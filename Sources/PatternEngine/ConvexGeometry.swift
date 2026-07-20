import Foundation
import simd

public struct AxisAlignedRect: Equatable, Sendable {
    public let minimum: SIMD2<Float>
    public let maximum: SIMD2<Float>

    public init(minimum: SIMD2<Float>, maximum: SIMD2<Float>) {
        precondition(
            minimum.isFinite && maximum.isFinite,
            "AxisAlignedRect bounds must be finite"
        )
        precondition(
            minimum.x <= maximum.x && minimum.y <= maximum.y,
            "AxisAlignedRect minimum must not exceed maximum"
        )
        self.minimum = minimum
        self.maximum = maximum
    }

    public var corners: [SIMD2<Float>] {
        [
            minimum,
            SIMD2(maximum.x, minimum.y),
            maximum,
            SIMD2(minimum.x, maximum.y),
        ]
    }

    public func intersects(_ other: AxisAlignedRect) -> Bool {
        guard
            maximum.x > minimum.x,
            maximum.y > minimum.y,
            other.maximum.x > other.minimum.x,
            other.maximum.y > other.minimum.y
        else {
            return false
        }
        return minimum.x < other.maximum.x
            && other.minimum.x < maximum.x
            && minimum.y < other.maximum.y
            && other.minimum.y < maximum.y
    }

    public func transformed(by affine: Affine2D) -> AxisAlignedRect {
        let transformedCorners = corners.map { affine.applying(to: $0) }
        let minimum = SIMD2(
            transformedCorners.map(\.x).min()!,
            transformedCorners.map(\.y).min()!
        )
        let maximum = SIMD2(
            transformedCorners.map(\.x).max()!,
            transformedCorners.map(\.y).max()!
        )
        return AxisAlignedRect(minimum: minimum, maximum: maximum)
    }
}

public struct HalfPlane2D: Equatable, Sendable {
    public let normal: SIMD2<Float>
    public let offset: Float

    public init(normal: SIMD2<Float>, offset: Float) {
        let length = simd_length(normal)
        precondition(
            normal.isFinite && offset.isFinite && length.isFinite && length > 0,
            "HalfPlane2D values must be finite and normal nonzero"
        )
        precondition(
            abs(length - 1) <= 0.0001,
            "HalfPlane2D normal must be normalized"
        )
        self.normal = normal
        self.offset = offset
    }

    public func contains(_ point: SIMD2<Float>, tolerance: Float) -> Bool {
        precondition(tolerance.isFinite && tolerance >= 0, "Tolerance must be finite and nonnegative")
        return simd_dot(normal, point) >= offset - tolerance
    }
}

public struct ConvexClip: Equatable, Sendable {
    public let halfPlanes: [HalfPlane2D]

    public init(halfPlanes: [HalfPlane2D]) {
        precondition(halfPlanes.count <= 4, "ConvexClip supports at most four half-planes")
        self.halfPlanes = halfPlanes
    }

    public func contains(_ point: SIMD2<Float>, tolerance: Float) -> Bool {
        precondition(tolerance.isFinite && tolerance >= 0, "Tolerance must be finite and nonnegative")
        return halfPlanes.allSatisfy { $0.contains(point, tolerance: tolerance) }
    }
}

private extension SIMD2 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}
