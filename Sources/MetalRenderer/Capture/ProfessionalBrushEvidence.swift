import Foundation

public struct ProfessionalBrushResolvedResource:
    Codable, Equatable, Sendable
{
    public let identity: String
    public let kind: String
    public let mipCount: Int

    public init(identity: String, kind: String, mipCount: Int) {
        self.identity = identity
        self.kind = kind
        self.mipCount = mipCount
    }
}
public struct ProfessionalBrushCompilerCounterSnapshot:
    Codable, Equatable, Sendable
{
    public let packageDecodeCount: UInt64
    public let imageDecodeCount: UInt64
    public let textureUploadCount: UInt64
    public let cacheHitCount: UInt64
    public let activationCount: UInt64

    public static let zero = ProfessionalBrushCompilerCounterSnapshot(
        packageDecodeCount: 0,
        imageDecodeCount: 0,
        textureUploadCount: 0,
        cacheHitCount: 0,
        activationCount: 0
    )

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

    init(_ counters: BrushCompilerCounters) {
        self.init(
            packageDecodeCount: counters.packageDecodeCount,
            imageDecodeCount: counters.imageDecodeCount,
            textureUploadCount: counters.textureUploadCount,
            cacheHitCount: counters.cacheHitCount,
            activationCount: counters.activationCount
        )
    }
}

public struct ProfessionalBrushCompilerCounterEvidence:
    Codable, Equatable, Sendable
{
    public let beforeCompile: ProfessionalBrushCompilerCounterSnapshot
    public let afterCompile: ProfessionalBrushCompilerCounterSnapshot
    public let afterCacheHit: ProfessionalBrushCompilerCounterSnapshot
    public let beforeStroke: ProfessionalBrushCompilerCounterSnapshot
    public let afterStroke: ProfessionalBrushCompilerCounterSnapshot

    public init(
        beforeCompile: ProfessionalBrushCompilerCounterSnapshot,
        afterCompile: ProfessionalBrushCompilerCounterSnapshot,
        afterCacheHit: ProfessionalBrushCompilerCounterSnapshot,
        beforeStroke: ProfessionalBrushCompilerCounterSnapshot,
        afterStroke: ProfessionalBrushCompilerCounterSnapshot
    ) {
        self.beforeCompile = beforeCompile
        self.afterCompile = afterCompile
        self.afterCacheHit = afterCacheHit
        self.beforeStroke = beforeStroke
        self.afterStroke = afterStroke
    }
}

public struct ProfessionalBrushInvariantObservations:
    Codable, Equatable, Sendable
{
    public let liveBGRA8SHA256: String
    public let committedBGRA8SHA256: String
    public let canonicalBGRA8SHA256: String
    public let liveNontransparentPixelCount: Int
    public let committedNontransparentPixelCount: Int
    public let canonicalNontransparentPixelCount: Int
    public let predictionOffBGRA8SHA256: String
    public let predictionOnBGRA8SHA256: String
    public let predictionMaximumChannelDelta: UInt8
    public let gridOriginBGRA8SHA256: String
    public let gridTranslatedBGRA8SHA256: String
    public let gridMaximumChannelDelta: UInt8
    public let eraserBeforeBGRA8SHA256: String
    public let eraserAfterBGRA8SHA256: String
    public let eraserBeforeNontransparentPixelCount: Int
    public let eraserAfterNontransparentPixelCount: Int
    public let eraserReducedAlphaPixelCount: Int
    public let radialRotationRenderedBGRA8SHA256: String
    public let radialRotationReferenceBGRA8SHA256: String
    public let radialRotationMaximumChannelDelta: UInt8
    public let radialReflectionRenderedBGRA8SHA256: String
    public let radialReflectionReferenceBGRA8SHA256: String
    public let radialReflectionMaximumChannelDelta: UInt8
    public let replayMode: String
    public let replayMaximumSamples: Int
    public let replayMaximumDabs: Int
    public let replayMaximumProjectedInstances: Int
    public let pipelinePrepareCallCountBeforeStroke: Int
    public let pipelinePrepareCallCountAfterStroke: Int

    public init(
        liveBGRA8SHA256: String,
        committedBGRA8SHA256: String,
        canonicalBGRA8SHA256: String,
        liveNontransparentPixelCount: Int,
        committedNontransparentPixelCount: Int,
        canonicalNontransparentPixelCount: Int,
        predictionOffBGRA8SHA256: String,
        predictionOnBGRA8SHA256: String,
        predictionMaximumChannelDelta: UInt8,
        gridOriginBGRA8SHA256: String,
        gridTranslatedBGRA8SHA256: String,
        gridMaximumChannelDelta: UInt8,
        eraserBeforeBGRA8SHA256: String,
        eraserAfterBGRA8SHA256: String,
        eraserBeforeNontransparentPixelCount: Int,
        eraserAfterNontransparentPixelCount: Int,
        eraserReducedAlphaPixelCount: Int,
        radialRotationRenderedBGRA8SHA256: String,
        radialRotationReferenceBGRA8SHA256: String,
        radialRotationMaximumChannelDelta: UInt8,
        radialReflectionRenderedBGRA8SHA256: String,
        radialReflectionReferenceBGRA8SHA256: String,
        radialReflectionMaximumChannelDelta: UInt8,
        replayMode: String,
        replayMaximumSamples: Int,
        replayMaximumDabs: Int,
        replayMaximumProjectedInstances: Int,
        pipelinePrepareCallCountBeforeStroke: Int,
        pipelinePrepareCallCountAfterStroke: Int
    ) {
        self.liveBGRA8SHA256 = liveBGRA8SHA256
        self.committedBGRA8SHA256 = committedBGRA8SHA256
        self.canonicalBGRA8SHA256 = canonicalBGRA8SHA256
        self.liveNontransparentPixelCount = liveNontransparentPixelCount
        self.committedNontransparentPixelCount =
            committedNontransparentPixelCount
        self.canonicalNontransparentPixelCount =
            canonicalNontransparentPixelCount
        self.predictionOffBGRA8SHA256 = predictionOffBGRA8SHA256
        self.predictionOnBGRA8SHA256 = predictionOnBGRA8SHA256
        self.predictionMaximumChannelDelta = predictionMaximumChannelDelta
        self.gridOriginBGRA8SHA256 = gridOriginBGRA8SHA256
        self.gridTranslatedBGRA8SHA256 = gridTranslatedBGRA8SHA256
        self.gridMaximumChannelDelta = gridMaximumChannelDelta
        self.eraserBeforeBGRA8SHA256 = eraserBeforeBGRA8SHA256
        self.eraserAfterBGRA8SHA256 = eraserAfterBGRA8SHA256
        self.eraserBeforeNontransparentPixelCount =
            eraserBeforeNontransparentPixelCount
        self.eraserAfterNontransparentPixelCount =
            eraserAfterNontransparentPixelCount
        self.eraserReducedAlphaPixelCount = eraserReducedAlphaPixelCount
        self.radialRotationRenderedBGRA8SHA256 =
            radialRotationRenderedBGRA8SHA256
        self.radialRotationReferenceBGRA8SHA256 =
            radialRotationReferenceBGRA8SHA256
        self.radialRotationMaximumChannelDelta =
            radialRotationMaximumChannelDelta
        self.radialReflectionRenderedBGRA8SHA256 =
            radialReflectionRenderedBGRA8SHA256
        self.radialReflectionReferenceBGRA8SHA256 =
            radialReflectionReferenceBGRA8SHA256
        self.radialReflectionMaximumChannelDelta =
            radialReflectionMaximumChannelDelta
        self.replayMode = replayMode
        self.replayMaximumSamples = replayMaximumSamples
        self.replayMaximumDabs = replayMaximumDabs
        self.replayMaximumProjectedInstances =
            replayMaximumProjectedInstances
        self.pipelinePrepareCallCountBeforeStroke =
            pipelinePrepareCallCountBeforeStroke
        self.pipelinePrepareCallCountAfterStroke =
            pipelinePrepareCallCountAfterStroke
    }
}

