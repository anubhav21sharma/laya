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
    finiteConfiguration: FiniteSymmetryConfiguration? = nil,
    historyByteBudget: Int = 200 * 1_024 * 1_024,
    layerStack: LayerStack = .initial()
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
    let renderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 64, height: 64),
        configuration: canvasConfiguration,
        initialLayerStack: layerStack,
        historyByteBudget: historyByteBudget
    )
    try renderer.installNativeHarnessBrushes()
    return renderer
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

@MainActor
func makeNativeTestLibrary(
    device: any MTLDevice
) throws -> any MTLLibrary {
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
    return library
}

@MainActor
func makeNativeDepositionPipelineLibrary(
    device: any MTLDevice
) throws -> DepositionPipelineLibrary {
    DepositionPipelineLibrary(
        device: device,
        library: try makeNativeTestLibrary(device: device)
    )
}

@MainActor
func makeNativeCompiler(
    renderer: GridRenderer
) throws -> BrushCompiler {
    guard let queue = renderer.device.makeCommandQueue() else {
        throw MetalRendererError.commandQueueUnavailable
    }
    return try BrushCompiler(
        device: renderer.device,
        commandQueue: queue,
        profile: BrushDeviceProfile(
            registryID: renderer.device.registryID,
            recommendedWorkingSetBytes: 1_024 * 1_024 * 1_024,
            maximumWorkingTextureDimension: 4_096,
            brushCacheBudgetBytes: 128 * 1_024 * 1_024,
            targetFramesPerSecond: 120
        ),
        pipelineLibrary: try makeNativeDepositionPipelineLibrary(
            device: renderer.device
        )
    )
}

@MainActor
private final class GatedSelectionCompiler {
    private var pending:
        [(BrushRecipeID, CheckedContinuation<CompiledBrush, Error>)] = []

    var pendingIDs: [BrushRecipeID] {
        pending.map(\.0)
    }

    func compile(_ definition: BrushDefinition) async throws -> CompiledBrush {
        try await withCheckedThrowingContinuation { continuation in
            pending.append((definition.id, continuation))
        }
    }

    func complete(
        _ id: BrushRecipeID,
        with brush: CompiledBrush
    ) throws {
        guard let index = pending.firstIndex(where: { $0.0 == id }) else {
            throw GatedSelectionCompilerError.missingPendingSelection(id)
        }
        let continuation = pending.remove(at: index).1
        continuation.resume(returning: brush)
    }
}

private enum GatedSelectionCompilerError: Error {
    case missingPendingSelection(BrushRecipeID)
}

@MainActor
private final class RecordingBrushSelectionStore:
    EditorBrushSelectionStore
{
    var storedID: String?
    private(set) var writes: [String] = []

    init(storedID: String? = nil) {
        self.storedID = storedID
    }

    func readSelectedBrushID() -> String? {
        storedID
    }

    func writeSelectedBrushID(_ id: String) {
        storedID = id
        writes.append(id)
    }
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
) async throws {
    controller.handleStrokeSample(controllerSample(.began, x: x, y: y))
    controller.handleStrokeSample(controllerSample(.ended, x: x, y: y))
    _ = try await renderer.finishCommitForHarness()
}

@MainActor
private func awaitControllerRendererIdleForHarness(
    _ renderer: GridRenderer
) throws {
    try renderer.drainStrokeWorkspaceRetirementForHarness()
    #expect(renderer.isIdle)
}

@MainActor
private func awaitControllerPaintOperationForHarness(
    _ controller: EditorSessionController,
    renderer: GridRenderer
) async throws {
    for _ in 0..<20_000 {
        if !controller.model.isBusy, renderer.isIdle { return }
        await Task.yield()
    }
    Issue.record("Controller paint operation did not settle")
}

@MainActor
private func awaitPaintRevisionReleaseForHarness(
    _ renderer: GridRenderer
) async {
    for _ in 0..<20_000 {
        if await renderer.paintStateSnapshotForTesting()
            .revisionResidentBytes == 0
        {
            return
        }
        await Task.yield()
    }
    Issue.record("Controller paint revision release did not settle")
}

@MainActor
private func awaitActorTransientSamples(
    _ renderer: GridRenderer,
    predictedXs: [Float],
    minimumTransientMutationVersion: UInt64? = nil
) async throws -> StrokeTransientPreparationSnapshot {
    var lastSnapshot: StrokeTransientPreparationSnapshot?
    var lastScheduler: StrokeFrameSchedulerSnapshot?
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if !renderer.strokePreparationIsQuiescentForAllocationHarness {
            _ = try await renderer.renderCurrentPaintFrameForHarness(
                width: renderer.pixelSize.width,
                height: renderer.pixelSize.height,
                includeTransient: true
            )
        }
        let snapshot = await renderer.offMainTransientSnapshotForTesting()
        let scheduler = await renderer.offMainSchedulerSnapshotForTesting()
        lastSnapshot = snapshot
        lastScheduler = scheduler
        let predicted = snapshot.predictedSamples.map(\.position.x)
        let mutationMatches = minimumTransientMutationVersion.map {
            scheduler.transientMutationVersion >= $0
        } ?? true
        if predicted == predictedXs, mutationMatches {
            return snapshot
        }
        await Task.yield()
    }
    let actualXs = lastSnapshot?.actualSamples.map(\.position.x) ?? []
    let predictedActualXs =
        lastSnapshot?.predictedSamples.map(\.position.x) ?? []
    throw MetalRendererError.commandFailed(
        "actor transient sample snapshot did not reach expected state "
            + "actual=\(actualXs) predicted=\(predictedActualXs) "
            + "expectedPredicted=\(predictedXs) "
            + "retainedActual=\(lastScheduler?.retainedActualSampleCount ?? -1) "
            + "mutation=\(lastScheduler?.transientMutationVersion ?? 0)"
    )
}

@MainActor
private func finishControllerCommitAndAwaitDeferredStroke(
    _ controller: EditorSessionController,
    renderer: GridRenderer
) async throws {
    guard case let .drawing(priorDrawing) =
        controller.transactionStateForTesting
    else { throw MetalRendererError.invalidStrokeLifecycle }
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if case let .drawing(drawing) =
            controller.transactionStateForTesting,
           drawing.token != priorDrawing.token
        {
            return
        }
        _ = try await renderer.renderCurrentPaintFrameForHarness(
            width: renderer.pixelSize.width,
            height: renderer.pixelSize.height,
            includeTransient: true
        )
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "deferred controller stroke did not resume after workspace retirement"
    )
}

@Test
@MainActor
func controllerStartsInFiniteDomainAndCanSwitchOnlyBeforeRasterEdit()
    async throws
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
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(renderer.finiteConfiguration == .radial(revised))
    #expect(controller.model.radialConfiguration == revised)
    #expect(!controller.historyAvailabilityForTesting.canUndo)

    let periodic = PeriodicSymmetryConfiguration.defaultConfiguration(
        presetID: .halfDrop,
        canonicalRasterSize: PixelSize(width: 64, height: 64)
    )
    controller.handlePeriodicConfiguration(periodic)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(renderer.documentConfiguration == .periodic(periodic))
    #expect(controller.model.documentConfiguration == .periodic(periodic))
    #expect(
        controller.model.pixelSize
            == EditorConfiguration.defaultPeriodicPixelSize
    )
    #expect(!controller.historyAvailabilityForTesting.canUndo)

    controller.handleFiniteConfiguration(.plain)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(renderer.documentConfiguration == .finite(.plain))
    #expect(controller.model.documentConfiguration == .finite(.plain))
    #expect(
        controller.model.pixelSize
            == EditorConfiguration.defaultFinitePixelSize
    )
}

@Test
@MainActor
func blankModeSelectionUsesFiniteAndPeriodicDefaults() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.selectPlainCanvasMode()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(renderer.documentConfiguration == .finite(.plain))
    #expect(renderer.pixelSize == PixelSize(width: 2_048, height: 2_048))
    #expect(
        renderer.viewport.worldCenter
            == WorldPoint(x: 1_024, y: 1_024)
    )

    controller.selectRadialMode()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    let radial = try #require(controller.model.radialConfiguration)
    #expect(renderer.pixelSize == PixelSize(width: 2_048, height: 2_048))
    #expect(radial.kind == .mandala)
    #expect(radial.rayCount == 8)
    #expect(radial.center == WorldPoint(x: 1_024, y: 1_024))

    controller.selectSeamlessPatternMode()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(
        renderer.documentConfiguration
            == .periodic(controller.model.periodicConfiguration)
    )
    #expect(renderer.pixelSize == PixelSize(width: 256, height: 256))
    #expect(renderer.viewport.worldCenter == WorldPoint(x: 128, y: 128))
}

