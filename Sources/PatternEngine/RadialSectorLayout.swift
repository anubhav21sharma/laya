import Foundation
import simd

public struct RadialPageCoordinate: Hashable, Comparable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public static func < (
        lhs: RadialPageCoordinate,
        rhs: RadialPageCoordinate
    ) -> Bool {
        lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
    }
}

public struct RadialResidentPage: Equatable, Sendable {
    public let coordinate: RadialPageCoordinate
    public let atlasSlot: Int

    public init(coordinate: RadialPageCoordinate, atlasSlot: Int) {
        self.coordinate = coordinate
        self.atlasSlot = atlasSlot
    }
}

public struct RadialSectorLayout: Equatable, Sendable {
    public static let pageSide = 256
    public static let maximumAtlasDimension = 16_384
    public static let maximumResidentBytesPerSurface = 256 * 1_024 * 1_024

    public let logicalBounds: AxisAlignedRect
    public let maximumRadius: Float
    public let sectorAngleRadians: Float
    public let pageOrigin: RadialPageCoordinate
    public let pageTableSize: PixelSize
    public let residentPages: [RadialResidentPage]
    public let atlasColumns: Int
    public let atlasPixelSize: PixelSize
    public let pageTable: [Int32]
    public let residentBytesPerSurface: Int

    public init(
        maximumRadius: Float,
        sectorAngleRadians: Float
    ) throws {
        guard maximumRadius.isFinite, maximumRadius > 0 else {
            throw SymmetryDescriptorError.nonFiniteRadialGeometry
        }
        guard sectorAngleRadians.isFinite,
              sectorAngleRadians > 0,
              sectorAngleRadians <= .pi
        else {
            throw SymmetryDescriptorError.nonFiniteRadialGeometry
        }

        let cosine = cos(sectorAngleRadians)
        let sine = sin(sectorAngleRadians)
        let minimumX = min(0, maximumRadius * cosine)
        let maximumY = sectorAngleRadians >= .pi / 2
            ? maximumRadius
            : maximumRadius * sine
        logicalBounds = AxisAlignedRect(
            minimum: SIMD2(minimumX, 0),
            maximum: SIMD2(maximumRadius, max(maximumY, 1))
        )
        self.maximumRadius = maximumRadius
        self.sectorAngleRadians = sectorAngleRadians

        let side = Float(Self.pageSide)
        let minimumPageX = Int(floor(logicalBounds.minimum.x / side))
        let minimumPageY = Int(floor(logicalBounds.minimum.y / side))
        let maximumPageX = Int(
            floor(logicalBounds.maximum.x.nextDown / side)
        )
        let maximumPageY = Int(
            floor(logicalBounds.maximum.y.nextDown / side)
        )
        pageOrigin = RadialPageCoordinate(
            x: minimumPageX,
            y: minimumPageY
        )
        pageTableSize = PixelSize(
            width: maximumPageX - minimumPageX + 1,
            height: maximumPageY - minimumPageY + 1
        )

        var coordinates: [RadialPageCoordinate] = []
        for y in minimumPageY...maximumPageY {
            for x in minimumPageX...maximumPageX {
                let coordinate = RadialPageCoordinate(x: x, y: y)
                if Self.pageIntersectsSector(
                    coordinate,
                    maximumRadius: maximumRadius,
                    sectorAngleRadians: sectorAngleRadians
                ) {
                    coordinates.append(coordinate)
                }
            }
        }
        guard !coordinates.isEmpty else {
            throw SymmetryDescriptorError.radialPageLayoutEmpty
        }

        let pageCount = coordinates.count
        atlasColumns = max(1, Int(ceil(sqrt(Double(pageCount)))))
        let atlasRows = (pageCount + atlasColumns - 1) / atlasColumns
        let atlasWidth = atlasColumns * Self.pageSide
        let atlasHeight = atlasRows * Self.pageSide
        guard atlasWidth <= Self.maximumAtlasDimension,
              atlasHeight <= Self.maximumAtlasDimension
        else {
            throw SymmetryDescriptorError.radialAtlasDimensionExceeded(
                width: atlasWidth,
                height: atlasHeight,
                maximum: Self.maximumAtlasDimension
            )
        }
        atlasPixelSize = PixelSize(width: atlasWidth, height: atlasHeight)

        let (pixels, pixelOverflow) = atlasWidth.multipliedReportingOverflow(
            by: atlasHeight
        )
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow,
              bytes <= Self.maximumResidentBytesPerSurface
        else {
            throw SymmetryDescriptorError.radialResidentBytesExceeded(
                actual: byteOverflow ? Int.max : bytes,
                maximum: Self.maximumResidentBytesPerSurface
            )
        }
        residentBytesPerSurface = bytes

        residentPages = coordinates.enumerated().map {
            RadialResidentPage(coordinate: $0.element, atlasSlot: $0.offset)
        }
        var table = Array(
            repeating: Int32(-1),
            count: pageTableSize.width * pageTableSize.height
        )
        for page in residentPages {
            let tableX = page.coordinate.x - pageOrigin.x
            let tableY = page.coordinate.y - pageOrigin.y
            table[tableY * pageTableSize.width + tableX] =
                Int32(page.atlasSlot)
        }
        pageTable = table
    }

