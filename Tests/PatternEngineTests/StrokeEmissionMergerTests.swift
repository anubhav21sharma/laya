import Foundation
@testable import PatternEngine
import Testing

@Suite("Stroke emission merger")
struct StrokeEmissionMergerTests {
    @Test
    func distanceTimeAndUnionModesUseTheLockedTupleOrder() throws {
        let distance = [
            candidate(kind: .begin, timeKey: 0, distanceKey: 0, marker: 10),
            candidate(kind: .distance, timeKey: 20, distanceKey: 20, marker: 20),
            candidate(kind: .distance, timeKey: 40, distanceKey: 40, marker: 40),
        ]
        let timed = [
            candidate(kind: .time, timeKey: 10, distanceKey: 10, marker: 11),
            candidate(kind: .time, timeKey: 30, distanceKey: 30, marker: 31),
            candidate(kind: .finish, timeKey: 50, distanceKey: 50, marker: 51),
        ]

        #expect(try drain(distance: distance, timed: []).map(\.kind) == [
            .begin, .distance, .distance,
        ])
        #expect(try drain(distance: [], timed: timed).map(\.kind) == [
            .time, .time, .finish,
        ])
        #expect(try drain(distance: distance, timed: timed).map(\.kind) == [
            .begin, .time, .distance, .time, .distance, .finish,
        ])
    }

    @Test
    func exactKeysCollapseButAdjacentQuantizationKeysRemainDistinct() throws {
        let earlierDistance = candidate(
            kind: .distance,
            timeKey: 10,
            distanceKey: 20,
            marker: 1
        )
        let exactTimed = candidate(
            kind: .time,
            timeKey: 10,
            distanceKey: 20,
            marker: 2
        )
        let adjacentTimed = candidate(
            kind: .time,
            timeKey: 10,
            distanceKey: 21,
            marker: 3
        )

        let merged = try drain(
            distance: [earlierDistance],
            timed: [exactTimed, adjacentTimed]
        )

        #expect(merged.map(\.kind) == [.distance, .time])
        #expect(merged.map(\.sample.pressure) == [1, 3])
        #expect(merged.map(\.distanceKey) == [20, 21])
    }

    @Test
    func productionCanonicalizationRejectsNontransitiveEpsilonMerging() throws {
        let tolerance = 0.000_001
        let distanceA = 0.000_010_00
        let distanceB = 0.000_010_75
        let distanceC = 0.000_011_50
        #expect(abs(distanceA - distanceB) < tolerance)
        #expect(abs(distanceB - distanceC) < tolerance)
        #expect(abs(distanceA - distanceC) > tolerance)

        let a = try canonicalizedBegin(
            sourceDistance: distanceA,
            marker: 1
        )
        let b = try canonicalizedBegin(
            sourceDistance: distanceB,
            marker: 2
        )
        let c = try canonicalizedBegin(
            sourceDistance: distanceC,
            marker: 3
        )
        #expect([a.distanceKey, b.distanceKey, c.distanceKey] == [10, 11, 12])

        let first = try drain(
            distance: [b],
            timed: [a, c]
        )
        let second = try drain(
            distance: [a, c],
            timed: [b]
        )

        #expect(first.map(\.distanceKey) == [10, 11, 12])
        #expect(second.map(\.distanceKey) == [10, 11, 12])
        #expect(first.map(\.sample.pressure) == [1, 2, 3])
        #expect(second.map(\.sample.pressure) == [1, 2, 3])
    }

    @Test
    func earliestKindSuppliesEveryAttributeAtACompleteTie() throws {
        let begin = candidate(
            kind: .begin,
            timeKey: 0,
            distanceKey: 0,
            marker: 11,
            direction: 0.11
        )
        let distance = candidate(
            kind: .distance,
            timeKey: 0,
            distanceKey: 0,
            marker: 22,
            direction: 0.22
        )
        let time = candidate(
            kind: .time,
            timeKey: 0,
            distanceKey: 0,
            marker: 33,
            direction: 0.33
        )
        let finish = candidate(
            kind: .finish,
            timeKey: 0,
            distanceKey: 0,
            marker: 44,
            direction: 0.44
        )

        let merged = try drain(
            distance: [distance],
            timed: [begin, time, finish]
        )

        #expect(merged == [begin])
        #expect(merged[0].sample.pressure == 11)
        #expect(merged[0].relativeStrokeTime == 11)
        #expect(merged[0].sourceDistance == 11)
        #expect(merged[0].direction == 0.11)
    }

    @Test
    func stationaryTicksAndDistinctCornerOrientationsCoexistInSequence() throws {
        let time = candidate(
            kind: .time,
            timeKey: 200,
            distanceKey: 0,
            marker: 1,
            direction: 0.75
        )
        let corner0 = candidate(
            kind: .corner,
            timeKey: 200,
            distanceKey: 0,
            marker: 2,
            direction: 1,
            cornerSequence: 8
        )
        let corner1 = candidate(
            kind: .corner,
            timeKey: 200,
            distanceKey: 0,
            marker: 3,
            direction: 1.5,
            cornerSequence: 9
        )

        let merged = try drain(
            distance: [corner0, corner1],
            timed: [time]
        )

        #expect(merged.map(\.kind) == [.time, .corner, .corner])
        #expect(merged.map(\.direction) == [0.75, 1, 1.5])
        #expect(merged.map(\.cornerSequence) == [0, 8, 9])
        #expect(merged.allSatisfy { $0.position == WorldPoint(x: 0, y: 0) })
    }

    @Test
    func authoritativeAndPredictionCandidatesRequireSeparateMergers() throws {
        let authoritative = candidate(
            kind: .distance,
            timeKey: 1,
            distanceKey: 1,
            marker: 1
        )
        let prediction = candidate(
            kind: .time,
            timeKey: 1,
            distanceKey: 1,
            marker: 2,
            provenance: .prediction
        )
        let merger = StrokeEmissionMerger(provenance: .authoritative)

        #expect(throws: StrokeEmissionMergerError.provenanceMismatch(
            expected: .authoritative,
            actual: .prediction
        )) {
            _ = try merger.next(distance: authoritative, timed: prediction)
        }

        #expect(try drain(
            distance: [authoritative],
            timed: [],
            provenance: .authoritative
        ) == [authoritative])
        #expect(try drain(
            distance: [],
            timed: [prediction],
            provenance: .prediction
        ) == [prediction])
    }

    @Test
    func uncommittedDecisionRetriesWithoutChangingDuplicateState() throws {
        let distance = candidate(
            kind: .distance,
            timeKey: 10,
            distanceKey: 20,
            marker: 1
        )
        let timed = candidate(
            kind: .time,
            timeKey: 10,
            distanceKey: 20,
            marker: 2
        )
        let merger = StrokeEmissionMerger(provenance: .authoritative)
        let firstProposal = try merger.next(
            distance: distance,
            timed: timed
        )
        let retryProposal = try merger.next(
            distance: distance,
            timed: timed
        )
        let first = try #require(firstProposal)
        let retry = try #require(retryProposal)
        #expect(first == retry)
        #expect(first.candidate == distance)
        let duplicateProposal = try first.continuation.next(
            distance: nil,
            timed: timed
        )
        let duplicate = try #require(duplicateProposal)
        #expect(duplicate.candidate == nil)
        #expect(!duplicate.consumesDistance)
        #expect(duplicate.consumesTimed)
    }
}

