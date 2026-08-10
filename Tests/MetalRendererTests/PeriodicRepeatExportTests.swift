import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Periodic repeat export")
struct PeriodicRepeatExportTests {
    @Test
    @MainActor
    func validatesSquarePresetAndDensityBeforeChangingState() async throws {
        guard let grid = try makeExportRenderer(preset: .grid) else {
            return
        }
        let gridBytes = try await canonicalBytes(grid)
        let gridViewport = grid.viewport
        let gridConfiguration = grid.periodicConfiguration

        await #expect(
            throws: PeriodicRepeatExportError.unsupportedPreset(.grid)
        ) {
            try await grid.exportPeriodicRepeat(density: 64)
        }
        #expect(try await canonicalBytes(grid) == gridBytes)
        #expect(grid.viewport == gridViewport)
        #expect(grid.periodicConfiguration == gridConfiguration)

        guard let square = try makeExportRenderer(
            preset: .squareRotation
        ) else {
            return
        }
        let initialBytes = try await canonicalBytes(square)
        let initialViewport = square.viewport
        let initialConfiguration = square.periodicConfiguration

        await #expect(throws: PeriodicRepeatExportError.invalidDensity(63)) {
            try await square.exportPeriodicRepeat(density: 63)
        }
        await #expect(
            throws: PeriodicRepeatExportError.invalidDensity(4_097)
        ) {
            try await square.exportPeriodicRepeat(density: 4_097)
        }
        #expect(square.viewport == initialViewport)
        #expect(square.periodicConfiguration == initialConfiguration)
        #expect(try await canonicalBytes(square) == initialBytes)
    }

    @Test(arguments: [
        SymmetryPresetID.squareRotation,
        .squareKaleidoscope,
    ])
    @MainActor
    func rendersOneSquareRepeatAtRequestedDensity(
        preset: SymmetryPresetID
    ) async throws {
        guard let renderer = try makeExportRenderer(preset: preset) else {
            return
        }
        let source = makeCanonicalFixture(side: 64)
        try await installCommittedRaster(source, into: renderer)

        let exported = try await renderer.exportPeriodicRepeat(density: 64)

        #expect(exported.pixelSize == PixelSize(width: 64, height: 64))
        #expect(exported.bytesPerRow == 64 * 4)
        #expect(exported.bgra8Bytes.count == 64 * 64 * 4)
        #expect(exported.bgra8Bytes == source)
    }

    @Test(arguments: [
        SymmetryPresetID.hexagons,
        .rotation3,
        .rotation6,
        .kaleidoscope60,
        .kaleidoscope30,
    ])
    @MainActor
    func rendersMetricTriangularSupercellAtRequestedHorizontalDensity(
        preset: SymmetryPresetID
    ) async throws {
        guard let renderer = try makeExportRenderer(preset: preset) else {
            return
        }
        let source = makeCanonicalFixture(side: 64)
        try await installCommittedRaster(source, into: renderer)

        let exported = try await renderer.exportPeriodicRepeat(density: 64)
        let expectedSize = PixelSize(width: 64, height: 111)
        let expected = wrappedBilinearReference(
            source,
            sourceSize: PixelSize(width: 64, height: 64),
            outputSize: expectedSize
        )

        #expect(exported.pixelSize == expectedSize)
        #expect(exported.bytesPerRow == expectedSize.width * 4)
        #expect(
            exported.bgra8Bytes.count
                == expectedSize.width * expectedSize.height * 4
        )
        #expect(maximumChannelDelta(exported.bgra8Bytes, expected) <= 1)
    }

    @Test
    @MainActor
    func maximumTriangularDensityFitsTheRectangularExportLimit()
        async throws
    {
        guard let renderer = try makeExportRenderer(
            preset: .kaleidoscope30
        ) else {
            return
        }
        let bytes = try await canonicalBytes(renderer)
        let configuration = renderer.periodicConfiguration

        let exported = try await renderer.exportPeriodicRepeat(density: 4_096)
        #expect(exported.pixelSize == PixelSize(width: 4_096, height: 7_094))
        #expect(exported.bgra8Bytes.count == 4_096 * 7_094 * 4)
        #expect(try await canonicalBytes(renderer) == bytes)
        #expect(renderer.periodicConfiguration == configuration)
    }

    @Test(arguments: [
        SymmetryPresetID.squareRotation,
        .squareKaleidoscope,
    ])
    @MainActor
    func rectangularRasterExportMatchesIndependentWrappedBilinearReference(
        preset: SymmetryPresetID
    ) async throws {
        let raster = PixelSize(width: 96, height: 64)
        guard let renderer = try makeExportRenderer(
            preset: preset,
            pixelSize: raster,
            repeatSide: 173.5,
            orientationRadians: .pi / 7
        ) else {
            return
        }
        let source = makeCanonicalFixture(
            width: raster.width,
            height: raster.height
        )
        try await installCommittedRaster(source, into: renderer)

        let density = 137
        let exported = try await renderer.exportPeriodicRepeat(density: density)
        let expected = wrappedBilinearReference(
            source,
            sourceSize: raster,
            density: density
        )

        #expect(
            maximumChannelDelta(exported.bgra8Bytes, expected) <= 1
        )
        #expect(
            renderer.periodicConfiguration.repeatSize
                == PatternSize(width: 173.5, height: 173.5)
        )
        #expect(
            renderer.periodicConfiguration.orientationRadians == .pi / 7
        )
    }

    @Test
    @MainActor
    func packagedThreeByThreeRepeatMatchesIndependentTranslatedSampling()
        async throws
    {
        guard let renderer = try makeExportRenderer(
            preset: .squareKaleidoscope
        ) else {
            return
        }
        let source = makeCanonicalFixture(side: 64)
        try await installCommittedRaster(source, into: renderer)
        let exported = try await renderer.exportPeriodicRepeat(density: 96)
        let repeated = tileThreeByThree(exported)
        let expected = wrappedBilinearReference(
            source,
            sourceSize: PixelSize(width: 64, height: 64),
            density: 96,
            repeatColumns: 3,
            repeatRows: 3
        )

        #expect(maximumChannelDelta(repeated, expected) <= 1)
    }

    @Test
    @MainActor
    func triangularThreeByThreeRepeatMatchesIndependentTranslatedSampling()
        async throws
    {
        guard let renderer = try makeExportRenderer(
            preset: .kaleidoscope30,
            repeatSide: 173.5,
            orientationRadians: .pi / 7
        ) else {
            return
        }
        let source = makeCanonicalFixture(side: 64)
        try await installCommittedRaster(source, into: renderer)
        let exported = try await renderer.exportPeriodicRepeat(density: 96)
        let repeated = tileThreeByThree(exported)
        let expected = wrappedBilinearReference(
            source,
            sourceSize: PixelSize(width: 64, height: 64),
            outputSize: PixelSize(
                width: exported.pixelSize.width * 3,
                height: exported.pixelSize.height * 3
            ),
            repeatSize: exported.pixelSize
        )

        #expect(exported.pixelSize == PixelSize(width: 96, height: 166))
        #expect(maximumChannelDelta(repeated, expected) <= 1)
    }

    @Test
    @MainActor
    func successfulExportLeavesBytesDescriptorAndViewportUnchanged()
        async throws
    {
        guard let renderer = try makeExportRenderer(
            preset: .squareRotation
        ) else {
            return
        }
        try await installCommittedRaster(
            makeCanonicalFixture(side: 64),
            into: renderer
        )
        renderer.pan(byScreenDelta: SIMD2(11, -7))
        renderer.zoom(
            by: 1.75,
            anchor: ScreenPoint(x: 13, y: 41)
        )
        let bytesBefore = try await canonicalBytes(renderer)
        let viewportBefore = renderer.viewport
        let configurationBefore = renderer.periodicConfiguration

        _ = try await renderer.exportPeriodicRepeat(density: 128)

        #expect(try await canonicalBytes(renderer) == bytesBefore)
        #expect(renderer.viewport == viewportBefore)
        #expect(renderer.periodicConfiguration == configurationBefore)
    }

    @Test(arguments: SymmetryPresetID.periodicCases)
    @MainActor
    func bakedRepeatCompletesEveryPeriodicPreset(
        preset: SymmetryPresetID
    ) async throws {
        guard let renderer = try makeExportRenderer(preset: preset) else {
            return
        }
        let source = makeCanonicalFixture(side: 64)
        try await installCommittedRaster(source, into: renderer)
        let viewport = renderer.viewport

        let exported = try await renderer.exportBakedPeriodicRepeat()

        let expectedSize: PixelSize
        switch preset {
        case .halfDrop, .mirrorX:
            expectedSize = PixelSize(width: 128, height: 64)
        case .brick, .mirrorY:
            expectedSize = PixelSize(width: 64, height: 128)
        case .mirrorXY:
            expectedSize = PixelSize(width: 128, height: 128)
        case .hexagons, .rotation3, .rotation6, .kaleidoscope60,
             .kaleidoscope30:
            expectedSize = PixelSize(width: 64, height: 111)
        case .grid, .rotational, .squareRotation,
             .squareKaleidoscope:
            expectedSize = PixelSize(width: 64, height: 64)
        case .plainCanvas, .radialMirror, .radialRotation,
             .radialMandala:
            Issue.record("Finite preset entered periodic matrix")
            return
        }
        #expect(exported.pixelSize == expectedSize, "\(preset)")
        #expect(
            exported.bgra8Bytes.count
                == expectedSize.width * expectedSize.height * 4,
            "\(preset)"
        )
        #expect(renderer.viewport == viewport)
        #expect(try await canonicalBytes(renderer) == source)
        if preset == .grid || preset == .rotational
            || preset.isSquare
        {
            #expect(exported.bgra8Bytes == source, "\(preset)")
        }
    }

    @Test
    @MainActor
    func bakedRepeatEncodesPhaseAndReflectionPeriods()
        async throws
    {
        let source = makeCanonicalFixture(side: 64)

        guard let halfDrop = try makeExportRenderer(
            preset: .halfDrop
        ) else {
            return
        }
        try await installCommittedRaster(source, into: halfDrop)
        let halfDropExport = try await halfDrop.exportBakedPeriodicRepeat()
        #expect(
            exportPixel(halfDropExport, x: 64, y: 0)
                == sourcePixel(source, width: 64, x: 0, y: 32)
        )

        guard let mirrorX = try makeExportRenderer(
            preset: .mirrorX
        ) else {
            return
        }
        try await installCommittedRaster(source, into: mirrorX)
        let mirrorExport = try await mirrorX.exportBakedPeriodicRepeat()
        #expect(
            exportPixel(mirrorExport, x: 64, y: 0)
                == sourcePixel(source, width: 64, x: 63, y: 0)
        )
    }

}

