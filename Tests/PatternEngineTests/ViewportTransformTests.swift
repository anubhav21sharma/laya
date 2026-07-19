import PatternEngine
import simd
import Testing

private func close(
    _ actual: WorldPoint,
    _ expected: WorldPoint,
    tolerance: Float = 0.0001
) -> Bool {
    abs(actual.x - expected.x) <= tolerance
        && abs(actual.y - expected.y) <= tolerance
}

@Test
func viewportRoundTripsAcrossPanAndZoom() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 800, height: 600),
        worldCenter: WorldPoint(x: 128, y: 128),
        zoom: 2
    )
    let world = WorldPoint(x: -42.5, y: 301.25)

    #expect(close(viewport.screenToWorld(viewport.worldToScreen(world)), world))
}

@Test
func panningMovesWorldCenterOppositeTheScreenDelta() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 800, height: 600),
        worldCenter: WorldPoint(x: 128, y: 128),
        zoom: 2
    )

    let panned = viewport.panned(byScreenDelta: SIMD2<Float>(20, -10))

    #expect(close(panned.worldCenter, WorldPoint(x: 118, y: 133)))
}

@Test
func cursorAnchoredZoomPreservesTheAnchorAndClamps() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 800, height: 600),
        worldCenter: WorldPoint(x: 128, y: 128),
        zoom: 1
    )
    let anchor = ScreenPoint(x: 73, y: 511)
    let before = viewport.screenToWorld(anchor)
    let zoomed = viewport.zoomed(by: 100, anchorScreen: anchor)

    #expect(zoomed.zoom == 8)
    #expect(close(zoomed.screenToWorld(anchor), before))
    #expect(viewport.zoomed(by: 0.0001, anchorScreen: anchor).zoom == 0.25)
}

@Test
func normalizedMouseSampleCarriesRecoveredNeutralPressure() {
    let sample = StrokeSample.mouse(
        position: ScreenPoint(x: 10, y: 20),
        timestamp: 3,
        phase: .began
    )

    #expect(sample.pressure == 0.5)
    #expect(sample.source == .mouse)
}
