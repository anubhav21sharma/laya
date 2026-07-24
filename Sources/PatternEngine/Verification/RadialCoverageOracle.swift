import Foundation
import simd

public enum RadialCoverageOracle {
    public static func fold(
        _ point: WorldPoint,
        configuration: FiniteSymmetryConfiguration,
        canvasSize: PixelSize
    ) -> CanonicalPoint? {
        guard contains(point.simd, canvasSize: canvasSize) else {
            return nil
        }
        switch configuration {
        case .plain:
            return CanonicalPoint(x: point.x, y: point.y)
        case let .radial(radial):
            let relative = point.simd - radial.center.simd
            let radius = simd_length(relative)
            guard radius > 0 else {
                return CanonicalPoint(x: 0, y: 0)
            }
            let isDihedral = radial.kind != .rotation
            let rays = radial.kind == .mirror ? 1 : radial.rayCount
            let sectorAngle = isDihedral
                ? Float.pi / Float(rays)
                : 2 * Float.pi / Float(rays)
            var angle = atan2(relative.y, relative.x)
                - normalize(radial.referenceAngleRadians)
            angle = positiveRemainder(angle, divisor: 2 * .pi)
            var sector = Int(floor(angle / sectorAngle))
            sector = min(
                sector,
                (isDihedral ? 2 * rays : rays) - 1
            )
            var localAngle = angle - Float(sector) * sectorAngle
            if isDihedral && !sector.isMultiple(of: 2) {
                localAngle = sectorAngle - localAngle
            }
            if localAngle == sectorAngle {
                localAngle = sectorAngle.nextDown
            }
            return CanonicalPoint(
                x: radius * cos(localAngle),
                y: radius * sin(localAngle)
            )
        }
    }

    public static func orbit(
        of point: WorldPoint,
        configuration: RadialSymmetryConfiguration
    ) -> [WorldPoint] {
        let relative = point.simd - configuration.center.simd
        let rays = configuration.kind == .mirror
            ? 1
            : configuration.rayCount
        let step = 2 * Float.pi / Float(rays)
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(
            configuration.kind == .rotation ? rays : 2 * rays
        )
        for index in 0..<rays {
            result.append(
                rotate(relative, by: Float(index) * step)
                    + configuration.center.simd
            )
        }
        if configuration.kind != .rotation {
            let reference = normalize(
                configuration.referenceAngleRadians
            )
            let reflected = reflect(relative, across: reference)
            for index in 0..<rays {
                result.append(
                    rotate(reflected, by: Float(index) * step)
                        + configuration.center.simd
                )
            }
        }
        return removingExactDuplicates(result).map(WorldPoint.init)
    }
}

private func contains(
    _ point: SIMD2<Float>,
    canvasSize: PixelSize
) -> Bool {
    point.x.isFinite && point.y.isFinite
        && point.x >= 0 && point.y >= 0
        && point.x < Float(canvasSize.width)
        && point.y < Float(canvasSize.height)
}

private func normalize(_ angle: Float) -> Float {
    precondition(angle.isFinite)
    var result = angle.truncatingRemainder(dividingBy: 2 * .pi)
    if result >= .pi {
        result -= 2 * .pi
    } else if result < -.pi {
        result += 2 * .pi
    }
    return result == 0 ? 0 : result
}

private func positiveRemainder(
    _ value: Float,
    divisor: Float
) -> Float {
    let remainder = value.truncatingRemainder(dividingBy: divisor)
    if remainder == 0 { return 0 }
    return remainder < 0 ? remainder + divisor : remainder
}

private func rotate(
    _ point: SIMD2<Float>,
    by angle: Float
) -> SIMD2<Float> {
    let cosine = cos(angle)
    let sine = sin(angle)
    return SIMD2(
        cosine * point.x - sine * point.y,
        sine * point.x + cosine * point.y
    )
}

private func reflect(
    _ point: SIMD2<Float>,
    across angle: Float
) -> SIMD2<Float> {
    let cosine = cos(2 * angle)
    let sine = sin(2 * angle)
    return SIMD2(
        cosine * point.x + sine * point.y,
        sine * point.x - cosine * point.y
    )
}

private func removingExactDuplicates(
    _ points: [SIMD2<Float>]
) -> [SIMD2<Float>] {
    var result: [SIMD2<Float>] = []
    for point in points where !result.contains(point) {
        result.append(point)
    }
    return result
}
