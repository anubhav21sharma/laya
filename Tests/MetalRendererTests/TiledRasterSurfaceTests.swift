import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Tiled raster surface", .serialized)
struct TiledRasterSurfaceTests {
    private let bytes = PaintTileDescriptor.residentByteCount

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
