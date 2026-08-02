import Foundation
@testable import PatternEngine
import Testing

@Suite("StrokeVelocityFilter")
struct StrokeVelocityFilterTests {
    @Test
    func uniformMotionUsesDurationWeightedVelocity() {
        var filter = StrokeVelocityFilter()
        #expect(filter.begin(at: point(0), time: 0) == 0)

        #expect(filter.update(to: point(1), time: 0.01) == 100)
        #expect(filter.update(to: point(2), time: 0.02) == 100)
        #expect(filter.update(to: point(3), time: 0.03) == 100)
        #expect(filter.snapshot.velocity == 100)
    }

    @Test
    func segmentEndingAtExactWindowBoundaryContributesNothing() {
        var filter = StrokeVelocityFilter()
        _ = filter.begin(at: point(0), time: 0)
        _ = filter.update(to: point(1), time: 0.02)
        _ = filter.update(to: point(3), time: 0.04)

        let velocity = filter.update(to: point(5), time: 0.06)

        #expect(velocity == 100)
        #expect(filter.snapshot.segmentCount == 2)
    }

    @Test
    func segmentCrossingWindowStartIsFractionallyIncluded() {
        var filter = StrokeVelocityFilter()
        _ = filter.begin(at: point(0), time: 0)
        _ = filter.update(to: point(3), time: 0.03)

        let velocity = filter.update(to: point(7), time: 0.05)

        expect(velocity, equals: 150)
    }

    @Test
    func largeTimestampBoundaryRetainsARealFractionalCrossing() {
        let base = 1_000_000_000_000.0
        let firstEnd = base + 0.010009765625
        let current = base + 0.049072265625
        let windowStart = current - StrokeVelocityFilter.windowDuration
        let crossingDuration = firstEnd - windowStart
        let secondDuration = current - firstEnd
        var filter = StrokeVelocityFilter()
        _ = filter.begin(at: point(0), time: base)
        _ = filter.update(to: point(0), time: firstEnd)

        let velocity = filter.update(to: point(3.90625), time: current)
        let expected = Float(
            100 * secondDuration / (crossingDuration + secondDuration)
        )

        #expect(crossingDuration == 0.0009765625)
        expect(velocity, equals: expected)
        #expect(filter.snapshot.segmentCount == 2)
    }

    @Test
    func jitteredIntervalsUseTheirActualDurations() {
        var filter = StrokeVelocityFilter()
        _ = filter.begin(at: point(0), time: 0)
        _ = filter.update(to: point(0.7), time: 0.007)
        _ = filter.update(to: point(2.7), time: 0.017)
        _ = filter.update(to: point(3.45), time: 0.031)

        let velocity = filter.update(to: point(6.45), time: 0.046)

        expect(velocity, equals: 5.85 / 0.040)
    }

    @Test
    func positiveSubminimumDeltaCoalescesIntoNextAcceptedSegment() {
        var coalesced = StrokeVelocityFilter()
        _ = coalesced.begin(at: point(0), time: 0)
        #expect(coalesced.update(to: point(0.03), time: 0.0003) == 0)
        let actual = coalesced.update(to: point(0.1), time: 0.001)

        var equivalent = StrokeVelocityFilter()
        _ = equivalent.begin(at: point(0), time: 0)
        let expected = equivalent.update(to: point(0.1), time: 0.001)

        expect(actual, equals: expected)
        #expect(coalesced.snapshot == equivalent.snapshot)
    }

    @Test
    func moreThanSixtyFourRawSamplesCoalesceWithoutExceedingCapacity() {
        var raw = StrokeVelocityFilter()
        _ = raw.begin(at: point(0), time: 0)
        for index in 1...100 {
            let time = Double(index) * 0.0003
            _ = raw.update(to: point(Float(time * 100)), time: time)
        }

        var equivalent = StrokeVelocityFilter()
        _ = equivalent.begin(at: point(0), time: 0)
        for index in stride(from: 3, through: 99, by: 3) {
            let time = Double(index) * 0.0003
            _ = equivalent.update(to: point(Float(time * 100)), time: time)
        }

        expect(raw.snapshot.velocity, equals: equivalent.snapshot.velocity)
        #expect(raw.snapshot.segmentCount == equivalent.snapshot.segmentCount)
        #expect(raw.snapshot.segmentCount <= StrokeVelocityFilter.segmentCapacity)
    }

