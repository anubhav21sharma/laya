import BrushFormat
import Foundation
import Metal
import PatternEngine

public enum BrushFoundationEvidenceValidationStatus: Equatable, Sendable {
    case passed
    case performancePending(gpuName: String)
}

public enum BrushFoundationEvidenceValidationError:
    Error, Equatable, LocalizedError
{
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}

public struct BrushCompilerCounterSnapshot:
    Codable, Equatable, Sendable
{
    public let packageDecodeCount: UInt64
    public let imageDecodeCount: UInt64
    public let textureUploadCount: UInt64
    public let cacheHitCount: UInt64
    public let activationCount: UInt64

    public init(_ counters: BrushCompilerCounters) {
        packageDecodeCount = counters.packageDecodeCount
        imageDecodeCount = counters.imageDecodeCount
        textureUploadCount = counters.textureUploadCount
        cacheHitCount = counters.cacheHitCount
        activationCount = counters.activationCount
    }

    public init(
        packageDecodeCount: UInt64,
        imageDecodeCount: UInt64,
        textureUploadCount: UInt64,
        cacheHitCount: UInt64,
        activationCount: UInt64
    ) {
        self.packageDecodeCount = packageDecodeCount
        self.imageDecodeCount = imageDecodeCount
        self.textureUploadCount = textureUploadCount
        self.cacheHitCount = cacheHitCount
        self.activationCount = activationCount
    }
}

public struct BrushCompilerCounterEvidence:
    Codable, Equatable, Sendable
{
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let commit: String
    public let gpuName: String
    public let activeDefinitionID: String
    public let residentByteCount: Int
    public let logicalDabEvaluationCount: Int
    public let beforeCompile: BrushCompilerCounterSnapshot
    public let afterFirstCompile: BrushCompilerCounterSnapshot
    public let afterCacheHit: BrushCompilerCounterSnapshot
    public let afterLogicalDabs: BrushCompilerCounterSnapshot

    public init(
        commit: String,
        gpuName: String,
        activeDefinitionID: String,
        residentByteCount: Int,
        logicalDabEvaluationCount: Int,
        beforeCompile: BrushCompilerCounterSnapshot,
        afterFirstCompile: BrushCompilerCounterSnapshot,
        afterCacheHit: BrushCompilerCounterSnapshot,
        afterLogicalDabs: BrushCompilerCounterSnapshot
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.commit = commit
        self.gpuName = gpuName
        self.activeDefinitionID = activeDefinitionID
        self.residentByteCount = residentByteCount
        self.logicalDabEvaluationCount = logicalDabEvaluationCount
        self.beforeCompile = beforeCompile
        self.afterFirstCompile = afterFirstCompile
        self.afterCacheHit = afterCacheHit
        self.afterLogicalDabs = afterLogicalDabs
    }
}

public struct BrushAnchorAdapterParityRecord:
    Codable, Equatable, Sendable
{
    public let recipeID: String
    public let traceName: String
    public let programLogicalDabCount: Int
    public let compatibilityLogicalDabCount: Int
    public let programLogicalDabDigest: String
    public let compatibilityLogicalDabDigest: String

    public init(
        recipeID: String,
        traceName: String,
        programLogicalDabCount: Int,
        compatibilityLogicalDabCount: Int,
        programLogicalDabDigest: String,
        compatibilityLogicalDabDigest: String
    ) {
        self.recipeID = recipeID
        self.traceName = traceName
        self.programLogicalDabCount = programLogicalDabCount
        self.compatibilityLogicalDabCount = compatibilityLogicalDabCount
        self.programLogicalDabDigest = programLogicalDabDigest
        self.compatibilityLogicalDabDigest = compatibilityLogicalDabDigest
    }
}

public struct BrushAnchorAdapterParityEvidence:
    Codable, Equatable, Sendable
{
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let commit: String
    public let records: [BrushAnchorAdapterParityRecord]

    public init(
        commit: String,
        records: [BrushAnchorAdapterParityRecord]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.commit = commit
        self.records = records
    }
}

