import EditorCore
import PatternEngine
import Testing

private func sample(_ phase: StrokePhase) -> StrokeSample {
    .mouse(
        position: ScreenPoint(x: 32, y: 48),
        timestamp: 1,
        phase: phase
    )
}

private let style = StrokeRenderStyle(
    color: .black,
    diameter: 20,
    compositeMode: .draw,
    eraserStrength: 1
)

private let alternateColor = InkColor(
    red: 0.25,
    green: 0.5,
    blue: 0.75,
    alpha: 1
)!

private let region = SelectionRegion(
    rawOrigin: CanonicalPoint(x: -8, y: 12),
    folded: PixelRect(minX: 4, minY: 12, maxX: 20, maxY: 36)!
)

private func collectingDrawTransaction() -> EditorTransaction {
    var transaction = EditorTransaction()
    _ = transaction.apply(
        .pointerBegan(sample(.began), tool: .draw, style: style)
    )
    return transaction
}

private func commitPendingTransaction() -> EditorTransaction {
    var transaction = collectingDrawTransaction()
    _ = transaction.apply(.pointerEnded(sample(.ended)))
    return transaction
}

private func selectingTransaction(
    _ selection: SelectionRegion?
) -> EditorTransaction {
    var transaction = EditorTransaction()
    _ = transaction.apply(.selectionChanged(selection))
    return transaction
}

private func selectionReadyTransaction() -> EditorTransaction {
    var transaction = selectingTransaction(region)
    _ = transaction.apply(.selectionEnded)
    return transaction
}

private func transformingTransaction() -> EditorTransaction {
    var transaction = selectionReadyTransaction()
    _ = transaction.apply(.toolIntent(.transform))
    return transaction
}

private func pendingCommandTransaction() -> EditorTransaction {
    var transaction = EditorTransaction()
    _ = transaction.apply(.command(.clear))
    return transaction
}

@Test
func strokeSamplesUseOneTokenThroughCommit() {
    var transaction = EditorTransaction()

    let began = transaction.apply(
        .pointerBegan(sample(.began), tool: .draw, style: style)
    )
    guard
        case let .beginStroke(token, beganSample, tool, beganStyle) = began.first
    else {
        Issue.record("Expected beginStroke")
        return
    }
    #expect(began.count == 1)
    #expect(beganSample == sample(.began))
    #expect(tool == .draw)
    #expect(beganStyle == style)

    #expect(
        transaction.apply(.pointerMoved(sample(.moved)))
            == [.appendStroke(token, sample(.moved))]
    )
    #expect(
        transaction.apply(.pointerEnded(sample(.ended)))
            == [.requestStrokeCommit(token, sample(.ended))]
    )

    guard case let .drawing(drawing) = transaction.state else {
        Issue.record("Expected drawing state")
        return
    }
    #expect(drawing.token == token)
    #expect(drawing.tool == .draw)
    #expect(drawing.phase == .commitPending)
}

@Test
func pointerEventsRejectMismatchedSamplePhasesWithoutAllocatingTokens() {
    var idle = EditorTransaction()
    let idleBefore = idle

    #expect(
        idle.apply(
            .pointerBegan(sample(.moved), tool: .draw, style: style)
        ) == []
    )
    #expect(idle == idleBefore)

    let began = idle.apply(
        .pointerBegan(sample(.began), tool: .draw, style: style)
    )
    guard case let .beginStroke(token, _, _, _) = began.first else {
        Issue.record("Expected valid stroke after rejected mismatch")
        return
    }
    #expect(token.rawValue == 1)

    let collectingBefore = idle
    #expect(idle.apply(.pointerMoved(sample(.ended))) == [])
    #expect(idle == collectingBefore)
    #expect(idle.apply(.pointerEnded(sample(.moved))) == [])
    #expect(idle == collectingBefore)
    #expect(idle.apply(.pointerMoved(sample(.cancelled))) == [])
    #expect(idle == collectingBefore)
}

