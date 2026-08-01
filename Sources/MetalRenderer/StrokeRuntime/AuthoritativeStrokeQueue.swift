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
        guard !work.isEmpty else { return }
        for item in work {
            storage[(head + count) % capacity] = item
            count += 1
        }
        nextExpectedOrdinal += UInt64(work.count)
        highWater = max(highWater, count)
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
}
