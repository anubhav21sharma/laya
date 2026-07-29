import Foundation
import Testing

@Suite("Deposition legacy removal")
struct DepositionLegacyRemovalTests {
    @Test
    func activeProductionContainsNoLegacyDepositionRuntimeSurface() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileManager = FileManager.default
        let productionRoots = [
            repositoryRoot.appendingPathComponent("Sources/PatternEngine"),
            repositoryRoot.appendingPathComponent("Sources/MetalRenderer"),
            repositoryRoot.appendingPathComponent("Sources/EditorCore"),
            repositoryRoot.appendingPathComponent("App/PatternSpike"),
        ]
        let explicitFiles: [URL] = [
            repositoryRoot.appendingPathComponent(
                "Sources/CShaderTypes/include/ShaderTypes.h"
            ),
        ]
        let forbiddenTokens = [
            "compatibilityRecipe",
            "LegacyBrushRecipeAdapter.",
            "BrushMaterialState",
            "BoundedWashSurface",
            "PatternMaterialWireBoundedWash",
            "PatternDepositionEdgeWetConcentration",
            "patternWash",
            "pipelines.stamp",
            "washDeposit",
            "washSoften",
            "washResolve",
            "legacyIsReady",
            "compiledBrush: nil",
            "let compiledBrush: CompiledBrush?",
            "execution.compiledBrush != nil",
            "func compatibilityRandomValues(",
            """
            func materialInputs(
                    _ material: BrushMaterial
                ) -> BrushMaterialInputs
            """,
            """
            public static func legacy(
                    recipe: BrushRecipe
            """,
        ]
        let allowedHistoricalSchemaFiles: Set<String> = [
            "Sources/PatternEngine/BrushModel/LegacyBrushRecipeAdapter.swift",
        ]

        var discoveredFiles: [URL] = []
        for root in productionRoots {
            let files = try #require(
                fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey]
                )
            )
            .compactMap { $0 as? URL }
            .filter {
                ["swift", "metal", "h"].contains($0.pathExtension)
            }
            discoveredFiles.append(contentsOf: files)
        }
        let productionFiles = (discoveredFiles + explicitFiles)
            .sorted { $0.path < $1.path }
        var violations: [String] = []

        for file in productionFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            let relativePath = file.path.replacingOccurrences(
                of: repositoryRoot.path + "/",
                with: ""
            )
            for token in forbiddenTokens
            where source.contains(token)
                && !(
                    token == "LegacyBrushRecipeAdapter."
                        && allowedHistoricalSchemaFiles.contains(relativePath)
                )
            {
                violations.append("\(relativePath): \(token)")
            }
        }

        #expect(violations.isEmpty)
    }

    @Test
    func nativeAnchorCatalogHasNoBoundedWashEntry() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalog = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/EditorCore/Brushes/AnchorBrushCatalog.swift"
            ),
            encoding: .utf8
        )

        #expect(!catalog.contains("boundedWash"))
    }
}
