import Foundation

public enum TimedStrokeEmitterError: Error, Equatable, Sendable {
    case invalidTimeInterval
    case strokeAlreadyActive
    case strokeNotActive
    case invalidPoint
    case invalidProvenance
    case canonicalKeyOverflow
    case tickIndexOverflow
}

/// One fully attributed point consumed by recorded-time emission.
public struct TimedStrokePoint: Equatable, Sendable {
    public let sample: InterpolatedStrokeSample
    public let sourceDistance: Double
    public let direction: Float

    public init(
        sample: InterpolatedStrokeSample,
        sourceDistance: Double,
        direction: Float
    ) {
        self.sample = sample
        self.sourceDistance = sourceDistance
        self.direction = direction
    }
}

public struct TimedStrokeEmissionPage: Equatable, Sendable {
    public let emittedCount: Int
    public let hasMore: Bool
}

/// A copyable arithmetic cursor over a bounded page of recorded-time output.
public struct TimedStrokeEmissionCursor: Equatable, Sendable {
    private let originTimestamp: TimeInterval
    private let interval: TimeInterval
    private let startRelativeTime: TimeInterval
    private let endRelativeTime: TimeInterval
    private let start: TimedStrokePoint
    private let end: TimedStrokePoint
    private let provenance: StrokeEmissionProvenance
    private var beginCandidate: StrokeEmissionCandidate?
    private var finishCandidate: StrokeEmissionCandidate?
    private var nextTickIndex: Int64
    private let finalTickIndex: Int64

    fileprivate init(
        originTimestamp: TimeInterval,
        interval: TimeInterval,
        startRelativeTime: TimeInterval,
        endRelativeTime: TimeInterval,
        start: TimedStrokePoint,
        end: TimedStrokePoint,
        provenance: StrokeEmissionProvenance,
        beginCandidate: StrokeEmissionCandidate?,
        finishCandidate: StrokeEmissionCandidate?,
        nextTickIndex: Int64,
        finalTickIndex: Int64
    ) {
        self.originTimestamp = originTimestamp
        self.interval = interval
        self.startRelativeTime = startRelativeTime
        self.endRelativeTime = endRelativeTime
        self.start = start
        self.end = end
        self.provenance = provenance
        self.beginCandidate = beginCandidate
        self.finishCandidate = finishCandidate
        self.nextTickIndex = nextTickIndex
        self.finalTickIndex = finalTickIndex
    }

    public var isComplete: Bool {
        beginCandidate == nil
            && nextTickIndex > finalTickIndex
            && finishCandidate == nil
    }

    public var remainingCandidateCount: UInt64 {
        var result: UInt64 = beginCandidate == nil ? 0 : 1
        if nextTickIndex <= finalTickIndex {
            result += UInt64(finalTickIndex - nextTickIndex) + 1
        }
        if finishCandidate != nil {
            result += 1
        }
        return result
    }

    /// Emits at most one logical-batch page. Successfully accepted candidates
    /// advance the cursor one at a time, so a failed sink can safely retry.
    @discardableResult
    public mutating func emitNextPage(
        _ emit: (StrokeEmissionCandidate) throws -> Void
    ) throws -> TimedStrokeEmissionPage {
        var emittedCount = 0
        if let beginCandidate {
            try emit(beginCandidate)
            self.beginCandidate = nil
            emittedCount += 1
        }

        while emittedCount < LogicalDabBatch.maximumDabCount,
              nextTickIndex <= finalTickIndex
        {
            let candidate = try timedCandidate(at: nextTickIndex)
            try emit(candidate)
            nextTickIndex += 1
            emittedCount += 1
        }
        if emittedCount < LogicalDabBatch.maximumDabCount,
           nextTickIndex > finalTickIndex,
           let finishCandidate
        {
            try emit(finishCandidate)
            self.finishCandidate = nil
            emittedCount += 1
        }
        return TimedStrokeEmissionPage(
            emittedCount: emittedCount,
            hasMore: !isComplete
        )
    }

