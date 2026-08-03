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
        program: nativeTestProgram(),
        nominalDiameter: 20,
        color: .black,
        seed: seed
    )
}

private func stageCGenerator(
    id: String,
    stabilization: BrushStabilizationDefinition = .none,
    usesTravelDirection: Bool = false,
    maximumAngularStep: Float = .pi / 6,
    stationaryDirection: Float = 0,
    baseSpacingFraction: Float? = nil,
    seed: UInt64 = 1
) throws -> BrushStrokeGenerator {
    BrushStrokeGenerator(
        program: try stageCTestProgram(
            id: id,
            stabilization: stabilization,
            usesTravelDirection: usesTravelDirection,
            maximumAngularStep: maximumAngularStep,
            stationaryDirection: stationaryDirection,
            baseSpacingFraction: baseSpacingFraction
        ),
        nominalDiameter: 20,
        color: .black,
        seed: seed
    )
}

@Test
func manualEqualityInventoryCoversEveryStoredField() {
    let fieldNames = Set(
        Mirror(reflecting: legacyGenerator()).children.compactMap(\.label)
    )

    #expect(fieldNames == Set([
        "program",
        "nominalDiameter",
        "color",
        "seed",
        "currentSpacing",
        "emittedDabCount",
        "stabilizer",
        "directionTracker",
        "cornerEmitter",
        "path",
        "random",
        "isActive",
        "hasAttributedPath",
        "heldDirectionalBegin",
        "nextCornerSequence",
        "strokeStartTimestamp",
        "processedPathDistance",
        "distanceUntilNext",
        "lastDirection",
        "lastEmittedSourcePosition",
    ]))
}

@Test
func schemaV2NonePinsExactNonDirectionalTrace() throws {
    var generator = try stageCGenerator(id: "test.generator.v2-none")
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
}

@Test
func directionalBeginWaitsForFirstTravelWithoutConsumingOrdinalOrRandom()
    throws
{
    var generator = try stageCGenerator(
        id: "test.generator.directional-begin",
        usesTravelDirection: true,
        seed: 0x51
    )
    var began: [DabAttributes] = []
    generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { began.append($0) }

    #expect(began.isEmpty)
    #expect(generator.emittedDabCount == 0)

    var moved: [DabAttributes] = []
    generator.append(
        generatorSample(x: 5, timestamp: 1, phase: .moved)
    ) { moved.append($0) }

    #expect(moved.map(\.position) == [
        WorldPoint(x: 0, y: 0),
        WorldPoint(x: 2.5, y: 0),
        WorldPoint(x: 5, y: 0),
    ])
    #expect(moved.map(\.ordinal) == [0, 1, 2])
    var expectedRandom = BrushRandom(seed: 0x51)
    #expect(moved.first?.randomValues.compatibility == expectedRandom.nextValues())
    #expect(moved.allSatisfy { abs($0.rotation) < 0.000_01 })
}

@Test
func stationaryDirectionalTapUsesCompiledFallbackAndEmitsExactlyOneDab()
    throws
{
    let fallback = Float.pi / 3
    var generator = try stageCGenerator(
        id: "test.generator.directional-tap",
        usesTravelDirection: true,
        stationaryDirection: fallback
    )
    var dabs: [DabAttributes] = []

    generator.begin(
        generatorSample(x: 4, y: 7, timestamp: 0, phase: .began)
    ) { dabs.append($0) }
    generator.finish(
        generatorSample(x: 4, y: 7, timestamp: 1, phase: .ended)
    ) { dabs.append($0) }

    #expect(dabs.count == 1)
    #expect(dabs.first?.position == WorldPoint(x: 4, y: 7))
    #expect(dabs.first?.ordinal == 0)
    #expect(abs(try #require(dabs.first).rotation - fallback) < 0.000_01)
}

@Test
func weightedFinishAddsOnlyOneCausalEndpointCorrectionAndResetsForNextStroke()
    throws
{
    var generator = try stageCGenerator(
        id: "test.generator.weighted-finish",
        stabilization: .weightedWindow(distance: 4),
        baseSpacingFraction: 0.05
    )
    var body: [DabAttributes] = []
    generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { body.append($0) }
    for index in 1...8 {
        generator.append(
            generatorSample(
                x: Float(index),
                timestamp: Double(index),
                phase: .moved
            )
        ) { body.append($0) }
    }
    let bodyBeforeFinish = body
    #expect((body.last?.position.x ?? 8) < 7)
    var correction: [DabAttributes] = []
    generator.finish(
        generatorSample(x: 9, timestamp: 9, phase: .ended)
    ) { correction.append($0) }

    #expect(body == bodyBeforeFinish)
    #expect(correction.count == 1)
    #expect(correction.first?.position == WorldPoint(x: 9, y: 0))

    var next: [DabAttributes] = []
    generator.begin(
        generatorSample(x: 100, timestamp: 10, phase: .began)
    ) { next.append($0) }
    #expect(next.map(\.position) == [WorldPoint(x: 100, y: 0)])
    #expect(next.map(\.ordinal) == [0])
}