public enum BrushFoundationCompilerProbe {
    public static let definitionID = "evidence.cache-probe"
    public static let logicalDabEvaluationCount = 1_000

    @MainActor
    public static func capture(commit: String) async throws
        -> BrushCompilerCounterEvidence
    {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            throw BrushFoundationEvidenceValidationError.invalid(
                "Metal device or command queue is unavailable"
            )
        }
        let profile = try BrushDeviceProfile(
            registryID: device.registryID,
            recommendedWorkingSetBytes:
                max(device.recommendedMaxWorkingSetSize, 64 * 1_024 * 1_024),
            maximumWorkingTextureDimension:
                BrushDeviceProfile.maximumPortableTextureDimension,
            targetFramesPerSecond: 120
        )
        let compiler = BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: profile
        )
        let package = try probePackage()
        let before = BrushCompilerCounterSnapshot(compiler.debugCounters)
        let first = try await compiler.compileAndActivate(package: package)
        let afterFirst = BrushCompilerCounterSnapshot(compiler.debugCounters)
        let second = try await compiler.compileAndActivate(package: package)
        let afterCacheHit = BrushCompilerCounterSnapshot(
            compiler.debugCounters
        )

        var emitted = 0
        for index in 0..<logicalDabEvaluationCount {
            var generator = BrushStrokeGenerator(
                program: second.program,
                nominalDiameter: 20,
                color: .black,
                seed: UInt64(index + 1)
            )
            emitted += generator.beginBatches(probeSample()).reduce(0) {
                $0 + $1.dabs.count
            }
        }
        let afterDabs = BrushCompilerCounterSnapshot(compiler.debugCounters)
        guard first.residentByteCount == second.residentByteCount else {
            throw BrushFoundationEvidenceValidationError.invalid(
                "compiler probe cache hit changed resident bytes"
            )
        }
        return BrushCompilerCounterEvidence(
            commit: commit,
            gpuName: device.name,
            activeDefinitionID: second.program.definition.id.rawValue,
            residentByteCount: second.residentByteCount,
            logicalDabEvaluationCount: emitted,
            beforeCompile: before,
            afterFirstCompile: afterFirst,
            afterCacheHit: afterCacheHit,
            afterLogicalDabs: afterDabs
        )
    }

    private static func probePackage() throws -> BrushPackage {
        let recipe = try BrushRecipe(
            id: BrushRecipeID(definitionID),
            shape: .asset("builtin.shape.hard-round")
        )
        let definition = try LegacyBrushRecipeAdapter.definition(
            from: recipe,
            displayName: "Foundation cache probe"
        )
        return try BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: definition,
            resourceData: [:]
        )
    }

    private static func probeSample() -> WorldStrokeSample {
        var input = BrushInputDeriver()
        return input.derive(
            StrokeSample(
                position: ScreenPoint(x: 0, y: 0),
                pressure: 1,
                timestamp: 0,
                phase: .began,
                source: .pencil,
                capabilities: [.pressure]
            ),
            viewport: ViewportTransform(
                drawableSize: PatternSize(width: 1, height: 1),
                worldCenter: WorldPoint(x: 0, y: 0)
            )
        )
    }
}

public enum BrushFoundationEvidenceValidator {
    public typealias SliceFourValidator = (
        URL, URL, URL, String
    ) throws -> SliceFourEvidenceValidationStatus

    public static let logicalFileName = "brush-logical-v1.json"
    public static let parityFileName = "anchor-adapter-parity.json"
    public static let compilerFileName = "compiler-counters.json"
    public static let performanceFileName = "performance-status.txt"
    public static let sceneDirectoryName = "scene-inputs"

