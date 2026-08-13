import Foundation
import MetalRenderer

protocol InteractiveBrushTraceClock: Sendable {
    func nowNanoseconds() -> UInt64
    func sleep(untilNanoseconds deadline: UInt64) async throws
}

struct ContinuousInteractiveBrushTraceClock:
    InteractiveBrushTraceClock,
    Sendable
{
    func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func sleep(untilNanoseconds deadline: UInt64) async throws {
        let now = nowNanoseconds()
        guard deadline > now else { return }
        try await Task.sleep(nanoseconds: deadline - now)
    }
}

enum InteractiveBrushTraceLoggerError: Error, Equatable, Sendable {
    case writerQueueOverflow
    case writerFailed(String)
}

final class InteractiveBrushTraceLogger:
    InteractiveBrushTraceSink,
    @unchecked Sendable
{
    private struct State {
        var acceptsRecords = true
        var pendingRecordCount = 0
        var terminalError: InteractiveBrushTraceLoggerError?
        var failureRecordWasScheduled = false
        var nextHeartbeatNanoseconds: UInt64 = 0
    }

    private let writerCapacity: Int
    private let clock: any InteractiveBrushTraceClock
    private let recordAdmissionHook: (@Sendable () -> Void)?
    private let fileHandle: FileHandle
    private let writerQueue = DispatchQueue(
        label: "app.laya.interactive-brush-trace-writer"
    )
    private let stateLock = NSLock()
    private let heartbeatEmissionLock = NSLock()
    private let admittedEnqueues = DispatchGroup()
    private var state = State()
    private var heartbeatTask: Task<Void, Never>?

    init(
        logURL: URL,
        writerCapacity: Int = 256,
        clock: any InteractiveBrushTraceClock =
            ContinuousInteractiveBrushTraceClock(),
        recordAdmissionHook: (@Sendable () -> Void)? = nil
    ) throws {
        precondition(writerCapacity >= 0)
        self.writerCapacity = writerCapacity
        self.clock = clock
        self.recordAdmissionHook = recordAdmissionHook
        let directory = logURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(
            atPath: logURL.path,
            contents: nil
        )
        fileHandle = try FileHandle(forWritingTo: logURL)
        let firstHeartbeat = clock.nowNanoseconds() + 1_000_000_000
        state.nextHeartbeatNanoseconds = firstHeartbeat
        heartbeatTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                guard let self else { return }
                let deadline = self.stateLock.withLock {
                    self.state.nextHeartbeatNanoseconds
                }
                do {
                    try await clock.sleep(untilNanoseconds: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.emitElapsedHeartbeats()
            }
        }
    }

    func record(_ record: InteractiveBrushTraceRecord) {
        enum Admission {
            case rejected
            case record
            case overflowFailure
        }
        let admission: Admission = stateLock.withLock {
            guard state.acceptsRecords else { return .rejected }
            guard state.pendingRecordCount < writerCapacity else {
                state.acceptsRecords = false
                state.terminalError = .writerQueueOverflow
                guard !state.failureRecordWasScheduled else {
                    return .rejected
                }
                state.failureRecordWasScheduled = true
                admittedEnqueues.enter()
                return .overflowFailure
            }
            state.pendingRecordCount += 1
            admittedEnqueues.enter()
            return .record
        }
        if case .record = admission {
            recordAdmissionHook?()
        } else if case .overflowFailure = admission {
            recordAdmissionHook?()
        }
        switch admission {
        case .rejected:
            return
        case .record:
            enqueueWrite(record, decrementsPendingCount: true)
            admittedEnqueues.leave()
        case .overflowFailure:
            enqueueWrite(
                InteractiveBrushTraceRecord(
                    stage: .failure,
                    monotonicNanoseconds: clock.nowNanoseconds(),
                    message: "writer queue overflow"
                ),
                decrementsPendingCount: false
            )
            admittedEnqueues.leave()
        }
    }

    func flush() async {
        emitElapsedHeartbeats()
        await drainWriter()
    }

    func finish() async throws {
        emitElapsedHeartbeats()
        stateLock.withLock { state.acceptsRecords = false }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await drainAdmittedWrites()
        try? fileHandle.close()
        if let error = stateLock.withLock({ state.terminalError }) {
            throw error
        }
    }

    deinit {
        heartbeatTask?.cancel()
        try? fileHandle.close()
    }

    private func drainWriter() async {
        await withCheckedContinuation { continuation in
            writerQueue.async { continuation.resume() }
        }
    }

    private func drainAdmittedWrites() async {
        await withCheckedContinuation { continuation in
            admittedEnqueues.notify(queue: writerQueue) {
                continuation.resume()
            }
        }
    }

    private func enqueueWrite(
        _ record: InteractiveBrushTraceRecord,
        decrementsPendingCount: Bool
    ) {
        writerQueue.async { [self] in
            defer {
                if decrementsPendingCount {
                    stateLock.withLock { state.pendingRecordCount -= 1 }
                }
            }
            do {
                var data = try JSONEncoder().encode(record)
                data.append(0x0A)
                try fileHandle.write(contentsOf: data)
                try fileHandle.synchronize()
            } catch {
                stateLock.withLock {
                    state.acceptsRecords = false
                    if state.terminalError == nil {
                        state.terminalError = .writerFailed(
                            error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    private func emitElapsedHeartbeats() {
        heartbeatEmissionLock.withLock {
            let now = clock.nowNanoseconds()
            let deadlines: [UInt64] = stateLock.withLock {
                guard state.acceptsRecords else { return [] }
                var deadlines: [UInt64] = []
                while state.nextHeartbeatNanoseconds <= now {
                    deadlines.append(state.nextHeartbeatNanoseconds)
                    let (next, overflow) = state.nextHeartbeatNanoseconds
                        .addingReportingOverflow(1_000_000_000)
                    if overflow {
                        state.nextHeartbeatNanoseconds = .max
                        break
                    }
                    state.nextHeartbeatNanoseconds = next
                }
                return deadlines
            }
            for deadline in deadlines {
                record(InteractiveBrushTraceRecord(
                    stage: .progress,
                    monotonicNanoseconds: deadline,
                    message: "heartbeat"
                ))
            }
        }
    }
}
