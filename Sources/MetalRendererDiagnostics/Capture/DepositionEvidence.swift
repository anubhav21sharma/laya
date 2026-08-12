import BrushFormat
import Foundation
import MetalRenderer

public struct DepositionTelemetryEvidence:
    Codable, Equatable, Sendable
{
    public let authoritativeBacklog: Int
    public let predictedBacklog: Int
    public let backlogHighWater: Int
    public let encodedInstanceCount: UInt64
    public let bufferHighWater: Int
    public let missedFrameCount: UInt64

    public static let zero = DepositionTelemetryEvidence(
        authoritativeBacklog: 0,
        predictedBacklog: 0,
        backlogHighWater: 0,
        encodedInstanceCount: 0,
        bufferHighWater: 0,
        missedFrameCount: 0
    )

    public init(
        authoritativeBacklog: Int,
        predictedBacklog: Int,
        backlogHighWater: Int,
        encodedInstanceCount: UInt64,
        bufferHighWater: Int,
        missedFrameCount: UInt64
    ) {
        self.authoritativeBacklog = authoritativeBacklog
        self.predictedBacklog = predictedBacklog
        self.backlogHighWater = backlogHighWater
        self.encodedInstanceCount = encodedInstanceCount
        self.bufferHighWater = bufferHighWater
        self.missedFrameCount = missedFrameCount
    }

    init(_ snapshot: DepositionTelemetrySnapshot) {
        self.init(
            authoritativeBacklog: snapshot.authoritativeBacklog,
            predictedBacklog: snapshot.predictedBacklog,
            backlogHighWater: snapshot.backlogHighWater,
            encodedInstanceCount: snapshot.encodedInstanceCount,
            bufferHighWater: snapshot.bufferHighWater,
            missedFrameCount: snapshot.missedFrameCount
        )
    }
}

public struct DepositionSceneEvidence: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let scene: String
    public let definitionID: String
    public let semanticHash: String
    public let pipelineKey: String
    public let abiVersion: UInt16
    public let resourceBytes: Int
    public let textureLevels: [String: Int]
    public let logicalDabCount: Int
    public let projectedInstanceCount: Int
    public let canonicalSHA256: String
    public let cpuReferenceSHA256: String?
    public let maximumCPUGPUChannelDelta: UInt8?
    public let previewCommitMaximumChannelDelta: UInt8
    public let telemetry: DepositionTelemetryEvidence
    public let invariantResults: [String: Bool]

    public init(
        schemaVersion: UInt16,
        scene: String,
        definitionID: String,
        semanticHash: String,
        pipelineKey: String,
        abiVersion: UInt16,
        resourceBytes: Int,
        textureLevels: [String: Int],
        logicalDabCount: Int,
        projectedInstanceCount: Int,
        canonicalSHA256: String,
        cpuReferenceSHA256: String?,
        maximumCPUGPUChannelDelta: UInt8?,
        previewCommitMaximumChannelDelta: UInt8,
        telemetry: DepositionTelemetryEvidence,
        invariantResults: [String: Bool]
    ) {
        self.schemaVersion = schemaVersion
        self.scene = scene
        self.definitionID = definitionID
        self.semanticHash = semanticHash
        self.pipelineKey = pipelineKey
        self.abiVersion = abiVersion
        self.resourceBytes = resourceBytes
        self.textureLevels = textureLevels
        self.logicalDabCount = logicalDabCount
        self.projectedInstanceCount = projectedInstanceCount
        self.canonicalSHA256 = canonicalSHA256
        self.cpuReferenceSHA256 = cpuReferenceSHA256
        self.maximumCPUGPUChannelDelta = maximumCPUGPUChannelDelta
        self.previewCommitMaximumChannelDelta =
            previewCommitMaximumChannelDelta
        self.telemetry = telemetry
        self.invariantResults = invariantResults
    }

    public func encoded() throws -> Data {
        try DepositionEvidenceValidator.validate(self)
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
            throw DepositionEvidenceValidationError.malformedEvidence
        }
        try DepositionEvidenceValidator.validate(evidence)
        return evidence
    }

    public static func sha256(_ bytes: [UInt8]) -> String {
        BrushContentHash.sha256Hex(of: Data(bytes))
    }
}
