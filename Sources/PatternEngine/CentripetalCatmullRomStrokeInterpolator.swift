import Foundation
import simd

/// A fully attributed point on the deterministic stroke path.
public struct InterpolatedStrokeSample: Equatable, Sendable {
    public let position: WorldPoint
    public let pressure: Float
    public let timestamp: TimeInterval
    public let altitude: Float?
    public let azimuth: Float?
    public let roll: Float?
    public let velocity: Float
    public let phase: StrokePhase
    public let source: StrokeSource
    public let kind: StrokeSampleKind
    public let capabilities: StrokeInputCapabilities

    public init(
        position: WorldPoint,
        pressure: Float,
        timestamp: TimeInterval,
        altitude: Float?,
        azimuth: Float?,
        roll: Float?,
        velocity: Float,
        phase: StrokePhase,
        source: StrokeSource,
        kind: StrokeSampleKind,
        capabilities: StrokeInputCapabilities
    ) {
        self.position = position
        self.pressure = pressure
        self.timestamp = timestamp
        self.altitude = altitude
        self.azimuth = azimuth
        self.roll = roll
        self.velocity = velocity
        self.phase = phase
        self.source = source
        self.kind = kind
        self.capabilities = capabilities
    }

    public init(_ sample: WorldStrokeSample) {
        self.init(
            position: sample.position,
            pressure: sample.pressure,
            timestamp: sample.timestamp,
            altitude: sample.altitude,
            azimuth: sample.azimuth,
            roll: sample.roll,
            velocity: sample.velocity,
            phase: sample.phase,
            source: sample.source,
            kind: sample.kind,
            capabilities: sample.capabilities
        )
    }

    fileprivate func interpolated(
        to end: InterpolatedStrokeSample,
        fraction: Float,
        position: WorldPoint
    ) -> InterpolatedStrokeSample {
        let clamped = min(1, max(0, fraction))
        if clamped == 0 {
            return replacingPosition(position)
        }
        if clamped == 1 {
            return end.replacingPosition(position)
        }

        return InterpolatedStrokeSample(
            position: position,
            pressure: lerp(pressure, end.pressure, clamped),
            timestamp: timestamp
                + (end.timestamp - timestamp) * TimeInterval(clamped),
            altitude: Self.optionalLinear(altitude, end.altitude, clamped),
            azimuth: Self.optionalAngle(azimuth, end.azimuth, clamped),
            roll: Self.optionalAngle(roll, end.roll, clamped),
            velocity: lerp(velocity, end.velocity, clamped),
            phase: end.phase,
            source: end.source,
            kind: end.kind,
            capabilities: end.capabilities
        )
    }

    private func replacingPosition(
        _ position: WorldPoint
    ) -> InterpolatedStrokeSample {
        InterpolatedStrokeSample(
            position: position,
            pressure: pressure,
            timestamp: timestamp,
            altitude: altitude,
            azimuth: azimuth,
            roll: roll,
            velocity: velocity,
            phase: phase,
            source: source,
            kind: kind,
            capabilities: capabilities
        )
    }

    private static func optionalLinear(
        _ start: Float?,
        _ end: Float?,
        _ fraction: Float
    ) -> Float? {
        guard let start, let end else { return nil }
        return lerp(start, end, fraction)
    }

    private static func optionalAngle(
        _ start: Float?,
        _ end: Float?,
        _ fraction: Float
    ) -> Float? {
        guard let start, let end else { return nil }
        let fullTurn = 2 * Float.pi
        var delta = (end - start).truncatingRemainder(
            dividingBy: fullTurn
        )
        if delta > .pi {
            delta -= fullTurn
        } else if delta < -.pi {
            delta += fullTurn
        }
        var result = start + delta * fraction
        if result > .pi {
            result -= fullTurn
        } else if result < -.pi {
            result += fullTurn
        }
        return result
    }
}

private func lerp(_ start: Float, _ end: Float, _ fraction: Float) -> Float {
    start + (end - start) * fraction
}

/// One short linearized segment of an attributed Catmull-Rom path.
public struct AttributedStrokePathSegment: Equatable, Sendable {
    public let start: InterpolatedStrokeSample
    public let end: InterpolatedStrokeSample

    public var length: Float {
        simd_distance(start.position.simd, end.position.simd)
    }

    public func sample(at fraction: Float) -> InterpolatedStrokeSample {
        let clamped = min(1, max(0, fraction))
        let position = WorldPoint(
            start.position.simd
                + (end.position.simd - start.position.simd) * clamped
        )
        return start.interpolated(
            to: end,
            fraction: clamped,
            position: position
        )
    }

    func sample(
        at fraction: Float,
        exactPosition: WorldPoint
    ) -> InterpolatedStrokeSample {
        if exactPosition == start.position {
            return start
        }
        if exactPosition == end.position {
            return end
        }
        return start.interpolated(
            to: end,
            fraction: fraction,
            position: exactPosition
        )
    }
}

/// Converts attributed control points into deterministic short path segments.
/// Dab spacing is deliberately owned by the downstream stroke generator.
public struct CentripetalCatmullRomPathInterpolator: Equatable, Sendable {
    public let maximumSegmentLength: Float

