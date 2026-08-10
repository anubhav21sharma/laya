@testable import EditorCore
import Foundation
import PatternEngine
import Testing

private let historyLayerID = UUID(
    uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
)!

@Test
func diagnosticSnapshotIncludesBaseSemanticsAndNavigationSequence() throws {
    let history = DocumentHistory(initialDocumentIsEmpty: false)
    let initial = history.diagnosticSnapshotForTesting()
    #expect(!initial.baseDocumentIsEmpty)
    #expect(initial.nextNavigationToken == 0)

    _ = history.appendSuccessful(makeRasterCommand(bytes: 64))
    let navigation = try #require(try history.beginUndo())
    let pending = history.diagnosticSnapshotForTesting()
    #expect(pending.nextNavigationToken == 1)
    #expect(pending.pendingNavigation?.token == navigation.token)
    #expect(!pending.baseDocumentIsEmpty)
}

@Test
func navigationMovesCursorOnlyAfterSuccess() throws {
    let history = DocumentHistory()
    let command = makeRasterCommand(bytes: 64)
    try history.validateNewCommand(retainedBytes: command.retainedBytes)
    _ = history.appendSuccessful(command)

    let undo = try #require(try history.beginUndo())
    #expect(history.canUndo)
    #expect(!history.canRedo)
    try history.finishNavigation(token: undo.token, succeeded: false)
    #expect(history.canUndo)
    #expect(!history.canRedo)

    let retry = try #require(try history.beginUndo())
    try history.finishNavigation(token: retry.token, succeeded: true)
    #expect(!history.canUndo)
    #expect(history.canRedo)
}

