import Foundation

public struct CanonicalDabPlacement: Equatable, Sendable {
    public let center: CanonicalPoint
    public let radius: Float

    public init(center: CanonicalPoint, radius: Float) {
        self.center = center
        self.radius = radius
    }
}

public enum GridProjection {
    public static func fold(
        _ point: WorldPoint,
        tileSize: PatternSize
    ) -> CanonicalPoint {
        CanonicalPoint(
            x: point.x - floor(point.x / tileSize.width) * tileSize.width,
            y: point.y - floor(point.y / tileSize.height) * tileSize.height
        )
    }

    public static func placements(
        center: WorldPoint,
        radius: Float,
        tileSize: PatternSize
    ) -> [CanonicalDabPlacement] {
        precondition(radius > 0)
        let folded = fold(center, tileSize: tileSize)
        let xOffsets = intersectingOffsets(
            center: folded.x,
            radius: radius,
            extent: tileSize.width
        )
        let yOffsets = intersectingOffsets(
            center: folded.y,
            radius: radius,
            extent: tileSize.height
        )
        var result: [CanonicalDabPlacement] = []
        result.reserveCapacity(xOffsets.count * yOffsets.count)
        for y in yOffsets {
            for x in xOffsets {
                result.append(
                    CanonicalDabPlacement(
                        center: CanonicalPoint(x: folded.x + x, y: folded.y + y),
                        radius: radius
                    )
                )
            }
        }
        result.sort {
            let lhsDistance = $0.center.x * $0.center.x + $0.center.y * $0.center.y
            let rhsDistance = $1.center.x * $1.center.x + $1.center.y * $1.center.y
            return lhsDistance < rhsDistance
        }
        return result
    }

    private static func intersectingOffsets(
        center: Float,
        radius: Float,
        extent: Float
    ) -> [Float] {
        let minimum = Int(floor((-radius - center) / extent))
        let maximum = Int(ceil((extent + radius - center) / extent))
        return (minimum...maximum).compactMap { lattice in
            let offset = Float(lattice) * extent
            let translated = center + offset
            return translated + radius > 0 && translated - radius < extent
                ? offset
                : nil
        }
    }
}
