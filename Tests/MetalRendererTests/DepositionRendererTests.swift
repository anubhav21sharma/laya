import BrushFormat
import CShaderTypes
import EditorCore
import Foundation
import Metal
@testable import MetalRenderer
@testable import MetalRendererDiagnostics
import PatternEngine
import Testing

@Suite("Compiled deposition renderer")
struct DepositionRendererTests {
    @Test
    func facadeDelegatesDisplayAndCommitPolicyToFocusedUnits() {
        let stable = CanvasDisplayCompositor.parameters(
            outputMapping: .affine(.identity),
            transientMode: nil,
            strokeOpacity: 0.2,
            eraserStrength: 0.3,
            showGridLines: true
        )
        #expect(!stable.liveVisible)
        #expect(stable.compositeMode == PatternCompositeWireDraw)
        #expect(stable.strokeOpacity == 1)
        #expect(stable.accumulationLimit == 1)
        #expect(stable.eraserStrength == 1)
        #expect(stable.showGridLines)
        #expect(stable.showCanvasBoundary)

        let transient = CanvasDisplayCompositor.parameters(
            outputMapping: .affine(.identity),
            transientMode: .erase,
            strokeOpacity: 0.65,
            eraserStrength: 0.45,
            showGridLines: false
        )
        #expect(transient.liveVisible)
        #expect(transient.compositeMode == PatternCompositeWireErase)
        #expect(transient.strokeOpacity == 0.65)
        #expect(transient.accumulationLimit == 1)
        #expect(transient.eraserStrength == 0.45)
        #expect(!transient.showGridLines)

        #expect(StrokeCommitter.parameters(
            mode: .draw,
            strokeOpacity: 0.65,
            eraserStrength: 0.45
        ) == DocumentPaintStrokeCompositeParameters(
            mode: .draw,
            strokeOpacity: 0.65,
            accumulationLimit: 1,
            eraserStrength: 1
        ))
        #expect(StrokeCommitter.parameters(
            mode: .erase,
            strokeOpacity: 0.65,
            eraserStrength: 0.45
        ) == DocumentPaintStrokeCompositeParameters(
            mode: .erase,
            strokeOpacity: 0.65,
            accumulationLimit: 1,
            eraserStrength: 0.45
        ))
    }

    @Test
    @MainActor
    func analyticSoftRoundFalloffAndChiselCoverageReachCommittedPixels()
        async throws
    {
        guard let hardSetup = try makeDepositionRendererSetup(),
              let softSetup = try makeDepositionRendererSetup(),
              let chiselSetup = try makeDepositionRendererSetup()
        else {
            return
        }
        let hard = try await hardSetup.compileBrush(
            definition: try analyticShapeDefinition(
                id: "brush.analytic-hard-round",
                shape: .hardRound,
                tipSupport: .analyticEllipse
            )
        )
        let soft = try await softSetup.compileBrush(
            definition: try analyticShapeDefinition(
                id: "brush.analytic-soft-round",
                shape: .softRound,
                tipSupport: .analyticEllipse
            )
        )
        let chisel = try await chiselSetup.compileBrush(
            definition: try analyticShapeDefinition(
                id: "brush.analytic-chisel",
                shape: .chisel,
                tipSupport: .analyticRectangle
            )
        )

        let hardPixels = try await committedTap(
            renderer: hardSetup.renderer,
            brush: hard,
            token: RendererOperationToken(rawValue: 15_001)
        )
        let softPixels = try await committedTap(
            renderer: softSetup.renderer,
            brush: soft,
            token: RendererOperationToken(rawValue: 15_002)
        )
        let chiselPixels = try await committedTap(
            renderer: chiselSetup.renderer,
            brush: chisel,
            token: RendererOperationToken(rawValue: 15_003)
        )

        let softCenter = alpha(softPixels, x: 32, y: 32, width: 64)
        let softMidpoint = alpha(softPixels, x: 37, y: 32, width: 64)
        let hardMidpoint = alpha(hardPixels, x: 37, y: 32, width: 64)
        let softCorner = alpha(softPixels, x: 39, y: 39, width: 64)
        let chiselCorner = alpha(chiselPixels, x: 39, y: 39, width: 64)

        #expect(softCenter > softMidpoint)
        #expect(softMidpoint > 0)
        #expect(Int(hardMidpoint) - Int(softMidpoint) >= 64)
        #expect(Int(chiselCorner) - Int(softCorner) >= 128)
    }

    @Test
    func opaqueSupportOracleDefinesPlainDiskAndRejectsWrongGeometry() {
        let authority = OpaqueStampSupportOracle.plainDisk(
            pixelSize: PixelSize(width: 64, height: 48),
            center: SIMD2<Float>(31.25, 19.75),
            radius: 7.5
        )
        let exact = authority.analyticMask()

        let exactComparison = authority.compare(exact)
        #expect(exactComparison.isAccepted)
        #expect(!authority.compare(exact.shifted(dx: 1, dy: 0)).isAccepted)
        #expect(!authority.compare(exact.shifted(dx: 2, dy: 0)).isAccepted)
        #expect(!authority.compare(exact.mirroredHorizontally()).isAccepted)
        let expandedComparison = authority.compare(
            exact.expandedSupportToTheRight(
                by: exactComparison.supportBoundsEdgeTolerance + 1
            )
        )
        #expect(!expandedComparison.isAccepted)
        #expect(
            expandedComparison.maximumSupportBoundsEdgeDelta
                > expandedComparison.supportBoundsEdgeTolerance
        )

        let radialConfiguration = RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 7,
            center: WorldPoint(x: 31.5, y: 23.5),
            referenceAngleRadians: -0.2
        )
        let radialAuthority = OpaqueStampSupportOracle.radialHardRound(
            canvasSize: PixelSize(width: 64, height: 48),
            sourceCenter: WorldPoint(x: 42.25, y: 27.75),
            radius: 5.5,
            configuration: radialConfiguration
        )
        let radialExact = radialAuthority.analyticMask()
        #expect(radialAuthority.compare(radialExact).isAccepted)
        // A displacement beyond the wider radial presentation annulus must
        // still be rejected; the derived boundary is not a permissive match.
        #expect(
            !radialAuthority.compare(
                radialExact.shifted(dx: 4, dy: 0)
            ).isAccepted
        )
    }

    @Test
    func opaqueSupportOracleDefinesPeriodicWrapAndRadialOrbit() {
        let periodic = OpaqueStampSupportOracle.periodicHardRound(
            tileSize: PixelSize(width: 64, height: 80),
            worldCenter: SIMD2<Float>(62.25, 31.75),
            radius: 6.5,
            tiling: .grid
        )
        let periodicMask = periodic.analyticMask()
        #expect(periodic.compare(periodicMask).isAccepted)
        #expect(!periodic.compare(
            periodicMask.shifted(dx: 2, dy: 0)
        ).isAccepted)

        let radialConfiguration = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 7,
            center: WorldPoint(x: 45.5, y: 39.5),
            referenceAngleRadians: 0.19
        )
        let radial = OpaqueStampSupportOracle.radialHardRound(
            canvasSize: PixelSize(width: 112, height: 96),
            sourceCenter: WorldPoint(x: 73.25, y: 51.75),
            radius: 4.75,
            configuration: radialConfiguration
        )
        let radialMask = radial.analyticMask()
        #expect(radial.compare(radialMask).isAccepted)
        #expect(!radial.compare(
            radialMask.mirroredHorizontally()
        ).isAccepted)
    }

    @Test
    @MainActor
    func diagnosticsComeFromActualSchedulerEncodingPoolAndTimestamps()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.diagnostics")
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 9_001)

        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12, y: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let queued = try #require(
            setup.renderer.offMainPreparationMailboxSnapshotForTesting
        ).input
        #expect(queued.authoritativeHighWater > 0)
        #expect(
            queued.authoritativeHighWater
                >= queued.authoritativePendingSampleCount
        )

        try setup.renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 48, y: 48)
        )
        let completion = try await setup.renderer.finishCommitForHarness()
        let diagnostics =
            setup.renderer.brushLabDiagnosticSnapshot.deposition

        #expect(completion.eventToSubmitNanoseconds > 0)
        #expect(completion.gpuCompletionNanoseconds > 0)
        #expect(diagnostics.authoritativePending == 0)
        #expect(diagnostics.predictedPending == 0)
        #expect(completion.encodedDabCount > 0)
        #expect(completion.encodedInstanceCount > 0)
        #expect(
            diagnostics.strokeEncodedInstanceCount
                >= UInt64(diagnostics.lastFrameEncodedInstanceCount)
        )
        #expect(diagnostics.bufferLeaseHighWater == 0)
        #expect(diagnostics.currentBufferLeaseCount == 0)
        #expect(
            setup.renderer.offMainSurfaceSnapshotForTesting?
                .surfaceLeaseHighWater == 1
        )
        #expect(diagnostics.eventToSubmit.p50 > 0)
        #expect(diagnostics.gpuCompletion.p50 > 0)
        #expect(setup.renderer.isIdle)
    }

    @Test
    @MainActor
    func actualDelayedSubmissionRecordsAProductionMissedFrame()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            id: "brush.actual-missed-frame"
        )
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 9_002)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began),
            style: depositionStyle(brush, compositeMode: .draw)
        )

        try await Task.sleep(for: .milliseconds(25))
        _ = try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 1
        )

        let telemetry =
            setup.renderer.brushLabDiagnosticSnapshot.deposition
        #expect(telemetry.eventToSubmit.p50 >= 16_666_667)
        #expect(telemetry.missedFrameCount > 0)
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func pointerDownWithoutPreparedBrushFailsBeforeMutation() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.uninstalled")
        let before = try await depositionCommittedBytes(setup.renderer)

        #expect(throws: MetalRendererError.compiledBrushUnavailable(.draw)) {
            try setup.renderer.beginStroke(
                token: RendererOperationToken(rawValue: 1),
                sample: depositionSample(.began),
                style: depositionStyle(brush, compositeMode: .draw)
            )
        }

        #expect(try await depositionCommittedBytes(setup.renderer) == before)
        #expect(setup.renderer.isIdle)
    }

    @Test
    @MainActor
    func renderIdentityMismatchFailsBeforeMutation() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.identity")
        try setup.renderer.activateDrawBrush(brush)
        let before = try await depositionCommittedBytes(setup.renderer)
        let mismatchedIdentity = try BrushRenderIdentity(
            definitionID: brush.program.definition.id,
            semanticHash: String(repeating: "f", count: 64)
        )
        let style = StrokeRenderStyle(
            color: .black,
            diameter: 20,
            compositeMode: .draw,
            eraserStrength: 1,
            program: brush.program,
            renderIdentity: mismatchedIdentity,
            seed: 2
        )

        #expect(throws: MetalRendererError.compiledBrushIdentityMismatch) {
            try setup.renderer.beginStroke(
                token: RendererOperationToken(rawValue: 2),
                sample: depositionSample(.began),
                style: style
            )
        }

        #expect(try await depositionCommittedBytes(setup.renderer) == before)
        #expect(setup.renderer.isIdle)
    }

    @Test
    @MainActor
    func installedCompiledBrushRejectsMismatchedIdentityAndAcceptsMatching()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.compatibility")
        try setup.renderer.activateDrawBrush(brush)

        let mismatchedIdentity = try BrushRenderIdentity(
            definitionID: brush.program.definition.id,
            semanticHash: String(repeating: "f", count: 64)
        )
        let mismatchedNativeStyle = StrokeRenderStyle(
            color: .black,
            diameter: 20,
            compositeMode: .draw,
            eraserStrength: 1,
            program: brush.program,
            renderIdentity: mismatchedIdentity,
            seed: 2
        )
        let beforeMismatch = try await depositionCommittedBytes(setup.renderer)
        #expect(throws: MetalRendererError.compiledBrushIdentityMismatch) {
            try setup.renderer.beginStroke(
                token: RendererOperationToken(rawValue: 92),
                sample: depositionSample(.began),
                style: mismatchedNativeStyle
            )
        }
        #expect(
            try await depositionCommittedBytes(setup.renderer)
                == beforeMismatch
        )
        #expect(setup.renderer.isIdle)

        let matchingToken = RendererOperationToken(rawValue: 93)
        try setup.renderer.beginStroke(
            token: matchingToken,
            sample: depositionSample(.began),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        #expect(
            setup.renderer.harnessCapturedCompiledBrushIdentity
                == brush.renderIdentity
        )
        try setup.renderer.cancelStroke(token: matchingToken)
    }

    @Test
    @MainActor
    func drawAndEraseCaptureDistinctPreparedBrushes() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let draw = try await setup.compileBrush(id: "brush.draw")
        let erase = try await setup.compileBrush(id: "brush.erase")
        try setup.renderer.activateDrawBrush(draw)
        try setup.renderer.activateEraserBrush(erase)

        let drawToken = RendererOperationToken(rawValue: 3)
        try setup.renderer.beginStroke(
            token: drawToken,
            sample: depositionSample(.began),
            style: depositionStyle(draw, compositeMode: .draw)
        )
        #expect(
            setup.renderer.harnessCapturedCompiledBrushIdentity
                == draw.renderIdentity
        )
        try await awaitInstalledPaintTransientSource(setup.renderer)
        try setup.renderer.cancelStroke(token: drawToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)

        let eraseToken = RendererOperationToken(rawValue: 4)
        try setup.renderer.beginStroke(
            token: eraseToken,
            sample: depositionSample(.began),
            style: depositionStyle(erase, compositeMode: .erase)
        )
        #expect(
            setup.renderer.harnessCapturedCompiledBrushIdentity
                == erase.renderIdentity
        )
        try setup.renderer.cancelStroke(token: eraseToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
    }

    @Test
    @MainActor
    func activeStrokeRetainsBrushAcrossCompilerSelectionChurn() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let captured = try await setup.compileBrush(id: "brush.captured")
        try setup.renderer.activateDrawBrush(captured)
        let token = RendererOperationToken(rawValue: 5)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began),
            style: depositionStyle(captured, compositeMode: .draw)
        )

        _ = try await setup.compileBrush(id: "brush.editor-selection")

        #expect(
            setup.renderer.harnessCapturedCompiledBrushIdentity
                == captured.renderIdentity
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func activationDuringStrokeFailsWithoutAlteringCapturedBrush()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let first = try await setup.compileBrush(id: "brush.first")
        let replacement = try await setup.compileBrush(id: "brush.replacement")
        try setup.renderer.activateDrawBrush(first)
        let token = RendererOperationToken(rawValue: 6)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began),
            style: depositionStyle(first, compositeMode: .draw)
        )

        #expect(throws: MetalRendererError.compiledBrushActivationRequiresIdle) {
            try setup.renderer.activateDrawBrush(replacement)
        }
        #expect(
            setup.renderer.harnessCapturedCompiledBrushIdentity
                == first.renderIdentity
        )
        #expect(setup.renderer.hasActiveStroke)
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func activationPerformsNoCompilerOrResourcePreparationWork() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.prepared")
        let before = setup.compiler.debugCounters

        try setup.renderer.activateDrawBrush(brush)
        try setup.renderer.activateEraserBrush(brush)

        #expect(setup.compiler.debugCounters == before)
    }

    @Test
    @MainActor
    func inconsistentMaterialBindingCannotReplacePreparedBrush()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let supported = try await setup.compileBrush(id: "brush.material")
        let alternateBase = try stageCMetalTestProgram(
            id: "brush.alternate-material"
        ).definition
        let alternate = try await setup.compileBrush(
            definition: try depositionDefinitionCopy(
                alternateBase,
                material: BrushMaterialDefinition(
                    accumulation: .uniformGlaze,
                    interaction: .none,
                    edgeTreatment: .none,
                    strength: 0.5,
                    wetness: 0,
                    bleedRadius: 0,
                    softenPasses: 0,
                    accumulationLimit: 0.5,
                    interactionParameters: nil
                )
            )
        )
        try setup.renderer.activateDrawBrush(supported)
        let forged = CompiledBrush(
            program: supported.program,
            backendContract: supported.backendContract,
            renderIdentity: supported.renderIdentity,
            pipelineKey: supported.primaryComponent.pipelineKey,
            uniformTemplate: supported.primaryComponent.uniformTemplate,
            textures: supported.primaryComponent.textures,
            cursorTipProfile: supported.primaryComponent.cursorTipProfile,
            depositionPipeline:
                supported.primaryComponent.depositionPipeline,
            depositionMaterial:
                alternate.primaryComponent.depositionMaterial,
            residentByteCount: supported.residentByteCount,
            report: supported.report,
            diagnostics: supported.diagnostics,
            cacheKeys: supported.cacheKeys
        )

        #expect(throws: MetalRendererError.invalidCompiledBrush) {
            try setup.renderer.activateDrawBrush(forged)
        }
        #expect(
            setup.renderer.harnessPreparedDrawBrushIdentity
                == supported.renderIdentity
        )
    }

    @Test
    @MainActor
    func nativeProjectionQueuesFrozenDepositionWithCompiledOrdinals()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.projected")
        try setup.renderer.activateDrawBrush(brush)
        try await setup.renderer.applyTiling(.squareRotation)
        let token = RendererOperationToken(rawValue: 7)

        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 8, y: 8),
            style: depositionStyle(brush, compositeMode: .draw)
        )

        _ = try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 1
        )
        let surface = try #require(
            setup.renderer.offMainSurfaceSnapshotForTesting
        )
        #expect(surface.encodedInstanceCount > 0)
        #expect(
            setup.renderer.offMainReplayRetentionForHarness
                .retainedDabCount == 1
        )
        #expect(
            setup.renderer.harnessCompiledIsometryOrdinals.count > 1
        )
        try setup.renderer.cancelStroke(token: token)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
    }

    @Test
    @MainActor
    func liveFlushCoalescesEveryPreparedIdentityPageSincePriorFlush()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            id: "brush.identity-page-coalescing"
        )
        try setup.renderer.activateDrawBrush(brush)
        setup.renderer.replaceDepositionFrameBudgetForHarness(
            try depositionFrameBudget(
                maximumAuthoritativeInstances: 4
            )
        )
        let token = RendererOperationToken(rawValue: 7_001)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 8, y: 8),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let preparationOnly = try await setup.renderer
            .flushPendingLiveForHarness()
        #expect(preparationOnly.metrics.encodedInstanceCount == 0)
        #expect(preparationOnly.metrics.eventToSubmitNanoseconds > 0)
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 56, y: 56)
        )

        let result = try await setup.renderer
            .flushAcceptedStrokeInputForHarness(
                outputPixelSize: setup.renderer.pixelSize
            )

        #expect(result.emittedHighWater > 1)
        let audit = try DepositionHarnessRunner
            .auditEncodedInstanceIdentityRanges(
                sceneName: "identity-page-coalescing",
                previousEncodedHighWater: 0,
                emittedHighWater: result.emittedHighWater,
                encodedIdentityRanges: result.encodedIdentityRanges
            )
        #expect(
            audit.encodedHighWater == result.emittedHighWater
        )
        #expect(result.metrics.encodedInstanceCount > 0)
        #expect(result.metrics.eventToSubmitNanoseconds > 0)
        try setup.renderer.cancelStroke(token: token)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
    }

    @Test
    @MainActor
    func nativePredictionReplacementDoesNotAlterAuthoritativeQueue()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.prediction")
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 8)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 1
        )
        try await awaitOffMainPreparationQuiescence(setup.renderer)
        let beforePrediction = await setup.renderer
            .offMainSchedulerSnapshotForTesting()
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 36)
        )
        let firstPrediction = try await awaitOffMainSchedulerMutation(
            setup.renderer,
            after: beforePrediction.transientMutationVersion
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 52)
        )
        let replacement = try await awaitOffMainSchedulerMutation(
            setup.renderer,
            after: firstPrediction.transientMutationVersion
        )

        #expect(firstPrediction.transientMutationVersion > 0)
        #expect(
            replacement.transientMutationVersion
                > firstPrediction.transientMutationVersion
        )
        #expect(replacement.authoritativePending
            == firstPrediction.authoritativePending)
        #expect(replacement.authoritativeHighWater
            == firstPrediction.authoritativeHighWater)
        #expect(firstPrediction.predictedHighWater > 0)
        #expect(replacement.predictedHighWater
            >= firstPrediction.predictedHighWater)
        try setup.renderer.cancelStroke(token: token)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
    }

    // Retired Main prediction-pressure duplicate; covered by
    // predictionOverloadShedsOnlyTruePrediction.
    @Test
    @MainActor
    func predictionPressureTruncatesBeforeAuthoritativeSettlement()
        async throws
    {
        try await StrokeFrameSchedulerTests()
            .predictionOverloadShedsOnlyTruePrediction()
    }

    @Test
    @MainActor
    func scheduledNativeDepositionRendersThroughPreparedPipeline()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.render")
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 9)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began),
            style: depositionStyle(brush, compositeMode: .draw)
        )

        _ = try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 1
        )
        let frame = try await setup.renderer.renderOffscreenDisplayForHarness(
            width: 64,
            height: 64,
            showGridLines: false
        )

        #expect(
            depositionTextureBytes(frame.texture)
                .enumerated()
                .contains { index, value in
                    index % 4 == 3 && value > 0
                }
        )
        #expect(
            setup.renderer.harnessScheduledAuthoritativeRecords.isEmpty
        )
        #expect(setup.renderer.harnessReservedInstanceBufferCount == 0)
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func translucentOneDabAppliesStrokeAlphaExactlyOnceEverywhere()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.alpha-once")
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 9_002)
        let half = InkColor(
            red: 1,
            green: 0,
            blue: 0,
            alpha: 0.5
        )!
        let style = StrokeRenderStyle(
            color: half,
            diameter: 20,
            compositeMode: .draw,
            eraserStrength: 1,
            program: brush.program,
            renderIdentity: brush.renderIdentity,
            seed: 1
        )

        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began),
            style: style
        )
        try setup.renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended)
        )
        let live = depositionTextureBytes(
            try await prepareOffMainCommit(setup.renderer).texture
        )
        _ = try await setup.renderer.finishCommitForHarness()
        let committed = depositionTextureBytes(
            try await setup.renderer.renderOffscreenDisplayForHarness(
                width: 64,
                height: 64,
                showGridLines: false
            ).texture
        )
        let canonical = try await depositionCommittedBytes(setup.renderer)
        let center = (32 * 64 + 32) * 4

        #expect((126...129).contains(Int(canonical[center + 3])))
        #expect((126...129).contains(Int(canonical[center + 2])))
        #expect(canonical[center] == 0)
        #expect(canonical[center + 1] == 0)
        #expect(maximumChannelDelta(live, committed) <= 1)
    }

    @Test
    @MainActor
    func foreignTokenCannotMutateOrTerminateNativeStroke() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.token-isolation")
        try setup.renderer.activateDrawBrush(brush)
        let accepted = RendererOperationToken(rawValue: 101)
        let foreign = RendererOperationToken(rawValue: 102)
        var completions: [RendererOperationCompletion] = []
        setup.renderer.onOperationCompleted = { completions.append($0) }

        try setup.renderer.beginStroke(
            token: accepted,
            sample: depositionSample(.began, x: 16),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let scheduledBefore =
            setup.renderer.harnessScheduledAuthoritativeRecords
        let committedBefore = try await depositionCommittedBytes(setup.renderer)

        #expect(throws: MetalRendererError.invalidRendererOperationToken) {
            try setup.renderer.appendStroke(
                token: foreign,
                sample: depositionSample(.moved, x: 32)
            )
        }
        #expect(throws: MetalRendererError.invalidRendererOperationToken) {
            try setup.renderer.requestStrokeCommit(
                token: foreign,
                sample: depositionSample(.ended, x: 48)
            )
        }
        #expect(throws: MetalRendererError.invalidRendererOperationToken) {
            try setup.renderer.cancelStroke(token: foreign)
        }

        #expect(
            setup.renderer.harnessScheduledAuthoritativeRecords
                == scheduledBefore
        )
        #expect(
            try await depositionCommittedBytes(setup.renderer)
                == committedBefore
        )
        #expect(setup.renderer.activeStroke?.token == accepted)
        #expect(completions.isEmpty)

        try setup.renderer.requestStrokeCommit(
            token: accepted,
            sample: depositionSample(.ended, x: 48)
        )
        _ = try await setup.renderer.finishCommitForHarness()

        #expect(completions.count == 1)
        guard case let .rasterSuccess(receipt) = completions.first else {
            Issue.record("Expected exactly one accepted-token receipt")
            return
        }
        #expect(receipt.token == accepted)
        #expect(completions.count == 1)
    }

    @Test
    @MainActor
    func nativePointerCancelCreatesNoCommit() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.cancel")
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 11)
        var completions: [RendererOperationCompletion] = []
        setup.renderer.onOperationCompleted = { completions.append($0) }
        let committedBefore = try await depositionCommittedBytes(setup.renderer)

        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        try setup.renderer.cancelStroke(token: token)

        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(setup.renderer.isIdle)
        #expect(
            try await depositionCommittedBytes(setup.renderer)
                == committedBefore
        )
        #expect(completions.isEmpty)
        #expect(setup.renderer.harnessReservedInstanceBufferCount == 0)
    }

    @Test
    @MainActor
    func nativeSchedulerOverflowIsAtomicAndRendererRecovers()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        let capacity = 4
        setup.renderer.replaceDepositionFrameBudgetForHarness(
            try depositionFrameBudget(
                maximumAuthoritativeInstances: capacity,
                maximumPendingAuthoritativeInstances: capacity
            )
        )
        let token = RendererOperationToken(rawValue: 24)
        var reportedErrors: [MetalRendererError] = []
        var completions: [RendererOperationCompletion] = []
        setup.renderer.onError = { reportedErrors.append($0) }
        setup.renderer.onOperationCompleted = { completions.append($0) }
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 8),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let overflow = (0..<256).map { index in
            depositionSample(
                .moved,
                x: 12 + Float(index % 40)
            )
        }

        var submittedError: Error?
        do {
            try setup.renderer.appendStrokeBatch(
                token: token,
                samples: overflow
            )
        } catch {
            submittedError = error
        }
        #expect(
            submittedError as? MetalRendererError
                == .strokeSampleCapacityExceeded(capacity)
        )
        #expect(!(submittedError is StrokeInputQueueError))
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(reportedErrors == [.strokeSampleCapacityExceeded(capacity)])
        #expect(
            completions.filter {
                if case let .failure(completedToken, error) = $0 {
                    return completedToken == token
                        && error == .strokeSampleCapacityExceeded(capacity)
                }
                return false
            }.count == 1
        )
        #expect(setup.renderer.isIdle)

        let recoveryToken = RendererOperationToken(rawValue: 25)
        try setup.renderer.beginStroke(
            token: recoveryToken,
            sample: depositionSample(.began, x: 8),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        try setup.renderer.cancelStroke(token: recoveryToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(setup.renderer.isIdle)
    }

    @Test
    @MainActor
    func nativePredictionDoesNotChangeCommitOrActualDabIdentity()
        async throws
    {
        guard let baseline = try makeDepositionRendererSetup(),
              let predicted = try makeDepositionRendererSetup()
        else {
            return
        }
        let definition = try stageCMetalTestProgram(
            id: "brush.prediction-parity",
            replayMode: .replayTail,
            replayLimits: BrushRecipePolicy.replayTailLimits
        ).definition
        let baselineBrush = try await baseline.compileBrush(
            definition: definition
        )
        let predictedBrush = try await predicted.compileBrush(
            definition: definition
        )
        try baseline.renderer.activateDrawBrush(baselineBrush)
        try predicted.renderer.activateDrawBrush(predictedBrush)
        var baselineDabs: [LogicalDab] = []
        var predictedDabs: [LogicalDab] = []
        baseline.renderer.onLogicalDabsGenerated = {
            if !$0.isPredicted {
                baselineDabs.append($0)
            }
        }
        predicted.renderer.onLogicalDabsGenerated = {
            if !$0.isPredicted {
                predictedDabs.append($0)
            }
        }
        let baselineToken = RendererOperationToken(rawValue: 28)
        let predictedToken = RendererOperationToken(rawValue: 29)

        try baseline.renderer.beginStroke(
            token: baselineToken,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(baselineBrush, compositeMode: .draw)
        )
        try predicted.renderer.beginStroke(
            token: predictedToken,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(predictedBrush, compositeMode: .draw)
        )
        try predicted.renderer.appendStroke(
            token: predictedToken,
            sample: depositionPredictedSample(x: 28)
        )
        try baseline.renderer.appendStroke(
            token: baselineToken,
            sample: depositionSample(.moved, x: 40)
        )
        try predicted.renderer.appendStroke(
            token: predictedToken,
            sample: depositionSample(.moved, x: 40)
        )
        try predicted.renderer.appendStroke(
            token: predictedToken,
            sample: depositionPredictedSample(x: 56)
        )
        try baseline.renderer.requestStrokeCommit(
            token: baselineToken,
            sample: depositionSample(.ended, x: 52)
        )
        try predicted.renderer.requestStrokeCommit(
            token: predictedToken,
            sample: depositionSample(.ended, x: 52)
        )
        _ = try await baseline.renderer.finishCommitForHarness()
        _ = try await predicted.renderer.finishCommitForHarness()

        #expect(predictedDabs == baselineDabs)
        let predictedPixels = try await depositionCommittedBytes(
            predicted.renderer
        )
        let baselinePixels = try await depositionCommittedBytes(
            baseline.renderer
        )
        #expect(predictedPixels == baselinePixels)
    }

    @Test
    @MainActor
    func nativeFramePartitioningDoesNotChangeCommittedBytes()
        async throws
    {
        guard let wide = try makeDepositionRendererSetup(),
              let narrow = try makeDepositionRendererSetup()
        else {
            return
        }
        let wideBrush = try await wide.compileBrush(
            id: "brush.partition-parity"
        )
        let narrowBrush = try await narrow.compileBrush(
            id: "brush.partition-parity"
        )
        try wide.renderer.activateDrawBrush(wideBrush)
        try narrow.renderer.activateDrawBrush(narrowBrush)
        narrow.renderer.replaceDepositionFrameBudgetForHarness(
            try depositionFrameBudget(
                maximumAuthoritativeInstances: 1,
                maximumPredictedInstances: 1
            )
        )

        try await commitNativeStroke(
            renderer: wide.renderer,
            brush: wideBrush,
            token: RendererOperationToken(rawValue: 30)
        )
        try await commitNativeStroke(
            renderer: narrow.renderer,
            brush: narrowBrush,
            token: RendererOperationToken(rawValue: 31)
        )

        let narrowPixels = try await depositionCommittedBytes(narrow.renderer)
        let widePixels = try await depositionCommittedBytes(wide.renderer)
        #expect(narrowPixels == widePixels)
    }

    @Test
    @MainActor
    func nativeInputUsesBoundedActorMailboxAfterWarmup() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        try await setup.renderer.applyTiling(.squareRotation)
        let token = RendererOperationToken(rawValue: 39)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 0),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let workspaceIdentity =
            setup.renderer.offMainStrokeWorkspaceIdentityForTesting
        let workspaceInstallationCount = setup.renderer
            .offMainStrokeWorkspaceInstallationCountForTesting

        for batchIndex in 0..<2 {
            try setup.renderer.appendStrokeBatch(
                token: token,
                samples: (0..<32).map { offset in
                    depositionSample(
                        .moved,
                        x: Float((batchIndex * 32 + offset) % 96) * 0.5
                    )
                }
            )
        }
        try await driveOffMainStroke(setup.renderer) {
            setup.renderer.strokePreparationIsQuiescentForAllocationHarness
        }
        let warmed = try #require(
            setup.renderer.offMainPreparationMailboxSnapshotForTesting
        )

        for batchIndex in 2..<6 {
            try setup.renderer.appendStrokeBatch(
                token: token,
                samples: (0..<32).map { offset in
                    depositionSample(
                        .moved,
                        x: Float((batchIndex * 32 + offset) % 96) * 0.5
                    )
                }
            )
        }
        try setup.renderer.appendStrokeBatch(
            token: token,
            samples: (0..<64).map { offset in
                depositionPredictedSample(x: Float(offset) * 0.5)
            }
        )
        try await driveOffMainStroke(setup.renderer) {
            setup.renderer.strokePreparationIsQuiescentForAllocationHarness
        }
        let measured = try #require(
            setup.renderer.offMainPreparationMailboxSnapshotForTesting
        )

        #expect(measured.input.authoritativeCapacity == 12_288)
        #expect(measured.input.predictionCapacity == 64)
        #expect(
            measured.input.authoritativeStorageCapacity
                == warmed.input.authoritativeStorageCapacity
        )
        #expect(
            measured.input.predictionStorageCapacity
                == warmed.input.predictionStorageCapacity
        )
        #expect(measured.resultStorageCapacity == warmed.resultStorageCapacity)
        #expect(measured.resultHighWater == 1)
        #expect(
            setup.renderer.offMainStrokeWorkspaceIdentityForTesting
                == workspaceIdentity
        )
        #expect(
            setup.renderer.offMainStrokeWorkspaceInstallationCountForTesting
                == workspaceInstallationCount
        )
        try setup.renderer.cancelStroke(token: token)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
    }

    @Test
    func inputPathAuditCountsRepeatedEqualSizedStorageAllocations() {
        var audit = InputPathStorageAudit()
        audit.recordCollectionStorageAllocation(capacity: 64)
        audit.armAfterWarmup()

        audit.recordCollectionStorageAllocation(capacity: 64)
        audit.recordCollectionStorageAllocation(capacity: 64)

        #expect(audit.snapshot.allocationEventCountAfterWarmup == 2)
    }

    @Test
    func allocatorProbeDetectsArrayAndAcceptsProductionRoute() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            root.appendingPathComponent(
                "scripts/run-brush-input-allocation-probe.sh"
            ).path,
            root.appendingPathComponent(
                ".build/brush-input-allocation-probe-tests"
            ).path,
            "release",
        ]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let outputData =
            outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: outputData, as: UTF8.self)

        #expect(process.terminationStatus == 0, "\(output)")
        #expect(
            output.contains(
                "ALLOCATOR PROBE SELF-TEST PASS allocations="
            ),
            "\(output)"
        )
        #expect(
            output.contains(
                "ALLOCATOR PROBE PRODUCTION PASS allocations=0"
            ),
            "\(output)"
        )
    }

    @Test
    @MainActor
    func nativePreviewMatchesCommittedPixelsWithinOneChannelValue()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.preview-commit")
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 32)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 16),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 48)
        )
        try setup.renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 48)
        )
        let preview = depositionTextureBytes(
            try await prepareOffMainCommit(setup.renderer).texture
        )

        _ = try await setup.renderer.finishCommitForHarness()
        let committed = depositionTextureBytes(
            try await setup.renderer.renderOffscreenDisplayForHarness(
                width: 64,
                height: 64,
                showGridLines: false
            ).texture
        )

        #expect(maximumChannelDelta(preview, committed) <= 1)
    }
    @Test
    @MainActor
    func nativeAppendOnlyEstimatedSuffixCommitsThroughActor() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let definition = try stageCMetalTestProgram(
            id: "brush.append-only-estimated",
            replayMode: .appendOnly
        ).definition
        let brush = try await setup.compileBrush(definition: definition)
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 41)

        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionEstimatedSample(
                .moved,
                x: 28,
                index: 60,
                expecting: [.pressure]
            )
        )
        try setup.renderer.finishStrokeTransient(
            token: token,
            sample: depositionSample(.ended, x: 44)
        )
        try setup.renderer.commitFinishedStroke(token: token)
        _ = try await setup.renderer.finishCommitForHarness()

        #expect(setup.renderer.isIdle)
        #expect(
            try await depositionCommittedBytes(setup.renderer)
                .contains { $0 != 0 }
        )
        #expect(
            setup.renderer.offMainSurfaceSnapshotForTesting?
                .encodedInstanceCount ?? 0 > 0
        )
        #expect(
            setup.renderer.instancePool.diagnosticSnapshot
                .strokeLeaseHighWater == 0
        )
    }

    @Test
    @MainActor
    func nativeFractionalEraserPreviewMatchesCommitAfterPanAndZoom()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateEraserBrush(brush)
        let initialBytes = depositionNonuniformCanonicalBytes()
        try await setup.renderer.restoreCommittedDocument(
            CommittedDocumentSnapshot(
                canvasSize: setup.renderer.pixelSize,
                documentConfiguration: setup.renderer.documentConfiguration,
                documentDomainLocked: true,
                radialGeometryLocked: false,
                storage: .singleRaster(
                    bgra8PremultipliedBytes: initialBytes
                )
            )
        )
        setup.renderer.pan(byScreenDelta: SIMD2<Float>(0.37, -0.61))
        setup.renderer.zoom(
            by: 1.37,
            anchor: ScreenPoint(x: 19.25, y: 23.75)
        )
        let token = RendererOperationToken(rawValue: 44)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 27.4, y: 29.2),
            style: depositionStyle(
                brush,
                compositeMode: .erase,
                diameter: 13,
                eraserStrength: 0.6
            )
        )
        try setup.renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 38.6, y: 35.7)
        )
        let live = depositionTextureBytes(
            try await prepareOffMainCommit(
                setup.renderer,
                outputPixelSize: PixelSize(width: 79, height: 73)
            ).texture
        )

        _ = try await setup.renderer.finishCommitForHarness()
        let committed = depositionTextureBytes(
            try await setup.renderer.renderOffscreenDisplayForHarness(
                width: 79,
                height: 73,
                showGridLines: false
            ).texture
        )
        #expect(maximumChannelDelta(live, committed) <= 1)
    }

    @Test
    @MainActor
    func nativeOverlappingEraserDabsApplyStrengthOnce()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            id: "brush.overlap-eraser"
        )
        try setup.renderer.activateDrawBrush(brush)
        try setup.renderer.activateEraserBrush(brush)
        try await commitNativeStroke(
            renderer: setup.renderer,
            brush: brush,
            token: RendererOperationToken(rawValue: 45)
        )
        #expect(
            try await depositionCenterBGRA(setup.renderer)[3] == 255
        )

        let token = RendererOperationToken(rawValue: 46)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 28),
            style: depositionStyle(
                brush,
                compositeMode: .erase,
                diameter: 24,
                eraserStrength: 0.5
            )
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 34)
        )
        try setup.renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 40)
        )
        _ = try await setup.renderer.finishCommitForHarness()
        #expect(
            (125...130).contains(
                Int(try await depositionCenterBGRA(setup.renderer)[3])
            )
        )
    }

    @Test
    @MainActor
    func nativeInkOffMainPreparationIsBatchPartitionInvariant()
        async throws
    {
        guard let incremental = try makeDepositionRendererSetup(),
              let partitioned = try makeDepositionRendererSetup()
        else { return }
        let incrementalBrush = try await incremental.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        let partitionedBrush = try await partitioned.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        requireSendableRenderState(incrementalBrush.renderState)
        try incremental.renderer.activateDrawBrush(incrementalBrush)
        try partitioned.renderer.activateDrawBrush(partitionedBrush)
        let incrementalToken = RendererOperationToken(rawValue: 90_001)
        let partitionedToken = RendererOperationToken(rawValue: 90_002)
        let began = depositionSample(.began, x: 8, y: 24)
        let moved = (1...20).map { index in
            StrokeSample.mouse(
                position: ScreenPoint(
                    x: 8 + Float(index) * 2,
                    y: 24 + Float(index % 4)
                ),
                timestamp: TimeInterval(index) / 240,
                phase: .moved
            )
        }
        try incremental.renderer.beginStroke(
            token: incrementalToken,
            sample: began,
            style: depositionStyle(
                incrementalBrush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try partitioned.renderer.beginStroke(
            token: partitionedToken,
            sample: began,
            style: depositionStyle(
                partitionedBrush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try incremental.renderer.appendStrokeBatch(
            token: incrementalToken,
            samples: moved
        )
        let partitionWidths = [1, 7, 3, 5, 4]
        var partitionStart = 0
        var partitionIndex = 0
        while partitionStart < moved.count {
            let partitionEnd = min(
                moved.count,
                partitionStart
                    + partitionWidths[partitionIndex % partitionWidths.count]
            )
            try partitioned.renderer.appendStrokeBatch(
                token: partitionedToken,
                samples: Array(moved[partitionStart..<partitionEnd])
            )
            partitionStart = partitionEnd
            partitionIndex += 1
        }
        try incremental.renderer.requestStrokeCommit(
            token: incrementalToken,
            sample: depositionSample(.ended, x: 52, y: 24)
        )
        try partitioned.renderer.requestStrokeCommit(
            token: partitionedToken,
            sample: depositionSample(.ended, x: 52, y: 24)
        )
        _ = try await incremental.renderer.finishCommitForHarness()
        _ = try await partitioned.renderer.finishCommitForHarness()

        let incrementalPixels = try await depositionCommittedBytes(incremental.renderer)
        let partitionedPixels = try await depositionCommittedBytes(
            partitioned.renderer
        )
        #expect(incrementalPixels == partitionedPixels)
    }

    @Test
    @MainActor
    func nativeInkOffMainRoutePublishesAfterPreparationAndCommits()
        async throws
    {
        guard let offMain = try makeDepositionRendererSetup(),
              let reference = try makeDepositionRendererSetup()
        else { return }
        let offMainBrush = try await offMain.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        let referenceBrush = try await reference.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try offMain.renderer.activateDrawBrush(offMainBrush)
        try reference.renderer.activateDrawBrush(referenceBrush)
        let offMainToken = RendererOperationToken(rawValue: 90_004)
        let referenceToken = RendererOperationToken(rawValue: 90_005)
        let began = depositionSample(.began, x: 8, y: 24)
        let moved = (1...12).map { index in
            depositionSample(
                .moved,
                x: 8 + Float(index) * 3,
                y: 24 + Float(index % 3)
            )
        }
        var publishedDabs: [LogicalDab] = []
        offMain.renderer.onLogicalDabsGenerated = {
            publishedDabs.append($0)
        }

        try offMain.renderer.beginStroke(
            token: offMainToken,
            sample: began,
            style: depositionStyle(
                offMainBrush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try offMain.renderer.appendStrokeBatch(
            token: offMainToken,
            samples: moved
        )
        #expect(publishedDabs.isEmpty)
        try offMain.renderer.requestStrokeCommit(
            token: offMainToken,
            sample: depositionSample(.ended, x: 48, y: 24)
        )

        try reference.renderer.beginStroke(
            token: referenceToken,
            sample: began,
            style: depositionStyle(
                referenceBrush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try reference.renderer.appendStrokeBatch(
            token: referenceToken,
            samples: moved
        )
        try reference.renderer.requestStrokeCommit(
            token: referenceToken,
            sample: depositionSample(.ended, x: 48, y: 24)
        )

        _ = try await offMain.renderer.finishCommitForHarness()
        _ = try await reference.renderer.finishCommitForHarness()

        #expect(!publishedDabs.isEmpty)
        #expect(offMain.renderer.isIdle)
        let workerPriority = try #require(
            offMain.renderer
                .offMainPreparationWorkerTaskPriorityForTesting
        )
        #expect(
            workerPriority.rawValue
                >= TaskPriority.userInitiated.rawValue
        )
        #expect(
            offMain.renderer.instancePool.diagnosticSnapshot
                .strokeLeaseHighWater == 0
        )
        #expect(
            // Advance-only Stage C pages may add one bounded zero-instance
            // lease beyond the input/terminal lifecycle frames.
            (1...(moved.count + 4)).contains(
                offMain.renderer.offMainZeroWorkLeaseCountForTesting
            )
        )
        #expect(
            offMain.renderer.offMainSurfaceSnapshotForTesting?
                .surfaceCount == 2
        )
        #expect(
            offMain.renderer.offMainSurfaceSnapshotForTesting?
                .surfaceLeaseHighWater == 1
        )
        let offMainPixels = try await depositionCommittedBytes(offMain.renderer)
        let referencePixels = try await depositionCommittedBytes(reference.renderer)
        #expect(offMainPixels == referencePixels)
    }

    @Test
    func stageCAppendOnlyFixtureRejectsReplayLimits() {
        #expect(throws: BrushDefinitionValidationError.invalidReplay) {
            _ = try stageCMetalTestProgram(
                id: "test.renderer.stage-c-invalid-append-only-limits",
                replayMode: .appendOnly,
                replayLimits: BrushRecipePolicy.replayTailLimits
            )
        }
    }

    @Test
    @MainActor
    func stageCOffCanvasMultiPageZeroWorkCommitsAndReusesProductionRoute()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup(finite: .plain)
        else { return }
        let program = try stageCMetalTestProgram(
            id: "test.renderer.stage-c-zero-work-production",
            replayMode: .appendOnly,
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let brush = try await setup.compileBrush(
            definition: program.definition
        )
        try setup.renderer.activateDrawBrush(brush)
        let canonicalBefore = try await depositionCommittedBytes(setup.renderer)
        let documentDomainLockedBefore =
            setup.renderer.documentDomainLocked
        let radialGeometryLockedBefore =
            setup.renderer.radialGeometryLocked
        let offCanvasToken = RendererOperationToken(rawValue: 91_110)
        var offCanvasDabs: [LogicalDab] = []
        var offCanvasCompletions: [RendererOperationCompletion] = []
        setup.renderer.onLogicalDabsGenerated = {
            offCanvasDabs.append($0)
        }
        setup.renderer.onOperationCompleted = {
            offCanvasCompletions.append($0)
        }

        try setup.renderer.beginStroke(
            token: offCanvasToken,
            sample: timedDepositionSample(
                .began,
                x: -10_000,
                timestamp: 0
            ),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 8
            )
        )
        try setup.renderer.requestStrokeCommit(
            token: offCanvasToken,
            sample: timedDepositionSample(
                .ended,
                x: -10_000,
                timestamp: 1_025.0 / 240
            )
        )
        _ = try await setup.renderer.finishCommitForHarness()
        for _ in 0..<10_000
        where setup.renderer.rendererEventDiagnosticsForTesting
            .pendingEventCount > 0
        {
            await Task.yield()
        }

        let zeroWorkScheduler = await setup.renderer
            .offMainSchedulerSnapshotForTesting()
        #expect(zeroWorkScheduler.authoritativeCandidatePageCount > 2)
        #expect(zeroWorkScheduler.authoritativeCandidateResumeCount > 2)
        #expect(zeroWorkScheduler.authoritativeCandidateProjectionHighWater == 0)
        #expect(
            setup.renderer.offMainZeroWorkLeaseCountForTesting > 1
        )

        #expect(setup.renderer.isIdle)
        #expect(offCanvasCompletions.count == 1)
        if offCanvasCompletions.count == 1,
           case let .operationSuccess(completedToken) =
            offCanvasCompletions[0]
        {
            #expect(completedToken == offCanvasToken)
        } else {
            Issue.record(
                "Clipped no-op commit must publish exactly one operation success"
            )
        }
        #expect(offCanvasDabs.count == 1_026)
        #expect(
            offCanvasDabs.map(\.ordinal) == Array(0...UInt64(1_025))
        )
        #expect(
            try await depositionCommittedBytes(setup.renderer)
                == canonicalBefore
        )
        #expect(
            setup.renderer.documentDomainLocked
                == documentDomainLockedBefore
        )
        #expect(
            setup.renderer.radialGeometryLocked
                == radialGeometryLockedBefore
        )
        #expect(setup.renderer.isIdle)
        #expect(
            setup.renderer.documentDomainLocked
                == documentDomainLockedBefore
        )
        #expect(
            setup.renderer.radialGeometryLocked
                == radialGeometryLockedBefore
        )

        setup.renderer.onLogicalDabsGenerated = nil
        setup.renderer.onOperationCompleted = nil
        let visibleToken = RendererOperationToken(rawValue: 91_111)
        try setup.renderer.beginStroke(
            token: visibleToken,
            sample: timedDepositionSample(
                .began,
                x: 16,
                timestamp: 10
            ),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 8
            )
        )
        try setup.renderer.requestStrokeCommit(
            token: visibleToken,
            sample: timedDepositionSample(
                .ended,
                x: 48,
                timestamp: 10 + 4.0 / 240
            )
        )
        _ = try await prepareOffMainCommit(setup.renderer)
        _ = try await setup.renderer.finishCommitForHarness()

        #expect(setup.renderer.isIdle)
        #expect(
            try await depositionCommittedBytes(setup.renderer)
                != canonicalBefore
        )
    }

    @Test
    @MainActor
    func offMainPredictedAwaitingEstimateMatchesDirectPredictionPixels()
        async throws
    {
        guard let corrected = try makeDepositionRendererSetup(),
              let direct = try makeDepositionRendererSetup()
        else { return }
        let correctedBrush = try await corrected.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        let directBrush = try await direct.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try corrected.renderer.activateDrawBrush(correctedBrush)
        try direct.renderer.activateDrawBrush(directBrush)
        let correctedToken = RendererOperationToken(rawValue: 91_120)
        let directToken = RendererOperationToken(rawValue: 91_121)
        let style = depositionStyle(
            correctedBrush,
            compositeMode: .draw,
            diameter: 12
        )
        let directStyle = depositionStyle(
            directBrush,
            compositeMode: .draw,
            diameter: 12
        )
        let began = depositionSample(.began, x: 8, y: 24)
        let predicted = depositionCorrectionSample(
            phase: .moved,
            kind: .predicted,
            x: 20,
            pressure: 0.5,
            timestamp: 3,
            altitude: 0.7,
            azimuth: 0.8,
            estimationUpdateIndex: 240,
            estimatedProperties: .location,
            expecting: .location
        )
        let update = depositionCorrectionSample(
            phase: .moved,
            kind: .estimatedUpdate,
            x: 44,
            pressure: 0.9,
            timestamp: 4,
            altitude: 1,
            azimuth: 1.2,
            estimationUpdateIndex: 240,
            estimatedProperties: [],
            expecting: []
        )
        let directPrediction = depositionCorrectionSample(
            phase: .moved,
            kind: .predicted,
            x: 44,
            pressure: 0.5,
            timestamp: 3,
            altitude: 0.7,
            azimuth: 0.8,
            estimationUpdateIndex: 240,
            estimatedProperties: [],
            expecting: []
        )

        try corrected.renderer.beginStroke(
            token: correctedToken,
            sample: began,
            style: style
        )
        try corrected.renderer.appendStroke(
            token: correctedToken,
            sample: predicted
        )
        try corrected.renderer.applyEstimatedStrokeUpdate(
            token: correctedToken,
            sample: update
        )
        try direct.renderer.beginStroke(
            token: directToken,
            sample: began,
            style: directStyle
        )
        try direct.renderer.appendStroke(
            token: directToken,
            sample: directPrediction
        )
        let correctedFrame = try await prepareOffMainCommit(
            corrected.renderer
        )
        let directFrame = try await prepareOffMainCommit(
            direct.renderer
        )
        let correctedPixels = depositionTextureBytes(
            correctedFrame.texture
        )
        let directPixels = depositionTextureBytes(
            directFrame.texture
        )
        #expect(correctedPixels == directPixels)
        try corrected.renderer.cancelStroke(token: correctedToken)
        try direct.renderer.cancelStroke(token: directToken)
    }

    @Test
    @MainActor
    func warmedOffMainActorAcceptsBrushModeAndViewportChangesWithoutDebt()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let ink = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        let dryMedia = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.dryMedia
        )
        let eraser = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.eraser
        )
        try setup.renderer.activateDrawBrush(ink)
        try setup.renderer.activateEraserBrush(eraser)
        let cancellationCount = setup.renderer
            .offMainTerminalCancellationPublicationCountForTesting

        let firstToken = RendererOperationToken(rawValue: 90_011)
        try setup.renderer.beginStroke(
            token: firstToken,
            sample: depositionSample(.began, x: 8, y: 24),
            style: depositionStyle(
                ink,
                compositeMode: .draw,
                diameter: 12
            )
        )
        #expect(
            setup.renderer.offMainStrokeWorkspaceInstallationCountForTesting
                == 1
        )
        _ = try await awaitOffMainPreparedLease(setup.renderer)
        try setup.renderer.cancelStroke(token: firstToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(
            setup.renderer.offMainStrokeWorkspaceInstallationCountForTesting
                == 0
        )

        setup.renderer.resize(to: PatternSize(width: 96, height: 80))
        setup.renderer.pan(byScreenDelta: SIMD2<Float>(3, -2))
        setup.renderer.zoom(
            by: 1.1,
            anchor: ScreenPoint(x: 32, y: 24)
        )
        try setup.renderer.activateDrawBrush(dryMedia)

        let secondToken = RendererOperationToken(rawValue: 90_012)
        try setup.renderer.beginStroke(
            token: secondToken,
            sample: depositionSample(.began, x: 12, y: 20),
            style: depositionStyle(
                dryMedia,
                compositeMode: .draw,
                diameter: 10
            )
        )
        #expect(
            setup.renderer.offMainStrokeWorkspaceInstallationCountForTesting
                == 1
        )
        _ = try await awaitOffMainPreparedLease(setup.renderer)
        try setup.renderer.cancelStroke(token: secondToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(
            setup.renderer.offMainStrokeWorkspaceInstallationCountForTesting
                == 0
        )

        let eraseToken = RendererOperationToken(rawValue: 90_013)
        try setup.renderer.beginStroke(
            token: eraseToken,
            sample: depositionSample(.began, x: 16, y: 18),
            style: depositionStyle(
                eraser,
                compositeMode: .erase,
                diameter: 9
            )
        )
        #expect(
            setup.renderer.offMainStrokeWorkspaceInstallationCountForTesting
                == 1
        )
        _ = try await awaitOffMainPreparedLease(setup.renderer)
        try setup.renderer.cancelStroke(token: eraseToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(
            setup.renderer.offMainStrokeWorkspaceInstallationCountForTesting
                == 0
        )
        #expect(
            setup.renderer
                .offMainTerminalCancellationPublicationCountForTesting
                == cancellationCount + 3
        )
    }

    @Test
    @MainActor
    func offMainCommitPublishesRestorableHistoryPair() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        let canonicalBefore = try await depositionCommittedBytes(setup.renderer)
        var receipt: RasterMutationReceipt?
        setup.renderer.onOperationCompleted = { completion in
            if case let .rasterSuccess(value) = completion {
                receipt = value
            }
        }
        let token = RendererOperationToken(rawValue: 90_008)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 8, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 42, y: 31)
        )
        try setup.renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 56, y: 24)
        )
        _ = try await prepareOffMainCommit(setup.renderer)
        _ = try await setup.renderer.finishCommitForHarness()
        let canonicalAfter = try await depositionCommittedBytes(setup.renderer)
        #expect(canonicalAfter != canonicalBefore)
        let history = try #require(receipt)

        try await setup.renderer.restoreDocumentRevision(
            token: RendererOperationToken(rawValue: 90_009),
            revision: history.before
        )
        #expect(
            try await depositionCommittedBytes(setup.renderer)
                == canonicalBefore
        )

        try await setup.renderer.restoreDocumentRevision(
            token: RendererOperationToken(rawValue: 90_010),
            revision: history.after
        )
        #expect(
            try await depositionCommittedBytes(setup.renderer)
                == canonicalAfter
        )
        try await setup.renderer.releasePaintRevisions([
            history.before.id,
            history.after.id,
        ])
    }

    @Test
    @MainActor
    func offMainProductionTraceCoversTenLogicalMinutes() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )

        let trace = try await setup.renderer
            .runOffMainProductionTraceForTesting(compiledBrush: brush)

        print(
            "TASK7_PRODUCTION_TRACE "
                + "samples=\(trace.inputSampleCount) "
                + "logical_ns=\(trace.logicalDurationNanoseconds) "
                + "wall_ns=\(trace.wallDurationNanoseconds) "
                + "first_decile_ns_per_event="
                + "\(trace.firstDecileNanosecondsPerEvent) "
                + "last_decile_ns_per_event="
                + "\(trace.lastDecileNanosecondsPerEvent) "
                + "input_high_water="
                + "\(trace.authoritativeInputHighWater) "
                + "input_capacity="
                + "\(trace.authoritativeInputCapacity) "
                + "input_storage="
                + "\(trace.authoritativeInputInitialStorageCapacity)/"
                + "\(trace.authoritativeInputStorageCapacity) "
                + "result_high_water=\(trace.resultHighWater) "
                + "result_capacity=\(trace.resultCapacity) "
                + "result_storage="
                + "\(trace.resultInitialStorageCapacity)/"
                + "\(trace.resultStorageCapacity) "
                + "workspace_installations="
                + "\(trace.workspaceInitialInstallationCount)/"
                + "\(trace.workspaceInstallationCount) "
                + "payload_bytes="
                + "\(trace.maximumPreparedPayloadBytes) "
                + "surfaces=\(trace.surface.surfaceCount) "
                + "surface_lease_high_water="
                + "\(trace.surface.surfaceLeaseHighWater) "
                + "missed=\(trace.missedLogicalFrameCount) "
                + "deferred=\(trace.deferredDrainCount)"
        )
        #expect(trace.inputSampleCount == 36_000)
        #expect(trace.logicalDurationNanoseconds == 599_999_976_000)
        #expect(trace.authoritativeInputHighWater <= 60)
        #expect(trace.authoritativeInputCapacity == 12_288)
        #expect(
            trace.authoritativeInputStorageCapacity
                == trace.authoritativeInputInitialStorageCapacity
        )
        #expect(trace.predictionInputCapacity == 64)
        #expect(
            trace.predictionInputStorageCapacity
                == trace.predictionInputInitialStorageCapacity
        )
        #expect(trace.resultHighWater == 1)
        #expect(trace.resultCapacity == 1)
        #expect(
            trace.resultStorageCapacity
                == trace.resultInitialStorageCapacity
        )
        #expect(
            trace.workspaceInstallationCount
                == trace.workspaceInitialInstallationCount
        )
        #expect(trace.workspaceIdentityStayedStable)
        #expect(trace.maximumPreparedPayloadBytes > 0)
        #expect(trace.surface.surfaceCount == 2)
        #expect(trace.surface.surfaceLeaseHighWater == 1)
        #expect(
            trace.surface.maximumUploadBytes
                == GridCanvasContract.maximumStrokeTileReferenceCount
                    * MemoryLayout<PatternDepositionStampInstance>.stride
        )
        #expect(trace.surface.encodedFrameCount > 0)
        #expect(trace.surface.encodedInstanceCount > 0)
        // Scheduling may piggyback acknowledgements or publish an empty token.
        // Bounded-replay finishing can publish at most one continuation for
        // each retained dab in addition to the submitted batches and commit.
        let maximumZeroWorkLeaseCount =
            (36_000 + 60 - 1) / 60
            + BrushRecipePolicy.replayTailLimits.maximumDabs
            + 1
        #expect(trace.zeroWorkLeaseCount <= maximumZeroWorkLeaseCount)
        #expect(trace.missedLogicalFrameCount == 0)
        #expect(trace.allPreparationAndEncodingOffMain)
        #expect(
            trace.lastDecileNanosecondsPerEvent
                <= max(
                    trace.firstDecileNanosecondsPerEvent * 2,
                    trace.firstDecileNanosecondsPerEvent + 100_000
                )
        )
    }

    @Test
    @MainActor
    func nativeInkAppendObserverCanSynchronouslyCancelAndRecover()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 90_012)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 8, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )

        var callbackCount = 0
        var cancellationError: String?
        setup.renderer.onLogicalDabsGenerated = { _ in
            callbackCount += 1
            guard callbackCount == 1 else { return }
            do {
                try setup.renderer.cancelStroke(token: token)
            } catch {
                cancellationError = String(describing: error)
            }
        }

        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 40, y: 24)
        )
        try await driveOffMainStroke(setup.renderer) {
            callbackCount == 1 && setup.renderer.isIdle
        }

        #expect(callbackCount == 1)
        #expect(cancellationError == nil)
        #expect(setup.renderer.isIdle)
        setup.renderer.onLogicalDabsGenerated = nil

        let recoveryToken = RendererOperationToken(rawValue: 90_013)
        try setup.renderer.beginStroke(
            token: recoveryToken,
            sample: depositionSample(.began, x: 12, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try setup.renderer.cancelStroke(token: recoveryToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(setup.renderer.isIdle)
    }

    @Test
    @MainActor
    func nativeInkFinishObserverCanSynchronouslyCancelAndRecover()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 90_014)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 8, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 20, y: 24)
        )

        var callbackCount = 0
        var cancellationError: String?
        setup.renderer.onLogicalDabsGenerated = { _ in
            callbackCount += 1
            guard callbackCount == 1 else { return }
            do {
                try setup.renderer.cancelStroke(token: token)
            } catch {
                cancellationError = String(describing: error)
            }
        }

        try setup.renderer.finishStrokeTransient(
            token: token,
            sample: depositionSample(.ended, x: 52, y: 24)
        )
        try await driveOffMainStroke(setup.renderer) {
            callbackCount == 1 && setup.renderer.isIdle
        }

        #expect(callbackCount == 1)
        #expect(cancellationError == nil)
        #expect(setup.renderer.isIdle)
        setup.renderer.onLogicalDabsGenerated = nil

        let recoveryToken = RendererOperationToken(rawValue: 90_015)
        try setup.renderer.beginStroke(
            token: recoveryToken,
            sample: depositionSample(.began, x: 12, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try setup.renderer.cancelStroke(token: recoveryToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(setup.renderer.isIdle)
    }

    @Test
    @MainActor
    func logicalDabObserverReentrantChainIsIterativeAndBounded()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 90_020)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 8, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )

        let chainLength = 256
        var remaining = chainLength
        var callbackDepth = 0
        var maximumCallbackDepth = 0
        var appendError: String?
        setup.renderer.onLogicalDabsGenerated = { _ in
            callbackDepth += 1
            maximumCallbackDepth = max(maximumCallbackDepth, callbackDepth)
            defer { callbackDepth -= 1 }
            guard remaining > 0, appendError == nil else { return }
            remaining -= 1
            let index = chainLength - remaining
            do {
                try setup.renderer.appendStroke(
                    token: token,
                    sample: .mouse(
                        position: ScreenPoint(
                            x: index.isMultiple(of: 2) ? 24 : 28,
                            y: 24
                        ),
                        timestamp: TimeInterval(index) / 240,
                        phase: .moved
                    )
                )
            } catch {
                appendError = String(describing: error)
            }
        }

        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 20, y: 24)
        )
        try await driveOffMainStroke(setup.renderer) {
            remaining == 0 || appendError != nil
        }

        #expect(remaining == 0)
        #expect(appendError == nil)
        #expect(maximumCallbackDepth == 1)
        setup.renderer.onLogicalDabsGenerated = nil
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func logicalDabObserverNestedAppendPreservesFIFOOrder()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 90_021)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 8, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )

        var distances: [Float] = []
        var startedNestedAppend = false
        var nestedError: String?
        setup.renderer.onLogicalDabsGenerated = { dab in
            distances.append(dab.sourceDistance)
            guard !startedNestedAppend else { return }
            startedNestedAppend = true
            do {
                try setup.renderer.appendStroke(
                    token: token,
                    sample: depositionSample(.moved, x: 56, y: 24)
                )
            } catch {
                nestedError = String(describing: error)
            }
        }

        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 40, y: 24)
        )
        try await driveOffMainStroke(setup.renderer) {
            startedNestedAppend
                && setup.renderer
                    .strokePreparationIsQuiescentForAllocationHarness
                && setup.renderer.rendererEventDiagnosticsForTesting
                    .pendingEventCount == 0
        }

        #expect(startedNestedAppend)
        #expect(nestedError == nil)
        #expect(distances.count > 2)
        #expect(
            zip(distances, distances.dropFirst()).allSatisfy { pair in
                pair.0 <= pair.1
            }
        )
        setup.renderer.onLogicalDabsGenerated = nil
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func cancelInvalidatesQueuedOldStrokeEventsButKeepsReplacementEvents()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        let oldToken = RendererOperationToken(rawValue: 90_022)
        let newToken = RendererOperationToken(rawValue: 90_023)
        let replacementColor = InkColor(
            red: 1,
            green: 0,
            blue: 0,
            alpha: 1
        )!
        try setup.renderer.beginStroke(
            token: oldToken,
            sample: depositionSample(.began, x: 8, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )

        var observedColors: [InkColor] = []
        var cancelledOldStroke = false
        var replacementError: String?
        setup.renderer.onLogicalDabsGenerated = { dab in
            observedColors.append(dab.color)
            guard !cancelledOldStroke else { return }
            cancelledOldStroke = true
            do {
                try setup.renderer.cancelStroke(token: oldToken)
            } catch {
                replacementError = String(describing: error)
            }
        }

        try setup.renderer.appendStroke(
            token: oldToken,
            sample: depositionSample(.moved, x: 40, y: 24)
        )
        try await driveOffMainStroke(setup.renderer) {
            cancelledOldStroke
                && replacementError == nil
                && setup.renderer.isIdle
        }

        try setup.renderer.beginStroke(
            token: newToken,
            sample: depositionSample(.began, x: 12, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12,
                color: replacementColor
            )
        )
        try setup.renderer.appendStroke(
            token: newToken,
            sample: depositionSample(.moved, x: 44, y: 24)
        )
        try await driveOffMainStroke(setup.renderer) {
            observedColors.dropFirst().contains(replacementColor)
        }

        #expect(cancelledOldStroke)
        #expect(replacementError == nil)
        #expect(observedColors.first == .black)
        #expect(!observedColors.dropFirst().isEmpty)
        #expect(
            observedColors.dropFirst().allSatisfy {
                $0 == replacementColor
            }
        )
        setup.renderer.onLogicalDabsGenerated = nil
        try setup.renderer.cancelStroke(token: newToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(setup.renderer.isIdle)
    }
}