private func exportPixel(
    _ export: PeriodicRepeatExport,
    x: Int,
    y: Int
) -> [UInt8] {
    let offset = y * export.bytesPerRow + x * 4
    return Array(export.bgra8Bytes[offset..<(offset + 4)])
}

private func sourcePixel(
    _ bytes: [UInt8],
    width: Int,
    x: Int,
    y: Int
) -> [UInt8] {
    let offset = (y * width + x) * 4
    return Array(bytes[offset..<(offset + 4)])
}

@MainActor
private func makeExportRenderer(
    preset: SymmetryPresetID,
    pixelSize: PixelSize = PixelSize(width: 64, height: 64),
    repeatSide: Float? = nil,
    orientationRadians: Float = 0
) throws -> GridRenderer? {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return nil
    }
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
    let periodicConfiguration: PeriodicSymmetryConfiguration
    if let repeatSide {
        periodicConfiguration = PeriodicSymmetryConfiguration(
            presetID: preset,
            repeatSize: PatternSize(
                width: repeatSide,
                height: repeatSide
            ),
            orientationRadians: orientationRadians
        )
    } else {
        periodicConfiguration = .defaultConfiguration(
            presetID: preset,
            canonicalRasterSize: pixelSize
        )
    }
    return try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(
            width: Float(pixelSize.width),
            height: Float(pixelSize.height)
        ),
        configuration: TilingCanvasConfiguration(
            pixelSize: pixelSize,
            periodicConfiguration: periodicConfiguration
        )
    )
}