@Test
@MainActor
func undoingFirstRadialEditUnlocksAndAllowsModeChange() async throws {
    guard let renderer = try makeControllerRenderer(
        finiteConfiguration: .radial(controllerRadialConfiguration)
    ) else { return }
    let controller = EditorSessionController(renderer: renderer)

    try await commitControllerStroke(controller, renderer: renderer, x: 47, y: 34)
    #expect(controller.model.documentDomainLocked)
    #expect(controller.model.radialGeometryLocked)

    controller.undo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(!controller.model.documentDomainLocked)
    #expect(!controller.model.radialGeometryLocked)
    #expect(controller.model.canRedo)

    controller.selectSeamlessPatternMode()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
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
func lockedRadialGeometryChangeReportsRadialLock() async throws {
    guard let renderer = try makeControllerRenderer(
        finiteConfiguration: .radial(controllerRadialConfiguration)
    ) else { return }
    let controller = EditorSessionController(renderer: renderer)
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }
    try await commitControllerStroke(controller, renderer: renderer, x: 47, y: 34)

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
func plainAndSeamlessLocksFollowCommittedContentState() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }

    controller.selectPlainCanvasMode()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    try await commitControllerStroke(
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
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(!controller.model.documentDomainLocked)

    controller.selectSeamlessPatternMode()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(renderer.pixelSize == PixelSize(width: 256, height: 256))
    try await commitControllerStroke(controller, renderer: renderer)
    #expect(controller.model.documentDomainLocked)

    controller.clear()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(!controller.model.documentDomainLocked)

    controller.selectRadialMode()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(renderer.pixelSize == PixelSize(width: 2_048, height: 2_048))
    #expect(controller.model.radialConfiguration?.center == WorldPoint(
        x: 1_024,
        y: 1_024
    ))
}

@Test
@MainActor
func redoAndUndoClearReconcileRadialLocksWithVisibleHistoryState() async throws {
    guard let renderer = try makeControllerRenderer(
        finiteConfiguration: .radial(controllerRadialConfiguration)
    ) else { return }
    let controller = EditorSessionController(renderer: renderer)

    try await commitControllerStroke(controller, renderer: renderer, x: 47, y: 34)
    let stroke = try #require(controller.lastRecordedRasterCommandForTesting)

    controller.undo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(!controller.model.radialGeometryLocked)

    controller.redo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.documentDomainLocked)
    #expect(controller.model.radialGeometryLocked)

    controller.clear()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    let clear = try #require(controller.lastRecordedRasterCommandForTesting)
    #expect(!controller.model.documentDomainLocked)
    #expect(!controller.model.radialGeometryLocked)

    controller.undo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.documentDomainLocked)
    #expect(controller.model.radialGeometryLocked)

    controller.redo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(!controller.model.documentDomainLocked)
    #expect(!controller.model.radialGeometryLocked)

    try await renderer.releasePaintRevisions(
        Set(
            [stroke, clear].flatMap {
                [$0.before.id, $0.after.id]
            }
        )
    )
}

@Test
@MainActor
func resizingBlankDocumentKeepsModeEditable() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.handleTileSize(PixelSize(width: 96, height: 80))
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )

    #expect(!controller.model.documentDomainLocked)
    controller.selectPlainCanvasMode()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(renderer.documentConfiguration == .finite(.plain))
}

@Test
@MainActor
func rasterSuccessRecordsTheCapturedEraseTool() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleTool(.erase)
    try await commitControllerStroke(controller, renderer: renderer)

    let command = try #require(controller.lastRecordedRasterCommandForTesting)
    #expect(command.layerID == LayerStack.initialLayerID)
    #expect(command.kind == .erase)
    #expect(controller.model.canUndo)
    #expect(!controller.model.canRedo)
    #expect(!controller.model.isBusy)
    #expect(renderer.isIdle)

    try await renderer.releasePaintRevisions([command.before.id, command.after.id])
}

@Test
@MainActor
func layerBoundHistorySurvivesReorderAndActiveLayerChanges() async throws {
    let compatibility = try LayerDescriptor(
        id: LayerStack.initialLayerID,
        name: "Compatibility"
    )
    let second = try LayerDescriptor(
        id: controllerLayerID(2),
        name: "Second"
    )
    let stack = try LayerStack(
        layers: [compatibility, second],
        activeLayerID: compatibility.id
    )
    guard let renderer = try makeControllerRenderer(layerStack: stack)
    else { return }
    let controller = EditorSessionController(
        renderer: renderer,
        layerStack: stack
    )

    try await commitControllerStroke(controller, renderer: renderer)
    let raster = try #require(controller.lastRecordedRasterCommandForTesting)
    #expect(raster.layerID == compatibility.id)
    try controller.moveLayer(compatibility.id, to: 1)
    try controller.setActiveLayer(second.id)

    controller.undo()
    #expect(controller.layerStackForTesting.activeLayerID == compatibility.id)
    controller.undo()
    #expect(
        controller.layerStackForTesting.orderedLayerIDs
            == [compatibility.id, second.id]
    )
    controller.undo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )

    controller.redo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    try await renderer.releasePaintRevisions([raster.before.id, raster.after.id])
}

@Test
@MainActor
func layerMutationIsRejectedWhileDrawingWithoutChangingTheStack() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let before = controller.layerStackForTesting
    controller.handleStrokeSample(controllerSample(.began))

    #expect(throws: EditorSessionLayerError.mutationRequiresIdle) {
        try controller.renameLayer(
            LayerStack.initialLayerID,
            to: "Changed"
        )
    }
    #expect(controller.layerStackForTesting == before)

    controller.handleStrokeSample(controllerSample(.cancelled))
    try awaitControllerRendererIdleForHarness(renderer)
}

@Test
@MainActor
func layerDeletionCapturesBeforeRemovalAndUndoRedoStayAtomic() throws {
    let compatibility = try LayerDescriptor(
        id: LayerStack.initialLayerID,
        name: "Compatibility"
    )
    let target = try LayerDescriptor(
        id: controllerLayerID(20),
        name: "Target",
        isVisible: false,
        opacity: 0.375,
        isLocked: true,
        blendMode: .screen
    )
    let fallback = try LayerDescriptor(
        id: controllerLayerID(21),
        name: "Fallback"
    )
    let stack = try LayerStack(
        layers: [compatibility, target, fallback],
        activeLayerID: target.id
    )
    guard let renderer = try makeControllerRenderer(layerStack: stack)
    else { return }
    let controller = EditorSessionController(
        renderer: renderer,
        layerStack: stack
    )

    try controller.moveLayer(target.id, to: 2)
    try controller.deleteLayer(target.id)

    #expect(
        controller.layerStackForTesting.orderedLayerIDs
            == [compatibility.id, fallback.id]
    )
    #expect(controller.layerStackForTesting.activeLayerID == fallback.id)
    let deletionRevision = try #require(
        controller.lastRecordedLayerRevisionForTesting
    )
    #expect(renderer.containsLayerRevision(deletionRevision.id))

    controller.undo()
    #expect(
        controller.layerStackForTesting.layers
            == [compatibility, fallback, target]
    )
    #expect(controller.layerStackForTesting.activeLayerID == target.id)
    #expect(controller.historyAvailabilityForTesting.canRedo)

    controller.redo()
    #expect(controller.layerStackForTesting.layer(id: target.id) == nil)
    #expect(controller.layerStackForTesting.activeLayerID == fallback.id)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
}

@Test
@MainActor
func layerDeletionFailuresPreserveMetadataAndHistoryCursor() async throws {
    let compatibility = try LayerDescriptor(
        id: LayerStack.initialLayerID,
        name: "Compatibility"
    )
    let target = try LayerDescriptor(
        id: controllerLayerID(22),
        name: "Target"
    )
    let stack = try LayerStack(
        layers: [compatibility, target],
        activeLayerID: target.id
    )
    guard let renderer = try makeControllerRenderer(layerStack: stack)
    else { return }
    let controller = EditorSessionController(
        renderer: renderer,
        layerStack: stack
    )
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }
    try controller.deleteLayer(target.id)
    let deleted = controller.layerStackForTesting
    let revision = try #require(
        controller.lastRecordedLayerRevisionForTesting
    )

    try await renderer.releasePaintRevisions([revision.id])
    controller.undo()
    #expect(controller.layerStackForTesting == deleted)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(errors.count == 1)
}

@Test
@MainActor
func layerDeletionDefaultRouteUsesAtomicRendererStorage()
    throws
{
    let compatibility = try LayerDescriptor(
        id: LayerStack.initialLayerID,
        name: "Compatibility"
    )
    let target = try LayerDescriptor(
        id: controllerLayerID(23),
        name: "Target"
    )
    let stack = try LayerStack(
        layers: [compatibility, target],
        activeLayerID: target.id
    )
    guard let renderer = try makeControllerRenderer(layerStack: stack)
    else { return }
    let controller = EditorSessionController(
        renderer: renderer,
        layerStack: stack
    )

    try controller.deleteLayer(target.id)
    #expect(controller.layerStackForTesting.layer(id: target.id) == nil)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
}

