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
    ) throws {
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

        try commitRadialDab(renderer, at: ScreenPoint(x: 92, y: 71))
        let display = try renderer.renderOffscreenDisplayForHarness(
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
    func radialGuideChangesBlankFiniteDisplay() throws {
        let configuration = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 8,
            center: WorldPoint(x: 47, y: 73),
            referenceAngleRadians: -.pi / 7
        )
        guard let renderer = try makeRadialRenderer(configuration) else {
            return
        }

        let plain = try renderer.renderOffscreenDisplayForHarness(
            width: 128,
            height: 128,
            showGridLines: false
        )
        let guided = try renderer.renderOffscreenDisplayForHarness(
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
    func boundedWashCrossingRadialPageBoundaryReachesEveryOrbit() throws {
        let size = PixelSize(width: 600, height: 600)
        let radial = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 8,
            center: WorldPoint(x: 300, y: 300)
        )
        guard let renderer = try makeRadialRenderer(
            radial,
            size: size
        ) else {
            return
        }
        let source = ScreenPoint(x: 555, y: 305)
        try commitRadialDab(
            renderer,
            at: source,
            tokenValue: 70,
            style: try finiteWashStyle(diameter: 20)
        )

        let exported = try renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        let orbit = RadialCoverageOracle.orbit(
            of: WorldPoint(x: source.x, y: source.y),
            configuration: radial
        )
        #expect(orbit.count == 16)
        #expect(orbit.allSatisfy {
            radialPixelIsInk(
                exported.bgra8Bytes,
                width: size.width,
                height: size.height,
                point: $0
            )
        })
    }

    @Test
    @MainActor
    func boundedWashOnPlainCanvasDoesNotWrapAtFiniteEdge() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 128, height: 128)
        let renderer = try makeFiniteRenderer(
            device: device,
            configuration: .plain,
            size: size
        )
        try commitRadialDab(
            renderer,
            at: ScreenPoint(x: 2, y: 64),
            tokenValue: 71,
            style: try finiteWashStyle(diameter: 4)
        )

        let exported = try renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        let oppositeAlpha = exported.bgra8Bytes[
            (64 * size.width + 125) * 4 + 3
        ]
        #expect(oppositeAlpha == 0)
    }

    @Test
    @MainActor
    func radialGeometryLocksOnlyAfterSuccessfulCommit() throws {
        let initial = RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 6,
            center: WorldPoint(x: 64, y: 64)
        )
        guard let renderer = try makeRadialRenderer(initial) else {
            return
        }
        #expect(!renderer.documentDomainLocked)
        #expect(!renderer.radialGeometryLocked)

        let failedToken = RendererOperationToken(rawValue: 1)
        try renderer.beginStroke(
            token: failedToken,
            sample: radialSample(.began, x: 90, y: 64),
            style: radialDrawStyle
        )
        try renderer.requestStrokeCommit(
            token: failedToken,
            sample: radialSample(.ended, x: 90, y: 64),
            maximumRetainedBytes: 4_000_000
        )
        _ = try renderer.flushPendingLiveForHarness()
        _ = try renderer.submitCommitForHarness(forceFailure: true)
        #expect(throws: MetalRendererError.self) {
            try renderer.drainCompletedOperationsForHarness()
        }
        #expect(!renderer.documentDomainLocked)
        #expect(!renderer.radialGeometryLocked)

        let revised = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 7,
            center: WorldPoint(x: 61, y: 65),
            referenceAngleRadians: .pi / 9
        )
        try renderer.applyFiniteConfiguration(.radial(revised))
        try commitRadialDab(
            renderer,
            at: ScreenPoint(x: 90, y: 64),
            tokenValue: 2
        )
        #expect(renderer.documentDomainLocked)
        #expect(renderer.radialGeometryLocked)
        #expect(throws: MetalRendererError.radialGeometryLocked) {
            try renderer.applyFiniteConfiguration(.radial(initial))
        }
    }

    @Test
    @MainActor
    func radialEraseAndClearAffectEveryLinkedImageAndKeepLock() throws {
        let radial = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 6,
            center: WorldPoint(x: 64, y: 64),
            referenceAngleRadians: .pi / 17
        )
        guard let renderer = try makeRadialRenderer(radial) else { return }
        let source = ScreenPoint(x: 91, y: 70)
        try commitRadialDab(
            renderer,
            at: source,
            tokenValue: 30
        )
        let orbit = RadialCoverageOracle.orbit(
            of: WorldPoint(x: source.x, y: source.y),
            configuration: radial
        )
        let drawn = try renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        #expect(orbit.allSatisfy {
            radialPixelIsInk(
                drawn.bgra8Bytes,
                width: 128,
                point: $0
            )
        })

        let eraseStyle = StrokeRenderStyle(
            color: .black,
            diameter: 20,
            compositeMode: .erase,
            eraserStrength: 1
        )
        try commitRadialDab(
            renderer,
            at: source,
            tokenValue: 31,
            style: eraseStyle
        )
        let erased = try renderer.exportFiniteCanvas(
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

        try commitRadialDab(
            renderer,
            at: source,
            tokenValue: 32
        )
        try renderer.requestClear(
            token: RendererOperationToken(rawValue: 33),
            maximumRetainedBytes: 4_000_000
        )
        try renderer.finishRasterOperationForHarness()
        let cleared = try renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        #expect(
            stride(from: 3, to: cleared.bgra8Bytes.count, by: 4)
                .allSatisfy { cleared.bgra8Bytes[$0] == 0 }
        )
        #expect(renderer.documentDomainLocked)
        #expect(renderer.radialGeometryLocked)
    }

    @Test
    @MainActor
    func radialResizeCropsByOrbitWithoutScalingOrResurrection() throws {
        let radial = RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 4,
            center: WorldPoint(x: 55, y: 55)
        )
        guard let renderer = try makeRadialRenderer(radial) else { return }
        try commitRadialDab(
            renderer,
            at: ScreenPoint(x: 75, y: 55),
            tokenValue: 1
        )
        try commitRadialDab(
            renderer,
            at: ScreenPoint(x: 127, y: 55),
            tokenValue: 2
        )
        let original = try renderer.exportFiniteCanvas(
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
        try renderer.requestResize(
            token: RendererOperationToken(rawValue: 3),
            to: PixelSize(width: 64, height: 64),
            maximumRetainedBytes: 4_000_000
        )
        try renderer.finishRasterOperationForHarness()
        let receipt = try #require(resizeReceipt)
        #expect(receipt.before.documentPixelSize == PixelSize(width: 128, height: 128))
        #expect(receipt.after.documentPixelSize == PixelSize(width: 64, height: 64))
        #expect(renderer.pixelSize == PixelSize(width: 64, height: 64))
        #expect(renderer.radialGeometryLocked)

        let cropped = try renderer.exportFiniteCanvas(
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

        try renderer.requestResize(
            token: RendererOperationToken(rawValue: 4),
            to: PixelSize(width: 128, height: 128),
            maximumRetainedBytes: 4_000_000
        )
        try renderer.finishRasterOperationForHarness()
        let expanded = try renderer.exportFiniteCanvas(
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
    func radialResizeUndoRedoRestoresExactAtlasAndDocumentSize() throws {
        let radial = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 5,
            center: WorldPoint(x: 55, y: 55),
            referenceAngleRadians: .pi / 13
        )
        guard let renderer = try makeRadialRenderer(radial) else { return }
        try commitRadialDab(
            renderer,
            at: ScreenPoint(x: 76, y: 59),
            tokenValue: 10
        )
        let original = try radialCanonicalBytes(renderer)
        var resizeReceipt: RasterMutationReceipt?
        renderer.onOperationCompleted = { completion in
            if case let .rasterSuccess(receipt) = completion {
                resizeReceipt = receipt
            }
        }

        try renderer.requestResize(
            token: RendererOperationToken(rawValue: 11),
            to: PixelSize(width: 64, height: 64),
            maximumRetainedBytes: 4_000_000
        )
        try renderer.finishRasterOperationForHarness()
        let receipt = try #require(resizeReceipt)
        let resized = try radialCanonicalBytes(renderer)
        #expect(renderer.pixelSize == PixelSize(width: 64, height: 64))
        #expect(renderer.radialGeometryLocked)

        try renderer.requestResizeRestore(
            token: RendererOperationToken(rawValue: 12),
            revision: receipt.before
        )
        try renderer.finishRasterOperationForHarness()
        #expect(renderer.pixelSize == PixelSize(width: 128, height: 128))
        #expect(try radialCanonicalBytes(renderer) == original)
        #expect(renderer.radialGeometryLocked)

        try renderer.requestResizeRestore(
            token: RendererOperationToken(rawValue: 13),
            revision: receipt.after
        )
        try renderer.finishRasterOperationForHarness()
        #expect(renderer.pixelSize == PixelSize(width: 64, height: 64))
        #expect(try radialCanonicalBytes(renderer) == resized)
        #expect(renderer.radialGeometryLocked)

        renderer.releaseRasterRevisions([
            receipt.before.id,
            receipt.after.id,
        ])
    }

    @Test
    @MainActor
    func failedSubmittedRadialResizePreservesAllInstalledState() throws {
        let radial = RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 7,
            center: WorldPoint(x: 55, y: 55)
        )
        guard let renderer = try makeRadialRenderer(radial) else { return }
        try commitRadialDab(
            renderer,
            at: ScreenPoint(x: 83, y: 57),
            tokenValue: 20
        )
        let configuration = renderer.documentConfiguration
        let canonical = try radialCanonicalBytes(renderer)
        let snapshot = renderer.harnessTilingMutationSnapshot
        var completions: [RendererOperationCompletion] = []
        renderer.onOperationCompleted = { completions.append($0) }

        try renderer.requestResizeForHarness(
            token: RendererOperationToken(rawValue: 21),
            to: PixelSize(width: 64, height: 64),
            maximumRetainedBytes: 4_000_000,
            forceResourceAllocationFailure: false,
            forceCommandFailure: true
        )
        #expect(throws: MetalRendererError.commandFailed(
            "injected harness command-buffer failure"
        )) {
            try renderer.finishRasterOperationForHarness()
        }

        #expect(renderer.documentConfiguration == configuration)
        #expect(renderer.pixelSize == PixelSize(width: 128, height: 128))
        #expect(renderer.radialGeometryLocked)
        #expect(renderer.documentDomainLocked)
        #expect(renderer.harnessTilingMutationSnapshot == snapshot)
        #expect(try radialCanonicalBytes(renderer) == canonical)
        #expect(renderer.isIdle)
        #expect(completions.count == 1)
    }
}