    public static func validate(
        logicalBaselineURL: URL,
        rendererBaselineURL: URL,
        artifactRoot: URL,
        expectedCommit: String
    ) throws -> BrushFoundationEvidenceValidationStatus {
        try validate(
            logicalBaselineURL: logicalBaselineURL,
            rendererBaselineURL: rendererBaselineURL,
            artifactRoot: artifactRoot,
            expectedCommit: expectedCommit,
            sliceFourValidator: {
                try SliceFourEvidenceValidator.validate(
                    positiveRoot: $0,
                    negativeRoot: $1,
                    sceneRoot: $2,
                    expectedCommit: $3
                )
            }
        )
    }

    static func validate(
        logicalBaselineURL: URL,
        rendererBaselineURL: URL,
        artifactRoot: URL,
        expectedCommit: String,
        sliceFourValidator: SliceFourValidator
    ) throws -> BrushFoundationEvidenceValidationStatus {
        guard isCommit(expectedCommit) else {
            throw invalid("expected commit must be 40 lowercase hexadecimal characters")
        }
        let positiveRoot = artifactRoot.appendingPathComponent("positive")
        let negativeRoot = artifactRoot.appendingPathComponent(
            "negative-control"
        )
        let sceneRoot = artifactRoot.appendingPathComponent(sceneDirectoryName)
        try validateSceneInputs(sceneRoot)
        try validateEvidencePairs(
            positiveRoot: positiveRoot,
            negativeRoot: negativeRoot
        )

        let logicalBaseline = try decodeLogicalBaseline(
            logicalBaselineURL,
            label: "checked logical baseline"
        )
        let actualLogical = try decodeLogicalBaseline(
            artifactRoot.appendingPathComponent(logicalFileName),
            label: "generated logical evidence"
        )
        try validateLogicalBaseline(logicalBaseline)
        try validateLogicalBaseline(actualLogical)
        guard logicalBaseline == actualLogical else {
            throw invalid("generated 15-record logical evidence changed")
        }
        try validateParity(
            at: artifactRoot.appendingPathComponent(parityFileName),
            expectedCommit: expectedCommit,
            logical: actualLogical
        )

        let rendererBaseline = try decodeRendererBaseline(
            rendererBaselineURL,
            label: "checked renderer baseline"
        )
        try rendererBaseline.validate(expectedRecordCount: 8)
        let actualRenderer: BrushCharacterizationBaseline
        do {
            actualRenderer = try BrushCharacterizationBaseline.merge(
                inputRoot: positiveRoot
            )
        } catch {
            throw invalid(
                "generated renderer characterization is incomplete or invalid: \(error.localizedDescription)"
            )
        }
        do {
            try rendererBaseline.requireMatches(actualRenderer.records)
        } catch {
            throw invalid(
                "generated eight-record renderer characterization changed"
            )
        }
        let benchmarkGPUName = try loadBenchmarkGPUName(
            positiveRoot.appendingPathComponent(
                SliceFourEvidenceValidator.sceneNames[0]
            ).appendingPathComponent(
                "\(SliceFourEvidenceValidator.sceneNames[0]).benchmark.json"
            )
        )
        try validateCompilerEvidence(
            at: artifactRoot.appendingPathComponent(compilerFileName),
            expectedCommit: expectedCommit,
            expectedGPUName: benchmarkGPUName
        )

        let sliceFourStatus: SliceFourEvidenceValidationStatus
        do {
            sliceFourStatus = try sliceFourValidator(
                positiveRoot,
                negativeRoot,
                sceneRoot,
                expectedCommit
            )
        } catch {
            throw invalid(
                "Slice 4 correctness, schema-6, digest, parity, or performance validation failed: \(error.localizedDescription)"
            )
        }
        return try validatePerformanceStatus(
            sliceFourStatus,
            at: artifactRoot.appendingPathComponent(performanceFileName)
        )
    }

