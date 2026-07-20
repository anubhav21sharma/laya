import Darwin
import CShaderTypes
import Foundation
import Metal
import PatternEngine

public enum SliceThreeHarnessRunError: Error, Equatable, LocalizedError {
    case structuralMismatch(
        sceneName: String,
        metric: HarnessStructuralMetric,
        expectedRelation: HarnessRelation,
        expectedValue: Int,
        actualValue: Int
    )
    case invariant(sceneName: String, message: String)
    case missingCompletion(sceneName: String, token: RendererOperationToken)
    case unexpectedCompletion(sceneName: String, token: RendererOperationToken)
    case missingArtifact(sceneName: String, channel: HarnessPixelChannel)
    case pixelMismatch(
        sceneName: String,
        channel: HarnessPixelChannel,
        x: Int,
        y: Int,
        expected: [UInt8],
        actual: [UInt8],
        tolerance: UInt8
    )

    public var errorDescription: String? {
        switch self {
        case let .structuralMismatch(
            sceneName,
            metric,
            relation,
            expected,
            actual
        ):
            "Slice 3 scene '\(sceneName)' metric \(metric.rawValue): expected \(relation.rawValue) \(expected), actual \(actual)."
        case let .invariant(sceneName, message):
            "Slice 3 scene '\(sceneName)' invariant failed: \(message)."
        case let .missingCompletion(sceneName, token):
            "Slice 3 scene '\(sceneName)' did not receive completion token \(token.rawValue)."
        case let .unexpectedCompletion(sceneName, token):
            "Slice 3 scene '\(sceneName)' received the wrong completion for token \(token.rawValue)."
        case let .missingArtifact(sceneName, channel):
            "Slice 3 scene '\(sceneName)' is missing artifact channel \(channel.rawValue)."
        case let .pixelMismatch(
            sceneName,
            channel,
            x,
            y,
            expected,
            actual,
            tolerance
        ):
            "Slice 3 scene '\(sceneName)' channel \(channel.rawValue) pixel mismatch at (\(x), \(y)): expected \(expected), actual \(actual), tolerance \(tolerance)."
        }
    }
}

@MainActor
public final class SliceThreeHarnessRunner {
    private static let historyLimitBytes = 200 * 1_024 * 1_024
    private static let displayFrameBudgetMilliseconds = 1_000.0 / 60.0

    private struct Measurements {
        var cpuEncodeMilliseconds: [Double] = []
        var gpuMilliseconds: [Double] = []
        var brushProcessingMilliseconds: [Double] = []
        var eventToSubmitMilliseconds: [Double] = []
        var dabGPUMilliseconds: [Double] = []
        var gridGPUMilliseconds: [Double] = []
        var commitGPUMilliseconds: [Double] = []
        var revisionCaptureMilliseconds: [Double] = []
        var revisionRestoreMilliseconds: [Double] = []

        mutating func append(
            _ metrics: GPUFrameMetrics,
            category: FrameCategory
        ) {
            cpuEncodeMilliseconds.append(metrics.cpuEncodeMilliseconds)
            gpuMilliseconds.append(metrics.gpuMilliseconds)
            switch category {
            case .dab:
                dabGPUMilliseconds.append(metrics.gpuMilliseconds)
            case .grid:
                gridGPUMilliseconds.append(metrics.gpuMilliseconds)
            case .commit:
                commitGPUMilliseconds.append(metrics.gpuMilliseconds)
            }
        }
    }

    private enum FrameCategory {
        case dab
        case grid
        case commit
    }

    private struct Artifact {
        let suffix: String
        let texture: any MTLTexture
    }

    private struct ScenarioResult {
        let primary: any MTLTexture
        let live: (any MTLTexture)?
        let committed: (any MTLTexture)?
        let canonical: any MTLTexture
        let artifacts: [Artifact]
        let structuralValues: [HarnessStructuralMetric: Int]
        let historyCommandCount: Int
        let historyResidentBytes: Int
        let changedRegionCount: Int
        let projectedFragmentCount: Int
    }

    private struct StrokeResult {
        let receipt: RasterMutationReceipt
        let live: (any MTLTexture)?
        let committed: any MTLTexture
        let canonical: any MTLTexture
    }

    private final class CompletionQueue {
        var values: [RendererOperationCompletion] = []

        func takeReceipt(
            sceneName: String,
            token: RendererOperationToken
        ) throws -> RasterMutationReceipt {
            guard !values.isEmpty else {
                throw SliceThreeHarnessRunError.missingCompletion(
                    sceneName: sceneName,
                    token: token
                )
            }
            let completion = values.removeFirst()
            guard case let .rasterSuccess(receipt) = completion,
                  receipt.token == token
            else {
                throw SliceThreeHarnessRunError.unexpectedCompletion(
                    sceneName: sceneName,
                    token: token
                )
            }
            return receipt
        }

        func takeOperationSuccess(
            sceneName: String,
            token: RendererOperationToken
        ) throws {
            guard !values.isEmpty else {
                throw SliceThreeHarnessRunError.missingCompletion(
                    sceneName: sceneName,
                    token: token
                )
            }
            let completion = values.removeFirst()
            guard case let .operationSuccess(completedToken) = completion,
                  completedToken == token
            else {
                throw SliceThreeHarnessRunError.unexpectedCompletion(
                    sceneName: sceneName,
                    token: token
                )
            }
        }
    }

