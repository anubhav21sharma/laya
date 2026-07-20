import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

private let blackDrawStyle = StrokeRenderStyle(
    color: .black,
    diameter: 20,
    compositeMode: .draw,
    eraserStrength: 1
)

private let fixedEraseStyle = StrokeRenderStyle(
    color: InkColor(red: 1, green: 0, blue: 0, alpha: 0.25)!,
    diameter: 12,
    compositeMode: .erase,
    eraserStrength: 1
)

private func rasterSample(
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
private func makeRasterOperationRenderer() throws -> GridRenderer? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
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

@MainActor
private func commitCenterStroke(
    renderer: GridRenderer,
    token: RendererOperationToken,
    style: StrokeRenderStyle
) throws {
    try renderer.beginStroke(
        token: token,
        sample: rasterSample(.began),
        style: style
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: rasterSample(.ended),
        maximumRetainedBytes: 1_000_000
    )
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.submitCommitForHarness()
    try renderer.drainCompletedOperationsForHarness()
}

@Test
@MainActor
func clearPublishesFullRegionReceiptAndRestoreUsesOperationSuccess() throws {
    guard let renderer = try makeRasterOperationRenderer() else { return }
    var completions: [RendererOperationCompletion] = []
    renderer.onOperationCompleted = { completions.append($0) }
    try commitCenterStroke(
        renderer: renderer,
        token: RendererOperationToken(rawValue: 1),
        style: blackDrawStyle
    )
    guard case let .rasterSuccess(drawReceipt) = completions.removeFirst() else {
        Issue.record("Expected draw receipt")
        return
    }

    let clearToken = RendererOperationToken(rawValue: 2)
    let revisionBeforeClear = renderer.harnessRevision
    try renderer.requestClear(
        token: clearToken,
        maximumRetainedBytes: 1_000_000
    )
    #expect(renderer.harnessRevision == revisionBeforeClear)
    try renderer.finishRasterOperationForHarness()

    guard case let .rasterSuccess(clearReceipt) = completions.first else {
        Issue.record("Expected clear raster receipt")
        return
    }
    #expect(clearReceipt.token == clearToken)
    #expect(clearReceipt.before.regions.rectangles == [
        PixelRect(minX: 0, minY: 0, maxX: 64, maxY: 64)!,
    ])
    #expect(clearReceipt.before.regions == clearReceipt.after.regions)
    #expect(renderer.harnessRevision == revisionBeforeClear.advanced())
    #expect(try centerBGRA(renderer) == [0, 0, 0, 0])

    completions.removeAll()
    let restoreToken = RendererOperationToken(rawValue: 3)
    try renderer.requestRasterRestore(
        token: restoreToken,
        revision: clearReceipt.before
    )
    try renderer.finishRasterOperationForHarness()

    #expect(completions.count == 1)
    guard case let .operationSuccess(completedToken) = completions.first else {
        Issue.record("Restore must use operationSuccess")
        return
    }
    #expect(completedToken == restoreToken)
    #expect(try centerBGRA(renderer)[3] == 255)

    completions.removeAll()
    let redoToken = RendererOperationToken(rawValue: 4)
    try renderer.requestRasterRestore(
        token: redoToken,
        revision: clearReceipt.after
    )
    try renderer.finishRasterOperationForHarness()
    #expect(completions.count == 1)
    guard case let .operationSuccess(redoneToken) = completions.first else {
        Issue.record("Redo restore must use operationSuccess")
        return
    }
    #expect(redoneToken == redoToken)
    #expect(try centerBGRA(renderer) == [0, 0, 0, 0])

    renderer.releaseRasterRevisions([
        drawReceipt.before.id,
        drawReceipt.after.id,
        clearReceipt.before.id,
        clearReceipt.after.id,
    ])
}

@Test
@MainActor
func failedClearKeepsCanonicalAndDiscardsOnlyProvisionalPair() throws {
    guard let renderer = try makeRasterOperationRenderer() else { return }
    var completions: [RendererOperationCompletion] = []
    renderer.onOperationCompleted = { completions.append($0) }
    try commitCenterStroke(
        renderer: renderer,
        token: RendererOperationToken(rawValue: 5),
        style: blackDrawStyle
    )
    guard case let .rasterSuccess(drawReceipt) = completions.removeFirst() else {
        Issue.record("Expected draw receipt")
        return
    }
    let snapshot = renderer.harnessTilingMutationSnapshot
    let publishedBytes = renderer.harnessRasterRevisionResidentBytes
    let centerBefore = try centerBGRA(renderer)

    try renderer.requestClearForHarness(
        token: RendererOperationToken(rawValue: 6),
        maximumRetainedBytes: 1_000_000,
        forceFailure: true
    )
    #expect(renderer.harnessRasterRevisionResidentBytes > publishedBytes)
    #expect(throws: MetalRendererError.commandFailed(
        "injected harness command-buffer failure"
    )) {
        try renderer.finishRasterOperationForHarness()
    }

    #expect(renderer.harnessRevision == snapshot.revision)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == snapshot.canonicalFront
    )
    #expect(try centerBGRA(renderer) == centerBefore)
    #expect(renderer.harnessRasterRevisionResidentBytes == publishedBytes)
    #expect(completions.count == 1)
    guard case let .failure(token, _) = completions.first else {
        Issue.record("Expected clear failure without a raster receipt")
        return
    }
    #expect(token == RendererOperationToken(rawValue: 6))

    renderer.releaseRasterRevisions([
        drawReceipt.before.id,
        drawReceipt.after.id,
    ])
}

