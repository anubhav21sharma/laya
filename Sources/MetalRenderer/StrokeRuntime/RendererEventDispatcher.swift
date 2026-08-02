import Foundation
import PatternEngine

enum RendererEvent: Sendable {
    case error(MetalRendererError)
    case idleStateChanged(Bool)
    case operationCompleted(RendererOperationCompletion)
    case logicalDab(generation: UInt64, dab: LogicalDab)
    case strokeRuntimeSnapshot(
        generation: UInt64,
        snapshot: StrokeRuntimeTelemetrySnapshot
    )
    case strokeRuntimeSegmentMarker(
        generation: UInt64,
        marker: StrokeRuntimeSegmentMarker
    )
    #if DEBUG
    case interactiveFramePresented(TimeInterval, Int)
    case interactiveFrameMetrics(GPUFrameMetrics)
    #endif
}

@MainActor
final class RendererEventDispatcher {
    static let deliveryBudgetPerTurn = 256

    struct Diagnostics: Equatable {
        let pendingEventCount: Int
        let pendingHighWater: Int
        let maximumCallbackDepth: Int
        let scheduledContinuationCount: UInt64
        let coalescedRuntimeSnapshotCount: UInt64
        let coalescedDebugFrameEventCount: UInt64
        let staleGenerationDiscardCount: UInt64
        let checkpointEventVisitCount: UInt64
        let retainedConsumedSlotCount: Int
    }

    private struct StagedEvent {
        let event: RendererEvent
        var isCommitted: Bool
    }

    private struct OperationFrame {
        var events: [StagedEvent] = []
        var checkpointedEventCount = 0
    }

    private struct LogicalDabCursor {
        let generation: UInt64
        var remainingCount: Int
    }

    private enum PendingEntry {
        case event(RendererEvent)
        case logicalDabs(LogicalDabCursor)
    }

    private struct PendingNode {
        var entry: PendingEntry?
        var previous: Int?
        var next: Int?
        var nextFree: Int?
    }

    private struct LogicalDabRing {
        private var storage: [LogicalDab?] = []
        private var head = 0
        private(set) var count = 0
        private(set) var retainedConsumedSlotCount = 0

        mutating func append(_ dab: LogicalDab) {
            ensureCapacity(for: count + 1)
            let index = (head + count) % storage.count
            precondition(storage[index] == nil)
            storage[index] = dab
            count += 1
        }

        mutating func popFirst() -> LogicalDab {
            precondition(count > 0)
            guard let dab = storage[head] else {
                preconditionFailure(
                    "Renderer logical-dab ring lost a live payload"
                )
            }
            storage[head] = nil
            // Audit the slot itself: the diagnostic must expose a future
            // regression that leaves the consumed payload resident.
            if storage[head] != nil {
                let (next, overflow) = retainedConsumedSlotCount
                    .addingReportingOverflow(1)
                retainedConsumedSlotCount = overflow ? .max : next
            }
            head = (head + 1) % storage.count
            count -= 1
            if count == 0 {
                head = 0
            }
            return dab
        }

        private mutating func ensureCapacity(for requiredCount: Int) {
            guard requiredCount > storage.count else { return }
            let doubled = storage.count.multipliedReportingOverflow(by: 2)
            let growth = doubled.overflow ? Int.max : doubled.partialValue
            let newCapacity = max(16, max(requiredCount, growth))
            var expanded = [LogicalDab?](
                repeating: nil,
                count: newCapacity
            )
            if !storage.isEmpty {
                for offset in 0..<count {
                    expanded[offset] = storage[(head + offset) % storage.count]
                }
            }
            storage = expanded
            head = 0
        }
    }

    private enum DequeuedUnit {
        case event(RendererEvent)
        case staleGenerationDiscard
    }

