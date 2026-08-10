import EditorCore
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import PatternFile
import Testing

@Suite("Pattern project app bridge", .serialized)
struct PatternProjectBridgeTests {
    @Test
    @MainActor
    func nativeMultiLayerSaveLoadSavePreservesRawTilesAndMetadata()
        async throws
    {
        guard let (device, library) = try bridgeTestMetal() else { return }
        let size = PixelSize(width: 64, height: 64)
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 160, height: 120),
            configuration: TilingCanvasConfiguration(
                pixelSize: size,
                tiling: .brick
            )
        )
        try await bridgeInstallSingleRaster(
            bridgeOpaqueBytes(size, salt: 17),
            into: renderer
        )
        var stack = renderer.layerStack
        let top = try LayerDescriptor(
            id: UUID(
                uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa"
            )!,
            name: "Highlights",
            isVisible: false,
            opacity: 0.5,
            isLocked: true,
            blendMode: .screen
        )
        try stack.add(top, at: 1)
        _ = try renderer.applyLayerStack(stack)
        renderer.restoreSavedViewport(
            worldCenter: WorldPoint(x: 41, y: 27),
            zoom: 2
        )
        let identity = PatternProjectIdentity(
            documentID: UUID(
                uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )!,
            title: "Bridge",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_100)

        let firstCapture = try await PatternProjectBridge.capture(
            renderer: renderer,
            identity: identity,
            appVersion: "0.1.0",
            modifiedAt: modifiedAt
        )
        let firstBytes = try save(firstCapture)
        let decoded = try PatternProjectPackageCodec.open(firstBytes)
        let restored = try await PatternProjectBridge.makeRenderer(
            from: decoded,
            device: device,
            library: library,
            drawableSize: PatternSize(width: 160, height: 120)
        )

        #expect(restored.layerStack == stack)
        #expect(restored.viewport.worldCenter == WorldPoint(x: 41, y: 27))
        #expect(restored.viewport.zoom == 2)
        #expect(restored.documentDomainLocked)
        #expect(!restored.radialGeometryLocked)
        #expect(try PatternProjectBridge.identity(from: decoded) == identity)
        let originalNative = try renderer.captureNativeArchive()
        let restoredNative = try restored.captureNativeArchive()
        defer {
            originalNative.close()
            restoredNative.close()
        }
        #expect(originalNative.layers == restoredNative.layers)
        for tile in originalNative.layers.flatMap(\.tiles) {
            #expect(try originalNative.payload(for: tile.persistedID)
                == restoredNative.payload(for: tile.persistedID))
        }

        let secondCapture = try await PatternProjectBridge.capture(
            renderer: restored,
            identity: identity,
            appVersion: "0.1.0",
            modifiedAt: modifiedAt
        )
        #expect(try save(secondCapture) == firstBytes)
    }

    @Test
    @MainActor
    func nativeImportedRendererCanInstallBrushesAndDraw() async throws {
        guard let (device, library) = try bridgeTestMetal() else { return }
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            configuration: TilingCanvasConfiguration(
                pixelSize: PixelSize(width: 64, height: 64),
                tiling: .grid
            )
        )
        let captured = try await PatternProjectBridge.capture(
            renderer: renderer,
            identity: .new(),
            appVersion: "0.1.0"
        )
        let decoded = try PatternProjectPackageCodec.open(save(captured))
        let importedRenderer = try await PatternProjectBridge.makeRenderer(
            from: decoded,
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64)
        )
        try importedRenderer.installNativeHarnessBrushes()
        let imported = EditorSessionController(renderer: importedRenderer)
        imported.handleStrokeSamples([
            .mouse(
                position: ScreenPoint(x: 10, y: 10),
                timestamp: 1,
                phase: .began
            ),
            .mouse(
                position: ScreenPoint(x: 40, y: 40),
                timestamp: 2,
                phase: .ended
            ),
        ])
        _ = try await importedRenderer
            .completePendingInteractiveStrokeAndAwaitIdle()

        #expect(importedRenderer.isIdle)
        #expect(importedRenderer.documentDomainLocked)
        #expect(try importedRenderer.captureNativeArchive()
            .layers.flatMap(\.tiles).count > 0)
    }

    @Test
    @MainActor
    func nonemptyNativeProjectCannotClaimAnUnlockedDocument() async throws {
        guard let (device, library) = try bridgeTestMetal() else { return }
        let size = PixelSize(width: 64, height: 64)
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            configuration: TilingCanvasConfiguration(
                pixelSize: size,
                tiling: .grid
            )
        )
        try await bridgeInstallSingleRaster(
            bridgeOpaqueBytes(size, salt: 31),
            into: renderer
        )
        let captured = try await PatternProjectBridge.capture(
            renderer: renderer,
            identity: .new(),
            appVersion: "0.1.0"
        )
        let metadata = captured.metadata
        let invalid = PatternProjectMetadata(
            documentID: metadata.documentID,
            title: metadata.title,
            appVersion: metadata.appVersion,
            createdAt: metadata.createdAt,
            modifiedAt: metadata.modifiedAt,
            canvasSize: metadata.canvasSize,
            viewport: metadata.viewport,
            documentConfiguration: metadata.documentConfiguration,
            documentDomainLocked: false,
            radialGeometryLocked: metadata.radialGeometryLocked,
            activeLayerID: metadata.activeLayerID,
            layers: metadata.layers
        )
        let decoded = try PatternProjectPackageCodec.open(
            save(captured, metadata: invalid)
        )

        await #expect(throws: PatternProjectBridgeError.incompatibleSurface) {
            try await PatternProjectBridge.makeRenderer(
                from: decoded,
                device: device,
                library: library,
                drawableSize: PatternSize(width: 64, height: 64)
            )
        }
    }
}

private func save(
    _ captured: CapturedPatternProject,
    metadata: PatternProjectMetadata? = nil
) throws -> Data {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("project.patternproj")
    try PatternProjectPackageCodec.save(
        metadata: metadata ?? captured.metadata,
        tilePayloadProvider: captured,
        to: destination
    )
    return try Data(contentsOf: destination)
}

@MainActor
private func bridgeInstallSingleRaster(
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
private func bridgeTestMetal()
    throws -> ((any MTLDevice), any MTLLibrary)?
{
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
    return (device, library)
}

private func bridgeOpaqueBytes(
    _ size: PixelSize,
    salt: UInt8
) -> [UInt8] {
    (0..<(size.width * size.height)).flatMap { index in
        let value = UInt8(truncatingIfNeeded: index) &+ salt
        return [value, value &* 3, value &* 7, 255]
    }
}
