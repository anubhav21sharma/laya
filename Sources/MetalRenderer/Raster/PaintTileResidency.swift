import Foundation
import Metal

public struct PaintTileID: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: PaintTileID, rhs: PaintTileID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct PaintTileIdentity: Hashable, Comparable, Sendable {
    public let layerID: UUID
    public let coordinate: PaintTileCoordinate
    public let tileID: PaintTileID

    public init(
        layerID: UUID,
        coordinate: PaintTileCoordinate,
        tileID: PaintTileID
    ) {
        self.layerID = layerID
        self.coordinate = coordinate
        self.tileID = tileID
    }

    public static func < (
        lhs: PaintTileIdentity,
        rhs: PaintTileIdentity
    ) -> Bool {
        let lhsLayer = lhs.layerID.uuidString
        let rhsLayer = rhs.layerID.uuidString
        if lhsLayer != rhsLayer { return lhsLayer < rhsLayer }
        if lhs.coordinate.y != rhs.coordinate.y {
            return lhs.coordinate.y < rhs.coordinate.y
        }
        if lhs.coordinate.x != rhs.coordinate.x {
            return lhs.coordinate.x < rhs.coordinate.x
        }
        return lhs.tileID < rhs.tileID
    }
}

public enum PaintTilePinReason: UInt8, CaseIterable, Comparable, Sendable {
    case active
    case dirty
    case historyBefore
    case visible
    case inFlight

    public static func < (
        lhs: PaintTilePinReason,
        rhs: PaintTilePinReason
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum PaintTileResidencyError: Error, Equatable, Sendable {
    case invalidByteBudget(Int)
    case nonpositiveByteCount(Int)
    case byteCountMismatch(expected: Int, actual: Int)
    case residentByteCountOverflow
    case useEpochOverflow
    case pinCountOverflow(reason: PaintTilePinReason)
    case unbalancedUnpin(reason: PaintTilePinReason)
    case missingIdentity(PaintTileIdentity)
    case invalidTargetBytes(Int)
    case insufficientCapacity(
        requestedBytes: Int,
        byteBudget: Int,
        pinnedBytes: Int
    )
}

public enum PaintTileBudgetFallback: Sendable {
    case macOS
    case iOS
}

public enum PaintTileBudget {
    private static let mebibyte = UInt64(1_024 * 1_024)
    private static let minimum = 64 * mebibyte
    private static let maximum = 256 * mebibyte

    public static func bytes(
        recommendedMaxWorkingSetSize recommendation: UInt64,
        fallback: PaintTileBudgetFallback
    ) throws -> Int {
        let selected: UInt64
        if recommendation == 0 {
            selected = switch fallback {
            case .macOS: 128 * mebibyte
            case .iOS: 64 * mebibyte
            }
        } else {
            selected = min(maximum, max(minimum, recommendation / 8))
        }
        guard let result = Int(exactly: selected) else {
            throw PaintTileResidencyError.residentByteCountOverflow
        }
        return result
    }

    public static func bytes(
        for device: any MTLDevice,
        fallback: PaintTileBudgetFallback
    ) throws -> Int {
        try bytes(
            recommendedMaxWorkingSetSize:
                UInt64(device.recommendedMaxWorkingSetSize),
            fallback: fallback
        )
    }
}

struct PaintTilePinCounts: Equatable, Sendable,
    ExpressibleByDictionaryLiteral
{
    private var active = 0
    private var dirty = 0
    private var historyBefore = 0
    private var visible = 0
    private var inFlight = 0

    init() {}

    init(dictionaryLiteral elements: (PaintTilePinReason, Int)...) {
        self.init()
        for (reason, count) in elements { self[reason] = count }
    }

    subscript(_ reason: PaintTilePinReason) -> Int? {
        get {
            let count = switch reason {
            case .active: active
            case .dirty: dirty
            case .historyBefore: historyBefore
            case .visible: visible
            case .inFlight: inFlight
            }
            return count == 0 ? nil : count
        }
        set {
            let count = newValue ?? 0
            switch reason {
            case .active: active = count
            case .dirty: dirty = count
            case .historyBefore: historyBefore = count
            case .visible: visible = count
            case .inFlight: inFlight = count
            }
        }
    }

    var isPinned: Bool {
        active > 0 || dirty > 0 || historyBefore > 0
            || visible > 0 || inFlight > 0
    }

    var dictionary: [PaintTilePinReason: Int] {
        var result: [PaintTilePinReason: Int] = [:]
        for reason in PaintTilePinReason.allCases {
            if let count = self[reason] { result[reason] = count }
        }
        return result
    }
}

public struct PaintTileResidency: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let byteCount: Int
        var lastUseEpoch: UInt64
        var pinCounts: PaintTilePinCounts

        var isPinned: Bool {
            pinCounts.isPinned
        }
    }

    public let byteBudget: Int
    private(set) var nextUseEpoch: UInt64
    private(set) var entries: [PaintTileIdentity: Entry]

