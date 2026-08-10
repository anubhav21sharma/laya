import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import PatternFile
import Testing

@Suite("Pattern project app bridge")
struct PatternProjectBridgeTests {
    @Test
    @MainActor
    func rendererPackageAndFreshRendererRoundTripCommittedPixels()
        async throws
    {
        guard let (device, library) = try bridgeTestMetal() else {
            return
        }
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
        let bytes = bridgeOpaqueBytes(size, salt: 17)
        try await bridgeInstallSingleRaster(bytes, into: renderer)
        renderer.restoreSavedViewport(
            worldCenter: WorldPoint(x: 41, y: 27),
            zoom: 2
        )
        let identity = PatternProjectIdentity(
            documentID: UUID(
                uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )!,
            layerID: UUID(
                uuidString: "11111111-2222-3333-4444-555555555555"
            )!,
            title: "Bridge",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let captured = try await PatternProjectBridge.capture(
            renderer: renderer,
            identity: identity,
            appVersion: "0.1.0",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let encoded = try PatternProjectPackageCodec.encode(
            metadata: captured.metadata,
            rastersByPath: captured.rastersByPath
        )
        let decoded = try PatternProjectPackageCodec.open(encoded)
        let snapshot = try PatternProjectBridge.committedSnapshot(
            from: decoded
        )
        let restored = try await bridgeRestoredRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 160, height: 120),
            snapshot: snapshot
        )
        restored.restoreSavedViewport(
            worldCenter: WorldPoint(
                x: decoded.metadata.metadata.viewport.offsetX,
                y: decoded.metadata.metadata.viewport.offsetY
            ),
            zoom: decoded.metadata.metadata.viewport.scale
        )

        #expect(try await restored.captureCommittedDocument() == snapshot)
        #expect(restored.viewport.worldCenter == WorldPoint(x: 41, y: 27))
        #expect(restored.viewport.zoom == 2)
        #expect(try PatternProjectBridge.identity(from: decoded) == identity)
    }

