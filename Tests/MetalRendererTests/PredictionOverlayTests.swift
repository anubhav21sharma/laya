import CShaderTypes
import BrushFormat
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Replaceable prediction overlay")
struct PredictionOverlayTests {
    @Test
    func tileReplacementCommitsAndRollsBackWithoutLosingVisibleFootprint() throws {
        var state = PredictionTileReplacementState(maximumTileCount: 8)
        let first = [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
        ]
        let second = [
            PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 0, y: 1),
        ]

        try state.beginReplacement(first)
        #expect(state.visibleCoordinates.isEmpty)
        #expect(state.plannedCoordinates == first)
        #expect(state.priorCoordinatesToClear.isEmpty)
        state.commitReplacement()
        #expect(state.visibleCoordinates == first)

        try state.beginReplacement(second)
        #expect(state.priorCoordinatesToClear == first)
        state.rollbackReplacement()
        #expect(state.visibleCoordinates == first)
        #expect(state.plannedCoordinates.isEmpty)
        #expect(state.priorCoordinatesToClear.isEmpty)

        try state.beginReplacement([])
        #expect(state.priorCoordinatesToClear == first)
        state.commitReplacement()
        #expect(state.visibleCoordinates.isEmpty)
    }

    @Test(arguments: [StrokeSampleKind.predicted, .estimatedUpdate])
    @MainActor
    func invalidBeginKindsAreRejectedBeforeStrokeMutation(
        kind: StrokeSampleKind
    ) async throws {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileNativeInk()
        try setup.renderer.activateDrawBrush(brush)

        #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
            try setup.renderer.beginStroke(
                token: RendererOperationToken(
                    rawValue: kind == .predicted ? 710 : 711
                ),
                sample: predictionInvalidLifecycleSample(
                    x: 8,
                    timestamp: 0,
                    phase: .began,
                    kind: kind
                ),
                style: predictionStyle(brush)
            )
        }

        #expect(setup.renderer.isIdle)
        #expect(setup.renderer.transientStrokeBuffer == nil)
        #expect(setup.renderer.harnessScheduledAuthoritativeRecords.isEmpty)
        #expect(setup.renderer.harnessScheduledPredictedRecords.isEmpty)
        #expect(setup.renderer.predictionOverlay.snapshot.provenance == nil)
    }

    @Test(arguments: [StrokeSampleKind.predicted, .estimatedUpdate])
    @MainActor
    func invalidFinishKindsAreRejectedBeforeStrokeMutation(
        kind: StrokeSampleKind
    ) async throws {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileNativeInk()
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(
            rawValue: kind == .predicted ? 712 : 713
        )
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionInputSample(
                x: 8,
                timestamp: 0,
                phase: .began
            ),
            style: predictionStyle(brush)
        )
        try await drainPredictionActor(setup.renderer)
        let before = await predictionMutationSnapshot(setup.renderer)
        #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
            try setup.renderer.finishStrokeTransient(
                token: token,
                sample: predictionInvalidLifecycleSample(
                    x: 12,
                    timestamp: 0.01,
                    phase: .ended,
                    kind: kind
                )
            )
        }

        #expect(
            await predictionMutationSnapshot(setup.renderer) == before
        )
        #expect(setup.renderer.activeStroke?.isFinishedTransiently == false)
        try setup.renderer.cancelStroke(token: token)
    }

    @Test(arguments: [StrokeSampleKind.predicted, .estimatedUpdate])
    @MainActor
    func invalidCommitKindsAreRejectedBeforeCancellingStroke(
        kind: StrokeSampleKind
    ) async throws {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileNativeInk()
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(
            rawValue: kind == .predicted ? 714 : 715
        )
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionInputSample(
                x: 8,
                timestamp: 0,
                phase: .began
            ),
            style: predictionStyle(brush)
        )
        try await drainPredictionActor(setup.renderer)
        let before = await predictionMutationSnapshot(setup.renderer)

        #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
            try setup.renderer.requestStrokeCommit(
                token: token,
                sample: predictionInvalidLifecycleSample(
                    x: 12,
                    timestamp: 0.01,
                    phase: .ended,
                    kind: kind
                ),
                maximumRetainedBytes: 1_024 * 1_024
            )
        }

        #expect(setup.renderer.activeStroke?.token == token)
        #expect(
            await predictionMutationSnapshot(setup.renderer) == before
        )
        #expect(setup.renderer.activeStroke?.isFinishedTransiently == false)
        try setup.renderer.cancelStroke(token: token)
    }

    @Test(arguments: [StrokeSampleKind.predicted, .estimatedUpdate])
    @MainActor
    func invalidAppendEndpointKindsRejectWithoutAnyInputSideEffect(
        kind: StrokeSampleKind
    ) async throws {
        for (offset, phase) in [StrokePhase.began, .ended].enumerated() {
            guard let setup = try predictionRendererSetup() else { return }
            let brush = try await setup.compileNativeInk()
            try setup.renderer.activateDrawBrush(brush)
            setup.renderer.configureStrokeRuntimeTelemetry(
                profile: .syntheticTest
            )
            let token = RendererOperationToken(
                rawValue: UInt64(720 + offset)
                    + (kind == .predicted ? 0 : 10)
            )
            try setup.renderer.beginStroke(
                token: token,
                sample: predictionInputSample(
                    x: 8,
                    timestamp: 0,
                    phase: .began
                ),
                style: predictionStyle(brush)
            )
            _ = setup.renderer.takeBrushLabEventToSubmitNanoseconds(
                submittedAt: UInt64.max
            )
            try await drainPredictionActor(setup.renderer)
            let before = await predictionMutationSnapshot(setup.renderer)

            #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
                try setup.renderer.appendStroke(
                    token: token,
                    sample: predictionInvalidLifecycleSample(
                        x: 12,
                        timestamp: 0.01,
                        phase: phase,
                        kind: kind
                    )
                )
            }

            #expect(
                await predictionMutationSnapshot(setup.renderer) == before
            )
            try setup.renderer.cancelStroke(token: token)
        }
    }

    @Test
    @MainActor
    func mixedBatchWithInvalidLaterSampleRejectsWithoutValidPrefixMutation()
        async throws
    {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileNativeInk()
        try setup.renderer.activateDrawBrush(brush)
        setup.renderer.configureStrokeRuntimeTelemetry(profile: .syntheticTest)
        let token = RendererOperationToken(rawValue: 740)
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionInputSample(
                x: 8,
                timestamp: 0,
                phase: .began
            ),
            style: predictionStyle(brush)
        )
        _ = setup.renderer.takeBrushLabEventToSubmitNanoseconds(
            submittedAt: UInt64.max
        )
        try await drainPredictionActor(setup.renderer)
        let before = await predictionMutationSnapshot(setup.renderer)

        #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
            try setup.renderer.appendStrokeBatch(
                token: token,
                samples: [
                    predictionInputSample(
                        x: 12,
                        timestamp: 0.01,
                        phase: .moved
                    ),
                    predictionInvalidLifecycleSample(
                        x: 14,
                        timestamp: 0.02,
                        phase: .ended,
                        kind: .predicted
                    ),
                ]
            )
        }

        #expect(
            await predictionMutationSnapshot(setup.renderer) == before
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test(arguments: [StrokePhase.began, .ended])
    @MainActor
    func estimatedUpdateEndpointPhaseRejectsWithoutAnyInputSideEffect(
        phase: StrokePhase
    ) async throws {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileNativeInk()
        try setup.renderer.activateDrawBrush(brush)
        setup.renderer.configureStrokeRuntimeTelemetry(profile: .syntheticTest)
        let token = RendererOperationToken(
            rawValue: phase == .began ? 741 : 742
        )
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionInputSample(
                x: 8,
                timestamp: 0,
                phase: .began
            ),
            style: predictionStyle(brush)
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: predictionEstimatedSample(
                x: 9,
                timestamp: 0.001,
                index: 123
            )
        )
        _ = setup.renderer.takeBrushLabEventToSubmitNanoseconds(
            submittedAt: UInt64.max
        )
        try await drainPredictionActor(setup.renderer)
        let before = await predictionMutationSnapshot(setup.renderer)

        #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
            try setup.renderer.applyEstimatedStrokeUpdate(
                token: token,
                sample: predictionInvalidLifecycleSample(
                    x: 12,
                    timestamp: 0.01,
                    phase: phase,
                    kind: .estimatedUpdate,
                    estimationUpdateIndex: 123
                )
            )
        }

        #expect(
            await predictionMutationSnapshot(setup.renderer) == before
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    func admissionTruncatesEachPredictionDimensionAndRecordsEveryOverload() {
        let admission = PredictionOverlay.admit(
            normalizedSampleCount: 65,
            logicalDabCount: 513,
            projectedInstanceCount: 7,
            predictedInstanceBudget: 3
        )

        #expect(admission.normalizedSampleCount == 64)
        #expect(admission.logicalDabCount == 512)
        #expect(admission.projectedInstanceCount == 3)
        #expect(
            admission.overload == [
                .normalizedSamples,
                .logicalDabs,
                .projectedInstances,
            ]
        )
    }

    @Test
    @MainActor
    func replacementClearsOnlyThePreviouslySubmittedDirtyRegions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 128, height: 128)
        let overlay = try PredictionOverlay(
            device: device,
            pixelSize: size
        )
        let first = PixelRect(minX: 4, minY: 6, maxX: 20, maxY: 22)!
        let second = PixelRect(minX: 80, minY: 82, maxX: 96, maxY: 98)!
        let boundary = PredictionProvenanceBoundary(
            coordinatorRevision: 1,
            nextAuthoritativeOrdinal: 12
        )

        _ = overlay.planReplacement(
            epoch: 1,
            provenance: boundary,
            admission: PredictionOverlay.admit(
                normalizedSampleCount: 1,
                logicalDabCount: 2,
                projectedInstanceCount: 2,
                predictedInstanceBudget: 8
            ),
            dirtyRegions: [first]
        )
        overlay.markVisible(epoch: 1)

        let clear = overlay.planReplacement(
            epoch: 2,
            provenance: boundary,
            admission: PredictionOverlay.admit(
                normalizedSampleCount: 1,
                logicalDabCount: 2,
                projectedInstanceCount: 2,
                predictedInstanceBudget: 8
            ),
            dirtyRegions: [second]
        )

        #expect(
            clear == .regional(
                PixelRegionSet([first], clippedTo: size)
            )
        )
        #expect(
            clear != .regional(
                PixelRegionSet([first, second], clippedTo: size)
            )
        )
    }

    @Test
    @MainActor
    func overlappingRawFootprintBeyondTwoHundredFiftySixStaysExact()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let overlay = try PredictionOverlay(device: device, pixelSize: size)
        let exact = PixelRect(
            minX: 20,
            minY: 24,
            maxX: 36,
            maxY: 40
        )!
        let raw = [PixelRect](repeating: exact, count: 257)

        _ = overlay.planReplacement(
            epoch: 1,
            provenance: nil,
            admission: PredictionOverlay.admit(
                normalizedSampleCount: 1,
                logicalDabCount: 257,
                projectedInstanceCount: 257,
                predictedInstanceBudget: 512
            ),
            dirtyRegions: raw
        )
        overlay.markVisible(epoch: 1)
        let clear = overlay.planReplacement(
            epoch: 2,
            provenance: nil,
            admission: PredictionOverlay.admit(
                normalizedSampleCount: 0,
                logicalDabCount: 0,
                projectedInstanceCount: 0,
                predictedInstanceBudget: 512
            ),
            dirtyRegions: []
        )

        #expect(
            overlay.snapshot.previousDirtyRegions
                == PixelRegionSet([exact], clippedTo: size)
        )
        #expect(
            clear == .regional(
                PixelRegionSet([exact], clippedTo: size)
            )
        )
    }

    @Test
    @MainActor
    func disjointCanonicalFootprintBeyondThirtyTwoStaysRegional() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let overlay = try PredictionOverlay(device: device, pixelSize: size)
        let disjoint = (0..<40).map { index in
            PixelRect(
                minX: index * 3,
                minY: 12,
                maxX: index * 3 + 1,
                maxY: 13
            )!
        }
        let exact = PixelRegionSet(disjoint, clippedTo: size)

        _ = overlay.planReplacement(
            epoch: 1,
            provenance: nil,
            admission: PredictionOverlay.admit(
                normalizedSampleCount: 1,
                logicalDabCount: 40,
                projectedInstanceCount: 40,
                predictedInstanceBudget: 512
            ),
            dirtyRegions: disjoint
        )
        overlay.markVisible(epoch: 1)
        let clear = overlay.planReplacement(
            epoch: 2,
            provenance: nil,
            admission: PredictionOverlay.admit(
                normalizedSampleCount: 0,
                logicalDabCount: 0,
                projectedInstanceCount: 0,
                predictedInstanceBudget: 512
            ),
            dirtyRegions: []
        )

        #expect(overlay.snapshot.previousDirtyRegions == exact)
        #expect(clear == .regional(exact))
    }

    @Test
    @MainActor
    func visibilityInstallsOnlyTheExactLatestPlannedEpoch() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 64, height: 64)
        let overlay = try PredictionOverlay(device: device, pixelSize: size)
        let first = PredictionProvenanceBoundary(
            coordinatorRevision: 3,
            nextAuthoritativeOrdinal: 30
        )
        let latest = PredictionProvenanceBoundary(
            coordinatorRevision: 4,
            nextAuthoritativeOrdinal: 40
        )
        let admission = PredictionOverlay.admit(
            normalizedSampleCount: 1,
            logicalDabCount: 1,
            projectedInstanceCount: 1,
            predictedInstanceBudget: 8
        )

        _ = overlay.planReplacement(
            epoch: 3,
            provenance: first,
            admission: admission,
            dirtyRegions: []
        )
        #expect(
            overlay.planReplacement(
                epoch: 2,
                provenance: latest,
                admission: admission,
                dirtyRegions: []
            ) == nil
        )
        _ = overlay.planReplacement(
            epoch: 4,
            provenance: latest,
            admission: admission,
            dirtyRegions: []
        )
        overlay.markVisible(epoch: 3)

        #expect(overlay.surface.visibleEpoch == 0)
        #expect(overlay.snapshot.provenance == latest)

        overlay.markVisible(epoch: 4)
        overlay.markVisible(epoch: 3)

        #expect(overlay.surface.visibleEpoch == 4)
        #expect(overlay.snapshot.provenance == latest)
    }

    @Test
    @MainActor
    func actualInvalidatesOnlyPredictionFromItsMatchingBoundary() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 64, height: 64)
        let overlay = try PredictionOverlay(
            device: device,
            pixelSize: size
        )
        let dirty = PixelRect(minX: 3, minY: 4, maxX: 13, maxY: 14)!
        let boundary = PredictionProvenanceBoundary(
            coordinatorRevision: 7,
            nextAuthoritativeOrdinal: 41
        )
        _ = overlay.planReplacement(
            epoch: 1,
            provenance: boundary,
            admission: PredictionOverlay.admit(
                normalizedSampleCount: 2,
                logicalDabCount: 5,
                projectedInstanceCount: 5,
                predictedInstanceBudget: 8
            ),
            dirtyRegions: [dirty]
        )
        overlay.markVisible(epoch: 1)

        #expect(
            !overlay.invalidatePrediction(
                from: PredictionProvenanceBoundary(
                    coordinatorRevision: 6,
                    nextAuthoritativeOrdinal: 41
                ),
                epoch: 2
            )
        )
        #expect(overlay.snapshot.provenance == boundary)
        #expect(
            overlay.invalidatePrediction(from: boundary, epoch: 2)
        )
        #expect(overlay.snapshot.provenance == nil)
        #expect(
            overlay.surface.lastClearPlan == .regional(
                PixelRegionSet([dirty], clippedTo: size)
            )
        )
    }

    @Test
    func frameBudgetTruncatesTruePredictionWithoutDroppingCorrection() throws {
        let budget = try predictionBudget(
            predictedPerFrame: 2,
            authoritativeCapacity: 8,
            predictedCapacity: 8
        )
        let scheduler = FrameScheduler(budget: budget)
        let correction = predictionRecord(identity: 10, predicted: false)
        let predictions = (100..<104).map {
            predictionRecord(identity: UInt64($0), predicted: true)
        }

        let result = try scheduler.replacePrediction(
            [correction] + predictions
        )

        #expect(result.acceptedPredictedInstanceCount == 2)
        #expect(result.droppedPredictedInstanceCount == 2)
        #expect(result.overloaded)
        #expect(
            scheduler.predictedRecords.map(\.identity) == [10, 100, 101]
        )
        #expect(scheduler.diagnosticSnapshot.predictionOverloadCount == 1)
    }

    @Test
    func correctionRemainsLosslessAcrossMultiplePredictionFrameChunks()
        throws
    {
        let budget = try predictionBudget(
            predictedPerFrame: 2,
            authoritativeCapacity: 8,
            predictedCapacity: 9
        )
        let scheduler = FrameScheduler(budget: budget)
        let corrections = (10..<17).map {
            predictionRecord(identity: UInt64($0), predicted: false)
        }
        let predictions = (100..<104).map {
            predictionRecord(identity: UInt64($0), predicted: true)
        }

        let replacement = try scheduler.replacePrediction(
            corrections + predictions
        )
        var submittedCorrections: [UInt64] = []
        var frameCount = 0
        while scheduler.predictedCount > 0 {
            let frame = scheduler.nextFrame(budget: budget)
            submittedCorrections.append(
                contentsOf: frame.predicted
                    .filter { !$0.isPredicted }
                    .map(\.identity)
            )
            frameCount += 1
        }

        #expect(replacement.acceptedPredictedInstanceCount == 2)
        #expect(replacement.droppedPredictedInstanceCount == 2)
        #expect(submittedCorrections == corrections.map(\.identity))
        #expect(frameCount > 1)
    }

    @Test
    func commitPreparationNeverPromotesTruePrediction() throws {
        let budget = try predictionBudget(
            predictedPerFrame: 4,
            authoritativeCapacity: 8,
            predictedCapacity: 8
        )
        let scheduler = FrameScheduler(budget: budget)
        try scheduler.replacePrediction([
            predictionRecord(identity: 10, predicted: false),
            predictionRecord(identity: 100, predicted: true),
            predictionRecord(identity: 101, predicted: true),
        ])

        let result = try scheduler.prepareReplayForCommit()

        #expect(result.promotedNonPredictedInstanceCount == 1)
        #expect(result.discardedPredictedInstanceCount == 2)
        #expect(scheduler.predictedCount == 0)
        #expect(scheduler.authoritativeRecords.map(\.identity) == [10])
        #expect(
            scheduler.authoritativeRecords.allSatisfy {
                !$0.isPredicted
            }
        )
    }

    @Test
    @MainActor
    func rendererRetainsOnlySixtyFourPredictedSamplesWithoutChangingActual()
        async throws
    {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileNativeInk()
        try setup.renderer.activateDrawBrush(brush)
        setup.renderer.configureStrokeRuntimeTelemetry(profile: .syntheticTest)
        let token = RendererOperationToken(rawValue: 700)
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionInputSample(
                x: 8,
                timestamp: 0,
                phase: .began
            ),
            style: predictionStyle(brush)
        )
        try await drainPredictionActor(setup.renderer)
        let authoritativeBefore = try #require(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
        )
        var predicted = (0..<64).map { index in
            predictionInputSample(
                x: 9 + Float(index) * 0.25,
                timestamp: 0.001 + Double(index) * 0.001,
                phase: .moved,
                kind: .predicted
            )
        }
        predicted.append(
            contentsOf: repeatElement(
                predictionInvalidLifecycleSample(
                    x: 40,
                    timestamp: 1,
                    phase: .ended,
                    kind: .predicted
                ),
                count: 100_000 - predicted.count
            )
        )

        var scratchSnapshots: [
            GridRenderer.PredictionSubmissionScratchSnapshot
        ] = []
        for _ in 0..<3 {
            try setup.renderer.appendStrokeBatch(
                token: token,
                authoritativeSamples:
                    predicted[..<predicted.startIndex],
                predictedSamples: predicted[...]
            )
            scratchSnapshots.append(
                setup.renderer
                    .predictionSubmissionScratchSnapshotForTesting
            )
            try await drainPredictionActor(setup.renderer)
        }
        let actorState = await setup.renderer
            .offMainTransientSnapshotForTesting()

        #expect(actorState.predictedSamples.count == 64)
        let firstScratch = try #require(scratchSnapshots.first)
        #expect(firstScratch.count == 64)
        #expect(firstScratch.highWater == 64)
        #expect(firstScratch.storageCapacity >= 64)
        #expect(firstScratch.storageIdentity != 0)
        #expect(firstScratch.storageReallocationCount == 0)
        #expect(firstScratch.lastSubmittedSampleCount == 100_000)
        #expect(firstScratch.lastAcceptedSampleCount == 64)
        #expect(firstScratch.lastShedSampleCount == 100_000 - 64)
        #expect(firstScratch.lastValidatedSampleCount == 64)
        #expect(firstScratch.lastTelemetrySampleCount == 64)
        #expect(
            scratchSnapshots.allSatisfy {
                $0.storageCapacity == firstScratch.storageCapacity
                    && $0.storageIdentity == firstScratch.storageIdentity
                    && $0.storageReallocationCount == 0
                    && $0.lastSubmittedSampleCount == 100_000
                    && $0.lastAcceptedSampleCount == 64
                    && $0.lastShedSampleCount == 100_000 - 64
                    && $0.lastValidatedSampleCount == 64
                    && $0.lastTelemetrySampleCount == 64
            }
        )
        #expect(
            setup.renderer.strokeRuntimeSnapshot?.inputProvenance.predicted
                == 3 * 64
        )
        #expect(
            setup.renderer.predictionOverlay.snapshot.lastOverload
                .contains(.normalizedSamples)
        )
        #expect(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
                == authoritativeBefore
        )

        try setup.renderer.appendStrokeBatch(
            token: token,
            authoritativeSamples: predicted[..<predicted.startIndex],
            predictedSamples: predicted[..<predicted.startIndex],
            submittedPredictionSampleCount: 100_000
        )
        let emptyScratch =
            setup.renderer.predictionSubmissionScratchSnapshotForTesting
        #expect(emptyScratch.count == 0)
        #expect(emptyScratch.highWater == 64)
        #expect(emptyScratch.storageCapacity == firstScratch.storageCapacity)
        #expect(emptyScratch.storageIdentity == firstScratch.storageIdentity)
        #expect(emptyScratch.storageReallocationCount == 0)
        #expect(emptyScratch.lastSubmittedSampleCount == 100_000)
        #expect(emptyScratch.lastAcceptedSampleCount == 0)
        #expect(emptyScratch.lastShedSampleCount == 100_000)
        #expect(emptyScratch.lastValidatedSampleCount == 0)
        #expect(emptyScratch.lastTelemetrySampleCount == 0)
        try await drainPredictionActor(setup.renderer)
        let clearedActorState = await setup.renderer
            .offMainTransientSnapshotForTesting()
        #expect(clearedActorState.predictedSamples.isEmpty)
        #expect(
            setup.renderer.predictionOverlay.snapshot.normalizedSampleCount
                == 0
        )
        #expect(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
                == authoritativeBefore
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func everyBrushRouteUsesTheSixtyFourSamplePredictionCap()
        async throws
    {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileReplayTail()
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 703)
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionInputSample(
                x: 8,
                timestamp: 0,
                phase: .began
            ),
            style: predictionStyle(brush)
        )
        let predicted = (0..<65).map { index in
            predictionInputSample(
                x: 9 + Float(index) * 0.25,
                timestamp: 0.001 + Double(index) * 0.001,
                phase: .moved,
                kind: .predicted
            )
        }

        try setup.renderer.appendStrokeBatch(
            token: token,
            samples: predicted
        )
        try await drainPredictionActor(setup.renderer)
        let actorState = await setup.renderer
            .offMainTransientSnapshotForTesting()

        #expect(actorState.predictedSamples.count == 64)
        #expect(
            setup.renderer.predictionOverlay.snapshot.lastOverload
                .contains(.normalizedSamples)
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func unresolvedActualSampleOccupancyTruncatesPredictionWithoutThrowing()
        async throws
    {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileReplayTail(
            limits: BrushReplayLimits(
                maximumSamples: 1,
                maximumDabs: 64,
                maximumProjectedInstances: 64
            )
        )
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 706)
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionUnresolvedActualBegan(index: 101),
            style: predictionStyle(brush)
        )
        try await drainPredictionActor(setup.renderer)
        let actualBefore = await setup.renderer
            .offMainTransientSnapshotForTesting()

        try setup.renderer.appendStroke(
            token: token,
            sample: predictionInputSample(
                x: 24,
                timestamp: 0.01,
                phase: .moved,
                kind: .predicted
            )
        )
        try await drainPredictionActor(setup.renderer)
        let actorState = await setup.renderer
            .offMainTransientSnapshotForTesting()

        #expect(actorState.actualSamples == actualBefore.actualSamples)
        #expect(actorState.actualDabs == actualBefore.actualDabs)
        #expect(actorState.predictedSamples.isEmpty)
        #expect(
            setup.renderer.predictionOverlay.snapshot.lastOverload
                .contains(.normalizedSamples)
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func unresolvedActualDabOccupancyTruncatesPredictionWithoutThrowing()
        async throws
    {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileReplayTail(
            limits: BrushReplayLimits(
                maximumSamples: 16,
                maximumDabs: 1,
                maximumProjectedInstances: 64
            )
        )
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 707)
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionUnresolvedActualBegan(index: 102),
            style: predictionStyle(brush)
        )
        try await drainPredictionActor(setup.renderer)
        #expect(
            await setup.renderer.offMainTransientSnapshotForTesting()
                .actualDabs.count == 1
        )

        try setup.renderer.appendStroke(
            token: token,
            sample: predictionInputSample(
                x: 24,
                timestamp: 0.01,
                phase: .moved,
                kind: .predicted
            )
        )
        try await drainPredictionActor(setup.renderer)
        let actorState = await setup.renderer
            .offMainTransientSnapshotForTesting()

        #expect(actorState.actualDabs.count == 1)
        #expect(actorState.predictedDabs.isEmpty)
        #expect(
            setup.renderer.predictionOverlay.snapshot.lastOverload
                .contains(.logicalDabs)
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func unresolvedActualProjectionOccupancyTruncatesPredictionWithoutThrowing()
        async throws
    {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileReplayTail(
            limits: BrushReplayLimits(
                maximumSamples: 16,
                maximumDabs: 64,
                maximumProjectedInstances: 1
            )
        )
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 708)
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionUnresolvedActualBegan(index: 103),
            style: predictionStyle(brush)
        )
        try await drainPredictionActor(setup.renderer)
        let actualProjectedCount = try #require(
            await setup.renderer.offMainTransientSnapshotForTesting()
                .actualDabs.first?.projectedInstanceCount
        )
        #expect(actualProjectedCount == 1)

        try setup.renderer.appendStroke(
            token: token,
            sample: predictionInputSample(
                x: 24,
                timestamp: 0.01,
                phase: .moved,
                kind: .predicted
            )
        )
        try await drainPredictionActor(setup.renderer)

        #expect(
            await setup.renderer.offMainTransientSnapshotForTesting()
                .predictedDabs.isEmpty
        )
        #expect(
            setup.renderer.predictionOverlay.snapshot.lastOverload
                .contains(.projectedInstances)
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func retainedCorrectionConsumesPendingCapacityBeforePrediction()
        async throws
    {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileReplayTail()
        try setup.renderer.activateDrawBrush(brush)

        let probeToken = RendererOperationToken(rawValue: 7_090)
        try setup.renderer.beginStroke(
            token: probeToken,
            sample: predictionUnresolvedActualBegan(index: 1_040),
            style: predictionStyle(brush)
        )
        try await drainPredictionActor(setup.renderer)
        let probeState = await setup.renderer
            .offMainTransientSnapshotForTesting()
        let correctionCount = probeState.actualDabs.reduce(0) {
            $0 + $1.projectedInstanceCount
        }
        #expect(correctionCount > 0)
        try setup.renderer.cancelStroke(token: probeToken)
        try setup.renderer.drainStrokeWorkspaceRetirementForHarness()

        let constrained = try predictionBudget(
            predictedPerFrame: 1,
            authoritativeCapacity: 64,
            predictedCapacity: correctionCount
        )
        _ = setup.renderer.replaceDepositionFrameBudgetForHarness(
            constrained
        )
        let token = RendererOperationToken(rawValue: 709)
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionUnresolvedActualBegan(index: 104),
            style: predictionStyle(brush)
        )
        try await drainPredictionActor(setup.renderer)
        let actualBefore = await setup.renderer
            .offMainTransientSnapshotForTesting()
        let coordinatorBefore = try #require(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
        )

        try setup.renderer.appendStroke(
            token: token,
            sample: predictionInputSample(
                x: 24,
                timestamp: 0.01,
                phase: .moved,
                kind: .predicted
            )
        )
        try await drainPredictionActor(setup.renderer)
        let actorState = await setup.renderer
            .offMainTransientSnapshotForTesting()

        #expect(actorState.actualSamples == actualBefore.actualSamples)
        #expect(actorState.actualDabs == actualBefore.actualDabs)
        #expect(actorState.predictedSamples.count == 1)
        #expect(actorState.predictedDabs.isEmpty)
        #expect(
            setup.renderer.offMainPredictedInstanceCountForTesting
                == correctionCount
        )
        #expect(
            setup.renderer.predictionOverlay.snapshot.lastOverload
                .contains(.projectedInstances)
        )
        #expect(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
                == coordinatorBefore
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func rendererTruncatesPredictionBeforeTheFiveHundredThirteenthDab()
        async throws
    {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileNativeInk()
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 701)
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionInputSample(
                x: 8,
                timestamp: 0,
                phase: .began
            ),
            style: predictionStyle(brush)
        )

        try setup.renderer.appendStroke(
            token: token,
            sample: predictionInputSample(
                x: 10_000,
                timestamp: 1,
                phase: .moved,
                kind: .predicted
            )
        )
        try await drainPredictionActor(setup.renderer)
        let actorState = await setup.renderer
            .offMainTransientSnapshotForTesting()

        #expect(actorState.predictedDabs.count == 512)
        #expect(
            setup.renderer.predictionOverlay.snapshot
                .projectedInstanceCount
                == setup.renderer.offMainPredictedInstanceCountForTesting
        )
        #expect(
            setup.renderer.predictionOverlay.snapshot.lastOverload
                .contains(.logicalDabs)
        )
        #expect(
            setup.renderer.harnessScheduledAuthoritativeRecords
                .allSatisfy { !$0.isPredicted }
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func predictedEstimatedReplayUsesTheSameBoundedOverlayAdmission()
        async throws
    {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileNativeInk()
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 704)
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionInputSample(
                x: 8,
                timestamp: 0,
                phase: .began
            ),
            style: predictionStyle(brush)
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: predictionEstimatedSample(
                x: 9,
                timestamp: 0.001,
                index: 91
            )
        )
        try await drainPredictionActor(setup.renderer)
        let provenance = try #require(
            setup.renderer.predictionOverlay.snapshot.provenance
        )

        try setup.renderer.applyEstimatedStrokeUpdate(
            token: token,
            sample: predictionEstimatedUpdateSample(
                x: 10_000,
                timestamp: 1,
                index: 91
            )
        )
        try await drainPredictionActor(setup.renderer)
        let actorState = await setup.renderer
            .offMainTransientSnapshotForTesting()

        #expect(actorState.predictedDabs.count == 512)
        #expect(
            setup.renderer.predictionOverlay.snapshot.provenance
                == provenance
        )
        #expect(
            setup.renderer.predictionOverlay.snapshot.lastOverload
                .contains(.logicalDabs)
        )
        #expect(
            setup.renderer.predictionOverlay.snapshot
                .projectedInstanceCount
                == setup.renderer.offMainPredictedInstanceCountForTesting
        )
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func predictedEstimatedReplaySubtractsPendingCorrectionCapacity()
        async throws
    {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileNativeInk()
        try setup.renderer.activateDrawBrush(brush)

        let probeToken = RendererOperationToken(rawValue: 7_160)
        try setup.renderer.beginStroke(
            token: probeToken,
            sample: predictionUnresolvedActualBegan(index: 1_210),
            style: predictionStyle(brush)
        )
        try await drainPredictionActor(setup.renderer)
        let probeState = await setup.renderer
            .offMainTransientSnapshotForTesting()
        let correctionCount = probeState.actualDabs.reduce(0) {
            $0 + $1.projectedInstanceCount
        }
        #expect(correctionCount > 0)
        try setup.renderer.cancelStroke(token: probeToken)
        try setup.renderer.drainStrokeWorkspaceRetirementForHarness()

        let constrained = try predictionBudget(
            predictedPerFrame: 1,
            authoritativeCapacity: 64,
            predictedCapacity: correctionCount
        )
        _ = setup.renderer.replaceDepositionFrameBudgetForHarness(
            constrained
        )
        let token = RendererOperationToken(rawValue: 716)
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionUnresolvedActualBegan(index: 121),
            style: predictionStyle(brush)
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: predictionEstimatedSample(
                x: 9,
                timestamp: 0.001,
                index: 122
            )
        )
        try await drainPredictionActor(setup.renderer)
        let actualBefore = await setup.renderer
            .offMainTransientSnapshotForTesting()
        let coordinatorBefore = try #require(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
        )
        let provenanceBefore = try #require(
            setup.renderer.predictionOverlay.snapshot.provenance
        )

        try setup.renderer.applyEstimatedStrokeUpdate(
            token: token,
            sample: predictionEstimatedUpdateSample(
                x: 10_000,
                timestamp: 1,
                index: 122
            )
        )
        try await drainPredictionActor(setup.renderer)
        let actorState = await setup.renderer
            .offMainTransientSnapshotForTesting()

        #expect(actorState.actualSamples == actualBefore.actualSamples)
        #expect(actorState.actualDabs == actualBefore.actualDabs)
        #expect(actorState.predictedSamples.count == 1)
        #expect(actorState.predictedDabs.isEmpty)
        #expect(
            setup.renderer.offMainPredictedInstanceCountForTesting
                == correctionCount
        )
        #expect(
            setup.renderer.predictionOverlay.snapshot.lastOverload
                .contains(.projectedInstances)
        )
        #expect(
            setup.renderer.predictionOverlay.snapshot.provenance
                == provenanceBefore
        )
        #expect(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
                == coordinatorBefore
        )
        #expect(setup.renderer.activeStroke?.token == token)
        #expect(setup.renderer.activeStroke?.isFinishedTransiently == false)
        try setup.renderer.cancelStroke(token: token)
    }

    @Test
    @MainActor
    func rendererRejectsMismatchedPredictionInvalidationAtomically()
        async throws
    {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileNativeInk()
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 705)
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionInputSample(
                x: 8,
                timestamp: 0,
                phase: .began
            ),
            style: predictionStyle(brush)
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: predictionEstimatedSample(
                x: 24,
                timestamp: 0.01,
                index: 92
            )
        )
        try await drainPredictionActor(setup.renderer)
        let matching = try #require(
            setup.renderer.predictionOverlay.snapshot.provenance
        )
        _ = setup.renderer.predictionOverlay.planReplacement(
            epoch: UInt64.max - 1,
            provenance: PredictionProvenanceBoundary(
                coordinatorRevision:
                    matching.coordinatorRevision &+ 1,
                nextAuthoritativeOrdinal:
                    matching.nextAuthoritativeOrdinal
            ),
            admission: PredictionOverlay.admit(
                normalizedSampleCount: 0,
                logicalDabCount: 0,
                projectedInstanceCount: 0,
                predictedInstanceBudget: 1
            ),
            dirtyRegions: []
        )
        let before = await predictionMutationSnapshot(setup.renderer)
        let snapshotMaterializationCountBeforePreflight =
            setup.renderer.predictionOverlay
                .snapshotMaterializationCountForTesting

        #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
            try setup.renderer.appendStroke(
                token: token,
                sample: predictionInputSample(
                    x: 26,
                    timestamp: 0.02,
                    phase: .moved
                )
            )
        }
        #expect(
            setup.renderer.predictionOverlay
                .snapshotMaterializationCountForTesting
                == snapshotMaterializationCountBeforePreflight
        )
        #expect(
            await predictionMutationSnapshot(setup.renderer) == before
        )

        #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
            try setup.renderer.applyEstimatedStrokeUpdate(
                token: token,
                sample: predictionEstimatedUpdateSample(
                    x: 28,
                    timestamp: 0.03,
                    index: 92
                )
            )
        }
        #expect(
            await predictionMutationSnapshot(setup.renderer) == before
        )

        #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
            try setup.renderer.finishStrokeTransient(
                token: token,
                sample: predictionInputSample(
                    x: 29,
                    timestamp: 0.035,
                    phase: .ended
                )
            )
        }
        #expect(
            await predictionMutationSnapshot(setup.renderer) == before
        )

        #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
            try setup.renderer.appendStroke(
                token: token,
                sample: predictionEstimatedActualMoved(
                    x: 30,
                    timestamp: 0.04,
                    index: 93
                )
            )
        }
        #expect(
            await predictionMutationSnapshot(setup.renderer) == before
        )
        try setup.renderer.cancelStroke(token: token)
    }


    @Test
    @MainActor
    func pointerUpDiscardsPredictionBeforeFinalActualDrain() async throws {
        guard let setup = try predictionRendererSetup() else { return }
        let brush = try await setup.compileNativeInk()
        try setup.renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 702)
        try setup.renderer.beginStroke(
            token: token,
            sample: predictionInputSample(
                x: 8,
                timestamp: 0,
                phase: .began
            ),
            style: predictionStyle(brush)
        )
        try setup.renderer.appendStroke(
            token: token,
            sample: predictionInputSample(
                x: 40,
                timestamp: 0.02,
                phase: .moved,
                kind: .predicted
            )
        )
        try await drainPredictionActor(setup.renderer)
        #expect(
            await setup.renderer.offMainTransientSnapshotForTesting()
                .predictedDabs.contains { $0.attributes.isPredicted }
        )
        #expect(setup.renderer.predictionOverlay.snapshot.provenance != nil)

        try setup.renderer.finishStrokeTransient(
            token: token,
            sample: predictionInputSample(
                x: 42,
                timestamp: 0.03,
                phase: .ended
            )
        )
        try await drainPredictionActor(setup.renderer)
        let actorState = await setup.renderer
            .offMainTransientSnapshotForTesting()

        #expect(actorState.predictedDabs.allSatisfy {
            !$0.attributes.isPredicted
        })
        #expect(actorState.predictedSamples.isEmpty)
        #expect(setup.renderer.predictionOverlay.snapshot.provenance == nil)
        #expect(setup.renderer.activeStroke?.isFinishedTransiently == true)
        try setup.renderer.cancelStroke(token: token)
    }
}