    private func timedCandidate(at tickIndex: Int64)
        throws -> StrokeEmissionCandidate
    {
        let relativeTime = Double(tickIndex) * interval
        let duration = endRelativeTime - startRelativeTime
        let doubleFraction = min(
            1,
            max(0, (relativeTime - startRelativeTime) / duration)
        )
        let sample = Self.interpolatedSample(
            from: start.sample,
            to: end.sample,
            fraction: doubleFraction,
            timestamp: originTimestamp + relativeTime
        )
        let sourceDistance = Self.stableLinear(
            start.sourceDistance,
            end.sourceDistance,
            fraction: doubleFraction
        )
        let direction = Self.stableLinear(
            start.direction,
            end.direction,
            fraction: doubleFraction
        )
        guard Self.isFinite(sample),
              sourceDistance.isFinite,
              direction.isFinite
        else {
            throw TimedStrokeEmitterError.invalidPoint
        }
        return StrokeEmissionCandidate(
            sample: sample,
            relativeStrokeTime: relativeTime,
            sourceDistance: sourceDistance,
            direction: direction,
            provenance: provenance,
            timeKey: try Self.canonicalKey(
                relativeTime,
                scale: 1_000_000_000
            ),
            distanceKey: try Self.canonicalKey(
                sourceDistance,
                scale: 1_000_000
            ),
            kind: .time,
            cornerSequence: 0
        )
    }

    private static func canonicalKey(
        _ value: Double,
        scale: Double
    ) throws -> Int64 {
        let scaled = value * scale
        guard scaled.isFinite,
              let key = Int64(exactly: scaled.rounded(.toNearestOrEven))
        else {
            throw TimedStrokeEmitterError.canonicalKeyOverflow
        }
        return key
    }

    private static func interpolatedSample(
        from start: InterpolatedStrokeSample,
        to end: InterpolatedStrokeSample,
        fraction: Double,
        timestamp: TimeInterval
    ) -> InterpolatedStrokeSample {
        let clamped = min(1, max(0, fraction))
        if clamped == 0 {
            return replacingTimestamp(of: start, with: timestamp)
        }
        if clamped == 1 {
            return replacingTimestamp(of: end, with: timestamp)
        }
        let discrete = clamped < 0.5 ? start : end
        return InterpolatedStrokeSample(
            position: WorldPoint(
                x: stableLinear(
                    start.position.x,
                    end.position.x,
                    fraction: clamped
                ),
                y: stableLinear(
                    start.position.y,
                    end.position.y,
                    fraction: clamped
                )
            ),
            pressure: stableLinear(
                start.pressure,
                end.pressure,
                fraction: clamped
            ),
            timestamp: timestamp,
            altitude: optionalLinear(
                start.altitude,
                end.altitude,
                fraction: clamped
            ),
            azimuth: optionalAngle(
                start.azimuth,
                end.azimuth,
                fraction: clamped
            ),
            roll: optionalAngle(
                start.roll,
                end.roll,
                fraction: clamped
            ),
            velocity: stableLinear(
                start.velocity,
                end.velocity,
                fraction: clamped
            ),
            phase: discrete.phase,
            source: discrete.source,
            kind: discrete.kind,
            capabilities: discrete.capabilities,
            tangentialPressure: optionalLinear(
                start.tangentialPressure,
                end.tangentialPressure,
                fraction: clamped
            ),
            deviceIdentifier: discrete.deviceIdentifier,
            estimationUpdateIndex: discrete.estimationUpdateIndex,
            estimatedProperties: discrete.estimatedProperties,
            estimatedPropertiesExpectingUpdates:
                discrete.estimatedPropertiesExpectingUpdates
        )
    }

    private static func replacingTimestamp(
        of sample: InterpolatedStrokeSample,
        with timestamp: TimeInterval
    ) -> InterpolatedStrokeSample {
        InterpolatedStrokeSample(
            position: sample.position,
            pressure: sample.pressure,
            timestamp: timestamp,
            altitude: sample.altitude,
            azimuth: sample.azimuth,
            roll: sample.roll,
            velocity: sample.velocity,
            phase: sample.phase,
            source: sample.source,
            kind: sample.kind,
            capabilities: sample.capabilities,
            tangentialPressure: sample.tangentialPressure,
            deviceIdentifier: sample.deviceIdentifier,
            estimationUpdateIndex: sample.estimationUpdateIndex,
            estimatedProperties: sample.estimatedProperties,
            estimatedPropertiesExpectingUpdates:
                sample.estimatedPropertiesExpectingUpdates
        )
    }

