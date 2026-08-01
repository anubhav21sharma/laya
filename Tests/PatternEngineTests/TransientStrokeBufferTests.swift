import Foundation
import Testing
@testable import PatternEngine

private let transientViewport = ViewportTransform(
    drawableSize: PatternSize(width: 2, height: 2),
    worldCenter: WorldPoint(x: 0, y: 0)
)

private func transientSample(
    _ index: Int,
    kind: StrokeSampleKind = .actual,
    estimationUpdateIndex: Int? = nil,
    estimatedProperties: StrokeEstimatedProperties = [],
    expecting: StrokeEstimatedProperties = [],
    pressure: Float = 0.5,
    capabilities: StrokeInputCapabilities = [.pressure],
    altitude: Float? = nil,
    azimuth: Float? = nil,
    roll: Float? = nil,
    phase: StrokePhase? = nil
) -> WorldStrokeSample {
    let sample = StrokeSample(
        position: ScreenPoint(x: Float(index) + 1, y: 1),
        pressure: pressure,
        timestamp: TimeInterval(index),
        phase: phase ?? (index == 0 ? .began : .moved),
        source: .mouse,
        kind: kind,
        capabilities: capabilities,
        altitude: altitude,
        azimuth: azimuth,
        roll: roll,
        estimationUpdateIndex: estimationUpdateIndex,
        estimatedProperties: estimatedProperties,
        estimatedPropertiesExpectingUpdates: expecting
    )
    var input = BrushInputDeriver()
    return input.derive(sample, viewport: transientViewport)
}

