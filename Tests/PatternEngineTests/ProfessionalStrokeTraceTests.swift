import Foundation
import PatternEngine
import Testing

@Test
func professionalTraceCorpusPinsItsOrderedLifecycleAndCapabilities() {
    // These literals are the versioned Stage 5 calibration corpus. Changing
    // them is a schema/baseline decision, not an incidental fixture edit.
    #expect(StrokeTraceFixtures.professional.map(\.name) == [
        "professional-tap",
        "professional-slow-line",
        "professional-fast-line",
        "professional-pressure-ramp",
        "professional-tilt-sweep",
        "professional-direction-turn",
        "professional-corner",
        "professional-hatching",
        "professional-grid-seam",
        "professional-radial-spoke",
    ])

    for trace in StrokeTraceFixtures.professional {
        #expect(trace.samples.filter { $0.phase == .began }.count == 1)
        #expect(trace.samples.filter { $0.phase == .ended }.count == 1)
        #expect(trace.samples.map(\.timestamp) == trace.samples.map(\.timestamp).sorted())
        #expect(trace.samples.allSatisfy {
            $0.position.x.isFinite && $0.position.y.isFinite
                && $0.pressure.isFinite && $0.timestamp.isFinite
        })
    }

    #expect(StrokeTraceFixtures.professional.map { $0.samples.map(sample) }
        == expectedProfessionalCorpus)
}

@Test
func correctiveTraceCorpusPinsReportedDirectInputFailures() {
    #expect(StrokeTraceFixtures.corrective.map(\.name) == [
        "corrective-technical-ink-ten-second-line",
        "corrective-technical-ink-fast-release",
        "corrective-graphite-forty-pixel-line",
        "corrective-charcoal-neutral-pressure-line",
        "corrective-chisel-right-angle",
        "corrective-chisel-circle",
    ])

    for trace in StrokeTraceFixtures.corrective {
        #expect(trace.samples.first?.phase == .began)
        #expect(trace.samples.last?.phase == .ended)
        #expect(trace.samples.filter { $0.phase == .began }.count == 1)
        #expect(trace.samples.filter { $0.phase == .ended }.count == 1)
        #expect(
            trace.samples.map(\.timestamp)
                == trace.samples.map(\.timestamp).sorted()
        )
    }

    let sustained = StrokeTraceFixtures.correctiveTechnicalInkTenSecondLine
    #expect(sustained.samples.count == 121)
    #expect(sustained.samples.first?.position == ScreenPoint(x: 64, y: 128))
    #expect(sustained.samples.first?.timestamp == 100)
    #expect(sustained.samples.last?.position == ScreenPoint(x: 448, y: 128))
    #expect(sustained.samples.last?.timestamp == 110)

    let release = StrokeTraceFixtures.correctiveTechnicalInkFastRelease
    #expect(release.samples.map(\.timestamp) == [200, 200.08, 200.081])
    #expect(release.samples.map(\.position) == [
        ScreenPoint(x: 64, y: 224),
        ScreenPoint(x: 416, y: 224),
        ScreenPoint(x: 448, y: 224),
    ])

    let graphite = StrokeTraceFixtures.correctiveGraphiteFortyPixelLine
    #expect(graphite.samples.allSatisfy { $0.pressure == 0.5 })
    #expect(graphite.samples.allSatisfy { $0.source == .mouse })

    let charcoal = StrokeTraceFixtures.correctiveCharcoalNeutralPressureLine
    #expect(charcoal.samples.allSatisfy { $0.pressure == 0.5 })
    #expect(charcoal.samples.allSatisfy { $0.source == .pencil })
    #expect(charcoal.samples.allSatisfy {
        $0.capabilities == [.pressure]
    })

    let corner = StrokeTraceFixtures.correctiveChiselRightAngle
    #expect(corner.samples.map(\.position) == [
        ScreenPoint(x: 96, y: 400),
        ScreenPoint(x: 256, y: 400),
        ScreenPoint(x: 256, y: 240),
        ScreenPoint(x: 416, y: 240),
    ])

    let circle = StrokeTraceFixtures.correctiveChiselCircle
    #expect(circle.samples.count == 33)
    #expect(circle.samples.first?.position == circle.samples.last?.position)
    #expect(circle.samples.first?.timestamp == 500)
    #expect(circle.samples.last?.timestamp == 501.6)
}

