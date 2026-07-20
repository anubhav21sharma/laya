import Darwin
import Foundation
import Metal
import PatternEngine

public struct HarnessRunResult: Equatable, Sendable {
    public let imageURL: URL
    public let benchmarkURL: URL
    public let benchmark: BenchmarkRecord
    public let artifactURLs: [URL]
}

public enum HarnessRunError: Error, Equatable, LocalizedError {
    case processMetricsUnavailable
    case pixelMismatch(
        x: Int,
        y: Int,
        expected: [UInt8],
        actual: [UInt8],
        tolerance: UInt8
    )
    case gridPixelMismatch(
        sceneName: String,
        channel: HarnessPixelChannel,
        x: Int,
        y: Int,
        expected: [UInt8],
        actual: [UInt8],
        tolerance: UInt8
    )
    case missingArtifact(
        sceneName: String,
        channel: HarnessPixelChannel
    )
    case structuralMismatch(
        sceneName: String,
        metric: HarnessStructuralMetric,
        expectedRelation: HarnessRelation,
        expectedValue: Int,
        actualValue: Int
    )
    case counterInvariant(sceneName: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .processMetricsUnavailable:
            "Peak resident-memory measurement is unavailable."
        case let .pixelMismatch(x, y, expected, actual, tolerance):
            "Pixel mismatch at (\(x), \(y)): expected \(expected), actual \(actual), tolerance \(tolerance)."
        case let .gridPixelMismatch(
            sceneName,
            channel,
            x,
            y,
            expected,
            actual,
            tolerance
        ):
            "Grid scene '\(sceneName)' channel \(channel.rawValue) pixel mismatch at (\(x), \(y)): expected \(expected), actual \(actual), tolerance \(tolerance)."
        case let .missingArtifact(sceneName, channel):
            "Grid scene '\(sceneName)' is missing artifact channel \(channel.rawValue)."
        case let .structuralMismatch(
            sceneName,
            metric,
            relation,
            expected,
            actual
        ):
            "Grid scene '\(sceneName)' structural mismatch \(metric.rawValue): expected \(relation.rawValue) \(expected), actual \(actual)."
        case let .counterInvariant(sceneName, message):
            "Grid scene '\(sceneName)' counter invariant failed: \(message)"
        }
    }
}

@MainActor
public final class HarnessRunner {
    private struct GridArtifacts {
        var liveScreen: (any MTLTexture)?
        var committedScreen: (any MTLTexture)?
        var canonical: (any MTLTexture)?

        func texture(
            for channel: HarnessPixelChannel
        ) -> (any MTLTexture)? {
            switch channel {
            case .screen:
                committedScreen ?? liveScreen
            case .liveScreen:
                liveScreen
            case .committedScreen:
                committedScreen
            case .canonical:
                canonical
            }
        }
    }

    private struct GridMeasurements {
        var timestamp: TimeInterval = 0
        var pendingEventStart: CFAbsoluteTime?
        var brushProcessingMilliseconds: [Double] = []
        var eventToSubmitMilliseconds: [Double] = []
        var cpuEncodeMilliseconds: [Double] = []
        var gpuMilliseconds: [Double] = []
        var dabGPUMilliseconds: [Double] = []
        var gridGPUMilliseconds: [Double] = []
        var commitGPUMilliseconds: [Double] = []
        var commitPendingMilliseconds: [Double] = []
        var newInstanceCounts: [Int] = []
        var totalStrokeInstanceCounts: [Int] = []
        var totalInstancesAtPreviousFrame = 0
        var restampedInstanceCount = 0
        var missedFrameCount = 0
        let displayFrameBudgetMilliseconds = 1_000.0 / 60.0
    }

    private let blankRenderer: BlankRenderer
    private let gridRenderer: GridRenderer

