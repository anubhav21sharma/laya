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

struct HarnessRenderConfiguration: Equatable, Sendable {
    let pixelSize: PixelSize
    let tiling: TilingKind
    let diagnosticMode: HarnessDiagnosticMode
}

struct TranslationHarnessInput: Equatable, Sendable {
    let center: WorldPoint
    let tiling: TilingKind
    let capturesPhasedGridLines: Bool
}

struct HarnessOracleMetrics: Codable, Equatable, Sendable {
    let oracleHoleCount: Int
    let oraclePhantomCount: Int
    let oracleMaximumDelta: Int
    let transformMismatchCount: Int

    static func encode(_ metrics: HarnessOracleMetrics) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(metrics)
    }
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
    case tilingPixelMismatch(
        sceneName: String,
        tiling: TilingKind,
        cell: CellIndex?,
        channel: HarnessPixelChannel,
        x: Int,
        y: Int,
        expected: [UInt8],
        actual: [UInt8],
        tolerance: UInt8
    )
    case tilingStructuralMismatch(
        sceneName: String,
        tiling: TilingKind,
        cell: CellIndex?,
        metric: HarnessStructuralMetric,
        expectedRelation: HarnessRelation,
        expectedValue: Int,
        actualValue: Int
    )
    case missingStructuralMetric(
        sceneName: String,
        metric: HarnessStructuralMetric
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
        case let .tilingPixelMismatch(
            sceneName,
            tiling,
            cell,
            channel,
            x,
            y,
            expected,
            actual,
            tolerance
        ):
            "Tiling scene '\(sceneName)' tiling \(tiling) cell \(Self.cellDescription(cell)) channel \(channel.rawValue) coordinate \(x),\(y): expected \(expected), actual \(actual), tolerance \(tolerance)."
        case let .tilingStructuralMismatch(
            sceneName,
            tiling,
            cell,
            metric,
            relation,
            expected,
            actual
        ):
            "Tiling scene '\(sceneName)' tiling \(tiling) cell \(Self.cellDescription(cell)) metric \(metric.rawValue): expected \(relation.rawValue) \(expected), actual \(actual)."
        case let .missingStructuralMetric(sceneName, metric):
            "Grid scene '\(sceneName)' cannot measure structural metric \(metric.rawValue)."
        case let .counterInvariant(sceneName, message):
            "Grid scene '\(sceneName)' counter invariant failed: \(message)"
        }
    }

    private static func cellDescription(_ cell: CellIndex?) -> String {
        guard let cell else {
            return "none"
        }
        return "\(cell.column),\(cell.row)"
    }
}

@MainActor
public final class HarnessRunner {
    nonisolated static func translationInput(
        for program: TilingHarnessProgram
    ) -> TranslationHarnessInput? {
        switch program {
        case .generalizedGrid:
            TranslationHarnessInput(
                center: WorldPoint(x: -2, y: -2),
                tiling: .grid,
                capturesPhasedGridLines: false
            )
        case .halfDropInterior:
            TranslationHarnessInput(
                center: WorldPoint(x: 432, y: 144),
                tiling: .halfDrop,
                capturesPhasedGridLines: true
            )
        case .halfDropEdge:
            TranslationHarnessInput(
                center: WorldPoint(x: 288, y: 96),
                tiling: .halfDrop,
                capturesPhasedGridLines: true
            )
        case .halfDropCorner:
            TranslationHarnessInput(
                center: WorldPoint(x: 288, y: 288),
                tiling: .halfDrop,
                capturesPhasedGridLines: true
            )
        case .brickTranspose:
            TranslationHarnessInput(
                center: WorldPoint(x: 144, y: 192),
                tiling: .brick,
                capturesPhasedGridLines: true
            )
        default:
            nil
        }
    }

    nonisolated static func configuration(
        for scene: HarnessScene
    ) -> HarnessRenderConfiguration {
        HarnessRenderConfiguration(
            pixelSize: PixelSize(
                width: scene.tileWidth ?? Int(GridCanvasContract.tileSize),
                height: scene.tileHeight ?? Int(GridCanvasContract.tileSize)
            ),
            tiling: scene.tiling ?? .grid,
            diagnosticMode: scene.diagnosticMode ?? .hardRound
        )
    }

