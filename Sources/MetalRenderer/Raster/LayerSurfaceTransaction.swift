import EditorCore
import Foundation
import PatternEngine

struct LayerSurfaceTransactionReceipt: Equatable, Sendable {
    let before: LayerStack
    let after: LayerStack
    let baseGeneration: UInt64
    let generation: UInt64
    let addedLayerIDs: [UUID]
    let removedLayerIDs: [UUID]
    let historyRevision: LayerSurfaceHistoryRevision
}

/// Sole prepared owner for one stack+raster registry publication. The store's
/// immutable epoch contains both values, so commit is one nonthrowing swap;
/// cancellation retires candidate-only tiles without changing the old epoch.
final class LayerSurfaceTransaction: @unchecked Sendable {
    private enum State { case prepared, committed, cancelled }

    private let store: DocumentPaintSurfaceStore
    private let preparedCommit: DocumentPaintPreparedCommit
    private let receipt: LayerSurfaceTransactionReceipt
    private let historyRevision: LayerSurfaceHistoryRevision
    private let restorationBorrow: LayerSurfaceHistoryRevision.Borrow?
    private let ownsHistoryRevision: Bool
    private let lock = NSLock()
    private var state = State.prepared

    var historyRetainedBytes: Int { historyRevision.retainedBytes }

    init(
        store: DocumentPaintSurfaceStore,
        preparedCommit: DocumentPaintPreparedCommit,
        before: LayerStack,
        after: LayerStack,
        baseGeneration: UInt64,
        generation: UInt64,
        historyRevision: LayerSurfaceHistoryRevision,
        restorationBorrow: LayerSurfaceHistoryRevision.Borrow? = nil,
        ownsHistoryRevision: Bool
    ) {
        let beforeIDs = Set(before.orderedLayerIDs)
        let afterIDs = Set(after.orderedLayerIDs)
        self.store = store
        self.preparedCommit = preparedCommit
        self.historyRevision = historyRevision
        self.restorationBorrow = restorationBorrow
        self.ownsHistoryRevision = ownsHistoryRevision
        receipt = LayerSurfaceTransactionReceipt(
            before: before,
            after: after,
            baseGeneration: baseGeneration,
            generation: generation,
            addedLayerIDs: after.orderedLayerIDs.filter {
                !beforeIDs.contains($0)
            },
            removedLayerIDs: before.orderedLayerIDs.filter {
                !afterIDs.contains($0)
            },
            historyRevision: historyRevision
        )
    }

    func commit() -> LayerSurfaceTransactionReceipt {
        lock.lock()
        switch state {
        case .prepared:
            state = .committed
            lock.unlock()
            store.commitPreparedForCoordinator(preparedCommit)
            restorationBorrow?.close()
            return receipt
        case .committed:
            lock.unlock()
            return receipt
        case .cancelled:
            lock.unlock()
            preconditionFailure("cancelled layer transaction cannot commit")
        }
    }

    func cancel() {
        lock.lock()
        guard state == .prepared else {
            lock.unlock()
            return
        }
        state = .cancelled
        lock.unlock()
        store.cancelPrepared(preparedCommit)
        restorationBorrow?.close()
        if ownsHistoryRevision { historyRevision.close() }
    }

    deinit { cancel() }
}

private final class LayerSurfaceResizeEncoding {
    let layerID: UUID
    let dirtyCoordinates: [PaintTileCoordinate]
    let sourceBinding: DocumentPaintLayerBinding
    let candidateBinding: DocumentPaintLayerBinding
    var sourceLease: PaintTileLease?
    var destinationLease: PaintTileLease?
    var backendEncoding: DocumentPaintSurfaceMutationBackendEncoding?

    init(
        layerID: UUID,
        dirtyCoordinates: [PaintTileCoordinate],
        sourceBinding: DocumentPaintLayerBinding,
        candidateBinding: DocumentPaintLayerBinding,
        sourceLease: PaintTileLease?,
        destinationLease: PaintTileLease?,
        backendEncoding: DocumentPaintSurfaceMutationBackendEncoding
    ) {
        self.layerID = layerID
        self.dirtyCoordinates = dirtyCoordinates
        self.sourceBinding = sourceBinding
        self.candidateBinding = candidateBinding
        self.sourceLease = sourceLease
        self.destinationLease = destinationLease
        self.backendEncoding = backendEncoding
    }
}

private enum LayerSurfaceResizeTransactionError: Error {
    case cleanupFailed
}