    private let minimumSubdivisionEstimate: Float
    private var beforePrevious: InterpolatedStrokeSample?
    private var previous: InterpolatedStrokeSample?

    public init(
        maximumSegmentLength: Float = 0.5,
        minimumSubdivisionEstimate: Float? = nil
    ) {
        self.init(
            maximumSegmentLength: maximumSegmentLength,
            validatedMinimumSubdivisionEstimate:
                minimumSubdivisionEstimate ?? maximumSegmentLength
        )
    }

    private init(
        maximumSegmentLength: Float,
        validatedMinimumSubdivisionEstimate minimumSubdivisionEstimate: Float
    ) {
        precondition(
            maximumSegmentLength.isFinite && maximumSegmentLength > 0,
            "Maximum path segment length must be finite and positive"
        )
        precondition(
            minimumSubdivisionEstimate.isFinite
                && minimumSubdivisionEstimate > 0,
            "Minimum subdivision estimate must be finite and positive"
        )
        self.maximumSegmentLength = maximumSegmentLength
        self.minimumSubdivisionEstimate = minimumSubdivisionEstimate
        beforePrevious = nil
        previous = nil
    }

    @discardableResult
    public mutating func begin(
        at sample: InterpolatedStrokeSample
    ) -> InterpolatedStrokeSample {
        beforePrevious = sample
        previous = sample
        return sample
    }

    public mutating func append(
        _ current: InterpolatedStrokeSample,
        emit: (AttributedStrokePathSegment) throws -> Void
    ) rethrows {
        guard let p1 = previous, let p0 = beforePrevious else {
            _ = begin(at: current)
            return
        }

        let estimate = max(
            simd_distance(p0.position.simd, p1.position.simd)
                + simd_distance(p1.position.simd, current.position.simd),
            minimumSubdivisionEstimate
        )
        let subdivisions = max(
            1,
            Int(ceil(estimate / maximumSegmentLength))
        )
        var lineStart = p1

        for step in 1...subdivisions {
            let fraction = Float(step) / Float(subdivisions)
            let position = Self.samplePosition(
                p0: p0.position,
                p1: p1.position,
                p2: current.position,
                p3: current.position,
                u: fraction
            )
            let lineEnd = p1.interpolated(
                to: current,
                fraction: fraction,
                position: position
            )
            try emit(AttributedStrokePathSegment(
                start: lineStart,
                end: lineEnd
            ))
            lineStart = lineEnd
        }

        beforePrevious = p1
        previous = current
    }

    @discardableResult
    public mutating func finish(
        at finalSample: InterpolatedStrokeSample,
        emit: (AttributedStrokePathSegment) throws -> Void
    ) rethrows -> InterpolatedStrokeSample {
        if previous?.position != finalSample.position {
            try append(finalSample, emit: emit)
        }
        cancel()
        return finalSample
    }

    public mutating func cancel() {
        beforePrevious = nil
        previous = nil
    }

    fileprivate static func samplePosition(
        p0: WorldPoint,
        p1: WorldPoint,
        p2: WorldPoint,
        p3: WorldPoint,
        u: Float
    ) -> WorldPoint {
        let incoming = p1.simd - p0.simd
        let outgoing = p2.simd - p1.simd
        let cross = incoming.x * outgoing.y - incoming.y * outgoing.x
        if abs(cross) < 0.0001 {
            return WorldPoint(p1.simd + outgoing * u)
        }
        let epsilon: Float = 0.0001
        let dt0 = max(epsilon, sqrt(simd_distance(p0.simd, p1.simd)))
        let dt1 = max(epsilon, sqrt(simd_distance(p1.simd, p2.simd)))
        let dt2 = max(epsilon, sqrt(simd_distance(p2.simd, p3.simd)))
        // Keep SIMD operations discrete and explicitly typed so different Swift
        // compiler versions can resolve the overloaded operators reliably.
        let d20: SIMD2<Float> = p2.simd - p0.simd
        let d31: SIMD2<Float> = p3.simd - p1.simd
        let d32: SIMD2<Float> = p3.simd - p2.simd
        let m1a: SIMD2<Float> = incoming / dt0
        let m1b: SIMD2<Float> = d20 / (dt0 + dt1)
        let m1c: SIMD2<Float> = outgoing / dt1
        let m2a: SIMD2<Float> = outgoing / dt1
        let m2b: SIMD2<Float> = d31 / (dt1 + dt2)
        let m2c: SIMD2<Float> = d32 / dt2
        var m1 = m1a - m1b + m1c
        var m2 = m2a - m2b + m2c
        m1 *= dt1
        m2 *= dt1
        let u2 = u * u
        let u3 = u2 * u
        return WorldPoint(
            (2 * u3 - 3 * u2 + 1) * p1.simd
                + (u3 - 2 * u2 + u) * m1
                + (-2 * u3 + 3 * u2) * p2.simd
                + (u3 - u2) * m2
        )
    }
}