    private let deliver: @MainActor (RendererEvent) -> Void
    private var operationFrameStorage: [OperationFrame] = []
    private var operationDepth = 0
    private var pendingNodes: [PendingNode] = []
    private var pendingHeadNode: Int?
    private var pendingTailNode: Int?
    private var pendingFreeNode: Int?
    private var pendingLogicalDabs = LogicalDabRing()
    private var retainedConsumedNodePayloadCount = 0
    private var pendingRuntimeSnapshotNodes: [UInt64: Int] = [:]
    #if DEBUG
    private var pendingInteractivePresentationNode: Int?
    private var pendingInteractiveMetricsNode: Int?
    #endif
    private var pendingCallbackCount = 0
    private var pendingHighWater = 0
    private var callbackDepth = 0
    private var maximumCallbackDepth = 0
    private var drainContinuationScheduled = false
    private var isDraining = false
    private var scheduledContinuationCount: UInt64 = 0
    private var coalescedRuntimeSnapshotCount: UInt64 = 0
    private var coalescedDebugFrameEventCount: UInt64 = 0
    private var staleGenerationDiscardCount: UInt64 = 0
    private var checkpointEventVisitCount: UInt64 = 0
    private var activeStrokeGeneration: UInt64?
    private var activeTelemetryGeneration: UInt64?
    private var nextStrokeGeneration: UInt64 = 0
    private var nextTelemetryGeneration: UInt64 = 0

    init(deliver: @escaping @MainActor (RendererEvent) -> Void) {
        self.deliver = deliver
    }

    var diagnostics: Diagnostics {
        Diagnostics(
            pendingEventCount: pendingCallbackCount,
            pendingHighWater: pendingHighWater,
            maximumCallbackDepth: maximumCallbackDepth,
            scheduledContinuationCount: scheduledContinuationCount,
            coalescedRuntimeSnapshotCount:
                coalescedRuntimeSnapshotCount,
            coalescedDebugFrameEventCount:
                coalescedDebugFrameEventCount,
            staleGenerationDiscardCount: staleGenerationDiscardCount,
            checkpointEventVisitCount: checkpointEventVisitCount,
            retainedConsumedSlotCount: retainedConsumedSlotCount
        )
    }

    var hasOpenOperation: Bool {
        operationDepth > 0
    }

    #if DEBUG
    /// Delivers one additional bounded turn while preserving the already
    /// scheduled production continuation. Tests use this causal boundary to
    /// change observers between turns without scheduler-count polling.
    func drainOnePendingTurnForHarness() {
        guard operationDepth == 0,
              !isDraining,
              pendingCallbackCount > 0
        else {
            return
        }
        drainTurn()
    }
    #endif

    func beginOperation() {
        if operationDepth == operationFrameStorage.count {
            operationFrameStorage.append(OperationFrame())
        } else {
            operationFrameStorage[operationDepth].events.removeAll(
                keepingCapacity: true
            )
            operationFrameStorage[operationDepth]
                .checkpointedEventCount = 0
        }
        operationDepth += 1
    }

    func stage(_ event: RendererEvent) {
        precondition(
            operationDepth > 0,
            "Renderer events must be staged inside an operation"
        )
        operationFrameStorage[operationDepth - 1].events.append(
            StagedEvent(event: event, isCommitted: false)
        )
    }

    func commitCheckpoint() {
        precondition(
            operationDepth > 0,
            "Renderer event checkpoint requires an open operation"
        )
        let frameIndex = operationDepth - 1
        let checkpointStart = operationFrameStorage[frameIndex]
            .checkpointedEventCount
        let checkpointEnd = operationFrameStorage[frameIndex].events.endIndex
        for eventIndex in checkpointStart..<checkpointEnd {
            operationFrameStorage[frameIndex].events[eventIndex]
                .isCommitted = true
        }
        operationFrameStorage[frameIndex].checkpointedEventCount = checkpointEnd
        checkpointEventVisitCount = Self.saturatingAdd(
            checkpointEventVisitCount,
            UInt64(checkpointEnd - checkpointStart)
        )
    }

