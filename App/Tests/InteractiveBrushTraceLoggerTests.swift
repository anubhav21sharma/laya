import Foundation
import Metal
@testable import MetalRenderer
@testable import PatternEngine
import Testing

#if os(macOS)
import AppKit
#endif

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

@Test
func admittedRecordCannotBeOvertakenByFinish() async throws {
    let logURL = try interactiveBrushTemporaryLogURL()
    defer { try? FileManager.default.removeItem(at: logURL) }
    let gate = InteractiveBrushTraceBlockingGate()
    let logger = try InteractiveBrushTraceLogger(
        logURL: logURL,
        writerCapacity: 8,
        clock: ManualInteractiveBrushTraceClock(nowNanoseconds: 50),
        recordAdmissionHook: { gate.block() }
    )
    let recordTask = Task.detached {
        logger.record(interactiveBrushTestRecord(
            stage: .eventReceived,
            monotonicNanoseconds: 50
        ))
    }
    gate.waitUntilBlocked()
    let finishTask = Task { try await logger.finish() }
    await Task.yield()
    gate.release()
    await recordTask.value
    try await finishTask.value

    #expect(try interactiveBrushReadRecords(at: logURL).map(\.stage) == [
        .eventReceived,
    ])
}

@Test
func recorderDetachQuiescesCapturedSinkBeforeLoggerFinish() async throws {
    let logURL = try interactiveBrushTemporaryLogURL()
    defer { try? FileManager.default.removeItem(at: logURL) }
    let logger = try InteractiveBrushTraceLogger(
        logURL: logURL,
        writerCapacity: 8,
        clock: ManualInteractiveBrushTraceClock(nowNanoseconds: 60)
    )
    let gate = InteractiveBrushTraceBlockingGate()
    let sink = GatedInteractiveBrushTraceSink(logger: logger, gate: gate)
    let recorder = InteractiveBrushTraceRecorder()
    recorder.configure(sink: sink)
    let identity = StrokeTraceIdentity(
        strokeGeneration: 1,
        authoritativeSequence: 1,
        sampleSequence: 1,
        provenance: .authoritative
    )
    let recordTask = Task.detached {
        recorder.record(
            stage: .eventReceived,
            lineage: InteractiveBrushInputTrace(
                identity: identity,
                eventReceiptMonotonicNanoseconds: 60
            ),
            monotonicNanoseconds: 60
        )
    }
    gate.waitUntilBlocked()
    let detached = LockedFlag()
    let detachTask = Task.detached {
        recorder.configure(sink: nil)
        detached.set()
    }
    await Task.yield()
    #expect(!detached.value)
    gate.release()
    await recordTask.value
    await detachTask.value
    try await logger.finish()

    #expect(try interactiveBrushReadRecords(at: logURL).map(\.stage) == [
        .eventReceived,
    ])
}

#if os(macOS)
@MainActor
@Test
func nativeCanvasAssignsStrokeEventAndSampleSequencesAtReceipt() throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let sink = AppInteractiveBrushTraceTestSink()
    renderer.configureInteractiveBrushTrace(sink: sink)
    let controller = EditorSessionController(renderer: renderer)
    let view = InteractiveMetalView(
        frame: CGRect(x: 0, y: 0, width: 64, height: 64),
        controller: controller,
        renderer: renderer,
        requestEditorFocus: {},
        pointerCancellationGeneration: 0
    )
    view.drawableSize = CGSize(width: 64, height: 64)

    view.mouseDown(with: try #require(interactiveBrushPointerEvent(
        type: .leftMouseDown,
        location: CGPoint(x: 16, y: 16)
    )))
    view.mouseDragged(with: try #require(interactiveBrushPointerEvent(
        type: .leftMouseDragged,
        location: CGPoint(x: 24, y: 16)
    )))
    view.mouseUp(with: try #require(interactiveBrushPointerEvent(
        type: .leftMouseUp,
        location: CGPoint(x: 32, y: 16)
    )))
    view.mouseDown(with: try #require(interactiveBrushPointerEvent(
        type: .leftMouseDown,
        location: CGPoint(x: 40, y: 16)
    )))
    view.mouseUp(with: try #require(interactiveBrushPointerEvent(
        type: .leftMouseUp,
        location: CGPoint(x: 48, y: 16)
    )))

    let identities = sink.records
        .filter { $0.stage == .eventReceived }
        .compactMap(\.identity)
    #expect(identities.count == 5)
    #expect(identities.map(\.strokeGeneration) == [1, 1, 1, 2, 2])
    #expect(identities.map(\.authoritativeSequence) == [1, 2, 3, 1, 2])
    #expect(identities.map(\.sampleSequence) == [1, 2, 3, 1, 2])
    #expect(identities.allSatisfy { $0.provenance == .authoritative })
}
#endif

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

private final class InteractiveBrushTraceBlockingGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func block() {
        entered.signal()
        released.wait()
    }

    func waitUntilBlocked() {
        entered.wait()
    }

    func release() {
        released.signal()
    }
}

private final class GatedInteractiveBrushTraceSink:
    InteractiveBrushTraceSink,
    @unchecked Sendable
{
    private let logger: InteractiveBrushTraceLogger
    private let gate: InteractiveBrushTraceBlockingGate

    init(
        logger: InteractiveBrushTraceLogger,
        gate: InteractiveBrushTraceBlockingGate
    ) {
        self.logger = logger
        self.gate = gate
    }

    func record(_ record: InteractiveBrushTraceRecord) {
        gate.block()
        logger.record(record)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}

private final class AppInteractiveBrushTraceTestSink:
    InteractiveBrushTraceSink,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [InteractiveBrushTraceRecord] = []

    var records: [InteractiveBrushTraceRecord] {
        lock.withLock { storage }
    }

    func record(_ record: InteractiveBrushTraceRecord) {
        lock.withLock { storage.append(record) }
    }
}

#if os(macOS)
private func interactiveBrushPointerEvent(
    type: NSEvent.EventType,
    location: CGPoint
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
}
#endif
