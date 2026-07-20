import PatternEngine

public struct EditorTransactionToken:
    RawRepresentable, Hashable, Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct SelectionRegion: Equatable, Sendable {
    public let rawOrigin: CanonicalPoint
    public let folded: PixelRect

    public init(rawOrigin: CanonicalPoint, folded: PixelRect) {
        self.rawOrigin = rawOrigin
        self.folded = folded
    }
}

public enum DrawingPhase: UInt8, Equatable, Sendable {
    case collecting
    case commitPending
}

public struct DrawingTransaction: Equatable, Sendable {
    public var token: EditorTransactionToken
    public var tool: StrokeTool
    public var phase: DrawingPhase

    public init(
        token: EditorTransactionToken,
        tool: StrokeTool,
        phase: DrawingPhase
    ) {
        self.token = token
        self.tool = tool
        self.phase = phase
    }
}

public enum EditorTransactionState: Equatable, Sendable {
    case idle
    case drawing(DrawingTransaction)
    case selectingDraft(SelectionRegion?)
    case selectionReady(SelectionRegion)
    case transforming(SelectionRegion)
}

public enum EditorTransactionEvent: Equatable, Sendable {
    case pointerBegan(
        StrokeSample,
        tool: StrokeTool,
        style: StrokeRenderStyle
    )
    case pointerMoved(StrokeSample)
    case pointerEnded(StrokeSample)
    case pointerCancelled
    case toolIntent(EditorTool)
    case colorIntent(InkColor)
    case brushDiameterIntent(Float)
    case gridVisibilityIntent(Bool)
    case command(EditorCommand)
    case tilingIntent(TilingKind)
    case tileSizeIntent(PixelSize)
    case selectionChanged(SelectionRegion?)
    case selectionEnded
    case operationCompleted(EditorTransactionToken, succeeded: Bool)
}

public enum EditorTransactionEffect: Equatable, Sendable {
    case beginStroke(
        EditorTransactionToken,
        StrokeSample,
        StrokeTool,
        StrokeRenderStyle
    )
    case appendStroke(EditorTransactionToken, StrokeSample)
    case requestStrokeCommit(EditorTransactionToken, StrokeSample)
    case cancelStroke(EditorTransactionToken)
    case updateTool(EditorTool)
    case updateColor(InkColor)
    case updateBrushDiameter(Float)
    case updateGridVisibility(Bool)
    case performCommand(EditorTransactionToken, EditorCommand)
    case applyTiling(EditorTransactionToken, TilingKind)
    case applyTileSize(EditorTransactionToken, PixelSize)
    case clearSelectionOverlay
    case beginTransform(SelectionRegion)
    case cancelTransform
    case busy
    case reportOperationFailure
}

public struct EditorTransaction: Equatable, Sendable {
    private var nextToken: UInt64
    public private(set) var state: EditorTransactionState
    public private(set) var pendingOperation: EditorTransactionToken?

    public init() {
        nextToken = 1
        state = .idle
        pendingOperation = nil
    }

    public var isBusy: Bool {
        if pendingOperation != nil {
            return true
        }
        guard case let .drawing(drawing) = state else {
            return false
        }
        return drawing.phase == .commitPending
    }

    public mutating func apply(
        _ event: EditorTransactionEvent
    ) -> [EditorTransactionEffect] {
        if case let .operationCompleted(token, succeeded) = event {
            return completeOperation(token, succeeded: succeeded)
        }

        if isBusy {
            return [.busy]
        }

        switch state {
        case .idle:
            return applyWhileIdle(event)
        case let .drawing(drawing):
            return applyWhileCollecting(event, drawing: drawing)
        case let .selectingDraft(region):
            return applyWhileSelectingDraft(event, region: region)
        case let .selectionReady(region):
            return applyWhileSelectionReady(event, region: region)
        case .transforming:
            return applyWhileTransforming(event)
        }
    }

    private mutating func completeOperation(
        _ token: EditorTransactionToken,
        succeeded: Bool
    ) -> [EditorTransactionEffect] {
        if pendingOperation == token {
            pendingOperation = nil
            return succeeded ? [] : [.reportOperationFailure]
        }

        if case let .drawing(drawing) = state,
           drawing.phase == .commitPending,
           drawing.token == token
        {
            state = .idle
            return succeeded ? [] : [.reportOperationFailure]
        }

        return []
    }

