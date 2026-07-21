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

    private var transaction = EditorTransaction()
    private var history = DocumentHistory()
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
        ) throws -> Void)? = nil
    ) {
        self.model = model
        self.renderer = renderer
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
        model.confirmPixelSize(renderer.pixelSize)
        model.confirmTiling(renderer.tiling)
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

    func handleStrokeSample(_ sample: StrokeSample) {
        let event: EditorTransactionEvent
        switch sample.phase {
        case .began:
            guard let tool = strokeTool else { return }
            event = .pointerBegan(
                sample,
                tool: tool,
                style: StrokeRenderStyle(
                    color: model.inkColor,
                    diameter: model.brushDiameter,
                    compositeMode: tool == .draw ? .draw : .erase,
                    eraserStrength: model.eraserStrength
                )
            )
        case .moved:
            event = .pointerMoved(sample)
        case .ended:
            event = .pointerEnded(sample)
        case .cancelled:
            event = .pointerCancelled
        }
        apply(event)
    }

    func handleTiling(_ tiling: TilingKind) {
        apply(.tilingIntent(tiling))
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
                  let tiling = TilingKind(rawValue: UInt32(index1 - 1))
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
        apply(.pointerCancelled)
    }

    func handleFocusLoss() {
        isSpaceDown = false
        cancelTransientEdit()
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

    private func apply(_ event: EditorTransactionEvent) {
        execute(transaction.apply(event))
        refreshDerivedModelState()
    }

    private func execute(_ effects: [EditorTransactionEffect]) {
        for effect in effects {
            do {
                try execute(effect)
            } catch let error as MetalRendererError {
                handleSynchronousFailure(of: effect, error: error)
                break
            } catch {
                handleSynchronousFailure(
                    of: effect,
                    error: .commandFailed(error.localizedDescription)
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
                sample: sample,
                maximumRetainedBytes: history.maximumBytes
            )
        case let .cancelStroke(token):
            try renderer.cancelStroke(token: rendererToken(token))
        case let .updateTool(tool):
            model.confirmTool(tool)
        case let .updateColor(color):
            model.confirmInkColor(color)
        case let .updateBrushDiameter(diameter):
            model.confirmBrushDiameter(diameter)
        case let .updateGridVisibility(visible):
            model.confirmGridVisibility(visible)
            renderer.setInteractiveGridVisibility(visible)
        case let .applyTiling(token, tiling):
            let before = model.tiling
            if before == tiling {
                apply(.operationCompleted(token, succeeded: true))
                return
            }
            try history.validateNewCommand(retainedBytes: 0)
            try renderer.applyTiling(tiling)
            model.confirmTiling(tiling)
            let released = history.appendSuccessful(
                .tiling(MetadataChange(before: before, after: tiling))
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
                    ? command.before.pixelSize
                    : command.after.pixelSize
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
                model.confirmTiling(target)
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
        error: MetalRendererError
    ) {
        report(error)
        switch effect {
        case let .beginStroke(token, _, _, _),
             let .appendStroke(token, _):
            try? renderer.cancelStroke(token: rendererToken(token))
            _ = transaction.apply(.pointerCancelled)
        case let .requestStrokeCommit(token, _),
             let .performCommand(token, _),
             let .applyTiling(token, _),
             let .applyTileSize(token, _):
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
        case .cancelStroke, .updateTool, .updateColor,
             .updateBrushDiameter, .updateGridVisibility,
             .clearSelectionOverlay, .beginTransform, .cancelTransform,
             .busy, .reportOperationFailure:
            break
        }
        refreshDerivedModelState()
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
                    receipt.before.pixelSize == pendingTileResize.before
                        && receipt.after.pixelSize == pendingTileResize.after,
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
                confirmPixelSizeAndClampDiameter(receipt.after.pixelSize)
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
            self.pendingHistoryNavigation = nil
        } catch {
            preconditionFailure(
                "Controller history navigation token became stale: \(error)"
            )
        }
    }

    private func refreshDerivedModelState() {
        model.confirmBusy(transaction.isBusy)
        model.confirmHistoryAvailability(
            canUndo: history.canUndo && !transaction.isBusy,
            canRedo: history.canRedo && !transaction.isBusy
        )
    }

    private func confirmPixelSizeAndClampDiameter(_ pixelSize: PixelSize) {
        model.confirmPixelSize(pixelSize)
        model.confirmBrushDiameter(
            min(
                model.brushDiameter,
                EditorConfiguration.brushMaximum(for: pixelSize)
            )
        )
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