    public func residentPage(
        at coordinate: RadialPageCoordinate
    ) -> RadialResidentPage? {
        let x = coordinate.x - pageOrigin.x
        let y = coordinate.y - pageOrigin.y
        guard x >= 0, y >= 0,
              x < pageTableSize.width,
              y < pageTableSize.height
        else {
            return nil
        }
        let slot = pageTable[y * pageTableSize.width + x]
        guard slot >= 0 else { return nil }
        return RadialResidentPage(
            coordinate: coordinate,
            atlasSlot: Int(slot)
        )
    }

    public func residentPage(containing point: SIMD2<Float>)
        -> RadialResidentPage?
    {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let side = Float(Self.pageSide)
        return residentPage(
            at: RadialPageCoordinate(
                x: Int(floor(point.x / side)),
                y: Int(floor(point.y / side))
            )
        )
    }

    public func logicalToAtlas(
        for page: RadialResidentPage
    ) -> Affine2D {
        let atlasX = page.atlasSlot % atlasColumns
        let atlasY = page.atlasSlot / atlasColumns
        let side = Float(Self.pageSide)
        return Affine2D(
            xAxis: SIMD2(1, 0),
            yAxis: SIMD2(0, 1),
            translation: SIMD2(
                Float(atlasX - page.coordinate.x) * side,
                Float(atlasY - page.coordinate.y) * side
            )
        )
    }

    public func atlasPoint(forLogical point: SIMD2<Float>)
        -> SIMD2<Float>?
    {
        guard let page = residentPage(containing: point) else { return nil }
        return logicalToAtlas(for: page).applying(to: point)
    }

    public func logicalPageBounds(
        _ page: RadialResidentPage
    ) -> AxisAlignedRect {
        let side = Float(Self.pageSide)
        let minimum = SIMD2(
            Float(page.coordinate.x) * side,
            Float(page.coordinate.y) * side
        )
        return AxisAlignedRect(
            minimum: minimum,
            maximum: minimum + SIMD2(repeating: side)
        )
    }

    public func containsLogicalPoint(_ point: SIMD2<Float>) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        let tolerance = max(maximumRadius, 1) * 16 * Float.ulpOfOne
        let radiusSquared = simd_length_squared(point)
        guard radiusSquared <= maximumRadius * maximumRadius + tolerance else {
            return false
        }
        if radiusSquared <= tolerance {
            return true
        }
        var angle = atan2(point.y, point.x)
        if angle < 0 { angle += 2 * .pi }
        return angle <= sectorAngleRadians + tolerance
    }

    private static func pageIntersectsSector(
        _ coordinate: RadialPageCoordinate,
        maximumRadius: Float,
        sectorAngleRadians: Float
    ) -> Bool {
        let side = Float(pageSide)
        let minimum = SIMD2(
            Float(coordinate.x) * side,
            Float(coordinate.y) * side
        )
        var polygon = [
            minimum,
            minimum + SIMD2(side, 0),
            minimum + SIMD2(repeating: side),
            minimum + SIMD2(0, side),
        ]
        let lower = HalfPlane2D(normal: SIMD2(0, 1), offset: 0)
        let upperDirection = SIMD2(
            cos(sectorAngleRadians),
            sin(sectorAngleRadians)
        )
        let upper = HalfPlane2D(
            normal: SIMD2(upperDirection.y, -upperDirection.x),
            offset: 0
        )
        polygon = clip(polygon, to: lower)
        polygon = clip(polygon, to: upper)
        guard !polygon.isEmpty else { return false }
        if polygon.contains(where: {
            simd_length_squared($0) <= maximumRadius * maximumRadius
        }) {
            return true
        }
        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            if distanceSquaredFromOrigin(toSegmentFrom: start, to: end)
                <= maximumRadius * maximumRadius
            {
                return true
            }
        }
        return false
    }
}

private func clip(
    _ polygon: [SIMD2<Float>],
    to plane: HalfPlane2D
) -> [SIMD2<Float>] {
    guard let last = polygon.last else { return [] }
    var result: [SIMD2<Float>] = []
    var start = last
    var startDistance = simd_dot(plane.normal, start) - plane.offset
    for end in polygon {
        let endDistance = simd_dot(plane.normal, end) - plane.offset
        let startInside = startDistance >= 0
        let endInside = endDistance >= 0
        if endInside != startInside {
            let t = startDistance / (startDistance - endDistance)
            result.append(start + (end - start) * t)
        }
        if endInside {
            result.append(end)
        }
        start = end
        startDistance = endDistance
    }
    return result
}

private func distanceSquaredFromOrigin(
    toSegmentFrom start: SIMD2<Float>,
    to end: SIMD2<Float>
) -> Float {
    let segment = end - start
    let lengthSquared = simd_length_squared(segment)
    guard lengthSquared > 0 else { return simd_length_squared(start) }
    let t = min(1, max(0, -simd_dot(start, segment) / lengthSquared))
    return simd_length_squared(start + segment * t)
}

private extension SIMD2 where Scalar == Float {
    var isFinite: Bool { x.isFinite && y.isFinite }
}
