import Foundation
import PatternEngine
import os

enum StrokeInputCancellationReason: Equatable, Sendable {
    case authoritativeCapacityExceeded(
        current: Int,
        incoming: Int,
        maximum: Int
    )
}

enum StrokeInputMessage: Equatable, Sendable {
    case begin(
        generation: UInt64,
        configuration: StrokePreparationConfiguration,
        samples: [StrokeSample]
    )
    case appendAuthoritative(
        generation: UInt64,
        samples: [StrokeSample]
    )
    case appendAuthoritativeSample(
        generation: UInt64,
        sample: StrokeSample
    )
    case finish(
        generation: UInt64,
        samples: [StrokeSample]
    )
    case replacePrediction(
        generation: UInt64,
        samples: [StrokeSample],
        acceptedCount: Int
    )
    case replacePredictionBatchSample(
        generation: UInt64,
        sample: StrokeSample,
        index: Int,
        count: Int,
        submittedCount: Int
    )
    case replacePredictionSample(
        generation: UInt64,
        sample: StrokeSample
    )
    case applyEstimatedUpdate(
        generation: UInt64,
        sample: StrokeSample
    )
    case commit(generation: UInt64)
    case cancel(
        generation: UInt64,
        reason: StrokeInputCancellationReason?
    )

    var generation: UInt64 {
        switch self {
        case let .begin(generation, _, _),
             let .appendAuthoritative(generation, _),
             let .appendAuthoritativeSample(generation, _),
             let .finish(generation, _),
             let .replacePrediction(generation, _, _),
             let .replacePredictionBatchSample(generation, _, _, _, _),
             let .replacePredictionSample(generation, _),
             let .applyEstimatedUpdate(generation, _),
             let .commit(generation),
             let .cancel(generation, _):
            generation
        }
    }
}

enum StrokeInputQueueError: Error, Equatable, Sendable {
    case invalidCapacity(Int)
    case authoritativeCapacityExceeded(
        generation: UInt64,
        current: Int,
        incoming: Int,
        maximum: Int
    )
}

struct StrokeInputAdmission: Equatable, Sendable {
    let acceptedPredictionSampleCount: Int
    let shedPredictionSampleCount: Int

    static let authoritative = StrokeInputAdmission(
        acceptedPredictionSampleCount: 0,
        shedPredictionSampleCount: 0
    )
}

struct StrokeInputQueueSnapshot: Equatable, Sendable {
    let authoritativePendingSampleCount: Int
    let predictedPendingSampleCount: Int
    let hasPendingInput: Bool
    let authoritativeHighWater: Int
    let predictedHighWater: Int
    let authoritativeCapacity: Int
    let predictionCapacity: Int
    let authoritativeStorageCapacity: Int
    let predictionStorageCapacity: Int
    let cancelledGeneration: UInt64?
}

/// Fixed-storage input admission owned by the stroke worker. Authoritative
/// occupancy is charged by normalized sample, even when callers submit a
/// batch in one immutable message, so batching cannot bypass the bound.
struct StrokeInputQueue: Sendable {
    var snapshot: StrokeInputQueueSnapshot {
        StrokeInputQueueSnapshot(
            authoritativePendingSampleCount: authoritativeSampleCount,
            predictedPendingSampleCount: predictedSampleCount,
            hasPendingInput: pendingCancellation != nil
                || !authoritative.isEmpty
                || !prediction.isEmpty,
            authoritativeHighWater: authoritativeHighWater,
            predictedHighWater: predictedHighWater,
            authoritativeCapacity: authoritativeCapacity,
            predictionCapacity: predictionCapacity,
            authoritativeStorageCapacity: authoritative.storageCapacity,
            predictionStorageCapacity: prediction.storageCapacity,
            cancelledGeneration: cancelledGeneration
        )
    }

    private let authoritativeCapacity: Int
    private let predictionCapacity: Int
    private var authoritative: MessageRing
    private var prediction: MessageRing
    private var authoritativeSampleCount = 0
    private var predictedSampleCount = 0
    private var authoritativeHighWater = 0
    private var predictedHighWater = 0
    private var nextSequence: UInt64 = 1
    private var pendingCancellation: StrokeInputMessage?
    private var cancelledGeneration: UInt64?

    init(budget: DepositionFrameBudget) {
        // The authoritative descriptor/sample capacity is the same hard bound
        // as projected authoritative carry. Prediction has its independent,
        // route-independent Task 6 sample cap and is replaceable.
        try! self.init(
            authoritativeCapacity:
                budget.maximumPendingAuthoritativeInstances,
            predictionCapacity:
                PredictionOverlay.maximumNormalizedSampleCount
        )
    }

