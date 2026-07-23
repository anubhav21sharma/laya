import CShaderTypes
import Darwin
import Foundation
import ImageIO
import Metal
import PatternEngine

private let sliceFourLegacyTilings: [TilingKind] = [
    .grid,
    .halfDrop,
    .brick,
    .mirrorX,
    .mirrorY,
    .mirrorXY,
    .rotational,
]
import UniformTypeIdentifiers

public struct SliceFourArtifactDigest: Codable, Equatable, Sendable {
    public let fileName: String
    public let byteCount: Int
    public let fnv1a64: String
}

/// Renderer-measured schema-5 evidence. Every value in this document is
/// captured from the GridRenderer execution which produced the sibling PNGs.
public struct SliceFourMeasuredEvidence: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sceneName: String
    public let recipeID: String
    public let seed: UInt64
    public let material: String
    public let replayMode: String
    public let attributedSampleCount: Int
    public let actualSampleCount: Int
    public let predictedSampleCount: Int
    public let structuralValues: [String: Int]
    public let liveCommittedMaximumDelta: Int
    public let canonicalChangedByteCount: Int
    public let auditValues: [String: Int]
    public let rendererBacked: Bool
    public let appServicesBacked: Bool
    public let coverage: [String]
    public let artifacts: [SliceFourArtifactDigest]
}

public enum SliceFourHarnessRunError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case invalidTrace(String)
    case defaultLibraryUnavailable
    case unknownRecipe(String)
    case missingCompletion(String)
    case unexpectedCompletion(String)
    case pixelMismatch(
        sceneName: String,
        channel: HarnessPixelChannel,
        x: Int,
        y: Int,
        expected: [UInt8],
        actual: [UInt8],
        tolerance: UInt8
    )
    case missingPixelArtifact(String, HarnessPixelChannel)
    case emptyCommittedOutput(String)
    case structuralMismatch(
        sceneName: String,
        metric: HarnessStructuralMetric,
        relation: HarnessRelation,
        expected: Int,
        actual: Int
    )
    case missingStructuralMetric(String, HarnessStructuralMetric)
    case negativeControlUnexpectedlyPassed(
        sceneName: String,
        metric: HarnessStructuralMetric
    )

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Slice 4 harness requires schema 5, found schema \(version)."
        case let .invalidTrace(message):
            "Slice 4 attributed trace is invalid: \(message)."
        case .defaultLibraryUnavailable:
            "The Slice 4 harness could not load the app Metal library."
        case let .unknownRecipe(identity):
            "Slice 4 scene references unknown recipe identity '\(identity)'."
        case let .missingCompletion(scene):
            "Slice 4 scene '\(scene)' did not publish a renderer completion."
        case let .unexpectedCompletion(scene):
            "Slice 4 scene '\(scene)' published an unexpected renderer completion."
        case let .pixelMismatch(scene, channel, x, y, expected, actual, tolerance):
            "Slice 4 scene '\(scene)' \(channel.rawValue) pixel \(x),\(y): expected \(expected) +/- \(tolerance), actual \(actual)."
        case let .missingPixelArtifact(scene, channel):
            "Slice 4 scene '\(scene)' has no \(channel.rawValue) artifact."
        case let .emptyCommittedOutput(scene):
            "Slice 4 scene '\(scene)' committed no nontransparent pixels."
        case let .structuralMismatch(scene, metric, relation, expected, actual):
            "Slice 4 scene '\(scene)' metric \(metric.rawValue): expected \(relation.rawValue) \(expected), actual \(actual)."
        case let .missingStructuralMetric(scene, metric):
            "Slice 4 scene '\(scene)' has no value for metric \(metric.rawValue)."
        case let .negativeControlUnexpectedlyPassed(scene, metric):
            "Slice 4 scene '\(scene)' negative control for \(metric.rawValue) unexpectedly passed."
        }
    }
}

@MainActor
public final class SliceFourHarnessRunner {
    public typealias HistoryRecorder = @MainActor (
        RasterMutationReceipt?
    ) throws -> Int
    public typealias CatalogRecipeVerifier = @MainActor (BrushRecipe) -> Bool
    private static let displayFrameBudgetMilliseconds = 1_000.0 / 60.0

    private struct Measurements {
        var cpu: [Double] = []
        var gpu: [Double] = []
        var brush: [Double] = []
        var eventToSubmit: [Double] = []
        var dabGPU: [Double] = []
        var dabInstanceCounts: [Int] = []
        var fiveHundredDabStressFrameIndex: Int?
        var fiveHundredDabStressNewDabCount: Int?
        var gridGPU: [Double] = []
        var commitGPU: [Double] = []

        mutating func append(
            _ value: GPUFrameMetrics,
            kind: Kind,
            newInstanceCount: Int = 0
        ) {
            cpu.append(value.cpuEncodeMilliseconds)
            gpu.append(value.gpuMilliseconds)
            switch kind {
            case .dab:
                dabGPU.append(value.gpuMilliseconds)
                dabInstanceCounts.append(newInstanceCount)
            case .grid: gridGPU.append(value.gpuMilliseconds)
            case .commit: commitGPU.append(value.gpuMilliseconds)
            }
        }

        mutating func appendFiveHundredDabStress(
            _ value: GPUFrameMetrics,
            newDabCount: Int,
            newInstanceCount: Int
        ) {
            precondition(fiveHundredDabStressFrameIndex == nil)
            fiveHundredDabStressFrameIndex = dabGPU.count
            fiveHundredDabStressNewDabCount = newDabCount
            append(
                value,
                kind: .dab,
                newInstanceCount: newInstanceCount
            )
        }

        enum Kind { case dab, grid, commit }
    }

    private struct CounterPeaks {
        var samples = 0
        var dabs = 0
        var replays = 0
        var promotions = 0
        var degradations = 0
        var assets = 0
        var washPixels = 0
        var washBytes = 0

        mutating func include(_ counters: SliceFourRendererCounters) {
            samples = max(samples, counters.retainedSampleCount)
            dabs = max(dabs, counters.retainedDabCount)
            replays = max(replays, counters.replayCount)
            promotions = max(promotions, counters.promotedSettledPrefixCount)
            degradations = max(degradations, counters.replayDegradationCount)
            assets = max(assets, counters.assetResidentBytes)
            washPixels = max(washPixels, counters.processedWashPixelCount)
            washBytes = max(washBytes, counters.washWorkingBytes)
        }
    }

    private let device: any MTLDevice
    private let library: (any MTLLibrary)?
    private let anchorRecipes: [BrushRecipe]
    private let historyRecorder: HistoryRecorder?
    private let catalogRecipeVerifier: CatalogRecipeVerifier?
    private var nextTokenRawValue: UInt64 = 1

    public init(device: any MTLDevice) {
        self.device = device
        library = device.makeDefaultLibrary()
        anchorRecipes = []
        historyRecorder = nil
        catalogRecipeVerifier = nil
    }

    public init(device: any MTLDevice, library: any MTLLibrary) {
        self.device = device
        self.library = library
        anchorRecipes = []
        historyRecorder = nil
        catalogRecipeVerifier = nil
    }

    public init(
        device: any MTLDevice,
        library: (any MTLLibrary)? = nil,
        anchorRecipes: [BrushRecipe],
        catalogRecipeVerifier: @escaping CatalogRecipeVerifier,
        historyRecorder: @escaping HistoryRecorder
    ) {
        self.device = device
        self.library = library ?? device.makeDefaultLibrary()
        self.anchorRecipes = anchorRecipes
        self.catalogRecipeVerifier = catalogRecipeVerifier
        self.historyRecorder = historyRecorder
    }

