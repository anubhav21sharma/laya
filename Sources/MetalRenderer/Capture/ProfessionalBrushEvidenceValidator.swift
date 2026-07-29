import BrushFormat
import CoreGraphics
import Foundation
import ImageIO
import PatternEngine

public enum ProfessionalBrushEvidenceValidationError:
    Error, Equatable, LocalizedError
{
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}

public enum ProfessionalBrushPerformanceValidationStatus:
    Equatable, Sendable
{
    case passed
    case pending
}

public enum ProfessionalBrushEvidenceValidationStatus:
    Equatable, Sendable
{
    case passed
    case pending
}

public enum ProfessionalBrushEvidenceValidator {
    public static let positiveSceneNames = [
        "professional-chisel-marker",
        "professional-graphite-pencil",
        "professional-natural-charcoal",
        "professional-technical-ink",
    ]
    public static let negativeSceneNames = positiveSceneNames.map {
        "\($0)-negative-control"
    }
    public static let sceneNames =
        (positiveSceneNames + negativeSceneNames).sorted()

    public static let requiredInvariantNames = [
        "boundedLiveWork",
        "destinationOutEraserCompatible",
        "nonemptyVisibleOutput",
        "predictionOnOffEqual",
        "previewCommitMaximumDeltaWithinTolerance",
        "professionalDefinitionIdentityExact",
        "radialRotationAndReflectionCorrect",
        "resolvedResourcesAndMipsExact",
        "strokeCompilerCacheCountersUnchanged",
        "tilingPeriodTranslationEqual",
    ]

    private struct SceneTruth {
        let family: String
        let definitionID: String
        let semanticHash: String
        let pipelineKey: String
        let residentBytes: Int
        let resourceLevels: [String: Int]
    }

    // These hashes bind canonical BrushPackage encodings of the already
    // committed Stage 5 definitions. They are intentionally not derived from
    // live renderer state.
    private static let sceneTruth: [String: SceneTruth] = [
        "professional-chisel-marker": SceneTruth(
            family: "Chisel Marker",
            definitionID: "builtin.professional-chisel-marker",
            semanticHash:
                "2c1b9c2c7770dacfd4eee5e5fc6bbbf57b202bbcb15b6edca37de868ed2ec1f1",
            pipelineKey:
                "deposition:uniformGlaze:markerOverlap:s0:g0:h0:d0:abi1:format80:samples1",
            residentBytes: 21_845,
            resourceLevels: ["builtin.shape.marker-chisel": 8]
        ),
        "professional-graphite-pencil": SceneTruth(
            family: "Graphite Pencil",
            definitionID: "builtin.professional-graphite-pencil",
            semanticHash:
                "10af674df1d65e52efde75a68860e554c31e75dda12c17027bb728a47550aa52",
            pipelineKey:
                "deposition:flow:dryBreakup:s0:g1:h1:d0:abi1:format80:samples1",
            residentBytes: 114_687,
            resourceLevels: [
                "builtin.grain.graphite": 9,
                "builtin.grain.paper": 7,
                "builtin.shape.graphite-tip": 8,
            ]
        ),
        "professional-natural-charcoal": SceneTruth(
            family: "Natural Charcoal",
            definitionID: "builtin.professional-natural-charcoal",
            semanticHash:
                "c686a582f773263649cb5259851eeffbe2403d38ed9a2be4ae9114bb7c8bd007",
            pipelineKey:
                "deposition:flow:dryBreakup:s1:g1:h1:d0:abi1:format80:samples1",
            residentBytes: 120_148,
            resourceLevels: [
                "builtin.grain.charcoal": 9,
                "builtin.grain.paper": 7,
                "builtin.shape.charcoal-tip": 8,
                "builtin.shape.soft-round": 7,
            ]
        ),
        "professional-technical-ink": SceneTruth(
            family: "Technical Ink",
            definitionID: "builtin.professional-technical-ink",
            semanticHash:
                "394e34d6ddccb13978714550537cae9b2cab9e566032b6b3ddc25b6eab0d5534",
            pipelineKey:
                "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1",
            residentBytes: 21_845,
            resourceLevels: ["builtin.shape.technical-nib": 8]
        ),
    ]

    public static func expectedSemanticHash(
        forPositiveScene scene: String
    ) -> String? {
        sceneTruth[scene]?.semanticHash
    }

    public static func expectedResourceLevels(
        forPositiveScene scene: String
    ) -> [String: Int]? {
        sceneTruth[scene]?.resourceLevels
    }

