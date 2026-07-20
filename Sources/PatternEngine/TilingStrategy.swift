import Foundation
import simd

public struct CellIndex: Hashable, Sendable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

public struct TilingImage: Equatable, Sendable {
    public let cell: CellIndex
    public let ordinal: UInt8
    public let worldBounds: AxisAlignedRect
    public let worldToCanonical: Affine2D

    public init(
        cell: CellIndex,
        ordinal: UInt8,
        worldBounds: AxisAlignedRect,
        worldToCanonical: Affine2D
    ) {
        self.cell = cell
        self.ordinal = ordinal
        self.worldBounds = worldBounds
        self.worldToCanonical = worldToCanonical
    }
}

public struct TilingStrategy: Equatable, Sendable {
    public let kind: TilingKind
    public let tileSize: PatternSize

    public init(kind: TilingKind, tileSize: PatternSize) {
        precondition(
            tileSize.width.isFinite,
            "TilingStrategy tile width must be finite"
        )
        precondition(
            tileSize.height.isFinite,
            "TilingStrategy tile height must be finite"
        )
        precondition(
            tileSize.width.rounded(.towardZero) == tileSize.width,
            "TilingStrategy tile width must be an integer"
        )
        precondition(
            tileSize.height.rounded(.towardZero) == tileSize.height,
            "TilingStrategy tile height must be an integer"
        )
        precondition(
            tileSize.width >= 64 && tileSize.width <= 4096,
            "TilingStrategy tile width must be in 64...4096"
        )
        precondition(
            tileSize.height >= 64 && tileSize.height <= 4096,
            "TilingStrategy tile height must be in 64...4096"
        )
        self.kind = kind
        self.tileSize = tileSize
    }

    public func cell(containing point: WorldPoint) -> CellIndex {
        switch kind {
        case .halfDrop:
            let column = Int(floor(point.x / tileSize.width))
            let phaseY = parity(column) * tileSize.height * 0.5
            let row = Int(floor((point.y - phaseY) / tileSize.height))
            return CellIndex(column: column, row: row)
        case .brick:
            let row = Int(floor(point.y / tileSize.height))
            let phaseX = parity(row) * tileSize.width * 0.5
            let column = Int(floor((point.x - phaseX) / tileSize.width))
            return CellIndex(column: column, row: row)
        case .grid, .mirrorX, .mirrorY, .mirrorXY, .rotational:
            return CellIndex(
                column: Int(floor(point.x / tileSize.width)),
                row: Int(floor(point.y / tileSize.height))
            )
        }
    }

    public func images(
        intersecting worldBounds: AxisAlignedRect
    ) -> [TilingImage] {
        guard
            worldBounds.maximum.x > worldBounds.minimum.x,
            worldBounds.maximum.y > worldBounds.minimum.y
        else {
            return []
        }

        var cells: [CellIndex] = []
        switch kind {
        case .halfDrop:
            guard let columns = intersectingIndices(
                minimum: worldBounds.minimum.x,
                maximum: worldBounds.maximum.x,
                extent: tileSize.width,
                phase: 0
            ) else {
                return []
            }
            for column in columns {
                let phaseY = parity(column) * tileSize.height * 0.5
                guard let rows = intersectingIndices(
                    minimum: worldBounds.minimum.y,
                    maximum: worldBounds.maximum.y,
                    extent: tileSize.height,
                    phase: phaseY
                ) else {
                    continue
                }
                for row in rows {
                    cells.append(CellIndex(column: column, row: row))
                }
            }
        case .brick:
            guard let rows = intersectingIndices(
                minimum: worldBounds.minimum.y,
                maximum: worldBounds.maximum.y,
                extent: tileSize.height,
                phase: 0
            ) else {
                return []
            }
            for row in rows {
                let phaseX = parity(row) * tileSize.width * 0.5
                guard let columns = intersectingIndices(
                    minimum: worldBounds.minimum.x,
                    maximum: worldBounds.maximum.x,
                    extent: tileSize.width,
                    phase: phaseX
                ) else {
                    continue
                }
                for column in columns {
                    cells.append(CellIndex(column: column, row: row))
                }
            }
        case .grid, .mirrorX, .mirrorY, .mirrorXY, .rotational:
            guard
                let columns = intersectingIndices(
                    minimum: worldBounds.minimum.x,
                    maximum: worldBounds.maximum.x,
                    extent: tileSize.width,
                    phase: 0
                ),
                let rows = intersectingIndices(
                    minimum: worldBounds.minimum.y,
                    maximum: worldBounds.maximum.y,
                    extent: tileSize.height,
                    phase: 0
                )
            else {
                return []
            }
            for row in rows {
                for column in columns {
                    cells.append(CellIndex(column: column, row: row))
                }
            }
        }

        cells.sort {
            if $0.row != $1.row {
                return $0.row < $1.row
            }
            return $0.column < $1.column
        }

        var result: [TilingImage] = []
        for cell in cells {
            for image in images(for: cell)
            where image.worldBounds.intersects(worldBounds) && !result.contains(image) {
                result.append(image)
            }
        }
        return result
    }