private func requireSendableRenderState<T: Sendable>(_: T) {}

@MainActor
struct DepositionRendererSetup {
    let renderer: GridRenderer
    let compiler: BrushCompiler
    let device: any MTLDevice
    let library: any MTLLibrary

    func compileBrush(id: String) async throws -> CompiledBrush {
        try await compileBrush(
            definition: stageCMetalTestProgram(id: id).definition
        )
    }

    func compileBrush(definition: BrushDefinition) async throws -> CompiledBrush {
        try await compiler.compileAndActivate(
            package: BrushPackage(
                manifest: BrushPackageManifest(resources: []),
                definition: definition,
                resourceData: [:]
            )
        )
    }
}

private func nativeTerminationDefinition(
    id: String,
    termination: BrushTerminationDefinition
) throws -> BrushDefinition {
    let base = try stageCMetalTestProgram(id: id).definition
    return try depositionDefinitionCopy(base, termination: termination)
}

private func depositionDefinitionCopy(
    _ base: BrushDefinition,
    material: BrushMaterialDefinition? = nil,
    termination: BrushTerminationDefinition? = nil
) throws -> BrushDefinition {
    try BrushDefinition(
        id: base.id,
        metadata: base.metadata,
        capabilities: base.capabilities,
        resources: base.components[0].resources,
        coverage: base.components[0].coverage,
        placement: base.components[0].placement,
        dynamics: base.components[0].dynamics,
        color: base.components[0].color,
        material: material ?? base.components[0].material,
        stabilization: base.stabilization,
        taper: base.components[0].taper,
        replayMode: base.replayMode,
        replayLimits: base.replayLimits,
        termination: termination ?? base.termination,
        seedPolicy: base.seedPolicy,
        limits: base.limits,
        performanceIntent: base.performanceIntent,
        compatibility: base.compatibility,
        sensorNormalization: base.sensorNormalization,
        sensorProgram: base.components[0].sensorProgram,
        stabilizationV2: base.stabilizationV2,
        direction: base.direction,
        emission: base.components[0].emission,
        tipSupports: base.components[0].tipSupports
    )
}

