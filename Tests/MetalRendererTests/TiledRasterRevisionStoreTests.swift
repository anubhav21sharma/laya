import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Tiled raster revision store", .serialized)
struct TiledRasterRevisionStoreTests {
    @Test
    func capturesOneTwoAndFourTilesInDeterministicCoordinateOrder() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 513, height: 513)
        let layerID = tiledRevisionLayerID(1)
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount * 16
        )
        let queue = try #require(device.makeCommandQueue())

        for coordinates in [
            [PaintTileCoordinate(x: 0, y: 0)],
            [.init(x: 1, y: 0), .init(x: 0, y: 0)],
            [
                .init(x: 1, y: 1), .init(x: 0, y: 1),
                .init(x: 1, y: 0), .init(x: 0, y: 0),
            ],
        ] {
            let regions = tiledRevisionRegions(for: coordinates, size: size)
            let pair = try store.allocatePair(
                layerID: layerID,
                generation: 7,
                pixelSize: size,
                dirtyRegions: regions,
                beforePresentCoordinates: coordinates,
                afterPresentCoordinates: coordinates
            )
            let expected = Array(Set(coordinates)).sorted()
            let expectedBytes = try expected.reduce(into: 0) {
                $0 += try tiledRevisionRetainedBytes(
                    coordinate: $1,
                    size: size,
                    device: device
                )
            }
            #expect(pair.before.tileCoordinates == expected.map(\.revisionCoordinate))
            #expect(pair.after.tileCoordinates == expected.map(\.revisionCoordinate))
            #expect(pair.before.retainedBytes == expectedBytes)
            let sources = try expected.enumerated().map { index, coordinate in
                let texture = try tiledRevisionTexture(device: device)
                tiledRevisionUpload(
                    tiledRevisionBytes(seed: UInt8(index + 1)),
                    to: texture
                )
                return TiledRasterRevisionTileSource.texture(
                    coordinate: coordinate,
                    texture: texture
                )
            }
            let capture = try #require(queue.makeCommandBuffer())
            let before = try store.encodeCapture(
                pair.before,
                layerID: layerID,
                generation: 7,
                sources: Array(sources.reversed()),
                on: capture
            )
            let after = try store.encodeCapture(
                pair.after,
                layerID: layerID,
                generation: 7,
                sources: sources,
                on: capture
            )
            capture.commit()
            capture.waitUntilCompleted()
            try tiledRevisionRequireCompleted(capture)
            try store.finalize(before, as: .succeeded)
            try store.finalize(after, as: .succeeded)
            try store.publish(pair)

            let targets = try expected.map {
                TiledRasterRevisionTileTarget(
                    coordinate: $0,
                    texture: try tiledRevisionTexture(device: device)
                )
            }
            let restore = try #require(queue.makeCommandBuffer())
            let restoreToken = try store.encodeRestore(
                pair.before,
                layerID: layerID,
                generation: 7,
                targets: Array(targets.reversed()),
                on: restore
            )
            restore.commit()
            restore.waitUntilCompleted()
            try tiledRevisionRequireCompleted(restore)
            try store.finalize(restoreToken, as: .succeeded)
            for (index, target) in targets.enumerated() {
                let descriptor = try PaintTileDescriptor(
                    coordinate: target.coordinate,
                    logicalPixelSize: size
                )
                let actual = tiledRevisionDownload(target.texture)
                let source = tiledRevisionBytes(seed: UInt8(index + 1))
                #expect(tiledRevisionClippedBytes(
                    actual,
                    width: descriptor.logicalBounds.width,
                    height: descriptor.logicalBounds.height
                ) == tiledRevisionClippedBytes(
                    source,
                    width: descriptor.logicalBounds.width,
                    height: descriptor.logicalBounds.height
                ))
            }
            try store.release(pair.revisionIDs)
        }
    }

    @Test
    func captureRestorePreservesClippedPixelsAndExplicitClearTiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 300, height: 256)
        let layerID = tiledRevisionLayerID(2)
        let first = PaintTileCoordinate(x: 0, y: 0)
        let edge = PaintTileCoordinate(x: 1, y: 0)
        let coordinates = [first, edge]
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount * 4
        )
        let pair = try store.allocatePair(
            layerID: layerID,
            generation: 11,
            pixelSize: size,
            dirtyRegions: tiledRevisionRegions(for: coordinates, size: size),
            beforePresentCoordinates: [first],
            afterPresentCoordinates: [edge]
        )
        #expect(pair.before.retainedBytes == PaintTileDescriptor.residentByteCount)
        let edgeExpectedBytes = try tiledRevisionRetainedBytes(
            coordinate: edge,
            size: size,
            device: device
        )
        #expect(pair.after.retainedBytes == edgeExpectedBytes)

        let beforeTexture = try tiledRevisionTexture(device: device)
        let afterTexture = try tiledRevisionTexture(device: device)
        let beforeBytes = tiledRevisionBytes(seed: 17)
        let afterBytes = tiledRevisionBytes(seed: 91)
        tiledRevisionUpload(beforeBytes, to: beforeTexture)
        tiledRevisionUpload(afterBytes, to: afterTexture)
        let queue = try #require(device.makeCommandQueue())
        let capture = try #require(queue.makeCommandBuffer())
        let beforeToken = try store.encodeCapture(
            pair.before,
            layerID: layerID,
            generation: 11,
            sources: [
                .knownClear(coordinate: edge),
                .texture(coordinate: first, texture: beforeTexture),
            ],
            on: capture
        )
        let afterToken = try store.encodeCapture(
            pair.after,
            layerID: layerID,
            generation: 11,
            sources: [
                .texture(coordinate: edge, texture: afterTexture),
                .knownClear(coordinate: first),
            ],
            on: capture
        )
        capture.commit()
        capture.waitUntilCompleted()
        try tiledRevisionRequireCompleted(capture)
        try store.finalize(beforeToken, as: .succeeded)
        try store.finalize(afterToken, as: .succeeded)
        try store.publish(pair)

        let snapshots = try store.snapshotsForHarness()
        #expect(snapshots.count == 2)
        let beforeSnapshot = try #require(snapshots.first {
            $0.reference.id == pair.before.id
        })
        #expect(beforeSnapshot.payloads.map(\.coordinate) == [first, edge])
        #expect(beforeSnapshot.payloads[0].payload == .rgba16Float(beforeBytes))
        #expect(beforeSnapshot.payloads[1].payload == .knownClear)
        let afterSnapshot = try #require(snapshots.first {
            $0.reference.id == pair.after.id
        })
        guard case let .rgba16Float(edgePayload) = afterSnapshot.payloads[1].payload
        else {
            Issue.record("Edge tile must retain RGBA16F bytes")
            return
        }
        #expect(edgePayload.count == 44 * 256 * 8)
        #expect(edgePayload == tiledRevisionClippedBytes(afterBytes, width: 44, height: 256))

        let restoredFirst = try tiledRevisionTexture(device: device)
        let restoredEdge = try tiledRevisionTexture(device: device)
        tiledRevisionUpload(Data(repeating: 0xA7, count: PaintTileDescriptor.residentByteCount), to: restoredFirst)
        tiledRevisionUpload(Data(repeating: 0xA7, count: PaintTileDescriptor.residentByteCount), to: restoredEdge)
        let restore = try #require(queue.makeCommandBuffer())
        let restoreToken = try store.encodeRestore(
            pair.before,
            layerID: layerID,
            generation: 11,
            targets: [
                .init(coordinate: edge, texture: restoredEdge),
                .init(coordinate: first, texture: restoredFirst),
            ],
            on: restore
        )
        restore.commit()
        restore.waitUntilCompleted()
        try tiledRevisionRequireCompleted(restore)
        try store.finalize(restoreToken, as: .succeeded)
        #expect(tiledRevisionDownload(restoredFirst) == beforeBytes)
        let restoredEdgeBytes = tiledRevisionDownload(restoredEdge)
        #expect(tiledRevisionClippedBytes(restoredEdgeBytes, width: 44, height: 256) == Data(count: 44 * 256 * 8))
        #expect(restoredEdgeBytes[(44 * 8)] == 0xA7)
    }

    @Test
    func eraseToEmptyUsesNoRetainedBufferForAfterRevision() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount
        )
        let pair = try store.allocatePair(
            layerID: tiledRevisionLayerID(3),
            generation: 0,
            pixelSize: PixelSize(width: 256, height: 256),
            dirtyRegions: tiledRevisionRegions(
                for: [coordinate],
                size: PixelSize(width: 256, height: 256)
            ),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: []
        )
        #expect(pair.before.retainedBytes == PaintTileDescriptor.residentByteCount)
        #expect(pair.after.retainedBytes == 0)
        #expect(store.residentBytes == PaintTileDescriptor.residentByteCount)
    }

    @Test
    func finalizedAfterTileSetIsAvailableOnlyWhenTheWholePairIsReady() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 300, height: 256)
        let layerID = tiledRevisionLayerID(30)
        let first = PaintTileCoordinate(x: 0, y: 0)
        let edge = PaintTileCoordinate(x: 1, y: 0)
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount * 3
        )
        let pair = try store.allocatePair(
            layerID: layerID,
            generation: 77,
            pixelSize: size,
            dirtyRegions: tiledRevisionRegions(for: [edge, first], size: size),
            beforePresentCoordinates: [first],
            afterPresentCoordinates: [edge]
        )
        #expect(throws: TiledRasterRevisionStoreError.pairNotReady) {
            _ = try store.finalizedTileSet(for: pair.after)
        }

        let source = try tiledRevisionTexture(device: device)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let before = try store.encodeCapture(
            pair.before,
            layerID: layerID,
            generation: 77,
            sources: [
                .texture(coordinate: first, texture: source),
                .knownClear(coordinate: edge),
            ],
            on: command
        )
        let after = try store.encodeCapture(
            pair.after,
            layerID: layerID,
            generation: 77,
            sources: [
                .knownClear(coordinate: first),
                .texture(coordinate: edge, texture: source),
            ],
            on: command
        )
        command.commit()
        command.waitUntilCompleted()
        try tiledRevisionRequireCompleted(command)
        try store.finalize(before, as: .succeeded)
        #expect(throws: TiledRasterRevisionStoreError.pairNotReady) {
            _ = try store.finalizedTileSet(for: pair.after)
        }
        try store.finalize(after, as: .succeeded)

        let tileSet = try store.finalizedTileSet(for: pair.after)
        #expect(tileSet.reference == pair.after)
        #expect(tileSet.layerID == layerID)
        #expect(tileSet.generation == 77)
        #expect(tileSet.tiles.map(\.descriptor.coordinate) == [first, edge])
        guard case .knownClear = tileSet.tiles[0].payload else {
            Issue.record("Removed tile must remain explicitly clear")
            return
        }
        guard case let .rgba16Float(
            buffer,
            offset,
            bytesPerRow,
            bytesPerImage
        ) = tileSet.tiles[1].payload else {
            Issue.record("Present edge tile must expose retained GPU bytes")
            return
        }
        #expect(buffer.storageMode == .private)
        #expect(offset == 0)
        #expect(bytesPerRow >= 44 * 8)
        #expect(bytesPerImage == bytesPerRow * 256)
        #expect(tileSet.surfaceRevisionAdvance == 1)
    }

    @Test
    func rejectsStaleForeignLayerGenerationFormatAndCoordinateWithoutMutation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let layerID = tiledRevisionLayerID(4)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount * 4
        )
        let pair = try store.allocatePair(
            layerID: layerID,
            generation: 9,
            pixelSize: size,
            dirtyRegions: tiledRevisionRegions(for: [coordinate], size: size),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        let baseline = store.snapshot()
        let texture = try tiledRevisionTexture(device: device)
        let queue = try #require(device.makeCommandQueue())

        #expect(throws: TiledRasterRevisionStoreError.layerMismatch(
            expected: layerID,
            actual: tiledRevisionLayerID(99)
        )) {
            _ = try store.encodeCapture(
                pair.before,
                layerID: tiledRevisionLayerID(99),
                generation: 9,
                sources: [.texture(coordinate: coordinate, texture: texture)],
                on: try #require(queue.makeCommandBuffer())
            )
        }
        #expect(throws: TiledRasterRevisionStoreError.generationMismatch(
            expected: 9,
            actual: 10
        )) {
            _ = try store.encodeCapture(
                pair.before,
                layerID: layerID,
                generation: 10,
                sources: [.texture(coordinate: coordinate, texture: texture)],
                on: try #require(queue.makeCommandBuffer())
            )
        }
        #expect(throws: TiledRasterRevisionStoreError.coordinateSetMismatch) {
            _ = try store.encodeCapture(
                pair.before,
                layerID: layerID,
                generation: 9,
                sources: [.texture(coordinate: .init(x: 1, y: 0), texture: texture)],
                on: try #require(queue.makeCommandBuffer())
            )
        }
        let wrongFormat = try tiledRevisionTexture(
            device: device,
            pixelFormat: .bgra8Unorm
        )
        #expect(throws: TiledRasterRevisionStoreError.invalidTextureFormat) {
            _ = try store.encodeCapture(
                pair.before,
                layerID: layerID,
                generation: 9,
                sources: [.texture(coordinate: coordinate, texture: wrongFormat)],
                on: try #require(queue.makeCommandBuffer())
            )
        }
        #expect(store.snapshot() == baseline)

        let foreign = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount
        )
        #expect(throws: TiledRasterRevisionStoreError.missingRevision) {
            _ = try foreign.encodeCapture(
                pair.before,
                layerID: layerID,
                generation: 9,
                sources: [.texture(coordinate: coordinate, texture: texture)],
                on: try #require(queue.makeCommandBuffer())
            )
        }
    }

    @Test
    func duplicateFinalizeAndReleaseDuringRestoreAreSafe() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = tiledRevisionLayerID(5)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount * 2
        )
        let pair = try store.allocatePair(
            layerID: layerID,
            generation: 1,
            pixelSize: size,
            dirtyRegions: tiledRevisionRegions(for: [coordinate], size: size),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        let source = try tiledRevisionTexture(device: device)
        let queue = try #require(device.makeCommandQueue())
        let capture = try #require(queue.makeCommandBuffer())
        let before = try store.encodeCapture(
            pair.before,
            layerID: layerID,
            generation: 1,
            sources: [.texture(coordinate: coordinate, texture: source)],
            on: capture
        )
        let after = try store.encodeCapture(
            pair.after,
            layerID: layerID,
            generation: 1,
            sources: [.texture(coordinate: coordinate, texture: source)],
            on: capture
        )
        capture.commit()
        capture.waitUntilCompleted()
        try tiledRevisionRequireCompleted(capture)
        try store.finalize(before, as: .succeeded)
        #expect(throws: TiledRasterRevisionStoreError.invalidOperationToken) {
            try store.finalize(before, as: .succeeded)
        }
        try store.finalize(after, as: .succeeded)
        try store.publish(pair)

        let target = try tiledRevisionTexture(device: device)
        let restore = try #require(queue.makeCommandBuffer())
        let restoreToken = try store.encodeRestore(
            pair.before,
            layerID: layerID,
            generation: 1,
            targets: [.init(coordinate: coordinate, texture: target)],
            on: restore
        )
        try store.release([pair.before.id])
        #expect(store.containsRevision(pair.before.id))
        restore.commit()
        restore.waitUntilCompleted()
        try tiledRevisionRequireCompleted(restore)
        try store.finalize(restoreToken, as: .succeeded)
        #expect(!store.containsRevision(pair.before.id))
        #expect(store.containsRevision(pair.after.id))
    }

    @Test
    func allocationAndPipelineFailuresPublishNothingAndLeaveStoreReusable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bytes = PaintTileDescriptor.residentByteCount
        let size = PixelSize(width: 512, height: 256)
        let coordinates = [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
        ]
        let layerID = tiledRevisionLayerID(6)
        let regions = tiledRevisionRegions(for: coordinates, size: size)

        for allocationIndex in 0..<2 {
            let store = TiledRasterRevisionStore(
                device: device,
                maximumRetainedBytes: bytes * 4
            )
            #expect(throws: TiledRasterRevisionStoreError.injectedFailure(
                .bufferAllocation(allocationIndex)
            )) {
                _ = try store.allocatePair(
                    layerID: layerID,
                    generation: 2,
                    pixelSize: size,
                    dirtyRegions: regions,
                    beforePresentCoordinates: coordinates,
                    afterPresentCoordinates: coordinates,
                    failureInjection: .init(
                        failingAt: .bufferAllocation(allocationIndex)
                    )
                )
            }
            #expect(store.snapshot() == .empty(maximumRetainedBytes: bytes * 4))
        }

        for point in [
            TiledRasterRevisionFailurePoint.tileCapture(0),
            .tileCapture(1),
            .commandEncoding,
        ] {
            let store = TiledRasterRevisionStore(
                device: device,
                maximumRetainedBytes: bytes * 4
            )
            let pair = try store.allocatePair(
                layerID: layerID,
                generation: 2,
                pixelSize: size,
                dirtyRegions: regions,
                beforePresentCoordinates: coordinates,
                afterPresentCoordinates: coordinates
            )
            let textures = try coordinates.map { coordinate in
                TiledRasterRevisionTileSource.texture(
                    coordinate: coordinate,
                    texture: try tiledRevisionTexture(device: device)
                )
            }
            let queue = try #require(device.makeCommandQueue())
            #expect(throws: TiledRasterRevisionStoreError.injectedFailure(point)) {
                _ = try store.encodeCapture(
                    pair.before,
                    layerID: layerID,
                    generation: 2,
                    sources: textures,
                    on: try #require(queue.makeCommandBuffer()),
                    failureInjection: .init(failingAt: point)
                )
            }
            #expect(store.residentBytes == 0)
            #expect(store.snapshot().publishedRevisionCount == 0)
            #expect(store.snapshot().provisionalRevisionCount == 0)
        }

        let completionStore = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: bytes * 2
        )
        let pair = try completionStore.allocatePair(
            layerID: layerID,
            generation: 2,
            pixelSize: PixelSize(width: 256, height: 256),
            dirtyRegions: tiledRevisionRegions(
                for: [.init(x: 0, y: 0)],
                size: PixelSize(width: 256, height: 256)
            ),
            beforePresentCoordinates: [.init(x: 0, y: 0)],
            afterPresentCoordinates: [.init(x: 0, y: 0)]
        )
        let texture = try tiledRevisionTexture(device: device)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let token = try completionStore.encodeCapture(
            pair.before,
            layerID: layerID,
            generation: 2,
            sources: [.texture(coordinate: .init(x: 0, y: 0), texture: texture)],
            on: command
        )
        command.commit()
        command.waitUntilCompleted()
        #expect(throws: TiledRasterRevisionStoreError.injectedFailure(.completion)) {
            try completionStore.finalize(
                token,
                as: .succeeded,
                failureInjection: .init(failingAt: .completion)
            )
        }
        #expect(completionStore.residentBytes == 0)
        #expect(completionStore.snapshot().provisionalRevisionCount == 0)

        let reusable = try completionStore.allocatePair(
            layerID: layerID,
            generation: 3,
            pixelSize: PixelSize(width: 256, height: 256),
            dirtyRegions: tiledRevisionRegions(
                for: [.init(x: 0, y: 0)],
                size: PixelSize(width: 256, height: 256)
            ),
            beforePresentCoordinates: [],
            afterPresentCoordinates: []
        )
        #expect(reusable.retainedBytes == 0)
        try completionStore.discard(reusable)
    }

    @Test
    func byteBudgetIsCheckedAndRepeatedDirtyRegionsCaptureTileOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 512)
        let layerID = tiledRevisionLayerID(7)
        let tile = PaintTileCoordinate(x: 0, y: 0)
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount
        )
        let repeated = PixelRegionSet(
            [
                PixelRect(minX: 2, minY: 2, maxX: 20, maxY: 20)!,
                PixelRect(minX: 80, minY: 80, maxX: 120, maxY: 120)!,
                PixelRect(minX: 180, minY: 180, maxX: 200, maxY: 200)!,
            ],
            clippedTo: size
        )
        let clearBefore = try store.allocatePair(
            layerID: layerID,
            generation: 0,
            pixelSize: size,
            dirtyRegions: repeated,
            beforePresentCoordinates: [],
            afterPresentCoordinates: [tile]
        )
        #expect(clearBefore.after.tileCoordinates == [tile.revisionCoordinate])
        #expect(clearBefore.retainedBytes == PaintTileDescriptor.residentByteCount)
        try store.discard(clearBefore)

        #expect(throws: TiledRasterRevisionStoreError.byteBudgetExceeded(
            requiredBytes: PaintTileDescriptor.residentByteCount * 2,
            availableBytes: PaintTileDescriptor.residentByteCount
        )) {
            _ = try store.allocatePair(
                layerID: layerID,
                generation: 0,
                pixelSize: size,
                dirtyRegions: repeated,
                beforePresentCoordinates: [tile],
                afterPresentCoordinates: [tile]
            )
        }
        #expect(store.residentBytes == 0)
    }
}

