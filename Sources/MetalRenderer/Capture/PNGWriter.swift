import CoreGraphics
import Foundation
import ImageIO
import Metal
import PatternEngine
import UniformTypeIdentifiers

public enum PNGWriter {
    @MainActor
    public static func pixel(
        in texture: any MTLTexture,
        x: Int,
        y: Int
    ) -> SIMD4<UInt8> {
        precondition(texture.pixelFormat == .bgra8Unorm)
        precondition((0..<texture.width).contains(x))
        precondition((0..<texture.height).contains(y))

        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 4,
                from: MTLRegionMake2D(x, y, 1, 1),
                mipmapLevel: 0
            )
        }
        return SIMD4(pixel[0], pixel[1], pixel[2], pixel[3])
    }

    @MainActor
    public static func write(
        texture: any MTLTexture,
        to url: URL
    ) throws {
        guard texture.pixelFormat == .bgra8Unorm else {
            throw PNGWriterError.unsupportedPixelFormat(texture.pixelFormat.rawValue)
        }

        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count: bytesPerRow * texture.height
        )
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        try writeBGRA(
            bytes,
            pixelSize: PixelSize(
                width: texture.width,
                height: texture.height
            ),
            to: url
        )
    }

    public static func writeBGRA(
        _ bytes: [UInt8],
        pixelSize: PixelSize,
        to url: URL
    ) throws {
        guard bytes.count == pixelSize.width * pixelSize.height * 4 else {
            throw PNGWriterError.invalidByteCount(bytes.count)
        }
        let bytesPerRow = pixelSize.width * 4
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            throw PNGWriterError.dataProviderCreationFailed
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
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
            throw PNGWriterError.imageCreationFailed
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PNGWriterError.destinationCreationFailed
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PNGWriterError.finalizeFailed
        }
    }

    public static func write(
        coverage: OracleCoverage,
        to url: URL
    ) throws {
        var bgra: [UInt8] = []
        bgra.reserveCapacity(coverage.bytes.count * 4)
        for byte in coverage.bytes {
            bgra.append(contentsOf: [byte, byte, byte, 255])
        }
        try writeBGRA(bgra, pixelSize: coverage.pixelSize, to: url)
    }
}

public enum PNGWriterError: Error, Equatable, LocalizedError {
    case unsupportedPixelFormat(UInt)
    case invalidByteCount(Int)
    case dataProviderCreationFailed
    case imageCreationFailed
    case destinationCreationFailed
    case finalizeFailed

    public var errorDescription: String? {
        switch self {
        case let .unsupportedPixelFormat(rawValue):
            "Unsupported capture pixel format \(rawValue)."
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
