import PatternEngine
import Testing

@Test
func gridFoldUsesPositiveHalfOpenModulo() {
    let cases = [
        (WorldPoint(x: 0, y: 0), CanonicalPoint(x: 0, y: 0)),
        (WorldPoint(x: 256, y: 256), CanonicalPoint(x: 0, y: 0)),
        (WorldPoint(x: -1, y: -257), CanonicalPoint(x: 255, y: 255)),
        (WorldPoint(x: 513, y: 510), CanonicalPoint(x: 1, y: 254)),
    ]
    for (world, expected) in cases {
        #expect(
            GridProjection.fold(
                world,
                tileSize: PatternSize(width: 256, height: 256)
            ) == expected
        )
    }
}

@Test
func gridFoldPreservesHighMagnitudeRemainders() {
    let cases = [
        (
            WorldPoint(x: 10_000_000_000, y: 10_000_000_000),
            CanonicalPoint(x: 1, y: 1)
        ),
        (
            WorldPoint(x: -10_000_000_000, y: -10_000_000_000),
            CanonicalPoint(x: 2, y: 2)
        ),
    ]
    for (world, expected) in cases {
        #expect(
            GridProjection.fold(
                world,
                tileSize: PatternSize(width: 3, height: 3)
            ) == expected
        )
    }
}

@Test
func gridFoldKeepsTinyNegativeRemainderHalfOpen() {
    let extent: Float = 1
    let folded = GridProjection.fold(
        WorldPoint(x: -1e-8, y: -1e-8),
        tileSize: PatternSize(width: extent, height: extent)
    )
    let expected = Float(1).nextDown

    #expect(folded == CanonicalPoint(x: expected, y: expected))
    #expect(folded.x >= 0 && folded.x < extent)
    #expect(folded.y >= 0 && folded.y < extent)
}

@Test
func interiorDabHasOnePlacement() {
    let placements = GridProjection.placements(
        center: WorldPoint(x: 100, y: 100),
        radius: 10,
        tileSize: PatternSize(width: 256, height: 256)
    )

    #expect(placements == [
        CanonicalDabPlacement(center: CanonicalPoint(x: 100, y: 100), radius: 10),
    ])
}

@Test
func leftEdgeDabWrapsToTheRightEdge() {
    let placements = GridProjection.placements(
        center: WorldPoint(x: 3, y: 100),
        radius: 10,
        tileSize: PatternSize(width: 256, height: 256)
    )

    #expect(Set(placements.map(\.center)) == Set([
        CanonicalPoint(x: 3, y: 100),
        CanonicalPoint(x: 259, y: 100),
    ]))
}

@Test
func cornerDabProducesFourTranslatedPlacements() {
    let placements = GridProjection.placements(
        center: WorldPoint(x: -2, y: -2),
        radius: 10,
        tileSize: PatternSize(width: 256, height: 256)
    )

    #expect(Set(placements.map(\.center)) == Set([
        CanonicalPoint(x: 254, y: 254),
        CanonicalPoint(x: -2, y: 254),
        CanonicalPoint(x: 254, y: -2),
        CanonicalPoint(x: -2, y: -2),
    ]))
}

@Test
func diagonalBoundingBoxOverlapDoesNotEmitCircleCopy() {
    let placements = GridProjection.placements(
        center: WorldPoint(x: 5, y: 5),
        radius: 6,
        tileSize: PatternSize(width: 256, height: 256)
    )

    #expect(placements.count == 3)
    #expect(Set(placements.map(\.center)) == Set([
        CanonicalPoint(x: 5, y: 5),
        CanonicalPoint(x: 261, y: 5),
        CanonicalPoint(x: 5, y: 261),
    ]))
}

@Test
func diagonalTangentDoesNotEmitCircleCopy() {
    let placements = GridProjection.placements(
        center: WorldPoint(x: 3, y: 4),
        radius: 5,
        tileSize: PatternSize(width: 256, height: 256)
    )

    #expect(placements.count == 3)
    #expect(Set(placements.map(\.center)) == Set([
        CanonicalPoint(x: 3, y: 4),
        CanonicalPoint(x: 259, y: 4),
        CanonicalPoint(x: 3, y: 260),
    ]))
}

@Test
func tangentOnlyDabDoesNotEmitTranslatedPlacement() {
    let placements = GridProjection.placements(
        center: WorldPoint(x: 10, y: 100),
        radius: 10,
        tileSize: PatternSize(width: 256, height: 256)
    )

    #expect(placements == [
        CanonicalDabPlacement(center: CanonicalPoint(x: 10, y: 100), radius: 10),
    ])
}
