import Foundation
import simd

public struct CellIndex: Hashable, Sendable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

public struct TilingImage: Equatable, Sendable {
    public let cell: CellIndex
    public let ordinal: UInt8
    public let worldBounds: AxisAlignedRect
    public let worldClip: ConvexClip
    public let worldToCanonical: Affine2D
    public let operation: CompiledGroupOperation

    public init(
        cell: CellIndex,
        ordinal: UInt8,
        worldBounds: AxisAlignedRect,
        worldClip: ConvexClip? = nil,
        worldToCanonical: Affine2D
    ) {
        self.init(
            cell: cell,
            ordinal: ordinal,
            worldBounds: worldBounds,
            worldClip: worldClip,
            worldToCanonical: worldToCanonical,
            operation: .identity
        )
    }

    public init(
        cell: CellIndex,
        ordinal: UInt8,
        worldBounds: AxisAlignedRect,
        worldClip: ConvexClip? = nil,
        worldToCanonical: Affine2D,
        operation: CompiledGroupOperation
    ) {
        self.cell = cell
        self.ordinal = ordinal
        self.worldBounds = worldBounds
        self.worldClip = worldClip ?? ConvexClip(halfPlanes: [
            HalfPlane2D(
                normal: SIMD2(1, 0),
                offset: worldBounds.minimum.x
            ),
            HalfPlane2D(
                normal: SIMD2(-1, 0),
                offset: -worldBounds.maximum.x
            ),
            HalfPlane2D(
                normal: SIMD2(0, 1),
                offset: worldBounds.minimum.y
            ),
            HalfPlane2D(
                normal: SIMD2(0, -1),
                offset: -worldBounds.maximum.y
            ),
        ])
        self.worldToCanonical = worldToCanonical
        self.operation = operation
    }
}

public struct TilingStrategy: Equatable, Sendable {
    public let presetID: SymmetryPresetID
    public let tileSize: PatternSize
    public let periodicConfiguration: PeriodicSymmetryConfiguration
    public let compiledSymmetry: CompiledSymmetry

    public var kind: TilingKind { presetID }

    public init(kind: TilingKind, tileSize: PatternSize) {
        precondition(
            tileSize.width.isFinite,
            "TilingStrategy tile width must be finite"
        )
        precondition(
            tileSize.height.isFinite,
            "TilingStrategy tile height must be finite"
        )
        precondition(
            tileSize.width.rounded(.towardZero) == tileSize.width,
            "TilingStrategy tile width must be an integer"
        )
        precondition(
            tileSize.height.rounded(.towardZero) == tileSize.height,
            "TilingStrategy tile height must be an integer"
        )
        precondition(
            tileSize.width >= 64 && tileSize.width <= 4096,
            "TilingStrategy tile width must be in 64...4096"
        )
        precondition(
            tileSize.height >= 64 && tileSize.height <= 4096,
            "TilingStrategy tile height must be in 64...4096"
        )
        let canonicalRasterSize = PixelSize(
            width: Int(tileSize.width),
            height: Int(tileSize.height)
        )
        let configuration = PeriodicSymmetryConfiguration
            .defaultConfiguration(
                presetID: kind,
                canonicalRasterSize: canonicalRasterSize
            )
        do {
            compiledSymmetry = try SymmetryDescriptorCompiler.compile(
                configuration: configuration,
                canonicalRasterSize: canonicalRasterSize
            )
        } catch {
            preconditionFailure(
                "TilingStrategy validated dimensions must compile"
            )
        }
        presetID = kind
        self.tileSize = tileSize
        periodicConfiguration = compiledSymmetry.domain.periodic!.configuration
    }

    public init(
        configuration: PeriodicSymmetryConfiguration,
        canonicalRasterSize: PixelSize
    ) throws {
        let compiled = try SymmetryDescriptorCompiler.compile(
            configuration: configuration,
            canonicalRasterSize: canonicalRasterSize
        )
        presetID = configuration.presetID
        tileSize = PatternSize(
            width: Float(canonicalRasterSize.width),
            height: Float(canonicalRasterSize.height)
        )
        periodicConfiguration = compiled.domain.periodic!.configuration
        compiledSymmetry = compiled
    }

    public func cell(containing point: WorldPoint) -> CellIndex {
        RectangularSymmetryKernel(
            compiled: compiledSymmetry
        ).cell(containing: point)
    }

    public func images(
        intersecting worldBounds: AxisAlignedRect
    ) -> [TilingImage] {
        precondition(
            worldBounds.minimum.x.isFinite,
            "TilingStrategy minimum x bound must be finite"
        )
        precondition(
            worldBounds.minimum.y.isFinite,
            "TilingStrategy minimum y bound must be finite"
        )
        precondition(
            worldBounds.maximum.x.isFinite,
            "TilingStrategy maximum x bound must be finite"
        )
        precondition(
            worldBounds.maximum.y.isFinite,
            "TilingStrategy maximum y bound must be finite"
        )
        guard
            worldBounds.maximum.x > worldBounds.minimum.x,
            worldBounds.maximum.y > worldBounds.minimum.y
        else {
            return []
        }
        return RectangularSymmetryKernel(
            compiled: compiledSymmetry
        ).images(intersecting: worldBounds)
    }

    public func displayFold(_ point: WorldPoint) -> CanonicalPoint {
        RectangularSymmetryKernel(
            compiled: compiledSymmetry
        ).displayFold(point)
    }
}
