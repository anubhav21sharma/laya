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
        gridSeam,
        reflectedCell,
        long,
    ]

    private static func sample(
        _ x: Float,
        _ y: Float,
        pressure: Float,
        timestamp: TimeInterval,
        phase: StrokePhase,
        source: StrokeSource = .mouse
    ) -> StrokeSample {
        StrokeSample(
            position: ScreenPoint(x: x, y: y),
            pressure: pressure,
            timestamp: timestamp,
            phase: phase,
            source: source,
            capabilities: source == .mouse ? [] : [.pressure]
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
