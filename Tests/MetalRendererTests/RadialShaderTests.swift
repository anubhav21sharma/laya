import EditorCore
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Radial production Metal path")
struct RadialShaderTests {
    @Test(arguments: [
        RadialSymmetryKind.rotation,
        .mandala,
        .mirror,
    ])
    @MainActor
    func committedDabAppearsAtEveryIndependentOrbitPoint(
        kind: RadialSymmetryKind
    ) async throws {
        let rays = kind == .mirror ? 1 : 4
        let configuration = RadialSymmetryConfiguration(
            kind: kind,
            rayCount: rays,
            center: WorldPoint(x: 64, y: 64),
            referenceAngleRadians: .pi / 11
        )
        guard let renderer = try makeRadialRenderer(configuration) else {
            return
        }

        try await commitRadialDab(
            renderer,
            at: ScreenPoint(x: 92, y: 71)
        )
        let display = try await renderer.renderOffscreenDisplayForHarness(
            width: 128,
            height: 128,
            showGridLines: false
        )
        let bytes = radialTextureBytes(display.texture)
        let orbit = RadialCoverageOracle.orbit(
            of: WorldPoint(x: 92, y: 71),
            configuration: configuration
        )

        #expect(orbit.count == (kind == .rotation ? rays : 2 * rays))
        for point in orbit {
            #expect(
                radialPixelIsInk(
                    bytes,
                    width: display.texture.width,
                    point: point
                ),
                "Missing radial image near \(point)"
            )
        }
    }

    @Test
    @MainActor
    func radialGuideChangesBlankFiniteDisplay() async throws {
        let configuration = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 8,
            center: WorldPoint(x: 47, y: 73),
            referenceAngleRadians: -.pi / 7
        )
        guard let renderer = try makeRadialRenderer(configuration) else {
            return
        }

        let plain = try await renderer.renderOffscreenDisplayForHarness(
            width: 128,
            height: 128,
            showGridLines: false
        )
        let guided = try await renderer.renderOffscreenDisplayForHarness(
            width: 128,
            height: 128,
            showGridLines: true
        )

        #expect(
            radialTextureBytes(plain.texture)
                != radialTextureBytes(guided.texture)
        )
    }

    @Test
    @MainActor
    func finiteCanvasBoundaryRemainsVisibleWhenGridIsHidden() async throws {
        let configuration = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 8,
            center: WorldPoint(x: 64, y: 64)
        )
        guard let renderer = try makeRadialRenderer(configuration) else {
            return
        }

        let display = try await renderer.renderOffscreenDisplayForHarness(
            width: 128,
            height: 128,
            showGridLines: false
        )
        let bytes = radialTextureBytes(display.texture)
        let edgeOffset = (64 * 128) * 4
        let centerOffset = (64 * 128 + 64) * 4

        #expect(
            Array(bytes[edgeOffset..<(edgeOffset + 4)])
                != Array(bytes[centerOffset..<(centerOffset + 4)])
        )
    }

    @Test
    @MainActor
    func radialEraseAndClearAffectEveryLinkedImageAndUnlockEmptyCanvas()
        async throws
    {
        let radial = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 6,
            center: WorldPoint(x: 64, y: 64),
            referenceAngleRadians: .pi / 17
        )
        guard let renderer = try makeRadialRenderer(radial) else { return }
        let source = ScreenPoint(x: 91, y: 70)
        try await commitRadialDab(
            renderer,
            at: source,
            tokenValue: 30
        )
        let orbit = RadialCoverageOracle.orbit(
            of: WorldPoint(x: source.x, y: source.y),
            configuration: radial
        )
        let drawn = try await renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        #expect(orbit.allSatisfy {
            radialPixelIsInk(
                drawn.bgra8Bytes,
                width: 128,
                point: $0
            )
        })

        let eraseStyle = radialTemplateStyle(
            color: .black,
            diameter: 20,
            compositeMode: .erase,
            eraserStrength: 1
        )
        try await commitRadialDab(
            renderer,
            at: source,
            tokenValue: 31,
            style: eraseStyle
        )
        let erased = try await renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        #expect(orbit.allSatisfy {
            !radialPixelIsInk(
                erased.bgra8Bytes,
                width: 128,
                point: $0
            )
        })
        #expect(renderer.radialGeometryLocked)

        try await commitRadialDab(
            renderer,
            at: source,
            tokenValue: 32
        )
        try await renderer.clearDocument(
            token: RendererOperationToken(rawValue: 33)
        )
        let cleared = try await renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        #expect(
            stride(from: 3, to: cleared.bgra8Bytes.count, by: 4)
                .allSatisfy { cleared.bgra8Bytes[$0] == 0 }
        )
        #expect(!renderer.documentDomainLocked)
        #expect(!renderer.radialGeometryLocked)
        try await renderer.applyFiniteConfiguration(.plain)
        #expect(renderer.documentConfiguration == .finite(.plain))
    }

    @Test
    @MainActor
    func radialResizeCropsByOrbitWithoutScalingOrResurrection()
        async throws
    {
        let radial = RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 4,
            center: WorldPoint(x: 55, y: 55)
        )
        guard let renderer = try makeRadialRenderer(radial) else { return }
        try await commitRadialDab(
            renderer,
            at: ScreenPoint(x: 75, y: 55),
            tokenValue: 1
        )
        try await commitRadialDab(
            renderer,
            at: ScreenPoint(x: 127, y: 55),
            tokenValue: 2
        )
        let original = try await renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        #expect(
            radialPixelIsInk(
                original.bgra8Bytes,
                width: 128,
                point: WorldPoint(x: 126, y: 55)
            )
        )

        var resizeReceipt: RasterMutationReceipt?
        renderer.onOperationCompleted = { completion in
            if case let .rasterSuccess(receipt) = completion {
                resizeReceipt = receipt
            }
        }
        try await renderer.resizeDocument(
            token: RendererOperationToken(rawValue: 3),
            to: PixelSize(width: 64, height: 64)
        )
        let receipt = try #require(resizeReceipt)
        #expect(receipt.before.documentPixelSize == PixelSize(width: 128, height: 128))
        #expect(receipt.after.documentPixelSize == PixelSize(width: 64, height: 64))
        #expect(renderer.pixelSize == PixelSize(width: 64, height: 64))
        #expect(renderer.radialGeometryLocked)

        let cropped = try await renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        #expect(
            radialPixelIsInk(
                cropped.bgra8Bytes,
                width: 64,
                height: 64,
                point: WorldPoint(x: 35, y: 55)
            )
        )

        try await renderer.resizeDocument(
            token: RendererOperationToken(rawValue: 4),
            to: PixelSize(width: 128, height: 128)
        )
        let expanded = try await renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        #expect(
            radialPixelIsInk(
                expanded.bgra8Bytes,
                width: 128,
                point: WorldPoint(x: 75, y: 55)
            )
        )
        #expect(
            !radialPixelIsInk(
                expanded.bgra8Bytes,
                width: 128,
                point: WorldPoint(x: 126, y: 55)
            )
        )
    }

    @Test
    @MainActor
    func radialResizeUndoRedoRestoresExactAtlasAndDocumentSize() async throws {
        let radial = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 5,
            center: WorldPoint(x: 55, y: 55),
            referenceAngleRadians: .pi / 13
        )
        guard let renderer = try makeRadialRenderer(radial) else { return }
        try await commitRadialDab(
            renderer,
            at: ScreenPoint(x: 76, y: 59),
            tokenValue: 10
        )
        let original = try await radialCanonicalBytes(renderer)
        var resizeReceipt: RasterMutationReceipt?
        renderer.onOperationCompleted = { completion in
            if case let .rasterSuccess(receipt) = completion {
                resizeReceipt = receipt
            }
        }

        try await renderer.resizeDocument(
            token: RendererOperationToken(rawValue: 11),
            to: PixelSize(width: 64, height: 64)
        )
        let receipt = try #require(resizeReceipt)
        let resized = try await radialCanonicalBytes(renderer)
        #expect(renderer.pixelSize == PixelSize(width: 64, height: 64))
        #expect(renderer.radialGeometryLocked)

        try await renderer.restoreDocumentRevision(
            token: RendererOperationToken(rawValue: 12),
            revision: receipt.before
        )
        #expect(renderer.pixelSize == PixelSize(width: 128, height: 128))
        #expect(try await radialCanonicalBytes(renderer) == original)
        #expect(renderer.radialGeometryLocked)

        try await renderer.restoreDocumentRevision(
            token: RendererOperationToken(rawValue: 13),
            revision: receipt.after
        )
        #expect(renderer.pixelSize == PixelSize(width: 64, height: 64))
        #expect(try await radialCanonicalBytes(renderer) == resized)
        #expect(renderer.radialGeometryLocked)

        try await renderer.releasePaintRevisions([
            receipt.before.id,
            receipt.after.id,
        ])
    }
}

