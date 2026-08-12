import Foundation
import PatternEngine
@testable import MetalRenderer
import Testing

@Suite("Append-only authoritative stroke coordinator")
struct StrokeRenderCoordinatorTests {
    @Test
    @MainActor
    func generatorAndProjectionExecuteOffMainActor() async throws {
        let budget = try DepositionFrameBudget(
            cpuPreparationNanoseconds: 1_500_000,
            maximumAuthoritativeInstances: 32,
            maximumPredictedInstances: 16,
            maximumPendingAuthoritativeInstances: 128,
            maximumPendingPredictedInstances: 32,
            inFlightUploadBufferCount: 3
        )
        let executor = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: 120
        )
        let configuration = StrokePreparationConfiguration(
            program: try BrushProgramCompiler.compile(
                coordinatorInkDefinition()
            ),
            nominalDiameter: 10,
            color: .black,
            seed: 7,
            viewport: ViewportTransform(
                drawableSize: PatternSize(width: 512, height: 512),
                worldCenter: WorldPoint(x: 256, y: 256)
            ),
            tilingStrategy: TilingStrategy(
                kind: .grid,
                tileSize: PatternSize(width: 512, height: 512)
            )
        )

        let prepared = try await executor.beginPreparedStroke(
            generation: 77,
            configuration: configuration,
            actualSamples: [sample(index: 0, phase: .began)]
        )

