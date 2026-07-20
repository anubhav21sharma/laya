import Foundation
import PatternEngine
import simd
import Testing

private let standardTileSize = PatternSize(width: 288, height: 192)

@Test
func tilingKindRawValuesAndDisplayFoldMatchTheGoverningTable() {
    #expect(TilingKind.allCases.map(\.rawValue) == Array(0...6).map(UInt32.init))

    let probes: [(TilingKind, WorldPoint, CanonicalPoint)] = [
        (.grid,       .init(x: -1,  y: 193), .init(x: 287, y: 1)),
        (.halfDrop,   .init(x: 300, y: 96),  .init(x: 12,  y: 0)),
        (.brick,      .init(x: 144, y: 200), .init(x: 0,   y: 8)),
        (.mirrorX,    .init(x: 300, y: 20),  .init(x: 276, y: 20)),
        (.mirrorY,    .init(x: 20,  y: 200), .init(x: 20,  y: 184)),
        (.mirrorXY,   .init(x: 300, y: 200), .init(x: 276, y: 184)),
        (.rotational, .init(x: 300, y: 200), .init(x: 12,  y: 8)),
    ]

    for (kind, point, expected) in probes {
        #expect(
            TilingStrategy(kind: kind, tileSize: standardTileSize)
                .displayFold(point) == expected
        )
    }
}

@Test
func everyTilingFamilyUsesHalfOpenRightAndBottomBoundaries() {
    let rightBoundaryCases: [(TilingKind, CellIndex, CanonicalPoint)] = [
        (.grid,       .init(column: 1, row: 0),  .init(x: 0, y: 20)),
        (.halfDrop,   .init(column: 1, row: -1), .init(x: 0, y: 116)),
        (.brick,      .init(column: 1, row: 0),  .init(x: 0, y: 20)),
        (.mirrorX,    .init(column: 1, row: 0),  .init(x: 0, y: 20)),
        (.mirrorY,    .init(column: 1, row: 0),  .init(x: 0, y: 20)),
        (.mirrorXY,   .init(column: 1, row: 0),  .init(x: 0, y: 20)),
        (.rotational, .init(column: 1, row: 0),  .init(x: 0, y: 20)),
    ]
    let rightBoundary = WorldPoint(x: standardTileSize.width, y: 20)

    for (kind, expectedCell, expectedFold) in rightBoundaryCases {
        let strategy = TilingStrategy(kind: kind, tileSize: standardTileSize)
        #expect(strategy.cell(containing: rightBoundary) == expectedCell)
        #expect(strategy.displayFold(rightBoundary) == expectedFold)
    }

    let bottomBoundaryCases: [(TilingKind, CellIndex, CanonicalPoint)] = [
        (.grid,       .init(column: 0, row: 1),  .init(x: 20,  y: 0)),
        (.halfDrop,   .init(column: 0, row: 1),  .init(x: 20,  y: 0)),
        (.brick,      .init(column: -1, row: 1), .init(x: 164, y: 0)),
        (.mirrorX,    .init(column: 0, row: 1),  .init(x: 20,  y: 0)),
        (.mirrorY,    .init(column: 0, row: 1),  .init(x: 20,  y: 0)),
        (.mirrorXY,   .init(column: 0, row: 1),  .init(x: 20,  y: 0)),
        (.rotational, .init(column: 0, row: 1),  .init(x: 20,  y: 0)),
    ]
    let bottomBoundary = WorldPoint(x: 20, y: standardTileSize.height)

    for (kind, expectedCell, expectedFold) in bottomBoundaryCases {
        let strategy = TilingStrategy(kind: kind, tileSize: standardTileSize)
        #expect(strategy.cell(containing: bottomBoundary) == expectedCell)
        #expect(strategy.displayFold(bottomBoundary) == expectedFold)
    }
}