    nonisolated static func productionCoverage(
        fromBGRA bytes: [UInt8],
        pixelSize: PixelSize
    ) -> OracleCoverage {
        let pixelCount = pixelSize.width * pixelSize.height
        precondition(
            bytes.count == pixelCount * 4,
            "Production BGRA byte count must equal pixel area times four"
        )
        var coverage = [UInt8](repeating: 0, count: pixelCount)
        for pixelIndex in 0..<pixelCount {
            coverage[pixelIndex] = bytes[pixelIndex * 4 + 3] >= 128
                ? 255
                : 0
        }
        return OracleCoverage(pixelSize: pixelSize, bytes: coverage)
    }

    nonisolated static func compareOracleCoverage(
        expected: OracleCoverage,
        productionBGRA: [UInt8]
    ) -> CoverageComparison {
        let actual = productionCoverage(
            fromBGRA: productionBGRA,
            pixelSize: expected.pixelSize
        )
        return TilingCoverageOracle.compare(
            expected: expected,
            actual: actual,
            boundaryTolerance: 1
        )
    }

    nonisolated static func isPhasedGridLineVisible(
        line: SIMD4<UInt8>,
        offLine: SIMD4<UInt8>
    ) -> Bool {
        Int(line.x) + 20 < Int(offLine.x)
            && Int(line.y) + 20 < Int(offLine.y)
            && Int(line.z) + 20 < Int(offLine.z)
            && line.w == 255
    }

