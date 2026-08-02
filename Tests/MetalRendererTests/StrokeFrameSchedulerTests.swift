import CShaderTypes
import EditorCore
import Foundation
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Off-main stroke frame scheduler")
struct StrokeFrameSchedulerTests {
    @Test
    func authoritativeInputOverflowCancelsGenerationAtomically() throws {
        var queue = try StrokeInputQueue(
            authoritativeCapacity: 4,
            predictionCapacity: 2
        )
        let generation: UInt64 = 41

        try queue.enqueue(
            .appendAuthoritative(
                generation: generation,
                samples: samples(0..<3)
            )
        )

        #expect(
            throws: StrokeInputQueueError.authoritativeCapacityExceeded(
                generation: generation,
                current: 3,
                incoming: 2,
                maximum: 4
            )
        ) {
            try queue.enqueue(
                .appendAuthoritative(
                    generation: generation,
                    samples: samples(3..<5)
                )
            )
        }

        let snapshot = queue.snapshot
        #expect(snapshot.authoritativePendingSampleCount == 0)
        #expect(snapshot.predictedPendingSampleCount == 0)
        #expect(snapshot.cancelledGeneration == generation)
        #expect(
            queue.dequeue()
                == .cancel(
                    generation: generation,
                    reason: .authoritativeCapacityExceeded(
                        current: 3,
                        incoming: 2,
                        maximum: 4
                    )
                )
        )
        #expect(queue.dequeue() == nil)
    }

    @Test
    func inputQueueUsesBudgetCapacitiesAndPreallocatedStorage() throws {
        let budget = try frameBudget(
            authoritativePerFrame: 4,
            predictedPerFrame: 2,
            authoritativeCapacity: 12,
            predictedCapacity: 7
        )
        let queue = StrokeInputQueue(budget: budget)

        #expect(queue.snapshot.authoritativeCapacity == 12)
        #expect(
            queue.snapshot.predictionCapacity
                == PredictionOverlay.maximumNormalizedSampleCount
        )
        #expect(queue.snapshot.authoritativeStorageCapacity >= 12)
        #expect(
            queue.snapshot.predictionStorageCapacity
                >= PredictionOverlay.maximumNormalizedSampleCount
        )
    }

    @Test
    func predictionReplacementIsBoundedAndNeverRemovesAuthoritativeInput()
        throws
    {
        var queue = try StrokeInputQueue(
            authoritativeCapacity: 4,
            predictionCapacity: 2
        )
        let generation: UInt64 = 7
        try queue.enqueue(
            .appendAuthoritative(
                generation: generation,
                samples: samples(0..<2)
            )
        )
        let first = try queue.enqueue(
            .replacePrediction(
                generation: generation,
                samples: predictedSamples(10..<12),
                acceptedCount: 2
            )
        )
        let oversizedPrediction = predictedSamples(20..<10_020)
        let replacement = try queue.enqueue(
            .replacePrediction(
                generation: generation,
                samples: oversizedPrediction,
                acceptedCount: oversizedPrediction.count
            )
        )

        #expect(first.acceptedPredictionSampleCount == 2)
        #expect(first.shedPredictionSampleCount == 0)
        #expect(replacement.acceptedPredictionSampleCount == 2)
        #expect(replacement.shedPredictionSampleCount == 9_998)
        #expect(queue.snapshot.authoritativePendingSampleCount == 2)
        #expect(queue.snapshot.predictedPendingSampleCount == 2)
        #expect(queue.snapshot.predictedHighWater == 2)

        guard case let .appendAuthoritative(_, authoritative)? = queue.dequeue()
        else {
            Issue.record("Expected authoritative input to remain queued")
            return
        }
        guard case let .replacePredictionBatchSample(
            _, firstPredicted, firstIndex, batchCount, firstSubmittedCount
        )? = queue.dequeue(),
        case let .replacePredictionBatchSample(
            _,
            secondPredicted,
            secondIndex,
            secondBatchCount,
            secondSubmittedCount
        )? = queue.dequeue()
        else {
            Issue.record("Expected only the bounded prediction prefix")
            return
        }
        #expect(authoritative.map(\.timestamp) == [0, 1])
        #expect(firstPredicted.timestamp == 20)
        #expect(secondPredicted.timestamp == 21)
        #expect(firstIndex == 0)
        #expect(secondIndex == 1)
        #expect(batchCount == 2)
        #expect(secondBatchCount == 2)
        #expect(firstSubmittedCount == 10_000)
        #expect(secondSubmittedCount == 10_000)
        #expect(queue.dequeue() == nil)
    }

    @Test
    func emptyPredictionReplacementRemainsPendingUntilDequeued() throws {
        var queue = try StrokeInputQueue(
            authoritativeCapacity: 4,
            predictionCapacity: 2
        )
        let generation: UInt64 = 9

        let admission = try queue.enqueue(
            .replacePrediction(
                generation: generation,
                samples: [],
                acceptedCount: 0
            )
        )

        #expect(admission.acceptedPredictionSampleCount == 0)
        #expect(admission.shedPredictionSampleCount == 0)
        #expect(queue.snapshot.authoritativePendingSampleCount == 0)
        #expect(queue.snapshot.predictedPendingSampleCount == 0)
        #expect(queue.snapshot.hasPendingInput)
        #expect(
            queue.dequeue()
                == .replacePrediction(
                    generation: generation,
                    samples: [],
                    acceptedCount: 0
                )
        )
        #expect(!queue.snapshot.hasPendingInput)
        #expect(queue.dequeue() == nil)
    }

    @Test
    func estimatedUpdateAdmissionIsOneAuthoritativeUnitAndPreservesFIFO()
        throws
    {
        var queue = try StrokeInputQueue(
            authoritativeCapacity: 4,
            predictionCapacity: 2
        )
        let generation: UInt64 = 8
        let initial = queue.snapshot
        let authoritative = samples(0..<1)
        let prediction = predictedSamples(10..<11)
        let update = estimatedUpdateSample(index: 17)

        try queue.enqueue(
            .appendAuthoritative(
                generation: generation,
                samples: authoritative
            )
        )
        _ = try queue.enqueue(
            .replacePrediction(
                generation: generation,
                samples: prediction,
                acceptedCount: prediction.count
            )
        )
        let admission = try queue.enqueue(
            .applyEstimatedUpdate(
                generation: generation,
                sample: update
            )
        )

        #expect(admission == .authoritative)
        let admitted = queue.snapshot
        #expect(admitted.authoritativePendingSampleCount == 2)
        #expect(admitted.predictedPendingSampleCount == 1)
        #expect(admitted.authoritativeHighWater == 2)
        #expect(admitted.predictedHighWater == 1)
        #expect(
            admitted.authoritativeStorageCapacity
                == initial.authoritativeStorageCapacity
        )
        #expect(
            admitted.predictionStorageCapacity
                == initial.predictionStorageCapacity
        )
        #expect(
            queue.dequeue()
                == .appendAuthoritative(
                    generation: generation,
                    samples: authoritative
                )
        )
        #expect(
            queue.dequeue()
                == .replacePredictionBatchSample(
                    generation: generation,
                    sample: prediction[0],
                    index: 0,
                    count: 1,
                    submittedCount: 1
                )
        )
        #expect(
            queue.dequeue()
                == .applyEstimatedUpdate(
                    generation: generation,
                    sample: update
                )
        )
        #expect(queue.dequeue() == nil)
        #expect(queue.snapshot.authoritativePendingSampleCount == 0)
        #expect(queue.snapshot.predictedPendingSampleCount == 0)
    }

    @Test
    func estimatedUpdateAtFullAuthoritativeCapacityCancelsWithTypedError()
        throws
    {
        var queue = try StrokeInputQueue(
            authoritativeCapacity: 2,
            predictionCapacity: 2
        )
        let generation: UInt64 = 18
        let initial = queue.snapshot
        try queue.enqueue(
            .appendAuthoritative(
                generation: generation,
                samples: samples(0..<2)
            )
        )
        _ = try queue.enqueue(
            .replacePrediction(
                generation: generation,
                samples: predictedSamples(10..<11),
                acceptedCount: 1
            )
        )

        #expect(
            throws: StrokeInputQueueError.authoritativeCapacityExceeded(
                generation: generation,
                current: 2,
                incoming: 1,
                maximum: 2
            )
        ) {
            try queue.enqueue(
                .applyEstimatedUpdate(
                    generation: generation,
                    sample: estimatedUpdateSample(index: 22)
                )
            )
        }

        let cancelled = queue.snapshot
        #expect(cancelled.authoritativePendingSampleCount == 0)
        #expect(cancelled.predictedPendingSampleCount == 0)
        #expect(cancelled.authoritativeHighWater == 2)
        #expect(cancelled.predictedHighWater == 1)
        #expect(cancelled.cancelledGeneration == generation)
        #expect(
            cancelled.authoritativeStorageCapacity
                == initial.authoritativeStorageCapacity
        )
        #expect(
            cancelled.predictionStorageCapacity
                == initial.predictionStorageCapacity
        )
        #expect(
            queue.dequeue()
                == .cancel(
                    generation: generation,
                    reason: .authoritativeCapacityExceeded(
                        current: 2,
                        incoming: 1,
                        maximum: 2
                    )
                )
        )
        #expect(queue.dequeue() == nil)
    }

    @Test
    func actorAppliesLocationPressureAzimuthAndAltitudeCorrections()
        async throws
    {
        let properties: [StrokeEstimatedProperties] = [
            .location,
            .pressure,
            .azimuth,
            .altitude,
        ]
        for (offset, property) in properties.enumerated() {
            let generation = UInt64(300 + offset)
            let scheduler = try preparationScheduler()
            let initial = estimatedPreparationSample(
                phase: .began,
                kind: .actual,
                index: 40 + offset,
                property: property,
                x: 10,
                pressure: 0.2,
                altitude: 0.4,
                azimuth: 0.6
            )
            let began = try await scheduler.beginPreparedStroke(
                generation: generation,
                configuration: try preparationConfiguration(),
                actualSamples: [initial]
            )
            try await acknowledgeAll(
                began,
                scheduler: scheduler,
                generation: generation
            )
            let retainedBefore = await scheduler
                .transientPreparationSnapshotForTesting
            #expect(retainedBefore.actualSamples.count == 1)

            let update = estimatedPreparationSample(
                phase: .moved,
                kind: .estimatedUpdate,
                index: 40 + offset,
                property: [],
                x: 42,
                pressure: 0.9,
                altitude: 1.1,
                azimuth: 1.4
            )
            let result = await scheduler.process(
                .applyEstimatedUpdate(
                    generation: generation,
                    sample: update
                )
            )
            guard case let .prepared(corrected) = result else {
                Issue.record("Expected corrected actor output for \(property)")
                continue
            }
            let diagnostic = try #require(
                await scheduler.lastEstimatedUpdateSnapshotForTesting
            )
            #expect(diagnostic.target == .authoritative)
            #expect(
                diagnostic.mergedSample
                    .estimatedPropertiesExpectingUpdates.isEmpty
            )
            let original = try #require(retainedBefore.actualSamples.first)
            if property == .location {
                #expect(diagnostic.mergedSample.position != original.position)
                #expect(diagnostic.mergedSample.pressure == original.pressure)
            } else if property == .pressure {
                #expect(diagnostic.mergedSample.pressure == 0.9)
                #expect(diagnostic.mergedSample.position == original.position)
            } else if property == .azimuth {
                #expect(diagnostic.mergedSample.azimuth == 1.4)
                #expect(diagnostic.mergedSample.altitude == original.altitude)
            } else if property == .altitude {
                #expect(diagnostic.mergedSample.altitude == 1.1)
                #expect(diagnostic.mergedSample.azimuth == original.azimuth)
            }
            #expect(
                (await scheduler.transientPreparationSnapshotForTesting)
                    .actualSamples.isEmpty
            )
            try await acknowledgeAll(
                corrected,
                scheduler: scheduler,
                generation: generation
            )
            await scheduler.cancel(generation: generation)
        }
    }

    @Test
    func predictedAwaitingEstimateIsCorrectedWithoutChangingProvenance()
        async throws
    {
        let scheduler = try preparationScheduler()
        let generation: UInt64 = 401
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: try preparationConfiguration(),
            actualSamples: [resolvedPreparationSample(phase: .began, x: 8)]
        )
        try await acknowledgeAll(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let predictionResult = await scheduler.process(
            .replacePrediction(
                generation: generation,
                samples: [
                    estimatedPreparationSample(
                        phase: .moved,
                        kind: .predicted,
                        index: 88,
                        property: .location,
                        x: 20,
                        pressure: 0.5,
                        altitude: 0.7,
                        azimuth: 0.8
                    ),
                    estimatedPreparationSample(
                        phase: .moved,
                        kind: .predicted,
                        index: 89,
                        property: .location,
                        x: 36,
                        pressure: 0.5,
                        altitude: 0.7,
                        azimuth: 0.8
                    ),
                ],
                acceptedCount: 2
            )
        )
        guard case let .prepared(prediction) = predictionResult else {
            Issue.record("Expected prediction preparation")
            return
        }
        let provenance = prediction.predictionProvenanceBoundary
        try await acknowledgeAll(
            prediction,
            scheduler: scheduler,
            generation: generation
        )
        let predictedBefore = try #require(
            (await scheduler.transientPreparationSnapshotForTesting)
                .predictedSamples.last
        )

        let updateResult = await scheduler.process(
            .applyEstimatedUpdate(
                generation: generation,
                sample: estimatedPreparationSample(
                    phase: .moved,
                    kind: .estimatedUpdate,
                    index: 89,
                    property: [],
                    x: 48,
                    pressure: 0.9,
                    altitude: 1.0,
                    azimuth: 1.2
                )
            )
        )
        guard case let .prepared(corrected) = updateResult else {
            Issue.record("Expected predicted estimated correction")
            return
        }
        let predictedAfter = try #require(
            (await scheduler.transientPreparationSnapshotForTesting)
                .predictedSamples.last
        )
        let correctedSnapshot =
            await scheduler.transientPreparationSnapshotForTesting
        #expect(predictedAfter.position != predictedBefore.position)
        #expect(
            predictedAfter.estimatedPropertiesExpectingUpdates.isEmpty
        )
        #expect(corrected.predictionProvenanceBoundary == provenance)
        #expect(
            corrected.predictionAdmission?.projectedInstanceCount
                == correctedSnapshot.predictedDabs.reduce(0) {
                    $0 + $1.projectedInstanceCount
                }
        )
        #expect(
            (await scheduler.lastEstimatedUpdateSnapshotForTesting)?.target
                == .predicted
        )
        try await acknowledgeAll(
            corrected,
            scheduler: scheduler,
            generation: generation
        )
        await scheduler.cancel(generation: generation)
    }

    @Test
    func invalidAndUnknownEstimatedUpdatesRollbackWithoutCancellingActor()
        async throws
    {
        let scheduler = try preparationScheduler()
        let generation: UInt64 = 402
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: try preparationConfiguration(),
            actualSamples: [
                estimatedPreparationSample(
                    phase: .began,
                    kind: .actual,
                    index: 91,
                    property: .pressure,
                    x: 8,
                    pressure: 0.3,
                    altitude: 0.6,
                    azimuth: 0.7
                ),
            ]
        )
        try await acknowledgeAll(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let before = await scheduler.transientPreparationSnapshotForTesting
        let beforeScheduler = await scheduler.snapshot

        let invalid = await scheduler.process(
            .applyEstimatedUpdate(
                generation: generation,
                sample: estimatedPreparationSample(
                    phase: .moved,
                    kind: .estimatedUpdate,
                    index: 91,
                    property: .azimuth,
                    x: 10,
                    pressure: 0.9,
                    altitude: 0.8,
                    azimuth: 1.1
                )
            )
        )
        guard case .estimatedUpdateWasRejected(
            generation,
            .invalidEstimatedUpdateProperties(91),
            nil
        ) = invalid else {
            Issue.record("Expected typed invalid-property rejection")
            return
        }
        #expect(
            await scheduler.transientPreparationSnapshotForTesting == before
        )
        #expect((await scheduler.snapshot).activeGeneration == generation)
        #expect(
            (await scheduler.snapshot).transientMutationVersion
                == beforeScheduler.transientMutationVersion
        )
        #expect(await scheduler.lastEstimatedUpdateSnapshotForTesting == nil)

        let unknown = await scheduler.process(
            .applyEstimatedUpdate(
                generation: generation,
                sample: estimatedPreparationSample(
                    phase: .moved,
                    kind: .estimatedUpdate,
                    index: 999,
                    property: [],
                    x: 10,
                    pressure: 0.9,
                    altitude: 0.8,
                    azimuth: 1.1
                )
            )
        )
        guard case .estimatedUpdateWasIgnored(
            generation,
            .unknownEstimatedUpdateIndex(999)
        ) = unknown else {
            Issue.record("Expected typed unknown-update ignore")
            return
        }
        #expect(
            await scheduler.transientPreparationSnapshotForTesting == before
        )
        #expect((await scheduler.snapshot).activeGeneration == generation)
        await scheduler.cancel(generation: generation)
    }

    @Test
    func commitBarrierHasDedicatedCapacityAfterAuthoritativeQueueFills()
        throws
    {
        var queue = try StrokeInputQueue(
            authoritativeCapacity: 4,
            predictionCapacity: 2
        )
        let generation: UInt64 = 12
        try queue.enqueue(
            .appendAuthoritative(
                generation: generation,
                samples: samples(0..<4)
            )
        )

        try queue.enqueue(.commit(generation: generation))

        #expect(queue.snapshot.authoritativePendingSampleCount == 4)
        guard case let .appendAuthoritative(_, admitted)? = queue.dequeue()
        else {
            Issue.record("Expected full authoritative batch")
            return
        }
        #expect(admitted.count == 4)
        #expect(queue.dequeue() == .commit(generation: generation))
        #expect(queue.dequeue() == nil)
    }

    @Test
    func resultMailboxBorrowsOnePayloadAndBackpressuresInput()
        async throws
    {
        let budget = try frameBudget(
            authoritativePerFrame: 4,
            predictedPerFrame: 2,
            authoritativeCapacity: 12,
            predictedCapacity: 4
        )
        let mailbox = StrokePreparationMailbox(budget: budget)
        let generation: UInt64 = 91
        try mailbox.submit(
            .appendAuthoritative(
                generation: generation,
                samples: samples(0..<1)
            )
        )
        try mailbox.submit(
            .appendAuthoritative(
                generation: generation,
                samples: samples(1..<2)
            )
        )

        #expect(mailbox.takeInput() != nil)
        #expect(mailbox.snapshot.workerIsProcessing)
        #expect(mailbox.takeInput() == nil)
        mailbox.publish(.cancelled(generation: generation, reason: nil))
        mailbox.completeWorkerOperation()
        #expect(!mailbox.snapshot.workerIsProcessing)
        #expect(mailbox.takeInput() == nil)
        #expect(mailbox.snapshot.pendingResultCount == 1)
        #expect(mailbox.snapshot.resultCapacity == 1)
        #expect(mailbox.snapshot.resultHighWater == 1)
        #expect(mailbox.snapshot.maximumPreparedRecordCount == 4)
        #expect(
            mailbox.snapshot.maximumPreparedLogicalDabCount
                == TransientStrokeBufferContract.wholeStrokeDabCapacity
        )
        #expect(
            mailbox.snapshot.maximumPreparedPayloadBytes
                == 4 * MemoryLayout<PixelRect>.stride
                    + TransientStrokeBufferContract.wholeStrokeDabCapacity
                        * MemoryLayout<LogicalDab>.stride
        )

        var results: [StrokePreparationResult] = []
        mailbox.drainResults(into: &results)
        #expect(results.count == 1)
        #expect(mailbox.takeInput() != nil)
        mailbox.completeWorkerOperation()
        #expect(mailbox.takeInput() == nil)

        let preparedGeneration: UInt64 = 92
        let scheduler = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: 120
        )
        let prepared = try await scheduler.beginPreparedStroke(
            generation: preparedGeneration,
            configuration: try preparationConfiguration(),
            actualSamples: [
                resolvedPreparationSample(phase: .began, x: 8),
            ]
        )
        let token = try #require(prepared.frameToken)

        let abandonedMailbox = StrokePreparationMailbox(budget: budget)
        abandonedMailbox.publish(.prepared(prepared))
        var abandonedResults: [StrokePreparationResult] = []
        abandonedMailbox.drainResults(into: &abandonedResults)
        #expect(abandonedResults.count == 1)
        #expect(
            abandonedMailbox.snapshot.awaitingPreparedFrameSubmission
        )

        try abandonedMailbox.submitCancellation(
            generation: preparedGeneration,
            reason: nil,
            frameDisposition: .abandonedBeforeSubmission
        )
        let abandonedAcknowledgement = try #require(
            abandonedMailbox.takePreparedFrameAcknowledgement()
        )
        #expect(
            abandonedAcknowledgement.generation == preparedGeneration
        )
        #expect(abandonedAcknowledgement.token == token)
        abandonedMailbox.completePreparedFrameAcknowledgement(
            generation: preparedGeneration,
            token: token
        )
        abandonedMailbox.completeWorkerOperation()
        #expect(
            !abandonedMailbox.snapshot.awaitingPreparedFrameSubmission
        )
        #expect(abandonedMailbox.takeInput() != nil)
        abandonedMailbox.completeWorkerOperation()

        let mainOwnedMailbox = StrokePreparationMailbox(budget: budget)
        mainOwnedMailbox.publish(.prepared(prepared))
        var mainOwnedResults: [StrokePreparationResult] = []
        mainOwnedMailbox.drainResults(into: &mainOwnedResults)
        try mainOwnedMailbox.submitCancellation(
            generation: preparedGeneration,
            reason: nil,
            frameDisposition: .preserveMainOwnership
        )
        #expect(
            mainOwnedMailbox.takePreparedFrameAcknowledgement() == nil
        )
        #expect(mainOwnedMailbox.takeInput() == nil)

        try mainOwnedMailbox.acknowledgePreparedFrame(
            generation: preparedGeneration,
            token: token
        )
        let mainAcknowledgement = try #require(
            mainOwnedMailbox.takePreparedFrameAcknowledgement()
        )
        #expect(mainAcknowledgement.generation == preparedGeneration)
        #expect(mainAcknowledgement.token == token)
        mainOwnedMailbox.completePreparedFrameAcknowledgement(
            generation: preparedGeneration,
            token: token
        )
        mainOwnedMailbox.completeWorkerOperation()
        #expect(mainOwnedMailbox.takeInput() != nil)
        mainOwnedMailbox.completeWorkerOperation()

        let inFlightMailbox = StrokePreparationMailbox(budget: budget)
        inFlightMailbox.publish(.prepared(prepared))
        var inFlightResults: [StrokePreparationResult] = []
        inFlightMailbox.drainResults(into: &inFlightResults)
        try inFlightMailbox.acknowledgePreparedFrame(
            generation: preparedGeneration,
            token: token
        )
        let inFlightAcknowledgement = try #require(
            inFlightMailbox.takePreparedFrameAcknowledgement()
        )
        try inFlightMailbox.submitCancellation(
            generation: preparedGeneration,
            reason: nil,
            frameDisposition: .abandonedBeforeSubmission
        )
        inFlightMailbox.completePreparedFrameAcknowledgement(
            generation: inFlightAcknowledgement.generation,
            token: inFlightAcknowledgement.token
        )
        inFlightMailbox.completeWorkerOperation()
        if inFlightMailbox.takePreparedFrameAcknowledgement() != nil {
            Issue.record("Cancellation queued a duplicate in-flight ack")
            return
        }
        guard inFlightMailbox.takeInput() != nil else {
            Issue.record("Cancellation remained blocked after in-flight ack")
            return
        }
        inFlightMailbox.completeWorkerOperation()

        // A timeout task can be delayed behind actor work and publish after
        // the progress it was bounding. The mailbox revision is the source
        // of truth, so that stale timeout must not defeat completed work even
        // when bufferingNewest retains only the timeout signal.
        let causalMailbox = StrokePreparationMailbox(budget: budget)
        let progressRegistration =
            StrokePreparationAsyncProgressRegistration(mailbox: causalMailbox)
        defer { progressRegistration.remove() }
        let observedRevision = causalMailbox.currentProgressRevision
        causalMailbox.publish(
            .cancelled(generation: preparedGeneration, reason: nil)
        )
        progressRegistration.recordTimeoutForTesting(
            after: observedRevision
        )
        #expect(
            causalMailbox.currentProgressRevision != observedRevision
        )
        #expect(
            try await progressRegistration.waitForProgress(
                after: observedRevision
            )
        )
    }

    @Test
    func mailboxQuiescenceIncludesDequeuedWorkStillProcessing() throws {
        let budget = try frameBudget(
            authoritativePerFrame: 4,
            predictedPerFrame: 2,
            authoritativeCapacity: 12,
            predictedCapacity: 4
        )
        let mailbox = StrokePreparationMailbox(budget: budget)
        try mailbox.submit(
            .appendAuthoritative(
                generation: 93,
                samples: samples(0..<1)
            )
        )

        #expect(!mailbox.snapshot.isQuiescent)
        #expect(mailbox.takeInput() != nil)
        let processing = mailbox.snapshot
        #expect(!processing.input.hasPendingInput)
        #expect(processing.pendingResultCount == 0)
        #expect(!processing.awaitingPreparedFrameSubmission)
        #expect(processing.workerIsProcessing)
        #expect(!processing.isQuiescent)

        mailbox.completeWorkerOperation()
        #expect(mailbox.snapshot.isQuiescent)
    }

    @Test(arguments: [60, 120])
    func displayRateUsesDeterministicFrameBudget(_ framesPerSecond: Int)
        async throws
    {
        let budget = try frameBudget(
            authoritativePerFrame: 2,
            predictedPerFrame: 1,
            authoritativeCapacity: 6,
            predictedCapacity: 2
        )
        let scheduler = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: framesPerSecond
        )
        try await scheduler.begin(generation: 1)
        try await scheduler.enqueueAuthoritative(
            projectedRecords(0..<5),
            generation: 1
        )

        let first = try #require(await scheduler.prepareFrame(generation: 1))
        #expect(first.authoritative.map(\.identity) == [0, 1])
        #expect(first.authoritativeRemaining == 3)
        #expect(
            first.targetFrameDurationNanoseconds
                == UInt64(1_000_000_000 / framesPerSecond)
        )
        try await scheduler.markSubmitted(first, generation: 1)

        let diagnostics = await scheduler.snapshot
        #expect(diagnostics.authoritativePending == 3)
        #expect(diagnostics.authoritativeHighWater == 5)
        #expect(diagnostics.maximumPreparationWorkUnitsPerFrame == 2)
    }

    @Test
    func commitBarrierWaitsForEveryAuthoritativeFrameToSubmit() async throws {
        let budget = try frameBudget(
            authoritativePerFrame: 2,
            predictedPerFrame: 2,
            authoritativeCapacity: 5,
            predictedCapacity: 2
        )
        let scheduler = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: 60
        )
        try await scheduler.begin(generation: 9)
        try await scheduler.enqueueAuthoritative(
            projectedRecords(0..<5),
            generation: 9
        )
        try await scheduler.requestCommit(generation: 9)

        #expect(!(await scheduler.isCommitReady(generation: 9)))
        var submitted: [UInt64] = []
        while let frame = try await scheduler.prepareFrame(generation: 9) {
            submitted.append(contentsOf: frame.authoritative.map(\.identity))
            #expect(!(await scheduler.isCommitReady(generation: 9)))
            try await scheduler.markSubmitted(frame, generation: 9)
        }

        #expect(submitted == [0, 1, 2, 3, 4])
        #expect(await scheduler.isCommitReady(generation: 9))
    }

    @Test
    func predictionOverloadShedsOnlyTruePrediction() async throws {
        let budget = try frameBudget(
            authoritativePerFrame: 2,
            predictedPerFrame: 2,
            authoritativeCapacity: 4,
            predictedCapacity: 4
        )
        let scheduler = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: 120
        )
        try await scheduler.begin(generation: 5)
        try await scheduler.enqueueAuthoritative(
            projectedRecords(0..<2),
            generation: 5
        )
        let prediction = try await scheduler.replacePrediction(
            projectedRecords(100..<105, predicted: true),
            generation: 5
        )

        #expect(prediction.acceptedPredictedInstanceCount == 2)
        #expect(prediction.droppedPredictedInstanceCount == 3)
        let authoritative = try #require(
            await scheduler.prepareFrame(generation: 5)
        )
        #expect(authoritative.authoritative.map(\.identity) == [0, 1])
        #expect(authoritative.predicted.isEmpty)
        try await scheduler.markSubmitted(authoritative, generation: 5)
        let predicted = try #require(
            await scheduler.prepareFrame(generation: 5)
        )
        #expect(predicted.authoritative.isEmpty)
        #expect(predicted.predicted.map(\.identity) == [100, 101])
    }

    @Test
    func commitPromotesRetainedNonPredictedPrefixAndDiscardsTruePrediction()
        async throws
    {
        let budget = try frameBudget(
            authoritativePerFrame: 2,
            predictedPerFrame: 4,
            authoritativeCapacity: 4,
            predictedCapacity: 4
        )
        let scheduler = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: 60
        )
        let generation: UInt64 = 6
        try await scheduler.begin(generation: generation)

        let replacement = try await scheduler.replacePrediction(
            projectedRecords(10..<12)
                + projectedRecords(100..<104, predicted: true),
            generation: generation
        )

        #expect(replacement.acceptedPredictedInstanceCount == 2)
        #expect(replacement.droppedPredictedInstanceCount == 2)
        #expect((await scheduler.snapshot).predictedPending == 4)

        try await scheduler.requestCommit(generation: generation)

        let committed = await scheduler.snapshot
        #expect(committed.authoritativePending == 2)
        #expect(committed.predictedPending == 0)
        #expect(!(await scheduler.isCommitReady(generation: generation)))

        let frame = try #require(
            await scheduler.prepareFrame(generation: generation)
        )
        #expect(frame.authoritative.map(\.identity) == [10, 11])
        #expect(frame.authoritative.allSatisfy { !$0.isPredicted })
        #expect(frame.predicted.isEmpty)
        try await scheduler.markSubmitted(frame, generation: generation)

        #expect(await scheduler.isCommitReady(generation: generation))
    }

    @Test
    func cancellationClearsQueuesAndRejectsStaleGeneration() async throws {
        let budget = try frameBudget(
            authoritativePerFrame: 2,
            predictedPerFrame: 2,
            authoritativeCapacity: 4,
            predictedCapacity: 2
        )
        let scheduler = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: 60
        )
        try await scheduler.begin(generation: 3)
        try await scheduler.enqueueAuthoritative(
            projectedRecords(0..<3),
            generation: 3
        )
        _ = try await scheduler.replacePrediction(
            projectedRecords(100..<102, predicted: true),
            generation: 3
        )

        await scheduler.cancel(generation: 3)

        let snapshot = await scheduler.snapshot
        #expect(snapshot.authoritativePending == 0)
        #expect(snapshot.predictedPending == 0)
        #expect(snapshot.cancelledGeneration == 3)
        await #expect(
            throws: StrokeFrameSchedulerError.staleGeneration(
                expected: nil,
                actual: 3
            )
        ) {
            try await scheduler.enqueueAuthoritative(
                projectedRecords(10..<11),
                generation: 3
            )
        }
    }

    @Test
    func acceleratedTenMinuteTraceHasFlatBoundedSchedulerWork()
        async throws
    {
        let budget = try frameBudget(
            authoritativePerFrame: 1,
            predictedPerFrame: 1,
            authoritativeCapacity: 12_288,
            predictedCapacity: 4_096
        )
        let scheduler = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: 60
        )
        let generation: UInt64 = 600
        try await scheduler.begin(generation: generation)
        let initial = await scheduler.snapshot
        let record = projectedRecords(0..<1)
        let frameCount = 36_000
        let decileCount = frameCount / 10
        let targetNanoseconds = UInt64(1_000_000_000 / 60)
        let firstDecileStart = DispatchTime.now().uptimeNanoseconds
        var firstDecileDuration: UInt64 = 0
        var lastDecileStart: UInt64 = 0
        var submittedFrameCount = 0

        for index in 0..<frameCount {
            if index == frameCount - decileCount {
                lastDecileStart = DispatchTime.now().uptimeNanoseconds
            }
            try await scheduler.enqueueAuthoritative(
                record,
                generation: generation
            )
            let frame = try #require(
                await scheduler.prepareFrame(generation: generation)
            )
            if index == 0 || index == frameCount - 1 {
                #expect(frame.authoritative.count == 1)
                #expect(frame.predicted.isEmpty)
                #expect(
                    frame.targetFrameDurationNanoseconds
                        == targetNanoseconds
                )
            }
            try await scheduler.markSubmitted(
                frame,
                generation: generation
            )
            submittedFrameCount += 1
            if index + 1 == decileCount {
                firstDecileDuration = DispatchTime.now().uptimeNanoseconds
                    - firstDecileStart
            }
        }
        let lastDecileDuration = DispatchTime.now().uptimeNanoseconds
            - lastDecileStart
        let final = await scheduler.snapshot

        #expect(submittedFrameCount == frameCount)
        #expect(
            UInt64(frameCount) * targetNanoseconds
                == 599_999_976_000
        )
        #expect(final.authoritativePending == 0)
        #expect(final.authoritativeHighWater == 1)
        #expect(final.maximumPreparationWorkUnitsPerFrame == 1)
        #expect(
            final.authoritativeStorageCapacity
                == initial.authoritativeStorageCapacity
        )
        #expect(
            final.predictedStorageCapacity
                == initial.predictedStorageCapacity
        )
        // The accelerated trace does not sleep. Allow ordinary CI jitter but
        // reject a sustained tail slowdown characteristic of growing work.
        #expect(
            lastDecileDuration
                <= max(
                    firstDecileDuration * 4,
                    firstDecileDuration + 100_000_000
                )
        )
    }

    private func preparationScheduler() throws -> StrokeFrameScheduler {
        StrokeFrameScheduler(
            budget: try frameBudget(
                authoritativePerFrame: 128,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            ),
            targetFramesPerSecond: 120
        )
    }

    private func preparationConfiguration() throws
        -> StrokePreparationConfiguration
    {
        StrokePreparationConfiguration(
            program: try BrushProgramCompiler.compile(
                StageFourAnchorDefinitions.ink
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
    }

    private func acknowledgeAll(
        _ first: StrokePreparedDepositionBatch,
        scheduler: StrokeFrameScheduler,
        generation: UInt64
    ) async throws {
        var current: StrokePreparedDepositionBatch? = first
        while let batch = current, let token = batch.frameToken {
            let next = await scheduler.acknowledgePreparedFrame(
                generation: generation,
                frameToken: token
            )
            if case let .prepared(prepared)? = next {
                current = prepared
            } else if case let .failed(_, failure)? = next {
                Issue.record("Preparation acknowledgement failed: \(failure)")
                current = nil
            } else {
                current = nil
            }
        }
    }

    private func resolvedPreparationSample(
        phase: StrokePhase,
        x: Float
    ) -> StrokeSample {
        StrokeSample(
            position: ScreenPoint(x: x, y: 32),
            pressure: 0.5,
            timestamp: TimeInterval(x) / 240,
            phase: phase,
            source: .pencil,
            capabilities: [.pressure, .altitude, .azimuth],
            altitude: 0.7,
            azimuth: 0.8
        )
    }

    private func estimatedPreparationSample(
        phase: StrokePhase,
        kind: StrokeSampleKind,
        index: Int,
        property: StrokeEstimatedProperties,
        x: Float,
        pressure: Float,
        altitude: Float,
        azimuth: Float
    ) -> StrokeSample {
        StrokeSample(
            position: ScreenPoint(x: x, y: 32),
            pressure: pressure,
            timestamp: TimeInterval(index) / 240,
            phase: phase,
            source: .pencil,
            kind: kind,
            capabilities: [.pressure, .altitude, .azimuth],
            altitude: altitude,
            azimuth: azimuth,
            estimationUpdateIndex: index,
            estimatedProperties: property,
            estimatedPropertiesExpectingUpdates:
                kind == .estimatedUpdate ? [] : property
        )
    }

    private func samples(_ range: Range<Int>) -> [StrokeSample] {
        range.map { index in
            .mouse(
                position: ScreenPoint(x: Float(index), y: 0),
                timestamp: TimeInterval(index),
                phase: .moved
            )
        }
    }

    private func predictedSamples(_ range: Range<Int>) -> [StrokeSample] {
        range.map { index in
            StrokeSample(
                position: ScreenPoint(x: Float(index), y: 0),
                pressure: 1,
                timestamp: TimeInterval(index),
                phase: .moved,
                source: .pencil,
                kind: .predicted,
                capabilities: [.pressure]
            )
        }
    }

    private func estimatedUpdateSample(index: Int) -> StrokeSample {
        StrokeSample(
            position: ScreenPoint(x: Float(index), y: 0),
            pressure: 0.75,
            timestamp: TimeInterval(index),
            phase: .moved,
            source: .pencil,
            kind: .estimatedUpdate,
            capabilities: [.pressure],
            estimationUpdateIndex: index
        )
    }

    private func projectedRecords(
        _ range: Range<Int>,
        predicted: Bool = false
    ) -> [ProjectedDepositionRecord] {
        range.map { index in
            let identity = UInt64(index)
            return ProjectedDepositionRecord(
                identity: identity,
                instance: instance(
                    identity: identity,
                    predicted: predicted
                ),
                radialPage: nil
            )
        }
    }

    private func instance(
        identity: UInt64,
        predicted: Bool
    ) -> PatternDepositionStampInstance {
        let clip = PatternClipHalfPlane(
            normal: .zero,
            offset: 0,
            padding: 0
        )
        return PatternDepositionStampInstance(
            tipFrame0: SIMD4(1, 0, 0, 1),
            tipFrame1: SIMD4(0, 0, 1, 0),
            primaryGrainFrame0: .zero,
            primaryGrainFrame1: .zero,
            secondaryGrainFrame0: .zero,
            secondaryGrainFrame1: .zero,
            premultipliedColor: SIMD4(0, 0, 0, 1),
            coverageInputs: SIMD4(1, 1, 1, 1),
            clip0: clip,
            clip1: clip,
            clip2: clip,
            clip3: clip,
            identity: SIMD4(
                UInt32(truncatingIfNeeded: identity),
                UInt32(truncatingIfNeeded: identity >> 32),
                0,
                predicted ? DepositionIdentityFlags.predicted : 0
            ),
            metadata: SIMD4(0, 0, 0, UInt32(DepositionABI.version)),
            reserved0: .zero,
            reserved1: .zero
        )
    }

    private func frameBudget(
        authoritativePerFrame: Int,
        predictedPerFrame: Int,
        authoritativeCapacity: Int,
        predictedCapacity: Int
    ) throws -> DepositionFrameBudget {
        try DepositionFrameBudget(
            cpuPreparationNanoseconds: 1_500_000,
            maximumAuthoritativeInstances: authoritativePerFrame,
            maximumPredictedInstances: predictedPerFrame,
            maximumPendingAuthoritativeInstances: authoritativeCapacity,
            maximumPendingPredictedInstances: predictedCapacity,
            inFlightUploadBufferCount: 3
        )
    }
}
