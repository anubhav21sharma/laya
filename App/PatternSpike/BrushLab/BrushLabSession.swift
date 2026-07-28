#if DEBUG
import BrushFormat
import Foundation
import MetalRenderer
import Observation
import PatternEngine

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
    case compilerOnly(String)
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

@MainActor
@Observable
final class BrushLabSession {
    static let maximumInputRecords = 4_096
    static let maximumDabRecords = 16_384

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
        controller.renderer.onLogicalDabsGenerated = { [weak self] dabs in
            self?.record(dabs)
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
            let compiled = try await compiler.compileAndActivate(
                package: package
            )
            compiledBrush = compiled
            compilationReport = compiled.report
            compilationDiagnostics = compiled.diagnostics.map(
                Self.diagnosticDescription
            )
            if compiled.program.requestedBackend == .deposition {
                try controller.installDiagnosticDrawBrush(compiled)
                activeDrawingPackageContentHash = contentHash
                drawingAvailability = .available
            } else {
                drawingAvailability = .compilerOnly(
                    "This package requires typed canvas interaction, which "
                        + "the production deposition renderer does not support. "
                        + "The previous drawing brush remains active."
                )
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

    func clearError() {
        errorMessage = nil
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

    private func prepareInspectionState() {
        package = nil
        sourceName = nil
        packageContentHash = nil
        compiledBrush = nil
        compilationReport = nil
        compilationFailure = nil
        compilationDiagnostics = []
        drawingAvailability = .unloaded
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

    private func record(_ dabs: [LogicalDab]) {
        for dab in dabs {
            guard dabRecords.count < Self.maximumDabRecords else {
                droppedDabRecordCount += 1
                continue
            }
            dabRecords.append(
                BrushLabDabRecord(
                    sequence: dabRecords.count + droppedDabRecordCount,
                    dab: dab
                )
            )
        }
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
}

enum BrushLabEvidenceError: Error, Equatable, LocalizedError {
    case packageUnavailable
    case rendererBusy

    var errorDescription: String? {
        switch self {
        case .packageUnavailable:
            "Load a native .layabrush package before exporting evidence."
        case .rendererBusy:
            "Finish or cancel the active canvas operation first."
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
