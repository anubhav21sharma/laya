import Metal
import MetalKit
@testable import MetalRenderer
import PatternEngine
import Testing

@MainActor
private func makeResizeRenderer(pixelSize: PixelSize) throws -> GridRenderer? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let shader = try String(
        contentsOf: root.appendingPathComponent("Sources/MetalRenderer/Shaders.metal"),
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
        configuration: TilingCanvasConfiguration(pixelSize: pixelSize, tiling: .grid)
    )
}

@Test
@MainActor
func currentResizeShrinkCropsOnlyRightAndBottomBytes() async throws {
    let oldSize = PixelSize(width: 96, height: 80)
    let newSize = PixelSize(width: 64, height: 64)
    guard let renderer = try makeResizeRenderer(pixelSize: oldSize) else { return }
    let original = deterministicResizePixels(oldSize)
    try await installResizePixels(original, into: renderer)

    try await renderer.resizeDocument(
        token: RendererOperationToken(rawValue: 1),
        to: newSize
    )

    #expect(renderer.pixelSize == newSize)
    #expect(
        try await resizeSnapshotBytes(renderer)
            == croppedOrFilledResizePixels(original, from: oldSize, to: newSize)
    )
}

@Test
@MainActor
func currentResizeGrowPreservesTopLeftAndTransparentFillsRemainder()
    async throws
{
    let oldSize = PixelSize(width: 64, height: 64)
    let newSize = PixelSize(width: 96, height: 80)
    guard let renderer = try makeResizeRenderer(pixelSize: oldSize) else { return }
    let original = deterministicResizePixels(oldSize)
    try await installResizePixels(original, into: renderer)

    try await renderer.resizeDocument(
        token: RendererOperationToken(rawValue: 2),
        to: newSize
    )

    #expect(
        try await resizeSnapshotBytes(renderer)
            == croppedOrFilledResizePixels(original, from: oldSize, to: newSize)
    )
}

@Test
@MainActor
func currentResizeHistoryRestoresExactDimensionsAndBytes() async throws {
    let oldSize = PixelSize(width: 96, height: 80)
    let newSize = PixelSize(width: 64, height: 64)
    guard let renderer = try makeResizeRenderer(pixelSize: oldSize) else { return }
    let original = deterministicResizePixels(oldSize)
    try await installResizePixels(original, into: renderer)
    let initialIdentity = renderer.paintCanonicalStateIdentityForTesting()
    var receipt: LayerGeometryMutationReceipt?
    renderer.onOperationCompleted = {
        if case let .layerGeometrySuccess(value) = $0 { receipt = value }
    }

    try await renderer.resizeDocument(
        token: RendererOperationToken(rawValue: 10),
        to: newSize
    )
    let history = try #require(receipt)
    let resized = try await resizeSnapshotBytes(renderer)
    let resizedIdentity = renderer.paintCanonicalStateIdentityForTesting()

    #expect(resizedIdentity.geometry.documentPixelSize == newSize)
    #expect(resizedIdentity.geometryRevision
        == initialIdentity.geometryRevision + 1)
    #expect(resizedIdentity.layerStackRevision
        == initialIdentity.layerStackRevision + 1)
    #expect(resizedIdentity.compositeRevision
        == initialIdentity.compositeRevision + 1)

    #expect(try renderer.restoreLayerGeometryBefore(history.revision) == oldSize)
    #expect(renderer.pixelSize == oldSize)
    #expect(try await resizeSnapshotBytes(renderer) == original)
    let beforeIdentity = renderer.paintCanonicalStateIdentityForTesting()
    #expect(beforeIdentity.geometry == initialIdentity.geometry)
    #expect(beforeIdentity.geometryRevision
        == resizedIdentity.geometryRevision + 1)
    #expect(beforeIdentity != initialIdentity)

    #expect(try renderer.restoreLayerGeometryAfter(history.revision) == newSize)
    #expect(renderer.pixelSize == newSize)
    #expect(try await resizeSnapshotBytes(renderer) == resized)
    let afterIdentity = renderer.paintCanonicalStateIdentityForTesting()
    #expect(afterIdentity.geometry == resizedIdentity.geometry)
    #expect(afterIdentity.geometryRevision
        == beforeIdentity.geometryRevision + 1)
    #expect(afterIdentity != resizedIdentity)
    try await renderer.releasePaintRevisions([history.revision.id])
}

