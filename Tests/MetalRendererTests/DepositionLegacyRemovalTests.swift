import Foundation
import Testing

@Suite("Deposition legacy removal")
struct DepositionLegacyRemovalTests {
    @Test
    func simulatorPresentationFallbackCannotClaimDrawablePresentation()
        throws
    {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rendererSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/MetalRenderer/GridRenderer.swift"
            ),
            encoding: .utf8
        )
        let fallbackStart = try #require(rendererSource.range(
            of: "#if targetEnvironment(simulator)\n"
                + "                        self?."
        ))
        let fallbackEnd = try #require(rendererSource.range(
            of: "                        #endif",
            range: fallbackStart.upperBound..<rendererSource.endIndex
        ))
        let fallback = rendererSource[
            fallbackStart.lowerBound..<fallbackEnd.upperBound
        ]

        #expect(fallback.contains("recordStrokeRuntimeCompletedFrame("))
        #expect(!fallback.contains("recordStrokeRuntimePresentedFrame("))
    }
}
