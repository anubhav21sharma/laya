import Foundation
import PatternEngine
import Testing

private let brushInputViewport = ViewportTransform(
    drawableSize: PatternSize(width: 200, height: 200),
    worldCenter: WorldPoint(x: 0, y: 0),
    zoom: 1
)

private func validatedSample(
    x: Float,
    y: Float,
    pressure: Float = 0.5,
    timestamp: TimeInterval,
    phase: StrokePhase,
    source: StrokeSource = .mouse,
    kind: StrokeSampleKind = .actual,
    capabilities: StrokeInputCapabilities = [],
    altitude: Float? = nil,
    azimuth: Float? = nil,
    roll: Float? = nil,
    tangentialPressure: Float? = nil,
    deviceIdentifier: UInt64? = nil,
    estimationUpdateIndex: Int? = nil,
    estimatedProperties: StrokeEstimatedProperties = [],
    estimatedPropertiesExpectingUpdates: StrokeEstimatedProperties = []
) throws -> StrokeSample {
    try #require(
        StrokeSample.validated(
            position: ScreenPoint(x: x, y: y),
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
    )
}

@Test
func tangentialPressureAndEstimationIdentitySurviveDerivation() throws {
    let sample = try validatedSample(
        x: 1,
        y: 2,
        pressure: 0.7,
        timestamp: 1,
        phase: .moved,
        source: .tablet,
        kind: .estimatedUpdate,
        capabilities: [.pressure, .tangentialPressure],
        tangentialPressure: 2,
        deviceIdentifier: 42,
        estimationUpdateIndex: 9,
        estimatedProperties: [.pressure],
        estimatedPropertiesExpectingUpdates: [.pressure]
    )
    var input = BrushInputDeriver()
    let world = input.derive(sample, viewport: brushInputViewport)

    #expect(world.tangentialPressure == 1)
    #expect(world.deviceIdentifier == 42)
    #expect(world.estimationUpdateIndex == 9)
    #expect(world.estimatedProperties == [.pressure])
    #expect(world.estimatedPropertiesExpectingUpdates == [.pressure])
}

@Test
func estimationValidationRejectsInvalidIdentityAndFlagRelationships() {
    let base = {
        (
            kind: StrokeSampleKind,
            index: Int?,
            capabilities: StrokeInputCapabilities,
            estimated: StrokeEstimatedProperties,
            expecting: StrokeEstimatedProperties
        ) in
        StrokeSample.validated(
            position: ScreenPoint(x: 1, y: 2),
            pressure: 0.5,
            timestamp: 1,
            phase: .moved,
            source: .pencil,
            kind: kind,
            capabilities: capabilities,
            estimationUpdateIndex: index,
            estimatedProperties: estimated,
            estimatedPropertiesExpectingUpdates: expecting
        )
    }

    #expect(base(.estimatedUpdate, nil, [.pressure], [], []) == nil)
    #expect(base(.actual, -1, [.pressure], [], []) == nil)
    #expect(base(.actual, 3, [], [.pressure], []) == nil)
    #expect(base(.actual, 3, [.pressure], [], [.pressure]) == nil)
    #expect(base(.actual, 3, [], [.location], [.location]) != nil)
    #expect(base(.actual, 3, [.pressure], [.pressure], [.pressure]) != nil)
    #expect(
        base(
            .actual,
            3,
            [.pressure],
            StrokeEstimatedProperties(rawValue: 1 << 7),
            []
        ) == nil
    )
    #expect(
        base(
            .actual,
            3,
            StrokeInputCapabilities(rawValue: 1 << 7),
            [],
            []
        ) == nil
    )
}

@Test
func missingOptionalTabletFieldsRemainAbsent() throws {
    let sample = try validatedSample(
        x: 4,
        y: 5,
        timestamp: 2,
        phase: .moved,
        source: .tablet,
        capabilities: [.pressure, .tangentialPressure]
    )

    #expect(sample.tangentialPressure == nil)
    #expect(sample.deviceIdentifier == nil)
    #expect(sample.estimationUpdateIndex == nil)
    #expect(sample.estimatedProperties.isEmpty)
    #expect(sample.estimatedPropertiesExpectingUpdates.isEmpty)
}

