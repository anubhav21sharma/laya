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
#endif