@Test
@MainActor
func resizeHistorySnapshotOwnershipIsRetainedButNotPending() async throws {
    let oldSize = PixelSize(width: 96, height: 80)
    let newSize = PixelSize(width: 64, height: 64)
    guard let renderer = try makeResizeRenderer(pixelSize: oldSize) else { return }
    try await installResizePixels(
        deterministicResizePixels(oldSize),
        into: renderer
    )
    var receipt: LayerGeometryMutationReceipt?
    renderer.onOperationCompleted = {
        if case let .layerGeometrySuccess(value) = $0 { receipt = value }
    }

    try await renderer.resizeDocument(
        token: RendererOperationToken(rawValue: 11),
        to: newSize
    )
    let evidence = await renderer.stageDAcceptanceEvidence()

    #expect(evidence.activeSnapshotTokenCount == 1)
    #expect(evidence.retainedHistorySnapshotTokenCount == 1)
    #expect(evidence.pendingOwnershipCount == 0)
    let history = try #require(receipt)
    try await renderer.releasePaintRevisions([history.revision.id])
}

@Test
@MainActor
func captureSuspensionDeadlineBoundsCancellationInsensitivePreparation()
    async throws
{
    let size = PixelSize(width: 64, height: 64)
    guard let renderer = try makeResizeRenderer(pixelSize: size) else { return }
    let gate = DocumentPaintPreparationTestGate()
    let blockedPreparation = Task { await gate.wait() }
    renderer.installPaintDisplayPreparationTaskForTesting(blockedPreparation)
    let view = MTKView(
        frame: CGRect(x: 0, y: 0, width: 64, height: 64),
        device: renderer.device
    )
    let started = DispatchTime.now().uptimeNanoseconds
    let deadline = started + 10_000_000

    await #expect(throws: MetalRendererError.self) {
        try await renderer.suspendPaintDisplayPreparationForCapture(
            deadlineUptimeNanoseconds: deadline
        )
    }

    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    #expect(elapsed < 1_000_000_000)
    #expect(!renderer.paintDisplayPreparationIsSuspendedForTesting)
    #expect(renderer.paintDisplayPreparationIsRetiringForTesting)
    renderer.draw(in: view)
    #expect(renderer.paintDisplayPreparationScheduleCountForTesting == 0)
    #expect(renderer.lastError == nil)
    await gate.open()
    await blockedPreparation.value
    for _ in 0..<1_000
    where renderer.paintDisplayPreparationIsRetiringForTesting {
        await Task.yield()
    }
    #expect(!renderer.paintDisplayPreparationIsRetiringForTesting)
    #expect(renderer.paintDisplayPreparationScheduleCountForTesting == 1)
    #expect(renderer.lastError == nil)
}

@Test
@MainActor
func invalidCurrentResizeLeavesGeometryAndPixelsUnchanged() async throws {
    let size = PixelSize(width: 64, height: 64)
    guard let renderer = try makeResizeRenderer(pixelSize: size) else { return }
    let original = deterministicResizePixels(size)
    try await installResizePixels(original, into: renderer)

    await #expect(throws: MetalRendererError.self) {
        try await renderer.resizeDocument(
            token: RendererOperationToken(rawValue: 20),
            to: PixelSize(width: 63, height: 64)
        )
    }

    #expect(renderer.pixelSize == size)
    #expect(try await resizeSnapshotBytes(renderer) == original)
}

@MainActor
private func installResizePixels(
    _ bytes: [UInt8],
    into renderer: GridRenderer
) async throws {
    try await renderer.restoreCommittedDocument(CommittedDocumentSnapshot(
        canvasSize: renderer.pixelSize,
        documentConfiguration: renderer.documentConfiguration,
        documentDomainLocked: bytes.contains { $0 != 0 },
        radialGeometryLocked: false,
        storage: .singleRaster(bgra8PremultipliedBytes: bytes)
    ))
}

@MainActor
private func resizeSnapshotBytes(_ renderer: GridRenderer) async throws -> [UInt8] {
    let snapshot = try await renderer.captureCommittedDocument()
    guard case let .singleRaster(bytes) = snapshot.storage else {
        throw MetalRendererError.committedSnapshotIncompatible
    }
    return bytes
}

private func deterministicResizePixels(_ size: PixelSize) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
    for y in 0..<size.height {
        for x in 0..<size.width {
            let offset = (y * size.width + x) * 4
            bytes[offset] = UInt8(truncatingIfNeeded: x &* 13 &+ y &* 7)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: x &* 3 &+ y &* 17)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: x &* 19 &+ y &* 5)
            bytes[offset + 3] = 255
        }
    }
    return bytes
}

private func croppedOrFilledResizePixels(
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
