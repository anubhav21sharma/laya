import Foundation

struct SceneEvidence: Decodable {
    let schemaVersion: Int
    let scene: String
    let family: String
    let definitionID: String
    let definitionSemanticHash: String
    let pipelineKey: String
    let abiVersion: Int
    let residentResourceBytes: Int
    let resolvedResources: [ResolvedResource]
    let logicalDabCount: Int
    let projectedInstanceCount: Int
    let livePNGSHA256: String
    let committedPNGSHA256: String
    let canonicalPNGSHA256: String
    let characterizationSHA256: String
    let rendererExecutableSHA256: String
    let previewCommitMaximumChannelDelta: Int
    let compilerCounters: CompilerCounterEvidence
    let telemetry: TelemetryEvidence
    let observations: InvariantObservations
    let invariantResults: [String: Bool]
}

struct ResolvedResource: Decodable {
    let identity: String
    let kind: String
    let mipCount: Int
}

struct CompilerCounterEvidence: Decodable {
    let beforeCompile: CompilerCounterSnapshot
    let afterCompile: CompilerCounterSnapshot
    let afterCacheHit: CompilerCounterSnapshot
    let beforeStroke: CompilerCounterSnapshot
    let afterStroke: CompilerCounterSnapshot
}

struct CompilerCounterSnapshot: Decodable, Equatable {
    let packageDecodeCount: UInt64
    let imageDecodeCount: UInt64
    let textureUploadCount: UInt64
    let cacheHitCount: UInt64
    let activationCount: UInt64

    static let zero = CompilerCounterSnapshot(
        packageDecodeCount: 0,
        imageDecodeCount: 0,
        textureUploadCount: 0,
        cacheHitCount: 0,
        activationCount: 0
    )
}

struct TelemetryEvidence: Decodable {
    let authoritativeBacklog: Int
    let predictedBacklog: Int
    let backlogHighWater: Int
    let encodedInstanceCount: UInt64
    let bufferHighWater: Int
    let missedFrameCount: UInt64
}

struct InvariantObservations: Decodable {
    let liveBGRA8SHA256: String
    let committedBGRA8SHA256: String
    let canonicalBGRA8SHA256: String
    let liveNontransparentPixelCount: Int
    let committedNontransparentPixelCount: Int
    let canonicalNontransparentPixelCount: Int
    let predictionOffBGRA8SHA256: String
    let predictionOnBGRA8SHA256: String
    let predictionMaximumChannelDelta: Int
    let gridOriginBGRA8SHA256: String
    let gridTranslatedBGRA8SHA256: String
    let gridMaximumChannelDelta: Int
    let eraserBeforeBGRA8SHA256: String
    let eraserAfterBGRA8SHA256: String
    let eraserBeforeNontransparentPixelCount: Int
    let eraserAfterNontransparentPixelCount: Int
    let eraserReducedAlphaPixelCount: Int
    let radialRotationRenderedBGRA8SHA256: String
    let radialRotationReferenceBGRA8SHA256: String
    let radialRotationMaximumChannelDelta: Int
    let radialReflectionRenderedBGRA8SHA256: String
    let radialReflectionReferenceBGRA8SHA256: String
    let radialReflectionMaximumChannelDelta: Int
    let replayMode: String
    let replayMaximumSamples: Int
    let replayMaximumDabs: Int
    let replayMaximumProjectedInstances: Int
    let pipelinePrepareCallCountBeforeStroke: Int
    let pipelinePrepareCallCountAfterStroke: Int
}

struct ProfessionalBenchmark: Decodable {
    struct Hardware: Decodable {
        let gpuName: String
        let logicalProcessorCount: Int
        let physicalMemoryBytes: UInt64
    }
    struct Build: Decodable {
        let configuration: String
        let gitCommit: String
    }

    let schemaVersion: Int
    let timestampUTC: String
    let sceneName: String
    let program: String
    let hardware: Hardware
    let operatingSystem: String
    let build: Build
    let frameCount: Int
    let cpuEncodeMilliseconds: [Double]
    let gpuMilliseconds: [Double]
    let peakResidentBytes: UInt64
    let newInstanceCounts: [Int]
    let missedFrameCount: Int
    let totalProjectedFragmentCount: Int
    let totalInstanceBytes: Int
    let previewCommitViolationCount: Int
    let recipeID: String
    let seed: UInt64
    let replayMode: String
    let assetResidentBytes: Int
    let logicalDabDigest: String
    let canonicalBGRA8Digest: String
    let logicalDabCount: Int
}