private func analyticShapeDefinition(
    id: String,
    shape: BrushShapeDescriptor,
    tipSupport: BrushTipSupportDefinition
) throws -> BrushDefinition {
    let base = try stageCMetalTestProgram(id: id).definition
    return try BrushDefinition(
        id: base.id,
        metadata: base.metadata,
        capabilities: base.capabilities,
        resources: base.components[0].resources,
        coverage: BrushCoverageDefinition(
            shapes: [BrushShapeLayerDefinition(
                shape: shape,
                combination: .replace,
                scale: 1,
                rotation: 0,
                offset: .zero
            )],
            grains: [],
            baseHardness: 1,
            aspectRatio: 1,
            tipThreshold: 0,
            antialiasing: true
        ),
        placement: base.components[0].placement,
        dynamics: base.components[0].dynamics,
        color: base.components[0].color,
        material: base.components[0].material,
        stabilization: base.stabilization,
        taper: base.components[0].taper,
        replayMode: base.replayMode,
        replayLimits: base.replayLimits,
        termination: base.termination,
        seedPolicy: base.seedPolicy,
        limits: base.limits,
        performanceIntent: base.performanceIntent,
        compatibility: base.compatibility,
        sensorNormalization: base.sensorNormalization,
        sensorProgram: base.components[0].sensorProgram,
        stabilizationV2: base.stabilizationV2,
        direction: base.direction,
        emission: base.components[0].emission,
        tipSupports: [tipSupport]
    )
}

