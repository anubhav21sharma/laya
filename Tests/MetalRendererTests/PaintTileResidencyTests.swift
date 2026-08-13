import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Paint tile residency", .serialized)
struct PaintTileResidencyTests {
    private let bytes = PaintTileDescriptor.residentByteCount

    @Test
    func budgetFormulaUsesExactClampAndPlatformFallbacks() throws {
        let mib = UInt64(1_024 * 1_024)
        #expect(try PaintTileBudget.bytes(recommendedMaxWorkingSetSize: 1, fallback: .macOS) == 64 * Int(mib))
        #expect(try PaintTileBudget.bytes(recommendedMaxWorkingSetSize: 800 * mib, fallback: .macOS) == 100 * Int(mib))
        #expect(try PaintTileBudget.bytes(recommendedMaxWorkingSetSize: 8_000 * mib, fallback: .iOS) == 256 * Int(mib))
        #expect(try PaintTileBudget.bytes(recommendedMaxWorkingSetSize: 0, fallback: .macOS) == 128 * Int(mib))
        #expect(try PaintTileBudget.bytes(recommendedMaxWorkingSetSize: 0, fallback: .iOS) == 64 * Int(mib))
        #expect(try PaintTileBudget.bytes(recommendedMaxWorkingSetSize: UInt64.max, fallback: .macOS) == 256 * Int(mib))
    }

