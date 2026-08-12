import CShaderTypes
import EditorCore
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Off-main stroke frame scheduler")
struct StrokeFrameSchedulerTests {
    // Medium gates run hundreds of CPU-heavy tests concurrently. A one-second
    // wall-clock deadline can expire while the worker is merely descheduled,
    // even though its revision protocol is making correct progress.
    private static let asyncProgressTimeoutNanoseconds: UInt64 =
        5_000_000_000

    @Test
    func compositeComponentIdentitySurvivesGenerationAndProjection()
        async throws
    {
        let generation: UInt64 = 0xC0_02
        let scheduler = try preparationScheduler(
            authoritativePerFrame: 128,
            preparationClock: { 0 }
        )
        let program = try stageCMetalCompositeProgram(
            id: "test.scheduler.composite-identity"
        )
        let finitePlain = try TilingStrategy(
            finiteConfiguration: .plain,
            canvasSize: PixelSize(width: 512, height: 512)
        )

        let first = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: try preparationConfiguration(
                program: program,
                strategy: finitePlain
            ),
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 64,
                    timestamp: 0
                ),
            ]
        )
        let pages = try await drainPreparedBatchRecords(
            first,
            scheduler: scheduler,
            generation: generation
        )
        let dabs = pages.flatMap(\.logicalDabs)

        #expect(dabs.map(\.ordinal) == [0, 1])
        #expect(dabs.map(\.componentOrdinal) == [0, 1])
        #expect(dabs.map(\.componentDabOrdinal) == [0, 0])
        #expect(pages.contains { $0.authoritativeInstanceCount > 0 })
        #expect(pages.allSatisfy { $0.authoritativeInstanceCount <= 128 })
        #expect(pages.flatMap(\.dirtyRegions).count >= dabs.count)
        await scheduler.cancel(generation: generation)
    }

    @Test
    func compositeProjectionSharesExistingPendingAndWorkCeilings()
        async throws
    {
        let generation: UInt64 = 0xC0_03
        let ceiling = 2
        let scheduler = StrokeFrameScheduler(
            budget: try frameBudget(
                authoritativePerFrame: ceiling,
                predictedPerFrame: ceiling,
                authoritativeCapacity: ceiling,
                predictedCapacity: ceiling
            ),
            targetFramesPerSecond: 120,
            preparationClock: { 0 }
        )
        let program = try stageCMetalCompositeProgram(
            id: "test.scheduler.composite-aggregate-ceilings"
        )
        let strategy = try TilingStrategy(
            finiteConfiguration: .plain,
            canvasSize: PixelSize(width: 512, height: 512)
        )

        let first = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: try preparationConfiguration(
                program: program,
                strategy: strategy
            ),
            actualSamples: [stageCPreparationSample(
                phase: .began,
                x: 128,
                y: 192,
                timestamp: 0
            )]
        )
        let pages = try await drainPreparedBatchRecords(
            first,
            scheduler: scheduler,
            generation: generation
        )
        let logicalPages = pages.filter { !$0.logicalDabs.isEmpty }

        #expect(logicalPages.flatMap(\.logicalDabs).map(\.componentOrdinal)
            == [0, 1])
        #expect(logicalPages.map(\.authoritativeInstanceCount)
            == [ceiling, ceiling])
        #expect(logicalPages.allSatisfy {
            $0.authoritativeInstanceCount <= ceiling
                && $0.dirtyRegions.count <= ceiling
        })
        let snapshot = await scheduler.snapshot
        #expect(snapshot.maximumPreparationWorkUnitsPerFrame
            <= LogicalDabBatch.maximumDabCount)
        await scheduler.cancel(generation: generation)
    }

    @Test
    func compositePredictionSharesOneReplayDabCeiling() async throws {
        let generation: UInt64 = 0xC0_04
        let limits = BrushReplayLimits(
            maximumSamples: 4,
            maximumDabs: 1,
            maximumProjectedInstances: 8
        )
        let scheduler = try preparationScheduler(
            authoritativePerFrame: 128,
            preparationClock: { 0 }
        )
        let program = try stageCMetalCompositeProgram(
            id: "test.scheduler.composite-replay-dab-ceiling",
            replayMode: .replayTail,
            replayLimits: limits
        )
        let configuration = try preparationConfiguration(program: program)
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [stageCPreparationSample(
                phase: .began,
                x: 64,
                timestamp: 0
            )]
        )
        try await acknowledgeAll(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let beforePrediction = await scheduler
            .transientPreparationSnapshotForTesting

        let prediction = try await scheduler.replacePreparedPrediction(
            generation: generation,
            samples: [stageCPreparationSample(
                phase: .moved,
                x: 96,
                timestamp: 1,
                kind: .predicted
            )]
        )
        let snapshot = await scheduler
            .transientPreparationSnapshotForTesting

        #expect(
            prediction.predictionAdmission?.overload
                .contains(.logicalDabs) == true
        )
        #expect(prediction.logicalDabs.isEmpty)
        #expect(snapshot.predictedDabs.isEmpty)
        #expect(snapshot.actualDabs == beforePrediction.actualDabs)
        #expect(snapshot.actualSamples == beforePrediction.actualSamples)
        try await acknowledgeAll(
            prediction,
            scheduler: scheduler,
            generation: generation
        )
        await scheduler.cancel(generation: generation)
    }

    @Test
    func stageCCandidatePagesAreCadenceIndependentAtBoundaries()
        async throws
    {
        let candidateCounts = [511, 512, 513, 1_025]
        let displaySchedules = [60, 120, 1_000]
        var baselineByCount: [Int: [LogicalDab]] = [:]
        var baselinePageCountsByCount: [Int: [Int]] = [:]

        for candidateCount in candidateCounts {
            for framesPerSecond in displaySchedules {
                let generation = UInt64(candidateCount * 2_000
                    + framesPerSecond)
                let scheduler = try preparationScheduler(
                    targetFramesPerSecond: framesPerSecond,
                    authoritativePerFrame: 4_096,
                    preparationClock: { 0 }
                )
                let program = try stageCMetalTestProgram(
                    id: "test.scheduler.stage-c-page-\(candidateCount)-\(framesPerSecond)",
                    emission: BrushEmissionDefinition(
                        mode: .time,
                        timeInterval: 1.0 / 240
                    )
                )
                let began = try await scheduler.beginPreparedStroke(
                    generation: generation,
                    configuration: try preparationConfiguration(
                        program: program
                    ),
                    actualSamples: [
                        stageCPreparationSample(
                            phase: .began,
                            x: 64,
                            timestamp: 0
                        ),
                    ]
                )
                _ = try await drainPreparedBatches(
                    began,
                    scheduler: scheduler,
                    generation: generation
                )

                let finished = try await scheduler.finishPreparedStroke(
                    generation: generation,
                    actualSamples: [
                        stageCPreparationSample(
                            phase: .ended,
                            x: 64,
                            timestamp: Double(candidateCount) / 240
                        ),
                    ]
                )
                let pages = try await drainPreparedBatches(
                    finished,
                    scheduler: scheduler,
                    generation: generation
                )
                let logicalPages = pages.filter { !$0.isEmpty }
                #expect(
                    logicalPages.allSatisfy {
                        $0.count <= LogicalDabBatch.maximumDabCount / 2
                    }
                )
                let dabs = logicalPages.flatMap { $0 }
                #expect(dabs.count == candidateCount)
                #expect(
                    dabs.map(\.ordinal)
                        == Array(1...UInt64(candidateCount))
                )
                let pageCounts = logicalPages.map(\.count)
                if let baseline = baselinePageCountsByCount[candidateCount] {
                    #expect(pageCounts == baseline)
                } else {
                    baselinePageCountsByCount[candidateCount] = pageCounts
                }
                if let baseline = baselineByCount[candidateCount] {
                    #expect(dabs == baseline)
                } else {
                    baselineByCount[candidateCount] = dabs
                }
                #expect(
                    (await scheduler.snapshot)
                        .maximumPreparationWorkUnitsPerFrame
                        <= LogicalDabBatch.maximumDabCount
                )
                await scheduler.cancel(generation: generation)
            }
        }
    }

    @Test
    func cancellationAcknowledgementRetiresPageWithoutResumingCursor()
        async throws
    {
        let generation: UInt64 = 0xC1_12_CA
        let scheduler = try preparationScheduler(
            authoritativePerFrame: 4_096,
            preparationClock: { 0 }
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-cancel-resume",
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: try preparationConfiguration(program: program),
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 64,
                    timestamp: 0
                ),
            ]
        )
        _ = try await drainPreparedBatches(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let firstPreparedPage = try await scheduler.finishPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .ended,
                    x: 64,
                    timestamp: 513.0 / 240
                ),
            ]
        )
        let firstPage = try await advanceToFirstLogicalPreparedBatch(
            firstPreparedPage,
            scheduler: scheduler,
            generation: generation
        )
        #expect(!firstPage.logicalDabs.isEmpty)
        #expect(
            firstPage.logicalDabs.count
                <= LogicalDabBatch.maximumDabCount / 2
        )
        #expect(
            (await scheduler.snapshot).maximumPreparationWorkUnitsPerFrame
                <= LogicalDabBatch.maximumDabCount
        )
        let token = try #require(firstPage.frameToken)

        let mailbox = StrokePreparationMailbox(
            budget: try frameBudget(
                authoritativePerFrame: 128,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            )
        )
        mailbox.publish(.prepared(firstPage))
        var drained: [StrokePreparationResult] = []
        mailbox.drainResults(into: &drained)
        try mailbox.submitCancellation(
            generation: generation,
            reason: nil,
            frameDisposition: .abandonedBeforeSubmission
        )
        let mailboxAcknowledgement = try #require(
            mailbox.takePreparedFrameAcknowledgement()
        )
        #expect(!mailboxAcknowledgement.resumeAuthoritativeContinuation)

        let acknowledgement = await scheduler.acknowledgePreparedFrame(
            generation: generation,
            frameToken: token,
            resumeAuthoritativeContinuation:
                mailboxAcknowledgement.resumeAuthoritativeContinuation
        )
        mailbox.completePreparedFrameAcknowledgement(
            generation: generation,
            token: token
        )
        mailbox.completeWorkerOperation()
        #expect(acknowledgement == nil)
        #expect(
            (await scheduler.snapshot)
                .authoritativeCandidateContinuationPending
        )

        await scheduler.cancel(generation: generation)
        #expect(
            !(await scheduler.snapshot)
                .authoritativeCandidateContinuationPending
        )

        let nextGeneration = generation + 1
        let reused = try await scheduler.beginPreparedStroke(
            generation: nextGeneration,
            configuration: try preparationConfiguration(program: program),
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 32,
                    timestamp: 10
                ),
            ]
        )
        #expect(reused.logicalDabs.map(\.ordinal) == [0])
        await scheduler.cancel(generation: nextGeneration)
    }

    @Test
    func zeroProjectionCandidatePageUsesAContinuationToken()
        async throws
    {
        let generation: UInt64 = 0xC1_12_00
        let scheduler = try preparationScheduler(
            authoritativePerFrame: 4_096,
            preparationClock: { 0 }
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-zero-projection-page",
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let finitePlain = try TilingStrategy(
            finiteConfiguration: .plain,
            canvasSize: PixelSize(width: 512, height: 512)
        )
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: try preparationConfiguration(
                program: program,
                strategy: finitePlain
            ),
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: -10_000,
                    timestamp: 0
                ),
            ]
        )
        _ = try await drainPreparedBatches(
            began,
            scheduler: scheduler,
            generation: generation
        )

        let first = try await scheduler.finishPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .ended,
                    x: -10_000,
                    timestamp: 513.0 / 240
                ),
            ]
        )
        let continuationToken = try #require(first.frameToken)
        #expect(first.dirtyRegions.isEmpty)
        #expect(
            (await scheduler.stageCCleanupSnapshotForTesting)
                .hasBorrowedPreparedOutputPage
        )
        let mailbox = StrokePreparationMailbox(
            budget: try frameBudget(
                authoritativePerFrame: 128,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            )
        )
        mailbox.publish(.prepared(first))
        var mailboxResults: [StrokePreparationResult] = []
        mailbox.drainResults(into: &mailboxResults)
        try mailbox.submit(
            .appendAuthoritative(
                generation: generation,
                samples: [
                    stageCPreparationSample(
                        phase: .moved,
                        x: -10_000,
                        timestamp: 514.0 / 240
                    ),
                ]
            )
        )
        #expect(mailbox.takeInput() == nil)
        try mailbox.acknowledgePreparedFrame(
            generation: generation,
            token: continuationToken
        )
        let leaseAcknowledgement = try #require(
            mailbox.takePreparedFrameAcknowledgement()
        )
        #expect(leaseAcknowledgement.resumeAuthoritativeContinuation)
        mailbox.completePreparedFrameAcknowledgement(
            generation: generation,
            token: continuationToken
        )
        mailbox.completeWorkerOperation()

        let pages = try await drainPreparedBatches(
            first,
            scheduler: scheduler,
            generation: generation
        )
        let logicalPages = pages.filter { !$0.isEmpty }
        #expect(logicalPages.allSatisfy {
            $0.count <= LogicalDabBatch.maximumDabCount / 2
        })
        #expect(logicalPages.flatMap { $0 }.map(\.ordinal)
            == Array(1...UInt64(513)))
        #expect(
            !(await scheduler.snapshot)
                .authoritativeCandidateContinuationPending
        )
        #expect(
            !(await scheduler.stageCCleanupSnapshotForTesting)
                .hasBorrowedPreparedOutputPage
        )
        await scheduler.cancel(generation: generation)
    }

    @Test
    func bridgeDoesNotLetFinishOrCommitOvertakeAZeroProjectionContinuation()
        async throws
    {
        let generation: UInt64 = 0xC1_12_B1
        let bridge = StrokePreparationBridge(
            budget: try frameBudget(
                authoritativePerFrame: 4_096,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            ),
            targetFramesPerSecond: 120
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-bridge-zero-projection",
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let finitePlain = try TilingStrategy(
            finiteConfiguration: .plain,
            canvasSize: PixelSize(width: 512, height: 512)
        )
        try bridge.submit(
            .begin(
                generation: generation,
                configuration: try preparationConfiguration(
                    program: program,
                    strategy: finitePlain
                ),
                samples: [
                    stageCPreparationSample(
                        phase: .began,
                        x: -10_000,
                        timestamp: 0
                    ),
                ]
            )
        )
        _ = try await drainBridgeUntilQuiescent(
            bridge,
            generation: generation,
            // Commit metadata counts settled input. The unresolved began
            // sample remains intentionally transient until finish settles it.
            expectedInputSampleCount: 0,
            requireCommitBarrier: false
        )

        try bridge.submit(
            .finish(
                generation: generation,
                samples: [
                    stageCPreparationSample(
                        phase: .ended,
                        x: -10_000,
                        timestamp: 513.0 / 240
                    ),
                ]
            )
        )
        try bridge.submit(.commit(generation: generation))

        let outcome = try await drainBridgeUntilQuiescent(
            bridge,
            generation: generation,
            // Off-canvas transient chunks are promoted by commit itself, so
            // the last prepared snapshot still reports the pre-promotion
            // settled-input count. Ordering is proven by the finishing batch
            // and exact dab count observed before the commit barrier below.
            expectedInputSampleCount: 0,
            requireCommitBarrier: true
        )
        #expect(outcome.dabs.count == 513)
        #expect(outcome.dabs.map(\.ordinal) == Array(1...UInt64(513)))
        #expect(outcome.zeroWorkAcknowledgementCount > 1)
        #expect(outcome.sawFinishingBatch)
        #expect(outcome.logicalDabCountAtCommitBarrier == 513)
        #expect(!bridge.mailbox.snapshot.input.hasPendingInput)
        #expect(!bridge.mailbox.snapshot.awaitingPreparedFrameSubmission)
    }

    @Test
    func bridgeBlocksPredictionEstimateAndLaterActualBehindCandidateCursor()
        async throws
    {
        let generation: UInt64 = 0xC1_12_F1
        let bridge = StrokePreparationBridge(
            budget: try frameBudget(
                authoritativePerFrame: 4_096,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            ),
            targetFramesPerSecond: 120
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-bridge-fifo",
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let finitePlain = try TilingStrategy(
            finiteConfiguration: .plain,
            canvasSize: PixelSize(width: 512, height: 512)
        )
        try bridge.submit(
            .begin(
                generation: generation,
                configuration: try preparationConfiguration(
                    program: program,
                    strategy: finitePlain
                ),
                samples: [
                    stageCPreparationSample(
                        phase: .began,
                        x: -10_000,
                        timestamp: 0
                    ),
                ]
            )
        )
        _ = try await drainBridgeUntilQuiescent(
            bridge,
            generation: generation,
            expectedInputSampleCount: 0,
            requireCommitBarrier: false
        )

        try bridge.submit(
            .appendAuthoritative(
                generation: generation,
                samples: [
                    stageCPreparationSample(
                        phase: .moved,
                        x: -10_000,
                        timestamp: 1_025.0 / 240
                    ),
                ]
            )
        )
        try bridge.submit(
            .replacePrediction(
                generation: generation,
                samples: [
                    stageCPreparationSample(
                        phase: .moved,
                        x: -10_000,
                        timestamp: 1_025.5 / 240,
                        kind: .predicted
                    ),
                ],
                acceptedCount: 1
            )
        )
        try bridge.submit(
            .applyEstimatedUpdate(
                generation: generation,
                sample: stageCPreparationSample(
                    phase: .moved,
                    x: -10_000,
                    timestamp: 1_025.75 / 240,
                    kind: .estimatedUpdate,
                    estimationUpdateIndex: 404
                )
            )
        )
        try bridge.submit(
            .appendAuthoritative(
                generation: generation,
                samples: [
                    stageCPreparationSample(
                        phase: .moved,
                        x: -10_000,
                        timestamp: 1_026.0 / 240
                    ),
                ]
            )
        )

        let progress = StrokePreparationAsyncProgressRegistration(
            mailbox: bridge.mailbox
        )
        var firstResults: [StrokePreparationResult] = []
        var progressRemoved = false
        defer {
            if !progressRemoved { progress.remove() }
        }
        for _ in 0..<1_000 {
            let revision = progress.currentRevision
            bridge.drainResults(into: &firstResults)
            if !firstResults.isEmpty { break }
            if progress.currentRevision != revision { continue }
            guard try await progress.waitForProgress(
                after: revision,
                timeoutNanoseconds: Self.asyncProgressTimeoutNanoseconds
            ) else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
        }
        let firstPageSnapshot: (token: UInt64, dabs: [LogicalDab]) = try {
            guard case let .prepared(firstPage) = firstResults.first else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
            return (
                try #require(firstPage.frameToken),
                Array(firstPage.logicalDabs)
            )
        }()
        let firstToken = firstPageSnapshot.token
        #expect((1...512).contains(firstPageSnapshot.dabs.count))
        let firstPageLogicalDabs = firstPageSnapshot.dabs
        let blockedMailbox = bridge.mailbox.snapshot
        #expect(blockedMailbox.awaitingPreparedFrameSubmission)
        #expect(blockedMailbox.input.authoritativePendingSampleCount == 2)
        #expect(blockedMailbox.input.predictedPendingSampleCount == 1)
        #expect(
            (await bridge.schedulerSnapshotForTesting())
                .authoritativeCandidateContinuationPending
        )
        var noOvertake: [StrokePreparationResult] = []
        bridge.drainResults(into: &noOvertake)
        #expect(noOvertake.isEmpty)

        firstResults.removeAll(keepingCapacity: true)
        try bridge.acknowledgePreparedFrame(
            generation: generation,
            token: firstToken
        )
        progress.remove()
        progressRemoved = true
        let remainder = try await drainBridgeUntilQuiescent(
            bridge,
            generation: generation,
            expectedInputSampleCount: 0,
            requireCommitBarrier: false
        )
        let actualDabs = (firstPageLogicalDabs + remainder.dabs)
            .filter { !$0.isPredicted }
        #expect(actualDabs.count == 1_026)
        #expect(actualDabs.map(\.ordinal) == Array(1...UInt64(1_026)))
        #expect(remainder.ignoredEstimatedUpdateCount == 1)
        #expect(
            !(await bridge.schedulerSnapshotForTesting())
                .authoritativeCandidateContinuationPending
        )
        #expect(bridge.mailbox.snapshot.isQuiescent)
        try bridge.submit(.cancel(generation: generation, reason: nil))
    }

    @Test
    func bridgeCancellationDuringCandidateResumeDiscardsSuffixAndReuses()
        async throws
    {
        let generation: UInt64 = 0xC1_12_C0
        let bridge = StrokePreparationBridge(
            budget: try frameBudget(
                authoritativePerFrame: 4_096,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            ),
            targetFramesPerSecond: 120
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-bridge-cancel-resume",
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let configuration = try preparationConfiguration(
            program: program,
            strategy: TilingStrategy(
                kind: .grid,
                tileSize: PatternSize(width: 512, height: 512)
            )
        )
        try bridge.submit(
            .begin(
                generation: generation,
                configuration: configuration,
                samples: [
                    stageCPreparationSample(
                        phase: .began,
                        x: -10_000,
                        timestamp: 0
                    ),
                ]
            )
        )
        _ = try await drainBridgeUntilQuiescent(
            bridge,
            generation: generation,
            expectedInputSampleCount: 0,
            requireCommitBarrier: false
        )
        try bridge.submit(
            .appendAuthoritative(
                generation: generation,
                samples: [
                    stageCPreparationSample(
                        phase: .moved,
                        x: -10_000,
                        timestamp: 1_025.0 / 240
                    ),
                ]
            )
        )

        let progress = StrokePreparationAsyncProgressRegistration(
            mailbox: bridge.mailbox
        )
        var progressRemoved = false
        defer {
            if !progressRemoved { progress.remove() }
        }
        var results: [StrokePreparationResult] = []
        var firstPage: StrokePreparedDepositionBatch?
        for _ in 0..<1_000 {
            let revision = progress.currentRevision
            bridge.drainResults(into: &results)
            for result in results {
                switch result {
                case let .prepared(batch) where !batch.logicalDabs.isEmpty:
                    firstPage = batch
                case let .prepared(batch):
                    guard let token = batch.frameToken else {
                        throw StrokeFrameSchedulerError.invalidLifecycle
                    }
                    try bridge.acknowledgePreparedFrame(
                        generation: generation,
                        token: token
                    )
                case let .failed(_, failure):
                    throw StrokePreparationFailure.unexpected(
                        "bridge preparation failed: \(failure)"
                    )
                default:
                    throw StrokeFrameSchedulerError.invalidLifecycle
                }
            }
            if firstPage != nil { break }
            if progress.currentRevision != revision { continue }
            guard try await progress.waitForProgress(
                after: revision,
                timeoutNanoseconds: Self.asyncProgressTimeoutNanoseconds
            ) else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
        }
        let page = try #require(firstPage)
        #expect((1...512).contains(page.logicalDabs.count))
        #expect(page.frameToken != nil)
        #expect(
            (await bridge.schedulerSnapshotForTesting())
                .authoritativeCandidateContinuationPending
        )

        try bridge.submitCancellation(
            generation: generation,
            reason: nil,
            frameDisposition: .abandonedBeforeSubmission
        )
        var sawCancellation = false
        var preparedAfterCancellation = 0
        for _ in 0..<1_000 {
            let revision = progress.currentRevision
            bridge.drainResults(into: &results)
            for result in results {
                switch result {
                case .cancelled(generation, nil):
                    sawCancellation = true
                case .prepared:
                    preparedAfterCancellation += 1
                default:
                    Issue.record(
                        "Unexpected cancellation result: \(result)"
                    )
                }
            }
            if sawCancellation, bridge.mailbox.snapshot.isQuiescent {
                break
            }
            if progress.currentRevision != revision { continue }
            guard try await progress.waitForProgress(
                after: revision,
                timeoutNanoseconds: Self.asyncProgressTimeoutNanoseconds
            ) else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
        }
        #expect(sawCancellation)
        #expect(preparedAfterCancellation == 0)
        #expect(
            bridge.mailbox.snapshot.terminalCancellationPublicationCount
                == 1
        )
        let cancelled = await bridge.schedulerSnapshotForTesting()
        #expect(cancelled.activeGeneration == nil)
        #expect(cancelled.cancelledGeneration == generation)
        #expect(!cancelled.authoritativeCandidateContinuationPending)
        #expect(cancelled.authoritativePending == 0)
        #expect(cancelled.predictedPending == 0)
        progress.remove()
        progressRemoved = true

        let retryGeneration = generation + 1
        try bridge.submit(
            .begin(
                generation: retryGeneration,
                configuration: configuration,
                samples: [
                    stageCPreparationSample(
                        phase: .began,
                        x: 32,
                        timestamp: 10
                    ),
                ]
            )
        )
        let retry = try await drainBridgeUntilQuiescent(
            bridge,
            generation: retryGeneration,
            expectedInputSampleCount: 0,
            requireCommitBarrier: false
        )
        #expect(retry.dabs.map(\.ordinal) == [0])
        try bridge.submit(.cancel(generation: retryGeneration, reason: nil))
    }

    @Test
    func radialExpansionPagesBeforeProjectedInstanceBudget()
        async throws
    {
        let generation: UInt64 = 0xC1_12_FA
        let scheduler = try preparationScheduler(
            authoritativePerFrame: 4_096
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-radial-projection-page",
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let radial = try TilingStrategy(
            finiteConfiguration: .radial(
                RadialSymmetryConfiguration(
                    kind: .mandala,
                    rayCount: 32,
                    center: WorldPoint(x: 256, y: 256)
                )
            ),
            canvasSize: PixelSize(width: 512, height: 512)
        )
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: try preparationConfiguration(
                program: program,
                nominalDiameter: 200,
                strategy: radial
            ),
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 320,
                    timestamp: 0
                ),
            ]
        )
        _ = try await drainPreparedBatches(
            began,
            scheduler: scheduler,
            generation: generation
        )

        let first = try await scheduler.finishPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .ended,
                    x: 320,
                    timestamp: 500.0 / 240
                ),
            ]
        )
        var batches = [PreparedBatchRecord(first)]
        var current: StrokePreparedDepositionBatch? = first
        while let batch = current, let token = batch.frameToken {
            let result = await scheduler.acknowledgePreparedFrame(
                generation: generation,
                frameToken: token
            )
            if case let .prepared(next)? = result {
                batches.append(PreparedBatchRecord(next))
                current = next
            } else if case let .failed(_, failure)? = result {
                Issue.record("Radial continuation failed: \(failure)")
                current = nil
            } else {
                current = nil
            }
        }
        #expect(batches.flatMap(\.logicalDabs).count == 500)
        #expect(
            batches.count > 1,
            "Projected records per batch: \(batches.map { $0.dirtyRegions.count })"
        )
        #expect(batches.allSatisfy { $0.dirtyRegions.count <= 4_096 })
        #expect(
            (await scheduler.snapshot).activeGeneration == generation
        )
        try await scheduler.requestCommit(generation: generation)
        #expect(await scheduler.isCommitReady(generation: generation))
        await scheduler.cancel(generation: generation)
    }

    @Test
    func preparationDeadlineYieldsAnExactRetryablePrefix()
        async throws
    {
        let generation: UInt64 = 0xC1_12_BD
        let budget = try frameBudget(
            authoritativePerFrame: 4_096,
            predictedPerFrame: 4_096,
            authoritativeCapacity: 12_288,
            predictedCapacity: 4_096
        )
        let clock = SteppedPreparationClock(step: 2_000_000)
        let scheduler = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: 120,
            preparationClock: { clock.now() }
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-preparation-deadline",
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let configuration = try preparationConfiguration(program: program)
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 64,
                    timestamp: 0
                ),
            ]
        )
        _ = try await drainPreparedBatches(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let first = try await scheduler.finishPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .ended,
                    x: 64,
                    timestamp: 4.0 / 240
                ),
            ]
        )
        let deadlineBatches = try await drainPreparedBatchRecords(
            first,
            scheduler: scheduler,
            generation: generation
        )
        let deadlinePages = deadlineBatches
            .map(\.logicalDabs)
            .filter { !$0.isEmpty }
        #expect(deadlinePages.map(\.count) == [1, 1, 1, 1])
        // Deadline enforcement is cooperative at the atomic-dab boundary.
        // This clock advances farther than the 1.5 ms budget at every read,
        // proving elapsed time may overshoot while accepted work remains
        // bounded to exactly one indivisible dab per page.
        #expect(
            deadlineBatches.allSatisfy {
                $0.preparationCPUNanoseconds
                    >= budget.cpuPreparationNanoseconds
            }
        )

        let snapshot = await scheduler.snapshot
        #expect(snapshot.authoritativeCandidatePageCount >= 5)
        #expect(snapshot.authoritativeCandidateResumeCount >= 5)
        #expect(snapshot.authoritativeCandidateLogicalHighWater == 1)
        #expect(snapshot.authoritativeCandidateProjectionHighWater <= 4_096)
        #expect(snapshot.maximumPreparationWorkUnitsPerFrame <= 4_096)
        try await scheduler.requestCommit(generation: generation)
        if let frame = try await scheduler.prepareFrame(
            generation: generation
        ) {
            var result = await scheduler.acknowledgePreparedFrame(
                generation: generation,
                frameToken: frame.token
            )
            while case let .prepared(batch)? = result,
                  let token = batch.frameToken
            {
                result = await scheduler.acknowledgePreparedFrame(
                    generation: generation,
                    frameToken: token
                )
            }
        }
        #expect(await scheduler.isCommitReady(generation: generation))

        let baselineGeneration = generation + 1
        let baseline = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: 120
        )
        let baselineBegin = try await baseline.beginPreparedStroke(
            generation: baselineGeneration,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 64,
                    timestamp: 0
                ),
            ]
        )
        _ = try await drainPreparedBatches(
            baselineBegin,
            scheduler: baseline,
            generation: baselineGeneration
        )
        let baselineFinish = try await baseline.finishPreparedStroke(
            generation: baselineGeneration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .ended,
                    x: 64,
                    timestamp: 4.0 / 240
                ),
            ]
        )
        let baselineDabs = try await drainPreparedBatches(
            baselineFinish,
            scheduler: baseline,
            generation: baselineGeneration
        ).flatMap { $0 }
        #expect(deadlinePages.flatMap { $0 } == baselineDabs)
        await scheduler.cancel(generation: generation)
        await baseline.cancel(generation: baselineGeneration)
    }

    @Test
    func zeroDabSamplesHonorCPUDeadlineAndRemainCancellable()
        async throws
    {
        let budget = try frameBudget(
            authoritativePerFrame: 4_096,
            predictedPerFrame: 4_096,
            authoritativeCapacity: 12_288,
            predictedCapacity: 4_096
        )
        let clockStep: UInt64 = 10_000
        let clock = SteppedPreparationClock(step: clockStep)
        let scheduler = StrokeFrameScheduler(
            budget: budget,
            targetFramesPerSecond: 120,
            preparationClock: { clock.now() }
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-zero-dab-deadline",
            replayMode: .appendOnly,
            emission: BrushEmissionDefinition(
                mode: .distance,
                timeInterval: nil
            )
        )
        let configuration = try preparationConfiguration(program: program)
        let stationary = (1...4_096).map { index in
            stageCPreparationSample(
                phase: .moved,
                x: 64,
                timestamp: Double(index) / 240
            )
        }

        let generation: UInt64 = 0xC1_12_0D
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 64,
                    timestamp: 0
                ),
            ]
        )
        _ = try await drainPreparedBatchRecords(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let storageBeforeMaximumBatch = await scheduler.snapshot
        let first = try await scheduler.appendPreparedStroke(
            generation: generation,
            actualSamples: stationary
        )
        let pages = try await drainPreparedBatchRecords(
            first,
            scheduler: scheduler,
            generation: generation
        )
        #expect(pages.count > 3)
        // Component cursor transitions are now charged work, even when they
        // emit no dab. The deadline may therefore observe several resumable
        // cursor steps per sample, but must still batch a meaningful input
        // prefix instead of degenerating to one acknowledgement per sample.
        let minimumSamplesPerDeadlinePage = 8
        let maximumDeadlinePages =
            (stationary.count + minimumSamplesPerDeadlinePage - 1)
                / minimumSamplesPerDeadlinePage
                + 2
        #expect(
            pages.count <= maximumDeadlinePages,
            "The 4,096-sample zero-dab trace must not degenerate to one ACK per sample"
        )
        #expect(pages.allSatisfy { $0.logicalDabs.isEmpty })
        #expect(pages.allSatisfy { $0.dirtyRegions.isEmpty })
        let deadlineSnapshot = await scheduler.snapshot
        #expect(
            deadlineSnapshot.transientChunkStorageCapacity
                == storageBeforeMaximumBatch.transientChunkStorageCapacity
        )
        #expect(
            deadlineSnapshot.settledChunkStorageCapacity
                == storageBeforeMaximumBatch.settledChunkStorageCapacity
        )
        #expect(
            deadlineSnapshot.perMutationSettledStorageCapacity
                == storageBeforeMaximumBatch.perMutationSettledStorageCapacity
        )
        #expect(
            deadlineSnapshot.maximumPreparationWorkUnitsPerFrame
                < LogicalDabBatch.maximumDabCount,
            "The CPU deadline must page zero-emission samples before the 512-work fallback"
        )

        let finished = try await scheduler.finishPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .ended,
                    x: 64,
                    timestamp: Double(stationary.count + 1) / 240
                ),
            ]
        )
        _ = try await drainPreparedBatchRecords(
            finished,
            scheduler: scheduler,
            generation: generation
        )
        try await scheduler.requestCommit(generation: generation)
        #expect(await scheduler.isCommitReady(generation: generation))
        await scheduler.cancel(generation: generation)

        let cancelledGeneration = generation + 1
        let cancelBegin = try await scheduler.beginPreparedStroke(
            generation: cancelledGeneration,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 64,
                    timestamp: 0
                ),
            ]
        )
        _ = try await drainPreparedBatchRecords(
            cancelBegin,
            scheduler: scheduler,
            generation: cancelledGeneration
        )
        let outstanding = try await scheduler.appendPreparedStroke(
            generation: cancelledGeneration,
            actualSamples: stationary
        )
        #expect(outstanding.frameToken != nil)
        #expect(outstanding.logicalDabs.isEmpty)
        #expect(
            (await scheduler.snapshot)
                .authoritativeCandidateContinuationPending
        )
        await scheduler.cancel(generation: cancelledGeneration)
        #expect(
            !(await scheduler.snapshot)
                .authoritativeCandidateContinuationPending
        )

        let reusedGeneration = generation + 2
        let reused = try await scheduler.beginPreparedStroke(
            generation: reusedGeneration,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 32,
                    timestamp: 0
                ),
            ]
        )
        #expect(reused.logicalDabs.map(\.ordinal) == [0])
        await scheduler.cancel(generation: reusedGeneration)
    }

    @Test
    func retainedReplayPreparationYieldsAtTheCandidatePageBoundary()
        async throws
    {
        let generation: UInt64 = 0xC1_12_B0
        let maximumWorkPerReturn = LogicalDabBatch.maximumDabCount
        let scheduler = try preparationScheduler(
            authoritativePerFrame: maximumWorkPerReturn
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-retained-work-budget",
            replayMode: .replayTail,
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let finitePlain = try TilingStrategy(
            finiteConfiguration: .plain,
            canvasSize: PixelSize(width: 512, height: 512)
        )
        let configuration = try preparationConfiguration(
            program: program,
            strategy: finitePlain
        )

        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 64,
                    timestamp: 0
                ),
            ]
        )
        _ = try await drainPreparedBatchRecords(
            began,
            scheduler: scheduler,
            generation: generation
        )

        // Retain 1,993 logical dabs: close enough to the 2,048-dab replay-tail
        // limit that a later replacement must not count and reproject the
        // complete tail in one scheduler turn.
        let retainedSamples = (1..<250).map { index in
            stageCPreparationSample(
                phase: .moved,
                x: 64,
                timestamp: Double(index * 8) / 240
            )
        }
        let retainedFirst = try await scheduler.appendPreparedStroke(
            generation: generation,
            actualSamples: retainedSamples
        )
        let retainedBatches = try await drainPreparedBatchRecords(
            retainedFirst,
            scheduler: scheduler,
            generation: generation
        )
        #expect(
            retainedBatches.flatMap(\.logicalDabs).count == 1_992
        )
        #expect((await scheduler.snapshot).retainedActualSampleCount == 250)

        // This one sample emits enough dabs to exercise cursor continuation
        // and to settle most of the old replay tail. Both reprojection of the
        // retained tail and settled-transfer validation must remain page
        // bounded, rather than hiding thousands of scans in a single return.
        let replacementFirst = try await scheduler.appendPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .moved,
                    x: 64,
                    timestamp: Double(249 * 8 + 1_800) / 240
                ),
            ]
        )
        let replacementBatches = try await drainPreparedBatchRecords(
            replacementFirst,
            scheduler: scheduler,
            generation: generation
        )
        #expect(replacementBatches.count > 4)
        #expect(
            replacementBatches.flatMap(\.logicalDabs).count == 1_800
        )
        #expect(
            replacementBatches.allSatisfy {
                $0.authoritativeInstanceCount <= maximumWorkPerReturn
                    && $0.predictedInstanceCount <= maximumWorkPerReturn
            }
        )
        #expect(
            replacementBatches.allSatisfy {
                $0.preparationCPUNanoseconds < 100_000_000
            },
            "A retained-state scheduler return monopolized its actor for 100 ms"
        )

        let replacementSnapshot = await scheduler.snapshot
        #expect(replacementSnapshot.authoritativeCandidatePageCount > 4)
        #expect(replacementSnapshot.authoritativeCandidateResumeCount > 4)
        #expect(
            replacementSnapshot.maximumPreparationWorkUnitsPerFrame
                <= maximumWorkPerReturn,
            "Retained replay counting, reprojection, and settled transfer must be included in the per-return work budget"
        )
        // Leave another cursor continuation outstanding, cancel between
        // pages, and prove no retained-work transaction poisons rapid reuse.
        let cancellationFirst = try await scheduler.appendPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .moved,
                    x: 64,
                    timestamp: Double(249 * 8 + 1_800 + 513) / 240
                ),
            ]
        )
        #expect(cancellationFirst.frameToken != nil)
        #expect(
            (await scheduler.snapshot)
                .authoritativeCandidateContinuationPending
        )
        await scheduler.cancel(generation: generation)
        let cancelled = await scheduler.snapshot
        #expect(cancelled.activeGeneration == nil)
        #expect(cancelled.cancelledGeneration == generation)
        #expect(!cancelled.authoritativeCandidateContinuationPending)
        #expect(cancelled.retainedActualSampleCount == 0)

        let retryGeneration = generation + 1
        let retry = try await scheduler.beginPreparedStroke(
            generation: retryGeneration,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 32,
                    timestamp: 0
                ),
            ]
        )
        #expect(retry.logicalDabs.map(\.ordinal) == [0])
        await scheduler.cancel(generation: retryGeneration)
    }

    @Test
    func retainedProjectionAtPendingCapacityDrainsBeforeCandidateResume()
        async throws
    {
        let generation: UInt64 = 0xC1_12_B1
        let pendingCapacity = 8
        let scheduler = StrokeFrameScheduler(
            budget: try frameBudget(
                authoritativePerFrame: 4,
                predictedPerFrame: 4,
                authoritativeCapacity: pendingCapacity,
                predictedCapacity: pendingCapacity
            ),
            targetFramesPerSecond: 120,
            preparationClock: { 0 }
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-retained-exact-capacity",
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let configuration = try preparationConfiguration(
            program: program,
            strategy: TilingStrategy(
                kind: .grid,
                tileSize: PatternSize(width: 512, height: 512)
            )
        )
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 64,
                    timestamp: 0
                ),
            ]
        )
        _ = try await drainPreparedBatchRecords(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let seed = try await scheduler.appendPreparedStroke(
            generation: generation,
            actualSamples: (1..<pendingCapacity).map { index in
                stageCPreparationSample(
                    phase: .moved,
                    x: 64,
                    timestamp: Double(index) / 240
                )
            }
        )
        #expect(
            try await drainPreparedBatches(
                seed,
                scheduler: scheduler,
                generation: generation
            ).flatMap { $0 }.count == pendingCapacity - 1
        )
        let retained = await scheduler.transientPreparationSnapshotForTesting
        #expect(retained.actualDabs.count == pendingCapacity)
        #expect(
            retained.actualDabs.reduce(0) {
                $0 + $1.projectedInstanceCount
            } == pendingCapacity
        )

        var candidateFirst: StrokePreparedDepositionBatch?
        do {
            candidateFirst = try await scheduler.appendPreparedStroke(
                generation: generation,
                actualSamples: [
                    stageCPreparationSample(
                        phase: .moved,
                        x: 64,
                        timestamp: Double(pendingCapacity) / 240
                    ),
                ]
            )
        } catch {
            Issue.record(
                "An exactly-full retained prefix must drain before the candidate resumes: \(error)"
            )
        }
        if let candidateFirst {
            let batches = try await drainPreparedBatchRecords(
                candidateFirst,
                scheduler: scheduler,
                generation: generation
            )
            #expect(batches.count >= 3)
            #expect(batches.flatMap(\.logicalDabs).map(\.ordinal) == [8])
            #expect(
                batches.allSatisfy {
                    $0.authoritativeInstanceCount <= 4
                        && $0.predictedInstanceCount <= 4
                }
            )
            #expect(
                !(await scheduler.snapshot)
                    .authoritativeCandidateContinuationPending
            )
        }
        await scheduler.cancel(generation: generation)
    }

    @Test
    func indivisibleProjectionAbovePendingCapacityFailsTypedAndReuses()
        async throws
    {
        let generation: UInt64 = 0xC1_12_B2
        let pendingCapacity = 17
        let scheduler = StrokeFrameScheduler(
            budget: try frameBudget(
                authoritativePerFrame: pendingCapacity,
                predictedPerFrame: 4,
                authoritativeCapacity: pendingCapacity,
                predictedCapacity: pendingCapacity
            ),
            targetFramesPerSecond: 120,
            preparationClock: { 0 }
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-retained-over-capacity",
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let configuration = try preparationConfiguration(
            program: program,
            strategy: TilingStrategy(
                finiteConfiguration: .radial(
                    RadialSymmetryConfiguration(
                        kind: .mandala,
                        rayCount: pendingCapacity + 1,
                        center: WorldPoint(x: 256, y: 256)
                    )
                ),
                canvasSize: PixelSize(width: 512, height: 512)
            )
        )
        do {
            _ = try await scheduler.beginPreparedStroke(
                generation: generation,
                configuration: configuration,
                actualSamples: [
                    stageCPreparationSample(
                        phase: .began,
                        x: 256,
                        y: 256,
                        timestamp: 0
                    ),
                ]
            )
            Issue.record("Expected one indivisible projection to fail")
        } catch let error as StrokeFrameSchedulerError {
            #expect(
                error == .projectedInstanceCapacityExceeded(
                    actual: pendingCapacity + 1,
                    maximum: pendingCapacity
                )
            )
        }
        let failed = await scheduler.snapshot
        #expect(failed.activeGeneration == nil)
        #expect(failed.cancelledGeneration == generation)
        #expect(!failed.authoritativeCandidateContinuationPending)
        #expect(failed.retainedActualSampleCount == 0)

        let retryGeneration = generation + 1
        let retry = try await scheduler.beginPreparedStroke(
            generation: retryGeneration,
            configuration: try preparationConfiguration(
                program: program,
                strategy: TilingStrategy(
                    finiteConfiguration: .plain,
                    canvasSize: PixelSize(width: 512, height: 512)
                )
            ),
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 32,
                    timestamp: 0
                ),
            ]
        )
        #expect(retry.logicalDabs.map(\.ordinal) == [0])
        await scheduler.cancel(generation: retryGeneration)
    }

    @Test
    func candidateCapacityFailureAfterPublishedPagesRollsBackAndReuses()
        async throws
    {
        let generation: UInt64 = 0xC1_12_FC
        let scheduler = try preparationScheduler(
            authoritativePerFrame: 4_096,
            preparationClock: { 0 }
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-cursor-capacity-failure",
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let finitePlain = try TilingStrategy(
            finiteConfiguration: .plain,
            canvasSize: PixelSize(width: 512, height: 512)
        )
        let configuration = try preparationConfiguration(
            program: program,
            strategy: finitePlain
        )
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: -10_000,
                    timestamp: 0
                ),
            ]
        )
        _ = try await drainPreparedBatches(
            began,
            scheduler: scheduler,
            generation: generation
        )

        var current: StrokePreparationResult? = .prepared(
            try await scheduler.finishPreparedStroke(
                generation: generation,
                actualSamples: [
                    stageCPreparationSample(
                        phase: .ended,
                        x: -10_000,
                        timestamp: 5_000.0 / 240
                    ),
                ]
            )
        )
        var acceptedPages: [[LogicalDab]] = []
        var failure: StrokePreparationFailure?
        while let result = current {
            switch result {
            case let .prepared(batch):
                acceptedPages.append(Array(batch.logicalDabs))
                guard let token = batch.frameToken else {
                    Issue.record("Expected continuation token before overflow")
                    current = nil
                    continue
                }
                current = await scheduler.acknowledgePreparedFrame(
                    generation: generation,
                    frameToken: token
                )
            case let .failed(_, actualFailure):
                failure = actualFailure
                current = nil
            default:
                Issue.record("Unexpected cursor-overflow result")
                current = nil
            }
        }
        #expect(acceptedPages.allSatisfy {
            $0.count <= LogicalDabBatch.maximumDabCount / 2
        })
        let accepted = acceptedPages.flatMap { $0 }
        #expect(accepted.map(\.ordinal)
            == Array(1...UInt64(accepted.count)))
        #expect(accepted.count < 4_096)
        #expect(
            failure == .scheduler(
                .generatedDabCapacityExceeded(
                    actual: 4_097,
                    maximum: 4_096
                )
            )
        )
        let cancelled = await scheduler.snapshot
        #expect(cancelled.activeGeneration == nil)
        #expect(cancelled.cancelledGeneration == generation)
        #expect(!cancelled.authoritativeCandidateContinuationPending)
        #expect(cancelled.authoritativePending == 0)
        #expect(cancelled.predictedPending == 0)
        #expect(cancelled.retainedActualSampleCount == 0)
        #expect(cancelled.retainedPredictedSampleCount == 0)

        let retryGeneration = generation + 1
        let retry = try await scheduler.beginPreparedStroke(
            generation: retryGeneration,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 32,
                    timestamp: 0
                ),
            ]
        )
        #expect(retry.logicalDabs.map(\.ordinal) == [0])
        await scheduler.cancel(generation: retryGeneration)
    }

    @Test
    func invalidContinuationAcknowledgementFailsClosedAndReuses()
        async throws
    {
        let generation: UInt64 = 0xC1_12_AC
        let scheduler = try preparationScheduler(
            authoritativePerFrame: 4_096,
            preparationClock: { 0 }
        )
        let program = try stageCMetalTestProgram(
            id: "test.scheduler.stage-c-invalid-continuation-ack",
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let configuration = try preparationConfiguration(program: program)
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 32,
                    timestamp: 0
                ),
            ]
        )
        _ = try await drainPreparedBatches(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let page = try await scheduler.finishPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .ended,
                    x: 32,
                    timestamp: 513.0 / 240
                ),
            ]
        )
        let token = try #require(page.frameToken)
        let failed = await scheduler.acknowledgePreparedFrame(
            generation: generation,
            frameToken: token + 1
        )
        guard case .failed(
            generation,
            .scheduler(.invalidPreparedFrame)
        ) = failed else {
            Issue.record("Expected typed invalid continuation ACK failure")
            return
        }
        let cancelled = await scheduler.snapshot
        #expect(cancelled.activeGeneration == nil)
        #expect(cancelled.cancelledGeneration == generation)
        #expect(!cancelled.authoritativeCandidateContinuationPending)
        #expect(!cancelled.frameOutstanding)

        let retryGeneration = generation + 1
        let retry = try await scheduler.beginPreparedStroke(
            generation: retryGeneration,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 32,
                    timestamp: 0
                ),
            ]
        )
        #expect(retry.logicalDabs.map(\.ordinal) == [0])
        await scheduler.cancel(generation: retryGeneration)
    }

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
                == PredictionAdmissionLimits.maximumNormalizedSampleCount
        )
        #expect(queue.snapshot.authoritativeStorageCapacity >= 12)
        #expect(
            queue.snapshot.predictionStorageCapacity
                >= PredictionAdmissionLimits.maximumNormalizedSampleCount
        )
    }

    @Test
    func authoritativeInputBatchLimitPreservesAggregateQueueCapacity()
        throws
    {
        var queue = try StrokeInputQueue(
            authoritativeCapacity: 12_288,
            predictionCapacity: 2
        )
        let acceptedGeneration: UInt64 = 0xC1_12_40
        let accepted = samples(0..<4_096)
        try queue.enqueue(
            .appendAuthoritative(
                generation: acceptedGeneration,
                samples: accepted
            )
        )
        #expect(queue.snapshot.authoritativeCapacity == 12_288)
        #expect(queue.snapshot.authoritativePendingSampleCount == 4_096)
        #expect(
            queue.dequeue()
                == .appendAuthoritative(
                    generation: acceptedGeneration,
                    samples: accepted
                )
        )

        let rejectedGeneration = acceptedGeneration + 1
        let rejected = samples(0..<4_097)
        #expect(
            throws: StrokeInputQueueError.authoritativeCapacityExceeded(
                generation: rejectedGeneration,
                current: 0,
                incoming: 4_097,
                maximum: 4_096
            )
        ) {
            try queue.enqueue(
                .appendAuthoritative(
                    generation: rejectedGeneration,
                    samples: rejected
                )
            )
        }
        #expect(queue.snapshot.authoritativeCapacity == 12_288)
        #expect(queue.snapshot.authoritativePendingSampleCount == 0)
        #expect(queue.snapshot.cancelledGeneration == rejectedGeneration)
        #expect(
            queue.dequeue()
                == .cancel(
                    generation: rejectedGeneration,
                    reason: .authoritativeCapacityExceeded(
                        current: 0,
                        incoming: 4_097,
                        maximum: 4_096
                    )
                )
        )

        let reusedGeneration = rejectedGeneration + 1
        try queue.enqueue(
            .appendAuthoritative(
                generation: reusedGeneration,
                samples: samples(0..<1)
            )
        )
        #expect(queue.snapshot.authoritativePendingSampleCount == 1)
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
                        property: [],
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
        let actualBefore =
            (await scheduler.transientPreparationSnapshotForTesting)
                .actualSamples

        let updateResult = await scheduler.process(
            .applyEstimatedUpdate(
                generation: generation,
                sample: estimatedPreparationSample(
                    phase: .moved,
                    kind: .estimatedUpdate,
                    index: 88,
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
        #expect(predictedAfter.position == predictedBefore.position)
        #expect(
            predictedAfter.artisticVelocity
                != predictedBefore.artisticVelocity
        )
        #expect(correctedSnapshot.actualSamples == actualBefore)
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
        let diagnostic = try #require(
            await scheduler.lastEstimatedUpdateSnapshotForTesting
        )
        #expect(diagnostic.target == .predicted)
        #expect(diagnostic.rederivedSampleCount == 2)
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
    func stageCDirectionalZeroDabBeginSurvivesPredictionAndActualReplay()
        async throws
    {
        let scheduler = try preparationScheduler()
        let generation: UInt64 = 451
        let configuration = try preparationConfiguration(
            program: stageCMetalTestProgram(
                id: "test.scheduler-stage-c-held-begin",
                usesTravelDirection: true,
                baseSpacingFraction: 0.05
            )
        )
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 12,
                    timestamp: 0
                ),
            ]
        )
        #expect(began.logicalDabs.isEmpty)
        try await acknowledgeAll(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let beganSnapshot =
            await scheduler.transientPreparationSnapshotForTesting
        #expect(
            beganSnapshot.actualSamples.count == 1,
            "retained actual count: \(beganSnapshot.actualSamples.count); replay contract: \(configuration.program.replayContract)"
        )
        #expect(beganSnapshot.actualDabs.isEmpty)

        let actualBeforePrediction =
            await scheduler.transientPreparationSnapshotForTesting
        let prediction = try await scheduler.replacePreparedPrediction(
            generation: generation,
            samples: [
                stageCPreparationSample(
                    phase: .moved,
                    x: 52,
                    timestamp: 1,
                    kind: .predicted
                ),
            ]
        )
        #expect(prediction.logicalDabs.first?.ordinal == 0)
        #expect(prediction.logicalDabs.allSatisfy { $0.isPredicted })
        let withPrediction =
            await scheduler.transientPreparationSnapshotForTesting
        #expect(withPrediction.actualSamples == actualBeforePrediction.actualSamples)
        #expect(withPrediction.actualDabs == actualBeforePrediction.actualDabs)
        #expect(withPrediction.predictedSamples.count == 1)
        #expect(withPrediction.predictedDabs.first?.attributes.ordinal == 0)
        try await acknowledgeAll(
            prediction,
            scheduler: scheduler,
            generation: generation
        )

        let clearedPrediction = try await scheduler.replacePreparedPrediction(
            generation: generation,
            samples: []
        )
        try await acknowledgeAll(
            clearedPrediction,
            scheduler: scheduler,
            generation: generation
        )
        let actual = try await scheduler.appendPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .moved,
                    x: 52,
                    timestamp: 1
                ),
            ]
        )
        #expect(actual.logicalDabs.first?.ordinal == 0)
        #expect(actual.logicalDabs.allSatisfy { !$0.isPredicted })
        try await acknowledgeAll(
            actual,
            scheduler: scheduler,
            generation: generation
        )

        let finished = try await scheduler.finishPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .ended,
                    x: 68,
                    timestamp: 2
                ),
            ]
        )
        let finishingBatches = try await drainPreparedBatchRecords(
            finished,
            scheduler: scheduler,
            generation: generation
        )
        #expect(!finishingBatches.isEmpty)
        #expect(finishingBatches.dropLast().allSatisfy { !$0.isFinishing })
        #expect(finishingBatches.last?.isFinishing == true)
        await scheduler.cancel(generation: generation)
    }

    @Test
    func stageCEstimatedReplacementRestoresPrecedingCheckpointOnce()
        async throws
    {
        let program = try stageCMetalTestProgram(
            id: "test.scheduler-stage-c-estimated",
            stabilization: .weightedWindow(distance: 24),
            usesTravelDirection: true,
            baseSpacingFraction: 0.05
        )
        let configuration = try preparationConfiguration(program: program)
        let generation: UInt64 = 452
        let scheduler = try preparationScheduler()
        let source = [
            stageCPreparationSample(
                phase: .began,
                x: 10,
                timestamp: 0
            ),
            stageCPreparationSample(
                phase: .moved,
                x: 40,
                timestamp: 1,
                estimationUpdateIndex: 701,
                estimatedProperties: .location
            ),
            stageCPreparationSample(
                phase: .moved,
                x: 72,
                timestamp: 2
            ),
        ]
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: source
        )
        try await acknowledgeAll(
            began,
            scheduler: scheduler,
            generation: generation
        )

        let updateResult = await scheduler.process(
            .applyEstimatedUpdate(
                generation: generation,
                sample: stageCPreparationSample(
                    phase: .moved,
                    x: 52,
                    timestamp: 1,
                    kind: .estimatedUpdate,
                    estimationUpdateIndex: 701
                )
            )
        )
        guard case let .prepared(corrected) = updateResult else {
            Issue.record("Expected Stage C estimated replay preparation")
            return
        }
        let diagnostic = try #require(
            await scheduler.lastEstimatedUpdateSnapshotForTesting
        )
        #expect(diagnostic.target == .authoritative)
        #expect(diagnostic.rederivedSampleCount == 2)
        let correctedSnapshot =
            await scheduler.transientPreparationSnapshotForTesting

        let clean = try preparationScheduler()
        let cleanGeneration: UInt64 = 453
        let cleanBatch = try await clean.beginPreparedStroke(
            generation: cleanGeneration,
            configuration: configuration,
            actualSamples: [
                source[0],
                stageCPreparationSample(
                    phase: .moved,
                    x: 52,
                    timestamp: 1
                ),
                source[2],
            ]
        )
        let cleanDabs = try await drainPreparedBatches(
            cleanBatch,
            scheduler: clean,
            generation: cleanGeneration
        ).flatMap { $0 }
        let cleanSnapshot = await clean.transientPreparationSnapshotForTesting
        #expect(correctedSnapshot.actualDabs == cleanSnapshot.actualDabs)
        #expect(correctedSnapshot.predictedDabs.isEmpty)
        #expect(corrected.logicalDabs.last == cleanDabs.last)
        try await acknowledgeAll(
            corrected,
            scheduler: scheduler,
            generation: generation
        )
        await scheduler.cancel(generation: generation)
        await clean.cancel(generation: cleanGeneration)
    }

    @Test
    func stageCCornerFailureIsTypedAndFreshGenerationIsReusable()
        async throws
    {
        let scheduler = try preparationScheduler()
        let configuration = try preparationConfiguration(
            program: stageCMetalTestProgram(
                id: "test.scheduler-stage-c-failure",
                usesTravelDirection: true,
                maximumAngularStep: .pi / 180,
                baseSpacingFraction: 0.05
            )
        )
        let generation: UInt64 = 454
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 40,
                    timestamp: 0
                ),
                stageCPreparationSample(
                    phase: .moved,
                    x: 80,
                    timestamp: 1
                ),
            ]
        )
        try await acknowledgeAll(
            began,
            scheduler: scheduler,
            generation: generation
        )

        let firstFailurePage = await scheduler.process(
            .appendAuthoritative(
                generation: generation,
                samples: [
                    stageCPreparationSample(
                        phase: .moved,
                        x: 40,
                        timestamp: 2
                    ),
                ]
            )
        )
        let failed = await driveUntilInjectedFailure(
            firstFailurePage,
            scheduler: scheduler,
            generation: generation
        )
        let failureSnapshot = await scheduler.snapshot
        guard case .failed(
            generation,
            .cornerEmission(.capacityExceeded(
                requiredCandidateCount: 179,
                maximumCandidateCount:
                    StrokeEmissionCandidateBuffer.maximumCount
            ))
        ) = failed else {
            Issue.record(
                "Expected typed Stage C corner-capacity failure; actual=\(String(describing: failed)); snapshot=\(failureSnapshot)"
            )
            return
        }
        let cancelled = await scheduler.snapshot
        #expect(cancelled.activeGeneration == nil)
        #expect(cancelled.cancelledGeneration == generation)
        #expect(cancelled.retainedActualSampleCount == 0)
        #expect(cancelled.retainedPredictedSampleCount == 0)

        let retryGeneration: UInt64 = 455
        let retryBegin = try await scheduler.beginPreparedStroke(
            generation: retryGeneration,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 20,
                    timestamp: 0
                ),
            ]
        )
        #expect(retryBegin.logicalDabs.isEmpty)
        try await acknowledgeAll(
            retryBegin,
            scheduler: scheduler,
            generation: retryGeneration
        )
        let retryMove = try await scheduler.appendPreparedStroke(
            generation: retryGeneration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .moved,
                    x: 60,
                    timestamp: 1
                ),
            ]
        )
        let retryPages = try await drainPreparedBatchRecords(
            retryMove,
            scheduler: scheduler,
            generation: retryGeneration
        )
        #expect(retryPages.flatMap(\.logicalDabs).first?.ordinal == 0)
        await scheduler.cancel(generation: retryGeneration)
    }

    @Test
    func predictedCornerOverflowShedsPredictionWithoutCancellingActualState()
        async throws
    {
        let scheduler = try preparationScheduler()
        let generation: UInt64 = 456
        let configuration = try preparationConfiguration(
            program: stageCMetalTestProgram(
                id: "test.scheduler-stage-c-predicted-corner-overflow",
                usesTravelDirection: true,
                maximumAngularStep: .pi / 180,
                baseSpacingFraction: 0.05
            )
        )
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 40,
                    timestamp: 0
                ),
                stageCPreparationSample(
                    phase: .moved,
                    x: 80,
                    timestamp: 1
                ),
            ]
        )
        try await acknowledgeAll(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let actualBefore =
            await scheduler.transientPreparationSnapshotForTesting

        let prediction = try await scheduler.replacePreparedPrediction(
            generation: generation,
            samples: [
                stageCPreparationSample(
                    phase: .moved,
                    x: 40,
                    timestamp: 2,
                    kind: .predicted
                ),
            ]
        )

        #expect(
            prediction.predictionAdmission?.overload
                .contains(.logicalDabs) == true
        )
        #expect(prediction.logicalDabs.isEmpty)
        let afterPrediction =
            await scheduler.transientPreparationSnapshotForTesting
        #expect(afterPrediction.actualSamples == actualBefore.actualSamples)
        #expect(afterPrediction.actualDabs == actualBefore.actualDabs)
        #expect(afterPrediction.predictedDabs.isEmpty)
        try await acknowledgeAll(
            prediction,
            scheduler: scheduler,
            generation: generation
        )
        let appended = try await scheduler.appendPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .moved,
                    x: 120,
                    timestamp: 3
                ),
            ]
        )
        let appendedPages = try await drainPreparedBatchRecords(
            appended,
            scheduler: scheduler,
            generation: generation
        )
        #expect(!appendedPages.flatMap(\.logicalDabs).isEmpty)
        await scheduler.cancel(generation: generation)
    }

    @Test
    func predictedLateCornerKeyOverflowRollsBackAllSampleWork() async throws {
        let scheduler = try preparationScheduler()
        let generation: UInt64 = 458
        let configuration = try preparationConfiguration(
            program: stageCMetalTestProgram(
                id: "test.scheduler-stage-c-predicted-late-key-overflow",
                usesTravelDirection: true,
                maximumAngularStep: .pi / 6,
                baseSpacingFraction: 0.01
            )
        )
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 100,
                    y: 100,
                    timestamp: 0
                ),
                stageCPreparationSample(
                    phase: .moved,
                    x: 70,
                    y: 70,
                    timestamp: 1
                ),
            ]
        )
        try await acknowledgeAll(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let actualBefore =
            await scheduler.transientPreparationSnapshotForTesting

        let prediction = try await scheduler.replacePreparedPrediction(
            generation: generation,
            samples: [
                stageCPreparationSample(
                    phase: .moved,
                    x: 70,
                    y: 68,
                    timestamp: 10_000_000_001,
                    kind: .predicted
                ),
            ]
        )

        #expect(
            prediction.predictionAdmission?.overload
                .contains(.logicalDabs) == true
        )
        #expect(prediction.logicalDabs.isEmpty)
        let afterPrediction =
            await scheduler.transientPreparationSnapshotForTesting
        #expect(afterPrediction.actualSamples == actualBefore.actualSamples)
        #expect(afterPrediction.actualDabs == actualBefore.actualDabs)
        #expect(afterPrediction.predictedDabs.isEmpty)

        try await acknowledgeAll(
            prediction,
            scheduler: scheduler,
            generation: generation
        )
        let appended = try await scheduler.appendPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .moved,
                    x: 40,
                    y: 40,
                    timestamp: 2
                ),
            ]
        )
        let appendedPages = try await drainPreparedBatchRecords(
            appended,
            scheduler: scheduler,
            generation: generation
        )
        #expect(!appendedPages.flatMap(\.logicalDabs).isEmpty)
        await scheduler.cancel(generation: generation)
    }

    @Test
    func predictedEstimatedCornerOverflowDoesNotCancelActualState()
        async throws
    {
        let scheduler = try preparationScheduler()
        let generation: UInt64 = 457
        let estimateIndex = 457
        let configuration = try preparationConfiguration(
            program: stageCMetalTestProgram(
                id: "test.scheduler-stage-c-estimated-corner-overflow",
                usesTravelDirection: true,
                maximumAngularStep: .pi / 180,
                baseSpacingFraction: 0.05
            )
        )
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 40,
                    timestamp: 0
                ),
                stageCPreparationSample(
                    phase: .moved,
                    x: 80,
                    timestamp: 1
                ),
            ]
        )
        try await acknowledgeAll(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let prediction = try await scheduler.replacePreparedPrediction(
            generation: generation,
            samples: [
                stageCPreparationSample(
                    phase: .moved,
                    x: 120,
                    timestamp: 2,
                    kind: .predicted,
                    estimationUpdateIndex: estimateIndex,
                    estimatedProperties: [.location]
                ),
            ]
        )
        try await acknowledgeAll(
            prediction,
            scheduler: scheduler,
            generation: generation
        )
        let actualBefore =
            await scheduler.transientPreparationSnapshotForTesting

        let result = await scheduler.process(.applyEstimatedUpdate(
            generation: generation,
            sample: stageCPreparationSample(
                phase: .moved,
                x: 40,
                timestamp: 2,
                kind: .estimatedUpdate,
                estimationUpdateIndex: estimateIndex
            )
        ))
        guard case let .prepared(corrected) = result else {
            Issue.record("Expected predicted corner overflow to be shed")
            return
        }
        #expect(
            corrected.predictionAdmission?.overload
                .contains(.logicalDabs) == true
        )
        #expect(corrected.logicalDabs.isEmpty)
        let afterCorrection =
            await scheduler.transientPreparationSnapshotForTesting
        #expect(afterCorrection.actualSamples == actualBefore.actualSamples)
        #expect(afterCorrection.actualDabs == actualBefore.actualDabs)
        #expect(afterCorrection.predictedDabs.isEmpty)
        try await acknowledgeAll(
            corrected,
            scheduler: scheduler,
            generation: generation
        )
        let appended = try await scheduler.appendPreparedStroke(
            generation: generation,
            actualSamples: [
                stageCPreparationSample(
                    phase: .moved,
                    x: 120,
                    timestamp: 3
                ),
            ]
        )
        let appendedPages = try await drainPreparedBatchRecords(
            appended,
            scheduler: scheduler,
            generation: generation
        )
        #expect(!appendedPages.flatMap(\.logicalDabs).isEmpty)
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
    func mailboxNeverReentersSchedulerWithCancellationDuringWorkerAwait()
        throws
    {
        let mailbox = StrokePreparationMailbox(
            budget: try frameBudget(
                authoritativePerFrame: 4,
                predictedPerFrame: 2,
                authoritativeCapacity: 12,
                predictedCapacity: 4
            )
        )
        let generation: UInt64 = 0xC1_12_A5
        try mailbox.submit(
            .appendAuthoritative(
                generation: generation,
                samples: samples(0..<1)
            )
        )
        #expect(mailbox.takeInput() != nil)
        #expect(mailbox.snapshot.workerIsProcessing)

        // The one bridge worker remains the scheduler's only caller while its
        // actor call awaits Metal completion. Cancellation may be queued from
        // Main, but cannot enter the actor and mutate the reference-owned
        // continuation until the suspended call has returned.
        try mailbox.submitCancellation(
            generation: generation,
            reason: nil,
            frameDisposition: .preserveMainOwnership
        )
        #expect(mailbox.takeInput() == nil)
        #expect(mailbox.snapshot.workerIsProcessing)

        mailbox.completeWorkerOperation()
        guard case .cancel(generation, nil)? = mailbox.takeInput() else {
            Issue.record("Queued cancellation did not follow worker completion")
            return
        }
        mailbox.completeWorkerOperation()
        #expect(mailbox.snapshot.isQuiescent)
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

    private func preparationScheduler(
        targetFramesPerSecond: Int = 120,
        authoritativePerFrame: Int = 128,
        preparationClock: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws -> StrokeFrameScheduler {
        StrokeFrameScheduler(
            budget: try frameBudget(
                authoritativePerFrame: authoritativePerFrame,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            ),
            targetFramesPerSecond: targetFramesPerSecond,
            preparationClock: preparationClock
        )
    }

    private func drainPreparedBatches(
        _ first: StrokePreparedDepositionBatch,
        scheduler: StrokeFrameScheduler,
        generation: UInt64
    ) async throws -> [[LogicalDab]] {
        try await drainPreparedBatchRecords(
            first,
            scheduler: scheduler,
            generation: generation
        ).map(\.logicalDabs)
    }

    /// Test-owned value snapshot. Prepared batch collections are token-scoped
    /// page views and must never be retained or read after acknowledgement.
    private struct PreparedBatchRecord {
        let logicalDabs: [LogicalDab]
        let dirtyRegions: [PixelRect]
        let authoritativeInstanceCount: Int
        let predictedInstanceCount: Int
        let preparationCPUNanoseconds: UInt64
        let isFinishing: Bool

        init(_ batch: StrokePreparedDepositionBatch) {
            logicalDabs = Array(batch.logicalDabs)
            dirtyRegions = Array(batch.dirtyRegions)
            authoritativeInstanceCount = batch.authoritativeInstanceCount
            predictedInstanceCount = batch.predictedInstanceCount
            preparationCPUNanoseconds = batch.preparationCPUNanoseconds
            isFinishing = batch.isFinishing
        }
    }

    private func drainPreparedBatchRecords(
        _ first: StrokePreparedDepositionBatch,
        scheduler: StrokeFrameScheduler,
        generation: UInt64
    ) async throws -> [PreparedBatchRecord] {
        var pages: [PreparedBatchRecord] = []
        var current: StrokePreparedDepositionBatch? = first
        while let batch = current {
            pages.append(PreparedBatchRecord(batch))
            guard let token = batch.frameToken else { break }
            let next = await scheduler.acknowledgePreparedFrame(
                generation: generation,
                frameToken: token
            )
            switch next {
            case let .prepared(prepared):
                current = prepared
            case let .failed(_, failure):
                Issue.record("Preparation acknowledgement failed: \(failure)")
                current = nil
            case nil:
                current = nil
            default:
                Issue.record("Unexpected preparation acknowledgement result")
                current = nil
            }
        }
        return pages
    }

    private func advanceToFirstLogicalPreparedBatch(
        _ first: StrokePreparedDepositionBatch,
        scheduler: StrokeFrameScheduler,
        generation: UInt64
    ) async throws -> StrokePreparedDepositionBatch {
        var current = first
        for _ in 0..<10_000 {
            if !current.logicalDabs.isEmpty { return current }
            guard let token = current.frameToken else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
            let next = await scheduler.acknowledgePreparedFrame(
                generation: generation,
                frameToken: token
            )
            guard case let .prepared(prepared)? = next else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
            current = prepared
        }
        throw StrokeFrameSchedulerError.invalidLifecycle
    }

    private func drainBridgeUntilQuiescent(
        _ bridge: StrokePreparationBridge,
        generation: UInt64,
        expectedInputSampleCount: UInt64,
        requireCommitBarrier: Bool
    ) async throws -> (
        dabs: [LogicalDab],
        zeroWorkAcknowledgementCount: Int,
        sawFinishingBatch: Bool,
        ignoredEstimatedUpdateCount: Int,
        logicalDabCountAtCommitBarrier: Int?
    ) {
        let progress = StrokePreparationAsyncProgressRegistration(
            mailbox: bridge.mailbox
        )
        defer { progress.remove() }
        var resultScratch: [StrokePreparationResult] = []
        resultScratch.reserveCapacity(1)
        var dabs: [LogicalDab] = []
        var zeroWorkAcknowledgementCount = 0
        var sawFinishingBatch = false
        var ignoredEstimatedUpdateCount = 0
        var latestInputSampleCount: UInt64 = 0
        var commitBarrierReached = false
        var logicalDabCountAtCommitBarrier: Int?

        for _ in 0..<10_000 {
            let revision = progress.currentRevision
            bridge.drainResults(into: &resultScratch)
            var deferredAcknowledgement: (generation: UInt64, token: UInt64)?
            for result in resultScratch {
                switch result {
                case let .prepared(batch):
                    dabs.append(contentsOf: batch.logicalDabs)
                    sawFinishingBatch = sawFinishingBatch || batch.isFinishing
                    latestInputSampleCount = batch.coordinatorSnapshot
                        .commitMetadata.inputSampleCount
                    if let token = batch.frameToken {
                        if batch.surfaceLease == nil {
                            zeroWorkAcknowledgementCount += 1
                        }
                        deferredAcknowledgement = (generation, token)
                    }
                case let .commitBarrierReached(resultGeneration, _):
                    #expect(resultGeneration == generation)
                    commitBarrierReached = true
                    logicalDabCountAtCommitBarrier = dabs.count
                case let .failed(_, failure):
                    throw StrokePreparationFailure.unexpected(
                        "bridge failure \(failure); dabs=\(dabs.count); "
                            + "mailbox=\(bridge.mailbox.snapshot); "
                            + "scheduler=\(await bridge.schedulerSnapshotForTesting())"
                    )
                case .cancelled:
                    throw StrokeFrameSchedulerError.invalidLifecycle
                case .estimatedUpdateWasIgnored:
                    ignoredEstimatedUpdateCount += 1
                case .predictionWasShed,
                     .estimatedUpdateWasRejected:
                    break
                }
            }
            resultScratch.removeAll(keepingCapacity: true)
            if let deferredAcknowledgement {
                try bridge.acknowledgePreparedFrame(
                    generation: deferredAcknowledgement.generation,
                    token: deferredAcknowledgement.token
                )
            }

            let mailbox = bridge.mailbox.snapshot
            if latestInputSampleCount == expectedInputSampleCount,
               mailbox.isQuiescent,
               (!requireCommitBarrier || commitBarrierReached)
            {
                return (
                    dabs,
                    zeroWorkAcknowledgementCount,
                    sawFinishingBatch,
                    ignoredEstimatedUpdateCount,
                    logicalDabCountAtCommitBarrier
                )
            }

            if bridge.mailbox.snapshot.isQuiescent,
               latestInputSampleCount != expectedInputSampleCount
            {
                throw StrokePreparationFailure.unexpected(
                    "bridge became quiescent at input count "
                        + "\(latestInputSampleCount), expected "
                    + "\(expectedInputSampleCount); dabs=\(dabs.count)"
                )
            }
            if progress.currentRevision != revision { continue }
            guard try await progress.waitForProgress(
                after: revision,
                timeoutNanoseconds: Self.asyncProgressTimeoutNanoseconds
            ) else {
                throw StrokePreparationFailure.unexpected(
                    "bridge progress timed out; mailbox=\(bridge.mailbox.snapshot)"
                )
            }
        }
        throw StrokeFrameSchedulerError.invalidLifecycle
    }

    private func preparationConfiguration(
        program: BrushProgram? = nil,
        nominalDiameter: Float = 10,
        strategy: TilingStrategy? = nil,
        metalResourceDescriptor: StrokeMetalResourceDescriptor? = nil
    ) throws
        -> StrokePreparationConfiguration
    {
        let selectedProgram: BrushProgram
        if let program {
            selectedProgram = program
        } else {
            selectedProgram = try BrushProgramCompiler.compile(
                StageFourAnchorDefinitions.ink
            )
        }
        return StrokePreparationConfiguration(
            program: selectedProgram,
            nominalDiameter: nominalDiameter,
            color: .black,
            seed: 7,
            viewport: ViewportTransform(
                drawableSize: PatternSize(width: 512, height: 512),
                worldCenter: WorldPoint(x: 256, y: 256)
            ),
            tilingStrategy: strategy ?? TilingStrategy(
                kind: .grid,
                tileSize: PatternSize(width: 512, height: 512)
            ),
            metalResourceDescriptor: metalResourceDescriptor
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

    private func stageCPreparationSample(
        phase: StrokePhase,
        x: Float,
        y: Float = 32,
        timestamp: TimeInterval,
        kind: StrokeSampleKind = .actual,
        estimationUpdateIndex: Int? = nil,
        estimatedProperties: StrokeEstimatedProperties = []
    ) -> StrokeSample {
        StrokeSample(
            position: ScreenPoint(x: x, y: y),
            pressure: 0.5,
            timestamp: timestamp,
            phase: phase,
            source: .pencil,
            kind: kind,
            capabilities: [.pressure, .altitude, .azimuth],
            altitude: 0.7,
            azimuth: 0.8,
            estimationUpdateIndex: estimationUpdateIndex,
            estimatedProperties: estimatedProperties,
            estimatedPropertiesExpectingUpdates:
                kind == .estimatedUpdate ? [] : estimatedProperties
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

extension StrokeFrameSchedulerTests {
    @Test
    func injectedStageCFailuresCleanEveryMutationBoundaryAndReuse()
        async throws
    {
        let seams = StrokeStageCFailureInjectionSeam.allCases.filter { seam in
            switch seam {
            case .beforeSurfaceEncoding, .afterSurfaceEncoding,
                 .beforeAcknowledgementResume, .afterAcknowledgementResume,
                 .beforeFinishGate, .afterFinishGate:
                false
            default:
                true
            }
        }

        for (offset, seam) in seams.enumerated() {
            let generation = UInt64(0xC1_12_D0 + offset * 2)
            let injector = OneShotStageCFailureInjector(seam: seam)
            let scheduler = StrokeFrameScheduler(
                budget: try frameBudget(
                    authoritativePerFrame: 4_096,
                    predictedPerFrame: 4_096,
                    authoritativeCapacity: 12_288,
                    predictedCapacity: 4_096
                ),
                targetFramesPerSecond: 120,
                preparationClock: { 0 },
                stageCFailureInjection: injector.injection
            )
            let replayMode: BrushReplayMode = switch seam {
            case .beforeCoordinatorReserve, .afterCoordinatorReserve,
                 .beforeCoordinatorFinalize, .afterCoordinatorFinalize:
                .appendOnly
            default:
                .replayTail
            }
            let configuration = try preparationConfiguration(
                program: stageCMetalTestProgram(
                    id: "test.scheduler.stage-c-failure-\(seam.rawValue)",
                    replayMode: replayMode
                )
            )
            let requiresRetainedState: Bool = switch seam {
            case .beforeRetainedProjection, .afterRetainedProjection:
                true
            default:
                false
            }
            let firstResult: StrokePreparationResult?
            if requiresRetainedState {
                let began = await scheduler.process(
                    .begin(
                        generation: generation,
                        configuration: configuration,
                        samples: [
                            stageCPreparationSample(
                                phase: .began,
                                x: 64,
                                timestamp: 0
                            ),
                        ]
                    )
                )
                guard case let .prepared(beginBatch)? = began else {
                    Issue.record("Failed to seed Stage C seam \(seam)")
                    continue
                }
                _ = try await drainPreparedBatchRecords(
                    beginBatch,
                    scheduler: scheduler,
                    generation: generation
                )
                firstResult = await scheduler.process(
                    .appendAuthoritative(
                        generation: generation,
                        samples: [
                            stageCPreparationSample(
                                phase: .moved,
                                x: 80,
                                timestamp: 1
                            ),
                        ]
                    )
                )
            } else {
                firstResult = await scheduler.process(
                    .begin(
                        generation: generation,
                        configuration: configuration,
                        samples: [
                            stageCPreparationSample(
                                phase: .began,
                                x: 64,
                                timestamp: 0
                            ),
                        ]
                    )
                )
            }
            let result = await driveUntilInjectedFailure(
                firstResult,
                scheduler: scheduler,
                generation: generation
            )
            #expect(injector.didInject)
            guard case let .failed(
                actualGeneration,
                failure
            )? = result else {
                Issue.record("Expected typed failure at Stage C seam \(seam)")
                await scheduler.cancel(generation: generation)
                continue
            }
            #expect(actualGeneration == generation)
            #expect(failure == .injectedStageC(seam))
            try await assertInjectedFailureCleanupAndReuse(
                scheduler,
                failedGeneration: generation,
                configuration: configuration
            )
        }
    }

    @Test
    func injectedStageCAcknowledgementAndFinishFailuresCleanAndReuse()
        async throws
    {
        let cases: [(StrokeStageCFailureInjectionSeam, Bool)] = [
            (.beforeAcknowledgementResume, false),
            (.afterAcknowledgementResume, false),
            (.beforeFinishGate, true),
            (.afterFinishGate, true),
        ]
        for (offset, entry) in cases.enumerated() {
            let (seam, isFinishGate) = entry
            let generation = UInt64(0xC1_12_E0 + offset * 2)
            let injector = OneShotStageCFailureInjector(
                seam: seam,
                initiallyArmed: isFinishGate
            )
            let scheduler = StrokeFrameScheduler(
                budget: try frameBudget(
                    authoritativePerFrame: 4_096,
                    predictedPerFrame: 4_096,
                    authoritativeCapacity: 12_288,
                    predictedCapacity: 4_096
                ),
                targetFramesPerSecond: 120,
                preparationClock: { 0 },
                stageCFailureInjection: injector.injection
            )
            let configuration = try preparationConfiguration(
                program: stageCMetalTestProgram(
                    id: "test.scheduler.stage-c-deferred-\(seam.rawValue)",
                    emission: BrushEmissionDefinition(
                        mode: .time,
                        timeInterval: 1.0 / 240
                    )
                )
            )
            let began = await scheduler.process(
                .begin(
                    generation: generation,
                    configuration: configuration,
                    samples: [
                        stageCPreparationSample(
                            phase: .began,
                            x: 64,
                            timestamp: 0
                        ),
                    ]
                )
            )
            guard case let .prepared(beginBatch)? = began else {
                Issue.record("Failed to prepare deferred seam \(seam)")
                continue
            }

            let result: StrokePreparationResult?
            if isFinishGate {
                _ = try await drainPreparedBatchRecords(
                    beginBatch,
                    scheduler: scheduler,
                    generation: generation
                )
                let finish = await scheduler.process(
                    .finish(
                        generation: generation,
                        samples: [
                            stageCPreparationSample(
                                phase: .ended,
                                x: 80,
                                timestamp: 1
                            ),
                        ]
                    )
                )
                result = await driveUntilInjectedFailure(
                    finish,
                    scheduler: scheduler,
                    generation: generation
                )
            } else {
                _ = try await drainPreparedBatchRecords(
                    beginBatch,
                    scheduler: scheduler,
                    generation: generation
                )
                injector.arm()
                let page = await scheduler.process(
                    .appendAuthoritative(
                        generation: generation,
                        samples: [
                            stageCPreparationSample(
                                phase: .moved,
                                x: 64,
                                timestamp: 513.0 / 240
                            ),
                        ]
                    )
                )
                result = await driveUntilInjectedFailure(
                    page,
                    scheduler: scheduler,
                    generation: generation
                )
            }
            #expect(injector.didInject)
            guard case let .failed(
                actualGeneration,
                failure
            )? = result else {
                Issue.record("Expected typed deferred failure at \(seam)")
                await scheduler.cancel(generation: generation)
                continue
            }
            #expect(actualGeneration == generation)
            #expect(failure == .injectedStageC(seam))
            try await assertInjectedFailureCleanupAndReuse(
                scheduler,
                failedGeneration: generation,
                configuration: configuration
            )
        }
    }

    @Test
    @MainActor
    func injectedStageCSurfaceFailuresCleanAndReuse() async throws {
        guard let setup = try await stageCSurfaceTestSetup() else { return }
        for (offset, seam) in [
            StrokeStageCFailureInjectionSeam.beforeSurfaceEncoding,
            .afterSurfaceEncoding,
        ].enumerated() {
            let generation = UInt64(0xC1_12_F0 + offset * 2)
            let injector = OneShotStageCFailureInjector(seam: seam)
            let store = PaintTileStore(
                device: setup.device,
                byteBudget: PaintTileDescriptor.residentByteCount * 32
            )
            let surfaces = try stageCCurrentSurfaceResources(
                device: setup.device,
                store: store,
                layerID: UUID(),
                generation: generation,
                pixelSize: PixelSize(width: 512, height: 512),
                pipeline: setup.tilePipeline
            )
            let descriptor = StrokeMetalResourceDescriptor(
                surfaces: surfaces,
                brush: setup.brush,
                frameUniforms: stageCSurfaceFrameUniforms(side: 512),
                forceCommandFailure: false
            )
            let scheduler = StrokeFrameScheduler(
                budget: try frameBudget(
                    authoritativePerFrame: 4_096,
                    predictedPerFrame: 4_096,
                    authoritativeCapacity: 12_288,
                    predictedCapacity: 4_096
                ),
                targetFramesPerSecond: 120,
                preparationClock: { 0 },
                stageCFailureInjection: injector.injection
            )
            let configuration = try preparationConfiguration(
                program: stageCMetalTestProgram(
                    id: "test.scheduler.stage-c-surface-\(seam.rawValue)"
                ),
                metalResourceDescriptor: descriptor
            )
            let first = await scheduler.process(
                .begin(
                    generation: generation,
                    configuration: configuration,
                    samples: [
                        stageCPreparationSample(
                            phase: .began,
                            x: 64,
                            timestamp: 0
                        ),
                    ]
                )
            )
            let result = await driveUntilInjectedFailure(
                first,
                scheduler: scheduler,
                generation: generation
            )
            #expect(injector.didInject)
            guard case let .failed(actualGeneration, failure)? = result else {
                Issue.record("Expected typed surface failure at \(seam)")
                await scheduler.cancel(generation: generation)
                continue
            }
            #expect(actualGeneration == generation)
            #expect(failure == .injectedStageC(seam))
            let retryGeneration = generation + 1
            let retrySurfaces = try stageCCurrentSurfaceResources(
                device: setup.device,
                store: store,
                layerID: UUID(),
                generation: retryGeneration,
                pixelSize: PixelSize(width: 512, height: 512),
                pipeline: setup.tilePipeline
            )
            let retryConfiguration = try preparationConfiguration(
                program: stageCMetalTestProgram(
                    id: "test.scheduler.stage-c-surface-retry-\(seam.rawValue)"
                ),
                metalResourceDescriptor: StrokeMetalResourceDescriptor(
                    surfaces: retrySurfaces,
                    brush: setup.brush,
                    frameUniforms: stageCSurfaceFrameUniforms(side: 512),
                    forceCommandFailure: false
                )
            )
            try await assertInjectedFailureCleanupAndReuse(
                scheduler,
                failedGeneration: generation,
                configuration: configuration,
                retryConfiguration: retryConfiguration
            )
            #expect(store.snapshot().activeLeaseCount == 0)
            #expect(store.snapshot().entries.isEmpty)
        }
    }

    @Test
    @MainActor
    func capabilityBackedSurfaceRunsThroughSchedulerAndReleasesPins()
        async throws
    {
        guard let setup = try await stageCSurfaceTestSetup() else { return }
        let generation: UInt64 = 0xD5_01
        let store = PaintTileStore(
            device: setup.device,
            byteBudget: PaintTileDescriptor.residentByteCount * 32
        )
        let surfaces = try stageCCurrentSurfaceResources(
            device: setup.device,
            store: store,
            layerID: UUID(
                uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )!,
            generation: generation,
            pixelSize: PixelSize(width: 512, height: 512),
            pipeline: setup.tilePipeline
        )
        let descriptor = StrokeMetalResourceDescriptor(
            surfaces: surfaces,
            brush: setup.brush,
            frameUniforms: stageCSurfaceFrameUniforms(side: 512),
            forceCommandFailure: false
        )

        let scheduler = StrokeFrameScheduler(
            budget: try frameBudget(
                authoritativePerFrame: 4_096,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            ),
            targetFramesPerSecond: 120,
            preparationClock: { 0 }
        )
        let configuration = try preparationConfiguration(
            program: stageCMetalTestProgram(
                id: "test.scheduler.stage-d-tiled",
                replayMode: .appendOnly
            ),
            metalResourceDescriptor: descriptor
        )
        let began = await scheduler.process(.begin(
            generation: generation,
            configuration: configuration,
            samples: [stageCPreparationSample(
                phase: .began,
                x: 64,
                timestamp: 0
            )]
        ))
        guard case let .prepared(first)? = began,
              let firstLease = first.surfaceLease
        else {
            Issue.record("Expected capability-backed begin lease")
            return
        }
        #expect(!firstLease.tiledBindings.isEmpty)
        #expect(first.surfaceSnapshot?.surfaceCount == 2)
        #expect(first.surfaceSnapshot?.residentTileHighWater ?? 0 > 0)
        let afterAck = await scheduler.acknowledgePreparedFrame(
            generation: generation,
            frameToken: firstLease.token
        )
        if case let .prepared(continuation)? = afterAck {
            try await acknowledgeAll(
                continuation,
                scheduler: scheduler,
                generation: generation
            )
        } else if case let .failed(_, failure)? = afterAck {
            Issue.record("Capability-backed ACK failed: \(failure)")
        }
        #expect(store.snapshot().activeLeaseCount == 0)

        let appended = await scheduler.process(.appendAuthoritative(
            generation: generation,
            samples: [stageCPreparationSample(
                phase: .moved,
                x: 320,
                timestamp: 1.0 / 120
            )]
        ))
        guard case let .prepared(second)? = appended,
              let secondLease = second.surfaceLease
        else {
            Issue.record("Expected capability-backed append lease")
            return
        }
        #expect(secondLease.tiledBindings.count >= firstLease.tiledBindings.count)
        await scheduler.cancel(generation: generation)
        #expect((await scheduler.snapshot).activeGeneration == nil)
        #expect(store.snapshot().activeLeaseCount == 1)
        #expect(!store.snapshot().entries.isEmpty)

        let cancelledAck = await scheduler.acknowledgePreparedFrame(
            generation: generation,
            frameToken: secondLease.token
        )
        #expect(cancelledAck == nil)
        #expect(store.snapshot().activeLeaseCount == 0)
        #expect(store.snapshot().entries.isEmpty)
    }

    @Test
    @MainActor
    func capabilityBackedSchedulerRunsPredictionEstimateFinishAndReuse()
        async throws
    {
        guard let setup = try await stageCSurfaceTestSetup() else { return }
        let generation: UInt64 = 0xD5_10
        let store = PaintTileStore(
            device: setup.device,
            byteBudget: PaintTileDescriptor.residentByteCount * 32
        )
        let firstResources = try stageCCurrentSurfaceResources(
            device: setup.device,
            store: store,
            layerID: UUID(),
            generation: generation,
            pixelSize: PixelSize(width: 512, height: 512),
            pipeline: setup.tilePipeline
        )
        let firstAuthoritativeSurfaceID =
            firstResources.capability.testingAuthoritativeSurfaceID
        let firstPredictionSurfaceID =
            firstResources.capability.testingPredictionSurfaceID
        let firstDescriptor = StrokeMetalResourceDescriptor(
            surfaces: firstResources,
            brush: setup.brush,
            frameUniforms: stageCSurfaceFrameUniforms(side: 512),
            forceCommandFailure: false
        )
        let scheduler = StrokeFrameScheduler(
            budget: try frameBudget(
                authoritativePerFrame: 4_096,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            ),
            targetFramesPerSecond: 120,
            preparationClock: { 0 }
        )
        let configuration = try preparationConfiguration(
            program: stageCMetalTestProgram(
                id: "test.scheduler.stage-d-tiled-lifecycle",
                replayMode: .appendOnly
            ),
            metalResourceDescriptor: firstDescriptor
        )
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [
                stageCPreparationSample(
                    phase: .began,
                    x: 64,
                    timestamp: 0
                ),
                stageCPreparationSample(
                    phase: .moved,
                    x: 96,
                    timestamp: 1,
                    estimationUpdateIndex: 701,
                    estimatedProperties: .location
                ),
            ]
        )
        #expect(began.surfaceLease?.layer == .authoritative)
        try await acknowledgeAll(
            began,
            scheduler: scheduler,
            generation: generation
        )

        let prediction = try await scheduler.replacePreparedPrediction(
            generation: generation,
            samples: [stageCPreparationSample(
                phase: .moved,
                x: 128,
                timestamp: 2,
                kind: .predicted
            )]
        )
        #expect(prediction.surfaceLease?.layer == .prediction)
        try await acknowledgeAll(
            prediction,
            scheduler: scheduler,
            generation: generation
        )

        let estimate = await scheduler.process(.applyEstimatedUpdate(
            generation: generation,
            sample: stageCPreparationSample(
                phase: .moved,
                x: 104,
                timestamp: 1,
                kind: .estimatedUpdate,
                estimationUpdateIndex: 701
            )
        ))
        guard case let .prepared(estimated)? = estimate else {
            Issue.record("Expected capability-backed estimated replacement")
            return
        }
        #expect(estimated.surfaceLease?.layer == .authoritative)
        try await acknowledgeAll(
            estimated,
            scheduler: scheduler,
            generation: generation
        )

        let appended = try await scheduler.appendPreparedStroke(
            generation: generation,
            actualSamples: [stageCPreparationSample(
                phase: .moved,
                x: 144,
                timestamp: 3
            )]
        )
        try await acknowledgeAll(
            appended,
            scheduler: scheduler,
            generation: generation
        )
        let finished = try await scheduler.finishPreparedStroke(
            generation: generation,
            actualSamples: [stageCPreparationSample(
                phase: .ended,
                x: 160,
                timestamp: 4
            )]
        )
        let finishing = try await drainPreparedBatchRecords(
            finished,
            scheduler: scheduler,
            generation: generation
        )
        #expect(finishing.last?.isFinishing == true)
        await scheduler.cancel(generation: generation)
        #expect(store.snapshot().activeLeaseCount == 0)
        #expect(store.snapshot().entries.isEmpty)

        let reusedGeneration = generation + 1
        let reusedResources = try stageCCurrentSurfaceResources(
            device: setup.device,
            store: store,
            layerID: UUID(),
            generation: reusedGeneration,
            pixelSize: PixelSize(width: 512, height: 512),
            pipeline: setup.tilePipeline
        )
        #expect(
            reusedResources.capability.testingAuthoritativeSurfaceID
                != firstAuthoritativeSurfaceID
        )
        #expect(
            reusedResources.capability.testingPredictionSurfaceID
                != firstPredictionSurfaceID
        )
        let reusedConfiguration = try preparationConfiguration(
            program: stageCMetalTestProgram(
                id: "test.scheduler.stage-d-tiled-lifecycle-reused",
                replayMode: .appendOnly
            ),
            metalResourceDescriptor: StrokeMetalResourceDescriptor(
                surfaces: reusedResources,
                brush: setup.brush,
                frameUniforms: stageCSurfaceFrameUniforms(side: 512),
                forceCommandFailure: false
            )
        )
        let reused = try await scheduler.beginPreparedStroke(
            generation: reusedGeneration,
            configuration: reusedConfiguration,
            actualSamples: [stageCPreparationSample(
                phase: .began,
                x: 80,
                timestamp: 10
            )]
        )
        try await acknowledgeAll(
            reused,
            scheduler: scheduler,
            generation: reusedGeneration
        )
        await scheduler.cancel(generation: reusedGeneration)
        #expect(store.snapshot().activeLeaseCount == 0)
        #expect(store.snapshot().entries.isEmpty)
    }

    @Test
    @MainActor
    func capabilityBackedCommitPublishesSourceOnlyAfterFinalACK()
        async throws
    {
        guard let setup = try await stageCSurfaceTestSetup() else { return }
        let generation: UInt64 = 0xD5_11
        let store = PaintTileStore(
            device: setup.device,
            byteBudget: PaintTileDescriptor.residentByteCount * 32
        )
        let layerID = UUID()
        let resources = try StrokeTileSurfaceResources(
            device: setup.device,
            commandQueue: setup.device.makeCommandQueue()!,
            capability: try .testing(
                store: store,
                layerID: layerID,
                pixelSize: PixelSize(width: 512, height: 512),
                generation: generation
            ),
            maximumRecordCount: 4_096,
            maximumTileReferenceCount: 16_384
        )
        let scheduler = StrokeFrameScheduler(
            budget: try frameBudget(
                authoritativePerFrame: 4_096,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            ),
            targetFramesPerSecond: 120,
            preparationClock: { 0 }
        )
        let configuration = try preparationConfiguration(
            program: stageCMetalTestProgram(
                id: "test.scheduler.task6-atomic-source-barrier",
                replayMode: .appendOnly
            ),
            metalResourceDescriptor: StrokeMetalResourceDescriptor(
                surfaces: resources,
                brush: setup.brush,
                frameUniforms: stageCSurfaceFrameUniforms(side: 512),
                forceCommandFailure: false
            )
        )
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: configuration,
            actualSamples: [stageCPreparationSample(
                phase: .began,
                x: 64,
                timestamp: 0
            )]
        )
        try await acknowledgeAll(
            began,
            scheduler: scheduler,
            generation: generation
        )
        let finished = try await scheduler.finishPreparedStroke(
            generation: generation,
            actualSamples: [stageCPreparationSample(
                phase: .ended,
                x: 96,
                timestamp: 1
            )]
        )
        _ = try await drainPreparedBatchRecords(
            finished,
            scheduler: scheduler,
            generation: generation
        )

        let commit = await scheduler.process(.commit(generation: generation))
        guard case let .prepared(commitPage)? = commit,
              let commitToken = commitPage.frameToken
        else {
            Issue.record("Commit must first publish one ACK-scoped page")
            return
        }
        #expect(!resources.capability.isTerminal)
        #expect(resources.snapshot.activeLeaseCount == 0)

        let barrier = await scheduler.acknowledgePreparedFrame(
            generation: generation,
            frameToken: commitToken
        )
        guard case let .commitBarrierReached(
            barrierGeneration,
            commitMutation
        )? = barrier,
        case let .source(source) = commitMutation
        else {
            Issue.record("Final ACK must atomically publish the opaque source")
            return
        }
        #expect(barrierGeneration == generation)
        #expect(!source.coordinates.isEmpty)
        #expect(resources.snapshot.activeLeaseCount == 1)
        #expect(!resources.capability.isTerminal)

        try source.cancelUnclaimed()
        #expect(resources.snapshot.activeLeaseCount == 0)
        #expect(resources.capability.isTerminal)
        await scheduler.cancel(generation: generation)
        #expect(store.snapshot().entries.isEmpty)
    }

    @Test
    @MainActor
    func capabilityBackedCommandFailureRetiresAndReusesImmediately()
        async throws
    {
        guard let setup = try await stageCSurfaceTestSetup() else { return }
        let generation: UInt64 = 0xD5_20
        let store = PaintTileStore(
            device: setup.device,
            byteBudget: PaintTileDescriptor.residentByteCount * 16
        )
        func resources(_ value: UInt64) throws -> StrokeTileSurfaceResources {
            try stageCCurrentSurfaceResources(
                device: setup.device,
                store: store,
                layerID: UUID(),
                generation: value,
                pixelSize: PixelSize(width: 512, height: 512),
                pipeline: setup.tilePipeline
            )
        }
        let failingResources = try resources(generation)
        let scheduler = StrokeFrameScheduler(
            budget: try frameBudget(
                authoritativePerFrame: 4_096,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            ),
            targetFramesPerSecond: 120,
            preparationClock: { 0 }
        )
        let failed = await scheduler.process(.begin(
            generation: generation,
            configuration: try preparationConfiguration(
                program: stageCMetalTestProgram(
                    id: "test.scheduler.stage-d-tiled-failure",
                    replayMode: .appendOnly
                ),
                metalResourceDescriptor: StrokeMetalResourceDescriptor(
                    surfaces: failingResources,
                    brush: setup.brush,
                    frameUniforms: stageCSurfaceFrameUniforms(side: 512),
                    forceCommandFailure: true
                )
            ),
            samples: [stageCPreparationSample(
                phase: .began,
                x: 64,
                timestamp: 0
            )]
        ))
        guard case let .failed(actual, .tileSurface(.commandFailed(_)))? = failed
        else {
            Issue.record("Expected typed tiled command failure")
            return
        }
        #expect(actual == generation)
        #expect(store.snapshot().activeLeaseCount == 0)
        #expect(store.snapshot().entries.isEmpty)

        let reusedGeneration = generation + 1
        let goodResources = try resources(reusedGeneration)
        let recovered = try await scheduler.beginPreparedStroke(
            generation: reusedGeneration,
            configuration: try preparationConfiguration(
                program: stageCMetalTestProgram(
                    id: "test.scheduler.stage-d-tiled-failure-reuse",
                    replayMode: .appendOnly
                ),
                metalResourceDescriptor: StrokeMetalResourceDescriptor(
                    surfaces: goodResources,
                    brush: setup.brush,
                    frameUniforms: stageCSurfaceFrameUniforms(side: 512),
                    forceCommandFailure: false
                )
            ),
            actualSamples: [stageCPreparationSample(
                phase: .began,
                x: 64,
                timestamp: 1
            )]
        )
        try await acknowledgeAll(
            recovered,
            scheduler: scheduler,
            generation: reusedGeneration
        )
        await scheduler.cancel(generation: reusedGeneration)
        #expect(store.snapshot().entries.isEmpty)
    }

    @Test
    @MainActor
    func capabilityBackedSchedulerMapsRadialPagesIntoCompactAtlas()
        async throws
    {
        guard let setup = try await stageCSurfaceTestSetup() else { return }
        let generation: UInt64 = 0xD5_30
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 12,
                center: WorldPoint(x: 256, y: 256)
            )),
            canvasSize: PixelSize(width: 512, height: 512)
        )
        let layout = try #require(
            strategy.compiledSymmetry.domain.finite?.radial.layout
        )
        let store = PaintTileStore(
            device: setup.device,
            byteBudget: PaintTileDescriptor.residentByteCount * 64
        )
        let surfaces = try stageCCurrentSurfaceResources(
            device: setup.device,
            store: store,
            layerID: UUID(),
            generation: generation,
            pixelSize: layout.atlasPixelSize,
            pipeline: setup.tilePipeline
        )
        let scheduler = StrokeFrameScheduler(
            budget: try frameBudget(
                authoritativePerFrame: 4_096,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            ),
            targetFramesPerSecond: 120,
            preparationClock: { 0 }
        )
        let began = try await scheduler.beginPreparedStroke(
            generation: generation,
            configuration: try preparationConfiguration(
                program: stageCMetalTestProgram(
                    id: "test.scheduler.stage-d-tiled-radial",
                    replayMode: .appendOnly
                ),
                strategy: strategy,
                metalResourceDescriptor: StrokeMetalResourceDescriptor(
                    surfaces: surfaces,
                    brush: setup.brush,
                    frameUniforms: stageCSurfaceFrameUniforms(side: 512),
                    radialLayout: layout,
                    forceCommandFailure: false
                )
            ),
            actualSamples: [stageCPreparationSample(
                phase: .began,
                x: 320,
                y: 256,
                timestamp: 0
            )]
        )
        let bindings = try #require(began.surfaceLease).tiledBindings
        #expect(!bindings.isEmpty)
        #expect(began.authoritativeInstanceCount > 0)
        #expect(bindings.allSatisfy {
            let coordinate = $0.descriptor.coordinate
            return layout.residentPages.contains { page in
                coordinate == PaintTileCoordinate(
                    x: page.atlasSlot % layout.atlasColumns,
                    y: page.atlasSlot / layout.atlasColumns
                )
            }
        })
        try await acknowledgeAll(
            began,
            scheduler: scheduler,
            generation: generation
        )
        await scheduler.cancel(generation: generation)
        #expect(store.snapshot().entries.isEmpty)
    }

    private func assertInjectedFailureCleanupAndReuse(
        _ scheduler: StrokeFrameScheduler,
        failedGeneration: UInt64,
        configuration: StrokePreparationConfiguration,
        retryConfiguration: StrokePreparationConfiguration? = nil
    ) async throws {
        let failed = await scheduler.snapshot
        #expect(failed.activeGeneration == nil)
        #expect(failed.cancelledGeneration == failedGeneration)
        #expect(failed.authoritativePending == 0)
        #expect(failed.predictedPending == 0)
        #expect(!failed.frameOutstanding)
        #expect(!failed.authoritativeCandidateContinuationPending)
        #expect(failed.retainedActualSampleCount == 0)
        #expect(failed.retainedPredictedSampleCount == 0)
        let transient = await scheduler.transientPreparationSnapshotForTesting
        #expect(transient.actualSamples.isEmpty)
        #expect(transient.predictedSamples.isEmpty)
        #expect(transient.actualDabs.isEmpty)
        #expect(transient.predictedDabs.isEmpty)
        let cleanup = await scheduler.stageCCleanupSnapshotForTesting
        #expect(cleanup.arenaOccupiedSlotCount == 0)
        #expect(!cleanup.arenaHasActiveTransaction)
        #expect(!cleanup.arenaHasActiveOperation)
        #expect(cleanup.projectedCarryCount == 0)
        #expect(!cleanup.coordinatorIsPresent)
        #expect(cleanup.coordinatorAuthoritativeQueueDepth == 0)
        #expect(cleanup.schedulerAuthoritativeQueueDepth == 0)
        #expect(cleanup.schedulerPredictionQueueDepth == 0)
        #expect(!cleanup.hasCandidateContinuation)
        #expect(!cleanup.hasOutstandingFrame)
        #expect(!cleanup.hasOutstandingSurfaceLease)
        #expect(!cleanup.hasOutstandingZeroWorkContinuation)
        #expect(!cleanup.hasBorrowedPreparedOutputPage)

        let retryGeneration = failedGeneration + 1
        let retry = await scheduler.process(
            .begin(
                generation: retryGeneration,
                configuration: retryConfiguration ?? configuration,
                samples: [
                    stageCPreparationSample(
                        phase: .began,
                        x: 32,
                        timestamp: 0
                    ),
                ]
            )
        )
        guard case let .prepared(first)? = retry else {
            Issue.record(
                "Fresh generation failed after injected failure \(failedGeneration)"
            )
            return
        }
        let batches = try await drainPreparedBatchRecords(
            first,
            scheduler: scheduler,
            generation: retryGeneration
        )
        #expect(batches.flatMap(\.logicalDabs).map(\.ordinal) == [0])
        #expect((await scheduler.snapshot).activeGeneration == retryGeneration)
        await scheduler.cancel(generation: retryGeneration)
    }

    private func driveUntilInjectedFailure(
        _ first: StrokePreparationResult?,
        scheduler: StrokeFrameScheduler,
        generation: UInt64
    ) async -> StrokePreparationResult? {
        var current = first
        for _ in 0..<10_000 {
            switch current {
            case .failed:
                return current
            case let .prepared(batch):
                guard let token = batch.frameToken else { return current }
                current = await scheduler.acknowledgePreparedFrame(
                    generation: generation,
                    frameToken: token
                )
            case nil:
                return nil
            default:
                return current
            }
        }
        Issue.record("Injected Stage C failure did not terminate within bound")
        return current
    }

    @Test
    @MainActor
    func bridgePublishesDisplayFrameAndCompletionConfirmedAffineACK()
        async throws
    {
        guard let setup = try await stageCSurfaceTestSetup() else { return }
        let generation: UInt64 = 0xD6_20
        let store = PaintTileStore(
            device: setup.device,
            byteBudget: PaintTileDescriptor.residentByteCount * 32
        )
        let surfaces = try stageCCurrentSurfaceResources(
            device: setup.device,
            store: store,
            layerID: UUID(),
            generation: generation,
            pixelSize: PixelSize(width: 512, height: 512),
            pipeline: setup.tilePipeline
        )
        let descriptor = StrokeMetalResourceDescriptor(
            surfaces: surfaces,
            brush: setup.brush,
            frameUniforms: stageCSurfaceFrameUniforms(side: 512),
            forceCommandFailure: false
        )
        let bridge = StrokePreparationBridge(
            budget: try frameBudget(
                authoritativePerFrame: 4_096,
                predictedPerFrame: 4_096,
                authoritativeCapacity: 12_288,
                predictedCapacity: 4_096
            ),
            targetFramesPerSecond: 120
        )
        try bridge.submit(.begin(
            generation: generation,
            configuration: try preparationConfiguration(
                program: stageCMetalTestProgram(
                    id: "test.scheduler.stage-d-display-frame"
                ),
                metalResourceDescriptor: descriptor
            ),
            samples: [stageCPreparationSample(
                phase: .began,
                x: 64,
                timestamp: 0
            )]
        ))

        let progress = StrokePreparationAsyncProgressRegistration(
            mailbox: bridge.mailbox
        )
        defer { progress.remove() }
        var scratch: [StrokePreparationResult] = []
        var prepared: StrokePreparedDepositionBatch?
        for _ in 0..<1_000 {
            let revision = progress.currentRevision
            bridge.drainResults(into: &scratch)
            if case let .prepared(batch)? = scratch.first {
                prepared = batch
                break
            }
            scratch.removeAll(keepingCapacity: true)
            if progress.currentRevision != revision { continue }
            _ = try await progress.waitForProgress(
                after: revision,
                timeoutNanoseconds: Self.asyncProgressTimeoutNanoseconds
            )
        }
        let batch = try #require(prepared)
        let frame = try #require(batch.displayFrame)
        #expect(frame.generation == generation)
        #expect(frame.layer == batch.surfaceLease?.layer)
        #expect(bridge.mailbox.snapshot.awaitingPreparedFrameSubmission)

        try await frame.acknowledgement.fulfill()
        await #expect(
            throws: StrokePreparationAcknowledgementError
                .acknowledgementAlreadyFulfilled
        ) {
            try await frame.acknowledgement.fulfill()
        }
        for _ in 0..<16 {
            scratch.removeAll(keepingCapacity: true)
            bridge.drainResults(into: &scratch)
            for result in scratch {
                if case let .prepared(next) = result,
                   let nextFrame = next.displayFrame
                {
                    try await nextFrame.acknowledgement.fulfill()
                }
            }
            if bridge.mailbox.snapshot.isQuiescent { break }
            await Task.yield()
        }
        #expect(bridge.mailbox.snapshot.isQuiescent)
        #expect(store.snapshot().activeLeaseCount == 0)
        try bridge.submit(.cancel(generation: generation, reason: nil))
    }

    @MainActor
    private func stageCSurfaceTestSetup() async throws -> (
        device: any MTLDevice,
        brush: CompiledBrushRenderState,
        tilePipeline: DepositionPipelineBinding
    )? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shader = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MetalRenderer/Shaders.metal"
            ),
            encoding: .utf8
        )
        let header = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CShaderTypes/include/ShaderTypes.h"
            ),
            encoding: .utf8
        )
        let library = try await device.makeLibrary(
            source: shader.replacingOccurrences(
                of: "#include \"ShaderTypes.h\"",
                with: header
            ),
            options: nil
        )
        let profile = try BrushDeviceProfile(
            registryID: device.registryID,
            recommendedWorkingSetBytes: 1_024 * 1_024 * 1_024,
            maximumWorkingTextureDimension: 4_096,
            brushCacheBudgetBytes: 64 * 1_024 * 1_024,
            targetFramesPerSecond: 120
        )
        let pipelines = DepositionPipelineLibrary(
            device: device,
            library: library
        )
        let compiler = BrushCompiler(
            device: device,
            commandQueue: commandQueue,
            profile: profile,
            pipelineLibrary: pipelines
        )
        let compiled = try await compiler.compileAndActivate(
            definition: StageFourAnchorDefinitions.ink
        )
        return (
            device,
            compiled.renderState,
            compiled.primaryComponent.depositionPipeline
        )
    }

    @MainActor
    private func stageCCurrentSurfaceResources(
        device: any MTLDevice,
        store: PaintTileStore,
        layerID: UUID,
        generation: UInt64,
        pixelSize: PixelSize,
        pipeline: DepositionPipelineBinding
    ) throws -> StrokeTileSurfaceResources {
        try StrokeTileSurfaceResources(
            device: device,
            commandQueue: device.makeCommandQueue()!,
            capability: try .testing(
                store: store,
                layerID: layerID,
                pixelSize: pixelSize,
                generation: generation
            ),
            maximumRecordCount: 4_096,
            maximumTileReferenceCount: 16_384
        )
    }

    private func stageCSurfaceFrameUniforms(
        side: Float
    ) -> PatternGridFrameUniforms {
        PatternGridFrameUniforms(
            drawableSize: SIMD2(repeating: side),
            worldCenter: SIMD2(repeating: side / 2),
            tileSize: SIMD2(repeating: side),
            zoom: 1,
            gridLineWidth: 0,
            showGridLines: 0,
            liveVisible: 1,
            tilingKind: 0,
            diagnosticMode: 0,
            compositeMode: 0,
            symmetryFamily: 0,
            repeatSize: SIMD2(repeating: side),
            latticeXAxis: SIMD2(1, 0),
            latticeYAxis: SIMD2(0, 1),
            latticeTranslation: .zero,
            guideKind: 0,
            showCanvasBoundary: 0
        )
    }
}

private final class OneShotStageCFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let seam: StrokeStageCFailureInjectionSeam
    private var isArmed: Bool
    private var hasInjected = false

    var didInject: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasInjected
    }

    var injection: StrokeStageCFailureInjection {
        StrokeStageCFailureInjection { [self] observed, _ in
            lock.lock()
            defer { lock.unlock() }
            guard isArmed, observed == seam, !hasInjected else { return }
            hasInjected = true
            throw StrokeStageCInjectedFailure(seam: observed)
        }
    }

    init(
        seam: StrokeStageCFailureInjectionSeam,
        initiallyArmed: Bool = true
    ) {
        self.seam = seam
        isArmed = initiallyArmed
    }

    func arm() {
        lock.lock()
        isArmed = true
        lock.unlock()
    }
}

private final class SteppedPreparationClock: @unchecked Sendable {
    private let lock = NSLock()
    private let step: UInt64
    private var value: UInt64 = 0

    init(step: UInt64) {
        self.step = step
    }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value &+= step
        return current
    }
}
