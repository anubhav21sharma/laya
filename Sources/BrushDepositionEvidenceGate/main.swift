import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum StageFourEvidenceValidationError:
    Error, Equatable, LocalizedError
{
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}

public enum StageFourEvidenceValidationStatus: Equatable, Sendable {
    case passed
    case performancePending(gpuName: String)
}

public enum StageFourEvidenceValidator {
    public static let positiveSceneNames = [
        "deposition-airbrush",
        "deposition-cache-pinning",
        "deposition-custom-asymmetric",
        "deposition-dry",
        "deposition-erase",
        "deposition-failure-matrix",
        "deposition-glaze",
        "deposition-ink",
        "deposition-kinematics",
        "deposition-layer-matrix",
        "deposition-marker",
        "deposition-periodic-seams",
        "deposition-prediction",
        "deposition-preview-commit",
        "deposition-radial-reflection",
        "deposition-stamp-size-mips",
    ]
    public static let negativeSceneNames = positiveSceneNames.map {
        "\($0)-negative-control"
    }

    public static let requiredMetamorphicInvariants = [
        "batchPartitionsEqual",
        "cancelPreservesCanonical",
        "eraseColorIndependent",
        "predictionOnOffEqual",
        "reflectionHandednessCorrect",
        "symmetryOrderEqual",
        "tilingPeriodTranslationEqual",
        "zoomIndependent",
    ]
    public static let requiredPhysicalProfiles = [
        "a14Floor60Hz",
        "inputToPhoton",
        "memoryWarning",
        "pencil",
        "referenceMSeriesProMotion120Hz",
        "suspendResume",
        "sustainedThermal",
        "wacom",
    ]

