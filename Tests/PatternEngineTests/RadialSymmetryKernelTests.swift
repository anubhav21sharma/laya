import Foundation
@testable import PatternEngine
import simd
import Testing

@Suite("Radial symmetry kernel")
struct RadialSymmetryKernelTests {
    private let canvas = PixelSize(width: 256, height: 256)

    @Test
    func cyclicAndDihedralFoldsMatchIndependentOracle() throws {
        let configurations: [FiniteSymmetryConfiguration] = [
            .plain,
            .radial(RadialSymmetryConfiguration(
                kind: .mirror,
                rayCount: 1,
                center: WorldPoint(x: 128, y: 128),
                referenceAngleRadians: .pi / 7
            )),
            .radial(RadialSymmetryConfiguration(
                kind: .rotation,
                rayCount: 5,
                center: WorldPoint(x: 91, y: 137),
                referenceAngleRadians: -.pi / 9
            )),
            .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 7,
                center: WorldPoint(x: 117, y: 83),
                referenceAngleRadians: .pi / 11
            )),
        ]
        let probes = [
            WorldPoint(x: 0, y: 0),
            WorldPoint(x: 32, y: 211),
            WorldPoint(x: 128, y: 128),
            WorldPoint(x: 255.5, y: 17),
        ]

        for configuration in configurations {
            let strategy = try TilingStrategy(
                finiteConfiguration: configuration,
                canvasSize: canvas
            )
            for point in probes {
                let logical = try #require(RadialCoverageOracle.fold(
                    point,
                    configuration: configuration,
                    canvasSize: canvas
                ))
                let actual = strategy.displayFold(point)
                if let layout = strategy.compiledSymmetry.domain.finite?
                    .radial.layout
                {
                    let atlas = try #require(
                        layout.atlasPoint(forLogical: logical.simd)
                    )
                    #expect(simd_distance(
                        SIMD2(actual.x, actual.y),
                        atlas
                    ) < 0.000_1)
                } else {
                    #expect(actual == logical)
                }
            }
        }
    }

    @Test(arguments: [2, 3, 4, 5, 7, 8, 12, 16, 32])
    func genericCyclicAndDihedralPointsProjectOneLinkedSource(
        _ rayCount: Int
    ) throws {
        for kind in [RadialSymmetryKind.rotation, .mandala] {
            let configuration = RadialSymmetryConfiguration(
                kind: kind,
                rayCount: rayCount,
                center: WorldPoint(x: 128, y: 128),
                referenceAngleRadians: 0.17
            )
            let strategy = try TilingStrategy(
                finiteConfiguration: .radial(configuration),
                canvasSize: canvas
            )
            let source = WorldPoint(x: 181, y: 143)
            let orbit = RadialCoverageOracle.orbit(
                of: source,
                configuration: configuration
            ).filter {
                $0.x >= 0 && $0.y >= 0
                    && $0.x < 256 && $0.y < 256
            }
            let expected = strategy.displayFold(source)

            for point in orbit {
                let actual = strategy.displayFold(point)
                #expect(simd_distance(
                    SIMD2(actual.x, actual.y),
                    SIMD2(expected.x, expected.y)
                ) < 0.001)
            }
        }
    }

    @Test
    func finiteCanvasNeverRepeatsOutsideItsBounds() throws {
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 8,
                center: WorldPoint(x: 128, y: 128)
            )),
            canvasSize: canvas
        )

        #expect(strategy.images(intersecting: AxisAlignedRect(
            minimum: SIMD2(300, 300),
            maximum: SIMD2(340, 340)
        )).isEmpty)
        #expect(strategy.displayFold(WorldPoint(x: -1, y: 12))
            == CanonicalPoint(x: -1, y: -1))
    }

    @Test
    func centerFootprintDeduplicatesInvariantButNotOrientedImages()
        throws
    {
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 6,
                center: WorldPoint(x: 128, y: 128)
            )),
            canvasSize: canvas
        )
        let transform = Affine2D(
            xAxis: SIMD2(8, 0),
            yAxis: SIMD2(0, 8),
            translation: SIMD2(128, 128)
        )
        let bounds = AxisAlignedRect(
            minimum: SIMD2(-1, -1),
            maximum: SIMD2(1, 1)
        )
        let invariant = TilingProjection.fragments(
            for: StampFootprint(
                brushToWorld: transform,
                localBounds: bounds,
                coverageSymmetry: .rotationAndReflectionInvariant
            ),
            using: strategy
        )
        let oriented = TilingProjection.fragments(
            for: StampFootprint(
                brushToWorld: transform,
                localBounds: bounds,
                coverageSymmetry: .oriented
            ),
            using: strategy
        )

        #expect(!invariant.isEmpty)
        #expect(oriented.count > invariant.count)
    }
}

private extension CanonicalPoint {
    var simd: SIMD2<Float> { SIMD2(x, y) }
}
