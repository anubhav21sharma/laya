import Foundation
@testable import PatternEngine
import simd
import Testing

@Suite("Tiling coverage oracle")
struct TilingCoverageOracleTests {
    @Test
    func directFoldProbesCoverEveryTilingKindAndSignedParity() {
        let tileSize = PixelSize(width: 64, height: 96)
        let probes = [
            DirectFoldProbe(
                name: "grid negative",
                tiling: .grid,
                worldCenter: SIMD2(-1.5, -1.5),
                expectedPixels: [PixelCoordinate(x: 62, y: 94)]
            ),
            DirectFoldProbe(
                name: "grid large",
                tiling: .grid,
                worldCenter: SIMD2(640_007.5, -863_988.5),
                expectedPixels: [PixelCoordinate(x: 7, y: 11)]
            ),
            DirectFoldProbe(
                name: "half-drop even column",
                tiling: .halfDrop,
                worldCenter: SIMD2(10.5, 20.5),
                expectedPixels: [PixelCoordinate(x: 10, y: 20)]
            ),
            DirectFoldProbe(
                name: "half-drop positive odd column",
                tiling: .halfDrop,
                worldCenter: SIMD2(74.5, 68.5),
                expectedPixels: [PixelCoordinate(x: 10, y: 20)]
            ),
            DirectFoldProbe(
                name: "half-drop negative odd column",
                tiling: .halfDrop,
                worldCenter: SIMD2(-53.5, -27.5),
                expectedPixels: [PixelCoordinate(x: 10, y: 20)]
            ),
            DirectFoldProbe(
                name: "brick even row",
                tiling: .brick,
                worldCenter: SIMD2(10.5, 20.5),
                expectedPixels: [PixelCoordinate(x: 10, y: 20)]
            ),
            DirectFoldProbe(
                name: "brick positive odd row",
                tiling: .brick,
                worldCenter: SIMD2(42.5, 116.5),
                expectedPixels: [PixelCoordinate(x: 10, y: 20)]
            ),
            DirectFoldProbe(
                name: "brick negative odd row",
                tiling: .brick,
                worldCenter: SIMD2(-21.5, -75.5),
                expectedPixels: [PixelCoordinate(x: 10, y: 20)]
            ),
            DirectFoldProbe(
                name: "mirror-x even column",
                tiling: .mirrorX,
                worldCenter: SIMD2(10.5, 20.5),
                expectedPixels: [PixelCoordinate(x: 10, y: 20)]
            ),
            DirectFoldProbe(
                name: "mirror-x odd column",
                tiling: .mirrorX,
                worldCenter: SIMD2(74.5, 20.5),
                expectedPixels: [PixelCoordinate(x: 53, y: 20)]
            ),
            DirectFoldProbe(
                name: "mirror-y odd row",
                tiling: .mirrorY,
                worldCenter: SIMD2(10.5, 116.5),
                expectedPixels: [PixelCoordinate(x: 10, y: 75)]
            ),
            DirectFoldProbe(
                name: "mirror-xy even column and row",
                tiling: .mirrorXY,
                worldCenter: SIMD2(10.5, 20.5),
                expectedPixels: [PixelCoordinate(x: 10, y: 20)]
            ),
            DirectFoldProbe(
                name: "mirror-xy odd column only",
                tiling: .mirrorXY,
                worldCenter: SIMD2(74.5, 20.5),
                expectedPixels: [PixelCoordinate(x: 53, y: 20)]
            ),
            DirectFoldProbe(
                name: "mirror-xy odd row only",
                tiling: .mirrorXY,
                worldCenter: SIMD2(10.5, 116.5),
                expectedPixels: [PixelCoordinate(x: 10, y: 75)]
            ),
            DirectFoldProbe(
                name: "mirror-xy odd column and row",
                tiling: .mirrorXY,
                worldCenter: SIMD2(74.5, 116.5),
                expectedPixels: [PixelCoordinate(x: 53, y: 75)]
            ),
            DirectFoldProbe(
                name: "rotational identity and half-turn",
                tiling: .rotational,
                worldCenter: SIMD2(10.5, 20.5),
                expectedPixels: [
                    PixelCoordinate(x: 10, y: 20),
                    PixelCoordinate(x: 53, y: 75),
                ]
            ),
        ]

        for probe in probes {
            let result = TilingCoverageOracle.renderCanonical(
                footprint: .hardRound(radius: 1),
                brushToWorld: pointProbeTransform(at: probe.worldCenter),
                tileSize: tileSize,
                tiling: probe.tiling,
                supersampling: 1
            )

            #expect(
                fullyCoveredPixels(in: result.coverage) == probe.expectedPixels,
                "\(probe.name)"
            )
            #expect(
                result.coverage.bytes.allSatisfy { $0 == 0 || $0 == 255 },
                "\(probe.name)"
            )
        }
    }

    @Test
    func rotationalGeneratorsAndFixedPointAreExact() {
        let rectangular = PixelSize(width: 64, height: 96)
        let base = renderPointProbe(
            center: SIMD2(10.5, 20.5),
            tileSize: rectangular,
            tiling: .rotational
        )
        let translated = renderPointProbe(
            center: SIMD2(202.5, -171.5),
            tileSize: rectangular,
            tiling: .rotational
        )
        let halfTurned = renderPointProbe(
            center: SIMD2(53.5, 75.5),
            tileSize: rectangular,
            tiling: .rotational
        )

        #expect(base.coverage == translated.coverage)
        #expect(base.coverage == halfTurned.coverage)
        #expect(fullyCoveredPixels(in: base.coverage) == [
            PixelCoordinate(x: 10, y: 20),
            PixelCoordinate(x: 53, y: 75),
        ])

        let fixedTile = PixelSize(width: 65, height: 97)
        let fixed = renderPointProbe(
            center: SIMD2(32.5, 48.5),
            tileSize: fixedTile,
            tiling: .rotational
        )
        #expect(fullyCoveredPixels(in: fixed.coverage) == [
            PixelCoordinate(x: 32, y: 48),
        ])
        #expect(fixed.coverage.bytes.reduce(0, { $0 + Int($1) }) == 255)
    }

    @Test
    func exactIntegerRightBottomNegativeAndLargeCentersWrapHalfOpen() {
        let tileSize = PixelSize(width: 64, height: 96)
        let centers = [
            SIMD2<Float>(64, 96),
            SIMD2<Float>(-64, -96),
            SIMD2<Float>(64_000, -96_000),
        ]
        let expected = Set([
            PixelCoordinate(x: 0, y: 0),
            PixelCoordinate(x: 63, y: 0),
            PixelCoordinate(x: 0, y: 95),
            PixelCoordinate(x: 63, y: 95),
        ])

        for center in centers {
            let result = TilingCoverageOracle.renderCanonical(
                footprint: .hardRound(radius: 1),
                brushToWorld: Affine2D(
                    xAxis: SIMD2(0.4, 0),
                    yAxis: SIMD2(0, 0.4),
                    translation: center
                ),
                tileSize: tileSize,
                tiling: .grid,
                supersampling: 2
            )
            let nonzero = Set(
                result.coverage.bytes.indices.compactMap { index in
                    result.coverage.bytes[index] == 0
                        ? nil
                        : PixelCoordinate(
                            x: index % tileSize.width,
                            y: index / tileSize.width
                        )
                }
            )

            #expect(nonzero == expected)
            #expect(expected.allSatisfy {
                result.coverage.bytes[$0.y * tileSize.width + $0.x] == 64
            })
        }
    }

    @Test
    func rectangularOutputAndCoordinateDiagnosticsUseIndependentBGRAEncoding() {
        let tileSize = PixelSize(width: 64, height: 96)
        let result = renderPointProbe(
            center: SIMD2(10.5, 20.5),
            tileSize: tileSize,
            tiling: .grid
        )
        let pixelIndex = 20 * tileSize.width + 10
        let byteOffset = pixelIndex * 4

        #expect(result.coverage.pixelSize == tileSize)
        #expect(result.coverage.bytes.count == 64 * 96)
        #expect(result.canonicalCoordinatesBGRA.count == 64 * 96 * 4)
        #expect(result.brushLocalCoordinatesBGRA.count == 64 * 96 * 4)
        #expect(
            Array(result.canonicalCoordinatesBGRA[byteOffset..<(byteOffset + 4)])
                == [
                    0,
                    encodeUnitCoordinate(20.5 / 96),
                    encodeUnitCoordinate(10.5 / 64),
                    255,
                ]
        )
        #expect(
            Array(result.brushLocalCoordinatesBGRA[byteOffset..<(byteOffset + 4)])
                == [0, 128, 128, 255]
        )
        #expect(
            result.canonicalCoordinatesBGRA
                != result.brushLocalCoordinatesBGRA
        )
    }

    @Test
    func comparisonCountsOneInjectedHoleAndOneInjectedPhantom() {
        let pixelSize = PixelSize(width: 2, height: 2)
        let expected = OracleCoverage(
            pixelSize: pixelSize,
            bytes: [255, 0, 128, 64]
        )
        let actual = OracleCoverage(
            pixelSize: pixelSize,
            bytes: [0, 255, 128, 64]
        )

        #expect(
            TilingCoverageOracle.compare(
                expected: expected,
                actual: actual,
                boundaryTolerance: 0
            ) == CoverageComparison(
                holeCount: 1,
                phantomCount: 1,
                maximumDelta: 255
            )
        )

        let withinTolerance = TilingCoverageOracle.compare(
            expected: OracleCoverage(pixelSize: pixelSize, bytes: [100, 0, 0, 0]),
            actual: OracleCoverage(pixelSize: pixelSize, bytes: [99, 1, 0, 0]),
            boundaryTolerance: 1
        )
        #expect(withinTolerance.holeCount == 0)
        #expect(withinTolerance.phantomCount == 0)
        #expect(withinTolerance.maximumDelta == 1)

        let partialCoverage = TilingCoverageOracle.compare(
            expected: OracleCoverage(
                pixelSize: pixelSize,
                bytes: [100, 50, 0, 0]
            ),
            actual: OracleCoverage(
                pixelSize: pixelSize,
                bytes: [50, 100, 0, 0]
            ),
            boundaryTolerance: 0
        )
        #expect(partialCoverage.holeCount == 0)
        #expect(partialCoverage.phantomCount == 0)
        #expect(partialCoverage.maximumDelta == 50)

        let presenceTransitions = TilingCoverageOracle.compare(
            expected: OracleCoverage(
                pixelSize: pixelSize,
                bytes: [1, 0, 0, 0]
            ),
            actual: OracleCoverage(
                pixelSize: pixelSize,
                bytes: [0, 1, 0, 0]
            ),
            boundaryTolerance: 0
        )
        #expect(presenceTransitions.holeCount == 1)
        #expect(presenceTransitions.phantomCount == 1)
        #expect(presenceTransitions.maximumDelta == 1)

        let suppressedTransitions = TilingCoverageOracle.compare(
            expected: OracleCoverage(
                pixelSize: pixelSize,
                bytes: [1, 0, 0, 0]
            ),
            actual: OracleCoverage(
                pixelSize: pixelSize,
                bytes: [0, 1, 0, 0]
            ),
            boundaryTolerance: 1
        )
        #expect(suppressedTransitions.holeCount == 0)
        #expect(suppressedTransitions.phantomCount == 0)
        #expect(suppressedTransitions.maximumDelta == 1)
    }

    @Test
    func supersamplingFourThroughEightCoversEveryTilingKind() {
        let tileSize = PixelSize(width: 65, height: 67)
        let tilings: [(String, TilingKind)] = [
            ("grid", .grid),
            ("half-drop", .halfDrop),
            ("brick", .brick),
            ("mirror-x", .mirrorX),
            ("mirror-y", .mirrorY),
            ("mirror-xy", .mirrorXY),
            ("rotational", .rotational),
        ]

        for supersampling in 4...8 {
            for (name, tiling) in tilings {
                let testCase = OraclePropertyCase(
                    name: "\(name) ss\(supersampling)",
                    footprint: .hardRound(radius: 2),
                    brushToWorld: unitTransform(
                        center: SIMD2(70.31, 72.27)
                    ),
                    tileSize: tileSize,
                    tiling: tiling,
                    supersampling: supersampling
                )
                let expected = TilingCoverageOracle.renderCanonical(
                    footprint: testCase.footprint,
                    brushToWorld: testCase.brushToWorld,
                    tileSize: tileSize,
                    tiling: tiling,
                    supersampling: supersampling
                )
                let actual = rasterizeProductionFragments(testCase)
                let comparison = TilingCoverageOracle.compare(
                    expected: expected.coverage,
                    actual: actual.coverage,
                    boundaryTolerance: 1
                )
                #expect(comparison.holeCount == 0, "\(testCase.name)")
                #expect(comparison.phantomCount == 0, "\(testCase.name)")
                #expect(comparison.maximumDelta <= 1, "\(testCase.name)")
            }
        }
    }

    @Test
    func supersamplingEightUsesBitSixtyThreeAndMaximumDiagnosticSum() {
        let tileSize = PixelSize(width: 64, height: 64)
        let result = TilingCoverageOracle.renderCanonical(
            footprint: .hardRound(radius: 1),
            brushToWorld: Affine2D(
                xAxis: SIMD2(32, 0),
                yAxis: SIMD2(0, 256),
                translation: SIMD2(0.5, 1)
            ),
            tileSize: tileSize,
            tiling: .grid,
            supersampling: 8
        )

        #expect(result.coverage.bytes[0] == 255)
        #expect(
            diagnosticPixel(
                result.canonicalCoordinatesBGRA,
                x: 0,
                y: 0,
                width: tileSize.width
            )[3] == 255
        )
        #expect(
            diagnosticPixel(
                result.brushLocalCoordinatesBGRA,
                x: 0,
                y: 0,
                width: tileSize.width
            ) == [0, 255, 128, 255]
        )
    }

    @Test
    func productionFragmentsMatchIndependentOraclePropertyMatrix() {
        for testCase in oraclePropertyMatrix {
            let expected = TilingCoverageOracle.renderCanonical(
                footprint: testCase.footprint,
                brushToWorld: testCase.brushToWorld,
                tileSize: testCase.tileSize,
                tiling: testCase.tiling,
                supersampling: testCase.supersampling
            )
            let actual = rasterizeProductionFragments(testCase)
            let comparison = TilingCoverageOracle.compare(
                expected: expected.coverage,
                actual: actual.coverage,
                boundaryTolerance: 1
            )

            #expect(
                expected.coverage.bytes.contains(where: { $0 > 0 }),
                "\(testCase.name): oracle output must not be all zero"
            )
            #expect(
                actual.coverage.bytes.contains(where: { $0 > 0 }),
                "\(testCase.name): production output must not be all zero"
            )
            #expect(comparison.holeCount == 0, "\(testCase.name)")
            #expect(comparison.phantomCount == 0, "\(testCase.name)")
            #expect(comparison.maximumDelta <= 1, "\(testCase.name)")
        }
    }

    @Test
    func compiledDescriptorsMatchIndependentOracleAcrossLegacyMatrix() {
        for testCase in compiledDescriptorParityMatrix {
            let expected = TilingCoverageOracle.renderCanonical(
                footprint: testCase.oracleCase.footprint,
                brushToWorld: testCase.oracleCase.brushToWorld,
                tileSize: testCase.oracleCase.tileSize,
                tiling: testCase.oracleCase.tiling,
                supersampling: testCase.oracleCase.supersampling
            )
            let actual = rasterizeProductionFragments(testCase.oracleCase)

            let coverageMatches = expected.coverage.bytes.elementsEqual(
                actual.coverage.bytes
            )
            let canonicalMatches = expected.canonicalCoordinatesBGRA
                .elementsEqual(actual.canonicalCoordinatesBGRA)
            let brushLocalMatches = expected.brushLocalCoordinatesBGRA
                .elementsEqual(actual.brushLocalCoordinatesBGRA)
            guard coverageMatches else {
                Issue.record(
                    "\(testCase.failureContext): coverage bytes"
                )
                return
            }
            guard canonicalMatches else {
                Issue.record(
                    "\(testCase.failureContext): canonical-coordinate bytes"
                )
                return
            }
            guard brushLocalMatches else {
                Issue.record(
                    "\(testCase.failureContext): brush-local bytes"
                )
                return
            }
        }
    }

    @Test
    func triangularOracleMatchesAtLargeRotatedCoordinates() {
        let testCase = OraclePropertyCase(
            name: "triangular translation large rotated",
            footprint: .hardRound(radius: 5),
            brushToWorld: Affine2D(
                xAxis: SIMD2(0, 1),
                yAxis: SIMD2(-1, 0),
                translation: SIMD2(640_020, -864_066)
            ),
            tileSize: PixelSize(width: 64, height: 96),
            tiling: .hexagons,
            supersampling: 2
        )
        let expected = TilingCoverageOracle.renderCanonical(
            footprint: testCase.footprint,
            brushToWorld: testCase.brushToWorld,
            tileSize: testCase.tileSize,
            tiling: testCase.tiling,
            supersampling: testCase.supersampling
        )
        let actual = rasterizeProductionFragments(testCase)

        let mismatches = expected.coverage.bytes.indices.filter {
            expected.coverage.bytes[$0] != actual.coverage.bytes[$0]
        }
        let summary = mismatches.prefix(16).map { index in
            let x = index % testCase.tileSize.width
            let y = index / testCase.tileSize.width
            let expectedByte = expected.coverage.bytes[index]
            let actualByte = actual.coverage.bytes[index]
            return "(\(x),\(y)) \(expectedByte)/\(actualByte)"
        }.joined(separator: ", ")
        #expect(
            mismatches.isEmpty,
            "mismatches=\(summary)"
        )
    }

    @Test(arguments: [
        SymmetryPresetID.hexagons,
        .rotation3,
        .rotation6,
        .kaleidoscope60,
        .kaleidoscope30,
    ])
    func orientedTriangularConfigurationsMatchIndependentOracle(
        _ preset: SymmetryPresetID
    ) throws {
        let rasterSize = PixelSize(width: 64, height: 96)
        let spacing: Float = 80
        let angle: Float = 0.37
        let configuration = PeriodicSymmetryConfiguration(
            presetID: preset,
            repeatSize: PatternSize(width: spacing, height: spacing),
            orientationRadians: angle
        )
        let horizontal = SIMD2(
            spacing * cos(angle),
            spacing * sin(angle)
        )
        let vertical = SIMD2(
            -sqrt(Float(3)) * spacing * sin(angle),
            sqrt(Float(3)) * spacing * cos(angle)
        )
        let brushToWorld = Affine2D(
            xAxis: SIMD2(6.3, 1.4),
            yAxis: SIMD2(-2.1, 5.7),
            translation: horizontal * 1.31 + vertical * -0.73
        )
        let expected = TilingCoverageOracle.renderCanonical(
            footprint: .asymmetricTriangle,
            brushToWorld: brushToWorld,
            configuration: configuration,
            canonicalRasterSize: rasterSize,
            supersampling: 2,
            coverageSymmetry: .oriented
        )
        let strategy = try TilingStrategy(
            configuration: configuration,
            canonicalRasterSize: rasterSize
        )
        let fragments = TilingProjection.fragments(
            for: StampFootprint(
                brushToWorld: brushToWorld,
                localBounds: AxisAlignedRect(
                    minimum: SIMD2(-0.75, -0.60),
                    maximum: SIMD2(0.85, 0.90)
                ),
                coverageSymmetry: .oriented
            ),
            using: strategy
        )
        let actual = rasterizeProductionFragments(
            OraclePropertyCase(
                name: "\(preset)",
                footprint: .asymmetricTriangle,
                brushToWorld: brushToWorld,
                tileSize: rasterSize,
                tiling: preset,
                supersampling: 2
            ),
            fragments: fragments
        )
        let translatedBrush = Affine2D(
            xAxis: brushToWorld.xAxis,
            yAxis: brushToWorld.yAxis,
            translation: brushToWorld.translation
                + horizontal * 3 - vertical * 2
        )
        let repeatedExpected = TilingCoverageOracle.renderCanonical(
            footprint: .asymmetricTriangle,
            brushToWorld: translatedBrush,
            configuration: configuration,
            canonicalRasterSize: rasterSize,
            supersampling: 2,
            coverageSymmetry: .oriented
        )
        let repeatedFragments = TilingProjection.fragments(
            for: StampFootprint(
                brushToWorld: translatedBrush,
                localBounds: AxisAlignedRect(
                    minimum: SIMD2(-0.75, -0.60),
                    maximum: SIMD2(0.85, 0.90)
                ),
                coverageSymmetry: .oriented
            ),
            using: strategy
        )
        let repeatedActual = rasterizeProductionFragments(
            OraclePropertyCase(
                name: "\(preset) repeated",
                footprint: .asymmetricTriangle,
                brushToWorld: translatedBrush,
                tileSize: rasterSize,
                tiling: preset,
                supersampling: 2
            ),
            fragments: repeatedFragments
        )

        #expect(expected == actual)
        #expect(repeatedExpected == repeatedActual)
        #expect(expected == repeatedExpected)
        #expect(actual == repeatedActual)
    }

    @Test
    func orientedSquareConfigurationsMatchIndependentOracleAndRepeatExactly()
        throws
    {
        let cases: [
            (
                configuration: PeriodicSymmetryConfiguration,
                rasterSize: PixelSize
            )
        ] = [
            (
                PeriodicSymmetryConfiguration(
                    presetID: .squareRotation,
                    repeatSize: PatternSize(width: 80, height: 80),
                    orientationRadians: 0.37
                ),
                PixelSize(width: 96, height: 64)
            ),
            (
                PeriodicSymmetryConfiguration(
                    presetID: .squareKaleidoscope,
                    repeatSize: PatternSize(width: 96, height: 96),
                    orientationRadians: -0.41
                ),
                PixelSize(width: 64, height: 96)
            ),
        ]

        for testCase in cases {
            let side = testCase.configuration.repeatSize.width
            let angle = testCase.configuration.orientationRadians
            let u = SIMD2(side * cos(angle), side * sin(angle))
            let v = SIMD2(-side * sin(angle), side * cos(angle))
            let baseTransform = Affine2D(
                xAxis: SIMD2(6.3, 1.4),
                yAxis: SIMD2(-2.1, 5.7),
                translation: u * 1.31 + v * -0.73
            )
            var baseline: OracleRasterResult?

            for translation in [
                baseTransform.translation,
                baseTransform.translation + u * 3 + v * -2,
            ] {
                let brushToWorld = Affine2D(
                    xAxis: baseTransform.xAxis,
                    yAxis: baseTransform.yAxis,
                    translation: translation
                )
                let expected = TilingCoverageOracle.renderCanonical(
                    footprint: .asymmetricTriangle,
                    brushToWorld: brushToWorld,
                    configuration: testCase.configuration,
                    canonicalRasterSize: testCase.rasterSize,
                    supersampling: 2,
                    coverageSymmetry: .oriented
                )
                let strategy = try TilingStrategy(
                    configuration: testCase.configuration,
                    canonicalRasterSize: testCase.rasterSize
                )
                let fragments = TilingProjection.fragments(
                    for: StampFootprint(
                        brushToWorld: brushToWorld,
                        localBounds: AxisAlignedRect(
                            minimum: SIMD2(-0.75, -0.60),
                            maximum: SIMD2(0.85, 0.90)
                        ),
                        coverageSymmetry: .oriented
                    ),
                    using: strategy
                )
                let actual = rasterizeProductionFragments(
                    OraclePropertyCase(
                        name: "\(testCase.configuration.presetID)",
                        footprint: .asymmetricTriangle,
                        brushToWorld: brushToWorld,
                        tileSize: testCase.rasterSize,
                        tiling: testCase.configuration.presetID,
                        supersampling: 2
                    ),
                    fragments: fragments
                )

                #expect(expected.coverage.bytes == actual.coverage.bytes)
                #expect(
                    expected.canonicalCoordinatesBGRA
                        == actual.canonicalCoordinatesBGRA
                )
                #expect(
                    expected.brushLocalCoordinatesBGRA
                        == actual.brushLocalCoordinatesBGRA
                )
                if let baseline {
                    #expect(expected == baseline)
                } else {
                    baseline = expected
                }
            }
        }
    }

    @Test
    func oracleDoesNotConsumeProductionDescriptors() throws {
        let source = try String(
            contentsOf: packageRoot()
                .appending(
                    path:
                        "Sources/PatternEngine/Verification/TilingCoverageOracle.swift"
                ),
            encoding: .utf8
        )

        #expect(source.contains("tiling: TilingKind"))
        #expect(!source.contains("CompiledSymmetry"))
        #expect(!source.contains("CompiledIsometry"))
        #expect(!source.contains("CompiledOwnership"))
        #expect(!source.contains("CompiledDisplayProgram"))
    }

    @Test
    func coordinateDiagnosticsMatchAnIndependentFragmentRasterizer() {
        let diagnosticCases = oraclePropertyMatrix.filter {
            [
                "rotated hard-round",
                "half-drop asymmetric corner",
                "mirror-xy asymmetric corner",
            ].contains($0.name)
        }

        for testCase in diagnosticCases {
            let expected = TilingCoverageOracle.renderCanonical(
                footprint: testCase.footprint,
                brushToWorld: testCase.brushToWorld,
                tileSize: testCase.tileSize,
                tiling: testCase.tiling,
                supersampling: testCase.supersampling
            )
            let actual = rasterizeProductionFragments(testCase)

            #expect(
                maximumByteDelta(
                    expected.canonicalCoordinatesBGRA,
                    actual.canonicalCoordinatesBGRA
                ) <= 1,
                "\(testCase.name): canonical coordinates"
            )
            #expect(
                maximumByteDelta(
                    expected.brushLocalCoordinatesBGRA,
                    actual.brushLocalCoordinatesBGRA
                ) <= 1,
                "\(testCase.name): brush-local coordinates"
            )
            #expect(
                expected.canonicalCoordinatesBGRA.contains(where: { $0 > 0 }),
                "\(testCase.name): canonical diagnostics must not be all zero"
            )
            #expect(
                expected.brushLocalCoordinatesBGRA.contains(where: { $0 > 0 }),
                "\(testCase.name): brush diagnostics must not be all zero"
            )
        }
    }

    @Test
    func rotationalBrushDiagnosticsFollowSourceOverCandidateOrder() {
        let tileSize = PixelSize(width: 65, height: 97)
        let center = SIMD2<Float>(32.5, 48.5)
        let centeredHardRound = OraclePropertyCase(
            name: "centered rotational hard-round",
            footprint: .hardRound(radius: 8),
            brushToWorld: unitTransform(center: center),
            tileSize: tileSize,
            tiling: .rotational,
            supersampling: 1
        )
        let centeredExpected = TilingCoverageOracle.renderCanonical(
            footprint: centeredHardRound.footprint,
            brushToWorld: centeredHardRound.brushToWorld,
            tileSize: tileSize,
            tiling: .rotational,
            supersampling: 1
        )
        let centeredActual = rasterizeProductionFragments(centeredHardRound)
        #expect(
            centeredExpected.brushLocalCoordinatesBGRA
                == centeredActual.brushLocalCoordinatesBGRA
        )
        #expect(
            diagnosticPixel(
                centeredExpected.brushLocalCoordinatesBGRA,
                x: 32,
                y: 44,
                width: tileSize.width
            ) == [0, 64, 128, 255]
        )
        #expect(
            diagnosticPixel(
                centeredExpected.brushLocalCoordinatesBGRA,
                x: 32,
                y: 52,
                width: tileSize.width
            ) == [0, 191, 128, 255]
        )

        let boundaryFixedRound = OraclePropertyCase(
            name: "boundary-fixed rotational hard-round",
            footprint: .hardRound(radius: 8),
            brushToWorld: unitTransform(center: SIMD2(0, 48.5)),
            tileSize: tileSize,
            tiling: .rotational,
            supersampling: 1
        )
        let boundaryExpected = TilingCoverageOracle.renderCanonical(
            footprint: boundaryFixedRound.footprint,
            brushToWorld: boundaryFixedRound.brushToWorld,
            tileSize: tileSize,
            tiling: .rotational,
            supersampling: 1
        )
        let boundaryActual = rasterizeProductionFragments(boundaryFixedRound)
        let boundaryProbe = diagnosticPixel(
            boundaryExpected.brushLocalCoordinatesBGRA,
            x: 4,
            y: 48,
            width: tileSize.width
        )
        #expect(boundaryProbe == [0, 128, 56, 255])
        #expect(
            boundaryProbe == diagnosticPixel(
                boundaryActual.brushLocalCoordinatesBGRA,
                x: 4,
                y: 48,
                width: tileSize.width
            )
        )

        let orientedOverlap = OraclePropertyCase(
            name: "overlapping rotational triangle",
            footprint: .asymmetricTriangle,
            brushToWorld: scaledTransform(scale: 20, center: center),
            tileSize: tileSize,
            tiling: .rotational,
            supersampling: 1
        )
        let orientedExpected = TilingCoverageOracle.renderCanonical(
            footprint: orientedOverlap.footprint,
            brushToWorld: orientedOverlap.brushToWorld,
            tileSize: tileSize,
            tiling: .rotational,
            supersampling: 1
        )
        let orientedActual = rasterizeProductionFragments(orientedOverlap)
        let orientedTop = diagnosticPixel(
            orientedExpected.brushLocalCoordinatesBGRA,
            x: 32,
            y: 44,
            width: tileSize.width
        )
        let orientedBottom = diagnosticPixel(
            orientedExpected.brushLocalCoordinatesBGRA,
            x: 32,
            y: 52,
            width: tileSize.width
        )
        #expect(orientedTop == [0, 153, 128, 255])
        #expect(orientedBottom == [0, 102, 128, 255])
        #expect(
            orientedTop == diagnosticPixel(
                orientedActual.brushLocalCoordinatesBGRA,
                x: 32,
                y: 44,
                width: tileSize.width
            )
        )
        #expect(
            orientedBottom == diagnosticPixel(
                orientedActual.brushLocalCoordinatesBGRA,
                x: 32,
                y: 52,
                width: tileSize.width
            )
        )
    }

    @Test
    func rotationalMultiCellHardRoundsMatchFullProductionBrushBuffers() {
        let tileSize = PixelSize(width: 64, height: 64)
        let cases = [
            OraclePropertyCase(
                name: "radius-63 rotational hard-round",
                footprint: .hardRound(radius: 63),
                brushToWorld: unitTransform(center: SIMD2(32, 32)),
                tileSize: tileSize,
                tiling: .rotational,
                supersampling: 1
            ),
            OraclePropertyCase(
                name: "maximum rotational hard-round",
                footprint: .hardRound(radius: 256),
                brushToWorld: unitTransform(center: SIMD2(32, 32)),
                tileSize: tileSize,
                tiling: .rotational,
                supersampling: 1
            ),
        ]
        #expect(productionFragments(for: cases[0]).count == 14)

        for testCase in cases {
            let expected = TilingCoverageOracle.renderCanonical(
                footprint: testCase.footprint,
                brushToWorld: testCase.brushToWorld,
                tileSize: tileSize,
                tiling: .rotational,
                supersampling: 1
            )
            let actual = rasterizeProductionFragments(testCase)
            let repeated = TilingCoverageOracle.renderCanonical(
                footprint: testCase.footprint,
                brushToWorld: testCase.brushToWorld,
                tileSize: tileSize,
                tiling: .rotational,
                supersampling: 1
            )

            #expect(expected == repeated, "\(testCase.name): deterministic")
            #expect(
                maximumByteDelta(
                    expected.coverage.bytes,
                    actual.coverage.bytes
                ) == 0,
                "\(testCase.name): coverage"
            )
            #expect(
                maximumByteDelta(
                    expected.brushLocalCoordinatesBGRA,
                    actual.brushLocalCoordinatesBGRA
                ) <= 1,
                "\(testCase.name): full brush buffer"
            )
        }
    }

    @Test
    func rotatedAndReflectedMultiCellRoundsMatchFullProductionBrushBuffers() {
        let tileSize = PixelSize(width: 64, height: 64)
        let cases: [
            (testCase: OraclePropertyCase, expectedFragmentCount: Int)
        ] = [
            (
                OraclePropertyCase(
                    name: "rotated radius-63 centered in tile",
                    footprint: .hardRound(radius: 63),
                    brushToWorld: Affine2D(
                        xAxis: SIMD2(0.8, 0.6),
                        yAxis: SIMD2(-0.6, 0.8),
                        translation: SIMD2(32, 32)
                    ),
                    tileSize: tileSize,
                    tiling: .rotational,
                    supersampling: 1
                ),
                12
            ),
            (
                OraclePropertyCase(
                    name: "rotated radius-63 centered on cell corner",
                    footprint: .hardRound(radius: 63),
                    brushToWorld: Affine2D(
                        xAxis: SIMD2(0.8, 0.6),
                        yAxis: SIMD2(-0.6, 0.8),
                        translation: SIMD2(0, 0)
                    ),
                    tileSize: tileSize,
                    tiling: .rotational,
                    supersampling: 1
                ),
                15
            ),
            (
                OraclePropertyCase(
                    name: "reflected radius-63 centered in tile",
                    footprint: .hardRound(radius: 63),
                    brushToWorld: Affine2D(
                        xAxis: SIMD2(-0.8, 0.6),
                        yAxis: SIMD2(0.6, 0.8),
                        translation: SIMD2(32, 32)
                    ),
                    tileSize: tileSize,
                    tiling: .rotational,
                    supersampling: 1
                ),
                12
            ),
            (
                OraclePropertyCase(
                    name: "reflected radius-63 centered on cell corner",
                    footprint: .hardRound(radius: 63),
                    brushToWorld: Affine2D(
                        xAxis: SIMD2(-0.8, 0.6),
                        yAxis: SIMD2(0.6, 0.8),
                        translation: SIMD2(0, 0)
                    ),
                    tileSize: tileSize,
                    tiling: .rotational,
                    supersampling: 1
                ),
                15
            ),
        ]

        for entry in cases {
            let testCase = entry.testCase
            let fragments = productionFragments(for: testCase)
            #expect(
                fragments.count == entry.expectedFragmentCount,
                "\(testCase.name): retained fragments"
            )
            let expected = TilingCoverageOracle.renderCanonical(
                footprint: testCase.footprint,
                brushToWorld: testCase.brushToWorld,
                tileSize: tileSize,
                tiling: .rotational,
                supersampling: 1
            )
            let actual = rasterizeProductionFragments(testCase)
            let repeated = TilingCoverageOracle.renderCanonical(
                footprint: testCase.footprint,
                brushToWorld: testCase.brushToWorld,
                tileSize: tileSize,
                tiling: .rotational,
                supersampling: 1
            )

            #expect(expected == repeated, "\(testCase.name): deterministic")
            #expect(
                maximumByteDelta(
                    expected.coverage.bytes,
                    actual.coverage.bytes
                ) == 0,
                "\(testCase.name): coverage"
            )
            #expect(
                maximumByteDelta(
                    expected.brushLocalCoordinatesBGRA,
                    actual.brushLocalCoordinatesBGRA
                ) <= 1,
                "\(testCase.name): full brush buffer"
            )
        }
    }

    @Test
    func rotatedLargeCoordinatesMatchFullProductionBrushBuffers() {
        let tileSize = PixelSize(width: 64, height: 96)
        let cases = [
            OraclePropertyCase(
                name: "positive-x negative-y rotated hard-round",
                footprint: .hardRound(radius: 6),
                brushToWorld: Affine2D(
                    xAxis: SIMD2(0.8, 0.6),
                    yAxis: SIMD2(-0.6, 0.8),
                    translation: SIMD2(640_000, -640_000)
                ),
                tileSize: tileSize,
                tiling: .grid,
                supersampling: 2
            ),
            OraclePropertyCase(
                name: "negative-x positive-y rotated hard-round",
                footprint: .hardRound(radius: 6),
                brushToWorld: Affine2D(
                    xAxis: SIMD2(-0.8, 0.6),
                    yAxis: SIMD2(0.6, 0.8),
                    translation: SIMD2(-640_000, 640_000)
                ),
                tileSize: tileSize,
                tiling: .rotational,
                supersampling: 2
            ),
        ]

        for testCase in cases {
            let expected = TilingCoverageOracle.renderCanonical(
                footprint: testCase.footprint,
                brushToWorld: testCase.brushToWorld,
                tileSize: tileSize,
                tiling: testCase.tiling,
                supersampling: testCase.supersampling
            )
            let actual = rasterizeProductionFragments(testCase)

            #expect(
                maximumByteDelta(
                    expected.coverage.bytes,
                    actual.coverage.bytes
                ) == 0,
                "\(testCase.name): coverage"
            )
            #expect(
                maximumByteDelta(
                    expected.brushLocalCoordinatesBGRA,
                    actual.brushLocalCoordinatesBGRA
                ) <= 1,
                "\(testCase.name): full brush buffer"
            )
        }
    }

    @Test
    func propertyHarnessNegativeControlsDetectCoverageAndDiagnosticCorruption() {
        let testCase = oraclePropertyMatrix.first {
            $0.name == "grid interior"
        }!
        let expected = TilingCoverageOracle.renderCanonical(
            footprint: testCase.footprint,
            brushToWorld: testCase.brushToWorld,
            tileSize: testCase.tileSize,
            tiling: testCase.tiling,
            supersampling: testCase.supersampling
        )
        let actual = rasterizeProductionFragments(testCase)
        let baseline = TilingCoverageOracle.compare(
            expected: expected.coverage,
            actual: actual.coverage,
            boundaryTolerance: 1
        )
        #expect(baseline.holeCount == 0)
        #expect(baseline.phantomCount == 0)
        #expect(baseline.maximumDelta <= 1)

        var corruptedCoverage = actual.coverage.bytes
        let coveredIndex = expected.coverage.bytes.firstIndex { $0 == 255 }!
        let emptyIndex = expected.coverage.bytes.firstIndex { $0 == 0 }!
        corruptedCoverage[coveredIndex] = 0
        corruptedCoverage[emptyIndex] = 255
        let detectedCoverage = TilingCoverageOracle.compare(
            expected: expected.coverage,
            actual: OracleCoverage(
                pixelSize: actual.coverage.pixelSize,
                bytes: corruptedCoverage
            ),
            boundaryTolerance: 1
        )
        #expect(detectedCoverage.holeCount >= 1)
        #expect(detectedCoverage.phantomCount >= 1)
        #expect(detectedCoverage.maximumDelta == 255)

        var corruptedCanonical = actual.canonicalCoordinatesBGRA
        let diagnosticOffset = coveredIndex * 4 + 2
        corruptedCanonical[diagnosticOffset] =
            corruptedCanonical[diagnosticOffset] < 128 ? 255 : 0
        #expect(
            maximumByteDelta(
                expected.canonicalCoordinatesBGRA,
                corruptedCanonical
            ) > 1
        )

        var corruptedBrush = actual.brushLocalCoordinatesBGRA
        corruptedBrush[coveredIndex * 4 + 1] =
            corruptedBrush[coveredIndex * 4 + 1] < 128 ? 255 : 0
        #expect(
            maximumByteDelta(
                expected.brushLocalCoordinatesBGRA,
                corruptedBrush
            ) > 1
        )
    }

    @Test
    func invalidSizesCountsSamplingAndToleranceFailFast() throws {
        if let validationCase = ProcessInfo.processInfo.environment[
            "PATTERN_ENGINE_ORACLE_VALIDATION_CASE"
        ] {
            exerciseOracleValidation(named: validationCase)
            return
        }

        let invalidCases = [
            ("coverageByteCount", "OracleCoverage byte count must equal pixel area"),
            ("coverageAreaOverflow", "OracleCoverage pixel area must be Int-representable"),
            ("canonicalByteCount", "Oracle canonical BGRA byte count must equal pixel area times four"),
            ("brushLocalByteCount", "Oracle brush-local BGRA byte count must equal pixel area times four"),
            ("tileTooSmall", "TilingCoverageOracle tile width must be in 64...4096"),
            ("tileTooLarge", "TilingCoverageOracle tile height must be in 64...4096"),
            ("supersamplingZero", "TilingCoverageOracle supersampling must be in 1...8"),
            ("supersamplingTooLarge", "TilingCoverageOracle supersampling must be in 1...8"),
            ("radiusTooSmall", "TilingCoverageOracle radius must be finite and at least 1"),
            ("radiusTooLarge", "TilingCoverageOracle radius exceeds the supported tile-relative maximum"),
            ("singularTransform", "TilingCoverageOracle brush-to-world transform must be nonsingular"),
            ("illConditionedTransform", "TilingCoverageOracle brush-to-world transform must be nonsingular"),
            ("nonfiniteInverse", "TilingCoverageOracle inverse transform must be finite"),
            ("oversizedHardRound", "TilingCoverageOracle transformed hard-round dimensions exceed supported diameter"),
            ("oversizedTriangle", "TilingCoverageOracle transformed triangle dimensions exceed supported diameter"),
            ("unrepresentableWorldBounds", "TilingCoverageOracle world sample bounds must be Int-representable"),
            ("comparisonSize", "Coverage comparison requires equal pixel sizes"),
            ("boundaryTolerance", "Coverage comparison boundary tolerance must be 0 or 1"),
        ]

        for (validationCase, expectedMessage) in invalidCases {
            let result = try runOracleValidationSubprocess(
                for: validationCase
            )
            #expect(result.status != 0, "\(validationCase)")
            #expect(
                result.standardError.contains(
                    "Precondition failed: \(expectedMessage)"
                ),
                "\(validationCase): \(result.standardError)"
            )
        }

        for survivor in [
            "uniformSmallScale",
            "uniformSubnormalScale",
            "rotationalUniformSubnormalScale",
            "rotatedMaximumFootprint",
        ] {
            let result = try runOracleValidationSubprocess(for: survivor)
            #expect(
                result.status == 0,
                "\(survivor): \(result.standardError)"
            )
        }
    }
}

