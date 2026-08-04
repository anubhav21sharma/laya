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
    let renderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 64, height: 64),
        configuration: canvasConfiguration
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
) throws {
    controller.handleStrokeSample(controllerSample(.began, x: x, y: y))
    controller.handleStrokeSample(controllerSample(.ended, x: x, y: y))
    _ = try renderer.finishCommitForHarness()
}

@MainActor
private func awaitControllerRendererIdleForHarness(
    _ renderer: GridRenderer
) throws {
    try renderer.drainStrokeWorkspaceRetirementForHarness()
    #expect(renderer.isIdle)
}

@MainActor
private func awaitActorTransientSamples(
    _ renderer: GridRenderer,
    predictedXs: [Float],
    minimumAuthoritativeInputCount: UInt64? = nil
) async throws -> StrokeTransientPreparationSnapshot {
    var lastSnapshot: StrokeTransientPreparationSnapshot?
    for _ in 0..<20_000 {
        try renderer.drainCompletedOperationsForHarness()
        if renderer.hasPendingOffMainSurfaceLeaseForTesting {
            _ = try renderer.completeNextPendingInteractiveFrame()
        }
        let snapshot = await renderer.offMainTransientSnapshotForTesting()
        lastSnapshot = snapshot
        let predicted = snapshot.predictedSamples.map(\.position.x)
        let authoritativeMatches = minimumAuthoritativeInputCount.map {
            renderer.compatibilityInkCoordinatorSnapshotForTesting?
                .commitMetadata.inputSampleCount ?? 0 >= $0
        } ?? true
        if predicted == predictedXs, authoritativeMatches {
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
            + "expectedPredicted=\(predictedXs)"
    )
}

@MainActor
private func finishControllerCommitAndAwaitDeferredStroke(
    _ controller: EditorSessionController,
    renderer: GridRenderer
) async throws {
    _ = try renderer.completePendingInteractiveStroke()
    for _ in 0..<20_000 {
        if renderer.hasActiveStroke,
           case .drawing = controller.transactionStateForTesting
        {
            return
        }
        try renderer.drainCompletedOperationsForHarness()
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "deferred controller stroke did not resume after workspace retirement"
    )
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
    #expect(throws: MetalRendererError.self) {
        _ = try renderer.finishCommitForHarness(forceCommitFailure: true)
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
    #expect(command.layerID == LayerStack.compatibilityLayerID)
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
func layerBoundHistorySurvivesReorderAndActiveLayerChanges() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let compatibility = try LayerDescriptor(
        id: LayerStack.compatibilityLayerID,
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
    var restoredLayerIDs: [UUID] = []
    let controller = EditorSessionController(
        renderer: renderer,
        layerStack: stack,
        requestRasterRestore: { token, layerID, revision in
            restoredLayerIDs.append(layerID)
            try renderer.requestRasterRestore(
                token: token,
                revision: revision
            )
        }
    )

    try commitControllerStroke(controller, renderer: renderer)
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
    #expect(restoredLayerIDs == [compatibility.id])
    try renderer.finishRasterOperationForHarness()

    controller.redo()
    #expect(restoredLayerIDs == [compatibility.id, compatibility.id])
    try renderer.finishRasterOperationForHarness()
    renderer.releaseRasterRevisions([raster.before.id, raster.after.id])
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
            LayerStack.compatibilityLayerID,
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
    guard let renderer = try makeControllerRenderer() else { return }
    let compatibility = try LayerDescriptor(
        id: LayerStack.compatibilityLayerID,
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
    let revision = controllerLayerRevision(20)
    let storage = ControllerLayerRasterStorageSpy(
        layers: [target.id: revision]
    )
    let controller = EditorSessionController(
        renderer: renderer,
        layerStack: stack,
        layerRasterStorage: storage
    )

    try controller.moveLayer(target.id, to: 2)
    try controller.deleteLayer(target.id)

    #expect(storage.events == [.capture(target.id), .delete(target.id)])
    #expect(
        controller.layerStackForTesting.orderedLayerIDs
            == [compatibility.id, fallback.id]
    )
    #expect(controller.layerStackForTesting.activeLayerID == fallback.id)
    #expect(storage.layers[target.id] == nil)

    controller.undo()
    #expect(controller.model.isBusy)
    #expect(storage.pending?.kind == .restore)
    #expect(storage.pending?.revision == revision)
    #expect(controller.layerStackForTesting.layer(id: target.id) == nil)
    storage.completePending(succeeded: true)

    #expect(
        controller.layerStackForTesting.layers
            == [compatibility, fallback, target]
    )
    #expect(controller.layerStackForTesting.activeLayerID == target.id)
    #expect(storage.layers[target.id] == revision)
    #expect(controller.historyAvailabilityForTesting.canRedo)

    controller.redo()
    #expect(controller.model.isBusy)
    #expect(storage.pending?.kind == .delete)
    #expect(controller.layerStackForTesting.layer(id: target.id) == target)
    storage.completePending(succeeded: true)

    #expect(controller.layerStackForTesting.layer(id: target.id) == nil)
    #expect(controller.layerStackForTesting.activeLayerID == fallback.id)
    #expect(storage.layers[target.id] == nil)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
}

@Test
@MainActor
func layerDeletionFailuresPreserveMetadataAndHistoryCursor() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let compatibility = try LayerDescriptor(
        id: LayerStack.compatibilityLayerID,
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
    let revision = controllerLayerRevision(22)
    let storage = ControllerLayerRasterStorageSpy(
        layers: [target.id: revision]
    )
    let controller = EditorSessionController(
        renderer: renderer,
        layerStack: stack,
        layerRasterStorage: storage
    )
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }
    try controller.deleteLayer(target.id)
    let deleted = controller.layerStackForTesting

    storage.unavailableRevisionIDs.insert(revision.id)
    controller.undo()
    #expect(storage.pending == nil)
    #expect(controller.layerStackForTesting == deleted)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    storage.unavailableRevisionIDs.remove(revision.id)

    controller.undo()
    #expect(storage.pending?.kind == .restore)
    storage.completePending(succeeded: false)
    #expect(controller.layerStackForTesting == deleted)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)

    controller.undo()
    storage.completePending(succeeded: true)
    let restored = controller.layerStackForTesting
    #expect(controller.historyAvailabilityForTesting.canRedo)

    storage.synchronousRequestFailure = true
    controller.redo()
    #expect(storage.pending == nil)
    #expect(controller.layerStackForTesting == restored)
    #expect(!controller.historyAvailabilityForTesting.canUndo)
    #expect(controller.historyAvailabilityForTesting.canRedo)
    #expect(errors.count == 3)

    let deletionFailureStorage = ControllerLayerRasterStorageSpy(
        layers: [target.id: revision]
    )
    deletionFailureStorage.synchronousDeleteFailure = true
    let deletionFailureController = EditorSessionController(
        renderer: renderer,
        layerStack: stack,
        layerRasterStorage: deletionFailureStorage
    )
    #expect(throws: MetalRendererError.commandFailed(
        "injected synchronous layer deletion failure"
    )) {
        try deletionFailureController.deleteLayer(target.id)
    }
    #expect(deletionFailureController.layerStackForTesting == stack)
    #expect(!deletionFailureController.historyAvailabilityForTesting.canUndo)
    #expect(deletionFailureStorage.layers[target.id] == revision)
    #expect(deletionFailureStorage.retainedRevisionIDs.isEmpty)
}

