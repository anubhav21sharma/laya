import BrushDepositionEvidenceValidation
import Foundation

struct StageFourRegression {
    let status: StageFourEvidenceValidationStatus
    let manifestSHA256: String
}

enum StageFourRegressionValidator {
    static func validate(
        recordURL: URL,
        stageFourRoot: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String,
        expectedSourceTreeData: Data
    ) throws -> StageFourRegression {
        // This call is the authority. The copied exit status and terminal line
        // below are only required to agree with the freshly derived result.
        let status = try StageFourEvidenceValidator.validate(
            artifactRoot: stageFourRoot,
            expectedCommit: expectedCommit,
            expectedSourceTreeSHA256: expectedSourceTreeSHA256
        )
        let expectedExit: Int
        switch status {
        case .passed:
            expectedExit = 0
        case .performancePending:
            expectedExit = 2
        }

        let data = try ArtifactFileSystem.regularFileData(
            recordURL,
            label: "Stage 4 regression"
        )
        let object = try ArtifactFileSystem.jsonObject(
            data,
            label: "Stage 4 regression"
        )
        try ArtifactFileSystem.requireExactKeys(
            object,
            [
                "schemaVersion", "exitStatus", "artifactRoot", "commit",
                "sourceTreeSHA256", "artifactManifestSHA256",
                "terminalLine",
            ],
            label: "Stage 4 regression"
        )
        let manifestData = try ArtifactFileSystem.regularFileData(
            stageFourRoot.appendingPathComponent("artifact-sha256.txt"),
            label: "Stage 4 artifact manifest"
        )
        let manifestHash = ArtifactFileSystem.sha256(manifestData)
        guard object["schemaVersion"] as? Int == 1,
              object["exitStatus"] as? Int == expectedExit,
              object["artifactRoot"] as? String
                == stageFourRoot.standardizedFileURL.path,
              object["commit"] as? String == expectedCommit,
              object["sourceTreeSHA256"] as? String
                == expectedSourceTreeSHA256,
              object["artifactManifestSHA256"] as? String == manifestHash,
              let terminal = object["terminalLine"] as? String,
              terminal.contains("commit=\(expectedCommit)"),
              terminal.contains(
                  "artifacts=\(stageFourRoot.standardizedFileURL.path)"
              )
        else {
            throw ArtifactFileSystem.invalid(
                "Stage 4 regression record disagrees with fresh validation"
            )
        }
        let stageFourSource = try ArtifactFileSystem.regularFileData(
            stageFourRoot.appendingPathComponent("source-tree.txt"),
            label: "Stage 4 source tree"
        )
        let stageFourTerminal = try ArtifactFileSystem.regularFileData(
            stageFourRoot.appendingPathComponent(
                "source-tree-terminal.txt"
            ),
            label: "Stage 4 terminal source tree"
        )
        guard stageFourSource == expectedSourceTreeData,
              stageFourTerminal == expectedSourceTreeData
        else {
            throw ArtifactFileSystem.invalid(
                "Stage 4 prerequisite source tree differs from Stage 5"
            )
        }
        return StageFourRegression(
            status: status,
            manifestSHA256: manifestHash
        )
    }
}
