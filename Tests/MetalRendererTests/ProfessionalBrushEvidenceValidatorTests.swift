import Foundation
import BrushDepositionEvidenceValidation
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
        let fixture = try professionalPerformanceFixture(
            gpuName: "Mystery GPU"
        )
        let root = fixture.root
        defer { try? FileManager.default.removeItem(at: root) }
        let valid: [String: Any] = [
            "schemaVersion": 2,
            "correctnessPassed": true,
            "gpuName": "Mystery GPU",
            "gpuClassification": "unknown",
            "cpuPreparationP95Milliseconds": 1.25,
            "cpuPreparationBudgetMilliseconds": 2.0,
            "gpu500DabMilliseconds": 1.0,
            "gpu500DabBudgetMilliseconds": 3.0,
        ]
        #expect(
            try PerformanceStatusValidator.validate(
                try JSONSerialization.data(
                    withJSONObject: valid,
                    options: [.sortedKeys]
                ),
                expectedGPUName: "Mystery GPU",
                expectedOperatingSystem: fixture.operatingSystem,
                expectedCommit: fixture.commit,
                expectedRendererSHA256: fixture.renderer,
                measuredCPUP95Milliseconds: 1.25,
                positiveRoot: root
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
                    expectedOperatingSystem: fixture.operatingSystem,
                    expectedCommit: fixture.commit,
                    expectedRendererSHA256: fixture.renderer,
                    measuredCPUP95Milliseconds: 1.25,
                    positiveRoot: root
                )
            }
        }
    }

    @Test
    func copiedStageFourPhysicalProfilesAreNotStageFiveEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stageFour = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: stageFour)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = stageFour.appendingPathComponent(
            "physical-profiles",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        for profile in StageFourEvidenceValidator.requiredPhysicalProfiles {
            let sourceProfile = source.appendingPathComponent(
                profile,
                isDirectory: true
            )
            let copiedProfile = root.appendingPathComponent(
                profile,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: sourceProfile,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: copiedProfile,
                withIntermediateDirectories: true
            )
            let bytes = Data("stage-four-\(profile)".utf8)
            try bytes.write(
                to: sourceProfile.appendingPathComponent("evidence.json")
            )
            try bytes.write(
                to: copiedProfile.appendingPathComponent("evidence.json")
            )
        }

        #expect(throws: Error.self) {
            _ = try PhysicalEvidenceValidator.validate(
                root: root,
                expectedCommit: String(repeating: "a", count: 40),
                expectedSourceTreeSHA256:
                    String(repeating: "b", count: 64),
                expectedRendererSHA256:
                    String(repeating: "c", count: 64)
            )
        }
    }

    @Test
    func performanceStatusRejectsSelfAttestedInvariantBooleans() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try testJSONData([
            "dabGPUMilliseconds": [1.0],
        ]).write(
            to: logs.appendingPathComponent(
                "five-hundred-dabs.benchmark.json"
            )
        )
        let status = try testJSONData([
            "schemaVersion": 1,
            "correctnessPassed": true,
            "gpuName": "Apple M4",
            "gpuClassification": "physical",
            "cpuPreparationP95Milliseconds": 1.0,
            "cpuPreparationBudgetMilliseconds": 2.0,
            "gpu500DabMilliseconds": 1.0,
            "gpu500DabBudgetMilliseconds": 3.0,
            "completedStrokeLengthIndependent": true,
            "hotPathCompilerResourceCountersZero": true,
        ])

        #expect(throws: Error.self) {
            _ = try PerformanceStatusValidator.validate(
                status,
                expectedGPUName: "Apple M4",
                expectedOperatingSystem: "Version 26.0",
                expectedCommit: String(repeating: "a", count: 40),
                expectedRendererSHA256:
                    String(repeating: "b", count: 64),
                measuredCPUP95Milliseconds: 1,
                positiveRoot: root
            )
        }
    }

    @Test
    func physicalEvidenceBindsEveryProfileAndProfessionalBrushToRawData()
        throws
    {
        let fixture = try professionalPhysicalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(
            try PhysicalEvidenceValidator.validate(
                root: fixture.root,
                expectedCommit: fixture.commit,
                expectedSourceTreeSHA256: fixture.tree,
                expectedRendererSHA256: fixture.renderer
            )
        )

        let profile = fixture.root.appendingPathComponent(
            "pencil/evidence.json"
        )
        let validProfile = try Data(contentsOf: profile)
        try mutateTestJSONObject(at: profile) { object in
            var workloads = object["workloads"] as! [[String: Any]]
            workloads.removeLast()
            object["workloads"] = workloads
        }
        #expect(throws: Error.self) {
            _ = try PhysicalEvidenceValidator.validate(
                root: fixture.root,
                expectedCommit: fixture.commit,
                expectedSourceTreeSHA256: fixture.tree,
                expectedRendererSHA256: fixture.renderer
            )
        }
        try validProfile.write(to: profile)

        let raw = fixture.root.appendingPathComponent(
            "pencil/raw/builtin.professional-graphite-pencil.json"
        )
        let validRaw = try Data(contentsOf: raw)
        try mutateTestJSONObject(at: raw) {
            $0["semanticHash"] = String(repeating: "0", count: 64)
        }
        #expect(throws: Error.self) {
            _ = try PhysicalEvidenceValidator.validate(
                root: fixture.root,
                expectedCommit: fixture.commit,
                expectedSourceTreeSHA256: fixture.tree,
                expectedRendererSHA256: fixture.renderer
            )
        }
        try validRaw.write(to: raw)

        try mutateTestJSONObject(at: raw) { object in
            var missed = object["missedFrameFlags"] as! [Any]
            missed[0] = true
            object["missedFrameFlags"] = missed
        }
        #expect(throws: Error.self) {
            _ = try PhysicalEvidenceValidator.validate(
                root: fixture.root,
                expectedCommit: fixture.commit,
                expectedSourceTreeSHA256: fixture.tree,
                expectedRendererSHA256: fixture.renderer
            )
        }
        try validRaw.write(to: raw)

        try mutateTestJSONObject(at: profile) {
            $0["profileID"] = "wacom"
        }
        #expect(throws: Error.self) {
            _ = try PhysicalEvidenceValidator.validate(
                root: fixture.root,
                expectedCommit: fixture.commit,
                expectedSourceTreeSHA256: fixture.tree,
                expectedRendererSHA256: fixture.renderer
            )
        }
    }

    @Test
    func performanceEvidenceRejectsIdentityDigestCounterAndWorkloadMutations()
        throws
    {
        func fixture() throws -> ProfessionalPerformanceTestFixture {
            try professionalPerformanceFixture(gpuName: "Apple M4")
        }
        func reject(
            _ fixture: ProfessionalPerformanceTestFixture,
            gpuMaximum: Double = 1
        ) {
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            #expect(throws: Error.self) {
                _ = try validatePerformanceFixture(
                    fixture,
                    gpuMaximum: gpuMaximum
                )
            }
        }

        var value = try fixture()
        try FileManager.default.removeItem(
            at: value.root.appendingPathComponent(
                "professional-technical-ink"
            )
        )
        reject(value)

        value = try fixture()
        try FileManager.default.createDirectory(
            at: value.root.appendingPathComponent("extra-brush"),
            withIntermediateDirectories: false
        )
        reject(value)

        value = try fixture()
        try mutatePerformanceRawAndRebind(
            fixture: value,
            scene: "professional-graphite-pencil",
            filename: "professional-five-hundred-dabs.raw.json",
            referenceKey: "fiveHundredDabs"
        ) {
            $0["semanticHash"] = String(repeating: "0", count: 64)
        }
        reject(value)

        value = try fixture()
        try mutateTestJSONObject(
            at: value.root.appendingPathComponent(
                "professional-graphite-pencil/"
                    + "professional-five-hundred-dabs.raw.json"
            )
        ) {
            $0["recordCount"] = 499
        }
        reject(value)

        value = try fixture()
        try FileManager.default.removeItem(
            at: value.root.appendingPathComponent(
                "professional-natural-charcoal/"
                    + "professional-long-stroke.raw.json"
            )
        )
        reject(value)

        value = try fixture()
        try mutatePerformanceRawAndRebind(
            fixture: value,
            scene: "professional-natural-charcoal",
            filename: "professional-long-stroke.raw.json",
            referenceKey: "longStroke"
        ) { raw in
            var after =
                raw["compilerCountersAfter"] as! [String: Any]
            after["textureUploadCount"] = 5
            raw["compilerCountersAfter"] = after
        }
        reject(value)

        value = try fixture()
        try mutatePerformanceRawAndRebind(
            fixture: value,
            scene: "professional-chisel-marker",
            filename: "professional-long-stroke.raw.json",
            referenceKey: "longStroke"
        ) { raw in
            var restamped =
                raw["restampedInstanceCounts"] as! [Int]
            restamped[64] = 1
            raw["restampedInstanceCounts"] = restamped
        }
        reject(value)

        value = try fixture()
        try mutatePerformanceRawAndRebind(
            fixture: value,
            scene: "professional-chisel-marker",
            filename: "professional-long-stroke.raw.json",
            referenceKey: "longStroke"
        ) { raw in
            var newInstances =
                raw["newInstanceCounts"] as! [Any]
            newInstances[64] = true
            raw["newInstanceCounts"] = newInstances
        }
        reject(value)

        value = try fixture()
        let traceDirectory = value.root.appendingPathComponent(
            "professional-technical-ink"
        )
        let traceURL = traceDirectory.appendingPathComponent(
            "professional-long-stroke-trace.json"
        )
        try mutateTestJSONObject(at: traceURL) { trace in
            var samples = trace["samples"] as! [[String: Any]]
            samples[64]["x"] = 65.0
            trace["samples"] = samples
        }
        let changedTraceDigest = ArtifactFileSystem.sha256(
            try Data(contentsOf: traceURL)
        )
        try mutatePerformanceRawAndRebind(
            fixture: value,
            scene: "professional-technical-ink",
            filename: "professional-long-stroke.raw.json",
            referenceKey: "longStroke"
        ) {
            $0["traceSHA256"] = changedTraceDigest
        }
        reject(value)

        value = try fixture()
        try mutatePerformanceRawAndRebind(
            fixture: value,
            scene: "professional-technical-ink",
            filename: "professional-five-hundred-dabs.raw.json",
            referenceKey: "fiveHundredDabs"
        ) {
            $0["gpuMilliseconds"] = [3.0, 2.0, 1.0]
        }
        reject(value, gpuMaximum: 3)

        value = try fixture()
        try mutateTestJSONObject(
            at: value.root.appendingPathComponent(
                "professional-chisel-marker/"
                    + "professional-performance.json"
            )
        ) {
            $0["unexpected"] = true
        }
        reject(value)
    }

    @Test
    func physicalEvidenceRejectsPartialProfileSetsAndUnknownFiles()
        throws
    {
        var fixture = try professionalPhysicalFixture()
        try FileManager.default.removeItem(
            at: fixture.root.appendingPathComponent("wacom")
        )
        #expect(throws: Error.self) {
            _ = try PhysicalEvidenceValidator.validate(
                root: fixture.root,
                expectedCommit: fixture.commit,
                expectedSourceTreeSHA256: fixture.tree,
                expectedRendererSHA256: fixture.renderer
            )
        }
        try? FileManager.default.removeItem(at: fixture.root)

        fixture = try professionalPhysicalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("unknown".utf8).write(
            to: fixture.root.appendingPathComponent(
                "wacom/raw/unknown.json"
            )
        )
        #expect(throws: Error.self) {
            _ = try PhysicalEvidenceValidator.validate(
                root: fixture.root,
                expectedCommit: fixture.commit,
                expectedSourceTreeSHA256: fixture.tree,
                expectedRendererSHA256: fixture.renderer
            )
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
            "operating-system.txt":
                "ProductName:\t\tmacOS\n"
                + "ProductVersion:\t\t26.0\n"
                + "BuildVersion:\t\t25A123\n",
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
            "operatingSystem": "Version 26.0 (Build 25A123)",
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

        for rawOperatingSystem in [
            "ProductName:\t\tmacOS\n"
                + "ProductVersion:\t\t26.0\n"
                + "BuildVersion:\t\t25A999\n",
            "ProductName:\t\tmacOS\n"
                + "ProductVersion:\t\t26.0\n"
                + "UnknownVersion:\t\t25A123\n",
            "ProductName:\t\tmacOS\n"
                + "ProductVersion:\t\t26.0\n"
                + "BuildVersion:\t\t25A123\n"
                + "Extra:\t\tfield\n",
        ] {
            let operatingSystemURL = raw.appendingPathComponent(
                "operating-system.txt"
            )
            let rawOperatingSystemData = Data(rawOperatingSystem.utf8)
            try rawOperatingSystemData.write(to: operatingSystemURL)
            var contradictory = provenance
            var contradictoryHashes = rawHashes
            contradictoryHashes["operating-system.txt"] =
                ArtifactFileSystem.sha256(rawOperatingSystemData)
            contradictory["rawProvenanceSHA256"] = contradictoryHashes
            try JSONSerialization.data(
                withJSONObject: contradictory,
                options: [.sortedKeys]
            ).write(to: root.appendingPathComponent("provenance.json"))
            #expect(
                throws: Error.self,
                "raw OS: \(rawOperatingSystem)"
            ) {
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
        try Data(rawValues["operating-system.txt"]!.utf8).write(
            to: raw.appendingPathComponent("operating-system.txt")
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
    func characterizationBaselineBindsEveryRecordToGoldenTruth() throws {
        let baseline =
            try professionalCharacterizationBaselineForValidation()
        let valid = try baseline.encoded()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let url = root.appendingPathComponent("baseline.json")
        try valid.write(to: url)
        _ = try CharacterizationValidator.validateBaseline(url)

        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("family", { $0["family"] = "Wrong Family" }),
            ("semantic hash", {
                $0["definitionSemanticHash"] =
                    String(repeating: "0", count: 64)
            }),
            ("logical digest", {
                $0["logicalDabDigest"] =
                    String(repeating: "0", count: 64)
            }),
            ("metric", {
                $0["maximumDiameter"] =
                    (($0["maximumDiameter"] as? NSNumber)?.doubleValue
                        ?? 0) + 1
            }),
        ]
        for (name, mutate) in mutations {
            var object = try #require(
                JSONSerialization.jsonObject(with: valid)
                    as? [String: Any]
            )
            var records = try #require(
                object["records"] as? [[String: Any]]
            )
            let index = try #require(
                records.firstIndex {
                    $0["traceName"] as? String
                        == "professional-fast-line"
                }
            )
            mutate(&records[index])
            object["records"] = records
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: url)
            #expect(throws: Error.self, "\(name)") {
                _ = try CharacterizationValidator.validateBaseline(url)
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

