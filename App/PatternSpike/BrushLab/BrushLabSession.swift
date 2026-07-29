#if DEBUG
import BrushFormat
import EditorCore
import Foundation
import Metal
import MetalRenderer
import Observation
import PatternEngine
import PatternFile

struct BrushLabSettingItem: Equatable, Identifiable {
    let name: String
    let value: String

    var id: String {
        name
    }
}

struct BrushLabSettingGroup: Equatable, Identifiable {
    let title: String
    let items: [BrushLabSettingItem]

    var id: String {
        title
    }
}

struct BrushLabResourcePreview: Equatable, Identifiable {
    let descriptor: BrushPackageResource
    let data: Data

    var id: String {
        descriptor.id
    }
}

enum BrushLabDrawingAvailability: Equatable {
    case unloaded
    case available
    case unsupportedInteraction(BrushInteractionMode)
    case compilationFailed(String)
}

struct BrushLabInputRecord: Codable, Equatable, Sendable {
    let sequence: Int
    let x: Float
    let y: Float
    let pressure: Float
    let timestamp: TimeInterval
    let phase: String
    let source: String
    let kind: String
    let altitude: Float?
    let azimuth: Float?
    let roll: Float?
    let tangentialPressure: Float?
    let deviceIdentifier: UInt64?
    let estimationUpdateIndex: Int?
    let capabilities: UInt8

    init(sequence: Int, sample: StrokeSample) {
        self.sequence = sequence
        x = sample.position.x
        y = sample.position.y
        pressure = sample.pressure
        timestamp = sample.timestamp
        phase = Self.name(sample.phase)
        source = Self.name(sample.source)
        kind = Self.name(sample.kind)
        altitude = sample.altitude
        azimuth = sample.azimuth
        roll = sample.roll
        tangentialPressure = sample.tangentialPressure
        deviceIdentifier = sample.deviceIdentifier
        estimationUpdateIndex = sample.estimationUpdateIndex
        capabilities = sample.capabilities.rawValue
    }

    private static func name(_ phase: StrokePhase) -> String {
        switch phase {
        case .began: "began"
        case .moved: "moved"
        case .ended: "ended"
        case .cancelled: "cancelled"
        }
    }

    private static func name(_ source: StrokeSource) -> String {
        switch source {
        case .mouse: "mouse"
        case .tablet: "tablet"
        case .pencil: "pencil"
        }
    }

    private static func name(_ kind: StrokeSampleKind) -> String {
        switch kind {
        case .actual: "actual"
        case .coalesced: "coalesced"
        case .predicted: "predicted"
        case .estimatedUpdate: "estimatedUpdate"
        }
    }
}

struct BrushLabDabRecord: Codable, Equatable, Sendable {
    let sequence: Int
    let ordinal: UInt64
    let predicted: Bool
    let x: Float
    let y: Float
    let diameter: Float
    let spacing: Float
    let flow: Float
    let strokeOpacity: Float
    let rotation: Float
    let hardness: Float
    let grainScale: Float
    let materialFamily: String
    let materialContribution: Float
    let sourceDistance: Float

    init(sequence: Int, dab: LogicalDab) {
        self.sequence = sequence
        ordinal = dab.ordinal
        predicted = dab.isPredicted
        x = dab.position.x
        y = dab.position.y
        diameter = dab.diameter
        spacing = dab.spacing
        flow = dab.flow
        strokeOpacity = dab.strokeOpacity
        rotation = dab.rotation
        hardness = dab.hardness
        grainScale = dab.grainScale
        materialFamily = String(describing: dab.materialFamily)
        materialContribution = dab.materialContribution
        sourceDistance = dab.sourceDistance
    }
}

struct BrushLabFrameMetrics: Codable, Equatable, Sendable {
    var framesPerSecond = 0.0
    var p95FrameMilliseconds = 0.0
    var missedFramePercentage = 0.0
    var targetFramesPerSecond = 0
    var sampleCount = 0
    var cpuEncodeMilliseconds = 0.0
    var gpuMilliseconds = 0.0
    var p95CPUEncodeMilliseconds = 0.0
    var p95GPUMilliseconds = 0.0
    var rendererSampleCount = 0
}

struct BrushLabCompletedReplay: Sendable {
    let generationID: String
    let cardID: String
    let canvasHash: String
    let traceHash: String
    let substrateInputCount: Int
    let input: [BrushLabInputRecord]
    let logicalDabs: [BrushLabDabRecord]
    let snapshot: CommittedDocumentSnapshot
    let packageHash: String
    let definitionID: String
    let semanticHash: String
    let pipelineKey: String
    let abiVersion: UInt16
    let diagnostics: BrushLabDiagnostics
}

@MainActor
@Observable
final class BrushLabSession {
    static let maximumInputRecords = 4_096
    static let maximumDabRecords = 16_384
    private static let substrateColor = InkColor(
        red: 0.2,
        green: 0.45,
        blue: 0.85,
        alpha: 1
    )!

    let controller: EditorSessionController
    let compiler: BrushCompiler

    private(set) var package: BrushPackage?
    private(set) var sourceName: String?
    private(set) var packageContentHash: String?
    private(set) var activeDrawingPackageContentHash: String?
    private(set) var compiledBrush: CompiledBrush?
    private(set) var compilationReport: BrushCompilationReport?
    private(set) var compilationFailure: BrushCompilationFailure?
    private(set) var compilationDiagnostics: [String] = []
    private(set) var drawingAvailability: BrushLabDrawingAvailability =
        .unloaded
    private(set) var inputRecords: [BrushLabInputRecord] = []
    private(set) var dabRecords: [BrushLabDabRecord] = []
    private(set) var droppedInputRecordCount = 0
    private(set) var droppedDabRecordCount = 0
    private(set) var deterministicSeed: UInt64 = 1
    private(set) var frameMetrics = BrushLabFrameMetrics()
    private(set) var manualCards = BrushLabManualCard.fixedMatrix
    private(set) var professionalManualCards =
        BrushLabManualCard.professionalFixedMatrix
    private(set) var selectedManualCardID: String?
    private(set) var completedReplay: BrushLabCompletedReplay?
    private(set) var manualAssessments: [String: BrushLabManualAssessment] =
        Dictionary(
            uniqueKeysWithValues: BrushLabManualCard.fixedMatrix.map {
                ($0.cardID, BrushLabManualAssessment(cardID: $0.cardID))
            }
        )
    private(set) var professionalManualAssessments:
        [String: BrushLabManualAssessment] = Dictionary(
            uniqueKeysWithValues:
                BrushLabManualCard.professionalFixedMatrix.map {
                    ($0.cardID, BrushLabManualAssessment(cardID: $0.cardID))
                }
        )
    private(set) var depositionMetrics = DebugDepositionSnapshot()
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var cpuEncodeSamples: [Double] = []
    private var gpuSamples: [Double] = []