@Test
func delayedFinishPreservesDeclaredLagWithoutFlushingBodyAndTapResets()
    throws
{
    var generator = try stageCGenerator(
        id: "test.generator.delayed-finish",
        stabilization: .delayed(distance: 4)
    )
    var dabs: [DabAttributes] = []
    generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { dabs.append($0) }
    generator.append(
        generatorSample(x: 2, timestamp: 1, phase: .moved)
    ) { dabs.append($0) }
    generator.append(
        generatorSample(x: 6, timestamp: 2, phase: .moved)
    ) { dabs.append($0) }
    generator.finish(
        generatorSample(x: 10, timestamp: 3, phase: .ended)
    ) { dabs.append($0) }

    #expect(!dabs.isEmpty)
    #expect(dabs.last?.position == WorldPoint(x: 6, y: 0))
    #expect(dabs.allSatisfy { $0.position.x <= 6 })

    var tap: [DabAttributes] = []
    generator.begin(
        generatorSample(x: 20, timestamp: 4, phase: .began)
    ) { tap.append($0) }
    generator.finish(
        generatorSample(x: 20, timestamp: 5, phase: .ended)
    ) { tap.append($0) }
    #expect(tap.count == 1)
    #expect(tap.first?.position == WorldPoint(x: 20, y: 0))
    #expect(tap.first?.ordinal == 0)
}

@Test
func directionalPredictionRunsFromValueCopyAndLeavesAuthoritativeStateUntouched()
    throws
{
    var authoritative = try stageCGenerator(
        id: "test.generator.direction-prediction",
        usesTravelDirection: true,
        maximumAngularStep: .pi / 8,
        seed: 0x71
    )
    authoritative.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { _ in }
    authoritative.append(
        generatorSample(x: 8, timestamp: 1, phase: .moved)
    ) { _ in }
    let beforePrediction = authoritative

    var prediction = authoritative
    var predictedDabs: [DabAttributes] = []
    let outcome = try prediction.appendPredictionPrefix(
        generatorSample(x: 8, y: 8, timestamp: 2, phase: .moved)
            .replacingKindForTest(.predicted),
        maximumPathSubdivisionCount: 4_096
    ) { predictedDabs.append($0) }

    #expect(outcome == .completed)
    #expect(!predictedDabs.isEmpty)
    #expect(authoritative == beforePrediction)

    var baseline = beforePrediction
    var afterPrediction: [DabAttributes] = []
    var expected: [DabAttributes] = []
    let actual = generatorSample(x: 8, y: 8, timestamp: 2, phase: .moved)
    authoritative.append(actual) { afterPrediction.append($0) }
    baseline.append(actual) { expected.append($0) }
    #expect(afterPrediction == expected)
    #expect(authoritative == baseline)
}

@Test
func typedCornerCapacityFailurePublishesNothingAndGeneratorRemainsReusable()
    throws
{
    var generator = try stageCGenerator(
        id: "test.generator.corner-capacity",
        usesTravelDirection: true,
        maximumAngularStep: BrushCornerEmitter.minimumAngularStep,
        seed: 0x73
    )
    try generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { _ in }
    try generator.append(
        generatorSample(x: 10, timestamp: 1, phase: .moved),
        maximumPathSubdivisionCount: 4_096
    ) { _ in }
    let beforeReversal = generator
    var rejected: [DabAttributes] = []

    #expect(throws: BrushCornerEmitterError.self) {
        try generator.append(
            generatorSample(x: 0, timestamp: 2, phase: .moved),
            maximumPathSubdivisionCount: 4_096
        ) { rejected.append($0) }
    }
    #expect(rejected.isEmpty)
    #expect(generator == beforeReversal)

    var baseline = beforeReversal
    let recovery = generatorSample(x: 20, timestamp: 3, phase: .moved)
    var actualDabs: [DabAttributes] = []
    var expectedDabs: [DabAttributes] = []
    try generator.append(
        recovery,
        maximumPathSubdivisionCount: 4_096
    ) { actualDabs.append($0) }
    try baseline.append(
        recovery,
        maximumPathSubdivisionCount: 4_096
    ) { expectedDabs.append($0) }
    #expect(actualDabs == expectedDabs)
    #expect(generator == baseline)
}

