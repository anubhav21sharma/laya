import PatternEngine

public enum EditorConfiguration {
    public static let defaultBrushDiameter: Float = 20
    public static let minimumBrushDiameter: Float = 2
    public static let maximumBrushDiameter: Float = 2_000
    public static let minimumTileDimension = 64
    public static let maximumTileDimension = 4_096

    public static func brushMaximum(for size: PixelSize) -> Float {
        min(maximumBrushDiameter, 8 * Float(min(size.width, size.height)))
    }

    public static func stepBrush(
        _ value: Float,
        larger: Bool,
        pixelSize: PixelSize
    ) -> Float {
        let proposed = (larger ? value * 1.25 : value / 1.25).rounded()
        return min(
            brushMaximum(for: pixelSize),
            max(minimumBrushDiameter, proposed)
        )
    }

    public static func stepTile(
        _ size: PixelSize,
        larger: Bool
    ) -> PixelSize {
        return PixelSize(
            width: stepTileDimension(size.width, larger: larger),
            height: stepTileDimension(size.height, larger: larger)
        )
    }

    public static func isValidTileSize(_ size: PixelSize) -> Bool {
        let range = minimumTileDimension...maximumTileDimension
        return range.contains(size.width) && range.contains(size.height)
    }

    private static func stepTileDimension(
        _ value: Int,
        larger: Bool
    ) -> Int {
        if larger {
            guard value < maximumTileDimension else {
                return maximumTileDimension
            }
            return min(
                maximumTileDimension,
                max(minimumTileDimension, value + 32)
            )
        }

        guard value > minimumTileDimension else {
            return minimumTileDimension
        }
        return max(
            minimumTileDimension,
            min(maximumTileDimension, value - 32)
        )
    }
}
