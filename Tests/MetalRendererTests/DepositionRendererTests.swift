import BrushFormat
import CShaderTypes
import EditorCore
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Compiled deposition renderer")
struct DepositionRendererTests {
    // Retired Main scheduler duplicate; covered by
    // actorAppliesLocationPressureAzimuthAndAltitudeCorrections.
    @Test
    @MainActor
    func boundedCorrectionRejectsEveryPointerUpLimitBeforeMutation()
        async throws
    {
        try await StrokeFrameSchedulerTests()
            .actorAppliesLocationPressureAzimuthAndAltitudeCorrections()
    }

    @Test
    func interactiveInputRouteContainsNoOwningSingleSampleOrDabTemporaries()
        throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let renderer = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MetalRenderer/GridRenderer.swift"
            ),
            encoding: .utf8
        )
        let rendererHarness = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MetalRenderer/GridRenderer+Harness.swift"
            ),
            encoding: .utf8
        )
        let dynamics = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/PatternEngine/BrushDynamicsEngine.swift"
            ),
            encoding: .utf8
        )
        let transientBuffer = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/PatternEngine/TransientStrokeBuffer.swift"
            ),
            encoding: .utf8
        )

        #expect(!renderer.contains("let suffix = [sample]"))
        #expect(renderer.contains(".replacePredictionSample("))
        #expect(!renderer.contains("CollectionOfOne(sample)"))
        #expect(renderer.contains("frozenHarnessScheduler: nil"))
        #expect(
            renderer.components(
                separatedBy: "frozenHarnessScheduler: FrameScheduler("
            ).count == 2
        )
        #expect(
            renderer.contains(
                "func beginFrozenProjectionHarnessExecution(radius: Float)"
            )
        )
        #expect(!renderer.contains("func beginHarnessExecution("))
        #expect(
            rendererHarness.components(
                separatedBy: "beginFrozenProjectionHarnessExecution("
            ).count == 4
        )
        #expect(
            renderer.contains(
                "onLogicalDabsGenerated: ((LogicalDab) -> Void)?"
            )
        )
        #expect(!dynamics.contains("definition.coverage.shapes.map"))
        #expect(!dynamics.contains("shapeFrames.flatMap"))
        #expect(!dynamics.contains("unitCorners.map"))
        #expect(!dynamics.contains("corners.map"))
        #expect(!renderer.contains("Array(dabs)"))
        #expect(!renderer.contains("var snapshot: [LogicalDab]"))
        #expect(
            transientBuffer.contains(
                "public struct ReservationTransaction"
            )
        )
        #expect(
            !transientBuffer.contains(
                "final class ReservationTransaction"
            )
        )
    }

    @Test
    func productionCompletionLivesOutsideHarnessAndCallsNoHarnessAPI()
        throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let production = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MetalRenderer/GridRenderer.swift"
            ),
            encoding: .utf8
        )
        let harness = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MetalRenderer/GridRenderer+Harness.swift"
            ),
            encoding: .utf8
        )
        let declaration =
            "public func completePendingInteractiveStroke() throws"
        #expect(production.contains(declaration))
        #expect(!harness.contains(declaration))

        for signature in [
            declaration,
            "func completePendingInteractiveStroke(\n        forceCommitFailure:",
            "func completeNextPendingInteractiveFrame(",
            "func submitPendingInteractiveCommit(",
            "func drainCompletedInteractiveOperations() throws",
            "public func completePendingRasterOperation() throws",
        ] {
            let method = try productionMethod(
                signature,
                in: production
            )
            #expect(
                !method.contains("ForHarness"),
                "\(signature) calls a harness API"
            )
        }
        #expect(
            harness.contains("completePendingInteractiveStroke(\n")
                && harness.contains(
                    "forceCommitFailure: forceCommitFailure"
                )
        )
        #expect(harness.contains("try submitPendingInteractiveCommit("))
        #expect(harness.contains("try drainCompletedInteractiveOperations()"))
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
            sample: depositionSample(.ended, x: 48, y: 48),
            maximumRetainedBytes: 1_000_000
        )
        let completion = try setup.renderer.finishCommitForHarness()
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
        _ = try setup.renderer.flushPendingLiveForHarness()

        let telemetry =
            setup.renderer.brushLabDiagnosticSnapshot.deposition
        #expect(telemetry.eventToSubmit.p50 >= 16_666_667)
        #expect(telemetry.missedFrameCount > 0)
        try setup.renderer.cancelStroke(token: token)
    }

    // Retired Main instance-pool duplicate; covered by
    // offMainSurfaceLeaseWaitsForCompositeCompletionBeforeNextInput.
    @Test
    @MainActor
    func laterSmallStrokeResetsPoolHighWaterButLifetimeStaysMonotonic()
        async throws
    {
        try await offMainSurfaceLeaseWaitsForCompositeCompletionBeforeNextInput()
    }

    @Test
    @MainActor
    func pointerDownWithoutPreparedBrushFailsBeforeMutation() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.uninstalled")
        let before = setup.renderer.harnessTilingMutationSnapshot

        #expect(throws: MetalRendererError.compiledBrushUnavailable(.draw)) {
            try setup.renderer.beginStroke(
                token: RendererOperationToken(rawValue: 1),
                sample: depositionSample(.began),
                style: depositionStyle(brush, compositeMode: .draw)
            )
        }

        #expect(setup.renderer.harnessTilingMutationSnapshot == before)
        #expect(setup.renderer.isIdle)
    }

    @Test
    @MainActor
    func renderIdentityMismatchFailsBeforeMutation() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.identity")
        try setup.renderer.activateDrawBrush(brush)
        let before = setup.renderer.harnessTilingMutationSnapshot
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

        #expect(setup.renderer.harnessTilingMutationSnapshot == before)
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
        let beforeMismatch = setup.renderer.harnessTilingMutationSnapshot
        #expect(throws: MetalRendererError.compiledBrushIdentityMismatch) {
            try setup.renderer.beginStroke(
                token: RendererOperationToken(rawValue: 92),
                sample: depositionSample(.began),
                style: mismatchedNativeStyle
            )
        }
        #expect(setup.renderer.harnessTilingMutationSnapshot == beforeMismatch)
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
    func unsupportedWetBrushCannotReplacePreparedDrawBrush() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let supported = try await setup.compileBrush(id: "brush.supported")
        try setup.renderer.activateDrawBrush(supported)
        let wet = try forgedWetBrush(from: supported)

        #expect(throws: MetalRendererError.unsupportedCompiledBrush) {
            try setup.renderer.activateDrawBrush(wet)
        }
        #expect(
            setup.renderer.harnessPreparedDrawBrushIdentity
                == supported.renderIdentity
        )
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
        let alternate = try await setup.compileBrush(
            recipe: BrushRecipe(
                id: BrushRecipeID("brush.alternate-material"),
                material: BrushMaterial(
                    family: .glaze,
                    strength: 0.5,
                    wetness: 0,
                    bleedRadius: 0,
                    softenPasses: 0,
                    accumulationLimit: 0.5
                )
            )
        )
        try setup.renderer.activateDrawBrush(supported)
        let forged = CompiledBrush(
            program: supported.program,
            renderIdentity: supported.renderIdentity,
            pipelineKey: supported.pipelineKey,
            uniformTemplate: supported.uniformTemplate,
            textures: supported.textures,
            depositionPipeline: supported.depositionPipeline,
            depositionMaterial: alternate.depositionMaterial,
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
        try setup.renderer.applyTiling(.squareRotation)
        let token = RendererOperationToken(rawValue: 7)

        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 8, y: 8),
            style: depositionStyle(brush, compositeMode: .draw)
        )

        try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 1
        )
        let surface = try #require(
            setup.renderer.offMainSurfaceSnapshotForTesting
        )
        #expect(surface.encodedInstanceCount > 0)
        #expect(setup.renderer.liveStroke.pending.isEmpty)
        #expect(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting?
                .authoritativeSubmittedDabCount ?? 0 > 0
        )
        #expect(
            setup.renderer.harnessCompiledIsometryOrdinals.count > 1
        )
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
        try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 1
        )
        let authoritative = try #require(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
        ).authoritativeSubmittedDabCount

        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 36)
        )
        try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 1
        )
        let firstPredictionEpoch = setup.renderer.replayStroke.renderEpoch
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 52)
        )
        try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 1
        )
        let replacementEpoch = setup.renderer.replayStroke.renderEpoch

        #expect(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting?
                .authoritativeSubmittedDabCount
                == authoritative
        )
        #expect(firstPredictionEpoch > 0)
        #expect(replacementEpoch > firstPredictionEpoch)
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

    // Retired Main estimated-settlement duplicate; covered by
    // estimatedUpdateAtFullAuthoritativeCapacityCancelsWithTypedError.
    @Test
    @MainActor
    func estimatedSettlementPreflightFailureIsAtomicAndRetrySucceeds()
        async throws
    {
        try StrokeFrameSchedulerTests()
            .estimatedUpdateAtFullAuthoritativeCapacityCancelsWithTypedError()
    }

    // Retired Main prediction-replay duplicate; covered by
    // predictionReplacementIsBoundedAndNeverRemovesAuthoritativeInput.
    @Test
    @MainActor
    func predictionReplayPreflightFailureIsAtomicAndRetrySucceeds()
        async throws
    {
        try StrokeFrameSchedulerTests()
            .predictionReplacementIsBoundedAndNeverRemovesAuthoritativeInput()
    }

    // Retired Main estimated-replay duplicate; covered by
    // predictedAwaitingEstimateIsCorrectedWithoutChangingProvenance.
    @Test
    @MainActor
    func estimatedReplayPreflightFailureIsAtomicAndRetrySucceeds()
        async throws
    {
        try await StrokeFrameSchedulerTests()
            .predictedAwaitingEstimateIsCorrectedWithoutChangingProvenance()
    }

    // Retired Main authoritative-replay duplicate; covered by
    // abandonedPreparedAppendLeavesExactStateAndRetryIsIdentical.
    @Test
    @MainActor
    func authoritativeReplayPreflightFailureIsAtomicAndRetrySucceeds()
        async throws
    {
        try StrokeRenderCoordinatorTests()
            .abandonedPreparedAppendLeavesExactStateAndRetryIsIdentical()
    }

    // Retired Main finish-replay duplicate; covered by
    // commitBarrierWaitsForEveryAuthoritativeFrameToSubmit.
    @Test
    @MainActor
    func finishReplayPreflightFailureIsAtomicAndRetrySucceeds()
        async throws
    {
        try await StrokeFrameSchedulerTests()
            .commitBarrierWaitsForEveryAuthoritativeFrameToSubmit()
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

        try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 1
        )
        let frame = try setup.renderer.renderOffscreenDisplayForHarness(
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
        try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 1
        )
        let live = depositionTextureBytes(
            try setup.renderer.renderOffscreenDisplayForHarness(
                width: 64,
                height: 64,
                showGridLines: false
            ).texture
        )
        try setup.renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended),
            maximumRetainedBytes: 1_000_000
        )
        try await prepareOffMainCommit(setup.renderer)
        _ = try setup.renderer.finishCommitForHarness()
        let committed = depositionTextureBytes(
            try setup.renderer.renderOffscreenDisplayForHarness(
                width: 64,
                height: 64,
                showGridLines: false
            ).texture
        )
        let canonical = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        let center = (32 * 64 + 32) * 4

        #expect((126...129).contains(Int(canonical[center + 3])))
        #expect((126...129).contains(Int(canonical[center + 2])))
        #expect(canonical[center] == 0)
        #expect(canonical[center + 1] == 0)
        #expect(maximumChannelDelta(live, committed) <= 1)
    }

    @Test
    @MainActor
    func nativePointerUpReturnsBeforeDrainAndPublishesOneCommit()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.async-finish")
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 10)
        var completions: [RendererOperationCompletion] = []
        setup.renderer.onOperationCompleted = { completions.append($0) }
        let initialRevision = setup.renderer.harnessRevision

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
            sample: depositionSample(.ended, x: 52),
            maximumRetainedBytes: 1_000_000
        )

        // The request is enqueued immediately; commit readiness becomes true
        // only after the actor publishes its ordered commit barrier.
        #expect(setup.renderer.activeStroke?.commitRequested == false)
        #expect(setup.renderer.activeStroke?.pendingRevisions == nil)
        #expect(setup.renderer.harnessRevision == initialRevision)
        #expect(completions.isEmpty)
        #expect(!setup.renderer.isIdle)

        _ = try setup.renderer.finishCommitForHarness()

        #expect(setup.renderer.isIdle)
        #expect(setup.renderer.harnessRevision == initialRevision.advanced())
        #expect(completions.count == 1)
        guard case let .rasterSuccess(receipt) = completions.first else {
            Issue.record("Expected one compiled deposition commit")
            return
        }
        #expect(receipt.token == token)

        try setup.renderer.drainCompletedOperationsForHarness()
        #expect(completions.count == 1)
        #expect(setup.renderer.harnessRevision == initialRevision.advanced())

        for rawToken in 20...21 {
            let rapidToken = RendererOperationToken(
                rawValue: UInt64(rawToken)
            )
            try setup.renderer.beginStroke(
                token: rapidToken,
                sample: depositionSample(.began, x: Float(rawToken)),
                style: depositionStyle(brush, compositeMode: .draw)
            )
            try setup.renderer.requestStrokeCommit(
                token: rapidToken,
                sample: depositionSample(
                    .ended,
                    x: Float(rawToken + 12)
                ),
                maximumRetainedBytes: 1_000_000
            )

            let completion = try await setup.renderer
                .completePendingInteractiveStrokeAndAwaitIdle()
            #expect(completion.encodedDabCount > 0)
            #expect(setup.renderer.isIdle)
        }
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
        let snapshotBefore = setup.renderer.harnessTilingMutationSnapshot

        #expect(throws: MetalRendererError.invalidRendererOperationToken) {
            try setup.renderer.appendStroke(
                token: foreign,
                sample: depositionSample(.moved, x: 32)
            )
        }
        #expect(throws: MetalRendererError.invalidRendererOperationToken) {
            try setup.renderer.requestStrokeCommit(
                token: foreign,
                sample: depositionSample(.ended, x: 48),
                maximumRetainedBytes: 1_000_000
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
            setup.renderer.harnessTilingMutationSnapshot == snapshotBefore
        )
        #expect(setup.renderer.activeStroke?.token == accepted)
        #expect(completions.isEmpty)

        try setup.renderer.requestStrokeCommit(
            token: accepted,
            sample: depositionSample(.ended, x: 48),
            maximumRetainedBytes: 1_000_000
        )
        _ = try setup.renderer.finishCommitForHarness()

        #expect(completions.count == 1)
        guard case let .rasterSuccess(receipt) = completions.first else {
            Issue.record("Expected exactly one accepted-token receipt")
            return
        }
        #expect(receipt.token == accepted)
        try setup.renderer.drainCompletedOperationsForHarness()
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
        let initialRevision = setup.renderer.harnessRevision

        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        try setup.renderer.cancelStroke(token: token)

        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(setup.renderer.isIdle)
        #expect(setup.renderer.harnessRevision == initialRevision)
        #expect(completions.isEmpty)
        #expect(setup.renderer.harnessReservedInstanceBufferCount == 0)
    }

    @Test
    @MainActor
    func nativeTwoPhaseFinishDefersRevisionAllocationUntilDrain()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.two-phase-finish")
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 12)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 16),
            style: depositionStyle(brush, compositeMode: .draw)
        )

        try setup.renderer.finishStrokeTransient(
            token: token,
            sample: depositionSample(.ended, x: 48)
        )
        #expect(setup.renderer.activeStroke?.isFinishedTransiently == true)
        #expect(setup.renderer.activeStroke?.commitRequested == false)
        try setup.renderer.commitFinishedStroke(
            token: token,
            maximumRetainedBytes: 1_000_000
        )

        #expect(setup.renderer.activeStroke?.commitRequested == false)
        #expect(setup.renderer.activeStroke?.pendingRevisions == nil)
        _ = try setup.renderer.finishCommitForHarness()
        #expect(setup.renderer.isIdle)
    }

    // Retired Main reservation duplicate; covered by
    // warmedOffMainWorkspaceIsReusedAcrossBrushModeAndViewportChanges.
    @Test
    @MainActor
    func nativeReservationFailureIsAtomicAndRendererRecovers()
        async throws
    {
        try await warmedOffMainWorkspaceIsReusedAcrossBrushModeAndViewportChanges()
    }

    // Retired Main encoder-selector duplicate; covered by
    // generatorAndProjectionExecuteOffMainActor.
    @Test
    @MainActor
    func missingDepositionEncoderFailsWithoutCanonicalMutation()
        async throws
    {
        try await StrokeRenderCoordinatorTests()
            .generatorAndProjectionExecuteOffMainActor()
    }

    // Retired Main command-failure duplicate; covered by
    // offMainSurfaceCommandFailureCancelsWithoutCanonicalMutation.
    @Test
    @MainActor
    func nativeGPUFailureClearsTransientStateAndNextStrokeSucceeds()
        async throws
    {
        try await offMainSurfaceCommandFailureCancelsWithoutCanonicalMutation()
    }

    @Test
    @MainActor
    func lateRevisionBudgetFailurePreservesCanonicalAndAllowsRetry()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.history-failure")
        try setup.renderer.activateDrawBrush(brush)
        let before = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        let failedToken = RendererOperationToken(rawValue: 17)
        try setup.renderer.beginStroke(
            token: failedToken,
            sample: depositionSample(.began),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        try setup.renderer.requestStrokeCommit(
            token: failedToken,
            sample: depositionSample(.ended),
            maximumRetainedBytes: 0
        )

        #expect(
            throws: MetalRendererError.rasterRevisionStorageLimitExceeded
        ) {
            _ = try setup.renderer.finishCommitForHarness()
        }

        #expect(setup.renderer.isIdle)
        #expect(setup.renderer.harnessRasterRevisionResidentBytes == 0)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == before
        )

        try commitNativeStroke(
            renderer: setup.renderer,
            brush: brush,
            token: RendererOperationToken(rawValue: 18)
        )
        #expect(setup.renderer.isIdle)
    }

    // Retired Main projection-overflow duplicate; covered by
    // capacityFailureIsTransactionalAndHighWaterIsBounded.
    @Test
    @MainActor
    func nativeProjectedInstanceOverflowIsAtomicAndRendererRecovers()
        async throws
    {
        try StrokeRenderCoordinatorTests()
            .capacityFailureIsTransactionalAndHighWaterIsBounded()
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

    // Retired post-begin queue-removal duplicate; covered by
    // offMainSurfaceCommandFailureCancelsWithoutCanonicalMutation.
    @Test
    @MainActor
    func nativeCommandBufferAbsenceIsAtomicAndRendererRecovers()
        async throws
    {
        try await offMainSurfaceCommandFailureCancelsWithoutCanonicalMutation()
    }

    @Test
    @MainActor
    func nativeCommitGPUFailureIsAtomicAndRendererRecovers()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.commit-failure")
        try setup.renderer.activateDrawBrush(brush)
        let before = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        let failedToken = RendererOperationToken(rawValue: 25)
        try setup.renderer.beginStroke(
            token: failedToken,
            sample: depositionSample(.began),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        try setup.renderer.requestStrokeCommit(
            token: failedToken,
            sample: depositionSample(.ended, x: 40),
            maximumRetainedBytes: 1_000_000
        )

        #expect(
            throws: MetalRendererError.commandFailed(
                "injected harness command-buffer failure"
            )
        ) {
            _ = try setup.renderer.finishCommitForHarness(
                forceCommitFailure: true
            )
        }

        #expect(setup.renderer.isIdle)
        #expect(setup.renderer.harnessReservedInstanceBufferCount == 0)
        #expect(setup.renderer.harnessRasterRevisionResidentBytes == 0)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == before
        )

        try commitNativeStroke(
            renderer: setup.renderer,
            brush: brush,
            token: RendererOperationToken(rawValue: 26)
        )
    }

    // Retired Main replay-completion duplicate; covered by
    // predictionIsPreparedOffMainAndReplacesOnlySpeculativeWork.
    @Test
    @MainActor
    func nativeStaleReplayCompletionCannotReplaceNewerPrediction()
        async throws
    {
        try await StrokeRenderCoordinatorTests()
            .predictionIsPreparedOffMainAndReplacesOnlySpeculativeWork()
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
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.prediction-parity"),
            replayMode: .replayTail,
            replayLimits: BrushRecipePolicy.replayTailLimits
        )
        let baselineBrush = try await baseline.compileBrush(
            recipe: recipe
        )
        let predictedBrush = try await predicted.compileBrush(
            recipe: recipe
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
            sample: depositionSample(.ended, x: 52),
            maximumRetainedBytes: 1_000_000
        )
        try predicted.renderer.requestStrokeCommit(
            token: predictedToken,
            sample: depositionSample(.ended, x: 52),
            maximumRetainedBytes: 1_000_000
        )
        _ = try baseline.renderer.finishCommitForHarness()
        _ = try predicted.renderer.finishCommitForHarness()

        #expect(predictedDabs == baselineDabs)
        #expect(
            depositionTextureBytes(
                try predicted.renderer.copyCanonicalForHarness()
            )
                == depositionTextureBytes(
                    try baseline.renderer.copyCanonicalForHarness()
                )
        )
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

        try commitNativeStroke(
            renderer: wide.renderer,
            brush: wideBrush,
            token: RendererOperationToken(rawValue: 30)
        )
        try commitNativeStroke(
            renderer: narrow.renderer,
            brush: narrowBrush,
            token: RendererOperationToken(rawValue: 31)
        )

        #expect(
            depositionTextureBytes(
                try narrow.renderer.copyCanonicalForHarness()
            )
                == depositionTextureBytes(
                    try wide.renderer.copyCanonicalForHarness()
                )
        )
    }

    @Test
    @MainActor
    func projectedLongStrokeHarnessKeepsNativeLifecycleAcrossFourHundredFrames()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.long-harness")
        try setup.renderer.activateDrawBrush(brush)
        let points = HarnessRunner.taskEightLongStrokePoints
        #expect(points.count == BenchmarkLongStrokeMetrics.segmentCount + 1)

        _ = try setup.renderer.beginFixedProjectedStrokeForHarness(
            at: points[0]
        )
        var previousHighWater: UInt64 = 0
        let initial = try setup.renderer.flushPendingLiveForHarness()
        var audit = try HarnessRunner.auditEncodedInstanceIdentityRanges(
            sceneName: "projected-long-stroke",
            previousEncodedHighWater: previousHighWater,
            emittedHighWater: initial.emittedHighWater,
            encodedIdentityRanges: initial.encodedIdentityRanges
        )
        previousHighWater = audit.encodedHighWater

        for point in points.dropFirst() {
            _ = try setup.renderer.appendFixedProjectedSegmentForHarness(
                to: point
            )
            let frame = try setup.renderer.flushPendingLiveForHarness()
            audit = try HarnessRunner.auditEncodedInstanceIdentityRanges(
                sceneName: "projected-long-stroke",
                previousEncodedHighWater: previousHighWater,
                emittedHighWater: frame.emittedHighWater,
                encodedIdentityRanges: frame.encodedIdentityRanges
            )
            #expect(audit.newlyEncodedInstanceCount > 0)
            previousHighWater = audit.encodedHighWater
        }

        try setup.renderer.endFixedProjectedStrokeForHarness()
        #expect(setup.renderer.activeStroke != nil)
        #expect(setup.renderer.activeStroke?.commitRequested == true)
        #expect(setup.renderer.activeStroke?.pendingRevisions == nil)
        #expect(
            setup.renderer.activeStroke?.pendingTokenBearingFrameCount == 0
        )
        #expect(
            setup.renderer.activeStroke?.frozenHarnessScheduler?
                .authoritativeIsDrained
                == true
        )
        #expect(setup.renderer.needsReplayClear)
        _ = try setup.renderer.finishCommitForHarness()
        #expect(setup.renderer.isIdle)
        #expect(previousHighWater > 400)
    }

    @Test
    @MainActor
    func nativeHarnessAuditAllowsBacklogThenRequiresExactFinalDrain()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            id: "brush.backlog-integration"
        )
        try setup.renderer.activateDrawBrush(brush)

        _ = try setup.renderer.beginFixedProjectedStrokeForHarness(
            at: WorldPoint(x: 32, y: 32)
        )
        for _ in 1..<5_000 {
            _ = try setup.renderer.appendFixedProjectedSegmentForHarness(
                to: WorldPoint(x: 32, y: 32)
            )
        }

        let first = try setup.renderer.flushPendingLiveForHarness()
        let firstAudit = try HarnessRunner.auditLiveFlushIdentity(
            sceneName: "backlog-integration",
            previousEncodedHighWater: 0,
            flushResult: first
        )
        #expect(first.emittedHighWater == 5_000)
        #expect(first.authoritativeBacklogRemaining == 904)
        #expect(firstAudit.newlyEncodedInstanceCount == 4_096)
        #expect(firstAudit.encodedHighWater == 4_096)

        let final = try setup.renderer.flushPendingLiveForHarness()
        let finalAudit = try HarnessRunner.auditLiveFlushIdentity(
            sceneName: "backlog-integration",
            previousEncodedHighWater: firstAudit.encodedHighWater,
            flushResult: final
        )
        #expect(final.emittedHighWater == 5_000)
        #expect(final.authoritativeBacklogRemaining == 0)
        #expect(finalAudit.newlyEncodedInstanceCount == 904)
        #expect(finalAudit.encodedHighWater == 5_000)
        try setup.renderer.cancelStroke(
            token: setup.renderer.activeStroke!.token
        )
    }

    @Test
    @MainActor
    func nativeInputUsesBoundedActorMailboxAfterWarmup() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        try setup.renderer.applyTiling(.squareRotation)
        let token = RendererOperationToken(rawValue: 39)
        let workspaceIdentity =
            setup.renderer.offMainStrokeWorkspaceIdentityForTesting
        let workspaceInstallationCount = setup.renderer
            .offMainStrokeWorkspaceInstallationCountForTesting
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 0),
            style: depositionStyle(brush, compositeMode: .draw)
        )

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
            sample: depositionSample(.ended, x: 48),
            maximumRetainedBytes: 1_000_000
        )
        try await prepareOffMainCommit(setup.renderer)
        let preview = depositionTextureBytes(
            try setup.renderer.renderOffscreenDisplayForHarness(
                width: 64,
                height: 64,
                showGridLines: false
            ).texture
        )

        _ = try setup.renderer.submitCommitForHarness()
        try setup.renderer.drainCompletedOperationsForHarness()
        let committed = depositionTextureBytes(
            try setup.renderer.renderOffscreenDisplayForHarness(
                width: 64,
                height: 64,
                showGridLines: false
            ).texture
        )

        #expect(maximumChannelDelta(preview, committed) <= 1)
    }

    @Test
    @MainActor
    func nativeSubmittedCommitAloneOwnsTerminalStateAfterDisplayFailure()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            id: "brush.submitted-commit-owner"
        )
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 40)
        var completions: [RendererOperationCompletion] = []
        var reportedErrors: [MetalRendererError] = []
        setup.renderer.onOperationCompleted = { completions.append($0) }
        setup.renderer.onError = { reportedErrors.append($0) }
        let initial = setup.renderer.harnessTilingMutationSnapshot

        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        try setup.renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 40),
            maximumRetainedBytes: 1_000_000
        )
        try await prepareOffMainCommit(setup.renderer)
        setup.renderer.deferNextFrameOutcomeForHarness()
        _ = try setup.renderer.submitCommitForHarness()
        let provisionalBytes =
            setup.renderer.harnessRasterRevisionResidentBytes

        try setup.renderer.submitDisplayOnlyForHarness(forceFailure: true)
        #expect(
            throws: MetalRendererError.commandFailed(
                "injected harness command-buffer failure"
            )
        ) {
            try setup.renderer.drainNextCompletedOperationForHarness()
        }

        #expect(!setup.renderer.isIdle)
        #expect(completions.isEmpty)
        #expect(setup.renderer.harnessRevision == initial.revision)
        #expect(
            setup.renderer.harnessTilingMutationSnapshot.canonicalFront
                == initial.canonicalFront
        )
        #expect(
            setup.renderer.harnessRasterRevisionResidentBytes
                == provisionalBytes
        )
        #expect(reportedErrors.count == 1)

        setup.renderer.releaseDeferredFrameOutcomesForHarness()
        try setup.renderer.drainCompletedOperationsForHarness()
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(setup.renderer.isIdle)
        #expect(
            setup.renderer.harnessRevision == initial.revision.advanced()
        )
        #expect(
            setup.renderer.harnessTilingMutationSnapshot.canonicalFront
                == initial.canonicalScratch
        )
        guard case let .rasterSuccess(receipt) = completions.first else {
            Issue.record("Expected exactly one eventual raster success")
            return
        }
        #expect(receipt.token == token)
        setup.renderer.releaseRasterRevisions([
            receipt.before.id,
            receipt.after.id,
        ])
    }
    @Test
    @MainActor
    func nativeAppendOnlyEstimatedSuffixCommitsThroughActor() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.append-only-estimated"),
            replayMode: .appendOnly
        )
        let brush = try await setup.compileBrush(recipe: recipe)
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
        try setup.renderer.commitFinishedStroke(
            token: token,
            maximumRetainedBytes: 1_000_000
        )
        _ = try setup.renderer.finishCommitForHarness()

        #expect(setup.renderer.isIdle)
        #expect(setup.renderer.harnessRevision.rawValue == 1)
        #expect(
            setup.renderer.offMainSurfaceSnapshotForTesting?
                .encodedInstanceCount ?? 0 > 0
        )
        #expect(
            setup.renderer.instancePool.diagnosticSnapshot
                .strokeLeaseHighWater == 0
        )
    }

    // The retired MainActor scheduler's instance-pool preflight and replay
    // clear failure tests are covered on the production actor route by
    // offMainSurfaceLeaseWaitsForCompositeCompletionBeforeNextInput() and
    // offMainSurfaceCommandFailureCancelsWithoutCanonicalMutation().
    @Test
    @MainActor
    func nativeFractionalEraserPreviewMatchesCommitAfterPanAndZoom()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.fractional-eraser"),
            baseFlow: 1,
            strokeOpacity: 0.55
        )
        let brush = try await setup.compileBrush(recipe: recipe)
        try setup.renderer.activateEraserBrush(brush)
        try setup.renderer.replaceCanonicalPixelsForHarness(
            depositionNonuniformCanonicalBytes()
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
            sample: depositionSample(.ended, x: 38.6, y: 35.7),
            maximumRetainedBytes: 1_000_000
        )
        try await prepareOffMainCommit(setup.renderer)
        let live = depositionTextureBytes(
            try setup.renderer.renderOffscreenDisplayForHarness(
                width: 79,
                height: 73,
                showGridLines: false
            ).texture
        )

        _ = try setup.renderer.submitCommitForHarness()
        try setup.renderer.drainCompletedOperationsForHarness()
        let committed = depositionTextureBytes(
            try setup.renderer.renderOffscreenDisplayForHarness(
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
        try commitNativeStroke(
            renderer: setup.renderer,
            brush: brush,
            token: RendererOperationToken(rawValue: 45)
        )
        #expect(
            try depositionCenterBGRA(setup.renderer)[3] == 255
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
            sample: depositionSample(.ended, x: 40),
            maximumRetainedBytes: 1_000_000
        )
        _ = try setup.renderer.finishCommitForHarness()
        #expect(
            (125...130).contains(
                Int(try depositionCenterBGRA(setup.renderer)[3])
            )
        )
    }

    @Test
    @MainActor
    func nativeInkOffMainPreparationIsBatchPartitionInvariant()
        async throws
    {
        guard let incremental = try makeDepositionRendererSetup(),
              let partitioned = try makeDepositionRendererSetup(),
              let legacy = try makeDepositionRendererSetup()
        else { return }
        let incrementalBrush = try await incremental.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        let partitionedBrush = try await partitioned.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        let legacyBrush = try await legacy.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        requireSendableRenderState(incrementalBrush.renderState)
        try incremental.renderer.activateDrawBrush(incrementalBrush)
        try partitioned.renderer.activateDrawBrush(partitionedBrush)
        try legacy.renderer.activateDrawBrush(legacyBrush)
        let incrementalToken = RendererOperationToken(rawValue: 90_001)
        let partitionedToken = RendererOperationToken(rawValue: 90_002)
        let legacyToken = RendererOperationToken(rawValue: 90_003)
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
        try legacy.renderer.beginStroke(
            token: legacyToken,
            sample: began,
            style: depositionStyle(
                legacyBrush,
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
        try legacy.renderer.appendStrokeBatch(
            token: legacyToken,
            samples: moved
        )

        try incremental.renderer.requestStrokeCommit(
            token: incrementalToken,
            sample: depositionSample(.ended, x: 52, y: 24),
            maximumRetainedBytes: 1_000_000
        )
        try legacy.renderer.requestStrokeCommit(
            token: legacyToken,
            sample: depositionSample(.ended, x: 52, y: 24),
            maximumRetainedBytes: 1_000_000
        )
        try partitioned.renderer.requestStrokeCommit(
            token: partitionedToken,
            sample: depositionSample(.ended, x: 52, y: 24),
            maximumRetainedBytes: 1_000_000
        )
        _ = try incremental.renderer.finishCommitForHarness()
        _ = try partitioned.renderer.finishCommitForHarness()
        _ = try legacy.renderer.finishCommitForHarness()

        let incrementalPixels = depositionTextureBytes(
            try incremental.renderer.copyCanonicalForHarness()
        )
        #expect(
            incrementalPixels == depositionTextureBytes(
                try partitioned.renderer.copyCanonicalForHarness()
            )
        )
        #expect(
            incrementalPixels == depositionTextureBytes(
                try legacy.renderer.copyCanonicalForHarness()
            )
        )
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
            sample: depositionSample(.ended, x: 48, y: 24),
            maximumRetainedBytes: 1_000_000
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
            sample: depositionSample(.ended, x: 48, y: 24),
            maximumRetainedBytes: 1_000_000
        )

        _ = try offMain.renderer.finishCommitForHarness()
        _ = try reference.renderer.finishCommitForHarness()

        #expect(!publishedDabs.isEmpty)
        #expect(offMain.renderer.isIdle)
        #expect(
            offMain.renderer
                .compatibilityInkEncodingRanOnMainThreadForTesting == false
        )
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
        #expect(!offMain.renderer.liveTile.isDirty)
        #expect(offMain.renderer.offMainZeroWorkLeaseCountForTesting == 1)
        #expect(
            offMain.renderer.offMainSurfaceSnapshotForTesting?
                .surfaceCount == 2
        )
        #expect(
            offMain.renderer.offMainSurfaceSnapshotForTesting?
                .surfaceLeaseHighWater == 1
        )
        #expect(
            depositionTextureBytes(
                try offMain.renderer.copyCanonicalForHarness()
            ) == depositionTextureBytes(
                try reference.renderer.copyCanonicalForHarness()
            )
        )
    }

    @Test
    @MainActor
    func offMainMatchesFrozenPixelsAcrossTilingAndSymmetryWithPrediction()
        async throws
    {
        let tilings: [(TilingKind, String)] = [
            (.grid, "128dadaf651fb66f"),
            (.halfDrop, "e47e95b2759ef798"),
            (.squareRotation, "5add6b42f2963f65"),
            (.squareKaleidoscope, "7afcc6f412f49865"),
            (.hexagons, "8140200a3635e3a5"),
            (.kaleidoscope30, "3077db84bff4d09c"),
        ]
        for (index, entry) in tilings.enumerated() {
            let (tiling, expectedDigest) = entry
            guard let offMain = try makeDepositionRendererSetup(
                tiling: tiling
            ), let legacy = try makeDepositionRendererSetup(tiling: tiling)
            else { return }
            let offMainBrush = try await offMain.compileBrush(
                definition: StageFourAnchorDefinitions.ink
            )
            let legacyBrush = try await legacy.compileBrush(
                definition: StageFourAnchorDefinitions.ink
            )
            try offMain.renderer.activateDrawBrush(offMainBrush)
            try legacy.renderer.activateDrawBrush(legacyBrush)
            let offMainToken = RendererOperationToken(
                rawValue: UInt64(91_000 + index * 2)
            )
            let legacyToken = RendererOperationToken(
                rawValue: UInt64(91_001 + index * 2)
            )
            let began = depositionSample(.began, x: 4, y: 7)
            let authoritative = [
                depositionSample(.moved, x: 18, y: 29),
                depositionSample(.moved, x: 39, y: 53),
            ]
            let prediction = [
                depositionPredictedSample(x: 48),
                depositionPredictedSample(x: 56),
            ]

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
                samples: prediction
            )
            try offMain.renderer.appendStrokeBatch(
                token: offMainToken,
                samples: authoritative
            )
            try offMain.renderer.requestStrokeCommit(
                token: offMainToken,
                sample: depositionSample(.ended, x: 60, y: 12),
                maximumRetainedBytes: 4_000_000
            )

            try legacy.renderer.beginStroke(
                token: legacyToken,
                sample: began,
                style: depositionStyle(
                    legacyBrush,
                    compositeMode: .draw,
                    diameter: 12
                )
            )
            try legacy.renderer.appendStrokeBatch(
                token: legacyToken,
                samples: prediction
            )
            try legacy.renderer.appendStrokeBatch(
                token: legacyToken,
                samples: authoritative
            )
            try legacy.renderer.requestStrokeCommit(
                token: legacyToken,
                sample: depositionSample(.ended, x: 60, y: 12),
                maximumRetainedBytes: 4_000_000
            )

            try await prepareOffMainCommit(offMain.renderer)
            try await prepareOffMainCommit(legacy.renderer)
            _ = try offMain.renderer.finishCommitForHarness()
            _ = try legacy.renderer.finishCommitForHarness()
            let offMainPixels = depositionTextureBytes(
                try offMain.renderer.copyCanonicalForHarness()
            )
            let legacyPixels = depositionTextureBytes(
                try legacy.renderer.copyCanonicalForHarness()
            )
            let digest = depositionPixelDigest(offMainPixels)
            print(
                "TASK7_PARITY \(tiling) "
                    + "digest=\(digest)"
            )
            #expect(
                offMainPixels == legacyPixels,
                "Off-main determinism mismatch for \(tiling)"
            )
            #expect(digest == expectedDigest)
            #expect(
                offMain.renderer.offMainZeroWorkLeaseCountForTesting == 1
            )
            #expect(
                offMain.renderer
                    .compatibilityInkEncodingRanOnMainThreadForTesting
                    == false
            )
        }
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
    func stageCTimedRadialPagingMatchesIncrementallyDrainedCanonicalPixels()
        async throws
    {
        let radial = FiniteSymmetryConfiguration.radial(
            RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 32,
                center: WorldPoint(x: 32, y: 32)
            )
        )
        guard let paged = try makeDepositionRendererSetup(finite: radial),
              let incremental = try makeDepositionRendererSetup(finite: radial)
        else { return }
        let program = try stageCMetalTestProgram(
            id: "test.renderer.stage-c-radial-paging",
            baseSpacingFraction: 0.1,
            replayMode: .appendOnly,
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let pagedBrush = try await paged.compileBrush(
            definition: program.definition
        )
        let incrementalBrush = try await incremental.compileBrush(
            definition: program.definition
        )
        try paged.renderer.activateDrawBrush(pagedBrush)
        try incremental.renderer.activateDrawBrush(incrementalBrush)

        let pagedToken = RendererOperationToken(rawValue: 91_100)
        let incrementalToken = RendererOperationToken(rawValue: 91_101)
        let began = timedDepositionSample(
            .began,
            x: 40,
            timestamp: 0
        )
        var pagedDabs: [LogicalDab] = []
        paged.renderer.onLogicalDabsGenerated = { pagedDabs.append($0) }
        try paged.renderer.beginStroke(
            token: pagedToken,
            sample: began,
            style: depositionStyle(
                pagedBrush,
                compositeMode: .draw,
                diameter: 32
            )
        )
        try incremental.renderer.beginStroke(
            token: incrementalToken,
            sample: began,
            style: depositionStyle(
                incrementalBrush,
                compositeMode: .draw,
                diameter: 32
            )
        )
        try await drainOffMainPreparedFrames(
            paged.renderer,
            minimumFrameCount: 1
        )
        try await drainOffMainPreparedFrames(
            incremental.renderer,
            minimumFrameCount: 1
        )

        // One input interval is intentionally large enough for the production
        // encoder to cross the per-frame projection budget. The assertion
        // below uses the surface encoder's measured cumulative work rather
        // than inferring it from ray count. The reference drains three smaller
        // prefixes to prove input partitioning does not change final pixels.
        for candidateIndex in stride(from: 40, through: 120, by: 40) {
            let fraction = Float(candidateIndex) / 160
            try incremental.renderer.appendStroke(
                token: incrementalToken,
                sample: timedDepositionSample(
                    .moved,
                    x: 40 + 16 * fraction,
                    timestamp: Double(candidateIndex) / 240
                )
            )
            try await drainOffMainPreparedFrames(
                incremental.renderer,
                minimumFrameCount: 1
            )
        }
        let ended = timedDepositionSample(
            .ended,
            x: 56,
            timestamp: 160.0 / 240
        )
        try paged.renderer.requestStrokeCommit(
            token: pagedToken,
            sample: ended,
            maximumRetainedBytes: 1_000_000
        )
        try incremental.renderer.requestStrokeCommit(
            token: incrementalToken,
            sample: ended,
            maximumRetainedBytes: 1_000_000
        )
        try await prepareOffMainCommit(paged.renderer)
        try await prepareOffMainCommit(incremental.renderer)
        let pagedScheduler = await paged.renderer
            .offMainSchedulerSnapshotForTesting()
        let pagedSurface = try #require(
            paged.renderer.offMainSurfaceSnapshotForTesting
        )
        #expect(pagedScheduler.authoritativeCandidatePageCount > 1)
        #expect(pagedScheduler.authoritativeCandidateResumeCount > 1)
        #expect(
            pagedScheduler.synchronousCompatibilityReplayInvocationCount == 0
        )
        #expect(
            pagedScheduler.authoritativeCandidateProjectionHighWater <= 4_096
        )
        #expect(
            pagedScheduler.maximumPreparationWorkUnitsPerFrame <= 4_096
        )
        #expect(pagedSurface.encodedInstanceCount > 4_096)

        _ = try paged.renderer.finishCommitForHarness()
        _ = try incremental.renderer.finishCommitForHarness()
        let pagedPixels = depositionTextureBytes(
            try paged.renderer.copyCanonicalForHarness()
        )
        let incrementalPixels = depositionTextureBytes(
            try incremental.renderer.copyCanonicalForHarness()
        )
        #expect(pagedDabs.count == 161)
        #expect(pagedDabs.map(\.ordinal) == Array(0...UInt64(160)))
        #expect(pagedPixels.contains { $0 != 0 })
        #expect(pagedPixels == incrementalPixels)
        #expect(paged.renderer.isIdle)
        #expect(incremental.renderer.isIdle)
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
        let resultOwnershipProbe = StrokePreparationResultOwnershipProbe()
        setup.renderer.setStrokePreparationResultOwnershipProbeForTesting(
            resultOwnershipProbe
        )
        let canonicalBefore = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        let revisionBefore = setup.renderer.harnessRevision
        let revisionBytesBefore =
            setup.renderer.harnessRasterRevisionResidentBytes
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
            ),
            maximumRetainedBytes: 1_000_000
        )
        try await prepareOffMainNoOpCompletion(setup.renderer)

        let zeroWorkScheduler = await setup.renderer
            .offMainSchedulerSnapshotForTesting()
        #expect(zeroWorkScheduler.authoritativeCandidatePageCount > 2)
        #expect(zeroWorkScheduler.authoritativeCandidateResumeCount > 2)
        #expect(
            zeroWorkScheduler.synchronousCompatibilityReplayInvocationCount
                == 0
        )
        #expect(zeroWorkScheduler.authoritativeCandidateProjectionHighWater == 0)
        #expect(
            setup.renderer.offMainZeroWorkLeaseCountForTesting > 1
        )

        #expect(!setup.renderer.isIdle)
        #expect(
            !setup.renderer.offMainStrokeWorkspaceIsAvailableForTesting
        )
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
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == canonicalBefore
        )
        #expect(setup.renderer.harnessRevision == revisionBefore)
        #expect(
            setup.renderer.harnessRasterRevisionResidentBytes
                == revisionBytesBefore
        )
        #expect(
            setup.renderer.documentDomainLocked
                == documentDomainLockedBefore
        )
        #expect(
            setup.renderer.radialGeometryLocked
                == radialGeometryLockedBefore
        )
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(setup.renderer.isIdle)
        let resultOwnership = resultOwnershipProbe.snapshot
        #expect(resultOwnership.workerAcknowledgementCount > 1)
        #expect(
            !resultOwnership.acknowledgementArrivedBeforeResultRelease
        )
        #expect(!resultOwnership.mainWaitTimedOut)
        #expect(
            setup.renderer.offMainStrokeWorkspaceIsAvailableForTesting
        )
        #expect(
            setup.renderer.harnessRasterRevisionResidentBytes
                == revisionBytesBefore
        )
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
            ),
            maximumRetainedBytes: 1_000_000
        )
        try await prepareOffMainCommit(setup.renderer)
        _ = try setup.renderer.finishCommitForHarness()

        #expect(setup.renderer.isIdle)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) != canonicalBefore
        )
        let ownershipAfterVisibleStroke = resultOwnershipProbe.snapshot
        #expect(
            ownershipAfterVisibleStroke.workerAcknowledgementCount
                == resultOwnership.workerAcknowledgementCount
        )
        #expect(
            !ownershipAfterVisibleStroke
                .acknowledgementArrivedBeforeResultRelease
        )
        #expect(!ownershipAfterVisibleStroke.mainWaitTimedOut)
    }

    @Test
    @MainActor
    func stageCVisibleCandidateContinuationRejectsOvertakingThenRapidlyReuses()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup(finite: .plain)
        else { return }
        let firstProgram = try stageCMetalTestProgram(
            id: "test.renderer.stage-c-visible-continuation-first",
            replayMode: .appendOnly,
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let replacementProgram = try stageCMetalTestProgram(
            id: "test.renderer.stage-c-visible-continuation-replacement",
            replayMode: .appendOnly,
            emission: BrushEmissionDefinition(
                mode: .time,
                timeInterval: 1.0 / 240
            )
        )
        let firstBrush = try await setup.compileBrush(
            definition: firstProgram.definition
        )
        let replacementBrush = try await setup.compileBrush(
            definition: replacementProgram.definition
        )
        try setup.renderer.activateDrawBrush(firstBrush)

        // Seed two valid raster references so the undo and redo restore routes
        // reach the renderer's active-stroke gate rather than failing because
        // of a forged or missing history payload.
        var seedReceipt: RasterMutationReceipt?
        setup.renderer.onOperationCompleted = { completion in
            if case let .rasterSuccess(receipt) = completion {
                seedReceipt = receipt
            }
        }
        try setup.renderer.requestClearForHarness(
            token: RendererOperationToken(rawValue: 91_120),
            maximumRetainedBytes: 1_000_000,
            forceFailure: false
        )
        try setup.renderer.finishRasterOperationForHarness()
        let history = try #require(seedReceipt)
        setup.renderer.onOperationCompleted = nil
        let canonicalBefore = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )

        let cancellationCount = setup.renderer
            .offMainTerminalCancellationPublicationCountForTesting
        let token = RendererOperationToken(rawValue: 91_121)
        try setup.renderer.beginStroke(
            token: token,
            sample: timedDepositionSample(
                .began,
                x: 16,
                timestamp: 0
            ),
            style: depositionStyle(
                firstBrush,
                compositeMode: .draw,
                diameter: 16
            )
        )
        try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 1
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: timedDepositionSample(
                .moved,
                x: 48,
                timestamp: 513.0 / 240
            )
        )
        let paused = try await awaitOffMainCandidateContinuationResult(
            setup.renderer
        )
        #expect(paused.mailbox.pendingResultCount == 1)
        #expect(paused.mailbox.awaitingPreparedFrameSubmission)
        #expect(paused.scheduler.authoritativeCandidateContinuationPending)
        #expect(
            paused.scheduler.synchronousCompatibilityReplayInvocationCount
                == 0
        )

        #expect(throws: MetalRendererError.commitPendingInput) {
            try setup.renderer.requestResizeForHarness(
                token: RendererOperationToken(rawValue: 91_122),
                to: PixelSize(width: 96, height: 80),
                maximumRetainedBytes: 1_000_000,
                forceResourceAllocationFailure: false
            )
        }
        #expect(throws: MetalRendererError.commitPendingInput) {
            try setup.renderer.requestClearForHarness(
                token: RendererOperationToken(rawValue: 91_123),
                maximumRetainedBytes: 1_000_000,
                forceFailure: false
            )
        }
        #expect(throws: MetalRendererError.commitPendingInput) {
            try setup.renderer.requestRasterRestoreForHarness(
                token: RendererOperationToken(rawValue: 91_124),
                revision: history.before,
                forceFailure: false
            )
        }
        #expect(throws: MetalRendererError.commitPendingInput) {
            try setup.renderer.requestRasterRestoreForHarness(
                token: RendererOperationToken(rawValue: 91_125),
                revision: history.after,
                forceFailure: false
            )
        }
        #expect(
            throws: MetalRendererError.compiledBrushActivationRequiresIdle
        ) {
            try setup.renderer.activateDrawBrush(replacementBrush)
        }
        let afterConflicts = await setup.renderer
            .offMainSchedulerSnapshotForTesting()
        #expect(afterConflicts.authoritativeCandidateContinuationPending)
        #expect(setup.renderer.activeStroke?.token == token)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == canonicalBefore
        )

        try setup.renderer.cancelStroke(token: token)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        let cancelled = await setup.renderer
            .offMainSchedulerSnapshotForTesting()
        #expect(!cancelled.authoritativeCandidateContinuationPending)
        #expect(cancelled.activeGeneration == nil)
        #expect(setup.renderer.isIdle)
        #expect(
            setup.renderer
                .offMainTerminalCancellationPublicationCountForTesting
                == cancellationCount + 1
        )
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == canonicalBefore
        )

        try setup.renderer.activateDrawBrush(replacementBrush)
        let nextToken = RendererOperationToken(rawValue: 91_126)
        try setup.renderer.beginStroke(
            token: nextToken,
            sample: timedDepositionSample(
                .began,
                x: 20,
                timestamp: 10
            ),
            style: depositionStyle(
                replacementBrush,
                compositeMode: .draw,
                diameter: 16
            )
        )
        try setup.renderer.requestStrokeCommit(
            token: nextToken,
            sample: timedDepositionSample(
                .ended,
                x: 44,
                timestamp: 10 + 4.0 / 240
            ),
            maximumRetainedBytes: 1_000_000
        )
        try await prepareOffMainCommit(setup.renderer)
        _ = try setup.renderer.finishCommitForHarness()
        #expect(setup.renderer.isIdle)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) != canonicalBefore
        )

        setup.renderer.releaseRasterRevisions([
            history.before.id,
            history.after.id,
        ])
    }

    @Test
    @MainActor
    func stageCZeroWorkCandidateContinuationCancelsWithoutStaleRapidReuse()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup(finite: .plain)
        else { return }
        let program = try stageCMetalTestProgram(
            id: "test.renderer.stage-c-zero-work-continuation-cancel",
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
        let canonicalBefore = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        let cancellationCount = setup.renderer
            .offMainTerminalCancellationPublicationCountForTesting
        var publishedDabs: [LogicalDab] = []
        setup.renderer.onLogicalDabsGenerated = {
            publishedDabs.append($0)
        }

        let token = RendererOperationToken(rawValue: 91_130)
        try setup.renderer.beginStroke(
            token: token,
            sample: timedDepositionSample(
                .began,
                x: -10_000,
                timestamp: 0
            ),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 16
            )
        )
        try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 0
        )
        #expect(publishedDabs.map(\.ordinal) == [0])
        publishedDabs.removeAll(keepingCapacity: true)

        try setup.renderer.appendStroke(
            token: token,
            sample: timedDepositionSample(
                .moved,
                x: -10_000,
                timestamp: 1_025.0 / 240
            )
        )
        let paused = try await awaitOffMainCandidateContinuationResult(
            setup.renderer
        )
        #expect(paused.mailbox.pendingResultCount == 1)
        #expect(paused.mailbox.awaitingPreparedFrameSubmission)
        #expect(paused.scheduler.authoritativeCandidateContinuationPending)
        #expect(paused.scheduler.authoritativeCandidateProjectionHighWater == 0)
        #expect(
            paused.scheduler.synchronousCompatibilityReplayInvocationCount
                == 0
        )

        try setup.renderer.cancelStroke(token: token)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        let cancelled = await setup.renderer
            .offMainSchedulerSnapshotForTesting()
        #expect(!cancelled.authoritativeCandidateContinuationPending)
        #expect(cancelled.activeGeneration == nil)
        #expect(setup.renderer.isIdle)
        #expect(publishedDabs.isEmpty)
        #expect(
            setup.renderer
                .offMainTerminalCancellationPublicationCountForTesting
                == cancellationCount + 1
        )
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == canonicalBefore
        )

        let nextToken = RendererOperationToken(rawValue: 91_131)
        try setup.renderer.beginStroke(
            token: nextToken,
            sample: timedDepositionSample(
                .began,
                x: 20,
                timestamp: 10
            ),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 16
            )
        )
        try setup.renderer.requestStrokeCommit(
            token: nextToken,
            sample: timedDepositionSample(
                .ended,
                x: 44,
                timestamp: 10 + 4.0 / 240
            ),
            maximumRetainedBytes: 1_000_000
        )
        try await prepareOffMainCommit(setup.renderer)
        _ = try setup.renderer.finishCommitForHarness()
        #expect(publishedDabs.count == 5)
        #expect(publishedDabs.map(\.ordinal) == Array(0...UInt64(4)))
        #expect(setup.renderer.isIdle)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) != canonicalBefore
        )
    }

    @Test
    @MainActor
    func offMainEstimatedCorrectionsMatchDirectFinalPixels() async throws {
        let properties: [StrokeEstimatedProperties] = [
            .location,
            .pressure,
            .azimuth,
            .altitude,
        ]
        for (offset, property) in properties.enumerated() {
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
            let correctedToken = RendererOperationToken(
                rawValue: UInt64(91_100 + offset * 2)
            )
            let directToken = RendererOperationToken(
                rawValue: UInt64(91_101 + offset * 2)
            )
            let updateIndex = 200 + offset
            let initial = depositionCorrectionSample(
                phase: .began,
                kind: .actual,
                x: 10,
                pressure: 0.2,
                timestamp: 1,
                altitude: 0.4,
                azimuth: 0.6,
                estimationUpdateIndex: updateIndex,
                estimatedProperties: property,
                expecting: property
            )
            let update = depositionCorrectionSample(
                phase: .moved,
                kind: .estimatedUpdate,
                x: 38,
                pressure: 0.9,
                timestamp: 2,
                altitude: 1.1,
                azimuth: 1.4,
                estimationUpdateIndex: updateIndex,
                estimatedProperties: [],
                expecting: []
            )
            let final = depositionCorrectionSample(
                phase: .began,
                kind: .actual,
                x: property == .location ? 38 : 10,
                pressure: property == .pressure ? 0.9 : 0.2,
                timestamp: 1,
                altitude: property == .altitude ? 1.1 : 0.4,
                azimuth: property == .azimuth ? 1.4 : 0.6,
                estimationUpdateIndex: updateIndex,
                estimatedProperties: [],
                expecting: []
            )
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

            try corrected.renderer.beginStroke(
                token: correctedToken,
                sample: initial,
                style: style
            )
            try corrected.renderer.applyEstimatedStrokeUpdate(
                token: correctedToken,
                sample: update
            )
            try corrected.renderer.requestStrokeCommit(
                token: correctedToken,
                sample: depositionSample(.ended, x: 54, y: 24),
                maximumRetainedBytes: 1_000_000
            )

            try direct.renderer.beginStroke(
                token: directToken,
                sample: final,
                style: directStyle
            )
            try direct.renderer.requestStrokeCommit(
                token: directToken,
                sample: depositionSample(.ended, x: 54, y: 24),
                maximumRetainedBytes: 1_000_000
            )

            try await prepareOffMainCommit(corrected.renderer)
            try await prepareOffMainCommit(direct.renderer)
            _ = try corrected.renderer.finishCommitForHarness()
            _ = try direct.renderer.finishCommitForHarness()
            #expect(
                depositionTextureBytes(
                    try corrected.renderer.copyCanonicalForHarness()
                ) == depositionTextureBytes(
                    try direct.renderer.copyCanonicalForHarness()
                ),
                "Corrected/direct pixel mismatch for \(property)"
            )
        }
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

        try await drainOffMainPreparedFrames(
            corrected.renderer,
            minimumFrameCount: 3
        )
        try await drainOffMainPreparedFrames(
            direct.renderer,
            minimumFrameCount: 2
        )
        let correctedPixels = depositionTextureBytes(
            try corrected.renderer.renderOffscreenDisplayForHarness(
                width: 64,
                height: 64,
                showGridLines: false
            ).texture
        )
        let directPixels = depositionTextureBytes(
            try direct.renderer.renderOffscreenDisplayForHarness(
                width: 64,
                height: 64,
                showGridLines: false
            ).texture
        )
        #expect(correctedPixels == directPixels)
        try corrected.renderer.cancelStroke(token: correctedToken)
        try direct.renderer.cancelStroke(token: directToken)
    }

    @Test
    @MainActor
    func offMainSurfaceLeaseWaitsForCompositeCompletionBeforeNextInput()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        let canonicalBefore = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        let token = RendererOperationToken(rawValue: 90_006)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 8, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )

        for _ in 0..<10_000 {
            try setup.renderer.drainCompletedInteractiveOperations()
            if setup.renderer.hasPendingOffMainSurfaceLeaseForTesting {
                break
            }
            await Task.yield()
        }
        #expect(setup.renderer.hasPendingOffMainSurfaceLeaseForTesting)
        #expect(
            setup.renderer.offMainPreparationMailboxSnapshotForTesting?
                .awaitingPreparedFrameSubmission == true
        )
        let firstLeaseSurface = try #require(
            setup.renderer.offMainSurfaceSnapshotForTesting
        )
        #expect(firstLeaseSurface.authoritativeSurfaceIsInitialized)
        #expect(firstLeaseSurface.predictionSurfaceIsInitialized)

        setup.renderer.deferNextFrameOutcomeForHarness()
        _ = try setup.renderer.completeNextPendingInteractiveFrame()
        #expect(setup.renderer.hasPendingOffMainSurfaceLeaseForTesting)
        #expect(setup.renderer.hasSubmittedOffMainSurfaceLeaseForTesting)

        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 18, y: 24)
        )
        #expect(
            setup.renderer.offMainPreparationMailboxSnapshotForTesting?
                .input.authoritativePendingSampleCount == 1
        )

        setup.renderer.releaseDeferredFrameOutcomesForHarness()
        try setup.renderer.drainNextCompletedOperationForHarness()
        #expect(!setup.renderer.hasSubmittedOffMainSurfaceLeaseForTesting)
        #expect(!setup.renderer.hasPendingOffMainSurfaceLeaseForTesting)
        #expect(!setup.renderer.hasCurrentOffMainSurfaceLeaseForTesting)
        _ = try setup.renderer.renderOffscreenDisplayForHarness(
            width: 64,
            height: 64,
            showGridLines: false
        )

        for _ in 0..<10_000 {
            try setup.renderer.drainCompletedInteractiveOperations()
            if setup.renderer.hasPendingOffMainSurfaceLeaseForTesting {
                break
            }
            await Task.yield()
        }
        #expect(setup.renderer.hasPendingOffMainSurfaceLeaseForTesting)

        try setup.renderer.cancelStroke(token: token)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(setup.renderer.isIdle)
        #expect(!setup.renderer.hasPendingOffMainSurfaceLeaseForTesting)
        #expect(!setup.renderer.hasSubmittedOffMainSurfaceLeaseForTesting)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == canonicalBefore
        )
    }

    @Test
    @MainActor
    func warmedOffMainWorkspaceIsReusedAcrossBrushModeAndViewportChanges()
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
        let workspaceIdentity =
            setup.renderer.offMainStrokeWorkspaceIdentityForTesting
        let installationCount =
            setup.renderer.offMainStrokeWorkspaceInstallationCountForTesting
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
        _ = try await awaitOffMainPreparedLease(setup.renderer)
        try setup.renderer.cancelStroke(token: firstToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)

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
        _ = try await awaitOffMainPreparedLease(setup.renderer)
        try setup.renderer.cancelStroke(token: secondToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)

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
        _ = try await awaitOffMainPreparedLease(setup.renderer)
        try setup.renderer.cancelStroke(token: eraseToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)

        #expect(
            setup.renderer.offMainStrokeWorkspaceIdentityForTesting
                == workspaceIdentity
        )
        #expect(
            setup.renderer.offMainStrokeWorkspaceInstallationCountForTesting
                == installationCount
        )
        #expect(
            setup.renderer
                .offMainTerminalCancellationPublicationCountForTesting
                == cancellationCount + 3
        )
    }

    @Test
    @MainActor
    func submittedLeaseRetiresOnlyAfterFailedMainCommandTerminates()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        let workspaceIdentity =
            setup.renderer.offMainStrokeWorkspaceIdentityForTesting
        let installationCount =
            setup.renderer.offMainStrokeWorkspaceInstallationCountForTesting
        let cancellationCount = setup.renderer
            .offMainTerminalCancellationPublicationCountForTesting
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
        _ = try await awaitOffMainPreparedLease(setup.renderer)

        setup.renderer.deferNextFrameOutcomeForHarness()
        _ = try setup.renderer.completeNextPendingInteractiveFrame(
            forceFailure: true
        )
        #expect(setup.renderer.hasSubmittedOffMainSurfaceLeaseForTesting)
        try setup.renderer.cancelStroke(token: token)
        #expect(
            !setup.renderer.offMainStrokeWorkspaceIsAvailableForTesting
        )
        #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
            try setup.renderer.beginStroke(
                token: RendererOperationToken(rawValue: 90_015),
                sample: depositionSample(.began, x: 10, y: 22),
                style: depositionStyle(
                    brush,
                    compositeMode: .draw,
                    diameter: 12
                )
            )
        }

        setup.renderer.releaseDeferredFrameOutcomesForHarness()
        #expect(throws: MetalRendererError.self) {
            try setup.renderer.drainNextCompletedOperationForHarness()
        }
        try await awaitOffMainWorkspaceAvailable(setup.renderer)

        #expect(!setup.renderer.hasSubmittedOffMainSurfaceLeaseForTesting)
        #expect(!setup.renderer.hasCurrentOffMainSurfaceLeaseForTesting)
        #expect(
            setup.renderer.offMainStrokeWorkspaceIdentityForTesting
                == workspaceIdentity
        )
        #expect(
            setup.renderer.offMainStrokeWorkspaceInstallationCountForTesting
                == installationCount
        )
        #expect(
            setup.renderer
                .offMainTerminalCancellationPublicationCountForTesting
                == cancellationCount + 1
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
        let canonicalBefore = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
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
            sample: depositionSample(.ended, x: 56, y: 24),
            maximumRetainedBytes: 1_000_000
        )
        try await prepareOffMainCommit(setup.renderer)
        _ = try setup.renderer.finishCommitForHarness()
        let canonicalAfter = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        #expect(canonicalAfter != canonicalBefore)
        let history = try #require(receipt)

        try setup.renderer.requestRasterRestoreForHarness(
            token: RendererOperationToken(rawValue: 90_009),
            revision: history.before,
            forceFailure: false
        )
        try setup.renderer.finishRasterOperationForHarness()
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == canonicalBefore
        )

        try setup.renderer.requestRasterRestoreForHarness(
            token: RendererOperationToken(rawValue: 90_010),
            revision: history.after,
            forceFailure: false
        )
        try setup.renderer.finishRasterOperationForHarness()
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == canonicalAfter
        )
        setup.renderer.releaseRasterRevisions([
            history.before.id,
            history.after.id,
        ])
    }

    @Test
    @MainActor
    func offMainSurfaceCommandFailureCancelsWithoutCanonicalMutation()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        setup.renderer.setForceOffMainStrokeCommandFailureForTesting(true)
        let before = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        let token = RendererOperationToken(rawValue: 90_007)
        var reportedErrors: [MetalRendererError] = []
        var completions: [RendererOperationCompletion] = []
        setup.renderer.onError = { reportedErrors.append($0) }
        setup.renderer.onOperationCompleted = { completions.append($0) }
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 8, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try setup.renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 24, y: 24),
            maximumRetainedBytes: 1_000_000
        )

        #expect(throws: MetalRendererError.self) {
            _ = try setup.renderer.finishCommitForHarness()
        }
        #expect(setup.renderer.isIdle)
        #expect(reportedErrors.count == 1)
        #expect(
            completions.filter {
                if case let .failure(completedToken, _) = $0 {
                    return completedToken == token
                }
                return false
            }.count == 1
        )
        #expect(setup.renderer.harnessReservedInstanceBufferCount == 0)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == before
        )
    }

    @Test
    @MainActor
    func failedPreparedSurfaceCompositeAllowsImmediateRecoveryStroke()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        let canonicalBefore = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        let revisionBefore = setup.renderer.harnessRevision
        let historyBefore =
            try setup.renderer.harnessRasterRevisionSnapshots
        let historyBytesBefore =
            setup.renderer.harnessRasterRevisionResidentBytes
        let failedToken = RendererOperationToken(rawValue: 90_016)
        var completions: [RendererOperationCompletion] = []
        setup.renderer.onOperationCompleted = {
            completions.append($0)
        }

        try setup.renderer.beginStroke(
            token: failedToken,
            sample: depositionSample(.began, x: 8, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try setup.renderer.preparePendingLiveSurfaceForHarness()
        #expect(
            setup.renderer.hasPendingPreparedStrokeSurfaceForHarness
        )
        #expect(throws: MetalRendererError.commandFailed(
            "injected post-surface encoding failure"
        )) {
            _ = try setup.renderer.completeNextPendingInteractiveFrame(
                forcePostSurfaceEncodingFailure: true
            )
        }
        try setup.renderer.drainStrokeWorkspaceRetirementForHarness()

        #expect(
            completions.filter {
                if case let .failure(token, _) = $0 {
                    return token == failedToken
                }
                return false
            }.count == 1
        )
        #expect(!setup.renderer.hasActiveStroke)
        #expect(!setup.renderer.hasPendingRasterOperationForTesting)
        #expect(!setup.renderer.hasPendingOffMainSurfaceLeaseForTesting)
        #expect(!setup.renderer.hasSubmittedOffMainSurfaceLeaseForTesting)
        #expect(!setup.renderer.hasCurrentOffMainSurfaceLeaseForTesting)
        #expect(setup.renderer.offMainStrokeWorkspaceIsAvailableForTesting)
        #expect(setup.renderer.isIdle)
        #expect(setup.renderer.harnessReservedInstanceBufferCount == 0)
        #expect(setup.renderer.harnessRevision == revisionBefore)
        #expect(
            setup.renderer.harnessRasterRevisionResidentBytes
                == historyBytesBefore
        )
        #expect(
            try setup.renderer.harnessRasterRevisionSnapshots
                == historyBefore
        )
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == canonicalBefore
        )

        try commitNativeStroke(
            renderer: setup.renderer,
            brush: brush,
            token: RendererOperationToken(rawValue: 90_017)
        )
        #expect(setup.renderer.isIdle)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) != canonicalBefore
        )
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
                == GridCanvasContract.instanceCapacity
                    * MemoryLayout<PatternDepositionStampInstance>.stride
        )
        #expect(trace.surface.encodedFrameCount > 0)
        #expect(trace.surface.encodedInstanceCount > 0)
        // Scheduling may piggyback acknowledgements or publish an empty token.
        // Protocol work remains bounded to one per submitted batch plus commit.
        #expect(trace.zeroWorkLeaseCount <= 601)
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

    @Test
    @MainActor
    func partialBatchFailurePublishesAcceptedPrefixExactlyOnce()
        async throws
    {
        guard let reference = try makeDepositionRendererSetup(),
              let failing = try makeDepositionRendererSetup()
        else { return }
        let referenceBrush = try await reference.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        let failingBrush = try await failing.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try reference.renderer.activateDrawBrush(referenceBrush)
        try failing.renderer.activateDrawBrush(failingBrush)
        let referenceToken = RendererOperationToken(rawValue: 90_030)
        let failingToken = RendererOperationToken(rawValue: 90_031)
        let began = depositionSample(.began, x: 8, y: 24)
        let acceptedSample = depositionSample(.moved, x: 40, y: 24)
        try reference.renderer.beginStroke(
            token: referenceToken,
            sample: began,
            style: depositionStyle(
                referenceBrush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try await drainOffMainPreparedFrames(
            reference.renderer,
            minimumFrameCount: 1
        )
        let referenceInstancesBefore = try #require(
            reference.renderer.offMainSurfaceSnapshotForTesting
        ).encodedInstanceCount

        var expectedPrefixDabs: [LogicalDab] = []
        reference.renderer.onLogicalDabsGenerated = {
            expectedPrefixDabs.append($0)
        }
        try reference.renderer.appendStroke(
            token: referenceToken,
            sample: acceptedSample
        )
        try await awaitOffMainPreparedLease(reference.renderer)
        let referenceInstancesAfter = try #require(
            reference.renderer.offMainSurfaceSnapshotForTesting
        ).encodedInstanceCount
        let expectedCoordinator = try #require(
            reference.renderer.compatibilityInkCoordinatorSnapshotForTesting
        )
        #expect(!expectedPrefixDabs.isEmpty)
        #expect(referenceInstancesAfter > referenceInstancesBefore)
        reference.renderer.onLogicalDabsGenerated = nil
        try reference.renderer.cancelStroke(token: referenceToken)

        let capacity = Int(
            referenceInstancesAfter - referenceInstancesBefore
        )
        let constrainedBudget = try depositionFrameBudget(
            maximumAuthoritativeInstances: capacity,
            maximumPendingAuthoritativeInstances: capacity
        )
        let previousBudget = failing.renderer
            .replaceDepositionFrameBudgetForHarness(constrainedBudget)
        try failing.renderer.beginStroke(
            token: failingToken,
            sample: began,
            style: depositionStyle(
                failingBrush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try await drainOffMainPreparedFrames(
            failing.renderer,
            minimumFrameCount: 1
        )
        let canonicalBefore = depositionTextureBytes(
            try failing.renderer.copyCanonicalForHarness()
        )
        var actualDabs: [LogicalDab] = []
        failing.renderer.onLogicalDabsGenerated = { actualDabs.append($0) }

        try failing.renderer.appendStrokeBatch(
            token: failingToken,
            samples: [
                acceptedSample,
                depositionSample(.moved, x: 200, y: 24),
            ]
        )
        try await awaitOffMainPreparedLease(failing.renderer)
        #expect(actualDabs == expectedPrefixDabs)
        #expect(
            failing.renderer.compatibilityInkCoordinatorSnapshotForTesting
                == expectedCoordinator
        )
        _ = try failing.renderer.completeNextPendingInteractiveFrame()
        var batchError: MetalRendererError?
        for _ in 0..<20_000 {
            do {
                try failing.renderer.drainCompletedInteractiveOperations()
            } catch let error as MetalRendererError {
                batchError = error
                break
            }
            await Task.yield()
        }
        #expect(
            batchError
                == .projectedInstanceCapacityExceeded(capacity)
        )
        #expect(actualDabs == expectedPrefixDabs)
        try await awaitOffMainWorkspaceAvailable(failing.renderer)
        #expect(failing.renderer.isIdle)
        #expect(
            depositionTextureBytes(
                try failing.renderer.copyCanonicalForHarness()
            ) == canonicalBefore
        )

        failing.renderer.replaceDepositionFrameBudgetForHarness(
            previousBudget
        )
        failing.renderer.onLogicalDabsGenerated = nil
        let recoveryToken = RendererOperationToken(rawValue: 90_032)
        try failing.renderer.beginStroke(
            token: recoveryToken,
            sample: began,
            style: depositionStyle(
                failingBrush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try failing.renderer.cancelStroke(token: recoveryToken)
        try await awaitOffMainWorkspaceAvailable(failing.renderer)
        #expect(failing.renderer.isIdle)

        let boundedInitial = await failing.renderer
            .offMainSchedulerSnapshotForTesting()
        var boundedErrors: [MetalRendererError] = []
        var boundedCompletions: [RendererOperationCompletion] = []
        failing.renderer.onError = { boundedErrors.append($0) }
        failing.renderer.onOperationCompleted = {
            boundedCompletions.append($0)
        }

        let generationToken = RendererOperationToken(rawValue: 90_033)
        try failing.renderer.beginStroke(
            token: generationToken,
            sample: began,
            style: depositionStyle(
                failingBrush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        try await drainOffMainPreparedFrames(
            failing.renderer,
            minimumFrameCount: 1
        )
        try failing.renderer.appendStroke(
            token: generationToken,
            sample: depositionSample(.moved, x: 8_000, y: 24)
        )
        let generationError = try await awaitOffMainRendererFailure(
            failing.renderer
        )
        #expect(
            generationError == .generatedDabCapacityExceeded(
                TransientStrokeBufferContract.wholeStrokeDabCapacity
            )
        )
        try await awaitOffMainWorkspaceAvailable(failing.renderer)
        let generationBounded = await failing.renderer
            .offMainSchedulerSnapshotForTesting()
        #expect(
            generationBounded.generatedLogicalDabHighWater
                == TransientStrokeBufferContract.wholeStrokeDabCapacity
        )
        #expect(
            generationBounded.generatedProjectionHighWater
                <= previousBudget.maximumPendingAuthoritativeInstances
        )
        #expect(
            generationBounded.generatedLogicalDabStorageCapacity
                == boundedInitial.generatedLogicalDabStorageCapacity
        )
        #expect(
            generationBounded.generatedProjectionStorageCapacity
                == boundedInitial.generatedProjectionStorageCapacity
        )
        #expect(
            generationBounded.projectionStorageAllocationCount
                == boundedInitial.projectionStorageAllocationCount
        )
        #expect(
            depositionTextureBytes(
                try failing.renderer.copyCanonicalForHarness()
            ) == canonicalBefore
        )

        var extremeGenerationErrors: [MetalRendererError] = []
        for (offset, extremeX) in [
            Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude,
        ].enumerated() {
            let extremeGenerationToken = RendererOperationToken(
                rawValue: UInt64(90_034 + offset)
            )
            try failing.renderer.beginStroke(
                token: extremeGenerationToken,
                sample: began,
                style: depositionStyle(
                    failingBrush,
                    compositeMode: .draw,
                    diameter: 12
                )
            )
            try await drainOffMainPreparedFrames(
                failing.renderer,
                minimumFrameCount: 1
            )
            let extremeStartedAt = DispatchTime.now().uptimeNanoseconds
            try failing.renderer.appendStroke(
                token: extremeGenerationToken,
                sample: depositionSample(
                    .moved,
                    x: extremeX,
                    y: 24
                )
            )
            let extremeGenerationError =
                try await awaitOffMainRendererFailure(failing.renderer)
            let extremeElapsedNanoseconds =
                DispatchTime.now().uptimeNanoseconds - extremeStartedAt
            #expect(
                extremeGenerationError == .generatedDabCapacityExceeded(
                    TransientStrokeBufferContract.wholeStrokeDabCapacity
                )
            )
            #expect(extremeElapsedNanoseconds < 2_000_000_000)
            extremeGenerationErrors.append(extremeGenerationError)
            try await awaitOffMainWorkspaceAvailable(failing.renderer)
        }
        let extremeGenerationBounded = await failing.renderer
            .offMainSchedulerSnapshotForTesting()
        #expect(
            extremeGenerationBounded.generatedLogicalDabHighWater
                == TransientStrokeBufferContract.wholeStrokeDabCapacity
        )
        #expect(
            extremeGenerationBounded.generatedLogicalDabStorageCapacity
                == boundedInitial.generatedLogicalDabStorageCapacity
        )
        #expect(
            extremeGenerationBounded.generatedProjectionStorageCapacity
                == boundedInitial.generatedProjectionStorageCapacity
        )
        #expect(
            extremeGenerationBounded.projectionStorageAllocationCount
                == boundedInitial.projectionStorageAllocationCount
        )
        #expect(
            depositionTextureBytes(
                try failing.renderer.copyCanonicalForHarness()
            ) == canonicalBefore
        )

        let projectionToken = RendererOperationToken(rawValue: 90_036)
        try failing.renderer.beginStroke(
            token: projectionToken,
            sample: depositionSample(.began, x: 32, y: 32),
            style: depositionStyle(
                failingBrush,
                compositeMode: .draw,
                diameter: 16_384
            )
        )
        let projectionError = try await awaitOffMainRendererFailure(
            failing.renderer
        )
        #expect(
            projectionError == .projectedInstanceCapacityExceeded(
                previousBudget.maximumPendingAuthoritativeInstances
            )
        )
        try await awaitOffMainWorkspaceAvailable(failing.renderer)
        let projectionBounded = await failing.renderer
            .offMainSchedulerSnapshotForTesting()
        #expect(
            projectionBounded.projectionCellHighWater
                <= previousBudget.maximumPendingAuthoritativeInstances
        )
        #expect(
            projectionBounded.projectionImageHighWater
                <= previousBudget.maximumPendingAuthoritativeInstances
        )
        #expect(
            projectionBounded.projectionFragmentHighWater
                <= previousBudget.maximumPendingAuthoritativeInstances
        )
        #expect(
            projectionBounded.projectionCellStorageCapacity
                == boundedInitial.projectionCellStorageCapacity
        )
        #expect(
            projectionBounded.projectionImageStorageCapacity
                == boundedInitial.projectionImageStorageCapacity
        )
        #expect(
            projectionBounded.projectionFragmentStorageCapacity
                == boundedInitial.projectionFragmentStorageCapacity
        )
        #expect(
            projectionBounded.projectionStorageAllocationCount
                == boundedInitial.projectionStorageAllocationCount
        )

        let extremeProjectionToken = RendererOperationToken(
            rawValue: 90_037
        )
        let extremeProjectionStartedAt = DispatchTime.now().uptimeNanoseconds
        let extremeProjectionError: MetalRendererError
        do {
            try failing.renderer.beginStroke(
                token: extremeProjectionToken,
                sample: depositionSample(.began, x: 32, y: 32),
                style: depositionStyle(
                    failingBrush,
                    compositeMode: .draw,
                    diameter: Float.greatestFiniteMagnitude
                )
            )
            Issue.record("Expected the brush diameter contract to reject")
            return
        } catch let error as MetalRendererError {
            extremeProjectionError = error
        }
        let extremeProjectionElapsedNanoseconds =
            DispatchTime.now().uptimeNanoseconds
                - extremeProjectionStartedAt
        #expect(
            extremeProjectionError == .brushDiameterOutOfRange(
                actual: Float.greatestFiniteMagnitude,
                minimum: failingBrush.program.definition.limits
                    .minimumDiameter,
                maximum: failingBrush.program.definition.limits
                    .maximumDiameter
            )
        )
        #expect(extremeProjectionElapsedNanoseconds < 2_000_000_000)
        #expect(failing.renderer.isIdle)
        let extremeProjectionBounded = await failing.renderer
            .offMainSchedulerSnapshotForTesting()
        #expect(
            extremeProjectionBounded.projectionCellHighWater
                <= previousBudget.maximumPendingAuthoritativeInstances
        )
        #expect(
            extremeProjectionBounded.projectionImageHighWater
                <= previousBudget.maximumPendingAuthoritativeInstances
        )
        #expect(
            extremeProjectionBounded.projectionFragmentHighWater
                <= previousBudget.maximumPendingAuthoritativeInstances
        )
        #expect(
            extremeProjectionBounded.projectionCellStorageCapacity
                == boundedInitial.projectionCellStorageCapacity
        )
        #expect(
            extremeProjectionBounded.projectionImageStorageCapacity
                == boundedInitial.projectionImageStorageCapacity
        )
        #expect(
            extremeProjectionBounded.projectionFragmentStorageCapacity
                == boundedInitial.projectionFragmentStorageCapacity
        )
        #expect(
            extremeProjectionBounded.projectionStorageAllocationCount
                == boundedInitial.projectionStorageAllocationCount
        )
        #expect(
            boundedErrors
                == [generationError]
                    + extremeGenerationErrors
                    + [projectionError]
        )
        #expect(
            boundedCompletions.filter {
                if case .failure = $0 { return true }
                return false
            }.count == 4
        )
        #expect(
            depositionTextureBytes(
                try failing.renderer.copyCanonicalForHarness()
            ) == canonicalBefore
        )
        failing.renderer.onError = nil
        failing.renderer.onOperationCompleted = nil
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
            recipe: BrushRecipe(id: BrushRecipeID(id))
        )
    }

    func compileBrush(recipe: BrushRecipe) async throws -> CompiledBrush {
        let definition = try LegacyBrushRecipeAdapter.definition(
            from: recipe,
            displayName: recipe.id.rawValue
        )
        return try await compileBrush(definition: definition)
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
    let base = try LegacyBrushRecipeAdapter.definition(
        from: BrushRecipe(id: BrushRecipeID(id)),
        displayName: id
    )
    return try BrushDefinition(
        id: base.id,
        schemaVersion: base.schemaVersion,
        metadata: base.metadata,
        capabilities: base.capabilities,
        resources: base.resources,
        coverage: base.coverage,
        placement: base.placement,
        dynamics: base.dynamics,
        color: base.color,
        material: base.material,
        stabilization: base.stabilization,
        taper: base.taper,
        replayMode: base.replayMode,
        replayLimits: base.replayLimits,
        termination: termination,
        seedPolicy: base.seedPolicy,
        limits: base.limits,
        performanceIntent: base.performanceIntent,
        compatibility: base.compatibility
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
    _ renderer: GridRenderer
) async throws {
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if renderer.hasPendingOffMainSurfaceLeaseForTesting {
            _ = try renderer.completeNextPendingInteractiveFrame()
        }
        try renderer.prepareCompiledCommitIfReady()
        if renderer.isIdle {
            return
        }
        if renderer.activeStroke?.pendingRevisions != nil {
            return
        }
        await Task.yield()
    }
    let mailbox = renderer.offMainPreparationMailboxSnapshotForTesting
    let scheduler = await renderer.offMainSchedulerSnapshotForTesting()
    print(
        "OFF_MAIN_COMMIT_TIMEOUT "
            + "mailbox=\(String(describing: mailbox)) "
            + "scheduler=\(String(describing: scheduler)) "
            + "pending_surface=\(renderer.hasPendingOffMainSurfaceLeaseForTesting) "
            + "submitted_surface=\(renderer.hasSubmittedOffMainSurfaceLeaseForTesting)"
    )
    throw MetalRendererError.commandFailed(
        "off-main test commit preparation exceeded its bound"
    )
}

