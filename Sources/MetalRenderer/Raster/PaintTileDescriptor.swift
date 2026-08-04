import Metal
import PatternEngine

public enum PaintTileError: Error, Equatable, Sendable {
    case pixelOutsideSurface(x: Int, y: Int)
    case coordinateOutsideSurface(PaintTileCoordinate)
    case invalidAntialiasHalo(Int)
    case boundsArithmeticOverflow
}

public struct PaintTileCoordinate: Hashable, Comparable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public static func < (
        lhs: PaintTileCoordinate,
        rhs: PaintTileCoordinate
    ) -> Bool {
        (lhs.y, lhs.x) < (rhs.y, rhs.x)
    }
}

public struct PaintTileDescriptor: Hashable, Sendable {
    public static let side = 256
    public static let pixelFormat: MTLPixelFormat = .rgba16Float
    public static let residentByteCount = 256 * 256 * 4 * 2

    public let coordinate: PaintTileCoordinate
    public let logicalBounds: PixelRect

    public var physicalPixelSize: PixelSize {
        PixelSize(width: Self.side, height: Self.side)
    }

    public var residentByteCount: Int {
        Self.residentByteCount
    }

    public init(
        coordinate: PaintTileCoordinate,
        logicalPixelSize: PixelSize
    ) throws {
        guard coordinate.x >= 0, coordinate.y >= 0 else {
            throw PaintTileError.coordinateOutsideSurface(coordinate)
        }
        let (minX, xOverflow) = coordinate.x.multipliedReportingOverflow(
            by: Self.side
        )
        let (minY, yOverflow) = coordinate.y.multipliedReportingOverflow(
            by: Self.side
        )
        guard !xOverflow, !yOverflow,
              minX < logicalPixelSize.width,
              minY < logicalPixelSize.height
        else {
            throw PaintTileError.coordinateOutsideSurface(coordinate)
        }
        let (unclippedMaxX, maxXOverflow) = minX.addingReportingOverflow(
            Self.side
        )
        let (unclippedMaxY, maxYOverflow) = minY.addingReportingOverflow(
            Self.side
        )
        guard !maxXOverflow, !maxYOverflow,
              let bounds = PixelRect(
                minX: minX,
                minY: minY,
                maxX: min(unclippedMaxX, logicalPixelSize.width),
                maxY: min(unclippedMaxY, logicalPixelSize.height)
              )
        else {
            throw PaintTileError.boundsArithmeticOverflow
        }
        self.coordinate = coordinate
        logicalBounds = bounds
    }

    public static func coordinate(
        containingX x: Int,
        y: Int,
        in pixelSize: PixelSize
    ) throws -> PaintTileCoordinate {
        guard x >= 0, y >= 0,
              x < pixelSize.width, y < pixelSize.height
        else {
            throw PaintTileError.pixelOutsideSurface(x: x, y: y)
        }
        return PaintTileCoordinate(x: x / side, y: y / side)
    }

    /// Returns the physical tiles intersecting the half-open support bounds
    /// after applying the required antialias halo and clipping to the surface.
    public static func coordinates(
        intersecting supportBounds: PixelRect,
        in pixelSize: PixelSize,
        antialiasHalo: Int = 1
    ) throws -> [PaintTileCoordinate] {
        guard antialiasHalo >= 0 else {
            throw PaintTileError.invalidAntialiasHalo(antialiasHalo)
        }
        let (expandedMinX, minXOverflow) = supportBounds.minX
            .subtractingReportingOverflow(antialiasHalo)
        let (expandedMinY, minYOverflow) = supportBounds.minY
            .subtractingReportingOverflow(antialiasHalo)
        let (expandedMaxX, maxXOverflow) = supportBounds.maxX
            .addingReportingOverflow(antialiasHalo)
        let (expandedMaxY, maxYOverflow) = supportBounds.maxY
            .addingReportingOverflow(antialiasHalo)
        guard !minXOverflow, !minYOverflow,
              !maxXOverflow, !maxYOverflow
        else {
            throw PaintTileError.boundsArithmeticOverflow
        }
        let minX = max(0, expandedMinX)
        let minY = max(0, expandedMinY)
        let maxX = min(pixelSize.width, expandedMaxX)
        let maxY = min(pixelSize.height, expandedMaxY)
        guard maxX > minX, maxY > minY else { return [] }

        let firstX = minX / side
        let firstY = minY / side
        let lastX = (maxX - 1) / side
        let lastY = (maxY - 1) / side
        var result: [PaintTileCoordinate] = []
        let columnCount = lastX - firstX + 1
        let rowCount = lastY - firstY + 1
        let (capacity, overflow) = columnCount.multipliedReportingOverflow(
            by: rowCount
        )
        guard !overflow else { throw PaintTileError.boundsArithmeticOverflow }
        result.reserveCapacity(capacity)
        for y in firstY...lastY {
            for x in firstX...lastX {
                result.append(PaintTileCoordinate(x: x, y: y))
            }
        }
        return result
    }
}
