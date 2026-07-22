#if DEBUG
import Foundation
import Observation

struct DebugPerformanceSnapshot: Equatable, Sendable {
    var framesPerSecond = 0.0
    var p95FrameMilliseconds = 0.0
    var missedFramePercentage = 0.0
    var targetFramesPerSecond = 0
    var sampleCount = 0
}

@MainActor
@Observable
final class DebugPerformanceMonitor {
    private static let maximumSampleCount = 240
    private static let publicationInterval = 0.25
    private static let suspensionInterval = 0.5

    private(set) var snapshot = DebugPerformanceSnapshot()
    private var intervalsMilliseconds: [Double] = []
    private var lastFrameTimestamp: TimeInterval?
    private var lastPublicationTimestamp: TimeInterval?
    private var currentTargetFramesPerSecond = 0

    func recordPresentedFrame(
        at timestamp: TimeInterval,
        targetFramesPerSecond: Int
    ) {
        guard timestamp.isFinite, targetFramesPerSecond > 0 else { return }

        if currentTargetFramesPerSecond != targetFramesPerSecond {
            resetSamples(targetFramesPerSecond: targetFramesPerSecond)
        }

        defer { lastFrameTimestamp = timestamp }
        guard let lastFrameTimestamp else {
            lastPublicationTimestamp = timestamp
            return
        }

        let interval = timestamp - lastFrameTimestamp
        guard interval > 0 else { return }
        guard interval < Self.suspensionInterval else {
            resetSamples(targetFramesPerSecond: targetFramesPerSecond)
            lastPublicationTimestamp = timestamp
            return
        }

        intervalsMilliseconds.append(interval * 1_000)
        if intervalsMilliseconds.count > Self.maximumSampleCount {
            intervalsMilliseconds.removeFirst(
                intervalsMilliseconds.count - Self.maximumSampleCount
            )
        }

        if timestamp - (lastPublicationTimestamp ?? 0)
            >= Self.publicationInterval
        {
            publishSnapshot()
            lastPublicationTimestamp = timestamp
        }
    }

    func reset() {
        snapshot = DebugPerformanceSnapshot()
        intervalsMilliseconds.removeAll(keepingCapacity: true)
        lastFrameTimestamp = nil
        lastPublicationTimestamp = nil
        currentTargetFramesPerSecond = 0
    }

    private func resetSamples(targetFramesPerSecond: Int) {
        intervalsMilliseconds.removeAll(keepingCapacity: true)
        lastFrameTimestamp = nil
        lastPublicationTimestamp = nil
        currentTargetFramesPerSecond = targetFramesPerSecond
        snapshot = DebugPerformanceSnapshot(
            targetFramesPerSecond: targetFramesPerSecond
        )
    }

    private func publishSnapshot() {
        guard !intervalsMilliseconds.isEmpty,
              currentTargetFramesPerSecond > 0
        else { return }

        let mean = intervalsMilliseconds.reduce(0, +)
            / Double(intervalsMilliseconds.count)
        let sorted = intervalsMilliseconds.sorted()
        let p95Index = max(
            0,
            min(
                sorted.count - 1,
                Int(ceil(Double(sorted.count) * 0.95)) - 1
            )
        )
        let frameBudget = 1_000 / Double(currentTargetFramesPerSecond)
        let expectedFrameCounts = intervalsMilliseconds.map {
            max(1, Int(($0 / frameBudget).rounded()))
        }
        let expectedFrames = expectedFrameCounts.reduce(0, +)
        let missedFrames = expectedFrameCounts.reduce(0) {
            $0 + max(0, $1 - 1)
        }

        snapshot = DebugPerformanceSnapshot(
            framesPerSecond: 1_000 / mean,
            p95FrameMilliseconds: sorted[p95Index],
            missedFramePercentage: expectedFrames == 0
                ? 0
                : Double(missedFrames) / Double(expectedFrames) * 100,
            targetFramesPerSecond: currentTargetFramesPerSecond,
            sampleCount: intervalsMilliseconds.count
        )
    }
}
#endif
