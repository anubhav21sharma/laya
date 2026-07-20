import simd

public struct InkColor: Equatable, Sendable {
    public let red: Float
    public let green: Float
    public let blue: Float
    public let alpha: Float

    public init?(red: Float, green: Float, blue: Float, alpha: Float) {
        let values = [red, green, blue, alpha]
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { return nil }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = InkColor(
        red: 0, green: 0, blue: 0, alpha: 1
    )!

    public var simd: SIMD4<Float> {
        SIMD4(red, green, blue, alpha)
    }
}