        #expect(!prepared.logicalDabs.isEmpty)
        #expect(prepared.authoritativeInstanceCount > 0)
        #expect(!prepared.dirtyRegions.isEmpty)
        #expect(!prepared.executorProbe.generatorRanOnMainThread)
        #expect(!prepared.executorProbe.projectionRanOnMainThread)
        #expect(prepared.generation == 77)
    }

    @Test
    @MainActor
    func preparedProjectionIsBorrowedOneFrameUntilSubmissionAck()
        async throws
    {
        let budget = try DepositionFrameBudget(
            cpuPreparationNanoseconds: 1_500_000,
            maximumAuthoritativeInstances: 2,
            maximumPredictedInstances: 1,
            maximumPendingAuthoritativeInstances: 16,
            maximumPendingPredictedInstances: 4,
            inFlightUploadBufferCount: 3
        )
        let executor = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: 120
        )
        let configuration = StrokePreparationConfiguration(
            program: try BrushProgramCompiler.compile(
                coordinatorInkDefinition()
            ),
            nominalDiameter: 10,
            color: .black,
            seed: 7,
            viewport: ViewportTransform(
                drawableSize: PatternSize(width: 512, height: 512),
                worldCenter: WorldPoint(x: 256, y: 256)
            ),
            tilingStrategy: TilingStrategy(
                kind: .grid,
                tileSize: PatternSize(width: 512, height: 512)
            )
        )
        var prepared: StrokePreparedDepositionBatch? = try await executor
            .beginPreparedStroke(
                generation: 88,
                configuration: configuration,
                actualSamples: [sample(index: 0, phase: .began)]
            )
        var projectedCount = 0
        var frameCount = 0
        while let frame = prepared {
            #expect(frame.authoritativeInstanceCount <= 2)
            projectedCount += frame.authoritativeInstanceCount
            guard let token = frame.frameToken else { break }
            frameCount += 1
            guard case let .prepared(next)? = await executor
                .acknowledgePreparedFrame(
                    generation: 88,
                    frameToken: token
                )
            else {
                prepared = nil
                continue
            }
            prepared = next
        }

        #expect(projectedCount > 0)
        #expect(frameCount > 0)
        // A bounded frame may now contain only path-advancement work before
        // the next accepted projection, so frame count is not a dab count.
        #expect(frameCount <= 16)
        var finishing: StrokePreparedDepositionBatch? = try await executor
            .finishPreparedStroke(
                generation: 88,
                actualSamples: [sample(index: 1, phase: .ended)]
            )
        while let frame = finishing,
              let token = frame.frameToken
        {
            guard case let .prepared(next)? = await executor
                .acknowledgePreparedFrame(
                    generation: 88,
                    frameToken: token
                )
            else {
                finishing = nil
                continue
            }
            finishing = next
        }
        try await executor.requestCommit(generation: 88)
        #expect(await executor.isCommitReady(generation: 88))
    }

    @Test
    @MainActor
    func predictionIsPreparedOffMainAndReplacesOnlySpeculativeWork()
        async throws
    {
        let budget = try DepositionFrameBudget(
            cpuPreparationNanoseconds: 1_500_000,
            maximumAuthoritativeInstances: 32,
            maximumPredictedInstances: 16,
            maximumPendingAuthoritativeInstances: 128,
            maximumPendingPredictedInstances: 32,
            inFlightUploadBufferCount: 3
        )
        let executor = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: 120
        )
        let configuration = StrokePreparationConfiguration(
            program: try BrushProgramCompiler.compile(
                coordinatorInkDefinition()
            ),
            nominalDiameter: 10,
            color: .black,
            seed: 7,
            viewport: ViewportTransform(
                drawableSize: PatternSize(width: 512, height: 512),
                worldCenter: WorldPoint(x: 256, y: 256)
            ),
            tilingStrategy: TilingStrategy(
                kind: .grid,
                tileSize: PatternSize(width: 512, height: 512)
            )
        )
        let began = try await executor.beginPreparedStroke(
            generation: 89,
            configuration: configuration,
            actualSamples: [sample(index: 0, phase: .began)]
        )
        if let token = began.frameToken {
            _ = await executor.acknowledgePreparedFrame(
                generation: 89,
                frameToken: token
            )
        }

        let result = await executor.process(
            .replacePrediction(
                generation: 89,
                samples: [predictedSample(index: 3)],
                acceptedCount: 1
            )
        )
        guard case let .prepared(prediction) = result else {
            Issue.record("Expected an off-main prepared prediction batch")
            return
        }

        #expect(!prediction.logicalDabs.isEmpty)
        #expect(prediction.authoritativeInstanceCount == 0)
        #expect(prediction.predictedInstanceCount > 0)
        #expect(!prediction.dirtyRegions.isEmpty)
        #expect(!prediction.executorProbe.generatorRanOnMainThread)
        #expect(!prediction.executorProbe.projectionRanOnMainThread)
        #expect(prediction.predictionAdmission != nil)
    }

    @Test(arguments: [1, 10, 1_000, 100_000])
    func everyOrdinalIsReturnedAndSubmittedExactlyOnce(
        eventCount: Int
    ) throws {
        let coordinator = try makeCoordinator(
            capacity: eventCount == 100_000 ? 12_288 : 64
        )
        var submittedOrdinals: [UInt64] = []
        submittedOrdinals.reserveCapacity(eventCount + 2)

        let began = try commitBegin(
            [sample(index: 0, phase: .began)],
            coordinator: coordinator
        )
        try submitAll(
            began,
            coordinator: coordinator,
            ordinals: &submittedOrdinals
        )
        if eventCount > 1 {
            for index in 1..<eventCount {
                let emitted = try commitAppend(
                    [sample(index: index, phase: .moved)],
                    coordinator: coordinator
                )
                #expect(emitted.work.count <= 4)
                try submitAll(
                    emitted,
                    coordinator: coordinator,
                    ordinals: &submittedOrdinals
                )
            }
        }

        #expect(
            submittedOrdinals
                == Array(0..<UInt64(submittedOrdinals.count))
        )
        #expect(Set(submittedOrdinals).count == submittedOrdinals.count)
        #expect(coordinator.snapshot.authoritativeQueueDepth == 0)
        #expect(
            coordinator.snapshot.authoritativeSubmittedDabCount
                == UInt64(submittedOrdinals.count)
        )
        #expect(coordinator.snapshot.maximumReturnedDabCount <= 4)
        #expect(coordinator.snapshot.retainedCompletedDabCount == 0)
        #expect(coordinator.snapshot.authoritativeQueueHighWater <= 4)
    }

    @Test
    func capacityFailureIsTransactionalAndHighWaterIsBounded() throws {
        let coordinator = try makeCoordinator(capacity: 1)
        let first = try commitBegin(
            [sample(index: 0, phase: .began)],
            coordinator: coordinator
        )
        let before = coordinator.snapshot
        let inputBefore = coordinator.inputDeriverSnapshot

        #expect(throws: AuthoritativeStrokeQueueError.self) {
            _ = try coordinator.prepareAppend(
                actualSamples: [sample(index: 3, phase: .moved)]
            )
        }

        #expect(coordinator.snapshot == before)
        #expect(coordinator.inputDeriverSnapshot == inputBefore)
        var ordinals: [UInt64] = []
        try submitAll(
            first,
            coordinator: coordinator,
            ordinals: &ordinals
        )
        #expect(coordinator.snapshot.authoritativeQueueHighWater == 1)
    }

    @Test
    func abandonedPreparedAppendLeavesExactStateAndRetryIsIdentical() throws {
        let coordinator = try makeCoordinator(capacity: 8)
        let began = try coordinator.prepareBegin(
            actualSamples: [sample(index: 0, phase: .began)]
        )
        try coordinator.commit(began)
        var ordinals: [UInt64] = []
        try submitAll(
            began.emission,
            coordinator: coordinator,
            ordinals: &ordinals
        )
        let before = coordinator.snapshot
        let inputBefore = coordinator.inputDeriverSnapshot

        let prepared = try coordinator.prepareAppend(
            actualSamples: [sample(index: 3, phase: .moved)]
        )
        try coordinator.abandon(prepared)
        #expect(coordinator.snapshot == before)
        #expect(coordinator.inputDeriverSnapshot == inputBefore)

        let retry = try coordinator.prepareAppend(
            actualSamples: [sample(index: 3, phase: .moved)]
        )
        #expect(retry.work == prepared.work)
        try coordinator.commit(retry)
        try submitAll(
            retry.emission,
            coordinator: coordinator,
            ordinals: &ordinals
        )
        #expect(coordinator.snapshot.commitMetadata.inputSampleCount == 2)
        #expect(coordinator.inputDeriverSnapshot != inputBefore)
    }

    @Test
    func abandonedAndEmptyTransactionsAreConsumedExactlyOnce() throws {
        let coordinator = try makeCoordinator(capacity: 8)
        let began = try coordinator.prepareBegin(
            actualSamples: [sample(index: 0, phase: .began)]
        )
        try coordinator.commit(began)
        var ordinals: [UInt64] = []
        try submitAll(
            began.emission,
            coordinator: coordinator,
            ordinals: &ordinals
        )

        let beforeAbandon = coordinator.snapshot
        let abandoned = try coordinator.prepareAppend(
            actualSamples: [sample(index: 3, phase: .moved)]
        )
        #expect(throws: StrokeRenderCoordinatorError.self) {
            _ = try coordinator.prepareAppend(
                actualSamples: [sample(index: 4, phase: .moved)]
            )
        }
        try coordinator.abandon(abandoned)
        #expect(coordinator.snapshot == beforeAbandon)
        #expect(throws: StrokeRenderCoordinatorError.self) {
            try coordinator.commit(abandoned)
        }
        #expect(throws: StrokeRenderCoordinatorError.self) {
            try coordinator.abandon(abandoned)
        }
        #expect(coordinator.snapshot == beforeAbandon)

        let empty = try coordinator.prepareAppend(actualSamples: [])
        try coordinator.commit(empty)
        let afterEmptyCommit = coordinator.snapshot
        #expect(throws: StrokeRenderCoordinatorError.self) {
            try coordinator.commit(empty)
        }
        #expect(afterEmptyCommit == coordinator.snapshot)
    }

    @Test
    func preparedTransactionCannotCrossCoordinatorOrigin() throws {
        let source = try makeCoordinator(capacity: 8)
        let foreign = try makeCoordinator(capacity: 8)
        let prepared = try source.prepareBegin(
            actualSamples: [sample(index: 0, phase: .began)]
        )
        let foreignBefore = foreign.snapshot

        #expect(throws: StrokeRenderCoordinatorError.self) {
            try foreign.commit(prepared)
        }
        #expect(throws: StrokeRenderCoordinatorError.self) {
            try foreign.abandon(prepared)
        }
        #expect(foreign.snapshot == foreignBefore)
        try source.abandon(prepared)
    }

    @Test
    func copiedPreparedCoordinatorCannotConsumeTransactionTwice() throws {
        let coordinator = try makeCoordinator(capacity: 8)
        let prepared = try coordinator.prepareBegin(
            actualSamples: [sample(index: 0, phase: .began)]
        )
        let commitAlias = coordinator
        let abandonAlias = coordinator

        try coordinator.commit(prepared)
        let committed = coordinator.snapshot
        #expect(throws: StrokeRenderCoordinatorError.self) {
            try commitAlias.commit(prepared)
        }
        #expect(throws: StrokeRenderCoordinatorError.self) {
            try abandonAlias.abandon(prepared)
        }
        #expect(commitAlias.snapshot == committed)
        #expect(abandonAlias.snapshot == committed)
    }

    @Test
    func submissionInterleavingInvalidatesPreparedTransactionWithoutCountLoss()
        throws
    {
        let coordinator = try makeCoordinator(capacity: 8)
        let began = try coordinator.prepareBegin(
            actualSamples: [sample(index: 0, phase: .began)]
        )
        try coordinator.commit(began)
        let candidate = try coordinator.prepareAppend(
            actualSamples: [sample(index: 3, phase: .moved)]
        )
        let frame = try #require(
            try coordinator.prepareAuthoritativeFrame(maximumDabs: 8)
        )
        try coordinator.markAuthoritativeFrameSubmitted(frame)
        let afterSubmission = coordinator.snapshot

        #expect(throws: StrokeRenderCoordinatorError.self) {
            try coordinator.commit(candidate)
        }
        #expect(coordinator.snapshot == afterSubmission)
        #expect(afterSubmission.authoritativeSubmittedDabCount == 1)
        #expect(afterSubmission.commitMetadata.submittedDabCount == 1)
        #expect(afterSubmission.authoritativeQueueDepth == 0)
    }

    @Test
    func queueWrapsAfterPartialRetireWithoutDrainingToEmpty() throws {
        var queue = try AuthoritativeStrokeQueue(capacity: 5)
        try queue.append(queueWork(0..<4))
        let first = try #require(try queue.prepare(maximumCount: 2))
        #expect(first.work.map(\.ordinal) == [0, 1])
        try queue.retire(first)

        try queue.append(queueWork(4..<7))
        #expect(queue.count == 5)
        let wrapped = try #require(try queue.prepare(maximumCount: 3))
        #expect(wrapped.work.map(\.ordinal) == [2, 3, 4])
        try queue.retire(wrapped)
        #expect(queue.count == 2)

        try queue.append(queueWork(7..<9))
        let remainder = try #require(try queue.prepare(maximumCount: 5))
        #expect(remainder.work.map(\.ordinal) == [5, 6, 7, 8])
        try queue.retire(remainder)
        #expect(queue.submittedCount == 9)
        #expect(queue.isEmpty)
    }

    @Test
    func compactRetiredTransferAdvancesAccountingWithoutQueueStorage() throws {
        var queue = try AuthoritativeStrokeQueue(capacity: 4)

        try queue.preflightRetiredTransfer(
            startingOrdinal: 0,
            count: 4
        )
        queue.recordPrevalidatedRetiredTransfer(
            startingOrdinal: 0,
            count: 4
        )

        #expect(queue.isEmpty)
        #expect(queue.count == 0)
        #expect(queue.highWater == 4)
        #expect(queue.nextExpectedOrdinal == 4)
        #expect(queue.submittedCount == 4)
    }

    @Test
    func compactRetiredTransferRejectsCapacityOrdinalAndOverflowExactly()
        throws
    {
        let queue = try AuthoritativeStrokeQueue(capacity: 4)

        #expect(
            throws: AuthoritativeStrokeQueueError.capacityExceeded(
                current: 0,
                incoming: 5,
                maximum: 4
            )
        ) {
            try queue.preflightRetiredTransfer(
                startingOrdinal: 0,
                count: 5
            )
        }
        #expect(
            throws: AuthoritativeStrokeQueueError.noncontiguousOrdinal(
                expected: 0,
                actual: 1
            )
        ) {
            try queue.preflightRetiredTransfer(
                startingOrdinal: 1,
                count: 1
            )
        }
        #expect(throws: AuthoritativeStrokeQueueError.ordinalOverflow) {
            try queue.preflightRetiredTransfer(
                startingOrdinal: UInt64.max,
                count: 1
            )
        }
    }

    @Test
    func replaceableActualInputIsRejectedTransactionally() throws {
        let coordinator = try makeCoordinator(capacity: 8)
        let began = try commitBegin(
            [sample(index: 0, phase: .began)],
            coordinator: coordinator
        )
        var ordinals: [UInt64] = []
        try submitAll(
            began,
            coordinator: coordinator,
            ordinals: &ordinals
        )
        let before = coordinator.snapshot
        let replaceable = StrokeSample(
            position: ScreenPoint(x: 1, y: 256),
            pressure: 0.5,
            timestamp: 1.0 / 240,
            phase: .moved,
            source: .pencil,
            kind: .actual,
            capabilities: [.pressure],
            estimationUpdateIndex: 1,
            estimatedProperties: [.pressure],
            estimatedPropertiesExpectingUpdates: [.pressure]
        )

        #expect(throws: StrokeRenderCoordinatorError.invalidAuthoritativeSample) {
            _ = try coordinator.prepareAppend(actualSamples: [replaceable])
        }
        #expect(coordinator.snapshot == before)
    }

    @Test
    func settledReplayTransferInstallsOnlyAfterDownstreamAcceptance()
        throws
    {
        let coordinator = try makeCoordinator(capacity: 16)
        let before = coordinator.snapshot
        let chunks = settledReplayChunks(
            samples: [
                sample(index: 0, phase: .began),
                sample(index: 2, phase: .moved),
            ],
            generator: coordinator.generatorSnapshot,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let expectedGenerator = try #require(
            chunks.last?.generatorSnapshotAfterSample
        )
        var expectedDeriver = coordinator.inputDeriverSnapshot
        for chunk in chunks {
            _ = expectedDeriver.rederive(chunk.sample)
        }

        let prepared = try prepareSettledReplayTransfer(
            chunks,
            coordinator: coordinator
        )

        #expect(coordinator.snapshot == before)
        #expect(coordinator.generatorSnapshot != expectedGenerator)
        try coordinator.reserveForDownstreamAcceptance(
            prepared,
            retireAfterAcceptance: true
        )
        #expect(coordinator.snapshot == before)

        coordinator.finalizeAndRetireAfterDownstreamAcceptance(prepared)

        #expect(coordinator.generatorSnapshot == expectedGenerator)
        #expect(coordinator.inputDeriverSnapshot == expectedDeriver)
        #expect(coordinator.snapshot.authoritativeQueueDepth == 0)
        #expect(
            coordinator.snapshot.authoritativeSubmittedDabCount
                == UInt64(prepared.work.count)
        )
        #expect(
            coordinator.snapshot.commitMetadata.inputSampleCount
                == UInt64(chunks.count)
        )
        #expect(
            coordinator.snapshot.commitMetadata.emittedDabCount
                == UInt64(prepared.work.count)
        )
        #expect(
            coordinator.snapshot.commitMetadata.lastEmittedOrdinal
                == prepared.work.last?.ordinal
        )
    }

    @Test
    func settledReplayTransferCanPromoteActorApprovedEstimatedMetadata()
        throws
    {
        let coordinator = try makeCoordinator(capacity: 16)
        let estimated = StrokeSample(
            position: ScreenPoint(x: 0, y: 256),
            pressure: 0.5,
            timestamp: 0,
            phase: .began,
            source: .pencil,
            kind: .actual,
            capabilities: [.pressure],
            estimationUpdateIndex: 42,
            estimatedProperties: [.pressure],
            estimatedPropertiesExpectingUpdates: [.pressure]
        )
        let chunks = settledReplayChunks(
            samples: [estimated],
            generator: coordinator.generatorSnapshot,
            inputDeriver: coordinator.inputDeriverSnapshot
        )

        let prepared = try prepareSettledReplayTransfer(
            chunks,
            coordinator: coordinator
        )
        try coordinator.reserveForDownstreamAcceptance(
            prepared,
            retireAfterAcceptance: true
        )
        coordinator.finalizeAndRetireAfterDownstreamAcceptance(prepared)

        #expect(coordinator.snapshot.commitMetadata.inputSampleCount == 1)
        #expect(
            coordinator.snapshot.commitMetadata.emittedDabCount
                == UInt64(prepared.work.count)
        )
    }

    @Test
    func settledReplayTransferAcceptsTerminalGeneratorReset() throws {
        let coordinator = try makeCoordinator(capacity: 16)
        let beganChunks = settledReplayChunks(
            samples: [sample(index: 0, phase: .began)],
            generator: coordinator.generatorSnapshot,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let began = try prepareSettledReplayTransfer(
            beganChunks,
            coordinator: coordinator
        )
        try coordinator.reserveForDownstreamAcceptance(
            began,
            retireAfterAcceptance: true
        )
        coordinator.finalizeAndRetireAfterDownstreamAcceptance(began)

        let endedChunks = settledReplayChunks(
            samples: [sample(index: 2, phase: .ended)],
            generator: coordinator.generatorSnapshot,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let endedGenerator = try #require(
            endedChunks.last?.generatorSnapshotAfterSample
        )
        #expect(endedGenerator.emittedDabCount == 0)

        let ended = try prepareSettledReplayTransfer(
            endedChunks,
            coordinator: coordinator
        )
        try coordinator.reserveForDownstreamAcceptance(
            ended,
            retireAfterAcceptance: true
        )
        coordinator.finalizeAndRetireAfterDownstreamAcceptance(ended)

        #expect(coordinator.generatorSnapshot == endedGenerator)
        #expect(coordinator.snapshot.commitMetadata.inputSampleCount == 2)
        #expect(throws: StrokeRenderCoordinatorError.invalidLifecycle) {
            _ = try coordinator.prepareAppend(actualSamples: [])
        }
    }

    @Test
    func settledReplayTransferRejectsMismatchedFrozenInputCheckpoint()
        throws
    {
        let coordinator = try makeCoordinator(capacity: 16)
        let before = coordinator.snapshot
        let valid = settledReplayChunks(
            samples: [sample(index: 0, phase: .began)],
            generator: coordinator.generatorSnapshot,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let validChunk = try #require(valid.first)
        var mismatchedInputDeriver = coordinator.inputDeriverSnapshot
        _ = mismatchedInputDeriver.derive(
            sample(index: 4, phase: .began),
            viewport: coordinatorViewport()
        )
        let inputMismatch = TransientStrokeChunk(
            sample: validChunk.sample,
            dabs: validChunk.dabs,
            generatorSnapshotAfterSample:
                validChunk.generatorSnapshotAfterSample,
            inputDeriverSnapshotBeforeSample: mismatchedInputDeriver
        )
        #expect(throws: StrokeRenderCoordinatorError.self) {
            _ = try prepareSettledReplayTransfer(
                [inputMismatch],
                coordinator: coordinator
            )
        }
        #expect(coordinator.snapshot == before)

        let retry = try prepareSettledReplayTransfer(
            valid,
            coordinator: coordinator
        )
        try coordinator.abandon(retry)
        #expect(coordinator.snapshot == before)
    }

    @Test
    func settledReplayTransferRejectsMovedSampleBeforeBegin() throws {
        let coordinator = try makeCoordinator(capacity: 16)
        let before = coordinator.snapshot
        let invalid = settledReplayChunks(
            samples: [sample(index: 2, phase: .moved)],
            generator: coordinator.generatorSnapshot,
            inputDeriver: coordinator.inputDeriverSnapshot
        )

        #expect(throws: StrokeRenderCoordinatorError.invalidLifecycle) {
            _ = try prepareSettledReplayTransfer(
                invalid,
                coordinator: coordinator
            )
        }
        #expect(coordinator.snapshot == before)

        let valid = settledReplayChunks(
            samples: [sample(index: 0, phase: .began)],
            generator: coordinator.generatorSnapshot,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let retry = try prepareSettledReplayTransfer(
            valid,
            coordinator: coordinator
        )
        try coordinator.abandon(retry)
        #expect(coordinator.snapshot == before)
    }

    @Test
    func settledReplayTransferRejectsWrongEndingGeneratorState()
        throws
    {
        let coordinator = try makeCoordinator(capacity: 16)
        let before = coordinator.snapshot
        let valid = settledReplayChunks(
            samples: [sample(index: 0, phase: .began)],
            generator: coordinator.generatorSnapshot,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let validChunk = try #require(valid.first)
        let wrongEnd = TransientStrokeChunk(
            sample: validChunk.sample,
            dabs: validChunk.dabs,
            generatorSnapshotAfterSample: coordinator.generatorSnapshot,
            inputDeriverSnapshotBeforeSample:
                validChunk.inputDeriverSnapshotBeforeSample
        )

        #expect(
            throws: StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        ) {
            _ = try prepareSettledReplayTransfer(
                [wrongEnd],
                coordinator: coordinator
            )
        }
        #expect(coordinator.snapshot == before)

        let retry = try prepareSettledReplayTransfer(
            valid,
            coordinator: coordinator
        )
        try coordinator.abandon(retry)
        #expect(coordinator.snapshot == before)
    }

    @Test
    func settledReplayTransferRejectsDiscontinuousOrPredictedDabs()
        throws
    {
        let coordinator = try makeCoordinator(capacity: 16)
        let before = coordinator.snapshot
        let valid = settledReplayChunks(
            samples: [sample(index: 0, phase: .began)],
            generator: coordinator.generatorSnapshot,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let validChunk = try #require(valid.first)
        let discontinuous = TransientStrokeChunk(
            sample: validChunk.sample,
            dabs: [
                TransientStrokeDab(
                    attributes: testDab(ordinal: 1),
                    projectedInstanceCount: 1
                ),
            ],
            generatorSnapshotAfterSample:
                validChunk.generatorSnapshotAfterSample,
            inputDeriverSnapshotBeforeSample:
                validChunk.inputDeriverSnapshotBeforeSample
        )
        #expect(
            throws: StrokeRenderCoordinatorError.ordinalDiscontinuity(
                expected: 0,
                actual: 1
            )
        ) {
            _ = try prepareSettledReplayTransfer(
                [discontinuous],
                coordinator: coordinator
            )
        }
        #expect(coordinator.snapshot == before)

        let predicted = TransientStrokeChunk(
            sample: validChunk.sample,
            dabs: [
                TransientStrokeDab(
                    attributes: testDab(ordinal: 0, isPredicted: true),
                    projectedInstanceCount: 1
                ),
            ],
            generatorSnapshotAfterSample:
                validChunk.generatorSnapshotAfterSample,
            inputDeriverSnapshotBeforeSample:
                validChunk.inputDeriverSnapshotBeforeSample
        )
        #expect(
            throws: StrokeRenderCoordinatorError.invalidAuthoritativeSample
        ) {
            _ = try prepareSettledReplayTransfer(
                [predicted],
                coordinator: coordinator
            )
        }
        #expect(coordinator.snapshot == before)

        let retry = try prepareSettledReplayTransfer(
            valid,
            coordinator: coordinator
        )
        try coordinator.abandon(retry)
        #expect(coordinator.snapshot == before)
    }

    @Test
    func preparedWorkRetiresOnlyAfterSuccessfulSubmission() throws {
        let coordinator = try makeCoordinator(capacity: 8)
        _ = try commitBegin(
            [sample(index: 0, phase: .began)],
            coordinator: coordinator
        )
        let preparedCandidate = try coordinator
            .prepareAuthoritativeFrame(maximumDabs: 8)
        let prepared = try #require(preparedCandidate)

        #expect(throws: AuthoritativeStrokeQueueError.self) {
            _ = try coordinator.prepareAuthoritativeFrame(maximumDabs: 8)
        }
        coordinator.abandonAuthoritativeFrame(prepared)
        let retryCandidate = try coordinator
            .prepareAuthoritativeFrame(maximumDabs: 8)
        let retry = try #require(retryCandidate)
        #expect(retry.work == prepared.work)
        try coordinator.markAuthoritativeFrameSubmitted(retry)
        let exhausted = try coordinator.prepareAuthoritativeFrame(
            maximumDabs: 8
        )
        #expect(exhausted == nil)
        #expect(coordinator.snapshot.authoritativeQueueDepth == 0)
    }

    @Test
    func batchingPartitionsProduceIdenticalDabsAndCanonicalPixels() throws {
        let samples = (0..<128).map {
            sample(index: $0, phase: $0 == 0 ? .began : .moved)
        }
        let single = try makeCoordinator(capacity: 1_024)
        let partitioned = try makeCoordinator(capacity: 1_024)

        var singleWork = try commitBegin(
            [samples[0]],
            coordinator: single
        ).work
        singleWork += try commitAppend(
            Array(samples.dropFirst()),
            coordinator: single
        ).work

        var partitionedWork = try commitBegin(
            [samples[0]],
            coordinator: partitioned
        ).work
        let widths = [1, 7, 3, 19, 2, 31, 5, 11]
        var cursor = 1
        var widthIndex = 0
        while cursor < samples.count {
            let end = min(samples.count, cursor + widths[widthIndex % widths.count])
            partitionedWork += try commitAppend(
                Array(samples[cursor..<end]),
                coordinator: partitioned
            ).work
            cursor = end
            widthIndex += 1
        }

        #expect(partitionedWork == singleWork)
        #expect(
            partitioned.inputDeriverSnapshot
                == single.inputDeriverSnapshot
        )
        #expect(
            canonicalCoverage(for: partitionedWork)
                == canonicalCoverage(for: singleWork)
        )
    }

    @Test
    func cancelResetsCompleteInputStateBeforeRapidCoordinatorReuse() throws {
        let coordinator = try makeCoordinator(capacity: 64)
        _ = try commitBegin(
            [sample(index: 0, phase: .began)],
            coordinator: coordinator
        )
        _ = try commitAppend(
            [
                sample(index: 1, phase: .moved),
                sample(index: 4, phase: .moved),
            ],
            coordinator: coordinator
        )
        #expect(coordinator.inputDeriverSnapshot != BrushInputDeriver())

        coordinator.cancel()

        #expect(coordinator.inputDeriverSnapshot == BrushInputDeriver())
        let next = sample(index: 100, phase: .began)
        _ = try commitBegin([next], coordinator: coordinator)
        var expected = BrushInputDeriver()
        _ = expected.derive(next, viewport: coordinatorViewport())
        #expect(coordinator.inputDeriverSnapshot == expected)
    }

    @Test
    func stageCDirectionalBeginPromotesItsZeroDabCheckpoint() throws {
        let coordinator = try makeStageCCoordinator(
            program: stageCMetalTestProgram(
                id: "test.coordinator-stage-c-held-begin",
                usesTravelDirection: true
            ),
            capacity: 64
        )
        let initialGenerator = coordinator.generatorSnapshot
        let beganSample = stageCSample(x: 16, y: 256, phase: .began)
        let chunks = settledReplayChunks(
            samples: [beganSample],
            generator: initialGenerator,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let beganChunk = try #require(chunks.first)
        let heldGenerator = try #require(
            beganChunk.generatorSnapshotAfterSample
        )

        #expect(beganChunk.dabs.isEmpty)
        #expect(heldGenerator.emittedDabCount == 0)
        #expect(heldGenerator != initialGenerator)

        let transfer = try coordinator.prepareSettledReplayTransfer(
            chunks,
            trustedStartingGenerator: initialGenerator,
            trustedFinalGenerator: heldGenerator
        )
        try coordinator.reserveForDownstreamAcceptance(
            transfer,
            retireAfterAcceptance: true
        )
        coordinator.finalizeAndRetireAfterDownstreamAcceptance(transfer)
        #expect(coordinator.generatorSnapshot == heldGenerator)

        let moved = try commitAppend(
            [stageCSample(x: 48, y: 256, phase: .moved)],
            coordinator: coordinator
        )
        #expect(moved.work.first?.ordinal == 0)
        #expect(moved.work.allSatisfy { $0.dab.isPredicted == false })
    }

    @Test
    func stageCCompactTransferPagesValidationAndInstallsAtomically() throws {
        let coordinator = try makeStageCCoordinator(
            program: stageCMetalTestProgram(
                id: "test.coordinator-stage-c-compact-transfer"
            ),
            capacity: 64
        )
        let initialGenerator = coordinator.generatorSnapshot
        let chunks = settledReplayChunks(
            samples: [
                stageCSample(x: 16, y: 256, phase: .began),
                stageCSample(x: 48, y: 256, phase: .moved),
            ],
            generator: initialGenerator,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let expectedGenerator = try #require(
            chunks.last?.generatorSnapshotAfterSample
        )
        var expectedDeriver = coordinator.inputDeriverSnapshot
        for chunk in chunks {
            _ = expectedDeriver.rederive(chunk.sample)
        }
        let expectedDabCount = chunks.reduce(0) { $0 + $1.dabs.count }
        let expectedLastOrdinal = chunks.last?.dabs.last?.attributes.ordinal
        let before = coordinator.snapshot
        var cursor = try coordinator.beginSettledStageCTransfer(
            expectedChunkCount: 2,
            trustedStartingGenerator: initialGenerator,
            trustedFinalGenerator: expectedGenerator
        )
        var prepared: PreparedSettledStageCTransfer?
        var pageCount = 0

        while prepared == nil {
            let step = try coordinator.resumeSettledStageCTransfer(
                &cursor,
                chunks: chunks,
                maximumWorkUnits: 1
            )
            pageCount += 1
            switch step {
            case let .pending(consumedWorkUnits):
                #expect(consumedWorkUnits == 1)
                #expect(coordinator.snapshot == before)
                #expect(coordinator.generatorSnapshot == initialGenerator)
            case let .prepared(candidate, consumedWorkUnits):
                #expect(consumedWorkUnits == 1)
                prepared = candidate
            }
        }

        let candidate = try #require(prepared)
        #expect(pageCount == 4 + expectedDabCount)
        #expect(candidate.sampleCount == 2)
        #expect(candidate.dabCount == expectedDabCount)
        #expect(candidate.lastOrdinal == expectedLastOrdinal)
        #expect(coordinator.snapshot == before)
        try coordinator.reserveForDownstreamAcceptance(
            candidate,
            retireAfterAcceptance: true
        )
        #expect(coordinator.snapshot == before)

        coordinator.finalizeAndRetireAfterDownstreamAcceptance(candidate)

        #expect(coordinator.generatorSnapshot == expectedGenerator)
        #expect(coordinator.inputDeriverSnapshot == expectedDeriver)
        #expect(coordinator.snapshot.authoritativeQueueDepth == 0)
        #expect(
            coordinator.snapshot.authoritativeSubmittedDabCount
                == UInt64(expectedDabCount)
        )
        #expect(coordinator.snapshot.commitMetadata.inputSampleCount == 2)
        #expect(
            coordinator.snapshot.commitMetadata.emittedDabCount
                == UInt64(expectedDabCount)
        )
        #expect(
            coordinator.snapshot.commitMetadata.lastEmittedOrdinal
                == expectedLastOrdinal
        )
    }

    @Test
    func stageCCompactTransferBoundsZeroDabCheckpointWork() throws {
        let coordinator = try makeStageCCoordinator(
            program: stageCMetalTestProgram(
                id: "test.coordinator-stage-c-compact-zero-dab",
                usesTravelDirection: true
            ),
            capacity: 8
        )
        let initialGenerator = coordinator.generatorSnapshot
        let chunks = settledReplayChunks(
            samples: [stageCSample(x: 16, y: 256, phase: .began)],
            generator: initialGenerator,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let finalGenerator = try #require(
            chunks.first?.generatorSnapshotAfterSample
        )
        #expect(chunks.first?.dabs.isEmpty == true)
        var cursor = try coordinator.beginSettledStageCTransfer(
            expectedChunkCount: 1,
            trustedStartingGenerator: initialGenerator,
            trustedFinalGenerator: finalGenerator
        )

        let header = try coordinator.resumeSettledStageCTransfer(
            &cursor,
            chunks: chunks,
            maximumWorkUnits: 1
        )
        guard case let .pending(headerWork) = header else {
            Issue.record("zero-dab header unexpectedly completed transfer")
            return
        }
        #expect(headerWork == 1)

        let footer = try coordinator.resumeSettledStageCTransfer(
            &cursor,
            chunks: chunks,
            maximumWorkUnits: 1
        )
        guard case let .prepared(prepared, footerWork) = footer else {
            Issue.record("zero-dab footer did not complete transfer")
            return
        }
        #expect(footerWork == 1)
        #expect(prepared.sampleCount == 1)
        #expect(prepared.dabCount == 0)
        #expect(prepared.lastOrdinal == nil)
    }

    @Test
    func stageCCompactTransferRejectsChunkMutationAcrossPages() throws {
        let coordinator = try makeStageCCoordinator(
            program: stageCMetalTestProgram(
                id: "test.coordinator-stage-c-compact-stable-source",
                usesTravelDirection: true
            ),
            capacity: 8
        )
        let initialGenerator = coordinator.generatorSnapshot
        let firstChunks = settledReplayChunks(
            samples: [stageCSample(x: 16, y: 256, phase: .began)],
            generator: initialGenerator,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let replacementChunks = settledReplayChunks(
            samples: [stageCSample(x: 80, y: 256, phase: .began)],
            generator: initialGenerator,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let replacementFinal = try #require(
            replacementChunks.first?.generatorSnapshotAfterSample
        )
        #expect(firstChunks.first?.dabs.isEmpty == true)
        #expect(replacementChunks.first?.dabs.isEmpty == true)
        var cursor = try coordinator.beginSettledStageCTransfer(
            expectedChunkCount: 1,
            trustedStartingGenerator: initialGenerator,
            trustedFinalGenerator: replacementFinal
        )
        let header = try coordinator.resumeSettledStageCTransfer(
            &cursor,
            chunks: firstChunks,
            maximumWorkUnits: 1
        )
        guard case .pending = header else {
            Issue.record("chunk header unexpectedly completed transfer")
            return
        }

        #expect(
            throws: StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        ) {
            _ = try coordinator.resumeSettledStageCTransfer(
                &cursor,
                chunks: replacementChunks,
                maximumWorkUnits: 1
            )
        }
    }

    @Test
    func stageCDelayedCheckpointMutationIsRejectedBeforePublication()
        throws
    {
        let coordinator = try makeStageCCoordinator(
            program: stageCMetalTestProgram(
                id: "test.coordinator-stage-c-delayed-checkpoint",
                stabilization: .delayed(distance: 12)
            ),
            capacity: 64
        )
        let initialGenerator = coordinator.generatorSnapshot
        let valid = settledReplayChunks(
            samples: [stageCSample(x: 16, y: 256, phase: .began)],
            generator: initialGenerator,
            inputDeriver: coordinator.inputDeriverSnapshot
        )
        let validChunk = try #require(valid.first)
        let delayedGenerator = try #require(
            validChunk.generatorSnapshotAfterSample
        )
        #expect(validChunk.dabs.isEmpty)
        #expect(delayedGenerator.emittedDabCount == 0)
        #expect(delayedGenerator != initialGenerator)

        let omittingStabilizerState = TransientStrokeChunk(
            sample: validChunk.sample,
            dabs: validChunk.dabs,
            generatorSnapshotAfterSample: initialGenerator,
            inputDeriverSnapshotBeforeSample:
                validChunk.inputDeriverSnapshotBeforeSample
        )
        let before = coordinator.snapshot
        #expect(
            throws: StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        ) {
            _ = try coordinator.prepareSettledReplayTransfer([
                omittingStabilizerState,
            ], trustedStartingGenerator: initialGenerator,
            trustedFinalGenerator: delayedGenerator)
        }
        #expect(coordinator.snapshot == before)
        #expect(coordinator.generatorSnapshot == initialGenerator)

        let retry = try coordinator.prepareSettledReplayTransfer(
            valid,
            trustedStartingGenerator: initialGenerator,
            trustedFinalGenerator: delayedGenerator
        )
        try coordinator.abandon(retry)
        #expect(coordinator.snapshot == before)
    }

    @Test
    func stageCDirectionalBatchPartitionsPreserveDabsAndCheckpoint()
        throws
    {
        let program = try stageCMetalTestProgram(
            id: "test.coordinator-stage-c-batching",
            usesTravelDirection: true,
            maximumAngularStep: .pi / 6,
            baseSpacingFraction: 0.05
        )
        var samples: [StrokeSample] = []
        samples.reserveCapacity(96)
        for index in 0..<96 {
            let column = Float(index % 24)
            let row = Float(index / 24)
            samples.append(
                stageCSample(
                    x: 32 + column * 3,
                    y: 128 + row * 16,
                    phase: index == 0 ? .began : .moved
                )
            )
        }
        let single = try makeStageCCoordinator(
            program: program,
            capacity: 2_048
        )
        let partitioned = try makeStageCCoordinator(
            program: program,
            capacity: 2_048
        )

        var singleWork = try commitBegin(
            [samples[0]],
            coordinator: single
        ).work
        singleWork += try commitAppend(
            Array(samples.dropFirst()),
            coordinator: single
        ).work

        var partitionedWork = try commitBegin(
            [samples[0]],
            coordinator: partitioned
        ).work
        let widths = [1, 7, 3, 13, 2, 17, 5, 11]
        var cursor = 1
        var widthIndex = 0
        while cursor < samples.count {
            let end = min(
                samples.count,
                cursor + widths[widthIndex % widths.count]
            )
            partitionedWork += try commitAppend(
                Array(samples[cursor..<end]),
                coordinator: partitioned
            ).work
            cursor = end
            widthIndex += 1
        }

        #expect(partitionedWork == singleWork)
        #expect(partitioned.generatorSnapshot == single.generatorSnapshot)
        #expect(
            partitioned.inputDeriverSnapshot
                == single.inputDeriverSnapshot
        )
    }

    @Test
    func stageCCornerFailureRollsBackAndCoordinatorRemainsReusable()
        throws
    {
        let coordinator = try makeStageCCoordinator(
            program: stageCMetalTestProgram(
                id: "test.coordinator-stage-c-failure",
                usesTravelDirection: true,
                maximumAngularStep: .pi / 180,
                baseSpacingFraction: 0.05
            ),
            capacity: 2_048
        )
        _ = try commitBegin(
            [stageCSample(x: 40, y: 256, phase: .began)],
            coordinator: coordinator
        )
        _ = try commitAppend(
            [stageCSample(x: 80, y: 256, phase: .moved)],
            coordinator: coordinator
        )
        let beforeFailure = coordinator.generatorSnapshot
        let beforeSnapshot = coordinator.snapshot

        #expect(throws: BrushCornerEmitterError.capacityExceeded(
            requiredCandidateCount: 179,
            maximumCandidateCount:
                StrokeEmissionCandidateBuffer.maximumCount
        )) {
            _ = try coordinator.prepareAppend(
                actualSamples: [
                    stageCSample(x: 40, y: 256, phase: .moved),
                ]
            )
        }
        #expect(coordinator.generatorSnapshot == beforeFailure)
        #expect(coordinator.snapshot == beforeSnapshot)

        let retry = try commitAppend(
            [stageCSample(x: 120, y: 256, phase: .moved)],
            coordinator: coordinator
        )
        #expect(!retry.work.isEmpty)
        #expect(retry.work.first?.ordinal == beforeFailure.emittedDabCount)
    }

    @Test
    func completedBodyIsReducedToCompactCommitMetadata() throws {
        let coordinator = try makeCoordinator(capacity: 32)
        var ordinals: [UInt64] = []
        let began = try commitBegin(
            [sample(index: 0, phase: .began)],
            coordinator: coordinator
        )
        try submitAll(began, coordinator: coordinator, ordinals: &ordinals)
        for index in 1..<1_000 {
            let emitted = try commitAppend(
                [sample(index: index, phase: .moved)],
                coordinator: coordinator
            )
            try submitAll(
                emitted,
                coordinator: coordinator,
                ordinals: &ordinals
            )
        }

        let snapshot = coordinator.snapshot
        #expect(snapshot.authoritativeQueueDepth == 0)
        #expect(snapshot.retainedCompletedDabCount == 0)
        #expect(snapshot.commitMetadata.inputSampleCount == 1_000)
        #expect(
            snapshot.commitMetadata.emittedDabCount
                == UInt64(ordinals.count)
        )
        #expect(snapshot.commitMetadata.lastEmittedOrdinal == ordinals.last)
    }
}

