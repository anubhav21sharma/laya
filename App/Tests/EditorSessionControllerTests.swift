@testable import EditorCore
import Foundation
import Metal
@testable import MetalRenderer
@testable import PatternEngine
import Testing

#if os(macOS)
import AppKit
#endif

@MainActor
func makeControllerRenderer(
    finiteConfiguration: FiniteSymmetryConfiguration? = nil
) throws -> GridRenderer? {
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
    let pixelSize = PixelSize(width: 64, height: 64)
    let canvasConfiguration = try finiteConfiguration.map {
        try TilingCanvasConfiguration(
            pixelSize: pixelSize,
            finiteConfiguration: $0
        )
    } ?? TilingCanvasConfiguration(
        pixelSize: pixelSize,
        tiling: .grid
    )
    return try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 64, height: 64),
        configuration: canvasConfiguration
    )
}

private func controllerSample(
    _ phase: StrokePhase,
    x: Float = 32,
    y: Float = 32,
    timestamp: TimeInterval = 0
) -> StrokeSample {
    .mouse(
        position: ScreenPoint(x: x, y: y),
        timestamp: timestamp,
        phase: phase
    )
}

private func estimatedControllerSample(
    phase: StrokePhase,
    kind: StrokeSampleKind,
    index: Int,
    pressure: Float,
    expecting: StrokeEstimatedProperties,
    estimated: StrokeEstimatedProperties? = nil,
    x: Float = 32,
    timestamp: TimeInterval? = nil
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: pressure,
        timestamp: timestamp ?? (phase == .ended ? 2 : 1),
        phase: phase,
        source: .pencil,
        kind: kind,
        capabilities: [.pressure],
        estimationUpdateIndex: index,
        estimatedProperties: estimated ?? expecting,
        estimatedPropertiesExpectingUpdates: expecting
    )
}

private func controllerMovedSample(
    x: Float,
    timestamp: TimeInterval,
    kind: StrokeSampleKind
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: 0.5,
        timestamp: timestamp,
        phase: .moved,
        source: .mouse,
        kind: kind
    )
}

private let controllerRadialConfiguration = RadialSymmetryConfiguration(
    kind: .mandala,
    rayCount: 8,
    center: WorldPoint(x: 32, y: 32),
    referenceAngleRadians: .pi / 12
)

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
func controllerStartsInFiniteDomainAndCanSwitchOnlyBeforeRasterEdit()
    throws
{
    guard let renderer = try makeControllerRenderer(
        finiteConfiguration: .radial(controllerRadialConfiguration)
    ) else { return }
    let controller = EditorSessionController(renderer: renderer)

    #expect(
        controller.model.documentConfiguration
            == .finite(.radial(controllerRadialConfiguration))
    )
    #expect(controller.model.tiling == .radialMandala)
    #expect(!controller.model.documentDomainLocked)
    #expect(!controller.model.radialGeometryLocked)

    let revised = RadialSymmetryConfiguration(
        kind: .rotation,
        rayCount: 7,
        center: WorldPoint(x: 29, y: 35),
        referenceAngleRadians: -.pi / 9
    )
    controller.handleFiniteConfiguration(.radial(revised))
    #expect(renderer.finiteConfiguration == .radial(revised))
    #expect(controller.model.radialConfiguration == revised)
    #expect(!controller.historyAvailabilityForTesting.canUndo)

    let periodic = PeriodicSymmetryConfiguration.defaultConfiguration(
        presetID: .halfDrop,
        canonicalRasterSize: PixelSize(width: 64, height: 64)
    )
    controller.handlePeriodicConfiguration(periodic)
    #expect(renderer.documentConfiguration == .periodic(periodic))
    #expect(controller.model.documentConfiguration == .periodic(periodic))
    #expect(
        controller.model.pixelSize
            == EditorConfiguration.defaultPeriodicPixelSize
    )
    #expect(!controller.historyAvailabilityForTesting.canUndo)

    controller.handleFiniteConfiguration(.plain)
    #expect(renderer.documentConfiguration == .finite(.plain))
    #expect(controller.model.documentConfiguration == .finite(.plain))
    #expect(
        controller.model.pixelSize
            == EditorConfiguration.defaultFinitePixelSize
    )
}

@Test
@MainActor
func blankModeSelectionUsesFiniteAndPeriodicDefaults() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.selectPlainCanvasMode()
    #expect(renderer.documentConfiguration == .finite(.plain))
    #expect(renderer.pixelSize == PixelSize(width: 2_048, height: 2_048))
    #expect(
        renderer.viewport.worldCenter
            == WorldPoint(x: 1_024, y: 1_024)
    )

    controller.selectRadialMode()
    let radial = try #require(controller.model.radialConfiguration)
    #expect(renderer.pixelSize == PixelSize(width: 2_048, height: 2_048))
    #expect(radial.kind == .mandala)
    #expect(radial.rayCount == 8)
    #expect(radial.center == WorldPoint(x: 1_024, y: 1_024))

    controller.selectSeamlessPatternMode()
    #expect(
        renderer.documentConfiguration
            == .periodic(controller.model.periodicConfiguration)
    )
    #expect(renderer.pixelSize == PixelSize(width: 256, height: 256))
    #expect(renderer.viewport.worldCenter == WorldPoint(x: 128, y: 128))
}

