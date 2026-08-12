import Foundation
@testable import PatternEngine
import Testing

private let compositeGeneratorViewport = ViewportTransform(
    drawableSize: PatternSize(width: 2, height: 2),
    worldCenter: WorldPoint(x: 0, y: 0)
)

private func compositeGeneratorSample(
    x: Float,
    timestamp: TimeInterval,
    phase: StrokePhase,
    kind: StrokeSampleKind = .actual
) -> WorldStrokeSample {
    let sample = StrokeSample(
        position: ScreenPoint(x: x + 1, y: 1),
        pressure: 0.5,
        timestamp: timestamp,
        phase: phase,
        source: .mouse,
        kind: kind,
        capabilities: []
    )
    var input = BrushInputDeriver()
    return input.derive(sample, viewport: compositeGeneratorViewport)
}

func independentCompositeProgram(
    id: String,
    replayMode: BrushReplayMode = .appendOnly,
    replayLimits: BrushReplayLimits? = nil
) throws -> BrushProgram {
    let base = nativeTestDefinition(
        id: BrushRecipeID(id),
        replayMode: replayMode,
        replayLimits: replayLimits
    )
    let primary = base.components[0]
    var secondaryOutputs = primary.sensorProgram.outputs
    secondaryOutputs[.size] = BrushOutputProgramDefinition(
        baseValue: 0.5,
        terms: []
    )
    secondaryOutputs[.flow] = BrushOutputProgramDefinition(
        baseValue: 0.5,
        terms: []
    )
    secondaryOutputs[.rotation] = BrushOutputProgramDefinition(
        baseValue: .pi / 4,
        terms: []
    )
    let secondaryPlacement = BrushPlacementDefinition(
        baseSpacingFraction: 0.25,
        maximumSpacingFraction: 0.5,
        baseFlow: 0.5,
        strokeOpacity: primary.placement.strokeOpacity,
        baseScatterFraction: 0,
        baseRotation: 0,
        baseJitterFraction: 0,
        baseOffset: .zero
    )
    let definition = try nativeCompositeTestDefinition(
        from: base,
        components: [
            nativeTestComponent(
                from: base,
                identifier: "primary",
                ordinal: 0
            ),
            nativeTestComponent(
                from: base,
                identifier: "texture",
                ordinal: 1,
                placement: secondaryPlacement,
                sensorProgram: BrushSensorProgramDefinition(
                    outputs: secondaryOutputs
                ),
                emission: BrushEmissionDefinition(
                    mode: .time,
                    timeInterval: 0.25
                )
            ),
        ]
    )
    return try BrushProgramCompiler.compile(definition)
}

private func independentCompositeGenerator(
    seed: UInt64 = 0xC1_18_02
) throws -> BrushStrokeGenerator {
    BrushStrokeGenerator(
        program: try independentCompositeProgram(
            id: "test.composite-generator.independent"
        ),
        nominalDiameter: 20,
        color: .black,
        seed: seed
    )
}

@Test func compositeGeneratorEmitsOrderedIndependentBeginDabs() throws {
    let base = nativeTestDefinition(
        id: BrushRecipeID("test.composite-generator.ordered-begin")
    )
    let definition = try nativeCompositeTestDefinition(
        from: base,
        components: [
            nativeTestComponent(
                from: base,
                identifier: "primary",
                ordinal: 0
            ),
            nativeTestComponent(
                from: base,
                identifier: "texture",
                ordinal: 1
            ),
        ]
    )
    let seed: UInt64 = 0xC1_18_01
    var generator = BrushStrokeGenerator(
        program: try BrushProgramCompiler.compile(definition),
        nominalDiameter: 20,
        color: .black,
        seed: seed
    )

    let dabs = try generator.currentSampleDabs(
        compositeGeneratorSample(x: 0, timestamp: 0, phase: .began)
    )

    #expect(dabs.count == 2)
    #expect(dabs.map(\.ordinal) == [0, 1])
    #expect(dabs.map(\.componentOrdinal) == [0, 1])
    #expect(dabs.map(\.componentDabOrdinal) == [0, 0])
    if dabs.count == 2 {
        #expect(dabs[0].randomValues != dabs[1].randomValues)
    }
    #expect(generator.emittedDabCount == 2)
}