private func makeCoordinator(
    capacity: Int
) throws -> StrokeRenderCoordinator {
    let definition = try coordinatorInkDefinition()
    let program = try BrushProgramCompiler.compile(definition)
    return try StrokeRenderCoordinator(
        program: program,
        nominalDiameter: 10,
        color: .black,
        seed: 7,
        viewport: coordinatorViewport(),
        authoritativeCapacity: capacity
    )
}

private func makeStageCCoordinator(
    program: BrushProgram,
    capacity: Int
) throws -> StrokeRenderCoordinator {
    try StrokeRenderCoordinator(
        program: program,
        nominalDiameter: 10,
        color: .black,
        seed: 7,
        viewport: coordinatorViewport(),
        authoritativeCapacity: capacity
    )
}

private func coordinatorViewport() -> ViewportTransform {
    ViewportTransform(
        drawableSize: PatternSize(width: 512, height: 512),
        worldCenter: WorldPoint(x: 256, y: 256)
    )
}

private func coordinatorInkDefinition() throws -> BrushDefinition {
    let one = BrushMappingDefinition(
        input: .pressure,
        response: .constant(1),
        scale: 1,
        offset: 0,
        lowerClamp: 1,
        upperClamp: 1,
        inverted: false,
        jitter: 0,
        missingInputValue: 1
    )
    let zero = BrushMappingDefinition(
        input: .pressure,
        response: .constant(0),
        scale: 1,
        offset: 0,
        lowerClamp: 0,
        upperClamp: 0,
        inverted: false,
        jitter: 0,
        missingInputValue: 0
    )
    return try BrushDefinition(
        id: BrushRecipeID("test.coordinator-ink"),
        metadata: BrushMetadata(displayName: "Coordinator Ink"),
        capabilities: [],
        resources: [],
        coverage: BrushCoverageDefinition(
            shapes: [
                BrushShapeLayerDefinition(
                    shape: .hardRound,
                    combination: .replace,
                    scale: 1,
                    rotation: 0,
                    offset: .zero
                ),
            ],
            grains: [],
            baseHardness: 1,
            aspectRatio: 1,
            tipThreshold: 0.01,
            antialiasing: true
        ),
        placement: BrushPlacementDefinition(
            baseSpacingFraction: 0.1,
            maximumSpacingFraction: 0.1,
            baseFlow: 1,
            strokeOpacity: 1,
            baseScatterFraction: 0,
            baseRotation: 0,
            baseJitterFraction: 0,
            baseOffset: .zero
        ),
        dynamics: BrushDynamicsDefinition(
            size: one,
            flow: one,
            opacity: one,
            spacing: one,
            rotation: zero,
            scatter: one,
            hardness: one,
            grain: one,
            offsetX: zero,
            offsetY: zero,
            hue: zero,
            saturation: zero,
            brightness: zero,
            secondaryColorMix: zero,
            noPressureNeutral: 1,
            randomization: .none
        ),
        color: BrushColorBehaviorDefinition(
            baseAdjustment: .identity,
            perStampJitter: BrushColorJitter(
                hue: 0,
                saturation: 0,
                brightness: 0,
                secondaryColorMix: 0
            ),
            perStrokeJitter: BrushColorJitter(
                hue: 0,
                saturation: 0,
                brightness: 0,
                secondaryColorMix: 0
            )
        ),
        material: BrushMaterialDefinition(
            accumulation: .flow,
            interaction: .none,
            edgeTreatment: .none,
            strength: 1,
            wetness: 0,
            bleedRadius: 0,
            softenPasses: 0,
            accumulationLimit: 1,
            interactionParameters: nil
        ),
        stabilization: 0,
        taper: .none,
        replayMode: .appendOnly,
        replayLimits: nil,
        seedPolicy: .fixed(7),
        limits: BrushDefinitionLimits(
            minimumDiameter: 1,
            maximumDiameter: 1_024,
            maximumOpacity: 1,
            maximumSpacingFraction: 1,
            maximumResourceDimension: 4_096,
            maximumResidentBytes: 64 * 1_024 * 1_024
        ),
        performanceIntent: .realtime120,
        compatibility: BrushCompatibilityMetadata(
            sourceSettingKeys: [],
            requiredSemanticKeys: []
        )
    )
}

