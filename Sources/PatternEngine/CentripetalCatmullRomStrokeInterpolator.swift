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
    public let tangentialPressure: Float?
    public let deviceIdentifier: UInt64?
    public let estimationUpdateIndex: Int?
    public let estimatedProperties: StrokeEstimatedProperties
    public let estimatedPropertiesExpectingUpdates: StrokeEstimatedProperties
    public let velocity: Float
    public let artisticVelocity: Float
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
        artisticVelocity: Float,
        phase: StrokePhase,
        source: StrokeSource,
        kind: StrokeSampleKind,
        capabilities: StrokeInputCapabilities,
        tangentialPressure: Float? = nil,
        deviceIdentifier: UInt64? = nil,
        estimationUpdateIndex: Int? = nil,
        estimatedProperties: StrokeEstimatedProperties = [],
        estimatedPropertiesExpectingUpdates: StrokeEstimatedProperties = []
    ) {
        self.position = position
        self.pressure = pressure
        self.timestamp = timestamp
        self.altitude = altitude
        self.azimuth = azimuth
        self.roll = roll
        self.tangentialPressure = tangentialPressure
        self.deviceIdentifier = deviceIdentifier
        self.estimationUpdateIndex = estimationUpdateIndex
        self.estimatedProperties = estimatedProperties
        self.estimatedPropertiesExpectingUpdates =
            estimatedPropertiesExpectingUpdates
        self.velocity = velocity
        self.artisticVelocity = artisticVelocity
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
            artisticVelocity: sample.artisticVelocity,
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

        let discrete = clamped < 0.5 ? self : end
        return InterpolatedStrokeSample(
            position: position,
            pressure: lerp(pressure, end.pressure, clamped),
            timestamp: timestamp
                + (end.timestamp - timestamp) * TimeInterval(clamped),
            altitude: Self.optionalLinear(altitude, end.altitude, clamped),
            azimuth: Self.optionalAngle(azimuth, end.azimuth, clamped),
            roll: Self.optionalAngle(roll, end.roll, clamped),
            velocity: lerp(velocity, end.velocity, clamped),
            artisticVelocity: lerp(
                artisticVelocity,
                end.artisticVelocity,
                clamped
            ),
            phase: discrete.phase,
            source: discrete.source,
            kind: discrete.kind,
            capabilities: discrete.capabilities,
            tangentialPressure: Self.optionalLinear(
                tangentialPressure,
                end.tangentialPressure,
                clamped
            ),
            deviceIdentifier: discrete.deviceIdentifier,
            estimationUpdateIndex: discrete.estimationUpdateIndex,
            estimatedProperties: discrete.estimatedProperties,
            estimatedPropertiesExpectingUpdates:
                discrete.estimatedPropertiesExpectingUpdates
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
            artisticVelocity: artisticVelocity,
            phase: phase,
            source: source,
            kind: kind,
            capabilities: capabilities,
            tangentialPressure: tangentialPressure,
            deviceIdentifier: deviceIdentifier,
            estimationUpdateIndex: estimationUpdateIndex,
            estimatedProperties: estimatedProperties,
            estimatedPropertiesExpectingUpdates:
                estimatedPropertiesExpectingUpdates
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

    public init(
        start: InterpolatedStrokeSample,
        end: InterpolatedStrokeSample
    ) {
        self.start = start
        self.end = end
    }

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

public enum StrokePathInterpolationError: Error, Equatable, Sendable {
    case subdivisionCapacityExceeded(maximum: Int)
}

public enum StrokePathInterpolationOutcome: Equatable, Sendable {
    case completed
    case truncated
}

/// Copyable, allocation-free traversal of one attributed path advance.
///
/// The stroke generator owns this cursor while a logical-dab page is pending.
/// Installing `completedPath` is therefore an explicit commit performed only
/// after every segment in the advance has been consumed.
struct AttributedStrokePathAdvanceStep: Equatable, Sendable {
    let segment: AttributedStrokePathSegment
    let continuation: AttributedStrokePathAdvanceCursor
}

struct AttributedStrokePathAdvanceCursor: Equatable, Sendable {
    private let p0: InterpolatedStrokeSample
    private let p1: InterpolatedStrokeSample
    private let current: InterpolatedStrokeSample
    private let subdivisionCount: Int
    private let clampsToSegmentBounds: Bool
    private var nextStep: Int
    private var lineStart: InterpolatedStrokeSample

    let completedPath: CentripetalCatmullRomPathInterpolator

    fileprivate init(
        p0: InterpolatedStrokeSample,
        p1: InterpolatedStrokeSample,
        current: InterpolatedStrokeSample,
        subdivisionCount: Int,
        clampsToSegmentBounds: Bool,
        completedPath: CentripetalCatmullRomPathInterpolator
    ) {
        self.p0 = p0
        self.p1 = p1
        self.current = current
        self.subdivisionCount = subdivisionCount
        self.clampsToSegmentBounds = clampsToSegmentBounds
        nextStep = 1
        lineStart = p1
        self.completedPath = completedPath
    }

    var isComplete: Bool {
        nextStep > subdivisionCount
    }

    func nextSegment() -> AttributedStrokePathAdvanceStep? {
        guard !isComplete else { return nil }
        let fraction = Float(nextStep) / Float(subdivisionCount)
        let position = CentripetalCatmullRomPathInterpolator.samplePosition(
            p0: p0.position,
            p1: p1.position,
            p2: current.position,
            p3: current.position,
            u: fraction,
            clampsToSegmentBounds: clampsToSegmentBounds
        )
        let lineEnd = p1.interpolated(
            to: current,
            fraction: fraction,
            position: position
        )
        var continuation = self
        continuation.nextStep += 1
        continuation.lineStart = lineEnd
        return AttributedStrokePathAdvanceStep(
            segment: AttributedStrokePathSegment(
                start: lineStart,
                end: lineEnd
            ),
            continuation: continuation
        )
    }
}

/// Converts attributed control points into deterministic short path segments.
/// Dab spacing is deliberately owned by the downstream stroke generator.
public struct CentripetalCatmullRomPathInterpolator: Equatable, Sendable {
    public let maximumSegmentLength: Float

    private let minimumSubdivisionEstimate: Float
    private let clampsToSegmentBounds: Bool
    private var beforePrevious: InterpolatedStrokeSample?
    private var previous: InterpolatedStrokeSample?

    public init(
        maximumSegmentLength: Float = 0.5,
        minimumSubdivisionEstimate: Float? = nil
    ) {
        self.init(
            maximumSegmentLength: maximumSegmentLength,
            validatedMinimumSubdivisionEstimate:
                minimumSubdivisionEstimate ?? maximumSegmentLength,
            clampsToSegmentBounds: false
        )
    }

    public init(
        maximumSegmentLength: Float,
        minimumSubdivisionEstimate: Float?,
        clampsToSegmentBounds: Bool
    ) {
        self.init(
            maximumSegmentLength: maximumSegmentLength,
            validatedMinimumSubdivisionEstimate:
                minimumSubdivisionEstimate ?? maximumSegmentLength,
            clampsToSegmentBounds: clampsToSegmentBounds
        )
    }

    private init(
        maximumSegmentLength: Float,
        validatedMinimumSubdivisionEstimate minimumSubdivisionEstimate: Float,
        clampsToSegmentBounds: Bool
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
        self.clampsToSegmentBounds = clampsToSegmentBounds
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
        let rawSubdivisionCount = ceil(estimate / maximumSegmentLength)
        let subdivisions = rawSubdivisionCount.isFinite
            && Double(rawSubdivisionCount) < Double(Int.max)
            ? max(1, Int(rawSubdivisionCount))
            : Int.max
        try append(
            current,
            from: p0,
            after: p1,
            subdivisions: subdivisions,
            emit: emit
        )
    }

    /// Creates a bounded, resumable traversal without mutating this path.
    /// The caller installs the cursor's `completedPath` only after draining it.
    func advanceCursor(
        to current: InterpolatedStrokeSample,
        maximumSubdivisionCount: Int
    ) throws -> AttributedStrokePathAdvanceCursor? {
        precondition(maximumSubdivisionCount > 0)
        guard let p1 = previous, let p0 = beforePrevious else { return nil }
        let requiredSubdivisionCount = Self.requiredSubdivisionCount(
            p0: p0.position,
            p1: p1.position,
            p2: current.position,
            maximumSegmentLength: maximumSegmentLength,
            minimumSubdivisionEstimate: minimumSubdivisionEstimate
        )
        guard requiredSubdivisionCount <= Double(maximumSubdivisionCount)
        else {
            throw StrokePathInterpolationError.subdivisionCapacityExceeded(
                maximum: maximumSubdivisionCount
            )
        }
        let estimate = max(
            simd_distance(p0.position.simd, p1.position.simd)
                + simd_distance(p1.position.simd, current.position.simd),
            minimumSubdivisionEstimate
        )
        let rawSubdivisionCount = ceil(estimate / maximumSegmentLength)
        guard rawSubdivisionCount.isFinite,
              Double(rawSubdivisionCount) <= Double(maximumSubdivisionCount)
        else {
            throw StrokePathInterpolationError.subdivisionCapacityExceeded(
                maximum: maximumSubdivisionCount
            )
        }
        var completedPath = self
        completedPath.beforePrevious = p1
        completedPath.previous = current
        return AttributedStrokePathAdvanceCursor(
            p0: p0,
            p1: p1,
            current: current,
            subdivisionCount: max(1, Int(rawSubdivisionCount)),
            clampsToSegmentBounds: clampsToSegmentBounds,
            completedPath: completedPath
        )
    }

    /// Executes a path step only when its interpolation work fits the caller's
    /// explicit budget. The Double preflight avoids overflowing finite Float
    /// coordinates before the bounded renderer path can reject the input.
    public mutating func append(
        _ current: InterpolatedStrokeSample,
        maximumSubdivisionCount: Int,
        emit: (AttributedStrokePathSegment) throws -> Void
    ) throws {
        precondition(maximumSubdivisionCount > 0)
        guard let p1 = previous, let p0 = beforePrevious else {
            _ = begin(at: current)
            return
        }
        let requiredSubdivisionCount = Self.requiredSubdivisionCount(
            p0: p0.position,
            p1: p1.position,
            p2: current.position,
            maximumSegmentLength: maximumSegmentLength,
            minimumSubdivisionEstimate: minimumSubdivisionEstimate
        )
        guard requiredSubdivisionCount
            <= Double(maximumSubdivisionCount)
        else {
            throw StrokePathInterpolationError
                .subdivisionCapacityExceeded(
                    maximum: maximumSubdivisionCount
                )
        }
        let estimate = max(
            simd_distance(p0.position.simd, p1.position.simd)
                + simd_distance(p1.position.simd, current.position.simd),
            minimumSubdivisionEstimate
        )
        let rawSubdivisionCount = ceil(estimate / maximumSegmentLength)
        guard rawSubdivisionCount.isFinite,
              Double(rawSubdivisionCount) <= Double(maximumSubdivisionCount)
        else {
            throw StrokePathInterpolationError
                .subdivisionCapacityExceeded(
                    maximum: maximumSubdivisionCount
                )
        }
        try append(
            current,
            from: p0,
            after: p1,
            subdivisions: max(1, Int(rawSubdivisionCount)),
            emit: emit
        )
    }

    /// Emits only the true leading path subdivisions that fit the caller's
    /// budget. A truncated prefix never advances interpolation state, allowing
    /// prediction callers to retain the visible prefix without committing a
    /// generator snapshot for an incomplete input sample.
    @discardableResult
    public mutating func appendBoundedPrefix(
        _ current: InterpolatedStrokeSample,
        maximumSubdivisionCount: Int,
        emit: (AttributedStrokePathSegment) throws -> Void
    ) throws -> StrokePathInterpolationOutcome {
        precondition(maximumSubdivisionCount > 0)
        guard let p1 = previous, let p0 = beforePrevious else {
            _ = begin(at: current)
            return .completed
        }
        let requiredSubdivisionCount = Self.requiredSubdivisionCount(
            p0: p0.position,
            p1: p1.position,
            p2: current.position,
            maximumSegmentLength: maximumSegmentLength,
            minimumSubdivisionEstimate: minimumSubdivisionEstimate
        )
        guard requiredSubdivisionCount
            > Double(maximumSubdivisionCount)
        else {
            try append(
                current,
                maximumSubdivisionCount:
                    maximumSubdivisionCount,
                emit: emit
            )
            return .completed
        }

        try emitBoundedPrefix(
            current,
            from: p0,
            after: p1,
            emittedSubdivisionCount: maximumSubdivisionCount,
            requiredSubdivisionCount: requiredSubdivisionCount,
            emit: emit
        )
        return .truncated
    }

    private mutating func append(
        _ current: InterpolatedStrokeSample,
        from p0: InterpolatedStrokeSample,
        after p1: InterpolatedStrokeSample,
        subdivisions: Int,
        emit: (AttributedStrokePathSegment) throws -> Void
    ) rethrows {
        var lineStart = p1

        for step in 1...subdivisions {
            let fraction = Float(step) / Float(subdivisions)
            let position = Self.samplePosition(
                p0: p0.position,
                p1: p1.position,
                p2: current.position,
                p3: current.position,
                u: fraction,
                clampsToSegmentBounds: clampsToSegmentBounds
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

    private func emitBoundedPrefix(
        _ current: InterpolatedStrokeSample,
        from p0: InterpolatedStrokeSample,
        after p1: InterpolatedStrokeSample,
        emittedSubdivisionCount: Int,
        requiredSubdivisionCount: Double,
        emit: (AttributedStrokePathSegment) throws -> Void
    ) rethrows {
        var lineStart = p1

        for step in 1...emittedSubdivisionCount {
            let fraction = Float(
                Double(step) / requiredSubdivisionCount
            )
            let position = Self.samplePosition(
                p0: p0.position,
                p1: p1.position,
                p2: current.position,
                p3: current.position,
                u: fraction,
                clampsToSegmentBounds: clampsToSegmentBounds
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
    }

    private static func requiredSubdivisionCount(
        p0: WorldPoint,
        p1: WorldPoint,
        p2: WorldPoint,
        maximumSegmentLength: Float,
        minimumSubdivisionEstimate: Float
    ) -> Double {
        func distance(_ lhs: WorldPoint, _ rhs: WorldPoint) -> Double {
            hypot(
                Double(rhs.x) - Double(lhs.x),
                Double(rhs.y) - Double(lhs.y)
            )
        }
        let estimate = max(
            distance(p0, p1) + distance(p1, p2),
            Double(minimumSubdivisionEstimate)
        )
        return ceil(estimate / Double(maximumSegmentLength))
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

    @discardableResult
    public mutating func finish(
        at finalSample: InterpolatedStrokeSample,
        maximumSubdivisionCount: Int,
        emit: (AttributedStrokePathSegment) throws -> Void
    ) throws -> InterpolatedStrokeSample {
        if previous?.position != finalSample.position {
            try append(
                finalSample,
                maximumSubdivisionCount: maximumSubdivisionCount,
                emit: emit
            )
        }
        cancel()
        return finalSample
    }

    @discardableResult
    public mutating func finishBoundedPrefix(
        at finalSample: InterpolatedStrokeSample,
        maximumSubdivisionCount: Int,
        emit: (AttributedStrokePathSegment) throws -> Void
    ) throws -> StrokePathInterpolationOutcome {
        if previous?.position != finalSample.position {
            let outcome = try appendBoundedPrefix(
                finalSample,
                maximumSubdivisionCount: maximumSubdivisionCount,
                emit: emit
            )
            guard outcome == .completed else { return .truncated }
        }
        cancel()
        return .completed
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
        u: Float,
        clampsToSegmentBounds: Bool = false
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
        let position = WorldPoint(
            (2 * u3 - 3 * u2 + 1) * p1.simd
                + (u3 - 2 * u2 + u) * m1
                + (-2 * u3 + 3 * u2) * p2.simd
                + (u3 - u2) * m2
        )
        guard clampsToSegmentBounds else { return position }
        return WorldPoint(
            x: min(max(position.x, min(p1.x, p2.x)), max(p1.x, p2.x)),
            y: min(max(position.y, min(p1.y, p2.y)), max(p1.y, p2.y))
        )
    }
}