    public static func validate(
        _ evidence: ProfessionalBrushSceneEvidence
    ) throws {
        guard evidence.schemaVersion
                == ProfessionalBrushSceneEvidence.currentSchemaVersion,
              let truth = sceneTruth[evidence.scene],
              evidence.family == truth.family,
              evidence.definitionID == truth.definitionID,
              evidence.definitionSemanticHash == truth.semanticHash,
              isSHA256(evidence.definitionSemanticHash),
              evidence.pipelineKey == truth.pipelineKey,
              evidence.abiVersion == DepositionABI.version,
              evidence.residentResourceBytes == truth.residentBytes,
              evidence.logicalDabCount > 0,
              evidence.projectedInstanceCount >= evidence.logicalDabCount,
              [
                  evidence.livePNGSHA256,
                  evidence.committedPNGSHA256,
                  evidence.canonicalPNGSHA256,
                  evidence.characterizationSHA256,
              ].allSatisfy(isSHA256),
              evidence.previewCommitMaximumChannelDelta <= 1
        else {
            throw invalid(
                "professional scene identity, hashes, counts, pipeline, resources, or preview delta are invalid"
            )
        }

        let resourceNames = evidence.resolvedResources.map(\.identity)
        guard !resourceNames.isEmpty,
              resourceNames == resourceNames.sorted(),
              Set(resourceNames).count == resourceNames.count,
              Dictionary(
                  uniqueKeysWithValues: evidence.resolvedResources.map {
                      ($0.identity, $0.mipCount)
                  }
              ) == truth.resourceLevels,
              evidence.resolvedResources.allSatisfy({
                  ["shape", "grain"].contains($0.kind)
                      && $0.mipCount > 0
                      && resourceKind(for: $0.identity) == $0.kind
              })
        else {
            throw invalid(
                "resolved professional resources are not the exact sorted identity and mip set"
            )
        }

        let expectedUploads = UInt64(truth.resourceLevels.count)
        let afterCompile = ProfessionalBrushCompilerCounterSnapshot(
            packageDecodeCount: 1,
            imageDecodeCount: 0,
            textureUploadCount: expectedUploads,
            cacheHitCount: 0,
            activationCount: 1
        )
        let afterCacheHit = ProfessionalBrushCompilerCounterSnapshot(
            packageDecodeCount: 2,
            imageDecodeCount: 0,
            textureUploadCount: expectedUploads,
            cacheHitCount: expectedUploads,
            activationCount: 2
        )
        let counters = evidence.compilerCounters
        guard counters.beforeCompile == .zero,
              counters.afterCompile == afterCompile,
              counters.afterCacheHit == afterCacheHit,
              counters.beforeStroke == afterCacheHit,
              counters.afterStroke == afterCacheHit
        else {
            throw invalid(
                "compiler/cache counters do not prove one compile, one cache hit, and no input-path work: \(counters)"
            )
        }

        let telemetry = evidence.telemetry
        guard telemetry.authoritativeBacklog == 0,
              telemetry.predictedBacklog == 0,
              telemetry.backlogHighWater > 0,
              telemetry.backlogHighWater
                <= evidence.projectedInstanceCount,
              telemetry.encodedInstanceCount > 0,
              telemetry.encodedInstanceCount
                <= UInt64(evidence.projectedInstanceCount),
              (1...3).contains(telemetry.bufferHighWater)
        else {
            throw invalid(
                "professional telemetry is incomplete: telemetry=\(telemetry) projected=\(evidence.projectedInstanceCount)"
            )
        }
        guard Set(evidence.invariantResults.keys)
                == Set(requiredInvariantNames),
              evidence.invariantResults.values.allSatisfy({ $0 })
        else {
            throw invalid(
                "professional invariant results are incomplete: \(evidence.invariantResults)"
            )
        }
    }