@Test
func cornerCanonicalKeyBoundaryIsTypedTransactionalAndReusable() throws {
    func generator(id: String, seed: UInt64) throws -> BrushStrokeGenerator {
        try stageCGenerator(
            id: id,
            usesTravelDirection: true,
            maximumAngularStep: .pi / 4,
            seed: seed
        )
    }

    let largestRepresentableInt64 = Double(Int64.max).nextDown
    #expect(
        try BrushStrokeGenerator.canonicalKey(
            largestRepresentableInt64,
            scale: 1
        ) == Int64(exactly: largestRepresentableInt64)
    )
    #expect(
        try BrushStrokeGenerator.canonicalKey(
            Double(Int64.min),
            scale: 1
        ) == Int64.min
    )
    #expect(throws: BrushCornerEmitterError.canonicalKeyOverflow) {
        try BrushStrokeGenerator.canonicalKey(
            Double(Int64.max),
            scale: 1
        )
    }

    let safeTimestamp: TimeInterval = 2
    var safe = try generator(id: "test.generator.corner-key-safe", seed: 0x74)
    safe.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { _ in }
    try safe.append(
        generatorSample(x: 10, timestamp: 1, phase: .moved),
        maximumPathSubdivisionCount: 4_096
    ) { _ in }
    try safe.append(
        generatorSample(x: 20, timestamp: safeTimestamp, phase: .moved),
        maximumPathSubdivisionCount: 4_096
    ) { _ in }
    var boundaryDabs: [DabAttributes] = []
    try safe.append(
        generatorSample(
            x: 20,
            y: 10,
            timestamp: safeTimestamp + 1,
            phase: .moved
        ),
        maximumPathSubdivisionCount: 4_096
    ) { boundaryDabs.append($0) }
    #expect(!boundaryDabs.isEmpty)

    var overflowing = try generator(
        id: "test.generator.corner-key-overflow",
        seed: 0x75
    )
    overflowing.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { _ in }
    try overflowing.append(
        generatorSample(x: 10, timestamp: 1, phase: .moved),
        maximumPathSubdivisionCount: 4_096
    ) { _ in }
    let beforeOverflow = overflowing
    var rejected: [DabAttributes] = []

    #expect(throws: BrushCornerEmitterError.canonicalKeyOverflow) {
        try overflowing.append(
            generatorSample(x: 20, timestamp: 10_000_000_000, phase: .moved),
            maximumPathSubdivisionCount: 4_096
        ) { rejected.append($0) }
    }
    #expect(rejected.isEmpty)
    #expect(overflowing == beforeOverflow)

    var baseline = beforeOverflow
    overflowing.cancel()
    baseline.cancel()
    var actual: [DabAttributes] = []
    var expected: [DabAttributes] = []
    overflowing.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { actual.append($0) }
    baseline.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { expected.append($0) }
    try overflowing.append(
        generatorSample(x: 10, timestamp: 1, phase: .moved),
        maximumPathSubdivisionCount: 4_096
    ) { actual.append($0) }
    try baseline.append(
        generatorSample(x: 10, timestamp: 1, phase: .moved),
        maximumPathSubdivisionCount: 4_096
    ) { expected.append($0) }
    #expect(actual == expected)
    #expect(overflowing == baseline)
}

@Test
func exactReversalEmitsBoundedOrderedFanBeforeNumberingAndRandomConsumption()
    throws
{
    let seed: UInt64 = 0x77
    var generator = try stageCGenerator(
        id: "test.generator.corner-order",
        usesTravelDirection: true,
        maximumAngularStep: .pi / 4,
        seed: seed
    )
    generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { _ in }
    var prefix: [DabAttributes] = []
    try generator.append(
        generatorSample(x: 10, timestamp: 1, phase: .moved),
        maximumPathSubdivisionCount: 4_096
    ) { prefix.append($0) }
    let startingOrdinal = generator.emittedDabCount

    var reversal: [DabAttributes] = []
    try generator.append(
        generatorSample(x: 0, timestamp: 2, phase: .moved),
        maximumPathSubdivisionCount: 4_096
    ) { reversal.append($0) }

    #expect(reversal.count >= 3)
    #expect(reversal.prefix(3).allSatisfy {
        $0.position == WorldPoint(x: 10, y: 0)
    })
    let rotations = reversal.prefix(3).map(\.rotation)
    #expect(abs(rotations[0] - .pi / 4) < 0.000_01)
    #expect(abs(rotations[1] - .pi / 2) < 0.000_01)
    #expect(abs(rotations[2] - 3 * .pi / 4) < 0.000_01)
    #expect(reversal.prefix(3).map(\.ordinal) == [
        startingOrdinal,
        startingOrdinal + 1,
        startingOrdinal + 2,
    ])

    var random = BrushRandom(seed: seed)
    for _ in 0..<startingOrdinal { _ = random.nextValues() }
    #expect(
        reversal[0].randomValues.compatibility == random.nextValues()
    )
    #expect(
        reversal[1].randomValues.compatibility == random.nextValues()
    )
    #expect(
        reversal[2].randomValues.compatibility == random.nextValues()
    )
}

