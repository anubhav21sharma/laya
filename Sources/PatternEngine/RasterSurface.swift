public struct RasterRevision: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public func advanced() -> RasterRevision {
        RasterRevision(rawValue: rawValue &+ 1)
    }
}

public protocol RasterSurface {
    var pixelSize: PixelSize { get }
    var revision: RasterRevision { get }
}
