import Foundation
@testable import MetalRenderer
import Testing

@Test
func acceptanceConfigurationRequiresAnAbsoluteLogPath() {
    #expect(
        InteractiveBrushAcceptanceConfiguration(
            environment: [:]
        ).logURL == nil
    )
    #expect(
        InteractiveBrushAcceptanceConfiguration(environment: [
            "INTERACTIVE_BRUSH_ACCEPTANCE_LOG": "relative/trace.jsonl",
        ]).logURL == nil
    )
    #expect(
        InteractiveBrushAcceptanceConfiguration(environment: [
            "INTERACTIVE_BRUSH_ACCEPTANCE_LOG": "/tmp/trace.jsonl",
        ]).logURL?.path == "/tmp/trace.jsonl"
    )
}

@Test
func activeLoggerFlushesJSONLAndEmitsOneHeartbeatPerElapsedSecond() async throws {
    let logURL = try interactiveBrushTemporaryLogURL()
    defer { try? FileManager.default.removeItem(at: logURL) }
    let clock = ManualInteractiveBrushTraceClock(nowNanoseconds: 20)
    let logger = try InteractiveBrushTraceLogger(
        logURL: logURL,
        writerCapacity: 8,
        clock: clock
    )
    logger.record(interactiveBrushTestRecord(
        stage: .eventReceived,
        monotonicNanoseconds: 20
    ))
    await logger.flush()

    let activeRecords = try interactiveBrushReadRecords(at: logURL)
    #expect(activeRecords.map(\.stage) == [.eventReceived])

    clock.advance(byNanoseconds: 3_000_000_000)
    await Task.yield()
    await logger.flush()
    let records = try interactiveBrushReadRecords(at: logURL)
    #expect(records.map(\.stage) == [
        .eventReceived, .progress, .progress, .progress,
    ])
    #expect(records.dropFirst().map(\.monotonicNanoseconds) == [
        1_000_000_020, 2_000_000_020, 3_000_000_020,
    ])
    try await logger.finish()
}

@Test
func writerQueueOverflowRecordsTerminalFailureAndMakesFinishThrow() async throws {
    let logURL = try interactiveBrushTemporaryLogURL()
    defer { try? FileManager.default.removeItem(at: logURL) }
    let logger = try InteractiveBrushTraceLogger(
        logURL: logURL,
        writerCapacity: 0,
        clock: ManualInteractiveBrushTraceClock(nowNanoseconds: 40)
    )
    logger.record(interactiveBrushTestRecord(
        stage: .eventReceived,
        monotonicNanoseconds: 40
    ))
    do {
        try await logger.finish()
        Issue.record("Expected writer queue overflow")
    } catch let error as InteractiveBrushTraceLoggerError {
        #expect(error == .writerQueueOverflow)
    }
    let records = try interactiveBrushReadRecords(at: logURL)
    #expect(records.last?.stage == .failure)
    #expect(records.last?.message == "writer queue overflow")
}

private func interactiveBrushTestRecord(
    stage: InteractiveBrushTraceStage,
    monotonicNanoseconds: UInt64
) -> InteractiveBrushTraceRecord {
    InteractiveBrushTraceRecord(
        stage: stage,
        monotonicNanoseconds: monotonicNanoseconds
    )
}

private func interactiveBrushTemporaryLogURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("jsonl")
    return url
}

private func interactiveBrushReadRecords(
    at url: URL
) throws -> [InteractiveBrushTraceRecord] {
    let data = try Data(contentsOf: url)
    return try data.split(separator: 0x0A).map {
        try JSONDecoder().decode(
            InteractiveBrushTraceRecord.self,
            from: Data($0)
        )
    }
}

private final class ManualInteractiveBrushTraceClock:
    InteractiveBrushTraceClock,
    @unchecked Sendable
{
    private struct State {
        var nowNanoseconds: UInt64
        var sleepers: [UUID: (UInt64, CheckedContinuation<Void, Error>)] = [:]
    }

    private let state: NSLock
    private var clockState: State

    init(nowNanoseconds: UInt64) {
        state = NSLock()
        clockState = State(nowNanoseconds: nowNanoseconds)
    }

    func nowNanoseconds() -> UInt64 {
        state.withLock { clockState.nowNanoseconds }
    }

    func sleep(untilNanoseconds deadline: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumesImmediately = state.withLock {
                    if clockState.nowNanoseconds >= deadline {
                        return true
                    }
                    clockState.sleepers[id] = (deadline, continuation)
                    return false
                }
                if resumesImmediately { continuation.resume() }
            }
        } onCancel: {
            let continuation = state.withLock {
                clockState.sleepers.removeValue(forKey: id)?.1
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(byNanoseconds amount: UInt64) {
        let continuations = state.withLock {
            clockState.nowNanoseconds += amount
            let ready = clockState.sleepers.filter {
                $0.value.0 <= clockState.nowNanoseconds
            }
            for id in ready.keys {
                clockState.sleepers.removeValue(forKey: id)
            }
            return ready.values.map(\.1)
        }
        for continuation in continuations { continuation.resume() }
    }
}
