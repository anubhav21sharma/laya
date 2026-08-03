import PatternEngine

public struct AuthoritativeStrokeWork: Equatable, Sendable {
    public let ordinal: UInt64
    public let dab: LogicalDab

    public init(dab: LogicalDab) {
        precondition(!dab.isPredicted)
        ordinal = dab.ordinal
        self.dab = dab
    }
}

public struct PreparedAuthoritativeStrokeFrame: Equatable, Sendable {
    public let work: [AuthoritativeStrokeWork]
    fileprivate let token: UInt64

    fileprivate init(work: [AuthoritativeStrokeWork], token: UInt64) {
        self.work = work
        self.token = token
    }
}

public enum AuthoritativeStrokeQueueError: Error, Equatable, Sendable {
    case invalidCapacity(Int)
    case capacityExceeded(current: Int, incoming: Int, maximum: Int)
    case noncontiguousOrdinal(expected: UInt64, actual: UInt64)
    case frameAlreadyPrepared
    case invalidPreparedFrame
    case ordinalOverflow
}

/// Fixed-capacity, exactly-once queue for authoritative logical dabs.
///
/// Preparation borrows a prefix without removing it. Only a successful
/// `retire(_:)` removes that prefix; `abandon(_:)` makes the same work eligible
/// for retry. Retired ordinals are forgotten except for compact counters and
/// can therefore never be returned by a later frame.
public struct AuthoritativeStrokeQueue: Sendable {
    public let capacity: Int
    public private(set) var count = 0
    public private(set) var highWater = 0
    public private(set) var submittedCount: UInt64 = 0
    public private(set) var nextExpectedOrdinal: UInt64 = 0

    public var availableCapacity: Int { capacity - count }
    public var isEmpty: Bool { count == 0 }
    var hasPreparedFrame: Bool { preparedToken != nil }

    private var head = 0
    private var storage: ContiguousArray<AuthoritativeStrokeWork?>
    private var preparedToken: UInt64?
    private var preparedCount = 0
    private var nextToken: UInt64 = 1

    public init(capacity: Int) throws {
        guard capacity > 0 else {
            throw AuthoritativeStrokeQueueError.invalidCapacity(capacity)
        }
        self.capacity = capacity
        storage = ContiguousArray(repeating: nil, count: capacity)
    }

    public func preflightAppend(
        _ work: [AuthoritativeStrokeWork]
    ) throws {
        guard work.count <= availableCapacity else {
            throw AuthoritativeStrokeQueueError.capacityExceeded(
                current: count,
                incoming: work.count,
                maximum: capacity
            )
        }
        var expected = nextExpectedOrdinal
        for item in work {
            guard item.ordinal == item.dab.ordinal,
                  item.ordinal == expected
            else {
                throw AuthoritativeStrokeQueueError.noncontiguousOrdinal(
                    expected: expected,
                    actual: item.ordinal
                )
            }
            let (next, overflow) = expected.addingReportingOverflow(1)
            guard !overflow else {
                throw AuthoritativeStrokeQueueError.ordinalOverflow
            }
            expected = next
        }
    }

    public mutating func append(
        _ work: [AuthoritativeStrokeWork]
    ) throws {
        try preflightAppend(work)
        appendPrevalidated(work)
    }

    /// Appends work whose capacity, ordinal continuity, and overflow were
    /// checked by `preflightAppend(_:)` while the caller held exclusive state.
    mutating func appendPrevalidated(
        _ work: [AuthoritativeStrokeWork]
    ) {
        guard !work.isEmpty else { return }
        for item in work {
            storage[(head + count) % capacity] = item
            count += 1
        }
        nextExpectedOrdinal &+= UInt64(work.count)
        highWater = max(highWater, count)
    }

    /// Validates accounting for authoritative work that downstream already
    /// accepted. The caller must also prove the queue has no borrowed or
    /// retained work before recording the transfer.
    func preflightRetiredTransfer(
        startingOrdinal: UInt64,
        count incomingCount: Int
    ) throws {
        guard incomingCount >= 0 else {
            throw AuthoritativeStrokeQueueError.invalidCapacity(incomingCount)
        }
        guard incomingCount <= availableCapacity else {
            throw AuthoritativeStrokeQueueError.capacityExceeded(
                current: count,
                incoming: incomingCount,
                maximum: capacity
            )
        }
        let incoming = UInt64(incomingCount)
        let (_, overflow) = startingOrdinal.addingReportingOverflow(incoming)
        guard !overflow else {
            throw AuthoritativeStrokeQueueError.ordinalOverflow
        }
        guard startingOrdinal == nextExpectedOrdinal else {
            throw AuthoritativeStrokeQueueError.noncontiguousOrdinal(
                expected: nextExpectedOrdinal,
                actual: startingOrdinal
            )
        }
        let (_, submittedOverflow) = submittedCount
            .addingReportingOverflow(incoming)
        guard !submittedOverflow else {
            throw AuthoritativeStrokeQueueError.ordinalOverflow
        }
    }

