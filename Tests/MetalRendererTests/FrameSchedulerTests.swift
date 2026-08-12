import CShaderTypes
@testable import MetalRenderer
import Testing

@Suite("Deposition frame scheduler")
struct FrameSchedulerTests {
    @Test
    func diagnosticsReportActualPendingCountsAndHighWater() throws {
        let budget = try frameBudget(
            authoritativePerFrame: 2,
            predictedPerFrame: 1,
            authoritativeCapacity: 8,
            predictedCapacity: 4
        )
        let scheduler = FrameScheduler(budget: budget)

        try scheduler.enqueueAuthoritative(records(0..<5))
        try scheduler.replacePrediction(records(100..<103))
        var diagnostics = scheduler.diagnosticSnapshot
        #expect(diagnostics.authoritativePending == 5)
        #expect(diagnostics.predictedPending == 3)
        #expect(diagnostics.authoritativeHighWater == 5)
        #expect(diagnostics.predictedHighWater == 3)
        #expect(diagnostics.authoritativeStorageCapacity >= 8)
        #expect(diagnostics.predictedStorageCapacity >= 4)

        _ = scheduler.nextFrame(budget: budget)
        diagnostics = scheduler.diagnosticSnapshot
        #expect(diagnostics.authoritativePending == 3)
        #expect(diagnostics.predictedPending == 2)
        #expect(diagnostics.authoritativeHighWater == 5)
        #expect(diagnostics.predictedHighWater == 3)
        #expect(diagnostics.authoritativeStorageCapacity >= 8)
        #expect(diagnostics.predictedStorageCapacity >= 4)

        try scheduler.enqueueAuthoritative(records(10..<15))
        #expect(
            scheduler.diagnosticSnapshot.authoritativeHighWater == 8
        )
    }

    @Test
    func frameTakesAuthoritativeBeforePredictionWithoutDroppingCarry()
        throws
    {
        let budget = try frameBudget(
            authoritativePerFrame: 2,
            predictedPerFrame: 2,
            authoritativeCapacity: 4,
            predictedCapacity: 4
        )
        let scheduler = FrameScheduler(budget: budget)
        try scheduler.enqueueAuthoritative(records(0..<3))
        try scheduler.replacePrediction(records(100..<102))

        let first = scheduler.nextFrame(budget: budget)
        let second = scheduler.nextFrame(budget: budget)

        #expect(first.authoritative.map(\.identity) == [0, 1])
        #expect(first.predicted.map(\.identity) == [100, 101])
        #expect(first.authoritativeRemaining == 1)
        #expect(first.predictedRemaining == 0)
        #expect(second.authoritative.map(\.identity) == [2])
        #expect(second.predicted.isEmpty)
    }

    @Test
    func failedPredictionReplacementPreservesBothQueues() throws {
        let budget = try frameBudget(
            authoritativePerFrame: 4,
            predictedPerFrame: 2,
            authoritativeCapacity: 4,
            predictedCapacity: 2
        )
        let scheduler = FrameScheduler(budget: budget)
        try scheduler.enqueueAuthoritative(records(10..<12))
        try scheduler.replacePrediction(records(100..<102))

        #expect(
            throws: FrameSchedulerError.predictedCapacityExceeded(
                actual: 3,
                maximum: 2
            )
        ) {
            try scheduler.replacePrediction(records(200..<203))
        }
        let frame = scheduler.nextFrame(budget: budget)

        #expect(frame.authoritative.map(\.identity) == [10, 11])
        #expect(frame.predicted.map(\.identity) == [100, 101])
    }

    @Test
    func successfulPredictionReplacementDoesNotAffectAuthoritativeCarry()
        throws
    {
        let budget = try frameBudget(
            authoritativePerFrame: 2,
            predictedPerFrame: 2,
            authoritativeCapacity: 4,
            predictedCapacity: 3
        )
        let scheduler = FrameScheduler(budget: budget)
        try scheduler.enqueueAuthoritative(records(0..<4))
        try scheduler.replacePrediction(records(100..<102))
        try scheduler.replacePrediction(records(200..<203))

        let first = scheduler.nextFrame(budget: budget)
        let second = scheduler.nextFrame(budget: budget)

        #expect(first.authoritative.map(\.identity) == [0, 1])
        #expect(first.predicted.map(\.identity) == [200, 201])
        #expect(second.authoritative.map(\.identity) == [2, 3])
        #expect(second.predicted.map(\.identity) == [202])
    }

    @Test
    func authoritativeCapacityBoundarySucceedsAndOverflowIsAtomic() throws {
        let budget = try frameBudget(
            authoritativePerFrame: 2,
            predictedPerFrame: 1,
            authoritativeCapacity: 4,
            predictedCapacity: 1
        )
        let scheduler = FrameScheduler(budget: budget)
        try scheduler.enqueueAuthoritative(records(0..<4))

        #expect(
            throws: FrameSchedulerError.authoritativeCapacityExceeded(
                current: 4,
                incoming: 1,
                maximum: 4
            )
        ) {
            try scheduler.enqueueAuthoritative(records(99..<100))
        }

        let first = scheduler.nextFrame(budget: budget)
        let second = scheduler.nextFrame(budget: budget)
        #expect(
            (first.authoritative + second.authoritative).map(\.identity)
                == [0, 1, 2, 3]
        )
    }

    @Test
    func pointerUpDrainStateIgnoresReplaceablePrediction() throws {
        let budget = try frameBudget(
            authoritativePerFrame: 2,
            predictedPerFrame: 2,
            authoritativeCapacity: 2,
            predictedCapacity: 2
        )
        let scheduler = FrameScheduler(budget: budget)
        try scheduler.replacePrediction(records(100..<102))

        #expect(scheduler.authoritativeIsDrained)
        try scheduler.enqueueAuthoritative(records(0..<1))
        #expect(!scheduler.authoritativeIsDrained)
        _ = scheduler.nextFrame(budget: budget)
        #expect(scheduler.authoritativeIsDrained)
    }

    @Test
    func discardPredictionAndResetPreserveReusableBoundedState() throws {
        let budget = try frameBudget(
            authoritativePerFrame: 2,
            predictedPerFrame: 2,
            authoritativeCapacity: 3,
            predictedCapacity: 3
        )
        let scheduler = FrameScheduler(budget: budget)
        try scheduler.enqueueAuthoritative(records(0..<3))
        try scheduler.replacePrediction(records(100..<103))

        scheduler.discardPrediction()
        let authoritativeOnly = scheduler.nextFrame(budget: budget)
        #expect(authoritativeOnly.authoritative.map(\.identity) == [0, 1])
        #expect(authoritativeOnly.predicted.isEmpty)

        scheduler.reset()
        let empty = scheduler.nextFrame(budget: budget)
        #expect(empty == ScheduledDepositionFrame(
            authoritative: [],
            predicted: [],
            authoritativeRemaining: 0,
            predictedRemaining: 0
        ))

        try scheduler.enqueueAuthoritative(records(50..<53))
        #expect(
            scheduler.nextFrame(budget: budget).authoritative.map(\.identity)
                == [50, 51]
        )
    }

    @Test
    func legalFramePartitionsProduceTheSameAuthoritativeSequence() throws {
        let source = records(0..<23)
        let narrow = try drain(
            source,
            budget: frameBudget(
                authoritativePerFrame: 3,
                predictedPerFrame: 1,
                authoritativeCapacity: 23,
                predictedCapacity: 1
            )
        )
        let wide = try drain(
            source,
            budget: frameBudget(
                authoritativePerFrame: 8,
                predictedPerFrame: 1,
                authoritativeCapacity: 23,
                predictedCapacity: 1
            )
        )

        #expect(narrow == Array(0..<23).map(UInt64.init))
        #expect(wide == narrow)
    }

    @Test
    func millionRecordSequenceRemainsExactWhenFedInLegalChunks() throws {
        let total = 1_000_000
        let chunkSize = 257
        let budget = try frameBudget(
            authoritativePerFrame: 193,
            predictedPerFrame: 1,
            authoritativeCapacity: 514,
            predictedCapacity: 1
        )
        let scheduler = FrameScheduler(budget: budget)
        var produced = 0
        var expectedIdentity: UInt64 = 0

        while produced < total {
            let end = min(total, produced + chunkSize)
            try scheduler.enqueueAuthoritative(
                records(produced..<end)
            )
            produced = end

            while scheduler.authoritativeCount > chunkSize {
                verifyExact(
                    scheduler.nextFrame(budget: budget).authoritative,
                    expectedIdentity: &expectedIdentity
                )
            }
        }
        while !scheduler.authoritativeIsDrained {
            verifyExact(
                scheduler.nextFrame(budget: budget).authoritative,
                expectedIdentity: &expectedIdentity
            )
        }

        #expect(expectedIdentity == UInt64(total))
        #expect(scheduler.authoritativeCount == 0)
    }

    private func drain(
        _ source: [ProjectedDepositionRecord],
        budget: DepositionFrameBudget
    ) throws -> [UInt64] {
        let scheduler = FrameScheduler(budget: budget)
        try scheduler.enqueueAuthoritative(source)
        var result: [UInt64] = []
        while !scheduler.authoritativeIsDrained {
            result.append(
                contentsOf: scheduler.nextFrame(budget: budget)
                    .authoritative.map(\.identity)
            )
        }
        return result
    }

    private func verifyExact(
        _ records: [ProjectedDepositionRecord],
        expectedIdentity: inout UInt64
    ) {
        for record in records {
            guard record.identity == expectedIdentity else {
                Issue.record(
                    "Expected identity \(expectedIdentity), got \(record.identity)"
                )
                return
            }
            expectedIdentity += 1
        }
    }

    private func records(
        _ range: Range<Int>
    ) -> [ProjectedDepositionRecord] {
        range.map { index in
            ProjectedDepositionRecord(
                identity: UInt64(index),
                instance: instance(identity: UInt64(index)),
                radialPage: nil
            )
        }
    }

    private func instance(
        identity: UInt64
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
                0
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
            cpuPreparationNanoseconds: 1_000_000,
            maximumAuthoritativeInstances: authoritativePerFrame,
            maximumPredictedInstances: predictedPerFrame,
            maximumPendingAuthoritativeInstances: authoritativeCapacity,
            maximumPendingPredictedInstances: predictedCapacity,
            inFlightUploadBufferCount: 3
        )
    }
}
