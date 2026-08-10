import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Document paint stable canonical snapshot", .serialized)
struct DocumentPaintStableCanonicalSnapshotTests {
    private let tileBytes = PaintTileDescriptor.residentByteCount

    @Test
    func freezesFullOldEpochAcrossClearAndResizeUntilExplicitClose() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let oldGeometry = try geometry(width: 512, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: oldGeometry
        )
        let coordinates = [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
        ]
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layerID: coordinates]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let oldBinding = try registry.binding(for: layerID)

        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: layerID,
            addressing: .finite(oldGeometry.storagePixelSize),
            addressingRevision: 41,
            limits: .init(maximumActiveChildSelections: 2)
        )
        #expect(snapshot.documentGeneration == oldBinding.generation)
        #expect(snapshot.geometry == oldGeometry)
        #expect(snapshot.layerID == layerID)
        #expect(snapshot.revision == oldBinding.canonical.revision)
        #expect(snapshot.addressing == .finite(oldGeometry.storagePixelSize))
        #expect(snapshot.addressingRevision == 41)
        #expect(snapshot.referenceCount == 2)

        let cleared = try registry.makeCandidate(
            removingCoordinatesByLayer: [layerID: coordinates]
        )
        registry.commitPrepared(try registry.prepareCommit(cleared))
        let resizedGeometry = try geometry(width: 256, height: 256)
        let resized = try registry.makeCandidate(geometry: resizedGeometry)
        registry.commitPrepared(try registry.prepareCommit(resized))

        let child = try snapshot.captureVisibleSources(
            outputRegion: try region(0, 0, 1, 1),
            outputGeometryRevision: 77
        )
        #expect(child.key.documentGeneration == oldBinding.generation)
        #expect(child.key.addressingRevision == 41)
        #expect(child.key.outputGeometryRevision == 77)
        #expect(child.sourceBatch.sources[0].references
            == oldBinding.canonical.references)
        #expect(child.sourceBatch.sources[0].provider.entitledReferences
            == [oldBinding.canonical.references[0]])
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 1)

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: child.key,
            sourceBatch: child.sourceBatch,
            outputRegion: child.outputRegion,
            limits: stableSnapshotTestPlanLimits
        )
        #expect(lease.content.key.documentGeneration == oldBinding.generation)
        #expect(snapshot.activeChildSelectionCount == 0)
        snapshot.close()
        #expect(snapshot.isClosed)
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
        #expect(registry.sharedTileStore.snapshot().activeLeaseCount == 1)
        try lease.retire()
        #expect(registry.sharedTileStore.snapshot().activeLeaseCount == 0)
    }

    @Test
    func childLimitBorrowingAndCloseOwnExactlyOneRootToken() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 512, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: geometry,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)]
        )
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 1,
            limits: .init(maximumActiveChildSelections: 2)
        )
        let first = try snapshot.captureVisibleSources(
            outputRegion: try region(0, 0, 256, 256),
            outputGeometryRevision: 1
        )
        let second = try snapshot.captureVisibleSources(
            outputRegion: try region(256, 0, 512, 256),
            outputGeometryRevision: 2
        )
        let retained = registry.sharedTileStore.snapshot()
        #expect(retained.activeSnapshotTokenCount == 1)
        #expect(retained.aggregateSnapshotReferenceCount == 2)
        #expect(retained.snapshotPayloadDebtByteCount == tileBytes * 2)
        #expect(snapshot.activeChildSelectionCount == 2)
        #expect(throws: DocumentPaintStableCanonicalSnapshotError
            .activeChildSelectionLimitExceeded(maximum: 2)) {
            _ = try snapshot.captureVisibleSources(
                outputRegion: try region(0, 0, 1, 1),
                outputGeometryRevision: 3
            )
        }

        try first.sourceBatch.abandon()
        #expect(snapshot.activeChildSelectionCount == 1)
        let replacement = try snapshot.captureVisibleSources(
            outputRegion: try region(0, 0, 1, 1),
            outputGeometryRevision: 3
        )
        snapshot.close()
        #expect(throws: DocumentPaintStableCanonicalSnapshotError.closed) {
            _ = try snapshot.captureVisibleSources(
                outputRegion: try region(0, 0, 1, 1),
                outputGeometryRevision: 4
            )
        }
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 1)
        try second.sourceBatch.abandon()
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 1)
        try replacement.sourceBatch.abandon()
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
    }

    @Test
    func failedChildConsumptionReturnsAdmissionAndLeavesRootReusable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 256, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: geometry,
            coordinates: [.init(x: 0, y: 0)]
        )
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 1,
            limits: .init(maximumActiveChildSelections: 1)
        )
        let failed = try snapshot.captureVisibleSources(
            outputRegion: try region(0, 0, 256, 256),
            outputGeometryRevision: 1
        )
        let cache = SparseTileSamplingPlanCache(
            sourceLeaseFailureInjector: { _ in
                throw SparseTileSamplingPlanError.injectedSourceLeaseFailure(0)
            }
        )
        #expect(throws: SparseTileSamplingPlanError
            .injectedSourceLeaseFailure(0)) {
            _ = try cache.acquire(
                key: failed.key,
                sourceBatch: failed.sourceBatch,
                outputRegion: failed.outputRegion,
                limits: stableSnapshotTestPlanLimits
            )
        }
        #expect(snapshot.activeChildSelectionCount == 0)
        let next = try snapshot.captureVisibleSources(
            outputRegion: try region(0, 0, 1, 1),
            outputGeometryRevision: 2
        )
        try next.sourceBatch.abandon()
        snapshot.close()
        let terminal = registry.sharedTileStore.snapshot()
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(terminal.activeLeaseCount == 0)
        #expect(terminal.snapshotPayloadDebtByteCount == 0)
    }

    @Test
    func rootAndUnconsumedChildDeinitCloseAllRetentionDebt() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 256, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: geometry,
            coordinates: [.init(x: 0, y: 0)]
        )
        var snapshot: DocumentPaintStableCanonicalSnapshot? = try registry
            .captureStableCanonicalSnapshot(
                layerID: layerID,
                addressing: .finite(geometry.storagePixelSize),
                addressingRevision: 1
            )
        var child: DocumentPaintCanonicalVisibleSourceCapture? = try snapshot?
            .captureVisibleSources(
                outputRegion: region(0, 0, 1, 1),
                outputGeometryRevision: 1
            )
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 1)
        snapshot = nil
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 1)
        child = nil
        #expect(child == nil)
        let terminal = registry.sharedTileStore.snapshot()
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(terminal.aggregateSnapshotReferenceCount == 0)
        #expect(terminal.snapshotPayloadDebtByteCount == 0)
    }

    @Test
    func emptyRootAndChildConsumeNoStoreCapability() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 256, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: geometry
        )
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 1
        )
        #expect(snapshot.referenceCount == 0)
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
        let child = try snapshot.captureVisibleSources(
            outputRegion: try region(0, 0, 1, 1),
            outputGeometryRevision: 1
        )
        #expect(child.sourceBatch.sources[0].references.isEmpty)
        snapshot.close()
        try child.sourceBatch.abandon()
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
        #expect(snapshot.activeChildSelectionCount == 0)
    }

    @Test
    func selectedReferencePreflightRejectsBeforeBorrowAndRootStaysReusable()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 512, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: geometry,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)]
        )
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 1,
            limits: .init(
                maximumActiveChildSelections: 1,
                maximumSelectedReferenceCountPerChild: 1
            )
        )
        #expect(throws: DocumentPaintStableCanonicalSnapshotError
            .selectedReferenceLimitExceeded(required: 2, maximum: 1)) {
            _ = try snapshot.captureVisibleSources(
                outputRegion: try region(0, 0, 512, 256),
                outputGeometryRevision: 1
            )
        }
        #expect(snapshot.activeChildSelectionCount == 0)
        let retained = registry.sharedTileStore.snapshot()
        #expect(retained.activeSnapshotTokenCount == 1)
        #expect(retained.aggregateSnapshotReferenceCount == 2)
        let valid = try snapshot.captureVisibleSources(
            outputRegion: try region(0, 0, 1, 1),
            outputGeometryRevision: 2
        )
        try valid.sourceBatch.abandon()
        snapshot.close()
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
    }

    @Test
    func invalidRootRequestsAndLiabilityFailureAreTransactional() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 512, height: 256)
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes * 4,
            snapshotPayloadLiabilityByteBudget: tileBytes,
            transferByteCapacity: tileBytes * 13,
            geometry: geometry,
            layerIDs: [layerID]
        )
        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [
                layerID: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            ]
        )
        registry.commitPrepared(try registry.prepareCommit(candidate))

        let unknown = UUID()
        #expect(throws: DocumentPaintSurfaceStoreError.unknownLayerID(unknown)) {
            _ = try registry.captureStableCanonicalSnapshot(
                layerID: unknown,
                addressing: .finite(geometry.storagePixelSize),
                addressingRevision: 1
            )
        }
        #expect(throws: SparseTileSamplingPlanError.inconsistentAddressing) {
            _ = try registry.captureStableCanonicalSnapshot(
                layerID: layerID,
                addressing: .finite(PixelSize(width: 256, height: 256)),
                addressingRevision: 1
            )
        }
        #expect(throws: PaintTileStoreError.snapshotRetentionLimitExceeded(
            limit: .payloadDebtBytes,
            required: tileBytes * 2,
            maximum: tileBytes
        )) {
            _ = try registry.captureStableCanonicalSnapshot(
                layerID: layerID,
                addressing: .finite(geometry.storagePixelSize),
                addressingRevision: 1
            )
        }
        let terminal = registry.sharedTileStore.snapshot()
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(terminal.aggregateSnapshotReferenceCount == 0)
        #expect(terminal.snapshotPayloadDebtByteCount == 0)
        #expect(terminal.entries.allSatisfy { $0.snapshotRetainCount == 0 })
    }

    @Test
    func invalidZeroNegativeAndHardMaximumLimitsAreTyped() {
        #expect(throws: DocumentPaintStableCanonicalSnapshotError.invalidLimit) {
            _ = try DocumentPaintStableCanonicalSnapshotLimits(
                maximumActiveChildSelections: 0
            )
        }
        #expect(throws: DocumentPaintStableCanonicalSnapshotError.invalidLimit) {
            _ = try DocumentPaintStableCanonicalSnapshotLimits(
                maximumActiveChildSelections: -1
            )
        }
        #expect(throws: DocumentPaintStableCanonicalSnapshotError.invalidLimit) {
            _ = try DocumentPaintStableCanonicalSnapshotLimits(
                maximumActiveChildSelections: 1,
                maximumSelectedReferenceCountPerChild: 0
            )
        }
        #expect(throws: DocumentPaintStableCanonicalSnapshotError.invalidLimit) {
            _ = try DocumentPaintStableCanonicalSnapshotLimits(
                maximumActiveChildSelections: 65,
                maximumSelectedReferenceCountPerChild: 1
            )
        }
        #expect(throws: DocumentPaintStableCanonicalSnapshotError.invalidLimit) {
            _ = try DocumentPaintStableCanonicalSnapshotLimits(
                maximumActiveChildSelections: 1,
                maximumSelectedReferenceCountPerChild: 513
            )
        }
    }

    @Test
    func evictedRootAndChildStayMetadataOnlyUntilPlanAcquisition() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 256, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: geometry,
            coordinates: [.init(x: 0, y: 0)]
        )
        _ = try registry.sharedTileStore.applyMemoryPressure(
            targetResidentBytes: 0
        )
        let before = registry.sharedTileStore.snapshot()
        #expect(before.residentByteCount == 0)
        #expect(before.backingByteCount == tileBytes)
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 1
        )
        let afterRoot = registry.sharedTileStore.snapshot()
        #expect(afterRoot.residentByteCount == before.residentByteCount)
        #expect(afterRoot.backingByteCount == before.backingByteCount)
        #expect(afterRoot.stateRevision == before.stateRevision)
        #expect(afterRoot.persistentZeroAllocationCount
            == before.persistentZeroAllocationCount)
        #expect(afterRoot.lastTransferAccounting == before.lastTransferAccounting)
        let child = try snapshot.captureVisibleSources(
            outputRegion: try region(0, 0, 1, 1),
            outputGeometryRevision: 1
        )
        let afterChild = registry.sharedTileStore.snapshot()
        #expect(afterChild.residentByteCount == 0)
        #expect(afterChild.stateRevision == before.stateRevision)
        #expect(afterChild.lastTransferAccounting == before.lastTransferAccounting)

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: child.key,
            sourceBatch: child.sourceBatch,
            outputRegion: child.outputRegion,
            limits: stableSnapshotTestPlanLimits
        )
        #expect(registry.sharedTileStore.snapshot().residentByteCount == tileBytes)
        try lease.retire()
        snapshot.close()
        let terminal = registry.sharedTileStore.snapshot()
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(terminal.activeLeaseCount == 0)
    }

    @Test
    func childPreflightIntersectsEveryPlanAndStoreCapacity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 256, height: 256)
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes * 1_024,
            transferByteCapacity: tileBytes * 3_073,
            geometry: geometry,
            layerIDs: [layerID]
        )
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 1,
            limits: .init(
                maximumActiveChildSelections: 1,
                maximumSelectedReferenceCountPerChild: 512
            )
        )
        #expect(try snapshot.testingMaximumSelectedReferences(
            planLimits: planLimits()
        ) == 512)
        #expect(try snapshot.testingMaximumSelectedReferences(
            planLimits: planLimits(bindingSlots: 7)
        ) == 7)
        #expect(try snapshot.testingMaximumSelectedReferences(
            planLimits: planLimits(bindingBytes: 7 * 64)
        ) == 7)
        #expect(try snapshot.testingMaximumSelectedReferences(
            planLimits: planLimits(bindingChunks: 1)
        ) == 64)
        #expect(try snapshot.testingMaximumSelectedReferences(
            planLimits: planLimits(texturesPerBatch: 2, batchCount: 3)
        ) == 6)
        #expect(throws: SparseTileSamplingPlanError.invalidLimit) {
            _ = try snapshot.captureVisibleSources(
                outputRegion: try region(0, 0, 1, 1),
                outputGeometryRevision: 1,
                planLimits: planLimits(bindingSlots: 0)
            )
        }
        #expect(snapshot.activeChildSelectionCount == 0)
        snapshot.close()
    }

    @Test
    func captureAndCommitLinearizeAsWholeOldOrWholeNewEpochs() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 512, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: geometry,
            coordinates: [.init(x: 0, y: 0)]
        )
        let old = try registry.binding(for: layerID)
        let replacement = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layerID: [.init(x: 1, y: 0)]]
        )
        let prepared = try registry.prepareCommit(replacement)
        let barrier = StableSnapshotRaceBarrier()
        registry.testingEpochHook = barrier.hook

        let captureTask = Task.detached {
            try registry.captureStableCanonicalSnapshot(
                layerID: layerID,
                addressing: .finite(geometry.storagePixelSize),
                addressingRevision: 1
            )
        }
        try await barrier.waitUntilReached()
        let commitTask = Task.detached {
            registry.commitPrepared(prepared)
        }
        barrier.release()
        let oldSnapshot = try await captureTask.value
        await commitTask.value
        registry.testingEpochHook = nil

        #expect(oldSnapshot.documentGeneration == old.generation)
        #expect(oldSnapshot.referenceCount == 1)
        let newSnapshot = try registry.captureStableCanonicalSnapshot(
            layerID: layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 1
        )
        #expect(newSnapshot.documentGeneration == replacement.generation)
        #expect(newSnapshot.referenceCount == 2)
        let output = try region(0, 0, 1, 1)
        let oldChild = try oldSnapshot.captureVisibleSources(
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let newChild = try newSnapshot.captureVisibleSources(
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let cache = SparseTileSamplingPlanCache()
        let oldLease = try cache.acquire(
            key: oldChild.key,
            sourceBatch: oldChild.sourceBatch,
            outputRegion: output,
            limits: stableSnapshotTestPlanLimits
        )
        let newLease = try cache.acquire(
            key: newChild.key,
            sourceBatch: newChild.sourceBatch,
            outputRegion: output,
            limits: stableSnapshotTestPlanLimits
        )
        #expect(oldLease.content !== newLease.content)
        #expect(oldLease.content.key.addressingRevision
            == newLease.content.key.addressingRevision)
        #expect(oldLease.content.key.outputGeometryRevision
            == newLease.content.key.outputGeometryRevision)
        oldSnapshot.close()
        newSnapshot.close()
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
        #expect(registry.sharedTileStore.snapshot().activeLeaseCount == 2)
        try oldLease.retire()
        try newLease.retire()
        let terminal = registry.sharedTileStore.snapshot()
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(terminal.aggregateSnapshotReferenceCount == 0)
        #expect(terminal.activeLeaseCount == 0)
        #expect(terminal.snapshotPayloadDebtByteCount == 0)
    }

    @Test
    func closeAfterChildAdmissionRollsBackPartialConstruction() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 256, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: geometry,
            coordinates: [.init(x: 0, y: 0)]
        )
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 1,
            limits: .init(maximumActiveChildSelections: 1)
        )
        let barrier = StableChildAdmissionBarrier()
        snapshot.testingChildAdmissionCompleted = barrier.hook
        let childTask = Task.detached {
            Result {
                try snapshot.captureVisibleSources(
                    outputRegion: SparseTileOutputRegion(
                        minX: 0, minY: 0, maxX: 1, maxY: 1
                    ),
                    outputGeometryRevision: 1
                )
            }
        }
        try await barrier.waitUntilReached()
        snapshot.close()
        barrier.release()
        let result = await childTask.value
        #expect(throws: DocumentPaintStableCanonicalSnapshotError.closed) {
            _ = try result.get()
        }
        snapshot.testingChildAdmissionCompleted = nil
        #expect(snapshot.activeChildSelectionCount == 0)
        let terminal = registry.sharedTileStore.snapshot()
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(terminal.aggregateSnapshotReferenceCount == 0)
        #expect(terminal.snapshotPayloadDebtByteCount == 0)
    }

    @Test
    func closeVersusChildCreationIsLinearizableAcrossRepeatedRaces()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 256, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: geometry,
            coordinates: [.init(x: 0, y: 0)]
        )
        for revision in 0..<32 {
            let snapshot = try registry.captureStableCanonicalSnapshot(
                layerID: layerID,
                addressing: .finite(geometry.storagePixelSize),
                addressingRevision: UInt64(revision + 1),
                limits: .init(maximumActiveChildSelections: 1)
            )
            async let result = Task.detached {
                Result {
                    try snapshot.captureVisibleSources(
                        outputRegion: SparseTileOutputRegion(
                            minX: 0, minY: 0, maxX: 1, maxY: 1
                        ),
                        outputGeometryRevision: 1
                    )
                }
            }.value
            async let close: Void = Task.detached { snapshot.close() }.value
            let (captured, _) = await (result, close)
            switch captured {
            case let .success(child):
                try child.sourceBatch.abandon()
            case let .failure(error):
                #expect(
                    error as? DocumentPaintStableCanonicalSnapshotError
                        == .closed
                )
            }
            #expect(snapshot.activeChildSelectionCount == 0)
            #expect(registry.sharedTileStore.snapshot()
                .activeSnapshotTokenCount == 0)
        }
    }

    @Test
    func planAcquisitionFailuresReturnChildAdmissionAndKeepRootReusable()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        enum Failure: CaseIterable {
            case pageLimit
            case sourceLease
            case boundTexture
            case publication
        }
        for failure in Failure.allCases {
            let layerID = UUID()
            let geometry = try geometry(width: 512, height: 256)
            let registry = try makeRegistry(
                device: device,
                layerID: layerID,
                geometry: geometry,
                coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)]
            )
            let snapshot = try registry.captureStableCanonicalSnapshot(
                layerID: layerID,
                addressing: .finite(geometry.storagePixelSize),
                addressingRevision: 1,
                limits: .init(maximumActiveChildSelections: 1)
            )
            let cache = SparseTileSamplingPlanCache(
                sourceLeaseFailureInjector: { _ in
                    guard failure == .sourceLease else { return }
                    throw SparseTileSamplingPlanError
                        .injectedSourceLeaseFailure(0)
                },
                boundTextureFailureInjector: {
                    guard failure == .boundTexture else { return }
                    throw SparseTileSamplingPlanError
                        .injectedBoundTextureFailure
                },
                afterContentPublication: {
                    guard failure == .publication else { return }
                    throw SparseTileSamplingPlanError
                        .injectedContentPublicationFailure
                }
            )
            let limits = planLimits(
                pageEntries: failure == .pageLimit ? 1 : 1_048_576
            )
            let expected: SparseTileSamplingPlanError = switch failure {
            case .pageLimit:
                .pageEntryLimitExceeded(required: 2, maximum: 1)
            case .sourceLease:
                .injectedSourceLeaseFailure(0)
            case .boundTexture:
                .injectedBoundTextureFailure
            case .publication:
                .injectedContentPublicationFailure
            }

            #expect(throws: expected) {
                _ = try snapshot.acquireVisiblePlan(
                    cache: cache,
                    outputRegion: try region(0, 0, 512, 256),
                    outputGeometryRevision: 1,
                    limits: limits
                )
            }
            #expect(snapshot.activeChildSelectionCount == 0)
            #expect(cache.snapshot().activeContentAcquisitionCount == 0)
            #expect(cache.snapshot().pendingRetirementCount == 0)
            let retained = registry.sharedTileStore.snapshot()
            #expect(retained.activeSnapshotTokenCount == 1)
            #expect(retained.activeLeaseCount == 0)

            let recovery = try snapshot.acquireVisiblePlan(
                cache: SparseTileSamplingPlanCache(),
                outputRegion: try region(0, 0, 1, 1),
                outputGeometryRevision: 2,
                limits: stableSnapshotTestPlanLimits
            )
            try recovery.retire()
            snapshot.close()
            assertNoRetentionDebt(registry)
        }
    }

    @Test
    func rootCloseDuringPlanAcquisitionDefersUntilBorrowTerminates()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 256, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: geometry,
            coordinates: [.init(x: 0, y: 0)]
        )
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 1,
            limits: .init(maximumActiveChildSelections: 1)
        )
        let barrier = StableChildAdmissionBarrier()
        let cache = SparseTileSamplingPlanCache(
            afterSlotReservation: barrier.hook
        )
        let acquisition = Task.detached {
            try snapshot.acquireVisiblePlan(
                cache: cache,
                outputRegion: SparseTileOutputRegion(
                    minX: 0, minY: 0, maxX: 1, maxY: 1
                ),
                outputGeometryRevision: 1,
                limits: stableSnapshotTestPlanLimits
            )
        }
        try await barrier.waitUntilReached()
        snapshot.close()
        #expect(snapshot.activeChildSelectionCount == 1)
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 1)
        barrier.release()
        let lease = try await acquisition.value
        #expect(snapshot.activeChildSelectionCount == 0)
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
        #expect(registry.sharedTileStore.snapshot().activeLeaseCount == 1)
        try lease.retire()
        #expect(cache.snapshot().activeContentAcquisitionCount == 0)
        #expect(cache.snapshot().pendingRetirementCount == 0)
        assertNoRetentionDebt(registry)
    }

    @Test
    func invalidatedPlanReservationReturnsChildAdmissionAndRootCanRetry()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 256, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: geometry,
            coordinates: [.init(x: 0, y: 0)]
        )
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 1,
            limits: .init(maximumActiveChildSelections: 1)
        )
        let barrier = StableChildAdmissionBarrier()
        let cache = SparseTileSamplingPlanCache(
            afterSlotReservation: barrier.hook
        )
        let acquisition = Task.detached {
            Result {
                try snapshot.acquireVisiblePlan(
                    cache: cache,
                    outputRegion: SparseTileOutputRegion(
                        minX: 0, minY: 0, maxX: 1, maxY: 1
                    ),
                    outputGeometryRevision: 1,
                    limits: stableSnapshotTestPlanLimits
                )
            }
        }
        try await barrier.waitUntilReached()
        cache.invalidate(documentGeneration: snapshot.documentGeneration)
        barrier.release()
        let result = await acquisition.value
        #expect(throws: SparseTileSamplingPlanError.staleSlotOwner) {
            _ = try result.get()
        }
        #expect(snapshot.activeChildSelectionCount == 0)
        #expect(cache.snapshot().activeContentAcquisitionCount == 0)
        #expect(cache.snapshot().pendingRetirementCount == 0)
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 1)

        let recovery = try snapshot.acquireVisiblePlan(
            cache: cache,
            outputRegion: try region(0, 0, 1, 1),
            outputGeometryRevision: 2,
            limits: stableSnapshotTestPlanLimits
        )
        try recovery.retire()
        snapshot.close()
        assertNoRetentionDebt(registry)
    }

    @Test
    func failedLeaseReturnRemainsRetryableWithoutHoldingChildAdmission()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let geometry = try geometry(width: 256, height: 256)
        let registry = try makeRegistry(
            device: device,
            layerID: layerID,
            geometry: geometry,
            coordinates: [.init(x: 0, y: 0)]
        )
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 1,
            limits: .init(maximumActiveChildSelections: 1)
        )
        let returner = StableLeaseReturnProbe()
        let cache = SparseTileSamplingPlanCache(returnLease: returner.call)
        let lease = try snapshot.acquireVisiblePlan(
            cache: cache,
            outputRegion: try region(0, 0, 1, 1),
            outputGeometryRevision: 1,
            limits: stableSnapshotTestPlanLimits
        )
        #expect(snapshot.activeChildSelectionCount == 0)
        #expect(throws: StableLeaseReturnError.injected) {
            try lease.retire()
        }
        #expect(cache.snapshot().pendingRetirementCount == 1)
        #expect(registry.sharedTileStore.snapshot().activeLeaseCount == 1)
        try cache.retryPendingRetirements()
        #expect(cache.snapshot().pendingRetirementCount == 0)
        #expect(registry.sharedTileStore.snapshot().activeLeaseCount == 0)
        snapshot.close()
        assertNoRetentionDebt(registry)
    }

    private func makeRegistry(
        device: any MTLDevice,
        layerID: UUID,
        geometry: DocumentPaintGeometry,
        coordinates: [PaintTileCoordinate] = []
    ) throws -> DocumentPaintSurfaceStore {
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes * 8,
            transferByteCapacity: tileBytes * 25,
            geometry: geometry,
            layerIDs: [layerID]
        )
        if !coordinates.isEmpty {
            let candidate = try registry.makeCandidate(
                dirtyCoordinatesByLayer: [layerID: coordinates]
            )
            registry.commitPrepared(try registry.prepareCommit(candidate))
        }
        return registry
    }

    private func geometry(width: Int, height: Int) throws
        -> DocumentPaintGeometry
    {
        try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: width, height: height),
            storagePixelSize: PixelSize(width: width, height: height),
            radialLayout: nil
        )
    }

    private func region(
        _ minX: Int,
        _ minY: Int,
        _ maxX: Int,
        _ maxY: Int
    ) throws -> SparseTileOutputRegion {
        try SparseTileOutputRegion(
            minX: minX, minY: minY, maxX: maxX, maxY: maxY
        )
    }

    private func planLimits(
        pageEntries: Int = 1_048_576,
        bindingSlots: Int = 512,
        bindingChunks: Int = 16_384,
        bindingBytes: Int = 512 * 64,
        texturesPerBatch: Int = 16,
        batchCount: Int = 65_536
    ) -> SparseTilePlanLimits {
        SparseTilePlanLimits(
            maximumPageEntries: pageEntries,
            maximumPageChunks: 16_384,
            maximumPageTableBytes: 32 * 1_048_576,
            maximumBindingSlots: bindingSlots,
            maximumBindingChunks: bindingChunks,
            maximumBindingBytes: bindingBytes,
            maximumTexturesPerBatch: texturesPerBatch,
            maximumBatchCount: batchCount
        )
    }

    private func assertNoRetentionDebt(
        _ registry: DocumentPaintSurfaceStore,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let terminal = registry.sharedTileStore.snapshot()
        #expect(
            terminal.activeSnapshotTokenCount == 0,
            sourceLocation: sourceLocation
        )
        #expect(
            terminal.aggregateSnapshotReferenceCount == 0,
            sourceLocation: sourceLocation
        )
        #expect(
            terminal.activeLeaseCount == 0,
            sourceLocation: sourceLocation
        )
        #expect(
            terminal.snapshotPayloadDebtByteCount == 0,
            sourceLocation: sourceLocation
        )
    }
}

