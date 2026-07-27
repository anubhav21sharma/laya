import Foundation
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Brush foundation evidence gate", .serialized)
struct BrushFoundationEvidenceGateTests {
    @Test
    func validMatrixPasses() throws {
        let fixture = try FoundationGateFixture()
        defer { fixture.remove() }

        #expect(try fixture.validate() == .passed)
    }

    @Test
    func missingAndChangedLogicalBaselineFailIndependently() throws {
        do {
            let fixture = try FoundationGateFixture()
            defer { fixture.remove() }
            try FileManager.default.removeItem(at: fixture.actualLogicalURL)
            try fixture.expectFailure()
        }
        do {
            let fixture = try FoundationGateFixture()
            defer { fixture.remove() }
            try fixture.mutateJSON(at: fixture.actualLogicalURL) { object in
                var records = try #require(object["records"] as? [[String: Any]])
                records.removeLast()
                object["records"] = records
            }
            try fixture.expectFailure()
        }
    }

    @Test
    func missingCharacterizationFails() throws {
        let fixture = try FoundationGateFixture()
        defer { fixture.remove() }
        let name = try #require(SliceFourEvidenceValidator.sceneNames.first)
        try FileManager.default.removeItem(
            at: fixture.characterizationURL(scene: name)
        )

        try fixture.expectFailure()
    }

    @Test
    func wrongCommitFails() throws {
        let fixture = try FoundationGateFixture()
        defer { fixture.remove() }
        try fixture.mutateJSON(at: fixture.compilerEvidenceURL) { object in
            object["commit"] = String(repeating: "b", count: 40)
        }

        try fixture.expectFailure()
    }

    @Test
    func changedLogicalDigestFails() throws {
        let fixture = try FoundationGateFixture()
        defer { fixture.remove() }
        let name = try #require(SliceFourEvidenceValidator.sceneNames.first)
        try fixture.mutateJSON(at: fixture.characterizationURL(scene: name)) {
            object in
            var logical = try #require(object["logical"] as? [String: Any])
            logical["logicalDabDigest"] = "0000000000000000"
            object["logical"] = logical
        }

        try fixture.expectFailure()
    }

    @Test
    func changedCanonicalDigestFails() throws {
        let fixture = try FoundationGateFixture()
        defer { fixture.remove() }
        let name = try #require(SliceFourEvidenceValidator.sceneNames.first)
        try fixture.mutateJSON(at: fixture.characterizationURL(scene: name)) {
            object in
            object["canonicalBGRA8Digest"] = "0000000000000000"
        }

        try fixture.expectFailure()
    }

    @Test
    func missingCompilerCounterFails() throws {
        let fixture = try FoundationGateFixture()
        defer { fixture.remove() }
        try fixture.mutateJSON(at: fixture.compilerEvidenceURL) { object in
            var counters = try #require(
                object["afterCacheHit"] as? [String: Any]
            )
            counters.removeValue(forKey: "cacheHitCount")
            object["afterCacheHit"] = counters
        }

        try fixture.expectFailure()
    }

    @Test
    func positiveSceneMissingFails() throws {
        let fixture = try FoundationGateFixture()
        defer { fixture.remove() }
        let name = try #require(SliceFourEvidenceValidator.sceneNames.first)
        try FileManager.default.removeItem(
            at: fixture.positiveRoot.appendingPathComponent(name)
        )

        try fixture.expectFailure()
    }

    @Test
    func negativeControlUnexpectedlySucceedingFails() throws {
        let fixture = try FoundationGateFixture()
        defer { fixture.remove() }
        let name = try #require(SliceFourEvidenceValidator.sceneNames.first)
        try Data("0\n".utf8).write(
            to: fixture.negativeRoot.appendingPathComponent(name)
                .appendingPathComponent("exit-status.txt")
        )

        try fixture.expectFailure()
    }

    @Test
    func unrecognizedPerformancePendingTextFails() throws {
        let fixture = try FoundationGateFixture()
        defer { fixture.remove() }
        try Data("performance maybe pending\n".utf8).write(
            to: fixture.performanceStatusURL
        )

        try fixture.expectFailure()
    }

    @Test
    func onlyParavirtualGPUCanBePerformancePending() throws {
        let fixture = try FoundationGateFixture()
        defer { fixture.remove() }
        fixture.sliceFourStatus = .performancePending(gpuName: "Virtual GPU")
        try Data(
            "SLICE3 PERFORMANCE PENDING: unstable real-Metal timing environment 'Virtual GPU'.\n"
                .utf8
        ).write(to: fixture.performanceStatusURL)

        try fixture.expectFailure()
    }

    @Test
    @MainActor
    func realCompilerProbeSatisfiesTheProductionCounterContract() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "brush-compiler-evidence-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: output) }
        let evidence = try await BrushFoundationCompilerProbe.capture(
            commit: FoundationGateFixture.commit
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: output)

        try BrushFoundationEvidenceValidator.validateCompilerEvidence(
            at: output,
            expectedCommit: FoundationGateFixture.commit,
            expectedGPUName: evidence.gpuName
        )
    }
}

private final class FoundationGateFixture {
    static let commit = String(repeating: "a", count: 40)

