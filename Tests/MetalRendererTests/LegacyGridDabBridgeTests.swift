import CShaderTypes
@testable import MetalRenderer
import PatternEngine
import simd
import Testing

private let legacyBridgeTileSize = PatternSize(width: 256, height: 256)

@Test
func legacyGridBridgePreservesPlacementAndPeriodicPixelCoverage() {
    let fixtures: [LegacyBridgeFixture] = [
        LegacyBridgeFixture(
            center: SIMD2(100, 100),
            radius: 10,
            expectedCenters: Set([SIMD2(100, 100)])
        ),
        LegacyBridgeFixture(
            center: SIMD2(3, 100),
            radius: 10,
            expectedCenters: Set([
                SIMD2(3, 100),
                SIMD2(259, 100),
            ])
        ),
        LegacyBridgeFixture(
            center: SIMD2(-2, -2),
            radius: 10,
            expectedCenters: Set([
                SIMD2(254, 254),
                SIMD2(-2, 254),
                SIMD2(254, -2),
                SIMD2(-2, -2),
            ])
        ),
        LegacyBridgeFixture(
            center: SIMD2(5, 5),
            radius: 6,
            expectedCenters: Set([
                SIMD2(5, 5),
                SIMD2(261, 5),
                SIMD2(5, 261),
            ])
        ),
        LegacyBridgeFixture(
            center: SIMD2(3, 4),
            radius: 5,
            expectedCenters: Set([
                SIMD2(3, 4),
                SIMD2(259, 4),
                SIMD2(3, 260),
            ])
        ),
        LegacyBridgeFixture(
            center: SIMD2(10, 100),
            radius: 10,
            expectedCenters: Set([SIMD2(10, 100)])
        ),
    ]

    for fixture in fixtures {
        let instances = LegacyGridDabBridge.instances(
            center: WorldPoint(fixture.center),
            radius: fixture.radius,
            tileSize: legacyBridgeTileSize
        )

        #expect(instances.count == fixture.expectedCenters.count)
        #expect(Set(instances.map(\.center)) == fixture.expectedCenters)
        #expect(instances.allSatisfy { $0.radius == fixture.radius })

        var maximumCoverageError: Float = 0
        for pixelY in 0..<256 {
            for pixelX in 0..<256 {
                let probe = SIMD2<Float>(
                    Float(pixelX) + 0.5,
                    Float(pixelY) + 0.5
                )
                let actual = instances.map {
                    hardRoundCoverage(
                        at: probe,
                        center: $0.center,
                        radius: $0.radius
                    )
                }.max() ?? 0
                let expected = periodicHardRoundCoverage(
                    at: probe,
                    worldCenter: fixture.center,
                    radius: fixture.radius,
                    tileSize: legacyBridgeTileSize
                )
                maximumCoverageError = max(
                    maximumCoverageError,
                    abs(actual - expected)
                )
            }
        }
        #expect(maximumCoverageError == 0)
    }
}

private struct LegacyBridgeFixture {
    let center: SIMD2<Float>
    let radius: Float
    let expectedCenters: Set<SIMD2<Float>>
}

private func hardRoundCoverage(
    at point: SIMD2<Float>,
    center: SIMD2<Float>,
    radius: Float
) -> Float {
    min(max(radius + 0.5 - simd_distance(point, center), 0), 1)
}

private func periodicHardRoundCoverage(
    at point: SIMD2<Float>,
    worldCenter: SIMD2<Float>,
    radius: Float,
    tileSize: PatternSize
) -> Float {
    let delta = SIMD2<Float>(
        periodicDistance(
            between: point.x,
            and: worldCenter.x,
            extent: tileSize.width
        ),
        periodicDistance(
            between: point.y,
            and: worldCenter.y,
            extent: tileSize.height
        )
    )
    return min(max(radius + 0.5 - simd_length(delta), 0), 1)
}

private func periodicDistance(
    between lhs: Float,
    and rhs: Float,
    extent: Float
) -> Float {
    let direct = abs(lhs - rhs)
    let remainder = direct.truncatingRemainder(dividingBy: extent)
    return min(remainder, extent - remainder)
}
