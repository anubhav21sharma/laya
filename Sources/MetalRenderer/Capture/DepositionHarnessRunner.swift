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

    public init(
        device: any MTLDevice,
        library: any MTLLibrary
    ) {
        self.device = device
        self.library = library
    }

    public convenience init(device: any MTLDevice) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw DepositionHarnessRunError.metalResourceUnavailable(
                "the app Metal library"
            )
        }
        self.init(device: device, library: library)
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
        guard DepositionEvidenceValidator.positiveSceneNames.contains(stem)
        else {
            throw DepositionHarnessRunError.unknownScene(scene.name)
        }

        let package = try DepositionHarnessFixtures.package(for: stem)
        let tiling: TilingKind =
            stem == "deposition-periodic-seams"
                ? .squareKaleidoscope
                : .grid
        let context = try await makeContext(
            scene: scene,
            package: package,
            tiling: tiling
        )
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

        var invariants = try await invariantResults(
            stem: stem,
            scene: scene,
            primary: capture,
            context: context,
            package: package
        )
        invariants["strokeCompilerCountersUnchanged"] =
            countersBeforeStroke == countersAfterStroke
        for key in scene.depositionInvariantExpectations.keys
        where invariants[key] == nil {
            invariants[key] = false
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
            telemetry: DepositionTelemetryEvidence(
                authoritativeBacklog: 0,
                predictedBacklog: 0,
                backlogHighWater: capture.scheduledRecords.count,
                encodedInstanceCount:
                    UInt64(capture.projectedInstanceCount),
                bufferHighWater:
                    capture.projectedInstanceCount > 0 ? 1 : 0,
                missedFrameCount: 0
            ),
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
        let displayMetrics: [GPUFrameMetrics]
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

    func makeContext(
        scene: HarnessScene,
        package: BrushPackage,
        tiling: TilingKind = .grid,
        cacheBudgetBytes: Int = 64 * 1_024 * 1_024
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
        let compiler = BrushCompiler(
            device: device,
            commandQueue: commandQueue,
            profile: profile,
            pipelinePreparing: pipelineLibrary,
            testHooks: .none
        )
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(
                width: Float(scene.width),
                height: Float(scene.height)
            ),
            configuration: TilingCanvasConfiguration(
                pixelSize: PixelSize(
                    width: scene.width,
                    height: scene.height
                ),
                tiling: tiling
            )
        )
        let compiled = try await compiler.compileAndActivate(
            package: package
        )
        if package.definition.material.accumulation == .destinationOut {
            try renderer.activateEraserBrush(compiled)
        } else {
            try renderer.activateDrawBrush(compiled)
        }
        return Context(
            renderer: renderer,
            compiler: compiler,
            compiled: compiled
        )
    }

    func seedEraseCanvas(_ context: Context, scene: HarnessScene)
        async throws
    {
        let inkPackage = try DepositionHarnessFixtures.package(
            for: "deposition-ink"
        )
        let ink = try await context.compiler.compileAndActivate(
            package: inkPackage
        )
        try context.renderer.activateDrawBrush(ink)
        _ = try commitOnly(
            renderer: context.renderer,
            brush: ink,
            compositeMode: .draw,
            color: .black,
            trace: Self.trace(width: scene.width, height: scene.height)
        )
        let eraser = try await context.compiler.compileAndActivate(
            package: DepositionHarnessFixtures.package(
                for: "deposition-erase"
            )
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
        diameter: Float? = nil
    ) throws -> StrokeCapture {
        let renderer = context.renderer
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
        renderer.onOperationCompleted = { completions.append($0) }
        let before = Self.textureBytes(
            try renderer.copyCanonicalForHarness()
        )
        let style = StrokeRenderStyle(
            color: color,
            diameter: diameter
                ?? (stem == "deposition-stamp-size-mips" ? 48 : 22),
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
        for sample in samples.dropFirst().dropLast() {
            try renderer.appendStroke(token: token, sample: sample)
            if partitionMode == .everySample, sample.kind != .predicted {
                intermediateMetrics.append(
                    try renderer.flushPendingLiveForHarness().metrics
                )
            }
        }
        if !cancel {
            try renderer.requestStrokeCommit(
                token: token,
                sample: samples.last!,
                maximumRetainedBytes: 64 * 1_024 * 1_024
            )
        }
        let scheduled = renderer.harnessScheduledAuthoritativeRecords
            + renderer.harnessScheduledPredictedRecords
        let logical = renderer.harnessCounters.totalDabsThisStroke
        let projected = renderer.harnessCounters.totalInstancesThisStroke
        var flushMetrics =
            try renderer.flushPendingLiveForHarness().metrics
        while !renderer.harnessScheduledAuthoritativeRecords.isEmpty
                || !renderer.harnessScheduledPredictedRecords.isEmpty
        {
            let frame = try renderer.flushPendingLiveForHarness()
            flushMetrics = frame.metrics
            intermediateMetrics.append(frame.metrics)
        }
        let liveFrame = try renderer.renderOffscreenDisplayForHarness(
            width: scene.width,
            height: scene.height,
            showGridLines: false
        )
        let commitMetrics: GPUFrameMetrics
        if cancel {
            try renderer.cancelStroke(token: token)
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
            displayMetrics: intermediateMetrics
                + [liveFrame.metrics, committedFrame.metrics]
        )
    }

    func commitOnly(
        renderer: GridRenderer,
        brush: CompiledBrush,
        compositeMode: StrokeCompositeMode,
        color: InkColor,
        trace: [StrokeSample],
        partitionMode: PartitionMode = .oneFrame
    ) throws -> [UInt8] {
        let token = RendererOperationToken(rawValue: Self.seed &+ 1)
        var receipt: RasterMutationReceipt?
        renderer.onOperationCompleted = {
            if case let .rasterSuccess(value) = $0 {
                receipt = value
            }
        }
        let style = StrokeRenderStyle(
            color: color,
            diameter: 22,
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
        return Self.textureBytes(try renderer.copyCanonicalForHarness())
    }
}

private extension DepositionHarnessRunner {
    func invariantResults(
        stem: String,
        scene: HarnessScene,
        primary: StrokeCapture,
        context: Context,
        package: BrushPackage
    ) async throws -> [String: Bool] {
        var results: [String: Bool] = [:]
        let definition = context.compiled.program.definition
        let expected = DepositionHarnessFixtures.expectedPipeline(for: stem)
        results["familyAndAccumulationCorrect"] =
            expected.map {
                definition.id.rawValue == $0.definitionID
                    && definition.material.accumulation == $0.accumulation
                    && definition.material.edgeTreatment == $0.edge
                    && definition.coverage.shapes.first?.shape == $0.shape
                    && definition.placement.baseFlow == $0.flow
            } ?? true
        results["previewCommitMaximumDeltaWithinTolerance"] =
            primary.previewCommitMaximumChannelDelta <= 1

        switch stem {
        case "deposition-custom-asymmetric":
            results["customTexturesExact"] =
                customTexturesAreExact(context.compiled)
        case "deposition-layer-matrix":
            results["secondaryLayerPresent"] =
                try await layerMatrixIsComplete(scene: scene)
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
            results["activeCompiledBrushPinned"] =
                try await cachePinningAudit(scene: scene)
        case "deposition-failure-matrix":
            results["failurePreservesCanonicalAndHistory"] =
                try await failureMatrixAudit(
                    scene: scene,
                    package: package
                )
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
        return Self.textureBytes(capture.canonical)
    }

    func predictionIsEqual(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
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
        return without == with
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
        let inkPackage = try DepositionHarnessFixtures.package(
            for: "deposition-ink"
        )
        let context = try await makeContext(
            scene: scene,
            package: inkPackage
        )
        _ = try commitOnly(
            renderer: context.renderer,
            brush: context.compiled,
            compositeMode: .draw,
            color: .black,
            trace: Self.trace(width: scene.width, height: scene.height)
        )
        let eraser = try await context.compiler.compileAndActivate(
            package: DepositionHarnessFixtures.package(
                for: "deposition-erase"
            )
        )
        try context.renderer.activateEraserBrush(eraser)
        return try commitOnly(
            renderer: context.renderer,
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
        let records = context.renderer.harnessScheduledAuthoritativeRecords
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

    func layerMatrixIsComplete(scene: HarnessScene) async throws -> Bool {
        var observed = Set<BrushShapeCombinationMode>()
        var sawOneShape = false
        var sawTwoShapes = false
        var grainCounts = Set<Int>()
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
                        return false
                    }
                }
            }
        }
        return sawOneShape
            && sawTwoShapes
            && grainCounts == [0, 1, 2]
            && observed == [.multiply, .minimum, .maximum]
    }

    func mipMatrixIsComplete(scene: HarnessScene) async throws -> Bool {
        let package = try DepositionHarnessFixtures.package(
            for: "deposition-stamp-size-mips"
        )
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
    func cachePinningAudit(scene: HarnessScene) async throws -> Bool {
        guard let commandQueue = device.makeCommandQueue() else {
            throw DepositionHarnessRunError.metalResourceUnavailable(
                "a cache-audit command queue"
            )
        }
        let profile = try BrushDeviceProfile(
            registryID: device.registryID,
            recommendedWorkingSetBytes: 64 * 1_024 * 1_024,
            maximumWorkingTextureDimension: 4_096,
            brushCacheBudgetBytes: 6_000,
            targetFramesPerSecond: 120
        )
        let compiler = BrushCompiler(
            device: device,
            commandQueue: commandQueue,
            profile: profile,
            pipelinePreparing: DepositionPipelineLibrary(
                device: device,
                library: library
            ),
            testHooks: .none
        )
        let first = try await compiler.compileAndActivate(
            package: DepositionHarnessFixtures.cachePackage(index: 1)
        )
        let firstPinned = Set(compiler.pinnedKeys) == first.cacheKeys
        let firstKeys = first.cacheKeys
        let second = try await compiler.compileAndActivate(
            package: DepositionHarnessFixtures.cachePackage(index: 2)
        )
        let inactiveWasEvicted =
            Set(compiler.cachedKeys).isDisjoint(with: firstKeys)
        let activeIsPinned =
            Set(compiler.pinnedKeys) == second.cacheKeys
        let counters = compiler.debugCounters
        _ = try await compiler.compileAndActivate(
            package: DepositionHarnessFixtures.cachePackage(index: 2)
        )
        let churnHit = compiler.debugCounters.cacheHitCount
            > counters.cacheHitCount
        return firstPinned
            && inactiveWasEvicted
            && activeIsPinned
            && churnHit
    }

    func failureMatrixAudit(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        var passed = true
        passed = try await pipelineFailureIsAtomic(
            package: package
        ) && passed
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
        let recovery = try await canonicalVariant(
            scene: scene,
            package: package
        )
        return passed && Self.hasNontransparentPixel(recovery)
    }

    func pipelineFailureIsAtomic(package: BrushPackage) async throws -> Bool {
        guard let commandQueue = device.makeCommandQueue() else {
            return false
        }
        let preparer = FailOnceDepositionPipelinePreparer(
            delegate: DepositionPipelineLibrary(
                device: device,
                library: library
            )
        )
        let compiler = BrushCompiler(
            device: device,
            commandQueue: commandQueue,
            profile: try BrushDeviceProfile(
                registryID: device.registryID,
                recommendedWorkingSetBytes: 64 * 1_024 * 1_024,
                maximumWorkingTextureDimension: 4_096,
                targetFramesPerSecond: 120
            ),
            pipelinePreparing: preparer,
            testHooks: .none
        )
        let failureWasAtomic: Bool
        do {
            _ = try await compiler.compileAndActivate(package: package)
            return false
        } catch let failure as BrushCompilationFailure {
            failureWasAtomic =
                failure.stage == .pipelineSelection
                && compiler.activeBrush == nil
                && compiler.residentByteCount == 0
        }
        guard failureWasAtomic else { return false }
        let recovery = try await compiler.compileAndActivate(
            package: package
        )
        return compiler.activeBrush?.renderIdentity
            == recovery.renderIdentity
    }

    func bufferFailureIsAtomic(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let context = try await makeContext(
            scene: scene,
            package: package
        )
        let before = try failureSnapshot(context.renderer)
        guard let leases = context.renderer.instancePool.acquire(
            count: GridCanvasContract.inFlightBufferCount
        ) else {
            return false
        }
        let token = RendererOperationToken(rawValue: Self.seed &+ 31)
        try context.renderer.beginStroke(
            token: token,
            sample: Self.trace(
                width: scene.width,
                height: scene.height
            )[0],
            style: Self.style(context.compiled)
        )
        do {
            _ = try context.renderer.flushPendingLiveForHarness()
            for lease in leases {
                context.renderer.instancePool.abandon(lease)
            }
            return false
        } catch MetalRendererError.instanceBufferAllocationFailed {
            let onlyExternallyHeldLeasesRemain =
                context.renderer.harnessReservedInstanceBufferCount
                == leases.count
            for lease in leases {
                context.renderer.instancePool.abandon(lease)
            }
            let after = try failureSnapshot(context.renderer)
            let failureWasAtomic = context.renderer.isIdle
                && onlyExternallyHeldLeasesRemain
                && before == after
            let recovered = try validRecovery(
                context: context,
                scene: scene
            )
            return failureWasAtomic && recovered
        }
    }

    func encoderFailureIsAtomic(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let context = try await makeContext(
            scene: scene,
            package: package
        )
        let before = try failureSnapshot(context.renderer)
        let token = RendererOperationToken(rawValue: Self.seed &+ 32)
        try context.renderer.beginStroke(
            token: token,
            sample: Self.trace(
                width: scene.width,
                height: scene.height
            )[0],
            style: Self.style(context.compiled)
        )
        guard let encoder =
                context.renderer.removeDepositionEncoderForHarness()
        else {
            return false
        }
        do {
            _ = try context.renderer.flushPendingLiveForHarness()
            context.renderer.restoreDepositionEncoderForHarness(encoder)
            return false
        } catch MetalRendererError.depositionEncoderUnavailable {
            context.renderer.restoreDepositionEncoderForHarness(encoder)
            let after = try failureSnapshot(context.renderer)
            let failureWasAtomic = context.renderer.isIdle
                && before == after
            let recovered = try validRecovery(
                context: context,
                scene: scene
            )
            return failureWasAtomic && recovered
        }
    }

    func allocationFailureIsAtomic(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let context = try await makeContext(
            scene: scene,
            package: package
        )
        let before = try failureSnapshot(context.renderer)
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
                scene: scene
            )
            return failureWasAtomic && recovered
        }
    }

    func completionFailureIsAtomic(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let context = try await makeContext(
            scene: scene,
            package: package
        )
        let before = try failureSnapshot(context.renderer)
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
            _ = try context.renderer.flushPendingLiveForHarness(
                forceFailure: true
            )
            return false
        } catch MetalRendererError.commandFailed {
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
                scene: scene
            )
            return failureWasAtomic && recovered
        }
    }

    func revisionFailureIsAtomic(
        scene: HarnessScene,
        package: BrushPackage
    ) async throws -> Bool {
        let context = try await makeContext(
            scene: scene,
            package: package
        )
        let before = try failureSnapshot(context.renderer)
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
                && context.renderer.harnessRasterRevisionResidentBytes == 0
                && before == after
            let recovered = try validRecovery(
                context: context,
                scene: scene
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
            reservedInstanceBufferCount:
                renderer.harnessReservedInstanceBufferCount,
            scheduledAuthoritativeCount:
                renderer.harnessScheduledAuthoritativeRecords.count,
            scheduledPredictedCount:
                renderer.harnessScheduledPredictedRecords.count,
            pendingInstanceColorCount:
                renderer.harnessPendingInstanceColors.count
        )
    }

    func validRecovery(context: Context, scene: HarnessScene) throws
        -> Bool
    {
        let bytes = try commitOnly(
            renderer: context.renderer,
            brush: context.compiled,
            compositeMode: .draw,
            color: .black,
            trace: Self.trace(width: scene.width, height: scene.height)
        )
        return Self.hasNontransparentPixel(bytes)
            && context.renderer.isIdle
            && context.renderer.harnessReservedInstanceBufferCount == 0
            && context.renderer.harnessScheduledAuthoritativeRecords.isEmpty
            && context.renderer.harnessScheduledPredictedRecords.isEmpty
            && context.renderer.harnessPendingInstanceColors.isEmpty
    }
}