@Test
@MainActor
func missingHistoryTargetFailsBeforeRendererMutationAndPreservesCursor()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let size = PixelSize(width: 64, height: 64)
    let regions = PixelRegionSet(
        [PixelRect(minX: 0, minY: 0, maxX: 1, maxY: 1)!],
        clippedTo: size
    )
    let missingLayerID = controllerLayerID(99)
    let before = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: 900),
        pixelSize: size,
        documentPixelSize: size,
        regions: regions,
        retainedBytes: 8,
        storage: .tiledRGBA16Float(
            layerID: missingLayerID,
            generation: 900,
            tileCoordinates: []
        )
    )
    let after = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: 901),
        pixelSize: size,
        documentPixelSize: size,
        regions: regions,
        retainedBytes: 8,
        storage: .tiledRGBA16Float(
            layerID: missingLayerID,
            generation: 901,
            tileCoordinates: []
        )
    )
    let history = DocumentHistory(initialDocumentIsEmpty: false)
    _ = history.appendSuccessful(.raster(RasterHistoryCommand(
        layerID: missingLayerID,
        kind: .draw,
        before: before,
        after: after
    )))
    let controller = EditorSessionController(
        renderer: renderer,
        documentHistory: history
    )
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }
    let bytes = try await canonicalBytes(renderer)

    controller.undo()

    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(controller.transactionStateForTesting == .idle)
    #expect(try await canonicalBytes(renderer) == bytes)
    #expect(errors.count == 1)
}

@Test
@MainActor
func operationSuccessMovesUndoRedoOnlyAfterRendererCompletion() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    try await commitControllerStroke(controller, renderer: renderer, x: 20, y: 20)
    let first = try #require(controller.lastRecordedRasterCommandForTesting)
    try await commitControllerStroke(controller, renderer: renderer, x: 44, y: 44)
    _ = try #require(controller.lastRecordedRasterCommandForTesting)
    let afterSecond = try await canonicalBytes(renderer)

    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    controller.undo()
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(controller.model.isBusy)
    #expect(!controller.model.canUndo)
    #expect(!controller.model.canRedo)
    #expect(try await canonicalBytes(renderer) == afterSecond)

    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
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
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(controller.model.canUndo)
    #expect(!controller.model.canRedo)
    #expect(try await canonicalBytes(renderer) == afterSecond)

    controller.undo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    try await commitControllerStroke(controller, renderer: renderer, x: 32, y: 48)
    let replacement = try #require(
        controller.lastRecordedRasterCommandForTesting
    )

    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(!controller.model.canRedo)

    let retained = [first, replacement]
    try await renderer.releasePaintRevisions(
        Set(retained.flatMap { [$0.before.id, $0.after.id] })
    )
}

private func controllerLayerID(_ value: Int) -> UUID {
    UUID(uuidString: String(
        format: "00000000-0000-0000-0000-%012d",
        value
    ))!
}

@Test
@MainActor
func tilingChangeUndoRedoIsMetadataOnly() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let originalBytes = try await canonicalBytes(renderer)
    let originalPaint = await renderer.paintStateSnapshotForTesting()

    controller.handleTiling(.mirrorX)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.tiling == .mirrorX)
    #expect(renderer.tiling == .mirrorX)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(
        await renderer.paintStateSnapshotForTesting().revisionResidentBytes
            == 0
    )

    controller.undo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.tiling == .grid)
    #expect(renderer.tiling == .grid)
    #expect(controller.historyAvailabilityForTesting.canRedo)

    controller.redo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.tiling == .mirrorX)
    #expect(renderer.tiling == .mirrorX)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(try await canonicalBytes(renderer) == originalBytes)
    let finalPaint = await renderer.paintStateSnapshotForTesting()
    #expect(finalPaint.storeIdentity == originalPaint.storeIdentity)
    #expect(finalPaint.layerIDs == originalPaint.layerIDs)
    #expect(finalPaint.revisionResidentBytes == 0)
}

@Test
@MainActor
func periodicConfigurationChangeUndoRedoIsExactMetadataOnly() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let before = controller.model.periodicConfiguration
    let beforeBytes = try await canonicalBytes(renderer)
    let beforePaint = await renderer.paintStateSnapshotForTesting()
    let configuration = PeriodicSymmetryConfiguration(
        presetID: .squareKaleidoscope,
        repeatSize: PatternSize(width: 192, height: 192),
        orientationRadians: .pi / 6
    )

    controller.handlePeriodicConfiguration(configuration)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )

    #expect(controller.model.periodicConfiguration == configuration)
    #expect(renderer.periodicConfiguration == configuration)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(
        await renderer.paintStateSnapshotForTesting().revisionResidentBytes
            == 0
    )

    controller.undo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.periodicConfiguration == before)
    #expect(renderer.periodicConfiguration == before)
    #expect(controller.historyAvailabilityForTesting.canRedo)
    #expect(
        await renderer.paintStateSnapshotForTesting().revisionResidentBytes
            == 0
    )

    controller.redo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.periodicConfiguration == configuration)
    #expect(renderer.periodicConfiguration == configuration)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(try await canonicalBytes(renderer) == beforeBytes)
    let afterPaint = await renderer.paintStateSnapshotForTesting()
    #expect(afterPaint.storeIdentity == beforePaint.storeIdentity)
    #expect(afterPaint.layerIDs == beforePaint.layerIDs)
    #expect(afterPaint.revisionResidentBytes == 0)
}

@Test
@MainActor
func everyTriangularPresetLeavesEditorControlsResponsive() async throws {
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
        try await awaitControllerPaintOperationForHarness(
            controller,
            renderer: renderer
        )
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
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(try await canonicalBytes(renderer).allSatisfy { $0 == 0 })
    #expect(!controller.model.isBusy)
    #expect(renderer.isIdle)

}

@Test
@MainActor
func invalidPeriodicConfigurationFailsAtomicallyWithoutHistory() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }
    let beforeConfiguration = controller.model.periodicConfiguration
    let beforeBytes = try await canonicalBytes(renderer)
    let beforePaint = await renderer.paintStateSnapshotForTesting()
    let invalid = PeriodicSymmetryConfiguration(
        presetID: .squareRotation,
        repeatSize: PatternSize(width: 192, height: 160),
        orientationRadians: .pi / 4
    )

    controller.handlePeriodicConfiguration(invalid)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )

    #expect(controller.model.periodicConfiguration == beforeConfiguration)
    #expect(renderer.periodicConfiguration == beforeConfiguration)
    #expect(!controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(!controller.model.isBusy)
    #expect(renderer.isIdle)
    #expect(try await canonicalBytes(renderer) == beforeBytes)
    let afterPaint = await renderer.paintStateSnapshotForTesting()
    #expect(afterPaint.storeIdentity == beforePaint.storeIdentity)
    #expect(afterPaint.layerIDs == beforePaint.layerIDs)
    #expect(afterPaint.documentGeneration == beforePaint.documentGeneration)
    #expect(afterPaint.revisionResidentBytes == 0)
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
func cancellationFailureCannotStrandQueuedPeriodicIntentBusy() async throws {
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
    #expect(!renderer.isIdle)
    #expect(controller.model.periodicConfiguration == before)
    #expect(!controller.historyAvailabilityForTesting.canUndo)

    controller.handleTiling(.mirrorX)
    #expect(controller.model.isBusy)
    try awaitControllerRendererIdleForHarness(renderer)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.tiling == .mirrorX)
    #expect(!controller.model.isBusy)
}

@Test
@MainActor
func normalizedEquivalentPeriodicConfigurationDoesNotCreateHistory() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.handleTiling(.squareRotation)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    controller.undo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
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
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )

    #expect(controller.model.periodicConfiguration == before)
    #expect(renderer.periodicConfiguration == before)
    #expect(!controller.historyAvailabilityForTesting.canUndo)
    #expect(controller.historyAvailabilityForTesting.canRedo)
}

@Test
@MainActor
func tilingAfterUndoReleasesRasterRedoWithoutAllocatingMetadataPayload() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var reportedErrors: [MetalRendererError] = []
    controller.onError = { reportedErrors.append($0) }
    try await commitControllerStroke(controller, renderer: renderer)
    controller.undo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )

    controller.handleTiling(.mirrorY)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )

    #expect(!controller.historyAvailabilityForTesting.canRedo)
    await awaitPaintRevisionReleaseForHarness(renderer)
    #expect(
        await renderer.paintStateSnapshotForTesting().revisionResidentBytes
            == 0
    )
    #expect(reportedErrors.isEmpty, "reported errors: \(reportedErrors)")
}