    private static func validateLogicalBaseline(
        _ baseline: BrushLogicalBaseline
    ) throws {
        guard baseline.schemaVersion == BrushLogicalBaseline.schemaVersion,
              baseline.records.count == 15,
              Set(baseline.records.map(\.recipeID)).count == 5,
              baseline.records.allSatisfy({
                  !$0.traceName.isEmpty
                      && !$0.recipeID.isEmpty
                      && $0.nominalDiameter.isFinite
                      && $0.nominalDiameter > 0
                      && $0.sampleCount > 0
                      && $0.logicalDabCount > 0
                      && isDigest($0.logicalDabDigest)
              })
        else {
            throw invalid("logical evidence is not the exact valid 15-record matrix")
        }
    }

    private static func validateParity(
        at url: URL,
        expectedCommit: String,
        logical: BrushLogicalBaseline
    ) throws {
        let data = try regularFileData(url, label: "anchor adapter parity")
        try requireKeys(
            data,
            expected: ["schemaVersion", "commit", "records"],
            label: "anchor adapter parity"
        )
        let evidence: BrushAnchorAdapterParityEvidence
        do {
            evidence = try JSONDecoder().decode(
                BrushAnchorAdapterParityEvidence.self,
                from: data
            )
        } catch {
            throw invalid("anchor adapter parity JSON is invalid: \(error)")
        }
        guard let parityObject = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let parityRecords = parityObject["records"] as? [[String: Any]],
              parityRecords.allSatisfy({
                  Set($0.keys) == [
                      "recipeID", "traceName", "programLogicalDabCount",
                      "compatibilityLogicalDabCount",
                      "programLogicalDabDigest",
                      "compatibilityLogicalDabDigest",
                  ]
              })
        else {
            throw invalid("anchor adapter parity records have unexpected keys")
        }
        let sorted = evidence.records.sorted {
            ($0.recipeID, $0.traceName) < ($1.recipeID, $1.traceName)
        }
        guard evidence.schemaVersion
                == BrushAnchorAdapterParityEvidence.currentSchemaVersion,
              evidence.commit == expectedCommit,
              evidence.records == sorted,
              evidence.records.count == 15,
              Set(evidence.records.map {
                  "\($0.recipeID)\u{0}\($0.traceName)"
              }).count == 15,
              evidence.records.allSatisfy({
                  $0.programLogicalDabCount
                      == $0.compatibilityLogicalDabCount
                      && $0.programLogicalDabCount > 0
                      && $0.programLogicalDabDigest
                          == $0.compatibilityLogicalDabDigest
                      && isDigest($0.programLogicalDabDigest)
              })
        else {
            throw invalid("anchor adapter parity is not an exact 15-entry match")
        }
        let logicalByKey = Dictionary(
            uniqueKeysWithValues: logical.records.map {
                ("\($0.recipeID)\u{0}\($0.traceName)", $0)
            }
        )
        for record in evidence.records {
            let key = "\(record.recipeID)\u{0}\(record.traceName)"
            guard let expected = logicalByKey[key],
                  expected.logicalDabCount == record.programLogicalDabCount,
                  expected.logicalDabDigest == record.programLogicalDabDigest
            else {
                throw invalid(
                    "anchor adapter parity disagrees with logical evidence: \(record.recipeID)/\(record.traceName)"
                )
            }
        }
    }

