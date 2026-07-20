import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@MainActor
private func makeResizeRenderer(
    pixelSize: PixelSize,
    tiling: TilingKind = .grid
) throws -> GridRenderer? {
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
        drawableSize: PatternSize(width: 320, height: 240),
        configuration: TilingCanvasConfiguration(
            pixelSize: pixelSize,
            tiling: tiling
        )
    )
}

@Test
@MainActor
func resizeShrinkCropsOnlyRightAndBottomBytes() throws {
    let oldSize = PixelSize(width: 96, height: 80)
    let newSize = PixelSize(width: 64, height: 72)
    guard let renderer = try makeResizeRenderer(pixelSize: oldSize) else {
        return
    }
    let original = deterministicPixels(oldSize)
    try renderer.replaceCanonicalPixelsForHarness(original)
    let initialRevision = renderer.harnessRevision
    var receipts: [RasterMutationReceipt] = []
    renderer.onOperationCompleted = {
        if case let .rasterSuccess(receipt) = $0 {
            receipts.append(receipt)
        }
    }

    try renderer.requestResize(
        token: RendererOperationToken(rawValue: 1),
        to: newSize,
        maximumRetainedBytes: 1_000_000
    )
    #expect(renderer.pixelSize == oldSize)
    #expect(renderer.harnessRevision == initialRevision)
    try renderer.finishRasterOperationForHarness()

    #expect(renderer.pixelSize == newSize)
    #expect(renderer.harnessRevision == initialRevision.advanced())
    #expect(try canonicalBytes(renderer) == croppedOrFilled(
        original,
        from: oldSize,
        to: newSize
    ))
    let receipt = try #require(receipts.first)
    #expect(receipt.before.pixelSize == oldSize)
    #expect(receipt.after.pixelSize == newSize)
    renderer.releaseRasterRevisions([receipt.before.id, receipt.after.id])
}

@Test
@MainActor
func resizeGrowPreservesTopLeftAndTransparentFillsRightAndBottom() throws {
    let oldSize = PixelSize(width: 64, height: 72)
    let newSize = PixelSize(width: 96, height: 80)
    guard let renderer = try makeResizeRenderer(pixelSize: oldSize) else {
        return
    }
    let original = deterministicPixels(oldSize)
    try renderer.replaceCanonicalPixelsForHarness(original)
    var receipt: RasterMutationReceipt?
    renderer.onOperationCompleted = {
        if case let .rasterSuccess(value) = $0 {
            receipt = value
        }
    }

    try renderer.requestResize(
        token: RendererOperationToken(rawValue: 2),
        to: newSize,
        maximumRetainedBytes: 1_000_000
    )
    try renderer.finishRasterOperationForHarness()

    let grown = try canonicalBytes(renderer)
    #expect(grown == croppedOrFilled(original, from: oldSize, to: newSize))
    for y in 0..<newSize.height {
        for x in 0..<newSize.width where x >= oldSize.width || y >= oldSize.height {
            let offset = (y * newSize.width + x) * 4
            #expect(Array(grown[offset..<(offset + 4)]) == [0, 0, 0, 0])
        }
    }

    let stored = try #require(receipt)
    renderer.releaseRasterRevisions([stored.before.id, stored.after.id])
}

