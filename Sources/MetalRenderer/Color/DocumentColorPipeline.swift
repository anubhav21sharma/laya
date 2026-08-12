import Metal
import PatternEngine
import simd

public enum DocumentColorBlendMode: Equatable, Sendable {
    case normal
    case multiply
    case screen
}

@frozen
public struct EncodedPremultipliedBGRA8: Equatable, Sendable {
    public let blue: UInt8
    public let green: UInt8
    public let red: UInt8
    public let alpha: UInt8

    public init(blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        self.blue = blue
        self.green = green
        self.red = red
        self.alpha = alpha
    }
}

public enum DocumentColorInterchangeError: Error, Equatable, Sendable {
    case invalidDimensions(width: Int, height: Int)
    case invalidRowStride(minimum: Int, actual: Int)
    case invalidEncodedByteCount(expected: Int, actual: Int)
    case invalidLinearPixelCount(expected: Int, actual: Int)
    case byteCountOverflow
}

public enum DocumentColorPipeline {
    public static let workingPixelFormat: MTLPixelFormat = .rgba16Float
    public static let displayPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    public static let renderSampleCount = 1
    public static let interchangePixelFormat: MTLPixelFormat = .bgra8Unorm

    /// Sole production paint-ingress boundary. Its encoded input type makes a
    /// second decode or premultiplication impossible without explicitly
    /// leaving the typed route.
    public static func packShaderColor(
        _ color: EncodedSRGBColor
    ) -> SIMD4<Float> {
        color.linearPremultiplied().simd
    }

    /// Imports a single encoded-premultiplied BGRA8 interchange pixel into the
    /// document's linear-premultiplied working color space.
    public static func importEncodedPremultipliedBGRA8(
        _ pixel: EncodedPremultipliedBGRA8
    ) -> LinearPremultipliedColor {
        guard pixel.alpha > 0 else { return transparent }
        let inverseAlpha = 1 / Float(pixel.alpha)
        let straight = EncodedSRGBColor(
            red: min(1, Float(pixel.red) * inverseAlpha),
            green: min(1, Float(pixel.green) * inverseAlpha),
            blue: min(1, Float(pixel.blue) * inverseAlpha),
            alpha: Float(pixel.alpha) / 255
        )!
        return straight.linearPremultiplied()
    }

    /// Exports a single document color through the inverse interchange path:
    /// linear unpremultiply, sRGB encode, then encoded-space premultiply.
    public static func exportEncodedPremultipliedBGRA8(
        _ color: LinearPremultipliedColor
    ) -> EncodedPremultipliedBGRA8 {
        guard color.alpha > 0 else {
            return EncodedPremultipliedBGRA8(
                blue: 0,
                green: 0,
                red: 0,
                alpha: 0
            )
        }
        let encoded = color.encodedSRGB()
        return EncodedPremultipliedBGRA8(
            blue: byte(encoded.blue * encoded.alpha),
            green: byte(encoded.green * encoded.alpha),
            red: byte(encoded.red * encoded.alpha),
            alpha: byte(encoded.alpha)
        )
    }

    public static func importEncodedPremultipliedBGRA8Row(
        _ bytes: [UInt8],
        pixelCount: Int
    ) throws -> [LinearPremultipliedColor] {
        try importEncodedPremultipliedBGRA8Buffer(
            bytes,
            width: pixelCount,
            height: 1,
            bytesPerRow: checkedPackedByteCount(width: pixelCount)
        )
    }

    public static func exportEncodedPremultipliedBGRA8Row(
        _ colors: [LinearPremultipliedColor],
        pixelCount: Int
    ) throws -> [UInt8] {
        try exportEncodedPremultipliedBGRA8Buffer(
            colors,
            width: pixelCount,
            height: 1,
            bytesPerRow: checkedPackedByteCount(width: pixelCount)
        )
    }