private func estimatedTransientChunk(
    _ index: Int,
    kind: StrokeSampleKind = .actual,
    estimationUpdateIndex: Int,
    estimatedProperties: StrokeEstimatedProperties,
    expecting: StrokeEstimatedProperties,
    pressure: Float,
    snapshot: BrushStrokeGenerator? = nil,
    generatorBefore: BrushStrokeGenerator? = nil,
    inputBefore: BrushInputDeriver? = nil
) -> TransientStrokeChunk {
    TransientStrokeChunk(
        sample: transientSample(
            index,
            kind: kind,
            estimationUpdateIndex: estimationUpdateIndex,
            estimatedProperties: estimatedProperties,
            expecting: expecting,
            pressure: pressure
        ),
        dabs: [],
        generatorSnapshotBeforeSample: generatorBefore,
        generatorSnapshotAfterSample: snapshot,
        inputDeriverSnapshotBeforeSample: inputBefore
    )
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
        program: nativeTestProgram(),
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
func appendOnlyLongStrokeReturnsConstantNewWorkAndRetainsNoCompletedBody() {
    var buffer = transientBuffer(mode: .appendOnly)
    var maximumReturnedChunkCount = 0
    var returnedDabCount = 0

    for index in 0..<100_000 {
        let update = buffer.appendActual(
            transientChunk(index, dabCount: 1)
        )
        maximumReturnedChunkCount = max(
            maximumReturnedChunkCount,
            update.settledPrefix.count
        )
        returnedDabCount += update.settledDabCount
        #expect(update.rejection == nil)
        #expect(!update.requiresReplayReplacement)
    }

    #expect(maximumReturnedChunkCount == 1)
    #expect(returnedDabCount == 100_000)
    #expect(buffer.actualChunks.isEmpty)
    #expect(buffer.actualDabCount == 0)
    #expect(buffer.replayEpoch == 0)
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
func estimatedUpdatePlansAuthoritativeSuffixAndPreservesIdentity() throws {
    let before = transientGenerator(seed: 17)
    var buffer = transientBuffer(mode: .replayTail)
    _ = buffer.appendActual(transientChunk(0, snapshot: before))
    _ = buffer.appendActual(
        estimatedTransientChunk(
            1,
            estimationUpdateIndex: 7,
            estimatedProperties: [.pressure],
            expecting: [.pressure],
            pressure: 0.2,
            snapshot: transientGenerator(seed: 18)
        )
    )
    _ = buffer.appendActual(transientChunk(2))
    let update = transientSample(
        99,
        kind: .estimatedUpdate,
        estimationUpdateIndex: 7,
        estimatedProperties: [],
        expecting: [],
        pressure: 0.9
    )

    let plan = try buffer.planEstimatedUpdate(update)

    #expect(plan.target == .authoritative)
    #expect(plan.replacedChunkIndex == 1)
    #expect(plan.generatorBeforeReplacement == before)
    #expect(plan.mergedSample.pressure == 0.9)
    #expect(plan.mergedSample.position == buffer.actualSamples[1].position)
    #expect(plan.mergedSample.timestamp == buffer.actualSamples[1].timestamp)
    #expect(plan.mergedSample.kind == .actual)
    #expect(plan.mergedSample.estimationUpdateIndex == 7)
    #expect(plan.mergedSample.estimatedProperties.isEmpty)
    #expect(plan.samplesToReplay == [buffer.actualSamples[2]])
}

@Test
func borrowedEstimatedReplacementUsesCallerOwnedReplayAndSettlementStorage()
    throws
{
    var buffer = transientBuffer(mode: .replayTail)
    _ = buffer.appendActual(
        estimatedTransientChunk(
            0,
            estimationUpdateIndex: 71,
            estimatedProperties: [.pressure],
            expecting: [.pressure],
            pressure: 0.2
        )
    )
    _ = buffer.appendActual(transientChunk(1))
    var replaySamples: [WorldStrokeSample] = []
    replaySamples.reserveCapacity(
        TransientStrokeBufferContract.wholeStrokeSampleCapacity
    )
    let replayCapacity = replaySamples.capacity
    let plan = try buffer.planEstimatedUpdate(
        transientSample(
            9,
            kind: .estimatedUpdate,
            estimationUpdateIndex: 71,
            pressure: 0.85
        ),
        replacementSamplesInto: &replaySamples
    )
    var rebuilt: [TransientStrokeChunk] = []
    rebuilt.reserveCapacity(
        TransientStrokeBufferContract.wholeStrokeSampleCapacity
    )
    for sample in replaySamples {
        rebuilt.append(TransientStrokeChunk(sample: sample, dabs: []))
    }
    var settled: [TransientStrokeChunk] = []
    settled.reserveCapacity(
        TransientStrokeBufferContract.wholeStrokeSampleCapacity
    )
    let settlementCapacity = settled.capacity

    let mutation = try buffer.replaceEstimatedSuffix(
        using: plan,
        expectedSamples: replaySamples,
        with: rebuilt,
        settledInto: &settled
    )

    #expect(replaySamples.capacity == replayCapacity)
    #expect(settled.capacity == settlementCapacity)
    #expect(settled.isEmpty)
    #expect(mutation.requiresReplayReplacement)
    #expect(buffer.actualSamples == replaySamples)
    #expect(buffer.actualSamples.first?.pressure == 0.85)
}

@Test
func estimatedSuffixReplacementIsTransactionalAndInvalidatesOldPlans() throws {
    var buffer = transientBuffer(mode: .replayTail)
    _ = buffer.appendActual(
        estimatedTransientChunk(
            0,
            estimationUpdateIndex: 5,
            estimatedProperties: [.pressure],
            expecting: [.pressure],
            pressure: 0.2
        )
    )
    let update = transientSample(
        10,
        kind: .estimatedUpdate,
        estimationUpdateIndex: 5,
        pressure: 0.8
    )
    let plan = try buffer.planEstimatedUpdate(update)
    let replacement = TransientStrokeChunk(
        sample: plan.mergedSample,
        dabs: [],
        generatorSnapshotAfterSample: transientGenerator(seed: 30)
    )
    let oldEpoch = buffer.replayEpoch

    let result = try buffer.replaceEstimatedSuffix(
        using: plan,
        with: [replacement]
    )

    #expect(buffer.actualSamples == [plan.mergedSample])
    #expect(buffer.replayEpoch == oldEpoch + 1)
    #expect(result.replayEpoch == oldEpoch + 1)
    let afterReplacement = buffer
    #expect(throws: TransientStrokeBufferError.self) {
        try buffer.replaceEstimatedSuffix(using: plan, with: [replacement])
    }
    #expect(buffer == afterReplacement)
}

@Test
func ordinaryAppendMakesEstimatedUpdatePlanStale() throws {
    var buffer = transientBuffer(mode: .replayTail)
    _ = buffer.appendActual(
        estimatedTransientChunk(
            0,
            estimationUpdateIndex: 5,
            estimatedProperties: [.pressure],
            expecting: [.pressure],
            pressure: 0.2
        )
    )
    let update = transientSample(
        10,
        kind: .estimatedUpdate,
        estimationUpdateIndex: 5,
        pressure: 0.8
    )
    let plan = try buffer.planEstimatedUpdate(update)
    _ = buffer.appendActual(transientChunk(1))
    let before = buffer

    #expect(throws: TransientStrokeBufferError.self) {
        try buffer.replaceEstimatedSuffix(
            using: plan,
            with: [
                TransientStrokeChunk(sample: plan.mergedSample, dabs: []),
                transientChunk(1),
            ]
        )
    }
    #expect(buffer == before)
}

