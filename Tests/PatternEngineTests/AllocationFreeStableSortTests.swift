import Testing
@testable import PatternEngine

@Suite("Allocation-free stable sort")
struct AllocationFreeStableSortTests {
    private struct SortKey: Equatable {
        let primary: Int
        let originalOrdinal: Int
    }

    @Test
    func matchesStandardOrderAcrossBoundaries() {
        let fixtures = [
            [],
            [1],
            [2, 1],
            [3, 1, 2],
            Array((0..<4_096).reversed()),
            (0..<4_096).map { ($0 * 1_103 + 97) % 4_099 },
        ]

        for fixture in fixtures {
            var actual = fixture
            var scratch: [Int] = []
            scratch.reserveCapacity(actual.count)
            allocationFreeStableSort(&actual, scratch: &scratch, by: <)
            #expect(actual == fixture.sorted())
            #expect(scratch.isEmpty)
            #expect(scratch.capacity >= actual.count)
        }
    }

    @Test
    func preservesOriginalOrderForDistinguishableTies() {
        let fixture = (0..<1_024).map { index in
            SortKey(
                primary: (index * 17) % 31,
                originalOrdinal: index
            )
        }
        let precedes: (SortKey, SortKey) -> Bool = {
            $0.primary < $1.primary
        }
        var actual = fixture
        var scratch: [SortKey] = []
        scratch.reserveCapacity(actual.count)
        allocationFreeStableSort(
            &actual,
            scratch: &scratch,
            by: precedes
        )
        #expect(actual == fixture.sorted(by: precedes))
    }
}