    public static func loadScenes(from directory: URL) throws
        -> [HarnessScene]
    {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.pathExtension == "json"
                && $0.deletingPathExtension().lastPathComponent
                    .hasPrefix("professional-")
        }
        .map { try HarnessScene.decode(Data(contentsOf: $0)) }
        .sorted { $0.name < $1.name }
    }

    public static func validateSceneSet(_ scenes: [HarnessScene]) throws {
        let names = scenes.map(\.name)
        guard names == names.sorted(),
              Set(names).count == names.count,
              names == sceneNames,
              scenes.allSatisfy({ $0.schemaVersion == 6 })
        else {
            throw invalid(
                "professional scenes must be the exact sorted four positive and four negative set"
            )
        }
        for positiveName in positiveSceneNames {
            guard let positive = scenes.first(where: {
                $0.name == positiveName
            }),
                let negative = scenes.first(where: {
                    $0.name == "\(positiveName)-negative-control"
                })
            else {
                throw invalid("professional scene pair is missing")
            }
            let positiveExpectations =
                positive.depositionInvariantExpectations
            let negativeExpectations =
                negative.depositionInvariantExpectations
            let differences = positiveExpectations.keys.filter {
                positiveExpectations[$0] != negativeExpectations[$0]
            }
            guard Set(positiveExpectations.keys)
                    == Set(requiredInvariantNames),
                  Set(negativeExpectations.keys)
                    == Set(requiredInvariantNames),
                  positiveExpectations.values.allSatisfy({ $0 }),
                  differences.count == 1,
                  differences.allSatisfy({
                      negativeExpectations[$0] == false
                  })
            else {
                throw invalid(
                    "professional positive/negative pair must flip exactly one named requirement"
                )
            }
        }
    }

    public static func validateExpectations(
        scene: HarnessScene,
        actual: [String: Bool]
    ) throws {
        for key in scene.depositionInvariantExpectations.keys.sorted() {
            guard actual[key] == scene.depositionInvariantExpectations[key]
            else {
                throw invalid(
                    "\(scene.name) expectation '\(key)' did not match"
                )
            }
        }
    }

    public static func rejectRawStatusStrings(
        _ data: Data,
        label: String
    ) throws {
        let rawValues = ["pass", "passed", "pending", "fail", "failed"]
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           rawValues.contains(text)
        {
            throw invalid("\(label) cannot be a raw caller-provided status")
        }
        if let value = try? JSONSerialization.jsonObject(with: data),
           containsRawStatus(value)
        {
            throw invalid("\(label) contains a raw caller-provided status")
        }
    }

    public static func validateArtifactManifest(root: URL) throws {
        let manifestURL = root.appendingPathComponent(
            "artifact-sha256.txt"
        )
        let data = try regularFileData(
            manifestURL,
            label: "artifact digest manifest"
        )
        guard let text = String(data: data, encoding: .utf8),
              !text.isEmpty,
              text.hasSuffix("\n")
        else {
            throw invalid("artifact digest manifest is empty or malformed")
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).dropLast().map(String.init)
        var manifest: [String: String] = [:]
        var orderedPaths: [String] = []
        for line in lines {
            guard line.count > 68 else {
                throw invalid("artifact digest manifest line is malformed")
            }
            let digest = String(line.prefix(64))
            let separator = line.dropFirst(64).prefix(4)
            let path = String(line.dropFirst(68))
            guard isSHA256(digest),
                  separator == "  ./",
                  !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.split(separator: "/").contains(".."),
                  manifest[path] == nil,
                  path != "artifact-sha256.txt"
            else {
                throw invalid("artifact digest manifest path is unsafe")
            }
            manifest[path] = digest
            orderedPaths.append(path)
        }
        guard orderedPaths == orderedPaths.sorted() else {
            throw invalid("artifact digest manifest paths must be sorted")
        }
        let urls = try allRegularFiles(root: root).filter {
            $0.lastPathComponent != "artifact-sha256.txt"
        }
        let actual = try Set(urls.map {
            try relativePath($0, under: root)
        })
        guard Set(manifest.keys) == actual else {
            throw invalid(
                "artifact digest manifest file set is not exact: expected \(manifest.keys.sorted()), actual \(actual.sorted())"
            )
        }
        for url in urls {
            let path = try relativePath(url, under: root)
            guard manifest[path] == sha256(try Data(contentsOf: url)) else {
                throw invalid("artifact digest mismatch: \(path)")
            }
        }
    }

    public static func validatePerformanceStatus(
        _ data: Data,
        expectedGPUName: String,
        measuredCPUP95Milliseconds: Double
    ) throws -> ProfessionalBrushPerformanceValidationStatus {
        try rejectRawStatusStrings(data, label: "performance status")
        try requireExactKeys(
            data,
            expected: [
                "schemaVersion", "correctnessPassed", "gpuName",
                "gpuClassification",
                "cpuPreparationP95Milliseconds",
                "cpuPreparationBudgetMilliseconds",
                "gpu500DabMilliseconds", "gpu500DabBudgetMilliseconds",
                "completedStrokeLengthIndependent",
                "hotPathCompilerResourceCountersZero",
            ],
            label: "performance status"
        )
        let value: ProfessionalBrushPerformanceStatus
        do {
            value = try JSONDecoder().decode(
                ProfessionalBrushPerformanceStatus.self,
                from: data
            )
        } catch {
            throw invalid("performance status JSON is malformed")
        }
        guard value.schemaVersion == 1,
              value.correctnessPassed,
              value.gpuName == expectedGPUName,
              value.gpuClassification
                == gpuClassification(value.gpuName),
              value.cpuPreparationP95Milliseconds.isFinite,
              value.cpuPreparationP95Milliseconds >= 0,
              value.cpuPreparationBudgetMilliseconds == 2,
              value.cpuPreparationP95Milliseconds < 2,
              close(
                  value.cpuPreparationP95Milliseconds,
                  measuredCPUP95Milliseconds
              ),
              value.gpu500DabMilliseconds.isFinite,
              value.gpu500DabMilliseconds >= 0,
              value.gpu500DabBudgetMilliseconds == 3,
              value.completedStrokeLengthIndependent,
              value.hotPathCompilerResourceCountersZero
        else {
            throw invalid(
                "performance status does not prove the software budget and counter contract"
            )
        }
        if value.gpuClassification == "physical" {
            guard value.gpu500DabMilliseconds < 3 else {
                throw invalid("physical GPU 500-dab budget was exceeded")
            }
            return .passed
        }
        return .pending
    }

    public static func validateProvenance(
        _ data: Data,
        artifactRoot: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String,
        expectedStageFourManifestSHA256: String
    ) throws {
        try requireExactKeys(
            data,
            expected: [
                "schemaVersion", "commit", "sourceTreeSHA256",
                "configuration", "swiftVersion", "xcodeVersion",
                "xcodegenVersion", "operatingSystem", "kernel",
                "hardwareMachine", "hardwareModel", "gpuName",
                "gpuClassification", "artifactRoot",
                "stageFourExitStatus",
                "stageFourArtifactManifestSHA256",
            ],
            label: "provenance"
        )
        let object = try jsonObject(data, label: "provenance")
        guard object["schemaVersion"] as? Int == 1,
              object["commit"] as? String == expectedCommit,
              isCommit(expectedCommit),
              object["sourceTreeSHA256"] as? String
                == expectedSourceTreeSHA256,
              isSHA256(expectedSourceTreeSHA256),
              object["configuration"] as? String == "Debug",
              nonemptyStrings(
                  object,
                  keys: [
                      "swiftVersion", "xcodeVersion", "xcodegenVersion",
                      "operatingSystem", "kernel", "hardwareMachine",
                      "hardwareModel", "gpuName",
                  ]
              ),
              let gpuName = object["gpuName"] as? String,
              object["gpuClassification"] as? String
                == gpuClassification(gpuName),
              object["artifactRoot"] as? String
                == artifactRoot.standardizedFileURL.path,
              let stageFourExit = object["stageFourExitStatus"] as? Int,
              [0, 2].contains(stageFourExit),
              object["stageFourArtifactManifestSHA256"] as? String
                == expectedStageFourManifestSHA256,
              isSHA256(expectedStageFourManifestSHA256)
        else {
            throw invalid(
                "provenance does not bind commit, tree, tools, artifact root, and Stage 4 regression"
            )
        }
    }

    public static func sha256(_ data: Data) -> String {
        BrushContentHash.sha256Hex(of: data)
    }

    private static func resourceKind(for identity: String) -> String? {
        BrushTextureIdentity(rawValue: identity).map {
            $0.kind == .shape ? "shape" : "grain"
        }
    }

    private static func containsRawStatus(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if object.keys.contains(where: {
                ["status", "result", "outcome"].contains($0.lowercased())
            }) {
                return true
            }
            return object.values.contains(where: containsRawStatus)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsRawStatus)
        }
        return false
    }

    private static func requireExactKeys(
        _ data: Data,
        expected: Set<String>,
        label: String
    ) throws {
        guard Set(try jsonObject(data, label: label).keys) == expected else {
            throw invalid("\(label) keys are not exact")
        }
    }

    private static func jsonObject(
        _ data: Data,
        label: String
    ) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any]
        else {
            throw invalid("\(label) JSON is malformed")
        }
        return object
    }

    private static func regularFileData(
        _ url: URL,
        label: String
    ) throws -> Data {
        let values = try url.resourceValues(
            forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            throw invalid("\(label) must be a regular non-symlink file")
        }
        return try Data(contentsOf: url)
    }

    private static func allRegularFiles(root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            throw invalid("artifact root cannot be enumerated")
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                ]
            )
            guard values.isSymbolicLink != true else {
                throw invalid("artifact root contains a symbolic link")
            }
            if values.isRegularFile == true {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func relativePath(
        _ url: URL,
        under root: URL
    ) throws -> String {
        let resolvedRoot = root.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let resolvedURL = url.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let prefix = resolvedRoot + "/"
        guard resolvedURL.hasPrefix(prefix) else {
            throw invalid("artifact path escapes its root")
        }
        return String(resolvedURL.dropFirst(prefix.count))
    }

    private static func nonemptyStrings(
        _ object: [String: Any],
        keys: [String]
    ) -> Bool {
        keys.allSatisfy {
            guard let string = object[$0] as? String else { return false }
            return !string.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        }
    }

    private static func isCommit(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy(isLowerHex)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(isLowerHex)
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
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

    private static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.isFinite && rhs.isFinite
            && abs(lhs - rhs) <= max(1, abs(lhs), abs(rhs)) * 1e-12
    }

    private static func invalid(
        _ message: String
    ) -> ProfessionalBrushEvidenceValidationError {
        .invalid(message)
    }
}

