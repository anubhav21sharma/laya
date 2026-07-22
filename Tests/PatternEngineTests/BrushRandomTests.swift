import Testing
@testable import PatternEngine

@Test(arguments: [
    (UInt64(1), UInt64(0x910a2dec89025cc1), Float(0.56656152)),
    (UInt64(42), UInt64(0xbdd732262feb6e95), Float(0.74156487)),
    (UInt64.max, UInt64(0xe4d971771b652c20), Float(0.8939429)),
])
func splitMix64PinsWordsAndUpper24BitFloats(
    fixture: (seed: UInt64, word: UInt64, unit: Float)
) {
    var random = BrushRandom(seed: fixture.seed)
    let word = random.nextWord()

    #expect(word == fixture.word)
    #expect(BrushRandom.unitFloat(from: word) == fixture.unit)
    #expect(BrushRandom.unitFloat(from: word) >= 0)
    #expect(BrushRandom.unitFloat(from: word) < 1)
}

@Test func eachDabConsumesTheSameSevenNamedChannels() {
    var random = BrushRandom(seed: 0x1234_5678_9abc_def0)
    let first = random.nextValues()
    let second = random.nextValues()

    var words = BrushRandom(seed: 0x1234_5678_9abc_def0)
    let expectedFirst = BrushRandomValues(
        spacing: BrushRandom.unitFloat(from: words.nextWord()),
        scatterX: BrushRandom.unitFloat(from: words.nextWord()),
        scatterY: BrushRandom.unitFloat(from: words.nextWord()),
        rotation: BrushRandom.unitFloat(from: words.nextWord()),
        grainX: BrushRandom.unitFloat(from: words.nextWord()),
        grainY: BrushRandom.unitFloat(from: words.nextWord()),
        materialVariation: BrushRandom.unitFloat(from: words.nextWord())
    )

    #expect(first == expectedFirst)
    #expect(second.spacing == BrushRandom.unitFloat(from: words.nextWord()))
    #expect(first.spacing != second.spacing)
}

@Test func predictedRandomEvaluationCannotAdvanceActualCursor() {
    var actual = BrushRandom(seed: 9)
    let predictedA = actual.predictedValues()
    let predictedB = actual.predictedValues()
    let authoritative = actual.nextValues()

    #expect(predictedA == predictedB)
    #expect(authoritative == predictedA)
    #expect(actual.nextValues() != authoritative)
}

@Test func disabledDynamicsStillReserveEveryRandomChannel() throws {
    var disabledCursor = BrushRandom(seed: 88)
    var enabledCursor = BrushRandom(seed: 88)
    let disabledValues = disabledCursor.nextValues()
    let enabledValues = enabledCursor.nextValues()
    let engine = BrushDynamicsEngine()
    let sample = dynamicsSample()
    let context = dynamicsContext()
    let enabledRecipe = try BrushRecipe(
        id: BrushRecipeID("test.random.enabled"),
        randomization: BrushRandomization(
            spacing: 0.25,
            scatter: 0.25,
            rotation: 0.25,
            grain: 0.25,
            material: 0.25
        )
    )

    _ = engine.evaluate(
        sample: sample,
        context: context,
        recipe: .legacyEquivalent,
        random: disabledValues
    )
    _ = engine.evaluate(
        sample: sample,
        context: context,
        recipe: enabledRecipe,
        random: enabledValues
    )

    #expect(disabledCursor == enabledCursor)
    #expect(disabledCursor.nextValues() == enabledCursor.nextValues())
}

private func dynamicsSample() -> InterpolatedStrokeSample {
    InterpolatedStrokeSample(
        position: WorldPoint(x: 0, y: 0),
        pressure: 1,
        timestamp: 0,
        altitude: nil,
        azimuth: nil,
        roll: nil,
        velocity: 0,
        phase: .moved,
        source: .mouse,
        kind: .actual,
        capabilities: []
    )
}

private func dynamicsContext() -> BrushStrokeContext {
    BrushStrokeContext(
        nominalDiameter: 20,
        color: .black,
        direction: 0,
        strokeAge: 0,
        traveledDistance: 0,
        ordinal: 0,
        isPredicted: false
    )
}
