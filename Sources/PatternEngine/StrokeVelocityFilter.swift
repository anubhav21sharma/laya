import Foundation

/// A fixed-window, duration-weighted velocity filter for one world-space stroke.
///
/// The filter retains at most 64 accepted segments inline, allowing copied
/// stroke state to remain independent and allocation-free after initialization.
public struct StrokeVelocityFilter: Equatable, Sendable {
    public static let windowDuration: TimeInterval = 0.040
    public static let segmentCapacity = 64
    public static let minimumDeltaTime: TimeInterval =
        windowDuration / Double(segmentCapacity)

    public struct Snapshot: Equatable, Sendable {
        public let velocity: Float
        public let segmentCount: Int
    }

    private var segmentSlots = StrokeVelocityFilterSegmentStorage()
    private var oldestSegmentIndex = 0
    private var segmentCount = 0
    private var capacityFallbackEvictionCount = 0
    private var segmentTimeBase: TimeInterval = 0
    private var originPosition = WorldPoint(x: 0, y: 0)
    private var originTime: TimeInterval = 0
    private var hasOrigin = false
    private var lastFiniteVelocity: Float = 0

    public init() {}

    /// Starts a fresh stroke cursor and returns its zero velocity.
    @discardableResult
    public mutating func begin(
        at position: WorldPoint,
        time: TimeInterval
    ) -> Float {
        reset()
        guard Self.isFinite(position), time.isFinite else {
            return lastFiniteVelocity
        }
        originPosition = position
        originTime = time
        hasOrigin = true
        return lastFiniteVelocity
    }

    /// Incorporates one raw world-space sample and returns the filtered speed.
    @discardableResult
    public mutating func update(
        to position: WorldPoint,
        time: TimeInterval
    ) -> Float {
        guard Self.isFinite(position), time.isFinite else {
            return lastFiniteVelocity
        }

        guard hasOrigin else {
            originPosition = position
            originTime = time
            hasOrigin = true
            return lastFiniteVelocity
        }

        let deltaTime = time - originTime
        guard deltaTime.isFinite, deltaTime > 0 else {
            return lastFiniteVelocity
        }
        guard !isBelowMinimumDelta(deltaTime) else {
            return lastFiniteVelocity
        }

        let speed = clampedSpeed(
            from: originPosition,
            to: position,
            over: deltaTime
        )
        let windowStart = time - Self.windowDuration
        guard windowStart.isFinite else {
            return lastFiniteVelocity
        }

        removeSegments(endingAtOrBefore: windowStart, currentTime: time)
        appendSegment(
            start: originTime,
            end: time,
            duration: deltaTime,
            speed: speed
        )
        originPosition = position
        originTime = time

        let velocity = filteredVelocity(through: time, from: windowStart)
        if velocity.isFinite {
            lastFiniteVelocity = velocity
        }
        return lastFiniteVelocity
    }

    public mutating func reset() {
        segmentSlots = StrokeVelocityFilterSegmentStorage()
        oldestSegmentIndex = 0
        segmentCount = 0
        capacityFallbackEvictionCount = 0
        segmentTimeBase = 0
        originPosition = WorldPoint(x: 0, y: 0)
        originTime = 0
        hasOrigin = false
        lastFiniteVelocity = 0
    }

    public var snapshot: Snapshot {
        Snapshot(
            velocity: lastFiniteVelocity,
            segmentCount: segmentCount
        )
    }

    var capacityFallbackEvictionCountForTesting: Int {
        capacityFallbackEvictionCount
    }

