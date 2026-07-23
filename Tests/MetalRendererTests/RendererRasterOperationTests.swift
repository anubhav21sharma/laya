import Metal
@testable import MetalRenderer
import EditorCore
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
    let drawnCanonical = try canonicalBytes(renderer)

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
    let clearedCanonical = try canonicalBytes(renderer)
    #expect(clearedCanonical == [UInt8](repeating: 0, count: 64 * 64 * 4))
    #expect(renderer.isIdle)

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
    #expect(try canonicalBytes(renderer) == drawnCanonical)
    #expect(renderer.isIdle)

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
    #expect(try canonicalBytes(renderer) == clearedCanonical)
    #expect(renderer.isIdle)

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
    let before = try canonicalBytes(renderer)

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
    #expect(try canonicalBytes(renderer) == before)
    #expect(renderer.isIdle)
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

@Test(arguments: [
    SymmetryPresetID.grid,
    .squareRotation,
    .squareKaleidoscope,
])
@MainActor
func liveAndCommittedFixedStrengthEraserMatchAndClearCenter(
    preset: SymmetryPresetID
) throws {
    guard let renderer = try makeRasterOperationRenderer() else { return }
    if preset != .grid {
        try renderer.applyTiling(preset)
    }
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

@Test
@MainActor
func fractionallySampledDrawPreviewMatchesCommittedNonuniformRaster() throws {
    try fractionallySampledPreviewMatchesCommit(
        style: StrokeRenderStyle(
            color: InkColor(
                red: 0.9,
                green: 0.2,
                blue: 0.65,
                alpha: 0.72
            )!,
            diameter: 11,
            compositeMode: .draw,
            eraserStrength: 1
        ),
        token: RendererOperationToken(rawValue: 40)
    )
}

@Test
@MainActor
func fractionallySampledEraserPreviewMatchesCommittedNonuniformRaster() throws {
    try fractionallySampledPreviewMatchesCommit(
        style: StrokeRenderStyle(
            color: .black,
            diameter: 11,
            compositeMode: .erase,
            eraserStrength: 1
        ),
        token: RendererOperationToken(rawValue: 41)
    )
}

@Test
@MainActor
func glazePreviewMatchesCommitAndNeverExceedsStrokeOpacity() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.glaze.preview-commit"),
        material: BrushMaterial(
            family: .glaze,
            strength: 1,
            wetness: 0.2,
            bleedRadius: 0,
            softenPasses: 0,
            accumulationLimit: 0.8
        ),
        baseSpacingFraction: 0.16,
        maximumSpacingFraction: 0.3,
        baseFlow: 0.2,
        strokeOpacity: 0.65
    )
    let style = StrokeRenderStyle(
        color: InkColor(red: 0.8, green: 0.2, blue: 0.55, alpha: 0.9)!,
        diameter: 20,
        compositeMode: .draw,
        eraserStrength: 1,
        recipe: recipe,
        seed: 700
    )
    try fractionallySampledPreviewMatchesCommit(
        style: style,
        token: RendererOperationToken(rawValue: 42)
    )

    guard let renderer = try makeRasterOperationRenderer() else { return }
    try commitCenterStroke(
        renderer: renderer,
        token: RendererOperationToken(rawValue: 43),
        style: style
    )
    let committedBytes = try canonicalBytes(renderer)
    let alphaValues = stride(
        from: 3,
        to: committedBytes.count,
        by: 4
    ).map { committedBytes[$0] }
    #expect(alphaValues.max()! <= UInt8((0.65 * 255).rounded(.up)))
}

@Test
@MainActor
func boundedWashPreviewMatchesCommitAndHonorsAccumulationLimit() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.wash.preview-commit"),
        shape: .softRound,
        grain: .paper,
        material: BrushMaterial(
            family: .boundedWash,
            strength: 0.85,
            wetness: 0.9,
            bleedRadius: 10,
            softenPasses: 2,
            accumulationLimit: 0.7
        ),
        baseSpacingFraction: 0.15,
        maximumSpacingFraction: 0.3,
        baseFlow: 0.45,
        strokeOpacity: 0.6,
        replayMode: .boundedWholeStroke,
        replayLimits: BrushRecipePolicy.wholeStrokeLimits
    )
    let style = StrokeRenderStyle(
        color: InkColor(red: 0.2, green: 0.45, blue: 0.8, alpha: 0.9)!,
        diameter: 18,
        compositeMode: .draw,
        eraserStrength: 1,
        recipe: recipe,
        seed: 702
    )
    try fractionallySampledPreviewMatchesCommit(
        style: style,
        token: RendererOperationToken(rawValue: 45)
    )

    guard let renderer = try makeRasterOperationRenderer() else { return }
    try commitCenterStroke(
        renderer: renderer,
        token: RendererOperationToken(rawValue: 46),
        style: style
    )
    let committedBytes = try canonicalBytes(renderer)
    let alphaValues = stride(
        from: 3,
        to: committedBytes.count,
        by: 4
    ).map { committedBytes[$0] }
    let expectedCeiling = UInt8((0.7 * 0.6 * 255).rounded(.up))
    #expect(alphaValues.max()! <= expectedCeiling)
}

