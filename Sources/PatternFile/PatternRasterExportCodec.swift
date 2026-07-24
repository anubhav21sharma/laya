import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PatternRasterExportFormat: Equatable, Sendable {
    case png
    case tiff
    case jpeg(quality: Float, background: PatternOpaqueColor)
}

public struct PatternOpaqueColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = Self(red: 255, green: 255, blue: 255)
    public static let black = Self(red: 0, green: 0, blue: 0)
}

public enum PatternRasterExportError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidJPEGQuality(Float)
    case invalidDimensions(width: Int, height: Int)
    case encodingFailed
    case encodedDataTooLarge(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidJPEGQuality(quality):
            "JPEG quality \(quality) is outside 0...1."
        case let .invalidDimensions(width, height):
            "Export dimensions \(width)x\(height) are outside 1...8192."
        case .encodingFailed:
            "Raster export encoding failed."
        case let .encodedDataTooLarge(actual, maximum):
            "Encoded export is \(actual) bytes; the limit is \(maximum)."
        }
    }
}

public enum PatternRasterExportCodec {
    public static let maximumDimension = 8_192
    public static let maximumEncodedBytes = 512 * 1_024 * 1_024

    public static func encode(
        _ image: PatternRasterImage,
        as format: PatternRasterExportFormat
    ) throws -> Data {
        switch format {
        case .png:
            return try encodeImage(
                image,
                type: .png,
                properties: nil
            )
        case .tiff:
            return try encodeImage(
                image,
                type: .tiff,
                properties: nil
            )
        case let .jpeg(quality, background):
            guard quality.isFinite, (0...1).contains(quality) else {
                throw PatternRasterExportError.invalidJPEGQuality(quality)
            }
            let flattened = try PatternRasterImage(
                pixelSize: image.pixelSize,
                bgra8PremultipliedBytes: flatten(
                    image.bgra8PremultipliedBytes,
                    over: background
                )
            )
            return try encodeImage(
                flattened,
                type: .jpeg,
                properties: [
                    kCGImageDestinationLossyCompressionQuality:
                        quality,
                ] as CFDictionary
            )
        }
    }
}

private extension PatternRasterExportCodec {
    static func encodeImage(
        _ image: PatternRasterImage,
        type: UTType,
        properties: CFDictionary?
    ) throws -> Data {
        guard (1...maximumDimension).contains(image.pixelSize.width),
              (1...maximumDimension).contains(image.pixelSize.height)
        else {
            throw PatternRasterExportError.invalidDimensions(
                width: image.pixelSize.width,
                height: image.pixelSize.height
            )
        }
        let bytesPerRow = image.pixelSize.width * 4
        guard let provider = CGDataProvider(
            data: Data(image.bgra8PremultipliedBytes) as CFData
        ) else {
            throw PatternRasterExportError.encodingFailed
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
            throw PatternRasterExportError.encodingFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw PatternRasterExportError.encodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw PatternRasterExportError.encodingFailed
        }
        let encoded = output as Data
        guard encoded.count <= maximumEncodedBytes
        else {
            throw PatternRasterExportError.encodedDataTooLarge(
                actual: encoded.count,
                maximum: maximumEncodedBytes
            )
        }
        return encoded
    }

    static func flatten(
        _ bytes: [UInt8],
        over background: PatternOpaqueColor
    ) -> [UInt8] {
        var result = bytes
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = UInt16(bytes[offset + 3])
            let inverseAlpha = 255 - alpha
            result[offset] = composite(
                bytes[offset],
                background: background.blue,
                inverseAlpha: inverseAlpha
            )
            result[offset + 1] = composite(
                bytes[offset + 1],
                background: background.green,
                inverseAlpha: inverseAlpha
            )
            result[offset + 2] = composite(
                bytes[offset + 2],
                background: background.red,
                inverseAlpha: inverseAlpha
            )
            result[offset + 3] = 255
        }
        return result
    }

    static func composite(
        _ premultiplied: UInt8,
        background: UInt8,
        inverseAlpha: UInt16
    ) -> UInt8 {
        let backgroundContribution =
            (UInt16(background) * inverseAlpha + 127) / 255
        return UInt8(
            min(
                255,
                UInt16(premultiplied) + backgroundContribution
            )
        )
    }
}
