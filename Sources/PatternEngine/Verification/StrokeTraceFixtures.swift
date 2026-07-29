import Foundation

/// Platform-free input traces shared by pure, renderer, and harness tests.
///
/// These fixtures describe the Slice 3 stroke-input baseline. Slice 4 extends
/// their samples additively as BrushInput V2 lands; it must not silently change
/// the existing positions, pressures, timestamps, lifecycle, or sources.
public struct StrokeTraceFixture: Equatable, Sendable {
    public let name: String
    public let samples: [StrokeSample]

    public init(name: String, samples: [StrokeSample]) {
        precondition(!name.isEmpty)
        precondition(!samples.isEmpty)
        self.name = name
        self.samples = samples
    }
}

public enum StrokeTraceFixtures {
    public static let click = StrokeTraceFixture(
        name: "click",
        samples: [
            sample(40, 40, pressure: 0.5, timestamp: 1, phase: .began),
            sample(40, 40, pressure: 0.5, timestamp: 1.01, phase: .ended),
        ]
    )

    public static let straight = StrokeTraceFixture(
        name: "straight",
        samples: [
            sample(0, 0, pressure: 0.25, timestamp: 2, phase: .began),
            sample(5, 0, pressure: 0.5, timestamp: 2.01, phase: .moved),
            sample(6, 0, pressure: 0.75, timestamp: 2.02, phase: .ended),
        ]
    )

    public static let curved = StrokeTraceFixture(
        name: "curved",
        samples: [
            sample(0, 0, pressure: 0.2, timestamp: 3, phase: .began),
            sample(7.5, 0, pressure: 0.5, timestamp: 3.01, phase: .moved),
            sample(7.5, 7.5, pressure: 0.9, timestamp: 3.02, phase: .ended),
        ]
    )

    public static let repeatedTimestamp = StrokeTraceFixture(
        name: "repeated-timestamp",
        samples: [
            sample(8, 8, pressure: 0.3, timestamp: 4, phase: .began),
            sample(12, 8, pressure: 0.6, timestamp: 4, phase: .moved),
            sample(16, 8, pressure: 0.9, timestamp: 4.01, phase: .ended),
        ]
    )

    public static let pressureRamp = StrokeTraceFixture(
        name: "pressure-ramp",
        samples: [
            sample(
                24,
                32,
                pressure: 0.1,
                timestamp: 5,
                phase: .began,
                source: .pencil
            ),
            sample(
                32,
                32,
                pressure: 0.4,
                timestamp: 5.01,
                phase: .moved,
                source: .pencil
            ),
            sample(
                40,
                32,
                pressure: 0.7,
                timestamp: 5.02,
                phase: .moved,
                source: .pencil
            ),
            sample(
                48,
                32,
                pressure: 1,
                timestamp: 5.03,
                phase: .ended,
                source: .pencil
            ),
        ]
    )

    /// Authoritative input replaces an earlier predicted tail without allowing
    /// that tail to advance the committed stroke generator.
    public static let predictionCorrection = StrokeTraceFixture(
        name: "prediction-correction",
        samples: [
            sample(24, 32, pressure: 0.2, timestamp: 5, phase: .began,
                   source: .pencil),
            sample(30, 32, pressure: 0.35, timestamp: 5.01, phase: .moved,
                   source: .pencil, kind: .coalesced),
            sample(36, 32, pressure: 0.5, timestamp: 5.02, phase: .moved,
                   source: .pencil, kind: .coalesced),
            sample(42, 32, pressure: 0.65, timestamp: 5.03, phase: .moved,
                   source: .pencil, kind: .predicted),
            sample(48, 32, pressure: 0.8, timestamp: 5.04, phase: .moved,
                   source: .pencil, kind: .predicted),
            sample(43, 32, pressure: 0.7, timestamp: 5.03, phase: .moved,
                   source: .pencil),
            sample(46, 32, pressure: 0.85, timestamp: 5.04, phase: .moved,
                   source: .pencil),
            sample(50, 32, pressure: 1, timestamp: 5.05, phase: .ended,
                   source: .pencil),
        ]
    )

    public static let gridSeam = StrokeTraceFixture(
        name: "grid-seam",
        samples: [
            sample(250, 128, pressure: 0.5, timestamp: 6, phase: .began),
            sample(256, 128, pressure: 0.5, timestamp: 6.01, phase: .moved),
            sample(262, 128, pressure: 0.5, timestamp: 6.02, phase: .ended),
        ]
    )

