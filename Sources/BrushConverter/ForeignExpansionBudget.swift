import Foundation

final class ForeignExpansionBudget: @unchecked Sendable {
    let maximumExpandedBytes: Int
    let maximumEntries: Int

    private let lock = NSLock()
    private var expandedBytes = 0
    private var entries = 0

    init(maximumExpandedBytes: Int, maximumEntries: Int) {
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumEntries = maximumEntries
    }

    convenience init(limits: ForeignContainerLimits = .standard) {
        self.init(
            maximumExpandedBytes: limits.maximumExpandedBytes,
            maximumEntries: limits.maximumNestedEntries
        )
    }

    var consumedExpandedBytes: Int {
        lock.withLock { expandedBytes }
    }

    var consumedEntries: Int {
        lock.withLock { entries }
    }

    func charge(expandedByteCount: Int) throws {
        try lock.withLock {
            let (next, overflow) = expandedBytes.addingReportingOverflow(
                expandedByteCount
            )
            guard expandedByteCount >= 0,
                  !overflow,
                  next <= maximumExpandedBytes
            else {
                throw ForeignContainerError.expansionBudgetExceeded(
                    actual: overflow ? Int.max : next,
                    maximum: maximumExpandedBytes
                )
            }
            expandedBytes = next
        }
    }

    func charge(entryCount: Int) throws {
        try lock.withLock {
            let (next, overflow) = entries.addingReportingOverflow(entryCount)
            guard entryCount >= 0, !overflow, next <= maximumEntries else {
                throw ForeignContainerError.aggregateEntryCountExceeded(
                    actual: overflow ? Int.max : next,
                    maximum: maximumEntries
                )
            }
            entries = next
        }
    }

    func refund(expandedByteCount: Int, entryCount: Int) {
        lock.withLock {
            expandedBytes -= expandedByteCount
            entries -= entryCount
        }
    }
}