    @Test
    func deterministicTieOrderIsEpochLayerYXTiles() throws {
        let layerA = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let layerB = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let identities = [
            identity(layer: layerB, x: 0, y: 0, tileID: 1),
            identity(layer: layerA, x: 1, y: 0, tileID: 4),
            identity(layer: layerA, x: 0, y: 1, tileID: 3),
            identity(layer: layerA, x: 0, y: 0, tileID: 2),
            identity(layer: layerA, x: 0, y: 0, tileID: 1),
        ]
        var residency = PaintTileResidency(
            byteBudget: bytes * identities.count,
            nextUseEpoch: 9,
            entries: Dictionary(uniqueKeysWithValues: identities.map {
                ($0, .init(byteCount: bytes, lastUseEpoch: 4, pinCounts: [:]))
            })
        )

        #expect(try residency.evictUnpinned(to: 0) == [
            identity(layer: layerA, x: 0, y: 0, tileID: 1),
            identity(layer: layerA, x: 0, y: 0, tileID: 2),
            identity(layer: layerA, x: 1, y: 0, tileID: 4),
            identity(layer: layerA, x: 0, y: 1, tileID: 3),
            identity(layer: layerB, x: 0, y: 0, tileID: 1),
        ])
    }

    @Test
    func everyReasonAndNestedPinsPreventEvictionUntilBalanced() throws {
        let id = identity(layer: UUID(), x: 0, y: 0, tileID: 1)
        var residency = PaintTileResidency(byteBudget: bytes)
        _ = try residency.admit(id, byteCount: bytes, pinReasons: [])

        for reason in PaintTilePinReason.allCases {
            try residency.pin(id, reason: reason)
            try residency.pin(id, reason: reason)
        }
        #expect(residency.pinnedByteCount == bytes)
        #expect(try residency.evictUnpinned(to: 0).isEmpty)

        for reason in PaintTilePinReason.allCases {
            try residency.unpin(id, reason: reason)
        }
        #expect(residency.isPinned(id))
        #expect(try residency.evictUnpinned(to: 0).isEmpty)

        for reason in PaintTilePinReason.allCases {
            try residency.unpin(id, reason: reason)
        }
        #expect(!residency.isPinned(id))
        #expect(try residency.evictUnpinned(to: 0) == [id])
    }

    @Test
    func transactionalReserveFailureAtEveryAllocationIndexPreservesExactState() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surfaceID = UUID()
        let layerID = UUID()
        let size = PixelSize(width: 1024, height: 1024)
        let requested = [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 0, y: 1),
            PaintTileCoordinate(x: 1, y: 1),
        ]

        for failureIndex in requested.indices {
            let store = PaintTileStore(device: device, byteBudget: bytes * 6)
            let seed = try store.reserve(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: 7,
                pixelSize: size,
                coordinates: [PaintTileCoordinate(x: 3, y: 3)],
                pinReasons: [.visible]
            )
            try store.release(seed, surfaceID: surfaceID, currentGeneration: 7)
            let before = store.snapshot()

            #expect(throws: PaintTileStoreError.injectedAllocationFailure(reserveIndex: failureIndex)) {
                _ = try store.reserve(
                    surfaceID: surfaceID,
                    layerID: layerID,
                    generation: 7,
                    pixelSize: size,
                    coordinates: requested,
                    pinReasons: [.active, .dirty],
                    failureInjection: .init(failingAtReserveIndex: failureIndex)
                )
            }
            #expect(store.snapshot() == before)
        }
    }

    @Test
    func immutableNestedLeasesAreGenerationScopedAndUsePrivateRGBA16FTiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 2)
        let surfaceID = UUID()
        let layerID = UUID()
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let size = PixelSize(width: 512, height: 512)

        let active = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: 11,
            pixelSize: size,
            coordinates: [coordinate],
            pinReasons: [.active]
        )
        let visible = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: 11,
            pixelSize: size,
            coordinates: [coordinate],
            pinReasons: [.visible, .inFlight]
        )
        #expect(active.bindings.count == 1)
        #expect(active.bindings[0].identity == visible.bindings[0].identity)
        #expect(active.bindings[0].texture.pixelFormat == .rgba16Float)
        #expect(active.bindings[0].texture.storageMode == .private)
        #expect(active.bindings[0].texture.width == 256)
        #expect(active.bindings[0].texture.height == 256)
        #expect(store.snapshot().residentByteCount == bytes)

        try store.release(active, surfaceID: surfaceID, currentGeneration: 11)
        #expect(try store.applyMemoryPressure(targetResidentBytes: 0).evictedIdentities.isEmpty)
        let beforeStaleReturn = store.snapshot()
        #expect(throws: PaintTileStoreError.staleGeneration(expected: 12, actual: 11)) {
            try store.release(visible, surfaceID: surfaceID, currentGeneration: 12)
        }
        #expect(store.snapshot() == beforeStaleReturn)
        try store.release(visible, surfaceID: surfaceID, currentGeneration: 11)
        #expect(try store.applyMemoryPressure(targetResidentBytes: 0).evictedIdentities.isEmpty)
        #expect(store.snapshot().residentByteCount == 0)
    }

    @Test
    func overBudgetReservationIsTypedAndDoesNotMutateStore() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes)
        let before = store.snapshot()
        #expect(throws: PaintTileResidencyError.insufficientCapacity(
            requestedBytes: bytes * 2,
            byteBudget: bytes,
            pinnedBytes: 0
        )) {
            _ = try store.reserve(
                surfaceID: UUID(),
                layerID: UUID(),
                generation: 1,
                pixelSize: PixelSize(width: 512, height: 256),
                coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
                pinReasons: [.active]
            )
        }
        #expect(store.snapshot() == before)
    }

    @Test
    func replacementRejectsPeakTransferAboveExplicitHeadroomWithoutMutation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 5 - 1
        )
        let surfaceID = UUID()
        let layerID = UUID()
        let size = PixelSize(width: 512, height: 256)
        let old = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: 1,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            pinReasons: [.dirty]
        )
        try store.markModified(old, surfaceID: surfaceID, currentGeneration: 1)
        try store.release(old, surfaceID: surfaceID, currentGeneration: 1)
        let before = store.snapshot()

        #expect(throws: PaintTileStoreError.transferCapacityExceeded(
            requiredBytes: bytes * 5,
            capacityBytes: bytes * 5 - 1,
            residentBytes: bytes,
            allocationBytes: bytes,
            persistentZeroBytes: bytes,
            stagingBytes: bytes * 2
        )) {
            _ = try store.reserve(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: 1,
                pixelSize: size,
                coordinates: [.init(x: 1, y: 0)],
                pinReasons: [.active]
            )
        }
        #expect(store.snapshot() == before)
    }

    @Test
    func aggregateAdmissionWithZeroMaximumAndMaxAdditionalFailsClosed()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 3
        )
        let before = store.snapshot()

        #expect(throws: PaintTileStoreError.transferCapacityExceeded(
            requiredBytes: bytes * 2,
            capacityBytes: 0,
            residentBytes: 0,
            allocationBytes: bytes,
            persistentZeroBytes: bytes,
            stagingBytes: 0
        )) {
            _ = try store.reserveSortedUnique(
                surfaceID: UUID(),
                layerID: UUID(),
                generation: 1,
                pixelSize: PixelSize(width: 256, height: 256),
                coordinates: [.init(x: 0, y: 0)],
                pinReasons: [.active],
                aggregateTransferAdmission:
                    PaintTileAggregateTransferAdmission(
                        additionalPhysicalBytes: .max,
                        maximumPhysicalBytes: 0
                    )
            )
        }
        #expect(store.snapshot() == before)
    }

    @Test
    func replacementReportsBoundedPeakTextureAndStagingOwnership() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 5
        )
        let surfaceID = UUID()
        let layerID = UUID()
        let size = PixelSize(width: 512, height: 256)
        let old = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: 1,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            pinReasons: [.dirty]
        )
        try store.markModified(old, surfaceID: surfaceID, currentGeneration: 1)
        try store.release(old, surfaceID: surfaceID, currentGeneration: 1)

        let replacement = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: 1,
            pixelSize: size,
            coordinates: [.init(x: 1, y: 0)],
            pinReasons: [.active]
        )

        #expect(store.snapshot().lastTransferAccounting == PaintTileTransferAccounting(
            residentTextureBytesBefore: bytes,
            allocatedTextureBytes: bytes,
            persistentZeroAllocationBytes: 0,
            persistentZeroAllocationCount: 0,
            uploadStagingBytes: 0,
            readbackStagingBytes: bytes,
            capturedPayloadBytes: bytes,
            peakTrackedBytes: bytes * 5,
            capacityBytes: bytes * 5
        ))
        #expect(store.snapshot().residentByteCount == bytes)
        try store.release(replacement, surfaceID: surfaceID, currentGeneration: 1)
    }

    @Test
    func smallerLaterTransferCannotErasePhysicalPeakHighWater() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes * 2,
            transferByteCapacity: bytes * 9
        )
        let surfaceID = UUID()
        let layerID = UUID()
        let size = PixelSize(width: 1024, height: 256)
        let original = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: 1,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            pinReasons: [.dirty]
        )
        try store.markModified(
            original,
            surfaceID: surfaceID,
            currentGeneration: 1
        )
        try store.release(
            original,
            surfaceID: surfaceID,
            currentGeneration: 1
        )
        let replacement = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: 1,
            pixelSize: size,
            coordinates: [.init(x: 2, y: 0), .init(x: 3, y: 0)],
            pinReasons: [.active]
        )
        #expect(store.snapshot().lastTransferAccounting?.peakTrackedBytes
            == bytes * 9)
        try store.release(
            replacement,
            surfaceID: surfaceID,
            currentGeneration: 1
        )
        try store.retire(surfaceID: surfaceID, generation: 1)

        let smallerSurfaceID = UUID()
        let smaller = try store.reserve(
            surfaceID: smallerSurfaceID,
            layerID: layerID,
            generation: 2,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            pinReasons: [.active]
        )
        let afterSmallerTransfer = store.snapshot()
        #expect(afterSmallerTransfer.lastTransferAccounting?.peakTrackedBytes
            == bytes * 2)
        #expect(afterSmallerTransfer.transferPeakTrackedByteHighWater
            == bytes * 9)
        try store.release(
            smaller,
            surfaceID: smallerSurfaceID,
            currentGeneration: 2
        )
    }

    @Test
    func zeroSourceCapacityAndTextureAllocationFailuresAreAtomicAndRetryable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surfaceID = UUID()
        let layerID = UUID()
        let size = PixelSize(width: 512, height: 256)
        let capacityStore = PaintTileStore(
            device: device,
            byteBudget: bytes * 2,
            transferByteCapacity: bytes * 2
        )
        let beforeCapacity = capacityStore.snapshot()
        #expect(throws: PaintTileStoreError.transferCapacityExceeded(
            requiredBytes: bytes * 3,
            capacityBytes: bytes * 2,
            residentBytes: 0,
            allocationBytes: bytes * 2,
            persistentZeroBytes: bytes,
            stagingBytes: 0
        )) {
            _ = try capacityStore.reserve(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: 1,
                pixelSize: size,
                coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
                pinReasons: [.active]
            )
        }
        #expect(capacityStore.snapshot() == beforeCapacity)
        let capacityRetry = try capacityStore.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: 1,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            pinReasons: [.active]
        )
        #expect(capacityStore.snapshot().persistentZeroAllocationCount == 1)
        try capacityStore.release(
            capacityRetry,
            surfaceID: surfaceID,
            currentGeneration: 1
        )

        let allocationStore = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 2
        )
        let beforeAllocation = allocationStore.snapshot()
        #expect(throws: PaintTileStoreError.injectedAllocationFailure(
            reserveIndex: 0
        )) {
            _ = try allocationStore.reserve(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: 1,
                pixelSize: size,
                coordinates: [.init(x: 0, y: 0)],
                pinReasons: [.active],
                failureInjection: .init(failingAtReserveIndex: 0)
            )
        }
        #expect(allocationStore.snapshot() == beforeAllocation)
        let allocationRetry = try allocationStore.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: 1,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            pinReasons: [.active]
        )
        #expect(allocationStore.snapshot().persistentZeroAllocationCount == 1)
        try allocationStore.release(
            allocationRetry,
            surfaceID: surfaceID,
            currentGeneration: 1
        )
    }

    @Test
    func pressureReportsTypedUnsatisfiedPinnedResidency() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes)
        let surfaceID = UUID()
        let layerID = UUID()
        let lease = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: 3,
            pixelSize: PixelSize(width: 256, height: 256),
            coordinates: [.init(x: 0, y: 0)],
            pinReasons: [.inFlight]
        )

        #expect(try store.applyMemoryPressure(targetResidentBytes: 0) == .unsatisfied(
            targetBytes: 0,
            remainingResidentBytes: bytes,
            pinnedBytes: bytes,
            backingByteCount: 0,
            evictedIdentities: []
        ))
        try store.release(lease, surfaceID: surfaceID, currentGeneration: 3)
    }

    @Test
    func pressureIncludesOutstandingCoverageReservationLiability() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let coverageBytes = try #require(
            DepositionComponentCoverage.residentByteCount(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side
            )
        )
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes * 3
        )
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let lease = try surface.reserveSortedUniqueTiles(
            at: [coordinate],
            pinReasons: [.inFlight]
        )
        let provisional = try surface.makeProvisionalBindings(
            for: lease,
            coordinates: [coordinate],
            workspace: PaintTileProvisionalWorkspace(
                maximumBindingCount: 1
            )
        )

        #expect(try store.applyMemoryPressure(
            targetResidentBytes: bytes
        ) == .unsatisfied(
            targetBytes: bytes,
            remainingResidentBytes: bytes + coverageBytes,
            pinnedBytes: bytes + coverageBytes,
            backingByteCount: 0,
            evictedIdentities: []
        ))
        #expect(store.snapshot().residentByteCount == bytes)

        try surface.cancelProvisionalBindings(provisional)
        #expect(try store.applyMemoryPressure(
            targetResidentBytes: bytes
        ) == .satisfied(
            evictedIdentities: [],
            residentByteCount: bytes,
            backingByteCount: 0
        ))
        try surface.returnLease(lease)
    }

    @Test
    func provisionalLiabilityRejectsEscapedPayloadTransfersAtGlobalCap()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let coverageBytes = try #require(
            DepositionComponentCoverage.residentByteCount(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side
            )
        )
        let capacity = bytes * 5 + coverageBytes - 1
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes * 3,
            transferByteCapacity: capacity
        )
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let lease = try surface.reserveSortedUniqueTiles(
            at: [coordinate],
            pinReasons: [.inFlight]
        )
        try surface.markDirty(lease)
        let provider = try surface.makeExactReferenceProvider()
        let capture = try TiledRasterExactReferenceCapture(
            providers: [provider]
        )
        let reference = try #require(provider.references.first)
        let provisional = try surface.makeProvisionalBindings(
            for: lease,
            coordinates: [coordinate],
            workspace: .init(maximumBindingCount: 1)
        )
        let beforeTransfers = store.snapshot()
        #expect(beforeTransfers.provisionalByteCount
            == bytes + coverageBytes)

        #expect(throws: PaintTileStoreError.self) {
            _ = try capture.payload(reference, from: provider)
        }
        #expect(throws: PaintTileStoreError.self) {
            _ = try surface.payloadSnapshot()
        }
        #expect(store.snapshot() == beforeTransfers)

        try surface.cancelProvisionalBindings(provisional)
        #expect(try capture.payload(reference, from: provider)
            != .knownClear)
        let afterSuccess = store.snapshot()
        #expect(afterSuccess.lastTransferAccounting?.peakTrackedBytes
            == bytes * 4)
        #expect(afterSuccess.transferPeakTrackedByteHighWater <= capacity)
        capture.close()
        try surface.returnLease(lease)
    }

    @Test
    func backingCapacityRejectsProvisionalBeforeTextureAllocation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let coverageBytes = try #require(
            DepositionComponentCoverage.residentByteCount(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side
            )
        )
        let capacity = bytes * 4 + coverageBytes - 1
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes * 2,
            transferByteCapacity: capacity
        )
        let first = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let firstCoordinate = PaintTileCoordinate(x: 0, y: 0)
        let firstLease = try first.reserveSortedUniqueTiles(
            at: [firstCoordinate],
            pinReasons: [.inFlight]
        )
        try first.markDirty(firstLease)
        try first.returnLease(firstLease)
        _ = try first.applyMemoryPressure(targetResidentBytes: 0)
        #expect(store.snapshot().backingByteCount == bytes)

        let second = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let secondCoordinate = PaintTileCoordinate(x: 0, y: 0)
        let secondLease = try second.reserveSortedUniqueTiles(
            at: [secondCoordinate],
            pinReasons: [.inFlight]
        )
        let before = store.snapshot()
        let allocationAttempts =
            store.testingProvisionalTextureAllocationAttemptCount

        #expect(throws: PaintTileStoreError.self) {
            _ = try second.makeProvisionalBindings(
                for: secondLease,
                coordinates: [secondCoordinate],
                workspace: .init(maximumBindingCount: 1)
            )
        }
        #expect(store.testingProvisionalTextureAllocationAttemptCount
            == allocationAttempts)
        #expect(store.snapshot() == before)
        #expect(store.snapshot().transferPeakTrackedByteHighWater <= capacity)
        try second.returnLease(secondLease)
    }

    @Test
    func provisionalLiabilityRejectsEscapedBackingRehydrationAtGlobalCap()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let coverageBytes = try #require(
            DepositionComponentCoverage.residentByteCount(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side
            )
        )
        let capacity = bytes * 6 + coverageBytes - 1
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes * 3,
            transferByteCapacity: capacity
        )
        let escaped = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let escapedLease = try escaped.reserveSortedUniqueTiles(
            at: [coordinate],
            pinReasons: [.inFlight]
        )
        try escaped.markDirty(escapedLease)
        let provider = try escaped.makeExactReferenceProvider()
        let capture = try TiledRasterExactReferenceCapture(
            providers: [provider]
        )
        try escaped.returnLease(escapedLease)
        _ = try escaped.applyMemoryPressure(targetResidentBytes: 0)
        #expect(store.snapshot().backingByteCount == bytes)

        let active = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let activeLease = try active.reserveSortedUniqueTiles(
            at: [coordinate],
            pinReasons: [.inFlight]
        )
        let provisional = try active.makeProvisionalBindings(
            for: activeLease,
            coordinates: [coordinate],
            workspace: .init(maximumBindingCount: 1)
        )
        let beforeRehydrate = store.snapshot()

        #expect(throws: PaintTileStoreError.self) {
            _ = try provider.leaseExactReferences(
                provider.references,
                using: capture,
                pinReasons: [.visible]
            )
        }
        #expect(store.snapshot() == beforeRehydrate)
        #expect(store.snapshot().transferPeakTrackedByteHighWater <= capacity)

        try active.cancelProvisionalBindings(provisional)
        let rehydrated = try provider.leaseExactReferences(
            provider.references,
            using: capture,
            pinReasons: [.visible]
        )
        try rehydrated.returnLease()
        capture.close()
        try active.returnLease(activeLease)
    }

    @Test
    func committedClearWorkspaceKeepsSupersededCoverageInTransferLedger()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let coverageBytes = try #require(
            DepositionComponentCoverage.residentByteCount(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side
            )
        )
        let expectedPeak = bytes * 6 + coverageBytes * 2
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes * 3,
            transferByteCapacity: expectedPeak
        )
        let readbackSurface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let clearSurface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let readbackCoordinate = PaintTileCoordinate(x: 0, y: 0)
        let clearCoordinate = PaintTileCoordinate(x: 0, y: 0)
        let readbackLease = try readbackSurface.reserveSortedUniqueTiles(
            at: [readbackCoordinate],
            pinReasons: [.inFlight]
        )
        var clearLease = try clearSurface.reserveSortedUniqueTiles(
            at: [clearCoordinate],
            pinReasons: [.inFlight]
        )
        try readbackSurface.markDirty(readbackLease)
        try clearSurface.markDirty(clearLease)
        let initial = try clearSurface.makeProvisionalBindings(
            for: clearLease,
            coordinates: [clearCoordinate],
            modifiedCoordinates: [clearCoordinate],
            workspace: .init(maximumBindingCount: 1)
        )
        clearLease = try clearSurface.commitProvisionalBindings(
            initial,
            for: clearLease,
            modifiedCoordinates: [clearCoordinate],
            knownClearCoordinates: []
        )
        clearSurface.completeProvisionalBindings(initial)
        let readbackProvider = try readbackSurface
            .makeExactReferenceProvider()
        let capture = try TiledRasterExactReferenceCapture(
            providers: [readbackProvider]
        )
        let readbackReference = try #require(
            readbackProvider.references.first
        )

        let clearing = try clearSurface.makeProvisionalBindings(
            for: clearLease,
            coordinates: [clearCoordinate],
            modifiedCoordinates: [],
            workspace: .init(maximumBindingCount: 1)
        )
        clearLease = try clearSurface.commitProvisionalBindings(
            clearing,
            for: clearLease,
            modifiedCoordinates: [],
            knownClearCoordinates: [clearCoordinate]
        )
        #expect(store.snapshot().provisionalByteCount
            == bytes + coverageBytes * 2)

        _ = try capture.payload(readbackReference, from: readbackProvider)
        let duringCommittedWindow = store.snapshot()
        #expect(duringCommittedWindow.lastTransferAccounting?.peakTrackedBytes
            == expectedPeak)
        #expect(duringCommittedWindow.transferPeakTrackedByteHighWater
            == expectedPeak)
        clearSurface.completeProvisionalBindings(clearing)
        capture.close()
        try readbackSurface.returnLease(readbackLease)
        try clearSurface.returnLease(clearLease)
    }

    private func identity(
        layer: UUID,
        x: Int,
        y: Int,
        tileID: UInt64
    ) -> PaintTileIdentity {
        PaintTileIdentity(
            layerID: layer,
            coordinate: PaintTileCoordinate(x: x, y: y),
            tileID: PaintTileID(rawValue: tileID)
        )
    }
}
