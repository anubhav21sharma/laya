import Foundation
@testable import PatternEngine
import Testing

private let stageCPartitionViewport = ViewportTransform(
    drawableSize: PatternSize(width: 2, height: 2),
    worldCenter: WorldPoint(x: 0, y: 0)
)

private struct StageCPartitionEvidence {
    let dabs: [LogicalDab]
    let rasterInputBatches: [LogicalDabBatch]
    let checkpoints: [BrushStrokeGenerator]
    let finalGenerator: BrushStrokeGenerator
}

private enum StageCPredictionBatching {
    case none
    case endpointOnly
    case everySample
}

@Test
func stageCAcceptanceEnumeratesEveryShortTracePartition() {
    let partitions = stageCContiguousPartitions(itemCount: 6)

    #expect(partitions.count == 32)
    #expect(partitions.first == [0..<6])
    #expect(partitions.last == [
        0..<1,
        1..<2,
        2..<3,
        3..<4,
        4..<5,
        5..<6,
    ])
}

@Test
func stageCAcceptanceV1DistanceTraceSurvivesEveryBatchPartition() throws {
    let seed: UInt64 = 0xC1_13_01
    let samples = stageCV1DistanceSamples()
    let partitions = stageCContiguousPartitions(itemCount: samples.count)
    let baseline = try stageCRunInputPartition(
        program: nativeTestProgram(),
        seed: seed,
        samples: samples,
        partition: try #require(partitions.first)
    )

    #expect(partitions.count == 32)
    #expect(baseline.dabs.count == 7)
    stageCExpectCanonicalIdentity(baseline.dabs, seed: seed)

    for partition in partitions {
        let actual = try stageCRunInputPartition(
            program: nativeTestProgram(),
            seed: seed,
            samples: samples,
            partition: partition
        )
        stageCExpectEquivalent(
            actual,
            baseline: baseline,
            partition: partition
        )
    }
}

@Test
func stageCAcceptanceV2UnionCornerTimedTraceSurvivesEveryBatchPartition()
    throws
{
    let seed: UInt64 = 0xC1_13_02
    let program = try stageCPartitionProgram(
        id: "test.stage-c.acceptance.partition.union-corner-time"
    )
    let samples = stageCV2UnionCornerTimedSamples()
    let partitions = stageCContiguousPartitions(itemCount: samples.count)
    let baseline = try stageCRunInputPartition(
        program: program,
        seed: seed,
        samples: samples,
        partition: try #require(partitions.first)
    )

    #expect(partitions.count == 32)
    #expect(baseline.dabs.count == 19)
    stageCExpectCanonicalIdentity(baseline.dabs, seed: seed)
    stageCExpectCornerFan(in: baseline.dabs)
    let distanceOnly = try stageCRunInputPartition(
        program: stageCPartitionProgram(
            id: "test.stage-c.acceptance.partition.distance-control",
            emission: BrushEmissionDefinition(
                mode: .distance,
                timeInterval: nil
            )
        ),
        seed: seed,
        samples: samples,
        partition: try #require(partitions.first)
    )
    #expect(baseline.dabs.count > distanceOnly.dabs.count)

    for partition in partitions {
        let actual = try stageCRunInputPartition(
            program: program,
            seed: seed,
            samples: samples,
            partition: partition
        )
        stageCExpectEquivalent(
            actual,
            baseline: baseline,
            partition: partition
        )
    }
}

