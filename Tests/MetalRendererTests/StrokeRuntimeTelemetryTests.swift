import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Test
func strokeRuntimeTelemetryAggregatesAttributableProductionFrames() throws {
    let clock = SyntheticRuntimeTimestampSource([
        100, 110, 900,
    ])
    var telemetry = StrokeRuntimeTelemetry(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        traceProfile: .productionTenSeconds,
        timestampSource: clock
    )
    let segmentID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000002"
    )!
    let strokeID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000003"
    )!

    let began = try telemetry.beginSegment(
        id: segmentID,
        strokeID: strokeID
    )
    telemetry.recordInput(.actual, count: 2)
    telemetry.recordInput(.coalesced, count: 3)
    telemetry.recordInput(.predicted, count: 4)
    telemetry.recordInput(.estimatedUpdate, count: 1)
    try telemetry.recordFrame(
        StrokeRuntimeFrameSample(
            strokeID: strokeID,
            timestamps: StrokeRuntimeFrameTimestamps(
                input: 1_000,
                prepareStarted: 1_100,
                prepareFinished: 1_300,
                submitted: 1_500,
                gpuStarted: 1_600,
                gpuFinished: 1_900,
                presented: 2_000
            ),
            targetFrameDurationNanoseconds: 1_000,
            newLogicalDabCount: 5,
            newProjectedDabCount: 9,
            authoritativeReplayCount: 0,
            predictedReplayCount: 2,
            authoritativeQueueDepth: 3,
            predictedQueueDepth: 2,
            cacheHitCount: 7,
            cacheMissCount: 1,
            residentMemoryBytes: 4_096
        )
    )
    try telemetry.recordFrame(
        StrokeRuntimeFrameSample(
            strokeID: strokeID,
            timestamps: StrokeRuntimeFrameTimestamps(
                input: 2_100,
                prepareStarted: 2_200,
                prepareFinished: 2_600,
                submitted: 3_000,
                gpuStarted: 3_100,
                gpuFinished: 3_400,
                presented: 3_500
            ),
            targetFrameDurationNanoseconds: 1_000,
            newLogicalDabCount: 7,
            newProjectedDabCount: 13,
            authoritativeReplayCount: 0,
            predictedReplayCount: 3,
            authoritativeQueueDepth: 1,
            predictedQueueDepth: 0,
            cacheHitCount: 11,
            cacheMissCount: 2,
            residentMemoryBytes: 8_192
        )
    )
    let ended = try telemetry.endSegment()

    #expect(began.kind == .segmentBegan)
    #expect(began.timestampNanoseconds == 100)
    #expect(ended.kind == .segmentEnded)
    #expect(ended.timestampNanoseconds == 110)
    #expect(began.sessionID == telemetry.snapshot.sessionID)
    #expect(began.segmentID == segmentID)
    #expect(began.strokeID == strokeID)

    let snapshot = telemetry.snapshot
    #expect(snapshot.traceProfile == .productionTenSeconds)
    #expect(snapshot.inputProvenance.actual == 2)
    #expect(snapshot.inputProvenance.coalesced == 3)
    #expect(snapshot.inputProvenance.predicted == 4)
    #expect(snapshot.inputProvenance.estimatedUpdate == 1)
    #expect(snapshot.newLogicalDabCount == 12)
    #expect(snapshot.newProjectedDabCount == 22)
    #expect(snapshot.authoritativeReplayCount == 0)
    #expect(snapshot.predictedReplayCount == 5)
    #expect(snapshot.authoritativeQueueDepth == 1)
    #expect(snapshot.predictedQueueDepth == 0)
    #expect(snapshot.authoritativeQueueHighWater == 3)
    #expect(snapshot.predictedQueueHighWater == 2)
    #expect(snapshot.prepare.p95 == 400)
    #expect(snapshot.eventToSubmit.p95 == 900)
    #expect(snapshot.gpu.p95 == 300)
    #expect(snapshot.frame.p95 == 1_500)
    #expect(snapshot.missedFrameFraction == 0.5)
    #expect(snapshot.eventToSubmitMissFraction == 0)
    #expect(snapshot.cacheHitCount == 18)
    #expect(snapshot.cacheMissCount == 3)
    #expect(snapshot.memoryHighWaterBytes == 8_192)
    #expect(snapshot.frameCount == 2)
    #expect(snapshot.attributedFrameCount == 2)
    #expect(snapshot.observedDurationNanoseconds == 2_500)
    #expect(snapshot.authoritativeQueueDepths == [3, 1])
}

@MainActor
@Test
func productionControllerAttestsCompleteRendererEvents() throws {
    let sessionID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000201"
    )!
    let segmentID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000202"
    )!
    let strokeID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000203"
    )!
    let controller = StrokeRuntimeProductionController(
        sessionID: sessionID,
        traceProfile: .productionTenSeconds,
        timestampSource: SyntheticRuntimeTimestampSource([10, 20])
    )

    let began = try controller.beginStroke(
        segmentID: segmentID,
        strokeID: strokeID
    )
    for frame in 0..<3 {
        let base = UInt64(frame) * 5_000_000_000
        controller.recordInput(.actual, at: base)
        try controller.beginFrame(
            id: UInt64(frame),
            prepareStarted: base + 100,
            targetFrameDurationNanoseconds: 6_000_000_000
        )
        try controller.recordPrepared(
            id: UInt64(frame),
            at: base + 200,
            newLogicalDabCount: 1,
            newProjectedDabCount: 2,
            authoritativeReplayCount: 0,
            predictedReplayCount: 0,
            authoritativeQueueDepth: 2 - frame,
            predictedQueueDepth: 0,
            cacheHitCount: 1,
            cacheMissCount: 0,
            residentMemoryBytes: 4_096
        )
        try controller.recordSubmitted(id: UInt64(frame), at: base + 300)
        try controller.recordGPU(
            id: UInt64(frame),
            started: base + 400,
            finished: base + 500
        )
        _ = try controller.recordPresented(
            id: UInt64(frame),
            at: base + (frame == 2 ? 1_000 : 600)
        )
    }
    let ended = try controller.endStroke()
    let evidence = try #require(controller.recordedEvidence)
    let snapshot = evidence.report

    #expect(controller.snapshot.frameRecords == nil)
    #expect(snapshot.frameRecords?.count == 3)
    #expect(began.sessionID == sessionID)
    #expect(began.segmentID == segmentID)
    #expect(ended.segmentID == segmentID)
    #expect(snapshot.sessionID == sessionID)
    #expect(snapshot.segmentID == segmentID)
    #expect(snapshot.strokeID == strokeID)
    #expect(snapshot.attestation?.origin == .productionRenderer)
    #expect(snapshot.attestation?.completeFrameEventCount == 3)
    #expect(snapshot.attestation?.queueObservationCount == 3)
    #expect(snapshot.attestation?.begunFrameEventCount == 3)
    #expect(snapshot.attestation?.attributedFrameEventCount == 3)
    #expect(snapshot.attestation?.discardedFrameEventCount == 0)
    #expect(
        snapshot.attestation?.presentationSemantics == .drawablePresented
    )
    #expect(snapshot.wallDurationNanoseconds == 10_000_001_000)
    #expect(snapshot.logicalDurationNanoseconds == 10_000_001_000)
    try BenchmarkStrokeRuntimeGate.validate(
        evidence,
        replayMode: .appendOnly
    )
}

