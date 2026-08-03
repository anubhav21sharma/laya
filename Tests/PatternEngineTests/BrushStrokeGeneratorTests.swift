import Foundation
@testable import PatternEngine
import simd
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
    maximumSpacingFraction: Float? = nil,
    coverage: BrushCoverageDefinition? = nil,
    outputOverrides: [
        BrushDynamicOutput: BrushOutputProgramDefinition
    ] = [:],
    tipSupports: [BrushTipSupportDefinition] = [.analyticEllipse],
    emission: BrushEmissionDefinition = BrushEmissionDefinition(
        mode: .distance,
        timeInterval: nil
    ),
    nominalDiameter: Float = 20,
    seed: UInt64 = 1
) throws -> BrushStrokeGenerator {
    BrushStrokeGenerator(
        program: try stageCTestProgram(
            id: id,
            stabilization: stabilization,
            usesTravelDirection: usesTravelDirection,
            maximumAngularStep: maximumAngularStep,
            stationaryDirection: stationaryDirection,
            baseSpacingFraction: baseSpacingFraction,
            maximumSpacingFraction: maximumSpacingFraction,
            coverage: coverage,
            outputOverrides: outputOverrides,
            tipSupports: tipSupports,
            emission: emission
        ),
        nominalDiameter: nominalDiameter,
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
        "timedEmitter",
        "authoritativeEmissionMerger",
        "predictionEmissionMerger",
        "strokeStartTimestamp",
        "processedPathDistance",
        "distanceUntilNext",
        "lastDirection",
        "lastEmittedSourcePosition",
        "footprintEnvelope",
    ]))
}

@Test
func emissionCursorInventoryCoversEveryContinuationOwner() throws {
    let generator = try stageCGenerator(id: "test.generator.cursor-inventory")
    let cursor = try generator.emissionCursor(
        for: generatorSample(x: 0, timestamp: 0, phase: .began),
        maximumPathSubdivisionCount: 4_096
    )
    let fieldNames = Set(
        Mirror(reflecting: cursor).children.compactMap(\.label)
    )

    #expect(fieldNames == Set([
        "generator",
        "sample",
        "operation",
        "maximumPathSubdivisionCount",
        "phase",
        "attributed",
        "pathCursor",
        "pendingPathContinuation",
        "pendingSegment",
        "pendingDirection",
        "pendingSignedTurn",
        "segmentCursor",
        "sourceCursor",
        "sourcePurpose",
    ]))
}

@Test
func logicalIdentityOverflowIsPreflightedBeforeCandidateAcceptance() {
    #expect(throws: BrushStrokeGeneratorEmissionError.logicalOrdinalOverflow) {
        try BrushStrokeGenerator.preflightLogicalIdentity(
            emittedDabCount: .max
        )
    }
    #expect(throws: Never.self) {
        try BrushStrokeGenerator.preflightLogicalIdentity(
            emittedDabCount: .max - 1
        )
    }
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
func schemaV2UnionCollapsesExactTimedDistanceTiesBeforeIdentity() throws {
    let interval = 0.25
    let emission = BrushEmissionDefinition(
        mode: .distanceAndTime,
        timeInterval: interval
    )
    var union = try stageCGenerator(
        id: "test.generator.emission.union-ties",
        baseSpacingFraction: 0.125,
        maximumSpacingFraction: 0.5,
        emission: emission,
        seed: 0xC1_11_01
    )
    var distanceOnly = try stageCGenerator(
        id: "test.generator.emission.distance-ties",
        baseSpacingFraction: 0.125,
        maximumSpacingFraction: 0.5,
        seed: 0xC1_11_01
    )
    let began = generatorSample(x: 0, timestamp: 0, phase: .began)
    let ended = generatorSample(x: 20, timestamp: 2, phase: .ended)
    var unionTrace: [DabAttributes] = []
    var distanceTrace: [DabAttributes] = []

    union.begin(began) { unionTrace.append($0) }
    union.finish(ended) { unionTrace.append($0) }
    distanceOnly.begin(began) { distanceTrace.append($0) }
    distanceOnly.finish(ended) { distanceTrace.append($0) }

    #expect(unionTrace == distanceTrace)
    #expect(unionTrace.map(\.ordinal) == Array(0..<UInt64(unionTrace.count)))
    var expectedRandom = BrushRandom(seed: 0xC1_11_01)
    #expect(unionTrace.map(\.randomValues.compatibility) == unionTrace.map {
        _ in expectedRandom.nextValues()
    })
    #expect(zip(unionTrace, unionTrace.dropFirst()).allSatisfy {
        $0.position != $1.position
    })
}

@Test
func schemaV2TimeModeEmitsStationaryRecordedTicksAndOneFinish() throws {
    var generator = try stageCGenerator(
        id: "test.generator.emission.stationary-time",
        emission: BrushEmissionDefinition(
            mode: .time,
            timeInterval: 0.25
        ),
        seed: 0xC1_11_02
    )
    var trace: [DabAttributes] = []
    generator.begin(
        generatorSample(x: 7, y: 9, timestamp: 10, phase: .began)
    ) { trace.append($0) }
    generator.finish(
        generatorSample(x: 7, y: 9, timestamp: 11, phase: .ended)
    ) { trace.append($0) }

    #expect(trace.count == 5)
    #expect(trace.allSatisfy { $0.position == WorldPoint(x: 7, y: 9) })
    #expect(trace.map(\.ordinal) == [0, 1, 2, 3, 4])
}

@Test
func schemaV2UnionKeepsCornerOrientationsAsDistinctAcceptedIdentities()
    throws
{
    var generator = try stageCGenerator(
        id: "test.generator.emission.union-corners",
        usesTravelDirection: true,
        maximumAngularStep: .pi / 8,
        baseSpacingFraction: 0.25,
        maximumSpacingFraction: 0.5,
        emission: BrushEmissionDefinition(
            mode: .distanceAndTime,
            timeInterval: 0.5
        ),
        seed: 0xC1_11_03
    )
    var trace: [DabAttributes] = []
    generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { trace.append($0) }
    generator.append(
        generatorSample(x: 10, timestamp: 1, phase: .moved)
    ) { trace.append($0) }
    generator.finish(
        generatorSample(x: 10, y: 10, timestamp: 2, phase: .ended)
    ) { trace.append($0) }

    let grouped = Dictionary(grouping: trace, by: \.sourceDistance)
    let cornerFan = try #require(grouped.values.first(where: { dabs in
        Set(dabs.map(\.rotation)).count >= 2
    }))
    #expect(cornerFan.count >= 2)
    #expect(Set(cornerFan.map(\.ordinal)).count == cornerFan.count)
    #expect(trace.map(\.ordinal) == Array(0..<UInt64(trace.count)))
}

