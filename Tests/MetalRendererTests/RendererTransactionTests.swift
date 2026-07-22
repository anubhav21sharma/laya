import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

private let drawStyle = StrokeRenderStyle(
    color: InkColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.8)!,
    diameter: 20,
    compositeMode: .draw,
    eraserStrength: 1
)

private func strokeSample(
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

@Test
@MainActor
func earlyHarnessReleaseDoesNotHoldTheNextFrameOutcome() {
    let mailbox = GridRenderCompletionMailbox()
    mailbox.deferNextForHarness()
    mailbox.releaseDeferredForHarness()
    mailbox.push(
        .init(
            operationToken: nil,
            rasterCommit: nil,
            uploadSubmissions: [],
            succeeded: true,
            errorMessage: nil
        )
    )

    #expect(mailbox.drain().count == 1)
}

@MainActor
private func makeRenderer() throws -> GridRenderer? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let shaderURL = root
        .appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    let headerURL = root
        .appendingPathComponent(
            "Sources/CShaderTypes/include/ShaderTypes.h"
        )
    let shader = try String(contentsOf: shaderURL, encoding: .utf8)
    let header = try String(contentsOf: headerURL, encoding: .utf8)
    let source = shader.replacingOccurrences(
        of: "#include \"ShaderTypes.h\"",
        with: header
    )
    let library = try device.makeLibrary(source: source, options: nil)
    return try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 64, height: 64),
        configuration: TilingCanvasConfiguration(
            pixelSize: PixelSize(width: 64, height: 64),
            tiling: .grid
        )
    )
}

@Test
@MainActor
func rendererRejectsMismatchedAppendCommitAndCancelTokens() throws {
    guard let renderer = try makeRenderer() else { return }
    let accepted = RendererOperationToken(rawValue: 41)
    let mismatched = RendererOperationToken(rawValue: 42)
    try renderer.beginStroke(
        token: accepted,
        sample: strokeSample(.began),
        style: drawStyle
    )

    #expect(throws: MetalRendererError.invalidRendererOperationToken) {
        try renderer.appendStroke(
            token: mismatched,
            sample: strokeSample(.moved)
        )
    }
    #expect(throws: MetalRendererError.invalidRendererOperationToken) {
        try renderer.requestStrokeCommit(
            token: mismatched,
            sample: strokeSample(.ended),
            maximumRetainedBytes: 1_000_000
        )
    }
    #expect(throws: MetalRendererError.invalidRendererOperationToken) {
        try renderer.cancelStroke(token: mismatched)
    }

    #expect(renderer.hasActiveStroke)
    try renderer.cancelStroke(token: accepted)
    #expect(renderer.isIdle)
}

@Test
@MainActor
func submittedCommitPublishesExactlyOneReceiptOnlyAfterCompletionDrain()
    throws
{
    guard let renderer = try makeRenderer() else { return }
    let token = RendererOperationToken(rawValue: 7)
    var completions: [RendererOperationCompletion] = []
    renderer.onOperationCompleted = { completions.append($0) }
    let initialRevision = renderer.harnessRevision

    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began),
        style: drawStyle
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: strokeSample(.ended, x: 40),
        maximumRetainedBytes: 1_000_000
    )
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.submitCommitForHarness()

    #expect(!renderer.isIdle)
    #expect(completions.isEmpty)
    #expect(renderer.harnessRevision == initialRevision)

    try renderer.drainCompletedOperationsForHarness()

    #expect(renderer.isIdle)
    #expect(renderer.harnessRevision == initialRevision.advanced())
    #expect(completions.count == 1)
    guard case let .rasterSuccess(receipt) = completions.first else {
        Issue.record("Expected one raster success receipt")
        return
    }
    #expect(receipt.token == token)
    #expect(receipt.before.pixelSize == PixelSize(width: 64, height: 64))
    #expect(receipt.before.regions == receipt.after.regions)
    #expect(!receipt.before.regions.rectangles.isEmpty)
    #expect(
        renderer.harnessRasterRevisionResidentBytes
            == receipt.before.retainedBytes + receipt.after.retainedBytes
    )

    renderer.releaseRasterRevisions([receipt.before.id, receipt.after.id])
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
}

