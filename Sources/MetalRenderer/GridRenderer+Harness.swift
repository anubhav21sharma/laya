import CShaderTypes
import Foundation
import Metal
import PatternEngine

@MainActor
extension GridRenderer {
    func installNativeHarnessBrushes() throws {
        try activateDrawBrush(
            makeNativeHarnessBrush(mode: .draw)
        )
        try activateEraserBrush(
            makeNativeHarnessBrush(mode: .erase)
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

    static func nativeHarnessDefinition(
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
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let encodedLiveClear: Bool
            let encodedReplayClear: Bool
            let encoding = try encodeScheduledDeposition(commandBuffer)
            nativeEncoding = encoding
            encodedLiveClear = encoding.encodedLiveClear
            encodedReplayClear = encoding.encodedReplayClear
            submissions = try finalizeFrameEncoding(
                encodedClear: encodedLiveClear,
                encodedReplayClear: encodedReplayClear,
                uploads: uploads,
                nativeEncoding: nativeEncoding,
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
                emittedHighWater: UInt64(counters.totalInstancesThisStroke),
                encodedIdentityRanges: uploads.map(\.identityRange)
            )
        } catch {
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
            if activeStroke?.compiledBrush != nil {
                for _ in 0..<64 {
                    try prepareCompiledCommitIfReady()
                    if activeStroke?.pendingRevisions != nil {
                        break
                    }
                    _ = try flushPendingLiveForHarness()
                }
                try prepareCompiledCommitIfReady()
            }
            let metrics = try submitCommitForHarness(
                forceFailure: forceCommitFailure
            )
            try drainCompletedOperationsForHarness()
            return metrics
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
        try prepareCompiledCommitIfReady()
        let nativeIsReady = activeStroke?.compiledBrush != nil
            && activeStroke?.scheduler?.authoritativeIsDrained == true
            && activeStroke?.scheduler?.predictedCount == 0
            && !needsReplayClear
        let legacyIsReady = activeStroke?.compiledBrush == nil
            && liveStroke.bakedHighWater == liveStroke.emittedHighWater
            && replayStroke.bakedHighWater == replayStroke.emittedHighWater
        guard activeStroke?.commitRequested == true,
              activeStroke?.pendingTokenBearingFrameCount == 0,
              activeStroke?.pendingRevisions != nil,
              nativeIsReady || legacyIsReady
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
        activeStroke?.compiledBrush?.renderIdentity
    }
    var harnessScheduledAuthoritativeRecords:
        [ProjectedDepositionRecord]
    {
        activeStroke?.scheduler?.authoritativeRecords ?? []
    }
    var harnessScheduledPredictedRecords: [ProjectedDepositionRecord] {
        activeStroke?.scheduler?.predictedRecords ?? []
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
        return previous
    }
    var harnessPendingInstanceColors: [SIMD4<Float>] {
        activeStroke?.scheduler?.authoritativeRecords.map(
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
        radius requestedRadius: Float = GridCanvasContract.brushRadius,
        coverageSymmetry: FootprintCoverageSymmetry = .halfTurnInvariant
    ) throws -> [CellFragment] {
        try beginHarnessExecution(radius: requestedRadius)
        counters = GridStructuralCounters()
        counters.newDabsThisEvent = 1
        counters.totalDabsThisStroke = 1
        let fragments = try appendProjectedFragments(
            at: world,
            requestedRadius: requestedRadius,
            coverageSymmetry: coverageSymmetry
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
