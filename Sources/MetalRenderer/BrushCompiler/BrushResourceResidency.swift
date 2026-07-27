import Foundation

public enum BrushResourcePressureResult: Equatable, Sendable {
    case satisfied(evictedKeys: [String])
    case activeBrushExceedsTarget(requiredBytes: Int, targetBytes: Int)
}

enum BrushResourceResidencyError: Error, Equatable, Sendable {
    case emptyKey
    case nonpositiveByteCount(Int)
    case byteCountMismatch(key: String, expected: Int, actual: Int)
    case residentByteCountOverflow
    case accessOrdinalOverflow
    case invalidTargetBytes(Int)
    case insufficientCapacity(
        requestedBytes: Int,
        byteBudget: Int,
        pinnedBytes: Int
    )
}

struct BrushResourceResidency: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let byteCount: Int
        var pinned: Bool
        var lastAccess: UInt64
    }

    let byteBudget: Int
    private(set) var nextAccessOrdinal: UInt64
    private(set) var entries: [String: Entry]

    init(byteBudget: Int) {
        precondition(byteBudget > 0)
        self.init(
            byteBudget: byteBudget,
            nextAccessOrdinal: 0,
            entries: [:]
        )
    }

    /// Internal state injection is intentionally available to deterministic
    /// overflow and stable-tie tests.
    init(
        byteBudget: Int,
        nextAccessOrdinal: UInt64,
        entries: [String: Entry]
    ) {
        precondition(byteBudget > 0)
        self.byteBudget = byteBudget
        self.nextAccessOrdinal = nextAccessOrdinal
        self.entries = entries
    }

    var keys: [String] {
        entries.keys.sorted()
    }

    var pinnedKeys: [String] {
        entries.compactMap { key, entry in
            entry.pinned ? key : nil
        }.sorted()
    }

    var residentByteCount: Int {
        entries.values.reduce(0) { $0 + $1.byteCount }
    }

    var pinnedByteCount: Int {
        entries.values.reduce(0) {
            $0 + ($1.pinned ? $1.byteCount : 0)
        }
    }

    mutating func access(
        key: String,
        byteCount: Int,
        pinned: Bool
    ) throws -> [String] {
        guard !key.isEmpty else {
            throw BrushResourceResidencyError.emptyKey
        }
        guard byteCount > 0 else {
            throw BrushResourceResidencyError.nonpositiveByteCount(byteCount)
        }
        let (ordinal, ordinalOverflow) =
            nextAccessOrdinal.addingReportingOverflow(1)
        guard !ordinalOverflow else {
            throw BrushResourceResidencyError.accessOrdinalOverflow
        }

        if var existing = entries[key] {
            guard existing.byteCount == byteCount else {
                throw BrushResourceResidencyError.byteCountMismatch(
                    key: key,
                    expected: existing.byteCount,
                    actual: byteCount
                )
            }
            existing.pinned = existing.pinned || pinned
            existing.lastAccess = ordinal
            entries[key] = existing
            nextAccessOrdinal = ordinal
            return []
        }

        let currentBytes = try checkedResidentByteCount()
        let (projectedBytes, byteOverflow) =
            currentBytes.addingReportingOverflow(byteCount)
        guard !byteOverflow else {
            throw BrushResourceResidencyError.residentByteCountOverflow
        }
        let pinnedBytes = try checkedPinnedByteCount()
        let (minimumBytes, pinnedOverflow) =
            pinnedBytes.addingReportingOverflow(byteCount)
        guard !pinnedOverflow else {
            throw BrushResourceResidencyError.residentByteCountOverflow
        }
        guard byteCount <= byteBudget, minimumBytes <= byteBudget else {
            throw BrushResourceResidencyError.insufficientCapacity(
                requestedBytes: byteCount,
                byteBudget: byteBudget,
                pinnedBytes: pinnedBytes
            )
        }

        var stagedEntries = entries
        var stagedBytes = projectedBytes
        var evicted: [String] = []
        while stagedBytes > byteBudget {
            guard let victim = Self.leastRecentlyUsedUnpinned(in: stagedEntries)
            else {
                throw BrushResourceResidencyError.insufficientCapacity(
                    requestedBytes: byteCount,
                    byteBudget: byteBudget,
                    pinnedBytes: pinnedBytes
                )
            }
            guard let removed = stagedEntries.removeValue(forKey: victim) else {
                preconditionFailure("Chosen residency victim must exist")
            }
            stagedBytes -= removed.byteCount
            evicted.append(victim)
        }
        stagedEntries[key] = Entry(
            byteCount: byteCount,
            pinned: pinned,
            lastAccess: ordinal
        )
        entries = stagedEntries
        nextAccessOrdinal = ordinal
        return evicted
    }

    mutating func pin(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.pinned = true
        entries[key] = entry
    }

    mutating func unpin(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.pinned = false
        entries[key] = entry
    }

    mutating func remove(_ key: String) {
        entries.removeValue(forKey: key)
    }

    mutating func evictUnpinned(to targetResidentBytes: Int) throws -> [String] {
        guard targetResidentBytes >= 0 else {
            throw BrushResourceResidencyError.invalidTargetBytes(
                targetResidentBytes
            )
        }
        var stagedEntries = entries
        var stagedBytes = try checkedResidentByteCount()
        var evicted: [String] = []
        while stagedBytes > targetResidentBytes {
            guard let victim = Self.leastRecentlyUsedUnpinned(in: stagedEntries)
            else {
                break
            }
            guard let removed = stagedEntries.removeValue(forKey: victim) else {
                preconditionFailure("Chosen residency victim must exist")
            }
            stagedBytes -= removed.byteCount
            evicted.append(victim)
        }
        entries = stagedEntries
        return evicted
    }

    func pressureResult(
        targetResidentBytes: Int
    ) -> BrushResourcePressureResult {
        let requiredBytes = pinnedByteCount
        guard targetResidentBytes >= requiredBytes else {
            return .activeBrushExceedsTarget(
                requiredBytes: requiredBytes,
                targetBytes: targetResidentBytes
            )
        }
        var staged = self
        let evicted = (try? staged.evictUnpinned(to: targetResidentBytes)) ?? []
        return .satisfied(evictedKeys: evicted)
    }

    mutating func applyMemoryPressure(
        targetResidentBytes: Int
    ) throws -> BrushResourcePressureResult {
        guard targetResidentBytes >= 0 else {
            throw BrushResourceResidencyError.invalidTargetBytes(
                targetResidentBytes
            )
        }
        let result = pressureResult(targetResidentBytes: targetResidentBytes)
        guard case .satisfied = result else { return result }
        let evicted = try evictUnpinned(to: targetResidentBytes)
        return .satisfied(evictedKeys: evicted)
    }

    private func checkedResidentByteCount() throws -> Int {
        try Self.checkedByteCount(entries.values.map(\.byteCount))
    }

    private func checkedPinnedByteCount() throws -> Int {
        try Self.checkedByteCount(
            entries.values.compactMap { $0.pinned ? $0.byteCount : nil }
        )
    }

    private static func checkedByteCount(
        _ byteCounts: [Int]
    ) throws -> Int {
        var total = 0
        for byteCount in byteCounts {
            guard byteCount > 0 else {
                throw BrushResourceResidencyError
                    .nonpositiveByteCount(byteCount)
            }
            let (next, overflow) = total.addingReportingOverflow(byteCount)
            guard !overflow else {
                throw BrushResourceResidencyError.residentByteCountOverflow
            }
            total = next
        }
        return total
    }

    private static func leastRecentlyUsedUnpinned(
        in entries: [String: Entry]
    ) -> String? {
        entries
            .filter { !$0.value.pinned }
            .min {
                ($0.value.lastAccess, $0.key)
                    < ($1.value.lastAccess, $1.key)
            }?
            .key
    }
}