    func endOperation(succeeded: Bool) {
        precondition(
            operationDepth > 0,
            "Renderer event operation was not open"
        )
        let frameIndex = operationDepth - 1
        if succeeded {
            for index in operationFrameStorage[frameIndex].events.indices {
                operationFrameStorage[frameIndex].events[index]
                    .isCommitted = true
            }
        }
        operationDepth -= 1
        if operationDepth > 0 {
            let parentIndex = operationDepth - 1
            for index in operationFrameStorage[frameIndex].events.indices {
                let staged = operationFrameStorage[frameIndex].events[index]
                if staged.isCommitted {
                    operationFrameStorage[parentIndex].events.append(
                        StagedEvent(
                            event: staged.event,
                            isCommitted: true
                        )
                    )
                }
            }
            operationFrameStorage[frameIndex].events.removeAll(
                keepingCapacity: true
            )
            operationFrameStorage[frameIndex].checkpointedEventCount = 0
            return
        }
        for index in operationFrameStorage[frameIndex].events.indices {
            let staged = operationFrameStorage[frameIndex].events[index]
            if staged.isCommitted {
                enqueueCommitted(staged.event)
            }
        }
        operationFrameStorage[frameIndex].events.removeAll(
            keepingCapacity: true
        )
        operationFrameStorage[frameIndex].checkpointedEventCount = 0
        requestDrain()
    }

    func advanceStrokeGeneration() -> UInt64 {
        nextStrokeGeneration = Self.nextNonzeroGeneration(
            after: nextStrokeGeneration
        )
        activeStrokeGeneration = nextStrokeGeneration
        return nextStrokeGeneration
    }

    func advanceTelemetryGeneration() -> UInt64 {
        nextTelemetryGeneration = Self.nextNonzeroGeneration(
            after: nextTelemetryGeneration
        )
        activeTelemetryGeneration = nextTelemetryGeneration
        return nextTelemetryGeneration
    }

    func invalidateStrokeGeneration(_ generation: UInt64) {
        if activeStrokeGeneration == generation {
            activeStrokeGeneration = nil
        }
    }

    func invalidateTelemetryGeneration(_ generation: UInt64) {
        if activeTelemetryGeneration == generation {
            activeTelemetryGeneration = nil
        }
    }

    private var retainedConsumedSlotCount: Int {
        let (total, overflow) = retainedConsumedNodePayloadCount
            .addingReportingOverflow(
                pendingLogicalDabs.retainedConsumedSlotCount
            )
        return overflow ? .max : total
    }

    private func enqueueCommitted(_ event: RendererEvent) {
        switch event {
        case let .logicalDab(generation, dab):
            enqueueLogicalDab(dab, generation: generation)
        case let .strokeRuntimeSnapshot(generation, _):
            if let existing = pendingRuntimeSnapshotNodes.removeValue(
                forKey: generation
            ) {
                _ = removePendingNode(at: existing)
                pendingCallbackCount -= 1
                coalescedRuntimeSnapshotCount = Self.saturatingIncrement(
                    coalescedRuntimeSnapshotCount
                )
            }
            let index = appendPending(.event(event), callbackCount: 1)
            pendingRuntimeSnapshotNodes[generation] = index
        #if DEBUG
        case .interactiveFramePresented:
            if let existing = pendingInteractivePresentationNode {
                pendingInteractivePresentationNode = nil
                _ = removePendingNode(at: existing)
                pendingCallbackCount -= 1
                coalescedDebugFrameEventCount = Self.saturatingIncrement(
                    coalescedDebugFrameEventCount
                )
            }
            pendingInteractivePresentationNode = appendPending(
                .event(event),
                callbackCount: 1
            )
        case .interactiveFrameMetrics:
            if let existing = pendingInteractiveMetricsNode {
                pendingInteractiveMetricsNode = nil
                _ = removePendingNode(at: existing)
                pendingCallbackCount -= 1
                coalescedDebugFrameEventCount = Self.saturatingIncrement(
                    coalescedDebugFrameEventCount
                )
            }
            pendingInteractiveMetricsNode = appendPending(
                .event(event),
                callbackCount: 1
            )
        #endif
        default:
            _ = appendPending(.event(event), callbackCount: 1)
        }
    }