@MainActor
@Test
func gridRendererRecordsAttributedProductionCallSites() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let renderer = try GridRenderer(
        device: device,
        library: try strokeRuntimeTestLibrary(device: device),
        drawableSize: PatternSize(width: 64, height: 64),
        configuration: try TilingCanvasConfiguration(
            pixelSize: PixelSize(width: 64, height: 64),
            tiling: .grid
        )
    )
    try renderer.installNativeHarnessBrushes()
    let sessionID = UUID()
    var markers: [StrokeRuntimeSegmentMarker] = []
    renderer.onStrokeRuntimeSegmentMarker = { markers.append($0) }
    renderer.configureStrokeRuntimeTelemetry(
        profile: .syntheticTest,
        sessionID: sessionID
    )
    let token = RendererOperationToken(rawValue: 0x5445_4C45)
    let style = try renderer.nativeHarnessStrokeStyle(
        diameter: 12,
        seed: token.rawValue
    )

    try renderer.beginStroke(
        token: token,
        sample: runtimeStrokeSample(x: 12, phase: .began, timestamp: 0),
        style: style
    )
    _ = try renderer.flushPendingLiveForHarness()
    try renderer.appendStroke(
        token: token,
        sample: runtimeStrokeSample(x: 32, phase: .moved, timestamp: 1 / 60)
    )
    _ = try renderer.flushPendingLiveForHarness()
    try renderer.requestStrokeCommit(
        token: token,
        sample: runtimeStrokeSample(x: 52, phase: .ended, timestamp: 2 / 60),
        maximumRetainedBytes: 8 * 1_024 * 1_024
    )
    while renderer.brushLabDiagnosticSnapshot.deposition
        .authoritativePending > 0
    {
        _ = try renderer.flushPendingLiveForHarness()
    }
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.finishCommitForHarness()

    let snapshot = try #require(renderer.strokeRuntimeSnapshot)
    let attestation = try #require(snapshot.attestation)
    #expect(attestation.origin == .productionRenderer)
    #expect(attestation.completeFrameEventCount == snapshot.frameCount)
    #expect(attestation.queueObservationCount == snapshot.frameCount)
    #expect(attestation.begunFrameEventCount == snapshot.frameCount)
    #expect(
        attestation.attributedFrameEventCount
            == snapshot.attributedFrameCount
    )
    #expect(attestation.attributedFrameEventCount > 0)
    #expect(attestation.discardedFrameEventCount == 0)
    #expect(
        attestation.presentationSemantics == .offscreenCommandCompleted
    )
    #expect(snapshot.sessionID == sessionID)
    #expect(snapshot.segmentID == markers.first?.segmentID)
    #expect(snapshot.strokeID == markers.first?.strokeID)
    #expect(snapshot.inputProvenance.actual == 3)
    #expect(snapshot.newLogicalDabCount > 0)
    #expect(snapshot.newProjectedDabCount > 0)
    #expect(snapshot.lastTimestamps != nil)
    #expect(snapshot.frame == .zero)
    #expect(snapshot.missedFrameCount == 0)
    #expect(markers.map(\.kind) == [.segmentBegan, .segmentEnded])
    #expect(markers[0].segmentID == markers[1].segmentID)
    #expect(markers[0].strokeID == markers[1].strokeID)
}

@MainActor
@Test
func runtimeBeginObserverCanCancelStartReplacementWithoutOuterBeginDestroyingIt()
    async throws
{
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let renderer = try runtimeTestRenderer(device: device)
    renderer.configureStrokeRuntimeTelemetry(profile: .syntheticTest)
    let originalToken = RendererOperationToken(rawValue: 0x4245_4741)
    let replacementToken = RendererOperationToken(rawValue: 0x4245_4742)
    let style = try renderer.nativeHarnessStrokeStyle(
        diameter: 12,
        seed: originalToken.rawValue
    )
    var replaced = false
    var replacementStarted = false
    var replacementError: MetalRendererError?
    renderer.onIdleStateChange = { idle in
        guard idle, replaced, !replacementStarted else { return }
        replacementStarted = true
        do {
            try renderer.beginStroke(
                token: replacementToken,
                sample: runtimeStrokeSample(
                    x: 16,
                    phase: .began,
                    timestamp: 1
                ),
                style: style
            )
        } catch let error as MetalRendererError {
            replacementError = error
        } catch {
            replacementError = .commandFailed(error.localizedDescription)
        }
    }
    renderer.onStrokeRuntimeSegmentMarker = { marker in
        guard marker.kind == .segmentBegan, !replaced else { return }
        replaced = true
        #expect(renderer.hasActiveStroke)
        do {
            try renderer.cancelStroke(token: originalToken)
        } catch let error as MetalRendererError {
            replacementError = error
        } catch {
            replacementError = .commandFailed(error.localizedDescription)
        }
    }

    try renderer.beginStroke(
        token: originalToken,
        sample: runtimeStrokeSample(x: 12, phase: .began, timestamp: 0),
        style: style
    )

    #expect(replaced)
    #expect(!replacementStarted)
    #expect(replacementError == nil)
    try await renderer.awaitPendingStrokeWorkspaceRetirement()
    #expect(replacementStarted)
    #expect(renderer.hasActiveStroke)
    try renderer.appendStroke(
        token: replacementToken,
        sample: runtimeStrokeSample(x: 32, phase: .moved, timestamp: 2)
    )
    do {
        try renderer.cancelStroke(token: originalToken)
        Issue.record("Expected the original token to be stale")
    } catch let error as MetalRendererError {
        #expect(error == .invalidRendererOperationToken)
    }
    renderer.onStrokeRuntimeSegmentMarker = nil
    renderer.onIdleStateChange = nil
    try renderer.cancelStroke(token: replacementToken)
    try await renderer.awaitPendingStrokeWorkspaceRetirement()
}

@MainActor
@Test
func runtimeEndObserverCanStartReplacementWithoutOuterTeardownDestroyingIt()
    async throws
{
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let renderer = try runtimeTestRenderer(device: device)
    renderer.configureStrokeRuntimeTelemetry(profile: .syntheticTest)
    let originalToken = RendererOperationToken(rawValue: 0x454E_4441)
    let replacementToken = RendererOperationToken(rawValue: 0x454E_4442)
    let style = try renderer.nativeHarnessStrokeStyle(
        diameter: 12,
        seed: originalToken.rawValue
    )
    try renderer.beginStroke(
        token: originalToken,
        sample: runtimeStrokeSample(x: 12, phase: .began, timestamp: 0),
        style: style
    )
    var replaced = false
    var replacementStarted = false
    var replacementError: MetalRendererError?
    renderer.onIdleStateChange = { idle in
        guard idle, replaced, !replacementStarted else { return }
        replacementStarted = true
        do {
            try renderer.beginStroke(
                token: replacementToken,
                sample: runtimeStrokeSample(
                    x: 16,
                    phase: .began,
                    timestamp: 1
                ),
                style: style
            )
        } catch let error as MetalRendererError {
            replacementError = error
        } catch {
            replacementError = .commandFailed(error.localizedDescription)
        }
    }
    renderer.onStrokeRuntimeSegmentMarker = { marker in
        guard marker.kind == .segmentEnded, !replaced else { return }
        replaced = true
        #expect(!renderer.isIdle)
    }

    try renderer.cancelStroke(token: originalToken)

    #expect(replaced)
    #expect(!replacementStarted)
    #expect(replacementError == nil)
    try await renderer.awaitPendingStrokeWorkspaceRetirement()
    #expect(replacementStarted)
    #expect(renderer.hasActiveStroke)
    try renderer.appendStroke(
        token: replacementToken,
        sample: runtimeStrokeSample(x: 32, phase: .moved, timestamp: 2)
    )
    renderer.onStrokeRuntimeSegmentMarker = nil
    renderer.onIdleStateChange = nil
    try renderer.cancelStroke(token: replacementToken)
    try await renderer.awaitPendingStrokeWorkspaceRetirement()
}

