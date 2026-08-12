import Foundation
import ProfessionalBrushEvidenceValidation

public enum BrushCorrectiveGateCategory:
    String, CaseIterable, Equatable, Sendable
{
    case boundedResources
    case cursorSupport
    case determinism
    case historyParity
    case inputPath
    case visibleOutput
}

public enum BrushCorrectiveGateError: Error, Equatable, Sendable {
    case invalidCategorySet
    case failedCategory(BrushCorrectiveGateCategory)
}

public struct BrushCorrectiveGateResult: Equatable, Sendable {
    public let automatedPassed: Bool
    public let manualAndPhysicalPending: Bool
}

/// Cross-family software admission boundary. Artifact details remain owned by
/// `ProfessionalBrushEvidenceValidation`; this type names the corrective
/// matrix and exposes its automation/manual boundary to tools and tests.
public enum BrushCorrectiveGate {
    public static let positiveSceneNames = [
        "professional-chisel-marker",
        "professional-graphite-pencil",
        "professional-natural-charcoal",
        "professional-technical-ink",
    ]
    public static let negativeSceneNames = positiveSceneNames.map {
        "\($0)-negative-control"
    }

    public static func validateArtifacts(
        artifactRoot: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String
    ) throws -> BrushCorrectiveGateResult {
        let status = try ProfessionalBrushArtifactValidator.validate(
            artifactRoot: artifactRoot,
            expectedCommit: expectedCommit,
            expectedSourceTreeSHA256: expectedSourceTreeSHA256
        )
        return BrushCorrectiveGateResult(
            automatedPassed: true,
            manualAndPhysicalPending: status == .pending
        )
    }

    public static func validateCategoryControls(
        _ controls: [BrushCorrectiveGateCategory: Bool]
    ) throws {
        guard Set(controls.keys) == Set(BrushCorrectiveGateCategory.allCases)
        else {
            throw BrushCorrectiveGateError.invalidCategorySet
        }
        for category in BrushCorrectiveGateCategory.allCases
            where controls[category] != true
        {
            throw BrushCorrectiveGateError.failedCategory(category)
        }
    }
}