@Test
func undoDuringCollectingCancelsBeforeCommand() {
    var transaction = collectingDrawTransaction()
    guard case let .drawing(drawing) = transaction.state else {
        Issue.record("Expected collecting drawing transaction")
        return
    }

    let effects = transaction.apply(.command(.undo))

    #expect(effects.count == 2)
    guard
        case let .cancelStroke(cancelledToken) = effects[0],
        case let .performCommand(_, command) = effects[1]
    else {
        Issue.record("Expected cancelStroke then performCommand")
        return
    }
    #expect(cancelledToken == drawing.token)
    #expect(command == .undo)
    #expect(transaction.pendingOperation != nil)
}

@Test
func pointerEndStaysDrawingUntilMatchingCompletion() {
    var transaction = collectingDrawTransaction()
    _ = transaction.apply(.pointerEnded(sample(.ended)))
    guard case let .drawing(drawing) = transaction.state else {
        Issue.record("Expected drawing state")
        return
    }
    #expect(drawing.phase == .commitPending)
    #expect(transaction.isBusy)
}

@Test
func collectingStrokeCancelsBeforeSynchronousAndConfigurationIntents() {
    var toolTransaction = collectingDrawTransaction()
    guard case let .drawing(toolDrawing) = toolTransaction.state else {
        Issue.record("Expected drawing state")
        return
    }
    #expect(
        toolTransaction.apply(.toolIntent(.erase))
            == [.cancelStroke(toolDrawing.token), .updateTool(.erase)]
    )

    var colorTransaction = collectingDrawTransaction()
    guard case let .drawing(colorDrawing) = colorTransaction.state else {
        Issue.record("Expected drawing state")
        return
    }
    #expect(
        colorTransaction.apply(.colorIntent(alternateColor))
            == [
                .cancelStroke(colorDrawing.token),
                .updateColor(alternateColor),
            ]
    )

    var diameterTransaction = collectingDrawTransaction()
    guard case let .drawing(diameterDrawing) = diameterTransaction.state else {
        Issue.record("Expected drawing state")
        return
    }
    #expect(
        diameterTransaction.apply(.brushDiameterIntent(32))
            == [
                .cancelStroke(diameterDrawing.token),
                .updateBrushDiameter(32),
            ]
    )

    var tilingTransaction = collectingDrawTransaction()
    guard case let .drawing(tilingDrawing) = tilingTransaction.state else {
        Issue.record("Expected drawing state")
        return
    }
    let tilingEffects = tilingTransaction.apply(.tilingIntent(.brick))
    #expect(tilingEffects.count == 2)
    #expect(tilingEffects[0] == .cancelStroke(tilingDrawing.token))
    guard case let .applyTiling(tilingToken, .brick) = tilingEffects[1] else {
        Issue.record("Expected applyTiling")
        return
    }
    #expect(tilingTransaction.pendingOperation == tilingToken)

    var sizeTransaction = collectingDrawTransaction()
    guard case let .drawing(sizeDrawing) = sizeTransaction.state else {
        Issue.record("Expected drawing state")
        return
    }
    let size = PixelSize(width: 288, height: 320)
    let sizeEffects = sizeTransaction.apply(.tileSizeIntent(size))
    #expect(sizeEffects.count == 2)
    #expect(sizeEffects[0] == .cancelStroke(sizeDrawing.token))
    guard case let .applyTileSize(sizeToken, appliedSize) = sizeEffects[1] else {
        Issue.record("Expected applyTileSize")
        return
    }
    #expect(appliedSize == size)
    #expect(sizeTransaction.pendingOperation == sizeToken)
}

@Test
func transformInterruptionCancelsAndClearsBeforeCommand() {
    var transaction = transformingTransaction()

    let effects = transaction.apply(.command(.redo))

    #expect(effects.count == 3)
    #expect(effects[0] == .cancelTransform)
    #expect(effects[1] == .clearSelectionOverlay)
    guard case let .performCommand(token, .redo) = effects[2] else {
        Issue.record("Expected performCommand last")
        return
    }
    #expect(transaction.state == .idle)
    #expect(transaction.pendingOperation == token)
}

@Test
func transformGridChangeCancelsAndClearsBeforeConfigurationEffect() {
    var transaction = transformingTransaction()

    #expect(
        transaction.apply(.gridVisibilityIntent(true))
            == [
                .cancelTransform,
                .clearSelectionOverlay,
                .updateGridVisibility(true),
            ]
    )
    #expect(transaction.state == .idle)
}

