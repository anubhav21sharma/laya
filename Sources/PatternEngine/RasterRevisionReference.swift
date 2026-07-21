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