@Test
func schemaV2TimedUnionIsInvariantToAuthoritativeInputPartitions() throws {
    let emission = BrushEmissionDefinition(
        mode: .distanceAndTime,
        timeInterval: 0.125
    )
    func trace(partitioned: Bool) throws -> [DabAttributes] {
        var generator = try stageCGenerator(
            id: "test.generator.emission.partition",
            baseSpacingFraction: 0.125,
            maximumSpacingFraction: 0.5,
            emission: emission,
            seed: 0xC1_11_04
        )
        var result: [DabAttributes] = []
        generator.begin(
            generatorSample(x: 0, timestamp: 0, phase: .began)
        ) { result.append($0) }
        if partitioned {
            for index in 1..<8 {
                generator.append(
                    generatorSample(
                        x: Float(index) * 2.5,
                        timestamp: Double(index) * 0.125,
                        phase: .moved
                    )
                ) { result.append($0) }
            }
        }
        generator.finish(
            generatorSample(x: 20, timestamp: 1, phase: .ended)
        ) { result.append($0) }
        return result
    }

    #expect(try trace(partitioned: false) == trace(partitioned: true))
}

@Test
func schemaV2TimedUnionBatchStreamingAndSinkRetryAreExact() throws {
    let program = try stageCTestProgram(
        id: "test.generator.emission.batch-retry",
        baseSpacingFraction: 0.125,
        maximumSpacingFraction: 0.5,
        emission: BrushEmissionDefinition(
            mode: .distanceAndTime,
            timeInterval: 0.125
        )
    )
    let began = generatorSample(x: 0, timestamp: 0, phase: .began)
    let ended = generatorSample(x: 20, timestamp: 1, phase: .ended)
    var streaming = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 20,
        color: .black,
        seed: 0xC1_11_05
    )
    var batched = streaming
    var streamed: [DabAttributes] = []
    streaming.begin(began) { streamed.append($0) }
    streaming.finish(ended) { streamed.append($0) }
    let batchTrace = try batched.beginBatch(began).dabs
        + batched.finishBatch(ended).dabs
    #expect(batchTrace == streamed)
    #expect(batched == streaming)

    enum Rejected: Error { case once }
    var retrying = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 20,
        color: .black,
        seed: 0xC1_11_05
    )
    retrying.begin(began) { _ in }
    let before = retrying
    var observed = 0
    #expect(throws: Rejected.once) {
        try retrying.finish(ended) { _ in
            observed += 1
            if observed == 3 { throw Rejected.once }
        }
    }
    #expect(retrying == before)
    var retried: [DabAttributes] = []
    var baseline = before
    let collectRetried: (DabAttributes) throws -> Void = {
        retried.append($0)
    }
    try retrying.finish(ended, emit: collectRetried)
    var expected: [DabAttributes] = []
    let collectExpected: (DabAttributes) throws -> Void = {
        expected.append($0)
    }
    try baseline.finish(ended, emit: collectExpected)
    #expect(retried == expected)
    #expect(retrying == baseline)
}

@Test
func schemaV2TimedCancelAndPredictionLeaveRapidReuseAuthoritative() throws {
    let program = try stageCTestProgram(
        id: "test.generator.emission.lifecycle",
        emission: BrushEmissionDefinition(mode: .time, timeInterval: 0.1)
    )
    func generator() -> BrushStrokeGenerator {
        BrushStrokeGenerator(
            program: program,
            nominalDiameter: 20,
            color: .black,
            seed: 0xC1_11_06
        )
    }
    let began = generatorSample(x: 0, timestamp: 0, phase: .began)
    var authoritative = generator()
    authoritative.begin(began) { _ in }
    let beforePrediction = authoritative
    var prediction = authoritative
    var predicted: [DabAttributes] = []
    _ = try prediction.appendPredictionPrefix(
        generatorSample(x: 5, timestamp: 0.5, phase: .moved)
            .replacingKindForTest(.predicted),
        maximumPathSubdivisionCount: 4_096
    ) { predicted.append($0) }
    #expect(!predicted.isEmpty)
    #expect(authoritative == beforePrediction)

    authoritative.cancel()
    var fresh = generator()
    let nextBegin = generatorSample(x: 2, timestamp: 4, phase: .began)
    let nextEnd = generatorSample(x: 2, timestamp: 4.3, phase: .ended)
    var actual: [DabAttributes] = []
    var expected: [DabAttributes] = []
    authoritative.begin(nextBegin) { actual.append($0) }
    authoritative.finish(nextEnd) { actual.append($0) }
    fresh.begin(nextBegin) { expected.append($0) }
    fresh.finish(nextEnd) { expected.append($0) }
    #expect(actual == expected)
    #expect(authoritative == fresh)
}

@Test(arguments: [511, 512, 513])
func schemaV2GeneratorAdvancePagesAtTheLogicalDabBoundary(
    candidateCount: Int
) throws {
    var generator = try stageCGenerator(
        id: "test.generator.emission.page-\(candidateCount)",
        emission: BrushEmissionDefinition(
            mode: .time,
            timeInterval: 1.0 / 240
        ),
        seed: 0xC1_11_10
    )
    generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { _ in }
    var cursor = try generator.emissionCursor(
        for: generatorSample(
            x: 0,
            timestamp: Double(candidateCount) / 240,
            phase: .ended
        ),
        maximumPathSubdivisionCount: 4_096
    )
    var ordinals: [UInt64] = []

    let first = try cursor.emitNextPage { ordinals.append($0.ordinal) }
    #expect(first.emittedCount == min(candidateCount, 512))
    #expect(first.hasMore == (candidateCount > 512))
    if first.hasMore {
        let second = try cursor.emitNextPage { ordinals.append($0.ordinal) }
        #expect(second.emittedCount == candidateCount - 512)
        #expect(!second.hasMore)
    }

    #expect(ordinals == Array(1...UInt64(candidateCount)))
    let completed = try #require(cursor.completedGenerator)
    #expect(completed.emittedDabCount == 0)
}

@Test
func schemaV2HugeTimedGapDoesOnlyOneBoundedGeneratorPage() throws {
    var generator = try stageCGenerator(
        id: "test.generator.emission.huge-page",
        emission: BrushEmissionDefinition(
            mode: .time,
            timeInterval: 1.0 / 240
        ),
        seed: 0xC1_11_11
    )
    generator.begin(
        generatorSample(x: 3, timestamp: 0, phase: .began)
    ) { _ in }
    var cursor = try generator.emissionCursor(
        for: generatorSample(
            x: 3,
            timestamp: 1_000_000,
            phase: .ended
        ),
        maximumPathSubdivisionCount: 4_096
    )
    var count = 0
    let page = try cursor.emitNextPage { _ in count += 1 }

    #expect(page.emittedCount == LogicalDabBatch.maximumDabCount)
    #expect(page.hasMore)
    #expect(count == LogicalDabBatch.maximumDabCount)
    #expect(cursor.completedGenerator == nil)
}

