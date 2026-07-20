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

@MainActor
public final class GridRenderer: NSObject, MTKViewDelegate {
    public let device: any MTLDevice
    public let pixelSize: PixelSize
    public private(set) var lastError: MetalRendererError?
    public var onError: ((MetalRendererError) -> Void)?
    public private(set) var viewport: ViewportTransform
    public private(set) var counters = GridStructuralCounters()
    public var isIdle: Bool { lifecycle.state == .idle }
    public var hasActiveStroke: Bool { lifecycle.state == .active }

    private struct FrameUpload {
        let lease: DabInstanceBufferPool.Lease
        let throughExclusive: UInt64
        let count: Int
    }

    private let commandQueue: any MTLCommandQueue
    private let pipelines: GridPipelineLibrary
    private let canonical: CanonicalRaster
    private let liveTile: PersistentLiveTile
    private let instancePool: DabInstanceBufferPool
    private let completionMailbox = GridRenderCompletionMailbox()
    private let tileSize: PatternSize
    private let tilingStrategy: TilingStrategy
    private var lifecycle = GridStrokeLifecycle()
    private var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    private var liveStroke = LiveStroke()
    private var completedUploadRanges: [(signal: UInt64, throughExclusive: UInt64)] = []
    private var needsLiveClear = true

    public convenience init(
        device: any MTLDevice,
        drawableSize: PatternSize,
        pixelSize: PixelSize = GridCanvasContract.defaultPixelSize
    ) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.defaultLibraryUnavailable
        }
        try self.init(
            device: device,
            library: library,
            drawableSize: drawableSize,
            pixelSize: pixelSize
        )
    }

    public init(
        device: any MTLDevice,
        library: any MTLLibrary,
        drawableSize: PatternSize,
        pixelSize: PixelSize = GridCanvasContract.defaultPixelSize
    ) throws {
        ShaderABI.preconditionValid()
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRendererError.commandQueueUnavailable
        }
        let tileSize = PatternSize(
            width: Float(pixelSize.width),
            height: Float(pixelSize.height)
        )
        self.device = device
        self.pixelSize = pixelSize
        self.commandQueue = commandQueue
        self.tileSize = tileSize
        tilingStrategy = TilingStrategy(kind: .grid, tileSize: tileSize)
        pipelines = try GridPipelineLibrary(device: device, library: library)
        canonical = try CanonicalRaster(
            device: device,
            pixelSize: pixelSize
        )
        liveTile = try PersistentLiveTile(
            device: device,
            pixelSize: pixelSize
        )
        instancePool = try DabInstanceBufferPool(device: device)
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

    public func handle(_ sample: StrokeSample) {
        if lifecycle.state == .commitRequested {
            return
        }
        if case .commitPending = lifecycle.state {
            return
        }

        do {
            counters.newDabsThisEvent = 0
            switch sample.phase {
            case .began:
                try lifecycle.begin()
                counters = GridStructuralCounters()
                let world = viewport.screenToWorld(sample.position)
                try interpolator.begin(at: world, emit: appendWorldDab)
            case .moved:
                guard lifecycle.state == .active else {
                    throw MetalRendererError.invalidStrokeLifecycle
                }
                let world = viewport.screenToWorld(sample.position)
                try interpolator.append(world, emit: appendWorldDab)
            case .ended:
                guard lifecycle.state == .active else {
                    throw MetalRendererError.invalidStrokeLifecycle
                }
                let world = viewport.screenToWorld(sample.position)
                try interpolator.finish(at: world, emit: appendWorldDab)
                try lifecycle.requestCommit()
            case .cancelled:
                try cancelActiveStroke()
            }
        } catch MetalRendererError.commitPendingInput {
            return
        } catch let error as MetalRendererError {
            failTransiently(error)
        } catch {
            failTransiently(.commandFailed(error.localizedDescription))
        }
    }

    public func cancelActiveStroke() throws {
        try lifecycle.cancelActive()
        resetLiveState()
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
        do {
            let encodedClear = needsLiveClear
            if encodedClear {
                try encodeLiveClear(commandBuffer)
            }
            uploads = try encodePendingLiveDabs(commandBuffer)
            let plannedThrough = uploads.last?.throughExclusive
                ?? liveStroke.bakedHighWater
            let encodedCommit = lifecycle.state == .commitRequested
                && plannedThrough == liveStroke.emittedHighWater
            if encodedCommit {
                try encodeCommit(
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
                encodedCommit: encodedCommit,
                commandBuffer: commandBuffer
            )
            commandBuffer.present(drawable)
            if lifecycle.state != .idle {
                counters.renderedFramesThisStroke += 1
            }
            commandBuffer.commit()
        } catch let error as MetalRendererError {
            abandon(uploads)
            report(error)
        } catch {
            abandon(uploads)
            report(.commandFailed(error.localizedDescription))
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

    func flushPendingLiveForHarness() throws -> GPUFrameMetrics {
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
                encodedCommit: false,
                commandBuffer: commandBuffer
            )
            didFinalize = true
            if lifecycle.state != .idle {
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
                failTransiently(error)
                throw error
            }
            return metrics(
                commandBuffer: commandBuffer,
                cpuMilliseconds: cpuMilliseconds
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
            failTransiently(error)
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

    func finishCommitForHarness() throws -> GPUFrameMetrics {
        drainFrameOutcomes()
        drainCompletedUploadRanges()
        guard lifecycle.state == .commitRequested,
              liveStroke.bakedHighWater == liveStroke.emittedHighWater
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }

        let start = CFAbsoluteTimeGetCurrent()
        try encodeCommit(commandBuffer, liveVisible: liveTile.isVisible)
        _ = try finalizeFrameEncoding(
            encodedClear: false,
            uploads: [],
            encodedCommit: true,
            commandBuffer: commandBuffer
        )
        counters.renderedFramesThisStroke += 1
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
            failTransiently(error)
            throw error
        }
        return metrics(
            commandBuffer: commandBuffer,
            cpuMilliseconds: cpuMilliseconds
        )
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
            failTransiently(error)
            throw error
        }
        return texture
    }

    var harnessCounters: GridStructuralCounters { counters }
    var harnessRevision: RasterRevision { canonical.revision }

    func injectFiveHundredInteriorDabsIntoOneFrame() throws {
        try lifecycle.begin()
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

    private func appendWorldDab(_ point: WorldPoint) throws {
        counters.newDabsThisEvent += 1
        counters.totalDabsThisStroke += 1
        try appendProjectedFragments(at: point)
    }

    private func appendProjectedFragments(at point: WorldPoint) throws {
        let radius = TilingProjection.clampedRadius(
            requested: GridCanvasContract.brushRadius,
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
        for fragment in fragments {
            let instance = PatternProjectedStampInstance(
                fragment: fragment,
                radius: radius
            )
            try liveStroke.append(instance)
            counters.totalInstancesThisStroke += 1
        }
    }

    private func frameUniforms(
        drawableSize: PatternSize,
        showGridLines: Bool,
        liveVisible: Bool
    ) -> PatternGridFrameUniforms {
        PatternGridFrameUniforms(
            drawableSize: drawableSize.simd,
            worldCenter: viewport.worldCenter.simd,
            tileSize: tileSize.simd,
            zoom: viewport.zoom,
            gridLineWidth: 1,
            showGridLines: showGridLines ? 1 : 0,
            liveVisible: liveVisible ? 1 : 0,
            tilingKind: tilingStrategy.kind.rawValue,
            diagnosticMode: PatternDiagnosticWireNone
        )
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
            failTransiently(error)
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
                uploads.append(
                    FrameUpload(
                        lease: lease,
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
    ) throws {
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
    }

    private func encodeDisplay(
        into texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        showGridLines: Bool,
        liveVisible: Bool
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
    }

    private func finalizeFrameEncoding(
        encodedClear: Bool,
        uploads: [FrameUpload],
        encodedCommit: Bool,
        commandBuffer: any MTLCommandBuffer
    ) throws -> [DabBufferSubmissionIdentity] {
        let commitToken: UInt64? = encodedCommit
            ? try lifecycle.markCommitSubmitted()
            : nil

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
        commandBuffer.addCompletedHandler {
            [completionMailbox, submittedUploads] buffer in
            completionMailbox.push(
                .init(
                    commitToken: commitToken,
                    uploadSubmissions: submittedUploads,
                    succeeded: buffer.status == .completed,
                    errorMessage: buffer.error?.localizedDescription
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
            guard outcome.succeeded else {
                let error = MetalRendererError.commandFailed(
                    outcome.errorMessage ?? "unknown command-buffer error"
                )
                instancePool.reclaimTerminalFailure(
                    outcome.uploadSubmissions
                )
                failTransiently(error)
                latestError = error
                continue
            }
            guard let token = outcome.commitToken else {
                continue
            }
            do {
                try lifecycle.completeCommit(token: token, succeeded: true)
                canonical.acceptScratchCommit()
                resetLiveState()
            } catch let error as MetalRendererError {
                failTransiently(error)
                latestError = error
            } catch {
                let rendererError = MetalRendererError.commandFailed(
                    error.localizedDescription
                )
                failTransiently(rendererError)
                latestError = rendererError
            }
        }
        return latestError
    }

    private func resetLiveState() {
        interpolator.cancel()
        liveTile.hide()
        completedUploadRanges.removeAll(keepingCapacity: true)
        liveStroke.reset()
        needsLiveClear = true
    }

    private func failTransiently(_ error: MetalRendererError) {
        report(error)
        lifecycle.resetTransiently()
        resetLiveState()
    }

    private func report(_ error: MetalRendererError) {
        lastError = error
        onError?(error)
    }

    private func abandon(_ uploads: [FrameUpload]) {
        for upload in uploads {
            instancePool.abandon(upload.lease)
        }
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