private final class StableSnapshotRaceBarrier: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let permit = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didReach = false

    lazy var hook: @Sendable (DocumentPaintSurfaceEpochTestingPoint) -> Void = {
        [weak self] point in
        guard point == .stableSnapshotCaptured else { return }
        self?.pauseOnce()
    }

    func waitUntilReached() async throws {
        let reached = reached
        let succeeded = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: reached.wait(timeout: .now() + 5) == .success
                )
            }
        }
        guard succeeded else { throw StableSnapshotRaceError.timeout }
    }

    func release() { permit.signal() }

    private func pauseOnce() {
        lock.lock()
        let shouldPause = !didReach
        didReach = true
        lock.unlock()
        guard shouldPause else { return }
        reached.signal()
        _ = permit.wait(timeout: .now() + 5)
    }
}

private enum StableSnapshotRaceError: Error { case timeout }

private enum StableLeaseReturnError: Error { case injected }

private final class StableLeaseReturnProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    lazy var call: SparseTileLeaseReturner = { [weak self] lease in
        guard let self else {
            throw StableLeaseReturnError.injected
        }
        lock.lock()
        attempts += 1
        let shouldFail = attempts == 1
        lock.unlock()
        guard !shouldFail else { throw StableLeaseReturnError.injected }
        try lease.returnLease()
    }
}

private final class StableChildAdmissionBarrier: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let permit = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didReach = false

    lazy var hook: @Sendable () -> Void = { [weak self] in
        guard let self else { return }
        lock.lock()
        let shouldPause = !didReach
        didReach = true
        lock.unlock()
        guard shouldPause else { return }
        reached.signal()
        _ = permit.wait(timeout: .now() + 5)
    }

    func waitUntilReached() async throws {
        let reached = reached
        let succeeded = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: reached.wait(timeout: .now() + 5) == .success
                )
            }
        }
        guard succeeded else { throw StableSnapshotRaceError.timeout }
    }

    func release() { permit.signal() }
}

private let stableSnapshotTestPlanLimits = SparseTilePlanLimits(
    maximumPageEntries: 4_096,
    maximumPageChunks: 256,
    maximumPageTableBytes: 1_048_576,
    maximumBindingSlots: 512,
    maximumBindingChunks: 64,
    maximumBindingBytes: 1_048_576,
    maximumTexturesPerBatch: 64,
    maximumBatchCount: 64
)
