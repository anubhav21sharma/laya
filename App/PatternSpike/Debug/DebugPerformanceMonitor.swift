#if DEBUG
import Foundation
import MetalRenderer
import Observation

struct DebugPerformanceSnapshot: Codable, Equatable, Sendable {
    var framesPerSecond = 0.0
    var p95FrameMilliseconds = 0.0
    var missedFramePercentage = 0.0
    var targetFramesPerSecond = 0
    var sampleCount = 0
    var missedFrameCount: UInt64 = 0
    var deposition = DebugDepositionSnapshot()
    var strokeRuntime: StrokeRuntimeTelemetrySnapshot?
}

struct DebugDurationPercentiles: Codable, Equatable, Sendable {
    var p50: UInt64 = 0
    var p95: UInt64 = 0
    var p99: UInt64 = 0
}

extension DebugDurationPercentiles {
    init(_ source: DepositionDurationPercentiles) {
        p50 = source.p50
        p95 = source.p95
        p99 = source.p99
    }
}

struct DebugDepositionSnapshot: Codable, Equatable, Sendable {
    var authoritativeBacklog = 0
    var predictedBacklog = 0
    var authoritativeHighWater = 0
    var predictedHighWater = 0
    var backlogHighWater = 0
    var encodedDabCount: UInt64 = 0
    var encodedInstanceCount: UInt64 = 0
    var currentBufferLeaseCount = 0
    var strokeBufferLeaseHighWater = 0
    var lifetimeBufferLeaseHighWater = 0
    var missedFrameCount: UInt64 = 0
    var cpuPreparation = DebugDurationPercentiles()
    var eventToSubmit = DebugDurationPercentiles()
    var gpuDuration = DebugDurationPercentiles()
    var gpuCompletion = DebugDurationPercentiles()
}

enum DebugPerformanceLogEventKind: String, Codable, Sendable {
    case sessionStarted
    case segmentBegan
    case sample
    case segmentEnded
    case sessionEnded
}

struct DebugPerformanceContext: Codable, Equatable, Sendable {
    let brushID: String
    let tool: String
    let brushDiameter: Float
    let symmetry: String
    let canvasWidth: Int
    let canvasHeight: Int
    let gridVisible: Bool
}

struct DebugPerformanceLogRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: UUID
    let timestamp: Date
    let kind: DebugPerformanceLogEventKind
    let gpuName: String
    let segmentID: UUID?
    let strokeID: UUID?
    let context: DebugPerformanceContext?
    let snapshot: DebugPerformanceSnapshot
}

@MainActor
final class DebugPerformanceLogger {
    let logURL: URL

    private let sink: DebugPerformanceLogSink
    private let pendingRecordCapacity: Int
    private var mailbox: DebugPerformanceLogMailbox?
    private var continuation: AsyncStream<Void>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var flushTask: Task<Void, Error>?
    private var flushGeneration: UInt64 = 0
    private var maximumMailboxRecordCount = 0
    private var droppedMailboxRecordCount: UInt64 = 0

    init(
        directory: URL? = nil,
        filename: String? = nil,
        pendingRecordCapacity: Int = 256,
        batchSize: Int = 32
    ) {
        precondition(pendingRecordCapacity > 0)
        precondition(batchSize > 0)
        let root = directory ?? Self.defaultDirectory()
        let generatedName = filename ?? (
            "brush-performance-"
                + String(Int(Date().timeIntervalSince1970))
                + "-"
                + UUID().uuidString.lowercased()
                + ".jsonl"
        )
        logURL = root.appendingPathComponent(
            generatedName,
            isDirectory: false
        )
        sink = DebugPerformanceLogSink(
            logURL: logURL,
            pendingRecordCapacity: pendingRecordCapacity,
            batchSize: batchSize
        )
        self.pendingRecordCapacity = pendingRecordCapacity
        startConsumer()
    }

    deinit {
        continuation?.finish()
        consumerTask?.cancel()
        flushTask?.cancel()
    }