    private mutating func applyWhileIdle(
        _ event: EditorTransactionEvent
    ) -> [EditorTransactionEffect] {
        switch event {
        case let .pointerBegan(sample, tool, style):
            let token = takeToken()
            state = .drawing(
                DrawingTransaction(
                    token: token,
                    tool: tool,
                    phase: .collecting
                )
            )
            return [.beginStroke(token, sample, tool, style)]
        case .pointerMoved, .pointerEnded, .pointerCancelled:
            return []
        case let .toolIntent(tool):
            return [.updateTool(tool)]
        case let .colorIntent(color):
            return [.updateColor(color)]
        case let .brushDiameterIntent(diameter):
            return [.updateBrushDiameter(diameter)]
        case let .gridVisibilityIntent(visible):
            return [.updateGridVisibility(visible)]
        case let .command(command):
            return [beginCommand(command)]
        case let .tilingIntent(tiling):
            return [beginTiling(tiling)]
        case let .tileSizeIntent(size):
            return [beginTileSize(size)]
        case let .selectionChanged(region):
            state = .selectingDraft(region)
            return []
        case .selectionEnded, .operationCompleted:
            return []
        }
    }

    private mutating func applyWhileCollecting(
        _ event: EditorTransactionEvent,
        drawing: DrawingTransaction
    ) -> [EditorTransactionEffect] {
        switch event {
        case .pointerBegan:
            return [.busy]
        case let .pointerMoved(sample):
            return [.appendStroke(drawing.token, sample)]
        case let .pointerEnded(sample):
            state = .drawing(
                DrawingTransaction(
                    token: drawing.token,
                    tool: drawing.tool,
                    phase: .commitPending
                )
            )
            return [.requestStrokeCommit(drawing.token, sample)]
        case .pointerCancelled:
            state = .idle
            return [.cancelStroke(drawing.token)]
        case let .toolIntent(tool):
            state = .idle
            return [.cancelStroke(drawing.token), .updateTool(tool)]
        case let .colorIntent(color):
            state = .idle
            return [.cancelStroke(drawing.token), .updateColor(color)]
        case let .brushDiameterIntent(diameter):
            state = .idle
            return [
                .cancelStroke(drawing.token),
                .updateBrushDiameter(diameter),
            ]
        case let .gridVisibilityIntent(visible):
            return [.updateGridVisibility(visible)]
        case let .command(command):
            state = .idle
            return [.cancelStroke(drawing.token), beginCommand(command)]
        case let .tilingIntent(tiling):
            state = .idle
            return [.cancelStroke(drawing.token), beginTiling(tiling)]
        case let .tileSizeIntent(size):
            state = .idle
            return [.cancelStroke(drawing.token), beginTileSize(size)]
        case .selectionChanged, .selectionEnded:
            return [.busy]
        case .operationCompleted:
            return []
        }
    }

    private mutating func applyWhileSelectingDraft(
        _ event: EditorTransactionEvent,
        region: SelectionRegion?
    ) -> [EditorTransactionEffect] {
        switch event {
        case .pointerBegan, .pointerMoved, .pointerEnded:
            return []
        case .pointerCancelled:
            state = .idle
            return clearSelectionEffects(for: region)
        case let .toolIntent(tool):
            state = .idle
            return clearSelectionEffects(for: region) + [.updateTool(tool)]
        case let .colorIntent(color):
            state = .idle
            return clearSelectionEffects(for: region) + [.updateColor(color)]
        case let .brushDiameterIntent(diameter):
            state = .idle
            return clearSelectionEffects(for: region)
                + [.updateBrushDiameter(diameter)]
        case let .gridVisibilityIntent(visible):
            return [.updateGridVisibility(visible)]
        case let .command(command):
            state = .idle
            return clearSelectionEffects(for: region) + [beginCommand(command)]
        case let .tilingIntent(tiling):
            state = .idle
            return clearSelectionEffects(for: region) + [beginTiling(tiling)]
        case let .tileSizeIntent(size):
            state = .idle
            return clearSelectionEffects(for: region) + [beginTileSize(size)]
        case let .selectionChanged(nextRegion):
            state = .selectingDraft(nextRegion)
            return []
        case .selectionEnded:
            if let region {
                state = .selectionReady(region)
            } else {
                state = .idle
            }
            return []
        case .operationCompleted:
            return []
        }
    }

