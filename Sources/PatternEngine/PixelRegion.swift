public struct PixelRect: Hashable, Sendable {
    public let minX: Int
    public let minY: Int
    public let maxX: Int
    public let maxY: Int

    public init?(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        guard maxX > minX, maxY > minY else { return nil }
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: Int { maxX - minX }
    public var height: Int { maxY - minY }

    public func clipped(to size: PixelSize) -> PixelRect? {
        PixelRect(
            minX: max(0, minX),
            minY: max(0, minY),
            maxX: min(size.width, maxX),
            maxY: min(size.height, maxY)
        )
    }

    public func touchesOrOverlaps(_ other: PixelRect) -> Bool {
        minX <= other.maxX && other.minX <= maxX
            && minY <= other.maxY && other.minY <= maxY
    }

    public func union(_ other: PixelRect) -> PixelRect {
        PixelRect(
            minX: min(minX, other.minX),
            minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX),
            maxY: max(maxY, other.maxY)
        )!
    }
}

public struct PixelRegionSet: Equatable, Sendable {
    public let rectangles: [PixelRect]

    public init(_ candidates: [PixelRect], clippedTo size: PixelSize) {
        var pending = candidates.compactMap { $0.clipped(to: size) }
        pending.sort(by: PixelRegionSet.precedes)
        var merged: [PixelRect] = []

        while let first = pending.first {
            pending.removeFirst()
            var current = first
            var didMerge = true
            while didMerge {
                didMerge = false
                for index in pending.indices.reversed()
                where current.touchesOrOverlaps(pending[index]) {
                    current = current.union(pending.remove(at: index))
                    didMerge = true
                }
                for index in merged.indices.reversed()
                where current.touchesOrOverlaps(merged[index]) {
                    current = current.union(merged.remove(at: index))
                    didMerge = true
                }
            }
            merged.append(current)
        }
        rectangles = merged.sorted(by: PixelRegionSet.precedes)
    }

    private static func precedes(_ lhs: PixelRect, _ rhs: PixelRect) -> Bool {
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
        if lhs.maxY != rhs.maxY { return lhs.maxY < rhs.maxY }
        return lhs.maxX < rhs.maxX
    }
}
