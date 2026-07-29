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

    #expect(StrokeTraceFixtures.professionalTap.samples.map(\.phase) == [
        .began, .ended,
    ])
    #expect(StrokeTraceFixtures.professionalSlowLine.samples.map(\.position) == [
        ScreenPoint(x: 64, y: 128),
        ScreenPoint(x: 256, y: 128),
        ScreenPoint(x: 448, y: 128),
    ])
    #expect(StrokeTraceFixtures.professionalFastLine.samples.map(\.position)
        == StrokeTraceFixtures.professionalSlowLine.samples.map(\.position))
    #expect(StrokeTraceFixtures.professionalSlowLine.samples.last!.timestamp
        - StrokeTraceFixtures.professionalSlowLine.samples.first!.timestamp == 2)
    #expect(abs(
        StrokeTraceFixtures.professionalFastLine.samples.last!.timestamp
            - StrokeTraceFixtures.professionalFastLine.samples.first!.timestamp
            - 0.04
    ) < 0.000_001)
    #expect(StrokeTraceFixtures.professionalPressureRamp.samples.map(\.pressure) == [
        0.1, 0.4, 0.7, 1,
    ])
    #expect(StrokeTraceFixtures.professionalPressureRamp.samples[1].kind == .coalesced)
    #expect(StrokeTraceFixtures.professionalPressureRamp.samples.allSatisfy {
        $0.source == .pencil && $0.capabilities == [.pressure]
    })
    #expect(StrokeTraceFixtures.professionalTiltSweep.samples.map(\.altitude) == [
        0.1, 0.6, 1.2,
    ])
    #expect(StrokeTraceFixtures.professionalTiltSweep.samples.map(\.azimuth) == [
        0.25, 0.5, 0.75,
    ])
    #expect(StrokeTraceFixtures.professionalTiltSweep.samples.allSatisfy {
        $0.capabilities.isSuperset(of: [.pressure, .altitude, .azimuth])
    })
    #expect(StrokeTraceFixtures.professionalDirectionTurn.samples.contains {
        $0.kind == .predicted
    })
    #expect(StrokeTraceFixtures.professionalDirectionTurn.samples.contains {
        $0.kind == .actual && $0.timestamp == 50.2 && $0.position == ScreenPoint(x: 256, y: 224)
    })
    #expect(StrokeTraceFixtures.professionalGridSeam.samples.contains {
        $0.position.x < 256
    })
    #expect(StrokeTraceFixtures.professionalGridSeam.samples.contains {
        $0.position.x > 256
    })
    #expect(StrokeTraceFixtures.professionalRadialSpoke.samples.first?.position
        == ScreenPoint(x: 256, y: 256))
    #expect(StrokeTraceFixtures.professionalRadialSpoke.samples.last?.position
        == ScreenPoint(x: 448, y: 256))
    #expect(StrokeTraceFixtures.professionalCorner.samples.map(\.position) == [
        ScreenPoint(x: 64, y: 448),
        ScreenPoint(x: 256, y: 448),
        ScreenPoint(x: 256, y: 256),
        ScreenPoint(x: 384, y: 256),
    ])
    #expect(StrokeTraceFixtures.professionalHatching.samples.map(\.position) == [
        ScreenPoint(x: 64, y: 128),
        ScreenPoint(x: 448, y: 128),
        ScreenPoint(x: 448, y: 160),
        ScreenPoint(x: 64, y: 160),
        ScreenPoint(x: 64, y: 192),
        ScreenPoint(x: 448, y: 192),
    ])
    #expect(StrokeTraceFixtures.professionalTap.samples.allSatisfy {
        $0.source == .mouse && $0.capabilities.isEmpty
    })
}