    @discardableResult
    func record(
        _ kind: DebugPerformanceLogEventKind,
        snapshot: DebugPerformanceSnapshot,
        gpuName: String,
        context: DebugPerformanceContext? = nil
    ) -> Bool {
        guard let runtime = snapshot.strokeRuntime else { return false }
        let record = DebugPerformanceLogRecord(
            schemaVersion: 1,
            sessionID: runtime.sessionID,
            timestamp: Date(),
            kind: kind,
            gpuName: gpuName,
            segmentID: runtime.segmentID,
            strokeID: runtime.strokeID,
            context: context,
            snapshot: snapshot
        )
        guard let mailbox, let continuation else {
            droppedMailboxRecordCount &+= 1
            return false
        }
        let result = mailbox.enqueue(record)
        maximumMailboxRecordCount = max(
            maximumMailboxRecordCount,
            result.bufferedRecordCount
        )
        droppedMailboxRecordCount &+= result.droppedRecordCount
        guard result.accepted else { return false }
        switch continuation.yield(()) {
        case .enqueued, .dropped:
            return true
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    func flush() async throws {
        if let activeFlush = flushTask {
            let generation = flushGeneration
            do {
                try await activeFlush.value
                clearCompletedFlush(generation: generation)
            } catch {
                clearCompletedFlush(generation: generation)
                throw error
            }
            // The active consumer is the bounded successor installed by the
            // earlier flush. Close and drain it as this call's own boundary.
            try await flush()
            return
        }
        let previousConsumer = consumerTask
        continuation?.finish()
        flushGeneration &+= 1
        let generation = flushGeneration
        let sink = sink
        let task = Task {
            await previousConsumer?.value
            try await sink.flush()
        }
        flushTask = task
        startConsumer(after: task)
        do {
            try await task.value
            clearCompletedFlush(generation: generation)
        } catch {
            clearCompletedFlush(generation: generation)
            throw error
        }
    }

    func diagnostics() async -> DebugPerformanceLogDiagnostics {
        let mailboxMaximum = maximumMailboxRecordCount
        let mailboxDropped = droppedMailboxRecordCount
        let sinkDiagnostics = await sink.diagnostics
        return DebugPerformanceLogDiagnostics(
            maximumBufferedRecordCount: max(
                mailboxMaximum,
                sinkDiagnostics.maximumBufferedRecordCount
            ),
            droppedRecordCount:
                mailboxDropped + sinkDiagnostics.droppedRecordCount
        )
    }

    private func startConsumer(
        after predecessor: Task<Void, Error>? = nil
    ) {
        let mailbox = DebugPerformanceLogMailbox(
            capacity: pendingRecordCapacity
        )
        let pair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.mailbox = mailbox
        continuation = pair.continuation
        consumerTask = Task { [sink] in
            if let predecessor {
                _ = try? await predecessor.value
            }
            guard !Task.isCancelled else { return }
            for await _ in pair.stream {
                for record in mailbox.drain() {
                    await sink.enqueue(record)
                }
            }
            for record in mailbox.drain() {
                await sink.enqueue(record)
            }
        }
    }

    private func clearCompletedFlush(generation: UInt64) {
        guard flushGeneration == generation, flushTask != nil else { return }
        flushTask = nil
    }

    private static func defaultDirectory() -> URL {
        let manager = FileManager.default
        let library = manager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first ?? manager.temporaryDirectory
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Pattern", isDirectory: true)
    }
}

struct DebugPerformanceLogDiagnostics: Equatable, Sendable {
    let maximumBufferedRecordCount: Int
    let droppedRecordCount: UInt64
}

private final class DebugPerformanceLogMailbox: @unchecked Sendable {
    struct EnqueueResult: Sendable {
        let accepted: Bool
        let bufferedRecordCount: Int
        let droppedRecordCount: UInt64
    }

    private let capacity: Int
    private let lock = NSLock()
    private var records: [DebugPerformanceLogRecord] = []

    init(capacity: Int) {
        self.capacity = capacity
        records.reserveCapacity(capacity)
    }

    func enqueue(
        _ record: DebugPerformanceLogRecord
    ) -> EnqueueResult {
        lock.lock()
        defer { lock.unlock() }
        if records.count == capacity {
            if record.kind == .sample {
                return EnqueueResult(
                    accepted: false,
                    bufferedRecordCount: records.count,
                    droppedRecordCount: 1
                )
            }
            if let sampleIndex = records.firstIndex(
                where: { $0.kind == .sample }
            ) {
                records.remove(at: sampleIndex)
            } else {
                records.removeFirst()
            }
            records.append(record)
            return EnqueueResult(
                accepted: true,
                bufferedRecordCount: records.count,
                droppedRecordCount: 1
            )
        }
        records.append(record)
        return EnqueueResult(
            accepted: true,
            bufferedRecordCount: records.count,
            droppedRecordCount: 0
        )
    }

    func drain() -> [DebugPerformanceLogRecord] {
        lock.lock()
        defer { lock.unlock() }
        let drained = records
        records.removeAll(keepingCapacity: true)
        return drained
    }
}

private actor DebugPerformanceLogSink {
    nonisolated let logURL: URL

    var diagnostics: DebugPerformanceLogDiagnostics {
        DebugPerformanceLogDiagnostics(
            maximumBufferedRecordCount: maximumBufferedRecordCount,
            droppedRecordCount: droppedRecordCount
        )
    }

    private let pendingRecordCapacity: Int
    private let batchSize: Int
    private var pendingRecords: [DebugPerformanceLogRecord] = []
    private var maximumBufferedRecordCount = 0
    private var droppedRecordCount: UInt64 = 0
    private var periodicFlushScheduled = false
    private var fileHandle: FileHandle?
    private let encoder: JSONEncoder

    init(
        logURL: URL,
        pendingRecordCapacity: Int,
        batchSize: Int
    ) {
        self.logURL = logURL
        self.pendingRecordCapacity = pendingRecordCapacity
        self.batchSize = batchSize
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        pendingRecords.reserveCapacity(pendingRecordCapacity)
    }

    func enqueue(_ record: DebugPerformanceLogRecord) {
        if pendingRecords.count == pendingRecordCapacity {
            if record.kind == .sample {
                droppedRecordCount &+= 1
                return
            }
            if let sampleIndex = pendingRecords.firstIndex(
                where: { $0.kind == .sample }
            ) {
                pendingRecords.remove(at: sampleIndex)
            } else {
                pendingRecords.removeFirst()
            }
            droppedRecordCount &+= 1
        }
        pendingRecords.append(record)
        maximumBufferedRecordCount = max(
            maximumBufferedRecordCount,
            pendingRecords.count
        )
        if pendingRecords.count >= batchSize {
            try? writePendingBatch(synchronize: false)
        } else if !periodicFlushScheduled {
            periodicFlushScheduled = true
            Task {
                try? await Task.sleep(for: .seconds(1))
                flushPeriodically()
            }
        }
    }

    func flush() throws {
        try writePendingBatch(synchronize: true)
    }

    private func flushPeriodically() {
        periodicFlushScheduled = false
        try? writePendingBatch(synchronize: false)
    }

    private func writePendingBatch(synchronize: Bool) throws {
        guard !pendingRecords.isEmpty else {
            if synchronize {
                try fileHandle?.synchronize()
            }
            return
        }
        var payload = Data()
        for record in pendingRecords {
            var data = try encoder.encode(record)
            data.append(0x0A)
            payload.append(data)
        }
        let handle = try writableHandle()
        try handle.write(contentsOf: payload)
        if synchronize {
            try handle.synchronize()
        }
        pendingRecords.removeAll(keepingCapacity: true)
    }

    private func writableHandle() throws -> FileHandle {
        if let fileHandle { return fileHandle }
        let manager = FileManager.default
        try manager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: logURL.path) {
            guard manager.createFile(atPath: logURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        fileHandle = handle
        return handle
    }
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
    private var gpuDurationNanoseconds: [UInt64] = []
    private var gpuCompletionNanoseconds: [UInt64] = []

    @discardableResult
    func recordPresentedFrame(
        at timestamp: TimeInterval,
        targetFramesPerSecond: Int
    ) -> Bool {
        guard timestamp.isFinite, targetFramesPerSecond > 0 else {
            return false
        }

        if currentTargetFramesPerSecond != targetFramesPerSecond {
            resetSamples(targetFramesPerSecond: targetFramesPerSecond)
        }

        defer { lastFrameTimestamp = timestamp }
        guard let lastFrameTimestamp else {
            lastPublicationTimestamp = timestamp
            return false
        }

        let interval = timestamp - lastFrameTimestamp
        guard interval > 0 else { return false }
        guard interval < Self.suspensionInterval else {
            resetSamples(targetFramesPerSecond: targetFramesPerSecond)
            lastPublicationTimestamp = timestamp
            return false
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
            return true
        }
        return false
    }

    func reset() {
        snapshot = DebugPerformanceSnapshot()
        intervalsMilliseconds.removeAll(keepingCapacity: true)
        lastFrameTimestamp = nil
        lastPublicationTimestamp = nil
        currentTargetFramesPerSecond = 0
        cpuPreparationNanoseconds.removeAll(keepingCapacity: true)
        eventToSubmitNanoseconds.removeAll(keepingCapacity: true)
        gpuDurationNanoseconds.removeAll(keepingCapacity: true)
        gpuCompletionNanoseconds.removeAll(keepingCapacity: true)
    }

    func recordDepositionSample(
        authoritativeBacklog: Int,
        predictedBacklog: Int,
        authoritativeHighWater: Int,
        predictedHighWater: Int,
        backlogHighWater: Int,
        encodedDabs: UInt64,
        encodedInstances: UInt64,
        currentBufferLeaseCount: Int,
        strokeBufferLeaseHighWater: Int,
        lifetimeBufferLeaseHighWater: Int,
        cpuPreparationNanoseconds: UInt64,
        eventToSubmitNanoseconds: UInt64,
        gpuDurationNanoseconds: UInt64,
        gpuCompletionNanoseconds: UInt64,
        missedFrames: UInt64
    ) {
        guard authoritativeBacklog >= 0,
              predictedBacklog >= 0,
              authoritativeHighWater >= 0,
              predictedHighWater >= 0,
              backlogHighWater >= 0,
              currentBufferLeaseCount >= 0,
              strokeBufferLeaseHighWater >= 0,
              lifetimeBufferLeaseHighWater >= 0
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
            gpuDurationNanoseconds,
            to: &self.gpuDurationNanoseconds
        )
        appendBounded(
            gpuCompletionNanoseconds,
            to: &self.gpuCompletionNanoseconds
        )
        var deposition = snapshot.deposition
        deposition.authoritativeBacklog = authoritativeBacklog
        deposition.predictedBacklog = predictedBacklog
        deposition.authoritativeHighWater = authoritativeHighWater
        deposition.predictedHighWater = predictedHighWater
        deposition.backlogHighWater = backlogHighWater
        deposition.encodedDabCount = saturatingAdd(
            deposition.encodedDabCount,
            encodedDabs
        )
        deposition.encodedInstanceCount = saturatingAdd(
            deposition.encodedInstanceCount,
            encodedInstances
        )
        deposition.currentBufferLeaseCount = currentBufferLeaseCount
        deposition.strokeBufferLeaseHighWater =
            strokeBufferLeaseHighWater
        deposition.lifetimeBufferLeaseHighWater =
            lifetimeBufferLeaseHighWater
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
        deposition.gpuDuration = percentiles(
            self.gpuDurationNanoseconds
        )
        deposition.gpuCompletion = percentiles(
            self.gpuCompletionNanoseconds
        )
        snapshot.deposition = deposition
    }

    func recordRendererFrame(
        _ metrics: GPUFrameMetrics,
        deposition renderer: BrushLabRendererDepositionDiagnosticSnapshot
    ) {
        let gpuDurationNanoseconds = metrics.gpuMilliseconds.isFinite
            ? UInt64(max(0, metrics.gpuMilliseconds) * 1_000_000)
            : 0
        appendBounded(
            gpuDurationNanoseconds,
            to: &self.gpuDurationNanoseconds
        )
        var deposition = snapshot.deposition
        deposition.authoritativeBacklog = renderer.authoritativePending
        deposition.predictedBacklog = renderer.predictedPending
        deposition.authoritativeHighWater = renderer.authoritativeHighWater
        deposition.predictedHighWater = renderer.predictedHighWater
        deposition.backlogHighWater = renderer.backlogHighWater
        deposition.encodedDabCount = renderer.strokeEncodedDabCount
        deposition.encodedInstanceCount = renderer.strokeEncodedInstanceCount
        deposition.currentBufferLeaseCount = renderer.currentBufferLeaseCount
        deposition.strokeBufferLeaseHighWater =
            renderer.strokeBufferLeaseHighWater
        deposition.lifetimeBufferLeaseHighWater =
            renderer.lifetimeBufferLeaseHighWater
        deposition.missedFrameCount = renderer.missedFrameCount
        deposition.cpuPreparation = .init(renderer.cpuPreparation)
        deposition.eventToSubmit = .init(renderer.eventToSubmit)
        deposition.gpuDuration = percentiles(
            self.gpuDurationNanoseconds
        )
        deposition.gpuCompletion = .init(renderer.gpuCompletion)
        snapshot.deposition = deposition
    }

    func recordStrokeRuntimeSnapshot(
        _ runtime: StrokeRuntimeTelemetrySnapshot
    ) {
        var deposition = snapshot.deposition
        deposition.authoritativeBacklog = runtime.authoritativeQueueDepth
        deposition.predictedBacklog = runtime.predictedQueueDepth
        deposition.authoritativeHighWater =
            runtime.authoritativeQueueHighWater
        deposition.predictedHighWater = runtime.predictedQueueHighWater
        deposition.backlogHighWater = max(
            runtime.authoritativeQueueHighWater,
            runtime.predictedQueueHighWater
        )
        deposition.encodedDabCount = runtime.newLogicalDabCount
        deposition.encodedInstanceCount = runtime.newProjectedDabCount
        deposition.missedFrameCount = runtime.missedFrameCount
        deposition.cpuPreparation = .init(runtime.prepare)
        deposition.eventToSubmit = .init(runtime.eventToSubmit)
        deposition.gpuDuration = .init(runtime.gpu)
        snapshot.deposition = deposition
        snapshot.strokeRuntime = runtime
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
