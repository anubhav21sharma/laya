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

public struct RasterRevisionReference: Equatable, Sendable {
    public let id: StoredRasterRevisionID
    /// Physical texture dimensions retained by this revision.
    public let pixelSize: PixelSize
    /// User-visible finite canvas dimensions. This differs from `pixelSize`
    /// only when a sparse radial sector atlas backs the document.
    public let documentPixelSize: PixelSize
    public let regions: PixelRegionSet
    public let retainedBytes: Int

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
            retainedBytes: retainedBytes
        )
    }

    public init(
        id: StoredRasterRevisionID,
        pixelSize: PixelSize,
        documentPixelSize: PixelSize,
        regions: PixelRegionSet,
        retainedBytes: Int
    ) {
        precondition(retainedBytes >= 0)
        self.id = id
        self.pixelSize = pixelSize
        self.documentPixelSize = documentPixelSize
        self.regions = regions
        self.retainedBytes = retainedBytes
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
            retainedBytes: retainedBytes
        )
    }
}