private struct ExpectedProfessionalSample: Equatable {
    let position: ScreenPoint
    let pressure: Float
    let timestamp: TimeInterval
    let phase: StrokePhase
    let source: StrokeSource
    let kind: StrokeSampleKind
    let capabilities: StrokeInputCapabilities
    let altitude: Float?
    let azimuth: Float?
    let roll: Float?
    let tangentialPressure: Float?
    let deviceIdentifier: UInt64?
    let estimationUpdateIndex: Int?
    let estimatedProperties: StrokeEstimatedProperties
    let estimatedPropertiesExpectingUpdates: StrokeEstimatedProperties
}

private func sample(_ sample: StrokeSample) -> ExpectedProfessionalSample {
    ExpectedProfessionalSample(
        position: sample.position,
        pressure: sample.pressure,
        timestamp: sample.timestamp,
        phase: sample.phase,
        source: sample.source,
        kind: sample.kind,
        capabilities: sample.capabilities,
        altitude: sample.altitude,
        azimuth: sample.azimuth,
        roll: sample.roll,
        tangentialPressure: sample.tangentialPressure,
        deviceIdentifier: sample.deviceIdentifier,
        estimationUpdateIndex: sample.estimationUpdateIndex,
        estimatedProperties: sample.estimatedProperties,
        estimatedPropertiesExpectingUpdates:
            sample.estimatedPropertiesExpectingUpdates
    )
}

private func expected(
    _ x: Float,
    _ y: Float,
    pressure: Float,
    timestamp: TimeInterval,
    phase: StrokePhase,
    source: StrokeSource,
    kind: StrokeSampleKind = .actual,
    capabilities: StrokeInputCapabilities,
    altitude: Float? = nil,
    azimuth: Float? = nil,
    roll: Float? = nil,
    tangentialPressure: Float? = nil,
    deviceIdentifier: UInt64? = nil,
    estimationUpdateIndex: Int? = nil,
    estimatedProperties: StrokeEstimatedProperties = [],
    estimatedPropertiesExpectingUpdates: StrokeEstimatedProperties = []
) -> ExpectedProfessionalSample {
    ExpectedProfessionalSample(
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
        estimatedPropertiesExpectingUpdates: estimatedPropertiesExpectingUpdates
    )
}