@Test
@MainActor
func undoingFirstRadialEditUnlocksAndAllowsModeChange() throws {
    guard let renderer = try makeControllerRenderer(
        finiteConfiguration: .radial(controllerRadialConfiguration)
    ) else { return }
    let controller = EditorSessionController(renderer: renderer)

    try commitControllerStroke(controller, renderer: renderer, x: 47, y: 34)
    #expect(controller.model.documentDomainLocked)
    #expect(controller.model.radialGeometryLocked)

    controller.undo()
    try renderer.finishRasterOperationForHarness()
    #expect(!controller.model.documentDomainLocked)
    #expect(!controller.model.radialGeometryLocked)
    #expect(controller.model.canRedo)

    controller.selectSeamlessPatternMode()
    #expect(
        controller.model.documentConfiguration
            == .periodic(controller.model.periodicConfiguration)
    )
    #expect(!controller.model.canUndo)
    #expect(!controller.model.canRedo)
    #expect(!controller.model.documentDomainLocked)
}

@Test
@MainActor
func lockedRadialGeometryChangeReportsRadialLock() throws {
    guard let renderer = try makeControllerRenderer(
        finiteConfiguration: .radial(controllerRadialConfiguration)
    ) else { return }
    let controller = EditorSessionController(renderer: renderer)
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }
    try commitControllerStroke(controller, renderer: renderer, x: 47, y: 34)

    controller.handleFiniteConfiguration(.radial(
        RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 6,
            center: WorldPoint(x: 31, y: 29)
        )
    ))

    #expect(errors.last == .radialGeometryLocked)
    #expect(renderer.finiteConfiguration == .radial(controllerRadialConfiguration))
}

@Test
@MainActor
func plainAndSeamlessLocksFollowCommittedContentState() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }

    controller.selectPlainCanvasMode()
    try commitControllerStroke(
        controller,
        renderer: renderer,
        x: 1_024,
        y: 1_024
    )
    #expect(controller.model.documentDomainLocked)
    #expect(!controller.model.radialGeometryLocked)

    controller.selectRadialMode()
    #expect(errors.last == .documentDomainLocked)
    #expect(renderer.documentConfiguration == .finite(.plain))

    controller.undo()
    try renderer.finishRasterOperationForHarness()
    #expect(!controller.model.documentDomainLocked)

    controller.selectSeamlessPatternMode()
    #expect(renderer.pixelSize == PixelSize(width: 256, height: 256))
    try commitControllerStroke(controller, renderer: renderer)
    #expect(controller.model.documentDomainLocked)

    controller.clear()
    try renderer.finishRasterOperationForHarness()
    #expect(!controller.model.documentDomainLocked)

    controller.selectRadialMode()
    #expect(renderer.pixelSize == PixelSize(width: 2_048, height: 2_048))
    #expect(controller.model.radialConfiguration?.center == WorldPoint(
        x: 1_024,
        y: 1_024
    ))
}

@Test
@MainActor
func redoAndUndoClearReconcileRadialLocksWithVisibleHistoryState() throws {
    guard let renderer = try makeControllerRenderer(
        finiteConfiguration: .radial(controllerRadialConfiguration)
    ) else { return }
    let controller = EditorSessionController(renderer: renderer)

    try commitControllerStroke(controller, renderer: renderer, x: 47, y: 34)
    let stroke = try #require(controller.lastRecordedRasterCommandForTesting)

    controller.undo()
    try renderer.finishRasterOperationForHarness()
    #expect(!controller.model.radialGeometryLocked)

    controller.redo()
    try renderer.finishRasterOperationForHarness()
    #expect(controller.model.documentDomainLocked)
    #expect(controller.model.radialGeometryLocked)

    controller.clear()
    try renderer.finishRasterOperationForHarness()
    let clear = try #require(controller.lastRecordedRasterCommandForTesting)
    #expect(!controller.model.documentDomainLocked)
    #expect(!controller.model.radialGeometryLocked)

    controller.undo()
    try renderer.finishRasterOperationForHarness()
    #expect(controller.model.documentDomainLocked)
    #expect(controller.model.radialGeometryLocked)

    controller.redo()
    try renderer.finishRasterOperationForHarness()
    #expect(!controller.model.documentDomainLocked)
    #expect(!controller.model.radialGeometryLocked)

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
func resizingBlankDocumentKeepsModeEditable() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.handleTileSize(PixelSize(width: 96, height: 80))
    try renderer.finishRasterOperationForHarness()

    #expect(!controller.model.documentDomainLocked)
    controller.selectPlainCanvasMode()
    #expect(renderer.documentConfiguration == .finite(.plain))
}

