import Foundation

public struct DepositionTelemetrySnapshot: Equatable, Sendable {
    public let authoritativeBacklog: Int
    public let predictedBacklog: Int
    public let backlogHighWater: Int
    public let encodedInstanceCount: UInt64
    public let bufferHighWater: Int
    public let missedFrameCount: UInt64
    public let submittedFrameCount: UInt64

    public var missedFrameFraction: Double {
        guard submittedFrameCount > 0 else { return 0 }
        return Double(missedFrameCount) / Double(submittedFrameCount)
    }

    public static let zero = DepositionTelemetrySnapshot(
        authoritativeBacklog: 0,
        predictedBacklog: 0,
        backlogHighWater: 0,
        encodedInstanceCount: 0,
        bufferHighWater: 0,
        missedFrameCount: 0,
        submittedFrameCount: 0
    )

    public init(
        authoritativeBacklog: Int,
        predictedBacklog: Int,
        backlogHighWater: Int,
        encodedInstanceCount: UInt64,
        bufferHighWater: Int,
        missedFrameCount: UInt64,
        submittedFrameCount: UInt64 = 0
    ) {
        self.authoritativeBacklog = authoritativeBacklog
        self.predictedBacklog = predictedBacklog
        self.backlogHighWater = backlogHighWater
        self.encodedInstanceCount = encodedInstanceCount
        self.bufferHighWater = bufferHighWater
        self.missedFrameCount = missedFrameCount
        self.submittedFrameCount = submittedFrameCount
    }
}

public struct DepositionDurationPercentiles:
    Codable, Equatable, Sendable
{
    public let p50: UInt64
    public let p95: UInt64
    public let p99: UInt64

    public static let zero = DepositionDurationPercentiles(
        p50: 0,
        p95: 0,
        p99: 0
    )

    public init(p50: UInt64, p95: UInt64, p99: UInt64) {
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
    }
}

public struct DepositionTelemetryTimingSnapshot: Equatable, Sendable {
    public let eventToSubmit: DepositionDurationPercentiles
    public let cpuPreparation: DepositionDurationPercentiles
    public let gpuEncoding: DepositionDurationPercentiles
    public let gpuCompletion: DepositionDurationPercentiles

    public static let zero = DepositionTelemetryTimingSnapshot(
        eventToSubmit: .zero,
        cpuPreparation: .zero,
        gpuEncoding: .zero,
        gpuCompletion: .zero
    )

    public init(
        eventToSubmit: DepositionDurationPercentiles,
        cpuPreparation: DepositionDurationPercentiles,
        gpuEncoding: DepositionDurationPercentiles,
        gpuCompletion: DepositionDurationPercentiles
    ) {
        self.eventToSubmit = eventToSubmit
        self.cpuPreparation = cpuPreparation
        self.gpuEncoding = gpuEncoding
        self.gpuCompletion = gpuCompletion
    }
}

struct DepositionTelemetry: Sendable {
    var snapshot: DepositionTelemetrySnapshot {
        DepositionTelemetrySnapshot(
            authoritativeBacklog: authoritativeBacklog,
            predictedBacklog: predictedBacklog,
            backlogHighWater: backlogHighWater,
            encodedInstanceCount: encodedInstanceCount,
            bufferHighWater: bufferHighWater,
            missedFrameCount: missedFrameCount,
            submittedFrameCount: submittedFrameCount
        )
    }

    var timings: DepositionTelemetryTimingSnapshot {
        DepositionTelemetryTimingSnapshot(
            eventToSubmit: eventToSubmitWindow.percentiles(),
            cpuPreparation: cpuPreparationWindow.percentiles(),
            gpuEncoding: gpuEncodingWindow.percentiles(),
            gpuCompletion: gpuCompletionWindow.percentiles()
        )
    }

    private var authoritativeBacklog = 0
    private var predictedBacklog = 0
    private var backlogHighWater = 0
    private var encodedInstanceCount: UInt64 = 0
    private var bufferHighWater = 0
    private var missedFrameCount: UInt64 = 0
    private var submittedFrameCount: UInt64 = 0
    private var eventToSubmitWindow: BoundedDurationWindow
    private var cpuPreparationWindow: BoundedDurationWindow
    private var gpuEncodingWindow: BoundedDurationWindow
    private var gpuCompletionWindow: BoundedDurationWindow

