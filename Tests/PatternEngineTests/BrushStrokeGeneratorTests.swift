import Foundation
@testable import PatternEngine
import Testing

private let generatorViewport = ViewportTransform(
    drawableSize: PatternSize(width: 2, height: 2),
    worldCenter: WorldPoint(x: 0, y: 0)
)

private func generatorSample(
    x: Float,
    y: Float = 0,
    pressure: Float = 0.5,
    timestamp: TimeInterval,
    phase: StrokePhase,
    capabilities: StrokeInputCapabilities = []
) -> WorldStrokeSample {
    let sample = StrokeSample(
        position: ScreenPoint(x: x + 1, y: y + 1),
        pressure: pressure,
        timestamp: timestamp,
        phase: phase,
        source: capabilities.contains(.pressure) ? .pencil : .mouse,
        capabilities: capabilities
    )
    var input = BrushInputDeriver()
    return input.derive(sample, viewport: generatorViewport)
}

private func legacyGenerator(seed: UInt64 = 1) -> BrushStrokeGenerator {
    BrushStrokeGenerator(
        recipe: .legacyEquivalent,
        nominalDiameter: 20,
        color: .black,
        seed: seed
    )
}

@Test
func generatorAcceptsAPrecompiledProgram() throws {
    let definition = try LegacyBrushRecipeAdapter.definition(
        from: .legacyEquivalent,
        displayName: "Legacy"
    )
    let program = try BrushProgramCompiler.compile(definition)
    let generator = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 20,
        color: .black,
        seed: 17
    )

    #expect(generator.program == program)
}

@Test
func generatorPreservesLegacyStraightPlacementAndExactEndpoint() {
    var generator = legacyGenerator()
    var dabs: [DabAttributes] = []
    generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { dabs.append($0) }
    generator.append(
        generatorSample(x: 5, timestamp: 1, phase: .moved)
    ) { dabs.append($0) }
    generator.finish(
        generatorSample(x: 6, timestamp: 2, phase: .ended)
    ) { dabs.append($0) }

    #expect(dabs.map(\.position) == [
        WorldPoint(x: 0, y: 0),
        WorldPoint(x: 2.5, y: 0),
        WorldPoint(x: 5, y: 0),
        WorldPoint(x: 6, y: 0),
    ])
    #expect(dabs.map(\.ordinal) == [0, 1, 2, 3])
    #expect(dabs.allSatisfy { $0.spacing == 2.5 })
}

@Test
func generatorCarriesDynamicSpacingAndNeverEmitsCoincidentDabs() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.generator.spacing"),
        baseSpacingFraction: 0.1,
        maximumSpacingFraction: 0.25,
        spacingMapping: .linear(input: .pressure, output: 1...2)
    )
    var generator = BrushStrokeGenerator(
        recipe: recipe,
        nominalDiameter: 20,
        color: .black,
        seed: 7
    )
    var dabs: [DabAttributes] = []
    generator.begin(
        generatorSample(
            x: 0,
            pressure: 0,
            timestamp: 0,
            phase: .began,
            capabilities: [.pressure]
        )
    ) { dabs.append($0) }
    generator.append(
        generatorSample(
            x: 1,
            pressure: 1,
            timestamp: 1,
            phase: .moved,
            capabilities: [.pressure]
        )
    ) { dabs.append($0) }
    generator.append(
        generatorSample(
            x: 1,
            pressure: 1,
            timestamp: 2,
            phase: .moved,
            capabilities: [.pressure]
        )
    ) { dabs.append($0) }
    generator.finish(
        generatorSample(
            x: 8,
            pressure: 1,
            timestamp: 3,
            phase: .ended,
            capabilities: [.pressure]
        )
    ) { dabs.append($0) }

    #expect(dabs.first?.spacing == 2)
    #expect(dabs.last?.position == WorldPoint(x: 8, y: 0))
    for pair in zip(dabs, dabs.dropFirst()) {
        #expect(pair.0.position != pair.1.position)
    }
    #expect(dabs.map(\.ordinal) == Array(0..<UInt64(dabs.count)))
}