@Test
@MainActor
func submittedCommitAloneOwnsTerminalStateAfterLaterDisplayFailure() throws {
    guard let renderer = try makeRenderer() else { return }
    let token = RendererOperationToken(rawValue: 8)
    var completions: [RendererOperationCompletion] = []
    var reportedErrors: [MetalRendererError] = []
    renderer.onOperationCompleted = { completions.append($0) }
    renderer.onError = { reportedErrors.append($0) }
    let initialSnapshot = renderer.harnessTilingMutationSnapshot

    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began),
        style: drawStyle
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: strokeSample(.ended, x: 40),
        maximumRetainedBytes: 1_000_000
    )
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.submitCommitForHarness()
    let provisionalBytes = renderer.harnessRasterRevisionResidentBytes

    try renderer.submitDisplayOnlyForHarness(forceFailure: true)
    renderer.prioritizeLatestFrameOutcomeForHarness()

    #expect(
        throws: MetalRendererError.commandFailed(
            "injected harness command-buffer failure"
        )
    ) {
        try renderer.drainNextCompletedOperationForHarness()
    }

    #expect(!renderer.isIdle)
    #expect(completions.isEmpty)
    #expect(renderer.harnessRevision == initialSnapshot.revision)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == initialSnapshot.canonicalFront
    )
    #expect(renderer.harnessRasterRevisionResidentBytes == provisionalBytes)
    #expect(reportedErrors.count == 1)

    try renderer.drainCompletedOperationsForHarness()

    #expect(renderer.isIdle)
    #expect(renderer.harnessRevision == initialSnapshot.revision.advanced())
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == initialSnapshot.canonicalScratch
    )
    #expect(completions.count == 1)
    guard case let .rasterSuccess(receipt) = completions.first else {
        Issue.record("Expected exactly one eventual raster success")
        return
    }
    #expect(receipt.token == token)
    #expect(
        renderer.harnessRasterRevisionResidentBytes
            == receipt.before.retainedBytes + receipt.after.retainedBytes
    )

    renderer.releaseRasterRevisions([receipt.before.id, receipt.after.id])
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
}

@Test
@MainActor
func delayedPrecommitFrameFailureBlocksCommitAndTerminatesExactlyOnce() throws {
    guard let renderer = try makeRenderer() else { return }
    let token = RendererOperationToken(rawValue: 81)
    var completions: [RendererOperationCompletion] = []
    renderer.onOperationCompleted = { completions.append($0) }
    let initialSnapshot = renderer.harnessTilingMutationSnapshot

    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began),
        style: drawStyle
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: strokeSample(.ended, x: 40),
        maximumRetainedBytes: 1_000_000
    )

    renderer.deferNextFrameOutcomeForHarness()
    _ = try renderer.flushPendingLiveForHarness(forceFailure: true)

    do {
        _ = try renderer.submitCommitForHarness()
        Issue.record(
            "Commit submitted before its token-bearing predecessor drained"
        )
        return
    } catch let error as MetalRendererError {
        #expect(error == .invalidStrokeLifecycle)
    }

    #expect(!renderer.isIdle)
    #expect(completions.isEmpty)
    #expect(renderer.harnessRevision == initialSnapshot.revision)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == initialSnapshot.canonicalFront
    )
    #expect(renderer.harnessRasterRevisionResidentBytes > 0)

    renderer.releaseDeferredFrameOutcomesForHarness()
    #expect(
        throws: MetalRendererError.commandFailed(
            "injected harness command-buffer failure"
        )
    ) {
        try renderer.drainCompletedOperationsForHarness()
    }

    #expect(renderer.isIdle)
    #expect(renderer.harnessRevision == initialSnapshot.revision)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == initialSnapshot.canonicalFront
    )
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
    #expect(renderer.harnessReservedInstanceBufferCount == 0)
    #expect(renderer.harnessTilingMutationSnapshot.pendingInstanceCount == 0)
    #expect(renderer.harnessTilingMutationSnapshot.bakedHighWater == 0)
    #expect(renderer.harnessTilingMutationSnapshot.emittedHighWater == 0)
    #expect(completions.count == 1)
    guard case let .failure(completedToken, _) = completions.first else {
        Issue.record("Expected exactly one terminal failure")
        return
    }
    #expect(completedToken == token)
}

@Test
@MainActor
func submittedFailureReturnsNoReceiptAndRetainsCanonicalFront() throws {
    guard let renderer = try makeRenderer() else { return }
    let token = RendererOperationToken(rawValue: 9)
    var completions: [RendererOperationCompletion] = []
    renderer.onOperationCompleted = { completions.append($0) }
    let initialSnapshot = renderer.harnessTilingMutationSnapshot

    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began),
        style: drawStyle
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: strokeSample(.ended, x: 40),
        maximumRetainedBytes: 1_000_000
    )
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.submitCommitForHarness(forceFailure: true)

    #expect(completions.isEmpty)
    #expect(
        throws: MetalRendererError.commandFailed(
            "injected harness command-buffer failure"
        )
    ) {
        try renderer.drainCompletedOperationsForHarness()
    }

    #expect(renderer.isIdle)
    #expect(renderer.harnessRevision == initialSnapshot.revision)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == initialSnapshot.canonicalFront
    )
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
    #expect(completions.count == 1)
    guard case let .failure(completedToken, _) = completions.first else {
        Issue.record("Expected one renderer failure")
        return
    }
    #expect(completedToken == token)
}

