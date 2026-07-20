import PatternEngine
import Testing

@Test
func regionSetMergesTouchingButKeepsSeparatedSeamEdges() {
    let size = PixelSize(width: 256, height: 192)
    let regions = PixelRegionSet(
        [
            PixelRect(minX: -2, minY: 8, maxX: 4, maxY: 20)!,
            PixelRect(minX: 4, minY: 8, maxX: 10, maxY: 20)!,
            PixelRect(minX: 250, minY: 8, maxX: 260, maxY: 20)!,
        ],
        clippedTo: size
    )

    #expect(regions.rectangles == [
        PixelRect(minX: 0, minY: 8, maxX: 10, maxY: 20)!,
        PixelRect(minX: 250, minY: 8, maxX: 256, maxY: 20)!,
    ])
}
