import Foundation
import PatternEngine

public enum BrushPerformanceTier:
    String, Codable, Equatable, Sendable
{
    case realtime120
    case realtime60
    case unsupportedResourceCost
}

public enum BrushPerformanceEvidenceBasis:
    String, Codable, Equatable, Sendable
{
    case estimated
    case measured
}

public struct BrushPerformanceClassification:
    Codable, Equatable, Sendable
{
    public let tier: BrushPerformanceTier
    public let basis: BrushPerformanceEvidenceBasis
    public let reason: String

    public init(
        tier: BrushPerformanceTier,
        basis: BrushPerformanceEvidenceBasis,
        reason: String
    ) {
        self.tier = tier
        self.basis = basis
        self.reason = reason
    }
}

public enum BrushCompatibilityLevel:
    String, Codable, Equatable, Sendable
{
    case exact
    case approximated
    case unsupported
}

public struct BrushCompatibilityEntry:
    Codable, Equatable, Sendable
{
    public let semanticKey: String
    public let level: BrushCompatibilityLevel
    public let message: String

    public init(
        semanticKey: String,
        level: BrushCompatibilityLevel,
        message: String
    ) {
        self.semanticKey = semanticKey
        self.level = level
        self.message = message
    }
}

public enum BrushCompilationReportValidationError:
    Error, Equatable, Sendable
{
    case emptyDefinitionID
    case invalidPackageContentHash
    case negativeEncodedResourceBytes(Int)
    case negativeResidentResourceBytes(Int)
    case negativeRequestedBytes(Int)
    case invalidFailureReason
    case emptyCompatibilitySemanticKey
    case unsortedCompatibility
    case duplicateCompatibilitySemanticKey(String)
}

private enum BrushCompilationReportValidator {
    static let maximumFailureReasonUTF8ByteCount = 1_024

    static func validateIdentity(
        definitionID: String,
        packageContentHash: String
    ) throws {
        guard !definitionID.isEmpty else {
            throw BrushCompilationReportValidationError.emptyDefinitionID
        }
        let hashBytes = packageContentHash.utf8
        guard hashBytes.count == 64,
              hashBytes.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              })
        else {
            throw BrushCompilationReportValidationError
                .invalidPackageContentHash
        }
    }

    static func validateFailureReason(_ reason: String) throws {
        guard !reason.isEmpty,
              reason.utf8.count <= maximumFailureReasonUTF8ByteCount,
              reason.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw BrushCompilationReportValidationError.invalidFailureReason
        }
    }
}

public struct BrushCompilationReport: Codable, Equatable, Sendable {
    public let definitionID: String
    public let packageContentHash: String
    public let backend: BrushBackendKind
    public let compatibility: [BrushCompatibilityEntry]
    public let performance: BrushPerformanceClassification
    public let encodedResourceBytes: Int
    public let residentResourceBytes: Int
    public let deviceRegistryID: UInt64

    public init(
        definitionID: String,
        packageContentHash: String,
        backend: BrushBackendKind,
        compatibility: [BrushCompatibilityEntry],
        performance: BrushPerformanceClassification,
        encodedResourceBytes: Int,
        residentResourceBytes: Int,
        deviceRegistryID: UInt64
    ) throws {
        try BrushCompilationReportValidator.validateIdentity(
            definitionID: definitionID,
            packageContentHash: packageContentHash
        )
        guard encodedResourceBytes >= 0 else {
            throw BrushCompilationReportValidationError
                .negativeEncodedResourceBytes(encodedResourceBytes)
        }
        guard residentResourceBytes >= 0 else {
            throw BrushCompilationReportValidationError
                .negativeResidentResourceBytes(residentResourceBytes)
        }
        try Self.validate(compatibility)
        self.definitionID = definitionID
        self.packageContentHash = packageContentHash
        self.backend = backend
        self.compatibility = compatibility
        self.performance = performance
        self.encodedResourceBytes = encodedResourceBytes
        self.residentResourceBytes = residentResourceBytes
        self.deviceRegistryID = deviceRegistryID
    }