@Test
func estimatedUpdateSupportsMultiplePartialPropertyResolutions() throws {
    var buffer = transientBuffer(mode: .replayTail)
    _ = buffer.appendActual(
        TransientStrokeChunk(
            sample: transientSample(
                1,
                estimationUpdateIndex: 12,
                estimatedProperties: [.pressure, .roll],
                expecting: [.pressure, .roll],
                pressure: 0.2,
                capabilities: [.pressure, .roll],
                roll: 0.1
            ),
            dabs: []
        )
    )

    let pressureResolution = transientSample(
        10,
        kind: .estimatedUpdate,
        estimationUpdateIndex: 12,
        estimatedProperties: [.roll],
        expecting: [.roll],
        pressure: 0.8,
        capabilities: [.pressure, .roll],
        roll: 0.4
    )
    let firstPlan = try buffer.planEstimatedUpdate(pressureResolution)
    #expect(firstPlan.mergedSample.pressure == 0.8)
    #expect(firstPlan.mergedSample.roll == 0.4)
    #expect(
        firstPlan.mergedSample.estimatedPropertiesExpectingUpdates
            == [.roll]
    )
    _ = try buffer.replaceEstimatedSuffix(
        using: firstPlan,
        with: [TransientStrokeChunk(sample: firstPlan.mergedSample, dabs: [])]
    )

    let rollResolution = transientSample(
        11,
        kind: .estimatedUpdate,
        estimationUpdateIndex: 12,
        pressure: 0.1,
        capabilities: [.pressure, .roll],
        roll: 0.9
    )
    let secondPlan = try buffer.planEstimatedUpdate(rollResolution)
    #expect(secondPlan.mergedSample.pressure == 0.8)
    #expect(secondPlan.mergedSample.roll == 0.9)
    #expect(
        secondPlan.mergedSample.estimatedPropertiesExpectingUpdates.isEmpty
    )
    _ = try buffer.replaceEstimatedSuffix(
        using: secondPlan,
        with: [
            TransientStrokeChunk(sample: secondPlan.mergedSample, dabs: []),
        ]
    )
    #expect(buffer.actualSamples[0].pressure == 0.8)
    #expect(buffer.actualSamples[0].roll == 0.9)
}

