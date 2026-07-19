import PatternEngine
import Testing

private struct TestSurface: RasterSurface {
    let pixelSize: PixelSize
    let revision: RasterRevision
}

@Test
func rasterSurfaceExposesNoMetalType() {
    let surface = TestSurface(
        pixelSize: PixelSize(width: 256, height: 256),
        revision: RasterRevision(rawValue: 7)
    )

    #expect(surface.pixelSize == PixelSize(width: 256, height: 256))
    #expect(surface.revision == RasterRevision(rawValue: 7))
}

@Test
func rasterRevisionAdvancesWithWrappingArithmetic() {
    let revision = RasterRevision(rawValue: .max)

    #expect(revision.advanced() == RasterRevision(rawValue: 0))
}
