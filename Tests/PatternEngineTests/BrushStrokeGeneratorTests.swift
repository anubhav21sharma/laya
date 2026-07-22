import Foundation
import PatternEngine
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
