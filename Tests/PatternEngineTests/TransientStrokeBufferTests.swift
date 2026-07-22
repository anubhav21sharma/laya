import Foundation
import Testing
@testable import PatternEngine

private let transientViewport = ViewportTransform(
    drawableSize: PatternSize(width: 2, height: 2),
    worldCenter: WorldPoint(x: 0, y: 0)
)

private func transientSample(
    _ index: Int,
    kind: StrokeSampleKind = .actual
) -> WorldStrokeSample {
    let sample = StrokeSample(
        position: ScreenPoint(x: Float(index) + 1, y: 1),
        pressure: 0.5,
        timestamp: TimeInterval(index),
        phase: index == 0 ? .began : .moved,
        source: .mouse,
        kind: kind
    )
    var input = BrushInputDeriver()
    return input.derive(sample, viewport: transientViewport)
}

private func transientDab(
    _ ordinal: Int,
    predicted: Bool = false,
    projectedInstances: Int = 1
) -> TransientStrokeDab {
    let position = WorldPoint(x: Float(ordinal), y: 0)
    return TransientStrokeDab(
        attributes: DabAttributes(
            position: position,
            brushToWorld: Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                translation: position.simd
            ),
            radius: 1,
            diameter: 2,
            spacing: 1,
            flow: 1,
            strokeOpacity: 1,
            rotation: 0,
            scatter: .zero,
            hardness: 1,
            grainOffset: .zero,
            grainScale: 1,
            grainRotation: 0,
            color: .black,
            colorAdjustment: .identity,
            materialFamily: .ink,
            materialContribution: 1,
            sourceDistance: Float(ordinal),
            ordinal: UInt64(ordinal),
            isPredicted: predicted
        ),
        projectedInstanceCount: projectedInstances
    )
}

private func transientChunk(
    _ index: Int,
    dabCount: Int = 1,
    projectedInstancesPerDab: Int = 1,
    kind: StrokeSampleKind = .actual,
    snapshot: BrushStrokeGenerator? = nil
) -> TransientStrokeChunk {
    TransientStrokeChunk(
        sample: transientSample(index, kind: kind),
        dabs: (0..<dabCount).map {
            transientDab(
                index * 10_000 + $0,
                predicted: kind == .predicted,
                projectedInstances: projectedInstancesPerDab
            )
        },
        generatorSnapshotAfterSample: snapshot
    )
}

private func transientGenerator(seed: UInt64) -> BrushStrokeGenerator {
    BrushStrokeGenerator(
        recipe: .legacyEquivalent,
        nominalDiameter: 20,
        color: .black,
        seed: seed
    )
}

private func declaredReplayRecipe(
    id: String,
    mode: BrushReplayMode = .replayTail,
    maximumSamples: Int,
    maximumDabs: Int,
    maximumProjectedInstances: Int
) throws -> BrushRecipe {
    try BrushRecipe(
        id: BrushRecipeID(id),
        replayMode: mode,
        replayLimits: BrushReplayLimits(
            maximumSamples: maximumSamples,
            maximumDabs: maximumDabs,
            maximumProjectedInstances: maximumProjectedInstances
        )
    )
}

private func transientBuffer(
    mode: BrushReplayMode
) -> TransientStrokeBuffer {
    let limits: BrushReplayLimits?
    switch mode {
    case .appendOnly:
        limits = nil
    case .replayTail:
        limits = BrushRecipePolicy.replayTailLimits
    case .boundedWholeStroke:
        limits = BrushRecipePolicy.wholeStrokeLimits
    }
    let recipe = try! BrushRecipe(
        id: BrushRecipeID("test.buffer.\(mode)"),
        replayMode: mode,
        replayLimits: limits
    )
    return TransientStrokeBuffer(replayContract: recipe.replayContract)
}

