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
            switch try HarnessSchemaRouting.runnerKind(
                for: scene.schemaVersion
            ) {
            case .deposition:
                Task { @MainActor in
                    do {
                        let result = try await DepositionHarnessRunner(
                            device: device,
                            productionAnchorDefinitions: [
                                "deposition-airbrush":
                                    AnchorBrushCatalog.airbrush.definition,
                                "deposition-dry":
                                    AnchorBrushCatalog.dryMedia.definition,
                                "deposition-erase":
                                    AnchorBrushCatalog.eraser.definition,
                                "deposition-glaze":
                                    AnchorBrushCatalog.glaze.definition,
                                "deposition-ink":
                                    AnchorBrushCatalog.ink.definition,
                                "deposition-marker":
                                    AnchorBrushCatalog.marker.definition,
                            ]
                        ).run(
                            scene: scene,
                            outputDirectory: outputDirectory,
                            build: build
                        )
                        pass(scene: scene, result: result)
                    } catch {
                        fail(error)
                    }
                }
                return
            case .sliceThree:
                let result = try SliceThreeHarnessRunner(device: device).run(
                    scene: scene,
                    outputDirectory: outputDirectory,
                    build: build
                )
                pass(scene: scene, result: result)
            case .foundation:
                let result = try HarnessRunner(device: device).run(
                    scene: scene,
                    outputDirectory: outputDirectory,
                    build: build
                )
                pass(scene: scene, result: result)
            }
        } catch {
            fail(error)
        }
    }

    private static func pass(
        scene: HarnessScene,
        result: HarnessRunResult
    ) -> Never {
        print(
            "HARNESS PASS scene=\(scene.name) image=\(result.imageURL.path) benchmark=\(result.benchmarkURL.path)"
        )
        exit(EXIT_SUCCESS)
    }

    private static func fail(_ error: Error) -> Never {
        let message = "HARNESS FAIL \(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(EXIT_FAILURE)
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