    public func run(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) throws -> HarnessRunResult {
        guard scene.schemaVersion == 5 else {
            throw SliceFourHarnessRunError.unsupportedSchema(scene.schemaVersion)
        }
        try Self.validateTrace(scene.attributedSamples)
        guard let library else {
            throw SliceFourHarnessRunError.defaultLibraryUnavailable
        }
        guard let recipeID = scene.recipeID, let seed = scene.seed,
              let expectedMaterial = scene.expectedMaterial,
              let expectedReplay = scene.replayMode
        else {
            preconditionFailure("HarnessScene.decode must validate schema 5")
        }
        let recipe = try Self.recipe(identity: recipeID)
        let renderer = try makeRenderer(scene: scene, library: library)
        let token = takeToken()
        var completions: [RendererOperationCompletion] = []
        renderer.onOperationCompleted = { completions.append($0) }
        let canonicalBefore = try renderer.copyCanonicalForHarness()
        let canonicalBeforeBytes = Self.textureBytes(canonicalBefore)
        var measurements = Measurements()
        var peaks = CounterPeaks()
        var predictedDuplicateSettledDabCount = 0
        var predictedSuffixWasObserved = false
        var settledDabCountBeforePrediction = 0

        let style = StrokeRenderStyle(
            color: InkColor(red: 0.16, green: 0.38, blue: 0.82, alpha: 0.82)!,
            diameter: 24,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: seed
        )
        let samples = try scene.attributedSamples.map { attributed in
            guard let sample = attributed.strokeSample else {
                throw SliceFourHarnessRunError.invalidTrace(
                    "sample at timestamp \(attributed.timestamp) is invalid"
                )
            }
            return sample
        }

        try renderer.beginStroke(token: token, sample: samples[0], style: style)
        peaks.include(renderer.sliceFourRendererCounters)
        let terminal = samples.last!.phase
        for (sampleIndex, pair) in zip(
            scene.attributedSamples.dropFirst().dropLast(),
            samples.dropFirst().dropLast()
        ).enumerated() {
            let (attributed, sample) = pair
            let inputStart = CFAbsoluteTimeGetCurrent()
            if attributed.kind == .predicted, !predictedSuffixWasObserved {
                predictedSuffixWasObserved = true
                settledDabCountBeforePrediction = renderer
                    .sliceFourRendererCounters.settledDabCount
            }
            try renderer.appendStroke(token: token, sample: sample)
            measurements.brush.append(
                (CFAbsoluteTimeGetCurrent() - inputStart) * 1_000
            )
            let counters = renderer.sliceFourRendererCounters
            if attributed.kind != .predicted, predictedSuffixWasObserved {
                if counters.predictedDabCount != 0
                    || counters.settledDabCount < settledDabCountBeforePrediction
                {
                    predictedDuplicateSettledDabCount += 1
                }
                predictedSuffixWasObserved = false
            }
            peaks.include(counters)
            if (scene.name.contains("long-stroke")
                || scene.name.contains("wash-bounds")),
               sampleIndex % 16 == 15
            {
                let submitStart = CFAbsoluteTimeGetCurrent()
                let flush = try renderer.flushPendingLiveForHarness()
                measurements.append(
                    flush.metrics,
                    kind: .dab,
                    newInstanceCount: renderer.harnessCounters
                        .newInstancesThisFrame
                )
                measurements.eventToSubmit.append(
                    (CFAbsoluteTimeGetCurrent() - submitStart) * 1_000
                )
                peaks.include(renderer.sliceFourRendererCounters)
            }
        }

        var receipt: RasterMutationReceipt?
        var liveFrame: RenderedFrame
        if terminal == .cancelled {
            // A cancelled terminal sample has no renderer append operation;
            // its position only terminates the already-attributed live trace.
            let eventStart = CFAbsoluteTimeGetCurrent()
            let flush = try renderer.flushPendingLiveForHarness()
            measurements.eventToSubmit.append(
                (CFAbsoluteTimeGetCurrent() - eventStart) * 1_000
            )
            measurements.append(
                flush.metrics,
                kind: .dab,
                newInstanceCount: renderer.harnessCounters.newInstancesThisFrame
            )
            peaks.include(renderer.sliceFourRendererCounters)
            liveFrame = try renderer.renderOffscreenDisplayForHarness(
                width: scene.width,
                height: scene.height,
                showGridLines: false
            )
            measurements.append(liveFrame.metrics, kind: .grid)
            try renderer.cancelStroke(token: token)
        } else {
            let eventStart = CFAbsoluteTimeGetCurrent()
            try renderer.requestStrokeCommit(
                token: token,
                sample: samples.last!,
                maximumRetainedBytes: 64 * 1_024 * 1_024
            )
            peaks.include(renderer.sliceFourRendererCounters)
            let flush = try renderer.flushPendingLiveForHarness()
            measurements.eventToSubmit.append(
                (CFAbsoluteTimeGetCurrent() - eventStart) * 1_000
            )
            measurements.append(
                flush.metrics,
                kind: .dab,
                newInstanceCount: renderer.harnessCounters.newInstancesThisFrame
            )
            peaks.include(renderer.sliceFourRendererCounters)
            liveFrame = try renderer.renderOffscreenDisplayForHarness(
                width: scene.width,
                height: scene.height,
                showGridLines: false
            )
            measurements.append(liveFrame.metrics, kind: .grid)
            let commitMetrics = try renderer.submitCommitForHarness()
            measurements.append(commitMetrics, kind: .commit)
            try renderer.drainCompletedOperationsForHarness()
            guard let completion = completions.first else {
                throw SliceFourHarnessRunError.missingCompletion(scene.name)
            }
            guard case let .rasterSuccess(value) = completion,
                  value.token == token
            else {
                throw SliceFourHarnessRunError.unexpectedCompletion(scene.name)
            }
            receipt = value
        }

        let committedFrame = try renderer.renderOffscreenDisplayForHarness(
            width: scene.width,
            height: scene.height,
            showGridLines: false
        )
        measurements.append(committedFrame.metrics, kind: .grid)
        let canonical = try renderer.copyCanonicalForHarness()
        let liveBytes = Self.textureBytes(liveFrame.texture)
        let committedBytes = Self.textureBytes(committedFrame.texture)
        let canonicalBytes = Self.textureBytes(canonical)
        let liveCommitDelta = Self.maximumByteDelta(liveBytes, committedBytes)
        let canonicalChanged = Self.differingByteCount(
            canonicalBeforeBytes,
            canonicalBytes
        )
        if predictedSuffixWasObserved,
           renderer.sliceFourRendererCounters.predictedDabCount != 0
        {
            predictedDuplicateSettledDabCount += 1
        }
        let staleReplayEpochViolationCount: Int
        if scene.name.contains("stale-epoch") {
            staleReplayEpochViolationCount = renderer
                .auditDelayedStaleReplayCompletionForHarness()
                .staleCompletionViolationCount
        } else {
            staleReplayEpochViolationCount = 0
        }

        if terminal == .cancelled {
            guard canonicalChanged == 0 else {
                throw SliceFourHarnessRunError.structuralMismatch(
                    sceneName: scene.name,
                    metric: .canonicalByteDelta,
                    relation: .equal,
                    expected: 0,
                    actual: canonicalChanged
                )
            }
        } else if !Self.hasNontransparentPixel(canonicalBytes) {
            throw SliceFourHarnessRunError.emptyCommittedOutput(scene.name)
        }

        let materialMismatch = recipe.material.family
            == expectedMaterial.brushMaterialFamily ? 0 : 1
        let replayMismatch = recipe.replayMode
            == expectedReplay.brushReplayMode ? 0 : 1
        var structural = Self.zeroStructuralValues()
        structural[.emittedDabCount] = renderer.harnessCounters.totalDabsThisStroke
        structural[.encodedInstanceCount] = renderer.harnessCounters.totalInstancesThisStroke
        structural[.previewCommitMaximumDelta] = liveCommitDelta
        structural[.previewCommitViolationCount] = terminal == .cancelled
            ? 0 : Self.previewCommitViolationCount(liveBytes, committedBytes, tolerance: 1)
        structural[.canonicalByteDelta] = canonicalChanged
        structural[.canonicalRevisionDelta] = receipt == nil ? 0 : 1
        structural[.historyCommandCount] = try historyRecorder?(receipt)
            ?? (receipt == nil ? 0 : 1)
        structural[.changedRegionCount] = receipt?.after.regions.rectangles.count ?? 0
        structural[.peakRetainedSampleCount] = peaks.samples
        structural[.peakRetainedDabCount] = peaks.dabs
        structural[.replayCount] = peaks.replays
        structural[.promotedSettledPrefixCount] = peaks.promotions
        structural[.replayDegradationCount] = peaks.degradations
        structural[.assetResidentBytes] = peaks.assets
        structural[.materialMismatchCount] = materialMismatch
        structural[.replayModeMismatchCount] = replayMismatch
        let finalCounters = renderer.sliceFourRendererCounters
        structural[.assetIdentityMismatchCount] =
            finalCounters.assetIdentityMismatchCount
                + finalCounters.assetFallbackCount
        structural[.predictedDuplicateSettledDabCount] =
            predictedDuplicateSettledDabCount
        structural[.staleReplayEpochViolationCount] =
            staleReplayEpochViolationCount
        structural[.processedWashPixelCount] = peaks.washPixels
        structural[.washWorkingBytes] = peaks.washBytes
        let auditValues = try runRendererAudits(
            scene: scene,
            recipe: recipe,
            library: library,
            primaryCanonicalBytes: canonicalBytes
        )
        for (name, value) in auditValues {
            if let metric = HarnessStructuralMetric(rawValue: name) {
                structural[metric] = value
            }
        }
        if scene.name.contains("long-stroke") {
            let stress = try fiveHundredDabPerformanceAudit(library: library)
            measurements.appendFiveHundredDabStress(
                stress.metrics,
                newDabCount: stress.newDabCount,
                newInstanceCount: stress.newInstanceCount
            )
        }

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let liveURL = outputDirectory.appendingPathComponent("\(scene.name).live.png")
        let committedURL = outputDirectory.appendingPathComponent("\(scene.name).committed.png")
        let canonicalURL = outputDirectory.appendingPathComponent("\(scene.name).canonical.png")
        try PNGWriter.write(texture: liveFrame.texture, to: liveURL)
        try PNGWriter.write(texture: committedFrame.texture, to: committedURL)
        try PNGWriter.write(texture: canonical, to: canonicalURL)

        try Self.evaluatePixelChecks(
            scene: scene,
            live: liveFrame.texture,
            committed: committedFrame.texture,
            canonical: canonical
        )
        let stringValues = Dictionary(
            uniqueKeysWithValues: structural.map { ($0.key.rawValue, $0.value) }
        )
        if scene.negativeControls.isEmpty {
            try Self.evaluateStructuralChecks(scene: scene, values: stringValues)
        } else {
            try Self.evaluateNegativeControls(scene: scene, values: stringValues)
        }

        let artifactDigests = try [liveURL, committedURL, canonicalURL].map {
            try Self.digest(url: $0)
        }
        let evidence = SliceFourMeasuredEvidence(
            schemaVersion: 5,
            sceneName: scene.name,
            recipeID: recipeID,
            seed: seed,
            material: expectedMaterial.rawValue,
            replayMode: expectedReplay.rawValue,
            attributedSampleCount: scene.attributedSamples.count,
            actualSampleCount: scene.attributedSamples.filter { $0.kind != .predicted }.count,
            predictedSampleCount: scene.attributedSamples.filter { $0.kind == .predicted }.count,
            structuralValues: stringValues,
            liveCommittedMaximumDelta: liveCommitDelta,
            canonicalChangedByteCount: canonicalChanged,
            auditValues: auditValues,
            rendererBacked: true,
            appServicesBacked: historyRecorder != nil
                && catalogRecipeVerifier != nil
                && anchorRecipes.count == 4,
            coverage: Self.coverage(
                for: scene,
                recipe: recipe,
                audits: auditValues
            ),
            artifacts: artifactDigests
        )
        let evidenceURL = outputDirectory.appendingPathComponent(
            "\(scene.name).slice4-evidence.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(evidence).write(to: evidenceURL, options: .atomic)

        let record = try benchmark(
            scene: scene,
            build: build,
            measurements: measurements,
            values: structural,
            recipe: recipe
        )
        let benchmarkURL = outputDirectory.appendingPathComponent(
            "\(scene.name).benchmark.json"
        )
        try BenchmarkRecord.encode(record).write(to: benchmarkURL, options: .atomic)
        if let receipt {
            renderer.releaseRasterRevisions([receipt.before.id, receipt.after.id])
        }
        return HarnessRunResult(
            imageURL: liveURL,
            benchmarkURL: benchmarkURL,
            benchmark: record,
            artifactURLs: [
                liveURL, committedURL, canonicalURL, evidenceURL, benchmarkURL,
            ]
        )
    }

    nonisolated public static func evaluateStructuralChecks(
        scene: HarnessScene,
        values: [String: Int]
    ) throws {
        for check in scene.structuralChecks {
            guard let actual = values[check.metric.rawValue] else {
                throw SliceFourHarnessRunError.missingStructuralMetric(
                    scene.name,
                    check.metric
                )
            }
            let passes = switch check.relation {
            case .equal: actual == check.value
            case .lessThanOrEqual: actual <= check.value
            case .greaterThanOrEqual: actual >= check.value
            }
            guard passes else {
                throw SliceFourHarnessRunError.structuralMismatch(
                    sceneName: scene.name,
                    metric: check.metric,
                    relation: check.relation,
                    expected: check.value,
                    actual: actual
                )
            }
        }
    }

    nonisolated static func evaluateNegativeControls(
        scene: HarnessScene,
        values: [String: Int]
    ) throws {
        guard let first = scene.negativeControls.first else {
            throw SliceFourHarnessRunError.negativeControlUnexpectedlyPassed(
                sceneName: scene.name,
                metric: .emittedDabCount
            )
        }
        var firstFailure: SliceFourHarnessRunError?
        for check in scene.negativeControls {
            do {
                try evaluateStructuralCheck(
                    check,
                    sceneName: scene.name,
                    values: values
                )
            } catch let error as SliceFourHarnessRunError {
                guard case .structuralMismatch = error else { throw error }
                firstFailure = firstFailure ?? error
                continue
            }
            throw SliceFourHarnessRunError.negativeControlUnexpectedlyPassed(
                sceneName: scene.name,
                metric: check.metric
            )
        }
        throw firstFailure
            ?? SliceFourHarnessRunError.negativeControlUnexpectedlyPassed(
                sceneName: scene.name,
                metric: first.metric
            )
    }

    nonisolated private static func evaluateStructuralCheck(
        _ check: HarnessStructuralCheck,
        sceneName: String,
        values: [String: Int]
    ) throws {
        guard let actual = values[check.metric.rawValue] else {
            throw SliceFourHarnessRunError.missingStructuralMetric(
                sceneName,
                check.metric
            )
        }
        let passes = switch check.relation {
        case .equal: actual == check.value
        case .lessThanOrEqual: actual <= check.value
        case .greaterThanOrEqual: actual >= check.value
        }
        guard passes else {
            throw SliceFourHarnessRunError.structuralMismatch(
                sceneName: sceneName,
                metric: check.metric,
                relation: check.relation,
                expected: check.value,
                actual: actual
            )
        }
    }

    nonisolated static func recipeCoverageOracleForTests(
        fragments: [CellFragment],
        pixelSize: PixelSize,
        recipe: BrushRecipe,
        radius: Float,
        brushAttributes: SIMD4<Float>,
        resolvedShapeIdentity: BrushTextureIdentity,
        resolvedGrainIdentity: BrushTextureIdentity
    ) -> OracleCoverage {
        recipeCoverageOracle(
            fragments: fragments,
            pixelSize: pixelSize,
            recipe: recipe,
            radius: radius,
            brushAttributes: brushAttributes,
            resolvedShapeIdentity: resolvedShapeIdentity,
            resolvedGrainIdentity: resolvedGrainIdentity
        )
    }

    nonisolated static func compareRecipeCoverageForTests(
        expected: OracleCoverage,
        productionBGRA: [UInt8]
    ) -> CoverageComparison {
        compareRecipeCoverage(
            expected: expected,
            productionBGRA: productionBGRA
        )
    }
}

@MainActor
private extension SliceFourHarnessRunner {
    func makeRenderer(
        scene: HarnessScene,
        library: any MTLLibrary
    ) throws -> GridRenderer {
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

    func takeToken() -> RendererOperationToken {
        let token = RendererOperationToken(rawValue: nextTokenRawValue)
        nextTokenRawValue &+= 1
        precondition(nextTokenRawValue != 0)
        return token
    }

    func runRendererAudits(
        scene: HarnessScene,
        recipe: BrushRecipe,
        library: any MTLLibrary,
        primaryCanonicalBytes: [UInt8]
    ) throws -> [String: Int] {
        var values: [String: Int] = [:]
        values["drawEraseChangedByteCount"] = try drawEraseAudit(
            scene: scene,
            recipe: recipe,
            library: library
        )

        if scene.name.contains("legacy") {
            let legacy = try BrushRecipe(id: BrushRecipeID(scene.recipeID!))
            let bytes = try renderAuditCanonical(
                scene: scene,
                recipe: legacy,
                seed: scene.seed!,
                library: library
            )
            values["legacyParityMaximumDelta"] = Self.maximumByteDelta(
                primaryCanonicalBytes,
                bytes
            )
            let matrix = try anchorTilingMatrixAudit(library: library)
            values["anchorTilingMatrixPassCount"] = matrix.passCount
            values["anchorTilingNoncentralCount"] = matrix.noncentralCount
            values["anchorTilingLiveCommitPassCount"] = matrix.liveCommitCount
            values["anchorTilingContinuityPassCount"] = matrix.continuityCount
            values["anchorTilingEraserAlphaPassCount"] = matrix.eraserAlphaCount
            values["anchorTilingEraserColorPassCount"] = matrix.eraserColorCount
            values["anchorCatalogEqualityCount"] = matrix.catalogEqualityCount
        }
        if scene.name.contains("pressure") {
            let same = try renderAuditCanonical(
                scene: scene,
                recipe: recipe,
                seed: scene.seed!,
                library: library
            )
            let different = try renderAuditCanonical(
                scene: scene,
                recipe: recipe,
                seed: scene.seed! &+ 1,
                library: library
            )
            let neutralPressure = try renderAuditCanonical(
                scene: scene,
                recipe: recipe,
                seed: scene.seed!,
                library: library,
                pressureOverride: 1
            )
            let hard = try BrushRecipe(id: BrushRecipeID("audit.hard-round"))
            let hardBytes = try renderAuditCanonical(
                scene: scene,
                recipe: hard,
                seed: scene.seed!,
                library: library
            )
            values["sameSeedMaximumDelta"] = Self.maximumByteDelta(
                primaryCanonicalBytes,
                same
            )
            values["differentSeedChangedByteCount"] = Self.differingByteCount(
                primaryCanonicalBytes,
                different
            )
            values["pressureResponseChangedByteCount"] = Self.differingByteCount(
                primaryCanonicalBytes,
                neutralPressure
            )
            values["shapeHardnessChangedByteCount"] = Self.differingByteCount(
                primaryCanonicalBytes,
                hardBytes
            )
        }
        if scene.name.contains("stale-epoch") {
            let failures = try failureAudit(
                scene: scene,
                recipe: recipe,
                library: library
            )
            values["gpuFailurePreservedCanonicalCount"] = failures.gpuPreserved
            values["allocationFailurePreservedCanonicalCount"] =
                failures.allocationPreserved
            values["gpuFailureExactErrorCount"] = failures.gpuExactError
            values["gpuFailureCompletionCount"] = failures.gpuCompletionCount
            values["gpuFailureTransientEmptyCount"] = failures.gpuTransientEmpty
            values["allocationFailureExactErrorCount"] =
                failures.allocationExactError
            values["allocationFailureCompletionCount"] =
                failures.allocationCompletionCount
            values["failureHistoryNoopCount"] = failures.historyNoop
        }
        return values
    }

    func anchorTilingMatrixAudit(
        library: any MTLLibrary
    ) throws -> (
        passCount: Int,
        noncentralCount: Int,
        liveCommitCount: Int,
        continuityCount: Int,
        eraserAlphaCount: Int,
        eraserColorCount: Int,
        catalogEqualityCount: Int
    ) {
        var passCount = 0
        var noncentralCount = 0
        var liveCommitCount = 0
        var continuityCount = 0
        var eraserAlphaCount = 0
        var eraserColorCount = 0
        let catalogEqualityCount = anchorRecipes.filter {
            catalogRecipeVerifier?($0) == true
        }.count
        for tiling in sliceFourLegacyTilings {
            for recipe in anchorRecipes {
                let renderer = try GridRenderer(
                    device: device,
                    library: library,
                    drawableSize: PatternSize(width: 160, height: 96),
                    configuration: TilingCanvasConfiguration(
                        pixelSize: PixelSize(width: 64, height: 64),
                        tiling: tiling
                    )
                )
                // With the 160x96 viewport centered over a 64x64 tile these
                // screen points map to world x=68...92: a derived, genuinely
                // noncentral cell rather than a hard-coded screen assertion.
                let start = ScreenPoint(x: 116, y: 48)
                let end = ScreenPoint(x: 140, y: 48)
                let draw = StrokeRenderStyle(
                    color: InkColor(red: 0.7, green: 0.2, blue: 0.5, alpha: 1)!,
                    diameter: 22,
                    compositeMode: .draw,
                    eraserStrength: 1,
                    recipe: recipe,
                    seed: 50_000 + UInt64(tiling.rawValue)
                )
                let token = takeToken()
                var receipt: RasterMutationReceipt?
                renderer.onOperationCompleted = {
                    if case let .rasterSuccess(value) = $0 { receipt = value }
                }
                try renderer.beginStroke(
                    token: token,
                    sample: .mouse(position: start, timestamp: 0, phase: .began),
                    style: draw
                )
                try renderer.requestStrokeCommit(
                    token: token,
                    sample: .mouse(position: end, timestamp: 0.02, phase: .ended),
                    maximumRetainedBytes: 64 * 1_024 * 1_024
                )
                _ = try renderer.flushPendingLiveForHarness()
                let live = try renderer.renderOffscreenDisplayForHarness(
                    width: 160,
                    height: 96,
                    showGridLines: false
                )
                _ = try renderer.submitCommitForHarness()
                try renderer.drainCompletedOperationsForHarness()
                let committed = try renderer.renderOffscreenDisplayForHarness(
                    width: 160,
                    height: 96,
                    showGridLines: false
                )
                if Self.maximumByteDelta(
                    Self.textureBytes(live.texture),
                    Self.textureBytes(committed.texture)
                ) <= 1 { liveCommitCount += 1 }
                if let receipt {
                    renderer.releaseRasterRevisions([
                        receipt.before.id, receipt.after.id,
                    ])
                }
                let drawn = Self.textureBytes(try renderer.copyCanonicalForHarness())
                let cell = renderer.harnessCell(for: start)
                let derivedNoncentral = cell.column != 0 || cell.row != 0
                if derivedNoncentral { noncentralCount += 1 }
                let seamRenderer = try GridRenderer(
                    device: device,
                    library: library,
                    drawableSize: PatternSize(width: 160, height: 96),
                    configuration: TilingCanvasConfiguration(
                        pixelSize: PixelSize(width: 64, height: 64),
                        tiling: tiling
                    )
                )
                // Keep the narrowest enabled anchor axis above one source
                // texel per destination pixel so the CPU texture oracle and
                // the GPU both sample the base mip.
                let seamRadius: Float = 192
                let seamCosine = cos(recipe.baseRotation)
                let seamSine = sin(recipe.baseRotation)
                let seamTransform = Affine2D(
                    xAxis: SIMD2(
                        seamCosine * seamRadius,
                        seamSine * seamRadius
                    ),
                    yAxis: SIMD2(
                        -seamSine * seamRadius * recipe.aspectRatio,
                        seamCosine * seamRadius * recipe.aspectRatio
                    ),
                    translation: SIMD2(64, 32)
                )
                let minimumSeamRadius = min(
                    simd_length(seamTransform.xAxis),
                    simd_length(seamTransform.yAxis)
                )
                let recipeFootprint = StampFootprint(
                    brushToWorld: seamTransform,
                    localBounds: AxisAlignedRect(
                        minimum: SIMD2(-1, -1),
                        maximum: SIMD2(1, 1)
                    ),
                    coverageSymmetry:
                        recipe.footprintCoverageSymmetry
                )
                let brushAttributes = SIMD4<Float>(
                    recipe.baseHardness,
                    recipe.grainTransform.scale,
                    recipe.grainTransform.offset.x,
                    recipe.grainTransform.offset.y
                )
                let brushFrame = try seamRenderer
                    .renderBrushFootprintForHarness(
                        footprint: recipeFootprint,
                        radius: minimumSeamRadius,
                        recipe: recipe,
                        brushAttributes: brushAttributes
                    )
                let recipeOracle = Self.recipeCoverageOracle(
                    fragments: brushFrame.fragments,
                    pixelSize: PixelSize(width: 64, height: 64),
                    recipe: recipe,
                    radius: minimumSeamRadius,
                    brushAttributes: brushAttributes,
                    resolvedShapeIdentity: brushFrame.shapeIdentity,
                    resolvedGrainIdentity: brushFrame.grainIdentity
                )
                let recipeCoverage = Self.compareRecipeCoverage(
                    expected: recipeOracle,
                    productionBGRA: Self.textureBytes(brushFrame.canonical)
                )
                let diagnosticTransform = Affine2D(
                    xAxis: SIMD2(40, 0),
                    yAxis: SIMD2(0, 40),
                    translation: SIMD2(64, 32)
                )
                let seamFootprint = StampFootprint(
                    brushToWorld: diagnosticTransform,
                    localBounds: AxisAlignedRect(
                        minimum: SIMD2(-0.75, -0.60),
                        maximum: SIMD2(0.85, 0.90)
                    ),
                    coverageSymmetry: .oriented
                )
                let seamFrame = try seamRenderer.renderDiagnosticFootprintForHarness(
                    footprint: seamFootprint,
                    radius: 40,
                    diagnosticMode: PatternDiagnosticWireCanonicalCoordinates,
                    width: 160,
                    height: 96
                )
                let oracle = TilingCoverageOracle.renderCanonical(
                    footprint: .asymmetricTriangle,
                    brushToWorld: diagnosticTransform,
                    tileSize: PixelSize(width: 64, height: 64),
                    tiling: tiling,
                    supersampling: 1
                )
                let seamBytes = Self.textureBytes(seamFrame.canonical)
                let coverage = HarnessRunner.compareOracleCoverage(
                    expected: oracle.coverage,
                    productionBGRA: seamBytes
                )
                let coordinateMismatches = HarnessRunner
                    .coordinateContinuityMismatchCount(
                        productionBGRA: seamBytes,
                        oracleBGRA: oracle.canonicalCoordinatesBGRA,
                        usesCircularRGDistance: true
                    )
                if derivedNoncentral,
                   brushFrame.assetsWereExact,
                   recipeCoverage.holeCount == 0,
                   recipeCoverage.phantomCount == 0,
                   coverage.holeCount == 0,
                   coverage.phantomCount == 0,
                   coordinateMismatches == 0
                {
                    continuityCount += 1
                }
                let erase = StrokeRenderStyle(
                    color: .black,
                    diameter: 30,
                    compositeMode: .erase,
                    eraserStrength: 1,
                    recipe: try BrushRecipe(id: BrushRecipeID("matrix.eraser")),
                    seed: 60_000 + UInt64(tiling.rawValue)
                )
                try executeAuditStroke(
                    renderer: renderer,
                    style: erase,
                    start: start,
                    end: end
                )
                let erased = Self.textureBytes(try renderer.copyCanonicalForHarness())
                if Self.differingByteCount(drawn, erased) > 0 { passCount += 1 }
                if Self.alphaSum(erased) < Self.alphaSum(drawn),
                   Self.alphaNeverIncreases(before: drawn, after: erased),
                   Self.transparentPixelCount(erased)
                    > Self.transparentPixelCount(drawn)
                {
                    eraserAlphaCount += 1
                }

                let colorRenderer = try GridRenderer(
                    device: device,
                    library: library,
                    drawableSize: PatternSize(width: 160, height: 96),
                    configuration: TilingCanvasConfiguration(
                        pixelSize: PixelSize(width: 64, height: 64),
                        tiling: tiling
                    )
                )
                try colorRenderer.replaceCanonicalPixelsForHarness(drawn)
                let coloredErase = StrokeRenderStyle(
                    color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!,
                    diameter: erase.diameter,
                    compositeMode: .erase,
                    eraserStrength: erase.eraserStrength,
                    recipe: erase.recipe,
                    seed: erase.seed
                )
                try executeAuditStroke(
                    renderer: colorRenderer,
                    style: coloredErase,
                    start: start,
                    end: end
                )
                let coloredErased = Self.textureBytes(
                    try colorRenderer.copyCanonicalForHarness()
                )
                if coloredErased == erased { eraserColorCount += 1 }
            }
        }
        return (
            passCount,
            noncentralCount,
            liveCommitCount,
            continuityCount,
            eraserAlphaCount,
            eraserColorCount,
            catalogEqualityCount
        )
    }

    nonisolated static func recipeCoverageOracle(
        fragments: [CellFragment],
        pixelSize: PixelSize,
        recipe: BrushRecipe,
        radius: Float,
        brushAttributes: SIMD4<Float>,
        resolvedShapeIdentity: BrushTextureIdentity,
        resolvedGrainIdentity: BrushTextureIdentity
    ) -> OracleCoverage {
        var bytes = [UInt8](
            repeating: 0,
            count: pixelSize.width * pixelSize.height
        )
        let inverses = fragments.map {
            ($0, $0.canonicalFromBrush.inverted())
        }
        for y in 0..<pixelSize.height {
            for x in 0..<pixelSize.width {
                let canonical = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                var accumulatedAlpha: Float = 0
                for (fragment, inverse) in inverses {
                    let brushLocal = inverse.applying(to: canonical)
                    guard abs(brushLocal.x) <= 1,
                          abs(brushLocal.y) <= 1,
                          fragment.brushClip.contains(
                              brushLocal,
                              tolerance: 0
                          )
                    else { continue }
                    let coverage = BrushCoverageOracle.coverage(
                        recipe: recipe,
                        brushLocal: brushLocal,
                        canonical: canonical,
                        hardness: brushAttributes.x,
                        radius: radius,
                        grainScale: brushAttributes.y,
                        grainOffset: SIMD2(
                            brushAttributes.z,
                            brushAttributes.w
                        ),
                        resolvedShapeIdentity: resolvedShapeIdentity,
                        resolvedGrainIdentity: resolvedGrainIdentity
                    )
                    accumulatedAlpha = coverage
                        + accumulatedAlpha * (1 - coverage)
                }
                bytes[y * pixelSize.width + x] = accumulatedAlpha >= 0.5 / 255
                    ? 255 : 0
            }
        }
        return OracleCoverage(pixelSize: pixelSize, bytes: bytes)
    }

    nonisolated static func compareRecipeCoverage(
        expected: OracleCoverage,
        productionBGRA: [UInt8]
    ) -> CoverageComparison {
        let width = expected.pixelSize.width
        let height = expected.pixelSize.height
        precondition(productionBGRA.count == width * height * 4)
        let actualBytes = (0..<(width * height)).map {
            productionBGRA[$0 * 4 + 3] > 0 ? UInt8(255) : UInt8(0)
        }
        var holes = 0
        var phantoms = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let expectedCovered = expected.bytes[index] > 0
                let actualCovered = actualBytes[index] > 0
                if expectedCovered && !actualCovered {
                    holes += 1
                } else if actualCovered && !expectedCovered {
                    phantoms += 1
                }
            }
        }
        return CoverageComparison(
            holeCount: holes,
            phantomCount: phantoms,
            maximumDelta: holes == 0 && phantoms == 0 ? 0 : 255
        )
    }