@Test
func estimatedUpdatesDoNotAdvanceAuthoritativeVelocityCursor() throws {
    var input = BrushInputDeriver()
    _ = input.derive(
        try validatedSample(
            x: 100,
            y: 100,
            timestamp: 1,
            phase: .began
        ),
        viewport: brushInputViewport
    )
    _ = input.derive(
        try validatedSample(
            x: 190,
            y: 100,
            timestamp: 1.5,
            phase: .moved,
            kind: .estimatedUpdate,
            estimationUpdateIndex: 7
        ),
        viewport: brushInputViewport
    )
    let actual = input.derive(
        try validatedSample(
            x: 110,
            y: 100,
            timestamp: 2,
            phase: .moved
        ),
        viewport: brushInputViewport
    )

    #expect(abs(actual.velocity - 10) < 0.001)
}

@Test
func strokeSampleRejectsNonfiniteRequiredValues() {
    #expect(
        StrokeSample.validated(
            position: ScreenPoint(x: .nan, y: 0),
            pressure: 0.5,
            timestamp: 1,
            phase: .began,
            source: .mouse
        ) == nil
    )
    #expect(
        StrokeSample.validated(
            position: ScreenPoint(x: 0, y: .infinity),
            pressure: 0.5,
            timestamp: 1,
            phase: .began,
            source: .mouse
        ) == nil
    )
    #expect(
        StrokeSample.validated(
            position: ScreenPoint(x: 0, y: 0),
            pressure: .nan,
            timestamp: 1,
            phase: .began,
            source: .mouse
        ) == nil
    )
    #expect(
        StrokeSample.validated(
            position: ScreenPoint(x: 0, y: 0),
            pressure: 0.5,
            timestamp: .infinity,
            phase: .began,
            source: .mouse
        ) == nil
    )
}

@Test
func strokeSampleNormalizesMeasuredPressureAndAngles() throws {
    let sample = try validatedSample(
        x: 10,
        y: 20,
        pressure: 1.5,
        timestamp: 1,
        phase: .moved,
        source: .pencil,
        kind: .coalesced,
        capabilities: [.pressure, .altitude, .azimuth, .roll],
        altitude: -.pi,
        azimuth: 2.5 * .pi,
        roll: -2.5 * .pi
    )
    let lowerBounds = try validatedSample(
        x: 10,
        y: 20,
        pressure: -1,
        timestamp: 2,
        phase: .moved,
        source: .pencil,
        capabilities: [.pressure, .altitude],
        altitude: .pi
    )

    #expect(sample.pressure == 1)
    #expect(sample.altitude == 0)
    #expect(abs(try #require(sample.azimuth) - (.pi / 2)) < 0.0001)
    #expect(abs(try #require(sample.roll) + (.pi / 2)) < 0.0001)
    #expect(sample.kind == .coalesced)
    #expect(
        sample.capabilities
            == [.pressure, .altitude, .azimuth, .roll]
    )
    #expect(lowerBounds.pressure == 0)
    #expect(lowerBounds.altitude == .pi / 2)
}

@Test
func strokeSampleDropsNonfiniteOptionalSensorsWithoutLosingCapabilities() throws {
    let result = try #require(
        StrokeSample.validationResult(
            position: ScreenPoint(x: 10, y: 20),
            pressure: 0.5,
            timestamp: 1,
            phase: .moved,
            source: .tablet,
            capabilities: [.altitude, .azimuth, .roll],
            altitude: .nan,
            azimuth: .infinity,
            roll: -.infinity
        )
    )
    let sample = result.sample

    #expect(sample.altitude == nil)
    #expect(sample.azimuth == nil)
    #expect(sample.roll == nil)
    #expect(sample.capabilities == [.altitude, .azimuth, .roll])
    #expect(
        result.developmentDiagnostic
            == .discardedNonfiniteOptionalSensor
    )
}

@Test
func mouseSamplePreservesNeutralCompatibilityAndAbsentSensors() {
    let sample = StrokeSample.mouse(
        position: ScreenPoint(x: 10, y: 20),
        timestamp: 3,
        phase: .began
    )

    #expect(sample.pressure == 0.5)
    #expect(sample.source == .mouse)
    #expect(sample.kind == .actual)
    #expect(sample.capabilities.isEmpty)
    #expect(sample.altitude == nil)
    #expect(sample.azimuth == nil)
    #expect(sample.roll == nil)
}