@Test
@MainActor
func failedLiveUploadTerminatesOperationAndReclaimsTransientState() throws {
    guard let renderer = try makeRenderer() else { return }
    let token = RendererOperationToken(rawValue: 10)
    var completions: [RendererOperationCompletion] = []
    renderer.onOperationCompleted = { completions.append($0) }
    let initialSnapshot = renderer.harnessTilingMutationSnapshot

    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began),
        style: drawStyle
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: strokeSample(.ended, x: 40),
        maximumRetainedBytes: 1_000_000
    )
    #expect(renderer.harnessRasterRevisionResidentBytes > 0)

    #expect(
        throws: MetalRendererError.commandFailed(
            "injected harness command-buffer failure"
        )
    ) {
        _ = try renderer.flushPendingLiveForHarness(forceFailure: true)
    }

    #expect(renderer.isIdle)
    #expect(renderer.harnessRevision == initialSnapshot.revision)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == initialSnapshot.canonicalFront
    )
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
    #expect(renderer.harnessReservedInstanceBufferCount == 0)
    #expect(renderer.harnessTilingMutationSnapshot.pendingInstanceCount == 0)
    #expect(renderer.harnessTilingMutationSnapshot.bakedHighWater == 0)
    #expect(renderer.harnessTilingMutationSnapshot.emittedHighWater == 0)
    #expect(completions.count == 1)
    guard case let .failure(completedToken, _) = completions.first else {
        Issue.record("Expected one renderer failure and no raster receipt")
        return
    }
    #expect(completedToken == token)
}

@Test
@MainActor
func historyLimitFailureCleansProvisionalRevisionsBeforeSubmission() throws {
    guard let renderer = try makeRenderer() else { return }
    let token = RendererOperationToken(rawValue: 11)
    let initialSnapshot = renderer.harnessTilingMutationSnapshot

    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began),
        style: drawStyle
    )
    #expect(throws: MetalRendererError.rasterRevisionStorageLimitExceeded) {
        try renderer.requestStrokeCommit(
            token: token,
            sample: strokeSample(.ended, x: 40),
            maximumRetainedBytes: 0
        )
    }

    #expect(renderer.isIdle)
    #expect(renderer.harnessRevision == initialSnapshot.revision)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == initialSnapshot.canonicalFront
    )
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
}

@Test
@MainActor
func strokeBeginCapturesDiameterColorAndCompositeMode() throws {
    guard let renderer = try makeRenderer() else { return }
    let drawToken = RendererOperationToken(rawValue: 21)
    let capturedDraw = StrokeRenderStyle(
        color: InkColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)!,
        diameter: 40,
        compositeMode: .draw,
        eraserStrength: 1
    )

    try renderer.beginStroke(
        token: drawToken,
        sample: strokeSample(.began),
        style: capturedDraw
    )

    #expect(renderer.harnessInterpolatorSpacing == 5)
    #expect(renderer.harnessCompositeMode == .draw)
    #expect(
        renderer.harnessPendingInstanceColors.allSatisfy {
            $0 == capturedDraw.color.simd
        }
    )
    try renderer.cancelStroke(token: drawToken)

    let eraseToken = RendererOperationToken(rawValue: 22)
    let capturedErase = StrokeRenderStyle(
        color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!,
        diameter: 12,
        compositeMode: .erase,
        eraserStrength: 0.35
    )
    try renderer.beginStroke(
        token: eraseToken,
        sample: strokeSample(.began),
        style: capturedErase
    )

    #expect(renderer.harnessCompositeMode == .erase)
    #expect(
        renderer.harnessPendingInstanceColors.allSatisfy {
            $0 == SIMD4<Float>(0, 0, 0, 1)
        }
    )
    try renderer.cancelStroke(token: eraseToken)
}

@Test
@MainActor
func lowPressureAnisotropicDabPreservesItsTrueSubpixelScale() throws {
    guard let renderer = try makeRenderer() else { return }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.subpixel-affine-scale"),
        aspectRatio: 0.25,
        sizeMapping: .linear(input: .pressure, output: 0.1...1)
    )
    let token = RendererOperationToken(rawValue: 220)
    try renderer.beginStroke(
        token: token,
        sample: StrokeSample(
            position: ScreenPoint(x: 32, y: 32),
            pressure: 0,
            timestamp: 0,
            phase: .began,
            source: .pencil,
            capabilities: [.pressure]
        ),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 8,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 220
        )
    )

    let radii = renderer.liveStroke.pending.map(\.instance.radius)
    #expect(!radii.isEmpty)
    #expect(radii.allSatisfy { abs($0 - 0.1) < 0.0001 })
    try renderer.cancelStroke(token: token)
}

@Test
@MainActor
func replayableEventDabGenerationFailsAtDeclaredBoundWithoutMutation() throws {
    guard let renderer = try makeRenderer() else { return }
    let limits = BrushReplayLimits(
        maximumSamples: 16,
        maximumDabs: 8,
        maximumProjectedInstances: 128
    )
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.event-dab-bound"),
        replayMode: .replayTail,
        replayLimits: limits
    )
    let token = RendererOperationToken(rawValue: 221)
    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began, x: 16),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 2,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 221
        )
    )
    let bufferBefore = try #require(renderer.transientStrokeBuffer)
    let generatorBefore = try #require(renderer.strokeGenerator)

    #expect(throws: MetalRendererError.generatedDabCapacityExceeded(8)) {
        try renderer.appendStroke(
            token: token,
            sample: strokeSample(.moved, x: 48)
        )
    }

    #expect(renderer.transientStrokeBuffer == bufferBefore)
    #expect(renderer.strokeGenerator == generatorBefore)
    #expect(renderer.liveStroke.pending.count <= 128)
    try renderer.cancelStroke(token: token)
}