private func tiledRevisionLayerID(_ value: Int) -> UUID {
    UUID(uuidString: String(
        format: "10000000-0000-0000-0000-%012d",
        value
    ))!
}

private func tiledRevisionRegions(
    for coordinates: [PaintTileCoordinate],
    size: PixelSize
) -> PixelRegionSet {
    PixelRegionSet(
        coordinates.map {
            try! PaintTileDescriptor(
                coordinate: $0,
                logicalPixelSize: size
            ).logicalBounds
        },
        clippedTo: size
    )
}

private func tiledRevisionRetainedBytes(
    coordinate: PaintTileCoordinate,
    size: PixelSize,
    device: any MTLDevice
) throws -> Int {
    let descriptor = try PaintTileDescriptor(
        coordinate: coordinate,
        logicalPixelSize: size
    )
    let alignment = device.minimumTextureBufferAlignment(for: .rgba16Float)
    let raw = descriptor.logicalBounds.width * 8
    let row = ((raw + alignment - 1) / alignment) * alignment
    return row * descriptor.logicalBounds.height
}

private func tiledRevisionTexture(
    device: any MTLDevice,
    pixelFormat: MTLPixelFormat = .rgba16Float
) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat,
        width: PaintTileDescriptor.side,
        height: PaintTileDescriptor.side,
        mipmapped: false
    )
    descriptor.storageMode = .shared
    return try #require(device.makeTexture(descriptor: descriptor))
}