@Test
func brushInputDerivesWorldPositionAndVelocity() throws {
    var input = BrushInputDeriver()
    let began = try validatedSample(
        x: 100,
        y: 100,
        timestamp: 1,
        phase: .began
    )
    let moved = try validatedSample(
        x: 110,
        y: 100,
        timestamp: 1.1,
        phase: .moved
    )

    let worldBegan = input.derive(began, viewport: brushInputViewport)
    let worldMoved = input.derive(moved, viewport: brushInputViewport)

    #expect(worldBegan.position == WorldPoint(x: 0, y: 0))
    #expect(worldBegan.velocity == 0)
    #expect(worldMoved.position == WorldPoint(x: 10, y: 0))
    #expect(abs(worldMoved.velocity - 100) < 0.001)
    #expect(abs(worldMoved.artisticVelocity - 100) < 0.001)
    #expect(worldMoved.pressure == moved.pressure)
    #expect(worldMoved.kind == moved.kind)
}

@Test
func artisticVelocityUsesExactFortyMillisecondWorldWindow() throws {
    var input = BrushInputDeriver()
    _ = input.derive(
        try validatedSample(x: 100, y: 100, timestamp: 1, phase: .began),
        viewport: brushInputViewport
    )
    let first = input.derive(
        try validatedSample(x: 102, y: 100, timestamp: 1.02, phase: .moved),
        viewport: brushInputViewport
    )
    let mixed = input.derive(
        try validatedSample(
            x: 111,
            y: 100,
            timestamp: 1.05,
            phase: .moved,
            kind: .coalesced
        ),
        viewport: brushInputViewport
    )
    let clipped = input.derive(
        try validatedSample(x: 114, y: 100, timestamp: 1.06, phase: .moved),
        viewport: brushInputViewport
    )

    #expect(abs(first.velocity - 100) < 0.001)
    #expect(abs(first.artisticVelocity - 100) < 0.001)
    #expect(abs(mixed.velocity - 300) < 0.001)
    #expect(abs(mixed.artisticVelocity - 250) < 0.01)
    #expect(abs(clipped.velocity - 300) < 0.001)
    #expect(abs(clipped.artisticVelocity - 300) < 0.01)
}

@Test
func artisticVelocityCoalescesSubminimumTimeAndIncludesStationarySegments()
    throws
{
    var coalesced = BrushInputDeriver()
    _ = coalesced.derive(
        try validatedSample(x: 100, y: 100, timestamp: 2, phase: .began),
        viewport: brushInputViewport
    )
    let tooSoon = coalesced.derive(
        try validatedSample(
            x: 100.03,
            y: 100,
            timestamp: 2.0003,
            phase: .moved,
            kind: .coalesced
        ),
        viewport: brushInputViewport
    )
    let accepted = coalesced.derive(
        try validatedSample(x: 100.1, y: 100, timestamp: 2.001, phase: .moved),
        viewport: brushInputViewport
    )
    #expect(tooSoon.artisticVelocity == 0)
    #expect(abs(accepted.artisticVelocity - 100) < 0.02)

    var stationary = BrushInputDeriver()
    _ = stationary.derive(
        try validatedSample(x: 100, y: 100, timestamp: 3, phase: .began),
        viewport: brushInputViewport
    )
    _ = stationary.derive(
        try validatedSample(x: 100, y: 100, timestamp: 3.02, phase: .moved),
        viewport: brushInputViewport
    )
    let moved = stationary.derive(
        try validatedSample(x: 104, y: 100, timestamp: 3.04, phase: .moved),
        viewport: brushInputViewport
    )
    #expect(abs(moved.velocity - 200) < 0.001)
    #expect(abs(moved.artisticVelocity - 100) < 0.01)
}

