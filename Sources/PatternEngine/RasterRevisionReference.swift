import Foundation

public struct StoredRasterRevisionID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    private let namespace: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
        namespace = 0
    }

    package init(rawValue: UInt64, namespace: UInt64) {
        precondition(namespace != 0)
        self.rawValue = rawValue
        self.namespace = namespace
    }

    package func belongs(to namespace: UInt64) -> Bool {
        self.namespace == namespace
    }

    public static func == (
        lhs: StoredRasterRevisionID,
        rhs: StoredRasterRevisionID
    ) -> Bool {
        lhs.namespace == rhs.namespace && lhs.rawValue == rhs.rawValue
    }

    public static func != (
        lhs: StoredRasterRevisionID,
        rhs: StoredRasterRevisionID
    ) -> Bool {
        !(lhs == rhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(namespace)
        hasher.combine(rawValue)
    }
}

public struct RasterRevisionTileCoordinate:
    Hashable, Comparable, Sendable
{
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        precondition(x >= 0 && y >= 0)
        self.x = x
        self.y = y
    }

    public static func < (
        lhs: RasterRevisionTileCoordinate,
        rhs: RasterRevisionTileCoordinate
    ) -> Bool {
        (lhs.y, lhs.x) < (rhs.y, rhs.x)
    }
}

public enum RasterRevisionStorage: Equatable, Sendable {
    /// Compatibility storage used by the pre-Stage-D full-surface renderer.
    case fullSurfaceBGRA8
    /// Sparse canonical paint storage. Coordinates must be unique and sorted.
    case tiledRGBA16Float(
        layerID: UUID,
        generation: UInt64,
        tileCoordinates: [RasterRevisionTileCoordinate]
    )

    public var layerID: UUID? {
        guard case let .tiledRGBA16Float(layerID, _, _) = self else {
            return nil
        }
        return layerID
    }

    public var generation: UInt64? {
        guard case let .tiledRGBA16Float(_, generation, _) = self else {
            return nil
        }
        return generation
    }

    public var tileCoordinates: [RasterRevisionTileCoordinate] {
        guard case let .tiledRGBA16Float(_, _, coordinates) = self else {
            return []
        }
        return coordinates
    }
}

public struct RasterRevisionReference: Equatable, Sendable {
    public let id: StoredRasterRevisionID
    /// Physical texture dimensions retained by this revision.
    public let pixelSize: PixelSize
    /// User-visible finite canvas dimensions. This differs from `pixelSize`
    /// only when a sparse radial sector atlas backs the document.
    public let documentPixelSize: PixelSize
    public let regions: PixelRegionSet
    public let retainedBytes: Int
    public let storage: RasterRevisionStorage

    public var layerID: UUID? { storage.layerID }
    public var generation: UInt64? { storage.generation }
    public var tileCoordinates: [RasterRevisionTileCoordinate] {
        storage.tileCoordinates
    }

    public init(
        id: StoredRasterRevisionID,
        pixelSize: PixelSize,
        regions: PixelRegionSet,
        retainedBytes: Int
    ) {
        self.init(
            id: id,
            pixelSize: pixelSize,
            documentPixelSize: pixelSize,
            regions: regions,
            retainedBytes: retainedBytes,
            storage: .fullSurfaceBGRA8
        )
    }

    public init(
        id: StoredRasterRevisionID,
        pixelSize: PixelSize,
        documentPixelSize: PixelSize,
        regions: PixelRegionSet,
        retainedBytes: Int,
        storage: RasterRevisionStorage = .fullSurfaceBGRA8
    ) {
        precondition(retainedBytes >= 0)
        if case let .tiledRGBA16Float(_, _, coordinates) = storage {
            precondition(coordinates == Array(Set(coordinates)).sorted())
        }
        self.id = id
        self.pixelSize = pixelSize
        self.documentPixelSize = documentPixelSize
        self.regions = regions
        self.retainedBytes = retainedBytes
        self.storage = storage
    }

    public init(
        id: StoredRasterRevisionID,
        pixelSize: PixelSize,
        documentPixelSize: PixelSize?,
        regions: PixelRegionSet,
        retainedBytes: Int
    ) {
        self.init(
            id: id,
            pixelSize: pixelSize,
            documentPixelSize: documentPixelSize ?? pixelSize,
            regions: regions,
            retainedBytes: retainedBytes,
            storage: .fullSurfaceBGRA8
        )
    }
}