    func drawEraseAudit(
        scene: HarnessScene,
        recipe: BrushRecipe,
        library: any MTLLibrary
    ) throws -> Int {
        let renderer = try makeRenderer(scene: scene, library: library)
        let y = Float(scene.height) * 0.5
        let start = ScreenPoint(x: Float(scene.width) * 0.3, y: y)
        let end = ScreenPoint(x: Float(scene.width) * 0.7, y: y)
        let draw = StrokeRenderStyle(
            color: InkColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)!,
            diameter: 28,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 9_001
        )
        try executeAuditStroke(renderer: renderer, style: draw, start: start, end: end)
        let drawn = Self.textureBytes(try renderer.copyCanonicalForHarness())
        let eraserRecipe = try BrushRecipe(id: BrushRecipeID("audit.hard-round-eraser"))
        let erase = StrokeRenderStyle(
            color: .black,
            diameter: 36,
            compositeMode: .erase,
            eraserStrength: 1,
            recipe: eraserRecipe,
            seed: 9_002
        )
        try executeAuditStroke(renderer: renderer, style: erase, start: start, end: end)
        let erased = Self.textureBytes(try renderer.copyCanonicalForHarness())
        return Self.differingByteCount(drawn, erased)
    }

    func renderAuditCanonical(
        scene: HarnessScene,
        recipe: BrushRecipe,
        seed: UInt64,
        library: any MTLLibrary,
        pressureOverride: Float? = nil
    ) throws -> [UInt8] {
        let renderer = try makeRenderer(scene: scene, library: library)
        let attributed = scene.attributedSamples
        let converted = try attributed.enumerated().map { index, input in
            let phase: StrokePhase = if index == 0 {
                .began
            } else if index == attributed.count - 1 {
                .ended
            } else {
                .moved
            }
            guard let sample = StrokeSample.validated(
                position: ScreenPoint(x: input.x, y: input.y),
                pressure: pressureOverride ?? input.pressure,
                timestamp: input.timestamp,
                phase: phase,
                source: input.source.strokeSource,
                kind: input.kind == .predicted ? .actual : input.kind.strokeSampleKind,
                capabilities: StrokeInputCapabilities(rawValue: input.capabilities),
                altitude: input.altitude,
                azimuth: input.azimuth,
                roll: input.roll
            ) else {
                throw SliceFourHarnessRunError.invalidTrace("audit sample is invalid")
            }
            return sample
        }
        let style = StrokeRenderStyle(
            color: InkColor(red: 0.16, green: 0.38, blue: 0.82, alpha: 0.82)!,
            diameter: 24,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: seed
        )
        let token = takeToken()
        var receipts: [RasterMutationReceipt] = []
        renderer.onOperationCompleted = {
            if case let .rasterSuccess(receipt) = $0 { receipts.append(receipt) }
        }
        try renderer.beginStroke(token: token, sample: converted[0], style: style)
        for sample in converted.dropFirst().dropLast() {
            try renderer.appendStroke(token: token, sample: sample)
        }
        try renderer.requestStrokeCommit(
            token: token,
            sample: converted.last!,
            maximumRetainedBytes: 64 * 1_024 * 1_024
        )
        _ = try renderer.flushPendingLiveForHarness()
        _ = try renderer.submitCommitForHarness()
        try renderer.drainCompletedOperationsForHarness()
        let bytes = Self.textureBytes(try renderer.copyCanonicalForHarness())
        if let receipt = receipts.first {
            renderer.releaseRasterRevisions([receipt.before.id, receipt.after.id])
        }
        return bytes
    }

    func executeAuditStroke(
        renderer: GridRenderer,
        style: StrokeRenderStyle,
        start: ScreenPoint,
        end: ScreenPoint
    ) throws {
        let token = takeToken()
        var receipt: RasterMutationReceipt?
        renderer.onOperationCompleted = {
            if case let .rasterSuccess(value) = $0 { receipt = value }
        }
        try renderer.beginStroke(
            token: token,
            sample: .mouse(position: start, timestamp: 0, phase: .began),
            style: style
        )
        try renderer.requestStrokeCommit(
            token: token,
            sample: .mouse(position: end, timestamp: 0.02, phase: .ended),
            maximumRetainedBytes: 64 * 1_024 * 1_024
        )
        _ = try renderer.flushPendingLiveForHarness()
        _ = try renderer.submitCommitForHarness()
        try renderer.drainCompletedOperationsForHarness()
        if let receipt {
            renderer.releaseRasterRevisions([receipt.before.id, receipt.after.id])
        }
    }

    func fiveHundredDabPerformanceAudit(
        library: any MTLLibrary
    ) throws -> (
        metrics: GPUFrameMetrics,
        newDabCount: Int,
        newInstanceCount: Int
    ) {
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 512, height: 512),
            configuration: TilingCanvasConfiguration(
                pixelSize: PixelSize(width: 512, height: 512),
                tiling: .grid
            )
        )
        try renderer.injectFiveHundredInteriorDabsIntoOneFrame()
        let prepared = renderer.harnessCounters
        guard prepared.newDabsThisEvent == 500,
              prepared.totalDabsThisStroke == 500,
              prepared.totalInstancesThisStroke == 500
        else {
            throw SliceFourHarnessRunError.invalidTrace(
                "500-dab audit did not prepare exactly 500 new dabs"
            )
        }
        let flush = try renderer.flushPendingLiveForHarness()
        let newInstanceCount = renderer.harnessCounters.newInstancesThisFrame
        guard newInstanceCount == 500 else {
            throw SliceFourHarnessRunError.invalidTrace(
                "500-dab audit encoded \(newInstanceCount) instances"
            )
        }
        return (flush.metrics, prepared.newDabsThisEvent, newInstanceCount)
    }

    func failureAudit(
        scene: HarnessScene,
        recipe: BrushRecipe,
        library: any MTLLibrary
    ) throws -> (
        gpuPreserved: Int,
        allocationPreserved: Int,
        gpuExactError: Int,
        gpuCompletionCount: Int,
        gpuTransientEmpty: Int,
        allocationExactError: Int,
        allocationCompletionCount: Int,
        historyNoop: Int
    ) {
        let renderer = try makeRenderer(scene: scene, library: library)
        let before = Self.textureBytes(try renderer.copyCanonicalForHarness())
        let token = takeToken()
        var completions: [RendererOperationCompletion] = []
        renderer.onOperationCompleted = { completions.append($0) }
        let style = StrokeRenderStyle(
            color: .black,
            diameter: 20,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 7_777
        )
        try renderer.beginStroke(
            token: token,
            sample: .mouse(
                position: ScreenPoint(x: 24, y: 24),
                timestamp: 0,
                phase: .began
            ),
            style: style
        )
        try renderer.requestStrokeCommit(
            token: token,
            sample: .mouse(
                position: ScreenPoint(x: 72, y: 72),
                timestamp: 0.02,
                phase: .ended
            ),
            maximumRetainedBytes: 64 * 1_024 * 1_024
        )
        renderer.deferNextFrameOutcomeForHarness()
        _ = try renderer.flushPendingLiveForHarness(forceFailure: true)
        renderer.releaseDeferredFrameOutcomesForHarness()
        var gpuExactError = 0
        do {
            try renderer.drainCompletedOperationsForHarness()
        } catch let error as MetalRendererError {
            gpuExactError = error == .commandFailed(
                "injected harness command-buffer failure"
            ) ? 1 : 0
        }
        let afterGPU = Self.textureBytes(try renderer.copyCanonicalForHarness())
        let gpuFailureCompletionCount = completions.reduce(into: 0) {
            if case let .failure(completionToken, error) = $1,
               completionToken == token,
               error == .commandFailed("injected harness command-buffer failure")
            { $0 += 1 }
        }
        let gpuCounters = renderer.sliceFourRendererCounters
        let gpuTransientEmpty = renderer.isIdle
            && gpuCounters.retainedSampleCount == 0
            && gpuCounters.retainedDabCount == 0 ? 1 : 0

        let allocationRenderer = try makeRenderer(scene: scene, library: library)
        let allocationBefore = Self.textureBytes(
            try allocationRenderer.copyCanonicalForHarness()
        )
        var allocationCompletions: [RendererOperationCompletion] = []
        allocationRenderer.onOperationCompleted = {
            allocationCompletions.append($0)
        }
        var allocationExactError = 0
        do {
            try allocationRenderer.requestResizeForHarness(
                token: takeToken(),
                to: PixelSize(width: scene.tileWidth! + 1, height: scene.tileHeight!),
                maximumRetainedBytes: 64 * 1_024 * 1_024,
                forceResourceAllocationFailure: true
            )
        } catch let error as MetalRendererError {
            allocationExactError = error == .textureAllocationFailed ? 1 : 0
        }
        let allocationAfter = Self.textureBytes(
            try allocationRenderer.copyCanonicalForHarness()
        )
        let historyNoop = try historyRecorder?(nil) == 0 ? 1 : 0
        return (
            before == afterGPU && renderer.isIdle ? 1 : 0,
            allocationBefore == allocationAfter && allocationRenderer.isIdle ? 1 : 0,
            gpuExactError,
            gpuFailureCompletionCount,
            gpuTransientEmpty,
            allocationExactError,
            allocationCompletions.count,
            historyNoop
        )
    }

    private func benchmark(
        scene: HarnessScene,
        build: BenchmarkBuild,
        measurements: Measurements,
        values: [HarnessStructuralMetric: Int],
        recipe: BrushRecipe
    ) throws -> BenchmarkRecord {
        let processInfo = ProcessInfo.processInfo
        let eventTimes = measurements.eventToSubmit.isEmpty
            ? measurements.cpu : measurements.eventToSubmit
        return BenchmarkRecord(
            schemaVersion: 5,
            timestampUTC: ISO8601DateFormatter().string(from: Date()),
            sceneName: scene.name,
            hardware: BenchmarkHardware(
                gpuName: device.name,
                logicalProcessorCount: processInfo.activeProcessorCount,
                physicalMemoryBytes: processInfo.physicalMemory
            ),
            operatingSystem: processInfo.operatingSystemVersionString,
            build: build,
            frameCount: measurements.cpu.count,
            cpuEncodeMilliseconds: measurements.cpu,
            gpuMilliseconds: measurements.gpu,
            peakResidentBytes: try Self.peakResidentBytes(),
            brushProcessingMilliseconds: measurements.brush.isEmpty
                ? measurements.cpu : measurements.brush,
            eventToSubmitMilliseconds: eventTimes,
            dabGPUMilliseconds: measurements.dabGPU,
            gridGPUMilliseconds: measurements.gridGPU,
            commitGPUMilliseconds: measurements.commitGPU,
            displayFrameBudgetMilliseconds: Self.displayFrameBudgetMilliseconds,
            newInstanceCounts: measurements.dabInstanceCounts,
            missedFrameCount: eventTimes.filter {
                $0 > Self.displayFrameBudgetMilliseconds
            }.count,
            tilingRawValue: scene.tiling?.rawValue,
            tileWidth: scene.tileWidth,
            tileHeight: scene.tileHeight,
            totalProjectedFragmentCount: values[.encodedInstanceCount] ?? 0,
            maximumFragmentsPerFootprint: max(
                1,
                (values[.encodedInstanceCount] ?? 0)
                    / max(1, values[.emittedDabCount] ?? 0)
            ),
            totalInstanceBytes: (values[.encodedInstanceCount] ?? 0)
                * ShaderABI.projectedStampInstanceStride,
            diagnosticMode: scene.diagnosticMode?.rawValue,
            revisionCaptureMilliseconds: [],
            revisionRestoreMilliseconds: [],
            historyResidentBytes: 0,
            historyCommandCount: values[.historyCommandCount] ?? 0,
            historyCanUndo: (values[.historyCommandCount] ?? 0) > 0,
            historyCanRedo: false,
            historyAppendCount: values[.historyCommandCount] ?? 0,
            historyNavigationFinishCount: 0,
            historyReleasedRevisionCount: 0,
            changedRegionCount: values[.changedRegionCount] ?? 0,
            coloredOutputMismatchCount: 0,
            previewCommitViolationCount:
                values[.previewCommitViolationCount] ?? 0,
            recipeID: recipe.id.rawValue,
            material: scene.expectedMaterial?.rawValue,
            seed: scene.seed,
            replayMode: scene.replayMode?.rawValue,
            peakRetainedSampleCount: values[.peakRetainedSampleCount],
            peakRetainedDabCount: values[.peakRetainedDabCount],
            replayCount: values[.replayCount],
            promotedSettledPrefixCount:
                values[.promotedSettledPrefixCount],
            replayDegradationCount: values[.replayDegradationCount],
            assetResidentBytes: values[.assetResidentBytes],
            materialGPUMilliseconds: measurements.dabGPU,
            fiveHundredDabStressFrameIndex:
                measurements.fiveHundredDabStressFrameIndex,
            fiveHundredDabStressNewDabCount:
                measurements.fiveHundredDabStressNewDabCount,
            processedWashPixelCount: values[.processedWashPixelCount],
            washWorkingBytes: values[.washWorkingBytes],
            program: scene.program?.rawValue
        )
    }
}

