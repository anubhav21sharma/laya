import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Document paint surface registry", .serialized)
struct DocumentPaintSurfaceStoreTests {
    private let tileBytes = PaintTileDescriptor.residentByteCount

    @Test
    func emptyRegistryHasGenericLayerBindingsAndCheckedGeometry() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let first = UUID()
        let second = UUID()
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 4_096, height: 2_048),
            storagePixelSize: PixelSize(width: 4_096, height: 2_048),
            radialLayout: nil
        )
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes * 8,
            transferByteCapacity: tileBytes * 9,
            geometry: geometry,
            layerIDs: [first, second],
            generation: 4
        )

        #expect(registry.generation == 4)
        #expect(registry.geometry == geometry)
        #expect(registry.layerIDs == [first, second])
        #expect(try registry.binding(for: first).canonical.references.isEmpty)
        #expect(try registry.binding(for: second).canonical.references.isEmpty)
        #expect(registry.tileStoreIdentity == registry.sharedTileStore.identity)
        #expect(registry.sharedTileStore.transferByteCapacity == tileBytes * 9)
        #expect(registry.snapshot().tileByteBudget == tileBytes * 8)
        #expect(registry.snapshot().activeTileLeaseCount == 0)
        #expect(registry.snapshot().issuedNamespaceCount == 0)
        #expect(registry.snapshot().preparedCandidateCount == 0)
        #expect(throws: DocumentPaintSurfaceStoreError.duplicateLayerID(first)) {
            _ = try DocumentPaintSurfaceStore(
                device: device,
                byteBudget: tileBytes,
                geometry: geometry,
                layerIDs: [first, first]
            )
        }
        #expect(throws: DocumentPaintSurfaceStoreError.geometryByteCountOverflow) {
            _ = try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: Int.max, height: 2),
                storagePixelSize: PixelSize(width: Int.max, height: 2),
                radialLayout: nil
            )
        }
    }

    @Test
    func radialGeometryUsesSparsePagesAndRejectsMismatchedAtlasStorage() throws {
        let layout = try RadialSectorLayout(
            maximumRadius: 1_024,
            sectorAngleRadians: .pi / 9
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 2_048, height: 2_048),
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        #expect(geometry.storageResidentByteCount
            == (try layout.residentByteCount(bytesPerPixel: 8)))

        let mismatch = PixelSize(
            width: layout.atlasPixelSize.width + 1,
            height: layout.atlasPixelSize.height
        )
        #expect(throws: DocumentPaintSurfaceStoreError
            .radialStorageSizeMismatch(
                expected: layout.atlasPixelSize,
                actual: mismatch
            )) {
            _ = try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 2_048, height: 2_048),
                storagePixelSize: mismatch,
                radialLayout: layout
            )
        }
    }

    @Test
    func registryIssuesAuthenticatedRoleSpecificStrokeNamespace() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let lease = try registry.issueStrokeNamespace(
            layerID: layer,
            generation: registry.generation
        )

        #expect(lease.storeIdentity == registry.tileStoreIdentity)
        #expect(lease.layerID == layer)
        #expect(lease.generation == registry.generation)
        #expect(lease.authoritative.role == .authoritative)
        #expect(lease.prediction.role == .prediction)
        #expect(lease.authoritative.surfaceID != lease.prediction.surfaceID)
        #expect(lease.isAuthenticated(
            storeIdentity: registry.tileStoreIdentity,
            layerID: layer,
            generation: registry.generation
        ))
        #expect(!lease.isAuthenticated(
            storeIdentity: PaintTileStoreIdentity(),
            layerID: layer,
            generation: registry.generation
        ))
        lease.reportRetired()
        #expect(!lease.isAuthenticated(
            storeIdentity: registry.tileStoreIdentity,
            layerID: layer,
            generation: registry.generation
        ))
    }

    @Test
    func exactReferencesRejectForeignStoreStaleIdentityAndUnsortedInput() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: tileBytes * 4)
        let other = PaintTileStore(device: device, byteBudget: tileBytes * 4)
        let layer = UUID()
        let surface = UUID()
        let size = PixelSize(width: 512, height: 256)
        let lease = try store.reserve(
            surfaceID: surface,
            layerID: layer,
            generation: 8,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            pinReasons: [.dirty]
        )
        try store.markModified(lease, surfaceID: surface, currentGeneration: 8)
        try store.release(lease, surfaceID: surface, currentGeneration: 8)
        let refs = try store.references(
            surfaceID: surface,
            layerID: layer,
            generation: 8
        )
        #expect(refs.map(\.coordinate) == [
            .init(x: 0, y: 0), .init(x: 1, y: 0),
        ])
        #expect(refs.allSatisfy { $0.storeIdentity == store.identity })

        #expect(throws: PaintTileStoreError.foreignStoreReference) {
            _ = try other.reserveReferences(
                refs,
                leaseSurfaceID: UUID(),
                leaseLayerID: layer,
                leaseGeneration: 9,
                pinReasons: [.visible]
            )
        }
        #expect(throws: PaintTileStoreError.unsortedReference) {
            _ = try store.reserveReferences(
                refs.reversed(),
                leaseSurfaceID: UUID(),
                leaseLayerID: layer,
                leaseGeneration: 9,
                pinReasons: [.visible]
            )
        }
        var stale = refs
        stale[0] = stale[0].replacing(
            identity: PaintTileIdentity(
                layerID: layer,
                coordinate: stale[0].coordinate,
                tileID: PaintTileID(rawValue: .max)
            )
        )
        #expect(throws: PaintTileStoreError.staleTileReference) {
            _ = try store.reserveReferences(
                stale,
                leaseSurfaceID: UUID(),
                leaseLayerID: layer,
                leaseGeneration: 9,
                pinReasons: [.visible]
            )
        }
    }

    @Test
    func mixedNamespaceReferenceLeaseIsExactSortedAndAtomic() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: tileBytes * 4)
        let layer = UUID()
        let size = PixelSize(width: 512, height: 256)
        let first = try seed(
            store: store, surfaceID: UUID(), layerID: layer,
            generation: 1, size: size, coordinate: .init(x: 0, y: 0)
        )
        let second = try seed(
            store: store, surfaceID: UUID(), layerID: layer,
            generation: 2, size: size, coordinate: .init(x: 1, y: 0)
        )
        let references = [first, second].sorted()
        let owner = UUID()
        let before = store.snapshot()
        let lease = try store.reserveReferences(
            references,
            leaseSurfaceID: owner,
            leaseLayerID: layer,
            leaseGeneration: 3,
            pinReasons: [.visible, .inFlight]
        )
        #expect(lease.storeIdentity == store.identity)
        #expect(lease.bindings.map(\.identity) == references.map(\.identity))
        #expect(store.snapshot().activeLeaseCount == before.activeLeaseCount + 1)
        try store.release(lease, surfaceID: owner, currentGeneration: 3)
        #expect(store.snapshot().activeLeaseCount == before.activeLeaseCount)

        let state = store.snapshot()
        #expect(throws: PaintTileStoreError.staleTileReference) {
            _ = try store.reserveReferences(
                [first, second.replacing(
                    identity: PaintTileIdentity(
                        layerID: layer,
                        coordinate: second.coordinate,
                        tileID: PaintTileID(rawValue: .max)
                    )
                )].sorted(),
                leaseSurfaceID: owner,
                leaseLayerID: layer,
                leaseGeneration: 3,
                pinReasons: [.visible]
            )
        }
        #expect(store.snapshot() == state)
    }

    @Test
    func immutableSurfaceViewLeasesExactReferencesAndRejectsMutation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: tileBytes * 2)
        let layer = UUID()
        let physical = UUID()
        let size = PixelSize(width: 512, height: 256)
        _ = try seed(
            store: store, surfaceID: physical, layerID: layer,
            generation: 2, size: size, coordinate: .init(x: 1, y: 0)
        )
        let refs = try store.references(
            surfaceID: physical, layerID: layer, generation: 2
        )
        let view = try TiledRasterCoordinateReferenceView(
            storeIdentity: store.identity,
            surfaceID: UUID(),
            layerID: layer,
            pixelSize: size,
            generation: 3,
            revision: RasterRevision(rawValue: 7),
            references: refs
        )
        let surface = try TiledRasterSurface(store: store, referenceView: view)
        #expect(surface.references == refs)
        #expect(surface.revision == RasterRevision(rawValue: 7))
        let lease = try surface.leaseExistingTiles(
            at: [.init(x: 1, y: 0)], pinReasons: [.visible]
        )
        try surface.returnLease(lease)
        #expect(throws: TiledRasterSurfaceError.immutableReferenceView) {
            _ = try surface.reserveTiles(
                at: [.init(x: 0, y: 0)], pinReasons: [.dirty]
            )
        }
    }

    @Test
    func immutableBackingSnapshotNeverSubstitutesReusedPhysicalCoordinate() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: tileBytes * 2)
        let layer = UUID()
        let physical = UUID()
        let size = PixelSize(width: 256, height: 256)
        let old = try seed(
            store: store, surfaceID: physical, layerID: layer,
            generation: 1, size: size, coordinate: .init(x: 0, y: 0)
        )
        let view = try TiledRasterCoordinateReferenceView(
            storeIdentity: store.identity,
            surfaceID: UUID(),
            layerID: layer,
            pixelSize: size,
            generation: 2,
            revision: RasterRevision(rawValue: 1),
            references: [old]
        )
        let immutable = try TiledRasterSurface(store: store, referenceView: view)
        try store.retire(surfaceID: physical, generation: 1)
        let replacement = try seed(
            store: store, surfaceID: physical, layerID: layer,
            generation: 1, size: size, coordinate: .init(x: 0, y: 0)
        )
        #expect(replacement.identity != old.identity)
        #expect(throws: PaintTileStoreError.staleTileReference) {
            _ = try store.snapshot(exactReferences: [old])
        }
        #expect(immutable.backingSnapshot().entries.isEmpty)
    }

    @Test
    func candidateCOWSharesUnchangedReferencesAndOwnsOnlyDirtyCoordinates() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [
                .init(x: 0, y: 0), .init(x: 1, y: 0),
            ]]
        )
        let preparedInitial = try registry.prepareCommit(initial)
        registry.commitPrepared(preparedInitial)
        let before = try registry.binding(for: layer).canonical.references

        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 1, y: 0)]]
        )
        let after = try candidate.binding(for: layer).canonical.references
        #expect(after.count == 2)
        #expect(after[0] == before[0])
        #expect(after[1].coordinate == before[1].coordinate)
        #expect(after[1].identity != before[1].identity)
        #expect(candidate.ownedReferences == [after[1]])
        #expect(candidate.ownedNamespaces.count == 1)
        #expect(candidate.ownedNamespaces[0].role == .provisional)
        #expect(candidate.ownedNamespaces[0].surfaceID
            == after[1].physicalSurfaceID)
    }

    @Test
    func candidateCanRemoveCoordinateWithoutAllocatingReplacement() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let candidate = try registry.makeCandidate(
            removingCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        #expect(try candidate.binding(for: layer).canonical.references.isEmpty)
        #expect(candidate.ownedReferences.isEmpty)
        registry.commitPrepared(try registry.prepareCommit(candidate))
        #expect(try registry.binding(for: layer).canonical.references.isEmpty)
        #expect(registry.sharedTileStore.snapshot().entries.isEmpty)
    }

    @Test
    func commitRetiresReplacedReferenceOnlyAfterOldViewReturnsFinalLease() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let oldSurface = try registry.binding(for: layer).canonical
        let oldReference = try #require(oldSurface.references.first)
        let displayLease = try oldSurface.leaseExistingTiles(
            at: [oldReference.coordinate],
            pinReasons: [.visible, .inFlight]
        )

        let replacement = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [oldReference.coordinate]]
        )
        registry.commitPrepared(try registry.prepareCommit(replacement))
        let newReference = try #require(
            registry.binding(for: layer).canonical.references.first
        )
        #expect(newReference.identity != oldReference.identity)
        #expect(registry.sharedTileStore.isRetirementPending(oldReference))
        #expect(registry.sharedTileStore.lookup(
            surfaceID: oldReference.physicalSurfaceID,
            layerID: oldReference.layerID,
            generation: oldReference.physicalGeneration,
            coordinate: oldReference.coordinate
        ) != nil)

        try oldSurface.returnLease(displayLease)
        #expect(!registry.sharedTileStore.isRetirementPending(oldReference))
        #expect(registry.sharedTileStore.lookup(
            surfaceID: oldReference.physicalSurfaceID,
            layerID: oldReference.layerID,
            generation: oldReference.physicalGeneration,
            coordinate: oldReference.coordinate
        ) == nil)
        #expect(registry.sharedTileStore.lookup(
            surfaceID: newReference.physicalSurfaceID,
            layerID: newReference.layerID,
            generation: newReference.physicalGeneration,
            coordinate: newReference.coordinate
        ) != nil)
    }

    @Test
    func geometryCandidateStartsExplicitlyEmptyAndSwapsOrDiscardsAtomically() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let oldSurface = try registry.binding(for: layer).canonical
        let oldReference = try #require(oldSurface.references.first)
        let oldLease = try oldSurface.leaseExistingTiles(
            at: [oldReference.coordinate], pinReasons: [.visible]
        )
        let oldSnapshot = registry.snapshot()
        let resizedGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 2_048, height: 512),
            storagePixelSize: PixelSize(width: 2_048, height: 512),
            radialLayout: nil
        )

        let discarded = try registry.makeCandidate(geometry: resizedGeometry)
        #expect(try discarded.binding(for: layer).canonical.references.isEmpty)
        try registry.discard(discarded)
        #expect(registry.snapshot() == oldSnapshot)
        #expect(oldSurface.references == [oldReference])

        let committed = try registry.makeCandidate(geometry: resizedGeometry)
        registry.commitPrepared(try registry.prepareCommit(committed))
        #expect(registry.geometry == resizedGeometry)
        #expect(registry.generation == oldSnapshot.generation + 1)
        #expect(try registry.binding(for: layer).canonical.references.isEmpty)
        #expect(oldSurface.references == [oldReference])
        #expect(registry.sharedTileStore.isRetirementPending(oldReference))
        try oldSurface.returnLease(oldLease)
        #expect(!registry.sharedTileStore.isRetirementPending(oldReference))
    }

    @Test
    func candidateFailureStaleCommitAndDiscardPreserveActiveRegistry() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let before = registry.snapshot()
        #expect(throws: PaintTileStoreError.injectedAllocationFailure(reserveIndex: 0)) {
            _ = try registry.makeCandidate(
                dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]],
                failureInjection: .init(failingAtReserveIndex: 0)
            )
        }
        #expect(registry.snapshot() == before)

        let first = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        let stale = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 1, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(first))
        let committed = registry.snapshot()
        #expect(throws: DocumentPaintSurfaceStoreError.staleCandidate(
            expectedGeneration: registry.generation,
            actualGeneration: stale.baseGeneration
        )) {
            _ = try registry.prepareCommit(stale)
        }
        try registry.discard(stale)
        let afterDiscard = registry.snapshot()
        #expect(afterDiscard.generation == committed.generation)
        #expect(afterDiscard.geometry == committed.geometry)
        #expect(afterDiscard.layers == committed.layers)
        #expect(afterDiscard.residentTileBytes < committed.residentTileBytes)
        #expect(throws: DocumentPaintSurfaceStoreError.candidateAlreadyConsumed) {
            try registry.discard(stale)
        }
    }

    @Test
    func preparedCandidateRequiresExplicitSingleUseCommitOrCancellation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let activeBefore = registry.snapshot()
        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        let owned = try #require(candidate.ownedReferences.first)
        let prepared = try registry.prepareCommit(candidate)
        #expect(registry.snapshot().preparedCandidateCount == 1)
        #expect(throws: DocumentPaintSurfaceStoreError
            .preparedCandidateRequiresExplicitCancellation) {
            try registry.discard(candidate)
        }
        registry.cancelPrepared(prepared)
        #expect(registry.snapshot() == activeBefore)
        #expect(registry.sharedTileStore.lookup(
            surfaceID: owned.physicalSurfaceID,
            layerID: owned.layerID,
            generation: owned.physicalGeneration,
            coordinate: owned.coordinate
        ) == nil)

        // Both terminal APIs are idempotent after the one ownership token was
        // consumed; the cancelled candidate can never publish later.
        registry.commitPrepared(prepared)
        registry.cancelPrepared(prepared)
        #expect(registry.snapshot() == activeBefore)

        let committedCandidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 1, y: 0)]]
        )
        let committed = try registry.prepareCommit(committedCandidate)
        registry.commitPrepared(committed)
        let afterCommit = registry.snapshot()
        registry.commitPrepared(committed)
        registry.cancelPrepared(committed)
        #expect(registry.snapshot() == afterCommit)
    }

    @Test
    func candidatePrunesOnlyExactOwnedDirtyReferencesBeforePublication() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let baseCoordinate = PaintTileCoordinate(x: 0, y: 0)
        let firstDirty = PaintTileCoordinate(x: 1, y: 0)
        let secondDirty = PaintTileCoordinate(x: 2, y: 0)

        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [baseCoordinate]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [firstDirty, secondDirty]]
        )
        let leasedView = try candidate.binding(for: layer).canonical
        let firstReference = try #require(leasedView.references.first {
            $0.coordinate == firstDirty
        })
        let lease = try leasedView.leaseExistingTiles(
            at: [firstDirty],
            pinReasons: [.visible]
        )
        let initialBytes = registry.sharedTileStore.snapshot().residentByteCount

        #expect(throws: DocumentPaintSurfaceStoreError.unsortedCoordinate(
            previous: secondDirty,
            current: firstDirty
        )) {
            try registry.pruneFullyTransparentCoordinates(
                [secondDirty, firstDirty],
                from: candidate,
                layerID: layer
            )
        }
        #expect(throws: DocumentPaintSurfaceStoreError
            .duplicateCoordinate(firstDirty)) {
            try registry.pruneFullyTransparentCoordinates(
                [firstDirty, firstDirty],
                from: candidate,
                layerID: layer
            )
        }
        #expect(throws: DocumentPaintSurfaceStoreError
            .unownedCandidateCoordinate(baseCoordinate)) {
            try registry.pruneFullyTransparentCoordinates(
                [baseCoordinate],
                from: candidate,
                layerID: layer
            )
        }

        try registry.pruneFullyTransparentCoordinates(
            [firstDirty],
            from: candidate,
            layerID: layer
        )
        let deferred = registry.sharedTileStore.snapshot()
        #expect(deferred.preparedRetirementCount == 0)
        #expect(deferred.pendingRetirementCount == 1)
        #expect(deferred.residentByteCount == initialBytes)
        #expect(candidate.ownedReferences.map(\.coordinate) == [secondDirty])
        #expect(try candidate.binding(for: layer).canonical.references.map(
            \.coordinate
        ) == [baseCoordinate, secondDirty])
        #expect(registry.sharedTileStore.isRetirementPending(firstReference))

        try leasedView.returnLease(lease)
        let returned = registry.sharedTileStore.snapshot()
        #expect(returned.preparedRetirementCount == 0)
        #expect(returned.pendingRetirementCount == 0)
        #expect(returned.residentByteCount == initialBytes - tileBytes)

        try registry.pruneFullyTransparentCoordinates(
            [secondDirty],
            from: candidate,
            layerID: layer
        )
        let fullyPruned = registry.sharedTileStore.snapshot()
        #expect(candidate.ownedReferences.isEmpty)
        #expect(fullyPruned.residentByteCount == initialBytes - tileBytes * 2)
        let beforeEmptyPrune = fullyPruned
        try registry.pruneFullyTransparentCoordinates(
            [],
            from: candidate,
            layerID: layer
        )
        #expect(registry.sharedTileStore.snapshot() == beforeEmptyPrune)

        let prepared = try registry.prepareCommit(candidate)
        #expect(registry.sharedTileStore.snapshot().preparedRetirementCount == 2)
        registry.commitPreparedForCoordinator(prepared)
        #expect(registry.sharedTileStore.snapshot().preparedRetirementCount == 0)
        #expect(try registry.binding(for: layer).canonical.references.map(
            \.coordinate
        ) == [baseCoordinate])
        #expect(throws: DocumentPaintSurfaceStoreError.candidateAlreadyConsumed) {
            _ = try candidate.binding(for: layer)
        }
    }

    @Test
    func candidatePruneRejectsForeignAndStaleCandidatesWithoutMutation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let stale = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [coordinate]]
        )
        let winner = try registry.makeCandidate()
        registry.commitPrepared(try registry.prepareCommit(winner))
        let staleSnapshot = registry.sharedTileStore.snapshot()
        #expect(throws: DocumentPaintSurfaceStoreError.staleCandidate(
            expectedGeneration: registry.generation,
            actualGeneration: stale.baseGeneration
        )) {
            try registry.pruneFullyTransparentCoordinates(
                [coordinate],
                from: stale,
                layerID: layer
            )
        }
        #expect(registry.sharedTileStore.snapshot() == staleSnapshot)
        try registry.discard(stale)

        let foreignRegistry = try makeRegistry(device: device, layers: [layer])
        let foreign = try foreignRegistry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [coordinate]]
        )
        let beforeForeign = registry.sharedTileStore.snapshot()
        #expect(throws: DocumentPaintSurfaceStoreError.foreignCandidate) {
            try registry.pruneFullyTransparentCoordinates(
                [coordinate],
                from: foreign,
                layerID: layer
            )
        }
        #expect(registry.sharedTileStore.snapshot() == beforeForeign)
        try foreignRegistry.discard(foreign)
    }

    @Test
    func retirementDeletesImmediatelyOrAfterFinalLeaseAndCanBeCancelled() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: tileBytes * 3)
        let layer = UUID()
        let size = PixelSize(width: 768, height: 256)
        let immediate = try seed(
            store: store, surfaceID: UUID(), layerID: layer,
            generation: 1, size: size, coordinate: .init(x: 0, y: 0)
        )
        let deferred = try seed(
            store: store, surfaceID: UUID(), layerID: layer,
            generation: 1, size: size, coordinate: .init(x: 1, y: 0)
        )
        let cancelled = try seed(
            store: store, surfaceID: UUID(), layerID: layer,
            generation: 1, size: size, coordinate: .init(x: 2, y: 0)
        )
        let owner = UUID()
        let lease = try store.reserveReferences(
            [deferred],
            leaseSurfaceID: owner,
            leaseLayerID: layer,
            leaseGeneration: 2,
            pinReasons: [.visible]
        )
        #expect(throws: PaintTileStoreError.outstandingLeases(
            surfaceID: deferred.physicalSurfaceID,
            generation: deferred.physicalGeneration,
            count: 1
        )) {
            try store.retire(
                surfaceID: deferred.physicalSurfaceID,
                generation: deferred.physicalGeneration
            )
        }
        let immediatePlan = try store.prepareRetirement([immediate])
        #expect(store.snapshot().preparedRetirementCount == 1)
        #expect(store.snapshot().pendingRetirementCount == 0)
        store.requestRetirement(immediatePlan)
        #expect(store.snapshot().preparedRetirementCount == 0)
        #expect(store.snapshot().pendingRetirementCount == 0)
        #expect(try store.references(
            surfaceID: immediate.physicalSurfaceID,
            layerID: layer,
            generation: immediate.physicalGeneration
        ).isEmpty)

        let deferredPlan = try store.prepareRetirement([deferred])
        #expect(store.snapshot().preparedRetirementCount == 1)
        store.requestRetirement(deferredPlan)
        #expect(store.snapshot().preparedRetirementCount == 0)
        #expect(store.snapshot().pendingRetirementCount == 1)
        #expect(store.isRetirementPending(deferred))
        try store.release(lease, surfaceID: owner, currentGeneration: 2)
        #expect(store.snapshot().pendingRetirementCount == 0)
        #expect(!store.isRetirementPending(deferred))
        #expect(try store.references(
            surfaceID: deferred.physicalSurfaceID,
            layerID: layer,
            generation: deferred.physicalGeneration
        ).isEmpty)

        let cancelPlan = try store.prepareRetirement([cancelled])
        #expect(store.snapshot().preparedRetirementCount == 1)
        store.cancelRetirement(cancelPlan)
        #expect(store.snapshot().preparedRetirementCount == 0)
        #expect(store.snapshot().pendingRetirementCount == 0)
        #expect(try store.references(
            surfaceID: cancelled.physicalSurfaceID,
            layerID: layer,
            generation: cancelled.physicalGeneration
        ) == [cancelled])
    }

    private func makeRegistry(
        device: any MTLDevice,
        layers: [UUID]
    ) throws -> DocumentPaintSurfaceStore {
        try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes * 16,
            geometry: DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 1_024, height: 1_024),
                storagePixelSize: PixelSize(width: 1_024, height: 1_024),
                radialLayout: nil
            ),
            layerIDs: layers
        )
    }

    private func seed(
        store: PaintTileStore,
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64,
        size: PixelSize,
        coordinate: PaintTileCoordinate
    ) throws -> PaintTileReference {
        let lease = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            pixelSize: size,
            coordinates: [coordinate],
            pinReasons: [.dirty]
        )
        try store.markModified(
            lease, surfaceID: surfaceID, currentGeneration: generation
        )
        try store.release(
            lease, surfaceID: surfaceID, currentGeneration: generation
        )
        return try #require(store.references(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation
        ).first)
    }
}
