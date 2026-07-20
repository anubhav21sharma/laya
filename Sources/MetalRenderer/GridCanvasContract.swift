import PatternEngine

public enum GridCanvasContract {
    public static let tileSize: Float = 256
    public static let defaultPixelSize = PixelSize(
        width: Int(tileSize),
        height: Int(tileSize)
    )
    public static let brushRadius: Float = 10
    public static let dabSpacing: Float = 2.5
    public static let zoomRange: ClosedRange<Float> = 0.25...8
    public static let paperBGRA = SIMD4<UInt8>(241, 244, 242, 255)
    public static let instanceCapacity = 4_096
    public static let pendingCapacity = instanceCapacity * 3
    public static let inFlightBufferCount = 3
}
