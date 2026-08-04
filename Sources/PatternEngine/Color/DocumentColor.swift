import Foundation
import simd

/// Bounded, encoded IEC 61966-2-1 sRGB supplied by document and UI boundaries.
public struct EncodedSRGBColor: Equatable, Sendable {
    public let red: Float
    public let green: Float
    public let blue: Float
    public let alpha: Float

    public init?(red: Float, green: Float, blue: Float, alpha: Float) {
        guard Self.isUnit(red),
              Self.isUnit(green),
              Self.isUnit(blue),
              Self.isUnit(alpha)
        else {
            return nil
        }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(_ inkColor: InkColor) {
        self.init(
            red: inkColor.red,
            green: inkColor.green,
            blue: inkColor.blue,
            alpha: inkColor.alpha
        )!
    }

    public var simd: SIMD4<Float> {
        SIMD4(red, green, blue, alpha)
    }

    /// Converts encoded RGB to linear light, then premultiplies RGB by alpha.
    /// Alpha is coverage and is deliberately never passed through the transfer
    /// function.
    public func linearPremultiplied() -> LinearPremultipliedColor {
        LinearPremultipliedColor(
            red: Self.decode(red) * alpha,
            green: Self.decode(green) * alpha,
            blue: Self.decode(blue) * alpha,
            alpha: alpha
        )!
    }

    public var inkColor: InkColor {
        InkColor(red: red, green: green, blue: blue, alpha: alpha)!
    }

    private static func decode(_ encoded: Float) -> Float {
        if encoded <= 0.04045 {
            return encoded / 12.92
        }
        return pow((encoded + 0.055) / 1.055, 2.4)
    }

    private static func isUnit(_ value: Float) -> Bool {
        value.isFinite && (0...1).contains(value)
    }
}

/// Bounded linear-light RGB with independent, unpremultiplied alpha.
public struct LinearUnpremultipliedColor: Equatable, Sendable {
    public let red: Float
    public let green: Float
    public let blue: Float
    public let alpha: Float

    public init?(red: Float, green: Float, blue: Float, alpha: Float) {
        guard Self.isUnit(red),
              Self.isUnit(green),
              Self.isUnit(blue),
              Self.isUnit(alpha)
        else {
            return nil
        }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var simd: SIMD4<Float> {
        SIMD4(red, green, blue, alpha)
    }

    public func premultiplied() -> LinearPremultipliedColor {
        LinearPremultipliedColor(
            red: red * alpha,
            green: green * alpha,
            blue: blue * alpha,
            alpha: alpha
        )!
    }

    private static func isUnit(_ value: Float) -> Bool {
        value.isFinite && (0...1).contains(value)
    }
}

/// Bounded linear-light RGB whose channels are constrained by premultiplied
/// alpha, so invalid mixed color semantics cannot enter paint arithmetic.
public struct LinearPremultipliedColor: Equatable, Sendable {
    public let red: Float
    public let green: Float
    public let blue: Float
    public let alpha: Float

    public init?(red: Float, green: Float, blue: Float, alpha: Float) {
        guard Self.isUnit(alpha),
              Self.isPremultiplied(red, alpha: alpha),
              Self.isPremultiplied(green, alpha: alpha),
              Self.isPremultiplied(blue, alpha: alpha)
        else {
            return nil
        }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var simd: SIMD4<Float> {
        SIMD4(red, green, blue, alpha)
    }

    public func unpremultiplied() -> LinearUnpremultipliedColor {
        guard alpha > 0 else {
            return LinearUnpremultipliedColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 0
            )!
        }
        return LinearUnpremultipliedColor(
            red: min(1, red / alpha),
            green: min(1, green / alpha),
            blue: min(1, blue / alpha),
            alpha: alpha
        )!
    }

    /// Unpremultiplies linear RGB before applying the sRGB transfer function.
    /// Transparent pixels have no recoverable chroma and encode as clear black.
    public func encodedSRGB() -> EncodedSRGBColor {
        let linear = unpremultiplied()
        return EncodedSRGBColor(
            red: Self.encode(linear.red),
            green: Self.encode(linear.green),
            blue: Self.encode(linear.blue),
            alpha: alpha
        )!
    }

    private static func encode(_ linear: Float) -> Float {
        if linear <= 0.0031308 {
            return linear * 12.92
        }
        return 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    private static func isUnit(_ value: Float) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static func isPremultiplied(
        _ value: Float,
        alpha: Float
    ) -> Bool {
        value.isFinite && value >= 0 && value <= alpha
    }
}
