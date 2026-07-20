import EditorCore
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@MainActor
private func makeControllerRenderer() throws -> GridRenderer? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let shader = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/MetalRenderer/Shaders.metal"
        ),
        encoding: .utf8
    )
    let header = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/CShaderTypes/include/ShaderTypes.h"
        ),
        encoding: .utf8
    )
    let library = try device.makeLibrary(
        source: shader.replacingOccurrences(
            of: "#include \"ShaderTypes.h\"",
            with: header
        ),
        options: nil
    )
    return try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 64, height: 64),
        configuration: TilingCanvasConfiguration(
            pixelSize: PixelSize(width: 64, height: 64),
            tiling: .grid
        )
    )
}

private func controllerSample(
    _ phase: StrokePhase,
    x: Float = 32,
    y: Float = 32
) -> StrokeSample {
    .mouse(
        position: ScreenPoint(x: x, y: y),
        timestamp: 0,
        phase: phase
    )
}

@MainActor
private func commitControllerStroke(
    _ controller: EditorSessionController,
    renderer: GridRenderer,
    x: Float = 32,
    y: Float = 32
) throws {
    controller.handleStrokeSample(controllerSample(.began, x: x, y: y))
    controller.handleStrokeSample(controllerSample(.ended, x: x, y: y))
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.submitCommitForHarness()
    try renderer.drainCompletedOperationsForHarness()
}

@Test
@MainActor
func rasterSuccessRecordsTheCapturedEraseTool() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    var releaseCalls: [Set<StoredRasterRevisionID>] = []
    let controller = EditorSessionController(
        renderer: renderer,
        releaseRasterRevisions: {
            releaseCalls.append($0)
            renderer.releaseRasterRevisions($0)
        }
    )

    controller.handleTool(.erase)
    try commitControllerStroke(controller, renderer: renderer)

    let command = try #require(controller.lastRecordedRasterCommandForTesting)
    #expect(command.kind == .erase)
    #expect(releaseCalls == [[]])
    #expect(controller.model.canUndo)
    #expect(!controller.model.canRedo)
    #expect(!controller.model.isBusy)
    #expect(renderer.isIdle)

    renderer.releaseRasterRevisions([command.before.id, command.after.id])
}

@Test
@MainActor
func operationSuccessMovesUndoRedoOnlyAfterRendererCompletion() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    var releaseCalls: [Set<StoredRasterRevisionID>] = []
    let controller = EditorSessionController(
        renderer: renderer,
        releaseRasterRevisions: {
            releaseCalls.append($0)
            renderer.releaseRasterRevisions($0)
        }
    )

    try commitControllerStroke(controller, renderer: renderer, x: 20, y: 20)
    let first = try #require(controller.lastRecordedRasterCommandForTesting)
    try commitControllerStroke(controller, renderer: renderer, x: 44, y: 44)
    let second = try #require(controller.lastRecordedRasterCommandForTesting)
    let afterSecond = try canonicalBytes(renderer)
    releaseCalls.removeAll()

    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    controller.undo()
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(controller.model.isBusy)
    #expect(!controller.model.canUndo)
    #expect(!controller.model.canRedo)
    #expect(!renderer.isIdle)
    #expect(try canonicalBytes(renderer) == afterSecond)

    try renderer.finishRasterOperationForHarness()
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(controller.historyAvailabilityForTesting.canRedo)
    #expect(controller.model.canUndo)
    #expect(controller.model.canRedo)
    #expect(!controller.model.isBusy)
    #expect(renderer.isIdle)

    controller.redo()
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(controller.historyAvailabilityForTesting.canRedo)
    #expect(controller.model.isBusy)
    #expect(!controller.model.canUndo)
    #expect(!controller.model.canRedo)
    try renderer.finishRasterOperationForHarness()
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(controller.model.canUndo)
    #expect(!controller.model.canRedo)
    #expect(try canonicalBytes(renderer) == afterSecond)

    controller.undo()
    try renderer.finishRasterOperationForHarness()
    releaseCalls.removeAll()
    try commitControllerStroke(controller, renderer: renderer, x: 32, y: 48)
    let replacement = try #require(
        controller.lastRecordedRasterCommandForTesting
    )

    #expect(releaseCalls == [[second.before.id, second.after.id]])
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(!controller.model.canRedo)

    let retained = [first, replacement]
    renderer.releaseRasterRevisions(
        Set(retained.flatMap { [$0.before.id, $0.after.id] })
    )
}

@Test
@MainActor
func failureKeepsHistoryCursorAvailabilityAndWholeRasterUnchanged() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    var errors: [MetalRendererError] = []
    let controller = EditorSessionController(
        renderer: renderer,
        requestRasterRestore: { token, revision in
            try renderer.requestRasterRestoreForHarness(
                token: token,
                revision: revision,
                forceFailure: true
            )
        }
    )
    controller.onError = { errors.append($0) }
    try commitControllerStroke(controller, renderer: renderer)
    let command = try #require(controller.lastRecordedRasterCommandForTesting)
    let before = try canonicalBytes(renderer)

    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    controller.undo()
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(controller.model.isBusy)
    #expect(!renderer.isIdle)

    #expect(throws: MetalRendererError.commandFailed(
        "injected harness command-buffer failure"
    )) {
        try renderer.finishRasterOperationForHarness()
    }

    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(controller.model.canUndo)
    #expect(!controller.model.canRedo)
    #expect(!controller.model.isBusy)
    #expect(renderer.isIdle)
    #expect(try canonicalBytes(renderer) == before)
    #expect(errors.count == 1)

    renderer.releaseRasterRevisions([command.before.id, command.after.id])
}