private struct DirectFoldProbe {
    let name: String
    let tiling: TilingKind
    let worldCenter: SIMD2<Float>
    let expectedPixels: Set<PixelCoordinate>
}

private struct PixelCoordinate: Hashable {
    let x: Int
    let y: Int
}

private struct OraclePropertyCase {
    let name: String
    let footprint: OracleFootprint
    let brushToWorld: Affine2D
    let tileSize: PixelSize
    let tiling: TilingKind
    let supersampling: Int
}

private struct CompiledDescriptorParityCase {
    let oracleCase: OraclePropertyCase
    let failureContext: String
}

private struct ParityTransform {
    let name: String
    let make: (SIMD2<Float>) -> Affine2D
}

private struct ParityCenter {
    let name: String
    let resolve: (PixelSize) -> SIMD2<Float>
}

private let compiledDescriptorParityMatrix: [CompiledDescriptorParityCase] = {
    let sizes = [
        ("square", PixelSize(width: 64, height: 64)),
        ("rectangular", PixelSize(width: 64, height: 96)),
    ]
    let transforms = [
        ParityTransform(name: "identity") { _ in
            Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                translation: .zero
            )
        },
        ParityTransform(name: "translated") {
            Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                translation: $0
            )
        },
        ParityTransform(name: "rotated-90") {
            Affine2D(
                xAxis: SIMD2(0, 1),
                yAxis: SIMD2(-1, 0),
                translation: $0
            )
        },
        ParityTransform(name: "reflected-x") {
            Affine2D(
                xAxis: SIMD2(-1, 0),
                yAxis: SIMD2(0, 1),
                translation: $0
            )
        },
        ParityTransform(name: "sheared-x") {
            Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0.5, 1),
                translation: $0
            )
        },
    ]
    let centres = [
        ParityCenter(name: "base-cell") { _ in SIMD2(20, 30) },
        ParityCenter(name: "positive-odd-cell") {
            SIMD2(Float($0.width + 20), Float($0.height + 30))
        },
        ParityCenter(name: "negative-odd-cell") {
            SIMD2(Float(-$0.width + 20), Float(-$0.height + 30))
        },
        ParityCenter(name: "exact-right-boundary") {
            SIMD2(Float($0.width), 30)
        },
        ParityCenter(name: "exact-bottom-boundary") {
            SIMD2(20, Float($0.height))
        },
        ParityCenter(name: "seam") { _ in SIMD2(0, 30) },
        ParityCenter(name: "corner") {
            SIMD2(Float($0.width), Float($0.height))
        },
        ParityCenter(name: "large-representable-cell") {
            SIMD2(
                Float($0.width * 10_000 + 20),
                Float(-$0.height * 9_001 + 30)
            )
        },
    ]
    let footprints: [(name: String, footprint: OracleFootprint)] = [
        ("hard-round", .hardRound(radius: 5)),
        ("asymmetric-triangle", .asymmetricTriangle),
    ]
    let supersamplingValues = [1, 2, 4]
    var cases: [CompiledDescriptorParityCase] = []
    var centreIndex = 0

    let legacyAndSquarePresets = SymmetryPresetID.allCases.filter {
        $0.rawValue <= SymmetryPresetID.squareKaleidoscope.rawValue
    }
    for preset in legacyAndSquarePresets {
        for (sizeName, size) in sizes {
            for transform in transforms {
                for footprint in footprints {
                    for supersampling in supersamplingValues {
                        let centre: ParityCenter
                        if transform.name == "identity" {
                            centre = centres[6]
                        } else {
                            centre = centres[centreIndex % centres.count]
                            centreIndex += 1
                        }
                        let brushToWorld = transform.make(
                            centre.resolve(size)
                        )
                        let context = [
                            "preset=\(preset)",
                            "size=\(sizeName)-\(size.width)x\(size.height)",
                            "transform=\(transform.name)",
                            "footprint=\(footprint.name)",
                            "supersampling=\(supersampling)",
                            "centre=\(centre.name)",
                        ].joined(separator: " ")
                        cases.append(
                            CompiledDescriptorParityCase(
                                oracleCase: OraclePropertyCase(
                                    name: context,
                                    footprint: footprint.footprint,
                                    brushToWorld: brushToWorld,
                                    tileSize: size,
                                    tiling: preset,
                                    supersampling: supersampling
                                ),
                                failureContext: context
                            )
                        )
                    }
                }
            }
        }
    }
    return cases
}()