@MainActor
private func prepareOffMainNoOpCompletion(
    _ renderer: GridRenderer
) async throws {
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if renderer.hasPendingOffMainSurfaceLeaseForTesting {
            _ = try renderer.completeNextPendingInteractiveFrame()
        }
        try renderer.prepareCompiledCommitIfReady()
        if renderer.activeStroke == nil {
            return
        }
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "off-main no-op completion exceeded its bound"
    )
}

@MainActor
func drainOffMainPreparedFrames(
    _ renderer: GridRenderer,
    minimumFrameCount: Int
) async throws {
    var completedFrameCount = 0
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if renderer.hasPendingOffMainSurfaceLeaseForTesting {
            _ = try renderer.completeNextPendingInteractiveFrame()
            completedFrameCount += 1
            continue
        }
        if completedFrameCount >= minimumFrameCount,
           let mailbox = renderer
            .offMainPreparationMailboxSnapshotForTesting,
           mailbox.isQuiescent,
           !renderer.hasSubmittedOffMainSurfaceLeaseForTesting
        {
            return
        }
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "off-main test preparation exceeded its bound"
    )
}

@MainActor
private func awaitOffMainPreparedLease(
    _ renderer: GridRenderer
) async throws {
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if renderer.hasPendingOffMainSurfaceLeaseForTesting { return }
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "off-main prepared lease exceeded its bound"
    )
}