@Test
func stageCAcceptanceV2CursorSurvivesEveryOutputPartition() throws {
    let seed: UInt64 = 0xC1_13_03
    let program = try stageCPartitionProgram(
        id: "test.stage-c.acceptance.cursor.union-corner-time"
    )
    let samples = [
        stageCPartitionSample(
            x: 0,
            y: 0,
            timestamp: 0,
            phase: .began
        ),
        stageCPartitionSample(
            x: 6,
            y: 0,
            timestamp: 0.3,
            phase: .moved
        ),
        stageCPartitionSample(
            x: 6,
            y: 6,
            timestamp: 0.6,
            phase: .ended
        ),
    ]
    var generator = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 20,
        color: .black,
        seed: seed
    )
    _ = try generator.currentSampleDabs(samples[0])
    _ = try generator.currentSampleDabs(samples[1])
    let initialCursor = try generator.emissionCursor(
        for: samples[2],
        maximumPathSubdivisionCount: 4_096
    )
    var uninterrupted = initialCursor
    var expected: [LogicalDab] = []
    while !uninterrupted.isComplete {
        _ = try uninterrupted.emitNextPage { expected.append($0) }
    }
    let expectedGenerator = try #require(
        uninterrupted.completedGenerator
    )

    // Keep exhaustive enumeration deliberately short: enough candidates to
    // exercise corner, distance, time, finish and merger checkpoints without
    // turning the acceptance gate exponential in a production-length trace.
    #expect(expected.count == 7)
    guard expected.count == 7 else { return }
    stageCExpectCanonicalIdentity(
        expected,
        seed: seed,
        startingOrdinal: expected[0].ordinal
    )
    stageCExpectCornerFan(in: expected)

    let partitions = stageCContiguousPartitions(itemCount: expected.count)
    #expect(partitions.count == 64)
    let referenceCheckpoints = try stageCCursorCheckpoints(
        initialCursor,
        dabCount: expected.count
    )

    for partition in partitions {
        var cursor = initialCursor
        var actual: [LogicalDab] = []
        for (groupIndex, group) in partition.enumerated() {
            if groupIndex == partition.indices.last {
                while !cursor.isComplete {
                    _ = try cursor.emitNextPage { actual.append($0) }
                }
                continue
            }
            let cut = group.upperBound
            let page = try cursor.emitNextPageDeciding { dab in
                guard actual.count < cut else { return .pause }
                actual.append(dab)
                return .accept
            }
            #expect(page.hasMore)
            #expect(actual.count == cut)
            #expect(cursor == referenceCheckpoints[cut])
        }

        #expect(actual == expected)
        #expect(actual.map(\.ordinal) == expected.map(\.ordinal))
        #expect(
            actual.map(\.randomValues) == expected.map(\.randomValues)
        )
        #expect(cursor.completedGenerator == expectedGenerator)
    }
}

@Test
func stageCAcceptancePredictionBatchingCannotChangeAuthoritativeTrace()
    throws
{
    let seed: UInt64 = 0xC1_13_04
    let program = try stageCPartitionProgram(
        id: "test.stage-c.acceptance.prediction-partition"
    )
    let samples = stageCV2UnionCornerTimedSamples()
    let partitions = stageCContiguousPartitions(itemCount: samples.count)
    let baseline = try stageCRunInputPartition(
        program: program,
        seed: seed,
        samples: samples,
        partition: try #require(partitions.first)
    )
    var observedPredictedDabCount = 0

    for partition in partitions {
        for predictionBatching in [
            StageCPredictionBatching.endpointOnly,
            .everySample,
        ] {
            let actual = try stageCRunInputPartition(
                program: program,
                seed: seed,
                samples: samples,
                partition: partition,
                predictionBatching: predictionBatching,
                observedPredictedDabCount: &observedPredictedDabCount
            )
            stageCExpectEquivalent(
                actual,
                baseline: baseline,
                partition: partition
            )
        }
    }

    #expect(observedPredictedDabCount > 0)
}