public extension ProfessionalBrushEvidenceValidator {
    static func validate(
        artifactRoot: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String,
        expectedStageFourArtifactRoot: URL
    ) throws -> ProfessionalBrushEvidenceValidationStatus {
        guard artifactRoot.path.hasPrefix("/"),
              artifactRoot.standardizedFileURL.path == artifactRoot.path,
              expectedStageFourArtifactRoot.path.hasPrefix("/")
        else {
            throw invalid(
                "artifact roots must be absolute standardized paths"
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
            "scene-inputs",
            "scene-matrix.json",
            "source-tree-terminal.txt",
            "source-tree.txt",
            "stage-four-regression.json",
        ]
        guard try entryNames(artifactRoot) == expectedRootEntries else {
            throw invalid("Stage 5 artifact root file set is not exact")
        }

        let source = try regularFileData(
            artifactRoot.appendingPathComponent("source-tree.txt"),
            label: "source tree"
        )
        let terminal = try regularFileData(
            artifactRoot.appendingPathComponent(
                "source-tree-terminal.txt"
            ),
            label: "terminal source tree"
        )
        guard !source.isEmpty,
              source == terminal,
              sha256(source) == expectedSourceTreeSHA256
        else {
            throw invalid(
                "committed source tree is empty, changed, or unbound"
            )
        }

        let stageFourManifestHash = try validateStageFourRegression(
            at: artifactRoot.appendingPathComponent(
                "stage-four-regression.json"
            ),
            stageFourRoot: expectedStageFourArtifactRoot,
            expectedCommit: expectedCommit,
            expectedSourceTreeSHA256: expectedSourceTreeSHA256,
            expectedSourceTreeData: source
        )
        let provenanceData = try regularFileData(
            artifactRoot.appendingPathComponent("provenance.json"),
            label: "provenance"
        )
        try validateProvenance(
            provenanceData,
            artifactRoot: artifactRoot,
            expectedCommit: expectedCommit,
            expectedSourceTreeSHA256: expectedSourceTreeSHA256,
            expectedStageFourManifestSHA256: stageFourManifestHash
        )
        let provenance = try jsonObject(
            provenanceData,
            label: "provenance"
        )
        let gpuName = provenance["gpuName"] as! String
        let operatingSystem = provenance["operatingSystem"] as! String

        try validateSceneMatrix(
            artifactRoot.appendingPathComponent("scene-matrix.json")
        )
        let sceneRoot = artifactRoot.appendingPathComponent("scene-inputs")
        let expectedSceneFiles = Set(sceneNames.map { "\($0).json" })
        guard try entryNames(sceneRoot) == expectedSceneFiles else {
            throw invalid("scene-inputs file set is not exact")
        }
        try validateSceneSet(try loadScenes(from: sceneRoot))

        let baseline = try validateCharacterizationBaseline(
            artifactRoot.appendingPathComponent(
                "characterization-baseline.json"
            )
        )
        let maximumCPUP95 = try validatePositiveArtifacts(
            root: artifactRoot.appendingPathComponent("positive"),
            expectedCommit: expectedCommit,
            expectedGPUName: gpuName,
            expectedOperatingSystem: operatingSystem,
            baseline: baseline
        )
        try validateNegativeArtifacts(
            root: artifactRoot.appendingPathComponent("negative-control")
        )
        let manualComplete = try validateManualCatalog(
            root: artifactRoot.appendingPathComponent("manual-cards")
        )
        let physicalComplete = try validatePhysicalProfiles(
            root: artifactRoot.appendingPathComponent("physical-profiles"),
            expectedCommit: expectedCommit,
            expectedSourceTreeSHA256: expectedSourceTreeSHA256
        )
        let performance = try validatePerformanceStatus(
            regularFileData(
                artifactRoot.appendingPathComponent(
                    "performance-status.json"
                ),
                label: "performance status"
            ),
            expectedGPUName: gpuName,
            measuredCPUP95Milliseconds: maximumCPUP95
        )
        try validateArtifactManifest(root: artifactRoot)

        return performance == .passed
                && manualComplete && physicalComplete
            ? .passed
            : .pending
    }
}

private extension ProfessionalBrushEvidenceValidator {
    static let requiredPhysicalProfileNames: Set<String> = [
        "a14Floor60Hz",
        "inputToPhoton",
        "memoryWarning",
        "pencil",
        "referenceMSeriesProMotion120Hz",
        "suspendResume",
        "sustainedThermal",
        "wacom",
    ]

