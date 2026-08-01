#if DEBUG
import Foundation
@testable import MetalRenderer
import Testing

@MainActor
@Test
func debugPerformanceMonitorReportsSteadyFrameCadence() {
    let monitor = DebugPerformanceMonitor()
    var publicationCount = 0

    for frame in 0...20 {
        if monitor.recordPresentedFrame(
            at: Double(frame) / 60,
            targetFramesPerSecond: 60
        ) {
            publicationCount += 1
        }
    }

    #expect(publicationCount == 1)
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
        gpuDurationNanoseconds: 2_500_000,
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
        gpuDurationNanoseconds: 5_000_000,
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
    #expect(diagnostics.gpuDuration.p95 == 5_000_000)
    #expect(diagnostics.gpuCompletion.p99 == 6_000_000)
}

@MainActor
@Test
func debugPerformanceMonitorUsesRendererOwnedDiagnostics() {
    let monitor = DebugPerformanceMonitor()
    monitor.recordRendererFrame(
        GPUFrameMetrics(
            cpuEncodeMilliseconds: 1.5,
            gpuMilliseconds: 2.25,
            eventToSubmitNanoseconds: 3_000_000,
            gpuCompletionNanoseconds: 4_000_000,
            encodedDabCount: 7,
            encodedInstanceCount: 13,
            bufferLeaseCount: 2
        ),
        deposition: BrushLabRendererDepositionDiagnosticSnapshot(
            authoritativePending: 9,
            predictedPending: 3,
            authoritativeHighWater: 19,
            predictedHighWater: 13,
            backlogHighWater: 32,
            lastFrameEncodedDabCount: 7,
            lastFrameEncodedInstanceCount: 13,
            strokeEncodedDabCount: 17,
            strokeEncodedInstanceCount: 31,
            currentBufferLeaseCount: 2,
            strokeBufferLeaseHighWater: 3,
            lifetimeBufferLeaseHighWater: 4,
            missedFrameCount: 5,
            eventToSubmit: .init(p50: 2_000_000, p95: 3_000_000, p99: 4_000_000),
            cpuPreparation: .init(p50: 1_000_000, p95: 1_500_000, p99: 2_000_000),
            gpuCompletion: .init(p50: 3_000_000, p95: 4_000_000, p99: 5_000_000)
        )
    )

    let diagnostics = monitor.snapshot.deposition
    #expect(diagnostics.authoritativeBacklog == 9)
    #expect(diagnostics.predictedBacklog == 3)
    #expect(diagnostics.encodedDabCount == 17)
    #expect(diagnostics.encodedInstanceCount == 31)
    #expect(diagnostics.cpuPreparation.p95 == 1_500_000)
    #expect(diagnostics.eventToSubmit.p95 == 3_000_000)
    #expect(diagnostics.gpuDuration.p95 == 2_250_000)
    #expect(diagnostics.gpuCompletion.p95 == 4_000_000)
}

@MainActor
@Test
func debugPerformanceMonitorPublishesStrokeRuntimeContract() {
    let monitor = DebugPerformanceMonitor()
    let runtime = debugRuntimeSnapshot()

    monitor.recordStrokeRuntimeSnapshot(runtime)

    #expect(monitor.snapshot.strokeRuntime == runtime)
    #expect(monitor.snapshot.deposition.authoritativeBacklog == 3)
    #expect(monitor.snapshot.deposition.predictedBacklog == 2)
    #expect(monitor.snapshot.deposition.cpuPreparation.p95 == 2_000_000)
    #expect(monitor.snapshot.deposition.eventToSubmit.p95 == 4_000_000)
    #expect(monitor.snapshot.deposition.gpuDuration.p95 == 3_000_000)
}

