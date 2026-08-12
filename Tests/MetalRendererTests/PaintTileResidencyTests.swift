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