@MainActor
func awaitOffMainWorkspaceAvailable(
    _ renderer: GridRenderer
) async throws {
    for _ in 0..<10_000 {
        try renderer.drainCompletedInteractiveOperations()
        if renderer.offMainStrokeWorkspaceIsAvailableForTesting {
            return
        }
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "off-main warmed workspace retirement exceeded its bound"
    )
}

@MainActor
private func awaitOffMainCandidateContinuationResult(
    _ renderer: GridRenderer
) async throws -> (
    mailbox: StrokePreparationMailboxSnapshot,
    scheduler: StrokeFrameSchedulerSnapshot
) {
    for _ in 0..<20_000 {
        if let mailbox = renderer.offMainPreparationMailboxSnapshotForTesting,
           mailbox.pendingResultCount > 0,
           mailbox.awaitingPreparedFrameSubmission
        {
            let scheduler = await renderer
                .offMainSchedulerSnapshotForTesting()
            if scheduler.authoritativeCandidateContinuationPending {
                return (mailbox, scheduler)
            }
        }
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "off-main candidate continuation did not pause at a prepared result"
    )
}

@MainActor
private func awaitOffMainRendererFailure(
    _ renderer: GridRenderer
) async throws -> MetalRendererError {
    for _ in 0..<20_000 {
        do {
            try renderer.drainCompletedInteractiveOperations()
        } catch let error as MetalRendererError {
            return error
        }
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "off-main failure publication exceeded its bound"
    )
}