@Test
@MainActor
func resizeHistoryFinalizesOnlyAfterInstallAndRestoresExactBytes() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let before = try await canonicalBytes(renderer)
    let newSize = PixelSize(width: 96, height: 80)

    controller.handleTileSize(newSize)
    #expect(controller.model.pixelSize == PixelSize(width: 64, height: 64))
    #expect(!controller.historyAvailabilityForTesting.canUndo)
    #expect(controller.model.isBusy)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )

    #expect(controller.model.pixelSize == newSize)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(!controller.model.isBusy)
    #expect(try await canonicalBytes(renderer) == [UInt8](
        repeating: 0,
        count: newSize.width * newSize.height * 4
    ))

    controller.undo()
    #expect(controller.model.pixelSize == PixelSize(width: 64, height: 64))
    #expect(controller.historyAvailabilityForTesting.canRedo)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.pixelSize == PixelSize(width: 64, height: 64))
    #expect(try await canonicalBytes(renderer) == before)
    #expect(controller.historyAvailabilityForTesting.canRedo)

    controller.redo()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.pixelSize == newSize)
    #expect(!controller.historyAvailabilityForTesting.canRedo)

    let resize = try #require(controller.lastRecordedResizeCommandForTesting)
    try await renderer.releasePaintRevisions([resize.layerRevision.id])
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
func brushChangeKeepsSubsequentEditorActionsCoherent() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.stepBrush(larger: true)
    #expect(controller.model.brushDiameter == 25)
    #expect(!controller.model.isBusy)

    var retainedRevisionIDs: Set<StoredRasterRevisionID> = []
    try await commitControllerStroke(controller, renderer: renderer)
    let draw = try #require(controller.lastRecordedRasterCommandForTesting)
    retainedRevisionIDs.formUnion([draw.before.id, draw.after.id])
    #expect(draw.kind == .draw)
    let drawnBytes = try await canonicalBytes(renderer)
    #expect(!drawnBytes.allSatisfy { $0 == 0 })

    controller.handleTool(.erase)
    #expect(controller.model.tool == .erase)
    try await commitControllerStroke(controller, renderer: renderer)
    let erase = try #require(controller.lastRecordedRasterCommandForTesting)
    retainedRevisionIDs.formUnion([erase.before.id, erase.after.id])
    #expect(erase.kind == .erase)
    let erasedBytes = try await canonicalBytes(renderer)
    let drawnAlpha = stride(from: 3, to: drawnBytes.count, by: 4)
        .reduce(0) { $0 + Int(drawnBytes[$1]) }
    let erasedAlpha = stride(from: 3, to: erasedBytes.count, by: 4)
        .reduce(0) { $0 + Int(erasedBytes[$1]) }
    #expect(erasedAlpha < drawnAlpha)

    controller.handleTool(.draw)
    try await commitControllerStroke(
        controller,
        renderer: renderer,
        x: 20,
        y: 20
    )
    let redraw = try #require(controller.lastRecordedRasterCommandForTesting)
    retainedRevisionIDs.formUnion([redraw.before.id, redraw.after.id])
    let redrawnBytes = try await canonicalBytes(renderer)
    #expect(!redrawnBytes.allSatisfy { $0 == 0 })

    controller.handleGridVisibility(true)
    controller.handleTiling(.halfDrop)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.showGrid)
    #expect(renderer.interactiveGridVisibility)
    #expect(controller.model.tiling == .halfDrop)
    #expect(renderer.tiling == .halfDrop)

    controller.clear()
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(try await canonicalBytes(renderer).allSatisfy { $0 == 0 })
    #expect(!controller.model.isBusy)

    let clear = try #require(controller.lastRecordedRasterCommandForTesting)
    retainedRevisionIDs.formUnion([clear.before.id, clear.after.id])
    try await renderer.releasePaintRevisions(retainedRevisionIDs)
}

@Test
@MainActor
func pointerDownCapturesPreparedNativeProgramsAndUniqueNonzeroSeed() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let sessionEntropy: UInt64 = 0xA5A5_1234_5678_9ABC
    let controller = EditorSessionController(
        renderer: renderer,
        strokeSeedSessionEntropy: sessionEntropy
    )

    try controller.model.confirmRecipe(AnchorBrushCatalog.marker.id)
    controller.handleStrokeSample(controllerSample(.began))
    let first = try #require(renderer.harnessActiveStrokeStyle)
    #expect(
        first.renderIdentity.definitionID == first.program.definition.id
    )
    #expect(first.seed == EditorSessionController.derivedStrokeSeed(
        sequence: 1,
        sessionEntropy: sessionEntropy
    ))
    controller.handleStrokeSample(controllerSample(.cancelled))
    try awaitControllerRendererIdleForHarness(renderer)

    try controller.model.confirmRecipe(AnchorBrushCatalog.glaze.id)
    controller.handleStrokeSample(controllerSample(.began))
    let second = try #require(renderer.harnessActiveStrokeStyle)
    #expect(second.program == first.program)
    #expect(
        second.renderIdentity.definitionID == second.program.definition.id
    )
    #expect(second.seed == EditorSessionController.derivedStrokeSeed(
        sequence: 2,
        sessionEntropy: sessionEntropy
    ))
    #expect(second.seed != first.seed)
    controller.handleStrokeSample(controllerSample(.cancelled))
    try awaitControllerRendererIdleForHarness(renderer)

    controller.handleTool(.erase)
    controller.handleStrokeSample(controllerSample(.began))
    let eraser = try #require(renderer.harnessActiveStrokeStyle)
    #expect(
        eraser.renderIdentity.definitionID == eraser.program.definition.id
    )
    #expect(eraser.program != second.program)
    #expect(eraser.seed == EditorSessionController.derivedStrokeSeed(
        sequence: 3,
        sessionEntropy: sessionEntropy
    ))
    #expect(eraser.seed != second.seed)
    #expect(eraser.compositeMode == .erase)
    controller.handleStrokeSample(controllerSample(.cancelled))
    try awaitControllerRendererIdleForHarness(renderer)
}

@Test
@MainActor
func selectionConfirmsOnlyAfterCompiledRendererActivation() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let compiler = try makeNativeCompiler(renderer: renderer)
    let controller = EditorSessionController(
        renderer: renderer,
        compileDefinition: { definition in
            try await compiler.compileAndActivate(definition: definition)
        }
    )
    let ink = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.defaultDraw.definition
    )
    let eraser = try await compiler.compileAndActivate(
        definition: AnchorBrushCatalog.eraser.definition
    )
    try controller.installBootstrapBrushes(draw: ink, eraser: eraser)

    await controller.selectBrush(AnchorBrushCatalog.marker.id)

    #expect(controller.model.selectedRecipeID == EditorBrushCatalog.nativeMarker.id)
    #expect(
        renderer.harnessPreparedDrawBrushIdentity?.definitionID
            == EditorBrushCatalog.nativeMarker.id
    )

    controller.handleTool(.erase)
    #expect(
        renderer.harnessPreparedEraserBrushIdentity?.definitionID
            == AnchorBrushCatalog.eraser.id
    )
}

@Test
@MainActor
func successfulSelectionPersistsTheCanonicalActivatedBrushExactlyOnce()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let compiler = try makeNativeCompiler(renderer: renderer)
    let store = RecordingBrushSelectionStore()
    let controller = EditorSessionController(
        renderer: renderer,
        compileDefinition: { definition in
            try await compiler.compileAndActivate(definition: definition)
        },
        selectionStore: store
    )
    let ink = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.defaultDraw.definition
    )
    let eraser = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.eraser.definition
    )
    try controller.installBootstrapBrushes(draw: ink, eraser: eraser)

    await controller.selectBrush(AnchorBrushCatalog.marker.id)

    #expect(controller.model.selectedRecipeID == EditorBrushCatalog.nativeMarker.id)
    #expect(store.writes == [EditorBrushCatalog.nativeMarker.id.rawValue])
}

@Test
@MainActor
func failedSelectionPreservesInstalledBrushAndModelSelection() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let compiler = try makeNativeCompiler(renderer: renderer)
    let store = RecordingBrushSelectionStore()
    let controller = EditorSessionController(
        renderer: renderer,
        compileDefinition: { _ in throw MetalRendererError.unsupportedBrushProgram },
        selectionStore: store
    )
    let ink = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.defaultDraw.definition
    )
    let eraser = try await compiler.compileAndActivate(
        definition: AnchorBrushCatalog.eraser.definition
    )
    try controller.installBootstrapBrushes(draw: ink, eraser: eraser)
    let beforeModel = controller.model.selectedRecipeID
    let beforeDraw = renderer.harnessPreparedDrawBrushIdentity

    await controller.selectBrush(AnchorBrushCatalog.marker.id)

    #expect(controller.model.selectedRecipeID == beforeModel)
    #expect(renderer.harnessPreparedDrawBrushIdentity == beforeDraw)
    #expect(renderer.harnessPreparedDrawBrushIdentity == ink.renderIdentity)
    #expect(store.writes.isEmpty)
}