@Test
@MainActor
func layerDeletionDefaultRouteRejectsBeforeMetadataOrHistoryMutation()
    throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let compatibility = try LayerDescriptor(
        id: LayerStack.compatibilityLayerID,
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
    let controller = EditorSessionController(
        renderer: renderer,
        layerStack: stack
    )

    #expect(throws: EditorSessionLayerError.rendererStorageUnavailable(
        target.id
    )) {
        try controller.deleteLayer(target.id)
    }
    #expect(controller.layerStackForTesting == stack)
    #expect(!controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
}

@Test
@MainActor
func missingHistoryTargetFailsBeforeRendererMutationAndPreservesCursor()
    throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let size = PixelSize(width: 64, height: 64)
    let regions = PixelRegionSet(
        [PixelRect(minX: 0, minY: 0, maxX: 1, maxY: 1)!],
        clippedTo: size
    )
    let before = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: 900),
        pixelSize: size,
        regions: regions,
        retainedBytes: 8
    )
    let after = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: 901),
        pixelSize: size,
        regions: regions,
        retainedBytes: 8
    )
    let history = DocumentHistory(initialDocumentIsEmpty: false)
    _ = history.appendSuccessful(.raster(RasterHistoryCommand(
        layerID: controllerLayerID(99),
        kind: .draw,
        before: before,
        after: after
    )))
    var restoreCount = 0
    let controller = EditorSessionController(
        renderer: renderer,
        documentHistory: history,
        requestRasterRestore: { _, _, _ in restoreCount += 1 }
    )
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }
    let bytes = try canonicalBytes(renderer)

    controller.undo()

    #expect(restoreCount == 0)
    #expect(controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(controller.transactionStateForTesting == .idle)
    #expect(try canonicalBytes(renderer) == bytes)
    #expect(errors.count == 1)
}