@Suite("Finite full-canvas export")
struct FiniteCanvasExportTests {
    @Test
    @MainActor
    func plainTransparentExportPreservesExactCanvasPixels() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try makeFiniteRenderer(
            device: device,
            configuration: .plain,
            size: PixelSize(width: 64, height: 64)
        )
        let fixture = (0..<(64 * 64)).flatMap { index -> [UInt8] in
            let x = index % 64
            let y = index / 64
            let alpha = UInt8(truncatingIfNeeded: x * 7 + y * 11)
            guard alpha > 0 else { return [0, 0, 0, 0] }
            return [
                UInt8((x * 3) % (Int(alpha) + 1)),
                UInt8((y * 5) % (Int(alpha) + 1)),
                UInt8((x + y) % (Int(alpha) + 1)),
                alpha,
            ]
        }
        try await installFiniteCommittedRaster(fixture, into: renderer)

        let exported = try await renderer.exportFiniteCanvas(
            transparentBackground: true
        )

        #expect(exported.pixelSize == PixelSize(width: 64, height: 64))
        #expect(exported.bytesPerRow == 256)
        #expect(exported.bgra8Bytes == fixture)
        #expect(exported.hasTransparentBackground)
    }

    @Test
    @MainActor
    func radialExportUsesDocumentPixelsAndIgnoresViewportAndGuides()
        async throws
    {
        let radial = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 5,
            center: WorldPoint(x: 64, y: 64),
            referenceAngleRadians: .pi / 13
        )
        guard let renderer = try makeRadialRenderer(radial) else { return }
        try await commitRadialDab(
            renderer,
            at: ScreenPoint(x: 94, y: 70)
        )
        let beforeConfiguration = renderer.documentConfiguration
        let beforeLock = renderer.radialGeometryLocked
        let beforeCanonical = try await radialCanonicalBytes(renderer)

        let baseline = try await renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        renderer.pan(byScreenDelta: SIMD2(37, -19))
        renderer.zoom(
            by: 2.25,
            anchor: ScreenPoint(x: 17, y: 103)
        )
        renderer.setInteractiveGridVisibility(true)
        let transformed = try await renderer.exportFiniteCanvas(
            transparentBackground: true
        )

        #expect(transformed == baseline)
        #expect(renderer.documentConfiguration == beforeConfiguration)
        #expect(renderer.radialGeometryLocked == beforeLock)
        #expect(try await radialCanonicalBytes(renderer) == beforeCanonical)
        #expect(baseline.bgra8Bytes.contains { $0 != 0 })
        #expect(
            stride(from: 3, to: baseline.bgra8Bytes.count, by: 4)
                .contains { baseline.bgra8Bytes[$0] == 0 }
        )
    }

}

