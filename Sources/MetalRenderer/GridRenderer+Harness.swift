import CShaderTypes
import Foundation
import Metal
import PatternEngine

struct SliceFourRendererCounters: Equatable, Sendable {
    let retainedSampleCount: Int
    let retainedDabCount: Int
    let settledDabCount: Int
    let predictedDabCount: Int
    let replayCount: Int
    let replayRenderEpoch: UInt64
    let replayVisibleEpoch: UInt64
    let promotedSettledPrefixCount: Int
    let replayDegradationCount: Int
    let assetResidentBytes: Int
    let assetFallbackCount: Int
    let assetIdentityMismatchCount: Int
    let processedWashPixelCount: Int
    let washWorkingBytes: Int
}

struct SliceFourReplayEpochAudit: Equatable, Sendable {
    let newerEpoch: UInt64
    let visibleBeforeStaleCompletion: UInt64
    let visibleAfterStaleCompletion: UInt64
    let staleCompletionViolationCount: Int
}

@MainActor
extension GridRenderer {
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
            let liveEncoding = try encodePendingLiveDabs(commandBuffer)
            uploads = liveEncoding.uploads
            let encodedReplayClear = liveEncoding.encodedReplayClear
            submissions = try finalizeFrameEncoding(
                encodedClear: false,
                encodedReplayClear: encodedReplayClear,
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
            liveVisible: liveTile.isVisible || replayTile.isVisible
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

    func renderBrushFootprintForHarness(
        footprint: StampFootprint,
        radius: Float,
        recipe: BrushRecipe,
        brushAttributes: SIMD4<Float>
    ) throws -> HarnessBrushRenderedFrame {
        let fragments = TilingProjection.fragments(
            for: footprint,
            using: tilingStrategy
        )
        let instances = fragments.map {
            PatternProjectedStampInstance(
                fragment: $0,
                radius: radius,
                color: .black,
                brushAttributes: brushAttributes
            )
        }
        guard !instances.isEmpty,
              instances.count <= GridCanvasContract.pendingCapacity
        else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                GridCanvasContract.pendingCapacity
            )
        }
        let instanceByteCount = instances.count
            * MemoryLayout<PatternProjectedStampInstance>.stride
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

