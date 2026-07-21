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
    private var deferredOutcomes: [Outcome] = []
    private var shouldDeferNextOutcome = false

    func push(_ outcome: Outcome) {
        lock.lock()
        if shouldDeferNextOutcome {
            deferredOutcomes.append(outcome)
            shouldDeferNextOutcome = false
        } else {
            outcomes.append(outcome)
        }
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

    @MainActor
    func drainFirstForHarness() -> Outcome? {
        lock.lock()
        let result = outcomes.isEmpty ? nil : outcomes.removeFirst()
        lock.unlock()
        return result
    }

    @MainActor
    func prioritizeLastForHarness() {
        lock.lock()
        if outcomes.count > 1 {
            outcomes.insert(outcomes.removeLast(), at: 0)
        }
        lock.unlock()
    }

    @MainActor
    func deferNextForHarness() {
        lock.lock()
        precondition(
            !shouldDeferNextOutcome,
            "A frame outcome is already deferred for the harness."
        )
        shouldDeferNextOutcome = true
        lock.unlock()
    }

    @MainActor
    func releaseDeferredForHarness() {
        lock.lock()
        shouldDeferNextOutcome = false
        outcomes.append(contentsOf: deferredOutcomes)
        deferredOutcomes.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