private extension SliceFourHarnessRunner {
    static func validateTrace(_ samples: [HarnessAttributedSample]) throws {
        guard samples.count >= 2, samples.first?.phase == .began else {
            throw SliceFourHarnessRunError.invalidTrace(
                "the trace must begin and contain a terminal sample"
            )
        }
        guard samples.first?.kind != .predicted else {
            throw SliceFourHarnessRunError.invalidTrace(
                "the began sample cannot be predicted"
            )
        }
        guard samples.last?.phase == .ended
                || samples.last?.phase == .cancelled
        else {
            throw SliceFourHarnessRunError.invalidTrace(
                "the last sample is neither ended nor cancelled"
            )
        }
        for pair in zip(samples, samples.dropFirst()) {
            guard pair.1.timestamp >= pair.0.timestamp else {
                throw SliceFourHarnessRunError.invalidTrace(
                    "timestamps decrease"
                )
            }
            guard pair.1.phase != .began else {
                throw SliceFourHarnessRunError.invalidTrace(
                    "a second began sample appears"
                )
            }
        }
        guard samples.dropLast().dropFirst().allSatisfy({
            $0.phase == .moved
        }) else {
            throw SliceFourHarnessRunError.invalidTrace(
                "only the first and last samples may be lifecycle terminals"
            )
        }
    }

