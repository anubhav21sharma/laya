import Foundation
import PatternEngine
import Testing

@Suite("TimedStrokeEmitter")
struct TimedStrokeEmitterTests {
    @Test
    func intervalValidationUsesTheInclusiveRecordedTimeContract() throws {
        _ = try TimedStrokeEmitter(timeInterval: 1.0 / 240)
        _ = try TimedStrokeEmitter(timeInterval: 10)

        for value in [0, -1, 1.0 / 241, 10.000_001, .infinity, .nan] {
            #expect(throws: TimedStrokeEmitterError.invalidTimeInterval) {
                _ = try TimedStrokeEmitter(timeInterval: value)
            }
        }
    }

    @Test
    func beginIsTheOnlyCandidateAtRelativeZero() throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 0.25)
        var cursor = try emitter.begin(at: timedPoint(
            x: 3,
            y: 4,
            pressure: 0.2,
            timestamp: 90,
            sourceDistance: 7,
            direction: 1.25,
            phase: .began
        ))

        let candidates = try drain(&cursor)

        #expect(candidates.count == 1)
        let begin = try #require(candidates.first)
        #expect(begin.kind == .begin)
        #expect(begin.relativeStrokeTime == 0)
        #expect(begin.timeKey == 0)
        #expect(begin.sourceDistance == 7)
        #expect(begin.distanceKey == 7_000_000)
        #expect(begin.direction == 1.25)
        #expect(begin.provenance == .authoritative)
        #expect(begin.sample.position == WorldPoint(x: 3, y: 4))
        #expect(cursor.isComplete)
    }

    @Test
    func exactBoundaryAndStationarySegmentsEmitAttributedTimeTicks() throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 0.25)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            pressure: 0.2,
            timestamp: 10,
            sourceDistance: 5,
            direction: 0,
            phase: .began,
            altitude: 0.6,
            azimuth: 0.2,
            roll: -0.2,
            tangentialPressure: -0.2,
            deviceIdentifier: 11,
            estimationUpdateIndex: 2,
            estimatedProperties: [.altitude],
            estimatedPropertiesExpectingUpdates: [.altitude]
        ))

        let movingResult = try emitter.advance(to: timedPoint(
            x: 8,
            pressure: 1,
            timestamp: 10.5,
            sourceDistance: 9,
            direction: 2,
            phase: .moved,
            kind: .coalesced,
            altitude: 0.2,
            azimuth: 0.4,
            roll: -0.6,
            tangentialPressure: 0.8,
            deviceIdentifier: 22,
            estimationUpdateIndex: 4,
            estimatedProperties: [.pressure, .roll],
            estimatedPropertiesExpectingUpdates: [.pressure]
        ))
        var moving = try #require(movingResult)
        let movingCandidates = try drain(&moving)

        #expect(movingCandidates.count == 2)
        let midpoint = movingCandidates[0]
        #expect(midpoint.kind == .time)
        #expect(midpoint.relativeStrokeTime == 0.25)
        #expect(midpoint.timeKey == 250_000_000)
        #expect(midpoint.sourceDistance == 7)
        #expect(midpoint.distanceKey == 7_000_000)
        #expect(midpoint.direction == 1)
        #expect(midpoint.sample.position == WorldPoint(x: 4, y: 0))
        #expect(midpoint.sample.pressure == 0.6)
        #expect(midpoint.sample.timestamp == 10.25)
        #expect(abs(try #require(midpoint.sample.altitude) - 0.4) < 0.000_001)
        #expect(abs(try #require(midpoint.sample.azimuth) - 0.3) < 0.000_001)
        #expect(abs(try #require(midpoint.sample.roll) + 0.4) < 0.000_001)
        #expect(
            abs(try #require(midpoint.sample.tangentialPressure) - 0.3)
                < 0.000_001
        )
        #expect(midpoint.sample.phase == .moved)
        #expect(midpoint.sample.kind == .coalesced)
        #expect(midpoint.sample.deviceIdentifier == 22)
        #expect(midpoint.sample.estimationUpdateIndex == 4)
        #expect(midpoint.sample.estimatedProperties == [.pressure, .roll])
        #expect(
            midpoint.sample.estimatedPropertiesExpectingUpdates == [.pressure]
        )
        #expect(movingCandidates[1].sample.position == WorldPoint(x: 8, y: 0))

        let stationaryResult = try emitter.advance(to: timedPoint(
            x: 8,
            pressure: 0.5,
            timestamp: 10.75,
            sourceDistance: 9,
            direction: 2,
            phase: .moved
        ))
        var stationary = try #require(stationaryResult)
        let stationaryCandidates = try drain(&stationary)

        #expect(stationaryCandidates.count == 1)
        #expect(stationaryCandidates[0].relativeStrokeTime == 0.75)
        #expect(stationaryCandidates[0].position == WorldPoint(x: 8, y: 0))
        #expect(stationaryCandidates[0].sourceDistance == 9)
        #expect(stationaryCandidates[0].direction == 2)
    }

    @Test
    func nonincreasingAndNonfiniteTimestampsDoNotMutateTheCursor() throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 0.25)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 4,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        let before = emitter

        #expect(try emitter.advance(to: timedPoint(
            x: 100,
            timestamp: 4,
            sourceDistance: 100,
            direction: 1,
            phase: .moved
        )) == nil)
        #expect(emitter == before)
        #expect(try emitter.advance(to: timedPoint(
            x: 100,
            timestamp: 3,
            sourceDistance: 100,
            direction: 1,
            phase: .moved
        )) == nil)
        #expect(emitter == before)
        #expect(try emitter.advance(to: timedPoint(
            x: 100,
            timestamp: .nan,
            sourceDistance: 100,
            direction: 1,
            phase: .moved
        )) == nil)
        #expect(emitter == before)
    }

    @Test
    func predictionUsesAValueCopyAndNeverConsumesAuthoritativeTicks() throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 0.1)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 10,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        let firstResult = try emitter.advance(to: timedPoint(
            x: 1.5,
            timestamp: 10.15,
            sourceDistance: 1.5,
            direction: 0.15,
            phase: .moved
        ))
        var first = try #require(firstResult)
        _ = try drain(&first)
        let authoritativeBeforePrediction = emitter

        var predictionEmitter = emitter
        let predictionResult = try predictionEmitter.prediction(to: timedPoint(
            x: 3.5,
            timestamp: 10.35,
            sourceDistance: 3.5,
            direction: 0.35,
            phase: .moved,
            kind: .predicted
        ))
        var prediction = try #require(predictionResult)
        let predicted = try drain(&prediction)

        #expect(emitter == authoritativeBeforePrediction)
        #expect(predictionEmitter != authoritativeBeforePrediction)
        #expect(predicted.map(\.timeKey) == [200_000_000, 300_000_000])
        #expect(predicted.allSatisfy { $0.provenance == .prediction })
        #expect(predicted.allSatisfy { $0.kind == .time })

        let authoritativeResult = try emitter.advance(to: timedPoint(
            x: 2.5,
            timestamp: 10.25,
            sourceDistance: 2.5,
            direction: 0.25,
            phase: .moved
        ))
        var authoritative = try #require(authoritativeResult)
        let actual = try drain(&authoritative)
        #expect(actual.map(\.relativeStrokeTime) == [0.2])
        #expect(actual[0].provenance == .authoritative)
    }

    @Test
    func successivePredictionPointsAdvanceOnlyTheCallerOwnedCopy() throws {
        var authoritative = try TimedStrokeEmitter(timeInterval: 0.1)
        _ = try authoritative.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        #expect(try authoritative.advance(to: timedPoint(
            x: 0.5,
            timestamp: 0.05,
            sourceDistance: 0.5,
            direction: 0.05,
            phase: .moved
        )) == nil)
        let checkpoint = authoritative
        var prediction = authoritative

        let firstResult = try prediction.prediction(to: timedPoint(
            x: 1.5,
            timestamp: 0.15,
            sourceDistance: 1.5,
            direction: 0.15,
            phase: .moved,
            kind: .predicted
        ))
        var first = try #require(firstResult)
        let firstCandidates = try drain(&first)
        let secondResult = try prediction.prediction(to: timedPoint(
            x: 2.5,
            timestamp: 0.25,
            sourceDistance: 2.5,
            direction: 0.25,
            phase: .moved,
            kind: .predicted
        ))
        var second = try #require(secondResult)
        let secondCandidates = try drain(&second)

        #expect(firstCandidates.map(\.timeKey) == [100_000_000])
        #expect(secondCandidates.map(\.timeKey) == [200_000_000])
        #expect(firstCandidates[0].position == WorldPoint(x: 1, y: 0))
        #expect(secondCandidates[0].position == WorldPoint(x: 2, y: 0))
        #expect(authoritative == checkpoint)

        let actualResult = try authoritative.advance(to: timedPoint(
            x: 1.5,
            timestamp: 0.15,
            sourceDistance: 1.5,
            direction: 0.15,
            phase: .moved
        ))
        var actual = try #require(actualResult)
        #expect(try drain(&actual).map(\.timeKey) == [100_000_000])
    }

    @Test
    func predictionTraceIsIndependentOfInputPartitioning() throws {
        let points = (1...8).map { index in
            timedPoint(
                x: Float(index),
                timestamp: Double(index) * 0.07,
                sourceDistance: Double(index),
                direction: Float(index) * 0.1,
                phase: .moved,
                kind: .predicted
            )
        }
        let whole = try emitPredictionTrace(points, partitionSizes: [8])
        let split = try emitPredictionTrace(points, partitionSizes: [1, 3, 2, 2])
        let singletons = try emitPredictionTrace(
            points,
            partitionSizes: Array(repeating: 1, count: 8)
        )

        expectEquivalentPredictionGeometry(split, whole)
        expectEquivalentPredictionGeometry(singletons, whole)
        #expect(whole.map(\.timeKey) == [
            100_000_000, 200_000_000, 300_000_000, 400_000_000,
            500_000_000,
        ])
    }

    @Test
    func largeAbsoluteOriginCannotEraseRelativeInterpolationProgress() throws {
        let origin = TimeInterval(1 << 46)
        let interval = 1.0 / 240
        #expect(origin + interval == origin)
        var emitter = try TimedStrokeEmitter(timeInterval: interval)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: origin,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        let result = try emitter.advance(to: timedPoint(
            x: 15,
            timestamp: origin + 0.0625,
            sourceDistance: 15,
            direction: 1.5,
            phase: .moved
        ))
        var cursor = try #require(result)
        let candidates = try drain(&cursor)

        #expect(candidates.count == 15)
        #expect(abs(candidates[0].position.x - 1) < 0.000_001)
        #expect(abs(candidates[0].sourceDistance - 1) < 0.000_000_001)
        #expect(abs(candidates[0].direction - 0.1) < 0.000_001)
        #expect(candidates[0].relativeStrokeTime == interval)
    }

    @Test
    func extremeFiniteContinuousEndpointsNeverProduceNonfiniteCandidates()
        throws
    {
        let extreme = Float.greatestFiniteMagnitude
        var emitter = try TimedStrokeEmitter(timeInterval: 1)
        _ = try emitter.begin(at: timedPoint(
            x: extreme,
            y: -extreme,
            pressure: extreme,
            velocity: extreme,
            timestamp: 0,
            sourceDistance: 0,
            direction: extreme,
            phase: .began,
            altitude: extreme,
            azimuth: extreme,
            roll: -extreme,
            tangentialPressure: extreme
        ))
        let result = try emitter.advance(to: timedPoint(
            x: -extreme,
            y: extreme,
            pressure: -extreme,
            velocity: -extreme,
            timestamp: 2,
            sourceDistance: 2,
            direction: -extreme,
            phase: .moved,
            altitude: -extreme,
            azimuth: -extreme,
            roll: extreme,
            tangentialPressure: -extreme
        ))
        var cursor = try #require(result)
        let candidates = try drain(&cursor)

        #expect(candidates.count == 2)
        for candidate in candidates {
            #expect(candidate.position.x.isFinite)
            #expect(candidate.position.y.isFinite)
            #expect(candidate.sample.pressure.isFinite)
            #expect(candidate.sample.velocity.isFinite)
            #expect(candidate.sample.altitude?.isFinite == true)
            #expect(candidate.sample.azimuth?.isFinite == true)
            #expect(candidate.sample.roll?.isFinite == true)
            #expect(candidate.sample.tangentialPressure?.isFinite == true)
            #expect(candidate.direction.isFinite)
            #expect(candidate.relativeStrokeTime.isFinite)
            #expect(candidate.sourceDistance.isFinite)
        }
        #expect(abs(candidates[0].position.x) < 1)
        #expect(abs(candidates[0].position.y) < 1)
        #expect(abs(candidates[0].sample.pressure) < 1)
        #expect(abs(candidates[0].sample.velocity) < 1)
        #expect(abs(candidates[0].sample.altitude ?? .infinity) < 1)
        #expect(abs(candidates[0].sample.tangentialPressure ?? .infinity) < 1)
        #expect(abs(candidates[0].direction) < 1)
    }

    @Test
    func finishCatchesUpTicksThenEmitsExactEndpointAndAllowsRapidReuse()
        throws
    {
        var emitter = try TimedStrokeEmitter(timeInterval: 0.25)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 20,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        #expect(try emitter.advance(to: timedPoint(
            x: 1,
            timestamp: 20.1,
            sourceDistance: 1,
            direction: 0.1,
            phase: .moved
        )) == nil)

        var finish = try emitter.finish(at: timedPoint(
            x: 6,
            pressure: 0.9,
            timestamp: 20.6,
            sourceDistance: 6,
            direction: 0.6,
            phase: .ended
        ))
        let candidates = try drain(&finish)

        #expect(candidates.map(\.kind) == [.time, .time, .finish])
        #expect(
            candidates.map(\.timeKey)
                == [250_000_000, 500_000_000, 600_000_000]
        )
        #expect(candidates.last?.relativeStrokeTime == 20.6 - 20)
        #expect(candidates.last?.sample.position == WorldPoint(x: 6, y: 0))
        #expect(candidates.last?.timeKey == 600_000_000)
        #expect(candidates.last?.distanceKey == 6_000_000)

        var nextBegin = try emitter.begin(at: timedPoint(
            x: 50,
            timestamp: 30,
            sourceDistance: 0,
            direction: -1,
            phase: .began
        ))
        #expect(try drain(&nextBegin).map(\.kind) == [.begin])
    }

    @Test
    func terminationCanDeclareEndpointAlreadySuppliedAndCancelEmitsNothing()
        throws
    {
        var emitter = try TimedStrokeEmitter(timeInterval: 1)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        var supplied = try emitter.finish(
            at: timedPoint(
                x: 0.5,
                timestamp: 0.5,
                sourceDistance: 0.5,
                direction: 0,
                phase: .ended
            ),
            endpointAlreadySupplied: true
        )
        #expect(try drain(&supplied).isEmpty)

        _ = try emitter.begin(at: timedPoint(
            x: 3,
            timestamp: 8,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        emitter.cancel()
        #expect(throws: TimedStrokeEmitterError.strokeNotActive) {
            _ = try emitter.advance(to: timedPoint(
                x: 4,
                timestamp: 9,
                sourceDistance: 1,
                direction: 0,
                phase: .moved
            ))
        }
        var afterCancel = try emitter.begin(at: timedPoint(
            x: -2,
            timestamp: 9,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        #expect(try drain(&afterCancel).count == 1)
    }

    @Test
    func hugeGapExposesOnlyOneBoundedPageAndAnArithmeticRemainder() throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 1.0 / 240)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        let result = try emitter.advance(to: timedPoint(
            x: 1,
            timestamp: 1_000_000,
            sourceDistance: 1,
            direction: 0,
            phase: .moved
        ))
        var cursor = try #require(result)

        var keys: [Int64] = []
        let firstPage = try cursor.emitNextPage { keys.append($0.timeKey) }

        #expect(firstPage.emittedCount == LogicalDabBatch.maximumDabCount)
        #expect(firstPage.hasMore)
        #expect(keys.count == LogicalDabBatch.maximumDabCount)
        #expect(keys.first == 4_166_667)
        #expect(keys.last == 2_133_333_333)
        #expect(cursor.remainingCandidateCount == 239_999_488)
    }

    @Test(arguments: [511, 512, 513])
    func exactPageBoundariesResumeWithoutSkipOrDuplicate(
        candidateCount: Int
    ) throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 1)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        let proposed = try emitter.advance(to: timedPoint(
            x: Float(candidateCount),
            timestamp: Double(candidateCount),
            sourceDistance: Double(candidateCount),
            direction: 0,
            phase: .moved
        ))
        var cursor = try #require(proposed)
        var keys: [Int64] = []
        let first = try cursor.emitNextPage { keys.append($0.timeKey) }
        #expect(first.emittedCount == min(candidateCount, 512))
        #expect(first.hasMore == (candidateCount > 512))
        if first.hasMore {
            let second = try cursor.emitNextPage { keys.append($0.timeKey) }
            #expect(second.emittedCount == candidateCount - 512)
            #expect(!second.hasMore)
        }
        #expect(keys.count == candidateCount)
        #expect(keys.first == 1_000_000_000)
        #expect(keys.last == Int64(candidateCount) * 1_000_000_000)
        #expect(zip(keys, keys.dropFirst()).allSatisfy { $1 - $0 == 1_000_000_000 })
    }

    @Test
    func transactionalSingleCandidateStepIsCopyableAndRetryable() throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 0.1)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        let proposed = try emitter.advance(to: timedPoint(
            x: 3,
            timestamp: 0.3,
            sourceDistance: 3,
            direction: 0,
            phase: .moved
        ))
        let source = try #require(proposed)
        let firstProposal = try source.nextCandidate()
        let retryProposal = try source.nextCandidate()
        let first = try #require(firstProposal)
        let retry = try #require(retryProposal)
        #expect(first == retry)
        let secondProposal = try first.continuation.nextCandidate()
        let second = try #require(secondProposal)
        #expect(first.candidate.timeKey == 100_000_000)
        #expect(second.candidate.timeKey == 200_000_000)
        #expect(source.remainingCandidateCount == 3)
    }

    @Test
    func copiedOrAbandonedContinuationCannotMutateAuthoritativeState() throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 1.0 / 240)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        let firstResult = try emitter.advance(to: timedPoint(
            x: 513,
            timestamp: 513.0 / 240,
            sourceDistance: 513,
            direction: 0.513,
            phase: .moved
        ))
        var firstCursor = try #require(firstResult)
        var copiedCursor = firstCursor
        let emitterAfterAdvance = emitter

        var firstKeys: [Int64] = []
        var copiedKeys: [Int64] = []
        let firstPage = try firstCursor.emitNextPage {
            firstKeys.append($0.timeKey)
        }
        let copiedPage = try copiedCursor.emitNextPage {
            copiedKeys.append($0.timeKey)
        }

        #expect(firstPage.emittedCount == 512)
        #expect(firstPage.hasMore)
        #expect(copiedPage == firstPage)
        #expect(copiedKeys == firstKeys)
        #expect(emitter == emitterAfterAdvance)
        var suffixKeys: [Int64] = []
        let suffixPage = try firstCursor.emitNextPage {
            suffixKeys.append($0.timeKey)
        }
        #expect(suffixPage.emittedCount == 1)
        #expect(!suffixPage.hasMore)
        #expect(suffixKeys == [2_137_500_000])
        #expect(firstCursor.isComplete)

        let nextResult = try emitter.advance(to: timedPoint(
            x: 514,
            timestamp: 514.0 / 240,
            sourceDistance: 514,
            direction: 0.514,
            phase: .moved
        ))
        var next = try #require(nextResult)
        #expect(try drain(&next).map(\.timeKey) == [2_141_666_667])
    }

    @Test
    func throwingSinkRetriesAtTheFailedCandidateWithoutSkipOrDuplicate()
        throws
    {
        enum SinkFailure: Error { case rejected }

        var emitter = try TimedStrokeEmitter(timeInterval: 0.1)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        let result = try emitter.advance(to: timedPoint(
            x: 1,
            timestamp: 1,
            sourceDistance: 1,
            direction: 1,
            phase: .moved
        ))
        var cursor = try #require(result)
        var acceptedKeys: [Int64] = []

        #expect(throws: SinkFailure.rejected) {
            _ = try cursor.emitNextPage { candidate in
                if candidate.timeKey == 400_000_000 {
                    throw SinkFailure.rejected
                }
                acceptedKeys.append(candidate.timeKey)
            }
        }
        #expect(acceptedKeys == [100_000_000, 200_000_000, 300_000_000])

        _ = try cursor.emitNextPage { candidate in
            acceptedKeys.append(candidate.timeKey)
        }
        #expect(
            acceptedKeys
                == stride(from: Int64(100_000_000), through: 1_000_000_000,
                          by: 100_000_000).map { $0 }
        )
    }

    @Test
    func sourceDistanceInterpolationRetainsDoublePrecision() throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 1)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 1_000_000_000,
            direction: 0,
            phase: .began
        ))
        let result = try emitter.advance(to: timedPoint(
            x: 3,
            timestamp: 3,
            sourceDistance: 1_000_001_000,
            direction: 3,
            phase: .moved
        ))
        var cursor = try #require(result)
        let candidates = try drain(&cursor)

        #expect(candidates[0].distanceKey == 1_000_000_333_333_333)
        #expect(candidates[1].distanceKey == 1_000_000_666_666_667)
        #expect(candidates[2].distanceKey == 1_000_001_000_000_000)
    }

    @Test
    func canonicalKeysUseNearestEvenAtPositiveHalfwayValues() throws {
        var lower = try TimedStrokeEmitter(timeInterval: 10)
        var lowerBegin = try lower.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 0.000_000_5,
            direction: 0,
            phase: .began
        ))
        #expect(try drain(&lowerBegin)[0].distanceKey == 0)
        var lowerFinish = try lower.finish(at: timedPoint(
            x: 0,
            timestamp: 0.000_000_000_5,
            sourceDistance: 0.000_000_5,
            direction: 0,
            phase: .ended
        ))
        #expect(try drain(&lowerFinish)[0].timeKey == 0)

        var upper = try TimedStrokeEmitter(timeInterval: 10)
        var upperBegin = try upper.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 0.000_001_5,
            direction: 0,
            phase: .began
        ))
        #expect(try drain(&upperBegin)[0].distanceKey == 2)
        var upperFinish = try upper.finish(at: timedPoint(
            x: 0,
            timestamp: 0.000_000_001_5,
            sourceDistance: 0.000_001_5,
            direction: 0,
            phase: .ended
        ))
        #expect(try drain(&upperFinish)[0].timeKey == 2)
    }

    @Test
    func decimalIntervalBoundaryDoesNotLoseTheCoincidentTick() throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 0.1)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        let result = try emitter.advance(to: timedPoint(
            x: 3,
            timestamp: 0.3,
            sourceDistance: 3,
            direction: 0.3,
            phase: .moved
        ))
        var cursor = try #require(result)

        let candidates = try drain(&cursor)
        #expect(
            candidates.map(\.timeKey)
                == [100_000_000, 200_000_000, 300_000_000]
        )
        #expect(candidates.allSatisfy {
            $0.sample.timestamp == $0.relativeStrokeTime
        })
    }

    @Test
    func invalidBeginIsAtomicAndEmitterRemainsReusable() throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 0.5)
        let initial = emitter

        #expect(throws: TimedStrokeEmitterError.invalidPoint) {
            _ = try emitter.begin(at: timedPoint(
                x: 0,
                timestamp: 0,
                sourceDistance: -0.25,
                direction: 0,
                phase: .began
            ))
        }
        #expect(emitter == initial)

        #expect(throws: TimedStrokeEmitterError.canonicalKeyOverflow) {
            _ = try emitter.begin(at: timedPoint(
                x: 0,
                timestamp: 0,
                sourceDistance: 10_000_000_000_000,
                direction: 0,
                phase: .began
            ))
        }
        #expect(emitter == initial)

        var valid = try emitter.begin(at: timedPoint(
            x: 1,
            timestamp: 1,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        #expect(try drain(&valid).map(\.kind) == [.begin])
    }

    @Test
    func relativeTimeKeyOverflowFailsBeforeAnyStateMutation() throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 1)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        let before = emitter

        #expect(throws: TimedStrokeEmitterError.canonicalKeyOverflow) {
            _ = try emitter.advance(to: timedPoint(
                x: 1,
                timestamp: 10_000_000_000,
                sourceDistance: 1,
                direction: 0,
                phase: .moved
            ))
        }
        #expect(emitter == before)

        let result = try emitter.advance(to: timedPoint(
            x: 1,
            timestamp: 1,
            sourceDistance: 1,
            direction: 0,
            phase: .moved
        ))
        var valid = try #require(result)
        #expect(try drain(&valid).map(\.timeKey) == [1_000_000_000])
    }

    @Test
    func arbitraryInputPartitionsProduceTheSameCandidateStream() throws {
        var points: [TimedStrokePoint] = []
        for index in 0...12 {
            let phase: StrokePhase = index == 0 ? .began : .moved
            let kind: StrokeSampleKind = index.isMultiple(of: 2)
                ? .actual
                : .coalesced
            points.append(timedPoint(
                x: Float(index),
                y: Float(index % 3),
                pressure: Float(index) / 12,
                timestamp: 40 + Double(index) * 0.07,
                sourceDistance: Double(index) * 1.25,
                direction: Float(index) * 0.2,
                phase: phase,
                kind: kind
            ))
        }

        let unpartitioned = try emitTrace(points, partitionSizes: [12])
        let partitioned = try emitTrace(points, partitionSizes: [1, 4, 2, 5])
        let singletons = try emitTrace(
            points,
            partitionSizes: Array(repeating: 1, count: 12)
        )

        #expect(partitioned == unpartitioned)
        #expect(singletons == unpartitioned)
    }

    @Test
    func authoritativeAndPredictionEntryPointsRejectCrossedStreamsAtomically()
        throws
    {
        var emitter = try TimedStrokeEmitter(timeInterval: 0.1)
        _ = try emitter.begin(at: timedPoint(
            x: 0,
            timestamp: 0,
            sourceDistance: 0,
            direction: 0,
            phase: .began
        ))
        let before = emitter

        #expect(throws: TimedStrokeEmitterError.invalidProvenance) {
            _ = try emitter.advance(to: timedPoint(
                x: 1,
                timestamp: 0.2,
                sourceDistance: 1,
                direction: 0,
                phase: .moved,
                kind: .predicted
            ))
        }
        #expect(emitter == before)
        #expect(throws: TimedStrokeEmitterError.invalidProvenance) {
            _ = try emitter.advance(to: timedPoint(
                x: 1,
                timestamp: 0.2,
                sourceDistance: 1,
                direction: 0,
                phase: .moved,
                kind: .estimatedUpdate
            ))
        }
        #expect(emitter == before)
        #expect(throws: TimedStrokeEmitterError.invalidProvenance) {
            _ = try emitter.prediction(to: timedPoint(
                x: 1,
                timestamp: 0.2,
                sourceDistance: 1,
                direction: 0,
                phase: .moved,
                kind: .actual
            ))
        }
        #expect(emitter == before)
    }
}