@Test
@MainActor
func resizeUndoRedoRestoresExactDimensionsBytesAndMonotonicRevision() throws {
    let oldSize = PixelSize(width: 96, height: 80)
    let newSize = PixelSize(width: 64, height: 72)
    guard let renderer = try makeResizeRenderer(pixelSize: oldSize) else {
        return
    }
    let original = deterministicPixels(oldSize)
    let resized = croppedOrFilled(original, from: oldSize, to: newSize)
    try renderer.replaceCanonicalPixelsForHarness(original)
    var resizeReceipt: RasterMutationReceipt?
    renderer.onOperationCompleted = {
        if case let .rasterSuccess(receipt) = $0 {
            resizeReceipt = receipt
        }
    }

    try renderer.requestResize(
        token: RendererOperationToken(rawValue: 10),
        to: newSize,
        maximumRetainedBytes: 1_000_000
    )
    try renderer.finishRasterOperationForHarness()
    let receipt = try #require(resizeReceipt)
    let afterResizeRevision = renderer.harnessRevision

    try renderer.requestResizeRestore(
        token: RendererOperationToken(rawValue: 11),
        revision: receipt.before
    )
    #expect(renderer.pixelSize == newSize)
    try renderer.finishRasterOperationForHarness()
    #expect(renderer.pixelSize == oldSize)
    #expect(try canonicalBytes(renderer) == original)
    #expect(renderer.harnessRevision == afterResizeRevision.advanced())

    try renderer.requestResizeRestore(
        token: RendererOperationToken(rawValue: 12),
        revision: receipt.after
    )
    try renderer.finishRasterOperationForHarness()
    #expect(renderer.pixelSize == newSize)
    #expect(try canonicalBytes(renderer) == resized)
    #expect(renderer.harnessRevision == afterResizeRevision.advanced().advanced())

    renderer.releaseRasterRevisions([receipt.before.id, receipt.after.id])
}

@Test
@MainActor
func replacementAllocationFailurePreservesAllRendererState() throws {
    let oldSize = PixelSize(width: 96, height: 80)
    guard let renderer = try makeResizeRenderer(
        pixelSize: oldSize,
        tiling: .mirrorX
    ) else { return }
    let original = deterministicPixels(oldSize)
    try renderer.replaceCanonicalPixelsForHarness(original)
    renderer.pan(byScreenDelta: SIMD2<Float>(17, -9))
    renderer.zoom(
        by: 1.5,
        anchor: ScreenPoint(x: 80, y: 60)
    )
    let resourceSnapshot = renderer.harnessTilingMutationSnapshot
    let viewport = renderer.viewport
    let residentBytes = renderer.harnessRasterRevisionResidentBytes
    var completions: [RendererOperationCompletion] = []
    renderer.onOperationCompleted = { completions.append($0) }

    #expect(throws: MetalRendererError.textureAllocationFailed) {
        try renderer.requestResizeForHarness(
            token: RendererOperationToken(rawValue: 20),
            to: PixelSize(width: 64, height: 72),
            maximumRetainedBytes: 1_000_000,
            forceResourceAllocationFailure: true
        )
    }

    #expect(renderer.harnessTilingMutationSnapshot == resourceSnapshot)
    #expect(renderer.pixelSize == oldSize)
    #expect(renderer.tiling == .mirrorX)
    #expect(renderer.viewport == viewport)
    #expect(try canonicalBytes(renderer) == original)
    #expect(renderer.harnessRasterRevisionResidentBytes == residentBytes)
    #expect(renderer.isIdle)
    #expect(completions.isEmpty)
}

@Test
@MainActor
func submittedResizeFailurePreservesResourcesPixelsAndRevisionStorage() throws {
    let oldSize = PixelSize(width: 96, height: 80)
    guard let renderer = try makeResizeRenderer(
        pixelSize: oldSize,
        tiling: .brick
    ) else { return }
    let original = deterministicPixels(oldSize)
    try renderer.replaceCanonicalPixelsForHarness(original)
    let snapshot = renderer.harnessTilingMutationSnapshot
    var completions: [RendererOperationCompletion] = []
    renderer.onOperationCompleted = { completions.append($0) }

    try renderer.requestResizeForHarness(
        token: RendererOperationToken(rawValue: 25),
        to: PixelSize(width: 64, height: 72),
        maximumRetainedBytes: 1_000_000,
        forceResourceAllocationFailure: false,
        forceCommandFailure: true
    )
    #expect(!renderer.isIdle)
    #expect(throws: MetalRendererError.commandFailed(
        "injected harness command-buffer failure"
    )) {
        try renderer.finishRasterOperationForHarness()
    }

    #expect(renderer.harnessTilingMutationSnapshot == snapshot)
    #expect(renderer.pixelSize == oldSize)
    #expect(renderer.tiling == .brick)
    #expect(try canonicalBytes(renderer) == original)
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
    #expect(renderer.isIdle)
    #expect(completions.count == 1)
    guard case let .failure(token, _) = completions.first else {
        Issue.record("Expected one terminal resize failure")
        return
    }
    #expect(token == RendererOperationToken(rawValue: 25))
}

