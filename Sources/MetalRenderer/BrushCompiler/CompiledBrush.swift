import Metal
import PatternEngine

public struct CompiledDepositionBackendContract: Equatable, Sendable {
    public let schemaVersion: UInt16
    public let compilerFamily: BrushBackendCompilerFamily
    public let encoderFamily: BrushBackendEncoderFamily

    init(registration: BrushBackendRegistration) {
        schemaVersion = registration.key.schemaVersion
        compilerFamily = registration.compilerFamily
        encoderFamily = registration.encoderFamily
    }
}

public struct CompiledCanvasInteractionBackendContract:
    Equatable, Sendable
{
    public let schemaVersion: UInt16
    public let compilerFamily: BrushBackendCompilerFamily
    public let encoderFamily: BrushBackendEncoderFamily
    public let usesDestinationSampling: Bool

    init(registration: BrushBackendRegistration) {
        schemaVersion = registration.key.schemaVersion
        compilerFamily = registration.compilerFamily
        encoderFamily = registration.encoderFamily
        usesDestinationSampling = registration.declaredCapabilities.contains(
            .destinationSampling
        )
    }
}

public enum CompiledBrushBackendContract: Equatable, Sendable {
    case deposition(CompiledDepositionBackendContract)
    case canvasInteraction(CompiledCanvasInteractionBackendContract)
}

public struct BrushFunctionConstants: Equatable, Hashable, Sendable {
    public let usesSecondaryShape: Bool
    public let usesGrain: Bool
    public let usesSecondaryGrain: Bool

    public init(
        usesSecondaryShape: Bool,
        usesGrain: Bool,
        usesSecondaryGrain: Bool
    ) {
        self.usesSecondaryShape = usesSecondaryShape
        self.usesGrain = usesGrain
        self.usesSecondaryGrain = usesSecondaryGrain
    }
}

public struct BrushPipelineKey: Hashable, Sendable {
    public let backend: BrushBackendKind
    public let accumulation: BrushAccumulationMode
    public let edgeTreatment: BrushEdgeTreatment
    public let functionConstants: BrushFunctionConstants

    public init(
        backend: BrushBackendKind,
        accumulation: BrushAccumulationMode,
        edgeTreatment: BrushEdgeTreatment,
        functionConstants: BrushFunctionConstants
    ) {
        self.backend = backend
        self.accumulation = accumulation
        self.edgeTreatment = edgeTreatment
        self.functionConstants = functionConstants
    }
}

public struct BrushUniformTemplate: Equatable, Sendable {
    public let placement: BrushPlacementDefinition
    public let coverage: BrushCoverageDefinition
    public let color: BrushColorBehaviorDefinition
    public let material: BrushMaterialDefinition

    public init(
        placement: BrushPlacementDefinition,
        coverage: BrushCoverageDefinition,
        color: BrushColorBehaviorDefinition,
        material: BrushMaterialDefinition
    ) {
        self.placement = placement
        self.coverage = coverage
        self.color = color
        self.material = material
    }
}

public struct BrushCompilerCounters: Equatable, Sendable {
    public let packageDecodeCount: UInt64
    public let imageDecodeCount: UInt64
    public let textureUploadCount: UInt64
    public let cacheHitCount: UInt64
    public let activationCount: UInt64

    public init(
        packageDecodeCount: UInt64,
        imageDecodeCount: UInt64,
        textureUploadCount: UInt64,
        cacheHitCount: UInt64,
        activationCount: UInt64
    ) {
        self.packageDecodeCount = packageDecodeCount
        self.imageDecodeCount = imageDecodeCount
        self.textureUploadCount = textureUploadCount
        self.cacheHitCount = cacheHitCount
        self.activationCount = activationCount
    }

    public static let zero = BrushCompilerCounters(
        packageDecodeCount: 0,
        imageDecodeCount: 0,
        textureUploadCount: 0,
        cacheHitCount: 0,
        activationCount: 0
    )
}

public struct BrushCompilerDiagnosticSnapshot: Equatable, Sendable {
    public let counters: BrushCompilerCounters
    public let cacheResidentBytes: Int
    public let cacheBudgetBytes: Int
    public let cachedResourceCount: Int
    public let pinnedResourceCount: Int
    public let activeDefinitionID: String?

    public init(
        counters: BrushCompilerCounters,
        cacheResidentBytes: Int,
        cacheBudgetBytes: Int,
        cachedResourceCount: Int,
        pinnedResourceCount: Int,
        activeDefinitionID: String?
    ) {
        self.counters = counters
        self.cacheResidentBytes = cacheResidentBytes
        self.cacheBudgetBytes = cacheBudgetBytes
        self.cachedResourceCount = cachedResourceCount
        self.pinnedResourceCount = pinnedResourceCount
        self.activeDefinitionID = activeDefinitionID
    }
}

public enum CompiledBrushTipSource: Equatable, Sendable {
    case analyticEllipse
    case analyticRectangle
    case texture(resourceID: String)
}

public struct CompiledBrushTipSupport: Equatable, Sendable {
    public let semanticTipHash: String
    public let source: CompiledBrushTipSource
    public let definition: BrushTipSupportDefinition
    public let assetSupport: BrushTipAssetSupport?
    public let sourceWidth: Int?
    public let sourceHeight: Int?
    public let mipLevelCount: Int

