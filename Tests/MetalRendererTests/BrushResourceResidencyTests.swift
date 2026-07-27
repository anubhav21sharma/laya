@testable import MetalRenderer
import Testing

@Suite("Brush resource residency")
struct BrushResourceResidencyTests {
    @Test
    func insertionEvictsOnlyLeastRecentlyUsedUnpinnedEntries() throws {
        var state = BrushResourceResidency(byteBudget: 100)

        #expect(try state.access(key: "active", byteCount: 60, pinned: true) == [])
        #expect(try state.access(key: "old", byteCount: 30, pinned: false) == [])
        #expect(try state.access(key: "new", byteCount: 30, pinned: false) == ["old"])
        #expect(state.keys == ["active", "new"])
        #expect(state.residentByteCount == 90)
        #expect(state.pinnedKeys == ["active"])
    }

    @Test
    func duplicateAccessRefreshesRecencyWithoutChangingBytesOrDroppingPin() throws {
        var state = BrushResourceResidency(byteBudget: 90)
        _ = try state.access(key: "active", byteCount: 30, pinned: true)
        _ = try state.access(key: "a", byteCount: 30, pinned: false)
        _ = try state.access(key: "b", byteCount: 30, pinned: false)

        #expect(try state.access(key: "a", byteCount: 30, pinned: false) == [])
        #expect(try state.access(key: "c", byteCount: 30, pinned: false) == ["b"])
        #expect(state.keys == ["a", "active", "c"])
        #expect(state.pinnedKeys == ["active"])
        #expect(state.residentByteCount == 90)
    }

    @Test
    func duplicateAccessCanPromoteButNeverImplicitlyUnpins() throws {
        var state = BrushResourceResidency(byteBudget: 20)
        _ = try state.access(key: "shared", byteCount: 10, pinned: false)

        _ = try state.access(key: "shared", byteCount: 10, pinned: true)
        #expect(state.pinnedKeys == ["shared"])
        _ = try state.access(key: "shared", byteCount: 10, pinned: false)
        #expect(state.pinnedKeys == ["shared"])
    }

    @Test
    func recencyTiesEvictByStableKeyOrder() throws {
        var state = BrushResourceResidency(
            byteBudget: 20,
            nextAccessOrdinal: 8,
            entries: [
                "z": .init(byteCount: 10, pinned: false, lastAccess: 4),
                "a": .init(byteCount: 10, pinned: false, lastAccess: 4),
            ]
        )

        #expect(try state.access(key: "new", byteCount: 10, pinned: false) == ["a"])
        #expect(state.keys == ["new", "z"])
    }

    @Test
    func explicitEvictionNeverRemovesPinsAndIsDeterministic() throws {
        var state = BrushResourceResidency(byteBudget: 100)
        _ = try state.access(key: "active", byteCount: 40, pinned: true)
        _ = try state.access(key: "old", byteCount: 25, pinned: false)
        _ = try state.access(key: "new", byteCount: 25, pinned: false)

        #expect(try state.evictUnpinned(to: 45) == ["old", "new"])
        #expect(state.keys == ["active"])
        #expect(state.residentByteCount == 40)
    }

    @Test
    func pinUnpinAndRemoveDoNotAlterRecency() throws {
        var state = BrushResourceResidency(byteBudget: 60)
        _ = try state.access(key: "a", byteCount: 20, pinned: false)
        _ = try state.access(key: "b", byteCount: 20, pinned: false)
        state.pin("a")
        state.unpin("a")
        state.remove("b")
        _ = try state.access(key: "c", byteCount: 40, pinned: false)

        #expect(state.keys == ["a", "c"])
        #expect(state.residentByteCount == 60)
        #expect(state.pinnedKeys == [])
    }

