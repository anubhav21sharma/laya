import Foundation

/// Schema-v2 position stabilization selected by authored world distance.
public enum StrokeStabilizerMode: Equatable, Sendable {
    case none
    case weightedWindow(distance: Float)
    case delayed(distance: Float)
}

public enum StrokeStabilizerError: Error, Equatable, Sendable {
    case invalidDistance
    case incompatibleMode
}

/// Deterministic, fixed-capacity position stabilization for one stroke stream.
///
/// The strength initializer and unconditional `process` result are the isolated
/// schema-v1 exponential adapter. Schema v2 uses a typed mode and the bounded
/// optional `processV2` result. Callers evaluate prediction from a value copy.
public struct StrokeStabilizer: Equatable, Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let retainedPointCount: Int
        public let pointCapacity: Int
        public let exactHeadPosition: WorldPoint?
        public let exactHead: WorldStrokeSample?
        public let authoredDistance: Double
        public let newestRetainedDistance: Double?
        public let newestRetainedPosition: WorldPoint?
    }

    public let strength: Float

    private var filteredPosition: WorldPoint?
    private var v2Mode: StrokeStabilizerMode?
    private var v2ExactHead: WorldStrokeSample?
    private var v2AuthoredDistance: Double
    private var v2LastResampleIndex: UInt64
    private var v2PointStorage: StrokeStabilizerPointStorage
    private var v2OldestPointIndex: Int
    private var v2PointCount: Int

    public init(strength: Float) {
        precondition(
            strength.isFinite && strength >= 0 && strength < 1,
            "Stabilization strength must be finite and in 0..<1"
        )
        self.strength = strength
        filteredPosition = nil
        v2Mode = nil
        v2ExactHead = nil
        v2AuthoredDistance = 0
        v2LastResampleIndex = 0
        v2PointStorage = StrokeStabilizerPointStorage()
        v2OldestPointIndex = 0
        v2PointCount = 0
    }

    public init(mode: StrokeStabilizerMode) throws {
        switch mode {
        case .none:
            break
        case let .weightedWindow(distance), let .delayed(distance):
            guard distance.isFinite,
                  distance >= Float(1) / 1_024,
                  distance <= 4_096
            else {
                throw StrokeStabilizerError.invalidDistance
            }
        }
        strength = 0
        filteredPosition = nil
        v2Mode = mode
        v2ExactHead = nil
        v2AuthoredDistance = 0
        v2LastResampleIndex = 0
        v2PointStorage = StrokeStabilizerPointStorage()
        v2OldestPointIndex = 0
        v2PointCount = 0
    }

    public var declaredEndpointLag: Float? {
        guard case let .delayed(distance) = v2Mode else { return nil }
        return distance
    }

    public var snapshot: Snapshot {
        let newest = v2PointCount > 0
            ? retainedPoint(at: v2PointCount - 1)
            : nil
        return Snapshot(
            retainedPointCount: v2PointCount,
            pointCapacity: Self.resampledPointCapacity,
            exactHeadPosition: v2ExactHead?.position,
            exactHead: v2ExactHead,
            authoredDistance: v2AuthoredDistance,
            newestRetainedDistance: newest?.authoredDistance,
            newestRetainedPosition: newest?.position
        )
    }

    public mutating func processV2(
        _ sample: WorldStrokeSample
    ) throws -> WorldStrokeSample? {
        guard let v2Mode else {
            throw StrokeStabilizerError.incompatibleMode
        }
        if sample.phase == .cancelled {
            resetV2()
            return nil
        }

        if sample.phase == .began {
            resetV2()
            v2ExactHead = sample
            appendPoint(sample.position, authoredDistance: 0)
            switch v2Mode {
            case .none, .weightedWindow:
                return sample
            case .delayed:
                return nil
            }
        }

        if let previous = v2ExactHead?.position {
            let segmentLength = hypot(
                Double(sample.position.x) - Double(previous.x),
                Double(sample.position.y) - Double(previous.y)
            )
            if segmentLength > 0 {
                let segmentStartDistance = v2AuthoredDistance
                v2AuthoredDistance += segmentLength
                appendResampledPoints(
                    from: previous,
                    to: sample.position,
                    segmentStartDistance: segmentStartDistance,
                    segmentLength: segmentLength,
                    mode: v2Mode
                )
            }
        } else {
            appendPoint(sample.position, authoredDistance: 0)
        }
        v2ExactHead = sample

        let output: WorldStrokeSample?
        switch v2Mode {
        case .none:
            output = sample
        case let .weightedWindow(distance):
            output = sample.phase == .ended
                ? sample
                : sample.replacingPosition(
                    weightedPosition(
                        head: sample.position,
                        configuredDistance: Double(distance)
                    )
                )
        case let .delayed(distance):
            if sample.phase == .ended, v2AuthoredDistance == 0 {
                output = sample
            } else if v2AuthoredDistance >= Double(distance) {
                output = sample.replacingPosition(
                    position(
                        at: v2AuthoredDistance - Double(distance),
                        head: sample.position
                    )
                )
            } else {
                output = nil
            }
        }

        if sample.phase == .ended {
            resetV2()
        }
        return output
    }

    public mutating func process(
        _ sample: WorldStrokeSample
    ) -> WorldStrokeSample {
        if sample.phase == .cancelled {
            resetLegacy()
            return sample
        }

        if sample.phase == .began {
            resetLegacy()
            filteredPosition = sample.position
            return sample
        }

        // Preserve the compatibility path bit-for-bit, including signed zero.
        guard strength > 0 else {
            if sample.phase == .ended {
                resetLegacy()
            } else {
                filteredPosition = sample.position
            }
            return sample
        }

        guard let previous = filteredPosition else {
            if sample.phase != .ended {
                filteredPosition = sample.position
            }
            return sample
        }

        let response = 1 - strength
        let position = WorldPoint(
            x: previous.x + (sample.position.x - previous.x) * response,
            y: previous.y + (sample.position.y - previous.y) * response
        )
        let output = sample.replacingPosition(position)

        if sample.phase == .ended {
            resetLegacy()
        } else {
            filteredPosition = position
        }
        return output
    }

    public mutating func reset() {
        resetLegacy()
        resetV2()
    }

    private mutating func resetLegacy() {
        filteredPosition = nil
    }

    private mutating func resetV2() {
        v2ExactHead = nil
        v2AuthoredDistance = 0
        v2LastResampleIndex = 0
        v2PointStorage = StrokeStabilizerPointStorage()
        v2OldestPointIndex = 0
        v2PointCount = 0
    }

    private mutating func appendResampledPoints(
        from start: WorldPoint,
        to end: WorldPoint,
        segmentStartDistance: Double,
        segmentLength: Double,
        mode: StrokeStabilizerMode
    ) {
        let configuredDistance: Double
        switch mode {
        case .none:
            return
        case let .weightedWindow(distance), let .delayed(distance):
            configuredDistance = Double(distance)
        }
        let interval = configuredDistance / 64
        let quotient = floor(v2AuthoredDistance / interval)
        guard quotient < Double(UInt64.max) else {
            preconditionFailure("Authored stroke exceeds resampling index range")
        }
        let finalGridIndex = UInt64(quotient)
        guard finalGridIndex > v2LastResampleIndex else {
            return
        }

        let firstNewIndex = v2LastResampleIndex + 1
        var firstRetainedNewIndex = firstNewIndex
        if finalGridIndex - firstNewIndex
            >= UInt64(Self.resampledPointCapacity)
        {
            firstRetainedNewIndex = finalGridIndex
                - UInt64(Self.resampledPointCapacity - 1)
            v2PointStorage = StrokeStabilizerPointStorage()
            v2OldestPointIndex = 0
            v2PointCount = 0
        }

        let rawCount = finalGridIndex - firstRetainedNewIndex + 1
        let pointCount = min(
            Self.resampledPointCapacity,
            Int(rawCount)
        )
        var lastAppendedIndex = v2LastResampleIndex
        for offset in 0..<pointCount {
            let gridIndex = firstRetainedNewIndex + UInt64(offset)
            let authoredDistance = Double(gridIndex) * interval
            guard authoredDistance <= v2AuthoredDistance else { break }
            let fraction = min(
                1,
                max(
                    0,
                    (authoredDistance - segmentStartDistance) / segmentLength
                )
            )
            appendPoint(
                WorldPoint(
                    x: Float(
                        Double(start.x)
                            + (Double(end.x) - Double(start.x)) * fraction
                    ),
                    y: Float(
                        Double(start.y)
                            + (Double(end.y) - Double(start.y)) * fraction
                    )
                ),
                authoredDistance: authoredDistance
            )
            lastAppendedIndex = gridIndex
        }
        v2LastResampleIndex = lastAppendedIndex
    }

    private static let resampledPointCapacity = 65

    private mutating func appendPoint(
        _ point: WorldPoint,
        authoredDistance: Double
    ) {
        let index: Int
        if v2PointCount < Self.resampledPointCapacity {
            index = (v2OldestPointIndex + v2PointCount)
                % Self.resampledPointCapacity
            v2PointCount += 1
        } else {
            index = v2OldestPointIndex
            v2OldestPointIndex = (v2OldestPointIndex + 1)
                % Self.resampledPointCapacity
        }
        v2PointStorage.set(
            point: point,
            authoredDistance: authoredDistance,
            at: index
        )
    }

    private func retainedPoint(at offset: Int) -> StrokeStabilizerPoint {
        v2PointStorage.point(
            at: (v2OldestPointIndex + offset) % Self.resampledPointCapacity
        )
    }

    private func position(
        at targetDistance: Double,
        head: WorldPoint
    ) -> WorldPoint {
        precondition(v2PointCount > 0)
        var previous = retainedPoint(at: 0)
        if targetDistance <= previous.authoredDistance {
            return previous.position
        }
        for offset in 1..<v2PointCount {
            let next = retainedPoint(at: offset)
            if targetDistance <= next.authoredDistance {
                return Self.interpolate(
                    from: previous,
                    to: next,
                    at: targetDistance
                )
            }
            previous = next
        }
        return Self.interpolate(
            from: previous,
            to: StrokeStabilizerPoint(
                position: head,
                authoredDistance: v2AuthoredDistance
            ),
            at: targetDistance
        )
    }

    private func weightedPosition(
        head: WorldPoint,
        configuredDistance: Double
    ) -> WorldPoint {
        guard v2AuthoredDistance > 0 else { return head }
        let startDistance = max(
            0,
            v2AuthoredDistance - configuredDistance
        )
        let coveredDistance = v2AuthoredDistance - startDistance
        var previous = StrokeStabilizerPoint(
            position: position(at: startDistance, head: head),
            authoredDistance: startDistance
        )
        var momentX = 0.0
        var momentY = 0.0

        for offset in 0..<v2PointCount {
            let next = retainedPoint(at: offset)
            guard next.authoredDistance > startDistance,
                  next.authoredDistance <= v2AuthoredDistance
            else {
                continue
            }
            Self.integrateWeightedSegment(
                from: previous,
                to: next,
                windowStart: startDistance,
                configuredDistance: configuredDistance,
                momentX: &momentX,
                momentY: &momentY
            )
            previous = next
        }

        let exactHead = StrokeStabilizerPoint(
            position: head,
            authoredDistance: v2AuthoredDistance
        )
        if exactHead.authoredDistance > previous.authoredDistance {
            Self.integrateWeightedSegment(
                from: previous,
                to: exactHead,
                windowStart: startDistance,
                configuredDistance: configuredDistance,
                momentX: &momentX,
                momentY: &momentY
            )
        }
        let normalizedWeight = coveredDistance
            + coveredDistance * coveredDistance
                / (2 * configuredDistance)
        return WorldPoint(
            x: Float(momentX / normalizedWeight),
            y: Float(momentY / normalizedWeight)
        )
    }

    private static func integrateWeightedSegment(
        from start: StrokeStabilizerPoint,
        to end: StrokeStabilizerPoint,
        windowStart: Double,
        configuredDistance: Double,
        momentX: inout Double,
        momentY: inout Double
    ) {
        let localStart = start.authoredDistance - windowStart
        let segmentLength = end.authoredDistance - start.authoredDistance
        guard segmentLength > 0 else { return }
        momentX += weightedCoordinateMoment(
            start: Double(start.position.x),
            end: Double(end.position.x),
            localStart: localStart,
            segmentLength: segmentLength,
            configuredDistance: configuredDistance
        )
        momentY += weightedCoordinateMoment(
            start: Double(start.position.y),
            end: Double(end.position.y),
            localStart: localStart,
            segmentLength: segmentLength,
            configuredDistance: configuredDistance
        )
    }

    private static func weightedCoordinateMoment(
        start: Double,
        end: Double,
        localStart: Double,
        segmentLength: Double,
        configuredDistance: Double
    ) -> Double {
        let delta = end - start
        let unweighted = segmentLength * (start + end) / 2
        let distanceWeighted = segmentLength * (
            localStart * start
                + (localStart * delta + segmentLength * start) / 2
                + segmentLength * delta / 3
        )
        return unweighted + distanceWeighted / configuredDistance
    }

    private static func interpolate(
        from start: StrokeStabilizerPoint,
        to end: StrokeStabilizerPoint,
        at authoredDistance: Double
    ) -> WorldPoint {
        let length = end.authoredDistance - start.authoredDistance
        guard length > 0 else { return end.position }
        let fraction = min(
            1,
            max(0, (authoredDistance - start.authoredDistance) / length)
        )
        return WorldPoint(
            x: Float(
                Double(start.position.x)
                    + (Double(end.position.x) - Double(start.position.x))
                        * fraction
            ),
            y: Float(
                Double(start.position.y)
                    + (Double(end.position.y) - Double(start.position.y))
                        * fraction
            )
        )
    }
}

