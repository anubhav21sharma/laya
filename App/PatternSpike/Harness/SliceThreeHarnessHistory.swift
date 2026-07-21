import EditorCore
import Foundation
import MetalRenderer
import PatternEngine

struct SliceThreeHarnessHistoryEvidence: Equatable, Sendable {
    let commandCount: Int
    let retainedRasterBytes: Int
    let canUndo: Bool
    let canRedo: Bool
    let appendCount: Int
    let navigationFinishCount: Int
    let releasedRevisionIDs: Set<StoredRasterRevisionID>
    let navigationPending: Bool
}

enum SliceThreeHarnessHistoryError: Error, Equatable, LocalizedError {
    case commandCount(expected: Int, actual: Int)
    case appendCount(expected: Int, actual: Int)
    case navigationFinishCount(expected: Int, actual: Int)
    case canUndo(expected: Bool, actual: Bool)
    case canRedo(expected: Bool, actual: Bool)
    case navigationPending

    var errorDescription: String? {
        switch self {
        case let .commandCount(expected, actual):
            "Slice 3 history command count expected \(expected), actual \(actual)."
        case let .appendCount(expected, actual):
            "Slice 3 history append count expected \(expected), actual \(actual)."
        case let .navigationFinishCount(expected, actual):
            "Slice 3 history navigation finish count expected \(expected), actual \(actual)."
        case let .canUndo(expected, actual):
            "Slice 3 history canUndo expected \(expected), actual \(actual)."
        case let .canRedo(expected, actual):
            "Slice 3 history canRedo expected \(expected), actual \(actual)."
        case .navigationPending:
            "Slice 3 history navigation is still pending."
        }
    }
}

final class SliceThreeHarnessHistory {
    private let history: DocumentHistory
    private let releaseRasterRevisions: (Set<StoredRasterRevisionID>) -> Void
    private var appendCount = 0
    private var navigationFinishCount = 0
    private var releasedRevisionIDs: Set<StoredRasterRevisionID> = []
    private var pendingNavigationToken: UInt64?

    init(
        maximumCommands: Int = 100,
        maximumBytes: Int = 200 * 1_024 * 1_024,
        releaseRasterRevisions: @escaping (
            Set<StoredRasterRevisionID>
        ) -> Void
    ) {
        history = DocumentHistory(
            maximumCommands: maximumCommands,
            maximumBytes: maximumBytes
        )
        self.releaseRasterRevisions = releaseRasterRevisions
    }

    var maximumBytes: Int { history.maximumBytes }

    var evidence: SliceThreeHarnessHistoryEvidence {
        SliceThreeHarnessHistoryEvidence(
            commandCount: history.commandCount,
            retainedRasterBytes: history.retainedRasterBytes,
            canUndo: history.canUndo,
            canRedo: history.canRedo,
            appendCount: appendCount,
            navigationFinishCount: navigationFinishCount,
            releasedRevisionIDs: releasedRevisionIDs,
            navigationPending: pendingNavigationToken != nil
        )
    }

    func appendRaster(
        kind: RasterEditKind,
        receipt: RasterMutationReceipt
    ) throws {
        try append(
            .raster(
                RasterHistoryCommand(
                    kind: kind,
                    before: receipt.before,
                    after: receipt.after
                )
            )
        )
    }

    func appendResize(receipt: RasterMutationReceipt) throws {
        try append(
            .tileResize(
                TileResizeHistoryCommand(
                    before: receipt.before,
                    after: receipt.after
                )
            )
        )
    }

    func appendTiling(before: TilingKind, after: TilingKind) throws {
        try append(.tiling(MetadataChange(before: before, after: after)))
    }

    func beginUndo() throws -> HistoryNavigation? {
        let navigation = try history.beginUndo()
        pendingNavigationToken = navigation?.token
        return navigation
    }

    func beginRedo() throws -> HistoryNavigation? {
        let navigation = try history.beginRedo()
        pendingNavigationToken = navigation?.token
        return navigation
    }

    func finishNavigation(token: UInt64, succeeded: Bool) throws {
        try history.finishNavigation(token: token, succeeded: succeeded)
        pendingNavigationToken = nil
        navigationFinishCount += 1
    }

    func validateEvidence(
        expectedCommandCount: Int,
        expectedAppendCount: Int? = nil,
        expectedNavigationFinishCount: Int,
        expectedCanUndo: Bool = true,
        expectedCanRedo: Bool = false
    ) throws {
        let evidence = evidence
        guard !evidence.navigationPending else {
            throw SliceThreeHarnessHistoryError.navigationPending
        }
        guard evidence.commandCount == expectedCommandCount else {
            throw SliceThreeHarnessHistoryError.commandCount(
                expected: expectedCommandCount,
                actual: evidence.commandCount
            )
        }
        let appendExpectation = expectedAppendCount ?? expectedCommandCount
        guard evidence.appendCount == appendExpectation else {
            throw SliceThreeHarnessHistoryError.appendCount(
                expected: appendExpectation,
                actual: evidence.appendCount
            )
        }
        guard evidence.navigationFinishCount
                == expectedNavigationFinishCount
        else {
            throw SliceThreeHarnessHistoryError.navigationFinishCount(
                expected: expectedNavigationFinishCount,
                actual: evidence.navigationFinishCount
            )
        }
        guard evidence.canUndo == expectedCanUndo else {
            throw SliceThreeHarnessHistoryError.canUndo(
                expected: expectedCanUndo,
                actual: evidence.canUndo
            )
        }
        guard evidence.canRedo == expectedCanRedo else {
            throw SliceThreeHarnessHistoryError.canRedo(
                expected: expectedCanRedo,
                actual: evidence.canRedo
            )
        }
    }

    private func append(_ command: DocumentHistoryCommand) throws {
        try history.validateNewCommand(retainedBytes: command.retainedBytes)
        let released = history.appendSuccessful(command)
        appendCount += 1
        guard !released.isEmpty else { return }
        releasedRevisionIDs.formUnion(released)
        releaseRasterRevisions(released)
    }
}