    init(
        authoritativeCapacity: Int,
        predictionCapacity: Int
    ) throws {
        guard authoritativeCapacity > 0 else {
            throw StrokeInputQueueError.invalidCapacity(
                authoritativeCapacity
            )
        }
        guard predictionCapacity > 0 else {
            throw StrokeInputQueueError.invalidCapacity(predictionCapacity)
        }
        self.authoritativeCapacity = authoritativeCapacity
        self.predictionCapacity = predictionCapacity
        // Control messages have a dedicated slot. A full authoritative sample
        // queue must still be able to accept the ordered finish/commit barrier;
        // barrier admission never consumes or evicts authoritative samples.
        authoritative = MessageRing(capacity: authoritativeCapacity + 1)
        prediction = MessageRing(capacity: predictionCapacity)
    }

    @discardableResult
    mutating func enqueue(
        _ message: StrokeInputMessage
    ) throws -> StrokeInputAdmission {
        switch message {
        case let .begin(generation, _, samples),
             let .appendAuthoritative(generation, samples),
             let .finish(generation, samples):
            guard samples.count
                <= authoritativeCapacity - authoritativeSampleCount
            else {
                let current = authoritativeSampleCount
                cancelForCapacityFailure(
                    generation: generation,
                    current: current,
                    incoming: samples.count
                )
                throw StrokeInputQueueError.authoritativeCapacityExceeded(
                    generation: generation,
                    current: current,
                    incoming: samples.count,
                    maximum: authoritativeCapacity
                )
            }
            guard !samples.isEmpty else { return .authoritative }
            authoritative.append(
                QueuedMessage(sequence: takeSequence(), message: message)
            )
            authoritativeSampleCount += samples.count
            authoritativeHighWater = max(
                authoritativeHighWater,
                authoritativeSampleCount
            )
            return .authoritative

        case let .appendAuthoritativeSample(generation, sample):
            guard authoritativeSampleCount < authoritativeCapacity else {
                let current = authoritativeSampleCount
                cancelForCapacityFailure(
                    generation: generation,
                    current: current,
                    incoming: 1
                )
                throw StrokeInputQueueError.authoritativeCapacityExceeded(
                    generation: generation,
                    current: current,
                    incoming: 1,
                    maximum: authoritativeCapacity
                )
            }
            authoritative.append(
                QueuedMessage(
                    sequence: takeSequence(),
                    message: .appendAuthoritativeSample(
                        generation: generation,
                        sample: sample
                    )
                )
            )
            authoritativeSampleCount += 1
            authoritativeHighWater = max(
                authoritativeHighWater,
                authoritativeSampleCount
            )
            return .authoritative

        case let .applyEstimatedUpdate(generation, sample):
            guard authoritativeSampleCount < authoritativeCapacity else {
                let current = authoritativeSampleCount
                cancelForCapacityFailure(
                    generation: generation,
                    current: current,
                    incoming: 1
                )
                throw StrokeInputQueueError.authoritativeCapacityExceeded(
                    generation: generation,
                    current: current,
                    incoming: 1,
                    maximum: authoritativeCapacity
                )
            }
            authoritative.append(
                QueuedMessage(
                    sequence: takeSequence(),
                    message: .applyEstimatedUpdate(
                        generation: generation,
                        sample: sample
                    )
                )
            )
            authoritativeSampleCount += 1
            authoritativeHighWater = max(
                authoritativeHighWater,
                authoritativeSampleCount
            )
            return .authoritative

        case let .replacePrediction(
            generation,
            samples,
            requestedCount
        ):
            let submittedCount = max(samples.count, requestedCount)
            let acceptedCount = max(
                0,
                min(
                    samples.count,
                    requestedCount,
                    predictionCapacity
                )
            )
            prediction.reset()
            predictedSampleCount = 0
            if acceptedCount > 0 {
                for index in 0..<acceptedCount {
                    prediction.append(
                        QueuedMessage(
                            sequence: takeSequence(),
                            message: .replacePredictionBatchSample(
                                generation: generation,
                                sample: samples[index],
                                index: index,
                                count: acceptedCount,
                                submittedCount: submittedCount
                            )
                        )
                    )
                }
                predictedSampleCount = acceptedCount
                predictedHighWater = max(
                    predictedHighWater,
                    predictedSampleCount
                )
            } else {
                // Preserve the semantic replacement with an empty, static
                // payload without retaining the caller's potentially large
                // array when its requested prefix is empty.
                prediction.append(
                    QueuedMessage(
                        sequence: takeSequence(),
                        message: .replacePrediction(
                            generation: generation,
                            samples: [],
                            acceptedCount: 0
                        )
                    )
                )
            }
            return StrokeInputAdmission(
                acceptedPredictionSampleCount: acceptedCount,
                shedPredictionSampleCount: submittedCount - acceptedCount
            )

        case .replacePredictionBatchSample:
            preconditionFailure(
                "Prediction batch parts are owned by StrokeInputQueue"
            )

        case let .replacePredictionSample(generation, sample):
            prediction.reset()
            prediction.append(
                QueuedMessage(
                    sequence: takeSequence(),
                    message: .replacePredictionSample(
                        generation: generation,
                        sample: sample
                    )
                )
            )
            predictedSampleCount = 1
            predictedHighWater = max(predictedHighWater, 1)
            return StrokeInputAdmission(
                acceptedPredictionSampleCount: 1,
                shedPredictionSampleCount: 0
            )

        case .commit:
            authoritative.append(
                QueuedMessage(sequence: takeSequence(), message: message)
            )
            return .authoritative

        case let .cancel(generation, reason):
            authoritative.reset()
            prediction.reset()
            authoritativeSampleCount = 0
            predictedSampleCount = 0
            cancelledGeneration = generation
            pendingCancellation = .cancel(
                generation: generation,
                reason: reason
            )
            return .authoritative
        }
    }

