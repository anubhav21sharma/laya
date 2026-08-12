import PatternEngine
import Testing

@Test
func strokeTraceCatalogPinsTheSliceThreeInputBaseline() {
    #expect(StrokeTraceFixtures.all.map(\.name) == [
        "click",
        "straight",
        "curved",
        "repeated-timestamp",
        "pressure-ramp",
        "prediction-correction",
        "grid-seam",
        "reflected-cell",
        "long",
    ])

    for fixture in StrokeTraceFixtures.all {
        #expect(fixture.samples.first?.phase == .began, "\(fixture.name)")
        #expect(fixture.samples.last?.phase == .ended, "\(fixture.name)")
        #expect(
            fixture.samples.allSatisfy {
                $0.position.x.isFinite
                    && $0.position.y.isFinite
                    && $0.pressure.isFinite
                    && $0.timestamp.isFinite
            },
            "\(fixture.name)"
        )
    }

    #expect(StrokeTraceFixtures.repeatedTimestamp.samples.map(\.timestamp) == [
        4,
        4,
        4.01,
    ])
    #expect(StrokeTraceFixtures.pressureRamp.samples.map(\.pressure) == [
        0.1,
        0.4,
        0.7,
        1,
    ])
    #expect(
        StrokeTraceFixtures.pressureRamp.samples.allSatisfy {
            $0.source == .pencil
                && $0.capabilities == [.pressure]
        }
    )
    #expect(
        StrokeTraceFixtures.reflectedCell.samples.allSatisfy {
            $0.source == .tablet
                && $0.capabilities == [.pressure]
        }
    )
    #expect(
        StrokeTraceFixtures.click.samples.allSatisfy {
            $0.capabilities.isEmpty
        }
    )
    #expect(StrokeTraceFixtures.long.samples.count == 66)
    #expect(
        StrokeTraceFixtures.long.samples.last?.position
            == ScreenPoint(x: 1_040, y: 32)
    )
}
