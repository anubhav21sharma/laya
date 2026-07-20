import PatternEngine
import simd
import Testing

@Test
func mixedAxisReflectionRoundTrips() {
    let affine = Affine2D(
        xAxis: SIMD2(-1, 0),
        yAxis: SIMD2(0, 1),
        translation: SIMD2(256, 17)
    )
    let point = SIMD2<Float>(33, -4)
    let roundTrip = affine.inverted().applying(
        to: affine.applying(to: point)
    )
    #expect(simd_distance(roundTrip, point) < 0.0001)
}

@Test
func concatenationAppliesBrushThenCellTransform() {
    let brushToWorld = Affine2D(
        xAxis: SIMD2(0, 2),
        yAxis: SIMD2(-2, 0),
        translation: SIMD2(300, 144)
    )
    let worldToCanonical = Affine2D(
        xAxis: SIMD2(1, 0),
        yAxis: SIMD2(0, 1),
        translation: SIMD2(-288, -144)
    )
    let combined = brushToWorld.concatenating(worldToCanonical)
    #expect(
        simd_distance(
            combined.applying(to: SIMD2<Float>(1, 0)),
            SIMD2<Float>(12, 2)
        ) < 0.0001
    )
}

@Test
func identityPreservesPoints() {
    let point = SIMD2<Float>(-17.5, 42.25)

    #expect(Affine2D.identity.applying(to: point) == point)
}
