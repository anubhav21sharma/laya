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
    public private(set) var viewport: ViewportTransform
    public private(set) var counters = GridStructuralCounters()
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

    private struct FrameUpload {
        let lease: DabInstanceBufferPool.Lease
        let identityRange: Range<UInt64>
        let throughExclusive: UInt64
        let count: Int
    }

    private struct ActiveStrokeExecution {
        let token: RendererOperationToken
        let style: StrokeRenderStyle
        var commitRequested: Bool
        var pendingRevisions: PendingRasterRevisionPair?
        var pendingTokenBearingFrameCount: Int

        var isCommitSubmitted: Bool {
            !commitRequested && pendingRevisions != nil
        }
    }

    private struct EncodedRasterCommit {
        let token: RendererOperationToken
        let revisions: PendingRasterRevisionPair
        let captureTokens: [RasterRevisionOperationToken]
    }

    private struct RasterResources {
        let pixelSize: PixelSize
        let tileSize: PatternSize
        let canonical: CanonicalRaster
        let liveTile: PersistentLiveTile
    }

    private struct PendingClearOperation {
        let submissionID: UInt64
        let token: RendererOperationToken
        let revisions: PendingRasterRevisionPair
        let captureTokens: [RasterRevisionOperationToken]
        let commandBuffer: any MTLCommandBuffer
    }

    private struct PendingRestoreOperation {
        let submissionID: UInt64
        let token: RendererOperationToken
        let revision: RasterRevisionReference
        let restoreToken: RasterRevisionOperationToken
        let commandBuffer: any MTLCommandBuffer
    }

    private struct PendingResizeOperation {
        let submissionID: UInt64
        let token: RendererOperationToken
        let replacement: RasterResources
        let revisions: PendingRasterRevisionPair
        let captureTokens: [RasterRevisionOperationToken]
        let commandBuffer: any MTLCommandBuffer
    }

    private struct PendingResizeRestoreOperation {
        let submissionID: UInt64
        let token: RendererOperationToken
        let replacement: RasterResources
        let restoreToken: RasterRevisionOperationToken
        let commandBuffer: any MTLCommandBuffer
    }

    private enum PendingRasterOperation {
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

    private let commandQueue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let pipelines: GridPipelineLibrary
    private let instancePool: DabInstanceBufferPool
    private let revisionStore: RasterRevisionStore
    private let completionMailbox = GridRenderCompletionMailbox()
    private let rasterCompletionMailbox = RendererRasterCompletionMailbox()
    private var resources: RasterResources
    private var tileSize: PatternSize { resources.tileSize }
    private var canonical: CanonicalRaster { resources.canonical }
    private var liveTile: PersistentLiveTile { resources.liveTile }
    private var tilingStrategy: TilingStrategy
    private var activeStroke: ActiveStrokeExecution?
    private var pendingRasterOperation: PendingRasterOperation?
    private var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    private var liveStroke = LiveStroke()
    private var completedUploadRanges: [(signal: UInt64, throughExclusive: UInt64)] = []
    private var needsLiveClear = true
    private var nextHarnessTokenRawValue: UInt64 = 1
    private var nextRasterSubmissionID: UInt64 = 1

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
        self.device = device
        self.commandQueue = commandQueue
        self.library = library
        self.resources = resources
        tilingStrategy = TilingStrategy(
            kind: configuration.tiling,
            tileSize: resources.tileSize
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
        guard isIdle else {
            throw MetalRendererError.tilingChangeRequiresIdle
        }
        tilingStrategy = TilingStrategy(
            kind: tiling,
            tileSize: tileSize
        )
    }

    public func setTiling(_ tiling: TilingKind) throws {
        try applyTiling(tiling)
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
        interpolator = CentripetalCatmullRomStrokeInterpolator(
            radius: style.diameter / 2
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
            let world = viewport.screenToWorld(sample.position)
            try interpolator.begin(at: world, emit: appendWorldDab)
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
        guard sample.phase == .moved else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        try requireCollectingStroke(token: token)
        counters.newDabsThisEvent = 0
        let world = viewport.screenToWorld(sample.position)
        try interpolator.append(world, emit: appendWorldDab)
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
            let world = viewport.screenToWorld(sample.position)
            try interpolator.finish(at: world, emit: appendWorldDab)
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

    private func requestResizeRestore(
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

    private func requestResize(
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

    private func requestClear(
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

    private func requestRasterRestore(
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

    private func prepareCurrentStrokeCommit(
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

        let regions = liveStroke.dirtyRegions(clippedTo: pixelSize)
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

    private func beginHarnessExecution(radius: Float) throws {
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
        interpolator = CentripetalCatmullRomStrokeInterpolator(radius: radius)
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
            let encodedClear = needsLiveClear
            if encodedClear {
                try encodeLiveClear(commandBuffer)
            }
            uploads = try encodePendingLiveDabs(commandBuffer)
            let plannedThrough = uploads.last?.throughExclusive
                ?? liveStroke.bakedHighWater
            let shouldEncodeCommit = activeStroke?.commitRequested == true
                && plannedThrough == liveStroke.emittedHighWater
                && !hasEarlierPendingUploads
                && activeStroke?.pendingTokenBearingFrameCount == 0
            if shouldEncodeCommit {
                rasterCommit = try encodeCommit(
                    commandBuffer,
                    liveVisible: liveTile.isVisible || !uploads.isEmpty
                )
            }
            try encodeDisplay(
                into: drawable.texture,
                commandBuffer: commandBuffer,
                showGridLines: interactiveGridVisibility,
                liveVisible: liveTile.isVisible || !uploads.isEmpty
            )
            _ = try finalizeFrameEncoding(
                encodedClear: encodedClear,
                uploads: uploads,
                rasterCommit: rasterCommit,
                commandBuffer: commandBuffer
            )
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

    public func flushPendingLiveForHarness(
        forceFailure: Bool = false
    ) throws -> HarnessLiveFlushResult {
        drainFrameOutcomes()
        drainCompletedUploadRanges()
        try clearLiveForHarnessIfNeeded()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            let error = MetalRendererError.commandBufferUnavailable
            failActiveOperationIfNeeded(error)
            throw error
        }

        var uploads: [FrameUpload] = []
        var submissions: [DabBufferSubmissionIdentity] = []
        var didFinalize = false
        let start = CFAbsoluteTimeGetCurrent()
        do {
            uploads = try encodePendingLiveDabs(commandBuffer)
            submissions = try finalizeFrameEncoding(
                encodedClear: false,
                uploads: uploads,
                rasterCommit: nil,
                commandBuffer: commandBuffer,
                forceFailure: forceFailure
            )
            didFinalize = true
            if activeStroke != nil {
                counters.renderedFramesThisStroke += 1
            }
            let cpuMilliseconds = HarnessSubmissionTiming
                .measureThroughSubmission(
                    since: start,
                    submit: commandBuffer.commit
                )
            commandBuffer.waitUntilCompleted()
            let submittedError = drainFrameOutcomes()
            drainCompletedUploadRanges()
            if let submittedError {
                throw submittedError
            }
            do {
                try validateHarnessCommand(commandBuffer)
            } catch let error as MetalRendererError {
                instancePool.reclaimTerminalFailure(submissions)
                report(error)
                throw error
            }
            return HarnessLiveFlushResult(
                metrics: metrics(
                    commandBuffer: commandBuffer,
                    cpuMilliseconds: cpuMilliseconds
                ),
                emittedHighWater: liveStroke.emittedHighWater,
                encodedIdentityRanges: uploads.map(\.identityRange)
            )
        } catch {
            if !didFinalize {
                abandon(uploads)
                failActiveOperationIfNeeded(
                    (error as? MetalRendererError)
                        ?? .commandFailed(error.localizedDescription)
                )
            }
            throw error
        }
    }

    public func renderOffscreenDisplayForHarness(
        width: Int,
        height: Int,
        showGridLines: Bool
    ) throws -> RenderedFrame {
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw MetalRendererError.invalidDrawableSize
        }
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
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            let error = MetalRendererError.commandBufferUnavailable
            failActiveOperationIfNeeded(error)
            throw error
        }

        let start = CFAbsoluteTimeGetCurrent()
        try encodeDisplay(
            into: texture,
            commandBuffer: commandBuffer,
            showGridLines: showGridLines,
            liveVisible: liveTile.isVisible
        )
        let cpuMilliseconds = elapsedMilliseconds(since: start)
        commandBuffer.commit()
        do {
            try waitForHarnessCommand(commandBuffer)
        } catch let error as MetalRendererError {
            report(error)
            throw error
        }
        return RenderedFrame(
            texture: texture,
            metrics: metrics(
                commandBuffer: commandBuffer,
                cpuMilliseconds: cpuMilliseconds
            )
        )
    }

    func renderDiagnosticFootprintForHarness(
        footprint: StampFootprint,
        radius: Float,
        diagnosticMode: UInt32,
        width: Int,
        height: Int
    ) throws -> HarnessDiagnosticRenderedFrame {
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw MetalRendererError.invalidDrawableSize
        }
        precondition(
            diagnosticMode == PatternDiagnosticWireAsymmetricCoverage
                || diagnosticMode == PatternDiagnosticWireCanonicalCoordinates
                || diagnosticMode == PatternDiagnosticWireBrushLocalCoordinates,
            "Harness diagnostic mode must use a shared nonzero wire value"
        )

        let fragments = TilingProjection.fragments(
            for: footprint,
            using: tilingStrategy
        )
        let instances = fragments.map {
            PatternProjectedStampInstance(fragment: $0, radius: radius)
        }
        guard
            !instances.isEmpty,
            instances.count <= GridCanvasContract.pendingCapacity
        else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                GridCanvasContract.pendingCapacity
            )
        }
        let instanceByteCount =
            instances.count * MemoryLayout<PatternProjectedStampInstance>.stride
        guard let instanceBuffer = device.makeBuffer(
            length: instanceByteCount,
            options: .storageModeShared
        ) else {
            throw MetalRendererError.instanceBufferAllocationFailed
        }
        instances.withUnsafeBytes { bytes in
            instanceBuffer.contents().copyMemory(
                from: bytes.baseAddress!,
                byteCount: bytes.count
            )
        }

        let canonicalTexture = try makeHarnessTexture(
            width: pixelSize.width,
            height: pixelSize.height
        )
        let screenTexture = try makeHarnessTexture(
            width: width,
            height: height
        )
        let displayValidationCanonical =
            try makeHarnessDisplayValidationTexture()
        let displayValidationScreen = try makeHarnessTexture(
            width: width,
            height: height
        )
        let gridLinesScreen = try makeHarnessTexture(
            width: width,
            height: height
        )
        let diagnosticPipeline =
            try GridPipelineLibrary.makeHarnessDiagnosticPipeline(
                device: device,
                library: library
            )
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            let error = MetalRendererError.commandBufferUnavailable
            failActiveOperationIfNeeded(error)
            throw error
        }

        let start = CFAbsoluteTimeGetCurrent()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = canonicalTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }
        encoder.label = "Harness Diagnostic Projected Footprint"
        encoder.setRenderPipelineState(diagnosticPipeline)
        var uniforms = frameUniforms(
            drawableSize: tileSize,
            showGridLines: false,
            liveVisible: false,
            diagnosticMode: diagnosticMode
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
        encoder.setVertexBuffer(
            instanceBuffer,
            offset: 0,
            index: Int(PatternBufferIndexDabInstances)
        )
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: instances.count
        )
        encoder.endEncoding()

        try encodeDisplay(
            into: screenTexture,
            commandBuffer: commandBuffer,
            showGridLines: false,
            liveVisible: false,
            canonicalTexture: canonicalTexture
        )
        try encodeDisplay(
            into: displayValidationScreen,
            commandBuffer: commandBuffer,
            showGridLines: false,
            liveVisible: false,
            canonicalTexture: displayValidationCanonical
        )
        try encodeDisplay(
            into: gridLinesScreen,
            commandBuffer: commandBuffer,
            showGridLines: true,
            liveVisible: false,
            canonicalTexture: displayValidationCanonical
        )
        let cpuMilliseconds = elapsedMilliseconds(since: start)
        commandBuffer.commit()
        do {
            try waitForHarnessCommand(commandBuffer)
        } catch let error as MetalRendererError {
            report(error)
            throw error
        }
        return HarnessDiagnosticRenderedFrame(
            canonical: canonicalTexture,
            screen: screenTexture,
            displayValidationCanonical: displayValidationCanonical,
            displayValidationScreen: displayValidationScreen,
            gridLinesScreen: gridLinesScreen,
            fragments: fragments,
            metrics: metrics(
                commandBuffer: commandBuffer,
                cpuMilliseconds: cpuMilliseconds
            )
        )
    }

    public func finishCommitForHarness() throws -> GPUFrameMetrics {
        let metrics = try submitCommitForHarness()
        try drainCompletedOperationsForHarness()
        return metrics
    }

    func requestRasterRestoreForHarness(
        token: RendererOperationToken,
        revision: RasterRevisionReference,
        forceFailure: Bool
    ) throws {
        try requestRasterRestore(
            token: token,
            revision: revision,
            forceFailure: forceFailure
        )
    }

    func requestClearForHarness(
        token: RendererOperationToken,
        maximumRetainedBytes: Int,
        forceFailure: Bool
    ) throws {
        try requestClear(
            token: token,
            maximumRetainedBytes: maximumRetainedBytes,
            forceFailure: forceFailure
        )
    }

    func requestResizeForHarness(
        token: RendererOperationToken,
        to pixelSize: PixelSize,
        maximumRetainedBytes: Int,
        forceResourceAllocationFailure: Bool,
        forceCommandFailure: Bool = false
    ) throws {
        try requestResize(
            token: token,
            to: pixelSize,
            maximumRetainedBytes: maximumRetainedBytes,
            forceResourceAllocationFailure: forceResourceAllocationFailure,
            forceCommandFailure: forceCommandFailure
        )
    }

    func requestResizeRestoreForHarness(
        token: RendererOperationToken,
        revision: RasterRevisionReference,
        forceCommandFailure: Bool
    ) throws {
        try requestResizeRestore(
            token: token,
            revision: revision,
            forceCommandFailure: forceCommandFailure
        )
    }

    public func finishRasterOperationForHarness() throws {
        guard let operation = pendingRasterOperation else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        operation.commandBuffer.waitUntilCompleted()
        if let error = drainRasterOperationOutcomes() {
            throw error
        }
    }

    func submitCommitForHarness(
        forceFailure: Bool = false
    ) throws -> GPUFrameMetrics {
        drainFrameOutcomes()
        drainCompletedUploadRanges()
        guard activeStroke?.commitRequested == true,
              activeStroke?.pendingTokenBearingFrameCount == 0,
              liveStroke.bakedHighWater == liveStroke.emittedHighWater
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            let error = MetalRendererError.commandBufferUnavailable
            failActiveOperationIfNeeded(error)
            throw error
        }

        let start = CFAbsoluteTimeGetCurrent()
        let rasterCommit = try encodeCommit(
            commandBuffer,
            liveVisible: liveTile.isVisible
        )
        _ = try finalizeFrameEncoding(
            encodedClear: false,
            uploads: [],
            rasterCommit: rasterCommit,
            commandBuffer: commandBuffer,
            forceFailure: forceFailure
        )
        counters.renderedFramesThisStroke += 1
        let cpuMilliseconds = elapsedMilliseconds(since: start)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try validateHarnessCommand(commandBuffer)
        return metrics(
            commandBuffer: commandBuffer,
            cpuMilliseconds: cpuMilliseconds
        )
    }

    func drainCompletedOperationsForHarness() throws {
        let submittedError = drainFrameOutcomes()
        drainCompletedUploadRanges()
        if let submittedError {
            throw submittedError
        }
    }

    func submitDisplayOnlyForHarness(
        forceFailure: Bool
    ) throws {
        let texture = try makeHarnessTexture(width: 64, height: 64)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }
        try encodeDisplay(
            into: texture,
            commandBuffer: commandBuffer,
            showGridLines: false,
            liveVisible: false
        )
        _ = try finalizeFrameEncoding(
            encodedClear: false,
            uploads: [],
            rasterCommit: nil,
            commandBuffer: commandBuffer,
            forceFailure: forceFailure
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try validateHarnessCommand(commandBuffer)
    }

    func prioritizeLatestFrameOutcomeForHarness() {
        completionMailbox.prioritizeLastForHarness()
    }

    func deferNextFrameOutcomeForHarness() {
        completionMailbox.deferNextForHarness()
    }

    func releaseDeferredFrameOutcomesForHarness() {
        completionMailbox.releaseDeferredForHarness()
    }

    func drainNextCompletedOperationForHarness() throws {
        guard let outcome = completionMailbox.drainFirstForHarness() else {
            return
        }
        let submittedError = processFrameOutcome(outcome)
        drainCompletedUploadRanges()
        if let submittedError {
            throw submittedError
        }
    }

    public func copyCanonicalForHarness() throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: canonical.pixelSize.width,
            height: canonical.pixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalRendererError.commandFailed(
                "Metal blit encoder creation failed."
            )
        }
        encoder.copy(
            from: canonical.front,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: canonical.pixelSize.width,
                height: canonical.pixelSize.height,
                depth: 1
            ),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        do {
            try waitForHarnessCommand(commandBuffer)
        } catch let error as MetalRendererError {
            report(error)
            throw error
        }
        return texture
    }

    public func replaceCanonicalPixelsForHarness(_ bytes: [UInt8]) throws {
        let bytesPerRow = pixelSize.width * 4
        guard bytes.count == bytesPerRow * pixelSize.height else {
            throw MetalRendererError.commandFailed(
                "Harness canonical byte count does not match pixel size."
            )
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelSize.width,
            height: pixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let staging = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }
        bytes.withUnsafeBytes { storage in
            staging.replace(
                region: MTLRegionMake2D(
                    0,
                    0,
                    pixelSize.width,
                    pixelSize.height
                ),
                mipmapLevel: 0,
                withBytes: storage.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }
        try encodeResizeIntersectionCopy(
            from: staging,
            oldPixelSize: pixelSize,
            to: canonical.front,
            newPixelSize: pixelSize,
            on: commandBuffer
        )
        commandBuffer.commit()
        try waitForHarnessCommand(commandBuffer)
    }

    public var harnessCounters: GridStructuralCounters { counters }
    var harnessRevision: RasterRevision { canonical.revision }
    var harnessTiling: TilingKind { tilingStrategy.kind }
    var harnessRasterRevisionResidentBytes: Int {
        revisionStore.residentBytes
    }
    var harnessReservedInstanceBufferCount: Int {
        instancePool.unavailableSlotCount
    }
    var harnessInterpolatorSpacing: Float { interpolator.spacing }
    var harnessCompositeMode: StrokeCompositeMode? {
        activeStroke?.style.compositeMode
    }
    var harnessPendingInstanceColors: [SIMD4<Float>] {
        liveStroke.pending.map(\.instance.color)
    }
    var harnessTilingMutationSnapshot: HarnessTilingMutationSnapshot {
        HarnessTilingMutationSnapshot(
            canonicalFront: ObjectIdentifier(canonical.front as AnyObject),
            canonicalScratch: ObjectIdentifier(canonical.scratch as AnyObject),
            liveTexture: ObjectIdentifier(liveTile.texture as AnyObject),
            revision: canonical.revision,
            liveVisible: liveTile.isVisible,
            liveDirty: liveTile.isDirty,
            needsLiveClear: needsLiveClear,
            counters: counters,
            pendingInstanceCount: liveStroke.pending.count,
            bakedHighWater: liveStroke.bakedHighWater,
            emittedHighWater: liveStroke.emittedHighWater
        )
    }

    func injectFiveHundredInteriorDabsIntoOneFrame() throws {
        try beginHarnessExecution(radius: GridCanvasContract.brushRadius)
        counters = GridStructuralCounters()
        counters.newDabsThisEvent = 500
        counters.totalDabsThisStroke = 500

        for row in 0..<25 {
            for column in 0..<20 {
                try appendProjectedFragments(
                    at: WorldPoint(
                        x: 32 + Float(column) * 8,
                        y: 32 + Float(row) * 7
                    )
                )
            }
        }
    }

    @discardableResult
    func injectHarnessDab(
        at world: WorldPoint,
        radius requestedRadius: Float = GridCanvasContract.brushRadius
    ) throws -> [CellFragment] {
        try beginHarnessExecution(radius: requestedRadius)
        counters = GridStructuralCounters()
        counters.newDabsThisEvent = 1
        counters.totalDabsThisStroke = 1
        let fragments = try appendProjectedFragments(
            at: world,
            requestedRadius: requestedRadius
        )
        try prepareCurrentStrokeCommit(maximumRetainedBytes: Int.max)
        return fragments
    }

    @discardableResult
    func beginFixedProjectedStrokeForHarness(
        at world: WorldPoint
    ) throws -> [CellFragment] {
        try beginHarnessExecution(radius: GridCanvasContract.brushRadius)
        counters = GridStructuralCounters()
        counters.newDabsThisEvent = 1
        counters.totalDabsThisStroke = 1
        return try appendProjectedFragments(at: world)
    }

    @discardableResult
    func appendFixedProjectedSegmentForHarness(
        to world: WorldPoint
    ) throws -> [CellFragment] {
        guard hasActiveStroke else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        counters.newDabsThisEvent = 1
        counters.totalDabsThisStroke += 1
        return try appendProjectedFragments(at: world)
    }

    func endFixedProjectedStrokeForHarness() throws {
        guard hasActiveStroke else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        counters.newDabsThisEvent = 0
        try prepareCurrentStrokeCommit(maximumRetainedBytes: Int.max)
    }

    private func appendWorldDab(_ point: WorldPoint) throws {
        counters.newDabsThisEvent += 1
        counters.totalDabsThisStroke += 1
        try appendProjectedFragments(at: point)
    }

    @discardableResult
    private func appendProjectedFragments(
        at point: WorldPoint,
        requestedRadius: Float? = nil
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
            coverageSymmetry: .halfTurnInvariant
        )
        let fragments = TilingProjection.fragments(
            for: footprint,
            using: tilingStrategy
        )
        let color: InkColor
        switch activeStroke.style.compositeMode {
        case .draw:
            color = activeStroke.style.color
        case .erase:
            color = InkColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: activeStroke.style.eraserStrength
            )!
        }
        for fragment in fragments {
            let instance = PatternProjectedStampInstance(
                fragment: fragment,
                radius: radius,
                color: color
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

    private func frameUniforms(
        drawableSize: PatternSize,
        showGridLines: Bool,
        liveVisible: Bool,
        diagnosticMode: UInt32 = PatternDiagnosticWireNone
    ) -> PatternGridFrameUniforms {
        let compositeMode = activeStroke?.style.compositeMode.rawValue
            ?? PatternCompositeWireDraw
        return PatternGridFrameUniforms(
            drawableSize: drawableSize.simd,
            worldCenter: viewport.worldCenter.simd,
            tileSize: tileSize.simd,
            zoom: viewport.zoom,
            gridLineWidth: 1,
            showGridLines: showGridLines ? 1 : 0,
            liveVisible: liveVisible ? 1 : 0,
            tilingKind: tilingStrategy.kind.rawValue,
            diagnosticMode: diagnosticMode,
            compositeMode: compositeMode,
            padding: 0
        )
    }

    private func makeHarnessTexture(
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

    private func makeHarnessDisplayValidationTexture()
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
        return RasterResources(
            pixelSize: pixelSize,
            tileSize: PatternSize(
                width: Float(pixelSize.width),
                height: Float(pixelSize.height)
            ),
            canonical: canonical,
            liveTile: liveTile
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

    private func encodeResizeIntersectionCopy(
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
        for texture in [canonical.front, canonical.scratch, liveTile.texture] {
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
        needsLiveClear = false
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

    private func clearLiveForHarnessIfNeeded() throws {
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

    private func encodePendingLiveDabs(
        _ commandBuffer: any MTLCommandBuffer
    ) throws -> [FrameUpload] {
        guard let firstPending = liveStroke.pending.firstIndex(
            where: { $0.identity >= liveStroke.bakedHighWater }
        ) else {
            return []
        }

        var uploads: [FrameUpload] = []
        uploads.reserveCapacity(GridCanvasContract.inFlightBufferCount)
        var cursor = firstPending

        do {
            while cursor < liveStroke.pending.endIndex,
                  uploads.count < GridCanvasContract.inFlightBufferCount {
                guard let lease = instancePool.acquire() else {
                    break
                }
                let end = min(
                    cursor + lease.capacity,
                    liveStroke.pending.endIndex
                )
                let chunk = liveStroke.pending[cursor..<end]
                instancePool.write(chunk, into: lease)
                do {
                    try encodeStamp(
                        commandBuffer,
                        lease: lease,
                        count: chunk.count
                    )
                } catch {
                    instancePool.abandon(lease)
                    throw error
                }
                let throughExclusive = chunk.last.map { $0.identity + 1 }
                    ?? liveStroke.bakedHighWater
                let fromIdentity = chunk.first.map(\.identity)
                    ?? throughExclusive
                uploads.append(
                    FrameUpload(
                        lease: lease,
                        identityRange: fromIdentity..<throughExclusive,
                        throughExclusive: throughExclusive,
                        count: chunk.count
                    )
                )
                cursor = end
            }
            return uploads
        } catch {
            abandon(uploads)
            throw error
        }
    }

    private func encodeStamp(
        _ commandBuffer: any MTLCommandBuffer,
        lease: DabInstanceBufferPool.Lease,
        count: Int
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = liveTile.texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }
        encoder.label = "Stamp Persistent Live Dabs"
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
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: count
        )
        encoder.endEncoding()
    }

    private func encodeCommit(
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
            encoder.setFragmentTexture(
                canonical.front,
                index: Int(PatternTextureIndexCanonical)
            )
            encoder.setFragmentTexture(
                liveTile.texture,
                index: Int(PatternTextureIndexLive)
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

    private func encodeDisplay(
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
        encoder.label = "Grid Display"
        encoder.setRenderPipelineState(pipelines.display)
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
        encoder.setFragmentTexture(
            canonicalTexture ?? canonical.front,
            index: Int(PatternTextureIndexCanonical)
        )
        encoder.setFragmentTexture(
            liveTile.texture,
            index: Int(PatternTextureIndexLive)
        )
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 3
        )
        encoder.endEncoding()
    }

    private func finalizeFrameEncoding(
        encodedClear: Bool,
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
                    throughExclusive: upload.throughExclusive
                )
            )
            liveStroke.markEncoded(
                throughExclusive: upload.throughExclusive
            )
        }
        counters.newInstancesThisFrame = uploads.reduce(0) {
            $0 + $1.count
        }
        if !uploads.isEmpty {
            liveTile.markStamped()
        }

        let submittedOperationToken: RendererOperationToken?
        if let rasterCommit {
            submittedOperationToken = rasterCommit.token
        } else if let execution = activeStroke,
                  !execution.isCommitSubmitted,
                  encodedClear || !uploads.isEmpty
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
            ] buffer in
            let completed = buffer.status == .completed && !forceFailure
            completionMailbox.push(
                .init(
                    operationToken: submittedOperationToken,
                    rasterCommit: submittedCommit,
                    uploadSubmissions: submittedUploads,
                    succeeded: completed,
                    errorMessage: forceFailure
                        ? "injected harness command-buffer failure"
                        : buffer.error?.localizedDescription
                )
            )
        }
        return submittedUploads
    }

    private func drainCompletedUploadRanges() {
        let completedSignal = instancePool.event.signaledValue
        let completed = completedUploadRanges.filter {
            $0.signal <= completedSignal
        }
        if let greatest = completed.map(\.throughExclusive).max() {
            liveStroke.releaseEncodedPrefix(throughExclusive: greatest)
        }
        completedUploadRanges.removeAll {
            $0.signal <= completedSignal
        }
    }

    @discardableResult
    private func drainRasterOperationOutcomes() -> MetalRendererError? {
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
        let tiling = tilingStrategy.kind
        replacement.liveTile.markCleared()
        resources = replacement
        tilingStrategy = TilingStrategy(
            kind: tiling,
            tileSize: replacement.tileSize
        )
        needsLiveClear = false
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
    private func drainFrameOutcomes() -> MetalRendererError? {
        var latestError: MetalRendererError?
        for outcome in completionMailbox.drain() {
            let error = processFrameOutcome(outcome)
            if let error {
                latestError = error
            }
        }
        return latestError
    }

    private func processFrameOutcome(
        _ outcome: GridRenderCompletionMailbox.Outcome
    ) -> MetalRendererError? {
        if !outcome.succeeded {
            instancePool.reclaimTerminalFailure(
                outcome.uploadSubmissions
            )
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
        interpolator.cancel()
        liveTile.hide()
        completedUploadRanges.removeAll(keepingCapacity: true)
        liveStroke.reset()
        needsLiveClear = true
    }

    private func report(_ error: MetalRendererError) {
        lastError = error
        onError?(error)
    }

    private func notifyIdleStateIfChanged(from wasIdle: Bool) {
        guard wasIdle != isIdle else { return }
        onIdleStateChange?(isIdle)
    }

    private func abandon(_ uploads: [FrameUpload]) {
        for upload in uploads {
            instancePool.abandon(upload.lease)
        }
    }

    private func abandon(_ commit: EncodedRasterCommit?) {
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

    private func failActiveOperationIfNeeded(_ error: MetalRendererError) {
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

    private func waitForHarnessCommand(
        _ commandBuffer: any MTLCommandBuffer
    ) throws {
        commandBuffer.waitUntilCompleted()
        try validateHarnessCommand(commandBuffer)
    }

    private func validateHarnessCommand(
        _ commandBuffer: any MTLCommandBuffer
    ) throws {
        guard commandBuffer.status == .completed else {
            throw MetalRendererError.commandFailed(
                commandBuffer.error?.localizedDescription
                    ?? "unknown command-buffer error"
            )
        }
    }

    private func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }

    private func metrics(
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