@Test
@MainActor
func failedRestoreKeepsCanonicalFrontAndRevisionUnchanged() throws {
    guard let renderer = try makeRasterOperationRenderer() else { return }
    var completions: [RendererOperationCompletion] = []
    renderer.onOperationCompleted = { completions.append($0) }
    try commitCenterStroke(
        renderer: renderer,
        token: RendererOperationToken(rawValue: 10),
        style: blackDrawStyle
    )
    guard case let .rasterSuccess(receipt) = completions.removeFirst() else {
        Issue.record("Expected draw receipt")
        return
    }
    let snapshot = renderer.harnessTilingMutationSnapshot
    let before = try centerBGRA(renderer)

    try renderer.requestRasterRestoreForHarness(
        token: RendererOperationToken(rawValue: 11),
        revision: receipt.before,
        forceFailure: true
    )
    #expect(throws: MetalRendererError.commandFailed(
        "injected harness command-buffer failure"
    )) {
        try renderer.finishRasterOperationForHarness()
    }

    #expect(renderer.harnessRevision == snapshot.revision)
    #expect(
        renderer.harnessTilingMutationSnapshot.canonicalFront
            == snapshot.canonicalFront
    )
    #expect(try centerBGRA(renderer) == before)
    #expect(completions.count == 1)
    guard case let .failure(token, _) = completions.first else {
        Issue.record("Expected one restore failure")
        return
    }
    #expect(token == RendererOperationToken(rawValue: 11))

    renderer.releaseRasterRevisions([receipt.before.id, receipt.after.id])
}

@Test
@MainActor
func restoreRejectsMismatchedCanonicalSizeBeforeSubmission() throws {
    guard let renderer = try makeRasterOperationRenderer() else { return }
    let size = PixelSize(width: 65, height: 64)
    let region = PixelRegionSet(
        [PixelRect(minX: 0, minY: 0, maxX: 65, maxY: 64)!],
        clippedTo: size
    )
    let mismatched = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: 999),
        pixelSize: size,
        regions: region,
        retainedBytes: 65 * 64 * 4
    )

    #expect(throws: MetalRendererError.rasterRevisionTextureSizeMismatch(
        expectedWidth: 64,
        expectedHeight: 64,
        actualWidth: 65,
        actualHeight: 64
    )) {
        try renderer.requestRasterRestore(
            token: RendererOperationToken(rawValue: 20),
            revision: mismatched
        )
    }
    #expect(renderer.isIdle)
}

@Test
@MainActor
func liveAndCommittedFixedStrengthEraserMatchAndClearCenter() throws {
    guard let renderer = try makeRasterOperationRenderer() else { return }
    var receipts: [RasterMutationReceipt] = []
    renderer.onOperationCompleted = {
        if case let .rasterSuccess(receipt) = $0 {
            receipts.append(receipt)
        }
    }
    try commitCenterStroke(
        renderer: renderer,
        token: RendererOperationToken(rawValue: 30),
        style: blackDrawStyle
    )

    let eraseToken = RendererOperationToken(rawValue: 31)
    try renderer.beginStroke(
        token: eraseToken,
        sample: rasterSample(.began),
        style: fixedEraseStyle
    )
    try renderer.requestStrokeCommit(
        token: eraseToken,
        sample: rasterSample(.ended),
        maximumRetainedBytes: 1_000_000
    )
    _ = try renderer.flushPendingLiveForHarness()
    let live = try renderer.renderOffscreenDisplayForHarness(
        width: 64,
        height: 64,
        showGridLines: false
    )

    _ = try renderer.submitCommitForHarness()
    try renderer.drainCompletedOperationsForHarness()
    let committed = try renderer.renderOffscreenDisplayForHarness(
        width: 64,
        height: 64,
        showGridLines: false
    )

    let liveBytes = textureBytes(live.texture)
    let committedBytes = textureBytes(committed.texture)
    let maximumDelta = zip(liveBytes, committedBytes).reduce(0) {
        max($0, abs(Int($1.0) - Int($1.1)))
    }
    #expect(maximumDelta <= 1)
    #expect(try centerBGRA(renderer) == [0, 0, 0, 0])

    renderer.releaseRasterRevisions(
        Set(receipts.flatMap { [$0.before.id, $0.after.id] })
    )
}

@MainActor
private func centerBGRA(_ renderer: GridRenderer) throws -> [UInt8] {
    let texture = try renderer.copyCanonicalForHarness()
    let bytes = textureBytes(texture)
    let offset = (32 * texture.width + 32) * 4
    return Array(bytes[offset..<(offset + 4)])
}

private func textureBytes(_ texture: any MTLTexture) -> [UInt8] {
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
