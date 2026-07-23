import Foundation
@testable import PatternEngine
import simd
import Testing

private let legacySymmetryPresetIDs: [SymmetryPresetID] = [
    .grid,
    .halfDrop,
    .brick,
    .mirrorX,
    .mirrorY,
    .mirrorXY,
    .rotational,
]

@Suite("Symmetry descriptor compiler")
struct SymmetryDescriptorCompilerTests {
    @Test
    func stableSelectorsAreAppendOnlyAndLegacyCompatible() throws {
        #expect(SymmetryDocumentDomainID.periodic.rawValue == 0)
        #expect(SymmetryDocumentDomainID.finite.rawValue == 1)
        #expect(SymmetryKernelFamily.rectangular.rawValue == 0)
        #expect(SymmetryKernelFamily.triangular.rawValue == 1)
        #expect(SymmetryKernelFamily.radial.rawValue == 2)
        #expect(
            legacySymmetryPresetIDs.map(\.rawValue)
                == Array(0...6).map(UInt32.init)
        )
        #expect(SymmetryPresetID.squareRotation.rawValue == 7)
        #expect(SymmetryPresetID.squareKaleidoscope.rawValue == 8)
        #expect(SymmetryPresetID.hexagons.rawValue == 9)
        #expect(SymmetryPresetID.rotation3.rawValue == 10)
        #expect(SymmetryPresetID.rotation6.rawValue == 11)
        #expect(SymmetryPresetID.kaleidoscope60.rawValue == 12)
        #expect(SymmetryPresetID.kaleidoscope30.rawValue == 13)
        #expect(
            SymmetryPresetID.allCases.map(\.rawValue)
                == Array(0...13).map(UInt32.init)
        )
        #expect(TilingKind.rotational.rawValue == 6)

        let encoded = try JSONEncoder().encode(SymmetryPresetID.mirrorXY)
        #expect(String(decoding: encoded, as: UTF8.self) == "5")
        #expect(
            try JSONDecoder().decode(
                SymmetryPresetID.self,
                from: Data("5".utf8)
            ) == .mirrorXY
        )
    }

    @Test(arguments: legacySymmetryPresetIDs)
    func everyLegacyPresetCompilesClosedRectangularData(
        _ presetID: SymmetryPresetID
    ) throws {
        let compiled = try SymmetryDescriptorCompiler.compile(
            presetID: presetID,
            tileSize: PatternSize(width: 128, height: 192)
        )

        #expect(compiled.presetID == presetID)
        #expect(compiled.domain.periodic != nil)
        #expect(compiled.family == .rectangular)
        #expect(compiled.ownership == .rectangularHalfOpen)
        #expect(compiled.rasterMetric == .identity)
        #expect(compiled.exportCapability == .rectangularRepeat)
        #expect(compiled.displayProgram.family == .rectangular)
        #expect(compiled.displayProgram.presetWireID == presetID.rawValue)
        #expect(compiled.cost.maximumImagesPerCell == compiled.images.count)
        #expect(
            compiled.cost.maximumProjectedInstancesPerDab
                <= TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity
        )
        #expect(!compiled.images.isEmpty)
        #expect(
            compiled.domain.periodic?.translationBasis
                == PeriodicTranslationBasis(
                    origin: .zero,
                    u: SIMD2(128, 0),
                    v: SIMD2(0, 192)
                )
        )
    }

    @Test
    func legacyPhaseReflectionAndRotationProgramsAreExact() throws {
        let size = PatternSize(width: 128, height: 192)
        let grid = try SymmetryDescriptorCompiler.compile(presetID: .grid, tileSize: size)
        let halfDrop = try SymmetryDescriptorCompiler.compile(presetID: .halfDrop, tileSize: size)
        let brick = try SymmetryDescriptorCompiler.compile(presetID: .brick, tileSize: size)
        let mirrorX = try SymmetryDescriptorCompiler.compile(presetID: .mirrorX, tileSize: size)
        let mirrorY = try SymmetryDescriptorCompiler.compile(presetID: .mirrorY, tileSize: size)
        let mirrorXY = try SymmetryDescriptorCompiler.compile(presetID: .mirrorXY, tileSize: size)
        let rotational = try SymmetryDescriptorCompiler.compile(presetID: .rotational, tileSize: size)

        #expect(grid.domain.periodic?.phase == nil)
        #expect(halfDrop.domain.periodic?.phase == PeriodicPhaseProgram(indexAxis: .x, offsetAxis: .y, fractions: [0, 0.5]))
        #expect(brick.domain.periodic?.phase == PeriodicPhaseProgram(indexAxis: .y, offsetAxis: .x, fractions: [0, 0.5]))
        #expect(mirrorX.domain.periodic?.alternatingReflections == [.x])
        #expect(mirrorY.domain.periodic?.alternatingReflections == [.y])
        #expect(mirrorXY.domain.periodic?.alternatingReflections == [.x, .y])
        #expect(rotational.images.map(\.ordinal) == [0, 1])
        #expect(rotational.images[1].localToCanonical == Affine2D(xAxis: SIMD2(-1, 0), yAxis: SIMD2(0, -1), translation: size.simd))
        #expect(rotational.domain.periodic?.coincidentImagePolicy == .halfTurnInvariantCoverage)
    }

    @Test
    func validationReturnsTypedDimensionFailures() {
        let cases: [(PatternSize, SymmetryDescriptorError)] = [
            (PatternSize(width: .infinity, height: 64), .nonFiniteDimension(.width)),
            (PatternSize(width: 64, height: .infinity), .nonFiniteDimension(.height)),
            (PatternSize(width: 64.5, height: 64), .nonIntegerDimension(.width)),
            (PatternSize(width: 64, height: 64.5), .nonIntegerDimension(.height)),
            (PatternSize(width: 63, height: 64), .dimensionOutOfRange(.width, value: 63)),
            (PatternSize(width: 64, height: 4_097), .dimensionOutOfRange(.height, value: 4_097)),
        ]

        for (size, expected) in cases {
            #expect(throws: expected) {
                try SymmetryDescriptorCompiler.compile(presetID: .grid, tileSize: size)
            }
        }
    }

    @Test
    func compilerValidatesSquareConfigurationGeometryAndOrientation() throws {
        let legacy = PeriodicSymmetryConfiguration(
            presetID: .grid,
            repeatSize: PatternSize(width: 128, height: 96),
            orientationRadians: 0
        )
        #expect(legacy.presetID == .grid)
        #expect(legacy.repeatSize == PatternSize(width: 128, height: 96))
        #expect(legacy.orientationRadians == 0)
        let compiledLegacy = try SymmetryDescriptorCompiler.compile(
            configuration: legacy,
            canonicalRasterSize: PixelSize(width: 128, height: 96)
        )
        #expect(compiledLegacy.ownership == .rectangularHalfOpen)

        let nonSquare = PeriodicSymmetryConfiguration(
            presetID: .squareRotation,
            repeatSize: PatternSize(width: 128, height: 96),
            orientationRadians: 0
        )
        #expect(throws: SymmetryDescriptorError.nonSquareRepeat(
            width: 128,
            height: 96
        )) {
            try SymmetryDescriptorCompiler.compile(
                configuration: nonSquare,
                canonicalRasterSize: PixelSize(width: 128, height: 96)
            )
        }
        let nonFiniteAngle = PeriodicSymmetryConfiguration(
            presetID: .squareKaleidoscope,
            repeatSize: PatternSize(width: 128, height: 128),
            orientationRadians: .infinity
        )
        #expect(throws: SymmetryDescriptorError.nonFiniteOrientation) {
            try SymmetryDescriptorCompiler.compile(
                configuration: nonFiniteAngle,
                canonicalRasterSize: PixelSize(width: 128, height: 128)
            )
        }
    }

    @Test
    func repeatGeometryAcceptsContinuousWorldDimensionsIndependentOfRaster() throws {
        for side: Float in [96.5, 173.25, 8_192.25] {
            let configuration = PeriodicSymmetryConfiguration(
                presetID: .squareRotation,
                repeatSize: PatternSize(width: side, height: side),
                orientationRadians: .pi / 7
            )
            let compiled = try SymmetryDescriptorCompiler.compile(
                configuration: configuration,
                canonicalRasterSize: PixelSize(width: 128, height: 96)
            )
            #expect(
                compiled.domain.periodic?.configuration.repeatSize
                    == configuration.repeatSize
            )
            #expect(
                compiled.domain.periodic?.configuration.orientationRadians
                    == configuration.orientationRadians
            )
        }

        let nonFinite = PeriodicSymmetryConfiguration(
            presetID: .squareRotation,
            repeatSize: PatternSize(width: .infinity, height: .infinity),
            orientationRadians: 0
        )
        #expect(
            throws: SymmetryDescriptorError.nonFiniteDimension(.width)
        ) {
            try SymmetryDescriptorCompiler.compile(
                configuration: nonFinite,
                canonicalRasterSize: PixelSize(width: 128, height: 96)
            )
        }
    }

    @Test
    func compilerRejectsRepeatGeometryThatExceedsProjectionCapacity() {
        let configuration = PeriodicSymmetryConfiguration(
            presetID: .squareKaleidoscope,
            repeatSize: PatternSize(width: 0.001, height: 0.001),
            orientationRadians: .pi / 7
        )

        do {
            _ = try SymmetryDescriptorCompiler.compile(
                configuration: configuration,
                canonicalRasterSize: PixelSize(width: 128, height: 96)
            )
            Issue.record("Expected unsafe repeat geometry to be rejected")
        } catch let error as SymmetryDescriptorError {
            guard case let .projectionCostExceedsLimit(actual, maximum) =
                error
            else {
                Issue.record("Unexpected compiler error: \(error)")
                return
            }
            #expect(
                actual
                    > TransientStrokeBufferContract
                        .visibleEpochProjectedInstanceCapacity
            )
            #expect(
                maximum
                    == TransientStrokeBufferContract
                        .visibleEpochProjectedInstanceCapacity
            )
        } catch {
            Issue.record("Unexpected compiler error: \(error)")
        }
    }

    @Test
    func compilerCostBoundIncludesWorstCaseRotatedBrushBounds() {
        let configuration = PeriodicSymmetryConfiguration(
            presetID: .squareKaleidoscope,
            repeatSize: PatternSize(width: 37, height: 37),
            orientationRadians: 0
        )

        do {
            _ = try SymmetryDescriptorCompiler.compile(
                configuration: configuration,
                canonicalRasterSize: PixelSize(width: 128, height: 96)
            )
            Issue.record("Expected rotated maximum dab cost rejection")
        } catch let error as SymmetryDescriptorError {
            guard case let .projectionCostExceedsLimit(actual, maximum) =
                error
            else {
                Issue.record("Unexpected compiler error: \(error)")
                return
            }
            #expect(actual == 7_688)
            #expect(
                maximum
                    == TransientStrokeBufferContract
                        .visibleEpochProjectedInstanceCapacity
            )
        } catch {
            Issue.record("Unexpected compiler error: \(error)")
        }
    }

    @Test
    func squarePresetsCompileExactImageTablesOwnershipAndCost() throws {
        let repeatSize = PatternSize(width: 128, height: 128)
        let rasterSize = PixelSize(width: 128, height: 128)
        let squareRotation = try SymmetryDescriptorCompiler.compile(
            configuration: PeriodicSymmetryConfiguration(
                presetID: .squareRotation,
                repeatSize: repeatSize,
                orientationRadians: 0
            ),
            canonicalRasterSize: rasterSize
        )
        let squareKaleidoscope = try SymmetryDescriptorCompiler.compile(
            configuration: PeriodicSymmetryConfiguration(
                presetID: .squareKaleidoscope,
                repeatSize: repeatSize,
                orientationRadians: 0
            ),
            canonicalRasterSize: rasterSize
        )

        let rotations = squareRotationImages(side: 128)
        let reflected = squareReflectedImages(side: 128)
        #expect(squareRotation.family == .rectangular)
        #expect(squareRotation.images == rotations)
        #expect(squareRotation.cost.maximumImagesPerCell == 4)
        guard case let .squareRotation(sectors, rotationStabilizers) =
            squareRotation.ownership
        else {
            Issue.record("Square Rotation must compile square-sector ownership")
            return
        }
        #expect(sectors.count == 4)
        #expect(sectors.map(\.ownerOrdinal) == Array(0..<4).map(UInt8.init))
        #expect(sectors.allSatisfy {
            $0.canonicalVertices.count == 3
                && abs(signedArea($0.canonicalVertices) - 4_096) < 0.001
        })
        #expect(rotationStabilizers.contains {
            $0.canonicalPoint == SIMD2<Float>(64, 64)
                && $0.kind == .rotation(order: 4)
        })

        #expect(squareKaleidoscope.family == .rectangular)
        #expect(squareKaleidoscope.images == rotations + reflected)
        #expect(squareKaleidoscope.cost.maximumImagesPerCell == 8)
        guard case let .squareMirrorTriangles(
            triangles,
            reflectionStabilizers
        ) = squareKaleidoscope.ownership else {
            Issue.record(
                "Square Kaleidoscope must compile mirror-triangle ownership"
            )
            return
        }
        #expect(triangles.count == 8)
        #expect(
            triangles.map(\.ownerOrdinal)
                == Array(0..<8).map(UInt8.init)
        )
        #expect(
            triangles.allSatisfy {
                $0.canonicalVertices.count == 3
                    && abs(signedArea($0.canonicalVertices) - 2_048) < 0.001
            }
        )
        #expect(reflectionStabilizers.contains {
            $0.canonicalPoint == SIMD2<Float>(64, 64)
                && $0.kind == .dihedral(rotationOrder: 4)
        })

        let center = SIMD2<Float>(64, 64)
        #expect(
            squareRotation.images.filter {
                $0.localToCanonical.applying(to: center) == center
            }.count == 4
        )
        #expect(
            squareKaleidoscope.images.filter {
                $0.localToCanonical.applying(to: center) == center
            }.count == 8
        )
    }

    @Test
    func squareRasterMetricMapsSquareWorldRepeatIntoRectangularStorage() throws {
        let compiled = try SymmetryDescriptorCompiler.compile(
            configuration: PeriodicSymmetryConfiguration(
                presetID: .squareRotation,
                repeatSize: PatternSize(width: 128, height: 128),
                orientationRadians: 0
            ),
            canonicalRasterSize: PixelSize(width: 192, height: 128)
        )

        #expect(compiled.rasterMetric.worldToRaster == Affine2D(
            xAxis: SIMD2(1.5, 0),
            yAxis: SIMD2(0, 1),
            translation: .zero
        ))
        #expect(
            simd_distance(
                compiled.rasterMetric.rasterToWorld.xAxis,
                SIMD2<Float>(2 / 3, 0)
            ) < 0.000_001
        )
        #expect(compiled.rasterMetric.rasterToWorld.yAxis == SIMD2(0, 1))
    }

    @Test
    func squareDihedralImagesAreClosedInvertibleAndPreserveTheSquareLattice()
        throws
    {
        let compiled = try SymmetryDescriptorCompiler.compile(
            configuration: PeriodicSymmetryConfiguration(
                presetID: .squareKaleidoscope,
                repeatSize: PatternSize(width: 173.5, height: 173.5),
                orientationRadians: .pi / 7
            ),
            canonicalRasterSize: PixelSize(width: 192, height: 128)
        )
        let probes = [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(37, 19),
            SIMD2<Float>(192, 128),
        ]

        for image in compiled.images {
            let transform = image.localToCanonical
            let determinant = transform.xAxis.x * transform.yAxis.y
                - transform.xAxis.y * transform.yAxis.x
            #expect(
                abs(determinant - (image.operation.reflected ? -1 : 1))
                    < 0.000_001
            )
            let inverse = transform.inverted()
            #expect(compiled.images.contains {
                affinesAgree(
                    transform.concatenating(
                        $0.localToCanonical
                    ),
                    .identity,
                    probes: probes
                )
            })
            #expect(
                affinesAgree(
                    transform.concatenating(inverse),
                    .identity,
                    probes: probes
                )
            )
        }

        for lhs in compiled.images {
            for rhs in compiled.images {
                let product = lhs.localToCanonical.concatenating(
                    rhs.localToCanonical
                )
                #expect(compiled.images.contains {
                    affinesAgree(
                        product,
                        $0.localToCanonical,
                        probes: probes
                    )
                })
            }
        }

        let basis = compiled.domain.periodic!.translationBasis
        #expect(abs(simd_length(basis.u) - 173.5) < 0.000_1)
        #expect(abs(simd_length(basis.v) - 173.5) < 0.000_1)
        #expect(abs(simd_dot(basis.u, basis.v)) < 0.002)
        #expect(
            abs(
                basis.u.x * basis.v.y - basis.u.y * basis.v.x
                    - 173.5 * 173.5
            ) < 0.01
        )
    }

    @Test
    func triangularPresetsCompileExactSupercellPrograms() throws {
        let expectations: [(
            preset: SymmetryPresetID,
            images: Int,
            guide: CompiledGuideKind,
            stabilizers: Int
        )] = [
            (.hexagons, 2, .hexagons, 0),
            (.rotation3, 6, .triangularRotation3, 6),
            (.rotation6, 12, .triangularRotation6, 12),
            (.kaleidoscope60, 12, .triangularKaleidoscope60, 6),
            (.kaleidoscope30, 24, .triangularKaleidoscope30, 12),
        ]

        for expected in expectations {
            let compiled = try SymmetryDescriptorCompiler.compile(
                configuration: PeriodicSymmetryConfiguration(
                    presetID: expected.preset,
                    repeatSize: PatternSize(width: 256, height: 256),
                    orientationRadians: .pi / 7
                ),
                canonicalRasterSize: PixelSize(width: 192, height: 128)
            )
            #expect(compiled.family == .triangular)
            #expect(compiled.displayProgram.family == .triangular)
            #expect(compiled.displayProgram.guideKind == expected.guide)
            #expect(compiled.images.count == expected.images)
            #expect(compiled.images.map(\.ordinal)
                == Array(0..<expected.images).map(UInt8.init))
            #expect(compiled.cost.maximumImagesPerCell == expected.images)
            guard case let .triangularDomains(
                triangles,
                stabilizers
            ) = compiled.ownership else {
                Issue.record(
                    "\(expected.preset) must compile triangular ownership"
                )
                continue
            }
            #expect(triangles.count == 24)
            #expect(stabilizers.count == expected.stabilizers)
            #expect(triangles.allSatisfy {
                Int($0.ownerOrdinal) < expected.images
                    && $0.canonicalVertices.count == 3
            })
            let coveredArea = triangles.reduce(Float.zero) {
                $0 + abs(signedArea($1.canonicalVertices))
            }
            #expect(abs(coveredArea - 192 * 128) < 0.1)

            let basis = compiled.domain.periodic!.translationBasis
            #expect(abs(simd_length(basis.u) - 256) < 0.001)
            #expect(
                abs(simd_length(basis.v) - sqrt(3) * 256) < 0.001
            )
            #expect(abs(simd_dot(basis.u, basis.v)) < 0.02)
            #expect(
                simd_distance(
                    compiled.rasterMetric.worldToRaster.applying(
                        to: basis.u
                    ),
                    SIMD2<Float>(192, 0)
                ) < 0.001
            )
            #expect(
                simd_distance(
                    compiled.rasterMetric.worldToRaster.applying(
                        to: basis.v
                    ),
                    SIMD2<Float>(0, 128)
                ) < 0.001
            )
        }
    }

    @Test
    func triangularImageTablesAreClosedModuloRectangularSupercell() throws {
        for preset in [
            SymmetryPresetID.hexagons,
            .rotation3,
            .rotation6,
            .kaleidoscope60,
            .kaleidoscope30,
        ] {
            let compiled = try SymmetryDescriptorCompiler.compile(
                configuration: PeriodicSymmetryConfiguration(
                    presetID: preset,
                    repeatSize: PatternSize(width: 256, height: 256),
                    orientationRadians: -.pi / 9
                ),
                canonicalRasterSize: PixelSize(width: 192, height: 128)
            )
            for image in compiled.images {
                let determinant =
                    image.localToCanonical.xAxis.x
                        * image.localToCanonical.yAxis.y
                    - image.localToCanonical.xAxis.y
                        * image.localToCanonical.yAxis.x
                #expect(
                    abs(
                        determinant
                            - (image.operation.reflected ? -1 : 1)
                    ) < 0.000_01
                )
                #expect(compiled.images.contains {
                    affinesAgreeModuloSupercell(
                        image.localToCanonical.concatenating(
                            $0.localToCanonical
                        ),
                        .identity,
                        size: PatternSize(width: 192, height: 128)
                    )
                })
            }
            for lhs in compiled.images {
                for rhs in compiled.images {
                    let product = lhs.localToCanonical.concatenating(
                        rhs.localToCanonical
                    )
                    #expect(compiled.images.contains {
                        affinesAgreeModuloSupercell(
                            product,
                            $0.localToCanonical,
                            size: PatternSize(width: 192, height: 128)
                        )
                    })
                }
            }
        }
    }

    @Test
    func compilerValidatesTriangularSpacingAndCost() {
        let unequal = PeriodicSymmetryConfiguration(
            presetID: .rotation6,
            repeatSize: PatternSize(width: 128, height: 96),
            orientationRadians: .pi / 6
        )
        #expect(
            throws: SymmetryDescriptorError.nonUniformTriangularSpacing(
                width: 128,
                height: 96
            )
        ) {
            try SymmetryDescriptorCompiler.compile(
                configuration: unequal,
                canonicalRasterSize: PixelSize(width: 128, height: 96)
            )
        }

        let overBudget = PeriodicSymmetryConfiguration(
            presetID: .kaleidoscope30,
            repeatSize: PatternSize(width: 0.001, height: 0.001),
            orientationRadians: .pi / 11
        )
        #expect(throws: SymmetryDescriptorError.self) {
            try SymmetryDescriptorCompiler.compile(
                configuration: overBudget,
                canonicalRasterSize: PixelSize(width: 128, height: 96)
            )
        }
    }
}

