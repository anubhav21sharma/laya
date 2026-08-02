import Foundation
import PatternEngine
import Testing

private func attributedSample(
    x: Float,
    y: Float = 0,
    pressure: Float = 0.5,
    timestamp: TimeInterval,
    velocity: Float = 0,
    altitude: Float? = nil,
    azimuth: Float? = nil,
    roll: Float? = nil,
    phase: StrokePhase,
    kind: StrokeSampleKind = .actual,
    capabilities: StrokeInputCapabilities = [.pressure],
    tangentialPressure: Float? = nil,
    deviceIdentifier: UInt64? = nil,
    estimationUpdateIndex: Int? = nil,
    estimatedProperties: StrokeEstimatedProperties = [],
    estimatedPropertiesExpectingUpdates: StrokeEstimatedProperties = []
) -> InterpolatedStrokeSample {
    InterpolatedStrokeSample(
        position: WorldPoint(x: x, y: y),
        pressure: pressure,
        timestamp: timestamp,
        altitude: altitude,
        azimuth: azimuth,
        roll: roll,
        velocity: velocity,
        phase: phase,
        source: .pencil,
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

private func angleDistance(_ lhs: Float, _ rhs: Float) -> Float {
    let fullTurn = 2 * Float.pi
    let delta = (lhs - rhs).truncatingRemainder(dividingBy: fullTurn)
    return min(abs(delta), fullTurn - abs(delta))
}

@Suite("AttributedStrokeInterpolator")
struct AttributedStrokeInterpolatorTests {
    @Test
    func continuousTangentialPressureInterpolatesAndDiscreteFieldsChooseNearest()
        throws
    {
        let start = attributedSample(
            x: 0,
            timestamp: 0,
            phase: .moved,
            kind: .actual,
            capabilities: [.pressure, .tangentialPressure],
            tangentialPressure: -1,
            deviceIdentifier: 10,
            estimationUpdateIndex: 1,
            estimatedProperties: [.pressure],
            estimatedPropertiesExpectingUpdates: [.pressure]
        )
        let end = attributedSample(
            x: 10,
            timestamp: 1,
            phase: .ended,
            kind: .coalesced,
            capabilities: [.pressure, .tangentialPressure, .roll],
            tangentialPressure: 1,
            deviceIdentifier: 20,
            estimationUpdateIndex: 2,
            estimatedProperties: [.roll],
            estimatedPropertiesExpectingUpdates: [.roll]
        )
        let segment = AttributedStrokePathSegment(start: start, end: end)
        let beforeMidpoint = segment.sample(at: 0.49)
        let midpoint = segment.sample(at: 0.5)

        #expect(abs(try #require(beforeMidpoint.tangentialPressure) + 0.02) < 0.001)
        #expect(beforeMidpoint.deviceIdentifier == 10)
        #expect(beforeMidpoint.estimationUpdateIndex == 1)
        #expect(beforeMidpoint.estimatedProperties == [.pressure])
        #expect(beforeMidpoint.phase == .moved)
        #expect(midpoint.deviceIdentifier == 20)
        #expect(midpoint.estimationUpdateIndex == 2)
        #expect(midpoint.estimatedProperties == [.roll])
        #expect(midpoint.phase == .ended)
    }
    @Test
    func pressureTimestampAndVelocityFollowArcFraction() {
        var interpolator = AttributedStrokeInterpolator(spacing: 2.5)
        var emitted: [InterpolatedStrokeSample] = []
        interpolator.begin(
            at: attributedSample(
                x: 0,
                pressure: 0,
                timestamp: 10,
                velocity: 100,
                phase: .began
            )
        ) { emitted.append($0) }
        interpolator.finish(
            at: attributedSample(
                x: 10,
                pressure: 1,
                timestamp: 14,
                velocity: 500,
                phase: .ended
            )
        ) { emitted.append($0) }

        #expect(emitted.map(\.position.x) == [0, 2.5, 5, 7.5, 10])
        #expect(emitted.map(\.pressure) == [0, 0.25, 0.5, 0.75, 1])
        #expect(emitted.map(\.timestamp) == [10, 11, 12, 13, 14])
        #expect(emitted.map(\.velocity) == [100, 200, 300, 400, 500])
    }

    @Test
    func anglesUseShortestArc() {
        var interpolator = AttributedStrokeInterpolator(spacing: 5)
        var emitted: [InterpolatedStrokeSample] = []
        let degrees = Float.pi / 180
        interpolator.begin(
            at: attributedSample(
                x: 0,
                timestamp: 0,
                altitude: 0.2,
                azimuth: 170 * degrees,
                roll: -170 * degrees,
                phase: .began,
                capabilities: [.pressure, .altitude, .azimuth, .roll]
            )
        ) { emitted.append($0) }
        interpolator.finish(
            at: attributedSample(
                x: 10,
                timestamp: 1,
                altitude: 1.2,
                azimuth: -170 * degrees,
                roll: 170 * degrees,
                phase: .ended,
                capabilities: [.pressure, .altitude, .azimuth, .roll]
            )
        ) { emitted.append($0) }

        #expect(emitted.count == 3)
        #expect(abs(emitted[1].altitude! - 0.7) < 0.0001)
        #expect(angleDistance(emitted[1].azimuth!, .pi) < 0.0001)
        #expect(angleDistance(emitted[1].roll!, -.pi) < 0.0001)
    }

    @Test
    func missingOptionalValueRemainsMissingUntilRealEndpoint() {
        var interpolator = AttributedStrokeInterpolator(spacing: 5)
        var emitted: [InterpolatedStrokeSample] = []
        interpolator.begin(
            at: attributedSample(
                x: 0,
                timestamp: 0,
                altitude: nil,
                azimuth: nil,
                roll: nil,
                phase: .began,
                capabilities: []
            )
        ) { emitted.append($0) }
        interpolator.finish(
            at: attributedSample(
                x: 10,
                timestamp: 1,
                altitude: 0.8,
                azimuth: 1.4,
                roll: -0.6,
                phase: .ended,
                capabilities: [.altitude, .azimuth, .roll]
            )
        ) { emitted.append($0) }

        #expect(emitted.count == 3)
        #expect(emitted[0].altitude == nil)
        #expect(emitted[1].altitude == nil)
        #expect(emitted[1].azimuth == nil)
        #expect(emitted[1].roll == nil)
        #expect(emitted[2].altitude == 0.8)
        #expect(emitted[2].azimuth == 1.4)
        #expect(emitted[2].roll == -0.6)
    }

    @Test
    func spacingCarryCrossesAttributedInputEvents() {
        var interpolator = AttributedStrokeInterpolator(spacing: 2.5)
        var emitted: [InterpolatedStrokeSample] = []
        interpolator.begin(
            at: attributedSample(x: 0, timestamp: 0, phase: .began)
        ) { emitted.append($0) }
        interpolator.append(
            attributedSample(x: 1, timestamp: 1, phase: .moved)
        ) { emitted.append($0) }
        interpolator.append(
            attributedSample(x: 3, timestamp: 2, phase: .moved)
        ) { emitted.append($0) }

        #expect(emitted.count == 2)
        #expect(abs(emitted[0].position.x) < 0.0001)
        #expect(abs(emitted[1].position.x - 2.5) < 0.0001)
        #expect(abs(emitted[1].timestamp - 1.75) < 0.0001)
    }

    @Test
    func finishAlwaysEmitsExactAttributedEndpoint() {
        var interpolator = AttributedStrokeInterpolator(spacing: 3)
        var emitted: [InterpolatedStrokeSample] = []
        let first = attributedSample(x: 0, timestamp: 0, phase: .began)
        let final = attributedSample(
            x: 7,
            pressure: 0.9,
            timestamp: 1,
            velocity: 42,
            altitude: 0.4,
            azimuth: -0.7,
            roll: 1.1,
            phase: .ended,
            capabilities: [.pressure, .altitude, .azimuth, .roll]
        )
        interpolator.begin(at: first) { emitted.append($0) }
        interpolator.finish(at: final) { emitted.append($0) }

        #expect(emitted.last == final)
    }

    @Test
    func attributedCurvesMatchLegacyPositionsExactly() {
        let inputs: [InterpolatedStrokeSample] = [
            attributedSample(x: 0, y: 0, timestamp: 0, phase: .began),
            attributedSample(x: 7.5, y: 0, timestamp: 1, phase: .moved),
            attributedSample(x: 7.5, y: 7.5, timestamp: 2, phase: .moved),
            attributedSample(x: 9, y: 10, timestamp: 3, phase: .ended),
        ]
        var attributed = AttributedStrokeInterpolator(spacing: 2.5)
        var attributedOutput: [WorldPoint] = []
        attributed.begin(at: inputs[0]) { attributedOutput.append($0.position) }
        attributed.append(inputs[1]) { attributedOutput.append($0.position) }
        attributed.append(inputs[2]) { attributedOutput.append($0.position) }
        attributed.finish(at: inputs[3]) { attributedOutput.append($0.position) }

        var legacy = CentripetalCatmullRomStrokeInterpolator(radius: 10)
        var legacyOutput: [WorldPoint] = []
        legacy.begin(at: inputs[0].position) { legacyOutput.append($0) }
        legacy.append(inputs[1].position) { legacyOutput.append($0) }
        legacy.append(inputs[2].position) { legacyOutput.append($0) }
        legacy.finish(at: inputs[3].position) { legacyOutput.append($0) }

        #expect(attributedOutput == legacyOutput)
    }

    @Test
    func boundedPrefixUsesFullPathFractionsWithoutAdvancingState() throws {
        let start = attributedSample(
            x: 0,
            timestamp: 0,
            phase: .began,
            kind: .predicted
        )
        let end = attributedSample(
            x: 10,
            timestamp: 1,
            phase: .moved,
            kind: .predicted
        )
        var complete = CentripetalCatmullRomPathInterpolator(
            maximumSegmentLength: 1
        )
        _ = complete.begin(at: start)
        var completeSegments: [AttributedStrokePathSegment] = []
        complete.append(end) { completeSegments.append($0) }

        var bounded = CentripetalCatmullRomPathInterpolator(
            maximumSegmentLength: 1
        )
        _ = bounded.begin(at: start)
        let before = bounded
        var boundedSegments: [AttributedStrokePathSegment] = []
        let outcome = try bounded.appendBoundedPrefix(
            end,
            maximumSubdivisionCount: 3
        ) { boundedSegments.append($0) }

        #expect(outcome == .truncated)
        #expect(boundedSegments == Array(completeSegments.prefix(3)))
        #expect(bounded == before)

        var strict = before
        var strictSegments: [AttributedStrokePathSegment] = []
        #expect(
            throws: StrokePathInterpolationError
                .subdivisionCapacityExceeded(maximum: 3)
        ) {
            try strict.append(
                end,
                maximumSubdivisionCount: 3
            ) { strictSegments.append($0) }
        }
        #expect(strictSegments.isEmpty)
        #expect(strict == before)
    }

    @Test
    func boundedPrefixKeepsExtremeFiniteInputWorkAndOutputFinite() throws {
        for x in [
            Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude,
        ] {
            let start = attributedSample(
                x: 0,
                timestamp: 0,
                phase: .began,
                kind: .predicted
            )
            let end = attributedSample(
                x: x,
                timestamp: 1,
                phase: .moved,
                kind: .predicted
            )
            var interpolator = CentripetalCatmullRomPathInterpolator(
                maximumSegmentLength: 0.5
            )
            _ = interpolator.begin(at: start)
            let before = interpolator
            var segments: [AttributedStrokePathSegment] = []

            let outcome = try interpolator.appendBoundedPrefix(
                end,
                maximumSubdivisionCount: 4
            ) { segments.append($0) }

            #expect(outcome == .truncated)
            #expect(segments.count == 4)
            #expect(
                segments.allSatisfy {
                    $0.start.position.x.isFinite
                        && $0.start.position.y.isFinite
                        && $0.end.position.x.isFinite
                        && $0.end.position.y.isFinite
                }
            )
            #expect(interpolator == before)
        }
    }

    @Test
    func cancelDropsPathAndSpacingCarry() {
        var interpolator = AttributedStrokeInterpolator(spacing: 2.5)
        var emitted: [InterpolatedStrokeSample] = []
        interpolator.begin(
            at: attributedSample(x: 0, timestamp: 0, phase: .began)
        ) { emitted.append($0) }
        interpolator.append(
            attributedSample(x: 1, timestamp: 1, phase: .moved)
        ) { emitted.append($0) }
        interpolator.cancel()
        interpolator.append(
            attributedSample(x: 40, timestamp: 2, phase: .moved)
        ) { emitted.append($0) }

        #expect(emitted.map(\.position) == [
            WorldPoint(x: 0, y: 0),
            WorldPoint(x: 40, y: 0),
        ])
    }
}