    public init(device: any MTLDevice) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.defaultLibraryUnavailable
        }
        blankRenderer = try BlankRenderer(device: device, library: library)
        gridRenderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 512, height: 512)
        )
    }

    public func run(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) throws -> HarnessRunResult {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        if scene.schemaVersion == 1 {
            return try runBlank(
                scene: scene,
                outputDirectory: outputDirectory,
                build: build
            )
        }
        return try runGrid(
            scene: scene,
            outputDirectory: outputDirectory,
            build: build
        )
    }

    private func runBlank(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) throws -> HarnessRunResult {
        let frame = try blankRenderer.renderOffscreen(
            width: scene.width,
            height: scene.height
        )
        let imageURL = outputDirectory
            .appendingPathComponent("\(scene.name).screen.png")

        try PNGWriter.write(texture: frame.texture, to: imageURL)

        for check in scene.checks {
            let actual = PNGWriter.pixel(
                in: frame.texture,
                x: check.x,
                y: check.y
            )
            let expected = SIMD4(
                check.expectedBGRA[0],
                check.expectedBGRA[1],
                check.expectedBGRA[2],
                check.expectedBGRA[3]
            )
            guard BlankCanvasContract.matches(
                actual: actual,
                expected: expected,
                tolerance: check.tolerance
            ) else {
                throw HarnessRunError.pixelMismatch(
                    x: check.x,
                    y: check.y,
                    expected: check.expectedBGRA,
                    actual: [actual.x, actual.y, actual.z, actual.w],
                    tolerance: check.tolerance
                )
            }
        }

        let processInfo = ProcessInfo.processInfo
        let record = BenchmarkRecord(
            schemaVersion: 1,
            timestampUTC: ISO8601DateFormatter().string(from: Date()),
            sceneName: scene.name,
            hardware: BenchmarkHardware(
                gpuName: blankRenderer.device.name,
                logicalProcessorCount: processInfo.activeProcessorCount,
                physicalMemoryBytes: processInfo.physicalMemory
            ),
            operatingSystem: processInfo.operatingSystemVersionString,
            build: build,
            frameCount: 1,
            cpuEncodeMilliseconds: [frame.metrics.cpuEncodeMilliseconds],
            gpuMilliseconds: [frame.metrics.gpuMilliseconds],
            peakResidentBytes: try Self.peakResidentBytes()
        )
        let benchmarkURL = outputDirectory
            .appendingPathComponent("\(scene.name).benchmark.json")
        try BenchmarkRecord.encode(record).write(
            to: benchmarkURL,
            options: .atomic
        )

        return HarnessRunResult(
            imageURL: imageURL,
            benchmarkURL: benchmarkURL,
            benchmark: record,
            artifactURLs: [imageURL, benchmarkURL]
        )
    }

    private func runGrid(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) throws -> HarnessRunResult {
        guard let program = scene.program else {
            throw HarnessSceneError.missingProgram
        }

        var measurements = GridMeasurements()
        var artifacts = GridArtifacts()
        var revisionStart = gridRenderer.harnessRevision.rawValue
        var canonicalBefore: [UInt8]?

        switch program {
        case .gridInterior:
            measureHandle(.began, x: 200, y: 256, into: &measurements)
            measureHandle(.moved, x: 240, y: 256, into: &measurements)
            try captureLive(
                scene: scene,
                artifacts: &artifacts,
                measurements: &measurements
            )
            measureHandle(.ended, x: 240, y: 256, into: &measurements)
            try flushPending(
                scene: scene,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                artifacts: &artifacts,
                measurements: &measurements
            )

        case .gridBoundary:
            measureHandle(.began, x: 128, y: 128, into: &measurements)
            measureHandle(.moved, x: 160, y: 160, into: &measurements)
            try captureLive(
                scene: scene,
                artifacts: &artifacts,
                measurements: &measurements
            )
            measureHandle(.ended, x: 160, y: 160, into: &measurements)
            try flushPending(
                scene: scene,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                artifacts: &artifacts,
                measurements: &measurements
            )

        case .previewCommit:
            measureHandle(.began, x: 180, y: 220, into: &measurements)
            measureHandle(.moved, x: 260, y: 300, into: &measurements)
            measureHandle(.ended, x: 260, y: 300, into: &measurements)
            try flushPending(
                scene: scene,
                measurements: &measurements
            )
            artifacts.liveScreen = try captureDisplay(
                scene: scene,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                artifacts: &artifacts,
                measurements: &measurements
            )

        case .cancelPreservesCanonical:
            measureHandle(.began, x: 180, y: 180, into: &measurements)
            measureHandle(.ended, x: 220, y: 180, into: &measurements)
            try flushPending(
                scene: scene,
                measurements: &measurements
            )
            try finishCommit(measurements: &measurements)
            let beforeTexture = try gridRenderer.copyCanonicalForHarness()
            canonicalBefore = textureBytes(beforeTexture)
            revisionStart = gridRenderer.harnessRevision.rawValue

            measureHandle(.began, x: 300, y: 300, into: &measurements)
            measureHandle(.moved, x: 340, y: 320, into: &measurements)
            try captureLive(
                scene: scene,
                artifacts: &artifacts,
                measurements: &measurements
            )
            measureHandle(.cancelled, x: 340, y: 320, into: &measurements)
            artifacts.committedScreen = try captureDisplay(
                scene: scene,
                measurements: &measurements
            )
            artifacts.canonical = try gridRenderer.copyCanonicalForHarness()

        case .fiveHundredDabs:
            let start = CFAbsoluteTimeGetCurrent()
            measurements.pendingEventStart = start
            try gridRenderer.injectFiveHundredInteriorDabsIntoOneFrame()
            measurements.brushProcessingMilliseconds.append(
                elapsedMilliseconds(since: start)
            )
            try captureLive(
                scene: scene,
                artifacts: &artifacts,
                measurements: &measurements
            )

        case .longStroke:
            try replayLongZigzag(
                scene: scene,
                measurements: &measurements
            )
            try captureLive(
                scene: scene,
                artifacts: &artifacts,
                measurements: &measurements
            )
            guard measurements.newInstanceCounts.last == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "late frame encoded \(measurements.newInstanceCounts.last ?? -1) instances instead of 0"
                )
            }
            let last = longZigzagPoint(index: 239)
            measureHandle(
                .ended,
                x: last.x,
                y: last.y,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                measurements: &measurements
            )
            artifacts.liveScreen = try captureDisplay(
                scene: scene,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                artifacts: &artifacts,
                measurements: &measurements
            )
        }

        let revisionDelta = Int(
            gridRenderer.harnessRevision.rawValue - revisionStart
        )
        let previewCommitDelta = maximumByteDelta(
            artifacts.liveScreen,
            artifacts.committedScreen
        )
        let canonicalByteDelta: Int
        if let canonicalBefore, let canonical = artifacts.canonical {
            canonicalByteDelta = differingByteCount(
                canonicalBefore,
                textureBytes(canonical)
            )
        } else {
            canonicalByteDelta = 0
        }

        let counters = gridRenderer.harnessCounters
        let structuralValues: [HarnessStructuralMetric: Int] = [
            .emittedDabCount: counters.totalDabsThisStroke,
            .encodedInstanceCount: measurements.newInstanceCounts.reduce(0, +),
            .restampedInstanceCount: measurements.restampedInstanceCount,
            .canonicalRevisionDelta: revisionDelta,
            .previewCommitMaximumDelta: previewCommitDelta,
            .canonicalByteDelta: canonicalByteDelta,
            .missedFrameCount: measurements.missedFrameCount,
        ]

        let processInfo = ProcessInfo.processInfo
        let record = BenchmarkRecord(
            schemaVersion: 2,
            timestampUTC: ISO8601DateFormatter().string(from: Date()),
            sceneName: scene.name,
            hardware: BenchmarkHardware(
                gpuName: gridRenderer.device.name,
                logicalProcessorCount: processInfo.activeProcessorCount,
                physicalMemoryBytes: processInfo.physicalMemory
            ),
            operatingSystem: processInfo.operatingSystemVersionString,
            build: build,
            frameCount: measurements.newInstanceCounts.count,
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
            commitPendingMilliseconds:
                measurements.commitPendingMilliseconds,
            displayFrameBudgetMilliseconds:
                measurements.displayFrameBudgetMilliseconds,
            newInstanceCounts: measurements.newInstanceCounts,
            totalStrokeInstanceCounts:
                measurements.totalStrokeInstanceCounts,
            missedFrameCount: measurements.missedFrameCount
        )

        let emitted = try writeGridArtifacts(
            scene: scene,
            artifacts: artifacts,
            record: record,
            outputDirectory: outputDirectory
        )
        try evaluatePixelChecks(
            scene: scene,
            artifacts: artifacts
        )
        try evaluateStructuralChecks(
            scene: scene,
            values: structuralValues
        )

        return HarnessRunResult(
            imageURL: emitted.primaryImageURL,
            benchmarkURL: emitted.benchmarkURL,
            benchmark: record,
            artifactURLs: emitted.artifactURLs
        )
    }

    private func measureHandle(
        _ phase: StrokePhase,
        x: Float,
        y: Float,
        into measurements: inout GridMeasurements
    ) {
        let start = CFAbsoluteTimeGetCurrent()
        if phase == .began {
            measurements.totalInstancesAtPreviousFrame = 0
        }
        if measurements.pendingEventStart == nil {
            measurements.pendingEventStart = start
        }
        gridRenderer.handle(
            StrokeSample.mouse(
                position: ScreenPoint(x: x, y: y),
                timestamp: measurements.timestamp,
                phase: phase
            )
        )
        measurements.timestamp += 1.0 / 120.0
        measurements.brushProcessingMilliseconds.append(
            elapsedMilliseconds(since: start)
        )
    }

    private func flushPending(
        scene: HarnessScene,
        measurements: inout GridMeasurements
    ) throws {
        let submitStart = measurements.pendingEventStart
            ?? CFAbsoluteTimeGetCurrent()
        let eventProcessingMilliseconds = elapsedMilliseconds(
            since: submitStart
        )
        let metrics = try gridRenderer.flushPendingLiveForHarness()
        let submitMilliseconds = eventProcessingMilliseconds
            + metrics.cpuEncodeMilliseconds
        let counters = gridRenderer.harnessCounters
        let created = counters.totalInstancesThisStroke
            - measurements.totalInstancesAtPreviousFrame

        guard created >= 0 else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "total instances moved backward within a stroke"
            )
        }
        guard counters.newInstancesThisFrame <=
                GridCanvasContract.pendingCapacity
        else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "frame encoded \(counters.newInstancesThisFrame) instances beyond the fixed \(GridCanvasContract.pendingCapacity) bound"
            )
        }

        measurements.restampedInstanceCount += max(
            0,
            counters.newInstancesThisFrame - created
        )
        measurements.newInstanceCounts.append(
            counters.newInstancesThisFrame
        )
        measurements.totalStrokeInstanceCounts.append(
            counters.totalInstancesThisStroke
        )
        measurements.totalInstancesAtPreviousFrame =
            counters.totalInstancesThisStroke
        measurements.eventToSubmitMilliseconds.append(submitMilliseconds)
        measurements.cpuEncodeMilliseconds.append(
            metrics.cpuEncodeMilliseconds
        )
        measurements.gpuMilliseconds.append(metrics.gpuMilliseconds)
        measurements.dabGPUMilliseconds.append(metrics.gpuMilliseconds)
        if submitMilliseconds >
            measurements.displayFrameBudgetMilliseconds
        {
            measurements.missedFrameCount += 1
        }
        measurements.pendingEventStart = nil
    }

    private func captureLive(
        scene: HarnessScene,
        artifacts: inout GridArtifacts,
        measurements: inout GridMeasurements
    ) throws {
        try flushPending(scene: scene, measurements: &measurements)
        artifacts.liveScreen = try captureDisplay(
            scene: scene,
            measurements: &measurements
        )
    }

    private func captureDisplay(
        scene: HarnessScene,
        measurements: inout GridMeasurements
    ) throws -> any MTLTexture {
        let frame = try gridRenderer.renderOffscreenDisplayForHarness(
            width: scene.width,
            height: scene.height,
            showGridLines: false
        )
        measurements.cpuEncodeMilliseconds.append(
            frame.metrics.cpuEncodeMilliseconds
        )
        measurements.gpuMilliseconds.append(frame.metrics.gpuMilliseconds)
        measurements.gridGPUMilliseconds.append(frame.metrics.gpuMilliseconds)
        return frame.texture
    }

    private func finishCommit(
        measurements: inout GridMeasurements
    ) throws {
        let start = CFAbsoluteTimeGetCurrent()
        let metrics = try gridRenderer.finishCommitForHarness()
        measurements.commitPendingMilliseconds.append(
            elapsedMilliseconds(since: start)
        )
        measurements.cpuEncodeMilliseconds.append(
            metrics.cpuEncodeMilliseconds
        )
        measurements.gpuMilliseconds.append(metrics.gpuMilliseconds)
        measurements.commitGPUMilliseconds.append(metrics.gpuMilliseconds)
    }

    private func captureCommittedAndCanonical(
        scene: HarnessScene,
        artifacts: inout GridArtifacts,
        measurements: inout GridMeasurements
    ) throws {
        try finishCommit(measurements: &measurements)
        artifacts.committedScreen = try captureDisplay(
            scene: scene,
            measurements: &measurements
        )
        artifacts.canonical = try gridRenderer.copyCanonicalForHarness()
    }

    private func replayLongZigzag(
        scene: HarnessScene,
        measurements: inout GridMeasurements
    ) throws {
        measureHandle(.began, x: 48, y: 48, into: &measurements)
        for index in 0..<240 {
            let point = longZigzagPoint(index: index)
            measureHandle(
                .moved,
                x: point.x,
                y: point.y,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                measurements: &measurements
            )
        }
    }

    private func longZigzagPoint(index: Int) -> ScreenPoint {
        ScreenPoint(
            x: index.isMultiple(of: 2) ? 208 : 48,
            y: 48 + Float(index % 161)
        )
    }

    private func evaluatePixelChecks(
        scene: HarnessScene,
        artifacts: GridArtifacts
    ) throws {
        for check in scene.checks {
            guard let texture = artifacts.texture(for: check.channel) else {
                throw HarnessRunError.missingArtifact(
                    sceneName: scene.name,
                    channel: check.channel
                )
            }
            let actual = PNGWriter.pixel(
                in: texture,
                x: check.x,
                y: check.y
            )
            let expected = SIMD4(
                check.expectedBGRA[0],
                check.expectedBGRA[1],
                check.expectedBGRA[2],
                check.expectedBGRA[3]
            )
            guard BlankCanvasContract.matches(
                actual: actual,
                expected: expected,
                tolerance: check.tolerance
            ) else {
                throw HarnessRunError.gridPixelMismatch(
                    sceneName: scene.name,
                    channel: check.channel,
                    x: check.x,
                    y: check.y,
                    expected: check.expectedBGRA,
                    actual: [actual.x, actual.y, actual.z, actual.w],
                    tolerance: check.tolerance
                )
            }
        }
    }

    private func evaluateStructuralChecks(
        scene: HarnessScene,
        values: [HarnessStructuralMetric: Int]
    ) throws {
        for check in scene.structuralChecks {
            let actual = values[check.metric] ?? 0
            let passed: Bool
            switch check.relation {
            case .equal:
                passed = actual == check.value
            case .lessThanOrEqual:
                passed = actual <= check.value
            }
            guard passed else {
                throw HarnessRunError.structuralMismatch(
                    sceneName: scene.name,
                    metric: check.metric,
                    expectedRelation: check.relation,
                    expectedValue: check.value,
                    actualValue: actual
                )
            }
        }
    }

    private func writeGridArtifacts(
        scene: HarnessScene,
        artifacts: GridArtifacts,
        record: BenchmarkRecord,
        outputDirectory: URL
    ) throws -> (
        primaryImageURL: URL,
        benchmarkURL: URL,
        artifactURLs: [URL]
    ) {
        var artifactURLs: [URL] = []
        var liveURL: URL?
        var committedURL: URL?

        if let texture = artifacts.liveScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).live.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            liveURL = url
            artifactURLs.append(url)
        }
        if let texture = artifacts.committedScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).committed.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            committedURL = url
            artifactURLs.append(url)
        }
        if let texture = artifacts.canonical {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).canonical.png"
            )
            try PNGWriter.write(texture: texture, to: url)
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

        guard let primaryImageURL = committedURL ?? liveURL else {
            throw HarnessRunError.missingArtifact(
                sceneName: scene.name,
                channel: .screen
            )
        }
        return (primaryImageURL, benchmarkURL, artifactURLs)
    }

    private func maximumByteDelta(
        _ lhsTexture: (any MTLTexture)?,
        _ rhsTexture: (any MTLTexture)?
    ) -> Int {
        guard let lhsTexture, let rhsTexture else {
            return 0
        }
        let lhs = textureBytes(lhsTexture)
        let rhs = textureBytes(rhsTexture)
        guard lhs.count == rhs.count else {
            return 255
        }
        return zip(lhs, rhs).reduce(0) {
            max($0, abs(Int($1.0) - Int($1.1)))
        }
    }

    private func differingByteCount(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> Int {
        guard lhs.count == rhs.count else {
            return max(lhs.count, rhs.count)
        }
        return zip(lhs, rhs).reduce(0) {
            $0 + ($1.0 == $1.1 ? 0 : 1)
        }
    }

    private func textureBytes(_ texture: any MTLTexture) -> [UInt8] {
        precondition(texture.pixelFormat == .bgra8Unorm)
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count: bytesPerRow * texture.height
        )
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(
                    0,
                    0,
                    texture.width,
                    texture.height
                ),
                mipmapLevel: 0
            )
        }
        return bytes
    }

    private func elapsedMilliseconds(
        since start: CFAbsoluteTime
    ) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }

    private static func peakResidentBytes() throws -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
            throw HarnessRunError.processMetricsUnavailable
        }
        return UInt64(usage.ru_maxrss)
    }
}