@Test
func replayTailEnforcesTheRecipeDeclaredSampleLimit() throws {
    let recipe = try declaredReplayRecipe(
        id: "test.buffer.declared-samples",
        maximumSamples: 2,
        maximumDabs: 100,
        maximumProjectedInstances: 100
    )
    var buffer = TransientStrokeBuffer(
        replayContract: recipe.replayContract
    )

    _ = buffer.appendActual(transientChunk(0, dabCount: 0))
    _ = buffer.appendActual(transientChunk(1, dabCount: 0))
    let update = buffer.appendActual(transientChunk(2, dabCount: 0))

    #expect(buffer.replayContract == recipe.replayContract)
    #expect(buffer.actualSampleCount == 2)
    #expect(update.settledPrefix.map(\.sample.position.x) == [0])
}

@Test
func replayTailEnforcesTheRecipeDeclaredDabLimit() throws {
    let recipe = try declaredReplayRecipe(
        id: "test.buffer.declared-dabs",
        maximumSamples: 100,
        maximumDabs: 3,
        maximumProjectedInstances: 100
    )
    var buffer = TransientStrokeBuffer(
        replayContract: recipe.replayContract
    )

    _ = buffer.appendActual(transientChunk(0, dabCount: 2))
    let update = buffer.appendActual(transientChunk(1, dabCount: 2))

    #expect(buffer.actualDabCount == 2)
    #expect(update.settledPrefix.map(\.sample.position.x) == [0])
}

@Test
func replayTailEnforcesTheRecipeDeclaredProjectedInstanceLimit() throws {
    let recipe = try declaredReplayRecipe(
        id: "test.buffer.declared-projected",
        maximumSamples: 100,
        maximumDabs: 100,
        maximumProjectedInstances: 5
    )
    var buffer = TransientStrokeBuffer(
        replayContract: recipe.replayContract
    )

    _ = buffer.appendActual(
        transientChunk(0, projectedInstancesPerDab: 2)
    )
    _ = buffer.appendActual(
        transientChunk(1, projectedInstancesPerDab: 2)
    )
    let update = buffer.appendActual(
        transientChunk(2, projectedInstancesPerDab: 2)
    )

    #expect(buffer.visibleProjectedInstanceCount == 4)
    #expect(update.settledPrefix.map(\.sample.position.x) == [0])
    #expect(update.replayWindowShortened)
}

@Test
func appendOnlySettlesActualChunksAndRetainsOnlyPrediction() throws {
    var buffer = transientBuffer(mode: .appendOnly)
    let first = transientChunk(0)

    let append = buffer.appendActual(first)

    #expect(append.settledPrefix == [first])
    #expect(!append.requiresReplayReplacement)
    #expect(buffer.actualSampleCount == 0)
    #expect(buffer.actualDabCount == 0)

    let predicted = transientChunk(1, kind: .predicted)
    let prediction = try buffer.replacePredicted(with: [predicted])
    #expect(prediction.requiresReplayReplacement)
    #expect(buffer.predictedSamples == [predicted.sample])

    let second = transientChunk(2)
    let nextActual = buffer.appendActual(second)
    #expect(nextActual.settledPrefix == [second])
    #expect(nextActual.clearedPredictedSuffix)
    #expect(nextActual.requiresReplayReplacement)
    #expect(buffer.predictedSampleCount == 0)
}

@Test
func replayTailEnforcesTheSampleAndDabCapsByOldestWholeChunk() {
    var sampleBound = transientBuffer(mode: .replayTail)
    var lastSampleUpdate = TransientStrokeBufferUpdate.noChange
    for index in 0...TransientStrokeBufferContract.replayTailSampleCapacity {
        lastSampleUpdate = sampleBound.appendActual(
            transientChunk(index, dabCount: 0)
        )
    }

    #expect(
        sampleBound.actualSampleCount
            == TransientStrokeBufferContract.replayTailSampleCapacity
    )
    #expect(lastSampleUpdate.settledPrefix.map(\.sample.position.x) == [0])
    #expect(sampleBound.actualSamples.first?.position.x == 1)

    var dabBound = transientBuffer(mode: .replayTail)
    var promotedDabs = 0
    for index in 0..<200 {
        let update = dabBound.appendActual(
            transientChunk(index, dabCount: 11)
        )
        promotedDabs += update.settledDabCount
    }

    #expect(dabBound.actualSampleCount == 186)
    #expect(dabBound.actualDabCount == 2_046)
    #expect(promotedDabs == 154)
    #expect(dabBound.actualSamples.first?.position.x == 14)
}

