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
            let runtimeTraceProfile = try runtimeTraceProfile(in: arguments)

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
            Task { @MainActor in
                do {
                    let baseResult = try await DepositionHarnessRunner(
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
                            "professional-chisel-marker":
                                ProfessionalBrushCatalog.chiselMarker
                                    .definition,
                            "professional-graphite-pencil":
                                ProfessionalBrushCatalog.graphitePencil
                                    .definition,
                            "professional-natural-charcoal":
                                ProfessionalBrushCatalog.naturalCharcoal
                                    .definition,
                            "professional-technical-ink":
                                ProfessionalBrushCatalog.technicalInk
                                    .definition,
                        ]
                    ).run(
                        scene: scene,
                        outputDirectory: outputDirectory,
                        build: build
                    )
                    let result = try attachRuntimeTrace(
                        runtimeTraceProfile,
                        device: device,
                        to: baseResult
                    )
                    try validateRuntimeTrace(
                        runtimeTraceProfile,
                        result: result
                    )
                    pass(scene: scene, result: result)
                } catch {
                    fail(error)
                }
            }
            return
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

    private static func runtimeTraceProfile(
        in arguments: [String]
    ) throws -> StrokeRuntimeTraceProfile? {
        let flag = "--performance-trace"
        guard arguments.contains(flag) else { return nil }
        switch try value(after: flag, in: arguments) {
        case "10-second":
            return .productionTenSeconds
        case "accelerated-10-minute":
            return .productionAcceleratedTenMinutes
        case let value:
            throw HarnessLaunchError.invalidPerformanceTrace(value)
        }
    }

    private static func validateRuntimeTrace(
        _ requested: StrokeRuntimeTraceProfile?,
        result: HarnessRunResult
    ) throws {
        guard let requested else { return }
        guard let runtime = result.benchmark.strokeRuntime,
              runtime.traceProfile == requested
        else {
            throw HarnessLaunchError.missingProductionRuntimeTrace(
                requested.rawValue
            )
        }
        guard runtime.attestation?.origin == .productionRenderer else {
            throw HarnessLaunchError.missingProductionRuntimeTrace(
                requested.rawValue
            )
        }
    }

    @MainActor
    private static func attachRuntimeTrace(
        _ requested: StrokeRuntimeTraceProfile?,
        device: any MTLDevice,
        to result: HarnessRunResult
    ) throws -> HarnessRunResult {
        guard let requested else { return result }
        let runtime = try ProductionStrokeRuntimeTraceRunner(
            device: device
        ).run(profile: requested)
        var benchmark = result.benchmark
        benchmark.strokeRuntime = runtime
        try BenchmarkRecord.encode(benchmark).write(
            to: result.benchmarkURL,
            options: .atomic
        )
        return HarnessRunResult(
            imageURL: result.imageURL,
            benchmarkURL: result.benchmarkURL,
            benchmark: benchmark,
            artifactURLs: result.artifactURLs
        )
    }
}

@MainActor
private struct ProductionStrokeRuntimeTraceRunner {
    let device: any MTLDevice

    func run(
        profile: StrokeRuntimeTraceProfile
    ) throws -> StrokeRuntimeTelemetrySnapshot {
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.defaultLibraryUnavailable
        }
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 512, height: 512),
            configuration: try TilingCanvasConfiguration(
                pixelSize: PixelSize(width: 512, height: 512),
                tiling: .grid
            )
        )
        try renderer.installNativeHarnessBrushes()
        renderer.configureStrokeRuntimeTelemetry(
            profile: profile,
            windowCapacity: 4_096
        )
        let token = RendererOperationToken(rawValue: 0x5452_4143_45)
        let style = try renderer.nativeHarnessStrokeStyle(
            color: .black,
            diameter: 20,
            seed: token.rawValue
        )
        let started = DispatchTime.now().uptimeNanoseconds
        try renderer.beginStroke(
            token: token,
            sample: sample(
                x: 96,
                y: 256,
                timestamp: 0,
                phase: .began
            ),
            style: style
        )
        _ = try renderer.flushPendingLiveForHarness()

        var frame: UInt64 = 1
        while DispatchTime.now().uptimeNanoseconds - started
            < profile.requiredWallDurationNanoseconds
        {
            let phase = Float(frame % 320) / 319
            let x = frame / 320 % 2 == 0
                ? 96 + phase * 320
                : 416 - phase * 320
            try renderer.appendStroke(
                token: token,
                sample: sample(
                    x: x,
                    y: 256 + sin(Float(frame) * 0.05) * 48,
                    timestamp: Double(frame) / 60,
                    phase: .moved
                )
            )
            _ = try renderer.flushPendingLiveForHarness()
            frame &+= 1
            usleep(16_000)
        }

        try renderer.requestStrokeCommit(
            token: token,
            sample: sample(
                x: 416,
                y: 256,
                timestamp: Double(frame) / 60,
                phase: .ended
            ),
            maximumRetainedBytes: 64 * 1_024 * 1_024
        )
        while renderer.brushLabDiagnosticSnapshot.deposition
            .authoritativePending > 0
        {
            _ = try renderer.flushPendingLiveForHarness()
        }
        _ = try renderer.flushPendingLiveForHarness()
        _ = try renderer.finishCommitForHarness()
        guard let evidence = renderer.strokeRuntimeRecordedEvidence else {
            throw HarnessLaunchError.missingProductionRuntimeTrace(
                profile.rawValue
            )
        }
        try BenchmarkStrokeRuntimeGate.validate(
            evidence,
            replayMode: .appendOnly
        )
        return evidence.report
    }

    private func sample(
        x: Float,
        y: Float,
        timestamp: TimeInterval,
        phase: StrokePhase
    ) -> StrokeSample {
        StrokeSample(
            position: ScreenPoint(x: x, y: y),
            pressure: 0.75,
            timestamp: timestamp,
            phase: phase,
            source: .mouse,
            kind: .actual,
            capabilities: [.pressure]
        )
    }
}

enum HarnessLaunchError: Error, LocalizedError {
    case missingArgument(String)
    case metalUnavailable
    case invalidPerformanceTrace(String)
    case missingProductionRuntimeTrace(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(flag):
            "Missing required harness argument \(flag)."
        case .metalUnavailable:
            "Metal is unavailable."
        case let .invalidPerformanceTrace(value):
            "Unknown performance trace '\(value)'; expected '10-second' or 'accelerated-10-minute'."
        case let .missingProductionRuntimeTrace(profile):
            "Harness result did not contain attributable production runtime telemetry for '\(profile)'."
        }
    }
}
