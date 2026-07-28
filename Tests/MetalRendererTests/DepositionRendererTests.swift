import BrushFormat
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Compiled deposition renderer")
struct DepositionRendererTests {
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

        let records = setup.renderer.harnessScheduledAuthoritativeRecords
        #expect(!records.isEmpty)
        #expect(setup.renderer.liveStroke.pending.isEmpty)
        #expect(
            records.allSatisfy {
                $0.instance.metadata.w == UInt32(DepositionABI.version)
            }
        )
        #expect(
            records.allSatisfy {
                setup.renderer.harnessCompiledIsometryOrdinals.contains(
                    UInt8(truncatingIfNeeded: $0.instance.identity.z)
                )
            }
        )
        try setup.renderer.cancelStroke(token: token)
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
        let authoritative =
            setup.renderer.harnessScheduledAuthoritativeRecords

        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 36)
        )
        let firstPrediction =
            setup.renderer.harnessScheduledPredictedRecords
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 52)
        )
        let replacement =
            setup.renderer.harnessScheduledPredictedRecords

        #expect(
            setup.renderer.harnessScheduledAuthoritativeRecords
                == authoritative
        )
        #expect(!firstPrediction.isEmpty)
        #expect(!replacement.isEmpty)
        #expect(replacement != firstPrediction)
        try setup.renderer.cancelStroke(token: token)
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

        _ = try setup.renderer.flushPendingLiveForHarness()
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

        #expect(setup.renderer.activeStroke?.commitRequested == true)
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

        #expect(setup.renderer.activeStroke?.commitRequested == true)
        #expect(setup.renderer.activeStroke?.pendingRevisions == nil)
        _ = try setup.renderer.finishCommitForHarness()
        #expect(setup.renderer.isIdle)
    }

    @Test
    @MainActor
    func nativeReservationFailureIsAtomicAndRendererRecovers()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.reservation")
        try setup.renderer.activateDrawBrush(brush)
        let before = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        let leases = try #require(
            setup.renderer.instancePool.acquire(
                count: GridCanvasContract.inFlightBufferCount
            )
        )
        let failedToken = RendererOperationToken(rawValue: 12)
        try setup.renderer.beginStroke(
            token: failedToken,
            sample: depositionSample(.began),
            style: depositionStyle(brush, compositeMode: .draw)
        )

        #expect(throws: MetalRendererError.instanceBufferAllocationFailed) {
            _ = try setup.renderer.flushPendingLiveForHarness()
        }

        #expect(setup.renderer.isIdle)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == before
        )
        for lease in leases {
            setup.renderer.instancePool.abandon(lease)
        }

        try commitNativeStroke(
            renderer: setup.renderer,
            brush: brush,
            token: RendererOperationToken(rawValue: 13)
        )
        #expect(setup.renderer.isIdle)
    }

    @Test
    @MainActor
    func missingDepositionEncoderFailsWithoutCanonicalMutation()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.no-encoder")
        try setup.renderer.activateDrawBrush(brush)
        let before = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        let token = RendererOperationToken(rawValue: 14)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let removedEncoder = try #require(
            setup.renderer.removeDepositionEncoderForHarness()
        )

        #expect(throws: MetalRendererError.depositionEncoderUnavailable) {
            _ = try setup.renderer.flushPendingLiveForHarness()
        }

        #expect(setup.renderer.isIdle)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == before
        )
        #expect(setup.renderer.harnessRasterRevisionResidentBytes == 0)

        setup.renderer.restoreDepositionEncoderForHarness(removedEncoder)
        try commitNativeStroke(
            renderer: setup.renderer,
            brush: brush,
            token: RendererOperationToken(rawValue: 15)
        )
        #expect(setup.renderer.isIdle)
    }

    @Test
    @MainActor
    func nativeGPUFailureClearsTransientStateAndNextStrokeSucceeds()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.gpu-failure")
        try setup.renderer.activateDrawBrush(brush)
        let before = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        let failedToken = RendererOperationToken(rawValue: 15)
        try setup.renderer.beginStroke(
            token: failedToken,
            sample: depositionSample(.began),
            style: depositionStyle(brush, compositeMode: .draw)
        )

        #expect(
            throws: MetalRendererError.commandFailed(
                "injected harness command-buffer failure"
            )
        ) {
            _ = try setup.renderer.flushPendingLiveForHarness(
                forceFailure: true
            )
        }

        #expect(setup.renderer.isIdle)
        #expect(setup.renderer.harnessReservedInstanceBufferCount == 0)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == before
        )

        try commitNativeStroke(
            renderer: setup.renderer,
            brush: brush,
            token: RendererOperationToken(rawValue: 16)
        )
        #expect(setup.renderer.isIdle)
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

    @Test
    @MainActor
    func nativeProjectedInstanceOverflowIsAtomicAndRendererRecovers()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let constrainedRecipe = try BrushRecipe(
            id: BrushRecipeID("brush.projected-overflow"),
            replayMode: .replayTail,
            replayLimits: BrushReplayLimits(
                maximumSamples: 16,
                maximumDabs: 16,
                maximumProjectedInstances: 1
            )
        )
        let constrained = try await setup.compileBrush(
            recipe: constrainedRecipe
        )
        try setup.renderer.activateDrawBrush(constrained)
        try setup.renderer.applyTiling(.squareRotation)
        let before = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )

        #expect(
            throws: MetalRendererError.projectedInstanceCapacityExceeded(1)
        ) {
            try setup.renderer.beginStroke(
                token: RendererOperationToken(rawValue: 19),
                sample: depositionSample(.began, x: 16, y: 16),
                style: depositionStyle(
                    constrained,
                    compositeMode: .draw
                )
            )
        }

        #expect(setup.renderer.isIdle)
        #expect(setup.renderer.harnessRasterRevisionResidentBytes == 0)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == before
        )

        let recovery = try await setup.compileBrush(
            id: "brush.projected-overflow-recovery"
        )
        try setup.renderer.activateDrawBrush(recovery)
        try commitNativeStroke(
            renderer: setup.renderer,
            brush: recovery,
            token: RendererOperationToken(rawValue: 20)
        )
    }

    @Test
    @MainActor
    func nativeSchedulerOverflowIsAtomicAndRendererRecovers()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.scheduler-overflow")
        try setup.renderer.activateDrawBrush(brush)
        try setup.renderer.applyTiling(.squareRotation)
        let previousBudget = setup.renderer
            .replaceDepositionFrameBudgetForHarness(
                try depositionFrameBudget(
                    maximumAuthoritativeInstances: 1,
                    maximumPendingAuthoritativeInstances: 1
                )
            )
        let before = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )

        #expect(
            throws: MetalRendererError.projectedInstanceCapacityExceeded(1)
        ) {
            try setup.renderer.beginStroke(
                token: RendererOperationToken(rawValue: 21),
                sample: depositionSample(.began, x: 16, y: 16),
                style: depositionStyle(brush, compositeMode: .draw)
            )
        }

        #expect(setup.renderer.isIdle)
        #expect(setup.renderer.harnessRasterRevisionResidentBytes == 0)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == before
        )

        setup.renderer.replaceDepositionFrameBudgetForHarness(previousBudget)
        try commitNativeStroke(
            renderer: setup.renderer,
            brush: brush,
            token: RendererOperationToken(rawValue: 22)
        )
    }

    @Test
    @MainActor
    func nativeCommandBufferAbsenceIsAtomicAndRendererRecovers()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.no-command-buffer")
        try setup.renderer.activateDrawBrush(brush)
        let before = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        try setup.renderer.beginStroke(
            token: RendererOperationToken(rawValue: 23),
            sample: depositionSample(.began),
            style: depositionStyle(brush, compositeMode: .draw)
        )

        #expect(throws: MetalRendererError.commandBufferUnavailable) {
            _ = try setup.renderer.flushPendingLiveForHarness(
                forceCommandBufferUnavailable: true
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
            token: RendererOperationToken(rawValue: 24)
        )
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

    @Test
    @MainActor
    func nativeStaleReplayCompletionCannotReplaceNewerPrediction()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.stale-replay")
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 27)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try setup.renderer.flushPendingLiveForHarness()

        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 30)
        )
        let staleEpoch = setup.renderer.replayStroke.renderEpoch
        setup.renderer.deferNextFrameOutcomeForHarness()
        _ = try setup.renderer.flushPendingLiveForHarness()

        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 38)
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 54)
        )
        let newestEpoch = setup.renderer.replayStroke.renderEpoch
        #expect(newestEpoch > staleEpoch)
        _ = try setup.renderer.flushPendingLiveForHarness()
        _ = try setup.renderer.flushPendingLiveForHarness()
        #expect(setup.renderer.replayTile.visibleEpoch == newestEpoch)

        setup.renderer.releaseDeferredFrameOutcomesForHarness()
        try setup.renderer.drainNextCompletedOperationForHarness()

        #expect(setup.renderer.replayTile.visibleEpoch == newestEpoch)
        #expect(setup.renderer.hasActiveStroke)
        try setup.renderer.cancelStroke(token: token)
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
            baselineDabs.append(contentsOf: $0.filter { !$0.isPredicted })
        }
        predicted.renderer.onLogicalDabsGenerated = {
            predictedDabs.append(contentsOf: $0.filter { !$0.isPredicted })
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
        while !setup.renderer.harnessScheduledAuthoritativeRecords.isEmpty {
            _ = try setup.renderer.flushPendingLiveForHarness()
        }
        _ = try setup.renderer.flushPendingLiveForHarness()
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
}