@Test
@MainActor
func failedFirstRadialCommitLeavesGeometryEditable() throws {
    guard let renderer = try makeControllerRenderer(
        finiteConfiguration: .radial(controllerRadialConfiguration)
    ) else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.handleStrokeSample(controllerSample(.began, x: 47, y: 34))
    controller.handleStrokeSample(controllerSample(.ended, x: 47, y: 34))
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.submitCommitForHarness(forceFailure: true)
    #expect(throws: MetalRendererError.self) {
        try renderer.drainCompletedOperationsForHarness()
    }

    #expect(!controller.model.documentDomainLocked)
    #expect(!controller.model.radialGeometryLocked)
    let revised = RadialSymmetryConfiguration(
        kind: .rotation,
        rayCount: 6,
        center: WorldPoint(x: 31, y: 29)
    )
    controller.handleFiniteConfiguration(.radial(revised))
    #expect(renderer.finiteConfiguration == .radial(revised))
    #expect(controller.model.radialConfiguration == revised)
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
func periodicConfigurationChangeUndoRedoIsExactMetadataOnly() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let before = controller.model.periodicConfiguration
    let beforeBytes = try canonicalBytes(renderer)
    let beforeResources = renderer.harnessTilingMutationSnapshot
    let configuration = PeriodicSymmetryConfiguration(
        presetID: .squareKaleidoscope,
        repeatSize: PatternSize(width: 192, height: 192),
        orientationRadians: .pi / 6
    )

    controller.handlePeriodicConfiguration(configuration)

    #expect(controller.model.periodicConfiguration == configuration)
    #expect(renderer.periodicConfiguration == configuration)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)

    controller.undo()
    #expect(controller.model.periodicConfiguration == before)
    #expect(renderer.periodicConfiguration == before)
    #expect(controller.historyAvailabilityForTesting.canRedo)
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)

    controller.redo()
    #expect(controller.model.periodicConfiguration == configuration)
    #expect(renderer.periodicConfiguration == configuration)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(try canonicalBytes(renderer) == beforeBytes)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == beforeResources.canonicalFront
    )
    #expect(renderer.harnessRevision == beforeResources.revision)
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
}

@Test
@MainActor
func everyTriangularPresetLeavesEditorControlsResponsive() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let presets: [SymmetryPresetID] = [
        .hexagons,
        .rotation3,
        .rotation6,
        .kaleidoscope60,
        .kaleidoscope30,
    ]

    for preset in presets {
        controller.handleTiling(preset)
        #expect(controller.model.tiling == preset)
        #expect(renderer.tiling == preset)
        #expect(!controller.model.isBusy)
        #expect(renderer.isIdle)

        controller.handleGridVisibility(true)
        controller.handleTool(.erase)
        #expect(controller.model.showGrid)
        #expect(renderer.interactiveGridVisibility)
        #expect(controller.model.tool == .erase)

        controller.handleTool(.draw)
        controller.handleGridVisibility(false)
        #expect(controller.model.tool == .draw)
        #expect(!controller.model.showGrid)
        #expect(!renderer.interactiveGridVisibility)
    }

    controller.clear()
    try renderer.finishRasterOperationForHarness()
    #expect(try canonicalBytes(renderer).allSatisfy { $0 == 0 })
    #expect(!controller.model.isBusy)
    #expect(renderer.isIdle)

    let clear = try #require(controller.lastRecordedRasterCommandForTesting)
    renderer.releaseRasterRevisions([clear.before.id, clear.after.id])
}

@Test
@MainActor
func invalidPeriodicConfigurationFailsAtomicallyWithoutHistory() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }
    let beforeConfiguration = controller.model.periodicConfiguration
    let beforeBytes = try canonicalBytes(renderer)
    let beforeResources = renderer.harnessTilingMutationSnapshot
    let invalid = PeriodicSymmetryConfiguration(
        presetID: .squareRotation,
        repeatSize: PatternSize(width: 192, height: 160),
        orientationRadians: .pi / 4
    )

    controller.handlePeriodicConfiguration(invalid)

    #expect(controller.model.periodicConfiguration == beforeConfiguration)
    #expect(renderer.periodicConfiguration == beforeConfiguration)
    #expect(!controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(!controller.model.isBusy)
    #expect(renderer.isIdle)
    #expect(try canonicalBytes(renderer) == beforeBytes)
    #expect(renderer.harnessTilingMutationSnapshot == beforeResources)
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
    #expect(errors.count == 1)
    guard let error = errors.first,
          case .invalidPeriodicConfiguration = error
    else {
        Issue.record("Expected invalidPeriodicConfiguration")
        return
    }
}

