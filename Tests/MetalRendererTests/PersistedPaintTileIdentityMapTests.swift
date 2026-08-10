import EditorCore
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Persisted paint tile identity bijection", .serialized)
struct PersistedPaintTileIdentityMapTests {
    @Test
    func publicationAssignsOneStableIDAcrossEvictionAndPageIn() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let store = try makeStore(device: device, layerID: layerID)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)

        let candidate = try store.makeCandidate(
            dirtyCoordinatesByLayer: [layerID: [coordinate]]
        )
        #expect(store.persistedTileIdentitySnapshot().bindings.isEmpty)
        let prepared = try store.prepareCommit(candidate)
        #expect(store.persistedTileIdentitySnapshot().bindings.isEmpty)
        store.commitPrepared(prepared)

        let published = store.persistedTileIdentitySnapshot()
        let binding = try #require(published.bindings.first)
        #expect(published.bindings.count == 1)
        #expect(binding.identity.coordinate == coordinate)
        #expect(binding.identity.layerID == layerID)

        let reference = try #require(
            store.snapshot().layers.first?.references.first
        )
        _ = try store.sharedTileStore.applyMemoryPressure(
            targetResidentBytes: 0
        )
        let pageIn = try store.sharedTileStore.reserveReferences(
            [reference],
            leaseSurfaceID: reference.physicalSurfaceID,
            leaseLayerID: layerID,
            leaseGeneration: reference.physicalGeneration,
            pinReasons: [.inFlight]
        )
        try store.sharedTileStore.release(
            pageIn,
            surfaceID: reference.physicalSurfaceID,
            currentGeneration: reference.physicalGeneration
        )

        #expect(store.persistedTileIdentitySnapshot() == published)
        #expect(store.persistedTileIdentitySnapshot()
            .persistedID(for: reference.identity) == binding.persistedID)
    }

    @Test
    func discardedCandidateNeverPublishesItsGeneratedID() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let store = try makeStore(device: device, layerID: layerID)
        let candidate = try store.makeCandidate(
            dirtyCoordinatesByLayer: [
                layerID: [PaintTileCoordinate(x: 0, y: 0)],
            ]
        )

        #expect(candidate.persistedTileIdentitySnapshot.bindings.count == 1)
        #expect(store.persistedTileIdentitySnapshot().bindings.isEmpty)
        try store.discard(candidate)
        #expect(store.persistedTileIdentitySnapshot().bindings.isEmpty)
    }

    @Test
    func copyOnWriteAndHistoryRestorePreserveTheLogicalUUIDExactly() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let store = try makeStore(device: device, layerID: layerID)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let initial = try store.makeCandidate(
            dirtyCoordinatesByLayer: [layerID: [coordinate]]
        )
        store.commitPrepared(try store.prepareCommit(initial))
        let before = try #require(
            store.persistedTileIdentitySnapshot().bindings.first
        )

        let replacement = try store.makeCandidate(
            dirtyCoordinatesByLayer: [layerID: [coordinate]]
        )
        let history = try store.prepareLayerSurfaceHistoryRevision(
            for: replacement
        )
        store.commitPrepared(try store.prepareCommit(replacement))
        let after = try #require(
            store.persistedTileIdentitySnapshot().bindings.first
        )
        #expect(after.persistedID == before.persistedID)
        #expect(after.identity != before.identity)

        let borrowBefore = try history.borrow()
        let undo = try store.prepareLayerSurfaceRestoreCommit(
            borrowBefore,
            endpoint: .before
        )
        store.commitPrepared(undo)
        borrowBefore.close()
        #expect(store.persistedTileIdentitySnapshot().bindings == [before])

        let borrowAfter = try history.borrow()
        let redo = try store.prepareLayerSurfaceRestoreCommit(
            borrowAfter,
            endpoint: .after
        )
        store.commitPrepared(redo)
        borrowAfter.close()
        #expect(store.persistedTileIdentitySnapshot().bindings == [after])
        history.close()
    }

    @Test
    func layerDeleteAndRestoreRemoveAndReinstallTheExactBinding() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let first = try persistedIdentityLayer(201, name: "First")
        let second = try persistedIdentityLayer(202, name: "Second")
        var stack = try LayerStack(
            layers: [first, second],
            activeLayerID: second.id
        )
        let store = try makeStore(device: device, stack: stack)
        let seeded = try store.makeCandidate(
            dirtyCoordinatesByLayer: [
                first.id: [PaintTileCoordinate(x: 0, y: 0)],
                second.id: [PaintTileCoordinate(x: 1, y: 0)],
            ]
        )
        store.commitPrepared(try store.prepareCommit(seeded))
        let before = store.persistedTileIdentitySnapshot()
        let removed = try #require(before.bindings.first {
            $0.identity.layerID == second.id
        })

        _ = try stack.delete(second.id)
        let deletion = try store.makeCandidate(layerStack: stack)
        let history = try store.prepareLayerSurfaceHistoryRevision(
            for: deletion
        )
        store.commitPrepared(try store.prepareCommit(deletion))
        #expect(store.persistedTileIdentitySnapshot()
            .identity(for: removed.persistedID) == nil)

        let borrow = try history.borrow()
        let undo = try store.prepareLayerSurfaceRestoreCommit(
            borrow,
            endpoint: .before
        )
        store.commitPrepared(undo)
        borrow.close()
        #expect(store.persistedTileIdentitySnapshot() == before)
        history.close()
    }

    @Test
    func trustedImportRejectsDuplicateIDAndCoordinateDisagreement() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let store = try makeStore(device: device, layerID: layerID)
        let persistedID = UUID()
        let first = PaintTileCoordinate(x: 0, y: 0)
        let second = PaintTileCoordinate(x: 1, y: 0)

        #expect(throws: PersistedPaintTileIdentityMapError
            .duplicatePersistedID(persistedID)) {
            _ = try store.makeCandidate(
                dirtyCoordinatesByLayer: [layerID: [first, second]],
                importedPersistedTileBindings: [
                    .init(
                        persistedID: persistedID,
                        layerID: layerID,
                        coordinate: first
                    ),
                    .init(
                        persistedID: persistedID,
                        layerID: layerID,
                        coordinate: second
                    ),
                ]
            )
        }
        #expect(store.persistedTileIdentitySnapshot().bindings.isEmpty)

        #expect(throws: PersistedPaintTileIdentityMapError
            .importCoordinateMissing(
                layerID: layerID,
                coordinate: second
            )) {
            _ = try store.makeCandidate(
                dirtyCoordinatesByLayer: [layerID: [first]],
                importedPersistedTileBindings: [
                    .init(
                        persistedID: UUID(),
                        layerID: layerID,
                        coordinate: second
                    ),
                ]
            )
        }
        #expect(store.persistedTileIdentitySnapshot().bindings.isEmpty)
    }

    @Test
    func trustedImportBindsManifestIDToFreshRuntimeIdentityOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let store = try makeStore(device: device, layerID: layerID)
        let persistedID = UUID()
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let candidate = try store.makeCandidate(
            dirtyCoordinatesByLayer: [layerID: [coordinate]],
            importedPersistedTileBindings: [
                .init(
                    persistedID: persistedID,
                    layerID: layerID,
                    coordinate: coordinate
                ),
            ]
        )
        let candidateBinding = try #require(
            candidate.persistedTileIdentitySnapshot.bindings.first
        )
        #expect(candidateBinding.persistedID == persistedID)
        #expect(store.persistedTileIdentitySnapshot().bindings.isEmpty)

        store.commitPrepared(try store.prepareCommit(candidate))
        let installed = store.persistedTileIdentitySnapshot()
        #expect(installed.bindings == [candidateBinding])
        #expect(installed.identity(for: persistedID)
            == candidateBinding.identity)
    }

    @Test
    func unownedRegeneratedRuntimeIdentityFailsBeforeSnapshotCreation() throws {
        let storeIdentity = PaintTileStoreIdentity()
        let layerID = UUID()
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let descriptor = try PaintTileDescriptor(
            coordinate: coordinate,
            logicalPixelSize: PixelSize(width: 256, height: 256)
        )
        let oldIdentity = PaintTileIdentity(
            layerID: layerID,
            coordinate: coordinate,
            tileID: PaintTileID(rawValue: 1)
        )
        let regeneratedIdentity = PaintTileIdentity(
            layerID: layerID,
            coordinate: coordinate,
            tileID: PaintTileID(rawValue: 2)
        )
        let surfaceID = UUID()
        let oldReference = PaintTileReference(
            storeIdentity: storeIdentity,
            physicalSurfaceID: surfaceID,
            layerID: layerID,
            physicalGeneration: 1,
            identity: oldIdentity,
            descriptor: descriptor
        )
        let regeneratedReference = PaintTileReference(
            storeIdentity: storeIdentity,
            physicalSurfaceID: surfaceID,
            layerID: layerID,
            physicalGeneration: 2,
            identity: regeneratedIdentity,
            descriptor: descriptor
        )
        let persistedID = UUID()
        let installed = try PersistedPaintTileIdentitySnapshot(validating: [
            .init(persistedID: persistedID, identity: oldIdentity),
        ])

        #expect(throws: PersistedPaintTileIdentityMapError
            .regeneratedRuntimeIdentity(
                layerID: layerID,
                coordinate: coordinate,
                expected: oldIdentity,
                actual: regeneratedIdentity
            )) {
            _ = try PersistedPaintTileIdentityMap.transition(
                from: installed,
                baseReferences: [oldReference],
                candidateReferences: [regeneratedReference],
                candidateOwnedReferences: [],
                imports: []
            )
        }
    }

    @Test
    func nativeArchiveCaptureRetainsOneExactMultiLayerEpochUntilClose()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let first = try persistedIdentityLayer(301, name: "Bottom")
        let second = try persistedIdentityLayer(302, name: "Top")
        let stack = try LayerStack(
            layers: [first, second],
            activeLayerID: second.id
        )
        let store = try makeStore(device: device, stack: stack)
        let firstCoordinate = PaintTileCoordinate(x: 0, y: 0)
        let secondCoordinate = PaintTileCoordinate(x: 1, y: 0)
        let seeded = try store.makeCandidate(
            dirtyCoordinatesByLayer: [
                first.id: [firstCoordinate],
                second.id: [secondCoordinate],
            ]
        )
        store.commitPrepared(try store.prepareCommit(seeded))
        let published = store.persistedTileIdentitySnapshot()

        let capture = try store.captureNativeArchive()
        #expect(capture.documentGeneration == store.generation)
        #expect(capture.geometry == store.geometry)
        #expect(capture.layerStack == stack)
        #expect(capture.layers.map(\.layerID) == [first.id, second.id])
        let capturedIDs = capture.layers.flatMap { $0.tiles }
            .map { $0.persistedID }
            .sorted {
            $0.uuidString < $1.uuidString
        }
        let publishedIDs = published.bindings.map { $0.persistedID }.sorted {
            $0.uuidString < $1.uuidString
        }
        #expect(capturedIDs == publishedIDs)
        #expect(store.sharedTileStore.snapshot().activeSnapshotTokenCount == 1)

        let oldTiles = capture.layers.flatMap(\.tiles)
        for tile in oldTiles {
            #expect(try capture.payload(for: tile.persistedID)
                == Data(count: PaintTileDescriptor.residentByteCount))
        }

        let replacement = try store.makeCandidate(
            dirtyCoordinatesByLayer: [first.id: [firstCoordinate]]
        )
        store.commitPrepared(try store.prepareCommit(replacement))
        #expect(store.persistedTileIdentitySnapshot() != published)
        for tile in oldTiles {
            #expect(try capture.payload(for: tile.persistedID)
                == Data(count: PaintTileDescriptor.residentByteCount))
        }

        capture.close()
        #expect(store.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
        let firstTile = try #require(oldTiles.first)
        #expect(throws: TiledRasterSurfaceError
            .exactReferenceCaptureClosed) {
            try capture.payload(for: firstTile.persistedID)
        }
    }

    private func makeStore(
        device: any MTLDevice,
        layerID: UUID
    ) throws -> DocumentPaintSurfaceStore {
        let descriptor = try LayerDescriptor(id: layerID, name: "Layer")
        return try makeStore(
            device: device,
            stack: LayerStack(layers: [descriptor], activeLayerID: layerID)
        )
    }

    private func makeStore(
        device: any MTLDevice,
        stack: LayerStack
    ) throws -> DocumentPaintSurfaceStore {
        let size = PixelSize(width: 512, height: 256)
        return try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount * 8,
            geometry: DocumentPaintGeometry(
                documentPixelSize: size,
                storagePixelSize: size,
                radialLayout: nil
            ),
            layerIDs: stack.orderedLayerIDs,
            layerStack: stack
        )
    }
}

private func persistedIdentityLayer(
    _ value: Int,
    name: String
) throws -> LayerDescriptor {
    try LayerDescriptor(
        id: UUID(uuidString: String(
            format: "00000000-0000-0000-0002-%012d",
            value
        ))!,
        name: name
    )
}
