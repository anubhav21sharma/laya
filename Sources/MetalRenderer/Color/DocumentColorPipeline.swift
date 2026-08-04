import Metal
import PatternEngine
import simd

public enum DocumentColorBlendMode: Equatable, Sendable {
    case normal
    case multiply
    case screen
}

public enum DocumentColorPipeline {
    public static let workingPixelFormat: MTLPixelFormat = .rgba16Float
    public static let displayPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb

    /// Non-production packing boundary for the Task 6 atomic surface switch.
    /// Its encoded input type makes a second decode or premultiplication
    /// impossible without explicitly leaving the typed route.
    public static func packShaderColor(
        _ color: EncodedSRGBColor
    ) -> SIMD4<Float> {
        color.linearPremultiplied().simd
    }

    static func referenceSourceOver(
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
}
