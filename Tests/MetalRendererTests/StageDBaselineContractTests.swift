import CryptoKit
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Stage D baseline renderer contracts", .serialized)
struct StageDBaselineContractTests {
    @Test
    func legacyProductionPaintAllocationsRemainEnumeratedUntilTaskSix() throws {
        #expect(
            try stageDBaselinePaintAllocations() == [
                StageDPaintAllocation(
                    file: "Sources/MetalRenderer/CanonicalRaster.swift",
                    type: "CanonicalRaster",
                    bindings: ["front", "scratch"]
                ),
                StageDPaintAllocation(
                    file: "Sources/MetalRenderer/PersistentLiveTile.swift",
                    type: "PersistentLiveTile",
                    bindings: ["texture"]
                ),
                StageDPaintAllocation(
                    file: "Sources/MetalRenderer/Brush/ReplayLiveTile.swift",
                    type: "ReplayLiveTile",
                    bindings: ["texture"]
                ),
                StageDPaintAllocation(
                    file: "Sources/MetalRenderer/StrokeRuntime/StrokePrivateSurfaceEncoder.swift",
                    type: "StrokeMetalSurfaceResources",
                    bindings: ["authoritativeTexture", "predictionTexture"]
                ),
            ]
        )
    }

    @Test
    func tiledTestSeamContainsNoFullCanvasPaintAllocation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/MetalRenderer/StrokeRuntime/StrokeTileSurfaceResources.swift"
            ),
            encoding: .utf8
        )
        #expect(!source.contains("texture2DDescriptor"))
        #expect(source.contains("TiledRasterSurface"))
        #expect(source.contains("PaintTileStore"))
    }

    @Test
    func encodedImportFixturesHaveIndependentLinearReferences() {
        for fixture in stageDImportFixtures {
            #expect(fixture.encodedBGRA8.count == 4)
            #expect(fixture.linearReference.count == 4)
            let actual = stageDDecodeEncodedBGRA8(fixture.encodedBGRA8)
            for (actual, expected) in zip(
                actual,
                fixture.linearReference
            ) {
                #expect(
                    abs(actual - expected) < 1e-9,
                    Comment(rawValue: fixture.name)
                )
            }
        }
    }

    @Test
    @MainActor
    func drySceneSemanticAndCanonicalHashesAreFrozen() async throws {
        for scene in stageDDryScenes {
            let actual = try await stageDDrySceneSnapshot(scene.kind)
            #expect(actual.semanticSHA256 == scene.semanticSHA256)
            #expect(actual.canonicalBGRA8SHA256 == scene.canonicalBGRA8SHA256)
        }
    }

    @Test
    @MainActor
    func stageCLifecycleInventoryHasOneNamedOwner() async throws {
        #expect(stageDLifecycleTransitions.count == 12)
        #expect(
            stageDLifecycleTransitions.map(\.name) == [
                "initialize-import-existing-snapshot",
                "begin",
                "append-actual-coalesced",
                "replace-prediction",
                "prepare-submit-display",
                "finish-commit",
                "cancel-failure",
                "clear",
                "undo-redo",
                "stage-c-stroke-ownership",
                "resize-mode-switch",
                "export-committed-snapshot",
            ]
        )
        for transition in stageDLifecycleTransitions {
            try await transition.exercise()
        }
    }
}

private struct StageDPaintAllocation: Equatable {
    let file: String
    let type: String
    let bindings: [String]
}

private func stageDBaselinePaintAllocations() throws -> [StageDPaintAllocation] {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try [
        ("Sources/MetalRenderer/CanonicalRaster.swift", "CanonicalRaster", ["front", "scratch"]),
        ("Sources/MetalRenderer/PersistentLiveTile.swift", "PersistentLiveTile", ["texture"]),
        ("Sources/MetalRenderer/Brush/ReplayLiveTile.swift", "ReplayLiveTile", ["texture"]),
        ("Sources/MetalRenderer/StrokeRuntime/StrokePrivateSurfaceEncoder.swift", "StrokeMetalSurfaceResources", ["authoritativeTexture", "predictionTexture"]),
    ].map { file, type, bindings in
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(file),
            encoding: .utf8
        )
        let descriptor = try #require(
            source.range(of: "let descriptor = MTLTextureDescriptor")
        )
        let allocation = source[descriptor.lowerBound...]
        #expect(allocation.contains("pixelFormat: .bgra8Unorm"))
        let actualBindings = allocation.matches(
            of: /let\s+([A-Za-z]+)\s*=\s*device\.makeTexture\([\s\S]{0,80}?descriptor:\s*descriptor/
        ).map { String($0.1) }
        #expect(actualBindings == bindings, Comment(rawValue: type))
        return StageDPaintAllocation(
            file: file,
            type: type,
            bindings: actualBindings
        )
    }
}

