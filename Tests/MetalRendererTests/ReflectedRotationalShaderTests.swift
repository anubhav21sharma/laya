import Foundation
import Testing

@Suite("Reflected, rotational, and diagnostic Metal paths")
struct ReflectedRotationalShaderTests {
    @Test
    func mirrorAndRotationalDisplayCasesUseSharedWireValues() throws {
        let source = try normalizedSource("Sources/MetalRenderer/Shaders.metal")

        #expect(source.contains("case PatternTilingWireMirrorX:"))
        #expect(source.contains("case PatternTilingWireMirrorY:"))
        #expect(source.contains("case PatternTilingWireMirrorXY:"))
        #expect(source.contains("case PatternTilingWireRotational:"))
        #expect(source.contains("const int column = int(floor(world.x / tileSize.x));"))
        #expect(source.contains("const int row = int(floor(world.y / tileSize.y));"))
        #expect(source.contains("patternPositiveFold(tileSize.x - local.x, tileSize.x)"))
        #expect(source.contains("patternPositiveFold(tileSize.y - local.y, tileSize.y)"))
    }

    @Test
    func unknownTilingWireUsesFixedDebugColorInsteadOfInteractiveState() throws {
        let shader = try normalizedSource("Sources/MetalRenderer/Shaders.metal")
        let renderer = try normalizedSource(
            "Sources/MetalRenderer/GridRenderer.swift"
        )

        #expect(shader.contains("float4(1.0, 0.0, 1.0, 1.0)"))
        #expect(shader.contains("if (!mapping.valid)"))
        #expect(renderer.contains("tilingKind: tilingStrategy.kind.rawValue"))
        #expect(!renderer.contains("public func setTilingWire"))
        #expect(!renderer.contains("public var tilingWire"))
    }

    @Test
    func diagnosticPipelineUsesProductionVertexAndSharedDiagnosticWires() throws {
        let shader = try normalizedSource("Sources/MetalRenderer/Shaders.metal")
        let pipelines = try normalizedSource(
            "Sources/MetalRenderer/GridPipelineLibrary.swift"
        )

        #expect(shader.contains(
            "fragment float4 patternDiagnosticFootprintFragment("
        ))
        #expect(shader.contains("case PatternDiagnosticWireAsymmetricCoverage:"))
        #expect(shader.contains("case PatternDiagnosticWireCanonicalCoordinates:"))
        #expect(shader.contains("case PatternDiagnosticWireBrushLocalCoordinates:"))
        #expect(shader.contains("float2(-0.75, -0.60)"))
        #expect(shader.contains("float2(0.85, -0.20)"))
        #expect(shader.contains("float2(-0.10, 0.90)"))
        #expect(pipelines.contains("vertex: \"patternProjectedStampVertex\""))
        #expect(pipelines.contains("fragment: \"patternDiagnosticFootprintFragment\""))
        #expect(!shader.contains("PatternDiagnosticWireAsymmetricCoverage ="))
    }

    @Test
    func diagnosticSelectionIsInternalAndAbsentFromProductViews() throws {
        let renderer = try normalizedSource(
            "Sources/MetalRenderer/GridRenderer.swift"
        )
        let productPaths = [
            "App/PatternSpike/ContentView.swift",
            "App/PatternSpike/Canvas/MetalCanvas.swift",
            "App/PatternSpike/Canvas/InteractiveMetalView.swift",
        ]

        #expect(renderer.contains("renderDiagnosticFootprintForHarness"))
        #expect(!renderer.contains(
            "public func renderDiagnosticFootprintForHarness"
        ))
        for path in productPaths {
            let source = try normalizedSource(path)
            #expect(!source.contains("diagnosticMode"), "\(path)")
            #expect(!source.contains("DiagnosticWire"), "\(path)")
            #expect(!source.contains("renderDiagnostic"), "\(path)")
        }
    }

    @Test
    func harnessComputesDiagnosticMetricsFromCapturesAndTransforms() throws {
        let runner = try normalizedSource(
            "Sources/MetalRenderer/Capture/HarnessRunner.swift"
        )

        #expect(runner.contains("coordinateContinuityMismatchCount("))
        #expect(runner.contains("independentTransformMismatchCount("))
        #expect(runner.contains("duplicateFixedPointWriteCount("))
        #expect(runner.contains("displayFoldMismatchCount("))
        #expect(runner.contains("gridLineLatticeMismatchCount("))
        #expect(runner.contains("rotationalGeneratorWorldProbes("))
        #expect(runner.contains("textureBytes("))
        #expect(runner.contains("canonicalCoordinatesBGRA"))
        #expect(runner.contains("brushLocalCoordinatesBGRA"))
    }

    private func normalizedSource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        ).replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }
}