    private static func optionalLinear(
        _ start: Float?,
        _ end: Float?,
        fraction: Double
    ) -> Float? {
        guard let start, let end else { return nil }
        return stableLinear(start, end, fraction: fraction)
    }

    private static func optionalAngle(
        _ start: Float?,
        _ end: Float?,
        fraction: Double
    ) -> Float? {
        guard let start, let end else { return nil }
        let fullTurn = 2 * Double.pi
        let normalizedStart = normalizedAngle(Double(start), fullTurn: fullTurn)
        let normalizedEnd = normalizedAngle(Double(end), fullTurn: fullTurn)
        var delta = (normalizedEnd - normalizedStart).truncatingRemainder(
            dividingBy: fullTurn
        )
        if delta > Double.pi {
            delta -= fullTurn
        } else if delta < -Double.pi {
            delta += fullTurn
        }
        return Float(normalizedAngle(
            normalizedStart + delta * fraction,
            fullTurn: fullTurn
        ))
    }

    private static func normalizedAngle(
        _ value: Double,
        fullTurn: Double
    ) -> Double {
        var result = value.truncatingRemainder(dividingBy: fullTurn)
        if result > Double.pi {
            result -= fullTurn
        } else if result < -Double.pi {
            result += fullTurn
        }
        return result
    }

    private static func stableLinear(
        _ start: Float,
        _ end: Float,
        fraction: Double
    ) -> Float {
        Float(stableLinear(Double(start), Double(end), fraction: fraction))
    }

    private static func stableLinear(
        _ start: Double,
        _ end: Double,
        fraction: Double
    ) -> Double {
        if start.sign == end.sign {
            return start + (end - start) * fraction
        }
        return start * (1 - fraction) + end * fraction
    }

    private static func isFinite(_ sample: InterpolatedStrokeSample) -> Bool {
        sample.position.x.isFinite
            && sample.position.y.isFinite
            && sample.pressure.isFinite
            && sample.timestamp.isFinite
            && sample.velocity.isFinite
            && sample.altitude?.isFinite != false
            && sample.azimuth?.isFinite != false
            && sample.roll?.isFinite != false
            && sample.tangentialPressure?.isFinite != false
    }
}

/// Pure, sample-driven recorded-time candidate state.
public struct TimedStrokeEmitter: Equatable, Sendable {
    public let timeInterval: TimeInterval

    private var originTimestamp: TimeInterval?
    private var previous: TimedStrokePoint?
    private var previousRelativeTime: TimeInterval?
    private var nextTickIndex: Int64

    public init(timeInterval: TimeInterval) throws {
        guard timeInterval.isFinite,
              timeInterval >= 1.0 / 240,
              timeInterval <= 10
        else {
            throw TimedStrokeEmitterError.invalidTimeInterval
        }
        self.timeInterval = timeInterval
        originTimestamp = nil
        previous = nil
        previousRelativeTime = nil
        nextTickIndex = 1
    }

    public mutating func begin(
        at point: TimedStrokePoint
    ) throws -> TimedStrokeEmissionCursor {
        guard originTimestamp == nil else {
            throw TimedStrokeEmitterError.strokeAlreadyActive
        }
        try Self.validate(point)
        try Self.validateAuthoritativeProvenance(point)
        let distanceKey = try Self.canonicalKey(
            point.sourceDistance,
            scale: 1_000_000
        )
        let candidate = StrokeEmissionCandidate(
            sample: point.sample,
            relativeStrokeTime: 0,
            sourceDistance: point.sourceDistance,
            direction: point.direction,
            provenance: .authoritative,
            timeKey: 0,
            distanceKey: distanceKey,
            kind: .begin,
            cornerSequence: 0
        )
        originTimestamp = point.sample.timestamp
        previous = point
        previousRelativeTime = 0
        nextTickIndex = 1
        return TimedStrokeEmissionCursor(
            originTimestamp: point.sample.timestamp,
            interval: timeInterval,
            startRelativeTime: 0,
            endRelativeTime: 0,
            start: point,
            end: point,
            provenance: .authoritative,
            beginCandidate: candidate,
            finishCandidate: nil,
            nextTickIndex: 1,
            finalTickIndex: 0
        )
    }

