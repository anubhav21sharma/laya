@testable import PatternEngine
import simd
import Testing

@Suite("Triangular symmetry kernel")
struct TriangularSymmetryKernelTests {
    @Test
    func genericFootprintsEnumerateExactRectangularSupercellOrbits()
        throws
    {
        let expectations: [(SymmetryPresetID, Int)] = [
            (.hexagons, 2),
            (.rotation3, 6),
            (.rotation6, 12),
            (.kaleidoscope60, 12),
            (.kaleidoscope30, 24),
        ]
        for (preset, expectedCount) in expectations {
            let strategy = try triangularStrategy(preset)
            let basis = try #require(
                strategy.compiledSymmetry.domain.periodic
            )
                .translationBasis
            let center = basis.u * 0.271 + basis.v * 0.193
            let bounds = AxisAlignedRect(
                minimum: center - SIMD2(repeating: 0.01),
                maximum: center + SIMD2(repeating: 0.01)
            )
            let images = strategy.images(intersecting: bounds)

            #expect(images.count == expectedCount)
            #expect(Set(images.map(\.ordinal)).count == expectedCount)
            for image in images {
                let canonical = image.worldToCanonical.applying(to: center)
                #expect(canonical.x >= 0 && canonical.x < 192)
                #expect(canonical.y >= 0 && canonical.y < 128)
                #expect(image.worldClip.halfPlanes.count == 4)
            }
        }
    }

    @Test
    func supercellTranslationsProduceTheSameCanonicalOrbit() throws {
        let strategy = try triangularStrategy(.kaleidoscope30)
        let basis = try #require(
            strategy.compiledSymmetry.domain.periodic
        )
            .translationBasis
        let center = basis.u * 0.271 + basis.v * 0.193
        let translations = [
            SIMD2<Float>.zero,
            basis.u,
            basis.v,
            -basis.u - basis.v,
        ]
        let reference = canonicalOrbit(
            center: center,
            strategy: strategy
        )
        for translation in translations {
            let translated = canonicalOrbit(
                center: center + translation,
                strategy: strategy
            )
            #expect(
                zip(reference, translated).allSatisfy {
                    simd_distance($0, $1) < 0.001
                }
            )
        }
    }

    @Test
    func displayFoldUsesHalfOpenOrientedRectangularSupercell() throws {
        let strategy = try triangularStrategy(.rotation6)
        let basis = try #require(
            strategy.compiledSymmetry.domain.periodic
        )
            .translationBasis
        let local = basis.u * 0.31 + basis.v * 0.47
        let expected = CanonicalPoint(x: 192 * 0.31, y: 128 * 0.47)

        for translated in [
            local,
            local + basis.u,
            local + basis.v,
            local - basis.u - basis.v,
        ] {
            let folded = strategy.displayFold(WorldPoint(translated))
            #expect(abs(folded.x - expected.x) < 0.001)
            #expect(abs(folded.y - expected.y) < 0.001)
        }

        let origin = strategy.displayFold(WorldPoint(.zero))
        #expect(origin == CanonicalPoint(x: 0, y: 0))
        let negative = strategy.displayFold(
            WorldPoint(-basis.u * 0.25 - basis.v * 0.25)
        )
        #expect(abs(negative.x - 144) < 0.001)
        #expect(abs(negative.y - 96) < 0.001)
    }

    @Test
    func fixedPointDeduplicationUsesExactTriangularOperations() throws {
        let expectations: [(SymmetryPresetID, Int, Int)] = [
            (.rotation3, 6, 2),
            (.rotation6, 12, 4),
            (.kaleidoscope60, 12, 2),
            (.kaleidoscope30, 24, 4),
        ]
        for (preset, orientedCount, invariantCount) in expectations {
            let strategy = try triangularStrategy(preset)
            let fixedRaster = SIMD2<Float>(96, 128 / 6)
            let fixedWorld = strategy.compiledSymmetry.rasterMetric
                .rasterToWorld.applying(to: fixedRaster)

            let oriented = TilingProjection.fragments(
                for: triangularFootprint(
                    center: fixedWorld,
                    coverageSymmetry: .oriented
                ),
                using: strategy
            )
            let invariant = TilingProjection.fragments(
                for: triangularFootprint(
                    center: fixedWorld,
                    coverageSymmetry: .rotationAndReflectionInvariant
                ),
                using: strategy
            )
            #expect(Set(oriented.map(\.imageOrdinal)).count == orientedCount)
            let centerGroups = Dictionary(
                grouping: invariant,
                by: triangularFixedCenterKey
            )
            #expect(centerGroups.count == invariantCount)
            #expect(centerGroups.values.allSatisfy { fragments in
                guard let operation = fragments.first?.operation else {
                    return false
                }
                return fragments.allSatisfy {
                    $0.operation == operation
                }
            })
            #expect(invariant.count < oriented.count)
        }
    }

    @Test
    func nearFixedPointAtMaximumRasterDoesNotCollapseDistinctImages()
        throws
    {
        let rasterSize = PixelSize(width: 4_096, height: 4_096)
        let strategy = try TilingStrategy(
            configuration: PeriodicSymmetryConfiguration(
                presetID: .kaleidoscope30,
                repeatSize: PatternSize(width: 8_192, height: 8_192),
                orientationRadians: -.pi / 9
            ),
            canonicalRasterSize: rasterSize
        )
        let metric = strategy.compiledSymmetry.rasterMetric
        let exactRaster = SIMD2<Float>(2_048, 4_096 / 6)
        let exactWorld = metric.rasterToWorld.applying(to: exactRaster)
        let nearWorld = metric.rasterToWorld.applying(
            to: exactRaster + SIMD2<Float>(0.0015, 0.0015)
        )
        let brushXAxis = metric.rasterToWorld.xAxis * 0.01
        let brushYAxis = metric.rasterToWorld.yAxis * 0.01

        func fragments(at center: SIMD2<Float>) -> [CellFragment] {
            TilingProjection.fragments(
                for: StampFootprint(
                    brushToWorld: Affine2D(
                        xAxis: brushXAxis,
                        yAxis: brushYAxis,
                        translation: center
                    ),
                    localBounds: AxisAlignedRect(
                        minimum: SIMD2(-1, -1),
                        maximum: SIMD2(1, 1)
                    ),
                    coverageSymmetry: .rotationAndReflectionInvariant
                ),
                using: strategy
            )
        }

        let exactOrdinals = Set(
            fragments(at: exactWorld).map(\.imageOrdinal)
        )
        let nearOrdinals = Set(
            fragments(at: nearWorld).map(\.imageOrdinal)
        )

        #expect(exactOrdinals.count < 24)
        #expect(nearOrdinals.count == 24)
    }
}

