import MetalRenderer
import Testing

@Test
func sliceOneConstantsMatchTheApprovedDesign() {
    #expect(GridCanvasContract.tileSize == 256)
    #expect(GridCanvasContract.brushRadius == 10)
    #expect(GridCanvasContract.dabSpacing == 2.5)
    #expect(GridCanvasContract.zoomRange == 0.25...8)
    #expect(GridCanvasContract.paperBGRA == SIMD4<UInt8>(241, 244, 242, 255))
    #expect(GridCanvasContract.instanceCapacity == 4_096)
    #expect(GridCanvasContract.inFlightBufferCount == 3)
}
