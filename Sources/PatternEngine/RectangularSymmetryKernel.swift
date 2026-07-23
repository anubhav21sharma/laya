import Foundation
import simd

struct RectangularSymmetryKernel: Equatable, Sendable {
    let compiled: CompiledSymmetry
    let periodic: CompiledPeriodicDomain

    init(compiled: CompiledSymmetry) {
        precondition(compiled.family == .rectangular)
        guard case let .periodic(periodic) = compiled.domain else {
            preconditionFailure(
                "RectangularSymmetryKernel requires a periodic descriptor"
            )
        }
        self.compiled = compiled
        self.periodic = periodic
    }

    func cell(containing point: WorldPoint) -> CellIndex {
        guard let program = periodic.phase else {
            return CellIndex(
                column: checkedCellIndex(
                    coordinate: point.x,
                    extent: periodic.tileSize.width,
                    phase: 0,
                    axis: .x
                ),
                row: checkedCellIndex(
                    coordinate: point.y,
                    extent: periodic.tileSize.height,
                    phase: 0,
                    axis: .y
                )
            )
        }

        switch program.indexAxis {
        case .x:
            let column = checkedCellIndex(
                coordinate: point.x,
                extent: periodic.tileSize.width,
                phase: 0,
                axis: .x
            )
            let phase = phaseOffset(for: column, program: program)
            let row = checkedCellIndex(
                coordinate: point.y,
                extent: periodic.tileSize.height,
                phase: phase,
                axis: .y
            )
            return CellIndex(column: column, row: row)
        case .y:
            let row = checkedCellIndex(
                coordinate: point.y,
                extent: periodic.tileSize.height,
                phase: 0,
                axis: .y
            )
            let phase = phaseOffset(for: row, program: program)
            let column = checkedCellIndex(
                coordinate: point.x,
                extent: periodic.tileSize.width,
                phase: phase,
                axis: .x
            )
            return CellIndex(column: column, row: row)
        }
    }

