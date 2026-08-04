import CShaderTypes
import Foundation
import Metal
import MetalKit
import PatternEngine

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
        self.deposition = deposition
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

struct HarnessDiagnosticRenderedFrame {
    let canonical: any MTLTexture
    let screen: any MTLTexture
    let displayValidationCanonical: any MTLTexture
    let displayValidationScreen: any MTLTexture
    let gridLinesScreen: any MTLTexture
    let fragments: [CellFragment]
    let metrics: GPUFrameMetrics
}

public struct HarnessLiveFlushResult {
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

struct HarnessTilingMutationSnapshot: Equatable {
    let canonicalFront: ObjectIdentifier
    let canonicalScratch: ObjectIdentifier
    let liveTexture: ObjectIdentifier
    let revision: RasterRevision
    let liveVisible: Bool
    let liveDirty: Bool
    let needsLiveClear: Bool
    let counters: GridStructuralCounters
    let pendingInstanceCount: Int
    let bakedHighWater: UInt64
    let emittedHighWater: UInt64
}

struct StrokeRuntimeReplayEpochTracker {
    private(set) var lastEpoch: UInt64 = 0

    mutating func beginStroke(at epoch: UInt64) {
        lastEpoch = epoch
    }

    mutating func consume(currentEpoch: UInt64) -> UInt64 {
        let delta = currentEpoch >= lastEpoch
            ? currentEpoch - lastEpoch
            : currentEpoch
        lastEpoch = currentEpoch
        return delta
    }
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
    public let device: any MTLDevice
    public var pixelSize: PixelSize { resources.canvasPixelSize }
    var storagePixelSize: PixelSize { resources.pixelSize }
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
    struct StrokeRuntimeFrameIdentity: Hashable {
        let telemetryGeneration: UInt64
        let frameID: UInt64
    }
    private var nextStrokeRuntimeFrameID: UInt64 = 1
    private var pendingStrokeRuntimeFrameIDs:
        Set<StrokeRuntimeFrameIdentity> = []
    private var strokeRuntimeReplayEpochTracker =
        StrokeRuntimeReplayEpochTracker()
    public private(set) var interactiveGridVisibility = false
    public var isIdle: Bool {
        activeStroke == nil
            && pendingRasterOperation == nil
            && strokeWorkspaceState == .available
    }
    public var strokeRuntimeSnapshot: StrokeRuntimeTelemetrySnapshot? {
        strokeRuntimeController?.snapshot
    }
    public var strokeRuntimeRecordedEvidence: StrokeRuntimeRecordedEvidence? {
        strokeRuntimeController?.recordedEvidence
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
        strokeRuntimeReplayEpochTracker.beginStroke(at: 0)
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
        guard pendingRasterOperation == nil else { return false }
        guard let activeStroke else { return false }
        return !activeStroke.commitRequested
            && activeStroke.pendingRevisions == nil
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
        let liveDirty = liveStroke.dirtyRegions(
            clippedTo: storagePixelSize
        ).rectangles.count
        let replayDirty = replayStroke.dirtyRegions(
            clippedTo: storagePixelSize
        ).rectangles.count
        return BrushLabRendererDiagnosticSnapshot(
            totalDabsThisStroke: counters.totalDabsThisStroke,
            totalInstancesThisStroke: counters.totalInstancesThisStroke,
            renderedFramesThisStroke: counters.renderedFramesThisStroke,
            actualDabCount: brushLabActualDabCount,
            predictedDabCount: brushLabPredictedDabCount,
            replayCount: transientStrokeBuffer?.replayEpoch ?? 0,
            dirtyRegionCount: liveDirty + replayDirty,
            rasterRevisionResidentBytes: revisionStore.residentBytes,
            builtInTextureCount:
                (activeDrawBrush?.textures.count ?? 0)
                    + (activeEraserBrush?.textures.count ?? 0),
            assetFallbackCount: 0,
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

    struct FrameUpload {
        enum Layer: Equatable {
            case settled
            case replay
        }

        let lease: DabInstanceBufferPool.Lease
        let identityRange: Range<UInt64>
        let throughExclusive: UInt64
        let count: Int
        let layer: Layer
        let replayEpoch: UInt64
    }

    struct PendingLiveEncoding {
        let uploads: [FrameUpload]
        let encodedReplayClear: Bool
    }

    struct NativeDepositionFrameEncoding {
        let authoritativeCount: Int
        let predictedCount: Int
        let logicalDabCount: Int
        let uploadBufferCount: Int
        let encodedLiveClear: Bool
        let encodedReplayClear: Bool
        let replayEpoch: UInt64
        let encodedAuthoritativeIdentityRange: Range<UInt64>?
        let preparedWorkerFrame: PreparedWorkerFrameIdentity?

        var instanceCount: Int {
            authoritativeCount + predictedCount
        }
    }

    struct PreparedWorkerFrameIdentity: Equatable, Sendable {
        let generation: UInt64
        let token: UInt64
        let recordCount: Int
    }

    struct PendingPreparedSurfaceFrame: Sendable {
        let identity: PreparedWorkerFrameIdentity
        let lease: StrokePreparedSurfaceLease
        let logicalDabCount: Int
        let replayEpoch: UInt64
    }

    struct ActiveStrokeExecution {
        let token: RendererOperationToken
        let style: StrokeRenderStyle
        let brush: CompiledBrushRenderState
        let renderIdentity: BrushRenderIdentity
        /// Scheduler retained only by deterministic projected-dab harnesses.
        /// Interactive compiled-brush strokes always leave this nil.
        var frozenHarnessScheduler: FrameScheduler?
        var commitRequested: Bool
        var commitRetainedByteLimit: Int?
        var pendingRevisions: PendingRasterRevisionPair?
        var pendingTokenBearingFrameCount: Int
        var isFinishedTransiently: Bool

        var isCommitSubmitted: Bool {
            !commitRequested && pendingRevisions != nil
        }
    }

    struct EncodedRasterCommit {
        let token: RendererOperationToken
        let revisions: PendingRasterRevisionPair
        let captureTokens: [RasterRevisionOperationToken]
    }

    struct ProjectedDabRecord {
        let depositionRecord: ProjectedDepositionRecord
        let dirtyRect: PixelRect
        let radialPage: RadialPageCoordinate?
    }

    private struct PreparedGeneratedDab {
        let attributes: DabAttributes
        let projectedRange: Range<Int>

        var transient: TransientStrokeDab {
            TransientStrokeDab(
                attributes: attributes,
                projectedInstanceCount: projectedRange.count
            )
        }
    }

    private struct PredictionGenerationLimits {
        let maximumDabCount: Int
        let maximumProjectedInstanceCount: Int
    }

    private struct PreparedPredictionDabs {
        let range: Range<Int>
        let overload: PredictionOverloadReasons
    }

    private struct PredictionGenerationLimitReached: Error {
        let reason: PredictionOverloadReasons
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

    /// Renderer-owned collection storage used by the synchronous input and
    /// frame-drain paths. Every buffer is reserved before a stroke can arm the
    /// allocation audit; hot-path reuse clears logical contents while keeping
    /// the backing storage.
    private final class DepositionInputScratch {
        var preparedDabs: [PreparedGeneratedDab] = []
        var transientDabs: [TransientStrokeDab] = []
        var preparedChunkRanges: [Range<Int>] = []
        var transientChunks: [TransientStrokeChunk] = []
        var settledChunks: [TransientStrokeChunk] = []
        var worldSamples: [WorldStrokeSample] = []
        var projectedArena: [ProjectedDabRecord] = []
        var flattenedProjected: [ProjectedDabRecord] = []
        var depositionRecords: [ProjectedDepositionRecord] = []
        var replayRecords: [ProjectedDabRecord] = []
        var replayDirtyRegions: [PixelRect] = []
        var authoritativeFrame: [ProjectedDepositionRecord] = []
        var predictedFrame: [ProjectedDepositionRecord] = []
        var encodedLogicalIdentities: [UInt64] = []

        init() {
            preparedDabs.reserveCapacity(
                TransientStrokeBufferContract.wholeStrokeDabCapacity
            )
            transientDabs.reserveCapacity(
                TransientStrokeBufferContract.wholeStrokeDabCapacity
            )
            preparedChunkRanges.reserveCapacity(
                TransientStrokeBufferContract.wholeStrokeSampleCapacity
            )
            transientChunks.reserveCapacity(
                TransientStrokeBufferContract.wholeStrokeSampleCapacity
            )
            settledChunks.reserveCapacity(
                TransientStrokeBufferContract.wholeStrokeSampleCapacity
            )
            worldSamples.reserveCapacity(
                TransientStrokeBufferContract.wholeStrokeSampleCapacity
            )
            projectedArena.reserveCapacity(
                TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity
            )
            flattenedProjected.reserveCapacity(
                TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity
            )
            depositionRecords.reserveCapacity(
                GridCanvasContract.pendingCapacity
            )
            replayRecords.reserveCapacity(
                TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity
            )
            replayDirtyRegions.reserveCapacity(
                TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity
                + LiveStroke.maximumRetainedDirtyRectangleCount
            )
            authoritativeFrame.reserveCapacity(
                GridCanvasContract.instanceCapacity
            )
            predictedFrame.reserveCapacity(
                TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity
            )
            encodedLogicalIdentities.reserveCapacity(
                TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity
            )
        }
    }

    struct RasterResources {
        let canvasPixelSize: PixelSize
        let pixelSize: PixelSize
        let tileSize: PatternSize
        let canonical: CanonicalRaster
        let liveTile: PersistentLiveTile
        let predictionOverlay: PredictionOverlay
    }

    struct PreparedRasterReplacement {
        let resources: RasterResources
        let strokeMetalSurfaceResources: StrokeMetalSurfaceResources
        let strategy: TilingStrategy
        let radialPageTableTexture: any MTLTexture
    }

    struct PendingClearOperation {
        let submissionID: UInt64
        let token: RendererOperationToken
        let revisions: PendingRasterRevisionPair
        let captureTokens: [RasterRevisionOperationToken]
        let commandBuffer: any MTLCommandBuffer
    }

    struct PendingRestoreOperation {
        let submissionID: UInt64
        let token: RendererOperationToken
        let revision: RasterRevisionReference
        let restoreToken: RasterRevisionOperationToken
        let commandBuffer: any MTLCommandBuffer
    }

    struct PendingResizeOperation {
        let submissionID: UInt64
        let token: RendererOperationToken
        let replacement: PreparedRasterReplacement
        let revisions: PendingRasterRevisionPair
        let captureTokens: [RasterRevisionOperationToken]
        let commandBuffer: any MTLCommandBuffer
    }

    struct PendingResizeRestoreOperation {
        let submissionID: UInt64
        let token: RendererOperationToken
        let replacement: PreparedRasterReplacement
        let restoreToken: RasterRevisionOperationToken
        let commandBuffer: any MTLCommandBuffer
    }

    enum PendingRasterOperation {
        case clear(PendingClearOperation)
        case restore(PendingRestoreOperation)
        case resize(PendingResizeOperation)
        case resizeRestore(PendingResizeRestoreOperation)

        var submissionID: UInt64 {
            switch self {
            case let .clear(operation):
                operation.submissionID
            case let .restore(operation):
                operation.submissionID
            case let .resize(operation):
                operation.submissionID
            case let .resizeRestore(operation):
                operation.submissionID
            }
        }

        var token: RendererOperationToken {
            switch self {
            case let .clear(operation):
                operation.token
            case let .restore(operation):
                operation.token
            case let .resize(operation):
                operation.token
            case let .resizeRestore(operation):
                operation.token
            }
        }

        var commandBuffer: any MTLCommandBuffer {
            switch self {
            case let .clear(operation):
                operation.commandBuffer
            case let .restore(operation):
                operation.commandBuffer
            case let .resize(operation):
                operation.commandBuffer
            case let .resizeRestore(operation):
                operation.commandBuffer
            }
        }
    }

    let commandQueue: any MTLCommandQueue
    let library: any MTLLibrary
    private let pipelines: GridPipelineLibrary
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
    private let depositionInputScratch = DepositionInputScratch()
    let transientDabArena = TransientStrokeDabArena()
    private let tilingProjectionScratch = TilingProjectionScratch(
        maximumFragmentCount:
            TransientStrokeBufferContract
                .visibleEpochProjectedInstanceCapacity
    )
    var scheduledAuthoritativeIdentityHighWater: UInt64 = 0
    private var encodedAuthoritativeIdentityHighWater: UInt64 = 0
    var lastEncodedAuthoritativeIdentityRange: Range<UInt64>?
    let revisionStore: RasterRevisionStore
    let completionMailbox = GridRenderCompletionMailbox()
    private let rasterCompletionMailbox = RendererRasterCompletionMailbox()
    var resources: RasterResources
    private var strokeMetalSurfaceResources: StrokeMetalSurfaceResources
    private var strokeMetalSurfaceInstallationCount: UInt64 = 1
    private var radialPageTableTexture: (any MTLTexture)?
    var tileSize: PatternSize { resources.tileSize }
    var canonical: CanonicalRaster { resources.canonical }
    var liveTile: PersistentLiveTile { resources.liveTile }
    var predictionOverlay: PredictionOverlay {
        resources.predictionOverlay
    }
    var replayTile: ReplayLiveTile { predictionOverlay.surface }
    var tilingStrategy: TilingStrategy
    var activeStroke: ActiveStrokeExecution?
    var pendingRasterOperation: PendingRasterOperation?
    var strokeGenerator: BrushStrokeGenerator?
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
    private var pendingPreparedWorkerFrame: PreparedWorkerFrameIdentity?
    private var pendingPreparedSurfaceFrame: PendingPreparedSurfaceFrame?
    private var submittedPreparedWorkerFrame:
        PreparedWorkerFrameIdentity?
    private var currentPreparedSurfaceLease:
        StrokePreparedSurfaceLease?
    private var offMainLiveVisible = false
    private var offMainReplayVisible = false
    var compositeLiveIsVisible: Bool {
        if strokePreparationBridge != nil {
            return offMainLiveVisible || offMainReplayVisible
        }
        return liveTile.isVisible || replayTile.isVisible
    }
    private var pendingPreparationCommitRetainedBytes: Int?
    private var lastOffMainCoordinatorSnapshot: StrokeRenderSnapshot?
    private var lastOffMainPredictionProvenanceBoundary:
        PredictionProvenanceBoundary?
    private var lastOffMainEncodingRanOnMainThread: Bool?
    private var lastOffMainSurfaceSnapshot:
        StrokePrivateSurfaceEncoderSnapshot?
    private var lastOffMainZeroWorkLeaseCount = 0
    private var lastOffMainPredictedInstanceCount = 0
    var predictedStrokeGenerator: BrushStrokeGenerator?
    var transientStrokeBuffer: TransientStrokeBuffer?
    var brushInputDeriver = BrushInputDeriver()
    var predictedInputDeriver: BrushInputDeriver?
    var liveStroke = LiveStroke()
    var replayStroke = LiveStroke(
        capacity: TransientStrokeBufferContract
            .visibleEpochProjectedInstanceCapacity
    )
    private var completedUploadRanges: [
        (
            signal: UInt64,
            throughExclusive: UInt64,
            layer: FrameUpload.Layer,
            replayEpoch: UInt64
        )
    ] = []
    var needsLiveClear = true
    var needsReplayClear = true
    private var nextHarnessTokenRawValue: UInt64 = 1
    private var nextRasterSubmissionID: UInt64 = 1
    private var nextReplayEpoch: UInt64 = 1
    private var knownStrokeTotalDistance: Float?

    private var forceOffMainStrokeCommandFailureForTesting = false

    public convenience init(
        device: any MTLDevice,
        drawableSize: PatternSize,
        configuration: TilingCanvasConfiguration
    ) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.defaultLibraryUnavailable
        }
        try self.init(
            device: device,
            library: library,
            drawableSize: drawableSize,
            configuration: configuration
        )
    }

    public init(
        device: any MTLDevice,
        library: any MTLLibrary,
        drawableSize: PatternSize,
        configuration: TilingCanvasConfiguration
    ) throws {
        ShaderABI.preconditionValid()
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
        let resources = try Self.makeRasterResources(
            device: device,
            canvasPixelSize: configuration.pixelSize,
            pixelSize: storageSize,
            initialRevision: RasterRevision(rawValue: 0),
            forceAllocationFailure: false
        )
        self.device = device
        self.commandQueue = commandQueue
        self.library = library
        self.resources = resources
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
        strokeMetalSurfaceResources = try StrokeMetalSurfaceResources(
            device: device,
            pixelSize: storageSize,
            maximumRecordCount: max(
                frameBudget.maximumAuthoritativeInstances,
                frameBudget.maximumPredictedInstances
            )
        )
        warmedStrokePreparationBridge = StrokePreparationBridge(
            budget: frameBudget,
            targetFramesPerSecond: 120
        )
        activeDrawBrush = nil
        activeEraserBrush = nil
        tilingStrategy = strategy
        radialPageTableTexture = try Self.makeRadialPageTableTexture(
            device: device,
            compiled: strategy.compiledSymmetry
        )
        pipelines = try GridPipelineLibrary(device: device, library: library)
        instancePool = try DabInstanceBufferPool(device: device)
        depositionEncoder = nil
        revisionStore = RasterRevisionStore(device: device)
        viewport = ViewportTransform(
            drawableSize: drawableSize,
            worldCenter: WorldPoint(
                x: Float(resources.canvasPixelSize.width) * 0.5,
                y: Float(resources.canvasPixelSize.height) * 0.5
            ),
            zoom: 1
        )
        completedUploadRanges.reserveCapacity(
            GridCanvasContract.inFlightBufferCount
        )
        strokePreparationResultScratch.reserveCapacity(1)
        predictionSubmissionScratch.reserveCapacity(
            PredictionOverlay.maximumNormalizedSampleCount
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
        try clearInitialTextures()
    }

    public func applyTiling(_ tiling: TilingKind) throws {
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
        try applyPeriodicConfiguration(proposed)
    }

    public func applyPeriodicConfiguration(
        _ configuration: PeriodicSymmetryConfiguration
    ) throws {
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
            try installEmptyStrategy(proposed)
        } else {
            tilingStrategy = proposed
        }
    }

    public func applyFiniteConfiguration(
        _ configuration: FiniteSymmetryConfiguration
    ) throws {
        try replaceEmptyDocumentConfiguration(
            .finite(configuration),
            pixelSize: pixelSize
        )
    }

    public func replaceEmptyDocumentConfiguration(
        _ configuration: SymmetryDocumentConfiguration,
        pixelSize proposedPixelSize: PixelSize
    ) throws {
        try replaceEmptyDocumentConfiguration(
            configuration,
            pixelSize: proposedPixelSize,
            forceStrokeSurfaceAllocationFailure: false
        )
    }

    func replaceEmptyDocumentConfigurationForTesting(
        _ configuration: SymmetryDocumentConfiguration,
        pixelSize proposedPixelSize: PixelSize,
        forceStrokeSurfaceAllocationFailure: Bool
    ) throws {
        try replaceEmptyDocumentConfiguration(
            configuration,
            pixelSize: proposedPixelSize,
            forceStrokeSurfaceAllocationFailure:
                forceStrokeSurfaceAllocationFailure
        )
    }

    private func replaceEmptyDocumentConfiguration(
        _ configuration: SymmetryDocumentConfiguration,
        pixelSize proposedPixelSize: PixelSize,
        forceStrokeSurfaceAllocationFailure: Bool
    ) throws {
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
        try installEmptyStrategy(
            proposed,
            forceStrokeSurfaceAllocationFailure:
                forceStrokeSurfaceAllocationFailure
        )
    }

    public func reconcileGeometryLock(documentIsEmpty: Bool) throws {
        guard isIdle else {
            throw MetalRendererError.commitPendingInput
        }
        setDocumentGeometryLocked(!documentIsEmpty)
    }

    public func setFiniteConfiguration(
        _ configuration: FiniteSymmetryConfiguration
    ) throws {
        try applyFiniteConfiguration(configuration)
    }

    private func installEmptyStrategy(
        _ proposed: TilingStrategy,
        forceStrokeSurfaceAllocationFailure: Bool = false
    ) throws {
        let canvasSizeChanged = proposed.canvasSize != pixelSize
        let proposedStorageSize = PixelSize(
            width: Int(proposed.tileSize.width),
            height: Int(proposed.tileSize.height)
        )
        let replacement = try Self.makeRasterResources(
            device: device,
            canvasPixelSize: proposed.canvasSize,
            pixelSize: proposedStorageSize,
            initialRevision: canonical.revision,
            forceAllocationFailure: false
        )
        let replacementPageTable = try Self.makeRadialPageTableTexture(
            device: device,
            compiled: proposed.compiledSymmetry
        )
        if forceStrokeSurfaceAllocationFailure {
            throw MetalRendererError.textureAllocationFailed
        }
        let replacementStrokeMetalSurfaceResources =
            try StrokeMetalSurfaceResources(
                device: device,
                pixelSize: proposedStorageSize,
                maximumRecordCount: max(
                    depositionFrameBudget.maximumAuthoritativeInstances,
                    depositionFrameBudget.maximumPredictedInstances
                )
            )
        let priorResources = resources
        let priorStrategy = tilingStrategy
        let priorPageTable = radialPageTableTexture
        let priorStrokeMetalSurfaceResources =
            strokeMetalSurfaceResources
        let priorStrokeMetalSurfaceInstallationCount =
            strokeMetalSurfaceInstallationCount
        resources = replacement
        strokeMetalSurfaceResources =
            replacementStrokeMetalSurfaceResources
        strokeMetalSurfaceInstallationCount &+= 1
        tilingStrategy = proposed
        radialPageTableTexture = replacementPageTable
        do {
            try clearInitialTextures()
        } catch {
            resources = priorResources
            strokeMetalSurfaceResources =
                priorStrokeMetalSurfaceResources
            strokeMetalSurfaceInstallationCount =
                priorStrokeMetalSurfaceInstallationCount
            tilingStrategy = priorStrategy
            radialPageTableTexture = priorPageTable
            throw error
        }
        setDocumentGeometryLocked(false)
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

    public func setTiling(_ tiling: TilingKind) throws {
        try applyTiling(tiling)
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
        let material = definition.material
        guard brush.program.requestedBackend == .deposition,
              brush.pipelineKey.backend == .deposition,
              material.interaction == .none,
              material.edgeTreatment != .wetConcentration
        else {
            throw MetalRendererError.unsupportedCompiledBrush
        }
        let expectedMaterial: DepositionMaterialBinding
        do {
            expectedMaterial = try DepositionMaterialBinding(
                compiledBrush: brush
            )
        } catch {
            throw MetalRendererError.invalidCompiledBrush
        }
        let pipelineKey = brush.depositionPipeline.key
        guard brush.renderIdentity.definitionID == definition.id,
              brush.report.definitionID == definition.id.rawValue,
              brush.report.packageContentHash
                == brush.renderIdentity.semanticHash,
              brush.report.backend == brush.program.requestedBackend,
              brush.pipelineKey == pipelineKey.brush,
              pipelineKey.abiVersion == DepositionABI.version,
              pipelineKey.colorPixelFormatRawValue
                == GridPipelineLibrary.colorPixelFormat.rawValue,
              pipelineKey.sampleCount == GridPipelineLibrary.sampleCount,
              brush.uniformTemplate.placement == definition.placement,
              brush.uniformTemplate.coverage == definition.coverage,
              brush.uniformTemplate.color == definition.color,
              brush.uniformTemplate.material == definition.material,
              depositionMaterial(
                brush.depositionMaterial,
                matches: expectedMaterial
              ),
              brush.residentByteCount >= 0,
              brush.report.residentResourceBytes
                == brush.residentByteCount
        else {
            throw MetalRendererError.invalidCompiledBrush
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
    ) throws {
        try applyPeriodicConfiguration(configuration)
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
            commitRetainedByteLimit: nil,
            pendingRevisions: nil,
            pendingTokenBearingFrameCount: 0,
            isFinishedTransiently: false
        )
        let generation = rendererEventDispatcher.advanceStrokeGeneration()
        strokeEventGeneration = generation
        let runtimeBeginEvents = beginStrokeRuntime(sample)
        do {
            counters.newDabsThisEvent = 0
            let forceOffMainCommandFailure =
                forceOffMainStrokeCommandFailureForTesting
            let metalResourceDescriptor = StrokeMetalResourceDescriptor(
                surfaces: strokeMetalSurfaceResources,
                brush: brushRenderState,
                frameUniforms: frameUniforms(
                    drawableSize: tileSize,
                    showGridLines: false,
                    liveVisible: true
                ),
                forceCommandFailure: forceOffMainCommandFailure
            )
            let bridge = warmedStrokePreparationBridge
            strokePreparationBridge = bridge
            strokePreparationGeneration = generation
            strokeWorkspaceState = .borrowed(generation)
            try submitStrokeInput(
                .begin(
                    generation: generation,
                    configuration: StrokePreparationConfiguration(
                        program: style.program,
                        nominalDiameter: style.diameter,
                        color: generatorColor,
                        seed: style.seed,
                        viewport: viewport,
                        tilingStrategy: tilingStrategy,
                        metalResourceDescriptor: metalResourceDescriptor,
                        allocationProbe: strokePreparationAllocationProbe
                    ),
                    samples: [sample]
                ),
                using: bridge
            )
            stageStrokeRuntimeEvents(runtimeBeginEvents)
            operationSucceeded = true
        } catch {
            _ = endStrokeRuntimeIfPossible()
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
            try requireCurrentPredictionProvenance()
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
                using: bridge
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
            try requireCurrentPredictionProvenance()
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
            PredictionOverlay.maximumNormalizedSampleCount
        ) {
            try validateStrokeAppendSample(sample)
            guard sample.kind == .predicted else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            predictionSubmissionScratch.append(sample)
        }
        if !authoritativeSamples.isEmpty {
            try requireCollectingStroke(token: token)
            try requireCurrentPredictionProvenance()
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
            using: bridge
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
            using: bridge
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
            using: bridge
        )
    }

    public func requestStrokeCommit(
        token: RendererOperationToken,
        sample: StrokeSample,
        maximumRetainedBytes: Int
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
            try requestOffMainStrokeCommit(
                maximumRetainedBytes: maximumRetainedBytes
            )
            operationSucceeded = true
        } catch {
            let runtimeEndEvents = endStrokeRuntimeIfPossible()
            discardPendingRevisionsIfPossible()
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
        try requireCurrentPredictionProvenance()
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
            using: bridge
        )
        activeStroke?.isFinishedTransiently = true
        operationSucceeded = true
    }

    public func commitFinishedStroke(
        token: RendererOperationToken,
        maximumRetainedBytes: Int
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
            try requestOffMainStrokeCommit(
                maximumRetainedBytes: maximumRetainedBytes
            )
            operationSucceeded = true
        } catch {
            let runtimeEndEvents = endStrokeRuntimeIfPossible()
            discardPendingRevisionsIfPossible()
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
        try requireCurrentPredictionProvenance()
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
            using: bridge
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

    public func releaseRasterRevisions(
        _ ids: Set<StoredRasterRevisionID>
    ) {
        guard !ids.isEmpty else { return }
        revisionStore.release(ids)
    }

    public func requestClear(
        token: RendererOperationToken,
        maximumRetainedBytes: Int
    ) throws {
        try requestClear(
            token: token,
            maximumRetainedBytes: maximumRetainedBytes,
            forceFailure: false
        )
    }

    public func requestRasterRestore(
        token: RendererOperationToken,
        revision: RasterRevisionReference
    ) throws {
        try requestRasterRestore(
            token: token,
            revision: revision,
            forceFailure: false
        )
    }

    public func requestResize(
        token: RendererOperationToken,
        to pixelSize: PixelSize,
        maximumRetainedBytes: Int
    ) throws {
        try requestResize(
            token: token,
            to: pixelSize,
            maximumRetainedBytes: maximumRetainedBytes,
            forceResourceAllocationFailure: false,
            forceCommandFailure: false
        )
    }

    public func requestResizeRestore(
        token: RendererOperationToken,
        revision: RasterRevisionReference
    ) throws {
        try requestResizeRestore(
            token: token,
            revision: revision,
            forceCommandFailure: false
        )
    }

    func requestResizeRestore(
        token: RendererOperationToken,
        revision: RasterRevisionReference,
        forceCommandFailure: Bool
    ) throws {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        let wasIdle = isIdle
        defer {
            notifyIdleStateIfChanged(from: wasIdle)
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        guard isIdle else {
            throw MetalRendererError.commitPendingInput
        }
        try validateTileSize(revision.documentPixelSize)
        guard revision.regions == fullRasterRegions(for: revision.pixelSize) else {
            throw MetalRendererError.commandFailed(
                "Resize restore requires a full-raster revision."
            )
        }

        let replacementStrategy = try resizedStrategy(
            canvasPixelSize: revision.documentPixelSize
        )
        let expectedStorageSize = storageSize(for: replacementStrategy)
        guard revision.pixelSize == expectedStorageSize else {
            throw MetalRendererError.rasterRevisionTextureSizeMismatch(
                expectedWidth: expectedStorageSize.width,
                expectedHeight: expectedStorageSize.height,
                actualWidth: revision.pixelSize.width,
                actualHeight: revision.pixelSize.height
            )
        }
        let replacementResources = try Self.makeRasterResources(
            device: device,
            canvasPixelSize: revision.documentPixelSize,
            pixelSize: revision.pixelSize,
            initialRevision: canonical.revision,
            forceAllocationFailure: false
        )
        let replacement = PreparedRasterReplacement(
            resources: replacementResources,
            strokeMetalSurfaceResources: try StrokeMetalSurfaceResources(
                device: device,
                pixelSize: revision.pixelSize,
                maximumRecordCount: max(
                    depositionFrameBudget.maximumAuthoritativeInstances,
                    depositionFrameBudget.maximumPredictedInstances
                )
            ),
            strategy: replacementStrategy,
            radialPageTableTexture: try Self.makeRadialPageTableTexture(
                device: device,
                compiled: replacementStrategy.compiledSymmetry
            )
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }

        let restoreToken: RasterRevisionOperationToken
        do {
            try encodeTransparentClear(
                of: replacement.resources.canonical.front,
                on: commandBuffer,
                label: "Resize Restore Front Clear"
            )
            try encodeTransparentClear(
                of: replacement.resources.canonical.scratch,
                on: commandBuffer,
                label: "Resize Restore Scratch Clear"
            )
            try encodeTransparentClear(
                of: replacement.resources.liveTile.texture,
                on: commandBuffer,
                label: "Resize Restore Live Clear"
            )
            try encodeTransparentClear(
                of: replacement.resources.predictionOverlay.surface.texture,
                on: commandBuffer,
                label: "Resize Restore Replay Clear"
            )
            restoreToken = try revisionStore.encodeRestore(
                revision,
                into: replacement.resources.canonical.scratch,
                on: commandBuffer
            )
        } catch {
            throw error
        }

        let submissionID = takeRasterSubmissionID()
        pendingRasterOperation = .resizeRestore(
            PendingResizeRestoreOperation(
                submissionID: submissionID,
                token: token,
                replacement: replacement,
                restoreToken: restoreToken,
                commandBuffer: commandBuffer
            )
        )
        installRasterCompletionHandler(
            on: commandBuffer,
            submissionID: submissionID,
            token: token,
            forceFailure: forceCommandFailure
        )
        commandBuffer.commit()
    }

    func requestResize(
        token: RendererOperationToken,
        to newPixelSize: PixelSize,
        maximumRetainedBytes: Int,
        forceResourceAllocationFailure: Bool,
        forceCommandFailure: Bool
    ) throws {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        let wasIdle = isIdle
        defer {
            notifyIdleStateIfChanged(from: wasIdle)
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        guard isIdle else {
            throw MetalRendererError.commitPendingInput
        }
        try validateTileSize(newPixelSize)
        guard maximumRetainedBytes >= 0 else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }

        let replacementStrategy = try resizedStrategy(
            canvasPixelSize: newPixelSize
        )
        let newStoragePixelSize = storageSize(for: replacementStrategy)
        let beforeRegions = fullRasterRegions(for: storagePixelSize)
        let afterRegions = fullRasterRegions(for: newStoragePixelSize)
        let beforeBytes = try revisionStore.retainedBytes(
            pixelSize: storagePixelSize,
            regions: beforeRegions
        )
        let afterBytes = try revisionStore.retainedBytes(
            pixelSize: newStoragePixelSize,
            regions: afterRegions
        )
        let (pairBytes, overflow) = beforeBytes.addingReportingOverflow(
            afterBytes
        )
        guard !overflow, pairBytes <= maximumRetainedBytes else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }

        let replacementResources = try Self.makeRasterResources(
            device: device,
            canvasPixelSize: newPixelSize,
            pixelSize: newStoragePixelSize,
            initialRevision: canonical.revision,
            forceAllocationFailure: forceResourceAllocationFailure
        )
        let replacement = PreparedRasterReplacement(
            resources: replacementResources,
            strokeMetalSurfaceResources: try StrokeMetalSurfaceResources(
                device: device,
                pixelSize: newStoragePixelSize,
                maximumRecordCount: max(
                    depositionFrameBudget.maximumAuthoritativeInstances,
                    depositionFrameBudget.maximumPredictedInstances
                )
            ),
            strategy: replacementStrategy,
            radialPageTableTexture: try Self.makeRadialPageTableTexture(
                device: device,
                compiled: replacementStrategy.compiledSymmetry
            )
        )
        let revisions = try revisionStore.allocatePair(
            beforePixelSize: storagePixelSize,
            beforeDocumentPixelSize: pixelSize,
            beforeRegions: beforeRegions,
            afterPixelSize: newStoragePixelSize,
            afterDocumentPixelSize: newPixelSize,
            afterRegions: afterRegions
        )
        precondition(
            revisions.retainedBytes == pairBytes,
            "Raster revision preflight and allocation must agree."
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            revisionStore.discard(revisions)
            throw MetalRendererError.commandBufferUnavailable
        }

        var captureTokens: [RasterRevisionOperationToken] = []
        do {
            captureTokens.append(
                try revisionStore.encodeCapture(
                    revisions.before,
                    from: canonical.front,
                    on: commandBuffer
                )
            )
            try encodeTransparentClear(
                of: replacement.resources.canonical.front,
                on: commandBuffer,
                label: "Resize Front Clear"
            )
            try encodeTransparentClear(
                of: replacement.resources.canonical.scratch,
                on: commandBuffer,
                label: "Resize Scratch Clear"
            )
            try encodeTransparentClear(
                of: replacement.resources.liveTile.texture,
                on: commandBuffer,
                label: "Resize Live Clear"
            )
            try encodeTransparentClear(
                of: replacement.resources.predictionOverlay.surface.texture,
                on: commandBuffer,
                label: "Resize Replay Clear"
            )
            if tilingStrategy.compiledSymmetry.family == .radial,
               replacementStrategy.compiledSymmetry.family == .radial,
               tiling != .plainCanvas
            {
                try encodeRadialResizeCopy(
                    from: canonical.front,
                    sourceStrategy: tilingStrategy,
                    sourcePageTable: radialPageTableTexture,
                    to: replacement.resources.canonical.scratch,
                    destinationStrategy: replacementStrategy,
                    on: commandBuffer
                )
            } else {
                try encodeResizeIntersectionCopy(
                    from: canonical.front,
                    oldPixelSize: storagePixelSize,
                    to: replacement.resources.canonical.scratch,
                    newPixelSize: newStoragePixelSize,
                    on: commandBuffer
                )
            }
            captureTokens.append(
                try revisionStore.encodeCapture(
                    revisions.after,
                    from: replacement.resources.canonical.scratch,
                    on: commandBuffer
                )
            )
        } catch {
            finalizeCaptureTokens(captureTokens, as: .cancelled)
            revisionStore.discard(revisions)
            throw error
        }

        let submissionID = takeRasterSubmissionID()
        pendingRasterOperation = .resize(
            PendingResizeOperation(
                submissionID: submissionID,
                token: token,
                replacement: replacement,
                revisions: revisions,
                captureTokens: captureTokens,
                commandBuffer: commandBuffer
            )
        )
        installRasterCompletionHandler(
            on: commandBuffer,
            submissionID: submissionID,
            token: token,
            forceFailure: forceCommandFailure
        )
        commandBuffer.commit()
    }

    func requestClear(
        token: RendererOperationToken,
        maximumRetainedBytes: Int,
        forceFailure: Bool
    ) throws {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        let wasIdle = isIdle
        defer {
            notifyIdleStateIfChanged(from: wasIdle)
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        guard isIdle else {
            throw MetalRendererError.commitPendingInput
        }
        guard maximumRetainedBytes >= 0 else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }

        let fullRegion = PixelRegionSet(
            [
                PixelRect(
                    minX: 0,
                    minY: 0,
                    maxX: storagePixelSize.width,
                    maxY: storagePixelSize.height
                )!,
            ],
            clippedTo: storagePixelSize
        )
        let oneRevisionBytes = try revisionStore.retainedBytes(
            pixelSize: storagePixelSize,
            regions: fullRegion
        )
        let (pairBytes, overflow) = oneRevisionBytes.multipliedReportingOverflow(
            by: 2
        )
        guard !overflow, pairBytes <= maximumRetainedBytes else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }

        let revisions = try revisionStore.allocatePair(
            beforePixelSize: storagePixelSize,
            beforeRegions: fullRegion,
            afterPixelSize: storagePixelSize,
            afterRegions: fullRegion
        )
        precondition(
            revisions.retainedBytes == pairBytes,
            "Raster revision preflight and allocation must agree."
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            revisionStore.discard(revisions)
            throw MetalRendererError.commandBufferUnavailable
        }

        var captureTokens: [RasterRevisionOperationToken] = []
        do {
            captureTokens.append(
                try revisionStore.encodeCapture(
                    revisions.before,
                    from: canonical.front,
                    on: commandBuffer
                )
            )
            try encodeTransparentClear(
                of: canonical.scratch,
                on: commandBuffer,
                label: "Canonical Scratch Clear"
            )
            captureTokens.append(
                try revisionStore.encodeCapture(
                    revisions.after,
                    from: canonical.scratch,
                    on: commandBuffer
                )
            )
        } catch {
            finalizeCaptureTokens(captureTokens, as: .cancelled)
            revisionStore.discard(revisions)
            throw error
        }

        let submissionID = takeRasterSubmissionID()
        pendingRasterOperation = .clear(
            PendingClearOperation(
                submissionID: submissionID,
                token: token,
                revisions: revisions,
                captureTokens: captureTokens,
                commandBuffer: commandBuffer
            )
        )
        installRasterCompletionHandler(
            on: commandBuffer,
            submissionID: submissionID,
            token: token,
            forceFailure: forceFailure
        )
        commandBuffer.commit()
    }

    func requestRasterRestore(
        token: RendererOperationToken,
        revision: RasterRevisionReference,
        forceFailure: Bool
    ) throws {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        let wasIdle = isIdle
        defer {
            notifyIdleStateIfChanged(from: wasIdle)
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        guard isIdle else {
            throw MetalRendererError.commitPendingInput
        }
        guard revision.pixelSize == storagePixelSize else {
            throw MetalRendererError.rasterRevisionTextureSizeMismatch(
                expectedWidth: storagePixelSize.width,
                expectedHeight: storagePixelSize.height,
                actualWidth: revision.pixelSize.width,
                actualHeight: revision.pixelSize.height
            )
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }

        try encodeCanonicalFrontCopy(to: canonical.scratch, on: commandBuffer)
        let restoreToken: RasterRevisionOperationToken
        do {
            restoreToken = try revisionStore.encodeRestore(
                revision,
                into: canonical.scratch,
                on: commandBuffer
            )
        } catch {
            throw error
        }

        let submissionID = takeRasterSubmissionID()
        pendingRasterOperation = .restore(
            PendingRestoreOperation(
                submissionID: submissionID,
                token: token,
                revision: revision,
                restoreToken: restoreToken,
                commandBuffer: commandBuffer
            )
        )
        installRasterCompletionHandler(
            on: commandBuffer,
            submissionID: submissionID,
            token: token,
            forceFailure: forceFailure
        )
        commandBuffer.commit()
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
        guard !activeStroke.commitRequested,
              activeStroke.pendingRevisions == nil
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
    }

    private func requireCurrentPredictionProvenance() throws {
        guard let visibleBoundary =
            predictionOverlay.currentProvenance
        else {
            return
        }
        guard visibleBoundary
            == lastOffMainPredictionProvenanceBoundary
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
    }

    func prepareFrozenProjectionHarnessCommit(
        maximumRetainedBytes: Int
    ) throws {
        try requestFrozenProjectionHarnessCommit(
            maximumRetainedBytes: maximumRetainedBytes
        )
    }

    private func requestFrozenProjectionHarnessCommit(
        maximumRetainedBytes: Int
    ) throws {
        markBrushLabInputReceipt()
        guard maximumRetainedBytes >= 0 else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }
        guard var execution = activeStroke,
              !execution.commitRequested,
              execution.pendingRevisions == nil
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard strokePreparationBridge == nil,
              let scheduler = execution.frozenHarnessScheduler
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let replayPreparation: ReplayCommitPreparation
        do {
            replayPreparation = try scheduler.prepareReplayForCommit()
        } catch let error as FrameSchedulerError {
            throw rendererError(for: error)
        }
        let promotedPredictionCount = replayPreparation
            .promotedNonPredictedInstanceCount
        if replayPreparation.discardedPredictedInstanceCount > 0 {
            let epoch = takeReplayEpoch()
            predictionOverlay.discard(epoch: epoch)
            replayStroke.beginReplacementEpoch(epoch)
            needsReplayClear = true
        }
        let (scheduledHighWater, overflow) =
            scheduledAuthoritativeIdentityHighWater.addingReportingOverflow(
                UInt64(promotedPredictionCount)
            )
        guard !overflow else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                depositionFrameBudget.maximumPendingAuthoritativeInstances
            )
        }
        scheduledAuthoritativeIdentityHighWater = scheduledHighWater
        recordBrushLabScheduler(scheduler)
        execution.commitRequested = true
        execution.commitRetainedByteLimit = maximumRetainedBytes
        activeStroke = execution
    }