    mutating func dequeue() -> StrokeInputMessage? {
        if let pendingCancellation {
            self.pendingCancellation = nil
            return pendingCancellation
        }
        switch (authoritative.first, prediction.first) {
        case (nil, nil):
            return nil
        case let (authoritative?, nil):
            return removeAuthoritative(authoritative)
        case let (nil, prediction?):
            return removePrediction(prediction)
        case let (authoritative?, prediction?):
            if authoritative.sequence < prediction.sequence {
                return removeAuthoritative(authoritative)
            }
            return removePrediction(prediction)
        }
    }

    private mutating func removeAuthoritative(
        _ queued: QueuedMessage
    ) -> StrokeInputMessage {
        _ = authoritative.removeFirst()
        switch queued.message {
        case let .begin(_, _, samples),
             let .appendAuthoritative(_, samples),
             let .finish(_, samples):
            authoritativeSampleCount -= samples.count
        case .appendAuthoritativeSample,
             .applyEstimatedUpdate:
            authoritativeSampleCount -= 1
        case .commit:
            break
        case .replacePrediction,
             .replacePredictionBatchSample,
             .replacePredictionSample,
             .cancel:
            preconditionFailure("Invalid authoritative input queue payload")
        }
        return queued.message
    }

    private mutating func removePrediction(
        _ queued: QueuedMessage
    ) -> StrokeInputMessage {
        _ = prediction.removeFirst()
        switch queued.message {
        case let .replacePrediction(_, _, acceptedCount):
            predictedSampleCount -= acceptedCount
        case .replacePredictionBatchSample,
             .replacePredictionSample:
            predictedSampleCount -= 1
        default:
            preconditionFailure("Invalid prediction input queue payload")
        }
        return queued.message
    }

    private mutating func cancelForCapacityFailure(
        generation: UInt64,
        current: Int,
        incoming: Int
    ) {
        authoritative.reset()
        prediction.reset()
        authoritativeSampleCount = 0
        predictedSampleCount = 0
        cancelledGeneration = generation
        pendingCancellation = .cancel(
            generation: generation,
            reason: .authoritativeCapacityExceeded(
                current: current,
                incoming: incoming,
                maximum: authoritativeCapacity
            )
        )
    }

    private mutating func takeSequence() -> UInt64 {
        let sequence = nextSequence
        let (successor, overflow) = sequence.addingReportingOverflow(1)
        precondition(!overflow, "Stroke input sequence exhausted")
        nextSequence = successor
        return sequence
    }
}

private struct QueuedMessage: Equatable, Sendable {
    let sequence: UInt64
    let message: StrokeInputMessage
}

private struct MessageRing: Sendable {
    var first: QueuedMessage? {
        guard count > 0 else { return nil }
        return storage[head]
    }

    var storageCapacity: Int { storage.capacity }
    var isEmpty: Bool { count == 0 }