@Test
@MainActor
func replayTailReplacesPredictionAndAppliesEndTaperBeforeCommit() throws {
    guard let renderer = try makeRenderer() else { return }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.replay-taper"),
        taper: BrushTaperConfiguration(
            start: .disabled,
            end: .worldPixels(12),
            minimumSize: 0.2,
            minimumFlow: 0.25,
            effects: [.size, .flow]
        ),
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    let style = StrokeRenderStyle(
        color: .black,
        diameter: 20,
        compositeMode: .draw,
        eraserStrength: 1,
        recipe: recipe,
        seed: 900
    )
    let token = RendererOperationToken(rawValue: 900)
    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began, x: 16),
        style: style
    )
    try renderer.appendStroke(
        token: token,
        sample: StrokeSample(
            position: ScreenPoint(x: 48, y: 32),
            pressure: 0.5,
            timestamp: 1,
            phase: .moved,
            source: .mouse,
            kind: .predicted
        )
    )
    let predictedEpoch = renderer.replayStroke.renderEpoch
    #expect(renderer.transientStrokeBuffer?.predictedSampleCount == 1)

    try renderer.appendStroke(
        token: token,
        sample: StrokeSample(
            position: ScreenPoint(x: 40, y: 32),
            pressure: 0.5,
            timestamp: 2,
            phase: .moved,
            source: .mouse
        )
    )
    #expect(renderer.transientStrokeBuffer?.predictedSampleCount == 0)
    #expect(renderer.replayStroke.renderEpoch > predictedEpoch)

    try renderer.requestStrokeCommit(
        token: token,
        sample: StrokeSample(
            position: ScreenPoint(x: 52, y: 32),
            pressure: 0.5,
            timestamp: 3,
            phase: .ended,
            source: .mouse
        ),
        maximumRetainedBytes: 1_000_000
    )
    let radii = renderer.replayStroke.pending.map(\.instance.radius)
    #expect(radii.count > 2)
    let endRadius = try #require(radii.last)
    let precedingMaximum = try #require(radii.dropLast().max())
    #expect(endRadius < precedingMaximum)

    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.submitCommitForHarness()
    try renderer.drainCompletedOperationsForHarness()
    #expect(renderer.isIdle)
}

@Test
@MainActor
func predictedBatchChainsAndAtomicallyReplacesTheWholeSuffix() throws {
    guard let renderer = try makeRenderer() else { return }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.predicted-batch"),
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    let token = RendererOperationToken(rawValue: 9010)
    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began, x: 12),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 16,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 9010
        )
    )
    let authoritativeDabCount = try #require(renderer.strokeGenerator)
        .emittedDabCount
    let epochBeforeFirstBatch = try #require(renderer.transientStrokeBuffer)
        .replayEpoch

    try renderer.appendStrokeBatch(
        token: token,
        samples: [
            StrokeSample(
                position: ScreenPoint(x: 24, y: 32),
                pressure: 0.5,
                timestamp: 1,
                phase: .moved,
                source: .mouse,
                kind: .predicted
            ),
            StrokeSample(
                position: ScreenPoint(x: 40, y: 32),
                pressure: 0.5,
                timestamp: 2,
                phase: .moved,
                source: .mouse,
                kind: .predicted
            ),
        ]
    )

    let firstSuffix = try #require(renderer.transientStrokeBuffer)
    #expect(firstSuffix.predictedSampleCount == 2)
    #expect(firstSuffix.replayEpoch == epochBeforeFirstBatch + 1)
    #expect(firstSuffix.predictedSamples.map(\.position) == [
        WorldPoint(x: 24, y: 32),
        WorldPoint(x: 40, y: 32),
    ])
    #expect(renderer.strokeGenerator?.emittedDabCount == authoritativeDabCount)
    #expect(
        renderer.predictedStrokeGenerator?.emittedDabCount
            ?? 0 > authoritativeDabCount
    )

    let epochBeforeReplacement = firstSuffix.replayEpoch
    try renderer.appendStrokeBatch(
        token: token,
        samples: [
            StrokeSample(
                position: ScreenPoint(x: 30, y: 32),
                pressure: 0.5,
                timestamp: 1.5,
                phase: .moved,
                source: .mouse,
                kind: .predicted
            ),
            StrokeSample(
                position: ScreenPoint(x: 34, y: 32),
                pressure: 0.5,
                timestamp: 2,
                phase: .moved,
                source: .mouse,
                kind: .predicted
            ),
        ]
    )
    let replacementSuffix = try #require(renderer.transientStrokeBuffer)
    #expect(replacementSuffix.predictedSampleCount == 2)
    #expect(replacementSuffix.replayEpoch == epochBeforeReplacement + 1)
    #expect(replacementSuffix.predictedSamples.map(\.position) == [
        WorldPoint(x: 30, y: 32),
        WorldPoint(x: 34, y: 32),
    ])

    try renderer.appendStroke(
        token: token,
        sample: strokeSample(.moved, x: 28)
    )
    #expect(renderer.transientStrokeBuffer?.predictedSampleCount == 0)
    #expect(renderer.predictedStrokeGenerator == nil)
    try renderer.cancelStroke(token: token)
}