@Test
func locationResolutionRederivesVelocityFromExactInputCheckpoint() throws {
    var deriver = BrushInputDeriver()
    let began = deriver.derive(
        StrokeSample(
            position: ScreenPoint(x: 1, y: 1),
            pressure: 0.5,
            timestamp: 0,
            phase: .began,
            source: .pencil
        ),
        viewport: transientViewport
    )
    let beforeEstimated = deriver
    let estimated = deriver.derive(
        StrokeSample(
            position: ScreenPoint(x: 2, y: 1),
            pressure: 0.5,
            timestamp: 1,
            phase: .moved,
            source: .pencil,
            estimationUpdateIndex: 20,
            estimatedProperties: [.location],
            estimatedPropertiesExpectingUpdates: [.location]
        ),
        viewport: transientViewport
    )
    let beforeLater = deriver
    let later = deriver.derive(
        StrokeSample(
            position: ScreenPoint(x: 3, y: 1),
            pressure: 0.5,
            timestamp: 2,
            phase: .moved,
            source: .pencil
        ),
        viewport: transientViewport
    )
    let generatorBefore = transientGenerator(seed: 70)
    var buffer = transientBuffer(mode: .replayTail)
    _ = buffer.appendActual(
        TransientStrokeChunk(
            sample: began,
            dabs: [],
            generatorSnapshotAfterSample: generatorBefore,
            inputDeriverSnapshotBeforeSample: BrushInputDeriver()
        )
    )
    _ = buffer.appendActual(
        TransientStrokeChunk(
            sample: estimated,
            dabs: [],
            generatorSnapshotBeforeSample: generatorBefore,
            generatorSnapshotAfterSample: transientGenerator(seed: 71),
            inputDeriverSnapshotBeforeSample: beforeEstimated
        )
    )
    _ = buffer.appendActual(
        TransientStrokeChunk(
            sample: later,
            dabs: [],
            inputDeriverSnapshotBeforeSample: beforeLater
        )
    )
    let update = transientSample(
        10,
        kind: .estimatedUpdate,
        estimationUpdateIndex: 20
    )

    let plan = try buffer.planEstimatedUpdate(update)

    #expect(plan.inputDeriverBeforeReplacement == beforeEstimated)
    #expect(plan.generatorBeforeReplacement == generatorBefore)
    #expect(plan.mergedSample.timestamp == 1)
    #expect(plan.mergedSample.position.x == 10)
    #expect(plan.mergedSample.velocity == 10)
    #expect(plan.samplesToReplay.count == 1)
    #expect(plan.samplesToReplay[0].position.x == 2)
    #expect(plan.samplesToReplay[0].velocity == 8)
}

@Test
func predictedEstimatedUpdateRebuildsOnlyPrediction() throws {
    let authoritativeSnapshot = transientGenerator(seed: 80)
    var buffer = transientBuffer(mode: .replayTail)
    _ = buffer.appendActual(
        transientChunk(0, snapshot: authoritativeSnapshot)
    )
    _ = try buffer.replacePredicted(with: [
        estimatedTransientChunk(
            1,
            kind: .predicted,
            estimationUpdateIndex: 21,
            estimatedProperties: [.pressure],
            expecting: [.pressure],
            pressure: 0.2,
            snapshot: transientGenerator(seed: 81),
            generatorBefore: authoritativeSnapshot
        ),
        transientChunk(2, kind: .predicted),
    ])
    let actualBefore = buffer.actualChunks
    let plan = try buffer.planEstimatedUpdate(
        transientSample(
            9,
            kind: .estimatedUpdate,
            estimationUpdateIndex: 21,
            pressure: 0.9
        )
    )
    let oldEpoch = buffer.replayEpoch
    let replayedSamples = [plan.mergedSample] + plan.samplesToReplay
    let rebuiltSnapshot = transientGenerator(seed: 230)
    let rebuilt = replayedSamples.enumerated().map { index, sample in
        TransientStrokeChunk(
            sample: sample,
            dabs: [],
            generatorSnapshotAfterSample:
                index == replayedSamples.count - 1 ? rebuiltSnapshot : nil
        )
    }

    let result = try buffer.replaceEstimatedSuffix(
        using: plan,
        with: rebuilt
    )

    #expect(plan.target == .predicted)
    #expect(plan.generatorBeforeReplacement == authoritativeSnapshot)
    #expect(buffer.actualChunks == actualBefore)
    #expect(buffer.predictedSamples.map(\.pressure) == [0.9, 0.5])
    #expect(buffer.replayEpoch == oldEpoch + 1)
    #expect(!result.clearedPredictedSuffix)
}