@Test
func everyTilingFamilyHandlesNegativeParity() {
    let point = WorldPoint(x: -1, y: -1)
    let cases: [(TilingKind, CellIndex, CanonicalPoint)] = [
        (.grid,       .init(column: -1, row: -1), .init(x: 287, y: 191)),
        (.halfDrop,   .init(column: -1, row: -1), .init(x: 287, y: 95)),
        (.brick,      .init(column: -1, row: -1), .init(x: 143, y: 191)),
        (.mirrorX,    .init(column: -1, row: -1), .init(x: 1,   y: 191)),
        (.mirrorY,    .init(column: -1, row: -1), .init(x: 287, y: 1)),
        (.mirrorXY,   .init(column: -1, row: -1), .init(x: 1,   y: 1)),
        (.rotational, .init(column: -1, row: -1), .init(x: 287, y: 191)),
    ]

    for (kind, expectedCell, expectedFold) in cases {
        let strategy = TilingStrategy(kind: kind, tileSize: standardTileSize)
        #expect(strategy.cell(containing: point) == expectedCell)
        #expect(strategy.displayFold(point) == expectedFold)
    }
}

@Test
func everyTilingFamilyKeepsIndicesNearPositiveAndNegativeOneMillion() {
    let tileSize = PatternSize(width: 256, height: 128)
    let indices = [1_000_000, -1_000_000, 999_999, -999_999]

    for kind in TilingKind.allCases {
        let strategy = TilingStrategy(kind: kind, tileSize: tileSize)
        for index in indices {
            let odd = !index.isMultiple(of: 2)
            let phaseX: Float = kind == .brick && odd ? tileSize.width * 0.5 : 0
            let phaseY: Float = kind == .halfDrop && odd ? tileSize.height * 0.5 : 0
            let point = WorldPoint(
                x: Float(index) * tileSize.width + phaseX + 64,
                y: Float(index) * tileSize.height + phaseY + 32
            )
            let expectedX: Float = (kind == .mirrorX || kind == .mirrorXY) && odd
                ? 192
                : 64
            let expectedY: Float = (kind == .mirrorY || kind == .mirrorXY) && odd
                ? 96
                : 32

            #expect(
                strategy.cell(containing: point)
                    == CellIndex(column: index, row: index)
            )
            #expect(
                strategy.displayFold(point)
                    == CanonicalPoint(x: expectedX, y: expectedY)
            )
        }
    }
}

@Test
func tilingStrategyDimensionValidationRunsInSubprocesses() throws {
    if let validationCase = ProcessInfo.processInfo.environment[
        "PATTERN_ENGINE_TILING_DIMENSION_CASE"
    ] {
        constructStrategyForDimensionValidation(named: validationCase)
        return
    }

    let invalidCases = [
        ("widthNaN", "TilingStrategy tile width must be finite"),
        ("widthInfinity", "TilingStrategy tile width must be finite"),
        ("heightNaN", "TilingStrategy tile height must be finite"),
        ("heightInfinity", "TilingStrategy tile height must be finite"),
        ("widthFractional", "TilingStrategy tile width must be an integer"),
        ("heightFractional", "TilingStrategy tile height must be an integer"),
        ("widthBelowMinimum", "TilingStrategy tile width must be in 64...4096"),
        ("heightBelowMinimum", "TilingStrategy tile height must be in 64...4096"),
        ("widthAboveMaximum", "TilingStrategy tile width must be in 64...4096"),
        ("heightAboveMaximum", "TilingStrategy tile height must be in 64...4096"),
    ]
    for (validationCase, expectedMessage) in invalidCases {
        let result = try runDimensionValidationSubprocess(for: validationCase)
        #expect(result.status != 0)
        #expect(
            result.standardError.contains(
                "Precondition failed: \(expectedMessage)"
            )
        )
    }

    for acceptedCase in [
        "widthMinimum",
        "widthMaximum",
        "heightMinimum",
        "heightMaximum",
    ] {
        let result = try runDimensionValidationSubprocess(for: acceptedCase)
        #expect(result.status == 0)
    }
}

