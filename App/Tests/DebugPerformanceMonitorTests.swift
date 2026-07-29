#if DEBUG
import Testing

@MainActor
@Test
func debugPerformanceMonitorReportsSteadyFrameCadence() {
    let monitor = DebugPerformanceMonitor()

    for frame in 0...20 {
        monitor.recordPresentedFrame(
            at: Double(frame) / 60,
            targetFramesPerSecond: 60
        )
    }

    #expect(abs(monitor.snapshot.framesPerSecond - 60) < 0.001)
    #expect(abs(monitor.snapshot.p95FrameMilliseconds - 16.667) < 0.001)
    #expect(monitor.snapshot.missedFramePercentage == 0)
    #expect(monitor.snapshot.targetFramesPerSecond == 60)
}

@MainActor
@Test
func debugPerformanceMonitorCountsMissedDisplayFrames() {
    let monitor = DebugPerformanceMonitor()
    var timestamp = 0.0
    monitor.recordPresentedFrame(at: timestamp, targetFramesPerSecond: 60)

    for frame in 1...20 {
        timestamp += [8, 16].contains(frame) ? 2.0 / 60 : 1.0 / 60
        monitor.recordPresentedFrame(
            at: timestamp,
            targetFramesPerSecond: 60
        )
    }

    #expect(monitor.snapshot.missedFramePercentage > 0)
    #expect(monitor.snapshot.p95FrameMilliseconds > 16.667)
}

@MainActor
@Test
func debugPerformanceMonitorResetsAcrossDisplayChanges() {
    let monitor = DebugPerformanceMonitor()

    for frame in 0...20 {
        monitor.recordPresentedFrame(
            at: Double(frame) / 60,
            targetFramesPerSecond: 60
        )
    }
    monitor.recordPresentedFrame(at: 1, targetFramesPerSecond: 120)

    #expect(monitor.snapshot.sampleCount == 0)
    #expect(monitor.snapshot.targetFramesPerSecond == 120)
}

@MainActor
@Test
func debugPerformanceMonitorPublishesActualDepositionDiagnostics() {
    let monitor = DebugPerformanceMonitor()

    monitor.recordDepositionSample(
        authoritativeBacklog: 9,
        predictedBacklog: 3,
        authoritativeHighWater: 19,
        predictedHighWater: 13,
        backlogHighWater: 32,
        encodedDabs: 7,
        encodedInstances: 11,
        currentBufferLeaseCount: 2,
        strokeBufferLeaseHighWater: 2,
        lifetimeBufferLeaseHighWater: 3,
        cpuPreparationNanoseconds: 1_000_000,
        eventToSubmitNanoseconds: 2_000_000,
        gpuCompletionNanoseconds: 3_000_000,
        missedFrames: 1
    )
    monitor.recordDepositionSample(
        authoritativeBacklog: 4,
        predictedBacklog: 0,
        authoritativeHighWater: 17,
        predictedHighWater: 5,
        backlogHighWater: 22,
        encodedDabs: 5,
        encodedInstances: 13,
        currentBufferLeaseCount: 0,
        strokeBufferLeaseHighWater: 1,
        lifetimeBufferLeaseHighWater: 3,
        cpuPreparationNanoseconds: 2_000_000,
        eventToSubmitNanoseconds: 4_000_000,
        gpuCompletionNanoseconds: 6_000_000,
        missedFrames: 2
    )

    let diagnostics = monitor.snapshot.deposition
    #expect(diagnostics.authoritativeBacklog == 4)
    #expect(diagnostics.predictedBacklog == 0)
    #expect(diagnostics.authoritativeHighWater == 17)
    #expect(diagnostics.predictedHighWater == 5)
    #expect(diagnostics.backlogHighWater == 22)
    #expect(diagnostics.encodedDabCount == 12)
    #expect(diagnostics.encodedInstanceCount == 24)
    #expect(diagnostics.currentBufferLeaseCount == 0)
    #expect(diagnostics.strokeBufferLeaseHighWater == 1)
    #expect(diagnostics.lifetimeBufferLeaseHighWater == 3)
    #expect(diagnostics.missedFrameCount == 3)
    #expect(diagnostics.cpuPreparation.p50 == 1_000_000)
    #expect(diagnostics.cpuPreparation.p95 == 2_000_000)
    #expect(diagnostics.eventToSubmit.p95 == 4_000_000)
    #expect(diagnostics.gpuCompletion.p99 == 6_000_000)
}
#endif