@MainActor
private struct PredictionRendererSetup {
    let renderer: GridRenderer
    let compiler: BrushCompiler

    func compileNativeInk() async throws -> CompiledBrush {
        let recipe = try BrushRecipe(
            id: BrushRecipeID("builtin.native-ink"),
            replayMode: .appendOnly
        )
        let definition = try LegacyBrushRecipeAdapter.definition(
            from: recipe,
            displayName: "Prediction Overlay"
        )
        return try await compiler.compileAndActivate(
            package: BrushPackage(
                manifest: BrushPackageManifest(resources: []),
                definition: definition,
                resourceData: [:]
            )
        )
    }

    func compileReplayTail(
        limits: BrushReplayLimits = BrushRecipePolicy.replayTailLimits
    ) async throws -> CompiledBrush {
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.prediction-overlay-replay-tail"),
            replayMode: .replayTail,
            replayLimits: limits
        )
        let definition = try LegacyBrushRecipeAdapter.definition(
            from: recipe,
            displayName: "Prediction Overlay Replay Tail"
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

private struct PredictionMutationSnapshot: Equatable {
    let receiptPending: Bool
    let runtimeInputProvenance: StrokeRuntimeInputProvenanceCounts?
    let eventDiagnostics: RendererEventDispatcher.Diagnostics
    let coordinator: StrokeRenderSnapshot?
    let scheduler: StrokeFrameSchedulerSnapshot
    let transient: StrokeTransientPreparationSnapshot
    let overlay: PredictionOverlaySnapshot
    let activeToken: RendererOperationToken?
    let isFinishedTransiently: Bool?
}

@MainActor
private func predictionMutationSnapshot(
    _ renderer: GridRenderer
) async -> PredictionMutationSnapshot {
    let scheduler = await renderer.offMainSchedulerSnapshotForTesting()
    let transient = await renderer.offMainTransientSnapshotForTesting()
    return PredictionMutationSnapshot(
        receiptPending: renderer.brushLabInputReceiptPendingForTesting,
        runtimeInputProvenance:
            renderer.strokeRuntimeSnapshot?.inputProvenance,
        eventDiagnostics: renderer.rendererEventDiagnosticsForTesting,
        coordinator:
            renderer.compatibilityInkCoordinatorSnapshotForTesting,
        scheduler: scheduler,
        transient: transient,
        overlay: renderer.predictionOverlay.snapshot,
        activeToken: renderer.activeStroke?.token,
        isFinishedTransiently:
            renderer.activeStroke?.isFinishedTransiently
    )
}

@MainActor
private func drainPredictionActor(
    _ renderer: GridRenderer
) async throws {
    for _ in 0..<20_000 {
        try renderer.drainCompletedInteractiveOperations()
        if renderer.hasPendingOffMainSurfaceLeaseForTesting {
            _ = try renderer.completeNextPendingInteractiveFrame()
            continue
        }
        if let mailbox = renderer.offMainPreparationMailboxSnapshotForTesting,
           mailbox.isQuiescent,
           !renderer.hasSubmittedOffMainSurfaceLeaseForTesting
        {
            return
        }
        await Task.yield()
    }
    throw MetalRendererError.commandFailed(
        "prediction actor drain exceeded its test bound"
    )
}

@MainActor
private func predictionRendererSetup() throws -> PredictionRendererSetup? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue()
    else { return nil }
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
    let library = try device.makeLibrary(
        source: shader.replacingOccurrences(
            of: "#include \"ShaderTypes.h\"",
            with: header
        ),
        options: nil
    )
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
    return PredictionRendererSetup(
        renderer: renderer,
        compiler: BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: profile,
            pipelinePreparing: DepositionPipelineLibrary(
                device: device,
                library: library
            ),
            testHooks: .none
        )
    )
}

