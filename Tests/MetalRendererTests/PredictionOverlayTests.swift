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
        let authoritativeBefore = try #require(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
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

        #expect(
            setup.renderer.transientStrokeBuffer?.predictedSampleCount
                == 64
        )
        #expect(
            setup.renderer.predictionOverlay.snapshot.lastOverload
                .contains(.normalizedSamples)
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

        #expect(
            setup.renderer.transientStrokeBuffer?.predictedSampleCount
                == 64
        )
        #expect(
            setup.renderer.predictionOverlay.snapshot.lastOverload
                .contains(.normalizedSamples)
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

        #expect(
            setup.renderer.transientStrokeBuffer?.predictedDabCount == 512
        )
        #expect(
            setup.renderer.predictionOverlay.snapshot
                .projectedInstanceCount
                == setup.renderer.harnessScheduledPredictedRecords.count
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

        #expect(
            setup.renderer.transientStrokeBuffer?.predictedDabCount == 512
        )
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
                == setup.renderer.harnessScheduledPredictedRecords.count
        )
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
        let coordinatorBefore = try #require(
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
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
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
                == coordinatorBefore
        )
        #expect(setup.renderer.transientStrokeBuffer == bufferBefore)
        #expect(
            setup.renderer.harnessTransientDabArenaSnapshot == arenaBefore
        )
        #expect(
            setup.renderer.harnessScheduledAuthoritativeRecords
                == authoritativeBefore
        )
        #expect(
            setup.renderer.harnessScheduledPredictedRecords == predictedBefore
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
            setup.renderer.compatibilityInkCoordinatorSnapshotForTesting
                == coordinatorBefore
        )
        #expect(setup.renderer.transientStrokeBuffer == bufferBefore)
        #expect(
            setup.renderer.harnessTransientDabArenaSnapshot == arenaBefore
        )
        #expect(
            setup.renderer.harnessScheduledAuthoritativeRecords
                == authoritativeBefore
        )
        #expect(
            setup.renderer.harnessScheduledPredictedRecords == predictedBefore
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
        #expect(
            setup.renderer.harnessScheduledPredictedRecords
                .contains { $0.isPredicted }
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

        #expect(
            setup.renderer.harnessScheduledPredictedRecords
                .allSatisfy { !$0.isPredicted }
        )
        #expect(
            setup.renderer.harnessScheduledAuthoritativeRecords
                .allSatisfy { !$0.isPredicted }
        )
        #expect(
            setup.renderer.transientStrokeBuffer?.predictedSampleCount == 0
        )
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

    func compileReplayTail() async throws -> CompiledBrush {
        let recipe = try BrushRecipe(
            id: BrushRecipeID("brush.prediction-overlay-replay-tail"),
            replayMode: .replayTail,
            replayLimits: BrushRecipePolicy.replayTailLimits
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