/// Fixed-spacing attributed compatibility walker.
///
/// Slice 4's generator consumes `CentripetalCatmullRomPathInterpolator`
/// directly and owns dynamic spacing. This value exists to pin attributed
/// interpolation and to keep legacy placement exact during migration.
public struct AttributedStrokeInterpolator: Equatable, Sendable {
    public let spacing: Float

    private var path: CentripetalCatmullRomPathInterpolator
    private var lastInputPosition: WorldPoint?
    private var lastEmitted: InterpolatedStrokeSample?
    private var distanceUntilNext: Float

    public init(spacing: Float) {
        precondition(
            spacing.isFinite && spacing > 0,
            "Stroke spacing must be finite and positive"
        )
        self.spacing = spacing
        path = CentripetalCatmullRomPathInterpolator(
            maximumSegmentLength: min(0.5, spacing * 0.2),
            minimumSubdivisionEstimate: spacing
        )
        lastInputPosition = nil
        lastEmitted = nil
        distanceUntilNext = spacing
    }

    public mutating func begin(
        at sample: InterpolatedStrokeSample,
        emit: (InterpolatedStrokeSample) throws -> Void
    ) rethrows {
        resetState()
        _ = path.begin(at: sample)
        lastInputPosition = sample.position
        lastEmitted = sample
        distanceUntilNext = spacing
        try emit(sample)
    }

    public mutating func append(
        _ current: InterpolatedStrokeSample,
        emit: (InterpolatedStrokeSample) throws -> Void
    ) rethrows {
        guard lastInputPosition != nil else {
            return try begin(at: current, emit: emit)
        }

        var updatedPath = path
        try updatedPath.append(current) { segment in
            try consume(segment, emit: emit)
        }
        path = updatedPath
        lastInputPosition = current.position
    }

    public mutating func finish(
        at finalSample: InterpolatedStrokeSample,
        emit: (InterpolatedStrokeSample) throws -> Void
    ) rethrows {
        if lastInputPosition != finalSample.position {
            try append(finalSample, emit: emit)
        }
        if lastEmitted?.position != finalSample.position {
            try emit(finalSample)
            lastEmitted = finalSample
        }
        resetState()
    }

    public mutating func cancel() {
        resetState()
    }

    private mutating func consume(
        _ segment: AttributedStrokePathSegment,
        emit: (InterpolatedStrokeSample) throws -> Void
    ) rethrows {
        var cursor = segment.start.position.simd
        let terminal = segment.end.position.simd
        let segmentLength = simd_distance(cursor, terminal)
        var remainingLength = segmentLength

        while remainingLength >= distanceUntilNext && remainingLength > 0 {
            let direction = (terminal - cursor) / remainingLength
            cursor += direction * distanceUntilNext
            let fraction = segmentLength > 0
                ? simd_distance(segment.start.position.simd, cursor)
                    / segmentLength
                : 1
            let sample = segment.sample(
                at: fraction,
                exactPosition: WorldPoint(cursor)
            )
            try emit(sample)
            lastEmitted = sample
            remainingLength = simd_distance(cursor, terminal)
            distanceUntilNext = spacing
        }

        distanceUntilNext -= remainingLength
    }

    private mutating func resetState() {
        path.cancel()
        lastInputPosition = nil
        lastEmitted = nil
        distanceUntilNext = spacing
    }
}

/// Legacy position-only wrapper retained until the new stroke generator owns
/// every renderer caller.
public struct CentripetalCatmullRomStrokeInterpolator: Sendable {
    public let spacing: Float

    private var attributed: AttributedStrokeInterpolator
    private var timestamp: TimeInterval

    public init(radius: Float) {
        precondition(radius > 0)
        spacing = max(1, min(8, radius * 0.25))
        attributed = AttributedStrokeInterpolator(spacing: spacing)
        timestamp = 0
    }

    public mutating func begin(
        at point: WorldPoint,
        emit: (WorldPoint) throws -> Void
    ) rethrows {
        timestamp = 0
        try attributed.begin(
            at: legacySample(position: point, phase: .began)
        ) { try emit($0.position) }
    }

    public mutating func append(
        _ current: WorldPoint,
        emit: (WorldPoint) throws -> Void
    ) rethrows {
        timestamp += 1
        try attributed.append(
            legacySample(position: current, phase: .moved)
        ) { try emit($0.position) }
    }

    public mutating func finish(
        at finalPoint: WorldPoint,
        emit: (WorldPoint) throws -> Void
    ) rethrows {
        timestamp += 1
        try attributed.finish(
            at: legacySample(position: finalPoint, phase: .ended)
        ) { try emit($0.position) }
    }

    public mutating func cancel() {
        attributed.cancel()
        timestamp = 0
    }

    private func legacySample(
        position: WorldPoint,
        phase: StrokePhase
    ) -> InterpolatedStrokeSample {
        InterpolatedStrokeSample(
            position: position,
            pressure: 0.5,
            timestamp: timestamp,
            altitude: nil,
            azimuth: nil,
            roll: nil,
            velocity: 0,
            phase: phase,
            source: .mouse,
            kind: .actual,
            capabilities: []
        )
    }
}
