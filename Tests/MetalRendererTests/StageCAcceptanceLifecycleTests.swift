import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Stage C production lifecycle acceptance", .serialized)
struct StageCAcceptanceLifecycleTests {
    @Test
    @MainActor
    func authoritativeBatchPartitionsCommitIdenticalPixels() async throws {
        let movedSamples = [
            stageCAcceptanceSample(.moved, x: 20, y: 8, timestamp: 0.1),
            stageCAcceptanceSample(.moved, x: 20, y: 20, timestamp: 0.2),
            stageCAcceptanceSample(.moved, x: 32, y: 20, timestamp: 0.3),
            stageCAcceptanceSample(.moved, x: 32, y: 32, timestamp: 0.4),
            stageCAcceptanceSample(.moved, x: 44, y: 32, timestamp: 0.5),
        ]
        let partitions = stageCAcceptancePartitions(
            itemCount: movedSamples.count
        )
        #expect(partitions.count == 16)
        var expectedDabs: [LogicalDab]?
        var expectedPixels: [UInt8]?
        guard let setup = try makeDepositionRendererSetup(
            tiling: .grid,
            finite: .plain
        ) else { return }
        let program = try stageCMetalTestProgram(
            id: "test.stage-c.acceptance.pixel-partition",
            usesTravelDirection: true,
            maximumAngularStep: .pi / 8,
            emission: BrushEmissionDefinition(
                mode: .distanceAndTime,
                timeInterval: 0.05
            )
        )
        let brush = try await setup.compileBrush(
            definition: program.definition
        )
        try setup.renderer.activateDrawBrush(brush)
        for (partitionIndex, partition) in partitions.enumerated() {
            let token = RendererOperationToken(
                rawValue: UInt64(121_000 + partitionIndex * 2)
            )
            var dabs: [LogicalDab] = []
            setup.renderer.onLogicalDabsGenerated = { dab in
                if !dab.isPredicted { dabs.append(dab) }
            }
            try setup.renderer.beginStroke(
                token: token,
                sample: stageCAcceptanceSample(
                    .began,
                    x: 8,
                    y: 8,
                    timestamp: 0
                ),
                style: depositionStyle(
                    brush,
                    compositeMode: .draw,
                    diameter: 12
                )
            )
            for group in partition {
                try setup.renderer.appendStrokeBatch(
                    token: token,
                    samples: Array(movedSamples[group])
                )
            }
            try setup.renderer.requestStrokeCommit(
                token: token,
                sample: stageCAcceptanceSample(
                    .ended,
                    x: 44,
                    y: 44,
                    timestamp: 0.6
                ),
                maximumRetainedBytes: 4_000_000
            )
            try await prepareOffMainCommit(setup.renderer)
            _ = try setup.renderer.finishCommitForHarness()
            try await awaitOffMainWorkspaceAvailable(setup.renderer)
            setup.renderer.onLogicalDabsGenerated = nil
            let pixels = depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            )

            #expect(!dabs.isEmpty)
            #expect(pixels.contains { $0 != 0 })
            if let expectedDabs, let expectedPixels {
                #expect(dabs == expectedDabs)
                #expect(pixels == expectedPixels)
            } else {
                expectedDabs = dabs
                expectedPixels = pixels
            }
            await expectProductionRendererClean(
                setup.renderer,
                mode: StageCAcceptanceMode(
                    label: "partition-\(partitionIndex)",
                    finite: .plain
                )
            )
            if partitionIndex != partitions.indices.last {
                try setup.renderer.requestClearForHarness(
                    token: RendererOperationToken(
                        rawValue: UInt64(121_001 + partitionIndex * 2)
                    ),
                    maximumRetainedBytes: 4_000_000,
                    forceFailure: false
                )
                try setup.renderer.finishRasterOperationForHarness()
                #expect(
                    !depositionTextureBytes(
                        try setup.renderer.copyCanonicalForHarness()
                    ).contains { $0 != 0 }
                )
            }
        }
    }

    @Test
    @MainActor
    func plainSeamlessAndRadialExerciseTheCompleteProductionLifecycle()
        async throws
    {
        for (index, mode) in StageCAcceptanceMode.all.enumerated() {
            try await exerciseProductionLifecycle(
                mode,
                tokenBase: UInt64(120_000 + index * 100)
            )
        }
    }

    @MainActor
    private func exerciseProductionLifecycle(
        _ mode: StageCAcceptanceMode,
        tokenBase: UInt64
    ) async throws {
        guard let setup = try mode.makeSetup() else { return }
        let primaryProgram = try stageCMetalTestProgram(
            id: "test.stage-c.acceptance.\(mode.label).primary"
        )
        let replacementProgram = try stageCMetalTestProgram(
            id: "test.stage-c.acceptance.\(mode.label).replacement",
            replayMode: .appendOnly
        )
        let primaryBrush = try await setup.compileBrush(
            definition: primaryProgram.definition
        )
        let replacementBrush = try await setup.compileBrush(
            definition: replacementProgram.definition
        )
        try setup.renderer.activateDrawBrush(primaryBrush)
        var tokens = StageCAcceptanceTokenSource(nextRawValue: tokenBase)

        let emptyPixels = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        #expect(!emptyPixels.contains { $0 != 0 }, Comment(rawValue: mode.label))

        // Begin + actual append + prediction + estimate + finish/commit.
        // Draining before finish leaves the coordinator alive so the legacy
        // synchronous-replay counter is an observable production assertion.
        var actualDabCount = 0
        var predictedDabCount = 0
        setup.renderer.onLogicalDabsGenerated = { dab in
            if dab.isPredicted {
                predictedDabCount += 1
            } else {
                actualDabCount += 1
            }
        }
        let richToken = tokens.take()
        let estimateIndex = Int(tokenBase)
        try setup.renderer.beginStroke(
            token: richToken,
            sample: depositionCorrectionSample(
                phase: .began,
                kind: .actual,
                x: 10,
                pressure: 0.2,
                timestamp: 1,
                altitude: 0.5,
                azimuth: 0.75,
                estimationUpdateIndex: estimateIndex,
                estimatedProperties: .pressure,
                expecting: .pressure
            ),
            style: depositionStyle(
                primaryBrush,
                compositeMode: .draw,
                diameter: 10
            )
        )
        try setup.renderer.appendStroke(
            token: richToken,
            sample: depositionSample(.moved, x: 28, y: 24)
        )
        try setup.renderer.appendStroke(
            token: richToken,
            sample: depositionPredictedSample(x: 42)
        )
        try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 0
        )
        #expect(actualDabCount > 0, Comment(rawValue: mode.label))
        #expect(predictedDabCount > 0, Comment(rawValue: mode.label))
        try setup.renderer.applyEstimatedStrokeUpdate(
            token: richToken,
            sample: depositionCorrectionSample(
                phase: .moved,
                kind: .estimatedUpdate,
                x: 10,
                pressure: 0.85,
                timestamp: 2,
                altitude: 0.5,
                azimuth: 0.75,
                estimationUpdateIndex: estimateIndex,
                estimatedProperties: [],
                expecting: []
            )
        )
        try await drainOffMainPreparedFrames(
            setup.renderer,
            minimumFrameCount: 0
        )
        let activeScheduler = await setup.renderer
            .offMainSchedulerSnapshotForTesting()
        #expect(
            activeScheduler.synchronousCompatibilityReplayInvocationCount == 0,
            Comment(rawValue: "\(mode.label): legacy renderer entered")
        )

        try setup.renderer.requestStrokeCommit(
            token: richToken,
            sample: depositionSample(.ended, x: 54, y: 24),
            maximumRetainedBytes: 4_000_000
        )
        try await prepareOffMainCommit(setup.renderer)
        _ = try setup.renderer.finishCommitForHarness()
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        setup.renderer.onLogicalDabsGenerated = nil
        let richPixels = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        #expect(richPixels != emptyPixels, Comment(rawValue: mode.label))
        #expect(richPixels.contains { $0 != 0 }, Comment(rawValue: mode.label))
        await expectProductionRendererClean(setup.renderer, mode: mode)

        // Cancel must discard actual and speculative work without changing the
        // committed raster, then leave the same workspace immediately reusable.
        let cancelToken = tokens.take()
        try setup.renderer.beginStroke(
            token: cancelToken,
            sample: depositionSample(.began, x: 14, y: 40),
            style: depositionStyle(
                primaryBrush,
                compositeMode: .draw,
                diameter: 8,
                color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!
            )
        )
        try setup.renderer.appendStroke(
            token: cancelToken,
            sample: depositionSample(.moved, x: 46, y: 40)
        )
        try setup.renderer.appendStroke(
            token: cancelToken,
            sample: depositionPredictedSample(x: 52)
        )
        try setup.renderer.cancelStroke(token: cancelToken)
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == richPixels,
            Comment(rawValue: "\(mode.label): cancel changed committed pixels")
        )
        await expectProductionRendererClean(setup.renderer, mode: mode)

        // Inject a real off-main surface failure, then switch brush and reuse
        // immediately. Failure must be atomic; successful reuse must commit.
        setup.renderer.setForceOffMainStrokeCommandFailureForTesting(true)
        let failureToken = tokens.take()
        try setup.renderer.beginStroke(
            token: failureToken,
            sample: depositionSample(.began, x: 12, y: 50),
            style: depositionStyle(
                primaryBrush,
                compositeMode: .draw,
                diameter: 8
            )
        )
        try setup.renderer.requestStrokeCommit(
            token: failureToken,
            sample: depositionSample(.ended, x: 32, y: 50),
            maximumRetainedBytes: 4_000_000
        )
        #expect(throws: MetalRendererError.self) {
            _ = try setup.renderer.finishCommitForHarness()
        }
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == richPixels,
            Comment(rawValue: "\(mode.label): injected failure mutated pixels")
        )
        await expectProductionRendererClean(setup.renderer, mode: mode)

        setup.renderer.setForceOffMainStrokeCommandFailureForTesting(false)
        try setup.renderer.activateDrawBrush(replacementBrush)
        let reuseToken = tokens.take()
        try setup.renderer.beginStroke(
            token: reuseToken,
            sample: depositionSample(.began, x: 18, y: 48),
            style: depositionStyle(
                replacementBrush,
                compositeMode: .draw,
                diameter: 8,
                color: InkColor(red: 0, green: 0, blue: 1, alpha: 1)!
            )
        )
        try setup.renderer.appendStroke(
            token: reuseToken,
            sample: depositionSample(.moved, x: 44, y: 48)
        )
        try setup.renderer.requestStrokeCommit(
            token: reuseToken,
            sample: depositionSample(.ended, x: 52, y: 48),
            maximumRetainedBytes: 4_000_000
        )
        try await prepareOffMainCommit(setup.renderer)
        _ = try setup.renderer.finishCommitForHarness()
        try await awaitOffMainWorkspaceAvailable(setup.renderer)
        let reusedPixels = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        #expect(reusedPixels != richPixels, Comment(rawValue: mode.label))
        await expectProductionRendererClean(setup.renderer, mode: mode)

        // Resize, undo and redo must restore exact dimensions and bytes.
        var receipts: [RendererOperationToken: RasterMutationReceipt] = [:]
        setup.renderer.onOperationCompleted = { completion in
            if case let .rasterSuccess(receipt) = completion {
                receipts[receipt.token] = receipt
            }
        }
        let resizeToken = tokens.take()
        let resizedSize = PixelSize(width: 80, height: 72)
        try setup.renderer.requestResizeForHarness(
            token: resizeToken,
            to: resizedSize,
            maximumRetainedBytes: 4_000_000,
            forceResourceAllocationFailure: false
        )
        try setup.renderer.finishRasterOperationForHarness()
        let resizeReceipt = try #require(receipts[resizeToken])
        let resizedPixels = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        #expect(setup.renderer.pixelSize == resizedSize)
        #expect(resizedPixels != reusedPixels, Comment(rawValue: mode.label))
        await expectProductionRendererClean(setup.renderer, mode: mode)

        try setup.renderer.requestResizeRestoreForHarness(
            token: tokens.take(),
            revision: resizeReceipt.before,
            forceCommandFailure: false
        )
        try setup.renderer.finishRasterOperationForHarness()
        #expect(setup.renderer.pixelSize == PixelSize(width: 64, height: 64))
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == reusedPixels,
            Comment(rawValue: "\(mode.label): resize undo mismatch")
        )
        await expectProductionRendererClean(setup.renderer, mode: mode)

        try setup.renderer.requestResizeRestoreForHarness(
            token: tokens.take(),
            revision: resizeReceipt.after,
            forceCommandFailure: false
        )
        try setup.renderer.finishRasterOperationForHarness()
        #expect(setup.renderer.pixelSize == resizedSize)
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == resizedPixels,
            Comment(rawValue: "\(mode.label): resize redo mismatch")
        )
        await expectProductionRendererClean(setup.renderer, mode: mode)

        // Clear, undo and redo operate at the resized dimensions and restore
        // exact committed bytes rather than merely publishing completion calls.
        let clearToken = tokens.take()
        try setup.renderer.requestClearForHarness(
            token: clearToken,
            maximumRetainedBytes: 4_000_000,
            forceFailure: false
        )
        try setup.renderer.finishRasterOperationForHarness()
        let clearReceipt = try #require(receipts[clearToken])
        let clearedPixels = depositionTextureBytes(
            try setup.renderer.copyCanonicalForHarness()
        )
        #expect(!clearedPixels.contains { $0 != 0 }, Comment(rawValue: mode.label))
        await expectProductionRendererClean(setup.renderer, mode: mode)

        try setup.renderer.requestRasterRestoreForHarness(
            token: tokens.take(),
            revision: clearReceipt.before,
            forceFailure: false
        )
        try setup.renderer.finishRasterOperationForHarness()
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == resizedPixels,
            Comment(rawValue: "\(mode.label): clear undo mismatch")
        )
        await expectProductionRendererClean(setup.renderer, mode: mode)

        try setup.renderer.requestRasterRestoreForHarness(
            token: tokens.take(),
            revision: clearReceipt.after,
            forceFailure: false
        )
        try setup.renderer.finishRasterOperationForHarness()
        #expect(
            depositionTextureBytes(
                try setup.renderer.copyCanonicalForHarness()
            ) == clearedPixels,
            Comment(rawValue: "\(mode.label): clear redo mismatch")
        )
        await expectProductionRendererClean(setup.renderer, mode: mode)

        setup.renderer.releaseRasterRevisions([
            resizeReceipt.before.id,
            resizeReceipt.after.id,
            clearReceipt.before.id,
            clearReceipt.after.id,
        ])
        setup.renderer.onOperationCompleted = nil
    }

    @MainActor
    private func expectProductionRendererClean(
        _ renderer: GridRenderer,
        mode: StageCAcceptanceMode
    ) async {
        let scheduler = await renderer.offMainSchedulerSnapshotForTesting()
        #expect(renderer.isIdle, Comment(rawValue: mode.label))
        #expect(!renderer.hasActiveStroke, Comment(rawValue: mode.label))
        #expect(!renderer.hasPendingRasterOperationForTesting)
        #expect(!renderer.hasPendingOffMainSurfaceLeaseForTesting)
        #expect(!renderer.hasSubmittedOffMainSurfaceLeaseForTesting)
        #expect(!renderer.hasCurrentOffMainSurfaceLeaseForTesting)
        #expect(renderer.offMainStrokeWorkspaceIsAvailableForTesting)
        #expect(renderer.harnessReservedInstanceBufferCount == 0)
        #expect(scheduler.activeGeneration == nil)
        #expect(scheduler.authoritativePending == 0)
        #expect(scheduler.predictedPending == 0)
        #expect(!scheduler.frameOutstanding)
        #expect(!scheduler.authoritativeCandidateContinuationPending)
        #expect(scheduler.synchronousCompatibilityReplayInvocationCount == 0)
    }
}

