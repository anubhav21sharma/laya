import CoreGraphics
import Foundation
import ImageIO
import PatternEngine
import UniformTypeIdentifiers

public struct PatternRasterImage: Equatable, Sendable {
    public let pixelSize: PixelSize
    public let bgra8PremultipliedBytes: [UInt8]

    public init(
        pixelSize: PixelSize,
        bgra8PremultipliedBytes: [UInt8]
    ) throws {
        let (bytesPerRow, rowOverflow) = pixelSize.width
            .multipliedReportingOverflow(by: 4)
        let (byteCount, imageOverflow) = bytesPerRow
            .multipliedReportingOverflow(by: pixelSize.height)
        guard !rowOverflow,
              !imageOverflow,
              bgra8PremultipliedBytes.count == byteCount
        else {
            throw PatternRasterImageError.invalidByteCount(
                bgra8PremultipliedBytes.count
            )
        }
        self.pixelSize = pixelSize
        self.bgra8PremultipliedBytes = bgra8PremultipliedBytes
    }
}

public enum PatternRasterImageError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case encodedDataTooLarge(actual: Int, maximum: Int)
    case invalidByteCount(Int)
    case invalidImage
    case unsupportedImageType
    case invalidDimensions(width: Int, height: Int)
    case unexpectedDimensions(
        expected: PixelSize,
        actualWidth: Int,
        actualHeight: Int
    )
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case let .encodedDataTooLarge(actual, maximum):
            "Encoded raster is \(actual) bytes; the limit is \(maximum)."
        case let .invalidByteCount(count):
            "BGRA raster byte count \(count) is invalid."
        case .invalidImage:
            "Raster data does not contain one valid image."
        case .unsupportedImageType:
            "Project rasters must be PNG images."
        case let .invalidDimensions(width, height):
            "Raster dimensions \(width)x\(height) are invalid."
        case let .unexpectedDimensions(expected, width, height):
            "Raster dimensions \(width)x\(height) do not match \(expected.width)x\(expected.height)."
        case .encodingFailed:
            "Raster PNG encoding failed."
        case .decodingFailed:
            "Raster PNG decoding failed."
        }
    }
}

public enum PatternRasterPNGCodec {
    public static let maximumEncodedBytes = 256 * 1_024 * 1_024
    public static let maximumDimension = 4_096

    public static func encode(
        _ image: PatternRasterImage
    ) throws -> Data {
        try validateDimensions(
            width: image.pixelSize.width,
            height: image.pixelSize.height
        )
        let bytesPerRow = image.pixelSize.width * 4
        guard let provider = CGDataProvider(
            data: Data(image.bgra8PremultipliedBytes) as CFData
        ) else {
            throw PatternRasterImageError.encodingFailed
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        )
        guard let cgImage = CGImage(
            width: image.pixelSize.width,
            height: image.pixelSize.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw PatternRasterImageError.encodingFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PatternRasterImageError.encodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PatternRasterImageError.encodingFailed
        }
        let encoded = output as Data
        guard encoded.count <= maximumEncodedBytes else {
            throw PatternRasterImageError.encodedDataTooLarge(
                actual: encoded.count,
                maximum: maximumEncodedBytes
            )
        }
        return encoded
    }

    public static func decode(
        _ data: Data,
        expectedPixelSize: PixelSize? = nil
    ) throws -> PatternRasterImage {
        guard data.count <= maximumEncodedBytes else {
            throw PatternRasterImageError.encodedDataTooLarge(
                actual: data.count,
                maximum: maximumEncodedBytes
            )
        }
        let options = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            options
        ),
            CGImageSourceGetCount(source) == 1
        else {
            throw PatternRasterImageError.invalidImage
        }
        guard CGImageSourceGetType(source) as String?
                == UTType.png.identifier
        else {
            throw PatternRasterImageError.unsupportedImageType
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            options
        ) as? [CFString: Any],
            let widthNumber =
                properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let heightNumber =
                properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw PatternRasterImageError.invalidImage
        }
        let width = widthNumber.intValue
        let height = heightNumber.intValue
        try validateDimensions(width: width, height: height)
        if let expectedPixelSize,
           expectedPixelSize.width != width
            || expectedPixelSize.height != height
        {
            throw PatternRasterImageError.unexpectedDimensions(
                expected: expectedPixelSize,
                actualWidth: width,
                actualHeight: height
            )
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(
            source,
            0,
            options
        ) else {
            throw PatternRasterImageError.decodingFailed
        }
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
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw PatternRasterImageError.decodingFailed
        }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return try PatternRasterImage(
            pixelSize: PixelSize(width: width, height: height),
            bgra8PremultipliedBytes: bytes
        )
    }

    private static func validateDimensions(
        width: Int,
        height: Int
    ) throws {
        guard (1...maximumDimension).contains(width),
              (1...maximumDimension).contains(height)
        else {
            throw PatternRasterImageError.invalidDimensions(
                width: width,
                height: height
            )
        }
    }
}
