#if DEBUG
import Foundation
import Observation

struct DebugPerformanceSnapshot: Equatable, Sendable {
    var framesPerSecond = 0.0
    var p95FrameMilliseconds = 0.0
    var missedFramePercentage = 0.0
    var targetFramesPerSecond = 0
    var sampleCount = 0
    var missedFrameCount: UInt64 = 0
    var deposition = DebugDepositionSnapshot()
}

struct DebugDurationPercentiles: Codable, Equatable, Sendable {
    var p50: UInt64 = 0
    var p95: UInt64 = 0
    var p99: UInt64 = 0
}

struct DebugDepositionSnapshot: Equatable, Sendable {
    var authoritativeBacklog = 0
    var predictedBacklog = 0
    var backlogHighWater = 0
    var encodedDabCount: UInt64 = 0
    var encodedInstanceCount: UInt64 = 0
    var bufferHighWater = 0
    var missedFrameCount: UInt64 = 0
    var cpuPreparation = DebugDurationPercentiles()
    var eventToSubmit = DebugDurationPercentiles()
    var gpuCompletion = DebugDurationPercentiles()
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
    private var cpuPreparationNanoseconds: [UInt64] = []
    private var eventToSubmitNanoseconds: [UInt64] = []
    private var gpuCompletionNanoseconds: [UInt64] = []

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
        cpuPreparationNanoseconds.removeAll(keepingCapacity: true)
        eventToSubmitNanoseconds.removeAll(keepingCapacity: true)
        gpuCompletionNanoseconds.removeAll(keepingCapacity: true)
    }

    func recordDepositionSample(
        authoritativeBacklog: Int,
        predictedBacklog: Int,
        encodedDabs: UInt64,
        encodedInstances: UInt64,
        bufferCount: Int,
        cpuPreparationNanoseconds: UInt64,
        eventToSubmitNanoseconds: UInt64,
        gpuCompletionNanoseconds: UInt64,
        missedFrames: UInt64
    ) {
        guard authoritativeBacklog >= 0,
              predictedBacklog >= 0,
              bufferCount >= 0
        else {
            return
        }
        appendBounded(
            cpuPreparationNanoseconds,
            to: &self.cpuPreparationNanoseconds
        )
        appendBounded(
            eventToSubmitNanoseconds,
            to: &self.eventToSubmitNanoseconds
        )
        appendBounded(
            gpuCompletionNanoseconds,
            to: &self.gpuCompletionNanoseconds
        )
        var deposition = snapshot.deposition
        deposition.authoritativeBacklog = authoritativeBacklog
        deposition.predictedBacklog = predictedBacklog
        let (backlog, overflow) = authoritativeBacklog
            .addingReportingOverflow(predictedBacklog)
        deposition.backlogHighWater = max(
            deposition.backlogHighWater,
            overflow ? .max : backlog
        )
        deposition.encodedDabCount = saturatingAdd(
            deposition.encodedDabCount,
            encodedDabs
        )
        deposition.encodedInstanceCount = saturatingAdd(
            deposition.encodedInstanceCount,
            encodedInstances
        )
        deposition.bufferHighWater = max(
            deposition.bufferHighWater,
            bufferCount
        )
        deposition.missedFrameCount = saturatingAdd(
            deposition.missedFrameCount,
            missedFrames
        )
        deposition.cpuPreparation = percentiles(
            self.cpuPreparationNanoseconds
        )
        deposition.eventToSubmit = percentiles(
            self.eventToSubmitNanoseconds
        )
        deposition.gpuCompletion = percentiles(
            self.gpuCompletionNanoseconds
        )
        snapshot.deposition = deposition
    }

    private func resetSamples(targetFramesPerSecond: Int) {
        intervalsMilliseconds.removeAll(keepingCapacity: true)
        lastFrameTimestamp = nil
        lastPublicationTimestamp = nil
        currentTargetFramesPerSecond = targetFramesPerSecond
        snapshot = DebugPerformanceSnapshot(
            targetFramesPerSecond: targetFramesPerSecond,
            deposition: snapshot.deposition
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
            sampleCount: intervalsMilliseconds.count,
            missedFrameCount: UInt64(missedFrames),
            deposition: snapshot.deposition
        )
    }

    private func appendBounded(
        _ value: UInt64,
        to samples: inout [UInt64]
    ) {
        if samples.count == Self.maximumSampleCount {
            samples.removeFirst()
        }
        samples.append(value)
    }

    private func percentiles(
        _ samples: [UInt64]
    ) -> DebugDurationPercentiles {
        guard !samples.isEmpty else { return DebugDurationPercentiles() }
        let sorted = samples.sorted()
        func nearestRank(_ percentile: Double) -> UInt64 {
            let rank = Int(ceil(Double(sorted.count) * percentile))
            return sorted[max(0, min(rank - 1, sorted.count - 1))]
        }
        return DebugDurationPercentiles(
            p50: nearestRank(0.50),
            p95: nearestRank(0.95),
            p99: nearestRank(0.99)
        )
    }

    private func saturatingAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
#endif
