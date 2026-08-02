import BrushFormat
import CShaderTypes
import CoreGraphics
import Foundation
import ImageIO
import Metal
import PatternEngine
import UniformTypeIdentifiers

public enum DepositionHarnessRunError:
    Error, Equatable, LocalizedError
{
    case unsupportedSchema(Int)
    case unknownScene(String)
    case metalResourceUnavailable(String)
    case missingCompletion(String)
    case unexpectedCompletion(String)
    case emptyCanonical(String)
    case invariantFailed(scene: String, invariant: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Native deposition harness requires schema 6, found \(version)."
        case let .unknownScene(scene):
            "Unknown native deposition scene '\(scene)'."
        case let .metalResourceUnavailable(resource):
            "Native deposition harness could not create \(resource)."
        case let .missingCompletion(scene):
            "Native deposition scene '\(scene)' published no completion."
        case let .unexpectedCompletion(scene):
            "Native deposition scene '\(scene)' published an unexpected completion."
        case let .emptyCanonical(scene):
            "Native deposition scene '\(scene)' produced an empty canonical raster."
        case let .invariantFailed(scene, invariant):
            "Native deposition scene '\(scene)' failed invariant '\(invariant)'."
        }
    }
}

@MainActor
public final class DepositionHarnessRunner {
    nonisolated fileprivate static let seed: UInt64 = 0x4c_41_59_41

    private let device: any MTLDevice
    private let library: any MTLLibrary
    private let productionAnchorDefinitions: [String: BrushDefinition]

    public init(
        device: any MTLDevice,
        library: any MTLLibrary,
        productionAnchorDefinitions: [String: BrushDefinition]
    ) {
        self.device = device
        self.library = library
        self.productionAnchorDefinitions = productionAnchorDefinitions
    }

    public convenience init(
        device: any MTLDevice,
        productionAnchorDefinitions: [String: BrushDefinition]
    ) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw DepositionHarnessRunError.metalResourceUnavailable(
                "the app Metal library"
            )
        }
        self.init(
            device: device,
            library: library,
            productionAnchorDefinitions: productionAnchorDefinitions
        )
    }

    public func run(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) async throws -> HarnessRunResult {
        guard scene.schemaVersion == 6 else {
            throw DepositionHarnessRunError.unsupportedSchema(
                scene.schemaVersion
            )
        }
        let stem = Self.positiveStem(scene.name)
        let isProfessional =
            ProfessionalBrushEvidenceValidator.positiveSceneNames
                .contains(stem)
        guard DepositionEvidenceValidator.positiveSceneNames.contains(stem)
                || isProfessional
        else {
            throw DepositionHarnessRunError.unknownScene(scene.name)
        }

        let package = try package(for: stem)
        let tiling: TilingKind =
            stem == "deposition-periodic-seams"
                ? .squareKaleidoscope
                : .grid
        let context = try await makeContext(
            scene: scene,
            package: package,
            tiling: tiling
        )
        if isProfessional {
            _ = try await context.compiler.compileAndActivate(
                package: package
            )
        }
        if stem == "deposition-erase" {
            try await seedEraseCanvas(context, scene: scene)
        }
        let countersBeforeStroke = context.compiler.debugCounters
        let capture = try performStroke(
            context: context,
            scene: scene,
            stem: stem
        )
        let countersAfterStroke = context.compiler.debugCounters
        let canonicalBytes = Self.textureBytes(capture.canonical)
        guard Self.hasNontransparentPixel(canonicalBytes) else {
            throw DepositionHarnessRunError.emptyCanonical(scene.name)
        }
        if stem == "deposition-erase",
           canonicalBytes == capture.canonicalBefore
        {
            throw DepositionHarnessRunError.invariantFailed(
                scene: scene.name,
                invariant: "eraserMutatesSeededCanonical"
            )
        }

        var invariants: [String: Bool]
        let professionalAudit: ProfessionalRunAudit?
        if isProfessional {
            let audit = try await professionalInvariantResults(
                stem: stem,
                scene: scene,
                primary: capture,
                context: context,
                package: package,
                countersBeforeStroke: countersBeforeStroke,
                countersAfterStroke: countersAfterStroke
            )
            professionalAudit = audit
            invariants = audit.invariantResults
        } else {
            professionalAudit = nil
            invariants = try await invariantResults(
                stem: stem,
                scene: scene,
                primary: capture,
                context: context,
                package: package
            )
            invariants["strokeCompilerCountersUnchanged"] =
                countersBeforeStroke == countersAfterStroke
                && capture.pipelinePreparationUnchanged
            invariants["strokePipelinePreparationUnchanged"] =
                capture.pipelinePreparationUnchanged
        }
        for key in scene.depositionInvariantExpectations.keys
        where invariants[key] == nil {
            invariants[key] = false
        }

        if isProfessional {
            let performance = scene.name.hasSuffix("-negative-control")
                ? nil
                : try await professionalPerformanceArtifacts(
                    scene: scene,
                    build: build,
                    package: package,
                    primary: capture
                )
            return try finishProfessionalRun(
                scene: scene,
                outputDirectory: outputDirectory,
                build: build,
                context: context,
                capture: capture,
                audit: professionalAudit!,
                invariants: invariants,
                countersBeforeStroke: countersBeforeStroke,
                countersAfterStroke: countersAfterStroke,
                performance: performance
            )
        }

        let cpuReference: [UInt8]?
        if stem == "deposition-ink" {
            cpuReference = Self.hardRoundCPUReference(
                records: capture.scheduledRecords,
                material: context.compiled.depositionMaterial,
                width: capture.canonical.width,
                height: capture.canonical.height
            )
        } else {
            cpuReference = nil
        }
        let cpuDelta = cpuReference.map {
            Self.maximumChannelDelta($0, canonicalBytes)
        }
        let textureLevels = Dictionary(
            uniqueKeysWithValues: context.compiled.textures.keys.sorted().map {
                ($0, context.compiled.textures[$0]!.mipmapLevelCount)
            }
        )
        let evidence = DepositionSceneEvidence(
            schemaVersion: DepositionSceneEvidence.currentSchemaVersion,
            scene: stem,
            definitionID:
                context.compiled.program.definition.id.rawValue,
            semanticHash: context.compiled.renderIdentity.semanticHash,
            pipelineKey: Self.pipelineDescription(
                context.compiled.depositionPipeline.key
            ),
            abiVersion:
                context.compiled.depositionPipeline.key.abiVersion,
            resourceBytes: context.compiled.residentByteCount,
            textureLevels: textureLevels,
            logicalDabCount: capture.logicalDabCount,
            projectedInstanceCount: capture.projectedInstanceCount,
            canonicalSHA256: DepositionSceneEvidence.sha256(
                canonicalBytes
            ),
            cpuReferenceSHA256: cpuReference.map(
                DepositionSceneEvidence.sha256
            ),
            maximumCPUGPUChannelDelta: cpuDelta,
            previewCommitMaximumChannelDelta:
                capture.previewCommitMaximumChannelDelta,
            telemetry: capture.telemetry,
            invariantResults: invariants
        )
        try DepositionEvidenceValidator.validate(evidence)

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let liveURL = outputDirectory.appendingPathComponent(
            "\(scene.name).live.png"
        )
        let committedURL = outputDirectory.appendingPathComponent(
            "\(scene.name).committed.png"
        )
        let canonicalURL = outputDirectory.appendingPathComponent(
            "\(scene.name).canonical.png"
        )
        try Self.writePNGAtomically(capture.live, to: liveURL)
        try Self.writePNGAtomically(capture.committed, to: committedURL)
        try Self.writePNGAtomically(capture.canonical, to: canonicalURL)

        var artifactURLs = [liveURL, committedURL, canonicalURL]
        if let cpuReference {
            let cpuURL = outputDirectory.appendingPathComponent(
                "\(scene.name).cpu-reference.png"
            )
            try Self.writePNGAtomically(
                bgra: cpuReference,
                pixelSize: PixelSize(
                    width: capture.canonical.width,
                    height: capture.canonical.height
                ),
                to: cpuURL
            )
            artifactURLs.append(cpuURL)
        }
        let evidenceURL = outputDirectory.appendingPathComponent(
            "\(scene.name).deposition-evidence.json"
        )
        try evidence.encoded().write(to: evidenceURL, options: .atomic)
        artifactURLs.append(evidenceURL)

        let benchmark = Self.benchmark(
            scene: scene,
            build: build,
            device: device,
            capture: capture,
            evidence: evidence
        )
        let benchmarkURL = outputDirectory.appendingPathComponent(
            "\(scene.name).benchmark.json"
        )
        try BenchmarkRecord.encode(benchmark).write(
            to: benchmarkURL,
            options: .atomic
        )
        artifactURLs.append(benchmarkURL)

        // Evaluate after writing renderer-backed diagnostics. A paired
        // negative therefore proves its authoritative expectation is wrong
        // while still leaving inspectable failure evidence.
        try DepositionEvidenceValidator.validateExpectations(
            scene: scene,
            actual: invariants
        )
        return HarnessRunResult(
            imageURL: liveURL,
            benchmarkURL: benchmarkURL,
            benchmark: benchmark,
            artifactURLs: artifactURLs
        )
    }
}

private extension DepositionHarnessRunner {
    struct Context {
        let renderer: GridRenderer
        let compiler: BrushCompiler
        let compiled: CompiledBrush
        let countersBeforeCompile: BrushCompilerCounters
        let countersAfterCompile: BrushCompilerCounters
        let pipelineLibrary: DepositionPipelineLibrary
        let pipelineFailurePreparer:
            ArmableDepositionPipelinePreparer?
    }

    struct StrokeCapture {
        let live: any MTLTexture
        let committed: any MTLTexture
        let canonical: any MTLTexture
        let canonicalBefore: [UInt8]
        let scheduledRecords: [ProjectedDepositionRecord]
        let logicalDabCount: Int
        let projectedInstanceCount: Int
        let previewCommitMaximumChannelDelta: UInt8
        let flushMetrics: GPUFrameMetrics
        let commitMetrics: GPUFrameMetrics
        let strokeMetrics: [GPUFrameMetrics]
        let identityFrames: [ProfessionalLongStrokeIdentityFrame]
        let displayMetrics: [GPUFrameMetrics]
        let pipelinePreparationUnchanged: Bool
        let telemetry: DepositionTelemetryEvidence
    }

    struct ProfessionalRasterPair {
        let first: [UInt8]
        let second: [UInt8]
    }

    struct ProfessionalRadialObservations {
        let rotation: ProfessionalRasterPair
        let reflection: ProfessionalRasterPair
    }

    struct ProfessionalRunAudit {
        let invariantResults: [String: Bool]
        let prediction: ProfessionalRasterPair
        let grid: ProfessionalRasterPair
        let eraser: ProfessionalRasterPair
        let radial: ProfessionalRadialObservations
        let pipelinePrepareCallCountBeforeStroke: Int
        let pipelinePrepareCallCountAfterStroke: Int
    }

    struct ProfessionalPerformanceArtifacts {
        let index: Data
        let fiveHundredDabs: Data
        let longStroke: Data
        let longStrokeTrace: Data
    }

    struct SeededFailureContext {
        let context: Context
        let baseline: RendererFailureSnapshot
    }

    enum PartitionMode {
        case oneFrame
        case everySample
    }

    static func positiveStem(_ name: String) -> String {
        let suffix = "-negative-control"
        return name.hasSuffix(suffix)
            ? String(name.dropLast(suffix.count))
            : name
    }

    func package(for stem: String) throws -> BrushPackage {
        if let definition = productionAnchorDefinitions[stem] {
            return try BrushPackage(
                manifest: BrushPackageManifest(resources: []),
                definition: definition,
                resourceData: [:]
            )
        }
        if Self.productionAnchorSceneNames.contains(stem)
            || ProfessionalBrushEvidenceValidator.positiveSceneNames
                .contains(stem)
        {
            throw DepositionHarnessRunError.invariantFailed(
                scene: stem,
                invariant: "productionBrushDefinitionInjected"
            )
        }
        return try DepositionHarnessFixtures.package(for: stem)
    }

    static let productionAnchorSceneNames: Set<String> = [
        "deposition-airbrush",
        "deposition-dry",
        "deposition-erase",
        "deposition-glaze",
        "deposition-ink",
        "deposition-marker",
    ]