private struct RendererFailureSnapshot: Equatable {
    let canonicalBytes: [UInt8]
    let revision: RasterRevision
    let historyResidentBytes: Int
    let reservedInstanceBufferCount: Int
    let scheduledAuthoritativeCount: Int
    let scheduledPredictedCount: Int
    let pendingInstanceColorCount: Int
}

@MainActor
private final class FailOnceDepositionPipelinePreparer:
    DepositionPipelinePreparing
{
    private let delegate: any DepositionPipelinePreparing
    private var hasFailed = false

    init(delegate: any DepositionPipelinePreparing) {
        self.delegate = delegate
    }

    func prepare(
        for key: DepositionPipelineKey
    ) async throws -> DepositionPipelineBinding {
        if !hasFailed {
            hasFailed = true
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
            padding2: 0
        )
    }
}

private extension DepositionHarnessRunner {
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
                flow: 0.42
            )
        case "deposition-marker":
            ExpectedPipeline(
                definitionID: "builtin.native-marker",
                accumulation: .uniformGlaze,
                edge: .markerOverlap,
                shape: .chisel,
                flow: 0.46
            )
        case "deposition-airbrush":
            ExpectedPipeline(
                definitionID: "builtin.native-airbrush",
                accumulation: .flow,
                edge: .none,
                shape: .softRound,
                flow: 0.14
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
        case "deposition-ink":
            try builtInPackage(
                id: "builtin.native-ink",
                name: "Native Ink",
                shape: .hardRound,
                grains: [],
                flow: 0.82,
                hardness: 0.9,
                aspect: 1,
                accumulation: .flow,
                edge: .none
            )
        case "deposition-dry":
            try builtInPackage(
                id: "builtin.native-dry-media",
                name: "Native Dry Media",
                shape: .hardRound,
                grains: [grain(.paper, strength: 0.72)],
                flow: 0.68,
                hardness: 0.74,
                aspect: 0.72,
                accumulation: .flow,
                edge: .dryBreakup
            )
        case "deposition-glaze":
            try builtInPackage(
                id: "builtin.native-glaze",
                name: "Native Glaze",
                shape: .softRound,
                grains: [],
                flow: 0.42,
                hardness: 0.35,
                aspect: 1,
                accumulation: .uniformGlaze,
                edge: .none
            )
        case "deposition-marker":
            try builtInPackage(
                id: "builtin.native-marker",
                name: "Native Marker",
                shape: .chisel,
                grains: [],
                flow: 0.46,
                hardness: 0.78,
                aspect: 0.68,
                accumulation: .uniformGlaze,
                edge: .markerOverlap
            )
        case "deposition-airbrush":
            try builtInPackage(
                id: "builtin.native-airbrush",
                name: "Native Airbrush",
                shape: .softRound,
                grains: [],
                flow: 0.14,
                hardness: 0.12,
                aspect: 1,
                accumulation: .flow,
                edge: .none
            )
        case "deposition-erase":
            try builtInPackage(
                id: "builtin.native-eraser",
                name: "Native Eraser",
                shape: .hardRound,
                grains: [],
                flow: 1,
                hardness: 0.92,
                aspect: 1,
                accumulation: .destinationOut,
                edge: .none
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
        let secondary: [BrushShapeLayerDefinition] = twoShapes
            ? [
                BrushShapeLayerDefinition(
                    shape: .softRound,
                    combination: combination,
                    scale: 0.72,
                    rotation: 0.37,
                    offset: SIMD2(0.12, -0.08)
                ),
            ]
            : []
        let grains = [
            grain(.paper, strength: 0.55),
            grain(.noise, strength: 0.35),
        ]
        let definition = try definition(
            id:
                "evidence.layer-\(combination.rawValue)-\(grainCount)-\(twoShapes)",
            name: "Native Layer Matrix",
            resources: [],
            shapes: [
                BrushShapeLayerDefinition(
                    shape: .hardRound,
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
            manifest: BrushPackageManifest(resources: []),
            definition: definition,
            resourceData: [:]
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