private let oraclePropertyMatrix: [OraclePropertyCase] = [
    OraclePropertyCase(
        name: "grid interior",
        footprint: .hardRound(radius: 5),
        brushToWorld: unitTransform(center: SIMD2(20.13, 30.21)),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .grid,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "grid asymmetric edge",
        footprint: .asymmetricTriangle,
        brushToWorld: scaledTransform(scale: 7, center: SIMD2(1.37, 41.19)),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .grid,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "rotated hard-round",
        footprint: .hardRound(radius: 6),
        brushToWorld: Affine2D(
            xAxis: SIMD2(0.8, 0.6),
            yAxis: SIMD2(-0.6, 0.8),
            translation: SIMD2(62.17, 40.31)
        ),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .grid,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "half-drop hard edge",
        footprint: .hardRound(radius: 6),
        brushToWorld: unitTransform(center: SIMD2(64.23, 48.37)),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .halfDrop,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "half-drop asymmetric corner",
        footprint: .asymmetricTriangle,
        brushToWorld: Affine2D(
            xAxis: SIMD2(5.6, 4.2),
            yAxis: SIMD2(-3.6, 4.8),
            translation: SIMD2(64.27, 96.33)
        ),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .halfDrop,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "brick hard corner",
        footprint: .hardRound(radius: 7),
        brushToWorld: unitTransform(center: SIMD2(32.29, 96.17)),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .brick,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "mirror-x asymmetric edge",
        footprint: .asymmetricTriangle,
        brushToWorld: scaledTransform(scale: 8, center: SIMD2(64.31, 30.23)),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .mirrorX,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "mirror-y asymmetric edge",
        footprint: .asymmetricTriangle,
        brushToWorld: scaledTransform(scale: 8, center: SIMD2(20.19, 96.27)),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .mirrorY,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "mirror-xy asymmetric corner",
        footprint: .asymmetricTriangle,
        brushToWorld: scaledTransform(scale: 8, center: SIMD2(64.21, 96.29)),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .mirrorXY,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "rotational asymmetric noncentral",
        footprint: .asymmetricTriangle,
        brushToWorld: Affine2D(
            xAxis: SIMD2(6.4, 4.8),
            yAxis: SIMD2(-4.2, 5.6),
            translation: SIMD2(12.31, 20.27)
        ),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .rotational,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "reflected hard-round transform",
        footprint: .hardRound(radius: 5),
        brushToWorld: Affine2D(
            xAxis: SIMD2(-1, 0),
            yAxis: SIMD2(0, 1),
            translation: SIMD2(40.17, 50.29)
        ),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .mirrorXY,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "large signed noncentral coordinate",
        footprint: .hardRound(radius: 5),
        brushToWorld: unitTransform(
            center: SIMD2(2_386.13, -2_750.79)
        ),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .halfDrop,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "maximum large footprint",
        footprint: .hardRound(radius: 256),
        brushToWorld: unitTransform(center: SIMD2(0.13, 0.21)),
        tileSize: PixelSize(width: 64, height: 96),
        tiling: .grid,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "transposed rectangular tile",
        footprint: .hardRound(radius: 7),
        brushToWorld: unitTransform(center: SIMD2(94.31, 62.27)),
        tileSize: PixelSize(width: 96, height: 64),
        tiling: .brick,
        supersampling: 2
    ),
    OraclePropertyCase(
        name: "odd rectangular half-drop phase",
        footprint: .hardRound(radius: 5),
        brushToWorld: unitTransform(center: SIMD2(66.19, 49.23)),
        tileSize: PixelSize(width: 65, height: 97),
        tiling: .halfDrop,
        supersampling: 1
    ),
    OraclePropertyCase(
        name: "odd rectangular brick phase",
        footprint: .asymmetricTriangle,
        brushToWorld: scaledTransform(
            scale: 7,
            center: SIMD2(49.17, 66.21)
        ),
        tileSize: PixelSize(width: 97, height: 65),
        tiling: .brick,
        supersampling: 3
    ),
]