@MainActor
private func installFiniteCommittedRaster(
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

private let radialDrawStyle = radialTemplateStyle()

private func radialTemplateStyle(
    color: InkColor = .black,
    diameter: Float = 12,
    compositeMode: StrokeCompositeMode = .draw,
    eraserStrength: Float = 1
) -> StrokeRenderStyle {
    let program = try! BrushProgramCompiler.compile(
        GridRenderer.nativeHarnessDefinition(mode: compositeMode)
    )
    return StrokeRenderStyle(
        color: color,
        diameter: diameter,
        compositeMode: compositeMode,
        eraserStrength: eraserStrength,
        program: program,
        renderIdentity: try! BrushRenderIdentity(
            definitionID: program.definition.id,
            semanticHash: String(
                repeating: compositeMode == .draw ? "d" : "e",
                count: 64
            )
        ),
        seed: 1
    )
}

@MainActor
private func makeRadialRenderer(
    _ radial: RadialSymmetryConfiguration,
    size: PixelSize = PixelSize(width: 128, height: 128)
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
    let renderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(
            width: Float(size.width),
            height: Float(size.height)
        ),
        configuration: TilingCanvasConfiguration(
            pixelSize: size,
            finiteConfiguration: .radial(radial)
        )
    )
    try renderer.installNativeHarnessBrushes()
    return renderer
}

