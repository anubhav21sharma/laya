import Foundation

public protocol StrokeRuntimeTimestampSource: Sendable {
    func nowNanoseconds() -> UInt64
}

public struct StrokeRuntimeUptimeTimestampSource:
    StrokeRuntimeTimestampSource, Sendable
{
    public init() {}

    public func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

public enum StrokeRuntimeTraceProfile: String, Codable, Sendable {
    case productionTenSeconds
    case productionAcceleratedTenMinutes
    case syntheticTest

    public var logicalDurationNanoseconds: UInt64 {
        switch self {
        case .productionTenSeconds:
            10_000_000_000
        case .productionAcceleratedTenMinutes:
            600_000_000_000
        case .syntheticTest:
            0
        }
    }

    public var isAccelerated: Bool {
        self == .productionAcceleratedTenMinutes
    }

    public var isProduction: Bool {
        switch self {
        case .productionTenSeconds, .productionAcceleratedTenMinutes:
            true
        case .syntheticTest:
            false
        }
    }
}

public enum StrokeRuntimeInputProvenance: String, Codable, Sendable {
    case actual
    case coalesced
    case predicted
    case estimatedUpdate
}

public struct StrokeRuntimeInputProvenanceCounts:
    Codable, Equatable, Sendable
{
    public var actual: UInt64
    public var coalesced: UInt64
    public var predicted: UInt64
    public var estimatedUpdate: UInt64

    public static let zero = StrokeRuntimeInputProvenanceCounts(
        actual: 0,
        coalesced: 0,
        predicted: 0,
        estimatedUpdate: 0
    )

    public init(
        actual: UInt64,
        coalesced: UInt64,
        predicted: UInt64,
        estimatedUpdate: UInt64
    ) {
        self.actual = actual
        self.coalesced = coalesced
        self.predicted = predicted
        self.estimatedUpdate = estimatedUpdate
    }

    mutating func record(
        _ provenance: StrokeRuntimeInputProvenance,
        count: UInt64
    ) {
        switch provenance {
        case .actual:
            actual = Self.saturatingAdd(actual, count)
        case .coalesced:
            coalesced = Self.saturatingAdd(coalesced, count)
        case .predicted:
            predicted = Self.saturatingAdd(predicted, count)
        case .estimatedUpdate:
            estimatedUpdate = Self.saturatingAdd(estimatedUpdate, count)
        }
    }

    private static func saturatingAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}

public struct StrokeRuntimeFrameTimestamps:
    Codable, Equatable, Sendable
{
    public let input: UInt64
    public let prepareStarted: UInt64
    public let prepareFinished: UInt64
    public let submitted: UInt64
    public let gpuStarted: UInt64
    public let gpuFinished: UInt64
    public let presented: UInt64

    public init(
        input: UInt64,
        prepareStarted: UInt64,
        prepareFinished: UInt64,
        submitted: UInt64,
        gpuStarted: UInt64,
        gpuFinished: UInt64,
        presented: UInt64
    ) {
        self.input = input
        self.prepareStarted = prepareStarted
        self.prepareFinished = prepareFinished
        self.submitted = submitted
        self.gpuStarted = gpuStarted
        self.gpuFinished = gpuFinished
        self.presented = presented
    }
}

public struct StrokeRuntimeFrameSample: Equatable, Sendable {
    public let strokeID: UUID
    public let timestamps: StrokeRuntimeFrameTimestamps
    public let targetFrameDurationNanoseconds: UInt64
    public let newLogicalDabCount: UInt64
    public let newProjectedDabCount: UInt64
    public let authoritativeReplayCount: UInt64
    public let predictedReplayCount: UInt64
    public let authoritativeQueueDepth: Int
    public let predictedQueueDepth: Int
    public let cacheHitCount: UInt64
    public let cacheMissCount: UInt64
    public let residentMemoryBytes: UInt64

    public init(
        strokeID: UUID,
        timestamps: StrokeRuntimeFrameTimestamps,
        targetFrameDurationNanoseconds: UInt64,
        newLogicalDabCount: UInt64,
        newProjectedDabCount: UInt64,
        authoritativeReplayCount: UInt64,
        predictedReplayCount: UInt64,
        authoritativeQueueDepth: Int,
        predictedQueueDepth: Int,
        cacheHitCount: UInt64,
        cacheMissCount: UInt64,
        residentMemoryBytes: UInt64
    ) {
        self.strokeID = strokeID
        self.timestamps = timestamps
        self.targetFrameDurationNanoseconds =
            targetFrameDurationNanoseconds
        self.newLogicalDabCount = newLogicalDabCount
        self.newProjectedDabCount = newProjectedDabCount
        self.authoritativeReplayCount = authoritativeReplayCount
        self.predictedReplayCount = predictedReplayCount
        self.authoritativeQueueDepth = authoritativeQueueDepth
        self.predictedQueueDepth = predictedQueueDepth
        self.cacheHitCount = cacheHitCount
        self.cacheMissCount = cacheMissCount
        self.residentMemoryBytes = residentMemoryBytes
    }
}

public enum StrokeRuntimeSegmentEventKind: String, Codable, Sendable {
    case segmentBegan
    case segmentEnded
}

public struct StrokeRuntimeSegmentMarker: Codable, Equatable, Sendable {
    public let kind: StrokeRuntimeSegmentEventKind
    public let sessionID: UUID
    public let segmentID: UUID
    public let strokeID: UUID?
    public let timestampNanoseconds: UInt64
    public let traceProfile: StrokeRuntimeTraceProfile

    public init(
        kind: StrokeRuntimeSegmentEventKind,
        sessionID: UUID,
        segmentID: UUID,
        strokeID: UUID?,
        timestampNanoseconds: UInt64,
        traceProfile: StrokeRuntimeTraceProfile
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.strokeID = strokeID
        self.timestampNanoseconds = timestampNanoseconds
        self.traceProfile = traceProfile
    }
}

public struct StrokeRuntimeTelemetrySnapshot:
    Codable, Equatable, Sendable
{
    public let sessionID: UUID
    public let segmentID: UUID?
    public let strokeID: UUID?
    public let traceProfile: StrokeRuntimeTraceProfile
    public let inputProvenance: StrokeRuntimeInputProvenanceCounts
    public let newLogicalDabCount: UInt64
    public let newProjectedDabCount: UInt64
    public let authoritativeReplayCount: UInt64
    public let predictedReplayCount: UInt64
    public let authoritativeQueueDepth: Int
    public let predictedQueueDepth: Int
    public let authoritativeQueueHighWater: Int
    public let predictedQueueHighWater: Int
    public let prepare: DepositionDurationPercentiles
    public let eventToSubmit: DepositionDurationPercentiles
    public let gpu: DepositionDurationPercentiles
    public let frame: DepositionDurationPercentiles
    public let missedFrameCount: UInt64
    public let eventToSubmitMissCount: UInt64
    public let frameCount: UInt64
    public let observedDurationNanoseconds: UInt64
    public let cacheHitCount: UInt64
    public let cacheMissCount: UInt64
    public let memoryHighWaterBytes: UInt64
    public let authoritativeQueueDepths: [Int]
    public let lastTimestamps: StrokeRuntimeFrameTimestamps?

    public var missedFrameFraction: Double {
        guard frameCount > 0 else { return 0 }
        return Double(missedFrameCount) / Double(frameCount)
    }

    public var eventToSubmitMissFraction: Double {
        guard frameCount > 0 else { return 0 }
        return Double(eventToSubmitMissCount) / Double(frameCount)
    }

    public init(
        sessionID: UUID,
        segmentID: UUID?,
        strokeID: UUID?,
        traceProfile: StrokeRuntimeTraceProfile,
        inputProvenance: StrokeRuntimeInputProvenanceCounts,
        newLogicalDabCount: UInt64,
        newProjectedDabCount: UInt64,
        authoritativeReplayCount: UInt64,
        predictedReplayCount: UInt64,
        authoritativeQueueDepth: Int,
        predictedQueueDepth: Int,
        authoritativeQueueHighWater: Int,
        predictedQueueHighWater: Int,
        prepare: DepositionDurationPercentiles,
        eventToSubmit: DepositionDurationPercentiles,
        gpu: DepositionDurationPercentiles,
        frame: DepositionDurationPercentiles,
        missedFrameCount: UInt64,
        eventToSubmitMissCount: UInt64,
        frameCount: UInt64,
        observedDurationNanoseconds: UInt64,
        cacheHitCount: UInt64,
        cacheMissCount: UInt64,
        memoryHighWaterBytes: UInt64,
        authoritativeQueueDepths: [Int],
        lastTimestamps: StrokeRuntimeFrameTimestamps?
    ) {
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.strokeID = strokeID
        self.traceProfile = traceProfile
        self.inputProvenance = inputProvenance
        self.newLogicalDabCount = newLogicalDabCount
        self.newProjectedDabCount = newProjectedDabCount
        self.authoritativeReplayCount = authoritativeReplayCount
        self.predictedReplayCount = predictedReplayCount
        self.authoritativeQueueDepth = authoritativeQueueDepth
        self.predictedQueueDepth = predictedQueueDepth
        self.authoritativeQueueHighWater = authoritativeQueueHighWater
        self.predictedQueueHighWater = predictedQueueHighWater
        self.prepare = prepare
        self.eventToSubmit = eventToSubmit
        self.gpu = gpu
        self.frame = frame
        self.missedFrameCount = missedFrameCount
        self.eventToSubmitMissCount = eventToSubmitMissCount
        self.frameCount = frameCount
        self.observedDurationNanoseconds = observedDurationNanoseconds
        self.cacheHitCount = cacheHitCount
        self.cacheMissCount = cacheMissCount
        self.memoryHighWaterBytes = memoryHighWaterBytes
        self.authoritativeQueueDepths = authoritativeQueueDepths
        self.lastTimestamps = lastTimestamps
    }
}

public enum StrokeRuntimeTelemetryError: Error, Equatable {
    case segmentAlreadyActive
    case noActiveSegment
    case strokeDoesNotMatchSegment
    case invalidQueueDepth
    case invalidTargetFrameDuration
    case invalidTimestampOrder
}

public struct StrokeRuntimeTelemetry: Sendable {
    public var snapshot: StrokeRuntimeTelemetrySnapshot {
        StrokeRuntimeTelemetrySnapshot(
            sessionID: sessionID,
            segmentID: segmentID,
            strokeID: strokeID,
            traceProfile: traceProfile,
            inputProvenance: inputProvenance,
            newLogicalDabCount: newLogicalDabCount,
            newProjectedDabCount: newProjectedDabCount,
            authoritativeReplayCount: authoritativeReplayCount,
            predictedReplayCount: predictedReplayCount,
            authoritativeQueueDepth: authoritativeQueueDepth,
            predictedQueueDepth: predictedQueueDepth,
            authoritativeQueueHighWater: authoritativeQueueHighWater,
            predictedQueueHighWater: predictedQueueHighWater,
            prepare: prepareWindow.percentiles(),
            eventToSubmit: eventToSubmitWindow.percentiles(),
            gpu: gpuWindow.percentiles(),
            frame: frameWindow.percentiles(),
            missedFrameCount: missedFrameCount,
            eventToSubmitMissCount: eventToSubmitMissCount,
            frameCount: frameCount,
            observedDurationNanoseconds: observedDurationNanoseconds,
            cacheHitCount: cacheHitCount,
            cacheMissCount: cacheMissCount,
            memoryHighWaterBytes: memoryHighWaterBytes,
            authoritativeQueueDepths: authoritativeQueueDepths,
            lastTimestamps: lastTimestamps
        )
    }

    private let sessionID: UUID
    private let traceProfile: StrokeRuntimeTraceProfile
    private let timestampSource: any StrokeRuntimeTimestampSource
    private let queueWindowCapacity: Int
    private var segmentID: UUID?
    private var strokeID: UUID?
    private var segmentActive = false
    private var inputProvenance = StrokeRuntimeInputProvenanceCounts.zero
    private var newLogicalDabCount: UInt64 = 0
    private var newProjectedDabCount: UInt64 = 0
    private var authoritativeReplayCount: UInt64 = 0
    private var predictedReplayCount: UInt64 = 0
    private var authoritativeQueueDepth = 0
    private var predictedQueueDepth = 0
    private var authoritativeQueueHighWater = 0
    private var predictedQueueHighWater = 0
    private var prepareWindow: BoundedDurationWindow
    private var eventToSubmitWindow: BoundedDurationWindow
    private var gpuWindow: BoundedDurationWindow
    private var frameWindow: BoundedDurationWindow
    private var missedFrameCount: UInt64 = 0
    private var eventToSubmitMissCount: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var firstInputTimestamp: UInt64?
    private var observedDurationNanoseconds: UInt64 = 0
    private var cacheHitCount: UInt64 = 0
    private var cacheMissCount: UInt64 = 0
    private var memoryHighWaterBytes: UInt64 = 0
    private var authoritativeQueueDepths: [Int] = []
    private var previousPresentationTimestamp: UInt64?
    private var lastTimestamps: StrokeRuntimeFrameTimestamps?

    public init(
        sessionID: UUID = UUID(),
        traceProfile: StrokeRuntimeTraceProfile,
        windowCapacity: Int = 600,
        timestampSource: any StrokeRuntimeTimestampSource =
            StrokeRuntimeUptimeTimestampSource()
    ) {
        precondition(windowCapacity > 0)
        self.sessionID = sessionID
        self.traceProfile = traceProfile
        self.timestampSource = timestampSource
        queueWindowCapacity = windowCapacity
        prepareWindow = BoundedDurationWindow(capacity: windowCapacity)
        eventToSubmitWindow = BoundedDurationWindow(
            capacity: windowCapacity
        )
        gpuWindow = BoundedDurationWindow(capacity: windowCapacity)
        frameWindow = BoundedDurationWindow(capacity: windowCapacity)
        authoritativeQueueDepths.reserveCapacity(windowCapacity)
    }

    public mutating func beginSegment(
        id: UUID = UUID(),
        strokeID: UUID? = nil
    ) throws -> StrokeRuntimeSegmentMarker {
        guard !segmentActive else {
            throw StrokeRuntimeTelemetryError.segmentAlreadyActive
        }
        segmentID = id
        self.strokeID = strokeID
        segmentActive = true
        return marker(.segmentBegan, segmentID: id)
    }

    public mutating func endSegment()
        throws -> StrokeRuntimeSegmentMarker
    {
        guard segmentActive, let segmentID else {
            throw StrokeRuntimeTelemetryError.noActiveSegment
        }
        let marker = marker(.segmentEnded, segmentID: segmentID)
        segmentActive = false
        return marker
    }

    public mutating func recordInput(
        _ provenance: StrokeRuntimeInputProvenance,
        count: UInt64 = 1
    ) {
        inputProvenance.record(provenance, count: count)
    }

    public mutating func recordFrame(
        _ sample: StrokeRuntimeFrameSample
    ) throws {
        guard segmentActive else {
            throw StrokeRuntimeTelemetryError.noActiveSegment
        }
        if let strokeID, strokeID != sample.strokeID {
            throw StrokeRuntimeTelemetryError.strokeDoesNotMatchSegment
        }
        guard sample.authoritativeQueueDepth >= 0,
              sample.predictedQueueDepth >= 0
        else {
            throw StrokeRuntimeTelemetryError.invalidQueueDepth
        }
        guard sample.targetFrameDurationNanoseconds > 0 else {
            throw StrokeRuntimeTelemetryError.invalidTargetFrameDuration
        }
        let timestamps = sample.timestamps
        guard timestamps.input <= timestamps.prepareStarted,
              timestamps.prepareStarted <= timestamps.prepareFinished,
              timestamps.prepareFinished <= timestamps.submitted,
              timestamps.gpuStarted <= timestamps.gpuFinished,
              timestamps.submitted <= timestamps.presented
        else {
            throw StrokeRuntimeTelemetryError.invalidTimestampOrder
        }

        strokeID = sample.strokeID
        let prepare = timestamps.prepareFinished
            - timestamps.prepareStarted
        let eventToSubmit = timestamps.submitted - timestamps.input
        let gpu = timestamps.gpuFinished - timestamps.gpuStarted
        prepareWindow.append(prepare)
        eventToSubmitWindow.append(eventToSubmit)
        gpuWindow.append(gpu)

        if let previousPresentationTimestamp,
           timestamps.presented > previousPresentationTimestamp
        {
            let interval = timestamps.presented
                - previousPresentationTimestamp
            frameWindow.append(interval)
            let expectedFrames = max(
                UInt64(1),
                Self.roundedQuotient(
                    interval,
                    sample.targetFrameDurationNanoseconds
                )
            )
            if expectedFrames > 1 {
                missedFrameCount = Self.saturatingAdd(
                    missedFrameCount,
                    expectedFrames - 1
                )
            }
        }
        previousPresentationTimestamp = timestamps.presented
        if firstInputTimestamp == nil {
            firstInputTimestamp = timestamps.input
        }
        if let firstInputTimestamp,
           timestamps.presented >= firstInputTimestamp
        {
            observedDurationNanoseconds = timestamps.presented
                - firstInputTimestamp
        }
        if eventToSubmit > sample.targetFrameDurationNanoseconds {
            eventToSubmitMissCount = Self.saturatingAdd(
                eventToSubmitMissCount,
                1
            )
        }

        newLogicalDabCount = Self.saturatingAdd(
            newLogicalDabCount,
            sample.newLogicalDabCount
        )
        newProjectedDabCount = Self.saturatingAdd(
            newProjectedDabCount,
            sample.newProjectedDabCount
        )
        authoritativeReplayCount = Self.saturatingAdd(
            authoritativeReplayCount,
            sample.authoritativeReplayCount
        )
        predictedReplayCount = Self.saturatingAdd(
            predictedReplayCount,
            sample.predictedReplayCount
        )
        authoritativeQueueDepth = sample.authoritativeQueueDepth
        predictedQueueDepth = sample.predictedQueueDepth
        authoritativeQueueHighWater = max(
            authoritativeQueueHighWater,
            sample.authoritativeQueueDepth
        )
        predictedQueueHighWater = max(
            predictedQueueHighWater,
            sample.predictedQueueDepth
        )
        if authoritativeQueueDepths.count == queueWindowCapacity {
            authoritativeQueueDepths.removeFirst()
        }
        authoritativeQueueDepths.append(sample.authoritativeQueueDepth)
        cacheHitCount = Self.saturatingAdd(
            cacheHitCount,
            sample.cacheHitCount
        )
        cacheMissCount = Self.saturatingAdd(
            cacheMissCount,
            sample.cacheMissCount
        )
        memoryHighWaterBytes = max(
            memoryHighWaterBytes,
            sample.residentMemoryBytes
        )
        frameCount = Self.saturatingAdd(frameCount, 1)
        lastTimestamps = timestamps
    }

    private func marker(
        _ kind: StrokeRuntimeSegmentEventKind,
        segmentID: UUID
    ) -> StrokeRuntimeSegmentMarker {
        StrokeRuntimeSegmentMarker(
            kind: kind,
            sessionID: sessionID,
            segmentID: segmentID,
            strokeID: strokeID,
            timestampNanoseconds: timestampSource.nowNanoseconds(),
            traceProfile: traceProfile
        )
    }

    private static func roundedQuotient(
        _ numerator: UInt64,
        _ denominator: UInt64
    ) -> UInt64 {
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        let roundsUp = remainder >= denominator - remainder
        return quotient + (roundsUp ? 1 : 0)
    }

    private static func saturatingAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}
