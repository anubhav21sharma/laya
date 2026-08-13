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
func compiledRectangularDisplayFoldMatchesIndependentFixtures() throws {
    let rasterSize = PixelSize(width: 192, height: 128)
    let axisAlignedCases: [(
        SymmetryPresetID,
        PatternSize,
        [(WorldPoint, CanonicalPoint)]
    )] = [
        (
            .grid,
            PatternSize(width: 128, height: 96),
            [
                (.init(x: -1, y: -1), .init(x: 190.5, y: 126.666_664)),
                (.init(x: 128, y: 96), .init(x: 0, y: 0)),
            ]
        ),
        (
            .halfDrop,
            PatternSize(width: 128, height: 96),
            [
                (.init(x: 129, y: 49), .init(x: 1.5, y: 1.333_333_4)),
                (.init(x: -127, y: -47), .init(x: 1.5, y: 1.333_333_4)),
                (.init(x: 128, y: 48), .init(x: 0, y: 0)),
            ]
        ),
        (
            .brick,
            PatternSize(width: 128, height: 96),
            [
                (.init(x: 65, y: 97), .init(x: 1.5, y: 1.333_333_4)),
                (.init(x: -63, y: -95), .init(x: 1.5, y: 1.333_333_4)),
                (.init(x: 64, y: 96), .init(x: 0, y: 0)),
            ]
        ),
        (
            .mirrorX,
            PatternSize(width: 128, height: 96),
            [
                (.init(x: 129, y: 24), .init(x: 190.5, y: 32)),
                (.init(x: -1, y: 24), .init(x: 1.5, y: 32)),
                (.init(x: 128, y: 96), .init(x: 0, y: 0)),
            ]
        ),
        (
            .mirrorY,
            PatternSize(width: 128, height: 96),
            [
                (.init(x: 32, y: 97), .init(x: 48, y: 126.666_664)),
                (.init(x: 32, y: -1), .init(x: 48, y: 1.333_335_9)),
                (.init(x: 128, y: 96), .init(x: 0, y: 0)),
            ]
        ),
        (
            .mirrorXY,
            PatternSize(width: 128, height: 96),
            [
                (.init(x: 129, y: 97), .init(x: 190.5, y: 126.666_664)),
                (.init(x: -1, y: -1), .init(x: 1.5, y: 1.333_335_9)),
                (.init(x: 128, y: 96), .init(x: 0, y: 0)),
            ]
        ),
        (
            .rotational,
            PatternSize(width: 128, height: 96),
            [
                (.init(x: -1, y: -1), .init(x: 190.5, y: 126.666_664)),
                (.init(x: 128, y: 96), .init(x: 0, y: 0)),
            ]
        ),
        (
            .squareRotation,
            PatternSize(width: 128, height: 128),
            [
                (.init(x: 32, y: 64), .init(x: 48, y: 64)),
                (.init(x: -32, y: -32), .init(x: 144, y: 96)),
                (.init(x: 128, y: 128), .init(x: 0, y: 0)),
            ]
        ),
    ]

    for (presetID, repeatSize, probes) in axisAlignedCases {
        let strategy = try TilingStrategy(
            configuration: PeriodicSymmetryConfiguration(
                presetID: presetID,
                repeatSize: repeatSize
            ),
            canonicalRasterSize: rasterSize
        )
        let fold = try #require(
            strategy.compiledSymmetry.domain.periodic?.displayFold
        )
        #expect(fold.family == .rectangular)
        #expect(fold.coordinateSpace == .axisAlignedRepeat)
        for (world, expected) in probes {
            expectApproximatelyEqual(fold.applying(to: world), expected)
        }
    }

    for presetID in [
        SymmetryPresetID.squareRotation,
        .squareKaleidoscope,
    ] {
        let strategy = try TilingStrategy(
            configuration: PeriodicSymmetryConfiguration(
                presetID: presetID,
                repeatSize: PatternSize(width: 128, height: 128),
                orientationRadians: .pi / 5
            ),
            canonicalRasterSize: rasterSize
        )
        let periodic = try #require(strategy.compiledSymmetry.domain.periodic)
        let fold = periodic.displayFold
        #expect(fold.family == .rectangular)
        #expect(fold.coordinateSpace == .unitLattice)
        let probes: [(SIMD2<Float>, CanonicalPoint)] = [
            (.init(0.25, 0.5), .init(x: 48, y: 64)),
            (.init(-0.25, -0.25), .init(x: 144, y: 96)),
            (.zero, .init(x: 0, y: 0)),
        ]
        for (lattice, expected) in probes {
            let world = periodic.translationBasis.u * lattice.x
                + periodic.translationBasis.v * lattice.y
            expectApproximatelyEqual(
                fold.applying(to: WorldPoint(world)),
                expected
            )
        }
    }
}

