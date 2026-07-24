import PatternEngine

public struct TilingCanvasConfiguration: Equatable, Sendable {
    public let pixelSize: PixelSize
    public let tiling: TilingKind
    public let documentConfiguration: SymmetryDocumentConfiguration

    public var periodicConfiguration: PeriodicSymmetryConfiguration {
        guard case let .periodic(configuration) = documentConfiguration else {
            preconditionFailure(
                "Finite canvas configuration has no periodic configuration"
            )
        }
        return configuration
    }

    public var finiteConfiguration: FiniteSymmetryConfiguration? {
        guard case let .finite(configuration) = documentConfiguration else {
            return nil
        }
        return configuration
    }

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
        try Self.validate(
            pixelSize: pixelSize,
            documentConfiguration: .periodic(periodicConfiguration)
        )
        self.pixelSize = pixelSize
        tiling = periodicConfiguration.presetID
        documentConfiguration = .periodic(periodicConfiguration)
    }

    public init(
        pixelSize: PixelSize,
        finiteConfiguration: FiniteSymmetryConfiguration
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
        try Self.validate(
            pixelSize: pixelSize,
            documentConfiguration: .finite(finiteConfiguration)
        )
        self.pixelSize = pixelSize
        documentConfiguration = .finite(finiteConfiguration)
        switch finiteConfiguration {
        case .plain:
            tiling = .plainCanvas
        case let .radial(radial):
            switch radial.kind {
            case .mirror:
                tiling = .radialMirror
            case .rotation:
                tiling = .radialRotation
            case .mandala:
                tiling = .radialMandala
            }
        }
    }

    public init(
        pixelSize: PixelSize,
        documentConfiguration: SymmetryDocumentConfiguration
    ) throws {
        switch documentConfiguration {
        case let .periodic(configuration):
            try self.init(
                pixelSize: pixelSize,
                periodicConfiguration: configuration
            )
        case let .finite(configuration):
            try self.init(
                pixelSize: pixelSize,
                finiteConfiguration: configuration
            )
        }
    }

    private static func validate(
        pixelSize: PixelSize,
        documentConfiguration: SymmetryDocumentConfiguration
    ) throws {
        do {
            _ = try SymmetryDescriptorCompiler.compile(
                documentConfiguration: documentConfiguration,
                canvasSize: pixelSize
            )
        } catch {
            throw MetalRendererError.invalidSymmetryConfiguration(
                error.localizedDescription
            )
        }
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
