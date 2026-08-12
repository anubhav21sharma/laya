import Foundation
@testable import MetalRenderer
@testable import MetalRendererDiagnostics
import Testing

@Suite("Current native harness scene")
struct HarnessSceneTests {
    @Test
    func unsupportedSchemasFailFromVersionEnvelopeBeforeBodyDecode() {
        for version in [1, 2, 3, 4, 5, 7] {
            let data = Data("{\"schemaVersion\":\(version)}".utf8)
            #expect(throws: HarnessSceneError.unsupportedSchema(version)) {
                try HarnessScene.decode(data)
            }
        }
    }

    @Test
    func schemaSixRoundTripsCurrentDepositionScene() throws {
        let data = Data(
            """
            {
              "schemaVersion": 6,
              "name": "deposition-ink",
              "width": 128,
              "height": 128,
              "depositionInvariantExpectations": {
                "familyAndAccumulationCorrect": true
              }
            }
            """.utf8
        )

        let scene = try HarnessScene.decode(data)
        let roundTripped = try HarnessScene.decode(
            JSONEncoder().encode(scene)
        )

        #expect(roundTripped == scene)
        #expect(scene.schemaVersion == 6)
        #expect(scene.name == "deposition-ink")
        #expect(scene.width == 128)
        #expect(scene.height == 128)
        #expect(scene.depositionInvariantExpectations == [
            "familyAndAccumulationCorrect": true,
        ])
    }
}