private let expectedProfessionalCorpus: [[ExpectedProfessionalSample]] = [
    [
        expected(256, 256, pressure: 0.5, timestamp: 1, phase: .began,
                 source: .mouse, capabilities: []),
        expected(256, 256, pressure: 0.5, timestamp: 1.01, phase: .ended,
                 source: .mouse, capabilities: []),
    ],
    [
        expected(64, 128, pressure: 0.5, timestamp: 10, phase: .began,
                 source: .mouse, capabilities: []),
        expected(256, 128, pressure: 0.5, timestamp: 11, phase: .moved,
                 source: .mouse, capabilities: []),
        expected(448, 128, pressure: 0.5, timestamp: 12, phase: .ended,
                 source: .mouse, capabilities: []),
    ],
    [
        expected(64, 128, pressure: 0.5, timestamp: 20, phase: .began,
                 source: .mouse, capabilities: []),
        expected(256, 128, pressure: 0.5, timestamp: 20.02, phase: .moved,
                 source: .mouse, capabilities: []),
        expected(448, 128, pressure: 0.5, timestamp: 20.04, phase: .ended,
                 source: .mouse, capabilities: []),
    ],
    [
        expected(64, 200, pressure: 0.1, timestamp: 30, phase: .began,
                 source: .pencil, capabilities: [.pressure]),
        expected(192, 200, pressure: 0.4, timestamp: 30.1, phase: .moved,
                 source: .pencil, kind: .coalesced, capabilities: [.pressure]),
        expected(320, 200, pressure: 0.7, timestamp: 30.2, phase: .moved,
                 source: .pencil, capabilities: [.pressure]),
        expected(448, 200, pressure: 1, timestamp: 30.3, phase: .ended,
                 source: .pencil, capabilities: [.pressure]),
    ],
    [
        expected(80, 64, pressure: 0.3, timestamp: 40, phase: .began,
                 source: .tablet,
                 capabilities: [.pressure, .altitude, .azimuth], altitude: 0.1,
                 azimuth: 0.25),
        expected(80, 256, pressure: 0.6, timestamp: 40.1, phase: .moved,
                 source: .tablet,
                 capabilities: [.pressure, .altitude, .azimuth], altitude: 0.6,
                 azimuth: 0.5),
        expected(80, 448, pressure: 0.9, timestamp: 40.2, phase: .ended,
                 source: .tablet,
                 capabilities: [.pressure, .altitude, .azimuth], altitude: 1.2,
                 azimuth: 0.75),
    ],
    [
        expected(64, 64, pressure: 0.4, timestamp: 50, phase: .began,
                 source: .pencil, capabilities: [.pressure]),
        expected(256, 64, pressure: 0.6, timestamp: 50.1, phase: .moved,
                 source: .pencil, capabilities: [.pressure]),
        expected(256, 256, pressure: 0.8, timestamp: 50.2, phase: .moved,
                 source: .pencil, kind: .predicted, capabilities: [.pressure]),
        expected(256, 224, pressure: 0.8, timestamp: 50.2, phase: .moved,
                 source: .pencil, capabilities: [.pressure]),
        expected(384, 224, pressure: 1, timestamp: 50.3, phase: .ended,
                 source: .pencil, capabilities: [.pressure]),
    ],
    [
        expected(64, 448, pressure: 0.5, timestamp: 60, phase: .began,
                 source: .pencil, capabilities: [.pressure]),
        expected(256, 448, pressure: 0.5, timestamp: 60.1, phase: .moved,
                 source: .pencil, capabilities: [.pressure]),
        expected(256, 256, pressure: 0.5, timestamp: 60.2, phase: .moved,
                 source: .pencil, capabilities: [.pressure]),
        expected(384, 256, pressure: 0.5, timestamp: 60.3, phase: .ended,
                 source: .pencil, capabilities: [.pressure]),
    ],
    [
        expected(64, 128, pressure: 0.5, timestamp: 70, phase: .began,
                 source: .pencil, capabilities: [.pressure]),
        expected(448, 128, pressure: 0.5, timestamp: 70.1, phase: .moved,
                 source: .pencil, capabilities: [.pressure]),
        expected(448, 160, pressure: 0.5, timestamp: 70.2, phase: .moved,
                 source: .pencil, capabilities: [.pressure]),
        expected(64, 160, pressure: 0.5, timestamp: 70.3, phase: .moved,
                 source: .pencil, capabilities: [.pressure]),
        expected(64, 192, pressure: 0.5, timestamp: 70.4, phase: .moved,
                 source: .pencil, capabilities: [.pressure]),
        expected(448, 192, pressure: 0.5, timestamp: 70.5, phase: .ended,
                 source: .pencil, capabilities: [.pressure]),
    ],
    [
        expected(224, 320, pressure: 0.5, timestamp: 80, phase: .began,
                 source: .pencil, capabilities: [.pressure]),
        expected(256, 320, pressure: 0.5, timestamp: 80.1, phase: .moved,
                 source: .pencil, capabilities: [.pressure]),
        expected(288, 320, pressure: 0.5, timestamp: 80.2, phase: .ended,
                 source: .pencil, capabilities: [.pressure]),
    ],
    [
        expected(256, 256, pressure: 0.3, timestamp: 90, phase: .began,
                 source: .pencil, capabilities: [.pressure]),
        expected(352, 256, pressure: 0.6, timestamp: 90.1, phase: .moved,
                 source: .pencil, capabilities: [.pressure]),
        expected(448, 256, pressure: 0.9, timestamp: 90.2, phase: .ended,
                 source: .pencil, capabilities: [.pressure]),
    ],
]
