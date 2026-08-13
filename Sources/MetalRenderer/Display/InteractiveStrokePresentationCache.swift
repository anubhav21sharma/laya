import EditorCore
import Foundation
@preconcurrency import Metal
import PatternEngine

enum InteractiveStrokePresentationCacheError: Error, Equatable, Sendable {
    case invalidCapacity
    case foreignUpdate
    case staleRevision(
        current: InteractiveStrokePresentationRevision,
        proposed: InteractiveStrokePresentationRevision
    )
    case updateSlotCapacityExceeded(maximum: Int)
    case tileCapacityExceeded(required: Int, maximum: Int)
    case commandBufferUnavailable
    case blitEncoderUnavailable
    case clearEncoderUnavailable
    case commandFailed(String)
    case generationIsUpdating(UInt64)
}

struct InteractiveStrokeCompositeParameters: Equatable, Sendable {
    let blendMode: LayerBlendMode
    let opacity: Float
}

struct InteractiveStrokePresentationRevision:
    Equatable, Hashable, Comparable, Sendable
{
    let generation: UInt64
    let sequence: UInt64

    static func < (
        lhs: InteractiveStrokePresentationRevision,
        rhs: InteractiveStrokePresentationRevision
    ) -> Bool {
        lhs.generation == rhs.generation
            ? lhs.sequence < rhs.sequence
            : lhs.generation < rhs.generation
    }
}

struct InteractiveStrokePresentationSnapshot: @unchecked Sendable {
    let revision: InteractiveStrokePresentationRevision
    let canonicalIdentity: CanvasCanonicalStateIdentity
    let authoritative: TiledRasterExactReferenceProvider?
    let prediction: TiledRasterExactReferenceProvider?
    let parameters: InteractiveStrokeCompositeParameters
}

struct InteractiveStrokePresentationCacheSnapshot: Equatable, Sendable {
    let maximumUpdateSlotCount: Int
    let activeUpdateSlotCount: Int
    let updateSlotHighWater: Int
    let residentBytes: Int
    let residentByteHighWater: Int
    let provisionalBytes: Int
    let componentCoverageBytes: Int
    let backingBytes: Int
    let publishedRevision: InteractiveStrokePresentationRevision?
    let submittedUpdateCount: UInt64
    let completedUpdateCount: UInt64
    let failedUpdateCount: UInt64
    let cancelledUpdateCount: UInt64
    let acknowledgementSettlementCount: UInt64
    let retirementWaiterCount: Int
    let retirementResumeCount: UInt64
}

protocol InteractiveStrokePresentationCacheCompletionGating: Sendable {
    func cacheCommandDidSubmit() async
    func waitAfterGPUCompletion() async
}