@Test
func schemaV2GeneratorPageRetryResumesAtTheRejectedDab() throws {
    enum Rejected: Error { case once }
    var generator = try stageCGenerator(
        id: "test.generator.emission.page-retry",
        emission: BrushEmissionDefinition(mode: .time, timeInterval: 0.1),
        seed: 0xC1_11_12
    )
    generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { _ in }
    var cursor = try generator.emissionCursor(
        for: generatorSample(x: 0, timestamp: 1, phase: .ended),
        maximumPathSubdivisionCount: 4_096
    )
    var accepted: [UInt64] = []

    #expect(throws: Rejected.once) {
        _ = try cursor.emitNextPage { dab in
            if dab.ordinal == 4 { throw Rejected.once }
            accepted.append(dab.ordinal)
        }
    }
    #expect(accepted == [1, 2, 3])
    let retryStart = cursor
    var retry = retryStart
    var copied = retryStart
    var retried: [DabAttributes] = []
    var copiedDabs: [DabAttributes] = []
    _ = try retry.emitNextPage { retried.append($0) }
    _ = try copied.emitNextPage { copiedDabs.append($0) }

    #expect(retried == copiedDabs)
    #expect(retried.first?.ordinal == 4)
    #expect(retry.completedGenerator == copied.completedGenerator)
}

@Test
func schemaV2GeneratorPausePreservesExactRejectedCandidateAndRealErrors()
    throws
{
    enum Rejected: Error { case once }
    var generator = try stageCGenerator(
        id: "test.generator.emission.page-pause",
        emission: BrushEmissionDefinition(mode: .time, timeInterval: 0.1),
        seed: 0xC1_11_15
    )
    generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { _ in }
    let startingCursor = try generator.emissionCursor(
        for: generatorSample(x: 0, timestamp: 1, phase: .ended),
        maximumPathSubdivisionCount: 4_096
    )

    var paused = startingCursor
    var acceptedBeforePause: [DabAttributes] = []
    var rejectedByPause: DabAttributes?
    let pausePage = try paused.emitNextPageDeciding { dab in
        if dab.ordinal == 4 {
            rejectedByPause = dab
            return .pause
        }
        acceptedBeforePause.append(dab)
        return .accept
    }
    #expect(pausePage == .init(emittedCount: 3, hasMore: true))
    #expect(acceptedBeforePause.map(\.ordinal) == [1, 2, 3])
    #expect(rejectedByPause?.ordinal == 4)

    var failed = startingCursor
    var acceptedBeforeError: [DabAttributes] = []
    var rejectedByError: DabAttributes?
    #expect(throws: Rejected.once) {
        _ = try failed.emitNextPageDeciding { dab in
            if dab.ordinal == 4 {
                rejectedByError = dab
                throw Rejected.once
            }
            acceptedBeforeError.append(dab)
            return .accept
        }
    }

    // Full cursor equality covers the merger's canonical candidate key and
    // every random/ordinal continuation owner, not only the visible dab.
    #expect(paused == failed)
    #expect(acceptedBeforePause == acceptedBeforeError)
    #expect(rejectedByPause == rejectedByError)

    var resumed: [DabAttributes] = []
    let resumedPage = try paused.emitNextPage { resumed.append($0) }
    var baseline = startingCursor
    var expected: [DabAttributes] = []
    let baselinePage = try baseline.emitNextPage { expected.append($0) }

    #expect(resumed.first == rejectedByPause)
    #expect(acceptedBeforePause + resumed == expected)
    #expect(
        pausePage.emittedCount + resumedPage.emittedCount
            == baselinePage.emittedCount
    )
    #expect(resumedPage.hasMore == baselinePage.hasMore)
    #expect(paused.completedGenerator == baseline.completedGenerator)
}

@Test
func schemaV2PagedGeneratorMatchesCompatibilityTraceAcrossLifecycleAndCorners()
    throws
{
    let program = try stageCTestProgram(
        id: "test.generator.emission.cursor-lifecycle",
        usesTravelDirection: true,
        maximumAngularStep: .pi / 8,
        baseSpacingFraction: 0.125,
        maximumSpacingFraction: 0.5,
        emission: BrushEmissionDefinition(
            mode: .distanceAndTime,
            timeInterval: 0.125
        )
    )
    let samples = [
        generatorSample(x: 0, timestamp: 0, phase: .began),
        generatorSample(x: 10, timestamp: 0.5, phase: .moved),
        generatorSample(x: 10, y: 10, timestamp: 1, phase: .moved),
        generatorSample(x: 20, y: 10, timestamp: 1.5, phase: .ended),
    ]
    var compatibility = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 20,
        color: .black,
        seed: 0xC1_11_13
    )
    var expected: [DabAttributes] = []
    compatibility.begin(samples[0]) { expected.append($0) }
    compatibility.append(samples[1]) { expected.append($0) }
    compatibility.append(samples[2]) { expected.append($0) }
    compatibility.finish(samples[3]) { expected.append($0) }

    var paged = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 20,
        color: .black,
        seed: 0xC1_11_13
    )
    var actual: [DabAttributes] = []
    for sample in samples {
        var cursor = try paged.emissionCursor(
            for: sample,
            maximumPathSubdivisionCount: 4_096
        )
        repeat {
            let page = try cursor.emitNextPage { actual.append($0) }
            #expect(page.emittedCount <= LogicalDabBatch.maximumDabCount)
        } while !cursor.isComplete
        paged = try #require(cursor.completedGenerator)
    }

    #expect(actual == expected)
    #expect(paged == compatibility)
}

@Test
func schemaV2PagedUnionSettlesTimedDistanceDuplicates() throws {
    let program = try stageCTestProgram(
        id: "test.generator.emission.cursor-union-duplicate",
        baseSpacingFraction: 0.1,
        maximumSpacingFraction: 0.5,
        emission: BrushEmissionDefinition(
            mode: .distanceAndTime,
            timeInterval: 0.05
        )
    )
    let samples = [
        generatorSample(x: 8, y: 8, timestamp: 0, phase: .began),
        generatorSample(x: 20, y: 8, timestamp: 0.1, phase: .moved),
        generatorSample(x: 20, y: 20, timestamp: 0.2, phase: .moved),
        generatorSample(x: 32, y: 20, timestamp: 0.3, phase: .moved),
        generatorSample(x: 32, y: 32, timestamp: 0.4, phase: .moved),
        generatorSample(x: 44, y: 32, timestamp: 0.5, phase: .moved),
        generatorSample(x: 44, y: 44, timestamp: 0.6, phase: .ended),
    ]
    var compatibility = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 12,
        color: .black,
        seed: 1
    )
    var expected: [DabAttributes] = []
    compatibility.begin(samples[0]) { expected.append($0) }
    for sample in samples.dropFirst().dropLast() {
        compatibility.append(sample) { expected.append($0) }
    }
    compatibility.finish(samples[samples.count - 1]) {
        expected.append($0)
    }

    var paged = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 12,
        color: .black,
        seed: 1
    )
    var actual: [DabAttributes] = []
    for sample in samples {
        var cursor = try paged.emissionCursor(
            for: sample,
            maximumPathSubdivisionCount: 4_096
        )
        let page = try cursor.emitNextPage { actual.append($0) }
        #expect(!page.hasMore)
        paged = try #require(cursor.completedGenerator)
    }

    #expect(actual == expected)
    #expect(paged == compatibility)
}

