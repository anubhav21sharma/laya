import Foundation
@testable import MetalRenderer
import Testing

@Test
func strokeRuntimeTelemetryAggregatesAttributableProductionFrames() throws {
    let clock = SyntheticRuntimeTimestampSource([
        100, 110, 900,
    ])
    var telemetry = StrokeRuntimeTelemetry(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        traceProfile: .productionTenSeconds,
        timestampSource: clock
    )
    let segmentID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000002"
    )!
    let strokeID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000003"
    )!

    let began = try telemetry.beginSegment(
        id: segmentID,
        strokeID: strokeID
    )
    telemetry.recordInput(.actual, count: 2)
    telemetry.recordInput(.coalesced, count: 3)
    telemetry.recordInput(.predicted, count: 4)
    telemetry.recordInput(.estimatedUpdate, count: 1)
    try telemetry.recordFrame(
        StrokeRuntimeFrameSample(
            strokeID: strokeID,
            timestamps: StrokeRuntimeFrameTimestamps(
                input: 1_000,
                prepareStarted: 1_100,
                prepareFinished: 1_300,
                submitted: 1_500,
                gpuStarted: 1_600,
                gpuFinished: 1_900,
                presented: 2_000
            ),
            targetFrameDurationNanoseconds: 1_000,
            newLogicalDabCount: 5,
            newProjectedDabCount: 9,
            authoritativeReplayCount: 0,
            predictedReplayCount: 2,
            authoritativeQueueDepth: 3,
            predictedQueueDepth: 2,
            cacheHitCount: 7,
            cacheMissCount: 1,
            residentMemoryBytes: 4_096
        )
    )
    try telemetry.recordFrame(
        StrokeRuntimeFrameSample(
            strokeID: strokeID,
            timestamps: StrokeRuntimeFrameTimestamps(
                input: 2_100,
                prepareStarted: 2_200,
                prepareFinished: 2_600,
                submitted: 3_000,
                gpuStarted: 3_100,
                gpuFinished: 3_700,
                presented: 3_500
            ),
            targetFrameDurationNanoseconds: 1_000,
            newLogicalDabCount: 7,
            newProjectedDabCount: 13,
            authoritativeReplayCount: 0,
            predictedReplayCount: 3,
            authoritativeQueueDepth: 1,
            predictedQueueDepth: 0,
            cacheHitCount: 11,
            cacheMissCount: 2,
            residentMemoryBytes: 8_192
        )
    )
    let ended = try telemetry.endSegment()

    #expect(began.kind == .segmentBegan)
    #expect(began.timestampNanoseconds == 100)
    #expect(ended.kind == .segmentEnded)
    #expect(ended.timestampNanoseconds == 110)
    #expect(began.sessionID == telemetry.snapshot.sessionID)
    #expect(began.segmentID == segmentID)
    #expect(began.strokeID == strokeID)

    let snapshot = telemetry.snapshot
    #expect(snapshot.traceProfile == .productionTenSeconds)
    #expect(snapshot.inputProvenance.actual == 2)
    #expect(snapshot.inputProvenance.coalesced == 3)
    #expect(snapshot.inputProvenance.predicted == 4)
    #expect(snapshot.inputProvenance.estimatedUpdate == 1)
    #expect(snapshot.newLogicalDabCount == 12)
    #expect(snapshot.newProjectedDabCount == 22)
    #expect(snapshot.authoritativeReplayCount == 0)
    #expect(snapshot.predictedReplayCount == 5)
    #expect(snapshot.authoritativeQueueDepth == 1)
    #expect(snapshot.predictedQueueDepth == 0)
    #expect(snapshot.authoritativeQueueHighWater == 3)
    #expect(snapshot.predictedQueueHighWater == 2)
    #expect(snapshot.prepare.p95 == 400)
    #expect(snapshot.eventToSubmit.p95 == 900)
    #expect(snapshot.gpu.p95 == 600)
    #expect(snapshot.frame.p95 == 1_500)
    #expect(snapshot.missedFrameFraction == 0.5)
    #expect(snapshot.eventToSubmitMissFraction == 0)
    #expect(snapshot.cacheHitCount == 18)
    #expect(snapshot.cacheMissCount == 3)
    #expect(snapshot.memoryHighWaterBytes == 8_192)
    #expect(snapshot.frameCount == 2)
    #expect(snapshot.observedDurationNanoseconds == 2_500)
    #expect(snapshot.authoritativeQueueDepths == [3, 1])
}