@MainActor
@Test
func failedCommitPublishesEndTelemetryAndIdleAfterRollback() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let renderer = try runtimeTestRenderer(device: device)
    renderer.configureStrokeRuntimeTelemetry(profile: .syntheticTest)
    let token = RendererOperationToken(rawValue: 0x524F_4C4C)
    let style = try renderer.nativeHarnessStrokeStyle(
        diameter: 12,
        seed: token.rawValue
    )
    try renderer.beginStroke(
        token: token,
        sample: runtimeStrokeSample(x: 12, phase: .began, timestamp: 0),
        style: style
    )

    enum ObservedEvent: Equatable {
        case marker(StrokeRuntimeSegmentEventKind)
        case snapshot
        case idle(Bool)
    }
    var events: [ObservedEvent] = []
    renderer.onStrokeRuntimeSegmentMarker = { marker in
        #expect(!renderer.isIdle)
        events.append(.marker(marker.kind))
    }
    renderer.onStrokeRuntimeSnapshot = { _ in
        #expect(!renderer.isIdle)
        events.append(.snapshot)
    }
    renderer.onIdleStateChange = { idle in
        #expect(renderer.isIdle == idle)
        events.append(.idle(idle))
    }

    #expect(throws: MetalRendererError.rasterRevisionStorageLimitExceeded) {
        try renderer.requestStrokeCommit(
            token: token,
            sample: runtimeStrokeSample(x: 32, phase: .ended, timestamp: 1),
            maximumRetainedBytes: -1
        )
    }

    #expect(!renderer.isIdle)
    #expect(
        events == [
            .marker(.segmentEnded),
            .snapshot,
        ]
    )
    try await renderer.awaitPendingStrokeWorkspaceRetirement()
    #expect(renderer.isIdle)
    #expect(
        events == [
            .marker(.segmentEnded),
            .snapshot,
            .idle(true),
        ]
    )
}

@MainActor
@Test
func mixedLogicalDabAndRuntimeEventsPreserveCommittedOrder() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let renderer = try runtimeTestRenderer(device: device)
    renderer.configureStrokeRuntimeTelemetry(profile: .syntheticTest)
    let token = RendererOperationToken(rawValue: 0x4F52_4445)
    let style = try renderer.nativeHarnessStrokeStyle(
        diameter: 12,
        seed: token.rawValue
    )
    enum ObservedEvent: Equatable {
        case dab(UInt64)
        case marker(StrokeRuntimeSegmentEventKind)
        case snapshot
    }
    var events: [ObservedEvent] = []
    renderer.onLogicalDabsGenerated = { events.append(.dab($0.ordinal)) }
    renderer.onStrokeRuntimeSegmentMarker = {
        events.append(.marker($0.kind))
    }
    renderer.onStrokeRuntimeSnapshot = { _ in events.append(.snapshot) }

    try renderer.beginStroke(
        token: token,
        sample: runtimeStrokeSample(x: 12, phase: .began, timestamp: 0),
        style: style
    )
    try renderer.drainPreparedStrokeInputForHarness()

    let markerIndex = try #require(
        events.firstIndex(of: .marker(.segmentBegan))
    )
    let snapshotIndex = try #require(events.firstIndex(of: .snapshot))
    let dabOrdinals: [UInt64] = events.compactMap { event in
        guard case let .dab(ordinal) = event else { return nil }
        return ordinal
    }
    let firstDabIndex = try #require(events.firstIndex {
        if case .dab = $0 { return true }
        return false
    })
    #expect(!dabOrdinals.isEmpty)
    #expect(markerIndex < snapshotIndex)
    #expect(snapshotIndex < firstDabIndex)
    #expect(
        zip(dabOrdinals, dabOrdinals.dropFirst()).allSatisfy {
            $0 <= $1
        }
    )
    renderer.onLogicalDabsGenerated = nil
    renderer.onStrokeRuntimeSegmentMarker = nil
    renderer.onStrokeRuntimeSnapshot = nil
    try renderer.cancelStroke(token: token)
    try renderer.drainStrokeWorkspaceRetirementForHarness()
}

@MainActor
@Test
func lateOldTelemetryFrameCannotMutateReconfiguredController() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let renderer = try runtimeTestRenderer(device: device)
    let oldToken = RendererOperationToken(rawValue: 0x4F4C_4401)
    let newToken = RendererOperationToken(rawValue: 0x4E45_5701)
    let style = try renderer.nativeHarnessStrokeStyle(
        diameter: 12,
        seed: oldToken.rawValue
    )
    renderer.configureStrokeRuntimeTelemetry(profile: .syntheticTest)
    try renderer.beginStroke(
        token: oldToken,
        sample: runtimeStrokeSample(x: 12, phase: .began, timestamp: 0),
        style: style
    )
    let oldIdentity = try #require(
        renderer.beginStrokeRuntimeFrameForTesting()
    )
    renderer.prepareStrokeRuntimeFrameForTesting(oldIdentity)
    renderer.submitStrokeRuntimeFrameForTesting(oldIdentity)
    try renderer.cancelStroke(token: oldToken)
    try await renderer.awaitPendingStrokeWorkspaceRetirement()

    renderer.configureStrokeRuntimeTelemetry(profile: .syntheticTest)
    try renderer.beginStroke(
        token: newToken,
        sample: runtimeStrokeSample(x: 16, phase: .began, timestamp: 1),
        style: style
    )
    let newIdentity = try #require(
        renderer.beginStrokeRuntimeFrameForTesting()
    )
    #expect(oldIdentity.frameID == newIdentity.frameID)
    #expect(
        oldIdentity.telemetryGeneration
            != newIdentity.telemetryGeneration
    )
    renderer.prepareStrokeRuntimeFrameForTesting(newIdentity)
    renderer.submitStrokeRuntimeFrameForTesting(newIdentity)
    let snapshotBeforeStaleCompletion = renderer.strokeRuntimeSnapshot

    renderer.completeStrokeRuntimeGPUFrameForTesting(oldIdentity)
    renderer.presentStrokeRuntimeFrameForTesting(oldIdentity)

    #expect(renderer.pendingStrokeRuntimeFrameCountForTesting == 1)
    #expect(renderer.strokeRuntimeSnapshot == snapshotBeforeStaleCompletion)
    renderer.completeStrokeRuntimeGPUFrameForTesting(newIdentity)
    #expect(renderer.pendingStrokeRuntimeFrameCountForTesting == 1)
    renderer.presentStrokeRuntimeFrameForTesting(newIdentity)
    #expect(renderer.pendingStrokeRuntimeFrameCountForTesting == 0)
    try renderer.cancelStroke(token: newToken)
    try await renderer.awaitPendingStrokeWorkspaceRetirement()
}