@Test
@MainActor
func failedPredictedBatchLeavesThePriorSuffixUntouched() throws {
    guard let renderer = try makeRenderer() else { return }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.predicted-batch-rollback"),
        replayMode: .replayTail,
        replayLimits: BrushReplayLimits(
            maximumSamples: 16,
            maximumDabs: 6,
            maximumProjectedInstances: 128
        )
    )
    let token = RendererOperationToken(rawValue: 9011)
    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began, x: 16),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 2,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 9011
        )
    )
    try renderer.appendStroke(
        token: token,
        sample: StrokeSample(
            position: ScreenPoint(x: 17, y: 32),
            pressure: 0.5,
            timestamp: 1,
            phase: .moved,
            source: .mouse,
            kind: .predicted
        )
    )
    let bufferBefore = try #require(renderer.transientStrokeBuffer)
    let generatorBefore = try #require(renderer.predictedStrokeGenerator)
    let replayBefore = renderer.replayStroke

    #expect(throws: MetalRendererError.generatedDabCapacityExceeded(6)) {
        try renderer.appendStrokeBatch(
            token: token,
            samples: [
                StrokeSample(
                    position: ScreenPoint(x: 20, y: 32),
                    pressure: 0.5,
                    timestamp: 2,
                    phase: .moved,
                    source: .mouse,
                    kind: .predicted
                ),
                StrokeSample(
                    position: ScreenPoint(x: 24, y: 32),
                    pressure: 0.5,
                    timestamp: 3,
                    phase: .moved,
                    source: .mouse,
                    kind: .predicted
                ),
            ]
        )
    }

    #expect(renderer.transientStrokeBuffer == bufferBefore)
    #expect(renderer.predictedStrokeGenerator == generatorBefore)
    #expect(renderer.replayStroke.pending.map(\.identity)
        == replayBefore.pending.map(\.identity))
    #expect(renderer.replayStroke.renderEpoch == replayBefore.renderEpoch)
    #expect(!renderer.isIdle)
    try renderer.cancelStroke(token: token)
}

@Test
@MainActor
func staleReplayFailureTerminatesTheActiveStrokeAndPreservesCanonical() throws {
    guard let renderer = try makeRenderer() else { return }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.reordered-replay"),
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    let token = RendererOperationToken(rawValue: 902)
    var completions: [RendererOperationCompletion] = []
    renderer.onOperationCompleted = { completions.append($0) }
    let initialSnapshot = renderer.harnessTilingMutationSnapshot
    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began, x: 12),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 16,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 902
        )
    )

    try renderer.appendStroke(
        token: token,
        sample: StrokeSample(
            position: ScreenPoint(x: 44, y: 32),
            pressure: 0.5,
            timestamp: 1,
            phase: .moved,
            source: .mouse,
            kind: .predicted
        )
    )
    let staleEpoch = renderer.replayStroke.renderEpoch
    renderer.deferNextFrameOutcomeForHarness()
    _ = try renderer.flushPendingLiveForHarness(forceFailure: true)

    try renderer.appendStroke(
        token: token,
        sample: strokeSample(.moved, x: 36)
    )
    let newestEpoch = renderer.replayStroke.renderEpoch
    #expect(newestEpoch > staleEpoch)
    _ = try renderer.flushPendingLiveForHarness()
    #expect(renderer.replayTile.visibleEpoch == newestEpoch)

    renderer.releaseDeferredFrameOutcomesForHarness()
    #expect(
        throws: MetalRendererError.commandFailed(
            "injected harness command-buffer failure"
        )
    ) {
        try renderer.drainNextCompletedOperationForHarness()
    }
    #expect(renderer.isIdle)
    #expect(renderer.harnessRevision == initialSnapshot.revision)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == initialSnapshot.canonicalFront
    )
    #expect(completions.count == 1)
    guard case let .failure(completedToken, _) = completions.first else {
        Issue.record("Expected the stale replay failure to terminate the stroke")
        return
    }
    #expect(completedToken == token)
}