private func tiledRevisionBytes(seed: UInt8) -> Data {
    Data((0..<PaintTileDescriptor.residentByteCount).map {
        UInt8(truncatingIfNeeded: $0 &* 29 &+ Int(seed))
    })
}

private func tiledRevisionUpload(
    _ bytes: Data,
    to texture: any MTLTexture
) {
    bytes.withUnsafeBytes {
        texture.replace(
            region: MTLRegionMake2D(
                0,
                0,
                PaintTileDescriptor.side,
                PaintTileDescriptor.side
            ),
            mipmapLevel: 0,
            withBytes: $0.baseAddress!,
            bytesPerRow: PaintTileDescriptor.side * 8
        )
    }
}

private func tiledRevisionDownload(_ texture: any MTLTexture) -> Data {
    var bytes = Data(count: PaintTileDescriptor.residentByteCount)
    bytes.withUnsafeMutableBytes {
        texture.getBytes(
            $0.baseAddress!,
            bytesPerRow: PaintTileDescriptor.side * 8,
            from: MTLRegionMake2D(
                0,
                0,
                PaintTileDescriptor.side,
                PaintTileDescriptor.side
            ),
            mipmapLevel: 0
        )
    }
    return bytes
}

private func tiledRevisionClippedBytes(
    _ bytes: Data,
    width: Int,
    height: Int
) -> Data {
    var result = Data()
    result.reserveCapacity(width * height * 8)
    for y in 0..<height {
        let start = y * PaintTileDescriptor.side * 8
        result.append(bytes[start..<(start + width * 8)])
    }
    return result
}

private func tiledRevisionRequireCompleted(
    _ commandBuffer: any MTLCommandBuffer
) throws {
    #expect(commandBuffer.status == .completed)
    if let error = commandBuffer.error { throw error }
}

private extension PaintTileCoordinate {
    var revisionCoordinate: RasterRevisionTileCoordinate {
        RasterRevisionTileCoordinate(x: x, y: y)
    }
}
