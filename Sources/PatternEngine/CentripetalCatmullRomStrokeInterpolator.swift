import Foundation
import simd

public struct CentripetalCatmullRomStrokeInterpolator: Sendable {
    public let spacing: Float

    private var beforePrevious: WorldPoint?
    private var previous: WorldPoint?
    private var lastEmitted: WorldPoint?
    private var distanceUntilNext: Float

    public init(radius: Float) {
        precondition(radius > 0)
        spacing = max(1, min(8, radius * 0.25))
        distanceUntilNext = spacing
    }

    public mutating func begin(
        at point: WorldPoint,
        emit: (WorldPoint) throws -> Void
    ) rethrows {
        beforePrevious = point
        previous = point
        lastEmitted = point
        distanceUntilNext = spacing
        try emit(point)
    }

    public mutating func append(
        _ current: WorldPoint,
        emit: (WorldPoint) throws -> Void
    ) rethrows {
        guard let p1 = previous, let p0 = beforePrevious else {
            return try begin(at: current, emit: emit)
        }
        let estimate = max(
            simd_distance(p0.simd, p1.simd) + simd_distance(p1.simd, current.simd),
            spacing
        )
        let subdivisions = max(1, Int(ceil(estimate / min(0.5, spacing * 0.2))))
        var lineStart = p1

        for step in 1...subdivisions {
            let u = Float(step) / Float(subdivisions)
            let lineEnd = Self.sample(
                p0: p0,
                p1: p1,
                p2: current,
                p3: current,
                u: u
            )
            try consumeLine(from: &lineStart, to: lineEnd, emit: emit)
            lineStart = lineEnd
        }

        beforePrevious = p1
        previous = current
    }

    public mutating func finish(
        at finalPoint: WorldPoint,
        emit: (WorldPoint) throws -> Void
    ) rethrows {
        if previous != finalPoint {
            try append(finalPoint, emit: emit)
        }
        if lastEmitted != finalPoint {
            try emit(finalPoint)
            lastEmitted = finalPoint
        }
        beforePrevious = nil
        previous = nil
        distanceUntilNext = spacing
    }

    public mutating func cancel() {
        beforePrevious = nil
        previous = nil
        lastEmitted = nil
        distanceUntilNext = spacing
    }

    private mutating func consumeLine(
        from start: inout WorldPoint,
        to end: WorldPoint,
        emit: (WorldPoint) throws -> Void
    ) rethrows {
        var cursor = start.simd
        let terminal = end.simd
        var remainingLength = simd_distance(cursor, terminal)

        while remainingLength >= distanceUntilNext && remainingLength > 0 {
            let direction = (terminal - cursor) / remainingLength
            cursor += direction * distanceUntilNext
            let point = WorldPoint(cursor)
            try emit(point)
            lastEmitted = point
            remainingLength = simd_distance(cursor, terminal)
            distanceUntilNext = spacing
        }

        distanceUntilNext -= remainingLength
        start = WorldPoint(terminal)
    }

    private static func sample(
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