@Test
@MainActor
func staleReplaySuccessCannotReplaceTheNewestVisibleEpoch() throws {
    guard let renderer = try makeRenderer() else { return }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.reordered-replay-success"),
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    let token = RendererOperationToken(rawValue: 905)
    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began, x: 12),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 16,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 905
        )
    )

    try renderer.appendStroke(
        token: token,
        sample: StrokeSample(
            position: ScreenPoint(x: 44, y: 32),
            pressure: 0.5,
            timestamp: 1,
            phase: .moved,
            source: .mouse,
            kind: .predicted
        )
    )
    let staleEpoch = renderer.replayStroke.renderEpoch
    renderer.deferNextFrameOutcomeForHarness()
    _ = try renderer.flushPendingLiveForHarness()

    try renderer.appendStroke(
        token: token,
        sample: strokeSample(.moved, x: 36)
    )
    let newestEpoch = renderer.replayStroke.renderEpoch
    #expect(newestEpoch > staleEpoch)
    _ = try renderer.flushPendingLiveForHarness()
    #expect(renderer.replayTile.visibleEpoch == newestEpoch)

    renderer.releaseDeferredFrameOutcomesForHarness()
    try renderer.drainNextCompletedOperationForHarness()
    #expect(renderer.replayTile.visibleEpoch == newestEpoch)
    #expect(!renderer.isIdle)
    try renderer.cancelStroke(token: token)
}

@Test
@MainActor
func replayPromotionWaitsForCompleteAtomicUploadPreflight() throws {
    guard let renderer = try makeRenderer() else { return }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.atomic-replay-preflight"),
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    let token = RendererOperationToken(rawValue: 903)
    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began, x: 16),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 16,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 903
        )
    )
    _ = try renderer.flushPendingLiveForHarness()
    let priorVisibleEpoch = renderer.replayTile.visibleEpoch

    // Crossing the 256-sample tail cap promotes the oldest chunk into the
    // settled layer while retaining a nonempty replay replacement.
    for index in 1...256 {
        try renderer.appendStroke(
            token: token,
            sample: StrokeSample(
                position: ScreenPoint(
                    x: 16 + Float(index) * 0.1,
                    y: 32
                ),
                pressure: 0.5,
                timestamp: TimeInterval(index),
                phase: .moved,
                source: .mouse
            )
        )
    }

    let latestEpoch = renderer.replayStroke.renderEpoch
    let settledBefore = renderer.liveStroke.bakedHighWater
    let replayBefore = renderer.replayStroke.bakedHighWater
    #expect(latestEpoch > priorVisibleEpoch)
    #expect(renderer.liveStroke.emittedHighWater > settledBefore)
    #expect(renderer.replayStroke.emittedHighWater > replayBefore)
    #expect(renderer.needsReplayClear)

    // One free slot cannot satisfy the promotion + replacement pair. The
    // batch reservation must roll back and the old replay epoch must remain
    // the visible one.
    let heldLeases = try #require(renderer.instancePool.acquire(count: 2))
    var leasesReleased = false
    defer {
        if !leasesReleased {
            for lease in heldLeases {
                renderer.instancePool.abandon(lease)
            }
        }
    }
    let deferred = try renderer.flushPendingLiveForHarness()
    #expect(deferred.encodedIdentityRanges.isEmpty)
    #expect(renderer.replayTile.visibleEpoch == priorVisibleEpoch)
    #expect(renderer.liveStroke.bakedHighWater == settledBefore)
    #expect(renderer.replayStroke.bakedHighWater == replayBefore)
    #expect(renderer.needsReplayClear)
    #expect(renderer.harnessReservedInstanceBufferCount == 2)

    for lease in heldLeases {
        renderer.instancePool.abandon(lease)
    }
    leasesReleased = true

    let completed = try renderer.flushPendingLiveForHarness()
    #expect(completed.encodedIdentityRanges.count == 2)
    #expect(renderer.liveStroke.bakedHighWater
        == renderer.liveStroke.emittedHighWater)
    #expect(renderer.replayStroke.bakedHighWater
        == renderer.replayStroke.emittedHighWater)
    #expect(renderer.replayTile.visibleEpoch == latestEpoch)
    #expect(!renderer.needsReplayClear)
    try renderer.cancelStroke(token: token)
}