@Suite("Finite full-canvas export")
struct FiniteCanvasExportTests {
    @Test
    @MainActor
    func plainTransparentExportPreservesExactCanvasPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try makeFiniteRenderer(
            device: device,
            configuration: .plain,
            size: PixelSize(width: 64, height: 64)
        )
        let fixture = (0..<(64 * 64)).flatMap { index -> [UInt8] in
            let x = index % 64
            let y = index / 64
            return [
                UInt8(truncatingIfNeeded: x * 3),
                UInt8(truncatingIfNeeded: y * 5),
                UInt8(truncatingIfNeeded: x + y),
                UInt8(truncatingIfNeeded: x * 7 + y * 11),
            ]
        }
        try renderer.replaceCanonicalPixelsForHarness(fixture)

        let exported = try renderer.exportFiniteCanvas(
            transparentBackground: true
        )

        #expect(exported.pixelSize == PixelSize(width: 64, height: 64))
        #expect(exported.bytesPerRow == 256)
        #expect(exported.bgra8Bytes == fixture)
        #expect(exported.hasTransparentBackground)
    }

    @Test
    @MainActor
    func radialExportUsesDocumentPixelsAndIgnoresViewportAndGuides() throws {
        let radial = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 5,
            center: WorldPoint(x: 64, y: 64),
            referenceAngleRadians: .pi / 13
        )
        guard let renderer = try makeRadialRenderer(radial) else { return }
        try commitRadialDab(renderer, at: ScreenPoint(x: 94, y: 70))
        let beforeConfiguration = renderer.documentConfiguration
        let beforeLock = renderer.radialGeometryLocked
        let beforeCanonical = try radialCanonicalBytes(renderer)

        let baseline = try renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        renderer.pan(byScreenDelta: SIMD2(37, -19))
        renderer.zoom(
            by: 2.25,
            anchor: ScreenPoint(x: 17, y: 103)
        )
        renderer.setInteractiveGridVisibility(true)
        let transformed = try renderer.exportFiniteCanvas(
            transparentBackground: true
        )

        #expect(transformed == baseline)
        #expect(renderer.documentConfiguration == beforeConfiguration)
        #expect(renderer.radialGeometryLocked == beforeLock)
        #expect(try radialCanonicalBytes(renderer) == beforeCanonical)
        #expect(baseline.bgra8Bytes.contains { $0 != 0 })
        #expect(
            stride(from: 3, to: baseline.bgra8Bytes.count, by: 4)
                .contains { baseline.bgra8Bytes[$0] == 0 }
        )
    }

    @Test(arguments: [
        FiniteCanvasExportInjectedFailure.textureAllocation,
        .commandBuffer,
        .renderEncoder,
    ])
    @MainActor
    func exportFailureDoesNotMutateFiniteDocument(
        failure: FiniteCanvasExportInjectedFailure
    ) throws {
        let radial = RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 7,
            center: WorldPoint(x: 59, y: 67)
        )
        guard let renderer = try makeRadialRenderer(radial) else { return }
        try commitRadialDab(renderer, at: ScreenPoint(x: 91, y: 68))
        let configuration = renderer.documentConfiguration
        let lock = renderer.radialGeometryLocked
        let viewport = renderer.viewport
        let canonical = try radialCanonicalBytes(renderer)

        #expect(throws: MetalRendererError.self) {
            try renderer.exportFiniteCanvas(
                transparentBackground: false,
                injecting: failure
            )
        }
        #expect(renderer.documentConfiguration == configuration)
        #expect(renderer.radialGeometryLocked == lock)
        #expect(renderer.viewport == viewport)
        #expect(try radialCanonicalBytes(renderer) == canonical)
    }
}

