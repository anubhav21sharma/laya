import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Paint tile snapshot retention", .serialized)
struct PaintTileSnapshotRetentionTests {
    private let bytes = PaintTileDescriptor.residentByteCount

    @Test
    func retainedPendingTileAllowsOnlyTokenAuthorizedLeaseUntilFinalReturn()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 2)
        let surfaceID = UUID()
        let layerID = UUID()
        let generation: UInt64 = 7
        let initial = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            pixelSize: PixelSize(width: 256, height: 256),
            coordinates: [.init(x: 0, y: 0)],
            pinReasons: [.dirty]
        )
        let reference = try #require(store.references(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation
        ).first)
        let token = try store.retainSnapshotReferences([reference])
        let retirement = try store.prepareRetirement([reference])
        store.requestRetirement(retirement)
        try store.release(
            initial,
            surfaceID: surfaceID,
            currentGeneration: generation
        )

        #expect(store.snapshot().entries.map(\.identity) == [reference.identity])
        #expect(store.snapshot().pendingRetirementCount == 1)
        #expect(throws: PaintTileStoreError.staleTileReference) {
            _ = try store.reserveReferences(
                [reference],
                leaseSurfaceID: surfaceID,
                leaseLayerID: layerID,
                leaseGeneration: generation,
                pinReasons: [.visible]
            )
        }
        let retainedLease = try store.reserveRetainedReferences(
            [reference],
            token: token,
            leaseSurfaceID: surfaceID,
            leaseLayerID: layerID,
            leaseGeneration: generation,
            pinReasons: [.visible]
        )
        token.close()
        token.close()
        #expect(store.snapshot().entries.count == 1)

        try store.release(
            retainedLease,
            surfaceID: surfaceID,
            currentGeneration: generation
        )
        #expect(store.snapshot().entries.isEmpty)
        #expect(store.snapshot().pendingRetirementCount == 0)
    }

    @Test
    func captureMayCrossPreparedCommitAndCloseDeletesAfterPinsDrain()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try seedStore(device: device)
        let retirement = try fixture.store.prepareRetirement([
            fixture.reference,
        ])
        let token = try fixture.store.retainSnapshotReferences([
            fixture.reference,
        ])
        try fixture.store.release(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        fixture.store.requestRetirement(retirement)
        #expect(fixture.store.snapshot().entries.count == 1)
        token.close()
        #expect(fixture.store.snapshot().entries.isEmpty)
    }

    @Test
    func cancelingPreparedRetirementReappliesKnownClearRemovalAfterTokenClose()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try seedStore(device: device)
        let retirement = try fixture.store.prepareRetirement([
            fixture.reference,
        ])
        let token = try fixture.store.retainSnapshotReferences([
            fixture.reference,
        ])
        try fixture.store.release(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        token.close()
        #expect(fixture.store.snapshot().entries.count == 1)
        fixture.store.cancelRetirement(retirement)
        #expect(fixture.store.snapshot().entries.isEmpty)
    }

    @Test
    func pendingRetirementRejectsNewCaptureBitIdentically() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try seedStore(device: device)
        let retirement = try fixture.store.prepareRetirement([
            fixture.reference,
        ])
        fixture.store.requestRetirement(retirement)
        let before = fixture.store.snapshot()
        #expect(throws: PaintTileStoreError.staleTileReference) {
            _ = try fixture.store.retainSnapshotReferences([
                fixture.reference,
            ])
        }
        #expect(fixture.store.snapshot() == before)
        try fixture.store.release(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
    }

    @Test
    func overlappingTokensChargePayloadDebtOnceAndReleaseOnLastClose()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try seedStore(device: device)
        let first = try fixture.store.retainSnapshotReferences([
            fixture.reference,
        ])
        let second = try fixture.store.retainSnapshotReferences([
            fixture.reference,
        ])
        var snapshot = fixture.store.snapshot()
        #expect(snapshot.activeSnapshotTokenCount == 2)
        #expect(snapshot.aggregateSnapshotReferenceCount == 2)
        #expect(snapshot.snapshotPayloadDebtByteCount == bytes)
        #expect(snapshot.entries[0].snapshotRetainCount == 2)

        let retirement = try fixture.store.prepareRetirement([
            fixture.reference,
        ])
        fixture.store.requestRetirement(retirement)
        try fixture.store.release(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        first.close()
        snapshot = fixture.store.snapshot()
        #expect(snapshot.entries[0].snapshotRetainCount == 1)
        #expect(snapshot.snapshotPayloadDebtByteCount == bytes)
        second.close()
        #expect(fixture.store.snapshot().entries.isEmpty)
        #expect(fixture.store.snapshot().snapshotPayloadDebtByteCount == 0)
    }

    @Test
    func explicitLiabilityBudgetRetainsBackedSparseContentBeyondResidentBudget()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try seedBackedStore(
            device: device,
            snapshotPayloadLiabilityByteBudget: bytes * 3
        )
        #expect(fixture.store.byteBudget == bytes)
        #expect(fixture.references.count == 3)
        #expect(fixture.store.snapshot().residentByteCount == 0)
        #expect(fixture.store.snapshot().backingByteCount == bytes * 3)

        let token = try fixture.store.retainSnapshotReferences(
            fixture.references
        )
        #expect(
            fixture.store.snapshot().snapshotPayloadDebtByteCount == bytes * 3
        )
        token.close()
        #expect(fixture.store.snapshot().snapshotPayloadDebtByteCount == 0)
    }

    @Test
    func explicitLiabilityBudgetRejectsBackedCaptureTransactionally()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try seedBackedStore(
            device: device,
            snapshotPayloadLiabilityByteBudget: bytes * 2
        )
        let before = fixture.store.snapshot()

        #expect(throws: PaintTileStoreError.snapshotRetentionLimitExceeded(
            limit: .payloadDebtBytes,
            required: bytes * 3,
            maximum: bytes * 2
        )) {
            _ = try fixture.store.retainSnapshotReferences(
                fixture.references
            )
        }
        #expect(fixture.store.snapshot() == before)
    }

    @Test
    func backingStateChangesNeverPayDownRetainedPayloadLiability() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try seedStore(device: device)
        try fixture.store.markModified(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        let token = try fixture.store.retainSnapshotReferences([
            fixture.reference,
        ])
        #expect(fixture.store.snapshot().snapshotPayloadDebtByteCount == bytes)

        try fixture.store.markKnownClear(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation,
            coordinates: [fixture.reference.coordinate]
        )
        #expect(fixture.store.snapshot().snapshotPayloadDebtByteCount == bytes)
        token.close()
        #expect(fixture.store.snapshot().snapshotPayloadDebtByteCount == 0)
        try fixture.store.release(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
    }

    @Test
    func captureAcrossPreparedRetirementPreReservesPayloadLiability() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes,
            snapshotPayloadLiabilityByteBudget: bytes
        )
        let fixture = try seedStore(device: device, store: store)
        let retirement = try store.prepareRetirement([fixture.reference])

        let token = try store.retainSnapshotReferences([fixture.reference])
        #expect(store.snapshot().preparedRetirementCount == 1)
        #expect(store.snapshot().snapshotPayloadDebtByteCount == bytes)
        store.requestRetirement(retirement)
        try store.release(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        let retained = store.snapshot()
        #expect(retained.pendingRetirementCount == 1)
        #expect(retained.entries.count == 1)
        #expect(retained.snapshotPayloadDebtByteCount == bytes)

        token.close()
        let terminal = store.snapshot()
        #expect(terminal.pendingRetirementCount == 0)
        #expect(terminal.entries.isEmpty)
        #expect(terminal.snapshotPayloadDebtByteCount == 0)
    }

    @Test
    func failedAllocationLeavesRetainedDebtAndBackingStateUnchanged() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 5,
            snapshotRetentionLimits: limits(maximumPayloadDebtBytes: bytes)
        )
        let fixture = try seedStore(device: device, store: store)
        try store.markModified(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        let token = try store.retainSnapshotReferences([fixture.reference])
        try store.release(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        let before = store.snapshot()

        #expect(throws: PaintTileStoreError.injectedAllocationFailure(
            reserveIndex: 0
        )) {
            _ = try store.reserve(
                surfaceID: fixture.surfaceID,
                layerID: fixture.layerID,
                generation: fixture.generation,
                pixelSize: PixelSize(width: 512, height: 256),
                coordinates: [.init(x: 1, y: 0)],
                pinReasons: [.dirty],
                failureInjection: .init(failingAtReserveIndices: [0])
            )
        }
        #expect(store.snapshot() == before)
        token.close()
    }

    @Test
    func oneTokenRetainsExactSortedReferencesAcrossLayers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 2)
        let generation: UInt64 = 3
        let firstSurface = UUID()
        let secondSurface = UUID()
        let firstLayer = UUID()
        let secondLayer = UUID()
        let firstLease = try store.reserve(
            surfaceID: firstSurface,
            layerID: firstLayer,
            generation: generation,
            pixelSize: PixelSize(width: 256, height: 256),
            coordinates: [.init(x: 0, y: 0)],
            pinReasons: [.dirty]
        )
        let secondLease = try store.reserve(
            surfaceID: secondSurface,
            layerID: secondLayer,
            generation: generation,
            pixelSize: PixelSize(width: 512, height: 256),
            coordinates: [.init(x: 1, y: 0)],
            pinReasons: [.dirty]
        )
        let references = try (
            store.references(
                surfaceID: firstSurface,
                layerID: firstLayer,
                generation: generation
            ) + store.references(
                surfaceID: secondSurface,
                layerID: secondLayer,
                generation: generation
            )
        ).sorted()
        let token = try store.retainSnapshotReferences(references)
        #expect(store.snapshot().activeSnapshotTokenCount == 1)
        #expect(store.snapshot().aggregateSnapshotReferenceCount == 2)
        #expect(store.snapshot().snapshotPayloadDebtByteCount == bytes * 2)
        try store.release(
            firstLease,
            surfaceID: firstSurface,
            currentGeneration: generation
        )
        try store.release(
            secondLease,
            surfaceID: secondSurface,
            currentGeneration: generation
        )
        try store.retire(surfaceID: firstSurface, generation: generation)
        try store.retire(surfaceID: secondSurface, generation: generation)
        #expect(store.snapshot().entries.count == 2)
        token.close()
        #expect(store.snapshot().entries.isEmpty)
        #expect(store.snapshot().tileIndexEntryCount == 0)
    }

    @Test
    func compactRetentionMetadataUsesTileIDStrideAndExactCapBoundary()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let perReference = PaintTileStore.snapshotRetentionReferenceMetadataBytes
        let fixed = PaintTileStore.snapshotRetentionFixedMetadataBytes
        #expect(perReference == MemoryLayout<PaintTileID>.stride)
        #expect(
            fixed >= MemoryLayout<UInt64>.stride
                + MemoryLayout<ObjectIdentifier>.stride
                + MemoryLayout<[PaintTileID]>.stride
                + MemoryLayout<PaintTileSnapshotToken>.stride
        )
        let exact = fixed + perReference

        let rejectingStore = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 4,
            snapshotRetentionLimits: limits(maximumMetadataBytes: exact - 1)
        )
        let rejectingFixture = try seedStore(
            device: device,
            store: rejectingStore
        )
        let before = rejectingStore.snapshot()
        #expect(throws: PaintTileStoreError.snapshotRetentionLimitExceeded(
            limit: .metadataBytes,
            required: exact,
            maximum: exact - 1
        )) {
            _ = try rejectingStore.retainSnapshotReferences([
                rejectingFixture.reference,
            ])
        }
        #expect(rejectingStore.snapshot() == before)
        try rejectingStore.release(
            rejectingFixture.lease,
            surfaceID: rejectingFixture.surfaceID,
            currentGeneration: rejectingFixture.generation
        )

        let acceptingStore = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 4,
            snapshotRetentionLimits: limits(maximumMetadataBytes: exact)
        )
        let acceptingFixture = try seedStore(
            device: device,
            store: acceptingStore
        )
        let token = try acceptingStore.retainSnapshotReferences([
            acceptingFixture.reference,
        ])
        #expect(acceptingStore.snapshot().snapshotMetadataByteCount == exact)
        token.close()
        #expect(acceptingStore.snapshot().snapshotMetadataByteCount == 0)
        try acceptingStore.release(
            acceptingFixture.lease,
            surfaceID: acceptingFixture.surfaceID,
            currentGeneration: acceptingFixture.generation
        )
    }

    @Test
    func maximumShapeMembershipHasLogarithmicComparisonBound() {
        let count = 65_536
        let tileIDs = (0..<count).map {
            PaintTileID(rawValue: UInt64($0 * 2))
        }
        let perLookupBound = Int.bitWidth - count.leadingZeroBitCount
        var totalComparisons = 0
        for tileID in tileIDs {
            var comparisons = 0
            #expect(PaintTileStore.snapshotRetentionContains(
                tileID,
                in: tileIDs,
                comparisonCount: &comparisons
            ))
            #expect(comparisons <= perLookupBound)
            totalComparisons += comparisons
        }
        var missingComparisons = 0
        #expect(!PaintTileStore.snapshotRetentionContains(
            PaintTileID(rawValue: UInt64(count * 2 + 1)),
            in: tileIDs,
            comparisonCount: &missingComparisons
        ))
        #expect(missingComparisons <= perLookupBound)
        #expect(totalComparisons <= count * perLookupBound)
    }

    @Test
    func retainedDirtyBytesSurvivePressureAndPageInBitIdentically()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try seedStore(device: device)
        let payload = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 * 31) })
        try upload(
            payload,
            into: fixture.lease.bindings[0].texture,
            device: device
        )
        try fixture.store.markModified(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        let token = try fixture.store.retainSnapshotReferences([
            fixture.reference,
        ])
        #expect(fixture.store.snapshot().snapshotPayloadDebtByteCount == bytes)
        let retirement = try fixture.store.prepareRetirement([
            fixture.reference,
        ])
        fixture.store.requestRetirement(retirement)
        try fixture.store.release(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        _ = try fixture.store.applyMemoryPressure(targetResidentBytes: 0)
        let pressured = fixture.store.snapshot()
        #expect(pressured.residentByteCount == 0)
        #expect(pressured.backingByteCount == bytes)
        #expect(pressured.entries[0].backing == .rgba16Float(payload))
        #expect(pressured.snapshotPayloadDebtByteCount == bytes)

        let restored = try fixture.store.reserveRetainedReferences(
            [fixture.reference],
            token: token,
            leaseSurfaceID: fixture.surfaceID,
            leaseLayerID: fixture.layerID,
            leaseGeneration: fixture.generation,
            pinReasons: [.visible]
        )
        #expect(try download(
            restored.bindings[0].texture,
            device: device
        ) == payload)
        #expect(fixture.store.snapshot().snapshotPayloadDebtByteCount == bytes)
        token.close()
        #expect(fixture.store.snapshot().snapshotPayloadDebtByteCount == 0)
        try fixture.store.release(
            restored,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        #expect(fixture.store.snapshot().entries.isEmpty)
    }

    @Test
    func closeThenOutOfOrderReturnsAndFailedReturnRetryRemainExact()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 2)
        let surfaceID = UUID()
        let layerID = UUID()
        let generation: UInt64 = 9
        let initial = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            pixelSize: PixelSize(width: 512, height: 256),
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            pinReasons: [.dirty]
        )
        let references = try store.references(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation
        )
        let token = try store.retainSnapshotReferences(references)
        let retirement = try store.prepareRetirement(references)
        store.requestRetirement(retirement)
        try store.release(
            initial,
            surfaceID: surfaceID,
            currentGeneration: generation
        )
        let first = try store.reserveRetainedReferences(
            [references[0]],
            token: token,
            leaseSurfaceID: surfaceID,
            leaseLayerID: layerID,
            leaseGeneration: generation,
            pinReasons: [.visible]
        )
        let second = try store.reserveRetainedReferences(
            [references[1]],
            token: token,
            leaseSurfaceID: surfaceID,
            leaseLayerID: layerID,
            leaseGeneration: generation,
            pinReasons: [.visible]
        )
        token.close()
        try store.release(
            second,
            surfaceID: surfaceID,
            currentGeneration: generation
        )
        #expect(store.snapshot().entries.map(\.identity) == [
            references[0].identity,
        ])
        let beforeFailure = store.snapshot()
        #expect(throws: PaintTileStoreError.staleGeneration(
            expected: generation + 1,
            actual: generation
        )) {
            try store.release(
                first,
                surfaceID: surfaceID,
                currentGeneration: generation + 1
            )
        }
        #expect(store.snapshot() == beforeFailure)
        try store.release(
            first,
            surfaceID: surfaceID,
            currentGeneration: generation
        )
        #expect(store.snapshot().entries.isEmpty)
    }

    @Test
    func closedAndNonmemberCapabilitiesCannotAuthorizeABAOrForeignTiles()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 2)
        let surfaceID = UUID()
        let layerID = UUID()
        let generation: UInt64 = 4
        let initial = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            pixelSize: PixelSize(width: 512, height: 256),
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            pinReasons: [.dirty]
        )
        let references = try store.references(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation
        )
        let token = try store.retainSnapshotReferences([references[0]])
        #expect(throws: PaintTileStoreError.invalidSnapshotRetentionToken) {
            _ = try store.reserveRetainedReferences(
                [references[1]],
                token: token,
                leaseSurfaceID: surfaceID,
                leaseLayerID: layerID,
                leaseGeneration: generation,
                pinReasons: [.visible]
            )
        }
        try store.release(
            initial,
            surfaceID: surfaceID,
            currentGeneration: generation
        )
        try store.retire(surfaceID: surfaceID, generation: generation)
        token.close()
        #expect(store.snapshot().entries.isEmpty)

        let replacement = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            pixelSize: PixelSize(width: 512, height: 256),
            coordinates: [.init(x: 0, y: 0)],
            pinReasons: [.dirty]
        )
        let replacementReference = try #require(store.references(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation
        ).first)
        #expect(replacementReference.identity != references[0].identity)
        #expect(throws: PaintTileStoreError.invalidSnapshotRetentionToken) {
            _ = try store.reserveRetainedReferences(
                [replacementReference],
                token: token,
                leaseSurfaceID: surfaceID,
                leaseLayerID: layerID,
                leaseGeneration: generation,
                pinReasons: [.visible]
            )
        }
        try store.release(
            replacement,
            surfaceID: surfaceID,
            currentGeneration: generation
        )
    }

    @Test
    func captureAndAuthorizedReserveRejectMalformedForeignAndStaleInputs()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try seedStore(device: device, tileCount: 2)
        let references = try fixture.store.references(
            surfaceID: fixture.surfaceID,
            layerID: fixture.layerID,
            generation: fixture.generation
        )
        let before = fixture.store.snapshot()
        #expect(throws: PaintTileStoreError.duplicateReference) {
            _ = try fixture.store.retainSnapshotReferences([
                references[0], references[0],
            ])
        }
        #expect(throws: PaintTileStoreError.unsortedReference) {
            _ = try fixture.store.retainSnapshotReferences([
                references[1], references[0],
            ])
        }
        let foreignStore = PaintTileStore(
            device: device,
            byteBudget: bytes * 2
        )
        let foreignFixture = try seedStore(
            device: device,
            store: foreignStore
        )
        #expect(throws: PaintTileStoreError.foreignStoreReference) {
            _ = try fixture.store.retainSnapshotReferences([
                foreignFixture.reference,
            ])
        }
        #expect(fixture.store.snapshot() == before)

        let token = try fixture.store.retainSnapshotReferences([
            references[0],
        ])
        #expect(throws: PaintTileStoreError.invalidSnapshotRetentionToken) {
            _ = try foreignStore.reserveRetainedReferences(
                [foreignFixture.reference],
                token: token,
                leaseSurfaceID: foreignFixture.surfaceID,
                leaseLayerID: foreignFixture.layerID,
                leaseGeneration: foreignFixture.generation,
                pinReasons: [.visible]
            )
        }
        let stale = references[0].replacing(identity: references[1].identity)
        #expect(throws: PaintTileStoreError.invalidSnapshotRetentionToken) {
            _ = try fixture.store.reserveRetainedReferences(
                [stale],
                token: token,
                leaseSurfaceID: fixture.surfaceID,
                leaseLayerID: fixture.layerID,
                leaseGeneration: fixture.generation,
                pinReasons: [.visible]
            )
        }
        token.close()
        try fixture.store.release(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        try foreignStore.release(
            foreignFixture.lease,
            surfaceID: foreignFixture.surfaceID,
            currentGeneration: foreignFixture.generation
        )
    }

    @Test
    func everyConfiguredCaptureLimitFailsBitIdenticallyAtBoundary()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        struct Case {
            let limit: PaintTileSnapshotRetentionLimit
            let limits: PaintTileSnapshotRetentionLimits
            let required: Int
            let maximum: Int
        }
        let cases = [
            Case(
                limit: .activeTokens,
                limits: limits(maximumActiveTokenCount: 0),
                required: 1,
                maximum: 0
            ),
            Case(
                limit: .referencesPerToken,
                limits: limits(maximumReferencesPerToken: 0),
                required: 1,
                maximum: 0
            ),
            Case(
                limit: .aggregateReferences,
                limits: limits(maximumAggregateReferenceCount: 0),
                required: 1,
                maximum: 0
            ),
            Case(
                limit: .metadataBytes,
                limits: limits(
                    maximumMetadataBytes:
                        PaintTileStore.snapshotRetentionFixedMetadataBytes
                            + PaintTileStore
                                .snapshotRetentionReferenceMetadataBytes
                            - 1
                ),
                required:
                    PaintTileStore.snapshotRetentionFixedMetadataBytes
                        + PaintTileStore
                            .snapshotRetentionReferenceMetadataBytes,
                maximum:
                    PaintTileStore.snapshotRetentionFixedMetadataBytes
                        + PaintTileStore
                            .snapshotRetentionReferenceMetadataBytes
                        - 1
            ),
            Case(
                limit: .payloadDebtBytes,
                limits: limits(maximumPayloadDebtBytes: bytes - 1),
                required: bytes,
                maximum: bytes - 1
            ),
        ]
        for testCase in cases {
            let store = PaintTileStore(
                device: device,
                byteBudget: bytes,
                transferByteCapacity: bytes * 4,
                snapshotRetentionLimits: testCase.limits
            )
            let fixture = try seedStore(device: device, store: store)
            let before = store.snapshot()
            #expect(throws: PaintTileStoreError
                .snapshotRetentionLimitExceeded(
                    limit: testCase.limit,
                    required: testCase.required,
                    maximum: testCase.maximum
                )) {
                _ = try store.retainSnapshotReferences([fixture.reference])
            }
            #expect(store.snapshot() == before)
            try store.release(
                fixture.lease,
                surfaceID: fixture.surfaceID,
                currentGeneration: fixture.generation
            )
        }
    }

    @Test
    func indexAndUniquePayloadDebtLimitsAreTransactionalAndReusable()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let indexStore = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 4,
            snapshotRetentionLimits: limits(maximumIndexEntryCount: 0)
        )
        let beforeIndex = indexStore.snapshot()
        #expect(throws: PaintTileStoreError.snapshotRetentionLimitExceeded(
            limit: .indexEntries,
            required: 1,
            maximum: 0
        )) {
            _ = try indexStore.reserve(
                surfaceID: UUID(),
                layerID: UUID(),
                generation: 1,
                pixelSize: PixelSize(width: 256, height: 256),
                coordinates: [.init(x: 0, y: 0)],
                pinReasons: [.dirty]
            )
        }
        #expect(indexStore.snapshot() == beforeIndex)

        let debtStore = PaintTileStore(
            device: device,
            byteBudget: bytes * 2,
            transferByteCapacity: bytes * 7,
            snapshotRetentionLimits: limits(
                maximumPayloadDebtBytes: bytes
            )
        )
        let fixture = try seedStore(
            device: device,
            store: debtStore,
            tileCount: 2
        )
        let references = try debtStore.references(
            surfaceID: fixture.surfaceID,
            layerID: fixture.layerID,
            generation: fixture.generation
        )
        let first = try debtStore.retainSnapshotReferences([references[0]])
        let overlap = try debtStore.retainSnapshotReferences([references[0]])
        let beforeDebtFailure = debtStore.snapshot()
        #expect(throws: PaintTileStoreError.snapshotRetentionLimitExceeded(
            limit: .payloadDebtBytes,
            required: bytes * 2,
            maximum: bytes
        )) {
            _ = try debtStore.retainSnapshotReferences([references[1]])
        }
        #expect(debtStore.snapshot() == beforeDebtFailure)
        overlap.close()
        first.close()
        try debtStore.release(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
    }

    @Test
    func retireAtomicallyDefersBothNamespacesUntilAggregateTokenCloses()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 2)
        let first = try seedStore(device: device, store: store)
        let second = try seedStore(device: device, store: store)
        let references = ([first.reference, second.reference]).sorted()
        let token = try store.retainSnapshotReferences(references)
        try store.release(
            first.lease,
            surfaceID: first.surfaceID,
            currentGeneration: first.generation
        )
        try store.release(
            second.lease,
            surfaceID: second.surfaceID,
            currentGeneration: second.generation
        )
        try store.retireAtomically(
            authoritativeSurfaceID: first.surfaceID,
            predictionSurfaceID: second.surfaceID,
            generation: first.generation
        )
        #expect(store.snapshot().pendingRetirementCount == 2)
        token.close()
        #expect(store.snapshot().entries.isEmpty)
        #expect(store.snapshot().tileIndexEntryCount == 0)
    }

    @Test
    func tokenAuthorizesExactPreparedMembersWhileOrdinaryAdmissionStaysClosed()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try seedStore(device: device)
        let retirement = try fixture.store.prepareRetirement([
            fixture.reference,
        ])
        let token = try fixture.store.retainSnapshotReferences([
            fixture.reference,
        ])
        #expect(throws: PaintTileStoreError.staleTileReference) {
            _ = try fixture.store.reserveReferences(
                [fixture.reference],
                leaseSurfaceID: fixture.surfaceID,
                leaseLayerID: fixture.layerID,
                leaseGeneration: fixture.generation,
                pinReasons: [.visible]
            )
        }
        let retained = try fixture.store.reserveRetainedReferences(
            [fixture.reference],
            token: token,
            leaseSurfaceID: fixture.surfaceID,
            leaseLayerID: fixture.layerID,
            leaseGeneration: fixture.generation,
            pinReasons: [.visible]
        )
        fixture.store.cancelRetirement(retirement)
        token.close()
        try fixture.store.release(
            retained,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        try fixture.store.release(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        #expect(fixture.store.snapshot().entries.isEmpty)
    }

    @Test
    func tokenAndPerRecordCountOverflowFailuresAreBitIdentical()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let tokenOverflowStore = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 4,
            snapshotRetentionLimits: limits(),
            snapshotTokenDeinitDiagnostic: { _ in },
            initialSnapshotRetentionTokenID: .max
        )
        let tokenFixture = try seedStore(
            device: device,
            store: tokenOverflowStore
        )
        let beforeToken = tokenOverflowStore.snapshot()
        #expect(throws: PaintTileStoreError
            .snapshotRetentionTokenIdentityOverflow) {
            _ = try tokenOverflowStore.retainSnapshotReferences([
                tokenFixture.reference,
            ])
        }
        #expect(tokenOverflowStore.snapshot() == beforeToken)
        try tokenOverflowStore.release(
            tokenFixture.lease,
            surfaceID: tokenFixture.surfaceID,
            currentGeneration: tokenFixture.generation
        )

        let countStore = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 4,
            snapshotRetentionLimits: limits(),
            snapshotTokenDeinitDiagnostic: { _ in },
            snapshotRetainCountMaximum: 1
        )
        let countFixture = try seedStore(device: device, store: countStore)
        let first = try countStore.retainSnapshotReferences([
            countFixture.reference,
        ])
        let beforeCount = countStore.snapshot()
        #expect(throws: PaintTileStoreError.snapshotRetentionCountOverflow(
            countFixture.reference.identity.tileID
        )) {
            _ = try countStore.retainSnapshotReferences([
                countFixture.reference,
            ])
        }
        #expect(countStore.snapshot() == beforeCount)
        first.close()
        try countStore.release(
            countFixture.lease,
            surfaceID: countFixture.surfaceID,
            currentGeneration: countFixture.generation
        )
    }

    @Test
    func droppingUnclosedTokenDiagnosesButNeverReleasesStoreOwnership()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let diagnostic = DiagnosticCounter()
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 4,
            snapshotRetentionLimits: limits(),
            snapshotTokenDeinitDiagnostic: { _ in diagnostic.increment() }
        )
        let fixture = try seedStore(device: device, store: store)
        var token: PaintTileSnapshotToken? = try store
            .retainSnapshotReferences([fixture.reference])
        weak let weakToken = token
        try store.release(
            fixture.lease,
            surfaceID: fixture.surfaceID,
            currentGeneration: fixture.generation
        )
        #expect(token != nil)
        token = nil
        #expect(weakToken == nil)
        #expect(diagnostic.value == 1)
        let afterDrop = store.snapshot()
        #expect(afterDrop.activeSnapshotTokenCount == 1)
        #expect(afterDrop.entries[0].snapshotRetainCount == 1)
        #expect(afterDrop.snapshotPayloadDebtByteCount == bytes)
    }

    @Test
    func closeVersusReserveIsLinearizableAndIssuedLeaseAlwaysReturns()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        for _ in 0..<32 {
            let fixture = try seedStore(device: device)
            let token = try fixture.store.retainSnapshotReferences([
                fixture.reference,
            ])
            let retirement = try fixture.store.prepareRetirement([
                fixture.reference,
            ])
            fixture.store.requestRetirement(retirement)
            try fixture.store.release(
                fixture.lease,
                surfaceID: fixture.surfaceID,
                currentGeneration: fixture.generation
            )

            let result = LeaseRaceResult()
            let start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                token.close()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                do {
                    result.install(.success(try fixture.store
                        .reserveRetainedReferences(
                            [fixture.reference],
                            token: token,
                            leaseSurfaceID: fixture.surfaceID,
                            leaseLayerID: fixture.layerID,
                            leaseGeneration: fixture.generation,
                            pinReasons: [.visible]
                        )))
                } catch {
                    result.install(.failure(error))
                }
                group.leave()
            }
            start.signal()
            start.signal()
            group.wait()

            switch try #require(result.value) {
            case let .success(lease):
                try fixture.store.release(
                    lease,
                    surfaceID: fixture.surfaceID,
                    currentGeneration: fixture.generation
                )
            case let .failure(error):
                #expect(error as? PaintTileStoreError
                    == .invalidSnapshotRetentionToken)
            }
            #expect(fixture.store.snapshot().entries.isEmpty)
            #expect(fixture.store.snapshot().activeSnapshotTokenCount == 0)
        }
    }

    private struct SeedFixture {
        let store: PaintTileStore
        let surfaceID: UUID
        let layerID: UUID
        let generation: UInt64
        let lease: PaintTileLease
        let reference: PaintTileReference
    }

    private final class DiagnosticCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private final class LeaseRaceResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<PaintTileLease, Error>?

        var value: Result<PaintTileLease, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func install(_ value: Result<PaintTileLease, Error>) {
            lock.lock()
            precondition(stored == nil)
            stored = value
            lock.unlock()
        }
    }

    private struct BackedStoreFixture {
        let store: PaintTileStore
        let references: [PaintTileReference]
    }

    private func seedBackedStore(
        device: any MTLDevice,
        snapshotPayloadLiabilityByteBudget: Int
    ) throws -> BackedStoreFixture {
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 5,
            snapshotPayloadLiabilityByteBudget:
                snapshotPayloadLiabilityByteBudget
        )
        let surfaceID = UUID()
        let layerID = UUID()
        let generation: UInt64 = 11
        let pixelSize = PixelSize(width: 256 * 3, height: 256)
        for index in 0..<3 {
            let lease = try store.reserve(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: generation,
                pixelSize: pixelSize,
                coordinates: [.init(x: index, y: 0)],
                pinReasons: [.dirty]
            )
            let payload = Data(
                repeating: UInt8(index + 1),
                count: bytes
            )
            try upload(payload, into: lease.bindings[0].texture, device: device)
            try store.markModified(
                lease,
                surfaceID: surfaceID,
                currentGeneration: generation
            )
            try store.release(
                lease,
                surfaceID: surfaceID,
                currentGeneration: generation
            )
            _ = try store.applyMemoryPressure(targetResidentBytes: 0)
        }
        return BackedStoreFixture(
            store: store,
            references: try store.references(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: generation
            )
        )
    }

    private func seedStore(
        device: any MTLDevice,
        store providedStore: PaintTileStore? = nil,
        tileCount: Int = 1
    ) throws -> SeedFixture {
        let store = providedStore
            ?? PaintTileStore(device: device, byteBudget: bytes * 2)
        let surfaceID = UUID()
        let layerID = UUID()
        let generation: UInt64 = 7
        let lease = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            pixelSize: PixelSize(width: tileCount * 256, height: 256),
            coordinates: (0..<tileCount).map { .init(x: $0, y: 0) },
            pinReasons: [.dirty]
        )
        let reference = try #require(store.references(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation
        ).first)
        return SeedFixture(
            store: store,
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            lease: lease,
            reference: reference
        )
    }

    private func limits(
        maximumActiveTokenCount: Int = 8,
        maximumReferencesPerToken: Int = 8,
        maximumAggregateReferenceCount: Int = 16,
        maximumIndexEntryCount: Int = 16,
        maximumMetadataBytes: Int = 4_096,
        maximumPayloadDebtBytes: Int? = nil
    ) -> PaintTileSnapshotRetentionLimits {
        PaintTileSnapshotRetentionLimits(
            maximumActiveTokenCount: maximumActiveTokenCount,
            maximumReferencesPerToken: maximumReferencesPerToken,
            maximumAggregateReferenceCount: maximumAggregateReferenceCount,
            maximumIndexEntryCount: maximumIndexEntryCount,
            maximumMetadataBytes: maximumMetadataBytes,
            maximumPayloadDebtBytes: maximumPayloadDebtBytes ?? bytes * 16
        )
    }

    private func upload(
        _ bytes: Data,
        into texture: any MTLTexture,
        device: any MTLDevice
    ) throws {
        let buffer = try #require(device.makeBuffer(
            bytes: Array(bytes),
            length: bytes.count,
            options: .storageModeShared
        ))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(
            from: buffer,
            sourceOffset: 0,
            sourceBytesPerRow: PaintTileDescriptor.side * 8,
            sourceBytesPerImage: bytes.count,
            sourceSize: MTLSize(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side,
                depth: 1
            ),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
    }

    private func download(
        _ texture: any MTLTexture,
        device: any MTLDevice
    ) throws -> Data {
        let buffer = try #require(device.makeBuffer(
            length: bytes,
            options: .storageModeShared
        ))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side,
                depth: 1
            ),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: PaintTileDescriptor.side * 8,
            destinationBytesPerImage: bytes
        )
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        return Data(bytes: buffer.contents(), count: bytes)
    }
}