    private let device: any MTLDevice
    private let library: any MTLLibrary
    private var nextTokenRawValue: UInt64 = 1

    init(device: any MTLDevice, library: any MTLLibrary) {
        self.device = device
        self.library = library
    }

    public func run(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) throws -> HarnessRunResult {
        guard scene.schemaVersion == 4, let program = scene.program,
              program.isSliceThreeProgram
        else {
            throw HarnessSceneError.unsupportedSchema(scene.schemaVersion)
        }
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let renderer = try makeRenderer(scene: scene)
        let completions = CompletionQueue()
        renderer.onOperationCompleted = { completions.values.append($0) }
        var measurements = Measurements()

        let result: ScenarioResult
        switch program {
        case .coloredDraw:
            result = try runColoredDraw(
                scene: scene,
                renderer: renderer,
                completions: completions,
                measurements: &measurements
            )
        case .eraserLiveCommit:
            result = try runEraserLiveCommit(
                scene: scene,
                renderer: renderer,
                completions: completions,
                measurements: &measurements
            )
        case .regionUndoSeam:
            result = try runRegionUndoSeam(
                scene: scene,
                renderer: renderer,
                completions: completions,
                measurements: &measurements
            )
        case .clearUndo:
            result = try runClearUndo(
                scene: scene,
                renderer: renderer,
                completions: completions,
                measurements: &measurements
            )
        case .tilingUndo:
            result = try runTilingUndo(
                scene: scene,
                renderer: renderer,
                completions: completions,
                measurements: &measurements
            )
        case .resizeCropFill:
            result = try runResizeCropFill(
                scene: scene,
                renderer: renderer,
                completions: completions,
                measurements: &measurements
            )
        default:
            throw HarnessSceneError.programUnavailableForSchema(
                program: program,
                schemaVersion: scene.schemaVersion
            )
        }

        let processInfo = ProcessInfo.processInfo
        let record = BenchmarkRecord(
            schemaVersion: 4,
            timestampUTC: ISO8601DateFormatter().string(from: Date()),
            sceneName: scene.name,
            hardware: BenchmarkHardware(
                gpuName: device.name,
                logicalProcessorCount: processInfo.activeProcessorCount,
                physicalMemoryBytes: processInfo.physicalMemory
            ),
            operatingSystem: processInfo.operatingSystemVersionString,
            build: build,
            frameCount: measurements.cpuEncodeMilliseconds.count,
            cpuEncodeMilliseconds: measurements.cpuEncodeMilliseconds,
            gpuMilliseconds: measurements.gpuMilliseconds,
            peakResidentBytes: try Self.peakResidentBytes(),
            brushProcessingMilliseconds:
                measurements.brushProcessingMilliseconds,
            eventToSubmitMilliseconds:
                measurements.eventToSubmitMilliseconds,
            dabGPUMilliseconds: measurements.dabGPUMilliseconds,
            gridGPUMilliseconds: measurements.gridGPUMilliseconds,
            commitGPUMilliseconds: measurements.commitGPUMilliseconds,
            displayFrameBudgetMilliseconds:
                Self.displayFrameBudgetMilliseconds,
            missedFrameCount: measurements.eventToSubmitMilliseconds
                .filter { $0 > Self.displayFrameBudgetMilliseconds }.count,
            tilingRawValue: scene.tiling?.rawValue,
            tileWidth: scene.tileWidth,
            tileHeight: scene.tileHeight,
            totalProjectedFragmentCount: result.projectedFragmentCount,
            maximumFragmentsPerFootprint:
                result.projectedFragmentCount,
            totalInstanceBytes: result.projectedFragmentCount
                * MemoryLayout<PatternProjectedStampInstance>.stride,
            diagnosticMode: scene.diagnosticMode?.rawValue,
            revisionCaptureMilliseconds:
                measurements.revisionCaptureMilliseconds,
            revisionRestoreMilliseconds:
                measurements.revisionRestoreMilliseconds,
            historyResidentBytes: result.historyResidentBytes,
            historyCommandCount: result.historyCommandCount,
            changedRegionCount: result.changedRegionCount,
            program: program.rawValue
        )

        var artifactURLs: [URL] = []
        for artifact in result.artifacts {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).\(artifact.suffix)"
            )
            try PNGWriter.write(texture: artifact.texture, to: url)
            artifactURLs.append(url)
        }
        let benchmarkURL = outputDirectory.appendingPathComponent(
            "\(scene.name).benchmark.json"
        )
        try BenchmarkRecord.encode(record).write(
            to: benchmarkURL,
            options: .atomic
        )
        artifactURLs.append(benchmarkURL)

        try evaluatePixelChecks(scene: scene, result: result)
        try Self.evaluateStructuralChecks(
            scene: scene,
            values: result.structuralValues
        )

        guard let primaryURL = artifactURLs.first else {
            throw SliceThreeHarnessRunError.missingArtifact(
                sceneName: scene.name,
                channel: .screen
            )
        }
        return HarnessRunResult(
            imageURL: primaryURL,
            benchmarkURL: benchmarkURL,
            benchmark: record,
            artifactURLs: artifactURLs
        )
    }

    private func runColoredDraw(
        scene: HarnessScene,
        renderer: GridRenderer,
        completions: CompletionQueue,
        measurements: inout Measurements
    ) throws -> ScenarioResult {
        let before = try renderer.copyCanonicalForHarness()
        let color = InkColor(
            red: 0.8,
            green: 0.4,
            blue: 0.2,
            alpha: 0.75
        )!
        let stroke = try commitStroke(
            scene: scene,
            renderer: renderer,
            completions: completions,
            point: centerPoint(scene),
            style: StrokeRenderStyle(
                color: color,
                diameter: 20,
                compositeMode: .draw,
                eraserStrength: 1
            ),
            capturesLive: true,
            measurements: &measurements
        )
        let center = pixel(
            in: stroke.canonical,
            x: renderer.pixelSize.width / 2,
            y: renderer.pixelSize.height / 2
        )
        let expected = [
            unorm(color.blue * color.alpha),
            unorm(color.green * color.alpha),
            unorm(color.red * color.alpha),
            unorm(color.alpha),
        ]
        guard zip(center, expected).allSatisfy({
            abs(Int($0.0) - Int($0.1)) <= 1
        }), center[0] > 0, center[1] > 0, center[2] > 0,
            center[3] > 0, center[3] < 255
        else {
            throw SliceThreeHarnessRunError.invariant(
                sceneName: scene.name,
                message: "colored canonical center \(center) does not match nonblack premultiplied BGRA \(expected)"
            )
        }

        let undone = try restore(
            scene: scene,
            renderer: renderer,
            completions: completions,
            revision: stroke.receipt.before,
            measurements: &measurements
        )
        let redone = try restore(
            scene: scene,
            renderer: renderer,
            completions: completions,
            revision: stroke.receipt.after,
            measurements: &measurements
        )
        let undoDelta = differingByteCount(before, undone)
        let redoDelta = differingByteCount(stroke.canonical, redone)
        try requireZero(
            undoDelta,
            scene: scene,
            message: "colored draw undo did not restore the blank canonical raster"
        )
        try requireZero(
            redoDelta,
            scene: scene,
            message: "colored draw redo did not restore committed bytes"
        )
        let live = stroke.live!
        return ScenarioResult(
            primary: stroke.committed,
            live: live,
            committed: stroke.committed,
            canonical: redone,
            artifacts: [
                Artifact(suffix: "live.screen.png", texture: live),
                Artifact(suffix: "committed.screen.png", texture: stroke.committed),
                Artifact(suffix: "undone.canonical.png", texture: undone),
                Artifact(suffix: "redone.canonical.png", texture: redone),
                Artifact(suffix: "canonical.png", texture: redone),
            ],
            structuralValues: structuralValues(
                renderer: renderer,
                historyCommandCount: 1,
                changedRegionCount:
                    stroke.receipt.before.regions.rectangles.count,
                extras: [
                    .undoCanonicalByteDelta: undoDelta,
                    .redoCanonicalByteDelta: redoDelta,
                ]
            ),
            historyCommandCount: 1,
            historyResidentBytes: renderer.harnessRasterRevisionResidentBytes,
            changedRegionCount:
                stroke.receipt.before.regions.rectangles.count,
            projectedFragmentCount: renderer.harnessCounters
                .totalInstancesThisStroke
        )
    }

    private func runEraserLiveCommit(
        scene: HarnessScene,
        renderer: GridRenderer,
        completions: CompletionQueue,
        measurements: inout Measurements
    ) throws -> ScenarioResult {
        let point = centerPoint(scene)
        let seed = try commitStroke(
            scene: scene,
            renderer: renderer,
            completions: completions,
            point: point,
            style: drawStyle,
            capturesLive: false,
            measurements: &measurements
        )
        let erase = try commitStroke(
            scene: scene,
            renderer: renderer,
            completions: completions,
            point: point,
            style: StrokeRenderStyle(
                color: InkColor(
                    red: 0.2,
                    green: 0.8,
                    blue: 0.4,
                    alpha: 0.5
                )!,
                diameter: 20,
                compositeMode: .erase,
                eraserStrength: 1
            ),
            capturesLive: true,
            measurements: &measurements
        )
        let live = erase.live!
        let previewDelta = maximumByteDelta(live, erase.committed)
        guard previewDelta <= 1 else {
            throw SliceThreeHarnessRunError.invariant(
                sceneName: scene.name,
                message: "eraser live/commit maximum delta \(previewDelta) exceeds 1"
            )
        }
        let center = pixel(
            in: erase.canonical,
            x: renderer.pixelSize.width / 2,
            y: renderer.pixelSize.height / 2
        )
        guard center == [0, 0, 0, 0] else {
            throw SliceThreeHarnessRunError.invariant(
                sceneName: scene.name,
                message: "destination-out center is \(center) instead of transparent"
            )
        }
        let undone = try restore(
            scene: scene,
            renderer: renderer,
            completions: completions,
            revision: erase.receipt.before,
            measurements: &measurements
        )
        let redone = try restore(
            scene: scene,
            renderer: renderer,
            completions: completions,
            revision: erase.receipt.after,
            measurements: &measurements
        )
        let undoDelta = differingByteCount(seed.canonical, undone)
        let redoDelta = differingByteCount(erase.canonical, redone)
        try requireZero(
            undoDelta + redoDelta,
            scene: scene,
            message: "eraser undo/redo did not restore exact canonical bytes"
        )
        let count = erase.receipt.before.regions.rectangles.count
        return ScenarioResult(
            primary: erase.committed,
            live: live,
            committed: erase.committed,
            canonical: redone,
            artifacts: [
                Artifact(suffix: "live.screen.png", texture: live),
                Artifact(suffix: "committed.screen.png", texture: erase.committed),
                Artifact(suffix: "undone.canonical.png", texture: undone),
                Artifact(suffix: "redone.canonical.png", texture: redone),
                Artifact(suffix: "canonical.png", texture: redone),
            ],
            structuralValues: structuralValues(
                renderer: renderer,
                historyCommandCount: 2,
                changedRegionCount: count,
                extras: [
                    .previewCommitMaximumDelta: previewDelta,
                    .undoCanonicalByteDelta: undoDelta,
                    .redoCanonicalByteDelta: redoDelta,
                ]
            ),
            historyCommandCount: 2,
            historyResidentBytes: renderer.harnessRasterRevisionResidentBytes,
            changedRegionCount: count,
            projectedFragmentCount: renderer.harnessCounters
                .totalInstancesThisStroke
        )
    }

    private func runRegionUndoSeam(
        scene: HarnessScene,
        renderer: GridRenderer,
        completions: CompletionQueue,
        measurements: inout Measurements
    ) throws -> ScenarioResult {
        let before = try renderer.copyCanonicalForHarness()
        let stroke = try commitStroke(
            scene: scene,
            renderer: renderer,
            completions: completions,
            point: ScreenPoint(x: 0, y: Float(scene.height) * 0.5),
            style: StrokeRenderStyle(
                color: .black,
                diameter: 12,
                compositeMode: .draw,
                eraserStrength: 1
            ),
            capturesLive: true,
            measurements: &measurements
        )
        let changedRegions = stroke.receipt.before.regions.rectangles.count
        guard changedRegions == 2 else {
            throw SliceThreeHarnessRunError.invariant(
                sceneName: scene.name,
                message: "seam edit retained \(changedRegions) changed regions instead of 2"
            )
        }
        let undone = try restore(
            scene: scene,
            renderer: renderer,
            completions: completions,
            revision: stroke.receipt.before,
            measurements: &measurements
        )
        let redone = try restore(
            scene: scene,
            renderer: renderer,
            completions: completions,
            revision: stroke.receipt.after,
            measurements: &measurements
        )
        let undoDelta = differingByteCount(before, undone)
        let redoDelta = differingByteCount(stroke.canonical, redone)
        try requireZero(
            undoDelta + redoDelta,
            scene: scene,
            message: "seam undo/redo changed canonical bytes"
        )
        let live = stroke.live!
        return ScenarioResult(
            primary: stroke.committed,
            live: live,
            committed: stroke.committed,
            canonical: redone,
            artifacts: [
                Artifact(suffix: "live.screen.png", texture: live),
                Artifact(suffix: "committed.screen.png", texture: stroke.committed),
                Artifact(suffix: "undone.canonical.png", texture: undone),
                Artifact(suffix: "redone.canonical.png", texture: redone),
                Artifact(suffix: "canonical.png", texture: redone),
            ],
            structuralValues: structuralValues(
                renderer: renderer,
                historyCommandCount: 1,
                changedRegionCount: changedRegions,
                extras: [
                    .undoCanonicalByteDelta: undoDelta,
                    .redoCanonicalByteDelta: redoDelta,
                ]
            ),
            historyCommandCount: 1,
            historyResidentBytes: renderer.harnessRasterRevisionResidentBytes,
            changedRegionCount: changedRegions,
            projectedFragmentCount: renderer.harnessCounters
                .totalInstancesThisStroke
        )
    }

    private func runClearUndo(
        scene: HarnessScene,
        renderer: GridRenderer,
        completions: CompletionQueue,
        measurements: inout Measurements
    ) throws -> ScenarioResult {
        let seed = try commitStroke(
            scene: scene,
            renderer: renderer,
            completions: completions,
            point: centerPoint(scene),
            style: drawStyle,
            capturesLive: false,
            measurements: &measurements
        )
        let token = takeToken()
        let start = CFAbsoluteTimeGetCurrent()
        try renderer.requestClear(
            token: token,
            maximumRetainedBytes: Self.historyLimitBytes
        )
        try renderer.finishRasterOperationForHarness()
        measurements.revisionCaptureMilliseconds.append(
            elapsedMilliseconds(since: start)
        )
        let receipt = try completions.takeReceipt(
            sceneName: scene.name,
            token: token
        )
        let cleared = try renderer.copyCanonicalForHarness()
        guard textureBytes(cleared).allSatisfy({ $0 == 0 }) else {
            throw SliceThreeHarnessRunError.invariant(
                sceneName: scene.name,
                message: "clear did not produce a transparent canonical raster"
            )
        }
        let clearedScreen = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        let undone = try restore(
            scene: scene,
            renderer: renderer,
            completions: completions,
            revision: receipt.before,
            measurements: &measurements
        )
        let redone = try restore(
            scene: scene,
            renderer: renderer,
            completions: completions,
            revision: receipt.after,
            measurements: &measurements
        )
        let undoDelta = differingByteCount(seed.canonical, undone)
        let redoDelta = differingByteCount(cleared, redone)
        try requireZero(
            undoDelta + redoDelta,
            scene: scene,
            message: "clear undo/redo did not restore exact canonical bytes"
        )
        let count = receipt.before.regions.rectangles.count
        guard count == 1 else {
            throw SliceThreeHarnessRunError.invariant(
                sceneName: scene.name,
                message: "clear retained \(count) regions instead of one full raster"
            )
        }
        return ScenarioResult(
            primary: clearedScreen,
            live: nil,
            committed: clearedScreen,
            canonical: redone,
            artifacts: [
                Artifact(suffix: "committed.screen.png", texture: clearedScreen),
                Artifact(suffix: "before-clear.canonical.png", texture: seed.canonical),
                Artifact(suffix: "cleared.canonical.png", texture: cleared),
                Artifact(suffix: "undone.canonical.png", texture: undone),
                Artifact(suffix: "redone.canonical.png", texture: redone),
                Artifact(suffix: "canonical.png", texture: redone),
            ],
            structuralValues: structuralValues(
                renderer: renderer,
                historyCommandCount: 2,
                changedRegionCount: count,
                extras: [
                    .undoCanonicalByteDelta: undoDelta,
                    .redoCanonicalByteDelta: redoDelta,
                ]
            ),
            historyCommandCount: 2,
            historyResidentBytes: renderer.harnessRasterRevisionResidentBytes,
            changedRegionCount: count,
            projectedFragmentCount: renderer.harnessCounters
                .totalInstancesThisStroke
        )
    }

    private func runTilingUndo(
        scene: HarnessScene,
        renderer: GridRenderer,
        completions: CompletionQueue,
        measurements: inout Measurements
    ) throws -> ScenarioResult {
        _ = try commitStroke(
            scene: scene,
            renderer: renderer,
            completions: completions,
            point: ScreenPoint(
                x: Float(scene.width) * 0.31,
                y: Float(scene.height) * 0.43
            ),
            style: drawStyle,
            capturesLive: false,
            measurements: &measurements
        )
        let canonicalBefore = try renderer.copyCanonicalForHarness()
        let initialScreen = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        let originalTiling = renderer.tiling
        let alternateTiling: TilingKind = originalTiling == .mirrorXY
            ? .grid
            : .mirrorXY
        try renderer.applyTiling(alternateTiling)
        let alternateScreen = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        let canonicalAfterChange = try renderer.copyCanonicalForHarness()
        try renderer.applyTiling(originalTiling)
        let restoredScreen = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        let canonicalAfterUndo = try renderer.copyCanonicalForHarness()
        try renderer.applyTiling(alternateTiling)
        let redoneScreen = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        let canonicalAfterRedo = try renderer.copyCanonicalForHarness()
        try renderer.applyTiling(originalTiling)

        let metadataDelta = differingByteCount(
            canonicalBefore,
            canonicalAfterChange
        ) + differingByteCount(canonicalBefore, canonicalAfterUndo)
            + differingByteCount(canonicalBefore, canonicalAfterRedo)
        let restoredDelta = maximumByteDelta(initialScreen, restoredScreen)
        let redoneDelta = maximumByteDelta(alternateScreen, redoneScreen)
        let changedDisplay = differingByteCount(initialScreen, alternateScreen)
        guard metadataDelta == 0, restoredDelta == 0, redoneDelta == 0,
              changedDisplay > 0
        else {
            throw SliceThreeHarnessRunError.invariant(
                sceneName: scene.name,
                message: "tiling undo/redo did not preserve canonical bytes and restore exact displays"
            )
        }
        return ScenarioResult(
            primary: restoredScreen,
            live: nil,
            committed: restoredScreen,
            canonical: canonicalAfterUndo,
            artifacts: [
                Artifact(suffix: "initial-tiling.screen.png", texture: initialScreen),
                Artifact(suffix: "alternate-tiling.screen.png", texture: alternateScreen),
                Artifact(suffix: "restored-tiling.screen.png", texture: restoredScreen),
                Artifact(suffix: "redone-tiling.screen.png", texture: redoneScreen),
                Artifact(suffix: "canonical.png", texture: canonicalAfterUndo),
            ],
            structuralValues: structuralValues(
                renderer: renderer,
                historyCommandCount: 2,
                changedRegionCount: 0,
                extras: [
                    .metadataCanonicalByteDelta: metadataDelta,
                    .restoredDisplayMaximumDelta: restoredDelta,
                    .redoCanonicalByteDelta: redoneDelta,
                ]
            ),
            historyCommandCount: 2,
            historyResidentBytes: renderer.harnessRasterRevisionResidentBytes,
            changedRegionCount: 0,
            projectedFragmentCount: renderer.harnessCounters
                .totalInstancesThisStroke
        )
    }

    private func runResizeCropFill(
        scene: HarnessScene,
        renderer: GridRenderer,
        completions: CompletionQueue,
        measurements: inout Measurements
    ) throws -> ScenarioResult {
        let originalSize = renderer.pixelSize
        guard originalSize.width >= 96, originalSize.height >= 80 else {
            throw SliceThreeHarnessRunError.invariant(
                sceneName: scene.name,
                message: "resize scene requires at least a 96x80 starting tile"
            )
        }
        let originalBytes = deterministicPixels(originalSize)
        try renderer.replaceCanonicalPixelsForHarness(originalBytes)
        let original = try renderer.copyCanonicalForHarness()
        let shrinkSize = PixelSize(width: 64, height: 72)
        let shrinkReceipt = try resize(
            scene: scene,
            renderer: renderer,
            completions: completions,
            to: shrinkSize,
            measurements: &measurements
        )
        let shrunk = try renderer.copyCanonicalForHarness()
        let expectedShrunk = croppedOrFilled(
            originalBytes,
            from: originalSize,
            to: shrinkSize
        )
        guard textureBytes(shrunk) == expectedShrunk else {
            throw SliceThreeHarnessRunError.invariant(
                sceneName: scene.name,
                message: "shrink did not crop only the right and bottom"
            )
        }

        let growSize = PixelSize(width: 96, height: 96)
        let growReceipt = try resize(
            scene: scene,
            renderer: renderer,
            completions: completions,
            to: growSize,
            measurements: &measurements
        )
        let grown = try renderer.copyCanonicalForHarness()
        let expectedGrown = croppedOrFilled(
            expectedShrunk,
            from: shrinkSize,
            to: growSize
        )
        guard textureBytes(grown) == expectedGrown else {
            throw SliceThreeHarnessRunError.invariant(
                sceneName: scene.name,
                message: "growth did not preserve the top-left intersection and transparent-fill the right and bottom"
            )
        }

        _ = try resizeRestore(
            scene: scene,
            renderer: renderer,
            completions: completions,
            revision: growReceipt.before,
            measurements: &measurements
        )
        let undoShrink = try resizeRestore(
            scene: scene,
            renderer: renderer,
            completions: completions,
            revision: shrinkReceipt.before,
            measurements: &measurements
        )
        let restoredWidth = renderer.pixelSize.width
        let restoredHeight = renderer.pixelSize.height
        _ = try resizeRestore(
            scene: scene,
            renderer: renderer,
            completions: completions,
            revision: shrinkReceipt.after,
            measurements: &measurements
        )
        let redone = try resizeRestore(
            scene: scene,
            renderer: renderer,
            completions: completions,
            revision: growReceipt.after,
            measurements: &measurements
        )
        let undoDelta = differingByteCount(original, undoShrink)
        let redoDelta = differingByteCount(grown, redone)
        guard restoredWidth == originalSize.width,
              restoredHeight == originalSize.height,
              renderer.pixelSize == growSize,
              undoDelta == 0, redoDelta == 0
        else {
            throw SliceThreeHarnessRunError.invariant(
                sceneName: scene.name,
                message: "resize undo/redo did not restore exact dimensions and bytes"
            )
        }
        let committed = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        let regionCount = shrinkReceipt.before.regions.rectangles.count
            + growReceipt.before.regions.rectangles.count
        return ScenarioResult(
            primary: committed,
            live: nil,
            committed: committed,
            canonical: redone,
            artifacts: [
                Artifact(suffix: "committed.screen.png", texture: committed),
                Artifact(suffix: "original.canonical.png", texture: original),
                Artifact(suffix: "shrunk.canonical.png", texture: shrunk),
                Artifact(suffix: "grown.canonical.png", texture: grown),
                Artifact(suffix: "undone.canonical.png", texture: undoShrink),
                Artifact(suffix: "redone.canonical.png", texture: redone),
                Artifact(suffix: "canonical.png", texture: redone),
            ],
            structuralValues: structuralValues(
                renderer: renderer,
                historyCommandCount: 2,
                changedRegionCount: regionCount,
                extras: [
                    .undoCanonicalByteDelta: undoDelta,
                    .redoCanonicalByteDelta: redoDelta,
                    .restoredWidth: restoredWidth,
                    .restoredHeight: restoredHeight,
                ]
            ),
            historyCommandCount: 2,
            historyResidentBytes: renderer.harnessRasterRevisionResidentBytes,
            changedRegionCount: regionCount,
            projectedFragmentCount: 0
        )
    }

    private func commitStroke(
        scene: HarnessScene,
        renderer: GridRenderer,
        completions: CompletionQueue,
        point: ScreenPoint,
        style: StrokeRenderStyle,
        capturesLive: Bool,
        measurements: inout Measurements
    ) throws -> StrokeResult {
        let token = takeToken()
        var timestamp = 0.0
        var processingStart = CFAbsoluteTimeGetCurrent()
        try renderer.beginStroke(
            token: token,
            sample: .mouse(
                position: point,
                timestamp: timestamp,
                phase: .began
            ),
            style: style
        )
        measurements.brushProcessingMilliseconds.append(
            elapsedMilliseconds(since: processingStart)
        )
        timestamp += 1.0 / 120.0
        processingStart = CFAbsoluteTimeGetCurrent()
        try renderer.requestStrokeCommit(
            token: token,
            sample: .mouse(
                position: point,
                timestamp: timestamp,
                phase: .ended
            ),
            maximumRetainedBytes: Self.historyLimitBytes
        )
        let eventDuration = elapsedMilliseconds(since: processingStart)
        measurements.brushProcessingMilliseconds.append(eventDuration)

        let flush = try renderer.flushPendingLiveForHarness()
        measurements.eventToSubmitMilliseconds.append(
            HarnessSubmissionTiming.eventToSubmitMilliseconds(
                eventProcessingMilliseconds: eventDuration,
                flushThroughSubmissionMilliseconds:
                    flush.metrics.cpuEncodeMilliseconds
            )
        )
        measurements.append(flush.metrics, category: .dab)
        let live = capturesLive
            ? try captureDisplay(
                scene: scene,
                renderer: renderer,
                measurements: &measurements
            )
            : nil
        let captureStart = CFAbsoluteTimeGetCurrent()
        let commit = try renderer.finishCommitForHarness()
        measurements.revisionCaptureMilliseconds.append(
            elapsedMilliseconds(since: captureStart)
        )
        measurements.append(commit, category: .commit)
        let receipt = try completions.takeReceipt(
            sceneName: scene.name,
            token: token
        )
        let committed = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        let canonical = try renderer.copyCanonicalForHarness()
        return StrokeResult(
            receipt: receipt,
            live: live,
            committed: committed,
            canonical: canonical
        )
    }

    private func restore(
        scene: HarnessScene,
        renderer: GridRenderer,
        completions: CompletionQueue,
        revision: RasterRevisionReference,
        measurements: inout Measurements
    ) throws -> any MTLTexture {
        let token = takeToken()
        let start = CFAbsoluteTimeGetCurrent()
        try renderer.requestRasterRestore(token: token, revision: revision)
        try renderer.finishRasterOperationForHarness()
        measurements.revisionRestoreMilliseconds.append(
            elapsedMilliseconds(since: start)
        )
        try completions.takeOperationSuccess(
            sceneName: scene.name,
            token: token
        )
        return try renderer.copyCanonicalForHarness()
    }

    private func resize(
        scene: HarnessScene,
        renderer: GridRenderer,
        completions: CompletionQueue,
        to pixelSize: PixelSize,
        measurements: inout Measurements
    ) throws -> RasterMutationReceipt {
        let token = takeToken()
        let start = CFAbsoluteTimeGetCurrent()
        try renderer.requestResize(
            token: token,
            to: pixelSize,
            maximumRetainedBytes: Self.historyLimitBytes
        )
        try renderer.finishRasterOperationForHarness()
        measurements.revisionCaptureMilliseconds.append(
            elapsedMilliseconds(since: start)
        )
        return try completions.takeReceipt(sceneName: scene.name, token: token)
    }

    private func resizeRestore(
        scene: HarnessScene,
        renderer: GridRenderer,
        completions: CompletionQueue,
        revision: RasterRevisionReference,
        measurements: inout Measurements
    ) throws -> any MTLTexture {
        let token = takeToken()
        let start = CFAbsoluteTimeGetCurrent()
        try renderer.requestResizeRestore(token: token, revision: revision)
        try renderer.finishRasterOperationForHarness()
        measurements.revisionRestoreMilliseconds.append(
            elapsedMilliseconds(since: start)
        )
        try completions.takeOperationSuccess(
            sceneName: scene.name,
            token: token
        )
        return try renderer.copyCanonicalForHarness()
    }

    private func captureDisplay(
        scene: HarnessScene,
        renderer: GridRenderer,
        measurements: inout Measurements
    ) throws -> any MTLTexture {
        let frame = try renderer.renderOffscreenDisplayForHarness(
            width: scene.width,
            height: scene.height,
            showGridLines: false
        )
        measurements.append(frame.metrics, category: .grid)
        return frame.texture
    }

    private func makeRenderer(scene: HarnessScene) throws -> GridRenderer {
        guard let width = scene.tileWidth, let height = scene.tileHeight,
              let tiling = scene.tiling
        else {
            throw HarnessSceneError.missingSchemaFourField("tileWidth")
        }
        return try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(
                width: Float(scene.width),
                height: Float(scene.height)
            ),
            configuration: TilingCanvasConfiguration(
                pixelSize: PixelSize(width: width, height: height),
                tiling: tiling
            )
        )
    }

    private var drawStyle: StrokeRenderStyle {
        StrokeRenderStyle(
            color: .black,
            diameter: 20,
            compositeMode: .draw,
            eraserStrength: 1
        )
    }

    private func centerPoint(_ scene: HarnessScene) -> ScreenPoint {
        ScreenPoint(
            x: Float(scene.width) * 0.5,
            y: Float(scene.height) * 0.5
        )
    }

    private func takeToken() -> RendererOperationToken {
        let token = RendererOperationToken(rawValue: nextTokenRawValue)
        nextTokenRawValue &+= 1
        precondition(nextTokenRawValue != 0)
        return token
    }

    private func structuralValues(
        renderer: GridRenderer,
        historyCommandCount: Int,
        changedRegionCount: Int,
        extras: [HarnessStructuralMetric: Int]
    ) -> [HarnessStructuralMetric: Int] {
        var values = extras
        values[.historyCommandCount] = historyCommandCount
        values[.historyResidentBytes] =
            renderer.harnessRasterRevisionResidentBytes
        values[.changedRegionCount] = changedRegionCount
        return values
    }

    private func evaluatePixelChecks(
        scene: HarnessScene,
        result: ScenarioResult
    ) throws {
        for check in scene.checks {
            let texture: (any MTLTexture)?
            switch check.channel {
            case .screen:
                texture = result.primary
            case .liveScreen:
                texture = result.live
            case .committedScreen:
                texture = result.committed
            case .canonical:
                texture = result.canonical
            case .oracleCoverage, .oracleCanonicalCoordinates,
                 .oracleBrushLocalCoordinates:
                texture = nil
            }
            guard let texture else {
                throw SliceThreeHarnessRunError.missingArtifact(
                    sceneName: scene.name,
                    channel: check.channel
                )
            }
            guard (0..<texture.width).contains(check.x),
                  (0..<texture.height).contains(check.y)
            else {
                throw HarnessSceneError.invalidCheckCoordinate(
                    x: check.x,
                    y: check.y
                )
            }
            let actualVector = PNGWriter.pixel(
                in: texture,
                x: check.x,
                y: check.y
            )
            let actual = [
                actualVector.x,
                actualVector.y,
                actualVector.z,
                actualVector.w,
            ]
            let passed = zip(actual, check.expectedBGRA).allSatisfy {
                abs(Int($0.0) - Int($0.1)) <= Int(check.tolerance)
            }
            guard passed else {
                throw SliceThreeHarnessRunError.pixelMismatch(
                    sceneName: scene.name,
                    channel: check.channel,
                    x: check.x,
                    y: check.y,
                    expected: check.expectedBGRA,
                    actual: actual,
                    tolerance: check.tolerance
                )
            }
        }
    }

    nonisolated static func evaluateStructuralChecks(
        scene: HarnessScene,
        values: [HarnessStructuralMetric: Int]
    ) throws {
        for check in scene.structuralChecks {
            guard let actual = values[check.metric] else {
                throw SliceThreeHarnessRunError.invariant(
                    sceneName: scene.name,
                    message: "structural metric \(check.metric.rawValue) is unavailable"
                )
            }
            let passed: Bool
            switch check.relation {
            case .equal:
                passed = actual == check.value
            case .lessThanOrEqual:
                passed = actual <= check.value
            }
            guard passed else {
                throw SliceThreeHarnessRunError.structuralMismatch(
                    sceneName: scene.name,
                    metric: check.metric,
                    expectedRelation: check.relation,
                    expectedValue: check.value,
                    actualValue: actual
                )
            }
        }
    }

    private func requireZero(
        _ value: Int,
        scene: HarnessScene,
        message: String
    ) throws {
        guard value == 0 else {
            throw SliceThreeHarnessRunError.invariant(
                sceneName: scene.name,
                message: message
            )
        }
    }

    private func pixel(
        in texture: any MTLTexture,
        x: Int,
        y: Int
    ) -> [UInt8] {
        let value = PNGWriter.pixel(in: texture, x: x, y: y)
        return [value.x, value.y, value.z, value.w]
    }

    private func maximumByteDelta(
        _ lhs: any MTLTexture,
        _ rhs: any MTLTexture
    ) -> Int {
        let lhsBytes = textureBytes(lhs)
        let rhsBytes = textureBytes(rhs)
        guard lhsBytes.count == rhsBytes.count else { return 255 }
        return zip(lhsBytes, rhsBytes).reduce(0) {
            max($0, abs(Int($1.0) - Int($1.1)))
        }
    }

    private func differingByteCount(
        _ lhs: any MTLTexture,
        _ rhs: any MTLTexture
    ) -> Int {
        let lhsBytes = textureBytes(lhs)
        let rhsBytes = textureBytes(rhs)
        guard lhsBytes.count == rhsBytes.count else {
            return max(lhsBytes.count, rhsBytes.count)
        }
        return zip(lhsBytes, rhsBytes).filter(!=).count
    }

    private func textureBytes(_ texture: any MTLTexture) -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count: bytesPerRow * texture.height
        )
        bytes.withUnsafeMutableBytes { storage in
            texture.getBytes(
                storage.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        return bytes
    }

    private func deterministicPixels(_ size: PixelSize) -> [UInt8] {
        var bytes = [UInt8](
            repeating: 0,
            count: size.width * size.height * 4
        )
        for y in 0..<size.height {
            for x in 0..<size.width {
                let offset = (y * size.width + x) * 4
                bytes[offset] = UInt8(truncatingIfNeeded: x &* 13 &+ y &* 7)
                bytes[offset + 1] = UInt8(
                    truncatingIfNeeded: x &* 3 &+ y &* 17
                )
                bytes[offset + 2] = UInt8(
                    truncatingIfNeeded: x &* 19 &+ y &* 5
                )
                bytes[offset + 3] = UInt8(
                    truncatingIfNeeded: 1 &+ x &+ y
                )
            }
        }
        return bytes
    }

    private func croppedOrFilled(
        _ source: [UInt8],
        from sourceSize: PixelSize,
        to destinationSize: PixelSize
    ) -> [UInt8] {
        var destination = [UInt8](
            repeating: 0,
            count: destinationSize.width * destinationSize.height * 4
        )
        let width = min(sourceSize.width, destinationSize.width)
        let height = min(sourceSize.height, destinationSize.height)
        for y in 0..<height {
            let sourceStart = y * sourceSize.width * 4
            let destinationStart = y * destinationSize.width * 4
            destination.replaceSubrange(
                destinationStart..<(destinationStart + width * 4),
                with: source[sourceStart..<(sourceStart + width * 4)]
            )
        }
        return destination
    }

    private func unorm(_ value: Float) -> UInt8 {
        UInt8(clamping: Int((min(1, max(0, value)) * 255).rounded()))
    }

    private func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        max(0, (CFAbsoluteTimeGetCurrent() - start) * 1_000)
    }

    private static func peakResidentBytes() throws -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
            throw HarnessRunError.processMetricsUnavailable
        }
        return UInt64(usage.ru_maxrss)
    }
}
