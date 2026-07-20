import CShaderTypes
import MetalRenderer
import Testing

private func instance(_ x: Float) -> PatternProjectedStampInstance {
    let zeroClip = PatternClipHalfPlane(
        normal: .zero,
        offset: 0,
        padding: 0
    )
    return PatternProjectedStampInstance(
        canonicalXAxis: SIMD2<Float>(10, 0),
        canonicalYAxis: SIMD2<Float>(0, 10),
        canonicalTranslation: SIMD2<Float>(x, 0),
        radius: 10,
        clipCount: 0,
        color: SIMD4<Float>(0, 0, 0, 1),
        clip0: zeroClip,
        clip1: zeroClip,
        clip2: zeroClip,
        clip3: zeroClip
    )
}

@Test
func liveStrokeUsesMonotonicIdentityEvenForCoincidentDabs() throws {
    var stroke = LiveStroke(capacity: 8)
    try stroke.append(instance(4))
    try stroke.append(instance(4))

    #expect(stroke.pending.map(\.identity) == [0, 1])
    #expect(stroke.bakedHighWater == 0)
}

@Test
func bakedHighWaterAdvancesAndSafePrefixCompactsWithoutIdentityReset() throws {
    var stroke = LiveStroke(capacity: 8)
    try stroke.append(instance(1))
    try stroke.append(instance(2))
    try stroke.append(instance(3))
    stroke.markEncoded(throughExclusive: 2)
    stroke.releaseEncodedPrefix(throughExclusive: 2)
    try stroke.append(instance(4))

    #expect(stroke.bakedHighWater == 2)
    #expect(stroke.pending.map(\.identity) == [2, 3])
}

@Test
func liveStrokeRejectsGrowthBeyondItsPreallocatedCapacity() throws {
    var stroke = LiveStroke(capacity: 2)
    try stroke.append(instance(1))
    try stroke.append(instance(2))

    #expect(throws: MetalRendererError.projectedInstanceCapacityExceeded(2)) {
        try stroke.append(instance(3))
    }
    #expect(stroke.pending.map(\.identity) == [0, 1])
    #expect(stroke.bakedHighWater == 0)
    #expect(stroke.emittedHighWater == 2)
}

@Test
func resetKeepsCapacityButRestoresPerStrokeIdentity() throws {
    var stroke = LiveStroke(capacity: 4)
    try stroke.append(instance(1))
    stroke.reset()
    try stroke.append(instance(2))

    #expect(stroke.pending.map(\.identity) == [0])
    #expect(stroke.bakedHighWater == 0)
    #expect(stroke.emittedHighWater == 1)
    #expect(stroke.capacity == 4)
}
