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
        var canonical = candidates
        Self.canonicalizeInPlace(&canonical, clippedTo: size)
        rectangles = canonical
    }

    public static func canonicalizeInPlace(
        _ candidates: inout [PixelRect],
        clippedTo size: PixelSize
    ) {
        var writeIndex = 0
        for readIndex in candidates.indices {
            guard let clipped = candidates[readIndex].clipped(to: size)
            else {
                continue
            }
            candidates[writeIndex] = clipped
            writeIndex += 1
        }
        if writeIndex < candidates.count {
            candidates.removeLast(candidates.count - writeIndex)
        }
        candidates.sort(by: PixelRegionSet.precedes)
        var index = 0
        while index < candidates.count {
            var current = candidates[index]
            var scan = 0
            while scan < candidates.count {
                if scan == index {
                    scan += 1
                    continue
                }
                if current.touchesOrOverlaps(candidates[scan]) {
                    current = current.union(
                        candidates.remove(at: scan)
                    )
                    if scan < index {
                        index -= 1
                    }
                    candidates[index] = current
                    scan = 0
                } else {
                    scan += 1
                }
            }
            index += 1
        }
        candidates.sort(by: PixelRegionSet.precedes)
    }

    private static func precedes(_ lhs: PixelRect, _ rhs: PixelRect) -> Bool {
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
        if lhs.maxY != rhs.maxY { return lhs.maxY < rhs.maxY }
        return lhs.maxX < rhs.maxX
    }
}