@MainActor
@Test
func queuedLogicalDabsResolveReplacementObserverAtContinuationTime()
    async throws
{
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let renderer = try runtimeTestRenderer(device: device)
    let token = RendererOperationToken(rawValue: 0x4F42_5301)
    let style = try renderer.nativeHarnessStrokeStyle(
        diameter: 12,
        seed: token.rawValue
    )
    try renderer.beginStroke(
        token: token,
        sample: runtimeStrokeSample(x: 0, phase: .began, timestamp: 0),
        style: style
    )
    try renderer.drainPreparedStrokeInputForHarness()

    var initialObserverCount = 0
    var replacementObserverCount = 0
    renderer.onLogicalDabsGenerated = { _ in
        initialObserverCount += 1
    }
    try renderer.appendStroke(
        token: token,
        sample: runtimeStrokeSample(x: 4_096, phase: .moved, timestamp: 1)
    )
    try renderer.drainPreparedStrokeInputForHarness()

    #expect(initialObserverCount == 256)
    renderer.onLogicalDabsGenerated = { _ in
        replacementObserverCount += 1
    }
    renderer.drainOneRendererEventTurnForHarness()

    #expect(initialObserverCount == 256)
    #expect(replacementObserverCount > 0)
    renderer.onLogicalDabsGenerated = nil
    try renderer.cancelStroke(token: token)
    try await renderer.awaitPendingStrokeWorkspaceRetirement()
}

@MainActor
@Test
func queuedLogicalDabsStopCallingObserverWhenPropertyBecomesNil()
    async throws
{
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let renderer = try runtimeTestRenderer(device: device)
    let token = RendererOperationToken(rawValue: 0x4F42_5302)
    let style = try renderer.nativeHarnessStrokeStyle(
        diameter: 12,
        seed: token.rawValue
    )
    try renderer.beginStroke(
        token: token,
        sample: runtimeStrokeSample(x: 0, phase: .began, timestamp: 0),
        style: style
    )
    try renderer.drainPreparedStrokeInputForHarness()

    var observerCount = 0
    renderer.onLogicalDabsGenerated = { _ in observerCount += 1 }
    try renderer.appendStroke(
        token: token,
        sample: runtimeStrokeSample(x: 4_096, phase: .moved, timestamp: 1)
    )
    try renderer.drainPreparedStrokeInputForHarness()

    #expect(observerCount == 256)
    renderer.onLogicalDabsGenerated = nil
    renderer.drainOneRendererEventTurnForHarness()

    #expect(observerCount == 256)
    try renderer.cancelStroke(token: token)
    try await renderer.awaitPendingStrokeWorkspaceRetirement()
}

@Test
func replayEpochTrackerResetsForEachStroke() {
    var tracker = StrokeRuntimeReplayEpochTracker()

    tracker.beginStroke(at: 0)
    #expect(tracker.consume(currentEpoch: 1) == 1)

    tracker.beginStroke(at: 0)
    #expect(tracker.consume(currentEpoch: 1) == 1)
}

@MainActor
@Test
func acceleratedProductionTraceDerivesLogicalTimeFromWallTime() throws {
    let controller = StrokeRuntimeProductionController(
        traceProfile: .productionAcceleratedTenMinutes,
        timestampSource: SyntheticRuntimeTimestampSource([1, 2])
    )
    _ = try controller.beginStroke(strokeID: UUID())
    try recordControllerFrame(
        controller,
        id: 1,
        input: 1_000,
        presented: 2_000,
        queue: 2
    )
    try recordControllerFrame(
        controller,
        id: 2,
        input: 5_000_000_000,
        presented: 5_000_001_000,
        queue: 1
    )
    try recordControllerFrame(
        controller,
        id: 3,
        input: 10_000_000_000,
        presented: 10_000_001_000,
        queue: 0
    )
    _ = try controller.endStroke()
    let evidence = try #require(controller.recordedEvidence)

    #expect(evidence.report.wallDurationNanoseconds == 10_000_000_000)
    #expect(
        evidence.report.logicalDurationNanoseconds
            == 600_000_000_000
    )
    try BenchmarkStrokeRuntimeGate.validate(
        evidence,
        replayMode: .appendOnly
    )
}

@Test
func directAggregateRemainsAnImportedReport() throws {
    var telemetry = StrokeRuntimeTelemetry(
        traceProfile: .productionTenSeconds,
        timestampSource: SyntheticRuntimeTimestampSource([1, 2])
    )
    _ = try telemetry.beginSegment(strokeID: UUID())
    telemetry.recordInput(.actual)

    #expect(
        telemetry.snapshot.attestation?.origin == .syntheticOrImported
    )
}

@Test
func encodedSnapshotCannotRelabelItsAttestedTraceProfile() throws {
    let original = runtimeGateSnapshot(
        profile: .productionTenSeconds,
        actualReplay: 0,
        queues: [2, 1, 0],
        missed: 0,
        frames: 100
    )
    var object = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)
        ) as? [String: Any]
    )
    object["traceProfile"] =
        StrokeRuntimeTraceProfile.productionAcceleratedTenMinutes.rawValue
    let forged = try JSONDecoder().decode(
        StrokeRuntimeTelemetrySnapshot.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(forged.traceProfile != original.traceProfile)
    #expect(forged.attestation?.traceProfile != forged.traceProfile)
}

@Test
func encodedSnapshotCannotEraseGatedFailures() throws {
    let original = runtimeGateSnapshot(
        profile: .productionTenSeconds,
        actualReplay: 1,
        queues: [2, 1, 0],
        missed: 2,
        frames: 100
    )
    var object = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)
        ) as? [String: Any]
    )
    object["authoritativeReplayCount"] = 0
    object["eventToSubmitMissCount"] = 0
    let forged = try JSONDecoder().decode(
        StrokeRuntimeTelemetrySnapshot.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(forged.authoritativeReplayCount == 0)
    #expect(forged.eventToSubmitMissCount == 0)
    #expect(original.authoritativeReplayCount == 1)
    #expect(original.eventToSubmitMissCount == 2)
}

@Test
func encodedSnapshotCannotForgeRecorderOrigin() throws {
    let original = runtimeGateSnapshot(
        profile: .productionTenSeconds,
        actualReplay: 0,
        queues: [2, 1, 0],
        missed: 0,
        frames: 100,
        origin: .syntheticOrImported
    )
    var object = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)
        ) as? [String: Any]
    )
    var attestation = try #require(
        object["attestation"] as? [String: Any]
    )
    attestation["origin"] = StrokeRuntimeRecorderOrigin
        .productionRenderer.rawValue
    object["attestation"] = attestation
    let forged = try JSONDecoder().decode(
        StrokeRuntimeTelemetrySnapshot.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(forged.attestation?.origin == .productionRenderer)
    #expect(original.attestation?.origin == .syntheticOrImported)
}

@Test
func encodedSnapshotCannotHideFullSegmentBacklogGrowth() throws {
    let original = runtimeGateSnapshot(
        profile: .productionTenSeconds,
        actualReplay: 0,
        queues: [1, 2, 3],
        missed: 0,
        frames: 100
    )
    var object = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)
        ) as? [String: Any]
    )
    var attestation = try #require(
        object["attestation"] as? [String: Any]
    )
    attestation["longestBacklogGrowthRun"] = 0
    object["attestation"] = attestation
    let forged = try JSONDecoder().decode(
        StrokeRuntimeTelemetrySnapshot.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(forged.attestation?.longestBacklogGrowthRun == 0)
    #expect(original.attestation?.longestBacklogGrowthRun == 3)
}

