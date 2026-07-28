@testable import MetalRenderer
import Testing

@Suite("Deposition telemetry")
struct DepositionTelemetryTests {
    @Test
    func emptyTelemetryHasStableZeroSnapshots() {
        let telemetry = DepositionTelemetry(windowCapacity: 4)

        #expect(telemetry.snapshot == DepositionTelemetrySnapshot(
            authoritativeBacklog: 0,
            predictedBacklog: 0,
            backlogHighWater: 0,
            encodedInstanceCount: 0,
            bufferHighWater: 0,
            missedFrameCount: 0
        ))
        #expect(telemetry.timings == .zero)
    }

    @Test
    func backlogHighWaterIsMonotonicAcrossBothQueues() {
        var telemetry = DepositionTelemetry(windowCapacity: 4)

        telemetry.recordBacklog(authoritative: 3, predicted: 2)
        telemetry.recordBacklog(authoritative: 1, predicted: 1)
        telemetry.recordBacklog(authoritative: 4, predicted: 3)

        #expect(telemetry.snapshot.authoritativeBacklog == 4)
        #expect(telemetry.snapshot.predictedBacklog == 3)
        #expect(telemetry.snapshot.backlogHighWater == 7)
    }

    @Test
    func encodedMissedFrameAndBufferCountersSaturate() {
        var telemetry = DepositionTelemetry(windowCapacity: 4)

        telemetry.recordEncoding(instanceCount: UInt64.max, bufferCount: 2)
        telemetry.recordEncoding(instanceCount: 1, bufferCount: 1)
        telemetry.recordEncoding(instanceCount: 0, bufferCount: 5)
        telemetry.recordMissedFrames(UInt64.max)
        telemetry.recordMissedFrames(1)

        #expect(telemetry.snapshot.encodedInstanceCount == UInt64.max)
        #expect(telemetry.snapshot.bufferHighWater == 5)
        #expect(telemetry.snapshot.missedFrameCount == UInt64.max)
    }

    @Test
    func timingWindowsRetainOnlyNewestSamplesAndUseNearestRank() {
        var telemetry = DepositionTelemetry(windowCapacity: 4)

        for value in [10, 20, 30, 40, 50] as [UInt64] {
            telemetry.recordTimings(
                eventToSubmitNanoseconds: value,
                cpuPreparationNanoseconds: value + 100,
                gpuEncodingNanoseconds: value + 200,
                gpuCompletionNanoseconds: value + 300
            )
        }
        let timings = telemetry.timings

        #expect(timings.eventToSubmit == percentiles(30, 50, 50))
        #expect(timings.cpuPreparation == percentiles(130, 150, 150))
        #expect(timings.gpuEncoding == percentiles(230, 250, 250))
        #expect(timings.gpuCompletion == percentiles(330, 350, 350))
        #expect(telemetry.timings == timings)
    }

    @Test
    func resetClearsCountersAndWindowsWithoutChangingCapacity() {
        var telemetry = DepositionTelemetry(windowCapacity: 3)
        telemetry.recordBacklog(authoritative: 2, predicted: 1)
        telemetry.recordEncoding(instanceCount: 9, bufferCount: 2)
        telemetry.recordMissedFrames(3)
        telemetry.recordTimings(
            eventToSubmitNanoseconds: 10,
            cpuPreparationNanoseconds: 20,
            gpuEncodingNanoseconds: 30,
            gpuCompletionNanoseconds: 40
        )

        telemetry.reset()

        #expect(telemetry.snapshot == .zero)
        #expect(telemetry.timings == .zero)

        telemetry.recordTimings(
            eventToSubmitNanoseconds: 50,
            cpuPreparationNanoseconds: 60,
            gpuEncodingNanoseconds: 70,
            gpuCompletionNanoseconds: 80
        )
        #expect(
            telemetry.timings.eventToSubmit
                == percentiles(50, 50, 50)
        )
    }

    private func percentiles(
        _ p50: UInt64,
        _ p95: UInt64,
        _ p99: UInt64
    ) -> DepositionDurationPercentiles {
        DepositionDurationPercentiles(p50: p50, p95: p95, p99: p99)
    }
}
