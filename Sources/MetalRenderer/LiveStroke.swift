import CShaderTypes
import PatternEngine

public struct IdentifiedDab {
    public let identity: UInt64
    public let instance: PatternProjectedStampInstance
}

public struct LiveStroke {
    public let capacity: Int
    public private(set) var bakedHighWater: UInt64 = 0
    public private(set) var pending: ContiguousArray<IdentifiedDab> = []
    public var emittedHighWater: UInt64 { nextIdentity }

    private var nextIdentity: UInt64 = 0
    private var dirtyRectangles: [PixelRect] = []

    public init(capacity: Int = GridCanvasContract.pendingCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
        pending.reserveCapacity(capacity)
    }

    public mutating func append(
        _ instance: PatternProjectedStampInstance
    ) throws {
        try append(instance, dirtyRect: nil)
    }

    public mutating func append(
        _ instance: PatternProjectedStampInstance,
        dirtyRect: PixelRect
    ) throws {
        try append(instance, dirtyRect: Optional(dirtyRect))
    }

    public func dirtyRegions(clippedTo pixelSize: PixelSize) -> PixelRegionSet {
        PixelRegionSet(dirtyRectangles, clippedTo: pixelSize)
    }

    private mutating func append(
        _ instance: PatternProjectedStampInstance,
        dirtyRect: PixelRect?
    ) throws {
        guard pending.count < capacity else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                capacity
            )
        }
        pending.append(IdentifiedDab(identity: nextIdentity, instance: instance))
        if let dirtyRect {
            dirtyRectangles.append(dirtyRect)
        }
        nextIdentity &+= 1
    }

    public mutating func markEncoded(throughExclusive identity: UInt64) {
        precondition(identity >= bakedHighWater && identity <= nextIdentity)
        bakedHighWater = identity
    }

    public mutating func releaseEncodedPrefix(throughExclusive identity: UInt64) {
        precondition(identity <= bakedHighWater)
        let count = pending.prefix { $0.identity < identity }.count
        pending.removeFirst(count)
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        dirtyRectangles.removeAll(keepingCapacity: true)
        bakedHighWater = 0
        nextIdentity = 0
    }
}