private func depositionFrameBudget(
    maximumAuthoritativeInstances: Int,
    maximumPredictedInstances: Int = 4_096,
    maximumPendingAuthoritativeInstances: Int = 12_288,
    maximumPendingPredictedInstances: Int = 4_096
) throws -> DepositionFrameBudget {
    try DepositionFrameBudget(
        cpuPreparationNanoseconds: 1_500_000,
        maximumAuthoritativeInstances: maximumAuthoritativeInstances,
        maximumPredictedInstances: maximumPredictedInstances,
        maximumPendingAuthoritativeInstances:
            maximumPendingAuthoritativeInstances,
        maximumPendingPredictedInstances: maximumPendingPredictedInstances,
        inFlightUploadBufferCount: 3
    )
}

@MainActor
func prepareOffMainCommit(
    _ renderer: GridRenderer,
    outputPixelSize: PixelSize? = nil
) async throws -> RenderedFrame {
    let frames = try await renderer.drainPreparedStrokeInputForHarness(
        outputPixelSize: outputPixelSize ?? renderer.pixelSize
    )
    guard let frame = frames.last?.frame
    else {
        throw MetalRendererError.invalidStrokeLifecycle
    }
    return frame
}

@MainActor
func drainOffMainPreparedFrames(
    _ renderer: GridRenderer,
    minimumFrameCount: Int
) async throws -> RenderedFrame {
    var completedFrameCount = 0
    var lastFrame: RenderedFrame?
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if let frame = try await renderer.renderCurrentPaintFrameForHarness(
                width: renderer.pixelSize.width,
                height: renderer.pixelSize.height,
                includeTransient: true
            ), frame.metrics.encodedInstanceCount > 0
        {
            lastFrame = frame
            completedFrameCount += 1
        }
        if completedFrameCount >= minimumFrameCount, let lastFrame {
            return lastFrame
        }
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "off-main test preparation exceeded its bound"
    )
}

