struct ScheduledDepositionFrame: Equatable, Sendable {
    let authoritative: [ProjectedDepositionRecord]
    let predicted: [ProjectedDepositionRecord]
    let authoritativeRemaining: Int
    let predictedRemaining: Int
}

struct FrameSchedulerDiagnosticSnapshot: Equatable, Sendable {
    let authoritativePending: Int
    let predictedPending: Int
    let authoritativeHighWater: Int
    let predictedHighWater: Int
    let authoritativeStorageCapacity: Int
    let predictedStorageCapacity: Int
}

enum FrameSchedulerError: Error, Equatable, Sendable {
    case authoritativeCapacityExceeded(
        current: Int,
        incoming: Int,
        maximum: Int
    )
    case predictedCapacityExceeded(actual: Int, maximum: Int)
}

final class FrameScheduler: @unchecked Sendable {
    var diagnosticSnapshot: FrameSchedulerDiagnosticSnapshot {
        FrameSchedulerDiagnosticSnapshot(
            authoritativePending: authoritativeQueue.count,
            predictedPending: predictionQueue.count,
            authoritativeHighWater: authoritativeHighWater,
            predictedHighWater: predictedHighWater,
            authoritativeStorageCapacity:
                authoritativeQueue.storageCapacity,
            predictedStorageCapacity:
                predictionQueue.storageCapacity
        )
    }

    var authoritativeIsDrained: Bool {
        authoritativeQueue.isEmpty
    }

    var authoritativeCount: Int {
        authoritativeQueue.count
    }

    var authoritativeAvailableCapacity: Int {
        authoritativeQueue.availableCapacity
    }

    var predictedCount: Int {
        predictionQueue.count
    }

    var predictedCapacity: Int {
        predictionQueue.capacity
    }

    var authoritativeRecords: [ProjectedDepositionRecord] {
        authoritativeQueue.records
    }

    var predictedRecords: [ProjectedDepositionRecord] {
        predictionQueue.records
    }

    private var authoritativeQueue: BoundedDepositionQueue
    private var predictionQueue: BoundedDepositionQueue
    private var predictionCandidate: BoundedDepositionQueue
    private var authoritativeHighWater = 0
    private var predictedHighWater = 0

    init(budget: DepositionFrameBudget) {
        authoritativeQueue = BoundedDepositionQueue(
            capacity: budget.maximumPendingAuthoritativeInstances
        )
        predictionQueue = BoundedDepositionQueue(
            capacity: budget.maximumPendingPredictedInstances
        )
        predictionCandidate = BoundedDepositionQueue(
            capacity: budget.maximumPendingPredictedInstances
        )
    }

    func enqueueAuthoritative(
        _ records: [ProjectedDepositionRecord]
    ) throws {
        guard records.count <= authoritativeQueue.availableCapacity else {
            throw FrameSchedulerError.authoritativeCapacityExceeded(
                current: authoritativeQueue.count,
                incoming: records.count,
                maximum: authoritativeQueue.capacity
            )
        }
        authoritativeQueue.append(records)
        authoritativeHighWater = max(
            authoritativeHighWater,
            authoritativeQueue.count
        )
    }

    func replacePrediction(
        _ records: [ProjectedDepositionRecord]
    ) throws {
        guard records.count <= predictionQueue.capacity else {
            throw FrameSchedulerError.predictedCapacityExceeded(
                actual: records.count,
                maximum: predictionQueue.capacity
            )
        }

        predictionCandidate.reset()
        predictionCandidate.append(records)
        swap(&predictionQueue, &predictionCandidate)
        predictedHighWater = max(
            predictedHighWater,
            predictionQueue.count
        )
    }

    func nextFrame(
        budget: DepositionFrameBudget,
        includePrediction: Bool = true,
        authoritativeScratch: inout [ProjectedDepositionRecord],
        predictedScratch: inout [ProjectedDepositionRecord]
    ) -> ScheduledDepositionFrame {
        let frame = preparedFrame(
            budget: budget,
            includePrediction: includePrediction,
            authoritativeScratch: &authoritativeScratch,
            predictedScratch: &predictedScratch
        )
        consume(frame)
        return frame
    }

    func preparedFrame(
        budget: DepositionFrameBudget,
        includePrediction: Bool = true,
        authoritativeScratch: inout [ProjectedDepositionRecord],
        predictedScratch: inout [ProjectedDepositionRecord]
    ) -> ScheduledDepositionFrame {
        authoritativeQueue.copyPrefix(
            maximumCount: budget.maximumAuthoritativeInstances,
            into: &authoritativeScratch
        )
        if includePrediction {
            predictionQueue.copyPrefix(
                maximumCount: budget.maximumPredictedInstances,
                into: &predictedScratch
            )
        } else {
            predictedScratch.removeAll(keepingCapacity: true)
        }
        return ScheduledDepositionFrame(
            authoritative: authoritativeScratch,
            predicted: predictedScratch,
            authoritativeRemaining:
                authoritativeQueue.count - authoritativeScratch.count,
            predictedRemaining:
                predictionQueue.count - predictedScratch.count
        )
    }

