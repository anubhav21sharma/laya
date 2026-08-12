import EditorCore
import Foundation
import MetalRenderer
import PatternEngine

enum EditorSessionLayerError: Error, Equatable {
    case mutationRequiresIdle
    case rendererStorageUnavailable(UUID)
}

enum StrokeBeginAdmissionResult: String, Equatable, Sendable {
    case notObserved
    case accepted
    case deferredPointerStream
    case rendererBusyDeferred
    case awaitingEstimatedUpdates
    case footprintOutsideDocument
    case toolUnavailable
    case transactionNotIdle
    case transactionOperationPending
    case activeLayerUnavailable
    case compiledBrushUnavailable
}

@MainActor
func handleEditorShortcut(
    _ shortcut: EditorShortcut,
    controller: EditorSessionController,
    pointerCancellationGeneration: inout UInt
) {
    switch shortcut {
    case .cancel:
        controller.handleFocusLoss()
        pointerCancellationGeneration &+= 1
    default:
        controller.handleShortcut(shortcut)
    }
}

@MainActor
final class EditorSessionController {
    let model: EditorModel
    let renderer: GridRenderer
    var onError: ((MetalRendererError) -> Void)?
    var onNormalizedInput: ((StrokeSample) -> Void)?
    private(set) var isSpaceDown = false
    private(set) var lastStrokeBeginAdmissionResult:
        StrokeBeginAdmissionResult = .notObserved
    private let strokeSeedSessionEntropy: UInt64
    private var nextStrokeSequence: UInt64 = 1
    private var activeDrawBrush: CompiledBrush?
    private var activeEraserBrush: CompiledBrush?
    private var selectionGeneration: UInt64 = 0
    private let compileDefinition:
        @MainActor @Sendable (BrushDefinition) async throws -> CompiledBrush
    private let selectionStore: (any EditorBrushSelectionStore)?
    private var diagnosticFixedStrokeSeed: UInt64?
    private var pendingEstimatedProperties:
        [Int: StrokeEstimatedProperties] = [:]
    private var predictedEstimationIndices: Set<Int> = []
    private var ignoredLateEstimationIndices: Set<Int> = []
    private struct RoutedStrokeSample {
        let sample: StrokeSample
        let inputGeneration: UInt64?
        let batchID: UInt64?
        let submittedPredictionSampleCount: Int?
    }

    private var deferredPointerSamples: [RoutedStrokeSample] = []
    private var deferredPointerDrainScratch: [RoutedStrokeSample] = []
    private var deferredPointerBatchScratch: [StrokeSample] = []
    private var deferredPointerOverflowed = false
    private var deferredEstimationIndices: Set<Int> = []
    private var nextDeferredPointerBatchID: UInt64 = 1
    private(set) var deferredPointerResumeCountForTesting: UInt64 = 0
    private static let deferredPointerSampleCapacity =
        TransientStrokeBufferContract.wholeStrokeSampleCapacity

    private var transaction = EditorTransaction()
    private var history: DocumentHistory
    private(set) var layerStack: LayerStack
    private var activeStrokeLayerID: UUID?
    private var pendingRasterMutation: PendingRasterMutation?
    private var pendingTileResize: PendingTileResize?
    private var pendingHistoryNavigation: PendingHistoryNavigation?
    /// Metadata emitted by the reducer after cancelling an active stroke must
    /// wait for the actor-owned stroke workspace to finish retiring. The
    /// reducer operation stays pending until this exact effect is applied.
    private var pendingRendererIdleMetadataEffect: EditorTransactionEffect?
    private var pendingPaintRevisionReleaseIDs:
        Set<StoredRasterRevisionID> = []
    private var paintRevisionReleaseTask: Task<Void, Never>?
    private var emptyConfigurationReplacementInFlight = false
    private let requestStrokeCancellation: (
        RendererOperationToken
    ) throws -> Void
    private(set) var lastRecordedRasterCommandForTesting: RasterHistoryCommand?
    private(set) var lastRecordedResizeCommandForTesting: TileResizeHistoryCommand?
    private(set) var lastRecordedLayerRevisionForTesting:
        LayerSurfaceRevisionReference?
    private var awaitedClear: AwaitedClear?

    private struct PendingRasterMutation {
        let token: EditorTransactionToken
        let kind: RasterEditKind
        let layerID: UUID
    }

    private struct PendingTileResize {
        let token: EditorTransactionToken
        let before: PixelSize
        let after: PixelSize
    }

    private struct PendingHistoryNavigation {
        let operationToken: EditorTransactionToken
        let historyToken: UInt64
        let targetPixelSize: PixelSize?
    }

    private struct AwaitedClear {
        let token: EditorTransactionToken
        let continuation: CheckedContinuation<Void, Error>
    }

    init(
        model: EditorModel = EditorModel(),
        renderer: GridRenderer,
        layerStack: LayerStack = .initial(),
        documentHistory: DocumentHistory? = nil,
        requestStrokeCancellation: ((
            RendererOperationToken
        ) throws -> Void)? = nil,
        compileDefinition: (@MainActor @Sendable
            (BrushDefinition) async throws -> CompiledBrush)? = nil,
        selectionStore: (any EditorBrushSelectionStore)? = nil,
        strokeSeedSessionEntropy: UInt64 = EditorSessionController
            .makeStrokeSeedSessionEntropy()
    ) {
        self.model = model
        self.renderer = renderer
        precondition(
            renderer.layerStack == layerStack,
            "Controller and renderer must share one initial layer stack."
        )
        activeDrawBrush = renderer.preparedBrush(for: .draw)
        activeEraserBrush = renderer.preparedBrush(for: .erase)
        if let documentHistory {
            precondition(
                documentHistory.maximumBytes == renderer.historyByteBudget,
                "Injected history must share the renderer history budget."
            )
            history = documentHistory
        } else {
            history = DocumentHistory(
                maximumBytes: renderer.historyByteBudget,
                initialDocumentIsEmpty: !renderer.documentDomainLocked
            )
        }
        self.layerStack = layerStack
        self.strokeSeedSessionEntropy = strokeSeedSessionEntropy
        self.requestStrokeCancellation = requestStrokeCancellation ?? {
            try renderer.cancelStroke(token: $0)
        }
        self.compileDefinition = compileDefinition
            ?? Self.unsupportedDefinitionCompilation
        self.selectionStore = selectionStore
        deferredPointerSamples.reserveCapacity(
            Self.deferredPointerSampleCapacity
        )
        deferredPointerDrainScratch.reserveCapacity(
            Self.deferredPointerSampleCapacity
        )
        deferredPointerBatchScratch.reserveCapacity(
            Self.deferredPointerSampleCapacity
        )
        deferredEstimationIndices.reserveCapacity(
            Self.deferredPointerSampleCapacity
        )
        model.confirmDocumentConfiguration(renderer.documentConfiguration)
        model.confirmPixelSize(renderer.pixelSize)
        model.confirmGeometryLocks(
            documentDomainLocked: renderer.documentDomainLocked,
            radialGeometryLocked: renderer.radialGeometryLocked
        )
        model.confirmLayerStack(layerStack)
        renderer.setInteractiveGridVisibility(model.showGrid)
        renderer.onOperationCompleted = { [weak self] completion in
            self?.handleRendererCompletion(completion)
        }
        renderer.onIdleStateChange = { [weak self] isIdle in
            self?.handleRendererIdleStateChange(isIdle)
        }
        refreshDerivedModelState()
    }

    var historyAvailabilityForTesting: (canUndo: Bool, canRedo: Bool) {
        (history.canUndo, history.canRedo)
    }

    var layerStackForTesting: LayerStack { layerStack }
    var currentLayerStack: LayerStack { layerStack }

    private static func unsupportedDefinitionCompilation(
        _: BrushDefinition
    ) async throws -> CompiledBrush {
        throw MetalRendererError.unsupportedBrushProgram
    }

    var transactionStateForTesting: EditorTransactionState {
        transaction.state
    }

    struct DeferredPointerStorageSnapshotForTesting: Equatable {
        let queuedSampleCount: Int
        let queuedSampleCapacity: Int
        let drainSampleCapacity: Int
        let estimationIndexCapacity: Int
    }

    var deferredPointerStorageSnapshotForTesting:
        DeferredPointerStorageSnapshotForTesting
    {
        DeferredPointerStorageSnapshotForTesting(
            queuedSampleCount: deferredPointerSamples.count,
            queuedSampleCapacity: deferredPointerSamples.capacity,
            drainSampleCapacity: deferredPointerDrainScratch.capacity,
            estimationIndexCapacity: deferredEstimationIndices.capacity
        )
    }

