import Foundation
import simd

public struct Affine2D: Equatable, Sendable {
    public let xAxis: SIMD2<Float>
    public let yAxis: SIMD2<Float>
    public let translation: SIMD2<Float>

    public init(
        xAxis: SIMD2<Float>,
        yAxis: SIMD2<Float>,
        translation: SIMD2<Float>
    ) {
        precondition(
            xAxis.isFinite && yAxis.isFinite && translation.isFinite,
            "Affine2D components must be finite"
        )
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.translation = translation
    }

    public static let identity = Affine2D(
        xAxis: SIMD2(1, 0),
        yAxis: SIMD2(0, 1),
        translation: SIMD2(0, 0)
    )

    public func applying(to point: SIMD2<Float>) -> SIMD2<Float> {
        xAxis * point.x + yAxis * point.y + translation
    }

    public func concatenating(_ next: Affine2D) -> Affine2D {
        Affine2D(
            xAxis: next.xAxis * xAxis.x + next.yAxis * xAxis.y,
            yAxis: next.xAxis * yAxis.x + next.yAxis * yAxis.y,
            translation: next.applying(to: translation)
        )
    }

    public func inverted() -> Affine2D {
        let determinant = xAxis.x * yAxis.y - xAxis.y * yAxis.x
        precondition(
            determinant.isFinite && abs(determinant) >= Float.ulpOfOne,
            "Affine2D must be nonsingular"
        )

        let inverseXAxis = SIMD2(yAxis.y, -xAxis.y) / determinant
        let inverseYAxis = SIMD2(-yAxis.x, xAxis.x) / determinant
        return Affine2D(
            xAxis: inverseXAxis,
            yAxis: inverseYAxis,
            translation: -(inverseXAxis * translation.x + inverseYAxis * translation.y)
        )
    }
}

private extension SIMD2 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}
