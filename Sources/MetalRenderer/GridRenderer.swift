import CShaderTypes
import EditorCore
import Foundation
import Metal
import MetalKit
import PatternEngine

protocol InteractiveStrokePaintCommitGating: Sendable {
    func waitBeforeCommit() async
}

public struct GridStructuralCounters: Equatable, Sendable {
    public var newDabsThisEvent = 0
    public var totalDabsThisStroke = 0
    public var newInstancesThisFrame = 0
    public var totalInstancesThisStroke = 0
    public var renderedFramesThisStroke = 0

    public init() {}
}

public struct BrushLabRendererDiagnosticSnapshot: Equatable, Sendable {
    public let totalDabsThisStroke: Int
    public let totalInstancesThisStroke: Int
    public let renderedFramesThisStroke: Int
    public let actualDabCount: Int
    public let predictedDabCount: Int
    public let replayCount: UInt64
    public let dirtyRegionCount: Int
    public let rasterRevisionResidentBytes: Int
    public let builtInTextureCount: Int
    public let assetFallbackCount: Int
    public let viewportDrawableSize: PatternSize
    public let viewportWorldCenter: WorldPoint
    public let viewportZoom: Float
    public let rendererEvents: BrushLabRendererEventDiagnosticSnapshot
    public let deposition: BrushLabRendererDepositionDiagnosticSnapshot

    public init(
        totalDabsThisStroke: Int,
        totalInstancesThisStroke: Int,
        renderedFramesThisStroke: Int,
        actualDabCount: Int,
        predictedDabCount: Int,
        replayCount: UInt64,
        dirtyRegionCount: Int,
        rasterRevisionResidentBytes: Int,
        builtInTextureCount: Int,
        assetFallbackCount: Int,
        viewportDrawableSize: PatternSize,
        viewportWorldCenter: WorldPoint,
        viewportZoom: Float,
        rendererEvents: BrushLabRendererEventDiagnosticSnapshot,
        deposition: BrushLabRendererDepositionDiagnosticSnapshot
    ) {
        self.totalDabsThisStroke = totalDabsThisStroke
        self.totalInstancesThisStroke = totalInstancesThisStroke
        self.renderedFramesThisStroke = renderedFramesThisStroke
        self.actualDabCount = actualDabCount
        self.predictedDabCount = predictedDabCount
        self.replayCount = replayCount
        self.dirtyRegionCount = dirtyRegionCount
        self.rasterRevisionResidentBytes = rasterRevisionResidentBytes
        self.builtInTextureCount = builtInTextureCount
        self.assetFallbackCount = assetFallbackCount
        self.viewportDrawableSize = viewportDrawableSize
        self.viewportWorldCenter = viewportWorldCenter
        self.viewportZoom = viewportZoom
        self.rendererEvents = rendererEvents
        self.deposition = deposition
    }
}

public struct BrushLabRendererEventDiagnosticSnapshot:
    Equatable, Sendable
{
    public let pendingEventCount: Int
    public let pendingHighWater: Int
    public let staleGenerationDiscardCount: UInt64
    public let scheduledContinuationCount: UInt64

    public init(
        pendingEventCount: Int,
        pendingHighWater: Int,
        staleGenerationDiscardCount: UInt64,
        scheduledContinuationCount: UInt64
    ) {
        self.pendingEventCount = pendingEventCount
        self.pendingHighWater = pendingHighWater
        self.staleGenerationDiscardCount = staleGenerationDiscardCount
        self.scheduledContinuationCount = scheduledContinuationCount
    }
}

public struct BrushLabRendererDepositionDiagnosticSnapshot:
    Equatable, Sendable
{
    public let authoritativePending: Int
    public let predictedPending: Int
    public let authoritativeHighWater: Int
    public let predictedHighWater: Int
    public let backlogHighWater: Int
    public let lastFrameEncodedDabCount: Int
    public let lastFrameEncodedInstanceCount: Int
    public let strokeEncodedDabCount: UInt64
    public let strokeEncodedInstanceCount: UInt64
    public let currentBufferLeaseCount: Int
    public let strokeBufferLeaseHighWater: Int
    public let lifetimeBufferLeaseHighWater: Int
    public let missedFrameCount: UInt64
    public let eventToSubmit: DepositionDurationPercentiles
    public let cpuPreparation: DepositionDurationPercentiles
    public let gpuCompletion: DepositionDurationPercentiles

    public var bufferLeaseHighWater: Int {
        strokeBufferLeaseHighWater
    }
}

public struct HarnessLiveFlushResult {
    public let frame: RenderedFrame
    public let metrics: GPUFrameMetrics
    public let emittedHighWater: UInt64
    public let encodedIdentityRanges: [Range<UInt64>]
    public let authoritativeBacklogRemaining: Int
    public let replayRetention: HarnessReplayRetentionSnapshot
}

public struct HarnessReplayRetentionSnapshot: Equatable, Sendable {
    public let retainedDabCount: Int
    public let visibleProjectedInstanceCount: Int
}

package struct OffMainStrokeProductionTraceSnapshot: Sendable {
    package let inputSampleCount: Int
    package let logicalDurationNanoseconds: UInt64
    package let wallDurationNanoseconds: UInt64
    package let firstDecileNanosecondsPerEvent: UInt64
    package let lastDecileNanosecondsPerEvent: UInt64
    package let authoritativeInputHighWater: Int
    package let authoritativeInputCapacity: Int
    package let authoritativeInputInitialStorageCapacity: Int
    package let authoritativeInputStorageCapacity: Int
    package let predictionInputCapacity: Int
    package let predictionInputInitialStorageCapacity: Int
    package let predictionInputStorageCapacity: Int
    package let resultHighWater: Int
    package let resultCapacity: Int
    package let resultInitialStorageCapacity: Int
    package let resultStorageCapacity: Int
    package let workspaceInitialInstallationCount: UInt64
    package let workspaceInstallationCount: UInt64
    package let workspaceIdentityStayedStable: Bool
    package let maximumPreparedPayloadBytes: Int
    package let surface: StrokePrivateSurfaceEncoderSnapshot
    package let missedLogicalFrameCount: Int
    package let deferredDrainCount: Int
    package let zeroWorkLeaseCount: Int
    package let allPreparationAndEncodingOffMain: Bool
}

private struct OffMainStrokeTraceDrainOutcome {
    let coordinatorSnapshot: StrokeRenderSnapshot
    let surfaceSnapshot: StrokePrivateSurfaceEncoderSnapshot
    let deferredDrainCount: Int
    let zeroWorkLeaseCount: Int
    let commitBarrierReached: Bool
    let allPreparationAndEncodingOffMain: Bool
    let preparationCPUNanoseconds: UInt64
}

private struct OffMainStrokeTraceCommandOutcome: Sendable {
    let succeeded: Bool
    let errorMessage: String?
}

private struct OffMainStrokeTraceInactivityWatchdog {
    let timeoutNanoseconds: UInt64
    private(set) var lastProgressUptimeNanoseconds:
        UInt64 = DispatchTime.now().uptimeNanoseconds

    mutating func recordProgress() {
        lastProgressUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    var hasExpired: Bool {
        elapsedNanoseconds >= timeoutNanoseconds
    }

    var waitDeadline: Date {
        let remaining = timeoutNanoseconds > elapsedNanoseconds
            ? timeoutNanoseconds - elapsedNanoseconds
            : 0
        // Date is required by the condition wait, but it is only used for a
        // short polling slice. The actual inactivity budget is monotonic.
        let waitSeconds = min(
            0.25,
            max(0.001, Double(remaining) / 1_000_000_000)
        )
        return Date(timeIntervalSinceNow: waitSeconds)
    }

    private var elapsedNanoseconds: UInt64 {
        DispatchTime.now().uptimeNanoseconds
            &- lastProgressUptimeNanoseconds
    }
}

@MainActor
public final class GridRenderer: NSObject, MTKViewDelegate {
    enum PaintDisplayPreparationAction: Equatable, Sendable {
        case stable
        case transient
        case fail(StrokePreparationAcknowledgementError)
    }

    nonisolated static func paintDisplayPreparationAction(
        for status: StrokePreparedFrameAcknowledgementStatus?
    ) -> PaintDisplayPreparationAction {
        switch status {
        case nil, .pending, .fulfilled:
            .stable
        case .available:
            .transient
        case let .failed(error):
            .fail(error)
        }
    }

    nonisolated static func isDeferredPaintDisplayPreparationFailure(
        _ error: Error
    ) -> Bool {
        error as? DocumentPaintVisiblePlanControllerError
            == .transientSourceNotAvailable
    }

    public let device: any MTLDevice
    public let historyByteBudget: Int
    public var layerStack: LayerStack { paintContext.layerStack }
    private var documentPixelSizeState: PixelSize
    private var storagePixelSizeState: PixelSize
    public var pixelSize: PixelSize { documentPixelSizeState }
    var storagePixelSize: PixelSize { storagePixelSizeState }
    public private(set) var lastError: MetalRendererError?
    public var onError: ((MetalRendererError) -> Void)?
    public var onIdleStateChange: ((Bool) -> Void)?
    public var onOperationCompleted: ((RendererOperationCompletion) -> Void)?
    public var onLogicalDabsGenerated: ((LogicalDab) -> Void)?
    public var onStrokeRuntimeSnapshot:
        ((StrokeRuntimeTelemetrySnapshot) -> Void)?
    public var onStrokeRuntimeSegmentMarker:
        ((StrokeRuntimeSegmentMarker) -> Void)?
    #if DEBUG
    public var onInteractiveFramePresented: ((TimeInterval, Int) -> Void)?
    public var onInteractiveFrameMetrics: ((GPUFrameMetrics) -> Void)?
    #endif
    public private(set) var viewport: ViewportTransform
    public internal(set) var counters = GridStructuralCounters()
    private var brushLabActualDabCount = 0
    private var brushLabPredictedDabCount = 0
    private lazy var rendererEventDispatcher = RendererEventDispatcher {
        [weak self] event in
        self?.deliverRendererEvent(event)
    }
    private var strokeEventGeneration: UInt64?
    private var telemetryEventGeneration: UInt64?
    private var strokeRuntimeController: StrokeRuntimeProductionController?
    private let interactiveBrushTraceRecorder:
        InteractiveBrushTraceRecorder
    private let interactiveStrokePresentationCache:
        InteractiveStrokePresentationCache
    private struct PendingInteractiveBrushInputTrace {
        let sample: StrokeSample
        let lineage: InteractiveBrushInputTrace
    }
    private var pendingInteractiveBrushInputTraces:
        [PendingInteractiveBrushInputTrace] = []
    struct StrokeRuntimeFrameIdentity: Hashable {
        let telemetryGeneration: UInt64
        let frameID: UInt64
    }
    private var nextStrokeRuntimeFrameID: UInt64 = 1
    private var pendingStrokeRuntimeFrameIDs:
        Set<StrokeRuntimeFrameIdentity> = []
    public private(set) var interactiveGridVisibility = false
    public var isIdle: Bool {
        activeStroke == nil
            && paintCommitTask == nil
            && strokeWorkspaceState == .available
            && interactiveStrokeCacheLifecycleEpochs.isEmpty
    }
    public var strokeRuntimeSnapshot: StrokeRuntimeTelemetrySnapshot? {
        strokeRuntimeController?.snapshot
    }
    public var strokeRuntimeRecordedEvidence: StrokeRuntimeRecordedEvidence? {
        strokeRuntimeController?.recordedEvidence
    }

    public func configureInteractiveBrushTrace(
        sink: (any InteractiveBrushTraceSink)?
    ) {
        pendingInteractiveBrushInputTraces.removeAll(keepingCapacity: true)
        interactiveBrushTraceRecorder.configure(sink: sink)
    }

    public func recordInteractiveBrushInputReceipt(
        sample: StrokeSample,
        identity: StrokeTraceIdentity,
        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard interactiveBrushTraceRecorder.isEnabled else { return }
        if sample.phase == .began {
            pendingInteractiveBrushInputTraces.removeAll(keepingCapacity: true)
        } else if pendingInteractiveBrushInputTraces.count == 8_192 {
            pendingInteractiveBrushInputTraces.removeFirst()
        }
        let lineage = InteractiveBrushInputTrace(
            identity: identity,
            eventReceiptMonotonicNanoseconds: monotonicNanoseconds
        )
        pendingInteractiveBrushInputTraces.append(
            PendingInteractiveBrushInputTrace(
                sample: sample,
                lineage: lineage
            )
        )
        interactiveBrushTraceRecorder.record(
            stage: .eventReceived,
            lineage: lineage,
            monotonicNanoseconds: monotonicNanoseconds
        )
    }

    public func configureStrokeRuntimeTelemetry(
        profile: StrokeRuntimeTraceProfile,
        sessionID: UUID = UUID(),
        windowCapacity: Int = 600
    ) {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        invalidateTelemetryEventGeneration()
        strokeRuntimeController = StrokeRuntimeProductionController(
            sessionID: sessionID,
            traceProfile: profile,
            windowCapacity: windowCapacity
        )
        nextStrokeRuntimeFrameID = 1
        pendingStrokeRuntimeFrameIDs.removeAll(keepingCapacity: true)
        let generation = rendererEventDispatcher
            .advanceTelemetryGeneration()
        telemetryEventGeneration = generation
        stageRendererEvent(
            .strokeRuntimeSnapshot(
                generation: generation,
                snapshot: strokeRuntimeController!.snapshot
            )
        )
    }

    public func disableStrokeRuntimeTelemetry() {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        invalidateTelemetryEventGeneration()
        strokeRuntimeController = nil
        pendingStrokeRuntimeFrameIDs.removeAll(keepingCapacity: true)
    }
    public var hasActiveStroke: Bool {
        guard let activeStroke else { return false }
        return !activeStroke.commitRequested
    }
    public var tiling: TilingKind { tilingStrategy.kind }
    public var brushLabDiagnosticSnapshot:
        BrushLabRendererDiagnosticSnapshot
    {
        let scheduler = activeStroke?.frozenHarnessScheduler?
            .diagnosticSnapshot
        let telemetry = brushLabDepositionTelemetry.snapshot
        let timings = brushLabDepositionTelemetry.timings
        let pool = instancePool.diagnosticSnapshot
        let rendererEvents = rendererEventDispatcher.diagnostics
        let activeDirtyCoordinateCount = activePaintTransientSource?
            .changedCoordinateSets.reduce(0) { $0 + $1.count } ?? 0
        return BrushLabRendererDiagnosticSnapshot(
            totalDabsThisStroke: counters.totalDabsThisStroke,
            totalInstancesThisStroke: counters.totalInstancesThisStroke,
            renderedFramesThisStroke: counters.renderedFramesThisStroke,
            actualDabCount: brushLabActualDabCount,
            predictedDabCount: brushLabPredictedDabCount,
            replayCount: 0,
            dirtyRegionCount: activeDirtyCoordinateCount,
            rasterRevisionResidentBytes: paintRevisionResidentBytesState,
            builtInTextureCount:
                (activeDrawBrush.map(uniqueTextureCount) ?? 0)
                    + (activeEraserBrush.map(uniqueTextureCount) ?? 0),
            assetFallbackCount: 0,
            viewportDrawableSize: viewport.drawableSize,
            viewportWorldCenter: viewport.worldCenter,
            viewportZoom: viewport.zoom,
            rendererEvents: BrushLabRendererEventDiagnosticSnapshot(
                pendingEventCount: rendererEvents.pendingEventCount,
                pendingHighWater: rendererEvents.pendingHighWater,
                staleGenerationDiscardCount:
                    rendererEvents.staleGenerationDiscardCount,
                scheduledContinuationCount:
                    rendererEvents.scheduledContinuationCount
            ),
            deposition: BrushLabRendererDepositionDiagnosticSnapshot(
                authoritativePending:
                    scheduler?.authoritativePending
                        ?? telemetry.authoritativeBacklog,
                predictedPending:
                    scheduler?.predictedPending
                        ?? telemetry.predictedBacklog,
                authoritativeHighWater: max(
                    scheduler?.authoritativeHighWater ?? 0,
                    brushLabAuthoritativeHighWater
                ),
                predictedHighWater: max(
                    scheduler?.predictedHighWater ?? 0,
                    brushLabPredictedHighWater
                ),
                backlogHighWater: telemetry.backlogHighWater,
                lastFrameEncodedDabCount:
                    brushLabLastFrameEncodedDabCount,
                lastFrameEncodedInstanceCount:
                    brushLabLastFrameEncodedInstanceCount,
                strokeEncodedDabCount: brushLabStrokeEncodedDabCount,
                strokeEncodedInstanceCount:
                    telemetry.encodedInstanceCount,
                currentBufferLeaseCount: pool.currentLeaseCount,
                strokeBufferLeaseHighWater:
                    pool.strokeLeaseHighWater,
                lifetimeBufferLeaseHighWater:
                    pool.lifetimeLeaseHighWater,
                missedFrameCount: telemetry.missedFrameCount,
                eventToSubmit: timings.eventToSubmit,
                cpuPreparation: timings.cpuPreparation,
                gpuCompletion: timings.gpuCompletion
            )
        )
    }
    public var inputPathStorageDiagnosticSnapshot:
        InputPathStorageDiagnosticSnapshot
    {
        inputPathStorageAudit.snapshot
    }

    public var periodicConfiguration: PeriodicSymmetryConfiguration {
        tilingStrategy.periodicConfiguration
    }
    public var documentConfiguration: SymmetryDocumentConfiguration {
        tilingStrategy.documentConfiguration
    }
    public var finiteConfiguration: FiniteSymmetryConfiguration? {
        tilingStrategy.finiteConfiguration
    }
    public internal(set) var radialGeometryLocked = false
    public internal(set) var documentDomainLocked = false

    struct ActiveStrokeExecution {
        let token: RendererOperationToken
        let style: StrokeRenderStyle
        let brush: CompiledBrushRenderState
        let renderIdentity: BrushRenderIdentity
        /// Scheduler retained only by deterministic projected-dab harnesses.
        /// Interactive compiled-brush strokes always leave this nil.
        var frozenHarnessScheduler: FrameScheduler?
        var commitRequested: Bool
        var isFinishedTransiently: Bool
    }

    struct PredictionSubmissionScratchSnapshot: Equatable, Sendable {
        let count: Int
        let highWater: Int
        let storageCapacity: Int
        let storageIdentity: UInt
        let storageReallocationCount: UInt64
        let lastSubmittedSampleCount: Int
        let lastAcceptedSampleCount: Int
        let lastShedSampleCount: Int
        let lastValidatedSampleCount: Int
        let lastTelemetrySampleCount: Int
    }