    func makeContext(
        scene: HarnessScene,
        package: BrushPackage,
        tiling: TilingKind = .grid,
        drawableSize: PixelSize? = nil,
        cacheBudgetBytes: Int = 64 * 1_024 * 1_024,
        armablePipelineFailure: Bool = false
    ) async throws -> Context {
        guard let commandQueue = device.makeCommandQueue() else {
            throw DepositionHarnessRunError.metalResourceUnavailable(
                "a Metal command queue"
            )
        }
        let pipelineLibrary = DepositionPipelineLibrary(
            device: device,
            library: library
        )
        let profile = try BrushDeviceProfile(
            registryID: device.registryID,
            recommendedWorkingSetBytes:
                max(device.recommendedMaxWorkingSetSize, 64 * 1_024 * 1_024),
            maximumWorkingTextureDimension: 4_096,
            brushCacheBudgetBytes: cacheBudgetBytes,
            targetFramesPerSecond: 120
        )
        let failurePreparer = armablePipelineFailure
            ? ArmableDepositionPipelinePreparer(delegate: pipelineLibrary)
            : nil
        let compiler = BrushCompiler(
            device: device,
            commandQueue: commandQueue,
            profile: profile,
            pipelinePreparing: failurePreparer ?? pipelineLibrary,
            testHooks: .none
        )
        let size = drawableSize ?? PixelSize(
            width: scene.width,
            height: scene.height
        )
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(
                width: Float(size.width),
                height: Float(size.height)
            ),
            configuration: TilingCanvasConfiguration(
                pixelSize: size,
                tiling: tiling
            )
        )
        let countersBeforeCompile = compiler.debugCounters
        let compiled = try await compiler.compileAndActivate(
            package: package
        )
        let countersAfterCompile = compiler.debugCounters
        if package.definition.material.accumulation == .destinationOut {
            try renderer.activateEraserBrush(compiled)
        } else {
            try renderer.activateDrawBrush(compiled)
        }
        return Context(
            renderer: renderer,
            compiler: compiler,
            compiled: compiled,
            countersBeforeCompile: countersBeforeCompile,
            countersAfterCompile: countersAfterCompile,
            pipelineLibrary: pipelineLibrary,
            pipelineFailurePreparer: failurePreparer
        )
    }

    func seedEraseCanvas(_ context: Context, scene: HarnessScene)
        async throws
    {
        let inkPackage = try package(for: "deposition-ink")
        let ink = try await context.compiler.compileAndActivate(
            package: inkPackage
        )
        try context.renderer.activateDrawBrush(ink)
        _ = try commitOnly(
            context: context,
            brush: ink,
            compositeMode: .draw,
            color: .black,
            trace: Self.trace(width: scene.width, height: scene.height)
        )
        let eraser = try await context.compiler.compileAndActivate(
            package: self.package(for: "deposition-erase")
        )
        try context.renderer.activateEraserBrush(eraser)
    }

    func performStroke(
        context: Context,
        scene: HarnessScene,
        stem: String,
        trace: [StrokeSample]? = nil,
        partitionMode: PartitionMode = .oneFrame,
        color: InkColor = InkColor(
            red: 0.18,
            green: 0.42,
            blue: 0.86,
            alpha: 0.84
        )!,
        zoom: Float = 1,
        cancel: Bool = false,
        diameter: Float? = nil,
        collectPerformanceEvidence: Bool = false
    ) throws -> StrokeCapture {
        let renderer = context.renderer
        let pipelinePrepareCallsBefore =
            context.pipelineLibrary.debugPrepareCallCount
        let compositeMode: StrokeCompositeMode =
            context.compiled.program.definition.material.accumulation
                == .destinationOut ? .erase : .draw
        if zoom != 1 {
            renderer.restoreSavedViewport(
                worldCenter: WorldPoint(
                    x: Float(scene.width) * 0.5,
                    y: Float(scene.height) * 0.5
                ),
                zoom: zoom
            )
        }
        let samples = trace
            ?? Self.trace(width: scene.width, height: scene.height)
        let token = RendererOperationToken(rawValue: Self.seed)
        var completions: [RendererOperationCompletion] = []
        var generatedLogicalDabs: [LogicalDab] = []
        renderer.onOperationCompleted = { completions.append($0) }
        renderer.onLogicalDabsGenerated = {
            generatedLogicalDabs.append($0)
        }
        let before = Self.textureBytes(
            try renderer.copyCanonicalForHarness()
        )
        let style = StrokeRenderStyle(
            color: color,
            diameter: diameter
                ?? (
                    stem == "deposition-stamp-size-mips"
                        ? 48
                        : (
                            stem.hasPrefix("professional-")
                                ? (
                                    stem
                                        == "professional-natural-charcoal"
                                        ? 80
                                        : 40
                                )
                                : 22
                        )
                ),
            compositeMode: compositeMode,
            eraserStrength: 0.72,
            program: context.compiled.program,
            renderIdentity: context.compiled.renderIdentity,
            seed: Self.seed
        )
        try renderer.beginStroke(
            token: token,
            sample: samples[0],
            style: style
        )
        var intermediateMetrics: [GPUFrameMetrics] = []
        var performanceMetrics: [GPUFrameMetrics] = []
        var identityFrames: [ProfessionalLongStrokeIdentityFrame] = []
        var encodedHighWater: UInt64 = 0
        var generatedProjectedInstanceHighWater = 0
        func recordPerformanceFlush(
            _ result: HarnessLiveFlushResult,
            inputPhase: String
        ) throws {
            performanceMetrics.append(result.metrics)
            let previousEncodedHighWater = encodedHighWater
            let audit = try HarnessRunner.auditLiveFlushIdentity(
                sceneName: scene.name,
                previousEncodedHighWater: previousEncodedHighWater,
                flushResult: result
            )
            let currentGeneratedProjectedInstanceHighWater =
                renderer.harnessCounters.totalInstancesThisStroke
            guard currentGeneratedProjectedInstanceHighWater
                    >= generatedProjectedInstanceHighWater
            else {
                throw DepositionHarnessRunError.invariantFailed(
                    scene: scene.name,
                    invariant:
                        "generatedProjectedInstanceHighWaterMonotonic"
                )
            }
            identityFrames.append(
                ProfessionalLongStrokeIdentityFrame(
                    inputPhase: inputPhase,
                    previousEncodedLogicalDabHighWater:
                        previousEncodedHighWater,
                    emittedLogicalDabHighWater:
                        result.emittedHighWater,
                    authoritativeLogicalDabBacklogRemaining:
                        result.authoritativeBacklogRemaining,
                    previousGeneratedProjectedInstanceHighWater:
                        generatedProjectedInstanceHighWater,
                    generatedProjectedInstanceHighWater:
                        currentGeneratedProjectedInstanceHighWater,
                    encodedGPUInstanceCount:
                        result.metrics.encodedInstanceCount,
                    retainedDabCount:
                        result.replayRetention.retainedDabCount,
                    visibleProjectedInstanceCount:
                        result.replayRetention
                            .visibleProjectedInstanceCount,
                    encodedLogicalDabIdentityRanges:
                        result.encodedIdentityRanges
                )
            )
            encodedHighWater = audit.encodedHighWater
            generatedProjectedInstanceHighWater =
                currentGeneratedProjectedInstanceHighWater
        }
        if collectPerformanceEvidence,
           partitionMode == .everySample
        {
            let beganResult = try renderer.flushPendingLiveForHarness()
            intermediateMetrics.append(beganResult.metrics)
            try recordPerformanceFlush(
                beganResult,
                inputPhase: Self.phaseName(samples[0].phase)
            )
        }
        for sample in samples.dropFirst().dropLast() {
            try renderer.appendStroke(token: token, sample: sample)
            if partitionMode == .everySample, sample.kind != .predicted {
                let result = try renderer.flushPendingLiveForHarness()
                intermediateMetrics.append(result.metrics)
                if collectPerformanceEvidence {
                    try recordPerformanceFlush(
                        result,
                        inputPhase: Self.phaseName(sample.phase)
                    )
                }
            }
        }
        if !cancel {
            try renderer.drainPreparedStrokeInputForHarness()
            try renderer.requestStrokeCommit(
                token: token,
                sample: samples.last!,
                maximumRetainedBytes: 64 * 1_024 * 1_024
            )
        }
        let firstFlush = try renderer.flushPendingLiveForHarness()
        let flushMetrics = firstFlush.metrics
        if collectPerformanceEvidence {
            try recordPerformanceFlush(
                firstFlush,
                inputPhase: Self.phaseName(samples.last!.phase)
            )
        }
        if !cancel {
            try renderer.preparePendingCommitForHarness()
        }
        let scheduled = try renderer.projectLogicalDabsForHarness(
            generatedLogicalDabs
        )
        renderer.onLogicalDabsGenerated = nil
        let actorSnapshot = renderer.harnessOffMainDepositionSnapshot
        if !cancel, actorSnapshot == nil {
            throw DepositionHarnessRunError.invariantFailed(
                scene: scene.name,
                invariant: "productionActorDepositionSnapshot"
            )
        }
        let logical = actorSnapshot?.logicalDabCount
            ?? renderer.harnessCounters.totalDabsThisStroke
        let projected = actorSnapshot?.projectedInstanceCount
            ?? renderer.harnessCounters.totalInstancesThisStroke
        let liveFrame = try renderer.renderOffscreenDisplayForHarness(
            width: scene.width,
            height: scene.height,
            showGridLines: false
        )
        let commitMetrics: GPUFrameMetrics
        if cancel {
            try renderer.cancelStroke(token: token)
            try renderer.drainStrokeWorkspaceRetirementForHarness()
            commitMetrics = flushMetrics
        } else {
            commitMetrics = try renderer.finishCommitForHarness()
            guard let completion = completions.first else {
                throw DepositionHarnessRunError.missingCompletion(
                    scene.name
                )
            }
            guard case let .rasterSuccess(receipt) = completion,
                  receipt.token == token
            else {
                throw DepositionHarnessRunError.unexpectedCompletion(
                    scene.name
                )
            }
            renderer.releaseRasterRevisions([
                receipt.before.id,
                receipt.after.id,
            ])
        }
        let committedFrame = try renderer.renderOffscreenDisplayForHarness(
            width: scene.width,
            height: scene.height,
            showGridLines: false
        )
        let canonical = try renderer.copyCanonicalForHarness()
        let previewDelta = Self.maximumChannelDelta(
            Self.textureBytes(liveFrame.texture),
            Self.textureBytes(committedFrame.texture)
        )
        let timingTelemetry = renderer.brushLabDiagnosticSnapshot.deposition
        let telemetry = DepositionTelemetryEvidence(
            authoritativeBacklog:
                actorSnapshot?.authoritativeBacklog ?? 0,
            predictedBacklog: 0,
            backlogHighWater:
                actorSnapshot?.authoritativeBacklogHighWater ?? 0,
            encodedInstanceCount:
                actorSnapshot?.encodedInstanceCount ?? 0,
            bufferHighWater: actorSnapshot?.surfaceLeaseHighWater ?? 0,
            missedFrameCount: timingTelemetry.missedFrameCount
        )
        return StrokeCapture(
            live: liveFrame.texture,
            committed: committedFrame.texture,
            canonical: canonical,
            canonicalBefore: before,
            scheduledRecords: scheduled,
            logicalDabCount: logical,
            projectedInstanceCount: projected,
            previewCommitMaximumChannelDelta: previewDelta,
            flushMetrics: flushMetrics,
            commitMetrics: commitMetrics,
            strokeMetrics: collectPerformanceEvidence
                ? performanceMetrics : [],
            identityFrames: collectPerformanceEvidence
                ? identityFrames : [],
            displayMetrics: intermediateMetrics
                + [liveFrame.metrics, committedFrame.metrics],
            pipelinePreparationUnchanged:
                pipelinePrepareCallsBefore
                == context.pipelineLibrary.debugPrepareCallCount,
            telemetry: telemetry
        )
    }

    func commitOnly(
        context: Context,
        brush: CompiledBrush,
        compositeMode: StrokeCompositeMode,
        color: InkColor,
        trace: [StrokeSample],
        partitionMode: PartitionMode = .oneFrame,
        diameter: Float = 22
    ) throws -> [UInt8] {
        let renderer = context.renderer
        let pipelinePrepareCallsBefore =
            context.pipelineLibrary.debugPrepareCallCount
        let token = RendererOperationToken(rawValue: Self.seed &+ 1)
        var receipt: RasterMutationReceipt?
        renderer.onOperationCompleted = {
            if case let .rasterSuccess(value) = $0 {
                receipt = value
            }
        }
        let style = StrokeRenderStyle(
            color: color,
            diameter: diameter,
            compositeMode: compositeMode,
            eraserStrength: 0.72,
            program: brush.program,
            renderIdentity: brush.renderIdentity,
            seed: Self.seed
        )
        try renderer.beginStroke(
            token: token,
            sample: trace[0],
            style: style
        )
        for sample in trace.dropFirst().dropLast() {
            try renderer.appendStroke(token: token, sample: sample)
            if partitionMode == .everySample, sample.kind != .predicted {
                _ = try renderer.flushPendingLiveForHarness()
            }
        }
        try renderer.requestStrokeCommit(
            token: token,
            sample: trace.last!,
            maximumRetainedBytes: 64 * 1_024 * 1_024
        )
        _ = try renderer.finishCommitForHarness()
        if let receipt {
            renderer.releaseRasterRevisions([
                receipt.before.id,
                receipt.after.id,
            ])
        }
        guard pipelinePrepareCallsBefore
                == context.pipelineLibrary.debugPrepareCallCount
        else {
            throw DepositionHarnessRunError.invariantFailed(
                scene: brush.program.definition.id.rawValue,
                invariant: "strokePipelinePreparationUnchanged"
            )
        }
        return Self.textureBytes(try renderer.copyCanonicalForHarness())
    }

    func seededFailureContext(
        scene: HarnessScene,
        package: BrushPackage,
        armablePipelineFailure: Bool = false
    ) async throws -> SeededFailureContext {
        let context = try await makeContext(
            scene: scene,
            package: package,
            armablePipelineFailure: armablePipelineFailure
        )
        _ = try commitRetainingHistory(
            context: context,
            brush: context.compiled,
            trace: Self.trace(width: scene.width, height: scene.height)
        )
        let baseline = try failureSnapshot(context.renderer)
        guard baseline.isIdle,
              Self.hasNontransparentPixel(baseline.canonicalBytes),
              baseline.historyResidentBytes > 0,
              baseline.historySnapshots.count == 2,
              baseline.historySnapshots.contains(where: {
                  $0.retainedBytes.contains(where: { $0 != 0 })
              })
        else {
            throw DepositionHarnessRunError.invariantFailed(
                scene: scene.name,
                invariant: "failureStartsFromNonemptyExactHistory"
            )
        }
        return SeededFailureContext(
            context: context,
            baseline: baseline
        )
    }

    func commitRetainingHistory(
        context: Context,
        brush: CompiledBrush,
        trace: [StrokeSample]
    ) throws -> RasterMutationReceipt {
        let renderer = context.renderer
        let pipelinePrepareCallsBefore =
            context.pipelineLibrary.debugPrepareCallCount
        let token = RendererOperationToken(rawValue: Self.seed &+ 20)
        var receipt: RasterMutationReceipt?
        renderer.onOperationCompleted = {
            if case let .rasterSuccess(value) = $0 {
                receipt = value
            }
        }
        try renderer.beginStroke(
            token: token,
            sample: trace[0],
            style: Self.style(brush)
        )
        for sample in trace.dropFirst().dropLast() {
            try renderer.appendStroke(token: token, sample: sample)
        }
        try renderer.requestStrokeCommit(
            token: token,
            sample: trace.last!,
            maximumRetainedBytes: 64 * 1_024 * 1_024
        )
        _ = try renderer.finishCommitForHarness()
        guard let receipt,
              pipelinePrepareCallsBefore
                == context.pipelineLibrary.debugPrepareCallCount
        else {
            throw DepositionHarnessRunError.invariantFailed(
                scene: brush.program.definition.id.rawValue,
                invariant: "seededFailureHistoryCommit"
            )
        }
        return receipt
    }
}

private extension DepositionHarnessRunner {
    func professionalInvariantResults(
        stem: String,
        scene: HarnessScene,
        primary: StrokeCapture,
        context: Context,
        package: BrushPackage,
        countersBeforeStroke: BrushCompilerCounters,
        countersAfterStroke: BrushCompilerCounters
    ) async throws -> ProfessionalRunAudit {
        let definition = context.compiled.program.definition
        let expectedHash =
            ProfessionalBrushEvidenceValidator.expectedSemanticHash(
                forPositiveScene: stem
            )
        let expectedResources =
            ProfessionalBrushEvidenceValidator.expectedResourceLevels(
                forPositiveScene: stem
            )
        let actualResources = Dictionary(
            uniqueKeysWithValues: context.compiled.textures.map {
                ($0.key, $0.value.mipmapLevelCount)
            }
        )
        let replayLimits = definition.replayLimits
        let pipelineBefore =
            context.pipelineLibrary.debugPrepareCallCount
        let prediction = try await professionalPredictionObservation(
            scene: scene,
            package: package
        )
        let eraser = try await professionalEraserObservation(
            scene: scene,
            package: package
        )
        let radial = try await professionalRadialProjectionObservations(
            scene: scene,
            package: package
        )
        let grid = try await professionalGridTranslationObservation(
            scene: scene,
            package: package
        )
        let pipelineAfter =
            context.pipelineLibrary.debugPrepareCallCount
        let results = [
            "boundedLiveWork":
                definition.replayMode == .replayTail
                && replayLimits == BrushRecipePolicy.replayTailLimits
                && primary.logicalDabCount
                    <= BrushRecipePolicy.replayTailLimits.maximumDabs
                && primary.projectedInstanceCount
                    <= BrushRecipePolicy.replayTailLimits
                        .maximumProjectedInstances
                && primary.telemetry.backlogHighWater
                    <= BrushRecipePolicy.replayTailLimits
                        .maximumProjectedInstances,
            "destinationOutEraserCompatible":
                Self.hasNontransparentPixel(eraser.first)
                && eraser.first != eraser.second
                && Self.reducedAlphaPixelCount(
                    before: eraser.first,
                    after: eraser.second
                ) > 0,
            "nonemptyVisibleOutput":
                Self.hasNontransparentPixel(
                    Self.textureBytes(primary.live)
                )
                && Self.hasNontransparentPixel(
                    Self.textureBytes(primary.committed)
                )
                && Self.hasNontransparentPixel(
                    Self.textureBytes(primary.canonical)
                ),
            "predictionOnOffEqual":
                prediction.first == prediction.second,
            "previewCommitMaximumDeltaWithinTolerance":
                primary.previewCommitMaximumChannelDelta <= 1,
            "professionalDefinitionIdentityExact":
                productionAnchorDefinitions[stem] == definition
                && package.definition == definition
                && context.compiled.renderIdentity.definitionID
                    == definition.id
                && context.compiled.renderIdentity.semanticHash
                    == expectedHash,
            "radialRotationAndReflectionCorrect":
                Self.maximumChannelDelta(
                    radial.rotation.first,
                    radial.rotation.second
                ) <= 8
                && Self.maximumChannelDelta(
                    radial.reflection.first,
                    radial.reflection.second
                ) <= 8,
            "resolvedResourcesAndMipsExact":
                actualResources == expectedResources,
            "strokeCompilerCacheCountersUnchanged":
                countersBeforeStroke == countersAfterStroke
                    && primary.pipelinePreparationUnchanged
                    && pipelineBefore == pipelineAfter,
            "tilingPeriodTranslationEqual":
                grid.first == grid.second
                    && Self.hasNontransparentPixel(grid.first),
        ]
        return ProfessionalRunAudit(
            invariantResults: results,
            prediction: prediction,
            grid: grid,
            eraser: eraser,
            radial: radial,
            pipelinePrepareCallCountBeforeStroke: pipelineBefore,
            pipelinePrepareCallCountAfterStroke: pipelineAfter
        )
    }

