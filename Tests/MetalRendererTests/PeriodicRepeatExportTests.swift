import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Periodic repeat export")
struct PeriodicRepeatExportTests {
    @Test
    @MainActor
    func validatesSquarePresetAndDensityBeforeChangingState() throws {
        guard let grid = try makeExportRenderer(preset: .grid) else {
            return
        }
        let gridSnapshot = grid.harnessTilingMutationSnapshot
        let gridViewport = grid.viewport
        let gridConfiguration = grid.periodicConfiguration

        #expect(throws: PeriodicRepeatExportError.unsupportedPreset(.grid)) {
            try grid.exportPeriodicRepeat(density: 64)
        }
        #expect(grid.harnessTilingMutationSnapshot == gridSnapshot)
        #expect(grid.viewport == gridViewport)
        #expect(grid.periodicConfiguration == gridConfiguration)

        guard let square = try makeExportRenderer(
            preset: .squareRotation
        ) else {
            return
        }
        let initialBytes = try canonicalBytes(square)
        let initialSnapshot = square.harnessTilingMutationSnapshot
        let initialViewport = square.viewport
        let initialConfiguration = square.periodicConfiguration

        #expect(throws: PeriodicRepeatExportError.invalidDensity(63)) {
            try square.exportPeriodicRepeat(density: 63)
        }
        #expect(throws: PeriodicRepeatExportError.invalidDensity(4_097)) {
            try square.exportPeriodicRepeat(density: 4_097)
        }
        #expect(square.harnessTilingMutationSnapshot == initialSnapshot)
        #expect(square.viewport == initialViewport)
        #expect(square.periodicConfiguration == initialConfiguration)
        #expect(try canonicalBytes(square) == initialBytes)
    }

    @Test
    @MainActor
    func allocationAndEncodingFailuresLeaveAllRendererStateUntouched()
        throws
    {
        guard let renderer = try makeExportRenderer(
            preset: .squareKaleidoscope
        ) else {
            return
        }
        let source = makeCanonicalFixture(side: 64)
        try renderer.replaceCanonicalPixelsForHarness(source)
        let snapshot = renderer.harnessTilingMutationSnapshot
        let viewport = renderer.viewport
        let configuration = renderer.periodicConfiguration
        let cases: [
            (
                PeriodicRepeatExportInjectedFailure,
                MetalRendererError
            )
        ] = [
            (.textureAllocation, .textureAllocationFailed),
            (.commandBuffer, .commandBufferUnavailable),
            (.renderEncoder, .renderEncoderUnavailable),
        ]

        for (failure, expectedError) in cases {
            #expect(throws: expectedError) {
                try renderer.exportPeriodicRepeat(
                    density: 96,
                    injecting: failure
                )
            }
            #expect(renderer.harnessTilingMutationSnapshot == snapshot)
            #expect(renderer.viewport == viewport)
            #expect(renderer.periodicConfiguration == configuration)
            #expect(try canonicalBytes(renderer) == source)
        }
    }

    @Test(arguments: [
        SymmetryPresetID.squareRotation,
        .squareKaleidoscope,
    ])
    @MainActor
    func rendersOneSquareRepeatAtRequestedDensity(
        preset: SymmetryPresetID
    ) throws {
        guard let renderer = try makeExportRenderer(preset: preset) else {
            return
        }
        let source = makeCanonicalFixture(side: 64)
        try renderer.replaceCanonicalPixelsForHarness(source)

        let exported = try renderer.exportPeriodicRepeat(density: 64)

        #expect(exported.pixelSize == PixelSize(width: 64, height: 64))
        #expect(exported.bytesPerRow == 64 * 4)
        #expect(exported.bgra8Bytes.count == 64 * 64 * 4)
        #expect(exported.bgra8Bytes == source)
    }

    @Test(arguments: [
        SymmetryPresetID.squareRotation,
        .squareKaleidoscope,
    ])
    @MainActor
    func rectangularRasterExportMatchesIndependentWrappedBilinearReference(
        preset: SymmetryPresetID
    ) throws {
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
        try renderer.replaceCanonicalPixelsForHarness(source)

        let density = 137
        let exported = try renderer.exportPeriodicRepeat(density: density)
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
        throws
    {
        guard let renderer = try makeExportRenderer(
            preset: .squareKaleidoscope
        ) else {
            return
        }
        let source = makeCanonicalFixture(side: 64)
        try renderer.replaceCanonicalPixelsForHarness(source)
        let exported = try renderer.exportPeriodicRepeat(density: 96)
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
    func successfulExportLeavesBytesDescriptorAndViewportUnchanged() throws {
        guard let renderer = try makeExportRenderer(
            preset: .squareRotation
        ) else {
            return
        }
        try renderer.replaceCanonicalPixelsForHarness(
            makeCanonicalFixture(side: 64)
        )
        renderer.pan(byScreenDelta: SIMD2(11, -7))
        renderer.zoom(
            by: 1.75,
            anchor: ScreenPoint(x: 13, y: 41)
        )
        let bytesBefore = try canonicalBytes(renderer)
        let snapshotBefore = renderer.harnessTilingMutationSnapshot
        let viewportBefore = renderer.viewport
        let configurationBefore = renderer.periodicConfiguration

        _ = try renderer.exportPeriodicRepeat(density: 128)

        #expect(try canonicalBytes(renderer) == bytesBefore)
        #expect(renderer.harnessTilingMutationSnapshot == snapshotBefore)
        #expect(renderer.viewport == viewportBefore)
        #expect(renderer.periodicConfiguration == configurationBefore)
    }
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
    precondition(repeatColumns > 0 && repeatRows > 0)
    let outputWidth = density * repeatColumns
    let outputHeight = density * repeatRows
    var result = [UInt8](
        repeating: 0,
        count: outputWidth * outputHeight * 4
    )
    for y in 0..<outputHeight {
        for x in 0..<outputWidth {
            let canonicalX =
                (Double(x) + 0.5) / Double(density)
                * Double(sourceSize.width)
            let canonicalY =
                (Double(y) + 0.5) / Double(density)
                * Double(sourceSize.height)
            let sampleX = canonicalX - 0.5
            let sampleY = canonicalY - 0.5
            let lowerX = Int(floor(sampleX))
            let lowerY = Int(floor(sampleY))
            let blendX = sampleX - Double(lowerX)
            let blendY = sampleY - Double(lowerY)

            for channel in 0..<4 {
                let value00 = Double(sourceChannel(
                    source,
                    size: sourceSize,
                    x: lowerX,
                    y: lowerY,
                    channel: channel
                ))
                let value10 = Double(sourceChannel(
                    source,
                    size: sourceSize,
                    x: lowerX + 1,
                    y: lowerY,
                    channel: channel
                ))
                let value01 = Double(sourceChannel(
                    source,
                    size: sourceSize,
                    x: lowerX,
                    y: lowerY + 1,
                    channel: channel
                ))
                let value11 = Double(sourceChannel(
                    source,
                    size: sourceSize,
                    x: lowerX + 1,
                    y: lowerY + 1,
                    channel: channel
                ))
                let top = value00 + (value10 - value00) * blendX
                let bottom = value01 + (value11 - value01) * blendX
                let value = top + (bottom - top) * blendY
                result[(y * outputWidth + x) * 4 + channel] = UInt8(
                    clamping: Int(value.rounded())
                )
            }
        }
    }
    return result
}

private func sourceChannel(
    _ source: [UInt8],
    size: PixelSize,
    x: Int,
    y: Int,
    channel: Int
) -> UInt8 {
    let wrappedX = (x % size.width + size.width) % size.width
    let wrappedY = (y % size.height + size.height) % size.height
    return source[(wrappedY * size.width + wrappedX) * 4 + channel]
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
private func canonicalBytes(_ renderer: GridRenderer) throws -> [UInt8] {
    let texture = try renderer.copyCanonicalForHarness()
    let bytesPerRow = texture.width * 4
    var bytes = [UInt8](
        repeating: 0,
        count: bytesPerRow * texture.height
    )
    texture.getBytes(
        &bytes,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    return bytes
}

private func tileThreeByThree(
    _ export: PeriodicRepeatExport
) -> [UInt8] {
    let side = export.pixelSize.width
    let repeatedSide = side * 3
    var result = [UInt8](
        repeating: 0,
        count: repeatedSide * repeatedSide * 4
    )
    for tileY in 0..<3 {
        for tileX in 0..<3 {
            for row in 0..<side {
                let sourceStart = row * export.bytesPerRow
                let destinationStart =
                    ((tileY * side + row) * repeatedSide + tileX * side) * 4
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
