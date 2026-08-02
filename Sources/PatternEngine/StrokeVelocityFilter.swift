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

    private var segmentStartTimes = SIMD64<TimeInterval>(repeating: 0)
    private var segmentEndTimes = SIMD64<TimeInterval>(repeating: 0)
    private var segmentSpeeds = SIMD64<Float>(repeating: 0)
    private var oldestSegmentIndex = 0
    private var segmentCount = 0
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
        guard deltaTime >= Self.minimumDeltaTime else {
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

        removeSegments(
            endingAtOrBefore: windowStart,
            currentTime: time
        )
        appendSegment(
            start: originTime,
            end: time,
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
        segmentStartTimes = SIMD64(repeating: 0)
        segmentEndTimes = SIMD64(repeating: 0)
        segmentSpeeds = SIMD64(repeating: 0)
        oldestSegmentIndex = 0
        segmentCount = 0
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

    private static func isFinite(_ point: WorldPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
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
        while segmentCount > 0,
              endsAtOrBeforeWindowStart(
                  segmentEndTimes[oldestSegmentIndex],
                  windowStart: windowStart,
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
        let elapsed = currentTime - end
        let tolerance = max(currentTime.ulp, end.ulp) * 8
        return elapsed >= Self.windowDuration - tolerance
    }

    private mutating func appendSegment(
        start: TimeInterval,
        end: TimeInterval,
        speed: Float
    ) {
        if segmentCount == Self.segmentCapacity {
            oldestSegmentIndex = (oldestSegmentIndex + 1) % Self.segmentCapacity
            segmentCount -= 1
        }

        let index = (oldestSegmentIndex + segmentCount) % Self.segmentCapacity
        segmentStartTimes[index] = start
        segmentEndTimes[index] = end
        segmentSpeeds[index] = speed
        segmentCount += 1
    }

    private func filteredVelocity(
        through currentTime: TimeInterval,
        from windowStart: TimeInterval
    ) -> Float {
        var weightedDistance = 0.0
        var coveredDuration = 0.0

        for offset in 0..<segmentCount {
            let index = (oldestSegmentIndex + offset) % Self.segmentCapacity
            let overlapStart = max(segmentStartTimes[index], windowStart)
            let overlapEnd = min(segmentEndTimes[index], currentTime)
            let overlap = overlapEnd - overlapStart
            guard overlap.isFinite, overlap > 0 else {
                continue
            }

            let weighted = Double(segmentSpeeds[index]) * overlap
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
}