@MainActor
private func driveOffMainStroke(
    _ renderer: GridRenderer,
    until condition: () -> Bool
) async throws {
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if renderer.hasPendingOffMainSurfaceLeaseForTesting {
            _ = try renderer.completeNextPendingInteractiveFrame()
        }
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
    finite: FiniteSymmetryConfiguration? = nil
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
            pixelSize: PixelSize(width: 64, height: 64),
            finiteConfiguration: finite
        )
    } else {
        try TilingCanvasConfiguration(
            pixelSize: PixelSize(width: 64, height: 64),
            tiling: tiling
        )
    }
    let renderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 64, height: 64),
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
) throws -> [UInt8] {
    let texture = try renderer.copyCanonicalForHarness()
    let bytes = depositionTextureBytes(texture)
    let offset = (32 * texture.width + 32) * 4
    return Array(bytes[offset..<(offset + 4)])
}

private func productionMethod(
    _ signature: String,
    in source: String
) throws -> Substring {
    let signatureRange = try #require(source.range(of: signature))
    let openingBrace = try #require(
        source[signatureRange.upperBound...].firstIndex(of: "{")
    )
    var depth = 0
    var cursor = openingBrace
    while cursor < source.endIndex {
        switch source[cursor] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return source[signatureRange.lowerBound...cursor]
            }
        default:
            break
        }
        cursor = source.index(after: cursor)
    }
    throw ProductionSourceBoundaryError.unclosedMethod(signature)
}