    private static let rootEntries: Set<String> = [
        "artifact-sha256.txt",
        "brush-lab-cards",
        "logs",
        "negative-control",
        "performance-status.txt",
        "positive",
        "provenance.json",
        "scene-matrix.json",
        "source-tree-terminal.txt",
        "source-tree.txt",
    ]
    private static let evidenceKeys: Set<String> = [
        "abiVersion", "canonicalSHA256", "definitionID",
        "invariantResults", "logicalDabCount",
        "pipelineKey", "previewCommitMaximumChannelDelta",
        "projectedInstanceCount", "resourceBytes", "scene",
        "schemaVersion", "semanticHash", "telemetry", "textureLevels",
    ]
    private static let telemetryKeys: Set<String> = [
        "authoritativeBacklog", "backlogHighWater", "bufferHighWater",
        "encodedInstanceCount", "missedFrameCount", "predictedBacklog",
    ]
    private static let provenanceKeys: Set<String> = [
        "artifactRoot", "brushLabCatalogSHA256", "commit",
        "configuration", "gpuClassification", "gpuName",
        "hardwareMachine", "hardwareModel", "kernel", "operatingSystem",
        "schemaVersion", "sourceTreeSHA256", "swiftVersion",
        "xcodeVersion", "xcodegenVersion",
    ]
    private static let performanceKeys: Set<String> = [
        "completedStrokeLengthIndependent",
        "correctnessPassed",
        "cpuPreparationBudgetMilliseconds",
        "cpuPreparationP95Milliseconds",
        "gpu500DabBudgetMilliseconds",
        "gpu500DabMilliseconds",
        "gpuClassification",
        "gpuName",
        "hotPathCompilerResourceCountersZero",
        "physicalProfiles",
        "schemaVersion",
    ]
    private static let cardAssessmentKeys: Set<String> = [
        "buildup", "cardID", "edgeQuality", "eraserMatch", "notes",
        "responsiveness", "symmetryBehavior", "textureCohesion",
    ]
    private static let scenePixels = PixelDimensions(width: 128, height: 128)
    private static let depositionABIVersion = 1
    private static let depositionInstanceStride = 256
    private static let sceneTruth: [String: SceneTruth] = [
        "deposition-airbrush": SceneTruth(
            definitionID: "builtin.native-airbrush",
            semanticHash:
            "620be0f2e576b5b86342761778ce83efec8dbe29510eba71f9af86eff0ea9d62",
            pipelineKey:
            "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1",
            resourceBytes: 5461,
            textureLevels: ["builtin.shape.soft-round": 7]
        ),
        "deposition-cache-pinning": SceneTruth(
            definitionID: "deposition-cache-pinning.brush",
            semanticHash:
            "c7d1978947bf5d2b1381f4fe7076ef34d57301d336d2f63d686d6d73fa22b4fa",
            pipelineKey:
            "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1",
            resourceBytes: 5461,
            textureLevels: ["builtin.shape.hard-round": 7]
        ),
        "deposition-custom-asymmetric": SceneTruth(
            definitionID: "deposition-custom-asymmetric.brush",
            semanticHash:
            "ed124245524b1c35fc2095e6ab7798a7024e661cf36d8c967ffdad93270a637c",
            pipelineKey:
            "deposition:flow:none:s0:g1:h0:d0:abi1:format80:samples1",
            resourceBytes: 10922,
            textureLevels: [
                "custom.asymmetric.grain": 7,
                "custom.asymmetric.shape": 7,
            ]
        ),
        "deposition-dry": SceneTruth(
            definitionID: "builtin.native-dry-media",
            semanticHash:
            "16c1b49a98cd4096552f46e035d761179922942609b42bfda82bfbf4a7471fe2",
            pipelineKey:
            "deposition:flow:dryBreakup:s0:g1:h0:d0:abi1:format80:samples1",
            resourceBytes: 10922,
            textureLevels: [
                "builtin.grain.paper": 7,
                "builtin.shape.hard-round": 7,
            ]
        ),
        "deposition-erase": SceneTruth(
            definitionID: "builtin.native-eraser",
            semanticHash:
            "374ab6373f1bf8eb088cc4b8659c832e0a4045eee799d073fd5207053e17a7a5",
            pipelineKey:
            "deposition:destinationOut:none:s0:g0:h0:d0:abi1:format80:samples1",
            resourceBytes: 5461,
            textureLevels: ["builtin.shape.hard-round": 7]
        ),
        "deposition-failure-matrix": SceneTruth(
            definitionID: "deposition-failure-matrix.brush",
            semanticHash:
            "ba6bdb112332538b8d6b3c1d2525e54228142083161f51a4958d754ea7a7e84c",
            pipelineKey:
            "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1",
            resourceBytes: 5461,
            textureLevels: ["builtin.shape.hard-round": 7]
        ),
        "deposition-glaze": SceneTruth(
            definitionID: "builtin.native-glaze",
            semanticHash:
            "d4b8b8b63391c62ad8e8da29f2300ac901633dadf0f1005c0393e4534b5812cc",
            pipelineKey:
            "deposition:uniformGlaze:none:s0:g0:h0:d0:abi1:format80:samples1",
            resourceBytes: 5461,
            textureLevels: ["builtin.shape.soft-round": 7]
        ),
        "deposition-ink": SceneTruth(
            definitionID: "builtin.native-ink",
            semanticHash:
            "0d2ff2678740c26839f49df27278b00f012f8263b85f31909ef666ee98667e8a",
            pipelineKey:
            "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1",
            resourceBytes: 5461,
            textureLevels: ["builtin.shape.hard-round": 7]
        ),
        "deposition-kinematics": SceneTruth(
            definitionID: "deposition-kinematics.brush",
            semanticHash:
            "adb32fbc7e6214ab38d373b25a41c4fde80a7a2371a0d0535d97ecaf7576d21d",
            pipelineKey:
            "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1",
            resourceBytes: 5461,
            textureLevels: ["builtin.shape.hard-round": 7]
        ),
        "deposition-layer-matrix": SceneTruth(
            definitionID: "evidence.layer-multiply-2-true",
            semanticHash:
            "6cd54e9f53dbb905c61b7d1cacc39d0194e2f42281ade84559e5e0eb29cac4d4",
            pipelineKey:
            "deposition:flow:none:s1:g1:h1:d0:abi1:format80:samples1",
            resourceBytes: 21844,
            textureLevels: [
                "matrix.primary.grain": 7,
                "matrix.primary.shape": 7,
                "matrix.secondary.grain": 7,
                "matrix.secondary.shape": 7,
            ]
        ),
        "deposition-marker": SceneTruth(
            definitionID: "builtin.native-marker",
            semanticHash:
            "8923051495b72cb68351f2e1285923e6e96377ad15c157a2db87b46aba2027ee",
            pipelineKey:
            "deposition:uniformGlaze:markerOverlap:s0:g0:h0:d0:abi1:format80:samples1",
            resourceBytes: 5461,
            textureLevels: ["builtin.shape.chisel": 7]
        ),
        "deposition-periodic-seams": SceneTruth(
            definitionID: "deposition-periodic-seams.brush",
            semanticHash:
            "c0629f7fc1024e1a8a30a7599133d21be354af44f8a262ef0027a4e064afb698",
            pipelineKey:
            "deposition:flow:none:s0:g1:h0:d0:abi1:format80:samples1",
            resourceBytes: 10922,
            textureLevels: [
                "custom.asymmetric.grain": 7,
                "custom.asymmetric.shape": 7,
            ]
        ),
        "deposition-prediction": SceneTruth(
            definitionID: "deposition-prediction.brush",
            semanticHash:
            "810fff75718833a4b2e12d04e64a125ebf863e5b3783b907e11da85edbad7a64",
            pipelineKey:
            "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1",
            resourceBytes: 5461,
            textureLevels: ["builtin.shape.hard-round": 7]
        ),
        "deposition-preview-commit": SceneTruth(
            definitionID: "deposition-preview-commit.brush",
            semanticHash:
            "f4feee7141a83949994dab8cd07482cdc8cf0f12d4c10badfe0e725aca342a97",
            pipelineKey:
            "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1",
            resourceBytes: 5461,
            textureLevels: ["builtin.shape.hard-round": 7]
        ),
        "deposition-radial-reflection": SceneTruth(
            definitionID: "deposition-radial-reflection.brush",
            semanticHash:
            "9709db5f7001eeab912ffc6a3ea302861a72dc76ec6e4283f3960ab0784614b7",
            pipelineKey:
            "deposition:flow:none:s0:g1:h0:d0:abi1:format80:samples1",
            resourceBytes: 10922,
            textureLevels: [
                "custom.asymmetric.grain": 7,
                "custom.asymmetric.shape": 7,
            ]
        ),
        "deposition-stamp-size-mips": SceneTruth(
            definitionID: "evidence.native-mips",
            semanticHash:
            "987462e244018869a7b40db35fe3037007fb20a9dfeb02376eb3c450baa33a42",
            pipelineKey:
            "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1",
            resourceBytes: 5461,
            textureLevels: ["evidence.mip-probe.shape": 7]
        ),
    ]

