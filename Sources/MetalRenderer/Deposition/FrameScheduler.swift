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
}

enum FrameSchedulerError: Error, Equatable, Sendable {
    case authoritativeCapacityExceeded(
        current: Int,
        incoming: Int,
        maximum: Int
    )
    case predictedCapacityExceeded(actual: Int, maximum: Int)
}

struct FrameScheduler: Sendable {
    var diagnosticSnapshot: FrameSchedulerDiagnosticSnapshot {
        FrameSchedulerDiagnosticSnapshot(
            authoritativePending: authoritativeQueue.count,
            predictedPending: predictionQueue.count,
            authoritativeHighWater: authoritativeHighWater,
            predictedHighWater: predictedHighWater
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

    mutating func enqueueAuthoritative(
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

    mutating func replacePrediction(
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

    mutating func nextFrame(
        budget: DepositionFrameBudget,
        includePrediction: Bool = true
    ) -> ScheduledDepositionFrame {
        let authoritative = authoritativeQueue.take(
            maximumCount: budget.maximumAuthoritativeInstances
        )
        let predicted = includePrediction
            ? predictionQueue.take(
                maximumCount: budget.maximumPredictedInstances
            )
            : []
        return ScheduledDepositionFrame(
            authoritative: authoritative,
            predicted: predicted,
            authoritativeRemaining: authoritativeQueue.count,
            predictedRemaining: predictionQueue.count
        )
    }

    mutating func discardPrediction() {
        predictionQueue.reset()
    }

    mutating func promotePredictionToAuthoritative() throws {
        let records = predictionQueue.records
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
        predictionQueue.reset()
    }

    mutating func reset() {
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

    mutating func take(
        maximumCount: Int
    ) -> [ProjectedDepositionRecord] {
        precondition(maximumCount > 0)
        let takenCount = min(count, maximumCount)
        guard takenCount > 0 else { return [] }

        var records: [ProjectedDepositionRecord] = []
        records.reserveCapacity(takenCount)
        for offset in 0..<takenCount {
            let index = (head + offset) % capacity
            guard let record = storage[index] else {
                preconditionFailure(
                    "Bounded deposition queue lost an occupied record"
                )
            }
            records.append(record)
            storage[index] = nil
        }
        head = (head + takenCount) % capacity
        count -= takenCount
        if count == 0 {
            head = 0
        }
        return records
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