private enum ProductionSourceBoundaryError: Error {
    case unclosedMethod(String)
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
) throws {
    try renderer.beginStroke(
        token: token,
        sample: depositionSample(.began),
        style: depositionStyle(brush, compositeMode: .draw)
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: depositionSample(.ended, x: 40),
        maximumRetainedBytes: 1_000_000
    )
    _ = try renderer.finishCommitForHarness()
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

@MainActor
private func forgedWetBrush(
    from supported: CompiledBrush
) throws -> CompiledBrush {
    let definition = supported.program.definition
    let material = BrushMaterialDefinition(
        accumulation: definition.material.accumulation,
        interaction: .wetMix,
        edgeTreatment: .wetConcentration,
        strength: definition.material.strength,
        wetness: 1,
        bleedRadius: max(1, definition.material.bleedRadius),
        softenPasses: definition.material.softenPasses,
        accumulationLimit: definition.material.accumulationLimit,
        interactionParameters: BrushInteractionDefinition(
            pickup: 0.5,
            pull: 0.5,
            dilution: 0.5,
            charge: 0.5,
            persistence: 0.5,
            dirtyHaloRadius: 1
        )
    )
    let wetDefinition = try BrushDefinition(
        id: definition.id,
        schemaVersion: definition.schemaVersion,
        metadata: definition.metadata,
        capabilities: [
            BrushCapabilityDeclaration(
                identifier: BrushCapability.wetMix.rawValue,
                required: true
            ),
        ],
        resources: definition.resources,
        coverage: definition.coverage,
        placement: definition.placement,
        dynamics: definition.dynamics,
        color: definition.color,
        material: material,
        stabilization: definition.stabilization,
        taper: definition.taper,
        replayMode: definition.replayMode,
        replayLimits: definition.replayLimits,
        seedPolicy: definition.seedPolicy,
        limits: definition.limits,
        performanceIntent: definition.performanceIntent,
        compatibility: definition.compatibility
    )
    let program = try BrushProgramCompiler.compile(wetDefinition)
    return CompiledBrush(
        program: program,
        renderIdentity: supported.renderIdentity,
        pipelineKey: supported.pipelineKey,
        uniformTemplate: BrushUniformTemplate(
            placement: wetDefinition.placement,
            coverage: wetDefinition.coverage,
            color: wetDefinition.color,
            material: wetDefinition.material
        ),
        textures: supported.textures,
        depositionPipeline: supported.depositionPipeline,
        depositionMaterial: supported.depositionMaterial,
        residentByteCount: supported.residentByteCount,
        report: supported.report,
        diagnostics: supported.diagnostics,
        cacheKeys: supported.cacheKeys
    )
}