private func testJSONData(_ object: Any) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
}

private struct ProfessionalPerformanceTestFixture {
    let root: URL
    let commit: String
    let renderer: String
    let operatingSystem: String
}

private func professionalPerformanceFixture(
    gpuName: String
) throws -> ProfessionalPerformanceTestFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "professional-performance-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let commit = String(repeating: "a", count: 40)
    let renderer = String(repeating: "b", count: 64)
    let operatingSystem = "Version 26.0 (Build 25A1)"
    let truths: [(String, String, String, [(String, String, Int)])] = [
        (
            "professional-chisel-marker",
            "builtin.professional-chisel-marker",
            "2c1b9c2c7770dacfd4eee5e5fc6bbbf57b202bbcb15b6edca37de868ed2ec1f1",
            [("builtin.shape.marker-chisel", "shape", 8)]
        ),
        (
            "professional-graphite-pencil",
            "builtin.professional-graphite-pencil",
            "10af674df1d65e52efde75a68860e554c31e75dda12c17027bb728a47550aa52",
            [
                ("builtin.grain.graphite", "grain", 9),
                ("builtin.grain.paper", "grain", 7),
                ("builtin.shape.graphite-tip", "shape", 8),
            ]
        ),
        (
            "professional-natural-charcoal",
            "builtin.professional-natural-charcoal",
            "c686a582f773263649cb5259851eeffbe2403d38ed9a2be4ae9114bb7c8bd007",
            [
                ("builtin.grain.charcoal", "grain", 9),
                ("builtin.grain.paper", "grain", 7),
                ("builtin.shape.charcoal-tip", "shape", 8),
                ("builtin.shape.soft-round", "shape", 7),
            ]
        ),
        (
            "professional-technical-ink",
            "builtin.professional-technical-ink",
            "394e34d6ddccb13978714550537cae9b2cab9e566032b6b3ddc25b6eab0d5534",
            [("builtin.shape.technical-nib", "shape", 8)]
        ),
    ]
    let counters: [String: Any] = [
        "packageDecodeCount": 1,
        "imageDecodeCount": 0,
        "textureUploadCount": 1,
        "cacheHitCount": 0,
        "activationCount": 1,
    ]
    let source: [String: Any] = [
        "gitCommit": commit,
        "rendererExecutableSHA256": renderer,
        "gpuName": gpuName,
        "operatingSystem": operatingSystem,
    ]
    for (scene, definitionID, semanticHash, rawResources) in truths {
        let directory = root.appendingPathComponent(
            scene,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let resources = rawResources.map {
            [
                "identity": $0.0,
                "kind": $0.1,
                "mipCount": $0.2,
            ] as [String: Any]
        }
        var traceSamples: [[String: Any]] = []
        for index in 0..<128 {
            let phase =
                index == 0
                    ? "began"
                    : (index == 127 ? "ended" : "moved")
            traceSamples.append([
                "x": index.isMultiple(of: 2) ? 64.0 : 448.0,
                "y": 256.0,
                "pressure": Double(Float(0.58)),
                "timestamp": Double(index) * 0.004,
                "phase": phase,
                "source": "mouse",
                "kind": "actual",
            ])
        }
        let trace = try testJSONData([
            "schemaVersion": 1,
            "scene": scene,
            "definitionID": definitionID,
            "semanticHash": semanticHash,
            "samples": traceSamples,
        ])
        try trace.write(
            to: directory.appendingPathComponent(
                "professional-long-stroke-trace.json"
            )
        )
        let five = try testJSONData([
            "schemaVersion": 1,
            "workloadID": "professional-500-dabs",
            "scene": scene,
            "definitionID": definitionID,
            "semanticHash": semanticHash,
            "resolvedResources": resources,
            "source": source,
            "recordCount": 500,
            "measurementCount": 3,
            "gpuMilliseconds": [1.0, 0.9, 0.8],
            "compilerCountersBefore": counters,
            "compilerCountersAfter": counters,
        ])
        try five.write(
            to: directory.appendingPathComponent(
                "professional-five-hundred-dabs.raw.json"
            )
        )
        let long = try testJSONData([
            "schemaVersion": 1,
            "workloadID": "professional-long-stroke",
            "scene": scene,
            "definitionID": definitionID,
            "semanticHash": semanticHash,
            "resolvedResources": resources,
            "source": source,
            "inputSampleCount": 128,
            "tracePath": "professional-long-stroke-trace.json",
            "traceSHA256": ArtifactFileSystem.sha256(trace),
            "cpuPreparationMilliseconds":
                Array(repeating: 0.1, count: 128),
            "gpuMilliseconds": Array(repeating: 0.1, count: 128),
            "newInstanceCounts": Array(repeating: 64, count: 128),
            "restampedInstanceCounts": Array(repeating: 0, count: 128),
            "logicalDabCount": 128,
            "projectedInstanceCount": 8_192,
            "replayMode": "replayTail",
            "replayMaximumDabs": 2_048,
            "replayMaximumProjectedInstances": 4_096,
            "compilerCountersBefore": counters,
            "compilerCountersAfter": counters,
        ])
        try long.write(
            to: directory.appendingPathComponent(
                "professional-long-stroke.raw.json"
            )
        )
        let index = try testJSONData([
            "schemaVersion": 1,
            "scene": scene,
            "definitionID": definitionID,
            "semanticHash": semanticHash,
            "resolvedResources": resources,
            "source": source,
            "fiveHundredDabs": [
                "path": "professional-five-hundred-dabs.raw.json",
                "sha256": ArtifactFileSystem.sha256(five),
            ],
            "longStroke": [
                "path": "professional-long-stroke.raw.json",
                "sha256": ArtifactFileSystem.sha256(long),
            ],
        ])
        try index.write(
            to: directory.appendingPathComponent(
                "professional-performance.json"
            )
        )
    }
    return ProfessionalPerformanceTestFixture(
        root: root,
        commit: commit,
        renderer: renderer,
        operatingSystem: operatingSystem
    )
}