    public static func validate(
        artifactRoot: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String
    ) throws -> StageFourEvidenceValidationStatus {
        guard artifactRoot.path.hasPrefix("/"),
              artifactRoot.standardizedFileURL.path == artifactRoot.path
        else {
            throw invalid("artifact root must be an absolute standardized path")
        }
        guard isCommit(expectedCommit) else {
            throw invalid(
                "expected commit must be 40 lowercase hexadecimal characters"
            )
        }
        guard isSHA256(expectedSourceTreeSHA256) else {
            throw invalid(
                "expected source-tree digest must be lowercase SHA-256"
            )
        }
        guard try entryNames(artifactRoot) == rootEntries else {
            throw invalid("artifact root file set is not exact")
        }

        let provenance = try validateSourceProvenance(
            root: artifactRoot,
            expectedCommit: expectedCommit,
            expectedSourceTreeSHA256: expectedSourceTreeSHA256
        )
        try validateSceneMatrix(
            artifactRoot.appendingPathComponent("scene-matrix.json")
        )
        let measurements = try validateSceneArtifacts(
            root: artifactRoot,
            expectedCommit: expectedCommit,
            expectedGPUName: provenance.gpuName,
            expectedOperatingSystem: provenance.operatingSystem
        )
        try validateNegativeControls(
            artifactRoot.appendingPathComponent("negative-control")
        )
        try validateBrushLabCatalog(
            root: artifactRoot.appendingPathComponent("brush-lab-cards"),
            expectedSHA256: provenance.brushLabCatalogSHA256
        )
        let performanceEvidence = try validatePerformanceBenchmarks(
            root: artifactRoot.appendingPathComponent("logs"),
            expectedCommit: expectedCommit,
            expectedGPUName: provenance.gpuName
        )
        try validateArtifactManifest(root: artifactRoot)

        return try validatePerformancePolicy(
            artifactRoot.appendingPathComponent("performance-status.txt"),
            provenance: provenance,
            sceneCPUP95Milliseconds: measurements.maximumCPUP95Milliseconds,
            benchmarkEvidence: performanceEvidence
        )
    }

    private static func validateSourceProvenance(
        root: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String
    ) throws -> Provenance {
        let source = try regularFileData(
            root.appendingPathComponent("source-tree.txt"),
            label: "source tree"
        )
        let terminal = try regularFileData(
            root.appendingPathComponent("source-tree-terminal.txt"),
            label: "terminal source tree"
        )
        guard !source.isEmpty, source == terminal else {
            throw invalid(
                "source tree is empty or changed while evidence was recorded"
            )
        }
        guard sha256(source) == expectedSourceTreeSHA256 else {
            throw invalid("source-tree digest does not match the gate argument")
        }
        let url = root.appendingPathComponent("provenance.json")
        let data = try regularFileData(url, label: "provenance")
        try requireExactKeys(
            data,
            expected: provenanceKeys,
            label: "provenance"
        )
        let value: Provenance = try decode(data, label: "provenance")
        guard value.schemaVersion == 1,
              value.commit == expectedCommit,
              value.sourceTreeSHA256 == expectedSourceTreeSHA256,
              value.configuration == "Debug",
              nonempty(value.swiftVersion),
              nonempty(value.xcodeVersion),
              nonempty(value.xcodegenVersion),
              nonempty(value.operatingSystem),
              nonempty(value.kernel),
              nonempty(value.hardwareMachine),
              nonempty(value.hardwareModel),
              nonempty(value.gpuName),
              ["physical", "virtual", "paravirtual"].contains(
                  value.gpuClassification
              ),
              value.artifactRoot == root.standardizedFileURL.path,
              isSHA256(value.brushLabCatalogSHA256)
        else {
            throw invalid(
                "provenance does not bind the commit, tree, tools, hardware, GPU, and artifact root"
            )
        }
        let recognized = gpuClassification(value.gpuName)
        guard recognized == value.gpuClassification else {
            throw invalid(
                "provenance GPU classification does not match the GPU name"
            )
        }
        return value
    }

    private static func validateSceneMatrix(_ url: URL) throws {
        let data = try regularFileData(url, label: "scene matrix")
        try requireExactKeys(
            data,
            expected: ["schemaVersion", "positive", "negativeControls"],
            label: "scene matrix"
        )
        let matrix: SceneMatrix = try decode(data, label: "scene matrix")
        guard matrix.schemaVersion == 1,
              matrix.positive == positiveSceneNames,
              matrix.negativeControls == negativeSceneNames
        else {
            throw invalid("scene matrix is not the exact sorted 16+16 set")
        }
    }

