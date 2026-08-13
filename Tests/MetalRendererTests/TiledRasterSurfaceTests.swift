import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Tiled raster surface", .serialized)
struct TiledRasterSurfaceTests {
    private let bytes = PaintTileDescriptor.residentByteCount

    @Test
    func committedProvisionalRollbackRestoresLogicalSurfaceAndAccounting()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let coverageBytes = try #require(
            DepositionComponentCoverage.residentByteCount(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side
            )
        )
        let store = PaintTileStore(device: device, byteBudget: bytes * 5)
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        var lease = try surface.reserveSortedUniqueTiles(
            at: [coordinate],
            pinReasons: [.inFlight]
        )
        let first = try surface.makeProvisionalBindings(
            for: lease,
            coordinates: [coordinate],
            modifiedCoordinates: [coordinate],
            workspace: .init(maximumBindingCount: 1)
        )
        lease = try surface.commitProvisionalBindings(
            first,
            for: lease,
            modifiedCoordinates: [coordinate],
            knownClearCoordinates: []
        )
        surface.completeProvisionalBindings(first)
        let priorTexture = try #require(lease.bindings.first?.texture)
        let priorRevision = surface.revision
        let priorDirtyCoordinates = surface.dirtyTileCoordinates
        let priorProvider = try surface.makeExactReferenceProvider()
        let priorStore = store.snapshot()

        let clearing = try surface.makeProvisionalBindings(
            for: lease,
            coordinates: [coordinate],
            modifiedCoordinates: [],
            workspace: .init(maximumBindingCount: 1)
        )
        lease = try surface.commitProvisionalBindings(
            clearing,
            for: lease,
            modifiedCoordinates: [],
            knownClearCoordinates: [coordinate]
        )
        #expect(surface.dirtyTileCoordinates.isEmpty)
        #expect(store.snapshot().componentCoverageByteCount == 0)

        try surface.rollbackCommittedProvisionalBindings(
            clearing,
            for: lease,
            restoringRevision: priorRevision,
            dirtyCoordinates: priorDirtyCoordinates
        )

        #expect(surface.revision == priorRevision)
        #expect(surface.dirtyTileCoordinates == priorDirtyCoordinates)
        #expect(try surface.makeExactReferenceProvider().references
            == priorProvider.references)
        let restoredStore = store.snapshot()
        #expect(restoredStore.componentCoverageByteCount == coverageBytes)
        #expect(restoredStore.residentByteCount == priorStore.residentByteCount)
        let restoredEntry = try #require(restoredStore.entries.first)
        #expect(restoredEntry.hasComponentCoverageTexture)
        #expect(restoredEntry.pinCounts[.active] == 1)
        #expect(restoredEntry.backing == priorStore.entries.first?.backing)
        #expect(restoredStore.provisionalReservationCount == 1)

        let restoredLease = try surface.leaseExistingTiles(
            at: [coordinate],
            pinReasons: [.visible]
        )
        let restoredTexture = try #require(
            restoredLease.bindings.first?.texture
        )
        let restoredExactTexture = (restoredTexture as AnyObject)
            === (priorTexture as AnyObject)
        #expect(restoredExactTexture)
        try surface.returnLease(restoredLease)

        try surface.cancelProvisionalBindings(clearing)
        try surface.returnLease(lease)
        #expect(store.snapshot().provisionalReservationCount == 0)
    }

    @Test
    func exactCaptureUsesOneAggregateTokenForEveryProviderOnOneStore()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 3)
        let layerID = UUID()
        let size = PixelSize(width: 256, height: 256)
        let surfaces = (0..<3).map { _ in
            TiledRasterSurface(
                store: store,
                layerID: layerID,
                pixelSize: size,
                generation: 7
            )
        }
        for surface in surfaces {
            let lease = try surface.reserveTiles(
                at: [.init(x: 0, y: 0)],
                pinReasons: [.dirty]
            )
            try surface.markDirty(lease)
            try surface.returnLease(lease)
        }
        let providers = try surfaces.map {
            try $0.makeExactReferenceProvider()
        }
        let capture = try TiledRasterExactReferenceCapture(
            providers: providers
        )

        var snapshot = store.snapshot()
        #expect(snapshot.activeSnapshotTokenCount == 1)
        #expect(snapshot.aggregateSnapshotReferenceCount == 3)
        let bound = try providers[0].leaseExactReferences(
            providers[0].references,
            using: capture,
            pinReasons: [.visible, .inFlight]
        )
        capture.close()
        snapshot = store.snapshot()
        #expect(snapshot.activeSnapshotTokenCount == 0)
        #expect(snapshot.activeLeaseCount == 1)
        try bound.returnLease()
        #expect(store.snapshot().activeLeaseCount == 0)
    }

    @Test
    func selectedEntitlementRetainsOnlySelectedDebtButPreservesFullIdentity()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 3)
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 768, height: 256),
            generation: 11
        )
        let seed = try surface.reserveTiles(
            at: (0..<3).map { .init(x: $0, y: 0) },
            pinReasons: [.dirty]
        )
        try surface.markDirty(seed)
        try surface.returnLease(seed)

        let full = try surface.makeExactReferenceProvider()
        let selected = [full.identityReferences[0]]
        let provider = try full.restrictingEntitlement(to: selected)
        let capture = try TiledRasterExactReferenceCapture(
            providers: [provider]
        )

        #expect(provider.identityReferences.count == 3)
        #expect(provider.entitledReferences == selected)
        #expect(store.snapshot().activeSnapshotTokenCount == 1)
        #expect(store.snapshot().aggregateSnapshotReferenceCount == 1)
        #expect(throws: TiledRasterSurfaceError.exactReferenceNotCaptured) {
            _ = try provider.leaseExactReferences(
                [provider.identityReferences[1]],
                using: capture,
                pinReasons: [.visible]
            )
        }
        let lease = try provider.leaseExactReferences(
            selected,
            using: capture,
            pinReasons: [.visible]
        )
        capture.close()
        try lease.returnLease()
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
        #expect(store.snapshot().activeLeaseCount == 0)
    }

    @Test
    func exactCaptureBorrowAcceptsRestrictedProviderFromCapturedLineage()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 2)
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 512, height: 256)
        )
        let seed = try surface.reserveTiles(
            at: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            pinReasons: [.dirty]
        )
        try surface.markDirty(seed)
        try surface.returnLease(seed)
        let root = try surface.makeExactReferenceProvider()
        let selected = [root.references[0]]
        let restricted = try root.restrictingEntitlement(to: selected)
        let capture = try TiledRasterExactReferenceCapture(providers: [root])

        let borrow = try capture.borrowing(providers: [restricted])
        let lease = try restricted.leaseExactReferences(
            selected,
            using: borrow,
            pinReasons: [.visible]
        )

        borrow.close()
        capture.close()
        try lease.returnLease()
        let terminal = store.snapshot()
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(terminal.activeLeaseCount == 0)
    }

    @Test
    func exactCaptureBorrowRejectsUncapturedAndWiderLineageAuthority()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 2)
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 512, height: 256)
        )
        let seed = try surface.reserveTiles(
            at: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            pinReasons: [.dirty]
        )
        try surface.markDirty(seed)
        try surface.returnLease(seed)
        let firstLineage = try surface.makeExactReferenceProvider()
        let secondLineage = try surface.makeExactReferenceProvider()
        let firstOnly = try firstLineage.restrictingEntitlement(
            to: [firstLineage.references[0]]
        )
        let secondOnly = try secondLineage.restrictingEntitlement(
            to: [secondLineage.references[1]]
        )
        let capture = try TiledRasterExactReferenceCapture(
            providers: [firstOnly, secondOnly]
        )

        #expect(throws: TiledRasterSurfaceError.providerNotCaptured) {
            let uncapturedLineage = try surface.makeExactReferenceProvider()
            _ = try capture.borrowing(providers: [uncapturedLineage])
        }
        #expect(throws: TiledRasterSurfaceError.exactReferenceNotCaptured) {
            let widerSibling = try firstLineage.restrictingEntitlement(
                to: [firstLineage.references[1]]
            )
            _ = try capture.borrowing(providers: [widerSibling])
        }
        let retained = store.snapshot()
        #expect(retained.activeSnapshotTokenCount == 1)
        #expect(retained.aggregateSnapshotReferenceCount == 2)
        capture.close()
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
    }

    @Test
    func exactCaptureUnionsCapturedSiblingsWithinOneLineage() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 2)
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 512, height: 256)
        )
        let seed = try surface.reserveTiles(
            at: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            pinReasons: [.dirty]
        )
        try surface.markDirty(seed)
        try surface.returnLease(seed)
        let root = try surface.makeExactReferenceProvider()
        let first = try root.restrictingEntitlement(to: [root.references[0]])
        let second = try root.restrictingEntitlement(to: [root.references[1]])
        let capture = try TiledRasterExactReferenceCapture(
            providers: [first, second]
        )
        let wider = try root.restrictingEntitlement(to: root.references)

        let borrow = try capture.borrowing(providers: [wider])
        let lease = try wider.leaseExactReferences(
            root.references,
            using: borrow,
            pinReasons: [.visible]
        )

        borrow.close()
        capture.close()
        try lease.returnLease()
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
        #expect(store.snapshot().activeLeaseCount == 0)
    }

    @Test
    func emptyCapturedLineageCanBeBorrowedWithoutTokenCapacity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes)
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let root = try surface.makeExactReferenceProvider()
        let empty = try root.restrictingEntitlement(to: [])
        let capture = try TiledRasterExactReferenceCapture(providers: [empty])

        let borrow = try capture.borrowing(providers: [empty])
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
        borrow.close()
        capture.close()
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
    }

    @Test
    func captureCloseDefersTokensForLiveBorrowAndRejectsLaterBorrow()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes)
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let seed = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)], pinReasons: [.dirty]
        )
        try surface.markDirty(seed)
        try surface.returnLease(seed)
        let provider = try surface.makeExactReferenceProvider()
        let capture = try TiledRasterExactReferenceCapture(providers: [provider])
        let borrow = try capture.borrowing(providers: [provider])

        capture.close()
        #expect(store.snapshot().activeSnapshotTokenCount == 1)
        #expect(throws: TiledRasterSurfaceError.exactReferenceCaptureClosed) {
            _ = try capture.borrowing(providers: [provider])
        }
        let lease = try provider.leaseExactReferences(
            provider.references,
            using: borrow,
            pinReasons: [.visible]
        )
        borrow.close()
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
        #expect(store.snapshot().activeLeaseCount == 1)
        try lease.returnLease()
        #expect(store.snapshot().activeLeaseCount == 0)
    }

    @Test
    func captureCloseWaitsForEveryBorrowAndBorrowCloseIsIdempotent()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes)
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let seed = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)], pinReasons: [.dirty]
        )
        try surface.markDirty(seed)
        try surface.returnLease(seed)
        let provider = try surface.makeExactReferenceProvider()
        let capture = try TiledRasterExactReferenceCapture(providers: [provider])
        let first = try capture.borrowing(providers: [provider])
        let second = try capture.borrowing(providers: [provider])

        capture.close()
        first.close()
        #expect(store.snapshot().activeSnapshotTokenCount == 1)
        async let closeA: Void = second.close()
        async let closeB: Void = second.close()
        _ = await (closeA, closeB)
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
    }

    @Test
    func borrowAndCaptureCloseRaceNeverStrandsSnapshotRetention()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        for _ in 0..<32 {
            let store = PaintTileStore(device: device, byteBudget: bytes)
            let surface = TiledRasterSurface(
                store: store,
                layerID: UUID(),
                pixelSize: PixelSize(width: 256, height: 256)
            )
            let seed = try surface.reserveTiles(
                at: [.init(x: 0, y: 0)], pinReasons: [.dirty]
            )
            try surface.markDirty(seed)
            try surface.returnLease(seed)
            let provider = try surface.makeExactReferenceProvider()
            let capture = try TiledRasterExactReferenceCapture(
                providers: [provider]
            )

            let borrowTask = Task {
                try capture.borrowing(providers: [provider])
            }
            let closeTask = Task { capture.close() }
            do {
                let borrow = try await borrowTask.value
                borrow.close()
            } catch {
                #expect(error as? TiledRasterSurfaceError
                    == .exactReferenceCaptureClosed)
            }
            await closeTask.value
            #expect(store.snapshot().activeSnapshotTokenCount == 0)
            #expect(store.snapshot().activeLeaseCount == 0)
        }
    }

    @Test
    func borrowReserveAndCloseRaceNeverUsesClosedAuthorityOrLeaksLease()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        for _ in 0..<32 {
            let store = PaintTileStore(device: device, byteBudget: bytes)
            let surface = TiledRasterSurface(
                store: store,
                layerID: UUID(),
                pixelSize: PixelSize(width: 256, height: 256)
            )
            let seed = try surface.reserveTiles(
                at: [.init(x: 0, y: 0)], pinReasons: [.dirty]
            )
            try surface.markDirty(seed)
            try surface.returnLease(seed)
            let provider = try surface.makeExactReferenceProvider()
            let capture = try TiledRasterExactReferenceCapture(
                providers: [provider]
            )
            let borrow = try capture.borrowing(providers: [provider])

            let leaseTask = Task {
                try provider.leaseExactReferences(
                    provider.references,
                    using: borrow,
                    pinReasons: [.visible]
                )
            }
            let closeTask = Task { borrow.close() }
            do {
                let lease = try await leaseTask.value
                try lease.returnLease()
            } catch {
                #expect(error as? TiledRasterSurfaceError
                    == .exactReferenceCaptureClosed)
            }
            await closeTask.value
            capture.close()
            #expect(store.snapshot().activeSnapshotTokenCount == 0)
            #expect(store.snapshot().activeLeaseCount == 0)
        }
    }

    @Test
    func captureRetainsLineageUntilTerminalThenReleasesAuthorityMetadata()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes)
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let seed = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)], pinReasons: [.dirty]
        )
        try surface.markDirty(seed)
        try surface.returnLease(seed)
        var provider: TiledRasterExactReferenceProvider? = try surface
            .makeExactReferenceProvider()
        weak let lineage = try #require(provider).testingLineageAnchor
        let capture = try TiledRasterExactReferenceCapture(
            providers: [try #require(provider)]
        )

        provider = nil
        #expect(lineage != nil)
        let unrelated = try surface.makeExactReferenceProvider()
        #expect(throws: TiledRasterSurfaceError.providerNotCaptured) {
            _ = try capture.borrowing(providers: [unrelated])
        }

        capture.close()
        #expect(lineage == nil)
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
    }

    @Test
    func droppedDirectBorrowCannotStrandCaptureClosure() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes)
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let seed = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)], pinReasons: [.dirty]
        )
        try surface.markDirty(seed)
        try surface.returnLease(seed)
        let provider = try surface.makeExactReferenceProvider()
        let capture = try TiledRasterExactReferenceCapture(providers: [provider])
        var borrow: TiledRasterExactReferenceCapture.Borrow? = try capture
            .borrowing(providers: [provider])
        #expect(borrow != nil)

        borrow = nil
        capture.close()
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
    }

    @Test
    func emptyAndMixedEmptyEntitlementsConsumeNoEmptyTokenCapacity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 2)
        let layerID = UUID()
        let size = PixelSize(width: 512, height: 256)
        let surface = TiledRasterSurface(
            store: store,
            layerID: layerID,
            pixelSize: size
        )
        let seed = try surface.reserveTiles(
            at: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            pinReasons: [.dirty]
        )
        try surface.markDirty(seed)
        try surface.returnLease(seed)
        let full = try surface.makeExactReferenceProvider()

        let empty = try full.restrictingEntitlement(to: [])
        let emptyCapture = try TiledRasterExactReferenceCapture(
            providers: [empty]
        )
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
        #expect(store.snapshot().aggregateSnapshotReferenceCount == 0)
        emptyCapture.close()

        let selected = try full.restrictingEntitlement(
            to: [full.identityReferences[0]]
        )
        let mixedCapture = try TiledRasterExactReferenceCapture(
            providers: [empty, selected]
        )
        #expect(store.snapshot().activeSnapshotTokenCount == 1)
        #expect(store.snapshot().aggregateSnapshotReferenceCount == 1)
        mixedCapture.close()
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
    }

    @Test
    func selectedCaptureRollsBackEarlierStoreWhenLaterStoreAdmissionFails()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let oneTokenPerStore = PaintTileSnapshotRetentionLimits(
            maximumActiveTokenCount: 1,
            maximumReferencesPerToken: 4,
            maximumAggregateReferenceCount: 4,
            maximumIndexEntryCount: 4,
            maximumMetadataBytes: 1_024 * 1_024,
            maximumPayloadDebtBytes: bytes * 4
        )
        let firstStore = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 4,
            snapshotRetentionLimits: oneTokenPerStore
        )
        let secondStore = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 4,
            snapshotRetentionLimits: oneTokenPerStore
        )
        let successfulStore: PaintTileStore
        let rejectingStore: PaintTileStore
        if firstStore.identity < secondStore.identity {
            successfulStore = firstStore
            rejectingStore = secondStore
        } else {
            successfulStore = secondStore
            rejectingStore = firstStore
        }
        let size = PixelSize(width: 256, height: 256)
        func provider(_ store: PaintTileStore) throws
            -> TiledRasterExactReferenceProvider
        {
            let surface = TiledRasterSurface(
                store: store,
                layerID: UUID(),
                pixelSize: size
            )
            let seed = try surface.reserveTiles(
                at: [.init(x: 0, y: 0)], pinReasons: [.dirty]
            )
            try surface.markDirty(seed)
            try surface.returnLease(seed)
            return try surface.makeExactReferenceProvider()
        }
        let successfulProvider = try provider(successfulStore)
        let rejectingProvider = try provider(rejectingStore)
        let blocker = try rejectingStore.retainSnapshotReferences(
            rejectingProvider.references
        )

        #expect(throws: PaintTileStoreError.snapshotRetentionLimitExceeded(
            limit: .activeTokens,
            required: 2,
            maximum: 1
        )) {
            _ = try TiledRasterExactReferenceCapture(
                providers: [successfulProvider, rejectingProvider]
            )
        }
        #expect(successfulStore.snapshot().activeSnapshotTokenCount == 0)
        #expect(rejectingStore.snapshot().activeSnapshotTokenCount == 1)
        blocker.close()
        #expect(rejectingStore.snapshot().activeSnapshotTokenCount == 0)
    }

    @Test
    func exactProviderAcceptsOnlySortedCapturedSubsetsAndFrozenNamespace()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 3)
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 768, height: 256),
            generation: 9
        )
        let seed = try surface.reserveTiles(
            at: (0..<3).map { .init(x: $0, y: 0) },
            pinReasons: [.dirty]
        )
        try surface.markDirty(seed)
        try surface.returnLease(seed)
        let provider = try surface.makeExactReferenceProvider()
        let capture = try TiledRasterExactReferenceCapture(
            providers: [provider]
        )
        let selected = [provider.references[0], provider.references[2]]
        let lease = try provider.leaseExactReferences(
            selected,
            using: capture,
            pinReasons: [.visible]
        )
        #expect(lease.bindings.map(\.identity) == selected.map(\.identity))
        #expect(lease.surfaceID == provider.surfaceID)
        #expect(lease.layerID == provider.layerID)
        #expect(lease.generation == provider.generation)

        #expect(throws: TiledRasterSurfaceError.unsortedExactReference) {
            _ = try provider.leaseExactReferences(
                Array(selected.reversed()),
                using: capture,
                pinReasons: [.visible]
            )
        }
        var foreign = provider.references[1]
        foreign = foreign.replacing(
            identity: PaintTileIdentity(
                layerID: foreign.layerID,
                coordinate: foreign.coordinate,
                tileID: PaintTileID(rawValue: UInt64.max)
            )
        )
        #expect(throws: TiledRasterSurfaceError.exactReferenceNotCaptured) {
            _ = try provider.leaseExactReferences(
                [foreign],
                using: capture,
                pinReasons: [.visible]
            )
        }
        capture.close()
        try lease.returnLease()
    }

    @Test
    func exactCaptureCloseRacingProviderLeaseNeverStrandsOwnership()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        for _ in 0..<32 {
            let store = PaintTileStore(device: device, byteBudget: bytes)
            let surface = TiledRasterSurface(
                store: store,
                layerID: UUID(),
                pixelSize: PixelSize(width: 256, height: 256)
            )
            let seed = try surface.reserveTiles(
                at: [.init(x: 0, y: 0)],
                pinReasons: [.dirty]
            )
            try surface.markDirty(seed)
            try surface.returnLease(seed)
            let provider = try surface.makeExactReferenceProvider()
            let capture = try TiledRasterExactReferenceCapture(
                providers: [provider]
            )

            let leaseTask = Task {
                try provider.leaseExactReferences(
                    provider.references,
                    using: capture,
                    pinReasons: [.visible]
                )
            }
            let closeTask = Task { capture.close() }
            do {
                let lease = try await leaseTask.value
                try lease.returnLease()
            } catch {
                #expect(error as? TiledRasterSurfaceError
                    == .exactReferenceCaptureClosed)
            }
            await closeTask.value
            let snapshot = store.snapshot()
            #expect(snapshot.activeSnapshotTokenCount == 0)
            #expect(snapshot.activeLeaseCount == 0)
        }
    }

    @Test
    func staleAndPendingRetirementProvidersCannotOpenCapture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)

        let staleStore = PaintTileStore(device: device, byteBudget: bytes)
        let staleSurface = TiledRasterSurface(
            store: staleStore,
            layerID: UUID(),
            pixelSize: size
        )
        let staleSeed = try staleSurface.reserveTiles(
            at: [.init(x: 0, y: 0)],
            pinReasons: [.dirty]
        )
        try staleSurface.markDirty(staleSeed)
        try staleSurface.returnLease(staleSeed)
        let staleProvider = try staleSurface.makeExactReferenceProvider()
        try staleSurface.advanceGeneration()
        let replacement = try staleSurface.reserveTiles(
            at: [.init(x: 0, y: 0)],
            pinReasons: [.dirty]
        )
        try staleSurface.markDirty(replacement)
        try staleSurface.returnLease(replacement)
        #expect(throws: PaintTileStoreError.staleTileReference) {
            _ = try TiledRasterExactReferenceCapture(
                providers: [staleProvider]
            )
        }
        #expect(staleStore.snapshot().activeSnapshotTokenCount == 0)

        let pendingStore = PaintTileStore(device: device, byteBudget: bytes)
        let pendingSurface = TiledRasterSurface(
            store: pendingStore,
            layerID: UUID(),
            pixelSize: size
        )
        let pendingSeed = try pendingSurface.reserveTiles(
            at: [.init(x: 0, y: 0)],
            pinReasons: [.dirty]
        )
        try pendingSurface.markDirty(pendingSeed)
        let pendingProvider = try pendingSurface.makeExactReferenceProvider()
        let retirement = try pendingStore.prepareRetirement(
            pendingProvider.references
        )
        pendingStore.requestRetirement(retirement)
        #expect(pendingStore.snapshot().pendingRetirementCount == 1)
        #expect(throws: PaintTileStoreError.staleTileReference) {
            _ = try TiledRasterExactReferenceCapture(
                providers: [pendingProvider]
            )
        }
        #expect(pendingStore.snapshot().activeSnapshotTokenCount == 0)
        try pendingSurface.returnLease(pendingSeed)
        #expect(pendingStore.snapshot().pendingRetirementCount == 0)
    }

    @Test
    func emptySurfaceOwnsNoTexturesAndOneDabAllocatesOnlyItsTile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = TiledRasterSurface(
            device: device,
            layerID: UUID(),
            pixelSize: PixelSize(width: 4096, height: 4096),
            byteBudget: bytes * 4
        )
        #expect(surface.isEmpty)
        #expect(surface.residentTileCount == 0)
        #expect(surface.residentByteCount == 0)
        #expect(surface.revision == RasterRevision(rawValue: 0))

        let lease = try surface.reserveTiles(
            intersecting: try #require(PixelRect(minX: 100, minY: 100, maxX: 110, maxY: 110)),
            pinReasons: [.active, .dirty]
        )
        #expect(lease.bindings.map(\.descriptor.coordinate) == [.init(x: 0, y: 0)])
        #expect(surface.residentTileCount == 1)
        #expect(surface.residentByteCount == bytes)
        try surface.markDirty(lease)
        #expect(surface.dirtyTileCoordinates == [.init(x: 0, y: 0)])
        #expect(surface.revision == RasterRevision(rawValue: 1))
        try surface.returnLease(lease)
    }

    @Test
    func returningFinalPristineLeaseRestoresZeroTextureEmptyState() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = TiledRasterSurface(
            device: device,
            layerID: UUID(),
            pixelSize: PixelSize(width: 512, height: 512),
            byteBudget: bytes
        )
        let lease = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)],
            pinReasons: [.active]
        )

        try surface.returnLease(lease)

        #expect(surface.isEmpty)
        #expect(surface.residentTileCount == 0)
        #expect(surface.residentByteCount == 0)
    }

    @Test
    func exactProviderOmitsPinnedKnownClearPhysicalRecord() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = TiledRasterSurface(
            device: device,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256),
            byteBudget: bytes
        )
        let lease = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)],
            pinReasons: [.inFlight]
        )

        #expect(surface.references.count == 1)
        #expect(try surface.makeExactReferenceProvider().references.isEmpty)

        try surface.returnLease(lease)
        #expect(surface.isEmpty)
    }

    @Test
    func pristineTileSurvivesNestedLeaseUntilLastReturn() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = TiledRasterSurface(
            device: device,
            layerID: UUID(),
            pixelSize: PixelSize(width: 512, height: 512),
            byteBudget: bytes
        )
        let active = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)],
            pinReasons: [.active]
        )
        let visible = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)],
            pinReasons: [.visible]
        )

        try surface.returnLease(active)
        #expect(!surface.isEmpty)
        #expect(surface.residentTileCount == 1)

        try surface.returnLease(visible)
        #expect(surface.isEmpty)
        #expect(surface.residentTileCount == 0)
    }

    @Test
    func sharedStoreSurfaceCannotReturnAnotherLayersLease() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: bytes * 2)
        let sharedSurfaceID = UUID()
        let first = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 512, height: 512),
            surfaceID: sharedSurfaceID
        )
        let second = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 512, height: 512),
            surfaceID: sharedSurfaceID
        )
        let lease = try first.reserveTiles(
            at: [.init(x: 0, y: 0)],
            pinReasons: [.active]
        )
        let before = first.backingSnapshot()

        #expect(throws: TiledRasterSurfaceError.leaseLayerMismatch(
            expected: second.layerID,
            actual: first.layerID
        )) {
            try second.returnLease(lease)
        }
        #expect(first.backingSnapshot() == before)
        try first.returnLease(lease)
    }

    @Test
    func crossingCornerReservesFourPhysicalTilesAndDirtyRevisionAdvancesOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = TiledRasterSurface(
            device: device,
            layerID: UUID(),
            pixelSize: PixelSize(width: 700, height: 700),
            initialRevision: RasterRevision(rawValue: 40),
            byteBudget: bytes * 4
        )
        let lease = try surface.reserveTiles(
            intersecting: try #require(PixelRect(minX: 256, minY: 256, maxX: 257, maxY: 257)),
            pinReasons: [.dirty]
        )
        #expect(lease.bindings.map(\.descriptor.coordinate) == [
            .init(x: 0, y: 0), .init(x: 1, y: 0),
            .init(x: 0, y: 1), .init(x: 1, y: 1),
        ])
        #expect(lease.bindings.allSatisfy {
            $0.texture.width == 256 && $0.texture.height == 256
        })
        try surface.markDirty(lease)
        #expect(surface.revision == RasterRevision(rawValue: 41))
        #expect(surface.dirtyTileCoordinates.count == 4)
        try surface.returnLease(lease)
    }

    @Test
    func backingSnapshotIsImmutableAndPressureEvictsOnlyReturnedTiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = TiledRasterSurface(
            device: device,
            layerID: UUID(),
            pixelSize: PixelSize(width: 1024, height: 1024),
            byteBudget: bytes * 3
        )
        let first = try surface.reserveTiles(
            at: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            pinReasons: [.historyBefore]
        )
        try surface.markDirty(first)
        let before = surface.backingSnapshot()
        #expect(before.tileCoordinates == [.init(x: 0, y: 0), .init(x: 1, y: 0)])
        #expect(before.residentByteCount == bytes * 2)

        let third = try surface.reserveTiles(
            at: [.init(x: 2, y: 0)],
            pinReasons: [.visible]
        )
        #expect(before.tileCoordinates == [.init(x: 0, y: 0), .init(x: 1, y: 0)])
        #expect(surface.backingSnapshot().tileCoordinates.count == 3)

        try surface.returnLease(first)
        let pressure = try surface.applyMemoryPressure(targetResidentBytes: bytes)
        #expect(pressure.evictedIdentities.map(\.coordinate) == [
            .init(x: 0, y: 0), .init(x: 1, y: 0),
        ])
        #expect(surface.residentByteCount == bytes)
        try surface.returnLease(third)
    }

    @Test
    func generationAdvanceRejectsOutstandingLeasesThenRetiresWithoutStrandingPins() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = TiledRasterSurface(
            device: device,
            layerID: UUID(),
            pixelSize: PixelSize(width: 512, height: 512),
            byteBudget: bytes * 2
        )
        let old = try surface.reserveTiles(at: [.init(x: 0, y: 0)], pinReasons: [.inFlight])
        let leased = surface.backingSnapshot()
        #expect(throws: PaintTileStoreError.outstandingLeases(surfaceID: surface.surfaceID, generation: 0, count: 1)) {
            try surface.advanceGeneration()
        }
        #expect(surface.generation == 0)
        #expect(surface.backingSnapshot() == leased)
        try surface.returnLease(old)
        try surface.advanceGeneration()
        #expect(surface.generation == 1)
        #expect(surface.isEmpty)
        #expect(surface.revision == RasterRevision(rawValue: 1))
        let before = surface.backingSnapshot()
        #expect(throws: PaintTileStoreError.staleGeneration(expected: 1, actual: 0)) {
            try surface.returnLease(old)
        }
        #expect(surface.backingSnapshot() == before)
    }

    @Test
    func pressureSnapshotsPrivatePixelsAndRehydrateRestoresEveryRGBA16FByte() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = TiledRasterSurface(
            device: device,
            layerID: UUID(),
            pixelSize: PixelSize(width: 512, height: 512),
            byteBudget: bytes
        )
        let lease = try surface.reserveTiles(
            at: [.init(x: 1, y: 1)],
            pinReasons: [.dirty]
        )
        let expected = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
        try upload(expected, into: lease.bindings[0].texture, device: device)
        try surface.markDirty(lease)
        try surface.returnLease(lease)

        let pressure = try surface.applyMemoryPressure(targetResidentBytes: 0)
        #expect(pressure.evictedIdentities == [lease.bindings[0].identity])
        #expect(surface.residentByteCount == 0)
        #expect(surface.backingByteCount == bytes)
        #expect(!surface.isEmpty)
        let evicted = surface.backingSnapshot()
        #expect(evicted.entries[0].backing == .rgba16Float(expected))

        let restored = try surface.reserveTiles(
            at: [.init(x: 1, y: 1)],
            pinReasons: [.visible]
        )
        #expect(restored.bindings[0].identity == lease.bindings[0].identity)
        #expect(try download(restored.bindings[0].texture, device: device) == expected)
        #expect(surface.residentByteCount == bytes)
        #expect(surface.backingByteCount == 0)
        try surface.returnLease(restored)
    }

    @Test
    func payloadSnapshotCapturesAndRestoresModifiedResidentWithoutPressure() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = TiledRasterSurface(
            device: device,
            layerID: UUID(),
            pixelSize: PixelSize(width: 256, height: 256),
            byteBudget: bytes
        )
        let lease = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)],
            pinReasons: [.dirty]
        )
        let expected = Data((0..<bytes).map {
            UInt8(truncatingIfNeeded: $0 &* 19 &+ 7)
        })
        try upload(expected, into: lease.bindings[0].texture, device: device)
        try surface.markDirty(lease)

        let snapshot = try surface.payloadSnapshot()
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries[0].payload == .rgba16Float(expected))
        try upload(Data(count: bytes), into: lease.bindings[0].texture, device: device)
        guard case let .rgba16Float(payload) = snapshot.entries[0].payload else {
            Issue.record("Modified resident snapshot must contain RGBA16F bytes")
            return
        }
        try upload(payload, into: lease.bindings[0].texture, device: device)
        #expect(try download(lease.bindings[0].texture, device: device) == expected)
        try surface.returnLease(lease)
    }

    @Test
    func failedReserveLeavesSurfaceAndBackingSnapshotBitForBitUnchanged() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = TiledRasterSurface(
            device: device,
            layerID: UUID(),
            pixelSize: PixelSize(width: 512, height: 512),
            byteBudget: bytes * 4
        )
        let seed = try surface.reserveTiles(
            at: [.init(x: 1, y: 1)],
            pinReasons: [.dirty]
        )
        let payload = Data(repeating: 0xA7, count: bytes)
        try upload(payload, into: seed.bindings[0].texture, device: device)
        try surface.markDirty(seed)
        try surface.returnLease(seed)
        _ = try surface.applyMemoryPressure(targetResidentBytes: 0)
        let before = surface.backingSnapshot()
        #expect(before.entries[0].backing == .rgba16Float(payload))
        #expect(throws: PaintTileStoreError.injectedAllocationFailure(reserveIndex: 2)) {
            _ = try surface.reserveTiles(
                at: [
                    .init(x: 0, y: 0), .init(x: 1, y: 0),
                    .init(x: 0, y: 1),
                ],
                pinReasons: [.active, .dirty],
                failureInjection: .init(failingAtReserveIndex: 2)
            )
        }
        #expect(surface.backingSnapshot() == before)
    }

    @Test
    func clearFanOutUsesOnePersistentZeroSourceAndProducesExactZeros() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        for tileCount in [1, 2, 4, 16] {
            let store = PaintTileStore(
                device: device,
                byteBudget: bytes * tileCount,
                transferByteCapacity: bytes * (tileCount + 1)
            )
            let surface = TiledRasterSurface(
                store: store,
                layerID: UUID(),
                pixelSize: PixelSize(width: 256 * tileCount, height: 256)
            )
            let lease = try surface.reserveTiles(
                at: (0..<tileCount).map { .init(x: $0, y: 0) },
                pinReasons: [.active]
            )

            let snapshot = store.snapshot()
            #expect(snapshot.persistentZeroAllocationBytes == bytes)
            #expect(snapshot.persistentZeroAllocationCount == 1)
            #expect(
                snapshot.lastTransferAccounting?.persistentZeroAllocationBytes
                    == bytes
            )
            #expect(
                snapshot.lastTransferAccounting?.persistentZeroAllocationCount
                    == 1
            )
            #expect(snapshot.lastTransferAccounting?.uploadStagingBytes == 0)
            for binding in lease.bindings {
                #expect(
                    try download(binding.texture, device: device)
                        == Data(count: bytes)
                )
            }
            try surface.returnLease(lease)
        }
    }

    @Test
    func mixedClearAndPayloadRehydrateReusesPersistentZeroSource() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes * 2,
            transferByteCapacity: bytes * 8
        )
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 512, height: 256)
        )
        let original = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)],
            pinReasons: [.dirty]
        )
        let payload = Data((0..<bytes).map {
            UInt8(truncatingIfNeeded: $0 &* 29 &+ 17)
        })
        try upload(payload, into: original.bindings[0].texture, device: device)
        try surface.markDirty(original)
        try surface.returnLease(original)
        _ = try surface.applyMemoryPressure(targetResidentBytes: 0)

        let mixed = try surface.reserveTiles(
            at: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            pinReasons: [.visible]
        )

        #expect(try download(mixed.bindings[0].texture, device: device) == payload)
        #expect(
            try download(mixed.bindings[1].texture, device: device)
                == Data(count: bytes)
        )
        let snapshot = store.snapshot()
        #expect(snapshot.persistentZeroAllocationBytes == bytes)
        #expect(snapshot.persistentZeroAllocationCount == 1)
        #expect(
            snapshot.lastTransferAccounting?.persistentZeroAllocationBytes == 0
        )
        #expect(
            snapshot.lastTransferAccounting?.persistentZeroAllocationCount == 0
        )
        #expect(snapshot.lastTransferAccounting?.uploadStagingBytes == bytes)
        try surface.returnLease(mixed)
    }

    @Test
    func acceleratedWarmResidencyTraceHasFlatBytesTilesAndLeaseCount() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = TiledRasterSurface(
            device: device,
            layerID: UUID(),
            pixelSize: PixelSize(width: 1024, height: 1024),
            byteBudget: bytes * 4
        )
        let warmCoordinates = [
            PaintTileCoordinate(x: 0, y: 0), PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 0, y: 1), PaintTileCoordinate(x: 1, y: 1),
        ]
        var firstStable: TiledRasterBackingSnapshot?
        for frame in 0..<20_000 {
            let coordinate = warmCoordinates[frame & 3]
            let lease = try surface.reserveTiles(at: [coordinate], pinReasons: [.visible, .inFlight])
            if frame < warmCoordinates.count {
                try surface.markDirty(lease)
            }
            try surface.returnLease(lease)
            if frame == 3 {
                firstStable = surface.backingSnapshot()
            }
            if frame >= 4, frame.isMultiple(of: 997) {
                let current = surface.backingSnapshot()
                #expect(current.residentByteCount == firstStable?.residentByteCount)
                #expect(current.tileCoordinates == firstStable?.tileCoordinates)
                #expect(current.activeLeaseCount == 0)
                #expect(current.residentByteCount <= bytes * 4)
            }
        }
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
            sourceBytesPerImage: PaintTileDescriptor.residentByteCount,
            sourceSize: MTLSize(width: 256, height: 256, depth: 1),
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
            length: PaintTileDescriptor.residentByteCount,
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
            sourceSize: MTLSize(width: 256, height: 256, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: PaintTileDescriptor.side * 8,
            destinationBytesPerImage: PaintTileDescriptor.residentByteCount
        )
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        return Data(bytes: buffer.contents(), count: PaintTileDescriptor.residentByteCount)
    }
}