    public mutating func advance(
        to point: TimedStrokePoint
    ) throws -> TimedStrokeEmissionCursor? {
        guard let originTimestamp, let previous, let previousRelativeTime else {
            throw TimedStrokeEmitterError.strokeNotActive
        }
        guard point.sample.timestamp.isFinite,
              point.sample.timestamp > previous.sample.timestamp
        else {
            return nil
        }
        try Self.validate(point)
        try Self.validateAuthoritativeProvenance(point)
        guard point.sourceDistance >= previous.sourceDistance else {
            throw TimedStrokeEmitterError.invalidPoint
        }
        let relativeTime = point.sample.timestamp - originTimestamp
        _ = try Self.canonicalKey(relativeTime, scale: 1_000_000_000)
        let finalTickIndex = try Self.lastTickIndex(
            through: relativeTime,
            interval: timeInterval
        )
        let firstTickIndex = nextTickIndex
        let nextIndex: Int64
        if finalTickIndex >= firstTickIndex {
            let (value, overflow) = finalTickIndex.addingReportingOverflow(1)
            guard !overflow else {
                throw TimedStrokeEmitterError.tickIndexOverflow
            }
            nextIndex = value
        } else {
            nextIndex = firstTickIndex
        }

        self.previous = point
        self.previousRelativeTime = relativeTime
        nextTickIndex = nextIndex
        guard finalTickIndex >= firstTickIndex else { return nil }
        return TimedStrokeEmissionCursor(
            originTimestamp: originTimestamp,
            interval: timeInterval,
            startRelativeTime: previousRelativeTime,
            endRelativeTime: relativeTime,
            start: previous,
            end: point,
            provenance: .authoritative,
            beginCandidate: nil,
            finishCandidate: nil,
            nextTickIndex: firstTickIndex,
            finalTickIndex: finalTickIndex
        )
    }

    /// Evaluates speculative ticks from a value copy of authoritative state.
    public mutating func prediction(
        to point: TimedStrokePoint
    ) throws -> TimedStrokeEmissionCursor? {
        guard let originTimestamp, let previous, let previousRelativeTime else {
            throw TimedStrokeEmitterError.strokeNotActive
        }
        guard point.sample.timestamp.isFinite,
              point.sample.timestamp > previous.sample.timestamp
        else {
            return nil
        }
        try Self.validate(point)
        guard point.sample.kind == .predicted else {
            throw TimedStrokeEmitterError.invalidProvenance
        }
        guard point.sourceDistance >= previous.sourceDistance else {
            throw TimedStrokeEmitterError.invalidPoint
        }
        let relativeTime = point.sample.timestamp - originTimestamp
        _ = try Self.canonicalKey(relativeTime, scale: 1_000_000_000)
        let finalTickIndex = try Self.lastTickIndex(
            through: relativeTime,
            interval: timeInterval
        )
        let firstTickIndex = nextTickIndex
        let nextIndex: Int64
        if finalTickIndex >= firstTickIndex {
            nextIndex = try Self.indexAfter(finalTickIndex)
        } else {
            nextIndex = firstTickIndex
        }
        self.previous = point
        self.previousRelativeTime = relativeTime
        nextTickIndex = nextIndex
        guard finalTickIndex >= firstTickIndex else { return nil }
        return TimedStrokeEmissionCursor(
            originTimestamp: originTimestamp,
            interval: timeInterval,
            startRelativeTime: previousRelativeTime,
            endRelativeTime: relativeTime,
            start: previous,
            end: point,
            provenance: .prediction,
            beginCandidate: nil,
            finishCandidate: nil,
            nextTickIndex: firstTickIndex,
            finalTickIndex: finalTickIndex
        )
    }