private func triangularStrategy(
    _ preset: SymmetryPresetID
) throws -> TilingStrategy {
    try TilingStrategy(
        configuration: PeriodicSymmetryConfiguration(
            presetID: preset,
            repeatSize: PatternSize(width: 256, height: 256),
            orientationRadians: .pi / 7
        ),
        canonicalRasterSize: PixelSize(width: 192, height: 128)
    )
}

private func canonicalOrbit(
    center: SIMD2<Float>,
    strategy: TilingStrategy
) -> [SIMD2<Float>] {
    let epsilon = SIMD2<Float>(repeating: 0.01)
    return strategy.images(
        intersecting: AxisAlignedRect(
            minimum: center - epsilon,
            maximum: center + epsilon
        )
    ).map {
        $0.worldToCanonical.applying(to: center)
    }.sorted {
        $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y
    }
}

private func triangularFootprint(
    center: SIMD2<Float>,
    coverageSymmetry: FootprintCoverageSymmetry
) -> StampFootprint {
    StampFootprint(
        brushToWorld: Affine2D(
            xAxis: SIMD2(2, 0),
            yAxis: SIMD2(0, 2),
            translation: center
        ),
        localBounds: AxisAlignedRect(
            minimum: SIMD2(-1, -1),
            maximum: SIMD2(1, 1)
        ),
        coverageSymmetry: coverageSymmetry
    )
}

private func triangularFixedCenterKey(
    _ fragment: CellFragment
) -> SIMD2<Int> {
    let point = fragment.canonicalFromBrush.translation
    let x = abs(point.x) < 0.001 || abs(point.x - 192) < 0.001
        ? 0
        : point.x
    let y = abs(point.y) < 0.001 || abs(point.y - 128) < 0.001
        ? 0
        : point.y
    return SIMD2(
        Int((x * 1_000).rounded()),
        Int((y * 1_000).rounded())
    )
}