    private let capacity: Int
    private var storage: ContiguousArray<QueuedMessage?>
    private var head = 0
    private var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = ContiguousArray(repeating: nil, count: capacity)
    }

    mutating func append(_ message: QueuedMessage) {
        precondition(count < capacity)
        storage[(head + count) % capacity] = message
        count += 1
    }

    mutating func removeFirst() -> QueuedMessage {
        precondition(count > 0)
        let message = storage[head]!
        storage[head] = nil
        head = (head + 1) % capacity
        count -= 1
        if count == 0 { head = 0 }
        return message
    }

    mutating func reset() {
        for offset in 0..<count {
            storage[(head + offset) % capacity] = nil
        }
        head = 0
        count = 0
    }
}

enum StrokePreparationFailure: Error, Equatable, Sendable {
    case coordinator(StrokeRenderCoordinatorError)
    case cornerEmission(BrushCornerEmitterError)
    case authoritativeQueue(AuthoritativeStrokeQueueError)
    case scheduler(StrokeFrameSchedulerError)
    case stampPacking(DepositionStampPackingError)
    case privateSurfaceEncoding(StrokePrivateSurfaceEncodingError)
    case transientBuffer(TransientStrokeBufferError)
    case dabArenaCapacityExceeded(actual: Int, maximum: Int)
    case unexpected(String)
}

enum StrokePreparationCapacityFailure: Error, Equatable, Sendable {
    case strokeSamples(actual: Int, maximum: Int)
    case generatedDabs(actual: Int, maximum: Int)
    case projectedInstances(actual: Int, maximum: Int)
}

enum StrokePreparationResult: Sendable {
    case prepared(StrokePreparedDepositionBatch)
    case predictionWasShed(
        generation: UInt64,
        acceptedSampleCount: Int,
        shedSampleCount: Int
    )
    case estimatedUpdateWasIgnored(
        generation: UInt64,
        error: TransientStrokeBufferError
    )
    case estimatedUpdateWasRejected(
        generation: UInt64,
        error: TransientStrokeBufferError,
        capacityFailure: StrokePreparationCapacityFailure?
    )
    case commitBarrierReached(generation: UInt64)
    case cancelled(
        generation: UInt64,
        reason: StrokeInputCancellationReason?
    )
    case failed(generation: UInt64, failure: StrokePreparationFailure)

    var generation: UInt64 {
        switch self {
        case let .prepared(batch):
            batch.generation
        case let .predictionWasShed(generation, _, _),
             let .estimatedUpdateWasIgnored(generation, _),
             let .estimatedUpdateWasRejected(generation, _, _),
             let .commitBarrierReached(generation),
             let .cancelled(generation, _),
             let .failed(generation, _):
            generation
        }
    }
}

struct StrokePreparationMailboxSnapshot: Equatable, Sendable {
    let input: StrokeInputQueueSnapshot
    let pendingResultCount: Int
    let resultCapacity: Int
    let resultStorageCapacity: Int
    let resultHighWater: Int
    let awaitingPreparedFrameSubmission: Bool
    let workerIsProcessing: Bool
    let maximumPreparedRecordCount: Int
    let maximumPreparedLogicalDabCount: Int
    let maximumPreparedPayloadBytes: Int
    let terminalCancellationPublicationCount: UInt64
    let workerTaskPriority: TaskPriority?

    var isQuiescent: Bool {
        !input.hasPendingInput
            && pendingResultCount == 0
            && !awaitingPreparedFrameSubmission
            && !workerIsProcessing
    }
}

enum StrokePreparationAcknowledgementError: Error, Equatable, Sendable {
    case noPreparedFrame
    case invalidPreparedFrame(
        expectedGeneration: UInt64,
        expectedToken: UInt64,
        actualGeneration: UInt64,
        actualToken: UInt64
    )
    case acknowledgementAlreadyPending
}

enum StrokePreparationCancellationFrameDisposition: Equatable, Sendable {
    /// A drained prepared frame is still borrowed by Main or submitted to the
    /// GPU. Cancellation must wait for Main to acknowledge that exact lease.
    case preserveMainOwnership
    /// Main drained the immutable result but never installed or submitted its
    /// lease. The mailbox may return that abandoned frame to the actor before
    /// it processes the terminal cancellation.
    case abandonedBeforeSubmission
}