@Test
@MainActor
func debugPerformanceLoggerWritesReviewableJSONLines() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = DebugPerformanceLogger(
        directory: directory,
        filename: "manual-test.jsonl"
    )
    let snapshot = DebugPerformanceSnapshot(
        framesPerSecond: 59.8,
        p95FrameMilliseconds: 17.1,
        missedFramePercentage: 0.5,
        targetFramesPerSecond: 60,
        sampleCount: 42,
        strokeRuntime: debugRuntimeSnapshot()
    )
    let context = DebugPerformanceContext(
        brushID: "builtin.native-ink",
        tool: "draw",
        brushDiameter: 40,
        symmetry: "grid",
        canvasWidth: 256,
        canvasHeight: 256,
        gridVisible: true
    )

    logger.record(
        .sessionStarted,
        snapshot: snapshot,
        gpuName: "Test GPU"
    )
    logger.record(
        .sample,
        snapshot: snapshot,
        gpuName: "Test GPU",
        context: context
    )
    logger.record(
        .sessionEnded,
        snapshot: snapshot,
        gpuName: "Test GPU"
    )
    try await logger.flush()

    let data = try Data(contentsOf: logger.logURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let records = try data.split(separator: 0x0A).map {
        try decoder.decode(
            DebugPerformanceLogRecord.self,
            from: Data($0)
        )
    }
    #expect(records.map(\.kind) == [
        .sessionStarted,
        .sample,
        .sessionEnded,
    ])
    #expect(records[0].segmentID != nil)
    #expect(records.allSatisfy { $0.segmentID == records[0].segmentID })
    #expect(records[1].snapshot == snapshot)
    #expect(records[1].gpuName == "Test GPU")
    #expect(records[1].context == context)
}

@Test
@MainActor
func debugPerformanceLoggerBuffersAttributedSegmentsUntilFlush() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessionID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000101"
    )!
    let segmentID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000102"
    )!
    let strokeID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000103"
    )!
    let logger = DebugPerformanceLogger(
        directory: directory,
        filename: "buffered-test.jsonl"
    )
    let snapshot = DebugPerformanceSnapshot(
        strokeRuntime: debugRuntimeSnapshot()
    )

    logger.record(
        .segmentBegan,
        snapshot: snapshot,
        gpuName: "Test GPU"
    )
    logger.record(
        .sample,
        snapshot: snapshot,
        gpuName: "Test GPU"
    )
    logger.record(
        .segmentEnded,
        snapshot: snapshot,
        gpuName: "Test GPU"
    )

    #expect(!FileManager.default.fileExists(atPath: logger.logURL.path))
    try await logger.flush()

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let records = try Data(contentsOf: logger.logURL)
        .split(separator: 0x0A)
        .map {
            try decoder.decode(
                DebugPerformanceLogRecord.self,
                from: Data($0)
            )
        }
    #expect(records.map(\.kind) == [
        .segmentBegan,
        .sample,
        .segmentEnded,
    ])
    #expect(records.allSatisfy { $0.sessionID == sessionID })
    #expect(records.allSatisfy { $0.segmentID == segmentID })
    #expect(records.allSatisfy { $0.strokeID == strokeID })
    #expect(records[1].snapshot.strokeRuntime == debugRuntimeSnapshot())
}

@Test
@MainActor
func debugPerformanceLoggerBoundsRecordsBeforeBackgroundEncoding()
    async throws
{
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = DebugPerformanceLogger(
        directory: directory,
        filename: "bounded-test.jsonl",
        pendingRecordCapacity: 2,
        batchSize: 100
    )
    let snapshot = DebugPerformanceSnapshot(
        strokeRuntime: debugRuntimeSnapshot()
    )

    for _ in 0..<5 {
        logger.record(
            .sample,
            snapshot: snapshot,
            gpuName: "Test GPU"
        )
    }
    let diagnostics = await logger.diagnostics()

    #expect(diagnostics.maximumBufferedRecordCount <= 2)
    #expect(diagnostics.droppedRecordCount == 3)
    #expect(!FileManager.default.fileExists(atPath: logger.logURL.path))
    try await logger.flush()
}