    func handleStrokeSample(
        _ sample: StrokeSample,
        inputGeneration: UInt64? = nil
    ) {
        if hasDeferredPointerStream {
            if sample.phase == .began {
                lastStrokeBeginAdmissionResult = .deferredPointerStream
            }
            enqueueDeferredPointerSample(
                sample,
                inputGeneration: inputGeneration
            )
            return
        }
        if sample.phase == .began,
           transaction.state == .idle,
           !renderer.isIdle
        {
            lastStrokeBeginAdmissionResult = .rendererBusyDeferred
            enqueueDeferredPointerSample(
                sample,
                inputGeneration: inputGeneration
            )
            return
        }
        if sample.kind == .estimatedUpdate,
           let index = sample.estimationUpdateIndex,
           ignoredLateEstimationIndices.contains(index)
        {
            return
        }
        if sample.kind == .estimatedUpdate {
            onNormalizedInput?(sample)
            handleEstimatedPropertiesUpdate(sample)
            return
        }
        if sample.phase == .began, isAwaitingEstimatedUpdates {
            lastStrokeBeginAdmissionResult = .awaitingEstimatedUpdates
            enqueueDeferredPointerSample(
                sample,
                inputGeneration: inputGeneration
            )
            ignorePendingEstimatedUpdates()
            emitEstimatedUpdateFallbackDiagnostic()
            apply(.finalizeAwaitingEstimates)
            return
        }
        if sample.phase == .began,
           !renderer.strokeFootprintIntersectsDocument(
               at: sample.position,
               diameter: model.brushDiameter
           )
        {
            lastStrokeBeginAdmissionResult = .footprintOutsideDocument
            return
        }
        onNormalizedInput?(sample)
        let event: EditorTransactionEvent
        switch sample.phase {
        case .began:
            guard let tool = strokeTool else {
                lastStrokeBeginAdmissionResult = .toolUnavailable
                return
            }
            guard transaction.state == .idle else {
                lastStrokeBeginAdmissionResult = .transactionNotIdle
                return
            }
            guard transaction.pendingOperation == nil else {
                lastStrokeBeginAdmissionResult =
                    .transactionOperationPending
                return
            }
            let layerID: UUID
            do {
                layerID = try activeRasterLayerID()
            } catch {
                lastStrokeBeginAdmissionResult = .activeLayerUnavailable
                report(.commandFailed(error.localizedDescription))
                return
            }
            resetEstimatedUpdatesForNewStroke()
            trackPendingEstimatedProperties(in: sample)
            let compiledBrush = tool == .draw
                ? activeDrawBrush
                : activeEraserBrush
            guard let compiledBrush else {
                lastStrokeBeginAdmissionResult = .compiledBrushUnavailable
                report(.compiledBrushUnavailable(
                    tool == .draw ? .draw : .erase
                ))
                return
            }
            let program = compiledBrush.program
            let seed = takeStrokeSeed()
            let style = StrokeRenderStyle(
                color: model.inkColor,
                diameter: model.brushDiameter,
                compositeMode: tool == .draw ? .draw : .erase,
                eraserStrength: model.eraserStrength,
                program: program,
                renderIdentity: compiledBrush.renderIdentity,
                seed: seed
            )
            event = .pointerBegan(
                sample,
                tool: tool,
                style: style
            )
            activeStrokeLayerID = layerID
            lastStrokeBeginAdmissionResult = .accepted
        case .moved:
            guard isCollectingStroke else { return }
            trackPendingEstimatedProperties(in: sample)
            event = .pointerMoved(sample)
        case .ended:
            guard isCollectingStroke else { return }
            trackPendingEstimatedProperties(in: sample)
            event = pendingEstimatedProperties.isEmpty
                ? .pointerEnded(sample)
                : .pointerEndedAwaitingEstimates(sample)
        case .cancelled:
            ignorePendingEstimatedUpdates()
            event = .pointerCancelled
        }
        apply(event)
    }

    func handleStrokeSamples(
        _ samples: [StrokeSample],
        inputGeneration: UInt64? = nil,
        submittedPredictionSampleCount: Int? = nil
    ) {
        handleStrokeSampleBatch(
            samples,
            inputGeneration: inputGeneration,
            submittedPredictionSampleCount:
                submittedPredictionSampleCount
        )
    }

    private func handleStrokeSampleBatch<Samples>(
        _ samples: Samples,
        inputGeneration: UInt64?,
        submittedPredictionSampleCount: Int?
    ) where
        Samples: RandomAccessCollection,
        Samples.Element == StrokeSample
    {
        if hasDeferredPointerStream {
            if samples.contains(where: { $0.phase == .began }) {
                lastStrokeBeginAdmissionResult = .deferredPointerStream
            }
            enqueueDeferredPointerBatch(
                samples,
                inputGeneration: inputGeneration,
                submittedPredictionSampleCount:
                    submittedPredictionSampleCount
            )
            return
        }
        let rawPredictionStart = samples.firstIndex {
            $0.kind == .predicted
        } ?? samples.endIndex
        let authoritativePrefix = samples[..<rawPredictionStart]
        let containsStrokeBegin = authoritativePrefix.contains {
            $0.phase == .began && $0.kind != .estimatedUpdate
        }
        if containsStrokeBegin,
           transaction.state == .idle,
           !renderer.isIdle
        {
            lastStrokeBeginAdmissionResult = .rendererBusyDeferred
            enqueueDeferredPointerBatch(
                samples,
                inputGeneration: inputGeneration,
                submittedPredictionSampleCount:
                    submittedPredictionSampleCount
            )
            return
        }
        if containsStrokeBegin,
           transaction.state == .idle
        {
            for sample in authoritativePrefix {
                handleStrokeSample(
                    sample,
                    inputGeneration: inputGeneration
                )
            }
            guard rawPredictionStart < samples.endIndex
                    || (submittedPredictionSampleCount ?? 0) > 0,
                  case let .drawing(drawing) = transaction.state,
                  drawing.phase == .collecting,
                  transaction.pendingOperation == nil
            else {
                return
            }
            handleStrokeSampleBatch(
                samples[rawPredictionStart...],
                inputGeneration: inputGeneration,
                submittedPredictionSampleCount:
                    submittedPredictionSampleCount
            )
            return
        }
        guard samples.count > 1
                || submittedPredictionSampleCount != nil,
              case let .drawing(drawing) = transaction.state,
              drawing.phase == .collecting,
              transaction.pendingOperation == nil
        else {
            for sample in samples {
                handleStrokeSample(
                    sample,
                    inputGeneration: inputGeneration
                )
            }
            return
        }

        // BrushInputAdapter guarantees an authoritative prefix followed by a
        // terminal prediction suffix. Preserve every authoritative sample, but
        // admit only the renderer's bounded prediction prefix on Main.
        var predictionStart = samples.endIndex
        var sampleIndex = samples.startIndex
        var canUsePartitionedBatch = true
        while sampleIndex < samples.endIndex {
            let sample = samples[sampleIndex]
            if sample.kind == .predicted {
                predictionStart = sampleIndex
                break
            }
            guard sample.phase == .moved,
                  sample.kind == .actual || sample.kind == .coalesced
            else {
                canUsePartitionedBatch = false
                break
            }
            sampleIndex = samples.index(after: sampleIndex)
        }
        let normalizedPredictionSampleCount = samples.distance(
            from: predictionStart,
            to: samples.endIndex
        )
        let admittedPredictionEnd = samples.index(
            predictionStart,
            offsetBy: min(
                normalizedPredictionSampleCount,
                PredictionAdmissionLimits.maximumNormalizedSampleCount
            )
        )
        let effectiveSubmittedPredictionSampleCount = max(
            normalizedPredictionSampleCount,
            submittedPredictionSampleCount
                ?? normalizedPredictionSampleCount
        )
        if canUsePartitionedBatch {
            for sample in samples[predictionStart..<admittedPredictionEnd] {
                guard sample.phase == .moved,
                      sample.kind == .predicted
                else {
                    canUsePartitionedBatch = false
                    break
                }
            }
        }
        guard canUsePartitionedBatch else {
            for sample in samples {
                handleStrokeSample(
                    sample,
                    inputGeneration: inputGeneration
                )
            }
            return
        }
        let admittedSamples = samples[..<admittedPredictionEnd]
        for sample in admittedSamples {
            onNormalizedInput?(sample)
            trackPendingEstimatedProperties(in: sample)
        }
        let effects = admittedSamples.flatMap {
            transaction.apply(.pointerMoved($0))
        }
        guard effects.count == admittedSamples.count,
              effects.allSatisfy({ effect in
                  if case let .appendStroke(token, _) = effect {
                      return token == drawing.token
                  }
                  return false
              })
        else {
            execute(effects)
            refreshDerivedModelState()
            return
        }

        do {
            try renderer.appendStrokeBatch(
                token: rendererToken(drawing.token),
                authoritativeSamples: samples[..<predictionStart],
                predictedSamples:
                    samples[predictionStart..<admittedPredictionEnd],
                submittedPredictionSampleCount:
                    effectiveSubmittedPredictionSampleCount
            )
        } catch let error as MetalRendererError {
            if let firstEffect = effects.first {
                handleSynchronousFailure(
                    of: firstEffect,
                    error: error
                )
            } else {
                report(error)
                cancelCollectingStrokeAfterSynchronousFailure(
                    token: drawing.token
                )
            }
        } catch {
            let rendererError = MetalRendererError.commandFailed(
                error.localizedDescription
            )
            if let firstEffect = effects.first {
                handleSynchronousFailure(
                    of: firstEffect,
                    error: rendererError
                )
            } else {
                report(rendererError)
                cancelCollectingStrokeAfterSynchronousFailure(
                    token: drawing.token
                )
            }
        }
        refreshDerivedModelState()
        resumeDeferredPointerIfIdle()
    }