@Test
func schemaV2DistanceCursorResumesA513DabPathExactly() throws {
    var generator = try stageCGenerator(
        id: "test.generator.emission.distance-page",
        baseSpacingFraction: 0.001,
        maximumSpacingFraction: 0.5,
        seed: 0xC1_11_14
    )
    var beginCursor = try generator.emissionCursor(
        for: generatorSample(x: 0, timestamp: 0, phase: .began),
        maximumPathSubdivisionCount: 4_096
    )
    _ = try beginCursor.emitNextPage { _ in }
    generator = try #require(beginCursor.completedGenerator)
    var cursor = try generator.emissionCursor(
        for: generatorSample(x: 513, timestamp: 1, phase: .ended),
        maximumPathSubdivisionCount: 4_096
    )
    var ordinals: [UInt64] = []

    let first = try cursor.emitNextPage { ordinals.append($0.ordinal) }
    let second = try cursor.emitNextPage { ordinals.append($0.ordinal) }

    #expect(first == .init(emittedCount: 512, hasMore: true))
    #expect(second == .init(emittedCount: 1, hasMore: false))
    #expect(ordinals == Array(1...513))
    #expect(cursor.completedGenerator != nil)
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
    generator.begin(
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
    #expect(dabs.map(\.sourceDistance) == [0, 2.5, 5, 6])
    #expect(dabs.allSatisfy { $0.spacing == 2.5 })
    var expectedRandom = BrushRandom(seed: 1)
    #expect(dabs.map(\.randomValues.compatibility) == (0..<4).map { _ in
        expectedRandom.nextValues()
    })
}

@Test
func schemaV2UsesEvaluatedShapeSupportUnionForFollowingCarry() throws {
    let baseCoverage = nativeTestDefinition().coverage
    let baseShape = baseCoverage.shapes[0]
    let bounds = try BrushTipSupportDefinition.normalizedBounds(
        minX: -0.25,
        maxX: 0.75,
        minY: -0.5,
        maxY: 0.5
    )
    let cases: [(
        name: String,
        coverage: BrushCoverageDefinition,
        supports: [BrushTipSupportDefinition],
        outputs: [BrushDynamicOutput: BrushOutputProgramDefinition],
        expectedCarry: Float
    )] = [
        (
            "rotated chisel",
            footprintCoverage(
                base: baseCoverage,
                aspectRatio: 0.25,
                shapes: [baseShape]
            ),
            [.analyticRectangle],
            [.rotation: constantOutput(.pi / 2)],
            1.25
        ),
        (
            "asymmetric normalized texture bounds",
            footprintCoverage(
                base: baseCoverage,
                aspectRatio: 1,
                shapes: [BrushShapeLayerDefinition(
                    shape: baseShape.shape,
                    combination: .replace,
                    scale: 1,
                    rotation: 0,
                    offset: SIMD2(0.75, -0.5)
                )]
            ),
            [bounds],
            [:],
            2.5
        ),
        (
            "offset two-layer union",
            footprintCoverage(
                base: baseCoverage,
                aspectRatio: 1,
                shapes: [
                    baseShape,
                    BrushShapeLayerDefinition(
                        shape: baseShape.shape,
                        combination: .maximum,
                        scale: 0.5,
                        rotation: 0,
                        offset: SIMD2(2, 0)
                    ),
                ]
            ),
            [.analyticEllipse, .analyticEllipse],
            [:],
            8.75
        ),
    ]

    for fixture in cases {
        var generator = try stageCGenerator(
            id: "test.generator.footprint.\(fixture.name)",
            baseSpacingFraction: 0.25,
            maximumSpacingFraction: 0.5,
            coverage: fixture.coverage,
            outputOverrides: fixture.outputs,
            tipSupports: fixture.supports
        )
        let trace = try straightTrace(
            generator: &generator,
            length: 30,
            pressure: 0.5
        )

        #expect(trace.count >= 3, "\(fixture.name)")
        #expect(abs(trace[0].sourceDistance) < 0.000_01, "\(fixture.name)")
        #expect(
            abs(trace[0].spacing - fixture.expectedCarry) < 0.000_1,
            "\(fixture.name)"
        )
        #expect(
            abs(trace[1].sourceDistance - fixture.expectedCarry) < 0.000_1,
            "\(fixture.name)"
        )
    }
}

@Test
func schemaV2FootprintCarryIsTranslationInvariantAtLargeWorldCoordinates()
    throws
{
    let baseCoverage = nativeTestDefinition().coverage
    let baseShape = baseCoverage.shapes[0]
    let coverage = footprintCoverage(
        base: baseCoverage,
        aspectRatio: 1,
        shapes: [
            baseShape,
            BrushShapeLayerDefinition(
                shape: baseShape.shape,
                combination: .maximum,
                scale: 0.5,
                rotation: 0,
                offset: SIMD2(2, 0)
            ),
        ]
    )
    func firstDab(at x: Float, id: String) throws -> DabAttributes {
        var generator = try stageCGenerator(
            id: id,
            baseSpacingFraction: 0.25,
            maximumSpacingFraction: 0.5,
            coverage: coverage,
            tipSupports: [.analyticEllipse, .analyticEllipse]
        )
        var dabs: [DabAttributes] = []
        generator.begin(
            generatorSample(x: x, timestamp: 0, phase: .began)
        ) { dabs.append($0) }
        return try #require(dabs.first)
    }

    let origin = try firstDab(
        at: 0,
        id: "test.generator.footprint.translation-origin"
    )
    let translated = try firstDab(
        at: 1e10,
        id: "test.generator.footprint.translation-large"
    )

    #expect(abs(origin.spacing - 8.75) < 0.000_1)
    #expect(abs(translated.spacing - origin.spacing) < 0.000_1)
}

