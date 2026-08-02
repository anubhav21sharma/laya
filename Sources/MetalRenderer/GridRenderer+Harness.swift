import CShaderTypes
import Foundation
import Metal
import PatternEngine

@MainActor
extension GridRenderer {
    public func armInputPathStorageAuditForHarness() {
        armInputPathStorageAuditAfterWarmup()
    }

    public func installNativeHarnessBrushes() throws {
        try activateDrawBrush(
            makeNativeHarnessBrush(mode: .draw)
        )
        try activateEraserBrush(
            makeNativeHarnessBrush(mode: .erase)
        )
    }

    public func nativeHarnessStrokeStyle(
        color: InkColor = .black,
        diameter: Float = GridCanvasContract.brushRadius * 2,
        compositeMode: StrokeCompositeMode = .draw,
        eraserStrength: Float = 1,
        seed: UInt64
    ) throws -> StrokeRenderStyle {
        guard let brush = preparedBrush(for: compositeMode) else {
            throw MetalRendererError.compiledBrushUnavailable(compositeMode)
        }
        return StrokeRenderStyle(
            color: color,
            diameter: diameter,
            compositeMode: compositeMode,
            eraserStrength: eraserStrength,
            program: brush.program,
            renderIdentity: brush.renderIdentity,
            seed: seed
        )
    }

    private func makeNativeHarnessBrush(
        mode: StrokeCompositeMode
    ) throws -> CompiledBrush {
        let definition = try Self.nativeHarnessDefinition(mode: mode)
        let program = try BrushProgramCompiler.compile(definition)
        let coverage = definition.coverage
        let pipelineKey = BrushPipelineKey(
            backend: .deposition,
            accumulation: definition.material.accumulation,
            edgeTreatment: definition.material.edgeTreatment,
            functionConstants: BrushFunctionConstants(
                usesSecondaryShape: coverage.shapes.count > 1,
                usesGrain: !coverage.grains.isEmpty,
                usesSecondaryGrain: coverage.grains.count > 1,
                usesDestinationSampling: false
            )
        )
        let depositionKey = DepositionPipelineKey(
            brush: pipelineKey,
            abiVersion: DepositionABI.version,
            colorPixelFormatRawValue:
                GridPipelineLibrary.colorPixelFormat.rawValue,
            sampleCount: GridPipelineLibrary.sampleCount
        )
        let pipeline = try DepositionPipelineLibrary(
            device: device,
            library: library
        ).prepareImmediately(for: depositionKey)
        let uniforms = BrushUniformTemplate(
            placement: definition.placement,
            coverage: definition.coverage,
            color: definition.color,
            material: definition.material
        )
        let hash = String(
            repeating: mode == .draw ? "d" : "e",
            count: 64
        )
        let identity = try BrushRenderIdentity(
            definitionID: definition.id,
            semanticHash: hash
        )
        let report = try BrushCompilationReport(
            definitionID: definition.id.rawValue,
            packageContentHash: hash,
            backend: .deposition,
            compatibility: [],
            performance: BrushPerformanceClassification(
                tier: .realtime120,
                basis: .estimated,
                reason: "native harness fixture"
            ),
            encodedResourceBytes: 0,
            residentResourceBytes: 0,
            deviceRegistryID: device.registryID
        )
        return CompiledBrush(
            program: program,
            renderIdentity: identity,
            pipelineKey: pipelineKey,
            uniformTemplate: uniforms,
            textures: [:],
            depositionPipeline: pipeline,
            depositionMaterial: try DepositionMaterialBinding(
                uniformTemplate: uniforms,
                textures: [:]
            ),
            residentByteCount: 0,
            report: report,
            diagnostics: [],
            cacheKeys: []
        )
    }