@MainActor
private func awaitOffMainSchedulerMutation(
    _ renderer: GridRenderer,
    after priorVersion: UInt64
) async throws -> StrokeFrameSchedulerSnapshot {
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        _ = try await renderer.renderCurrentPaintFrameForHarness(
            width: renderer.pixelSize.width,
            height: renderer.pixelSize.height,
            includeTransient: true
        )
        let snapshot = await renderer.offMainSchedulerSnapshotForTesting()
        if snapshot.transientMutationVersion > priorVersion {
            return snapshot
        }
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "off-main mutation exceeded its test bound"
    )
}

@MainActor
private func awaitOffMainPreparationQuiescence(
    _ renderer: GridRenderer
) async throws {
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        _ = try await renderer.renderCurrentPaintFrameForHarness(
            width: renderer.pixelSize.width,
            height: renderer.pixelSize.height,
            includeTransient: true
        )
        if renderer.offMainPreparationMailboxSnapshotForTesting?
            .isQuiescent == true
        {
            return
        }
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "off-main preparation did not become quiescent"
    )
}

@MainActor
private func awaitOffMainPreparedLease(
    _ renderer: GridRenderer
) async throws {
    _ = try await renderer.renderCurrentPaintFrameForHarness(
        width: renderer.pixelSize.width,
        height: renderer.pixelSize.height,
        includeTransient: true
    )
}