@Test
func cancelClearsHeldBeginDirectionAndCornerStateForRapidNextStroke()
    throws
{
    var cancelled = try stageCGenerator(
        id: "test.generator.cancel-direction",
        usesTravelDirection: true,
        maximumAngularStep: .pi / 8,
        stationaryDirection: -.pi / 4,
        seed: 0x79
    )
    cancelled.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { _ in }
    cancelled.append(
        generatorSample(x: 8, timestamp: 1, phase: .moved)
    ) { _ in }
    cancelled.append(
        generatorSample(x: 8, y: 8, timestamp: 2, phase: .moved)
    ) { _ in }
    cancelled.cancel()

    var fresh = try stageCGenerator(
        id: "test.generator.cancel-direction",
        usesTravelDirection: true,
        maximumAngularStep: .pi / 8,
        stationaryDirection: -.pi / 4,
        seed: 0x79
    )
    let nextBegin = generatorSample(
        x: 30, y: 40, timestamp: 3, phase: .began
    )
    let nextEnd = generatorSample(
        x: 30, y: 40, timestamp: 4, phase: .ended
    )
    var actual: [DabAttributes] = []
    var expected: [DabAttributes] = []
    cancelled.begin(nextBegin) { actual.append($0) }
    cancelled.finish(nextEnd) { actual.append($0) }
    fresh.begin(nextBegin) { expected.append($0) }
    fresh.finish(nextEnd) { expected.append($0) }

    #expect(actual == expected)
    #expect(cancelled == fresh)
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
        program: nativeTestProgram(recipe),
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
        program: nativeTestProgram(recipe),
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
            program: nativeTestProgram(recipe),
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
    let program = nativeTestProgram(recipe)
    var generator = BrushStrokeGenerator(
        program: program,
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
        BrushDynamicsEngine().applyingLegacySchemaV1EndTaper(
            $0,
            totalDistance: 12,
            nominalDiameter: 20,
            program: program
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
    let program = nativeTestProgram(recipe)
    var generator = BrushStrokeGenerator(
        program: program,
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
    let tapered = BrushDynamicsEngine().applyingLegacySchemaV1EndTaper(
        click,
        totalDistance: 0,
        nominalDiameter: 20,
        program: program
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
func generatedLogicalDabStoresConsumedNativeRandomValues() throws {
    var generator = legacyGenerator(seed: 81)
    let batch = try generator.beginBatch(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    )
    var random = BrushRandom(seed: 81)
    let expected = random.nextValues()
    let expectedExtension = [
        BrushProgramRandomChannel.size,
        .flow,
        .opacity,
        .hardness,
        .offsetX,
        .offsetY,
        .hue,
        .saturation,
        .brightness,
        .secondaryColorMix,
    ].map {
        BrushRandom.extensionUnitFloat(
            strokeSeed: 81,
            logicalDabOrdinal: 0,
            outputChannel: $0
        )
    }

    #expect(batch.dabs.first?.randomValues.compatibility == expected)
    #expect(batch.dabs.first?.randomValues.extensionValues == expectedExtension)
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
    let program = nativeTestProgram(recipe)
    var generator = BrushStrokeGenerator(
        program: program,
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
    let tapered = BrushDynamicsEngine().applyingLegacySchemaV1EndTaper(
        original,
        totalDistance: 12,
        nominalDiameter: 20,
        program: program
    )

    #expect(tapered.materialInputs == original.materialInputs)
    #expect(tapered.randomValues == original.randomValues)
    #expect(tapered.primaryGrainToWorld == original.primaryGrainToWorld)
    #expect(tapered.secondaryGrainToWorld == original.secondaryGrainToWorld)
    #expect(tapered.worldBounds != original.worldBounds)
}

@Test
func truncatedPredictionFinishDoesNotAdvanceOrSynthesizeEndpoint() throws {
    var generator = legacyGenerator(seed: 93)
    generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { _ in }
    let before = generator
    let terminal = generatorSample(
        x: 10_000,
        timestamp: 1,
        phase: .ended
    ).replacingKindForTest(.predicted)
    var emitted: [DabAttributes] = []

    let outcome = try generator.finishPredictionPrefix(
        terminal,
        maximumPathSubdivisionCount: 16
    ) { emitted.append($0) }

    #expect(outcome == .truncated)
    #expect(!emitted.isEmpty)
    #expect(emitted.last?.position != terminal.position)
    #expect(generator == before)
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