private func stageCRunInputPartition(
    program: BrushProgram,
    seed: UInt64,
    samples: [WorldStrokeSample],
    partition: [Range<Int>],
    predictionBatching: StageCPredictionBatching = .none,
    observedPredictedDabCount: inout Int
) throws -> StageCPartitionEvidence {
    var generator = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 20,
        color: .black,
        seed: seed
    )
    var dabs: [LogicalDab] = []
    var rasterInputBatches: [LogicalDabBatch] = []
    var checkpoints: [BrushStrokeGenerator] = []

    for group in partition {
        if predictionBatching != .none,
           group.lowerBound > 0
        {
            var prediction = generator
            let predictionIndices: [Int] = switch predictionBatching {
            case .none: []
            case .endpointOnly: [group.upperBound - 1]
            case .everySample: Array(group)
            }
            for index in predictionIndices {
                let predicted = stageCPredicted(samples[index])
                try prediction.consumeCurrentSample(
                    predicted,
                    maximumPathSubdivisionCount: 4_096
                ) { _ in observedPredictedDabCount += 1 }
            }
        }

        var working = generator
        let startingOrdinal = UInt64(dabs.count)
        var groupDabs: [LogicalDab] = []
        for index in group {
            let batch = try stageCGenerateBatch(
                sample: samples[index],
                generator: &working
            )
            groupDabs.append(contentsOf: batch.dabs)
            checkpoints.append(working)
        }
        rasterInputBatches.append(try LogicalDabBatch(
            seed: seed,
            startingOrdinal: groupDabs.first?.ordinal ?? startingOrdinal,
            isPredicted: false,
            dabs: groupDabs
        ))
        dabs.append(contentsOf: groupDabs)
        generator = working
    }

    return StageCPartitionEvidence(
        dabs: dabs,
        rasterInputBatches: rasterInputBatches,
        checkpoints: checkpoints,
        finalGenerator: generator
    )
}

private func stageCRunInputPartition(
    program: BrushProgram,
    seed: UInt64,
    samples: [WorldStrokeSample],
    partition: [Range<Int>]
) throws -> StageCPartitionEvidence {
    var ignoredPredictionCount = 0
    return try stageCRunInputPartition(
        program: program,
        seed: seed,
        samples: samples,
        partition: partition,
        observedPredictedDabCount: &ignoredPredictionCount
    )
}

private func stageCGenerateBatch(
    sample: WorldStrokeSample,
    generator: inout BrushStrokeGenerator
) throws -> LogicalDabBatch {
    guard sample.phase != .cancelled else {
        preconditionFailure("A canonical emitted trace cannot contain cancel")
    }
    let startingOrdinal = generator.emittedDabCount
    let dabs = try generator.currentSampleDabs(sample)
    return try LogicalDabBatch(
        seed: generator.seed,
        startingOrdinal: dabs.first?.ordinal ?? startingOrdinal,
        isPredicted: sample.kind == .predicted,
        dabs: dabs
    )
}

private func stageCExpectEquivalent(
    _ actual: StageCPartitionEvidence,
    baseline: StageCPartitionEvidence,
    partition: [Range<Int>]
) {
    #expect(actual.dabs == baseline.dabs)
    #expect(actual.dabs.map(\.ordinal) == baseline.dabs.map(\.ordinal))
    #expect(
        actual.dabs.map(\.randomValues)
            == baseline.dabs.map(\.randomValues)
    )
    #expect(
        actual.rasterInputBatches.flatMap(\.dabs) == baseline.dabs
    )
    #expect(actual.finalGenerator == baseline.finalGenerator)
    for group in partition {
        let checkpointIndex = group.upperBound - 1
        #expect(
            actual.checkpoints[checkpointIndex]
                == baseline.checkpoints[checkpointIndex]
        )
    }
}

private func stageCExpectCanonicalIdentity(
    _ dabs: [LogicalDab],
    seed: UInt64,
    startingOrdinal: UInt64 = 0
) {
    #expect(
        dabs.map(\.ordinal)
            == Array(
                startingOrdinal
                    ..< startingOrdinal + UInt64(dabs.count)
            )
    )
    var expectedRandom = BrushRandom(seed: seed)
    if startingOrdinal > 0 {
        for _ in 0..<startingOrdinal { _ = expectedRandom.nextValues() }
    }
    #expect(dabs.map(\.randomValues.compatibility) == dabs.map {
        _ in expectedRandom.nextValues()
    })
}

private func stageCExpectCornerFan(in dabs: [LogicalDab]) {
    let grouped = Dictionary(grouping: dabs, by: \.sourceDistance)
    let fan = grouped.values.first { group in
        Set(group.map(\.rotation)).count >= 2
    }
    #expect(fan != nil)
    if let fan {
        #expect(Set(fan.map(\.ordinal)).count == fan.count)
    }
}