@Test
@MainActor
func debugPerformanceLoggerKeepsSegmentBoundariesUnderSamplePressure()
    async throws
{
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = DebugPerformanceLogger(
        directory: directory,
        filename: "boundary-pressure-test.jsonl",
        pendingRecordCapacity: 2,
        batchSize: 100
    )
    let snapshot = DebugPerformanceSnapshot(
        strokeRuntime: debugRuntimeSnapshot()
    )

    logger.record(.segmentBegan, snapshot: snapshot, gpuName: "Test GPU")
    for _ in 0..<3 {
        logger.record(.sample, snapshot: snapshot, gpuName: "Test GPU")
    }
    logger.record(.segmentEnded, snapshot: snapshot, gpuName: "Test GPU")
    try await logger.flush()

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let records = try Data(contentsOf: logger.logURL)
        .split(separator: 0x0A)
        .map {
            try decoder.decode(
                DebugPerformanceLogRecord.self,
                from: Data($0)
            )
        }
    let diagnostics = await logger.diagnostics()

    #expect(records.map(\.kind) == [.segmentBegan, .segmentEnded])
    #expect(records[0].segmentID == records[1].segmentID)
    #expect(records[0].strokeID == records[1].strokeID)
    #expect(diagnostics.maximumBufferedRecordCount <= 2)
    #expect(diagnostics.droppedRecordCount == 3)
}

@Test
@MainActor
func debugPerformanceLoggerAcceptsNextSegmentDuringFlush() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = DebugPerformanceLogger(
        directory: directory,
        filename: "flush-handoff-test.jsonl",
        pendingRecordCapacity: 2,
        batchSize: 100
    )
    let snapshot = DebugPerformanceSnapshot(
        strokeRuntime: debugRuntimeSnapshot()
    )

    logger.record(.sessionEnded, snapshot: snapshot, gpuName: "Test GPU")
    let firstFlush = Task { try await logger.flush() }
    await Task.yield()
    let accepted = logger.record(
        .segmentBegan,
        snapshot: snapshot,
        gpuName: "Test GPU"
    )
    try await firstFlush.value
    logger.record(.segmentEnded, snapshot: snapshot, gpuName: "Test GPU")
    try await logger.flush()

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let records = try Data(contentsOf: logger.logURL)
        .split(separator: 0x0A)
        .map {
            try decoder.decode(
                DebugPerformanceLogRecord.self,
                from: Data($0)
            )
        }

    #expect(accepted)
    #expect(records.map(\.kind) == [
        .sessionEnded,
        .segmentBegan,
        .segmentEnded,
    ])
}

private func debugRuntimeSnapshot() -> StrokeRuntimeTelemetrySnapshot {
    StrokeRuntimeTelemetrySnapshot(
        sessionID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000101"
        )!,
        segmentID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000102"
        ),
        strokeID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000103"
        ),
        traceProfile: .productionTenSeconds,
        inputProvenance: .init(
            actual: 10,
            coalesced: 5,
            predicted: 3,
            estimatedUpdate: 1
        ),
        newLogicalDabCount: 20,
        newProjectedDabCount: 30,
        authoritativeReplayCount: 0,
        predictedReplayCount: 2,
        authoritativeQueueDepth: 3,
        predictedQueueDepth: 2,
        authoritativeQueueHighWater: 7,
        predictedQueueHighWater: 4,
        prepare: .init(p50: 1_000_000, p95: 2_000_000, p99: 3_000_000),
        eventToSubmit: .init(
            p50: 2_000_000,
            p95: 4_000_000,
            p99: 5_000_000
        ),
        gpu: .init(p50: 2_000_000, p95: 3_000_000, p99: 4_000_000),
        frame: .init(
            p50: 16_000_000,
            p95: 17_000_000,
            p99: 18_000_000
        ),
        missedFrameCount: 1,
        eventToSubmitMissCount: 1,
        frameCount: 100,
        observedDurationNanoseconds: 10_000_000_000,
        cacheHitCount: 12,
        cacheMissCount: 1,
        memoryHighWaterBytes: 4_096,
        authoritativeQueueDepths: [5, 3, 3],
        lastTimestamps: nil
    )
}
#endif