    func images(
        intersecting worldBounds: AxisAlignedRect
    ) -> [TilingImage] {
        var cells: [CellIndex] = []
        if let program = periodic.phase {
            switch program.indexAxis {
            case .x:
                guard let columns = intersectingIndices(
                    minimum: worldBounds.minimum.x,
                    maximum: worldBounds.maximum.x,
                    extent: periodic.tileSize.width,
                    phase: 0,
                    axis: .x
                ) else {
                    return []
                }
                for column in columns {
                    let phase = phaseOffset(for: column, program: program)
                    guard let rows = intersectingIndices(
                        minimum: worldBounds.minimum.y,
                        maximum: worldBounds.maximum.y,
                        extent: periodic.tileSize.height,
                        phase: phase,
                        axis: .y
                    ) else {
                        continue
                    }
                    for row in rows {
                        cells.append(
                            CellIndex(column: column, row: row)
                        )
                    }
                }
            case .y:
                guard let rows = intersectingIndices(
                    minimum: worldBounds.minimum.y,
                    maximum: worldBounds.maximum.y,
                    extent: periodic.tileSize.height,
                    phase: 0,
                    axis: .y
                ) else {
                    return []
                }
                for row in rows {
                    let phase = phaseOffset(for: row, program: program)
                    guard let columns = intersectingIndices(
                        minimum: worldBounds.minimum.x,
                        maximum: worldBounds.maximum.x,
                        extent: periodic.tileSize.width,
                        phase: phase,
                        axis: .x
                    ) else {
                        continue
                    }
                    for column in columns {
                        cells.append(
                            CellIndex(column: column, row: row)
                        )
                    }
                }
            }
        } else {
            guard
                let columns = intersectingIndices(
                    minimum: worldBounds.minimum.x,
                    maximum: worldBounds.maximum.x,
                    extent: periodic.tileSize.width,
                    phase: 0,
                    axis: .x
                ),
                let rows = intersectingIndices(
                    minimum: worldBounds.minimum.y,
                    maximum: worldBounds.maximum.y,
                    extent: periodic.tileSize.height,
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
            where image.worldBounds.intersects(worldBounds)
                && !result.contains(image)
            {
                result.append(image)
            }
        }
        return result
    }

    func displayFold(_ point: WorldPoint) -> CanonicalPoint {
        let cell = cell(containing: point)
        var phasedPoint = point.simd
        if let program = periodic.phase {
            let index: Int
            switch program.indexAxis {
            case .x:
                index = cell.column
            case .y:
                index = cell.row
            }
            let phase = phaseOffset(for: index, program: program)
            switch program.offsetAxis {
            case .x:
                phasedPoint.x -= phase
            case .y:
                phasedPoint.y -= phase
            }
        }

        let localX = positiveModulo(
            phasedPoint.x,
            periodic.tileSize.width
        )
        let localY = positiveModulo(
            phasedPoint.y,
            periodic.tileSize.height
        )
        let reflectsX = periodic.alternatingReflections.contains(.x)
            && !cell.column.isMultiple(of: 2)
        let reflectsY = periodic.alternatingReflections.contains(.y)
            && !cell.row.isMultiple(of: 2)
        return CanonicalPoint(
            x: reflectsX
                ? positiveModulo(
                    periodic.tileSize.width - localX,
                    periodic.tileSize.width
                )
                : localX,
            y: reflectsY
                ? positiveModulo(
                    periodic.tileSize.height - localY,
                    periodic.tileSize.height
                )
                : localY
        )
    }

    private func images(for cell: CellIndex) -> [TilingImage] {
        let origin = cellOrigin(for: cell)
        let bounds = AxisAlignedRect(
            minimum: origin,
            maximum: origin + periodic.tileSize.simd
        )
        let reflectsX = periodic.alternatingReflections.contains(.x)
            && !cell.column.isMultiple(of: 2)
        let reflectsY = periodic.alternatingReflections.contains(.y)
            && !cell.row.isMultiple(of: 2)
        let worldToLocal = Affine2D(
            xAxis: SIMD2(1, 0),
            yAxis: SIMD2(0, 1),
            translation: -origin
        )
        let parityToCanonical = Affine2D(
            xAxis: SIMD2(reflectsX ? -1 : 1, 0),
            yAxis: SIMD2(0, reflectsY ? -1 : 1),
            translation: SIMD2(
                reflectsX ? periodic.tileSize.width : 0,
                reflectsY ? periodic.tileSize.height : 0
            )
        )

        return compiled.images.map { compiledImage in
            TilingImage(
                cell: cell,
                ordinal: compiledImage.ordinal,
                worldBounds: bounds,
                worldToCanonical: worldToLocal
                    .concatenating(parityToCanonical)
                    .concatenating(compiledImage.localToCanonical)
            )
        }
    }

    private func cellOrigin(for cell: CellIndex) -> SIMD2<Float> {
        let unphasedOrigin =
            periodic.translationBasis.origin
            + periodic.translationBasis.u * Float(cell.column)
            + periodic.translationBasis.v * Float(cell.row)
        guard let program = periodic.phase else {
            return unphasedOrigin
        }

        let index: Int
        switch program.indexAxis {
        case .x:
            index = cell.column
        case .y:
            index = cell.row
        }
        let phase = phaseOffset(for: index, program: program)
        var origin = unphasedOrigin
        switch program.offsetAxis {
        case .x:
            origin.x += phase
        case .y:
            origin.y += phase
        }
        return origin
    }

    private func phaseOffset(
        for index: Int,
        program: PeriodicPhaseProgram
    ) -> Float {
        let extent: Float
        switch program.offsetAxis {
        case .x:
            extent = periodic.tileSize.width
        case .y:
            extent = periodic.tileSize.height
        }
        return phaseFraction(for: index, program: program) * extent
    }

    private func phaseFraction(
        for index: Int,
        program: PeriodicPhaseProgram
    ) -> Float {
        let count = program.fractions.count
        let remainder = index % count
        let resolved = remainder >= 0 ? remainder : remainder + count
        return program.fractions[resolved]
    }
}

private func positiveModulo(_ value: Float, _ extent: Float) -> Float {
    let normalizedValue = abs(value) < Float.leastNormalMagnitude ? 0 : value
    let remainder = normalizedValue.truncatingRemainder(dividingBy: extent)
    if abs(remainder) < Float.leastNormalMagnitude {
        return 0
    }
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