@Test
@MainActor
func cancellationFailureCannotStrandQueuedPeriodicIntentBusy() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let injectedError = MetalRendererError.commandFailed(
        "injected cancellation failure"
    )
    var errors: [MetalRendererError] = []
    let controller = EditorSessionController(
        renderer: renderer,
        requestStrokeCancellation: { token in
            try renderer.cancelStroke(token: token)
            throw injectedError
        }
    )
    controller.onError = { errors.append($0) }
    let before = controller.model.periodicConfiguration

    controller.handleStrokeSample(controllerSample(.began))
    controller.handlePeriodicConfiguration(
        PeriodicSymmetryConfiguration(
            presetID: .squareRotation,
            repeatSize: PatternSize(width: 96.5, height: 96.5),
            orientationRadians: .pi / 7
        )
    )

    #expect(errors == [injectedError])
    #expect(controller.transactionStateForTesting == .idle)
    #expect(!controller.model.isBusy)
    #expect(renderer.isIdle)
    #expect(controller.model.periodicConfiguration == before)
    #expect(!controller.historyAvailabilityForTesting.canUndo)

    controller.handleTiling(.mirrorX)
    #expect(controller.model.tiling == .mirrorX)
    #expect(!controller.model.isBusy)
}

@Test
@MainActor
func normalizedEquivalentPeriodicConfigurationDoesNotCreateHistory() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleTiling(.squareRotation)
    controller.undo()
    #expect(!controller.historyAvailabilityForTesting.canUndo)
    #expect(controller.historyAvailabilityForTesting.canRedo)
    let before = controller.model.periodicConfiguration

    controller.handlePeriodicConfiguration(
        PeriodicSymmetryConfiguration(
            presetID: before.presetID,
            repeatSize: before.repeatSize,
            orientationRadians: 2 * .pi
        )
    )

    #expect(controller.model.periodicConfiguration == before)
    #expect(renderer.periodicConfiguration == before)
    #expect(!controller.historyAvailabilityForTesting.canUndo)
    #expect(controller.historyAvailabilityForTesting.canRedo)
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
func pointerDownCapturesSelectedProgramAndUniqueNonzeroSeed() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let sessionEntropy: UInt64 = 0xA5A5_1234_5678_9ABC
    let controller = EditorSessionController(
        renderer: renderer,
        strokeSeedSessionEntropy: sessionEntropy
    )

    controller.handleRecipe(AnchorBrushCatalog.marker.id)
    controller.handleStrokeSample(controllerSample(.began))
    let first = try #require(renderer.harnessActiveStrokeStyle)
    #expect(first.program.compatibilityRecipe != nil)
    #expect(first.seed == EditorSessionController.derivedStrokeSeed(
        sequence: 1,
        sessionEntropy: sessionEntropy
    ))
    controller.handleStrokeSample(controllerSample(.cancelled))

    controller.handleRecipe(AnchorBrushCatalog.glaze.id)
    controller.handleStrokeSample(controllerSample(.began))
    let second = try #require(renderer.harnessActiveStrokeStyle)
    #expect(second.program.compatibilityRecipe != nil)
    #expect(second.seed == EditorSessionController.derivedStrokeSeed(
        sequence: 2,
        sessionEntropy: sessionEntropy
    ))
    #expect(second.seed != first.seed)
    controller.handleStrokeSample(controllerSample(.cancelled))

    controller.handleTool(.erase)
    controller.handleStrokeSample(controllerSample(.began))
    let eraser = try #require(renderer.harnessActiveStrokeStyle)
    #expect(eraser.program.compatibilityRecipe != nil)
    #expect(eraser.seed == EditorSessionController.derivedStrokeSeed(
        sequence: 3,
        sessionEntropy: sessionEntropy
    ))
    #expect(eraser.seed != second.seed)
    #expect(eraser.compositeMode == .erase)
    controller.handleStrokeSample(controllerSample(.cancelled))
}

@Test
@MainActor
func diagnosticProgramSeedAndNormalizedInputAreCapturedAtStrokeStart()
    throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let program = AnchorBrushCatalog.marker.program
    var observed: [StrokeSample] = []
    controller.onNormalizedInput = { observed.append($0) }

    try controller.installDiagnosticDrawProgram(program)
    try controller.setDiagnosticFixedStrokeSeed(0xCAFE)
    let began = controllerSample(.began, x: 20, y: 24, timestamp: 1)
    controller.handleStrokeSample(began)

    let style = try #require(renderer.harnessActiveStrokeStyle)
    #expect(style.program.compatibilityRecipe != nil)
    #expect(style.seed == 0xCAFE)
    #expect(observed == [began])

    controller.handleStrokeSample(controllerSample(.cancelled, timestamp: 2))
    controller.handleRecipe(AnchorBrushCatalog.defaultDraw.id)
    controller.handleStrokeSample(controllerSample(.began, timestamp: 3))
    let builtIn = try #require(renderer.harnessActiveStrokeStyle)
    #expect(builtIn.program.compatibilityRecipe != nil)
    #expect(builtIn.seed == 0xCAFE)
    controller.handleStrokeSample(controllerSample(.cancelled, timestamp: 4))
}

#if DEBUG
private final class BrushProgramCompileSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func record() {
        lock.withLock { storage += 1 }
    }

    var count: Int {
        lock.withLock { storage }
    }
}