private func renderPointProbe(
    center: SIMD2<Float>,
    tileSize: PixelSize,
    tiling: TilingKind
) -> OracleRasterResult {
    TilingCoverageOracle.renderCanonical(
        footprint: .hardRound(radius: 1),
        brushToWorld: pointProbeTransform(at: center),
        tileSize: tileSize,
        tiling: tiling,
        supersampling: 1
    )
}

private func pointProbeTransform(at center: SIMD2<Float>) -> Affine2D {
    Affine2D(
        xAxis: SIMD2(0.25, 0),
        yAxis: SIMD2(0, 0.25),
        translation: center
    )
}

private func unitTransform(center: SIMD2<Float>) -> Affine2D {
    Affine2D(
        xAxis: SIMD2(1, 0),
        yAxis: SIMD2(0, 1),
        translation: center
    )
}

private func scaledTransform(
    scale: Float,
    center: SIMD2<Float>
) -> Affine2D {
    Affine2D(
        xAxis: SIMD2(scale, 0),
        yAxis: SIMD2(0, scale),
        translation: center
    )
}

private func fullyCoveredPixels(
    in coverage: OracleCoverage
) -> Set<PixelCoordinate> {
    Set(coverage.bytes.indices.compactMap { index in
        guard coverage.bytes[index] == 255 else {
            return nil
        }
        return PixelCoordinate(
            x: index % coverage.pixelSize.width,
            y: index / coverage.pixelSize.width
        )
    })
}