    private static func validateSceneArtifacts(
        root: URL,
        expectedCommit: String,
        expectedGPUName: String,
        expectedOperatingSystem: String
    ) throws -> SceneMeasurements {
        let positiveRoot = root.appendingPathComponent("positive")
        guard try entryNames(positiveRoot) == Set(positiveSceneNames) else {
            throw invalid("positive scene directory set is not exact")
        }
        var seenMetamorphic = Set<String>()
        var sceneP95: [Double] = []
        for scene in positiveSceneNames {
            let directory = positiveRoot.appendingPathComponent(scene)
            let hasCPUReference = scene == "deposition-ink"
            var expectedFiles: Set = [
                "benchmark.json", "canonical.png", "committed.png",
                "deposition-evidence.json", "live.png",
            ]
            if hasCPUReference {
                expectedFiles.insert("cpu-reference.png")
            }
            guard try entryNames(directory) == expectedFiles else {
                throw invalid("\(scene): positive artifact file set is not exact")
            }

            let evidenceURL = directory.appendingPathComponent(
                "deposition-evidence.json"
            )
            let evidenceData = try regularFileData(
                evidenceURL,
                label: "\(scene) deposition evidence"
            )
            var expectedEvidenceKeys = evidenceKeys
            if hasCPUReference {
                expectedEvidenceKeys.formUnion([
                    "cpuReferenceSHA256", "maximumCPUGPUChannelDelta",
                ])
            }
            try requireExactKeys(
                evidenceData,
                expected: expectedEvidenceKeys,
                label: "\(scene) deposition evidence"
            )
            let evidence: Evidence = try decode(
                evidenceData,
                label: "\(scene) deposition evidence"
            )
            try validateEvidenceIdentity(evidence, scene: scene)

            let canonical = try loadPNG(
                directory.appendingPathComponent("canonical.png"),
                expectedSize: scenePixels,
                label: "\(scene) canonical"
            )
            let committed = try loadPNG(
                directory.appendingPathComponent("committed.png"),
                expectedSize: scenePixels,
                label: "\(scene) committed"
            )
            let live = try loadPNG(
                directory.appendingPathComponent("live.png"),
                expectedSize: scenePixels,
                label: "\(scene) live"
            )
            guard sha256(canonical.bytes) == evidence.canonicalSHA256 else {
                throw invalid("\(scene): canonical PNG pixel digest mismatches")
            }
            let previewDelta = maximumChannelDelta(live.bytes, committed.bytes)
            guard previewDelta
                == evidence.previewCommitMaximumChannelDelta,
                previewDelta <= 1
            else {
                throw invalid(
                    "\(scene): preview/commit PNG delta is not exact or exceeds one channel value"
                )
            }

            if hasCPUReference {
                let cpu = try loadPNG(
                    directory.appendingPathComponent("cpu-reference.png"),
                    expectedSize: scenePixels,
                    label: "\(scene) CPU reference"
                )
                guard sha256(cpu.bytes) == evidence.cpuReferenceSHA256,
                      maximumChannelDelta(cpu.bytes, canonical.bytes)
                      == evidence.maximumCPUGPUChannelDelta
                else {
                    throw invalid(
                        "\(scene): CPU/GPU PNG digest or maximum delta mismatches"
                    )
                }
            } else if evidence.cpuReferenceSHA256 != nil
                || evidence.maximumCPUGPUChannelDelta != nil
            {
                throw invalid("\(scene): unexpected CPU reference fields")
            }

            guard evidence.invariantResults.values.allSatisfy(\.self),
                  evidence.invariantResults[
                      "strokeCompilerCountersUnchanged"
                  ] == true,
                  evidence.invariantResults[
                      "strokePipelinePreparationUnchanged"
                  ] == true
            else {
                throw invalid(
                    "\(scene): invariant or hot-path compiler/pipeline counter failed"
                )
            }
            seenMetamorphic.formUnion(
                evidence.invariantResults.keys.filter {
                    requiredMetamorphicInvariants.contains($0)
                }
            )
            let record = try validateBenchmark(
                directory.appendingPathComponent("benchmark.json"),
                scene: scene,
                evidence: evidence,
                expectedCommit: expectedCommit,
                expectedGPUName: expectedGPUName,
                expectedOperatingSystem: expectedOperatingSystem
            )
            sceneP95.append(percentile95(record.cpuEncodeMilliseconds))
        }
        guard seenMetamorphic == Set(requiredMetamorphicInvariants) else {
            throw invalid(
                "the complete named metamorphic invariant set is not proven"
            )
        }
        guard let maximum = sceneP95.max(), maximum.isFinite else {
            throw invalid("scene CPU preparation measurements are unavailable")
        }
        return SceneMeasurements(maximumCPUP95Milliseconds: maximum)
    }

    private static func validateEvidenceIdentity(
        _ evidence: Evidence,
        scene: String
    ) throws {
        guard let truth = sceneTruth[scene],
              evidence.schemaVersion == 1,
              evidence.scene == scene,
              evidence.definitionID == truth.definitionID,
              evidence.semanticHash == truth.semanticHash,
              evidence.pipelineKey == truth.pipelineKey,
              evidence.abiVersion == depositionABIVersion,
              evidence.resourceBytes == truth.resourceBytes,
              evidence.textureLevels == truth.textureLevels,
              evidence.logicalDabCount > 0,
              evidence.projectedInstanceCount > 0,
              isSHA256(evidence.canonicalSHA256),
              evidence.cpuReferenceSHA256.map(isSHA256) ?? true,
              !evidence.invariantResults.isEmpty
        else {
            throw invalid(
                "\(scene): schema, definition hash, pipeline, ABI, resource, texture, or count evidence is invalid"
            )
        }
        let telemetry = evidence.telemetry
        guard telemetry.authoritativeBacklog >= 0,
              telemetry.predictedBacklog >= 0,
              telemetry.backlogHighWater >= 0,
              telemetry.encodedInstanceCount
              == evidence.projectedInstanceCount,
              telemetry.bufferHighWater > 0
        else {
            throw invalid("\(scene): telemetry evidence is invalid")
        }
    }