private struct StrokeStabilizerPoint: Equatable, Sendable {
    var position = WorldPoint(x: 0, y: 0)
    var authoredDistance: Double = 0
}

private struct StrokeStabilizerPointStorage: Equatable, Sendable {
    private var x = SIMD64<Float>(repeating: 0)
    private var y = SIMD64<Float>(repeating: 0)
    private var distance = SIMD64<Double>(repeating: 0)
    private var x64: Float = 0
    private var y64: Float = 0
    private var distance64: Double = 0

    func point(at index: Int) -> StrokeStabilizerPoint {
        if index < 64 {
            return StrokeStabilizerPoint(
                position: WorldPoint(x: x[index], y: y[index]),
                authoredDistance: distance[index]
            )
        }
        precondition(index == 64)
        return StrokeStabilizerPoint(
            position: WorldPoint(x: x64, y: y64),
            authoredDistance: distance64
        )
    }

    mutating func set(
        point: WorldPoint,
        authoredDistance: Double,
        at index: Int
    ) {
        if index < 64 {
            x[index] = point.x
            y[index] = point.y
            distance[index] = authoredDistance
            return
        }
        precondition(index == 64)
        x64 = point.x
        y64 = point.y
        distance64 = authoredDistance
    }
}

private extension WorldStrokeSample {
    func replacingPosition(_ position: WorldPoint) -> WorldStrokeSample {
        let copiedSample = StrokeSample(
            position: ScreenPoint(x: position.x, y: position.y),
            pressure: pressure,
            timestamp: timestamp,
            phase: phase,
            source: source,
            kind: kind,
            capabilities: capabilities,
            altitude: altitude,
            azimuth: azimuth,
            roll: roll,
            tangentialPressure: tangentialPressure,
            deviceIdentifier: deviceIdentifier,
            estimationUpdateIndex: estimationUpdateIndex,
            estimatedProperties: estimatedProperties,
            estimatedPropertiesExpectingUpdates:
                estimatedPropertiesExpectingUpdates
        )
        return WorldStrokeSample(
            sample: copiedSample,
            position: position,
            velocity: velocity,
            artisticVelocity: artisticVelocity
        )
    }
}