private func rasterizeProductionFragments(
    _ testCase: OraclePropertyCase,
    fragments: [CellFragment]? = nil
) -> OracleRasterResult {
    let resolvedFragments = fragments ?? productionFragments(for: testCase)
    let inverseFragments = resolvedFragments.map {
        ProductionFragmentSample(
            canonicalToBrush: $0.canonicalFromBrush.inverted(),
            brushClip: $0.brushClip
        )
    }
    let width = testCase.tileSize.width
    let height = testCase.tileSize.height
    let sampleCount = testCase.supersampling * testCase.supersampling
    var coverage = [UInt8](repeating: 0, count: width * height)
    var canonicalBGRA = [UInt8](repeating: 0, count: width * height * 4)
    var brushBGRA = [UInt8](repeating: 0, count: width * height * 4)

    for pixelY in 0..<height {
        for pixelX in 0..<width {
            var coveredSamples = 0
            var canonicalRedSum = 0
            var canonicalGreenSum = 0
            var brushRedSum = 0
            var brushGreenSum = 0

            for subY in 0..<testCase.supersampling {
                for subX in 0..<testCase.supersampling {
                    let canonical = SIMD2<Float>(
                        Float(pixelX)
                            + (Float(subX) + 0.5)
                                / Float(testCase.supersampling),
                        Float(pixelY)
                            + (Float(subY) + 0.5)
                                / Float(testCase.supersampling)
                    )
                    var owningBrushPoint: SIMD2<Float>?
                    for fragment in inverseFragments {
                        let brushPoint = fragment.canonicalToBrush.applying(
                            to: canonical
                        )
                        if
                            fragment.brushClip.contains(
                                brushPoint,
                                tolerance: 0
                            ),
                            productionContains(
                                brushPoint,
                                footprint: testCase.footprint
                            )
                        {
                            owningBrushPoint = brushPoint
                        }
                    }
                    guard let brushPoint = owningBrushPoint else {
                        continue
                    }

                    coveredSamples += 1
                    canonicalRedSum += Int(
                        encodeUnitCoordinate(
                            canonical.x / Float(width)
                        )
                    )
                    canonicalGreenSum += Int(
                        encodeUnitCoordinate(
                            canonical.y / Float(height)
                        )
                    )
                    brushRedSum += Int(
                        encodeSignedCoordinate(brushPoint.x)
                    )
                    brushGreenSum += Int(
                        encodeSignedCoordinate(brushPoint.y)
                    )
                }
            }

            let pixelIndex = pixelY * width + pixelX
            let byteOffset = pixelIndex * 4
            let alpha = averagedByte(
                sum: coveredSamples * 255,
                divisor: sampleCount
            )
            coverage[pixelIndex] = alpha
            canonicalBGRA[byteOffset + 1] = averagedByte(
                sum: canonicalGreenSum,
                divisor: sampleCount
            )
            canonicalBGRA[byteOffset + 2] = averagedByte(
                sum: canonicalRedSum,
                divisor: sampleCount
            )
            canonicalBGRA[byteOffset + 3] = alpha
            brushBGRA[byteOffset + 1] = averagedByte(
                sum: brushGreenSum,
                divisor: sampleCount
            )
            brushBGRA[byteOffset + 2] = averagedByte(
                sum: brushRedSum,
                divisor: sampleCount
            )
            brushBGRA[byteOffset + 3] = alpha
        }
    }

    return OracleRasterResult(
        coverage: OracleCoverage(
            pixelSize: testCase.tileSize,
            bytes: coverage
        ),
        canonicalCoordinatesBGRA: canonicalBGRA,
        brushLocalCoordinatesBGRA: brushBGRA
    )
}

