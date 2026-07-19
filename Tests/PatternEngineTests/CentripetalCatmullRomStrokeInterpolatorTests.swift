import PatternEngine
import simd
import Testing

private func distance(_ lhs: WorldPoint, _ rhs: WorldPoint) -> Float {
    simd_distance(lhs.simd, rhs.simd)
}

@Test
func clickEmitsExactlyOneDab() throws {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    try interpolator.begin(at: WorldPoint(x: 4, y: 9)) { emitted.append($0) }
    try interpolator.finish(at: WorldPoint(x: 4, y: 9)) { emitted.append($0) }

    #expect(emitted == [WorldPoint(x: 4, y: 9)])
}

@Test
func straightMotionUsesRecoveredSpacingAndExactFinalEndpoint() throws {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    try interpolator.begin(at: WorldPoint(x: 0, y: 0)) { emitted.append($0) }
    try interpolator.append(WorldPoint(x: 5, y: 0)) { emitted.append($0) }
    try interpolator.finish(at: WorldPoint(x: 6, y: 0)) { emitted.append($0) }

    #expect(emitted == [
        WorldPoint(x: 0, y: 0),
        WorldPoint(x: 2.5, y: 0),
        WorldPoint(x: 5, y: 0),
        WorldPoint(x: 6, y: 0),
    ])
}

@Test
func spacingCarryCrossesInputSegments() throws {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    try interpolator.begin(at: WorldPoint(x: 0, y: 0)) { emitted.append($0) }
    try interpolator.append(WorldPoint(x: 1, y: 0)) { emitted.append($0) }
    try interpolator.append(WorldPoint(x: 3, y: 0)) { emitted.append($0) }

    #expect(emitted.count == 2)
    #expect(abs(emitted[1].x - 2.5) < 0.01)
}

@Test
func curvedMotionStaysAtFixedArcLengthWithinTolerance() throws {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    try interpolator.begin(at: WorldPoint(x: 0, y: 0)) { emitted.append($0) }
    try interpolator.append(WorldPoint(x: 7.5, y: 0)) { emitted.append($0) }
    try interpolator.append(WorldPoint(x: 7.5, y: 7.5)) { emitted.append($0) }

    for pair in zip(emitted, emitted.dropFirst()) {
        #expect(abs(distance(pair.0, pair.1) - 2.5) < 0.08)
    }
    #expect(emitted.contains { $0.x > 7.51 && $0.y > 0 })
}

@Test
func cancelResetsIdentityAndCarry() throws {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    try interpolator.begin(at: WorldPoint(x: -8, y: 0)) { emitted.append($0) }
    try interpolator.append(WorldPoint(x: -6, y: 0)) { emitted.append($0) }
    interpolator.cancel()
    try interpolator.begin(at: WorldPoint(x: 40, y: 20)) { emitted.append($0) }

    #expect(emitted.last == WorldPoint(x: 40, y: 20))
}

@Test
func negativeWorldMotionDoesNotChangeSpacing() throws {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    try interpolator.begin(at: WorldPoint(x: -8, y: -4)) { emitted.append($0) }
    try interpolator.finish(at: WorldPoint(x: -3, y: -4)) { emitted.append($0) }

    #expect(emitted == [
        WorldPoint(x: -8, y: -4),
        WorldPoint(x: -5.5, y: -4),
        WorldPoint(x: -3, y: -4),
    ])
}