    private func markOffMainStrokeCommitReady(
        maximumRetainedBytes: Int
    ) throws {
        markBrushLabInputReceipt()
        guard maximumRetainedBytes >= 0 else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }
        guard strokePreparationBridge != nil,
              var execution = activeStroke,
              execution.frozenHarnessScheduler == nil,
              !execution.commitRequested,
              execution.pendingRevisions == nil
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        execution.commitRequested = true
        execution.commitRetainedByteLimit = maximumRetainedBytes
        activeStroke = execution
    }

    private func requestOffMainStrokeCommit(
        maximumRetainedBytes: Int
    ) throws {
        guard maximumRetainedBytes >= 0 else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }
        guard pendingPreparationCommitRetainedBytes == nil,
              let bridge = strokePreparationBridge,
              let generation = strokePreparationGeneration
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        try submitStrokeInput(
            .commit(generation: generation),
            using: bridge
        )
        pendingPreparationCommitRetainedBytes = maximumRetainedBytes
    }

    @discardableResult
    private func submitStrokeInput(
        _ message: StrokeInputMessage,
        using bridge: StrokePreparationBridge
    ) throws -> StrokeInputAdmission {
        do {
            return try bridge.submit(message)
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

    func prepareCompiledCommitIfReady() throws {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        do {
            try prepareCompiledCommitIfReadyCore()
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

    private func prepareCompiledCommitIfReadyCore() throws {
        guard var execution = activeStroke else { return }
        let schedulerIsReady: Bool
        if let scheduler = execution.frozenHarnessScheduler {
            schedulerIsReady = scheduler.authoritativeIsDrained
                && scheduler.predictedCount == 0
        } else {
            schedulerIsReady = strokePreparationBridge != nil
                && pendingPreparedWorkerFrame == nil
                && pendingPreparedSurfaceFrame == nil
                && submittedPreparedWorkerFrame == nil
        }
        guard
              execution.commitRequested,
              execution.pendingRevisions == nil,
              schedulerIsReady,
              execution.pendingTokenBearingFrameCount == 0,
              !needsReplayClear,
              let maximumRetainedBytes =
                execution.commitRetainedByteLimit
        else {
            return
        }
        let settledRegions = liveStroke.dirtyRegions(
            clippedTo: storagePixelSize
        )
        let replayRegions = replayStroke.dirtyRegions(
            clippedTo: storagePixelSize
        )
        if settledRegions.rectangles.isEmpty,
           replayRegions.rectangles.isEmpty
        {
            finalizeNoOpStrokeCommit(execution)
            return
        }
        execution.pendingRevisions = try allocateCurrentStrokeRevisions(
            maximumRetainedBytes: maximumRetainedBytes
        )
        activeStroke = execution
    }

    /// A completely clipped stroke is a successful operation but not a
    /// raster mutation. It must not manufacture an empty history pair merely
    /// to drive the ordinary commit completion path.
    private func finalizeNoOpStrokeCommit(
        _ execution: ActiveStrokeExecution
    ) {
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        let runtimeEndEvents = endStrokeRuntimeIfPossible()
        activeStroke = nil
        resetLiveState(invalidateStrokeEvents: false)
        stageStrokeRuntimeEvents(runtimeEndEvents)
        stageRendererEvent(
            .operationCompleted(.operationSuccess(execution.token))
        )
    }

    private func allocateCurrentStrokeRevisions(
        maximumRetainedBytes: Int
    ) throws -> PendingRasterRevisionPair {
        guard maximumRetainedBytes >= 0 else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }
        let settledRegions = liveStroke.dirtyRegions(
            clippedTo: storagePixelSize
        )
        let replayRegions = replayStroke.dirtyRegions(
            clippedTo: storagePixelSize
        )
        let regions = PixelRegionSet(
            settledRegions.rectangles + replayRegions.rectangles,
            clippedTo: storagePixelSize
        )
        let oneRevisionBytes = try revisionStore.retainedBytes(
            pixelSize: storagePixelSize,
            regions: regions
        )
        let (pairBytes, overflow) = oneRevisionBytes.multipliedReportingOverflow(
            by: 2
        )
        guard !overflow, pairBytes <= maximumRetainedBytes else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }
        let pair = try revisionStore.allocatePair(
            beforePixelSize: storagePixelSize,
            beforeRegions: regions,
            afterPixelSize: storagePixelSize,
            afterRegions: regions
        )
        precondition(
            pair.retainedBytes == pairBytes,
            "Raster revision preflight and allocation must agree."
        )
        return pair
    }

    private func discardPendingRevisionsIfPossible() {
        guard let pair = activeStroke?.pendingRevisions else { return }
        revisionStore.discard(pair)
        activeStroke?.pendingRevisions = nil
    }

    /// Frozen projected-dab oracle entry point. It bypasses public stroke
    /// input entirely and exists only for deterministic capture fixtures.
    /// Interactive compiled-brush APIs never call this method.
    func beginFrozenProjectionHarnessExecution(radius: Float) throws {
        guard activeStroke == nil else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard let brush = preparedBrush(for: .draw) else {
            throw MetalRendererError.compiledBrushUnavailable(.draw)
        }
        let token = RendererOperationToken(rawValue: nextHarnessTokenRawValue)
        nextHarnessTokenRawValue &+= 1
        if nextHarnessTokenRawValue == 0 {
            nextHarnessTokenRawValue = 1
        }
        let style = StrokeRenderStyle(
            color: .black,
            diameter: radius * 2,
            compositeMode: .draw,
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
            commitRetainedByteLimit: nil,
            pendingRevisions: nil,
            pendingTokenBearingFrameCount: 0,
            isFinishedTransiently: false
        )
    }

    public func pan(byScreenDelta delta: SIMD2<Float>) {
        guard isIdle else { return }
        viewport = viewport.panned(byScreenDelta: delta)
    }

    public func zoom(by factor: Float, anchor: ScreenPoint) {
        guard isIdle else { return }
        viewport = viewport.zoomed(by: factor, anchorScreen: anchor)
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
    }

    public func resize(to size: PatternSize) {
        viewport = viewport.resized(to: size)
    }

    public func setInteractiveGridVisibility(_ visible: Bool) {
        interactiveGridVisibility = visible
    }

    /// Internal marker for a fatal completion outcome that already published
    /// its renderer error and terminal operation event while it was drained.
    /// Orchestration roots unwrap it without publishing the same failure again.
    private struct PreviouslyPublishedInteractiveFailure: Error {
        let error: MetalRendererError
    }

    public func completePendingInteractiveStroke() throws
        -> GPUFrameMetrics
    {
        try completePendingInteractiveStroke(forceCommitFailure: false)
    }

    /// Completes a scripted/headless interactive stroke and does not resume
    /// until the actor-owned preparation workspace is truly reusable. The
    /// regular pointer path remains request-driven and never awaits here.
    public func completePendingInteractiveStrokeAndAwaitIdle() async throws
        -> GPUFrameMetrics
    {
        guard let mailbox = strokePreparationBridge?.mailbox else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let progressRegistration =
            StrokePreparationAsyncProgressRegistration(mailbox: mailbox)
        defer { progressRegistration.remove() }

        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        do {
            var frames: [GPUFrameMetrics] = []
            while true {
                let observedRevision = progressRegistration.currentRevision
                try drainCompletedInteractiveOperationsCore()
                try prepareCompiledCommitIfReadyCore()
                if activeStroke == nil { break }
                if activeStroke?.pendingRevisions != nil {
                    break
                }
                if pendingPreparedSurfaceFrame != nil {
                    frames.append(
                        try completeNextPendingInteractiveFrameCore()
                    )
                    continue
                }
                if progressRegistration.currentRevision
                    != observedRevision
                {
                    continue
                }
                guard try await progressRegistration.waitForProgress(
                    after: observedRevision
                ) else {
                    throw MetalRendererError.commandFailed(
                        "stroke commit preparation exceeded its async bound"
                    )
                }
            }
            if activeStroke != nil {
                try prepareCompiledCommitIfReadyCore()
                frames.append(try submitPendingInteractiveCommitCore())
            }
            try drainCompletedInteractiveOperationsCore()

            while true {
                if isIdle { break }
                let observedRevision = progressRegistration.currentRevision
                try drainCompletedInteractiveOperationsCore()
                if isIdle { break }
                if progressRegistration.currentRevision
                    != observedRevision
                {
                    continue
                }
                guard try await progressRegistration.waitForProgress(
                    after: observedRevision
                ) else {
                    throw MetalRendererError.commandFailed(
                        "stroke workspace retirement exceeded its async bound"
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
                eventToSubmitNanoseconds: frames.map(
                    \.eventToSubmitNanoseconds
                ).max() ?? 0,
                gpuCompletionNanoseconds: frames.reduce(0) {
                    Self.saturatingAdd(
                        $0,
                        $1.gpuCompletionNanoseconds
                    )
                },
                encodedDabCount: frames.reduce(0) {
                    $0 + $1.encodedDabCount
                },
                encodedInstanceCount: frames.reduce(0) {
                    $0 + $1.encodedInstanceCount
                },
                bufferLeaseCount: frames.map(
                    \.bufferLeaseCount
                ).max() ?? 0
            )
        } catch let published as PreviouslyPublishedInteractiveFailure {
            throw published.error
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

    /// Awaits only an already-requested actor workspace retirement. This is
    /// useful for async workflows that cancel a transient stroke and must
    /// subsequently capture state or begin another scripted operation.
    public func awaitPendingStrokeWorkspaceRetirement() async throws {
        if isIdle { return }
        guard case let .retiring(retiringGeneration) = strokeWorkspaceState,
              let mailbox = strokePreparationBridge?.mailbox
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let progressRegistration =
            StrokePreparationAsyncProgressRegistration(mailbox: mailbox)
        defer { progressRegistration.remove() }

        while true {
            let observedRevision = progressRegistration.currentRevision
            try drainCompletedInteractiveOperations()
            if strokeWorkspaceState != .retiring(retiringGeneration) {
                return
            }
            if progressRegistration.currentRevision != observedRevision {
                continue
            }
            guard try await progressRegistration.waitForProgress(
                after: observedRevision
            ) else {
                throw MetalRendererError.commandFailed(
                    "stroke workspace retirement exceeded its async bound"
                )
            }
        }
    }

    func completePendingInteractiveStroke(
        forceCommitFailure: Bool
    ) throws -> GPUFrameMetrics {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        do {
            var frames: [GPUFrameMetrics] = []
            let maximumFrameAttempts = strokePreparationBridge == nil
                ? 64
                : 20_000
            for _ in 0..<maximumFrameAttempts {
                try drainCompletedInteractiveOperationsCore()
                try prepareCompiledCommitIfReadyCore()
                if activeStroke == nil { break }
                if activeStroke?.pendingRevisions != nil {
                    break
                }
                if strokePreparationBridge != nil,
                   pendingPreparedSurfaceFrame == nil
                {
                    // This synchronous API is a capture/test drain. Give the
                    // independent preparation executor a scheduling window
                    // instead of submitting empty GPU frames in a hot loop.
                    Thread.sleep(forTimeInterval: 0.000_01)
                    continue
                }
                frames.append(
                    try completeNextPendingInteractiveFrameCore()
                )
            }
            if activeStroke != nil {
                try prepareCompiledCommitIfReadyCore()
                frames.append(
                    try submitPendingInteractiveCommitCore(
                        forceFailure: forceCommitFailure
                    )
                )
            }
            try drainCompletedInteractiveOperationsCore()
            return GPUFrameMetrics(
                cpuEncodeMilliseconds: frames.reduce(0) {
                    $0 + $1.cpuEncodeMilliseconds
                },
                gpuMilliseconds: frames.reduce(0) {
                    $0 + $1.gpuMilliseconds
                },
                eventToSubmitNanoseconds: frames.map(
                    \.eventToSubmitNanoseconds
                ).max() ?? 0,
                gpuCompletionNanoseconds: frames.reduce(0) {
                    Self.saturatingAdd(
                        $0,
                        $1.gpuCompletionNanoseconds
                    )
                },
                encodedDabCount: frames.reduce(0) {
                    $0 + $1.encodedDabCount
                },
                encodedInstanceCount: frames.reduce(0) {
                    $0 + $1.encodedInstanceCount
                },
                bufferLeaseCount: frames.map(
                    \.bufferLeaseCount
                ).max() ?? 0
            )
        } catch let published as PreviouslyPublishedInteractiveFailure {
            throw published.error
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

    func completeNextPendingInteractiveFrame(
        forceFailure: Bool = false,
        forceCommandBufferUnavailable: Bool = false,
        forcePostSurfaceEncodingFailure: Bool = false
    ) throws -> GPUFrameMetrics {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        do {
            return try completeNextPendingInteractiveFrameCore(
                forceFailure: forceFailure,
                forceCommandBufferUnavailable:
                    forceCommandBufferUnavailable,
                forcePostSurfaceEncodingFailure:
                    forcePostSurfaceEncodingFailure
            )
        } catch let published as PreviouslyPublishedInteractiveFailure {
            throw published.error
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

    private func completeNextPendingInteractiveFrameCore(
        forceFailure: Bool = false,
        forceCommandBufferUnavailable: Bool = false,
        forcePostSurfaceEncodingFailure: Bool = false
    ) throws -> GPUFrameMetrics {
        if let submittedError = drainFrameOutcomes() {
            throw PreviouslyPublishedInteractiveFailure(
                error: submittedError
            )
        }
        drainCompletedUploadRanges()
        try drainStrokePreparationResultsCore()
        guard !forceCommandBufferUnavailable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            throw MetalRendererError.commandBufferUnavailable
        }

        let uploads: [FrameUpload] = []
        var nativeEncoding: NativeDepositionFrameEncoding?
        var submissions: [DabBufferSubmissionIdentity] = []
        var didFinalize = false
        let runtimePrepareStarted = DispatchTime.now().uptimeNanoseconds
        let runtimeFrameID = beginStrokeRuntimeFrame(
            at: runtimePrepareStarted,
            targetFrameDurationNanoseconds: 16_666_667
        )
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let encoding = try encodeScheduledDeposition(commandBuffer)
            nativeEncoding = encoding
            if forcePostSurfaceEncodingFailure,
               encoding.preparedWorkerFrame != nil
            {
                throw MetalRendererError.commandFailed(
                    "injected post-surface encoding failure"
                )
            }
            recordStrokeRuntimePreparedFrame(
                id: runtimeFrameID,
                encoding: encoding
            )
            submissions = try finalizeFrameEncoding(
                encodedClear: encoding.encodedLiveClear,
                encodedReplayClear: encoding.encodedReplayClear,
                uploads: uploads,
                nativeEncoding: encoding,
                rasterCommit: nil,
                commandBuffer: commandBuffer,
                forceFailure: forceFailure
            )
            didFinalize = true
            if activeStroke != nil {
                counters.renderedFramesThisStroke += 1
            }
            let submittedAtNanoseconds =
                DispatchTime.now().uptimeNanoseconds
            recordStrokeRuntimeSubmittedFrame(
                id: runtimeFrameID,
                at: submittedAtNanoseconds
            )
            commandBuffer.commit()
            let cpuMilliseconds = elapsedMilliseconds(since: start)
            commandBuffer.waitUntilCompleted()
            let completedAtNanoseconds =
                DispatchTime.now().uptimeNanoseconds
            let submittedError = drainFrameOutcomes()
            drainCompletedUploadRanges()
            if let submittedError {
                throw PreviouslyPublishedInteractiveFailure(
                    error: submittedError
                )
            }
            do {
                try validateCompletedCommand(commandBuffer)
            } catch {
                instancePool.reclaimTerminalFailure(submissions)
                throw error
            }
            let frameMetrics = metrics(
                commandBuffer: commandBuffer,
                cpuMilliseconds: cpuMilliseconds,
                submittedAtNanoseconds: submittedAtNanoseconds,
                completedAtNanoseconds: completedAtNanoseconds,
                nativeEncoding: nativeEncoding
            )
            recordBrushLabCompletedFrame(frameMetrics)
            recordStrokeRuntimeCompletedFrame(
                id: runtimeFrameID,
                commandBuffer: commandBuffer,
                submittedAt: submittedAtNanoseconds,
                completedAt: completedAtNanoseconds
            )
            return frameMetrics
        } catch {
            if let runtimeFrameID {
                discardStrokeRuntimeFrame(runtimeFrameID)
            }
            if !didFinalize {
                if nativeEncoding != nil,
                   commandBuffer.status == .notEnqueued
                {
                    installPreparedSurfaceTerminalHandler(
                        for: nativeEncoding,
                        on: commandBuffer
                    )
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                }
                abandon(uploads)
                _ = drainFrameOutcomes()
            }
            throw error
        }
    }

    func submitPendingInteractiveCommit(
        forceFailure: Bool = false
    ) throws -> GPUFrameMetrics {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        do {
            return try submitPendingInteractiveCommitCore(
                forceFailure: forceFailure
            )
        } catch let published as PreviouslyPublishedInteractiveFailure {
            throw published.error
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

    private func submitPendingInteractiveCommitCore(
        forceFailure: Bool = false
    ) throws -> GPUFrameMetrics {
        if let submittedError = drainFrameOutcomes() {
            throw PreviouslyPublishedInteractiveFailure(
                error: submittedError
            )
        }
        drainCompletedUploadRanges()
        try prepareCompiledCommitIfReadyCore()
        let nativeIsReady =
            if let scheduler = activeStroke?.frozenHarnessScheduler {
                scheduler.authoritativeIsDrained
                    && scheduler.predictedCount == 0
                    && !needsReplayClear
            } else {
                strokePreparationBridge != nil
                    && pendingPreparedWorkerFrame == nil
                    && pendingPreparedSurfaceFrame == nil
                    && submittedPreparedWorkerFrame == nil
                    && !needsReplayClear
            }
        guard activeStroke?.commitRequested == true,
              activeStroke?.pendingTokenBearingFrameCount == 0,
              activeStroke?.pendingRevisions != nil,
              nativeIsReady
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }

        let runtimePrepareStarted = DispatchTime.now().uptimeNanoseconds
        let runtimeFrameID = beginStrokeRuntimeFrame(
            at: runtimePrepareStarted,
            targetFrameDurationNanoseconds: 16_666_667
        )
        let start = CFAbsoluteTimeGetCurrent()
        let rasterCommit = try encodeCommit(
            commandBuffer,
            liveVisible: compositeLiveIsVisible
        )
        _ = try finalizeFrameEncoding(
            encodedClear: false,
            uploads: [],
            rasterCommit: rasterCommit,
            commandBuffer: commandBuffer,
            forceFailure: forceFailure
        )
        recordStrokeRuntimePreparedFrame(
            id: runtimeFrameID,
            encoding: nil
        )
        counters.renderedFramesThisStroke += 1
        let cpuMilliseconds = elapsedMilliseconds(since: start)
        let submittedAtNanoseconds =
            DispatchTime.now().uptimeNanoseconds
        recordStrokeRuntimeSubmittedFrame(
            id: runtimeFrameID,
            at: submittedAtNanoseconds
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let completedAtNanoseconds =
            DispatchTime.now().uptimeNanoseconds
        if commandBuffer.status == .completed, !forceFailure {
            recordStrokeRuntimeCompletedFrame(
                id: runtimeFrameID,
                commandBuffer: commandBuffer,
                submittedAt: submittedAtNanoseconds,
                completedAt: completedAtNanoseconds
            )
        }
        let submittedError = drainFrameOutcomes()
        drainCompletedUploadRanges()
        if let submittedError {
            throw PreviouslyPublishedInteractiveFailure(
                error: submittedError
            )
        }
        try validateCompletedCommand(commandBuffer)
        let frameMetrics = metrics(
            commandBuffer: commandBuffer,
            cpuMilliseconds: cpuMilliseconds,
            submittedAtNanoseconds: submittedAtNanoseconds,
            completedAtNanoseconds: completedAtNanoseconds
        )
        recordBrushLabCompletedFrame(frameMetrics)
        return frameMetrics
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
        } catch let published as PreviouslyPublishedInteractiveFailure {
            throw published.error
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
        let submittedError = drainFrameOutcomes()
        drainCompletedUploadRanges()
        try drainStrokePreparationResultsCore()
        if let submittedError {
            throw PreviouslyPublishedInteractiveFailure(
                error: submittedError
            )
        }
    }

    private func drainStrokePreparationResultsCore() throws {
        guard let bridge = strokePreparationBridge else { return }
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
                case .commitBarrierReached:
                    guard let maximumRetainedBytes =
                        pendingPreparationCommitRetainedBytes
                    else {
                        throw MetalRendererError.invalidStrokeLifecycle
                    }
                    pendingPreparationCommitRetainedBytes = nil
                    try markOffMainStrokeCommitReady(
                        maximumRetainedBytes: maximumRetainedBytes
                    )
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
                        finishStrokeWorkspaceRetirement(
                            generation: generation
                        )
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
              pendingPreparedWorkerFrame == nil,
              pendingPreparedSurfaceFrame == nil,
              submittedPreparedWorkerFrame == nil,
              activeStroke != nil
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let totalInstanceCount = batch.authoritativeInstanceCount
            + batch.predictedInstanceCount
        lastOffMainSurfaceSnapshot = batch.surfaceSnapshot
        lastOffMainPredictedInstanceCount = batch.predictedInstanceCount
        var replayEpoch: UInt64 = 0
        if let predictionAdmission = batch.predictionAdmission {
            replayEpoch = takeReplayEpoch()
            predictionOverlay.planReplacementInPlace(
                epoch: replayEpoch,
                provenance: batch.predictionProvenanceBoundary,
                admission: predictionAdmission,
                dirtyRegions: batch.dirtyRegions
            )
            replayStroke.beginReplacementEpoch(replayEpoch)
            for region in batch.dirtyRegions {
                replayStroke.recordDirtyRegion(region)
            }
            needsReplayClear = true
        } else {
            for region in batch.dirtyRegions {
                liveStroke.recordDirtyRegion(region)
            }
        }

        if let surfaceLease = batch.surfaceLease {
            lastOffMainEncodingRanOnMainThread =
                surfaceLease.encodingRanOnMainThread
            if surfaceLease.clearedPredictionSurface,
               batch.predictionAdmission == nil
            {
                replayEpoch = takeReplayEpoch()
                predictionOverlay.discard(epoch: replayEpoch)
                replayStroke.beginReplacementEpoch(replayEpoch)
                needsReplayClear = true
            }
            currentPreparedSurfaceLease = surfaceLease
            guard batch.frameToken == surfaceLease.token else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            let identity = PreparedWorkerFrameIdentity(
                generation: batch.generation,
                token: surfaceLease.token,
                recordCount: totalInstanceCount
            )
            pendingPreparedWorkerFrame = identity
            pendingPreparedSurfaceFrame = PendingPreparedSurfaceFrame(
                identity: identity,
                lease: surfaceLease,
                logicalDabCount: batch.logicalDabs.count,
                replayEpoch: replayEpoch
            )
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

        let (scheduledHighWater, overflow) =
            scheduledAuthoritativeIdentityHighWater
                .addingReportingOverflow(
                    UInt64(batch.authoritativeInstanceCount)
                )
        guard !overflow else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                depositionFrameBudget.maximumPendingAuthoritativeInstances
            )
        }
        scheduledAuthoritativeIdentityHighWater = scheduledHighWater
        counters.newDabsThisEvent = batch.logicalDabs.count
        counters.totalDabsThisStroke += batch.logicalDabs.count
        counters.totalInstancesThisStroke += totalInstanceCount
        deferLogicalDabsForPublication(batch.logicalDabs)
        lastOffMainCoordinatorSnapshot = batch.coordinatorSnapshot
        lastOffMainPredictionProvenanceBoundary =
            batch.predictionProvenanceBoundary
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

    private func acknowledgeSubmittedPreparationFrame(
        _ frame: PreparedWorkerFrameIdentity?
    ) throws {
        guard let frame else { return }
        guard pendingPreparedWorkerFrame == frame,
              let bridge = strokePreparationBridge
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        try bridge.acknowledgePreparedFrame(
            generation: frame.generation,
            token: frame.token
        )
        // Ack transfers the textures back to the actor. They must stop being
        // readable on Main before the actor is allowed to mutate them again.
        currentPreparedSurfaceLease = nil
        pendingPreparedWorkerFrame = nil
        pendingPreparedSurfaceFrame = nil
        submittedPreparedWorkerFrame = nil
    }

    public func completePendingRasterOperation() throws {
        guard let operation = pendingRasterOperation else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        operation.commandBuffer.waitUntilCompleted()
        if let error = drainRasterOperationOutcomes() {
            throw error
        }
    }

    public func draw(in view: MTKView) {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
            requestAnotherInteractiveFrameIfNeeded(in: view)
        }
        _ = drainRasterOperationOutcomes()
        if drainFrameOutcomes() != nil { return }
        drainCompletedUploadRanges()

        do {
            try drainStrokePreparationResultsCore()
            try prepareCompiledCommitIfReadyCore()
        } catch let published as PreviouslyPublishedInteractiveFailure {
            _ = published
            return
        } catch let error as MetalRendererError {
            failActiveOperationIfNeeded(error)
            return
        } catch {
            failActiveOperationIfNeeded(
                .commandFailed(error.localizedDescription)
            )
            return
        }

        // One Main composite owns the borrowed actor surface at a time. Its
        // completion outcome returns the lease before another actor mutation
        // or another reader submission can proceed.
        guard submittedPreparedWorkerFrame == nil else { return }
        guard let drawable = view.currentDrawable else {
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            failActiveOperationIfNeeded(.commandBufferUnavailable)
            return
        }
        let targetFramesPerSecond = max(1, view.preferredFramesPerSecond)
        let runtimeFrameID = beginStrokeRuntimeFrame(
            at: DispatchTime.now().uptimeNanoseconds,
            targetFrameDurationNanoseconds:
                UInt64(1_000_000_000 / targetFramesPerSecond)
        )
        #if DEBUG
        let cpuEncodeStart = CFAbsoluteTimeGetCurrent()
        #endif

        let uploads: [FrameUpload] = []
        var nativeEncoding: NativeDepositionFrameEncoding?
        var rasterCommit: EncodedRasterCommit?
        do {
            let hasEarlierPendingUploads = !completedUploadRanges.isEmpty
            let encodedLiveClear: Bool
            let encodedReplayClear: Bool
            if activeStroke != nil {
                let encoding = try encodeScheduledDeposition(commandBuffer)
                nativeEncoding = encoding
                encodedLiveClear = encoding.encodedLiveClear
                encodedReplayClear = encoding.encodedReplayClear
            } else {
                nativeEncoding = nil
                encodedLiveClear = false
                encodedReplayClear = false
            }
            let plannedSettledThrough = uploads.last {
                $0.layer == .settled
            }?.throughExclusive ?? liveStroke.bakedHighWater
            let plannedReplayThrough = uploads.last {
                $0.layer == .replay
            }?.throughExclusive ?? replayStroke.bakedHighWater
            let shouldEncodeCommit = activeStroke?.commitRequested == true
                && activeStroke?.pendingRevisions != nil
                && plannedSettledThrough == liveStroke.emittedHighWater
                && plannedReplayThrough == replayStroke.emittedHighWater
                && !hasEarlierPendingUploads
                && activeStroke?.pendingTokenBearingFrameCount == 0
            let hasCurrentNativeDeposition =
                (nativeEncoding?.instanceCount ?? 0) > 0
            if shouldEncodeCommit {
                rasterCommit = try encodeCommit(
                    commandBuffer,
                    liveVisible: compositeLiveIsVisible
                        || !uploads.isEmpty
                        || hasCurrentNativeDeposition
                )
            }
            try encodeDisplay(
                into: drawable.texture,
                commandBuffer: commandBuffer,
                showGridLines: interactiveGridVisibility,
                liveVisible: compositeLiveIsVisible
                    || !uploads.isEmpty
                    || hasCurrentNativeDeposition
            )
            _ = try finalizeFrameEncoding(
                encodedClear: encodedLiveClear,
                encodedReplayClear: encodedReplayClear,
                uploads: uploads,
                nativeEncoding: nativeEncoding,
                rasterCommit: rasterCommit,
                commandBuffer: commandBuffer
            )
            recordStrokeRuntimePreparedFrame(
                id: runtimeFrameID,
                encoding: nativeEncoding
            )
            let submittedAtNanoseconds =
                DispatchTime.now().uptimeNanoseconds
            recordStrokeRuntimeSubmittedFrame(
                id: runtimeFrameID,
                at: submittedAtNanoseconds
            )
            if runtimeFrameID != nil {
                commandBuffer.addCompletedHandler { [weak self] completedBuffer in
                    guard completedBuffer.status == .completed else { return }
                    #if targetEnvironment(simulator)
                    let completedAtNanoseconds =
                        DispatchTime.now().uptimeNanoseconds
                    #endif
                    let gpuStarted = Self.nanoseconds(
                        completedBuffer.gpuStartTime
                    )
                    let gpuFinished = Self.nanoseconds(
                        completedBuffer.gpuEndTime
                    )
                    Task { @MainActor [weak self] in
                        #if targetEnvironment(simulator)
                        self?.recordStrokeRuntimeCompletedFrame(
                            id: runtimeFrameID,
                            measuredGPUStart: gpuStarted,
                            measuredGPUEnd: gpuFinished,
                            submittedAt: submittedAtNanoseconds,
                            completedAt: completedAtNanoseconds
                        )
                        #else
                        self?.recordStrokeRuntimeGPUFrame(
                            id: runtimeFrameID,
                            measuredStart: gpuStarted,
                            measuredFinish: gpuFinished,
                            submittedAt: submittedAtNanoseconds
                        )
                        #endif
                    }
                }
                #if !targetEnvironment(simulator)
                drawable.addPresentedHandler { [weak self] presentedDrawable in
                    let measured = Self.nanoseconds(
                        presentedDrawable.presentedTime
                    )
                    let presentedAt = measured > 0
                        ? measured
                        : DispatchTime.now().uptimeNanoseconds
                    Task { @MainActor [weak self] in
                        self?.recordStrokeRuntimePresentedFrame(
                            id: runtimeFrameID,
                            at: presentedAt
                        )
                    }
                }
                #endif
            }
            #if DEBUG
            let cpuEncodeMilliseconds = elapsedMilliseconds(
                since: cpuEncodeStart
            )
            let eventToSubmitNanoseconds =
                takeBrushLabEventToSubmitNanoseconds(
                    submittedAt: submittedAtNanoseconds
                )
            let encodedDabCount =
                nativeEncoding?.logicalDabCount ?? 0
            let encodedInstanceCount =
                nativeEncoding?.instanceCount ?? 0
            let bufferLeaseCount =
                nativeEncoding?.uploadBufferCount ?? 0
            commandBuffer.addCompletedHandler { [weak self] completedBuffer in
                guard completedBuffer.status == .completed else { return }
                let completedAtNanoseconds =
                    DispatchTime.now().uptimeNanoseconds
                let frameMetrics = GPUFrameMetrics(
                    cpuEncodeMilliseconds: cpuEncodeMilliseconds,
                    gpuMilliseconds: max(
                        0,
                        (
                            completedBuffer.gpuEndTime
                                - completedBuffer.gpuStartTime
                        ) * 1_000
                    ),
                    eventToSubmitNanoseconds:
                        eventToSubmitNanoseconds,
                    gpuCompletionNanoseconds:
                        completedAtNanoseconds >= submittedAtNanoseconds
                            ? completedAtNanoseconds
                                - submittedAtNanoseconds
                            : 0,
                    encodedDabCount: encodedDabCount,
                    encodedInstanceCount: encodedInstanceCount,
                    bufferLeaseCount: bufferLeaseCount
                )
                Task { @MainActor [weak self] in
                    self?.recordBrushLabCompletedFrame(frameMetrics)
                    self?.stageRendererEvent(
                        .interactiveFrameMetrics(frameMetrics)
                    )
                }
            }
            let fallbackPresentationTimestamp =
                ProcessInfo.processInfo.systemUptime
            #if os(macOS)
            drawable.addPresentedHandler { [weak self] presentedDrawable in
                let timestamp = Self.interactivePresentationTimestamp(
                    presentedTime: presentedDrawable.presentedTime,
                    fallback: fallbackPresentationTimestamp
                )
                Task { @MainActor [weak self] in
                    self?.stageRendererEvent(
                        .interactiveFramePresented(
                            timestamp,
                            targetFramesPerSecond
                        )
                    )
                }
            }
            #else
            stageRendererEvent(
                .interactiveFramePresented(
                    fallbackPresentationTimestamp,
                    targetFramesPerSecond
                )
            )
            #endif
            #endif
            commandBuffer.present(drawable)
            if activeStroke != nil {
                counters.renderedFramesThisStroke += 1
            }
            commandBuffer.commit()
        } catch let error as MetalRendererError {
            if let runtimeFrameID {
                discardStrokeRuntimeFrame(runtimeFrameID)
            }
            if nativeEncoding != nil,
               commandBuffer.status == .notEnqueued
            {
                installPreparedSurfaceTerminalHandler(
                    for: nativeEncoding,
                    on: commandBuffer
                )
                commandBuffer.commit()
            }
            abandon(uploads)
            abandon(rasterCommit)
            failActiveOperationIfNeeded(error)
        } catch {
            if let runtimeFrameID {
                discardStrokeRuntimeFrame(runtimeFrameID)
            }
            if nativeEncoding != nil,
               commandBuffer.status == .notEnqueued
            {
                installPreparedSurfaceTerminalHandler(
                    for: nativeEncoding,
                    on: commandBuffer
                )
                commandBuffer.commit()
            }
            abandon(uploads)
            abandon(rasterCommit)
            failActiveOperationIfNeeded(
                .commandFailed(error.localizedDescription)
            )
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

    private func requestAnotherInteractiveFrameIfNeeded(in view: MTKView) {
        #if DEBUG
        let isHUDSamplePending = onInteractiveFramePresented != nil
            || onInteractiveFrameMetrics != nil
        #else
        let isHUDSamplePending = false
        #endif
        guard Self.interactiveFrameDemand(
            hasActiveStroke: activeStroke != nil
                || strokeWorkspaceState != .available,
            isViewportAnimating: false,
            hasPendingComposite: pendingRasterOperation != nil,
            isHUDSamplePending: isHUDSamplePending
        ) else {
            return
        }
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
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


    private func ingestGeneratedSample(
        _ sample: WorldStrokeSample,
        dabs dabRange: Range<Int>,
        generatorSnapshot: BrushStrokeGenerator,
        inputDeriverBeforeSample: BrushInputDeriver,
        isFinishing: Bool,
        predictionInvalidationBoundary:
            PredictionProvenanceBoundary? = nil
    ) throws {
        guard transientStrokeBuffer != nil,
              let strokeExecution = activeStroke
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        if let predictionInvalidationBoundary {
            precondition(
                predictionOverlay.canInvalidatePrediction(
                    from: predictionInvalidationBoundary
                ),
                "Prediction provenance changed after authoritative preflight."
            )
        }
        let dabs = depositionInputScratch.preparedDabs[dabRange]
        let arenaTransaction = try transientDabArena.beginTransaction(
            replacingPrediction: sample.kind == .predicted
        )
        defer { arenaTransaction.rollback() }
        let transientDabs = try transientDabSlice(
            for: dabRange,
            predicted: sample.kind == .predicted,
            transaction: arenaTransaction
        )
        let chunk = TransientStrokeChunk(
            sample: sample,
            dabs: transientDabs,
            generatorSnapshotAfterSample: generatorSnapshot,
            inputDeriverSnapshotBeforeSample: inputDeriverBeforeSample
        )

        if sample.kind == .predicted {
            depositionInputScratch.transientChunks.removeAll(
                keepingCapacity: true
            )
            depositionInputScratch.transientChunks.append(chunk)
            depositionInputScratch.settledChunks.removeAll(
                keepingCapacity: true
            )
            let replayProjectedInstanceCount =
                try transientStrokeBuffer!.previewPredictedReplacement(
                    with: depositionInputScratch.transientChunks,
                    settledInto: &depositionInputScratch.settledChunks
                )
            try preflightStrokeMutation(
                settledChunks: depositionInputScratch.settledChunks,
                replayProjectedInstanceCount:
                    replayProjectedInstanceCount
            )
            _ = try transientStrokeBuffer!.replacePredicted(
                with: depositionInputScratch.transientChunks,
                settledInto: &depositionInputScratch.settledChunks
            )
            try appendSettled(depositionInputScratch.settledChunks)
            try rebuildReplayLayer(
                preparedPredictedSingle: dabRange
            )
            try arenaTransaction.commit(
                retainingActual: transientStrokeBuffer!.actualChunks,
                retainingPredicted: transientStrokeBuffer!.predictedChunks
            )
            counters.newDabsThisEvent += dabs.count
            counters.totalDabsThisStroke += dabs.count
            deferLogicalDabsForPublication(dabs.lazy.map(\.attributes))
            return
        }

        depositionInputScratch.settledChunks.removeAll(
            keepingCapacity: true
        )
        let replayProjectedInstanceCount =
            transientStrokeBuffer!.previewActualAppend(
                chunk,
                settledInto: &depositionInputScratch.settledChunks
            )
        if isFinishing {
            let correction = transientStrokeBuffer!
                .terminationCorrection(
                    appending: chunk,
                    settledPrefixCount:
                        depositionInputScratch.settledChunks.count
                )
            _ = try BrushTerminationEvaluator(
                program: strokeExecution.style.program.termination
            ).evaluate(correction)
        }
        try preflightStrokeMutation(
            settledChunks: depositionInputScratch.settledChunks,
            replayProjectedInstanceCount: replayProjectedInstanceCount
        )
        let update = transientStrokeBuffer!.appendActual(
            chunk,
            settledInto: &depositionInputScratch.settledChunks
        )
        if case let .unresolvedSuffixExceedsCapacity(
            sampleCount,
            dabCount,
            projectedInstanceCount
        ) = update.rejection {
            let limits = transientStrokeBuffer!.activeReplayLimits
            if sampleCount > limits.maximumSamples {
                throw MetalRendererError.strokeSampleCapacityExceeded(
                    limits.maximumSamples
                )
            }
            if dabCount > limits.maximumDabs {
                throw MetalRendererError.generatedDabCapacityExceeded(
                    limits.maximumDabs
                )
            }
            if projectedInstanceCount > limits.maximumProjectedInstances {
                throw MetalRendererError.projectedInstanceCapacityExceeded(
                    limits.maximumProjectedInstances
                )
            }
            preconditionFailure(
                "Rejected unresolved suffix must exceed an active limit"
            )
        }
        precondition(
            update.rejection == nil,
            "Renderer must handle every transient buffer rejection"
        )
        if update.clearedPredictedSuffix {
            _ = activeStroke?.frozenHarnessScheduler?
                .discardTruePrediction()
        }
        let buffer = transientStrokeBuffer!
        if buffer.mode == .appendOnly,
           depositionInputScratch.settledChunks.count == 1,
           depositionInputScratch.settledChunks[0].dabs
               == transientDabs
        {
            let capacityBefore =
                depositionInputScratch.flattenedProjected.capacity
            depositionInputScratch.flattenedProjected.removeAll(
                keepingCapacity: true
            )
            precondition(
                depositionInputScratch.flattenedProjected.capacity
                    >= dabs.reduce(0) {
                        $0 + $1.projectedRange.count
                    },
                "Projection scratch must be reserved before interactive input."
            )
            for dab in dabs {
                depositionInputScratch.flattenedProjected.append(
                    contentsOf:
                        depositionInputScratch.projectedArena[
                            dab.projectedRange
                        ]
                )
            }
            recordScratchAllocationIfNeeded(
                capacityBefore: capacityBefore,
                capacityAfter:
                    depositionInputScratch.flattenedProjected.capacity
            )
            try appendSettledRecords(
                depositionInputScratch.flattenedProjected
            )
        } else {
            try appendSettled(
                depositionInputScratch.settledChunks
            )
        }

        if isFinishing,
           case .legacySchemaV1EndTaper =
               activeStroke?.style.program.termination
        {
            knownStrokeTotalDistance = max(
                dabs.last?.attributes.sourceDistance ?? 0,
                buffer.actualChunks.last?.dabs.last?
                    .attributes.sourceDistance ?? 0
            )
        }
        if buffer.mode != .appendOnly
            || update.requiresReplayReplacement
            || !buffer.predictedChunks.isEmpty
        {
            if buffer.mode == .appendOnly || isFinishing {
                try rebuildReplayLayer(
                    predictionInvalidationBoundary:
                        predictionInvalidationBoundary
                )
            } else {
                try rebuildReplayLayer(
                    preparedActualSingle: dabRange,
                    predictionInvalidationBoundary:
                        predictionInvalidationBoundary
                )
            }
        }
        try arenaTransaction.commit(
            retainingActual: transientStrokeBuffer!.actualChunks,
            retainingPredicted: transientStrokeBuffer!.predictedChunks
        )
        counters.newDabsThisEvent += dabs.count
        counters.totalDabsThisStroke += dabs.count
        deferLogicalDabsForPublication(dabs.lazy.map(\.attributes))
    }

    package func setStrokePreparationAllocationProbeForHarness(
        _ probe: StrokePreparationAllocationProbe?
    ) {
        precondition(isIdle)
        strokePreparationAllocationProbe = probe
    }

    package func advanceStrokePreparationForAllocationHarness() throws {
        try drainCompletedInteractiveOperations()
        if pendingPreparedSurfaceFrame != nil {
            _ = try completeNextPendingInteractiveFrame()
        }
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

    package var hasPendingPreparedStrokeSurfaceForHarness: Bool {
        pendingPreparedSurfaceFrame != nil
    }

    package var strokePreparationIsQuiescentForAllocationHarness: Bool {
        guard let snapshot = strokePreparationBridge?.mailbox.snapshot else {
            return true
        }
        return snapshot.isQuiescent
            && pendingPreparedSurfaceFrame == nil
            && submittedPreparedWorkerFrame == nil
    }

    package var offMainStrokeWorkspaceIdentityForTesting: UUID {
        strokeMetalSurfaceResources.identity
    }

    package var offMainStrokeWorkspacePixelSizeForTesting: PixelSize {
        strokeMetalSurfaceResources.pixelSize
    }

    package var offMainStrokeWorkspaceInstallationCountForTesting: UInt64 {
        strokeMetalSurfaceInstallationCount
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

    var compatibilityInkCoordinatorSnapshotForTesting:
        StrokeRenderSnapshot?
    {
        lastOffMainCoordinatorSnapshot
    }

    var compatibilityInkEncodingRanOnMainThreadForTesting: Bool? {
        lastOffMainEncodingRanOnMainThread
    }

    var hasPendingOffMainSurfaceLeaseForTesting: Bool {
        pendingPreparedSurfaceFrame != nil
    }

    var hasSubmittedOffMainSurfaceLeaseForTesting: Bool {
        submittedPreparedWorkerFrame != nil
    }

    var hasCurrentOffMainSurfaceLeaseForTesting: Bool {
        currentPreparedSurfaceLease != nil
    }

    var hasPendingRasterOperationForTesting: Bool {
        pendingRasterOperation != nil
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
        let generation: UInt64 = 600_000
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
        let initialWorkspaceIdentity = strokeMetalSurfaceResources.identity
        let initialWorkspaceInstallationCount =
            strokeMetalSurfaceInstallationCount
        let configuration = StrokePreparationConfiguration(
            program: compiledBrush.program,
            nominalDiameter: 12,
            color: .black,
            seed: 7,
            viewport: viewport,
            tilingStrategy: tilingStrategy,
            metalResourceDescriptor: StrokeMetalResourceDescriptor(
                surfaces: strokeMetalSurfaceResources,
                brush: brushRenderState,
                frameUniforms: frameUniforms(
                    drawableSize: tileSize,
                    showGridLines: false,
                    liveVisible: true
                ),
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
                strokeMetalSurfaceInstallationCount,
            workspaceIdentityStayedStable:
                strokeMetalSurfaceResources.identity
                    == initialWorkspaceIdentity,
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
            var deferredAcknowledgement: (generation: UInt64, token: UInt64)?
            for result in resultScratch {
                switch result {
                case let .cancelled(cancelledGeneration, _)
                    where cancelledGeneration == generation:
                    return
                case let .prepared(batch):
                    if let lease = batch.surfaceLease {
                        deferredAcknowledgement = (
                            lease.generation,
                            lease.token
                        )
                    } else if let token = batch.frameToken {
                        deferredAcknowledgement = (batch.generation, token)
                    }
                case let .failed(_, failure):
                    throw rendererError(for: failure)
                default:
                    break
                }
            }
            resultScratch.removeAll(keepingCapacity: true)
            if let deferredAcknowledgement {
                try bridge.acknowledgePreparedFrame(
                    generation: deferredAcknowledgement.generation,
                    token: deferredAcknowledgement.token
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
            var deferredAcknowledgement: (generation: UInt64, token: UInt64)?
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
                        guard let commandBuffer = commandQueue
                            .makeCommandBuffer()
                        else {
                            throw MetalRendererError
                                .commandBufferUnavailable
                        }
                        try encodeDisplay(
                            into: compositeTarget,
                            commandBuffer: commandBuffer,
                            showGridLines: false,
                            liveVisible: true,
                            liveTexture: lease.authoritativeTexture,
                            replayTexture: lease.predictionTexture
                        )
                        let commandOutcome = await withCheckedContinuation {
                            continuation in
                            commandBuffer.addCompletedHandler { completed in
                                continuation.resume(
                                    returning:
                                        OffMainStrokeTraceCommandOutcome(
                                            succeeded:
                                                completed.status
                                                    == .completed
                                                    && completed.error == nil,
                                            errorMessage:
                                                completed.error?
                                                    .localizedDescription
                                        )
                                )
                            }
                            commandBuffer.commit()
                        }
                        guard commandOutcome.succeeded else {
                            throw MetalRendererError.commandFailed(
                                commandOutcome.errorMessage
                                    ?? "off-main trace composite failed"
                            )
                        }
                        deferredAcknowledgement = (
                            lease.generation,
                            lease.token
                        )
                    } else if let token = batch.frameToken {
                        zeroWorkLeaseCount += 1
                        deferredAcknowledgement = (batch.generation, token)
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
            if let deferredAcknowledgement {
                try bridge.acknowledgePreparedFrame(
                    generation: deferredAcknowledgement.generation,
                    token: deferredAcknowledgement.token
                )
                watchdog.recordProgress()
            }
            let mailbox = bridge.mailbox.snapshot
            // Replay-tail/whole-stroke brushes legitimately retain consumed
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

    func drainOneRendererEventTurnForHarness() {
        rendererEventDispatcher.drainOnePendingTurnForHarness()
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

    private func deferPreparedLogicalDabsForPublication<Ranges: Collection>(
        _ ranges: Ranges
    ) where Ranges.Element == Range<Int> {
        precondition(
            rendererEventDispatcher.hasOpenOperation,
            "Logical dabs must be recorded inside an input-operation scope"
        )
        guard let generation = strokeEventGeneration else {
            preconditionFailure(
                "Logical dabs require an active stroke event generation"
            )
        }
        for range in ranges {
            for index in range {
                let dab =
                    depositionInputScratch.preparedDabs[index].attributes
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
    }

    private func appendSettled(
        _ chunks: [TransientStrokeChunk]
    ) throws {
        try preflightSettledAppend(chunks)
        let capacityBefore =
            depositionInputScratch.flattenedProjected.capacity
        depositionInputScratch.flattenedProjected.removeAll(
            keepingCapacity: true
        )
        for chunk in chunks {
            for dab in chunk.dabs {
                try appendProjectedRecords(
                    for: dab.attributes,
                    to: &depositionInputScratch.flattenedProjected
                )
            }
        }
        recordScratchAllocationIfNeeded(
            capacityBefore: capacityBefore,
            capacityAfter:
                depositionInputScratch.flattenedProjected.capacity
        )
        try appendSettledRecords(
            depositionInputScratch.flattenedProjected
        )
    }

    private func preflightSettledAppend(
        _ chunks: [TransientStrokeChunk]
    ) throws {
        var projectedCount = 0
        for chunk in chunks {
            let (nextCount, overflow) = projectedCount.addingReportingOverflow(
                chunk.projectedInstanceCount
            )
            guard !overflow else {
                throw MetalRendererError.projectedInstanceCapacityExceeded(
                    liveStroke.capacity
                )
            }
            projectedCount = nextCount
        }
        guard let scheduler = activeStroke?.frozenHarnessScheduler else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let availableCapacity = scheduler.authoritativeAvailableCapacity
        guard projectedCount <= availableCapacity else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                depositionFrameBudget.maximumPendingAuthoritativeInstances
            )
        }
    }

    private func preflightStrokeMutation(
        settledChunks: [TransientStrokeChunk],
        replayProjectedInstanceCount: Int
    ) throws {
        try preflightSettledAppend(settledChunks)
        guard let scheduler = activeStroke?.frozenHarnessScheduler else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard replayProjectedInstanceCount
            <= scheduler.predictedCapacity
        else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                scheduler.predictedCapacity
            )
        }
    }

    private func appendSettledRecords(
        _ records: [ProjectedDabRecord]
    ) throws {
        try enqueueCompiledAuthoritative(records)
    }

    private func enqueueCompiledAuthoritative(
        _ records: [ProjectedDabRecord]
    ) throws {
        guard let scheduler = activeStroke?.frozenHarnessScheduler
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let capacityBefore =
            depositionInputScratch.depositionRecords.capacity
        depositionInputScratch.depositionRecords.removeAll(
            keepingCapacity: true
        )
        precondition(
            depositionInputScratch.depositionRecords.capacity
                >= records.count,
            "Deposition scratch must be reserved before interactive input."
        )
        for record in records {
            depositionInputScratch.depositionRecords.append(
                record.depositionRecord
            )
        }
        recordScratchAllocationIfNeeded(
            capacityBefore: capacityBefore,
            capacityAfter:
                depositionInputScratch.depositionRecords.capacity
        )
        do {
            try scheduler.enqueueAuthoritative(
                depositionInputScratch.depositionRecords
            )
        } catch let error as FrameSchedulerError {
            throw rendererError(for: error)
        }
        let (scheduledHighWater, overflow) =
            scheduledAuthoritativeIdentityHighWater.addingReportingOverflow(
                UInt64(records.count)
            )
        guard !overflow else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                depositionFrameBudget.maximumPendingAuthoritativeInstances
            )
        }
        for record in records {
            liveStroke.recordDirtyRegion(record.dirtyRect)
        }
        counters.totalInstancesThisStroke += records.count
        scheduledAuthoritativeIdentityHighWater = scheduledHighWater
        recordBrushLabScheduler(scheduler)
    }

    private func prepareGeneratedDabs(
        generator: inout BrushStrokeGenerator,
        resetScratch: Bool = true,
        generate: (
            inout BrushStrokeGenerator,
            (DabAttributes) throws -> Void
        ) throws -> Void
    ) throws -> Range<Int> {
        try prepareGeneratedDabs(
            generator: &generator,
            resetScratch: resetScratch,
            predictionLimits: nil,
            generate: generate
        ).range
    }

    private func prepareBoundedPredictedDabs(
        generator: inout BrushStrokeGenerator,
        resetScratch: Bool,
        limits: PredictionGenerationLimits,
        generate: (
            inout BrushStrokeGenerator,
            (DabAttributes) throws -> Void
        ) throws -> Void
    ) throws -> PreparedPredictionDabs {
        precondition(limits.maximumDabCount >= 0)
        precondition(limits.maximumProjectedInstanceCount >= 0)
        return try prepareGeneratedDabs(
            generator: &generator,
            resetScratch: resetScratch,
            predictionLimits: limits,
            generate: generate
        )
    }

    private func prepareGeneratedDabs(
        generator: inout BrushStrokeGenerator,
        resetScratch: Bool,
        predictionLimits: PredictionGenerationLimits?,
        generate: (
            inout BrushStrokeGenerator,
            (DabAttributes) throws -> Void
        ) throws -> Void
    ) throws -> PreparedPredictionDabs {
        let globalMaximumDabs = TransientStrokeBufferContract
            .wholeStrokeDabCapacity
        let globalMaximumProjected = TransientStrokeBufferContract
            .visibleEpochProjectedInstanceCapacity
        let activeLimits = transientStrokeBuffer?.activeReplayLimits
        let isReplayable = transientStrokeBuffer?.mode != .appendOnly
        let maximumDabs = isReplayable
            ? min(
                globalMaximumDabs,
                activeLimits?.maximumDabs ?? globalMaximumDabs
            )
            : globalMaximumDabs
        let maximumProjected = isReplayable
            ? min(
                globalMaximumProjected,
                activeLimits?.maximumProjectedInstances
                    ?? globalMaximumProjected
            )
            : globalMaximumProjected
        let capacityBefore =
            depositionInputScratch.preparedDabs.capacity
        let transientCapacityBefore =
            depositionInputScratch.transientDabs.capacity
        let projectedCapacityBefore =
            depositionInputScratch.projectedArena.capacity
        if resetScratch {
            depositionInputScratch.preparedDabs.removeAll(
                keepingCapacity: true
            )
            depositionInputScratch.transientDabs.removeAll(
                keepingCapacity: true
            )
            depositionInputScratch.preparedChunkRanges.removeAll(
                keepingCapacity: true
            )
            depositionInputScratch.projectedArena.removeAll(
                keepingCapacity: true
            )
        }
        let preparedStart =
            depositionInputScratch.preparedDabs.count
        precondition(
            depositionInputScratch.preparedDabs.capacity
                >= maximumDabs,
            "Generated-dab scratch must be reserved before interactive input."
        )
        var projectedCount = 0
        var overload: PredictionOverloadReasons = []
        do {
            try generate(&generator) { dab in
                let preparedCount = depositionInputScratch
                    .preparedDabs.count - preparedStart
                if let predictionLimits,
                   preparedCount >= predictionLimits.maximumDabCount
                {
                    throw PredictionGenerationLimitReached(
                        reason: .logicalDabs
                    )
                }
                guard depositionInputScratch.preparedDabs.count
                    < maximumDabs
                else {
                    throw MetalRendererError.generatedDabCapacityExceeded(
                        maximumDabs
                    )
                }
                let projectedStart = depositionInputScratch
                    .projectedArena.count
                do {
                    try appendProjectedRecords(
                        for: dab,
                        to: &depositionInputScratch.projectedArena
                    )
                } catch {
                    depositionInputScratch.projectedArena.removeSubrange(
                        projectedStart..<depositionInputScratch
                            .projectedArena.count
                    )
                    throw error
                }
                let projectedRange = projectedStart
                    ..< depositionInputScratch.projectedArena.count
                let (nextCount, overflow) = projectedCount
                    .addingReportingOverflow(projectedRange.count)
                if let predictionLimits,
                   (overflow
                        || nextCount > predictionLimits
                            .maximumProjectedInstanceCount)
                {
                    depositionInputScratch.projectedArena.removeSubrange(
                        projectedRange
                    )
                    throw PredictionGenerationLimitReached(
                        reason: .projectedInstances
                    )
                }
                guard !overflow, nextCount <= maximumProjected else {
                    depositionInputScratch.projectedArena.removeSubrange(
                        projectedRange
                    )
                    throw MetalRendererError
                        .projectedInstanceCapacityExceeded(
                            maximumProjected
                        )
                }
                projectedCount = nextCount
                depositionInputScratch.preparedDabs.append(
                    PreparedGeneratedDab(
                        attributes: dab,
                        projectedRange: projectedRange
                    )
                )
                depositionInputScratch.transientDabs.append(
                    TransientStrokeDab(
                        attributes: dab,
                        projectedInstanceCount: projectedRange.count
                    )
                )
            }
        } catch let limit as PredictionGenerationLimitReached {
            overload.insert(limit.reason)
        }
        recordScratchAllocationIfNeeded(
            capacityBefore: capacityBefore,
            capacityAfter:
                depositionInputScratch.preparedDabs.capacity
        )
        recordScratchAllocationIfNeeded(
            capacityBefore: transientCapacityBefore,
            capacityAfter:
                depositionInputScratch.transientDabs.capacity
        )
        recordScratchAllocationIfNeeded(
            capacityBefore: projectedCapacityBefore,
            capacityAfter:
                depositionInputScratch.projectedArena.capacity
        )
        inputPathStorageAudit.recordGeneratedDabs(
            depositionInputScratch.preparedDabs.capacity
        )
        return PreparedPredictionDabs(
            range: preparedStart
                ..< depositionInputScratch.preparedDabs.count,
            overload: overload
        )
    }

    private func rebuildReplayLayer(
        preparedActualSuffixCount: Int = 0,
        preparedPredictedSuffixCount: Int = 0,
        preparedActualSingle: Range<Int>? = nil,
        preparedPredictedSingle: Range<Int>? = nil,
        predictionProvenance: PredictionProvenanceBoundary? = nil,
        predictionInvalidationBoundary:
            PredictionProvenanceBoundary? = nil,
        predictionOverload: PredictionOverloadReasons = []
    ) throws {
        precondition(
            predictionProvenance == nil
                || predictionInvalidationBoundary == nil
        )
        guard let buffer = transientStrokeBuffer,
              let activeStroke
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let retainedReplayStartDistance = (
            buffer.actualChunks.first { !$0.dabs.isEmpty }?.dabs.first
                ?? buffer.predictedChunks.first { !$0.dabs.isEmpty }?
                    .dabs.first
        )?.attributes.sourceDistance
        let regionCapacityBefore =
            depositionInputScratch.replayDirtyRegions.capacity
        depositionInputScratch.replayDirtyRegions.removeAll(
            keepingCapacity: true
        )
        let replacementCapacityBefore =
            depositionInputScratch.replayRecords.capacity
        depositionInputScratch.replayRecords.removeAll(
            keepingCapacity: true
        )
        precondition(
            depositionInputScratch.replayRecords.capacity
                >= min(
                    buffer.visibleProjectedInstanceCount,
                    TransientStrokeBufferContract
                        .visibleEpochProjectedInstanceCapacity
                ),
            "Replay scratch must be reserved before interactive input."
        )
        func appendReplayChunks(
            _ chunks: [TransientStrokeChunk],
            preparedSuffixCount: Int = 0,
            preparedSingle: Range<Int>? = nil
        ) throws {
            precondition(
                preparedSingle == nil || preparedSuffixCount == 0
            )
            let preparedCount = preparedSingle == nil
                ? preparedSuffixCount
                : 1
            precondition(
                preparedCount <= depositionInputScratch
                    .preparedChunkRanges.count
                    || preparedSingle != nil
            )
            let preparedStart = chunks.count - preparedCount
            precondition(preparedStart >= 0)
            for (index, chunk) in chunks.enumerated() {
                if knownStrokeTotalDistance == nil,
                   index >= preparedStart
                {
                    let preparedRange =
                        preparedSingle
                        ?? depositionInputScratch.preparedChunkRanges[
                            depositionInputScratch
                                .preparedChunkRanges.count
                                - preparedSuffixCount
                                + index - preparedStart
                        ]
                    let prepared =
                        depositionInputScratch.preparedDabs[
                            preparedRange
                        ]
                    precondition(
                        prepared.count == chunk.dabs.count
                            && zip(prepared, chunk.dabs).allSatisfy {
                                $0.transient == $1
                            },
                        "Prepared replay projection diverged from its chunk."
                    )
                    for dab in prepared {
                        depositionInputScratch.replayRecords.append(
                            contentsOf:
                                depositionInputScratch.projectedArena[
                                    dab.projectedRange
                                ]
                        )
                    }
                    continue
                }
                for transientDab in chunk.dabs {
                    let attributes: DabAttributes
                    if let totalDistance = knownStrokeTotalDistance,
                       case .legacySchemaV1EndTaper =
                           activeStroke.style.program.termination
                    {
                        attributes = BrushDynamicsEngine()
                            .applyingLegacySchemaV1EndTaper(
                                transientDab.attributes,
                                totalDistance: totalDistance,
                                nominalDiameter: activeStroke.style.diameter,
                                program: activeStroke.style.program,
                                retainedReplayStartDistance:
                                    retainedReplayStartDistance
                            )
                    } else {
                        attributes = transientDab.attributes
                    }
                    try appendProjectedRecords(
                        for: attributes,
                        to: &depositionInputScratch.replayRecords
                    )
                }
            }
        }
        try appendReplayChunks(
            buffer.actualChunks,
            preparedSuffixCount: preparedActualSuffixCount,
            preparedSingle: preparedActualSingle
        )
        try appendReplayChunks(
            buffer.predictedChunks,
            preparedSuffixCount: preparedPredictedSuffixCount,
            preparedSingle: preparedPredictedSingle
        )
        recordScratchAllocationIfNeeded(
            capacityBefore: replacementCapacityBefore,
            capacityAfter: depositionInputScratch.replayRecords.capacity
        )
        guard depositionInputScratch.replayRecords.count
            <= TransientStrokeBufferContract
                .visibleEpochProjectedInstanceCapacity
        else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity
            )
        }
        try replaceCompiledReplay(
            depositionInputScratch.replayRecords,
            dirtyRegionCapacityBefore: regionCapacityBefore,
            predictionProvenance: predictionProvenance,
            predictionInvalidationBoundary:
                predictionInvalidationBoundary,
            predictionOverload: predictionOverload
        )
    }

    private func replaceCompiledReplay(
        _ records: [ProjectedDabRecord],
        dirtyRegionCapacityBefore: Int,
        predictionProvenance: PredictionProvenanceBoundary?,
        predictionInvalidationBoundary:
            PredictionProvenanceBoundary?,
        predictionOverload: PredictionOverloadReasons
    ) throws {
        guard let scheduler = activeStroke?.frozenHarnessScheduler
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let capacityBefore =
            depositionInputScratch.depositionRecords.capacity
        depositionInputScratch.depositionRecords.removeAll(
            keepingCapacity: true
        )
        precondition(
            depositionInputScratch.depositionRecords.capacity
                >= records.count,
            "Deposition scratch must be reserved before interactive input."
        )
        for record in records {
            depositionInputScratch.depositionRecords.append(
                record.depositionRecord
            )
        }
        recordScratchAllocationIfNeeded(
            capacityBefore: capacityBefore,
            capacityAfter:
                depositionInputScratch.depositionRecords.capacity
        )
        let replacement: PredictionReplacementResult
        do {
            replacement = try scheduler.replacePrediction(
                depositionInputScratch.depositionRecords
            )
        } catch let error as FrameSchedulerError {
            throw rendererError(for: error)
        }

        let epoch = takeReplayEpoch()
        var overload = predictionOverload
        if replacement.overloaded {
            overload.insert(.projectedInstances)
        }
        let predictedSampleCount = transientStrokeBuffer?
            .predictedSampleCount ?? 0
        let predictedDabCount = transientStrokeBuffer?
            .predictedDabCount ?? 0
        let predictedInstanceCount = depositionInputScratch
            .depositionRecords.reduce(0) {
                $0 + ($1.isPredicted ? 1 : 0)
            }
        if predictedInstanceCount
            > depositionFrameBudget.maximumPredictedInstances
        {
            overload.insert(.projectedInstances)
        }
        depositionInputScratch.replayDirtyRegions.removeAll(
            keepingCapacity: true
        )
        var retainedPredictedCount = 0
        for record in records {
            if record.depositionRecord.isPredicted {
                guard retainedPredictedCount
                    < replacement.acceptedPredictedInstanceCount
                else {
                    continue
                }
                retainedPredictedCount += 1
            }
            depositionInputScratch.replayDirtyRegions.append(
                record.dirtyRect
            )
        }
        PixelRegionSet.canonicalizeInPlace(
            &depositionInputScratch.replayDirtyRegions,
            clippedTo: storagePixelSize
        )
        recordScratchAllocationIfNeeded(
            capacityBefore: dirtyRegionCapacityBefore,
            capacityAfter:
                depositionInputScratch.replayDirtyRegions.capacity
        )
        let admission = PredictionOverlayAdmission(
            normalizedSampleCount: min(
                predictedSampleCount,
                PredictionOverlay.maximumNormalizedSampleCount
            ),
            logicalDabCount: min(
                predictedDabCount,
                PredictionOverlay.maximumLogicalDabCount
            ),
            projectedInstanceCount:
                replacement.acceptedPredictedInstanceCount,
            overload: overload
        )
        if let predictionInvalidationBoundary,
           predictionOverlay.hasPrediction(
                from: predictionInvalidationBoundary
           ),
           depositionInputScratch.replayDirtyRegions.isEmpty
        {
            precondition(
                predictionOverlay.invalidatePrediction(
                    from: predictionInvalidationBoundary,
                    epoch: epoch
                ),
                "Validated prediction provenance must remain current."
            )
        } else {
            predictionOverlay.planReplacementInPlace(
                epoch: epoch,
                provenance: predictionProvenance,
                admission: admission,
                dirtyRegions:
                    depositionInputScratch.replayDirtyRegions
            )
        }
        replayStroke.beginReplacementEpoch(epoch)
        retainedPredictedCount = 0
        var acceptedRecordCount = 0
        for record in records {
            if record.depositionRecord.isPredicted {
                guard retainedPredictedCount
                    < replacement.acceptedPredictedInstanceCount
                else {
                    continue
                }
                retainedPredictedCount += 1
            }
            replayStroke.recordDirtyRegion(record.dirtyRect)
            acceptedRecordCount += 1
        }
        counters.totalInstancesThisStroke += acceptedRecordCount
        needsReplayClear = true
        recordBrushLabScheduler(scheduler)
    }

    private func rendererError(
        for error: FrameSchedulerError
    ) -> MetalRendererError {
        switch error {
        case let .authoritativeCapacityExceeded(_, _, maximum):
            .projectedInstanceCapacityExceeded(maximum)
        case let .predictedCapacityExceeded(_, maximum):
            .projectedInstanceCapacityExceeded(maximum)
        }
    }

    private func appendProjectedRecords(
        for dab: DabAttributes,
        to records: inout [ProjectedDabRecord]
    ) throws {
        guard activeStroke != nil else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let footprint = StampFootprint(
            brushToWorld: dab.brushToWorld,
            localBounds: AxisAlignedRect(
                minimum: SIMD2(-1, -1),
                maximum: SIMD2(1, 1)
            ),
            coverageSymmetry: .oriented
        )
        let allocationCountBefore =
            tilingProjectionScratch.storageAllocationCount
        let storageDiagnostics = TilingProjection.project(
            footprint,
            using: tilingStrategy,
            into: tilingProjectionScratch
        )
        if tilingProjectionScratch.storageAllocationCount
            > allocationCountBefore
        {
            inputPathStorageAudit.recordCollectionStorageAllocation(
                capacity: tilingProjectionScratch.fragments.capacity
            )
        }
        inputPathStorageAudit.recordTiling(
            storageDiagnostics
        )
        for fragment in tilingProjectionScratch.fragments {
            let isometryOrdinal = try compiledIsometryOrdinal(
                for: fragment
            )
            records.append(ProjectedDabRecord(
                depositionRecord: ProjectedDepositionRecord(
                    identity: dab.ordinal,
                    instance: try PatternDepositionStampInstance(
                        fragment: fragment,
                        dab: dab,
                        logicalOrdinal: dab.ordinal,
                        isometryOrdinal: isometryOrdinal
                    ),
                    radialPage: radialPage(for: fragment)
                ),
                dirtyRect: TilingProjection.dirtyPixelRect(
                    for: fragment,
                    radius: dab.radius
                ),
                radialPage: radialPage(for: fragment)
            ))
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

    private func radialPage(
        for fragment: CellFragment
    ) -> RadialPageCoordinate? {
        guard tilingStrategy.compiledSymmetry.domain.finite?
            .radial.layout != nil
        else {
            return nil
        }
        return RadialPageCoordinate(
            x: fragment.cell.column,
            y: fragment.cell.row
        )
    }

    private func takeReplayEpoch() -> UInt64 {
        let epoch = nextReplayEpoch
        nextReplayEpoch &+= 1
        precondition(nextReplayEpoch != 0, "Replay epoch exhausted")
        return epoch
    }

    @discardableResult
    func appendProjectedFragments(
        at point: WorldPoint,
        requestedRadius: Float? = nil,
        coverageSymmetry: FootprintCoverageSymmetry = .halfTurnInvariant
    ) throws -> [CellFragment] {
        guard let activeStroke else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let radius = TilingProjection.clampedRadius(
            requested: requestedRadius ?? activeStroke.style.diameter / 2,
            tileSize: tileSize
        )
        let brushToWorld = Affine2D(
            xAxis: SIMD2(radius, 0),
            yAxis: SIMD2(0, radius),
            translation: point.simd
        )
        let footprint = StampFootprint(
            brushToWorld: brushToWorld,
            localBounds: AxisAlignedRect(
                minimum: SIMD2(-1, -1),
                maximum: SIMD2(1, 1)
            ),
            coverageSymmetry: coverageSymmetry
        )
        let fragments = TilingProjection.fragments(
            for: footprint,
            using: tilingStrategy
        )
        let baseOrdinal = UInt64(counters.totalInstancesThisStroke)
        let dab = LogicalDab(
            position: point,
            brushToWorld: brushToWorld,
            radius: radius,
            diameter: radius * 2,
            spacing: 1,
            flow: 1,
            strokeOpacity: 1,
            rotation: 0,
            scatter: .zero,
            hardness: 1,
            grainOffset: .zero,
            grainScale: 1,
            grainRotation: 0,
            color: color(for: activeStroke.style),
            colorAdjustment: .identity,
            materialFamily: .ink,
            materialContribution: 1,
            sourceDistance: 0,
            ordinal: baseOrdinal,
            isPredicted: false
        )
        let records = try fragments.enumerated().map { offset, fragment in
            let ordinal = baseOrdinal + UInt64(offset)
            let radialPage = radialPage(for: fragment)
            return ProjectedDabRecord(
                depositionRecord: ProjectedDepositionRecord(
                    identity: ordinal,
                    instance: try PatternDepositionStampInstance(
                        fragment: fragment,
                        dab: dab,
                        logicalOrdinal: ordinal,
                        isometryOrdinal: compiledIsometryOrdinal(for: fragment)
                    ),
                    radialPage: radialPage
                ),
                dirtyRect: TilingProjection.dirtyPixelRect(
                    for: fragment,
                    radius: radius
                ),
                radialPage: radialPage
            )
        }
        try enqueueCompiledAuthoritative(records)
        return fragments
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
                activeStroke?.brush.program.definition.material
                    .accumulationLimit ?? 1,
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

    private static func makeRasterResources(
        device: any MTLDevice,
        canvasPixelSize: PixelSize? = nil,
        pixelSize: PixelSize,
        initialRevision: RasterRevision,
        forceAllocationFailure: Bool
    ) throws -> RasterResources {
        if forceAllocationFailure {
            throw MetalRendererError.textureAllocationFailed
        }
        let canonical = try CanonicalRaster(
            device: device,
            pixelSize: pixelSize,
            initialRevision: initialRevision
        )
        let liveTile = try PersistentLiveTile(
            device: device,
            pixelSize: pixelSize
        )
        let predictionOverlay = try PredictionOverlay(
            device: device,
            pixelSize: pixelSize
        )
        return RasterResources(
            canvasPixelSize: canvasPixelSize ?? pixelSize,
            pixelSize: pixelSize,
            tileSize: PatternSize(
                width: Float(pixelSize.width),
                height: Float(pixelSize.height)
            ),
            canonical: canonical,
            liveTile: liveTile,
            predictionOverlay: predictionOverlay
        )
    }

    private static func makeRadialPageTableTexture(
        device: any MTLDevice,
        compiled: CompiledSymmetry
    ) throws -> any MTLTexture {
        let layout = compiled.domain.finite?.radial.layout
        let width = layout?.pageTableSize.width ?? 1
        let height = layout?.pageTableSize.height ?? 1
        let values = layout?.pageTable ?? [Int32(0)]
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Sint,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * MemoryLayout<Int32>.stride
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

    private func fullRasterRegions(for size: PixelSize) -> PixelRegionSet {
        PixelRegionSet(
            [
                PixelRect(
                    minX: 0,
                    minY: 0,
                    maxX: size.width,
                    maxY: size.height
                )!,
            ],
            clippedTo: size
        )
    }

    func encodeResizeIntersectionCopy(
        from source: any MTLTexture,
        oldPixelSize: PixelSize,
        to destination: any MTLTexture,
        newPixelSize: PixelSize,
        on commandBuffer: any MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalRendererError.commandFailed(
                "Metal blit encoder creation failed."
            )
        }
        encoder.label = "Resize Top-Left Intersection Copy"
        encoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: min(oldPixelSize.width, newPixelSize.width),
                height: min(oldPixelSize.height, newPixelSize.height),
                depth: 1
            ),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
    }

    private func encodeRadialResizeCopy(
        from source: any MTLTexture,
        sourceStrategy: TilingStrategy,
        sourcePageTable: (any MTLTexture)?,
        to destination: any MTLTexture,
        destinationStrategy: TilingStrategy,
        on commandBuffer: any MTLCommandBuffer
    ) throws {
        guard let sourcePageTable,
              let layout = destinationStrategy.compiledSymmetry.domain.finite?
                .radial.layout
        else {
            throw MetalRendererError.invalidSymmetryConfiguration(
                "Radial resize requires source and destination page layouts."
            )
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalRendererError.commandFailed(
                "Metal compute encoder creation failed."
            )
        }
        encoder.label = "Radial Resize Crop/Expand Copy"
        encoder.setComputePipelineState(pipelines.radialResizeCopy)
        encoder.setTexture(
            source,
            index: Int(PatternTextureIndexCanonical)
        )
        encoder.setTexture(
            destination,
            index: Int(PatternTextureIndexLive)
        )
        encoder.setTexture(
            sourcePageTable,
            index: Int(PatternTextureIndexRadialPageTable)
        )
        var sourceUniforms = radialFrameUniforms(
            strategy: sourceStrategy,
            storagePixelSize: PixelSize(
                width: source.width,
                height: source.height
            )
        )
        var destinationUniforms = radialFrameUniforms(
            strategy: destinationStrategy,
            storagePixelSize: PixelSize(
                width: destination.width,
                height: destination.height
            )
        )
        encoder.setBytes(
            &sourceUniforms,
            length: MemoryLayout<PatternRadialFrameUniforms>.stride,
            index: Int(PatternBufferIndexRadialFrameUniforms)
        )
        encoder.setBytes(
            &destinationUniforms,
            length: MemoryLayout<PatternRadialFrameUniforms>.stride,
            index: Int(
                PatternBufferIndexRadialResizeDestinationUniforms
            )
        )
        let executionWidth = pipelines.radialResizeCopy.threadExecutionWidth
        let executionHeight = max(
            1,
            pipelines.radialResizeCopy.maxTotalThreadsPerThreadgroup
                / executionWidth
        )
        let threadsPerGroup = MTLSize(
            width: executionWidth,
            height: executionHeight,
            depth: 1
        )
        let pageThreads = MTLSize(
            width: RadialSectorLayout.pageSide,
            height: RadialSectorLayout.pageSide,
            depth: 1
        )
        for page in layout.residentPages {
            guard let pageX = Int32(exactly: page.coordinate.x),
                  let pageY = Int32(exactly: page.coordinate.y),
                  let slot = UInt32(exactly: page.atlasSlot)
            else {
                encoder.endEncoding()
                throw MetalRendererError.invalidSymmetryConfiguration(
                    "Radial resize page coordinates exceed the shader ABI."
                )
            }
            var pageUniforms = PatternRadialResizePageUniforms(
                logicalPageX: pageX,
                logicalPageY: pageY,
                destinationSlot: slot,
                padding: 0
            )
            encoder.setBytes(
                &pageUniforms,
                length: MemoryLayout<PatternRadialResizePageUniforms>.stride,
                index: Int(PatternBufferIndexRadialResizePage)
            )
            encoder.dispatchThreads(
                pageThreads,
                threadsPerThreadgroup: threadsPerGroup
            )
        }
        encoder.endEncoding()
    }

    private func clearInitialTextures() throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }
        for texture in [
            canonical.front,
            canonical.scratch,
            liveTile.texture,
            replayTile.texture,
        ] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: pass
            ) else {
                throw MetalRendererError.renderEncoderUnavailable
            }
            encoder.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw MetalRendererError.commandFailed(
                commandBuffer.error?.localizedDescription
                    ?? "initial transparent clear failed"
            )
        }
        liveTile.markCleared()
        predictionOverlay.markCleared(epoch: 0)
        needsLiveClear = false
        needsReplayClear = false
    }

    private func encodeTransparentClear(
        of texture: any MTLTexture,
        on commandBuffer: any MTLCommandBuffer,
        label: String
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }
        encoder.label = label
        encoder.endEncoding()
    }

    private func encodeCanonicalFrontCopy(
        to destination: any MTLTexture,
        on commandBuffer: any MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalRendererError.commandFailed(
                "Metal blit encoder creation failed."
            )
        }
        encoder.label = "Canonical Front To Scratch"
        encoder.copy(
            from: canonical.front,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: storagePixelSize.width,
                height: storagePixelSize.height,
                depth: 1
            ),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
    }

    private func encodeLiveClear(
        _ commandBuffer: any MTLCommandBuffer
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = liveTile.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }
        encoder.label = "Clear Persistent Live Stroke"
        encoder.endEncoding()
    }

    func encodeReplayClear(
        _ commandBuffer: any MTLCommandBuffer
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = replayTile.texture
        pass.colorAttachments[0].storeAction = .store
        if replayTile.hasRegionalClearPlan {
            pass.colorAttachments[0].loadAction = .load
        } else {
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }
        encoder.label = "Clear Replay Live Stroke"
        if replayTile.hasRegionalClearPlan {
            encoder.setRenderPipelineState(pipelines.replayClear)
            var uniforms = frameUniforms(
                drawableSize: tileSize,
                showGridLines: false,
                liveVisible: true
            )
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<PatternGridFrameUniforms>.stride,
                index: Int(PatternBufferIndexGridFrameUniforms)
            )
            for rectangle in replayTile.regionalClearRectangles {
                encoder.setScissorRect(
                    MTLScissorRect(
                        x: rectangle.minX,
                        y: rectangle.minY,
                        width: rectangle.width,
                        height: rectangle.height
                    )
                )
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 3
                )
            }
        }
        encoder.endEncoding()
    }

    func clearLiveForHarnessIfNeeded() throws {
        guard needsLiveClear else {
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            let error = MetalRendererError.commandBufferUnavailable
            failActiveOperationIfNeeded(error)
            throw error
        }
        do {
            try encodeLiveClear(commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            try validateHarnessCommand(commandBuffer)
        } catch let error as MetalRendererError {
            failActiveOperationIfNeeded(error)
            throw error
        }
        liveTile.markCleared()
        needsLiveClear = false
    }

    func encodePendingLiveDabs(
        _ commandBuffer: any MTLCommandBuffer
    ) throws -> PendingLiveEncoding {
        let requiresAtomicReplayReplacement = needsReplayClear
            && replayStroke.renderEpoch > replayTile.visibleEpoch
        if requiresAtomicReplayReplacement {
            return try encodeAtomicReplayReplacement(commandBuffer)
        }

        var uploads: [FrameUpload] = []
        uploads.reserveCapacity(GridCanvasContract.inFlightBufferCount)
        let encodedReplayClear = needsReplayClear
        do {
            if encodedReplayClear {
                try encodeReplayClear(commandBuffer)
            }
            try encodePending(
                liveStroke,
                layer: .settled,
                texture: liveTile.texture,
                commandBuffer: commandBuffer,
                uploads: &uploads
            )
            try encodePending(
                replayStroke,
                layer: .replay,
                texture: replayTile.texture,
                commandBuffer: commandBuffer,
                uploads: &uploads
            )
            return PendingLiveEncoding(
                uploads: uploads,
                encodedReplayClear: encodedReplayClear
            )
        } catch {
            abandon(uploads)
            throw error
        }
    }

    func encodeScheduledDeposition(
        _ commandBuffer: any MTLCommandBuffer
    ) throws -> NativeDepositionFrameEncoding {
        guard let execution = activeStroke else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        if strokePreparationBridge != nil {
            guard let pending = pendingPreparedSurfaceFrame,
                  submittedPreparedWorkerFrame == nil
            else {
                lastEncodedAuthoritativeIdentityRange = nil
                return NativeDepositionFrameEncoding(
                    authoritativeCount: 0,
                    predictedCount: 0,
                    logicalDabCount: 0,
                    uploadBufferCount: 0,
                    encodedLiveClear: false,
                    encodedReplayClear: false,
                    replayEpoch: 0,
                    encodedAuthoritativeIdentityRange: nil,
                    preparedWorkerFrame: nil
                )
            }
            let lease = pending.lease
            try encodePreparedSurfaceSnapshot(
                lease,
                commandBuffer: commandBuffer
            )
            let encodedAuthoritativeIdentityRange: Range<UInt64>?
            if lease.authoritativeInstanceCount > 0 {
                let lowerBound = encodedAuthoritativeIdentityHighWater
                let (upperBound, overflow) = lowerBound
                    .addingReportingOverflow(
                        UInt64(lease.authoritativeInstanceCount)
                    )
                precondition(
                    !overflow
                        && upperBound
                            <= scheduledAuthoritativeIdentityHighWater
                )
                encodedAuthoritativeIdentityRange = lowerBound..<upperBound
                encodedAuthoritativeIdentityHighWater = upperBound
            } else {
                encodedAuthoritativeIdentityRange = nil
            }
            lastEncodedAuthoritativeIdentityRange =
                encodedAuthoritativeIdentityRange
            brushLabLastFrameEncodedDabCount = pending.logicalDabCount
            brushLabLastFrameEncodedInstanceCount =
                pending.identity.recordCount
            brushLabStrokeEncodedDabCount = Self.saturatingAdd(
                brushLabStrokeEncodedDabCount,
                UInt64(pending.logicalDabCount)
            )
            brushLabDepositionTelemetry.recordEncoding(
                instanceCount: UInt64(pending.identity.recordCount),
                bufferCount: 1
            )
            submittedPreparedWorkerFrame = pending.identity
            return NativeDepositionFrameEncoding(
                authoritativeCount: lease.authoritativeInstanceCount,
                predictedCount: lease.predictedInstanceCount,
                logicalDabCount: pending.logicalDabCount,
                uploadBufferCount: pending.identity.recordCount > 0 ? 1 : 0,
                encodedLiveClear: lease.clearedAuthoritativeSurface,
                encodedReplayClear: lease.clearedPredictionSurface,
                replayEpoch: pending.replayEpoch,
                encodedAuthoritativeIdentityRange:
                    encodedAuthoritativeIdentityRange,
                preparedWorkerFrame: pending.identity
            )
        }
        guard let scheduler = execution.frozenHarnessScheduler else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let binding = execution.brush.resources.depositionPipeline
        let material = execution.brush.resources.depositionMaterial

        // Authoritative work owns the frame whenever it is present. This
        // keeps a frame to one render target, so preflight and submission are
        // one atomic encoder transaction and prediction replacement remains
        // all-or-nothing.
        let includePrediction = scheduler.authoritativeIsDrained
        let authoritativeCapacityBefore =
            depositionInputScratch.authoritativeFrame.capacity
        let predictedCapacityBefore =
            depositionInputScratch.predictedFrame.capacity
        let frame = scheduler.preparedFrame(
            budget: depositionFrameBudget,
            includePrediction: includePrediction,
            authoritativeScratch:
                &depositionInputScratch.authoritativeFrame,
            predictedScratch: &depositionInputScratch.predictedFrame
        )
        recordScratchAllocationIfNeeded(
            capacityBefore: authoritativeCapacityBefore,
            capacityAfter:
                depositionInputScratch.authoritativeFrame.capacity
        )
        recordScratchAllocationIfNeeded(
            capacityBefore: predictedCapacityBefore,
            capacityAfter: depositionInputScratch.predictedFrame.capacity
        )
        precondition(
            frame.authoritative.isEmpty || frame.predicted.isEmpty,
            "A compiled deposition frame must target one live surface."
        )
        let records = frame.authoritative.isEmpty
            ? frame.predicted
            : frame.authoritative
        let target = frame.authoritative.isEmpty
            ? replayTile.texture
            : liveTile.texture

        guard var encoder = depositionEncoder else {
            throw MetalRendererError.depositionEncoderUnavailable
        }
        encoder.updateFrameUniforms(
            frameUniforms(
                drawableSize: tileSize,
                showGridLines: false,
                liveVisible: true
            )
        )
        let prepared: PreparedDepositionEncoding?
        do {
            prepared = records.isEmpty
                ? nil
                : try encoder.preflight(
                    records: records,
                    binding: binding,
                    material: material,
                    target: target
                )
        } catch DepositionEncodingError.uploadBuffersUnavailable
            where !frame.predicted.isEmpty
        {
            lastEncodedAuthoritativeIdentityRange = nil
            return NativeDepositionFrameEncoding(
                authoritativeCount: 0,
                predictedCount: 0,
                logicalDabCount: 0,
                uploadBufferCount: 0,
                encodedLiveClear: false,
                encodedReplayClear: false,
                replayEpoch: 0,
                encodedAuthoritativeIdentityRange: nil,
                preparedWorkerFrame: nil
            )
        } catch {
            throw rendererError(forDepositionError: error)
        }

        let encodedLiveClear = needsLiveClear
        let encodedReplayClear = needsReplayClear
            && frame.authoritative.isEmpty
        do {
            if encodedLiveClear {
                try encodeLiveClear(commandBuffer)
            }
            if encodedReplayClear {
                try encodeReplayClear(commandBuffer)
            }
            if let prepared {
                _ = try encoder.encode(
                    prepared,
                    into: target,
                    commandBuffer: commandBuffer
                )
            }
        } catch {
            if let prepared {
                encoder.abandon(prepared)
            }
            throw rendererError(forDepositionError: error)
        }

        depositionEncoder = encoder
        scheduler.consume(frame)
        recordBrushLabScheduler(scheduler)
        let identityCapacityBefore =
            depositionInputScratch.encodedLogicalIdentities.capacity
        depositionInputScratch.encodedLogicalIdentities.removeAll(
            keepingCapacity: true
        )
        for record in records
        where !depositionInputScratch.encodedLogicalIdentities.contains(
            record.identity
        ) {
            depositionInputScratch.encodedLogicalIdentities.append(
                record.identity
            )
        }
        recordScratchAllocationIfNeeded(
            capacityBefore: identityCapacityBefore,
            capacityAfter:
                depositionInputScratch.encodedLogicalIdentities.capacity
        )
        brushLabLastFrameEncodedDabCount =
            depositionInputScratch.encodedLogicalIdentities.count
        brushLabLastFrameEncodedInstanceCount = records.count
        brushLabStrokeEncodedDabCount = Self.saturatingAdd(
            brushLabStrokeEncodedDabCount,
            UInt64(brushLabLastFrameEncodedDabCount)
        )
        brushLabDepositionTelemetry.recordEncoding(
            instanceCount: UInt64(records.count),
            bufferCount:
                instancePool.diagnosticSnapshot.currentLeaseCount
        )
        let encodedAuthoritativeIdentityRange: Range<UInt64>?
        if frame.authoritative.isEmpty {
            encodedAuthoritativeIdentityRange = nil
        } else {
            let lowerBound = encodedAuthoritativeIdentityHighWater
            let (upperBound, overflow) =
                lowerBound.addingReportingOverflow(
                    UInt64(frame.authoritative.count)
                )
            precondition(
                !overflow
                    && upperBound <= scheduledAuthoritativeIdentityHighWater,
                "Encoded authoritative identity exceeded scheduled high-water."
            )
            encodedAuthoritativeIdentityRange = lowerBound..<upperBound
            encodedAuthoritativeIdentityHighWater = upperBound
        }
        lastEncodedAuthoritativeIdentityRange =
            encodedAuthoritativeIdentityRange
        let preparedWorkerFrame: PreparedWorkerFrameIdentity?
        if let pendingPreparedWorkerFrame,
           !frame.authoritative.isEmpty,
           pendingPreparedWorkerFrame.recordCount
            == frame.authoritative.count
        {
            preparedWorkerFrame = pendingPreparedWorkerFrame
        } else {
            preparedWorkerFrame = nil
        }
        return NativeDepositionFrameEncoding(
            authoritativeCount: frame.authoritative.count,
            predictedCount: frame.predicted.count,
            logicalDabCount: brushLabLastFrameEncodedDabCount,
            uploadBufferCount: prepared?.uploadCount ?? 0,
            encodedLiveClear: encodedLiveClear,
            encodedReplayClear: encodedReplayClear,
            replayEpoch: encodedReplayClear || !frame.predicted.isEmpty
                ? replayStroke.renderEpoch
                : 0,
            encodedAuthoritativeIdentityRange:
                encodedAuthoritativeIdentityRange,
            preparedWorkerFrame: preparedWorkerFrame
        )
    }

    private func encodePreparedSurfaceSnapshot(
        _ lease: StrokePreparedSurfaceLease,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        let authoritative = lease.authoritativeTexture
        let prediction = lease.predictionTexture
        guard authoritative.width == liveTile.texture.width,
              authoritative.height == liveTile.texture.height,
              prediction.width == replayTile.texture.width,
              prediction.height == replayTile.texture.height,
              authoritative.pixelFormat == liveTile.texture.pixelFormat,
              prediction.pixelFormat == replayTile.texture.pixelFormat,
              let encoder = commandBuffer.makeBlitCommandEncoder()
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let size = MTLSize(
            width: authoritative.width,
            height: authoritative.height,
            depth: 1
        )
        encoder.label = "Snapshot Prepared Stroke Surfaces"
        encoder.copy(
            from: authoritative,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: size,
            to: liveTile.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.copy(
            from: prediction,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: size,
            to: replayTile.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
    }

    private func rendererError(
        forDepositionError error: Error
    ) -> MetalRendererError {
        if let rendererError = error as? MetalRendererError {
            return rendererError
        }
        guard let encodingError = error as? DepositionEncodingError else {
            return .commandFailed(error.localizedDescription)
        }
        switch encodingError {
        case .commandBufferUnavailable:
            return .commandBufferUnavailable
        case .renderEncoderUnavailable:
            return .renderEncoderUnavailable
        case .uploadBuffersUnavailable:
            return .instanceBufferAllocationFailed
        case .unsupportedPipelineBackend,
             .unsupportedPipelineABI,
             .invalidPipelinePixelFormat,
             .targetPixelFormatMismatch,
             .targetSampleCountMismatch,
             .targetIsNotRenderTarget,
             .targetChangedAfterPreflight,
             .missingTexture,
             .invalidMaterialUniform,
             .invalidInstance,
             .foreignPreparation:
            return .invalidCompiledBrush
        case .integerOverflow,
             .invalidCapacity,
             .recordLimitExceeded,
             .uploadLimitExceeded,
             .preparationAlreadyFinalized:
            return .commandFailed(String(describing: encodingError))
        }
    }

    /// Encodes a replay epoch only after reserving enough buffers for both
    /// chronological prefix promotion and the complete replacement tail.
    /// Returning an empty, uncleared encoding is an intentional retry signal:
    /// the previous replay texture remains visible until a later frame can
    /// reserve the whole atomic group.
    private func encodeAtomicReplayReplacement(
        _ commandBuffer: any MTLCommandBuffer
    ) throws -> PendingLiveEncoding {
        let settledCount = pendingInstanceCount(in: liveStroke)
        let replayCount = pendingInstanceCount(in: replayStroke)
        let capacity = GridCanvasContract.instanceCapacity
        guard settledCount <= capacity else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                capacity
            )
        }
        guard replayCount <= capacity else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                capacity
            )
        }

        let requiredLeaseCount = (settledCount > 0 ? 1 : 0)
            + (replayCount > 0 ? 1 : 0)
        guard let leases = instancePool.acquire(count: requiredLeaseCount)
        else {
            return PendingLiveEncoding(
                uploads: [],
                encodedReplayClear: false
            )
        }

        var uploads: [FrameUpload] = []
        uploads.reserveCapacity(requiredLeaseCount)
        var leaseIndex = 0
        do {
            if settledCount > 0 {
                try encodeCompletePending(
                    liveStroke,
                    layer: .settled,
                    texture: liveTile.texture,
                    lease: leases[leaseIndex],
                    commandBuffer: commandBuffer,
                    uploads: &uploads
                )
                leaseIndex += 1
            }

            try encodeReplayClear(commandBuffer)

            if replayCount > 0 {
                try encodeCompletePending(
                    replayStroke,
                    layer: .replay,
                    texture: replayTile.texture,
                    lease: leases[leaseIndex],
                    commandBuffer: commandBuffer,
                    uploads: &uploads
                )
            }
            return PendingLiveEncoding(
                uploads: uploads,
                encodedReplayClear: true
            )
        } catch {
            for lease in leases {
                instancePool.abandon(lease)
            }
            throw error
        }
    }

    private func pendingInstanceCount(in stroke: LiveStroke) -> Int {
        stroke.pending.count {
            $0.identity >= stroke.bakedHighWater
        }
    }

    private func encodeCompletePending(
        _ stroke: LiveStroke,
        layer: FrameUpload.Layer,
        texture: any MTLTexture,
        lease: DabInstanceBufferPool.Lease,
        commandBuffer: any MTLCommandBuffer,
        uploads: inout [FrameUpload]
    ) throws {
        guard let firstPending = stroke.pending.firstIndex(
            where: { $0.identity >= stroke.bakedHighWater }
        ) else {
            preconditionFailure("Atomic upload was preflighted without dabs")
        }
        let chunk = stroke.pending[firstPending...]
        precondition(chunk.count <= lease.capacity)
        instancePool.write(chunk, into: lease)
        try encodeStamp(
            commandBuffer,
            lease: lease,
            count: chunk.count,
            instances: chunk,
            texture: texture,
            layer: layer
        )
        let throughExclusive = chunk.last!.identity + 1
        uploads.append(
            FrameUpload(
                lease: lease,
                identityRange: chunk.first!.identity..<throughExclusive,
                throughExclusive: throughExclusive,
                count: chunk.count,
                layer: layer,
                replayEpoch: stroke.renderEpoch
            )
        )
    }

    private func encodePending(
        _ stroke: LiveStroke,
        layer: FrameUpload.Layer,
        texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        uploads: inout [FrameUpload]
    ) throws {
        guard let firstPending = stroke.pending.firstIndex(
            where: { $0.identity >= stroke.bakedHighWater }
        ) else { return }
        var cursor = firstPending
        while cursor < stroke.pending.endIndex,
              uploads.count < GridCanvasContract.inFlightBufferCount
        {
            guard let lease = instancePool.acquire() else { break }
            let end = min(cursor + lease.capacity, stroke.pending.endIndex)
            let chunk = stroke.pending[cursor..<end]
            instancePool.write(chunk, into: lease)
            do {
                try encodeStamp(
                    commandBuffer,
                    lease: lease,
                    count: chunk.count,
                    instances: chunk,
                    texture: texture,
                    layer: layer
                )
            } catch {
                instancePool.abandon(lease)
                throw error
            }
            let throughExclusive = chunk.last.map { $0.identity + 1 }
                ?? stroke.bakedHighWater
            let fromIdentity = chunk.first.map(\.identity) ?? throughExclusive
            uploads.append(
                FrameUpload(
                    lease: lease,
                    identityRange: fromIdentity..<throughExclusive,
                    throughExclusive: throughExclusive,
                    count: chunk.count,
                    layer: layer,
                    replayEpoch: stroke.renderEpoch
                )
            )
            cursor = end
        }
    }

    private func encodeStamp(
        _ commandBuffer: any MTLCommandBuffer,
        lease: DabInstanceBufferPool.Lease,
        count: Int,
        instances _: ArraySlice<IdentifiedDab>,
        texture: any MTLTexture,
        layer: FrameUpload.Layer
    ) throws {
        guard let execution = activeStroke else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let brush = execution.brush.resources
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }
        encoder.label = layer == .settled
            ? "Stamp Persistent Live Dabs"
            : "Stamp Replay Live Dabs"
        encoder.setRenderPipelineState(brush.depositionPipeline.state)
        var uniforms = frameUniforms(
            drawableSize: tileSize,
            showGridLines: false,
            liveVisible: true
        )
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<PatternGridFrameUniforms>.stride,
            index: Int(PatternBufferIndexGridFrameUniforms)
        )
        encoder.setVertexBuffer(
            lease.buffer,
            offset: 0,
            index: Int(PatternBufferIndexDabInstances)
        )
        for slot in brush.depositionMaterial.textures.boundSlots {
            guard let texture = brush.depositionMaterial.textures[slot] else {
                throw MetalRendererError.invalidCompiledBrush
            }
            encoder.setFragmentTexture(
                texture,
                index: slot.rawValue
            )
        }
        var materialUniforms = brush.depositionMaterial.uniforms
        encoder.setFragmentBytes(
            &materialUniforms,
            length: MemoryLayout<PatternDepositionMaterialUniforms>.stride,
            index: Int(PatternBufferIndexBrushMaterial)
        )
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: count
        )
        encoder.endEncoding()
    }

    func encodeCommit(
        _ commandBuffer: any MTLCommandBuffer,
        liveVisible: Bool,
        liveTexture: (any MTLTexture)? = nil,
        replayTexture: (any MTLTexture)? = nil
    ) throws -> EncodedRasterCommit {
        guard
            let execution = activeStroke,
            execution.commitRequested,
            let revisions = execution.pendingRevisions
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }

        var captureTokens: [RasterRevisionOperationToken] = []
        do {
            captureTokens.append(
                try revisionStore.encodeCapture(
                    revisions.before,
                    from: canonical.front,
                    on: commandBuffer
                )
            )

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = canonical.scratch
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: pass
            ) else {
                throw MetalRendererError.renderEncoderUnavailable
            }
            encoder.label = "Canonical Scratch Commit"
            encoder.setRenderPipelineState(pipelines.commit)
            var uniforms = frameUniforms(
                drawableSize: tileSize,
                showGridLines: false,
                liveVisible: liveVisible
            )
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<PatternGridFrameUniforms>.stride,
                index: Int(PatternBufferIndexGridFrameUniforms)
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<PatternGridFrameUniforms>.stride,
                index: Int(PatternBufferIndexGridFrameUniforms)
            )
            var materialUniforms = compositeMaterialUniforms
            encoder.setFragmentBytes(
                &materialUniforms,
                length: MemoryLayout<PatternCompositeUniforms>.stride,
                index: Int(PatternBufferIndexBrushMaterial)
            )
            encoder.setFragmentTexture(
                canonical.front,
                index: Int(PatternTextureIndexCanonical)
            )
            encoder.setFragmentTexture(
                liveTexture ?? liveTile.texture,
                index: Int(PatternTextureIndexLive)
            )
            encoder.setFragmentTexture(
                replayTexture ?? replayTile.texture,
                index: Int(PatternTextureIndexReplayLive)
            )
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 3
            )
            encoder.endEncoding()

            captureTokens.append(
                try revisionStore.encodeCapture(
                    revisions.after,
                    from: canonical.scratch,
                    on: commandBuffer
                )
            )
            return EncodedRasterCommit(
                token: execution.token,
                revisions: revisions,
                captureTokens: captureTokens
            )
        } catch {
            finalizeCaptureTokens(captureTokens, as: .cancelled)
            throw error
        }
    }

    func encodeDisplay(
        into texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        showGridLines: Bool,
        liveVisible: Bool,
        canonicalTexture: (any MTLTexture)? = nil,
        documentPixelMapping: Bool = false,
        transparentBackground: Bool = false,
        showCanvasBoundary: Bool = true,
        worldCenterOverride: SIMD2<Float>? = nil,
        zoomOverride: Float? = nil,
        liveTexture: (any MTLTexture)? = nil,
        replayTexture: (any MTLTexture)? = nil
    ) throws {
        guard texture.width > 0, texture.height > 0 else {
            throw MetalRendererError.invalidDrawableSize
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = transparentBackground
            ? MTLClearColorMake(0, 0, 0, 0)
            : MTLClearColor(
                red: 242.0 / 255.0,
                green: 244.0 / 255.0,
                blue: 241.0 / 255.0,
                alpha: 1
            )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }
        let displayFamily = tilingStrategy.compiledSymmetry.family
        switch displayFamily {
        case .rectangular:
            encoder.label = "Grid Display"
            encoder.setRenderPipelineState(pipelines.display)
        case .triangular:
            encoder.label = "Triangular Grid Display"
            encoder.setRenderPipelineState(pipelines.triangularDisplay)
        case .radial:
            encoder.label = "Radial Finite Display"
            encoder.setRenderPipelineState(pipelines.radialDisplay)
        }
        var uniforms = frameUniforms(
            drawableSize: PatternSize(
                width: Float(texture.width),
                height: Float(texture.height)
            ),
            showGridLines: showGridLines,
            liveVisible: liveVisible
        )
        if documentPixelMapping {
            uniforms.worldCenter = SIMD2(
                Float(pixelSize.width) * 0.5,
                Float(pixelSize.height) * 0.5
            )
            uniforms.zoom = 1
        }
        if let worldCenterOverride {
            uniforms.worldCenter = worldCenterOverride
        }
        if let zoomOverride {
            uniforms.zoom = zoomOverride
        }
        uniforms.showCanvasBoundary = showCanvasBoundary ? 1 : 0
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<PatternGridFrameUniforms>.stride,
            index: Int(PatternBufferIndexGridFrameUniforms)
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<PatternGridFrameUniforms>.stride,
            index: Int(PatternBufferIndexGridFrameUniforms)
        )
        var materialUniforms = compositeMaterialUniforms
        encoder.setFragmentBytes(
            &materialUniforms,
            length: MemoryLayout<PatternCompositeUniforms>.stride,
            index: Int(PatternBufferIndexBrushMaterial)
        )
        if displayFamily == .radial {
            var radialUniforms = radialFrameUniforms()
            encoder.setFragmentBytes(
                &radialUniforms,
                length: MemoryLayout<PatternRadialFrameUniforms>.stride,
                index: Int(PatternBufferIndexRadialFrameUniforms)
            )
            guard let radialPageTableTexture else {
                throw MetalRendererError.textureAllocationFailed
            }
            encoder.setFragmentTexture(
                radialPageTableTexture,
                index: Int(PatternTextureIndexRadialPageTable)
            )
        }
        encoder.setFragmentTexture(
            canonicalTexture ?? canonical.front,
            index: Int(PatternTextureIndexCanonical)
        )
        encoder.setFragmentTexture(
            liveTexture ?? liveTile.texture,
            index: Int(PatternTextureIndexLive)
        )
        encoder.setFragmentTexture(
            replayTexture ?? replayTile.texture,
            index: Int(PatternTextureIndexReplayLive)
        )
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 3
        )
        encoder.endEncoding()
    }

    func finalizeFrameEncoding(
        encodedClear: Bool,
        encodedReplayClear: Bool = false,
        uploads: [FrameUpload],
        nativeEncoding: NativeDepositionFrameEncoding? = nil,
        rasterCommit: EncodedRasterCommit?,
        commandBuffer: any MTLCommandBuffer,
        forceFailure: Bool = false
    ) throws -> [DabBufferSubmissionIdentity] {
        if let rasterCommit {
            guard
                var execution = activeStroke,
                execution.token == rasterCommit.token,
                execution.commitRequested,
                execution.pendingRevisions == rasterCommit.revisions
            else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            execution.commitRequested = false
            activeStroke = execution
        }

        let usesPreparedWorkerSurface =
            nativeEncoding?.preparedWorkerFrame != nil
        if encodedClear {
            if usesPreparedWorkerSurface {
                offMainLiveVisible = false
            } else {
                liveTile.markCleared()
            }
            needsLiveClear = false
        }
        if encodedReplayClear {
            if usesPreparedWorkerSurface {
                offMainReplayVisible = false
            }
            predictionOverlay.markCleared(
                epoch: nativeEncoding?.replayEpoch
                    ?? replayStroke.renderEpoch
            )
            needsReplayClear = false
        }
        var uploadSubmissions: [DabBufferSubmissionIdentity] = []
        uploadSubmissions.reserveCapacity(uploads.count)
        for upload in uploads {
            uploadSubmissions.append(
                instancePool.submit(
                    upload.lease,
                    on: commandBuffer
                )
            )
            completedUploadRanges.append(
                (
                    signal: upload.lease.signalValue,
                    throughExclusive: upload.throughExclusive,
                    layer: upload.layer,
                    replayEpoch: upload.replayEpoch
                )
            )
            switch upload.layer {
            case .settled:
                liveStroke.markEncoded(
                    throughExclusive: upload.throughExclusive
                )
            case .replay:
                if upload.replayEpoch == replayStroke.renderEpoch {
                    replayStroke.markEncoded(
                        throughExclusive: upload.throughExclusive
                    )
                }
            }
        }
        counters.newInstancesThisFrame = nativeEncoding?.instanceCount
            ?? uploads.reduce(0) { $0 + $1.count }
        if uploads.contains(where: { $0.layer == .settled }) {
            liveTile.markStamped()
        }
        if let epoch = uploads
            .filter({ $0.layer == .replay })
            .map(\.replayEpoch)
            .max()
        {
            predictionOverlay.markVisible(epoch: epoch)
        }
        if let nativeEncoding {
            if nativeEncoding.authoritativeCount > 0 {
                if usesPreparedWorkerSurface {
                    offMainLiveVisible = true
                } else {
                    liveTile.markStamped()
                }
            }
            if nativeEncoding.predictedCount > 0 {
                if usesPreparedWorkerSurface {
                    offMainReplayVisible = true
                }
                predictionOverlay.markVisible(
                    epoch: nativeEncoding.replayEpoch
                )
            }
        }

        let submittedOperationToken: RendererOperationToken?
        if let rasterCommit {
            submittedOperationToken = rasterCommit.token
        } else if let execution = activeStroke,
                  !execution.isCommitSubmitted,
                  encodedClear || encodedReplayClear || !uploads.isEmpty
                    || (nativeEncoding?.instanceCount ?? 0) > 0
        {
            submittedOperationToken = execution.token
        } else {
            submittedOperationToken = nil
        }
        if rasterCommit == nil, let submittedOperationToken {
            guard
                var execution = activeStroke,
                execution.token == submittedOperationToken,
                !execution.isCommitSubmitted
            else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            execution.pendingTokenBearingFrameCount += 1
            activeStroke = execution
        }
        let submittedUploads = uploadSubmissions
        let submittedReplayEpoch = uploads
            .filter { $0.layer == .replay }
            .map(\.replayEpoch)
            .max() ?? 0
        let submittedCommit = rasterCommit.map {
            GridRenderCompletionMailbox.RasterCommit(
                token: $0.token,
                revisions: $0.revisions,
                captureTokens: $0.captureTokens
            )
        }
        let submittedPreparedWorkerFrame =
            nativeEncoding?.preparedWorkerFrame
        commandBuffer.addCompletedHandler {
            [
                completionMailbox,
                submittedCommit,
                submittedOperationToken,
                submittedUploads,
                submittedReplayEpoch,
                submittedPreparedWorkerFrame,
            ] buffer in
            let completed = buffer.status == .completed && !forceFailure
            completionMailbox.push(
                .init(
                    operationToken: submittedOperationToken,
                    rasterCommit: submittedCommit,
                    uploadSubmissions: submittedUploads,
                    replayEpoch: submittedReplayEpoch,
                    preparedWorkerFrame:
                        submittedPreparedWorkerFrame,
                    succeeded: completed,
                    errorMessage: forceFailure
                        ? "injected harness command-buffer failure"
                        : buffer.error?.localizedDescription
                )
            )
        }
        return submittedUploads
    }

    /// A prepared-surface blit may be encoded before later display or commit
    /// encoding fails. The partial command must reach a terminal GPU state
    /// before its actor-owned textures are returned. The operation failure is
    /// reported by the caller; this outcome exists only to retire the exact
    /// borrowed lease after the partial command terminates.
    private func installPreparedSurfaceTerminalHandler(
        for nativeEncoding: NativeDepositionFrameEncoding?,
        on commandBuffer: any MTLCommandBuffer
    ) {
        guard let preparedWorkerFrame =
                nativeEncoding?.preparedWorkerFrame,
              submittedPreparedWorkerFrame == preparedWorkerFrame
        else {
            return
        }
        commandBuffer.addCompletedHandler {
            [completionMailbox, preparedWorkerFrame] _ in
            completionMailbox.push(
                .init(
                    operationToken: nil,
                    rasterCommit: nil,
                    uploadSubmissions: [],
                    preparedWorkerFrame: preparedWorkerFrame,
                    succeeded: true,
                    errorMessage: nil
                )
            )
        }
    }

    func drainCompletedUploadRanges() {
        let completedSignal = instancePool.event.signaledValue
        let completed = completedUploadRanges.filter {
            $0.signal <= completedSignal
        }
        if let greatest = (completed
            .filter { $0.layer == .settled }
            .map(\.throughExclusive)
            .max())
        {
            liveStroke.releaseEncodedPrefix(throughExclusive: greatest)
        }
        if let greatestReplay = (completed
            .filter {
                $0.layer == .replay
                    && $0.replayEpoch == replayStroke.renderEpoch
            }
            .map(\.throughExclusive)
            .max())
        {
            replayStroke.releaseEncodedPrefix(
                throughExclusive: greatestReplay
            )
        }
        completedUploadRanges.removeAll {
            $0.signal <= completedSignal
        }
    }

    @discardableResult
    func drainRasterOperationOutcomes() -> MetalRendererError? {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        var latestError: MetalRendererError?
        for outcome in rasterCompletionMailbox.drain() {
            if let error = processRasterOperationOutcome(outcome) {
                latestError = error
            }
        }
        return latestError
    }

    private func processRasterOperationOutcome(
        _ outcome: RendererRasterSubmissionOutcome
    ) -> MetalRendererError? {
        guard
            let pendingRasterOperation,
            pendingRasterOperation.submissionID == outcome.submissionID,
            pendingRasterOperation.token == outcome.token
        else {
            preconditionFailure(
                "Renderer completed a raster operation it did not accept."
            )
        }

        guard outcome.succeeded else {
            return finalizeRasterOperationFailure(
                pendingRasterOperation,
                error: .commandFailed(
                    outcome.errorMessage ?? "unknown command-buffer error"
                )
            )
        }

        switch pendingRasterOperation {
        case let .clear(operation):
            do {
                for token in operation.captureTokens {
                    try revisionStore.finalize(token, as: .succeeded)
                }
                canonical.acceptScratchCommit()
                revisionStore.publish(operation.revisions)
                setDocumentGeometryLocked(false)
                self.pendingRasterOperation = nil
                notifyIdleStateIfChanged(from: false)
                stageRendererEvent(
                    .operationCompleted(.rasterSuccess(
                        RasterMutationReceipt(
                            token: operation.token,
                            before: operation.revisions.before,
                            after: operation.revisions.after
                        )
                    ))
                )
                return nil
            } catch {
                let rendererError = (error as? MetalRendererError)
                    ?? .commandFailed(error.localizedDescription)
                finalizeCaptureTokens(operation.captureTokens, as: .failed)
                revisionStore.discard(operation.revisions)
                self.pendingRasterOperation = nil
                notifyIdleStateIfChanged(from: false)
                report(rendererError)
                stageRendererEvent(
                    .operationCompleted(
                        .failure(operation.token, rendererError)
                    )
                )
                return rendererError
            }
        case let .restore(operation):
            do {
                try revisionStore.finalize(
                    operation.restoreToken,
                    as: .succeeded
                )
                canonical.acceptScratchCommit()
                self.pendingRasterOperation = nil
                notifyIdleStateIfChanged(from: false)
                stageRendererEvent(
                    .operationCompleted(.operationSuccess(operation.token))
                )
                return nil
            } catch {
                let rendererError = (error as? MetalRendererError)
                    ?? .commandFailed(error.localizedDescription)
                finalizeRestoreToken(operation.restoreToken, as: .failed)
                self.pendingRasterOperation = nil
                notifyIdleStateIfChanged(from: false)
                report(rendererError)
                stageRendererEvent(
                    .operationCompleted(
                        .failure(operation.token, rendererError)
                    )
                )
                return rendererError
            }
        case let .resize(operation):
            do {
                for token in operation.captureTokens {
                    try revisionStore.finalize(token, as: .succeeded)
                }
                operation.replacement.resources.canonical
                    .acceptScratchCommit()
                revisionStore.publish(operation.revisions)
                install(operation.replacement)
                self.pendingRasterOperation = nil
                notifyIdleStateIfChanged(from: false)
                stageRendererEvent(
                    .operationCompleted(.rasterSuccess(
                        RasterMutationReceipt(
                            token: operation.token,
                            before: operation.revisions.before,
                            after: operation.revisions.after
                        )
                    ))
                )
                return nil
            } catch {
                let rendererError = (error as? MetalRendererError)
                    ?? .commandFailed(error.localizedDescription)
                finalizeCaptureTokens(operation.captureTokens, as: .failed)
                revisionStore.discard(operation.revisions)
                self.pendingRasterOperation = nil
                notifyIdleStateIfChanged(from: false)
                report(rendererError)
                stageRendererEvent(
                    .operationCompleted(
                        .failure(operation.token, rendererError)
                    )
                )
                return rendererError
            }
        case let .resizeRestore(operation):
            do {
                try revisionStore.finalize(
                    operation.restoreToken,
                    as: .succeeded
                )
                operation.replacement.resources.canonical
                    .acceptScratchCommit()
                install(operation.replacement)
                self.pendingRasterOperation = nil
                notifyIdleStateIfChanged(from: false)
                stageRendererEvent(
                    .operationCompleted(.operationSuccess(operation.token))
                )
                return nil
            } catch {
                let rendererError = (error as? MetalRendererError)
                    ?? .commandFailed(error.localizedDescription)
                finalizeRestoreToken(operation.restoreToken, as: .failed)
                self.pendingRasterOperation = nil
                notifyIdleStateIfChanged(from: false)
                report(rendererError)
                stageRendererEvent(
                    .operationCompleted(
                        .failure(operation.token, rendererError)
                    )
                )
                return rendererError
            }
        }
    }

    private func finalizeRasterOperationFailure(
        _ operation: PendingRasterOperation,
        error: MetalRendererError
    ) -> MetalRendererError {
        switch operation {
        case let .clear(clear):
            finalizeCaptureTokens(clear.captureTokens, as: .failed)
            revisionStore.discard(clear.revisions)
        case let .restore(restore):
            finalizeRestoreToken(restore.restoreToken, as: .failed)
        case let .resize(resize):
            finalizeCaptureTokens(resize.captureTokens, as: .failed)
            revisionStore.discard(resize.revisions)
        case let .resizeRestore(restore):
            finalizeRestoreToken(restore.restoreToken, as: .failed)
        }
        pendingRasterOperation = nil
        notifyIdleStateIfChanged(from: false)
        report(error)
        stageRendererEvent(
            .operationCompleted(.failure(operation.token, error))
        )
        return error
    }

    private func install(_ replacement: PreparedRasterReplacement) {
        let canvasSizeChanged =
            replacement.resources.canvasPixelSize != resources.canvasPixelSize
        replacement.resources.liveTile.markCleared()
        replacement.resources.predictionOverlay.markCleared(epoch: 0)
        resources = replacement.resources
        strokeMetalSurfaceResources =
            replacement.strokeMetalSurfaceResources
        strokeMetalSurfaceInstallationCount &+= 1
        tilingStrategy = replacement.strategy
        radialPageTableTexture = replacement.radialPageTableTexture
        needsLiveClear = false
        needsReplayClear = false
        if canvasSizeChanged {
            viewport = ViewportTransform(
                drawableSize: viewport.drawableSize,
                worldCenter: WorldPoint(
                    x: Float(resources.canvasPixelSize.width) * 0.5,
                    y: Float(resources.canvasPixelSize.height) * 0.5
                ),
                zoom: viewport.zoom
            )
        }
    }

    private func finalizeRestoreToken(
        _ token: RasterRevisionOperationToken,
        as outcome: RasterRevisionOperationOutcome
    ) {
        do {
            try revisionStore.finalize(token, as: outcome)
        } catch MetalRendererError.invalidRasterRevisionOperationToken {
            return
        } catch {
            report(
                (error as? MetalRendererError)
                    ?? .commandFailed(error.localizedDescription)
            )
        }
    }

    private func takeRasterSubmissionID() -> UInt64 {
        precondition(
            nextRasterSubmissionID < UInt64.max,
            "Renderer raster submission identity space exhausted."
        )
        let submissionID = nextRasterSubmissionID
        nextRasterSubmissionID += 1
        return submissionID
    }

    private func setDocumentGeometryLocked(_ locked: Bool) {
        documentDomainLocked = locked
        radialGeometryLocked =
            locked
            && tilingStrategy.compiledSymmetry.domain.finite?
                .radial.layout != nil
    }

    private func installRasterCompletionHandler(
        on commandBuffer: any MTLCommandBuffer,
        submissionID: UInt64,
        token: RendererOperationToken,
        forceFailure: Bool
    ) {
        commandBuffer.addCompletedHandler {
            [weak self, rasterCompletionMailbox] buffer in
            let succeeded = buffer.status == .completed && !forceFailure
            rasterCompletionMailbox.push(
                RendererRasterSubmissionOutcome(
                    submissionID: submissionID,
                    token: token,
                    succeeded: succeeded,
                    errorMessage: forceFailure
                        ? "injected harness command-buffer failure"
                        : buffer.error?.localizedDescription
                )
            )
            Task { @MainActor [weak self] in
                _ = self?.drainRasterOperationOutcomes()
            }
        }
    }

    @discardableResult
    func drainFrameOutcomes() -> MetalRendererError? {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        var latestError: MetalRendererError?
        for outcome in completionMailbox.drain() {
            let error = processFrameOutcome(outcome)
            if let error {
                latestError = error
            }
        }
        return latestError
    }

    func processFrameOutcome(
        _ outcome: GridRenderCompletionMailbox.Outcome
    ) -> MetalRendererError? {
        let ownsEventOperation = beginRendererEventOperationIfNeeded()
        defer {
            endRendererEventOperationIfNeeded(
                ownsEventOperation,
                succeeded: true
            )
        }
        if !outcome.succeeded {
            instancePool.reclaimTerminalFailure(
                outcome.uploadSubmissions
            )
        }
        if let preparedWorkerFrame = outcome.preparedWorkerFrame,
           pendingPreparedWorkerFrame == preparedWorkerFrame
        {
            do {
                try acknowledgeSubmittedPreparationFrame(
                    preparedWorkerFrame
                )
            } catch {
                let rendererError = (error as? MetalRendererError)
                    ?? .commandFailed(error.localizedDescription)
                if let token = outcome.operationToken {
                    terminateActiveOperation(
                        token: token,
                        error: rendererError
                    )
                } else {
                    report(rendererError)
                }
                return rendererError
            }
        }
        let isStaleReplayOutcome = outcome.replayEpoch != 0
            && outcome.replayEpoch < replayStroke.renderEpoch
        if isStaleReplayOutcome,
           outcome.rasterCommit == nil,
           outcome.succeeded
        {
            if let token = outcome.operationToken {
                finishTokenBearingFrame(token: token)
            }
            return nil
        }
        guard let commit = outcome.rasterCommit else {
            if let token = outcome.operationToken {
                finishTokenBearingFrame(token: token)
            }
            guard !outcome.succeeded else { return nil }
            let error = MetalRendererError.commandFailed(
                outcome.errorMessage ?? "unknown command-buffer error"
            )
            if let token = outcome.operationToken {
                terminateActiveOperation(token: token, error: error)
            } else {
                report(error)
            }
            return error
        }

        if outcome.succeeded {
            return finalizeRasterCommitSuccess(commit)
        }
        return finalizeRasterCommitFailure(
            commit,
            message: outcome.errorMessage
                ?? "unknown command-buffer error"
        )
    }

    private func finishTokenBearingFrame(token: RendererOperationToken) {
        guard
            var execution = activeStroke,
            execution.token == token
        else {
            return
        }
        precondition(
            execution.pendingTokenBearingFrameCount > 0,
            "A token-bearing frame outcome drained more than once."
        )
        execution.pendingTokenBearingFrameCount -= 1
        activeStroke = execution
    }

    private func finalizeRasterCommitSuccess(
        _ commit: GridRenderCompletionMailbox.RasterCommit
    ) -> MetalRendererError? {
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        guard activeStrokeMatchesSubmittedCommit(commit) else {
            let error = MetalRendererError.invalidRendererOperationToken
            finalizeCaptureTokens(commit.captureTokens, as: .failed)
            revisionStore.discard(commit.revisions)
            let runtimeEndEvents = endStrokeRuntimeIfPossible()
            activeStroke = nil
            resetLiveState()
            stageStrokeRuntimeEvents(runtimeEndEvents)
            report(error)
            stageRendererEvent(
                .operationCompleted(.failure(commit.token, error))
            )
            return error
        }

        do {
            for token in commit.captureTokens {
                try revisionStore.finalize(token, as: .succeeded)
            }
            canonical.acceptScratchCommit()
            revisionStore.publish(commit.revisions)
            setDocumentGeometryLocked(true)
            let receipt = RasterMutationReceipt(
                token: commit.token,
                before: commit.revisions.before,
                after: commit.revisions.after
            )
            let runtimeEndEvents = endStrokeRuntimeIfPossible()
            activeStroke = nil
            resetLiveState(invalidateStrokeEvents: false)
            stageStrokeRuntimeEvents(runtimeEndEvents)
            stageRendererEvent(.operationCompleted(.rasterSuccess(receipt)))
            return nil
        } catch let error as MetalRendererError {
            finalizeCaptureTokens(commit.captureTokens, as: .failed)
            discardSubmittedPairIfPossible(commit.revisions)
            let runtimeEndEvents = endStrokeRuntimeIfPossible()
            activeStroke = nil
            resetLiveState()
            stageStrokeRuntimeEvents(runtimeEndEvents)
            report(error)
            stageRendererEvent(
                .operationCompleted(.failure(commit.token, error))
            )
            return error
        } catch {
            let rendererError = MetalRendererError.commandFailed(
                error.localizedDescription
            )
            finalizeCaptureTokens(commit.captureTokens, as: .failed)
            discardSubmittedPairIfPossible(commit.revisions)
            let runtimeEndEvents = endStrokeRuntimeIfPossible()
            activeStroke = nil
            resetLiveState()
            stageStrokeRuntimeEvents(runtimeEndEvents)
            report(rendererError)
            stageRendererEvent(
                .operationCompleted(
                    .failure(commit.token, rendererError)
                )
            )
            return rendererError
        }
    }

    private func finalizeRasterCommitFailure(
        _ commit: GridRenderCompletionMailbox.RasterCommit,
        message: String
    ) -> MetalRendererError {
        let error = MetalRendererError.commandFailed(message)
        finalizeCaptureTokens(commit.captureTokens, as: .failed)
        if !terminateActiveOperation(token: commit.token, error: error) {
            revisionStore.discard(commit.revisions)
        }
        return error
    }

    private func activeStrokeMatchesSubmittedCommit(
        _ commit: GridRenderCompletionMailbox.RasterCommit
    ) -> Bool {
        guard let execution = activeStroke else { return false }
        return execution.token == commit.token
            && !execution.commitRequested
            && execution.pendingRevisions == commit.revisions
    }

    private func finalizeCaptureTokens(
        _ tokens: [RasterRevisionOperationToken],
        as outcome: RasterRevisionOperationOutcome
    ) {
        for token in tokens {
            do {
                try revisionStore.finalize(token, as: outcome)
            } catch MetalRendererError.invalidRasterRevisionOperationToken {
                continue
            } catch {
                report(
                    (error as? MetalRendererError)
                        ?? .commandFailed(error.localizedDescription)
                )
            }
        }
    }

    private func discardSubmittedPairIfPossible(
        _ pair: PendingRasterRevisionPair
    ) {
        if activeStroke?.pendingRevisions == pair {
            revisionStore.discard(pair)
        }
    }

    private func resetLiveState(
        invalidateStrokeEvents: Bool = true
    ) {
        strokeGenerator?.cancel()
        strokeGenerator = nil
        let isRetiringStrokeWorkspace = retireStrokeWorkspaceIfNeeded()
        if !isRetiringStrokeWorkspace {
            strokePreparationBridge = nil
            strokePreparationGeneration = nil
            pendingPreparedWorkerFrame = nil
            pendingPreparedSurfaceFrame = nil
            submittedPreparedWorkerFrame = nil
            currentPreparedSurfaceLease = nil
        }
        strokePreparationResultScratch.removeAll(keepingCapacity: true)
        offMainLiveVisible = false
        offMainReplayVisible = false
        pendingPreparationCommitRetainedBytes = nil
        lastOffMainCoordinatorSnapshot = nil
        lastOffMainPredictionProvenanceBoundary = nil
        predictedStrokeGenerator?.cancel()
        predictedStrokeGenerator = nil
        transientStrokeBuffer?.cancel()
        transientStrokeBuffer = nil
        brushInputDeriver.reset()
        predictedInputDeriver = nil
        liveTile.hide()
        predictionOverlay.reset()
        completedUploadRanges.removeAll(keepingCapacity: true)
        liveStroke.reset()
        replayStroke.reset()
        needsLiveClear = true
        needsReplayClear = true
        nextReplayEpoch = 1
        knownStrokeTotalDistance = nil
        if invalidateStrokeEvents {
            invalidateStrokeEventGeneration()
        }
    }

    private func retireStrokeWorkspaceIfNeeded() -> Bool {
        guard let bridge = strokePreparationBridge,
              let generation = strokePreparationGeneration
        else {
            strokeWorkspaceState = .available
            return false
        }
        switch strokeWorkspaceState {
        case .available:
            return false
        case .retiring:
            return true
        case let .borrowed(borrowedGeneration):
            precondition(borrowedGeneration == generation)
            var cancellationFrameDisposition =
                StrokePreparationCancellationFrameDisposition
                    .preserveMainOwnership
            if submittedPreparedWorkerFrame == nil,
               let frame = pendingPreparedWorkerFrame
            {
                do {
                    try bridge.acknowledgePreparedFrame(
                        generation: frame.generation,
                        token: frame.token
                    )
                    pendingPreparedWorkerFrame = nil
                    pendingPreparedSurfaceFrame = nil
                    currentPreparedSurfaceLease = nil
                } catch {
                    report(
                        .commandFailed(
                            "stroke workspace retirement failed: \(error)"
                        )
                    )
                }
            } else if submittedPreparedWorkerFrame == nil,
                      pendingPreparedSurfaceFrame == nil,
                      currentPreparedSurfaceLease == nil
            {
                // A result may already have left the mailbox but fail before
                // Main installs its immutable lease. No GPU command can own
                // that surface, so cancellation must return it to the actor.
                cancellationFrameDisposition =
                    .abandonedBeforeSubmission
            }
            do {
                try bridge.submitCancellation(
                    generation: generation,
                    reason: nil,
                    frameDisposition: cancellationFrameDisposition
                )
            } catch {
                report(
                    .commandFailed(
                        "stroke workspace cancellation failed: \(error)"
                    )
                )
            }
            strokeWorkspaceState = .retiring(generation)
            return true
        }
    }

    private func finishStrokeWorkspaceRetirement(
        generation: UInt64
    ) {
        guard strokeWorkspaceState == .retiring(generation),
              submittedPreparedWorkerFrame == nil,
              pendingPreparedWorkerFrame == nil,
              pendingPreparedSurfaceFrame == nil,
              currentPreparedSurfaceLease == nil
        else {
            return
        }
        let wasIdle = isIdle
        strokePreparationBridge = nil
        strokePreparationGeneration = nil
        strokeWorkspaceState = .available
        notifyIdleStateIfChanged(from: wasIdle)
    }

    func drainStrokeWorkspaceRetirementForHarness() throws {
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
            targetFramesPerSecond: 120
        )
    }

    func report(_ error: MetalRendererError) {
        lastError = error
        stageRendererEvent(.error(error))
    }

    private func notifyIdleStateIfChanged(from wasIdle: Bool) {
        guard wasIdle != isIdle else { return }
        stageRendererEvent(.idleStateChanged(isIdle))
    }

    func abandon(_ uploads: [FrameUpload]) {
        for upload in uploads {
            instancePool.abandon(upload.lease)
        }
    }

    func abandon(_ commit: EncodedRasterCommit?) {
        guard let commit else { return }
        finalizeCaptureTokens(commit.captureTokens, as: .cancelled)
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
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        discardPendingRevisionsIfPossible()
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
        guard !execution.isCommitSubmitted else {
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
        transientDabArena.reset()
        scheduledAuthoritativeIdentityHighWater = 0
        encodedAuthoritativeIdentityHighWater = 0
        lastEncodedAuthoritativeIdentityRange = nil
        lastOffMainEncodingRanOnMainThread = nil
        lastOffMainSurfaceSnapshot = nil
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

    private func transientDabSlice(
        for preparedRange: Range<Int>,
        predicted: Bool,
        transaction:
            TransientStrokeDabArena.ReservationTransaction
    ) throws -> TransientStrokeDabSlice {
        let slice = predicted
            ? try transaction.storePredicted(
                depositionInputScratch.transientDabs,
                range: preparedRange
            )
            : try transaction.storeActual(
                depositionInputScratch.transientDabs,
                range: preparedRange
            )
        return slice
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
            replayCapacity:
                liveStroke.pending.capacity + replayStroke.pending.capacity
        )
    }

    func takeBrushLabEventToSubmitNanoseconds(
        submittedAt nanoseconds: UInt64
    ) -> UInt64 {
        guard let receipt = brushLabPendingInputReceiptNanoseconds else {
            return 0
        }
        brushLabPendingInputReceiptNanoseconds = nil
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
            strokeRuntimeReplayEpochTracker.beginStroke(
                at: transientStrokeBuffer?.replayEpoch ?? 0
            )
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
        recordStrokeRuntimePreparedFrame(id: identity, encoding: nil)
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
        id: StrokeRuntimeFrameIdentity?,
        encoding: NativeDepositionFrameEncoding?
    ) {
        guard let id,
              id.telemetryGeneration == telemetryEventGeneration,
              let controller = strokeRuntimeController
        else {
            return
        }
        let scheduler = activeStroke?.frozenHarnessScheduler?
            .diagnosticSnapshot
        let currentReplayEpoch = transientStrokeBuffer?.replayEpoch ?? 0
        let replayDelta = strokeRuntimeReplayEpochTracker.consume(
            currentEpoch: currentReplayEpoch
        )
        let authoritativeReplay = encoding?.predictedCount == 0
            ? replayDelta : 0
        let predictedReplay = (encoding?.predictedCount ?? 0) > 0
            ? replayDelta : 0
        let residentBytes = UInt64(max(
            0,
            revisionStore.residentBytes
                + (activeDrawBrush?.residentByteCount ?? 0)
                + (activeEraserBrush?.residentByteCount ?? 0)
        ))
        do {
            try controller.recordPrepared(
                id: id.frameID,
                at: DispatchTime.now().uptimeNanoseconds,
                newLogicalDabCount: UInt64(max(
                    0,
                    encoding?.logicalDabCount ?? 0
                )),
                newProjectedDabCount: UInt64(max(
                    0,
                    encoding?.instanceCount ?? 0
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
        nativeEncoding: NativeDepositionFrameEncoding? = nil
    ) -> GPUFrameMetrics {
        let eventToSubmitNanoseconds = submittedAtNanoseconds == 0
            ? 0
            : takeBrushLabEventToSubmitNanoseconds(
                submittedAt: submittedAtNanoseconds
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
            encodedDabCount: nativeEncoding?.logicalDabCount ?? 0,
            encodedInstanceCount: nativeEncoding?.instanceCount ?? 0,
            bufferLeaseCount: nativeEncoding?.uploadBufferCount ?? 0
        )
    }
}
