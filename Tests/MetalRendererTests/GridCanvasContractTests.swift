import CShaderTypes
import Metal
import MetalRenderer
import PatternEngine
import Testing

@Test
func sliceOneConstantsMatchTheApprovedDesign() {
    #expect(GridCanvasContract.tileSize == 256)
    #expect(
        GridCanvasContract.defaultPixelSize
            == PixelSize(width: 256, height: 256)
    )
    #expect(GridCanvasContract.brushRadius == 10)
    #expect(GridCanvasContract.dabSpacing == 2.5)
    #expect(GridCanvasContract.zoomRange == 0.25...8)
    #expect(GridCanvasContract.paperBGRA == SIMD4<UInt8>(241, 244, 242, 255))
    #expect(GridCanvasContract.instanceCapacity == 4_096)
    #expect(GridCanvasContract.inFlightBufferCount == 3)
}

@Test
func physicalStrokePayloadHasAClosedUpperBound() {
    let pending = GridCanvasContract.pendingCapacity
    let inFlight = GridCanvasContract.instanceCapacity
        * GridCanvasContract.inFlightBufferCount

    #expect(pending == 12_288)
    #expect(pending + inFlight == 24_576)
}

@Test
func projectedInstanceBufferBytesUseTheExactOneHundredTwelveByteStride() {
    #expect(
        GridCanvasContract.instanceCapacity
            * MemoryLayout<PatternProjectedStampInstance>.stride
            == 458_752
    )
}

@Test
func tilingCanvasConfigurationAcceptsIndependentBoundaryDimensions() throws {
    let accepted = [
        (PixelSize(width: 64, height: 64), TilingKind.grid),
        (PixelSize(width: 320, height: 192), .halfDrop),
        (PixelSize(width: 4_096, height: 64), .mirrorXY),
        (PixelSize(width: 64, height: 4_096), .rotational),
        (PixelSize(width: 4_096, height: 4_096), .brick),
    ]

    for (pixelSize, tiling) in accepted {
        let configuration = try TilingCanvasConfiguration(
            pixelSize: pixelSize,
            tiling: tiling
        )

        #expect(configuration.pixelSize == pixelSize)
        #expect(configuration.tiling == tiling)
    }
}

@Test(
    arguments: [
        PixelSize(width: 63, height: 64),
        PixelSize(width: 4_097, height: 64),
        PixelSize(width: 64, height: 63),
        PixelSize(width: 64, height: 4_097),
    ]
)
func tilingCanvasConfigurationRejectsEachDimensionOutside64Through4096(
    pixelSize: PixelSize
) {
    #expect(
        throws: MetalRendererError.invalidTileDimensions(
            width: pixelSize.width,
            height: pixelSize.height
        )
    ) {
        try TilingCanvasConfiguration(
            pixelSize: pixelSize,
            tiling: .grid
        )
    }
}

@Test
func rendererInitializerAcceptsOneImmutableCanvasConfiguration() {
    let initializer: @MainActor (
        any MTLDevice,
        any MTLLibrary,
        PatternSize,
        TilingCanvasConfiguration
    ) throws -> GridRenderer = { device, library, drawableSize, configuration in
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: drawableSize,
            configuration: configuration
        )
        #expect(renderer.pixelSize == configuration.pixelSize)
        #expect(renderer.tiling == configuration.tiling)
        return renderer
    }

    _ = initializer
}