    init(windowCapacity: Int = 240) {
        precondition(windowCapacity > 0)
        eventToSubmitWindow = BoundedDurationWindow(
            capacity: windowCapacity
        )
        cpuPreparationWindow = BoundedDurationWindow(
            capacity: windowCapacity
        )
        gpuEncodingWindow = BoundedDurationWindow(
            capacity: windowCapacity
        )
        gpuCompletionWindow = BoundedDurationWindow(
            capacity: windowCapacity
        )
    }

    mutating func recordBacklog(
        authoritative: Int,
        predicted: Int
    ) {
        precondition(authoritative >= 0)
        precondition(predicted >= 0)
        authoritativeBacklog = authoritative
        predictedBacklog = predicted
        let (total, overflow) = authoritative.addingReportingOverflow(
            predicted
        )
        backlogHighWater = max(
            backlogHighWater,
            overflow ? Int.max : total
        )
    }

    mutating func recordEncoding(
        instanceCount: UInt64,
        bufferCount: Int
    ) {
        precondition(bufferCount >= 0)
        encodedInstanceCount = Self.saturatingAdd(
            encodedInstanceCount,
            instanceCount
        )
        bufferHighWater = max(bufferHighWater, bufferCount)
    }

    mutating func recordMissedFrames(_ count: UInt64 = 1) {
        missedFrameCount = Self.saturatingAdd(
            missedFrameCount,
            count
        )
    }

    mutating func recordTimings(
        eventToSubmitNanoseconds: UInt64,
        cpuPreparationNanoseconds: UInt64,
        gpuEncodingNanoseconds: UInt64,
        gpuCompletionNanoseconds: UInt64
    ) {
        // A zero event-to-submit duration is the sentinel used when a
        // submitted follow-up frame has no new input receipt. Keep counting
        // that submitted frame, but do not let the sentinel dilute the
        // latency distribution for frames that can be tied to input.
        if eventToSubmitNanoseconds > 0 {
            eventToSubmitWindow.append(eventToSubmitNanoseconds)
        }
        cpuPreparationWindow.append(cpuPreparationNanoseconds)
        gpuEncodingWindow.append(gpuEncodingNanoseconds)
        gpuCompletionWindow.append(gpuCompletionNanoseconds)
        submittedFrameCount = Self.saturatingAdd(
            submittedFrameCount,
            1
        )
    }

    mutating func reset() {
        authoritativeBacklog = 0
        predictedBacklog = 0
        backlogHighWater = 0
        encodedInstanceCount = 0
        bufferHighWater = 0
        missedFrameCount = 0
        submittedFrameCount = 0
        eventToSubmitWindow.reset()
        cpuPreparationWindow.reset()
        gpuEncodingWindow.reset()
        gpuCompletionWindow.reset()
    }

    private static func saturatingAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}

struct BoundedDurationWindow: Sendable {
    private let capacity: Int
    private var samples: ContiguousArray<UInt64>
    private var sampleCount = 0
    private var nextIndex = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        samples = ContiguousArray(repeating: 0, count: capacity)
    }

    mutating func append(_ sample: UInt64) {
        samples[nextIndex] = sample
        nextIndex = (nextIndex + 1) % capacity
        sampleCount = min(capacity, sampleCount + 1)
    }

    func percentiles() -> DepositionDurationPercentiles {
        guard sampleCount > 0 else { return .zero }
        var sorted = Array(samples.prefix(sampleCount))
        sorted.sort()
        return DepositionDurationPercentiles(
            p50: Self.nearestRank(0.50, sorted: sorted),
            p95: Self.nearestRank(0.95, sorted: sorted),
            p99: Self.nearestRank(0.99, sorted: sorted)
        )
    }

    mutating func reset() {
        sampleCount = 0
        nextIndex = 0
    }

    private static func nearestRank(
        _ percentile: Double,
        sorted: [UInt64]
    ) -> UInt64 {
        let rank = Int(ceil(Double(sorted.count) * percentile))
        return sorted[max(0, min(rank - 1, sorted.count - 1))]
    }
}
