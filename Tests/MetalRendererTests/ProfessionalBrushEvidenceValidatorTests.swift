import Foundation
@testable import MetalRenderer
@testable import ProfessionalBrushEvidenceValidation
import Testing

@Suite("Professional brush artifact validator", .serialized)
struct ProfessionalBrushEvidenceValidatorTests {
    @Test
    func artifactManifestRequiresExactSortedUniqueFilesAndHashes() throws {
        let root = try artifactManifestFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        try ArtifactFileSystem.validateManifest(root: root)

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
                try ArtifactFileSystem.validateManifest(root: root)
            }
        }

        try Data(original.utf8).write(to: manifest)
        try Data("extra".utf8).write(
            to: root.appendingPathComponent("extra.txt")
        )
        #expect(throws: Error.self) {
            try ArtifactFileSystem.validateManifest(root: root)
        }

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("extra.txt")
        )
        try Data("hidden".utf8).write(
            to: root.appendingPathComponent(".unmanifested")
        )
        #expect(throws: Error.self) {
            try ArtifactFileSystem.validateManifest(root: root)
        }
    }

    @Test
    func unknownGPUCannotBeClassifiedAsPhysical() {
        #expect(
            ArtifactFileSystem.gpuClassification("Mystery GPU")
                == "unknown"
        )
        #expect(
            ArtifactFileSystem.gpuClassification("Apple M4 Max")
                == "physical"
        )
        #expect(
            ArtifactFileSystem.gpuClassification(
                "Apple ParavirtualGraphics"
            ) == "paravirtual"
        )
    }

    @Test
    func performanceStatusIsArtifactDerivedAndUnknownGPUStaysPending()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(
            withJSONObject: ["dabGPUMilliseconds": [2.5]],
            options: [.sortedKeys]
        ).write(
            to: logs.appendingPathComponent(
                "five-hundred-dabs.benchmark.json"
            )
        )
        let valid: [String: Any] = [
            "schemaVersion": 1,
            "correctnessPassed": true,
            "gpuName": "Mystery GPU",
            "gpuClassification": "unknown",
            "cpuPreparationP95Milliseconds": 1.25,
            "cpuPreparationBudgetMilliseconds": 2.0,
            "gpu500DabMilliseconds": 2.5,
            "gpu500DabBudgetMilliseconds": 3.0,
            "completedStrokeLengthIndependent": true,
            "hotPathCompilerResourceCountersZero": true,
        ]
        #expect(
            try PerformanceStatusValidator.validate(
                try JSONSerialization.data(
                    withJSONObject: valid,
                    options: [.sortedKeys]
                ),
                expectedGPUName: "Mystery GPU",
                measuredCPUP95Milliseconds: 1.25,
                stageFourRoot: root
            ) == false
        )
        for (key, value) in [
            ("gpuClassification", "physical" as Any),
            ("correctnessPassed", false as Any),
            ("cpuPreparationP95Milliseconds", 2.0 as Any),
            ("gpu500DabMilliseconds", 2.4 as Any),
        ] {
            var mutated = valid
            mutated[key] = value
            #expect(throws: Error.self, "\(key)") {
                _ = try PerformanceStatusValidator.validate(
                    try JSONSerialization.data(
                        withJSONObject: mutated,
                        options: [.sortedKeys]
                    ),
                    expectedGPUName: "Mystery GPU",
                    measuredCPUP95Milliseconds: 1.25,
                    stageFourRoot: root
                )
            }
        }
    }

    @Test
    func provenanceBindsRawFilesAndRendererExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw-provenance")
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(
            at: raw,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true
        )
        let rawValues: [String: String] = [
            "hardware-machine.txt": "arm64\n",
            "hardware-model.txt": "VirtualMac\n",
            "hardware.txt": "",
            "kernel.txt": "Darwin Fixture\n",
            "operating-system.txt": "ProductVersion: 26.0\n",
            "swift-toolchain.txt": "Swift 6\nBuild\n",
            "validator-nm-undefined.txt": "_Foundation\n",
            "validator-otool.txt": "/usr/lib/libSystem.B.dylib\n",
            "xcode-toolchain.txt": "Xcode 26\nBuild 1\n",
            "xcodegen-toolchain.txt": "Version: 2.44\n",
        ]
        var rawHashes: [String: String] = [:]
        for (name, value) in rawValues {
            let data = Data(value.utf8)
            try data.write(to: raw.appendingPathComponent(name))
            rawHashes[name] = ArtifactFileSystem.sha256(data)
        }
        let executable = Data("renderer".utf8)
        try executable.write(
            to: runtime.appendingPathComponent("PatternSpike")
        )
        let commit = String(repeating: "a", count: 40)
        let tree = String(repeating: "b", count: 64)
        let stageFour = String(repeating: "c", count: 64)
        let provenance: [String: Any] = [
            "schemaVersion": 2,
            "commit": commit,
            "sourceTreeSHA256": tree,
            "configuration": "Debug",
            "swiftVersion": "Swift 6 Build",
            "xcodeVersion": "Xcode 26 Build 1",
            "xcodegenVersion": "Version: 2.44",
            "operatingSystem": "Fixture OS",
            "kernel": "Darwin Fixture",
            "hardwareMachine": "arm64",
            "hardwareModel": "VirtualMac",
            "gpuName": "Apple Paravirtual device",
            "gpuClassification": "paravirtual",
            "artifactRoot": root.path,
            "stageFourExitStatus": 2,
            "stageFourArtifactManifestSHA256": stageFour,
            "rawProvenanceSHA256": rawHashes,
            "rendererExecutableSHA256":
                ArtifactFileSystem.sha256(executable),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: provenance,
            options: [.sortedKeys]
        )
        try data.write(to: root.appendingPathComponent("provenance.json"))
        _ = try ProvenanceValidator.validate(
            root: raw,
            artifactRoot: root,
            expectedCommit: commit,
            expectedSourceTreeSHA256: tree,
            expectedStageFourManifestSHA256: stageFour,
            expectedStageFourExitStatus: 2
        )

        let kernelURL = raw.appendingPathComponent("kernel.txt")
        try Data().write(to: kernelURL)
        var emptyKernel = provenance
        var emptyKernelHashes = rawHashes
        emptyKernelHashes["kernel.txt"] =
            ArtifactFileSystem.sha256(Data())
        emptyKernel["rawProvenanceSHA256"] = emptyKernelHashes
        try JSONSerialization.data(
            withJSONObject: emptyKernel,
            options: [.sortedKeys]
        ).write(to: root.appendingPathComponent("provenance.json"))
        #expect(throws: Error.self) {
            _ = try ProvenanceValidator.validate(
                root: raw,
                artifactRoot: root,
                expectedCommit: commit,
                expectedSourceTreeSHA256: tree,
                expectedStageFourManifestSHA256: stageFour,
                expectedStageFourExitStatus: 2
            )
        }
        try Data(rawValues["kernel.txt"]!.utf8).write(to: kernelURL)

        var mutated = provenance
        mutated["rendererExecutableSHA256"] =
            String(repeating: "0", count: 64)
        try JSONSerialization.data(
            withJSONObject: mutated,
            options: [.sortedKeys]
        ).write(to: root.appendingPathComponent("provenance.json"))
        #expect(throws: Error.self) {
            _ = try ProvenanceValidator.validate(
                root: raw,
                artifactRoot: root,
                expectedCommit: commit,
                expectedSourceTreeSHA256: tree,
                expectedStageFourManifestSHA256: stageFour,
                expectedStageFourExitStatus: 2
            )
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

    @Test
    func suppliedUnknownPhysicalProfileFailsBeforeCopying() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repositoryRoot.appendingPathComponent(
            "scripts/verify-brush-stage5.sh"
        )
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            """
            set -eEuo pipefail
            artifacts="$(mktemp -d)"
            input="$(mktemp -d)"
            trap 'rm -rf "$artifacts" "$input"' EXIT
            mkdir "$input/a14-floor-typo"
            function_source="$(
              sed -n \
                '/^copy_physical_profiles()/,/^write_json_status_and_provenance()/p' \
                "$1" \
                | sed '$d'
            )"
            eval "$function_source"
            fail() {
              printf '%s\\n' "$*" >&2
              exit 91
            }
            export PROFESSIONAL_BRUSH_PHYSICAL_EVIDENCE_DIR="$input"
            copy_physical_profiles
            """,
            "professional-physical-unknown-regression",
            script.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        #expect(
            process.terminationStatus == 91,
            "stderr: \(String(decoding: error, as: UTF8.self))"
        )
    }

    @Test
    func suppliedManualEvidenceIsCopiedWithoutSelfApproval() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repositoryRoot.appendingPathComponent(
            "scripts/verify-brush-stage5.sh"
        )
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            """
            set -eEuo pipefail
            artifacts="$(mktemp -d)"
            input="$(mktemp)"
            trap 'rm -rf "$artifacts" "$input"' EXIT
            mkdir -p "$artifacts/manual-cards"
            printf '{"user":"owned"}\\n' >"$input"
            function_source="$(
              sed -n \
                '/^copy_manual_evidence()/,/^write_json_status_and_provenance()/p' \
                "$1" \
                | sed '$d'
            )"
            eval "$function_source"
            export PROFESSIONAL_BRUSH_MANUAL_EVIDENCE_FILE="$input"
            copy_manual_evidence
            cmp "$input" "$artifacts/manual-cards/catalog.json"
            printf 'copied-unchanged\\n'
            """,
            "professional-manual-input-regression",
            script.path,
        ]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        #expect(
            process.terminationStatus == 0,
            "stderr: \(String(decoding: stderr, as: UTF8.self))"
        )
        #expect(stdout == Data("copied-unchanged\n".utf8))
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
        "\(ArtifactFileSystem.sha256(try Data(contentsOf: url)))  ./\(url.lastPathComponent)"
    }
    try Data((entries.joined(separator: "\n") + "\n").utf8).write(
        to: root.appendingPathComponent("artifact-sha256.txt")
    )
    return root
}