    static func validateStageFourRegression(
        at url: URL,
        stageFourRoot: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String,
        expectedSourceTreeData: Data
    ) throws -> String {
        let data = try regularFileData(
            url,
            label: "Stage 4 regression"
        )
        try rejectRawStatusStrings(data, label: "Stage 4 regression")
        try requireExactKeys(
            data,
            expected: [
                "schemaVersion", "exitStatus", "artifactRoot", "commit",
                "sourceTreeSHA256", "artifactManifestSHA256",
                "terminalLine",
            ],
            label: "Stage 4 regression"
        )
        let object = try jsonObject(data, label: "Stage 4 regression")
        guard object["schemaVersion"] as? Int == 1,
              let exitStatus = object["exitStatus"] as? Int,
              [0, 2].contains(exitStatus),
              object["artifactRoot"] as? String
                == stageFourRoot.standardizedFileURL.path,
              object["commit"] as? String == expectedCommit,
              object["sourceTreeSHA256"] as? String
                == expectedSourceTreeSHA256,
              let manifestHash =
                object["artifactManifestSHA256"] as? String,
              isSHA256(manifestHash),
              let terminalLine = object["terminalLine"] as? String,
              terminalLine.hasPrefix(
                  exitStatus == 0
                    ? "BRUSH STAGE 4 PASS "
                    : "BRUSH STAGE 4 PERFORMANCE PENDING "
              ),
              terminalLine.contains(
                  "artifacts=\(stageFourRoot.standardizedFileURL.path)"
              ),
              terminalLine.contains("commit=\(expectedCommit)")
        else {
            throw invalid(
                "Stage 4 regression does not bind its accepted gate exit and provenance"
            )
        }
        let manifestData = try regularFileData(
            stageFourRoot.appendingPathComponent("artifact-sha256.txt"),
            label: "Stage 4 artifact manifest"
        )
        guard sha256(manifestData) == manifestHash else {
            throw invalid("Stage 4 artifact manifest digest changed")
        }
        let stageFourSource = try regularFileData(
            stageFourRoot.appendingPathComponent("source-tree.txt"),
            label: "Stage 4 source tree"
        )
        let stageFourTerminal = try regularFileData(
            stageFourRoot.appendingPathComponent(
                "source-tree-terminal.txt"
            ),
            label: "Stage 4 terminal source tree"
        )
        guard stageFourSource == expectedSourceTreeData,
              stageFourTerminal == expectedSourceTreeData
        else {
            throw invalid(
                "Stage 4 prerequisite was not run from the same committed source"
            )
        }
        let stageFourProvenance = try jsonObject(
            regularFileData(
                stageFourRoot.appendingPathComponent("provenance.json"),
                label: "Stage 4 provenance"
            ),
            label: "Stage 4 provenance"
        )
        guard stageFourProvenance["commit"] as? String == expectedCommit,
              stageFourProvenance["sourceTreeSHA256"] as? String
                == expectedSourceTreeSHA256
        else {
            throw invalid("Stage 4 provenance does not match Stage 5")
        }
        return manifestHash
    }

    static func validateSceneMatrix(_ url: URL) throws {
        let data = try regularFileData(url, label: "scene matrix")
        try requireExactKeys(
            data,
            expected: [
                "schemaVersion", "positive", "negativeControls",
            ],
            label: "scene matrix"
        )
        let object = try jsonObject(data, label: "scene matrix")
        guard object["schemaVersion"] as? Int == 1,
              object["positive"] as? [String] == positiveSceneNames,
              object["negativeControls"] as? [String]
                == negativeSceneNames
        else {
            throw invalid(
                "scene matrix is not the exact sorted Stage 5 set"
            )
        }
    }

