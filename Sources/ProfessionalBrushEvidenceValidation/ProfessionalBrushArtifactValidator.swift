import BrushDepositionEvidenceValidation
import Foundation

public enum ProfessionalBrushArtifactValidator {
    public static func validate(
        artifactRoot: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String,
        expectedStageFourArtifactRoot: URL
    ) throws -> ProfessionalBrushArtifactValidationStatus {
        guard artifactRoot.path.hasPrefix("/"),
              artifactRoot.standardizedFileURL.path == artifactRoot.path,
              expectedStageFourArtifactRoot.path.hasPrefix("/"),
              expectedStageFourArtifactRoot.standardizedFileURL.path
                == expectedStageFourArtifactRoot.path,
              ArtifactFileSystem.isCommit(expectedCommit),
              ArtifactFileSystem.isSHA256(expectedSourceTreeSHA256)
        else {
            throw ArtifactFileSystem.invalid(
                "artifact roots and expected source identities are invalid"
            )
        }
        let expectedRootEntries: Set<String> = [
            "artifact-sha256.txt",
            "characterization-baseline.json",
            "manual-cards",
            "negative-control",
            "performance-status.json",
            "physical-profiles",
            "positive",
            "provenance.json",
            "raw-provenance",
            "runtime",
            "scene-inputs",
            "scene-matrix.json",
            "source-tree-terminal.txt",
            "source-tree.txt",
            "stage-four-regression.json",
        ]
        guard try ArtifactFileSystem.entryNames(artifactRoot)
                == expectedRootEntries
        else {
            throw ArtifactFileSystem.invalid(
                "Stage 5 artifact root file set is not exact"
            )
        }
        guard try ArtifactFileSystem.entryNames(
            artifactRoot.appendingPathComponent("runtime")
        ) == ["PatternSpike"] else {
            throw ArtifactFileSystem.invalid(
                "runtime executable file set is not exact"
            )
        }

        let source = try ArtifactFileSystem.regularFileData(
            artifactRoot.appendingPathComponent("source-tree.txt"),
            label: "source tree"
        )
        let terminal = try ArtifactFileSystem.regularFileData(
            artifactRoot.appendingPathComponent(
                "source-tree-terminal.txt"
            ),
            label: "terminal source tree"
        )
        guard !source.isEmpty,
              source == terminal,
              ArtifactFileSystem.sha256(source)
                == expectedSourceTreeSHA256
        else {
            throw ArtifactFileSystem.invalid(
                "committed source tree is empty, changed, or unbound"
            )
        }

        let stageFour = try StageFourRegressionValidator.validate(
            recordURL: artifactRoot.appendingPathComponent(
                "stage-four-regression.json"
            ),
            stageFourRoot: expectedStageFourArtifactRoot,
            expectedCommit: expectedCommit,
            expectedSourceTreeSHA256: expectedSourceTreeSHA256,
            expectedSourceTreeData: source
        )
        let stageFourExit: Int
        switch stageFour.status {
        case .passed:
            stageFourExit = 0
        case .performancePending:
            stageFourExit = 2
        }
        let provenance = try ProvenanceValidator.validate(
            root: artifactRoot.appendingPathComponent("raw-provenance"),
            artifactRoot: artifactRoot,
            expectedCommit: expectedCommit,
            expectedSourceTreeSHA256: expectedSourceTreeSHA256,
            expectedStageFourManifestSHA256:
                stageFour.manifestSHA256,
            expectedStageFourExitStatus: stageFourExit
        )

        try SceneInputValidator.validateMatrix(
            artifactRoot.appendingPathComponent("scene-matrix.json")
        )
        try SceneInputValidator.validate(
            root: artifactRoot.appendingPathComponent("scene-inputs")
        )
        let baseline = try CharacterizationValidator.validateBaseline(
            artifactRoot.appendingPathComponent(
                "characterization-baseline.json"
            )
        )
        let rendererHash = ArtifactFileSystem.sha256(
            try ArtifactFileSystem.regularFileData(
                artifactRoot.appendingPathComponent(
                    "runtime/PatternSpike"
                ),
                label: "renderer executable"
            )
        )
        let maximumCPUP95 = try SceneArtifactValidator.validatePositive(
            root: artifactRoot.appendingPathComponent("positive"),
            expectedCommit: expectedCommit,
            expectedGPUName: provenance.gpuName,
            expectedOperatingSystem: provenance.operatingSystem,
            expectedRendererSHA256: rendererHash,
            baseline: baseline
        )
        try SceneArtifactValidator.validateNegative(
            root: artifactRoot.appendingPathComponent("negative-control")
        )
        let manualComplete = try ProfessionalManualEvidenceValidator.validate(
            root: artifactRoot.appendingPathComponent("manual-cards")
        )
        let physicalComplete = try PhysicalEvidenceValidator.validate(
            root: artifactRoot.appendingPathComponent("physical-profiles"),
            stageFourRoot: expectedStageFourArtifactRoot
        )
        let performanceComplete = try PerformanceStatusValidator.validate(
            ArtifactFileSystem.regularFileData(
                artifactRoot.appendingPathComponent(
                    "performance-status.json"
                ),
                label: "performance status"
            ),
            expectedGPUName: provenance.gpuName,
            measuredCPUP95Milliseconds: maximumCPUP95,
            stageFourRoot: expectedStageFourArtifactRoot
        )
        try ArtifactFileSystem.validateManifest(root: artifactRoot)

        return manualComplete && physicalComplete && performanceComplete
            ? .passed
            : .pending
    }
}
