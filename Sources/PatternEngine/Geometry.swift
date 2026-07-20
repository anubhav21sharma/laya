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

public struct DrawableCoordinateTransform: Equatable, Sendable {
    public let viewOrigin: ScreenPoint
    private let scale: SIMD2<Float>

    public init?(
        viewOrigin: ScreenPoint,
        viewSize: SIMD2<Float>,
        drawableSize: SIMD2<Float>
    ) {
        guard
            viewOrigin.x.isFinite,
            viewOrigin.y.isFinite,
            viewSize.x.isFinite,
            viewSize.y.isFinite,
            drawableSize.x.isFinite,
            drawableSize.y.isFinite,
            viewSize.x > 0,
            viewSize.y > 0,
            drawableSize.x > 0,
            drawableSize.y > 0
        else {
            return nil
        }

        self.viewOrigin = viewOrigin
        scale = drawableSize / viewSize
    }

    public func map(_ point: ScreenPoint) -> ScreenPoint {
        ScreenPoint(
            x: (point.x - viewOrigin.x) * scale.x,
            y: (point.y - viewOrigin.y) * scale.y
        )
    }

    public func mapDelta(_ delta: SIMD2<Float>) -> SIMD2<Float> {
        delta * scale
    }
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

public struct CanonicalPoint: Hashable, Sendable {
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