private struct ProfessionalPhysicalTestFixture {
    let root: URL
    let commit: String
    let tree: String
    let renderer: String
}

private func professionalPhysicalFixture()
    throws -> ProfessionalPhysicalTestFixture
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "professional-physical-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let commit = String(repeating: "a", count: 40)
    let tree = String(repeating: "b", count: 64)
    let renderer = String(repeating: "c", count: 64)
    let source: [String: Any] = [
        "commit": commit,
        "sourceTreeSHA256": tree,
        "rendererExecutableSHA256": renderer,
    ]
    let truths: [(String, String, [(String, String, Int)])] = [
        (
            "builtin.professional-chisel-marker",
            "2c1b9c2c7770dacfd4eee5e5fc6bbbf57b202bbcb15b6edca37de868ed2ec1f1",
            [("builtin.shape.marker-chisel", "shape", 8)]
        ),
        (
            "builtin.professional-graphite-pencil",
            "10af674df1d65e52efde75a68860e554c31e75dda12c17027bb728a47550aa52",
            [
                ("builtin.grain.graphite", "grain", 9),
                ("builtin.grain.paper", "grain", 7),
                ("builtin.shape.graphite-tip", "shape", 8),
            ]
        ),
        (
            "builtin.professional-natural-charcoal",
            "c686a582f773263649cb5259851eeffbe2403d38ed9a2be4ae9114bb7c8bd007",
            [
                ("builtin.grain.charcoal", "grain", 9),
                ("builtin.grain.paper", "grain", 7),
                ("builtin.shape.charcoal-tip", "shape", 8),
                ("builtin.shape.soft-round", "shape", 7),
            ]
        ),
        (
            "builtin.professional-technical-ink",
            "394e34d6ddccb13978714550537cae9b2cab9e566032b6b3ddc25b6eab0d5534",
            [("builtin.shape.technical-nib", "shape", 8)]
        ),
    ]
    let profiles: [(String, [String: Any])] = [
        (
            "a14Floor60Hz",
            physicalDevice(
                platform: "iPadOS", hardware: "iPad13,2",
                gpu: "Apple A14 GPU", refresh: 60,
                inputKind: "touch", vendor: "Apple",
                model: "Multi-Touch Display",
                telemetry: "UITouch.timestamp", prediction: "none"
            )
        ),
        (
            "inputToPhoton",
            physicalDevice(
                platform: "iPadOS", hardware: "iPad16,1",
                gpu: "Apple M4", refresh: 60,
                inputKind: "applePencil", vendor: "Apple",
                model: "Apple Pencil Pro",
                telemetry:
                    "UIEvent.coalescedTouches+predictedTouches",
                prediction: "coalescedAndPredicted"
            )
        ),
        (
            "memoryWarning",
            physicalDevice(
                platform: "iPadOS", hardware: "iPad16,1",
                gpu: "Apple M4", refresh: 60,
                inputKind: "touch", vendor: "Apple",
                model: "Multi-Touch Display",
                telemetry: "UITouch.timestamp", prediction: "none"
            )
        ),
        (
            "pencil",
            physicalDevice(
                platform: "iPadOS", hardware: "iPad16,1",
                gpu: "Apple M4", refresh: 60,
                inputKind: "applePencil", vendor: "Apple",
                model: "Apple Pencil Pro",
                telemetry:
                    "UIEvent.coalescedTouches+predictedTouches",
                prediction: "coalescedAndPredicted"
            )
        ),
        (
            "referenceMSeriesProMotion120Hz",
            physicalDevice(
                platform: "iPadOS", hardware: "iPad16,1",
                gpu: "Apple M4", refresh: 120,
                inputKind: "touch", vendor: "Apple",
                model: "Multi-Touch Display",
                telemetry: "UITouch.timestamp", prediction: "none"
            )
        ),
        (
            "suspendResume",
            physicalDevice(
                platform: "iPadOS", hardware: "iPad16,1",
                gpu: "Apple M4", refresh: 60,
                inputKind: "touch", vendor: "Apple",
                model: "Multi-Touch Display",
                telemetry: "UITouch.timestamp", prediction: "none"
            )
        ),
        (
            "sustainedThermal",
            physicalDevice(
                platform: "iPadOS", hardware: "iPad16,1",
                gpu: "Apple M4", refresh: 60,
                inputKind: "touch", vendor: "Apple",
                model: "Multi-Touch Display",
                telemetry: "UITouch.timestamp", prediction: "none"
            )
        ),
        (
            "wacom",
            physicalDevice(
                platform: "macOS", hardware: "Mac16,1",
                gpu: "Apple M4", refresh: 60,
                inputKind: "wacomStylus", vendor: "Wacom",
                model: "Wacom Intuos Pro",
                telemetry: "NSEvent.tabletPoint",
                prediction: "coalesced"
            )
        ),
    ]
    let counters: [String: Any] = [
        "packageDecodeCount": 1,
        "imageDecodeCount": 0,
        "textureUploadCount": 4,
        "cacheHitCount": 0,
        "activationCount": 1,
    ]
    for (profileID, device) in profiles {
        let directory = root.appendingPathComponent(
            profileID,
            isDirectory: true
        )
        let rawRoot = directory.appendingPathComponent(
            "raw",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rawRoot,
            withIntermediateDirectories: true
        )
        let prediction = device["predictionMode"] as! String
        var workloads: [[String: Any]] = []
        for (definitionID, semanticHash, rawResources) in truths {
            let resources = rawResources.map {
                [
                    "identity": $0.0,
                    "kind": $0.1,
                    "mipCount": $0.2,
                ] as [String: Any]
            }
            var samples: [[String: Any]] = []
            for index in 0..<20 {
                let kind: String
                switch prediction {
                case "coalescedAndPredicted":
                    kind = ["actual", "coalesced", "predicted"][
                        index % 3
                    ]
                case "coalesced":
                    kind = index.isMultiple(of: 2)
                        ? "actual" : "coalesced"
                default:
                    kind = "actual"
                }
                samples.append([
                    "timestampNanoseconds": index * 1_000_000,
                    "phase":
                        index == 0
                            ? "began"
                            : (index == 19 ? "ended" : "moved"),
                    "kind": kind,
                    "pressure": 0.5,
                    "x": Double(index),
                    "y": 10.0,
                ])
            }
            let raw = try testJSONData([
                "schemaVersion": 1,
                "profileID": profileID,
                "scenarioID": "professional-\(profileID)",
                "source": source,
                "device": device,
                "definitionID": definitionID,
                "semanticHash": semanticHash,
                "resolvedResources": resources,
                "inputSampleCount": 20,
                "inputSamples": samples,
                "cpuPreparationMilliseconds":
                    Array(repeating: 0.1, count: 20),
                "gpu500DabMilliseconds": [1.0, 0.9, 0.8],
                "missedFrameFlags":
                    Array(repeating: 0, count: 20),
                "compilerCountersBefore": counters,
                "compilerCountersAfter": counters,
            ])
            try raw.write(
                to: rawRoot.appendingPathComponent(
                    "\(definitionID).json"
                )
            )
            workloads.append([
                "definitionID": definitionID,
                "semanticHash": semanticHash,
                "resolvedResources": resources,
                "rawTracePath": "raw/\(definitionID).json",
                "rawTraceSHA256": ArtifactFileSystem.sha256(raw),
            ])
        }
        try testJSONData([
            "schemaVersion": 1,
            "profileID": profileID,
            "scenarioID": "professional-\(profileID)",
            "source": source,
            "device": device,
            "workloads": workloads,
        ]).write(
            to: directory.appendingPathComponent("evidence.json")
        )
    }
    return ProfessionalPhysicalTestFixture(
        root: root,
        commit: commit,
        tree: tree,
        renderer: renderer
    )
}