@Test
func schemaV2ProjectionModesChangeInstancesButNotLogicalTrace() throws {
    let baseCoverage = nativeTestDefinition().coverage
    let coverage = footprintCoverage(
        base: baseCoverage,
        aspectRatio: 0.3,
        shapes: baseCoverage.shapes
    )
    let inputs = [
        generatorSample(x: 128, y: 128, timestamp: 0, phase: .began),
        generatorSample(x: 176, y: 144, timestamp: 1, phase: .ended),
    ]
    func logicalTrace(id: String) throws -> [DabAttributes] {
        var generator = try stageCGenerator(
            id: id,
            usesTravelDirection: true,
            baseSpacingFraction: 0.25,
            maximumSpacingFraction: 0.5,
            coverage: coverage,
            tipSupports: [.analyticRectangle],
            seed: 0xC1_10
        )
        var dabs: [DabAttributes] = []
        generator.begin(inputs[0]) { dabs.append($0) }
        try generator.finish(
            inputs[1],
            maximumPathSubdivisionCount: 4_096
        ) { dabs.append($0) }
        return dabs
    }

    let plainTrace = try logicalTrace(id: "test.generator.projection.plain")
    let seamlessTrace = try logicalTrace(
        id: "test.generator.projection.seamless"
    )
    let radialTrace = try logicalTrace(id: "test.generator.projection.radial")
    #expect(plainTrace == seamlessTrace)
    #expect(plainTrace == radialTrace)

    let canvas = PixelSize(width: 256, height: 256)
    let strategies = [
        try TilingStrategy(
            finiteConfiguration: .plain,
            canvasSize: canvas
        ),
        TilingStrategy(
            kind: .grid,
            tileSize: PatternSize(width: 64, height: 64)
        ),
        try TilingStrategy(
            finiteConfiguration: .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 8,
                center: WorldPoint(x: 128, y: 128)
            )),
            canvasSize: canvas
        ),
    ]
    let bounds = AxisAlignedRect(
        minimum: SIMD2(-1, -1),
        maximum: SIMD2(1, 1)
    )
    let instanceCounts = strategies.map { strategy in
        plainTrace.reduce(into: 0) { count, dab in
            count += TilingProjection.fragments(
                for: StampFootprint(
                    brushToWorld: dab.brushToWorld,
                    localBounds: bounds,
                    coverageSymmetry: .oriented
                ),
                using: strategy
            ).count
        }
    }

    #expect(instanceCounts[0] > 0)
    #expect(instanceCounts[1] != instanceCounts[0])
    #expect(instanceCounts[2] != instanceCounts[0])
}

@Test
func schemaV2CurrentPostDynamicsFootprintChangesOnlyTheNextCandidate()
    throws
{
    let pressureSize = BrushOutputProgramDefinition(
        baseValue: 0.25,
        terms: [BrushResponseTermDefinition(
            input: .pressure,
            response: .linear,
            inputInverted: false,
            missingInputValue: 0,
            responseScale: 0.75,
            responseOffset: 0.25,
            responseLowerClamp: 0.25,
            responseUpperClamp: 1,
            jitter: 0,
            operation: .replace
        )]
    )
    var constant = try stageCGenerator(
        id: "test.generator.footprint.causal-constant",
        baseSpacingFraction: 0.25,
        maximumSpacingFraction: 0.5,
        outputOverrides: [.size: constantOutput(0.25)]
    )
    var dynamic = try stageCGenerator(
        id: "test.generator.footprint.causal-dynamic",
        baseSpacingFraction: 0.25,
        maximumSpacingFraction: 0.5,
        outputOverrides: [.size: pressureSize]
    )
    let began = generatorSample(
        x: 0,
        pressure: 0,
        timestamp: 0,
        phase: .began,
        capabilities: [.pressure]
    )
    let pressureChange = generatorSample(
        x: 0,
        pressure: 1,
        timestamp: 1,
        phase: .moved,
        capabilities: [.pressure]
    )
    let ended = generatorSample(
        x: 20,
        pressure: 1,
        timestamp: 2,
        phase: .ended,
        capabilities: [.pressure]
    )
    var constantTrace: [DabAttributes] = []
    var dynamicTrace: [DabAttributes] = []
    constant.begin(began) { constantTrace.append($0) }
    dynamic.begin(began) { dynamicTrace.append($0) }
    constant.append(pressureChange) { constantTrace.append($0) }
    dynamic.append(pressureChange) { dynamicTrace.append($0) }
    constant.finish(ended) { constantTrace.append($0) }
    dynamic.finish(ended) { dynamicTrace.append($0) }

    #expect(constantTrace.prefix(2).map(\.sourceDistance) == [0, 1.25])
    #expect(dynamicTrace.prefix(2).map(\.sourceDistance) == [0, 1.25])
    #expect(constantTrace[1].ordinal == dynamicTrace[1].ordinal)
    #expect(
        constantTrace[1].randomValues == dynamicTrace[1].randomValues
    )
    #expect(abs(constantTrace[2].sourceDistance - 2.5) < 0.000_1)
    #expect(abs(dynamicTrace[2].sourceDistance - 6.25) < 0.000_1)
}

@Test
func schemaV2FootprintEnvelopeRejectsBeforePublishingOrMutating() throws {
    let program = try stageCTestProgram(id: "test.generator.footprint.envelope")
    let limits = program.definition.limits
    let acceptedDiameter = limits.maximumDiameter
    var accepted = BrushStrokeGenerator(
        program: program,
        nominalDiameter: acceptedDiameter,
        color: .black,
        seed: 0xA1
    )
    let collectAccepted: (DabAttributes) throws -> Void = { _ in }
    try accepted.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began),
        emit: collectAccepted
    )

    let rejectedDiameter = acceptedDiameter.nextUp
    var outsideDiameter = BrushStrokeGenerator(
        program: program,
        nominalDiameter: rejectedDiameter,
        color: .black,
        seed: 0xA2
    )
    let beforeDiameterRejection = outsideDiameter
    var diameterSink: [DabAttributes] = []
    let collectDiameter: (DabAttributes) throws -> Void = {
        diameterSink.append($0)
    }
    #expect(throws: BrushStrokeGeneratorFootprintError
        .nominalDiameterOutsideCompiledLimits(
            actual: rejectedDiameter,
            minimum: limits.minimumDiameter,
            maximum: limits.maximumDiameter
        )) {
        try outsideDiameter.begin(
            generatorSample(x: 0, timestamp: 0, phase: .began),
            emit: collectDiameter
        )
    }
    #expect(diameterSink.isEmpty)
    #expect(outsideDiameter == beforeDiameterRejection)
    #expect(outsideDiameter.emittedDabCount == 0)

    var outsideWorld = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 20,
        color: .black,
        seed: 0xA3
    )
    let beforeWorldRejection = outsideWorld
    var worldSink: [DabAttributes] = []
    let collectWorld: (DabAttributes) throws -> Void = {
        worldSink.append($0)
    }
    let hugeWorld = generatorSample(
        x: 0,
        timestamp: 0,
        phase: .began
    ).replacing(position: WorldPoint(
        x: Float.greatestFiniteMagnitude / 2,
        y: 0
    ))
    #expect(throws: BrushStrokeGeneratorFootprintError
        .worldPositionOutsideFootprintEnvelope) {
        try outsideWorld.begin(hugeWorld, emit: collectWorld)
    }
    #expect(worldSink.isEmpty)
    #expect(outsideWorld == beforeWorldRejection)
    #expect(outsideWorld.emittedDabCount == 0)
}

