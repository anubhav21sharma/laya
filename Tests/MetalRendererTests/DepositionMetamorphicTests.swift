import Foundation
import Metal
@testable import MetalRenderer
import Testing

@Suite("Native deposition canonical metamorphic evidence", .serialized)
struct DepositionMetamorphicTests {
    @Test(arguments: [
        MetamorphicScene(
            name: "deposition-prediction",
            invariants: ["predictionOnOffEqual"]
        ),
        MetamorphicScene(
            name: "deposition-kinematics",
            invariants: ["batchPartitionsEqual", "zoomIndependent"]
        ),
        MetamorphicScene(
            name: "deposition-periodic-seams",
            invariants: [
                "symmetryOrderEqual",
                "tilingPeriodTranslationEqual",
            ]
        ),
        MetamorphicScene(
            name: "deposition-erase",
            invariants: ["eraseColorIndependent"]
        ),
        MetamorphicScene(
            name: "deposition-radial-reflection",
            invariants: ["reflectionHandednessCorrect"]
        ),
        MetamorphicScene(
            name: "deposition-preview-commit",
            invariants: ["cancelPreservesCanonical"]
        ),
    ])
    @MainActor
    func canonicalInvariantIsProvenFromNativeBytes(
        _ fixture: MetamorphicScene
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try depositionHarnessTestLibrary(device: device)
        let output = temporaryDirectory(named: fixture.name)
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try await DepositionHarnessRunner(
            device: device,
            library: library
        ).run(
            scene: repositoryScene(named: fixture.name),
            outputDirectory: output,
            build: BenchmarkBuild(
                configuration: "Testing",
                gitCommit: String(repeating: "a", count: 40)
            )
        )
        let evidence = try DepositionSceneEvidence.decode(
            Data(
                contentsOf: output.appendingPathComponent(
                    "\(fixture.name).deposition-evidence.json"
                )
            )
        )

        for invariant in fixture.invariants {
            #expect(evidence.invariantResults[invariant] == true)
        }
    }
}

struct MetamorphicScene: Sendable, CustomTestStringConvertible {
    let name: String
    let invariants: [String]

    var testDescription: String { name }
}