    @Test
    @MainActor
    func importedRendererKeepsBrushRuntimeAndCanDraw() async throws {
        guard let (device, library) = try bridgeTestMetal() else {
            return
        }
        let size = PixelSize(width: 64, height: 64)
        let sourceRenderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 160, height: 120),
            configuration: TilingCanvasConfiguration(
                pixelSize: size,
                tiling: .grid
            )
        )
        try sourceRenderer.installNativeHarnessBrushes()
        let source = EditorSessionController(renderer: sourceRenderer)
        source.handleInkColor(
            try #require(
                InkColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
            )
        )
        source.model.confirmBrushDiameter(32)
        source.handleGridVisibility(true)

        let importedRenderer = try await bridgeRestoredRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 160, height: 120),
            snapshot:
                try await sourceRenderer.captureCommittedDocument()
        )
        #expect(importedRenderer.preparedBrush(for: .draw) == nil)
        #expect(importedRenderer.preparedBrush(for: .erase) == nil)

        let imported = try source.replacementSession(
            renderer: importedRenderer
        )

        #expect(importedRenderer.preparedBrush(for: .draw) != nil)
        #expect(importedRenderer.preparedBrush(for: .erase) != nil)
        #expect(imported.model.inkColor == source.model.inkColor)
        #expect(imported.model.brushDiameter == 32)
        #expect(imported.model.showGrid)

        imported.handleStrokeSamples([
            .mouse(
                position: ScreenPoint(x: 16, y: 16),
                timestamp: 1,
                phase: .began
            ),
            .mouse(
                position: ScreenPoint(x: 48, y: 48),
                timestamp: 2,
                phase: .ended
            ),
        ])
        try await importedRenderer
            .completePendingInteractiveStrokeAndAwaitIdle()

        #expect(importedRenderer.isIdle)
        #expect(imported.model.canUndo)
        #expect(importedRenderer.documentDomainLocked)
    }

    @Test
    @MainActor
    func transparentButLogicallyEditedPeriodicProjectStaysLocked()
        async throws
    {
        guard let (device, library) = try bridgeTestMetal() else {
            return
        }
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
        try renderer.reconcileGeometryLock(documentIsEmpty: false)
        let identity = PatternProjectIdentity(
            documentID: UUID(),
            layerID: UUID(),
            title: "Transparent edit",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let captured = try await PatternProjectBridge.capture(
            renderer: renderer,
            identity: identity,
            appVersion: "0.1.0",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let decoded = try PatternProjectPackageCodec.open(
            PatternProjectPackageCodec.encode(
                metadata: captured.metadata,
                rastersByPath: captured.rastersByPath
            )
        )
        let restored = try await bridgeRestoredRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            snapshot: try PatternProjectBridge.committedSnapshot(
                from: decoded
            )
        )

        #expect(restored.documentDomainLocked)
        #expect(!restored.radialGeometryLocked)
    }

    @Test
    @MainActor
    func schemaThreeUnlockedProjectRejectsNonzeroCommittedPixels()
        async throws
    {
        guard let (device, library) = try bridgeTestMetal() else {
            return
        }
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
        let invalidMetadata = PatternProjectMetadata(
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
            PatternProjectPackageCodec.encode(
                metadata: invalidMetadata,
                rastersByPath: captured.rastersByPath
            )
        )

        #expect(throws: PatternProjectBridgeError.incompatibleSurface) {
            try PatternProjectBridge.committedSnapshot(from: decoded)
        }
    }

    @Test
    @MainActor
    func radialBridgeUsesLogicalPageCoordinatesAndPreservesLock()
        async throws
    {
        guard let (device, library) = try bridgeTestMetal() else {
            return
        }
        let size = PixelSize(width: 64, height: 64)
        let configuration = SymmetryDocumentConfiguration.finite(
            .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 7,
                center: WorldPoint(x: 31, y: 29),
                referenceAngleRadians: 0.1
            ))
        )
        let compiled = try SymmetryDescriptorCompiler.compile(
            documentConfiguration: configuration,
            canvasSize: size
        )
        let resident = try #require(
            compiled.domain.finite?.radial.layout?.residentPages.first
        )
        let pageSize = PixelSize(
            width: RadialSectorLayout.pageSide,
            height: RadialSectorLayout.pageSide
        )
        let initial = CommittedDocumentSnapshot(
            canvasSize: size,
            documentConfiguration: configuration,
            radialGeometryLocked: true,
            storage: .radialPages([
                CommittedRadialPagePixels(
                    coordinate: resident.coordinate,
                    bgra8PremultipliedBytes:
                        bridgeOpaqueBytes(pageSize, salt: 23)
                ),
            ])
        )
        let renderer = try await bridgeRestoredRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            snapshot: initial
        )
        let identity = PatternProjectIdentity(
            documentID: UUID(),
            layerID: UUID(),
            title: "Radial",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let captured = try await PatternProjectBridge.capture(
            renderer: renderer,
            identity: identity,
            appVersion: "0.1.0",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let decoded = try PatternProjectPackageCodec.open(
            PatternProjectPackageCodec.encode(
                metadata: captured.metadata,
                rastersByPath: captured.rastersByPath
            )
        )
        let restored = try PatternProjectBridge.committedSnapshot(
            from: decoded
        )

        #expect(restored == initial)
        #expect(decoded.metadata.metadata.radialGeometryLocked)
    }
}

@MainActor
private func bridgeRestoredRenderer(
    device: any MTLDevice,
    library: any MTLLibrary,
    drawableSize: PatternSize,
    snapshot: CommittedDocumentSnapshot
) async throws -> GridRenderer {
    let renderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: drawableSize,
        configuration: try TilingCanvasConfiguration(
            pixelSize: snapshot.canvasSize,
            documentConfiguration: snapshot.documentConfiguration
        )
    )
    try await renderer.restoreCommittedDocument(snapshot)
    return renderer
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
