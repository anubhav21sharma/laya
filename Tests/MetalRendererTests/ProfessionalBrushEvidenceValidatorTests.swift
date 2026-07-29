import Foundation
@testable import MetalRenderer
import Testing

@Suite("Professional brush artifact validator", .serialized)
struct ProfessionalBrushEvidenceValidatorTests {
    @Test
    func artifactManifestRequiresExactSortedUniqueFilesAndHashes() throws {
        let root = try artifactManifestFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        try ProfessionalBrushEvidenceValidator.validateArtifactManifest(
            root: root
        )

        let manifest = root.appendingPathComponent("artifact-sha256.txt")
        let original = try String(contentsOf: manifest, encoding: .utf8)
        let lines = original.split(separator: "\n").map(String.init)

        for mutation in [
            lines.reversed().joined(separator: "\n") + "\n",
            (lines + [lines[0]]).joined(separator: "\n") + "\n",
            String(repeating: "0", count: 64)
                + String(lines[0].dropFirst(64))
                + "\n"
                + lines.dropFirst().joined(separator: "\n")
                + "\n",
        ] {
            try Data(mutation.utf8).write(to: manifest)
            #expect(throws: Error.self) {
                try ProfessionalBrushEvidenceValidator
                    .validateArtifactManifest(root: root)
            }
        }