@MainActor
private func makeFiniteRenderer(
    device: any MTLDevice,
    configuration: FiniteSymmetryConfiguration,
    size: PixelSize
) throws -> GridRenderer {
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
    let renderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(
            width: Float(size.width),
            height: Float(size.height)
        ),
        configuration: TilingCanvasConfiguration(
            pixelSize: size,
            finiteConfiguration: configuration
        )
    )
    try renderer.installNativeHarnessBrushes()
    return renderer
}

@MainActor
private func commitRadialDab(
    _ renderer: GridRenderer,
    at point: ScreenPoint,
    tokenValue: UInt64 = 1,
    style: StrokeRenderStyle = radialDrawStyle
) async throws {
    let nativeStyle = try nativeRadialStyle(style, renderer: renderer)
    let token = RendererOperationToken(rawValue: tokenValue)
    try renderer.beginStroke(
        token: token,
        sample: radialSample(.began, x: point.x, y: point.y),
        style: nativeStyle
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: radialSample(.ended, x: point.x, y: point.y)
    )
    _ = try await renderer.finishCommitForHarness()
}

@MainActor
private func nativeRadialStyle(
    _ style: StrokeRenderStyle,
    renderer: GridRenderer
) throws -> StrokeRenderStyle {
    guard let brush = renderer.preparedBrush(
        for: style.compositeMode
    ) else {
        throw MetalRendererError.compiledBrushUnavailable(
            style.compositeMode
        )
    }
    let nativeStyle = StrokeRenderStyle(
        color: style.color,
        diameter: style.diameter,
        compositeMode: style.compositeMode,
        eraserStrength: style.eraserStrength,
        program: brush.program,
        renderIdentity: brush.renderIdentity,
        seed: style.seed
    )
    return nativeStyle
}

private func radialSample(
    _ phase: StrokePhase,
    x: Float,
    y: Float
) -> StrokeSample {
    .mouse(
        position: ScreenPoint(x: x, y: y),
        timestamp: 0,
        phase: phase
    )
}

private func radialTextureBytes(_ texture: any MTLTexture) -> [UInt8] {
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
private func radialCanonicalBytes(
    _ renderer: GridRenderer
) async throws -> [UInt8] {
    try await renderer.exportFiniteCanvas(
        transparentBackground: true
    ).bgra8Bytes
}

private func radialPixelIsInk(
    _ bytes: [UInt8],
    width: Int,
    height: Int = 128,
    point: WorldPoint
) -> Bool {
    let centerX = Int(point.x.rounded())
    let centerY = Int(point.y.rounded())
    for y in max(0, centerY - 2)...min(height - 1, centerY + 2) {
        for x in max(0, centerX - 2)...min(width - 1, centerX + 2) {
            let offset = (y * width + x) * 4
            if bytes[offset + 3] > 32,
               bytes[offset] < 160,
               bytes[offset + 1] < 160,
               bytes[offset + 2] < 160
            {
                return true
            }
        }
    }
    return false
}
