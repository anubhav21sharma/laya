import EditorCore
import MetalRenderer
import PatternEngine

@MainActor
final class EditorSessionController {
    let model: EditorModel
    let renderer: GridRenderer
    var onError: ((MetalRendererError) -> Void)?

    private var transaction = EditorTransaction()
    private var history = DocumentHistory()
    private var pendingRasterMutation: PendingRasterMutation?
    private var pendingHistoryNavigation: PendingHistoryNavigation?

    private struct PendingRasterMutation {
        let token: EditorTransactionToken
        let kind: RasterEditKind
    }

    private struct PendingHistoryNavigation {
        let operationToken: EditorTransactionToken
        let historyToken: UInt64
    }

    init(model: EditorModel = EditorModel(), renderer: GridRenderer) {
        self.model = model
        self.renderer = renderer
        renderer.onOperationCompleted = { [weak self] completion in
            self?.handleRendererCompletion(completion)
        }
        refreshDerivedModelState()
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
        case let .applyTiling(token, tiling):
            try renderer.setTiling(tiling)
            model.confirmTiling(tiling)
            apply(.operationCompleted(token, succeeded: true))
        case let .performCommand(token, command):
            try perform(command, token: token)
        case let .applyTileSize(token, _):
            apply(.operationCompleted(token, succeeded: false))
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
            historyToken: navigation.token
        )

        do {
            switch navigation.command {
            case let .raster(command):
                let revision = navigation.direction == .undo
                    ? command.before
                    : command.after
                try renderer.requestRasterRestore(
                    token: rendererToken(operationToken),
                    revision: revision
                )
            case .tiling, .tileResize:
                throw MetalRendererError.commandFailed(
                    "This history command is not available yet."
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
            } else {
                preconditionFailure(
                    "Renderer completed a raster mutation the controller did not accept."
                )
            }
            let released = history.appendSuccessful(
                .raster(
                    RasterHistoryCommand(
                        kind: kind,
                        before: receipt.before,
                        after: receipt.after
                    )
                )
            )
            renderer.releaseRasterRevisions(released)
            apply(
                .operationCompleted(
                    completedToken,
                    succeeded: true
                )
            )
        case let .operationSuccess(token):
            let completedToken = editorToken(token)
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