    nonisolated static func nativeHarnessDefinition(
        mode: StrokeCompositeMode
    ) throws -> BrushDefinition {
        let one = BrushMappingDefinition(
            input: .pressure,
            response: .constant(1),
            scale: 1,
            offset: 0,
            lowerClamp: 1,
            upperClamp: 1,
            inverted: false,
            jitter: 0,
            missingInputValue: 1
        )
        let zero = BrushMappingDefinition(
            input: .pressure,
            response: .constant(0),
            scale: 1,
            offset: 0,
            lowerClamp: 0,
            upperClamp: 0,
            inverted: false,
            jitter: 0,
            missingInputValue: 1
        )
        return try BrushDefinition(
            id: BrushRecipeID(
                mode == .draw
                    ? "harness.native-draw"
                    : "harness.native-erase"
            ),
            metadata: BrushMetadata(
                displayName: mode == .draw
                    ? "Harness Native Draw"
                    : "Harness Native Erase"
            ),
            capabilities: [],
            resources: [],
            coverage: BrushCoverageDefinition(
                shapes: [
                    BrushShapeLayerDefinition(
                        shape: .hardRound,
                        combination: .replace,
                        scale: 1,
                        rotation: 0,
                        offset: .zero
                    ),
                ],
                grains: [],
                baseHardness: 0.9,
                aspectRatio: 1,
                tipThreshold: 0.01,
                antialiasing: true
            ),
            placement: BrushPlacementDefinition(
                baseSpacingFraction: 0.1,
                maximumSpacingFraction: 0.25,
                baseFlow: 1,
                strokeOpacity: 1,
                baseScatterFraction: 0,
                baseRotation: 0,
                baseJitterFraction: 0,
                baseOffset: .zero
            ),
            dynamics: BrushDynamicsDefinition(
                size: one,
                flow: one,
                opacity: one,
                spacing: one,
                rotation: zero,
                scatter: zero,
                hardness: one,
                grain: one,
                offsetX: zero,
                offsetY: zero,
                hue: zero,
                saturation: zero,
                brightness: zero,
                secondaryColorMix: zero,
                noPressureNeutral: 0.5,
                randomization: .none
            ),
            color: BrushColorBehaviorDefinition(
                baseAdjustment: .identity,
                perStampJitter: BrushColorJitter(
                    hue: 0,
                    saturation: 0,
                    brightness: 0,
                    secondaryColorMix: 0
                ),
                perStrokeJitter: BrushColorJitter(
                    hue: 0,
                    saturation: 0,
                    brightness: 0,
                    secondaryColorMix: 0
                )
            ),
            material: BrushMaterialDefinition(
                accumulation: mode == .draw ? .flow : .destinationOut,
                interaction: .none,
                edgeTreatment: .none,
                strength: 1,
                wetness: 0,
                bleedRadius: 0,
                softenPasses: 0,
                accumulationLimit: 1,
                interactionParameters: nil
            ),
            stabilization: 0,
            taper: .none,
            replayMode: .appendOnly,
            replayLimits: nil,
            seedPolicy: .perStroke,
            limits: BrushDefinitionLimits(
                minimumDiameter: 0.01,
                maximumDiameter: 16_384,
                maximumOpacity: 1,
                maximumSpacingFraction: 4,
                maximumResourceDimension: 4_096,
                maximumResidentBytes: 64 * 1_024 * 1_024
            ),
            performanceIntent: .realtime120,
            compatibility: BrushCompatibilityMetadata(
                nativeFeatureVersion: 1,
                sourceSettingKeys: [],
                requiredSemanticKeys: []
            )
        )
    }