@Test
@MainActor
func tilingChangeUndoRedoIsMetadataOnly() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let originalBytes = try canonicalBytes(renderer)
    let originalResources = renderer.harnessTilingMutationSnapshot

    controller.handleTiling(.mirrorX)
    #expect(controller.model.tiling == .mirrorX)
    #expect(renderer.tiling == .mirrorX)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)

    controller.undo()
    #expect(controller.model.tiling == .grid)
    #expect(renderer.tiling == .grid)
    #expect(controller.historyAvailabilityForTesting.canRedo)

    controller.redo()
    #expect(controller.model.tiling == .mirrorX)
    #expect(renderer.tiling == .mirrorX)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(try canonicalBytes(renderer) == originalBytes)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == originalResources.canonicalFront
    )
    #expect(renderer.harnessRevision == originalResources.revision)
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
}

@Test
@MainActor
func tilingAfterUndoReleasesRasterRedoWithoutAllocatingMetadataPayload() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    var releaseCalls: [Set<StoredRasterRevisionID>] = []
    let controller = EditorSessionController(
        renderer: renderer,
        releaseRasterRevisions: {
            releaseCalls.append($0)
            renderer.releaseRasterRevisions($0)
        }
    )
    try commitControllerStroke(controller, renderer: renderer)
    let raster = try #require(controller.lastRecordedRasterCommandForTesting)
    controller.undo()
    try renderer.finishRasterOperationForHarness()
    releaseCalls.removeAll()

    controller.handleTiling(.mirrorY)

    #expect(releaseCalls == [[raster.before.id, raster.after.id]])
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
}

@Test
@MainActor
func resizeHistoryFinalizesOnlyAfterInstallAndRestoresExactBytes() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let before = try canonicalBytes(renderer)
    let newSize = PixelSize(width: 96, height: 80)

    controller.handleTileSize(newSize)
    #expect(controller.model.pixelSize == PixelSize(width: 64, height: 64))
    #expect(!controller.historyAvailabilityForTesting.canUndo)
    #expect(controller.model.isBusy)
    try renderer.finishRasterOperationForHarness()

    #expect(controller.model.pixelSize == newSize)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(!controller.model.isBusy)
    #expect(try canonicalBytes(renderer) == [UInt8](
        repeating: 0,
        count: newSize.width * newSize.height * 4
    ))

    controller.undo()
    #expect(controller.model.pixelSize == newSize)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    try renderer.finishRasterOperationForHarness()
    #expect(controller.model.pixelSize == PixelSize(width: 64, height: 64))
    #expect(try canonicalBytes(renderer) == before)
    #expect(controller.historyAvailabilityForTesting.canRedo)

    controller.redo()
    try renderer.finishRasterOperationForHarness()
    #expect(controller.model.pixelSize == newSize)
    #expect(!controller.historyAvailabilityForTesting.canRedo)

    let resize = try #require(controller.lastRecordedResizeCommandForTesting)
    renderer.releaseRasterRevisions([resize.before.id, resize.after.id])
}

@Test
@MainActor
func resizeAllocationFailureKeepsControllerHistoryAndCommittedModel() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(
        renderer: renderer,
        requestResize: { token, size, maximumRetainedBytes in
            try renderer.requestResizeForHarness(
                token: token,
                to: size,
                maximumRetainedBytes: maximumRetainedBytes,
                forceResourceAllocationFailure: true
            )
        }
    )
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }
    let resources = renderer.harnessTilingMutationSnapshot
    let viewport = renderer.viewport
    let bytes = try canonicalBytes(renderer)

    controller.handleTileSize(PixelSize(width: 96, height: 80))

    #expect(errors == [.textureAllocationFailed])
    #expect(controller.model.pixelSize == PixelSize(width: 64, height: 64))
    #expect(!controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(!controller.model.isBusy)
    #expect(renderer.harnessTilingMutationSnapshot == resources)
    #expect(renderer.viewport == viewport)
    #expect(try canonicalBytes(renderer) == bytes)
}

@MainActor
private func canonicalBytes(_ renderer: GridRenderer) throws -> [UInt8] {
    textureBytes(try renderer.copyCanonicalForHarness())
}

private func textureBytes(_ texture: any MTLTexture) -> [UInt8] {
    let bytesPerRow = texture.width * 4
    var bytes = [UInt8](
        repeating: 0,
        count: bytesPerRow * texture.height
    )
    bytes.withUnsafeMutableBytes { storage in
        texture.getBytes(
            storage.baseAddress!,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
    }
    return bytes
}