private func sample(index: Int, phase: StrokePhase) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: Float(index), y: 256),
        pressure: 1,
        timestamp: TimeInterval(index) / 240,
        phase: phase,
        source: .mouse,
        kind: index.isMultiple(of: 3) ? .coalesced : .actual
    )
}

private func stageCSample(
    x: Float,
    y: Float,
    phase: StrokePhase,
    kind: StrokeSampleKind = .actual,
    estimationUpdateIndex: Int? = nil,
    estimatedProperties: StrokeEstimatedProperties = []
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: y),
        pressure: 1,
        timestamp: TimeInterval(x + y) / 240,
        phase: phase,
        source: .pencil,
        kind: kind,
        capabilities: [.pressure, .altitude, .azimuth],
        altitude: 0.7,
        azimuth: 0.8,
        estimationUpdateIndex: estimationUpdateIndex,
        estimatedProperties: estimatedProperties,
        estimatedPropertiesExpectingUpdates: estimatedProperties
    )
}

private func predictedSample(index: Int) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: Float(index), y: 256),
        pressure: 1,
        timestamp: TimeInterval(index) / 240,
        phase: .moved,
        source: .pencil,
        kind: .predicted,
        capabilities: [.pressure]
    )
}

private func settledReplayChunks(
    samples: [StrokeSample],
    generator initialGenerator: BrushStrokeGenerator,
    inputDeriver initialInputDeriver: BrushInputDeriver
) -> [TransientStrokeChunk] {
    var generator = initialGenerator
    var inputDeriver = initialInputDeriver
    return samples.map { sample in
        let inputDeriverBefore = inputDeriver
        let worldSample = inputDeriver.derive(
            sample,
            viewport: coordinatorViewport()
        )
        var logicalDabs: [LogicalDab] = []
        if sample.phase == .cancelled {
            generator.cancel()
        } else {
            logicalDabs += generator.currentSampleDabsUnchecked(worldSample)
        }
        return TransientStrokeChunk(
            sample: worldSample,
            dabs: logicalDabs.map {
                TransientStrokeDab(
                    attributes: $0,
                    projectedInstanceCount: 1
                )
            },
            generatorSnapshotAfterSample: generator,
            inputDeriverSnapshotBeforeSample: inputDeriverBefore
        )
    }
}