    func professionalEraserObservation(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> ProfessionalRasterPair {
        let context = try await makeContext(
            scene: scene,
            package: package
        )
        let trace = Self.trace(width: scene.width, height: scene.height)
        let painted = try commitOnly(
            context: context,
            brush: context.compiled,
            compositeMode: .draw,
            color: .black,
            trace: trace,
            diameter: package.definition.id.rawValue
                == "builtin.professional-natural-charcoal" ? 80 : 40
        )
        let eraserPackage = try self.package(for: "deposition-erase")
        let eraser = try await context.compiler.compileAndActivate(
            package: eraserPackage
        )
        try context.renderer.activateEraserBrush(eraser)
        let erased = try commitOnly(
            context: context,
            brush: eraser,
            compositeMode: .erase,
            color: InkColor(red: 1, green: 0, blue: 1, alpha: 1)!,
            trace: trace,
            diameter: package.definition.id.rawValue
                == "builtin.professional-natural-charcoal" ? 80 : 40
        )
        return ProfessionalRasterPair(first: painted, second: erased)
    }

    func professionalGridTranslationObservation(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> ProfessionalRasterPair {
        let first = try await periodicProjectionBytes(
            scene: scene,
            package: package,
            tiling: .grid,
            worldOffset: .zero
        )
        let second = try await periodicProjectionBytes(
            scene: scene,
            package: package,
            tiling: .grid,
            worldOffset: SIMD2(Float(scene.width), 0)
        )
        return ProfessionalRasterPair(first: first, second: second)
    }

    func professionalRadialProjectionObservations(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> ProfessionalRadialObservations {
        let trace = Self.professionalRadialTrace(
            width: scene.width,
            height: scene.height
        )
        let plain = try await professionalFiniteProjectionBytes(
            scene: scene,
            package: package,
            configuration: .plain,
            trace: trace
        )
        let rotationRendered = try await professionalFiniteProjectionBytes(
            scene: scene,
            package: package,
            configuration: .radial(
                RadialSymmetryConfiguration(
                    kind: .rotation,
                    rayCount: 2,
                    center: WorldPoint(
                        x: Float(scene.width) * 0.5,
                        y: Float(scene.height) * 0.5
                    ),
                    referenceAngleRadians: 0
                )
            ),
            trace: trace
        )
        let reflectionRendered =
            try await professionalFiniteProjectionBytes(
                scene: scene,
                package: package,
                configuration: .radial(
                    RadialSymmetryConfiguration(
                        kind: .mirror,
                        rayCount: 1,
                        center: WorldPoint(
                            x: Float(scene.width) * 0.5,
                            y: Float(scene.height) * 0.5
                        ),
                        referenceAngleRadians: 0
                    )
                ),
                trace: trace
            )
        return ProfessionalRadialObservations(
            rotation: ProfessionalRasterPair(
                first: rotationRendered,
                second: Self.mergedWithTransformedCopy(
                    plain,
                    width: scene.width,
                    height: scene.height,
                    transform: .rotateHalfTurn
                )
            ),
            reflection: ProfessionalRasterPair(
                first: reflectionRendered,
                second: Self.mergedWithTransformedCopy(
                    plain,
                    width: scene.width,
                    height: scene.height,
                    transform: .reflectVertically
                )
            )
        )
    }

    func professionalFiniteProjectionBytes(
        scene: HarnessScene,
        package: BrushPackage,
        configuration: FiniteSymmetryConfiguration,
        trace: [StrokeSample]
    ) async throws -> [UInt8] {
        let context = try await makeContext(scene: scene, package: package)
        try context.renderer.applyFiniteConfiguration(configuration)
        try context.renderer.activateDrawBrush(context.compiled)
        let capture = try performStroke(
            context: context,
            scene: scene,
            stem: Self.positiveStem(scene.name),
            trace: trace,
            diameter: package.definition.id.rawValue
                == "builtin.professional-natural-charcoal" ? 80 : 40
        )
        guard capture.pipelinePreparationUnchanged else {
            throw DepositionHarnessRunError.invariantFailed(
                scene: scene.name,
                invariant: "strokePipelinePreparationUnchanged"
            )
        }
        return Self.textureBytes(capture.committed)
    }

    func finishProfessionalRun(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild,
        context: Context,
        capture: StrokeCapture,
        audit: ProfessionalRunAudit,
        invariants: [String: Bool],
        countersBeforeStroke: BrushCompilerCounters,
        countersAfterStroke: BrushCompilerCounters,
        performance: ProfessionalPerformanceArtifacts?
    ) throws -> HarnessRunResult {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let liveURL = outputDirectory.appendingPathComponent(
            "\(scene.name).live.png"
        )
        let committedURL = outputDirectory.appendingPathComponent(
            "\(scene.name).committed.png"
        )
        let canonicalURL = outputDirectory.appendingPathComponent(
            "\(scene.name).canonical.png"
        )
        try Self.writePNGAtomically(capture.live, to: liveURL)
        try Self.writePNGAtomically(capture.committed, to: committedURL)
        try Self.writePNGAtomically(capture.canonical, to: canonicalURL)

        let observationRasters: [(String, [UInt8])] = [
            ("prediction-off", audit.prediction.first),
            ("prediction-on", audit.prediction.second),
            ("grid-origin", audit.grid.first),
            ("grid-translated", audit.grid.second),
            ("eraser-before", audit.eraser.first),
            ("eraser-after", audit.eraser.second),
            (
                "radial-rotation-rendered",
                audit.radial.rotation.first
            ),
            (
                "radial-rotation-reference",
                audit.radial.rotation.second
            ),
            (
                "radial-reflection-rendered",
                audit.radial.reflection.first
            ),
            (
                "radial-reflection-reference",
                audit.radial.reflection.second
            ),
        ]
        var observationURLs: [URL] = []
        for (name, bytes) in observationRasters {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).\(name).png"
            )
            try Self.writePNGAtomically(
                bgra: bytes,
                pixelSize: PixelSize(
                    width: scene.width,
                    height: scene.height
                ),
                to: url
            )
            observationURLs.append(url)
        }

        let definition = context.compiled.program.definition
        let characterization =
            try ProfessionalBrushCharacterizer.record(
                family: definition.metadata.displayName,
                renderIdentity: context.compiled.renderIdentity,
                trace: StrokeTraceFixtures.professionalSlowLine,
                program: context.compiled.program
            )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        let characterizationData = try encoder.encode(characterization)
        let characterizationURL = outputDirectory.appendingPathComponent(
            "\(scene.name).characterization.json"
        )
        try characterizationData.write(
            to: characterizationURL,
            options: .atomic
        )

        let resolvedResources =
            context.compiled.textures.keys.sorted().map { identity in
                ProfessionalBrushResolvedResource(
                    identity: identity,
                    kind: identity.hasPrefix("builtin.shape.")
                        ? "shape"
                        : "grain",
                    mipCount:
                        context.compiled.textures[identity]!.mipmapLevelCount
                )
            }
        guard let replayLimits = definition.replayLimits else {
            throw DepositionHarnessRunError.invariantFailed(
                scene: scene.name,
                invariant: "boundedLiveWork"
            )
        }
        let liveBytes = Self.textureBytes(capture.live)
        let committedBytes = Self.textureBytes(capture.committed)
        let canonicalBytes = Self.textureBytes(capture.canonical)
        let observations = ProfessionalBrushInvariantObservations(
            liveBGRA8SHA256: Self.sha256(liveBytes),
            committedBGRA8SHA256: Self.sha256(committedBytes),
            canonicalBGRA8SHA256: Self.sha256(canonicalBytes),
            liveNontransparentPixelCount:
                Self.nontransparentPixelCount(liveBytes),
            committedNontransparentPixelCount:
                Self.nontransparentPixelCount(committedBytes),
            canonicalNontransparentPixelCount:
                Self.nontransparentPixelCount(canonicalBytes),
            predictionOffBGRA8SHA256:
                Self.sha256(audit.prediction.first),
            predictionOnBGRA8SHA256:
                Self.sha256(audit.prediction.second),
            predictionMaximumChannelDelta: Self.maximumChannelDelta(
                audit.prediction.first,
                audit.prediction.second
            ),
            gridOriginBGRA8SHA256: Self.sha256(audit.grid.first),
            gridTranslatedBGRA8SHA256: Self.sha256(audit.grid.second),
            gridMaximumChannelDelta: Self.maximumChannelDelta(
                audit.grid.first,
                audit.grid.second
            ),
            eraserBeforeBGRA8SHA256: Self.sha256(audit.eraser.first),
            eraserAfterBGRA8SHA256: Self.sha256(audit.eraser.second),
            eraserBeforeNontransparentPixelCount:
                Self.nontransparentPixelCount(audit.eraser.first),
            eraserAfterNontransparentPixelCount:
                Self.nontransparentPixelCount(audit.eraser.second),
            eraserReducedAlphaPixelCount: Self.reducedAlphaPixelCount(
                before: audit.eraser.first,
                after: audit.eraser.second
            ),
            radialRotationRenderedBGRA8SHA256:
                Self.sha256(audit.radial.rotation.first),
            radialRotationReferenceBGRA8SHA256:
                Self.sha256(audit.radial.rotation.second),
            radialRotationMaximumChannelDelta: Self.maximumChannelDelta(
                audit.radial.rotation.first,
                audit.radial.rotation.second
            ),
            radialReflectionRenderedBGRA8SHA256:
                Self.sha256(audit.radial.reflection.first),
            radialReflectionReferenceBGRA8SHA256:
                Self.sha256(audit.radial.reflection.second),
            radialReflectionMaximumChannelDelta: Self.maximumChannelDelta(
                audit.radial.reflection.first,
                audit.radial.reflection.second
            ),
            replayMode: "replayTail",
            replayMaximumSamples: replayLimits.maximumSamples,
            replayMaximumDabs: replayLimits.maximumDabs,
            replayMaximumProjectedInstances:
                replayLimits.maximumProjectedInstances,
            pipelinePrepareCallCountBeforeStroke:
                audit.pipelinePrepareCallCountBeforeStroke,
            pipelinePrepareCallCountAfterStroke:
                audit.pipelinePrepareCallCountAfterStroke
        )
        let evidence = ProfessionalBrushSceneEvidence(
            schemaVersion:
                ProfessionalBrushSceneEvidence.currentSchemaVersion,
            scene: Self.positiveStem(scene.name),
            family: definition.metadata.displayName,
            definitionID: definition.id.rawValue,
            definitionSemanticHash:
                context.compiled.renderIdentity.semanticHash,
            pipelineKey: Self.pipelineDescription(
                context.compiled.depositionPipeline.key
            ),
            abiVersion:
                context.compiled.depositionPipeline.key.abiVersion,
            residentResourceBytes: context.compiled.residentByteCount,
            resolvedResources: resolvedResources,
            logicalDabCount: capture.logicalDabCount,
            projectedInstanceCount: capture.projectedInstanceCount,
            livePNGSHA256: ProfessionalBrushEvidenceValidator.sha256(
                try Data(contentsOf: liveURL)
            ),
            committedPNGSHA256:
                ProfessionalBrushEvidenceValidator.sha256(
                    try Data(contentsOf: committedURL)
                ),
            canonicalPNGSHA256:
                ProfessionalBrushEvidenceValidator.sha256(
                    try Data(contentsOf: canonicalURL)
                ),
            characterizationSHA256:
                ProfessionalBrushEvidenceValidator.sha256(
                    characterizationData
                ),
            rendererExecutableSHA256:
                try Self.runningExecutableSHA256(),
            previewCommitMaximumChannelDelta:
                capture.previewCommitMaximumChannelDelta,
            compilerCounters: ProfessionalBrushCompilerCounterEvidence(
                beforeCompile: .init(context.countersBeforeCompile),
                afterCompile: .init(context.countersAfterCompile),
                afterCacheHit: .init(countersBeforeStroke),
                beforeStroke: .init(countersBeforeStroke),
                afterStroke: .init(countersAfterStroke)
            ),
            telemetry: capture.telemetry,
            observations: observations,
            invariantResults: invariants
        )
        try ProfessionalBrushEvidenceValidator.validate(evidence)
        let evidenceURL = outputDirectory.appendingPathComponent(
            "\(scene.name).professional-evidence.json"
        )
        try evidence.encoded().write(to: evidenceURL, options: .atomic)

        let benchmark = Self.professionalBenchmark(
            scene: scene,
            build: build,
            device: device,
            capture: capture,
            evidence: evidence,
            characterization: characterization
        )
        let benchmarkURL = outputDirectory.appendingPathComponent(
            "\(scene.name).benchmark.json"
        )
        try BenchmarkRecord.encode(benchmark).write(
            to: benchmarkURL,
            options: .atomic
        )
        var performanceURLs: [URL] = []
        if let performance {
            let performanceFiles: [(String, Data)] = [
                ("professional-performance.json", performance.index),
                (
                    "professional-five-hundred-dabs.raw.json",
                    performance.fiveHundredDabs
                ),
                (
                    "professional-long-stroke.raw.json",
                    performance.longStroke
                ),
                (
                    "professional-long-stroke-trace.json",
                    performance.longStrokeTrace
                ),
            ]
            for (name, data) in performanceFiles {
                let url = outputDirectory.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                performanceURLs.append(url)
            }
        }

        try ProfessionalBrushEvidenceValidator.validateExpectations(
            scene: scene,
            actual: invariants
        )
        return HarnessRunResult(
            imageURL: liveURL,
            benchmarkURL: benchmarkURL,
            benchmark: benchmark,
            artifactURLs: [
                liveURL, committedURL, canonicalURL, characterizationURL,
                evidenceURL, benchmarkURL,
            ] + observationURLs + performanceURLs
        )
    }

    func professionalPerformanceArtifacts(
        scene: HarnessScene,
        build: BenchmarkBuild,
        package: BrushPackage,
        primary: StrokeCapture
    ) async throws -> ProfessionalPerformanceArtifacts {
        let stem = Self.positiveStem(scene.name)
        let context = try await makeContext(
            scene: scene,
            package: package
        )
        let resources =
            context.compiled.textures.keys.sorted().map { identity in
                ProfessionalBrushResolvedResource(
                    identity: identity,
                    kind: identity.hasPrefix("builtin.shape.")
                        ? "shape" : "grain",
                    mipCount:
                        context.compiled.textures[identity]!.mipmapLevelCount
                )
            }
        let source = ProfessionalPerformanceSource(
            gitCommit: build.gitCommit,
            rendererExecutableSHA256:
                try Self.runningExecutableSHA256(),
            gpuName: device.name,
            operatingSystem:
                ProcessInfo.processInfo.operatingSystemVersionString
        )

        let fiveBefore = context.compiler.debugCounters
        let fiveGPU = try measureProfessionalFiveHundredDabs(
            records: primary.scheduledRecords,
            context: context,
            width: scene.width,
            height: scene.height
        )
        let fiveAfter = context.compiler.debugCounters
        let five = ProfessionalFiveHundredDabEvidence(
            scene: stem,
            definitionID: package.definition.id.rawValue,
            semanticHash: context.compiled.renderIdentity.semanticHash,
            resolvedResources: resources,
            source: source,
            gpuMilliseconds: fiveGPU,
            compilerCountersBefore: .init(fiveBefore),
            compilerCountersAfter: .init(fiveAfter)
        )

        let performanceSize = PixelSize(width: 512, height: 512)
        let trace = Self.professionalLongStrokeTrace(
            width: performanceSize.width,
            height: performanceSize.height
        )
        let traceRecord = ProfessionalLongStrokeTrace(
            scene: stem,
            definitionID: package.definition.id.rawValue,
            semanticHash: context.compiled.renderIdentity.semanticHash,
            samples: trace.map {
                ProfessionalLongStrokeTraceSample(
                    x: $0.position.x,
                    y: $0.position.y,
                    pressure: $0.pressure,
                    timestamp: $0.timestamp,
                    phase: Self.phaseName($0.phase),
                    source: "mouse",
                    kind: "actual"
                )
            }
        )
        let traceData = try Self.professionalJSON(traceRecord)
        let longContext = try await makeContext(
            scene: scene,
            package: package,
            drawableSize: performanceSize
        )
        let longBefore = longContext.compiler.debugCounters
        let capture = try performStroke(
            context: longContext,
            scene: scene,
            stem: stem,
            trace: trace,
            partitionMode: .everySample,
            collectPerformanceEvidence: true
        )
        let longAfter = longContext.compiler.debugCounters
        let cpuMilliseconds = capture.strokeMetrics.map(
            \.cpuEncodeMilliseconds
        )
        let gpuMilliseconds = capture.strokeMetrics.map(
            \.gpuMilliseconds
        )
        let eventToSubmitNanoseconds = capture.strokeMetrics.map(
            \.eventToSubmitNanoseconds
        )
        guard capture.strokeMetrics.count == 128,
              capture.identityFrames.count == 128,
              eventToSubmitNanoseconds.count == 128,
              eventToSubmitNanoseconds.allSatisfy({ $0 > 0 }),
              let limits = package.definition.replayLimits,
              let trend = ProfessionalLongStrokeTrendEvidence(
                  cpuMilliseconds: cpuMilliseconds,
                  gpuMilliseconds: gpuMilliseconds
              )
        else {
            throw DepositionHarnessRunError.invariantFailed(
                scene: scene.name,
                invariant: "professionalLongStrokeEvidenceComplete"
            )
        }
        let long = ProfessionalLongStrokeEvidence(
            scene: stem,
            definitionID: package.definition.id.rawValue,
            semanticHash: longContext.compiled.renderIdentity.semanticHash,
            resolvedResources: resources,
            source: source,
            inputSampleCount: trace.count,
            traceSHA256:
                ProfessionalBrushEvidenceValidator.sha256(traceData),
            cpuPreparationMilliseconds: cpuMilliseconds,
            gpuMilliseconds: gpuMilliseconds,
            eventToSubmitNanoseconds: eventToSubmitNanoseconds,
            trend: trend,
            identityFrames: capture.identityFrames,
            logicalDabCount: capture.logicalDabCount,
            projectedInstanceCount: capture.projectedInstanceCount,
            replayMaximumDabs: limits.maximumDabs,
            replayMaximumProjectedInstances:
                limits.maximumProjectedInstances,
            compilerCountersBefore: .init(longBefore),
            compilerCountersAfter: .init(longAfter)
        )
        let fiveData = try Self.professionalJSON(five)
        let longData = try Self.professionalJSON(long)
        let index = ProfessionalPerformanceIndex(
            scene: stem,
            definitionID: package.definition.id.rawValue,
            semanticHash: context.compiled.renderIdentity.semanticHash,
            resolvedResources: resources,
            source: source,
            fiveHundredDabs: .init(
                path: "professional-five-hundred-dabs.raw.json",
                sha256:
                    ProfessionalBrushEvidenceValidator.sha256(fiveData)
            ),
            longStroke: .init(
                path: "professional-long-stroke.raw.json",
                sha256:
                    ProfessionalBrushEvidenceValidator.sha256(longData)
            )
        )
        return ProfessionalPerformanceArtifacts(
            index: try Self.professionalJSON(index),
            fiveHundredDabs: fiveData,
            longStroke: longData,
            longStrokeTrace: traceData
        )
    }

    func measureProfessionalFiveHundredDabs(
        records: [ProjectedDepositionRecord],
        context: Context,
        width: Int,
        height: Int
    ) throws -> [Double] {
        guard !records.isEmpty else {
            throw DepositionHarnessRunError.invariantFailed(
                scene: context.compiled.program.definition.id.rawValue,
                invariant: "professionalFiveHundredDabSource"
            )
        }
        let exact = (0..<500).map { records[$0 % records.count] }
        var measurements: [Double] = []
        for _ in 0..<3 {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let target = device.makeTexture(descriptor: descriptor),
                  let queue = device.makeCommandQueue(),
                  let commandBuffer = queue.makeCommandBuffer()
            else {
                throw DepositionHarnessRunError
                    .metalResourceUnavailable(
                        "professional 500-dab measurement resources"
                    )
            }
            let empty = [UInt8](
                repeating: 0,
                count: width * height * 4
            )
            target.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: empty,
                bytesPerRow: width * 4
            )
            let pool = try DabInstanceBufferPool(device: device)
            var encoder = DepositionEncoder(
                instancePool: pool,
                frameUniforms: Self.frameUniforms(
                    width: width,
                    height: height
                )
            )
            let prepared = try encoder.preflight(
                records: exact,
                binding: context.compiled.depositionPipeline,
                material: context.compiled.depositionMaterial,
                target: target
            )
            _ = try encoder.encode(
                prepared,
                into: target,
                commandBuffer: commandBuffer
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else {
                throw DepositionHarnessRunError
                    .metalResourceUnavailable(
                        "completed professional 500-dab command"
                    )
            }
            measurements.append(
                max(
                    0,
                    (
                        commandBuffer.gpuEndTime
                            - commandBuffer.gpuStartTime
                    ) * 1_000
                )
            )
        }
        return measurements
    }

    static func professionalLongStrokeTrace(
        width: Int,
        height: Int
    ) -> [StrokeSample] {
        (0..<128).map { index in
            let x = Float(width)
                * (index.isMultiple(of: 2) ? 0.125 : 0.875)
            let y = Float(height) * 0.5
            let phase: StrokePhase =
                index == 0 ? .began : (index == 127 ? .ended : .moved)
            return StrokeSample(
                position: ScreenPoint(x: x, y: y),
                pressure: 0.58,
                timestamp: Double(index) * 0.004,
                phase: phase,
                source: .mouse,
                kind: .actual
            )
        }
    }

    static func phaseName(_ phase: StrokePhase) -> String {
        switch phase {
        case .began: "began"
        case .moved: "moved"
        case .ended: "ended"
        case .cancelled: "cancelled"
        }
    }

    static func professionalJSON<T: Encodable>(
        _ value: T
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        return try encoder.encode(value)
    }

    func invariantResults(
        stem: String,
        scene: HarnessScene,
        primary: StrokeCapture,
        context: Context,
        package: BrushPackage
    ) async throws -> [String: Bool] {
        var results: [String: Bool] = [:]
        let definition = context.compiled.program.definition
        if let productionDefinition = productionAnchorDefinitions[stem] {
            let expectedProgram = try BrushProgramCompiler.compile(
                productionDefinition
            )
            let expectedSemanticHash = try package.contentHash
            let identityIsExact =
                package.definition == productionDefinition
                && definition == productionDefinition
                && context.compiled.program == expectedProgram
                && context.compiled.renderIdentity.definitionID
                    == productionDefinition.id
                && context.compiled.renderIdentity.semanticHash
                    == expectedSemanticHash
            results["productionAnchorIdentityExact"] = identityIsExact
            results["familyAndAccumulationCorrect"] = identityIsExact
        } else {
            let expected = DepositionHarnessFixtures.expectedPipeline(
                for: stem
            )
            results["familyAndAccumulationCorrect"] =
                expected.map {
                    definition.id.rawValue == $0.definitionID
                        && definition.material.accumulation == $0.accumulation
                        && definition.material.edgeTreatment == $0.edge
                        && definition.coverage.shapes.first?.shape == $0.shape
                        && definition.placement.baseFlow == $0.flow
                } ?? true
        }
        results["previewCommitMaximumDeltaWithinTolerance"] =
            primary.previewCommitMaximumChannelDelta <= 1

        switch stem {
        case "deposition-custom-asymmetric":
            results["customTexturesExact"] =
                customTexturesAreExact(context.compiled)
        case "deposition-layer-matrix":
            let audit = try await layerMatrixAudit(scene: scene)
            results["secondaryLayerPresent"] = audit.complete
            results["layerCartesianRenderDistinct"] =
                audit.renderDistinct
        case "deposition-stamp-size-mips":
            results["textureMipSelectionCorrect"] =
                try await mipMatrixIsComplete(scene: scene)
        case "deposition-kinematics":
            let batch = try await canonicalVariant(
                scene: scene,
                package: package,
                partitionMode: .everySample
            )
            let zoomTrace = Self.trace(
                width: scene.width,
                height: scene.height,
                screenScale: 2
            )
            let zoom = try await canonicalVariant(
                scene: scene,
                package: package,
                trace: zoomTrace,
                zoom: 2
            )
            results["batchPartitionsEqual"] =
                batch == Self.textureBytes(primary.canonical)
            results["zoomIndependent"] =
                zoom == Self.textureBytes(primary.canonical)
        case "deposition-periodic-seams":
            results["tilingPeriodTranslationEqual"] =
                try await tilingTranslationIsEqual(
                    scene: scene,
                    package: package
                )
            results["symmetryOrderEqual"] =
                try symmetryOrderIsEqual(
                    records: primary.scheduledRecords,
                    compiled: context.compiled,
                    width: scene.width,
                    height: scene.height
                )
        case "deposition-radial-reflection":
            let audit = try await radialReflectionAudit(
                scene: scene,
                package: package
            )
            results["reflectionHandednessCorrect"] =
                audit.reflectionHandednessCorrect
            results["symmetryOrderEqual"] = audit.symmetryOrderEqual
        case "deposition-prediction":
            results["predictionOnOffEqual"] =
                try await predictionIsEqual(
                    scene: scene,
                    package: package
                )
        case "deposition-erase":
            results["eraseColorIndependent"] =
                try await eraseColorIsIndependent(scene: scene)
        case "deposition-preview-commit":
            results["cancelPreservesCanonical"] =
                try await cancelPreservesCanonical(
                    scene: scene,
                    package: package
                )
        case "deposition-cache-pinning":
            let audit = try await cachePinningAudit(scene: scene)
            results["activeCompiledBrushPinned"] =
                audit.activeCompiledBrushPinned
            results["activeBrushSurvivesPressureAndFailure"] =
                audit.activeBrushSurvivesPressureAndFailure
        case "deposition-failure-matrix":
            let audit = try await failureMatrixAudit(
                scene: scene,
                package: package
            )
            results["failurePreservesCanonicalAndHistory"] =
                audit.allFailuresPreservedState
            results["failureStartsFromNonemptyExactHistory"] =
                audit.startedFromNonemptyExactHistory
            results["pipelineFailureUsesSeededRenderer"] =
                audit.pipelineFailureUsesSeededRenderer
        default:
            break
        }
        return results
    }

    func canonicalVariant(
        scene: HarnessScene,
        package: BrushPackage,
        trace: [StrokeSample]? = nil,
        partitionMode: PartitionMode = .oneFrame,
        zoom: Float = 1,
        tiling: TilingKind = .grid,
        diameter: Float? = nil
    ) async throws -> [UInt8] {
        let variant = try await makeContext(
            scene: scene,
            package: package,
            tiling: tiling
        )
        let capture = try performStroke(
            context: variant,
            scene: scene,
            stem: Self.positiveStem(scene.name),
            trace: trace,
            partitionMode: partitionMode,
            zoom: zoom,
            diameter: diameter
        )
        guard capture.pipelinePreparationUnchanged else {
            throw DepositionHarnessRunError.invariantFailed(
                scene: scene.name,
                invariant: "strokePipelinePreparationUnchanged"
            )
        }
        return Self.textureBytes(capture.canonical)
    }

    func predictionIsEqual(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let observation = try await professionalPredictionObservation(
            scene: scene,
            package: package
        )
        return observation.first == observation.second
    }

    func professionalPredictionObservation(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> ProfessionalRasterPair {
        let actual = Self.trace(
            width: scene.width,
            height: scene.height
        )
        var predicted = actual
        predicted.insert(
            Self.sample(
                x: Float(scene.width) * 0.78,
                y: Float(scene.height) * 0.58,
                pressure: 0.55,
                timestamp: 0.045,
                phase: .moved,
                kind: .predicted
            ),
            at: predicted.count - 1
        )
        let without = try await canonicalVariant(
            scene: scene,
            package: package,
            trace: actual
        )
        let with = try await canonicalVariant(
            scene: scene,
            package: package,
            trace: predicted
        )
        return ProfessionalRasterPair(first: without, second: with)
    }

    func tilingTranslationIsEqual(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let base = Self.trace(width: scene.width, height: scene.height)
            .map {
                Self.repositioned(
                    $0,
                    x: $0.position.x.rounded() - 16,
                    y: $0.position.y.rounded()
                )
            }
        let translated = base.map {
            Self.translated($0, dx: Float(scene.width))
        }
        let first = try await canonicalVariant(
            scene: scene,
            package: package,
            trace: base,
            tiling: .grid
        )
        let second = try await canonicalVariant(
            scene: scene,
            package: package,
            trace: translated,
            tiling: .grid
        )
        guard first == second else { return false }
        for tiling in TilingKind.periodicCases {
            let configuration =
                PeriodicSymmetryConfiguration.defaultConfiguration(
                    presetID: tiling,
                    canonicalRasterSize: PixelSize(
                        width: scene.width,
                        height: scene.height
                    )
                )
            let compiled = try SymmetryDescriptorCompiler.compile(
                configuration: configuration,
                canonicalRasterSize: PixelSize(
                    width: scene.width,
                    height: scene.height
                )
            )
            guard let periodic = compiled.domain.periodic else {
                return false
            }
            let familyBase = try await periodicProjectionBytes(
                scene: scene,
                package: package,
                tiling: tiling,
                worldOffset: .zero
            )
            guard Self.hasNontransparentPixel(familyBase) else {
                return false
            }
            for (axis, reflectionAxis, basis) in [
                (
                    SymmetryAxis.x,
                    SymmetryReflectionAxes.x,
                    periodic.translationBasis.u
                ),
                (
                    SymmetryAxis.y,
                    SymmetryReflectionAxes.y,
                    periodic.translationBasis.v
                ),
            ] {
                let phaseMultiplier: Float =
                    periodic.phase?.indexAxis == axis
                    ? Float(periodic.phase?.fractions.count ?? 1)
                    : 1
                let reflectionMultiplier: Float =
                    periodic.alternatingReflections.contains(reflectionAxis)
                    ? 2 : 1
                let familyShifted = try await periodicProjectionBytes(
                    scene: scene,
                    package: package,
                    tiling: tiling,
                    worldOffset:
                        basis * phaseMultiplier * reflectionMultiplier
                )
                guard Self.maximumChannelDelta(
                    familyBase,
                    familyShifted
                ) <= 1 else {
                    return false
                }
            }
        }
        return true
    }

    func periodicProjectionBytes(
        scene: HarnessScene,
        package: BrushPackage,
        tiling: TilingKind,
        worldOffset: SIMD2<Float>
    ) async throws -> [UInt8] {
        let context = try await makeContext(
            scene: scene,
            package: package,
            tiling: tiling
        )
        let center = SIMD2<Float>(
            Float(scene.width) * 0.31,
            Float(scene.height) * 0.37
        ) + worldOffset
        let radius: Float = 13
        let brushToWorld = Affine2D(
            xAxis: SIMD2(radius, 0),
            yAxis: SIMD2(0, radius),
            translation: center
        )
        let dab = LogicalDab(
            position: WorldPoint(center),
            brushToWorld: brushToWorld,
            radius: radius,
            diameter: radius * 2,
            spacing: 1,
            flow: 0.75,
            strokeOpacity: 0.9,
            rotation: 0,
            scatter: .zero,
            hardness: 0.82,
            grainOffset: .zero,
            grainScale: 1,
            grainRotation: 0,
            color: .black,
            colorAdjustment: .identity,
            materialFamily: .ink,
            materialContribution: 0.9,
            sourceDistance: 0,
            ordinal: 0,
            isPredicted: false,
            primaryGrainToWorld: brushToWorld
        )
        let strategy = TilingStrategy(
            kind: tiling,
            tileSize: PatternSize(
                width: Float(scene.width),
                height: Float(scene.height)
            )
        )
        let fragments = TilingProjection.fragments(
            for: StampFootprint(
                brushToWorld: brushToWorld,
                localBounds: AxisAlignedRect(
                    minimum: SIMD2(-1, -1),
                    maximum: SIMD2(1, 1)
                ),
                coverageSymmetry: .oriented
            ),
            using: strategy
        )
        let records = try fragments.map {
            ProjectedDepositionRecord(
                identity: 0,
                instance: try PatternDepositionStampInstance(
                    fragment: $0,
                    dab: dab,
                    logicalOrdinal: 0,
                    isometryOrdinal: $0.imageOrdinal
                ),
                radialPage: nil
            )
        }
        return try directlyEncodedBytes(
            records: records,
            compiled: context.compiled,
            width: scene.width,
            height: scene.height
        )
    }

    func eraseColorIsIndependent(scene: HarnessScene) async throws -> Bool {
        let first = try await erasedCanonical(
            scene: scene,
            color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!
        )
        let second = try await erasedCanonical(
            scene: scene,
            color: InkColor(red: 0, green: 1, blue: 1, alpha: 1)!
        )
        return first == second
    }

    func erasedCanonical(
        scene: HarnessScene,
        color: InkColor
    ) async throws -> [UInt8] {
        let inkPackage = try package(for: "deposition-ink")
        let context = try await makeContext(
            scene: scene,
            package: inkPackage
        )
        _ = try commitOnly(
            context: context,
            brush: context.compiled,
            compositeMode: .draw,
            color: .black,
            trace: Self.trace(width: scene.width, height: scene.height)
        )
        let eraser = try await context.compiler.compileAndActivate(
            package: package(for: "deposition-erase")
        )
        try context.renderer.activateEraserBrush(eraser)
        return try commitOnly(
            context: context,
            brush: eraser,
            compositeMode: .erase,
            color: color,
            trace: Self.trace(width: scene.width, height: scene.height)
        )
    }

    func cancelPreservesCanonical(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let context = try await makeContext(
            scene: scene,
            package: package
        )
        let capture = try performStroke(
            context: context,
            scene: scene,
            stem: Self.positiveStem(scene.name),
            cancel: true
        )
        return capture.canonicalBefore
            == Self.textureBytes(capture.canonical)
    }

    func radialReflectionAudit(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> (
        reflectionHandednessCorrect: Bool,
        symmetryOrderEqual: Bool
    ) {
        let context = try await makeContext(
            scene: scene,
            package: package
        )
        try context.renderer.applyFiniteConfiguration(
            .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 7,
                center: WorldPoint(
                    x: Float(scene.width) * 0.5,
                    y: Float(scene.height) * 0.5
                ),
                referenceAngleRadians: 0.19
            ))
        )
        try context.renderer.activateDrawBrush(context.compiled)
        let token = RendererOperationToken(rawValue: Self.seed &+ 20)
        let samples = Self.trace(width: scene.width, height: scene.height)
        var generatedLogicalDabs: [LogicalDab] = []
        context.renderer.onLogicalDabsGenerated = {
            generatedLogicalDabs.append($0)
        }
        try context.renderer.beginStroke(
            token: token,
            sample: samples[0],
            style: StrokeRenderStyle(
                color: .black,
                diameter: 18,
                compositeMode: .draw,
                eraserStrength: 1,
                program: context.compiled.program,
                renderIdentity: context.compiled.renderIdentity,
                seed: Self.seed
            )
        )
        for sample in samples.dropFirst().dropLast() {
            try context.renderer.appendStroke(
                token: token,
                sample: sample
            )
        }
        try context.renderer.drainPreparedStrokeInputForHarness()
        context.renderer.onLogicalDabsGenerated = nil
        let records = try context.renderer.projectLogicalDabsForHarness(
            generatedLogicalDabs
        )
        let compiled = try SymmetryDescriptorCompiler.compile(
            finiteConfiguration: .radial(
                RadialSymmetryConfiguration(
                    kind: .mandala,
                    rayCount: 7,
                    center: WorldPoint(
                        x: Float(scene.width) * 0.5,
                        y: Float(scene.height) * 0.5
                    ),
                    referenceAngleRadians: 0.19
                )
            ),
            canvasSize: PixelSize(
                width: scene.width,
                height: scene.height
            )
        )
        let reflectedByOrdinal = Dictionary(
            uniqueKeysWithValues: compiled.images.map {
                ($0.ordinal, $0.operation.reflected)
            }
        )
        let flags = records.map {
            $0.instance.metadata.y
                & DepositionShapeFlags.reflected != 0
        }
        let flagsAreCorrect = !records.isEmpty
            && flags.contains(true)
            && flags.contains(false)
            && records.allSatisfy {
            let ordinal = UInt8(truncatingIfNeeded: $0.instance.identity.z)
            let reflected =
                $0.instance.metadata.y
                    & DepositionShapeFlags.reflected != 0
            return reflectedByOrdinal[ordinal] == reflected
        }
        let orderIsEqual = try symmetryOrderIsEqual(
            records: records,
            compiled: context.compiled,
            width: scene.width,
            height: scene.height
        )
        try context.renderer.cancelStroke(token: token)
        try context.renderer.drainStrokeWorkspaceRetirementForHarness()
        let renderedReflectionIsCorrect =
            try await radialMirrorDisplayIsCorrect(
                scene: scene,
                package: package
            )
        return (
            flagsAreCorrect && renderedReflectionIsCorrect,
            orderIsEqual
        )
    }

    func radialMirrorDisplayIsCorrect(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let context = try await makeContext(
            scene: scene,
            package: package
        )
        try context.renderer.applyFiniteConfiguration(
            .radial(RadialSymmetryConfiguration(
                kind: .mirror,
                rayCount: 1,
                center: WorldPoint(
                    x: Float(scene.width) * 0.5,
                    y: Float(scene.height) * 0.5
                ),
                referenceAngleRadians: 0
            ))
        )
        try context.renderer.activateDrawBrush(context.compiled)
        let y = Float(scene.height) * 0.32
        let trace = [
            Self.sample(
                x: Float(scene.width) * 0.28,
                y: y,
                pressure: 0.8,
                timestamp: 0,
                phase: .began
            ),
            Self.sample(
                x: Float(scene.width) * 0.72,
                y: y,
                pressure: 0.8,
                timestamp: 0.01,
                phase: .moved
            ),
            Self.sample(
                x: Float(scene.width) * 0.72,
                y: y,
                pressure: 0.8,
                timestamp: 0.02,
                phase: .ended
            ),
        ]
        let capture = try performStroke(
            context: context,
            scene: scene,
            stem: "deposition-radial-reflection",
            trace: trace,
            color: .black
        )
        let display = Self.textureBytes(capture.committed)
        guard Self.hasNontransparentPixel(display) else { return false }
        var reference = display
        let rowBytes = scene.width * 4
        for y in 0..<scene.height {
            let mirroredY = scene.height - 1 - y
            let destinationRange =
                (y * rowBytes)..<((y + 1) * rowBytes)
            let sourceStart = mirroredY * rowBytes
            let sourceEnd = (mirroredY + 1) * rowBytes
            let sourceRange = sourceStart..<sourceEnd
            reference.replaceSubrange(
                destinationRange,
                with: display[sourceRange]
            )
        }
        return Self.maximumChannelDelta(display, reference) <= 1
    }

    func customTexturesAreExact(_ brush: CompiledBrush) -> Bool {
        let expected: [(String, DepositionTextureSlot)] = [
            (
                DepositionHarnessFixtures.customShapeID,
                .primaryShape
            ),
            (
                DepositionHarnessFixtures.customGrainID,
                .primaryGrain
            ),
        ]
        return Set(brush.textures.keys)
                == Set(expected.map(\.0))
            && expected.allSatisfy { id, slot in
                guard let compiledTexture = brush.textures[id],
                      let bound =
                        brush.depositionMaterial.textures[slot]
                else {
                    return false
                }
                return ObjectIdentifier(compiledTexture as AnyObject)
                    == ObjectIdentifier(bound as AnyObject)
            }
            && brush.report.compatibility.allSatisfy {
                $0.level == .exact
            }
    }

    struct LayerMatrixAudit {
        let complete: Bool
        let renderDistinct: Bool
    }

    func layerMatrixAudit(scene: HarnessScene) async throws
        -> LayerMatrixAudit
    {
        var observed = Set<BrushShapeCombinationMode>()
        var sawOneShape = false
        var sawTwoShapes = false
        var grainCounts = Set<Int>()
        var outputs: [String: String] = [:]
        var resourceSlotsAreExact = true
        var everyVariantRendered = true
        for combination in [
            BrushShapeCombinationMode.multiply,
            .minimum,
            .maximum,
        ] {
            for twoShapes in [false, true] {
                for grainCount in 0...2 {
                    let package =
                        try DepositionHarnessFixtures.layerPackage(
                            combination: combination,
                            grainCount: grainCount,
                            twoShapes: twoShapes
                        )
                    let context = try await makeContext(
                        scene: scene,
                        package: package
                    )
                    let coverage =
                        context.compiled.program.definition.coverage
                    sawOneShape =
                        sawOneShape || coverage.shapes.count == 1
                    sawTwoShapes =
                        sawTwoShapes || coverage.shapes.count == 2
                    grainCounts.insert(coverage.grains.count)
                    if coverage.shapes.count == 2 {
                        observed.insert(
                            coverage.shapes[1].combination
                        )
                    }
                    var expectedSlots =
                        Set<DepositionTextureSlot>([.primaryShape])
                    if twoShapes {
                        expectedSlots.insert(.secondaryShape)
                    }
                    if grainCount > 0 {
                        expectedSlots.insert(.primaryGrain)
                    }
                    if grainCount > 1 {
                        expectedSlots.insert(.secondaryGrain)
                    }
                    resourceSlotsAreExact =
                        resourceSlotsAreExact
                        && Set(
                            context.compiled.depositionMaterial
                                .textures.boundSlots
                        ) == expectedSlots
                    guard context.compiled.pipelineKey
                            .functionConstants.usesSecondaryShape
                            == twoShapes,
                          context.compiled.pipelineKey
                            .functionConstants.usesGrain
                            == (grainCount > 0),
                          context.compiled.pipelineKey
                            .functionConstants.usesSecondaryGrain
                            == (grainCount > 1)
                    else {
                        return LayerMatrixAudit(
                            complete: false,
                            renderDistinct: false
                        )
                    }
                    let capture = try performStroke(
                        context: context,
                        scene: scene,
                        stem: "deposition-layer-matrix"
                    )
                    let bytes = Self.textureBytes(capture.canonical)
                    everyVariantRendered =
                        everyVariantRendered
                        && Self.hasNontransparentPixel(bytes)
                        && capture.pipelinePreparationUnchanged
                    outputs[
                        Self.layerVariantKey(
                            combination: combination,
                            twoShapes: twoShapes,
                            grainCount: grainCount
                        )
                    ] = DepositionSceneEvidence.sha256(bytes)
                }
            }
        }
        let complete = sawOneShape
            && sawTwoShapes
            && grainCounts == [0, 1, 2]
            && observed == [.multiply, .minimum, .maximum]
            && resourceSlotsAreExact
            && outputs.count == 18

        var pixelsAreDistinct = true
        for grainCount in 0...2 {
            let twoShapeDigests = Set(
                [
                    BrushShapeCombinationMode.multiply,
                    .minimum,
                    .maximum,
                ].compactMap {
                    outputs[
                        Self.layerVariantKey(
                            combination: $0,
                            twoShapes: true,
                            grainCount: grainCount
                        )
                    ]
                }
            )
            pixelsAreDistinct =
                pixelsAreDistinct && twoShapeDigests.count == 3
        }
        for combination in [
            BrushShapeCombinationMode.multiply,
            .minimum,
            .maximum,
        ] {
            for twoShapes in [false, true] {
                let grainDigests = Set((0...2).compactMap {
                    outputs[
                        Self.layerVariantKey(
                            combination: combination,
                            twoShapes: twoShapes,
                            grainCount: $0
                        )
                    ]
                })
                pixelsAreDistinct =
                    pixelsAreDistinct && grainDigests.count == 3
            }
            for grainCount in 0...2 {
                let oneShape = outputs[
                    Self.layerVariantKey(
                        combination: combination,
                        twoShapes: false,
                        grainCount: grainCount
                    )
                ]
                let twoShapes = outputs[
                    Self.layerVariantKey(
                        combination: combination,
                        twoShapes: true,
                        grainCount: grainCount
                    )
                ]
                pixelsAreDistinct =
                    pixelsAreDistinct
                    && oneShape != nil
                    && twoShapes != nil
                    && oneShape != twoShapes
            }
        }
        return LayerMatrixAudit(
            complete: complete,
            renderDistinct:
                complete && everyVariantRendered && pixelsAreDistinct
        )
    }

    static func layerVariantKey(
        combination: BrushShapeCombinationMode,
        twoShapes: Bool,
        grainCount: Int
    ) -> String {
        "\(combination.rawValue):\(twoShapes):\(grainCount)"
    }

    func mipMatrixIsComplete(scene: HarnessScene) async throws -> Bool {
        let package = try package(for: "deposition-stamp-size-mips")
        let context = try await makeContext(
            scene: scene,
            package: package
        )
        guard let levels = context.compiled.textures.values
            .map(\.mipmapLevelCount).max(), levels >= 4
        else {
            return false
        }
        let limits = context.compiled.program.definition.limits
        let diameters: [Float] = [
            limits.minimumDiameter,
            22,
            limits.maximumDiameter,
        ]
        let selected = Set(diameters.map {
            max(
                0,
                min(
                    levels - 1,
                    Int(floor(log2(64 / max(1, $0))))
                )
            )
        })
        var digests = Set<String>()
        var observedCenterAlphas: [Float: UInt8] = [:]
        for diameter in diameters {
            let bytes = try await canonicalVariant(
                scene: scene,
                package: package,
                diameter: diameter
            )
            guard Self.hasNontransparentPixel(bytes) else { return false }
            digests.insert(DepositionSceneEvidence.sha256(bytes))
            observedCenterAlphas[diameter] = try mipProbeCenterAlpha(
                scene: scene,
                compiled: context.compiled,
                diameter: diameter
            )
        }
        guard let resource = package.manifest.resources.first,
              let resourceData = package.resourceData[resource.id]
        else {
            return false
        }
        let decoded = try BrushAssetDecoder.decode(
            resource: resource,
            data: resourceData,
            profile: BrushDeviceProfile(
                registryID: device.registryID,
                recommendedWorkingSetBytes:
                    max(
                        device.recommendedMaxWorkingSetSize,
                        64 * 1_024 * 1_024
                    ),
                maximumWorkingTextureDimension: 4_096,
                brushCacheBudgetBytes: 64 * 1_024 * 1_024,
                targetFramesPerSecond: 120
            )
        )
        let samplesMatchExpectedLOD = diameters.allSatisfy { diameter in
            guard let observed = observedCenterAlphas[diameter] else {
                return false
            }
            let expected = Self.expectedMipProbeAlpha(
                decoded: decoded,
                diameter: diameter
            )
            return abs(Int(observed) - Int(expected)) <= 2
        }
        return selected.count == diameters.count
            && digests.count == diameters.count
            && Set(observedCenterAlphas.values).count == diameters.count
            && samplesMatchExpectedLOD
    }

    func mipProbeCenterAlpha(
        scene: HarnessScene,
        compiled: CompiledBrush,
        diameter: Float
    ) throws -> UInt8 {
        let center = SIMD2<Float>(
            Float(scene.width / 2) + 0.5,
            Float(scene.height / 2) + 0.5
        )
        let radius = diameter * 0.5
        let brushToWorld = Affine2D(
            xAxis: SIMD2(radius, 0),
            yAxis: SIMD2(0, radius),
            translation: center
        )
        let dab = LogicalDab(
            position: WorldPoint(center),
            brushToWorld: brushToWorld,
            radius: radius,
            diameter: diameter,
            spacing: 1,
            flow: 1,
            strokeOpacity: 1,
            rotation: 0,
            scatter: .zero,
            hardness: 1,
            grainOffset: .zero,
            grainScale: 1,
            grainRotation: 0,
            color: .black,
            colorAdjustment: .identity,
            materialFamily: .ink,
            materialContribution: 1,
            sourceDistance: 0,
            ordinal: 0,
            isPredicted: false,
            primaryGrainToWorld: nil
        )
        let fragments = TilingProjection.fragments(
            for: StampFootprint(
                brushToWorld: brushToWorld,
                localBounds: AxisAlignedRect(
                    minimum: SIMD2(-1, -1),
                    maximum: SIMD2(1, 1)
                ),
                coverageSymmetry: .oriented
            ),
            using: TilingStrategy(
                kind: .grid,
                tileSize: PatternSize(
                    width: Float(scene.width),
                    height: Float(scene.height)
                )
            )
        )
        let records = try fragments.map {
            ProjectedDepositionRecord(
                identity: 0,
                instance: try PatternDepositionStampInstance(
                    fragment: $0,
                    dab: dab,
                    logicalOrdinal: 0,
                    isometryOrdinal: $0.imageOrdinal
                ),
                radialPage: nil
            )
        }
        let bytes = try directlyEncodedBytes(
            records: records,
            compiled: compiled,
            width: scene.width,
            height: scene.height
        )
        let pixelOffset =
            ((scene.height / 2) * scene.width + scene.width / 2) * 4
        return bytes[pixelOffset + 3]
    }
}

private extension DepositionHarnessRunner {
    struct FailureMatrixAudit {
        let allFailuresPreservedState: Bool
        let startedFromNonemptyExactHistory: Bool
        let pipelineFailureUsesSeededRenderer: Bool
    }

