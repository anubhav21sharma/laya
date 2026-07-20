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
            let column = checkedCellIndex(
                coordinate: point.x,
                extent: tileSize.width,
                phase: 0,
                axis: .x
            )
            let phaseY = parity(column) * tileSize.height * 0.5
            let row = checkedCellIndex(
                coordinate: point.y,
                extent: tileSize.height,
                phase: phaseY,
                axis: .y
            )
            return CellIndex(column: column, row: row)
        case .brick:
            let row = checkedCellIndex(
                coordinate: point.y,
                extent: tileSize.height,
                phase: 0,
                axis: .y
            )
            let phaseX = parity(row) * tileSize.width * 0.5
            let column = checkedCellIndex(
                coordinate: point.x,
                extent: tileSize.width,
                phase: phaseX,
                axis: .x
            )
            return CellIndex(column: column, row: row)
        case .grid, .mirrorX, .mirrorY, .mirrorXY, .rotational:
            return CellIndex(
                column: checkedCellIndex(
                    coordinate: point.x,
                    extent: tileSize.width,
                    phase: 0,
                    axis: .x
                ),
                row: checkedCellIndex(
                    coordinate: point.y,
                    extent: tileSize.height,
                    phase: 0,
                    axis: .y
                )
            )
        }
    }

    public func images(
        intersecting worldBounds: AxisAlignedRect
    ) -> [TilingImage] {
        precondition(
            worldBounds.minimum.x.isFinite,
            "TilingStrategy minimum x bound must be finite"
        )
        precondition(
            worldBounds.minimum.y.isFinite,
            "TilingStrategy minimum y bound must be finite"
        )
        precondition(
            worldBounds.maximum.x.isFinite,
            "TilingStrategy maximum x bound must be finite"
        )
        precondition(
            worldBounds.maximum.y.isFinite,
            "TilingStrategy maximum y bound must be finite"
        )
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
                phase: 0,
                axis: .x
            ) else {
                return []
            }
            for column in columns {
                let phaseY = parity(column) * tileSize.height * 0.5
                guard let rows = intersectingIndices(
                    minimum: worldBounds.minimum.y,
                    maximum: worldBounds.maximum.y,
                    extent: tileSize.height,
                    phase: phaseY,
                    axis: .y
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
                phase: 0,
                axis: .y
            ) else {
                return []
            }
            for row in rows {
                let phaseX = parity(row) * tileSize.width * 0.5
                guard let columns = intersectingIndices(
                    minimum: worldBounds.minimum.x,
                    maximum: worldBounds.maximum.x,
                    extent: tileSize.width,
                    phase: phaseX,
                    axis: .x
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
                    phase: 0,
                    axis: .x
                ),
                let rows = intersectingIndices(
                    minimum: worldBounds.minimum.y,
                    maximum: worldBounds.maximum.y,
                    extent: tileSize.height,
                    phase: 0,
                    axis: .y
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
        let cell = cell(containing: point)
        switch kind {
        case .grid, .rotational:
            return CanonicalPoint(
                x: positiveModulo(point.x, tileSize.width),
                y: positiveModulo(point.y, tileSize.height)
            )
        case .halfDrop:
            let phaseY = parity(cell.column) * tileSize.height * 0.5
            return CanonicalPoint(
                x: positiveModulo(point.x, tileSize.width),
                y: positiveModulo(point.y - phaseY, tileSize.height)
            )
        case .brick:
            let phaseX = parity(cell.row) * tileSize.width * 0.5
            return CanonicalPoint(
                x: positiveModulo(point.x - phaseX, tileSize.width),
                y: positiveModulo(point.y, tileSize.height)
            )
        case .mirrorX, .mirrorY, .mirrorXY:
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

private enum CoordinateAxis: String {
    case x
    case y
}

private func checkedCellIndex(
    coordinate: Float,
    extent: Float,
    phase: Float,
    axis: CoordinateAxis
) -> Int {
    let candidateIndex = resolvedCellIndex(
        coordinate: coordinate,
        extent: extent,
        phase: phase,
        axis: axis
    )
    let floatIndex = Float(candidateIndex)
    precondition(
        exactCellIndex(floatIndex, axis: axis) == candidateIndex,
        "TilingStrategy \(axis.rawValue) cell index must be exactly representable as Float"
    )

    let unphasedOrigin = floatIndex * extent
    let origin = unphasedOrigin + phase
    let boundary = origin + extent
    precondition(
        unphasedOrigin.isFinite && origin.isFinite && boundary.isFinite,
        "TilingStrategy \(axis.rawValue) cell boundaries must be finite"
    )
    precondition(
        phase == 0 || origin - unphasedOrigin == phase,
        "TilingStrategy \(axis.rawValue) cell phase must be preserved"
    )
    precondition(
        boundary - origin == extent,
        "TilingStrategy \(axis.rawValue) cell extent must be preserved"
    )

    let (successorIndex, successorOverflowed) =
        candidateIndex.addingReportingOverflow(1)
    precondition(
        !successorOverflowed
            && resolvedCellIndex(
                coordinate: origin,
                extent: extent,
                phase: phase,
                axis: axis
            ) == candidateIndex
            && resolvedCellIndex(
                coordinate: boundary.nextDown,
                extent: extent,
                phase: phase,
                axis: axis
            ) == candidateIndex
            && resolvedCellIndex(
                coordinate: boundary,
                extent: extent,
                phase: phase,
                axis: axis
            ) == successorIndex,
        "TilingStrategy \(axis.rawValue) cell boundaries must round-trip half-open"
    )
    precondition(
        coordinate >= origin && coordinate < boundary,
        "TilingStrategy \(axis.rawValue) coordinate must resolve inside its cell"
    )
    return candidateIndex
}

private func resolvedCellIndex(
    coordinate: Float,
    extent: Float,
    phase: Float,
    axis: CoordinateAxis
) -> Int {
    var candidateIndex = quotientCellIndex(
        coordinate: coordinate,
        extent: extent,
        phase: phase,
        axis: axis
    )
    let origin = Float(candidateIndex) * extent + phase
    let boundary = origin + extent
    if coordinate < origin {
        let (previousIndex, overflowed) =
            candidateIndex.subtractingReportingOverflow(1)
        precondition(
            !overflowed,
            "TilingStrategy \(axis.rawValue) cell index must be Int-representable"
        )
        candidateIndex = previousIndex
    } else if coordinate >= boundary {
        let (nextIndex, overflowed) = candidateIndex.addingReportingOverflow(1)
        precondition(
            !overflowed,
            "TilingStrategy \(axis.rawValue) cell index must be Int-representable"
        )
        candidateIndex = nextIndex
    }
    return candidateIndex
}

private func quotientCellIndex(
    coordinate: Float,
    extent: Float,
    phase: Float,
    axis: CoordinateAxis
) -> Int {
    precondition(
        coordinate.isFinite,
        "TilingStrategy \(axis.rawValue) coordinate must be finite"
    )
    precondition(
        phase.isFinite,
        "TilingStrategy \(axis.rawValue) phase must be finite"
    )

    let phasedCoordinate = coordinate - phase
    precondition(
        phasedCoordinate.isFinite,
        "TilingStrategy \(axis.rawValue) phase subtraction must be finite"
    )
    let quotient = phasedCoordinate / extent
    precondition(
        quotient.isFinite,
        "TilingStrategy \(axis.rawValue) cell quotient must be finite"
    )
    return exactCellIndex(floor(quotient), axis: axis)
}

private func exactCellIndex(
    _ value: Float,
    axis: CoordinateAxis
) -> Int {
    precondition(
        value >= Float(Int.min) && value < Float(Int.max),
        "TilingStrategy \(axis.rawValue) cell index must be Int-representable"
    )
    guard let index = Int(exactly: value) else {
        preconditionFailure(
            "TilingStrategy \(axis.rawValue) cell index must be exactly representable as Float"
        )
    }
    return index
}

private func intersectingIndices(
    minimum: Float,
    maximum: Float,
    extent: Float,
    phase: Float,
    axis: CoordinateAxis
) -> ClosedRange<Int>? {
    let first = checkedCellIndex(
        coordinate: minimum,
        extent: extent,
        phase: phase,
        axis: axis
    )
    let last = checkedCellIndex(
        coordinate: maximum.nextDown,
        extent: extent,
        phase: phase,
        axis: axis
    )
    return first <= last ? first...last : nil
}
