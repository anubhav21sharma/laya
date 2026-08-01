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
    private var strokeRuntimeController: StrokeRuntimeProductionController?
    private var nextStrokeRuntimeFrameID: UInt64 = 1
    private var pendingStrokeRuntimeFrameIDs: Set<UInt64> = []
    private var strokeRuntimeReplayEpochTracker =
        StrokeRuntimeReplayEpochTracker()
    public private(set) var interactiveGridVisibility = false
    public var isIdle: Bool {
        activeStroke == nil && pendingRasterOperation == nil
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
        strokeRuntimeController = StrokeRuntimeProductionController(
            sessionID: sessionID,
            traceProfile: profile,
            windowCapacity: windowCapacity
        )
        nextStrokeRuntimeFrameID = 1
        pendingStrokeRuntimeFrameIDs.removeAll(keepingCapacity: true)
        strokeRuntimeReplayEpochTracker.beginStroke(at: 0)
        onStrokeRuntimeSnapshot?(strokeRuntimeController!.snapshot)
    }

    public func disableStrokeRuntimeTelemetry() {
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
        let scheduler = activeStroke?.scheduler?.diagnosticSnapshot
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

        var instanceCount: Int {
            authoritativeCount + predictedCount
        }
    }

    struct ActiveStrokeExecution {
        let token: RendererOperationToken
        let style: StrokeRenderStyle
        let compiledBrush: CompiledBrush
        let renderIdentity: BrushRenderIdentity
        var scheduler: FrameScheduler?
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
        let replayTile: ReplayLiveTile
    }

    struct PreparedRasterReplacement {
        let resources: RasterResources
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
    private var radialPageTableTexture: (any MTLTexture)?
    var tileSize: PatternSize { resources.tileSize }
    var canonical: CanonicalRaster { resources.canonical }
    var liveTile: PersistentLiveTile { resources.liveTile }
    var replayTile: ReplayLiveTile { resources.replayTile }
    var tilingStrategy: TilingStrategy
    var activeStroke: ActiveStrokeExecution?
    var pendingRasterOperation: PendingRasterOperation?
    var strokeGenerator: BrushStrokeGenerator?
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
        depositionFrameBudget = try DepositionFrameBudget(
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
        try installEmptyStrategy(proposed)
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
        _ proposed: TilingStrategy
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
        let priorResources = resources
        let priorStrategy = tilingStrategy
        let priorPageTable = radialPageTableTexture
        resources = replacement
        tilingStrategy = proposed
        radialPageTableTexture = replacementPageTable
        do {
            try clearInitialTextures()
        } catch {
            resources = priorResources
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
        switch mode {
        case .draw:
            activeDrawBrush = brush
        case .erase:
            activeEraserBrush = brush
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
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        guard sample.phase == .began, isIdle else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let compiledBrush = try compiledBrush(for: style)
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
        strokeGenerator = BrushStrokeGenerator(
            program: style.program,
            nominalDiameter: style.diameter,
            color: generatorColor,
            seed: style.seed
        )
        transientStrokeBuffer = TransientStrokeBuffer(
            replayContract: style.program.replayContract
        )
        activeStroke = ActiveStrokeExecution(
            token: token,
            style: style,
            compiledBrush: compiledBrush,
            renderIdentity: style.renderIdentity,
            scheduler: FrameScheduler(budget: depositionFrameBudget),
            commitRequested: false,
            commitRetainedByteLimit: nil,
            pendingRevisions: nil,
            pendingTokenBearingFrameCount: 0,
            isFinishedTransiently: false
        )
        beginStrokeRuntime(sample)
        do {
            counters.newDabsThisEvent = 0
            let inputBefore = brushInputDeriver
            let generatorBefore = strokeGenerator
            let worldSample = brushInputDeriver.derive(
                sample,
                viewport: viewport
            )
            guard var generator = strokeGenerator else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            let dabs = try prepareGeneratedDabs(generator: &generator) {
                generator, emit in
                try generator.begin(worldSample, emit: emit)
            }
            strokeGenerator = generator
            try ingestGeneratedSample(
                worldSample,
                dabs: dabs,
                generatorBeforeSample: generatorBefore,
                generatorSnapshot: generator,
                inputDeriverBeforeSample: inputBefore,
                isFinishing: false
            )
        } catch {
            endStrokeRuntimeIfPossible()
            activeStroke = nil
            resetLiveState()
            throw error
        }
    }

    public func appendStroke(
        token: RendererOperationToken,
        sample: StrokeSample
    ) throws {
        markBrushLabInputReceipt()
        recordStrokeRuntimeInput(sample)
        if sample.kind == .predicted {
            try replacePredictedStrokeSuffix(
                token: token,
                samples: CollectionOfOne(sample)
            )
        } else {
            try appendAuthoritativeStroke(token: token, sample: sample)
        }
    }

    public func appendStrokeBatch(
        token: RendererOperationToken,
        samples: [StrokeSample]
    ) throws {
        guard !samples.isEmpty else { return }
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
            } else {
                try appendAuthoritativeStroke(
                    token: token,
                    sample: samples[index]
                )
                index += 1
            }
        }
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
        guard let authoritativeGenerator = strokeGenerator,
              transientStrokeBuffer != nil
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let limits = transientStrokeBuffer!.activeReplayLimits
        guard samples.count <= limits.maximumSamples else {
            throw MetalRendererError.strokeSampleCapacityExceeded(
                limits.maximumSamples
            )
        }

        var previewDeriver = brushInputDeriver
        var previewGenerator = authoritativeGenerator
        var generatedDabCount = 0
        var projectedInstanceCount = 0
        depositionInputScratch.transientChunks.removeAll(
            keepingCapacity: true
        )
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
        let arenaTransaction = try transientDabArena.beginTransaction(
            replacingPrediction: true
        )
        defer { arenaTransaction.rollback() }

        for sample in samples {
            let inputBefore = previewDeriver
            let generatorBefore = previewGenerator
            let worldSample = previewDeriver.deriveAdvancingPrediction(
                sample,
                viewport: viewport
            )
            let prepared = try prepareGeneratedDabs(
                generator: &previewGenerator,
                resetScratch: false
            ) { generator, emit in
                try generator.append(worldSample, emit: emit)
            }
            let (nextCount, overflow) = generatedDabCount
                .addingReportingOverflow(prepared.count)
            guard !overflow, nextCount <= limits.maximumDabs else {
                throw MetalRendererError.generatedDabCapacityExceeded(
                    limits.maximumDabs
                )
            }
            let chunkProjectedCount = prepared.reduce(0) {
                $0 + depositionInputScratch.preparedDabs[$1]
                    .projectedRange.count
            }
            let (nextProjectedCount, projectedOverflow) = projectedInstanceCount
                .addingReportingOverflow(chunkProjectedCount)
            guard !projectedOverflow,
                  nextProjectedCount <= limits.maximumProjectedInstances
            else {
                throw MetalRendererError.projectedInstanceCapacityExceeded(
                    limits.maximumProjectedInstances
                )
            }
            generatedDabCount = nextCount
            projectedInstanceCount = nextProjectedCount
            depositionInputScratch.transientChunks.append(
                TransientStrokeChunk(
                    sample: worldSample,
                    dabs: try transientDabSlice(
                        for: prepared,
                        predicted: true,
                        transaction: arenaTransaction
                    ),
                    generatorSnapshotBeforeSample: generatorBefore,
                    generatorSnapshotAfterSample: previewGenerator,
                    inputDeriverSnapshotBeforeSample: inputBefore
                )
            )
            depositionInputScratch.preparedChunkRanges.append(
                prepared
            )
        }

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
            replayProjectedInstanceCount: replayProjectedInstanceCount
        )
        _ = try transientStrokeBuffer!.replacePredicted(
            with: depositionInputScratch.transientChunks,
            settledInto: &depositionInputScratch.settledChunks
        )

        try appendSettled(depositionInputScratch.settledChunks)
        try rebuildReplayLayer(
            preparedPredictedSuffixCount:
                depositionInputScratch.preparedChunkRanges.count
        )
        predictedInputDeriver = previewDeriver
        predictedStrokeGenerator = previewGenerator
        try arenaTransaction.commit(
            retainingActual: transientStrokeBuffer!.actualChunks,
            retainingPredicted: transientStrokeBuffer!.predictedChunks
        )
        counters.newDabsThisEvent = generatedDabCount
        counters.totalDabsThisStroke += generatedDabCount
        publishPreparedLogicalDabs(
            depositionInputScratch.preparedChunkRanges
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
        counters.newDabsThisEvent = 0
        guard let authoritativeGenerator = strokeGenerator else {
            throw MetalRendererError.invalidStrokeLifecycle
        }

        var previewDeriver = brushInputDeriver
        let inputBefore = previewDeriver
        let worldSample = previewDeriver.derive(
            sample,
            viewport: viewport
        )
        var generator = authoritativeGenerator
        let generatorBefore = generator
        let dabs = try prepareGeneratedDabs(generator: &generator) {
            generator, emit in
            try generator.append(worldSample, emit: emit)
        }
        try ingestGeneratedSample(
            worldSample,
            dabs: dabs,
            generatorBeforeSample: generatorBefore,
            generatorSnapshot: generator,
            inputDeriverBeforeSample: inputBefore,
            isFinishing: false
        )
        brushInputDeriver = previewDeriver
        strokeGenerator = generator
        predictedInputDeriver = nil
        predictedStrokeGenerator = nil
    }

    public func requestStrokeCommit(
        token: RendererOperationToken,
        sample: StrokeSample,
        maximumRetainedBytes: Int
    ) throws {
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        guard sample.phase == .ended else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        try requireCollectingStroke(token: token)
        do {
            try finishStrokeTransient(token: token, sample: sample)
            try requestCompiledStrokeCommit(
                maximumRetainedBytes: maximumRetainedBytes
            )
        } catch {
            endStrokeRuntimeIfPossible()
            discardPendingRevisionsIfPossible()
            activeStroke = nil
            resetLiveState()
            throw error
        }
    }

    public func finishStrokeTransient(
        token: RendererOperationToken,
        sample: StrokeSample
    ) throws {
        guard sample.phase == .ended else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        try requireCollectingStroke(token: token)
        recordStrokeRuntimeInput(sample)
        counters.newDabsThisEvent = 0
        var previewDeriver = brushInputDeriver
        let inputBefore = previewDeriver
        let worldSample = previewDeriver.derive(
            sample,
            viewport: viewport
        )
        guard var generator = strokeGenerator else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let generatorBefore = generator
        let dabs = try prepareGeneratedDabs(generator: &generator) {
            generator, emit in
            try generator.finish(worldSample, emit: emit)
        }
        try ingestGeneratedSample(
            worldSample,
            dabs: dabs,
            generatorBeforeSample: generatorBefore,
            generatorSnapshot: generator,
            inputDeriverBeforeSample: inputBefore,
            isFinishing: true
        )
        brushInputDeriver = previewDeriver
        strokeGenerator = generator
        predictedInputDeriver = nil
        predictedStrokeGenerator = nil
        activeStroke?.isFinishedTransiently = true
    }

    public func commitFinishedStroke(
        token: RendererOperationToken,
        maximumRetainedBytes: Int
    ) throws {
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        try requireEditableStroke(token: token)
        guard activeStroke?.isFinishedTransiently == true else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        do {
            try requestCompiledStrokeCommit(
                maximumRetainedBytes: maximumRetainedBytes
            )
        } catch {
            discardPendingRevisionsIfPossible()
            activeStroke = nil
            resetLiveState()
            throw error
        }
    }

    public func applyEstimatedStrokeUpdate(
        token: RendererOperationToken,
        sample: StrokeSample
    ) throws {
        guard sample.kind == .estimatedUpdate else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        recordStrokeRuntimeInput(sample)
        try requireEditableStroke(token: token)
        guard transientStrokeBuffer != nil else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        var updateDeriver = brushInputDeriver
        let update = updateDeriver.derive(sample, viewport: viewport)
        let plan: BorrowedEstimatedStrokeUpdatePlan
        do {
            plan = try transientStrokeBuffer!.planEstimatedUpdate(
                update,
                replacementSamplesInto:
                    &depositionInputScratch.worldSamples
            )
        } catch let error as TransientStrokeBufferError {
            switch error {
            case .unknownEstimatedUpdateIndex,
                 .estimatedUpdateAlreadyResolved:
                #if DEBUG
                print("Ignoring late or unknown estimated stroke update: \(error)")
                #endif
                return
            default:
                throw error
            }
        }
        guard var generator = plan.generatorBeforeReplacement else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        var deriver = plan.inputDeriverBeforeReplacement
            ?? (plan.target == .predicted
                ? brushInputDeriver
                : BrushInputDeriver())
        depositionInputScratch.transientChunks.removeAll(
            keepingCapacity: true
        )
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
        let arenaTransaction = try transientDabArena.beginTransaction(
            replacingPrediction: plan.target == .predicted
        )
        defer { arenaTransaction.rollback() }

        for plannedSample in depositionInputScratch.worldSamples {
            let inputBefore = deriver
            let replayedSample = deriver.rederive(plannedSample)
            precondition(
                replayedSample == plannedSample,
                "Estimated update plan and replay derivation diverged."
            )
            let generatorBefore = generator
            let prepared = try prepareGeneratedDabs(
                generator: &generator,
                resetScratch: false
            ) {
                generator, emit in
                switch replayedSample.phase {
                case .began:
                    try generator.begin(replayedSample, emit: emit)
                case .moved:
                    try generator.append(replayedSample, emit: emit)
                case .ended:
                    try generator.finish(replayedSample, emit: emit)
                case .cancelled:
                    throw MetalRendererError.invalidStrokeLifecycle
                }
            }
            depositionInputScratch.transientChunks.append(
                TransientStrokeChunk(
                    sample: replayedSample,
                    dabs: try transientDabSlice(
                        for: prepared,
                        predicted: plan.target == .predicted,
                        transaction: arenaTransaction
                    ),
                    generatorSnapshotBeforeSample: generatorBefore,
                    generatorSnapshotAfterSample: generator,
                    inputDeriverSnapshotBeforeSample: inputBefore
                )
            )
            depositionInputScratch.preparedChunkRanges.append(
                prepared
            )
        }
        _ = try transientStrokeBuffer!.replaceEstimatedSuffix(
            using: plan,
            expectedSamples: depositionInputScratch.worldSamples,
            with: depositionInputScratch.transientChunks,
            settledInto: &depositionInputScratch.settledChunks,
            preflightSettled: preflightStrokeMutation
        )
        try appendSettled(depositionInputScratch.settledChunks)
        switch plan.target {
        case .authoritative:
            try rebuildReplayLayer(
                preparedActualSuffixCount: min(
                    depositionInputScratch.preparedChunkRanges.count,
                    transientStrokeBuffer!.actualChunks.count
                )
            )
            strokeGenerator = generator
            brushInputDeriver = deriver
            predictedStrokeGenerator = nil
            predictedInputDeriver = nil
        case .predicted:
            try rebuildReplayLayer(
                preparedPredictedSuffixCount:
                    depositionInputScratch.preparedChunkRanges.count
            )
            predictedStrokeGenerator = generator
            predictedInputDeriver = deriver
        }
        try arenaTransaction.commit(
            retainingActual: transientStrokeBuffer!.actualChunks,
            retainingPredicted: transientStrokeBuffer!.predictedChunks
        )
        counters.newDabsThisEvent =
            depositionInputScratch.transientChunks.reduce(0) {
            $0 + $1.dabs.count
        }
        counters.totalDabsThisStroke += counters.newDabsThisEvent
        publishPreparedLogicalDabs(
            depositionInputScratch.preparedChunkRanges
        )
    }

    public func cancelStroke(token: RendererOperationToken) throws {
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        try requireEditableStroke(token: token)
        endStrokeRuntimeIfPossible()
        activeStroke = nil
        resetLiveState()
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
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
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
                of: replacement.resources.replayTile.texture,
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
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
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
                of: replacement.resources.replayTile.texture,
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
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
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
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
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

    func prepareCurrentStrokeCommit(
        maximumRetainedBytes: Int
    ) throws {
        try requestCompiledStrokeCommit(
            maximumRetainedBytes: maximumRetainedBytes
        )
    }

    private func requestCompiledStrokeCommit(
        maximumRetainedBytes: Int
    ) throws {
        markBrushLabInputReceipt()
        guard maximumRetainedBytes >= 0 else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }
        guard var execution = activeStroke,
              let scheduler = execution.scheduler,
              !execution.commitRequested,
              execution.pendingRevisions == nil
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let promotedPredictionCount = scheduler.predictedCount
        do {
            try scheduler.promotePredictionToAuthoritative()
        } catch let error as FrameSchedulerError {
            throw rendererError(for: error)
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

    func prepareCompiledCommitIfReady() throws {
        guard var execution = activeStroke,
              execution.commitRequested,
              execution.pendingRevisions == nil,
              execution.scheduler?.authoritativeIsDrained == true,
              execution.scheduler?.predictedCount == 0,
              execution.pendingTokenBearingFrameCount == 0,
              !needsReplayClear,
              let maximumRetainedBytes =
                execution.commitRetainedByteLimit
        else {
            return
        }
        execution.pendingRevisions = try allocateCurrentStrokeRevisions(
            maximumRetainedBytes: maximumRetainedBytes
        )
        activeStroke = execution
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

    func beginHarnessExecution(radius: Float) throws {
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
            compiledBrush: brush,
            renderIdentity: brush.renderIdentity,
            scheduler: FrameScheduler(budget: depositionFrameBudget),
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

    public func completePendingInteractiveStroke() throws
        -> GPUFrameMetrics
    {
        try completePendingInteractiveStroke(forceCommitFailure: false)
    }

    func completePendingInteractiveStroke(
        forceCommitFailure: Bool
    ) throws -> GPUFrameMetrics {
        do {
            var frames: [GPUFrameMetrics] = []
            for _ in 0..<64 {
                try prepareCompiledCommitIfReady()
                if activeStroke?.pendingRevisions != nil {
                    break
                }
                frames.append(
                    try completeNextPendingInteractiveFrame()
                )
            }
            try prepareCompiledCommitIfReady()
            frames.append(
                try submitPendingInteractiveCommit(
                    forceFailure: forceCommitFailure
                )
            )
            try drainCompletedInteractiveOperations()
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
        forceCommandBufferUnavailable: Bool = false
    ) throws -> GPUFrameMetrics {
        drainFrameOutcomes()
        drainCompletedUploadRanges()
        guard !forceCommandBufferUnavailable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            let error = MetalRendererError.commandBufferUnavailable
            failActiveOperationIfNeeded(error)
            throw error
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
                throw submittedError
            }
            do {
                try validateCompletedCommand(commandBuffer)
            } catch let error as MetalRendererError {
                instancePool.reclaimTerminalFailure(submissions)
                report(error)
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
                strokeRuntimeController?.discardFrame(id: runtimeFrameID)
                pendingStrokeRuntimeFrameIDs.remove(runtimeFrameID)
            }
            if !didFinalize {
                if nativeEncoding != nil,
                   commandBuffer.status == .notEnqueued
                {
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                }
                abandon(uploads)
                failActiveOperationIfNeeded(
                    (error as? MetalRendererError)
                        ?? .commandFailed(error.localizedDescription)
                )
            }
            throw error
        }
    }

    func submitPendingInteractiveCommit(
        forceFailure: Bool = false
    ) throws -> GPUFrameMetrics {
        drainFrameOutcomes()
        drainCompletedUploadRanges()
        try prepareCompiledCommitIfReady()
        let nativeIsReady =
            activeStroke?.scheduler?.authoritativeIsDrained == true
            && activeStroke?.scheduler?.predictedCount == 0
            && !needsReplayClear
        guard activeStroke?.commitRequested == true,
              activeStroke?.pendingTokenBearingFrameCount == 0,
              activeStroke?.pendingRevisions != nil,
              nativeIsReady
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            let error = MetalRendererError.commandBufferUnavailable
            failActiveOperationIfNeeded(error)
            throw error
        }

        let runtimePrepareStarted = DispatchTime.now().uptimeNanoseconds
        let runtimeFrameID = beginStrokeRuntimeFrame(
            at: runtimePrepareStarted,
            targetFrameDurationNanoseconds: 16_666_667
        )
        let start = CFAbsoluteTimeGetCurrent()
        let rasterCommit = try encodeCommit(
            commandBuffer,
            liveVisible: liveTile.isVisible || replayTile.isVisible
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
        try validateCompletedCommand(commandBuffer)
        let frameMetrics = metrics(
            commandBuffer: commandBuffer,
            cpuMilliseconds: cpuMilliseconds,
            submittedAtNanoseconds: submittedAtNanoseconds,
            completedAtNanoseconds: completedAtNanoseconds
        )
        recordBrushLabCompletedFrame(frameMetrics)
        recordStrokeRuntimeCompletedFrame(
            id: runtimeFrameID,
            commandBuffer: commandBuffer,
            submittedAt: submittedAtNanoseconds,
            completedAt: completedAtNanoseconds
        )
        return frameMetrics
    }

    func drainCompletedInteractiveOperations() throws {
        let submittedError = drainFrameOutcomes()
        drainCompletedUploadRanges()
        if let submittedError {
            throw submittedError
        }
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
        _ = drainRasterOperationOutcomes()
        drainFrameOutcomes()
        drainCompletedUploadRanges()

        guard let drawable = view.currentDrawable else {
            return
        }
        do {
            try prepareCompiledCommitIfReady()
        } catch let error as MetalRendererError {
            failActiveOperationIfNeeded(error)
            return
        } catch {
            failActiveOperationIfNeeded(
                .commandFailed(error.localizedDescription)
            )
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
                    liveVisible: liveTile.isVisible
                        || replayTile.isVisible || !uploads.isEmpty
                        || hasCurrentNativeDeposition
                )
            }
            try encodeDisplay(
                into: drawable.texture,
                commandBuffer: commandBuffer,
                showGridLines: interactiveGridVisibility,
                liveVisible: liveTile.isVisible
                    || replayTile.isVisible || !uploads.isEmpty
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
                    let gpuStarted = Self.nanoseconds(
                        completedBuffer.gpuStartTime
                    )
                    let gpuFinished = Self.nanoseconds(
                        completedBuffer.gpuEndTime
                    )
                    Task { @MainActor [weak self] in
                        self?.recordStrokeRuntimeGPUFrame(
                            id: runtimeFrameID,
                            measuredStart: gpuStarted,
                            measuredFinish: gpuFinished,
                            submittedAt: submittedAtNanoseconds
                        )
                    }
                }
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
                    self?.onInteractiveFrameMetrics?(frameMetrics)
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
                    self?.onInteractiveFramePresented?(
                        timestamp,
                        targetFramesPerSecond
                    )
                }
            }
            #else
            onInteractiveFramePresented?(
                fallbackPresentationTimestamp,
                targetFramesPerSecond
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
                strokeRuntimeController?.discardFrame(id: runtimeFrameID)
                pendingStrokeRuntimeFrameIDs.remove(runtimeFrameID)
            }
            if nativeEncoding != nil,
               commandBuffer.status == .notEnqueued
            {
                commandBuffer.commit()
            }
            abandon(uploads)
            abandon(rasterCommit)
            failActiveOperationIfNeeded(error)
        } catch {
            if let runtimeFrameID {
                strokeRuntimeController?.discardFrame(id: runtimeFrameID)
                pendingStrokeRuntimeFrameIDs.remove(runtimeFrameID)
            }
            if nativeEncoding != nil,
               commandBuffer.status == .notEnqueued
            {
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
        generatorBeforeSample: BrushStrokeGenerator?,
        generatorSnapshot: BrushStrokeGenerator,
        inputDeriverBeforeSample: BrushInputDeriver,
        isFinishing: Bool
    ) throws {
        guard transientStrokeBuffer != nil else {
            throw MetalRendererError.invalidStrokeLifecycle
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
            generatorSnapshotBeforeSample: generatorBeforeSample,
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
            publishLogicalDabs(dabs.lazy.map(\.attributes))
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
                try rebuildReplayLayer()
            } else {
                try rebuildReplayLayer(
                    preparedActualSingle: dabRange
                )
            }
        }
        try arenaTransaction.commit(
            retainingActual: transientStrokeBuffer!.actualChunks,
            retainingPredicted: transientStrokeBuffer!.predictedChunks
        )
        counters.newDabsThisEvent += dabs.count
        counters.totalDabsThisStroke += dabs.count
        publishLogicalDabs(dabs.lazy.map(\.attributes))
    }

    private func publishLogicalDabs<Dabs: Collection>(
        _ dabs: Dabs
    ) where Dabs.Element == LogicalDab {
        guard !dabs.isEmpty else { return }
        let observer = onLogicalDabsGenerated
        for dab in dabs {
            if dab.isPredicted {
                brushLabPredictedDabCount += 1
            } else {
                brushLabActualDabCount += 1
            }
            observer?(dab)
        }
    }

    private func publishPreparedLogicalDabs<Ranges: Collection>(
        _ ranges: Ranges
    ) where Ranges.Element == Range<Int> {
        let observer = onLogicalDabsGenerated
        for range in ranges {
            for index in range {
                let dab =
                    depositionInputScratch.preparedDabs[index].attributes
                if dab.isPredicted {
                    brushLabPredictedDabCount += 1
                } else {
                    brushLabActualDabCount += 1
                }
                observer?(dab)
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
        guard let scheduler = activeStroke?.scheduler else {
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
        guard let scheduler = activeStroke?.scheduler else {
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
        guard let scheduler = activeStroke?.scheduler
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
        try generate(&generator) { dab in
            guard depositionInputScratch.preparedDabs.count
                < maximumDabs
            else {
                throw MetalRendererError.generatedDabCapacityExceeded(
                    maximumDabs
                )
            }
            let projectedStart =
                depositionInputScratch.projectedArena.count
            try appendProjectedRecords(
                for: dab,
                to: &depositionInputScratch.projectedArena
            )
            let projectedRange = projectedStart
                ..< depositionInputScratch.projectedArena.count
            let (nextCount, overflow) = projectedCount.addingReportingOverflow(
                projectedRange.count
            )
            guard !overflow, nextCount <= maximumProjected else {
                throw MetalRendererError.projectedInstanceCapacityExceeded(
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
        return preparedStart
            ..< depositionInputScratch.preparedDabs.count
    }

    private func rebuildReplayLayer(
        preparedActualSuffixCount: Int = 0,
        preparedPredictedSuffixCount: Int = 0,
        preparedActualSingle: Range<Int>? = nil,
        preparedPredictedSingle: Range<Int>? = nil
    ) throws {
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
        replayStroke.appendDirtyRegions(
            clippedTo: storagePixelSize,
            into: &depositionInputScratch.replayDirtyRegions
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
        for record in depositionInputScratch.replayRecords {
            depositionInputScratch.replayDirtyRegions.append(
                record.dirtyRect
            )
        }
        PixelRegionSet.canonicalizeInPlace(
            &depositionInputScratch.replayDirtyRegions,
            clippedTo: storagePixelSize
        )
        recordScratchAllocationIfNeeded(
            capacityBefore: regionCapacityBefore,
            capacityAfter:
                depositionInputScratch.replayDirtyRegions.capacity
        )
        try replaceCompiledReplay(
            depositionInputScratch.replayRecords,
            clearRegions:
                depositionInputScratch.replayDirtyRegions
        )
    }

    private func replaceCompiledReplay(
        _ records: [ProjectedDabRecord],
        clearRegions: [PixelRect]
    ) throws {
        guard let scheduler = activeStroke?.scheduler
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
            try scheduler.replacePrediction(
                depositionInputScratch.depositionRecords
            )
        } catch let error as FrameSchedulerError {
            throw rendererError(for: error)
        }

        let epoch = takeReplayEpoch()
        replayTile.planReplacementInPlace(
            epoch: epoch,
            canonicalRegions: clearRegions
        )
        replayStroke.beginReplacementEpoch(epoch)
        for record in records {
            replayStroke.recordDirtyRegion(record.dirtyRect)
        }
        counters.totalInstancesThisStroke += records.count
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
                activeStroke?.compiledBrush.program.definition.material
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
        let replayTile = try ReplayLiveTile(
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
            replayTile: replayTile
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
        replayTile.markCleared(epoch: 0)
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
        guard let execution = activeStroke,
              let scheduler = execution.scheduler
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let binding = execution.compiledBrush.depositionPipeline
        let material = execution.compiledBrush.depositionMaterial

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
                encodedAuthoritativeIdentityRange: nil
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
                encodedAuthoritativeIdentityRange
        )
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
        let brush = execution.compiledBrush
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
        liveVisible: Bool
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
                liveTile.texture,
                index: Int(PatternTextureIndexLive)
            )
            encoder.setFragmentTexture(
                replayTile.texture,
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
        zoomOverride: Float? = nil
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
            liveTile.texture,
            index: Int(PatternTextureIndexLive)
        )
        encoder.setFragmentTexture(
            replayTile.texture,
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

        if encodedClear {
            liveTile.markCleared()
            needsLiveClear = false
        }
        if encodedReplayClear {
            replayTile.markCleared(
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
            replayTile.markVisible(epoch: epoch)
        }
        if let nativeEncoding {
            if nativeEncoding.authoritativeCount > 0 {
                liveTile.markStamped()
            }
            if nativeEncoding.predictedCount > 0 {
                replayTile.markVisible(epoch: nativeEncoding.replayEpoch)
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
        commandBuffer.addCompletedHandler {
            [
                completionMailbox,
                submittedCommit,
                submittedOperationToken,
                submittedUploads,
                submittedReplayEpoch,
            ] buffer in
            let completed = buffer.status == .completed && !forceFailure
            completionMailbox.push(
                .init(
                    operationToken: submittedOperationToken,
                    rasterCommit: submittedCommit,
                    uploadSubmissions: submittedUploads,
                    replayEpoch: submittedReplayEpoch,
                    succeeded: completed,
                    errorMessage: forceFailure
                        ? "injected harness command-buffer failure"
                        : buffer.error?.localizedDescription
                )
            )
        }
        return submittedUploads
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
                onOperationCompleted?(
                    .rasterSuccess(
                        RasterMutationReceipt(
                            token: operation.token,
                            before: operation.revisions.before,
                            after: operation.revisions.after
                        )
                    )
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
                onOperationCompleted?(.failure(operation.token, rendererError))
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
                onOperationCompleted?(.operationSuccess(operation.token))
                return nil
            } catch {
                let rendererError = (error as? MetalRendererError)
                    ?? .commandFailed(error.localizedDescription)
                finalizeRestoreToken(operation.restoreToken, as: .failed)
                self.pendingRasterOperation = nil
                notifyIdleStateIfChanged(from: false)
                report(rendererError)
                onOperationCompleted?(.failure(operation.token, rendererError))
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
                onOperationCompleted?(
                    .rasterSuccess(
                        RasterMutationReceipt(
                            token: operation.token,
                            before: operation.revisions.before,
                            after: operation.revisions.after
                        )
                    )
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
                onOperationCompleted?(.failure(operation.token, rendererError))
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
                onOperationCompleted?(.operationSuccess(operation.token))
                return nil
            } catch {
                let rendererError = (error as? MetalRendererError)
                    ?? .commandFailed(error.localizedDescription)
                finalizeRestoreToken(operation.restoreToken, as: .failed)
                self.pendingRasterOperation = nil
                notifyIdleStateIfChanged(from: false)
                report(rendererError)
                onOperationCompleted?(.failure(operation.token, rendererError))
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
        onOperationCompleted?(.failure(operation.token, error))
        return error
    }

    private func install(_ replacement: PreparedRasterReplacement) {
        let canvasSizeChanged =
            replacement.resources.canvasPixelSize != resources.canvasPixelSize
        replacement.resources.liveTile.markCleared()
        replacement.resources.replayTile.markCleared(epoch: 0)
        resources = replacement.resources
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
        if !outcome.succeeded {
            instancePool.reclaimTerminalFailure(
                outcome.uploadSubmissions
            )
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
            endStrokeRuntimeIfPossible()
            activeStroke = nil
            resetLiveState()
            report(error)
            onOperationCompleted?(.failure(commit.token, error))
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
            endStrokeRuntimeIfPossible()
            activeStroke = nil
            resetLiveState()
            onOperationCompleted?(.rasterSuccess(receipt))
            return nil
        } catch let error as MetalRendererError {
            finalizeCaptureTokens(commit.captureTokens, as: .failed)
            discardSubmittedPairIfPossible(commit.revisions)
            endStrokeRuntimeIfPossible()
            activeStroke = nil
            resetLiveState()
            report(error)
            onOperationCompleted?(.failure(commit.token, error))
            return error
        } catch {
            let rendererError = MetalRendererError.commandFailed(
                error.localizedDescription
            )
            finalizeCaptureTokens(commit.captureTokens, as: .failed)
            discardSubmittedPairIfPossible(commit.revisions)
            endStrokeRuntimeIfPossible()
            activeStroke = nil
            resetLiveState()
            report(rendererError)
            onOperationCompleted?(.failure(commit.token, rendererError))
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

    private func resetLiveState() {
        strokeGenerator?.cancel()
        strokeGenerator = nil
        predictedStrokeGenerator?.cancel()
        predictedStrokeGenerator = nil
        transientStrokeBuffer?.cancel()
        transientStrokeBuffer = nil
        brushInputDeriver.reset()
        predictedInputDeriver = nil
        liveTile.hide()
        replayTile.reset()
        completedUploadRanges.removeAll(keepingCapacity: true)
        liveStroke.reset()
        replayStroke.reset()
        needsLiveClear = true
        needsReplayClear = true
        nextReplayEpoch = 1
        knownStrokeTotalDistance = nil
    }

    func report(_ error: MetalRendererError) {
        lastError = error
        onError?(error)
    }

    private func notifyIdleStateIfChanged(from wasIdle: Bool) {
        guard wasIdle != isIdle else { return }
        onIdleStateChange?(isIdle)
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
        guard activeStroke?.token == token else {
            report(error)
            return false
        }
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        discardPendingRevisionsIfPossible()
        endStrokeRuntimeIfPossible()
        activeStroke = nil
        resetLiveState()
        report(error)
        onOperationCompleted?(.failure(token, error))
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

    private func beginStrokeRuntime(_ sample: StrokeSample) {
        guard let controller = strokeRuntimeController else { return }
        do {
            let marker = try controller.beginStroke(strokeID: UUID())
            strokeRuntimeReplayEpochTracker.beginStroke(
                at: transientStrokeBuffer?.replayEpoch ?? 0
            )
            onStrokeRuntimeSegmentMarker?(marker)
            onStrokeRuntimeSnapshot?(controller.snapshot)
            recordStrokeRuntimeInput(sample)
        } catch {
            strokeRuntimeController = nil
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
    ) -> UInt64? {
        guard let controller = strokeRuntimeController else { return nil }
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
            pendingStrokeRuntimeFrameIDs.insert(id)
            return id
        } catch {
            return nil
        }
    }

    private func recordStrokeRuntimePreparedFrame(
        id: UInt64?,
        encoding: NativeDepositionFrameEncoding?
    ) {
        guard let id, let controller = strokeRuntimeController else { return }
        let scheduler = activeStroke?.scheduler?.diagnosticSnapshot
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
                id: id,
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
            controller.discardFrame(id: id)
            pendingStrokeRuntimeFrameIDs.remove(id)
        }
    }

    private func recordStrokeRuntimeSubmittedFrame(
        id: UInt64?,
        at timestamp: UInt64
    ) {
        guard let id, let controller = strokeRuntimeController else { return }
        do {
            try controller.recordSubmitted(id: id, at: timestamp)
        } catch {
            controller.discardFrame(id: id)
            pendingStrokeRuntimeFrameIDs.remove(id)
        }
    }

    private func recordStrokeRuntimeCompletedFrame(
        id: UInt64?,
        commandBuffer: any MTLCommandBuffer,
        submittedAt: UInt64,
        completedAt: UInt64,
        presentedAt: UInt64? = nil
    ) {
        guard let id, let controller = strokeRuntimeController else { return }
        let measuredGPUStart = Self.nanoseconds(commandBuffer.gpuStartTime)
        let measuredGPUEnd = Self.nanoseconds(commandBuffer.gpuEndTime)
        let gpuStarted = max(submittedAt, measuredGPUStart)
        let gpuFinished = max(gpuStarted, measuredGPUEnd)
        let presented = max(gpuFinished, presentedAt ?? completedAt)
        do {
            _ = try controller.recordGPU(
                id: id,
                started: gpuStarted,
                finished: gpuFinished
            )
            if try controller.recordPresented(
                id: id,
                at: presented,
                semantics: .offscreenCommandCompleted
            ) {
                pendingStrokeRuntimeFrameIDs.remove(id)
                publishStrokeRuntimeSnapshotIfDue(controller)
            }
        } catch {
            controller.discardFrame(id: id)
            pendingStrokeRuntimeFrameIDs.remove(id)
        }
    }

    private func recordStrokeRuntimeGPUFrame(
        id: UInt64?,
        measuredStart: UInt64,
        measuredFinish: UInt64,
        submittedAt: UInt64
    ) {
        guard let id, let controller = strokeRuntimeController else { return }
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
                id: id,
                started: gpuStarted,
                finished: gpuFinished
            ) {
                pendingStrokeRuntimeFrameIDs.remove(id)
                publishStrokeRuntimeSnapshotIfDue(controller)
            }
        } catch {
            controller.discardFrame(id: id)
            pendingStrokeRuntimeFrameIDs.remove(id)
        }
    }

    private func recordStrokeRuntimePresentedFrame(
        id: UInt64?,
        at timestamp: UInt64
    ) {
        guard let id, let controller = strokeRuntimeController else { return }
        do {
            if try controller.recordPresented(
                id: id,
                at: timestamp,
                semantics: .drawablePresented
            ) {
                pendingStrokeRuntimeFrameIDs.remove(id)
                publishStrokeRuntimeSnapshotIfDue(controller)
            }
        } catch {
            controller.discardFrame(id: id)
            pendingStrokeRuntimeFrameIDs.remove(id)
        }
    }

    private func endStrokeRuntimeIfPossible() {
        guard let controller = strokeRuntimeController else { return }
        for id in pendingStrokeRuntimeFrameIDs.sorted() {
            controller.discardFrame(id: id)
        }
        controller.discardPendingFrames()
        pendingStrokeRuntimeFrameIDs.removeAll(keepingCapacity: true)
        do {
            let marker = try controller.endStroke()
            onStrokeRuntimeSnapshot?(controller.snapshot)
            onStrokeRuntimeSegmentMarker?(marker)
        } catch {
            if let marker = try? controller.endStroke() {
                onStrokeRuntimeSnapshot?(controller.snapshot)
                onStrokeRuntimeSegmentMarker?(marker)
            }
        }
    }

    private func publishStrokeRuntimeSnapshotIfDue(
        _ controller: StrokeRuntimeProductionController
    ) {
        guard controller.shouldPublishLiveSnapshot else { return }
        onStrokeRuntimeSnapshot?(controller.snapshot)
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