@Test
@MainActor
func mismatchedCompiledSelectionCannotPublishModelOrPersistence() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let compiler = try makeNativeCompiler(renderer: renderer)
    let wrongBrush = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.nativeDryMedia.definition
    )
    let store = RecordingBrushSelectionStore()
    let controller = EditorSessionController(
        renderer: renderer,
        compileDefinition: { _ in wrongBrush },
        selectionStore: store
    )
    let ink = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.defaultDraw.definition
    )
    let eraser = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.eraser.definition
    )
    try controller.installBootstrapBrushes(draw: ink, eraser: eraser)

    await controller.selectBrush(EditorBrushCatalog.nativeMarker.id)

    #expect(controller.model.selectedRecipeID == EditorBrushCatalog.defaultDraw.id)
    #expect(renderer.harnessPreparedDrawBrushIdentity == ink.renderIdentity)
    #expect(store.writes.isEmpty)
}

@Test
@MainActor
func latestCompletedSelectionWinsWhenEarlierCompilationFinishesStale()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let compiler = try makeNativeCompiler(renderer: renderer)
    let gate = GatedSelectionCompiler()
    let store = RecordingBrushSelectionStore()
    let controller = EditorSessionController(
        renderer: renderer,
        compileDefinition: { definition in
            try await gate.compile(definition)
        },
        selectionStore: store
    )
    let ink = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.defaultDraw.definition
    )
    let eraser = try await compiler.compileAndActivate(
        definition: AnchorBrushCatalog.eraser.definition
    )
    let marker = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.nativeMarker.definition
    )
    let airbrush = try await compiler.compileAndActivate(
        definition: AnchorBrushCatalog.airbrush.definition
    )
    try controller.installBootstrapBrushes(draw: ink, eraser: eraser)

    let staleSelection = Task { @MainActor in
        await controller.selectBrush(AnchorBrushCatalog.marker.id)
    }
    for _ in 0..<32 where !gate.pendingIDs.contains(EditorBrushCatalog.nativeMarker.id) {
        await Task.yield()
    }
    #expect(gate.pendingIDs == [EditorBrushCatalog.nativeMarker.id])

    let currentSelection = Task { @MainActor in
        await controller.selectBrush(AnchorBrushCatalog.airbrush.id)
    }
    for _ in 0..<32 where gate.pendingIDs.count < 2 {
        await Task.yield()
    }
    #expect(Set(gate.pendingIDs) == [
        EditorBrushCatalog.nativeMarker.id,
        AnchorBrushCatalog.airbrush.id,
    ])

    try gate.complete(AnchorBrushCatalog.airbrush.id, with: airbrush)
    await currentSelection.value
    #expect(controller.model.selectedRecipeID == AnchorBrushCatalog.airbrush.id)
    #expect(
        renderer.harnessPreparedDrawBrushIdentity
            == airbrush.renderIdentity
    )
    #expect(store.writes == [EditorBrushCatalog.nativeAirbrush.id.rawValue])

    try gate.complete(EditorBrushCatalog.nativeMarker.id, with: marker)
    await staleSelection.value
    #expect(controller.model.selectedRecipeID == AnchorBrushCatalog.airbrush.id)
    #expect(
        renderer.harnessPreparedDrawBrushIdentity
            == airbrush.renderIdentity
    )
    #expect(store.writes == [EditorBrushCatalog.nativeAirbrush.id.rawValue])
}

@Test
@MainActor
func replacementSessionPreservesConfirmedSelectionAndPersistenceWiring()
    async throws
{
    guard let sourceRenderer = try makeControllerRenderer(),
          let replacementRenderer = try makeControllerRenderer()
    else { return }
    let compiler = try makeNativeCompiler(renderer: sourceRenderer)
    let store = RecordingBrushSelectionStore()
    let source = EditorSessionController(
        renderer: sourceRenderer,
        compileDefinition: { definition in
            try await compiler.compileAndActivate(definition: definition)
        },
        selectionStore: store
    )
    let graphite = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.nativeDryMedia.definition
    )
    let eraser = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.eraser.definition
    )
    try source.installBootstrapBrushes(draw: graphite, eraser: eraser)
    try source.confirmBootstrapBrushSelection(
        EditorBrushCatalog.nativeDryMedia.id
    )

    let replacement = try source.replacementSession(
        renderer: replacementRenderer
    )
    #expect(
        replacement.model.selectedRecipeID
            == EditorBrushCatalog.nativeDryMedia.id
    )

    await replacement.selectBrush(AnchorBrushCatalog.marker.id)

    #expect(
        replacement.model.selectedRecipeID
            == EditorBrushCatalog.nativeMarker.id
    )
    #expect(store.writes == [
        EditorBrushCatalog.nativeDryMedia.id.rawValue,
        EditorBrushCatalog.nativeMarker.id.rawValue,
    ])
}

@Test
@MainActor
func replacementSessionAdoptsImportedRendererLayerStack() throws {
    let base = try LayerDescriptor(
        id: LayerStack.initialLayerID,
        name: "Imported Base"
    )
    let top = try LayerDescriptor(
        id: controllerLayerID(90),
        name: "Imported Top",
        isVisible: false,
        opacity: 0.5,
        isLocked: true,
        blendMode: .screen
    )
    let importedStack = try LayerStack(
        layers: [base, top],
        activeLayerID: top.id
    )
    guard let sourceRenderer = try makeControllerRenderer(),
          let importedRenderer = try makeControllerRenderer(
              layerStack: importedStack
          )
    else { return }
    let source = EditorSessionController(renderer: sourceRenderer)

    let replacement = try source.replacementSession(
        renderer: importedRenderer
    )

    #expect(replacement.layerStackForTesting == importedStack)
    #expect(replacement.model.layerStack == importedStack)
}

@Test
@MainActor
func replacementInvalidatesSelectionCompilingOnTheSourceSession()
    async throws
{
    guard let sourceRenderer = try makeControllerRenderer(),
          let replacementRenderer = try makeControllerRenderer()
    else { return }
    let compiler = try makeNativeCompiler(renderer: sourceRenderer)
    let gate = GatedSelectionCompiler()
    let store = RecordingBrushSelectionStore()
    let source = EditorSessionController(
        renderer: sourceRenderer,
        compileDefinition: { definition in
            try await gate.compile(definition)
        },
        selectionStore: store
    )
    let ink = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.defaultDraw.definition
    )
    let eraser = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.eraser.definition
    )
    let marker = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.nativeMarker.definition
    )
    try source.installBootstrapBrushes(draw: ink, eraser: eraser)

    let obsoleteSelection = Task { @MainActor in
        await source.selectBrush(EditorBrushCatalog.nativeMarker.id)
    }
    for _ in 0..<32 where gate.pendingIDs.isEmpty {
        await Task.yield()
    }
    #expect(gate.pendingIDs == [EditorBrushCatalog.nativeMarker.id])

    let replacement = try source.replacementSession(
        renderer: replacementRenderer
    )
    #expect(
        replacement.model.selectedRecipeID
            == EditorBrushCatalog.defaultDraw.id
    )

    try gate.complete(EditorBrushCatalog.nativeMarker.id, with: marker)
    await obsoleteSelection.value

    #expect(source.model.selectedRecipeID == EditorBrushCatalog.defaultDraw.id)
    #expect(
        sourceRenderer.harnessPreparedDrawBrushIdentity
            == ink.renderIdentity
    )
    #expect(store.writes.isEmpty)
}

@Test
@MainActor
func selectionDuringStrokeLeavesCurrentIdentityUntilNextStroke()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let compiler = try makeNativeCompiler(renderer: renderer)
    let controller = EditorSessionController(
        renderer: renderer,
        compileDefinition: { definition in
            try await compiler.compileAndActivate(definition: definition)
        }
    )
    let ink = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.defaultDraw.definition
    )
    let eraser = try await compiler.compileAndActivate(
        definition: AnchorBrushCatalog.eraser.definition
    )
    try controller.installBootstrapBrushes(draw: ink, eraser: eraser)

    var reportedErrors: [MetalRendererError] = []
    controller.onError = { reportedErrors.append($0) }
    controller.handleStrokeSample(controllerSample(.began))
    #expect(reportedErrors.isEmpty, "reported errors: \(reportedErrors)")
    let activeIdentity = try #require(
        renderer.harnessActiveStrokeStyle?.renderIdentity
    )
    #expect(activeIdentity == ink.renderIdentity)
    await controller.selectBrush(AnchorBrushCatalog.marker.id)
    #expect(controller.model.selectedRecipeID == EditorBrushCatalog.defaultDraw.id)
    #expect(renderer.harnessActiveStrokeStyle?.renderIdentity == activeIdentity)
    #expect(renderer.harnessPreparedDrawBrushIdentity == activeIdentity)

    controller.handleStrokeSample(controllerSample(.cancelled))
    try awaitControllerRendererIdleForHarness(renderer)
    await controller.selectBrush(AnchorBrushCatalog.marker.id)
    #expect(controller.model.selectedRecipeID == EditorBrushCatalog.nativeMarker.id)

    controller.handleStrokeSample(
        controllerSample(.began, timestamp: 3)
    )
    #expect(
        renderer.harnessActiveStrokeStyle?.renderIdentity
            == renderer.harnessPreparedDrawBrushIdentity
    )
    controller.handleStrokeSample(controllerSample(.cancelled, timestamp: 4))
    try awaitControllerRendererIdleForHarness(renderer)
}

