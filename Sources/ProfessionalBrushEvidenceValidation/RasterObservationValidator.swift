import CoreGraphics
import Foundation
import ImageIO

struct DecodedRaster {
    let width: Int
    let height: Int
    let bgra: [UInt8]
}

enum RasterObservationValidator {
    static func decode(_ data: Data, label: String) throws -> DecodedRaster {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 128,
              image.height == 128
        else {
            throw ArtifactFileSystem.invalid(
                "\(label) is not one 128x128 PNG image"
            )
        }
        var bytes = [UInt8](
            repeating: 0,
            count: image.width * image.height * 4
        )
        let info = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        )
        guard let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info.rawValue
        ) else {
            throw ArtifactFileSystem.invalid(
                "\(label) cannot be decoded as BGRA8"
            )
        }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return DecodedRaster(
            width: image.width,
            height: image.height,
            bgra: bytes
        )
    }

    static func maximumChannelDelta(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> Int {
        guard lhs.count == rhs.count else { return 256 }
        return zip(lhs, rhs).reduce(0) {
            max($0, abs(Int($1.0) - Int($1.1)))
        }
    }

    static func nontransparentPixelCount(_ bytes: [UInt8]) -> Int {
        stride(from: 3, to: bytes.count, by: 4).reduce(0) {
            $0 + (bytes[$1] > 0 ? 1 : 0)
        }
    }

    static func reducedAlphaPixelCount(
        before: [UInt8],
        after: [UInt8]
    ) -> Int {
        guard before.count == after.count else { return 0 }
        return stride(from: 3, to: before.count, by: 4).reduce(0) {
            $0 + (after[$1] < before[$1] ? 1 : 0)
        }
    }
}