private func drain(
    _ cursor: inout TimedStrokeEmissionCursor
) throws -> [StrokeEmissionCandidate] {
    var result: [StrokeEmissionCandidate] = []
    while !cursor.isComplete {
        _ = try cursor.emitNextPage { result.append($0) }
    }
    return result
}

private func emitTrace(
    _ points: [TimedStrokePoint],
    partitionSizes: [Int]
) throws -> [StrokeEmissionCandidate] {
    var emitter = try TimedStrokeEmitter(timeInterval: 0.1)
    var result: [StrokeEmissionCandidate] = []
    var begin = try emitter.begin(at: points[0])
    result += try drain(&begin)
    var index = 1
    for size in partitionSizes {
        let end = min(points.count, index + size)
        while index < end {
            if var cursor = try emitter.advance(to: points[index]) {
                result += try drain(&cursor)
            }
            index += 1
        }
    }
    while index < points.count {
        if var cursor = try emitter.advance(to: points[index]) {
            result += try drain(&cursor)
        }
        index += 1
    }
    return result
}

private func emitPredictionTrace(
    _ points: [TimedStrokePoint],
    partitionSizes: [Int]
) throws -> [StrokeEmissionCandidate] {
    var authoritative = try TimedStrokeEmitter(timeInterval: 0.1)
    _ = try authoritative.begin(at: timedPoint(
        x: 0,
        timestamp: 0,
        sourceDistance: 0,
        direction: 0,
        phase: .began
    ))
    var prediction = authoritative
    var result: [StrokeEmissionCandidate] = []
    var index = 0
    for size in partitionSizes {
        guard size > 0, index < points.count else { continue }
        let endpointIndex = min(points.count - 1, index + size - 1)
        if var cursor = try prediction.prediction(to: points[endpointIndex]) {
            result += try drain(&cursor)
        }
        index = endpointIndex + 1
    }
    while index < points.count {
        if var cursor = try prediction.prediction(to: points[index]) {
            result += try drain(&cursor)
        }
        index += 1
    }
    return result
}