@Test
func estimatedUpdateRejectsUnknownDuplicateResolvedAndPromotedIndices()
    throws
{
    let update = transientSample(
        9,
        kind: .estimatedUpdate,
        estimationUpdateIndex: 22,
        pressure: 0.9
    )

    let unknown = transientBuffer(mode: .replayTail)
    #expect(throws: TransientStrokeBufferError.self) {
        try unknown.planEstimatedUpdate(update)
    }

    var duplicate = transientBuffer(mode: .replayTail)
    for index in 1...2 {
        _ = duplicate.appendActual(
            estimatedTransientChunk(
                index,
                estimationUpdateIndex: 22,
                estimatedProperties: [.pressure],
                expecting: [.pressure],
                pressure: 0.2
            )
        )
    }
    #expect(throws: TransientStrokeBufferError.self) {
        try duplicate.planEstimatedUpdate(update)
    }

    var resolved = transientBuffer(mode: .replayTail)
    _ = resolved.appendActual(
        TransientStrokeChunk(
            sample: transientSample(
                1,
                estimationUpdateIndex: 22,
                pressure: 0.2
            ),
            dabs: []
        )
    )
    #expect(throws: TransientStrokeBufferError.self) {
        try resolved.planEstimatedUpdate(update)
    }

    var promoted = transientBuffer(mode: .appendOnly)
    _ = promoted.appendActual(
        TransientStrokeChunk(
            sample: transientSample(
                1,
                estimationUpdateIndex: 22,
                pressure: 0.2
            ),
            dabs: []
        )
    )
    #expect(throws: TransientStrokeBufferError.self) {
        try promoted.planEstimatedUpdate(update)
    }
}

@Test
func appendOnlyPinsUnresolvedSuffixThenPromotesItAfterResolution()
    throws
{
    var buffer = transientBuffer(mode: .appendOnly)
    _ = buffer.appendActual(
        estimatedTransientChunk(
            0,
            estimationUpdateIndex: 23,
            estimatedProperties: [.pressure],
            expecting: [.pressure],
            pressure: 0.2
        )
    )
    for index in 1..<TransientStrokeBufferContract
        .replayTailSampleCapacity
    {
        _ = buffer.appendActual(transientChunk(index, dabCount: 0))
    }
    #expect(
        buffer.actualSampleCount
            == TransientStrokeBufferContract.replayTailSampleCapacity
    )
    let plan = try buffer.planEstimatedUpdate(
        transientSample(
            9,
            kind: .estimatedUpdate,
            estimationUpdateIndex: 23,
            pressure: 0.9
        )
    )
    let replayedSamples = [plan.mergedSample] + plan.samplesToReplay
    let rebuiltSnapshot = transientGenerator(seed: 230)
    let rebuilt = replayedSamples.enumerated().map { index, sample in
        TransientStrokeChunk(
            sample: sample,
            dabs: [],
            generatorSnapshotAfterSample:
                index == replayedSamples.count - 1 ? rebuiltSnapshot : nil
        )
    }
    let oldEpoch = buffer.replayEpoch

    let result = try buffer.replaceEstimatedSuffix(
        using: plan,
        with: rebuilt
    )

    #expect(buffer.actualChunks.isEmpty)
    #expect(
        result.settledPrefix.count
            == TransientStrokeBufferContract.replayTailSampleCapacity
    )
    #expect(buffer.authoritativeGeneratorSnapshot == rebuiltSnapshot)
    #expect(buffer.replayEpoch == oldEpoch + 1)
}

@Test
func appendOnlyUnresolvedSuffixRejectsOverflowTransactionally() {
    var buffer = transientBuffer(mode: .appendOnly)
    _ = buffer.appendActual(
        estimatedTransientChunk(
            0,
            estimationUpdateIndex: 25,
            estimatedProperties: [.pressure],
            expecting: [.pressure],
            pressure: 0.2
        )
    )
    for index in 1..<TransientStrokeBufferContract
        .replayTailSampleCapacity
    {
        let update = buffer.appendActual(
            transientChunk(index, dabCount: 0)
        )
        #expect(update.rejection == nil)
        #expect(update.requiresReplayReplacement)
    }
    let before = buffer

    let overflow = buffer.appendActual(
        transientChunk(
            TransientStrokeBufferContract.replayTailSampleCapacity,
            dabCount: 0
        )
    )

    #expect(
        overflow.rejection
            == .unresolvedSuffixExceedsCapacity(
                sampleCount:
                    TransientStrokeBufferContract.replayTailSampleCapacity + 1,
                dabCount: 0,
                projectedInstanceCount: 0
            )
    )
    #expect(buffer == before)
}