private func prepareSettledReplayTransfer(
    _ chunks: [TransientStrokeChunk],
    coordinator: StrokeRenderCoordinator
) throws -> PreparedStrokeCoordinatorEmission {
    guard let finalGenerator = chunks.last?.generatorSnapshotAfterSample else {
        throw StrokeRenderCoordinatorError.settledReplayCheckpointMismatch
    }
    return try coordinator.prepareSettledReplayTransfer(
        chunks,
        trustedStartingGenerator: coordinator.generatorSnapshot,
        trustedFinalGenerator: finalGenerator
    )
}

private func queueWork(_ ordinals: Range<Int>) -> [AuthoritativeStrokeWork] {
    ordinals.map { ordinal in
        AuthoritativeStrokeWork(dab: testDab(ordinal: UInt64(ordinal)))
    }
}

private func testDab(
    ordinal: UInt64,
    isPredicted: Bool = false
) -> LogicalDab {
    LogicalDab(
        position: WorldPoint(x: Float(ordinal), y: 0),
        brushToWorld: .identity,
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
        ordinal: ordinal,
        isPredicted: isPredicted
    )
}

private func submitAll(
    _ emission: StrokeCoordinatorEmission,
    coordinator: StrokeRenderCoordinator,
    ordinals: inout [UInt64]
) throws {
    #expect(emission.work.map(\.ordinal) == emission.work.map(\.dab.ordinal))
    while let frame = try coordinator.prepareAuthoritativeFrame(
        maximumDabs: 16
    ) {
        ordinals.append(contentsOf: frame.work.map(\.ordinal))
        try coordinator.markAuthoritativeFrameSubmitted(frame)
    }
}

private func commitBegin(
    _ samples: [StrokeSample],
    coordinator: StrokeRenderCoordinator
) throws -> StrokeCoordinatorEmission {
    let prepared = try coordinator.prepareBegin(actualSamples: samples)
    try coordinator.commit(prepared)
    return prepared.emission
}

private func commitAppend(
    _ samples: [StrokeSample],
    coordinator: StrokeRenderCoordinator
) throws -> StrokeCoordinatorEmission {
    let prepared = try coordinator.prepareAppend(actualSamples: samples)
    try coordinator.commit(prepared)
    return prepared.emission
}

private func canonicalCoverage(
    for work: [AuthoritativeStrokeWork]
) -> [UInt16] {
    var pixels = [UInt16](repeating: 0, count: 512)
    for item in work {
        let center = Int(item.dab.position.x.rounded())
        let radius = max(1, Int(item.dab.radius.rounded(.up)))
        for x in max(0, center - radius)...min(511, center + radius) {
            pixels[x] &+= 1
        }
    }
    return pixels
}
