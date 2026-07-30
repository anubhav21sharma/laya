import BrushDepositionEvidenceValidation
import Foundation

enum PhysicalEvidenceValidator {
    static func validate(
        root: URL,
        stageFourRoot: URL
    ) throws -> Bool {
        let entries = try ArtifactFileSystem.entryNames(root)
        if entries.isEmpty {
            return false
        }
        guard entries == Set(StageFourEvidenceValidator.requiredPhysicalProfiles)
        else {
            throw ArtifactFileSystem.invalid(
                "physical evidence must be empty or contain the exact eight-profile set"
            )
        }
        // StageFourEvidenceValidator has already revalidated profile schemas,
        // devices, metrics, units, samples, thresholds, and raw trace digests.
        // Stage 5 accepts only an exact byte-for-byte copy of that authority.
        try ArtifactFileSystem.exactTreeMatch(
            root,
            stageFourRoot.appendingPathComponent("physical-profiles")
        )
        return true
    }
}