@Test
func generatorInterpolatesPressurePerDab() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.generator.pressure-per-dab"),
        baseSpacingFraction: 0.05,
        maximumSpacingFraction: 0.4,
        sizeMapping: .linear(input: .pressure, output: 0.5...1)
    )
    var generator = BrushStrokeGenerator(
        recipe: recipe,
        nominalDiameter: 20,
        color: .black,
        seed: 1
    )
    var dabs: [DabAttributes] = []
    generator.begin(
        generatorSample(
            x: 0,
            pressure: 0,
            timestamp: 0,
            phase: .began,
            capabilities: [.pressure]
        )
    ) { dabs.append($0) }
    generator.finish(
        generatorSample(
            x: 10,
            pressure: 1,
            timestamp: 1,
            phase: .ended,
            capabilities: [.pressure]
        )
    ) { dabs.append($0) }

    #expect(dabs.first?.diameter == 10)
    #expect(dabs.last?.diameter == 20)
    for pair in zip(dabs, dabs.dropFirst()) {
        #expect(pair.0.diameter <= pair.1.diameter)
    }
    #expect(Set(dabs.map(\.diameter)).count > 3)
}

@Test
func straightGeneratorOutputIsInvariantToEventPartitioning() {
    var single = legacyGenerator()
    var partitioned = legacyGenerator()
    var singleDabs: [DabAttributes] = []
    var partitionedDabs: [DabAttributes] = []

    single.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { singleDabs.append($0) }
    single.finish(
        generatorSample(x: 10, timestamp: 1, phase: .ended)
    ) { singleDabs.append($0) }

    partitioned.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { partitionedDabs.append($0) }
    partitioned.append(
        generatorSample(x: 3, timestamp: 0.3, phase: .moved)
    ) { partitionedDabs.append($0) }
    partitioned.append(
        generatorSample(x: 7, timestamp: 0.7, phase: .moved)
    ) { partitionedDabs.append($0) }
    partitioned.finish(
        generatorSample(x: 10, timestamp: 1, phase: .ended)
    ) { partitionedDabs.append($0) }

    #expect(partitionedDabs.map(\.position) == singleDabs.map(\.position))
}

@Test
func clickEmitsOnceAndCancelDropsAllGeneratorCarry() {
    var generator = legacyGenerator()
    var positions: [WorldPoint] = []
    generator.begin(
        generatorSample(x: 4, timestamp: 0, phase: .began)
    ) { positions.append($0.position) }
    generator.finish(
        generatorSample(x: 4, timestamp: 1, phase: .ended)
    ) { positions.append($0.position) }
    #expect(positions == [WorldPoint(x: 4, y: 0)])

    generator.begin(
        generatorSample(x: 0, timestamp: 2, phase: .began)
    ) { _ in }
    generator.append(
        generatorSample(x: 1, timestamp: 3, phase: .moved)
    ) { _ in }
    generator.cancel()
    generator.append(
        generatorSample(x: 40, timestamp: 4, phase: .moved)
    ) { positions.append($0.position) }

    #expect(positions.last == WorldPoint(x: 40, y: 0))
}

@Test
func transformedFootprintsAreDeterministicForRecipeAndSeed() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.generator.transform"),
        baseScatterFraction: 0.25,
        aspectRatio: 0.5,
        randomization: BrushRandomization(
            spacing: 0,
            scatter: 1,
            rotation: 1,
            grain: 0,
            material: 0
        )
    )
    func output(seed: UInt64) -> [DabAttributes] {
        var generator = BrushStrokeGenerator(
            recipe: recipe,
            nominalDiameter: 20,
            color: .black,
            seed: seed
        )
        var dabs: [DabAttributes] = []
        generator.begin(
            generatorSample(x: 0, timestamp: 0, phase: .began)
        ) { dabs.append($0) }
        generator.finish(
            generatorSample(x: 10, timestamp: 1, phase: .ended)
        ) { dabs.append($0) }
        return dabs
    }

    #expect(output(seed: 99) == output(seed: 99))
    #expect(output(seed: 99) != output(seed: 100))
}

