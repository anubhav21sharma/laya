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

struct HarnessLiveFlushResult {
    let metrics: GPUFrameMetrics
    let emittedHighWater: UInt64
    let encodedIdentityRanges: [Range<UInt64>]
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
    public let pixelSize: PixelSize
    public private(set) var lastError: MetalRendererError?
    public var onError: ((MetalRendererError) -> Void)?
    public var onIdleStateChange: ((Bool) -> Void)?
    public var onOperationCompleted: ((RendererOperationCompletion) -> Void)?
    public private(set) var viewport: ViewportTransform
    public private(set) var counters = GridStructuralCounters()
    public var isIdle: Bool { activeStroke == nil }
    public var hasActiveStroke: Bool {
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
    }

    private struct EncodedRasterCommit {
        let token: RendererOperationToken
        let revisions: PendingRasterRevisionPair
        let captureTokens: [RasterRevisionOperationToken]
    }

    private let commandQueue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let pipelines: GridPipelineLibrary
    private let canonical: CanonicalRaster
    private let liveTile: PersistentLiveTile
    private let instancePool: DabInstanceBufferPool
    private let revisionStore: RasterRevisionStore
    private let completionMailbox = GridRenderCompletionMailbox()
    private let tileSize: PatternSize
    private var tilingStrategy: TilingStrategy
    private var activeStroke: ActiveStrokeExecution?
    private var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    private var liveStroke = LiveStroke()
    private var completedUploadRanges: [(signal: UInt64, throughExclusive: UInt64)] = []
    private var needsLiveClear = true
    private var nextHarnessTokenRawValue: UInt64 = 1

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
        let tileSize = PatternSize(
            width: Float(configuration.pixelSize.width),
            height: Float(configuration.pixelSize.height)
        )
        self.device = device
        pixelSize = configuration.pixelSize
        self.commandQueue = commandQueue
        self.library = library
        self.tileSize = tileSize
        tilingStrategy = TilingStrategy(
            kind: configuration.tiling,
            tileSize: tileSize
        )
        pipelines = try GridPipelineLibrary(device: device, library: library)
        canonical = try CanonicalRaster(
            device: device,
            pixelSize: configuration.pixelSize
        )
        liveTile = try PersistentLiveTile(
            device: device,
            pixelSize: configuration.pixelSize
        )
        instancePool = try DabInstanceBufferPool(device: device)
        revisionStore = RasterRevisionStore(device: device)
        viewport = ViewportTransform(
            drawableSize: drawableSize,
            worldCenter: WorldPoint(
                x: tileSize.width * 0.5,
                y: tileSize.height * 0.5
            ),
            zoom: 1
        )
        completedUploadRanges.reserveCapacity(
            GridCanvasContract.inFlightBufferCount
        )
        super.init()
        try clearInitialTextures()
    }

    public func setTiling(_ tiling: TilingKind) throws {
        guard activeStroke == nil else {
            throw MetalRendererError.tilingChangeRequiresIdle
        }
        tilingStrategy = TilingStrategy(
            kind: tiling,
            tileSize: tileSize
        )
    }

    public func beginStroke(
        token: RendererOperationToken,
        sample: StrokeSample,
        style: StrokeRenderStyle
    ) throws {
        let wasIdle = isIdle
        defer { notifyIdleStateIfChanged(from: wasIdle) }
        guard sample.phase == .began, activeStroke == nil else {
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
            pendingRevisions: nil
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
            pendingRevisions: nil
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

    public func draw(in view: MTKView) {
        drainFrameOutcomes()
        drainCompletedUploadRanges()

        guard let drawable = view.currentDrawable else {
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            report(.commandBufferUnavailable)
            return
        }

        var uploads: [FrameUpload] = []
        var rasterCommit: EncodedRasterCommit?
        do {
            let encodedClear = needsLiveClear
            if encodedClear {
                try encodeLiveClear(commandBuffer)
            }
            uploads = try encodePendingLiveDabs(commandBuffer)
            let plannedThrough = uploads.last?.throughExclusive
                ?? liveStroke.bakedHighWater
            let shouldEncodeCommit = activeStroke?.commitRequested == true
                && plannedThrough == liveStroke.emittedHighWater
            if shouldEncodeCommit {
                rasterCommit = try encodeCommit(
                    commandBuffer,
                    liveVisible: liveTile.isVisible || !uploads.isEmpty
                )
            }
            try encodeDisplay(
                into: drawable.texture,
                commandBuffer: commandBuffer,
                showGridLines: false,
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
            failRequestedCommitIfNeeded(error)
        } catch {
            abandon(uploads)
            abandon(rasterCommit)
            failRequestedCommitIfNeeded(
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

    func flushPendingLiveForHarness() throws -> HarnessLiveFlushResult {
        drainFrameOutcomes()
        drainCompletedUploadRanges()
        try clearLiveForHarnessIfNeeded()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
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
                commandBuffer: commandBuffer
            )
            didFinalize = true
            if activeStroke != nil {
                counters.renderedFramesThisStroke += 1
            }
            let cpuMilliseconds = elapsedMilliseconds(since: start)
            commandBuffer.commit()
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
            }
            throw error
        }
    }

    func renderOffscreenDisplayForHarness(
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
            throw MetalRendererError.commandBufferUnavailable
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
            throw MetalRendererError.commandBufferUnavailable
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

    func finishCommitForHarness() throws -> GPUFrameMetrics {
        let metrics = try submitCommitForHarness()
        try drainCompletedOperationsForHarness()
        return metrics
    }

    func submitCommitForHarness(
        forceFailure: Bool = false
    ) throws -> GPUFrameMetrics {
        drainFrameOutcomes()
        drainCompletedUploadRanges()
        guard activeStroke?.commitRequested == true,
              liveStroke.bakedHighWater == liveStroke.emittedHighWater
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
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

    func copyCanonicalForHarness() throws -> any MTLTexture {
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

    var harnessCounters: GridStructuralCounters { counters }
    var harnessRevision: RasterRevision { canonical.revision }
    var harnessTiling: TilingKind { tilingStrategy.kind }
    var harnessRasterRevisionResidentBytes: Int {
        revisionStore.residentBytes
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
            throw MetalRendererError.commandBufferUnavailable
        }
        try encodeLiveClear(commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        do {
            try validateHarnessCommand(commandBuffer)
        } catch let error as MetalRendererError {
            report(error)
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

        let submittedUploads = uploadSubmissions
        let submittedCommit = rasterCommit.map {
            GridRenderCompletionMailbox.RasterCommit(
                token: $0.token,
                revisions: $0.revisions,
                captureTokens: $0.captureTokens
            )
        }
        commandBuffer.addCompletedHandler {
            [completionMailbox, submittedCommit, submittedUploads] buffer in
            let completed = buffer.status == .completed && !forceFailure
            completionMailbox.push(
                .init(
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
    private func drainFrameOutcomes() -> MetalRendererError? {
        var latestError: MetalRendererError?
        for outcome in completionMailbox.drain() {
            let wasIdle = isIdle
            defer { notifyIdleStateIfChanged(from: wasIdle) }
            if !outcome.succeeded {
                instancePool.reclaimTerminalFailure(
                    outcome.uploadSubmissions
                )
            }
            guard let commit = outcome.rasterCommit else {
                if !outcome.succeeded {
                    let error = MetalRendererError.commandFailed(
                        outcome.errorMessage
                            ?? "unknown command-buffer error"
                    )
                    report(error)
                    latestError = error
                }
                continue
            }

            let error: MetalRendererError?
            if outcome.succeeded {
                error = finalizeRasterCommitSuccess(commit)
            } else {
                error = finalizeRasterCommitFailure(
                    commit,
                    message: outcome.errorMessage
                        ?? "unknown command-buffer error"
                )
            }
            if let error {
                latestError = error
            }
        }
        return latestError
    }

    private func finalizeRasterCommitSuccess(
        _ commit: GridRenderCompletionMailbox.RasterCommit
    ) -> MetalRendererError? {
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
        discardSubmittedPairIfPossible(commit.revisions)
        activeStroke = nil
        resetLiveState()
        report(error)
        onOperationCompleted?(.failure(commit.token, error))
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

    private func failRequestedCommitIfNeeded(_ error: MetalRendererError) {
        report(error)
        guard activeStroke?.commitRequested == true else { return }
        let token = activeStroke!.token
        discardPendingRevisionsIfPossible()
        activeStroke = nil
        resetLiveState()
        onOperationCompleted?(.failure(token, error))
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
