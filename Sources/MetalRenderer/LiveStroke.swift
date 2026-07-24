import CShaderTypes
import PatternEngine

public struct IdentifiedDab {
    public let identity: UInt64
    public let renderEpoch: UInt64
    public let instance: PatternProjectedStampInstance
    public let radialPage: RadialPageCoordinate?
}

public struct LiveStroke {
    // More than this many still-disjoint dirty rectangles would make active-
    // stroke metadata grow with stroke length. Crossing the limit discards the
    // fragments and conservatively captures the full canonical tile instead.
    static let maximumRetainedDirtyRectangleCount = 256

    public let capacity: Int
    public private(set) var bakedHighWater: UInt64 = 0
    public private(set) var renderEpoch: UInt64 = 0
    public private(set) var pending: ContiguousArray<IdentifiedDab> = []
    public var emittedHighWater: UInt64 { nextIdentity }

    private var nextIdentity: UInt64 = 0
    private var dirtyRectangles: [PixelRect] = []
    private var usesFullTileDirtyRegion = false

    var retainedDirtyRectangleCount: Int {
        dirtyRectangles.count + (usesFullTileDirtyRegion ? 1 : 0)
    }

    public init(capacity: Int = GridCanvasContract.pendingCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
        pending.reserveCapacity(capacity)
        dirtyRectangles.reserveCapacity(
            min(capacity, Self.maximumRetainedDirtyRectangleCount)
        )
    }

    public mutating func append(
        _ instance: PatternProjectedStampInstance
    ) throws {
        try append(instance, dirtyRect: nil)
    }

    public mutating func append(
        _ instance: PatternProjectedStampInstance,
        dirtyRect: PixelRect,
        radialPage: RadialPageCoordinate? = nil
    ) throws {
        try append(
            instance,
            dirtyRect: Optional(dirtyRect),
            radialPage: radialPage
        )
    }

    public func dirtyRegions(clippedTo pixelSize: PixelSize) -> PixelRegionSet {
        if usesFullTileDirtyRegion {
            return PixelRegionSet(
                [
                    PixelRect(
                        minX: 0,
                        minY: 0,
                        maxX: pixelSize.width,
                        maxY: pixelSize.height
                    )!,
                ],
                clippedTo: pixelSize
            )
        }
        return PixelRegionSet(dirtyRectangles, clippedTo: pixelSize)
    }

    private mutating func append(
        _ instance: PatternProjectedStampInstance,
        dirtyRect: PixelRect?,
        radialPage: RadialPageCoordinate? = nil
    ) throws {
        guard pending.count < capacity else {
            throw MetalRendererError.projectedInstanceCapacityExceeded(
                capacity
            )
        }
        pending.append(
            IdentifiedDab(
                identity: nextIdentity,
                renderEpoch: renderEpoch,
                instance: instance,
                radialPage: radialPage
            )
        )
        if let dirtyRect {
            accumulateDirtyRectangle(dirtyRect)
        }
        nextIdentity &+= 1
    }

    private mutating func accumulateDirtyRectangle(_ dirtyRect: PixelRect) {
        guard !usesFullTileDirtyRegion else { return }

        var accumulated = dirtyRect
        var didMerge = true
        while didMerge {
            didMerge = false
            for index in dirtyRectangles.indices.reversed()
            where accumulated.touchesOrOverlaps(dirtyRectangles[index]) {
                accumulated = accumulated.union(
                    dirtyRectangles.remove(at: index)
                )
                didMerge = true
            }
        }
        if dirtyRectangles.count == Self.maximumRetainedDirtyRectangleCount {
            dirtyRectangles.removeAll(keepingCapacity: true)
            usesFullTileDirtyRegion = true
        } else {
            dirtyRectangles.append(accumulated)
        }
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
        usesFullTileDirtyRegion = false
        bakedHighWater = 0
        nextIdentity = 0
        renderEpoch = 0
    }

    /// Starts a replacement epoch without reusing an active-stroke identity.
    public mutating func beginReplacementEpoch(_ epoch: UInt64) {
        precondition(epoch > renderEpoch, "Replacement epochs must advance")
        pending.removeAll(keepingCapacity: true)
        dirtyRectangles.removeAll(keepingCapacity: true)
        usesFullTileDirtyRegion = false
        bakedHighWater = nextIdentity
        renderEpoch = epoch
    }
}