/// Causal wake-up used by synchronous capture drains. The production input
/// path never waits on this condition; it only records actor/mailbox progress.
package final class StrokePreparationProgressWaiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var revision: UInt64 = 0

    var currentRevision: UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return revision
    }

    func recordProgress() {
        condition.lock()
        revision &+= 1
        condition.broadcast()
        condition.unlock()
    }

    func waitForProgress(
        after observedRevision: UInt64,
        until deadline: Date
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while revision == observedRevision {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}

/// Owns the exact mailbox/waiter pairing installed by a harness drain. The
/// renderer can retire and clear its active bridge while the drain is still
/// unwinding, so removal must not rediscover the mailbox through renderer
/// state.
package final class StrokePreparationProgressRegistration {
    private let mailbox: StrokePreparationMailbox
    private let waiter: StrokePreparationProgressWaiter

    init(mailbox: StrokePreparationMailbox) {
        self.mailbox = mailbox
        waiter = mailbox.installProgressWaiterForHarness()
    }

    package var currentRevision: UInt64 {
        waiter.currentRevision
    }

    package func waitForProgress(
        after observedRevision: UInt64,
        until deadline: Date
    ) -> Bool {
        waiter.waitForProgress(
            after: observedRevision,
            until: deadline
        )
    }

    package func remove() {
        mailbox.removeProgressWaiterForHarness(waiter)
    }
}

/// Optional production-side async wake-up for scripted/headless completion.
/// Interactive input does not install this registration, so the hot mailbox
/// path remains a nil check with no task or continuation allocation.
package final class StrokePreparationAsyncProgressRegistration:
    @unchecked Sendable
{
    private enum Signal: Sendable {
        case progress
        case timedOut(observedRevision: UInt64)
    }

    private let mailbox: StrokePreparationMailbox
    private let continuation: AsyncStream<Signal>.Continuation
    private var iterator: AsyncStream<Signal>.Iterator

    init(mailbox: StrokePreparationMailbox) {
        let pair = AsyncStream<Signal>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.mailbox = mailbox
        continuation = pair.continuation
        iterator = pair.stream.makeAsyncIterator()
        mailbox.installAsyncProgressRegistration(self)
    }

    package var currentRevision: UInt64 {
        mailbox.currentProgressRevision
    }

    fileprivate func recordProgress() {
        continuation.yield(.progress)
    }

    /// Waits for progress after an exact mailbox revision. Timeout delivery
    /// can itself be delayed by executor pressure, so every wake rechecks the
    /// authoritative revision before interpreting the signal. This preserves
    /// the bound without allowing a late timeout to overwrite real progress
    /// in the newest-one stream.
    package func waitForProgress(
        after observedRevision: UInt64,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws -> Bool {
        if currentRevision != observedRevision { return true }

        let continuation = continuation
        let timeoutTask = Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                continuation.yield(
                    .timedOut(observedRevision: observedRevision)
                )
            } catch {
                return
            }
        }
        defer { timeoutTask.cancel() }

        while true {
            if Task.isCancelled { throw CancellationError() }
            if currentRevision != observedRevision { return true }
            guard let signal = await iterator.next() else {
                throw CancellationError()
            }
            if currentRevision != observedRevision { return true }
            switch signal {
            case .progress:
                // A buffered progress signal from an earlier revision is not
                // evidence for this wait. Its own timeout remains active.
                continue
            case let .timedOut(signalRevision):
                guard signalRevision == observedRevision else { continue }
                return false
            }
        }
    }

    package func recordTimeoutForTesting(after observedRevision: UInt64) {
        continuation.yield(
            .timedOut(observedRevision: observedRevision)
        )
    }

    package func remove() {
        mailbox.removeAsyncProgressRegistration(self)
        continuation.finish()
    }
}

/// Cross-executor transport only. The mutex protects bounded immutable-value
/// messages and results; it never encloses renderer, view, or Metal objects.
final class StrokePreparationMailbox: Sendable {
    var snapshot: StrokePreparationMailboxSnapshot {
        state.withLock { state in
            StrokePreparationMailboxSnapshot(
                input: state.input.snapshot,
                pendingResultCount: state.results.count,
                resultCapacity: state.results.capacity,
                resultStorageCapacity: state.results.storageCapacity,
                resultHighWater: state.resultHighWater,
                awaitingPreparedFrameSubmission:
                    state.awaitingFrame != nil,
                workerIsProcessing: state.workerIsProcessing,
                maximumPreparedRecordCount:
                    state.maximumPreparedRecordCount,
                maximumPreparedLogicalDabCount:
                    state.maximumPreparedLogicalDabCount,
                maximumPreparedPayloadBytes:
                    state.maximumPreparedPayloadBytes,
                terminalCancellationPublicationCount:
                    state.terminalCancellationPublicationCount,
                workerTaskPriority: state.workerTaskPriority
            )
        }
    }