private func productionFragments(
    for testCase: OraclePropertyCase
) -> [CellFragment] {
    let setup = productionFootprint(for: testCase)
    let strategy = TilingStrategy(
        kind: testCase.tiling,
        tileSize: PatternSize(
            width: Float(testCase.tileSize.width),
            height: Float(testCase.tileSize.height)
        )
    )
    return TilingProjection.fragments(
        for: setup.footprint,
        using: strategy
    )
}

private func diagnosticPixel(
    _ bytes: [UInt8],
    x: Int,
    y: Int,
    width: Int
) -> [UInt8] {
    let offset = (y * width + x) * 4
    return Array(bytes[offset..<(offset + 4)])
}

private struct ProductionFragmentSample {
    let canonicalToBrush: Affine2D
    let brushClip: ConvexClip
}

private struct ProductionFootprintSetup {
    let footprint: StampFootprint
}

private func productionFootprint(
    for testCase: OraclePropertyCase
) -> ProductionFootprintSetup {
    switch testCase.footprint {
    case let .hardRound(radius):
        return ProductionFootprintSetup(
            footprint: StampFootprint(
                brushToWorld: Affine2D(
                    xAxis: testCase.brushToWorld.xAxis * radius,
                    yAxis: testCase.brushToWorld.yAxis * radius,
                    translation: testCase.brushToWorld.translation
                ),
                localBounds: AxisAlignedRect(
                    minimum: SIMD2(-1, -1),
                    maximum: SIMD2(1, 1)
                ),
                coverageSymmetry: .halfTurnInvariant
            )
        )
    case .asymmetricTriangle:
        return ProductionFootprintSetup(
            footprint: StampFootprint(
                brushToWorld: testCase.brushToWorld,
                localBounds: AxisAlignedRect(
                    minimum: SIMD2(-0.75, -0.60),
                    maximum: SIMD2(0.85, 0.90)
                ),
                coverageSymmetry: .oriented
            )
        )
    }
}