private struct StageDEncodedImportFixture: Sendable {
    let name: String
    let encodedBGRA8: [UInt8]
    /// Hand-derived from IEC 61966-2-1 decode; alpha is never gamma encoded.
    let linearReference: [Double]
}

private let stageDImportFixtures: [StageDEncodedImportFixture] = [
    StageDEncodedImportFixture(
        name: "empty",
        encodedBGRA8: [0, 0, 0, 0],
        linearReference: [0, 0, 0, 0]
    ),
    StageDEncodedImportFixture(
        name: "translucent",
        encodedBGRA8: [32, 64, 128, 128],
        linearReference: [0.014443843596, 0.051269458374, 0.215860500114, 128.0 / 255.0]
    ),
    StageDEncodedImportFixture(
        name: "low-flow-repeated-buildup",
        encodedBGRA8: [16, 32, 64, 96],
        linearReference: [0.005181516702, 0.014443843596, 0.051269458374, 96.0 / 255.0]
    ),
    StageDEncodedImportFixture(
        name: "erase",
        encodedBGRA8: [24, 48, 96, 160],
        linearReference: [0.009134058702, 0.029556834438, 0.116970667759, 160.0 / 255.0]
    ),
    StageDEncodedImportFixture(
        name: "periodic-seam",
        encodedBGRA8: [255, 0, 255, 255],
        linearReference: [1, 0, 1, 1]
    ),
    StageDEncodedImportFixture(
        name: "radial-pages",
        encodedBGRA8: [12, 180, 240, 224],
        linearReference: [0.003676507324, 0.456411023180, 0.871367119199, 224.0 / 255.0]
    ),
]

private struct StageDDryScene: Sendable {
    let name: String
    let kind: StageDDrySceneKind
    let semanticSHA256: String
    let canonicalBGRA8SHA256: String
}

private let stageDDryScenes: [StageDDryScene] = [
    StageDDryScene(
        name: "empty",
        kind: .empty,
        semanticSHA256: "084d319ba809dda6fe4d8908ddb68223abe2bbebf42c623e6fb2afb38bb24c8a",
        canonicalBGRA8SHA256: "4fe7b59af6de3b665b67788cc2f99892ab827efae3a467342b3bb4e3bc8e5bfe"
    ),
    StageDDryScene(
        name: "periodic-seam",
        kind: .periodicSeam,
        semanticSHA256: "db1f959a9d367913219060804edb5d889218a8f1a6d6d657942c811d7a361771",
        canonicalBGRA8SHA256: "a979a116f0c38c99b2e3f0eeef20071d72019ceb360c5ee25c79a17bbc38421c"
    ),
    StageDDryScene(
        name: "radial-pages",
        kind: .radialPages,
        semanticSHA256: "089f851f0e3a3a822a5efbff093be5f446c00f72860206c40799157b202742a9",
        canonicalBGRA8SHA256: "74ddefcc329ec4fde57d9c93c5241e34419afa49d1eebf1832ea095e7d142550"
    ),
]

private enum StageDDrySceneKind: Sendable {
    case empty
    case periodicSeam
    case radialPages
}

private struct StageDDrySceneSnapshot: Sendable {
    let semanticSHA256: String
    let canonicalBGRA8SHA256: String
}

@MainActor
private func stageDDrySceneSnapshot(
    _ kind: StageDDrySceneKind
) async throws -> StageDDrySceneSnapshot {
    let finite: FiniteSymmetryConfiguration?
    switch kind {
    case .empty, .periodicSeam:
        finite = nil
    case .radialPages:
        finite = .radial(RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 8,
            center: WorldPoint(x: 32, y: 32)
        ))
    }
    guard let setup = try makeDepositionRendererSetup(
        tiling: .grid,
        finite: finite
    ) else {
        throw StageDDrySceneError.metalUnavailable
    }
    let program = try stageCMetalTestProgram(
        id: "test.stage-d.dry.\(kind)",
        replayMode: .appendOnly
    )
    let brush = try await setup.compileBrush(definition: program.definition)
    try setup.renderer.activateDrawBrush(brush)
    if kind != .empty {
        let token = RendererOperationToken(rawValue: 130_000)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 4, y: 32),
            style: depositionStyle(brush, compositeMode: .draw, diameter: 8)
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 60, y: 32)
        )
        try setup.renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 4, y: 32),
            maximumRetainedBytes: 4_000_000
        )
        try await prepareOffMainCommit(setup.renderer)
        _ = try setup.renderer.finishCommitForHarness()
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
    }
    return StageDDrySceneSnapshot(
        semanticSHA256: brush.renderIdentity.semanticHash,
        canonicalBGRA8SHA256: stageDSHA256(Data(depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )))
    )
}