@Test
func artisticVelocityIsInvariantToZoomAndConstantSpeedEventSplits() throws {
    let zoomedViewport = ViewportTransform(
        drawableSize: PatternSize(width: 200, height: 200),
        worldCenter: WorldPoint(x: 0, y: 0),
        zoom: 4
    )

    func derive(
        viewport: ViewportTransform,
        splits: [(WorldPoint, TimeInterval)]
    ) throws -> WorldStrokeSample {
        var input = BrushInputDeriver()
        let start = WorldPoint(x: 0, y: 0)
        _ = input.derive(
            try validatedSample(
                x: viewport.worldToScreen(start).x,
                y: viewport.worldToScreen(start).y,
                timestamp: 4,
                phase: .began
            ),
            viewport: viewport
        )
        var result: WorldStrokeSample?
        for (index, split) in splits.enumerated() {
            let screen = viewport.worldToScreen(split.0)
            result = input.derive(
                try validatedSample(
                    x: screen.x,
                    y: screen.y,
                    timestamp: 4 + split.1,
                    phase: index == splits.count - 1 ? .ended : .moved,
                    kind: index.isMultiple(of: 2) ? .coalesced : .actual
                ),
                viewport: viewport
            )
        }
        return try #require(result)
    }

    let single = try derive(
        viewport: brushInputViewport,
        splits: [(WorldPoint(x: 4, y: 0), 0.04)]
    )
    let partitioned = try derive(
        viewport: brushInputViewport,
        splits: [
            (WorldPoint(x: 1, y: 0), 0.01),
            (WorldPoint(x: 2, y: 0), 0.02),
            (WorldPoint(x: 3, y: 0), 0.03),
            (WorldPoint(x: 4, y: 0), 0.04),
        ]
    )
    let zoomed = try derive(
        viewport: zoomedViewport,
        splits: [
            (WorldPoint(x: 1, y: 0), 0.01),
            (WorldPoint(x: 2, y: 0), 0.02),
            (WorldPoint(x: 3, y: 0), 0.03),
            (WorldPoint(x: 4, y: 0), 0.04),
        ]
    )
    #expect(abs(single.artisticVelocity - 100) < 0.001)
    #expect(partitioned.artisticVelocity == single.artisticVelocity)
    #expect(zoomed.artisticVelocity == single.artisticVelocity)
}

@Test
func repeatedTimestampRetainsLastFiniteVelocity() throws {
    var input = BrushInputDeriver()
    _ = input.derive(
        try validatedSample(
            x: 100,
            y: 100,
            timestamp: 1,
            phase: .began
        ),
        viewport: brushInputViewport
    )
    let firstMove = input.derive(
        try validatedSample(
            x: 110,
            y: 100,
            timestamp: 1.1,
            phase: .moved
        ),
        viewport: brushInputViewport
    )
    let repeated = input.derive(
        try validatedSample(
            x: 130,
            y: 100,
            timestamp: 1.1,
            phase: .moved
        ),
        viewport: brushInputViewport
    )

    #expect(abs(firstMove.velocity - 100) < 0.001)
    #expect(repeated.velocity == firstMove.velocity)
}

@Test
func worldVelocityIsIndependentOfViewportZoom() throws {
    let unitViewport = brushInputViewport
    let zoomedViewport = ViewportTransform(
        drawableSize: PatternSize(width: 200, height: 200),
        worldCenter: WorldPoint(x: 0, y: 0),
        zoom: 4
    )
    let start = WorldPoint(x: 0, y: 0)
    let end = WorldPoint(x: 25, y: 0)
    var unitInput = BrushInputDeriver()
    var zoomedInput = BrushInputDeriver()

    _ = unitInput.derive(
        try validatedSample(
            x: unitViewport.worldToScreen(start).x,
            y: unitViewport.worldToScreen(start).y,
            timestamp: 1,
            phase: .began
        ),
        viewport: unitViewport
    )
    let unitMove = unitInput.derive(
        try validatedSample(
            x: unitViewport.worldToScreen(end).x,
            y: unitViewport.worldToScreen(end).y,
            timestamp: 1.25,
            phase: .moved
        ),
        viewport: unitViewport
    )
    _ = zoomedInput.derive(
        try validatedSample(
            x: zoomedViewport.worldToScreen(start).x,
            y: zoomedViewport.worldToScreen(start).y,
            timestamp: 1,
            phase: .began
        ),
        viewport: zoomedViewport
    )
    let zoomedMove = zoomedInput.derive(
        try validatedSample(
            x: zoomedViewport.worldToScreen(end).x,
            y: zoomedViewport.worldToScreen(end).y,
            timestamp: 1.25,
            phase: .moved
        ),
        viewport: zoomedViewport
    )

    #expect(abs(unitMove.velocity - 100) < 0.001)
    #expect(zoomedMove.velocity == unitMove.velocity)
}

@Test
func brushInputCapsVelocityAtNamedContract() throws {
    var input = BrushInputDeriver()
    _ = input.derive(
        try validatedSample(
            x: 100,
            y: 100,
            timestamp: 1,
            phase: .began
        ),
        viewport: brushInputViewport
    )
    let moved = input.derive(
        try validatedSample(
            x: 10_000,
            y: 100,
            timestamp: 1.000_001,
            phase: .moved
        ),
        viewport: brushInputViewport
    )

    #expect(moved.velocity == BrushInputContract.maximumWorldVelocity)
}

