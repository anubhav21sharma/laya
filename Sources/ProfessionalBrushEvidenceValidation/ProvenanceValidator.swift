import Foundation

struct ProfessionalProvenance {
    let gpuName: String
    let operatingSystem: String
}

enum ProvenanceValidator {
    private static let rawNames = [
        "hardware-machine.txt",
        "hardware-model.txt",
        "hardware.txt",
        "kernel.txt",
        "operating-system.txt",
        "swift-toolchain.txt",
        "validator-nm-undefined.txt",
        "validator-otool.txt",
        "xcode-toolchain.txt",
        "xcodegen-toolchain.txt",
    ]

    static func validate(
        root: URL,
        artifactRoot: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String,
        expectedStageFourManifestSHA256: String,
        expectedStageFourExitStatus: Int
    ) throws -> ProfessionalProvenance {
        guard try ArtifactFileSystem.entryNames(root) == Set(rawNames) else {
            throw ArtifactFileSystem.invalid(
                "raw provenance file set is not exact"
            )
        }
        var digests: [String: String] = [:]
        var rawData: [String: Data] = [:]
        for name in rawNames {
            let data = try ArtifactFileSystem.regularFileData(
                root.appendingPathComponent(name),
                label: "raw provenance \(name)"
            )
            guard name == "hardware.txt" || !data.isEmpty else {
                throw ArtifactFileSystem.invalid(
                    "raw provenance is empty: \(name)"
                )
            }
            digests[name] = ArtifactFileSystem.sha256(data)
            rawData[name] = data
        }

        let data = try ArtifactFileSystem.regularFileData(
            artifactRoot.appendingPathComponent("provenance.json"),
            label: "provenance"
        )
        let object = try ArtifactFileSystem.jsonObject(
            data,
            label: "provenance"
        )
        try ArtifactFileSystem.requireExactKeys(
            object,
            [
                "schemaVersion", "commit", "sourceTreeSHA256",
                "configuration", "swiftVersion", "xcodeVersion",
                "xcodegenVersion", "operatingSystem", "kernel",
                "hardwareMachine", "hardwareModel", "gpuName",
                "gpuClassification", "artifactRoot",
                "stageFourExitStatus",
                "stageFourArtifactManifestSHA256",
                "rawProvenanceSHA256", "rendererExecutableSHA256",
            ],
            label: "provenance"
        )
        guard object["schemaVersion"] as? Int == 2,
              object["commit"] as? String == expectedCommit,
              ArtifactFileSystem.isCommit(expectedCommit),
              object["sourceTreeSHA256"] as? String
                == expectedSourceTreeSHA256,
              ArtifactFileSystem.isSHA256(expectedSourceTreeSHA256),
              object["configuration"] as? String == "Debug",
              object["artifactRoot"] as? String
                == artifactRoot.standardizedFileURL.path,
              object["stageFourExitStatus"] as? Int
                == expectedStageFourExitStatus,
              object["stageFourArtifactManifestSHA256"] as? String
                == expectedStageFourManifestSHA256,
              let raw = object["rawProvenanceSHA256"] as? [String: String],
              raw == digests,
              let gpuName = ArtifactFileSystem.nonemptyString(
                  object,
                  "gpuName"
              ),
              object["gpuClassification"] as? String
                == ArtifactFileSystem.gpuClassification(gpuName),
              let operatingSystem = ArtifactFileSystem.nonemptyString(
                  object,
                  "operatingSystem"
              ),
              [
                  "swiftVersion", "xcodeVersion", "xcodegenVersion",
                  "kernel", "hardwareMachine", "hardwareModel",
              ].allSatisfy({
                  ArtifactFileSystem.nonemptyString(object, $0) != nil
              }),
              object["swiftVersion"] as? String
                == collapsed(rawData["swift-toolchain.txt"]),
              object["xcodeVersion"] as? String
                == collapsed(rawData["xcode-toolchain.txt"]),
              object["xcodegenVersion"] as? String
                == collapsed(rawData["xcodegen-toolchain.txt"]),
              object["kernel"] as? String
                == trimmed(rawData["kernel.txt"]),
              object["hardwareMachine"] as? String
                == trimmed(rawData["hardware-machine.txt"]),
              object["hardwareModel"] as? String
                == trimmed(rawData["hardware-model.txt"]),
              operatingSystem
                == normalizedOperatingSystem(
                    rawData["operating-system.txt"]
                ),
              let executableHash =
                object["rendererExecutableSHA256"] as? String,
              ArtifactFileSystem.isSHA256(executableHash)
        else {
            throw ArtifactFileSystem.invalid(
                "provenance does not bind raw toolchain, platform, GPU, and source inputs"
            )
        }
        let runtime = artifactRoot.appendingPathComponent(
            "runtime/PatternSpike"
        )
        guard executableHash == ArtifactFileSystem.sha256(
            try ArtifactFileSystem.regularFileData(
                runtime,
                label: "renderer executable"
            )
        ) else {
            throw ArtifactFileSystem.invalid(
                "renderer executable digest does not match provenance"
            )
        }
        return ProfessionalProvenance(
            gpuName: gpuName,
            operatingSystem: operatingSystem
        )
    }

    private static func collapsed(_ data: Data?) -> String? {
        guard let data,
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func trimmed(_ data: Data?) -> String? {
        guard let data,
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedOperatingSystem(
        _ data: Data?
    ) -> String? {
        guard let data,
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        var fields: [String: String] = [:]
        for rawLine in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            let line = String(rawLine)
            if line.isEmpty {
                continue
            }
            guard let separator = line.firstIndex(of: ":") else {
                return nil
            }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty,
                  !value.isEmpty,
                  fields.updateValue(value, forKey: key) == nil
            else {
                return nil
            }
        }
        guard Set(fields.keys) == [
            "ProductName", "ProductVersion", "BuildVersion",
        ],
            fields["ProductName"] == "macOS",
            let version = fields["ProductVersion"],
            let build = fields["BuildVersion"]
        else {
            return nil
        }
        return "Version \(version) (Build \(build))"
    }
}