    private static func validateBenchmark(
        _ url: URL,
        scene: String,
        evidence: Evidence,
        expectedCommit: String,
        expectedGPUName: String,
        expectedOperatingSystem: String
    ) throws -> Benchmark {
        let data = try regularFileData(url, label: "\(scene) benchmark")
        let record: Benchmark = try decode(data, label: "\(scene) benchmark")
        guard record.schemaVersion == 3,
              record.sceneName == scene,
              record.timestampUTC == "1970-01-01T00:00:00Z",
              record.hardware.gpuName == expectedGPUName,
              record.hardware.logicalProcessorCount > 0,
              record.hardware.physicalMemoryBytes > 0,
              record.operatingSystem == expectedOperatingSystem,
              record.build.configuration == "Debug",
              record.build.gitCommit == expectedCommit,
              record.frameCount > 0,
              validDurations(record.cpuEncodeMilliseconds),
              validDurations(record.gpuMilliseconds),
              record.peakResidentBytes > 0,
              !record.newInstanceCounts.isEmpty,
              record.newInstanceCounts.allSatisfy({ $0 >= 0 }),
              record.newInstanceCounts.reduce(0, +)
              == evidence.projectedInstanceCount,
              record.totalProjectedFragmentCount
              == evidence.projectedInstanceCount,
              record.totalInstanceBytes
              == evidence.projectedInstanceCount
              * depositionInstanceStride,
              record.previewCommitViolationCount == 0,
              record.recipeID == evidence.definitionID,
              record.seed != 0,
              record.assetResidentBytes == evidence.resourceBytes,
              isSHA256(record.logicalDabDigest),
              record.canonicalBGRA8Digest == evidence.canonicalSHA256,
              record.logicalDabCount == evidence.logicalDabCount,
              record.program == "nativeDeposition"
        else {
            throw invalid(
                "\(scene): benchmark identity, measurements, ABI bytes, resource counts, or evidence binding is invalid"
            )
        }
        return record
    }

    private static func validateNegativeControls(_ root: URL) throws {
        guard try entryNames(root) == Set(positiveSceneNames) else {
            throw invalid("negative-control directory set is not paired")
        }
        for scene in positiveSceneNames {
            let directory = root.appendingPathComponent(scene)
            guard try entryNames(directory) == [
                "exit-status.txt", "stderr.log", "stdout.log",
            ] else {
                throw invalid("\(scene): negative-control file set is not exact")
            }
            let stdout = try regularFileData(
                directory.appendingPathComponent("stdout.log"),
                label: "\(scene) negative stdout"
            )
            let stderr = try regularFileData(
                directory.appendingPathComponent("stderr.log"),
                label: "\(scene) negative stderr"
            )
            let exitStatus = try regularFileData(
                directory.appendingPathComponent("exit-status.txt"),
                label: "\(scene) negative exit"
            )
            guard stdout.isEmpty,
                  exitStatus == Data("1\n".utf8),
                  let message = String(data: stderr, encoding: .utf8),
                  message.hasPrefix("HARNESS FAIL "),
                  message.hasSuffix("\n"),
                  message.dropLast().allSatisfy({ $0 != "\n" })
            else {
                throw invalid(
                    "\(scene): negative control did not fail exactly once with exit 1"
                )
            }
        }
    }

    private static func validateBrushLabCatalog(
        root: URL,
        expectedSHA256: String
    ) throws {
        guard try entryNames(root) == ["catalog.json"] else {
            throw invalid("Brush Lab card artifact set is not exact")
        }
        let data = try regularFileData(
            root.appendingPathComponent("catalog.json"),
            label: "Brush Lab catalog"
        )
        guard sha256(data) == expectedSHA256,
              let object = try jsonObject(data, label: "Brush Lab catalog"),
              Set(object.keys) == ["assessments", "cards"],
              let cards = object["cards"] as? [[String: Any]],
              let assessments = object["assessments"] as? [[String: Any]],
              cards.count == 312,
              assessments.count == 312
        else {
            throw invalid(
                "Brush Lab catalog digest, schema, or 312-card count is invalid"
            )
        }
        let cardIDs = try cards.map { card -> String in
            guard let cardID = card["cardID"] as? String,
                  let schemaVersion = integer(card["schemaVersion"]),
                  schemaVersion == 1,
                  let brushID = card["brushID"] as? String,
                  nonempty(cardID),
                  nonempty(brushID)
            else {
                throw invalid("Brush Lab card identity is invalid")
            }
            return cardID
        }
        guard cardIDs == cardIDs.sorted(),
              Set(cardIDs).count == 312
        else {
            throw invalid("Brush Lab card identities are not sorted and unique")
        }
        let brushCounts = Dictionary(grouping: cards) {
            $0["brushID"] as! String
        }.mapValues(\.count)
        guard brushCounts.count == 6,
              brushCounts.values.allSatisfy({ $0 == 52 })
        else {
            throw invalid("Brush Lab catalog is not 52 cards per six anchors")
        }
        let assessmentIDs = try assessments.map {
            assessment -> String in
            guard Set(assessment.keys) == cardAssessmentKeys,
                  let cardID = assessment["cardID"] as? String,
                  assessment.allSatisfy({
                      $0.key == "cardID" || $0.value is NSNull
                  })
            else {
                throw invalid(
                    "Brush Lab assessments are not explicitly all pending"
                )
            }
            return cardID
        }
        guard assessmentIDs == cardIDs else {
            throw invalid("Brush Lab assessments are not bound to every card")
        }
    }