private enum StageDDrySceneError: Error { case metalUnavailable }

private func stageDDecodeEncodedBGRA8(_ encoded: [UInt8]) -> [Double] {
    encoded.enumerated().map { index, byte in
        let value = Double(byte) / 255
        if index == 3 { return value }
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }
}

private func stageDSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct StageDLifecycleTransition: Sendable {
    let name: String
    let exercise: @MainActor @Sendable () async throws -> Void
}

private let stageDLifecycleTransitions: [StageDLifecycleTransition] = [
    .init(name: "initialize-import-existing-snapshot", exercise: { try await stageDLifecycleProbe(.initializeImportSnapshotRestore) }),
    .init(name: "begin", exercise: { try await stageDLifecycleProbe(.begin) }),
    .init(name: "append-actual-coalesced", exercise: { try await stageDLifecycleProbe(.appendActual) }),
    .init(name: "replace-prediction", exercise: { try await stageDLifecycleProbe(.replacePrediction) }),
    .init(name: "prepare-submit-display", exercise: { try await stageDLifecycleProbe(.prepareSubmitDisplay) }),
    .init(name: "finish-commit", exercise: { try await stageDLifecycleProbe(.finishCommit) }),
    .init(name: "cancel-failure", exercise: { try await stageDLifecycleProbe(.cancelFailure) }),
    .init(name: "clear", exercise: { try await stageDLifecycleProbe(.clear) }),
    .init(name: "undo-redo", exercise: { try await stageDLifecycleProbe(.undoRedo) }),
    // Task 5 preserves the Stage C production owner; Task 6 switches it.
    .init(name: "stage-c-stroke-ownership", exercise: { try await stageDLifecycleProbe(.stageCStrokeOwnership) }),
    .init(name: "resize-mode-switch", exercise: { try await stageDLifecycleProbe(.resizeModeSwitch) }),
    .init(name: "export-committed-snapshot", exercise: { try await stageDLifecycleProbe(.exportCommittedSnapshot) }),
]

private enum StageDLifecycleKind: Sendable {
    case initializeImportSnapshotRestore, begin, appendActual, replacePrediction
    case prepareSubmitDisplay, finishCommit, cancelFailure, clear, undoRedo
    case stageCStrokeOwnership, resizeModeSwitch, exportCommittedSnapshot
}

