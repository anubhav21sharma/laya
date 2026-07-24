import Foundation
import Metal
import MetalRenderer
import PatternEngine
import Testing

@Suite("Radial evidence harness")
struct RadialHarnessTests {
    @Test
    func scenePairsCoverThePinnedMatrixAndDifferByOneExpectation()
        throws
    {
        let pairs = try radialHarnessScenePairs()
        #expect(Set(pairs.map(\.positive.scenario))
            == Set(RadialHarnessScenario.allCases))

        for pair in pairs {
            #expect(pair.positive.expectedMismatchCount == 0)
            #expect(pair.negative.expectedMismatchCount == 1)
            #expect(
                normalized(pair.positive) == normalized(pair.negative)
            )
        }
    }

    @Test
    @MainActor
    func positiveScenesPassRealMetalAndNegativeControlsFailClosed()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try radialHarnessLibrary(device: device)

        for pair in try radialHarnessScenePairs() {
            let measurement = try RadialHarnessRunner.run(
                pair.positive,
                device: device,
                library: library
            )
            try pair.positive.validate(measurement)
            #expect(measurement.mismatchCount == 0)
            #expect(measurement.projectedFragmentCount > 0)
            #expect(measurement.atlasResidentBytesPerSurface > 0)
            #expect(measurement.projectionMilliseconds >= 0)
            #expect(measurement.commitCPUMilliseconds >= 0)
            #expect(measurement.commitGPUMilliseconds >= 0)
            #expect(measurement.exportMilliseconds >= 0)
            #expect(measurement.exportHash != 0)
            #expect(throws: RadialHarnessSceneError.measurementMismatch(
                expected: 1,
                actual: 0
            )) {
                try pair.negative.validate(measurement)
            }
        }
    }

    @Test
    @MainActor
    func requiredRayMatrixIsDeterministicAcrossTwoRealMetalRuns()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try radialHarnessLibrary(device: device)
        let rays = [2, 3, 4, 5, 6, 7, 8, 12, 16, 32]

        for rayCount in rays {
            let scene = RadialHarnessScene(
                name: "radial-ray-\(rayCount)",
                scenario: .generic,
                kind: rayCount.isMultiple(of: 2) ? .mandala : .rotation,
                rayCount: rayCount,
                canvasWidth: 128,
                canvasHeight: 128,
                centerX: 61,
                centerY: 67,
                referenceAngleRadians: 0.17,
                probeX: 86,
                probeY: 73,
                diameter: 12,
                expectedMismatchCount: 0
            )
            let first = try RadialHarnessRunner.run(
                scene,
                device: device,
                library: library
            )
            let second = try RadialHarnessRunner.run(
                scene,
                device: device,
                library: library
            )

            try scene.validate(first)
            try scene.validate(second)
            #expect(first.exportHash == second.exportHash)
            #expect(
                first.projectedFragmentCount
                    == second.projectedFragmentCount
            )
            #expect(
                first.atlasResidentBytesPerSurface
                    == second.atlasResidentBytesPerSurface
            )
        }
    }
}

private struct RadialHarnessPair {
    let positive: RadialHarnessScene
    let negative: RadialHarnessScene
}

private func radialHarnessScenePairs() throws -> [RadialHarnessPair] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")
    return try RadialHarnessScenario.allCases.map { scenario in
        let stem: String
        switch scenario {
        case .generic: stem = "radial-generic"
        case .axis: stem = "radial-axis"
        case .center: stem = "radial-center"
        case .reflected: stem = "radial-reflected"
        case .largeFootprint: stem = "radial-large-footprint"
        case .erase: stem = "radial-erase"
        case .lock: stem = "radial-lock"
        case .export: stem = "radial-export"
        }
        let positive = try RadialHarnessScene.decode(
            Data(contentsOf: root.appendingPathComponent("\(stem).json"))
        )
        let negative = try RadialHarnessScene.decode(
            Data(contentsOf: root.appendingPathComponent(
                "\(stem)-negative-control.json"
            ))
        )
        return RadialHarnessPair(positive: positive, negative: negative)
    }
}

private func normalized(
    _ scene: RadialHarnessScene
) -> RadialHarnessScene {
    RadialHarnessScene(
        name: "normalized",
        scenario: scene.scenario,
        kind: scene.kind,
        rayCount: scene.rayCount,
        canvasWidth: scene.canvasWidth,
        canvasHeight: scene.canvasHeight,
        centerX: scene.centerX,
        centerY: scene.centerY,
        referenceAngleRadians: scene.referenceAngleRadians,
        probeX: scene.probeX,
        probeY: scene.probeY,
        diameter: scene.diameter,
        expectedMismatchCount: 0
    )
}

private func radialHarnessLibrary(
    device: any MTLDevice
) throws -> any MTLLibrary {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let shader = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/MetalRenderer/Shaders.metal"
        ),
        encoding: .utf8
    )
    let header = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/CShaderTypes/include/ShaderTypes.h"
        ),
        encoding: .utf8
    )
    return try device.makeLibrary(
        source: shader.replacingOccurrences(
            of: "#include \"ShaderTypes.h\"",
            with: header
        ),
        options: nil
    )
}