    static func validateCompilerEvidence(
        at url: URL,
        expectedCommit: String,
        expectedGPUName: String
    ) throws {
        let data = try regularFileData(url, label: "compiler counter evidence")
        try requireKeys(
            data,
            expected: [
                "schemaVersion", "commit", "gpuName", "activeDefinitionID",
                "residentByteCount", "logicalDabEvaluationCount",
                "beforeCompile", "afterFirstCompile", "afterCacheHit",
                "afterLogicalDabs",
            ],
            label: "compiler counter evidence"
        )
        let evidence: BrushCompilerCounterEvidence
        do {
            evidence = try JSONDecoder().decode(
                BrushCompilerCounterEvidence.self,
                from: data
            )
        } catch {
            throw invalid("compiler counter evidence JSON is invalid: \(error)")
        }
        guard let counterObject = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              [
                  "beforeCompile", "afterFirstCompile", "afterCacheHit",
                  "afterLogicalDabs",
              ].allSatisfy({
                  guard let snapshot = counterObject[$0] as? [String: Any]
                  else { return false }
                  return Set(snapshot.keys) == [
                      "packageDecodeCount", "imageDecodeCount",
                      "textureUploadCount", "cacheHitCount",
                      "activationCount",
                  ]
              })
        else {
            throw invalid("compiler counter snapshots have unexpected keys")
        }
        let zero = BrushCompilerCounterSnapshot(
            packageDecodeCount: 0,
            imageDecodeCount: 0,
            textureUploadCount: 0,
            cacheHitCount: 0,
            activationCount: 0
        )
        let first = BrushCompilerCounterSnapshot(
            packageDecodeCount: 1,
            imageDecodeCount: 0,
            textureUploadCount: 1,
            cacheHitCount: 0,
            activationCount: 1
        )
        let hit = BrushCompilerCounterSnapshot(
            packageDecodeCount: 2,
            imageDecodeCount: 0,
            textureUploadCount: 1,
            cacheHitCount: 1,
            activationCount: 2
        )
        guard evidence.schemaVersion
                == BrushCompilerCounterEvidence.currentSchemaVersion,
              evidence.commit == expectedCommit,
              evidence.gpuName == expectedGPUName,
              evidence.activeDefinitionID
                == BrushFoundationCompilerProbe.definitionID,
              evidence.residentByteCount > 0,
              evidence.logicalDabEvaluationCount
                == BrushFoundationCompilerProbe.logicalDabEvaluationCount,
              evidence.beforeCompile == zero,
              evidence.afterFirstCompile == first,
              evidence.afterCacheHit == hit,
              evidence.afterLogicalDabs == hit
        else {
            throw invalid(
                "compiler evidence does not prove first upload, cache hit, and zero input-path compiler work"
            )
        }
    }

    private static func validateEvidencePairs(
        positiveRoot: URL,
        negativeRoot: URL
    ) throws {
        guard try directoryNames(positiveRoot)
                == Set(SliceFourEvidenceValidator.sceneNames),
              try directoryNames(negativeRoot)
                == Set(SliceFourEvidenceValidator.sceneNames)
        else {
            throw invalid(
                "positive and negative directories must exactly match all eight Slice 4 scenes"
            )
        }
        for name in SliceFourEvidenceValidator.sceneNames {
            _ = try regularFileData(
                positiveRoot.appendingPathComponent(name)
                    .appendingPathComponent(
                        "\(name).brush-characterization.json"
                    ),
                label: "\(name) characterization"
            )
            let negative = negativeRoot.appendingPathComponent(name)
            guard try directoryNames(negative)
                    == ["stdout.log", "stderr.log", "exit-status.txt"]
            else {
                throw invalid("\(name): negative artifact file set is invalid")
            }
            let stdout = try regularFileData(
                negative.appendingPathComponent("stdout.log"),
                label: "\(name) negative stdout",
                allowEmpty: true
            )
            let stderr = try regularFileData(
                negative.appendingPathComponent("stderr.log"),
                label: "\(name) negative stderr"
            )
            let exit = try regularFileData(
                negative.appendingPathComponent("exit-status.txt"),
                label: "\(name) negative exit status"
            )
            guard stdout.isEmpty,
                  String(decoding: exit, as: UTF8.self) == "1\n",
                  let stderrText = String(data: stderr, encoding: .utf8),
                  stderrText.hasPrefix("HARNESS FAIL "),
                  stderrText.hasSuffix("\n"),
                  stderrText.split(separator: "\n").count == 1
            else {
                throw invalid(
                    "\(name): negative control did not fail closed with exact exit 1"
                )
            }
        }
    }