@Test
@MainActor
func stalePromotionAndReplacementFailurePreservesCanonicalAndHistory() throws {
    guard let renderer = try makeRenderer() else { return }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.failed-stale-promotion"),
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    let token = RendererOperationToken(rawValue: 906)
    var completions: [RendererOperationCompletion] = []
    renderer.onOperationCompleted = { completions.append($0) }
    let initialSnapshot = renderer.harnessTilingMutationSnapshot
    let canonicalBefore = rendererTransactionTextureBytes(
        try renderer.copyCanonicalForHarness()
    )

    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began, x: 16),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 16,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 906
        )
    )
    _ = try renderer.flushPendingLiveForHarness()

    for index in 1...256 {
        try renderer.appendStroke(
            token: token,
            sample: StrokeSample(
                position: ScreenPoint(
                    x: 16 + Float(index) * 0.1,
                    y: 32
                ),
                pressure: 0.5,
                timestamp: TimeInterval(index),
                phase: .moved,
                source: .mouse
            )
        )
    }
    #expect(renderer.liveStroke.emittedHighWater > 0)
    #expect(renderer.replayStroke.emittedHighWater > 0)

    let staleEpoch = renderer.replayStroke.renderEpoch
    renderer.deferNextFrameOutcomeForHarness()
    _ = try renderer.flushPendingLiveForHarness(forceFailure: true)

    try renderer.appendStroke(
        token: token,
        sample: StrokeSample(
            position: ScreenPoint(x: 48, y: 32),
            pressure: 0.5,
            timestamp: 257,
            phase: .moved,
            source: .mouse
        )
    )
    #expect(renderer.replayStroke.renderEpoch > staleEpoch)
    _ = try renderer.flushPendingLiveForHarness()

    renderer.releaseDeferredFrameOutcomesForHarness()
    #expect(
        throws: MetalRendererError.commandFailed(
            "injected harness command-buffer failure"
        )
    ) {
        try renderer.drainNextCompletedOperationForHarness()
    }

    #expect(renderer.isIdle)
    #expect(renderer.harnessRevision == initialSnapshot.revision)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == initialSnapshot.canonicalFront
    )
    #expect(
        rendererTransactionTextureBytes(
            try renderer.copyCanonicalForHarness()
        ) == canonicalBefore
    )
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
    #expect(completions.count == 1)
    guard case let .failure(completedToken, _) = completions.first else {
        Issue.record("Expected one terminal promotion failure")
        return
    }
    #expect(completedToken == token)
}

@Test
@MainActor
func failedAtomicReplayClearUploadPreservesCanonicalAndHistory() throws {
    guard let renderer = try makeRenderer() else { return }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.failed-atomic-replay"),
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    let token = RendererOperationToken(rawValue: 904)
    var completions: [RendererOperationCompletion] = []
    renderer.onOperationCompleted = { completions.append($0) }
    let initialSnapshot = renderer.harnessTilingMutationSnapshot

    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began, x: 16),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 16,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 904
        )
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: strokeSample(.ended, x: 40),
        maximumRetainedBytes: 1_000_000
    )
    #expect(renderer.needsReplayClear)
    #expect(renderer.harnessRasterRevisionResidentBytes > 0)

    #expect(
        throws: MetalRendererError.commandFailed(
            "injected harness command-buffer failure"
        )
    ) {
        _ = try renderer.flushPendingLiveForHarness(forceFailure: true)
    }

    #expect(renderer.isIdle)
    #expect(renderer.harnessRevision == initialSnapshot.revision)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == initialSnapshot.canonicalFront
    )
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
    #expect(renderer.harnessReservedInstanceBufferCount == 0)
    #expect(completions.count == 1)
    guard case let .failure(completedToken, _) = completions.first else {
        Issue.record("Expected one atomic replay failure")
        return
    }
    #expect(completedToken == token)
}

@Test
@MainActor
func boundedWashUsesFixedSurfaceAndDirtyAreaWorkPlan() throws {
    guard let renderer = try makeRenderer() else { return }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.bounded-wash"),
        shape: .softRound,
        grain: .paper,
        material: BrushMaterial(
            family: .boundedWash,
            strength: 0.65,
            wetness: 0.8,
            bleedRadius: 12,
            softenPasses: 2,
            accumulationLimit: 0.7
        ),
        baseFlow: 0.25,
        strokeOpacity: 0.6,
        replayMode: .boundedWholeStroke,
        replayLimits: BrushRecipePolicy.wholeStrokeLimits
    )
    let token = RendererOperationToken(rawValue: 901)
    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began, x: 28),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 24,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 901
        )
    )
    try renderer.appendStroke(
        token: token,
        sample: strokeSample(.moved, x: 36)
    )

    let plan = try #require(renderer.lastBoundedWashWorkPlan)
    #expect(plan.haloPixels == 12)
    #expect(plan.softenPasses == 2)
    #expect(plan.processedPixelCount > 0)
    #expect(plan.processingRegions.rectangles.count <= 256)
    #expect(
        renderer.boundedWashSurface?.workingByteCount
            == 64 * 64 * 8 * 2
    )
    let depositIdentity = renderer.boundedWashSurface.map {
        ObjectIdentifier($0.depositTexture as AnyObject)
    }
    let scratchIdentity = renderer.boundedWashSurface.map {
        ObjectIdentifier($0.scratchTexture as AnyObject)
    }
    _ = try renderer.flushPendingLiveForHarness()
    #expect(renderer.replayTile.isVisible)
    let encodedWork = renderer.boundedWashEncodedWork
    #expect(encodedWork.updateCount == 1)
    #expect(encodedWork.depositionPixelCount > 0)
    #expect(encodedWork.localPassPixelCount
        == encodedWork.resolvePixelCount * 2)
    #expect(encodedWork.processedPixelCount
        == renderer.sliceFourRendererCounters.processedWashPixelCount)
    #expect(renderer.sliceFourRendererCounters.washWorkingBytes
        == 64 * 64 * 8 * 2)

    let display = try renderer.renderOffscreenDisplayForHarness(
        width: 64,
        height: 64,
        showGridLines: false
    )
    let bytes = rendererTransactionTextureBytes(display.texture)
    let center = (32 * 64 + 32) * 4
    #expect(bytes[center] < GridCanvasContract.paperBGRA.x)
    #expect(bytes[center + 1] < GridCanvasContract.paperBGRA.y)
    #expect(bytes[center + 2] < GridCanvasContract.paperBGRA.z)
    #expect(
        renderer.boundedWashSurface.map {
            ObjectIdentifier($0.depositTexture as AnyObject)
        } == depositIdentity
    )
    #expect(
        renderer.boundedWashSurface.map {
            ObjectIdentifier($0.scratchTexture as AnyObject)
        } == scratchIdentity
    )
    try renderer.cancelStroke(token: token)
}