@Test
@MainActor
func diagnosticProgramSeedAndNormalizedInputAreCapturedAtStrokeStart()
    throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var observed: [StrokeSample] = []
    controller.onNormalizedInput = { observed.append($0) }

    try controller.setDiagnosticFixedStrokeSeed(0xCAFE)
    let began = controllerSample(.began, x: 20, y: 24, timestamp: 1)
    controller.handleStrokeSample(began)

    let style = try #require(renderer.harnessActiveStrokeStyle)
    #expect(style.renderIdentity.definitionID == style.program.definition.id)
    #expect(style.seed == 0xCAFE)
    #expect(observed == [began])

    controller.handleStrokeSample(controllerSample(.cancelled, timestamp: 2))
    try awaitControllerRendererIdleForHarness(renderer)
    try controller.model.confirmRecipe(AnchorBrushCatalog.defaultDraw.id)
    controller.handleStrokeSample(controllerSample(.began, timestamp: 3))
    let builtIn = try #require(renderer.harnessActiveStrokeStyle)
    #expect(
        builtIn.renderIdentity.definitionID == builtIn.program.definition.id
    )
    #expect(builtIn.seed == 0xCAFE)
    controller.handleStrokeSample(controllerSample(.cancelled, timestamp: 4))
    try awaitControllerRendererIdleForHarness(renderer)
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
func editorCatalogInitializesAllProgramsBeforePointerInputInFreshProcess()
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
            #expect(spy.count == 2)
            #expect(model.selectedProgram == EditorBrushCatalog.defaultDraw.program)
            #expect(EditorBrushCatalog.drawEntries.count == 5)
            #expect(spy.count == 10)

            let controller = EditorSessionController(
                model: model,
                renderer: renderer
            )
            controller.handleTool(.erase)
            controller.handleStrokeSample(controllerSample(.began))
            controller.handleStrokeSample(controllerSample(.cancelled))
            #expect(spy.count == 10)
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
        "editorCatalogInitializesAllProgramsBeforePointerInputInFreshProcess",
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
    async throws
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
    _ = try await renderer.flushPendingLiveForHarness()
    _ = try await renderer.finishCommitForHarness()
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
    try awaitControllerRendererIdleForHarness(renderer)

    #expect(controller.transactionStateForTesting == .idle)
    #expect(controller.lastRecordedRasterCommandForTesting == nil)
    #expect(renderer.isIdle)
}

@Test
@MainActor
func newPointerFinalizesEstimateFallbackThenBeginsDeferredStroke()
    async throws
{
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

    try await finishControllerCommitAndAwaitDeferredStroke(
        controller,
        renderer: renderer
    )

    guard case let .drawing(collecting) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected deferred pointer to begin after commit")
        return
    }
    #expect(collecting.phase == .collecting)
    #expect(!renderer.isIdle)
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
func movedBatchTracksEstimateUntilASeparateUpdateResolvesIt() async throws {
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
    _ = try await renderer.flushPendingLiveForHarness()
    _ = try await renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
@MainActor
func completeDeferredPointerStreamReplaysAfterPriorCommit() async throws {
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

    try await finishControllerCommitAndAwaitDeferredStroke(
        controller,
        renderer: renderer
    )
    guard case let .drawing(secondCommit) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected the complete deferred stroke to replay")
        return
    }
    #expect(secondCommit.phase == .commitPending)

    _ = try await renderer.flushPendingLiveForHarness()
    _ = try await renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
    #expect(
        await renderer.paintStateSnapshotForTesting().documentGeneration == 2
    )
}

@Test
@MainActor
func retiringWorkspaceDefersRapidPointerUntilTrueIdleExactlyOnce()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let initialStorage =
        controller.deferredPointerStorageSnapshotForTesting
    #expect(
        initialStorage.queuedSampleCapacity
            >= TransientStrokeBufferContract.wholeStrokeSampleCapacity
    )
    #expect(
        initialStorage.drainSampleCapacity
            >= TransientStrokeBufferContract.wholeStrokeSampleCapacity
    )
    #expect(
        initialStorage.estimationIndexCapacity
            >= TransientStrokeBufferContract.wholeStrokeSampleCapacity
    )
    var normalizedTimestamps: [TimeInterval] = []
    var reportedErrors: [MetalRendererError] = []
    controller.onNormalizedInput = {
        normalizedTimestamps.append($0.timestamp)
    }
    controller.onError = { reportedErrors.append($0) }

    controller.handleStrokeSample(
        controllerSample(.began, x: 12, timestamp: 1),
        inputGeneration: 7_000
    )
    controller.cancelTransientEdit()
    #expect(controller.transactionStateForTesting == .idle)
    #expect(!renderer.isIdle)
    #expect(!renderer.offMainStrokeWorkspaceIsAvailableForTesting)
    normalizedTimestamps.removeAll(keepingCapacity: true)

    let generation: UInt64 = 7_001
    let rapidMoveCount = 256
    var expectedTimestamps: [TimeInterval] = [10]
    controller.handleStrokeSample(
        controllerSample(.began, x: 20, timestamp: 10),
        inputGeneration: generation
    )
    controller.handleStrokeSample(
        controllerMovedSample(
            x: 63,
            timestamp: 9_999,
            kind: .actual
        ),
        inputGeneration: generation + 1
    )
    for index in 0..<rapidMoveCount {
        let timestamp = TimeInterval(index + 11)
        expectedTimestamps.append(timestamp)
        controller.handleStrokeSample(
            controllerMovedSample(
                x: 21 + Float(index % 32),
                timestamp: timestamp,
                kind: .actual
            ),
            inputGeneration: generation
        )
    }
    expectedTimestamps.append(400)
    controller.handleStrokeSample(
        controllerSample(.ended, x: 54, timestamp: 400),
        inputGeneration: generation
    )

    let queuedStorage =
        controller.deferredPointerStorageSnapshotForTesting
    #expect(queuedStorage.queuedSampleCount == rapidMoveCount + 2)
    #expect(
        queuedStorage.queuedSampleCapacity
            == initialStorage.queuedSampleCapacity
    )
    #expect(normalizedTimestamps.isEmpty)

    // An operation-completion callback can run before the actor publishes
    // its true idle transition. Rechecking renderer.isIdle must leave the
    // deferred stream intact until that later notification arrives.
    renderer.onIdleStateChange?(true)
    #expect(!renderer.isIdle)
    #expect(controller.deferredPointerResumeCountForTesting == 0)
    #expect(
        controller.deferredPointerStorageSnapshotForTesting.queuedSampleCount
            == rapidMoveCount + 2
    )
    #expect(normalizedTimestamps.isEmpty)
    #expect(reportedErrors.isEmpty)

    var didResume = false
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if case let .drawing(drawing) =
            controller.transactionStateForTesting,
           drawing.phase == .commitPending
        {
            didResume = true
            break
        }
        await Task.yield()
    }
    #expect(didResume)
    #expect(controller.deferredPointerResumeCountForTesting == 1)
    #expect(!renderer.isIdle)
    #expect(normalizedTimestamps == expectedTimestamps)
    #expect(!normalizedTimestamps.contains(9_999))
    #expect(reportedErrors.isEmpty)

    let resumedStorage =
        controller.deferredPointerStorageSnapshotForTesting
    #expect(resumedStorage.queuedSampleCount == 0)
    #expect(
        resumedStorage.queuedSampleCapacity
            == initialStorage.queuedSampleCapacity
    )
    #expect(
        resumedStorage.drainSampleCapacity
            == initialStorage.drainSampleCapacity
    )
    #expect(
        resumedStorage.estimationIndexCapacity
            == initialStorage.estimationIndexCapacity
    )

    _ = try await renderer
        .completePendingInteractiveStrokeAndAwaitIdle()
}

