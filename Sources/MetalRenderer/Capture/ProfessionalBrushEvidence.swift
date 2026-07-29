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

public struct ProfessionalBrushSceneEvidence:
    Codable, Equatable, Sendable
{
    public static let currentSchemaVersion: UInt16 = 1

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
    public let previewCommitMaximumChannelDelta: UInt8
    public let compilerCounters: ProfessionalBrushCompilerCounterEvidence
    public let telemetry: DepositionTelemetryEvidence
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
        previewCommitMaximumChannelDelta: UInt8,
        compilerCounters: ProfessionalBrushCompilerCounterEvidence,
        telemetry: DepositionTelemetryEvidence,
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
        self.previewCommitMaximumChannelDelta =
            previewCommitMaximumChannelDelta
        self.compilerCounters = compilerCounters
        self.telemetry = telemetry
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

public struct ProfessionalBrushPerformanceStatus:
    Codable, Equatable, Sendable
{
    public let schemaVersion: Int
    public let correctnessPassed: Bool
    public let gpuName: String
    public let gpuClassification: String
    public let cpuPreparationP95Milliseconds: Double
    public let cpuPreparationBudgetMilliseconds: Double
    public let gpu500DabMilliseconds: Double
    public let gpu500DabBudgetMilliseconds: Double
    public let completedStrokeLengthIndependent: Bool
    public let hotPathCompilerResourceCountersZero: Bool

    public init(
        schemaVersion: Int,
        correctnessPassed: Bool,
        gpuName: String,
        gpuClassification: String,
        cpuPreparationP95Milliseconds: Double,
        cpuPreparationBudgetMilliseconds: Double,
        gpu500DabMilliseconds: Double,
        gpu500DabBudgetMilliseconds: Double,
        completedStrokeLengthIndependent: Bool,
        hotPathCompilerResourceCountersZero: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.correctnessPassed = correctnessPassed
        self.gpuName = gpuName
        self.gpuClassification = gpuClassification
        self.cpuPreparationP95Milliseconds =
            cpuPreparationP95Milliseconds
        self.cpuPreparationBudgetMilliseconds =
            cpuPreparationBudgetMilliseconds
        self.gpu500DabMilliseconds = gpu500DabMilliseconds
        self.gpu500DabBudgetMilliseconds = gpu500DabBudgetMilliseconds
        self.completedStrokeLengthIndependent =
            completedStrokeLengthIndependent
        self.hotPathCompilerResourceCountersZero =
            hotPathCompilerResourceCountersZero
    }
}
