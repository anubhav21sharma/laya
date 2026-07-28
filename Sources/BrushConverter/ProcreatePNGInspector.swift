import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ProcreatePNGError: Error, Equatable, Sendable {
    case invalidSignature
    case invalidHeader
    case dimensionsOutOfRange(width: Int, height: Int)
    case unsupportedColorType(UInt8)
    case invalidImage
}

struct ProcreatePNGMetadata: Equatable, Sendable {
    let width: Int
    let height: Int
    let channelModel: ForeignBrushChannelModel
}

enum ProcreatePNGInspector {
    private static let signature = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ])

    static func inspect(_ data: Data) throws -> ProcreatePNGMetadata {
        guard data.starts(with: signature) else {
            throw ProcreatePNGError.invalidSignature
        }
        let source = data.startIndex == 0 ? data : Data(data)
        guard source.count >= 33,
              source.uint32BigEndian(at: 8) == 13,
              source[12 ..< 16] == Data("IHDR".utf8)
        else {
            throw ProcreatePNGError.invalidHeader
        }
        let width = Int(source.uint32BigEndian(at: 16))
        let height = Int(source.uint32BigEndian(at: 20))
        guard (1 ... ForeignBrushLimits.maximumSourceImageDimension)
            .contains(width),
            (1 ... ForeignBrushLimits.maximumSourceImageDimension)
            .contains(height)
        else {
            throw ProcreatePNGError.dimensionsOutOfRange(
                width: width,
                height: height
            )
        }
        let channelModel: ForeignBrushChannelModel
        switch source[25] {
        case 0:
            channelModel = .grayscale
        case 2, 3:
            channelModel = .rgb
        case 4:
            channelModel = .grayscaleAlpha
        case 6:
            channelModel = .rgba
        default:
            throw ProcreatePNGError.unsupportedColorType(source[25])
        }
        guard source[26] == 0,
              source[27] == 0,
              source[28] <= 1,
              let imageSource = CGImageSourceCreateWithData(
                  source as CFData,
                  nil
              ),
              CGImageSourceGetCount(imageSource) == 1,
              CGImageSourceGetType(imageSource) as String?
              == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(
                  imageSource,
                  0,
                  nil
              ),
              image.width == width,
              image.height == height
        else {
            throw ProcreatePNGError.invalidImage
        }
        return ProcreatePNGMetadata(
            width: width,
            height: height,
            channelModel: channelModel
        )
    }
}

private extension Data {
    func uint32BigEndian(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= count)
        return self[offset ..< offset + 4].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }
}