    public func flushPendingLiveForHarness(
        forceFailure: Bool = false,
        forceCommandBufferUnavailable: Bool = false
    ) throws -> HarnessLiveFlushResult {
        let progressWaiter =
            installStrokePreparationProgressWaiterForHarness()
        defer {
            if let progressWaiter {
                removeStrokePreparationProgressWaiterForHarness(
                    progressWaiter
                )
            }
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        if let progressWaiter,
           !hasPendingPreparedStrokeSurfaceForHarness,
           !strokePreparationIsQuiescentForAllocationHarness
        {
            try waitForPendingLiveSurfaceForHarness(
                progressWaiter: progressWaiter,
                deadline: deadline
            )
        }
        let submittedPreparedSurface =
            hasPendingPreparedStrokeSurfaceForHarness
        let frameMetrics = try completeNextPendingInteractiveFrame(
            forceFailure: forceFailure,
            forceCommandBufferUnavailable:
                forceCommandBufferUnavailable
        )
        if submittedPreparedSurface, let progressWaiter {
            try waitForPreparedSurfaceRetirementForHarness(
                progressWaiter: progressWaiter,
                deadline: deadline
            )
        }
        return HarnessLiveFlushResult(
            metrics: frameMetrics,
            emittedHighWater: scheduledAuthoritativeIdentityHighWater,
            encodedIdentityRanges:
                lastEncodedAuthoritativeIdentityRange.map { [$0] } ?? [],
            authoritativeBacklogRemaining:
                activeStroke?.frozenHarnessScheduler?
                    .authoritativeCount ?? 0,
            replayRetention: HarnessReplayRetentionSnapshot(
                retainedDabCount:
                    transientStrokeBuffer?.retainedDabCount ?? 0,
                visibleProjectedInstanceCount:
                    transientStrokeBuffer?
                        .visibleProjectedInstanceCount ?? 0
            )
        )
    }

    /// Waits until the actor publishes a surface lease, but deliberately does
    /// not submit it. Failure harnesses use this boundary to inject a failure
    /// into a command buffer that actually owns stroke work.
    func preparePendingLiveSurfaceForHarness() throws {
        guard let progressWaiter =
                installStrokePreparationProgressWaiterForHarness()
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        defer {
            removeStrokePreparationProgressWaiterForHarness(progressWaiter)
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        try waitForPendingLiveSurfaceForHarness(
            progressWaiter: progressWaiter,
            deadline: deadline
        )
    }

    private func waitForPendingLiveSurfaceForHarness(
        progressWaiter: StrokePreparationProgressRegistration,
        deadline: Date
    ) throws {
        while true {
            let observedRevision = progressWaiter.currentRevision
            try drainCompletedInteractiveOperations()
            if hasPendingPreparedStrokeSurfaceForHarness {
                return
            }
            guard activeStroke != nil else {
                throw lastError ?? MetalRendererError.invalidStrokeLifecycle
            }
            if progressWaiter.currentRevision != observedRevision {
                continue
            }
            guard progressWaiter.waitForProgress(
                after: observedRevision,
                until: deadline
            ) else {
                break
            }
        }
        throw MetalRendererError.commandFailed(
            "stroke surface preparation exceeded its harness bound"
        )
    }

    /// The GPU completion transfers a prepared surface back to the actor, but
    /// the acknowledgement itself is processed independently. Do not let a
    /// synchronous harness caller start measuring or enqueueing the next event
    /// while that prior actor operation is still running. A newly published
    /// surface is also a stable boundary: the actor cannot mutate it again
    /// until Main submits and acknowledges it on the next flush.
    private func waitForPreparedSurfaceRetirementForHarness(
        progressWaiter: StrokePreparationProgressRegistration,
        deadline: Date
    ) throws {
        while true {
            let observedRevision = progressWaiter.currentRevision
            try drainCompletedInteractiveOperations()
            if strokePreparationIsQuiescentForAllocationHarness
                || hasPendingPreparedStrokeSurfaceForHarness
            {
                return
            }
            if progressWaiter.currentRevision != observedRevision {
                continue
            }
            guard progressWaiter.waitForProgress(
                after: observedRevision,
                until: deadline
            ) else {
                break
            }
        }
        throw MetalRendererError.commandFailed(
            "stroke surface retirement exceeded its harness bound"
        )
    }

    nonisolated static func nativeEncodedIdentityRanges(
        previousEncodedHighWater: UInt64,
        emittedHighWater: UInt64,
        newInstanceCount: Int
    ) -> [Range<UInt64>] {
        guard
            newInstanceCount > 0,
            let count = UInt64(exactly: newInstanceCount),
            previousEncodedHighWater <= emittedHighWater,
            count <= emittedHighWater - previousEncodedHighWater
        else {
            return []
        }
        return [
            previousEncodedHighWater
                ..< previousEncodedHighWater + count,
        ]
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
            liveVisible: compositeLiveIsVisible
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
        let instances = try fragments.enumerated().map { ordinal, fragment in
            let dab = LogicalDab(
                position: WorldPoint(footprint.brushToWorld.translation),
                brushToWorld: footprint.brushToWorld,
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
                color: .black,
                colorAdjustment: .identity,
                materialFamily: .ink,
                materialContribution: 1,
                sourceDistance: 0,
                ordinal: UInt64(ordinal),
                isPredicted: false
            )
            return try PatternDepositionStampInstance(
                fragment: fragment,
                dab: dab,
                logicalOrdinal: UInt64(ordinal),
                isometryOrdinal: compiledIsometryOrdinal(for: fragment)
            )
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
            instances.count
                * MemoryLayout<PatternDepositionStampInstance>.stride
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
            width: storagePixelSize.width,
            height: storagePixelSize.height
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

    public func finishCommitForHarness(
        forceCommitFailure: Bool = false
    ) throws -> GPUFrameMetrics {
        do {
            let metrics = try completePendingInteractiveStroke(
                forceCommitFailure: forceCommitFailure
            )
            try drainStrokeWorkspaceRetirementForHarness()
            return metrics
        } catch {
            // A terminal failure also retires the borrowed actor workspace.
            // Keep the original failure as the observable result, but finish
            // the harness-only drain so a recovery stroke can start.
            try? drainStrokeWorkspaceRetirementForHarness()
            throw error
        }
    }

    /// Drains actor-prepared surface leases up to the commit barrier without
    /// submitting the raster commit. Capture harnesses use this to snapshot
    /// the complete live surface before comparing it with committed output.
    func preparePendingCommitForHarness() throws {
        guard let progressWaiter =
                installStrokePreparationProgressWaiterForHarness()
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        defer {
            removeStrokePreparationProgressWaiterForHarness(progressWaiter)
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while true {
            let observedRevision = progressWaiter.currentRevision
            try advanceStrokePreparationForAllocationHarness()
            try prepareCompiledCommitIfReady()
            if activeStroke?.pendingRevisions != nil {
                return
            }
            if progressWaiter.currentRevision != observedRevision {
                continue
            }
            guard progressWaiter.waitForProgress(
                after: observedRevision,
                until: deadline
            ) else {
                break
            }
        }
        throw MetalRendererError.commandFailed(
            "stroke commit preparation exceeded its harness bound"
        )
    }

    /// Drains all currently accepted actor input while leaving the stroke
    /// editable. This is an explicit capture boundary, not an interactive API.
    func drainPreparedStrokeInputForHarness() throws {
        guard let progressWaiter =
                installStrokePreparationProgressWaiterForHarness()
        else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        defer {
            removeStrokePreparationProgressWaiterForHarness(progressWaiter)
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while true {
            let observedRevision = progressWaiter.currentRevision
            try advanceStrokePreparationForAllocationHarness()
            if strokePreparationIsQuiescentForAllocationHarness {
                return
            }
            if progressWaiter.currentRevision != observedRevision {
                continue
            }
            guard progressWaiter.waitForProgress(
                after: observedRevision,
                until: deadline
            ) else {
                break
            }
        }
        throw MetalRendererError.commandFailed(
            "stroke input preparation exceeded its harness bound"
        )
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
        try completePendingRasterOperation()
    }

    func submitCommitForHarness(
        forceFailure: Bool = false
    ) throws -> GPUFrameMetrics {
        try submitPendingInteractiveCommit(forceFailure: forceFailure)
    }

    func drainCompletedOperationsForHarness() throws {
        try drainCompletedInteractiveOperations()
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
        let bytesPerRow = storagePixelSize.width * 4
        guard bytes.count == bytesPerRow * storagePixelSize.height else {
            throw MetalRendererError.commandFailed(
                "Harness canonical byte count does not match storage size."
            )
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: storagePixelSize.width,
            height: storagePixelSize.height,
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
                    storagePixelSize.width,
                    storagePixelSize.height
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
            oldPixelSize: storagePixelSize,
            to: canonical.front,
            newPixelSize: storagePixelSize,
            on: commandBuffer
        )
        commandBuffer.commit()
        try waitForHarnessCommand(commandBuffer)
        try reconcileGeometryLock(
            documentIsEmpty: !bytes.contains(where: { $0 != 0 })
        )
    }

    struct HarnessOffMainDepositionSnapshot: Equatable, Sendable {
        let logicalDabCount: Int
        let projectedInstanceCount: Int
        let authoritativeBacklog: Int
        let authoritativeBacklogHighWater: Int
        let encodedInstanceCount: UInt64
        let surfaceLeaseHighWater: Int
    }

    var harnessOffMainDepositionSnapshot:
        HarnessOffMainDepositionSnapshot?
    {
        guard let surface = offMainSurfaceSnapshotForHarness,
              let projectedInstanceCount = Int(
                  exactly: surface.encodedInstanceCount
              )
        else {
            return nil
        }
        let coordinator = offMainCoordinatorSnapshotForHarness
        let logicalDabCount = coordinator.flatMap {
            Int(exactly: $0.commitMetadata.emittedDabCount)
        } ?? counters.totalDabsThisStroke
        return HarnessOffMainDepositionSnapshot(
            logicalDabCount: logicalDabCount,
            projectedInstanceCount: projectedInstanceCount,
            authoritativeBacklog:
                coordinator?.authoritativeQueueDepth ?? 0,
            authoritativeBacklogHighWater:
                max(
                    coordinator?.authoritativeQueueHighWater ?? 0,
                    logicalDabCount > 0 ? 1 : 0
                ),
            encodedInstanceCount: surface.encodedInstanceCount,
            surfaceLeaseHighWater: surface.surfaceLeaseHighWater
        )
    }

    /// Deterministic evidence oracle for records already generated and
    /// encoded by the production actor. This never activates the retired
    /// MainActor scheduler or participates in interactive stroke execution.
    func projectLogicalDabsForHarness(
        _ dabs: [LogicalDab]
    ) throws -> [ProjectedDepositionRecord] {
        var records: [ProjectedDepositionRecord] = []
        records.reserveCapacity(dabs.count)
        for dab in dabs where !dab.isPredicted {
            let fragments = TilingProjection.fragments(
                for: StampFootprint(
                    brushToWorld: dab.brushToWorld,
                    localBounds: AxisAlignedRect(
                        minimum: SIMD2(-1, -1),
                        maximum: SIMD2(1, 1)
                    ),
                    coverageSymmetry: .oriented
                ),
                using: tilingStrategy
            )
            for fragment in fragments {
                let radialPage: RadialPageCoordinate? =
                    tilingStrategy.compiledSymmetry.domain.finite?
                        .radial.layout == nil
                        ? nil
                        : RadialPageCoordinate(
                            x: fragment.cell.column,
                            y: fragment.cell.row
                        )
                records.append(
                    ProjectedDepositionRecord(
                        identity: dab.ordinal,
                        instance: try PatternDepositionStampInstance(
                            fragment: fragment,
                            dab: dab,
                            logicalOrdinal: dab.ordinal,
                            isometryOrdinal:
                                compiledIsometryOrdinal(for: fragment)
                        ),
                        radialPage: radialPage
                    )
                )
            }
        }
        return records
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
    var harnessRasterRevisionSnapshots: [RasterRevisionHarnessSnapshot] {
        get throws { try revisionStore.snapshotsForHarness() }
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
    var harnessPreparedDrawBrushIdentity: BrushRenderIdentity? {
        activeDrawBrush?.renderIdentity
    }
    var harnessPreparedEraserBrushIdentity: BrushRenderIdentity? {
        activeEraserBrush?.renderIdentity
    }
    var harnessCapturedCompiledBrushIdentity: BrushRenderIdentity? {
        activeStroke?.brush.renderIdentity
    }
    var harnessScheduledAuthoritativeRecords:
        [ProjectedDepositionRecord]
    {
        activeStroke?.frozenHarnessScheduler?.authoritativeRecords ?? []
    }
    var harnessScheduledPredictedRecords: [ProjectedDepositionRecord] {
        activeStroke?.frozenHarnessScheduler?.predictedRecords ?? []
    }
    var harnessTransientDabArenaSnapshot:
        TransientStrokeDabArena.DiagnosticSnapshot
    {
        transientDabArena.diagnosticSnapshot
    }
    var harnessCompiledIsometryOrdinals: Set<UInt8> {
        Set(tilingStrategy.compiledSymmetry.images.map(\.ordinal))
    }
    func removeDepositionEncoderForHarness() -> DepositionEncoder? {
        defer { depositionEncoder = nil }
        return depositionEncoder
    }
    func restoreDepositionEncoderForHarness(_ encoder: DepositionEncoder) {
        depositionEncoder = encoder
    }
    @discardableResult
    func replaceDepositionFrameBudgetForHarness(
        _ budget: DepositionFrameBudget
    ) -> DepositionFrameBudget {
        let previous = depositionFrameBudget
        depositionFrameBudget = budget
        replaceAvailableStrokePreparationWorkspaceForHarness(
            budget: budget
        )
        return previous
    }
    @discardableResult
    func replaceActiveStrokeSchedulerForHarness(
        _ budget: DepositionFrameBudget
    ) -> FrameScheduler? {
        guard let previous = activeStroke?.frozenHarnessScheduler else {
            return nil
        }
        activeStroke?.frozenHarnessScheduler = FrameScheduler(budget: budget)
        return previous
    }
    func restoreActiveStrokeSchedulerForHarness(
        _ scheduler: FrameScheduler
    ) {
        activeStroke?.frozenHarnessScheduler = scheduler
    }
    var harnessPendingInstanceColors: [SIMD4<Float>] {
        activeStroke?.frozenHarnessScheduler?.authoritativeRecords.map(
            \.instance.premultipliedColor
        ) ?? []
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
        try beginFrozenProjectionHarnessExecution(
            radius: GridCanvasContract.brushRadius
        )
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
        radius requestedRadius: Float = GridCanvasContract.brushRadius,
        coverageSymmetry: FootprintCoverageSymmetry = .halfTurnInvariant
    ) throws -> [CellFragment] {
        try beginFrozenProjectionHarnessExecution(radius: requestedRadius)
        counters = GridStructuralCounters()
        counters.newDabsThisEvent = 1
        counters.totalDabsThisStroke = 1
        let fragments = try appendProjectedFragments(
            at: world,
            requestedRadius: requestedRadius,
            coverageSymmetry: coverageSymmetry
        )
        try prepareFrozenProjectionHarnessCommit(
            maximumRetainedBytes: Int.max
        )
        return fragments
    }

    @discardableResult
    func beginFixedProjectedStrokeForHarness(
        at world: WorldPoint
    ) throws -> [CellFragment] {
        try beginFrozenProjectionHarnessExecution(
            radius: GridCanvasContract.brushRadius
        )
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
        try prepareFrozenProjectionHarnessCommit(
            maximumRetainedBytes: Int.max
        )
    }
}
