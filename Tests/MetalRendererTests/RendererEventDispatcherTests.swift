import Foundation
@testable import MetalRenderer
import PatternEngine
import Testing

@Test
@MainActor
func nestedEventsDrainFIFOWithoutRecursiveDelivery() async {
    var delivered: [UInt64] = []
    var callbackDepth = 0
    var maximumCallbackDepth = 0
    let box = RendererEventDispatcherBox()
    box.dispatcher = RendererEventDispatcher { event in
        guard let value = rendererEventProbeValue(event) else { return }
        callbackDepth += 1
        maximumCallbackDepth = max(maximumCallbackDepth, callbackDepth)
        delivered.append(value)
        if value == 1 {
            box.dispatcher.beginOperation()
            box.dispatcher.stage(rendererEventProbe(3))
            box.dispatcher.endOperation(succeeded: true)
        }
        callbackDepth -= 1
    }

    box.dispatcher.beginOperation()
    box.dispatcher.stage(rendererEventProbe(1))
    box.dispatcher.stage(rendererEventProbe(2))
    box.dispatcher.endOperation(succeeded: true)

    #expect(delivered == [1, 2, 3])
    #expect(maximumCallbackDepth == 1)
    #expect(box.dispatcher.diagnostics.maximumCallbackDepth == 1)
}

@Test
@MainActor
func failedNestedOperationDiscardsOnlyItsUncommittedSuffix() async {
    var delivered: [UInt64] = []
    let dispatcher = RendererEventDispatcher { event in
        if let value = rendererEventProbeValue(event) {
            delivered.append(value)
        }
    }

    dispatcher.beginOperation()
    dispatcher.stage(rendererEventProbe(1))
    dispatcher.commitCheckpoint()
    dispatcher.beginOperation()
    dispatcher.stage(rendererEventProbe(2))
    dispatcher.endOperation(succeeded: false)
    dispatcher.stage(rendererEventProbe(3))
    dispatcher.endOperation(succeeded: true)

    #expect(delivered == [1, 3])
}

@Test
@MainActor
func committedCheckpointSurvivesLaterOperationFailure() async {
    var delivered: [UInt64] = []
    let dispatcher = RendererEventDispatcher { event in
        if let value = rendererEventProbeValue(event) {
            delivered.append(value)
        }
    }

    dispatcher.beginOperation()
    dispatcher.stage(rendererEventProbe(10))
    dispatcher.commitCheckpoint()
    dispatcher.stage(rendererEventProbe(11))
    dispatcher.endOperation(succeeded: false)

    #expect(delivered == [10])
}

@Test
@MainActor
func repeatedCheckpointsVisitEachNewlyStagedEventExactlyOnce() async {
    let eventCount = 1_024
    let dispatcher = RendererEventDispatcher { _ in }

    dispatcher.beginOperation()
    for value in 0..<eventCount {
        dispatcher.stage(rendererEventProbe(UInt64(value)))
        dispatcher.commitCheckpoint()
    }

    #expect(
        dispatcher.diagnostics.checkpointEventVisitCount
            == UInt64(eventCount)
    )
    dispatcher.endOperation(succeeded: false)

    for _ in 0..<10_000 where dispatcher.diagnostics.pendingEventCount > 0 {
        await Task.yield()
    }
    #expect(dispatcher.diagnostics.pendingEventCount == 0)
}

@Test
@MainActor
func advancingGenerationSkipsQueuedStaleEvents() async {
    var timestamps: [UInt64] = []
    let dispatcher = RendererEventDispatcher { event in
        guard case let .strokeRuntimeSegmentMarker(_, marker) = event else {
            return
        }
        timestamps.append(marker.timestampNanoseconds)
    }

    let staleGeneration = dispatcher.advanceTelemetryGeneration()
    dispatcher.beginOperation()
    dispatcher.stage(
        .strokeRuntimeSegmentMarker(
            generation: staleGeneration,
            marker: rendererEventMarker(timestamp: 1)
        )
    )
    let liveGeneration = dispatcher.advanceTelemetryGeneration()
    dispatcher.stage(
        .strokeRuntimeSegmentMarker(
            generation: liveGeneration,
            marker: rendererEventMarker(timestamp: 2)
        )
    )
    dispatcher.endOperation(succeeded: true)

    #expect(timestamps == [2])
    #expect(dispatcher.diagnostics.staleGenerationDiscardCount == 1)
}