    private mutating func applyWhileSelectionReady(
        _ event: EditorTransactionEvent,
        region: SelectionRegion
    ) -> [EditorTransactionEffect] {
        switch event {
        case .pointerBegan, .pointerMoved, .pointerEnded:
            return []
        case .pointerCancelled:
            state = .idle
            return [.clearSelectionOverlay]
        case .toolIntent(.transform):
            state = .transforming(region)
            return [.updateTool(.transform), .beginTransform(region)]
        case let .toolIntent(tool):
            state = .idle
            return [.clearSelectionOverlay, .updateTool(tool)]
        case let .colorIntent(color):
            state = .idle
            return [.clearSelectionOverlay, .updateColor(color)]
        case let .brushDiameterIntent(diameter):
            state = .idle
            return [
                .clearSelectionOverlay,
                .updateBrushDiameter(diameter),
            ]
        case let .gridVisibilityIntent(visible):
            return [.updateGridVisibility(visible)]
        case let .command(command):
            state = .idle
            return [.clearSelectionOverlay, beginCommand(command)]
        case let .tilingIntent(tiling):
            state = .idle
            return [.clearSelectionOverlay, beginTiling(tiling)]
        case let .tileSizeIntent(size):
            state = .idle
            return [.clearSelectionOverlay, beginTileSize(size)]
        case let .selectionChanged(nextRegion):
            state = .selectingDraft(nextRegion)
            return []
        case .selectionEnded, .operationCompleted:
            return []
        }
    }

    private mutating func applyWhileTransforming(
        _ event: EditorTransactionEvent
    ) -> [EditorTransactionEffect] {
        switch event {
        case .pointerBegan, .pointerMoved, .pointerEnded:
            return []
        case .pointerCancelled:
            state = .idle
            return [.cancelTransform, .clearSelectionOverlay]
        case .toolIntent(.transform):
            return [.updateTool(.transform)]
        case let .toolIntent(tool):
            state = .idle
            return [
                .cancelTransform,
                .clearSelectionOverlay,
                .updateTool(tool),
            ]
        case let .colorIntent(color):
            state = .idle
            return [
                .cancelTransform,
                .clearSelectionOverlay,
                .updateColor(color),
            ]
        case let .brushDiameterIntent(diameter):
            state = .idle
            return [
                .cancelTransform,
                .clearSelectionOverlay,
                .updateBrushDiameter(diameter),
            ]
        case let .gridVisibilityIntent(visible):
            return [.updateGridVisibility(visible)]
        case let .command(command):
            state = .idle
            return [
                .cancelTransform,
                .clearSelectionOverlay,
                beginCommand(command),
            ]
        case let .tilingIntent(tiling):
            state = .idle
            return [
                .cancelTransform,
                .clearSelectionOverlay,
                beginTiling(tiling),
            ]
        case let .tileSizeIntent(size):
            state = .idle
            return [
                .cancelTransform,
                .clearSelectionOverlay,
                beginTileSize(size),
            ]
        case .selectionChanged, .selectionEnded, .operationCompleted:
            return []
        }
    }

    private func clearSelectionEffects(
        for region: SelectionRegion?
    ) -> [EditorTransactionEffect] {
        region == nil ? [] : [.clearSelectionOverlay]
    }

    private mutating func beginCommand(
        _ command: EditorCommand
    ) -> EditorTransactionEffect {
        let token = takeToken()
        pendingOperation = token
        return .performCommand(token, command)
    }

    private mutating func beginTiling(
        _ tiling: TilingKind
    ) -> EditorTransactionEffect {
        let token = takeToken()
        pendingOperation = token
        return .applyTiling(token, tiling)
    }

    private mutating func beginTileSize(
        _ size: PixelSize
    ) -> EditorTransactionEffect {
        let token = takeToken()
        pendingOperation = token
        return .applyTileSize(token, size)
    }

    private mutating func takeToken() -> EditorTransactionToken {
        let token = EditorTransactionToken(rawValue: nextToken)
        nextToken &+= 1
        if nextToken == 0 {
            nextToken = 1
        }
        return token
    }
}
