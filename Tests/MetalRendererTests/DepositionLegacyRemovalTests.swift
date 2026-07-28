import Foundation
import Testing

@Suite("Deposition legacy removal")
struct DepositionLegacyRemovalTests {
    @Test
    func productionRendererContainsNoLegacyDepositionSurface() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileManager = FileManager.default
        let rendererRoot = repositoryRoot.appendingPathComponent(
            "Sources/MetalRenderer"
        )
        let explicitFiles = [
            repositoryRoot.appendingPathComponent(
                "Sources/CShaderTypes/include/ShaderTypes.h"
            ),
            repositoryRoot.appendingPathComponent(
                "Sources/EditorCore/Brushes/AnchorBrushCatalog.swift"
            ),
        ]
        let forbiddenTokens = [
            "compatibilityRecipe",
            "BrushMaterialState",
            "BoundedWashSurface",
            "PatternMaterialWireBoundedWash",
            "patternWash",
            "pipelines.stamp",
            "washDeposit",
            "washSoften",
            "washResolve",
        ]

        let rendererFiles = try #require(
            fileManager.enumerator(
                at: rendererRoot,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        .compactMap { $0 as? URL }
        .filter {
            ["swift", "metal"].contains($0.pathExtension)
        }
        let productionFiles = (rendererFiles + explicitFiles)
            .sorted { $0.path < $1.path }
        var violations: [String] = []

        for file in productionFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            let relativePath = file.path.replacingOccurrences(
                of: repositoryRoot.path + "/",
                with: ""
            )
            for token in forbiddenTokens where source.contains(token) {
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
