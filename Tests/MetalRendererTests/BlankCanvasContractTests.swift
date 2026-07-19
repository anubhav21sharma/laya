import MetalRenderer
import Testing

@Test
func blankCanvasUsesThePrecisionLightNeutral() {
    #expect(BlankCanvasContract.canvasBGRA == SIMD4<UInt8>(241, 244, 242, 255))
}

@Test
func pixelComparisonHonorsTheEightBitTolerance() {
    #expect(
        BlankCanvasContract.matches(
            actual: SIMD4<UInt8>(240, 245, 242, 255),
            expected: BlankCanvasContract.canvasBGRA,
            tolerance: 1
        )
    )
    #expect(
        !BlankCanvasContract.matches(
            actual: SIMD4<UInt8>(239, 245, 242, 255),
            expected: BlankCanvasContract.canvasBGRA,
            tolerance: 1
        )
    )
}