private func physicalDevice(
    platform: String,
    hardware: String,
    gpu: String,
    refresh: Double,
    inputKind: String,
    vendor: String,
    model: String,
    telemetry: String,
    prediction: String
) -> [String: Any] {
    [
        "platform": platform,
        "hardwareModel": hardware,
        "gpuName": gpu,
        "gpuRegistryID": "0x1234",
        "displayRefreshHertz": refresh,
        "inputKind": inputKind,
        "inputVendor": vendor,
        "inputModel": model,
        "inputTelemetryProvenance": telemetry,
        "predictionMode": prediction,
    ]
}

private func mutateTestJSONObject(
    at url: URL,
    _ mutation: (inout [String: Any]) throws -> Void
) throws {
    var object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: url)
    ) as! [String: Any]
    try mutation(&object)
    try testJSONData(object).write(to: url)
}

private func validatePerformanceFixture(
    _ fixture: ProfessionalPerformanceTestFixture,
    gpuMaximum: Double
) throws -> Bool {
    let status = try testJSONData([
        "schemaVersion": 2,
        "correctnessPassed": true,
        "gpuName": "Apple M4",
        "gpuClassification": "physical",
        "cpuPreparationP95Milliseconds": 1.25,
        "cpuPreparationBudgetMilliseconds": 2.0,
        "gpu500DabMilliseconds": gpuMaximum,
        "gpu500DabBudgetMilliseconds": 3.0,
    ])
    return try PerformanceStatusValidator.validate(
        status,
        expectedGPUName: "Apple M4",
        expectedOperatingSystem: fixture.operatingSystem,
        expectedCommit: fixture.commit,
        expectedRendererSHA256: fixture.renderer,
        measuredCPUP95Milliseconds: 1.25,
        positiveRoot: fixture.root
    )
}

private func mutatePerformanceRawAndRebind(
    fixture: ProfessionalPerformanceTestFixture,
    scene: String,
    filename: String,
    referenceKey: String,
    _ mutation: (inout [String: Any]) throws -> Void
) throws {
    let directory = fixture.root.appendingPathComponent(scene)
    let raw = directory.appendingPathComponent(filename)
    try mutateTestJSONObject(at: raw, mutation)
    let digest = ArtifactFileSystem.sha256(try Data(contentsOf: raw))
    try mutateTestJSONObject(
        at: directory.appendingPathComponent(
            "professional-performance.json"
        )
    ) { index in
        var reference = index[referenceKey] as! [String: Any]
        reference["sha256"] = digest
        index[referenceKey] = reference
    }
}