    public static func importEncodedPremultipliedBGRA8Buffer(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws -> [LinearPremultipliedColor] {
        let geometry = try validateBufferGeometry(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
        guard bytes.count == geometry.byteCount else {
            throw DocumentColorInterchangeError.invalidEncodedByteCount(
                expected: geometry.byteCount,
                actual: bytes.count
            )
        }

        var result: [LinearPremultipliedColor] = []
        result.reserveCapacity(geometry.pixelCount)
        for row in 0..<height {
            let rowStart = row * bytesPerRow
            for column in 0..<width {
                let offset = rowStart + column * 4
                result.append(importEncodedPremultipliedBGRA8(
                    EncodedPremultipliedBGRA8(
                        blue: bytes[offset],
                        green: bytes[offset + 1],
                        red: bytes[offset + 2],
                        alpha: bytes[offset + 3]
                    )
                ))
            }
        }
        return result
    }

    public static func exportEncodedPremultipliedBGRA8Buffer(
        _ colors: [LinearPremultipliedColor],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws -> [UInt8] {
        let geometry = try validateBufferGeometry(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
        guard colors.count == geometry.pixelCount else {
            throw DocumentColorInterchangeError.invalidLinearPixelCount(
                expected: geometry.pixelCount,
                actual: colors.count
            )
        }

        var result = [UInt8](repeating: 0, count: geometry.byteCount)
        for row in 0..<height {
            let rowStart = row * bytesPerRow
            let colorStart = row * width
            for column in 0..<width {
                let pixel = exportEncodedPremultipliedBGRA8(
                    colors[colorStart + column]
                )
                let offset = rowStart + column * 4
                result[offset] = pixel.blue
                result[offset + 1] = pixel.green
                result[offset + 2] = pixel.red
                result[offset + 3] = pixel.alpha
            }
        }
        return result
    }

    package static func referenceSourceOver(
        source: LinearPremultipliedColor,
        destination: LinearPremultipliedColor
    ) -> LinearPremultipliedColor {
        let retainedDestination = 1 - source.alpha
        return makePremultiplied(
            red: source.red + destination.red * retainedDestination,
            green: source.green + destination.green * retainedDestination,
            blue: source.blue + destination.blue * retainedDestination,
            alpha: source.alpha
                + destination.alpha * retainedDestination
        )
    }

    static func referenceDestinationOut(
        destination: LinearPremultipliedColor,
        eraseAlpha: Float
    ) -> LinearPremultipliedColor {
        let boundedErase = eraseAlpha.isFinite
            ? min(1, max(0, eraseAlpha))
            : 0
        let retained = 1 - boundedErase
        return makePremultiplied(
            red: destination.red * retained,
            green: destination.green * retained,
            blue: destination.blue * retained,
            alpha: destination.alpha * retained
        )
    }

    static func referenceBuildup(
        stamp: LinearPremultipliedColor,
        count: Int
    ) -> LinearPremultipliedColor {
        guard count > 0 else { return transparent }
        var accumulated = transparent
        for _ in 0..<count {
            accumulated = referenceSourceOver(
                source: stamp,
                destination: accumulated
            )
        }
        return accumulated
    }

    static func referenceBlend(
        source: LinearPremultipliedColor,
        destination: LinearPremultipliedColor,
        mode: DocumentColorBlendMode
    ) -> LinearPremultipliedColor {
        guard mode != .normal else {
            return referenceSourceOver(
                source: source,
                destination: destination
            )
        }

        let sourceStraight = source.unpremultiplied()
        let destinationStraight = destination.unpremultiplied()
        let sourceAlpha = source.alpha
        let destinationAlpha = destination.alpha
        let outputAlpha = sourceAlpha
            + destinationAlpha * (1 - sourceAlpha)
        let sourceChannels = sourceStraight.simd
        let destinationChannels = destinationStraight.simd
        var output = SIMD4<Float>(repeating: 0)
        for channel in 0..<3 {
            let blended: Float
            switch mode {
            case .normal:
                blended = sourceChannels[channel]
            case .multiply:
                blended = sourceChannels[channel]
                    * destinationChannels[channel]
            case .screen:
                blended = sourceChannels[channel]
                    + destinationChannels[channel]
                    - sourceChannels[channel] * destinationChannels[channel]
            }
            output[channel] =
                sourceChannels[channel] * sourceAlpha * (1 - destinationAlpha)
                + destinationChannels[channel] * destinationAlpha
                    * (1 - sourceAlpha)
                + blended * sourceAlpha * destinationAlpha
        }
        return makePremultiplied(
            red: output.x,
            green: output.y,
            blue: output.z,
            alpha: outputAlpha
        )
    }

    private static let transparent = LinearPremultipliedColor(
        red: 0,
        green: 0,
        blue: 0,
        alpha: 0
    )!

    private static func makePremultiplied(
        red: Float,
        green: Float,
        blue: Float,
        alpha: Float
    ) -> LinearPremultipliedColor {
        let boundedAlpha = min(1, max(0, alpha))
        return LinearPremultipliedColor(
            red: min(boundedAlpha, max(0, red)),
            green: min(boundedAlpha, max(0, green)),
            blue: min(boundedAlpha, max(0, blue)),
            alpha: boundedAlpha
        )!
    }

    private static func byte(_ unit: Float) -> UInt8 {
        UInt8((min(1, max(0, unit)) * 255).rounded())
    }

    private static func checkedPackedByteCount(width: Int) throws -> Int {
        guard width > 0 else {
            throw DocumentColorInterchangeError.invalidDimensions(
                width: width,
                height: 1
            )
        }
        let (count, overflow) = width.multipliedReportingOverflow(by: 4)
        guard !overflow else {
            throw DocumentColorInterchangeError.byteCountOverflow
        }
        return count
    }

    private static func validateBufferGeometry(
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws -> (pixelCount: Int, byteCount: Int) {
        guard width > 0, height > 0 else {
            throw DocumentColorInterchangeError.invalidDimensions(
                width: width,
                height: height
            )
        }
        let packedByteCount = try checkedPackedByteCount(width: width)
        guard bytesPerRow >= packedByteCount else {
            throw DocumentColorInterchangeError.invalidRowStride(
                minimum: packedByteCount,
                actual: bytesPerRow
            )
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(
            by: height
        )
        let (byteCount, byteOverflow) = bytesPerRow.multipliedReportingOverflow(
            by: height
        )
        guard !pixelOverflow, !byteOverflow else {
            throw DocumentColorInterchangeError.byteCountOverflow
        }
        return (pixelCount, byteCount)
    }
}
