import Darwin
import EditorCore
import Foundation
import Metal
import MetalRenderer
import PatternEngine

enum HarnessLaunch {
    @MainActor
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--harness-scene") else {
            return
        }

        do {
            let scenePath = try value(after: "--harness-scene", in: arguments)
            let outputPath = try value(after: "--output-directory", in: arguments)
            let gitCommit = try value(after: "--git-commit", in: arguments)
            let configuration = try value(after: "--configuration", in: arguments)

            guard let device = MTLCreateSystemDefaultDevice() else {
                throw HarnessLaunchError.metalUnavailable
            }

            let sceneData = try Data(contentsOf: URL(fileURLWithPath: scenePath))
            let scene = try HarnessScene.decode(sceneData)
            let outputDirectory = URL(fileURLWithPath: outputPath)
            let build = BenchmarkBuild(
                configuration: configuration,
                gitCommit: gitCommit
            )
            let result: HarnessRunResult
            if scene.schemaVersion == 5 {
                let history = SliceThreeHarnessHistory(
                    releaseRasterRevisions: { _ in }
                )
                let runner = SliceFourHarnessRunner(
                    device: device,
                    anchorRecipes: AnchorBrushCatalog.drawAnchors.map(\.recipe),
                    catalogRecipeVerifier: { recipe in
                        AnchorBrushCatalog.recipe(for: recipe.id) == recipe
                    },
                    historyRecorder: { receipt in
                        if let receipt {
                            try history.appendRaster(
                                kind: .draw,
                                receipt: receipt
                            )
                        }
                        return history.evidence.commandCount
                    }
                )
                result = try runner.run(
                    scene: scene,
                    outputDirectory: outputDirectory,
                    build: build
                )
            } else if scene.schemaVersion == 4 {
                result = try SliceThreeHarnessRunner(device: device).run(
                    scene: scene,
                    outputDirectory: outputDirectory,
                    build: build
                )
            } else {
                result = try HarnessRunner(device: device).run(
                    scene: scene,
                    outputDirectory: outputDirectory,
                    build: build
                )
            }

            print(
                "HARNESS PASS scene=\(scene.name) image=\(result.imageURL.path) benchmark=\(result.benchmarkURL.path)"
            )
            exit(EXIT_SUCCESS)
        } catch {
            let message = "HARNESS FAIL \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func value(
        after flag: String,
        in arguments: [String]
    ) throws -> String {
        guard
            let index = arguments.firstIndex(of: flag),
            arguments.indices.contains(index + 1)
        else {
            throw HarnessLaunchError.missingArgument(flag)
        }
        return arguments[index + 1]
    }
}

enum HarnessLaunchError: Error, LocalizedError {
    case missingArgument(String)
    case metalUnavailable

    var errorDescription: String? {
        switch self {
        case let .missingArgument(flag):
            "Missing required harness argument \(flag)."
        case .metalUnavailable:
            "Metal is unavailable."
        }
    }
}