@Test
func schemaV2UnsafeCompiledGeometryRejectsBeforeFirstCallback() throws {
    let baseCoverage = nativeTestDefinition().coverage
    let baseShape = baseCoverage.shapes[0]
    let unsafeCoverage = footprintCoverage(
        base: baseCoverage,
        aspectRatio: 1,
        shapes: [BrushShapeLayerDefinition(
            shape: baseShape.shape,
            combination: .replace,
            scale: 1,
            rotation: 0,
            offset: SIMD2(Float.greatestFiniteMagnitude / 2, 0)
        )]
    )
    var generator = try stageCGenerator(
        id: "test.generator.footprint.unsafe-geometry",
        coverage: unsafeCoverage,
        nominalDiameter: 20,
        seed: 0xA4
    )
    let before = generator
    var sink: [DabAttributes] = []
    let collect: (DabAttributes) throws -> Void = { sink.append($0) }

    #expect(throws: BrushStrokeGeneratorFootprintError
        .unsafeCompiledFootprintEnvelope) {
        try generator.begin(
            generatorSample(x: 0, timestamp: 0, phase: .began),
            emit: collect
        )
    }
    #expect(sink.isEmpty)
    #expect(generator == before)
    #expect(generator.emittedDabCount == 0)
}

@Test
func schemaV2CornerFootprintShortensOnlyTheUntraveledRemainder() throws {
    let baseCoverage = nativeTestDefinition().coverage
    let directionalButUnrotated = BrushOutputProgramDefinition(
        baseValue: 0,
        terms: [BrushResponseTermDefinition(
            input: .direction,
            response: .linear,
            inputInverted: false,
            missingInputValue: 0.5,
            responseScale: 0,
            responseOffset: 0,
            responseLowerClamp: 0,
            responseUpperClamp: 0,
            jitter: 0,
            operation: .replace
        )]
    )
    var generator = try stageCGenerator(
        id: "test.generator.footprint.corner-carry",
        maximumAngularStep: .pi / 8,
        baseSpacingFraction: 0.5,
        maximumSpacingFraction: 0.5,
        coverage: footprintCoverage(
            base: baseCoverage,
            aspectRatio: 0.05,
            shapes: baseCoverage.shapes
        ),
        outputOverrides: [.rotation: directionalButUnrotated],
        tipSupports: [.analyticRectangle],
        seed: 0xA5
    )
    var trace: [DabAttributes] = []
    generator.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { trace.append($0) }
    try generator.append(
        generatorSample(x: 12, timestamp: 1, phase: .moved),
        maximumPathSubdivisionCount: 4_096
    ) { trace.append($0) }
    let spacingBeforeTurn = generator.currentSpacing
    var turnDabs: [DabAttributes] = []
    try generator.append(
        generatorSample(x: 12, y: 3, timestamp: 2, phase: .moved),
        maximumPathSubdivisionCount: 4_096
    ) { turnDabs.append($0) }
    let finalCorner = try #require(turnDabs.last)
    #expect(turnDabs.count >= 2)
    #expect(turnDabs.allSatisfy {
        abs($0.sourceDistance - finalCorner.sourceDistance) < 0.000_1
    })
    #expect(finalCorner.spacing < spacingBeforeTurn)
    #expect(abs(generator.currentSpacing - finalCorner.spacing) < 0.000_1)

    let cornerTraceIndex = trace.count + turnDabs.count - 1
    trace.append(contentsOf: turnDabs)
    try generator.append(
        generatorSample(x: 12, y: 24, timestamp: 3, phase: .moved),
        maximumPathSubdivisionCount: 4_096
    ) { trace.append($0) }
    let next = try #require(trace.dropFirst(cornerTraceIndex + 1).first(where: {
        $0.sourceDistance > finalCorner.sourceDistance + 0.000_1
    }))
    let remaining = next.sourceDistance - finalCorner.sourceDistance

    #expect(remaining <= finalCorner.spacing + 0.000_1)
    #expect(trace.map(\.sourceDistance) == trace.map(\.sourceDistance).sorted())
    #expect(trace.map(\.ordinal) == Array(0..<UInt64(trace.count)))
}

@Test
func schemaV2RectangleCarryTracksTangentAndExactReversal() throws {
    let baseCoverage = nativeTestDefinition().coverage
    let coverage = footprintCoverage(
        base: baseCoverage,
        aspectRatio: 0.25,
        shapes: baseCoverage.shapes
    )
    func trace(
        id: String,
        end: WorldPoint
    ) throws -> [DabAttributes] {
        var generator = try stageCGenerator(
            id: id,
            baseSpacingFraction: 0.25,
            maximumSpacingFraction: 0.5,
            coverage: coverage,
            tipSupports: [.analyticRectangle]
        )
        var result: [DabAttributes] = []
        generator.begin(
            generatorSample(x: 0, timestamp: 0, phase: .began)
        ) { result.append($0) }
        try generator.finish(
            generatorSample(
                x: end.x,
                y: end.y,
                timestamp: 1,
                phase: .ended
            ),
            maximumPathSubdivisionCount: 4_096
        ) { result.append($0) }
        return result
    }

    let forward = try trace(
        id: "test.generator.footprint.forward",
        end: WorldPoint(x: 20, y: 0)
    )
    let vertical = try trace(
        id: "test.generator.footprint.vertical",
        end: WorldPoint(x: 0, y: 20)
    )
    let reversed = try trace(
        id: "test.generator.footprint.reversed",
        end: WorldPoint(x: -20, y: 0)
    )

    #expect(forward.prefix(3).map(\.sourceDistance) == [0, 5, 10])
    #expect(reversed.prefix(3).map(\.sourceDistance) == [0, 5, 10])
    #expect(abs(vertical[1].sourceDistance - 5) < 0.000_1)
    #expect(abs(vertical[1].spacing - 1.25) < 0.000_1)
    #expect(abs(vertical[2].sourceDistance - 6.25) < 0.000_1)
    #expect(forward.map(\.ordinal) == Array(0..<UInt64(forward.count)))
    #expect(reversed.map(\.ordinal) == Array(0..<UInt64(reversed.count)))
}

