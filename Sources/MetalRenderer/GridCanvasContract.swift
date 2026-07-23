import PatternEngine

public struct TilingCanvasConfiguration: Equatable, Sendable {
    public let pixelSize: PixelSize
    public let tiling: TilingKind
    public let periodicConfiguration: PeriodicSymmetryConfiguration

    public init(pixelSize: PixelSize, tiling: TilingKind) throws {
        try self.init(
            pixelSize: pixelSize,
            periodicConfiguration: .defaultConfiguration(
                presetID: tiling,
                canonicalRasterSize: pixelSize
            )
        )
    }

    public init(
        pixelSize: PixelSize,
        periodicConfiguration: PeriodicSymmetryConfiguration
    ) throws {
        guard
            (64...4_096).contains(pixelSize.width),
            (64...4_096).contains(pixelSize.height)
        else {
            throw MetalRendererError.invalidTileDimensions(
                width: pixelSize.width,
                height: pixelSize.height
            )
        }
        do {
            _ = try SymmetryDescriptorCompiler.compile(
                configuration: periodicConfiguration,
                canonicalRasterSize: pixelSize
            )
        } catch {
            throw MetalRendererError.invalidPeriodicConfiguration(
                error.localizedDescription
            )
        }
        self.pixelSize = pixelSize
        tiling = periodicConfiguration.presetID
        self.periodicConfiguration = periodicConfiguration
    }
}

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
