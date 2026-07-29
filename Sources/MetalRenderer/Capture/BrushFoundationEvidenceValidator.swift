import BrushFormat
import Foundation
import Metal
import PatternEngine

public enum BrushFoundationEvidenceValidationStatus: Equatable, Sendable {
    case passed
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

public enum BrushFoundationCompilerProbe {
    public static let definitionID = "harness.native-draw"
    public static let logicalDabEvaluationCount = 1_000

    @MainActor
    public static func capture(
        commit: String
    ) async throws -> BrushCompilerCounterEvidence {
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
        let pipelinePreparing: any DepositionPipelinePreparing
        if let library = device.makeDefaultLibrary() {
            pipelinePreparing = DepositionPipelineLibrary(
                device: device,
                library: library
            )
        } else {
            pipelinePreparing = try BrushFoundationProbePipelinePreparer(
                device: device
            )
        }
        let compiler = BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: profile,
            pipelinePreparing: pipelinePreparing,
            testHooks: .none
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

    @MainActor
    private static func probePackage() throws -> BrushPackage {
        try BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: GridRenderer.nativeHarnessDefinition(mode: .draw),
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

@MainActor
private final class BrushFoundationProbePipelinePreparer:
    DepositionPipelinePreparing
{
    private let state: any MTLRenderPipelineState
    private var bindings:
        [DepositionPipelineKey: DepositionPipelineBinding] = [:]

    init(device: any MTLDevice) throws {
        let source = """
            #include <metal_stdlib>
            using namespace metal;
            vertex float4 foundationProbeVertex(uint id [[vertex_id]]) {
                const float2 points[3] = {
                    float2(-1, -1), float2(3, -1), float2(-1, 3)
                };
                return float4(points[id], 0, 1);
            }
            fragment float4 foundationProbeFragment() {
                return float4(0);
            }
            """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(
            name: "foundationProbeVertex"
        )
        descriptor.fragmentFunction = library.makeFunction(
            name: "foundationProbeFragment"
        )
        descriptor.colorAttachments[0].pixelFormat =
            GridPipelineLibrary.colorPixelFormat
        state = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func prepare(
        for key: DepositionPipelineKey
    ) async throws -> DepositionPipelineBinding {
        if let binding = bindings[key] {
            return binding
        }
        let binding = DepositionPipelineBinding(key: key, state: state)
        bindings[key] = binding
        return binding
    }
}

private struct BrushFoundationProvenance: Decodable {
    let schemaVersion: Int
    let commit: String
    let configuration: String
    let operatingSystem: String
    let hardwareMachine: String
    let hardwareModel: String
    let gpuName: String
    let artifactRoot: String
}

private struct BrushFoundationPositiveRun {
    let gpuName: String
    let configuration: String
    let operatingSystem: String
}

public enum BrushFoundationEvidenceValidator {
    public static let compilerFileName = "compiler-counters.json"
    public static let performanceFileName = "performance-status.txt"
    public static let provenanceFileName = "provenance.json"
    public static let sceneDirectoryName = "scene-inputs"

    public static func validate(
        artifactRoot: URL,
        expectedCommit: String
    ) throws -> BrushFoundationEvidenceValidationStatus {
        guard isCommit(expectedCommit) else {
            throw invalid(
                "expected commit must be 40 lowercase hexadecimal characters"
            )
        }
        let positiveRoot = artifactRoot.appendingPathComponent("positive")
        let negativeRoot = artifactRoot.appendingPathComponent(
            "negative-control"
        )
        let scenesByName = try validateSceneInputs(
            artifactRoot.appendingPathComponent(sceneDirectoryName)
        )
        let positiveRun = try validatePositiveEvidence(
            root: positiveRoot,
            expectedCommit: expectedCommit,
            scenesByName: scenesByName
        )
        try validateNegativeControls(root: negativeRoot)
        try validateCompilerEvidence(
            at: artifactRoot.appendingPathComponent(compilerFileName),
            expectedCommit: expectedCommit,
            expectedGPUName: positiveRun.gpuName
        )
        try validateProvenance(
            at: artifactRoot.appendingPathComponent(provenanceFileName),
            artifactRoot: artifactRoot,
            expectedCommit: expectedCommit,
            expectedRun: positiveRun
        )
        return try validatePerformanceStatus(
            at: artifactRoot.appendingPathComponent(performanceFileName)
        )
    }

    static func validateCompilerEvidence(
        at url: URL,
        expectedCommit: String,
        expectedGPUName: String
    ) throws {
        guard !expectedGPUName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw invalid("benchmark GPU name must be nonempty")
        }
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
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              [
                  "beforeCompile", "afterFirstCompile", "afterCacheHit",
                  "afterLogicalDabs",
              ].allSatisfy({
                  guard let snapshot = object[$0] as? [String: Any] else {
                      return false
                  }
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
                "compiler evidence does not match the benchmark GPU or prove first upload, cache hit, and zero input-path compiler work"
            )
        }
    }

    private static func validateSceneInputs(
        _ root: URL
    ) throws -> [String: HarnessScene] {
        let expected = Set(
            DepositionEvidenceValidator.sceneNames.map { "\($0).json" }
        )
        guard try entryNames(root) == expected else {
            throw invalid(
                "scene-inputs must contain the exact 32-scene native deposition matrix"
            )
        }
        do {
            let scenes = try DepositionEvidenceValidator.loadScenes(from: root)
            try DepositionEvidenceValidator.validateSceneSet(scenes)
            return Dictionary(
                uniqueKeysWithValues: scenes.map { ($0.name, $0) }
            )
        } catch {
            throw invalid(
                "native deposition scene inputs are invalid: \(error.localizedDescription)"
            )
        }
    }

    private static func validatePositiveEvidence(
        root: URL,
        expectedCommit: String,
        scenesByName: [String: HarnessScene]
    ) throws -> BrushFoundationPositiveRun {
        let expectedNames = Set(
            DepositionEvidenceValidator.positiveSceneNames
        )
        guard try entryNames(root) == expectedNames else {
            throw invalid(
                "positive artifacts must contain exactly the 16 active deposition scenes"
            )
        }
        let expectedEvidence = Set(expectedNames.map {
            "\($0)/\($0).deposition-evidence.json"
        })
        let actualEvidence = try recursiveRegularFilePaths(
            root: root,
            suffix: ".deposition-evidence.json"
        )
        guard actualEvidence == expectedEvidence else {
            throw invalid(
                "positive artifacts must contain exactly one correctly named evidence file per active scene; found \(actualEvidence.sorted())"
            )
        }
        let expectedBenchmarks = Set(expectedNames.map {
            "\($0)/\($0).benchmark.json"
        })
        let actualBenchmarks = try recursiveRegularFilePaths(
            root: root,
            suffix: ".benchmark.json"
        )
        guard actualBenchmarks == expectedBenchmarks else {
            throw invalid(
                "positive artifacts must contain exactly one correctly named benchmark per active scene"
            )
        }

        var gpuNames = Set<String>()
        var configurations = Set<String>()
        var operatingSystems = Set<String>()
        for name in DepositionEvidenceValidator.positiveSceneNames {
            let sceneRoot = root.appendingPathComponent(name)
            try requireDirectory(sceneRoot, label: "\(name) positive artifacts")
            let evidenceURL = sceneRoot.appendingPathComponent(
                "\(name).deposition-evidence.json"
            )
            let evidence: DepositionSceneEvidence
            do {
                evidence = try DepositionSceneEvidence.decode(
                    regularFileData(
                        evidenceURL,
                        label: "\(name) deposition evidence"
                    )
                )
                guard evidence.scene == name else {
                    throw invalid(
                        "\(name) evidence identifies scene \(evidence.scene)"
                    )
                }
                guard let scene = scenesByName[name] else {
                    throw invalid("\(name) has no matching scene input")
                }
                try DepositionEvidenceValidator.validateExpectations(
                    scene: scene,
                    actual: evidence.invariantResults
                )
                guard evidence.invariantResults.values.allSatisfy({
                    $0
                }) else {
                    throw invalid(
                        "\(name) positive evidence contains a false invariant"
                    )
                }
            } catch let error as BrushFoundationEvidenceValidationError {
                throw error
            } catch {
                throw invalid(
                    "\(name) deposition evidence is invalid: \(error.localizedDescription)"
                )
            }
            let benchmarkURL = sceneRoot.appendingPathComponent(
                "\(name).benchmark.json"
            )
            let benchmark: BenchmarkRecord
            do {
                benchmark = try BenchmarkRecord.decode(
                    regularFileData(
                        benchmarkURL,
                        label: "\(name) benchmark"
                    )
                )
            } catch {
                throw invalid(
                    "\(name) benchmark is invalid: \(error.localizedDescription)"
                )
            }
            let gpuName = benchmark.hardware.gpuName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let configuration = benchmark.build.configuration
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let operatingSystem = benchmark.operatingSystem
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard benchmark.schemaVersion == 3,
                  benchmark.sceneName == name,
                  benchmark.build.gitCommit == expectedCommit,
                  !configuration.isEmpty,
                  !operatingSystem.isEmpty,
                  !gpuName.isEmpty,
                  benchmarkMatchesNativeEvidence(
                      benchmark,
                      evidence: evidence
                  )
            else {
                throw invalid(
                    "\(name) benchmark provenance does not match the active run"
                )
            }
            gpuNames.insert(gpuName)
            configurations.insert(configuration)
            operatingSystems.insert(operatingSystem)
        }
        guard gpuNames.count == 1,
              configurations.count == 1,
              operatingSystems.count == 1,
              let gpuName = gpuNames.first,
              let configuration = configurations.first,
              let operatingSystem = operatingSystems.first
        else {
            throw invalid(
                "all 16 active benchmarks must identify one GPU, configuration, and operating system"
            )
        }
        return BrushFoundationPositiveRun(
            gpuName: gpuName,
            configuration: configuration,
            operatingSystem: operatingSystem
        )
    }

    private static func benchmarkMatchesNativeEvidence(
        _ benchmark: BenchmarkRecord,
        evidence: DepositionSceneEvidence
    ) -> Bool {
        let (instanceBytes, overflow) =
            evidence.projectedInstanceCount.multipliedReportingOverflow(
                by: ShaderABI.depositionStampInstanceStride
            )
        guard !overflow else {
            return false
        }
        return benchmark.program == "nativeDeposition"
            && benchmark.recipeID == evidence.definitionID
            && benchmark.logicalDabDigest == evidence.canonicalSHA256
            && benchmark.canonicalBGRA8Digest == evidence.canonicalSHA256
            && benchmark.logicalDabCount == evidence.logicalDabCount
            && benchmark.peakResidentBytes == UInt64(evidence.resourceBytes)
            && benchmark.assetResidentBytes == evidence.resourceBytes
            && benchmark.newInstanceCounts
                == [evidence.projectedInstanceCount]
            && benchmark.totalProjectedFragmentCount
                == evidence.projectedInstanceCount
            && benchmark.totalInstanceBytes == instanceBytes
            && benchmark.previewCommitViolationCount
                == (evidence.previewCommitMaximumChannelDelta > 1 ? 1 : 0)
            && benchmark.seed.map { $0 != 0 } == true
            && benchmark.frameCount > 0
            && benchmark.cpuEncodeMilliseconds.count == benchmark.frameCount
            && benchmark.gpuMilliseconds.count == benchmark.frameCount
            && benchmark.material == nil
            && benchmark.replayMode == nil
            && benchmark.peakRetainedSampleCount == nil
            && benchmark.peakRetainedDabCount == nil
            && benchmark.replayCount == nil
            && benchmark.promotedSettledPrefixCount == nil
            && benchmark.replayDegradationCount == nil
            && benchmark.materialGPUMilliseconds == nil
            && benchmark.processedWashPixelCount == nil
            && benchmark.washWorkingBytes == nil
            && benchmark.brushCharacterizationVersion == nil
            && benchmark.inputSampleCount == nil
            && benchmark.fiveHundredDabStressFrameIndex == nil
            && benchmark.fiveHundredDabStressNewDabCount == nil
    }

    private static func validateNegativeControls(root: URL) throws {
        let expectedNames = Set(
            DepositionEvidenceValidator.positiveSceneNames
        )
        guard try entryNames(root) == expectedNames else {
            throw invalid(
                "negative-control artifacts must contain exactly 16 active scene pairs"
            )
        }
        for name in DepositionEvidenceValidator.positiveSceneNames {
            let directory = root.appendingPathComponent(name)
            try requireDirectory(
                directory,
                label: "\(name) negative control"
            )
            guard try entryNames(directory)
                    == ["stdout.log", "stderr.log", "exit-status.txt"]
            else {
                throw invalid(
                    "\(name): negative-control file set is invalid"
                )
            }
            let stdout = try regularFileData(
                directory.appendingPathComponent("stdout.log"),
                label: "\(name) negative stdout",
                allowEmpty: true
            )
            let stderr = try regularFileData(
                directory.appendingPathComponent("stderr.log"),
                label: "\(name) negative stderr"
            )
            let exit = try regularFileData(
                directory.appendingPathComponent("exit-status.txt"),
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

    private static func validateProvenance(
        at url: URL,
        artifactRoot: URL,
        expectedCommit: String,
        expectedRun: BrushFoundationPositiveRun
    ) throws {
        let data = try regularFileData(url, label: "foundation provenance")
        try requireKeys(
            data,
            expected: [
                "schemaVersion", "commit", "configuration",
                "operatingSystem", "hardwareMachine", "hardwareModel",
                "gpuName", "artifactRoot",
            ],
            label: "foundation provenance"
        )
        let provenance: BrushFoundationProvenance
        do {
            provenance = try JSONDecoder().decode(
                BrushFoundationProvenance.self,
                from: data
            )
        } catch {
            throw invalid("foundation provenance JSON is invalid: \(error)")
        }
        guard provenance.schemaVersion == 1,
              provenance.commit == expectedCommit,
              provenance.gpuName == expectedRun.gpuName,
              provenance.configuration == expectedRun.configuration,
              provenance.operatingSystem == expectedRun.operatingSystem,
              provenance.artifactRoot
                == artifactRoot.standardizedFileURL.path,
              [
                  provenance.hardwareMachine,
                  provenance.hardwareModel,
              ].allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else {
            throw invalid(
                "foundation provenance does not match the evidence run"
            )
        }
    }

    private static func validatePerformanceStatus(
        at url: URL
    ) throws -> BrushFoundationEvidenceValidationStatus {
        let text = String(
            decoding: try regularFileData(
                url,
                label: "performance status"
            ),
            as: UTF8.self
        )
        guard text == "accepted\n" else {
            throw invalid(
                "native deposition performance status is not accepted"
            )
        }
        return .passed
    }

    private static func recursiveRegularFilePaths(
        root: URL,
        suffix: String
    ) throws -> Set<String> {
        try requireDirectory(root, label: root.lastPathComponent)
        let canonicalRoot = root.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            throw invalid("cannot enumerate \(root.path)")
        }
        var paths = Set<String>()
        for case let url as URL in enumerator
        where url.lastPathComponent.hasSuffix(suffix) {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true
            else {
                throw invalid(
                    "evidence path is nonregular or a symlink: \(url.path)"
                )
            }
            let basePaths = Set([
                root.path,
                canonicalRoot.path,
                "/private\(root.path)",
            ])
            guard let basePath = basePaths.first(where: {
                url.path.hasPrefix($0 + "/")
            }) else {
                throw invalid(
                    "enumerated evidence escaped its artifact root"
                )
            }
            paths.insert(String(url.path.dropFirst(basePath.count + 1)))
        }
        return paths
    }

    private static func entryNames(_ url: URL) throws -> Set<String> {
        try requireDirectory(url, label: url.lastPathComponent)
        return Set(
            try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ).map(\.lastPathComponent)
        )
    }

    private static func requireDirectory(
        _ url: URL,
        label: String
    ) throws {
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw invalid(
                "\(label) is missing, not a directory, or a symlink"
            )
        }
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
                throw invalid(
                    "\(label) is missing, nonregular, or a symlink"
                )
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard allowEmpty || !data.isEmpty else {
                throw invalid("\(label) is empty")
            }
            return data
        } catch let error as BrushFoundationEvidenceValidationError {
            throw error
        } catch {
            throw invalid(
                "\(label) cannot be read: \(error.localizedDescription)"
            )
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
            throw invalid(
                "\(label) has missing or unexpected top-level keys"
            )
        }
    }

    private static func isCommit(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func invalid(
        _ message: String
    ) -> BrushFoundationEvidenceValidationError {
        .invalid(message)
    }
}