@Test
func translationFamilyImagesHaveExactOriginsAndTransforms() {
    let grid = TilingStrategy(kind: .grid, tileSize: standardTileSize)
    let gridImages = grid.images(intersecting: rect(
        minimum: SIMD2(-287.5, 384.5),
        maximum: SIMD2(-287, 385)
    ))
    #expect(gridImages == [
        TilingImage(
            cell: CellIndex(column: -1, row: 2),
            ordinal: 0,
            worldBounds: rect(
                minimum: SIMD2(-288, 384),
                maximum: SIMD2(0, 576)
            ),
            worldToCanonical: Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                translation: SIMD2(288, -384)
            )
        ),
    ])
    #expect(
        gridImages[0].worldToCanonical.applying(to: SIMD2(-288, 384))
            == SIMD2<Float>(0, 0)
    )

    let halfDrop = TilingStrategy(kind: .halfDrop, tileSize: standardTileSize)
    #expect(halfDrop.images(intersecting: rect(
        minimum: SIMD2(288.5, 480.5),
        maximum: SIMD2(289, 481)
    )) == [
        TilingImage(
            cell: CellIndex(column: 1, row: 2),
            ordinal: 0,
            worldBounds: rect(
                minimum: SIMD2(288, 480),
                maximum: SIMD2(576, 672)
            ),
            worldToCanonical: Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                translation: SIMD2(-288, -480)
            )
        ),
    ])

    let brick = TilingStrategy(kind: .brick, tileSize: standardTileSize)
    #expect(brick.images(intersecting: rect(
        minimum: SIMD2(720.5, 192.5),
        maximum: SIMD2(721, 193)
    )) == [
        TilingImage(
            cell: CellIndex(column: 2, row: 1),
            ordinal: 0,
            worldBounds: rect(
                minimum: SIMD2(720, 192),
                maximum: SIMD2(1008, 384)
            ),
            worldToCanonical: Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                translation: SIMD2(-720, -192)
            )
        ),
    ])
}

@Test
func mirrorImagesHaveExactReflectedBases() {
    let cases: [(TilingKind, AxisAlignedRect, TilingImage)] = [
        (
            .mirrorX,
            rect(minimum: SIMD2(288.5, 0.5), maximum: SIMD2(289, 1)),
            TilingImage(
                cell: CellIndex(column: 1, row: 0),
                ordinal: 0,
                worldBounds: rect(
                    minimum: SIMD2(288, 0),
                    maximum: SIMD2(576, 192)
                ),
                worldToCanonical: Affine2D(
                    xAxis: SIMD2(-1, 0),
                    yAxis: SIMD2(0, 1),
                    translation: SIMD2(576, 0)
                )
            )
        ),
        (
            .mirrorY,
            rect(minimum: SIMD2(0.5, 192.5), maximum: SIMD2(1, 193)),
            TilingImage(
                cell: CellIndex(column: 0, row: 1),
                ordinal: 0,
                worldBounds: rect(
                    minimum: SIMD2(0, 192),
                    maximum: SIMD2(288, 384)
                ),
                worldToCanonical: Affine2D(
                    xAxis: SIMD2(1, 0),
                    yAxis: SIMD2(0, -1),
                    translation: SIMD2(0, 384)
                )
            )
        ),
        (
            .mirrorXY,
            rect(minimum: SIMD2(288.5, 192.5), maximum: SIMD2(289, 193)),
            TilingImage(
                cell: CellIndex(column: 1, row: 1),
                ordinal: 0,
                worldBounds: rect(
                    minimum: SIMD2(288, 192),
                    maximum: SIMD2(576, 384)
                ),
                worldToCanonical: Affine2D(
                    xAxis: SIMD2(-1, 0),
                    yAxis: SIMD2(0, -1),
                    translation: SIMD2(576, 384)
                )
            )
        ),
    ]

    for (kind, query, expected) in cases {
        #expect(
            TilingStrategy(kind: kind, tileSize: standardTileSize)
                .images(intersecting: query) == [expected]
        )
    }
}