@Test
func copiedGeneratorPredictionDoesNotAdvanceActualState() {
    var actual = legacyGenerator(seed: 44)
    var actualPrefix: [DabAttributes] = []
    actual.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { actualPrefix.append($0) }

    var predicted = actual
    var predictedDabs: [DabAttributes] = []
    predicted.append(
        generatorSample(x: 10, timestamp: 1, phase: .moved)
    ) { predictedDabs.append($0) }

    var actualDabs: [DabAttributes] = []
    actual.append(
        generatorSample(x: 10, timestamp: 1, phase: .moved)
    ) { actualDabs.append($0) }

    #expect(actualDabs == predictedDabs)
    #expect(actualPrefix.count == 1)
}

@Test
func knownTotalDistanceAppliesStartAndEndTaperDeterministically() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.generator.taper"),
        taper: BrushTaperConfiguration(
            start: .worldPixels(4),
            end: .worldPixels(4),
            minimumSize: 0.25,
            minimumFlow: 0.2,
            effects: [.size, .flow]
        ),
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    var generator = BrushStrokeGenerator(
        recipe: recipe,
        nominalDiameter: 20,
        color: .black,
        seed: 8
    )
    var dabs: [DabAttributes] = []
    generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { dabs.append($0) }
    generator.finish(
        generatorSample(x: 12, timestamp: 1, phase: .ended)
    ) { dabs.append($0) }
    let tapered = dabs.map {
        BrushDynamicsEngine().applyingKnownTotalDistance(
            $0,
            totalDistance: 12,
            nominalDiameter: 20,
            recipe: recipe
        )
    }

    #expect(tapered.first?.diameter == 5)
    #expect(tapered.last?.diameter == 5)
    #expect(tapered.map(\.diameter).max() == 20)
    #expect(tapered.first?.flow == 0.2)
    #expect(tapered.last?.flow == 0.2)
}

@Test
func clickAndShortStrokeTaperStayFiniteAndBounded() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.generator.short-taper"),
        taper: BrushTaperConfiguration(
            start: .diameterMultiples(2),
            end: .diameterMultiples(2),
            minimumSize: 0.1,
            minimumFlow: 0.15,
            effects: [.size, .flow]
        ),
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    var generator = BrushStrokeGenerator(
        recipe: recipe,
        nominalDiameter: 20,
        color: .black,
        seed: 9
    )
    var dabs: [DabAttributes] = []
    generator.begin(
        generatorSample(x: 3, timestamp: 0, phase: .began)
    ) { dabs.append($0) }
    generator.finish(
        generatorSample(x: 3, timestamp: 1, phase: .ended)
    ) { dabs.append($0) }
    let click = try #require(dabs.first)
    let tapered = BrushDynamicsEngine().applyingKnownTotalDistance(
        click,
        totalDistance: 0,
        nominalDiameter: 20,
        recipe: recipe
    )
    #expect(tapered.diameter == 2)
    #expect(tapered.flow == 0.15)
    #expect(tapered.brushToWorld.xAxis.x.isFinite)
}

@Test
func batchAPIsPreserveCallbackOutputAcrossEmptyBoundaries() {
    let began = generatorSample(x: 0, timestamp: 0, phase: .began)
    let moved = generatorSample(x: 0.1, timestamp: 0.5, phase: .moved)
    let ended = generatorSample(x: 6, timestamp: 1, phase: .ended)
    var callback = legacyGenerator(seed: 51)
    var expected: [LogicalDab] = []
    callback.begin(began) { expected.append($0) }
    callback.append(moved) { expected.append($0) }
    callback.finish(ended) { expected.append($0) }

    var batched = legacyGenerator(seed: 51)
    let batches = batched.beginBatches(began)
        + batched.appendBatches(moved)
        + batched.finishBatches(ended)

    #expect(batches.flatMap(\.dabs) == expected)
    #expect(batches[0].ordinalRange == 0..<1)
    #expect(batches[1].dabs.isEmpty)
    #expect(batches[1].ordinalRange == 1..<1)
    #expect(batches[2].ordinalRange.lowerBound == 1)
    #expect(batched == callback)
}