    struct CachePinningAudit {
        let activeCompiledBrushPinned: Bool
        let activeBrushSurvivesPressureAndFailure: Bool
    }

    func cachePinningAudit(scene: HarnessScene) async throws
        -> CachePinningAudit
    {
        let firstPackage =
            try DepositionHarnessFixtures.cachePackage(index: 1)
        let context = try await makeContext(
            scene: scene,
            package: firstPackage,
            cacheBudgetBytes: 6_000,
            armablePipelineFailure: true
        )
        let compiler = context.compiler
        let first = context.compiled
        let firstKeys = first.cacheKeys
        let firstPinned =
            Set(compiler.pinnedKeys) == firstKeys
            && Set(compiler.cachedKeys).isSuperset(of: firstKeys)
            && context.renderer.harnessPreparedDrawBrushIdentity
                == first.renderIdentity
        let firstBytes = try commitOnly(
            context: context,
            brush: first,
            compositeMode: .draw,
            color: .black,
            trace: Self.trace(width: scene.width, height: scene.height)
        )
        let originalCacheKeys = compiler.cachedKeys
        let originalPinnedKeys = compiler.pinnedKeys
        let originalResidentBytes = compiler.residentByteCount
        let pressure = compiler.handleMemoryPressure(
            targetResidentBytes: max(0, originalResidentBytes - 1)
        )
        let pressurePreservedOriginal: Bool
        if case let .activeBrushExceedsTarget(
            requiredBytes,
            targetBytes
        ) = pressure {
            pressurePreservedOriginal =
                requiredBytes == originalResidentBytes
                && targetBytes == max(0, originalResidentBytes - 1)
                && compiler.activeBrush === first
                && compiler.cachedKeys == originalCacheKeys
                && compiler.pinnedKeys == originalPinnedKeys
                && compiler.residentByteCount == originalResidentBytes
        } else {
            pressurePreservedOriginal = false
        }

        guard let failurePreparer = context.pipelineFailurePreparer else {
            return CachePinningAudit(
                activeCompiledBrushPinned: false,
                activeBrushSurvivesPressureAndFailure: false
            )
        }
        let secondPackage =
            try DepositionHarnessFixtures.cachePackage(index: 2)
        failurePreparer.armFailure()
        let failedActivationPreservedOriginal: Bool
        do {
            _ = try await compiler.compileAndActivate(
                package: secondPackage
            )
            failedActivationPreservedOriginal = false
        } catch let failure as BrushCompilationFailure {
            failedActivationPreservedOriginal =
                failure.stage == .pipelineSelection
                && compiler.activeBrush === first
                && compiler.cachedKeys == originalCacheKeys
                && compiler.pinnedKeys == originalPinnedKeys
                && compiler.residentByteCount == originalResidentBytes
                && context.renderer.harnessPreparedDrawBrushIdentity
                    == first.renderIdentity
        }
        let recoveredOriginalBytes = try commitOnly(
            context: context,
            brush: first,
            compositeMode: .draw,
            color: .black,
            trace: Self.disjointTrace(
                width: scene.width,
                height: scene.height,
                upper: false
            )
        )
        let originalRemainedRenderable =
            Self.hasNontransparentPixel(firstBytes)
            && Self.hasNontransparentPixel(recoveredOriginalBytes)
            && recoveredOriginalBytes != firstBytes

        let second = try await compiler.compileAndActivate(
            package: secondPackage
        )
        try context.renderer.activateDrawBrush(second)
        let inactiveWasEvicted =
            Set(compiler.cachedKeys).isDisjoint(with: firstKeys)
        let activeIsPinned =
            Set(compiler.pinnedKeys) == second.cacheKeys
        let counters = compiler.debugCounters
        let secondCacheHit = try await compiler.compileAndActivate(
            package: secondPackage
        )
        try context.renderer.activateDrawBrush(secondCacheHit)
        let churnHit = compiler.debugCounters.cacheHitCount
            > counters.cacheHitCount
        let recoveredSecondBytes = try commitOnly(
            context: context,
            brush: secondCacheHit,
            compositeMode: .draw,
            color: .black,
            trace: Self.disjointTrace(
                width: scene.width,
                height: scene.height,
                upper: true
            )
        )
        let recoveredAndUsed =
            Self.hasNontransparentPixel(recoveredSecondBytes)
            && recoveredSecondBytes != recoveredOriginalBytes
            && compiler.activeBrush === secondCacheHit
            && context.renderer.harnessPreparedDrawBrushIdentity
                == secondCacheHit.renderIdentity
        return CachePinningAudit(
            activeCompiledBrushPinned:
                firstPinned
                && inactiveWasEvicted
                && activeIsPinned
                && churnHit,
            activeBrushSurvivesPressureAndFailure:
                firstPinned
                && pressurePreservedOriginal
                && failedActivationPreservedOriginal
                && originalRemainedRenderable
                && inactiveWasEvicted
                && activeIsPinned
                && churnHit
                && recoveredAndUsed
        )
    }