@Test func componentRandomNamespacesAreCollectionOrderIndependent() throws {
    let seed: UInt64 = 0xC1_18_07
    var generator = try independentCompositeGenerator(seed: seed)
    let dabs = try generator.currentSampleDabs(
        compositeGeneratorSample(x: 0, timestamp: 0, phase: .began)
    )
    let primary = try #require(dabs.first {
        $0.componentOrdinal == 0
    })
    let secondary = try #require(dabs.first {
        $0.componentOrdinal == 1
    })
    let primarySeed = BrushComponentRandomNamespace.seed(
        strokeSeed: seed,
        componentOrdinal: 0
    )
    let secondarySeed = BrushComponentRandomNamespace.seed(
        strokeSeed: seed,
        componentOrdinal: 1
    )
    var primaryFirst = BrushRandom(seed: primarySeed)
    var secondarySecond = BrushRandom(seed: secondarySeed)
    let forward: [UInt8: BrushRandomValues] = [
        0: primaryFirst.nextValues(),
        1: secondarySecond.nextValues(),
    ]
    var secondaryFirst = BrushRandom(seed: secondarySeed)
    var primarySecond = BrushRandom(seed: primarySeed)
    let reversed: [UInt8: BrushRandomValues] = [
        1: secondaryFirst.nextValues(),
        0: primarySecond.nextValues(),
    ]
    var intentionallyShared = BrushRandom(seed: seed)
    _ = intentionallyShared.nextValues()
    let wrongSecondary = intentionallyShared.nextValues()

    #expect(forward == reversed)
    #expect(primary.randomValues.compatibility == forward[0])
    #expect(secondary.randomValues.compatibility == forward[1])
    #expect(secondary.randomValues.compatibility != wrongSecondary)
}

@Test func componentZeroTraceIsUnchangedByAddingASecondaryComponent() throws {
    let base = nativeTestDefinition(
        id: BrushRecipeID("test.composite-generator.primary-compatibility")
    )
    let primary = nativeTestComponent(
        from: base,
        identifier: "primary",
        ordinal: 0
    )
    let composite = try nativeCompositeTestDefinition(
        from: base,
        components: [
            primary,
            nativeTestComponent(
                from: base,
                identifier: "texture",
                ordinal: 1
            ),
        ]
    )
    let seed: UInt64 = 0xC1_18_03
    var singleGenerator = BrushStrokeGenerator(
        program: nativeTestProgram(base),
        nominalDiameter: 20,
        color: .black,
        seed: seed
    )
    var compositeGenerator = BrushStrokeGenerator(
        program: try BrushProgramCompiler.compile(composite),
        nominalDiameter: 20,
        color: .black,
        seed: seed
    )
    let sample = compositeGeneratorSample(
        x: 0,
        timestamp: 0,
        phase: .began
    )

    let single = try singleGenerator.currentSampleDabs(sample)
    let combined = try compositeGenerator.currentSampleDabs(sample)

    #expect(combined.first == single.first)
    #expect(combined.first?.randomValues == single.first?.randomValues)
}

@Test func compositeComponentsUseIndependentCadenceAndDynamics() throws {
    var generator = try independentCompositeGenerator()
    var trace: [LogicalDab] = []
    generator.consumeCurrentSample(
        compositeGeneratorSample(x: 0, timestamp: 0, phase: .began)
    ) { trace.append($0) }
    generator.consumeCurrentSample(
        compositeGeneratorSample(x: 5, timestamp: 1, phase: .ended)
    ) { trace.append($0) }

    #expect(trace.map(\.ordinal) == Array(0..<UInt64(trace.count)))
    #expect(trace.map(\.componentOrdinal) == [0, 1, 0, 0, 1, 1, 1, 1])
    #expect(trace.map(\.componentDabOrdinal) == [0, 0, 1, 2, 1, 2, 3, 4])
    let primary = trace.filter { $0.componentOrdinal == 0 }
    let secondary = trace.filter { $0.componentOrdinal == 1 }
    #expect(primary.count == 3)
    #expect(secondary.count == 5)
    #expect(primary.allSatisfy { $0.diameter == 20 && $0.flow == 1 })
    #expect(secondary.allSatisfy {
        $0.diameter == 10 && $0.flow == 0.25 && $0.rotation == .pi / 4
    })
    #expect(generator.emittedDabCount == 0)
}