@Test
@MainActor
func clearAndResizeCommandsUseTheExplicitCompatibilityLayer() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)

    controller.clear()
    try renderer.finishRasterOperationForHarness()
    #expect(
        controller.lastRecordedRasterCommandForTesting?.layerID
            == LayerStack.compatibilityLayerID
    )
    controller.handleTileSize(PixelSize(width: 96, height: 80))
    try renderer.finishRasterOperationForHarness()
    #expect(
        controller.lastRecordedResizeCommandForTesting?.layerID
            == LayerStack.compatibilityLayerID
    )

    if let clear = controller.lastRecordedRasterCommandForTesting,
       let resize = controller.lastRecordedResizeCommandForTesting
    {
        renderer.releaseRasterRevisions([
            clear.before.id, clear.after.id,
            resize.before.id, resize.after.id,
        ])
    }
}

@Test
@MainActor
func mismatchedTiledReceiptFailsWithoutRecordingCrossLayerHistory() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    var requestedToken: RendererOperationToken?
    var released: [Set<StoredRasterRevisionID>] = []
    let controller = EditorSessionController(
        renderer: renderer,
        releaseRasterRevisions: { released.append($0) },
        requestClear: { token, _ in requestedToken = token }
    )
    var errors: [MetalRendererError] = []
    controller.onError = { errors.append($0) }
    controller.clear()
    let token = try #require(requestedToken)
    let expectedLayerID = LayerStack.compatibilityLayerID
    let actualLayerID = controllerLayerID(404)
    let size = PixelSize(width: 256, height: 256)
    let regions = PixelRegionSet(
        [PixelRect(minX: 0, minY: 0, maxX: 256, maxY: 256)!],
        clippedTo: size
    )
    let storage = RasterRevisionStorage.tiledRGBA16Float(
        layerID: actualLayerID,
        generation: 1,
        tileCoordinates: [.init(x: 0, y: 0)]
    )
    let before = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: 80_001),
        pixelSize: size,
        documentPixelSize: size,
        regions: regions,
        retainedBytes: 0,
        storage: storage
    )
    let after = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: 80_002),
        pixelSize: size,
        documentPixelSize: size,
        regions: regions,
        retainedBytes: PaintTileDescriptor.residentByteCount,
        storage: storage
    )

    renderer.onOperationCompleted?(.rasterSuccess(RasterMutationReceipt(
        token: token,
        before: before,
        after: after
    )))

    #expect(errors == [.rasterRevisionLayerMismatch(
        expected: expectedLayerID,
        actual: actualLayerID
    )])
    #expect(released == [[before.id, after.id]])
    #expect(!controller.historyAvailabilityForTesting.canUndo)
    #expect(!controller.historyAvailabilityForTesting.canRedo)
    #expect(controller.lastRecordedRasterCommandForTesting == nil)
    #expect(controller.transactionStateForTesting == .idle)
    #expect(!controller.model.isBusy)
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
        requestRasterRestore: { token, layerID, revision in
            #expect(layerID == LayerStack.compatibilityLayerID)
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

private func controllerLayerID(_ value: Int) -> UUID {
    UUID(uuidString: String(
        format: "00000000-0000-0000-0000-%012d",
        value
    ))!
}

private func controllerLayerRevision(_ value: UInt64)
    -> RasterRevisionReference
{
    let size = PixelSize(width: 64, height: 64)
    return RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: 10_000 + value),
        pixelSize: size,
        regions: PixelRegionSet([], clippedTo: size),
        retainedBytes: 128
    )
}

