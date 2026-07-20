import PatternEngine

public enum EditorConfiguration {
    public static let defaultBrushDiameter: Float = 20
    public static let minimumBrushDiameter: Float = 2
    public static let maximumBrushDiameter: Float = 2_000

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
        let delta = larger ? 32 : -32
        return PixelSize(
            width: min(4_096, max(64, size.width + delta)),
            height: min(4_096, max(64, size.height + delta))
        )
    }
}