@Test
@MainActor
func pointerDownDoesNotCompileABrushProgram() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let spy = BrushProgramCompileSpy()

    BrushProgramCompiler.$testInvocationObserver.withValue({
        spy.record()
    }) {
        controller.handleStrokeSample(controllerSample(.began))
        controller.handleStrokeSample(controllerSample(.cancelled))
    }

    #expect(spy.count == 0)
}

@Test
@MainActor
func anchorCatalogInitializesAllProgramsBeforePointerInputInFreshProcess()
    throws
{
    if ProcessInfo.processInfo.environment[
        "LAYA_TEST_FRESH_ANCHOR_CATALOG"
    ] == "1" {
        guard let renderer = try makeControllerRenderer() else { return }
        let spy = BrushProgramCompileSpy()

        BrushProgramCompiler.$testInvocationObserver.withValue({
            spy.record()
        }) {
            let model = EditorModel()
            #expect(spy.count == 1)
            #expect(model.selectedProgram == AnchorBrushCatalog.ink.program)
            #expect(AnchorBrushCatalog.all.count == 6)
            #expect(spy.count == 6)

            let controller = EditorSessionController(
                model: model,
                renderer: renderer
            )
            controller.handleTool(.erase)
            controller.handleStrokeSample(controllerSample(.began))
            controller.handleStrokeSample(controllerSample(.cancelled))
            #expect(spy.count == 6)
        }
        return
    }

    let result = try runFreshAnchorCatalogSubprocess()
    if result.status != 0 {
        Issue.record(
            "Fresh catalog subprocess failed: \(result.standardError)"
        )
    }
    #expect(result.status == 0)
}

private func runFreshAnchorCatalogSubprocess()
    throws -> (status: Int32, standardError: String)
{
    let testExecutablePath = editorControllerTestExecutablePath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
        "--test-bundle-path", testExecutablePath,
        "--filter",
        "anchorCatalogInitializesAllProgramsBeforePointerInputInFreshProcess",
        testExecutablePath,
        "--testing-library", "swift-testing",
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["LAYA_TEST_FRESH_ANCHOR_CATALOG": "1"],
        uniquingKeysWith: { _, new in new }
    )
    process.standardOutput = FileHandle.nullDevice
    let standardError = Pipe()
    process.standardError = standardError

    try process.run()
    process.waitUntilExit()
    let errorOutput = String(
        decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    return (process.terminationStatus, errorOutput)
}

private func editorControllerTestExecutablePath() -> String {
    guard
        let optionIndex = CommandLine.arguments.firstIndex(
            of: "--test-bundle-path"
        ),
        CommandLine.arguments.indices.contains(optionIndex + 1)
    else {
        preconditionFailure("Swift Testing test executable path is unavailable")
    }
    return CommandLine.arguments[optionIndex + 1]
}
#endif

@Test
@MainActor
func controllerDefersEstimatedEndAndCommitsResolvedStrokeExactlyOnce()
    throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var reportedErrors: [MetalRendererError] = []
    controller.onError = { reportedErrors.append($0) }
    controller.handleStrokeSample(controllerSample(.began))
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .ended,
            kind: .actual,
            index: 44,
            pressure: 0.2,
            expecting: [.pressure]
        )
    )

    guard case let .drawing(waiting) = controller.transactionStateForTesting
    else {
        Issue.record("Expected stroke to await estimated properties")
        return
    }
    #expect(waiting.phase == .awaitingEstimatedUpdates)
    #expect(controller.lastRecordedRasterCommandForTesting == nil)

    let resolved = estimatedControllerSample(
        phase: .moved,
        kind: .estimatedUpdate,
        index: 44,
        pressure: 0.9,
        expecting: []
    )
    controller.handleStrokeSample(resolved)
    #expect(reportedErrors.isEmpty)
    guard case let .drawing(committing) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected resolved stroke commit")
        return
    }
    #expect(committing.phase == .commitPending)
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
    let firstCommand = try #require(
        controller.lastRecordedRasterCommandForTesting
    )

    controller.handleStrokeSample(resolved)
    #expect(controller.lastRecordedRasterCommandForTesting == firstCommand)
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
@MainActor
func cancellingWhileAwaitingEstimatesDiscardsWithoutHistory() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleStrokeSample(controllerSample(.began))
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .ended,
            kind: .actual,
            index: 45,
            pressure: 0.3,
            expecting: [.pressure]
        )
    )
    controller.handleStrokeSample(controllerSample(.cancelled))

    #expect(controller.transactionStateForTesting == .idle)
    #expect(controller.lastRecordedRasterCommandForTesting == nil)
    #expect(renderer.isIdle)
}