    private struct State: Sendable {
        var input: StrokeInputQueue
        var results: StrokeResultRing
        var resultHighWater = 0
        var awaitingFrame: PreparedFrameIdentity?
        var pendingAcknowledgement: PreparedFrameIdentity?
        var acknowledgementInFlight: PreparedFrameIdentity?
        var workerIsProcessing = false
        var discardedGeneration: UInt64?
        var terminalCancellationPublicationCount: UInt64 = 0
        var progressRevision: UInt64 = 0
        var progressWaiter: StrokePreparationProgressWaiter?
        var asyncProgressRegistration:
            StrokePreparationAsyncProgressRegistration?
        var workerTaskPriority: TaskPriority?
        let maximumPreparedRecordCount: Int
        let maximumPreparedLogicalDabCount: Int
        let maximumPreparedPayloadBytes: Int
    }

    private struct PreparedFrameIdentity: Equatable, Sendable {
        let generation: UInt64
        let token: UInt64
    }

    private let state: OSAllocatedUnfairLock<State>
    /// Harness drains borrow this waiter only while they need a causal
    /// boundary. Keeping the synchronization storage with the warmed mailbox
    /// avoids allocating a condition object on every capture-frame flush.
    private let harnessProgressWaiter = StrokePreparationProgressWaiter()

    var currentProgressRevision: UInt64 {
        state.withLock { $0.progressRevision }
    }

    init(budget: DepositionFrameBudget) {
        let maximumPreparedRecordCount = max(
            budget.maximumAuthoritativeInstances,
            budget.maximumPredictedInstances
        )
        let maximumPreparedLogicalDabCount =
            TransientStrokeBufferContract.wholeStrokeDabCapacity
        let maximumPreparedPayloadBytes =
            maximumPreparedRecordCount * MemoryLayout<PixelRect>.stride
                + maximumPreparedLogicalDabCount
                    * MemoryLayout<LogicalDab>.stride
        state = OSAllocatedUnfairLock(
            initialState: State(
                input: StrokeInputQueue(budget: budget),
                // One immutable preparation payload may be borrowed by Main
                // at a time. Further samples stay in their bounded input rings
                // until that payload is delivered.
                results: StrokeResultRing(capacity: 1),
                progressWaiter: nil,
                maximumPreparedRecordCount: maximumPreparedRecordCount,
                maximumPreparedLogicalDabCount:
                    maximumPreparedLogicalDabCount,
                maximumPreparedPayloadBytes: maximumPreparedPayloadBytes
            )
        )
    }

    @discardableResult
    func submit(
        _ message: StrokeInputMessage
    ) throws -> StrokeInputAdmission {
        try submit(
            message,
            cancellationFrameDisposition: .preserveMainOwnership
        )
    }

    @discardableResult
    func submitCancellation(
        generation: UInt64,
        reason: StrokeInputCancellationReason?,
        frameDisposition: StrokePreparationCancellationFrameDisposition
    ) throws -> StrokeInputAdmission {
        try submit(
            .cancel(generation: generation, reason: reason),
            cancellationFrameDisposition: frameDisposition
        )
    }

    private func submit(
        _ message: StrokeInputMessage,
        cancellationFrameDisposition:
            StrokePreparationCancellationFrameDisposition
    ) throws -> StrokeInputAdmission {
        try state.withLock { state in
            let admission = try state.input.enqueue(message)
            if case let .cancel(generation, _) = message {
                state.discardedGeneration = generation
                if let awaiting = state.awaitingFrame,
                   (state.results.count > 0
                    || cancellationFrameDisposition
                        == .abandonedBeforeSubmission)
                {
                    if state.pendingAcknowledgement == nil,
                       state.acknowledgementInFlight != awaiting
                    {
                        state.pendingAcknowledgement = awaiting
                    }
                }
                state.results.reset()
            }
            return admission
        }
    }

    func takeInput() -> StrokeInputMessage? {
        state.withLock { state in
            guard state.results.count == 0,
                  state.awaitingFrame == nil,
                  state.pendingAcknowledgement == nil,
                  !state.workerIsProcessing
            else { return nil }
            guard let message = state.input.dequeue() else { return nil }
            state.workerIsProcessing = true
            return message
        }
    }

    func acknowledgePreparedFrame(
        generation: UInt64,
        token: UInt64
    ) throws {
        try state.withLock { state in
            guard let awaiting = state.awaitingFrame else {
                throw StrokePreparationAcknowledgementError.noPreparedFrame
            }
            let actual = PreparedFrameIdentity(
                generation: generation,
                token: token
            )
            guard awaiting == actual else {
                throw StrokePreparationAcknowledgementError
                    .invalidPreparedFrame(
                        expectedGeneration: awaiting.generation,
                        expectedToken: awaiting.token,
                        actualGeneration: generation,
                        actualToken: token
                    )
            }
            guard state.pendingAcknowledgement == nil,
                  state.acknowledgementInFlight == nil
            else {
                throw StrokePreparationAcknowledgementError
                    .acknowledgementAlreadyPending
            }
            state.pendingAcknowledgement = actual
        }
    }

