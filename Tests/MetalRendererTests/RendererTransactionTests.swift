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
            $0 == SIMD4<Float>(0, 0, 0, 0.35)
        }
    )
    try renderer.cancelStroke(token: eraseToken)
}