@Test
@MainActor
func telemetryCoalescingKeepsNewestValueAndCountsReplacement() async {
    var logicalDabCounts: [UInt64] = []
    let dispatcher = RendererEventDispatcher { event in
        guard case let .strokeRuntimeSnapshot(_, snapshot) = event else {
            return
        }
        logicalDabCounts.append(snapshot.newLogicalDabCount)
    }
    let generation = dispatcher.advanceTelemetryGeneration()

    dispatcher.beginOperation()
    dispatcher.stage(
        .strokeRuntimeSnapshot(
            generation: generation,
            snapshot: rendererEventSnapshot(logicalDabCount: 1)
        )
    )
    dispatcher.stage(
        .strokeRuntimeSnapshot(
            generation: generation,
            snapshot: rendererEventSnapshot(logicalDabCount: 9)
        )
    )
    dispatcher.endOperation(succeeded: true)

    #expect(logicalDabCounts == [9])
    #expect(dispatcher.diagnostics.coalescedRuntimeSnapshotCount == 1)
}

#if DEBUG
@Test
@MainActor
func debugFrameCoalescingDeliversOnlyNewestPresentationAndMetrics() async {
    var presentations: [(timestamp: TimeInterval, count: Int)] = []
    var deliveredMetrics: [GPUFrameMetrics] = []
    let dispatcher = RendererEventDispatcher { event in
        switch event {
        case let .interactiveFramePresented(timestamp, count):
            presentations.append((timestamp, count))
        case let .interactiveFrameMetrics(metrics):
            deliveredMetrics.append(metrics)
        default:
            break
        }
    }
    let oldMetrics = rendererEventFrameMetrics(value: 1)
    let newestMetrics = rendererEventFrameMetrics(value: 2)

    dispatcher.beginOperation()
    dispatcher.stage(.interactiveFramePresented(1, 10))
    dispatcher.stage(.interactiveFrameMetrics(oldMetrics))
    dispatcher.stage(.interactiveFramePresented(2, 20))
    dispatcher.stage(.interactiveFrameMetrics(newestMetrics))
    dispatcher.endOperation(succeeded: true)

    #expect(presentations.count == 1)
    #expect(presentations.first?.timestamp == 2)
    #expect(presentations.first?.count == 20)
    #expect(deliveredMetrics == [newestMetrics])
    #expect(dispatcher.diagnostics.coalescedDebugFrameEventCount == 2)
}
#endif

@Test
@MainActor
func selfFeedingDrainYieldsEvery256CallbacksAndReclaimsConsumedStorage()
    async
{
    let expectedDeliveryCount: UInt64 = 10_000
    var deliveredCount: UInt64 = 0
    var callbackDepth = 0
    var maximumCallbackDepth = 0
    var maximumRetainedConsumedSlots = 0
    let box = RendererEventDispatcherBox()
    box.dispatcher = RendererEventDispatcher { event in
        guard let value = rendererEventProbeValue(event) else { return }
        callbackDepth += 1
        maximumCallbackDepth = max(maximumCallbackDepth, callbackDepth)
        deliveredCount += 1
        maximumRetainedConsumedSlots = max(
            maximumRetainedConsumedSlots,
            box.dispatcher.diagnostics.retainedConsumedSlotCount
        )
        if value < expectedDeliveryCount {
            box.dispatcher.beginOperation()
            box.dispatcher.stage(rendererEventProbe(value + 1))
            box.dispatcher.endOperation(succeeded: true)
        }
        callbackDepth -= 1
    }

    box.dispatcher.beginOperation()
    box.dispatcher.stage(rendererEventProbe(1))
    box.dispatcher.endOperation(succeeded: true)

    #expect(RendererEventDispatcher.deliveryBudgetPerTurn == 256)
    #expect(deliveredCount == 256)
    #expect(box.dispatcher.diagnostics.scheduledContinuationCount == 1)

    for _ in 0..<100_000 where deliveredCount < expectedDeliveryCount {
        await Task.yield()
    }

    #expect(deliveredCount == expectedDeliveryCount)
    #expect(maximumCallbackDepth == 1)
    #expect(box.dispatcher.diagnostics.maximumCallbackDepth == 1)
    #expect(box.dispatcher.diagnostics.scheduledContinuationCount > 1)
    #expect(maximumRetainedConsumedSlots == 0)
    #expect(box.dispatcher.diagnostics.retainedConsumedSlotCount == 0)
    #expect(box.dispatcher.diagnostics.pendingEventCount == 0)
}