@Test
func predictedSamplesDoNotAdvanceAuthoritativeVelocityState() throws {
    var input = BrushInputDeriver()
    _ = input.derive(
        try validatedSample(
            x: 100,
            y: 100,
            timestamp: 1,
            phase: .began
        ),
        viewport: brushInputViewport
    )
    let predicted = input.derive(
        try validatedSample(
            x: 200,
            y: 100,
            timestamp: 2,
            phase: .moved,
            kind: .predicted
        ),
        viewport: brushInputViewport
    )
    let actual = input.derive(
        try validatedSample(
            x: 110,
            y: 100,
            timestamp: 2,
            phase: .moved
        ),
        viewport: brushInputViewport
    )

    #expect(predicted.velocity == 100)
    #expect(predicted.artisticVelocity == 100)
    #expect(actual.velocity == 10)
    #expect(actual.artisticVelocity == 10)
}

@Test
func copiedPredictionCursorChainsSuffixWithoutMutatingAuthoritativeState() throws {
    var authoritative = BrushInputDeriver()
    _ = authoritative.derive(
        try validatedSample(
            x: 100,
            y: 100,
            timestamp: 1,
            phase: .began
        ),
        viewport: brushInputViewport
    )
    var prediction = authoritative

    let first = prediction.deriveAdvancingPrediction(
        try validatedSample(
            x: 120,
            y: 100,
            timestamp: 2,
            phase: .moved,
            kind: .predicted
        ),
        viewport: brushInputViewport
    )
    let second = prediction.deriveAdvancingPrediction(
        try validatedSample(
            x: 150,
            y: 100,
            timestamp: 3,
            phase: .moved,
            kind: .predicted
        ),
        viewport: brushInputViewport
    )
    let actual = authoritative.derive(
        try validatedSample(
            x: 110,
            y: 100,
            timestamp: 3,
            phase: .moved
        ),
        viewport: brushInputViewport
    )

    #expect(abs(first.velocity - 20) < 0.001)
    #expect(abs(first.artisticVelocity - 20) < 0.001)
    #expect(abs(second.velocity - 30) < 0.001)
    #expect(abs(second.artisticVelocity - 30) < 0.001)
    #expect(abs(actual.velocity - 5) < 0.001)
    #expect(abs(actual.artisticVelocity - 5) < 0.001)
}

@Test
func cancellationResetsBrushInputVelocityState() throws {
    var input = BrushInputDeriver()
    _ = input.derive(
        try validatedSample(
            x: 100,
            y: 100,
            timestamp: 1,
            phase: .began
        ),
        viewport: brushInputViewport
    )
    _ = input.derive(
        try validatedSample(
            x: 110,
            y: 100,
            timestamp: 1.1,
            phase: .moved
        ),
        viewport: brushInputViewport
    )
    let cancelled = input.derive(
        try validatedSample(
            x: 120,
            y: 100,
            timestamp: 1.2,
            phase: .cancelled
        ),
        viewport: brushInputViewport
    )
    let afterCancel = input.derive(
        try validatedSample(
            x: 150,
            y: 100,
            timestamp: 2,
            phase: .moved
        ),
        viewport: brushInputViewport
    )

    #expect(cancelled.velocity == 0)
    #expect(cancelled.artisticVelocity == 0)
    #expect(afterCancel.velocity == 0)
    #expect(afterCancel.artisticVelocity == 0)
}

@Test
func predictionCopiesPreserveCompleteArtisticStateWithoutAdvancingActual()
    throws
{
    func prefix() throws -> BrushInputDeriver {
        var input = BrushInputDeriver()
        _ = input.derive(
            try validatedSample(x: 100, y: 100, timestamp: 10, phase: .began),
            viewport: brushInputViewport
        )
        _ = input.derive(
            try validatedSample(x: 101, y: 100, timestamp: 10.01, phase: .moved),
            viewport: brushInputViewport
        )
        _ = input.derive(
            try validatedSample(x: 104, y: 100, timestamp: 10.02, phase: .moved),
            viewport: brushInputViewport
        )
        return input
    }

    var authoritative = try prefix()
    var baseline = try prefix()
    var prediction = authoritative
    let predictedA = prediction.deriveAdvancingPrediction(
        try validatedSample(
            x: 108, y: 100, timestamp: 10.03, phase: .moved,
            kind: .predicted
        ),
        viewport: brushInputViewport
    )
    let predictedB = prediction.deriveAdvancingPrediction(
        try validatedSample(
            x: 113, y: 100, timestamp: 10.04, phase: .moved,
            kind: .predicted
        ),
        viewport: brushInputViewport
    )
    let actualSample = try validatedSample(
        x: 106, y: 100, timestamp: 10.04, phase: .moved
    )
    let actualAfterPrediction = authoritative.derive(
        actualSample, viewport: brushInputViewport
    )
    let actualBaseline = baseline.derive(
        actualSample, viewport: brushInputViewport
    )

    #expect(predictedA.artisticVelocity > 0)
    #expect(predictedB.artisticVelocity > predictedA.artisticVelocity)
    #expect(actualAfterPrediction == actualBaseline)
    #expect(authoritative == baseline)
}

