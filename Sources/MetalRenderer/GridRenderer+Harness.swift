import CShaderTypes
import Foundation
import Metal
import PatternEngine

@MainActor
extension HarnessLiveFlushResult {
    func mergingPrecedingSubmissions(
        _ preceding: [HarnessLiveFlushResult]
    ) -> HarnessLiveFlushResult {
        let results = preceding + [self]
        return HarnessLiveFlushResult(
            frame: frame,
            metrics: GPUFrameMetrics(
                cpuEncodeMilliseconds: results.reduce(0) {
                    $0 + $1.metrics.cpuEncodeMilliseconds
                },
                gpuMilliseconds: results.reduce(0) {
                    $0 + $1.metrics.gpuMilliseconds
                },
                eventToSubmitNanoseconds:
                    results.map(\.metrics.eventToSubmitNanoseconds)
                        .max() ?? 0,
                gpuCompletionNanoseconds: results.reduce(0) {
                    GridRenderer.saturatingAdd(
                        $0,
                        $1.metrics.gpuCompletionNanoseconds
                    )
                },
                encodedDabCount: results.reduce(0) {
                    $0 + $1.metrics.encodedDabCount
                },
                encodedInstanceCount: results.reduce(0) {
                    $0 + $1.metrics.encodedInstanceCount
                },
                bufferLeaseCount: results.reduce(0) {
                    $0 + $1.metrics.bufferLeaseCount
                }
            ),
            emittedHighWater: emittedHighWater,
            encodedIdentityRanges:
                results.flatMap(\.encodedIdentityRanges),
            authoritativeBacklogRemaining:
                authoritativeBacklogRemaining,
            replayRetention: replayRetention
        )
    }
}

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
                DocumentColorPipeline.workingPixelFormat.rawValue,
            sampleCount: DocumentColorPipeline.renderSampleCount
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

    public func flushPendingLiveForHarness() async throws
        -> HarnessLiveFlushResult
    {
        let frame: RenderedFrame
        if let transientFrame = try await renderCurrentPaintFrameForHarness(
            width: pixelSize.width,
            height: pixelSize.height,
            includeTransient: true
        ) {
            frame = transientFrame
        } else {
            // A fully clipped/synthetic frame owns no transient texture. The
            // committed sparse plan is still the exact visible result.
            guard let committedFrame = try await
                renderCurrentPaintFrameForHarness(
                width: pixelSize.width,
                height: pixelSize.height,
                includeTransient: false
            ) else { throw MetalRendererError.invalidStrokeLifecycle }
            frame = committedFrame
        }
        return takeHarnessLiveFlushResult(frame: frame)
    }

    private func takeHarnessLiveFlushResult(
        frame: RenderedFrame
    ) -> HarnessLiveFlushResult {
        HarnessLiveFlushResult(
            frame: frame,
            metrics: frame.metrics,
            emittedHighWater: scheduledAuthoritativeIdentityHighWater,
            encodedIdentityRanges:
                takeEncodedAuthoritativeIdentityRangesForHarness(),
            authoritativeBacklogRemaining:
                activeStroke?.frozenHarnessScheduler?
                    .authoritativeCount ?? 0,
            replayRetention: HarnessReplayRetentionSnapshot(
                retainedDabCount:
                    offMainReplayRetentionForHarness.retainedDabCount,
                visibleProjectedInstanceCount:
                    offMainReplayRetentionForHarness
                        .visibleProjectedInstanceCount
            )
        )
    }
    /// Waits until the actor publishes a surface lease, but deliberately does
    /// not submit it. Failure harnesses use this boundary to inject a failure
    /// into a command buffer that actually owns stroke work.
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
    ) async throws -> RenderedFrame {
        guard let frame = try await renderCurrentPaintFrameForHarness(
            width: width,
            height: height,
            includeTransient: compositeLiveIsVisible,
            showGridLines: showGridLines
        ) else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        return frame
    }

    public func finishCommitForHarness() async throws
        -> GPUFrameMetrics
    {
        var frames: [GPUFrameMetrics] = []
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try drainCompletedInteractiveOperations()
            if activeStroke == nil, isIdle { break }
            if let frame = try await renderCurrentPaintFrameForHarness(
                width: pixelSize.width,
                height: pixelSize.height,
                includeTransient: true
            ) {
                frames.append(frame.metrics)
                continue
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard activeStroke == nil, isIdle else {
            throw lastError ?? MetalRendererError.commandFailed(
                "stroke commit exceeded its harness bound"
            )
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
            bufferLeaseCount: frames.reduce(0) {
                $0 + $1.bufferLeaseCount
            }
        )
    }

    /// Drains currently accepted actor input while leaving the stroke editable.
    /// Every transient surface is submitted through the same Context display
    /// owner and acknowledged only after its GPU terminal callback.
    @discardableResult
    func drainPreparedStrokeInputForHarness(
        outputPixelSize: PixelSize
    ) async throws
        -> [HarnessLiveFlushResult]
    {
        var inactivityDeadline = DispatchTime.now().uptimeNanoseconds
            &+ 5_000_000_000
        var submittedFrames: [HarnessLiveFlushResult] = []
        while DispatchTime.now().uptimeNanoseconds < inactivityDeadline {
            try drainCompletedInteractiveOperations()
            if strokePreparationIsQuiescentForAllocationHarness {
                return submittedFrames
            }
            if let frame = try await renderCurrentPaintFrameForHarness(
                width: outputPixelSize.width,
                height: outputPixelSize.height,
                includeTransient: true
            ) {
                submittedFrames.append(
                    takeHarnessLiveFlushResult(frame: frame)
                )
                inactivityDeadline = DispatchTime.now().uptimeNanoseconds
                    &+ 5_000_000_000
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw MetalRendererError.commandFailed(
            "stroke input preparation exceeded its harness bound"
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
              let coordinator = offMainCoordinatorSnapshotForHarness,
              let logicalDabCount = Int(
                  exactly: coordinator.commitMetadata.emittedDabCount
              ),
              let projectedInstanceCount = Int(
                  exactly: scheduledAuthoritativeIdentityHighWater
              )
        else {
            return nil
        }
        return HarnessOffMainDepositionSnapshot(
            logicalDabCount: logicalDabCount,
            projectedInstanceCount: projectedInstanceCount,
            authoritativeBacklog:
                coordinator.authoritativeQueueDepth,
            authoritativeBacklogHighWater:
                max(
                    coordinator.authoritativeQueueHighWater,
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
    var harnessTiling: TilingKind { tilingStrategy.kind }
    func harnessWorldPoint(for screenPoint: ScreenPoint) -> WorldPoint {
        viewport.screenToWorld(screenPoint)
    }
    func harnessCell(for screenPoint: ScreenPoint) -> CellIndex {
        tilingStrategy.cell(containing: viewport.screenToWorld(screenPoint))
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
}