    init(controller: EditorSessionController, compiler: BrushCompiler) {
        self.controller = controller
        self.compiler = compiler
        try? controller.setDiagnosticFixedStrokeSeed(deterministicSeed)
        controller.onNormalizedInput = { [weak self] sample in
            self?.record(sample)
        }
        controller.renderer.onLogicalDabsGenerated = { [weak self] dab in
            self?.record(dab)
        }
    }

    var resourcePreviews: [BrushLabResourcePreview] {
        guard let package else { return [] }
        return package.manifest.resources.compactMap { descriptor in
            package.resourceData[descriptor.id].map {
                BrushLabResourcePreview(
                    descriptor: descriptor,
                    data: $0
                )
            }
        }
    }

    var settingGroups: [BrushLabSettingGroup] {
        guard let definition = package?.definition else { return [] }
        let shapeNames = definition.coverage.shapes.map {
            String(describing: $0.shape)
        }.joined(separator: ", ")
        let grainNames = definition.coverage.grains.map {
            String(describing: $0.grain)
        }.joined(separator: ", ")
        let capabilityNames = definition.capabilities.map {
            "\($0.identifier)\($0.required ? " (required)" : "")"
        }.joined(separator: ", ")
        return [
            BrushLabSettingGroup(
                title: "Identity",
                items: [
                    .init(name: "ID", value: definition.id.rawValue),
                    .init(
                        name: "Name",
                        value: definition.metadata.displayName
                    ),
                    .init(
                        name: "Author",
                        value: definition.metadata.author ?? "—"
                    ),
                    .init(
                        name: "Source",
                        value: definition.metadata.sourceApplication ?? "native"
                    ),
                ]
            ),
            BrushLabSettingGroup(
                title: "Coverage",
                items: [
                    .init(name: "Shapes", value: shapeNames),
                    .init(
                        name: "Grains",
                        value: grainNames.isEmpty ? "opaque" : grainNames
                    ),
                    .init(
                        name: "Hardness",
                        value: Self.number(definition.coverage.baseHardness)
                    ),
                    .init(
                        name: "Aspect",
                        value: Self.number(definition.coverage.aspectRatio)
                    ),
                ]
            ),
            BrushLabSettingGroup(
                title: "Placement",
                items: [
                    .init(
                        name: "Spacing",
                        value: Self.number(
                            definition.placement.baseSpacingFraction
                        )
                    ),
                    .init(
                        name: "Flow",
                        value: Self.number(definition.placement.baseFlow)
                    ),
                    .init(
                        name: "Opacity",
                        value: Self.number(
                            definition.placement.strokeOpacity
                        )
                    ),
                    .init(
                        name: "Scatter",
                        value: Self.number(
                            definition.placement.baseScatterFraction
                        )
                    ),
                    .init(
                        name: "Rotation",
                        value: Self.number(definition.placement.baseRotation)
                    ),
                ]
            ),
            BrushLabSettingGroup(
                title: "Dynamics",
                items: [
                    .init(
                        name: "Size",
                        value: Self.mapping(definition.dynamics.size)
                    ),
                    .init(
                        name: "Flow",
                        value: Self.mapping(definition.dynamics.flow)
                    ),
                    .init(
                        name: "Spacing",
                        value: Self.mapping(definition.dynamics.spacing)
                    ),
                    .init(
                        name: "Rotation",
                        value: Self.mapping(definition.dynamics.rotation)
                    ),
                    .init(
                        name: "Scatter",
                        value: Self.mapping(definition.dynamics.scatter)
                    ),
                ]
            ),
            BrushLabSettingGroup(
                title: "Material",
                items: [
                    .init(
                        name: "Accumulation",
                        value: definition.material.accumulation.rawValue
                    ),
                    .init(
                        name: "Interaction",
                        value: definition.material.interaction.rawValue
                    ),
                    .init(
                        name: "Edge",
                        value: definition.material.edgeTreatment.rawValue
                    ),
                    .init(
                        name: "Strength",
                        value: Self.number(definition.material.strength)
                    ),
                    .init(
                        name: "Wetness",
                        value: Self.number(definition.material.wetness)
                    ),
                ]
            ),
            BrushLabSettingGroup(
                title: "Execution",
                items: [
                    .init(
                        name: "Capabilities",
                        value: capabilityNames.isEmpty
                            ? "none"
                            : capabilityNames
                    ),
                    .init(
                        name: "Replay",
                        value: String(describing: definition.replayMode)
                    ),
                    .init(
                        name: "Seed policy",
                        value: String(describing: definition.seedPolicy)
                    ),
                    .init(
                        name: "Performance",
                        value: definition.performanceIntent.rawValue
                    ),
                ]
            ),
        ]
    }

