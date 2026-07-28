import BrushFormat
import Foundation
import PatternEngine

struct NormalizedForeignBrushResource: Equatable, Sendable {
    let descriptor: BrushPackageResource
    let data: Data
    let transform: BrushConversionResourceTransformEvidence?
}

enum ForeignBrushResourceNormalizer {
    static let syntheticR8MediaType =
        SyntheticV1BrushParser.rawGrayscaleMediaType

    static func normalize(
        _ source: ForeignBrushResourceDescriptor,
        data: Data,
        kind: BrushResourceKind
    ) throws -> NormalizedForeignBrushResource {
        guard source.pixelWidth <= BrushFormatLimits.maximumImageDimension,
              source.pixelHeight <= BrushFormatLimits.maximumImageDimension
        else {
            throw SyntheticV1MappingError.unsupportedResource(
                resourceID: source.id,
                reason: "native-dimension-limit"
            )
        }

        guard source.mediaType == syntheticR8MediaType else {
            throw SyntheticV1MappingError.unsupportedResource(
                resourceID: source.id,
                reason: "task3-requires-project-owned-r8"
            )
        }
        return try normalizeSyntheticR8(source, data: data, kind: kind)
    }

    private static func normalizeSyntheticR8(
        _ source: ForeignBrushResourceDescriptor,
        data: Data,
        kind: BrushResourceKind
    ) throws -> NormalizedForeignBrushResource {
        guard source.channelModel == .grayscale,
              source.colorInterpretation == .linear
        else {
            throw SyntheticV1MappingError.unsupportedResource(
                resourceID: source.id,
                reason: "synthetic-r8-contract"
            )
        }
        let (pixelCount, overflow) = source.pixelWidth
            .multipliedReportingOverflow(by: source.pixelHeight)
        guard !overflow else {
            throw SyntheticV1MappingError.unsupportedResource(
                resourceID: source.id,
                reason: "native-byte-limit"
            )
        }
        let (targetByteCount, targetByteCountOverflow) = pixelCount
            .addingReportingOverflow(
                DeterministicGrayscaleTIFFEncoder.headerByteCount
            )
        guard !targetByteCountOverflow,
              targetByteCount
                <= BrushFormatLimits.maximumEncodedResourceBytes
        else {
            throw SyntheticV1MappingError.unsupportedResource(
                resourceID: source.id,
                reason: "native-byte-limit"
            )
        }
        guard pixelCount == data.count else {
            throw SyntheticV1MappingError.malformedResource(
                resourceID: source.id,
                reason: "synthetic-r8-byte-count"
            )
        }

        let oriented = orient(
            Array(data),
            width: source.pixelWidth,
            height: source.pixelHeight,
            orientation: source.orientation,
            inverted: source.inverted
        )
        let tiff = DeterministicGrayscaleTIFFEncoder.encode(
            pixels: oriented.pixels,
            width: oriented.width,
            height: oriented.height
        )
        guard tiff.count <= BrushFormatLimits.maximumEncodedResourceBytes else {
            throw SyntheticV1MappingError.unsupportedResource(
                resourceID: source.id,
                reason: "native-byte-limit"
            )
        }

        var operations: [BrushResourceTransformOperation] = [.transcode]
        if source.inverted {
            operations.append(.inversion)
        }
        if source.orientation != .up {
            operations.append(.orientationCorrection)
        }
        operations.sort { $0.rawValue < $1.rawValue }

        return NormalizedForeignBrushResource(
            descriptor: try BrushPackageResource(
                id: source.id,
                kind: kind,
                mediaType: "image/tiff",
                data: tiff,
                pixelWidth: oriented.width,
                pixelHeight: oriented.height
            ),
            data: tiff,
            transform: try BrushConversionResourceTransformEvidence(
                resourceIdentifier: source.id,
                sourceMediaType: source.mediaType,
                targetMediaType: "image/tiff",
                sourcePixelWidth: source.pixelWidth,
                sourcePixelHeight: source.pixelHeight,
                targetPixelWidth: oriented.width,
                targetPixelHeight: oriented.height,
                operations: operations
            )
        )
    }

    private static func orient(
        _ source: [UInt8],
        width: Int,
        height: Int,
        orientation: ForeignBrushImageOrientation,
        inverted: Bool
    ) -> (pixels: [UInt8], width: Int, height: Int) {
        let swapsDimensions: Bool = switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: true
        case .up, .down, .upMirrored, .downMirrored: false
        }
        let targetWidth = swapsDimensions ? height : width
        let targetHeight = swapsDimensions ? width : height
        var target = [UInt8](
            repeating: 0,
            count: targetWidth * targetHeight
        )

        for y in 0..<height {
            for x in 0..<width {
                let point: (x: Int, y: Int) = switch orientation {
                case .up:
                    (x, y)
                case .down:
                    (width - 1 - x, height - 1 - y)
                case .left:
                    (y, width - 1 - x)
                case .right:
                    (height - 1 - y, x)
                case .upMirrored:
                    (width - 1 - x, y)
                case .downMirrored:
                    (x, height - 1 - y)
                case .leftMirrored:
                    (y, x)
                case .rightMirrored:
                    (height - 1 - y, width - 1 - x)
                }
                let value = source[y * width + x]
                target[point.y * targetWidth + point.x] =
                    inverted ? 255 - value : value
            }
        }
        return (target, targetWidth, targetHeight)
    }
}

enum DeterministicGrayscaleTIFFEncoder {
    private static let entryCount: UInt16 = 10
    private static let imageOffset =
        UInt32(8 + 2 + Int(entryCount) * 12 + 4)
    static let headerByteCount = Int(imageOffset)

    static func encode(
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> Data {
        var data = Data()
        data.reserveCapacity(Int(imageOffset) + pixels.count)

        data.append(contentsOf: [0x49, 0x49])
        appendUInt16(42, to: &data)
        appendUInt32(8, to: &data)
        appendUInt16(entryCount, to: &data)
        appendEntry(tag: 256, type: 4, count: 1, value: UInt32(width), to: &data)
        appendEntry(tag: 257, type: 4, count: 1, value: UInt32(height), to: &data)
        appendEntry(tag: 258, type: 3, count: 1, value: 8, to: &data)
        appendEntry(tag: 259, type: 3, count: 1, value: 1, to: &data)
        appendEntry(tag: 262, type: 3, count: 1, value: 1, to: &data)
        appendEntry(tag: 273, type: 4, count: 1, value: imageOffset, to: &data)
        appendEntry(tag: 277, type: 3, count: 1, value: 1, to: &data)
        appendEntry(tag: 278, type: 4, count: 1, value: UInt32(height), to: &data)
        appendEntry(
            tag: 279,
            type: 4,
            count: 1,
            value: UInt32(pixels.count),
            to: &data
        )
        appendEntry(tag: 284, type: 3, count: 1, value: 1, to: &data)
        appendUInt32(0, to: &data)
        data.append(contentsOf: pixels)
        return data
    }

    private static func appendEntry(
        tag: UInt16,
        type: UInt16,
        count: UInt32,
        value: UInt32,
        to data: inout Data
    ) {
        appendUInt16(tag, to: &data)
        appendUInt16(type, to: &data)
        appendUInt32(count, to: &data)
        appendUInt32(value, to: &data)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