@Test
func wholeStrokeDegradesAtItsCapsAndPromotesDeterministicPrefix() {
    var first = transientBuffer(mode: .boundedWholeStroke)
    var second = transientBuffer(mode: .boundedWholeStroke)
    var firstLast = TransientStrokeBufferUpdate.noChange
    var secondLast = TransientStrokeBufferUpdate.noChange

    for index in 0...TransientStrokeBufferContract.wholeStrokeSampleCapacity {
        let chunk = transientChunk(index, projectedInstancesPerDab: 0)
        firstLast = first.appendActual(chunk)
        secondLast = second.appendActual(chunk)
    }

    #expect(first == second)
    #expect(firstLast == secondLast)
    #expect(first.mode == .replayTail)
    #expect(first.degradationReason == .wholeStrokeCapacity)
    #expect(first.degradationCount == 1)
    #expect(first.actualSampleCount == 256)
    #expect(first.actualDabCount == 256)
    #expect(first.actualSamples.first?.position.x == 3_841)
    #expect(firstLast.settledPrefix.count == 3_841)
    #expect(first.settledPrefixPromotionCount == 1)
}

@Test
func wholeStrokeAcceptsExactly4096DabsThenDegradesOnTheNext() {
    var buffer = transientBuffer(mode: .boundedWholeStroke)
    _ = buffer.appendActual(
        transientChunk(
            0,
            dabCount: TransientStrokeBufferContract.wholeStrokeDabCapacity,
            projectedInstancesPerDab: 0
        )
    )

    #expect(buffer.mode == .boundedWholeStroke)
    #expect(buffer.actualDabCount == 4_096)

    let update = buffer.appendActual(
        transientChunk(1, projectedInstancesPerDab: 0)
    )

    #expect(buffer.mode == .replayTail)
    #expect(buffer.degradationReason == .wholeStrokeCapacity)
    #expect(update.settledPrefix.map(\.sample.position.x) == [0])
    #expect(buffer.actualDabCount == 1)
}

@Test
func visibleEpochProjectedInstanceCapDegradesAndShortensReplay() {
    var buffer = transientBuffer(mode: .boundedWholeStroke)
    _ = buffer.appendActual(
        transientChunk(0, projectedInstancesPerDab: 2_048)
    )
    _ = buffer.appendActual(
        transientChunk(1, projectedInstancesPerDab: 2_048)
    )
    #expect(buffer.mode == .boundedWholeStroke)
    #expect(buffer.visibleProjectedInstanceCount == 4_096)

    let update = buffer.appendActual(
        transientChunk(2, projectedInstancesPerDab: 1)
    )

    #expect(buffer.mode == .replayTail)
    #expect(buffer.degradationReason == .projectedInstanceCapacity)
    #expect(update.settledPrefix.map(\.sample.position.x) == [0])
    #expect(buffer.visibleProjectedInstanceCount == 2_049)
    #expect(buffer.visibleProjectedInstanceCount <= 4_096)
    #expect(buffer.replayWindowShorteningCount == 1)
    #expect(update.replayWindowShortened)
}

@Test
func replayWindowCanBeShortenedExplicitlyWithoutPartialChunks() {
    var buffer = transientBuffer(mode: .replayTail)
    for index in 0..<3 {
        _ = buffer.appendActual(
            transientChunk(index, projectedInstancesPerDab: 4)
        )
    }

    let update = buffer.shortenReplayWindow(
        maximumProjectedInstanceCount: 8
    )

    #expect(update.settledPrefix.map(\.sample.position.x) == [0])
    #expect(update.requiresReplayReplacement)
    #expect(update.replayWindowShortened)
    #expect(buffer.actualSamples.map(\.position.x) == [1, 2])
    #expect(buffer.visibleProjectedInstanceCount == 8)
    #expect(buffer.replayWindowShorteningCount == 1)

    let noChange = buffer.shortenReplayWindow(
        maximumProjectedInstanceCount: 8
    )
    #expect(noChange.settledPrefix.isEmpty)
    #expect(!noChange.requiresReplayReplacement)
    #expect(noChange.replayEpoch == buffer.replayEpoch)
}