    func loadPackage(at url: URL) async {
        guard controller.renderer.isIdle else {
            errorMessage = BrushLabEvidenceError.rendererBusy.localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let package = try await Task.detached(
                priority: .userInitiated
            ) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                return try BrushPackageIO.load(from: url)
            }.value
            await loadPackage(package, sourceName: url.lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadPackage(_ package: BrushPackage, sourceName: String) async {
        guard controller.renderer.isIdle else {
            errorMessage = BrushLabEvidenceError.rendererBusy.localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        prepareInspectionState()
        self.package = package
        self.sourceName = sourceName
        do {
            let contentHash = try package.contentHash
            packageContentHash = contentHash
            if package.definition.material.interaction != .none {
                compilationReport = try compiler.inspectionReport(for: package)
                drawingAvailability = .unsupportedInteraction(
                    package.definition.material.interaction
                )
                isLoading = false
                return
            }
            let compiled = try await compiler.compileAndActivate(
                package: package
            )
            compiledBrush = compiled
            compilationReport = compiled.report
            compilationDiagnostics = compiled.diagnostics.map(
                Self.diagnosticDescription
            )
            if compiled.program.requestedBackend == .deposition {
                try controller.installBootstrapBrushes(
                    draw: compiled,
                    eraser: compiled
                )
                activeDrawingPackageContentHash = contentHash
                drawingAvailability = .available
            }
        } catch let failure as BrushCompilationFailure {
            compilationFailure = failure
            drawingAvailability = .compilationFailed(
                "Compiler \(failure.stage.rawValue): \(failure.reason). "
                    + "The previous drawing brush remains active."
            )
        } catch {
            errorMessage = error.localizedDescription
            drawingAvailability = .compilationFailed(
                error.localizedDescription
            )
        }
        isLoading = false
    }

    func setDeterministicSeed(_ seed: UInt64) throws {
        guard seed != 0 else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        try controller.setDiagnosticFixedStrokeSeed(seed)
        deterministicSeed = seed
    }

    func clearTrace() {
        inputRecords.removeAll(keepingCapacity: true)
        dabRecords.removeAll(keepingCapacity: true)
        droppedInputRecordCount = 0
        droppedDabRecordCount = 0
    }

    func selectManualCard(_ cardID: String) async throws {
        guard controller.renderer.isIdle else {
            throw BrushLabEvidenceError.rendererBusy
        }
        guard let card = manualCards.first(where: {
            $0.cardID == cardID
        }) else {
            throw BrushLabEvidenceError.manualCardUnavailable(cardID)
        }
        completedReplay = nil
        try await prepareManualCard(card)
        selectedManualCardID = cardID
        clearTrace()
    }

    private func prepareManualCard(
        _ card: BrushLabManualCard
    ) async throws {
        guard let anchor = AnchorBrushCatalog.entry(
            for: BrushRecipeID(card.brushID)
        ) else {
            throw BrushLabEvidenceError.manualBrushUnavailable(card.brushID)
        }
        guard card.customResourceFixture == nil
                || card.customResourceFixture
                    == BrushLabManualCard.customAsymmetricFixture
        else {
            throw BrushLabEvidenceError.manualResourceFixtureUnavailable(
                card.customResourceFixture!
            )
        }
        if controller.renderer.documentConfiguration
            != card.documentConfiguration
        {
            switch card.documentConfiguration {
            case let .periodic(configuration):
                controller.handlePeriodicConfiguration(configuration)
            case let .finite(configuration):
                controller.handleFiniteConfiguration(configuration)
            }
        }
        guard controller.renderer.documentConfiguration
                == card.documentConfiguration
        else {
            throw BrushLabEvidenceError.documentConfigurationUnavailable
        }
        let package = try Self.manualPackage(
            anchor: anchor,
            customAsymmetric:
                card.customResourceFixture
                    == BrushLabManualCard.customAsymmetricFixture
        )
        await loadPackage(
            package,
            sourceName: "\(card.cardID).layabrush"
        )
        guard let compiledBrush,
              drawingAvailability == .available
        else {
            if let compilationFailure {
                throw compilationFailure
            }
            throw BrushLabEvidenceError.manualBrushUnavailable(card.brushID)
        }
        if card.tool == .erase {
            try controller.installBootstrapBrushes(
                draw: compiledBrush,
                eraser: compiledBrush
            )
            controller.handleTool(.erase)
        } else {
            controller.handleTool(.draw)
        }
        controller.handleInkColor(card.paintColor)
        controller.model.confirmBrushDiameter(card.diameter)
        guard controller.model.brushDiameter == card.diameter else {
            throw BrushLabEvidenceError.manualDiameterUnavailable(
                card.diameter
            )
        }
        try validatePreparedCard(card, compiledBrush: compiledBrush)
    }

    func replaySelectedManualCard() async throws
        -> BrushLabCompletedReplay
    {
        guard controller.renderer.isIdle else {
            throw BrushLabEvidenceError.rendererBusy
        }
        guard let card = selectedManualCard else {
            throw BrushLabEvidenceError.manualCardNotSelected
        }
        completedReplay = nil
        try await controller.clearAndAwaitCompletion()
        guard controller.renderer.isIdle else {
            throw BrushLabEvidenceError.rendererBusy
        }
        try await prepareManualCard(card)
        clearTrace()
        let substrateInputCount: Int
        if card.substrate == .recordedOpaqueStroke {
            controller.handleTool(.draw)
            controller.handleInkColor(Self.substrateColor)
            controller.model.confirmBrushDiameter(
                min(2_000, max(40, card.diameter * 1.75))
            )
            controller.handleStrokeSamples(card.substrateTraceSamples())
            _ = try controller.renderer.completePendingInteractiveStroke()
            substrateInputCount = inputRecords.count
            try applyAndValidateStrokeProperties(card)
        } else {
            substrateInputCount = 0
            try applyAndValidateStrokeProperties(card)
        }
        controller.handleStrokeSamples(card.traceSamples())
        _ = try controller.renderer.completePendingInteractiveStroke()
        guard controller.renderer.isIdle else {
            throw BrushLabEvidenceError.rendererBusy
        }
        let snapshot = try controller.renderer.captureCommittedDocument()
        let canvasHash = Self.canvasHash(snapshot)
        let traceHash = try Self.traceHash(
            input: inputRecords,
            dabs: dabRecords
        )
        guard let packageContentHash,
              let compiledBrush
        else {
            throw BrushLabEvidenceError.packageUnavailable
        }
        let generationID = BrushContentHash.sha256Hex(
            of: Data(
                [
                    card.cardID,
                    packageContentHash,
                    canvasHash,
                    traceHash,
                    String(deterministicSeed),
                ].joined(separator: "\u{0}").utf8
            )
        )
        let replay = BrushLabCompletedReplay(
            generationID: generationID,
            cardID: card.cardID,
            canvasHash: canvasHash,
            traceHash: traceHash,
            substrateInputCount: substrateInputCount,
            input: inputRecords,
            logicalDabs: dabRecords,
            snapshot: snapshot,
            packageHash: packageContentHash,
            definitionID:
                compiledBrush.renderIdentity.definitionID.rawValue,
            semanticHash: compiledBrush.renderIdentity.semanticHash,
            pipelineKey: Self.pipelineKey(compiledBrush),
            abiVersion:
                compiledBrush.depositionPipeline.key.abiVersion,
            diagnostics: makeDiagnostics()
        )
        completedReplay = replay
        return replay
    }

    func clearManualCard() {
        guard controller.renderer.isIdle else { return }
        controller.clear()
        completedReplay = nil
        clearTrace()
    }

    private func applyAndValidateStrokeProperties(
        _ card: BrushLabManualCard
    ) throws {
        controller.handleTool(
            card.tool == .erase ? .erase : .draw
        )
        controller.handleInkColor(card.paintColor)
        controller.model.confirmBrushDiameter(card.diameter)
        guard let compiledBrush else {
            throw BrushLabEvidenceError.packageUnavailable
        }
        try validatePreparedCard(card, compiledBrush: compiledBrush)
    }

    private func validatePreparedCard(
        _ card: BrushLabManualCard,
        compiledBrush: CompiledBrush
    ) throws {
        let expectedTool: EditorTool =
            card.tool == .erase ? .erase : .draw
        let expectedComposite: StrokeCompositeMode =
            card.tool == .erase ? .erase : .draw
        guard controller.renderer.documentConfiguration
                == card.documentConfiguration,
              controller.model.documentConfiguration
                == card.documentConfiguration,
              controller.model.tool == expectedTool,
              controller.model.inkColor == card.paintColor,
              controller.model.brushDiameter == card.diameter,
              packageContentHash
                == compiledBrush.renderIdentity.semanticHash,
              controller.renderer.preparedBrush(
                for: expectedComposite
              )?.renderIdentity == compiledBrush.renderIdentity
        else {
            throw BrushLabEvidenceError.manualCardStateMismatch(
                card.cardID
            )
        }
    }

    private static func traceHash(
        input: [BrushLabInputRecord],
        dabs: [BrushLabDabRecord]
    ) throws -> String {
        BrushContentHash.sha256Hex(
            of: try encodeSorted(
                BrushLabTraceIdentity(input: input, logicalDabs: dabs)
            )
        )
    }

    var selectedManualCard: BrushLabManualCard? {
        guard let selectedManualCardID else { return nil }
        return manualCards.first { $0.cardID == selectedManualCardID }
    }

    func clearError() {
        errorMessage = nil
    }

    func clearCompilationFailure() {
        compilationFailure = nil
    }

    func updateFrameMetrics(
        framesPerSecond: Double,
        p95FrameMilliseconds: Double,
        missedFramePercentage: Double,
        targetFramesPerSecond: Int,
        sampleCount: Int
    ) {
        frameMetrics.framesPerSecond = framesPerSecond
        frameMetrics.p95FrameMilliseconds = p95FrameMilliseconds
        frameMetrics.missedFramePercentage = missedFramePercentage
        frameMetrics.targetFramesPerSecond = targetFramesPerSecond
        frameMetrics.sampleCount = sampleCount
    }

    func recordRendererFrameMetrics(_ metrics: GPUFrameMetrics) {
        Self.appendBounded(
            metrics.cpuEncodeMilliseconds,
            to: &cpuEncodeSamples
        )
        Self.appendBounded(metrics.gpuMilliseconds, to: &gpuSamples)
        frameMetrics.cpuEncodeMilliseconds = metrics.cpuEncodeMilliseconds
        frameMetrics.gpuMilliseconds = metrics.gpuMilliseconds
        frameMetrics.p95CPUEncodeMilliseconds = Self.percentile95(
            cpuEncodeSamples
        )
        frameMetrics.p95GPUMilliseconds = Self.percentile95(gpuSamples)
        frameMetrics.rendererSampleCount = cpuEncodeSamples.count
    }

    func updateDepositionMetrics(_ metrics: DebugDepositionSnapshot) {
        depositionMetrics = metrics
    }

    func makeEvidenceData() throws -> Data {
        guard let package,
              let packageContentHash
        else {
            throw BrushLabEvidenceError.packageUnavailable
        }
        guard controller.renderer.isIdle else {
            throw BrushLabEvidenceError.rendererBusy
        }
        let snapshot = try controller.renderer.captureCommittedDocument()
        let bundle = BrushLabEvidenceBundle(
            package: .init(
                contentHash: packageContentHash,
                definitionID: package.definition.id.rawValue,
                displayName: package.definition.metadata.displayName,
                definitionSchemaVersion: package.definition.schemaVersion,
                manifestSchemaVersion: package.manifest.schemaVersion,
                resources: package.manifest.resources.map {
                    .init(
                        id: $0.id,
                        kind: $0.kind.rawValue,
                        mediaType: $0.mediaType,
                        sha256: $0.sha256,
                        encodedByteCount: $0.encodedByteCount,
                        pixelWidth: $0.pixelWidth,
                        pixelHeight: $0.pixelHeight
                    )
                }
            ),
            activeDrawingPackageContentHash:
                activeDrawingPackageContentHash,
            conversion: package.conversionReport.map {
                .init(
                    sourceFormat: $0.sourceFormat,
                    sourceVersion: $0.sourceVersion,
                    sourceContentHash: $0.sourceContentHash,
                    exact: $0.summary.exact,
                    approximated: $0.summary.approximated,
                    unsupported: $0.summary.unsupported,
                    resourceResampled: $0.summary.resourceResampled,
                    entries: $0.entries.map {
                        .init(
                            sourceSemanticKey: $0.sourceSemanticKey,
                            disposition: $0.disposition.rawValue,
                            reasonCode: $0.reasonCode,
                            message: $0.message
                        )
                    }
                )
            },
            compilation: compiledBrush.map {
                let report = $0.report
                return .init(
                    packageContentHash: report.packageContentHash,
                    backend: report.backend.rawValue,
                    pipelineAccumulation: $0.pipelineKey.accumulation.rawValue,
                    pipelineEdgeTreatment:
                        $0.pipelineKey.edgeTreatment.rawValue,
                    textureCount: $0.textures.count,
                    usesDestinationSampling:
                        $0.pipelineKey.functionConstants
                            .usesDestinationSampling,
                    performanceTier: report.performance.tier.rawValue,
                    performanceBasis: report.performance.basis.rawValue,
                    performanceReason: report.performance.reason,
                    encodedResourceBytes: report.encodedResourceBytes,
                    residentResourceBytes: report.residentResourceBytes,
                    deviceRegistryID: report.deviceRegistryID,
                    compatibility: report.compatibility.map {
                        .init(
                            semanticKey: $0.semanticKey,
                            level: $0.level.rawValue,
                            message: $0.message
                        )
                    },
                    diagnostics: compilationDiagnostics
                )
            },
            compilationFailure: compilationFailure.map {
                .init(
                    stage: $0.stage.rawValue,
                    backend: $0.backend.rawValue,
                    resourceID: $0.resourceID,
                    requestedBytes: $0.requestedBytes,
                    reason: $0.reason
                )
            },
            compiler: .init(compiler.diagnosticSnapshot),
            trace: .init(
                seed: deterministicSeed,
                inputs: inputRecords,
                dabs: dabRecords,
                droppedInputs: droppedInputRecordCount,
                droppedDabs: droppedDabRecordCount
            ),
            renderer: .init(controller.renderer.brushLabDiagnosticSnapshot),
            frame: frameMetrics,
            symmetry: .init(
                mode: String(
                    describing: controller.renderer.documentConfiguration
                ),
                canvasWidth: controller.renderer.pixelSize.width,
                canvasHeight: controller.renderer.pixelSize.height,
                gridVisible:
                controller.renderer.interactiveGridVisibility
            ),
            canvas: .init(
                contentHash: Self.canvasHash(snapshot),
                snapshot: snapshot
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return try encoder.encode(bundle)
    }

    func makeManualCardsData() throws -> Data {
        let bundle = BrushLabManualCatalog(
            cards: manualCards,
            assessments: manualCards.compactMap {
                manualAssessments[$0.cardID]
            }
        )
        return try bundle.encoded()
    }

    func makeProfessionalManualCardsData() throws -> Data {
        let bundle = BrushLabProfessionalManualCatalog(
            cards: professionalManualCards,
            assessments: professionalManualCards.compactMap {
                professionalManualAssessments[$0.cardID]
            }
        )
        return try bundle.encoded()
    }

    func makeManualEvidenceArchive() throws
        -> BrushLabManualEvidenceArchive
    {
        guard let card = selectedManualCard,
              let assessment = manualAssessments[card.cardID],
              let replay = completedReplay,
              replay.cardID == card.cardID
        else {
            throw BrushLabEvidenceError.completedReplayUnavailable
        }
        var imageFiles: [String: Data] = [:]
        switch replay.snapshot.storage {
        case let .singleRaster(bytes):
            imageFiles["canvas.png"] = try Self.evidencePNG(
                PatternRasterImage(
                    pixelSize: replay.snapshot.canvasSize,
                    bgra8PremultipliedBytes: bytes
                ),
                background: card.background
            )
        case let .radialPages(pages):
            for page in pages.sorted(by: {
                $0.coordinate < $1.coordinate
            }) {
                let name = "radial-\(page.coordinate.x)-"
                    + "\(page.coordinate.y).png"
                imageFiles[name] = try Self.evidencePNG(
                    PatternRasterImage(
                        pixelSize: PixelSize(
                            width: RadialSectorLayout.pageSide,
                            height: RadialSectorLayout.pageSide
                        ),
                        bgra8PremultipliedBytes:
                            page.bgra8PremultipliedBytes
                    ),
                    background: card.background
                )
            }
        }
        let identity = BrushLabManualEvidence.RenderIdentity(
            definitionID: replay.definitionID,
            semanticHash: replay.semanticHash,
            packageHash: replay.packageHash,
            pipelineKey: replay.pipelineKey,
            abiVersion: replay.abiVersion
        )
        let evidence = BrushLabManualEvidence(
            generationID: replay.generationID,
            cardID: card.cardID,
            card: card,
            assessment: assessment,
            renderIdentity: identity,
            inputOrigin: "synthetic",
            physicalDeviceStatus: .init(
                pencil: "pending",
                wacom: "pending"
            ),
            substrate: .init(
                kind: card.substrate.rawValue,
                inputCount: replay.substrateInputCount
            ),
            input: replay.input,
            logicalDabs: replay.logicalDabs,
            imageFiles: imageFiles.keys.sorted(),
            diagnostics: replay.diagnostics
        )
        var files = imageFiles
        files["evidence.json"] = try Self.encodeSorted(evidence)
        files["telemetry.json"] = try Self.encodeSorted(
            replay.diagnostics
        )
        return BrushLabManualEvidenceArchive(files: files)
    }

    private func prepareInspectionState() {
        package = nil
        sourceName = nil
        packageContentHash = nil
        compiledBrush = nil
        compilationReport = nil
        compilationDiagnostics = []
        drawingAvailability = .unloaded
        completedReplay = nil
        clearTrace()
        frameMetrics = BrushLabFrameMetrics()
        cpuEncodeSamples.removeAll(keepingCapacity: true)
        gpuSamples.removeAll(keepingCapacity: true)
    }

    private func record(_ sample: StrokeSample) {
        guard inputRecords.count < Self.maximumInputRecords else {
            droppedInputRecordCount += 1
            return
        }
        inputRecords.append(
            BrushLabInputRecord(
                sequence: inputRecords.count + droppedInputRecordCount,
                sample: sample
            )
        )
    }

    private func record(_ dab: LogicalDab) {
        guard dabRecords.count < Self.maximumDabRecords else {
            droppedDabRecordCount += 1
            return
        }
        dabRecords.append(
            BrushLabDabRecord(
                sequence: dabRecords.count + droppedDabRecordCount,
                dab: dab
            )
        )
    }

    private static func number(_ value: Float) -> String {
        String(format: "%.4g", value)
    }

    private static func appendBounded(
        _ value: Double,
        to samples: inout [Double]
    ) {
        let maximumSampleCount = 240
        if samples.count == maximumSampleCount {
            samples.removeFirst()
        }
        samples.append(value)
    }

    private static func percentile95(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = Int(
            ceil(Double(sorted.count) * 0.95)
        ) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    private static func mapping(_ value: BrushMappingDefinition) -> String {
        "\(value.input): \(value.response)"
    }

    private static func diagnosticDescription(
        _ diagnostic: BrushCompilationDiagnostic
    ) -> String {
        switch diagnostic {
        case let .resourceResampled(
            id,
            sourceWidth,
            sourceHeight,
            workingWidth,
            workingHeight
        ):
            "\(id) resampled \(sourceWidth)x\(sourceHeight) → "
                + "\(workingWidth)x\(workingHeight)"
        }
    }

    private static func canvasHash(
        _ snapshot: CommittedDocumentSnapshot
    ) -> String {
        var bytes = Data()
        switch snapshot.storage {
        case let .singleRaster(pixels):
            bytes.append(contentsOf: "singleRaster\0".utf8)
            bytes.append(contentsOf: pixels)
        case let .radialPages(pages):
            bytes.append(contentsOf: "radialPages\0".utf8)
            for page in pages.sorted(by: {
                $0.coordinate < $1.coordinate
            }) {
                bytes.append(
                    contentsOf:
                    "\(page.coordinate.x),\(page.coordinate.y)\0".utf8
                )
                bytes.append(contentsOf: page.bgra8PremultipliedBytes)
            }
        }
        return BrushContentHash.sha256Hex(of: bytes)
    }

    private func makeDiagnostics() -> BrushLabDiagnostics {
        let renderer = controller.renderer.brushLabDiagnosticSnapshot
        let deposition = renderer.deposition
        let textures = compiledBrush?.textures.map {
            BrushLabDiagnostics.Texture(
                id: $0.key,
                mipmapLevels: $0.value.mipmapLevelCount,
                residentBytes: $0.value.allocatedSize
            )
        }.sorted { $0.id < $1.id } ?? []
        return BrushLabDiagnostics(
            schemaVersion: 1,
            definitionHash: compiledBrush?.renderIdentity.semanticHash,
            packageHash: packageContentHash,
            pipelineKey: compiledBrush.map(Self.pipelineKey),
            abiVersion: compiledBrush?.depositionPipeline.key.abiVersion,
            textures: textures,
            residentResourceBytes:
                compiledBrush?.report.residentResourceBytes ?? 0,
            authoritativeBacklog: deposition.authoritativePending,
            predictedBacklog: deposition.predictedPending,
            backlogHighWater: deposition.backlogHighWater,
            encodedDabCount: deposition.strokeEncodedDabCount,
            encodedInstanceCount:
                deposition.strokeEncodedInstanceCount,
            rendererLogicalDabCount: renderer.totalDabsThisStroke,
            rendererProjectedInstanceCount:
                renderer.totalInstancesThisStroke,
            cpuPreparation: .init(deposition.cpuPreparation),
            eventToSubmit: .init(deposition.eventToSubmit),
            gpuCompletion: .init(deposition.gpuCompletion),
            missedFrameCount: depositionMetrics.missedFrameCount,
            missedFramePercentage: frameMetrics.missedFramePercentage,
            bufferHighWater: deposition.strokeBufferLeaseHighWater,
            bufferLifetimeHighWater:
                deposition.lifetimeBufferLeaseHighWater,
            lastFailureStage: compilationFailure?.stage.rawValue
        )
    }

    private static func pipelineKey(_ brush: CompiledBrush) -> String {
        let key = brush.depositionPipeline.key
        let constants = key.brush.functionConstants
        return [
            key.brush.backend.rawValue,
            key.brush.accumulation.rawValue,
            key.brush.edgeTreatment.rawValue,
            "shape2=\(constants.usesSecondaryShape)",
            "grain=\(constants.usesGrain)",
            "grain2=\(constants.usesSecondaryGrain)",
            "destination=\(constants.usesDestinationSampling)",
            "abi=\(key.abiVersion)",
            "format=\(key.colorPixelFormatRawValue)",
            "samples=\(key.sampleCount)",
        ].joined(separator: "|")
    }

    private static func encodeSorted<T: Encodable>(
        _ value: T
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return try encoder.encode(value)
    }

    private static func manualPackage(
        anchor: AnchorBrushEntry,
        customAsymmetric: Bool
    ) throws -> BrushPackage {
        guard customAsymmetric else {
            return try BrushPackage(
                manifest: BrushPackageManifest(resources: []),
                definition: anchor.definition,
                resourceData: [:]
            )
        }
        let grainID = "brush-lab.custom-asymmetric.grain"
        let shapeID = "brush-lab.custom-asymmetric.shape"
        let grainData = try asymmetricResourcePNG(seed: 173)
        let shapeData = try asymmetricResourcePNG(seed: 41)
        let resources = try [
            BrushPackageResource(
                id: grainID,
                kind: .grain,
                mediaType: "image/png",
                data: grainData,
                pixelWidth: 64,
                pixelHeight: 64
            ),
            BrushPackageResource(
                id: shapeID,
                kind: .shape,
                mediaType: "image/png",
                data: shapeData,
                pixelWidth: 64,
                pixelHeight: 64
            ),
        ]
        let references = [
            BrushResourceReference(
                identifier: grainID,
                kind: .grain,
                required: true,
                fallback: nil
            ),
            BrushResourceReference(
                identifier: shapeID,
                kind: .shape,
                required: true,
                fallback: nil
            ),
        ]
        let base = anchor.definition
        let definition = try BrushDefinition(
            id: base.id,
            schemaVersion: base.schemaVersion,
            metadata: base.metadata,
            capabilities: base.capabilities,
            resources: references,
            coverage: BrushCoverageDefinition(
                shapes: [
                    BrushShapeLayerDefinition(
                        shape: .asset(shapeID),
                        combination: .replace,
                        scale: 1,
                        rotation: 0.31,
                        offset: SIMD2(0.08, -0.06)
                    ),
                ],
                grains: [
                    BrushGrainLayerDefinition(
                        grain: .asset(grainID),
                        coordinateMode: .canonical,
                        transform: BrushGrainTransform(
                            scale: 0.12,
                            rotation: 0.23,
                            offset: SIMD2(0.11, -0.07)
                        ),
                        grainMovementFraction: 0.12,
                        grainFollowsBrushRotation: true,
                        strength: 0.68
                    ),
                ],
                baseHardness: base.coverage.baseHardness,
                aspectRatio: 0.63,
                tipThreshold: base.coverage.tipThreshold,
                antialiasing: base.coverage.antialiasing
            ),
            placement: base.placement,
            dynamics: base.dynamics,
            color: base.color,
            material: base.material,
            stabilization: base.stabilization,
            taper: base.taper,
            replayMode: base.replayMode,
            replayLimits: base.replayLimits,
            seedPolicy: base.seedPolicy,
            limits: base.limits,
            performanceIntent: base.performanceIntent,
            compatibility: base.compatibility
        )
        return try BrushPackage(
            manifest: BrushPackageManifest(resources: resources),
            definition: definition,
            resourceData: [
                grainID: grainData,
                shapeID: shapeData,
            ]
        )
    }

    private static func asymmetricResourcePNG(seed: UInt8) throws -> Data {
        let side = 64
        var bytes: [UInt8] = []
        bytes.reserveCapacity(side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let diagonal = x > y / 2 && x < 52 && y < 58
                let notch = x > 35 && y > 30
                let stripe = ((x * 3 + y * 5 + Int(seed)) % 17) < 8
                let value: UInt8 =
                    diagonal && !notch && stripe ? 255 : 18
                bytes.append(contentsOf: [value, value, value, 255])
            }
        }
        return try PatternRasterPNGCodec.encode(
            PatternRasterImage(
                pixelSize: PixelSize(width: side, height: side),
                bgra8PremultipliedBytes: bytes
            )
        )
    }

    private static func evidencePNG(
        _ image: PatternRasterImage,
        background: BrushLabManualBackground
    ) throws -> Data {
        guard background == .opaque else {
            return try PatternRasterPNGCodec.encode(image)
        }
        var bytes = image.bgra8PremultipliedBytes
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let inverseAlpha = UInt16(255 - bytes[offset + 3])
            for channel in 0..<3 {
                let value = UInt16(bytes[offset + channel])
                    + (255 * inverseAlpha + 127) / 255
                bytes[offset + channel] = UInt8(min(255, value))
            }
            bytes[offset + 3] = 255
        }
        return try PatternRasterPNGCodec.encode(
            PatternRasterImage(
                pixelSize: image.pixelSize,
                bgra8PremultipliedBytes: bytes
            )
        )
    }
}

private struct BrushLabTraceIdentity: Encodable {
    let input: [BrushLabInputRecord]
    let logicalDabs: [BrushLabDabRecord]
}

struct BrushLabDiagnostics: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let definitionHash: String?
    let packageHash: String?
    let pipelineKey: String?
    let abiVersion: UInt16?
    let textures: [Texture]
    let residentResourceBytes: Int
    let authoritativeBacklog: Int
    let predictedBacklog: Int
    let backlogHighWater: Int
    let encodedDabCount: UInt64
    let encodedInstanceCount: UInt64
    let rendererLogicalDabCount: Int
    let rendererProjectedInstanceCount: Int
    let cpuPreparation: DebugDurationPercentiles
    let eventToSubmit: DebugDurationPercentiles
    let gpuCompletion: DebugDurationPercentiles
    let missedFrameCount: UInt64
    let missedFramePercentage: Double
    let bufferHighWater: Int
    let bufferLifetimeHighWater: Int
    let lastFailureStage: String?

    struct Texture: Codable, Equatable, Sendable {
        let id: String
        let mipmapLevels: Int
        let residentBytes: Int
    }
}

private struct BrushLabManualEvidence: Encodable {
    let schemaVersion: UInt16 = 1
    let generationID: String
    let cardID: String
    let card: BrushLabManualCard
    let assessment: BrushLabManualAssessment
    let renderIdentity: RenderIdentity
    let inputOrigin: String
    let physicalDeviceStatus: PhysicalDeviceStatus
    let substrate: Substrate
    let input: [BrushLabInputRecord]
    let logicalDabs: [BrushLabDabRecord]
    let imageFiles: [String]
    let diagnostics: BrushLabDiagnostics

    struct RenderIdentity: Encodable {
        let definitionID: String
        let semanticHash: String
        let packageHash: String
        let pipelineKey: String
        let abiVersion: UInt16
    }

    struct PhysicalDeviceStatus: Encodable {
        let pencil: String
        let wacom: String
    }

    struct Substrate: Encodable {
        let kind: String
        let inputCount: Int
    }
}

struct BrushLabManualEvidenceArchive {
    let files: [String: Data]

    func writeAtomically(to destination: URL) throws {
        try BrushLabManualEvidenceSaveService.live.save(
            self,
            to: destination
        )
    }
}

struct BrushLabManualEvidenceSaveService: Sendable {
    typealias EntryWriter = @Sendable (Data, URL) throws -> Void

    static let live = BrushLabManualEvidenceSaveService {
        try $0.write(to: $1, options: .atomic)
    }

    private let writeEntry: EntryWriter

    init(_ writeEntry: @escaping EntryWriter) {
        self.writeEntry = writeEntry
    }

    func save(
        _ archive: BrushLabManualEvidenceArchive,
        to destination: URL
    ) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(
            atPath: parent.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw BrushLabEvidenceError.archiveParentUnavailable
        }
        guard archive.files.keys.allSatisfy({
            !$0.isEmpty
                && !$0.contains("/")
                && $0 != "."
                && $0 != ".."
        }) else {
            throw BrushLabEvidenceError.invalidArchivePath
        }
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(
            at: temporary,
            withIntermediateDirectories: false
        )
        var moved = false
        defer {
            if !moved {
                try? manager.removeItem(at: temporary)
            }
        }
        for name in archive.files.keys.sorted() {
            try writeEntry(
                archive.files[name]!,
                temporary.appendingPathComponent(name)
            )
        }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(
                destination,
                withItemAt: temporary
            )
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
        moved = true
    }
}

/// Writes the Stage 5 professional review catalog through the same session
/// that owns its fixed cards and user-owned assessments. UI surfaces use this
/// coordinator instead of directly serializing the catalog.
struct BrushLabProfessionalMatrixExportCoordinator: Sendable {
    typealias Writer = @Sendable (Data, URL) throws -> Void

    static let live = BrushLabProfessionalMatrixExportCoordinator {
        try $0.write(to: $1, options: .atomic)
    }

    private let write: Writer

    init(write: @escaping Writer) {
        self.write = write
    }

    @MainActor
    func data(from session: BrushLabSession) throws -> Data {
        try session.makeProfessionalManualCardsData()
    }

    @MainActor
    func export(_ session: BrushLabSession, to destination: URL) throws {
        try write(data(from: session), destination)
    }
}

enum BrushLabEvidenceError: Error, Equatable, LocalizedError {
    case packageUnavailable
    case rendererBusy
    case manualCardNotSelected
    case completedReplayUnavailable
    case manualCardUnavailable(String)
    case manualBrushUnavailable(String)
    case manualResourceFixtureUnavailable(String)
    case manualDiameterUnavailable(Float)
    case manualCardStateMismatch(String)
    case documentConfigurationUnavailable
    case archiveParentUnavailable
    case invalidArchivePath

    var errorDescription: String? {
        switch self {
        case .packageUnavailable:
            "Load a native .layabrush package before exporting evidence."
        case .rendererBusy:
            "Finish or cancel the active canvas operation first."
        case .manualCardNotSelected:
            "Select a Brush Lab manual card first."
        case .completedReplayUnavailable:
            "Replay the selected Brush Lab card to completion before export."
        case let .manualCardUnavailable(cardID):
            "Brush Lab manual card '\(cardID)' is unavailable."
        case let .manualBrushUnavailable(brushID):
            "Brush Lab brush '\(brushID)' is unavailable."
        case let .manualResourceFixtureUnavailable(fixture):
            "Brush Lab resource fixture '\(fixture)' is unavailable."
        case let .manualDiameterUnavailable(diameter):
            "Brush Lab diameter \(diameter) is unavailable."
        case let .manualCardStateMismatch(cardID):
            "Brush Lab card '\(cardID)' no longer matches renderer state."
        case .documentConfigurationUnavailable:
            "Clear the document before changing the manual-card projection."
        case .archiveParentUnavailable:
            "The Brush Lab evidence destination parent is unavailable."
        case .invalidArchivePath:
            "Brush Lab evidence contains an invalid archive path."
        }
    }
}

private struct BrushLabEvidenceBundle: Encodable {
    let schemaVersion = 1
    let package: Package
    let activeDrawingPackageContentHash: String?
    let conversion: Conversion?
    let compilation: Compilation?
    let compilationFailure: CompilationFailure?
    let compiler: Compiler
    let trace: Trace
    let renderer: Renderer
    let frame: BrushLabFrameMetrics
    let symmetry: Symmetry
    let canvas: Canvas

    struct Package: Encodable {
        let contentHash: String
        let definitionID: String
        let displayName: String
        let definitionSchemaVersion: UInt16
        let manifestSchemaVersion: UInt16
        let resources: [Resource]
    }

    struct Resource: Encodable {
        let id: String
        let kind: String
        let mediaType: String
        let sha256: String
        let encodedByteCount: Int
        let pixelWidth: Int
        let pixelHeight: Int
    }

    struct Conversion: Encodable {
        let sourceFormat: String
        let sourceVersion: String?
        let sourceContentHash: String
        let exact: Int
        let approximated: Int
        let unsupported: Int
        let resourceResampled: Int
        let entries: [ConversionEntry]
    }

    struct ConversionEntry: Encodable {
        let sourceSemanticKey: String
        let disposition: String
        let reasonCode: String
        let message: String
    }

    struct Compilation: Encodable {
        let packageContentHash: String
        let backend: String
        let pipelineAccumulation: String
        let pipelineEdgeTreatment: String
        let textureCount: Int
        let usesDestinationSampling: Bool
        let performanceTier: String
        let performanceBasis: String
        let performanceReason: String
        let encodedResourceBytes: Int
        let residentResourceBytes: Int
        let deviceRegistryID: UInt64
        let compatibility: [Compatibility]
        let diagnostics: [String]
    }

    struct Compatibility: Encodable {
        let semanticKey: String
        let level: String
        let message: String
    }

    struct CompilationFailure: Encodable {
        let stage: String
        let backend: String
        let resourceID: String?
        let requestedBytes: Int?
        let reason: String
    }

    struct Compiler: Encodable {
        let packageDecodeCount: UInt64
        let imageDecodeCount: UInt64
        let textureUploadCount: UInt64
        let cacheHitCount: UInt64
        let activationCount: UInt64
        let cacheResidentBytes: Int
        let cacheBudgetBytes: Int
        let cachedResourceCount: Int
        let pinnedResourceCount: Int
        let activeDefinitionID: String?

        init(_ snapshot: BrushCompilerDiagnosticSnapshot) {
            let counters = snapshot.counters
            packageDecodeCount = counters.packageDecodeCount
            imageDecodeCount = counters.imageDecodeCount
            textureUploadCount = counters.textureUploadCount
            cacheHitCount = counters.cacheHitCount
            activationCount = counters.activationCount
            cacheResidentBytes = snapshot.cacheResidentBytes
            cacheBudgetBytes = snapshot.cacheBudgetBytes
            cachedResourceCount = snapshot.cachedResourceCount
            pinnedResourceCount = snapshot.pinnedResourceCount
            activeDefinitionID = snapshot.activeDefinitionID
        }
    }

    struct Trace: Encodable {
        let seed: UInt64
        let inputs: [BrushLabInputRecord]
        let dabs: [BrushLabDabRecord]
        let droppedInputs: Int
        let droppedDabs: Int
    }

    struct Renderer: Encodable {
        let totalDabsThisStroke: Int
        let totalInstancesThisStroke: Int
        let renderedFramesThisStroke: Int
        let actualDabCount: Int
        let predictedDabCount: Int
        let replayCount: UInt64
        let dirtyRegionCount: Int
        let rasterRevisionResidentBytes: Int
        let builtInTextureCount: Int
        let assetFallbackCount: Int

        init(_ snapshot: BrushLabRendererDiagnosticSnapshot) {
            totalDabsThisStroke = snapshot.totalDabsThisStroke
            totalInstancesThisStroke = snapshot.totalInstancesThisStroke
            renderedFramesThisStroke = snapshot.renderedFramesThisStroke
            actualDabCount = snapshot.actualDabCount
            predictedDabCount = snapshot.predictedDabCount
            replayCount = snapshot.replayCount
            dirtyRegionCount = snapshot.dirtyRegionCount
            rasterRevisionResidentBytes =
                snapshot.rasterRevisionResidentBytes
            builtInTextureCount = snapshot.builtInTextureCount
            assetFallbackCount = snapshot.assetFallbackCount
        }
    }

    struct Symmetry: Encodable {
        let mode: String
        let canvasWidth: Int
        let canvasHeight: Int
        let gridVisible: Bool
    }

    struct Canvas: Encodable {
        let contentHash: String
        let storage: String
        let pixelFormat: String
        let width: Int
        let height: Int
        let singleRasterBGRA8Base64: String?
        let radialPages: [RadialPage]

        init(
            contentHash: String,
            snapshot: CommittedDocumentSnapshot
        ) {
            self.contentHash = contentHash
            pixelFormat = "bgra8Unorm-premultiplied"
            width = snapshot.canvasSize.width
            height = snapshot.canvasSize.height
            switch snapshot.storage {
            case let .singleRaster(bytes):
                storage = "singleRaster"
                singleRasterBGRA8Base64 = Data(bytes).base64EncodedString()
                radialPages = []
            case let .radialPages(pages):
                storage = "radialPages"
                singleRasterBGRA8Base64 = nil
                radialPages = pages.sorted {
                    $0.coordinate < $1.coordinate
                }.map {
                    RadialPage(
                        x: $0.coordinate.x,
                        y: $0.coordinate.y,
                        bgra8Base64: Data(
                            $0.bgra8PremultipliedBytes
                        ).base64EncodedString()
                    )
                }
            }
        }
    }

    struct RadialPage: Encodable {
        let x: Int
        let y: Int
        let bgra8Base64: String
    }
}
#endif
