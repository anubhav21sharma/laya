import CShaderTypes
import MetalRenderer
import Testing

private func instance(_ x: Float) -> PatternDabInstance {
    PatternDabInstance(
        center: SIMD2<Float>(x, 0),
        radius: 10,
        padding: 0
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

    #expect(throws: MetalRendererError.pendingDabCapacityExceeded(2)) {
        try stroke.append(instance(3))
    }
}
