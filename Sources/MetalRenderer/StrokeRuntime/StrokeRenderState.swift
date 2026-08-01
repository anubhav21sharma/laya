import Metal
import PatternEngine

/// The only unchecked sendability boundary in compiled brush state. Metal
/// resource protocols do not declare `Sendable`, but these references are
/// immutable after compilation and are only dereferenced by renderer encoding
/// code on its owning executor.
public final class CompiledBrushMetalResourceHolder: @unchecked Sendable {
    @MainActor public let depositionPipeline: DepositionPipelineBinding
    @MainActor public let depositionMaterial: DepositionMaterialBinding
    @MainActor public let textures: [String: any MTLTexture]

    @MainActor
    fileprivate init(compiledBrush: CompiledBrush) {
        depositionPipeline = compiledBrush.depositionPipeline
        depositionMaterial = compiledBrush.depositionMaterial
        textures = compiledBrush.textures
    }
}

/// Immutable, sendable brush state captured once at pointer-down.
public struct CompiledBrushRenderState: Sendable {
    public let program: BrushProgram
    public let renderIdentity: BrushRenderIdentity
    public let pipelineKey: BrushPipelineKey
    public let uniformTemplate: BrushUniformTemplate
    public let resources: CompiledBrushMetalResourceHolder
    public let residentByteCount: Int
    public let report: BrushCompilationReport
    public let diagnostics: [BrushCompilationDiagnostic]

    @MainActor
    public init(compiledBrush: CompiledBrush) {
        program = compiledBrush.program
        renderIdentity = compiledBrush.renderIdentity
        pipelineKey = compiledBrush.pipelineKey
        uniformTemplate = compiledBrush.uniformTemplate
        resources = CompiledBrushMetalResourceHolder(
            compiledBrush: compiledBrush
        )
        residentByteCount = compiledBrush.residentByteCount
        report = compiledBrush.report
        diagnostics = compiledBrush.diagnostics
    }
}

@MainActor
extension CompiledBrush {
    public var renderState: CompiledBrushRenderState {
        CompiledBrushRenderState(compiledBrush: self)
    }
}

public struct StrokeCommitMetadata: Equatable, Sendable {
    public internal(set) var inputSampleCount: UInt64 = 0
    public internal(set) var emittedDabCount: UInt64 = 0
    public internal(set) var submittedDabCount: UInt64 = 0
    public internal(set) var lastEmittedOrdinal: UInt64?

    public init() {}
}

public struct StrokeRenderSnapshot: Equatable, Sendable {
    public let authoritativeQueueDepth: Int
    public let authoritativeQueueHighWater: Int
    public let authoritativeSubmittedDabCount: UInt64
    public let maximumReturnedDabCount: Int
    public let retainedCompletedDabCount: Int
    public let commitMetadata: StrokeCommitMetadata

    public init(
        authoritativeQueueDepth: Int,
        authoritativeQueueHighWater: Int,
        authoritativeSubmittedDabCount: UInt64,
        maximumReturnedDabCount: Int,
        retainedCompletedDabCount: Int,
        commitMetadata: StrokeCommitMetadata
    ) {
        self.authoritativeQueueDepth = authoritativeQueueDepth
        self.authoritativeQueueHighWater = authoritativeQueueHighWater
        self.authoritativeSubmittedDabCount =
            authoritativeSubmittedDabCount
        self.maximumReturnedDabCount = maximumReturnedDabCount
        self.retainedCompletedDabCount = retainedCompletedDabCount
        self.commitMetadata = commitMetadata
    }
}

struct StrokeCoordinatorGeneratedSample: Sendable {
    let sample: WorldStrokeSample
    let dabs: [LogicalDab]
    let generatorBefore: BrushStrokeGenerator
    let generatorAfter: BrushStrokeGenerator
    let inputDeriverBefore: BrushInputDeriver
}

public struct StrokeCoordinatorEmission: Sendable {
    public let work: [AuthoritativeStrokeWork]
    let generatedSamples: [StrokeCoordinatorGeneratedSample]

    init(
        work: [AuthoritativeStrokeWork],
        generatedSamples: [StrokeCoordinatorGeneratedSample]
    ) {
        self.work = work
        self.generatedSamples = generatedSamples
    }

}