    static func validateCharacterizationBaseline(
        _ url: URL
    ) throws -> ProfessionalBrushLogicalBaseline {
        let data = try regularFileData(
            url,
            label: "professional characterization baseline"
        )
        try requireExactKeys(
            data,
            expected: ["schemaVersion", "records"],
            label: "professional characterization baseline"
        )
        let baseline: ProfessionalBrushLogicalBaseline
        do {
            baseline = try JSONDecoder().decode(
                ProfessionalBrushLogicalBaseline.self,
                from: data
            )
        } catch {
            throw invalid(
                "professional characterization baseline is malformed"
            )
        }
        let expectedKeys = positiveSceneNames.compactMap {
            sceneTruth[$0]?.definitionID
        }.sorted().flatMap { brushID in
            [
                "professional-corner",
                "professional-direction-turn",
                "professional-fast-line",
                "professional-grid-seam",
                "professional-hatching",
                "professional-pressure-ramp",
                "professional-radial-spoke",
                "professional-slow-line",
                "professional-tap",
                "professional-tilt-sweep",
            ].map { "\(brushID)\u{0}\($0)" }
        }
        let actualKeys = baseline.records.map {
            "\($0.brushID)\u{0}\($0.traceName)"
        }
        guard baseline.schemaVersion
                == ProfessionalBrushLogicalBaseline.schemaVersion,
              baseline.records.count == 40,
              actualKeys == expectedKeys,
              baseline.records.allSatisfy({ record in
                  sceneTruth.values.contains(where: {
                      $0.family == record.family
                          && $0.definitionID == record.brushID
                          && $0.semanticHash
                            == record.definitionSemanticHash
                  })
              })
        else {
            throw invalid(
                "professional characterization baseline is not the exact 40-record golden set"
            )
        }
        return baseline
    }

    static func validatePositiveArtifacts(
        root: URL,
        expectedCommit: String,
        expectedGPUName: String,
        expectedOperatingSystem: String,
        baseline: ProfessionalBrushLogicalBaseline
    ) throws -> Double {
        guard try entryNames(root) == Set(positiveSceneNames) else {
            throw invalid(
                "positive artifacts are not the exact four-scene set"
            )
        }
        var p95Values: [Double] = []
        for scene in positiveSceneNames {
            let directory = root.appendingPathComponent(scene)
            let expectedFiles: Set<String> = [
                "benchmark.json", "canonical.png",
                "characterization.json", "committed.png",
                "evidence.json", "live.png",
            ]
            guard try entryNames(directory) == expectedFiles else {
                throw invalid("\(scene) artifact file set is not exact")
            }
            let evidenceData = try regularFileData(
                directory.appendingPathComponent("evidence.json"),
                label: "\(scene) evidence"
            )
            try validateProfessionalEvidenceKeys(
                evidenceData,
                label: "\(scene) evidence"
            )
            let evidence = try ProfessionalBrushSceneEvidence.decode(
                evidenceData
            )
            guard evidence.scene == scene else {
                throw invalid("\(scene) evidence scene identity changed")
            }
            for (file, digest) in [
                ("live.png", evidence.livePNGSHA256),
                ("committed.png", evidence.committedPNGSHA256),
                ("canonical.png", evidence.canonicalPNGSHA256),
            ] {
                let png = try regularFileData(
                    directory.appendingPathComponent(file),
                    label: "\(scene) \(file)"
                )
                guard sha256(png) == digest,
                      pngDimensions(png) == PixelDimensions(
                          width: 128,
                          height: 128
                      )
                else {
                    throw invalid(
                        "\(scene) \(file) is invalid or hash-mismatched"
                    )
                }
            }
            let characterizationData = try regularFileData(
                directory.appendingPathComponent(
                    "characterization.json"
                ),
                label: "\(scene) characterization"
            )
            guard sha256(characterizationData)
                    == evidence.characterizationSHA256
            else {
                throw invalid(
                    "\(scene) characterization digest mismatch"
                )
            }
            let characterization:
                ProfessionalBrushCharacterizationRecord
            do {
                characterization = try JSONDecoder().decode(
                    ProfessionalBrushCharacterizationRecord.self,
                    from: characterizationData
                )
            } catch {
                throw invalid(
                    "\(scene) characterization is malformed"
                )
            }
            guard characterization.traceName
                    == "professional-slow-line",
                  characterization.brushID == evidence.definitionID,
                  characterization.family == evidence.family,
                  characterization.definitionSemanticHash
                    == evidence.definitionSemanticHash,
                  baseline.records.contains(characterization)
            else {
                throw invalid(
                    "\(scene) renderer characterization is not in the logical baseline"
                )
            }
            let benchmark: BenchmarkRecord
            do {
                benchmark = try BenchmarkRecord.decode(
                    regularFileData(
                        directory.appendingPathComponent("benchmark.json"),
                        label: "\(scene) benchmark"
                    )
                )
            } catch {
                throw invalid("\(scene) benchmark is malformed")
            }
            guard benchmark.schemaVersion == 3,
                  benchmark.sceneName == scene,
                  benchmark.build.gitCommit == expectedCommit,
                  benchmark.hardware.gpuName == expectedGPUName,
                  benchmark.operatingSystem == expectedOperatingSystem,
                  benchmark.program == "professionalNativeDeposition",
                  benchmark.recipeID == evidence.definitionID,
                  benchmark.logicalDabDigest
                    == characterization.logicalDabDigest,
                  benchmark.logicalDabCount == evidence.logicalDabCount,
                  benchmark.assetResidentBytes
                    == evidence.residentResourceBytes,
                  benchmark.peakResidentBytes
                    == UInt64(evidence.residentResourceBytes),
                  benchmark.totalProjectedFragmentCount
                    == evidence.projectedInstanceCount,
                  benchmark.totalInstanceBytes
                    == evidence.projectedInstanceCount
                        * ShaderABI.depositionStampInstanceStride,
                  benchmark.previewCommitViolationCount == 0,
                  benchmark.frameCount > 0,
                  benchmark.cpuEncodeMilliseconds.count
                    == benchmark.frameCount,
                  benchmark.gpuMilliseconds.count == benchmark.frameCount,
                  validDurations(benchmark.cpuEncodeMilliseconds),
                  validDurations(benchmark.gpuMilliseconds)
            else {
                throw invalid(
                    "\(scene) benchmark does not bind its renderer evidence and provenance"
                )
            }
            p95Values.append(
                percentile95(benchmark.cpuEncodeMilliseconds)
            )
        }
        guard let maximum = p95Values.max(), maximum < 2 else {
            throw invalid(
                "professional CPU preparation p95 did not remain below 2 ms"
            )
        }
        return maximum
    }

