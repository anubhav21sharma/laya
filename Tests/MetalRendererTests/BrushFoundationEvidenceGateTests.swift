import Foundation
@testable import MetalRenderer
import Testing

@Test
func foundationGateUsesTheExactNativeDepositionSceneSet() throws {
    let scenes = try DepositionEvidenceValidator.loadScenes(
        from: depositionSceneSourceRoot()
    )
    try DepositionEvidenceValidator.validateSceneSet(scenes)

    #expect(scenes.map(\.name) == DepositionEvidenceValidator.sceneNames)
    #expect(scenes.allSatisfy { $0.schemaVersion == 6 })
}

@Test
func foundationGateAcceptsOnlyCompleteNativeEvidence() throws {
    let fixture = try FoundationFixture()
    defer { fixture.remove() }

    #expect(
        try BrushFoundationEvidenceValidator.validate(
            artifactRoot: fixture.root,
            expectedCommit: fixture.commit
        ) == .passed
    )
}

@Test
func foundationGateRejectsMissingOrMisplacedEvidenceDiscovery() throws {
    let fixture = try FoundationFixture()
    defer { fixture.remove() }
    let scene = try #require(
        DepositionEvidenceValidator.positiveSceneNames.first
    )
    let evidence = fixture.positiveRoot
        .appendingPathComponent(scene)
        .appendingPathComponent("\(scene).deposition-evidence.json")
    try FileManager.default.moveItem(
        at: evidence,
        to: fixture.positiveRoot
            .appendingPathComponent(scene)
            .appendingPathComponent("wrong.deposition-evidence.json")
    )

    #expect(throws: Error.self) {
        try BrushFoundationEvidenceValidator.validate(
            artifactRoot: fixture.root,
            expectedCommit: fixture.commit
        )
    }
}

@Test
func foundationGateRejectsExtraActiveSceneDirectory() throws {
    let fixture = try FoundationFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
        at: fixture.positiveRoot.appendingPathComponent("retired-slice4"),
        withIntermediateDirectories: false
    )

    #expect(throws: Error.self) {
        try BrushFoundationEvidenceValidator.validate(
            artifactRoot: fixture.root,
            expectedCommit: fixture.commit
        )
    }
}

@Test
func foundationGateRejectsBenchmarkGPUDrift() throws {
    let fixture = try FoundationFixture()
    defer { fixture.remove() }
    let scene = try #require(
        DepositionEvidenceValidator.positiveSceneNames.first
    )
    try fixture.writeBenchmark(scene: scene, gpuName: "Other GPU")

    #expect(throws: Error.self) {
        try BrushFoundationEvidenceValidator.validate(
            artifactRoot: fixture.root,
            expectedCommit: fixture.commit
        )
    }
}

@Test
func foundationGateRejectsFalsePositiveInvariant() throws {
    let fixture = try FoundationFixture()
    defer { fixture.remove() }
    let scene = try #require(
        DepositionEvidenceValidator.positiveSceneNames.first
    )
    var invariantResults = try fixture.invariantExpectations(scene: scene)
    invariantResults["familyAndAccumulationCorrect"] = false
    try fixture.writeEvidence(
        scene: scene,
        invariantResults: invariantResults
    )

    #expect(throws: Error.self) {
        try BrushFoundationEvidenceValidator.validate(
            artifactRoot: fixture.root,
            expectedCommit: fixture.commit
        )
    }
}

@Test
func foundationGateRejectsBenchmarkThatDoesNotBindToEvidence() throws {
    let fixture = try FoundationFixture()
    defer { fixture.remove() }
    let scene = try #require(
        DepositionEvidenceValidator.positiveSceneNames.first
    )
    try fixture.writeBenchmark(
        scene: scene,
        gpuName: fixture.gpuName,
        program: "legacyRenderer"
    )

    #expect(throws: Error.self) {
        try BrushFoundationEvidenceValidator.validate(
            artifactRoot: fixture.root,
            expectedCommit: fixture.commit
        )
    }
}

@Test
func compilerCounterEvidenceRejectsEmptyOrMismatchedBenchmarkGPU()
    throws
{
    let fixture = try FoundationFixture()
    defer { fixture.remove() }
    let url = fixture.root.appendingPathComponent(
        BrushFoundationEvidenceValidator.compilerFileName
    )

    #expect(throws: Error.self) {
        try BrushFoundationEvidenceValidator.validateCompilerEvidence(
            at: url,
            expectedCommit: fixture.commit,
            expectedGPUName: ""
        )
    }
    #expect(throws: Error.self) {
        try BrushFoundationEvidenceValidator.validateCompilerEvidence(
            at: url,
            expectedCommit: fixture.commit,
            expectedGPUName: "Other GPU"
        )
    }
}

private struct FoundationFixture {
    let root: URL
    let commit = String(repeating: "a", count: 40)
    let gpuName = "Fixture GPU"

