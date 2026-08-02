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
    ) rethrows -> TimedStrokeEmissionPage {
        var emittedCount = 0
        if let beginCandidate {
            try emit(beginCandidate)
            self.beginCandidate = nil
            emittedCount += 1
        }

        while emittedCount < LogicalDabBatch.maximumDabCount,
              nextTickIndex <= finalTickIndex
        {
            let candidate = timedCandidate(at: nextTickIndex)
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
        -> StrokeEmissionCandidate
    {
        let relativeTime = Double(tickIndex) * interval
        let timestamp = originTimestamp + relativeTime
        let duration = end.sample.timestamp - start.sample.timestamp
        let doubleFraction = min(
            1,
            max(0, (timestamp - start.sample.timestamp) / duration)
        )
        let fraction = Float(doubleFraction)
        let interpolatedSample = AttributedStrokePathSegment(
            start: start.sample,
            end: end.sample
        ).sample(at: fraction)
        let sample = Self.replacingTimestamp(
            of: interpolatedSample,
            with: timestamp
        )
        let sourceDistance = start.sourceDistance
            + (end.sourceDistance - start.sourceDistance) * doubleFraction
        let direction = start.direction
            + (end.direction - start.direction) * fraction
        return StrokeEmissionCandidate(
            sample: sample,
            relativeStrokeTime: relativeTime,
            sourceDistance: sourceDistance,
            direction: direction,
            provenance: provenance,
            timeKey: Self.canonicalKey(relativeTime, scale: 1_000_000_000),
            distanceKey: Self.canonicalKey(
                sourceDistance,
                scale: 1_000_000
            ),
            kind: .time,
            cornerSequence: 0
        )
    }

    private static func canonicalKey(_ value: Double, scale: Double) -> Int64 {
        let rounded = (value * scale).rounded(.toNearestOrEven)
        return Int64(exactly: rounded)!
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
}

/// Pure, sample-driven recorded-time candidate state.
public struct TimedStrokeEmitter: Equatable, Sendable {
    public let timeInterval: TimeInterval

    private var originTimestamp: TimeInterval?
    private var previous: TimedStrokePoint?
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
        nextTickIndex = 1
        return TimedStrokeEmissionCursor(
            originTimestamp: point.sample.timestamp,
            interval: timeInterval,
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
        guard let originTimestamp, let previous else {
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
        nextTickIndex = nextIndex
        guard finalTickIndex >= firstTickIndex else { return nil }
        return TimedStrokeEmissionCursor(
            originTimestamp: originTimestamp,
            interval: timeInterval,
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
    public func prediction(
        to point: TimedStrokePoint
    ) throws -> TimedStrokeEmissionCursor? {
        guard let originTimestamp, let previous else {
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
        guard finalTickIndex >= nextTickIndex else { return nil }
        _ = try Self.indexAfter(finalTickIndex)
        return TimedStrokeEmissionCursor(
            originTimestamp: originTimestamp,
            interval: timeInterval,
            start: previous,
            end: point,
            provenance: .prediction,
            beginCandidate: nil,
            finishCandidate: nil,
            nextTickIndex: nextTickIndex,
            finalTickIndex: finalTickIndex
        )
    }

    /// Catches up authoritative time and optionally contributes the exact
    /// termination endpoint before resetting for immediate reuse.
    public mutating func finish(
        at point: TimedStrokePoint,
        endpointAlreadySupplied: Bool = false
    ) throws -> TimedStrokeEmissionCursor {
        guard let originTimestamp, let previous else {
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