    public static let reflectedCell = StrokeTraceFixture(
        name: "reflected-cell",
        samples: [
            sample(
                276,
                96,
                pressure: 0.35,
                timestamp: 7,
                phase: .began,
                source: .tablet
            ),
            sample(
                288,
                104,
                pressure: 0.65,
                timestamp: 7.01,
                phase: .moved,
                source: .tablet
            ),
            sample(
                300,
                128,
                pressure: 0.8,
                timestamp: 7.02,
                phase: .ended,
                source: .tablet
            ),
        ]
    )

    public static let long = StrokeTraceFixture(
        name: "long",
        samples: longSamples()
    )

    public static let all: [StrokeTraceFixture] = [
        click,
        straight,
        curved,
        repeatedTimestamp,
        pressureRamp,
        predictionCorrection,
        gridSeam,
        reflectedCell,
        long,
    ]

    // These explicit normalized samples are the versioned Stage 5
    // calibration corpus. Changing them changes characterization baselines.
    public static let professionalTap = StrokeTraceFixture(
        name: "professional-tap",
        samples: [
            professionalSample(256, 256, timestamp: 1, phase: .began),
            professionalSample(256, 256, timestamp: 1.01, phase: .ended),
        ]
    )

    public static let professionalSlowLine = StrokeTraceFixture(
        name: "professional-slow-line",
        samples: [
            professionalSample(64, 128, timestamp: 10, phase: .began),
            professionalSample(256, 128, timestamp: 11, phase: .moved),
            professionalSample(448, 128, timestamp: 12, phase: .ended),
        ]
    )

    public static let professionalFastLine = StrokeTraceFixture(
        name: "professional-fast-line",
        samples: [
            professionalSample(64, 128, timestamp: 20, phase: .began),
            professionalSample(256, 128, timestamp: 20.02, phase: .moved),
            professionalSample(448, 128, timestamp: 20.04, phase: .ended),
        ]
    )

    public static let professionalPressureRamp = StrokeTraceFixture(
        name: "professional-pressure-ramp",
        samples: [
            professionalSample(64, 200, pressure: 0.1, timestamp: 30,
                               phase: .began, source: .pencil),
            professionalSample(192, 200, pressure: 0.4, timestamp: 30.1,
                               phase: .moved, source: .pencil,
                               kind: .coalesced),
            professionalSample(320, 200, pressure: 0.7, timestamp: 30.2,
                               phase: .moved, source: .pencil),
            professionalSample(448, 200, pressure: 1, timestamp: 30.3,
                               phase: .ended, source: .pencil),
        ]
    )

    public static let professionalTiltSweep = StrokeTraceFixture(
        name: "professional-tilt-sweep",
        samples: [
            professionalSample(80, 64, pressure: 0.3, timestamp: 40,
                               phase: .began, source: .tablet, altitude: 0.1,
                               azimuth: 0.25),
            professionalSample(80, 256, pressure: 0.6, timestamp: 40.1,
                               phase: .moved, source: .tablet, altitude: 0.6,
                               azimuth: 0.5),
            professionalSample(80, 448, pressure: 0.9, timestamp: 40.2,
                               phase: .ended, source: .tablet, altitude: 1.2,
                               azimuth: 0.75),
        ]
    )

    /// Predicted input is replaced at the same timestamp by an authoritative
    /// correction before the stroke continues along a new direction.
    public static let professionalDirectionTurn = StrokeTraceFixture(
        name: "professional-direction-turn",
        samples: [
            professionalSample(64, 64, pressure: 0.4, timestamp: 50,
                               phase: .began, source: .pencil),
            professionalSample(256, 64, pressure: 0.6, timestamp: 50.1,
                               phase: .moved, source: .pencil),
            professionalSample(256, 256, pressure: 0.8, timestamp: 50.2,
                               phase: .moved, source: .pencil,
                               kind: .predicted),
            professionalSample(256, 224, pressure: 0.8, timestamp: 50.2,
                               phase: .moved, source: .pencil),
            professionalSample(384, 224, pressure: 1, timestamp: 50.3,
                               phase: .ended, source: .pencil),
        ]
    )

    public static let professionalCorner = StrokeTraceFixture(
        name: "professional-corner",
        samples: [
            professionalSample(64, 448, pressure: 0.5, timestamp: 60,
                               phase: .began, source: .pencil),
            professionalSample(256, 448, pressure: 0.5, timestamp: 60.1,
                               phase: .moved, source: .pencil),
            professionalSample(256, 256, pressure: 0.5, timestamp: 60.2,
                               phase: .moved, source: .pencil),
            professionalSample(384, 256, pressure: 0.5, timestamp: 60.3,
                               phase: .ended, source: .pencil),
        ]
    )