@MainActor
private func stageDLifecycleProbe(_ kind: StageDLifecycleKind) async throws {
    guard let setup = try makeDepositionRendererSetup(tiling: .grid, finite: .plain) else {
        throw StageDDrySceneError.metalUnavailable
    }
    let program = try stageCMetalTestProgram(
        id: "test.stage-d.lifecycle.\(kind)", replayMode: .appendOnly
    )
    let brush = try await setup.compileBrush(definition: program.definition)
    try setup.renderer.activateDrawBrush(brush)
    let initial = depositionTextureBytes(try setup.renderer.copyCanonicalForHarness())
    #expect(!initial.contains { $0 != 0 })

    let token = RendererOperationToken(rawValue: 140_000)
    try setup.renderer.beginStroke(
        token: token,
        sample: depositionSample(.began, x: 8, y: 8),
        style: depositionStyle(brush, compositeMode: .draw, diameter: 8)
    )
    #expect(setup.renderer.hasActiveStroke)
    guard kind != .begin else { return }

    try setup.renderer.appendStroke(
        token: token,
        sample: depositionSample(.moved, x: 40, y: 24)
    )
    guard kind != .appendActual else { return }

    if kind == .stageCStrokeOwnership {
        #expect(setup.renderer.hasActiveStroke)
        try setup.renderer.cancelStroke(token: token)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == initial
        )
        return
    }

    if kind == .replacePrediction {
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 48)
        )
        try await drainOffMainPreparedFrames(setup.renderer, minimumFrameCount: 0)
        #expect(setup.renderer.hasActiveStroke)
        return
    }

    try setup.renderer.requestStrokeCommit(
        token: token,
        sample: depositionSample(.ended, x: 56, y: 32),
        maximumRetainedBytes: 4_000_000
    )
    try await prepareOffMainCommit(setup.renderer)
    if kind == .prepareSubmitDisplay {
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == initial
        )
        return
    }
    _ = try setup.renderer.finishCommitForHarness()
    try await awaitOffMainWorkspaceAvailable(setup.renderer)
    let committed = depositionTextureBytes(try setup.renderer.copyCanonicalForHarness())
    #expect(committed.contains { $0 != 0 })
    guard kind != .finishCommit else { return }

    switch kind {
    case .initializeImportSnapshotRestore:
        let snapshot = try setup.renderer.captureCommittedDocument()
        let restored = try GridRenderer(
            device: setup.device,
            library: setup.library,
            drawableSize: PatternSize(width: 64, height: 64),
            committedSnapshot: snapshot
        )
        #expect(restored.documentConfiguration == snapshot.documentConfiguration)
        #expect(
            depositionTextureBytes(
                try restored.copyCanonicalForHarness()
            ) == committed
        )
    case .cancelFailure:
        let cancel = RendererOperationToken(rawValue: 140_001)
        try setup.renderer.beginStroke(token: cancel, sample: depositionSample(.began), style: depositionStyle(brush, compositeMode: .draw, diameter: 8))
        try setup.renderer.cancelStroke(token: cancel)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(depositionTextureBytes(try setup.renderer.copyCanonicalForHarness()) == committed)
    case .clear:
        try setup.renderer.requestClearForHarness(token: RendererOperationToken(rawValue: 140_002), maximumRetainedBytes: 4_000_000, forceFailure: false)
        try setup.renderer.finishRasterOperationForHarness()
        #expect(!depositionTextureBytes(try setup.renderer.copyCanonicalForHarness()).contains { $0 != 0 })
    case .undoRedo:
        var receipt: RasterMutationReceipt?
        setup.renderer.onOperationCompleted = { completion in
            if case let .rasterSuccess(value) = completion { receipt = value }
        }
        defer { setup.renderer.onOperationCompleted = nil }
        try setup.renderer.requestClearForHarness(token: RendererOperationToken(rawValue: 140_002), maximumRetainedBytes: 4_000_000, forceFailure: false)
        try setup.renderer.finishRasterOperationForHarness()
        let clear = try #require(receipt)
        try setup.renderer.requestRasterRestoreForHarness(token: RendererOperationToken(rawValue: 140_003), revision: clear.before, forceFailure: false)
        try setup.renderer.finishRasterOperationForHarness()
        #expect(depositionTextureBytes(try setup.renderer.copyCanonicalForHarness()) == committed)
        try setup.renderer.requestRasterRestoreForHarness(token: RendererOperationToken(rawValue: 140_004), revision: clear.after, forceFailure: false)
        try setup.renderer.finishRasterOperationForHarness()
        #expect(!depositionTextureBytes(try setup.renderer.copyCanonicalForHarness()).contains { $0 != 0 })
        setup.renderer.releaseRasterRevisions([clear.before.id, clear.after.id])
    case .resizeModeSwitch:
        try setup.renderer.requestResizeForHarness(token: RendererOperationToken(rawValue: 140_003), to: PixelSize(width: 80, height: 72), maximumRetainedBytes: 4_000_000, forceResourceAllocationFailure: false)
        try setup.renderer.finishRasterOperationForHarness()
        #expect(setup.renderer.pixelSize == PixelSize(width: 80, height: 72))
        try setup.renderer.requestClearForHarness(token: RendererOperationToken(rawValue: 140_004), maximumRetainedBytes: 4_000_000, forceFailure: false)
        try setup.renderer.finishRasterOperationForHarness()
        #expect(!depositionTextureBytes(try setup.renderer.copyCanonicalForHarness()).contains { $0 != 0 })
        try setup.renderer.reconcileGeometryLock(documentIsEmpty: true)
        let periodic = SymmetryDocumentConfiguration.periodic(
            .legacy(
                presetID: .grid,
                tileSize: PatternSize(width: 80, height: 72)
            )
        )
        try setup.renderer.replaceEmptyDocumentConfiguration(
            periodic,
            pixelSize: PixelSize(width: 80, height: 72)
        )
        #expect(setup.renderer.documentConfiguration == periodic)
    case .exportCommittedSnapshot:
        let snapshot = try setup.renderer.captureCommittedDocument()
        let export = try setup.renderer.exportFlattenedScene(
            pixelSize: snapshot.canvasSize,
            transparentBackground: true
        )
        #expect(export.pixelSize == snapshot.canvasSize)
        #expect(export.hasTransparentBackground)
        #expect(export.bgra8Bytes.count == snapshot.canvasSize.width * snapshot.canvasSize.height * 4)
        #expect(export.bgra8Bytes.contains { $0 != 0 })
    default:
        break
    }
}