private let radialDrawStyle = StrokeRenderStyle(
    color: .black,
    diameter: 12,
    compositeMode: .draw,
    eraserStrength: 1
)

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
    return try GridRenderer(
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
}

private func finiteWashStyle(
    diameter: Float
) throws -> StrokeRenderStyle {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.finite.wash.\(diameter)"),
        shape: .hardRound,
        grain: .opaque,
        material: BrushMaterial(
            family: .boundedWash,
            strength: 1,
            wetness: 1,
            bleedRadius: 8,
            softenPasses: 2,
            accumulationLimit: 1
        ),
        baseSpacingFraction: 0.2,
        maximumSpacingFraction: 0.2,
        baseFlow: 1,
        strokeOpacity: 1,
        replayMode: .boundedWholeStroke,
        replayLimits: BrushRecipePolicy.wholeStrokeLimits
    )
    return StrokeRenderStyle(
        color: .black,
        diameter: diameter,
        compositeMode: .draw,
        eraserStrength: 1,
        recipe: recipe,
        seed: 70
    )
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
    return try GridRenderer(
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
}

@MainActor
private func commitRadialDab(
    _ renderer: GridRenderer,
    at point: ScreenPoint,
    tokenValue: UInt64 = 1,
    style: StrokeRenderStyle = radialDrawStyle
) throws {
    let token = RendererOperationToken(rawValue: tokenValue)
    try renderer.beginStroke(
        token: token,
        sample: radialSample(.began, x: point.x, y: point.y),
        style: style
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: radialSample(.ended, x: point.x, y: point.y),
        maximumRetainedBytes: 4_000_000
    )
    _ = try renderer.flushPendingLiveForHarness()
    _ = try renderer.submitCommitForHarness()
    try renderer.drainCompletedOperationsForHarness()
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
) throws -> [UInt8] {
    radialTextureBytes(try renderer.copyCanonicalForHarness())
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
