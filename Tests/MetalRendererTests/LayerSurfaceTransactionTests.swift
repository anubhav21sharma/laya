import EditorCore
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Atomic layer surface transactions", .serialized)
struct LayerSurfaceTransactionTests {
    @Test
    @MainActor
    func resizeCopiesEveryLayerBeforeOneGeometryPublication() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return }
        let bottom = try layer(101, name: "Bottom")
        let top = try layer(102, name: "Top")
        let stack = try LayerStack(
            layers: [bottom, top],
            activeLayerID: top.id
        )
        let store = try makeStore(device: device, stack: stack)
        let seeded = try store.makeCandidate(
            dirtyCoordinatesByLayer: [
                bottom.id: [.init(x: 0, y: 0)],
                top.id: [.init(x: 0, y: 0)],
            ]
        )
        store.commitPrepared(try store.prepareCommit(seeded))
        try fillFirstPixel(
            SIMD4<Float>(0.25, 0, 0, 0.25),
            layerID: bottom.id,
            store: store
        )
        try fillFirstPixel(
            SIMD4<Float>(0, 0.5, 0, 0.5),
            layerID: top.id,
            store: store
        )
        let before = store.snapshot()
        let targetGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 256, height: 512),
            storagePixelSize: PixelSize(width: 256, height: 512),
            radialLayout: nil
        )
        let pipelines = try DocumentPaintSurfaceMutationPipelineLibrary.prepare(
            device: device,
            library: library
        )
        let backend = try DocumentPaintSurfaceMetalBackend(
            device: device,
            commandQueue: queue,
            pipelines: pipelines
        )

        let prepared = try store.prepareLayerSurfaceResizeTransaction(
            layerStack: stack,
            geometry: targetGeometry,
            targetRadialConfiguration: nil,
            backend: backend
        )

        #expect(store.snapshot().geometry == before.geometry)
        #expect(store.snapshot().generation == before.generation)
        let receipt = prepared.commit()
        #expect(receipt.baseGeneration == before.generation)
        #expect(receipt.generation == before.generation + 1)
        #expect(receipt.before == stack)
        #expect(receipt.after == stack)
        #expect(store.snapshot().geometry == targetGeometry)
        #expect(try firstPixel(layerID: bottom.id, store: store)
            == SIMD4<Float>(0.25, 0, 0, 0.25))
        #expect(try firstPixel(layerID: top.id, store: store)
            == SIMD4<Float>(0, 0.5, 0, 0.5))
        #expect(store.snapshot().layers.allSatisfy {
            $0.references.map(\.coordinate) == [.init(x: 0, y: 0)]
        })
        #expect(receipt.historyRevision.retainedBytes
            == PaintTileDescriptor.residentByteCount * 4)
        receipt.historyRevision.close()
    }

    @Test
    @MainActor
    func radialLayoutChangeRestoresEveryLayerExactReferenceOnUndo() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return }
        let bottom = try layer(111, name: "Bottom")
        let top = try layer(112, name: "Top")
        let stack = try LayerStack(
            layers: [bottom, top],
            activeLayerID: top.id
        )
        let canvas = PixelSize(width: 256, height: 256)
        let sourceConfiguration = RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 4,
            center: WorldPoint(x: 128, y: 128)
        )
        let targetConfiguration = RadialSymmetryConfiguration(
            kind: .mirror,
            rayCount: 6,
            center: WorldPoint(x: 128, y: 128)
        )
        let sourceGeometry = try radialGeometry(
            sourceConfiguration,
            canvas: canvas
        )
        let targetGeometry = try radialGeometry(
            targetConfiguration,
            canvas: canvas
        )
        let sourceLayout = try #require(sourceGeometry.radialLayout)
        let sourcePage = try #require(sourceLayout.residentPages.first)
        let sourceCoordinate = PaintTileCoordinate(
            x: sourcePage.atlasSlot % sourceLayout.atlasColumns,
            y: sourcePage.atlasSlot / sourceLayout.atlasColumns
        )
        let store = try makeStore(
            device: device,
            stack: stack,
            geometry: sourceGeometry
        )
        let seeded = try store.makeCandidate(
            dirtyCoordinatesByLayer: [
                bottom.id: [sourceCoordinate],
                top.id: [sourceCoordinate],
            ]
        )
        store.commitPrepared(try store.prepareCommit(seeded))
        let before = store.snapshot()
        let backend = try DocumentPaintSurfaceMetalBackend(
            device: device,
            commandQueue: queue,
            pipelines: try DocumentPaintSurfaceMutationPipelineLibrary.prepare(
                device: device,
                library: library
            )
        )

        let receipt = try store.prepareLayerSurfaceResizeTransaction(
            layerStack: stack,
            geometry: targetGeometry,
            targetRadialConfiguration: targetConfiguration,
            backend: backend
        ).commit()

        #expect(store.snapshot().geometry == targetGeometry)
        #expect(store.snapshot().layers.allSatisfy { !$0.references.isEmpty })
        _ = try store.prepareLayerSurfaceRestore(
            receipt.historyRevision,
            endpoint: .before
        ).commit()
        #expect(store.snapshot().geometry == sourceGeometry)
        #expect(store.snapshot().layerStack == stack)
        #expect(store.snapshot().layers == before.layers)
        receipt.historyRevision.close()
    }

    @Test
    @MainActor
    func resizeEncoderFailureLeavesAllLayersAndOwnershipUntouched() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return }
        let bottom = try layer(121, name: "Bottom")
        let top = try layer(122, name: "Top")
        let stack = try LayerStack(
            layers: [bottom, top],
            activeLayerID: top.id
        )
        let store = try makeStore(device: device, stack: stack)
        let seeded = try store.makeCandidate(
            dirtyCoordinatesByLayer: [
                bottom.id: [.init(x: 0, y: 0)],
                top.id: [.init(x: 0, y: 0)],
            ]
        )
        store.commitPrepared(try store.prepareCommit(seeded))
        let before = store.snapshot()
        let backend = try DocumentPaintSurfaceMetalBackend(
            device: device,
            commandQueue: queue,
            pipelines: try DocumentPaintSurfaceMutationPipelineLibrary.prepare(
                device: device,
                library: library
            ),
            failureInjection: .init(failingOnceAt: .encoder)
        )
        let targetGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 256, height: 512),
            storagePixelSize: PixelSize(width: 256, height: 512),
            radialLayout: nil
        )

        #expect(throws: DocumentPaintSurfaceMetalBackendError.encoderUnavailable) {
            _ = try store.prepareLayerSurfaceResizeTransaction(
                layerStack: stack,
                geometry: targetGeometry,
                targetRadialConfiguration: nil,
                backend: backend
            )
        }

        #expect(store.snapshot() == before)
        let tile = store.sharedTileStore.snapshot()
        #expect(tile.activeLeaseCount == 0)
        #expect(tile.preparedRetirementCount == 0)
        #expect(tile.pendingRetirementCount == 0)
        #expect(tile.activeSnapshotTokenCount == 0)
        #expect(backend.debugSnapshot.activeTokenCount == 0)
        #expect(backend.debugSnapshot.activeRetainedTextureCount == 0)
    }

    @Test
    func addReorderVisibilityOpacityLockAndActivePublishAsOneEpoch() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = try layer(1, name: "Bottom")
        let top = try layer(2, name: "Top")
        let initial = try LayerStack(
            layers: [bottom, top],
            activeLayerID: top.id
        )
        let store = try makeStore(device: device, stack: initial)
        let added = try layer(3, name: "Added")
        var target = initial
        try target.add(added, at: 1)
        try target.move(top.id, to: 0)
        try target.setVisibility(bottom.id, isVisible: false)
        try target.setOpacity(added.id, opacity: 0.5)
        try target.setLock(added.id, isLocked: true)
        try target.setBlendMode(added.id, blendMode: .screen)
        try target.setActiveLayer(bottom.id)
        let before = store.snapshot()

        let prepared = try store.prepareLayerSurfaceTransaction(
            layerStack: target
        )

        let whilePrepared = store.snapshot()
        #expect(whilePrepared.generation == before.generation)
        #expect(whilePrepared.geometry == before.geometry)
        #expect(whilePrepared.layerStack == before.layerStack)
        #expect(whilePrepared.layers == before.layers)
        #expect(whilePrepared.residentTileBytes == before.residentTileBytes)
        #expect(whilePrepared.activeTileLeaseCount
            == before.activeTileLeaseCount)
        #expect(whilePrepared.preparedCandidateCount == 1)
        let receipt = prepared.commit()
        let after = store.snapshot()
        #expect(receipt.before == initial)
        #expect(receipt.after == target)
        #expect(receipt.baseGeneration == before.generation)
        #expect(receipt.generation == before.generation + 1)
        #expect(receipt.addedLayerIDs == [added.id])
        #expect(receipt.removedLayerIDs.isEmpty)
        #expect(after.layerStack == target)
        #expect(after.layers.map(\.layerID) == target.orderedLayerIDs)
        #expect(after.layers.first { $0.layerID == added.id }?.references == [])
        #expect(after.preparedCandidateCount == 0)
    }

    @Test
    func cancelAndAllocationFailureLeaveOldStackPixelsAndDebtUntouched() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let first = try layer(11, name: "First")
        let initial = try LayerStack(
            layers: [first],
            activeLayerID: first.id
        )
        let store = try makeStore(device: device, stack: initial)
        let added = try layer(12, name: "Added")
        var target = initial
        try target.add(added, at: 1)
        let before = store.snapshot()
        #expect(throws: PaintTileStoreError.injectedAllocationFailure(
            reserveIndex: 0
        )) {
            _ = try store.prepareLayerSurfaceTransaction(
                layerStack: target,
                dirtyCoordinatesByLayer: [added.id: [.init(x: 0, y: 0)]],
                failureInjection: .init(failingAtReserveIndex: 0)
            )
        }
        #expect(store.snapshot() == before)

        let prepared = try store.prepareLayerSurfaceTransaction(
            layerStack: target,
            dirtyCoordinatesByLayer: [added.id: [.init(x: 0, y: 0)]]
        )
        #expect(store.snapshot().preparedCandidateCount == 1)
        prepared.cancel()
        prepared.cancel()
        #expect(store.snapshot() == before)
        let tile = store.sharedTileStore.snapshot()
        #expect(tile.activeLeaseCount == 0)
        #expect(tile.preparedRetirementCount == 0)
        #expect(tile.pendingRetirementCount == 0)
        #expect(tile.activeSnapshotTokenCount == 0)
    }

    @Test
    func deletePublishesActiveFallbackAndRetiresOnlyRemovedLayer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = try layer(21, name: "Bottom")
        let active = try layer(22, name: "Active")
        let initial = try LayerStack(
            layers: [bottom, active],
            activeLayerID: active.id
        )
        let store = try makeStore(device: device, stack: initial)
        let seeded = try store.makeCandidate(
            dirtyCoordinatesByLayer: [
                bottom.id: [.init(x: 0, y: 0)],
                active.id: [.init(x: 1, y: 0)],
            ]
        )
        store.commitPrepared(try store.prepareCommit(seeded))
        let oldActiveBinding = try store.binding(for: active.id).canonical
        let oldActiveReference = try #require(oldActiveBinding.references.first)
        let oldBottomReference = try #require(
            store.binding(for: bottom.id).canonical.references.first
        )
        var target = store.layerStack
        let removal = try target.delete(active.id)
        #expect(removal.activeLayerIDAfter == bottom.id)

        let receipt = try store.prepareLayerSurfaceTransaction(
            layerStack: target
        ).commit()

        #expect(receipt.removedLayerIDs == [active.id])
        #expect(store.layerStack == target)
        #expect(try store.binding(for: bottom.id).canonical.references
            == [oldBottomReference])
        #expect(throws: DocumentPaintSurfaceStoreError
            .unknownLayerID(active.id)) {
            _ = try store.binding(for: active.id)
        }
        receipt.historyRevision.close()
        #expect(!store.sharedTileStore.snapshot().entries.contains {
            $0.identity == oldActiveReference.identity
        })
    }

    @Test
    func deleteUndoRedoPreservesExactLayerAndTileRevision() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = try layer(31, name: "Bottom")
        let active = try LayerDescriptor(
            id: layer(32, name: "Active").id,
            name: "Active",
            isVisible: true,
            opacity: 0.625,
            isLocked: true,
            blendMode: .multiply
        )
        let initial = try LayerStack(
            layers: [bottom, active],
            activeLayerID: active.id
        )
        let store = try makeStore(device: device, stack: initial)
        let seeded = try store.makeCandidate(
            dirtyCoordinatesByLayer: [
                bottom.id: [.init(x: 0, y: 0)],
                active.id: [.init(x: 1, y: 0)],
            ]
        )
        store.commitPrepared(try store.prepareCommit(seeded))
        let beforeDelete = store.snapshot()
        let activeCanonical = try store.binding(for: active.id).canonical
        let activeReferences = activeCanonical.references
        let activeSurfaceRevision = activeCanonical.revision
        let activeEntries = try store.sharedTileStore.snapshot(
            exactReferences: activeReferences
        )
        var deletedStack = store.layerStack
        _ = try deletedStack.delete(active.id)

        let deletion = try store.prepareLayerSurfaceTransaction(
            layerStack: deletedStack
        ).commit()
        let revision = deletion.historyRevision
        #expect(store.layerStack == deletedStack)
        #expect(store.sharedTileStore.snapshot().activeSnapshotTokenCount == 1)
        #expect(store.sharedTileStore.snapshot().entries.contains {
            $0.identity == activeEntries[0].identity
        })

        let undo = try store.prepareLayerSurfaceRestore(
            revision,
            endpoint: .before
        ).commit()
        #expect(undo.after == beforeDelete.layerStack)
        #expect(store.layerStack == beforeDelete.layerStack)
        let restoredCanonical = try store.binding(for: active.id).canonical
        #expect(restoredCanonical.references == activeReferences)
        #expect(restoredCanonical.revision == activeSurfaceRevision)
        let restoredEntries = try store.sharedTileStore.snapshot(
            exactReferences: activeReferences
        )
        #expect(restoredEntries.map(\.surfaceID)
            == activeEntries.map(\.surfaceID))
        #expect(restoredEntries.map(\.generation)
            == activeEntries.map(\.generation))
        #expect(restoredEntries.map(\.identity)
            == activeEntries.map(\.identity))
        #expect(restoredEntries.map(\.descriptor)
            == activeEntries.map(\.descriptor))
        #expect(restoredEntries.map(\.backing)
            == activeEntries.map(\.backing))

        let redo = try store.prepareLayerSurfaceRestore(
            revision,
            endpoint: .after
        ).commit()
        #expect(redo.after == deletedStack)
        #expect(store.layerStack == deletedStack)
        #expect(throws: DocumentPaintSurfaceStoreError
            .unknownLayerID(active.id)) {
            _ = try store.binding(for: active.id)
        }

        revision.close()
        let terminal = store.sharedTileStore.snapshot()
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(!terminal.entries.contains {
            $0.identity == activeEntries[0].identity
        })
    }

    private func makeStore(
        device: any MTLDevice,
        stack: LayerStack
    ) throws -> DocumentPaintSurfaceStore {
        let size = PixelSize(width: 512, height: 256)
        return try makeStore(
            device: device,
            stack: stack,
            geometry: DocumentPaintGeometry(
                documentPixelSize: size,
                storagePixelSize: size,
                radialLayout: nil
            )
        )
    }

    private func makeStore(
        device: any MTLDevice,
        stack: LayerStack,
        geometry: DocumentPaintGeometry
    ) throws -> DocumentPaintSurfaceStore {
        return try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount * 8,
            geometry: geometry,
            layerIDs: stack.orderedLayerIDs,
            layerStack: stack
        )
    }
}