@Test
func eraseIsATypedRasterCommand() throws {
    let history = DocumentHistory()
    let erase = makeRasterCommand(kind: .erase, bytes: 64)
    try history.validateNewCommand(retainedBytes: erase.retainedBytes)
    _ = history.appendSuccessful(erase)

    let undo = try #require(try history.beginUndo())
    guard case let .raster(command) = undo.command else {
        Issue.record("Expected erase to be wrapped in a raster command")
        return
    }
    #expect(command.kind == .erase)
    try history.finishNavigation(token: undo.token, succeeded: false)
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
func periodicConfigurationMetadataHasNoRetainedRasterCost() throws {
    let history = DocumentHistory(maximumCommands: 2, maximumBytes: 0)
    let before = PeriodicSymmetryConfiguration(
        presetID: .grid,
        repeatSize: PatternSize(width: 256, height: 256)
    )
    let after = PeriodicSymmetryConfiguration(
        presetID: .squareKaleidoscope,
        repeatSize: PatternSize(width: 320, height: 320),
        orientationRadians: .pi / 6
    )
    let command = DocumentHistoryCommand.periodicConfiguration(
        MetadataChange(before: before, after: after)
    )

    try history.validateNewCommand(retainedBytes: command.retainedBytes)
    let released = history.appendSuccessful(command)

    #expect(command.retainedBytes == 0)
    #expect(command.revisionIDs.isEmpty)
    #expect(history.commandCount == 1)
    #expect(history.retainedRasterBytes == 0)
    #expect(released.isEmpty)
}

@Test
func periodicConfigurationUndoRedoPreservesExactCommandIdentity() throws {
    let history = DocumentHistory()
    let before = PeriodicSymmetryConfiguration(
        presetID: .halfDrop,
        repeatSize: PatternSize(width: 192, height: 128),
        orientationRadians: .pi / 8
    )
    let after = PeriodicSymmetryConfiguration(
        presetID: .kaleidoscope30,
        repeatSize: PatternSize(width: 384, height: 384),
        orientationRadians: .pi / 4
    )
    let command = DocumentHistoryCommand.periodicConfiguration(
        MetadataChange(before: before, after: after)
    )
    try history.validateNewCommand(retainedBytes: command.retainedBytes)
    _ = history.appendSuccessful(command)

    let undo = try #require(try history.beginUndo())
    #expect(undo.command == command)
    try history.finishNavigation(token: undo.token, succeeded: true)

    let redo = try #require(try history.beginRedo())
    #expect(redo.command == command)
    guard case let .periodicConfiguration(change) = redo.command else {
        Issue.record("Expected periodic-configuration metadata command")
        return
    }
    #expect(change.before == before)
    #expect(change.after == after)
    try history.finishNavigation(token: redo.token, succeeded: true)
}

@Test
func tileResizeRetainsOneAtomicMultiLayerGeometryRevision() throws {
    let beforeSize = PixelSize(width: 96, height: 80)
    let afterSize = PixelSize(width: 64, height: 72)
    let command = TileResizeHistoryCommand(
        beforePixelSize: beforeSize,
        afterPixelSize: afterSize,
        layerRevision: LayerSurfaceRevisionReference(
            id: StoredRasterRevisionID(rawValue: 100),
            retainedBytes: 53_248
        )
    )
    let history = DocumentHistory(maximumBytes: 100_000)

    try history.validateNewCommand(retainedBytes: command.retainedBytes)
    let released = history.appendSuccessful(.tileResize(command))

    #expect(command.beforePixelSize == beforeSize)
    #expect(command.afterPixelSize == afterSize)
    #expect(command.retainedBytes == 53_248)
    #expect(history.retainedRasterBytes == 53_248)
    #expect(released.isEmpty)

    let undo = try #require(try history.beginUndo())
    #expect(undo.command == .tileResize(command))
    try history.finishNavigation(token: undo.token, succeeded: true)
    let redo = try #require(try history.beginRedo())
    #expect(redo.command == .tileResize(command))
    try history.finishNavigation(token: redo.token, succeeded: false)
}

@Test
func rasterKeepsItsLayerAndResizeKeepsOneDocumentRevision() throws {
    let raster = makeRasterCommand(bytes: 16)
    let resize = TileResizeHistoryCommand(
        beforePixelSize: PixelSize(width: 64, height: 64),
        afterPixelSize: PixelSize(width: 32, height: 32),
        layerRevision: LayerSurfaceRevisionReference(
            id: StoredRasterRevisionID(rawValue: 10),
            retainedBytes: 16
        )
    )
    let history = DocumentHistory()
    _ = history.appendSuccessful(raster)
    _ = history.appendSuccessful(.layerMetadata(LayerStackMetadataCommand(
        before: LayerStackSnapshot(
            layers: [
                try LayerDescriptor(id: historyLayerID, name: "First"),
                try LayerDescriptor(
                    id: layerIDForHistory(2),
                    name: "Second"
                ),
            ],
            activeLayerID: historyLayerID
        ),
        after: LayerStackSnapshot(
            layers: [
                try LayerDescriptor(
                    id: layerIDForHistory(2),
                    name: "Second"
                ),
                try LayerDescriptor(id: historyLayerID, name: "First"),
            ],
            activeLayerID: layerIDForHistory(2)
        ),
        layerRevision: LayerSurfaceRevisionReference(
            id: StoredRasterRevisionID(rawValue: 12),
            retainedBytes: 0
        )
    )))
    _ = history.appendSuccessful(.tileResize(resize))

    let undoResize = try #require(try history.beginUndo())
    guard case let .tileResize(selectedResize) = undoResize.command else {
        Issue.record("Expected layer-bound resize")
        return
    }
    #expect(selectedResize.layerRevision == resize.layerRevision)
    try history.finishNavigation(token: undoResize.token, succeeded: true)

    let undoMetadata = try #require(try history.beginUndo())
    try history.finishNavigation(token: undoMetadata.token, succeeded: true)
    let undoRaster = try #require(try history.beginUndo())
    guard case let .raster(selectedRaster) = undoRaster.command else {
        Issue.record("Expected layer-bound raster")
        return
    }
    #expect(selectedRaster.layerID == historyLayerID)
}

@Test
func layerDeletionRetainsExactDescriptorOrderFallbackAndRasterRevision()
    throws
{
    let removed = try LayerDescriptor(
        id: layerIDForHistory(7),
        name: "Removed",
        isVisible: false,
        opacity: 0.375,
        isLocked: true,
        blendMode: .screen
    )
    let revision = LayerSurfaceRevisionReference(
        id: StoredRasterRevisionID(rawValue: 77),
        retainedBytes: 512
    )
    let command = LayerDeletionHistoryCommand(
        removedLayer: removed,
        removedOrder: 1,
        activeLayerIDBefore: removed.id,
        activeLayerIDAfter: historyLayerID,
        layerRevision: revision
    )
    let wrapped = DocumentHistoryCommand.layerDeletion(command)

    #expect(command.removedLayer == removed)
    #expect(command.removedOrder == 1)
    #expect(command.activeLayerIDBefore == removed.id)
    #expect(command.activeLayerIDAfter == historyLayerID)
    #expect(command.layerRevision == revision)
    #expect(wrapped.retainedBytes == 512)
    #expect(wrapped.revisionIDs == [revision.id])
}

@Test
func layerDeletionRestoreChecksRetainedRevisionBeforeMetadataMutation()
    throws
{
    let first = try LayerDescriptor(id: historyLayerID, name: "First")
    let removed = try LayerDescriptor(
        id: layerIDForHistory(8),
        name: "Removed"
    )
    var stack = try LayerStack(
        layers: [first, removed],
        activeLayerID: removed.id
    )
    let removal = try stack.delete(removed.id)
    let revision = LayerSurfaceRevisionReference(
        id: StoredRasterRevisionID(rawValue: 88),
        retainedBytes: 128
    )
    let command = LayerDeletionHistoryCommand(
        removal: removal,
        layerRevision: revision
    )
    let afterDeletion = stack

    #expect(throws: LayerDeletionHistoryError.retainedRevisionMissing(
        revision.id
    )) {
        try command.restoreMetadata(
            into: &stack,
            revisionIsAvailable: { _ in false }
        )
    }
    #expect(stack == afterDeletion)

    try command.restoreMetadata(
        into: &stack,
        revisionIsAvailable: { $0 == revision.id }
    )
    #expect(stack.layers == [first, removed])
    #expect(stack.activeLayerID == removed.id)
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

    #expect(!history.canRedo)
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

