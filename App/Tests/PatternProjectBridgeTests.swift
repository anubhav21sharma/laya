import Foundation
import Metal
import MetalRenderer
import PatternEngine
import PatternFile
import Testing

@Suite("Pattern project app bridge")
struct PatternProjectBridgeTests {
    @Test
    @MainActor
    func rendererPackageAndFreshRendererRoundTripCommittedPixels()
        throws
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
        try renderer.replaceCanonicalPixelsForHarness(bytes)
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

        let captured = try PatternProjectBridge.capture(
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
        let restored = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 160, height: 120),
            committedSnapshot: snapshot
        )
        restored.restoreSavedViewport(
            worldCenter: WorldPoint(
                x: decoded.metadata.metadata.viewport.offsetX,
                y: decoded.metadata.metadata.viewport.offsetY
            ),
            zoom: decoded.metadata.metadata.viewport.scale
        )

        #expect(try restored.captureCommittedDocument() == snapshot)
        #expect(restored.viewport.worldCenter == WorldPoint(x: 41, y: 27))
        #expect(restored.viewport.zoom == 2)
        #expect(try PatternProjectBridge.identity(from: decoded) == identity)
    }

    @Test
    @MainActor
    func radialBridgeUsesLogicalPageCoordinatesAndPreservesLock()
        throws
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
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            committedSnapshot: initial
        )
        let identity = PatternProjectIdentity(
            documentID: UUID(),
            layerID: UUID(),
            title: "Radial",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let captured = try PatternProjectBridge.capture(
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