@MainActor
@Test
func decodedReportCannotRetainLiveRecorderAuthority() throws {
    let evidence = try runtimeGateEvidence(
        profile: .productionTenSeconds,
        actualReplay: 0,
        queues: [2, 1, 0],
        missed: 0,
        frames: 100
    )
    let decoded = try JSONDecoder().decode(
        StrokeRuntimeTelemetrySnapshot.self,
        from: JSONEncoder().encode(evidence.report)
    )

    #expect(decoded == evidence.report)
    #expect(decoded.frameRecords?.count == 100)
    #expect(decoded.traceOverflowCount == 0)
    #expect(
        !((StrokeRuntimeRecordedEvidence.self as Any.Type)
            is any Codable.Type)
    )
    try BenchmarkStrokeRuntimeGate.validate(
        evidence,
        replayMode: .appendOnly
    )
}

@MainActor
@Test
func productionControllerConsumesInputWhenFrameBegins() throws {
    let controller = StrokeRuntimeProductionController(
        traceProfile: .syntheticTest
    )
    _ = try controller.beginStroke(strokeID: UUID())
    controller.recordInput(.actual, at: 100)
    try controller.beginFrame(
        id: 1,
        prepareStarted: 200,
        targetFrameDurationNanoseconds: 2_000
    )
    controller.recordInput(.actual, at: 1_000)
    try controller.beginFrame(
        id: 2,
        prepareStarted: 1_100,
        targetFrameDurationNanoseconds: 2_000
    )
    try finishControllerFrame(controller, id: 1, base: 200, submitted: 300)
    try finishControllerFrame(controller, id: 2, base: 1_100, submitted: 1_300)

    #expect(controller.snapshot.eventToSubmit.p95 == 300)
}

@MainActor
@Test
func productionControllerDiscardsEveryInflightFrameBeforeEnding() throws {
    let controller = StrokeRuntimeProductionController(
        traceProfile: .syntheticTest
    )
    _ = try controller.beginStroke(strokeID: UUID())
    try controller.beginFrame(
        id: 1,
        prepareStarted: 100,
        targetFrameDurationNanoseconds: 1_000
    )
    try controller.beginFrame(
        id: 2,
        prepareStarted: 200,
        targetFrameDurationNanoseconds: 1_000
    )

    controller.discardPendingFrames()
    let ended = try controller.endStroke()

    #expect(ended.kind == .segmentEnded)
}

@MainActor
@Test
func fullSegmentBacklogGrowthSurvivesBoundedDiagnosticHistory() throws {
    let controller = StrokeRuntimeProductionController(
        traceProfile: .productionTenSeconds,
        windowCapacity: 3,
        timestampSource: SyntheticRuntimeTimestampSource([1, 2])
    )
    _ = try controller.beginStroke(strokeID: UUID())
    for (index, queue) in [1, 2, 3, 4, 2, 1].enumerated() {
        try recordControllerFrame(
            controller,
            id: UInt64(index),
            input: UInt64(index) * 2_000_000_000,
            presented: UInt64(index) * 2_000_000_000 + 1_000,
            queue: queue
        )
    }
    _ = try controller.endStroke()
    let evidence = try #require(controller.recordedEvidence)

    #expect(evidence.report.authoritativeQueueDepths == [4, 2, 1])
    #expect(evidence.report.attestation?.queueObservationCount == 6)
    #expect(evidence.report.attestation?.longestBacklogGrowthRun == 4)
    #expect(throws: BenchmarkStrokeRuntimeGateError.monotonicBacklog(run: 4)) {
        try BenchmarkStrokeRuntimeGate.validate(
            evidence,
            replayMode: .appendOnly
        )
    }
}

@MainActor
@Test
func softwareGateRejectsInadequateQueueEvidence() throws {
    let controller = StrokeRuntimeProductionController(
        traceProfile: .productionTenSeconds,
        timestampSource: SyntheticRuntimeTimestampSource([1, 2])
    )
    _ = try controller.beginStroke(strokeID: UUID())
    try recordControllerFrame(
        controller,
        id: 1,
        input: 0,
        presented: 10_000_000_000,
        queue: 0
    )
    _ = try controller.endStroke()
    let evidence = try #require(controller.recordedEvidence)

    #expect(
        throws: BenchmarkStrokeRuntimeGateError
            .insufficientQueueEvidence(actual: 1, required: 3)
    ) {
        try BenchmarkStrokeRuntimeGate.validate(
            evidence,
            replayMode: .appendOnly
        )
    }
}

@MainActor
@Test
func productionGateDoesNotDiluteMissesWithFramesWithoutInput() throws {
    let controller = StrokeRuntimeProductionController(
        traceProfile: .productionTenSeconds,
        timestampSource: SyntheticRuntimeTimestampSource([1, 2])
    )
    _ = try controller.beginStroke(strokeID: UUID())
    controller.recordInput(.actual, at: 0)
    try controller.beginFrame(
        id: 0,
        prepareStarted: 100,
        targetFrameDurationNanoseconds: 1_000
    )
    try controller.recordPrepared(
        id: 0,
        at: 200,
        newLogicalDabCount: 1,
        newProjectedDabCount: 1,
        authoritativeReplayCount: 0,
        predictedReplayCount: 0,
        authoritativeQueueDepth: 1,
        predictedQueueDepth: 0,
        cacheHitCount: 0,
        cacheMissCount: 0,
        residentMemoryBytes: 1
    )
    try controller.recordSubmitted(id: 0, at: 2_000)
    try controller.recordGPU(id: 0, started: 2_100, finished: 2_200)
    _ = try controller.recordPresented(id: 0, at: 2_300)
    for frame in 1..<100 {
        let id = UInt64(frame)
        let base = id * 110_000_000
        try controller.beginFrame(
            id: id,
            prepareStarted: base + 100,
            targetFrameDurationNanoseconds: 1_000
        )
        try controller.recordPrepared(
            id: id,
            at: base + 200,
            newLogicalDabCount: 1,
            newProjectedDabCount: 1,
            authoritativeReplayCount: 0,
            predictedReplayCount: 0,
            authoritativeQueueDepth: frame.isMultiple(of: 2) ? 1 : 0,
            predictedQueueDepth: 0,
            cacheHitCount: 0,
            cacheMissCount: 0,
            residentMemoryBytes: 1
        )
        try controller.recordSubmitted(id: id, at: base + 300)
        try controller.recordGPU(
            id: id,
            started: base + 400,
            finished: base + 500
        )
        _ = try controller.recordPresented(id: id, at: base + 600)
    }
    _ = try controller.endStroke()
    let evidence = try #require(controller.recordedEvidence)

    #expect(evidence.report.eventToSubmitMissFraction == 1)
    #expect(
        throws: BenchmarkStrokeRuntimeGateError
            .eventToSubmitMissFraction(actual: 1, maximum: 0.01)
    ) {
        try BenchmarkStrokeRuntimeGate.validate(
            evidence,
            replayMode: .appendOnly
        )
    }
}