    public init(byteBudget: Int) {
        precondition(byteBudget > 0)
        self.init(byteBudget: byteBudget, nextUseEpoch: 0, entries: [:])
    }

    init(
        byteBudget: Int,
        nextUseEpoch: UInt64,
        entries: [PaintTileIdentity: Entry]
    ) {
        precondition(byteBudget > 0)
        self.byteBudget = byteBudget
        self.nextUseEpoch = nextUseEpoch
        self.entries = entries
    }

    public var residentByteCount: Int {
        entries.values.reduce(into: 0) { $0 += $1.byteCount }
    }

    public var pinnedByteCount: Int {
        entries.values.reduce(into: 0) {
            if $1.isPinned { $0 += $1.byteCount }
        }
    }

    public var residentIdentities: [PaintTileIdentity] {
        entries.keys.sorted()
    }

    public var leastRecentlyUsedOrder: [PaintTileIdentity] {
        entries.keys.sorted(by: evictionPrecedes)
    }

    public func isPinned(_ identity: PaintTileIdentity) -> Bool {
        entries[identity]?.isPinned ?? false
    }

    public func pinCount(
        _ identity: PaintTileIdentity,
        reason: PaintTilePinReason
    ) -> Int {
        entries[identity]?.pinCounts[reason] ?? 0
    }

    @discardableResult
    public mutating func admit(
        _ identity: PaintTileIdentity,
        byteCount: Int,
        pinReasons: [PaintTilePinReason]
    ) throws -> [PaintTileIdentity] {
        guard byteCount > 0 else {
            throw PaintTileResidencyError.nonpositiveByteCount(byteCount)
        }
        let epoch = try advancedEpoch()
        let reasons = Array(Set(pinReasons)).sorted()
        if var existing = entries[identity] {
            guard existing.byteCount == byteCount else {
                throw PaintTileResidencyError.byteCountMismatch(
                    expected: existing.byteCount,
                    actual: byteCount
                )
            }
            for reason in reasons {
                try Self.increment(reason, in: &existing.pinCounts)
            }
            existing.lastUseEpoch = epoch
            entries[identity] = existing
            nextUseEpoch = epoch
            return []
        }

        let current = try checkedResidentByteCount()
        let (projected, overflow) = current.addingReportingOverflow(byteCount)
        guard !overflow else {
            throw PaintTileResidencyError.residentByteCountOverflow
        }
        let pinned = try checkedPinnedByteCount()
        let (required, pinnedOverflow) = pinned.addingReportingOverflow(
            byteCount
        )
        guard !pinnedOverflow else {
            throw PaintTileResidencyError.residentByteCountOverflow
        }
        guard byteCount <= byteBudget, required <= byteBudget else {
            throw PaintTileResidencyError.insufficientCapacity(
                requestedBytes: byteCount,
                byteBudget: byteBudget,
                pinnedBytes: pinned
            )
        }

        var stagedEntries = entries
        var stagedBytes = projected
        var evicted: [PaintTileIdentity] = []
        while stagedBytes > byteBudget {
            guard let victim = Self.leastRecentlyUsedUnpinned(
                in: stagedEntries
            ) else {
                throw PaintTileResidencyError.insufficientCapacity(
                    requestedBytes: byteCount,
                    byteBudget: byteBudget,
                    pinnedBytes: pinned
                )
            }
            guard let removed = stagedEntries.removeValue(forKey: victim)
            else { preconditionFailure("Selected paint tile must exist") }
            stagedBytes -= removed.byteCount
            evicted.append(victim)
        }
        var counts = PaintTilePinCounts()
        for reason in reasons {
            try Self.increment(reason, in: &counts)
        }
        stagedEntries[identity] = Entry(
            byteCount: byteCount,
            lastUseEpoch: epoch,
            pinCounts: counts
        )
        entries = stagedEntries
        nextUseEpoch = epoch
        return evicted
    }

    public mutating func pin(
        _ identity: PaintTileIdentity,
        reason: PaintTilePinReason
    ) throws {
        guard var entry = entries[identity] else {
            throw PaintTileResidencyError.missingIdentity(identity)
        }
        try Self.increment(reason, in: &entry.pinCounts)
        entries[identity] = entry
    }

    func preflightPinExisting(
        _ identities: [PaintTileIdentity],
        reasons: [PaintTilePinReason]
    ) throws {
        let (_, epochOverflow) = nextUseEpoch.addingReportingOverflow(
            UInt64(identities.count)
        )
        guard !epochOverflow else {
            throw PaintTileResidencyError.useEpochOverflow
        }
        for identity in identities {
            guard let entry = entries[identity] else {
                throw PaintTileResidencyError.missingIdentity(identity)
            }
            for reason in reasons {
                guard (entry.pinCounts[reason] ?? 0) < Int.max else {
                    throw PaintTileResidencyError.pinCountOverflow(
                        reason: reason
                    )
                }
            }
        }
    }