@Test
@MainActor
func glazeAccumulationLimitHoldsAcrossSettledReplayAndCommit() throws {
    guard let renderer = try makeRenderer() else { return }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.glaze-combined-limit"),
        material: BrushMaterial(
            family: .glaze,
            strength: 1,
            wetness: 0,
            bleedRadius: 0,
            softenPasses: 0,
            accumulationLimit: 0.3
        ),
        baseFlow: 1,
        strokeOpacity: 1,
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    let token = RendererOperationToken(rawValue: 907)
    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began, x: 32),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 24,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 907
        )
    )
    for index in 1...256 {
        try renderer.appendStroke(
            token: token,
            sample: StrokeSample(
                position: ScreenPoint(
                    x: 32 + Float(index) * 0.01,
                    y: 32
                ),
                pressure: 0.5,
                timestamp: TimeInterval(index),
                phase: .moved,
                source: .mouse
            )
        )
    }
    try renderer.requestStrokeCommit(
        token: token,
        sample: StrokeSample(
            position: ScreenPoint(x: 34.56, y: 32),
            pressure: 0.5,
            timestamp: 257,
            phase: .ended,
            source: .mouse
        ),
        maximumRetainedBytes: 1_000_000
    )
    #expect(renderer.liveStroke.emittedHighWater > 0)
    #expect(renderer.replayStroke.emittedHighWater > 0)

    _ = try renderer.flushPendingLiveForHarness()
    let preview = rendererTransactionTextureBytes(
        try renderer.renderOffscreenDisplayForHarness(
            width: 64,
            height: 64,
            showGridLines: false
        ).texture
    )
    _ = try renderer.submitCommitForHarness()
    try renderer.drainCompletedOperationsForHarness()
    let committed = rendererTransactionTextureBytes(
        try renderer.renderOffscreenDisplayForHarness(
            width: 64,
            height: 64,
            showGridLines: false
        ).texture
    )

    let maximumDelta = zip(preview, committed).reduce(0) {
        max($0, abs(Int($1.0) - Int($1.1)))
    }
    #expect(maximumDelta <= 1)
    let center = (32 * 64 + 32) * 4
    let expectedMinimum = UInt8(
        Float(GridCanvasContract.paperBGRA.x) * 0.69
    )
    #expect(committed[center] >= expectedMinimum)
    #expect(committed[center + 1] >= expectedMinimum)
    #expect(committed[center + 2] >= expectedMinimum)
}

private func rendererTransactionTextureBytes(
    _ texture: any MTLTexture
) -> [UInt8] {
    let bytesPerRow = texture.width * 4
    var bytes = [UInt8](
        repeating: 0,
        count: bytesPerRow * texture.height
    )
    bytes.withUnsafeMutableBytes { storage in
        texture.getBytes(
            storage.baseAddress!,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
    }
    return bytes
}

@Test
@MainActor
func boundedWashFrameFailurePreservesCanonicalAndHistoryState() throws {
    guard let renderer = try makeRenderer() else { return }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.renderer.bounded-wash-failure"),
        shape: .softRound,
        grain: .paper,
        material: BrushMaterial(
            family: .boundedWash,
            strength: 0.65,
            wetness: 0.8,
            bleedRadius: 12,
            softenPasses: 2,
            accumulationLimit: 0.7
        ),
        baseFlow: 0.25,
        strokeOpacity: 0.6,
        replayMode: .boundedWholeStroke,
        replayLimits: BrushRecipePolicy.wholeStrokeLimits
    )
    let before = rendererTransactionTextureBytes(
        try renderer.copyCanonicalForHarness()
    )
    let token = RendererOperationToken(rawValue: 903)
    try renderer.beginStroke(
        token: token,
        sample: strokeSample(.began, x: 18),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 18,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 903
        )
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: strokeSample(.ended, x: 42),
        maximumRetainedBytes: 1_000_000
    )

    #expect(throws: MetalRendererError.self) {
        _ = try renderer.flushPendingLiveForHarness(forceFailure: true)
    }
    #expect(renderer.isIdle)
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
    let after = rendererTransactionTextureBytes(
        try renderer.copyCanonicalForHarness()
    )
    #expect(after == before)
}
