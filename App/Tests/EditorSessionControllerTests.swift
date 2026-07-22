import EditorCore
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

#if os(macOS)
import AppKit
#endif

@MainActor
func makeControllerRenderer() throws -> GridRenderer? {
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

@Test
@MainActor
func semanticShortcutsUpdateToolBrushAndGridThroughControllerIntents() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.handleShortcut(.selectTool(.erase))
    controller.handleShortcut(.stepBrush(larger: true))
    controller.handleShortcut(.toggleGrid)

    #expect(controller.model.tool == .erase)
    #expect(controller.model.brushDiameter == 25)
    #expect(controller.model.showGrid)
    #expect(renderer.interactiveGridVisibility)
}

@Test
@MainActor
func brushChangeKeepsSubsequentEditorActionsCoherent() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.stepBrush(larger: true)
    #expect(controller.model.brushDiameter == 25)
    #expect(!controller.model.isBusy)

    var retainedRevisionIDs: Set<StoredRasterRevisionID> = []
    try commitControllerStroke(controller, renderer: renderer)
    let draw = try #require(controller.lastRecordedRasterCommandForTesting)
    retainedRevisionIDs.formUnion([draw.before.id, draw.after.id])
    #expect(draw.kind == .draw)
    let drawnBytes = try canonicalBytes(renderer)
    #expect(!drawnBytes.allSatisfy { $0 == 0 })

    controller.handleTool(.erase)
    #expect(controller.model.tool == .erase)
    try commitControllerStroke(controller, renderer: renderer)
    let erase = try #require(controller.lastRecordedRasterCommandForTesting)
    retainedRevisionIDs.formUnion([erase.before.id, erase.after.id])
    #expect(erase.kind == .erase)
    let erasedBytes = try canonicalBytes(renderer)
    let drawnAlpha = stride(from: 3, to: drawnBytes.count, by: 4)
        .reduce(0) { $0 + Int(drawnBytes[$1]) }
    let erasedAlpha = stride(from: 3, to: erasedBytes.count, by: 4)
        .reduce(0) { $0 + Int(erasedBytes[$1]) }
    #expect(erasedAlpha < drawnAlpha)

    controller.handleTool(.draw)
    try commitControllerStroke(
        controller,
        renderer: renderer,
        x: 20,
        y: 20
    )
    let redraw = try #require(controller.lastRecordedRasterCommandForTesting)
    retainedRevisionIDs.formUnion([redraw.before.id, redraw.after.id])
    let redrawnBytes = try canonicalBytes(renderer)
    #expect(!redrawnBytes.allSatisfy { $0 == 0 })

    controller.handleGridVisibility(true)
    controller.handleTiling(.halfDrop)
    #expect(controller.model.showGrid)
    #expect(renderer.interactiveGridVisibility)
    #expect(controller.model.tiling == .halfDrop)
    #expect(renderer.tiling == .halfDrop)

    controller.clear()
    try renderer.finishRasterOperationForHarness()
    #expect(try canonicalBytes(renderer).allSatisfy { $0 == 0 })
    #expect(!controller.model.isBusy)

    let clear = try #require(controller.lastRecordedRasterCommandForTesting)
    retainedRevisionIDs.formUnion([clear.before.id, clear.after.id])
    renderer.releaseRasterRevisions(retainedRevisionIDs)
}

@Test
@MainActor
func tilingShortcutsUseStableOneBasedTilingIndices() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    for index in 1...7 {
        controller.handleShortcut(.selectTiling(index1: index))
        #expect(controller.model.tiling.rawValue == UInt32(index - 1))
        #expect(renderer.tiling.rawValue == UInt32(index - 1))
    }
}

@Test
@MainActor
func tileStepShortcutSubmitsOneClampedTwoDimensionResize() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.handleShortcut(.stepTile(larger: true))

    #expect(controller.model.pixelSize == PixelSize(width: 64, height: 64))
    #expect(controller.model.isBusy)
    try renderer.finishRasterOperationForHarness()
    #expect(controller.model.pixelSize == PixelSize(width: 96, height: 96))
    #expect(!controller.model.isBusy)

    let resize = try #require(controller.lastRecordedResizeCommandForTesting)
    renderer.releaseRasterRevisions([resize.before.id, resize.after.id])
}

@Test
@MainActor
func busyControllerRejectsConflictingSemanticShortcuts() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.handleShortcut(.stepTile(larger: true))
    #expect(controller.model.isBusy)

    controller.handleShortcut(.selectTool(.erase))
    controller.handleShortcut(.stepBrush(larger: true))
    controller.handleShortcut(.toggleGrid)
    controller.handleShortcut(.selectTiling(index1: 2))
    controller.handleShortcut(.clear)

    #expect(controller.model.tool == .draw)
    #expect(controller.model.brushDiameter == 20)
    #expect(!controller.model.showGrid)
    #expect(controller.model.tiling == .grid)

    try renderer.finishRasterOperationForHarness()
    let resize = try #require(controller.lastRecordedResizeCommandForTesting)
    renderer.releaseRasterRevisions([resize.before.id, resize.after.id])
}