@Test
func appendOnlyUnresolvedSuffixRejectsDabAndProjectionOverflow() {
    var dabBound = transientBuffer(mode: .appendOnly)
    _ = dabBound.appendActual(
        estimatedTransientChunk(
            0,
            estimationUpdateIndex: 26,
            estimatedProperties: [.pressure],
            expecting: [.pressure],
            pressure: 0.2
        )
    )
    _ = dabBound.appendActual(
        transientChunk(
            1,
            dabCount: TransientStrokeBufferContract.replayTailDabCapacity
        )
    )
    let dabBefore = dabBound
    let dabOverflow = dabBound.appendActual(transientChunk(2))
    #expect(dabOverflow.rejection != nil)
    #expect(dabBound == dabBefore)

    var projectionBound = transientBuffer(mode: .appendOnly)
    _ = projectionBound.appendActual(
        estimatedTransientChunk(
            0,
            estimationUpdateIndex: 27,
            estimatedProperties: [.pressure],
            expecting: [.pressure],
            pressure: 0.2
        )
    )
    _ = projectionBound.appendActual(
        transientChunk(
            1,
            projectedInstancesPerDab:
                TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity
        )
    )
    let projectionBefore = projectionBound
    let projectionOverflow = projectionBound.appendActual(transientChunk(2))
    #expect(projectionOverflow.rejection != nil)
    #expect(projectionBound == projectionBefore)
}

@Test
func estimatedUpdateFlagsCanOnlyResolveExistingProperties() throws {
    var buffer = transientBuffer(mode: .replayTail)
    _ = buffer.appendActual(
        TransientStrokeChunk(
            sample: transientSample(
                1,
                estimationUpdateIndex: 28,
                estimatedProperties: [.pressure, .roll],
                expecting: [.pressure, .roll],
                pressure: 0.2,
                capabilities: [.pressure, .roll],
                roll: 0.1
            ),
            dabs: []
        )
    )
    let pressureResolution = transientSample(
        10,
        kind: .estimatedUpdate,
        estimationUpdateIndex: 28,
        estimatedProperties: [.roll],
        expecting: [.roll],
        pressure: 0.8,
        capabilities: [.pressure, .roll],
        roll: 0.2
    )
    let plan = try buffer.planEstimatedUpdate(pressureResolution)
    _ = try buffer.replaceEstimatedSuffix(
        using: plan,
        with: [TransientStrokeChunk(sample: plan.mergedSample, dabs: [])]
    )

    let resurrectedPressure = transientSample(
        11,
        kind: .estimatedUpdate,
        estimationUpdateIndex: 28,
        estimatedProperties: [.pressure, .roll],
        expecting: [.pressure, .roll],
        pressure: 0.4,
        capabilities: [.pressure, .roll],
        roll: 0.3
    )
    #expect(
        throws: TransientStrokeBufferError
            .invalidEstimatedUpdateProperties(28)
    ) {
        try buffer.planEstimatedUpdate(resurrectedPressure)
    }

    let addedLocation = transientSample(
        12,
        kind: .estimatedUpdate,
        estimationUpdateIndex: 28,
        estimatedProperties: [.location, .roll],
        expecting: [.location, .roll],
        pressure: 0.4,
        capabilities: [.pressure, .roll],
        roll: 0.3
    )
    #expect(
        throws: TransientStrokeBufferError
            .invalidEstimatedUpdateProperties(28)
    ) {
        try buffer.planEstimatedUpdate(addedLocation)
    }
}