@Test
@MainActor
func retiringWorkspaceResumesDeferredPrefixBeforePointerEnds()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var normalizedTimestamps: [TimeInterval] = []
    var reportedErrors: [MetalRendererError] = []
    controller.onNormalizedInput = {
        normalizedTimestamps.append($0.timestamp)
    }
    controller.onError = { reportedErrors.append($0) }

    controller.handleStrokeSample(
        controllerSample(.began, x: 12, timestamp: 1),
        inputGeneration: 8_000
    )
    controller.cancelTransientEdit()
    #expect(!renderer.isIdle)
    normalizedTimestamps.removeAll(keepingCapacity: true)

    let generation: UInt64 = 8_001
    let acceptedPrediction = (0..<64).map { index in
        controllerMovedSample(
            x: 31 + Float(index) * 0.125,
            timestamp: 12 + Double(index) * 0.001,
            kind: .predicted
        )
    }
    var boundedDeferredBatch = [
        StrokeSample(
            position: ScreenPoint(x: 24, y: 32),
            pressure: 0.5,
            timestamp: 10,
            phase: .began,
            source: .mouse,
            kind: .coalesced
        ),
        controllerMovedSample(
            x: 30,
            timestamp: 11,
            kind: .actual
        ),
    ]
    boundedDeferredBatch.append(contentsOf: acceptedPrediction)
    controller.handleStrokeSamples(
        boundedDeferredBatch,
        inputGeneration: generation,
        submittedPredictionSampleCount: 100_000
    )
    #expect(controller.transactionStateForTesting == .idle)
    #expect(normalizedTimestamps.isEmpty)

    var didResumeCollecting = false
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if case let .drawing(drawing) =
            controller.transactionStateForTesting,
           drawing.phase == .collecting
        {
            didResumeCollecting = true
            break
        }
        await Task.yield()
    }
    #expect(didResumeCollecting)
    let deferredPredictionState = try await awaitActorTransientSamples(
        renderer,
        predictedXs: acceptedPrediction.map(\.position.x),
        minimumTransientMutationVersion: 3
    )
    #expect(deferredPredictionState.predictedSamples.count == 64)
    #expect(normalizedTimestamps.count == 2 + 64)
    #expect(normalizedTimestamps.prefix(2) == [10, 11])
    let deferredPredictionScratch =
        renderer.predictionSubmissionScratchSnapshotForTesting
    #expect(deferredPredictionScratch.lastSubmittedSampleCount == 100_000)
    #expect(deferredPredictionScratch.lastAcceptedSampleCount == 64)
    #expect(
        deferredPredictionScratch.lastShedSampleCount == 100_000 - 64
    )
    #expect(deferredPredictionScratch.lastValidatedSampleCount == 64)
    #expect(deferredPredictionScratch.lastTelemetrySampleCount == 64)

    controller.handleStrokeSample(
        controllerMovedSample(x: 38, timestamp: 20, kind: .actual),
        inputGeneration: generation
    )
    controller.handleStrokeSample(
        controllerSample(.ended, x: 46, timestamp: 21),
        inputGeneration: generation
    )
    guard case let .drawing(committing) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected resumed pointer to request one commit")
        return
    }
    #expect(committing.phase == .commitPending)
    #expect(normalizedTimestamps.suffix(2) == [20, 21])
    #expect(reportedErrors.isEmpty)

    _ = try await renderer
        .completePendingInteractiveStrokeAndAwaitIdle()
}

@Test
@MainActor
func deferredPointerCanReuseAnOldEstimatedUpdateIndex() async throws {
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

    try await finishControllerCommitAndAwaitDeferredStroke(
        controller,
        renderer: renderer
    )
    guard case let .drawing(secondCommit) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected reused index update to reach deferred stroke")
        return
    }
    #expect(secondCommit.phase == .commitPending)
    _ = try await renderer.flushPendingLiveForHarness()
    _ = try await renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
@MainActor
func deferredPointerRejectsLatePriorGenerationUpdateForReusedIndex()
    async throws
{
    func render(includeLatePriorUpdate: Bool) async throws -> [UInt8]? {
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

        try await finishControllerCommitAndAwaitDeferredStroke(
            controller,
            renderer: renderer
        )
        guard case let .drawing(secondCommit) =
            controller.transactionStateForTesting
        else {
            Issue.record("Expected deferred stroke to request its commit")
            return nil
        }
        #expect(secondCommit.phase == .commitPending)
    _ = try await renderer.flushPendingLiveForHarness()
    _ = try await renderer.finishCommitForHarness()
        #expect(controller.transactionStateForTesting == .idle)
        return try await canonicalBytes(renderer)
    }

    let expectedResult = try await render(includeLatePriorUpdate: false)
    let interleavedResult = try await render(includeLatePriorUpdate: true)
    let expected = try #require(expectedResult)
    let interleaved = try #require(interleavedResult)
    #expect(interleaved.elementsEqual(expected))
}

@Test
@MainActor
func deferredPointerOverflowCancelsInsteadOfReplayingPartialInput() async throws {
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

    _ = try await renderer.flushPendingLiveForHarness()
    _ = try await renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
    #expect(renderer.isIdle)
    #expect(
        await renderer.paintStateSnapshotForTesting().documentGeneration == 1
    )
}

@Test
@MainActor
func cancellingWhileCommitIsPendingDiscardsDeferredPointerStream() async throws {
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

    _ = try await renderer.flushPendingLiveForHarness()
    _ = try await renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
    #expect(renderer.isIdle)
    #expect(
        await renderer.paintStateSnapshotForTesting().documentGeneration == 1
    )
}

@Test
@MainActor
func ignoredToolInputDoesNotLeakEstimatedStateIntoNextStroke() async throws {
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
    _ = try await renderer.flushPendingLiveForHarness()
    _ = try await renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
@MainActor
func failedEstimatedFallbackCommitLeavesRendererReusable() async throws {
    guard let renderer = try makeControllerRenderer(historyByteBudget: 1)
    else { return }
    let controller = EditorSessionController(renderer: renderer)
    var reportedErrors: [MetalRendererError] = []
    controller.onError = { reportedErrors.append($0) }
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

    _ = try await renderer.finishCommitForHarness()
    #expect(reportedErrors.count == 1)
    guard case .commandFailed = reportedErrors.first else {
        Issue.record("Expected the history-budget terminal failure")
        return
    }
    #expect(controller.transactionStateForTesting == .idle)
    #expect(renderer.isIdle)

    controller.handleStrokeSample(controllerSample(.began, x: 40))
    #expect(renderer.hasActiveStroke)
    controller.handleStrokeSample(controllerSample(.cancelled, x: 40))
    try awaitControllerRendererIdleForHarness(renderer)
    #expect(renderer.isIdle)
}

@Test
@MainActor
func cancellationClearsPendingEstimateBookkeepingForNextStroke() async throws {
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
    try awaitControllerRendererIdleForHarness(renderer)
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
    try awaitControllerRendererIdleForHarness(renderer)
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
    _ = try await renderer.flushPendingLiveForHarness()
    _ = try await renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
@MainActor
func synchronousRendererFailureClearsEstimateBookkeeping() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var reportedErrors: [MetalRendererError] = []
    controller.onError = { reportedErrors.append($0) }
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
    controller.handleStrokeSamples(
        [],
        submittedPredictionSampleCount: 100_000
    )
    #expect(controller.transactionStateForTesting == .idle)
    #expect(reportedErrors == [.invalidStrokeLifecycle])
    try awaitControllerRendererIdleForHarness(renderer)

    controller.handleStrokeSample(controllerSample(.began, x: 36))
    controller.handleStrokeSample(controllerSample(.ended, x: 44))
    guard case let .drawing(committing) =
        controller.transactionStateForTesting
    else {
        Issue.record("Expected next stroke to commit after failure cleanup")
        return
    }
    #expect(committing.phase == .commitPending)
    _ = try await renderer.flushPendingLiveForHarness()
    _ = try await renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
    #expect(reportedErrors == [.invalidStrokeLifecycle])
}

@Test
@MainActor
func focusLossFinalizesAwaitingEstimateExactlyOnce() async throws {
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
    _ = try await renderer.flushPendingLiveForHarness()
    _ = try await renderer.finishCommitForHarness()
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
func controllerSubmitsPredictedMovesAsOneReplaceableSuffixBatch()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    try controller.model.confirmRecipe(AnchorBrushCatalog.marker.id)
    var normalizedImmediateBatch: [StrokeSample] = []
    controller.onNormalizedInput = {
        normalizedImmediateBatch.append($0)
    }
    let immediatePrediction = (0..<64).map { index in
        controllerMovedSample(
            x: 17 + Float(index) * 0.125,
            timestamp: 0.1 + Double(index) * 0.001,
            kind: .predicted
        )
    }
    var immediateBeganBatch = [
        StrokeSample(
            position: ScreenPoint(x: 16, y: 32),
            pressure: 0.5,
            timestamp: 0,
            phase: .began,
            source: .mouse,
            kind: .coalesced
        ),
        controllerMovedSample(
            x: 16.5,
            timestamp: 0.05,
            kind: .actual
        ),
    ]
    immediateBeganBatch.append(contentsOf: immediatePrediction)
    controller.handleStrokeSamples(
        immediateBeganBatch,
        submittedPredictionSampleCount: 100_000
    )
    let immediateState = try await awaitActorTransientSamples(
        renderer,
        predictedXs: immediatePrediction.map(\.position.x),
        minimumTransientMutationVersion: 3
    )
    #expect(immediateState.predictedSamples.count == 64)
    #expect(normalizedImmediateBatch.count == 2 + 64)
    #expect(normalizedImmediateBatch[0].phase == .began)
    #expect(normalizedImmediateBatch[0].kind == .coalesced)
    #expect(normalizedImmediateBatch[1].phase == .moved)
    #expect(normalizedImmediateBatch[1].kind == .actual)
    let immediateScratch =
        renderer.predictionSubmissionScratchSnapshotForTesting
    #expect(immediateScratch.lastSubmittedSampleCount == 100_000)
    #expect(immediateScratch.lastAcceptedSampleCount == 64)
    #expect(immediateScratch.lastShedSampleCount == 100_000 - 64)

    controller.handleStrokeSamples([
        controllerMovedSample(x: 24, timestamp: 1, kind: .predicted),
        controllerMovedSample(x: 40, timestamp: 2, kind: .predicted),
    ])
    let firstPrediction = try await awaitActorTransientSamples(
        renderer,
        predictedXs: [24, 40]
    )
    #expect(firstPrediction.predictedSamples.count == 2)

    controller.handleStrokeSamples([
        controllerMovedSample(x: 28, timestamp: 1, kind: .predicted),
        controllerMovedSample(x: 34, timestamp: 2, kind: .predicted),
    ])
    let replacementPrediction = try await awaitActorTransientSamples(
        renderer,
        predictedXs: [28, 34]
    )
    #expect(replacementPrediction.predictedSamples.count == 2)

    let mixedMutationVersionBefore =
        await renderer.offMainSchedulerSnapshotForTesting()
            .transientMutationVersion
    var normalizedMixedBatch: [StrokeSample] = []
    controller.onNormalizedInput = { normalizedMixedBatch.append($0) }
    let acceptedPrediction = (0..<64).map { index in
        controllerMovedSample(
            x: 31 + Float(index) * 0.125,
            timestamp: 3 + Double(index) * 0.001,
            kind: .predicted
        )
    }
    var mixedBatch = [
        controllerMovedSample(x: 30, timestamp: 2.5, kind: .actual),
    ]
    mixedBatch.append(contentsOf: acceptedPrediction)
    controller.handleStrokeSamples(
        mixedBatch,
        submittedPredictionSampleCount: 100_000
    )
    let boundedMixed = try await awaitActorTransientSamples(
        renderer,
        predictedXs: acceptedPrediction.map(\.position.x),
        minimumTransientMutationVersion:
            mixedMutationVersionBefore + 2
    )
    #expect(boundedMixed.predictedSamples.count == 64)
    #expect(normalizedMixedBatch.count == 1 + 64)
    let boundedScratch =
        renderer.predictionSubmissionScratchSnapshotForTesting
    #expect(boundedScratch.lastSubmittedSampleCount == 100_000)
    #expect(boundedScratch.lastAcceptedSampleCount == 64)
    #expect(boundedScratch.lastShedSampleCount == 100_000 - 64)
    #expect(boundedScratch.lastValidatedSampleCount == 64)
    #expect(boundedScratch.lastTelemetrySampleCount == 64)

    let authoritativeMutationVersionBefore =
        await renderer.offMainSchedulerSnapshotForTesting()
            .transientMutationVersion
    controller.handleStrokeSample(
        controllerMovedSample(x: 30, timestamp: 2, kind: .actual)
    )
    let settled = try await awaitActorTransientSamples(
        renderer,
        predictedXs: [],
        minimumTransientMutationVersion:
            authoritativeMutationVersionBefore + 1
    )
    #expect(settled.predictedSamples.isEmpty)
    #expect(
        await renderer.offMainSchedulerSnapshotForTesting()
            .transientMutationVersion
            >= authoritativeMutationVersionBefore + 1
    )
    controller.handleStrokeSample(controllerSample(.cancelled))
    try awaitControllerRendererIdleForHarness(renderer)
    #expect(renderer.isIdle)
}