@Test
@MainActor
func newPointerFinalizesEstimateFallbackThenBeginsDeferredStroke() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleStrokeSample(controllerSample(.began))
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .ended,
            kind: .actual,
            index: 46,
            pressure: 0.3,
            expecting: [.pressure]
        )
    )

    controller.handleStrokeSample(controllerSample(.began, x: 40))
    guard case let .drawing(committing) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected fallback commit before deferred pointer")
        return
    }
    #expect(committing.phase == .commitPending)

    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()

    guard case let .drawing(collecting) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected deferred pointer to begin after commit")
        return
    }
    #expect(collecting.phase == .collecting)
    #expect(renderer.hasActiveStroke)
    let firstCommand = try #require(
        controller.lastRecordedRasterCommandForTesting
    )

    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .moved,
            kind: .estimatedUpdate,
            index: 46,
            pressure: 0.9,
            expecting: []
        )
    )
    #expect(controller.lastRecordedRasterCommandForTesting == firstCommand)
    controller.handleStrokeSample(controllerSample(.cancelled, x: 40))
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
@MainActor
func movedBatchTracksEstimateUntilASeparateUpdateResolvesIt() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleStrokeSample(controllerSample(.began, x: 16))
    controller.handleStrokeSamples([
        estimatedControllerSample(
            phase: .moved,
            kind: .actual,
            index: 48,
            pressure: 0.2,
            expecting: [.pressure],
            x: 24,
            timestamp: 1
        ),
        controllerMovedSample(x: 32, timestamp: 2, kind: .coalesced),
    ])
    controller.handleStrokeSample(controllerSample(.ended, x: 40))

    guard case let .drawing(waiting) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected batched estimate to defer the commit")
        return
    }
    #expect(waiting.phase == .awaitingEstimatedUpdates)

    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .moved,
            kind: .estimatedUpdate,
            index: 48,
            pressure: 0.9,
            expecting: [],
            estimated: [],
            x: 24,
            timestamp: 3
        )
    )
    guard case let .drawing(committing) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected resolution to request one commit")
        return
    }
    #expect(committing.phase == .commitPending)
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
@MainActor
func completeDeferredPointerStreamReplaysAfterPriorCommit() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleStrokeSample(controllerSample(.began, x: 12))
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .ended,
            kind: .actual,
            index: 49,
            pressure: 0.3,
            expecting: [.pressure],
            x: 20
        )
    )

    controller.handleStrokeSample(controllerSample(.began, x: 36))
    controller.handleStrokeSample(
        controllerMovedSample(x: 44, timestamp: 3, kind: .actual)
    )
    controller.handleStrokeSample(controllerSample(.ended, x: 52))

    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    guard case let .drawing(secondCommit) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected the complete deferred stroke to replay")
        return
    }
    #expect(secondCommit.phase == .commitPending)

    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
    #expect(renderer.harnessRevision.rawValue == 2)
}

@Test
@MainActor
func deferredPointerCanReuseAnOldEstimatedUpdateIndex() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleStrokeSample(
        controllerSample(.began, x: 12),
        inputGeneration: 2_001
    )
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .ended,
            kind: .actual,
            index: 52,
            pressure: 0.3,
            expecting: [.pressure],
            x: 20
        ),
        inputGeneration: 2_001
    )

    controller.handleStrokeSample(
        controllerSample(.began, x: 36),
        inputGeneration: 2_002
    )
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .moved,
            kind: .actual,
            index: 52,
            pressure: 0.2,
            expecting: [.pressure],
            x: 44,
            timestamp: 3
        ),
        inputGeneration: 2_002
    )
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .moved,
            kind: .estimatedUpdate,
            index: 52,
            pressure: 0.8,
            expecting: [],
            estimated: [],
            x: 44,
            timestamp: 4
        ),
        inputGeneration: 2_002
    )
    controller.handleStrokeSample(
        controllerSample(.ended, x: 52),
        inputGeneration: 2_002
    )

    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    guard case let .drawing(secondCommit) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected reused index update to reach deferred stroke")
        return
    }
    #expect(secondCommit.phase == .commitPending)
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
@MainActor
func deferredPointerRejectsLatePriorGenerationUpdateForReusedIndex()
    throws
{
    func render(includeLatePriorUpdate: Bool) throws -> [UInt8]? {
        guard let renderer = try makeControllerRenderer() else {
            return nil
        }
        let controller = EditorSessionController(
            renderer: renderer,
            strokeSeedSessionEntropy: 0xD3FE_2233_4455_6677
        )
        controller.handleStrokeSample(
            controllerSample(.began, x: 12, timestamp: 1),
            inputGeneration: 1_001
        )
        controller.handleStrokeSample(
            estimatedControllerSample(
                phase: .ended,
                kind: .actual,
                index: 58,
                pressure: 0.3,
                expecting: [.pressure],
                x: 20,
                timestamp: 2
            ),
            inputGeneration: 1_001
        )

        controller.handleStrokeSample(
            controllerSample(.began, x: 36, timestamp: 2),
            inputGeneration: 1_002
        )
        controller.handleStrokeSample(
            estimatedControllerSample(
                phase: .moved,
                kind: .actual,
                index: 58,
                pressure: 0.2,
                expecting: [.pressure],
                x: 44,
                timestamp: 2
            ),
            inputGeneration: 1_002
        )
        if includeLatePriorUpdate {
            controller.handleStrokeSample(
                estimatedControllerSample(
                    phase: .moved,
                    kind: .estimatedUpdate,
                    index: 58,
                    pressure: 0.05,
                    expecting: [],
                    estimated: [],
                    x: 20,
                    timestamp: 2
                ),
                inputGeneration: 1_001
            )
        }
        controller.handleStrokeSample(
            estimatedControllerSample(
                phase: .moved,
                kind: .estimatedUpdate,
                index: 58,
                pressure: 0.9,
                expecting: [],
                estimated: [],
                x: 44,
                timestamp: 2
            ),
            inputGeneration: 1_002
        )
        controller.handleStrokeSample(
            controllerSample(.ended, x: 52, timestamp: 2),
            inputGeneration: 1_002
        )

        _ = try renderer.flushPendingLiveForHarness()
        _ = try renderer.finishCommitForHarness()
        guard case let .drawing(secondCommit) =
            controller.transactionStateForTesting
        else {
            Issue.record("Expected deferred stroke to request its commit")
            return nil
        }
        #expect(secondCommit.phase == .commitPending)
        _ = try renderer.flushPendingLiveForHarness()
        _ = try renderer.finishCommitForHarness()
        #expect(controller.transactionStateForTesting == .idle)
        return try canonicalBytes(renderer)
    }

    let expectedResult = try render(includeLatePriorUpdate: false)
    let interleavedResult = try render(includeLatePriorUpdate: true)
    let expected = try #require(expectedResult)
    let interleaved = try #require(interleavedResult)
    #expect(interleaved.elementsEqual(expected))
}