private func drain(
    distance: [StrokeEmissionCandidate],
    timed: [StrokeEmissionCandidate],
    provenance: StrokeEmissionProvenance = .authoritative
) throws -> [StrokeEmissionCandidate] {
    var merger = StrokeEmissionMerger(provenance: provenance)
    var distanceIndex = 0
    var timedIndex = 0
    var accepted: [StrokeEmissionCandidate] = []
    while distanceIndex < distance.count || timedIndex < timed.count {
        let proposed = try merger.next(
            distance: distanceIndex < distance.count
                ? distance[distanceIndex]
                : nil,
            timed: timedIndex < timed.count ? timed[timedIndex] : nil
        )
        let step = try #require(proposed)
        if let candidate = step.candidate {
            accepted.append(candidate)
        }
        merger = step.continuation
        if step.consumesDistance { distanceIndex += 1 }
        if step.consumesTimed { timedIndex += 1 }
    }
    return accepted
}

private func candidate(
    kind: StrokeEmissionCandidateKind,
    timeKey: Int64,
    distanceKey: Int64,
    marker: Float,
    direction: Float = 0,
    provenance: StrokeEmissionProvenance = .authoritative,
    cornerSequence: UInt64 = 0
) -> StrokeEmissionCandidate {
    StrokeEmissionCandidate(
        sample: InterpolatedStrokeSample(
            position: WorldPoint(x: 0, y: 0),
            pressure: marker,
            timestamp: Double(marker),
            altitude: marker + 0.1,
            azimuth: marker + 0.2,
            roll: marker + 0.3,
            velocity: marker + 0.4,
            artisticVelocity: marker + 0.5,
            phase: kind == .begin ? .began : .moved,
            source: .pencil,
            kind: provenance == .prediction ? .predicted : .actual,
            capabilities: [.pressure, .altitude, .azimuth, .roll],
            tangentialPressure: marker + 0.6,
            deviceIdentifier: UInt64(marker),
            estimationUpdateIndex: Int(marker),
            estimatedProperties: [.pressure],
            estimatedPropertiesExpectingUpdates: [.azimuth]
        ),
        relativeStrokeTime: Double(marker),
        sourceDistance: Double(marker),
        direction: direction,
        provenance: provenance,
        timeKey: timeKey,
        distanceKey: distanceKey,
        kind: kind,
        cornerSequence: cornerSequence
    )
}

private func canonicalizedBegin(
    sourceDistance: Double,
    marker: Float
) throws -> StrokeEmissionCandidate {
    var emitter = try TimedStrokeEmitter(timeInterval: 10)
    let sample = candidate(
        kind: .begin,
        timeKey: 0,
        distanceKey: 0,
        marker: marker
    ).sample
    let cursor = try emitter.begin(at: TimedStrokePoint(
        sample: sample,
        sourceDistance: sourceDistance,
        direction: 0
    ))
    let step = try cursor.nextCandidate()
    return try #require(step).candidate
}
