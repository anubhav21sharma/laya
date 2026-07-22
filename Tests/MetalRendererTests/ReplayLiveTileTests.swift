import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Test
@MainActor
func replayTilePlansRegionalReplacementAndRejectsStaleVisibility() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let size = PixelSize(width: 64, height: 64)
    let tile = try ReplayLiveTile(device: device, pixelSize: size)
    let prior = PixelRegionSet(
        [PixelRect(minX: 2, minY: 3, maxX: 8, maxY: 9)!],
        clippedTo: size
    )
    let replacement = PixelRegionSet(
        [PixelRect(minX: 7, minY: 8, maxX: 12, maxY: 14)!],
        clippedTo: size
    )

    #expect(
        tile.planReplacement(
            epoch: 1,
            prior: prior,
            replacement: replacement
        ) == .regional(
            PixelRegionSet(
                prior.rectangles + replacement.rectangles,
                clippedTo: size
            )
        )
    )
    tile.markVisible(epoch: 2)
    tile.markCleared(epoch: 1)
    #expect(tile.visibleEpoch == 2)
    #expect(tile.isVisible)
}

@Test
@MainActor
func replayTileFallsBackToFullClearForUnsafeRegionCount() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let size = PixelSize(width: 256, height: 256)
    let tile = try ReplayLiveTile(device: device, pixelSize: size)
    let rectangles = (0...ReplayLiveTile.maximumRegionalRectangleCount).map {
        PixelRect(
            minX: $0 * 4,
            minY: 0,
            maxX: $0 * 4 + 1,
            maxY: 1
        )!
    }
    let plan = tile.planReplacement(
        epoch: 1,
        prior: PixelRegionSet(rectangles, clippedTo: size),
        replacement: PixelRegionSet([], clippedTo: size)
    )
    #expect(
        plan == .fullTile(
            PixelRegionSet(
                [PixelRect(minX: 0, minY: 0, maxX: 256, maxY: 256)!],
                clippedTo: size
            )
        )
    )
}

@Test
@MainActor
func rendererEncodesRegionalReplayClearWithoutClearingOutsideThePlan() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue()
    else { return }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let shader = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/MetalRenderer/Shaders.metal"
        ),
        encoding: .utf8
    )
    let header = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/CShaderTypes/include/ShaderTypes.h"
        ),
        encoding: .utf8
    )
    let library = try device.makeLibrary(
        source: shader.replacingOccurrences(
            of: "#include \"ShaderTypes.h\"",
            with: header
        ),
        options: nil
    )
    let renderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 64, height: 64),
        configuration: TilingCanvasConfiguration(
            pixelSize: PixelSize(width: 64, height: 64),
            tiling: .grid
        )
    )
    let clearRegion = PixelRegionSet(
        [PixelRect(minX: 8, minY: 8, maxX: 16, maxY: 16)!],
        clippedTo: renderer.pixelSize
    )
    #expect(
        renderer.replayTile.planReplacement(
            epoch: 1,
            prior: clearRegion,
            replacement: PixelRegionSet([], clippedTo: renderer.pixelSize)
        ) == .regional(clearRegion)
    )

    let stagingDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: 64,
        height: 64,
        mipmapped: false
    )
    stagingDescriptor.storageMode = .shared
    stagingDescriptor.usage = [.shaderRead]
    let staging = try #require(device.makeTexture(descriptor: stagingDescriptor))
    let commandBuffer = try #require(queue.makeCommandBuffer())
    let seedPass = MTLRenderPassDescriptor()
    seedPass.colorAttachments[0].texture = renderer.replayTile.texture
    seedPass.colorAttachments[0].loadAction = .clear
    seedPass.colorAttachments[0].storeAction = .store
    seedPass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1)
    let seedEncoder = try #require(
        commandBuffer.makeRenderCommandEncoder(descriptor: seedPass)
    )
    seedEncoder.endEncoding()
    try renderer.encodeReplayClear(commandBuffer)
    let blit = try #require(commandBuffer.makeBlitCommandEncoder())
    blit.copy(
        from: renderer.replayTile.texture,
        sourceSlice: 0,
        sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: 64, height: 64, depth: 1),
        to: staging,
        destinationSlice: 0,
        destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
    )
    blit.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)

    var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
    bytes.withUnsafeMutableBytes { storage in
        staging.getBytes(
            storage.baseAddress!,
            bytesPerRow: 64 * 4,
            from: MTLRegionMake2D(0, 0, 64, 64),
            mipmapLevel: 0
        )
    }
    let cleared = (10 * 64 + 10) * 4
    let preserved = (32 * 64 + 32) * 4
    #expect(Array(bytes[cleared..<(cleared + 4)]) == [0, 0, 0, 0])
    #expect(Array(bytes[preserved..<(preserved + 4)]) == [0, 0, 255, 255])
}
