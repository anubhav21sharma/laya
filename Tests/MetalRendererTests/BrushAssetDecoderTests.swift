import BrushFormat
import Foundation
import ImageIO
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("BrushAssetDecoder")
struct BrushAssetDecoderTests {
    @Test
    func exactFixtureBuildsDeterministicR8MipPyramid() throws {
        let data = try Fixture.exact4x4.data()
        let decoded = try decode(data, width: 4, height: 4, ceiling: 4)

        #expect(decoded.resourceID == "shape.main")
        #expect(decoded.kind == .shape)
        #expect(decoded.sourceWidth == 4)
        #expect(decoded.sourceHeight == 4)
        #expect(decoded.workingWidth == 4)
        #expect(decoded.workingHeight == 4)
        #expect(decoded.mipLevels.map(\.count) == [16, 4, 1])
        #expect(decoded.mipLevels[0] == Data([
            255, 0, 0, 0,
            0, 255, 0, 0,
            0, 0, 255, 0,
            0, 0, 0, 255,
        ]))
        #expect(decoded.mipLevels[1] == Data([128, 0, 0, 128]))
        #expect(decoded.mipLevels[2] == Data([64]))
        #expect(decoded.residentByteCount == 21)
        #expect(!decoded.wasResampled)
        #expect(decoded.diagnostics == [])
    }

    @Test
    func oversizedFixturePreservesAspectRatioWithoutUpscaling() throws {
        let wideData = try Fixture.wide8x4.data()
        let wide = try decode(wideData, width: 8, height: 4, ceiling: 4)
        let smallData = try Fixture.coverage2x2.data()
        let small = try decode(smallData, width: 2, height: 2, ceiling: 4)

        #expect(wide.workingWidth == 4)
        #expect(wide.workingHeight == 2)
        #expect(wide.wasResampled)
        #expect(wide.diagnostics == [
            .resourceResampled(
                id: "shape.main",
                sourceWidth: 8,
                sourceHeight: 4,
                workingWidth: 4,
                workingHeight: 2
            ),
        ])
        #expect(small.workingWidth == 2)
        #expect(small.workingHeight == 2)
        #expect(!small.wasResampled)
    }

    @Test
    func oddMipGeometryMatchesMetalAndAveragesEverySourceTexel() throws {
        let decoded = try decode(
            Fixture.odd3x3.data(),
            width: 3,
            height: 3,
            ceiling: 3
        )

        #expect(decoded.mipLevels.map(\.count) == [9, 1])
        #expect(decoded.mipLevels[1] == Data([142]))
        #expect(decoded.residentByteCount == 10)
    }

    @Test
    func rectangularOddMipBinsCoverNarrowAndWidePartitions() throws {
        let decoded = try decode(
            Fixture.area5x3.data(),
            width: 5,
            height: 3,
            ceiling: 5
        )

        #expect(decoded.mipLevels.map(\.count) == [15, 2, 1])
        #expect(decoded.mipLevels[1] == Data([20, 133]))
        #expect(decoded.mipLevels[2] == Data([77]))
        #expect(decoded.residentByteCount == 18)
    }

    @Test
    func repeatedDecodeProducesIdenticalCoverageAndMips() throws {
        let data = try Fixture.exact4x4.data()

        let first = try decode(data, width: 4, height: 4, ceiling: 4)
        let second = try decode(data, width: 4, height: 4, ceiling: 4)

        #expect(first == second)
        #expect(first.mipLevels == second.mipLevels)
    }

    @Test
    func asymmetricFixtureRetainsTopLeftOrientation() throws {
        let decoded = try decode(
            Fixture.exact4x4.data(),
            width: 4,
            height: 4,
            ceiling: 4
        )

        #expect(Array(decoded.mipLevels[0].prefix(4)) == [255, 0, 0, 0])
        #expect(Array(decoded.mipLevels[0].suffix(4)) == [0, 0, 0, 255])
    }

    @Test
    func coverageIsLinearGrayscaleMultipliedByAlpha() throws {
        let decoded = try decode(
            Fixture.coverage2x2.data(),
            width: 2,
            height: 2,
            ceiling: 2
        )

        // sRGB 0.5 becomes 0.216 linear coverage. Transparent white is zero.
        #expect(decoded.mipLevels[0] == Data([55, 0, 128, 0]))
    }

    @Test
    func grayscaleCoverageDistinguishesNativeLinearFromTaggedNonlinear() throws {
        let native = try decode(
            Fixture.unprofiledGrayAlpha2x2.data(),
            width: 2,
            height: 2,
            ceiling: 2
        )
        let tagged = try decode(
            Fixture.taggedGrayAlpha2x1.data(),
            width: 2,
            height: 1,
            ceiling: 2
        )

        #expect(native.mipLevels[0] == Data([0, 128, 128, 0]))
        #expect(tagged.mipLevels[0] == Data([55, 128]))
    }

    @Test
    func acceptsDeclaredSingleFrameTIFF() throws {
        let data = try Fixture.singleFrameTIFF.data()
        let decoded = try decode(
            data,
            width: 2,
            height: 2,
            ceiling: 2,
            mediaType: "image/tiff"
        )

        #expect(decoded.mipLevels[0] == Data([0, 85, 170, 255]))
    }

    @Test
    func rejectsMalformedAndMultipleFrameImages() throws {
        let malformed = Data([0x89, 0x50, 0x4e, 0x47])
        let malformedResource = try resource(
            data: malformed,
            width: 2,
            height: 2
        )
        #expect(throws: BrushAssetDecodeError.invalidImage(id: "shape.main")) {
            _ = try BrushAssetDecoder.decode(
                resource: malformedResource,
                data: malformed,
                profile: profile(ceiling: 2)
            )
        }

        let multi = try Fixture.multiFrameTIFF.data()
        let multiResource = try resource(
            data: multi,
            width: 2,
            height: 2,
            mediaType: "image/tiff"
        )
        #expect(throws: BrushAssetDecodeError.multipleImageFrames(
            id: "shape.main",
            count: 2
        )) {
            _ = try BrushAssetDecoder.decode(
                resource: multiResource,
                data: multi,
                profile: profile(ceiling: 2)
            )
        }
    }

    @Test
    func rejectsMediaTypeAndResourceKindMismatch() throws {
        let tiff = try Fixture.singleFrameTIFF.data()
        let declaredPNG = try resource(
            data: tiff,
            width: 2,
            height: 2,
            mediaType: "image/png"
        )
        #expect(throws: BrushAssetDecodeError.imageTypeMismatch(
            id: "shape.main",
            declaredMediaType: "image/png",
            actualTypeIdentifier: "public.tiff"
        )) {
            _ = try BrushAssetDecoder.decode(
                resource: declaredPNG,
                data: tiff,
                profile: profile(ceiling: 2)
            )
        }

        let png = try Fixture.coverage2x2.data()
        let preview = try resource(
            data: png,
            kind: .preview,
            width: 2,
            height: 2
        )
        #expect(throws: BrushAssetDecodeError.unsupportedResourceKind(
            id: "shape.main",
            kind: .preview
        )) {
            _ = try BrushAssetDecoder.decode(
                resource: preview,
                data: png,
                profile: profile(ceiling: 2)
            )
        }
    }

    @Test
    func rejectsNonUpOrientationBeforeDecode() throws {
        let data = try Fixture.orientedTIFF2x2.data()
        let oriented = try resource(
            data: data,
            width: 2,
            height: 2,
            mediaType: "image/tiff"
        )

        #expect(throws: BrushAssetDecodeError.unsupportedOrientation(
            id: "shape.main",
            orientation: 6
        )) {
            _ = try BrushAssetDecoder.decode(
                resource: oriented,
                data: data,
                profile: profile(ceiling: 2)
            )
        }
    }

    @Test
    func rejectsDeclaredAndActualDimensionMismatch() throws {
        let data = try Fixture.exact4x4.data()
        let mismatched = try resource(data: data, width: 3, height: 4)

        #expect(throws: BrushAssetDecodeError.dimensionMismatch(
            id: "shape.main",
            declaredWidth: 3,
            declaredHeight: 4,
            actualWidth: 4,
            actualHeight: 4
        )) {
            _ = try BrushAssetDecoder.decode(
                resource: mismatched,
                data: data,
                profile: profile(ceiling: 4)
            )
        }
    }

    @Test
    func rejectsEncodedCountAndHashMismatchBeforeImageDecode() throws {
        let data = try Fixture.coverage2x2.data()
        let valid = try resource(data: data, width: 2, height: 2)
        let extra = data + Data([0])
        #expect(throws: BrushAssetDecodeError.encodedByteCountMismatch(
            id: "shape.main",
            declared: data.count,
            actual: extra.count
        )) {
            _ = try BrushAssetDecoder.decode(
                resource: valid,
                data: extra,
                profile: profile(ceiling: 2)
            )
        }

        var altered = data
        altered[altered.startIndex] ^= 0xff
        #expect(throws: BrushAssetDecodeError.contentHashMismatch(id: "shape.main")) {
            _ = try BrushAssetDecoder.decode(
                resource: valid,
                data: altered,
                profile: profile(ceiling: 2)
            )
        }
    }

    @Test
    func checkedSizingRejectsMissingZeroAndOverflowingValues() {
        #expect(throws: BrushAssetDecodeError.missingImageProperties(id: "shape.main")) {
            _ = try BrushAssetSizing.validatedSourceDimensions(
                resourceID: "shape.main",
                width: nil,
                height: 2
            )
        }
        #expect(throws: BrushAssetDecodeError.invalidDimensions(
            id: "shape.main",
            width: 0,
            height: 2
        )) {
            _ = try BrushAssetSizing.validatedSourceDimensions(
                resourceID: "shape.main",
                width: 0,
                height: 2
            )
        }
        #expect(throws: BrushAssetDecodeError.decodedByteCountOverflow(id: "shape.main")) {
            _ = try BrushAssetSizing.checkedPixelCount(
                resourceID: "shape.main",
                width: Int.max,
                height: 2
            )
        }
        #expect(throws: BrushAssetDecodeError.mipByteCountOverflow(id: "shape.main")) {
            _ = try BrushAssetSizing.checkedMipByteCount(
                resourceID: "shape.main",
                levelByteCounts: [Int.max, 1]
            )
        }
        #expect(throws: BrushAssetDecodeError.decodedByteCountOverflow(id: "shape.main")) {
            _ = try BrushAssetSizing.checkedSourceDecodedByteCount(
                resourceID: "shape.main",
                width: Int.max,
                height: 2,
                componentCount: 4,
                bytesPerComponent: 2
            )
        }
        #expect(throws: BrushAssetDecodeError.intermediateImageExceedsBounds(
            id: "shape.main",
            width: 5,
            height: 2,
            maximumDimension: 4
        )) {
            try BrushAssetSizing.validateIntermediateDimensions(
                resourceID: "shape.main",
                width: 5,
                height: 2,
                maximumDimension: 4
            )
        }
        #expect(throws: BrushAssetDecodeError.intermediateImageAspectMismatch(
            id: "shape.main",
            width: 4,
            height: 3,
            sourceWidth: 8,
            sourceHeight: 4
        )) {
            try BrushAssetSizing.validateIntermediateAspect(
                resourceID: "shape.main",
                width: 4,
                height: 3,
                sourceWidth: 8,
                sourceHeight: 4
            )
        }
        #expect(throws: BrushAssetDecodeError.transientDecodedBytesExceedLimit(
            id: "shape.main",
            requested: 65,
            limit: 64
        )) {
            try BrushAssetSizing.validateTransientDecodedByteCount(
                resourceID: "shape.main",
                requested: 65,
                limit: 64
            )
        }
        #expect(throws: Never.self) {
            try BrushAssetSizing.validateIntermediateAspect(
                resourceID: "shape.main",
                width: 4,
                height: 2,
                sourceWidth: 8,
                sourceHeight: 4
            )
            try BrushAssetSizing.validateTransientDecodedByteCount(
                resourceID: "shape.main",
                requested: 64,
                limit: 64
            )
        }
    }

    @Test
    func preflightRejectsUnsupportedColorDepthFloatAndOrientation() throws {
        let valid = try BrushAssetImageProperties.validated(
            resourceID: "shape.main",
            properties: imageProperties(
                colorModel: kCGImagePropertyColorModelRGB,
                depth: 16,
                hasAlpha: true
            )
        )
        #expect(valid.sourceDecodedByteCount == 32)
        #expect(try valid.decodedByteCount(
            resourceID: "shape.main",
            width: 1,
            height: 1
        ) == 8)

        #expect(throws: BrushAssetDecodeError.unsupportedColorModel(
            id: "shape.main",
            model: "CMYK"
        )) {
            _ = try BrushAssetImageProperties.validated(
                resourceID: "shape.main",
                properties: imageProperties(
                    colorModel: kCGImagePropertyColorModelCMYK
                )
            )
        }
        #expect(throws: BrushAssetDecodeError.unsupportedBitDepth(
            id: "shape.main",
            depth: 32
        )) {
            _ = try BrushAssetImageProperties.validated(
                resourceID: "shape.main",
                properties: imageProperties(depth: 32)
            )
        }
        #expect(throws: BrushAssetDecodeError.floatingPointComponentsUnsupported(
            id: "shape.main"
        )) {
            _ = try BrushAssetImageProperties.validated(
                resourceID: "shape.main",
                properties: imageProperties(isFloat: true)
            )
        }
        #expect(throws: BrushAssetDecodeError.unsupportedOrientation(
            id: "shape.main",
            orientation: 6
        )) {
            _ = try BrushAssetImageProperties.validated(
                resourceID: "shape.main",
                properties: imageProperties(orientation: 6)
            )
        }
    }

    @Test
    func workspaceRejectsAggregatePeakWhenEachComponentFits() throws {
        let estimate = try BrushAssetWorkspaceEstimate.checked(
            resourceID: "shape.main",
            width: 4,
            height: 4,
            colorModel: .rgb,
            intermediateByteCount: 64
        )

        #expect(estimate.intermediateByteCount == 64)
        #expect(estimate.conversionScratchByteCount == 64)
        #expect(estimate.coverageStorageByteCount == 32)
        #expect(estimate.conversionPhasePeakByteCount == 160)
        #expect(estimate.mipGenerationPhasePeakByteCount == 45)
        #expect(estimate.peakByteCount == 160)
        #expect(throws: BrushAssetDecodeError.transientDecodedBytesExceedLimit(
            id: "shape.main",
            requested: 160,
            limit: 100
        )) {
            try estimate.validate(
                resourceID: "shape.main",
                limit: 100
            )
        }

        let largerActualIntermediate =
            try estimate.replacingIntermediateByteCount(
                resourceID: "shape.main",
                intermediateByteCount: 120
            )
        #expect(largerActualIntermediate.peakByteCount == 216)
        #expect(throws: BrushAssetDecodeError.transientDecodedBytesExceedLimit(
            id: "shape.main",
            requested: 216,
            limit: 200
        )) {
            try largerActualIntermediate.validate(
                resourceID: "shape.main",
                limit: 200
            )
        }
        #expect(throws: BrushAssetDecodeError.decodedByteCountOverflow(
            id: "shape.main"
        )) {
            _ = try BrushAssetWorkspaceEstimate.checked(
                resourceID: "shape.main",
                width: 1,
                height: 1,
                colorModel: .gray,
                intermediateByteCount: Int.max
            )
        }
    }

    @Test
    func portableMaximumGrayAndRGBWorkspaceFitsExplicitCeiling() throws {
        let mebibyte = 1_024 * 1_024
        let limit = 256 * mebibyte
        let grayProperties = try BrushAssetImageProperties.validated(
            resourceID: "shape.main",
            properties: imageProperties(
                width: 4_096,
                height: 4_096,
                depth: 16
            )
        )
        let rgbProperties = try BrushAssetImageProperties.validated(
            resourceID: "shape.main",
            properties: imageProperties(
                width: 4_096,
                height: 4_096,
                colorModel: kCGImagePropertyColorModelRGB,
                depth: 16,
                hasAlpha: true
            )
        )
        let gray16 = try BrushAssetWorkspaceEstimate.checked(
            resourceID: "shape.main",
            width: 4_096,
            height: 4_096,
            colorModel: grayProperties.colorModel,
            intermediateByteCount: grayProperties.sourceDecodedByteCount
        )
        let rgb16 = try BrushAssetWorkspaceEstimate.checked(
            resourceID: "shape.main",
            width: 4_096,
            height: 4_096,
            colorModel: rgbProperties.colorModel,
            intermediateByteCount: rgbProperties.sourceDecodedByteCount
        )

        #expect(BrushAssetWorkspaceEstimate.maximumPortableByteCount == limit)
        #expect(grayProperties.sourceDecodedByteCount == 32 * mebibyte)
        #expect(rgbProperties.sourceDecodedByteCount == 128 * mebibyte)
        #expect(gray16.conversionPhasePeakByteCount == 96 * mebibyte)
        #expect(rgb16.conversionPhasePeakByteCount == 224 * mebibyte)
        #expect(gray16.mipGenerationPhasePeakByteCount == 47_535_445)
        #expect(rgb16.mipGenerationPhasePeakByteCount == 47_535_445)
        #expect(gray16.peakByteCount < limit)
        #expect(rgb16.peakByteCount < limit)
        #expect(throws: Never.self) {
            try gray16.validate(resourceID: "shape.main", limit: limit)
            try rgb16.validate(resourceID: "shape.main", limit: limit)
        }
    }

    @Test
    func decodeIsCallableFromDetachedTask() async throws {
        let data = try Fixture.exact4x4.data()
        let resource = try resource(data: data, width: 4, height: 4)
        let deviceProfile = try profile(ceiling: 4)

        let decoded = try await Task.detached {
            try BrushAssetDecoder.decode(
                resource: resource,
                data: data,
                profile: deviceProfile
            )
        }.value

        #expect(decoded.residentByteCount == 21)
    }

    private func decode(
        _ data: Data,
        width: Int,
        height: Int,
        ceiling: Int,
        mediaType: String = "image/png"
    ) throws -> DecodedBrushTexture {
        try BrushAssetDecoder.decode(
            resource: resource(
                data: data,
                width: width,
                height: height,
                mediaType: mediaType
            ),
            data: data,
            profile: profile(ceiling: ceiling)
        )
    }

    private func resource(
        data: Data,
        kind: BrushResourceKind = .shape,
        width: Int,
        height: Int,
        mediaType: String = "image/png"
    ) throws -> BrushPackageResource {
        try BrushPackageResource(
            id: "shape.main",
            kind: kind,
            mediaType: mediaType,
            data: data,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    private func profile(ceiling: Int) throws -> BrushDeviceProfile {
        try BrushDeviceProfile(
            registryID: 7,
            recommendedWorkingSetBytes: 1_024 * 1_024 * 1_024,
            maximumWorkingTextureDimension: ceiling,
            targetFramesPerSecond: 120
        )
    }
}

private func imageProperties(
    width: Int = 2,
    height: Int = 2,
    colorModel: CFString = kCGImagePropertyColorModelGray,
    depth: Int = 8,
    hasAlpha: Bool = false,
    isFloat: Bool = false,
    orientation: Int = 1
) -> [CFString: Any] {
    [
        kCGImagePropertyPixelWidth: NSNumber(value: width),
        kCGImagePropertyPixelHeight: NSNumber(value: height),
        kCGImagePropertyColorModel: colorModel,
        kCGImagePropertyDepth: NSNumber(value: depth),
        kCGImagePropertyHasAlpha: NSNumber(value: hasAlpha),
        kCGImagePropertyIsFloat: NSNumber(value: isFloat),
        kCGImagePropertyOrientation: NSNumber(value: orientation),
    ]
}

private enum Fixture: String {
    case exact4x4 = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAABKADAAQAAAABAAAABAAAAADFbP4CAAAAJ0lEQVQIHWP4DwQMDAxwzMTIyMgAEQMKAwETiEAWZATyQcrBAKQSAJJxEPsf8WuRAAAAAElFTkSuQmCC"
    case wide8x4 = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAYAAACzzX7wAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAACKADAAQAAAABAAAABAAAAABQdJZTAAAAGUlEQVQIHWP4DwQMDAwgCivNBJTECyhXAAARfxPzMqX7wAAAAABJRU5ErkJggg=="
    case odd3x3 = "iVBORw0KGgoAAAANSUhEUgAAAAMAAAADCAYAAABWKLW/AAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAA6ADAAQAAAABAAAAAwAAAABX3l5ZAAAAHElEQVQIHWNkYGD4D8QM////Z2ACMWCABSQCAwCbGwcBjPdTgwAAAABJRU5ErkJggg=="
    case area5x3 = "iVBORw0KGgoAAAANSUhEUgAAAAUAAAADCAAAAAB+XZokAAAAFklEQVR42mNgYEhJSWGAkDY2J06cAAAgpgUpFOIfHgAAAABJRU5ErkJggg=="
    case coverage2x2 = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAqADAAQAAAABAAAAAgAAAADtGLyqAAAAFklEQVQIHWNoaGj4DwQMDECigQFIAQBiSgn5RlJcQwAAAABJRU5ErkJggg=="
    case unprofiledGrayAlpha2x2 = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAQAAADYv8WvAAAADklEQVR42mNg+N/wH4wBGPYE/bv3jn4AAAAASUVORK5CYII="
    case taggedGrayAlpha2x1 = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAQAAABeK7cBAAAABGdBTUEAALGPC/xhBQAAAAFzUkdCAK7OHOkAAAANSURBVHjaY2j4/78BAAeAAv9qX62dAAAAAElFTkSuQmCC"
    case singleFrameTIFF = "SUkqAAgAAAAJAAABAwABAAAAAgAAAAEBAwABAAAAAgAAAAIBAwABAAAACAAAAAMBAwABAAAAAQAAAAYBAwABAAAAAQAAABEBBAABAAAAegAAABUBAwABAAAAAQAAABYBBAABAAAAAgAAABcBBAABAAAABAAAAAAAAAAAVar/"
    case multiFrameTIFF = "SUkqAAgAAAAJAAABAwABAAAAAgAAAAEBAwABAAAAAgAAAAIBAwABAAAACAAAAAMBAwABAAAAAQAAAAYBAwABAAAAAQAAABEBBAABAAAA7AAAABUBAwABAAAAAQAAABYBBAABAAAAAgAAABcBBAABAAAABAAAAHoAAAAJAAABAwABAAAAAgAAAAEBAwABAAAAAgAAAAIBAwABAAAACAAAAAMBAwABAAAAAQAAAAYBAwABAAAAAQAAABEBBAABAAAA8AAAABUBAwABAAAAAQAAABYBBAABAAAAAgAAABcBBAABAAAABAAAAAAAAAAAVar/AFWq/w=="
    case orientedTIFF2x2 = "SUkqAAgAAAAKAAABAwABAAAAAgAAAAEBAwABAAAAAgAAAAIBAwABAAAACAAAAAMBAwABAAAAAQAAAAYBAwABAAAAAQAAABEBBAABAAAAhgAAABIBAwABAAAABgAAABUBAwABAAAAAQAAABYBBAABAAAAAgAAABcBBAABAAAABAAAAAAAAAAAVar/"

    func data() throws -> Data {
        try #require(Data(base64Encoded: rawValue))
    }
}