@Test
func estimatedReplacementCapacityFailureRollsBackEveryField() throws {
    let recipe = try declaredReplayRecipe(
        id: "test.buffer.estimated-capacity",
        maximumSamples: 2,
        maximumDabs: 1,
        maximumProjectedInstances: 10
    )
    var buffer = TransientStrokeBuffer(
        replayContract: recipe.replayContract
    )
    _ = buffer.appendActual(
        estimatedTransientChunk(
            0,
            estimationUpdateIndex: 24,
            estimatedProperties: [.pressure],
            expecting: [.pressure],
            pressure: 0.2
        )
    )
    let plan = try buffer.planEstimatedUpdate(
        transientSample(
            9,
            kind: .estimatedUpdate,
            estimationUpdateIndex: 24,
            pressure: 0.9
        )
    )
    let before = buffer
    let oversized = TransientStrokeChunk(
        sample: plan.mergedSample,
        dabs: [transientDab(1), transientDab(2)]
    )

    #expect(throws: TransientStrokeBufferError.self) {
        try buffer.replaceEstimatedSuffix(using: plan, with: [oversized])
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

@Test
func actualArenaNeverOverwritesAStillRetainedSliceAtWraparound() throws {
    let arena = TransientStrokeDabArena()
    let capacity = TransientStrokeDabArena.retainedCapacity
    let firstTransaction = try arena.beginTransaction(
        replacingPrediction: false
    )
    let retained = try firstTransaction.storeActual(count: capacity) {
        transientDab($0)
    }
    let firstChunk = TransientStrokeChunk(
        sample: transientSample(0),
        dabs: retained
    )
    try firstTransaction.commit(
        retainingActual: [firstChunk],
        retainingPredicted: [TransientStrokeChunk]()
    )

    let secondTransaction = try arena.beginTransaction(
        replacingPrediction: false
    )
    let second = try secondTransaction.storeActual(count: capacity) {
        transientDab(capacity + $0)
    }
    let secondChunk = TransientStrokeChunk(
        sample: transientSample(1),
        dabs: second
    )
    try secondTransaction.commit(
        retainingActual: [firstChunk, secondChunk],
        retainingPredicted: [TransientStrokeChunk]()
    )

    let refused = try arena.beginTransaction(
        replacingPrediction: false
    )
    #expect(
        throws: TransientStrokeDabArena.ReservationError
            .capacityExceeded(capacity * 2)
    ) {
        _ = try refused.storeActual(count: 1) {
            transientDab(capacity * 2 + $0)
        }
    }
    refused.rollback()

    #expect(retained[0] == transientDab(0))
    #expect(retained[capacity - 1] == transientDab(capacity - 1))
}

@Test
func failedPredictionReplacementRetryPreservesPriorPredictionStorage()
    throws
{
    let arena = TransientStrokeDabArena()
    let firstTransaction = try arena.beginTransaction(
        replacingPrediction: true
    )
    let prior = try firstTransaction.storePredicted(count: 1) {
        transientDab(10 + $0, predicted: true)
    }
    let priorChunk = TransientStrokeChunk(
        sample: transientSample(10, kind: .predicted),
        dabs: prior
    )
    try firstTransaction.commit(
        retainingActual: [TransientStrokeChunk](),
        retainingPredicted: [priorChunk]
    )

    let failed = try arena.beginTransaction(replacingPrediction: true)
    _ = try failed.storePredicted(count: 1) {
        transientDab(20 + $0, predicted: true)
    }
    failed.rollback()

    let retry = try arena.beginTransaction(replacingPrediction: true)
    let replacement = try retry.storePredicted(count: 1) {
        transientDab(30 + $0, predicted: true)
    }

    #expect(prior[0] == transientDab(10, predicted: true))
    let replacementChunk = TransientStrokeChunk(
        sample: transientSample(30, kind: .predicted),
        dabs: replacement
    )
    try retry.commit(
        retainingActual: [TransientStrokeChunk](),
        retainingPredicted: [replacementChunk]
    )
}

private func requireSendable<T: Sendable>(_: T) {}