    func takePreparedFrameAcknowledgement()
        -> (generation: UInt64, token: UInt64)?
    {
        state.withLock { state in
            guard !state.workerIsProcessing,
                  let acknowledgement = state.pendingAcknowledgement,
                  state.acknowledgementInFlight == nil
            else {
                return nil
            }
            state.workerIsProcessing = true
            state.pendingAcknowledgement = nil
            state.acknowledgementInFlight = acknowledgement
            return (acknowledgement.generation, acknowledgement.token)
        }
    }

    func completePreparedFrameAcknowledgement(
        generation: UInt64,
        token: UInt64
    ) {
        let progressObservers = state.withLock { state in
            let identity = PreparedFrameIdentity(
                generation: generation,
                token: token
            )
            precondition(
                state.awaitingFrame == identity
                    && state.acknowledgementInFlight == identity
            )
            state.awaitingFrame = nil
            state.acknowledgementInFlight = nil
            state.progressRevision &+= 1
            return (
                state.progressWaiter,
                state.asyncProgressRegistration
            )
        }
        progressObservers.0?.recordProgress()
        progressObservers.1?.recordProgress()
    }

    func publish(_ result: StrokePreparationResult) {
        let progressObservers = state.withLock { state in
            if state.discardedGeneration == result.generation {
                if case .cancelled = result {
                    state.discardedGeneration = nil
                    state.terminalCancellationPublicationCount &+= 1
                    state.results.append(result)
                    state.resultHighWater = max(
                        state.resultHighWater,
                        state.results.count
                    )
                    state.progressRevision &+= 1
                    return (
                        state.progressWaiter,
                        state.asyncProgressRegistration
                    )
                }
                if case let .prepared(batch) = result,
                   let token = batch.frameToken
                {
                    let identity = PreparedFrameIdentity(
                        generation: batch.generation,
                        token: token
                    )
                    precondition(state.awaitingFrame == nil)
                    state.awaitingFrame = identity
                    state.pendingAcknowledgement = identity
                }
                state.progressRevision &+= 1
                return (
                    state.progressWaiter,
                    state.asyncProgressRegistration
                )
            }
            precondition(
                state.results.count < state.results.capacity,
                "Bounded stroke result mailbox overflow"
            )
            state.results.append(result)
            if case let .prepared(batch) = result,
               let token = batch.frameToken
            {
                precondition(
                    batch.dirtyRegions.count
                        <= state.maximumPreparedRecordCount
                )
                precondition(
                    batch.logicalDabs.count
                        <= state.maximumPreparedLogicalDabCount
                )
                precondition(state.awaitingFrame == nil)
                state.awaitingFrame = PreparedFrameIdentity(
                    generation: batch.generation,
                    token: token
                )
            }
            state.resultHighWater = max(
                state.resultHighWater,
                state.results.count
            )
            state.progressRevision &+= 1
            return (
                state.progressWaiter,
                state.asyncProgressRegistration
            )
        }
        progressObservers.0?.recordProgress()
        progressObservers.1?.recordProgress()
    }

    func completeWorkerOperation() {
        let progressObservers = state.withLock { state in
            precondition(state.workerIsProcessing)
            state.workerIsProcessing = false
            state.progressRevision &+= 1
            return (
                state.progressWaiter,
                state.asyncProgressRegistration
            )
        }
        progressObservers.0?.recordProgress()
        progressObservers.1?.recordProgress()
    }

    func installProgressWaiterForHarness()
        -> StrokePreparationProgressWaiter
    {
        state.withLock { state in
            precondition(state.progressWaiter == nil)
            state.progressWaiter = harnessProgressWaiter
            return harnessProgressWaiter
        }
    }

    func removeProgressWaiterForHarness(
        _ waiter: StrokePreparationProgressWaiter
    ) {
        state.withLock { state in
            precondition(state.progressWaiter === waiter)
            state.progressWaiter = nil
        }
    }

    func installAsyncProgressRegistration(
        _ registration: StrokePreparationAsyncProgressRegistration
    ) {
        state.withLock { state in
            precondition(state.asyncProgressRegistration == nil)
            state.asyncProgressRegistration = registration
        }
    }

    func removeAsyncProgressRegistration(
        _ registration: StrokePreparationAsyncProgressRegistration
    ) {
        state.withLock { state in
            precondition(state.asyncProgressRegistration === registration)
            state.asyncProgressRegistration = nil
        }
    }