@MainActor
private final class ControllerLayerRasterStorageSpy:
    EditorLayerRasterStorage
{
    enum Event: Equatable {
        case capture(UUID)
        case delete(UUID)
        case requestRestore(UUID)
        case requestDelete(UUID)
    }

    enum PendingKind: Equatable {
        case restore
        case delete
    }

    struct Pending: Equatable {
        let token: RendererOperationToken
        let kind: PendingKind
        let layerID: UUID
        let revision: RasterRevisionReference
    }

    var onOperationCompleted:
        ((EditorLayerRasterOperationCompletion) -> Void)?
    var layers: [UUID: RasterRevisionReference]
    private var retained: [StoredRasterRevisionID: RasterRevisionReference]
        = [:]
    var unavailableRevisionIDs: Set<StoredRasterRevisionID> = []
    var synchronousRequestFailure = false
    var synchronousDeleteFailure = false
    private(set) var events: [Event] = []
    private(set) var pending: Pending?
    var retainedRevisionIDs: Set<StoredRasterRevisionID> {
        Set(retained.keys)
    }

    init(layers: [UUID: RasterRevisionReference]) {
        self.layers = layers
    }

    func captureRevision(
        for layerID: UUID,
        maximumRetainedBytes: Int
    ) throws -> RasterRevisionReference {
        events.append(.capture(layerID))
        guard let revision = layers[layerID],
              revision.retainedBytes <= maximumRetainedBytes
        else {
            throw MetalRendererError.missingRasterRevision
        }
        retained[revision.id] = revision
        return revision
    }

    func deleteLayer(_ layerID: UUID) throws {
        events.append(.delete(layerID))
        if synchronousDeleteFailure {
            synchronousDeleteFailure = false
            throw MetalRendererError.commandFailed(
                "injected synchronous layer deletion failure"
            )
        }
        guard layers.removeValue(forKey: layerID) != nil else {
            throw MetalRendererError.missingRasterRevision
        }
    }

    func containsRevision(_ id: StoredRasterRevisionID) -> Bool {
        retained[id] != nil && !unavailableRevisionIDs.contains(id)
    }

    func requestRestore(
        token: RendererOperationToken,
        layerID: UUID,
        revision: RasterRevisionReference
    ) throws {
        try beginRequest(
            Pending(
                token: token,
                kind: .restore,
                layerID: layerID,
                revision: revision
            ),
            event: .requestRestore(layerID)
        )
    }

    func requestDelete(
        token: RendererOperationToken,
        layerID: UUID,
        revision: RasterRevisionReference
    ) throws {
        try beginRequest(
            Pending(
                token: token,
                kind: .delete,
                layerID: layerID,
                revision: revision
            ),
            event: .requestDelete(layerID)
        )
    }

    func releaseRevisions(_ ids: Set<StoredRasterRevisionID>) {
        for id in ids { retained.removeValue(forKey: id) }
    }

    func completePending(succeeded: Bool) {
        guard let pending else {
            Issue.record("Expected a pending layer raster operation")
            return
        }
        self.pending = nil
        if succeeded {
            switch pending.kind {
            case .restore:
                layers[pending.layerID] = pending.revision
            case .delete:
                layers.removeValue(forKey: pending.layerID)
            }
            onOperationCompleted?(.success(pending.token))
        } else {
            onOperationCompleted?(.failure(
                pending.token,
                .commandFailed("injected layer storage failure")
            ))
        }
    }

    private func beginRequest(
        _ request: Pending,
        event: Event
    ) throws {
        if synchronousRequestFailure {
            synchronousRequestFailure = false
            throw MetalRendererError.commandFailed(
                "injected synchronous layer storage failure"
            )
        }
        guard pending == nil else {
            throw MetalRendererError.commitPendingInput
        }
        events.append(event)
        pending = request
    }
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
    #expect(!renderer.isIdle)
    #expect(controller.model.periodicConfiguration == before)
    #expect(!controller.historyAvailabilityForTesting.canUndo)

    controller.handleTiling(.mirrorX)
    #expect(controller.model.isBusy)
    try awaitControllerRendererIdleForHarness(renderer)
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
func pointerDownCapturesPreparedNativeProgramsAndUniqueNonzeroSeed() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let sessionEntropy: UInt64 = 0xA5A5_1234_5678_9ABC
    let controller = EditorSessionController(
        renderer: renderer,
        strokeSeedSessionEntropy: sessionEntropy
    )

    controller.model.confirmRecipe(AnchorBrushCatalog.marker.id)
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

    controller.model.confirmRecipe(AnchorBrushCatalog.glaze.id)
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

    #expect(controller.model.selectedRecipeID == EditorBrushCatalog.chiselMarker.id)
    #expect(
        renderer.harnessPreparedDrawBrushIdentity?.definitionID
            == EditorBrushCatalog.chiselMarker.id
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

    #expect(controller.model.selectedRecipeID == EditorBrushCatalog.chiselMarker.id)
    #expect(store.writes == [EditorBrushCatalog.chiselMarker.id.rawValue])
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
        definition: EditorBrushCatalog.graphitePencil.definition
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

    await controller.selectBrush(EditorBrushCatalog.chiselMarker.id)

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
        definition: EditorBrushCatalog.chiselMarker.definition
    )
    let airbrush = try await compiler.compileAndActivate(
        definition: AnchorBrushCatalog.airbrush.definition
    )
    try controller.installBootstrapBrushes(draw: ink, eraser: eraser)

    let staleSelection = Task { @MainActor in
        await controller.selectBrush(AnchorBrushCatalog.marker.id)
    }
    for _ in 0..<32 where !gate.pendingIDs.contains(EditorBrushCatalog.chiselMarker.id) {
        await Task.yield()
    }
    #expect(gate.pendingIDs == [EditorBrushCatalog.chiselMarker.id])

    let currentSelection = Task { @MainActor in
        await controller.selectBrush(AnchorBrushCatalog.airbrush.id)
    }
    for _ in 0..<32 where gate.pendingIDs.count < 2 {
        await Task.yield()
    }
    #expect(Set(gate.pendingIDs) == [
        EditorBrushCatalog.chiselMarker.id,
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

    try gate.complete(EditorBrushCatalog.chiselMarker.id, with: marker)
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
        definition: EditorBrushCatalog.graphitePencil.definition
    )
    let eraser = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.eraser.definition
    )
    try source.installBootstrapBrushes(draw: graphite, eraser: eraser)
    try source.confirmBootstrapBrushSelection(
        EditorBrushCatalog.graphitePencil.id
    )

    let replacement = try source.replacementSession(
        renderer: replacementRenderer
    )
    #expect(
        replacement.model.selectedRecipeID
            == EditorBrushCatalog.graphitePencil.id
    )

    await replacement.selectBrush(AnchorBrushCatalog.marker.id)

    #expect(
        replacement.model.selectedRecipeID
            == EditorBrushCatalog.chiselMarker.id
    )
    #expect(store.writes == [
        EditorBrushCatalog.graphitePencil.id.rawValue,
        EditorBrushCatalog.chiselMarker.id.rawValue,
    ])
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
        definition: EditorBrushCatalog.chiselMarker.definition
    )
    try source.installBootstrapBrushes(draw: ink, eraser: eraser)

    let obsoleteSelection = Task { @MainActor in
        await source.selectBrush(EditorBrushCatalog.chiselMarker.id)
    }
    for _ in 0..<32 where gate.pendingIDs.isEmpty {
        await Task.yield()
    }
    #expect(gate.pendingIDs == [EditorBrushCatalog.chiselMarker.id])

    let replacement = try source.replacementSession(
        renderer: replacementRenderer
    )
    #expect(
        replacement.model.selectedRecipeID
            == EditorBrushCatalog.defaultDraw.id
    )

    try gate.complete(EditorBrushCatalog.chiselMarker.id, with: marker)
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
    #expect(controller.model.selectedRecipeID == EditorBrushCatalog.chiselMarker.id)

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
    controller.model.confirmRecipe(AnchorBrushCatalog.defaultDraw.id)
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

    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
    #expect(renderer.harnessRevision.rawValue == 2)
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
        try renderer.drainCompletedOperationsForHarness()
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
    #expect(renderer.hasActiveStroke)
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
        try renderer.drainCompletedOperationsForHarness()
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
        minimumAuthoritativeInputCount: 2
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
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
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
        _ = try renderer.flushPendingLiveForHarness()
        _ = try renderer.finishCommitForHarness()
        #expect(controller.transactionStateForTesting == .idle)
        return try canonicalBytes(renderer)
    }

    let expectedResult = try await render(includeLatePriorUpdate: false)
    let interleavedResult = try await render(includeLatePriorUpdate: true)
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

    #expect(throws: MetalRendererError.self) {
        _ = try renderer.finishCommitForHarness()
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
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
}