@MainActor
func awaitOffMainWorkspaceAvailable(
    _ renderer: GridRenderer
) async throws {
    try await renderer.awaitPendingStrokeWorkspaceRetirement()
}

@MainActor
private func awaitInstalledPaintTransientSource(
    _ renderer: GridRenderer
) async throws {
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if renderer.compositeLiveIsVisible { return }
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "paint transient source installation exceeded its test bound"
    )
}

@MainActor
private func driveOffMainStroke(
    _ renderer: GridRenderer,
    until condition: () -> Bool
) async throws {
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if condition() { return }
        _ = try await renderer.renderCurrentPaintFrameForHarness(
            width: renderer.pixelSize.width,
            height: renderer.pixelSize.height,
            includeTransient: true
        )
        if condition() { return }
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "off-main event delivery exceeded its bound"
    )
}

private func depositionPixelDigest(_ bytes: [UInt8]) -> String {
    var digest: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes {
        digest ^= UInt64(byte)
        digest &*= 1_099_511_628_211
    }
    return String(format: "%016llx", digest)
}

@MainActor
func makeDepositionRendererSetup(
    tiling: TilingKind = .grid,
    finite: FiniteSymmetryConfiguration? = nil,
    pixelSize: PixelSize = PixelSize(width: 64, height: 64)
)
    throws -> DepositionRendererSetup?
{
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue()
    else {
        return nil
    }
    let library = try depositionRendererLibrary(device: device)
    let configuration: TilingCanvasConfiguration = if let finite {
        try TilingCanvasConfiguration(
            pixelSize: pixelSize,
            finiteConfiguration: finite
        )
    } else {
        try TilingCanvasConfiguration(
            pixelSize: pixelSize,
            tiling: tiling
        )
    }
    let renderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(
            width: Float(pixelSize.width),
            height: Float(pixelSize.height)
        ),
        configuration: configuration
    )
    let profile = try BrushDeviceProfile(
        registryID: device.registryID,
        recommendedWorkingSetBytes: 1_024 * 1_024 * 1_024,
        maximumWorkingTextureDimension: 4_096,
        brushCacheBudgetBytes: 64 * 1_024 * 1_024,
        targetFramesPerSecond: 120
    )
    let compiler = BrushCompiler(
        device: device,
        commandQueue: queue,
        profile: profile,
        pipelinePreparing: DepositionPipelineLibrary(
            device: device,
            library: library
        ),
        testHooks: .none
    )
    return DepositionRendererSetup(
        renderer: renderer,
        compiler: compiler,
        device: device,
        library: library
    )
}

