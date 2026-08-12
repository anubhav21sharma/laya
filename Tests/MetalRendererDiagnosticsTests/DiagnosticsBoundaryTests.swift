import Foundation
import MetalRenderer
@testable import MetalRendererDiagnostics
import PatternEngine
import Testing

@Suite("Renderer diagnostics module boundary")
struct DiagnosticsBoundaryTests {
    @Test
    func diagnosticsModuleOwnsHarnessSceneDecoding() throws {
        let payload = Data(
            """
            {
              "schemaVersion": 6,
              "name": "deposition-ink",
              "width": 64,
              "height": 48,
              "depositionInvariantExpectations": {
                "familyAndAccumulationCorrect": true
              }
            }
            """.utf8
        )

        let scene = try HarnessScene.decode(payload)

        #expect(scene.name == "deposition-ink")
        #expect(scene.width == 64)
        #expect(scene.height == 48)
    }

    @Test
    func diagnosticsModuleOwnsIndependentDepositionOracle() {
        let accumulated = DepositionReference.accumulateAlpha(
            current: 0.25,
            baseCoverage: 0.5,
            flowCoverage: 0.4,
            mode: .flow,
            accumulationLimit: 1
        )

        #expect(accumulated == 0.55)
    }

    @Test
    func productionPNGExportRejectsMismatchedPixelPayloads() {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")

        #expect(throws: EncodedPNGWriterError.invalidByteCount(3)) {
            try EncodedPNGWriter.writeBGRA(
                [0, 1, 2],
                pixelSize: PixelSize(width: 1, height: 1),
                to: destination
            )
        }
    }
}