private func predictionInputSample(
    x: Float,
    timestamp: TimeInterval,
    phase: StrokePhase,
    kind: StrokeSampleKind = .actual
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: 0.7,
        timestamp: timestamp,
        phase: phase,
        source: .pencil,
        kind: kind,
        capabilities: [.pressure]
    )
}

private func predictionInvalidLifecycleSample(
    x: Float,
    timestamp: TimeInterval,
    phase: StrokePhase,
    kind: StrokeSampleKind,
    estimationUpdateIndex: Int = 120
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: 0.7,
        timestamp: timestamp,
        phase: phase,
        source: .pencil,
        kind: kind,
        capabilities: [.pressure],
        estimationUpdateIndex:
            kind == .estimatedUpdate ? estimationUpdateIndex : nil
    )
}

private func predictionEstimatedSample(
    x: Float,
    timestamp: TimeInterval,
    index: Int
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: 0.7,
        timestamp: timestamp,
        phase: .moved,
        source: .pencil,
        kind: .predicted,
        capabilities: [.pressure],
        estimationUpdateIndex: index,
        estimatedProperties: [.location],
        estimatedPropertiesExpectingUpdates: [.location]
    )
}

private func predictionUnresolvedActualBegan(index: Int) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: 8, y: 32),
        pressure: 0.7,
        timestamp: 0,
        phase: .began,
        source: .pencil,
        capabilities: [.pressure],
        estimationUpdateIndex: index,
        estimatedProperties: [.pressure],
        estimatedPropertiesExpectingUpdates: [.pressure]
    )
}