    private struct GridArtifacts {
        var liveScreen: (any MTLTexture)?
        var committedScreen: (any MTLTexture)?
        var canonical: (any MTLTexture)?
        var phasedGridScreen: (any MTLTexture)?
        var oracle: OracleRasterResult?
        var oracleMetrics: HarnessOracleMetrics?

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
            case .oracleCoverage, .oracleCanonicalCoordinates,
                 .oracleBrushLocalCoordinates:
                nil
            }
        }

        func oracleBGRA(
            for channel: HarnessPixelChannel
        ) -> (bytes: [UInt8], pixelSize: PixelSize)? {
            guard let oracle else {
                return nil
            }
            switch channel {
            case .oracleCoverage:
                var bytes: [UInt8] = []
                bytes.reserveCapacity(oracle.coverage.bytes.count * 4)
                for byte in oracle.coverage.bytes {
                    bytes.append(contentsOf: [byte, byte, byte, 255])
                }
                return (bytes, oracle.coverage.pixelSize)
            case .oracleCanonicalCoordinates:
                return (
                    oracle.canonicalCoordinatesBGRA,
                    oracle.coverage.pixelSize
                )
            case .oracleBrushLocalCoordinates:
                return (
                    oracle.brushLocalCoordinatesBGRA,
                    oracle.coverage.pixelSize
                )
            case .screen, .liveScreen, .committedScreen, .canonical:
                return nil
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

    private let device: any MTLDevice
    private let library: any MTLLibrary
    private let blankRenderer: BlankRenderer
    private var pristineGridRenderer: GridRenderer?

    public init(device: any MTLDevice) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.defaultLibraryUnavailable
        }
        self.device = device
        self.library = library
        blankRenderer = try BlankRenderer(device: device, library: library)
        pristineGridRenderer = try GridRenderer(
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
            let actual = try checkedPixel(in: frame.texture, check: check)
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
        let configuration = Self.configuration(for: scene)

        let gridRenderer: GridRenderer
        if configuration == HarnessRenderConfiguration(
            pixelSize: GridCanvasContract.defaultPixelSize,
            tiling: .grid,
            diagnosticMode: .hardRound
        ), let initialRenderer = pristineGridRenderer {
            pristineGridRenderer = nil
            gridRenderer = initialRenderer
        } else {
            gridRenderer = try GridRenderer(
                device: device,
                library: library,
                drawableSize: PatternSize(
                    width: Float(scene.width),
                    height: Float(scene.height)
                ),
                pixelSize: configuration.pixelSize,
                tiling: configuration.tiling
            )
        }

        var measurements = GridMeasurements()
        var artifacts = GridArtifacts()
        var revisionStart = gridRenderer.harnessRevision.rawValue
        var canonicalBefore: [UInt8]?

        switch program {
        case .gridInterior:
            measureHandle(
                .began,
                x: 200,
                y: 256,
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .moved,
                x: 240,
                y: 256,
                renderer: gridRenderer,
                into: &measurements
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
            measureHandle(
                .ended,
                x: 240,
                y: 256,
                renderer: gridRenderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )

        case .gridBoundary:
            measureHandle(
                .began,
                x: 128,
                y: 128,
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .moved,
                x: 160,
                y: 160,
                renderer: gridRenderer,
                into: &measurements
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
            measureHandle(
                .ended,
                x: 160,
                y: 160,
                renderer: gridRenderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )

        case .previewCommit:
            measureHandle(
                .began,
                x: 180,
                y: 220,
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .moved,
                x: 260,
                y: 300,
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .ended,
                x: 260,
                y: 300,
                renderer: gridRenderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )

        case .cancelPreservesCanonical:
            measureHandle(
                .began,
                x: 180,
                y: 180,
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .ended,
                x: 220,
                y: 180,
                renderer: gridRenderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try finishCommit(
                renderer: gridRenderer,
                measurements: &measurements
            )
            let beforeTexture = try gridRenderer.copyCanonicalForHarness()
            canonicalBefore = textureBytes(beforeTexture)
            revisionStart = gridRenderer.harnessRevision.rawValue

            measureHandle(
                .began,
                x: 300,
                y: 300,
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .moved,
                x: 340,
                y: 320,
                renderer: gridRenderer,
                into: &measurements
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
            measureHandle(
                .cancelled,
                x: 340,
                y: 320,
                renderer: gridRenderer,
                into: &measurements
            )
            artifacts.committedScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
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
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )

        case .longStroke:
            try replayLongZigzag(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
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
                renderer: gridRenderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
        case .generalizedGrid, .halfDropInterior, .halfDropEdge,
             .halfDropCorner, .brickTranspose:
            guard let input = Self.translationInput(for: program),
                  input.tiling == configuration.tiling,
                  gridRenderer.harnessTiling == configuration.tiling
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "translation program and renderer tiling disagree"
                )
            }
            try gridRenderer.injectHarnessDab(at: input.center)
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
            if input.capturesPhasedGridLines {
                artifacts.phasedGridScreen =
                    try capturePhasedGridDisplay(
                        scene: scene,
                        renderer: gridRenderer,
                        measurements: &measurements
                    )
                try validatePhasedGridLine(
                    scene: scene,
                    program: program,
                    texture: artifacts.phasedGridScreen!
                )
            }
            artifacts.oracle = TilingCoverageOracle.renderCanonical(
                footprint: .hardRound(
                    radius: GridCanvasContract.brushRadius
                ),
                brushToWorld: Affine2D(
                    xAxis: SIMD2(1, 0),
                    yAxis: SIMD2(0, 1),
                    translation: input.center.simd
                ),
                tileSize: configuration.pixelSize,
                tiling: configuration.tiling,
                supersampling: 1
            )
        default:
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "program \(program.rawValue) is not implemented by this task boundary"
            )
        }

        let oracleComparison: CoverageComparison?
        let transformMismatchCount: Int?
        if let oracle = artifacts.oracle, let canonical = artifacts.canonical {
            let canonicalBytes = textureBytes(canonical)
            let actualCoverage = Self.productionCoverage(
                fromBGRA: canonicalBytes,
                pixelSize: oracle.coverage.pixelSize
            )
            let comparison = TilingCoverageOracle.compare(
                expected: oracle.coverage,
                actual: actualCoverage,
                boundaryTolerance: 1
            )
            oracleComparison = comparison
            let mismatchCount = zip(
                oracle.coverage.bytes,
                actualCoverage.bytes
            ).reduce(0) {
                $0 + ($1.0 == $1.1 ? 0 : 1)
            }
            transformMismatchCount = mismatchCount
            artifacts.oracleMetrics = HarnessOracleMetrics(
                oracleHoleCount: comparison.holeCount,
                oraclePhantomCount: comparison.phantomCount,
                oracleMaximumDelta: Int(comparison.maximumDelta),
                transformMismatchCount: mismatchCount
            )
        } else {
            oracleComparison = nil
            transformMismatchCount = nil
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
        var structuralValues: [HarnessStructuralMetric: Int] = [
            .emittedDabCount: counters.totalDabsThisStroke,
            .encodedInstanceCount: measurements.newInstanceCounts.reduce(0, +),
            .restampedInstanceCount: measurements.restampedInstanceCount,
            .missedFrameCount: measurements.missedFrameCount,
        ]
        if artifacts.canonical != nil {
            structuralValues[.canonicalRevisionDelta] = revisionDelta
        }
        if artifacts.liveScreen != nil, artifacts.committedScreen != nil {
            structuralValues[.previewCommitMaximumDelta] = previewCommitDelta
        }
        if canonicalBefore != nil, artifacts.canonical != nil {
            structuralValues[.canonicalByteDelta] = canonicalByteDelta
        }
        if let oracleComparison {
            structuralValues[.oracleHoleCount] =
                oracleComparison.holeCount
            structuralValues[.oraclePhantomCount] =
                oracleComparison.phantomCount
            structuralValues[.oracleMaximumDelta] =
                Int(oracleComparison.maximumDelta)
        }
        if let transformMismatchCount {
            structuralValues[.transformMismatchCount] =
                transformMismatchCount
        }

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
        try Self.evaluateStructuralChecks(
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
        renderer: GridRenderer,
        into measurements: inout GridMeasurements
    ) {
        let start = CFAbsoluteTimeGetCurrent()
        if phase == .began {
            measurements.totalInstancesAtPreviousFrame = 0
        }
        if measurements.pendingEventStart == nil {
            measurements.pendingEventStart = start
        }
        renderer.handle(
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
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws {
        let submitStart = measurements.pendingEventStart
            ?? CFAbsoluteTimeGetCurrent()
        let eventProcessingMilliseconds = elapsedMilliseconds(
            since: submitStart
        )
        let metrics = try renderer.flushPendingLiveForHarness()
        let submitMilliseconds = eventProcessingMilliseconds
            + metrics.cpuEncodeMilliseconds
        let counters = renderer.harnessCounters
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
        renderer: GridRenderer,
        artifacts: inout GridArtifacts,
        measurements: inout GridMeasurements
    ) throws {
        try flushPending(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        artifacts.liveScreen = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
    }

    private func captureDisplay(
        scene: HarnessScene,
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws -> any MTLTexture {
        let frame = try renderer.renderOffscreenDisplayForHarness(
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

    private func capturePhasedGridDisplay(
        scene: HarnessScene,
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws -> any MTLTexture {
        let frame = try renderer.renderOffscreenDisplayForHarness(
            width: scene.width,
            height: scene.height,
            showGridLines: true
        )
        measurements.cpuEncodeMilliseconds.append(
            frame.metrics.cpuEncodeMilliseconds
        )
        measurements.gpuMilliseconds.append(frame.metrics.gpuMilliseconds)
        measurements.gridGPUMilliseconds.append(frame.metrics.gpuMilliseconds)
        return frame.texture
    }

    private func validatePhasedGridLine(
        scene: HarnessScene,
        program: TilingHarnessProgram,
        texture: any MTLTexture
    ) throws {
        let world: WorldPoint
        switch program {
        case .halfDropInterior, .halfDropCorner:
            world = WorldPoint(x: 300, y: 96)
        case .halfDropEdge:
            world = WorldPoint(x: 300, y: 288)
        case .brickTranspose:
            world = WorldPoint(x: 144, y: 300)
        default:
            return
        }
        let configuration = Self.configuration(for: scene)
        let viewport = ViewportTransform(
            drawableSize: PatternSize(
                width: Float(scene.width),
                height: Float(scene.height)
            ),
            worldCenter: WorldPoint(
                x: Float(configuration.pixelSize.width) * 0.5,
                y: Float(configuration.pixelSize.height) * 0.5
            )
        )
        let screen = viewport.worldToScreen(world)
        let x = Int(screen.x)
        let y = Int(screen.y)
        let line = PNGWriter.pixel(in: texture, x: x, y: y)
        let offLine = PNGWriter.pixel(
            in: texture,
            x: min(texture.width - 1, x + 4),
            y: min(texture.height - 1, y + 4)
        )
        let lineIsVisible = Self.isPhasedGridLineVisible(
            line: line,
            offLine: offLine
        )
        guard lineIsVisible else {
            throw HarnessRunError.tilingPixelMismatch(
                sceneName: scene.name,
                tiling: configuration.tiling,
                cell: nil,
                channel: .committedScreen,
                x: x,
                y: y,
                expected: [199, 202, 198, 255],
                actual: [line.x, line.y, line.z, line.w],
                tolerance: 5
            )
        }
    }

    private func finishCommit(
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws {
        let start = CFAbsoluteTimeGetCurrent()
        let metrics = try renderer.finishCommitForHarness()
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
        renderer: GridRenderer,
        artifacts: inout GridArtifacts,
        measurements: inout GridMeasurements
    ) throws {
        try finishCommit(
            renderer: renderer,
            measurements: &measurements
        )
        artifacts.committedScreen = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        artifacts.canonical = try renderer.copyCanonicalForHarness()
    }

    private func replayLongZigzag(
        scene: HarnessScene,
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws {
        measureHandle(
            .began,
            x: 48,
            y: 48,
            renderer: renderer,
            into: &measurements
        )
        for index in 0..<240 {
            let point = longZigzagPoint(index: index)
            measureHandle(
                .moved,
                x: point.x,
                y: point.y,
                renderer: renderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: renderer,
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
            let actual: SIMD4<UInt8>
            if let oracle = artifacts.oracleBGRA(for: check.channel) {
                guard
                    (0..<oracle.pixelSize.width).contains(check.x),
                    (0..<oracle.pixelSize.height).contains(check.y)
                else {
                    throw HarnessSceneError.invalidCheckCoordinate(
                        x: check.x,
                        y: check.y
                    )
                }
                let offset = (check.y * oracle.pixelSize.width + check.x) * 4
                actual = SIMD4(
                    oracle.bytes[offset],
                    oracle.bytes[offset + 1],
                    oracle.bytes[offset + 2],
                    oracle.bytes[offset + 3]
                )
            } else {
                guard let texture = artifacts.texture(for: check.channel) else {
                    throw HarnessRunError.missingArtifact(
                        sceneName: scene.name,
                        channel: check.channel
                    )
                }
                actual = try checkedPixel(in: texture, check: check)
            }
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
                if scene.schemaVersion == 3, let tiling = scene.tiling {
                    throw HarnessRunError.tilingPixelMismatch(
                        sceneName: scene.name,
                        tiling: tiling,
                        cell: nil,
                        channel: check.channel,
                        x: check.x,
                        y: check.y,
                        expected: check.expectedBGRA,
                        actual: [actual.x, actual.y, actual.z, actual.w],
                        tolerance: check.tolerance
                    )
                } else {
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
    }

    nonisolated static func evaluateStructuralChecks(
        scene: HarnessScene,
        values: [HarnessStructuralMetric: Int]
    ) throws {
        for check in scene.structuralChecks {
            guard let actual = values[check.metric] else {
                throw HarnessRunError.missingStructuralMetric(
                    sceneName: scene.name,
                    metric: check.metric
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
                if scene.schemaVersion == 3, let tiling = scene.tiling {
                    throw HarnessRunError.tilingStructuralMismatch(
                        sceneName: scene.name,
                        tiling: tiling,
                        cell: nil,
                        metric: check.metric,
                        expectedRelation: check.relation,
                        expectedValue: check.value,
                        actualValue: actual
                    )
                } else {
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
    }

    private func checkedPixel(
        in texture: any MTLTexture,
        check: HarnessPixelCheck
    ) throws -> SIMD4<UInt8> {
        guard
            (0..<texture.width).contains(check.x),
            (0..<texture.height).contains(check.y)
        else {
            throw HarnessSceneError.invalidCheckCoordinate(
                x: check.x,
                y: check.y
            )
        }
        return PNGWriter.pixel(in: texture, x: check.x, y: check.y)
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
        if let texture = artifacts.phasedGridScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).grid-lines.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let oracle = artifacts.oracle {
            let coverageURL = outputDirectory.appendingPathComponent(
                "\(scene.name).oracle.coverage.png"
            )
            try PNGWriter.write(
                coverage: oracle.coverage,
                to: coverageURL
            )
            artifactURLs.append(coverageURL)

            let canonicalURL = outputDirectory.appendingPathComponent(
                "\(scene.name).oracle.canonical-coordinates.png"
            )
            try PNGWriter.writeBGRA(
                oracle.canonicalCoordinatesBGRA,
                pixelSize: oracle.coverage.pixelSize,
                to: canonicalURL
            )
            artifactURLs.append(canonicalURL)

            let brushLocalURL = outputDirectory.appendingPathComponent(
                "\(scene.name).oracle.brush-local-coordinates.png"
            )
            try PNGWriter.writeBGRA(
                oracle.brushLocalCoordinatesBGRA,
                pixelSize: oracle.coverage.pixelSize,
                to: brushLocalURL
            )
            artifactURLs.append(brushLocalURL)
        }
        if let oracleMetrics = artifacts.oracleMetrics {
            let metricsURL = outputDirectory.appendingPathComponent(
                "\(scene.name).oracle.metrics.json"
            )
            try HarnessOracleMetrics.encode(oracleMetrics).write(
                to: metricsURL,
                options: .atomic
            )
            artifactURLs.append(metricsURL)
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