    /// Connected vertical travel keeps the three horizontal hatch passes in
    /// one legal stroke lifecycle.
    public static let professionalHatching = StrokeTraceFixture(
        name: "professional-hatching",
        samples: [
            professionalSample(64, 128, pressure: 0.5, timestamp: 70,
                               phase: .began, source: .pencil),
            professionalSample(448, 128, pressure: 0.5, timestamp: 70.1,
                               phase: .moved, source: .pencil),
            professionalSample(448, 160, pressure: 0.5, timestamp: 70.2,
                               phase: .moved, source: .pencil),
            professionalSample(64, 160, pressure: 0.5, timestamp: 70.3,
                               phase: .moved, source: .pencil),
            professionalSample(64, 192, pressure: 0.5, timestamp: 70.4,
                               phase: .moved, source: .pencil),
            professionalSample(448, 192, pressure: 0.5, timestamp: 70.5,
                               phase: .ended, source: .pencil),
        ]
    )

    public static let professionalGridSeam = StrokeTraceFixture(
        name: "professional-grid-seam",
        samples: [
            professionalSample(224, 320, pressure: 0.5, timestamp: 80,
                               phase: .began, source: .pencil),
            professionalSample(256, 320, pressure: 0.5, timestamp: 80.1,
                               phase: .moved, source: .pencil),
            professionalSample(288, 320, pressure: 0.5, timestamp: 80.2,
                               phase: .ended, source: .pencil),
        ]
    )

    public static let professionalRadialSpoke = StrokeTraceFixture(
        name: "professional-radial-spoke",
        samples: [
            professionalSample(256, 256, pressure: 0.3, timestamp: 90,
                               phase: .began, source: .pencil),
            professionalSample(352, 256, pressure: 0.6, timestamp: 90.1,
                               phase: .moved, source: .pencil),
            professionalSample(448, 256, pressure: 0.9, timestamp: 90.2,
                               phase: .ended, source: .pencil),
        ]
    )

    public static let professional: [StrokeTraceFixture] = [
        professionalTap,
        professionalSlowLine,
        professionalFastLine,
        professionalPressureRamp,
        professionalTiltSweep,
        professionalDirectionTurn,
        professionalCorner,
        professionalHatching,
        professionalGridSeam,
        professionalRadialSpoke,
    ]

    private static func sample(
        _ x: Float,
        _ y: Float,
        pressure: Float,
        timestamp: TimeInterval,
        phase: StrokePhase,
        source: StrokeSource = .mouse,
        kind: StrokeSampleKind = .actual
    ) -> StrokeSample {
        StrokeSample(
            position: ScreenPoint(x: x, y: y),
            pressure: pressure,
            timestamp: timestamp,
            phase: phase,
            source: source,
            kind: kind,
            capabilities: source == .mouse ? [] : [.pressure]
        )
    }

    private static func professionalSample(
        _ x: Float,
        _ y: Float,
        pressure: Float = 0.5,
        timestamp: TimeInterval,
        phase: StrokePhase,
        source: StrokeSource = .mouse,
        kind: StrokeSampleKind = .actual,
        altitude: Float? = nil,
        azimuth: Float? = nil
    ) -> StrokeSample {
        let capabilities: StrokeInputCapabilities = source == .mouse
            ? []
            : altitude == nil && azimuth == nil
                ? [.pressure]
                : [.pressure, .altitude, .azimuth]
        return StrokeSample(
            position: ScreenPoint(x: x, y: y),
            pressure: pressure,
            timestamp: timestamp,
            phase: phase,
            source: source,
            kind: kind,
            capabilities: capabilities,
            altitude: altitude,
            azimuth: azimuth
        )
    }

    private static func longSamples() -> [StrokeSample] {
        var samples = [
            sample(0, 32, pressure: 0.5, timestamp: 8, phase: .began),
        ]
        samples.reserveCapacity(66)
        for index in 1...64 {
            samples.append(
                sample(
                    Float(index * 16),
                    32 + Float((index % 4) * 3),
                    pressure: 0.5,
                    timestamp: 8 + Double(index) * 0.01,
                    phase: .moved
                )
            )
        }
        samples.append(
            sample(
                1_040,
                32,
                pressure: 0.5,
                timestamp: 8.65,
                phase: .ended
            )
        )
        return samples
    }
}