private func predictionEstimatedUpdateSample(
    x: Float,
    timestamp: TimeInterval,
    index: Int
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: 0.7,
        timestamp: timestamp,
        phase: .moved,
        source: .pencil,
        kind: .estimatedUpdate,
        capabilities: [.pressure],
        estimationUpdateIndex: index,
        estimatedProperties: [],
        estimatedPropertiesExpectingUpdates: []
    )
}

private func predictionEstimatedActualMoved(
    x: Float,
    timestamp: TimeInterval,
    index: Int
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: 0.7,
        timestamp: timestamp,
        phase: .moved,
        source: .pencil,
        capabilities: [.pressure],
        estimationUpdateIndex: index,
        estimatedProperties: [.pressure],
        estimatedPropertiesExpectingUpdates: [.pressure]
    )
}

@MainActor
private func predictionStyle(_ brush: CompiledBrush) -> StrokeRenderStyle {
    StrokeRenderStyle(
        color: .black,
        diameter: 10,
        compositeMode: .draw,
        eraserStrength: 1,
        program: brush.program,
        renderIdentity: brush.renderIdentity,
        seed: 7
    )
}

private func predictionBudget(
    predictedPerFrame: Int,
    authoritativeCapacity: Int,
    predictedCapacity: Int
) throws -> DepositionFrameBudget {
    try DepositionFrameBudget(
        cpuPreparationNanoseconds: 1_000_000,
        maximumAuthoritativeInstances: authoritativeCapacity,
        maximumPredictedInstances: predictedPerFrame,
        maximumPendingAuthoritativeInstances: authoritativeCapacity,
        maximumPendingPredictedInstances: predictedCapacity,
        inFlightUploadBufferCount: 3
    )
}

private func predictionRecord(
    identity: UInt64,
    predicted: Bool
) -> ProjectedDepositionRecord {
    let clip = PatternClipHalfPlane(
        normal: .zero,
        offset: 0,
        padding: 0
    )
    return ProjectedDepositionRecord(
        identity: identity,
        instance: PatternDepositionStampInstance(
            tipFrame0: SIMD4(1, 0, 0, 1),
            tipFrame1: SIMD4(0, 0, 1, 0),
            primaryGrainFrame0: .zero,
            primaryGrainFrame1: .zero,
            secondaryGrainFrame0: .zero,
            secondaryGrainFrame1: .zero,
            premultipliedColor: SIMD4(0, 0, 0, 1),
            coverageInputs: SIMD4(1, 1, 1, 1),
            clip0: clip,
            clip1: clip,
            clip2: clip,
            clip3: clip,
            identity: SIMD4(
                UInt32(truncatingIfNeeded: identity),
                UInt32(truncatingIfNeeded: identity >> 32),
                0,
                predicted ? DepositionIdentityFlags.predicted : 0
            ),
            metadata: SIMD4(0, 0, 0, UInt32(DepositionABI.version)),
            reserved0: .zero,
            reserved1: .zero
        ),
        radialPage: nil
    )
}