private func affinesAgree(
    _ lhs: Affine2D,
    _ rhs: Affine2D,
    probes: [SIMD2<Float>]
) -> Bool {
    probes.allSatisfy {
        simd_distance(lhs.applying(to: $0), rhs.applying(to: $0))
            < 0.000_1
    }
}

private func affinesAgreeModuloSupercell(
    _ lhs: Affine2D,
    _ rhs: Affine2D,
    size: PatternSize
) -> Bool {
    guard
        simd_distance(lhs.xAxis, rhs.xAxis) < 0.000_1,
        simd_distance(lhs.yAxis, rhs.yAxis) < 0.000_1
    else {
        return false
    }
    let delta = lhs.translation - rhs.translation
    let column = (delta.x / size.width).rounded()
    let row = (delta.y / size.height).rounded()
    return abs(delta.x - column * size.width) < 0.001
        && abs(delta.y - row * size.height) < 0.001
}

private func squareRotationImages(side: Float) -> [CompiledIsometry] {
    [
        CompiledIsometry(ordinal: 0, localToCanonical: .identity),
        CompiledIsometry(
            ordinal: 1,
            localToCanonical: Affine2D(
                xAxis: SIMD2(0, 1),
                yAxis: SIMD2(-1, 0),
                translation: SIMD2(side, 0)
            ),
            operation: CompiledGroupOperation(
                quarterTurns: 1,
                reflected: false
            )
        ),
        CompiledIsometry(
            ordinal: 2,
            localToCanonical: Affine2D(
                xAxis: SIMD2(-1, 0),
                yAxis: SIMD2(0, -1),
                translation: SIMD2(side, side)
            ),
            operation: CompiledGroupOperation(
                quarterTurns: 2,
                reflected: false
            )
        ),
        CompiledIsometry(
            ordinal: 3,
            localToCanonical: Affine2D(
                xAxis: SIMD2(0, -1),
                yAxis: SIMD2(1, 0),
                translation: SIMD2(0, side)
            ),
            operation: CompiledGroupOperation(
                quarterTurns: 3,
                reflected: false
            )
        ),
    ]
}

