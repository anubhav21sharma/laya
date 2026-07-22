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
    roll: Float? = nil
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
            roll: roll
        )
    )
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
    #expect(worldMoved.pressure == moved.pressure)
    #expect(worldMoved.kind == moved.kind)
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
    #expect(actual.velocity == 10)
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
    #expect(abs(second.velocity - 30) < 0.001)
    #expect(abs(actual.velocity - 5) < 0.001)
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
    #expect(afterCancel.velocity == 0)
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