    private static func validateSceneInputs(_ root: URL) throws {
        let expected = Set(
            SliceFourEvidenceValidator.sceneNames.flatMap {
                ["\($0).json", "\($0)-negative-control.json"]
            }
        )
        guard try directoryNames(root) == expected else {
            throw invalid(
                "scene-inputs must contain exactly the 16 Slice 4 scene files"
            )
        }
        for name in expected {
            _ = try regularFileData(
                root.appendingPathComponent(name),
                label: "scene input \(name)"
            )
        }
    }

    private static func validatePerformanceStatus(
        _ status: SliceFourEvidenceValidationStatus,
        at url: URL
    ) throws -> BrushFoundationEvidenceValidationStatus {
        let text = String(
            decoding: try regularFileData(
                url,
                label: "performance status"
            ),
            as: UTF8.self
        )
        switch status {
        case .passed:
            guard text == "accepted\n" else {
                throw invalid("unrecognized performance-pending text")
            }
            return .passed
        case let .performancePending(gpuName):
            guard BenchmarkHardware.isPerformancePendingEnvironment(
                gpuName: gpuName
            ) else {
                throw invalid(
                    "only a GPU name containing 'paravirtual' may be performance pending"
                )
            }
            let expected =
                "SLICE3 PERFORMANCE PENDING: unstable real-Metal timing environment '\(gpuName)'.\n"
            guard text == expected else {
                throw invalid("unrecognized performance-pending text")
            }
            return .performancePending(gpuName: gpuName)
        }
    }

    private static func loadBenchmarkGPUName(_ url: URL) throws -> String {
        let data = try regularFileData(url, label: "schema-6 benchmark provenance")
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let hardware = object["hardware"] as? [String: Any],
              let gpuName = hardware["gpuName"] as? String,
              !gpuName.isEmpty
        else {
            throw invalid("schema-6 benchmark GPU provenance is missing")
        }
        return gpuName
    }

    private static func decodeLogicalBaseline(
        _ url: URL,
        label: String
    ) throws -> BrushLogicalBaseline {
        let data = try regularFileData(url, label: label)
        do {
            return try JSONDecoder().decode(
                BrushLogicalBaseline.self,
                from: data
            )
        } catch {
            throw invalid("\(label) cannot be decoded strictly: \(error)")
        }
    }

    private static func decodeRendererBaseline(
        _ url: URL,
        label: String
    ) throws -> BrushCharacterizationBaseline {
        let data = try regularFileData(url, label: label)
        do {
            return try JSONDecoder().decode(
                BrushCharacterizationBaseline.self,
                from: data
            )
        } catch {
            throw invalid("\(label) cannot be decoded strictly: \(error)")
        }
    }

    private static func directoryNames(_ url: URL) throws -> Set<String> {
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw invalid("required directory is missing or is a symlink: \(url.path)")
        }
        return Set(
            try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ).map(\.lastPathComponent)
        )
    }

    private static func regularFileData(
        _ url: URL,
        label: String,
        allowEmpty: Bool = false
    ) throws -> Data {
        do {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true
            else {
                throw invalid("\(label) is missing, nonregular, or a symlink")
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard allowEmpty || !data.isEmpty else {
                throw invalid("\(label) is empty")
            }
            return data
        } catch let error as BrushFoundationEvidenceValidationError {
            throw error
        } catch {
            throw invalid("\(label) cannot be read: \(error.localizedDescription)")
        }
    }

    private static func requireKeys(
        _ data: Data,
        expected: Set<String>,
        label: String
    ) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys) == expected
        else {
            throw invalid("\(label) has missing or unexpected top-level keys")
        }
    }

    private static func isCommit(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 16 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func invalid(
        _ message: String
    ) -> BrushFoundationEvidenceValidationError {
        .invalid(message)
    }
}
