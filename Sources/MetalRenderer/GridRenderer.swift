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

struct HarnessDiagnosticRenderedFrame {
    let canonical: any MTLTexture
    let screen: any MTLTexture
    let displayValidationCanonical: any MTLTexture
    let displayValidationScreen: any MTLTexture
    let gridLinesScreen: any MTLTexture
    let fragments: [CellFragment]
    let metrics: GPUFrameMetrics
}

struct HarnessBrushRenderedFrame {
    let canonical: any MTLTexture
    let fragments: [CellFragment]
    let shapeIdentity: BrushTextureIdentity
    let grainIdentity: BrushTextureIdentity
    let assetsWereExact: Bool
}

public struct HarnessLiveFlushResult {
    public let metrics: GPUFrameMetrics
    public let emittedHighWater: UInt64
    public let encodedIdentityRanges: [Range<UInt64>]
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

@MainActor
public final class GridRenderer: NSObject, MTKViewDelegate {
    public let device: any MTLDevice
    public var pixelSize: PixelSize { resources.pixelSize }
    public private(set) var lastError: MetalRendererError?
    public var onError: ((MetalRendererError) -> Void)?
    public var onIdleStateChange: ((Bool) -> Void)?
    public var onOperationCompleted: ((RendererOperationCompletion) -> Void)?
    #if DEBUG && os(macOS)
    public var onInteractiveFramePresented: ((TimeInterval, Int) -> Void)?
    #endif
    public private(set) var viewport: ViewportTransform
    public internal(set) var counters = GridStructuralCounters()
    public private(set) var interactiveGridVisibility = false
    public var isIdle: Bool {
        activeStroke == nil && pendingRasterOperation == nil
    }
    public var hasActiveStroke: Bool {
        guard pendingRasterOperation == nil else { return false }
        guard let activeStroke else { return false }
        return !activeStroke.commitRequested
            && activeStroke.pendingRevisions == nil
    }
    public var tiling: TilingKind { tilingStrategy.kind }
    public var periodicConfiguration: PeriodicSymmetryConfiguration {
        tilingStrategy.periodicConfiguration
    }

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

    struct ActiveStrokeExecution {
        let token: RendererOperationToken
        let style: StrokeRenderStyle
        var commitRequested: Bool
        var pendingRevisions: PendingRasterRevisionPair?
        var pendingTokenBearingFrameCount: Int

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
        let instance: PatternProjectedStampInstance
        let dirtyRect: PixelRect
    }

    private struct PreparedGeneratedDab {
        let attributes: DabAttributes
        let projected: [ProjectedDabRecord]

        var transient: TransientStrokeDab {
            TransientStrokeDab(
                attributes: attributes,
                projectedInstanceCount: projected.count
            )
        }
    }

    struct RasterResources {
        let pixelSize: PixelSize
        let tileSize: PatternSize
        let canonical: CanonicalRaster
        let liveTile: PersistentLiveTile
        let replayTile: ReplayLiveTile
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
        let replacement: RasterResources
        let revisions: PendingRasterRevisionPair
        let captureTokens: [RasterRevisionOperationToken]
        let commandBuffer: any MTLCommandBuffer
    }

    struct PendingResizeRestoreOperation {
        let submissionID: UInt64
        let token: RendererOperationToken
        let replacement: RasterResources
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
    let brushTextureResolver: BrushTextureResolver
    private(set) var activeShapeResolution: BrushTextureResolution
    private(set) var activeGrainResolution: BrushTextureResolution
    private var activeShapeTexture: any MTLTexture {
        activeShapeResolution.texture
    }
    private var activeGrainTexture: any MTLTexture {
        activeGrainResolution.texture
    }
    private var activeMaterialState: BrushMaterialState
    private(set) var boundedWashSurface: BoundedWashSurface?
    private(set) var lastBoundedWashWorkPlan: BoundedWashWorkPlan?
    private(set) var boundedWashEncodedWork = BoundedWashEncodedWork()
    private var boundedWashHistory = BoundedWashHistoryAccumulator()
    let instancePool: DabInstanceBufferPool
    let revisionStore: RasterRevisionStore
    let completionMailbox = GridRenderCompletionMailbox()
    private let rasterCompletionMailbox = RendererRasterCompletionMailbox()
    var resources: RasterResources
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
        let resources = try Self.makeRasterResources(
            device: device,
            pixelSize: configuration.pixelSize,
            initialRevision: RasterRevision(rawValue: 0),
            forceAllocationFailure: false
        )
        let brushTextureResolver = BrushTextureResolver(device: device)
        try brushTextureResolver.preloadValidationPack()
        let defaultShape = try brushTextureResolver.resolve(shape: .hardRound)
        let defaultGrain = try brushTextureResolver.resolve(grain: .opaque)
        self.device = device
        self.commandQueue = commandQueue
        self.library = library
        self.resources = resources
        self.brushTextureResolver = brushTextureResolver
        activeShapeResolution = defaultShape
        activeGrainResolution = defaultGrain
        activeMaterialState = BrushMaterialState(recipe: .legacyEquivalent)
        boundedWashSurface = nil
        lastBoundedWashWorkPlan = nil
        tilingStrategy = try TilingStrategy(
            configuration: configuration.periodicConfiguration,
            canonicalRasterSize: resources.pixelSize
        )
        pipelines = try GridPipelineLibrary(device: device, library: library)
        instancePool = try DabInstanceBufferPool(device: device)
        revisionStore = RasterRevisionStore(device: device)
        viewport = ViewportTransform(
            drawableSize: drawableSize,
            worldCenter: WorldPoint(
                x: resources.tileSize.width * 0.5,
                y: resources.tileSize.height * 0.5
            ),
            zoom: 1
        )
        completedUploadRanges.reserveCapacity(
            GridCanvasContract.inFlightBufferCount
        )
        super.init()
        try clearInitialTextures()
    }