    nonisolated static func recipe(identity: String) throws -> BrushRecipe {
        let id = BrushRecipeID(identity)
        if identity.contains("legacy") {
            return try BrushRecipe(id: id)
        }
        if identity.contains("prediction") || identity.contains("stale") {
            return try BrushRecipe(
                id: id,
                baseSpacingFraction: 0.1,
                maximumSpacingFraction: 0.18,
                sizeMapping: .boundedPower(
                    input: .pressure,
                    output: 0.35...1,
                    exponent: 0.8
                ),
                taper: BrushTaperConfiguration(
                    start: .diameterMultiples(1.25),
                    end: .diameterMultiples(1.5),
                    minimumSize: 0.25,
                    minimumFlow: 0.2,
                    effects: [.size, .flow]
                ),
                replayMode: .replayTail,
                replayLimits: BrushRecipePolicy.replayTailLimits
            )
        }
        if identity.contains("pressure") {
            return try BrushRecipe(
                id: id,
                shape: .asset("builtin.shape.soft-round"),
                grain: .asset("builtin.grain.noise"),
                baseSpacingFraction: 0.1,
                maximumSpacingFraction: 0.2,
                baseFlow: 0.75,
                baseHardness: 0.65,
                baseScatterFraction: 0.08,
                sizeMapping: .boundedPower(
                    input: .pressure,
                    output: 0.25...1,
                    exponent: 0.8
                ),
                flowMapping: .linear(input: .pressure, output: 0.25...1),
                scatterMapping: .linear(input: .pressure, output: 0.25...1),
                randomization: BrushRandomization(
                    spacing: 0.1,
                    scatter: 1,
                    rotation: 0.15,
                    grain: 0.3,
                    material: 0.1
                )
            )
        }
        if identity.contains("dry") {
            let local = identity.contains("local")
                || identity.contains("tilings")
                || identity.contains("grain")
            return try BrushRecipe(
                id: id,
                shape: .hardRound,
                grain: .paper,
                grainCoordinateMode: local ? .brushLocal : .canonical,
                grainTransform: BrushGrainTransform(
                    scale: 1.5,
                    rotation: 0,
                    offset: .zero
                ),
                material: BrushMaterial(
                    family: .dry,
                    strength: 0.85,
                    wetness: 0,
                    bleedRadius: 0,
                    softenPasses: 0,
                    accumulationLimit: 1
                ),
                baseSpacingFraction: 0.1,
                maximumSpacingFraction: 0.2,
                baseFlow: 0.7,
                strokeOpacity: 0.9,
                baseHardness: 0.75,
                baseScatterFraction: 0.03,
                aspectRatio: 0.7,
                sizeMapping: .boundedPower(
                    input: .pressure,
                    output: 0.3...1,
                    exponent: 1.25
                ),
                flowMapping: .linear(input: .pressure, output: 0.35...1),
                rotationMapping: .linear(
                    input: .direction,
                    output: -Float.pi...Float.pi
                ),
                scatterMapping: .linear(input: .pressure, output: 0.5...1),
                randomization: BrushRandomization(
                    spacing: 0.1,
                    scatter: 1,
                    rotation: 0,
                    grain: 0.35,
                    material: 0.15
                ),
                replayMode: identity.contains("long")
                    ? .replayTail : .appendOnly,
                replayLimits: identity.contains("long")
                    ? BrushRecipePolicy.replayTailLimits : nil
            )
        }
        if identity.contains("glaze") {
            return try BrushRecipe(
                id: id,
                shape: .chisel,
                grain: .opaque,
                material: BrushMaterial(
                    family: .glaze,
                    strength: 0.75,
                    wetness: 0.2,
                    bleedRadius: 0,
                    softenPasses: 0,
                    accumulationLimit: 0.8
                ),
                baseSpacingFraction: 0.16,
                maximumSpacingFraction: 0.3,
                baseFlow: 0.2,
                strokeOpacity: 0.65,
                baseHardness: 0.7,
                aspectRatio: 0.35,
                sizeMapping: .linear(input: .pressure, output: 0.6...1),
                flowMapping: .linear(input: .pressure, output: 0.5...1),
                rotationMapping: .linear(
                    input: .direction,
                    output: -Float.pi...Float.pi
                )
            )
        }
        if identity.contains("wash") {
            return try BrushRecipe(
                id: id,
                shape: .softRound,
                grain: .paper,
                grainCoordinateMode: .canonical,
                grainTransform: BrushGrainTransform(
                    scale: 1.2,
                    rotation: 0,
                    offset: .zero
                ),
                material: BrushMaterial(
                    family: .boundedWash,
                    strength: 0.65,
                    wetness: 0.8,
                    bleedRadius: 12,
                    softenPasses: 2,
                    accumulationLimit: 0.7
                ),
                baseSpacingFraction: 0.15,
                maximumSpacingFraction: 0.3,
                baseFlow: 0.25,
                strokeOpacity: 0.6,
                baseHardness: 0.2,
                sizeMapping: .linear(input: .pressure, output: 0.6...1),
                flowMapping: .linear(input: .pressure, output: 0.5...1),
                randomization: BrushRandomization(
                    spacing: 0.05,
                    scatter: 0,
                    rotation: 0,
                    grain: 0.2,
                    material: 0.1
                ),
                replayMode: .boundedWholeStroke,
                replayLimits: BrushRecipePolicy.wholeStrokeLimits
            )
        }
        if identity.contains("ink") {
            return try BrushRecipe(
                id: id,
                baseSpacingFraction: 0.08,
                maximumSpacingFraction: 0.15,
                sizeMapping: .boundedPower(
                    input: .pressure,
                    output: 0.3...1,
                    exponent: 0.75
                )
            )
        }
        throw SliceFourHarnessRunError.unknownRecipe(identity)
    }