@Test
@MainActor
func calibratedAnchorsProduceVisibleNominalMouseDabs() throws {
    let fixtures: [(AnchorBrushEntry, UInt64, UInt8)] = [
        (AnchorBrushCatalog.glazeMarker, 47, 40),
        (AnchorBrushCatalog.boundedWash, 48, 24),
    ]

    for (entry, tokenValue, minimumPeakAlpha) in fixtures {
        guard let renderer = try makeRasterOperationRenderer() else { return }
        try commitCenterStroke(
            renderer: renderer,
            token: RendererOperationToken(rawValue: tokenValue),
            style: StrokeRenderStyle(
                color: .black,
                diameter: 40,
                compositeMode: .draw,
                eraserStrength: 1,
                recipe: entry.recipe,
                seed: tokenValue
            )
        )

        let bytes = try canonicalBytes(renderer)
        let alphaValues = stride(from: 3, to: bytes.count, by: 4).map {
            bytes[$0]
        }
        #expect(
            alphaValues.max()! >= minimumPeakAlpha,
            "\(entry.displayName) must remain clearly visible"
        )

        if entry.id == AnchorBrushCatalog.glazeMarker.id {
            let visibleOffsets = alphaValues.indices.filter {
                alphaValues[$0] >= 8
            }
            let xs = visibleOffsets.map { $0 % 64 }
            let ys = visibleOffsets.map { $0 / 64 }
            let visibleWidth = xs.max()! - xs.min()! + 1
            let visibleHeight = ys.max()! - ys.min()! + 1
            #expect(
                min(visibleWidth, visibleHeight) >= 22,
                "Glaze Marker must occupy most of its nominal cursor envelope"
            )
        }
    }
}

@Test
@MainActor
func rotationalFixedPointKeepsBrushLocalGrainOrientations() throws {
    guard let renderer = try makeRasterOperationRenderer() else { return }
    try renderer.applyTiling(.rotational)
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.brush-local-paper"),
        shape: .hardRound,
        grain: .paper,
        grainCoordinateMode: .brushLocal,
        material: .ink,
        baseSpacingFraction: 0.125,
        maximumSpacingFraction: 0.125
    )
    let token = RendererOperationToken(rawValue: 49)

    try renderer.beginStroke(
        token: token,
        sample: rasterSample(.began),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 20,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 49
        )
    )
    defer { try? renderer.cancelStroke(token: token) }

    #expect(renderer.harnessCounters.totalInstancesThisStroke == 2)
}

@Test
@MainActor
func boundedWashBleedWrapsAcrossCanonicalSeam() throws {
    let softenedResult = try renderSeamWash(
        bleedRadius: 8,
        softenPasses: 2
    )
    let depositOnlyResult = try renderSeamWash(
        bleedRadius: 0,
        softenPasses: 0
    )
    let softened = try #require(softenedResult)
    let depositOnly = try #require(depositOnlyResult)
    let acrossSeam = (32 * 64 + 61) * 4

    #expect(softened[acrossSeam] < depositOnly[acrossSeam])
    #expect(softened[acrossSeam + 1] < depositOnly[acrossSeam + 1])
    #expect(softened[acrossSeam + 2] < depositOnly[acrossSeam + 2])
}

@Test
@MainActor
func translucentEraserPreviewMatchesCommitAtFractionalEdges() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.erase.translucent-preview"),
        material: .ink,
        baseFlow: 1,
        strokeOpacity: 0.55
    )
    try fractionallySampledPreviewMatchesCommit(
        style: StrokeRenderStyle(
            color: .black,
            diameter: 13,
            compositeMode: .erase,
            eraserStrength: 0.6,
            recipe: recipe,
            seed: 701
        ),
        token: RendererOperationToken(rawValue: 44)
    )
}

@Test
@MainActor
func overlappingEraserDabsApplyStrengthOnceAfterLiveAccumulation() throws {
    guard let renderer = try makeRasterOperationRenderer() else { return }
    var receipts: [RasterMutationReceipt] = []
    renderer.onOperationCompleted = {
        if case let .rasterSuccess(receipt) = $0 {
            receipts.append(receipt)
        }
    }
    try commitCenterStroke(
        renderer: renderer,
        token: RendererOperationToken(rawValue: 45),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 24,
            compositeMode: .draw,
            eraserStrength: 1
        )
    )
    #expect(try centerBGRA(renderer)[3] == 255)

    let eraseToken = RendererOperationToken(rawValue: 46)
    let eraseStyle = StrokeRenderStyle(
        color: .black,
        diameter: 24,
        compositeMode: .erase,
        eraserStrength: 0.5
    )
    try renderer.beginStroke(
        token: eraseToken,
        sample: rasterSample(.began, x: 28),
        style: eraseStyle
    )
    try renderer.appendStroke(
        token: eraseToken,
        sample: rasterSample(.moved, x: 34)
    )
    try renderer.requestStrokeCommit(
        token: eraseToken,
        sample: rasterSample(.ended, x: 40),
        maximumRetainedBytes: 1_000_000
    )
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.submitCommitForHarness()
    try renderer.drainCompletedOperationsForHarness()

    #expect((125...130).contains(Int(try centerBGRA(renderer)[3])))
    renderer.releaseRasterRevisions(
        Set(receipts.flatMap { [$0.before.id, $0.after.id] })
    )
}