@Test
func predictionCanShortenAFullActualTailWithoutAdvancingItsSnapshot() throws {
    let authoritative = transientGenerator(seed: 21)
    var buffer = transientBuffer(mode: .replayTail)
    for index in 0..<TransientStrokeBufferContract.replayTailSampleCapacity {
        _ = buffer.appendActual(
            transientChunk(index, snapshot: authoritative)
        )
    }

    let update = try buffer.replacePredicted(with: [
        transientChunk(300, kind: .predicted),
    ])

    #expect(update.settledPrefix.map(\.sample.position.x) == [0])
    #expect(update.replayWindowShortened)
    #expect(buffer.actualSamples.first?.position.x == 1)
    #expect(buffer.predictedSamples.map(\.position.x) == [300])
    #expect(buffer.authoritativeGeneratorSnapshot == authoritative)
    #expect(buffer.retainedSampleCount == 256)
}

@Test
func predictedEndpointReplacementDoesNotAdvanceAuthoritativeState() throws {
    let actualSnapshot = transientGenerator(seed: 11)
    let firstPredictedSnapshot = transientGenerator(seed: 12)
    let secondPredictedSnapshot = transientGenerator(seed: 13)
    var buffer = transientBuffer(mode: .replayTail)
    _ = buffer.appendActual(
        transientChunk(0, snapshot: actualSnapshot)
    )

    _ = try buffer.replacePredicted(with: [
        transientChunk(
            10,
            kind: .predicted,
            snapshot: firstPredictedSnapshot
        ),
    ])
    let actualBeforeReplacement = buffer.actualChunks
    let authoritativeBeforeReplacement = buffer.authoritativeGeneratorSnapshot
    let firstEpoch = buffer.replayEpoch

    let replacement = try buffer.replacePredicted(with: [
        transientChunk(
            20,
            kind: .predicted,
            snapshot: secondPredictedSnapshot
        ),
    ])

    #expect(buffer.actualChunks == actualBeforeReplacement)
    #expect(
        buffer.authoritativeGeneratorSnapshot
            == authoritativeBeforeReplacement
    )
    #expect(buffer.predictedSamples.map(\.position.x) == [20])
    #expect(buffer.predictedGeneratorSnapshot == secondPredictedSnapshot)
    #expect(buffer.replayEpoch == firstEpoch + 1)
    #expect(replacement.clearedPredictedSuffix)
}

@Test
func oversizedPredictedReplacementIsTransactional() throws {
    var buffer = transientBuffer(mode: .replayTail)
    _ = buffer.appendActual(transientChunk(0))
    _ = try buffer.replacePredicted(with: [
        transientChunk(1, kind: .predicted),
    ])
    let before = buffer

    #expect(throws: TransientStrokeBufferError.self) {
        try buffer.replacePredicted(with: [
            transientChunk(
                2,
                dabCount:
                    TransientStrokeBufferContract.replayTailDabCapacity + 1,
                projectedInstancesPerDab: 0,
                kind: .predicted
            ),
        ])
    }
    #expect(buffer == before)
}

@Test
func cancelRestoresRequestedModeAndClearsAllRuntimeState() {
    var buffer = transientBuffer(mode: .boundedWholeStroke)
    for index in 0...TransientStrokeBufferContract.wholeStrokeSampleCapacity {
        _ = buffer.appendActual(
            transientChunk(index, projectedInstancesPerDab: 0)
        )
    }
    #expect(buffer.mode == .replayTail)

    buffer.cancel()

    #expect(buffer.mode == .boundedWholeStroke)
    #expect(buffer.actualChunks.isEmpty)
    #expect(buffer.predictedChunks.isEmpty)
    #expect(buffer.replayEpoch == 0)
    #expect(buffer.degradationReason == nil)
    #expect(buffer.degradationCount == 0)
    #expect(buffer.settledPrefixPromotionCount == 0)
    #expect(buffer.replayWindowShorteningCount == 0)
    #expect(buffer.authoritativeGeneratorSnapshot == nil)
    #expect(buffer.predictedGeneratorSnapshot == nil)

    requireSendable(buffer)
}

private func requireSendable<T: Sendable>(_: T) {}