    private static func validatePerformanceBenchmarks(
        root: URL,
        expectedCommit: String,
        expectedGPUName: String
    ) throws -> PerformanceBenchmarks {
        let fiveURL = root.appendingPathComponent(
            "five-hundred-dabs.benchmark.json"
        )
        let longURL = root.appendingPathComponent(
            "projected-long-stroke.benchmark.json"
        )
        let fiveData = try regularFileData(
            fiveURL,
            label: "500-dab performance evidence"
        )
        let longData = try regularFileData(
            longURL,
            label: "long-stroke performance evidence"
        )
        guard let five = try jsonObject(
            fiveData,
            label: "500-dab performance evidence"
        ),
            integer(five["schemaVersion"]) == 2,
            five["sceneName"] as? String == "five-hundred-dabs",
            let fiveBuild = five["build"] as? [String: Any],
            fiveBuild["gitCommit"] as? String == expectedCommit,
            let fiveHardware = five["hardware"] as? [String: Any],
            fiveHardware["gpuName"] as? String == expectedGPUName,
            let newCounts = integerArray(five["newInstanceCounts"]),
            newCounts == [500],
            let gpu = doubleArray(five["dabGPUMilliseconds"]),
            gpu.count == 1,
            validDurations(gpu),
            let maximumGPU = gpu.max()
        else {
            throw invalid(
                "exact 500-dab workload evidence is missing or malformed"
            )
        }
        guard let long = try jsonObject(
            longData,
            label: "long-stroke performance evidence"
        ),
            integer(long["schemaVersion"]) == 3,
            long["sceneName"] as? String == "projected-long-stroke",
            let longBuild = long["build"] as? [String: Any],
            longBuild["gitCommit"] as? String == expectedCommit,
            let longNew = integerArray(long["newInstanceCounts"]),
            let longTotal = integerArray(long["totalStrokeInstanceCounts"]),
            longNew == [Int](repeating: 1, count: 401),
            longTotal == Array(1 ... 401)
        else {
            throw invalid(
                "completed-stroke length-independence evidence is missing or malformed"
            )
        }
        return PerformanceBenchmarks(gpu500DabMilliseconds: maximumGPU)
    }

    private static func validateArtifactManifest(root: URL) throws {
        let manifestURL = root.appendingPathComponent("artifact-sha256.txt")
        let data = try regularFileData(
            manifestURL,
            label: "artifact digest manifest"
        )
        guard let text = String(data: data, encoding: .utf8),
              !text.isEmpty,
              text.hasSuffix("\n")
        else {
            throw invalid("artifact digest manifest is empty or not UTF-8")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
        var manifest: [String: String] = [:]
        for lineSlice in lines {
            let line = String(lineSlice)
            guard line.count > 68 else {
                throw invalid("artifact digest manifest line is malformed")
            }
            let digest = String(line.prefix(64))
            let separator = line.dropFirst(64).prefix(4)
            let path = String(line.dropFirst(68))
            guard isSHA256(digest),
                  separator == "  ./",
                  nonempty(path),
                  !path.hasPrefix("/"),
                  !path.split(separator: "/").contains(".."),
                  manifest[path] == nil,
                  path != "artifact-sha256.txt"
            else {
                throw invalid("artifact digest manifest path is unsafe")
            }
            manifest[path] = digest
        }
        let actualURLs = try allRegularFiles(root: root).filter {
            $0.lastPathComponent != "artifact-sha256.txt"
        }
        let actualPaths = Set(actualURLs.map {
            String($0.path.dropFirst(root.path.count + 1))
        })
        guard Set(manifest.keys) == actualPaths else {
            throw invalid("artifact digest manifest file set is not exact")
        }
        for url in actualURLs {
            let path = String(url.path.dropFirst(root.path.count + 1))
            guard try manifest[path] == sha256(
                regularFileData(url, label: path)
            ) else {
                throw invalid("artifact digest mismatch: \(path)")
            }
        }
    }

    private static func validatePerformancePolicy(
        _ url: URL,
        provenance: Provenance,
        sceneCPUP95Milliseconds: Double,
        benchmarkEvidence: PerformanceBenchmarks
    ) throws -> StageFourEvidenceValidationStatus {
        let data = try regularFileData(url, label: "performance status")
        try requireExactKeys(
            data,
            expected: performanceKeys,
            label: "performance status"
        )
        let value: PerformanceStatus = try decode(
            data,
            label: "performance status"
        )
        guard value.schemaVersion == 1,
              value.correctnessPassed,
              value.gpuName == provenance.gpuName,
              value.gpuClassification == provenance.gpuClassification,
              close(value.cpuPreparationBudgetMilliseconds, 2),
              close(value.gpu500DabBudgetMilliseconds, 3),
              close(
                  value.cpuPreparationP95Milliseconds,
                  sceneCPUP95Milliseconds
              ),
              value.cpuPreparationP95Milliseconds >= 0,
              value.cpuPreparationP95Milliseconds < 2,
              close(
                  value.gpu500DabMilliseconds,
                  benchmarkEvidence.gpu500DabMilliseconds
              ),
              value.gpu500DabMilliseconds > 0,
              value.completedStrokeLengthIndependent,
              value.hotPathCompilerResourceCountersZero,
              Set(value.physicalProfiles.keys)
              == Set(requiredPhysicalProfiles),
              value.physicalProfiles.values.allSatisfy({
                  ["passed", "pending", "failed"].contains($0)
              }),
              !value.physicalProfiles.values.contains("failed")
        else {
            throw invalid(
                "software performance, correctness, measurement, or hardware-profile policy failed"
            )
        }

        if value.gpuClassification != "physical" {
            guard value.physicalProfiles.values.allSatisfy({
                $0 == "pending"
            }) else {
                throw invalid(
                    "virtual/paravirtual evidence cannot claim physical realtime or input profiles"
                )
            }
            return .performancePending(gpuName: value.gpuName)
        }
        if value.physicalProfiles.values.contains("pending") {
            return .performancePending(gpuName: value.gpuName)
        }
        guard value.gpu500DabMilliseconds < 3 else {
            throw invalid(
                "stable physical Metal 500-dab GPU workload is not below 3 ms"
            )
        }
        return .passed
    }

    private static func requireExactKeys(
        _ data: Data,
        expected: Set<String>,
        label: String
    ) throws {
        guard let object = try jsonObject(data, label: label),
              Set(object.keys) == expected
        else {
            throw invalid("\(label) JSON keys are not exact")
        }
    }

    private static func decode<T: Decodable>(
        _ data: Data,
        label: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw invalid("\(label) JSON cannot be decoded: \(error)")
        }
    }