private func productionContains(
    _ brushPoint: SIMD2<Float>,
    footprint: OracleFootprint
) -> Bool {
    switch footprint {
    case .hardRound:
        return simd_dot(brushPoint, brushPoint) <= 1
    case .asymmetricTriangle:
        let vertices = [
            SIMD2<Float>(-0.75, -0.60),
            SIMD2<Float>(0.85, -0.20),
            SIMD2<Float>(-0.10, 0.90),
        ]
        return zip(vertices, vertices.dropFirst() + [vertices[0]])
            .allSatisfy { start, end in
                let edge = end - start
                let point = brushPoint - start
                return edge.x * point.y - edge.y * point.x >= 0
            }
    }
}

private func encodeUnitCoordinate(_ value: Float) -> UInt8 {
    UInt8(
        max(0, min(255, Int((value * 255).rounded())))
    )
}

private func encodeSignedCoordinate(_ value: Float) -> UInt8 {
    encodeUnitCoordinate(value * 0.5 + 0.5)
}

private func averagedByte(sum: Int, divisor: Int) -> UInt8 {
    UInt8((sum + divisor / 2) / divisor)
}

private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func maximumByteDelta(
    _ lhs: [UInt8],
    _ rhs: [UInt8]
) -> UInt8 {
    precondition(lhs.count == rhs.count)
    return zip(lhs, rhs).reduce(UInt8(0)) { maximum, pair in
        max(
            maximum,
            UInt8(abs(Int(pair.0) - Int(pair.1)))
        )
    }
}