@MainActor
private func fractionallySampledPreviewMatchesCommit(
    style: StrokeRenderStyle,
    token: RendererOperationToken
) throws {
    guard let renderer = try makeRasterOperationRenderer() else { return }
    var receipt: RasterMutationReceipt?
    renderer.onOperationCompleted = {
        if case let .rasterSuccess(completed) = $0 {
            receipt = completed
        }
    }
    try renderer.replaceCanonicalPixelsForHarness(nonuniformCanonicalBytes())
    renderer.pan(byScreenDelta: SIMD2<Float>(0.37, -0.61))
    renderer.zoom(
        by: 1.37,
        anchor: ScreenPoint(x: 19.25, y: 23.75)
    )

    try renderer.beginStroke(
        token: token,
        sample: rasterSample(.began, x: 27.4, y: 29.2),
        style: style
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: rasterSample(.ended, x: 38.6, y: 35.7),
        maximumRetainedBytes: 1_000_000
    )
    _ = try renderer.flushPendingLiveForHarness()
    let live = try renderer.renderOffscreenDisplayForHarness(
        width: 79,
        height: 73,
        showGridLines: false
    )

    _ = try renderer.submitCommitForHarness()
    try renderer.drainCompletedOperationsForHarness()
    let committed = try renderer.renderOffscreenDisplayForHarness(
        width: 79,
        height: 73,
        showGridLines: false
    )

    let maximumDelta = zip(
        textureBytes(live.texture),
        textureBytes(committed.texture)
    ).reduce(0) {
        max($0, abs(Int($1.0) - Int($1.1)))
    }
    #expect(maximumDelta <= 1)

    let completed = try #require(receipt)
    renderer.releaseRasterRevisions([
        completed.before.id,
        completed.after.id,
    ])
}

private func nonuniformCanonicalBytes() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
    for y in 0..<64 {
        for x in 0..<64 {
            let offset = (y * 64 + x) * 4
            let checker = ((x + y) & 1) == 0
            bytes[offset] = checker ? UInt8((x * 37 + y * 11) & 0xff) : 8
            bytes[offset + 1] = checker ? 12 : UInt8((x * 17 + y * 43) & 0xff)
            bytes[offset + 2] = checker ? 238 : UInt8((x * 29 + y * 7) & 0xff)
            bytes[offset + 3] = 255
        }
    }
    return bytes
}

@MainActor
private func centerBGRA(_ renderer: GridRenderer) throws -> [UInt8] {
    let texture = try renderer.copyCanonicalForHarness()
    let bytes = textureBytes(texture)
    let offset = (32 * texture.width + 32) * 4
    return Array(bytes[offset..<(offset + 4)])
}

@MainActor
private func canonicalBytes(_ renderer: GridRenderer) throws -> [UInt8] {
    textureBytes(try renderer.copyCanonicalForHarness())
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

@MainActor
private func renderSeamWash(
    bleedRadius: Float,
    softenPasses: Int
) throws -> [UInt8]? {
    guard let renderer = try makeRasterOperationRenderer() else { return nil }
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.wash.seam.\(softenPasses)"),
        shape: .hardRound,
        grain: .opaque,
        material: BrushMaterial(
            family: .boundedWash,
            strength: 1,
            wetness: 1,
            bleedRadius: bleedRadius,
            softenPasses: softenPasses,
            accumulationLimit: 1
        ),
        baseSpacingFraction: 0.2,
        maximumSpacingFraction: 0.2,
        baseFlow: 1,
        strokeOpacity: 1,
        replayMode: .boundedWholeStroke,
        replayLimits: BrushRecipePolicy.wholeStrokeLimits
    )
    let token = RendererOperationToken(rawValue: UInt64(800 + softenPasses))
    try renderer.beginStroke(
        token: token,
        sample: rasterSample(.began, x: 2, y: 32),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 4,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 800
        )
    )
    _ = try renderer.flushPendingLiveForHarness()
    let display = try renderer.renderOffscreenDisplayForHarness(
        width: 64,
        height: 64,
        showGridLines: false
    )
    let bytes = textureBytes(display.texture)
    try renderer.cancelStroke(token: token)
    return bytes
}