    /// Catches up authoritative time and optionally contributes the exact
    /// termination endpoint before resetting for immediate reuse.
    public mutating func finish(
        at point: TimedStrokePoint,
        endpointAlreadySupplied: Bool = false
    ) throws -> TimedStrokeEmissionCursor {
        guard let originTimestamp, let previous, let previousRelativeTime else {
            throw TimedStrokeEmitterError.strokeNotActive
        }
        try Self.validate(point)
        try Self.validateAuthoritativeProvenance(point)
        guard point.sample.timestamp >= previous.sample.timestamp,
              point.sourceDistance >= previous.sourceDistance
        else {
            throw TimedStrokeEmitterError.invalidPoint
        }
        let relativeTime = point.sample.timestamp - originTimestamp
        let timeKey = try Self.canonicalKey(
            relativeTime,
            scale: 1_000_000_000
        )
        let distanceKey = try Self.canonicalKey(
            point.sourceDistance,
            scale: 1_000_000
        )
        let finalTickIndex = try Self.lastTickIndex(
            through: relativeTime,
            interval: timeInterval
        )
        if finalTickIndex >= nextTickIndex {
            _ = try Self.indexAfter(finalTickIndex)
        }
        let finishCandidate = endpointAlreadySupplied ? nil :
            StrokeEmissionCandidate(
                sample: point.sample,
                relativeStrokeTime: relativeTime,
                sourceDistance: point.sourceDistance,
                direction: point.direction,
                provenance: .authoritative,
                timeKey: timeKey,
                distanceKey: distanceKey,
                kind: .finish,
                cornerSequence: 0
            )
        let cursor = TimedStrokeEmissionCursor(
            originTimestamp: originTimestamp,
            interval: timeInterval,
            startRelativeTime: previousRelativeTime,
            endRelativeTime: relativeTime,
            start: previous,
            end: point,
            provenance: .authoritative,
            beginCandidate: nil,
            finishCandidate: finishCandidate,
            nextTickIndex: nextTickIndex,
            finalTickIndex: finalTickIndex
        )
        reset()
        return cursor
    }

    public mutating func reset() {
        originTimestamp = nil
        previous = nil
        previousRelativeTime = nil
        nextTickIndex = 1
    }

    public mutating func cancel() {
        reset()
    }

    private static func validate(_ point: TimedStrokePoint) throws {
        let sample = point.sample
        guard sample.position.x.isFinite,
              sample.position.y.isFinite,
              sample.pressure.isFinite,
              sample.timestamp.isFinite,
              sample.velocity.isFinite,
              sample.altitude?.isFinite != false,
              sample.azimuth?.isFinite != false,
              sample.roll?.isFinite != false,
              sample.tangentialPressure?.isFinite != false,
              point.sourceDistance.isFinite,
              point.sourceDistance >= 0,
              point.direction.isFinite
        else {
            throw TimedStrokeEmitterError.invalidPoint
        }
        _ = try canonicalKey(point.sourceDistance, scale: 1_000_000)
    }

    private static func validateAuthoritativeProvenance(
        _ point: TimedStrokePoint
    ) throws {
        guard point.sample.kind == .actual
                || point.sample.kind == .coalesced
        else {
            throw TimedStrokeEmitterError.invalidProvenance
        }
    }

    private static func canonicalKey(
        _ value: Double,
        scale: Double
    ) throws -> Int64 {
        let scaled = value * scale
        guard scaled.isFinite,
              let key = Int64(exactly: scaled.rounded(.toNearestOrEven))
        else {
            throw TimedStrokeEmitterError.canonicalKeyOverflow
        }
        return key
    }

    private static func lastTickIndex(
        through relativeTime: TimeInterval,
        interval: TimeInterval
    ) throws -> Int64 {
        let quotient = relativeTime / interval
        guard quotient.isFinite,
              var index = Int64(exactly: quotient.rounded(.down))
        else {
            throw TimedStrokeEmitterError.tickIndexOverflow
        }
        let endpointKey = try canonicalKey(
            relativeTime,
            scale: 1_000_000_000
        )
        if index > 0 {
            let tickKey = try canonicalKey(
                Double(index) * interval,
                scale: 1_000_000_000
            )
            if tickKey > endpointKey {
                index -= 1
            }
        }
        let (followingIndex, followingOverflow) =
            index.addingReportingOverflow(1)
        if !followingOverflow,
           let followingKey = try? canonicalKey(
                Double(followingIndex) * interval,
                scale: 1_000_000_000
           ),
           followingKey <= endpointKey
        {
            index = followingIndex
        }
        return index
    }

    private static func indexAfter(_ index: Int64) throws -> Int64 {
        let (next, overflow) = index.addingReportingOverflow(1)
        guard !overflow else {
            throw TimedStrokeEmitterError.tickIndexOverflow
        }
        return next
    }
}