@Test
func invalidTileSizeIntentIsRejectedBeforeCancellationOrTokenAllocation() {
    var idle = EditorTransaction()
    let idleBefore = idle
    #expect(
        idle.apply(
            .tileSizeIntent(PixelSize(width: 63, height: 64))
        ) == []
    )
    #expect(idle == idleBefore)

    let validEffects = idle.apply(
        .tileSizeIntent(PixelSize(width: 64, height: 64))
    )
    guard case let .applyTileSize(token, _) = validEffects.first else {
        Issue.record("Expected valid tile-size operation")
        return
    }
    #expect(token.rawValue == 1)

    var collecting = collectingDrawTransaction()
    let collectingBefore = collecting
    #expect(
        collecting.apply(
            .tileSizeIntent(PixelSize(width: 4_097, height: 4_096))
        ) == []
    )
    #expect(collecting == collectingBefore)
}

@Test
func selectionDraftSettlesOnlyWithARegionAndReadySelectionCanTransform() {
    var empty = selectingTransaction(nil)
    #expect(empty.state == .selectingDraft(nil))
    #expect(empty.apply(.selectionEnded) == [])
    #expect(empty.state == .idle)

    var transaction = selectingTransaction(region)
    #expect(transaction.state == .selectingDraft(region))
    #expect(transaction.apply(.selectionEnded) == [])
    #expect(transaction.state == .selectionReady(region))
    #expect(
        transaction.apply(.toolIntent(.transform))
            == [.updateTool(.transform), .beginTransform(region)]
    )
    #expect(transaction.state == .transforming(region))
}

@Test
func pointerCancellationClearsEveryLiveLifecycle() {
    var drawing = collectingDrawTransaction()
    guard case let .drawing(value) = drawing.state else {
        Issue.record("Expected drawing state")
        return
    }
    #expect(drawing.apply(.pointerCancelled) == [.cancelStroke(value.token)])
    #expect(drawing.state == .idle)

    var draft = selectingTransaction(region)
    #expect(draft.apply(.pointerCancelled) == [.clearSelectionOverlay])
    #expect(draft.state == .idle)

    var ready = selectionReadyTransaction()
    #expect(ready.apply(.pointerCancelled) == [.clearSelectionOverlay])
    #expect(ready.state == .idle)

    var transforming = transformingTransaction()
    #expect(
        transforming.apply(.pointerCancelled)
            == [.cancelTransform, .clearSelectionOverlay]
    )
    #expect(transforming.state == .idle)
}

@Test
func submittedWorkRejectsConflictsAndGridChanges() {
    var stroke = commitPendingTransaction()
    let strokeState = stroke.state
    #expect(stroke.apply(.pointerMoved(sample(.moved))) == [.busy])
    #expect(stroke.state == strokeState)
    #expect(stroke.apply(.gridVisibilityIntent(true)) == [.busy])
    #expect(stroke.state == strokeState)

    var command = pendingCommandTransaction()
    let commandState = command.state
    let pending = command.pendingOperation
    #expect(command.apply(.toolIntent(.erase)) == [.busy])
    #expect(command.apply(.gridVisibilityIntent(true)) == [.busy])
    #expect(command.state == commandState)
    #expect(command.pendingOperation == pending)
}

@Test
func staleCompletionDoesNotChangeState() {
    var transaction = commitPendingTransaction()
    let originalState = transaction.state
    let originalPending = transaction.pendingOperation

    #expect(
        transaction.apply(
            .operationCompleted(
                EditorTransactionToken(rawValue: 9_999),
                succeeded: true
            )
        ) == []
    )
    #expect(transaction.state == originalState)
    #expect(transaction.pendingOperation == originalPending)
}

@Test
func matchingCompletionsReleaseBusyStateAndReportFailure() {
    var stroke = commitPendingTransaction()
    guard case let .drawing(drawing) = stroke.state else {
        Issue.record("Expected drawing state")
        return
    }
    #expect(
        stroke.apply(
            .operationCompleted(drawing.token, succeeded: false)
        ) == [.reportOperationFailure]
    )
    #expect(stroke.state == .idle)
    #expect(!stroke.isBusy)

    var command = pendingCommandTransaction()
    guard let token = command.pendingOperation else {
        Issue.record("Expected pending operation")
        return
    }
    #expect(
        command.apply(
            .operationCompleted(token, succeeded: true)
        ) == []
    )
    #expect(command.pendingOperation == nil)
    #expect(!command.isBusy)
}