private struct StageCAcceptanceMode: Sendable {
    let label: String
    let finite: FiniteSymmetryConfiguration?

    static let all: [Self] = [
        Self(label: "seamless", finite: nil),
        Self(label: "plain", finite: .plain),
        Self(
            label: "radial",
            finite: .radial(
                RadialSymmetryConfiguration(
                    kind: .mandala,
                    rayCount: 8,
                    center: WorldPoint(x: 32, y: 32)
                )
            )
        ),
    ]

    @MainActor
    func makeSetup() throws -> DepositionRendererSetup? {
        try makeDepositionRendererSetup(
            tiling: .grid,
            finite: finite
        )
    }
}

private struct StageCAcceptanceTokenSource {
    private(set) var nextRawValue: UInt64

    mutating func take() -> RendererOperationToken {
        defer { nextRawValue += 1 }
        return RendererOperationToken(rawValue: nextRawValue)
    }
}

private func stageCAcceptanceSample(
    _ phase: StrokePhase,
    x: Float,
    y: Float,
    timestamp: TimeInterval
) -> StrokeSample {
    .mouse(
        position: ScreenPoint(x: x, y: y),
        timestamp: timestamp,
        phase: phase
    )
}

private func stageCAcceptancePartitions(
    itemCount: Int
) -> [[Range<Int>]] {
    precondition(itemCount > 0 && itemCount < Int.bitWidth)
    let boundaryCount = itemCount - 1
    return (0..<(1 << boundaryCount)).map { mask in
        var groups: [Range<Int>] = []
        var start = 0
        for boundary in 0..<boundaryCount where mask & (1 << boundary) != 0 {
            groups.append(start..<(boundary + 1))
            start = boundary + 1
        }
        groups.append(start..<itemCount)
        return groups
    }
}