@Test
@MainActor
func deferredPointerOverflowCancelsInsteadOfReplayingPartialInput() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleStrokeSample(controllerSample(.began, x: 12))
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .ended,
            kind: .actual,
            index: 53,
            pressure: 0.3,
            expecting: [.pressure],
            x: 20
        )
    )

    controller.handleStrokeSample(controllerSample(.began, x: 36))
    for index in 0..<TransientStrokeBufferContract
        .wholeStrokeSampleCapacity
    {
        controller.handleStrokeSample(
            controllerMovedSample(
                x: 40 + Float(index % 8),
                timestamp: TimeInterval(index + 3),
                kind: .actual
            )
        )
    }
    controller.handleStrokeSample(controllerSample(.ended, x: 52))

    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
    #expect(renderer.isIdle)
    #expect(renderer.harnessRevision.rawValue == 1)
}

@Test
@MainActor
func cancellingWhileCommitIsPendingDiscardsDeferredPointerStream() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleStrokeSample(controllerSample(.began, x: 12))
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .ended,
            kind: .actual,
            index: 55,
            pressure: 0.3,
            expecting: [.pressure],
            x: 20
        )
    )

    controller.handleStrokeSample(controllerSample(.began, x: 36))
    controller.handleStrokeSample(
        controllerMovedSample(x: 44, timestamp: 3, kind: .actual)
    )
    controller.cancelTransientEdit()

    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
    #expect(renderer.isIdle)
    #expect(renderer.harnessRevision.rawValue == 1)
}

@Test
@MainActor
func ignoredToolInputDoesNotLeakEstimatedStateIntoNextStroke() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleTool(.select)
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .began,
            kind: .actual,
            index: 56,
            pressure: 0.2,
            expecting: [.pressure],
            x: 16
        )
    )
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .moved,
            kind: .actual,
            index: 57,
            pressure: 0.3,
            expecting: [.pressure],
            x: 24
        )
    )

    controller.handleTool(.draw)
    controller.handleStrokeSample(controllerSample(.began, x: 36))
    controller.handleStrokeSample(controllerSample(.ended, x: 44))
    guard case let .drawing(committing) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected ordinary stroke to ignore stale estimates")
        return
    }
    #expect(committing.phase == .commitPending)
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
@MainActor
func failedEstimatedFallbackCommitLeavesRendererReusable() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(
        renderer: renderer,
        historyMaximumBytes: 0
    )
    controller.handleStrokeSample(controllerSample(.began, x: 16))
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .ended,
            kind: .actual,
            index: 50,
            pressure: 0.2,
            expecting: [.pressure],
            x: 24
        )
    )
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .moved,
            kind: .estimatedUpdate,
            index: 50,
            pressure: 0.8,
            expecting: [],
            estimated: [],
            x: 24
        )
    )

    #expect(controller.transactionStateForTesting == .idle)
    #expect(renderer.isIdle)

    controller.handleStrokeSample(controllerSample(.began, x: 40))
    #expect(renderer.hasActiveStroke)
    controller.handleStrokeSample(controllerSample(.cancelled, x: 40))
    #expect(renderer.isIdle)
}