private func makeCanonicalFixture(side: Int) -> [UInt8] {
    makeCanonicalFixture(width: side, height: side)
}

private func makeCanonicalFixture(width: Int, height: Int) -> [UInt8] {
    (0..<(width * height)).flatMap { index -> [UInt8] in
        let x = index % width
        let y = index / width
        return [
            UInt8(truncatingIfNeeded: x &* 3 &+ y &* 5),
            UInt8(truncatingIfNeeded: x &* 7 &+ y &* 11),
            UInt8(truncatingIfNeeded: x &* 13 &+ y &* 17),
            255,
        ]
    }
}

private func wrappedBilinearReference(
    _ source: [UInt8],
    sourceSize: PixelSize,
    density: Int,
    repeatColumns: Int = 1,
    repeatRows: Int = 1
) -> [UInt8] {
    wrappedBilinearReference(
        source,
        sourceSize: sourceSize,
        outputSize: PixelSize(
            width: density * repeatColumns,
            height: density * repeatRows
        ),
        repeatSize: PixelSize(width: density, height: density)
    )
}

private func wrappedBilinearReference(
    _ source: [UInt8],
    sourceSize: PixelSize,
    outputSize: PixelSize,
    repeatSize: PixelSize? = nil
) -> [UInt8] {
    let period = repeatSize ?? outputSize
    let outputWidth = outputSize.width
    let outputHeight = outputSize.height
    var result = [UInt8](
        repeating: 0,
        count: outputWidth * outputHeight * 4
    )
    for y in 0..<outputHeight {
        for x in 0..<outputWidth {
            let canonicalX =
                (Float(x) + 0.5) / Float(period.width)
                * Float(sourceSize.width)
            let canonicalY =
                (Float(y) + 0.5) / Float(period.height)
                * Float(sourceSize.height)
            let sampleX = canonicalX - 0.5
            let sampleY = canonicalY - 0.5
            let lowerX = Int(floor(sampleX))
            let lowerY = Int(floor(sampleY))
            let blendX = sampleX - Float(lowerX)
            let blendY = sampleY - Float(lowerY)
            let value00 = sourceLinearPixel(
                source, size: sourceSize, x: lowerX, y: lowerY
            )
            let value10 = sourceLinearPixel(
                source, size: sourceSize, x: lowerX + 1, y: lowerY
            )
            let value01 = sourceLinearPixel(
                source, size: sourceSize, x: lowerX, y: lowerY + 1
            )
            let value11 = sourceLinearPixel(
                source, size: sourceSize, x: lowerX + 1, y: lowerY + 1
            )
            let top = value00 + (value10 - value00) * blendX
            let bottom = value01 + (value11 - value01) * blendX
            let value = top + (bottom - top) * blendY
            guard let color = LinearPremultipliedColor(
                red: value.x,
                green: value.y,
                blue: value.z,
                alpha: value.w
            ) else {
                preconditionFailure("bilinear oracle left premultiplied space")
            }
            let encoded = DocumentColorPipeline
                .exportEncodedPremultipliedBGRA8(color)
            let offset = (y * outputWidth + x) * 4
            result[offset] = encoded.blue
            result[offset + 1] = encoded.green
            result[offset + 2] = encoded.red
            result[offset + 3] = encoded.alpha
        }
    }
    return result
}