@Test
func rotationalImagesAreIdentityThenTileCenterRotation() {
    let strategy = TilingStrategy(kind: .rotational, tileSize: standardTileSize)
    let query = rect(
        minimum: SIMD2(288.5, 384.5),
        maximum: SIMD2(289, 385)
    )
    let bounds = rect(
        minimum: SIMD2(288, 384),
        maximum: SIMD2(576, 576)
    )
    let images = strategy.images(intersecting: query)

    #expect(images == [
        TilingImage(
            cell: CellIndex(column: 1, row: 2),
            ordinal: 0,
            worldBounds: bounds,
            worldToCanonical: Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                translation: SIMD2(-288, -384)
            )
        ),
        TilingImage(
            cell: CellIndex(column: 1, row: 2),
            ordinal: 1,
            worldBounds: bounds,
            worldToCanonical: Affine2D(
                xAxis: SIMD2(-1, 0),
                yAxis: SIMD2(0, -1),
                translation: SIMD2(576, 576)
            )
        ),
    ])

    let worldCenter = SIMD2<Float>(432, 480)
    let canonicalCenter = SIMD2<Float>(144, 96)
    #expect(images[0].worldToCanonical.applying(to: worldCenter) == canonicalCenter)
    #expect(images[1].worldToCanonical.applying(to: worldCenter) == canonicalCenter)
}

@Test
func imagesStrictlyIntersectBoundsAndUseStableRowColumnOrdinalOrder() {
    let query = rect(
        minimum: SIMD2<Float>(0, 0),
        maximum: SIMD2<Float>(576, 384)
    )
    let expectedCounts: [TilingKind: Int] = [
        .grid: 4,
        .halfDrop: 5,
        .brick: 5,
        .mirrorX: 4,
        .mirrorY: 4,
        .mirrorXY: 4,
        .rotational: 8,
    ]

    for kind in TilingKind.allCases {
        let strategy = TilingStrategy(kind: kind, tileSize: standardTileSize)
        let first = strategy.images(intersecting: query)
        let second = strategy.images(intersecting: query)

        #expect(first == second)
        #expect(first.count == expectedCounts[kind])
        #expect(first.allSatisfy { $0.worldBounds.intersects(query) })
        #expect(isInRowColumnOrdinalOrder(first))
        #expect(hasNoEqualImages(first))
    }
}

@Test
func emptyBoundsProduceNoImagesForEveryTilingFamily() {
    let zeroWidth = rect(
        minimum: SIMD2<Float>(10, 10),
        maximum: SIMD2<Float>(10, 20)
    )
    let zeroHeight = rect(
        minimum: SIMD2<Float>(10, 10),
        maximum: SIMD2<Float>(20, 10)
    )

    for kind in TilingKind.allCases {
        let strategy = TilingStrategy(kind: kind, tileSize: standardTileSize)
        #expect(strategy.images(intersecting: zeroWidth).isEmpty)
        #expect(strategy.images(intersecting: zeroHeight).isEmpty)
    }
}

@Test
func ordinalZeroImageTransformsAgreeWithDisplayFoldAcrossCoordinateClasses() {
    for kind in TilingKind.allCases {
        for point in [
            WorldPoint(x: standardTileSize.width, y: 20),
            WorldPoint(x: 20, y: standardTileSize.height),
            WorldPoint(x: -1, y: -1),
            WorldPoint(x: 300, y: 200),
        ] {
            expectImageTransformAgreement(
                kind: kind,
                tileSize: standardTileSize,
                point: point
            )
        }

        let largeTileSize = PatternSize(width: 256, height: 128)
        for index in [999_999, -999_999] {
            let odd = !index.isMultiple(of: 2)
            let phaseX: Float = kind == .brick && odd
                ? largeTileSize.width * 0.5
                : 0
            let phaseY: Float = kind == .halfDrop && odd
                ? largeTileSize.height * 0.5
                : 0
            expectImageTransformAgreement(
                kind: kind,
                tileSize: largeTileSize,
                point: WorldPoint(
                    x: Float(index) * largeTileSize.width + phaseX + 64,
                    y: Float(index) * largeTileSize.height + phaseY + 32
                )
            )
        }
    }
}

private func rect(
    minimum: SIMD2<Float>,
    maximum: SIMD2<Float>
) -> AxisAlignedRect {
    AxisAlignedRect(minimum: minimum, maximum: maximum)
}

private func isInRowColumnOrdinalOrder(_ images: [TilingImage]) -> Bool {
    zip(images, images.dropFirst()).allSatisfy { lhs, rhs in
        if lhs.cell.row != rhs.cell.row {
            return lhs.cell.row < rhs.cell.row
        }
        if lhs.cell.column != rhs.cell.column {
            return lhs.cell.column < rhs.cell.column
        }
        return lhs.ordinal <= rhs.ordinal
    }
}