    private enum CodingKeys: String, CodingKey {
        case definitionID
        case packageContentHash
        case backend
        case compatibility
        case performance
        case encodedResourceBytes
        case residentResourceBytes
        case deviceRegistryID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            definitionID: container.decode(String.self, forKey: .definitionID),
            packageContentHash: container.decode(
                String.self,
                forKey: .packageContentHash
            ),
            backend: container.decode(BrushBackendKind.self, forKey: .backend),
            compatibility: container.decode(
                [BrushCompatibilityEntry].self,
                forKey: .compatibility
            ),
            performance: container.decode(
                BrushPerformanceClassification.self,
                forKey: .performance
            ),
            encodedResourceBytes: container.decode(
                Int.self,
                forKey: .encodedResourceBytes
            ),
            residentResourceBytes: container.decode(
                Int.self,
                forKey: .residentResourceBytes
            ),
            deviceRegistryID: container.decode(
                UInt64.self,
                forKey: .deviceRegistryID
            )
        )
    }

    private static func validate(
        _ entries: [BrushCompatibilityEntry]
    ) throws {
        guard entries.allSatisfy({ !$0.semanticKey.isEmpty }) else {
            throw BrushCompilationReportValidationError
                .emptyCompatibilitySemanticKey
        }

        for index in entries.indices.dropFirst() {
            let previous = entries[index - 1].semanticKey
            let current = entries[index].semanticKey
            if current == previous {
                throw BrushCompilationReportValidationError
                    .duplicateCompatibilitySemanticKey(current)
            }
            guard previous < current else {
                throw BrushCompilationReportValidationError
                    .unsortedCompatibility
            }
        }
    }
}

public enum BrushCompilationStage:
    String, Codable, Equatable, Sendable
{
    case definition
    case archive
    case imageDecode
    case mipGeneration
    case textureUpload
    case residency
    case pipelineSelection
    case activation
}

public struct BrushCompilationFailure:
    Error, Codable, Equatable, Sendable
{
    public let definitionID: String
    public let packageContentHash: String
    public let backend: BrushBackendKind
    public let stage: BrushCompilationStage
    public let resourceID: String?
    public let requestedBytes: Int?
    public let deviceRegistryID: UInt64
    public let reason: String

    public init(
        definitionID: String,
        packageContentHash: String,
        backend: BrushBackendKind,
        stage: BrushCompilationStage,
        resourceID: String?,
        requestedBytes: Int?,
        deviceRegistryID: UInt64,
        reason: String
    ) throws {
        try BrushCompilationReportValidator.validateIdentity(
            definitionID: definitionID,
            packageContentHash: packageContentHash
        )
        if let requestedBytes, requestedBytes < 0 {
            throw BrushCompilationReportValidationError
                .negativeRequestedBytes(requestedBytes)
        }
        try BrushCompilationReportValidator.validateFailureReason(reason)
        self.definitionID = definitionID
        self.packageContentHash = packageContentHash
        self.backend = backend
        self.stage = stage
        self.resourceID = resourceID
        self.requestedBytes = requestedBytes
        self.deviceRegistryID = deviceRegistryID
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case definitionID
        case packageContentHash
        case backend
        case stage
        case resourceID
        case requestedBytes
        case deviceRegistryID
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            definitionID: container.decode(String.self, forKey: .definitionID),
            packageContentHash: container.decode(
                String.self,
                forKey: .packageContentHash
            ),
            backend: container.decode(BrushBackendKind.self, forKey: .backend),
            stage: container.decode(
                BrushCompilationStage.self,
                forKey: .stage
            ),
            resourceID: container.decodeIfPresent(
                String.self,
                forKey: .resourceID
            ),
            requestedBytes: container.decodeIfPresent(
                Int.self,
                forKey: .requestedBytes
            ),
            deviceRegistryID: container.decode(
                UInt64.self,
                forKey: .deviceRegistryID
            ),
            reason: container.decode(String.self, forKey: .reason)
        )
    }
}
