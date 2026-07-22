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

@Test
func legacyInterpolatorEmitsExactFixturePlacements() {
    #expect(emittedPoints(for: StrokeTraceFixtures.click) == [
        WorldPoint(x: 40, y: 40),
    ])
    #expect(emittedPoints(for: StrokeTraceFixtures.straight) == [
        WorldPoint(x: 0, y: 0),
        WorldPoint(x: 2.5, y: 0),
        WorldPoint(x: 5, y: 0),
        WorldPoint(x: 6, y: 0),
    ])
    #expect(emittedPoints(for: StrokeTraceFixtures.gridSeam) == [
        WorldPoint(x: 250, y: 128),
        WorldPoint(x: 252.5, y: 128),
        WorldPoint(x: 255, y: 128),
        WorldPoint(x: 257.5, y: 128),
        WorldPoint(x: 260, y: 128),
        WorldPoint(x: 262, y: 128),
    ])
}

private func emittedPoints(
    for fixture: StrokeTraceFixture
) -> [WorldPoint] {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    for sample in fixture.samples {
        let point = WorldPoint(sample.position.simd)
        switch sample.phase {
        case .began:
            interpolator.begin(at: point) { emitted.append($0) }
        case .moved:
            interpolator.append(point) { emitted.append($0) }
        case .ended:
            interpolator.finish(at: point) { emitted.append($0) }
        case .cancelled:
            interpolator.cancel()
        }
    }
    return emitted
}
