import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Committed document snapshots")
struct CommittedDocumentSnapshotTests {
    @Test
    @MainActor
    func periodicCaptureAndFreshRendererRestoreExactCanonicalBytes()
        throws
    {
        guard let (device, library) = try snapshotTestMetal() else {
            return
        }
        let size = PixelSize(width: 64, height: 64)
        let configuration = SymmetryDocumentConfiguration.periodic(
            .legacy(
                presetID: .halfDrop,
                tileSize: PatternSize(width: 64, height: 64)
            )
        )
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            configuration: TilingCanvasConfiguration(
                pixelSize: size,
                documentConfiguration: configuration
            )
        )
        let original = snapshotOpaqueBytes(size, salt: 7)
        try renderer.replaceCanonicalPixelsForHarness(original)

        let snapshot = try renderer.captureCommittedDocument()
        guard case let .singleRaster(bytes) = snapshot.storage else {
            Issue.record("Periodic snapshot used paged storage")
            return
        }
        #expect(bytes == original)
        #expect(snapshot.documentConfiguration == configuration)

        let restored = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            committedSnapshot: snapshot
        )
        #expect(try restored.captureCommittedDocument() == snapshot)
        #expect(restored.documentConfiguration == configuration)
        #expect(!restored.radialGeometryLocked)
        #expect(restored.documentDomainLocked)
    }

    @Test
    @MainActor
    func activeDraftIsExcludedFromCommittedCapture() throws {
        guard let (device, library) = try snapshotTestMetal() else {
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
        let committed = snapshotOpaqueBytes(size, salt: 3)
        try renderer.replaceCanonicalPixelsForHarness(committed)
        _ = try renderer.beginFixedProjectedStrokeForHarness(
            at: WorldPoint(x: 17, y: 23)
        )

        let captured = try renderer.captureCommittedDocument()

        guard case let .singleRaster(bytes) = captured.storage else {
            Issue.record("Periodic snapshot used paged storage")
            return
        }
        #expect(bytes == committed)
        #expect(renderer.hasActiveStroke)
    }

    @Test
    @MainActor
    func radialPagesAndLockRoundTripWithoutAtlasIdentityLeak()
        throws
    {
        guard let (device, library) = try snapshotTestMetal() else {
            return
        }
        let size = PixelSize(width: 64, height: 64)
        let radial = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 5,
            center: WorldPoint(x: 31, y: 29),
            referenceAngleRadians: 0.25
        )
        let configuration = SymmetryDocumentConfiguration.finite(
            .radial(radial)
        )
        let compiled = try SymmetryDescriptorCompiler.compile(
            documentConfiguration: configuration,
            canvasSize: size
        )
        let layout = try #require(compiled.domain.finite?.radial.layout)
        let resident = try #require(layout.residentPages.first)
        let pageSize = PixelSize(
            width: RadialSectorLayout.pageSide,
            height: RadialSectorLayout.pageSide
        )
        let pageBytes = snapshotOpaqueBytes(pageSize, salt: 29)
        let snapshot = CommittedDocumentSnapshot(
            canvasSize: size,
            documentConfiguration: configuration,
            radialGeometryLocked: true,
            storage: .radialPages([
                CommittedRadialPagePixels(
                    coordinate: resident.coordinate,
                    bgra8PremultipliedBytes: pageBytes
                ),
            ])
        )

        let restored = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            committedSnapshot: snapshot
        )
        let captured = try restored.captureCommittedDocument()

        #expect(captured == snapshot)
        #expect(restored.radialGeometryLocked)
        #expect(restored.documentDomainLocked)
    }

    @Test
    @MainActor
    func incompatibleRadialPayloadFailsBeforeAReplacementEscapes()
        throws
    {
        guard let (device, library) = try snapshotTestMetal() else {
            return
        }
        let size = PixelSize(width: 64, height: 64)
        let configuration = SymmetryDocumentConfiguration.finite(
            .radial(RadialSymmetryConfiguration(
                kind: .rotation,
                rayCount: 5,
                center: WorldPoint(x: 32, y: 32)
            ))
        )
        let pageSize = PixelSize(
            width: RadialSectorLayout.pageSide,
            height: RadialSectorLayout.pageSide
        )
        let unlockedNonempty = CommittedDocumentSnapshot(
            canvasSize: size,
            documentConfiguration: configuration,
            radialGeometryLocked: false,
            storage: .radialPages([
                CommittedRadialPagePixels(
                    coordinate: RadialPageCoordinate(x: 0, y: 0),
                    bgra8PremultipliedBytes:
                        snapshotOpaqueBytes(pageSize, salt: 1)
                ),
            ])
        )
        #expect(
            throws: MetalRendererError.committedSnapshotIncompatible
        ) {
            try GridRenderer(
                device: device,
                library: library,
                drawableSize: PatternSize(width: 64, height: 64),
                committedSnapshot: unlockedNonempty
            )
        }

        let malformed = CommittedDocumentSnapshot(
            canvasSize: size,
            documentConfiguration: configuration,
            radialGeometryLocked: true,
            storage: .radialPages([
                CommittedRadialPagePixels(
                    coordinate: RadialPageCoordinate(
                        x: 1_000_000,
                        y: -1_000_000
                    ),
                    bgra8PremultipliedBytes:
                        snapshotOpaqueBytes(pageSize, salt: 2)
                ),
            ])
        )
        #expect(
            throws: MetalRendererError.committedSnapshotIncompatible
        ) {
            try GridRenderer(
                device: device,
                library: library,
                drawableSize: PatternSize(width: 64, height: 64),
                committedSnapshot: malformed
            )
        }
    }
}

@MainActor
private func snapshotTestMetal()
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

private func snapshotOpaqueBytes(
    _ size: PixelSize,
    salt: UInt8
) -> [UInt8] {
    (0..<(size.width * size.height)).flatMap { index in
        let value = UInt8(truncatingIfNeeded: index) &+ salt
        return [value, value &* 3, value &* 7, 255]
    }
}