@MainActor
@Test
func productionGateRejectsDiscardedFrameEvidence() throws {
    let controller = StrokeRuntimeProductionController(
        traceProfile: .productionTenSeconds,
        timestampSource: SyntheticRuntimeTimestampSource([1, 2])
    )
    _ = try controller.beginStroke(strokeID: UUID())
    try recordControllerFrame(
        controller,
        id: 1,
        input: 0,
        presented: 1_000,
        queue: 2
    )
    try recordControllerFrame(
        controller,
        id: 2,
        input: 5_000_000_000,
        presented: 5_000_001_000,
        queue: 1
    )
    try recordControllerFrame(
        controller,
        id: 3,
        input: 10_000_000_000,
        presented: 10_000_001_000,
        queue: 0
    )
    try controller.beginFrame(
        id: 4,
        prepareStarted: 10_000_002_000,
        targetFrameDurationNanoseconds: 1_000
    )
    controller.discardPendingFrames()
    _ = try controller.endStroke()
    let evidence = try #require(controller.recordedEvidence)

    #expect(throws: BenchmarkStrokeRuntimeGateError.self) {
        try BenchmarkStrokeRuntimeGate.validate(
            evidence,
            replayMode: .appendOnly
        )
    }
}

@MainActor
@Test
func productionGateRejectsUnconsumedInputEvidence() throws {
    let controller = StrokeRuntimeProductionController(
        traceProfile: .productionTenSeconds,
        timestampSource: SyntheticRuntimeTimestampSource([1, 2])
    )
    _ = try controller.beginStroke(strokeID: UUID())
    for (id, input, presented, queue) in [
        (UInt64(1), UInt64(0), UInt64(1_000), 2),
        (UInt64(2), UInt64(5_000_000_000), UInt64(5_000_001_000), 1),
        (UInt64(3), UInt64(10_000_000_000), UInt64(10_000_001_000), 0),
    ] {
        try recordControllerFrame(
            controller,
            id: id,
            input: input,
            presented: presented,
            queue: queue
        )
    }
    controller.recordInput(.actual, at: 10_000_002_000)
    _ = try controller.endStroke()
    let evidence = try #require(controller.recordedEvidence)

    #expect(
        throws: BenchmarkStrokeRuntimeGateError.unconsumedInputEvidence(1)
    ) {
        try BenchmarkStrokeRuntimeGate.validate(
            evidence,
            replayMode: .appendOnly
        )
    }
}

@MainActor
@Test
func productionGateRejectsBoundedTraceOverflow() throws {
    let controller = StrokeRuntimeProductionController(
        traceProfile: .productionTenSeconds,
        windowCapacity: 3,
        traceCapacity: 3,
        timestampSource: SyntheticRuntimeTimestampSource([1, 2])
    )
    _ = try controller.beginStroke(strokeID: UUID())
    for (id, input, presented, queue) in [
        (UInt64(1), UInt64(0), UInt64(1_000), 2),
        (UInt64(2), UInt64(3_000_000_000), UInt64(3_000_001_000), 1),
        (UInt64(3), UInt64(6_000_000_000), UInt64(6_000_001_000), 2),
        (UInt64(4), UInt64(10_000_000_000), UInt64(10_000_001_000), 0),
    ] {
        try recordControllerFrame(
            controller,
            id: id,
            input: input,
            presented: presented,
            queue: queue
        )
    }
    _ = try controller.endStroke()
    let evidence = try #require(controller.recordedEvidence)

    #expect(evidence.report.frameRecords?.count == 3)
    #expect(evidence.report.traceOverflowCount == 1)
    #expect(
        throws: BenchmarkStrokeRuntimeGateError.incompleteFrameEvidence(
            begun: 4,
            complete: 3,
            discarded: 1
        )
    ) {
        try BenchmarkStrokeRuntimeGate.validate(
            evidence,
            replayMode: .appendOnly
        )
    }
}

@Test
func telemetryRejectsGPUOrderingAndFrameRegressions() throws {
    let strokeID = UUID()
    var telemetry = StrokeRuntimeTelemetry(
        traceProfile: .syntheticTest,
        timestampSource: SyntheticRuntimeTimestampSource([1])
    )
    _ = try telemetry.beginSegment(strokeID: strokeID)
    telemetry.recordInput(.actual)

    #expect(throws: StrokeRuntimeTelemetryError.invalidTimestampOrder) {
        try telemetry.recordFrame(runtimeFrame(
            strokeID: strokeID,
            input: 100,
            submitted: 400,
            gpuStarted: 300,
            gpuFinished: 500,
            presented: 600,
            queue: 1
        ))
    }
    try telemetry.recordFrame(runtimeFrame(
        strokeID: strokeID,
        input: 100,
        submitted: 400,
        gpuStarted: 450,
        gpuFinished: 500,
        presented: 600,
        queue: 1
    ))
    #expect(throws: StrokeRuntimeTelemetryError.timestampRegression) {
        try telemetry.recordFrame(runtimeFrame(
            strokeID: strokeID,
            input: 90,
            submitted: 500,
            gpuStarted: 510,
            gpuFinished: 520,
            presented: 700,
            queue: 0
        ))
    }
    #expect(throws: StrokeRuntimeTelemetryError.timestampRegression) {
        try telemetry.recordFrame(runtimeFrame(
            strokeID: strokeID,
            input: 100,
            submitted: 400,
            gpuStarted: 450,
            gpuFinished: 500,
            presented: 599,
            queue: 0
        ))
    }
}

@Test(arguments: [
    StrokeRuntimeFrameTimestamps(
        input: 200,
        prepareStarted: 100,
        prepareFinished: 300,
        submitted: 400,
        gpuStarted: 500,
        gpuFinished: 600,
        presented: 700
    ),
    StrokeRuntimeFrameTimestamps(
        input: 100,
        prepareStarted: 300,
        prepareFinished: 200,
        submitted: 400,
        gpuStarted: 500,
        gpuFinished: 600,
        presented: 700
    ),
    StrokeRuntimeFrameTimestamps(
        input: 100,
        prepareStarted: 200,
        prepareFinished: 500,
        submitted: 400,
        gpuStarted: 600,
        gpuFinished: 700,
        presented: 800
    ),
    StrokeRuntimeFrameTimestamps(
        input: 100,
        prepareStarted: 200,
        prepareFinished: 300,
        submitted: 500,
        gpuStarted: 400,
        gpuFinished: 600,
        presented: 700
    ),
    StrokeRuntimeFrameTimestamps(
        input: 100,
        prepareStarted: 200,
        prepareFinished: 300,
        submitted: 400,
        gpuStarted: 600,
        gpuFinished: 500,
        presented: 700
    ),
    StrokeRuntimeFrameTimestamps(
        input: 100,
        prepareStarted: 200,
        prepareFinished: 300,
        submitted: 400,
        gpuStarted: 500,
        gpuFinished: 700,
        presented: 600
    ),
])
func telemetryRejectsEveryWithinFrameTimestampInversion(
    _ timestamps: StrokeRuntimeFrameTimestamps
) throws {
    let strokeID = UUID()
    var telemetry = StrokeRuntimeTelemetry(
        traceProfile: .syntheticTest,
        timestampSource: SyntheticRuntimeTimestampSource([1])
    )
    _ = try telemetry.beginSegment(strokeID: strokeID)

    #expect(throws: StrokeRuntimeTelemetryError.invalidTimestampOrder) {
        try telemetry.recordFrame(StrokeRuntimeFrameSample(
            strokeID: strokeID,
            timestamps: timestamps,
            targetFrameDurationNanoseconds: 1_000,
            newLogicalDabCount: 1,
            newProjectedDabCount: 1,
            authoritativeReplayCount: 0,
            predictedReplayCount: 0,
            authoritativeQueueDepth: 0,
            predictedQueueDepth: 0,
            cacheHitCount: 0,
            cacheMissCount: 0,
            residentMemoryBytes: 0
        ))
    }
}

