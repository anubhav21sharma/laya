import BrushDepositionEvidenceGate
import CryptoKit
import Foundation
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Stage 4 deposition evidence gate")
struct DepositionEvidenceGateTests {
    @Test
    func completeVirtualEvidenceIsPerformancePendingOnly() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }

        #expect(
            try StageFourEvidenceValidator.validate(
                artifactRoot: fixture.root,
                expectedCommit: fixture.commit,
                expectedSourceTreeSHA256: fixture.sourceTreeSHA256
            ) == .performancePending(gpuName: fixture.gpuName)
        )
    }

    @Test
    func exactPositiveAndNegativeScenePairingIsRequired() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(
            at: fixture.root
                .appendingPathComponent("negative-control")
                .appendingPathComponent(
                    StageFourEvidenceValidator.positiveSceneNames[0]
                )
        )
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test(arguments: [
        EvidenceIdentityDefect.definitionID,
        EvidenceIdentityDefect.semanticHash,
        .pipelineKey,
        .abi,
        .resourceBytes,
        .textureLevels,
    ])
    func schemaDefinitionPipelineABIAndResourcesFailClosed(
        _ defect: EvidenceIdentityDefect
    ) throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        let scene = StageFourEvidenceValidator.positiveSceneNames[0]
        try fixture.mutateEvidence(scene: scene) { object in
            switch defect {
            case .definitionID:
                object["definitionID"] = "other.native-brush"
            case .semanticHash:
                object["semanticHash"] = String(repeating: "d", count: 64)
            case .pipelineKey:
                object["pipelineKey"] =
                    "deposition:flow:dryBreakup:s0:g1:h0:d0:abi1:format80:samples1"
            case .abi:
                object["abiVersion"] = 2
            case .resourceBytes:
                object["resourceBytes"] = 4096
            case .textureLevels:
                object["textureLevels"] = ["other.shape": 1]
            }
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func canonicalPNGPixelDigestAndDimensionsAreRecomputed() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        let scene = StageFourEvidenceValidator.positiveSceneNames[0]
        try fixture.writePNG(
            scene: scene,
            name: "canonical.png",
            pixels: fixture.changedPixels
        )
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func cpuGPUMaximumDeltaIsRecomputedFromPNGs() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.mutateEvidence(scene: "deposition-ink") {
            $0["maximumCPUGPUChannelDelta"] = 1
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func previewCommitDeltaIsRecomputedAndBounded() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        let scene = "deposition-preview-commit"
        try fixture.writePNG(
            scene: scene,
            name: "live.png",
            pixels: fixture.changedPixels
        )
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func everyMetamorphicInvariantMustBePresentAndTrue() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.mutateEvidence(scene: "deposition-kinematics") { object in
            var invariants = object["invariantResults"] as! [String: Bool]
            invariants["zoomIndependent"] = false
            object["invariantResults"] = invariants
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func hotPathCompilerAndPipelineCountersMustRemainZero() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.mutateEvidence(scene: "deposition-ink") { object in
            var invariants = object["invariantResults"] as! [String: Bool]
            invariants["strokeCompilerCountersUnchanged"] = false
            object["invariantResults"] = invariants
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func eachNegativeControlMustExitExactlyOne() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        let scene = StageFourEvidenceValidator.positiveSceneNames[0]
        try Data("0\n".utf8).write(
            to: fixture.root
                .appendingPathComponent("negative-control")
                .appendingPathComponent(scene)
                .appendingPathComponent("exit-status.txt")
        )
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func sourceTreeCommitAndTerminalTreeRemainBound() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try Data("changed\n".utf8).write(
            to: fixture.root.appendingPathComponent(
                "source-tree-terminal.txt"
            )
        )
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func performancePendingCannotHideCorrectnessFailure() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.mutatePerformance {
            $0["correctnessPassed"] = false
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func paravirtualProfileCannotClaimRealtimePerformance() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.mutatePerformance { object in
            var profiles = object["physicalProfiles"] as! [String: String]
            profiles["referenceMSeriesProMotion120Hz"] = "passed"
            profiles["a14Floor60Hz"] = "passed"
            object["physicalProfiles"] = profiles
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func alteredArtifactDigestFailsClosed() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try Data("altered manifest\n".utf8).write(
            to: fixture.root.appendingPathComponent("artifact-sha256.txt")
        )

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }
}

enum EvidenceIdentityDefect: CaseIterable, CustomTestStringConvertible {
    case definitionID
    case semanticHash
    case pipelineKey
    case abi
    case resourceBytes
    case textureLevels

    var testDescription: String {
        String(describing: self)
    }
}

private struct StageFourArtifactFixture {
    let root: URL
    let commit = String(repeating: "a", count: 40)
    let gpuName = "Apple Paravirtual device"
    let sourceTree = Data(
        "100644 blob 0123456789012345678901234567890123456789\tPackage.swift\n"
            .utf8
    )
    let pixels: [UInt8] = {
        var value = [UInt8](
            repeating: 0,
            count: 128 * 128 * 4
        )
        for alpha in stride(from: 3, to: value.count, by: 4) {
            value[alpha] = 255
        }
        return value
    }()

    var changedPixels: [UInt8] {
        var value = pixels
        value[0] = 4
        return value
    }

    var sourceTreeSHA256: String {
        Self.sha256(sourceTree)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "brush-stage4-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        for name in [
            "positive", "negative-control", "brush-lab-cards", "logs",
        ] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: false
            )
        }
        try writeSourceTree()
        try writeSceneMatrix()
        try writePositiveEvidence()
        try writeNegativeControls()
        try writeBrushLabCatalog()
        try writePerformance()
        try writeProvenance()
        try writePerformanceBenchmarks()
        try rewriteManifest()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func validate() throws -> StageFourEvidenceValidationStatus {
        try StageFourEvidenceValidator.validate(
            artifactRoot: root,
            expectedCommit: commit,
            expectedSourceTreeSHA256: sourceTreeSHA256
        )
    }

    func mutateEvidence(
        scene: String,
        _ mutation: (inout [String: Any]) -> Void
    ) throws {
        let url = root.appendingPathComponent("positive")
            .appendingPathComponent(scene)
            .appendingPathComponent("deposition-evidence.json")
        var object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as! [String: Any]
        mutation(&object)
        try Self.json(object).write(to: url)
    }

    func mutatePerformance(
        _ mutation: (inout [String: Any]) -> Void
    ) throws {
        let url = root.appendingPathComponent("performance-status.txt")
        var object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as! [String: Any]
        mutation(&object)
        try Self.json(object).write(to: url)
    }

    func writePNG(
        scene: String,
        name: String,
        pixels: [UInt8]
    ) throws {
        try PNGWriter.writeBGRA(
            pixels,
            pixelSize: PixelSize(width: 128, height: 128),
            to: root.appendingPathComponent("positive")
                .appendingPathComponent(scene)
                .appendingPathComponent(name)
        )
    }

    func rewriteManifest() throws {
        let manager = FileManager.default
        let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )!
        let files = enumerator.compactMap { $0 as? URL }
            .filter {
                $0.lastPathComponent != "artifact-sha256.txt"
                    && (try? $0.resourceValues(
                        forKeys: [.isRegularFileKey]
                    ).isRegularFile) == true
            }
            .sorted { $0.path < $1.path }
        let lines = try files.map { url in
            let relative = String(
                url.path.dropFirst(root.path.count + 1)
            )
            return try "\(Self.sha256(Data(contentsOf: url)))  ./\(relative)"
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(
            to: root.appendingPathComponent("artifact-sha256.txt")
        )
    }

    private func writeSourceTree() throws {
        try sourceTree.write(
            to: root.appendingPathComponent("source-tree.txt")
        )
        try sourceTree.write(
            to: root.appendingPathComponent("source-tree-terminal.txt")
        )
    }

    private func writeSceneMatrix() throws {
        try Self.json([
            "schemaVersion": 1,
            "positive": StageFourEvidenceValidator.positiveSceneNames,
            "negativeControls":
                StageFourEvidenceValidator.negativeSceneNames,
        ]).write(to: root.appendingPathComponent("scene-matrix.json"))
    }

    private func writePositiveEvidence() throws {
        let positive = root.appendingPathComponent("positive")
        for scene in StageFourEvidenceValidator.positiveSceneNames {
            let truth = Self.truth(scene)
            let directory = positive.appendingPathComponent(scene)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            for name in ["live.png", "committed.png", "canonical.png"] {
                try writePNG(scene: scene, name: name, pixels: pixels)
            }
            let hasCPUReference = scene == "deposition-ink"
            if hasCPUReference {
                try writePNG(
                    scene: scene,
                    name: "cpu-reference.png",
                    pixels: changedPixels
                )
            }
            let invariants = Dictionary(
                uniqueKeysWithValues:
                StageFourEvidenceValidator.requiredMetamorphicInvariants
                    .map { ($0, true) }
                    + [
                        ("strokeCompilerCountersUnchanged", true),
                        ("strokePipelinePreparationUnchanged", true),
                    ]
            )
            let evidence: [String: Any] = [
                "schemaVersion": 1,
                "scene": scene,
                "definitionID": truth.definitionID,
                "semanticHash": truth.semanticHash,
                "pipelineKey": truth.pipelineKey,
                "abiVersion": 1,
                "resourceBytes": truth.resourceBytes,
                "textureLevels": truth.textureLevels,
                "logicalDabCount": 4,
                "projectedInstanceCount": 4,
                "canonicalSHA256": Self.sha256(Data(pixels)),
                "previewCommitMaximumChannelDelta": 0,
                "telemetry": [
                    "authoritativeBacklog": 0,
                    "predictedBacklog": 0,
                    "backlogHighWater": 4,
                    "encodedInstanceCount": 4,
                    "bufferHighWater": 1,
                    "missedFrameCount": 0,
                ],
                "invariantResults": invariants,
            ]
            var complete = evidence
            if hasCPUReference {
                complete["cpuReferenceSHA256"] =
                    Self.sha256(Data(changedPixels))
                complete["maximumCPUGPUChannelDelta"] = 4
            }
            try Self.json(complete).write(
                to: directory.appendingPathComponent(
                    "deposition-evidence.json"
                )
            )
            try writeBenchmark(scene: scene, truth: truth, to: directory)
        }
    }

    private func writeBenchmark(
        scene: String,
        truth: FixtureSceneTruth,
        to directory: URL
    ) throws {
        let benchmark: [String: Any] = [
            "schemaVersion": 3,
            "timestampUTC": "1970-01-01T00:00:00Z",
            "sceneName": scene,
            "hardware": [
                "gpuName": gpuName,
                "logicalProcessorCount": 8,
                "physicalMemoryBytes": 8_589_934_592,
            ],
            "operatingSystem": "Fixture OS",
            "build": [
                "configuration": "Debug",
                "gitCommit": commit,
            ],
            "frameCount": 1,
            "cpuEncodeMilliseconds": [0.5],
            "gpuMilliseconds": [7.0],
            "peakResidentBytes": truth.resourceBytes,
            "newInstanceCounts": [4],
            "totalProjectedFragmentCount": 4,
            "totalInstanceBytes": 1024,
            "previewCommitViolationCount": 0,
            "recipeID": truth.definitionID,
            "seed": 1,
            "assetResidentBytes": truth.resourceBytes,
            "logicalDabDigest": String(repeating: "c", count: 64),
            "canonicalBGRA8Digest": Self.sha256(Data(pixels)),
            "logicalDabCount": 4,
            "program": "nativeDeposition",
        ]
        try Self.json(benchmark).write(
            to: directory.appendingPathComponent("benchmark.json")
        )
    }

    private func writeNegativeControls() throws {
        let negative = root.appendingPathComponent("negative-control")
        for scene in StageFourEvidenceValidator.positiveSceneNames {
            let directory = negative.appendingPathComponent(scene)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            try Data().write(
                to: directory.appendingPathComponent("stdout.log")
            )
            try Data("HARNESS FAIL fixture\n".utf8).write(
                to: directory.appendingPathComponent("stderr.log")
            )
            try Data("1\n".utf8).write(
                to: directory.appendingPathComponent("exit-status.txt")
            )
        }
    }

    private func writeBrushLabCatalog() throws {
        let brushIDs = (0 ..< 6).map { "fixture.brush.\($0)" }
        let cards: [[String: Any]] = brushIDs.flatMap { brushID in
            (0 ..< 52).map { index in
                [
                    "cardID": "\(brushID).card.\(String(format: "%02d", index))",
                    "schemaVersion": 1,
                    "brushID": brushID,
                ]
            }
        }.sorted {
            ($0["cardID"] as! String) < ($1["cardID"] as! String)
        }
        let assessments = cards.map {
            [
                "cardID": $0["cardID"]!,
                "responsiveness": NSNull(),
                "edgeQuality": NSNull(),
                "textureCohesion": NSNull(),
                "buildup": NSNull(),
                "symmetryBehavior": NSNull(),
                "eraserMatch": NSNull(),
                "notes": NSNull(),
            ] as [String: Any]
        }
        try Self.json([
            "cards": cards,
            "assessments": assessments,
        ]).write(
            to: root.appendingPathComponent("brush-lab-cards")
                .appendingPathComponent("catalog.json")
        )
    }

    private func writePerformance() throws {
        let profiles = Dictionary(
            uniqueKeysWithValues:
            StageFourEvidenceValidator.requiredPhysicalProfiles.map {
                ($0, "pending")
            }
        )
        try Self.json([
            "schemaVersion": 1,
            "correctnessPassed": true,
            "gpuName": gpuName,
            "gpuClassification": "paravirtual",
            "cpuPreparationP95Milliseconds": 0.5,
            "cpuPreparationBudgetMilliseconds": 2.0,
            "gpu500DabMilliseconds": 7.0,
            "gpu500DabBudgetMilliseconds": 3.0,
            "completedStrokeLengthIndependent": true,
            "hotPathCompilerResourceCountersZero": true,
            "physicalProfiles": profiles,
        ]).write(
            to: root.appendingPathComponent("performance-status.txt")
        )
    }

    private func writeProvenance() throws {
        let catalog = root.appendingPathComponent("brush-lab-cards")
            .appendingPathComponent("catalog.json")
        try Self.json([
            "schemaVersion": 1,
            "commit": commit,
            "sourceTreeSHA256": sourceTreeSHA256,
            "configuration": "Debug",
            "swiftVersion": "Fixture Swift",
            "xcodeVersion": "Fixture Xcode",
            "xcodegenVersion": "Fixture XcodeGen",
            "operatingSystem": "Fixture OS",
            "kernel": "Fixture Kernel",
            "hardwareMachine": "arm64",
            "hardwareModel": "VirtualMac2,1",
            "gpuName": gpuName,
            "gpuClassification": "paravirtual",
            "artifactRoot": root.standardizedFileURL.path,
            "brushLabCatalogSHA256":
                Self.sha256(Data(contentsOf: catalog)),
        ]).write(to: root.appendingPathComponent("provenance.json"))
    }

    private func writePerformanceBenchmarks() throws {
        let logs = root.appendingPathComponent("logs")
        try Self.json([
            "schemaVersion": 2,
            "sceneName": "five-hundred-dabs",
            "build": [
                "configuration": "Debug",
                "gitCommit": commit,
            ],
            "hardware": [
                "gpuName": gpuName,
                "logicalProcessorCount": 8,
                "physicalMemoryBytes": 8_589_934_592,
            ],
            "newInstanceCounts": [500],
            "dabGPUMilliseconds": [7.0],
        ]).write(
            to: logs.appendingPathComponent(
                "five-hundred-dabs.benchmark.json"
            )
        )
        try Self.json([
            "schemaVersion": 3,
            "sceneName": "projected-long-stroke",
            "build": [
                "configuration": "Debug",
                "gitCommit": commit,
            ],
            "newInstanceCounts": [Int](repeating: 1, count: 401),
            "totalStrokeInstanceCounts": Array(1 ... 401),
        ]).write(
            to: logs.appendingPathComponent(
                "projected-long-stroke.benchmark.json"
            )
        )
    }

    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func truth(_ scene: String) -> FixtureSceneTruth {
        let identities: [String: (String, String)] = [
            "deposition-airbrush": (
                "builtin.native-airbrush",
                "620be0f2e576b5b86342761778ce83efec8dbe29510eba71f9af86eff0ea9d62"
            ),
            "deposition-cache-pinning": (
                "deposition-cache-pinning.brush",
                "c7d1978947bf5d2b1381f4fe7076ef34d57301d336d2f63d686d6d73fa22b4fa"
            ),
            "deposition-custom-asymmetric": (
                "deposition-custom-asymmetric.brush",
                "ed124245524b1c35fc2095e6ab7798a7024e661cf36d8c967ffdad93270a637c"
            ),
            "deposition-dry": (
                "builtin.native-dry-media",
                "16c1b49a98cd4096552f46e035d761179922942609b42bfda82bfbf4a7471fe2"
            ),
            "deposition-erase": (
                "builtin.native-eraser",
                "374ab6373f1bf8eb088cc4b8659c832e0a4045eee799d073fd5207053e17a7a5"
            ),
            "deposition-failure-matrix": (
                "deposition-failure-matrix.brush",
                "ba6bdb112332538b8d6b3c1d2525e54228142083161f51a4958d754ea7a7e84c"
            ),
            "deposition-glaze": (
                "builtin.native-glaze",
                "d4b8b8b63391c62ad8e8da29f2300ac901633dadf0f1005c0393e4534b5812cc"
            ),
            "deposition-ink": (
                "builtin.native-ink",
                "0d2ff2678740c26839f49df27278b00f012f8263b85f31909ef666ee98667e8a"
            ),
            "deposition-kinematics": (
                "deposition-kinematics.brush",
                "adb32fbc7e6214ab38d373b25a41c4fde80a7a2371a0d0535d97ecaf7576d21d"
            ),
            "deposition-layer-matrix": (
                "evidence.layer-multiply-2-true",
                "6cd54e9f53dbb905c61b7d1cacc39d0194e2f42281ade84559e5e0eb29cac4d4"
            ),
            "deposition-marker": (
                "builtin.native-marker",
                "8923051495b72cb68351f2e1285923e6e96377ad15c157a2db87b46aba2027ee"
            ),
            "deposition-periodic-seams": (
                "deposition-periodic-seams.brush",
                "c0629f7fc1024e1a8a30a7599133d21be354af44f8a262ef0027a4e064afb698"
            ),
            "deposition-prediction": (
                "deposition-prediction.brush",
                "810fff75718833a4b2e12d04e64a125ebf863e5b3783b907e11da85edbad7a64"
            ),
            "deposition-preview-commit": (
                "deposition-preview-commit.brush",
                "f4feee7141a83949994dab8cd07482cdc8cf0f12d4c10badfe0e725aca342a97"
            ),
            "deposition-radial-reflection": (
                "deposition-radial-reflection.brush",
                "9709db5f7001eeab912ffc6a3ea302861a72dc76ec6e4283f3960ab0784614b7"
            ),
            "deposition-stamp-size-mips": (
                "evidence.native-mips",
                "987462e244018869a7b40db35fe3037007fb20a9dfeb02376eb3c450baa33a42"
            ),
        ]
        let identity = identities[scene]!
        let defaultPipeline =
            "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1"
        let pipeline: String = switch scene {
        case "deposition-custom-asymmetric",
             "deposition-periodic-seams",
             "deposition-radial-reflection":
            "deposition:flow:none:s0:g1:h0:d0:abi1:format80:samples1"
        case "deposition-dry":
            "deposition:flow:dryBreakup:s0:g1:h0:d0:abi1:format80:samples1"
        case "deposition-erase":
            "deposition:destinationOut:none:s0:g0:h0:d0:abi1:format80:samples1"
        case "deposition-glaze":
            "deposition:uniformGlaze:none:s0:g0:h0:d0:abi1:format80:samples1"
        case "deposition-layer-matrix":
            "deposition:flow:none:s1:g1:h1:d0:abi1:format80:samples1"
        case "deposition-marker":
            "deposition:uniformGlaze:markerOverlap:s0:g0:h0:d0:abi1:format80:samples1"
        default:
            defaultPipeline
        }
        let textures: [String: Int] = switch scene {
        case "deposition-airbrush", "deposition-glaze":
            ["builtin.shape.soft-round": 7]
        case "deposition-custom-asymmetric",
             "deposition-periodic-seams",
             "deposition-radial-reflection":
            [
                "custom.asymmetric.grain": 7,
                "custom.asymmetric.shape": 7,
            ]
        case "deposition-dry":
            [
                "builtin.grain.paper": 7,
                "builtin.shape.hard-round": 7,
            ]
        case "deposition-layer-matrix":
            [
                "matrix.primary.grain": 7,
                "matrix.primary.shape": 7,
                "matrix.secondary.grain": 7,
                "matrix.secondary.shape": 7,
            ]
        case "deposition-marker":
            ["builtin.shape.chisel": 7]
        case "deposition-stamp-size-mips":
            ["evidence.mip-probe.shape": 7]
        default:
            ["builtin.shape.hard-round": 7]
        }
        let resourceBytes = textures.count * 5461
        return FixtureSceneTruth(
            definitionID: identity.0,
            semanticHash: identity.1,
            pipelineKey: pipeline,
            resourceBytes: resourceBytes,
            textureLevels: textures
        )
    }
}

private struct FixtureSceneTruth {
    let definitionID: String
    let semanticHash: String
    let pipelineKey: String
    let resourceBytes: Int
    let textureLevels: [String: Int]
}
