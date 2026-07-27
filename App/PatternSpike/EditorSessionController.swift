import EditorCore
import MetalRenderer
import PatternEngine

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
    private(set) var isSpaceDown = false
    private let strokeSeedSessionEntropy: UInt64
    private var nextStrokeSequence: UInt64 = 1
    private var pendingEstimatedProperties:
        [Int: StrokeEstimatedProperties] = [:]
    private var predictedEstimationIndices: Set<Int> = []
    private var ignoredLateEstimationIndices: Set<Int> = []
    private struct RoutedStrokeSample {
        let sample: StrokeSample
        let inputGeneration: UInt64?
    }

    private var deferredPointerSamples: [RoutedStrokeSample] = []
    private var deferredPointerOverflowed = false
    private var deferredEstimationIndices: Set<Int> = []
    private static let deferredPointerSampleCapacity =
        TransientStrokeBufferContract.wholeStrokeSampleCapacity

    private var transaction = EditorTransaction()
    private var history: DocumentHistory
    private var pendingRasterMutation: PendingRasterMutation?
    private var pendingTileResize: PendingTileResize?
    private var pendingHistoryNavigation: PendingHistoryNavigation?
    private let releaseRasterRevisions: (Set<StoredRasterRevisionID>) -> Void
    private let requestRasterRestore: (
        RendererOperationToken,
        RasterRevisionReference
    ) throws -> Void
    private let requestResize: (
        RendererOperationToken,
        PixelSize,
        Int
    ) throws -> Void
    private let requestResizeRestore: (
        RendererOperationToken,
        RasterRevisionReference
    ) throws -> Void
    private let requestStrokeCancellation: (
        RendererOperationToken
    ) throws -> Void
    private(set) var lastRecordedRasterCommandForTesting: RasterHistoryCommand?
    private(set) var lastRecordedResizeCommandForTesting: TileResizeHistoryCommand?

    private struct PendingRasterMutation {
        let token: EditorTransactionToken
        let kind: RasterEditKind
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

    init(
        model: EditorModel = EditorModel(),
        renderer: GridRenderer,
        releaseRasterRevisions: ((Set<StoredRasterRevisionID>) -> Void)? = nil,
        requestRasterRestore: ((
            RendererOperationToken,
            RasterRevisionReference
        ) throws -> Void)? = nil,
        requestResize: ((
            RendererOperationToken,
            PixelSize,
            Int
        ) throws -> Void)? = nil,
        requestResizeRestore: ((
            RendererOperationToken,
            RasterRevisionReference
        ) throws -> Void)? = nil,
        requestStrokeCancellation: ((
            RendererOperationToken
        ) throws -> Void)? = nil,
        historyMaximumBytes: Int = 200 * 1_024 * 1_024,
        strokeSeedSessionEntropy: UInt64 = EditorSessionController
            .makeStrokeSeedSessionEntropy()
    ) {
        self.model = model
        self.renderer = renderer
        history = DocumentHistory(
            maximumBytes: historyMaximumBytes,
            initialDocumentIsEmpty: !renderer.documentDomainLocked
        )
        self.strokeSeedSessionEntropy = strokeSeedSessionEntropy
        self.releaseRasterRevisions = releaseRasterRevisions ?? {
            renderer.releaseRasterRevisions($0)
        }
        self.requestRasterRestore = requestRasterRestore ?? {
            try renderer.requestRasterRestore(token: $0, revision: $1)
        }
        self.requestResize = requestResize ?? {
            try renderer.requestResize(
                token: $0,
                to: $1,
                maximumRetainedBytes: $2
            )
        }
        self.requestResizeRestore = requestResizeRestore ?? {
            try renderer.requestResizeRestore(token: $0, revision: $1)
        }
        self.requestStrokeCancellation = requestStrokeCancellation ?? {
            try renderer.cancelStroke(token: $0)
        }
        model.confirmDocumentConfiguration(renderer.documentConfiguration)
        model.confirmPixelSize(renderer.pixelSize)
        model.confirmGeometryLocks(
            documentDomainLocked: renderer.documentDomainLocked,
            radialGeometryLocked: renderer.radialGeometryLocked
        )
        renderer.setInteractiveGridVisibility(model.showGrid)
        renderer.onOperationCompleted = { [weak self] completion in
            self?.handleRendererCompletion(completion)
        }
        refreshDerivedModelState()
    }

    var historyAvailabilityForTesting: (canUndo: Bool, canRedo: Bool) {
        (history.canUndo, history.canRedo)
    }

    var transactionStateForTesting: EditorTransactionState {
        transaction.state
    }

    func handleStrokeSample(
        _ sample: StrokeSample,
        inputGeneration: UInt64? = nil
    ) {
        if hasDeferredPointerStream {
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
            handleEstimatedPropertiesUpdate(sample)
            return
        }
        if sample.phase == .began, isAwaitingEstimatedUpdates {
            enqueueDeferredPointerSample(
                sample,
                inputGeneration: inputGeneration
            )
            ignorePendingEstimatedUpdates()
            emitEstimatedUpdateFallbackDiagnostic()
            apply(.finalizeAwaitingEstimates)
            return
        }
        let event: EditorTransactionEvent
        switch sample.phase {
        case .began:
            guard let tool = strokeTool,
                  transaction.state == .idle,
                  transaction.pendingOperation == nil
            else { return }
            resetEstimatedUpdatesForNewStroke()
            trackPendingEstimatedProperties(in: sample)
            let recipe = tool == .draw
                ? model.selectedRecipe
                : AnchorBrushCatalog.hardRoundEraser.recipe
            let seed = takeStrokeSeed()
            event = .pointerBegan(
                sample,
                tool: tool,
                style: StrokeRenderStyle(
                    color: model.inkColor,
                    diameter: model.brushDiameter,
                    compositeMode: tool == .draw ? .draw : .erase,
                    eraserStrength: model.eraserStrength,
                    recipe: recipe,
                    seed: seed
                ),
                recipe: recipe
            )
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
        inputGeneration: UInt64? = nil
    ) {
        if hasDeferredPointerStream {
            for sample in samples {
                handleStrokeSample(
                    sample,
                    inputGeneration: inputGeneration
                )
            }
            return
        }
        guard samples.count > 1,
              samples.allSatisfy({ $0.phase == .moved }),
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

        for sample in samples {
            trackPendingEstimatedProperties(in: sample)
        }
        let effects = samples.flatMap {
            transaction.apply(.pointerMoved($0))
        }
        guard effects.count == samples.count,
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
                samples: samples
            )
        } catch let error as MetalRendererError {
            handleSynchronousFailure(
                of: effects[0],
                error: error
            )
        } catch {
            handleSynchronousFailure(
                of: effects[0],
                error: .commandFailed(error.localizedDescription)
            )
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

    func handleRecipe(_ recipeID: BrushRecipeID) {
        apply(.recipeIntent(recipeID))
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

    func undo() {
        apply(.command(.undo))
    }

    func redo() {
        apply(.command(.redo))
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
        case let .beginStroke(token, sample, _, style, recipe):
            precondition(style.recipe == recipe)
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
                sample: sample,
                maximumRetainedBytes: history.maximumBytes
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
            try renderer.commitFinishedStroke(
                token: rendererToken(token),
                maximumRetainedBytes: history.maximumBytes
            )
        case let .cancelStroke(token):
            try requestStrokeCancellation(rendererToken(token))
            ignorePendingEstimatedUpdates()
        case let .updateTool(tool):
            model.confirmTool(tool)
        case let .updateColor(color):
            model.confirmInkColor(color)
        case let .updateBrushDiameter(diameter):
            model.confirmBrushDiameter(diameter)
        case let .updateRecipe(recipeID):
            model.confirmRecipe(recipeID)
        case let .updateGridVisibility(visible):
            model.confirmGridVisibility(visible)
            renderer.setInteractiveGridVisibility(visible)
        case let .applyTiling(token, tiling):
            let before = model.periodicConfiguration
            if before.presetID == tiling {
                apply(.operationCompleted(token, succeeded: true))
                return
            }
            try history.validateNewCommand(retainedBytes: 0)
            try renderer.applyTiling(tiling)
            let after = renderer.periodicConfiguration
            model.confirmPeriodicConfiguration(after)
            let released = history.appendSuccessful(
                .periodicConfiguration(
                    MetadataChange(before: before, after: after)
                )
            )
            if !released.isEmpty {
                releaseRasterRevisions(released)
            }
            apply(.operationCompleted(token, succeeded: true))
        case let .applyPeriodicConfiguration(token, configuration):
            let before = model.periodicConfiguration
            if before == configuration {
                apply(.operationCompleted(token, succeeded: true))
                return
            }
            try history.validateNewCommand(retainedBytes: 0)
            try renderer.applyPeriodicConfiguration(configuration)
            let after = renderer.periodicConfiguration
            model.confirmPeriodicConfiguration(after)
            if after == before {
                apply(.operationCompleted(token, succeeded: true))
                return
            }
            let released = history.appendSuccessful(
                .periodicConfiguration(
                    MetadataChange(before: before, after: after)
                )
            )
            if !released.isEmpty {
                releaseRasterRevisions(released)
            }
            apply(.operationCompleted(token, succeeded: true))
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
            do {
                try requestResize(
                    rendererToken(token),
                    pixelSize,
                    history.maximumBytes
                )
            } catch {
                pendingTileResize = nil
                throw error
            }
        case .clearSelectionOverlay, .beginTransform, .cancelTransform,
             .busy, .reportOperationFailure:
            break
        }
    }

    private func perform(
        _ command: EditorCommand,
        token: EditorTransactionToken
    ) throws {
        switch command {
        case .clear:
            precondition(pendingRasterMutation == nil)
            pendingRasterMutation = PendingRasterMutation(
                token: token,
                kind: .clear
            )
            do {
                try renderer.requestClear(
                    token: rendererToken(token),
                    maximumRetainedBytes: history.maximumBytes
                )
            } catch {
                pendingRasterMutation = nil
                throw error
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
                    ? command.before.documentPixelSize
                    : command.after.documentPixelSize
            }()
        )

        do {
            switch navigation.command {
            case let .raster(command):
                let revision = navigation.direction == .undo
                    ? command.before
                    : command.after
                try requestRasterRestore(
                    rendererToken(operationToken),
                    revision
                )
            case let .tiling(change):
                let target = navigation.direction == .undo
                    ? change.before
                    : change.after
                try renderer.applyTiling(target)
                model.confirmPeriodicConfiguration(
                    renderer.periodicConfiguration
                )
                try history.finishNavigation(
                    token: navigation.token,
                    succeeded: true
                )
                pendingHistoryNavigation = nil
                apply(.operationCompleted(operationToken, succeeded: true))
            case let .periodicConfiguration(change):
                let target = navigation.direction == .undo
                    ? change.before
                    : change.after
                try renderer.applyPeriodicConfiguration(target)
                model.confirmPeriodicConfiguration(
                    renderer.periodicConfiguration
                )
                try history.finishNavigation(
                    token: navigation.token,
                    succeeded: true
                )
                pendingHistoryNavigation = nil
                apply(.operationCompleted(operationToken, succeeded: true))
            case let .tileResize(command):
                let revision = navigation.direction == .undo
                    ? command.before
                    : command.after
                try requestResizeRestore(
                    rendererToken(operationToken),
                    revision
                )
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

    private func handleSynchronousFailure(
        of effect: EditorTransactionEffect,
        error: MetalRendererError,
        shouldReport: Bool = true
    ) {
        if shouldReport {
            report(error)
        }
        switch effect {
        case let .beginStroke(token, _, _, _, _),
             let .appendStroke(token, _),
             let .finishStrokeTransient(token, _),
             let .applyEstimatedUpdate(token, _):
            ignorePendingEstimatedUpdates()
            try? renderer.cancelStroke(token: rendererToken(token))
            _ = transaction.apply(.pointerCancelled)
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
            if case let .drawing(drawing) = transaction.state,
               drawing.phase == .commitPending,
               drawing.token == completedToken
            {
                ignorePendingEstimatedUpdates()
                kind = drawing.tool == .draw ? .draw : .erase
            } else if let pendingRasterMutation,
                      pendingRasterMutation.token == completedToken
            {
                kind = pendingRasterMutation.kind
                self.pendingRasterMutation = nil
            } else if let pendingTileResize,
                      pendingTileResize.token == completedToken
            {
                precondition(
                    receipt.before.documentPixelSize
                        == pendingTileResize.before
                        && receipt.after.documentPixelSize
                            == pendingTileResize.after,
                    "Renderer resize receipt must match the pending resize."
                )
                self.pendingTileResize = nil
                let command = TileResizeHistoryCommand(
                    before: receipt.before,
                    after: receipt.after
                )
                let released = history.appendSuccessful(.tileResize(command))
                lastRecordedResizeCommandForTesting = command
                releaseRasterRevisions(released)
                confirmPixelSizeAndClampDiameter(
                    receipt.after.documentPixelSize
                )
                apply(
                    .operationCompleted(
                        completedToken,
                        succeeded: true
                    )
                )
                refreshDerivedModelState()
                return
            } else {
                preconditionFailure(
                    "Renderer completed a raster mutation the controller did not accept."
                )
            }
            let command = RasterHistoryCommand(
                kind: kind,
                before: receipt.before,
                after: receipt.after
            )
            let released = history.appendSuccessful(.raster(command))
            lastRecordedRasterCommandForTesting = command
            releaseRasterRevisions(released)
            apply(
                .operationCompleted(
                    completedToken,
                    succeeded: true
                )
            )
        case let .operationSuccess(token):
            let completedToken = editorToken(token)
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
        }
        refreshDerivedModelState()
        resumeDeferredPointerIfIdle()
    }

    private func resumeDeferredPointerIfIdle() {
        guard transaction.state == .idle,
              hasDeferredPointerStream
        else { return }
        let samples = deferredPointerSamples
        let overflowed = deferredPointerOverflowed
        discardDeferredPointerStream()
        guard let began = samples.first(where: {
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
        for routedSample in samples {
            handleStrokeSample(
                routedSample.sample,
                inputGeneration: routedSample.inputGeneration
            )
        }
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
                inputGeneration: inputGeneration
            )
        )
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

    private func refreshDerivedModelState() {
        model.confirmDocumentConfiguration(renderer.documentConfiguration)
        model.confirmPixelSize(renderer.pixelSize)
        model.confirmGeometryLocks(
            documentDomainLocked: renderer.documentDomainLocked,
            radialGeometryLocked: renderer.radialGeometryLocked
        )
        model.confirmBusy(transaction.isBusy)
        model.confirmHistoryAvailability(
            canUndo: history.canUndo && !transaction.isBusy,
            canRedo: history.canRedo && !transaction.isBusy
        )
    }

    private func replaceEmptyDocumentConfiguration(
        _ configuration: SymmetryDocumentConfiguration
    ) {
        guard transaction.state == .idle,
              transaction.pendingOperation == nil,
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
        do {
            try renderer.replaceEmptyDocumentConfiguration(
                configuration,
                pixelSize: targetPixelSize(for: configuration)
            )
            releaseRasterRevisions(history.removeAll())
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