@Test
func matchingRendererFailureTerminatesCollectingTransaction() {
    var transaction = collectingDrawTransaction()
    guard case let .drawing(drawing) = transaction.state else {
        Issue.record("Expected collecting drawing transaction")
        return
    }

    #expect(
        transaction.apply(
            .operationCompleted(drawing.token, succeeded: false)
        ) == [.reportOperationFailure]
    )
    #expect(transaction.state == .idle)
    #expect(!transaction.isBusy)
}

@Test
func everyStateAndEventPairIsTotal() {
    let transactions = [
        EditorTransaction(),
        collectingDrawTransaction(),
        commitPendingTransaction(),
        selectingTransaction(nil),
        selectingTransaction(region),
        selectionReadyTransaction(),
        transformingTransaction(),
        pendingCommandTransaction(),
    ]
    let events: [EditorTransactionEvent] = [
        .pointerBegan(sample(.began), tool: .draw, style: style),
        .pointerMoved(sample(.moved)),
        .pointerEnded(sample(.ended)),
        .pointerCancelled,
        .toolIntent(.erase),
        .colorIntent(alternateColor),
        .brushDiameterIntent(24),
        .gridVisibilityIntent(true),
        .command(.undo),
        .tilingIntent(.halfDrop),
        .tileSizeIntent(PixelSize(width: 288, height: 320)),
        .selectionChanged(region),
        .selectionEnded,
        .operationCompleted(
            EditorTransactionToken(rawValue: 999),
            succeeded: false
        ),
    ]

    var pairCount = 0
    for original in transactions {
        for event in events {
            var transaction = original
            _ = transaction.apply(event)
            pairCount += 1
        }
    }

    #expect(pairCount == transactions.count * events.count)
}

private struct RejectedPair {
    let transaction: EditorTransaction
    let event: EditorTransactionEvent
    let effects: [EditorTransactionEffect]
}

@Test
func illegalStateEventPairsRejectWithoutMutationOrIllegalEffects() {
    let idle = EditorTransaction()
    let collecting = collectingDrawTransaction()
    let commitPending = commitPendingTransaction()
    let draft = selectingTransaction(region)
    let ready = selectionReadyTransaction()
    let transforming = transformingTransaction()
    let pending = pendingCommandTransaction()

    let pairs = [
        RejectedPair(
            transaction: idle,
            event: .pointerMoved(sample(.moved)),
            effects: []
        ),
        RejectedPair(
            transaction: idle,
            event: .pointerEnded(sample(.ended)),
            effects: []
        ),
        RejectedPair(
            transaction: collecting,
            event: .pointerBegan(
                sample(.began),
                tool: .draw,
                style: style
            ),
            effects: [.busy]
        ),
        RejectedPair(
            transaction: collecting,
            event: .pointerMoved(sample(.ended)),
            effects: []
        ),
        RejectedPair(
            transaction: collecting,
            event: .pointerEnded(sample(.moved)),
            effects: []
        ),
        RejectedPair(
            transaction: commitPending,
            event: .toolIntent(.erase),
            effects: [.busy]
        ),
        RejectedPair(
            transaction: draft,
            event: .pointerBegan(
                sample(.began),
                tool: .draw,
                style: style
            ),
            effects: []
        ),
        RejectedPair(
            transaction: ready,
            event: .pointerMoved(sample(.moved)),
            effects: []
        ),
        RejectedPair(
            transaction: transforming,
            event: .pointerEnded(sample(.ended)),
            effects: []
        ),
        RejectedPair(
            transaction: pending,
            event: .gridVisibilityIntent(true),
            effects: [.busy]
        ),
    ]

    for pair in pairs {
        var transaction = pair.transaction
        #expect(transaction.apply(pair.event) == pair.effects)
        #expect(transaction == pair.transaction)
    }
}