private func hasNoEqualImages(_ images: [TilingImage]) -> Bool {
    for firstIndex in images.indices {
        for secondIndex in images.indices where firstIndex < secondIndex {
            if images[firstIndex] == images[secondIndex] {
                return false
            }
        }
    }
    return true
}

private func expectImageTransformAgreement(
    kind: TilingKind,
    tileSize: PatternSize,
    point: WorldPoint
) {
    let strategy = TilingStrategy(kind: kind, tileSize: tileSize)
    let cell = strategy.cell(containing: point)
    let query = rect(
        minimum: point.simd,
        maximum: SIMD2(point.x.nextUp, point.y.nextUp)
    )
    let image = strategy.images(intersecting: query).first {
        $0.cell == cell && $0.ordinal == 0
    }
    let transformed = image?.worldToCanonical.applying(to: point.simd)
    let folded = strategy.displayFold(point)

    #expect(
        transformed.map {
            CanonicalPoint(
                x: testPositiveModulo($0.x, tileSize.width),
                y: testPositiveModulo($0.y, tileSize.height)
            )
        } == folded
    )
}

private func testPositiveModulo(_ value: Float, _ extent: Float) -> Float {
    let remainder = value.truncatingRemainder(dividingBy: extent)
    if remainder == 0 {
        return 0
    }
    return remainder < 0 ? min(remainder + extent, extent.nextDown) : remainder
}

private func runDimensionValidationSubprocess(
    for validationCase: String
) throws -> (status: Int32, standardError: String) {
    let testExecutablePath = tilingTestExecutablePath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
        "--test-bundle-path", testExecutablePath,
        "--filter", "tilingStrategyDimensionValidationRunsInSubprocesses",
        testExecutablePath,
        "--testing-library", "swift-testing",
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["PATTERN_ENGINE_TILING_DIMENSION_CASE": validationCase],
        uniquingKeysWith: { _, new in new }
    )
    process.standardOutput = FileHandle.nullDevice
    let standardError = Pipe()
    process.standardError = standardError

    try process.run()
    process.waitUntilExit()
    let errorOutput = String(
        decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    return (process.terminationStatus, errorOutput)
}

private func tilingTestExecutablePath() -> String {
    guard
        let optionIndex = CommandLine.arguments.firstIndex(of: "--test-bundle-path"),
        CommandLine.arguments.indices.contains(optionIndex + 1)
    else {
        preconditionFailure("Swift Testing test executable path is unavailable")
    }
    return CommandLine.arguments[optionIndex + 1]
}

private func constructStrategyForDimensionValidation(named validationCase: String) {
    let dimensions: (Float, Float)
    switch validationCase {
    case "widthNaN":
        dimensions = (.nan, 288)
    case "widthInfinity":
        dimensions = (.infinity, 288)
    case "heightNaN":
        dimensions = (288, .nan)
    case "heightInfinity":
        dimensions = (288, .infinity)
    case "widthFractional":
        dimensions = (287.5, 288)
    case "heightFractional":
        dimensions = (288, 287.5)
    case "widthBelowMinimum":
        dimensions = (63, 288)
    case "heightBelowMinimum":
        dimensions = (288, 63)
    case "widthAboveMaximum":
        dimensions = (4097, 288)
    case "heightAboveMaximum":
        dimensions = (288, 4097)
    case "widthMinimum":
        dimensions = (64, 288)
    case "widthMaximum":
        dimensions = (4096, 288)
    case "heightMinimum":
        dimensions = (288, 64)
    case "heightMaximum":
        dimensions = (288, 4096)
    default:
        preconditionFailure(
            "Unknown tiling dimension validation case: \(validationCase)"
        )
    }

    let uncheckedSize = unsafeBitCast(
        SIMD2<Float>(dimensions.0, dimensions.1),
        to: PatternSize.self
    )
    _ = TilingStrategy(kind: .grid, tileSize: uncheckedSize)
}