actor InteractiveStrokePresentationCache {
    private static let maximumUpdateSlotCount = 2

    private final class GenerationState: @unchecked Sendable {
        let generation: UInt64
        let layerID: UUID
        let pixelSize: PixelSize
        let authoritative: TiledRasterSurface
        let prediction: TiledRasterSurface

        init(
            store: PaintTileStore,
            generation: UInt64,
            layerID: UUID,
            pixelSize: PixelSize
        ) {
            self.generation = generation
            self.layerID = layerID
            self.pixelSize = pixelSize
            authoritative = TiledRasterSurface(
                store: store,
                layerID: layerID,
                pixelSize: pixelSize,
                generation: generation
            )
            prediction = TiledRasterSurface(
                store: store,
                layerID: layerID,
                pixelSize: pixelSize,
                generation: generation
            )
        }
    }

    private struct GPUCompletion: Sendable {
        let succeeded: Bool
        let message: String?
    }

    private final class GPUCompletionSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: GPUCompletion?
        private var waiter: CheckedContinuation<GPUCompletion, Never>?

        func finish(_ completion: GPUCompletion) {
            lock.lock()
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: completion)
            } else {
                self.completion = completion
                lock.unlock()
            }
        }

        func value() async -> GPUCompletion {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let completion {
                    lock.unlock()
                    continuation.resume(returning: completion)
                } else {
                    precondition(waiter == nil)
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }

    private final class DestinationUpdate: @unchecked Sendable {
        let surface: TiledRasterSurface
        let targetCoordinates: [PaintTileCoordinate]
        let modifiedCoordinates: [PaintTileCoordinate]
        var lease: PaintTileLease?
        var provisional: PaintTileProvisionalReservation?
        var wasCommitted = false

        init(
            surface: TiledRasterSurface,
            targetCoordinates: [PaintTileCoordinate],
            modifiedCoordinates: [PaintTileCoordinate]
        ) {
            self.surface = surface
            self.targetCoordinates = targetCoordinates
            self.modifiedCoordinates = modifiedCoordinates
        }

        func reserve() throws {
            guard !targetCoordinates.isEmpty else { return }
            lease = try surface.reserveSortedUniqueTiles(
                at: targetCoordinates,
                pinReasons: [.inFlight]
            )
            provisional = try surface.makeProvisionalBindings(
                for: lease!,
                coordinates: targetCoordinates,
                modifiedCoordinates: modifiedCoordinates,
                workspace: PaintTileProvisionalWorkspace(
                    maximumBindingCount: targetCoordinates.count
                )
            )
        }

        func commit() throws {
            guard let provisional, let lease else { return }
            let modified = Set(modifiedCoordinates)
            self.lease = try surface.commitProvisionalBindings(
                provisional,
                for: lease,
                modifiedCoordinates: modifiedCoordinates,
                knownClearCoordinates: targetCoordinates.filter {
                    !modified.contains($0)
                }
            )
            wasCommitted = true
            surface.completeProvisionalBindings(provisional)
        }

        func settle() {
            if let provisional, !wasCommitted {
                try? surface.cancelProvisionalBindings(provisional)
            }
            if let lease { try? surface.returnLease(lease) }
        }
    }

    private let commandQueue: any MTLCommandQueue
    private let store: PaintTileStore
    private let maximumTileCount: Int
    private let completionGate:
        (any InteractiveStrokePresentationCacheCompletionGating)?
    private let traceRecorder: InteractiveBrushTraceRecorder?
    private var generationState: GenerationState?
    private var published: InteractiveStrokePresentationSnapshot?
    private var updatingRevision: InteractiveStrokePresentationRevision?
    private var cancelledGenerations: Set<UInt64> = []
    private var updateSlotHighWater = 0
    private var submittedUpdateCount: UInt64 = 0
    private var completedUpdateCount: UInt64 = 0
    private var failedUpdateCount: UInt64 = 0
    private var cancelledUpdateCount: UInt64 = 0
    private var acknowledgementSettlementCount: UInt64 = 0
    private var retirementWaiters:
        [(UInt64, CheckedContinuation<Void, Never>)] = []
    private var retirementResumeCount: UInt64 = 0

    init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        byteBudget: Int,
        maximumTileCount: Int,
        completionGate:
            (any InteractiveStrokePresentationCacheCompletionGating)? = nil,
        traceRecorder: InteractiveBrushTraceRecorder? = nil
    ) {
        precondition(byteBudget > 0 && maximumTileCount > 0)
        self.commandQueue = commandQueue
        store = PaintTileStore(device: device, byteBudget: byteBudget)
        self.maximumTileCount = maximumTileCount
        self.completionGate = completionGate
        self.traceRecorder = traceRecorder
    }

    func adopt(
        _ update: DocumentPaintTransientCacheUpdate,
        parameters: InteractiveStrokeCompositeParameters
    ) async throws -> InteractiveStrokePresentationRevision {
        guard update.acknowledgementSettlement.claimOwnership() else {
            throw InteractiveStrokePresentationCacheError.foreignUpdate
        }
        let revision = InteractiveStrokePresentationRevision(
            generation: update.generation,
            sequence: update.sequence
        )
        defer { finishUpdateSlotIfOwned(revision) }
        do {
            let result = try await adoptCore(
                update,
                revision: revision,
                parameters: parameters
            )
            try await settleAcknowledgement(update, revision: revision)
            return result
        } catch {
            if error is CancellationError {
                cancelledUpdateCount &+= 1
            } else {
                failedUpdateCount &+= 1
            }
            try? await settleAcknowledgement(update, revision: revision)
            throw error
        }
    }

    func current(generation: UInt64) throws
        -> InteractiveStrokePresentationSnapshot?
    {
        guard let published, published.revision.generation == generation else {
            return nil
        }
        return published
    }

    func retire(generation: UInt64) async throws {
        if updatingRevision?.generation == generation {
            await withCheckedContinuation { continuation in
                retirementWaiters.append((generation, continuation))
            }
        }
        try retireCompletedGeneration(generation)
    }

    private func retireCompletedGeneration(_ generation: UInt64) throws {
        precondition(updatingRevision?.generation != generation)
        guard let state = generationState, state.generation == generation else {
            return
        }
        try state.authoritative.advanceGeneration()
        try state.prediction.advanceGeneration()
        generationState = nil
        if published?.revision.generation == generation { published = nil }
        cancelledGenerations.remove(generation)
    }

    func cancel(generation: UInt64) async throws {
        cancelledGenerations.insert(generation)
        try await retire(generation: generation)
    }

    func snapshot() -> InteractiveStrokePresentationCacheSnapshot {
        let storeSnapshot = store.snapshot()
        let activeSlots = (published == nil ? 0 : 1)
            + (updatingRevision == nil ? 0 : 1)
        return InteractiveStrokePresentationCacheSnapshot(
            maximumUpdateSlotCount: Self.maximumUpdateSlotCount,
            activeUpdateSlotCount: activeSlots,
            updateSlotHighWater: updateSlotHighWater,
            residentBytes: storeSnapshot.residentByteCount,
            residentByteHighWater: storeSnapshot.residentByteHighWater,
            provisionalBytes: storeSnapshot.provisionalByteCount,
            componentCoverageBytes: storeSnapshot.componentCoverageByteCount,
            backingBytes: storeSnapshot.backingByteCount,
            publishedRevision: published?.revision,
            submittedUpdateCount: submittedUpdateCount,
            completedUpdateCount: completedUpdateCount,
            failedUpdateCount: failedUpdateCount,
            cancelledUpdateCount: cancelledUpdateCount,
            acknowledgementSettlementCount: acknowledgementSettlementCount,
            retirementWaiterCount: retirementWaiters.count,
            retirementResumeCount: retirementResumeCount
        )
    }

    private func adoptCore(
        _ update: DocumentPaintTransientCacheUpdate,
        revision: InteractiveStrokePresentationRevision,
        parameters: InteractiveStrokeCompositeParameters
    ) async throws -> InteractiveStrokePresentationRevision {
        guard parameters.opacity.isFinite,
              (0...1).contains(parameters.opacity)
        else { throw InteractiveStrokePresentationCacheError.foreignUpdate }
        guard updatingRevision == nil else {
            throw InteractiveStrokePresentationCacheError
                .updateSlotCapacityExceeded(
                    maximum: Self.maximumUpdateSlotCount
                )
        }
        if let published, revision <= published.revision {
            throw InteractiveStrokePresentationCacheError.staleRevision(
                current: published.revision,
                proposed: revision
            )
        }
        let authoritativeSource = update.descriptor.authoritativeProvider
        let predictionSource = update.descriptor.predictionProvider
        guard authoritativeSource.layerID == update.layerID,
              predictionSource.layerID == update.layerID,
              authoritativeSource.generation == update.generation,
              predictionSource.generation == update.generation,
              authoritativeSource.pixelSize
                == update.canonicalIdentity.geometry.storagePixelSize,
              predictionSource.pixelSize == authoritativeSource.pixelSize
        else { throw InteractiveStrokePresentationCacheError.foreignUpdate }

        let state: GenerationState
        if let existing = generationState {
            guard existing.generation == update.generation,
                  existing.layerID == update.layerID,
                  existing.pixelSize == authoritativeSource.pixelSize
            else { throw InteractiveStrokePresentationCacheError.foreignUpdate }
            state = existing
        } else {
            state = GenerationState(
                store: store,
                generation: update.generation,
                layerID: update.layerID,
                pixelSize: authoritativeSource.pixelSize
            )
            generationState = state
        }

        updatingRevision = revision
        updateSlotHighWater = max(
            updateSlotHighWater,
            (published == nil ? 0 : 1) + 1
        )

        let selectedSource = update.changedRole == .authoritative
            ? authoritativeSource : predictionSource
        let changedSet = Set(update.changedCoordinates)
        let sourceReferences = selectedSource.references.filter {
            changedSet.contains($0.coordinate)
        }
        guard sourceReferences.count == update.changedCoordinates.count else {
            throw InteractiveStrokePresentationCacheError.foreignUpdate
        }
        let modifiedCoordinates = sourceReferences.map(\.coordinate)
        let authoritativeNextCoordinates = nextCoordinates(
            existing: state.authoritative.references.map(\.coordinate),
            clearsExisting: update.clearedAuthoritativeSurface,
            modified: update.changedRole == .authoritative
                ? modifiedCoordinates : []
        )
        let predictionNextCoordinates = nextCoordinates(
            existing: state.prediction.references.map(\.coordinate),
            clearsExisting: update.clearedPredictionSurface,
            modified: update.changedRole == .prediction
                ? modifiedCoordinates : []
        )
        let (requiredTileCount, requiredTileCountOverflow) =
            authoritativeNextCoordinates.count.addingReportingOverflow(
                predictionNextCoordinates.count
            )
        guard !requiredTileCountOverflow,
              requiredTileCount <= maximumTileCount
        else {
            throw InteractiveStrokePresentationCacheError.tileCapacityExceeded(
                required: requiredTileCountOverflow ? .max : requiredTileCount,
                maximum: maximumTileCount
            )
        }
        let restrictedSource = try selectedSource.restrictingEntitlement(
            to: sourceReferences
        )
        let capture = try TiledRasterExactReferenceCapture(
            providers: [restrictedSource]
        )
        var sourceLease: TiledRasterExactReferenceLease?
        let authoritativeUpdate = destinationUpdate(
            surface: state.authoritative,
            clearsExisting: update.clearedAuthoritativeSurface,
            modified: update.changedRole == .authoritative
                ? modifiedCoordinates : []
        )
        let predictionUpdate = destinationUpdate(
            surface: state.prediction,
            clearsExisting: update.clearedPredictionSurface,
            modified: update.changedRole == .prediction
                ? modifiedCoordinates : []
        )
        let destinationUpdates = [authoritativeUpdate, predictionUpdate]
            .compactMap { $0 }
        defer {
            for destinationUpdate in destinationUpdates.reversed() {
                destinationUpdate.settle()
            }
            try? sourceLease?.returnLease()
            capture.close()
        }

        if !sourceReferences.isEmpty {
            sourceLease = try restrictedSource.leaseExactReferences(
                sourceReferences,
                using: capture,
                pinReasons: [.inFlight]
            )
        }
        for destinationUpdate in destinationUpdates {
            try destinationUpdate.reserve()
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw InteractiveStrokePresentationCacheError
                .commandBufferUnavailable
        }
        for destinationUpdate in destinationUpdates {
            guard let provisional = destinationUpdate.provisional else {
                continue
            }
            let modified = Set(destinationUpdate.modifiedCoordinates)
            try encodeCopy(
                sourceBindings: (sourceLease?.bindings ?? []).filter {
                    modified.contains($0.descriptor.coordinate)
                },
                targetCoordinates: destinationUpdate.targetCoordinates,
                provisional: provisional,
                commandBuffer: commandBuffer
            )
        }
        recordTrace(
            .transientCacheSubmitted,
            update: update,
            residentBytes: store.snapshot().residentByteCount
        )
        let completionSignal = commit(commandBuffer)
        submittedUpdateCount &+= 1
        await completionGate?.cacheCommandDidSubmit()
        let completion = await completionSignal.value()
        await completionGate?.waitAfterGPUCompletion()
        guard completion.succeeded else {
            throw InteractiveStrokePresentationCacheError.commandFailed(
                completion.message ?? "transient cache command failed"
            )
        }
        try Task.checkCancellation()
        guard !cancelledGenerations.contains(update.generation) else {
            throw CancellationError()
        }

        for destinationUpdate in destinationUpdates {
            try destinationUpdate.commit()
        }
        let next = InteractiveStrokePresentationSnapshot(
            revision: revision,
            canonicalIdentity: update.canonicalIdentity,
            authoritative: try state.authoritative.makeExactReferenceProvider(),
            prediction: try state.prediction.makeExactReferenceProvider(),
            parameters: parameters
        )
        published = next
        completedUpdateCount &+= 1
        recordTrace(
            .transientCacheCompleted,
            update: update,
            residentBytes: store.snapshot().residentByteCount
        )
        return revision
    }

    private func nextCoordinates(
        existing: [PaintTileCoordinate],
        clearsExisting: Bool,
        modified: [PaintTileCoordinate]
    ) -> [PaintTileCoordinate] {
        var coordinates = clearsExisting ? [] : existing
        coordinates.append(contentsOf: modified)
        return sortedUnique(coordinates)
    }

    private func destinationUpdate(
        surface: TiledRasterSurface,
        clearsExisting: Bool,
        modified: [PaintTileCoordinate]
    ) -> DestinationUpdate? {
        var targets = modified
        if clearsExisting {
            targets.append(contentsOf: surface.references.map(\.coordinate))
        }
        targets = sortedUnique(targets)
        guard !targets.isEmpty else { return nil }
        return DestinationUpdate(
            surface: surface,
            targetCoordinates: targets,
            modifiedCoordinates: modified
        )
    }

    private func sortedUnique(
        _ coordinates: [PaintTileCoordinate]
    ) -> [PaintTileCoordinate] {
        coordinates.sorted().reduce(into: []) {
            if $0.last != $1 { $0.append($1) }
        }
    }

    private func encodeCopy(
        sourceBindings: [PaintTileBinding],
        targetCoordinates: [PaintTileCoordinate],
        provisional: PaintTileProvisionalReservation,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        let sources = Dictionary(uniqueKeysWithValues: sourceBindings.map {
            ($0.descriptor.coordinate, $0.texture)
        })
        if !sources.isEmpty {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw InteractiveStrokePresentationCacheError
                    .blitEncoderUnavailable
            }
            for index in 0..<provisional.count {
                let candidate = provisional[index]
                guard let source = sources[candidate.descriptor.coordinate]
                else { continue }
                blit.copy(
                    from: source,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(
                        width: PaintTileDescriptor.side,
                        height: PaintTileDescriptor.side,
                        depth: 1
                    ),
                    to: candidate.candidateTexture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
            blit.endEncoding()
        }
        for index in 0..<provisional.count {
            let candidate = provisional[index]
            let pass = MTLRenderPassDescriptor()
            let colorIsClear = sources[candidate.descriptor.coordinate] == nil
            if colorIsClear {
                pass.colorAttachments[0].texture = candidate.candidateTexture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColorMake(
                    0, 0, 0, 0
                )
            }
            // These surfaces are presentation-only: they never continue
            // deposition. Initialize their private accumulation companion
            // deterministically instead of retaining undefined GPU memory.
            let coverageAttachment = colorIsClear ? 1 : 0
            pass.colorAttachments[coverageAttachment].texture =
                candidate.candidateComponentCoverageTexture
            pass.colorAttachments[coverageAttachment].loadAction = .clear
            pass.colorAttachments[coverageAttachment].storeAction = .store
            pass.colorAttachments[coverageAttachment].clearColor =
                MTLClearColorMake(0, 0, 0, 0)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: pass
            ) else {
                throw InteractiveStrokePresentationCacheError
                    .clearEncoderUnavailable
            }
            encoder.endEncoding()
        }
        precondition(provisional.count == targetCoordinates.count)
    }

    private func commit(
        _ commandBuffer: any MTLCommandBuffer
    ) -> GPUCompletionSignal {
        let signal = GPUCompletionSignal()
        commandBuffer.addCompletedHandler { completed in
            signal.finish(GPUCompletion(
                succeeded: completed.status == .completed,
                message: completed.error?.localizedDescription
            ))
        }
        commandBuffer.commit()
        return signal
    }

    private func settleAcknowledgement(
        _ update: DocumentPaintTransientCacheUpdate,
        revision: InteractiveStrokePresentationRevision
    ) async throws {
        guard update.acknowledgementSettlement.claimSettlement() else {
            return
        }
        acknowledgementSettlementCount &+= 1
        try await update.acknowledgement.fulfill()
    }

    private func finishUpdateSlotIfOwned(
        _ revision: InteractiveStrokePresentationRevision
    ) {
        guard updatingRevision == revision else { return }
        updatingRevision = nil
        var resumed: [CheckedContinuation<Void, Never>] = []
        retirementWaiters.removeAll { waiter in
            guard waiter.0 == revision.generation else { return false }
            resumed.append(waiter.1)
            return true
        }
        retirementResumeCount &+= UInt64(resumed.count)
        for continuation in resumed { continuation.resume() }
    }

    private func recordTrace(
        _ stage: InteractiveBrushTraceStage,
        update: DocumentPaintTransientCacheUpdate,
        residentBytes: Int
    ) {
        for identity in update.traceIdentities {
            traceRecorder?.record(
                stage: stage,
                lineage: InteractiveBrushInputTrace(
                    identity: identity,
                    eventReceiptMonotonicNanoseconds: nil
                ),
                dirtyTileCount: update.changedCoordinates.count,
                residentBytes: residentBytes,
                activeOwnershipCount:
                    (published == nil ? 0 : 1)
                        + (updatingRevision == nil ? 0 : 1)
            )
        }
    }
}
