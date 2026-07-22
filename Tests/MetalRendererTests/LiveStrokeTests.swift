import CShaderTypes
@testable import MetalRenderer
import PatternEngine
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
        clip3: zeroClip,
        brushAttributes: SIMD4(1, 1, 0, 0)
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

@Test
func replacementEpochDoesNotReuseActiveStrokeIdentity() throws {
    var stroke = LiveStroke(capacity: 4)
    try stroke.append(instance(1))
    stroke.beginReplacementEpoch(1)
    try stroke.append(instance(2))
    let firstReplacementIdentity = stroke.pending.first?.identity
    stroke.beginReplacementEpoch(2)
    try stroke.append(instance(3))

    #expect(firstReplacementIdentity == 1)
    #expect(stroke.pending.map(\.identity) == [2])
    #expect(stroke.pending.map(\.renderEpoch) == [2])
    #expect(stroke.bakedHighWater == 2)
    #expect(stroke.emittedHighWater == 3)
}

@Test
func dirtyRegionsSurviveEncodedPrefixReleaseUntilReset() throws {
    var stroke = LiveStroke(capacity: 4)
    let first = PixelRect(minX: -2, minY: 4, maxX: 8, maxY: 12)!
    let touching = PixelRect(minX: 8, minY: 6, maxX: 14, maxY: 16)!
    let separate = PixelRect(minX: 24, minY: 24, maxX: 28, maxY: 28)!
    let pixelSize = PixelSize(width: 32, height: 32)

    try stroke.append(instance(1), dirtyRect: first)
    try stroke.append(instance(2), dirtyRect: touching)
    try stroke.append(instance(3), dirtyRect: separate)
    stroke.markEncoded(throughExclusive: stroke.emittedHighWater)
    stroke.releaseEncodedPrefix(throughExclusive: stroke.emittedHighWater)

    #expect(stroke.pending.isEmpty)
    #expect(
        stroke.dirtyRegions(clippedTo: pixelSize)
            == PixelRegionSet(
                [
                    PixelRect(minX: 0, minY: 4, maxX: 14, maxY: 16)!,
                    separate,
                ],
                clippedTo: pixelSize
            )
    )

    stroke.reset()

    #expect(stroke.dirtyRegions(clippedTo: pixelSize).rectangles.isEmpty)
}

@Test
func dirtyRegionRetentionStaysBoundedAcrossLongReleasedPrefix() throws {
    var stroke = LiveStroke(capacity: 1)
    let pixelSize = PixelSize(width: 1_024, height: 1_024)
    let retainedLimit = LiveStroke.maximumRetainedDirtyRectangleCount
    let emittedCount = retainedLimit * 8

    for index in 0..<emittedCount {
        let x = (index % 256) * 4
        let y = (index / 256) * 4
        let dirtyRect = PixelRect(
            minX: x,
            minY: y,
            maxX: x + 1,
            maxY: y + 1
        )!

        try stroke.append(instance(Float(index)), dirtyRect: dirtyRect)
        stroke.markEncoded(throughExclusive: stroke.emittedHighWater)
        stroke.releaseEncodedPrefix(
            throughExclusive: stroke.emittedHighWater
        )
    }

    #expect(stroke.pending.isEmpty)
    #expect(stroke.emittedHighWater == UInt64(emittedCount))
    #expect(stroke.retainedDirtyRectangleCount <= retainedLimit)
    #expect(
        stroke.dirtyRegions(clippedTo: pixelSize).rectangles
            == [
                PixelRect(
                    minX: 0,
                    minY: 0,
                    maxX: pixelSize.width,
                    maxY: pixelSize.height
                )!,
            ]
    )

    stroke.reset()

    #expect(stroke.retainedDirtyRectangleCount == 0)
    #expect(stroke.dirtyRegions(clippedTo: pixelSize).rectangles.isEmpty)
}