    private static func jsonObject(
        _ data: Data,
        label: String
    ) throws -> [String: Any]? {
        do {
            return try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        } catch {
            throw invalid("\(label) JSON cannot be parsed: \(error)")
        }
    }

    private static func entryNames(_ directory: URL) throws -> Set<String> {
        var statBuffer = stat()
        guard lstat(directory.path, &statBuffer) == 0,
              statBuffer.st_mode & S_IFMT == S_IFDIR
        else {
            throw invalid("required directory is missing: \(directory.path)")
        }
        do {
            return try Set(
                FileManager.default.contentsOfDirectory(
                    atPath: directory.path
                )
            )
        } catch {
            throw invalid(
                "cannot enumerate directory \(directory.path): \(error)"
            )
        }
    }

    private static func regularFileData(
        _ url: URL,
        label: String
    ) throws -> Data {
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0,
              statBuffer.st_mode & S_IFMT == S_IFREG,
              statBuffer.st_size >= 0,
              statBuffer.st_size <= 512 * 1024 * 1024
        else {
            throw invalid("\(label) is missing, unsafe, or too large")
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw invalid("\(label) cannot be read: \(error)")
        }
    }

    private static func allRegularFiles(root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw invalid("artifact root cannot be enumerated")
        }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                throw invalid("artifact tree contains a symbolic link")
            }
            if values.isRegularFile == true {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func loadPNG(
        _ url: URL,
        expectedSize: PixelDimensions,
        label: String
    ) throws -> Raster {
        let data = try regularFileData(url, label: label)
        let options = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            options
        ),
            CGImageSourceGetCount(source) == 1,
            CGImageSourceGetType(source) as String?
            == UTType.png.identifier,
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                options
            ) as? [CFString: Any],
            let width = (
                properties[kCGImagePropertyPixelWidth] as? NSNumber
            )?.intValue,
            let height = (
                properties[kCGImagePropertyPixelHeight] as? NSNumber
            )?.intValue,
            width == expectedSize.width,
            height == expectedSize.height,
            let image = CGImageSourceCreateImageAtIndex(source, 0, options)
        else {
            throw invalid(
                "\(label) is not one \(expectedSize.width)x\(expectedSize.height) PNG"
            )
        }
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        )
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw invalid("\(label) cannot create a BGRA decode context")
        }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return Raster(bytes: Data(bytes))
    }

    private static func maximumChannelDelta(
        _ lhs: Data,
        _ rhs: Data
    ) -> Int {
        guard lhs.count == rhs.count else { return Int.max }
        return zip(lhs, rhs).reduce(0) {
            max($0, abs(Int($1.0) - Int($1.1)))
        }
    }

    private static func validDurations(_ values: [Double]) -> Bool {
        !values.isEmpty && values.allSatisfy {
            $0.isFinite && $0 >= 0
        }
    }

    private static func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let result = number.intValue
        return number.doubleValue == Double(result) ? result : nil
    }

    private static func integerArray(_ value: Any?) -> [Int]? {
        guard let values = value as? [Any] else { return nil }
        let result = values.compactMap(integer)
        return result.count == values.count ? result : nil
    }

    private static func doubleArray(_ value: Any?) -> [Double]? {
        guard let values = value as? [NSNumber],
              values.allSatisfy({
                  CFGetTypeID($0) != CFBooleanGetTypeID()
              })
        else {
            return nil
        }
        return values.map(\.doubleValue)
    }

    private static func isCommit(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy(isLowerHex)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(isLowerHex)
    }

    private static func isLowerHex(_ value: UInt8) -> Bool {
        (48 ... 57).contains(value) || (97 ... 102).contains(value)
    }

    private static func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.isFinite
            && rhs.isFinite
            && abs(lhs - rhs) <= max(1, abs(lhs), abs(rhs)) * 1e-12
    }

    private static func gpuClassification(_ name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("paravirtual") {
            return "paravirtual"
        }
        if lowered.contains("virtual") || lowered.contains("simulator") {
            return "virtual"
        }
        return "physical"
    }

    private static func invalid(
        _ message: String
    ) -> StageFourEvidenceValidationError {
        .invalid(message)
    }
}