    private static func isFinite(_ point: WorldPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private func isBelowMinimumDelta(_ deltaTime: TimeInterval) -> Bool {
        let roundingAllowance =
            Self.minimumDeltaTime.ulp * Double(Self.segmentCapacity)
        return deltaTime < Self.minimumDeltaTime - roundingAllowance
    }

    private func clampedSpeed(
        from start: WorldPoint,
        to end: WorldPoint,
        over duration: TimeInterval
    ) -> Float {
        let deltaX = Double(end.x) - Double(start.x)
        let deltaY = Double(end.y) - Double(start.y)
        let distance = hypot(deltaX, deltaY)
        guard distance.isFinite else {
            return BrushInputContract.maximumWorldVelocity
        }
        let speed = distance / duration
        guard speed.isFinite else {
            return BrushInputContract.maximumWorldVelocity
        }
        return min(BrushInputContract.maximumWorldVelocity, Float(speed))
    }

    private mutating func removeSegments(
        endingAtOrBefore windowStart: TimeInterval,
        currentTime: TimeInterval
    ) {
        let relativeCurrentTime = currentTime - segmentTimeBase
        let relativeWindowStart = relativeWindowStart(
            absoluteWindowStart: windowStart,
            currentTime: currentTime,
            relativeCurrentTime: relativeCurrentTime
        )
        while segmentCount > 0,
              endsAtOrBeforeWindowStart(
                  Double(
                      segmentSlots.segment(at: oldestSegmentIndex).endOffset
                  ),
                  windowStart: relativeWindowStart,
                  currentTime: currentTime
              ) {
            oldestSegmentIndex = (oldestSegmentIndex + 1) % Self.segmentCapacity
            segmentCount -= 1
        }
    }

    private func endsAtOrBeforeWindowStart(
        _ end: TimeInterval,
        windowStart: TimeInterval,
        currentTime: TimeInterval
    ) -> Bool {
        if end <= windowStart {
            return true
        }
        let absoluteEnd = segmentTimeBase + end
        let boundary = absoluteEnd + Self.windowDuration
        return boundary.isFinite && boundary <= currentTime
    }

    private mutating func appendSegment(
        start: TimeInterval,
        end: TimeInterval,
        duration: TimeInterval,
        speed: Float
    ) {
        if segmentCount == 0 {
            segmentTimeBase = end
        }
        if segmentCount == Self.segmentCapacity {
            oldestSegmentIndex = (oldestSegmentIndex + 1) % Self.segmentCapacity
            segmentCount -= 1
            capacityFallbackEvictionCount += 1
        }

        let index = (oldestSegmentIndex + segmentCount) % Self.segmentCapacity
        let startOffset: Float
        let endOffset: Float
        if segmentCount == 0 {
            startOffset = -Float(min(duration, Self.windowDuration))
            endOffset = 0
        } else {
            startOffset = Float(start - segmentTimeBase)
            endOffset = Float(end - segmentTimeBase)
        }
        precondition(
            startOffset.isFinite && endOffset.isFinite,
            "Velocity-window offsets must remain finite"
        )
        segmentSlots.set(
            StrokeVelocityFilterSegment(
                startOffset: startOffset,
                endOffset: endOffset,
                speed: speed
            ),
            at: index
        )
        segmentCount += 1
    }

    private func filteredVelocity(
        through currentTime: TimeInterval,
        from windowStart: TimeInterval
    ) -> Float {
        var weightedDistance = 0.0
        var coveredDuration = 0.0
        let relativeCurrentTime = currentTime - segmentTimeBase
        let relativeWindowStart = relativeWindowStart(
            absoluteWindowStart: windowStart,
            currentTime: currentTime,
            relativeCurrentTime: relativeCurrentTime
        )

        for offset in 0..<segmentCount {
            let index = (oldestSegmentIndex + offset) % Self.segmentCapacity
            let segment = segmentSlots.segment(at: index)
            let overlapStart = max(
                Double(segment.startOffset),
                relativeWindowStart
            )
            let overlapEnd = min(
                Double(segment.endOffset),
                relativeCurrentTime
            )
            let overlap = overlapEnd - overlapStart
            guard overlap.isFinite, overlap > 0 else {
                continue
            }

            let weighted = Double(segment.speed) * overlap
            guard weighted.isFinite else {
                return lastFiniteVelocity
            }
            weightedDistance += weighted
            coveredDuration += overlap
        }

        guard
            weightedDistance.isFinite,
            coveredDuration.isFinite,
            coveredDuration > 0
        else {
            return lastFiniteVelocity
        }

        let result = weightedDistance / coveredDuration
        guard result.isFinite else {
            return lastFiniteVelocity
        }
        return min(BrushInputContract.maximumWorldVelocity, Float(result))
    }

    private func relativeWindowStart(
        absoluteWindowStart: TimeInterval,
        currentTime: TimeInterval,
        relativeCurrentTime: TimeInterval
    ) -> TimeInterval {
        if absoluteWindowStart < currentTime {
            return absoluteWindowStart - segmentTimeBase
        }
        return relativeCurrentTime - Self.windowDuration
    }

}

private struct StrokeVelocityFilterSegment: Equatable, Sendable {
    var startOffset: Float = 0
    var endOffset: Float = 0
    var speed: Float = 0
}

private struct StrokeVelocityFilterSegmentStorage: Equatable, Sendable {
    private var slot0 = StrokeVelocityFilterSegment()
    private var slot1 = StrokeVelocityFilterSegment()
    private var slot2 = StrokeVelocityFilterSegment()
    private var slot3 = StrokeVelocityFilterSegment()
    private var slot4 = StrokeVelocityFilterSegment()
    private var slot5 = StrokeVelocityFilterSegment()
    private var slot6 = StrokeVelocityFilterSegment()
    private var slot7 = StrokeVelocityFilterSegment()
    private var slot8 = StrokeVelocityFilterSegment()
    private var slot9 = StrokeVelocityFilterSegment()
    private var slot10 = StrokeVelocityFilterSegment()
    private var slot11 = StrokeVelocityFilterSegment()
    private var slot12 = StrokeVelocityFilterSegment()
    private var slot13 = StrokeVelocityFilterSegment()
    private var slot14 = StrokeVelocityFilterSegment()
    private var slot15 = StrokeVelocityFilterSegment()
    private var slot16 = StrokeVelocityFilterSegment()
    private var slot17 = StrokeVelocityFilterSegment()
    private var slot18 = StrokeVelocityFilterSegment()
    private var slot19 = StrokeVelocityFilterSegment()
    private var slot20 = StrokeVelocityFilterSegment()
    private var slot21 = StrokeVelocityFilterSegment()
    private var slot22 = StrokeVelocityFilterSegment()
    private var slot23 = StrokeVelocityFilterSegment()
    private var slot24 = StrokeVelocityFilterSegment()
    private var slot25 = StrokeVelocityFilterSegment()
    private var slot26 = StrokeVelocityFilterSegment()
    private var slot27 = StrokeVelocityFilterSegment()
    private var slot28 = StrokeVelocityFilterSegment()
    private var slot29 = StrokeVelocityFilterSegment()
    private var slot30 = StrokeVelocityFilterSegment()
    private var slot31 = StrokeVelocityFilterSegment()
    private var slot32 = StrokeVelocityFilterSegment()
    private var slot33 = StrokeVelocityFilterSegment()
    private var slot34 = StrokeVelocityFilterSegment()
    private var slot35 = StrokeVelocityFilterSegment()
    private var slot36 = StrokeVelocityFilterSegment()
    private var slot37 = StrokeVelocityFilterSegment()
    private var slot38 = StrokeVelocityFilterSegment()
    private var slot39 = StrokeVelocityFilterSegment()
    private var slot40 = StrokeVelocityFilterSegment()
    private var slot41 = StrokeVelocityFilterSegment()
    private var slot42 = StrokeVelocityFilterSegment()
    private var slot43 = StrokeVelocityFilterSegment()
    private var slot44 = StrokeVelocityFilterSegment()
    private var slot45 = StrokeVelocityFilterSegment()
    private var slot46 = StrokeVelocityFilterSegment()
    private var slot47 = StrokeVelocityFilterSegment()
    private var slot48 = StrokeVelocityFilterSegment()
    private var slot49 = StrokeVelocityFilterSegment()
    private var slot50 = StrokeVelocityFilterSegment()
    private var slot51 = StrokeVelocityFilterSegment()
    private var slot52 = StrokeVelocityFilterSegment()
    private var slot53 = StrokeVelocityFilterSegment()
    private var slot54 = StrokeVelocityFilterSegment()
    private var slot55 = StrokeVelocityFilterSegment()
    private var slot56 = StrokeVelocityFilterSegment()
    private var slot57 = StrokeVelocityFilterSegment()
    private var slot58 = StrokeVelocityFilterSegment()
    private var slot59 = StrokeVelocityFilterSegment()
    private var slot60 = StrokeVelocityFilterSegment()
    private var slot61 = StrokeVelocityFilterSegment()
    private var slot62 = StrokeVelocityFilterSegment()
    private var slot63 = StrokeVelocityFilterSegment()