@Test
func batchBeginResetsOrdinalsForActiveAndProgressedStrokes() throws {
    let first = generatorSample(x: 0, timestamp: 0, phase: .began)
    let replacement = generatorSample(x: 40, timestamp: 2, phase: .began)

    var activeCallback = legacyGenerator(seed: 53)
    activeCallback.begin(first) { _ in }
    var expectedActiveReset: [LogicalDab] = []
    activeCallback.begin(replacement) { expectedActiveReset.append($0) }

    var activeSingular = legacyGenerator(seed: 53)
    _ = try activeSingular.beginBatch(first)
    let activeSingularReset = try activeSingular.beginBatch(replacement)

    #expect(activeSingularReset.ordinalRange == 0..<1)
    #expect(activeSingularReset.dabs == expectedActiveReset)
    #expect(activeSingular == activeCallback)

    var activePlural = legacyGenerator(seed: 53)
    _ = activePlural.beginBatches(first)
    let activePluralReset = activePlural.beginBatches(replacement)

    #expect(activePluralReset.map(\.ordinalRange) == [0..<1])
    #expect(activePluralReset.flatMap(\.dabs) == expectedActiveReset)
    #expect(activePlural == activeCallback)

    let moved = generatorSample(x: 30, timestamp: 1, phase: .moved)
    var progressedCallback = legacyGenerator(seed: 55)
    progressedCallback.begin(first) { _ in }
    progressedCallback.append(moved) { _ in }
    #expect(progressedCallback.emittedDabCount > 1)
    var expectedProgressedReset: [LogicalDab] = []
    progressedCallback.begin(replacement) { expectedProgressedReset.append($0) }

    var progressedSingular = legacyGenerator(seed: 55)
    _ = try progressedSingular.beginBatch(first)
    _ = try progressedSingular.appendBatch(moved)
    #expect(progressedSingular.emittedDabCount > 1)
    let progressedSingularReset = try progressedSingular.beginBatch(replacement)

    #expect(progressedSingularReset.ordinalRange == 0..<1)
    #expect(progressedSingularReset.dabs == expectedProgressedReset)
    #expect(progressedSingular == progressedCallback)

    var progressedPlural = legacyGenerator(seed: 55)
    _ = progressedPlural.beginBatches(first)
    _ = progressedPlural.appendBatches(moved)
    #expect(progressedPlural.emittedDabCount > 1)
    let progressedPluralReset = progressedPlural.beginBatches(replacement)

    #expect(progressedPluralReset.map(\.ordinalRange) == [0..<1])
    #expect(progressedPluralReset.flatMap(\.dabs) == expectedProgressedReset)
    #expect(progressedPlural == progressedCallback)
}

@Test
func pluralBatchesSplitAnEightHundredDabSampleWithoutLoss() throws {
    let began = generatorSample(x: 0, timestamp: 0, phase: .began)
    let ended = generatorSample(x: 2_000, timestamp: 1, phase: .ended)

    var callback = legacyGenerator(seed: 57)
    callback.begin(began) { _ in }
    var expected: [LogicalDab] = []
    callback.finish(ended) { expected.append($0) }
    #expect(expected.count == 800)

    var plural = legacyGenerator(seed: 57)
    _ = plural.beginBatches(began)
    let batches = plural.finishBatches(ended)

    #expect(batches.map(\.dabs.count) == [512, 288])
    #expect(batches.map(\.ordinalRange) == [1..<513, 513..<801])
    #expect(batches.flatMap(\.dabs) == expected)
    #expect(plural == callback)

    var singular = legacyGenerator(seed: 57)
    _ = try singular.beginBatch(began)
    let beforeRejectedSample = singular
    #expect(throws: LogicalDabBatchError.tooManyDabs(
        actual: 800,
        maximum: LogicalDabBatch.maximumDabCount
    )) {
        try singular.finishBatch(ended)
    }
    #expect(singular == beforeRejectedSample)

    enum ExpectedFailure: Error, Equatable {
        case rejectedSecondChunk
    }
    var transactional = legacyGenerator(seed: 57)
    _ = transactional.beginBatches(began)
    let beforeRejectedChunks = transactional
    var validationCount = 0
    #expect(throws: ExpectedFailure.rejectedSecondChunk) {
        try transactional.validatedBatches(
            ended,
            operation: .finish
        ) { seed, startingOrdinal, isPredicted, dabs in
            validationCount += 1
            guard validationCount < 2 else {
                throw ExpectedFailure.rejectedSecondChunk
            }
            return try LogicalDabBatch(
                seed: seed,
                startingOrdinal: startingOrdinal,
                isPredicted: isPredicted,
                dabs: dabs
            )
        }
    }
    #expect(validationCount == 2)
    #expect(transactional == beforeRejectedChunks)
}