        let shape = try brushTextureResolver.resolve(shape: recipe.shape)
        let grain = try brushTextureResolver.resolve(grain: recipe.grain)
        let canonicalTexture = try makeHarnessTexture(
            width: pixelSize.width,
            height: pixelSize.height
        )
        let pipeline = try GridPipelineLibrary.makeHarnessBrushPipeline(
            device: device,
            library: library
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }
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
        encoder.label = "Harness Recipe Brush Footprint"
        encoder.setRenderPipelineState(pipeline)
        var frame = frameUniforms(
            drawableSize: tileSize,
            showGridLines: false,
            liveVisible: false
        )
        var material = BrushMaterialState(recipe: recipe).uniforms
        encoder.setVertexBytes(
            &frame,
            length: MemoryLayout<PatternGridFrameUniforms>.stride,
            index: Int(PatternBufferIndexGridFrameUniforms)
        )
        encoder.setVertexBuffer(
            instanceBuffer,
            offset: 0,
            index: Int(PatternBufferIndexDabInstances)
        )
        encoder.setFragmentTexture(
            shape.texture,
            index: Int(PatternTextureIndexBrushShape)
        )
        encoder.setFragmentTexture(
            grain.texture,
            index: Int(PatternTextureIndexBrushGrain)
        )
        encoder.setFragmentBytes(
            &material,
            length: MemoryLayout<PatternBrushMaterialUniforms>.stride,
            index: Int(PatternBufferIndexBrushMaterial)
        )
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: instances.count
        )
        encoder.endEncoding()
        commandBuffer.commit()
        try waitForHarnessCommand(commandBuffer)
        return HarnessBrushRenderedFrame(
            canonical: canonicalTexture,
            fragments: fragments,
            shapeIdentity: shape.resolvedIdentity,
            grainIdentity: grain.resolvedIdentity,
            assetsWereExact: shape.isExact && grain.isExact
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
              liveStroke.bakedHighWater == liveStroke.emittedHighWater,
              replayStroke.bakedHighWater == replayStroke.emittedHighWater
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
            liveVisible: liveTile.isVisible || replayTile.isVisible
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
    func harnessWorldPoint(for screenPoint: ScreenPoint) -> WorldPoint {
        viewport.screenToWorld(screenPoint)
    }
    func harnessCell(for screenPoint: ScreenPoint) -> CellIndex {
        tilingStrategy.cell(containing: viewport.screenToWorld(screenPoint))
    }
    var harnessRasterRevisionResidentBytes: Int {
        revisionStore.residentBytes
    }
    var harnessReservedInstanceBufferCount: Int {
        instancePool.unavailableSlotCount
    }
    var harnessInterpolatorSpacing: Float {
        strokeGenerator?.currentSpacing ?? 0
    }
    var harnessCompositeMode: StrokeCompositeMode? {
        activeStroke?.style.compositeMode
    }
    var harnessActiveStrokeStyle: StrokeRenderStyle? {
        activeStroke?.style
    }
    var sliceFourRendererCounters: SliceFourRendererCounters {
        let shapeMismatch = activeShapeResolution.isExact ? 0 : 1
        let grainMismatch = activeGrainResolution.isExact ? 0 : 1
        return SliceFourRendererCounters(
            retainedSampleCount:
                transientStrokeBuffer?.retainedSampleCount ?? 0,
            retainedDabCount:
                transientStrokeBuffer?.retainedDabCount ?? 0,
            settledDabCount:
                transientStrokeBuffer?.actualDabCount ?? 0,
            predictedDabCount:
                transientStrokeBuffer?.predictedDabCount ?? 0,
            replayCount: Int(transientStrokeBuffer?.replayEpoch ?? 0),
            replayRenderEpoch: replayStroke.renderEpoch,
            replayVisibleEpoch: replayTile.visibleEpoch,
            promotedSettledPrefixCount:
                transientStrokeBuffer?.settledPrefixPromotionCount ?? 0,
            replayDegradationCount:
                transientStrokeBuffer?.degradationCount ?? 0,
            assetResidentBytes:
                brushTextureResolver.cachedTextureCount
                    * BrushTextureFactory.mipmappedTextureByteCount,
            assetFallbackCount: brushTextureResolver.reportedFallbackCount,
            assetIdentityMismatchCount: shapeMismatch + grainMismatch,
            processedWashPixelCount:
                lastBoundedWashWorkPlan?.processedPixelCount ?? 0,
            washWorkingBytes:
                boundedWashSurface?.workingByteCount ?? 0
        )
    }

    /// Deterministically delivers a delayed older replay completion after a
    /// newer epoch is visible. This exercises the same renderer-owned epoch
    /// guard used by asynchronously completed replay command buffers.
    func auditDelayedStaleReplayCompletionForHarness()
        -> SliceFourReplayEpochAudit
    {
        let base = max(replayTile.visibleEpoch, replayStroke.renderEpoch)
        let staleEpoch = base &+ 1
        let newerEpoch = base &+ 2
        _ = replayTile.planReplacement(
            epoch: staleEpoch,
            prior: PixelRegionSet([], clippedTo: pixelSize),
            replacement: PixelRegionSet([], clippedTo: pixelSize)
        )
        replayTile.markVisible(epoch: staleEpoch)
        _ = replayTile.planReplacement(
            epoch: newerEpoch,
            prior: PixelRegionSet([], clippedTo: pixelSize),
            replacement: PixelRegionSet([], clippedTo: pixelSize)
        )
        replayTile.markVisible(epoch: newerEpoch)
        let before = replayTile.visibleEpoch
        replayTile.markVisible(epoch: staleEpoch)
        let after = replayTile.visibleEpoch
        return SliceFourReplayEpochAudit(
            newerEpoch: newerEpoch,
            visibleBeforeStaleCompletion: before,
            visibleAfterStaleCompletion: after,
            staleCompletionViolationCount:
                before == newerEpoch && after == newerEpoch ? 0 : 1
        )
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
}