    func failureMatrixAudit(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> FailureMatrixAudit {
        var passed = true
        let pipelinePassed = try await pipelineFailureIsAtomic(
            scene: scene,
            package: package
        )
        passed = pipelinePassed && passed
        passed = try await bufferFailureIsAtomic(
            scene: scene,
            package: package
        ) && passed
        passed = try await encoderFailureIsAtomic(
            scene: scene,
            package: package
        ) && passed
        passed = try await allocationFailureIsAtomic(
            scene: scene,
            package: package
        ) && passed
        passed = try await completionFailureIsAtomic(
            scene: scene,
            package: package
        ) && passed
        passed = try await revisionFailureIsAtomic(
            scene: scene,
            package: package
        ) && passed
        return FailureMatrixAudit(
            allFailuresPreservedState: passed,
            startedFromNonemptyExactHistory: passed,
            pipelineFailureUsesSeededRenderer: pipelinePassed
        )
    }

    func pipelineFailureIsAtomic(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let seeded = try await seededFailureContext(
            scene: scene,
            package: package,
            armablePipelineFailure: true
        )
        let context = seeded.context
        guard let preparer = context.pipelineFailurePreparer else {
            return false
        }
        let compilerKeys = context.compiler.cachedKeys
        let compilerPins = context.compiler.pinnedKeys
        let compilerBytes = context.compiler.residentByteCount
        preparer.armFailure()
        let failureWasAtomic: Bool
        do {
            _ = try await context.compiler.compileAndActivate(
                package: DepositionHarnessFixtures.layerPackage(
                    combination: .maximum,
                    grainCount: 1,
                    twoShapes: true
                )
            )
            return false
        } catch let failure as BrushCompilationFailure {
            let rendererSnapshot = try failureSnapshot(context.renderer)
            failureWasAtomic =
                failure.stage == .pipelineSelection
                && context.compiler.activeBrush === context.compiled
                && context.compiler.cachedKeys == compilerKeys
                && context.compiler.pinnedKeys == compilerPins
                && context.compiler.residentByteCount == compilerBytes
                && rendererSnapshot == seeded.baseline
        }
        guard failureWasAtomic else { return false }
        return try validRecovery(
            context: context,
            scene: scene,
            preservedState: seeded.baseline
        )
    }

    func bufferFailureIsAtomic(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let seeded = try await seededFailureContext(
            scene: scene,
            package: package
        )
        let context = seeded.context
        let before = seeded.baseline
        let constrainedBudget = try DepositionFrameBudget(
            cpuPreparationNanoseconds: 1_000_000,
            maximumAuthoritativeInstances: 4,
            maximumPredictedInstances: 4,
            maximumPendingAuthoritativeInstances: 4,
            maximumPendingPredictedInstances: 4,
            inFlightUploadBufferCount:
                GridCanvasContract.inFlightBufferCount
        )
        let previousBudget = context.renderer
            .replaceDepositionFrameBudgetForHarness(constrainedBudget)
        let token = RendererOperationToken(rawValue: Self.seed &+ 31)
        let trace = Self.trace(
            width: scene.width,
            height: scene.height
        )
        try context.renderer.beginStroke(
            token: token,
            sample: trace[0],
            style: Self.style(context.compiled)
        )
        do {
            // Settle the begin message before submitting the overflowing
            // mutation so the failure is actor scheduler backpressure, not
            // synchronous input-ring admission.
            try context.renderer.drainPreparedStrokeInputForHarness()
            try context.renderer.appendStroke(
                token: token,
                sample: trace[1]
            )
            try context.renderer.drainPreparedStrokeInputForHarness()
            if context.renderer.hasActiveStroke {
                try context.renderer.cancelStroke(token: token)
                try context.renderer
                    .drainStrokeWorkspaceRetirementForHarness()
            }
            _ = context.renderer.replaceDepositionFrameBudgetForHarness(
                previousBudget
            )
            return false
        } catch MetalRendererError.projectedInstanceCapacityExceeded(4) {
            try context.renderer.drainStrokeWorkspaceRetirementForHarness()
            _ = context.renderer.replaceDepositionFrameBudgetForHarness(
                previousBudget
            )
            let after = try failureSnapshot(context.renderer)
            let failureWasAtomic = context.renderer.isIdle
                && before == after
            let recovered = try validRecovery(
                context: context,
                scene: scene,
                preservedState: before
            )
            return failureWasAtomic && recovered
        } catch {
            if context.renderer.hasActiveStroke {
                try? context.renderer.cancelStroke(token: token)
            }
            try? context.renderer.drainStrokeWorkspaceRetirementForHarness()
            _ = context.renderer.replaceDepositionFrameBudgetForHarness(
                previousBudget
            )
            throw error
        }
    }

    func encoderFailureIsAtomic(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let seeded = try await seededFailureContext(
            scene: scene,
            package: package
        )
        let context = seeded.context
        let before = seeded.baseline
        let token = RendererOperationToken(rawValue: Self.seed &+ 32)
        context.renderer.setForceOffMainStrokeCommandFailureForTesting(
            true
        )
        try context.renderer.beginStroke(
            token: token,
            sample: Self.trace(
                width: scene.width,
                height: scene.height
            )[0],
            style: Self.style(context.compiled)
        )
        do {
            try context.renderer.drainPreparedStrokeInputForHarness()
            if context.renderer.hasActiveStroke {
                try context.renderer.cancelStroke(token: token)
                try context.renderer
                    .drainStrokeWorkspaceRetirementForHarness()
            }
            context.renderer
                .setForceOffMainStrokeCommandFailureForTesting(false)
            return false
        } catch MetalRendererError.commandFailed {
            try context.renderer.drainStrokeWorkspaceRetirementForHarness()
            context.renderer
                .setForceOffMainStrokeCommandFailureForTesting(false)
            let after = try failureSnapshot(context.renderer)
            let failureWasAtomic = context.renderer.isIdle
                && before == after
            let recovered = try validRecovery(
                context: context,
                scene: scene,
                preservedState: before
            )
            return failureWasAtomic && recovered
        } catch {
            if context.renderer.hasActiveStroke {
                try? context.renderer.cancelStroke(token: token)
            }
            try? context.renderer.drainStrokeWorkspaceRetirementForHarness()
            if context.renderer.isIdle {
                context.renderer
                    .setForceOffMainStrokeCommandFailureForTesting(false)
            }
            throw error
        }
    }

    func allocationFailureIsAtomic(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let seeded = try await seededFailureContext(
            scene: scene,
            package: package
        )
        let context = seeded.context
        let before = seeded.baseline
        do {
            try context.renderer.requestResizeForHarness(
                token: RendererOperationToken(
                    rawValue: Self.seed &+ 33
                ),
                to: PixelSize(
                    width: scene.width + 1,
                    height: scene.height
                ),
                maximumRetainedBytes: 64 * 1_024 * 1_024,
                forceResourceAllocationFailure: true
            )
            return false
        } catch MetalRendererError.textureAllocationFailed {
            let after = try failureSnapshot(context.renderer)
            let failureWasAtomic = context.renderer.isIdle
                && before == after
            let recovered = try validRecovery(
                context: context,
                scene: scene,
                preservedState: before
            )
            return failureWasAtomic && recovered
        }
    }

    func completionFailureIsAtomic(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let seeded = try await seededFailureContext(
            scene: scene,
            package: package
        )
        let context = seeded.context
        let before = seeded.baseline
        let token = RendererOperationToken(rawValue: Self.seed &+ 34)
        var completions: [RendererOperationCompletion] = []
        context.renderer.onOperationCompleted = {
            completions.append($0)
        }
        try context.renderer.beginStroke(
            token: token,
            sample: Self.trace(
                width: scene.width,
                height: scene.height
            )[0],
            style: Self.style(context.compiled)
        )
        do {
            try context.renderer.preparePendingLiveSurfaceForHarness()
            _ = try context.renderer.flushPendingLiveForHarness(
                forceFailure: true
            )
            return false
        } catch MetalRendererError.commandFailed {
            try context.renderer.drainStrokeWorkspaceRetirementForHarness()
            let oneFailure = completions.filter {
                if case let .failure(value, _) = $0 {
                    return value == token
                }
                return false
            }.count == 1
            let after = try failureSnapshot(context.renderer)
            let failureWasAtomic = oneFailure
                && context.renderer.isIdle
                && before == after
            let recovered = try validRecovery(
                context: context,
                scene: scene,
                preservedState: before
            )
            return failureWasAtomic && recovered
        }
    }

    func revisionFailureIsAtomic(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let seeded = try await seededFailureContext(
            scene: scene,
            package: package
        )
        let context = seeded.context
        let before = seeded.baseline
        let token = RendererOperationToken(rawValue: Self.seed &+ 35)
        let trace = Self.trace(width: scene.width, height: scene.height)
        try context.renderer.beginStroke(
            token: token,
            sample: trace[0],
            style: Self.style(context.compiled)
        )
        try context.renderer.requestStrokeCommit(
            token: token,
            sample: trace.last!,
            maximumRetainedBytes: 0
        )
        do {
            _ = try context.renderer.finishCommitForHarness()
            return false
        } catch MetalRendererError.rasterRevisionStorageLimitExceeded {
            let after = try failureSnapshot(context.renderer)
            let failureWasAtomic = context.renderer.isIdle
                && before == after
            let recovered = try validRecovery(
                context: context,
                scene: scene,
                preservedState: before
            )
            return failureWasAtomic && recovered
        }
    }

    func failureSnapshot(_ renderer: GridRenderer) throws
        -> RendererFailureSnapshot
    {
        RendererFailureSnapshot(
            canonicalBytes: Self.textureBytes(
                try renderer.copyCanonicalForHarness()
            ),
            revision: renderer.harnessRevision,
            historyResidentBytes:
                renderer.harnessRasterRevisionResidentBytes,
            historySnapshots:
                try renderer.harnessRasterRevisionSnapshots,
            isIdle: renderer.isIdle,
            hasActiveStroke: renderer.hasActiveStroke,
            preparedDrawBrushIdentity:
                renderer.harnessPreparedDrawBrushIdentity,
            preparedEraserBrushIdentity:
                renderer.harnessPreparedEraserBrushIdentity,
            capturedCompiledBrushIdentity:
                renderer.harnessCapturedCompiledBrushIdentity,
            reservedInstanceBufferCount:
                renderer.harnessReservedInstanceBufferCount,
            scheduledAuthoritativeRecords:
                renderer.harnessScheduledAuthoritativeRecords,
            scheduledPredictedRecords:
                renderer.harnessScheduledPredictedRecords,
            pendingInstanceColors:
                renderer.harnessPendingInstanceColors
        )
    }

    func validRecovery(
        context: Context,
        scene: HarnessScene,
        preservedState: RendererFailureSnapshot
    ) throws
        -> Bool
    {
        let bytes = try commitOnly(
            context: context,
            brush: context.compiled,
            compositeMode: .draw,
            color: .black,
            trace: Self.disjointTrace(
                width: scene.width,
                height: scene.height,
                upper: false
            )
        )
        let historySnapshots =
            try context.renderer.harnessRasterRevisionSnapshots
        return Self.hasNontransparentPixel(bytes)
            && bytes != preservedState.canonicalBytes
            && context.renderer.harnessRevision
                != preservedState.revision
            && context.renderer.isIdle
            && context.renderer.harnessReservedInstanceBufferCount == 0
            && context.renderer.harnessScheduledAuthoritativeRecords.isEmpty
            && context.renderer.harnessScheduledPredictedRecords.isEmpty
            && context.renderer.harnessPendingInstanceColors.isEmpty
            && historySnapshots == preservedState.historySnapshots
    }
}

private struct RendererFailureSnapshot: Equatable {
    let canonicalBytes: [UInt8]
    let revision: RasterRevision
    let historyResidentBytes: Int
    let historySnapshots: [RasterRevisionHarnessSnapshot]
    let isIdle: Bool
    let hasActiveStroke: Bool
    let preparedDrawBrushIdentity: BrushRenderIdentity?
    let preparedEraserBrushIdentity: BrushRenderIdentity?
    let capturedCompiledBrushIdentity: BrushRenderIdentity?
    let reservedInstanceBufferCount: Int
    let scheduledAuthoritativeRecords: [ProjectedDepositionRecord]
    let scheduledPredictedRecords: [ProjectedDepositionRecord]
    let pendingInstanceColors: [SIMD4<Float>]
}

@MainActor
private final class ArmableDepositionPipelinePreparer:
    DepositionPipelinePreparing
{
    private let delegate: any DepositionPipelinePreparing
    private var shouldFailNext = false

    init(delegate: any DepositionPipelinePreparing) {
        self.delegate = delegate
    }

    func armFailure() {
        shouldFailNext = true
    }

    func prepare(
        for key: DepositionPipelineKey
    ) async throws -> DepositionPipelineBinding {
        if shouldFailNext {
            shouldFailNext = false
            throw DepositionPipelineLibraryError.pipelineCreationFailed(
                "injected deposition harness pipeline failure"
            )
        }
        return try await delegate.prepare(for: key)
    }
}

private extension DepositionHarnessRunner {
    func symmetryOrderIsEqual(
        records: [ProjectedDepositionRecord],
        compiled: CompiledBrush,
        width: Int,
        height: Int
    ) throws -> Bool {
        guard let identity = records.first?.identity else { return false }
        let projections = records.filter { $0.identity == identity }
        let comparison: [ProjectedDepositionRecord]
        if projections.count > 1 {
            comparison = projections
        } else if let first = records.first,
                  let farthest = records.dropFirst().max(by: {
                      Self.squaredDistance(from: first, to: $0)
                          < Self.squaredDistance(from: first, to: $1)
                  })
        {
            comparison = [first, farthest]
        } else {
            comparison = []
        }
        guard comparison.count > 1 else { return false }
        let forward = try directlyEncodedBytes(
            records: comparison,
            compiled: compiled,
            width: width,
            height: height
        )
        let reverse = try directlyEncodedBytes(
            records: comparison.reversed(),
            compiled: compiled,
            width: width,
            height: height
        )
        return forward == reverse
    }