@MainActor
@Test
func productionControllerRotatesSegmentIDsWithinOneSession() throws {
    let sessionID = UUID()
    let controller = StrokeRuntimeProductionController(
        sessionID: sessionID,
        traceProfile: .syntheticTest,
        timestampSource: SyntheticRuntimeTimestampSource([1, 2, 3, 4])
    )
    let first = try controller.beginStroke(strokeID: UUID())
    _ = try controller.endStroke()
    let second = try controller.beginStroke(strokeID: UUID())

    #expect(first.sessionID == sessionID)
    #expect(second.sessionID == sessionID)
    #expect(first.segmentID != second.segmentID)
    #expect(first.strokeID != second.strokeID)
    #expect(controller.snapshot.segmentID == second.segmentID)
    #expect(controller.snapshot.strokeID == second.strokeID)
}

@MainActor
@Test
func strokeRuntimeSoftwareGateRejectsEachSilentFailureMode() throws {
    let passing = try runtimeGateEvidence(
        profile: .productionTenSeconds,
        actualReplay: 0,
        queues: [2, 1, 0],
        missed: 1,
        frames: 100
    )
    try BenchmarkStrokeRuntimeGate.validate(
        passing,
        replayMode: .appendOnly
    )

    #expect(throws: BenchmarkStrokeRuntimeGateError.appendOnlyReplay(1)) {
        try BenchmarkStrokeRuntimeGate.validate(
            try runtimeGateEvidence(
                profile: .productionTenSeconds,
                actualReplay: 1,
                queues: [2, 1, 0],
                missed: 0,
                frames: 100
            ),
            replayMode: .appendOnly
        )
    }
    #expect(
        throws: BenchmarkStrokeRuntimeGateError.monotonicBacklog(run: 3)
    ) {
        try BenchmarkStrokeRuntimeGate.validate(
            try runtimeGateEvidence(
                profile: .productionTenSeconds,
                actualReplay: 0,
                queues: [1, 2, 2],
                missed: 0,
                frames: 100
            ),
            replayMode: .appendOnly
        )
    }
    #expect(
        throws: BenchmarkStrokeRuntimeGateError
            .eventToSubmitMissFraction(actual: 0.02, maximum: 0.01)
    ) {
        try BenchmarkStrokeRuntimeGate.validate(
            try runtimeGateEvidence(
                profile: .productionTenSeconds,
                actualReplay: 0,
                queues: [2, 1, 0],
                missed: 2,
                frames: 100
            ),
            replayMode: .appendOnly
        )
    }
    #expect(
        throws: BenchmarkStrokeRuntimeGateError.nonProductionTrace
    ) {
        try BenchmarkStrokeRuntimeGate.validate(
            try runtimeGateEvidence(
                profile: .syntheticTest,
                actualReplay: 0,
                queues: [2, 1, 0],
                missed: 0,
                frames: 100
            ),
            replayMode: .appendOnly
        )
    }
    #expect(
        throws: BenchmarkStrokeRuntimeGateError.insufficientDuration(
            actual: 9_999_999_999,
            required: 10_000_000_000
        )
    ) {
        try BenchmarkStrokeRuntimeGate.validate(
            try runtimeGateEvidence(
                profile: .productionTenSeconds,
                actualReplay: 0,
                queues: [2, 1, 0],
                missed: 0,
                frames: 100,
                observedDuration: 9_999_999_999
            ),
            replayMode: .appendOnly
        )
    }
}

@Test
func productionTraceProfilesPinTenSecondAndAcceleratedTenMinuteDurations() {
    #expect(
        StrokeRuntimeTraceProfile.productionTenSeconds
            .logicalDurationNanoseconds == 10_000_000_000
    )
    #expect(
        StrokeRuntimeTraceProfile.productionAcceleratedTenMinutes
            .logicalDurationNanoseconds == 600_000_000_000
    )
    #expect(
        StrokeRuntimeTraceProfile.productionAcceleratedTenMinutes
            .isAccelerated
    )
    #expect(StrokeRuntimeTraceProfile.productionTenSeconds.isProduction)
    #expect(!StrokeRuntimeTraceProfile.syntheticTest.isProduction)
}

private final class SyntheticRuntimeTimestampSource:
    StrokeRuntimeTimestampSource, @unchecked Sendable
{
    private let lock = NSLock()
    private var timestamps: [UInt64]

    init(_ timestamps: [UInt64]) {
        self.timestamps = timestamps
    }

    func nowNanoseconds() -> UInt64 {
        lock.withLock {
            timestamps.removeFirst()
        }
    }
}

@MainActor
private func runtimeTestRenderer(
    device: any MTLDevice
) throws -> GridRenderer {
    let renderer = try GridRenderer(
        device: device,
        library: try strokeRuntimeTestLibrary(device: device),
        drawableSize: PatternSize(width: 64, height: 64),
        configuration: try TilingCanvasConfiguration(
            pixelSize: PixelSize(width: 64, height: 64),
            tiling: .grid
        )
    )
    try renderer.installNativeHarnessBrushes()
    return renderer
}

private func strokeRuntimeTestLibrary(
    device: any MTLDevice
) throws -> any MTLLibrary {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let shader = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/MetalRenderer/Shaders.metal"
        ),
        encoding: .utf8
    )
    let header = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/CShaderTypes/include/ShaderTypes.h"
        ),
        encoding: .utf8
    )
    return try device.makeLibrary(
        source: shader.replacingOccurrences(
            of: "#include \"ShaderTypes.h\"",
            with: header
        ),
        options: nil
    )
}

private func runtimeStrokeSample(
    x: Float,
    phase: StrokePhase,
    timestamp: TimeInterval
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: 0.75,
        timestamp: timestamp,
        phase: phase,
        source: .mouse,
        kind: .actual,
        capabilities: [.pressure]
    )
}

@MainActor
private func recordControllerFrame(
    _ controller: StrokeRuntimeProductionController,
    id: UInt64,
    input: UInt64,
    presented: UInt64,
    queue: Int
) throws {
    controller.recordInput(.actual, at: input)
    try controller.beginFrame(
        id: id,
        prepareStarted: input + 100,
        targetFrameDurationNanoseconds: 6_000_000_000
    )
    try controller.recordPrepared(
        id: id,
        at: input + 200,
        newLogicalDabCount: 1,
        newProjectedDabCount: 1,
        authoritativeReplayCount: 0,
        predictedReplayCount: 0,
        authoritativeQueueDepth: queue,
        predictedQueueDepth: 0,
        cacheHitCount: 0,
        cacheMissCount: 0,
        residentMemoryBytes: 1
    )
    try controller.recordSubmitted(id: id, at: input + 300)
    try controller.recordGPU(
        id: id,
        started: input + 400,
        finished: input + 500
    )
    _ = try controller.recordPresented(id: id, at: presented)
}

