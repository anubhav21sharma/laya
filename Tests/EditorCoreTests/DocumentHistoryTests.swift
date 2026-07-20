import EditorCore
import PatternEngine
import Testing

@Test
func navigationMovesCursorOnlyAfterSuccess() throws {
    let history = DocumentHistory()
    let command = makeRasterCommand(bytes: 64)
    try history.validateNewCommand(retainedBytes: command.retainedBytes)
    _ = history.appendSuccessful(command)

    let undo = try #require(try history.beginUndo())
    #expect(history.canUndo)
    try history.finishNavigation(token: undo.token, succeeded: false)
    #expect(history.canUndo)

    let retry = try #require(try history.beginUndo())
    try history.finishNavigation(token: retry.token, succeeded: true)
    #expect(!history.canUndo)
    #expect(history.canRedo)
}

@Test
func appendClearsRedoAndPrunesBothBounds() throws {
    let history = DocumentHistory(maximumCommands: 3, maximumBytes: 100)
    for index in 0..<4 {
        let command = makeRasterCommand(seed: UInt64(index), bytes: 40)
        try history.validateNewCommand(retainedBytes: command.retainedBytes)
        _ = history.appendSuccessful(command)
    }

    #expect(history.commandCount == 2)
    #expect(history.retainedRasterBytes == 80)
}

@Test
func metadataCommandsHaveNoRetainedRasterCost() throws {
    let history = DocumentHistory(maximumCommands: 2, maximumBytes: 0)
    let command = DocumentHistoryCommand.tiling(
        MetadataChange(before: TilingKind.grid, after: .mirrorX)
    )

    try history.validateNewCommand(retainedBytes: command.retainedBytes)
    let released = history.appendSuccessful(command)

    #expect(command.retainedBytes == 0)
    #expect(history.commandCount == 1)
    #expect(history.retainedRasterBytes == 0)
    #expect(released.isEmpty)
}

@Test
func staleNavigationTokensFail() throws {
    let history = DocumentHistory()
    let command = makeRasterCommand(bytes: 64)
    try history.validateNewCommand(retainedBytes: command.retainedBytes)
    _ = history.appendSuccessful(command)

    let undo = try #require(try history.beginUndo())
    try history.finishNavigation(token: undo.token, succeeded: false)

    #expect(throws: DocumentHistoryError.staleNavigationToken) {
        try history.finishNavigation(token: undo.token, succeeded: true)
    }
}

@Test
func appendReleasesRedoAndPrunedRevisionIDsWithoutDuplicates() throws {
    let history = DocumentHistory(maximumCommands: 3, maximumBytes: 100)
    let first = makeRasterCommand(seed: 1, bytes: 40)
    let second = makeRasterCommand(beforeID: 3, afterID: 4, bytes: 40)
    let redo = makeRasterCommand(seed: 3, bytes: 20)
    let replacement = makeRasterCommand(seed: 4, bytes: 60)

    for command in [first, second, redo] {
        try history.validateNewCommand(retainedBytes: command.retainedBytes)
        _ = history.appendSuccessful(command)
    }

    let undo = try #require(try history.beginUndo())
    try history.finishNavigation(token: undo.token, succeeded: true)

    try history.validateNewCommand(retainedBytes: replacement.retainedBytes)
    let released = history.appendSuccessful(replacement)

    #expect(released == [
        StoredRasterRevisionID(rawValue: 2),
        StoredRasterRevisionID(rawValue: 6),
        StoredRasterRevisionID(rawValue: 7),
    ])
    #expect(released.count == 3)
}

@Test
func pendingNavigationRejectsPreflightAndBothNavigationStarts() throws {
    let history = DocumentHistory()
    let command = makeRasterCommand(bytes: 64)
    try history.validateNewCommand(retainedBytes: command.retainedBytes)
    _ = history.appendSuccessful(command)

    let pendingUndo = try #require(try history.beginUndo())

    #expect(throws: DocumentHistoryError.navigationPending) {
        try history.validateNewCommand(retainedBytes: command.retainedBytes)
    }
    #expect(throws: DocumentHistoryError.navigationPending) {
        _ = try history.beginUndo()
    }
    #expect(throws: DocumentHistoryError.navigationPending) {
        _ = try history.beginRedo()
    }

    try history.finishNavigation(token: pendingUndo.token, succeeded: true)
    let pendingRedo = try #require(try history.beginRedo())

    #expect(throws: DocumentHistoryError.navigationPending) {
        _ = try history.beginUndo()
    }
    #expect(throws: DocumentHistoryError.navigationPending) {
        _ = try history.beginRedo()
    }

    try history.finishNavigation(token: pendingRedo.token, succeeded: false)
}

@Test
func zeroCommandLimitReleasesImmediatelyPrunedIncomingRevisions() throws {
    let history = DocumentHistory(maximumCommands: 0, maximumBytes: 64)
    let command = makeRasterCommand(beforeID: 10, afterID: 11, bytes: 64)

    try history.validateNewCommand(retainedBytes: command.retainedBytes)
    let released = history.appendSuccessful(command)

    #expect(history.commandCount == 0)
    #expect(history.retainedRasterBytes == 0)
    #expect(released == [
        StoredRasterRevisionID(rawValue: 10),
        StoredRasterRevisionID(rawValue: 11),
    ])
}

@Test
func preflightRejectsNegativeAndOversizedCommands() {
    let history = DocumentHistory(maximumBytes: 100)

    #expect(throws: DocumentHistoryError.negativeRetainedBytes(-1)) {
        try history.validateNewCommand(retainedBytes: -1)
    }
    #expect(throws: DocumentHistoryError.commandExceedsMaximumBytes(
        retainedBytes: 101,
        maximumBytes: 100
    )) {
        try history.validateNewCommand(retainedBytes: 101)
    }
}

private func makeRasterCommand(
    seed: UInt64 = 1,
    bytes: Int
) -> DocumentHistoryCommand {
    precondition(bytes.isMultiple(of: 2))
    return makeRasterCommand(
        beforeID: seed * 2,
        afterID: seed * 2 + 1,
        bytes: bytes
    )
}

private func makeRasterCommand(
    beforeID: UInt64,
    afterID: UInt64,
    bytes: Int
) -> DocumentHistoryCommand {
    precondition(bytes.isMultiple(of: 2))
    let size = PixelSize(width: 64, height: 64)
    let regions = PixelRegionSet(
        [PixelRect(minX: 0, minY: 0, maxX: 1, maxY: 1)!],
        clippedTo: size
    )
    let before = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: beforeID),
        pixelSize: size,
        regions: regions,
        retainedBytes: bytes / 2
    )
    let after = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: afterID),
        pixelSize: size,
        regions: regions,
        retainedBytes: bytes / 2
    )
    return .raster(
        RasterHistoryCommand(kind: .draw, before: before, after: after)
    )
}
