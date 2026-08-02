import Foundation
import PatternEngine
import Testing

@Suite("BrushDirectionTracker")
struct BrushDirectionTrackerTests {
    @Test
    func firstNonzeroSegmentInitializesWithoutInventingATurn() throws {
        var tracker = BrushDirectionTracker()
        try tracker.begin(at: directionPoint(0, 0))

        let stationary = try tracker.update(to: directionPoint(0, 0))
        let firstTravel = try tracker.update(to: directionPoint(0, 4))

        #expect(stationary.direction == nil)
        #expect(stationary.signedTurn == nil)
        expectDirection(firstTravel.direction, equals: .pi / 2)
        #expect(firstTravel.signedTurn == nil)
    }

    @Test
    func crossingFrom359DegreesTo1DegreeUsesTheShortArc() throws {
        var tracker = BrushDirectionTracker()
        try tracker.begin(at: directionPoint(0, 0))
        let firstEndpoint = directionEndpoint(degrees: 359)
        let first = try tracker.update(to: firstEndpoint)

        let turn = try tracker.update(
            to: firstEndpoint + directionEndpoint(degrees: 1)
        )

        expectDirection(first.direction, equals: degrees(-1))
        expectDirection(turn.direction, equals: degrees(1))
        expectDirection(turn.signedTurn, equals: degrees(2))
    }

    @Test
    func stationarySegmentsRetainDirectionAndPriorTurnSign() throws {
        var tracker = BrushDirectionTracker()
        try tracker.begin(at: directionPoint(0, 0))
        _ = try tracker.update(to: directionPoint(1, 0))
        _ = try tracker.update(to: directionPoint(1, -1))

        let stationary = try tracker.update(to: directionPoint(1, -1))
        let halfTurnAfterStationary = try tracker.update(
            to: directionPoint(1, 0)
        )

        expectDirection(stationary.direction, equals: degrees(-90))
        #expect(stationary.signedTurn == nil)
        expectDirection(halfTurnAfterStationary.signedTurn, equals: -.pi)
        expectDirection(halfTurnAfterStationary.direction, equals: -3 * .pi / 2)
    }

    @Test
    func exactHalfTurnWithoutPriorTurnUsesPositiveSignForBothSignedZeros() throws {
        for y in [Float.zero, -Float.zero] {
            var tracker = BrushDirectionTracker()
            try tracker.begin(at: directionPoint(0, 0))
            _ = try tracker.update(to: directionPoint(1, 0))

            let reversal = try tracker.update(to: directionPoint(0, y))

            expectDirection(reversal.signedTurn, equals: .pi)
            expectDirection(reversal.direction, equals: .pi)
        }
    }

    @Test
    func exactHalfTurnFollowsTheLastPositiveTurnSign() throws {
        var tracker = BrushDirectionTracker()
        try tracker.begin(at: directionPoint(0, 0))
        _ = try tracker.update(to: directionPoint(1, 0))
        _ = try tracker.update(to: directionPoint(1, 1))

        let reversal = try tracker.update(to: directionPoint(1, 0))

        expectDirection(reversal.signedTurn, equals: .pi)
        expectDirection(reversal.direction, equals: 3 * .pi / 2)
    }

    @Test
    func exactHalfTurnFollowsTheLastNegativeTurnSign() throws {
        var tracker = BrushDirectionTracker()
        try tracker.begin(at: directionPoint(0, 0))
        _ = try tracker.update(to: directionPoint(1, 0))
        _ = try tracker.update(to: directionPoint(1, -1))

        let reversal = try tracker.update(to: directionPoint(1, 0))

        expectDirection(reversal.signedTurn, equals: -.pi)
        expectDirection(reversal.direction, equals: -3 * .pi / 2)
    }

    @Test
    func manyCompleteTurnsPreserveExactReversalSignAndMonotonicAngle() throws {
        var tracker = BrushDirectionTracker()
        try tracker.begin(at: directionPoint(0, 0))
        var priorDirection: Float?

        for _ in 0..<20_000 {
            priorDirection = try tracker.update(to: directionPoint(1, 0)).direction
            priorDirection = try tracker.update(to: directionPoint(1, 1)).direction
            priorDirection = try tracker.update(to: directionPoint(0, 1)).direction
            priorDirection = try tracker.update(to: directionPoint(0, 0)).direction
        }

        let previous = try #require(priorDirection)
        let reversal = try tracker.update(to: directionPoint(0, 1))

        expectDirection(reversal.signedTurn, equals: .pi)
        let reversalDirection = try #require(reversal.direction)
        #expect(reversalDirection.isFinite)
        #expect(reversalDirection > previous)
    }

    @Test
    func copyHasIndependentValueStateAndResetRemovesAllHistory() throws {
        var original = BrushDirectionTracker()
        try original.begin(at: directionPoint(0, 0))
        _ = try original.update(to: directionEndpoint(degrees: 0))
        var copy = original
        _ = try copy.update(to: directionPoint(1, 1))

        let originalTurn = try original.update(to: directionPoint(1, -1))
        expectDirection(originalTurn.signedTurn, equals: -.pi / 2)

        copy.reset()
        try copy.begin(at: directionPoint(4, 5))
        let stationary = try copy.update(to: directionPoint(4, 5))
        #expect(stationary.direction == nil)
        #expect(stationary.signedTurn == nil)
    }

    @Test
    func nonfiniteBeginFailsTypedWithoutMutatingExistingState() throws {
        var tracker = BrushDirectionTracker()
        try tracker.begin(at: directionPoint(0, 0))
        _ = try tracker.update(to: directionPoint(1, 0))
        let stateBefore = tracker

        #expect(throws: BrushDirectionTrackerError.invalidPosition) {
            try tracker.begin(at: directionPoint(.infinity, 0))
        }

        #expect(tracker == stateBefore)
        let turn = try tracker.update(to: directionPoint(1, 1))
        expectDirection(turn.signedTurn, equals: .pi / 2)
    }

    @Test
    func nonfiniteUpdateFailsTypedWithoutMutatingExistingState() throws {
        var tracker = BrushDirectionTracker()
        try tracker.begin(at: directionPoint(0, 0))
        _ = try tracker.update(to: directionPoint(1, 0))
        let stateBefore = tracker

        #expect(throws: BrushDirectionTrackerError.invalidPosition) {
            _ = try tracker.update(to: directionPoint(1, .nan))
        }

        #expect(tracker == stateBefore)
        let turn = try tracker.update(to: directionPoint(1, -1))
        expectDirection(turn.signedTurn, equals: -.pi / 2)
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