    nonisolated static func coverage(
        for scene: HarnessScene,
        recipe: BrushRecipe,
        audits: [String: Int]
    ) -> [String] {
        var values: Set<String> = [
            "renderer.grid",
            "material.\(scene.expectedMaterial!.rawValue)",
            "replay.\(scene.replayMode!.rawValue)",
            "tiling.\(scene.tiling!.rawValue)",
            "shape.\(shapeName(recipe.shape))",
            "grain.\(grainName(recipe.grain))",
            "grain-coordinate.\(recipe.grainCoordinateMode == .canonical ? "canonical" : "brush-local")",
            "live-and-commit",
        ]
        let pressures = Set(scene.attributedSamples.map(\.pressure))
        if pressures.count > 1 { values.insert("pressure-flow-size") }
        if scene.attributedSamples.contains(where: { $0.kind == .predicted }) {
            values.formUnion(["prediction", "prediction-replacement"])
        }
        if scene.attributedSamples.last?.phase == .cancelled {
            values.formUnion(["cancel", "history-noop", "stale-epoch"])
        } else {
            values.formUnion(["draw", "history-commit"])
        }
        if scene.attributedSamples.contains(where: {
            $0.x < 0 || $0.y < 0
                || $0.x >= Float(scene.tileWidth!)
                || $0.y >= Float(scene.tileHeight!)
        }) {
            values.insert("noncentral-cell")
        }
        if recipe.taper != .none { values.insert("taper") }
        if audits["sameSeedMaximumDelta"] == 0,
           (audits["differentSeedChangedByteCount"] ?? 0) > 0 {
            values.formUnion(["seeded-randomness", "same-seed", "different-seed"])
        }
        if (audits["drawEraseChangedByteCount"] ?? 0) > 0 {
            values.insert("draw-and-erase")
        }
        if audits["gpuFailurePreservedCanonicalCount"] == 1,
           audits["allocationFailurePreservedCanonicalCount"] == 1 {
            values.insert("failure-preserves-canonical")
        }
        if audits["legacyParityMaximumDelta"] == 0,
           audits.keys.contains("legacyParityMaximumDelta") {
            values.insert("legacy-parity")
        }
        if audits["anchorTilingMatrixPassCount"] == 28,
           audits["anchorTilingNoncentralCount"] == 28 {
            values.formUnion([
                "anchor-tiling-matrix",
                "anchor-tiling-noncentral-matrix",
                "anchor-tiling-draw-erase-matrix",
            ])
        }
        if scene.expectedMaterial == .boundedWash {
            values.formUnion(["bounded-wash", "wash-bounds"])
        }
        if scene.name.contains("long") {
            values.formUnion(["long-stroke", "retention-bounds"])
        }
        if case .asset = recipe.shape { values.insert("shape-asset") }
        if case .asset = recipe.grain { values.insert("grain-asset") }
        return values.sorted()
    }

    nonisolated static func shapeName(_ shape: BrushShapeDescriptor) -> String {
        switch shape {
        case .hardRound: "hard-round"
        case .softRound: "soft-round"
        case .chisel: "chisel"
        case let .asset(id): "asset:\(id)"
        }
    }

    nonisolated static func grainName(_ grain: BrushGrainDescriptor) -> String {
        switch grain {
        case .opaque: "opaque"
        case .paper: "paper"
        case .noise: "noise"
        case let .asset(id): "asset:\(id)"
        }
    }

    static func zeroStructuralValues()
        -> [HarnessStructuralMetric: Int]
    {
        Dictionary(uniqueKeysWithValues: HarnessStructuralMetric.sliceFourEvidenceMetrics.map {
            ($0, 0)
        })
    }

    static func evaluatePixelChecks(
        scene: HarnessScene,
        live: any MTLTexture,
        committed: any MTLTexture,
        canonical: any MTLTexture
    ) throws {
        for check in scene.checks {
            let texture: (any MTLTexture)? = switch check.channel {
            case .screen, .liveScreen: live
            case .committedScreen: committed
            case .canonical: canonical
            case .oracleCoverage, .oracleCanonicalCoordinates,
                 .oracleBrushLocalCoordinates: nil
            }
            guard let texture else {
                throw SliceFourHarnessRunError.missingPixelArtifact(
                    scene.name,
                    check.channel
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
            let pixel = PNGWriter.pixel(in: texture, x: check.x, y: check.y)
            let actual = [pixel.x, pixel.y, pixel.z, pixel.w]
            let expected = check.expectedBGRA
            guard zip(actual, expected).allSatisfy({ lhs, rhs in
                abs(Int(lhs) - Int(rhs)) <= Int(check.tolerance)
            }) else {
                throw SliceFourHarnessRunError.pixelMismatch(
                    sceneName: scene.name,
                    channel: check.channel,
                    x: check.x,
                    y: check.y,
                    expected: expected,
                    actual: actual,
                    tolerance: check.tolerance
                )
            }
        }
    }

    nonisolated static func textureBytes(_ texture: any MTLTexture) -> [UInt8] {
        precondition(texture.pixelFormat == .bgra8Unorm)
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
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

    nonisolated static func maximumByteDelta(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> Int {
        guard lhs.count == rhs.count else { return 255 }
        return zip(lhs, rhs).reduce(0) {
            max($0, abs(Int($1.0) - Int($1.1)))
        }
    }

    nonisolated static func differingByteCount(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> Int {
        guard lhs.count == rhs.count else { return max(lhs.count, rhs.count) }
        return zip(lhs, rhs).reduce(0) {
            $0 + ($1.0 == $1.1 ? 0 : 1)
        }
    }

    nonisolated static func previewCommitViolationCount(
        _ live: [UInt8],
        _ committed: [UInt8],
        tolerance: UInt8
    ) -> Int {
        guard live.count == committed.count else {
            return max(live.count, committed.count)
        }
        let limit = Int(tolerance)
        return zip(live, committed).reduce(0) {
            $0 + (abs(Int($1.0) - Int($1.1)) > limit ? 1 : 0)
        }
    }

    nonisolated static func hasNontransparentPixel(_ bytes: [UInt8]) -> Bool {
        stride(from: 3, to: bytes.count, by: 4).contains {
            bytes[$0] != 0
        }
    }

    nonisolated static func alphaSum(_ bytes: [UInt8]) -> UInt64 {
        stride(from: 3, to: bytes.count, by: 4).reduce(into: 0) {
            $0 += UInt64(bytes[$1])
        }
    }

    nonisolated static func alphaNeverIncreases(
        before: [UInt8],
        after: [UInt8]
    ) -> Bool {
        guard before.count == after.count else { return false }
        return stride(from: 3, to: before.count, by: 4).allSatisfy {
            after[$0] <= before[$0]
        }
    }

    nonisolated static func transparentPixelCount(_ bytes: [UInt8]) -> Int {
        stride(from: 3, to: bytes.count, by: 4).reduce(into: 0) {
            if bytes[$1] == 0 { $0 += 1 }
        }
    }

    nonisolated static func digest(url: URL) throws -> SliceFourArtifactDigest {
        let data = try Data(contentsOf: url)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return SliceFourArtifactDigest(
            fileName: url.lastPathComponent,
            byteCount: data.count,
            fnv1a64: String(format: "%016llx", hash)
        )
    }

    nonisolated static func peakResidentBytes() throws -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
            throw HarnessRunError.processMetricsUnavailable
        }
        return UInt64(usage.ru_maxrss)
    }
}

private extension HarnessStructuralMetric {
    static let sliceFourEvidenceMetrics: [HarnessStructuralMetric] = [
        .emittedDabCount,
        .encodedInstanceCount,
        .canonicalRevisionDelta,
        .previewCommitMaximumDelta,
        .canonicalByteDelta,
        .previewCommitViolationCount,
        .historyCommandCount,
        .changedRegionCount,
        .peakRetainedSampleCount,
        .peakRetainedDabCount,
        .replayCount,
        .promotedSettledPrefixCount,
        .replayDegradationCount,
        .assetResidentBytes,
        .materialMismatchCount,
        .replayModeMismatchCount,
        .assetIdentityMismatchCount,
        .predictedDuplicateSettledDabCount,
        .staleReplayEpochViolationCount,
        .processedWashPixelCount,
        .washWorkingBytes,
        .drawEraseChangedByteCount,
        .legacyParityMaximumDelta,
        .anchorTilingMatrixPassCount,
        .anchorTilingNoncentralCount,
        .anchorTilingLiveCommitPassCount,
        .anchorTilingContinuityPassCount,
        .anchorTilingEraserAlphaPassCount,
        .anchorTilingEraserColorPassCount,
        .anchorCatalogEqualityCount,
        .sameSeedMaximumDelta,
        .differentSeedChangedByteCount,
        .pressureResponseChangedByteCount,
        .shapeHardnessChangedByteCount,
        .gpuFailurePreservedCanonicalCount,
        .allocationFailurePreservedCanonicalCount,
    ]
}

public enum SliceFourEvidenceValidationStatus: Equatable, Sendable {
    case passed
    case performancePending(gpuName: String)
}

public enum SliceFourEvidenceValidationError: Error, Equatable, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self { case let .invalid(message): message }
    }
}

public enum SliceFourEvidenceValidator {
    public static let sceneNames = [
        "slice4-legacy-ink-parity",
        "slice4-pressure-scatter",
        "slice4-dry-grain-tilings",
        "slice4-glaze-live-commit",
        "slice4-wash-bounds",
        "slice4-prediction-taper-replay",
        "slice4-stale-epoch-cancel",
        "slice4-long-stroke-bounds",
    ]
    static let requiredNegativeControlMetrics: [
        String: [HarnessStructuralMetric]
    ] = [
        "slice4-legacy-ink-parity": [
            .legacyParityMaximumDelta,
            .anchorTilingMatrixPassCount,
            .anchorTilingNoncentralCount,
            .anchorTilingLiveCommitPassCount,
            .anchorTilingContinuityPassCount,
            .anchorTilingEraserAlphaPassCount,
            .anchorTilingEraserColorPassCount,
            .anchorCatalogEqualityCount,
            .historyCommandCount,
        ],
        "slice4-pressure-scatter": [
            .pressureResponseChangedByteCount,
            .sameSeedMaximumDelta,
            .differentSeedChangedByteCount,
            .shapeHardnessChangedByteCount,
            .assetIdentityMismatchCount,
        ],
        "slice4-dry-grain-tilings": [
            .assetIdentityMismatchCount,
            .materialMismatchCount,
            .previewCommitViolationCount,
        ],
        "slice4-glaze-live-commit": [
            .previewCommitViolationCount,
            .materialMismatchCount,
            .historyCommandCount,
        ],
        "slice4-wash-bounds": [
            .processedWashPixelCount,
            .washWorkingBytes,
            .materialMismatchCount,
            .replayDegradationCount,
        ],
        "slice4-prediction-taper-replay": [
            .predictedDuplicateSettledDabCount,
            .replayCount,
            .historyCommandCount,
        ],
        "slice4-stale-epoch-cancel": [
            .staleReplayEpochViolationCount,
            .canonicalByteDelta,
            .gpuFailurePreservedCanonicalCount,
            .allocationFailurePreservedCanonicalCount,
        ],
        "slice4-long-stroke-bounds": [
            .replayDegradationCount,
            .peakRetainedSampleCount,
            .peakRetainedDabCount,
            .promotedSettledPrefixCount,
        ],
    ]