private func expectEquivalentPredictionGeometry(
    _ actual: [StrokeEmissionCandidate],
    _ expected: [StrokeEmissionCandidate]
) {
    #expect(actual.count == expected.count)
    #expect(actual.map(\.timeKey) == expected.map(\.timeKey))
    #expect(actual.map(\.distanceKey) == expected.map(\.distanceKey))
    #expect(actual.map(\.kind) == expected.map(\.kind))
    #expect(actual.map(\.provenance) == expected.map(\.provenance))
    for (actualCandidate, expectedCandidate) in zip(actual, expected) {
        #expect(
            abs(actualCandidate.position.x - expectedCandidate.position.x)
                < 0.000_001
        )
        #expect(
            abs(actualCandidate.position.y - expectedCandidate.position.y)
                < 0.000_001
        )
        #expect(
            abs(
                actualCandidate.sourceDistance
                    - expectedCandidate.sourceDistance
            ) < 0.000_000_001
        )
        #expect(
            abs(actualCandidate.direction - expectedCandidate.direction)
                < 0.000_001
        )
    }
}

private func timedPoint(
    x: Float,
    y: Float = 0,
    pressure: Float = 0.5,
    velocity: Float = 12,
    artisticVelocity: Float? = nil,
    timestamp: TimeInterval,
    sourceDistance: Double,
    direction: Float,
    phase: StrokePhase,
    kind: StrokeSampleKind = .actual,
    altitude: Float? = nil,
    azimuth: Float? = nil,
    roll: Float? = nil,
    tangentialPressure: Float? = nil,
    deviceIdentifier: UInt64? = nil,
    estimationUpdateIndex: Int? = nil,
    estimatedProperties: StrokeEstimatedProperties = [],
    estimatedPropertiesExpectingUpdates: StrokeEstimatedProperties = []
) -> TimedStrokePoint {
    TimedStrokePoint(
        sample: InterpolatedStrokeSample(
            position: WorldPoint(x: x, y: y),
            pressure: pressure,
            timestamp: timestamp,
            altitude: altitude,
            azimuth: azimuth,
            roll: roll,
            velocity: velocity,
            artisticVelocity: artisticVelocity ?? velocity,
            phase: phase,
            source: .pencil,
            kind: kind,
            capabilities: [
                .pressure, .altitude, .azimuth, .roll, .tangentialPressure,
            ],
            tangentialPressure: tangentialPressure,
            deviceIdentifier: deviceIdentifier,
            estimationUpdateIndex: estimationUpdateIndex,
            estimatedProperties: estimatedProperties,
            estimatedPropertiesExpectingUpdates:
                estimatedPropertiesExpectingUpdates
        ),
        sourceDistance: sourceDistance,
        direction: direction
    )
}