@Test
@MainActor
func cancellationClearsPendingEstimateBookkeepingForNextStroke() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleStrokeSample(controllerSample(.began, x: 16))
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .moved,
            kind: .actual,
            index: 51,
            pressure: 0.2,
            expecting: [.pressure],
            x: 24
        )
    )
    controller.cancelTransientEdit()
    #expect(renderer.isIdle)

    controller.handleStrokeSample(controllerSample(.began, x: 36))
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .moved,
            kind: .actual,
            index: 54,
            pressure: 0.3,
            expecting: [.pressure],
            x: 40
        )
    )
    controller.handleTool(.erase)
    #expect(renderer.isIdle)
    #expect(controller.model.tool == .erase)

    controller.handleTool(.draw)
    controller.handleStrokeSample(controllerSample(.began, x: 44))
    controller.handleStrokeSample(controllerSample(.ended, x: 52))
    guard case let .drawing(committing) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected ordinary stroke to commit without stale waits")
        return
    }
    #expect(committing.phase == .commitPending)
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
@MainActor
func synchronousRendererFailureClearsEstimateBookkeeping() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleStrokeSample(controllerSample(.began, x: 16))
    guard case let .drawing(drawing) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected active drawing transaction")
        return
    }
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .moved,
            kind: .actual,
            index: 55,
            pressure: 0.2,
            expecting: [.pressure],
            x: 24
        )
    )
    try renderer.cancelStroke(
        token: RendererOperationToken(rawValue: drawing.token.rawValue)
    )
    controller.handleStrokeSample(
        controllerMovedSample(x: 28, timestamp: 2, kind: .actual)
    )
    #expect(controller.transactionStateForTesting == .idle)

    controller.handleStrokeSample(controllerSample(.began, x: 36))
    controller.handleStrokeSample(controllerSample(.ended, x: 44))
    guard case let .drawing(committing) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected next stroke to commit after failure cleanup")
        return
    }
    #expect(committing.phase == .commitPending)
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
@MainActor
func focusLossFinalizesAwaitingEstimateExactlyOnce() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleStrokeSample(controllerSample(.began))
    controller.handleStrokeSample(
        estimatedControllerSample(
            phase: .ended,
            kind: .actual,
            index: 47,
            pressure: 0.3,
            expecting: [.pressure]
        )
    )

    controller.handleFocusLoss()
    guard case let .drawing(committing) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected focus-loss fallback commit")
        return
    }
    #expect(committing.phase == .commitPending)
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
    let firstCommand = try #require(
        controller.lastRecordedRasterCommandForTesting
    )

    controller.handleFocusLoss()
    #expect(controller.lastRecordedRasterCommandForTesting == firstCommand)
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
func strokeSeedDerivationIsDeterministicNonzeroAndSessionScoped() {
    let firstEntropy: UInt64 = 0x0123_4567_89AB_CDEF
    let secondEntropy: UInt64 = 0xFEDC_BA98_7654_3210
    let first = (UInt64(1)...512).map {
        EditorSessionController.derivedStrokeSeed(
            sequence: $0,
            sessionEntropy: firstEntropy
        )
    }
    let repeated = (UInt64(1)...512).map {
        EditorSessionController.derivedStrokeSeed(
            sequence: $0,
            sessionEntropy: firstEntropy
        )
    }
    let secondSession = (UInt64(1)...512).map {
        EditorSessionController.derivedStrokeSeed(
            sequence: $0,
            sessionEntropy: secondEntropy
        )
    }

    #expect(first == repeated)
    #expect(first.allSatisfy { $0 != 0 })
    #expect(Set(first).count == first.count)
    #expect(first != secondSession)
}

@Test
@MainActor
func controllerSubmitsPredictedMovesAsOneReplaceableSuffixBatch() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleRecipe(AnchorBrushCatalog.marker.id)
    controller.handleStrokeSample(controllerSample(.began, x: 16, y: 32))

    controller.handleStrokeSamples([
        controllerMovedSample(x: 24, timestamp: 1, kind: .predicted),
        controllerMovedSample(x: 40, timestamp: 2, kind: .predicted),
    ])
    #expect(renderer.transientStrokeBuffer?.predictedSampleCount == 2)
    #expect(
        renderer.transientStrokeBuffer?.predictedSamples.map(\.position.x)
            == [24, 40]
    )

    controller.handleStrokeSamples([
        controllerMovedSample(x: 28, timestamp: 1, kind: .predicted),
        controllerMovedSample(x: 34, timestamp: 2, kind: .predicted),
    ])
    #expect(renderer.transientStrokeBuffer?.predictedSampleCount == 2)
    #expect(
        renderer.transientStrokeBuffer?.predictedSamples.map(\.position.x)
            == [28, 34]
    )

    controller.handleStrokeSample(
        controllerMovedSample(x: 30, timestamp: 2, kind: .actual)
    )
    #expect(renderer.transientStrokeBuffer?.predictedSampleCount == 0)
    controller.handleStrokeSample(controllerSample(.cancelled))
    #expect(renderer.isIdle)
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