    let commandQueue: any MTLCommandQueue
    public let library: any MTLLibrary
    private let paintContext: DocumentPaintRenderContext
    private var paintOutputGeometryRevision: UInt64 = 0
    private var paintViewportRevision: UInt64 = 0
    private var paintBackingScaleRevision: UInt64 = 1
    private var paintBackingScale: SIMD2<Float>?
    private var paintDisplayPreparationSequence: UInt64 = 0
    private var interactiveFramePump = InteractiveFramePump()
    private var drawablePresentationRegistrar:
        (any DrawablePresentationRegistering)?
    private var presentationContinuationRequestCount = 0
    private var pendingLatestPaintDisplaySnapshot:
        CanvasPresentationSnapshot?
    private var activePaintDisplayPreparationRevision:
        CanvasPresentationRevision?
    private var paintDisplayPreparationTask: Task<Void, Never>?
    private var retiringPaintDisplayPreparationTask: Task<Void, Never>?
    private var retiringPaintDisplayPreparationRevision:
        CanvasPresentationRevision?
    private var paintDisplayPreparationRetirementMonitor: Task<Void, Never>?
    private var activePaintDisplayPreparationRetirementSequence: UInt64?
    private var nextPaintDisplayPreparationRetirementSequence: UInt64 = 0
    private var paintDisplayPreparationScheduleCount: UInt64 = 0
    private struct PreparedPaintDisplay {
        let snapshot: CanvasPresentationSnapshot
        let submission: PreparedLayerCompositeDisplaySubmission
    }
    private var preparedPaintDisplay: PreparedPaintDisplay?
    private var presentationPreparationGate:
        (any PresentationPreparationGating)?
    #if DEBUG
    private var paintDisplayAcknowledgementStatusOverrideForTesting:
        StrokePreparedFrameAcknowledgementStatus?
    private var paintRevisionReleaseFailureForTesting: MetalRendererError?
    private var paintStrokeCommitFailureForTesting: MetalRendererError?
    private var paintStrokeCommitGateForTesting:
        (any InteractiveStrokePaintCommitGating)?
    #endif
    #if DEBUG
    private var paintDisplayPublishedRevisions:
        [CanvasPresentationRevision] = []
    #endif
    private var paintDisplayPreparationIsSuspended = false
    package var paintDisplayPreparationIsSuspendedForTesting: Bool {
        paintDisplayPreparationIsSuspended
    }
    package var paintDisplayPreparationIsRetiringForTesting: Bool {
        retiringPaintDisplayPreparationTask != nil
    }
    package var paintDisplayPreparationScheduleCountForTesting: UInt64 {
        paintDisplayPreparationScheduleCount
    }
    #if DEBUG
    package var paintDisplayPublishedRevisionsForTesting:
        [CanvasPresentationRevision]
    {
        paintDisplayPublishedRevisions
    }
    #endif
    package var paintDisplayPreparationOwnershipCountForTesting: Int {
        (paintDisplayPreparationTask == nil ? 0 : 1)
            + (retiringPaintDisplayPreparationTask == nil ? 0 : 1)
    }
    package var interactiveFrameHasDemandForTesting: Bool {
        interactiveFramePump.hasDemand
    }
    package var presentationContinuationRequestCountForTesting: Int {
        presentationContinuationRequestCount
    }
    package func installDrawablePresentationRegistrarForTesting(
        _ registrar: any DrawablePresentationRegistering
    ) {
        drawablePresentationRegistrar = registrar
    }
    package func signalInteractivePresentationDemandForTesting(
        _ revision: CanvasPresentationRevision
    ) {
        interactiveFramePump.signal(.cachePublished(revision))
    }
    package func submitInteractivePresentationForTesting(
        _ revision: CanvasPresentationRevision,
        in view: MTKView
    ) {
        interactiveFramePump.signal(.cachePublished(revision))
        _ = interactiveFramePump.beginFrame()
        finishInteractiveFrame(.submitted(revision), in: view)
        registerDrawablePresentation(
            revision: revision,
            drawable: nil,
            in: view
        )
    }
    package func handleInteractiveCommandCompletionForTesting(
        in view: MTKView
    ) {
        requestInteractiveFrameAfterCommandCompletion(in: view)
    }
    package func installPresentationPreparationGateForTesting(
        _ gate: any PresentationPreparationGating
    ) {
        precondition(paintDisplayPreparationTask == nil)
        precondition(retiringPaintDisplayPreparationTask == nil)
        presentationPreparationGate = gate
    }
    #if DEBUG
    package func installFailedTransientAcknowledgementForTesting() {
        paintDisplayAcknowledgementStatusOverrideForTesting = .failed(
            .schedulerReleaseFailed(
                .unexpected("injected acknowledgement failure")
            )
        )
        invalidatePaintDisplayPreparation()
    }
    package func installPaintRevisionReleaseFailureForTesting(
        _ error: MetalRendererError
    ) {
        paintRevisionReleaseFailureForTesting = error
    }
    package func installPaintStrokeCommitFailureForTesting(
        _ error: MetalRendererError
    ) {
        paintStrokeCommitFailureForTesting = error
    }
    func installPaintStrokeCommitGateForTesting(
        _ gate: any InteractiveStrokePaintCommitGating
    ) {
        paintStrokeCommitGateForTesting = gate
    }
    package func installAfterPaintMutationPublicationHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) async {
        await paintContext.testingSetAfterMutationPublicationHook(hook)
    }
    package func installBeforePaintMutationPublicationClaimHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) async {
        await paintContext
            .testingSetBeforeMutationPublicationClaimHook(hook)
    }
    package var paintDisplayPreparationRevisionForTesting: UInt64 {
        paintDisplayPreparationSequence
    }
    #endif
    package func installPaintDisplayPreparationTaskForTesting(
        _ task: Task<Void, Never>
    ) {
        paintDisplayPreparationTask = task
        activePaintDisplayPreparationRevision = nil
    }
    private var activePaintTransientSource:
        DocumentPaintTransientDisplaySource?
    private var interactiveStrokeCacheAdoptionTask: Task<Void, Never>?
    private var interactiveStrokeCacheLifecycleEpochs: Set<UUID> = []
    private var interactiveStrokeCacheLifecycleEpochObjects:
        [UUID: DocumentPaintStrokePresentationEpoch] = [:]
    private var lastInteractiveStrokeCacheLifecycleIdentity: UUID?
    private var nextInteractiveStrokeCacheSequence: UInt64 = 1
    private var paintCommitTask: Task<Void, Never>?
    private var paintCommitPublicationState: StrokeCommitPublicationState?
    private var paintLifecycleTask: Task<Void, Never>?
    private var paintCommandError: MetalRendererError?
    private var strokeWorkspaceRetirementErrorWasReported = false
    private var paintRevisionResidentBytesState = 0
    private var pendingPaintHarnessDabCount = 0
    private var pendingPaintHarnessInstanceCount = 0
    private weak var paintDisplayView: MTKView?
    private var exclusiveInteractiveCompletionDrainInProgress = false
    var depositionFrameBudget: DepositionFrameBudget
    private(set) var activeDrawBrush: CompiledBrush?
    private(set) var activeEraserBrush: CompiledBrush?
    private var activeDrawBrushRenderState: CompiledBrushRenderState?
    private var activeEraserBrushRenderState: CompiledBrushRenderState?
    let instancePool: DabInstanceBufferPool
    var depositionEncoder: DepositionEncoder?
    private var brushLabDepositionTelemetry = DepositionTelemetry()
    private var brushLabAuthoritativeHighWater = 0
    private var brushLabPredictedHighWater = 0
    private var brushLabLastFrameEncodedDabCount = 0
    private var brushLabLastFrameEncodedInstanceCount = 0
    private var brushLabStrokeEncodedDabCount: UInt64 = 0
    private var brushLabPendingInputReceiptNanoseconds: UInt64?
    private var inputPathStorageAudit = InputPathStorageAudit()
    package private(set) var scheduledAuthoritativeIdentityHighWater: UInt64 = 0
    private var encodedAuthoritativeIdentityHighWater: UInt64 = 0
    private var pendingEncodedAuthoritativeIdentityRange: Range<UInt64>?
    private var activeStrokeTileSurfaceResources: StrokeTileSurfaceResources?
    var tileSize: PatternSize {
        PatternSize(
            width: Float(storagePixelSizeState.width),
            height: Float(storagePixelSizeState.height)
        )
    }
    var tilingStrategy: TilingStrategy
    var activeStroke: ActiveStrokeExecution?
    private var strokePreparationBridge: StrokePreparationBridge?
    private var warmedStrokePreparationBridge: StrokePreparationBridge
    private enum StrokeWorkspaceState: Equatable {
        case available
        case borrowed(UInt64)
        case retiring(UInt64)
    }
    private var strokeWorkspaceState = StrokeWorkspaceState.available
    private var strokePreparationGeneration: UInt64?
    private var strokePreparationAllocationProbe:
        StrokePreparationAllocationProbe?
    private var strokePreparationResultScratch:
        [StrokePreparationResult] = []
    private var predictionSubmissionScratch: [StrokeSample] = []
    private var predictionSubmissionScratchHighWater = 0
    private var predictionSubmissionScratchStorageIdentity: UInt = 0
    private var predictionSubmissionScratchStorageReallocationCount: UInt64 = 0
    private var predictionSubmissionLastSubmittedSampleCount = 0
    private var predictionSubmissionLastAcceptedSampleCount = 0
    private var predictionSubmissionLastShedSampleCount = 0
    private var predictionSubmissionLastValidatedSampleCount = 0
    private var predictionSubmissionLastTelemetrySampleCount = 0
    var compositeLiveIsVisible: Bool {
        activePaintTransientSource != nil
    }
    private var lastOffMainCoordinatorSnapshot: StrokeRenderSnapshot?
    private var lastOffMainReplayRetention = StrokePreparedReplayRetention(
        retainedDabCount: 0,
        visibleProjectedInstanceCount: 0
    )
    private var lastOffMainEncodingRanOnMainThread: Bool?
    private var lastOffMainSurfaceSnapshot:
        StrokePrivateSurfaceEncoderSnapshot?
    private var lastOffMainZeroWorkLeaseCount = 0
    private var lastOffMainPredictedInstanceCount = 0
    private var nextHarnessTokenRawValue: UInt64 = 1

    private var forceOffMainStrokeCommandFailureForTesting = false

    public convenience init(
        device: any MTLDevice,
        drawableSize: PatternSize,
        configuration: TilingCanvasConfiguration,
        initialLayerStack: LayerStack = .initial(),
        historyByteBudget: Int = 200 * 1_024 * 1_024
    ) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.defaultLibraryUnavailable
        }
        try self.init(
            device: device,
            library: library,
            drawableSize: drawableSize,
            configuration: configuration,
            initialLayerStack: initialLayerStack,
            historyByteBudget: historyByteBudget
        )
    }

    public init(
        device: any MTLDevice,
        library: any MTLLibrary,
        drawableSize: PatternSize,
        configuration: TilingCanvasConfiguration,
        initialLayerStack: LayerStack = .initial(),
        historyByteBudget: Int = 200 * 1_024 * 1_024
    ) throws {
        ShaderABI.preconditionValid()
        guard historyByteBudget > 0 else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRendererError.commandQueueUnavailable
        }
        let strategy: TilingStrategy
        do {
            strategy = try TilingStrategy(
                documentConfiguration: configuration.documentConfiguration,
                canvasSize: configuration.pixelSize
            )
        } catch {
            throw MetalRendererError.invalidSymmetryConfiguration(
                error.localizedDescription
            )
        }
        let storageSize = PixelSize(
            width: Int(strategy.tileSize.width),
            height: Int(strategy.tileSize.height)
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: configuration.pixelSize,
            storagePixelSize: storageSize,
            radialLayout: strategy.compiledSymmetry.domain.finite?.radial.layout
        )
        let paintContext = try DocumentPaintRenderContext(
            device: device,
            commandQueue: commandQueue,
            library: library,
            geometry: geometry,
            initialLayerStack: initialLayerStack,
            byteBudget: 512 * 1_024 * 1_024,
            snapshotPayloadLiabilityByteBudget: 512 * 1_024 * 1_024,
            transferByteCapacity: 64 * 1_024 * 1_024,
            maximumRevisionBytes: historyByteBudget
        )
        let traceRecorder = InteractiveBrushTraceRecorder()
        let transientCacheByteBudget = 512 * 1_024 * 1_024
        let transientCacheBytesPerTile =
            PaintTileDescriptor.residentByteCount
            + DepositionComponentCoverage.residentByteCount(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side
            )!
        self.device = device
        self.historyByteBudget = historyByteBudget
        self.commandQueue = commandQueue
        self.library = library
        self.paintContext = paintContext
        interactiveBrushTraceRecorder = traceRecorder
        interactiveStrokePresentationCache =
            InteractiveStrokePresentationCache(
                device: device,
                commandQueue: commandQueue,
                byteBudget: transientCacheByteBudget,
                maximumTileCount:
                    transientCacheByteBudget / transientCacheBytesPerTile,
                traceRecorder: traceRecorder
            )
        documentPixelSizeState = configuration.pixelSize
        storagePixelSizeState = storageSize
        let frameBudget = try DepositionFrameBudget(
            cpuPreparationNanoseconds: 1_500_000,
            maximumAuthoritativeInstances:
                GridCanvasContract.instanceCapacity,
            maximumPredictedInstances:
                TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity,
            maximumPendingAuthoritativeInstances:
                GridCanvasContract.pendingCapacity,
            maximumPendingPredictedInstances:
                TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity,
            inFlightUploadBufferCount:
                GridCanvasContract.inFlightBufferCount
        )
        depositionFrameBudget = frameBudget
        activeStrokeTileSurfaceResources = nil
        warmedStrokePreparationBridge = StrokePreparationBridge(
            budget: frameBudget,
            targetFramesPerSecond: 120,
            traceRecorder: traceRecorder
        )
        activeDrawBrush = nil
        activeEraserBrush = nil
        tilingStrategy = strategy
        instancePool = try DabInstanceBufferPool(device: device)
        depositionEncoder = nil
        viewport = ViewportTransform(
            drawableSize: drawableSize,
            worldCenter: WorldPoint(
                x: Float(configuration.pixelSize.width) * 0.5,
                y: Float(configuration.pixelSize.height) * 0.5
            ),
            zoom: 1
        )
        strokePreparationResultScratch.reserveCapacity(1)
        predictionSubmissionScratch.reserveCapacity(
            PredictionAdmissionLimits.maximumNormalizedSampleCount
        )
        super.init()
        depositionEncoder = DepositionEncoder(
            instancePool: instancePool,
            frameUniforms: frameUniforms(
                drawableSize: tileSize,
                showGridLines: false,
                liveVisible: true
            )
        )
    }

    deinit {
        if paintCommitPublicationState?.claimFailure() != false {
            paintCommitTask?.cancel()
        }
        if let bridge = strokePreparationBridge,
           let generation = strokePreparationGeneration,
           strokeWorkspaceState == .borrowed(generation)
        {
            bridge.submitCancellation(
                generation: generation,
                reason: nil,
                frameDisposition: .preserveMainOwnership
            )
        }
        let cache = interactiveStrokePresentationCache
        var epochByIdentity = interactiveStrokeCacheLifecycleEpochObjects
        if let activeEpoch = activeStrokeTileSurfaceResources?
            .capability.presentationEpoch
        {
            epochByIdentity[activeEpoch.identity] = activeEpoch
        }
        let epochs = Array(epochByIdentity.values)
        Task { @MainActor [cache, epochs] in
            for epoch in epochs {
                InteractiveStrokeCacheLifecycleCoordinator.shared
                    .requestCancellation(cache: cache, strokeEpoch: epoch)
            }
        }
    }

    public func applyTiling(_ tiling: TilingKind) async throws {
        guard case .periodic = tilingStrategy.documentConfiguration else {
            throw MetalRendererError.documentDomainLocked
        }
        let current = tilingStrategy.periodicConfiguration
        let proposed: PeriodicSymmetryConfiguration
        if tiling.supportsSpacingAndOrientation {
            if current.presetID.supportsSpacingAndOrientation {
                proposed = PeriodicSymmetryConfiguration(
                    presetID: tiling,
                    repeatSize: current.repeatSize,
                    orientationRadians: current.orientationRadians
                )
            } else {
                proposed = .defaultConfiguration(
                    presetID: tiling,
                    canonicalRasterSize: pixelSize
                )
            }
        } else {
            proposed = PeriodicSymmetryConfiguration(
                presetID: tiling,
                repeatSize: current.repeatSize,
                orientationRadians: 0
            )
        }
        try await applyPeriodicConfiguration(proposed)
    }

    public func applyPeriodicConfiguration(
        _ configuration: PeriodicSymmetryConfiguration
    ) async throws {
        guard isIdle else {
            throw MetalRendererError.tilingChangeRequiresIdle
        }
        let proposed: TilingStrategy
        do {
            proposed = try TilingStrategy(
                configuration: configuration,
                canonicalRasterSize: pixelSize
            )
        } catch {
            throw MetalRendererError.invalidPeriodicConfiguration(
                error.localizedDescription
            )
        }
        if case .finite = tilingStrategy.documentConfiguration {
            try requireEmptyConfigurationChangeAllowed()
            try await installEmptyStrategy(proposed)
        } else {
            tilingStrategy = proposed
            invalidatePaintDisplayPreparation()
        }
    }

    public func applyFiniteConfiguration(
        _ configuration: FiniteSymmetryConfiguration
    ) async throws {
        try await replaceEmptyDocumentConfiguration(
            .finite(configuration),
            pixelSize: pixelSize
        )
    }

    public func replaceEmptyDocumentConfiguration(
        _ configuration: SymmetryDocumentConfiguration,
        pixelSize proposedPixelSize: PixelSize
    ) async throws {
        guard isIdle else {
            throw MetalRendererError.tilingChangeRequiresIdle
        }
        try requireEmptyConfigurationChangeAllowed()
        try validateTileSize(proposedPixelSize)
        let proposed: TilingStrategy
        do {
            proposed = try TilingStrategy(
                documentConfiguration: configuration,
                canvasSize: proposedPixelSize
            )
        } catch {
            switch configuration {
            case .periodic:
                throw MetalRendererError.invalidPeriodicConfiguration(
                    error.localizedDescription
                )
            case .finite:
                throw MetalRendererError.invalidSymmetryConfiguration(
                    error.localizedDescription
                )
            }
        }
        try await installEmptyStrategy(proposed)
    }

    public func reconcileGeometryLock(documentIsEmpty: Bool) throws {
        guard isIdle else {
            throw MetalRendererError.commitPendingInput
        }
        setDocumentGeometryLocked(!documentIsEmpty)
    }

    public func setFiniteConfiguration(
        _ configuration: FiniteSymmetryConfiguration
    ) async throws {
        try await applyFiniteConfiguration(configuration)
    }

    private func installEmptyStrategy(
        _ proposed: TilingStrategy
    ) async throws {
        let canvasSizeChanged = proposed.canvasSize != pixelSize
        let proposedStorageSize = PixelSize(
            width: Int(proposed.tileSize.width),
            height: Int(proposed.tileSize.height)
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: proposed.canvasSize,
            storagePixelSize: proposedStorageSize,
            radialLayout:
                proposed.compiledSymmetry.domain.finite?.radial.layout
        )
        let result = try await paintContext.resize(
            to: geometry,
            targetRadialConfiguration:
                proposed.compiledSymmetry.domain.finite?.radial.configuration
        )
        if let result {
            guard let revision = result.revision else {
                throw MetalRendererError.commandFailed(
                    "Published geometry change has no history revision."
                )
            }
            try await paintContext.releaseRevisions([revision.id])
        }
        await refreshPaintRevisionResidentBytes()
        tilingStrategy = proposed
        documentPixelSizeState = proposed.canvasSize
        storagePixelSizeState = proposedStorageSize
        setDocumentGeometryLocked(false)
        invalidatePaintDisplayPreparation()
        if canvasSizeChanged {
            viewport = ViewportTransform(
                drawableSize: viewport.drawableSize,
                worldCenter: WorldPoint(
                    x: Float(proposed.canvasSize.width) * 0.5,
                    y: Float(proposed.canvasSize.height) * 0.5
                ),
                zoom: 1
            )
        }
    }

    private func requireEmptyConfigurationChangeAllowed() throws {
        guard !documentDomainLocked else {
            if case .finite(.radial) =
                tilingStrategy.documentConfiguration
            {
                throw MetalRendererError.radialGeometryLocked
            }
            throw MetalRendererError.documentDomainLocked
        }
    }

    public func setTiling(_ tiling: TilingKind) async throws {
        try await applyTiling(tiling)
    }

    public func activateDrawBrush(_ brush: CompiledBrush) throws {
        try installCompiledBrush(brush, for: .draw)
    }

    public func activateEraserBrush(_ brush: CompiledBrush) throws {
        try installCompiledBrush(brush, for: .erase)
    }

    public func preparedBrush(
        for mode: StrokeCompositeMode
    ) -> CompiledBrush? {
        switch mode {
        case .draw: activeDrawBrush
        case .erase: activeEraserBrush
        }
    }

    private func installCompiledBrush(
        _ brush: CompiledBrush,
        for mode: StrokeCompositeMode
    ) throws {
        guard isIdle else {
            throw MetalRendererError.compiledBrushActivationRequiresIdle
        }
        try validateCompiledBrush(brush)
        let renderState = brush.renderState
        switch mode {
        case .draw:
            activeDrawBrush = brush
            activeDrawBrushRenderState = renderState
        case .erase:
            activeEraserBrush = brush
            activeEraserBrushRenderState = renderState
        }
    }

    private func validateCompiledBrush(_ brush: CompiledBrush) throws {
        let definition = brush.program.definition
        guard brush.renderIdentity.definitionID == definition.id,
              brush.report.definitionID == definition.id.rawValue,
              brush.report.packageContentHash
                == brush.renderIdentity.semanticHash,
              brush.report.backend == brush.program.requestedBackend,
              brush.program.requestedBackend == .deposition,
              (brush.program.secondaryComponent == nil)
                == (brush.secondaryComponent == nil),
              try compiledComponent(
                brush.primaryComponent,
                matches: brush.program.primaryComponent
              ),
              brush.residentByteCount >= 0,
              brush.report.residentResourceBytes
                == brush.residentByteCount
        else {
            throw MetalRendererError.invalidCompiledBrush
        }
        if let compiledSecondary = brush.secondaryComponent,
           let programSecondary = brush.program.secondaryComponent,
           try !compiledComponent(
               compiledSecondary,
               matches: programSecondary
           )
        {
            throw MetalRendererError.invalidCompiledBrush
        }
    }

    private func compiledComponent(
        _ compiled: CompiledBrushComponent,
        matches program: BrushComponentProgram
    ) throws -> Bool {
        let definition = program.definition
        guard compiled.pipelineKey.backend == .deposition,
              definition.material.interaction == .none,
              definition.material.edgeTreatment != .wetConcentration
        else {
            throw MetalRendererError.unsupportedCompiledBrush
        }
        let expectedMaterial = try DepositionMaterialBinding(
            uniformTemplate: compiled.uniformTemplate,
            textures: compiled.textures,
            tipSupports: compiled.tipSupports
        )
        let pipelineKey = compiled.depositionPipeline.key
        return compiled.identifier == definition.identifier
            && compiled.ordinal == definition.ordinal
            && compiled.pipelineKey == pipelineKey.brush
            && pipelineKey.abiVersion == DepositionABI.version
            && pipelineKey.colorPixelFormatRawValue
                == DocumentColorPipeline.workingPixelFormat.rawValue
            && pipelineKey.sampleCount
                == DocumentColorPipeline.renderSampleCount
            && compiled.uniformTemplate.placement == definition.placement
            && compiled.uniformTemplate.coverage == definition.coverage
            && compiled.uniformTemplate.color == definition.color
            && compiled.uniformTemplate.material == definition.material
            && depositionMaterial(
                compiled.depositionMaterial,
                matches: expectedMaterial
            )
    }

    private func uniqueTextureCount(_ brush: CompiledBrush) -> Int {
        guard let secondary = brush.secondaryComponent else {
            return brush.primaryComponent.textures.count
        }
        return brush.primaryComponent.textures.count
            + secondary.textures.keys.reduce(into: 0) { count, key in
                if brush.primaryComponent.textures[key] == nil {
                    count += 1
                }
            }
    }

    private func depositionMaterial(
        _ actual: DepositionMaterialBinding,
        matches expected: DepositionMaterialBinding
    ) -> Bool {
        guard actual.uniforms.coverageParameters
                == expected.uniforms.coverageParameters,
              actual.uniforms.secondaryShapeTransform
                == expected.uniforms.secondaryShapeTransform,
              actual.uniforms.edgeParameters
                == expected.uniforms.edgeParameters,
              actual.uniforms.options == expected.uniforms.options,
              actual.textures.boundSlots == expected.textures.boundSlots
        else {
            return false
        }
        return expected.textures.boundSlots.allSatisfy { slot in
            guard let actualTexture = actual.textures[slot],
                  let expectedTexture = expected.textures[slot]
            else {
                return false
            }
            return ObjectIdentifier(actualTexture as AnyObject)
                == ObjectIdentifier(expectedTexture as AnyObject)
        }
    }

    private func validateStrokeBeginSample(
        _ sample: StrokeSample
    ) throws {
        guard sample.phase == .began,
              sample.kind == .actual || sample.kind == .coalesced
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
    }

    private func validateStrokeAppendSample(
        _ sample: StrokeSample
    ) throws {
        guard sample.phase == .moved,
              sample.kind != .estimatedUpdate
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
    }

    private func validateStrokeFinishSample(
        _ sample: StrokeSample
    ) throws {
        guard sample.phase == .ended,
              sample.kind == .actual || sample.kind == .coalesced
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
    }

    private func validateEstimatedStrokeUpdateSample(
        _ sample: StrokeSample
    ) throws {
        guard sample.phase == .moved,
              sample.kind == .estimatedUpdate
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
    }

    private func compiledBrush(
        for style: StrokeRenderStyle
    ) throws -> CompiledBrush {
        let brush: CompiledBrush? = switch style.compositeMode {
        case .draw:
            activeDrawBrush
        case .erase:
            activeEraserBrush
        }
        if let brush,
           brush.renderIdentity == style.renderIdentity,
           brush.program == style.program
        {
            return brush
        }

        if brush != nil {
            throw MetalRendererError.compiledBrushIdentityMismatch
        }
        throw MetalRendererError.compiledBrushUnavailable(style.compositeMode)
    }

    private func compiledBrushRenderState(
        for style: StrokeRenderStyle
    ) throws -> CompiledBrushRenderState {
        let state: CompiledBrushRenderState? = switch style.compositeMode {
        case .draw:
            activeDrawBrushRenderState
        case .erase:
            activeEraserBrushRenderState
        }
        guard let state,
              state.renderIdentity == style.renderIdentity,
              state.program == style.program
        else {
            throw MetalRendererError.compiledBrushIdentityMismatch
        }
        return state
    }

    public func setPeriodicConfiguration(
        _ configuration: PeriodicSymmetryConfiguration
    ) async throws {
        try await applyPeriodicConfiguration(configuration)
    }

    public func beginStroke(
        token: RendererOperationToken,
        sample: StrokeSample,
        style: StrokeRenderStyle
    ) throws {
        try validateStrokeBeginSample(sample)
        let diameterLimits = style.program.definition.limits
        guard style.diameter >= diameterLimits.minimumDiameter,
              style.diameter <= diameterLimits.maximumDiameter
        else {
            throw MetalRendererError.brushDiameterOutOfRange(
                actual: style.diameter,
                minimum: diameterLimits.minimumDiameter,
                maximum: diameterLimits.maximumDiameter
            )
        }
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        var operationSucceeded = false
        let wasIdle = isIdle
        defer {
            notifyIdleStateIfChanged(from: wasIdle)
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: operationSucceeded
            )
        }
        guard isIdle, strokeWorkspaceState == .available else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        _ = try compiledBrush(for: style)
        let brushRenderState = try compiledBrushRenderState(for: style)
        instancePool.beginStrokeDiagnostics()
        resetBrushLabDepositionDiagnostics()
        markBrushLabInputReceipt()
        counters = GridStructuralCounters()
        brushLabActualDabCount = 0
        brushLabPredictedDabCount = 0
        resetLiveState()
        let generatorColor: InkColor
        switch style.compositeMode {
        case .draw:
            generatorColor = Self.opaqueStrokeColor(style.color)
        case .erase:
            generatorColor = InkColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 1
            )!
        }
        activeStroke = ActiveStrokeExecution(
            token: token,
            style: style,
            brush: brushRenderState,
            renderIdentity: style.renderIdentity,
            frozenHarnessScheduler: nil,
            commitRequested: false,
            isFinishedTransiently: false
        )
        strokeEventGeneration = rendererEventDispatcher
            .advanceStrokeGeneration()
        let runtimeBeginEvents = beginStrokeRuntime(sample)
        do {
            counters.newDabsThisEvent = 0
            let forceOffMainCommandFailure =
                forceOffMainStrokeCommandFailureForTesting
            let capability = try paintContext.beginStrokeSurface()
            let generation = capability.generation
            let tileSurfaces = try StrokeTileSurfaceResources(
                device: device,
                commandQueue: commandQueue,
                capability: capability,
                maximumRecordCount: max(
                    depositionFrameBudget.maximumAuthoritativeInstances,
                    depositionFrameBudget.maximumPredictedInstances
                ),
                maximumTileReferenceCount:
                    GridCanvasContract.maximumStrokeTileReferenceCount
            )
            activeStrokeTileSurfaceResources = tileSurfaces
            let metalResourceDescriptor = StrokeMetalResourceDescriptor(
                surfaces: tileSurfaces,
                brush: brushRenderState,
                frameUniforms: frameUniforms(
                    drawableSize: tileSize,
                    showGridLines: false,
                    liveVisible: true
                ),
                radialLayout:
                    tilingStrategy.compiledSymmetry.domain.finite?.radial.layout,
                forceCommandFailure: forceOffMainCommandFailure
            )
            let bridge = warmedStrokePreparationBridge
            strokePreparationBridge = bridge
            strokePreparationGeneration = generation
            strokeWorkspaceState = .borrowed(generation)
            strokeWorkspaceRetirementErrorWasReported = false
            try submitStrokeInput(
                .begin(
                    generation: generation,
                    configuration: StrokePreparationConfiguration(
                        program: style.program,
                        nominalDiameter: style.diameter,
                        color: generatorColor,
                        seed: style.seed,
                        componentRandomNamespaceMode:
                            style.componentRandomNamespaceMode,
                        viewport: viewport,
                        tilingStrategy: tilingStrategy,
                        metalResourceDescriptor: metalResourceDescriptor,
                        allocationProbe: strokePreparationAllocationProbe
                    ),
                    samples: [sample]
                ),
                using: bridge,
                traceLineage: takeInteractiveBrushTraceLineage(for: sample)
            )
            startPaintLifecyclePump()
            stageStrokeRuntimeEvents(runtimeBeginEvents)
            operationSucceeded = true
        } catch {
            _ = endStrokeRuntimeIfPossible()
            if let capability = activeStrokeTileSurfaceResources?.capability {
                try? paintContext.cancelStrokeSurface(capability)
            }
            activeStrokeTileSurfaceResources = nil
            activeStroke = nil
            resetLiveState()
            throw error
        }
    }

    public func appendStroke(
        token: RendererOperationToken,
        sample: StrokeSample
    ) throws {
        try validateStrokeAppendSample(sample)
        if sample.kind != .predicted {
            try requireCollectingStroke(token: token)
        }
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        var operationSucceeded = false
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: operationSucceeded
            )
        }
        markBrushLabInputReceipt()
        recordStrokeRuntimeInput(sample)
        if sample.kind == .predicted {
            try requireCollectingStroke(token: token)
            guard let bridge = strokePreparationBridge,
                  let generation = strokePreparationGeneration
            else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            _ = try submitStrokeInput(
                .replacePredictionSample(
                    generation: generation,
                    sample: sample
                ),
                using: bridge,
                traceLineage: takeInteractiveBrushTraceLineage(for: sample)
            )
        } else {
            try appendAuthoritativeStroke(token: token, sample: sample)
        }
        operationSucceeded = true
    }

    package func appendStrokeBatch(
        token: RendererOperationToken,
        samples: [StrokeSample]
    ) throws {
        guard !samples.isEmpty else { return }
        for sample in samples {
            try validateStrokeAppendSample(sample)
        }
        if samples.contains(where: { $0.kind != .predicted }) {
            try requireCollectingStroke(token: token)
        }
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        var operationSucceeded = false
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: operationSucceeded
            )
        }
        markBrushLabInputReceipt()
        for sample in samples {
            recordStrokeRuntimeInput(sample)
        }
        var index = samples.startIndex
        while index < samples.endIndex {
            if samples[index].kind == .predicted {
                let suffixStart = index
                while index < samples.endIndex,
                      samples[index].kind == .predicted
                {
                    index += 1
                }
                try replacePredictedStrokeSuffix(
                    token: token,
                    samples: samples[suffixStart..<index]
                )
                commitRendererEventCheckpoint()
            } else {
                try appendAuthoritativeStroke(
                    token: token,
                    sample: samples[index]
                )
                commitRendererEventCheckpoint()
                index += 1
            }
        }
        operationSucceeded = true
    }

    /// Production batch route for the BrushInput adapter's explicit ordering
    /// contract: exact authoritative prefix followed by a replaceable predicted
    /// suffix. Only the admitted prediction prefix is inspected on Main; the
    /// suffix count still reaches the worker for overload accounting.
    public func appendStrokeBatch<AuthoritativeSamples, PredictedSamples>(
        token: RendererOperationToken,
        authoritativeSamples: AuthoritativeSamples,
        predictedSamples: PredictedSamples,
        submittedPredictionSampleCount: Int? = nil
    ) throws
    where
        AuthoritativeSamples: RandomAccessCollection,
        PredictedSamples: RandomAccessCollection,
        AuthoritativeSamples.Element == StrokeSample,
        PredictedSamples.Element == StrokeSample
    {
        let receivedPredictionSampleCount = predictedSamples.count
        let submittedPredictionSampleCount =
            submittedPredictionSampleCount
                ?? receivedPredictionSampleCount
        guard submittedPredictionSampleCount >= receivedPredictionSampleCount
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard !authoritativeSamples.isEmpty
                || submittedPredictionSampleCount > 0
        else {
            return
        }
        for sample in authoritativeSamples {
            try validateStrokeAppendSample(sample)
            guard sample.kind == .actual || sample.kind == .coalesced else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
        }
        predictionSubmissionScratch.removeAll(keepingCapacity: true)
        for sample in predictedSamples.prefix(
            PredictionAdmissionLimits.maximumNormalizedSampleCount
        ) {
            try validateStrokeAppendSample(sample)
            guard sample.kind == .predicted else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            predictionSubmissionScratch.append(sample)
        }
        if !authoritativeSamples.isEmpty {
            try requireCollectingStroke(token: token)
        } else {
            try requireCollectingStroke(token: token)
        }

        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        var operationSucceeded = false
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: operationSucceeded
            )
        }
        markBrushLabInputReceipt()
        for sample in authoritativeSamples {
            recordStrokeRuntimeInput(sample)
            try appendAuthoritativeStroke(token: token, sample: sample)
            commitRendererEventCheckpoint()
        }
        for sample in predictionSubmissionScratch {
            recordStrokeRuntimeInput(sample)
        }
        if submittedPredictionSampleCount > 0 {
            let admission = try submitPrevalidatedPredictedStrokeSuffix(
                token: token,
                samples: predictionSubmissionScratch,
                submittedSampleCount: submittedPredictionSampleCount
            )
            recordPredictionSubmissionScratch(
                admission: admission,
                submittedSampleCount: submittedPredictionSampleCount
            )
            commitRendererEventCheckpoint()
        }
        operationSucceeded = true
    }

    private func submitPrevalidatedPredictedStrokeSuffix(
        token: RendererOperationToken,
        samples: [StrokeSample],
        submittedSampleCount: Int
    ) throws -> StrokeInputAdmission {
        precondition(samples.count <= submittedSampleCount)
        guard let bridge = strokePreparationBridge,
              let generation = strokePreparationGeneration
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        return try submitStrokeInput(
            .replacePrediction(
                generation: generation,
                samples: samples,
                acceptedCount: submittedSampleCount
            ),
            using: bridge,
            traceLineage: samples.compactMap {
                takeInteractiveBrushTraceLineage(for: $0).first
            }
        )
    }

    private func recordPredictionSubmissionScratch(
        admission: StrokeInputAdmission,
        submittedSampleCount: Int
    ) {
        let identity = predictionSubmissionScratch.withUnsafeBufferPointer {
            buffer -> UInt in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return UInt(bitPattern: UnsafeRawPointer(baseAddress))
        }
        if identity != 0 {
            if predictionSubmissionScratchStorageIdentity != 0,
               predictionSubmissionScratchStorageIdentity != identity
            {
                predictionSubmissionScratchStorageReallocationCount &+= 1
            }
            predictionSubmissionScratchStorageIdentity = identity
        }
        predictionSubmissionScratchHighWater = max(
            predictionSubmissionScratchHighWater,
            predictionSubmissionScratch.count
        )
        predictionSubmissionLastSubmittedSampleCount = submittedSampleCount
        predictionSubmissionLastAcceptedSampleCount =
            admission.acceptedPredictionSampleCount
        predictionSubmissionLastShedSampleCount =
            admission.shedPredictionSampleCount
        predictionSubmissionLastValidatedSampleCount =
            predictionSubmissionScratch.count
        predictionSubmissionLastTelemetrySampleCount =
            predictionSubmissionScratch.count
    }

    private func replacePredictedStrokeSuffix<Samples: Collection>(
        token: RendererOperationToken,
        samples: Samples
    ) throws where Samples.Element == StrokeSample {
        precondition(!samples.isEmpty)
        var sampleIndex = samples.startIndex
        while sampleIndex != samples.endIndex {
            precondition(samples[sampleIndex].kind == .predicted)
            guard samples[sampleIndex].phase == .moved else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            sampleIndex = samples.index(after: sampleIndex)
        }
        try requireCollectingStroke(token: token)
        guard let bridge = strokePreparationBridge,
              let generation = strokePreparationGeneration
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        _ = try submitStrokeInput(
            .replacePrediction(
                generation: generation,
                samples: Array(samples),
                acceptedCount: samples.count
            ),
            using: bridge,
            traceLineage: samples.compactMap {
                takeInteractiveBrushTraceLineage(for: $0).first
            }
        )
    }

    private func appendAuthoritativeStroke(
        token: RendererOperationToken,
        sample: StrokeSample
    ) throws {
        precondition(sample.kind != .predicted)
        guard sample.phase == .moved else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        try requireCollectingStroke(token: token)
        guard let bridge = strokePreparationBridge,
              let generation = strokePreparationGeneration
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        try submitStrokeInput(
            .appendAuthoritativeSample(
                generation: generation,
                sample: sample
            ),
            using: bridge,
            traceLineage: takeInteractiveBrushTraceLineage(for: sample)
        )
    }

    public func requestStrokeCommit(
        token: RendererOperationToken,
        sample: StrokeSample
    ) throws {
        try validateStrokeFinishSample(sample)
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        var operationSucceeded = false
        let wasIdle = isIdle
        defer {
            notifyIdleStateIfChanged(from: wasIdle)
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: operationSucceeded
            )
        }
        try requireCollectingStroke(token: token)
        do {
            try finishStrokeTransient(token: token, sample: sample)
            try requestOffMainStrokeCommit()
            operationSucceeded = true
        } catch {
            let runtimeEndEvents = endStrokeRuntimeIfPossible()
            activeStroke = nil
            resetLiveState()
            stageStrokeRuntimeEvents(runtimeEndEvents)
            operationSucceeded = true
            throw error
        }
    }

    public func finishStrokeTransient(
        token: RendererOperationToken,
        sample: StrokeSample
    ) throws {
        try validateStrokeFinishSample(sample)
        try requireCollectingStroke(token: token)
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        var operationSucceeded = false
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: operationSucceeded
            )
        }
        try requireCollectingStroke(token: token)
        markBrushLabInputReceipt()
        recordStrokeRuntimeInput(sample)
        guard let bridge = strokePreparationBridge,
              let generation = strokePreparationGeneration
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        try submitStrokeInput(
            .finish(generation: generation, samples: [sample]),
            using: bridge,
            traceLineage: takeInteractiveBrushTraceLineage(for: sample)
        )
        activeStroke?.isFinishedTransiently = true
        operationSucceeded = true
    }

    public func commitFinishedStroke(
        token: RendererOperationToken
    ) throws {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        var operationSucceeded = false
        let wasIdle = isIdle
        defer {
            notifyIdleStateIfChanged(from: wasIdle)
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: operationSucceeded
            )
        }
        try requireEditableStroke(token: token)
        guard activeStroke?.isFinishedTransiently == true else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        do {
            try requestOffMainStrokeCommit()
            operationSucceeded = true
        } catch {
            let runtimeEndEvents = endStrokeRuntimeIfPossible()
            activeStroke = nil
            resetLiveState()
            stageStrokeRuntimeEvents(runtimeEndEvents)
            operationSucceeded = true
            throw error
        }
    }

    public func applyEstimatedStrokeUpdate(
        token: RendererOperationToken,
        sample: StrokeSample
    ) throws {
        try validateEstimatedStrokeUpdateSample(sample)
        try requireEditableStroke(token: token)
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        var operationSucceeded = false
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: operationSucceeded
            )
        }
        recordStrokeRuntimeInput(sample)
        try requireEditableStroke(token: token)
        guard let bridge = strokePreparationBridge,
              let generation = strokePreparationGeneration
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        try submitStrokeInput(
            .applyEstimatedUpdate(
                generation: generation,
                sample: sample
            ),
            using: bridge,
            traceLineage: takeInteractiveBrushTraceLineage(for: sample)
        )
        operationSucceeded = true
    }
    public func cancelStroke(token: RendererOperationToken) throws {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        var operationSucceeded = false
        let wasIdle = isIdle
        defer {
            notifyIdleStateIfChanged(from: wasIdle)
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: operationSucceeded
            )
        }
        try requireEditableStroke(token: token)
        let runtimeEndEvents = endStrokeRuntimeIfPossible()
        activeStroke = nil
        resetLiveState()
        stageStrokeRuntimeEvents(runtimeEndEvents)
        operationSucceeded = true
    }

    private func requireCollectingStroke(
        token: RendererOperationToken
    ) throws {
        try requireEditableStroke(token: token)
        guard activeStroke?.isFinishedTransiently == false else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
    }

    private func requireEditableStroke(
        token: RendererOperationToken
    ) throws {
        guard let activeStroke else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard activeStroke.token == token else {
            throw MetalRendererError.invalidRendererOperationToken
        }
        guard !activeStroke.commitRequested else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
    }

    private func requestOffMainStrokeCommit() throws {
        guard let bridge = strokePreparationBridge,
              let generation = strokePreparationGeneration,
              var execution = activeStroke,
              !execution.commitRequested
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        try submitStrokeInput(
            .commit(generation: generation),
            using: bridge
        )
        execution.commitRequested = true
        activeStroke = execution
    }

    @discardableResult
    private func submitStrokeInput(
        _ message: StrokeInputMessage,
        using bridge: StrokePreparationBridge,
        traceLineage: [InteractiveBrushInputTrace] = []
    ) throws -> StrokeInputAdmission {
        do {
            let admission = try bridge.submit(
                message,
                traceLineage: traceLineage
            )
            interactiveFramePump.signal(.input)
            if let paintDisplayView {
                requestPaintDisplay(in: paintDisplayView)
            }
            return admission
        } catch let error as StrokeInputQueueError {
            let rendererError: MetalRendererError
            switch error {
            case let .authoritativeCapacityExceeded(
                _,
                _,
                _,
                maximum
            ):
                rendererError = .strokeSampleCapacityExceeded(maximum)
            case .invalidCapacity:
                rendererError = .commandFailed(
                    "stroke input queue has an invalid capacity"
                )
            }
            failActiveOperationIfNeeded(rendererError)
            throw rendererError
        }
    }

    private func takeInteractiveBrushTraceLineage(
        for sample: StrokeSample
    ) -> [InteractiveBrushInputTrace] {
        guard let index = pendingInteractiveBrushInputTraces.firstIndex(
            where: { $0.sample == sample }
        ) else { return [] }
        return [pendingInteractiveBrushInputTraces.remove(at: index).lineage]
    }

    /// Frozen projected-dab oracle entry point. It bypasses public stroke
    /// input entirely and exists only for deterministic capture fixtures.
    /// Interactive compiled-brush APIs never call this method.
    func beginFrozenProjectionHarnessExecution(
        radius: Float,
        compositeMode: StrokeCompositeMode = .draw
    ) throws {
        guard activeStroke == nil else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard let brush = preparedBrush(for: compositeMode) else {
            throw MetalRendererError.compiledBrushUnavailable(compositeMode)
        }
        let token = RendererOperationToken(rawValue: nextHarnessTokenRawValue)
        nextHarnessTokenRawValue &+= 1
        if nextHarnessTokenRawValue == 0 {
            nextHarnessTokenRawValue = 1
        }
        let style = StrokeRenderStyle(
            color: .black,
            diameter: radius * 2,
            compositeMode: compositeMode,
            eraserStrength: 1,
            program: brush.program,
            renderIdentity: brush.renderIdentity,
            seed: token.rawValue
        )
        resetLiveState()
        resetBrushLabDepositionDiagnostics()
        activeStroke = ActiveStrokeExecution(
            token: token,
            style: style,
            brush: brush.renderState,
            renderIdentity: brush.renderIdentity,
            frozenHarnessScheduler: FrameScheduler(
                budget: depositionFrameBudget
            ),
            commitRequested: false,
            isFinishedTransiently: false
        )
    }

    public func pan(byScreenDelta delta: SIMD2<Float>) {
        guard isIdle else { return }
        viewport = viewport.panned(byScreenDelta: delta)
        invalidatePaintDisplayPreparation(reason: .viewport)
    }

    public func zoom(by factor: Float, anchor: ScreenPoint) {
        guard isIdle else { return }
        viewport = viewport.zoomed(by: factor, anchorScreen: anchor)
        invalidatePaintDisplayPreparation(reason: .viewport)
    }

    public func strokeFootprintIntersectsDocument(
        at screenPoint: ScreenPoint,
        diameter: Float
    ) -> Bool {
        guard diameter.isFinite, diameter > 0 else { return false }
        guard case .finite = tilingStrategy.documentConfiguration else {
            return true
        }
        let world = viewport.screenToWorld(screenPoint)
        let radius = diameter * 0.5
        return world.x + radius > 0
            && world.y + radius > 0
            && world.x - radius < Float(pixelSize.width)
            && world.y - radius < Float(pixelSize.height)
    }

    public func restoreSavedViewport(
        worldCenter: WorldPoint,
        zoom: Float
    ) {
        guard worldCenter.x.isFinite,
              worldCenter.y.isFinite,
              zoom.isFinite,
              GridCanvasContract.zoomRange.contains(zoom)
        else {
            return
        }
        viewport = ViewportTransform(
            drawableSize: viewport.drawableSize,
            worldCenter: worldCenter,
            zoom: zoom
        )
        invalidatePaintDisplayPreparation(reason: .viewport)
    }

    public func resize(to size: PatternSize) {
        viewport = viewport.resized(to: size)
        invalidatePaintDisplayPreparation(reason: .drawable)
    }

    public func setInteractiveGridVisibility(_ visible: Bool) {
        guard interactiveGridVisibility != visible else { return }
        interactiveGridVisibility = visible
        invalidatePaintDisplayPreparation()
    }

    private enum PaintDisplayInvalidationReason: Equatable {
        case cache
        case viewport
        case drawable
    }

    private func invalidatePaintDisplayPreparation(
        reason: PaintDisplayInvalidationReason = .cache,
        reschedule: Bool = true
    ) {
        paintOutputGeometryRevision &+= 1
        if paintOutputGeometryRevision == 0 { paintOutputGeometryRevision = 1 }
        if reason == .viewport || reason == .drawable {
            paintViewportRevision &+= 1
            if paintViewportRevision == 0 { paintViewportRevision = 1 }
        }
        guard let revision = advancePaintDisplayPresentationRevision() else {
            return
        }
        signalInteractiveFrame(reason: reason, revision: revision)
        if let paintDisplayPreparationTask {
            paintDisplayPreparationTask.cancel()
            trackRetiringPaintDisplayPreparation(
                paintDisplayPreparationTask,
                revision: activePaintDisplayPreparationRevision
            )
            self.paintDisplayPreparationTask = nil
            activePaintDisplayPreparationRevision = nil
        }
        if let preparedPaintDisplay {
            try? paintContext.cancelLayerDisplaySubmission(
                preparedPaintDisplay.submission
            )
            self.preparedPaintDisplay = nil
        }
        if let paintDisplayView {
            pendingLatestPaintDisplaySnapshot = makePaintDisplaySnapshot(
                revision: revision,
                in: paintDisplayView,
                transient: activePaintTransientSource
            )
        }
        if reschedule, let paintDisplayView {
            schedulePaintDisplayPreparation(in: paintDisplayView)
        }
    }

    private func advancePaintDisplayPresentationRevision()
        -> CanvasPresentationRevision?
    {
        let (sequence, overflow) = paintDisplayPreparationSequence
            .addingReportingOverflow(1)
        guard !overflow else {
            let error = MetalRendererError.commandFailed(
                "paint display presentation sequence overflow"
            )
            paintCommandError = error
            failActiveOperationIfNeeded(error)
            return nil
        }
        paintDisplayPreparationSequence = sequence
        return CanvasPresentationRevision(sequence: sequence)
    }

    private func signalInteractiveFrame(
        reason: PaintDisplayInvalidationReason,
        revision: CanvasPresentationRevision
    ) {
        switch reason {
        case .cache:
            interactiveFramePump.signal(.cachePublished(revision))
        case .viewport:
            interactiveFramePump.signal(.viewportChanged(revision))
        case .drawable:
            interactiveFramePump.signal(.drawableChanged(revision))
        }
    }

    private func schedulePaintDisplayPreparation(in view: MTKView) {
        paintDisplayView = view
        guard interactiveFramePump.hasDemand,
              !paintDisplayPreparationIsSuspended,
              retiringPaintDisplayPreparationTask == nil,
              !exclusiveInteractiveCompletionDrainInProgress,
              paintDisplayPreparationTask == nil,
              preparedPaintDisplay == nil
        else { return }
        let demandCheckpoint = interactiveFramePump.demandCheckpoint
        let source = activePaintTransientSource
        let transient: DocumentPaintTransientDisplaySource?
        #if DEBUG
        let acknowledgementStatus =
            paintDisplayAcknowledgementStatusOverrideForTesting
                ?? source?.acknowledgementStatus
        #else
        let acknowledgementStatus = source?.acknowledgementStatus
        #endif
        switch Self.paintDisplayPreparationAction(
            for: acknowledgementStatus
        ) {
        case .stable:
            if source?.acknowledgementStatus == .fulfilled {
                activePaintTransientSource = nil
            }
            transient = nil
        case .transient:
            transient = source
        case let .fail(error):
            #if DEBUG
            paintDisplayAcknowledgementStatusOverrideForTesting = nil
            #endif
            activePaintTransientSource = nil
            let rendererError = MetalRendererError.commandFailed(
                "transient display acknowledgement failed: \(error)"
            )
            paintCommandError = rendererError
            let failedRevision = CanvasPresentationRevision(
                sequence: max(paintDisplayPreparationSequence, 1)
            )
            let shouldContinue = interactiveFramePump
                .settleTerminalFailure(
                    upTo: failedRevision,
                    since: demandCheckpoint
                )
            failActiveOperationIfNeeded(rendererError)
            if shouldContinue {
                requestPaintDisplay(in: view)
            }
            return
        }
        let width = Int(view.drawableSize.width)
        let height = Int(view.drawableSize.height)
        guard width > 0, height > 0 else { return }
        let snapshot: CanvasPresentationSnapshot
        if let pendingLatestPaintDisplaySnapshot {
            snapshot = pendingLatestPaintDisplaySnapshot
        } else if paintDisplayPreparationSequence == 0 {
            guard let first = advancePaintDisplayPresentationRevision() else {
                return
            }
            interactiveFramePump.signal(.cachePublished(first))
            guard let firstSnapshot = makePaintDisplaySnapshot(
                revision: first,
                in: view,
                transient: transient
            ) else { return }
            snapshot = firstSnapshot
        } else {
            guard let currentSnapshot = makePaintDisplaySnapshot(
                revision: CanvasPresentationRevision(
                    sequence: paintDisplayPreparationSequence
                ),
                in: view,
                transient: transient
            ) else { return }
            snapshot = currentSnapshot
        }
        let revision = snapshot.revision
        guard let currentSnapshot = makePaintDisplaySnapshot(
            revision: revision,
            in: view,
            transient: transient
        ) else { return }
        do {
            try snapshot.validateCompatibility(with: currentSnapshot)
        } catch {
            pendingLatestPaintDisplaySnapshot = nil
            invalidatePaintDisplayPreparation()
            return
        }
        pendingLatestPaintDisplaySnapshot = nil
        paintDisplayPreparationScheduleCount &+= 1
        activePaintDisplayPreparationRevision = revision
        let preparationDemandCheckpoint = interactiveFramePump.demandCheckpoint
        let preparationGate = presentationPreparationGate
        let preparationContext = paintContext
        let preparationTilingStrategy = tilingStrategy
        let preparationStoragePixelSize = storagePixelSize
        let preparationStyle = transient == nil ? nil : activeStroke?.style
        paintDisplayPreparationTask = Task { @MainActor [weak self] in
            await preparationGate?.preparationDidBegin(revision: revision)
            do {
                if let injectedFailure = await preparationGate?
                    .injectedPreparationFailure(revision: revision)
                {
                    throw injectedFailure
                }
                let submission = try await CanvasDisplayCompositor.prepare(
                    context: preparationContext,
                    snapshot: snapshot,
                    tilingStrategy: preparationTilingStrategy,
                    storagePixelSize: preparationStoragePixelSize,
                    transient: transient,
                    transientMode: preparationStyle?.compositeMode,
                    strokeOpacity: preparationStyle?.color.alpha ?? 1,
                    eraserStrength:
                        preparationStyle?.eraserStrength ?? 1
                )
                guard !Task.isCancelled,
                      self?.installPreparedPaintDisplayIfCurrent(
                        submission,
                        snapshot: snapshot,
                        revision: revision
                      ) == true
                else {
                    try preparationContext
                        .cancelLayerDisplaySubmission(submission)
                    try await preparationContext
                        .retryLayerDisplayCompletions()
                    await preparationGate?.preparationDidRetire(
                        revision: revision
                    )
                    return
                }
                await preparationGate?.preparationDidPublish(
                    revision: revision
                )
                await preparationGate?.preparationDidRetire(
                    revision: revision
                )
                if !Task.isCancelled {
                    self?.finishSuccessfulPaintDisplayPreparation(
                        revision: revision,
                        in: view
                    )
                }
            } catch is CancellationError {
                await preparationGate?.preparationDidRetire(
                    revision: revision
                )
                self?.finishCancelledPaintDisplayPreparation(
                    revision: revision
                )
            } catch {
                guard !Task.isCancelled,
                      self?.paintDisplayPreparationIsCurrent(revision) == true
                else {
                    try? await preparationContext
                        .retryLayerDisplayCompletions()
                    await preparationGate?.preparationDidRetire(
                        revision: revision
                    )
                    return
                }
                await preparationGate?.preparationDidRetire(
                    revision: revision
                )
                if !Task.isCancelled {
                    self?.finishFailedPaintDisplayPreparation(
                        error,
                        snapshot: snapshot,
                        revision: revision,
                        demandCheckpoint: preparationDemandCheckpoint,
                        in: view
                    )
                }
            }
        }
    }

    private func paintDisplayPreparationIsCurrent(
        _ revision: CanvasPresentationRevision
    ) -> Bool {
        paintDisplayPreparationSequence == revision.sequence
            && activePaintDisplayPreparationRevision == revision
    }

    private func installPreparedPaintDisplayIfCurrent(
        _ submission: PreparedLayerCompositeDisplaySubmission,
        snapshot: CanvasPresentationSnapshot,
        revision: CanvasPresentationRevision
    ) -> Bool {
        guard paintDisplayPreparationIsCurrent(revision) else { return false }
        preparedPaintDisplay = PreparedPaintDisplay(
            snapshot: snapshot,
            submission: submission
        )
        #if DEBUG
        paintDisplayPublishedRevisions.append(revision)
        #endif
        interactiveFramePump.signal(.cachePublished(revision))
        return true
    }

    private func finishSuccessfulPaintDisplayPreparation(
        revision: CanvasPresentationRevision,
        in view: MTKView
    ) {
        guard activePaintDisplayPreparationRevision == revision else { return }
        paintDisplayPreparationTask = nil
        activePaintDisplayPreparationRevision = nil
        requestPaintDisplay(in: view)
    }

    private func finishCancelledPaintDisplayPreparation(
        revision: CanvasPresentationRevision
    ) {
        guard activePaintDisplayPreparationRevision == revision else { return }
        paintDisplayPreparationTask = nil
        activePaintDisplayPreparationRevision = nil
    }

    private func finishFailedPaintDisplayPreparation(
        _ error: any Error,
        snapshot: CanvasPresentationSnapshot,
        revision: CanvasPresentationRevision,
        demandCheckpoint: UInt64,
        in view: MTKView
    ) {
        guard paintDisplayPreparationIsCurrent(revision) else { return }
        paintDisplayPreparationTask = nil
        activePaintDisplayPreparationRevision = nil
        if Self.isDeferredPaintDisplayPreparationFailure(error) {
            pendingLatestPaintDisplaySnapshot = snapshot
            if activePaintTransientSource?.acknowledgementStatus == .fulfilled {
                activePaintTransientSource = nil
                invalidatePaintDisplayPreparation()
            }
            return
        }
        paintCommandError = (error as? MetalRendererError)
            ?? .commandFailed(error.localizedDescription)
        let shouldContinue = interactiveFramePump.settleTerminalFailure(
            upTo: revision,
            since: demandCheckpoint
        )
        failActiveOperationIfNeeded(paintCommandError!)
        if shouldContinue { requestPaintDisplay(in: view) }
    }

    public func suspendPaintDisplayPreparationForCapture(
        deadlineUptimeNanoseconds: UInt64? = nil
    ) async throws {
        guard !paintDisplayPreparationIsSuspended else {
            throw MetalRendererError.capturePreparationAlreadySuspended
        }
        paintDisplayPreparationIsSuspended = true
        do {
            guard await awaitRetiringPaintDisplayPreparation(
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            ) else {
                throw MetalRendererError.commandFailed(
                    "retiring paint display preparation exceeded "
                        + "the capture deadline"
                )
            }
            let pendingPreparation = paintDisplayPreparationTask
            invalidatePaintDisplayPreparation(reschedule: false)
            guard await waitForPaintDisplayPreparationTermination(
                pendingPreparation,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            ) else {
                if let pendingPreparation {
                    trackRetiringPaintDisplayPreparation(pendingPreparation)
                }
                throw MetalRendererError.commandFailed(
                    "paint display preparation cancellation exceeded "
                        + "the capture deadline"
                )
            }
            try checkInteractiveCompletionDeadline(
                deadlineUptimeNanoseconds
            )
            try await paintContext.retryLayerDisplayCompletions()
            try checkInteractiveCompletionDeadline(
                deadlineUptimeNanoseconds
            )
        } catch {
            paintDisplayPreparationIsSuspended = false
            if let paintDisplayView {
                schedulePaintDisplayPreparation(in: paintDisplayView)
            }
            throw error
        }
    }

    public func resumePaintDisplayPreparationAfterCapture() throws {
        guard paintDisplayPreparationIsSuspended else {
            throw MetalRendererError.capturePreparationNotSuspended
        }
        paintDisplayPreparationIsSuspended = false
        if let paintDisplayView {
            schedulePaintDisplayPreparation(in: paintDisplayView)
        }
    }

    private func waitForPaintDisplayPreparationTermination(
        _ task: Task<Void, Never>?,
        deadlineUptimeNanoseconds: UInt64?
    ) async -> Bool {
        guard let task else { return true }
        guard let deadlineUptimeNanoseconds else {
            await task.value
            return true
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineUptimeNanoseconds else { return false }
        let pair = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let completionWaiter = Task {
            await task.value
            pair.continuation.yield(true)
        }
        let deadlineWaiter = Task {
            do {
                try await Task.sleep(
                    nanoseconds: deadlineUptimeNanoseconds - now
                )
                pair.continuation.yield(false)
            } catch {
                return
            }
        }
        var iterator = pair.stream.makeAsyncIterator()
        let completed = await iterator.next() ?? false
        completionWaiter.cancel()
        deadlineWaiter.cancel()
        pair.continuation.finish()
        return completed
    }

    private func awaitRetiringPaintDisplayPreparation(
        deadlineUptimeNanoseconds: UInt64?
    ) async -> Bool {
        guard let retiringPaintDisplayPreparationTask else { return true }
        guard await waitForPaintDisplayPreparationTermination(
            retiringPaintDisplayPreparationTask,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        ) else { return false }
        clearRetiringPaintDisplayPreparation()
        return true
    }

    private func trackRetiringPaintDisplayPreparation(
        _ task: Task<Void, Never>,
        revision: CanvasPresentationRevision? = nil
    ) {
        guard retiringPaintDisplayPreparationTask == nil else { return }
        nextPaintDisplayPreparationRetirementSequence &+= 1
        if nextPaintDisplayPreparationRetirementSequence == 0 {
            nextPaintDisplayPreparationRetirementSequence = 1
        }
        let sequence = nextPaintDisplayPreparationRetirementSequence
        activePaintDisplayPreparationRetirementSequence = sequence
        retiringPaintDisplayPreparationTask = task
        retiringPaintDisplayPreparationRevision = revision
        paintDisplayPreparationRetirementMonitor = Task {
            @MainActor [weak self] in
            await task.value
            guard let self,
                  self.activePaintDisplayPreparationRetirementSequence
                    == sequence
            else { return }
            self.retiringPaintDisplayPreparationTask = nil
            self.retiringPaintDisplayPreparationRevision = nil
            self.paintDisplayPreparationRetirementMonitor = nil
            self.activePaintDisplayPreparationRetirementSequence = nil
            if !self.paintDisplayPreparationIsSuspended,
               let paintDisplayView = self.paintDisplayView
            {
                self.schedulePaintDisplayPreparation(in: paintDisplayView)
            }
        }
    }

    private func clearRetiringPaintDisplayPreparation() {
        paintDisplayPreparationRetirementMonitor?.cancel()
        paintDisplayPreparationRetirementMonitor = nil
        retiringPaintDisplayPreparationTask = nil
        retiringPaintDisplayPreparationRevision = nil
        activePaintDisplayPreparationRetirementSequence = nil
    }

    private func makePaintDisplaySubmission(
        outputPixelSize: PixelSize,
        transient: DocumentPaintTransientDisplaySource?,
        showGridLines: Bool? = nil
    ) async throws -> PreparedLayerCompositeDisplaySubmission {
        let sequence = max(paintDisplayPreparationSequence, 1)
        let snapshot = makePaintDisplaySnapshot(
            revision: CanvasPresentationRevision(sequence: sequence),
            outputPixelSize: outputPixelSize,
            transient: transient,
            showGridLines: showGridLines ?? interactiveGridVisibility
        )
        return try await makePaintDisplaySubmission(
            snapshot: snapshot,
            transient: transient
        )
    }

    private func makePaintDisplaySubmission(
        snapshot: CanvasPresentationSnapshot,
        transient: DocumentPaintTransientDisplaySource?
    ) async throws -> PreparedLayerCompositeDisplaySubmission {
        let style = transient == nil ? nil : activeStroke?.style
        return try await CanvasDisplayCompositor.prepare(
            context: paintContext,
            snapshot: snapshot,
            tilingStrategy: tilingStrategy,
            storagePixelSize: storagePixelSize,
            transient: transient,
            transientMode: style?.compositeMode,
            strokeOpacity: style?.color.alpha ?? 1,
            eraserStrength: style?.eraserStrength ?? 1
        )
    }

    private func makePaintDisplaySnapshot(
        revision: CanvasPresentationRevision,
        in view: MTKView,
        transient: DocumentPaintTransientDisplaySource?
    ) -> CanvasPresentationSnapshot? {
        let width = Int(view.drawableSize.width)
        let height = Int(view.drawableSize.height)
        guard width > 0, height > 0 else { return nil }
        updatePaintBackingScale(in: view)
        return makePaintDisplaySnapshot(
            revision: revision,
            outputPixelSize: PixelSize(width: width, height: height),
            transient: transient,
            showGridLines: interactiveGridVisibility
        )
    }

    private func updatePaintBackingScale(in view: MTKView) {
        let boundsSize = view.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return }
        let scale = SIMD2(
            Float(view.drawableSize.width / boundsSize.width),
            Float(view.drawableSize.height / boundsSize.height)
        )
        guard scale.x.isFinite,
              scale.y.isFinite,
              scale.x > 0,
              scale.y > 0
        else { return }
        if let paintBackingScale, paintBackingScale != scale {
            paintBackingScaleRevision &+= 1
            if paintBackingScaleRevision == 0 {
                paintBackingScaleRevision = 1
            }
        }
        paintBackingScale = scale
    }

    private func makePaintDisplaySnapshot(
        revision: CanvasPresentationRevision,
        outputPixelSize: PixelSize,
        transient: DocumentPaintTransientDisplaySource?,
        showGridLines: Bool
    ) -> CanvasPresentationSnapshot {
        let canonicalIdentity = paintContext.canonicalStateIdentity()
        let transientRevision = transient?.contentKeys
            .map(\.contentRevision)
            .max()
        return CanvasPresentationSnapshot(
            revision: revision,
            canonicalIdentity: canonicalIdentity,
            canonicalCacheRevision: canonicalIdentity.compositeRevision,
            transientGeneration: transient == nil
                ? nil : strokePreparationGeneration,
            transientRevision: transientRevision,
            outputMappingRevision: paintOutputGeometryRevision,
            viewportRevision: paintViewportRevision,
            viewport: viewport,
            drawablePixelSize: outputPixelSize,
            backingScaleRevision: paintBackingScaleRevision,
            showGridLines: showGridLines,
            showCanvasBoundary: true
        )
    }

    private func requestPaintDisplay(in view: MTKView) {
        #if os(macOS)
        view.setNeedsDisplay(view.bounds)
        #else
        view.setNeedsDisplay()
        #endif
    }

    package func paintStateSnapshotForTesting() async
        -> RendererPaintDiagnosticSnapshot
    {
        let snapshot = await paintContext.snapshot()
        return RendererPaintDiagnosticSnapshot(
            storeIdentity: snapshot.storeIdentity,
            activeLayerID: snapshot.activeLayerID,
            documentGeneration: snapshot.documentGeneration,
            layerIDs: snapshot.layerIDs,
            activeSnapshotTokenCount: snapshot.activeSnapshotTokenCount,
            aggregateSnapshotReferenceCount:
                snapshot.aggregateSnapshotReferenceCount,
            activeTileLeaseCount: snapshot.activeTileLeaseCount,
            snapshotMetadataByteCount: snapshot.snapshotMetadataByteCount,
            snapshotPayloadLiabilityByteCount:
                snapshot.snapshotPayloadLiabilityByteCount,
            revisionResidentBytes: snapshot.revisionResidentBytes,
            activeStrokeSurfaceCount: snapshot.activeStrokeSurfaceCount,
            activeCommandOperationCount: snapshot.activeCommandOperationCount
        )
    }

    func paintCanonicalStateIdentityForTesting()
        -> CanvasCanonicalStateIdentity
    {
        paintContext.canonicalStateIdentity()
    }

    public func stageDAcceptanceEvidence() async
        -> StageDAcceptanceRendererEvidence
    {
        try? await paintContext.retryLayerDisplayCompletions()
        let snapshot = await paintContext.snapshot()
        let cpuCaches = [
            snapshot.visiblePlan.cpuPlanCache,
            snapshot.stableCollectionRenderer.cpuCache,
            snapshot.layerCompositor.cpuPlanCache,
        ]
        let gpuCaches = [
            snapshot.visiblePlan.gpuPlanCache,
            snapshot.stableCollectionRenderer.gpuCache,
            snapshot.layerCompositor.gpuPlanCache,
        ]
        let completions = [
            snapshot.stableCollectionRenderer.completion,
            snapshot.layerCompositor.completion,
        ]
        let uploadRings = gpuCaches.compactMap(\.uploadRing)
        let cachedPlanMetalBufferBytes = gpuCaches.reduce(0) {
            $0 + $1.cachedPlanMetalBufferBytes
        }
        let uploadRingMetalBufferBytes = uploadRings.reduce(0) {
            $0 + $1.metalBufferBytes
        }
        let fixedResourceBytes = snapshot.backingTileBytes
            + snapshot.revisionResidentBytes
            + snapshot.snapshotMetadataByteCount
            + snapshot.snapshotPayloadLiabilityByteCount
            + cachedPlanMetalBufferBytes
            + uploadRingMetalBufferBytes
        let residentResourceBytes = snapshot.residentTileBytes
            + fixedResourceBytes
        let residentResourceHighWaterBytes = max(
            residentResourceBytes,
            snapshot.residentTileHighWaterBytes + fixedResourceBytes
        )
        return StageDAcceptanceRendererEvidence(
            storageAuthority: .sparseRGBA16Float,
            backend: .productionSparseMetal,
            documentGeneration: snapshot.documentGeneration,
            layerCount: snapshot.layerIDs.count,
            tileByteBudget: snapshot.tileByteBudget,
            residentTileBytes: snapshot.residentTileBytes,
            residentTileHighWaterBytes:
                snapshot.residentTileHighWaterBytes,
            backingTileBytes: snapshot.backingTileBytes,
            tileIndexEntryCount: snapshot.tileIndexEntryCount,
            cpuCachedPlanCount: cpuCaches.reduce(0) {
                $0 + $1.cachedContentCount
            },
            gpuCachedPlanCount: gpuCaches.reduce(0) {
                $0 + $1.preparedContentCount
            },
            cpuPlanCacheHitCount: cpuCaches.reduce(0) {
                $0 + $1.hitCount
            },
            cpuPlanCacheMissCount: cpuCaches.reduce(0) {
                $0 + $1.missCount
            },
            gpuPlanCacheHitCount: gpuCaches.reduce(0) {
                $0 + $1.hitCount
            },
            gpuPlanCacheMissCount: gpuCaches.reduce(0) {
                $0 + $1.missCount
            },
            cachedPlanMetalBufferBytes: cachedPlanMetalBufferBytes,
            uploadRingMetalBufferBytes: uploadRingMetalBufferBytes,
            residentResourceBytes: residentResourceBytes,
            residentResourceHighWaterBytes: residentResourceHighWaterBytes,
            planMetalBufferAllocationCount: gpuCaches.reduce(0) {
                $0 + $1.planMetalBufferAllocationCount
            },
            activeUploadSlotCount: uploadRings.reduce(0) {
                $0 + $1.activeSlotCount
            },
            uploadSlotHighWater: uploadRings.reduce(0) {
                $0 + $1.highWaterSlotCount
            },
            pendingPlanCompletionCount:
                snapshot.visiblePlan.pendingPlanCompletionCount
                    + completions.reduce(0) {
                        $0 + $1.pendingPlanCompletionCount
                    },
            pendingConsumerCompletionCount:
                snapshot.visiblePlan.pendingConsumerCompletionCount
                    + completions.reduce(0) {
                        $0 + $1.pendingConsumerCompletionCount
            },
            revisionResidentBytes: snapshot.revisionResidentBytes,
            activeSnapshotTokenCount: snapshot.activeSnapshotTokenCount,
            // Display preparation closes exact-reference capture before it
            // publishes a submission. Durable display state owns plan/texture
            // leases, which are reported separately, never snapshot tokens.
            retainedDisplaySnapshotTokenCount: 0,
            retainedHistorySnapshotTokenCount:
                snapshot.retainedHistorySnapshotTokenCount,
            aggregateSnapshotReferenceCount:
                snapshot.aggregateSnapshotReferenceCount,
            activeTileLeaseCount: snapshot.activeTileLeaseCount,
            activeStrokeSurfaceCount: snapshot.activeStrokeSurfaceCount,
            activeCommandOperationCount: snapshot.activeCommandOperationCount,
            pendingLayerDisplayAcknowledgementCount:
                snapshot.pendingLayerDisplayAcknowledgementCount
        )
    }

    public func releasePaintRevisions(
        _ revisionIDs: Set<StoredRasterRevisionID>
    ) async throws {
        try await paintContext.releaseRevisions(revisionIDs)
        await refreshPaintRevisionResidentBytes()
    }

    public func applyLayerStack(
        _ layerStack: LayerStack
    ) throws -> LayerSurfaceRevisionReference? {
        let result = try paintContext.applyLayerStack(layerStack)
        if result.didPublish {
            invalidatePaintDisplayPreparation()
        }
        return result.revision
    }

    public func restoreLayerStackBefore(
        _ revision: LayerSurfaceRevisionReference
    ) throws -> LayerStack {
        let result = try paintContext.restoreLayerStack(
            revision,
            endpoint: .before
        )
        invalidatePaintDisplayPreparation()
        return result.after
    }

    public func restoreLayerStackAfter(
        _ revision: LayerSurfaceRevisionReference
    ) throws -> LayerStack {
        let result = try paintContext.restoreLayerStack(
            revision,
            endpoint: .after
        )
        invalidatePaintDisplayPreparation()
        return result.after
    }

    public func restoreLayerGeometryBefore(
        _ revision: LayerSurfaceRevisionReference
    ) throws -> PixelSize {
        try restoreLayerGeometry(revision, endpoint: .before)
    }

    public func restoreLayerGeometryAfter(
        _ revision: LayerSurfaceRevisionReference
    ) throws -> PixelSize {
        try restoreLayerGeometry(revision, endpoint: .after)
    }

    private func restoreLayerGeometry(
        _ revision: LayerSurfaceRevisionReference,
        endpoint: LayerSurfaceRevisionEndpoint
    ) throws -> PixelSize {
        let result = try paintContext.restoreLayerStack(
            revision,
            endpoint: endpoint
        )
        let strategy = try TilingStrategy(
            documentConfiguration: documentConfiguration,
            canvasSize: result.afterGeometry.documentPixelSize
        )
        let storageSize = PixelSize(
            width: Int(strategy.tileSize.width),
            height: Int(strategy.tileSize.height)
        )
        guard storageSize == result.afterGeometry.storagePixelSize,
              strategy.compiledSymmetry.domain.finite?.radial.layout
                == result.afterGeometry.radialLayout
        else {
            throw MetalRendererError.commandFailed(
                "Layer geometry revision does not match the active symmetry configuration."
            )
        }
        installPaintGeometry(strategy: strategy)
        invalidatePaintDisplayPreparation()
        return result.afterGeometry.documentPixelSize
    }

    public func containsLayerRevision(
        _ id: StoredRasterRevisionID
    ) -> Bool {
        paintContext.containsLayerRevision(id)
    }

    public func clearDocument(
        token: RendererOperationToken
    ) async throws {
        do {
            let result = try await paintContext.clear()
            await refreshPaintRevisionResidentBytes()
            setDocumentGeometryLocked(false)
            try publishPaintMutation(result, token: token)
            invalidatePaintDisplayPreparation()
        } catch {
            let rendererError = currentPaintError(error)
            report(rendererError)
            stageRendererEvent(
                .operationCompleted(.failure(token, rendererError))
            )
            throw rendererError
        }
    }

    public func resizeDocument(
        token: RendererOperationToken,
        to pixelSize: PixelSize
    ) async throws {
        do {
            let strategy = try TilingStrategy(
                documentConfiguration: documentConfiguration,
                canvasSize: pixelSize
            )
            let storageSize = PixelSize(
                width: Int(strategy.tileSize.width),
                height: Int(strategy.tileSize.height)
            )
            let geometry = try DocumentPaintGeometry(
                documentPixelSize: pixelSize,
                storagePixelSize: storageSize,
                radialLayout:
                    strategy.compiledSymmetry.domain.finite?.radial.layout
            )
            let result = try await paintContext.resize(
                to: geometry,
                targetRadialConfiguration:
                    strategy.compiledSymmetry.domain.finite?.radial
                        .configuration
            )
            await refreshPaintRevisionResidentBytes()
            installPaintGeometry(strategy: strategy)
            if let result {
                guard let revision = result.revision else {
                    throw MetalRendererError.commandFailed(
                        "Published geometry change has no history revision."
                    )
                }
                stageRendererEvent(.operationCompleted(
                    .layerGeometrySuccess(LayerGeometryMutationReceipt(
                        token: token,
                        beforePixelSize:
                            result.beforeGeometry.documentPixelSize,
                        afterPixelSize:
                            result.afterGeometry.documentPixelSize,
                        revision: revision
                    ))
                ))
            } else {
                stageRendererEvent(
                    .operationCompleted(.operationSuccess(token))
                )
            }
            invalidatePaintDisplayPreparation()
        } catch {
            let rendererError = currentPaintError(error)
            report(rendererError)
            stageRendererEvent(
                .operationCompleted(.failure(token, rendererError))
            )
            throw rendererError
        }
    }

    public func restoreDocumentRevision(
        token: RendererOperationToken,
        revision: RasterRevisionReference,
        targetPixelSize: PixelSize? = nil
    ) async throws {
        do {
            let documentSize = targetPixelSize
                ?? revision.documentPixelSize
            let strategy = try TilingStrategy(
                documentConfiguration: documentConfiguration,
                canvasSize: documentSize
            )
            let storageSize = PixelSize(
                width: Int(strategy.tileSize.width),
                height: Int(strategy.tileSize.height)
            )
            let geometry = try DocumentPaintGeometry(
                documentPixelSize: documentSize,
                storagePixelSize: storageSize,
                radialLayout:
                    strategy.compiledSymmetry.domain.finite?.radial.layout
            )
            _ = try await paintContext.restorePublishedRevision(
                revision,
                targetGeometry: geometry
            )
            await refreshPaintRevisionResidentBytes()
            installPaintGeometry(strategy: strategy)
            setDocumentGeometryLocked(!revision.tileCoordinates.isEmpty)
            stageRendererEvent(
                .operationCompleted(.operationSuccess(token))
            )
            invalidatePaintDisplayPreparation()
        } catch {
            let rendererError = currentPaintError(error)
            report(rendererError)
            stageRendererEvent(
                .operationCompleted(.failure(token, rendererError))
            )
            throw rendererError
        }
    }

    private func publishPaintMutation(
        _ result: DocumentPaintSurfaceApplicationResult,
        token: RendererOperationToken
    ) throws {
        if let pair = result.historyPair {
            stageRendererEvent(.operationCompleted(.rasterSuccess(
                RasterMutationReceipt(
                    token: token,
                    before: pair.before,
                    after: pair.after
                )
            )))
        } else {
            stageRendererEvent(.operationCompleted(.operationSuccess(token)))
        }
    }

    private func refreshPaintRevisionResidentBytes() async {
        paintRevisionResidentBytesState = await paintContext.snapshot()
            .revisionResidentBytes
    }

    private func installPaintGeometry(strategy: TilingStrategy) {
        let canvasSizeChanged = strategy.canvasSize != pixelSize
        tilingStrategy = strategy
        documentPixelSizeState = strategy.canvasSize
        storagePixelSizeState = PixelSize(
            width: Int(strategy.tileSize.width),
            height: Int(strategy.tileSize.height)
        )
        if canvasSizeChanged {
            viewport = ViewportTransform(
                drawableSize: viewport.drawableSize,
                worldCenter: WorldPoint(
                    x: Float(strategy.canvasSize.width) * 0.5,
                    y: Float(strategy.canvasSize.height) * 0.5
                ),
                zoom: viewport.zoom
            )
        }
    }

    private func currentPaintError(_ error: Error) -> MetalRendererError {
        (error as? MetalRendererError)
            ?? .commandFailed(error.localizedDescription)
    }

    public func captureCommittedDocument() async throws
        -> CommittedDocumentSnapshot
    {
        try await paintContext.captureCommittedDocument(
            strategy: tilingStrategy,
            documentDomainLocked: documentDomainLocked,
            radialGeometryLocked: radialGeometryLocked,
            outputGeometryRevision: paintOutputGeometryRevision
        )
    }

    public func captureNativeArchive() throws
        -> DocumentPaintNativeArchiveCapture
    {
        try paintContext.captureNativeArchive()
    }

    public func importNativeArchive(
        _ manifest: DocumentPaintNativeArchiveImportManifest,
        documentDomainLocked: Bool,
        radialGeometryLocked: Bool,
        consume: @escaping @Sendable
            (DocumentPaintNativeArchiveImportWriter) throws -> Void
    ) async throws {
        try await paintContext.importNativeArchive(
            manifest,
            consume: consume
        )
        self.documentDomainLocked = documentDomainLocked
        self.radialGeometryLocked = radialGeometryLocked
        invalidatePaintDisplayPreparation()
    }

    /// Resolves committed finite paint at document-pixel geometry. Transient
    /// stroke surfaces, viewport state, and grid guides are excluded.
    public func exportFiniteCanvas(
        transparentBackground: Bool = false
    ) async throws -> FiniteCanvasExport {
        try await paintContext.exportFiniteCanvas(
            strategy: tilingStrategy,
            outputGeometryRevision: paintOutputGeometryRevision,
            transparentBackground: transparentBackground
        )
    }

    /// Resolves one half-open metric repeat from committed sparse paint.
    public func exportPeriodicRepeat(
        density: Int
    ) async throws -> PeriodicRepeatExport {
        try await paintContext.exportPeriodicMetric(
            strategy: tilingStrategy,
            density: density,
            outputGeometryRevision: paintOutputGeometryRevision
        )
    }

    /// Resolves the natural-density baked repeat from committed sparse paint.
    public func exportBakedPeriodicRepeat() async throws
        -> PeriodicRepeatExport
    {
        try await paintContext.exportPeriodicBaked(
            strategy: tilingStrategy,
            outputGeometryRevision: paintOutputGeometryRevision
        )
    }

    /// Flattens the committed preview viewport without guides or transient
    /// stroke pixels.
    public func exportFlattenedScene(
        pixelSize: PixelSize,
        transparentBackground: Bool = false
    ) async throws -> FlattenedSceneExport {
        let mapping: SparseTileSamplingOutputMapping
        if tilingStrategy.compiledSymmetry.domain.finite?.radial.layout != nil {
            mapping = try .finiteRadial(strategy: tilingStrategy)
        } else {
            let inverseZoom = 1 / viewport.zoom
            mapping = .affine(SparseTileOutputToSourceTransform(
                sourceOffset: viewport.worldCenter.simd - SIMD2(
                    Float(pixelSize.width) * 0.5 * inverseZoom,
                    Float(pixelSize.height) * 0.5 * inverseZoom
                ),
                sourceStep: SIMD2(repeating: inverseZoom)
            ))
        }
        let request = try DocumentPaintStableFlattenedOutputRequest(
            pixelSize: pixelSize,
            outputMapping: mapping,
            transparentBackground: transparentBackground
        )
        return try await paintContext.exportFlattenedScene(
            strategy: tilingStrategy,
            request: request,
            outputGeometryRevision: paintOutputGeometryRevision
        )
    }

    public func restoreCommittedDocument(
        _ snapshot: CommittedDocumentSnapshot
    ) async throws {
        guard snapshot.canvasSize == pixelSize,
              snapshot.documentConfiguration == documentConfiguration
        else {
            throw MetalRendererError.committedSnapshotIncompatible
        }
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: snapshot.canvasSize,
            storagePixelSize: storagePixelSize,
            radialLayout:
                tilingStrategy.compiledSymmetry.domain.finite?.radial.layout
        )
        let input: DocumentPaintEncodedImportInput
        switch snapshot.storage {
        case let .singleRaster(bytes):
            input = .singleRaster(DocumentPaintEncodedBGRA8PlaneInput(
                width: storagePixelSize.width,
                height: storagePixelSize.height,
                bytesPerRow: storagePixelSize.width * 4,
                bytes: Data(bytes)
            ))
        case let .radialPages(pages):
            input = .radialPages(pages.map {
                DocumentPaintEncodedBGRA8RadialPageInput(
                    coordinate: $0.coordinate,
                    plane: DocumentPaintEncodedBGRA8PlaneInput(
                        width: RadialSectorLayout.pageSide,
                        height: RadialSectorLayout.pageSide,
                        bytesPerRow: RadialSectorLayout.pageSide * 4,
                        bytes: Data($0.bgra8PremultipliedBytes)
                    )
                )
            })
        }
        let result = try await paintContext.importEncodedBGRA8(
            candidateGeometry: geometry,
            input: input
        )
        invalidatePaintDisplayPreparation()
        #if DEBUG
        if let paintRevisionReleaseFailureForTesting {
            self.paintRevisionReleaseFailureForTesting = nil
            throw paintRevisionReleaseFailureForTesting
        }
        #endif
        if let pair = result.historyPair {
            try await paintContext.releaseRevisions([
                pair.before.id,
                pair.after.id,
            ])
        }
        await refreshPaintRevisionResidentBytes()
        documentDomainLocked = snapshot.documentDomainLocked
        radialGeometryLocked = snapshot.radialGeometryLocked
    }

    func shutdown(
        reason: DocumentPaintRenderContextShutdownReason
    ) async throws -> DocumentPaintRenderContextShutdownSnapshot {
        if let paintCommitTask {
            if paintCommitPublicationState?.claimFailure() != false {
                paintCommitTask.cancel()
            }
            await paintCommitTask.value
        }
        if let execution = activeStroke {
            finishPaintStrokeFailure(
                token: execution.token,
                error: .commandFailed(
                    "stroke cancelled during renderer shutdown"
                )
            )
        }
        var epochByIdentity = interactiveStrokeCacheLifecycleEpochObjects
        if let activeEpoch = activeStrokeTileSurfaceResources?
            .capability.presentationEpoch
        {
            epochByIdentity[activeEpoch.identity] = activeEpoch
        }
        for epoch in epochByIdentity.values {
            InteractiveStrokeCacheLifecycleCoordinator.shared
                .requestCancellation(
                    cache: interactiveStrokePresentationCache,
                    strokeEpoch: epoch
                )
        }
        if activeStroke == nil, !isIdle {
            _ = try await completePendingInteractiveStrokeAndAwaitIdle()
        }
        let snapshot = try await paintContext.shutdown(reason: reason)
        guard activeStroke == nil, isIdle else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        return snapshot
    }

    /// Awaits a previously requested current stroke commit and returns only
    /// after the Context-owned stroke surface and worker workspace are reusable.
    public func completePendingInteractiveStrokeAndAwaitIdle(
        deadlineUptimeNanoseconds: UInt64? = nil
    ) async throws
        -> GPUFrameMetrics
    {
        var frames: [GPUFrameMetrics] = []
        guard let mailbox = strokePreparationBridge?.mailbox else {
            guard activeStroke == nil, isIdle else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            return GPUFrameMetrics(
                cpuEncodeMilliseconds: 0,
                gpuMilliseconds: 0
            )
        }
        guard !exclusiveInteractiveCompletionDrainInProgress else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        exclusiveInteractiveCompletionDrainInProgress = true
        defer {
            exclusiveInteractiveCompletionDrainInProgress = false
            if let paintDisplayView {
                schedulePaintDisplayPreparation(in: paintDisplayView)
            }
        }
        guard await awaitRetiringPaintDisplayPreparation(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        ) else {
            throw MetalRendererError.commandFailed(
                "retiring paint display preparation exceeded "
                    + "the stroke completion deadline"
            )
        }
        let pendingDisplayPreparation = paintDisplayPreparationTask
        invalidatePaintDisplayPreparation(reschedule: false)
        guard await waitForPaintDisplayPreparationTermination(
            pendingDisplayPreparation,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        ) else {
            if let pendingDisplayPreparation {
                trackRetiringPaintDisplayPreparation(
                    pendingDisplayPreparation
                )
            }
            throw MetalRendererError.commandFailed(
                "paint display preparation cancellation exceeded "
                    + "the stroke completion deadline"
            )
        }
        try checkInteractiveCompletionDeadline(deadlineUptimeNanoseconds)
        try await paintContext.retryLayerDisplayCompletions()
        while true {
            try Task.checkCancellation()
            try checkInteractiveCompletionDeadline(
                deadlineUptimeNanoseconds
            )
            try drainCompletedInteractiveOperations()
            if activeStroke == nil, isIdle { break }
            if let frame = try await renderCurrentPaintFrameForHarness(
                width: pixelSize.width,
                height: pixelSize.height,
                includeTransient: true
            ) {
                frames.append(frame.metrics)
                try checkInteractiveCompletionDeadline(
                    deadlineUptimeNanoseconds
                )
                continue
            }
            let progress = StrokePreparationAsyncProgressRegistration(
                mailbox: mailbox
            )
            let observedRevision = progress.currentRevision
            defer { progress.remove() }
            try drainCompletedInteractiveOperations()
            if activeStroke == nil, isIdle { break }
            if progress.currentRevision != observedRevision { continue }
            guard try await progress.waitForProgress(
                after: observedRevision,
                timeoutNanoseconds: try interactiveCompletionWaitNanoseconds(
                    deadlineUptimeNanoseconds
                )
            ) else {
                let snapshot = mailbox.snapshot
                let context = await paintContext.snapshot()
                throw lastError ?? MetalRendererError.commandFailed(
                    "stroke completion exceeded its inactivity bound "
                        + "(workspace: \(strokeWorkspaceState), "
                        + "input: \(snapshot.input.hasPendingInput), "
                        + "results: \(snapshot.pendingResultCount), "
                        + "awaitingACK: "
                        + "\(snapshot.awaitingPreparedFrameSubmission), "
                        + "worker: \(snapshot.workerIsProcessing), "
                        + "layerDisplay: "
                        + "\(context.pendingLayerDisplayAcknowledgementCount), "
                        + "compositorBusy: "
                        + "\(context.layerCompositor.isBusy))"
                )
            }
        }
        return GPUFrameMetrics(
            cpuEncodeMilliseconds: frames.reduce(0) {
                $0 + $1.cpuEncodeMilliseconds
            },
            gpuMilliseconds: frames.reduce(0) {
                $0 + $1.gpuMilliseconds
            },
            eventToSubmitNanoseconds:
                frames.map(\.eventToSubmitNanoseconds).max() ?? 0,
            gpuCompletionNanoseconds: frames.reduce(0) {
                Self.saturatingAdd($0, $1.gpuCompletionNanoseconds)
            },
            encodedDabCount: frames.reduce(0) {
                $0 + $1.encodedDabCount
            },
            encodedInstanceCount: frames.reduce(0) {
                $0 + $1.encodedInstanceCount
            },
            bufferLeaseCount:
                frames.map(\.bufferLeaseCount).max() ?? 0
        )
    }

    private func checkInteractiveCompletionDeadline(
        _ deadlineUptimeNanoseconds: UInt64?
    ) throws {
        guard let deadlineUptimeNanoseconds else { return }
        guard DispatchTime.now().uptimeNanoseconds
                < deadlineUptimeNanoseconds
        else {
            throw MetalRendererError.commandFailed(
                "stroke completion exceeded its absolute deadline"
            )
        }
    }

    private func interactiveCompletionWaitNanoseconds(
        _ deadlineUptimeNanoseconds: UInt64?
    ) throws -> UInt64 {
        guard let deadlineUptimeNanoseconds else {
            return 5_000_000_000
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineUptimeNanoseconds else {
            throw MetalRendererError.commandFailed(
                "stroke completion exceeded its absolute deadline"
            )
        }
        return min(5_000_000_000, deadlineUptimeNanoseconds - now)
    }

    public func awaitPendingStrokeWorkspaceRetirement() async throws {
        guard case let .retiring(generation) = strokeWorkspaceState else {
            return
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try drainCompletedInteractiveOperations()
            if let source = activePaintTransientSource {
                switch source.acknowledgementStatus {
                case .available, .pending:
                    try await paintContext.abandonTransientDisplaySource(
                        source
                    )
                    if activePaintTransientSource?.sourceIdentity
                        == source.sourceIdentity
                    {
                        activePaintTransientSource = nil
                    }
                case .fulfilled:
                    if activePaintTransientSource?.sourceIdentity
                        == source.sourceIdentity
                    {
                        activePaintTransientSource = nil
                    }
                case let .failed(error):
                    throw MetalRendererError.commandFailed(
                        "transient display acknowledgement failed: \(error)"
                    )
                }
            }
            try drainCompletedInteractiveOperations()
            if strokeWorkspaceState != .retiring(generation) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw MetalRendererError.commandFailed(
            "stroke workspace retirement exceeded its bound"
        )
    }


    func drainCompletedInteractiveOperations() throws {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        do {
            try drainCompletedInteractiveOperationsCore()
        } catch let error as MetalRendererError {
            failActiveOperationIfNeeded(error)
            throw error
        } catch {
            let rendererError = MetalRendererError.commandFailed(
                error.localizedDescription
            )
            failActiveOperationIfNeeded(rendererError)
            throw rendererError
        }
    }

    private func drainCompletedInteractiveOperationsCore() throws {
        try drainStrokePreparationResultsCore()
    }

    private func startPaintLifecyclePump() {
        guard paintLifecycleTask == nil else { return }
        paintLifecycleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let shouldContinue = self?
                    .performPaintLifecycleTurn()
                else { return }
                if !shouldContinue {
                    self?.paintLifecycleTask = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            self?.paintLifecycleTask = nil
        }
    }

    /// One non-suspending lifecycle turn. Keeping the strong renderer borrow
    /// inside this call prevents the stored pump task from retaining Grid
    /// across its bounded sleep when all external owners have disappeared.
    private func performPaintLifecycleTurn() -> Bool {
        do {
            try drainStrokePreparationResultsCore()
        } catch let error as MetalRendererError {
            failActiveOperationIfNeeded(error)
        } catch {
            failActiveOperationIfNeeded(
                .commandFailed(error.localizedDescription)
            )
        }
        return activeStroke != nil
            || strokeWorkspaceState != .available
            || paintCommitTask != nil
    }

    private func drainStrokePreparationResultsCore() throws {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        guard let bridge = strokePreparationBridge else { return }
        // Cache completion returns the worker's one prepared-page credit
        // before the MainActor terminal callback clears its task handle. A
        // following page may therefore already be published. Leave it in the
        // bounded mailbox until the prior adoption handoff is terminal.
        guard interactiveStrokeCacheAdoptionTask == nil else { return }
        bridge.drainResults(into: &strokePreparationResultScratch)
        #if DEBUG
        let observesSyntheticZeroWorkAcknowledgement =
            strokePreparationResultScratch.contains { result in
                if case let .prepared(batch) = result {
                    return batch.isSyntheticZeroWorkContinuation
                }
                return false
            }
        if observesSyntheticZeroWorkAcknowledgement {
            bridge.beginResultOwnershipWindowForTesting()
        }
        #endif
        var deferredZeroWorkAcknowledgement:
            (generation: UInt64, token: UInt64)?
        do {
            for result in strokePreparationResultScratch {
                guard result.generation == strokePreparationGeneration else {
                    continue
                }
                switch result {
                case let .prepared(batch):
                    let acknowledgement = try installPreparedStrokeBatch(batch)
                    if let acknowledgement {
                        precondition(deferredZeroWorkAcknowledgement == nil)
                        deferredZeroWorkAcknowledgement = acknowledgement
                    }
                case .predictionWasShed:
                    break
                case .estimatedUpdateWasIgnored:
                    break
                case let .estimatedUpdateWasRejected(
                    _,
                    error,
                    capacityFailure
                ):
                    if let capacityFailure {
                        throw rendererError(for: capacityFailure)
                    }
                    throw error
                case let .commitBarrierReached(
                    _,
                    commitMutation
                ):
                    try beginPaintStrokeCommit(commitMutation)
                case let .cancelled(generation, _):
                    if strokeWorkspaceState == .retiring(generation) {
                        finishStrokeWorkspaceRetirement(
                            generation: generation
                        )
                        continue
                    }
                    throw MetalRendererError.invalidStrokeLifecycle
                case let .failed(_, failure):
                    if case let .retiring(generation) = strokeWorkspaceState,
                       generation == result.generation
                    {
                        if !strokeWorkspaceRetirementErrorWasReported {
                            strokeWorkspaceRetirementErrorWasReported = true
                            report(rendererError(for: failure))
                        }
                        continue
                    }
                    throw rendererError(for: failure)
                }
            }
        } catch {
            strokePreparationResultScratch.removeAll(keepingCapacity: true)
            #if DEBUG
            if observesSyntheticZeroWorkAcknowledgement {
                bridge.cancelResultOwnershipWindowForTesting()
            }
            #endif
            throw error
        }
        // Prepared dab/dirty views are valid only through ACK. Release every
        // result that owns those views before returning the page lease.
        strokePreparationResultScratch.removeAll(keepingCapacity: true)
        #if DEBUG
        if observesSyntheticZeroWorkAcknowledgement {
            bridge.markResultOwnershipReleasedForTesting()
        }
        #endif
        if let deferredZeroWorkAcknowledgement {
            try bridge.acknowledgePreparedFrame(
                generation: deferredZeroWorkAcknowledgement.generation,
                token: deferredZeroWorkAcknowledgement.token
            )
            lastOffMainZeroWorkLeaseCount += 1
        } else {
            #if DEBUG
            if observesSyntheticZeroWorkAcknowledgement {
                bridge.cancelResultOwnershipWindowForTesting()
            }
            #endif
        }
    }

    private func beginPaintStrokeCommit(
        _ mutation: StrokePreparedCommitMutation
    ) throws {
        guard paintCommitTask == nil,
              let execution = activeStroke,
              execution.commitRequested
        else { throw MetalRendererError.invalidStrokeLifecycle }
        let parameters = StrokeCommitter.parameters(
            mode: execution.style.compositeMode,
            strokeOpacity: execution.style.color.alpha,
            eraserStrength: execution.style.eraserStrength
        )
        let token = execution.token
        let context = paintContext
        let capability = activeStrokeTileSurfaceResources?.capability
        let publicationState = StrokeCommitPublicationState()
        paintCommitPublicationState = publicationState
        #if DEBUG
        let commitGate = paintStrokeCommitGateForTesting
        let injectedCommitFailure = paintStrokeCommitFailureForTesting
        paintStrokeCommitFailureForTesting = nil
        #endif
        paintCommitTask = Task { @MainActor [weak self] in
            do {
                #if DEBUG
                await commitGate?.waitBeforeCommit()
                if let injectedCommitFailure {
                    throw injectedCommitFailure
                }
                #endif
                try Task.checkCancellation()
                let result = try await StrokeCommitter.commit(
                    mutation,
                    context: context,
                    capability: capability,
                    parameters: parameters,
                    publicationState: publicationState
                )
                // StrokeCommitter returns only after the Context has
                // irreversibly published its canonical revision and history.
                // Cancellation beyond this linearization point must finalize
                // that success; reporting a cancelled operation would invent
                // a rollback that did not occur.
                let revisionResidentBytes = await context.snapshot()
                    .revisionResidentBytes
                guard let self else { return }
                guard let current = self.activeStroke,
                      current.token == token
                else { throw MetalRendererError.invalidRendererOperationToken }
                self.paintRevisionResidentBytesState = revisionResidentBytes
                self.finishPaintStrokeCommit(
                    result,
                    execution: current
                )
            } catch is CancellationError {
                if case let .source(source) = mutation {
                    try? source.cancelUnclaimed()
                }
                self?.finishPaintStrokeFailure(
                    token: token,
                    error: .commandFailed("stroke commit cancelled")
                )
            } catch let error as MetalRendererError {
                self?.finishPaintStrokeFailure(token: token, error: error)
            } catch {
                self?.finishPaintStrokeFailure(
                    token: token,
                    error: .commandFailed(error.localizedDescription)
                )
            }
        }
    }

    private func finishPaintStrokeCommit(
        _ result: DocumentPaintSurfaceApplicationResult,
        execution: ActiveStrokeExecution
    ) {
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        let runtimeEndEvents = endStrokeRuntimeIfPossible()
        activeStroke = nil
        activePaintTransientSource = nil
        paintCommitTask = nil
        paintCommitPublicationState = nil
        resetLiveState(invalidateStrokeEvents: false)
        setDocumentGeometryLocked(result.didPublish || documentDomainLocked)
        stageStrokeRuntimeEvents(runtimeEndEvents)
        if let pair = result.historyPair {
            stageRendererEvent(.operationCompleted(.rasterSuccess(
                RasterMutationReceipt(
                    token: execution.token,
                    before: pair.before,
                    after: pair.after
                )
            )))
        } else {
            stageRendererEvent(
                .operationCompleted(.operationSuccess(execution.token))
            )
        }
        invalidatePaintDisplayPreparation()
    }

    private func finishPaintStrokeFailure(
        token: RendererOperationToken,
        error: MetalRendererError
    ) {
        guard activeStroke?.token == token else {
            let wasIdle = isIdle
            paintCommitTask = nil
            paintCommitPublicationState = nil
            notifyIdleStateIfChanged(from: wasIdle)
            return
        }
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        let runtimeEndEvents = endStrokeRuntimeIfPossible()
        activeStroke = nil
        activePaintTransientSource = nil
        paintCommitTask = nil
        paintCommitPublicationState = nil
        resetLiveState()
        stageStrokeRuntimeEvents(runtimeEndEvents)
        report(error)
        stageRendererEvent(.operationCompleted(.failure(token, error)))
        invalidatePaintDisplayPreparation()
    }

    private func rendererError(
        for failure: StrokePreparationFailure
    ) -> MetalRendererError {
        switch failure {
        case let .scheduler(
            .authoritativeCapacityExceeded(_, _, _, maximum)
        ):
            return .projectedInstanceCapacityExceeded(maximum)
        case let .scheduler(
            .strokeSampleCapacityExceeded(_, maximum)
        ):
            return .strokeSampleCapacityExceeded(maximum)
        case let .scheduler(
            .generatedDabCapacityExceeded(_, maximum)
        ), let .dabArenaCapacityExceeded(_, maximum):
            return .generatedDabCapacityExceeded(maximum)
        case let .scheduler(
            .projectedInstanceCapacityExceeded(_, maximum)
        ), let .scheduler(.replayCapacityExceeded(_, maximum)):
            return .projectedInstanceCapacityExceeded(maximum)
        case let .authoritativeQueue(
            .capacityExceeded(_, _, maximum)
        ):
            return .generatedDabCapacityExceeded(maximum)
        case .coordinator(.invalidLifecycle),
             .scheduler(.invalidLifecycle),
             .scheduler(.staleGeneration),
             .scheduler(.invalidPreparedFrame),
             .scheduler(.missingGeneratorCheckpoint):
            return .invalidStrokeLifecycle
        case .coordinator,
             .cornerEmission,
             .authoritativeQueue,
             .injectedStageC,
             .scheduler,
             .stampPacking,
             .privateSurfaceEncoding,
             .tileSurface,
             .transientBuffer,
             .unexpected:
            return .commandFailed(
                "stroke preparation failed: \(failure)"
            )
        }
    }

    private func rendererError(
        for failure: StrokePreparationCapacityFailure
    ) -> MetalRendererError {
        switch failure {
        case let .strokeSamples(_, maximum):
            .strokeSampleCapacityExceeded(maximum)
        case let .generatedDabs(_, maximum):
            .generatedDabCapacityExceeded(maximum)
        case let .projectedInstances(_, maximum):
            .projectedInstanceCapacityExceeded(maximum)
        }
    }

    private func installPreparedStrokeBatch(
        _ batch: StrokePreparedDepositionBatch
    ) throws -> (generation: UInt64, token: UInt64)? {
        guard batch.generation == strokePreparationGeneration,
              activeStroke != nil
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let totalInstanceCount = batch.authoritativeInstanceCount
            + batch.predictedInstanceCount
        lastOffMainSurfaceSnapshot = batch.surfaceSnapshot
        lastOffMainReplayRetention = batch.replayRetention
        lastOffMainPredictedInstanceCount = batch.predictedInstanceCount

        if let surfaceLease = batch.surfaceLease {
            lastOffMainEncodingRanOnMainThread =
                surfaceLease.encodingRanOnMainThread
            guard batch.frameToken == surfaceLease.token,
                  let displayFrame = batch.displayFrame
            else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            guard interactiveStrokeCacheAdoptionTask == nil else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            let sequence = nextInteractiveStrokeCacheSequence
            let (nextSequence, sequenceOverflow) = sequence
                .addingReportingOverflow(1)
            guard !sequenceOverflow else {
                throw MetalRendererError.commandFailed(
                    "interactive stroke cache sequence overflow"
                )
            }
            guard let transientLayerID = displayFrame.surface.layerID else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            let parameters = try paintContext
                .interactiveStrokeCompositeParameters(
                    layerID: transientLayerID
                )
            let update = try paintContext.makeTransientCacheUpdate(
                frame: displayFrame,
                sequence: sequence
            )
            nextInteractiveStrokeCacheSequence = nextSequence
            let lifecycleIdentity = update.presentationEpoch.identity
            interactiveStrokeCacheLifecycleEpochs.insert(lifecycleIdentity)
            interactiveStrokeCacheLifecycleEpochObjects[lifecycleIdentity] =
                update.presentationEpoch
            lastInteractiveStrokeCacheLifecycleIdentity = lifecycleIdentity
            interactiveStrokeCacheAdoptionTask =
                InteractiveStrokeCacheAdoptionOperation.start(
                    cache: interactiveStrokePresentationCache,
                    update: update,
                    parameters: parameters,
                    terminal: { [weak self] error in
                        guard let self else { return false }
                        self.interactiveStrokeCacheAdoptionTask = nil
                        if error == nil {
                            self.invalidatePaintDisplayPreparation()
                        } else if let error,
                                  !(error is CancellationError)
                        {
                            let rendererError = (error as? MetalRendererError)
                                ?? .commandFailed(
                                    error.localizedDescription
                                )
                            self.paintCommandError = rendererError
                            self.failActiveOperationIfNeeded(rendererError)
                        }
                        return true
                    },
                    lifecycleTerminal: { [weak self] _ in
                        guard let self else { return }
                        let wasIdle = self.isIdle
                        self.interactiveStrokeCacheLifecycleEpochs.remove(
                            lifecycleIdentity
                        )
                        self.interactiveStrokeCacheLifecycleEpochObjects
                            .removeValue(forKey: lifecycleIdentity)
                        self.notifyIdleStateIfChanged(from: wasIdle)
                    }
                )
            pendingPaintHarnessDabCount = batch.logicalDabs.count
            pendingPaintHarnessInstanceCount = totalInstanceCount
            if totalInstanceCount == 0 {
                lastOffMainZeroWorkLeaseCount += 1
            }
        } else if batch.isSyntheticZeroWorkContinuation
        {
            // A clipped page has no GPU submission to return its synthetic
            // lease. Defer the acknowledgement until the caller releases the
            // immutable result payload that owns this page's logical dabs.
        } else if batch.frameToken != nil || totalInstanceCount != 0 {
            throw MetalRendererError.invalidStrokeLifecycle
        }

        let authoritativeInstanceCount = UInt64(
            batch.newAuthoritativeInstanceCount
        )
        let (scheduledHighWater, scheduledOverflow) =
            scheduledAuthoritativeIdentityHighWater
                .addingReportingOverflow(
                    authoritativeInstanceCount
                )
        let encodedRangeLowerBound =
            encodedAuthoritativeIdentityHighWater
        let (encodedHighWater, encodedOverflow) =
            encodedRangeLowerBound.addingReportingOverflow(
                authoritativeInstanceCount
            )
        guard !scheduledOverflow, !encodedOverflow else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                depositionFrameBudget.maximumPendingAuthoritativeInstances
            )
        }
        scheduledAuthoritativeIdentityHighWater = scheduledHighWater
        encodedAuthoritativeIdentityHighWater = encodedHighWater
        if authoritativeInstanceCount != 0 {
            let encodedRange = encodedRangeLowerBound..<encodedHighWater
            if let pendingRange = pendingEncodedAuthoritativeIdentityRange {
                precondition(pendingRange.upperBound == encodedRange.lowerBound)
                pendingEncodedAuthoritativeIdentityRange =
                    pendingRange.lowerBound..<encodedRange.upperBound
            } else {
                pendingEncodedAuthoritativeIdentityRange = encodedRange
            }
        }
        counters.newDabsThisEvent = batch.logicalDabs.count
        counters.newInstancesThisFrame = totalInstanceCount
        counters.totalDabsThisStroke += batch.logicalDabs.count
        counters.totalInstancesThisStroke += totalInstanceCount
        deferLogicalDabsForPublication(batch.logicalDabs)
        lastOffMainCoordinatorSnapshot = batch.coordinatorSnapshot
        if let scheduler = activeStroke?.frozenHarnessScheduler {
            recordBrushLabScheduler(scheduler)
        }
        if batch.isSyntheticZeroWorkContinuation,
           let token = batch.frameToken
        {
            return (batch.generation, token)
        }
        return nil
    }

    public func draw(in view: MTKView) {
        paintDisplayView = view
        if paintDisplayPreparationSequence == 0 {
            interactiveFramePump.signal(.input)
        }
        let requestedRevision = interactiveFramePump.beginFrame()
        guard !exclusiveInteractiveCompletionDrainInProgress else {
            finishInteractiveFrame(
                .noCompatibleSnapshot(requestedRevision),
                in: view
            )
            return
        }
        guard let prepared = preparedPaintDisplay else {
            schedulePaintDisplayPreparation(in: view)
            finishInteractiveFrame(
                .noCompatibleSnapshot(
                    pendingLatestPaintDisplaySnapshot?.revision
                        ?? requestedRevision
                ),
                in: view
            )
            return
        }
        guard let currentSnapshot = makePaintDisplaySnapshot(
            revision: CanvasPresentationRevision(
                sequence: paintDisplayPreparationSequence
            ),
            in: view,
            transient: activePaintTransientSource
        ) else {
            finishInteractiveFrame(
                .drawableUnavailable(prepared.snapshot.revision),
                in: view
            )
            return
        }
        do {
            try prepared.snapshot.validateCompatibility(
                with: currentSnapshot
            )
        } catch {
            try? paintContext.cancelLayerDisplaySubmission(
                prepared.submission
            )
            preparedPaintDisplay = nil
            invalidatePaintDisplayPreparation()
            finishInteractiveFrame(
                .superseded(prepared.snapshot.revision),
                in: view
            )
            return
        }
        guard let drawable = view.currentDrawable else {
            finishInteractiveFrame(
                .drawableUnavailable(prepared.snapshot.revision),
                in: view
            )
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            failActiveOperationIfNeeded(.commandBufferUnavailable)
            finishInteractiveFrame(
                .failed(
                    prepared.snapshot.revision,
                    "command buffer unavailable"
                ),
                in: view
            )
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor =
            GridCanvasContract.paperClearColor

        preparedPaintDisplay = nil
        do {
            try paintContext.encodeLayerDisplaySubmission(
                prepared.submission,
                target: drawable.texture,
                commandBuffer: commandBuffer,
                renderPassDescriptor: pass
            )
            let targetFramesPerSecond = max(
                1,
                view.preferredFramesPerSecond
            )
            let runtimeFrameID = beginStrokeRuntimeFrame(
                at: DispatchTime.now().uptimeNanoseconds,
                targetFrameDurationNanoseconds:
                    UInt64(1_000_000_000 / targetFramesPerSecond)
            )
            recordStrokeRuntimePreparedFrame(
                id: runtimeFrameID
            )
            let submittedAt = DispatchTime.now().uptimeNanoseconds
            recordStrokeRuntimeSubmittedFrame(
                id: runtimeFrameID,
                at: submittedAt
            )
            commandBuffer.addCompletedHandler { [weak self] completed in
                let succeeded = completed.status == .completed
                let message = completed.error?.localizedDescription
                let gpuStarted = Self.nanoseconds(completed.gpuStartTime)
                let gpuFinished = Self.nanoseconds(completed.gpuEndTime)
                let completedAt = DispatchTime.now().uptimeNanoseconds
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.paintContext
                            .retryLayerDisplayCompletions()
                        if self.activePaintTransientSource?
                            .acknowledgementStatus == .fulfilled
                        {
                            self.activePaintTransientSource = nil
                        }
                    } catch {
                        self.paintCommandError =
                            .commandFailed(error.localizedDescription)
                    }
                    if let runtimeFrameID {
                        if succeeded {
                            #if targetEnvironment(simulator)
                            self.recordStrokeRuntimeCompletedFrame(
                                id: runtimeFrameID,
                                measuredGPUStart: gpuStarted,
                                measuredGPUEnd: gpuFinished,
                                submittedAt: submittedAt,
                                completedAt: completedAt
                            )
                            #else
                            self.recordStrokeRuntimeGPUFrame(
                                id: runtimeFrameID,
                                measuredStart: gpuStarted,
                                measuredFinish: gpuFinished,
                                submittedAt: submittedAt
                            )
                            #endif
                        } else {
                            self.discardStrokeRuntimeFrame(runtimeFrameID)
                        }
                    }
                    if !succeeded {
                        self.failActiveOperationIfNeeded(
                            .commandFailed(
                                message ?? "paint display command failed"
                            )
                        )
                    }
                    if let paintDisplayView = self.paintDisplayView {
                        self.requestInteractiveFrameAfterCommandCompletion(
                            in: paintDisplayView
                        )
                    }
                    self.startPaintLifecyclePump()
                }
            }
            registerDrawablePresentation(
                revision: prepared.snapshot.revision,
                drawable: drawable,
                in: view
            )
            commandBuffer.present(drawable)
            if activeStroke != nil {
                counters.renderedFramesThisStroke += 1
            }
            commandBuffer.commit()
            finishInteractiveFrame(
                .submitted(prepared.snapshot.revision),
                in: view
            )
        } catch let error as MetalRendererError {
            try? paintContext.cancelLayerDisplaySubmission(
                prepared.submission
            )
            failActiveOperationIfNeeded(error)
            finishInteractiveFrame(
                .failed(
                    prepared.snapshot.revision,
                    error.localizedDescription
                ),
                in: view
            )
        } catch {
            try? paintContext.cancelLayerDisplaySubmission(
                prepared.submission
            )
            failActiveOperationIfNeeded(
                .commandFailed(error.localizedDescription)
            )
            finishInteractiveFrame(
                .failed(
                    prepared.snapshot.revision,
                    error.localizedDescription
                ),
                in: view
            )
        }
    }

    private func finishInteractiveFrame(
        _ outcome: InteractiveFrameOutcome,
        in view: MTKView
    ) {
        if interactiveFramePump.finishFrame(outcome) {
            requestPaintDisplay(in: view)
        }
    }

    private func registerDrawablePresentation(
        revision: CanvasPresentationRevision,
        drawable: (any CAMetalDrawable)?,
        in view: MTKView
    ) {
        let handler: @MainActor @Sendable () -> Void = {
            [weak self, weak view] in
            guard let self, let view else { return }
            self.handleDrawablePresented(revision: revision, in: view)
        }
        if let drawablePresentationRegistrar {
            drawablePresentationRegistrar.register(
                revision: revision,
                handler: handler
            )
            return
        }
        guard let drawable else { return }
        drawable.addPresentedHandler { _ in
            Task { @MainActor in handler() }
        }
    }

    private func handleDrawablePresented(
        revision: CanvasPresentationRevision,
        in view: MTKView
    ) {
        guard interactiveFramePump.markPresented(revision) else { return }
        presentationContinuationRequestCount += 1
        requestPaintDisplay(in: view)
    }

    private func requestInteractiveFrameAfterCommandCompletion(
        in view: MTKView
    ) {
        guard interactiveFramePump.hasDemand else { return }
        requestPaintDisplay(in: view)
    }

    func renderCurrentPaintFrameForHarness(
        width: Int,
        height: Int,
        includeTransient: Bool,
        showGridLines: Bool? = nil
    ) async throws -> RenderedFrame? {
        guard (1...4_096).contains(width),
              (1...4_096).contains(height)
        else { throw MetalRendererError.invalidDrawableSize }

        let transient: DocumentPaintTransientDisplaySource?
        if includeTransient {
            transient = try await awaitPaintTransientSourceForHarness()
            if transient == nil { return nil }
        } else {
            transient = nil
        }
        let outputSize = PixelSize(width: width, height: height)
        let submission = try await makePaintDisplaySubmission(
            outputPixelSize: outputSize,
            transient: transient,
            showGridLines: showGridLines
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: DocumentColorPipeline.displayPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            try? paintContext.cancelLayerDisplaySubmission(submission)
            throw MetalRendererError.textureAllocationFailed
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            try? paintContext.cancelLayerDisplaySubmission(submission)
            throw MetalRendererError.commandBufferUnavailable
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor =
            GridCanvasContract.paperClearColor
        let measuredSubmission: (
            completion: (
                Bool,
                String?,
                TimeInterval,
                TimeInterval,
                UInt64,
                UInt64
            ),
            cpuPreparationMilliseconds: Double
        )
        let runtimeFrameID = beginStrokeRuntimeFrame(
            at: DispatchTime.now().uptimeNanoseconds,
            targetFrameDurationNanoseconds: 16_666_667
        )
        do {
            measuredSubmission = try await Self
                .performMeasuredCPUPreparation(
                    clock: CFAbsoluteTimeGetCurrent,
                    preparation: {
                        try paintContext.encodeLayerDisplaySubmission(
                            submission,
                            target: texture,
                            commandBuffer: commandBuffer,
                            renderPassDescriptor: pass
                        )
                        recordStrokeRuntimePreparedFrame(
                            id: runtimeFrameID
                        )
                    },
                    waitForCompletion: {
                        await withCheckedContinuation {
                            (continuation: CheckedContinuation<(
                                Bool,
                                String?,
                                TimeInterval,
                                TimeInterval,
                                UInt64,
                                UInt64
                            ), Never>) in
                            let submittedAtNanoseconds =
                                DispatchTime.now().uptimeNanoseconds
                            recordStrokeRuntimeSubmittedFrame(
                                id: runtimeFrameID,
                                at: submittedAtNanoseconds
                            )
                            commandBuffer.addCompletedHandler { completed in
                                continuation.resume(returning: (
                                    completed.status == .completed,
                                    completed.error?.localizedDescription,
                                    completed.gpuStartTime,
                                    completed.gpuEndTime,
                                    submittedAtNanoseconds,
                                    DispatchTime.now().uptimeNanoseconds
                                ))
                            }
                            commandBuffer.commit()
                        }
                    }
                )
        } catch {
            if let runtimeFrameID {
                discardStrokeRuntimeFrame(runtimeFrameID)
            }
            try? paintContext.cancelLayerDisplaySubmission(submission)
            throw error
        }
        let completion = measuredSubmission.completion
        try await paintContext.retryLayerDisplayCompletions()
        if activePaintTransientSource?.acknowledgementStatus == .fulfilled {
            activePaintTransientSource = nil
        }
        startPaintLifecyclePump()
        guard completion.0 else {
            if let runtimeFrameID {
                discardStrokeRuntimeFrame(runtimeFrameID)
            }
            throw MetalRendererError.commandFailed(
                completion.1 ?? "paint display command failed"
            )
        }
        recordStrokeRuntimeCompletedFrame(
            id: runtimeFrameID,
            measuredGPUStart: Self.nanoseconds(completion.2),
            measuredGPUEnd: Self.nanoseconds(completion.3),
            submittedAt: completion.4,
            completedAt: completion.5
        )
        let encodedDabCount = transient == nil
            ? 0 : pendingPaintHarnessDabCount
        let encodedInstanceCount = transient == nil
            ? 0 : pendingPaintHarnessInstanceCount
        if transient != nil {
            pendingPaintHarnessDabCount = 0
            pendingPaintHarnessInstanceCount = 0
        }
        let frameMetrics = metrics(
            commandBuffer: commandBuffer,
            cpuMilliseconds: measuredSubmission.cpuPreparationMilliseconds,
            submittedAtNanoseconds: completion.4,
            completedAtNanoseconds: completion.5,
            encodedDabCount: encodedDabCount,
            encodedInstanceCount: encodedInstanceCount,
            bufferLeaseCount: 0
        )
        recordBrushLabCompletedFrame(frameMetrics)
        return RenderedFrame(texture: texture, metrics: frameMetrics)
    }

    private func awaitPaintTransientSourceForHarness() async throws
        -> DocumentPaintTransientDisplaySource?
    {
        guard let bridge = strokePreparationBridge else { return nil }
        let progress = StrokePreparationAsyncProgressRegistration(
            mailbox: bridge.mailbox
        )
        defer { progress.remove() }
        while true {
            let observedRevision = progress.currentRevision
            try drainCompletedInteractiveOperations()
            if let source = activePaintTransientSource {
                switch source.acknowledgementStatus {
                case .available:
                    return source
                case .pending:
                    try await paintContext
                        .retryLayerDisplayCompletions()
                case .fulfilled:
                    if activePaintTransientSource?.sourceIdentity
                        == source.sourceIdentity
                    {
                        activePaintTransientSource = nil
                    }
                case let .failed(error):
                    throw MetalRendererError.commandFailed(
                        "transient display acknowledgement failed: \(error)"
                    )
                }
                if source.acknowledgementStatus == .fulfilled,
                   activePaintTransientSource?.sourceIdentity
                    == source.sourceIdentity
                {
                    activePaintTransientSource = nil
                }
            }
            if bridge.mailbox.snapshot.isQuiescent {
                return nil
            }
            if progress.currentRevision != observedRevision { continue }
            guard try await progress.waitForProgress(
                after: observedRevision
            ) else {
                let snapshot = bridge.mailbox.snapshot
                let plan = await paintContext.snapshot().visiblePlan
                throw MetalRendererError.commandFailed(
                    "stroke surface preparation exceeded its harness bound "
                        + "(inputPending: \(snapshot.input.hasPendingInput), "
                        + "results: \(snapshot.pendingResultCount), "
                        + "awaitingACK: "
                        + "\(snapshot.awaitingPreparedFrameSubmission), "
                        + "awaitingIdentity: "
                        + "\(String(describing: snapshot.awaitingPreparedFrameGeneration))/"
                        + "\(String(describing: snapshot.awaitingPreparedFrameToken)), "
                        + "rendererGeneration: "
                        + "\(String(describing: strokePreparationGeneration)), "
                        + "ackQueued/inFlight: "
                        + "\(snapshot.pendingPreparedFrameAcknowledgement)/"
                        + "\(snapshot.preparedFrameAcknowledgementIsInFlight), "
                        + "workerActive: \(snapshot.workerIsProcessing), "
                        + "sourceACK: "
                        + "\(String(describing: activePaintTransientSource?.acknowledgementStatus)), "
                        + "plan: current=\(plan.currentPlanIdentity != nil)/"
                        + "presentable=\(plan.currentIsPresentable) "
                        + "prepared=\(plan.preparedPlanCount) "
                        + "retiring=\(plan.retiringPlanCount) "
                        + "submission=\(plan.preparedSubmissionCount)/"
                        + "\(plan.submittedSubmissionCount) completion="
                        + "\(plan.pendingPlanCompletionCount)/"
                        + "\(plan.pendingConsumerCompletionCount)/"
                        + "\(plan.pendingTerminalEventCount) transient="
                        + "\(plan.transientAcknowledgementOwnedCount)/"
                        + "\(plan.transientAcknowledgementPendingCount))"
                )
            }
        }
    }

    #if DEBUG
    nonisolated static func interactivePresentationTimestamp(
        presentedTime: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard presentedTime.isFinite, presentedTime > 0 else {
            return fallback
        }
        return presentedTime
    }
    #endif

    nonisolated static func interactiveFrameDemand(
        hasActiveStroke: Bool,
        isViewportAnimating: Bool,
        hasPendingComposite: Bool,
        isHUDSamplePending: Bool
    ) -> Bool {
        hasActiveStroke
            || isViewportAnimating
            || hasPendingComposite
            || isHUDSamplePending
    }

    public func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {
        guard size.width > 0, size.height > 0 else {
            return
        }
        resize(
            to: PatternSize(
                width: Float(size.width),
                height: Float(size.height)
            )
        )
    }


    package func setStrokePreparationAllocationProbeForHarness(
        _ probe: StrokePreparationAllocationProbe?
    ) {
        precondition(isIdle)
        strokePreparationAllocationProbe = probe
    }

    package func installStrokePreparationProgressWaiterForHarness()
        -> StrokePreparationProgressRegistration?
    {
        guard let mailbox = strokePreparationBridge?.mailbox else {
            return nil
        }
        return StrokePreparationProgressRegistration(mailbox: mailbox)
    }

    package func removeStrokePreparationProgressWaiterForHarness(
        _ registration: StrokePreparationProgressRegistration
    ) {
        registration.remove()
    }

    package var strokePreparationIsQuiescentForAllocationHarness: Bool {
        guard let snapshot = strokePreparationBridge?.mailbox.snapshot else {
            return true
        }
        return snapshot.isQuiescent
    }

    package var offMainStrokeWorkspaceIdentityForTesting: UUID {
        guard let resources = activeStrokeTileSurfaceResources else {
            preconditionFailure("No active sparse stroke workspace")
        }
        return resources.identity
    }

    package var offMainStrokeWorkspacePixelSizeForTesting: PixelSize {
        guard let resources = activeStrokeTileSurfaceResources else {
            preconditionFailure("No active sparse stroke workspace")
        }
        return resources.pixelSize
    }

    package var offMainStrokeWorkspaceInstallationCountForTesting: UInt64 {
        activeStrokeTileSurfaceResources == nil ? 0 : 1
    }

    package var offMainStrokeWorkspaceIsAvailableForAllocationHarness: Bool {
        strokeWorkspaceState == .available
    }

    var offMainCoordinatorSnapshotForHarness: StrokeRenderSnapshot? {
        lastOffMainCoordinatorSnapshot
    }

    var offMainSurfaceSnapshotForHarness:
        StrokePrivateSurfaceEncoderSnapshot?
    {
        lastOffMainSurfaceSnapshot
    }

    var offMainReplayRetentionForHarness: StrokePreparedReplayRetention {
        lastOffMainReplayRetention
    }

    func takeEncodedAuthoritativeIdentityRangesForHarness()
        -> [Range<UInt64>]
    {
        defer { pendingEncodedAuthoritativeIdentityRange = nil }
        return pendingEncodedAuthoritativeIdentityRange.map { [$0] } ?? []
    }

    package func setForceOffMainStrokeCommandFailureForTesting(
        _ force: Bool
    ) {
        precondition(isIdle)
        forceOffMainStrokeCommandFailureForTesting = force
    }

    package func offMainStageCContinuationMetricsForAllocationHarness()
        async -> StrokeStageCContinuationMetrics
    {
        await (strokePreparationBridge ?? warmedStrokePreparationBridge)
            .stageCContinuationMetricsForAllocationHarness()
    }

    #if DEBUG
    func setStrokePreparationResultOwnershipProbeForTesting(
        _ probe: StrokePreparationResultOwnershipProbe?
    ) {
        precondition(isIdle)
        warmedStrokePreparationBridge
            .setResultOwnershipProbeForTesting(probe)
    }

    var offMainStrokeWorkspaceIsAvailableForTesting: Bool {
        strokeWorkspaceState == .available
    }

    var offMainTerminalCancellationPublicationCountForTesting: UInt64 {
        warmedStrokePreparationBridge.mailbox.snapshot
            .terminalCancellationPublicationCount
    }

    var offMainPreparationWorkerTaskPriorityForTesting: TaskPriority? {
        warmedStrokePreparationBridge.mailbox.snapshot.workerTaskPriority
    }

    var offMainPreparationWorkerDriverForTesting: AnyObject? {
        strokePreparationBridge?.workerDriverForTesting
    }

    var offMainPreparationWorkerTaskForTesting: Task<Void, Never>? {
        strokePreparationBridge?.workerTaskForTesting
    }

    var offMainPreparationMailboxForTesting: StrokePreparationMailbox? {
        strokePreparationBridge?.mailbox
    }

    var offMainPreparationMailboxSnapshotForTesting:
        StrokePreparationMailboxSnapshot?
    {
        strokePreparationBridge?.mailbox.snapshot
    }

    #if DEBUG
    func offMainSchedulerSnapshotForTesting() async
        -> StrokeFrameSchedulerSnapshot
    {
        await (strokePreparationBridge ?? warmedStrokePreparationBridge)
            .schedulerSnapshotForTesting()
    }

    func offMainTransientSnapshotForTesting() async
        -> StrokeTransientPreparationSnapshot
    {
        await (strokePreparationBridge ?? warmedStrokePreparationBridge)
            .transientSnapshotForTesting()
    }
    #endif

    var offMainSurfaceSnapshotForTesting:
        StrokePrivateSurfaceEncoderSnapshot?
    {
        lastOffMainSurfaceSnapshot
    }

    var offMainZeroWorkLeaseCountForTesting: Int {
        lastOffMainZeroWorkLeaseCount
    }

    var offMainPredictedInstanceCountForTesting: Int {
        lastOffMainPredictedInstanceCount
    }

    var predictionSubmissionScratchSnapshotForTesting:
        PredictionSubmissionScratchSnapshot
    {
        PredictionSubmissionScratchSnapshot(
            count: predictionSubmissionScratch.count,
            highWater: predictionSubmissionScratchHighWater,
            storageCapacity: predictionSubmissionScratch.capacity,
            storageIdentity: predictionSubmissionScratchStorageIdentity,
            storageReallocationCount:
                predictionSubmissionScratchStorageReallocationCount,
            lastSubmittedSampleCount:
                predictionSubmissionLastSubmittedSampleCount,
            lastAcceptedSampleCount:
                predictionSubmissionLastAcceptedSampleCount,
            lastShedSampleCount:
                predictionSubmissionLastShedSampleCount,
            lastValidatedSampleCount:
                predictionSubmissionLastValidatedSampleCount,
            lastTelemetrySampleCount:
                predictionSubmissionLastTelemetrySampleCount
        )
    }

    #endif

    package func runOffMainProductionTraceForTesting(
        compiledBrush: CompiledBrush,
        totalSampleCount: Int = 36_000,
        batchSize: Int = 60,
        inactivityTimeoutNanoseconds: UInt64 = 30_000_000_000,
        allocationProbe: StrokePreparationAllocationProbe? = nil,
        batchWillSubmit: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> OffMainStrokeProductionTraceSnapshot {
        precondition(isIdle)
        precondition(totalSampleCount >= 2)
        precondition(batchSize > 0)
        precondition(inactivityTimeoutNanoseconds > 0)
        let targetFrameNanoseconds = UInt64(1_000_000_000 / 60)
        let firstDecileEnd = totalSampleCount / 10
        let lastDecileStart = totalSampleCount - firstDecileEnd
        let brushRenderState = compiledBrush.renderState
        let bridge = warmedStrokePreparationBridge
        let progressRegistration = StrokePreparationProgressRegistration(
            mailbox: bridge.mailbox
        )
        defer { progressRegistration.remove() }
        let initialMailbox = bridge.mailbox.snapshot
        let capability = try paintContext.beginStrokeSurface()
        let generation = capability.generation
        let tileSurfaces = try StrokeTileSurfaceResources(
            device: device,
            commandQueue: commandQueue,
            capability: capability,
            maximumRecordCount: max(
                depositionFrameBudget.maximumAuthoritativeInstances,
                depositionFrameBudget.maximumPredictedInstances
            ),
            maximumTileReferenceCount:
                GridCanvasContract.maximumStrokeTileReferenceCount
        )
        activeStrokeTileSurfaceResources = tileSurfaces
        let initialWorkspaceIdentity = tileSurfaces.identity
        let initialWorkspaceInstallationCount: UInt64 = 1
        let configuration = StrokePreparationConfiguration(
            program: compiledBrush.program,
            nominalDiameter: 12,
            color: .black,
            seed: 7,
            viewport: viewport,
            tilingStrategy: tilingStrategy,
            metalResourceDescriptor: StrokeMetalResourceDescriptor(
                surfaces: tileSurfaces,
                brush: brushRenderState,
                frameUniforms: frameUniforms(
                    drawableSize: tileSize,
                    showGridLines: false,
                    liveVisible: true
                ),
                radialLayout:
                    tilingStrategy.compiledSymmetry.domain.finite?.radial.layout,
                forceCommandFailure: false
            ),
            allocationProbe: allocationProbe
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: storagePixelSize.width,
            height: storagePixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let compositeTarget = device.makeTexture(
            descriptor: descriptor
        ) else {
            throw MetalRendererError.textureAllocationFailed
        }
        compositeTarget.label = "Off-main Production Trace Composite"

        var firstDecileNanoseconds: UInt64 = 0
        var firstDecileEventCount = 0
        var lastDecileNanoseconds: UInt64 = 0
        var lastDecileEventCount = 0
        var missedLogicalFrameCount = 0
        var deferredDrainCount = 0
        var zeroWorkLeaseCount = 0
        var latestCoordinatorSnapshot: StrokeRenderSnapshot?
        var latestSurfaceSnapshot: StrokePrivateSurfaceEncoderSnapshot?
        var allOffMain = true
        let wallStarted = DispatchTime.now().uptimeNanoseconds

        var batchStart = 0
        while batchStart < totalSampleCount {
            let batchEnd = min(batchStart + batchSize, totalSampleCount)
            var samples: [StrokeSample] = []
            samples.reserveCapacity(batchEnd - batchStart)
            for index in batchStart..<batchEnd {
                let phase: StrokePhase
                if index == 0 {
                    phase = .began
                } else if index == totalSampleCount - 1 {
                    phase = .ended
                } else {
                    phase = .moved
                }
                samples.append(
                    .mouse(
                        position: ScreenPoint(
                            x: 32 + cos(Float(index) * 0.013) * 20,
                            y: 32 + sin(Float(index) * 0.013) * 20
                        ),
                        timestamp: TimeInterval(index) / 60,
                        phase: phase
                    )
                )
            }
            let message: StrokeInputMessage
            if batchStart == 0 {
                message = .begin(
                    generation: generation,
                    configuration: configuration,
                    samples: samples
                )
            } else if batchEnd == totalSampleCount {
                message = .finish(
                    generation: generation,
                    samples: samples
                )
            } else {
                message = .appendAuthoritative(
                    generation: generation,
                    samples: samples
                )
            }
            batchWillSubmit?(batchStart, batchEnd)
            try bridge.submit(message)
            let drained: OffMainStrokeTraceDrainOutcome
            do {
                drained = try await drainOffMainTraceMessage(
                    bridge: bridge,
                    generation: generation,
                    expectedInputSampleCount: UInt64(batchEnd),
                    requireCommitBarrier: false,
                    compositeTarget: compositeTarget,
                    progressRegistration: progressRegistration,
                    inactivityTimeoutNanoseconds:
                        inactivityTimeoutNanoseconds
                )
            } catch {
                throw MetalRendererError.commandFailed(
                    "off-main production trace batch "
                        + "\(batchStart)..<\(batchEnd) failed: \(error)"
                )
            }
            let batchPreparationCPU = drained.preparationCPUNanoseconds
            let eventCount = batchEnd - batchStart
            if batchEnd <= firstDecileEnd {
                firstDecileNanoseconds += batchPreparationCPU
                firstDecileEventCount += eventCount
            }
            if batchStart >= lastDecileStart {
                lastDecileNanoseconds += batchPreparationCPU
                lastDecileEventCount += eventCount
            }
            let logicalBudget = targetFrameNanoseconds * UInt64(eventCount)
            if batchPreparationCPU > logicalBudget {
                missedLogicalFrameCount += Int(
                    (batchPreparationCPU - logicalBudget)
                        / targetFrameNanoseconds
                ) + 1
            }
            deferredDrainCount += drained.deferredDrainCount
            zeroWorkLeaseCount += drained.zeroWorkLeaseCount
            latestCoordinatorSnapshot = drained.coordinatorSnapshot
            latestSurfaceSnapshot = drained.surfaceSnapshot
            allOffMain = allOffMain
                && drained.allPreparationAndEncodingOffMain
            batchStart = batchEnd
        }

        try bridge.submit(.commit(generation: generation))
        let committed = try await drainOffMainTraceMessage(
            bridge: bridge,
            generation: generation,
            expectedInputSampleCount: UInt64(totalSampleCount),
            requireCommitBarrier: true,
            compositeTarget: compositeTarget,
            progressRegistration: progressRegistration,
            inactivityTimeoutNanoseconds: inactivityTimeoutNanoseconds
        )
        if committed.preparationCPUNanoseconds > targetFrameNanoseconds {
            missedLogicalFrameCount += Int(
                (committed.preparationCPUNanoseconds
                    - targetFrameNanoseconds)
                    / targetFrameNanoseconds
            ) + 1
        }
        deferredDrainCount += committed.deferredDrainCount
        zeroWorkLeaseCount += committed.zeroWorkLeaseCount
        latestCoordinatorSnapshot = committed.coordinatorSnapshot
        latestSurfaceSnapshot = committed.surfaceSnapshot
        allOffMain = allOffMain
            && committed.allPreparationAndEncodingOffMain
        let wallDuration = DispatchTime.now().uptimeNanoseconds
            - wallStarted
        let mailbox = bridge.mailbox.snapshot
        guard let coordinator = latestCoordinatorSnapshot else {
            throw MetalRendererError.commandFailed(
                "production trace did not publish a coordinator snapshot"
            )
        }
        guard let surface = latestSurfaceSnapshot else {
            throw MetalRendererError.commandFailed(
                "production trace did not publish a surface snapshot"
            )
        }
        precondition(coordinator.commitMetadata.inputSampleCount
            == UInt64(totalSampleCount))
        let trace = OffMainStrokeProductionTraceSnapshot(
            inputSampleCount: totalSampleCount,
            logicalDurationNanoseconds:
                UInt64(totalSampleCount) * targetFrameNanoseconds,
            wallDurationNanoseconds: wallDuration,
            firstDecileNanosecondsPerEvent:
                firstDecileNanoseconds
                    / UInt64(max(1, firstDecileEventCount)),
            lastDecileNanosecondsPerEvent:
                lastDecileNanoseconds
                    / UInt64(max(1, lastDecileEventCount)),
            authoritativeInputHighWater:
                mailbox.input.authoritativeHighWater,
            authoritativeInputCapacity:
                mailbox.input.authoritativeCapacity,
            authoritativeInputInitialStorageCapacity:
                initialMailbox.input.authoritativeStorageCapacity,
            authoritativeInputStorageCapacity:
                mailbox.input.authoritativeStorageCapacity,
            predictionInputCapacity:
                mailbox.input.predictionCapacity,
            predictionInputInitialStorageCapacity:
                initialMailbox.input.predictionStorageCapacity,
            predictionInputStorageCapacity:
                mailbox.input.predictionStorageCapacity,
            resultHighWater: mailbox.resultHighWater,
            resultCapacity: mailbox.resultCapacity,
            resultInitialStorageCapacity:
                initialMailbox.resultStorageCapacity,
            resultStorageCapacity: mailbox.resultStorageCapacity,
            workspaceInitialInstallationCount:
                initialWorkspaceInstallationCount,
            workspaceInstallationCount:
                1,
            workspaceIdentityStayedStable:
                tileSurfaces.identity == initialWorkspaceIdentity,
            maximumPreparedPayloadBytes:
                mailbox.maximumPreparedPayloadBytes,
            surface: surface,
            missedLogicalFrameCount: missedLogicalFrameCount,
            deferredDrainCount: deferredDrainCount,
            zeroWorkLeaseCount: zeroWorkLeaseCount,
            allPreparationAndEncodingOffMain: allOffMain
        )
        try await resetOffMainTraceBridge(
            bridge,
            generation: generation,
            progressRegistration: progressRegistration,
            inactivityTimeoutNanoseconds: inactivityTimeoutNanoseconds
        )
        return trace
    }

    private func resetOffMainTraceBridge(
        _ bridge: StrokePreparationBridge,
        generation: UInt64,
        progressRegistration: StrokePreparationProgressRegistration,
        inactivityTimeoutNanoseconds: UInt64
    ) async throws {
        try bridge.submit(.cancel(generation: generation, reason: nil))
        var resultScratch: [StrokePreparationResult] = []
        resultScratch.reserveCapacity(1)
        var watchdog = OffMainStrokeTraceInactivityWatchdog(
            timeoutNanoseconds: inactivityTimeoutNanoseconds
        )
        while !watchdog.hasExpired {
            let observedRevision = progressRegistration.currentRevision
            bridge.drainResults(into: &resultScratch)
            if !resultScratch.isEmpty {
                watchdog.recordProgress()
            }
            var deferredDisplayAcknowledgement:
                StrokePreparedFrameAcknowledgement?
            var deferredSyntheticAcknowledgement:
                (generation: UInt64, token: UInt64)?
            for result in resultScratch {
                switch result {
                case let .cancelled(cancelledGeneration, _)
                    where cancelledGeneration == generation:
                    return
                case let .prepared(batch):
                    if batch.surfaceLease != nil {
                        guard let displayFrame = batch.displayFrame else {
                            throw MetalRendererError.invalidStrokeLifecycle
                        }
                        deferredDisplayAcknowledgement =
                            displayFrame.acknowledgement
                    } else if let token = batch.frameToken {
                        deferredSyntheticAcknowledgement = (
                            batch.generation,
                            token
                        )
                    }
                case let .failed(_, failure):
                    throw rendererError(for: failure)
                default:
                    break
                }
            }
            resultScratch.removeAll(keepingCapacity: true)
            if let deferredDisplayAcknowledgement {
                try await deferredDisplayAcknowledgement.fulfill()
                watchdog.recordProgress()
            }
            if let deferredSyntheticAcknowledgement {
                try bridge.acknowledgePreparedFrame(
                    generation: deferredSyntheticAcknowledgement.generation,
                    token: deferredSyntheticAcknowledgement.token
                )
                watchdog.recordProgress()
            }
            if progressRegistration.currentRevision != observedRevision {
                watchdog.recordProgress()
                continue
            }
            if progressRegistration.waitForProgress(
                after: observedRevision,
                until: watchdog.waitDeadline
            ) {
                watchdog.recordProgress()
            }
        }
        throw MetalRendererError.commandFailed(
            "off-main trace workspace retirement exceeded its bound"
        )
    }

    private func drainOffMainTraceMessage(
        bridge: StrokePreparationBridge,
        generation: UInt64,
        expectedInputSampleCount: UInt64,
        requireCommitBarrier: Bool,
        compositeTarget: any MTLTexture,
        progressRegistration: StrokePreparationProgressRegistration,
        inactivityTimeoutNanoseconds: UInt64
    ) async throws -> OffMainStrokeTraceDrainOutcome {
        var resultScratch: [StrokePreparationResult] = []
        resultScratch.reserveCapacity(1)
        var coordinatorSnapshot: StrokeRenderSnapshot?
        var surfaceSnapshot: StrokePrivateSurfaceEncoderSnapshot?
        var deferredDrainCount = 0
        var zeroWorkLeaseCount = 0
        var commitBarrierReached = false
        var allOffMain = true
        var preparationCPUNanoseconds: UInt64 = 0

        var watchdog = OffMainStrokeTraceInactivityWatchdog(
            timeoutNanoseconds: inactivityTimeoutNanoseconds
        )
        while !watchdog.hasExpired {
            let observedRevision = progressRegistration.currentRevision
            bridge.drainResults(into: &resultScratch)
            if resultScratch.isEmpty {
                deferredDrainCount += 1
            } else {
                watchdog.recordProgress()
            }
            var deferredDisplayAcknowledgement:
                StrokePreparedFrameAcknowledgement?
            var deferredSyntheticAcknowledgement:
                (generation: UInt64, token: UInt64)?
            for result in resultScratch {
                switch result {
                case let .prepared(batch):
                    preparationCPUNanoseconds = Self.saturatingAdd(
                        preparationCPUNanoseconds,
                        batch.preparationCPUNanoseconds
                    )
                    coordinatorSnapshot = batch.coordinatorSnapshot
                    surfaceSnapshot = batch.surfaceSnapshot
                    allOffMain = allOffMain
                        && !batch.executorProbe.generatorRanOnMainThread
                        && !batch.executorProbe.projectionRanOnMainThread
                    if let lease = batch.surfaceLease {
                        allOffMain = allOffMain
                            && !lease.encodingRanOnMainThread
                        if lease.authoritativeInstanceCount
                            + lease.predictedInstanceCount == 0
                        {
                            zeroWorkLeaseCount += 1
                        }
                        guard let displayFrame = batch.displayFrame else {
                            throw MetalRendererError.invalidStrokeLifecycle
                        }
                        deferredDisplayAcknowledgement =
                            displayFrame.acknowledgement
                    } else if let token = batch.frameToken {
                        zeroWorkLeaseCount += 1
                        deferredSyntheticAcknowledgement = (
                            batch.generation,
                            token
                        )
                    }
                case .predictionWasShed:
                    break
                case .estimatedUpdateWasIgnored:
                    break
                case let .estimatedUpdateWasRejected(
                    _,
                    error,
                    capacityFailure
                ):
                    if let capacityFailure {
                        throw rendererError(for: capacityFailure)
                    }
                    throw error
                case .commitBarrierReached:
                    commitBarrierReached = true
                case .cancelled:
                    throw MetalRendererError.invalidStrokeLifecycle
                case let .failed(_, failure):
                    throw rendererError(for: failure)
                }
            }
            resultScratch.removeAll(keepingCapacity: true)
            if let deferredDisplayAcknowledgement {
                try await deferredDisplayAcknowledgement.fulfill()
                watchdog.recordProgress()
            }
            if let deferredSyntheticAcknowledgement {
                try bridge.acknowledgePreparedFrame(
                    generation: deferredSyntheticAcknowledgement.generation,
                    token: deferredSyntheticAcknowledgement.token
                )
                watchdog.recordProgress()
            }
            let mailbox = bridge.mailbox.snapshot
            // Replay-tail brushes legitimately retain consumed
            // input without advancing committed metadata until promotion or
            // finish. Mailbox quiescence proves an intermediate message was
            // consumed; the final commit barrier below requires the exact
            // total committed sample count.
            let inputReached = !requireCommitBarrier
                || coordinatorSnapshot?.commitMetadata.inputSampleCount
                    == expectedInputSampleCount
            if inputReached,
               mailbox.isQuiescent,
               (!requireCommitBarrier || commitBarrierReached),
               let coordinatorSnapshot,
               let surfaceSnapshot
            {
                return OffMainStrokeTraceDrainOutcome(
                    coordinatorSnapshot: coordinatorSnapshot,
                    surfaceSnapshot: surfaceSnapshot,
                    deferredDrainCount: deferredDrainCount,
                    zeroWorkLeaseCount: zeroWorkLeaseCount,
                    commitBarrierReached: commitBarrierReached,
                    allPreparationAndEncodingOffMain: allOffMain,
                    preparationCPUNanoseconds:
                        preparationCPUNanoseconds
                )
            }
            if progressRegistration.currentRevision != observedRevision {
                watchdog.recordProgress()
                continue
            }
            if progressRegistration.waitForProgress(
                after: observedRevision,
                until: watchdog.waitDeadline
            ) {
                watchdog.recordProgress()
            }
        }
        let stalled = bridge.mailbox.snapshot
        throw MetalRendererError.commandFailed(
            "off-main production trace drain exceeded its inactivity bound "
                + "at input sample \(expectedInputSampleCount); input="
                + "\(stalled.input.authoritativePendingSampleCount)/"
                + "\(stalled.input.predictedPendingSampleCount) result="
                + "\(stalled.pendingResultCount) awaiting="
                + "\(stalled.awaitingPreparedFrameSubmission) worker="
                + "\(stalled.workerIsProcessing) coordinatorInput="
                + "\(String(describing: coordinatorSnapshot?.commitMetadata.inputSampleCount)) "
                + "surface=\(surfaceSnapshot != nil) barrier="
                + "\(commitBarrierReached)/\(requireCommitBarrier)"
        )
    }

    #if DEBUG
    var brushLabInputReceiptPendingForTesting: Bool {
        brushLabPendingInputReceiptNanoseconds != nil
    }

    var rendererEventDiagnosticsForTesting:
        RendererEventDispatcher.Diagnostics
    {
        rendererEventDispatcher.diagnostics
    }

    #endif

    @discardableResult
    private func beginRendererEventOperationIfNeeded() -> Bool {
        rendererEventDispatcher.beginOperation()
        return true
    }

    private func endRendererEventOperationIfNeeded(
        _ ownsOperation: Bool,
        succeeded: Bool
    ) {
        guard ownsOperation else { return }
        rendererEventDispatcher.endOperation(succeeded: succeeded)
    }

    private func stageRendererEvent(_ event: RendererEvent) {
        if rendererEventDispatcher.hasOpenOperation {
            rendererEventDispatcher.stage(event)
            return
        }
        rendererEventDispatcher.beginOperation()
        rendererEventDispatcher.stage(event)
        rendererEventDispatcher.endOperation(succeeded: true)
    }

    private func deliverRendererEvent(_ event: RendererEvent) {
        switch event {
        case let .error(error):
            onError?(error)
        case let .idleStateChanged(isIdle):
            onIdleStateChange?(isIdle)
        case let .operationCompleted(completion):
            onOperationCompleted?(completion)
        case let .logicalDab(_, dab):
            onLogicalDabsGenerated?(dab)
        case let .strokeRuntimeSnapshot(_, snapshot):
            onStrokeRuntimeSnapshot?(snapshot)
        case let .strokeRuntimeSegmentMarker(_, marker):
            onStrokeRuntimeSegmentMarker?(marker)
        #if DEBUG
        case let .interactiveFramePresented(timestamp, count):
            onInteractiveFramePresented?(timestamp, count)
        case let .interactiveFrameMetrics(metrics):
            onInteractiveFrameMetrics?(metrics)
        #endif
        }
    }

    private func commitRendererEventCheckpoint() {
        rendererEventDispatcher.commitCheckpoint()
    }

    private func invalidateStrokeEventGeneration() {
        guard let generation = strokeEventGeneration else { return }
        rendererEventDispatcher.invalidateStrokeGeneration(generation)
        strokeEventGeneration = nil
    }

    private func invalidateTelemetryEventGeneration() {
        guard let generation = telemetryEventGeneration else { return }
        rendererEventDispatcher.invalidateTelemetryGeneration(generation)
        telemetryEventGeneration = nil
    }

    private func deferLogicalDabsForPublication<Dabs: Collection>(
        _ dabs: Dabs
    ) where Dabs.Element == LogicalDab {
        guard !dabs.isEmpty else { return }
        precondition(
            rendererEventDispatcher.hasOpenOperation,
            "Logical dabs must be recorded inside an input-operation scope"
        )
        guard let generation = strokeEventGeneration else {
            preconditionFailure(
                "Logical dabs require an active stroke event generation"
            )
        }
        for dab in dabs {
            if dab.isPredicted {
                brushLabPredictedDabCount += 1
            } else {
                brushLabActualDabCount += 1
            }
            rendererEventDispatcher.stage(
                .logicalDab(generation: generation, dab: dab)
            )
        }
    }

    func compiledIsometryOrdinal(
        for fragment: CellFragment
    ) throws -> UInt8 {
        guard let isometry = tilingStrategy.compiledSymmetry.images.first(
            where: {
                $0.ordinal == fragment.imageOrdinal
                    && $0.operation == fragment.operation
            }
        ) else {
            throw MetalRendererError.invalidSymmetryConfiguration(
                "Projected fragment has no compiled isometry."
            )
        }
        return isometry.ordinal
    }

    private func color(for style: StrokeRenderStyle) -> InkColor {
        switch style.compositeMode {
        case .draw:
            Self.opaqueStrokeColor(style.color)
        case .erase:
            InkColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 1
            )!
        }
    }

    private nonisolated static func opaqueStrokeColor(
        _ color: InkColor
    ) -> InkColor {
        InkColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 1
        )!
    }

    func frameUniforms(
        drawableSize: PatternSize,
        showGridLines: Bool,
        liveVisible: Bool,
        diagnosticMode: UInt32 = PatternDiagnosticWireNone
    ) -> PatternGridFrameUniforms {
        let compositeMode = activeStroke?.style.compositeMode.rawValue
            ?? PatternCompositeWireDraw
        let worldToLattice: Affine2D
        let displayRepeatSize: SIMD2<Float>
        if let periodic = tilingStrategy.compiledSymmetry.domain.periodic {
            worldToLattice = periodic.worldToLattice
            displayRepeatSize =
                tilingStrategy.compiledSymmetry.family == .triangular
                ? SIMD2(
                    simd_length(periodic.translationBasis.u),
                    simd_length(periodic.translationBasis.v)
                )
                : periodic.configuration.repeatSize.simd
        } else {
            worldToLattice = .identity
            displayRepeatSize = SIMD2(
                Float(pixelSize.width),
                Float(pixelSize.height)
            )
        }
        return PatternGridFrameUniforms(
            drawableSize: drawableSize.simd,
            worldCenter: viewport.worldCenter.simd,
            tileSize: tileSize.simd,
            zoom: viewport.zoom,
            gridLineWidth: 1,
            showGridLines: showGridLines ? 1 : 0,
            liveVisible: liveVisible ? 1 : 0,
            tilingKind:
                tilingStrategy.compiledSymmetry.displayProgram.presetWireID,
            diagnosticMode: diagnosticMode,
            compositeMode: compositeMode,
            symmetryFamily:
                tilingStrategy.compiledSymmetry.displayProgram.family.rawValue,
            repeatSize: displayRepeatSize,
            latticeXAxis: worldToLattice.xAxis,
            latticeYAxis: worldToLattice.yAxis,
            latticeTranslation: worldToLattice.translation,
            guideKind:
                tilingStrategy.compiledSymmetry.displayProgram.guideKind
                    .rawValue,
            showCanvasBoundary: 0
        )
    }

    func radialFrameUniforms() -> PatternRadialFrameUniforms {
        radialFrameUniforms(
            strategy: tilingStrategy,
            storagePixelSize: storagePixelSize
        )
    }

    private func radialFrameUniforms(
        strategy: TilingStrategy,
        storagePixelSize: PixelSize
    ) -> PatternRadialFrameUniforms {
        guard let radial = strategy.compiledSymmetry.domain.finite?
            .radial
        else {
            preconditionFailure(
                "Radial uniforms require a finite descriptor"
            )
        }
        let layout = radial.layout
        let configuration = radial.configuration
        let isDihedral = configuration.map {
            $0.kind != .rotation
        } ?? false
        return PatternRadialFrameUniforms(
            canvasSize: SIMD2(
                Float(radial.canvasSize.width),
                Float(radial.canvasSize.height)
            ),
            center: configuration?.center.simd ?? .zero,
            referenceAngle: configuration?.referenceAngleRadians ?? 0,
            sectorAngle: radial.sectorAngleRadians,
            displayedSectorCount: UInt32(radial.displayedSectorCount),
            dihedral: isDihedral ? 1 : 0,
            pageOrigin: SIMD2(
                Float(layout?.pageOrigin.x ?? 0),
                Float(layout?.pageOrigin.y ?? 0)
            ),
            pageTableSize: SIMD2(
                Float(layout?.pageTableSize.width ?? 1),
                Float(layout?.pageTableSize.height ?? 1)
            ),
            atlasColumns: UInt32(layout?.atlasColumns ?? 1),
            pageSide: UInt32(
                layout == nil
                    ? max(storagePixelSize.width, storagePixelSize.height)
                    : RadialSectorLayout.pageSide
            ),
            atlasSize: SIMD2(
                Float(storagePixelSize.width),
                Float(storagePixelSize.height)
            )
        )
    }

    private var compositeMaterialUniforms: PatternCompositeUniforms {
        PatternCompositeUniforms(
            parameters: SIMD4(
                activeStroke?.style.color.alpha ?? 1,
                1,
                activeStroke?.style.compositeMode == .erase
                    ? activeStroke?.style.eraserStrength ?? 1
                    : 1,
                0
            )
        )
    }

    func makeHarnessTexture(
        width: Int,
        height: Int
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }
        return texture
    }

    func makeHarnessDisplayValidationTexture()
        throws -> any MTLTexture
    {
        let texture = try makeHarnessTexture(
            width: storagePixelSize.width,
            height: storagePixelSize.height
        )
        let bytesPerRow = storagePixelSize.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count: bytesPerRow * storagePixelSize.height
        )
        for y in 0..<storagePixelSize.height {
            for x in 0..<storagePixelSize.width {
                let offset = y * bytesPerRow + x * 4
                bytes[offset] = UInt8(
                    truncatingIfNeeded: x &* 37 &+ y &* 17
                )
                bytes[offset + 1] = UInt8(truncatingIfNeeded: y)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: x)
                bytes[offset + 3] = 255
            }
        }
        bytes.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(
                    0,
                    0,
                    storagePixelSize.width,
                    storagePixelSize.height
                ),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    private func resizedStrategy(
        canvasPixelSize: PixelSize
    ) throws -> TilingStrategy {
        do {
            switch tilingStrategy.documentConfiguration {
            case let .periodic(configuration):
                return try TilingStrategy(
                    configuration: configuration,
                    canonicalRasterSize: canvasPixelSize
                )
            case let .finite(configuration):
                return try TilingStrategy(
                    finiteConfiguration: configuration,
                    canvasSize: canvasPixelSize
                )
            }
        } catch {
            throw MetalRendererError.invalidSymmetryConfiguration(
                error.localizedDescription
            )
        }
    }

    private func storageSize(
        for strategy: TilingStrategy
    ) -> PixelSize {
        PixelSize(
            width: Int(strategy.tileSize.width),
            height: Int(strategy.tileSize.height)
        )
    }

    private func validateTileSize(_ size: PixelSize) throws {
        let validDimensions = 64...4_096
        guard
            validDimensions.contains(size.width),
            validDimensions.contains(size.height)
        else {
            throw MetalRendererError.invalidTileDimensions(
                width: size.width,
                height: size.height
            )
        }
    }

    private func setDocumentGeometryLocked(_ locked: Bool) {
        documentDomainLocked = locked
        radialGeometryLocked =
            locked
            && tilingStrategy.compiledSymmetry.domain.finite?
                .radial.layout != nil
    }

    private func resetLiveState(
        invalidateStrokeEvents: Bool = true
    ) {
        let isRetiringStrokeWorkspace = retireStrokeWorkspaceIfNeeded()
        if !isRetiringStrokeWorkspace {
            strokePreparationBridge = nil
            strokePreparationGeneration = nil
        }
        strokePreparationResultScratch.removeAll(keepingCapacity: true)
        if invalidateStrokeEvents {
            invalidateStrokeEventGeneration()
        }
    }

    private func retireStrokeWorkspaceIfNeeded() -> Bool {
        guard let bridge = strokePreparationBridge,
              let generation = strokePreparationGeneration
        else {
            strokeWorkspaceState = .available
            strokeWorkspaceRetirementErrorWasReported = false
            return false
        }
        switch strokeWorkspaceState {
        case .available:
            return false
        case .retiring:
            return true
        case let .borrowed(borrowedGeneration):
            precondition(borrowedGeneration == generation)
            let cancellationFrameDisposition:
                StrokePreparationCancellationFrameDisposition =
                    interactiveStrokeCacheAdoptionTask == nil
                        ? .abandonedBeforeSubmission
                        : .preserveMainOwnership
            beginInteractiveStrokeCacheRetirement(
                strokeEpoch: activeStrokeTileSurfaceResources?
                    .capability.presentationEpoch
            )
            bridge.submitCancellation(
                generation: generation,
                reason: nil,
                frameDisposition: cancellationFrameDisposition
            )
            strokeWorkspaceState = .retiring(generation)
            return true
        }
    }

    private func finishStrokeWorkspaceRetirement(
        generation: UInt64
    ) {
        guard strokeWorkspaceState == .retiring(generation) else {
            return
        }
        let wasIdle = isIdle
        strokePreparationBridge = nil
        strokePreparationGeneration = nil
        activeStrokeTileSurfaceResources = nil
        strokeWorkspaceState = .available
        strokeWorkspaceRetirementErrorWasReported = false
        notifyIdleStateIfChanged(from: wasIdle)
    }

    private func beginInteractiveStrokeCacheRetirement(
        strokeEpoch: DocumentPaintStrokePresentationEpoch?
    ) {
        guard let strokeEpoch else { return }
        let identity = strokeEpoch.identity
        let completionMailbox = strokePreparationBridge?.mailbox
        interactiveStrokeCacheLifecycleEpochs.insert(identity)
        interactiveStrokeCacheLifecycleEpochObjects[identity] = strokeEpoch
        lastInteractiveStrokeCacheLifecycleIdentity = identity
        InteractiveStrokeCacheLifecycleCoordinator.shared
            .requestCancellation(
                cache: interactiveStrokePresentationCache,
                strokeEpoch: strokeEpoch,
                lifecycleTerminal: { [weak self] _ in
                    guard let self else { return }
                    let wasIdle = self.isIdle
                    self.interactiveStrokeCacheLifecycleEpochs.remove(identity)
                    self.interactiveStrokeCacheLifecycleEpochObjects
                        .removeValue(forKey: identity)
                    self.notifyIdleStateIfChanged(from: wasIdle)
                    completionMailbox?.recordExternalProgress()
                },
                failureTerminal: { [weak self] error in
                    self?.report(.commandFailed(
                        "interactive stroke cache retirement failed: \(error)"
                    ))
                }
            )
    }

    func installInteractiveStrokeCacheFailureInjectionForTesting(
        _ failureInjection:
            InteractiveStrokePresentationCacheFailureInjection?
    ) async {
        await interactiveStrokePresentationCache
            .installFailureInjectionForTesting(failureInjection)
    }

    #if DEBUG
    func installInteractiveStrokeCacheCompletionGateForTesting(
        _ gate: (any InteractiveStrokePresentationCacheCompletionGating)?
    ) async {
        await interactiveStrokePresentationCache
            .installCompletionGateForTesting(gate)
    }
    #endif

    func awaitInteractiveStrokeCacheRetirementForHarness() async {
        guard let identity = lastInteractiveStrokeCacheLifecycleIdentity else {
            return
        }
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForLifecycle(identity)
    }

    func retryInteractiveStrokeCacheRetirementForHarness() async {
        await awaitInteractiveStrokeCacheRetirementForHarness()
    }

    func interactiveStrokeCacheSnapshotForTesting() async
        -> InteractiveStrokePresentationCacheSnapshot
    {
        await interactiveStrokePresentationCache.snapshot()
    }

    func interactiveStrokePresentationCacheForTesting()
        -> InteractiveStrokePresentationCache
    {
        interactiveStrokePresentationCache
    }

    func interactiveStrokeCacheLifecycleIdentityForTesting() -> UUID? {
        lastInteractiveStrokeCacheLifecycleIdentity
    }

    func installFailedInteractiveStrokeCacheUpdateForTesting(
        _ update: DocumentPaintTransientCacheUpdate,
        parameters: InteractiveStrokeCompositeParameters,
        lifecycleTerminal: @escaping @MainActor @Sendable (
            InteractiveStrokePresentationCacheSnapshot
        ) -> Void = { _ in }
    ) async {
        await startInteractiveStrokeCacheUpdateForTesting(
            update,
            parameters: parameters,
            lifecycleTerminal: lifecycleTerminal
        ).value
    }

    @discardableResult
    func startInteractiveStrokeCacheUpdateForTesting(
        _ update: DocumentPaintTransientCacheUpdate,
        parameters: InteractiveStrokeCompositeParameters,
        lifecycleTerminal: @escaping @MainActor @Sendable (
            InteractiveStrokePresentationCacheSnapshot
        ) -> Void = { _ in }
    ) -> Task<Void, Never> {
        let identity = update.presentationEpoch.identity
        interactiveStrokeCacheLifecycleEpochs.insert(identity)
        interactiveStrokeCacheLifecycleEpochObjects[identity] =
            update.presentationEpoch
        lastInteractiveStrokeCacheLifecycleIdentity = identity
        return InteractiveStrokeCacheAdoptionOperation.start(
            cache: interactiveStrokePresentationCache,
            update: update,
            parameters: parameters,
            terminal: { _ in true },
            lifecycleTerminal: { [weak self] snapshot in
                self?.interactiveStrokeCacheLifecycleEpochs.remove(identity)
                self?.interactiveStrokeCacheLifecycleEpochObjects
                    .removeValue(forKey: identity)
                lifecycleTerminal(snapshot)
            }
        )
    }

    func awaitInteractiveStrokeCacheAcknowledgementRetryForHarness() async {
        guard let identity = lastInteractiveStrokeCacheLifecycleIdentity else {
            return
        }
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForAcknowledgement(identity)
    }

    package func drainStrokeWorkspaceRetirementForHarness() throws {
        guard case .retiring = strokeWorkspaceState else { return }
        guard let progressRegistration =
                installStrokePreparationProgressWaiterForHarness()
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        defer {
            removeStrokePreparationProgressWaiterForHarness(
                progressRegistration
            )
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while true {
            let observedRevision = progressRegistration.currentRevision
            try drainCompletedInteractiveOperations()
            if strokeWorkspaceState == .available { return }
            if progressRegistration.currentRevision != observedRevision {
                continue
            }
            guard progressRegistration.waitForProgress(
                after: observedRevision,
                until: deadline
            ) else {
                break
            }
        }
        throw MetalRendererError.commandFailed(
            "stroke workspace retirement exceeded its harness bound"
        )
    }

    func replaceAvailableStrokePreparationWorkspaceForHarness(
        budget: DepositionFrameBudget
    ) {
        guard strokeWorkspaceState == .available else { return }
        warmedStrokePreparationBridge = StrokePreparationBridge(
            budget: budget,
            targetFramesPerSecond: 120,
            traceRecorder: interactiveBrushTraceRecorder
        )
    }

    #if DEBUG
    func replaceAvailableStrokePreparationWorkspaceForTesting(
        budget: DepositionFrameBudget,
        cancellationCleanupFailures: [StrokeTileSurfaceError]
    ) {
        guard strokeWorkspaceState == .available else { return }
        warmedStrokePreparationBridge = StrokePreparationBridge(
            budget: budget,
            targetFramesPerSecond: 120,
            traceRecorder: interactiveBrushTraceRecorder,
            testingSchedulerAcknowledgementFailures: [],
            testingSchedulerCancellationCleanupFailures:
                cancellationCleanupFailures
        )
    }
    #endif

    func report(_ error: MetalRendererError) {
        lastError = error
        stageRendererEvent(.error(error))
    }

    private func notifyIdleStateIfChanged(from wasIdle: Bool) {
        guard wasIdle != isIdle else { return }
        stageRendererEvent(.idleStateChanged(isIdle))
    }

    @discardableResult
    private func terminateActiveOperation(
        token: RendererOperationToken,
        error: MetalRendererError
    ) -> Bool {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        guard activeStroke?.token == token else {
            report(error)
            return false
        }
        // Compete atomically with the transaction immediately before its
        // irreversible canonical publication. If publication already owns
        // the terminal result, the commit task must report that success.
        if let publicationState = paintCommitPublicationState,
           !publicationState.claimFailure()
        {
            return true
        }
        paintCommitTask?.cancel()
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        let runtimeEndEvents = endStrokeRuntimeIfPossible()
        activeStroke = nil
        resetLiveState()
        stageStrokeRuntimeEvents(runtimeEndEvents)
        report(error)
        stageRendererEvent(.operationCompleted(.failure(token, error)))
        return true
    }

    func failActiveOperationIfNeeded(_ error: MetalRendererError) {
        guard let execution = activeStroke else {
            report(error)
            return
        }
        terminateActiveOperation(token: execution.token, error: error)
    }

    func waitForHarnessCommand(
        _ commandBuffer: any MTLCommandBuffer
    ) throws {
        commandBuffer.waitUntilCompleted()
        try validateHarnessCommand(commandBuffer)
    }

    func validateCompletedCommand(
        _ commandBuffer: any MTLCommandBuffer
    ) throws {
        guard commandBuffer.status == .completed else {
            throw MetalRendererError.commandFailed(
                commandBuffer.error?.localizedDescription
                    ?? "unknown command-buffer error"
            )
        }
    }

    func validateHarnessCommand(
        _ commandBuffer: any MTLCommandBuffer
    ) throws {
        try validateCompletedCommand(commandBuffer)
    }

    private func resetBrushLabDepositionDiagnostics() {
        brushLabDepositionTelemetry.reset()
        brushLabAuthoritativeHighWater = 0
        brushLabPredictedHighWater = 0
        brushLabLastFrameEncodedDabCount = 0
        brushLabLastFrameEncodedInstanceCount = 0
        brushLabStrokeEncodedDabCount = 0
        brushLabPendingInputReceiptNanoseconds = nil
        inputPathStorageAudit.reset()
        scheduledAuthoritativeIdentityHighWater = 0
        encodedAuthoritativeIdentityHighWater = 0
        pendingEncodedAuthoritativeIdentityRange = nil
        lastOffMainEncodingRanOnMainThread = nil
        lastOffMainCoordinatorSnapshot = nil
        lastOffMainSurfaceSnapshot = nil
        lastOffMainReplayRetention = StrokePreparedReplayRetention(
            retainedDabCount: 0,
            visibleProjectedInstanceCount: 0
        )
        lastOffMainZeroWorkLeaseCount = 0
        lastOffMainPredictedInstanceCount = 0
    }

    func armInputPathStorageAuditAfterWarmup() {
        inputPathStorageAudit.armAfterWarmup()
    }

    private func recordScratchAllocationIfNeeded(
        capacityBefore: Int,
        capacityAfter: Int
    ) {
        guard capacityAfter > capacityBefore else { return }
        inputPathStorageAudit.recordCollectionStorageAllocation(
            capacity: capacityAfter
        )
    }

    private func markBrushLabInputReceipt() {
        if brushLabPendingInputReceiptNanoseconds == nil {
            brushLabPendingInputReceiptNanoseconds =
                DispatchTime.now().uptimeNanoseconds
        }
    }

    private func recordBrushLabScheduler(_ scheduler: FrameScheduler) {
        let snapshot = scheduler.diagnosticSnapshot
        brushLabAuthoritativeHighWater = max(
            brushLabAuthoritativeHighWater,
            snapshot.authoritativeHighWater
        )
        brushLabPredictedHighWater = max(
            brushLabPredictedHighWater,
            snapshot.predictedHighWater
        )
        brushLabDepositionTelemetry.recordBacklog(
            authoritative: snapshot.authoritativePending,
            predicted: snapshot.predictedPending
        )
        inputPathStorageAudit.recordRecordStorage(
            schedulerCapacity:
                snapshot.authoritativeStorageCapacity
                + snapshot.predictedStorageCapacity,
            replayCapacity: 0
        )
    }

    func takeBrushLabEventToSubmitNanoseconds(
        submittedAt nanoseconds: UInt64,
        consumeReceipt: Bool = true
    ) -> UInt64 {
        guard let receipt = brushLabPendingInputReceiptNanoseconds else {
            return 0
        }
        if consumeReceipt {
            brushLabPendingInputReceiptNanoseconds = nil
        }
        return nanoseconds >= receipt ? nanoseconds - receipt : 0
    }

    func recordBrushLabCompletedFrame(_ metrics: GPUFrameMetrics) {
        guard metrics.encodedInstanceCount > 0 else { return }
        brushLabDepositionTelemetry.recordTimings(
            eventToSubmitNanoseconds: metrics.eventToSubmitNanoseconds,
            cpuPreparationNanoseconds: UInt64(
                max(0, metrics.cpuEncodeMilliseconds) * 1_000_000
            ),
            gpuEncodingNanoseconds: UInt64(
                max(0, metrics.gpuMilliseconds) * 1_000_000
            ),
            gpuCompletionNanoseconds: metrics.gpuCompletionNanoseconds
        )
        let conservativeFrameIntervalNanoseconds: UInt64 = 16_666_667
        if metrics.eventToSubmitNanoseconds
            >= conservativeFrameIntervalNanoseconds
        {
            brushLabDepositionTelemetry.recordMissedFrames(
                metrics.eventToSubmitNanoseconds
                    / conservativeFrameIntervalNanoseconds
            )
        }
    }

    private func beginStrokeRuntime(
        _ sample: StrokeSample
    ) -> [RendererEvent] {
        guard let controller = strokeRuntimeController,
              let generation = telemetryEventGeneration
        else {
            return []
        }
        do {
            let marker = try controller.beginStroke(strokeID: UUID())
            recordStrokeRuntimeInput(sample)
            return [
                .strokeRuntimeSegmentMarker(
                    generation: generation,
                    marker: marker
                ),
                .strokeRuntimeSnapshot(
                    generation: generation,
                    snapshot: controller.snapshot
                ),
            ]
        } catch {
            invalidateTelemetryEventGeneration()
            strokeRuntimeController = nil
            pendingStrokeRuntimeFrameIDs.removeAll(keepingCapacity: true)
            return []
        }
    }

    private func stageStrokeRuntimeEvents(_ events: [RendererEvent]) {
        for event in events {
            stageRendererEvent(event)
        }
    }

    private func recordStrokeRuntimeInput(_ sample: StrokeSample) {
        guard let controller = strokeRuntimeController else { return }
        let provenance: StrokeRuntimeInputProvenance = switch sample.kind {
        case .actual: .actual
        case .coalesced: .coalesced
        case .predicted: .predicted
        case .estimatedUpdate: .estimatedUpdate
        }
        controller.recordInput(
            provenance,
            at: DispatchTime.now().uptimeNanoseconds
        )
    }

    private func beginStrokeRuntimeFrame(
        at prepareStarted: UInt64,
        targetFrameDurationNanoseconds: UInt64
    ) -> StrokeRuntimeFrameIdentity? {
        guard let controller = strokeRuntimeController,
              let generation = telemetryEventGeneration
        else {
            return nil
        }
        let id = nextStrokeRuntimeFrameID
        nextStrokeRuntimeFrameID &+= 1
        if nextStrokeRuntimeFrameID == 0 {
            nextStrokeRuntimeFrameID = 1
        }
        do {
            try controller.beginFrame(
                id: id,
                prepareStarted: prepareStarted,
                targetFrameDurationNanoseconds:
                    targetFrameDurationNanoseconds
            )
            let identity = StrokeRuntimeFrameIdentity(
                telemetryGeneration: generation,
                frameID: id
            )
            pendingStrokeRuntimeFrameIDs.insert(identity)
            return identity
        } catch {
            return nil
        }
    }

    #if DEBUG
    func beginStrokeRuntimeFrameForTesting()
        -> StrokeRuntimeFrameIdentity?
    {
        beginStrokeRuntimeFrame(
            at: 1,
            targetFrameDurationNanoseconds: 16_666_667
        )
    }

    func prepareStrokeRuntimeFrameForTesting(
        _ identity: StrokeRuntimeFrameIdentity
    ) {
        recordStrokeRuntimePreparedFrame(id: identity)
    }

    func submitStrokeRuntimeFrameForTesting(
        _ identity: StrokeRuntimeFrameIdentity
    ) {
        recordStrokeRuntimeSubmittedFrame(id: identity, at: 3)
    }

    func completeStrokeRuntimeGPUFrameForTesting(
        _ identity: StrokeRuntimeFrameIdentity
    ) {
        recordStrokeRuntimeGPUFrame(
            id: identity,
            measuredStart: 4,
            measuredFinish: 5,
            submittedAt: 3
        )
    }

    func presentStrokeRuntimeFrameForTesting(
        _ identity: StrokeRuntimeFrameIdentity
    ) {
        recordStrokeRuntimePresentedFrame(id: identity, at: 6)
    }

    var pendingStrokeRuntimeFrameCountForTesting: Int {
        pendingStrokeRuntimeFrameIDs.count
    }
    #endif

    private func recordStrokeRuntimePreparedFrame(
        id: StrokeRuntimeFrameIdentity?
    ) {
        guard let id,
              id.telemetryGeneration == telemetryEventGeneration,
              let controller = strokeRuntimeController
        else {
            return
        }
        let scheduler = activeStroke?.frozenHarnessScheduler?
            .diagnosticSnapshot
        let authoritativeReplay: UInt64 = 0
        let predictedReplay: UInt64 = 0
        let residentBytes = UInt64(max(
            0,
            paintRevisionResidentBytesState
                + (activeDrawBrush?.residentByteCount ?? 0)
                + (activeEraserBrush?.residentByteCount ?? 0)
        ))
        do {
            try controller.recordPrepared(
                id: id.frameID,
                at: DispatchTime.now().uptimeNanoseconds,
                newLogicalDabCount: UInt64(max(
                    0,
                    counters.newDabsThisEvent
                )),
                newProjectedDabCount: UInt64(max(
                    0,
                    counters.newInstancesThisFrame
                )),
                authoritativeReplayCount: authoritativeReplay,
                predictedReplayCount: predictedReplay,
                authoritativeQueueDepth:
                    scheduler?.authoritativePending ?? 0,
                predictedQueueDepth: scheduler?.predictedPending ?? 0,
                cacheHitCount: 0,
                cacheMissCount: 0,
                residentMemoryBytes: residentBytes
            )
        } catch {
            controller.discardFrame(id: id.frameID)
            pendingStrokeRuntimeFrameIDs.remove(id)
        }
    }

    private func discardStrokeRuntimeFrame(
        _ identity: StrokeRuntimeFrameIdentity
    ) {
        if identity.telemetryGeneration == telemetryEventGeneration {
            strokeRuntimeController?.discardFrame(id: identity.frameID)
        }
        pendingStrokeRuntimeFrameIDs.remove(identity)
    }

    private func recordStrokeRuntimeSubmittedFrame(
        id: StrokeRuntimeFrameIdentity?,
        at timestamp: UInt64
    ) {
        guard let id,
              id.telemetryGeneration == telemetryEventGeneration,
              let controller = strokeRuntimeController
        else {
            return
        }
        do {
            try controller.recordSubmitted(id: id.frameID, at: timestamp)
        } catch {
            controller.discardFrame(id: id.frameID)
            pendingStrokeRuntimeFrameIDs.remove(id)
        }
    }

    private func recordStrokeRuntimeCompletedFrame(
        id: StrokeRuntimeFrameIdentity?,
        commandBuffer: any MTLCommandBuffer,
        submittedAt: UInt64,
        completedAt: UInt64,
        presentedAt: UInt64? = nil
    ) {
        recordStrokeRuntimeCompletedFrame(
            id: id,
            measuredGPUStart: Self.nanoseconds(commandBuffer.gpuStartTime),
            measuredGPUEnd: Self.nanoseconds(commandBuffer.gpuEndTime),
            submittedAt: submittedAt,
            completedAt: completedAt,
            presentedAt: presentedAt
        )
    }

    private func recordStrokeRuntimeCompletedFrame(
        id: StrokeRuntimeFrameIdentity?,
        measuredGPUStart: UInt64,
        measuredGPUEnd: UInt64,
        submittedAt: UInt64,
        completedAt: UInt64,
        presentedAt: UInt64? = nil
    ) {
        guard let id,
              id.telemetryGeneration == telemetryEventGeneration,
              let controller = strokeRuntimeController
        else {
            return
        }
        let gpuStarted = max(submittedAt, measuredGPUStart)
        let gpuFinished = max(gpuStarted, measuredGPUEnd)
        let presented = max(gpuFinished, presentedAt ?? completedAt)
        do {
            _ = try controller.recordGPU(
                id: id.frameID,
                started: gpuStarted,
                finished: gpuFinished
            )
            if try controller.recordPresented(
                id: id.frameID,
                at: presented,
                semantics: .offscreenCommandCompleted
            ) {
                pendingStrokeRuntimeFrameIDs.remove(id)
                publishStrokeRuntimeSnapshotIfDue(controller)
            }
        } catch {
            controller.discardFrame(id: id.frameID)
            pendingStrokeRuntimeFrameIDs.remove(id)
        }
    }

    private func recordStrokeRuntimeGPUFrame(
        id: StrokeRuntimeFrameIdentity?,
        measuredStart: UInt64,
        measuredFinish: UInt64,
        submittedAt: UInt64
    ) {
        guard let id,
              id.telemetryGeneration == telemetryEventGeneration,
              let controller = strokeRuntimeController
        else {
            return
        }
        let gpuStarted = max(
            submittedAt,
            measuredStart
        )
        let gpuFinished = max(
            gpuStarted,
            measuredFinish
        )
        do {
            if try controller.recordGPU(
                id: id.frameID,
                started: gpuStarted,
                finished: gpuFinished
            ) {
                pendingStrokeRuntimeFrameIDs.remove(id)
                publishStrokeRuntimeSnapshotIfDue(controller)
            }
        } catch {
            controller.discardFrame(id: id.frameID)
            pendingStrokeRuntimeFrameIDs.remove(id)
        }
    }

    private func recordStrokeRuntimePresentedFrame(
        id: StrokeRuntimeFrameIdentity?,
        at timestamp: UInt64
    ) {
        guard let id,
              id.telemetryGeneration == telemetryEventGeneration,
              let controller = strokeRuntimeController
        else {
            return
        }
        do {
            if try controller.recordPresented(
                id: id.frameID,
                at: timestamp,
                semantics: .drawablePresented
            ) {
                pendingStrokeRuntimeFrameIDs.remove(id)
                publishStrokeRuntimeSnapshotIfDue(controller)
            }
        } catch {
            controller.discardFrame(id: id.frameID)
            pendingStrokeRuntimeFrameIDs.remove(id)
        }
    }

    private func endStrokeRuntimeIfPossible() -> [RendererEvent] {
        guard let controller = strokeRuntimeController,
              let generation = telemetryEventGeneration
        else {
            return []
        }
        for identity in pendingStrokeRuntimeFrameIDs.sorted(by: {
            $0.frameID < $1.frameID
        }) where identity.telemetryGeneration == generation {
            controller.discardFrame(id: identity.frameID)
        }
        controller.discardPendingFrames()
        pendingStrokeRuntimeFrameIDs.removeAll(keepingCapacity: true)
        do {
            let marker = try controller.endStroke()
            return [
                .strokeRuntimeSegmentMarker(
                    generation: generation,
                    marker: marker
                ),
                .strokeRuntimeSnapshot(
                    generation: generation,
                    snapshot: controller.snapshot
                ),
            ]
        } catch {
            if let marker = try? controller.endStroke() {
                return [
                    .strokeRuntimeSegmentMarker(
                        generation: generation,
                        marker: marker
                    ),
                    .strokeRuntimeSnapshot(
                        generation: generation,
                        snapshot: controller.snapshot
                    ),
                ]
            }
            return []
        }
    }

    private func publishStrokeRuntimeSnapshotIfDue(
        _ controller: StrokeRuntimeProductionController
    ) {
        guard controller.shouldPublishLiveSnapshot else { return }
        guard let generation = telemetryEventGeneration else { return }
        stageRendererEvent(
            .strokeRuntimeSnapshot(
                generation: generation,
                snapshot: controller.snapshot
            )
        )
    }

    nonisolated private static func nanoseconds(
        _ seconds: TimeInterval
    ) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let value = seconds * 1_000_000_000
        guard value < Double(UInt64.max) else { return .max }
        return UInt64(value)
    }

    static func performMeasuredCPUPreparation<Completion>(
        clock: () -> CFAbsoluteTime,
        preparation: () throws -> Void,
        waitForCompletion: () async -> Completion
    ) async rethrows -> (
        completion: Completion,
        cpuPreparationMilliseconds: Double
    ) {
        let started = clock()
        try preparation()
        let cpuPreparationMilliseconds = max(
            0,
            (clock() - started) * 1_000
        )
        return (
            await waitForCompletion(),
            cpuPreparationMilliseconds
        )
    }

    static func saturatingAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }

    func metrics(
        commandBuffer: any MTLCommandBuffer,
        cpuMilliseconds: Double,
        submittedAtNanoseconds: UInt64 = 0,
        completedAtNanoseconds: UInt64 = 0,
        encodedDabCount: Int = 0,
        encodedInstanceCount: Int = 0,
        bufferLeaseCount: Int = 0
    ) -> GPUFrameMetrics {
        let eventToSubmitNanoseconds = submittedAtNanoseconds == 0
            ? 0
            : takeBrushLabEventToSubmitNanoseconds(
                submittedAt: submittedAtNanoseconds,
                consumeReceipt: encodedInstanceCount > 0
            )
        return GPUFrameMetrics(
            cpuEncodeMilliseconds: cpuMilliseconds,
            gpuMilliseconds: max(
                0,
                (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
            ),
            eventToSubmitNanoseconds: eventToSubmitNanoseconds,
            gpuCompletionNanoseconds:
                completedAtNanoseconds >= submittedAtNanoseconds
                    ? completedAtNanoseconds - submittedAtNanoseconds
                    : 0,
            encodedDabCount: encodedDabCount,
            encodedInstanceCount: encodedInstanceCount,
            bufferLeaseCount: bufferLeaseCount
        )
    }
}