    func segment(at index: Int) -> StrokeVelocityFilterSegment {
        switch index {
        case 0: slot0
        case 1: slot1
        case 2: slot2
        case 3: slot3
        case 4: slot4
        case 5: slot5
        case 6: slot6
        case 7: slot7
        case 8: slot8
        case 9: slot9
        case 10: slot10
        case 11: slot11
        case 12: slot12
        case 13: slot13
        case 14: slot14
        case 15: slot15
        case 16: slot16
        case 17: slot17
        case 18: slot18
        case 19: slot19
        case 20: slot20
        case 21: slot21
        case 22: slot22
        case 23: slot23
        case 24: slot24
        case 25: slot25
        case 26: slot26
        case 27: slot27
        case 28: slot28
        case 29: slot29
        case 30: slot30
        case 31: slot31
        case 32: slot32
        case 33: slot33
        case 34: slot34
        case 35: slot35
        case 36: slot36
        case 37: slot37
        case 38: slot38
        case 39: slot39
        case 40: slot40
        case 41: slot41
        case 42: slot42
        case 43: slot43
        case 44: slot44
        case 45: slot45
        case 46: slot46
        case 47: slot47
        case 48: slot48
        case 49: slot49
        case 50: slot50
        case 51: slot51
        case 52: slot52
        case 53: slot53
        case 54: slot54
        case 55: slot55
        case 56: slot56
        case 57: slot57
        case 58: slot58
        case 59: slot59
        case 60: slot60
        case 61: slot61
        case 62: slot62
        case 63: slot63
        default: preconditionFailure("Segment index must be in 0..<64.")
        }
    }