private func runOracleValidationSubprocess(
    for validationCase: String
) throws -> (status: Int32, standardError: String) {
    let testExecutablePath = oracleTestExecutablePath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
        "--test-bundle-path", testExecutablePath,
        "--filter", "invalidSizesCountsSamplingAndToleranceFailFast",
        testExecutablePath,
        "--testing-library", "swift-testing",
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["PATTERN_ENGINE_ORACLE_VALIDATION_CASE": validationCase],
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

private func exerciseOracleValidation(named validationCase: String) {
    let validSize = PixelSize(width: 64, height: 96)
    let validCoverage = OracleCoverage(
        pixelSize: validSize,
        bytes: [UInt8](repeating: 0, count: 64 * 96)
    )

    switch validationCase {
    case "coverageByteCount":
        _ = OracleCoverage(pixelSize: validSize, bytes: [])
    case "coverageAreaOverflow":
        _ = OracleCoverage(
            pixelSize: PixelSize(width: Int.max, height: 2),
            bytes: []
        )
    case "canonicalByteCount":
        _ = OracleRasterResult(
            coverage: validCoverage,
            canonicalCoordinatesBGRA: [],
            brushLocalCoordinatesBGRA: [UInt8](
                repeating: 0,
                count: 64 * 96 * 4
            )
        )
    case "brushLocalByteCount":
        _ = OracleRasterResult(
            coverage: validCoverage,
            canonicalCoordinatesBGRA: [UInt8](
                repeating: 0,
                count: 64 * 96 * 4
            ),
            brushLocalCoordinatesBGRA: []
        )
    case "tileTooSmall":
        _ = validatedOracleRender(
            tileSize: PixelSize(width: 63, height: 96)
        )
    case "tileTooLarge":
        _ = validatedOracleRender(
            tileSize: PixelSize(width: 64, height: 4_097)
        )
    case "supersamplingZero":
        _ = validatedOracleRender(supersampling: 0)
    case "supersamplingTooLarge":
        _ = validatedOracleRender(supersampling: 9)
    case "radiusTooSmall":
        _ = validatedOracleRender(footprint: .hardRound(radius: 0.99))
    case "radiusTooLarge":
        _ = validatedOracleRender(footprint: .hardRound(radius: 257))
    case "singularTransform":
        _ = validatedOracleRender(
            brushToWorld: Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(2, 0),
                translation: SIMD2(0, 0)
            )
        )
    case "illConditionedTransform":
        _ = validatedOracleRender(
            brushToWorld: Affine2D(
                xAxis: SIMD2(256, 256),
                yAxis: SIMD2(0, 2.9802322e-8),
                translation: SIMD2(32, 48)
            )
        )
    case "nonfiniteInverse":
        _ = validatedOracleRender(
            brushToWorld: Affine2D(
                xAxis: SIMD2(Float.leastNonzeroMagnitude, 0),
                yAxis: SIMD2(0, Float.leastNonzeroMagnitude),
                translation: SIMD2(32, 48)
            )
        )
    case "oversizedHardRound":
        _ = validatedOracleRender(
            footprint: .hardRound(radius: 1),
            brushToWorld: Affine2D(
                xAxis: SIMD2(300, 0),
                yAxis: SIMD2(0, 300),
                translation: SIMD2(32, 48)
            )
        )
    case "oversizedTriangle":
        _ = validatedOracleRender(
            footprint: .asymmetricTriangle,
            brushToWorld: Affine2D(
                xAxis: SIMD2(400, 0),
                yAxis: SIMD2(0, 400),
                translation: SIMD2(32, 48)
            )
        )
    case "unrepresentableWorldBounds":
        _ = validatedOracleRender(
            brushToWorld: Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                translation: SIMD2(
                    Float.greatestFiniteMagnitude,
                    Float.greatestFiniteMagnitude
                )
            )
        )
    case "uniformSmallScale":
        let result = validatedOracleRender(
            brushToWorld: Affine2D(
                xAxis: SIMD2(0.0001, 0),
                yAxis: SIMD2(0, 0.0001),
                translation: SIMD2(32.5, 48.5)
            )
        )
        precondition(
            result.coverage.bytes.reduce(0, { $0 + Int($1) }) == 255,
            "Uniform small scale must cover exactly one sample"
        )
        let offset = (48 * 64 + 32) * 4
        precondition(
            Array(result.brushLocalCoordinatesBGRA[offset..<(offset + 4)])
                == [0, 128, 128, 255],
            "Uniform small scale must preserve exact brush diagnostics"
        )
    case "uniformSubnormalScale":
        let result = validatedOracleRender(
            brushToWorld: Affine2D(
                xAxis: SIMD2(1e-30, 0),
                yAxis: SIMD2(0, 1e-30),
                translation: SIMD2(0.5, 0.5)
            )
        )
        precondition(
            result.coverage.bytes.reduce(0, { $0 + Int($1) }) == 255,
            "Uniform subnormal scale must cover exactly one sample"
        )
        precondition(
            diagnosticPixel(
                result.brushLocalCoordinatesBGRA,
                x: 0,
                y: 0,
                width: validSize.width
            ) == [0, 128, 128, 255],
            "Uniform subnormal scale must preserve finite diagnostics"
        )
    case "rotationalUniformSubnormalScale":
        let result = validatedOracleRender(
            brushToWorld: Affine2D(
                xAxis: SIMD2(1e-30, 0),
                yAxis: SIMD2(0, 1e-30),
                translation: SIMD2(0.5, 0.5)
            ),
            tiling: .rotational
        )
        precondition(
            result.coverage.bytes.reduce(0, { $0 + Int($1) }) == 510,
            "Rotational subnormal scale must cover two p2 samples"
        )
        precondition(
            diagnosticPixel(
                result.brushLocalCoordinatesBGRA,
                x: 0,
                y: 0,
                width: validSize.width
            ) == [0, 128, 128, 255],
            "Rotational subnormal scale must preserve identity diagnostics"
        )
        precondition(
            diagnosticPixel(
                result.brushLocalCoordinatesBGRA,
                x: 63,
                y: 95,
                width: validSize.width
            ) == [0, 128, 128, 255],
            "Rotational subnormal scale must preserve half-turn diagnostics"
        )
    case "rotatedMaximumFootprint":
        let diagonal = Float(0.5).squareRoot()
        let result = validatedOracleRender(
            footprint: .hardRound(radius: 256),
            brushToWorld: Affine2D(
                xAxis: SIMD2(diagonal, diagonal),
                yAxis: SIMD2(-diagonal, diagonal),
                translation: SIMD2(0, 0)
            ),
            tileSize: PixelSize(width: 64, height: 64)
        )
        precondition(
            result.coverage.bytes.allSatisfy { $0 == 255 },
            "Maximum rotated footprint must cover the canonical tile"
        )
    case "comparisonSize":
        _ = TilingCoverageOracle.compare(
            expected: validCoverage,
            actual: OracleCoverage(
                pixelSize: PixelSize(width: 64, height: 64),
                bytes: [UInt8](repeating: 0, count: 64 * 64)
            ),
            boundaryTolerance: 0
        )
    case "boundaryTolerance":
        _ = TilingCoverageOracle.compare(
            expected: validCoverage,
            actual: validCoverage,
            boundaryTolerance: 2
        )
    default:
        preconditionFailure(
            "Unknown oracle validation case: \(validationCase)"
        )
    }
}

private func validatedOracleRender(
    footprint: OracleFootprint = .hardRound(radius: 1),
    brushToWorld: Affine2D = .identity,
    tileSize: PixelSize = PixelSize(width: 64, height: 96),
    tiling: TilingKind = .grid,
    supersampling: Int = 1
) -> OracleRasterResult {
    TilingCoverageOracle.renderCanonical(
        footprint: footprint,
        brushToWorld: brushToWorld,
        tileSize: tileSize,
        tiling: tiling,
        supersampling: supersampling
    )
}

private func oracleTestExecutablePath() -> String {
    guard
        let optionIndex = CommandLine.arguments.firstIndex(
            of: "--test-bundle-path"
        ),
        CommandLine.arguments.indices.contains(optionIndex + 1)
    else {
        preconditionFailure("Swift Testing test executable path is unavailable")
    }
    return CommandLine.arguments[optionIndex + 1]
}
