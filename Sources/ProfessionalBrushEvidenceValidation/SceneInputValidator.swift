import Foundation

enum SceneInputValidator {
    static func validate(root: URL) throws {
        let expectedFiles = Set(
            ProfessionalBrushTruth.sceneNames.map { "\($0).json" }
        )
        guard try ArtifactFileSystem.entryNames(root) == expectedFiles else {
            throw ArtifactFileSystem.invalid(
                "scene-input file set is not exact"
            )
        }
        for expectedName in ProfessionalBrushTruth.sceneNames {
            let data = try ArtifactFileSystem.regularFileData(
                root.appendingPathComponent("\(expectedName).json"),
                label: "scene \(expectedName)"
            )
            let object = try ArtifactFileSystem.jsonObject(
                data,
                label: "scene \(expectedName)"
            )
            try ArtifactFileSystem.requireExactKeys(
                object,
                [
                    "schemaVersion", "name", "width", "height",
                    "depositionInvariantExpectations",
                ],
                label: "scene \(expectedName)"
            )
            guard object["schemaVersion"] as? Int == 6,
                  object["name"] as? String == expectedName,
                  object["width"] as? Int == 128,
                  object["height"] as? Int == 128,
                  let expectations =
                    object["depositionInvariantExpectations"]
                        as? [String: Bool],
                  Set(expectations.keys)
                    == ProfessionalBrushTruth.requiredInvariantNames
            else {
                throw ArtifactFileSystem.invalid(
                    "scene \(expectedName) schema or filename identity is invalid"
                )
            }
            let positive = !expectedName.hasSuffix("-negative-control")
            for invariant in ProfessionalBrushTruth.requiredInvariantNames {
                let expected = positive
                    || invariant != "professionalDefinitionIdentityExact"
                guard expectations[invariant] == expected else {
                    throw ArtifactFileSystem.invalid(
                        "scene \(expectedName) expectation matrix is invalid"
                    )
                }
            }
        }
    }

    static func validateMatrix(_ url: URL) throws {
        let data = try ArtifactFileSystem.regularFileData(
            url,
            label: "scene matrix"
        )
        let object = try ArtifactFileSystem.jsonObject(
            data,
            label: "scene matrix"
        )
        try ArtifactFileSystem.requireExactKeys(
            object,
            ["schemaVersion", "positive", "negativeControls"],
            label: "scene matrix"
        )
        guard object["schemaVersion"] as? Int == 1,
              object["positive"] as? [String]
                == ProfessionalBrushTruth.positiveSceneNames,
              object["negativeControls"] as? [String]
                == ProfessionalBrushTruth.negativeSceneNames
        else {
            throw ArtifactFileSystem.invalid(
                "scene matrix is not the exact sorted Stage 5 set"
            )
        }
    }
}
