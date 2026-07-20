public struct StoredRasterRevisionID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct RasterRevisionReference: Equatable, Sendable {
    public let id: StoredRasterRevisionID
    public let pixelSize: PixelSize
    public let regions: PixelRegionSet
    public let retainedBytes: Int

    public init(
        id: StoredRasterRevisionID,
        pixelSize: PixelSize,
        regions: PixelRegionSet,
        retainedBytes: Int
    ) {
        precondition(retainedBytes >= 0)
        self.id = id
        self.pixelSize = pixelSize
        self.regions = regions
        self.retainedBytes = retainedBytes
    }
}
