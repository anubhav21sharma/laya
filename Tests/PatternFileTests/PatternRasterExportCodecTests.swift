import CoreGraphics
import Foundation
import ImageIO
import PatternEngine
import PatternFile
import Testing
import UniformTypeIdentifiers

@Suite("Pattern raster export formats")
struct PatternRasterExportCodecTests {
    @Test
    func pngAndTIFFPreserveDimensionsAndLosslessPixels() throws {
        let image = try exportFixture()
        for (format, expectedType) in [
            (PatternRasterExportFormat.png, UTType.png),
            (.tiff, UTType.tiff),
        ] {
            let data = try PatternRasterExportCodec.encode(
                image,
                as: format
            )
            let decoded = try decodeExport(data)
            #expect(decoded.type == expectedType.identifier)
            #expect(decoded.image == image)
        }
    }

    @Test
    func jpegRequiresValidQualityAndFlattensToChosenBackground()
        throws
    {
        let size = PixelSize(width: 16, height: 16)
        var bytes = [UInt8](
            repeating: 0,
            count: size.width * size.height * 4
        )
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            bytes[offset] = 0
            bytes[offset + 1] = 0
            bytes[offset + 2] = 0
            bytes[offset + 3] = 0
        }
        let transparent = try PatternRasterImage(
            pixelSize: size,
            bgra8PremultipliedBytes: bytes
        )
        #expect(
            throws: PatternRasterExportError.invalidJPEGQuality(-0.1)
        ) {
            try PatternRasterExportCodec.encode(
                transparent,
                as: .jpeg(quality: -0.1, background: .white)
            )
        }
        #expect(
            throws: PatternRasterExportError.invalidJPEGQuality(1.1)
        ) {
            try PatternRasterExportCodec.encode(
                transparent,
                as: .jpeg(quality: 1.1, background: .white)
            )
        }

        let white = try decodeExport(
            PatternRasterExportCodec.encode(
                transparent,
                as: .jpeg(quality: 1, background: .white)
            )
        )
        let black = try decodeExport(
            PatternRasterExportCodec.encode(
                transparent,
                as: .jpeg(quality: 1, background: .black)
            )
        )
        #expect(white.type == UTType.jpeg.identifier)
        #expect(black.type == UTType.jpeg.identifier)
        #expect(
            white.image.bgra8PremultipliedBytes.allSatisfy { $0 == 255 }
        )
        for offset in stride(
            from: 0,
            to: black.image.bgra8PremultipliedBytes.count,
            by: 4
        ) {
            #expect(
                black.image.bgra8PremultipliedBytes[offset] <= 1
            )
            #expect(
                black.image.bgra8PremultipliedBytes[offset + 1] <= 1
            )
            #expect(
                black.image.bgra8PremultipliedBytes[offset + 2] <= 1
            )
            #expect(
                black.image.bgra8PremultipliedBytes[offset + 3] == 255
            )
        }
    }
}

private func exportFixture() throws -> PatternRasterImage {
    let size = PixelSize(width: 16, height: 16)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(size.width * size.height * 4)
    for index in 0..<(size.width * size.height) {
        let alpha = UInt8(truncatingIfNeeded: index)
        bytes.append(UInt8(UInt16(index & 0xFF) % (UInt16(alpha) + 1)))
        bytes.append(
            UInt8(UInt16((index * 3) & 0xFF) % (UInt16(alpha) + 1))
        )
        bytes.append(
            UInt8(UInt16((index * 7) & 0xFF) % (UInt16(alpha) + 1))
        )
        bytes.append(alpha)
    }
    return try PatternRasterImage(
        pixelSize: size,
        bgra8PremultipliedBytes: bytes
    )
}

private func decodeExport(
    _ data: Data
) throws -> (type: String, image: PatternRasterImage) {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    let source = try #require(
        CGImageSourceCreateWithData(data as CFData, options)
    )
    let type = try #require(CGImageSourceGetType(source) as String?)
    let cgImage = try #require(
        CGImageSourceCreateImageAtIndex(source, 0, options)
    )
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerRow = width * 4
    var bytes = [UInt8](
        repeating: 0,
        count: bytesPerRow * height
    )
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
        CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
        )
    )
    let context = try #require(CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo.rawValue
    ))
    context.setBlendMode(.copy)
    context.draw(
        cgImage,
        in: CGRect(x: 0, y: 0, width: width, height: height)
    )
    return (
        type,
        try PatternRasterImage(
            pixelSize: PixelSize(width: width, height: height),
            bgra8PremultipliedBytes: bytes
        )
    )
}