    func consume(_ frame: ScheduledDepositionFrame) {
        authoritativeQueue.removeFirst(frame.authoritative.count)
        predictionQueue.removeFirst(frame.predicted.count)
    }

    func nextFrame(
        budget: DepositionFrameBudget,
        includePrediction: Bool = true
    ) -> ScheduledDepositionFrame {
        var authoritative: [ProjectedDepositionRecord] = []
        var predicted: [ProjectedDepositionRecord] = []
        authoritative.reserveCapacity(
            budget.maximumAuthoritativeInstances
        )
        predicted.reserveCapacity(budget.maximumPredictedInstances)
        return nextFrame(
            budget: budget,
            includePrediction: includePrediction,
            authoritativeScratch: &authoritative,
            predictedScratch: &predicted
        )
    }

    func discardPrediction() {
        predictionQueue.reset()
    }

    func promotePredictionToAuthoritative() throws {
        guard predictionQueue.count
            <= authoritativeQueue.availableCapacity
        else {
            throw FrameSchedulerError.authoritativeCapacityExceeded(
                current: authoritativeQueue.count,
                incoming: predictionQueue.count,
                maximum: authoritativeQueue.capacity
            )
        }
        authoritativeQueue.append(contentsOf: predictionQueue)
        authoritativeHighWater = max(
            authoritativeHighWater,
            authoritativeQueue.count
        )
        predictionQueue.reset()
    }

    func reset() {
        authoritativeQueue.reset()
        predictionQueue.reset()
        predictionCandidate.reset()
        authoritativeHighWater = 0
        predictedHighWater = 0
    }
}

private struct BoundedDepositionQueue: Sendable {
    let capacity: Int

    var isEmpty: Bool {
        count == 0
    }

    var availableCapacity: Int {
        capacity - count
    }

    var storageCapacity: Int {
        storage.capacity
    }

    var records: [ProjectedDepositionRecord] {
        guard count > 0 else { return [] }
        return (0..<count).map { offset in
            guard let record = storage[(head + offset) % capacity] else {
                preconditionFailure(
                    "Bounded deposition queue lost an occupied record"
                )
            }
            return record
        }
    }

    private(set) var count = 0
    private var head = 0
    private var storage: ContiguousArray<ProjectedDepositionRecord?>

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = ContiguousArray(repeating: nil, count: capacity)
    }

    mutating func append(_ records: [ProjectedDepositionRecord]) {
        precondition(records.count <= availableCapacity)
        for record in records {
            let index = (head + count) % capacity
            storage[index] = record
            count += 1
        }
    }

    mutating func append(contentsOf source: BoundedDepositionQueue) {
        precondition(source.count <= availableCapacity)
        for offset in 0..<source.count {
            guard
                let record =
                    source.storage[(source.head + offset) % source.capacity]
            else {
                preconditionFailure(
                    "Bounded deposition queue lost an occupied record"
                )
            }
            let index = (head + count) % capacity
            storage[index] = record
            count += 1
        }
    }

    func copyPrefix(
        maximumCount: Int,
        into records: inout [ProjectedDepositionRecord]
    ) {
        precondition(maximumCount > 0)
        let copiedCount = min(count, maximumCount)
        records.removeAll(keepingCapacity: true)
        guard copiedCount > 0 else { return }
        precondition(
            records.capacity >= copiedCount,
            "Frame scratch must be reserved before interactive input."
        )
        for offset in 0..<copiedCount {
            guard let record = storage[(head + offset) % capacity] else {
                preconditionFailure(
                    "Bounded deposition queue lost an occupied record"
                )
            }
            records.append(record)
        }
    }

    mutating func removeFirst(_ removedCount: Int) {
        precondition((0...count).contains(removedCount))
        guard removedCount > 0 else { return }
        for offset in 0..<removedCount {
            storage[(head + offset) % capacity] = nil
        }
        head = (head + removedCount) % capacity
        count -= removedCount
        if count == 0 {
            head = 0
        }
    }

    mutating func reset() {
        guard count > 0 else {
            head = 0
            return
        }
        for offset in 0..<count {
            storage[(head + offset) % capacity] = nil
        }
        head = 0
        count = 0
    }
}