private func depositionRendererLibrary(
    device: any MTLDevice
) throws -> any MTLLibrary {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let shader = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/MetalRenderer/Shaders.metal"
        ),
        encoding: .utf8
    )
    let header = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/CShaderTypes/include/ShaderTypes.h"
        ),
        encoding: .utf8
    )
    return try device.makeLibrary(
        source: shader.replacingOccurrences(
            of: "#include \"ShaderTypes.h\"",
            with: header
        ),
        options: nil
    )
}

func depositionSample(
    _ phase: StrokePhase,
    x: Float = 32,
    y: Float = 32
) -> StrokeSample {
    .mouse(
        position: ScreenPoint(x: x, y: y),
        timestamp: 0,
        phase: phase
    )
}

private func timedDepositionSample(
    _ phase: StrokePhase,
    x: Float,
    timestamp: TimeInterval
) -> StrokeSample {
    .mouse(
        position: ScreenPoint(x: x, y: 32),
        timestamp: timestamp,
        phase: phase
    )
}

func depositionPredictedSample(x: Float) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: 0.5,
        timestamp: TimeInterval(x),
        phase: .moved,
        source: .mouse,
        kind: .predicted
    )
}

private func depositionEstimatedSample(
    _ phase: StrokePhase,
    x: Float,
    index: Int,
    expecting: StrokeEstimatedProperties
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: 0.4,
        timestamp: TimeInterval(x),
        phase: phase,
        source: .pencil,
        capabilities: [.pressure],
        estimationUpdateIndex: index,
        estimatedProperties: expecting,
        estimatedPropertiesExpectingUpdates: expecting
    )
}