@Test
@MainActor
func staleLogicalDabDiscardIsBudgetedAcrossDrainTurns() async {
    let staleDabCount = 10_000
    var deliveredCount = 0
    let dispatcher = RendererEventDispatcher { event in
        guard case .logicalDab = event else { return }
        deliveredCount += 1
    }
    let staleGeneration = dispatcher.advanceStrokeGeneration()

    dispatcher.beginOperation()
    for ordinal in 0..<staleDabCount {
        dispatcher.stage(
            .logicalDab(
                generation: staleGeneration,
                dab: rendererEventLogicalDab(ordinal: UInt64(ordinal))
            )
        )
    }
    _ = dispatcher.advanceStrokeGeneration()
    dispatcher.endOperation(succeeded: true)

    #expect(deliveredCount == 0)
    #expect(
        dispatcher.diagnostics.staleGenerationDiscardCount
            == UInt64(RendererEventDispatcher.deliveryBudgetPerTurn)
    )
    #expect(
        dispatcher.diagnostics.pendingEventCount
            == staleDabCount
                - RendererEventDispatcher.deliveryBudgetPerTurn
    )
    #expect(dispatcher.diagnostics.scheduledContinuationCount == 1)

    for _ in 0..<100_000
    where dispatcher.diagnostics.pendingEventCount > 0 {
        await Task.yield()
    }

    #expect(dispatcher.diagnostics.pendingEventCount == 0)
    #expect(
        dispatcher.diagnostics.staleGenerationDiscardCount
            == UInt64(staleDabCount)
    )
    #expect(dispatcher.diagnostics.scheduledContinuationCount > 1)
    #expect(dispatcher.diagnostics.retainedConsumedSlotCount == 0)
}

@Test
func gridRendererEventOperationsAlwaysOpenNestedFrames() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MetalRenderer/GridRenderer.swift"
        ),
        encoding: .utf8
    )

    #expect(
        !source.contains(
            "guard !rendererEventDispatcher.hasOpenOperation else"
        )
    )
}

@MainActor
private final class RendererEventDispatcherBox {
    var dispatcher: RendererEventDispatcher!
}

private func rendererEventProbe(_ value: UInt64) -> RendererEvent {
    .operationCompleted(
        .operationSuccess(RendererOperationToken(rawValue: value))
    )
}

private func rendererEventProbeValue(_ event: RendererEvent) -> UInt64? {
    guard case let .operationCompleted(completion) = event,
          case let .operationSuccess(token) = completion
    else {
        return nil
    }
    return token.rawValue
}

private func rendererEventLogicalDab(ordinal: UInt64) -> LogicalDab {
    LogicalDab(
        position: WorldPoint(x: 0, y: 0),
        brushToWorld: .identity,
        radius: 1,
        diameter: 2,
        spacing: 1,
        flow: 1,
        strokeOpacity: 1,
        rotation: 0,
        scatter: .zero,
        hardness: 1,
        grainOffset: .zero,
        grainScale: 1,
        grainRotation: 0,
        color: .black,
        colorAdjustment: .identity,
        materialFamily: .ink,
        materialContribution: 1,
        sourceDistance: Float(ordinal),
        ordinal: ordinal,
        isPredicted: false,
        materialInputs: .neutral,
        randomValues: .neutral
    )
}

#if DEBUG
private func rendererEventFrameMetrics(value: Int) -> GPUFrameMetrics {
    GPUFrameMetrics(
        cpuEncodeMilliseconds: Double(value),
        gpuMilliseconds: Double(value),
        eventToSubmitNanoseconds: UInt64(value),
        gpuCompletionNanoseconds: UInt64(value),
        encodedDabCount: value,
        encodedInstanceCount: value,
        bufferLeaseCount: value
    )
}
#endif

private func rendererEventMarker(
    timestamp: UInt64
) -> StrokeRuntimeSegmentMarker {
    StrokeRuntimeSegmentMarker(
        kind: .segmentBegan,
        sessionID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!,
        segmentID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!,
        strokeID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000003"
        ),
        timestampNanoseconds: timestamp,
        traceProfile: .productionTenSeconds
    )
}

private func rendererEventSnapshot(
    logicalDabCount: UInt64
) -> StrokeRuntimeTelemetrySnapshot {
    StrokeRuntimeTelemetrySnapshot(
        sessionID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!,
        segmentID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        ),
        strokeID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000003"
        ),
        traceProfile: .productionTenSeconds,
        inputProvenance: .zero,
        newLogicalDabCount: logicalDabCount,
        newProjectedDabCount: 0,
        authoritativeReplayCount: 0,
        predictedReplayCount: 0,
        authoritativeQueueDepth: 0,
        predictedQueueDepth: 0,
        authoritativeQueueHighWater: 0,
        predictedQueueHighWater: 0,
        prepare: .zero,
        eventToSubmit: .zero,
        gpu: .zero,
        frame: .zero,
        missedFrameCount: 0,
        eventToSubmitMissCount: 0,
        frameCount: 0,
        observedDurationNanoseconds: 0,
        cacheHitCount: 0,
        cacheMissCount: 0,
        memoryHighWaterBytes: 0,
        authoritativeQueueDepths: [],
        lastTimestamps: nil
    )
}