private func squareReflectedImages(side: Float) -> [CompiledIsometry] {
    [
        CompiledIsometry(
            ordinal: 4,
            localToCanonical: Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, -1),
                translation: SIMD2(0, side)
            ),
            operation: CompiledGroupOperation(
                quarterTurns: 0,
                reflected: true
            )
        ),
        CompiledIsometry(
            ordinal: 5,
            localToCanonical: Affine2D(
                xAxis: SIMD2(0, 1),
                yAxis: SIMD2(1, 0),
                translation: .zero
            ),
            operation: CompiledGroupOperation(
                quarterTurns: 1,
                reflected: true
            )
        ),
        CompiledIsometry(
            ordinal: 6,
            localToCanonical: Affine2D(
                xAxis: SIMD2(-1, 0),
                yAxis: SIMD2(0, 1),
                translation: SIMD2(side, 0)
            ),
            operation: CompiledGroupOperation(
                quarterTurns: 2,
                reflected: true
            )
        ),
        CompiledIsometry(
            ordinal: 7,
            localToCanonical: Affine2D(
                xAxis: SIMD2(0, -1),
                yAxis: SIMD2(-1, 0),
                translation: SIMD2(side, side)
            ),
            operation: CompiledGroupOperation(
                quarterTurns: 3,
                reflected: true
            )
        ),
    ]
}

private func signedArea(_ vertices: [SIMD2<Float>]) -> Float {
    guard vertices.count >= 3 else { return 0 }
    var twiceArea: Float = 0
    for index in vertices.indices {
        let next = vertices[(index + 1) % vertices.count]
        twiceArea += vertices[index].x * next.y - vertices[index].y * next.x
    }
    return abs(twiceArea) * 0.5
}