@Test
func strokeRuntimeSoftwareGateRejectsEachSilentFailureMode() throws {
    let passing = runtimeGateSnapshot(
        profile: .productionTenSeconds,
        actualReplay: 0,
        queues: [2, 1, 0],
        missed: 1,
        frames: 100
    )
    try BenchmarkStrokeRuntimeGate.validate(
        passing,
        replayMode: .appendOnly
    )

    #expect(throws: BenchmarkStrokeRuntimeGateError.appendOnlyReplay(1)) {
        try BenchmarkStrokeRuntimeGate.validate(
            runtimeGateSnapshot(
                profile: .productionTenSeconds,
                actualReplay: 1,
                queues: [2, 1, 0],
                missed: 0,
                frames: 100
            ),
            replayMode: .appendOnly
        )
    }
    #expect(
        throws: BenchmarkStrokeRuntimeGateError.monotonicBacklog([1, 2, 2])
    ) {
        try BenchmarkStrokeRuntimeGate.validate(
            runtimeGateSnapshot(
                profile: .productionTenSeconds,
                actualReplay: 0,
                queues: [1, 2, 2],
                missed: 0,
                frames: 100
            ),
            replayMode: .appendOnly
        )
    }
    #expect(
        throws: BenchmarkStrokeRuntimeGateError
            .eventToSubmitMissFraction(actual: 0.02, maximum: 0.01)
    ) {
        try BenchmarkStrokeRuntimeGate.validate(
            runtimeGateSnapshot(
                profile: .productionTenSeconds,
                actualReplay: 0,
                queues: [2, 1, 0],
                missed: 2,
                frames: 100
            ),
            replayMode: .appendOnly
        )
    }
    #expect(
        throws: BenchmarkStrokeRuntimeGateError.nonProductionTrace
    ) {
        try BenchmarkStrokeRuntimeGate.validate(
            runtimeGateSnapshot(
                profile: .syntheticTest,
                actualReplay: 0,
                queues: [2, 1, 0],
                missed: 0,
                frames: 100
            ),
            replayMode: .appendOnly
        )
    }
    #expect(
        throws: BenchmarkStrokeRuntimeGateError.insufficientDuration(
            actual: 9_999_999_999,
            required: 10_000_000_000
        )
    ) {
        try BenchmarkStrokeRuntimeGate.validate(
            runtimeGateSnapshot(
                profile: .productionTenSeconds,
                actualReplay: 0,
                queues: [2, 1, 0],
                missed: 0,
                frames: 100,
                observedDuration: 9_999_999_999
            ),
            replayMode: .appendOnly
        )
    }
}

@Test
func productionTraceProfilesPinTenSecondAndAcceleratedTenMinuteDurations() {
    #expect(
        StrokeRuntimeTraceProfile.productionTenSeconds
            .logicalDurationNanoseconds == 10_000_000_000
    )
    #expect(
        StrokeRuntimeTraceProfile.productionAcceleratedTenMinutes
            .logicalDurationNanoseconds == 600_000_000_000
    )
    #expect(
        StrokeRuntimeTraceProfile.productionAcceleratedTenMinutes
            .isAccelerated
    )
    #expect(StrokeRuntimeTraceProfile.productionTenSeconds.isProduction)
    #expect(!StrokeRuntimeTraceProfile.syntheticTest.isProduction)
}

private final class SyntheticRuntimeTimestampSource:
    StrokeRuntimeTimestampSource, @unchecked Sendable
{
    private let lock = NSLock()
    private var timestamps: [UInt64]

    init(_ timestamps: [UInt64]) {
        self.timestamps = timestamps
    }

    func nowNanoseconds() -> UInt64 {
        lock.withLock {
            timestamps.removeFirst()
        }
    }
}

private func runtimeGateSnapshot(
    profile: StrokeRuntimeTraceProfile,
    actualReplay: UInt64,
    queues: [Int],
    missed: UInt64,
    frames: UInt64,
    observedDuration: UInt64? = nil
) -> StrokeRuntimeTelemetrySnapshot {
    StrokeRuntimeTelemetrySnapshot(
        sessionID: UUID(),
        segmentID: UUID(),
        strokeID: UUID(),
        traceProfile: profile,
        inputProvenance: .zero,
        newLogicalDabCount: 1,
        newProjectedDabCount: 1,
        authoritativeReplayCount: actualReplay,
        predictedReplayCount: 0,
        authoritativeQueueDepth: queues.last ?? 0,
        predictedQueueDepth: 0,
        authoritativeQueueHighWater: queues.max() ?? 0,
        predictedQueueHighWater: 0,
        prepare: .zero,
        eventToSubmit: .zero,
        gpu: .zero,
        frame: .zero,
        missedFrameCount: missed,
        eventToSubmitMissCount: missed,
        frameCount: frames,
        observedDurationNanoseconds:
            observedDuration ?? profile.logicalDurationNanoseconds,
        cacheHitCount: 0,
        cacheMissCount: 0,
        memoryHighWaterBytes: 0,
        authoritativeQueueDepths: queues,
        lastTimestamps: nil
    )
}