private func radialGeometry(
    _ configuration: RadialSymmetryConfiguration,
    canvas: PixelSize
) throws -> DocumentPaintGeometry {
    let compiled = try SymmetryDescriptorCompiler.compile(
        finiteConfiguration: .radial(configuration),
        canvasSize: canvas
    )
    let layout = try #require(compiled.domain.finite?.radial.layout)
    return try DocumentPaintGeometry(
        documentPixelSize: canvas,
        storagePixelSize: layout.atlasPixelSize,
        radialLayout: layout
    )
}

private func fillFirstPixel(
    _ value: SIMD4<Float>,
    layerID: UUID,
    store: DocumentPaintSurfaceStore
) throws {
    let binding = try store.binding(for: layerID).canonical
    let lease = try binding.leaseExistingTiles(
        at: [.init(x: 0, y: 0)],
        pinReasons: [.inFlight]
    )
    defer { try? binding.returnLease(lease) }
    let texture = try #require(lease.bindings.first?.texture)
    var encoded = SIMD4<UInt16>(
        Float16(value.x).bitPattern,
        Float16(value.y).bitPattern,
        Float16(value.z).bitPattern,
        Float16(value.w).bitPattern
    )
    texture.replace(
        region: MTLRegionMake2D(0, 0, 1, 1),
        mipmapLevel: 0,
        withBytes: &encoded,
        bytesPerRow: MemoryLayout<UInt16>.stride * 4
    )
}

private func firstPixel(
    layerID: UUID,
    store: DocumentPaintSurfaceStore
) throws -> SIMD4<Float> {
    let binding = try store.binding(for: layerID).canonical
    let lease = try binding.leaseExistingTiles(
        at: [.init(x: 0, y: 0)],
        pinReasons: [.inFlight]
    )
    defer { try? binding.returnLease(lease) }
    let texture = try #require(lease.bindings.first?.texture)
    var encoded = SIMD4<UInt16>(repeating: 0)
    texture.getBytes(
        &encoded,
        bytesPerRow: MemoryLayout<UInt16>.stride * 4,
        from: MTLRegionMake2D(0, 0, 1, 1),
        mipmapLevel: 0
    )
    return SIMD4<Float>(
        Float(Float16(bitPattern: encoded.x)),
        Float(Float16(bitPattern: encoded.y)),
        Float(Float16(bitPattern: encoded.z)),
        Float(Float16(bitPattern: encoded.w))
    )
}

private func layer(_ value: Int, name: String) throws -> LayerDescriptor {
    try LayerDescriptor(
        id: UUID(uuidString: String(
            format: "00000000-0000-0000-0001-%012d",
            value
        ))!,
        name: name
    )
}