    public func levelOfDetail(
        projectedWidth: Float,
        projectedHeight: Float
    ) -> Float? {
        guard let sourceWidth, let sourceHeight, mipLevelCount > 0 else {
            return nil
        }
        return try? BrushTipMipSelector.levelOfDetail(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            projectedWidth: projectedWidth,
            projectedHeight: projectedHeight,
            mipLevelCount: mipLevelCount
        )
    }
}

/// Immutable render-time brush state. `textures` deliberately retains its GPU
/// resources even if the compiler later evicts its own cache references.
/// Residency therefore measures compiler-owned references, not guaranteed
/// physical deallocation while callers retain older compiled brushes.
@MainActor
public struct CompiledBrushComponent {
    public let identifier: BrushComponentIdentifier
    public let ordinal: UInt8
    public let pipelineKey: BrushPipelineKey
    public let uniformTemplate: BrushUniformTemplate
    public let textures: [String: any MTLTexture]
    public let tipSupports: [CompiledBrushTipSupport]
    public let cursorTipProfile: BrushCursorTipProfile
    public let depositionPipeline: DepositionPipelineBinding
    public let depositionMaterial: DepositionMaterialBinding

    init(
        identifier: BrushComponentIdentifier,
        ordinal: UInt8,
        pipelineKey: BrushPipelineKey,
        uniformTemplate: BrushUniformTemplate,
        textures: [String: any MTLTexture],
        tipSupports: [CompiledBrushTipSupport],
        cursorTipProfile: BrushCursorTipProfile,
        depositionPipeline: DepositionPipelineBinding,
        depositionMaterial: DepositionMaterialBinding
    ) {
        self.identifier = identifier
        self.ordinal = ordinal
        self.pipelineKey = pipelineKey
        self.uniformTemplate = uniformTemplate
        self.textures = textures
        self.tipSupports = tipSupports
        self.cursorTipProfile = cursorTipProfile
        self.depositionPipeline = depositionPipeline
        self.depositionMaterial = depositionMaterial
    }
}

@MainActor
public final class CompiledBrush {
    public let program: BrushProgram
    public let backendContract: CompiledBrushBackendContract
    public let renderIdentity: BrushRenderIdentity
    public let primaryComponent: CompiledBrushComponent
    public let secondaryComponent: CompiledBrushComponent?
    public let residentByteCount: Int
    public let report: BrushCompilationReport
    public let diagnostics: [BrushCompilationDiagnostic]

    package let cacheKeys: Set<String>

    init(
        program: BrushProgram,
        backendContract: CompiledBrushBackendContract,
        renderIdentity: BrushRenderIdentity,
        primaryComponent: CompiledBrushComponent,
        secondaryComponent: CompiledBrushComponent?,
        residentByteCount: Int,
        report: BrushCompilationReport,
        diagnostics: [BrushCompilationDiagnostic],
        cacheKeys: Set<String>
    ) {
        self.program = program
        self.backendContract = backendContract
        self.renderIdentity = renderIdentity
        self.primaryComponent = primaryComponent
        self.secondaryComponent = secondaryComponent
        self.residentByteCount = residentByteCount
        self.report = report
        self.diagnostics = diagnostics
        self.cacheKeys = cacheKeys
    }

    init(
        program: BrushProgram,
        backendContract: CompiledBrushBackendContract,
        renderIdentity: BrushRenderIdentity,
        pipelineKey: BrushPipelineKey,
        uniformTemplate: BrushUniformTemplate,
        textures: [String: any MTLTexture],
        tipSupports: [CompiledBrushTipSupport] = [],
        cursorTipProfile: BrushCursorTipProfile,
        depositionPipeline: DepositionPipelineBinding,
        depositionMaterial: DepositionMaterialBinding,
        residentByteCount: Int,
        report: BrushCompilationReport,
        diagnostics: [BrushCompilationDiagnostic],
        cacheKeys: Set<String>
    ) {
        self.program = program
        self.backendContract = backendContract
        self.renderIdentity = renderIdentity
        primaryComponent = CompiledBrushComponent(
            identifier: program.primaryComponent.definition.identifier,
            ordinal: program.primaryComponent.definition.ordinal,
            pipelineKey: pipelineKey,
            uniformTemplate: uniformTemplate,
            textures: textures,
            tipSupports: tipSupports,
            cursorTipProfile: cursorTipProfile,
            depositionPipeline: depositionPipeline,
            depositionMaterial: depositionMaterial
        )
        secondaryComponent = nil
        self.residentByteCount = residentByteCount
        self.report = report
        self.diagnostics = diagnostics
        self.cacheKeys = cacheKeys
    }

    public func cursorDescriptor(
        input: BrushCursorInput
    ) throws -> BrushCursorDescriptor {
        try BrushCursorDescriptor.evaluate(
            program: program,
            primaryProfile: primaryComponent.cursorTipProfile,
            secondaryProfile: secondaryComponent?.cursorTipProfile,
            input: input
        )
    }
}