    private func enqueueLogicalDab(
        _ dab: LogicalDab,
        generation: UInt64
    ) {
        if let tailIndex = pendingTailNode,
           case var .logicalDabs(cursor)? = pendingNodes[tailIndex].entry,
           cursor.generation == generation
        {
            let (nextCount, overflow) = cursor.remainingCount
                .addingReportingOverflow(1)
            precondition(!overflow, "Renderer logical-dab count overflowed")
            pendingLogicalDabs.append(dab)
            cursor.remainingCount = nextCount
            pendingNodes[tailIndex].entry = .logicalDabs(cursor)
            incrementPendingCallbackCount(by: 1)
            return
        }
        pendingLogicalDabs.append(dab)
        _ = appendPending(
            .logicalDabs(
                LogicalDabCursor(
                    generation: generation,
                    remainingCount: 1
                )
            ),
            callbackCount: 1
        )
    }

    @discardableResult
    private func appendPending(
        _ entry: PendingEntry,
        callbackCount: Int
    ) -> Int {
        let index = allocatePendingNode(for: entry)
        incrementPendingCallbackCount(by: callbackCount)
        return index
    }

    private func allocatePendingNode(for entry: PendingEntry) -> Int {
        let index: Int
        if let freeIndex = pendingFreeNode {
            index = freeIndex
            pendingFreeNode = pendingNodes[freeIndex].nextFree
            if pendingNodes[freeIndex].entry != nil {
                precondition(retainedConsumedNodePayloadCount > 0)
                retainedConsumedNodePayloadCount -= 1
            }
            pendingNodes[freeIndex] = PendingNode(
                entry: entry,
                previous: pendingTailNode,
                next: nil,
                nextFree: nil
            )
        } else {
            index = pendingNodes.count
            pendingNodes.append(
                PendingNode(
                    entry: entry,
                    previous: pendingTailNode,
                    next: nil,
                    nextFree: nil
                )
            )
        }
        if let tail = pendingTailNode {
            pendingNodes[tail].next = index
        } else {
            pendingHeadNode = index
        }
        pendingTailNode = index
        return index
    }

    @discardableResult
    private func removePendingNode(at index: Int) -> PendingEntry {
        guard let entry = pendingNodes[index].entry else {
            preconditionFailure("Renderer event queue removed a free node")
        }
        let previous = pendingNodes[index].previous
        let next = pendingNodes[index].next
        if let previous {
            pendingNodes[previous].next = next
        } else {
            pendingHeadNode = next
        }
        if let next {
            pendingNodes[next].previous = previous
        } else {
            pendingTailNode = previous
        }
        pendingNodes[index].entry = nil
        // Audit the free node itself instead of assuming removal released its
        // payload; tests mutation-check this readback path.
        if pendingNodes[index].entry != nil {
            let (next, overflow) = retainedConsumedNodePayloadCount
                .addingReportingOverflow(1)
            retainedConsumedNodePayloadCount = overflow ? .max : next
        }
        pendingNodes[index].previous = nil
        pendingNodes[index].next = nil
        pendingNodes[index].nextFree = pendingFreeNode
        pendingFreeNode = index
        return entry
    }

    private func incrementPendingCallbackCount(by count: Int) {
        let (next, overflow) = pendingCallbackCount.addingReportingOverflow(
            count
        )
        precondition(!overflow, "Renderer event pending count overflowed")
        pendingCallbackCount = next
        pendingHighWater = max(pendingHighWater, pendingCallbackCount)
    }

    private func requestDrain() {
        guard operationDepth == 0,
              !isDraining,
              !drainContinuationScheduled,
              pendingCallbackCount > 0
        else {
            return
        }
        drainTurn()
    }