    static func squaredDistance(
        from lhs: ProjectedDepositionRecord,
        to rhs: ProjectedDepositionRecord
    ) -> Float {
        let lhsCenter = SIMD2(
            lhs.instance.tipFrame1.x,
            lhs.instance.tipFrame1.y
        )
        let rhsCenter = SIMD2(
            rhs.instance.tipFrame1.x,
            rhs.instance.tipFrame1.y
        )
        let delta = lhsCenter - rhsCenter
        return simd_length_squared(delta)
    }

    func directlyEncodedBytes<S: Sequence>(
        records: S,
        compiled: CompiledBrush,
        width: Int,
        height: Int
    ) throws -> [UInt8] where S.Element == ProjectedDepositionRecord {
        let values = Array(records)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer()
        else {
            throw DepositionHarnessRunError.metalResourceUnavailable(
                "a direct-encoding target"
            )
        }
        let empty = [UInt8](
            repeating: 0,
            count: width * height * 4
        )
        target.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: empty,
            bytesPerRow: width * 4
        )
        let pool = try DabInstanceBufferPool(device: device)
        var encoder = DepositionEncoder(
            instancePool: pool,
            frameUniforms: Self.frameUniforms(
                width: width,
                height: height
            )
        )
        let prepared = try encoder.preflight(
            records: values,
            binding: compiled.depositionPipeline,
            material: compiled.depositionMaterial,
            target: target
        )
        _ = try encoder.encode(
            prepared,
            into: target,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw DepositionHarnessRunError.metalResourceUnavailable(
                "a completed direct-encoding command"
            )
        }
        return Self.textureBytes(target)
    }

    static func hardRoundCPUReference(
        records: [ProjectedDepositionRecord],
        material: DepositionMaterialBinding,
        width: Int,
        height: Int
    ) -> [UInt8] {
        var pixels = [SIMD4<Float>](
            repeating: .zero,
            count: width * height
        )
        let uniforms = material.uniforms
        let referenceMaterial = DepositionReferenceMaterial(
            secondaryShapeCombination: nil,
            primaryGrainStrength: nil,
            secondaryGrainStrength: nil,
            tipThreshold: uniforms.coverageParameters.z,
            antialiasing: uniforms.options.y != 0,
            accumulationMode: .flow,
            edgeTreatment: .none,
            materialStrength: uniforms.edgeParameters.x,
            accumulationLimit: uniforms.coverageParameters.w
        )
        for record in records where record.instance.metadata.w
                == UInt32(DepositionABI.version)
        {
            let instance = record.instance
            let frame = instance.tipFrame0
            let determinant =
                frame.x * frame.w - frame.y * frame.z
            guard abs(determinant) >= Float.ulpOfOne else { continue }
            for y in 0..<height {
                for x in 0..<width {
                    let relative = SIMD2<Float>(
                        Float(x) + 0.5 - instance.tipFrame1.x,
                        Float(y) + 0.5 - instance.tipFrame1.y
                    )
                    let local = SIMD2<Float>(
                        (
                            relative.x * frame.w
                                - relative.y * frame.z
                        ) / determinant,
                        (
                            frame.x * relative.y
                                - frame.y * relative.x
                        ) / determinant
                    )
                    guard Self.insideClips(
                        local,
                        instance: instance
                    ) else {
                        continue
                    }
                    let radius = instance.tipFrame1.z
                    let shape = min(
                        1,
                        max(0, radius + 0.5 - simd_length(local * radius))
                    )
                    let coverage = DepositionReference.coverage(
                        samples: DepositionCoverageSamples(
                            primaryShape: shape,
                            secondaryShape: nil,
                            primaryGrain: nil,
                            secondaryGrain: nil,
                            signedTipEdgeDistance:
                                radius * (1 - simd_length(local))
                        ),
                        instance: instance,
                        material: referenceMaterial
                    )
                    let deposited = min(
                        uniforms.coverageParameters.w,
                        coverage
                            * min(
                                1,
                                max(0, instance.coverageInputs.y)
                            )
                    )
                    let source =
                        instance.premultipliedColor * deposited
                    let index = y * width + x
                    pixels[index] =
                        source + pixels[index] * (1 - source.w)
                }
            }
        }
        return pixels.flatMap { pixel in
            [
                UInt8(clamping: Int((pixel.z * 255).rounded())),
                UInt8(clamping: Int((pixel.y * 255).rounded())),
                UInt8(clamping: Int((pixel.x * 255).rounded())),
                UInt8(clamping: Int((pixel.w * 255).rounded())),
            ]
        }
    }

