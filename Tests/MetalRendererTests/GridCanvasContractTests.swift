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
func projectedInstanceBufferBytesUseTheExactNinetySixByteStride() {
    #expect(
        GridCanvasContract.instanceCapacity
            * MemoryLayout<PatternProjectedStampInstance>.stride
            == 393_216
    )
}

@Test
func rendererInitializerAcceptsAnImmutableRectangularPixelSize() {
    let initializer: @MainActor (
        any MTLDevice,
        any MTLLibrary,
        PatternSize,
        PixelSize
    ) throws -> GridRenderer = { device, library, drawableSize, pixelSize in
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: drawableSize,
            pixelSize: pixelSize
        )
        #expect(renderer.pixelSize == pixelSize)
        return renderer
    }

    _ = initializer
}