@Test
@MainActor
func synchronousRendererFailureClearsEstimateBookkeeping() throws {
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
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()
    #expect(controller.transactionStateForTesting == .idle)
    #expect(reportedErrors == [.invalidStrokeLifecycle])
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
func controllerSubmitsPredictedMovesAsOneReplaceableSuffixBatch()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    controller.model.confirmRecipe(AnchorBrushCatalog.marker.id)
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
        minimumAuthoritativeInputCount: 2
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

    let mixedAuthoritativeInputBefore = try #require(
        renderer.compatibilityInkCoordinatorSnapshotForTesting?
            .commitMetadata.inputSampleCount
    )
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
        minimumAuthoritativeInputCount:
            mixedAuthoritativeInputBefore + 1
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

    let authoritativeInputBefore = try #require(
        renderer.compatibilityInkCoordinatorSnapshotForTesting?
            .commitMetadata.inputSampleCount
    )
    controller.handleStrokeSample(
        controllerMovedSample(x: 30, timestamp: 2, kind: .actual)
    )
    let settled = try await awaitActorTransientSamples(
        renderer,
        predictedXs: [],
        minimumAuthoritativeInputCount: authoritativeInputBefore + 1
    )
    #expect(settled.predictedSamples.isEmpty)
    #expect(
        renderer.compatibilityInkCoordinatorSnapshotForTesting?
            .commitMetadata.inputSampleCount
            == authoritativeInputBefore + 1
    )
    controller.handleStrokeSample(controllerSample(.cancelled))
    try awaitControllerRendererIdleForHarness(renderer)
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
func awaitedClearPropagatesSynchronousRequestFailureAndRecovers()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    var shouldFail = true
    let controller = EditorSessionController(
        renderer: renderer,
        requestClear: { token, maximumRetainedBytes in
            if shouldFail {
                throw MetalRendererError.commandBufferUnavailable
            }
            try renderer.requestClear(
                token: token,
                maximumRetainedBytes: maximumRetainedBytes
            )
        }
    )

    await #expect(throws: MetalRendererError.commandBufferUnavailable) {
        try await controller.clearAndAwaitCompletion()
    }
    #expect(controller.transactionStateForTesting == .idle)
    #expect(renderer.isIdle)
    #expect(controller.lastRecordedRasterCommandForTesting == nil)

    shouldFail = false
    try await controller.clearAndAwaitCompletion()
    #expect(controller.transactionStateForTesting == .idle)
    #expect(renderer.isIdle)
    #expect(
        controller.lastRecordedRasterCommandForTesting?.kind == .clear
    )
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