    mutating func set(
        _ segment: StrokeVelocityFilterSegment,
        at index: Int
    ) {
        switch index {
        case 0: slot0 = segment
        case 1: slot1 = segment
        case 2: slot2 = segment
        case 3: slot3 = segment
        case 4: slot4 = segment
        case 5: slot5 = segment
        case 6: slot6 = segment
        case 7: slot7 = segment
        case 8: slot8 = segment
        case 9: slot9 = segment
        case 10: slot10 = segment
        case 11: slot11 = segment
        case 12: slot12 = segment
        case 13: slot13 = segment
        case 14: slot14 = segment
        case 15: slot15 = segment
        case 16: slot16 = segment
        case 17: slot17 = segment
        case 18: slot18 = segment
        case 19: slot19 = segment
        case 20: slot20 = segment
        case 21: slot21 = segment
        case 22: slot22 = segment
        case 23: slot23 = segment
        case 24: slot24 = segment
        case 25: slot25 = segment
        case 26: slot26 = segment
        case 27: slot27 = segment
        case 28: slot28 = segment
        case 29: slot29 = segment
        case 30: slot30 = segment
        case 31: slot31 = segment
        case 32: slot32 = segment
        case 33: slot33 = segment
        case 34: slot34 = segment
        case 35: slot35 = segment
        case 36: slot36 = segment
        case 37: slot37 = segment
        case 38: slot38 = segment
        case 39: slot39 = segment
        case 40: slot40 = segment
        case 41: slot41 = segment
        case 42: slot42 = segment
        case 43: slot43 = segment
        case 44: slot44 = segment
        case 45: slot45 = segment
        case 46: slot46 = segment
        case 47: slot47 = segment
        case 48: slot48 = segment
        case 49: slot49 = segment
        case 50: slot50 = segment
        case 51: slot51 = segment
        case 52: slot52 = segment
        case 53: slot53 = segment
        case 54: slot54 = segment
        case 55: slot55 = segment
        case 56: slot56 = segment
        case 57: slot57 = segment
        case 58: slot58 = segment
        case 59: slot59 = segment
        case 60: slot60 = segment
        case 61: slot61 = segment
        case 62: slot62 = segment
        case 63: slot63 = segment
        default: preconditionFailure("Segment index must be in 0..<64.")
        }
    }
}