@Test
func predictionBatchDoesNotAdvanceAuthoritativeDabsOrRandomCursor() throws {
    let began = generatorSample(x: 0, timestamp: 0, phase: .began)
    var authoritative = legacyGenerator(seed: 63)
    _ = try authoritative.beginBatch(began)
    var predicted = authoritative
    let predictedBatch = try predicted.finishBatch(
        generatorSample(
            x: 9,
            timestamp: 0.5,
            phase: .ended
        ).replacingKindForTest(.predicted)
    )
    #expect(!predictedBatch.dabs.isEmpty)

    var withoutPrediction = authoritative
    let actual = generatorSample(x: 6, timestamp: 1, phase: .ended)
    let afterPrediction = try authoritative.finishBatch(actual)
    let baseline = try withoutPrediction.finishBatch(actual)

    #expect(afterPrediction == baseline)
    #expect(authoritative == withoutPrediction)
}

@Test
func failedBatchValidationLeavesGeneratorExactlyUnchanged() {
    enum ExpectedFailure: Error, Equatable {
        case rejected
    }
    var generator = legacyGenerator(seed: 75)
    let original = generator

    #expect(throws: ExpectedFailure.rejected) {
        try generator.validatedBatch(
            generatorSample(x: 0, timestamp: 0, phase: .began),
            operation: .begin
        ) { _, _, _, _ in
            throw ExpectedFailure.rejected
        }
    }
    #expect(generator == original)
}

@Test
func generatedLogicalDabStoresConsumedCompatibilityRandomValues() throws {
    var generator = legacyGenerator(seed: 81)
    let batch = try generator.beginBatch(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    )
    var random = BrushRandom(seed: 81)
    let expected = random.nextValues()

    #expect(batch.dabs.first?.randomValues.compatibility == expected)
    #expect(batch.dabs.first?.randomValues.extensionValues == Array(
        repeating: 0,
        count: 10
    ))
}

@Test
func retroactiveTaperPreservesAppendedLogicalDabInputs() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.generator.logical-taper"),
        taper: BrushTaperConfiguration(
            start: .worldPixels(4),
            end: .worldPixels(4),
            minimumSize: 0.25,
            minimumFlow: 0.2,
            effects: [.size, .flow]
        ),
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    var generator = BrushStrokeGenerator(
        recipe: recipe,
        nominalDiameter: 20,
        color: .black,
        seed: 91
    )
    _ = try generator.beginBatch(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    )
    let original = try #require(
        try generator.finishBatch(
            generatorSample(x: 12, timestamp: 1, phase: .ended)
        ).dabs.last
    )
    let tapered = BrushDynamicsEngine().applyingKnownTotalDistance(
        original,
        totalDistance: 12,
        nominalDiameter: 20,
        recipe: recipe
    )

    #expect(tapered.materialInputs == original.materialInputs)
    #expect(tapered.randomValues == original.randomValues)
    #expect(tapered.primaryGrainToWorld == original.primaryGrainToWorld)
    #expect(tapered.secondaryGrainToWorld == original.secondaryGrainToWorld)
    #expect(tapered.worldBounds != original.worldBounds)
}

private extension WorldStrokeSample {
    func replacingKindForTest(_ kind: StrokeSampleKind) -> WorldStrokeSample {
        let source = StrokeSample(
            position: ScreenPoint(x: position.x + 1, y: position.y + 1),
            pressure: pressure,
            timestamp: timestamp,
            phase: phase,
            source: self.source,
            kind: kind,
            capabilities: capabilities,
            altitude: altitude,
            azimuth: azimuth,
            roll: roll
        )
        var input = BrushInputDeriver()
        return input.derive(source, viewport: generatorViewport)
    }
}