    var positiveRoot: URL {
        root.appendingPathComponent("positive")
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "native-foundation-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try writeSceneInputs()
        try writePositiveEvidence()
        try writeNegativeControls()
        try writeCompilerEvidence()
        try Data("accepted\n".utf8).write(
            to: root.appendingPathComponent(
                BrushFoundationEvidenceValidator.performanceFileName
            )
        )
        try writeProvenance()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeBenchmark(
        scene: String,
        gpuName: String,
        program: String = "nativeDeposition"
    ) throws {
        let record = BenchmarkRecord(
            schemaVersion: 3,
            timestampUTC: "2026-07-29T00:00:00Z",
            sceneName: scene,
            hardware: BenchmarkHardware(
                gpuName: gpuName,
                logicalProcessorCount: 8,
                physicalMemoryBytes: 16 * 1_024 * 1_024
            ),
            operatingSystem: "Fixture OS",
            build: BenchmarkBuild(
                configuration: "Debug",
                gitCommit: commit
            ),
            frameCount: 1,
            cpuEncodeMilliseconds: [1],
            gpuMilliseconds: [1],
            peakResidentBytes: 0,
            newInstanceCounts: [1],
            totalProjectedFragmentCount: 1,
            totalInstanceBytes:
                ShaderABI.depositionStampInstanceStride,
            previewCommitViolationCount: 0,
            recipeID: "fixture.definition",
            seed: 1,
            assetResidentBytes: 0,
            logicalDabDigest: String(repeating: "e", count: 64),
            canonicalBGRA8Digest: String(repeating: "e", count: 64),
            logicalDabCount: 1,
            program: program
        )
        try BenchmarkRecord.encode(record).write(
            to: positiveRoot
                .appendingPathComponent(scene)
                .appendingPathComponent("\(scene).benchmark.json")
        )
    }

    func writeEvidence(
        scene: String,
        invariantResults: [String: Bool]
    ) throws {
        let evidence = DepositionSceneEvidence(
            schemaVersion: DepositionSceneEvidence.currentSchemaVersion,
            scene: scene,
            definitionID: "fixture.definition",
            semanticHash: String(repeating: "d", count: 64),
            pipelineKey: "fixture.pipeline",
            abiVersion: DepositionABI.version,
            resourceBytes: 0,
            textureLevels: [:],
            logicalDabCount: 1,
            projectedInstanceCount: 1,
            canonicalSHA256: String(repeating: "e", count: 64),
            cpuReferenceSHA256: nil,
            maximumCPUGPUChannelDelta: nil,
            previewCommitMaximumChannelDelta: 0,
            telemetry: .zero,
            invariantResults: invariantResults
        )
        try evidence.encoded().write(
            to: positiveRoot
                .appendingPathComponent(scene)
                .appendingPathComponent(
                    "\(scene).deposition-evidence.json"
                )
        )
    }

    func invariantExpectations(
        scene: String
    ) throws -> [String: Bool] {
        try HarnessScene.decode(
            Data(
                contentsOf: depositionSceneSourceRoot()
                    .appendingPathComponent("\(scene).json")
            )
        ).depositionInvariantExpectations
    }

    private func writeSceneInputs() throws {
        let destination = root.appendingPathComponent(
            BrushFoundationEvidenceValidator.sceneDirectoryName
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        for name in DepositionEvidenceValidator.sceneNames {
            try FileManager.default.copyItem(
                at: depositionSceneSourceRoot()
                    .appendingPathComponent("\(name).json"),
                to: destination.appendingPathComponent("\(name).json")
            )
        }
    }

    private func writePositiveEvidence() throws {
        try FileManager.default.createDirectory(
            at: positiveRoot,
            withIntermediateDirectories: false
        )
        for name in DepositionEvidenceValidator.positiveSceneNames {
            let directory = positiveRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            try writeEvidence(
                scene: name,
                invariantResults: try invariantExpectations(scene: name)
            )
            try writeBenchmark(scene: name, gpuName: gpuName)
        }
    }

    private func writeNegativeControls() throws {
        let negativeRoot = root.appendingPathComponent("negative-control")
        try FileManager.default.createDirectory(
            at: negativeRoot,
            withIntermediateDirectories: false
        )
        for name in DepositionEvidenceValidator.positiveSceneNames {
            let directory = negativeRoot.appendingPathComponent(name)
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

    private func writeCompilerEvidence() throws {
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
        let evidence = BrushCompilerCounterEvidence(
            commit: commit,
            gpuName: gpuName,
            activeDefinitionID: BrushFoundationCompilerProbe.definitionID,
            residentByteCount: 4_096,
            logicalDabEvaluationCount:
                BrushFoundationCompilerProbe.logicalDabEvaluationCount,
            beforeCompile: zero,
            afterFirstCompile: first,
            afterCacheHit: hit,
            afterLogicalDabs: hit
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(
            to: root.appendingPathComponent(
                BrushFoundationEvidenceValidator.compilerFileName
            )
        )
    }

    private func writeProvenance() throws {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "commit": commit,
            "configuration": "Debug",
            "operatingSystem": "Fixture OS",
            "hardwareMachine": "arm64",
            "hardwareModel": "Fixture Mac",
            "gpuName": gpuName,
            "artifactRoot": root.standardizedFileURL.path,
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(
            to: root.appendingPathComponent(
                BrushFoundationEvidenceValidator.provenanceFileName
            )
        )
    }
}

private func depositionSceneSourceRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")
}
