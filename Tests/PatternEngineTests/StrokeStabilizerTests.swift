import Foundation
import PatternEngine
import Testing

private let stabilizerViewport = ViewportTransform(
    drawableSize: PatternSize(width: 2, height: 2),
    worldCenter: WorldPoint(x: 0, y: 0)
)

private func worldSample(
    x: Float,
    y: Float = 0,
    pressure: Float = 0.5,
    timestamp: TimeInterval,
    phase: StrokePhase,
    source: StrokeSource = .pencil,
    kind: StrokeSampleKind = .actual,
    capabilities: StrokeInputCapabilities = [.pressure],
    altitude: Float? = nil,
    azimuth: Float? = nil,
    roll: Float? = nil
) -> WorldStrokeSample {
    let sample = StrokeSample(
        position: ScreenPoint(x: x + 1, y: y + 1),
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
    var deriver = BrushInputDeriver()
    return deriver.derive(sample, viewport: stabilizerViewport)
}

@Suite("StrokeStabilizer")
struct StrokeStabilizerTests {
    @Test
    func zeroStrengthIsBitForBitIdentity() {
        var stabilizer = StrokeStabilizer(strength: 0)
        let samples = [
            worldSample(x: -3, pressure: 0.2, timestamp: 1, phase: .began),
            worldSample(
                x: 7,
                y: 4,
                pressure: 0.9,
                timestamp: 2,
                phase: .moved,
                kind: .coalesced,
                capabilities: [.pressure, .altitude, .azimuth, .roll],
                altitude: 0.7,
                azimuth: 1.2,
                roll: -0.4
            ),
            worldSample(x: 9, timestamp: 3, phase: .ended),
        ]

        let output = samples.map { stabilizer.process($0) }

        #expect(output == samples)
    }

    @Test
    func deterministicCarryUsesBoundedState() {
        var stabilizer = StrokeStabilizer(strength: 0.5)

        let positions = [
            stabilizer.process(
                worldSample(x: 0, timestamp: 0, phase: .began)
            ).position,
            stabilizer.process(
                worldSample(x: 10, timestamp: 1, phase: .moved)
            ).position,
            stabilizer.process(
                worldSample(x: 10, timestamp: 2, phase: .moved)
            ).position,
        ]

        #expect(positions == [
            WorldPoint(x: 0, y: 0),
            WorldPoint(x: 5, y: 0),
            WorldPoint(x: 7.5, y: 0),
        ])
    }

    @Test
    func changesOnlyPositionAndPreservesAttributeOrder() {
        var stabilizer = StrokeStabilizer(strength: 0.75)
        let first = worldSample(
            x: 0,
            pressure: 0.15,
            timestamp: 10,
            phase: .began,
            source: .tablet,
            kind: .actual,
            capabilities: [.pressure, .azimuth],
            azimuth: -2
        )
        let second = worldSample(
            x: 8,
            pressure: 0.85,
            timestamp: 11,
            phase: .moved,
            source: .pencil,
            kind: .coalesced,
            capabilities: [.pressure, .altitude, .roll],
            altitude: 0.4,
            roll: 1.1
        )

        _ = stabilizer.process(first)
        let output = stabilizer.process(second)

        #expect(output.position == WorldPoint(x: 2, y: 0))
        #expect(output.pressure == second.pressure)
        #expect(output.timestamp == second.timestamp)
        #expect(output.altitude == second.altitude)
        #expect(output.azimuth == second.azimuth)
        #expect(output.roll == second.roll)
        #expect(output.velocity == second.velocity)
        #expect(output.phase == second.phase)
        #expect(output.source == second.source)
        #expect(output.kind == second.kind)
        #expect(output.capabilities == second.capabilities)
    }

    @Test
    func cancelDropsCarry() {
        var stabilizer = StrokeStabilizer(strength: 0.5)
        _ = stabilizer.process(
            worldSample(x: 0, timestamp: 0, phase: .began)
        )
        _ = stabilizer.process(
            worldSample(x: 10, timestamp: 1, phase: .moved)
        )
        let cancelled = worldSample(
            x: 20,
            timestamp: 2,
            phase: .cancelled
        )

        #expect(stabilizer.process(cancelled) == cancelled)
        let restarted = stabilizer.process(
            worldSample(x: 40, timestamp: 3, phase: .moved)
        )
        #expect(restarted.position == WorldPoint(x: 40, y: 0))
    }

    @Test
    func copiedStateCanEvaluatePredictionWithoutAdvancingActualCarry() {
        var actual = StrokeStabilizer(strength: 0.5)
        _ = actual.process(
            worldSample(x: 0, timestamp: 0, phase: .began)
        )
        _ = actual.process(
            worldSample(x: 10, timestamp: 1, phase: .moved)
        )

        var predicted = actual
        let predictedOutput = predicted.process(
            worldSample(
                x: 20,
                timestamp: 2,
                phase: .moved,
                kind: .predicted
            )
        )
        let actualOutput = actual.process(
            worldSample(x: 12, timestamp: 2, phase: .moved)
        )

        #expect(predictedOutput.position == WorldPoint(x: 12.5, y: 0))
        #expect(actualOutput.position == WorldPoint(x: 8.5, y: 0))
    }
}
