import Foundation
import MetalRenderer

public struct HarnessScene: Encodable, Equatable, Sendable {
    public static let currentSchemaVersion = 6

    public let schemaVersion: Int
    public let name: String
    public let width: Int
    public let height: Int
    public let depositionInvariantExpectations: [String: Bool]

    private init(
        name: String,
        width: Int,
        height: Int,
        depositionInvariantExpectations: [String: Bool]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.width = width
        self.height = height
        self.depositionInvariantExpectations =
            depositionInvariantExpectations
    }

    public static func decode(_ data: Data) throws -> HarnessScene {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(VersionEnvelope.self, from: data)
        guard envelope.schemaVersion == currentSchemaVersion else {
            throw HarnessSceneError.unsupportedSchema(
                envelope.schemaVersion
            )
        }

        let payload = try decoder.decode(CurrentPayload.self, from: data)
        guard !payload.name.isEmpty else {
            throw HarnessSceneError.emptyName
        }
        guard (1...4_096).contains(payload.width),
              (1...4_096).contains(payload.height)
        else {
            throw HarnessSceneError.invalidDimensions(
                width: payload.width,
                height: payload.height
            )
        }
        let currentSceneNames = Set(
            DepositionEvidenceValidator.sceneNames
                + ProfessionalBrushEvidenceValidator.sceneNames
        )
        let currentInvariantNames =
            DepositionEvidenceValidator.allowedInvariantNames.union(
                ProfessionalBrushEvidenceValidator.requiredInvariantNames
            )
        guard currentSceneNames.contains(payload.name),
              !payload.depositionInvariantExpectations.isEmpty,
              Set(payload.depositionInvariantExpectations.keys)
                .isSubset(of: currentInvariantNames)
        else {
            throw HarnessSceneError.invalidDepositionScene
        }

        return HarnessScene(
            name: payload.name,
            width: payload.width,
            height: payload.height,
            depositionInvariantExpectations:
                payload.depositionInvariantExpectations
        )
    }
}

private struct VersionEnvelope: Decodable {
    let schemaVersion: Int
}

private struct CurrentPayload: Decodable {
    let name: String
    let width: Int
    let height: Int
    let depositionInvariantExpectations: [String: Bool]
}

public enum HarnessSceneError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case emptyName
    case invalidDimensions(width: Int, height: Int)
    case invalidDepositionScene

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported harness scene schema \(version); expected schema 6."
        case .emptyName:
            "Harness scene name is empty."
        case let .invalidDimensions(width, height):
            "Harness dimensions \(width)x\(height) are outside 1...4096."
        case .invalidDepositionScene:
            "Schema 6 requires a current native deposition scene and known nonempty expectations."
        }
    }
}
