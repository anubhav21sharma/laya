import EditorCore
import MetalRenderer
import PatternEngine
import Testing

@Test
func sliceThreeHistoryEvidenceRejectsSkippedAppend() {
    let history = SliceThreeHarnessHistory(releaseRasterRevisions: { _ in })

    #expect(
        throws: SliceThreeHarnessHistoryError.commandCount(
            expected: 1,
            actual: 0
        )
    ) {
        try history.validateEvidence(
            expectedCommandCount: 1,
            expectedNavigationFinishCount: 0
        )
    }
}

@Test
func sliceThreeHistoryEvidenceRejectsSkippedNavigationFinalization() throws {
    let history = SliceThreeHarnessHistory(releaseRasterRevisions: { _ in })
    try history.appendRaster(
        kind: .draw,
        receipt: historyReceipt(seed: 1, retainedBytes: 64)
    )
    let pendingUndo = try history.beginUndo()
    _ = try #require(pendingUndo)

    #expect(
        throws: SliceThreeHarnessHistoryError.navigationPending
    ) {
        try history.validateEvidence(
            expectedCommandCount: 1,
            expectedNavigationFinishCount: 1
        )
    }
}

@Test
func sliceThreeHistoryUsesTwoPhaseNavigationAndReleasesDiscardedRedo() throws {
    var released: Set<StoredRasterRevisionID> = []
    let history = SliceThreeHarnessHistory {
        released.formUnion($0)
    }
    let first = historyReceipt(seed: 1, retainedBytes: 64)
    let replacement = historyReceipt(seed: 2, retainedBytes: 96)
    let firstRevisionIDs: Set<StoredRasterRevisionID> = [
        first.before.id,
        first.after.id,
    ]
    try history.appendRaster(kind: .draw, receipt: first)

    let pendingUndo = try history.beginUndo()
    let undo = try #require(pendingUndo)
    #expect(history.evidence.canUndo)
    #expect(!history.evidence.canRedo)
    try history.finishNavigation(token: undo.token, succeeded: true)
    #expect(!history.evidence.canUndo)
    #expect(history.evidence.canRedo)

    try history.appendRaster(kind: .erase, receipt: replacement)
    try history.validateEvidence(
        expectedCommandCount: 1,
        expectedAppendCount: 2,
        expectedNavigationFinishCount: 1
    )
    #expect(history.evidence.retainedRasterBytes == 96)
    #expect(history.evidence.appendCount == 2)
    #expect(history.evidence.releasedRevisionIDs == firstRevisionIDs)
    #expect(released == firstRevisionIDs)
}

private func historyReceipt(
    seed: UInt64,
    retainedBytes: Int
) -> RasterMutationReceipt {
    let size = PixelSize(width: 64, height: 64)
    let regions = PixelRegionSet(
        [PixelRect(minX: 0, minY: 0, maxX: 1, maxY: 1)!],
        clippedTo: size
    )
    let before = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: seed * 2),
        pixelSize: size,
        regions: regions,
        retainedBytes: retainedBytes / 2
    )
    let after = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: seed * 2 + 1),
        pixelSize: size,
        regions: regions,
        retainedBytes: retainedBytes - retainedBytes / 2
    )
    return RasterMutationReceipt(
        token: RendererOperationToken(rawValue: seed),
        before: before,
        after: after
    )
}
