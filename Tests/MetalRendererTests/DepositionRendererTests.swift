import BrushFormat
import EditorCore
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Compiled deposition renderer")
struct DepositionRendererTests {
    @Test
    @MainActor
    func boundedCorrectionRejectsEveryPointerUpLimitBeforeMutation()
        async throws
    {
        enum ExpectedLimit {
            case samples
            case worldLength
            case dabs
        }
        let cases: [(
            BrushTerminationDefinition,
            ExpectedLimit,
            endX: Float
        )] = [
            (
                .boundedCorrection(
                    maximumSamples: 1,
                    maximumWorldLength: 1_000,
                    maximumDabs: 2_048
                ),
                .samples,
                endX: 40
            ),
            (
                .boundedCorrection(
                    maximumSamples: 256,
                    maximumWorldLength: 1,
                    maximumDabs: 2_048
                ),
                .worldLength,
                endX: 40
            ),
            (
                .boundedCorrection(
                    maximumSamples: 256,
                    maximumWorldLength: 1_000,
                    maximumDabs: 1
                ),
                .dabs,
                endX: 14
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            guard let setup = try makeDepositionRendererSetup() else { return }
            let definition = try nativeTerminationDefinition(
                id: "brush.termination-limit-\(index)",
                termination: testCase.0
            )
            let brush = try await setup.compileBrush(definition: definition)
            try setup.renderer.activateDrawBrush(brush)
            let before = depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            )
            let token = RendererOperationToken(
                rawValue: UInt64(8_100 + index)
            )
            try setup.renderer.beginStroke(
                token: token,
                sample: depositionEstimatedSample(
                    .began,
                    x: 12,
                    index: 8_100 + index,
                    expecting: [.pressure]
                ),
                style: depositionStyle(brush, compositeMode: .draw)
            )
            let bufferBefore = try #require(
                setup.renderer.transientStrokeBuffer
            )
            let arenaBefore =
                setup.renderer.harnessTransientDabArenaSnapshot
            let authoritativeBefore =
                setup.renderer.harnessScheduledAuthoritativeRecords
            let predictedBefore =
                setup.renderer.harnessScheduledPredictedRecords

            var rejected = false
            do {
                try setup.renderer.finishStrokeTransient(
                    token: token,
                    sample: depositionSample(.ended, x: testCase.endX)
                )
                Issue.record(
                    "Pointer-up correction exceeded its declared limit"
                )
            } catch let error as BrushTerminationEvaluationError {
                rejected = true
                switch (testCase.1, error) {
                case let (.samples, .maximumSamplesExceeded(actual, maximum)):
                    #expect(actual > maximum)
                case let (
                    .worldLength,
                    .maximumWorldLengthExceeded(actual, maximum)
                ):
                    #expect(actual > maximum)
                case let (.dabs, .maximumDabsExceeded(actual, maximum)):
                    #expect(actual > maximum)
                default:
                    Issue.record("Wrong pointer-up limit error: \(error)")
                }
            }

            if rejected {
                #expect(setup.renderer.transientStrokeBuffer == bufferBefore)
                #expect(
                    setup.renderer.harnessTransientDabArenaSnapshot
                        == arenaBefore
                )
                #expect(
                    setup.renderer.harnessScheduledAuthoritativeRecords
                        == authoritativeBefore
                )
                #expect(
                    setup.renderer.harnessScheduledPredictedRecords
                        == predictedBefore
                )
                try setup.renderer.cancelStroke(token: token)
                #expect(setup.renderer.isIdle)
                #expect(
                    depositionTextureBytes(
                        try setup.renderer.copyCanonicalForHarness()
                    ) == before
                )
            }
        }
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
        #expect(renderer.contains("samples: CollectionOfOne(sample)"))
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
            harness.contains(
                "try completePendingInteractiveStroke(\n"
                    + "            forceCommitFailure:"
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
        let queued = setup.renderer.brushLabDiagnosticSnapshot.deposition
        #expect(queued.authoritativePending > 0)
        #expect(
            queued.authoritativeHighWater
                >= queued.authoritativePending
        )

        try setup.renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 48, y: 48),
            maximumRetainedBytes: 1_000_000
        )
        let completion =
            try setup.renderer.completePendingInteractiveStroke()
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
        #expect(diagnostics.bufferLeaseHighWater > 0)
        #expect(diagnostics.currentBufferLeaseCount == 0)
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

    @Test
    @MainActor
    func laterSmallStrokeResetsPoolHighWaterButLifetimeStaysMonotonic()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(id: "brush.pool-scopes")
        try setup.renderer.activateDrawBrush(brush)
        let held = try #require(
            setup.renderer.instancePool.acquire(count: 2)
        )

        try commitNativeStroke(
            renderer: setup.renderer,
            brush: brush,
            token: RendererOperationToken(rawValue: 9_101)
        )
        let large =
            setup.renderer.brushLabDiagnosticSnapshot.deposition
        #expect(large.strokeBufferLeaseHighWater == 3)
        #expect(large.lifetimeBufferLeaseHighWater == 3)
        for lease in held {
            setup.renderer.instancePool.abandon(lease)
        }

        try commitNativeStroke(
            renderer: setup.renderer,
            brush: brush,
            token: RendererOperationToken(rawValue: 9_102)
        )
        let small =
            setup.renderer.brushLabDiagnosticSnapshot.deposition
        #expect(small.strokeBufferLeaseHighWater == 1)
        #expect(small.lifetimeBufferLeaseHighWater == 3)
        #expect(small.currentBufferLeaseCount == 0)
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
    func predictionSettlementPreflightFailureIsAtomicAndRetrySucceeds()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.prediction-preflight-atomic"),
            replayMode: .replayTail,
            replayLimits: BrushReplayLimits(
                maximumSamples: 1,
                maximumDabs: 16,
                maximumProjectedInstances: 16
            )
        )
        let brush = try await setup.compileBrush(recipe: recipe)
        try setup.renderer.activateDrawBrush(brush)
        try setup.renderer.applyTiling(.squareRotation)
        let token = RendererOperationToken(rawValue: 8_001)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let bufferBefore = try #require(
            setup.renderer.transientStrokeBuffer
        )
        let arenaBefore =
            setup.renderer.harnessTransientDabArenaSnapshot
        let constrainedBudget = try depositionFrameBudget(
            maximumAuthoritativeInstances: 1,
            maximumPendingAuthoritativeInstances: 1
        )
        let previousBudget = setup.renderer
            .replaceDepositionFrameBudgetForHarness(constrainedBudget)
        let previousScheduler = try #require(
            setup.renderer.replaceActiveStrokeSchedulerForHarness(
                constrainedBudget
            )
        )
        let authoritativeBefore =
            setup.renderer.harnessScheduledAuthoritativeRecords
        let predictedBefore =
            setup.renderer.harnessScheduledPredictedRecords

        #expect(
            throws: MetalRendererError
                .projectedInstanceCapacityExceeded(1)
        ) {
            try setup.renderer.appendStroke(
                token: token,
                sample: depositionPredictedSample(x: 16)
            )
        }

        #expect(setup.renderer.transientStrokeBuffer == bufferBefore)
        #expect(
            setup.renderer.harnessTransientDabArenaSnapshot
                == arenaBefore
        )
        #expect(
            setup.renderer.harnessScheduledAuthoritativeRecords
                == authoritativeBefore
        )
        #expect(
            setup.renderer.harnessScheduledPredictedRecords
                == predictedBefore
        )

        setup.renderer.replaceDepositionFrameBudgetForHarness(
            previousBudget
        )
        setup.renderer.restoreActiveStrokeSchedulerForHarness(
            previousScheduler
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 16)
        )
        #expect(
            setup.renderer.transientStrokeBuffer?.predictedSampleCount == 1
        )
        #expect(
            !setup.renderer.harnessScheduledPredictedRecords.isEmpty
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func estimatedSettlementPreflightFailureIsAtomicAndRetrySucceeds()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.estimated-preflight-atomic"),
            replayMode: .appendOnly
        )
        let brush = try await setup.compileBrush(recipe: recipe)
        try setup.renderer.activateDrawBrush(brush)
        try setup.renderer.applyTiling(.squareRotation)
        let token = RendererOperationToken(rawValue: 8_002)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionEstimatedSample(
                .began,
                x: 12,
                index: 61,
                expecting: [.pressure]
            ),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let bufferBefore = try #require(
            setup.renderer.transientStrokeBuffer
        )
        let arenaBefore =
            setup.renderer.harnessTransientDabArenaSnapshot
        let update = depositionEstimatedUpdateSample(
            x: 13,
            index: 61
        )
        let constrainedBudget = try depositionFrameBudget(
            maximumAuthoritativeInstances: 1,
            maximumPendingAuthoritativeInstances: 1
        )
        let previousBudget = setup.renderer
            .replaceDepositionFrameBudgetForHarness(constrainedBudget)
        let previousScheduler = try #require(
            setup.renderer.replaceActiveStrokeSchedulerForHarness(
                constrainedBudget
            )
        )
        let authoritativeBefore =
            setup.renderer.harnessScheduledAuthoritativeRecords
        let predictedBefore =
            setup.renderer.harnessScheduledPredictedRecords

        #expect(
            throws: MetalRendererError
                .projectedInstanceCapacityExceeded(1)
        ) {
            try setup.renderer.applyEstimatedStrokeUpdate(
                token: token,
                sample: update
            )
        }

        #expect(setup.renderer.transientStrokeBuffer == bufferBefore)
        #expect(
            setup.renderer.harnessTransientDabArenaSnapshot
                == arenaBefore
        )
        #expect(
            setup.renderer.harnessScheduledAuthoritativeRecords
                == authoritativeBefore
        )
        #expect(
            setup.renderer.harnessScheduledPredictedRecords
                == predictedBefore
        )

        setup.renderer.replaceDepositionFrameBudgetForHarness(
            previousBudget
        )
        setup.renderer.restoreActiveStrokeSchedulerForHarness(
            previousScheduler
        )
        try setup.renderer.applyEstimatedStrokeUpdate(
            token: token,
            sample: update
        )
        #expect(
            setup.renderer.transientStrokeBuffer?.actualSampleCount == 0
        )
        #expect(
            !setup.renderer.harnessScheduledAuthoritativeRecords.isEmpty
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func predictionReplayPreflightFailureIsAtomicAndRetrySucceeds()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.prediction-replay-atomic"),
            replayMode: .replayTail,
            replayLimits: BrushReplayLimits(
                maximumSamples: 16,
                maximumDabs: 64,
                maximumProjectedInstances: 64
            )
        )
        let brush = try await setup.compileBrush(recipe: recipe)
        try setup.renderer.activateDrawBrush(brush)
        try setup.renderer.applyTiling(.squareRotation)
        let token = RendererOperationToken(rawValue: 8_003)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let bufferBefore = try #require(
            setup.renderer.transientStrokeBuffer
        )
        let arenaBefore =
            setup.renderer.harnessTransientDabArenaSnapshot
        let constrainedBudget = try depositionFrameBudget(
            maximumAuthoritativeInstances: 1,
            maximumPredictedInstances: 1,
            maximumPendingAuthoritativeInstances: 1,
            maximumPendingPredictedInstances: 1
        )
        let previousScheduler = try #require(
            setup.renderer.replaceActiveStrokeSchedulerForHarness(
                constrainedBudget
            )
        )
        let authoritativeBefore =
            setup.renderer.harnessScheduledAuthoritativeRecords
        let predictedBefore =
            setup.renderer.harnessScheduledPredictedRecords

        #expect(
            throws: MetalRendererError
                .projectedInstanceCapacityExceeded(1)
        ) {
            try setup.renderer.appendStroke(
                token: token,
                sample: depositionPredictedSample(x: 16)
            )
        }
        #expect(setup.renderer.transientStrokeBuffer == bufferBefore)
        #expect(
            setup.renderer.harnessTransientDabArenaSnapshot == arenaBefore
        )
        #expect(
            setup.renderer.harnessScheduledAuthoritativeRecords
                == authoritativeBefore
        )
        #expect(
            setup.renderer.harnessScheduledPredictedRecords
                == predictedBefore
        )

        setup.renderer.restoreActiveStrokeSchedulerForHarness(
            previousScheduler
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 16)
        )
        #expect(
            setup.renderer.transientStrokeBuffer?.predictedSampleCount == 1
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func estimatedReplayPreflightFailureIsAtomicAndRetrySucceeds()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.estimated-replay-atomic"),
            replayMode: .replayTail,
            replayLimits: BrushReplayLimits(
                maximumSamples: 16,
                maximumDabs: 64,
                maximumProjectedInstances: 64
            )
        )
        let brush = try await setup.compileBrush(recipe: recipe)
        try setup.renderer.activateDrawBrush(brush)
        try setup.renderer.applyTiling(.squareRotation)
        let token = RendererOperationToken(rawValue: 8_004)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionEstimatedSample(
                .began,
                x: 12,
                index: 62,
                expecting: [.pressure]
            ),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let bufferBefore = try #require(
            setup.renderer.transientStrokeBuffer
        )
        let arenaBefore =
            setup.renderer.harnessTransientDabArenaSnapshot
        let constrainedBudget = try depositionFrameBudget(
            maximumAuthoritativeInstances: 1,
            maximumPredictedInstances: 1,
            maximumPendingAuthoritativeInstances: 1,
            maximumPendingPredictedInstances: 1
        )
        let previousScheduler = try #require(
            setup.renderer.replaceActiveStrokeSchedulerForHarness(
                constrainedBudget
            )
        )

        #expect(
            throws: MetalRendererError
                .projectedInstanceCapacityExceeded(1)
        ) {
            try setup.renderer.applyEstimatedStrokeUpdate(
                token: token,
                sample: depositionEstimatedUpdateSample(
                    x: 13,
                    index: 62
                )
            )
        }
        #expect(setup.renderer.transientStrokeBuffer == bufferBefore)
        #expect(
            setup.renderer.harnessTransientDabArenaSnapshot == arenaBefore
        )

        setup.renderer.restoreActiveStrokeSchedulerForHarness(
            previousScheduler
        )
        try setup.renderer.applyEstimatedStrokeUpdate(
            token: token,
            sample: depositionEstimatedUpdateSample(
                x: 13,
                index: 62
            )
        )
        #expect(
            setup.renderer.transientStrokeBuffer?.actualSampleCount == 1
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func authoritativeReplayPreflightFailureIsAtomicAndRetrySucceeds()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.actual-replay-atomic"),
            replayMode: .replayTail,
            replayLimits: BrushReplayLimits(
                maximumSamples: 16,
                maximumDabs: 64,
                maximumProjectedInstances: 64
            )
        )
        let brush = try await setup.compileBrush(recipe: recipe)
        try setup.renderer.activateDrawBrush(brush)
        try setup.renderer.applyTiling(.squareRotation)
        let token = RendererOperationToken(rawValue: 8_005)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let bufferBefore = try #require(
            setup.renderer.transientStrokeBuffer
        )
        let arenaBefore =
            setup.renderer.harnessTransientDabArenaSnapshot
        let constrainedBudget = try depositionFrameBudget(
            maximumAuthoritativeInstances: 1,
            maximumPredictedInstances: 1,
            maximumPendingAuthoritativeInstances: 1,
            maximumPendingPredictedInstances: 1
        )
        let previousScheduler = try #require(
            setup.renderer.replaceActiveStrokeSchedulerForHarness(
                constrainedBudget
            )
        )

        #expect(
            throws: MetalRendererError
                .projectedInstanceCapacityExceeded(1)
        ) {
            try setup.renderer.appendStroke(
                token: token,
                sample: depositionSample(.moved, x: 16)
            )
        }
        #expect(setup.renderer.transientStrokeBuffer == bufferBefore)
        #expect(
            setup.renderer.harnessTransientDabArenaSnapshot == arenaBefore
        )

        setup.renderer.restoreActiveStrokeSchedulerForHarness(
            previousScheduler
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 16)
        )
        #expect(
            setup.renderer.transientStrokeBuffer?.actualSampleCount == 2
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func finishReplayPreflightFailureIsAtomicAndRetrySucceeds()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.finish-replay-atomic"),
            replayMode: .replayTail,
            replayLimits: BrushReplayLimits(
                maximumSamples: 16,
                maximumDabs: 64,
                maximumProjectedInstances: 64
            )
        )
        let brush = try await setup.compileBrush(recipe: recipe)
        try setup.renderer.activateDrawBrush(brush)
        try setup.renderer.applyTiling(.squareRotation)
        let token = RendererOperationToken(rawValue: 8_006)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let bufferBefore = try #require(
            setup.renderer.transientStrokeBuffer
        )
        let arenaBefore =
            setup.renderer.harnessTransientDabArenaSnapshot
        let constrainedBudget = try depositionFrameBudget(
            maximumAuthoritativeInstances: 1,
            maximumPredictedInstances: 1,
            maximumPendingAuthoritativeInstances: 1,
            maximumPendingPredictedInstances: 1
        )
        let previousScheduler = try #require(
            setup.renderer.replaceActiveStrokeSchedulerForHarness(
                constrainedBudget
            )
        )

        #expect(
            throws: MetalRendererError
                .projectedInstanceCapacityExceeded(1)
        ) {
            try setup.renderer.finishStrokeTransient(
                token: token,
                sample: depositionSample(.ended, x: 16)
            )
        }
        #expect(setup.renderer.transientStrokeBuffer == bufferBefore)
        #expect(
            setup.renderer.harnessTransientDabArenaSnapshot == arenaBefore
        )

        setup.renderer.restoreActiveStrokeSchedulerForHarness(
            previousScheduler
        )
        try setup.renderer.finishStrokeTransient(
            token: token,
            sample: depositionSample(.ended, x: 16)
        )
        #expect(
            setup.renderer.transientStrokeBuffer?.actualSampleCount == 2
        )
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
        let scheduled = try #require(
            setup.renderer.harnessScheduledAuthoritativeRecords.first
        )
        #expect(abs(scheduled.instance.premultipliedColor.w - 1) < 0.000_1)

        _ = try setup.renderer.flushPendingLiveForHarness()
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

        try setup.renderer.drainCompletedOperationsForHarness()
        #expect(completions.count == 1)
        #expect(setup.renderer.harnessRevision == initialRevision.advanced())
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
            setup.renderer.activeStroke?.scheduler?.authoritativeIsDrained
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
    func nativeInputAndReplayPathsAllocateNothingAfterWarmup()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            recipe: BrushRecipe(
                id: BrushRecipeID("brush.input-path-storage"),
                replayMode: .replayTail,
                replayLimits: BrushRecipePolicy.replayTailLimits
            )
        )
        try setup.renderer.activateDrawBrush(brush)
        try setup.renderer.applyTiling(.squareRotation)
        let token = RendererOperationToken(rawValue: 39)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 0),
            style: depositionStyle(brush, compositeMode: .draw)
        )

        for index in 1...128 {
            try setup.renderer.appendStroke(
                token: token,
                sample: depositionSample(
                    .moved,
                    x: Float(index % 96) * 0.5
                )
            )
            while !setup.renderer.harnessScheduledAuthoritativeRecords.isEmpty
                || setup.renderer.activeStroke?.scheduler?.predictedCount != 0
            {
                _ = try setup.renderer.flushPendingLiveForHarness()
            }
        }
        setup.renderer.armInputPathStorageAuditForHarness()

        for index in 129...640 {
            try setup.renderer.appendStroke(
                token: token,
                sample: depositionSample(
                    .moved,
                    x: Float(index % 96) * 0.5
                )
            )
            if index.isMultiple(of: 16) {
                try setup.renderer.appendStroke(
                    token: token,
                    sample: depositionPredictedSample(
                        x: Float((index + 1) % 96) * 0.5
                    )
                )
            }
            while !setup.renderer.harnessScheduledAuthoritativeRecords.isEmpty
                || setup.renderer.activeStroke?.scheduler?.predictedCount != 0
            {
                _ = try setup.renderer.flushPendingLiveForHarness()
            }
        }

        let storage = setup.renderer.inputPathStorageDiagnosticSnapshot
        #expect(storage.isArmed)
        #expect(storage.allocationEventCountAfterWarmup == 0)
        #expect(storage.generatedDabCapacityHighWater > 0)
        #expect(storage.tilingImageCapacityHighWater > 0)
        #expect(storage.tilingCandidateCapacityHighWater > 0)
        #expect(storage.projectionFragmentCapacityHighWater > 0)
        #expect(storage.schedulerRecordCapacityHighWater > 0)
        #expect(storage.replayRecordCapacityHighWater > 0)
        #expect(storage.auditedEventCount >= 512)
        try setup.renderer.cancelStroke(token: token)
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
        while !setup.renderer.harnessScheduledAuthoritativeRecords.isEmpty {
            _ = try setup.renderer.flushPendingLiveForHarness()
        }
        _ = try setup.renderer.flushPendingLiveForHarness()
        _ = try setup.renderer.submitCommitForHarness()
        let provisionalBytes =
            setup.renderer.harnessRasterRevisionResidentBytes

        try setup.renderer.submitDisplayOnlyForHarness(forceFailure: true)
        setup.renderer.prioritizeLatestFrameOutcomeForHarness()
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

        try setup.renderer.drainCompletedOperationsForHarness()
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
    func nativeAppendOnlyEstimatedSuffixFallsBackVisibleAndCommits()
        async throws
    {
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
        #expect(
            setup.renderer.transientStrokeBuffer?.actualSampleCount == 1
        )
        #expect(
            setup.renderer.activeStroke?.scheduler?.predictedCount ?? 0 > 0
        )

        try setup.renderer.finishStrokeTransient(
            token: token,
            sample: depositionSample(.ended, x: 44)
        )
        #expect(
            setup.renderer.transientStrokeBuffer?.actualSampleCount == 2
        )
        #expect(
            setup.renderer.activeStroke?.scheduler?.predictedCount ?? 0 > 0
        )
        try setup.renderer.commitFinishedStroke(
            token: token,
            maximumRetainedBytes: 1_000_000
        )
        _ = try setup.renderer.finishCommitForHarness()
        #expect(setup.renderer.isIdle)
        #expect(setup.renderer.harnessRevision.rawValue == 1)
    }

    @Test
    @MainActor
    func nativeReplayPromotionWaitsForCompleteAtomicUploadPreflight()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.atomic-replay-preflight"),
            replayMode: .replayTail,
            replayLimits: BrushRecipePolicy.replayTailLimits
        )
        let brush = try await setup.compileBrush(recipe: recipe)
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 42)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 16),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try setup.renderer.flushPendingLiveForHarness()
        let priorVisibleEpoch = setup.renderer.replayTile.visibleEpoch

        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 48)
        )

        let latestEpoch = setup.renderer.replayStroke.renderEpoch
        #expect(latestEpoch > priorVisibleEpoch)
        let predictedBefore =
            setup.renderer.activeStroke?.scheduler?.predictedCount ?? 0
        #expect(predictedBefore > 0)
        #expect(setup.renderer.needsReplayClear)

        let held = try #require(
            setup.renderer.instancePool.acquire(
                count: GridCanvasContract.inFlightBufferCount
            )
        )
        var released = false
        defer {
            if !released {
                for lease in held {
                    setup.renderer.instancePool.abandon(lease)
                }
            }
        }
        let deferred = try setup.renderer.flushPendingLiveForHarness()
        #expect(deferred.encodedIdentityRanges.isEmpty)
        #expect(
            setup.renderer.replayTile.visibleEpoch == priorVisibleEpoch
        )
        #expect(
            setup.renderer.activeStroke?.scheduler?.predictedCount
                == predictedBefore
        )
        #expect(setup.renderer.needsReplayClear)

        for lease in held {
            setup.renderer.instancePool.abandon(lease)
        }
        released = true
        let completed = try setup.renderer.flushPendingLiveForHarness()
        #expect(completed.metrics.encodedInstanceCount > 0)
        #expect(completed.encodedIdentityRanges.isEmpty)
        #expect(
            setup.renderer.activeStroke?.scheduler?.predictedCount == 0
        )
        #expect(setup.renderer.replayTile.visibleEpoch == latestEpoch)
        #expect(!setup.renderer.needsReplayClear)
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func nativeFailedReplayClearTerminatesAndClearsTransientState()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.failed-replay-clear"),
            replayMode: .replayTail,
            replayLimits: BrushRecipePolicy.replayTailLimits
        )
        let brush = try await setup.compileBrush(recipe: recipe)
        try setup.renderer.activateDrawBrush(brush)
        let canonicalBefore = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        let token = RendererOperationToken(rawValue: 43)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try setup.renderer.flushPendingLiveForHarness()
        try setup.renderer.appendStroke(
            token: token,
            sample: depositionPredictedSample(x: 40)
        )
        #expect(setup.renderer.needsReplayClear)
        #expect(
            setup.renderer.activeStroke?.scheduler?.predictedCount ?? 0 > 0
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
        #expect(setup.renderer.replayStroke.pending.isEmpty)
        #expect(setup.renderer.replayStroke.bakedHighWater == 0)
        #expect(setup.renderer.replayStroke.emittedHighWater == 0)
        #expect(setup.renderer.needsReplayClear)
        #expect(setup.renderer.harnessReservedInstanceBufferCount == 0)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == canonicalBefore
        )
    }

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
        while !setup.renderer.harnessScheduledAuthoritativeRecords.isEmpty {
            _ = try setup.renderer.flushPendingLiveForHarness()
        }
        _ = try setup.renderer.flushPendingLiveForHarness()
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
    func nativeInkIncrementalRouteMatchesBatchingAndDebugLegacyPixels()
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
        legacy.renderer.setCompatibilityInkRuntimeRouteForTesting(
            .legacyReplay
        )
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

        let coordinator = try #require(
            incremental.renderer
                .compatibilityInkCoordinatorSnapshotForTesting
        )
        #expect(coordinator.authoritativeSubmittedDabCount > 0)
        #expect(coordinator.authoritativeQueueDepth == 0)
        #expect(coordinator.retainedCompletedDabCount == 0)
        let partitionedCoordinator = try #require(
            partitioned.renderer
                .compatibilityInkCoordinatorSnapshotForTesting
        )
        #expect(
            partitionedCoordinator.commitMetadata
                == coordinator.commitMetadata
        )
        #expect(partitionedCoordinator.authoritativeQueueDepth == 0)
        #expect(partitionedCoordinator.retainedCompletedDabCount == 0)
        #expect(
            incremental.renderer.transientStrokeBuffer?.actualChunks.isEmpty
                == true
        )
        #expect(
            incremental.renderer.brushLabDiagnosticSnapshot.replayCount == 0
        )
        #expect(
            legacy.renderer.compatibilityInkCoordinatorSnapshotForTesting
                == nil
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
    func nativeInkFailedSchedulerPreflightDoesNotAdvanceCoordinator()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        try setup.renderer.applyTiling(.squareRotation)
        let token = RendererOperationToken(rawValue: 90_010)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        let coordinatorBefore = try #require(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
        )
        let bufferBefore = try #require(setup.renderer.transientStrokeBuffer)
        let arenaBefore = setup.renderer.harnessTransientDabArenaSnapshot
        let constrainedBudget = try depositionFrameBudget(
            maximumAuthoritativeInstances: 1,
            maximumPendingAuthoritativeInstances: 1
        )
        let previousBudget = setup.renderer
            .replaceDepositionFrameBudgetForHarness(constrainedBudget)
        let previousScheduler = try #require(
            setup.renderer.replaceActiveStrokeSchedulerForHarness(
                constrainedBudget
            )
        )

        #expect(
            throws: MetalRendererError
                .projectedInstanceCapacityExceeded(1)
        ) {
            try setup.renderer.appendStroke(
                token: token,
                sample: depositionSample(.moved, x: 24, y: 24)
            )
        }
        let coordinatorAfterFailure = try #require(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
        )
        #expect(coordinatorAfterFailure == coordinatorBefore)
        #expect(setup.renderer.transientStrokeBuffer == bufferBefore)
        #expect(setup.renderer.harnessTransientDabArenaSnapshot == arenaBefore)
        #expect(setup.renderer.harnessScheduledAuthoritativeRecords.isEmpty)

        setup.renderer.replaceDepositionFrameBudgetForHarness(previousBudget)
        setup.renderer.restoreActiveStrokeSchedulerForHarness(previousScheduler)
        if coordinatorAfterFailure == coordinatorBefore {
            try setup.renderer.appendStroke(
                token: token,
                sample: depositionSample(.moved, x: 24, y: 24)
            )
            let recovered = try #require(
                setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
            )
            #expect(
                recovered.commitMetadata.inputSampleCount
                    == coordinatorBefore.commitMetadata.inputSampleCount + 1
            )
            #expect(!setup.renderer.harnessScheduledAuthoritativeRecords.isEmpty)
        }
        try setup.renderer.cancelStroke(token: token)
        #expect(setup.renderer.isIdle)
        #expect(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
                == nil
        )
    }

    @Test
    @MainActor
    func nativeInkFrameTokenBoundaryCannotFailAfterSchedulerAcceptance()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let brush = try await setup.compileBrush(
            definition: StageFourAnchorDefinitions.ink
        )
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 90_011)
        try setup.renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12, y: 24),
            style: depositionStyle(
                brush,
                compositeMode: .draw,
                diameter: 12
            )
        )
        let before = try #require(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
        )
        let scheduledBefore =
            setup.renderer.harnessScheduledAuthoritativeRecords.count
        _ = try #require(
            setup.renderer.replaceCompatibilityInkFrameTokenForTesting(
                .max
            )
        )

        try setup.renderer.appendStroke(
            token: token,
            sample: depositionSample(.moved, x: 24, y: 24)
        )

        let after = try #require(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
        )
        #expect(
            after.commitMetadata.inputSampleCount
                == before.commitMetadata.inputSampleCount + 1
        )
        #expect(after.authoritativeQueueDepth == 0)
        #expect(
            after.commitMetadata.submittedDabCount
                == after.authoritativeSubmittedDabCount
        )
        #expect(
            after.authoritativeSubmittedDabCount
                > before.authoritativeSubmittedDabCount
        )
        let submittedDelta = after.authoritativeSubmittedDabCount
            - before.authoritativeSubmittedDabCount
        #expect(
            after.authoritativeQueueHighWater >= Int(submittedDelta)
        )
        #expect(
            setup.renderer.harnessScheduledAuthoritativeRecords.count
                > scheduledBefore
        )
        try setup.renderer.cancelStroke(token: token)
        #expect(setup.renderer.isIdle)
    }
}

private func requireSendableRenderState<T: Sendable>(_: T) {}

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
private func depositionStyle(
    _ brush: CompiledBrush,
    compositeMode: StrokeCompositeMode,
    diameter: Float = 20,
    eraserStrength: Float = 1
) -> StrokeRenderStyle {
    StrokeRenderStyle(
        color: .black,
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