@Test func compositeCursorResumesExactlyAcrossEveryAcceptedBoundary() throws {
    var generator = try independentCompositeGenerator(seed: 0xC1_18_04)
    _ = try generator.currentSampleDabs(
        compositeGeneratorSample(x: 0, timestamp: 0, phase: .began)
    )
    let startingCursor = try generator.emissionCursor(
        for: compositeGeneratorSample(x: 5, timestamp: 1, phase: .ended),
        maximumPathSubdivisionCount: 4_096
    )
    var baseline = startingCursor
    var expected: [LogicalDab] = []
    while !baseline.isComplete {
        _ = try baseline.emitNextPage { expected.append($0) }
    }
    let expectedGenerator = try #require(baseline.completedGenerator)

    for cut in 0...expected.count {
        var cursor = startingCursor
        var actual: [LogicalDab] = []
        if cut < expected.count {
            let page = try cursor.emitNextPageDeciding { dab in
                guard actual.count < cut else { return .pause }
                actual.append(dab)
                return .accept
            }
            #expect(page.hasMore)
            #expect(page.emittedCount == cut)
        }
        while !cursor.isComplete {
            _ = try cursor.emitNextPage { actual.append($0) }
        }

        #expect(actual == expected)
        #expect(cursor.completedGenerator == expectedGenerator)
    }
}

@Test func compositeCursorBoundsEveryStepAndAcceptedDabPerPage() throws {
    let generator = try independentCompositeGenerator(seed: 0xC1_18_08)
    let startingCursor = try generator.emissionCursor(
        for: compositeGeneratorSample(x: 0, timestamp: 0, phase: .began),
        maximumPathSubdivisionCount: 4_096
    )

    var baseline = startingCursor
    var expected: [LogicalDab] = []
    while !baseline.isComplete {
        _ = try baseline.emitNextPage { expected.append($0) }
    }

    var paged = startingCursor
    var actual: [LogicalDab] = []
    var pages: [BrushStrokeGenerator.EmissionPage] = []
    while !paged.isComplete {
        pages.append(try paged.emitNextPageDeciding(
            maximumWorkCount: 2
        ) { dab in
            actual.append(dab)
            return .accept
        })
    }

    #expect(actual == expected)
    #expect(paged.completedGenerator == baseline.completedGenerator)
    #expect(pages.allSatisfy { $0.workCount <= 2 })
    #expect(pages.allSatisfy { $0.emittedCount <= 1 })
    #expect(pages.contains { $0.workCount > 0 && $0.emittedCount == 0 })
}

@Test func compositePredictionCopiesBothEnginesWithoutAdvancingActualState()
    throws
{
    var authoritative = try independentCompositeGenerator(seed: 0xC1_18_05)
    _ = try authoritative.currentSampleDabs(
        compositeGeneratorSample(x: 0, timestamp: 0, phase: .began)
    )
    let beforePrediction = authoritative
    var prediction = authoritative
    let predicted = try prediction.currentSampleDabs(
        compositeGeneratorSample(
            x: 5,
            timestamp: 1,
            phase: .moved,
            kind: .predicted
        )
    )

    #expect(Set(predicted.map(\.componentOrdinal)) == [0, 1])
    #expect(predicted.allSatisfy { $0.isPredicted })
    #expect(authoritative == beforePrediction)

    var actual = authoritative
    let actualTrace = try actual.currentSampleDabs(
        compositeGeneratorSample(x: 5, timestamp: 1, phase: .moved)
    )
    #expect(actualTrace.allSatisfy { !$0.isPredicted })
    #expect(actualTrace.map(\.componentOrdinal) == predicted.map(\.componentOrdinal))
    #expect(actualTrace.map(\.componentDabOrdinal)
        == predicted.map(\.componentDabOrdinal))
}

@Test func compositeCancelResetsBothComponentEnginesAtomically() throws {
    let fresh = try independentCompositeGenerator(seed: 0xC1_18_06)
    var active = fresh
    _ = try active.currentSampleDabs(
        compositeGeneratorSample(x: 0, timestamp: 0, phase: .began)
    )
    #expect(active.emittedDabCount == 2)

    active.cancel()

    #expect(active == fresh)
    #expect(active.emittedDabCount == 0)
}

@Test func compositeEndedResetsBothEnginesToFreshState() throws {
    let fresh = try independentCompositeGenerator(seed: 0xC1_18_0A)
    var completed = fresh
    _ = try completed.currentSampleDabs(
        compositeGeneratorSample(x: 0, timestamp: 0, phase: .began)
    )
    _ = try completed.currentSampleDabs(
        compositeGeneratorSample(x: 5, timestamp: 1, phase: .ended)
    )

    #expect(completed == fresh)
    #expect(completed.emittedDabCount == 0)
}
