import Foundation
import PatternEngine
import Testing

@Suite("BrushDirectionTracker")
struct BrushDirectionTrackerTests {
    @Test
    func firstNonzeroSegmentInitializesWithoutInventingATurn() {
        var tracker = BrushDirectionTracker()
        tracker.begin(at: directionPoint(0, 0))

        let stationary = tracker.update(to: directionPoint(0, 0))
        let firstTravel = tracker.update(to: directionPoint(0, 4))

        #expect(stationary.direction == nil)
        #expect(stationary.signedTurn == nil)
        expectDirection(firstTravel.direction, equals: .pi / 2)
        #expect(firstTravel.signedTurn == nil)
    }

    @Test
    func crossingFrom359DegreesTo1DegreeUsesTheShortArc() {
        var tracker = BrushDirectionTracker()
        tracker.begin(at: directionPoint(0, 0))
        let firstEndpoint = directionEndpoint(degrees: 359)
        let first = tracker.update(to: firstEndpoint)

        let turn = tracker.update(
            to: firstEndpoint + directionEndpoint(degrees: 1)
        )

        expectDirection(first.direction, equals: degrees(-1))
        expectDirection(turn.direction, equals: degrees(1))
        expectDirection(turn.signedTurn, equals: degrees(2))
    }

    @Test
    func stationarySegmentsRetainDirectionAndPriorTurnSign() {
        var tracker = BrushDirectionTracker()
        tracker.begin(at: directionPoint(0, 0))
        _ = tracker.update(to: directionPoint(1, 0))
        _ = tracker.update(to: directionPoint(1, -1))

        let stationary = tracker.update(to: directionPoint(1, -1))
        let halfTurnAfterStationary = tracker.update(
            to: directionPoint(1, 0)
        )

        expectDirection(stationary.direction, equals: degrees(-90))
        #expect(stationary.signedTurn == nil)
        expectDirection(halfTurnAfterStationary.signedTurn, equals: -.pi)
        expectDirection(halfTurnAfterStationary.direction, equals: -3 * .pi / 2)
    }

    @Test
    func exactHalfTurnWithoutPriorTurnUsesPositiveSignForBothSignedZeros() {
        for y in [Float.zero, -Float.zero] {
            var tracker = BrushDirectionTracker()
            tracker.begin(at: directionPoint(0, 0))
            _ = tracker.update(to: directionPoint(1, 0))

            let reversal = tracker.update(to: directionPoint(0, y))

            expectDirection(reversal.signedTurn, equals: .pi)
            expectDirection(reversal.direction, equals: .pi)
        }
    }

    @Test
    func exactHalfTurnFollowsTheLastPositiveTurnSign() {
        var tracker = BrushDirectionTracker()
        tracker.begin(at: directionPoint(0, 0))
        _ = tracker.update(to: directionPoint(1, 0))
        _ = tracker.update(to: directionPoint(1, 1))

        let reversal = tracker.update(to: directionPoint(1, 0))

        expectDirection(reversal.signedTurn, equals: .pi)
        expectDirection(reversal.direction, equals: 3 * .pi / 2)
    }

    @Test
    func exactHalfTurnFollowsTheLastNegativeTurnSign() {
        var tracker = BrushDirectionTracker()
        tracker.begin(at: directionPoint(0, 0))
        _ = tracker.update(to: directionPoint(1, 0))
        _ = tracker.update(to: directionPoint(1, -1))

        let reversal = tracker.update(to: directionPoint(1, 0))

        expectDirection(reversal.signedTurn, equals: -.pi)
        expectDirection(reversal.direction, equals: -3 * .pi / 2)
    }

    @Test
    func copyHasIndependentValueStateAndResetRemovesAllHistory() {
        var original = BrushDirectionTracker()
        original.begin(at: directionPoint(0, 0))
        _ = original.update(to: directionEndpoint(degrees: 0))
        var copy = original
        _ = copy.update(to: directionPoint(1, 1))

        let originalTurn = original.update(to: directionPoint(1, -1))
        expectDirection(originalTurn.signedTurn, equals: -.pi / 2)

        copy.reset()
        copy.begin(at: directionPoint(4, 5))
        let stationary = copy.update(to: directionPoint(4, 5))
        #expect(stationary.direction == nil)
        #expect(stationary.signedTurn == nil)
    }
}

private func directionPoint(_ x: Float, _ y: Float) -> WorldPoint {
    WorldPoint(x: x, y: y)
}

private func + (lhs: WorldPoint, rhs: WorldPoint) -> WorldPoint {
    directionPoint(lhs.x + rhs.x, lhs.y + rhs.y)
}

private func directionEndpoint(degrees value: Float) -> WorldPoint {
    let angle = degrees(value)
    return directionPoint(cos(angle), sin(angle))
}

private func degrees(_ value: Float) -> Float {
    value * .pi / 180
}

private func expectDirection(
    _ actual: Float?,
    equals expected: Float,
    tolerance: Float = 0.000_01
) {
    #expect(actual != nil)
    if let actual {
        #expect(abs(actual - expected) <= tolerance)
    }
}
