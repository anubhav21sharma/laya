import CShaderTypes
import PatternEngine

enum LegacyGridDabBridge {
    static func instances(
        center: WorldPoint,
        radius requestedRadius: Float,
        tileSize: PatternSize
    ) -> [PatternDabInstance] {
        let radius = TilingProjection.clampedRadius(
            requested: requestedRadius,
            tileSize: tileSize
        )
        let footprint = StampFootprint(
            brushToWorld: Affine2D(
                xAxis: SIMD2(radius, 0),
                yAxis: SIMD2(0, radius),
                translation: center.simd
            ),
            localBounds: AxisAlignedRect(
                minimum: SIMD2(-1, -1),
                maximum: SIMD2(1, 1)
            ),
            coverageSymmetry: .halfTurnInvariant
        )
        let fragments = TilingProjection.fragments(
            for: footprint,
            using: TilingStrategy(kind: .grid, tileSize: tileSize)
        )

        return fragments.compactMap { fragment in
            let canonicalCenter = fragment.canonicalFromBrush.translation
            guard hardRoundIntersectsCanonicalTarget(
                center: canonicalCenter,
                radius: radius,
                tileSize: tileSize
            ) else {
                return nil
            }
            return PatternDabInstance(
                center: canonicalCenter,
                radius: radius,
                padding: 0
            )
        }
    }

    private static func hardRoundIntersectsCanonicalTarget(
        center: SIMD2<Float>,
        radius: Float,
        tileSize: PatternSize
    ) -> Bool {
        let nearestX = min(max(center.x, 0), tileSize.width)
        let nearestY = min(max(center.y, 0), tileSize.height)
        let deltaX = center.x - nearestX
        let deltaY = center.y - nearestY
        return deltaX * deltaX + deltaY * deltaY < radius * radius
    }
}