@Test
@MainActor
func tilingShortcutsUseStableOneBasedTilingIndices() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    for index in 1...7 {
        controller.handleShortcut(.selectTiling(index1: index))
        try await awaitControllerPaintOperationForHarness(
            controller,
            renderer: renderer
        )
        #expect(controller.model.tiling.rawValue == UInt32(index - 1))
        #expect(renderer.tiling.rawValue == UInt32(index - 1))
    }
}

@Test
@MainActor
func tileStepShortcutSubmitsOneClampedTwoDimensionResize() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.handleShortcut(.stepTile(larger: true))

    #expect(controller.model.pixelSize == PixelSize(width: 64, height: 64))
    #expect(controller.model.isBusy)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.pixelSize == PixelSize(width: 96, height: 96))
    #expect(!controller.model.isBusy)

    let resize = try #require(controller.lastRecordedResizeCommandForTesting)
    try await renderer.releasePaintRevisions([resize.layerRevision.id])
}

@Test
@MainActor
func busyControllerRejectsConflictingSemanticShortcuts() async throws {
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

    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    let resize = try #require(controller.lastRecordedResizeCommandForTesting)
    try await renderer.releasePaintRevisions([resize.layerRevision.id])
}

@Test
@MainActor
func commandShortcutsShareClearUndoAndRedoHistoryFlow() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    try await commitControllerStroke(controller, renderer: renderer)
    let stroke = try #require(controller.lastRecordedRasterCommandForTesting)

    controller.handleShortcut(.clear)
    #expect(controller.model.isBusy)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    let clear = try #require(controller.lastRecordedRasterCommandForTesting)
    #expect(clear.kind == .clear)
    #expect(controller.model.canUndo)

    controller.handleShortcut(.undo)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(controller.model.canRedo)

    controller.handleShortcut(.redo)
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )
    #expect(!controller.model.canRedo)

    try await renderer.releasePaintRevisions(
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
    try await awaitControllerPaintOperationForHarness(
        controller,
        renderer: renderer
    )

    #expect(controller.model.showGrid)
    #expect(renderer.interactiveGridVisibility)
    #expect(controller.model.tiling == .halfDrop)
    #expect(renderer.tiling == .halfDrop)

}

@Test
@MainActor
func cancelShortcutCancelsStrokeWithoutCreatingHistory() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.handleStrokeSample(controllerSample(.began))
    #expect(renderer.hasActiveStroke)
    controller.handleShortcut(.cancel)

    try await renderer.awaitPendingStrokeWorkspaceRetirement()
    #expect(renderer.isIdle)
    #expect(!controller.model.canUndo)
    #expect(controller.lastRecordedRasterCommandForTesting == nil)
}

@Test
@MainActor
func finiteStrokeFullyOutsideCanvasIsIgnoredWithoutErrorOrHistory() throws {
    guard let renderer = try makeControllerRenderer(
        finiteConfiguration: .plain
    ) else {
        return
    }
    let controller = EditorSessionController(renderer: renderer)
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }

    controller.handleStrokeSamples([
        controllerSample(.began, x: -100, y: -100, timestamp: 1),
        controllerSample(.moved, x: -90, y: -90, timestamp: 2),
        controllerSample(.ended, x: -80, y: -80, timestamp: 3),
    ])

    #expect(errors.isEmpty)
    #expect(renderer.isIdle)
    #expect(!renderer.hasActiveStroke)
    #expect(
        controller.lastStrokeBeginAdmissionResult
            == .footprintOutsideDocument
    )
    #expect(!controller.model.canUndo)
    #expect(controller.lastRecordedRasterCommandForTesting == nil)
}

@Test
@MainActor
func finiteStrokeWhoseBrushFootprintCrossesCanvasEdgeStillBegins() throws {
    guard let renderer = try makeControllerRenderer(
        finiteConfiguration: .plain
    ) else {
        return
    }
    let controller = EditorSessionController(renderer: renderer)
    controller.model.confirmBrushDiameter(20)

    controller.handleStrokeSample(
        controllerSample(.began, x: -5, y: 32, timestamp: 1)
    )

    #expect(renderer.hasActiveStroke)
    #expect(controller.lastStrokeBeginAdmissionResult == .accepted)
    controller.handleStrokeSample(
        controllerSample(.cancelled, x: -5, y: 32, timestamp: 2)
    )
    try awaitControllerRendererIdleForHarness(renderer)
    #expect(renderer.isIdle)
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
    try awaitControllerRendererIdleForHarness(renderer)

    #expect(!controller.isSpaceDown)
    #expect(!renderer.hasActiveStroke)
    #expect(renderer.isIdle)
}

#if os(macOS)
@Test
@MainActor
func nativeCanvasExposesStableAccessibilityTarget() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let view = InteractiveMetalView(
        frame: CGRect(x: 0, y: 0, width: 64, height: 64),
        controller: controller,
        renderer: renderer,
        requestEditorFocus: {},
        pointerCancellationGeneration: 0
    )

    #expect(view.isAccessibilityElement())
    #expect(view.accessibilityIdentifier() == "Pattern Canvas")
    #expect(view.accessibilityRole() == .group)
}

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
private func canonicalBytes(_ renderer: GridRenderer) async throws -> [UInt8] {
    let snapshot = try await renderer.captureCommittedDocument()
    switch snapshot.storage {
    case let .singleRaster(bytes):
        return bytes
    case let .radialPages(pages):
        return pages.flatMap(\.bgra8PremultipliedBytes)
    }
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