private func sourceLinearPixel(
    _ source: [UInt8],
    size: PixelSize,
    x: Int,
    y: Int
) -> SIMD4<Float> {
    let wrappedX = (x % size.width + size.width) % size.width
    let wrappedY = (y % size.height + size.height) % size.height
    let offset = (wrappedY * size.width + wrappedX) * 4
    let linear = DocumentColorPipeline.importEncodedPremultipliedBGRA8(
        EncodedPremultipliedBGRA8(
            blue: source[offset],
            green: source[offset + 1],
            red: source[offset + 2],
            alpha: source[offset + 3]
        )
    ).simd
    return SIMD4(
        Float(Float16(linear.x)),
        Float(Float16(linear.y)),
        Float(Float16(linear.z)),
        Float(Float16(linear.w))
    )
}

private func maximumChannelDelta(
    _ lhs: [UInt8],
    _ rhs: [UInt8]
) -> Int {
    precondition(lhs.count == rhs.count)
    return zip(lhs, rhs).map {
        abs(Int($0.0) - Int($0.1))
    }.max() ?? 0
}

@MainActor
private func installCommittedRaster(
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
private func canonicalBytes(_ renderer: GridRenderer) async throws -> [UInt8] {
    let snapshot = try await renderer.captureCommittedDocument()
    guard case let .singleRaster(bytes) = snapshot.storage else {
        Issue.record("Expected one current periodic committed raster")
        return []
    }
    return bytes
}

private func tileThreeByThree(
    _ export: PeriodicRepeatExport
) -> [UInt8] {
    let width = export.pixelSize.width
    let height = export.pixelSize.height
    let repeatedWidth = width * 3
    let repeatedHeight = height * 3
    var result = [UInt8](
        repeating: 0,
        count: repeatedWidth * repeatedHeight * 4
    )
    for tileY in 0..<3 {
        for tileX in 0..<3 {
            for row in 0..<height {
                let sourceStart = row * export.bytesPerRow
                let destinationStart =
                    (
                        (tileY * height + row) * repeatedWidth
                            + tileX * width
                    ) * 4
                result.replaceSubrange(
                    destinationStart..<(destinationStart + export.bytesPerRow),
                    with: export.bgra8Bytes[
                        sourceStart..<(sourceStart + export.bytesPerRow)
                    ]
                )
            }
        }
    }
    return result
}
