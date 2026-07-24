import Foundation
@testable import PatternEngine
import simd
import Testing

@Suite("Independent radial coverage oracle")
struct RadialCoverageOracleTests {
    @Test
    func primeAndPresetRayOrbitsHaveExactGenericCardinality() {
        let center = WorldPoint(x: 128, y: 128)
        let point = WorldPoint(x: 169, y: 147)

        for rays in [2, 3, 4, 5, 6, 7, 8, 12, 16, 32] {
            let cyclic = RadialCoverageOracle.orbit(
                of: point,
                configuration: RadialSymmetryConfiguration(
                    kind: .rotation,
                    rayCount: rays,
                    center: center
                )
            )
            let dihedral = RadialCoverageOracle.orbit(
                of: point,
                configuration: RadialSymmetryConfiguration(
                    kind: .mandala,
                    rayCount: rays,
                    center: center,
                    referenceAngleRadians: 0.13
                )
            )
            #expect(cyclic.count == rays)
            #expect(dihedral.count == 2 * rays)
        }
    }

    @Test
    func centreAndMirrorAxisStabilizersDoNotCreatePhantomPoints() {
        let center = WorldPoint(x: 90, y: 120)
        let mirror = RadialSymmetryConfiguration(
            kind: .mirror,
            rayCount: 1,
            center: center,
            referenceAngleRadians: 0
        )

        #expect(RadialCoverageOracle.orbit(
            of: center,
            configuration: mirror
        ).count == 1)
        #expect(RadialCoverageOracle.orbit(
            of: WorldPoint(x: 140, y: 120),
            configuration: mirror
        ).count == 1)
        #expect(RadialCoverageOracle.orbit(
            of: WorldPoint(x: 140, y: 130),
            configuration: mirror
        ).count == 2)
    }

    @Test
    func oracleSourceDoesNotConsumeProductionDescriptorArtifacts() throws {
        let source = try String(
            contentsOfFile:
                "Sources/PatternEngine/Verification/RadialCoverageOracle.swift",
            encoding: .utf8
        )
        for forbidden in [
            "CompiledSymmetry",
            "CompiledIsometry",
            "CompiledOwnership",
            "RadialSectorLayout",
            "TilingProjection",
            "TilingImage",
        ] {
            #expect(!source.contains(forbidden))
        }
    }
}