extension DocumentPaintSurfaceStore {
    func prepareLayerSurfaceTransaction(
        layerStack: LayerStack,
        geometry: DocumentPaintGeometry? = nil,
        dirtyCoordinatesByLayer: [UUID: [PaintTileCoordinate]] = [:],
        removingCoordinatesByLayer: [UUID: [PaintTileCoordinate]] = [:],
        failureInjection: PaintTileAllocationFailureInjection? = nil
    ) throws -> LayerSurfaceTransaction {
        let candidate = try makeCandidate(
            geometry: geometry,
            layerStack: layerStack,
            dirtyCoordinatesByLayer: dirtyCoordinatesByLayer,
            removingCoordinatesByLayer: removingCoordinatesByLayer,
            failureInjection: failureInjection
        )
        let historyRevision: LayerSurfaceHistoryRevision
        do {
            historyRevision = try prepareLayerSurfaceHistoryRevision(
                for: candidate
            )
        } catch {
            try? discard(candidate)
            throw error
        }
        do {
            let prepared = try prepareCommit(candidate)
            return LayerSurfaceTransaction(
                store: self,
                preparedCommit: prepared,
                before: candidate.baseLayerStack,
                after: candidate.layerStack,
                baseGeneration: candidate.baseGeneration,
                generation: candidate.generation,
                historyRevision: historyRevision,
                ownsHistoryRevision: true
            )
        } catch {
            historyRevision.close()
            try? discard(candidate)
            throw error
        }
    }

    func prepareLayerSurfaceRestore(
        _ revision: LayerSurfaceHistoryRevision,
        endpoint: LayerSurfaceRevisionEndpoint
    ) throws -> LayerSurfaceTransaction {
        let borrow = try revision.borrow()
        do {
            let prepared = try prepareLayerSurfaceRestoreCommit(
                borrow,
                endpoint: endpoint
            )
            return LayerSurfaceTransaction(
                store: self,
                preparedCommit: prepared,
                before: prepared.layerTransactionBefore,
                after: prepared.layerTransactionAfter,
                baseGeneration: prepared.layerTransactionBaseGeneration,
                generation: prepared.layerTransactionGeneration,
                historyRevision: revision,
                restorationBorrow: borrow,
                ownsHistoryRevision: false
            )
        } catch {
            borrow.close()
            throw error
        }
    }

