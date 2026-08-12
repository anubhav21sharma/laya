import CoreGraphics
import Foundation
import ImageIO
import PatternEngine
import UniformTypeIdentifiers

/// Product PNG export from an already-rendered encoded BGRA8 snapshot.
/// Texture readback and evidence-specific coverage conversion remain in the
/// diagnostics target.
public enum EncodedPNGWriter {
    public static func writeBGRA(
        _ bytes: [UInt8],
        pixelSize: PixelSize,
        to url: URL
    ) throws {
        guard bytes.count == pixelSize.width * pixelSize.height * 4 else {
            throw EncodedPNGWriterError.invalidByteCount(bytes.count)
        }
        let bytesPerRow = pixelSize.width * 4
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            throw EncodedPNGWriterError.dataProviderCreationFailed
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        )
        guard let image = CGImage(
            width: pixelSize.width,
            height: pixelSize.height,
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
            throw EncodedPNGWriterError.imageCreationFailed
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw EncodedPNGWriterError.destinationCreationFailed
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw EncodedPNGWriterError.finalizeFailed
        }
    }
}

public enum EncodedPNGWriterError: Error, Equatable, LocalizedError {
    case invalidByteCount(Int)
    case dataProviderCreationFailed
    case imageCreationFailed
    case destinationCreationFailed
    case finalizeFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidByteCount(count):
            "PNG BGRA input has invalid byte count \(count)."
        case .dataProviderCreationFailed:
            "PNG data provider creation failed."
        case .imageCreationFailed:
            "PNG image creation failed."
        case .destinationCreationFailed:
            "PNG destination creation failed."
        case .finalizeFailed:
            "PNG encoding failed."
        }
    }
}