    static func validateNegativeArtifacts(root: URL) throws {
        guard try entryNames(root) == Set(positiveSceneNames) else {
            throw invalid(
                "negative-control artifacts are not the exact four-scene set"
            )
        }
        for scene in positiveSceneNames {
            let directory = root.appendingPathComponent(scene)
            guard try entryNames(directory) == [
                "exit-status.txt", "stderr.log", "stdout.log",
            ] else {
                throw invalid(
                    "\(scene) negative-control file set is not exact"
                )
            }
            let status = try regularFileData(
                directory.appendingPathComponent("exit-status.txt"),
                label: "\(scene) negative exit"
            )
            let stdout = try regularFileData(
                directory.appendingPathComponent("stdout.log"),
                label: "\(scene) negative stdout"
            )
            let stderr = try regularFileData(
                directory.appendingPathComponent("stderr.log"),
                label: "\(scene) negative stderr"
            )
            let expected =
                "HARNESS FAIL \(scene)-negative-control expectation 'professionalDefinitionIdentityExact' did not match\n"
            guard status == Data("1\n".utf8),
                  stdout.isEmpty,
                  stderr == Data(expected.utf8)
            else {
                throw invalid(
                    "\(scene) negative control did not fail closed exactly"
                )
            }
        }
    }

    static func validateManualCatalog(root: URL) throws -> Bool {
        guard try entryNames(root) == ["catalog.json"] else {
            throw invalid("manual-card root file set is not exact")
        }
        let data = try regularFileData(
            root.appendingPathComponent("catalog.json"),
            label: "professional manual catalog"
        )
        try rejectRawStatusStrings(data, label: "manual catalog")
        try requireExactKeys(
            data,
            expected: ["schemaVersion", "cards", "assessments"],
            label: "professional manual catalog"
        )
        let object = try jsonObject(
            data,
            label: "professional manual catalog"
        )
        guard object["schemaVersion"] as? Int == 2,
              let cards = object["cards"] as? [[String: Any]],
              let assessments =
                object["assessments"] as? [[String: Any]],
              cards.count == 68,
              assessments.count == 68
        else {
            throw invalid(
                "professional manual catalog must contain 68 cards and assessments"
            )
        }
        let cardIDs = cards.compactMap { $0["cardID"] as? String }
        let assessmentIDs = assessments.compactMap {
            $0["cardID"] as? String
        }
        let expectedBrushIDs = Set(sceneTruth.values.map(\.definitionID))
        guard cardIDs.count == 68,
              cardIDs == cardIDs.sorted(),
              Set(cardIDs).count == 68,
              Set(cards.compactMap { $0["brushID"] as? String })
                == expectedBrushIDs,
              assessmentIDs == cardIDs
        else {
            throw invalid(
                "professional manual cards are not sorted, unique, or complete"
            )
        }
        let assessmentFields = [
            "responsiveness", "edgeQuality", "taperTermination",
            "textureCohesion", "pressureResponse",
            "tiltDirectionResponse", "buildup", "symmetryBehavior",
            "eraserMatch", "notes",
        ]
        var complete = true
        for assessment in assessments {
            for field in assessmentFields {
                if let value = assessment[field] {
                    if value is NSNull {
                        complete = false
                    } else if let text = value as? String,
                              !text.trimmingCharacters(
                                  in: .whitespacesAndNewlines
                              ).isEmpty
                    {
                        continue
                    } else {
                        throw invalid(
                            "manual assessment field is malformed: \(field)"
                        )
                    }
                } else {
                    complete = false
                }
            }
        }
        return complete
    }