    @Test
    func fullRingEvictsOnlyTheSegmentAtTheNextWindowBoundary() {
        var filter = StrokeVelocityFilter()
        _ = filter.begin(at: point(0), time: 0)
        for index in 1...StrokeVelocityFilter.segmentCapacity {
            let time = Double(index) * StrokeVelocityFilter.minimumDeltaTime
            _ = filter.update(to: point(Float(index)), time: time)
        }
        #expect(
            filter.snapshot.segmentCount == StrokeVelocityFilter.segmentCapacity
        )
        #expect(filter.capacityFallbackEvictionCountForTesting == 0)

        let nextIndex = StrokeVelocityFilter.segmentCapacity + 1
        let nextTime = Double(nextIndex) * StrokeVelocityFilter.minimumDeltaTime
        let velocity = filter.update(to: point(Float(nextIndex)), time: nextTime)

        #expect(filter.snapshot.segmentCount == StrokeVelocityFilter.segmentCapacity)
        expect(velocity, equals: Float(1) / Float(StrokeVelocityFilter.minimumDeltaTime))
        #expect(filter.capacityFallbackEvictionCountForTesting == 0)
    }

    @Test
    func zeroAndNegativeTimestampsLeaveStateUntouched() {
        var filter = StrokeVelocityFilter()
        _ = filter.begin(at: point(0), time: 0)
        _ = filter.update(to: point(1), time: 0.01)
        let before = filter.snapshot

        #expect(filter.update(to: point(100), time: 0.01) == 100)
        #expect(filter.snapshot == before)
        #expect(filter.update(to: point(-100), time: -1) == 100)
        #expect(filter.snapshot == before)
        #expect(filter.update(to: point(2), time: 0.02) == 100)
    }

    @Test
    func stationarySegmentDilutesMovingSegmentByDuration() {
        var filter = StrokeVelocityFilter()
        _ = filter.begin(at: point(0), time: 0)
        _ = filter.update(to: point(0), time: 0.01)

        let velocity = filter.update(to: point(1), time: 0.02)

        expect(velocity, equals: 50)
    }

    @Test
    func safetyClampedSpikeFallsOutOfTheWindow() {
        var filter = StrokeVelocityFilter()
        _ = filter.begin(at: point(0), time: 0)
        _ = filter.update(to: point(10_000), time: 0.01)
        let mixed = filter.update(to: point(10_001), time: 0.02)

        expect(mixed, equals: 50_050)
        #expect(filter.update(to: point(10_005), time: 0.06) == 100)
    }

    @Test
    func copiedFilterRetainsIndependentValueStateAndResetProducesZero() {
        var original = StrokeVelocityFilter()
        _ = original.begin(at: point(0), time: 0)
        _ = original.update(to: point(1), time: 0.01)
        let originalSnapshot = original.snapshot
        var copy = original

        _ = copy.update(to: point(5), time: 0.02)
        #expect(original.snapshot == originalSnapshot)

        copy.reset()
        #expect(copy.snapshot.velocity == 0)
        #expect(copy.snapshot.segmentCount == 0)
        #expect(copy.begin(at: point(10), time: 1) == 0)
        #expect(copy.snapshot.velocity == 0)
    }

    @Test
    func nonfiniteInputsLeaveTheLastFiniteVelocityAndStateUntouched() {
        var filter = StrokeVelocityFilter()
        _ = filter.begin(at: point(0), time: 0)
        _ = filter.update(to: point(1), time: 0.01)
        let before = filter.snapshot

        #expect(filter.update(to: point(.infinity), time: 0.02) == 100)
        #expect(filter.snapshot == before)
        #expect(filter.update(to: point(2), time: .infinity) == 100)
        #expect(filter.snapshot == before)
    }

    @Test
    func millionUpdatesAfterWarmupKeepTheInlineRingBounded() {
        var filter = StrokeVelocityFilter()
        _ = filter.begin(at: point(0), time: 0)
        for index in 1...128 {
            let time = Double(index) * StrokeVelocityFilter.minimumDeltaTime
            _ = filter.update(to: point(Float(index)), time: time)
        }

        for index in 129...1_000_128 {
            let time = Double(index) * StrokeVelocityFilter.minimumDeltaTime
            _ = filter.update(to: point(Float(index)), time: time)
        }
        #expect(filter.snapshot.segmentCount <= StrokeVelocityFilter.segmentCapacity)
    }
}

private func point(_ x: Float) -> WorldPoint {
    WorldPoint(x: x, y: 0)
}

private func expect(
    _ actual: Float,
    equals expected: Float,
    tolerance: Float = 0.001
) {
    #expect(abs(actual - expected) <= tolerance)
}