    private func drainTurn() {
        precondition(operationDepth == 0)
        precondition(!isDraining)
        isDraining = true
        var consumedWorkCount = 0
        while consumedWorkCount < Self.deliveryBudgetPerTurn,
              pendingCallbackCount > 0
        {
            guard let unit = dequeueNextUnit() else { break }
            consumedWorkCount += 1
            guard case let .event(event) = unit else {
                staleGenerationDiscardCount = Self.saturatingIncrement(
                    staleGenerationDiscardCount
                )
                continue
            }
            guard isLive(event) else {
                staleGenerationDiscardCount = Self.saturatingIncrement(
                    staleGenerationDiscardCount
                )
                continue
            }
            callbackDepth += 1
            maximumCallbackDepth = max(
                maximumCallbackDepth,
                callbackDepth
            )
            deliver(event)
            callbackDepth -= 1
        }
        isDraining = false
        if pendingCallbackCount > 0 {
            scheduleDrainContinuation()
        }
    }

    private func dequeueNextUnit() -> DequeuedUnit? {
        guard let headIndex = pendingHeadNode else {
            precondition(
                pendingCallbackCount == 0 && pendingLogicalDabs.count == 0,
                "Renderer event queue lost pending entries"
            )
            return nil
        }
        guard let entry = pendingNodes[headIndex].entry else {
            preconditionFailure("Renderer event queue linked a free node")
        }
        switch entry {
        case let .event(event):
            _ = removePendingNode(at: headIndex)
            clearCoalescingHandle(for: event, nodeIndex: headIndex)
            pendingCallbackCount -= 1
            return .event(event)
        case var .logicalDabs(cursor):
            precondition(cursor.remainingCount > 0)
            let dab = pendingLogicalDabs.popFirst()
            cursor.remainingCount -= 1
            pendingCallbackCount -= 1
            if cursor.remainingCount == 0 {
                _ = removePendingNode(at: headIndex)
            } else {
                pendingNodes[headIndex].entry = .logicalDabs(cursor)
            }
            guard cursor.generation == activeStrokeGeneration else {
                return .staleGenerationDiscard
            }
            return .event(
                .logicalDab(
                    generation: cursor.generation,
                    dab: dab
                )
            )
        }
    }

    private func clearCoalescingHandle(
        for event: RendererEvent,
        nodeIndex: Int
    ) {
        switch event {
        case let .strokeRuntimeSnapshot(generation, _):
            if pendingRuntimeSnapshotNodes[generation] == nodeIndex {
                pendingRuntimeSnapshotNodes.removeValue(forKey: generation)
            }
        #if DEBUG
        case .interactiveFramePresented:
            if pendingInteractivePresentationNode == nodeIndex {
                pendingInteractivePresentationNode = nil
            }
        case .interactiveFrameMetrics:
            if pendingInteractiveMetricsNode == nodeIndex {
                pendingInteractiveMetricsNode = nil
            }
        #endif
        default:
            break
        }
    }

    private func isLive(_ event: RendererEvent) -> Bool {
        switch event {
        case let .logicalDab(generation, _):
            generation == activeStrokeGeneration
        case let .strokeRuntimeSnapshot(generation, _),
             let .strokeRuntimeSegmentMarker(generation, _):
            generation == activeTelemetryGeneration
        default:
            true
        }
    }

    private func scheduleDrainContinuation() {
        guard !drainContinuationScheduled else { return }
        drainContinuationScheduled = true
        scheduledContinuationCount = Self.saturatingIncrement(
            scheduledContinuationCount
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            drainContinuationScheduled = false
            guard operationDepth == 0,
                  !isDraining,
                  pendingCallbackCount > 0
            else {
                return
            }
            drainTurn()
        }
    }

    private static func nextNonzeroGeneration(after value: UInt64) -> UInt64 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        saturatingAdd(value, 1)
    }

    private static func saturatingAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