public struct ProfessionalBrushSceneEvidence:
    Codable, Equatable, Sendable
{
    public static let currentSchemaVersion: UInt16 = 2

    public let schemaVersion: UInt16
    public let scene: String
    public let family: String
    public let definitionID: String
    public let definitionSemanticHash: String
    public let pipelineKey: String
    public let abiVersion: UInt16
    public let residentResourceBytes: Int
    public let resolvedResources: [ProfessionalBrushResolvedResource]
    public let logicalDabCount: Int
    public let projectedInstanceCount: Int
    public let livePNGSHA256: String
    public let committedPNGSHA256: String
    public let canonicalPNGSHA256: String
    public let characterizationSHA256: String
    public let rendererExecutableSHA256: String
    public let previewCommitMaximumChannelDelta: UInt8
    public let compilerCounters: ProfessionalBrushCompilerCounterEvidence
    public let telemetry: DepositionTelemetryEvidence
    public let observations: ProfessionalBrushInvariantObservations
    public let invariantResults: [String: Bool]

    public init(
        schemaVersion: UInt16,
        scene: String,
        family: String,
        definitionID: String,
        definitionSemanticHash: String,
        pipelineKey: String,
        abiVersion: UInt16,
        residentResourceBytes: Int,
        resolvedResources: [ProfessionalBrushResolvedResource],
        logicalDabCount: Int,
        projectedInstanceCount: Int,
        livePNGSHA256: String,
        committedPNGSHA256: String,
        canonicalPNGSHA256: String,
        characterizationSHA256: String,
        rendererExecutableSHA256: String,
        previewCommitMaximumChannelDelta: UInt8,
        compilerCounters: ProfessionalBrushCompilerCounterEvidence,
        telemetry: DepositionTelemetryEvidence,
        observations: ProfessionalBrushInvariantObservations,
        invariantResults: [String: Bool]
    ) {
        self.schemaVersion = schemaVersion
        self.scene = scene
        self.family = family
        self.definitionID = definitionID
        self.definitionSemanticHash = definitionSemanticHash
        self.pipelineKey = pipelineKey
        self.abiVersion = abiVersion
        self.residentResourceBytes = residentResourceBytes
        self.resolvedResources = resolvedResources
        self.logicalDabCount = logicalDabCount
        self.projectedInstanceCount = projectedInstanceCount
        self.livePNGSHA256 = livePNGSHA256
        self.committedPNGSHA256 = committedPNGSHA256
        self.canonicalPNGSHA256 = canonicalPNGSHA256
        self.characterizationSHA256 = characterizationSHA256
        self.rendererExecutableSHA256 = rendererExecutableSHA256
        self.previewCommitMaximumChannelDelta =
            previewCommitMaximumChannelDelta
        self.compilerCounters = compilerCounters
        self.telemetry = telemetry
        self.observations = observations
        self.invariantResults = invariantResults
    }

    public func encoded() throws -> Data {
        try ProfessionalBrushEvidenceValidator.validate(self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        let evidence: Self
        do {
            evidence = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ProfessionalBrushEvidenceValidationError.invalid(
                "professional scene evidence JSON is malformed"
            )
        }
        try ProfessionalBrushEvidenceValidator.validate(evidence)
        return evidence
    }
}