    static func insideClips(
        _ local: SIMD2<Float>,
        instance: PatternDepositionStampInstance
    ) -> Bool {
        let clips = [
            instance.clip0,
            instance.clip1,
            instance.clip2,
            instance.clip3,
        ]
        return clips.prefix(Int(instance.metadata.x)).allSatisfy {
            simd_dot($0.normal, local) >= $0.offset
        }
    }

    static func frameUniforms(
        width: Int,
        height: Int
    ) -> PatternGridFrameUniforms {
        PatternGridFrameUniforms(
            drawableSize: SIMD2(Float(width), Float(height)),
            worldCenter: SIMD2(Float(width) * 0.5, Float(height) * 0.5),
            tileSize: SIMD2(Float(width), Float(height)),
            zoom: 1,
            gridLineWidth: 0,
            showGridLines: 0,
            liveVisible: 1,
            tilingKind: TilingKind.grid.rawValue,
            diagnosticMode: 0,
            compositeMode: PatternCompositeWireDraw,
            symmetryFamily: 0,
            repeatSize: SIMD2(Float(width), Float(height)),
            latticeXAxis: SIMD2(1, 0),
            latticeYAxis: SIMD2(0, 1),
            latticeTranslation: .zero,
            guideKind: 0,
            showCanvasBoundary: 0
        )
    }
}

private extension DepositionHarnessRunner {
    static func disjointTrace(
        width: Int,
        height: Int,
        upper: Bool
    ) -> [StrokeSample] {
        let normalized: [SIMD2<Float>] = upper
            ? [
                SIMD2(0.60, 0.16),
                SIMD2(0.66, 0.18),
                SIMD2(0.72, 0.20),
                SIMD2(0.78, 0.22),
                SIMD2(0.84, 0.24),
            ]
            : [
                SIMD2(0.16, 0.76),
                SIMD2(0.21, 0.78),
                SIMD2(0.26, 0.80),
                SIMD2(0.31, 0.82),
                SIMD2(0.36, 0.84),
            ]
        let points = normalized.map {
            SIMD2($0.x * Float(width), $0.y * Float(height))
        }
        return [
            sample(
                x: points[0].x,
                y: points[0].y,
                pressure: 0.45,
                timestamp: 0,
                phase: .began
            ),
            sample(
                x: points[1].x,
                y: points[1].y,
                pressure: 0.58,
                timestamp: 0.01,
                phase: .moved
            ),
            sample(
                x: points[2].x,
                y: points[2].y,
                pressure: 0.72,
                timestamp: 0.02,
                phase: .moved
            ),
            sample(
                x: points[3].x,
                y: points[3].y,
                pressure: 0.64,
                timestamp: 0.03,
                phase: .moved
            ),
            sample(
                x: points[4].x,
                y: points[4].y,
                pressure: 0.70,
                timestamp: 0.04,
                phase: .ended
            ),
        ]
    }

    static func trace(
        width: Int,
        height: Int,
        screenScale: Float = 1
    ) -> [StrokeSample] {
        let center = SIMD2(Float(width) * 0.5, Float(height) * 0.5)
        let world = [
            SIMD2(Float(width) * 0.25, Float(height) * 0.38),
            SIMD2(Float(width) * 0.38, Float(height) * 0.44),
            SIMD2(Float(width) * 0.52, Float(height) * 0.50),
            SIMD2(Float(width) * 0.66, Float(height) * 0.57),
            SIMD2(Float(width) * 0.75, Float(height) * 0.62),
        ]
        let screen = world.map { center + ($0 - center) * screenScale }
        return [
            sample(
                x: screen[0].x,
                y: screen[0].y,
                pressure: 0.35,
                timestamp: 0,
                phase: .began
            ),
            sample(
                x: screen[1].x,
                y: screen[1].y,
                pressure: 0.55,
                timestamp: 0.01,
                phase: .moved
            ),
            sample(
                x: screen[2].x,
                y: screen[2].y,
                pressure: 0.8,
                timestamp: 0.02,
                phase: .moved
            ),
            sample(
                x: screen[3].x,
                y: screen[3].y,
                pressure: 0.62,
                timestamp: 0.03,
                phase: .moved
            ),
            sample(
                x: screen[4].x,
                y: screen[4].y,
                pressure: 0.72,
                timestamp: 0.04,
                phase: .moved
            ),
            sample(
                x: screen[4].x,
                y: screen[4].y,
                pressure: 0.72,
                timestamp: 0.05,
                phase: .ended
            ),
        ]
    }

    static func sample(
        x: Float,
        y: Float,
        pressure: Float,
        timestamp: TimeInterval,
        phase: StrokePhase,
        kind: StrokeSampleKind = .actual
    ) -> StrokeSample {
        StrokeSample(
            position: ScreenPoint(x: x, y: y),
            pressure: pressure,
            timestamp: timestamp,
            phase: phase,
            source: .pencil,
            kind: kind,
            capabilities: [.pressure]
        )
    }

    static func translated(
        _ sample: StrokeSample,
        dx: Float,
        dy: Float = 0
    ) -> StrokeSample {
        repositioned(
            sample,
            x: sample.position.x + dx,
            y: sample.position.y + dy
        )
    }

    static func repositioned(
        _ sample: StrokeSample,
        x: Float,
        y: Float
    ) -> StrokeSample {
        StrokeSample(
            position: ScreenPoint(
                x: x,
                y: y
            ),
            pressure: sample.pressure,
            timestamp: sample.timestamp,
            phase: sample.phase,
            source: sample.source,
            kind: sample.kind,
            capabilities: sample.capabilities,
            altitude: sample.altitude,
            azimuth: sample.azimuth,
            roll: sample.roll,
            tangentialPressure: sample.tangentialPressure,
            deviceIdentifier: sample.deviceIdentifier,
            estimationUpdateIndex: sample.estimationUpdateIndex,
            estimatedProperties: sample.estimatedProperties,
            estimatedPropertiesExpectingUpdates:
                sample.estimatedPropertiesExpectingUpdates
        )
    }

    static func style(_ brush: CompiledBrush) -> StrokeRenderStyle {
        StrokeRenderStyle(
            color: .black,
            diameter: 22,
            compositeMode: .draw,
            eraserStrength: 1,
            program: brush.program,
            renderIdentity: brush.renderIdentity,
            seed: seed
        )
    }

    static func pipelineDescription(
        _ key: DepositionPipelineKey
    ) -> String {
        let constants = key.brush.functionConstants
        return [
            key.brush.backend.rawValue,
            key.brush.accumulation.rawValue,
            key.brush.edgeTreatment.rawValue,
            constants.usesSecondaryShape ? "s1" : "s0",
            constants.usesGrain ? "g1" : "g0",
            constants.usesSecondaryGrain ? "h1" : "h0",
            constants.usesDestinationSampling ? "d1" : "d0",
            "abi\(key.abiVersion)",
            "format\(key.colorPixelFormatRawValue)",
            "samples\(key.sampleCount)",
        ].joined(separator: ":")
    }