    public func applyTiling(_ tiling: TilingKind) throws {
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
        tilingStrategy = proposed
    }

    public func setTiling(_ tiling: TilingKind) throws {
        try applyTiling(tiling)
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

        counters = GridStructuralCounters()
        resetLiveState()
        activeShapeResolution = try brushTextureResolver.resolve(
            shape: style.recipe.shape
        )
        activeGrainResolution = try brushTextureResolver.resolve(
            grain: style.recipe.grain
        )
        activeMaterialState = BrushMaterialState(recipe: style.recipe)
        if style.recipe.material.family == .boundedWash {
            do {
                if boundedWashSurface?.pixelSize != pixelSize {
                    boundedWashSurface = try BoundedWashSurface(
                        device: device,
                        pixelSize: pixelSize
                    )
                }
            } catch {
                throw MetalRendererError.boundedWashSurfaceAllocationFailed
            }
        }
        let generatorColor: InkColor
        switch style.compositeMode {
        case .draw:
            generatorColor = style.color
        case .erase:
            generatorColor = InkColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 1
            )!
        }
        strokeGenerator = BrushStrokeGenerator(
            recipe: style.recipe,
            nominalDiameter: style.diameter,
            color: generatorColor,
            seed: style.seed
        )
        transientStrokeBuffer = TransientStrokeBuffer(
            replayContract: style.recipe.replayContract
        )
        activeStroke = ActiveStrokeExecution(
            token: token,
            style: style,
            commitRequested: false,
            pendingRevisions: nil,
            pendingTokenBearingFrameCount: 0
        )
        do {
            counters.newDabsThisEvent = 0
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
                generatorSnapshot: generator,
                isFinishing: false
            )
        } catch {
            activeStroke = nil
            resetLiveState()
            throw error
        }
    }

    public func appendStroke(
        token: RendererOperationToken,
        sample: StrokeSample
    ) throws {
        if sample.kind == .predicted {
            let suffix = [sample]
            try replacePredictedStrokeSuffix(
                token: token,
                samples: suffix[...]
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

    private func replacePredictedStrokeSuffix(
        token: RendererOperationToken,
        samples: ArraySlice<StrokeSample>
    ) throws {
        precondition(!samples.isEmpty)
        precondition(samples.allSatisfy { $0.kind == .predicted })
        guard samples.allSatisfy({ $0.phase == .moved }) else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        try requireCollectingStroke(token: token)
        guard let authoritativeGenerator = strokeGenerator,
              var updatedBuffer = transientStrokeBuffer
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let limits = updatedBuffer.activeReplayLimits
        guard samples.count <= limits.maximumSamples else {
            throw MetalRendererError.strokeSampleCapacityExceeded(
                limits.maximumSamples
            )
        }

        var previewDeriver = brushInputDeriver
        var previewGenerator = authoritativeGenerator
        var preparedChunks: [TransientStrokeChunk] = []
        var preparedDabsByChunk: [[PreparedGeneratedDab]] = []
        var generatedDabCount = 0
        var projectedInstanceCount = 0
        preparedChunks.reserveCapacity(samples.count)
        preparedDabsByChunk.reserveCapacity(samples.count)

        for sample in samples {
            let worldSample = previewDeriver.deriveAdvancingPrediction(
                sample,
                viewport: viewport
            )
            let prepared = try prepareGeneratedDabs(
                generator: &previewGenerator
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
                $0 + $1.projected.count
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
            preparedChunks.append(
                TransientStrokeChunk(
                    sample: worldSample,
                    dabs: prepared.map(\.transient),
                    generatorSnapshotAfterSample: previewGenerator
                )
            )
            preparedDabsByChunk.append(prepared)
        }

        let update = try updatedBuffer.replacePredicted(
            with: preparedChunks
        )
        try preflightSettledAppend(update.settledPrefix)

        transientStrokeBuffer = updatedBuffer
        try appendSettled(update.settledPrefix)
        try rebuildReplayLayer(
            preparedPredictedSuffix: preparedDabsByChunk
        )
        predictedInputDeriver = previewDeriver
        predictedStrokeGenerator = previewGenerator
        counters.newDabsThisEvent = generatedDabCount
        counters.totalDabsThisStroke += generatedDabCount
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

        predictedInputDeriver = nil
        predictedStrokeGenerator = nil
        let worldSample = brushInputDeriver.derive(sample, viewport: viewport)
        var generator = authoritativeGenerator
        let dabs = try prepareGeneratedDabs(generator: &generator) {
            generator, emit in
            try generator.append(worldSample, emit: emit)
        }
        strokeGenerator = generator
        try ingestGeneratedSample(
            worldSample,
            dabs: dabs,
            generatorSnapshot: generator,
            isFinishing: false
        )
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
            counters.newDabsThisEvent = 0
            let worldSample = brushInputDeriver.derive(
                sample,
                viewport: viewport
            )
            guard var generator = strokeGenerator else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            let dabs = try prepareGeneratedDabs(generator: &generator) {
                generator, emit in
                try generator.finish(worldSample, emit: emit)
            }
            strokeGenerator = generator
            try ingestGeneratedSample(
                worldSample,
                dabs: dabs,
                generatorSnapshot: generator,
                isFinishing: true
            )
            try prepareCurrentStrokeCommit(
                maximumRetainedBytes: maximumRetainedBytes
            )
        } catch {
            discardPendingRevisionsIfPossible()
            activeStroke = nil
            resetLiveState()
            throw error
        }
    }

    public func cancelStroke(token: RendererOperationToken) throws {
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        try requireCollectingStroke(token: token)
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
        try validateTileSize(revision.pixelSize)
        guard revision.regions == fullRasterRegions(for: revision.pixelSize) else {
            throw MetalRendererError.commandFailed(
                "Resize restore requires a full-raster revision."
            )
        }

        let replacement = try Self.makeRasterResources(
            device: device,
            pixelSize: revision.pixelSize,
            initialRevision: canonical.revision,
            forceAllocationFailure: false
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }

        let restoreToken: RasterRevisionOperationToken
        do {
            try encodeTransparentClear(
                of: replacement.canonical.front,
                on: commandBuffer,
                label: "Resize Restore Front Clear"
            )
            try encodeTransparentClear(
                of: replacement.canonical.scratch,
                on: commandBuffer,
                label: "Resize Restore Scratch Clear"
            )
            try encodeTransparentClear(
                of: replacement.liveTile.texture,
                on: commandBuffer,
                label: "Resize Restore Live Clear"
            )
            restoreToken = try revisionStore.encodeRestore(
                revision,
                into: replacement.canonical.scratch,
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

        let beforeRegions = fullRasterRegions(for: pixelSize)
        let afterRegions = fullRasterRegions(for: newPixelSize)
        let beforeBytes = try revisionStore.retainedBytes(
            pixelSize: pixelSize,
            regions: beforeRegions
        )
        let afterBytes = try revisionStore.retainedBytes(
            pixelSize: newPixelSize,
            regions: afterRegions
        )
        let (pairBytes, overflow) = beforeBytes.addingReportingOverflow(
            afterBytes
        )
        guard !overflow, pairBytes <= maximumRetainedBytes else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }

        let replacement = try Self.makeRasterResources(
            device: device,
            pixelSize: newPixelSize,
            initialRevision: canonical.revision,
            forceAllocationFailure: forceResourceAllocationFailure
        )
        let revisions = try revisionStore.allocatePair(
            beforePixelSize: pixelSize,
            beforeRegions: beforeRegions,
            afterPixelSize: newPixelSize,
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
                of: replacement.canonical.front,
                on: commandBuffer,
                label: "Resize Front Clear"
            )
            try encodeTransparentClear(
                of: replacement.canonical.scratch,
                on: commandBuffer,
                label: "Resize Scratch Clear"
            )
            try encodeTransparentClear(
                of: replacement.liveTile.texture,
                on: commandBuffer,
                label: "Resize Live Clear"
            )
            try encodeResizeIntersectionCopy(
                from: canonical.front,
                oldPixelSize: pixelSize,
                to: replacement.canonical.scratch,
                newPixelSize: newPixelSize,
                on: commandBuffer
            )
            captureTokens.append(
                try revisionStore.encodeCapture(
                    revisions.after,
                    from: replacement.canonical.scratch,
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
                    maxX: pixelSize.width,
                    maxY: pixelSize.height
                )!,
            ],
            clippedTo: pixelSize
        )
        let oneRevisionBytes = try revisionStore.retainedBytes(
            pixelSize: pixelSize,
            regions: fullRegion
        )
        let (pairBytes, overflow) = oneRevisionBytes.multipliedReportingOverflow(
            by: 2
        )
        guard !overflow, pairBytes <= maximumRetainedBytes else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }

        let revisions = try revisionStore.allocatePair(
            beforePixelSize: pixelSize,
            beforeRegions: fullRegion,
            afterPixelSize: pixelSize,
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
        guard revision.pixelSize == pixelSize else {
            throw MetalRendererError.rasterRevisionTextureSizeMismatch(
                expectedWidth: pixelSize.width,
                expectedHeight: pixelSize.height,
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
        guard let activeStroke else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard activeStroke.token == token else {
            throw MetalRendererError.invalidRendererOperationToken
        }
        guard
            !activeStroke.commitRequested,
            activeStroke.pendingRevisions == nil
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
    }

    func prepareCurrentStrokeCommit(
        maximumRetainedBytes: Int
    ) throws {
        guard var execution = activeStroke else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard
            !execution.commitRequested,
            execution.pendingRevisions == nil
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard maximumRetainedBytes >= 0 else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }

        let settledRegions = liveStroke.dirtyRegions(clippedTo: pixelSize)
        let replayRegions = replayStroke.dirtyRegions(clippedTo: pixelSize)
        var regions = PixelRegionSet(
            settledRegions.rectangles + replayRegions.rectangles,
            clippedTo: pixelSize
        )
        if activeMaterialState.family == .boundedWash {
            let washRegions = boundedWashHistoryRegions
            regions = PixelRegionSet(
                regions.rectangles + washRegions.rectangles,
                clippedTo: pixelSize
            )
        }
        let oneRevisionBytes = try revisionStore.retainedBytes(
            pixelSize: pixelSize,
            regions: regions
        )
        let (pairBytes, overflow) = oneRevisionBytes.multipliedReportingOverflow(
            by: 2
        )
        guard !overflow, pairBytes <= maximumRetainedBytes else {
            throw MetalRendererError.rasterRevisionStorageLimitExceeded
        }

        let pair = try revisionStore.allocatePair(
            beforePixelSize: pixelSize,
            beforeRegions: regions,
            afterPixelSize: pixelSize,
            afterRegions: regions
        )
        precondition(
            pair.retainedBytes == pairBytes,
            "Raster revision preflight and allocation must agree."
        )
        execution.commitRequested = true
        execution.pendingRevisions = pair
        activeStroke = execution
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
        let token = RendererOperationToken(rawValue: nextHarnessTokenRawValue)
        nextHarnessTokenRawValue &+= 1
        if nextHarnessTokenRawValue == 0 {
            nextHarnessTokenRawValue = 1
        }
        let style = StrokeRenderStyle(
            color: .black,
            diameter: radius * 2,
            compositeMode: .draw,
            eraserStrength: 1
        )
        resetLiveState()
        strokeGenerator = BrushStrokeGenerator(
            recipe: style.recipe,
            nominalDiameter: style.diameter,
            color: style.color,
            seed: style.seed
        )
        activeShapeResolution = try brushTextureResolver.resolve(
            shape: style.recipe.shape
        )
        activeGrainResolution = try brushTextureResolver.resolve(
            grain: style.recipe.grain
        )
        activeMaterialState = BrushMaterialState(recipe: style.recipe)
        activeStroke = ActiveStrokeExecution(
            token: token,
            style: style,
            commitRequested: false,
            pendingRevisions: nil,
            pendingTokenBearingFrameCount: 0
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

    public func resize(to size: PatternSize) {
        viewport = viewport.resized(to: size)
    }

    public func setInteractiveGridVisibility(_ visible: Bool) {
        interactiveGridVisibility = visible
    }

    public func draw(in view: MTKView) {
        _ = drainRasterOperationOutcomes()
        drainFrameOutcomes()
        drainCompletedUploadRanges()

        guard let drawable = view.currentDrawable else {
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            failActiveOperationIfNeeded(.commandBufferUnavailable)
            return
        }

        var uploads: [FrameUpload] = []
        var rasterCommit: EncodedRasterCommit?
        do {
            let hasEarlierPendingUploads = !completedUploadRanges.isEmpty
            let encodedLiveClear = needsLiveClear
            if encodedLiveClear {
                try encodeLiveClear(commandBuffer)
            }
            let liveEncoding = try encodePendingLiveDabs(commandBuffer)
            uploads = liveEncoding.uploads
            let encodedReplayClear = liveEncoding.encodedReplayClear
            let plannedSettledThrough = uploads.last {
                $0.layer == .settled
            }?.throughExclusive ?? liveStroke.bakedHighWater
            let plannedReplayThrough = uploads.last {
                $0.layer == .replay
            }?.throughExclusive ?? replayStroke.bakedHighWater
            let shouldEncodeCommit = activeStroke?.commitRequested == true
                && plannedSettledThrough == liveStroke.emittedHighWater
                && plannedReplayThrough == replayStroke.emittedHighWater
                && !hasEarlierPendingUploads
                && activeStroke?.pendingTokenBearingFrameCount == 0
            if shouldEncodeCommit {
                rasterCommit = try encodeCommit(
                    commandBuffer,
                    liveVisible: liveTile.isVisible
                        || replayTile.isVisible || !uploads.isEmpty
                )
            }
            try encodeDisplay(
                into: drawable.texture,
                commandBuffer: commandBuffer,
                showGridLines: interactiveGridVisibility,
                liveVisible: liveTile.isVisible
                    || replayTile.isVisible || !uploads.isEmpty
            )
            _ = try finalizeFrameEncoding(
                encodedClear: encodedLiveClear,
                encodedReplayClear: encodedReplayClear,
                uploads: uploads,
                rasterCommit: rasterCommit,
                commandBuffer: commandBuffer
            )
            #if DEBUG && os(macOS)
            let targetFramesPerSecond = max(1, view.preferredFramesPerSecond)
            let fallbackPresentationTimestamp =
                ProcessInfo.processInfo.systemUptime
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
            #endif
            commandBuffer.present(drawable)
            if activeStroke != nil {
                counters.renderedFramesThisStroke += 1
            }
            commandBuffer.commit()
        } catch let error as MetalRendererError {
            abandon(uploads)
            abandon(rasterCommit)
            failActiveOperationIfNeeded(error)
        } catch {
            abandon(uploads)
            abandon(rasterCommit)
            failActiveOperationIfNeeded(
                .commandFailed(error.localizedDescription)
            )
        }
    }

    #if DEBUG && os(macOS)
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
        dabs: [PreparedGeneratedDab],
        generatorSnapshot: BrushStrokeGenerator,
        isFinishing: Bool
    ) throws {
        guard var buffer = transientStrokeBuffer else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        counters.newDabsThisEvent += dabs.count
        counters.totalDabsThisStroke += dabs.count
        let transientDabs = dabs.map(\.transient)
        let chunk = TransientStrokeChunk(
            sample: sample,
            dabs: transientDabs,
            generatorSnapshotAfterSample: generatorSnapshot
        )

        if sample.kind == .predicted {
            let predicted = buffer.predictedChunks + [chunk]
            _ = try buffer.replacePredicted(with: predicted)
            transientStrokeBuffer = buffer
            try rebuildReplayLayer(
                preparedPredictedSuffix: [dabs]
            )
            return
        }

        let update = buffer.appendActual(chunk)
        transientStrokeBuffer = buffer
        if buffer.mode == .appendOnly,
           update.settledPrefix.count == 1,
           update.settledPrefix[0].dabs == transientDabs
        {
            var projected: [ProjectedDabRecord] = []
            projected.reserveCapacity(
                dabs.reduce(0) { $0 + $1.projected.count }
            )
            for dab in dabs {
                projected.append(contentsOf: dab.projected)
            }
            try appendSettledRecords(projected)
        } else {
            try appendSettled(update.settledPrefix)
        }

        if isFinishing {
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
            try rebuildReplayLayer(
                preparedActualTail: buffer.mode == .appendOnly || isFinishing
                    ? nil
                    : dabs
            )
        }
    }

    private func appendSettled(
        _ chunks: [TransientStrokeChunk]
    ) throws {
        try preflightSettledAppend(chunks)
        var records: [ProjectedDabRecord] = []
        for chunk in chunks {
            for dab in chunk.dabs {
                records.append(
                    contentsOf: try projectedRecords(for: dab.attributes)
                )
            }
        }
        try appendSettledRecords(records)
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
        guard projectedCount <= liveStroke.capacity - liveStroke.pending.count
        else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                liveStroke.capacity
            )
        }
    }

    private func appendSettledRecords(
        _ records: [ProjectedDabRecord]
    ) throws {
        guard records.count <= liveStroke.capacity - liveStroke.pending.count
        else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                liveStroke.capacity
            )
        }
        if activeMaterialState.family == .boundedWash,
           let boundedWashSurface,
           !records.isEmpty
        {
            let plan = try boundedWashSurface.makeWorkPlan(
                dirtyRegions: records.map(\.dirtyRect),
                bleedRadius: activeMaterialState.bleedRadius,
                softenPasses: Int(activeMaterialState.softenPasses)
            )
            lastBoundedWashWorkPlan = plan
            accumulateBoundedWashHistory(plan.processingRegions)
        }
        try append(records, to: &liveStroke)
    }

    private func prepareGeneratedDabs(
        generator: inout BrushStrokeGenerator,
        generate: (
            inout BrushStrokeGenerator,
            (DabAttributes) throws -> Void
        ) throws -> Void
    ) throws -> [PreparedGeneratedDab] {
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
        var prepared: [PreparedGeneratedDab] = []
        prepared.reserveCapacity(min(64, maximumDabs))
        var projectedCount = 0
        try generate(&generator) { dab in
            guard prepared.count < maximumDabs else {
                throw MetalRendererError.generatedDabCapacityExceeded(
                    maximumDabs
                )
            }
            let projected = try projectedRecords(for: dab)
            let (nextCount, overflow) = projectedCount.addingReportingOverflow(
                projected.count
            )
            guard !overflow, nextCount <= maximumProjected else {
                throw MetalRendererError.projectedInstanceCapacityExceeded(
                    maximumProjected
                )
            }
            projectedCount = nextCount
            prepared.append(
                PreparedGeneratedDab(
                    attributes: dab,
                    projected: projected
                )
            )
        }
        return prepared
    }

    private func rebuildReplayLayer(
        preparedActualTail: [PreparedGeneratedDab]? = nil,
        preparedPredictedSuffix: [[PreparedGeneratedDab]] = []
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
        let priorRegions = replayStroke.dirtyRegions(clippedTo: pixelSize)
        var replacementRecords: [ProjectedDabRecord] = []
        replacementRecords.reserveCapacity(
            min(
                buffer.visibleProjectedInstanceCount,
                TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity
            )
        )
        func appendReplayChunks(
            _ chunks: [TransientStrokeChunk],
            preparedSuffix: [[PreparedGeneratedDab]] = []
        ) throws {
            let preparedStart = chunks.count - preparedSuffix.count
            precondition(preparedStart >= 0)
            for (index, chunk) in chunks.enumerated() {
                if knownStrokeTotalDistance == nil,
                   index >= preparedStart
                {
                    let prepared = preparedSuffix[index - preparedStart]
                    precondition(
                        prepared.map(\.transient) == chunk.dabs,
                        "Prepared replay projection diverged from its chunk."
                    )
                    for dab in prepared {
                        replacementRecords.append(
                            contentsOf: dab.projected
                        )
                    }
                    continue
                }
                for transientDab in chunk.dabs {
                    let attributes: DabAttributes
                    if let totalDistance = knownStrokeTotalDistance {
                        attributes = BrushDynamicsEngine()
                            .applyingKnownTotalDistance(
                                transientDab.attributes,
                                totalDistance: totalDistance,
                                nominalDiameter: activeStroke.style.diameter,
                                recipe: activeStroke.style.recipe,
                                retainedReplayStartDistance:
                                    retainedReplayStartDistance
                            )
                    } else {
                        attributes = transientDab.attributes
                    }
                    replacementRecords.append(
                        contentsOf: try projectedRecords(for: attributes)
                    )
                }
            }
        }
        try appendReplayChunks(
            buffer.actualChunks,
            preparedSuffix: preparedActualTail.map { [$0] } ?? []
        )
        try appendReplayChunks(
            buffer.predictedChunks,
            preparedSuffix: preparedPredictedSuffix
        )
        guard replacementRecords.count
            <= TransientStrokeBufferContract
                .visibleEpochProjectedInstanceCapacity
        else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity
            )
        }
        let replacementRegions = PixelRegionSet(
            replacementRecords.map(\.dirtyRect),
            clippedTo: pixelSize
        )
        if activeStroke.style.recipe.material.family == .boundedWash,
           let boundedWashSurface
        {
            let plan = try boundedWashSurface.makeWorkPlan(
                dirtyRegions: replacementRegions.rectangles,
                bleedRadius: activeStroke.style.recipe.material.bleedRadius,
                softenPasses: activeStroke.style.recipe.material.softenPasses
            )
            lastBoundedWashWorkPlan = plan
            accumulateBoundedWashHistory(plan.processingRegions)
        } else {
            lastBoundedWashWorkPlan = nil
        }
        let epoch = takeReplayEpoch()
        _ = replayTile.planReplacement(
            epoch: epoch,
            prior: priorRegions,
            replacement: replacementRegions
        )
        replayStroke.beginReplacementEpoch(epoch)
        try append(replacementRecords, to: &replayStroke)
        needsReplayClear = true
    }

    private func append(
        _ records: [ProjectedDabRecord],
        to stroke: inout LiveStroke
    ) throws {
        for record in records {
            try stroke.append(record.instance, dirtyRect: record.dirtyRect)
            counters.totalInstancesThisStroke += 1
        }
    }

    private func projectedRecords(
        for dab: DabAttributes
    ) throws -> [ProjectedDabRecord] {
        guard let activeStroke else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let minimumAffineScale = min(
            simd_length(dab.brushToWorld.xAxis),
            simd_length(dab.brushToWorld.yAxis)
        )
        guard minimumAffineScale.isFinite, minimumAffineScale > 0 else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let footprint = StampFootprint(
            brushToWorld: dab.brushToWorld,
            localBounds: AxisAlignedRect(
                minimum: SIMD2(-1, -1),
                maximum: SIMD2(1, 1)
            ),
            coverageSymmetry:
                activeStroke.style.recipe.footprintCoverageSymmetry
        )
        let color = InkColor(
            red: dab.color.red,
            green: dab.color.green,
            blue: dab.color.blue,
            alpha: dab.color.alpha * dab.flow * dab.materialContribution
        )!
        let brushAttributes = SIMD4(
            dab.hardness,
            dab.grainScale,
            dab.grainOffset.x,
            dab.grainOffset.y
        )
        return TilingProjection.fragments(
            for: footprint,
            using: tilingStrategy
        ).map { fragment in
            ProjectedDabRecord(
                instance: PatternProjectedStampInstance(
                    fragment: fragment,
                    radius: minimumAffineScale,
                    color: color,
                    brushAttributes: brushAttributes
                ),
                dirtyRect: TilingProjection.dirtyPixelRect(
                    for: fragment,
                    radius: minimumAffineScale
                )
            )
        }
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
        let footprint = StampFootprint(
            brushToWorld: Affine2D(
                xAxis: SIMD2(radius, 0),
                yAxis: SIMD2(0, radius),
                translation: point.simd
            ),
            localBounds: AxisAlignedRect(
                minimum: SIMD2(-1, -1),
                maximum: SIMD2(1, 1)
            ),
            coverageSymmetry: coverageSymmetry
        )
        return try appendProjectedFragments(
            footprint: footprint,
            radius: radius,
            color: color(for: activeStroke.style),
            brushAttributes: SIMD4(1, 1, 0, 0)
        )
    }

    private func appendProjectedFragments(
        footprint: StampFootprint,
        radius: Float,
        color: InkColor,
        brushAttributes: SIMD4<Float>
    ) throws -> [CellFragment] {
        let fragments = TilingProjection.fragments(
            for: footprint,
            using: tilingStrategy
        )
        for fragment in fragments {
            let instance = PatternProjectedStampInstance(
                fragment: fragment,
                radius: radius,
                color: color,
                brushAttributes: brushAttributes
            )
            try liveStroke.append(
                instance,
                dirtyRect: TilingProjection.dirtyPixelRect(
                    for: fragment,
                    radius: radius
                )
            )
            counters.totalInstancesThisStroke += 1
        }
        return fragments
    }

    private func color(for style: StrokeRenderStyle) -> InkColor {
        switch style.compositeMode {
        case .draw:
            style.color
        case .erase:
            InkColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 1
            )!
        }
    }

    func frameUniforms(
        drawableSize: PatternSize,
        showGridLines: Bool,
        liveVisible: Bool,
        diagnosticMode: UInt32 = PatternDiagnosticWireNone
    ) -> PatternGridFrameUniforms {
        let compositeMode = activeStroke?.style.compositeMode.rawValue
            ?? PatternCompositeWireDraw
        let periodic = tilingStrategy.compiledSymmetry.domain.periodic!
        let worldToLattice = periodic.worldToLattice
        let displayRepeatSize =
            tilingStrategy.compiledSymmetry.family == .triangular
            ? SIMD2(
                simd_length(periodic.translationBasis.u),
                simd_length(periodic.translationBasis.v)
            )
            : periodic.configuration.repeatSize.simd
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
            padding2: 0
        )
    }

    private var compositeMaterialUniforms: PatternBrushMaterialUniforms {
        var uniforms = activeMaterialState.uniforms
        if activeStroke?.style.compositeMode == .erase {
            uniforms.materialStrength = activeStroke?.style.eraserStrength ?? 1
        }
        return uniforms
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
            width: pixelSize.width,
            height: pixelSize.height
        )
        let bytesPerRow = pixelSize.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count: bytesPerRow * pixelSize.height
        )
        for y in 0..<pixelSize.height {
            for x in 0..<pixelSize.width {
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
                    pixelSize.width,
                    pixelSize.height
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
                width: pixelSize.width,
                height: pixelSize.height,
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
        let plan = replayTile.lastClearPlan
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = replayTile.texture
        pass.colorAttachments[0].storeAction = .store
        switch plan {
        case .regional:
            pass.colorAttachments[0].loadAction = .load
        case .fullTile, nil:
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }
        encoder.label = "Clear Replay Live Stroke"
        if case let .regional(regions) = plan {
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
            for rectangle in regions.rectangles {
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
        instances: ArraySlice<IdentifiedDab>,
        texture: any MTLTexture,
        layer: FrameUpload.Layer
    ) throws {
        if activeMaterialState.family == .boundedWash {
            try encodeBoundedWash(
                commandBuffer,
                lease: lease,
                count: count,
                instances: instances,
                destination: texture,
                layer: layer
            )
            return
        }
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
        encoder.setRenderPipelineState(pipelines.stamp)
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
        encoder.setFragmentTexture(
            activeShapeTexture,
            index: Int(PatternTextureIndexBrushShape)
        )
        encoder.setFragmentTexture(
            activeGrainTexture,
            index: Int(PatternTextureIndexBrushGrain)
        )
        var materialUniforms = activeMaterialState.uniforms
        encoder.setFragmentBytes(
            &materialUniforms,
            length: MemoryLayout<PatternBrushMaterialUniforms>.stride,
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

    private func encodeBoundedWash(
        _ commandBuffer: any MTLCommandBuffer,
        lease: DabInstanceBufferPool.Lease,
        count: Int,
        instances: ArraySlice<IdentifiedDab>,
        destination: any MTLTexture,
        layer: FrameUpload.Layer
    ) throws {
        guard let surface = boundedWashSurface else {
            throw MetalRendererError.boundedWashSurfaceAllocationFailed
        }
        let dirty = instances.compactMap {
            boundedWashDirtyRect(for: $0.instance)
        }
        let plan = try surface.makeWorkPlan(
            dirtyRegions: dirty,
            bleedRadius: activeMaterialState.bleedRadius,
            softenPasses: Int(activeMaterialState.softenPasses)
        )
        guard !plan.processingRegions.rectangles.isEmpty else { return }
        let regionMetadata = try surface.prepareProcessingRegions(
            plan.processingRegions,
            slot: lease.slot
        )
        lastBoundedWashWorkPlan = plan

        try encodeWashRegionalPass(
            commandBuffer,
            pipeline: pipelines.washClear,
            destination: surface.depositTexture,
            source: nil,
            regions: plan.processingRegions,
            regionMetadata: nil,
            label: "Clear Bounded Wash Deposit"
        )
        try encodeWashDeposit(
            commandBuffer,
            lease: lease,
            count: count,
            destination: surface.depositTexture,
            layer: layer
        )

        var source = surface.depositTexture
        if plan.softenPasses > 0 {
            for passIndex in 0..<plan.softenPasses {
                let target = passIndex.isMultiple(of: 2)
                    ? surface.scratchTexture
                    : surface.depositTexture
                try encodeWashRegionalPass(
                    commandBuffer,
                    pipeline: pipelines.washSoften,
                    destination: target,
                    source: source,
                    regions: plan.processingRegions,
                    regionMetadata: regionMetadata,
                    label: "Bounded Wash Soften \(passIndex + 1)"
                )
                source = target
            }
        }
        try encodeWashRegionalPass(
            commandBuffer,
            pipeline: pipelines.washResolve,
            destination: destination,
            source: source,
            regions: plan.processingRegions,
            regionMetadata: nil,
            label: layer == .settled
                ? "Resolve Bounded Wash To Settled Live"
                : "Resolve Bounded Wash To Replay Live"
        )
        boundedWashEncodedWork.record(plan)
    }

    private var boundedWashHistoryRegions: PixelRegionSet {
        boundedWashHistory.regions(pixelSize: pixelSize)
    }

    private func accumulateBoundedWashHistory(
        _ regions: PixelRegionSet
    ) {
        boundedWashHistory.record(regions, pixelSize: pixelSize)
    }

    private func boundedWashDirtyRect(
        for instance: PatternProjectedStampInstance
    ) -> PixelRect? {
        let radius = instance.radius
        guard radius.isFinite, radius > 0 else { return nil }
        let expansion = 1 + 1 / radius
        let extent = (
            abs(instance.canonicalXAxis) + abs(instance.canonicalYAxis)
        ) * expansion
        return PixelRect(
            minX: Int(floor(instance.canonicalTranslation.x - extent.x)),
            minY: Int(floor(instance.canonicalTranslation.y - extent.y)),
            maxX: Int(ceil(instance.canonicalTranslation.x + extent.x)),
            maxY: Int(ceil(instance.canonicalTranslation.y + extent.y))
        )
    }

    private func encodeWashDeposit(
        _ commandBuffer: any MTLCommandBuffer,
        lease: DabInstanceBufferPool.Lease,
        count: Int,
        destination: any MTLTexture,
        layer: FrameUpload.Layer
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }
        encoder.label = layer == .settled
            ? "Deposit Bounded Wash Settled Dabs"
            : "Deposit Bounded Wash Replay Dabs"
        encoder.setRenderPipelineState(pipelines.washDeposit)
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
        encoder.setFragmentTexture(
            activeShapeTexture,
            index: Int(PatternTextureIndexBrushShape)
        )
        encoder.setFragmentTexture(
            activeGrainTexture,
            index: Int(PatternTextureIndexBrushGrain)
        )
        var material = activeMaterialState.uniforms
        encoder.setFragmentBytes(
            &material,
            length: MemoryLayout<PatternBrushMaterialUniforms>.stride,
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

    private func encodeWashRegionalPass(
        _ commandBuffer: any MTLCommandBuffer,
        pipeline: any MTLRenderPipelineState,
        destination: any MTLTexture,
        source: (any MTLTexture)?,
        regions: PixelRegionSet,
        regionMetadata: (buffer: any MTLBuffer, count: Int)?,
        label: String
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }
        encoder.label = label
        encoder.setRenderPipelineState(pipeline)
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
        if let source {
            encoder.setFragmentTexture(
                source,
                index: Int(PatternTextureIndexCanonical)
            )
        }
        if let regionMetadata {
            encoder.setFragmentBuffer(
                regionMetadata.buffer,
                offset: 0,
                index: Int(PatternBufferIndexDabInstances)
            )
        }
        var material = activeMaterialState.uniforms
        material.padding1 = UInt32(regionMetadata?.count ?? 0)
        encoder.setFragmentBytes(
            &material,
            length: MemoryLayout<PatternBrushMaterialUniforms>.stride,
            index: Int(PatternBufferIndexBrushMaterial)
        )
        for rectangle in regions.rectangles {
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
                length: MemoryLayout<PatternBrushMaterialUniforms>.stride,
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
        canonicalTexture: (any MTLTexture)? = nil
    ) throws {
        guard texture.width > 0, texture.height > 0 else {
            throw MetalRendererError.invalidDrawableSize
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
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
        let usesTriangularDisplay =
            tilingStrategy.compiledSymmetry.family == .triangular
        encoder.label = usesTriangularDisplay
            ? "Triangular Grid Display"
            : "Grid Display"
        encoder.setRenderPipelineState(
            usesTriangularDisplay
                ? pipelines.triangularDisplay
                : pipelines.display
        )
        var uniforms = frameUniforms(
            drawableSize: PatternSize(
                width: Float(texture.width),
                height: Float(texture.height)
            ),
            showGridLines: showGridLines,
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
            length: MemoryLayout<PatternBrushMaterialUniforms>.stride,
            index: Int(PatternBufferIndexBrushMaterial)
        )
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
            replayTile.markCleared(epoch: replayStroke.renderEpoch)
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
        counters.newInstancesThisFrame = uploads.reduce(0) {
            $0 + $1.count
        }
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

        let submittedOperationToken: RendererOperationToken?
        if let rasterCommit {
            submittedOperationToken = rasterCommit.token
        } else if let execution = activeStroke,
                  !execution.isCommitSubmitted,
                  encodedClear || encodedReplayClear || !uploads.isEmpty
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
                operation.replacement.canonical.acceptScratchCommit()
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
                operation.replacement.canonical.acceptScratchCommit()
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

    private func install(_ replacement: RasterResources) {
        let configuration = tilingStrategy.periodicConfiguration
        let replacementStrategy: TilingStrategy
        do {
            replacementStrategy = try TilingStrategy(
                configuration: configuration,
                canonicalRasterSize: replacement.pixelSize
            )
        } catch {
            preconditionFailure(
                "Validated periodic configuration must survive raster resize"
            )
        }
        replacement.liveTile.markCleared()
        replacement.replayTile.markCleared(epoch: 0)
        resources = replacement
        tilingStrategy = replacementStrategy
        needsLiveClear = false
        needsReplayClear = false
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
            let receipt = RasterMutationReceipt(
                token: commit.token,
                before: commit.revisions.before,
                after: commit.revisions.after
            )
            activeStroke = nil
            resetLiveState()
            onOperationCompleted?(.rasterSuccess(receipt))
            return nil
        } catch let error as MetalRendererError {
            finalizeCaptureTokens(commit.captureTokens, as: .failed)
            discardSubmittedPairIfPossible(commit.revisions)
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
        lastBoundedWashWorkPlan = nil
        boundedWashEncodedWork = BoundedWashEncodedWork()
        boundedWashHistory = BoundedWashHistoryAccumulator()
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

    func validateHarnessCommand(
        _ commandBuffer: any MTLCommandBuffer
    ) throws {
        guard commandBuffer.status == .completed else {
            throw MetalRendererError.commandFailed(
                commandBuffer.error?.localizedDescription
                    ?? "unknown command-buffer error"
            )
        }
    }

    func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }

    func metrics(
        commandBuffer: any MTLCommandBuffer,
        cpuMilliseconds: Double
    ) -> GPUFrameMetrics {
        GPUFrameMetrics(
            cpuEncodeMilliseconds: cpuMilliseconds,
            gpuMilliseconds: max(
                0,
                (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
            )
        )
    }
}