@MainActor
private func finishControllerFrame(
    _ controller: StrokeRuntimeProductionController,
    id: UInt64,
    base: UInt64,
    submitted: UInt64
) throws {
    try controller.recordPrepared(
        id: id,
        at: base + 20,
        newLogicalDabCount: 1,
        newProjectedDabCount: 1,
        authoritativeReplayCount: 0,
        predictedReplayCount: 0,
        authoritativeQueueDepth: 0,
        predictedQueueDepth: 0,
        cacheHitCount: 0,
        cacheMissCount: 0,
        residentMemoryBytes: 0
    )
    try controller.recordSubmitted(id: id, at: submitted)
    try controller.recordGPU(
        id: id,
        started: submitted + 10,
        finished: submitted + 20
    )
    _ = try controller.recordPresented(id: id, at: submitted + 30)
}

private func runtimeFrame(
    strokeID: UUID,
    input: UInt64,
    submitted: UInt64,
    gpuStarted: UInt64,
    gpuFinished: UInt64,
    presented: UInt64,
    queue: Int
) -> StrokeRuntimeFrameSample {
    StrokeRuntimeFrameSample(
        strokeID: strokeID,
        timestamps: StrokeRuntimeFrameTimestamps(
            input: input,
            prepareStarted: input + 100,
            prepareFinished: input + 200,
            submitted: submitted,
            gpuStarted: gpuStarted,
            gpuFinished: gpuFinished,
            presented: presented
        ),
        targetFrameDurationNanoseconds: 1_000,
        newLogicalDabCount: 1,
        newProjectedDabCount: 1,
        authoritativeReplayCount: 0,
        predictedReplayCount: 0,
        authoritativeQueueDepth: queue,
        predictedQueueDepth: 0,
        cacheHitCount: 0,
        cacheMissCount: 0,
        residentMemoryBytes: 0
    )
}

@MainActor
private func runtimeGateEvidence(
    profile: StrokeRuntimeTraceProfile,
    actualReplay: UInt64,
    queues: [Int],
    missed: UInt64,
    frames: UInt64,
    observedDuration: UInt64? = nil
) throws -> StrokeRuntimeRecordedEvidence {
    let wallDuration = observedDuration
        ?? max(
            profile.requiredWallDurationNanoseconds,
            frames * 10_000
        )
    let controller = StrokeRuntimeProductionController(
        traceProfile: profile,
        windowCapacity: max(3, Int(frames)),
        timestampSource: SyntheticRuntimeTimestampSource([0, wallDuration])
    )
    _ = try controller.beginStroke(strokeID: UUID())
    let usableDuration = wallDuration > 3_000
        ? wallDuration - 3_000
        : 0
    for index in 0..<frames {
        let base = frames > 1
            ? usableDuration * index / (frames - 1)
            : 0
        let queue: Int
        if Int(index) < queues.count {
            queue = queues[Int(index)]
        } else {
            queue = index.isMultiple(of: 2) ? 0 : 1
        }
        controller.recordInput(.actual, at: base)
        try controller.beginFrame(
            id: index,
            prepareStarted: base + 1,
            targetFrameDurationNanoseconds: 1_000
        )
        try controller.recordPrepared(
            id: index,
            at: base + 2,
            newLogicalDabCount: 1,
            newProjectedDabCount: 1,
            authoritativeReplayCount: index == 0 ? actualReplay : 0,
            predictedReplayCount: 0,
            authoritativeQueueDepth: queue,
            predictedQueueDepth: 0,
            cacheHitCount: 0,
            cacheMissCount: 0,
            residentMemoryBytes: 1
        )
        let submitted = base + (index < missed ? 2_000 : 3)
        try controller.recordSubmitted(id: index, at: submitted)
        _ = try controller.recordGPU(
            id: index,
            started: submitted + 1,
            finished: submitted + 2
        )
        _ = try controller.recordPresented(
            id: index,
            at: index == frames - 1 ? wallDuration : base + 3_000
        )
    }
    _ = try controller.endStroke()
    return try #require(controller.recordedEvidence)
}

private func runtimeGateSnapshot(
    profile: StrokeRuntimeTraceProfile,
    actualReplay: UInt64,
    queues: [Int],
    missed: UInt64,
    frames: UInt64,
    observedDuration: UInt64? = nil,
    origin: StrokeRuntimeRecorderOrigin = .productionRenderer
) -> StrokeRuntimeTelemetrySnapshot {
    let wallDuration = observedDuration ?? profile.requiredWallDurationNanoseconds
    let longestGrowthRun = zip(queues, queues.dropFirst()).reduce(
        into: (current: UInt64(1), longest: UInt64(0), grew: false)
    ) { state, pair in
        if pair.1 >= pair.0 {
            state.current += 1
            state.grew = state.grew || pair.1 > pair.0
            if state.grew {
                state.longest = max(state.longest, state.current)
            }
        } else {
            state = (1, state.longest, false)
        }
    }.longest
    var snapshot = StrokeRuntimeTelemetrySnapshot(
        sessionID: UUID(),
        segmentID: UUID(),
        strokeID: UUID(),
        traceProfile: profile,
        inputProvenance: .init(
            actual: frames,
            coalesced: 0,
            predicted: 0,
            estimatedUpdate: 0
        ),
        newLogicalDabCount: 1,
        newProjectedDabCount: 1,
        authoritativeReplayCount: actualReplay,
        predictedReplayCount: 0,
        authoritativeQueueDepth: queues.last ?? 0,
        predictedQueueDepth: 0,
        authoritativeQueueHighWater: queues.max() ?? 0,
        predictedQueueHighWater: 0,
        prepare: .init(p50: 1, p95: 1, p99: 1),
        eventToSubmit: .init(p50: 2, p95: 2, p99: 2),
        gpu: .init(p50: 1, p95: 1, p99: 1),
        frame: .zero,
        missedFrameCount: missed,
        eventToSubmitMissCount: missed,
        frameCount: frames,
        attributedFrameCount: frames,
        observedDurationNanoseconds: wallDuration,
        wallDurationNanoseconds: wallDuration,
        logicalDurationNanoseconds: profile.logicalDuration(
            forWallDuration: wallDuration
        ),
        cacheHitCount: 0,
        cacheMissCount: 0,
        memoryHighWaterBytes: 0,
        authoritativeQueueDepths: queues,
        lastTimestamps: StrokeRuntimeFrameTimestamps(
            input: wallDuration > 6 ? wallDuration - 6 : 0,
            prepareStarted: wallDuration > 5 ? wallDuration - 5 : 0,
            prepareFinished: wallDuration > 4 ? wallDuration - 4 : 0,
            submitted: wallDuration > 3 ? wallDuration - 3 : 0,
            gpuStarted: wallDuration > 2 ? wallDuration - 2 : 0,
            gpuFinished: wallDuration > 1 ? wallDuration - 1 : 0,
            presented: wallDuration
        )
    )
    snapshot.attest(
        origin: origin,
        traceProfile: profile,
        completeFrameEventCount: frames,
        queueObservationCount: frames,
        longestBacklogGrowthRun: longestGrowthRun,
        firstInputTimestamp: 0,
        lastPresentationTimestamp: wallDuration
    )
    return snapshot
}