private func stageCCursorCheckpoints(
    _ initial: BrushStrokeGenerator.EmissionCursor,
    dabCount: Int
) throws -> [Int: BrushStrokeGenerator.EmissionCursor] {
    var result: [Int: BrushStrokeGenerator.EmissionCursor] = [:]
    for cut in 1..<dabCount {
        var cursor = initial
        var acceptedCount = 0
        let page = try cursor.emitNextPageDeciding { _ in
            guard acceptedCount < cut else { return .pause }
            acceptedCount += 1
            return .accept
        }
        #expect(page.hasMore)
        #expect(acceptedCount == cut)
        result[cut] = cursor
    }
    return result
}

private func stageCContiguousPartitions(
    itemCount: Int
) -> [[Range<Int>]] {
    precondition(itemCount > 0 && itemCount <= 16)
    let boundaryCount = itemCount - 1
    return (0..<(1 << boundaryCount)).map { mask in
        var groups: [Range<Int>] = []
        var start = 0
        for boundary in 0..<boundaryCount
        where mask & (1 << boundary) != 0 {
            groups.append(start..<(boundary + 1))
            start = boundary + 1
        }
        groups.append(start..<itemCount)
        return groups
    }
}

private func stageCPartitionProgram(
    id: String,
    emission: BrushEmissionDefinition = BrushEmissionDefinition(
        mode: .distanceAndTime,
        timeInterval: 0.1
    )
) throws -> BrushProgram {
    try stageCTestProgram(
        id: id,
        usesTravelDirection: true,
        maximumAngularStep: .pi / 8,
        baseSpacingFraction: 0.125,
        maximumSpacingFraction: 0.5,
        emission: emission
    )
}

private func stageCV1DistanceSamples() -> [WorldStrokeSample] {
    [
        stageCPartitionSample(x: 0, timestamp: 0, phase: .began),
        stageCPartitionSample(x: 3, timestamp: 0.1, phase: .moved),
        stageCPartitionSample(x: 6, timestamp: 0.2, phase: .moved),
        stageCPartitionSample(x: 9, timestamp: 0.3, phase: .moved),
        stageCPartitionSample(x: 12, timestamp: 0.4, phase: .moved),
        stageCPartitionSample(x: 15, timestamp: 0.5, phase: .ended),
    ]
}

private func stageCV2UnionCornerTimedSamples() -> [WorldStrokeSample] {
    [
        stageCPartitionSample(x: 0, y: 0, timestamp: 0, phase: .began),
        stageCPartitionSample(x: 5, y: 0, timestamp: 0.2, phase: .moved),
        stageCPartitionSample(x: 10, y: 0, timestamp: 0.4, phase: .moved),
        stageCPartitionSample(x: 10, y: 5, timestamp: 0.6, phase: .moved),
        stageCPartitionSample(x: 10, y: 10, timestamp: 0.8, phase: .moved),
        stageCPartitionSample(x: 15, y: 10, timestamp: 1, phase: .ended),
    ]
}

private func stageCPartitionSample(
    x: Float,
    y: Float = 0,
    pressure: Float = 0.5,
    timestamp: TimeInterval,
    phase: StrokePhase
) -> WorldStrokeSample {
    let sample = StrokeSample(
        position: ScreenPoint(x: x + 1, y: y + 1),
        pressure: pressure,
        timestamp: timestamp,
        phase: phase,
        source: .mouse
    )
    var input = BrushInputDeriver()
    return input.derive(sample, viewport: stageCPartitionViewport)
}

private func stageCPredicted(
    _ sample: WorldStrokeSample
) -> WorldStrokeSample {
    WorldStrokeSample(
        position: sample.position,
        pressure: sample.pressure,
        timestamp: sample.timestamp,
        altitude: sample.altitude,
        azimuth: sample.azimuth,
        roll: sample.roll,
        tangentialPressure: sample.tangentialPressure,
        deviceIdentifier: sample.deviceIdentifier,
        estimationUpdateIndex: sample.estimationUpdateIndex,
        estimatedProperties: sample.estimatedProperties,
        estimatedPropertiesExpectingUpdates:
            sample.estimatedPropertiesExpectingUpdates,
        velocity: sample.velocity,
        artisticVelocity: sample.artisticVelocity,
        phase: sample.phase,
        source: sample.source,
        kind: .predicted,
        capabilities: sample.capabilities
    )
}