@Test
@MainActor
func commandShortcutsShareClearUndoAndRedoHistoryFlow() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    try commitControllerStroke(controller, renderer: renderer)
    let stroke = try #require(controller.lastRecordedRasterCommandForTesting)

    controller.handleShortcut(.clear)
    #expect(controller.model.isBusy)
    try renderer.finishRasterOperationForHarness()
    let clear = try #require(controller.lastRecordedRasterCommandForTesting)
    #expect(clear.kind == .clear)
    #expect(controller.model.canUndo)

    controller.handleShortcut(.undo)
    try renderer.finishRasterOperationForHarness()
    #expect(controller.model.canRedo)

    controller.handleShortcut(.redo)
    try renderer.finishRasterOperationForHarness()
    #expect(!controller.model.canRedo)

    renderer.releaseRasterRevisions(
        Set(
            [stroke, clear].flatMap {
                [$0.before.id, $0.after.id]
            }
        )
    )
}

@Test
@MainActor
func clearCompletesWithoutAViewFrameAndControlsAcceptTheNextIntent() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.clear()
    #expect(controller.model.isBusy)

    for _ in 0..<200 where controller.model.isBusy {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(!controller.model.isBusy)
    #expect(renderer.isIdle)

    controller.handleGridVisibility(true)
    controller.handleTiling(.halfDrop)

    #expect(controller.model.showGrid)
    #expect(renderer.interactiveGridVisibility)
    #expect(controller.model.tiling == .halfDrop)
    #expect(renderer.tiling == .halfDrop)

    let clear = try #require(controller.lastRecordedRasterCommandForTesting)
    renderer.releaseRasterRevisions([clear.before.id, clear.after.id])
}

@Test
@MainActor
func cancelShortcutCancelsStrokeWithoutCreatingHistory() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.handleStrokeSample(controllerSample(.began))
    #expect(renderer.hasActiveStroke)
    controller.handleShortcut(.cancel)

    #expect(renderer.isIdle)
    #expect(!controller.model.canUndo)
    #expect(controller.lastRecordedRasterCommandForTesting == nil)
}

@Test
@MainActor
func focusLossPairsSpaceReleaseAndCancelsTheActivePointer() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.handleShortcut(.spaceChanged(true))
    #expect(controller.isSpaceDown)
    controller.handleShortcut(.spaceChanged(false))
    #expect(!controller.isSpaceDown)
    controller.handleShortcut(.spaceChanged(true))
    controller.handleStrokeSample(controllerSample(.began))
    #expect(controller.isSpaceDown)
    #expect(renderer.hasActiveStroke)

    controller.handleFocusLoss()

    #expect(!controller.isSpaceDown)
    #expect(!renderer.hasActiveStroke)
    #expect(renderer.isIdle)
}

#if os(macOS)
@Test
@MainActor
func escapeDuringActivePanCancelsNativeAndReducerState() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var focusRequestCount = 0
    let view = InteractiveMetalView(
        frame: CGRect(x: 0, y: 0, width: 64, height: 64),
        controller: controller,
        renderer: renderer,
        requestEditorFocus: { focusRequestCount += 1 },
        pointerCancellationGeneration: 0
    )
    view.drawableSize = CGSize(width: 64, height: 64)
    controller.handleShortcut(.spaceChanged(true))

    let down = try #require(
        pointerEvent(type: .leftMouseDown, location: CGPoint(x: 16, y: 16))
    )
    view.mouseDown(with: down)
    #expect(focusRequestCount == 1)
    #expect(view.hasActivePointerInteractionForTesting)

    var pointerCancellationGeneration: UInt = 0
    handleEditorShortcut(
        .cancel,
        controller: controller,
        pointerCancellationGeneration: &pointerCancellationGeneration
    )
    view.applyPointerCancellation(generation: pointerCancellationGeneration)
    let viewportAfterCancellation = renderer.viewport
    let drag = try #require(
        pointerEvent(type: .leftMouseDragged, location: CGPoint(x: 48, y: 48))
    )
    view.mouseDragged(with: drag)

    #expect(!view.hasActivePointerInteractionForTesting)
    #expect(renderer.viewport == viewportAfterCancellation)
    #expect(!controller.isSpaceDown)
    #expect(controller.transactionStateForTesting == .idle)
    #expect(renderer.isIdle)
}

@Test
@MainActor
func brushCursorTracksPointerDiameterAndZoom() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let view = InteractiveMetalView(
        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        controller: controller,
        renderer: renderer,
        requestEditorFocus: {},
        pointerCancellationGeneration: 0
    )
    view.drawableSize = CGSize(width: 200, height: 200)
    view.updateBrushCursor(diameter: 40)

    let move = try #require(
        pointerEvent(type: .mouseMoved, location: CGPoint(x: 30, y: 60))
    )
    view.mouseMoved(with: move)

    #expect(view.isBrushCursorVisibleForTesting)
    #expect(view.brushCursorFrameForTesting.midX == 30)
    #expect(view.brushCursorFrameForTesting.midY == 40)
    #expect(view.brushCursorFrameForTesting.width == 20)
    #expect(view.brushCursorFrameForTesting.height == 20)

    controller.zoom(by: 2, anchor: ScreenPoint(x: 30, y: 40))
    view.updateBrushCursor(diameter: 40)

    #expect(view.brushCursorFrameForTesting.width == 40)
    #expect(view.brushCursorFrameForTesting.height == 40)

    view.mouseExited(with: move)
    #expect(!view.isBrushCursorVisibleForTesting)
}

private func pointerEvent(
    type: NSEvent.EventType,
    location: CGPoint
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
}
#endif

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
