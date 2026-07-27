import Metal
import PatternEngine

public struct BrushFunctionConstants: Equatable, Hashable, Sendable {
    public let usesSecondaryShape: Bool
    public let usesGrain: Bool
    public let usesSecondaryGrain: Bool
    public let usesDestinationSampling: Bool

    public init(
        usesSecondaryShape: Bool,
        usesGrain: Bool,
        usesSecondaryGrain: Bool,
        usesDestinationSampling: Bool
    ) {
        self.usesSecondaryShape = usesSecondaryShape
        self.usesGrain = usesGrain
        self.usesSecondaryGrain = usesSecondaryGrain
        self.usesDestinationSampling = usesDestinationSampling
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

/// Immutable render-time brush state. `textures` deliberately retains its GPU
/// resources even if the compiler later evicts its own cache references.
/// Residency therefore measures compiler-owned references, not guaranteed
/// physical deallocation while callers retain older compiled brushes.
@MainActor
public final class CompiledBrush {
    public let program: BrushProgram
    public let pipelineKey: BrushPipelineKey
    public let uniformTemplate: BrushUniformTemplate
    public let textures: [String: any MTLTexture]
    public let residentByteCount: Int
    public let report: BrushCompilationReport
    public let diagnostics: [BrushCompilationDiagnostic]

    let cacheKeys: Set<String>

    init(
        program: BrushProgram,
        pipelineKey: BrushPipelineKey,
        uniformTemplate: BrushUniformTemplate,
        textures: [String: any MTLTexture],
        residentByteCount: Int,
        report: BrushCompilationReport,
        diagnostics: [BrushCompilationDiagnostic],
        cacheKeys: Set<String>
    ) {
        self.program = program
        self.pipelineKey = pipelineKey
        self.uniformTemplate = uniformTemplate
        self.textures = textures
        self.residentByteCount = residentByteCount
        self.report = report
        self.diagnostics = diagnostics
        self.cacheKeys = cacheKeys
    }
}