    /// Advances compact accounting for work accepted and retired downstream.
    /// `preflightRetiredTransfer(startingOrdinal:count:)` must have succeeded
    /// while the queue remained exclusively owned and empty.
    mutating func recordPrevalidatedRetiredTransfer(
        startingOrdinal: UInt64,
        count transferredCount: Int
    ) {
        precondition(isEmpty && !hasPreparedFrame)
        precondition(startingOrdinal == nextExpectedOrdinal)
        precondition(transferredCount >= 0 && transferredCount <= capacity)
        let transferred = UInt64(transferredCount)
        nextExpectedOrdinal = startingOrdinal &+ transferred
        submittedCount &+= transferred
        highWater = max(highWater, transferredCount)
    }

    /// Records high-water and submission accounting for work that downstream
    /// already accepted. The caller preflighted the append while this queue was
    /// empty, so no frame-token allocation or recoverable failure remains.
    mutating func recordPrevalidatedTransfer(
        _ work: [AuthoritativeStrokeWork]
    ) {
        precondition(
            isEmpty && !hasPreparedFrame,
            "Immediate authoritative transfer requires an empty queue"
        )
        highWater = max(highWater, work.count)
        nextExpectedOrdinal &+= UInt64(work.count)
        submittedCount &+= UInt64(work.count)
    }

    public mutating func prepare(
        maximumCount: Int
    ) throws -> PreparedAuthoritativeStrokeFrame? {
        guard maximumCount > 0 else {
            throw AuthoritativeStrokeQueueError.invalidCapacity(maximumCount)
        }
        guard preparedToken == nil else {
            throw AuthoritativeStrokeQueueError.frameAlreadyPrepared
        }
        guard count > 0 else { return nil }
        let borrowedCount = min(count, maximumCount)
        var work: [AuthoritativeStrokeWork] = []
        work.reserveCapacity(borrowedCount)
        for offset in 0..<borrowedCount {
            guard let item = storage[(head + offset) % capacity] else {
                preconditionFailure(
                    "Authoritative queue lost an occupied record"
                )
            }
            work.append(item)
        }
        let token = nextToken
        let (successor, overflow) = nextToken.addingReportingOverflow(1)
        guard !overflow else {
            throw AuthoritativeStrokeQueueError.ordinalOverflow
        }
        nextToken = successor
        preparedToken = token
        preparedCount = borrowedCount
        return PreparedAuthoritativeStrokeFrame(work: work, token: token)
    }

    public mutating func retire(
        _ frame: PreparedAuthoritativeStrokeFrame
    ) throws {
        guard preparedToken == frame.token,
              preparedCount == frame.work.count,
              preparedCount <= count
        else {
            throw AuthoritativeStrokeQueueError.invalidPreparedFrame
        }
        for offset in 0..<preparedCount {
            let index = (head + offset) % capacity
            guard storage[index] == frame.work[offset] else {
                throw AuthoritativeStrokeQueueError.invalidPreparedFrame
            }
            storage[index] = nil
        }
        let retired = preparedCount
        head = (head + retired) % capacity
        count -= retired
        submittedCount += UInt64(retired)
        if count == 0 { head = 0 }
        preparedToken = nil
        preparedCount = 0
    }

    public mutating func abandon(
        _ frame: PreparedAuthoritativeStrokeFrame
    ) {
        guard preparedToken == frame.token,
              preparedCount == frame.work.count
        else { return }
        preparedToken = nil
        preparedCount = 0
    }

    public mutating func reset() {
        if count > 0 {
            for offset in 0..<count {
                storage[(head + offset) % capacity] = nil
            }
        }
        count = 0
        highWater = 0
        submittedCount = 0
        nextExpectedOrdinal = 0
        head = 0
        preparedToken = nil
        preparedCount = 0
    }

    #if DEBUG
    @discardableResult
    mutating func replaceNextFrameTokenForTesting(
        _ token: UInt64
    ) -> UInt64 {
        let previous = nextToken
        nextToken = token
        return previous
    }
    #endif
}
