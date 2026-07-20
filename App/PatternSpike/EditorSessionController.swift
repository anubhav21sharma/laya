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
        case let .performCommand(token, _),
             let .applyTileSize(token, _):
            apply(.operationCompleted(token, succeeded: false))
        case .clearSelectionOverlay, .beginTransform, .cancelTransform,
             .busy, .reportOperationFailure:
            break
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
            guard
                case let .drawing(drawing) = transaction.state,
                drawing.phase == .commitPending,
                drawing.token.rawValue == receipt.token.rawValue
            else {
                preconditionFailure(
                    "Renderer completed a raster operation the controller did not accept."
                )
            }
            let kind: RasterEditKind = drawing.tool == .draw ? .draw : .erase
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
                    editorToken(receipt.token),
                    succeeded: true
                )
            )
        case let .operationSuccess(token):
            apply(
                .operationCompleted(
                    editorToken(token),
                    succeeded: true
                )
            )
        case let .failure(token, error):
            report(error)
            apply(
                .operationCompleted(
                    editorToken(token),
                    succeeded: false
                )
            )
        }
        refreshDerivedModelState()
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