@MainActor
private struct DepositionRendererSetup {
    let renderer: GridRenderer
    let compiler: BrushCompiler

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
        return try await compiler.compileAndActivate(
            package: BrushPackage(
                manifest: BrushPackageManifest(resources: []),
                definition: definition,
                resourceData: [:]
            )
        )
    }
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
private func makeDepositionRendererSetup()
    throws -> DepositionRendererSetup?
{
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue()
    else {
        return nil
    }
    let library = try depositionRendererLibrary(device: device)
    let renderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 64, height: 64),
        configuration: TilingCanvasConfiguration(
            pixelSize: PixelSize(width: 64, height: 64),
            tiling: .grid
        )
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
    return DepositionRendererSetup(renderer: renderer, compiler: compiler)
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

private func depositionSample(
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

private func depositionPredictedSample(x: Float) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: 0.5,
        timestamp: TimeInterval(x),
        phase: .moved,
        source: .mouse,
        kind: .predicted
    )
}

private func depositionTextureBytes(
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
private func depositionStyle(
    _ brush: CompiledBrush,
    compositeMode: StrokeCompositeMode
) -> StrokeRenderStyle {
    StrokeRenderStyle(
        color: .black,
        diameter: 20,
        compositeMode: compositeMode,
        eraserStrength: 1,
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
