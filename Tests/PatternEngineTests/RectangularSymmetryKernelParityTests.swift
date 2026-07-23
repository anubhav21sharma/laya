import PatternEngine
import simd
import Testing

private struct FoldFixture: Sendable {
    let presetID: SymmetryPresetID
    let point: WorldPoint
    let cell: CellIndex
    let canonical: CanonicalPoint
}

private let parityTileSize = PatternSize(width: 64, height: 96)

private let foldFixtures: [FoldFixture] = [
    .init(
        presetID: .grid,
        point: WorldPoint(x: -1, y: -1),
        cell: CellIndex(column: -1, row: -1),
        canonical: CanonicalPoint(x: 63, y: 95)
    ),
    .init(
        presetID: .halfDrop,
        point: WorldPoint(x: 65, y: 49),
        cell: CellIndex(column: 1, row: 0),
        canonical: CanonicalPoint(x: 1, y: 1)
    ),
    .init(
        presetID: .halfDrop,
        point: WorldPoint(x: -63, y: -47),
        cell: CellIndex(column: -1, row: -1),
        canonical: CanonicalPoint(x: 1, y: 1)
    ),
    .init(
        presetID: .brick,
        point: WorldPoint(x: 33, y: 97),
        cell: CellIndex(column: 0, row: 1),
        canonical: CanonicalPoint(x: 1, y: 1)
    ),
    .init(
        presetID: .brick,
        point: WorldPoint(x: -31, y: -95),
        cell: CellIndex(column: -1, row: -1),
        canonical: CanonicalPoint(x: 1, y: 1)
    ),
    .init(
        presetID: .mirrorX,
        point: WorldPoint(x: 65, y: 1),
        cell: CellIndex(column: 1, row: 0),
        canonical: CanonicalPoint(x: 63, y: 1)
    ),
    .init(
        presetID: .mirrorY,
        point: WorldPoint(x: 1, y: 97),
        cell: CellIndex(column: 0, row: 1),
        canonical: CanonicalPoint(x: 1, y: 95)
    ),
    .init(
        presetID: .mirrorXY,
        point: WorldPoint(x: -1, y: -1),
        cell: CellIndex(column: -1, row: -1),
        canonical: CanonicalPoint(x: 1, y: 1)
    ),
    .init(
        presetID: .rotational,
        point: WorldPoint(x: 65, y: 97),
        cell: CellIndex(column: 1, row: 1),
        canonical: CanonicalPoint(x: 1, y: 1)
    ),
    .init(
        presetID: .grid,
        point: WorldPoint(x: 64_000_000, y: -96_000_000),
        cell: CellIndex(column: 1_000_000, row: -1_000_000),
        canonical: CanonicalPoint(x: 0, y: 0)
    ),
]

@Test
func legacyRectangularFoldFixturesRemainExact() {
    for fixture in foldFixtures {
        let strategy = TilingStrategy(
            kind: fixture.presetID,
            tileSize: parityTileSize
        )

        #expect(strategy.cell(containing: fixture.point) == fixture.cell)
        #expect(strategy.displayFold(fixture.point) == fixture.canonical)
    }
}

@Test
func legacyRectangularImageTransformsAndOrdinalsRemainExact() {
    let grid = TilingStrategy(kind: .grid, tileSize: parityTileSize)
    #expect(grid.images(intersecting: probe(at: SIMD2(1, 1))) == [
        TilingImage(
            cell: CellIndex(column: 0, row: 0),
            ordinal: 0,
            worldBounds: rect(
                minimum: SIMD2(0, 0),
                maximum: SIMD2(64, 96)
            ),
            worldToCanonical: .identity
        ),
    ])

    let mirrorXY = TilingStrategy(kind: .mirrorXY, tileSize: parityTileSize)
    #expect(mirrorXY.images(intersecting: probe(at: SIMD2(-1, -1))) == [
        TilingImage(
            cell: CellIndex(column: -1, row: -1),
            ordinal: 0,
            worldBounds: rect(
                minimum: SIMD2(-64, -96),
                maximum: SIMD2(0, 0)
            ),
            worldToCanonical: Affine2D(
                xAxis: SIMD2(-1, 0),
                yAxis: SIMD2(0, -1),
                translation: .zero
            )
        ),
    ])

    let rotational = TilingStrategy(
        kind: .rotational,
        tileSize: parityTileSize
    )
    let rotationalBounds = rect(
        minimum: SIMD2(64, -96),
        maximum: SIMD2(128, 0)
    )
    #expect(rotational.images(intersecting: probe(at: SIMD2(65, -1))) == [
        TilingImage(
            cell: CellIndex(column: 1, row: -1),
            ordinal: 0,
            worldBounds: rotationalBounds,
            worldToCanonical: Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                translation: SIMD2(-64, 96)
            )
        ),
        TilingImage(
            cell: CellIndex(column: 1, row: -1),
            ordinal: 1,
            worldBounds: rotationalBounds,
            worldToCanonical: Affine2D(
                xAxis: SIMD2(-1, 0),
                yAxis: SIMD2(0, -1),
                translation: SIMD2(128, 0)
            )
        ),
    ])
}

@Test
func exactRightAndBottomEdgesBelongOnlyToSuccessorCell() {
    let strategy = TilingStrategy(kind: .grid, tileSize: parityTileSize)
    let query = rect(
        minimum: SIMD2(64, 96),
        maximum: SIMD2(65, 97)
    )
    let images = strategy.images(intersecting: query)

    #expect(strategy.cell(containing: WorldPoint(x: 64, y: 96))
        == CellIndex(column: 1, row: 1))
    #expect(images.map(\.cell) == [CellIndex(column: 1, row: 1)])
}

@Test
func repeatedQueriesRemainExactlyEqualAndOrdered() {
    let strategy = TilingStrategy(
        kind: .rotational,
        tileSize: parityTileSize
    )
    let query = rect(
        minimum: SIMD2(-1, -1),
        maximum: SIMD2(129, 193)
    )

    let first = strategy.images(intersecting: query)
    let second = strategy.images(intersecting: query)

    #expect(first == second)
    #expect(first == first.sorted(by: imagePrecedes))
}

private func imagePrecedes(_ lhs: TilingImage, _ rhs: TilingImage) -> Bool {
    if lhs.cell.row != rhs.cell.row {
        return lhs.cell.row < rhs.cell.row
    }
    if lhs.cell.column != rhs.cell.column {
        return lhs.cell.column < rhs.cell.column
    }
    return lhs.ordinal < rhs.ordinal
}

private func probe(at point: SIMD2<Float>) -> AxisAlignedRect {
    rect(minimum: point, maximum: point + SIMD2(repeating: 0.5))
}

private func rect(
    minimum: SIMD2<Float>,
    maximum: SIMD2<Float>
) -> AxisAlignedRect {
    AxisAlignedRect(minimum: minimum, maximum: maximum)
}