    let root: URL
    let positiveRoot: URL
    let negativeRoot: URL
    let sceneRoot: URL
    let actualLogicalURL: URL
    let compilerEvidenceURL: URL
    let performanceStatusURL: URL
    let logicalBaselineURL: URL
    let rendererBaselineURL: URL
    var sliceFourStatus: SliceFourEvidenceValidationStatus = .passed

    init() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        logicalBaselineURL = repository.appendingPathComponent(
            "Tests/EditorCoreTests/Fixtures/brush-logical-v1.json"
        )
        rendererBaselineURL = repository.appendingPathComponent(
            "App/PatternSpike/Harness/Baselines/brush-foundation-v1.json"
        )
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "brush-foundation-gate-\(UUID().uuidString)"
        )
        positiveRoot = root.appendingPathComponent("positive")
        negativeRoot = root.appendingPathComponent("negative-control")
        sceneRoot = root.appendingPathComponent(
            BrushFoundationEvidenceValidator.sceneDirectoryName
        )
        actualLogicalURL = root.appendingPathComponent("brush-logical-v1.json")
        compilerEvidenceURL = root.appendingPathComponent(
            "compiler-counters.json"
        )
        performanceStatusURL = root.appendingPathComponent(
            "performance-status.txt"
        )

        try FileManager.default.createDirectory(
            at: positiveRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: negativeRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sceneRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: logicalBaselineURL,
            to: actualLogicalURL
        )
        for name in SliceFourEvidenceValidator.sceneNames {
            for suffix in [".json", "-negative-control.json"] {
                try FileManager.default.copyItem(
                    at: repository.appendingPathComponent(
                        "App/PatternSpike/Harness/Scenes/\(name)\(suffix)"
                    ),
                    to: sceneRoot.appendingPathComponent("\(name)\(suffix)")
                )
            }
        }

        let logical = try JSONDecoder().decode(
            BrushLogicalBaseline.self,
            from: Data(contentsOf: logicalBaselineURL)
        )
        let parity = BrushAnchorAdapterParityEvidence(
            commit: Self.commit,
            records: logical.records.map {
                BrushAnchorAdapterParityRecord(
                    recipeID: $0.recipeID,
                    traceName: $0.traceName,
                    programLogicalDabCount: $0.logicalDabCount,
                    compatibilityLogicalDabCount: $0.logicalDabCount,
                    programLogicalDabDigest: $0.logicalDabDigest,
                    compatibilityLogicalDabDigest: $0.logicalDabDigest
                )
            }
        )
        let evidenceEncoder = JSONEncoder()
        evidenceEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try evidenceEncoder.encode(parity).write(
            to: root.appendingPathComponent(
                BrushFoundationEvidenceValidator.parityFileName
            )
        )

        let baseline = try JSONDecoder().decode(
            BrushCharacterizationBaseline.self,
            from: Data(contentsOf: rendererBaselineURL)
        )
        let records = Dictionary(
            uniqueKeysWithValues: baseline.records.map { ($0.sceneName, $0) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for name in SliceFourEvidenceValidator.sceneNames {
            let positive = positiveRoot.appendingPathComponent(name)
            let negative = negativeRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: positive,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: negative,
                withIntermediateDirectories: true
            )
            try encoder.encode(try #require(records[name])).write(
                to: characterizationURL(scene: name)
            )
            try JSONSerialization.data(
                withJSONObject: [
                    "hardware": ["gpuName": "Fixture GPU"],
                ],
                options: [.sortedKeys]
            ).write(
                to: positive.appendingPathComponent(
                    "\(name).benchmark.json"
                )
            )
            try Data().write(to: negative.appendingPathComponent("stdout.log"))
            try Data("HARNESS FAIL expected negative control\n".utf8).write(
                to: negative.appendingPathComponent("stderr.log")
            )
            try Data("1\n".utf8).write(
                to: negative.appendingPathComponent("exit-status.txt")
            )
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
        try evidenceEncoder.encode(
            BrushCompilerCounterEvidence(
                commit: Self.commit,
                gpuName: "Fixture GPU",
                activeDefinitionID: BrushFoundationCompilerProbe.definitionID,
                residentByteCount: 21,
                logicalDabEvaluationCount:
                    BrushFoundationCompilerProbe.logicalDabEvaluationCount,
                beforeCompile: zero,
                afterFirstCompile: first,
                afterCacheHit: hit,
                afterLogicalDabs: hit
            )
        ).write(to: compilerEvidenceURL)
        try Data("accepted\n".utf8).write(to: performanceStatusURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func characterizationURL(scene: String) -> URL {
        positiveRoot.appendingPathComponent(scene)
            .appendingPathComponent("\(scene).brush-characterization.json")
    }

    func validate() throws -> BrushFoundationEvidenceValidationStatus {
        try BrushFoundationEvidenceValidator.validate(
            logicalBaselineURL: logicalBaselineURL,
            rendererBaselineURL: rendererBaselineURL,
            artifactRoot: root,
            expectedCommit: Self.commit,
            sliceFourValidator: { [self] _, _, _, _ in sliceFourStatus }
        )
    }

    func expectFailure() throws {
        #expect(throws: BrushFoundationEvidenceValidationError.self) {
            _ = try validate()
        }
    }

    func mutateJSON(
        at url: URL,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        try mutation(&object)
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: url)
    }
}