@Test
func documentEmptinessTracksClearUndoRedoAndPrunedHistory() throws {
    let history = DocumentHistory()
    let draw = makeRasterCommand(seed: 1, kind: .draw, bytes: 16)
    let clear = makeRasterCommand(seed: 2, kind: .clear, bytes: 16)

    #expect(history.currentDocumentIsEmpty)
    _ = history.appendSuccessful(draw)
    #expect(!history.currentDocumentIsEmpty)
    _ = history.appendSuccessful(clear)
    #expect(history.currentDocumentIsEmpty)

    let undoClear = try #require(try history.beginUndo())
    #expect(!undoClear.targetDocumentIsEmpty)
    try history.finishNavigation(token: undoClear.token, succeeded: true)
    #expect(!history.currentDocumentIsEmpty)

    let undoDraw = try #require(try history.beginUndo())
    #expect(undoDraw.targetDocumentIsEmpty)
    try history.finishNavigation(token: undoDraw.token, succeeded: true)
    #expect(history.currentDocumentIsEmpty)

    let redoDraw = try #require(try history.beginRedo())
    #expect(!redoDraw.targetDocumentIsEmpty)
    try history.finishNavigation(token: redoDraw.token, succeeded: true)
    #expect(!history.currentDocumentIsEmpty)

    let imported = DocumentHistory(initialDocumentIsEmpty: false)
    #expect(!imported.currentDocumentIsEmpty)
    _ = imported.appendSuccessful(clear)
    #expect(imported.currentDocumentIsEmpty)
    let restoreImported = try #require(try imported.beginUndo())
    #expect(!restoreImported.targetDocumentIsEmpty)

    let pruned = DocumentHistory(maximumCommands: 0, maximumBytes: 16)
    _ = pruned.appendSuccessful(draw)
    #expect(!pruned.currentDocumentIsEmpty)
    #expect(pruned.commandCount == 0)
}

private func makeRasterCommand(
    seed: UInt64 = 1,
    kind: RasterEditKind = .draw,
    bytes: Int
) -> DocumentHistoryCommand {
    precondition(bytes.isMultiple(of: 2))
    return makeRasterCommand(
        beforeID: seed * 2,
        afterID: seed * 2 + 1,
        kind: kind,
        bytes: bytes
    )
}

private func makeFullRasterReference(
    id: UInt64,
    pixelSize: PixelSize,
    retainedBytes: Int
) -> RasterRevisionReference {
    let regions = PixelRegionSet(
        [
            PixelRect(
                minX: 0,
                minY: 0,
                maxX: pixelSize.width,
                maxY: pixelSize.height
            )!,
        ],
        clippedTo: pixelSize
    )
    return RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: id),
        pixelSize: pixelSize,
        regions: regions,
        retainedBytes: retainedBytes
    )
}

private func makeRasterCommand(
    beforeID: UInt64,
    afterID: UInt64,
    kind: RasterEditKind = .draw,
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
        RasterHistoryCommand(
            layerID: historyLayerID,
            kind: kind,
            before: before,
            after: after
        )
    )
}

private func layerIDForHistory(_ value: Int) -> UUID {
    UUID(uuidString: String(
        format: "00000000-0000-0000-0000-%012d",
        value
    ))!
}