    func drainResults(
        into destination: inout [StrokePreparationResult]
    ) {
        // The destination is MainActor-owned scratch. This unchecked closure
        // is still serialized by the lock and never escapes it; using the
        // non-Sendable overload avoids falsely transferring the inout buffer.
        state.withLockUnchecked { state in
            destination.removeAll(keepingCapacity: true)
            destination.reserveCapacity(state.results.count)
            while let result = state.results.removeFirst() {
                destination.append(result)
            }
        }
    }

    func recordWorkerTaskPriority(_ priority: TaskPriority) {
        state.withLock { state in
            state.workerTaskPriority = priority
        }
    }
}

/// One long-lived drain task services a stroke mailbox. Input methods remain
/// synchronous and bounded; all preparation crosses to the coordinator actor.
final class StrokePreparationBridge: Sendable {
    let mailbox: StrokePreparationMailbox

    private let scheduler: StrokeFrameScheduler
    private let wake: AsyncStream<Void>.Continuation
    private let workerTask: Task<Void, Never>

    init(
        budget: DepositionFrameBudget,
        targetFramesPerSecond: Int
    ) {
        let mailbox = StrokePreparationMailbox(budget: budget)
        let scheduler = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: targetFramesPerSecond
        )
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.mailbox = mailbox
        self.scheduler = scheduler
        wake = pair.continuation
        workerTask = Task.detached(priority: .userInitiated) {
            mailbox.recordWorkerTaskPriority(Task.currentPriority)
            for await _ in pair.stream {
                if Task.isCancelled { return }
                while true {
                    if let acknowledgement = mailbox
                        .takePreparedFrameAcknowledgement()
                    {
                        let result = await scheduler
                            .acknowledgePreparedFrame(
                                generation: acknowledgement.generation,
                                frameToken: acknowledgement.token
                            )
                        mailbox.completePreparedFrameAcknowledgement(
                            generation: acknowledgement.generation,
                            token: acknowledgement.token
                        )
                        if let result { mailbox.publish(result) }
                        mailbox.completeWorkerOperation()
                        continue
                    }
                    guard let message = mailbox.takeInput() else { break }
                    if let result = await scheduler.process(message) {
                        mailbox.publish(result)
                    }
                    mailbox.completeWorkerOperation()
                }
            }
        }
    }

    deinit {
        wake.finish()
        workerTask.cancel()
    }

    @discardableResult
    func submit(
        _ message: StrokeInputMessage
    ) throws -> StrokeInputAdmission {
        let admission = try mailbox.submit(message)
        wake.yield()
        return admission
    }

    @discardableResult
    func submitCancellation(
        generation: UInt64,
        reason: StrokeInputCancellationReason?,
        frameDisposition: StrokePreparationCancellationFrameDisposition
    ) throws -> StrokeInputAdmission {
        let admission = try mailbox.submitCancellation(
            generation: generation,
            reason: reason,
            frameDisposition: frameDisposition
        )
        wake.yield()
        return admission
    }

    func drainResults(
        into destination: inout [StrokePreparationResult]
    ) {
        mailbox.drainResults(into: &destination)
        wake.yield()
    }

    func acknowledgePreparedFrame(
        generation: UInt64,
        token: UInt64
    ) throws {
        try mailbox.acknowledgePreparedFrame(
            generation: generation,
            token: token
        )
        wake.yield()
    }

    #if DEBUG
    func schedulerSnapshotForTesting() async
        -> StrokeFrameSchedulerSnapshot
    {
        await scheduler.snapshot
    }

    func transientSnapshotForTesting() async
        -> StrokeTransientPreparationSnapshot
    {
        await scheduler.transientPreparationSnapshotForTesting
    }
    #endif
}

private struct StrokeResultRing: Sendable {
    let capacity: Int
    var storageCapacity: Int { storage.capacity }
    private(set) var count = 0

    private var storage: ContiguousArray<StrokePreparationResult?>
    private var head = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = ContiguousArray(repeating: nil, count: capacity)
    }

    mutating func append(_ result: StrokePreparationResult) {
        precondition(count < capacity)
        storage[(head + count) % capacity] = result
        count += 1
    }

    mutating func removeFirst() -> StrokePreparationResult? {
        guard count > 0 else { return nil }
        let result = storage[head]
        storage[head] = nil
        head = (head + 1) % capacity
        count -= 1
        if count == 0 { head = 0 }
        return result
    }

    mutating func reset() {
        while count > 0 {
            _ = removeFirst()
        }
    }
}