private func depositionEstimatedUpdateSample(
    x: Float,
    index: Int
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: 0.8,
        timestamp: TimeInterval(x),
        phase: .moved,
        source: .pencil,
        kind: .estimatedUpdate,
        capabilities: [.pressure],
        estimationUpdateIndex: index,
        estimatedProperties: [.pressure],
        estimatedPropertiesExpectingUpdates: []
    )
}

func depositionCorrectionSample(
    phase: StrokePhase,
    kind: StrokeSampleKind,
    x: Float,
    pressure: Float,
    timestamp: TimeInterval,
    altitude: Float,
    azimuth: Float,
    estimationUpdateIndex: Int,
    estimatedProperties: StrokeEstimatedProperties,
    expecting: StrokeEstimatedProperties
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 24),
        pressure: pressure,
        timestamp: timestamp,
        phase: phase,
        source: .pencil,
        kind: kind,
        capabilities: [.pressure, .altitude, .azimuth],
        altitude: altitude,
        azimuth: azimuth,
        estimationUpdateIndex: estimationUpdateIndex,
        estimatedProperties: estimatedProperties,
        estimatedPropertiesExpectingUpdates: expecting
    )
}

func depositionTextureBytes(
    _ texture: any MTLTexture
) -> [UInt8] {
    let bytesPerRow = texture.width * 4
    var bytes = [UInt8](
        repeating: 0,
        count: bytesPerRow * texture.height
    )
    texture.getBytes(
        &bytes,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    return bytes
}

@MainActor
private func depositionCommittedBytes(
    _ renderer: GridRenderer
) async throws -> [UInt8] {
    let snapshot = try await renderer.captureCommittedDocument()
    switch snapshot.storage {
    case let .singleRaster(bytes):
        return bytes
    case let .radialPages(pages):
        return pages.flatMap(\.bgra8PremultipliedBytes)
    }
}

private func depositionNonuniformCanonicalBytes() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
    for y in 0..<64 {
        for x in 0..<64 {
            let offset = (y * 64 + x) * 4
            let checker = ((x + y) & 1) == 0
            bytes[offset] =
                checker ? UInt8((x * 37 + y * 11) & 0xff) : 8
            bytes[offset + 1] =
                checker ? 12 : UInt8((x * 17 + y * 43) & 0xff)
            bytes[offset + 2] =
                checker ? 238 : UInt8((x * 29 + y * 7) & 0xff)
            bytes[offset + 3] = 255
        }
    }
    return bytes
}

@MainActor
private func depositionCenterBGRA(
    _ renderer: GridRenderer
) async throws -> [UInt8] {
    let bytes = try await depositionCommittedBytes(renderer)
    let offset = (32 * renderer.pixelSize.width + 32) * 4
    return Array(bytes[offset..<(offset + 4)])
}

private func alpha(
    _ bytes: [UInt8],
    x: Int,
    y: Int,
    width: Int
) -> UInt8 {
    bytes[(y * width + x) * 4 + 3]
}

private func maximumChannelDelta(
    _ lhs: [UInt8],
    _ rhs: [UInt8]
) -> UInt8 {
    guard lhs.count == rhs.count else { return .max }
    return zip(lhs, rhs).reduce(0) { current, pair in
        max(
            current,
            UInt8(abs(Int(pair.0) - Int(pair.1)))
        )
    }
}

@MainActor
private func commitNativeStroke(
    renderer: GridRenderer,
    brush: CompiledBrush,
    token: RendererOperationToken
) async throws {
    try renderer.beginStroke(
        token: token,
        sample: depositionSample(.began),
        style: depositionStyle(brush, compositeMode: .draw)
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: depositionSample(.ended, x: 40)
    )
    _ = try await renderer.finishCommitForHarness()
}

@MainActor
private func committedTap(
    renderer: GridRenderer,
    brush: CompiledBrush,
    token: RendererOperationToken
) async throws -> [UInt8] {
    try renderer.activateDrawBrush(brush)
    try renderer.beginStroke(
        token: token,
        sample: depositionSample(.began),
        style: depositionStyle(
            brush,
            compositeMode: .draw,
            diameter: 20
        )
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: depositionSample(.ended)
    )
    _ = try await renderer.finishCommitForHarness()
    return try await depositionCommittedBytes(renderer)
}

@MainActor
func depositionStyle(
    _ brush: CompiledBrush,
    compositeMode: StrokeCompositeMode,
    diameter: Float = 20,
    eraserStrength: Float = 1,
    color: InkColor = .black
) -> StrokeRenderStyle {
    StrokeRenderStyle(
        color: color,
        diameter: diameter,
        compositeMode: compositeMode,
        eraserStrength: eraserStrength,
        program: brush.program,
        renderIdentity: brush.renderIdentity,
        seed: 1
    )
}