    @Test
    func invalidAccessesAndByteMismatchAreAtomic() throws {
        var state = BrushResourceResidency(byteBudget: 100)
        _ = try state.access(key: "stable", byteCount: 40, pinned: true)
        let original = state

        #expect(throws: BrushResourceResidencyError.emptyKey) {
            try state.access(key: "", byteCount: 1, pinned: false)
        }
        #expect(state == original)
        #expect(throws: BrushResourceResidencyError.nonpositiveByteCount(0)) {
            try state.access(key: "zero", byteCount: 0, pinned: false)
        }
        #expect(state == original)
        #expect(
            throws: BrushResourceResidencyError.byteCountMismatch(
                key: "stable",
                expected: 40,
                actual: 41
            )
        ) {
            try state.access(key: "stable", byteCount: 41, pinned: false)
        }
        #expect(state == original)
    }

    @Test
    func candidateOverBudgetAndPinnedCapacityFailureAreAtomic() throws {
        var state = BrushResourceResidency(byteBudget: 100)
        _ = try state.access(key: "active", byteCount: 60, pinned: true)
        _ = try state.access(key: "inactive", byteCount: 20, pinned: false)

        let beforeTooLarge = state
        #expect(
            throws: BrushResourceResidencyError.insufficientCapacity(
                requestedBytes: 101,
                byteBudget: 100,
                pinnedBytes: 60
            )
        ) {
            try state.access(key: "huge", byteCount: 101, pinned: false)
        }
        #expect(state == beforeTooLarge)

        let beforePinnedFailure = state
        #expect(
            throws: BrushResourceResidencyError.insufficientCapacity(
                requestedBytes: 50,
                byteBudget: 100,
                pinnedBytes: 60
            )
        ) {
            try state.access(key: "candidate", byteCount: 50, pinned: true)
        }
        #expect(state == beforePinnedFailure)
    }

    @Test
    func checkedArithmeticAndOrdinalOverflowAreAtomic() throws {
        var byteOverflow = BrushResourceResidency(
            byteBudget: .max,
            nextAccessOrdinal: 4,
            entries: [
                "full": .init(
                    byteCount: .max,
                    pinned: false,
                    lastAccess: 4
                ),
            ]
        )
        let byteOriginal = byteOverflow
        #expect(throws: BrushResourceResidencyError.residentByteCountOverflow) {
            try byteOverflow.access(key: "overflow", byteCount: 1, pinned: false)
        }
        #expect(byteOverflow == byteOriginal)

        var ordinalOverflow = BrushResourceResidency(
            byteBudget: 10,
            nextAccessOrdinal: .max,
            entries: [:]
        )
        let ordinalOriginal = ordinalOverflow
        #expect(throws: BrushResourceResidencyError.accessOrdinalOverflow) {
            try ordinalOverflow.access(key: "a", byteCount: 1, pinned: false)
        }
        #expect(ordinalOverflow == ordinalOriginal)
    }

    @Test
    func pressureBelowPinsReportsRequiredBytesWithoutMutation() throws {
        var state = BrushResourceResidency(byteBudget: 100)
        _ = try state.access(key: "active", byteCount: 60, pinned: true)
        _ = try state.access(key: "inactive", byteCount: 20, pinned: false)
        let original = state

        #expect(
            state.pressureResult(targetResidentBytes: 50)
                == .activeBrushExceedsTarget(requiredBytes: 60, targetBytes: 50)
        )
        #expect(state == original)
    }

    @Test
    func negativePressureTargetIsTypedAndAtomicWhileZeroIsValid() throws {
        var state = BrushResourceResidency(byteBudget: 100)
        _ = try state.access(key: "active", byteCount: 60, pinned: true)
        _ = try state.access(key: "inactive", byteCount: 20, pinned: false)
        let original = state

        #expect(throws: BrushResourceResidencyError.invalidTargetBytes(-1)) {
            try state.applyMemoryPressure(targetResidentBytes: -1)
        }
        #expect(state == original)
        #expect(
            try state.applyMemoryPressure(targetResidentBytes: 0)
                == .activeBrushExceedsTarget(requiredBytes: 60, targetBytes: 0)
        )
        #expect(state == original)
    }

    @Test
    func pressureEvictsInactiveLRUUntilTarget() throws {
        var state = BrushResourceResidency(byteBudget: 100)
        _ = try state.access(key: "active", byteCount: 40, pinned: true)
        _ = try state.access(key: "old", byteCount: 20, pinned: false)
        _ = try state.access(key: "new", byteCount: 20, pinned: false)

        #expect(
            try state.applyMemoryPressure(targetResidentBytes: 65)
                == .satisfied(evictedKeys: ["old"])
        )
        #expect(state.keys == ["active", "new"])
        #expect(state.residentByteCount == 60)
    }
}