    public func displayFold(_ point: WorldPoint) -> CanonicalPoint {
        switch kind {
        case .grid, .rotational:
            return CanonicalPoint(
                x: positiveModulo(point.x, tileSize.width),
                y: positiveModulo(point.y, tileSize.height)
            )
        case .halfDrop:
            let column = Int(floor(point.x / tileSize.width))
            let phaseY = parity(column) * tileSize.height * 0.5
            return CanonicalPoint(
                x: positiveModulo(point.x, tileSize.width),
                y: positiveModulo(point.y - phaseY, tileSize.height)
            )
        case .brick:
            let row = Int(floor(point.y / tileSize.height))
            let phaseX = parity(row) * tileSize.width * 0.5
            return CanonicalPoint(
                x: positiveModulo(point.x - phaseX, tileSize.width),
                y: positiveModulo(point.y, tileSize.height)
            )
        case .mirrorX, .mirrorY, .mirrorXY:
            let cell = cell(containing: point)
            let reflectsX = (kind == .mirrorX || kind == .mirrorXY)
                && !cell.column.isMultiple(of: 2)
            let reflectsY = (kind == .mirrorY || kind == .mirrorXY)
                && !cell.row.isMultiple(of: 2)
            let localX = positiveModulo(point.x, tileSize.width)
            let localY = positiveModulo(point.y, tileSize.height)
            return CanonicalPoint(
                x: reflectsX
                    ? positiveModulo(tileSize.width - localX, tileSize.width)
                    : localX,
                y: reflectsY
                    ? positiveModulo(tileSize.height - localY, tileSize.height)
                    : localY
            )
        }
    }

    private func images(for cell: CellIndex) -> [TilingImage] {
        let origin = cellOrigin(for: cell)
        let bounds = AxisAlignedRect(
            minimum: origin,
            maximum: origin + tileSize.simd
        )

        if kind == .rotational {
            return [
                TilingImage(
                    cell: cell,
                    ordinal: 0,
                    worldBounds: bounds,
                    worldToCanonical: Affine2D(
                        xAxis: SIMD2(1, 0),
                        yAxis: SIMD2(0, 1),
                        translation: -origin
                    )
                ),
                TilingImage(
                    cell: cell,
                    ordinal: 1,
                    worldBounds: bounds,
                    worldToCanonical: Affine2D(
                        xAxis: SIMD2(-1, 0),
                        yAxis: SIMD2(0, -1),
                        translation: origin + tileSize.simd
                    )
                ),
            ]
        }

        let reflectsX = (kind == .mirrorX || kind == .mirrorXY)
            && !cell.column.isMultiple(of: 2)
        let reflectsY = (kind == .mirrorY || kind == .mirrorXY)
            && !cell.row.isMultiple(of: 2)
        return [
            TilingImage(
                cell: cell,
                ordinal: 0,
                worldBounds: bounds,
                worldToCanonical: Affine2D(
                    xAxis: SIMD2(reflectsX ? -1 : 1, 0),
                    yAxis: SIMD2(0, reflectsY ? -1 : 1),
                    translation: SIMD2(
                        reflectsX ? origin.x + tileSize.width : -origin.x,
                        reflectsY ? origin.y + tileSize.height : -origin.y
                    )
                )
            ),
        ]
    }

    private func cellOrigin(for cell: CellIndex) -> SIMD2<Float> {
        switch kind {
        case .halfDrop:
            return SIMD2(
                Float(cell.column) * tileSize.width,
                Float(cell.row) * tileSize.height
                    + parity(cell.column) * tileSize.height * 0.5
            )
        case .brick:
            return SIMD2(
                Float(cell.column) * tileSize.width
                    + parity(cell.row) * tileSize.width * 0.5,
                Float(cell.row) * tileSize.height
            )
        case .grid, .mirrorX, .mirrorY, .mirrorXY, .rotational:
            return SIMD2(
                Float(cell.column) * tileSize.width,
                Float(cell.row) * tileSize.height
            )
        }
    }
}

private func positiveModulo(_ value: Float, _ extent: Float) -> Float {
    let remainder = value.truncatingRemainder(dividingBy: extent)
    if remainder == 0 {
        return 0
    }
    if remainder < 0 {
        return min(remainder + extent, extent.nextDown)
    }
    return remainder
}

private func parity(_ value: Int) -> Float {
    value.isMultiple(of: 2) ? 0 : 1
}

private func intersectingIndices(
    minimum: Float,
    maximum: Float,
    extent: Float,
    phase: Float
) -> ClosedRange<Int>? {
    let first = Int(floor((minimum - phase) / extent))
    let last = Int(ceil((maximum - phase) / extent)) - 1
    return first <= last ? first...last : nil
}