@Test
@MainActor
func submittedResizeRestoreFailureKeepsInstalledDimensionsAndBytes() throws {
    let oldSize = PixelSize(width: 96, height: 80)
    let newSize = PixelSize(width: 64, height: 72)
    guard let renderer = try makeResizeRenderer(pixelSize: oldSize) else {
        return
    }
    let original = deterministicPixels(oldSize)
    try renderer.replaceCanonicalPixelsForHarness(original)
    var receipt: RasterMutationReceipt?
    renderer.onOperationCompleted = {
        if case let .rasterSuccess(value) = $0 {
            receipt = value
        }
    }
    try renderer.requestResize(
        token: RendererOperationToken(rawValue: 26),
        to: newSize,
        maximumRetainedBytes: 1_000_000
    )
    try renderer.finishRasterOperationForHarness()
    let stored = try #require(receipt)
    let snapshot = renderer.harnessTilingMutationSnapshot
    let resized = try canonicalBytes(renderer)

    try renderer.requestResizeRestoreForHarness(
        token: RendererOperationToken(rawValue: 27),
        revision: stored.before,
        forceCommandFailure: true
    )
    #expect(throws: MetalRendererError.commandFailed(
        "injected harness command-buffer failure"
    )) {
        try renderer.finishRasterOperationForHarness()
    }

    #expect(renderer.harnessTilingMutationSnapshot == snapshot)
    #expect(renderer.pixelSize == newSize)
    #expect(try canonicalBytes(renderer) == resized)
    #expect(renderer.isIdle)
    renderer.releaseRasterRevisions([stored.before.id, stored.after.id])
}

@Test
@MainActor
func resizeRejectsInvalidDimensionsAndHistoryCostBeforeMutation() throws {
    let size = PixelSize(width: 64, height: 64)
    guard let renderer = try makeResizeRenderer(pixelSize: size) else {
        return
    }
    let snapshot = renderer.harnessTilingMutationSnapshot

    #expect(throws: MetalRendererError.invalidTileDimensions(
        width: 63,
        height: 64
    )) {
        try renderer.requestResize(
            token: RendererOperationToken(rawValue: 30),
            to: PixelSize(width: 63, height: 64),
            maximumRetainedBytes: Int.max
        )
    }
    #expect(throws: MetalRendererError.rasterRevisionStorageLimitExceeded) {
        try renderer.requestResize(
            token: RendererOperationToken(rawValue: 31),
            to: PixelSize(width: 96, height: 80),
            maximumRetainedBytes: 0
        )
    }
    #expect(renderer.harnessTilingMutationSnapshot == snapshot)
    #expect(renderer.harnessRasterRevisionResidentBytes == 0)
    #expect(renderer.isIdle)
}

private func deterministicPixels(_ size: PixelSize) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
    for y in 0..<size.height {
        for x in 0..<size.width {
            let offset = (y * size.width + x) * 4
            bytes[offset] = UInt8(truncatingIfNeeded: x &* 13 &+ y &* 7)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: x &* 3 &+ y &* 17)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: x &* 19 &+ y &* 5)
            bytes[offset + 3] = UInt8(truncatingIfNeeded: 1 &+ x &+ y)
        }
    }
    return bytes
}

private func croppedOrFilled(
    _ source: [UInt8],
    from sourceSize: PixelSize,
    to destinationSize: PixelSize
) -> [UInt8] {
    var destination = [UInt8](
        repeating: 0,
        count: destinationSize.width * destinationSize.height * 4
    )
    let width = min(sourceSize.width, destinationSize.width)
    let height = min(sourceSize.height, destinationSize.height)
    for y in 0..<height {
        let sourceStart = y * sourceSize.width * 4
        let destinationStart = y * destinationSize.width * 4
        destination.replaceSubrange(
            destinationStart..<(destinationStart + width * 4),
            with: source[sourceStart..<(sourceStart + width * 4)]
        )
    }
    return destination
}

@MainActor
private func canonicalBytes(_ renderer: GridRenderer) throws -> [UInt8] {
    let texture = try renderer.copyCanonicalForHarness()
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
