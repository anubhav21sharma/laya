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

@Test
func regionSetReachesGlobalFixedPointAfterLateOrthogonalBridge() {
    let size = PixelSize(width: 32, height: 32)
    let regions = PixelRegionSet(
        adversarialBridgeRectangles,
        clippedTo: size
    )

    #expect(regions.rectangles == [
        PixelRect(minX: 0, minY: 0, maxX: 4, maxY: 4)!,
    ])
}

@Test
func regionSetIsDisjointAndDeterministicAcrossCandidatePermutations() {
    let size = PixelSize(width: 32, height: 32)
    let expected = [
        PixelRect(minX: 0, minY: 0, maxX: 4, maxY: 4)!,
    ]
    var distinctOutputs = Set<[PixelRect]>()
    var allOutputsAreDisjoint = true

    for permutation in permutations(of: adversarialBridgeRectangles) {
        let rectangles = PixelRegionSet(
            permutation,
            clippedTo: size
        ).rectangles
        distinctOutputs.insert(rectangles)

        for leftIndex in rectangles.indices {
            for rightIndex in (leftIndex + 1)..<rectangles.endIndex {
                if rectangles[leftIndex]
                    .touchesOrOverlaps(rectangles[rightIndex])
                {
                    allOutputsAreDisjoint = false
                }
            }
        }
    }

    #expect(distinctOutputs == Set<[PixelRect]>([expected]))
    #expect(allOutputsAreDisjoint)
}

private let adversarialBridgeRectangles = [
    PixelRect(minX: 0, minY: 0, maxX: 2, maxY: 2)!,
    PixelRect(minX: 3, minY: 0, maxX: 4, maxY: 1)!,
    PixelRect(minX: 3, minY: 1, maxX: 4, maxY: 3)!,
    PixelRect(minX: 1, minY: 3, maxX: 4, maxY: 4)!,
]

private func permutations<Element>(of values: [Element]) -> [[Element]] {
    guard !values.isEmpty else { return [[]] }

    return values.indices.flatMap { index in
        var remainder = values
        let value = remainder.remove(at: index)
        return permutations(of: remainder).map { [value] + $0 }
    }
}