    static func textureBytes(_ texture: any MTLTexture) -> [UInt8] {
        precondition(texture.pixelFormat == .bgra8Unorm)
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count: bytesPerRow * texture.height
        )
        bytes.withUnsafeMutableBytes { storage in
            texture.getBytes(
                storage.baseAddress!,
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

    static func maximumChannelDelta(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> UInt8 {
        guard lhs.count == rhs.count else { return .max }
        return zip(lhs, rhs).reduce(0) {
            max(
                $0,
                UInt8(abs(Int($1.0) - Int($1.1)))
            )
        }
    }

    static func hasNontransparentPixel(_ bytes: [UInt8]) -> Bool {
        stride(from: 3, to: bytes.count, by: 4).contains {
            bytes[$0] != 0
        }
    }

    static func nontransparentPixelCount(_ bytes: [UInt8]) -> Int {
        stride(from: 3, to: bytes.count, by: 4).reduce(0) {
            $0 + (bytes[$1] == 0 ? 0 : 1)
        }
    }

    static func sha256(_ bytes: [UInt8]) -> String {
        ProfessionalBrushEvidenceValidator.sha256(Data(bytes))
    }

    static func runningExecutableSHA256() throws -> String {
        guard let argument = CommandLine.arguments.first else {
            throw DepositionHarnessRunError.metalResourceUnavailable(
                "the running executable identity"
            )
        }
        let url = URL(fileURLWithPath: argument)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return ProfessionalBrushEvidenceValidator.sha256(
            try Data(contentsOf: url)
        )
    }

    static func reducedAlphaPixelCount(
        before: [UInt8],
        after: [UInt8]
    ) -> Int {
        guard before.count == after.count else { return 0 }
        return stride(from: 3, to: before.count, by: 4).reduce(0) {
            $0 + (before[$1] > after[$1] ? 1 : 0)
        }
    }

    enum HalfTurnOrReflection {
        case rotateHalfTurn
        case reflectVertically
    }

    static func mergedWithTransformedCopy(
        _ source: [UInt8],
        width: Int,
        height: Int,
        transform: HalfTurnOrReflection
    ) -> [UInt8] {
        precondition(source.count == width * height * 4)
        var result = source
        for y in 0..<height {
            for x in 0..<width {
                let transformedX: Int
                let transformedY: Int
                switch transform {
                case .rotateHalfTurn:
                    transformedX = width - 1 - x
                    transformedY = height - 1 - y
                case .reflectVertically:
                    transformedX = x
                    transformedY = height - 1 - y
                }
                let sourceIndex = (y * width + x) * 4
                let destinationIndex =
                    (transformedY * width + transformedX) * 4
                for channel in 0..<3 {
                    result[destinationIndex + channel] = min(
                        result[destinationIndex + channel],
                        source[sourceIndex + channel]
                    )
                }
                result[destinationIndex + 3] = max(
                    result[destinationIndex + 3],
                    source[sourceIndex + 3]
                )
            }
        }
        return result
    }

    static func professionalRadialTrace(
        width: Int,
        height: Int
    ) -> [StrokeSample] {
        let y = Float(height) * 0.32
        return [
            sample(
                x: Float(width) * 0.28,
                y: y,
                pressure: 0.8,
                timestamp: 0,
                phase: .began
            ),
            sample(
                x: Float(width) * 0.72,
                y: y,
                pressure: 0.8,
                timestamp: 0.01,
                phase: .moved
            ),
            sample(
                x: Float(width) * 0.72,
                y: y,
                pressure: 0.8,
                timestamp: 0.02,
                phase: .ended
            ),
        ]
    }

    static func expectedMipProbeAlpha(
        decoded: DecodedBrushTexture,
        diameter: Float
    ) -> UInt8 {
        let maximumLevel = decoded.mipLevels.count - 1
        let lod = max(
            0,
            min(Float(maximumLevel), log2(Float(decoded.workingWidth) / diameter))
        )
        let lowerLevel = Int(floor(lod))
        let upperLevel = min(maximumLevel, lowerLevel + 1)
        let fraction = lod - Float(lowerLevel)
        let lower = mipCenterSample(
            decoded.mipLevels[lowerLevel],
            width: max(1, decoded.workingWidth >> lowerLevel),
            height: max(1, decoded.workingHeight >> lowerLevel)
        )
        let upper = mipCenterSample(
            decoded.mipLevels[upperLevel],
            width: max(1, decoded.workingWidth >> upperLevel),
            height: max(1, decoded.workingHeight >> upperLevel)
        )
        let coverage = min(0.9, lower + (upper - lower) * fraction)
        return UInt8(clamping: Int((coverage * 255).rounded()))
    }

    static func mipCenterSample(
        _ data: Data,
        width: Int,
        height: Int
    ) -> Float {
        let bytes = [UInt8](data)
        let x0 = max(0, (width - 1) / 2)
        let x1 = min(width - 1, width / 2)
        let y0 = max(0, (height - 1) / 2)
        let y1 = min(height - 1, height / 2)
        let sum = [
            bytes[y0 * width + x0],
            bytes[y0 * width + x1],
            bytes[y1 * width + x0],
            bytes[y1 * width + x1],
        ].reduce(0) { $0 + Int($1) }
        return Float(sum) / (4 * 255)
    }

    static func benchmark(
        scene: HarnessScene,
        build: BenchmarkBuild,
        device: any MTLDevice,
        capture: StrokeCapture,
        evidence: DepositionSceneEvidence
    ) -> BenchmarkRecord {
        let process = ProcessInfo.processInfo
        let metrics = [capture.flushMetrics, capture.commitMetrics]
            + capture.displayMetrics
        return BenchmarkRecord(
            schemaVersion: 3,
            timestampUTC: "1970-01-01T00:00:00Z",
            sceneName: scene.name,
            hardware: BenchmarkHardware(
                gpuName: device.name,
                logicalProcessorCount: process.activeProcessorCount,
                physicalMemoryBytes: process.physicalMemory
            ),
            operatingSystem: process.operatingSystemVersionString,
            build: build,
            frameCount: metrics.count,
            cpuEncodeMilliseconds: metrics.map(
                \.cpuEncodeMilliseconds
            ),
            gpuMilliseconds: metrics.map(\.gpuMilliseconds),
            peakResidentBytes: UInt64(evidence.resourceBytes),
            newInstanceCounts: [evidence.projectedInstanceCount],
            totalProjectedFragmentCount:
                evidence.projectedInstanceCount,
            totalInstanceBytes:
                evidence.projectedInstanceCount
                    * ShaderABI.depositionStampInstanceStride,
            previewCommitViolationCount:
                evidence.previewCommitMaximumChannelDelta > 1 ? 1 : 0,
            recipeID: evidence.definitionID,
            seed: seed,
            assetResidentBytes: evidence.resourceBytes,
            logicalDabDigest: evidence.canonicalSHA256,
            canonicalBGRA8Digest: evidence.canonicalSHA256,
            logicalDabCount: evidence.logicalDabCount,
            program: "nativeDeposition"
        )
    }

    static func professionalBenchmark(
        scene: HarnessScene,
        build: BenchmarkBuild,
        device: any MTLDevice,
        capture: StrokeCapture,
        evidence: ProfessionalBrushSceneEvidence,
        characterization: ProfessionalBrushCharacterizationRecord
    ) -> BenchmarkRecord {
        let process = ProcessInfo.processInfo
        let metrics = [capture.flushMetrics, capture.commitMetrics]
            + capture.displayMetrics
        return BenchmarkRecord(
            schemaVersion: 3,
            timestampUTC: "1970-01-01T00:00:00Z",
            sceneName: scene.name,
            hardware: BenchmarkHardware(
                gpuName: device.name,
                logicalProcessorCount: process.activeProcessorCount,
                physicalMemoryBytes: process.physicalMemory
            ),
            operatingSystem: process.operatingSystemVersionString,
            build: build,
            frameCount: metrics.count,
            cpuEncodeMilliseconds: metrics.map(
                \.cpuEncodeMilliseconds
            ),
            gpuMilliseconds: metrics.map(\.gpuMilliseconds),
            peakResidentBytes: UInt64(evidence.residentResourceBytes),
            newInstanceCounts: [evidence.projectedInstanceCount],
            missedFrameCount: Int(evidence.telemetry.missedFrameCount),
            totalProjectedFragmentCount:
                evidence.projectedInstanceCount,
            totalInstanceBytes:
                evidence.projectedInstanceCount
                    * ShaderABI.depositionStampInstanceStride,
            previewCommitViolationCount:
                evidence.previewCommitMaximumChannelDelta > 1 ? 1 : 0,
            recipeID: evidence.definitionID,
            seed: seed,
            replayMode: "replayTail",
            assetResidentBytes: evidence.residentResourceBytes,
            logicalDabDigest: characterization.logicalDabDigest,
            canonicalBGRA8Digest: DepositionSceneEvidence.sha256(
                Self.textureBytes(capture.canonical)
            ),
            logicalDabCount: evidence.logicalDabCount,
            program: "professionalNativeDeposition"
        )
    }

    static func writePNGAtomically(
        _ texture: any MTLTexture,
        to url: URL
    ) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try PNGWriter.write(texture: texture, to: temporary)
        try installAtomically(temporary, at: url)
    }

    static func writePNGAtomically(
        bgra: [UInt8],
        pixelSize: PixelSize,
        to url: URL
    ) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try PNGWriter.writeBGRA(
            bgra,
            pixelSize: pixelSize,
            to: temporary
        )
        try installAtomically(temporary, at: url)
    }

    static func installAtomically(_ temporary: URL, at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(
                url,
                withItemAt: temporary
            )
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}

private enum DepositionHarnessFixtures {
    static let customGrainID = "custom.asymmetric.grain"
    static let customShapeID = "custom.asymmetric.shape"

    struct ExpectedPipeline {
        let definitionID: String
        let accumulation: BrushAccumulationMode
        let edge: BrushEdgeTreatment
        let shape: BrushShapeDescriptor
        let flow: Float
    }

    static func expectedPipeline(
        for stem: String
    ) -> ExpectedPipeline? {
        switch stem {
        case "deposition-ink":
            ExpectedPipeline(
                definitionID: "builtin.native-ink",
                accumulation: .flow,
                edge: .none,
                shape: .hardRound,
                flow: 0.82
            )
        case "deposition-dry":
            ExpectedPipeline(
                definitionID: "builtin.native-dry-media",
                accumulation: .flow,
                edge: .dryBreakup,
                shape: .hardRound,
                flow: 0.68
            )
        case "deposition-glaze":
            ExpectedPipeline(
                definitionID: "builtin.native-glaze",
                accumulation: .uniformGlaze,
                edge: .none,
                shape: .softRound,
                flow: 0.55
            )
        case "deposition-marker":
            ExpectedPipeline(
                definitionID: "builtin.native-marker",
                accumulation: .uniformGlaze,
                edge: .markerOverlap,
                shape: .chisel,
                flow: 0.65
            )
        case "deposition-airbrush":
            ExpectedPipeline(
                definitionID: "builtin.native-airbrush",
                accumulation: .flow,
                edge: .none,
                shape: .softRound,
                flow: 0.3
            )
        case "deposition-erase":
            ExpectedPipeline(
                definitionID: "builtin.native-eraser",
                accumulation: .destinationOut,
                edge: .none,
                shape: .hardRound,
                flow: 1
            )
        default:
            nil
        }
    }

    static func package(for stem: String) throws -> BrushPackage {
        switch stem {
        case "deposition-ink",
             "deposition-dry",
             "deposition-glaze",
             "deposition-marker",
             "deposition-airbrush",
             "deposition-erase":
            throw DepositionHarnessRunError.invariantFailed(
                scene: stem,
                invariant: "productionAnchorDefinitionInjected"
            )
        case "deposition-custom-asymmetric",
             "deposition-periodic-seams",
             "deposition-radial-reflection":
            try customPackage(id: "\(stem).brush")
        case "deposition-layer-matrix":
            try layerPackage(
                combination: .multiply,
                grainCount: 2,
                twoShapes: true
            )
        case "deposition-stamp-size-mips":
            try mipProbePackage()
        case "deposition-kinematics",
             "deposition-prediction",
             "deposition-preview-commit",
             "deposition-cache-pinning",
             "deposition-failure-matrix":
            try builtInPackage(
                id: "\(stem).brush",
                name: stem,
                shape: .hardRound,
                grains: [],
                flow: 0.75,
                hardness: 0.88,
                aspect: 1,
                accumulation: .flow,
                edge: .none
            )
        default:
            throw DepositionHarnessRunError.unknownScene(stem)
        }
    }

    static func layerPackage(
        combination: BrushShapeCombinationMode,
        grainCount: Int,
        twoShapes: Bool
    ) throws -> BrushPackage {
        let primaryShapeID = "matrix.primary.shape"
        let secondaryShapeID = "matrix.secondary.shape"
        let primaryGrainID = "matrix.primary.grain"
        let secondaryGrainID = "matrix.secondary.grain"
        let primaryShapeData = try asymmetricPNG(seed: 17)
        let secondaryShapeData = try asymmetricPNG(seed: 53)
        let primaryGrainData = try asymmetricPNG(seed: 107)
        let secondaryGrainData = try asymmetricPNG(seed: 211)
        var manifestResources: [BrushPackageResource] = []
        var resourceReferences: [BrushResourceReference] = []
        var resourceData: [String: Data] = [:]
        let primaryShapeResource = try BrushPackageResource(
            id: primaryShapeID,
            kind: .shape,
            mediaType: "image/png",
            data: primaryShapeData,
            pixelWidth: 64,
            pixelHeight: 64
        )
        manifestResources.append(primaryShapeResource)
        resourceReferences.append(
            BrushResourceReference(
                identifier: primaryShapeID,
                kind: .shape,
                required: true,
                fallback: nil
            )
        )
        resourceData[primaryShapeID] = primaryShapeData
        if twoShapes {
            let resource = try BrushPackageResource(
                id: secondaryShapeID,
                kind: .shape,
                mediaType: "image/png",
                data: secondaryShapeData,
                pixelWidth: 64,
                pixelHeight: 64
            )
            manifestResources.append(resource)
            resourceReferences.append(
                BrushResourceReference(
                    identifier: secondaryShapeID,
                    kind: .shape,
                    required: true,
                    fallback: nil
                )
            )
            resourceData[secondaryShapeID] = secondaryShapeData
        }
        if grainCount > 0 {
            let resource = try BrushPackageResource(
                id: primaryGrainID,
                kind: .grain,
                mediaType: "image/png",
                data: primaryGrainData,
                pixelWidth: 64,
                pixelHeight: 64
            )
            manifestResources.append(resource)
            resourceReferences.append(
                BrushResourceReference(
                    identifier: primaryGrainID,
                    kind: .grain,
                    required: true,
                    fallback: nil
                )
            )
            resourceData[primaryGrainID] = primaryGrainData
        }
        if grainCount > 1 {
            let resource = try BrushPackageResource(
                id: secondaryGrainID,
                kind: .grain,
                mediaType: "image/png",
                data: secondaryGrainData,
                pixelWidth: 64,
                pixelHeight: 64
            )
            manifestResources.append(resource)
            resourceReferences.append(
                BrushResourceReference(
                    identifier: secondaryGrainID,
                    kind: .grain,
                    required: true,
                    fallback: nil
                )
            )
            resourceData[secondaryGrainID] = secondaryGrainData
        }
        let secondary: [BrushShapeLayerDefinition] = twoShapes
            ? [
                BrushShapeLayerDefinition(
                    shape: .asset(secondaryShapeID),
                    combination: combination,
                    scale: 0.72,
                    rotation: 0.37,
                    offset: SIMD2(0.12, -0.08)
                ),
            ]
            : []
        let grains = [
            grain(.asset(primaryGrainID), strength: 0.55),
            grain(.asset(secondaryGrainID), strength: 0.35),
        ]
        manifestResources.sort { $0.id < $1.id }
        resourceReferences.sort { $0.identifier < $1.identifier }
        let definition = try definition(
            id:
                "evidence.layer-\(combination.rawValue)-\(grainCount)-\(twoShapes)",
            name: "Native Layer Matrix",
            resources: resourceReferences,
            shapes: [
                BrushShapeLayerDefinition(
                    shape: .asset(primaryShapeID),
                    combination: .replace,
                    scale: 1,
                    rotation: 0,
                    offset: .zero
                ),
            ] + secondary,
            grains: Array(grains.prefix(grainCount)),
            flow: 0.7,
            hardness: 0.75,
            aspect: 0.82,
            accumulation: .flow,
            edge: .none
        )
        return try BrushPackage(
            manifest: BrushPackageManifest(resources: manifestResources),
            definition: definition,
            resourceData: resourceData
        )
    }

    static func cachePackage(index: Int) throws -> BrushPackage {
        let id = "cache.resource.\(index)"
        let data = try asymmetricPNG(seed: UInt8(index * 31))
        let resource = try BrushPackageResource(
            id: id,
            kind: .shape,
            mediaType: "image/png",
            data: data,
            pixelWidth: 64,
            pixelHeight: 64
        )
        let definition = try definition(
            id: "evidence.cache.\(index)",
            name: "Cache \(index)",
            resources: [
                BrushResourceReference(
                    identifier: id,
                    kind: .shape,
                    required: true,
                    fallback: nil
                ),
            ],
            shapes: [
                BrushShapeLayerDefinition(
                    shape: .asset(id),
                    combination: .replace,
                    scale: 1,
                    rotation: 0,
                    offset: .zero
                ),
            ],
            grains: [],
            flow: 0.8,
            hardness: 0.8,
            aspect: 1,
            accumulation: .flow,
            edge: .none
        )
        return try BrushPackage(
            manifest: BrushPackageManifest(resources: [resource]),
            definition: definition,
            resourceData: [id: data]
        )
    }

    private static func customPackage(id: String) throws -> BrushPackage {
        let shapeData = try asymmetricPNG(seed: 41)
        let grainData = try asymmetricPNG(seed: 173)
        let resources = try [
            BrushPackageResource(
                id: customGrainID,
                kind: .grain,
                mediaType: "image/png",
                data: grainData,
                pixelWidth: 64,
                pixelHeight: 64
            ),
            BrushPackageResource(
                id: customShapeID,
                kind: .shape,
                mediaType: "image/png",
                data: shapeData,
                pixelWidth: 64,
                pixelHeight: 64
            ),
        ]
        let definition = try definition(
            id: id,
            name: "Custom Asymmetric",
            resources: [
                BrushResourceReference(
                    identifier: customGrainID,
                    kind: .grain,
                    required: true,
                    fallback: nil
                ),
                BrushResourceReference(
                    identifier: customShapeID,
                    kind: .shape,
                    required: true,
                    fallback: nil
                ),
            ],
            shapes: [
                BrushShapeLayerDefinition(
                    shape: .asset(customShapeID),
                    combination: .replace,
                    scale: 1,
                    rotation: 0.31,
                    offset: SIMD2(0.08, -0.06)
                ),
            ],
            grains: [
                grain(
                    .asset(customGrainID),
                    strength: 0.68
                ),
            ],
            flow: 0.74,
            hardness: 0.82,
            aspect: 0.63,
            accumulation: .flow,
            edge: .none
        )
        return try BrushPackage(
            manifest: BrushPackageManifest(resources: resources),
            definition: definition,
            resourceData: [
                customGrainID: grainData,
                customShapeID: shapeData,
            ]
        )
    }

    private static func mipProbePackage() throws -> BrushPackage {
        let resourceID = "evidence.mip-probe.shape"
        let data = try mipProbePNG()
        let resource = try BrushPackageResource(
            id: resourceID,
            kind: .shape,
            mediaType: "image/png",
            data: data,
            pixelWidth: 64,
            pixelHeight: 64
        )
        let definition = try definition(
            id: "evidence.native-mips",
            name: "Native Mip Matrix",
            resources: [
                BrushResourceReference(
                    identifier: resourceID,
                    kind: .shape,
                    required: true,
                    fallback: nil
                ),
            ],
            shapes: [
                BrushShapeLayerDefinition(
                    shape: .asset(resourceID),
                    combination: .replace,
                    scale: 1,
                    rotation: 0,
                    offset: .zero
                ),
            ],
            grains: [],
            flow: 1,
            hardness: 1,
            aspect: 1,
            accumulation: .flow,
            edge: .none,
            minimumDiameter: 8,
            maximumDiameter: 96
        )
        return try BrushPackage(
            manifest: BrushPackageManifest(resources: [resource]),
            definition: definition,
            resourceData: [resourceID: data]
        )
    }

    private static func builtInPackage(
        id: String,
        name: String,
        shape: BrushShapeDescriptor,
        grains: [BrushGrainLayerDefinition],
        flow: Float,
        hardness: Float,
        aspect: Float,
        accumulation: BrushAccumulationMode,
        edge: BrushEdgeTreatment,
        minimumDiameter: Float = 0.01,
        maximumDiameter: Float = 16_384
    ) throws -> BrushPackage {
        let definition = try definition(
            id: id,
            name: name,
            resources: [],
            shapes: [
                BrushShapeLayerDefinition(
                    shape: shape,
                    combination: .replace,
                    scale: 1,
                    rotation: 0,
                    offset: .zero
                ),
            ],
            grains: grains,
            flow: flow,
            hardness: hardness,
            aspect: aspect,
            accumulation: accumulation,
            edge: edge,
            minimumDiameter: minimumDiameter,
            maximumDiameter: maximumDiameter
        )
        return try BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: definition,
            resourceData: [:]
        )
    }

    private static func definition(
        id: String,
        name: String,
        resources: [BrushResourceReference],
        shapes: [BrushShapeLayerDefinition],
        grains: [BrushGrainLayerDefinition],
        flow: Float,
        hardness: Float,
        aspect: Float,
        accumulation: BrushAccumulationMode,
        edge: BrushEdgeTreatment,
        minimumDiameter: Float = 0.01,
        maximumDiameter: Float = 16_384
    ) throws -> BrushDefinition {
        let one = constant(1)
        let zero = constant(0)
        return try BrushDefinition(
            id: BrushRecipeID(id),
            metadata: BrushMetadata(displayName: name),
            capabilities: [],
            resources: resources,
            coverage: BrushCoverageDefinition(
                shapes: shapes,
                grains: grains,
                baseHardness: hardness,
                aspectRatio: aspect,
                tipThreshold: 0.01,
                antialiasing: true
            ),
            placement: BrushPlacementDefinition(
                baseSpacingFraction: 0.1,
                maximumSpacingFraction: 0.25,
                baseFlow: flow,
                strokeOpacity: 0.9,
                baseScatterFraction: 0,
                baseRotation: 0,
                baseJitterFraction: 0,
                baseOffset: .zero
            ),
            dynamics: BrushDynamicsDefinition(
                size: BrushMappingDefinition(
                    input: .pressure,
                    response: .boundedPower(exponent: 0.8),
                    scale: 0.7,
                    offset: 0.3,
                    lowerClamp: 0.3,
                    upperClamp: 1,
                    inverted: false,
                    jitter: 0,
                    missingInputValue: 0.5
                ),
                flow: one,
                opacity: one,
                spacing: one,
                rotation: zero,
                scatter: one,
                hardness: one,
                grain: one,
                offsetX: zero,
                offsetY: zero,
                hue: zero,
                saturation: zero,
                brightness: zero,
                secondaryColorMix: zero,
                noPressureNeutral: 0.5,
                randomization: .none
            ),
            color: BrushColorBehaviorDefinition(
                baseAdjustment: .identity,
                perStampJitter: BrushColorJitter(
                    hue: 0,
                    saturation: 0,
                    brightness: 0,
                    secondaryColorMix: 0
                ),
                perStrokeJitter: BrushColorJitter(
                    hue: 0,
                    saturation: 0,
                    brightness: 0,
                    secondaryColorMix: 0
                )
            ),
            material: BrushMaterialDefinition(
                accumulation: accumulation,
                interaction: .none,
                edgeTreatment: edge,
                strength: 0.9,
                wetness: 0,
                bleedRadius: 0,
                softenPasses: 0,
                accumulationLimit: 0.9,
                interactionParameters: nil
            ),
            stabilization: 0,
            taper: .none,
            replayMode: .appendOnly,
            replayLimits: nil,
            seedPolicy: .fixed(DepositionHarnessRunner.seed),
            limits: BrushDefinitionLimits(
                minimumDiameter: minimumDiameter,
                maximumDiameter: maximumDiameter,
                maximumOpacity: 1,
                maximumSpacingFraction: 4,
                maximumResourceDimension: 4_096,
                maximumResidentBytes: 64 * 1_024 * 1_024
            ),
            performanceIntent: .realtime120,
            compatibility: BrushCompatibilityMetadata(
                nativeFeatureVersion: 1,
                sourceSettingKeys: [],
                requiredSemanticKeys: []
            )
        )
    }

    private static func grain(
        _ descriptor: BrushGrainDescriptor,
        strength: Float
    ) -> BrushGrainLayerDefinition {
        BrushGrainLayerDefinition(
            grain: descriptor,
            coordinateMode: .canonical,
            transform: BrushGrainTransform(
                scale: 0.12,
                rotation: 0.23,
                offset: SIMD2(0.11, -0.07)
            ),
            grainMovementFraction: 0.12,
            grainFollowsBrushRotation: true,
            strength: strength
        )
    }

    private static func constant(_ value: Float)
        -> BrushMappingDefinition
    {
        BrushMappingDefinition(
            input: .pressure,
            response: .constant(value),
            scale: 1,
            offset: 0,
            lowerClamp: value,
            upperClamp: value,
            inverted: false,
            jitter: 0,
            missingInputValue: 1
        )
    }

    private static func asymmetricPNG(seed: UInt8) throws -> Data {
        let side = 64
        var bytes = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let diagonal = x > y / 2 && x < 52 && y < 58
                let notch = x > 35 && y > 30
                let stripe = ((x * 3 + y * 5 + Int(seed)) % 17) < 8
                bytes[y * side + x] =
                    diagonal && !notch && stripe ? 255 : 18
            }
        }
        return try grayscalePNG(
            bytes,
            description: "an asymmetric evidence image"
        )
    }

    private static func mipProbePNG() throws -> Data {
        let side = 64
        var bytes = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let distance = max(abs(2 * x - 63), abs(2 * y - 63))
                bytes[y * side + x] = switch distance {
                case ...1: 32
                case ...3: 240
                case ...7: 64
                case ...15: 208
                case ...31: 96
                default: 176
                }
            }
        }
        return try grayscalePNG(
            bytes,
            description: "a mip-selection evidence image"
        )
    }

    private static func grayscalePNG(
        _ bytes: [UInt8],
        description: String
    ) throws -> Data {
        let side = 64
        guard bytes.count == side * side else {
            throw DepositionHarnessRunError.metalResourceUnavailable(
                description
            )
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: side,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.none.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            throw DepositionHarnessRunError.metalResourceUnavailable(
                description
            )
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw DepositionHarnessRunError.metalResourceUnavailable(
                "\(description) PNG destination"
            )
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DepositionHarnessRunError.metalResourceUnavailable(
                "\(description) PNG"
            )
        }
        return output as Data
    }
}
