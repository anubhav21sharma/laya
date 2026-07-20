import Foundation

final class GridRenderCompletionMailbox: @unchecked Sendable {
    struct RasterCommit: Sendable {
        let token: RendererOperationToken
        let revisions: PendingRasterRevisionPair
        let captureTokens: [RasterRevisionOperationToken]
    }

    struct Outcome: Sendable {
        let operationToken: RendererOperationToken?
        let rasterCommit: RasterCommit?
        let uploadSubmissions: [DabBufferSubmissionIdentity]
        let succeeded: Bool
        let errorMessage: String?
    }

    private let lock = NSLock()
    private var outcomes: [Outcome] = []

    func push(_ outcome: Outcome) {
        lock.lock()
        outcomes.append(outcome)
        lock.unlock()
    }

    @MainActor
    func drain() -> [Outcome] {
        lock.lock()
        let result = outcomes
        outcomes.removeAll(keepingCapacity: true)
        lock.unlock()
        return result
    }
}