@Test
func schemaV2GeneratedTracesPassIndependentRasterGapAndDensityOracle()
    throws
{
    let baseCoverage = nativeTestDefinition().coverage
    let fixtures: [(
        name: String,
        support: BrushTipSupportDefinition,
        aspect: Float,
        rotation: Float,
        usesTravelDirection: Bool,
        end: WorldPoint
    )] = [
        (
            "ellipse", .analyticEllipse, 0.35, .pi / 7, false,
            WorldPoint(x: 32, y: 0)
        ),
        (
            "chisel tangent", .analyticRectangle, 0.2, 0, true,
            WorldPoint(x: 0, y: 32)
        ),
        (
            "textured bounds",
            try BrushTipSupportDefinition.normalizedBounds(
                minX: -0.7,
                maxX: 0.8,
                minY: -0.4,
                maxY: 0.6
            ),
            0.6,
            -.pi / 9,
            false,
            WorldPoint(x: 32, y: 0)
        ),
    ]

    for fixture in fixtures {
        var generator = try stageCGenerator(
            id: "test.generator.footprint.raster.\(fixture.name)",
            usesTravelDirection: fixture.usesTravelDirection,
            baseSpacingFraction: 0.3,
            maximumSpacingFraction: 0.4,
            coverage: footprintCoverage(
                base: baseCoverage,
                aspectRatio: fixture.aspect,
                shapes: baseCoverage.shapes
            ),
            outputOverrides: [
                .rotation: fixture.usesTravelDirection
                    ? directionalConstantOutput(fixture.rotation)
                    : constantOutput(fixture.rotation),
            ],
            tipSupports: [fixture.support]
        )
        var trace: [DabAttributes] = []
        generator.begin(
            generatorSample(x: 0, timestamp: 0, phase: .began)
        ) { trace.append($0) }
        try generator.finish(
            generatorSample(
                x: fixture.end.x,
                y: fixture.end.y,
                timestamp: 1,
                phase: .ended
            ),
            maximumPathSubdivisionCount: 4_096
        ) { trace.append($0) }

        let raster = independentTraceRasterMetrics(
            dabs: trace,
            support: fixture.support,
            from: WorldPoint(x: 0, y: 0),
            to: fixture.end,
            step: 0.05
        )
        #expect(raster.firstGap == nil, "\(fixture.name)")
        #expect(raster.maximumOverlap <= 8, "\(fixture.name)")
    }
}

@Test
func schemaV2FootprintSpacingHonorsSafetyFloorAndSupportRelativeCeiling()
    throws
{
    var tiny = try stageCGenerator(
        id: "test.generator.footprint.floor",
        baseSpacingFraction: 0.5,
        maximumSpacingFraction: 4,
        outputOverrides: [
            .size: constantOutput(1 / 1_024),
            .spacing: constantOutput(1 / 1_024),
        ]
    )
    let tinyTrace = try straightTrace(
        generator: &tiny,
        length: 4,
        pressure: 0.5
    )
    #expect(tinyTrace.first?.spacing == 1)

    var huge = try stageCGenerator(
        id: "test.generator.footprint.ceiling",
        baseSpacingFraction: 0.5,
        maximumSpacingFraction: 4,
        outputOverrides: [
            .size: constantOutput(8),
            .spacing: constantOutput(8),
        ]
    )
    let hugeTrace = try straightTrace(
        generator: &huge,
        length: 800,
        pressure: 0.5
    )
    #expect(hugeTrace.first?.spacing == 640)
    #expect(hugeTrace.dropFirst().first?.sourceDistance == 640)
}

@Test
func schemaV2MaximumCompatibilitySpacingJitterCannotInvalidateCarry()
    throws
{
    let program = try stageCTestProgram(
        id: "test.generator.footprint.maximum-spacing-jitter",
        randomization: BrushRandomization(
            spacing: 1,
            scatter: 0,
            rotation: 0,
            grain: 0,
            material: 0
        )
    )
    let sample = InterpolatedStrokeSample(generatorSample(
        x: 0,
        timestamp: 0,
        phase: .began
    ))
    let dab = BrushDynamicsEngine().evaluate(
        sample: sample,
        context: BrushStrokeContext(
            nominalDiameter: 20,
            color: .black,
            direction: 0,
            strokeAge: 0,
            traveledDistance: 0,
            totalDistance: nil,
            ordinal: 0,
            isPredicted: false
        ),
        program: program,
        random: BrushRandomValues(
            spacing: 0,
            scatterX: 0.5,
            scatterY: 0.5,
            rotation: 0.5,
            grainX: 0.5,
            grainY: 0.5,
            materialVariation: 0.5
        ),
        strokeSeed: 1
    )

    #expect(dab.spacing == 1)
}

@Test
func schemaV2FootprintPredictionIsAValueCopyAndActualRetryIsExact()
    throws
{
    let baseCoverage = nativeTestDefinition().coverage
    var authoritative = try stageCGenerator(
        id: "test.generator.footprint.prediction",
        usesTravelDirection: true,
        maximumAngularStep: .pi / 8,
        baseSpacingFraction: 0.3,
        maximumSpacingFraction: 0.5,
        coverage: footprintCoverage(
            base: baseCoverage,
            aspectRatio: 0.2,
            shapes: baseCoverage.shapes
        ),
        tipSupports: [.analyticRectangle],
        seed: 0xC1_11
    )
    authoritative.begin(
        generatorSample(x: 0, timestamp: 0, phase: .began)
    ) { _ in }
    try authoritative.append(
        generatorSample(x: 24, timestamp: 1, phase: .moved),
        maximumPathSubdivisionCount: 4_096
    ) { _ in }
    let beforePrediction = authoritative
    var prediction = authoritative
    var predicted: [DabAttributes] = []
    let outcome = try prediction.appendPredictionPrefix(
        generatorSample(
            x: 24,
            y: 24,
            timestamp: 2,
            phase: .moved
        ).replacingKindForTest(.predicted),
        maximumPathSubdivisionCount: 4_096
    ) { predicted.append($0) }
    #expect(outcome == .completed)
    #expect(!predicted.isEmpty)
    #expect(authoritative == beforePrediction)

    var baseline = beforePrediction
    let actual = generatorSample(
        x: 24,
        y: 24,
        timestamp: 2,
        phase: .moved
    )
    var afterPrediction: [DabAttributes] = []
    var expected: [DabAttributes] = []
    try authoritative.append(
        actual,
        maximumPathSubdivisionCount: 4_096
    ) { afterPrediction.append($0) }
    try baseline.append(
        actual,
        maximumPathSubdivisionCount: 4_096
    ) { expected.append($0) }

    #expect(afterPrediction == expected)
    #expect(authoritative == baseline)
}