@Test
func nonpositiveTimeDoesNotMutateArtisticVelocityFilter() throws {
    func prefix() throws -> BrushInputDeriver {
        var input = BrushInputDeriver()
        _ = input.derive(
            try validatedSample(x: 100, y: 100, timestamp: 20, phase: .began),
            viewport: brushInputViewport
        )
        _ = input.derive(
            try validatedSample(x: 101, y: 100, timestamp: 20.01, phase: .moved),
            viewport: brushInputViewport
        )
        return input
    }
    var control = try prefix()
    var withInvalidTime = try prefix()
    _ = withInvalidTime.derive(
        try validatedSample(x: 199, y: 100, timestamp: 20.01, phase: .moved),
        viewport: brushInputViewport
    )
    let next = try validatedSample(
        x: 105, y: 100, timestamp: 20.03, phase: .moved
    )
    let expected = control.derive(next, viewport: brushInputViewport)
    let actual = withInvalidTime.derive(next, viewport: brushInputViewport)

    #expect(actual.artisticVelocity == expected.artisticVelocity)
    #expect(actual.velocity != expected.velocity)
}

@Test
func finishAndRapidNextStrokeResetBothVelocityChannels() throws {
    var input = BrushInputDeriver()
    _ = input.derive(
        try validatedSample(x: 100, y: 100, timestamp: 30, phase: .began),
        viewport: brushInputViewport
    )
    let ended = input.derive(
        try validatedSample(x: 104, y: 100, timestamp: 30.02, phase: .ended),
        viewport: brushInputViewport
    )
    let next = input.derive(
        try validatedSample(x: 150, y: 100, timestamp: 30.03, phase: .moved),
        viewport: brushInputViewport
    )

    #expect(ended.velocity == 200)
    #expect(ended.artisticVelocity == 200)
    #expect(next.velocity == 0)
    #expect(next.artisticVelocity == 0)
}

@Test
func incompleteFilterCheckpointIsAVisibleMutationNegativeControl() throws {
    var complete = BrushInputDeriver()
    _ = complete.derive(
        try validatedSample(x: 100, y: 100, timestamp: 40, phase: .began),
        viewport: brushInputViewport
    )
    _ = complete.derive(
        try validatedSample(x: 101, y: 100, timestamp: 40.01, phase: .moved),
        viewport: brushInputViewport
    )
    _ = complete.derive(
        try validatedSample(x: 104, y: 100, timestamp: 40.02, phase: .moved),
        viewport: brushInputViewport
    )

    // This checkpoint has the same legacy position/time/instantaneous-speed
    // cursor, but intentionally omits the first 10 ms filter segment.
    var omitted = BrushInputDeriver()
    _ = omitted.derive(
        try validatedSample(x: 101, y: 100, timestamp: 40.01, phase: .began),
        viewport: brushInputViewport
    )
    _ = omitted.derive(
        try validatedSample(x: 104, y: 100, timestamp: 40.02, phase: .moved),
        viewport: brushInputViewport
    )
    let continuation = try validatedSample(
        x: 108, y: 100, timestamp: 40.03, phase: .moved
    )
    let correct = complete.derive(continuation, viewport: brushInputViewport)
    let mutated = omitted.derive(continuation, viewport: brushInputViewport)

    #expect(complete != omitted)
    #expect(correct.artisticVelocity != mutated.artisticVelocity)
    #expect(correct.velocity == mutated.velocity)
}

@Test
func sharedTraceWorldPositionsStillMatchLegacyViewportConversion() {
    var input = BrushInputDeriver()

    for sample in StrokeTraceFixtures.gridSeam.samples {
        let derived = input.derive(sample, viewport: brushInputViewport)
        #expect(
            derived.position
                == brushInputViewport.screenToWorld(sample.position)
        )
    }
}
