import CryptoKit
import Foundation
@testable import MetalRenderer
@testable import MetalRendererDiagnostics
import PatternEngine
import Testing

@Test
func checkedInFoundationRasterBaselineMatchesPreTaskSixBytes() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = repositoryRoot.appendingPathComponent(
        "App/PatternSpike/Harness/Baselines/brush-foundation-v1.json"
    )
    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    let baseline = try JSONDecoder().decode(
        BrushCharacterizationBaseline.self,
        from: data
    )

    #expect(digest ==
        "1f2dd91d3b2de7147fa7043980d7cc1fc22412e33e19d4eb8e04a1ff691da5c8")
    #expect(baseline.records.count == 8)
}

@Test
func baselineRejectsDuplicateSceneAndMalformedDigest() throws {
    let logical = BrushCharacterizationRecord(
        schemaVersion: 1,
        traceName: "ink",
        recipeID: "anchor.ink",
        nominalDiameter: 24,
        seed: 42,
        sampleCount: 3,
        logicalDabCount: 8,
        logicalDabDigest: "0123456789abcdef"
    )
    let valid = try BrushCharacterizationEvidence.validated(
        schemaVersion: 1,
        sceneName: "ink",
        logical: logical,
        canonicalWidth: 64,
        canonicalHeight: 64,
        canonicalBGRA8Digest: "fedcba9876543210",
        resolvedShapeIdentity: "builtin.shape.hard-round",
        resolvedGrainIdentity: "builtin.grain.opaque"
    )

    #expect(throws: BrushCharacterizationEvidenceError.self) {
        try BrushCharacterizationBaseline.validated(
            schemaVersion: 1,
            records: [valid, valid]
        )
    }
    #expect(throws: BrushCharacterizationEvidenceError.self) {
        try BrushCharacterizationEvidence.validated(
            schemaVersion: 1,
            sceneName: "ink",
            logical: logical,
            canonicalWidth: 64,
            canonicalHeight: 64,
            canonicalBGRA8Digest: "not-a-digest",
            resolvedShapeIdentity: "builtin.shape.hard-round",
            resolvedGrainIdentity: "builtin.grain.opaque"
        )
    }
}

@Test
func canonicalDigestIsStableAndSensitiveToPixelsAndDimensions() {
    let pixels: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
    let digest = BrushCharacterizationEvidence.canonicalBGRA8Digest(
        width: 2,
        height: 1,
        bytes: pixels
    )

    #expect(digest == "eb3621847e4d378d")
    #expect(digest != BrushCharacterizationEvidence.canonicalBGRA8Digest(
        width: 1,
        height: 2,
        bytes: pixels
    ))
    #expect(digest != BrushCharacterizationEvidence.canonicalBGRA8Digest(
        width: 2,
        height: 1,
        bytes: [0, 1, 2, 3, 4, 5, 6, 8]
    ))
}

@Test
func baselineRequiresSortedUniqueRecordsAndDetectsDigestMismatch() throws {
    let logical = BrushCharacterizationRecord(
        schemaVersion: 1,
        traceName: "ink",
        recipeID: "anchor.ink",
        nominalDiameter: 24,
        seed: 42,
        sampleCount: 3,
        logicalDabCount: 8,
        logicalDabDigest: "0123456789abcdef"
    )
    let alpha = try BrushCharacterizationEvidence.validated(
        schemaVersion: 1,
        sceneName: "alpha",
        logical: logical,
        canonicalWidth: 1,
        canonicalHeight: 1,
        canonicalBGRA8Digest: "0123456789abcdef",
        resolvedShapeIdentity: "shape",
        resolvedGrainIdentity: "grain"
    )
    let beta = try BrushCharacterizationEvidence.validated(
        schemaVersion: 1,
        sceneName: "beta",
        logical: logical,
        canonicalWidth: 1,
        canonicalHeight: 1,
        canonicalBGRA8Digest: "fedcba9876543210",
        resolvedShapeIdentity: "shape",
        resolvedGrainIdentity: "grain"
    )
    #expect(throws: BrushCharacterizationEvidenceError.self) {
        try BrushCharacterizationBaseline.validated(
            schemaVersion: 1,
            records: [beta, alpha]
        )
    }

    let baseline = try BrushCharacterizationBaseline.validated(
        schemaVersion: 1,
        records: [alpha, beta]
    )
    #expect(throws: BrushCharacterizationEvidenceError.digestMismatch) {
        try baseline.requireMatches([alpha, try BrushCharacterizationEvidence.validated(
            schemaVersion: 1,
            sceneName: "beta",
            logical: logical,
            canonicalWidth: 1,
            canonicalHeight: 1,
            canonicalBGRA8Digest: "0000000000000000",
            resolvedShapeIdentity: "shape",
            resolvedGrainIdentity: "grain"
        )])
    }
}

@Test
func baselineWriterCreatesItsOutputDirectoryAtomically() throws {
    let logical = BrushCharacterizationRecord(
        schemaVersion: 1,
        traceName: "ink",
        recipeID: "anchor.ink",
        nominalDiameter: 24,
        seed: 42,
        sampleCount: 3,
        logicalDabCount: 8,
        logicalDabDigest: "0123456789abcdef"
    )
    let record = try BrushCharacterizationEvidence.validated(
        schemaVersion: 1,
        sceneName: "alpha",
        logical: logical,
        canonicalWidth: 1,
        canonicalHeight: 1,
        canonicalBGRA8Digest: "fedcba9876543210",
        resolvedShapeIdentity: "shape",
        resolvedGrainIdentity: "grain"
    )
    let baseline = try BrushCharacterizationBaseline.validated(
        schemaVersion: 1,
        records: [record]
    )
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "brush-baseline-writer-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("nested/brush.json")

    try baseline.writeAtomically(to: output)

    #expect(FileManager.default.fileExists(atPath: output.path))
}

@Test
func rendererBaselineMergeFindsAndSortsOneRecordForEveryDepositionScene() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "brush-baseline-merge-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let encoder = JSONEncoder()
    for (index, scene) in DepositionEvidenceValidator.sceneNames.enumerated() {
        let logical = BrushCharacterizationRecord(
            schemaVersion: 1,
            traceName: scene,
            recipeID: "anchor.test",
            nominalDiameter: 24,
            seed: UInt64(index + 1),
            sampleCount: 3,
            logicalDabCount: 8,
            logicalDabDigest: String(format: "%016x", index + 1)
        )
        let evidence = try BrushCharacterizationEvidence.validated(
            schemaVersion: 1,
            sceneName: scene,
            logical: logical,
            canonicalWidth: 1,
            canonicalHeight: 1,
            canonicalBGRA8Digest: String(format: "%016x", index + 9),
            resolvedShapeIdentity: "shape",
            resolvedGrainIdentity: "grain"
        )
        let url = root
            .appendingPathComponent("nested/\(index)")
            .appendingPathComponent("\(scene).brush-characterization.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(evidence).write(to: url)
    }

    let merged = try BrushCharacterizationBaseline.merge(inputRoot: root)

    #expect(merged.records.map(\.sceneName)
        == DepositionEvidenceValidator.sceneNames.sorted())
}