    /// Prepares every layer against one immutable base generation. GPU copies,
    /// transparency reduction, and lease return all finish while the candidate
    /// remains unpublished; the returned transaction owns the sole atomic
    /// stack+geometry swap and one exact multi-layer history revision.
    func prepareLayerSurfaceResizeTransaction(
        layerStack: LayerStack,
        geometry: DocumentPaintGeometry,
        targetRadialConfiguration: RadialSymmetryConfiguration?,
        backend: any DocumentPaintSurfaceMutationBackend
    ) throws -> LayerSurfaceTransaction {
        let base = snapshot()
        guard base.layerStack == layerStack else {
            throw DocumentPaintSurfaceStoreError.layerStackMismatch(
                expected: base.layerStack.orderedLayerIDs,
                actual: layerStack.orderedLayerIDs
            )
        }
        var plans: [UUID: DocumentPaintSurfaceTransaction.ResizePlan] = [:]
        var dirty: [UUID: [PaintTileCoordinate]] = [:]
        var removed: [UUID: [PaintTileCoordinate]] = [:]
        for layer in base.layers {
            let plan = try DocumentPaintSurfaceTransaction.makeResizePlan(
                baseCoordinates: layer.references.map(\.coordinate),
                sourceGeometry: base.geometry,
                candidateGeometry: geometry
            )
            plans[layer.layerID] = plan
            dirty[layer.layerID] = plan.afterCoordinates
            removed[layer.layerID] = plan.removedCoordinates
        }
        let candidate = try makeCandidate(
            geometry: geometry,
            layerStack: layerStack,
            dirtyCoordinatesByLayer: dirty,
            removingCoordinatesByLayer: removed
        )
        guard candidate.baseGeneration == base.generation,
              candidate.baseLayerStack == base.layerStack
        else {
            try discard(candidate)
            throw DocumentPaintSurfaceStoreError.staleCandidate(
                expectedGeneration: base.generation,
                actualGeneration: candidate.baseGeneration
            )
        }
        var records: [LayerSurfaceResizeEncoding] = []
        records.reserveCapacity(layerStack.layers.count)
        var transparentCoordinatesByLayer:
            [UUID: [PaintTileCoordinate]] = [:]

        func cleanResources() throws {
            var failed = false
            for record in records.reversed() {
                if let encoding = record.backendEncoding {
                    do {
                        try backend.discardAndWaitUntilTerminal(encoding)
                        record.backendEncoding = nil
                    } catch {
                        failed = true
                    }
                }
                if let lease = record.sourceLease {
                    do {
                        try record.sourceBinding.canonical.returnLease(lease)
                        record.sourceLease = nil
                    } catch {
                        failed = true
                    }
                }
                if let lease = record.destinationLease {
                    do {
                        try record.candidateBinding.canonical.returnLease(lease)
                        record.destinationLease = nil
                    } catch {
                        failed = true
                    }
                }
            }
            if failed { throw LayerSurfaceResizeTransactionError.cleanupFailed }
        }

        do {
            for layerID in layerStack.orderedLayerIDs {
                guard let plan = plans[layerID] else {
                    throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
                }
                let sourceBinding = try binding(for: layerID)
                let candidateBinding = try candidate.binding(for: layerID)
                let sourceLease = plan.sourceCoordinates.isEmpty
                    ? nil
                    : try sourceBinding.canonical.leaseExistingTiles(
                        at: plan.sourceCoordinates,
                        pinReasons: [.inFlight]
                    )
                let destinationLease = plan.afterCoordinates.isEmpty
                    ? nil
                    : try candidateBinding.canonical.leaseExistingTiles(
                        at: plan.afterCoordinates,
                        pinReasons: [.dirty, .inFlight]
                    )
                do {
                    let sources = (sourceLease?.bindings ?? []).map {
                        DocumentPaintSurfaceMutationSource(
                            coordinate: $0.descriptor.coordinate,
                            logicalBounds: $0.descriptor.logicalBounds,
                            texture: $0.texture
                        )
                    }
                    let destinations = (destinationLease?.bindings ?? []).map {
                        DocumentPaintSurfaceMutationDestination(
                            coordinate: $0.descriptor.coordinate,
                            logicalBounds: $0.descriptor.logicalBounds,
                            texture: $0.texture
                        )
                    }
                    try DocumentPaintSurfaceTransaction.validateResizeBindings(
                        sources: sources,
                        destinations: destinations,
                        plan: plan
                    )
                    let encoding = try backend.encode(.resize(.init(
                        sourceGeometry: base.geometry,
                        candidateGeometry: geometry,
                        targetRadialConfiguration: targetRadialConfiguration,
                        clearsDestinationsBeforeCopy: true,
                        sources: sources,
                        destinations: destinations,
                        mappings: plan.mappings
                    )))
                    records.append(LayerSurfaceResizeEncoding(
                        layerID: layerID,
                        dirtyCoordinates: plan.afterCoordinates,
                        sourceBinding: sourceBinding,
                        candidateBinding: candidateBinding,
                        sourceLease: sourceLease,
                        destinationLease: destinationLease,
                        backendEncoding: encoding
                    ))
                } catch {
                    if let sourceLease {
                        try? sourceBinding.canonical.returnLease(sourceLease)
                    }
                    if let destinationLease {
                        try? candidateBinding.canonical.returnLease(
                            destinationLease
                        )
                    }
                    throw error
                }
            }

            for record in records {
                guard let encoding = record.backendEncoding else {
                    preconditionFailure("Layer resize lost backend encoding")
                }
                let evidence = try backend.complete(encoding, as: .succeeded)
                record.backendEncoding = nil
                let reduction = try DocumentPaintSurfaceTransaction
                    .validateReduction(
                        evidence,
                        dirtyCoordinates: record.dirtyCoordinates,
                        pixelSize: geometry.storagePixelSize
                    )
                transparentCoordinatesByLayer[record.layerID] =
                    reduction.fullyTransparentCoordinates
            }
            try cleanResources()
            for layerID in layerStack.orderedLayerIDs {
                try pruneFullyTransparentCoordinates(
                    transparentCoordinatesByLayer[layerID] ?? [],
                    from: candidate,
                    layerID: layerID
                )
            }

            let history = try prepareLayerSurfaceHistoryRevision(for: candidate)
            do {
                let prepared = try prepareCommit(candidate)
                return LayerSurfaceTransaction(
                    store: self,
                    preparedCommit: prepared,
                    before: candidate.baseLayerStack,
                    after: candidate.layerStack,
                    baseGeneration: candidate.baseGeneration,
                    generation: candidate.generation,
                    historyRevision: history,
                    ownsHistoryRevision: true
                )
            } catch {
                history.close()
                throw error
            }
        } catch {
            do {
                try cleanResources()
                try discard(candidate)
            } catch {
                throw LayerSurfaceResizeTransactionError.cleanupFailed
            }
            throw error
        }
    }
}
