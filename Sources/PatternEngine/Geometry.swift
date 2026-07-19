import Foundation
import simd

public struct ScreenPoint: Equatable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public var simd: SIMD2<Float> { SIMD2(x, y) }
}

public struct WorldPoint: Equatable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public init(_ value: SIMD2<Float>) {
        self.init(x: value.x, y: value.y)
    }

    public var simd: SIMD2<Float> { SIMD2(x, y) }
}

public struct CanonicalPoint: Equatable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

public struct PatternSize: Equatable, Sendable {
    public var width: Float
    public var height: Float

    public init(width: Float, height: Float) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
    }

    public var simd: SIMD2<Float> { SIMD2(width, height) }
}

public struct PixelSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
    }
}