    func preflightPinExisting(
        _ identity: PaintTileIdentity,
        reasons: [PaintTilePinReason]
    ) throws {
        guard let entry = entries[identity] else {
            throw PaintTileResidencyError.missingIdentity(identity)
        }
        for reason in reasons {
            guard (entry.pinCounts[reason] ?? 0) < Int.max else {
                throw PaintTileResidencyError.pinCountOverflow(reason: reason)
            }
        }
    }

    func preflightUseEpochAdvance(by count: Int) throws {
        guard count >= 0, let count = UInt64(exactly: count) else {
            throw PaintTileResidencyError.useEpochOverflow
        }
        let (_, overflow) = nextUseEpoch.addingReportingOverflow(count)
        guard !overflow else { throw PaintTileResidencyError.useEpochOverflow }
    }

    mutating func pinExistingPreflighted(
        _ identity: PaintTileIdentity,
        reasons: [PaintTilePinReason]
    ) {
        var entry = entries[identity]!
        nextUseEpoch += 1
        entry.lastUseEpoch = nextUseEpoch
        for reason in reasons {
            entry.pinCounts[reason] = (entry.pinCounts[reason] ?? 0) + 1
        }
        entries[identity] = entry
    }

    public mutating func unpin(
        _ identity: PaintTileIdentity,
        reason: PaintTilePinReason
    ) throws {
        guard var entry = entries[identity] else {
            throw PaintTileResidencyError.missingIdentity(identity)
        }
        guard let count = entry.pinCounts[reason], count > 0 else {
            throw PaintTileResidencyError.unbalancedUnpin(reason: reason)
        }
        if count == 1 {
            entry.pinCounts[reason] = nil
        } else {
            entry.pinCounts[reason] = count - 1
        }
        entries[identity] = entry
    }

    public mutating func remove(_ identity: PaintTileIdentity) {
        entries.removeValue(forKey: identity)
    }

    @discardableResult
    public mutating func evictUnpinned(
        to targetResidentBytes: Int
    ) throws -> [PaintTileIdentity] {
        guard targetResidentBytes >= 0 else {
            throw PaintTileResidencyError.invalidTargetBytes(
                targetResidentBytes
            )
        }
        var staged = entries
        var bytes = try checkedResidentByteCount()
        var evicted: [PaintTileIdentity] = []
        while bytes > targetResidentBytes {
            guard let victim = Self.leastRecentlyUsedUnpinned(in: staged)
            else { break }
            guard let removed = staged.removeValue(forKey: victim)
            else { preconditionFailure("Selected paint tile must exist") }
            bytes -= removed.byteCount
            evicted.append(victim)
        }
        entries = staged
        return evicted
    }

    private mutating func advancedEpoch() throws -> UInt64 {
        let (next, overflow) = nextUseEpoch.addingReportingOverflow(1)
        guard !overflow else {
            throw PaintTileResidencyError.useEpochOverflow
        }
        return next
    }

    private func checkedResidentByteCount() throws -> Int {
        try Self.checkedByteCount(entries.values.map(\.byteCount))
    }

    private func checkedPinnedByteCount() throws -> Int {
        try Self.checkedByteCount(
            entries.values.compactMap { $0.isPinned ? $0.byteCount : nil }
        )
    }

    private static func checkedByteCount(_ values: [Int]) throws -> Int {
        var total = 0
        for value in values {
            guard value > 0 else {
                throw PaintTileResidencyError.nonpositiveByteCount(value)
            }
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else {
                throw PaintTileResidencyError.residentByteCountOverflow
            }
            total = next
        }
        return total
    }

    private static func increment(
        _ reason: PaintTilePinReason,
        in counts: inout PaintTilePinCounts
    ) throws {
        let current = counts[reason] ?? 0
        let (next, overflow) = current.addingReportingOverflow(1)
        guard !overflow else {
            throw PaintTileResidencyError.pinCountOverflow(reason: reason)
        }
        counts[reason] = next
    }

    private func evictionPrecedes(
        _ lhs: PaintTileIdentity,
        _ rhs: PaintTileIdentity
    ) -> Bool {
        guard let left = entries[lhs], let right = entries[rhs] else {
            return lhs < rhs
        }
        if left.lastUseEpoch != right.lastUseEpoch {
            return left.lastUseEpoch < right.lastUseEpoch
        }
        return lhs < rhs
    }

    private static func leastRecentlyUsedUnpinned(
        in entries: [PaintTileIdentity: Entry]
    ) -> PaintTileIdentity? {
        entries
            .filter { !$0.value.isPinned }
            .min {
                if $0.value.lastUseEpoch != $1.value.lastUseEpoch {
                    return $0.value.lastUseEpoch < $1.value.lastUseEpoch
                }
                return $0.key < $1.key
            }?
            .key
    }
}