@Test
func schemaV2FootprintBatchAndStreamingRoutesAreIdentical() throws {
    let baseCoverage = nativeTestDefinition().coverage
    let program = try stageCTestProgram(
        id: "test.generator.footprint.batch-parity",
        usesTravelDirection: true,
        maximumAngularStep: .pi / 8,
        baseSpacingFraction: 0.25,
        maximumSpacingFraction: 0.5,
        coverage: footprintCoverage(
            base: baseCoverage,
            aspectRatio: 0.25,
            shapes: baseCoverage.shapes
        ),
        tipSupports: [.analyticRectangle]
    )
    var streaming = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 20,
        color: .black,
        seed: 0xC1_12
    )
    var batched = streaming
    let began = generatorSample(x: 0, timestamp: 0, phase: .began)
    let moved = generatorSample(x: 24, timestamp: 1, phase: .moved)
    let ended = generatorSample(
        x: 24,
        y: 24,
        timestamp: 2,
        phase: .ended
    )
    var streamed: [DabAttributes] = []
    streaming.begin(began) { streamed.append($0) }
    streaming.append(moved) { streamed.append($0) }
    streaming.finish(ended) { streamed.append($0) }
    let batches = [
        try batched.beginBatch(began),
        try batched.appendBatch(moved),
        try batched.finishBatch(ended),
    ]

    #expect(batches.flatMap(\.dabs) == streamed)
    #expect(batched == streaming)
}

@Test
func schemaV2FootprintInputRejectionAfterBeginIsAtomicAndRetryable()
    throws
{
    let program = try stageCTestProgram(
        id: "test.generator.footprint.append-rejection"
    )
    var generator = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 20,
        color: .black,
        seed: 0xC1_13
    )
    let began = generatorSample(x: 0, timestamp: 0, phase: .began)
    let beginSink: (DabAttributes) throws -> Void = { _ in }
    try generator.begin(began, emit: beginSink)
    let beforeRejection = generator
    var rejected: [DabAttributes] = []
    let collectRejected: (DabAttributes) throws -> Void = {
        rejected.append($0)
    }
    let outside = generatorSample(
        x: 0,
        timestamp: 1,
        phase: .moved
    ).replacing(position: WorldPoint(
        x: Float.greatestFiniteMagnitude / 2,
        y: 0
    ))
    #expect(throws: BrushStrokeGeneratorFootprintError
        .worldPositionOutsideFootprintEnvelope) {
        try generator.append(outside, emit: collectRejected)
    }
    #expect(rejected.isEmpty)
    #expect(generator == beforeRejection)

    var baseline = beforeRejection
    let retry = generatorSample(x: 20, timestamp: 1, phase: .moved)
    var actual: [DabAttributes] = []
    var expected: [DabAttributes] = []
    let collectActual: (DabAttributes) throws -> Void = { actual.append($0) }
    let collectExpected: (DabAttributes) throws -> Void = {
        expected.append($0)
    }
    try generator.append(retry, emit: collectActual)
    try baseline.append(retry, emit: collectExpected)

    #expect(actual == expected)
    #expect(generator == baseline)
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

private func constantOutput(_ value: Float) -> BrushOutputProgramDefinition {
    BrushOutputProgramDefinition(baseValue: value, terms: [])
}

private func directionalConstantOutput(
    _ value: Float
) -> BrushOutputProgramDefinition {
    BrushOutputProgramDefinition(
        baseValue: value,
        terms: [BrushResponseTermDefinition(
            input: .direction,
            response: .linear,
            inputInverted: false,
            missingInputValue: 0.5,
            responseScale: 0,
            responseOffset: value,
            responseLowerClamp: value,
            responseUpperClamp: value,
            jitter: 0,
            operation: .replace
        )]
    )
}

private func footprintCoverage(
    base: BrushCoverageDefinition,
    aspectRatio: Float,
    shapes: [BrushShapeLayerDefinition]
) -> BrushCoverageDefinition {
    BrushCoverageDefinition(
        shapes: shapes,
        grains: base.grains,
        baseHardness: base.baseHardness,
        aspectRatio: aspectRatio,
        tipThreshold: base.tipThreshold,
        antialiasing: base.antialiasing
    )
}

private func straightTrace(
    generator: inout BrushStrokeGenerator,
    length: Float,
    pressure: Float
) throws -> [DabAttributes] {
    let capabilities: StrokeInputCapabilities = [.pressure]
    var trace: [DabAttributes] = []
    generator.begin(generatorSample(
        x: 0,
        pressure: pressure,
        timestamp: 0,
        phase: .began,
        capabilities: capabilities
    )) { trace.append($0) }
    try generator.finish(
        generatorSample(
            x: length,
            pressure: pressure,
            timestamp: 1,
            phase: .ended,
            capabilities: capabilities
        ),
        maximumPathSubdivisionCount: 4_096
    ) { trace.append($0) }
    return trace
}

private func independentTraceRasterMetrics(
    dabs: [DabAttributes],
    support: BrushTipSupportDefinition,
    from start: WorldPoint,
    to end: WorldPoint,
    step: Float
) -> (firstGap: Float?, maximumOverlap: Int) {
    let delta = end.simd - start.simd
    let length = simd_length(delta)
    let sampleCount = max(1, Int(ceil(length / step)))
    var firstGap: Float?
    var maximumOverlap = 0
    for index in 0...sampleCount {
        let distance = min(length, Float(index) * step)
        let fraction = length > 0 ? distance / length : 0
        let point = start.simd + delta * fraction
        let overlap = dabs.reduce(into: 0) { count, dab in
            if independentTipContains(
                worldPoint: point,
                transform: dab.brushToWorld,
                support: support
            ) {
                count += 1
            }
        }
        if overlap == 0, firstGap == nil { firstGap = distance }
        maximumOverlap = max(maximumOverlap, overlap)
    }
    return (firstGap, maximumOverlap)
}

private func independentTipContains(
    worldPoint: SIMD2<Float>,
    transform: Affine2D,
    support: BrushTipSupportDefinition
) -> Bool {
    let relative = worldPoint - transform.translation
    let determinant = transform.xAxis.x * transform.yAxis.y
        - transform.xAxis.y * transform.yAxis.x
    guard determinant.isFinite, abs(determinant) > Float.ulpOfOne else {
        return false
    }
    let localX = (
        relative.x * transform.yAxis.y
            - relative.y * transform.yAxis.x
    ) / determinant
    let localY = (
        transform.xAxis.x * relative.y
            - transform.xAxis.y * relative.x
    ) / determinant
    let tolerance: Float = 0.000_1
    switch support.kind {
    case .analyticEllipse:
        return localX * localX + localY * localY <= 1 + tolerance
    case .analyticRectangle:
        return abs(localX) <= 1 + tolerance
            && abs(localY) <= 1 + tolerance
    case .normalizedBounds:
        guard let bounds = support.bounds else { return false }
        return localX >= bounds.minX - tolerance
            && localX <= bounds.maxX + tolerance
            && localY >= bounds.minY - tolerance
            && localY <= bounds.maxY + tolerance
    }
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