        try Data(original.utf8).write(to: manifest)
        try Data("extra".utf8).write(
            to: root.appendingPathComponent("extra.txt")
        )
        #expect(throws: Error.self) {
            try ProfessionalBrushEvidenceValidator.validateArtifactManifest(
                root: root
            )
        }
    }

    @Test(arguments: ["pass", "passed", "pending", "fail", "failed"])
    func rawCallerStatusStringsFailClosed(_ status: String) {
        #expect(throws: Error.self) {
            try ProfessionalBrushEvidenceValidator.rejectRawStatusStrings(
                Data(status.utf8),
                label: "physical profile"
            )
        }
    }

    @Test
    func structuredSoftwareGreenStatusIsPendingWithoutManualAndPhysicalProof()
        throws
    {
        let status = ProfessionalBrushPerformanceStatus(
            schemaVersion: 1,
            correctnessPassed: true,
            gpuName: "Apple Paravirtual device",
            gpuClassification: "paravirtual",
            cpuPreparationP95Milliseconds: 1.25,
            cpuPreparationBudgetMilliseconds: 2,
            gpu500DabMilliseconds: 2.5,
            gpu500DabBudgetMilliseconds: 3,
            completedStrokeLengthIndependent: true,
            hotPathCompilerResourceCountersZero: true
        )

        #expect(
            try ProfessionalBrushEvidenceValidator.validatePerformanceStatus(
                try sortedJSON(status),
                expectedGPUName: "Apple Paravirtual device",
                measuredCPUP95Milliseconds: 1.25
            ) == .pending
        )
    }

    @Test
    func performanceStatusRejectsThresholdCounterAndClassificationMutations()
        throws
    {
        let valid: [String: Any] = [
            "schemaVersion": 1,
            "correctnessPassed": true,
            "gpuName": "Apple Paravirtual device",
            "gpuClassification": "paravirtual",
            "cpuPreparationP95Milliseconds": 1.25,
            "cpuPreparationBudgetMilliseconds": 2.0,
            "gpu500DabMilliseconds": 2.5,
            "gpu500DabBudgetMilliseconds": 3.0,
            "completedStrokeLengthIndependent": true,
            "hotPathCompilerResourceCountersZero": true,
        ]
        let mutations: [(String, Any)] = [
            ("correctnessPassed", false),
            ("gpuClassification", "physical"),
            ("cpuPreparationP95Milliseconds", 2.0),
            ("cpuPreparationBudgetMilliseconds", 3.0),
            ("completedStrokeLengthIndependent", false),
            ("hotPathCompilerResourceCountersZero", false),
        ]

        for (key, value) in mutations {
            var object = valid
            object[key] = value
            #expect(throws: Error.self, "\(key)") {
                _ = try ProfessionalBrushEvidenceValidator
                    .validatePerformanceStatus(
                        try JSONSerialization.data(
                            withJSONObject: object,
                            options: [.sortedKeys]
                        ),
                        expectedGPUName: "Apple Paravirtual device",
                        measuredCPUP95Milliseconds: 1.25
                    )
            }
        }
    }

    @Test
    func provenanceBindsCommitTreeToolchainStageFourAndArtifactRoot()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "professional-provenance-\(UUID().uuidString)",
                isDirectory: true
            )
        let commit = String(repeating: "a", count: 40)
        let tree = String(repeating: "b", count: 64)
        let stageFourManifest = String(repeating: "c", count: 64)
        let valid: [String: Any] = [
            "schemaVersion": 1,
            "commit": commit,
            "sourceTreeSHA256": tree,
            "configuration": "Debug",
            "swiftVersion": "Swift 6",
            "xcodeVersion": "Xcode 26",
            "xcodegenVersion": "2.44",
            "operatingSystem": "macOS",
            "kernel": "Darwin",
            "hardwareMachine": "arm64",
            "hardwareModel": "VirtualMac",
            "gpuName": "Apple Paravirtual device",
            "gpuClassification": "paravirtual",
            "artifactRoot": root.path,
            "stageFourExitStatus": 2,
            "stageFourArtifactManifestSHA256": stageFourManifest,
        ]

        try ProfessionalBrushEvidenceValidator.validateProvenance(
            try JSONSerialization.data(
                withJSONObject: valid,
                options: [.sortedKeys]
            ),
            artifactRoot: root,
            expectedCommit: commit,
            expectedSourceTreeSHA256: tree,
            expectedStageFourManifestSHA256: stageFourManifest
        )

        for key in valid.keys {
            var object = valid
            object.removeValue(forKey: key)
            #expect(throws: Error.self, "\(key)") {
                try ProfessionalBrushEvidenceValidator.validateProvenance(
                    try JSONSerialization.data(
                        withJSONObject: object,
                        options: [.sortedKeys]
                    ),
                    artifactRoot: root,
                    expectedCommit: commit,
                    expectedSourceTreeSHA256: tree,
                    expectedStageFourManifestSHA256: stageFourManifest
                )
            }
        }
    }

    @Test
    func absentOptionalPhysicalEvidenceContinuesAsPending() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repositoryRoot.appendingPathComponent(
            "scripts/verify-brush-stage5.sh"
        )
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            """
            set -eEuo pipefail
            artifacts="$(mktemp -d)"
            trap 'rm -rf "$artifacts"' EXIT
            function_source="$(
              sed -n \
                '/^copy_physical_profiles()/,/^write_json_status_and_provenance()/p' \
                "$1" \
                | sed '$d'
            )"
            eval "$function_source"
            unset PROFESSIONAL_BRUSH_PHYSICAL_EVIDENCE_DIR
            copy_physical_profiles
            printf 'continued-as-pending\\n'
            """,
            "professional-physical-regression",
            script.path,
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        #expect(
            process.terminationStatus == 0,
            "stderr: \(String(decoding: error, as: UTF8.self))"
        )
        #expect(output == Data("continued-as-pending\n".utf8))
    }
}

private func artifactManifestFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "professional-manifest-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let first = root.appendingPathComponent("a.txt")
    let second = root.appendingPathComponent("b.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let entries = try [first, second].map { url in
        "\(ProfessionalBrushEvidenceValidator.sha256(try Data(contentsOf: url)))  ./\(url.lastPathComponent)"
    }
    try Data((entries.joined(separator: "\n") + "\n").utf8).write(
        to: root.appendingPathComponent("artifact-sha256.txt")
    )
    return root
}

private func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