    public static func validate(
        positiveRoot: URL,
        negativeRoot: URL,
        sceneRoot: URL,
        expectedCommit: String
    ) throws -> SliceFourEvidenceValidationStatus {
        guard !expectedCommit.isEmpty else { throw invalid("expected commit is empty") }
        guard try directoryNames(at: positiveRoot) == Set(sceneNames) else {
            throw invalid("positive artifact directories do not match the Slice 4 scene matrix")
        }
        guard try directoryNames(at: negativeRoot) == Set(sceneNames) else {
            throw invalid("negative artifact directories do not match the Slice 4 scene matrix")
        }

        var provenance: (BenchmarkHardware, String)?
        var aggregateCoverage = Set<String>()
        var tilings = Set<UInt32>()
        var materials = Set<String>()
        var measuredFiveHundredDabGPU: [Double] = []
        for name in sceneNames {
            let scene = try loadScene(sceneRoot.appendingPathComponent("\(name).json"))
            let negativeScene = try loadScene(
                sceneRoot.appendingPathComponent("\(name)-negative-control.json")
            )
            try validateNegativeControl(positive: scene, negative: negativeScene)

            let directory = positiveRoot.appendingPathComponent(name)
            let expectedFiles: Set<String> = [
                "stdout.log", "stderr.log",
                "\(name).live.png", "\(name).committed.png",
                "\(name).canonical.png", "\(name).benchmark.json",
                "\(name).slice4-evidence.json",
            ]
            guard try directoryNames(at: directory) == expectedFiles else {
                throw invalid("\(name): artifact file set is incomplete or unexpected")
            }
            let stderr = try Data(contentsOf: directory.appendingPathComponent("stderr.log"))
            guard stderr.isEmpty else { throw invalid("\(name): positive stderr is not empty") }
            let stdout = try String(
                contentsOf: directory.appendingPathComponent("stdout.log"),
                encoding: .utf8
            )
            let expectedStdout = "HARNESS PASS scene=\(name) image=\(directory.appendingPathComponent("\(name).live.png").path) benchmark=\(directory.appendingPathComponent("\(name).benchmark.json").path)\n"
            guard stdout == expectedStdout else {
                throw invalid("\(name): stdout is not the exact pass line")
            }
            let evidence = try JSONDecoder().decode(
                SliceFourMeasuredEvidence.self,
                from: Data(contentsOf: directory.appendingPathComponent(
                    "\(name).slice4-evidence.json"
                ))
            )
            guard evidence.schemaVersion == 5,
                  evidence.rendererBacked,
                  evidence.appServicesBacked,
                  evidence.sceneName == name,
                  evidence.recipeID == scene.recipeID,
                  evidence.seed == scene.seed,
                  evidence.material == scene.expectedMaterial?.rawValue,
                  evidence.replayMode == scene.replayMode?.rawValue,
                  evidence.attributedSampleCount == scene.attributedSamples.count,
                  evidence.actualSampleCount
                    == scene.attributedSamples.filter({ $0.kind != .predicted }).count,
                  evidence.predictedSampleCount
                    == scene.attributedSamples.filter({ $0.kind == .predicted }).count
            else {
                throw invalid("\(name): measured evidence provenance is invalid")
            }
            let expectedCoverage = Set(SliceFourHarnessRunner.coverage(
                for: scene,
                recipe: try SliceFourHarnessRunner.recipe(identity: scene.recipeID!),
                audits: evidence.auditValues
            ))
            guard Set(evidence.coverage) == expectedCoverage,
                  evidence.coverage.count == expectedCoverage.count
            else {
                throw invalid("\(name): coverage was not recomputed from measured evidence")
            }
            try SliceFourHarnessRunner.evaluateStructuralChecks(
                scene: scene,
                values: evidence.structuralValues
            )
            try validateNegativeFailure(
                directory: negativeRoot.appendingPathComponent(name),
                positive: scene,
                negative: negativeScene,
                measuredValues: evidence.structuralValues
            )
            if scene.attributedSamples.last?.phase == .ended {
                guard evidence.canonicalChangedByteCount > 0,
                      evidence.structuralValues[
                        HarnessStructuralMetric.previewCommitViolationCount.rawValue
                      ] == 0
                else {
                    throw invalid("\(name): live/commit or canonical pixel evidence failed")
                }
            } else {
                guard evidence.canonicalChangedByteCount == 0 else {
                    throw invalid("\(name): cancellation changed canonical pixels")
                }
            }
            guard (evidence.auditValues["drawEraseChangedByteCount"] ?? 0) > 0 else {
                throw invalid("\(name): draw/erase audit did not change canonical pixels")
            }
            if name.contains("legacy") {
                guard evidence.auditValues["legacyParityMaximumDelta"] == 0,
                      evidence.auditValues["anchorTilingMatrixPassCount"] == 28,
                      evidence.auditValues["anchorTilingNoncentralCount"] == 28,
                      evidence.auditValues["anchorTilingLiveCommitPassCount"] == 28,
                      evidence.auditValues["anchorTilingContinuityPassCount"] == 28,
                      evidence.auditValues["anchorTilingEraserAlphaPassCount"] == 28,
                      evidence.auditValues["anchorTilingEraserColorPassCount"] == 28,
                      evidence.auditValues["anchorCatalogEqualityCount"] == 4
                else {
                    throw invalid("\(name): legacy parity or 4x7 anchor/tiling matrix failed")
                }
            }
            if name.contains("pressure") {
                guard evidence.auditValues["sameSeedMaximumDelta"] == 0,
                      (evidence.auditValues["differentSeedChangedByteCount"] ?? 0) > 0,
                      (evidence.auditValues["pressureResponseChangedByteCount"] ?? 0) > 0,
                      (evidence.auditValues["shapeHardnessChangedByteCount"] ?? 0) > 0
                else {
                    throw invalid("\(name): deterministic seed/pressure/shape audit failed")
                }
            }
            if name.contains("stale-epoch") {
                guard evidence.auditValues["gpuFailurePreservedCanonicalCount"] == 1,
                      evidence.auditValues["allocationFailurePreservedCanonicalCount"] == 1,
                      evidence.auditValues["gpuFailureExactErrorCount"] == 1,
                      evidence.auditValues["gpuFailureCompletionCount"] == 1,
                      evidence.auditValues["gpuFailureTransientEmptyCount"] == 1,
                      evidence.auditValues["allocationFailureExactErrorCount"] == 1,
                      evidence.auditValues["allocationFailureCompletionCount"] == 0,
                      evidence.auditValues["failureHistoryNoopCount"] == 1
                else {
                    throw invalid("\(name): injected renderer failure mutated canonical state")
                }
            }
            let expectedArtifactNames: Set<String> = [
                "\(name).live.png", "\(name).committed.png",
                "\(name).canonical.png",
            ]
            guard evidence.artifacts.count == 3,
                  Set(evidence.artifacts.map(\.fileName)) == expectedArtifactNames,
                  evidence.artifacts.allSatisfy({ $0.byteCount > 0 })
            else {
                throw invalid("\(name): evidence must name exactly three nonempty PNGs")
            }
            for digest in evidence.artifacts {
                let url = directory.appendingPathComponent(digest.fileName)
                guard try SliceFourHarnessRunner.digest(url: url) == digest else {
                    throw invalid("\(name): artifact digest mismatch for \(digest.fileName)")
                }
                let isCanonical = digest.fileName.hasSuffix(".canonical.png")
                try validatePNG(
                    url,
                    width: isCanonical ? scene.tileWidth! : scene.width,
                    height: isCanonical ? scene.tileHeight! : scene.height,
                    requireNonzeroContent: !isCanonical
                        || scene.attributedSamples.last?.phase == .ended,
                    scene: name
                )
            }
            aggregateCoverage.formUnion(evidence.coverage)
            tilings.insert(scene.tiling!.rawValue)
            materials.insert(evidence.material)

            let record = try loadBenchmark(
                directory.appendingPathComponent("\(name).benchmark.json"),
                scene: name
            )
            guard record.schemaVersion == 5,
                  record.sceneName == name,
                  record.build.configuration == "Debug",
                  record.build.gitCommit == expectedCommit,
                  record.recipeID == scene.recipeID,
                  record.seed == scene.seed,
                  record.material == scene.expectedMaterial?.rawValue,
                  record.replayMode == scene.replayMode?.rawValue,
                  record.frameCount > 0,
                  record.totalInstanceBytes
                    == (record.totalProjectedFragmentCount ?? 0)
                        * ShaderABI.projectedStampInstanceStride,
                  record.cpuEncodeMilliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  record.gpuMilliseconds.allSatisfy({ $0.isFinite && $0 >= 0 })
            else {
                throw invalid("\(name): schema-5 benchmark is invalid")
            }
            guard record.historyCommandCount
                    == evidence.structuralValues[HarnessStructuralMetric.historyCommandCount.rawValue],
                  record.totalProjectedFragmentCount
                    == evidence.structuralValues[HarnessStructuralMetric.encodedInstanceCount.rawValue],
                  record.peakRetainedSampleCount
                    == evidence.structuralValues[HarnessStructuralMetric.peakRetainedSampleCount.rawValue],
                  record.peakRetainedDabCount
                    == evidence.structuralValues[HarnessStructuralMetric.peakRetainedDabCount.rawValue],
                  record.replayCount
                    == evidence.structuralValues[HarnessStructuralMetric.replayCount.rawValue],
                  record.assetResidentBytes
                    == evidence.structuralValues[HarnessStructuralMetric.assetResidentBytes.rawValue],
                  record.processedWashPixelCount
                    == evidence.structuralValues[HarnessStructuralMetric.processedWashPixelCount.rawValue],
                  record.washWorkingBytes
                    == evidence.structuralValues[HarnessStructuralMetric.washWorkingBytes.rawValue],
                  record.materialGPUMilliseconds == record.dabGPUMilliseconds,
                  record.newInstanceCounts?.count
                    == record.dabGPUMilliseconds?.count,
                  !(record.brushProcessingMilliseconds ?? []).isEmpty,
                  !(record.eventToSubmitMilliseconds ?? []).isEmpty,
                  !(record.dabGPUMilliseconds ?? []).isEmpty,
                  !(record.gridGPUMilliseconds ?? []).isEmpty,
                  scene.attributedSamples.last?.phase == .cancelled
                    || !(record.commitGPUMilliseconds ?? []).isEmpty
            else {
                throw invalid("\(name): benchmark and evidence metrics disagree")
            }
            if let provenance,
               provenance.0 != record.hardware || provenance.1 != record.operatingSystem {
                throw invalid("\(name): benchmark provenance is mixed")
            }
            provenance = provenance ?? (record.hardware, record.operatingSystem)
            if name == "slice4-long-stroke-bounds" {
                measuredFiveHundredDabGPU += try fiveHundredDabGPUTimings(
                    record: record
                )
            }
        }

        let requiredCoverage: Set<String> = [
            "renderer.grid", "pressure-flow-size", "seeded-randomness",
            "same-seed", "different-seed", "shape-asset", "grain-asset",
            "grain-coordinate.canonical", "grain-coordinate.brush-local",
            "material.ink", "material.dry", "material.glaze",
            "material.boundedWash", "taper", "prediction",
            "prediction-replacement", "stale-epoch", "noncentral-cell",
            "cancel", "history-noop", "history-commit", "long-stroke",
            "retention-bounds", "bounded-wash", "wash-bounds",
            "live-and-commit", "draw-and-erase",
            "failure-preserves-canonical", "legacy-parity",
            "anchor-tiling-matrix", "anchor-tiling-noncentral-matrix",
            "anchor-tiling-draw-erase-matrix",
        ]
        guard aggregateCoverage.isSuperset(of: requiredCoverage) else {
            throw invalid(
                "Slice 4 matrix lacks coverage: \(requiredCoverage.subtracting(aggregateCoverage).sorted())"
            )
        }
        guard tilings == Set(sliceFourLegacyTilings.map(\.rawValue)) else {
            throw invalid("Slice 4 matrix does not cover all seven tilings")
        }
        guard materials == Set(["ink", "dry", "glaze", "boundedWash"]) else {
            throw invalid("Slice 4 matrix does not cover all four material anchors")
        }
        guard measuredFiveHundredDabGPU.count == 1 else {
            throw invalid(
                "Slice 4 matrix has no uniquely identified exact-500-new-dab frame"
            )
        }
        guard let provenance else { throw invalid("benchmark provenance is unavailable") }
        if provenance.0.gpuName.lowercased().contains("paravirtual") {
            return .performancePending(gpuName: provenance.0.gpuName)
        }
        try validateStableGPUBudgets(positiveRoot: positiveRoot)
        return .passed
    }

