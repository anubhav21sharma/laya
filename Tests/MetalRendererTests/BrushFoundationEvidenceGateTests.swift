import Foundation
@testable import MetalRenderer
import Testing

@Test
func foundationGateUsesTheExactNativeDepositionSceneSet() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sceneRoot = root.appendingPathComponent(
        "App/PatternSpike/Harness/Scenes"
    )

    let scenes = try DepositionEvidenceValidator.loadScenes(from: sceneRoot)
    try DepositionEvidenceValidator.validateSceneSet(scenes)

    #expect(scenes.map(\.name) == DepositionEvidenceValidator.sceneNames)
    #expect(scenes.allSatisfy { $0.schemaVersion == 6 })
}

@Test
func foundationGateRejectsAnIncompleteNativeDepositionSceneSet() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sceneRoot = root.appendingPathComponent(
        "App/PatternSpike/Harness/Scenes"
    )
    var scenes = try DepositionEvidenceValidator.loadScenes(from: sceneRoot)
    scenes.removeLast()

    #expect(
        throws: DepositionEvidenceValidationError.sceneSetMismatch
    ) {
        try DepositionEvidenceValidator.validateSceneSet(scenes)
    }
}

@Test
func compilerCounterEvidenceRejectsInputPathCompilerWork() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "native-foundation-counter-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let commit = String(repeating: "a", count: 40)
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
    let invalidInputWork = BrushCompilerCounterSnapshot(
        packageDecodeCount: 3,
        imageDecodeCount: 0,
        textureUploadCount: 1,
        cacheHitCount: 1,
        activationCount: 2
    )
    let evidence = BrushCompilerCounterEvidence(
        commit: commit,
        gpuName: "Test GPU",
        activeDefinitionID: BrushFoundationCompilerProbe.definitionID,
        residentByteCount: 4_096,
        logicalDabEvaluationCount:
            BrushFoundationCompilerProbe.logicalDabEvaluationCount,
        beforeCompile: zero,
        afterFirstCompile: first,
        afterCacheHit: hit,
        afterLogicalDabs: invalidInputWork
    )
    let url = root.appendingPathComponent("compiler-counters.json")
    try JSONEncoder().encode(evidence).write(to: url)

    #expect(throws: Error.self) {
        try BrushFoundationEvidenceValidator.validateCompilerEvidence(
            at: url,
            expectedCommit: commit,
            expectedGPUName: nil
        )
    }
}