@Test
func compiledOrientedRectangularFoldKeepsNonOriginSeamsHalfOpen() throws {
    let strategy = try TilingStrategy(
        configuration: PeriodicSymmetryConfiguration(
            presetID: .squareRotation,
            repeatSize: PatternSize(width: 128, height: 128),
            orientationRadians: .pi / 4
        ),
        canonicalRasterSize: PixelSize(width: 192, height: 128)
    )
    let periodic = try #require(strategy.compiledSymmetry.domain.periodic)
    let epsilon: Float = 1 / 1_024

    let probes: [(SIMD2<Float>, CanonicalPoint)] = [
        (.init(1, 0.375), .init(x: 0, y: 48)),
        (.init(0.375, 1), .init(x: 72, y: 0)),
        (.init(1, 1), .init(x: 0, y: 0)),
        (.init(-1, 0.375), .init(x: 0, y: 48)),
        (.init(1 - epsilon, 0.375), .init(x: 191.812_5, y: 48)),
        (.init(1 + epsilon, 0.375), .init(x: 0.187_5, y: 48)),
        (.init(-1 - epsilon, 0.375), .init(x: 191.812_5, y: 48)),
        (.init(-1 + epsilon, 0.375), .init(x: 0.187_5, y: 48)),
        (.init(0.375, 1 - epsilon), .init(x: 72, y: 127.875)),
        (.init(0.375, 1 + epsilon), .init(x: 72, y: 0.125)),
        (.init(0.375, -1), .init(x: 72, y: 0)),
        (.init(0.375, -1 - epsilon), .init(x: 72, y: 127.875)),
        (.init(0.375, -1 + epsilon), .init(x: 72, y: 0.125)),
    ]

    for (targetLattice, expected) in probes {
        let world = periodic.translationBasis.u * targetLattice.x
            + periodic.translationBasis.v * targetLattice.y
        let actualLattice = periodic.worldToLattice.applying(to: world)
        #expect(abs(actualLattice.x - targetLattice.x) < 0.000_001)
        #expect(abs(actualLattice.y - targetLattice.y) < 0.000_001)
        expectRectangularLatticeSide(
            actual: actualLattice.x,
            target: targetLattice.x,
            epsilon: epsilon
        )
        expectRectangularLatticeSide(
            actual: actualLattice.y,
            target: targetLattice.y,
            epsilon: epsilon
        )
        expectApproximatelyEqual(
            periodic.displayFold.applying(to: WorldPoint(world)),
            expected
        )
    }
}

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
            ),
            operation: CompiledGroupOperation(
                quarterTurns: 2,
                reflected: false
            )
        ),
    ])
}

@Test
func rotatedSquareLatticeUsesExactCellClipMetricAndImageOrder() throws {
    let rasterSize = PixelSize(width: 192, height: 128)
    let repeatSize = PatternSize(width: 128, height: 128)
    let configuration = PeriodicSymmetryConfiguration(
        presetID: .squareRotation,
        repeatSize: repeatSize,
        orientationRadians: .pi / 4
    )
    let strategy = try TilingStrategy(
        configuration: configuration,
        canonicalRasterSize: rasterSize
    )
    let periodic = try #require(
        strategy.compiledSymmetry.domain.periodic
    )
    let world = periodic.translationBasis.u * 1.25
        + periodic.translationBasis.v * -0.75
    let point = WorldPoint(world)

    #expect(
        strategy.cell(containing: point)
            == CellIndex(column: 1, row: -1)
    )
    let folded = strategy.displayFold(point)
    #expect(abs(folded.x - 48) < 0.0001)
    #expect(abs(folded.y - 32) < 0.0001)

    let images = strategy.images(intersecting: rect(
        minimum: world - SIMD2(repeating: 0.25),
        maximum: world + SIMD2(repeating: 0.25)
    ))
    #expect(images.count == 4)
    #expect(images.map(\.cell) == Array(
        repeating: CellIndex(column: 1, row: -1),
        count: 4
    ))
    #expect(images.map(\.ordinal) == [0, 1, 2, 3])
    #expect(images.allSatisfy { $0.worldClip.halfPlanes.count == 4 })
    #expect(images.allSatisfy {
        $0.worldClip.contains(world, tolerance: 0.0001)
    })
    #expect(images == images.sorted(by: imagePrecedes))
}

@Test
func squareKaleidoscopeEnumeratesEightImagesPerGenericCell() throws {
    let strategy = try TilingStrategy(
        configuration: PeriodicSymmetryConfiguration(
            presetID: .squareKaleidoscope,
            repeatSize: PatternSize(width: 128, height: 128),
            orientationRadians: .pi / 6
        ),
        canonicalRasterSize: PixelSize(width: 192, height: 128)
    )
    let periodic = try #require(
        strategy.compiledSymmetry.domain.periodic
    )
    let world = periodic.translationBasis.u * 0.25
        + periodic.translationBasis.v * 0.375
    let images = strategy.images(intersecting: rect(
        minimum: world - SIMD2(repeating: 0.1),
        maximum: world + SIMD2(repeating: 0.1)
    ))

    #expect(images.count == 8)
    #expect(images.map(\.ordinal) == Array(0..<8).map(UInt8.init))
    #expect(images.map(\.operation.reflected) == [
        false, false, false, false,
        true, true, true, true,
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

private func expectApproximatelyEqual(
    _ actual: CanonicalPoint,
    _ expected: CanonicalPoint,
    tolerance: Float = 0.001
) {
    #expect(abs(actual.x - expected.x) < tolerance)
    #expect(abs(actual.y - expected.y) < tolerance)
}

private func expectRectangularLatticeSide(
    actual: Float,
    target: Float,
    epsilon: Float
) {
    let seam = target.rounded()
    if target == seam {
        #expect(actual >= seam && actual <= seam.nextUp)
    } else if abs(target - seam) == epsilon {
        #expect(target < seam ? actual < seam : actual > seam)
    }
}

private func rect(
    minimum: SIMD2<Float>,
    maximum: SIMD2<Float>
) -> AxisAlignedRect {
    AxisAlignedRect(minimum: minimum, maximum: maximum)
}