    func handleTiling(_ tiling: TilingKind) {
        guard tiling.isPeriodic else { return }
        if case .finite = model.documentConfiguration {
            let configuration = PeriodicSymmetryConfiguration
                .defaultConfiguration(
                    presetID: tiling,
                    canonicalRasterSize: model.pixelSize
                )
            replaceEmptyDocumentConfiguration(.periodic(configuration))
            return
        }
        apply(.tilingIntent(tiling))
    }

    func handlePeriodicConfiguration(
        _ configuration: PeriodicSymmetryConfiguration
    ) {
        guard configuration.presetID.isPeriodic else { return }
        if case .finite = model.documentConfiguration {
            replaceEmptyDocumentConfiguration(.periodic(configuration))
            return
        }
        apply(.periodicConfigurationIntent(configuration))
    }

    func handleFiniteConfiguration(
        _ configuration: FiniteSymmetryConfiguration
    ) {
        replaceEmptyDocumentConfiguration(.finite(configuration))
    }

    func selectSeamlessPatternMode() {
        handlePeriodicConfiguration(model.periodicConfiguration)
    }

    func selectPlainCanvasMode() {
        handleFiniteConfiguration(.plain)
    }

    func selectRadialMode() {
        let targetSize = targetPixelSize(for: .finite(.plain))
        let radial = model.radialConfiguration
            ?? RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 8,
                center: WorldPoint(
                    x: Float(targetSize.width) * 0.5,
                    y: Float(targetSize.height) * 0.5
                )
            )
        handleFiniteConfiguration(.radial(radial))
    }

    func handleTileSize(_ pixelSize: PixelSize) {
        guard EditorConfiguration.isValidTileSize(pixelSize) else {
            report(
                .invalidTileDimensions(
                    width: pixelSize.width,
                    height: pixelSize.height
                )
            )
            return
        }
        apply(.tileSizeIntent(pixelSize))
    }

    func handleGridVisibility(_ visible: Bool) {
        apply(.gridVisibilityIntent(visible))
    }

    func handleTool(_ tool: EditorTool) {
        apply(.toolIntent(tool))
    }

    func handleInkColor(_ color: InkColor) {
        apply(.colorIntent(color))
    }

    func selectBrush(_ id: BrushRecipeID) async {
        let generation = nextSelectionGeneration()
        guard renderer.isIdle,
              transaction.state == .idle,
              transaction.pendingOperation == nil,
              let resolvedID = EditorBrushCatalog.resolveSelection(id),
              let entry = EditorBrushCatalog.drawEntry(for: resolvedID)
        else { return }
        do {
            let compiled = try await compileDefinition(entry.definition)
            guard compiled.renderIdentity.definitionID == resolvedID else {
                throw MetalRendererError.invalidCompiledBrush
            }
            guard generation == selectionGeneration,
                  renderer.isIdle,
                  transaction.state == .idle,
                  transaction.pendingOperation == nil
            else { return }
            try renderer.activateDrawBrush(compiled)
            activeDrawBrush = compiled
            try model.confirmRecipe(resolvedID)
            selectionStore?.writeSelectedBrushID(resolvedID.rawValue)
        } catch let error as MetalRendererError {
            if generation == selectionGeneration {
                report(error)
            }
        } catch {
            if generation == selectionGeneration {
                report(.commandFailed(error.localizedDescription))
            }
        }
    }

    private func nextSelectionGeneration() -> UInt64 {
        selectionGeneration &+= 1
        return selectionGeneration
    }

    func installDiagnosticDrawBrush(_ brush: CompiledBrush) throws {
        guard renderer.isIdle else {
            throw MetalRendererError.commitPendingInput
        }
        try renderer.activateDrawBrush(brush)
        activeDrawBrush = brush
    }

    func installBootstrapBrushes(
        draw: CompiledBrush,
        eraser: CompiledBrush
    ) throws {
        try renderer.activateEraserBrush(eraser)
        activeEraserBrush = eraser
        try installDiagnosticDrawBrush(draw)
    }

    func confirmBootstrapBrushSelection(_ id: BrushRecipeID) throws {
        guard activeDrawBrush?.renderIdentity.definitionID == id,
              renderer.preparedBrush(for: .draw)?.renderIdentity.definitionID
                == id
        else {
            throw MetalRendererError.invalidCompiledBrush
        }
        try model.confirmRecipe(id)
        selectionStore?.writeSelectedBrushID(id.rawValue)
    }

    func replacementSession(
        renderer replacementRenderer: GridRenderer
    ) throws -> EditorSessionController {
        guard renderer.isIdle,
              transaction.state == .idle,
              transaction.pendingOperation == nil,
              replacementRenderer.isIdle
        else {
            throw MetalRendererError.commitPendingInput
        }
        if let activeDrawBrush {
            try replacementRenderer.activateDrawBrush(activeDrawBrush)
        }
        if let activeEraserBrush {
            try replacementRenderer.activateEraserBrush(activeEraserBrush)
        }

        let replacement = EditorSessionController(
            renderer: replacementRenderer,
            layerStack: replacementRenderer.layerStack,
            compileDefinition: compileDefinition,
            selectionStore: selectionStore
        )
        replacement.model.confirmTool(model.tool)
        replacement.model.confirmInkColor(model.inkColor)
        replacement.model.confirmBrushDiameter(model.brushDiameter)
        try replacement.model.confirmRecipe(model.selectedRecipeID)
        replacement.handleGridVisibility(model.showGrid)
        _ = nextSelectionGeneration()
        return replacement
    }

    func setDiagnosticFixedStrokeSeed(_ seed: UInt64?) throws {
        guard renderer.isIdle else {
            throw MetalRendererError.commitPendingInput
        }
        if let seed, seed == 0 {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        diagnosticFixedStrokeSeed = seed
    }

    func stepBrush(larger: Bool) {
        let diameter = EditorConfiguration.stepBrush(
            model.brushDiameter,
            larger: larger,
            pixelSize: model.pixelSize
        )
        apply(.brushDiameterIntent(diameter))
    }

    func handleShortcut(_ shortcut: EditorShortcut) {
        switch shortcut {
        case let .selectTool(tool):
            handleTool(tool)
        case .clear:
            clear()
        case .undo:
            undo()
        case .redo:
            redo()
        case let .stepBrush(larger):
            stepBrush(larger: larger)
        case let .stepTile(larger):
            handleTileSize(
                EditorConfiguration.stepTile(
                    model.pixelSize,
                    larger: larger
                )
            )
        case .toggleGrid:
            handleGridVisibility(!model.showGrid)
        case let .selectTiling(index1):
            guard index1 > 0,
                  let tiling = TilingKind(rawValue: UInt32(index1 - 1)),
                  tiling.isPeriodic
            else { return }
            handleTiling(tiling)
        case .cancel:
            cancelTransientEdit()
        case let .spaceChanged(isDown):
            isSpaceDown = isDown
        }
    }

    func clear() {
        apply(.command(.clear))
    }

    func clearAndAwaitCompletion() async throws {
        guard transaction.state == .idle,
              transaction.pendingOperation == nil,
              awaitedClear == nil
        else {
            throw MetalRendererError.commitPendingInput
        }
        let effects = transaction.apply(.command(.clear))
        guard effects.count == 1,
              case let .performCommand(token, .clear) = effects[0]
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        refreshDerivedModelState()

        try await withCheckedThrowingContinuation { continuation in
            awaitedClear = AwaitedClear(
                token: token,
                continuation: continuation
            )
            do {
                try execute(effects[0])
            } catch {
                let rendererError = (error as? MetalRendererError)
                    ?? .commandFailed(error.localizedDescription)
                handleSynchronousFailure(
                    of: effects[0],
                    error: rendererError
                )
                finishAwaitedClear(
                    token: token,
                    result: .failure(rendererError)
                )
            }
        }
    }

    /// Establishes an empty review document in one awaited production
    /// operation. Successful replacement removes the clear/setup history so a
    /// review card always starts from an empty, non-undoable configuration.
    func resetReviewDocument(
        to configuration: SymmetryDocumentConfiguration
    ) async throws {
        try await clearAndAwaitCompletion()
        guard transaction.state == .idle,
              transaction.pendingOperation == nil,
              awaitedClear == nil,
              !emptyConfigurationReplacementInFlight,
              renderer.isIdle,
              history.currentDocumentIsEmpty
        else {
            throw MetalRendererError.commitPendingInput
        }
        emptyConfigurationReplacementInFlight = true
        refreshDerivedModelState()
        defer {
            emptyConfigurationReplacementInFlight = false
            refreshDerivedModelState()
        }
        do {
            try await renderer.replaceEmptyDocumentConfiguration(
                configuration,
                pixelSize: targetPixelSize(for: configuration)
            )
            releaseHistoryRevisions(history.removeAll())
            refreshDerivedModelState()
        } catch let error as MetalRendererError {
            report(error)
            throw error
        } catch {
            let rendererError = MetalRendererError.commandFailed(
                error.localizedDescription
            )
            report(rendererError)
            throw rendererError
        }
        guard renderer.documentConfiguration == configuration,
              model.documentConfiguration == configuration,
              history.currentDocumentIsEmpty,
              !history.canUndo,
              !history.canRedo
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
    }

    func undo() {
        apply(.command(.undo))
    }

    func redo() {
        apply(.command(.redo))
    }

    func addLayer(_ descriptor: LayerDescriptor, at order: Int) throws {
        try mutateLayerStack { try $0.add(descriptor, at: order) }
    }

    func addLayerAndActivate(
        _ descriptor: LayerDescriptor,
        at order: Int
    ) throws {
        try mutateLayerStack {
            try $0.add(descriptor, at: order)
            try $0.setActiveLayer(descriptor.id)
        }
    }

    func deleteLayer(_ id: UUID) throws {
        guard transaction.state == .idle,
              transaction.pendingOperation == nil,
              renderer.isIdle
        else {
            throw EditorSessionLayerError.mutationRequiresIdle
        }

        var candidate = layerStack
        let removal = try candidate.delete(id)
        let revision = try renderer.applyLayerStack(candidate)
        let command = DocumentHistoryCommand.layerDeletion(
            LayerDeletionHistoryCommand(
                removal: removal,
                layerRevision: revision
            )
        )
        do {
            try history.validateNewCommand(
                retainedBytes: command.retainedBytes
            )
        } catch {
            _ = try? renderer.restoreLayerStackBefore(revision)
            releaseHistoryRevisions([revision.id])
            throw error
        }

        layerStack = candidate
        model.confirmLayerStack(candidate)
        lastRecordedLayerRevisionForTesting = revision
        let released = history.appendSuccessful(command)
        releaseHistoryRevisions(released)
        refreshDerivedModelState()
    }

    func moveLayer(_ id: UUID, to order: Int) throws {
        try mutateLayerStack { try $0.move(id, to: order) }
    }

    func setActiveLayer(_ id: UUID) throws {
        try mutateLayerStack { try $0.setActiveLayer(id) }
    }

    func renameLayer(_ id: UUID, to name: String) throws {
        try mutateLayerStack { try $0.rename(id, to: name) }
    }

    func setLayerVisibility(_ id: UUID, isVisible: Bool) throws {
        try mutateLayerStack {
            try $0.setVisibility(id, isVisible: isVisible)
        }
    }

    func setLayerOpacity(_ id: UUID, opacity: Float) throws {
        try mutateLayerStack { try $0.setOpacity(id, opacity: opacity) }
    }

    func setLayerLock(_ id: UUID, isLocked: Bool) throws {
        try mutateLayerStack { try $0.setLock(id, isLocked: isLocked) }
    }

    func setLayerBlendMode(_ id: UUID, blendMode: LayerBlendMode) throws {
        try mutateLayerStack {
            try $0.setBlendMode(id, blendMode: blendMode)
        }
    }

    private func mutateLayerStack(
        _ mutation: (inout LayerStack) throws -> Void
    ) throws {
        guard transaction.state == .idle,
              transaction.pendingOperation == nil,
              renderer.isIdle
        else {
            throw EditorSessionLayerError.mutationRequiresIdle
        }
        var candidate = layerStack
        try mutation(&candidate)
        guard candidate != layerStack else { return }
        let revision = try renderer.applyLayerStack(candidate)
        let command = DocumentHistoryCommand.layerMetadata(
            LayerStackMetadataCommand(
                before: layerStack.snapshot,
                after: candidate.snapshot,
                layerRevision: revision
            )
        )
        do {
            try history.validateNewCommand(retainedBytes: command.retainedBytes)
        } catch {
            _ = try? renderer.restoreLayerStackBefore(revision)
            releaseHistoryRevisions([revision.id])
            throw error
        }
        layerStack = candidate
        model.confirmLayerStack(candidate)
        lastRecordedLayerRevisionForTesting = revision
        let released = history.appendSuccessful(command)
        releaseHistoryRevisions(released)
        refreshDerivedModelState()
    }

    func cancelTransientEdit() {
        discardDeferredPointerStream()
        ignorePendingEstimatedUpdates()
        apply(.pointerCancelled)
    }

    func handleFocusLoss() {
        isSpaceDown = false
        if isAwaitingEstimatedUpdates {
            ignorePendingEstimatedUpdates()
            emitEstimatedUpdateFallbackDiagnostic()
            apply(.finalizeAwaitingEstimates)
        } else {
            cancelTransientEdit()
        }
    }

    func pan(byScreenDelta delta: SIMD2<Float>) {
        guard transaction.state == .idle,
              transaction.pendingOperation == nil
        else { return }
        renderer.pan(byScreenDelta: delta)
    }

    func zoom(by factor: Float, anchor: ScreenPoint) {
        guard transaction.state == .idle,
              transaction.pendingOperation == nil
        else { return }
        renderer.zoom(by: factor, anchor: anchor)
    }

    private var strokeTool: StrokeTool? {
        switch model.tool {
        case .draw:
            .draw
        case .erase:
            .erase
        case .select, .transform:
            nil
        }
    }

    private var isAwaitingEstimatedUpdates: Bool {
        guard case let .drawing(drawing) = transaction.state else {
            return false
        }
        return drawing.phase == .awaitingEstimatedUpdates
    }

    private var isCollectingStroke: Bool {
        guard case let .drawing(drawing) = transaction.state else {
            return false
        }
        return drawing.phase == .collecting
            && transaction.pendingOperation == nil
    }

    private func resetEstimatedUpdatesForNewStroke() {
        pendingEstimatedProperties.removeAll(keepingCapacity: true)
        predictedEstimationIndices.removeAll(keepingCapacity: true)
        ignoredLateEstimationIndices.removeAll(keepingCapacity: true)
    }

    private func trackPendingEstimatedProperties(
        in sample: StrokeSample
    ) {
        if sample.kind == .actual || sample.kind == .coalesced {
            for index in predictedEstimationIndices {
                pendingEstimatedProperties.removeValue(forKey: index)
            }
            predictedEstimationIndices.removeAll(keepingCapacity: true)
        }
        guard let index = sample.estimationUpdateIndex else { return }
        if sample.estimatedPropertiesExpectingUpdates.isEmpty {
            pendingEstimatedProperties.removeValue(forKey: index)
            predictedEstimationIndices.remove(index)
        } else {
            pendingEstimatedProperties[index] =
                sample.estimatedPropertiesExpectingUpdates
            if sample.kind == .predicted {
                predictedEstimationIndices.insert(index)
            }
        }
    }

    private func handleEstimatedPropertiesUpdate(
        _ sample: StrokeSample
    ) {
        guard let index = sample.estimationUpdateIndex,
              !ignoredLateEstimationIndices.contains(index),
              pendingEstimatedProperties[index] != nil
        else {
            return
        }
        if sample.estimatedPropertiesExpectingUpdates.isEmpty {
            pendingEstimatedProperties.removeValue(forKey: index)
            predictedEstimationIndices.remove(index)
        } else {
            pendingEstimatedProperties[index] =
                sample.estimatedPropertiesExpectingUpdates
        }
        apply(
            .estimatedPropertiesUpdated(
                sample,
                resolvesLastPending:
                    pendingEstimatedProperties.isEmpty
            )
        )
        if pendingEstimatedProperties.isEmpty {
            ignoredLateEstimationIndices.insert(index)
        }
    }

    private func ignorePendingEstimatedUpdates() {
        ignoredLateEstimationIndices.formUnion(
            pendingEstimatedProperties.keys
        )
        pendingEstimatedProperties.removeAll(keepingCapacity: true)
        predictedEstimationIndices.removeAll(keepingCapacity: true)
    }

    private func emitEstimatedUpdateFallbackDiagnostic() {
        #if DEBUG
        debugPrint(
            "Laya: finalizing stroke before pending estimated properties resolved."
        )
        #endif
    }

    private func apply(_ event: EditorTransactionEvent) {
        execute(transaction.apply(event))
        refreshDerivedModelState()
    }

    private func execute(_ effects: [EditorTransactionEffect]) {
        for (index, effect) in effects.enumerated() {
            do {
                try execute(effect)
            } catch let error as MetalRendererError {
                handleSynchronousFailure(of: effect, error: error)
                failUnexecutedEffects(
                    effects.dropFirst(index + 1),
                    because: error
                )
                break
            } catch {
                let rendererError = MetalRendererError.commandFailed(
                    error.localizedDescription
                )
                handleSynchronousFailure(of: effect, error: rendererError)
                failUnexecutedEffects(
                    effects.dropFirst(index + 1),
                    because: rendererError
                )
                break
            }
        }
    }

    private func execute(_ effect: EditorTransactionEffect) throws {
        switch effect {
        case let .beginStroke(token, sample, _, style):
            try renderer.beginStroke(
                token: rendererToken(token),
                sample: sample,
                style: style
            )
        case let .appendStroke(token, sample):
            try renderer.appendStroke(
                token: rendererToken(token),
                sample: sample
            )
        case let .requestStrokeCommit(token, sample):
            try renderer.requestStrokeCommit(
                token: rendererToken(token),
                sample: sample
            )
        case let .finishStrokeTransient(token, sample):
            try renderer.finishStrokeTransient(
                token: rendererToken(token),
                sample: sample
            )
        case let .applyEstimatedUpdate(token, sample):
            try renderer.applyEstimatedStrokeUpdate(
                token: rendererToken(token),
                sample: sample
            )
        case let .commitFinishedStroke(token):
            try renderer.commitFinishedStroke(token: rendererToken(token))
        case let .cancelStroke(token):
            try requestStrokeCancellation(rendererToken(token))
            ignorePendingEstimatedUpdates()
            activeStrokeLayerID = nil
        case let .updateTool(tool):
            model.confirmTool(tool)
        case let .updateColor(color):
            model.confirmInkColor(color)
        case let .updateBrushDiameter(diameter):
            model.confirmBrushDiameter(diameter)
        case let .updateRecipe(recipeID):
            try model.confirmRecipe(recipeID)
        case let .updateGridVisibility(visible):
            model.confirmGridVisibility(visible)
            renderer.setInteractiveGridVisibility(visible)
        case let .applyTiling(token, tiling):
            guard renderer.isIdle else {
                precondition(pendingRendererIdleMetadataEffect == nil)
                pendingRendererIdleMetadataEffect = effect
                return
            }
            let before = model.periodicConfiguration
            if before.presetID == tiling {
                apply(.operationCompleted(token, succeeded: true))
                return
            }
            try history.validateNewCommand(retainedBytes: 0)
            Task { @MainActor [weak self] in
                await self?.completeTilingEffect(
                    effect,
                    token: token,
                    before: before,
                    tiling: tiling
                )
            }
        case let .applyPeriodicConfiguration(token, configuration):
            guard renderer.isIdle else {
                precondition(pendingRendererIdleMetadataEffect == nil)
                pendingRendererIdleMetadataEffect = effect
                return
            }
            let before = model.periodicConfiguration
            if before == configuration {
                apply(.operationCompleted(token, succeeded: true))
                return
            }
            try history.validateNewCommand(retainedBytes: 0)
            Task { @MainActor [weak self] in
                await self?.completePeriodicConfigurationEffect(
                    effect,
                    token: token,
                    before: before,
                    configuration: configuration
                )
            }
        case let .performCommand(token, command):
            try perform(command, token: token)
        case let .applyTileSize(token, pixelSize):
            if pixelSize == model.pixelSize {
                apply(.operationCompleted(token, succeeded: true))
                return
            }
            precondition(pendingTileResize == nil)
            pendingTileResize = PendingTileResize(
                token: token,
                before: model.pixelSize,
                after: pixelSize
            )
            let rendererToken = rendererToken(token)
            Task { @MainActor [renderer] in
                // The renderer stages the sole terminal completion event,
                // including failures. The controller must not synthesize a
                // second reducer completion from this task.
                try? await renderer.resizeDocument(
                    token: rendererToken,
                    to: pixelSize
                )
            }
        case .clearSelectionOverlay, .beginTransform, .cancelTransform,
             .busy, .reportOperationFailure:
            break
        }
    }

    private func completeTilingEffect(
        _ effect: EditorTransactionEffect,
        token: EditorTransactionToken,
        before: PeriodicSymmetryConfiguration,
        tiling: TilingKind
    ) async {
        do {
            try await renderer.applyTiling(tiling)
            completePeriodicConfigurationChange(
                token: token,
                before: before
            )
        } catch {
            handleAsynchronousFailure(of: effect, error: error)
        }
    }

    private func completePeriodicConfigurationEffect(
        _ effect: EditorTransactionEffect,
        token: EditorTransactionToken,
        before: PeriodicSymmetryConfiguration,
        configuration: PeriodicSymmetryConfiguration
    ) async {
        do {
            try await renderer.applyPeriodicConfiguration(configuration)
            completePeriodicConfigurationChange(
                token: token,
                before: before
            )
        } catch {
            handleAsynchronousFailure(of: effect, error: error)
        }
    }

    private func completePeriodicConfigurationChange(
        token: EditorTransactionToken,
        before: PeriodicSymmetryConfiguration
    ) {
        let after = renderer.periodicConfiguration
        model.confirmPeriodicConfiguration(after)
        if after != before {
            let released = history.appendSuccessful(
                .periodicConfiguration(
                    MetadataChange(before: before, after: after)
                )
            )
            if !released.isEmpty {
                releaseHistoryRevisions(released)
            }
        }
        apply(.operationCompleted(token, succeeded: true))
    }

    private func handleAsynchronousFailure(
        of effect: EditorTransactionEffect,
        error: Error
    ) {
        let rendererError = (error as? MetalRendererError)
            ?? .commandFailed(error.localizedDescription)
        handleSynchronousFailure(of: effect, error: rendererError)
    }

    private func perform(
        _ command: EditorCommand,
        token: EditorTransactionToken
    ) throws {
        switch command {
        case .clear:
            let layerID = try activeRasterLayerID()
            precondition(pendingRasterMutation == nil)
            pendingRasterMutation = PendingRasterMutation(
                token: token,
                kind: .clear,
                layerID: layerID
            )
            let rendererToken = rendererToken(token)
            Task { @MainActor [renderer] in
                // `clearDocument` publishes success or failure before it
                // returns, so history remains event-driven.
                try? await renderer.clearDocument(token: rendererToken)
            }
        case .undo:
            try beginHistoryNavigation(
                history.beginUndo(),
                operationToken: token
            )
        case .redo:
            try beginHistoryNavigation(
                history.beginRedo(),
                operationToken: token
            )
        }
    }

    private func beginHistoryNavigation(
        _ navigation: HistoryNavigation?,
        operationToken: EditorTransactionToken
    ) throws {
        guard let navigation else {
            apply(.operationCompleted(operationToken, succeeded: true))
            return
        }
        precondition(pendingHistoryNavigation == nil)
        pendingHistoryNavigation = PendingHistoryNavigation(
            operationToken: operationToken,
            historyToken: navigation.token,
            targetPixelSize: {
                guard case let .tileResize(command) = navigation.command else {
                    return nil
                }
                return navigation.direction == .undo
                    ? command.beforePixelSize
                    : command.afterPixelSize
            }()
        )

        do {
            switch navigation.command {
            case let .raster(command):
                guard layerStack.layer(id: command.layerID) != nil else {
                    throw LayerStackError.layerMissing(command.layerID)
                }
                let revision = navigation.direction == .undo
                    ? command.before
                    : command.after
                let rendererToken = rendererToken(operationToken)
                Task { @MainActor [renderer] in
                    try? await renderer.restoreDocumentRevision(
                        token: rendererToken,
                        revision: revision
                    )
                }
            case let .tiling(change):
                let target = navigation.direction == .undo
                    ? change.before
                    : change.after
                Task { @MainActor [weak self] in
                    await self?.completeTilingHistoryNavigation(
                        navigation,
                        operationToken: operationToken,
                        target: target
                    )
                }
            case let .periodicConfiguration(change):
                let target = navigation.direction == .undo
                    ? change.before
                    : change.after
                Task { @MainActor [weak self] in
                    await self?.completePeriodicHistoryNavigation(
                        navigation,
                        operationToken: operationToken,
                        target: target
                    )
                }
            case let .tileResize(command):
                let targetPixelSize = navigation.direction == .undo
                    ? command.beforePixelSize
                    : command.afterPixelSize
                let restored = try navigation.direction == .undo
                    ? renderer.restoreLayerGeometryBefore(
                        command.layerRevision
                    )
                    : renderer.restoreLayerGeometryAfter(
                        command.layerRevision
                    )
                guard restored == targetPixelSize else {
                    throw LayerStackError.invalidRestoration
                }
                confirmPixelSizeAndClampDiameter(restored)
                try history.finishNavigation(
                    token: navigation.token,
                    succeeded: true
                )
                pendingHistoryNavigation = nil
                apply(.operationCompleted(operationToken, succeeded: true))
            case let .layerMetadata(command):
                let target = navigation.direction == .undo
                    ? command.before
                    : command.after
                let restored = try navigation.direction == .undo
                    ? renderer.restoreLayerStackBefore(command.layerRevision)
                    : renderer.restoreLayerStackAfter(command.layerRevision)
                guard restored.snapshot == target else {
                    throw LayerStackError.invalidRestoration
                }
                layerStack = restored
                model.confirmLayerStack(restored)
                try history.finishNavigation(
                    token: navigation.token,
                    succeeded: true
                )
                pendingHistoryNavigation = nil
                apply(.operationCompleted(operationToken, succeeded: true))
            case let .layerDeletion(command):
                var candidate = layerStack
                switch navigation.direction {
                case .undo:
                    try command.restoreMetadata(
                        into: &candidate,
                        revisionIsAvailable: {
                            renderer.containsLayerRevision($0)
                        }
                    )
                    let restored = try renderer.restoreLayerStackBefore(
                        command.layerRevision
                    )
                    guard restored == candidate else {
                        throw LayerStackError.invalidRestoration
                    }
                    layerStack = restored
                    model.confirmLayerStack(restored)
                case .redo:
                    let removal = try candidate.delete(
                        command.removedLayer.id
                    )
                    guard removal.descriptor == command.removedLayer,
                          removal.order == command.removedOrder,
                          removal.activeLayerIDBefore
                              == command.activeLayerIDBefore,
                          removal.activeLayerIDAfter
                              == command.activeLayerIDAfter
                    else {
                        throw LayerStackError.invalidRestoration
                    }
                    let restored = try renderer.restoreLayerStackAfter(
                        command.layerRevision
                    )
                    guard restored == candidate else {
                        throw LayerStackError.invalidRestoration
                    }
                    layerStack = restored
                    model.confirmLayerStack(restored)
                }
                try history.finishNavigation(
                    token: navigation.token,
                    succeeded: true
                )
                pendingHistoryNavigation = nil
                apply(.operationCompleted(operationToken, succeeded: true))
            }
        } catch {
            try history.finishNavigation(
                token: navigation.token,
                succeeded: false
            )
            pendingHistoryNavigation = nil
            throw error
        }
    }

    private func completeTilingHistoryNavigation(
        _ navigation: HistoryNavigation,
        operationToken: EditorTransactionToken,
        target: TilingKind
    ) async {
        do {
            try await renderer.applyTiling(target)
            try completeConfigurationHistoryNavigation(
                navigation,
                operationToken: operationToken
            )
        } catch {
            failConfigurationHistoryNavigation(
                navigation,
                operationToken: operationToken,
                error: error
            )
        }
    }

    private func completePeriodicHistoryNavigation(
        _ navigation: HistoryNavigation,
        operationToken: EditorTransactionToken,
        target: PeriodicSymmetryConfiguration
    ) async {
        do {
            try await renderer.applyPeriodicConfiguration(target)
            try completeConfigurationHistoryNavigation(
                navigation,
                operationToken: operationToken
            )
        } catch {
            failConfigurationHistoryNavigation(
                navigation,
                operationToken: operationToken,
                error: error
            )
        }
    }

    private func completeConfigurationHistoryNavigation(
        _ navigation: HistoryNavigation,
        operationToken: EditorTransactionToken
    ) throws {
        model.confirmPeriodicConfiguration(renderer.periodicConfiguration)
        try history.finishNavigation(
            token: navigation.token,
            succeeded: true
        )
        pendingHistoryNavigation = nil
        apply(.operationCompleted(operationToken, succeeded: true))
    }

    private func failConfigurationHistoryNavigation(
        _ navigation: HistoryNavigation,
        operationToken: EditorTransactionToken,
        error: Error
    ) {
        let command: EditorCommand = navigation.direction == .undo
            ? .undo
            : .redo
        handleAsynchronousFailure(
            of: .performCommand(operationToken, command),
            error: error
        )
    }

    private func handleSynchronousFailure(
        of effect: EditorTransactionEffect,
        error: MetalRendererError,
        shouldReport: Bool = true
    ) {
        if shouldReport {
            report(error)
        }
        switch effect {
        case let .beginStroke(token, _, _, _),
             let .appendStroke(token, _),
             let .finishStrokeTransient(token, _),
             let .applyEstimatedUpdate(token, _):
            cancelCollectingStrokeAfterSynchronousFailure(token: token)
        case let .requestStrokeCommit(token, _),
             let .commitFinishedStroke(token),
             let .performCommand(token, _),
             let .applyTiling(token, _),
             let .applyPeriodicConfiguration(token, _),
             let .applyTileSize(token, _):
            ignorePendingEstimatedUpdates()
            finishHistoryNavigationIfNeeded(
                operationToken: token,
                succeeded: false
            )
            if pendingRasterMutation?.token == token {
                pendingRasterMutation = nil
            }
            if pendingTileResize?.token == token {
                pendingTileResize = nil
            }
            apply(.operationCompleted(token, succeeded: false))
        case .cancelStroke:
            ignorePendingEstimatedUpdates()
        case .updateTool, .updateColor,
             .updateBrushDiameter, .updateRecipe, .updateGridVisibility,
             .clearSelectionOverlay, .beginTransform, .cancelTransform,
             .busy, .reportOperationFailure:
            break
        }
        refreshDerivedModelState()
        resumeDeferredPointerIfIdle()
    }

    private func cancelCollectingStrokeAfterSynchronousFailure(
        token: EditorTransactionToken
    ) {
        ignorePendingEstimatedUpdates()
        activeStrokeLayerID = nil
        try? renderer.cancelStroke(token: rendererToken(token))
        _ = transaction.apply(.pointerCancelled)
    }

    private func failUnexecutedEffects(
        _ effects: ArraySlice<EditorTransactionEffect>,
        because error: MetalRendererError
    ) {
        for effect in effects {
            handleSynchronousFailure(
                of: effect,
                error: error,
                shouldReport: false
            )
        }
    }

    nonisolated static func makeStrokeSeedSessionEntropy() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        let entropy = generator.next()
        return entropy == 0 ? 0xD1B5_4A32_D192_ED03 : entropy
    }

    nonisolated static func derivedStrokeSeed(
        sequence: UInt64,
        sessionEntropy: UInt64
    ) -> UInt64 {
        precondition(sequence != 0, "Stroke seed sequence must be nonzero")
        let multiplierA = (
            (sessionEntropy ^ 0x9E37_79B9_7F4A_7C15)
                &* 0xD6E8_FEB8_6659_FD93
        ) | 1
        let multiplierB = (
            (sessionEntropy &+ 0xA076_1D64_78BD_642F)
                ^ (sessionEntropy >> 29)
        ) | 1
        var seed = sequence &* multiplierA
        let rotation = Int(sessionEntropy & 63)
        if rotation > 0 {
            seed = (seed << rotation) | (seed >> (64 - rotation))
        }
        seed ^= seed >> 30
        seed &*= 0xBF58_476D_1CE4_E5B9
        seed ^= seed >> 27
        seed &*= multiplierB
        seed ^= seed >> 31
        precondition(seed != 0, "Seed mixing must preserve nonzero sequences")
        return seed
    }

    private func takeStrokeSeed() -> UInt64 {
        if let diagnosticFixedStrokeSeed {
            return diagnosticFixedStrokeSeed
        }
        let sequence = nextStrokeSequence
        let (nextSequence, overflow) = sequence.addingReportingOverflow(1)
        precondition(!overflow, "Stroke seed sequence exhausted")
        nextStrokeSequence = nextSequence
        return Self.derivedStrokeSeed(
            sequence: sequence,
            sessionEntropy: strokeSeedSessionEntropy
        )
    }

    private func handleRendererCompletion(
        _ completion: RendererOperationCompletion
    ) {
        switch completion {
        case let .rasterSuccess(receipt):
            let completedToken = editorToken(receipt.token)
            let kind: RasterEditKind
            let layerID: UUID
            if case let .drawing(drawing) = transaction.state,
               drawing.phase == .commitPending,
               drawing.token == completedToken
            {
                ignorePendingEstimatedUpdates()
                kind = drawing.tool == .draw ? .draw : .erase
                guard let capturedLayerID = activeStrokeLayerID else {
                    preconditionFailure(
                        "A completed stroke must retain its pointer-down layer."
                    )
                }
                layerID = capturedLayerID
            } else if let pendingRasterMutation,
                      pendingRasterMutation.token == completedToken
            {
                kind = pendingRasterMutation.kind
                layerID = pendingRasterMutation.layerID
                self.pendingRasterMutation = nil
            } else {
                preconditionFailure(
                    "Renderer completed a raster mutation the controller did not accept."
                )
            }
            let command = RasterHistoryCommand(
                layerID: layerID,
                kind: kind,
                before: receipt.before,
                after: receipt.after
            )
            let released = history.appendSuccessful(.raster(command))
            lastRecordedRasterCommandForTesting = command
            releaseHistoryRevisions(released)
            activeStrokeLayerID = nil
            apply(
                .operationCompleted(
                    completedToken,
                    succeeded: true
                )
            )
            finishAwaitedClear(
                token: completedToken,
                result: .success(())
            )
        case let .layerGeometrySuccess(receipt):
            let completedToken = editorToken(receipt.token)
            guard let pendingTileResize,
                  pendingTileResize.token == completedToken
            else {
                preconditionFailure(
                    "Renderer completed a layer geometry mutation the controller did not accept."
                )
            }
            precondition(
                receipt.beforePixelSize == pendingTileResize.before
                    && receipt.afterPixelSize == pendingTileResize.after,
                "Renderer resize receipt must match the pending resize."
            )
            self.pendingTileResize = nil
            let command = TileResizeHistoryCommand(
                beforePixelSize: receipt.beforePixelSize,
                afterPixelSize: receipt.afterPixelSize,
                layerRevision: receipt.revision
            )
            let released = history.appendSuccessful(.tileResize(command))
            lastRecordedResizeCommandForTesting = command
            releaseHistoryRevisions(released)
            confirmPixelSizeAndClampDiameter(receipt.afterPixelSize)
            apply(.operationCompleted(completedToken, succeeded: true))
            refreshDerivedModelState()
        case let .operationSuccess(token):
            let completedToken = editorToken(token)
            if pendingRasterMutation?.token == completedToken {
                pendingRasterMutation = nil
                apply(
                    .operationCompleted(
                        completedToken,
                        succeeded: true
                    )
                )
                finishAwaitedClear(
                    token: completedToken,
                    result: .success(())
                )
                break
            }
            if pendingHistoryNavigation?.operationToken == completedToken,
               let targetPixelSize = pendingHistoryNavigation?.targetPixelSize
            {
                confirmPixelSizeAndClampDiameter(targetPixelSize)
            }
            finishHistoryNavigationIfNeeded(
                operationToken: completedToken,
                succeeded: true
            )
            apply(
                .operationCompleted(
                    completedToken,
                    succeeded: true
                )
            )
        case let .failure(token, error):
            report(error)
            let completedToken = editorToken(token)
            if case let .drawing(drawing) = transaction.state,
               drawing.token == completedToken
            {
                ignorePendingEstimatedUpdates()
                activeStrokeLayerID = nil
            }
            finishHistoryNavigationIfNeeded(
                operationToken: completedToken,
                succeeded: false
            )
            if pendingRasterMutation?.token == completedToken {
                pendingRasterMutation = nil
            }
            if pendingTileResize?.token == completedToken {
                pendingTileResize = nil
            }
            apply(
                .operationCompleted(
                    completedToken,
                    succeeded: false
                )
            )
            finishAwaitedClear(
                token: completedToken,
                result: .failure(error)
            )
        }
        refreshDerivedModelState()
        resumeDeferredPointerIfIdle()
    }

    private func finishAwaitedClear(
        token: EditorTransactionToken,
        result: Result<Void, MetalRendererError>
    ) {
        guard let awaitedClear, awaitedClear.token == token else {
            return
        }
        self.awaitedClear = nil
        switch result {
        case .success:
            awaitedClear.continuation.resume()
        case let .failure(error):
            awaitedClear.continuation.resume(throwing: error)
        }
    }

    private func resumeDeferredPointerIfIdle() {
        guard transaction.state == .idle,
              renderer.isIdle,
              hasDeferredPointerStream
        else { return }
        deferredPointerResumeCountForTesting &+= 1
        let overflowed = deferredPointerOverflowed
        swap(
            &deferredPointerSamples,
            &deferredPointerDrainScratch
        )
        deferredPointerOverflowed = false
        deferredEstimationIndices.removeAll(keepingCapacity: true)
        defer {
            deferredPointerDrainScratch.removeAll(keepingCapacity: true)
        }
        guard let began = deferredPointerDrainScratch.first(where: {
            $0.sample.phase == .began
        }) else {
            return
        }
        if overflowed {
            handleStrokeSample(
                began.sample,
                inputGeneration: began.inputGeneration
            )
            handleStrokeSample(
                .mouse(
                    position: began.sample.position,
                    timestamp: began.sample.timestamp,
                    phase: .cancelled
                ),
                inputGeneration: began.inputGeneration
            )
            return
        }
        var index = deferredPointerDrainScratch.startIndex
        while index < deferredPointerDrainScratch.endIndex {
            let routedSample = deferredPointerDrainScratch[index]
            guard let batchID = routedSample.batchID else {
                handleStrokeSample(
                    routedSample.sample,
                    inputGeneration: routedSample.inputGeneration
                )
                index += 1
                continue
            }
            deferredPointerBatchScratch.removeAll(keepingCapacity: true)
            let inputGeneration = routedSample.inputGeneration
            let submittedPredictionSampleCount =
                routedSample.submittedPredictionSampleCount
            while index < deferredPointerDrainScratch.endIndex,
                  deferredPointerDrainScratch[index].batchID == batchID
            {
                deferredPointerBatchScratch.append(
                    deferredPointerDrainScratch[index].sample
                )
                index += 1
            }
            handleStrokeSamples(
                deferredPointerBatchScratch,
                inputGeneration: inputGeneration,
                submittedPredictionSampleCount:
                    submittedPredictionSampleCount
            )
        }
    }

    private func handleRendererIdleStateChange(_ isIdle: Bool) {
        guard isIdle, renderer.isIdle else { return }
        if let effect = pendingRendererIdleMetadataEffect {
            pendingRendererIdleMetadataEffect = nil
            execute([effect])
            refreshDerivedModelState()
        }
        resumeDeferredPointerIfIdle()
    }

    private var hasDeferredPointerStream: Bool {
        !deferredPointerSamples.isEmpty || deferredPointerOverflowed
    }

    private func discardDeferredPointerStream() {
        deferredPointerSamples.removeAll(keepingCapacity: true)
        deferredPointerOverflowed = false
        deferredEstimationIndices.removeAll(keepingCapacity: true)
    }

    private func enqueueDeferredPointerSample(
        _ sample: StrokeSample,
        inputGeneration: UInt64?
    ) {
        guard !deferredPointerOverflowed else { return }
        guard shouldEnqueueDeferredPointerSample(
            sample,
            inputGeneration: inputGeneration
        ) else {
            return
        }
        guard deferredPointerSamples.count
                < Self.deferredPointerSampleCapacity
        else {
            deferredPointerOverflowed = true
            deferredEstimationIndices.removeAll(keepingCapacity: true)
            return
        }
        deferredPointerSamples.append(
            RoutedStrokeSample(
                sample: sample,
                inputGeneration: inputGeneration,
                batchID: nil,
                submittedPredictionSampleCount: nil
            )
        )
        recordDeferredEstimationState(for: sample)
    }

    private func enqueueDeferredPointerBatch<Samples>(
        _ samples: Samples,
        inputGeneration: UInt64?,
        submittedPredictionSampleCount: Int?
    ) where
        Samples: RandomAccessCollection,
        Samples.Element == StrokeSample
    {
        guard !samples.isEmpty, !deferredPointerOverflowed else { return }
        guard shouldEnqueueDeferredPointerBatch(
            samples,
            inputGeneration: inputGeneration
        ) else {
            return
        }
        guard samples.count
                <= Self.deferredPointerSampleCapacity
                    - deferredPointerSamples.count
        else {
            deferredPointerOverflowed = true
            deferredEstimationIndices.removeAll(keepingCapacity: true)
            return
        }
        let batchID = nextDeferredPointerBatchID
        nextDeferredPointerBatchID &+= 1
        if nextDeferredPointerBatchID == 0 {
            nextDeferredPointerBatchID = 1
        }
        for (offset, sample) in samples.enumerated() {
            deferredPointerSamples.append(
                RoutedStrokeSample(
                    sample: sample,
                    inputGeneration: inputGeneration,
                    batchID: batchID,
                    submittedPredictionSampleCount: offset == 0
                        ? submittedPredictionSampleCount : nil
                )
            )
            recordDeferredEstimationState(for: sample)
        }
    }

    private func shouldEnqueueDeferredPointerBatch<Samples>(
        _ samples: Samples,
        inputGeneration: UInt64?
    ) -> Bool where
        Samples: RandomAccessCollection,
        Samples.Element == StrokeSample
    {
        guard let firstSample = samples.first else { return false }
        if let firstDeferred = deferredPointerSamples.first {
            guard inputGeneration == firstDeferred.inputGeneration else {
                return false
            }
        } else {
            guard firstSample.phase == .began,
                  firstSample.kind != .estimatedUpdate
            else {
                return false
            }
        }
        for sample in samples where sample.kind == .estimatedUpdate {
            guard inputGeneration != nil,
                  let index = sample.estimationUpdateIndex,
                  deferredEstimationIndices.contains(index)
            else {
                return false
            }
        }
        return true
    }

    private func recordDeferredEstimationState(for sample: StrokeSample) {
        if let index = sample.estimationUpdateIndex {
            if sample.estimatedPropertiesExpectingUpdates.isEmpty {
                deferredEstimationIndices.remove(index)
            } else {
                deferredEstimationIndices.insert(index)
            }
        }
    }

    private func shouldEnqueueDeferredPointerSample(
        _ sample: StrokeSample,
        inputGeneration: UInt64?
    ) -> Bool {
        guard let first = deferredPointerSamples.first else {
            return sample.phase == .began
                && sample.kind != .estimatedUpdate
        }
        guard inputGeneration == first.inputGeneration else { return false }
        guard sample.kind == .estimatedUpdate else { return true }
        guard inputGeneration != nil,
              let index = sample.estimationUpdateIndex
        else { return false }
        return deferredEstimationIndices.contains(index)
    }

    private func finishHistoryNavigationIfNeeded(
        operationToken: EditorTransactionToken,
        succeeded: Bool
    ) {
        guard let pendingHistoryNavigation,
              pendingHistoryNavigation.operationToken == operationToken
        else { return }
        do {
            try history.finishNavigation(
                token: pendingHistoryNavigation.historyToken,
                succeeded: succeeded
            )
            if succeeded {
                try renderer.reconcileGeometryLock(
                    documentIsEmpty: history.currentDocumentIsEmpty
                )
            }
            self.pendingHistoryNavigation = nil
        } catch {
            preconditionFailure(
                "Controller history navigation token became stale: \(error)"
            )
        }
    }

    private func releaseHistoryRevisions(
        _ ids: Set<StoredRasterRevisionID>
    ) {
        guard !ids.isEmpty else { return }
        pendingPaintRevisionReleaseIDs.formUnion(ids)
        startPaintRevisionReleaseIfNeeded()
    }

    private func startPaintRevisionReleaseIfNeeded() {
        guard paintRevisionReleaseTask == nil,
              !pendingPaintRevisionReleaseIDs.isEmpty
        else { return }
        paintRevisionReleaseTask = Task { @MainActor [weak self] in
            await self?.drainPendingPaintRevisionReleases()
        }
    }

    private func drainPendingPaintRevisionReleases() async {
        defer { paintRevisionReleaseTask = nil }
        while !pendingPaintRevisionReleaseIDs.isEmpty {
            let ids = pendingPaintRevisionReleaseIDs
            pendingPaintRevisionReleaseIDs.removeAll(keepingCapacity: true)
            do {
                try await renderer.releasePaintRevisions(ids)
            } catch let error as MetalRendererError {
                pendingPaintRevisionReleaseIDs.formUnion(ids)
                report(error)
                return
            } catch {
                pendingPaintRevisionReleaseIDs.formUnion(ids)
                report(.commandFailed(error.localizedDescription))
                return
            }
        }
    }

    private func refreshDerivedModelState() {
        model.confirmDocumentConfiguration(renderer.documentConfiguration)
        model.confirmPixelSize(renderer.pixelSize)
        model.confirmGeometryLocks(
            documentDomainLocked: renderer.documentDomainLocked,
            radialGeometryLocked: renderer.radialGeometryLocked
        )
        let isBusy = transaction.isBusy
            || emptyConfigurationReplacementInFlight
        model.confirmBusy(isBusy)
        model.confirmHistoryAvailability(
            canUndo: history.canUndo && !isBusy,
            canRedo: history.canRedo && !isBusy
        )
    }

    private func replaceEmptyDocumentConfiguration(
        _ configuration: SymmetryDocumentConfiguration
    ) {
        guard transaction.state == .idle,
              transaction.pendingOperation == nil,
              !emptyConfigurationReplacementInFlight,
              renderer.isIdle
        else {
            report(.tilingChangeRequiresIdle)
            return
        }
        guard history.currentDocumentIsEmpty else {
            if case .finite(.radial) = renderer.documentConfiguration {
                report(.radialGeometryLocked)
            } else {
                report(.documentDomainLocked)
            }
            return
        }
        let pixelSize = targetPixelSize(for: configuration)
        emptyConfigurationReplacementInFlight = true
        refreshDerivedModelState()
        Task { @MainActor [weak self] in
            await self?.completeEmptyDocumentConfigurationReplacement(
                configuration,
                pixelSize: pixelSize
            )
        }
    }

    private func completeEmptyDocumentConfigurationReplacement(
        _ configuration: SymmetryDocumentConfiguration,
        pixelSize: PixelSize
    ) async {
        defer {
            emptyConfigurationReplacementInFlight = false
            refreshDerivedModelState()
        }
        do {
            try await renderer.replaceEmptyDocumentConfiguration(
                configuration,
                pixelSize: pixelSize
            )
            releaseHistoryRevisions(history.removeAll())
            refreshDerivedModelState()
        } catch let error as MetalRendererError {
            report(error)
        } catch {
            report(.commandFailed(error.localizedDescription))
        }
    }

    private func confirmPixelSizeAndClampDiameter(_ pixelSize: PixelSize) {
        model.confirmPixelSize(pixelSize)
    }

    private func activeRasterLayerID() throws -> UUID {
        try layerStack.activeLayerForRasterMutation().id
    }

    private func targetPixelSize(
        for configuration: SymmetryDocumentConfiguration
    ) -> PixelSize {
        guard configuration.domainID != model.documentConfiguration.domainID
        else {
            return model.pixelSize
        }
        switch configuration {
        case .periodic:
            return EditorConfiguration.defaultPeriodicPixelSize
        case .finite:
            return EditorConfiguration.defaultFinitePixelSize
        }
    }

    private func report(_ error: MetalRendererError) {
        onError?(error)
    }

    private func rendererToken(
        _ token: EditorTransactionToken
    ) -> RendererOperationToken {
        RendererOperationToken(rawValue: token.rawValue)
    }

    private func editorToken(
        _ token: RendererOperationToken
    ) -> EditorTransactionToken {
        EditorTransactionToken(rawValue: token.rawValue)
    }
}
