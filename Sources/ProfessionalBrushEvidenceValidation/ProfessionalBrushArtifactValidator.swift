import Foundation

public enum ProfessionalBrushArtifactValidator {
    public static func validate(
        artifactRoot: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String
    ) throws -> ProfessionalBrushArtifactValidationStatus {
        guard artifactRoot.path.hasPrefix("/"),
              artifactRoot.standardizedFileURL.path == artifactRoot.path,
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

        let provenance = try ProvenanceValidator.validate(
            root: artifactRoot.appendingPathComponent("raw-provenance"),
            artifactRoot: artifactRoot,
            expectedCommit: expectedCommit,
            expectedSourceTreeSHA256: expectedSourceTreeSHA256
        )

        try SceneInputValidator.validateMatrix(
            artifactRoot.appendingPathComponent("scene-matrix.json")
        )
        try SceneInputValidator.validate(
            root: artifactRoot.appendingPathComponent("scene-inputs")
        )
        let rendererHash = ArtifactFileSystem.sha256(
            try ArtifactFileSystem.regularFileData(
                artifactRoot.appendingPathComponent(
                    "runtime/PatternSpike"
                ),
                label: "renderer executable"
            )
        )
        let positive = try SceneArtifactValidator.validatePositive(
            root: artifactRoot.appendingPathComponent("positive"),
            expectedCommit: expectedCommit,
            expectedGPUName: provenance.gpuName,
            expectedOperatingSystem: provenance.operatingSystem,
            expectedRendererSHA256: rendererHash
        )
        _ = try CharacterizationValidator.validateBaseline(
            artifactRoot.appendingPathComponent(
                "characterization-baseline.json"
            ),
            identities: positive.identities,
            positiveCharacterizations: positive.characterizations
        )
        try SceneArtifactValidator.validateNegative(
            root: artifactRoot.appendingPathComponent("negative-control")
        )
        let manualComplete = try ProfessionalManualEvidenceValidator.validate(
            root: artifactRoot.appendingPathComponent("manual-cards"),
            identities: positive.identities
        )
        let physicalComplete = try PhysicalEvidenceValidator.validate(
            root: artifactRoot.appendingPathComponent("physical-profiles"),
            expectedCommit: expectedCommit,
            expectedSourceTreeSHA256: expectedSourceTreeSHA256,
            expectedRendererSHA256: rendererHash,
            identities: positive.identities
        )
        let performanceComplete = try PerformanceStatusValidator.validate(
            ArtifactFileSystem.regularFileData(
                artifactRoot.appendingPathComponent(
                    "performance-status.json"
                ),
                label: "performance status"
            ),
            expectedGPUName: provenance.gpuName,
            expectedOperatingSystem: provenance.operatingSystem,
            expectedCommit: expectedCommit,
            expectedRendererSHA256: rendererHash,
            positiveRoot: artifactRoot.appendingPathComponent("positive"),
            identities: positive.identities
        )
        try ArtifactFileSystem.validateManifest(root: artifactRoot)

        return manualComplete && physicalComplete && performanceComplete
            ? .passed
            : .pending
    }
}