    private static func validatePNG(
        _ url: URL,
        width: Int,
        height: Int,
        requireNonzeroContent: Bool,
        scene: String
    ) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width,
              image.height == height,
              let data = image.dataProvider?.data as Data?,
              !data.isEmpty,
              !requireNonzeroContent || data.contains(where: { $0 != 0 })
        else {
            throw invalid("\(scene): PNG is undecodable, empty, or has wrong dimensions: \(url.lastPathComponent)")
        }
    }

    private static func validateStableGPUBudgets(positiveRoot: URL) throws {
        var brush: [Double] = []
        var events: [Double] = []
        var fiveHundredDabGPU: [Double] = []
        var missed = 0
        for name in sceneNames {
            let record = try loadBenchmark(
                positiveRoot.appendingPathComponent(name)
                    .appendingPathComponent("\(name).benchmark.json"),
                scene: name
            )
            brush += record.brushProcessingMilliseconds ?? []
            events += record.eventToSubmitMilliseconds ?? []
            missed += record.missedFrameCount ?? 0
            fiveHundredDabGPU += try fiveHundredDabGPUTimings(record: record)
        }
        guard percentile95(brush) < 2 else {
            throw invalid("stable-GPU brush-processing p95 exceeds 2 ms")
        }
        guard !fiveHundredDabGPU.isEmpty, percentile95(fiveHundredDabGPU) < 3 else {
            throw invalid("stable-GPU 500-dab material p95 is missing or exceeds 3 ms")
        }
        guard !events.isEmpty,
              Double(missed) / Double(events.count) < 0.01
        else {
            throw invalid("stable-GPU sustained 60 Hz missed-frame rate exceeds 1%")
        }
        if events.count >= 20 {
            let midpoint = events.count / 2
            let early = percentile95(Array(events[..<midpoint]))
            let late = percentile95(Array(events[midpoint...]))
            guard late <= max(early * 1.15, early + 0.05) else {
                throw invalid("stable-GPU sustained event p95 regressed by more than 15%")
            }
        }
    }

    static func fiveHundredDabGPUTimings(
        record: BenchmarkRecord
    ) throws -> [Double] {
        let stressScene = "slice4-long-stroke-bounds"
        guard record.sceneName == stressScene else {
            guard record.fiveHundredDabStressFrameIndex == nil,
                  record.fiveHundredDabStressNewDabCount == nil
            else {
                throw invalid(
                    "\(record.sceneName): 500-dab stress identity belongs only to \(stressScene)"
                )
            }
            return []
        }
        guard let timings = record.dabGPUMilliseconds,
              let counts = record.newInstanceCounts,
              let frameIndex = record.fiveHundredDabStressFrameIndex,
              let newDabCount = record.fiveHundredDabStressNewDabCount,
              !timings.isEmpty,
              timings.count == counts.count,
              counts.allSatisfy({ $0 >= 0 }),
              frameIndex == timings.index(before: timings.endIndex),
              newDabCount == 500,
              counts[frameIndex] == 500
        else {
            throw invalid(
                "\(record.sceneName): exact 500-new-dab stress-frame identity is invalid"
            )
        }
        return [timings[frameIndex]]
    }

    private static func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }

    private static func validateNegativeFailure(
        directory: URL,
        positive: HarnessScene,
        negative: HarnessScene,
        measuredValues: [String: Int]
    ) throws {
        let name = negative.name
        let expectedFiles: Set<String> = ["stdout.log", "stderr.log", "exit-status.txt"]
        guard try directoryNames(at: directory) == expectedFiles else {
            throw invalid("\(name): negative-control logs are incomplete")
        }
        let status = try String(
            contentsOf: directory.appendingPathComponent("exit-status.txt"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = try String(
            contentsOf: directory.appendingPathComponent("stderr.log"),
            encoding: .utf8
        )
        let stdout = try Data(
            contentsOf: directory.appendingPathComponent("stdout.log")
        )
        guard let check = negative.negativeControls.first,
              let actual = measuredValues[check.metric.rawValue]
        else {
            throw invalid("\(name): cannot derive the exact negative assertion")
        }
        for control in negative.negativeControls {
            guard let measured = measuredValues[control.metric.rawValue] else {
                throw invalid("\(name): negative control metric is unmeasured")
            }
            let unexpectedlyPasses = switch control.relation {
            case .equal: measured == control.value
            case .lessThanOrEqual: measured <= control.value
            case .greaterThanOrEqual: measured >= control.value
            }
            guard !unexpectedlyPasses else {
                throw invalid(
                    "\(name): negative control for \(control.metric.rawValue) did not fail"
                )
            }
        }
        let expectedError = SliceFourHarnessRunError.structuralMismatch(
            sceneName: negative.name,
            metric: check.metric,
            relation: check.relation,
            expected: check.value,
            actual: actual
        ).localizedDescription
        guard status == "1", stdout.isEmpty,
              stderr == "HARNESS FAIL \(expectedError)\n"
        else {
            throw invalid("\(name): negative control did not fail closed")
        }
    }

    private static func validateNegativeControl(
        positive: HarnessScene,
        negative: HarnessScene
    ) throws {
        guard negative.name == "\(positive.name)-negative-control",
              negative.schemaVersion == positive.schemaVersion,
              negative.recipeID == positive.recipeID,
              negative.seed == positive.seed,
              negative.attributedSamples == positive.attributedSamples,
              negative.expectedMaterial == positive.expectedMaterial,
              negative.replayMode == positive.replayMode,
              negative.checks == positive.checks,
              negative.structuralChecks.count == positive.structuralChecks.count
        else {
            throw invalid("\(positive.name): negative control changed its execution inputs")
        }
        let differences = zip(positive.structuralChecks, negative.structuralChecks)
            .filter { $0 != $1 }
        guard differences.count == 1,
              differences[0].0.metric == differences[0].1.metric,
              differences[0].0.relation == differences[0].1.relation,
              negative.negativeControls.first == differences[0].1,
              let required = requiredNegativeControlMetrics[positive.name],
              Set(required.map(\.rawValue))
                == Set(negative.negativeControls.map { $0.metric.rawValue }),
              negative.negativeControls.count == required.count,
              negative.negativeControls.allSatisfy({ control in
                  positive.structuralChecks.contains(where: { check in
                      check.metric == control.metric && check != control
                  })
              })
        else {
            throw invalid(
                "\(positive.name): negative controls do not independently cover every required family"
            )
        }
    }

    static func validateNegativeControlForTests(
        positive: HarnessScene,
        negative: HarnessScene
    ) throws {
        try validateNegativeControl(positive: positive, negative: negative)
    }

    private static func loadScene(_ url: URL) throws -> HarnessScene {
        do { return try HarnessScene.decode(Data(contentsOf: url)) }
        catch { throw invalid("\(url.lastPathComponent): cannot decode: \(error)") }
    }

    private static func loadBenchmark(
        _ url: URL,
        scene: String
    ) throws -> BenchmarkRecord {
        do { return try BenchmarkRecord.decode(Data(contentsOf: url)) }
        catch { throw invalid("\(scene): cannot decode benchmark: \(error)") }
    }

    private static func directoryNames(at url: URL) throws -> Set<String> {
        do {
            return Set(try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).map(\.lastPathComponent))
        } catch { throw invalid("cannot enumerate \(url.path): \(error)") }
    }

    private static func invalid(_ message: String)
        -> SliceFourEvidenceValidationError
    { .invalid(message) }
}