    static func validatePhysicalProfiles(
        root: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String
    ) throws -> Bool {
        let entries = try entryNames(root)
        guard entries.isSubset(of: requiredPhysicalProfileNames) else {
            throw invalid("physical profile set contains an unknown profile")
        }
        for profile in entries {
            let directory = root.appendingPathComponent(profile)
            guard try entryNames(directory) == [
                "evidence.json", "trace.json",
            ] else {
                throw invalid(
                    "\(profile) physical profile file set is not exact"
                )
            }
            let evidenceData = try regularFileData(
                directory.appendingPathComponent("evidence.json"),
                label: "\(profile) physical evidence"
            )
            let traceData = try regularFileData(
                directory.appendingPathComponent("trace.json"),
                label: "\(profile) physical trace"
            )
            try rejectRawStatusStrings(
                evidenceData,
                label: "\(profile) physical evidence"
            )
            try requireExactKeys(
                evidenceData,
                expected: [
                    "schemaVersion", "profileID", "commit",
                    "sourceTreeSHA256", "platform", "hardwareModel",
                    "gpuName", "gpuClassification", "inputKind",
                    "sampleCount", "measurementNames",
                    "traceSHA256", "swiftVersion", "xcodeVersion",
                ],
                label: "\(profile) physical evidence"
            )
            let evidence = try jsonObject(
                evidenceData,
                label: "\(profile) physical evidence"
            )
            guard evidence["schemaVersion"] as? Int == 1,
                  evidence["profileID"] as? String == profile,
                  evidence["commit"] as? String == expectedCommit,
                  evidence["sourceTreeSHA256"] as? String
                    == expectedSourceTreeSHA256,
                  let gpuName = evidence["gpuName"] as? String,
                  evidence["gpuClassification"] as? String
                    == "physical",
                  gpuClassification(gpuName) == "physical",
                  nonemptyStrings(
                      evidence,
                      keys: [
                          "platform", "hardwareModel", "inputKind",
                          "swiftVersion", "xcodeVersion",
                      ]
                  ),
                  let sampleCount = evidence["sampleCount"] as? Int,
                  sampleCount >= 30,
                  let names = evidence["measurementNames"] as? [String],
                  !names.isEmpty,
                  names == names.sorted(),
                  Set(names).count == names.count,
                  evidence["traceSHA256"] as? String
                    == sha256(traceData)
            else {
                throw invalid(
                    "\(profile) physical evidence is malformed or virtual"
                )
            }
            guard let trace = try? JSONSerialization.jsonObject(
                with: traceData
            ) as? [[String: Any]],
                trace.count == sampleCount,
                trace.allSatisfy({
                    guard let timestamp =
                            $0["timestampNanoseconds"] as? NSNumber,
                          let measurement =
                            $0["measurement"] as? String,
                          let value = $0["value"] as? NSNumber
                    else {
                        return false
                    }
                    return timestamp.int64Value >= 0
                        && names.contains(measurement)
                        && value.doubleValue.isFinite
                        && value.doubleValue >= 0
                })
            else {
                throw invalid(
                    "\(profile) physical raw trace is malformed"
                )
            }
        }
        return entries == requiredPhysicalProfileNames
    }

    static func validateProfessionalEvidenceKeys(
        _ data: Data,
        label: String
    ) throws {
        try requireExactKeys(
            data,
            expected: [
                "schemaVersion", "scene", "family", "definitionID",
                "definitionSemanticHash", "pipelineKey", "abiVersion",
                "residentResourceBytes", "resolvedResources",
                "logicalDabCount", "projectedInstanceCount",
                "livePNGSHA256", "committedPNGSHA256",
                "canonicalPNGSHA256", "characterizationSHA256",
                "previewCommitMaximumChannelDelta",
                "compilerCounters", "telemetry", "invariantResults",
            ],
            label: label
        )
        let object = try jsonObject(data, label: label)
        guard let resources =
                object["resolvedResources"] as? [[String: Any]],
              resources.allSatisfy({
                  Set($0.keys) == ["identity", "kind", "mipCount"]
              }),
              let compiler =
                object["compilerCounters"] as? [String: Any],
              Set(compiler.keys) == [
                  "beforeCompile", "afterCompile", "afterCacheHit",
                  "beforeStroke", "afterStroke",
              ],
              compiler.values.allSatisfy({
                  guard let snapshot = $0 as? [String: Any] else {
                      return false
                  }
                  return Set(snapshot.keys) == [
                      "packageDecodeCount", "imageDecodeCount",
                      "textureUploadCount", "cacheHitCount",
                      "activationCount",
                  ]
              }),
              let telemetry = object["telemetry"] as? [String: Any],
              Set(telemetry.keys) == [
                  "authoritativeBacklog", "predictedBacklog",
                  "backlogHighWater", "encodedInstanceCount",
                  "bufferHighWater", "missedFrameCount",
              ]
        else {
            throw invalid("\(label) nested keys are not exact")
        }
    }

    static func entryNames(_ directory: URL) throws -> Set<String> {
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw invalid(
                "\(directory.lastPathComponent) must be a non-symlink directory"
            )
        }
        return Set(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).map(\.lastPathComponent)
        )
    }

    static func pngDimensions(_ data: Data) -> PixelDimensions? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            nil
        ),
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
            ) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return PixelDimensions(width: width, height: height)
    }

    static func validDurations(_ values: [Double]) -> Bool {
        !values.isEmpty && values.allSatisfy {
            $0.isFinite && $0 >= 0
        }
    }

    static func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }
}

private struct PixelDimensions: Equatable {
    let width: Int
    let height: Int
}