private struct PixelDimensions {
    let width: Int
    let height: Int
}

private struct SceneTruth {
    let definitionID: String
    let semanticHash: String
    let pipelineKey: String
    let resourceBytes: Int
    let textureLevels: [String: Int]
}

private struct Raster {
    let bytes: Data
}

private struct SceneMeasurements {
    let maximumCPUP95Milliseconds: Double
}

private struct PerformanceBenchmarks {
    let gpu500DabMilliseconds: Double
}

private struct SceneMatrix: Decodable {
    let schemaVersion: Int
    let positive: [String]
    let negativeControls: [String]
}

private struct Provenance: Decodable {
    let schemaVersion: Int
    let commit: String
    let sourceTreeSHA256: String
    let configuration: String
    let swiftVersion: String
    let xcodeVersion: String
    let xcodegenVersion: String
    let operatingSystem: String
    let kernel: String
    let hardwareMachine: String
    let hardwareModel: String
    let gpuName: String
    let gpuClassification: String
    let artifactRoot: String
    let brushLabCatalogSHA256: String
}

private struct Evidence: Decodable {
    let schemaVersion: Int
    let scene: String
    let definitionID: String
    let semanticHash: String
    let pipelineKey: String
    let abiVersion: Int
    let resourceBytes: Int
    let textureLevels: [String: Int]
    let logicalDabCount: Int
    let projectedInstanceCount: Int
    let canonicalSHA256: String
    let cpuReferenceSHA256: String?
    let maximumCPUGPUChannelDelta: Int?
    let previewCommitMaximumChannelDelta: Int
    let telemetry: Telemetry
    let invariantResults: [String: Bool]
}

private struct Telemetry: Decodable {
    let authoritativeBacklog: Int
    let predictedBacklog: Int
    let backlogHighWater: Int
    let encodedInstanceCount: Int
    let bufferHighWater: Int
    let missedFrameCount: Int
}

private struct Benchmark: Decodable {
    let schemaVersion: Int
    let timestampUTC: String
    let sceneName: String
    let hardware: Hardware
    let operatingSystem: String
    let build: Build
    let frameCount: Int
    let cpuEncodeMilliseconds: [Double]
    let gpuMilliseconds: [Double]
    let peakResidentBytes: Int
    let newInstanceCounts: [Int]
    let totalProjectedFragmentCount: Int
    let totalInstanceBytes: Int
    let previewCommitViolationCount: Int
    let recipeID: String
    let seed: UInt64
    let assetResidentBytes: Int
    let logicalDabDigest: String
    let canonicalBGRA8Digest: String
    let logicalDabCount: Int
    let program: String
}

private struct Hardware: Decodable {
    let gpuName: String
    let logicalProcessorCount: Int
    let physicalMemoryBytes: UInt64
}

private struct Build: Decodable {
    let configuration: String
    let gitCommit: String
}

private struct PerformanceStatus: Decodable {
    let schemaVersion: Int
    let correctnessPassed: Bool
    let gpuName: String
    let gpuClassification: String
    let cpuPreparationP95Milliseconds: Double
    let cpuPreparationBudgetMilliseconds: Double
    let gpu500DabMilliseconds: Double
    let gpu500DabBudgetMilliseconds: Double
    let completedStrokeLengthIndependent: Bool
    let hotPathCompilerResourceCountersZero: Bool
    let physicalProfiles: [String: String]
}

@main
enum BrushDepositionEvidenceGate {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let options = try parse(arguments)
            let status = try StageFourEvidenceValidator.validate(
                artifactRoot: URL(fileURLWithPath: options.artifacts),
                expectedCommit: options.commit,
                expectedSourceTreeSHA256: options.sourceTreeSHA256
            )
            switch status {
            case .passed:
                print("BRUSH DEPOSITION EVIDENCE PASS")
                exit(0)
            case let .performancePending(gpuName):
                print(
                    "BRUSH DEPOSITION EVIDENCE PERFORMANCE PENDING gpu=\(gpuName)"
                )
                exit(2)
            }
        } catch {
            fputs(
                "BRUSH DEPOSITION EVIDENCE FAIL: \(error.localizedDescription)\n",
                stderr
            )
            exit(1)
        }
    }

    private struct Options {
        let artifacts: String
        let commit: String
        let sourceTreeSHA256: String
    }

    private static func parse(_ arguments: [String]) throws -> Options {
        guard arguments.count == 6 else {
            throw StageFourEvidenceValidationError.invalid(usage)
        }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard [
                "--artifacts", "--commit", "--source-tree-sha256",
            ].contains(flag),
                values[flag] == nil
            else {
                throw StageFourEvidenceValidationError.invalid(usage)
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard let artifacts = values["--artifacts"],
              artifacts.hasPrefix("/"),
              let commit = values["--commit"],
              let sourceTreeSHA256 = values["--source-tree-sha256"]
        else {
            throw StageFourEvidenceValidationError.invalid(usage)
        }
        return Options(
            artifacts: artifacts,
            commit: commit,
            sourceTreeSHA256: sourceTreeSHA256
        )
    }

    private static let usage =
        "usage: BrushDepositionEvidenceGate --artifacts <absolute-path> "
            + "--commit <40-char-sha> --source-tree-sha256 <64-char-sha>"
}
