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
            if !isAxisAligned {
                let lattice = periodic.worldToLattice.applying(
                    to: point.simd
                )
                return CellIndex(
                    column: checkedCellIndex(
                        coordinate: lattice.x,
                        extent: 1,
                        phase: 0,
                        axis: .x
                    ),
                    row: checkedCellIndex(
                        coordinate: lattice.y,
                        extent: 1,
                        phase: 0,
                        axis: .y
                    )
                )
            }
            return CellIndex(
                column: checkedCellIndex(
                    coordinate: point.x,
                    extent: repeatSize.width,
                    phase: 0,
                    axis: .x
                ),
                row: checkedCellIndex(
                    coordinate: point.y,
                    extent: repeatSize.height,
                    phase: 0,
                    axis: .y
                )
            )
        }

        switch program.indexAxis {
        case .x:
            let column = checkedCellIndex(
                coordinate: point.x,
                extent: repeatSize.width,
                phase: 0,
                axis: .x
            )
            let phase = phaseOffset(for: column, program: program)
            let row = checkedCellIndex(
                coordinate: point.y,
                extent: repeatSize.height,
                phase: phase,
                axis: .y
            )
            return CellIndex(column: column, row: row)
        case .y:
            let row = checkedCellIndex(
                coordinate: point.y,
                extent: repeatSize.height,
                phase: 0,
                axis: .y
            )
            let phase = phaseOffset(for: row, program: program)
            let column = checkedCellIndex(
                coordinate: point.x,
                extent: repeatSize.width,
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
        var result: [TilingImage] = []
        try! populateImages(
            intersecting: worldBounds,
            cells: &cells,
            result: &result
        )
        return result
    }

    func populateImages(
        intersecting worldBounds: AxisAlignedRect,
        cells: inout [CellIndex],
        result: inout [TilingImage],
        maximumImageCount: Int? = nil
    ) throws {
        cells.removeAll(keepingCapacity: true)
        result.removeAll(keepingCapacity: true)
        if let program = periodic.phase {
            switch program.indexAxis {
            case .x:
                guard let columns = intersectingIndices(
                    minimum: worldBounds.minimum.x,
                    maximum: worldBounds.maximum.x,
                    extent: repeatSize.width,
                    phase: 0,
                    axis: .x
                ) else {
                    return
                }
                for column in columns {
                    let phase = phaseOffset(for: column, program: program)
                    guard let rows = intersectingIndices(
                        minimum: worldBounds.minimum.y,
                        maximum: worldBounds.maximum.y,
                        extent: repeatSize.height,
                        phase: phase,
                        axis: .y
                    ) else {
                        continue
                    }
                    for row in rows {
                        try appendBoundedRectangularCell(
                            CellIndex(column: column, row: row),
                            to: &cells,
                            maximumImageCount: maximumImageCount
                        )
                    }
                }
            case .y:
                guard let rows = intersectingIndices(
                    minimum: worldBounds.minimum.y,
                    maximum: worldBounds.maximum.y,
                    extent: repeatSize.height,
                    phase: 0,
                    axis: .y
                ) else {
                    return
                }
                for row in rows {
                    let phase = phaseOffset(for: row, program: program)
                    guard let columns = intersectingIndices(
                        minimum: worldBounds.minimum.x,
                        maximum: worldBounds.maximum.x,
                        extent: repeatSize.width,
                        phase: phase,
                        axis: .x
                    ) else {
                        continue
                    }
                    for column in columns {
                        try appendBoundedRectangularCell(
                            CellIndex(column: column, row: row),
                            to: &cells,
                            maximumImageCount: maximumImageCount
                        )
                    }
                }
            }
        } else if isAxisAligned {
            guard
                let columns = intersectingIndices(
                    minimum: worldBounds.minimum.x,
                    maximum: worldBounds.maximum.x,
                    extent: repeatSize.width,
                    phase: 0,
                    axis: .x
                ),
                let rows = intersectingIndices(
                    minimum: worldBounds.minimum.y,
                    maximum: worldBounds.maximum.y,
                    extent: repeatSize.height,
                    phase: 0,
                    axis: .y
                )
            else {
                return
            }
            for row in rows {
                for column in columns {
                    try appendBoundedRectangularCell(
                        CellIndex(column: column, row: row),
                        to: &cells,
                        maximumImageCount: maximumImageCount
                    )
                }
            }
        } else {
            let lattice0 = periodic.worldToLattice.applying(
                to: worldBounds.minimum
            )
            let lattice1 = periodic.worldToLattice.applying(
                to: SIMD2(worldBounds.maximum.x, worldBounds.minimum.y)
            )
            let lattice2 = periodic.worldToLattice.applying(
                to: worldBounds.maximum
            )
            let lattice3 = periodic.worldToLattice.applying(
                to: SIMD2(worldBounds.minimum.x, worldBounds.maximum.y)
            )
            let minimumX = min(
                lattice0.x, lattice1.x, lattice2.x, lattice3.x
            )
            let maximumX = max(
                lattice0.x, lattice1.x, lattice2.x, lattice3.x
            )
            let minimumY = min(
                lattice0.y, lattice1.y, lattice2.y, lattice3.y
            )
            let maximumY = max(
                lattice0.y, lattice1.y, lattice2.y, lattice3.y
            )
            guard
                let columns = intersectingIndices(
                    minimum: minimumX,
                    maximum: maximumX,
                    extent: 1,
                    phase: 0,
                    axis: .x
                ),
                let rows = intersectingIndices(
                    minimum: minimumY,
                    maximum: maximumY,
                    extent: 1,
                    phase: 0,
                    axis: .y
                )
            else {
                return
            }
            for row in rows {
                for column in columns {
                    let cell = CellIndex(column: column, row: row)
                    if cellIntersects(cell, worldBounds: worldBounds) {
                        try appendBoundedRectangularCell(
                            cell,
                            to: &cells,
                            maximumImageCount: maximumImageCount
                        )
                    }
                }
            }
        }

        cells.sort {
            if $0.row != $1.row {
                return $0.row < $1.row
            }
            return $0.column < $1.column
        }

        for cell in cells {
            try appendImages(
                for: cell,
                intersecting: worldBounds,
                to: &result,
                maximumImageCount: maximumImageCount
            )
        }
    }

    func displayFold(_ point: WorldPoint) -> CanonicalPoint {
        periodic.displayFold.applying(to: point)
    }

    private func appendImages(
        for cell: CellIndex,
        intersecting worldBounds: AxisAlignedRect,
        to result: inout [TilingImage],
        maximumImageCount: Int?
    ) throws {
        let origin = cellOrigin(for: cell)
        let vertices = cellQuad(origin: origin)
        let bounds = rectangularBounds(
            vertices.0, vertices.1, vertices.2, vertices.3
        )
        guard bounds.intersects(worldBounds) else { return }
        let worldClip = periodic.phase != nil || isAxisAligned
            ? axisAlignedClip(bounds)
            : rectangularConvexClip(
                vertices.0, vertices.1, vertices.2, vertices.3
            )
        let reflectsX = periodic.alternatingReflections.contains(.x)
            && !cell.column.isMultiple(of: 2)
        let reflectsY = periodic.alternatingReflections.contains(.y)
            && !cell.row.isMultiple(of: 2)
        let worldToLocal = worldToBaseCanonical(
            cell: cell,
            origin: origin
        )
        let parityToCanonical = Affine2D(
            xAxis: SIMD2(reflectsX ? -1 : 1, 0),
            yAxis: SIMD2(0, reflectsY ? -1 : 1),
            translation: SIMD2(
                reflectsX ? periodic.tileSize.width : 0,
                reflectsY ? periodic.tileSize.height : 0
            )
        )

        for compiledImage in compiled.images {
            let candidate = TilingImage(
                cell: cell,
                ordinal: compiledImage.ordinal,
                worldBounds: bounds,
                worldClip: worldClip,
                worldToCanonical: worldToLocal
                    .concatenating(parityToCanonical)
                    .concatenating(compiledImage.localToCanonical),
                operation: compiledImage.operation
            )
            if !result.contains(candidate) {
                if let maximumImageCount,
                   result.count >= maximumImageCount
                {
                    throw TilingProjectionError.fragmentCapacityExceeded(
                        maximum: maximumImageCount
                    )
                }
                result.append(candidate)
            }
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
            extent = repeatSize.width
        case .y:
            extent = repeatSize.height
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

    private var repeatSize: PatternSize {
        periodic.configuration.repeatSize
    }

    private var isAxisAligned: Bool {
        periodic.translationBasis.u.y == 0
            && periodic.translationBasis.v.x == 0
    }

    private func worldToBaseCanonical(
        cell: CellIndex,
        origin: SIMD2<Float>
    ) -> Affine2D {
        if periodic.phase == nil && !isAxisAligned {
            let subtractCell = Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                translation: SIMD2(
                    -Float(cell.column),
                    -Float(cell.row)
                )
            )
            let scaleToRaster = Affine2D(
                xAxis: SIMD2(periodic.tileSize.width, 0),
                yAxis: SIMD2(0, periodic.tileSize.height),
                translation: .zero
            )
            return periodic.worldToLattice
                .concatenating(subtractCell)
                .concatenating(scaleToRaster)
        }

        let worldToLocal = Affine2D(
            xAxis: SIMD2(1, 0),
            yAxis: SIMD2(0, 1),
            translation: -origin
        )
        if repeatSize == periodic.tileSize {
            return worldToLocal
        }
        return worldToLocal.concatenating(Affine2D(
            xAxis: SIMD2(periodic.tileSize.width / repeatSize.width, 0),
            yAxis: SIMD2(0, periodic.tileSize.height / repeatSize.height),
            translation: .zero
        ))
    }

    private func cellQuad(
        origin: SIMD2<Float>
    ) -> (
        SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>
    ) {
        if periodic.phase != nil || isAxisAligned {
            return (
                origin,
                origin + SIMD2(repeatSize.width, 0),
                origin + repeatSize.simd,
                origin + SIMD2(0, repeatSize.height)
            )
        }
        let u = periodic.translationBasis.u
        let v = periodic.translationBasis.v
        return (origin, origin + u, origin + u + v, origin + v)
    }

    private func cellIntersects(
        _ cell: CellIndex,
        worldBounds: AxisAlignedRect
    ) -> Bool {
        let vertices = cellQuad(origin: cellOrigin(for: cell))
        if pointInRect(vertices.0, worldBounds)
            || pointInRect(vertices.1, worldBounds)
            || pointInRect(vertices.2, worldBounds)
            || pointInRect(vertices.3, worldBounds)
        {
            return true
        }
        let clip = rectangularConvexClip(
            vertices.0, vertices.1, vertices.2, vertices.3
        )
        if clip.contains(worldBounds.minimum, tolerance: 0)
            || clip.contains(
                SIMD2(worldBounds.maximum.x, worldBounds.minimum.y),
                tolerance: 0
            )
            || clip.contains(worldBounds.maximum, tolerance: 0)
            || clip.contains(
                SIMD2(worldBounds.minimum.x, worldBounds.maximum.y),
                tolerance: 0
            )
        {
            return true
        }
        for cellIndex in 0 ..< 4 {
            let cellStart = rectangularPoint(vertices, at: cellIndex)
            let cellEnd = rectangularPoint(
                vertices,
                at: (cellIndex + 1) % 4
            )
            for rectIndex in 0 ..< 4 {
                let rectStart = rectangularRectCorner(
                    worldBounds,
                    at: rectIndex
                )
                let rectEnd = rectangularRectCorner(
                    worldBounds,
                    at: (rectIndex + 1) % 4
                )
                if segmentsIntersect(
                    cellStart,
                    cellEnd,
                    rectStart,
                    rectEnd
                ) {
                    return true
                }
            }
        }
        return false
    }
}

private func appendBoundedRectangularCell(
    _ cell: CellIndex,
    to cells: inout [CellIndex],
    maximumImageCount: Int?
) throws {
    if let maximumImageCount, cells.count >= maximumImageCount {
        throw TilingProjectionError.fragmentCapacityExceeded(
            maximum: maximumImageCount
        )
    }
    cells.append(cell)
}

private func bounds(
    enclosing points: [SIMD2<Float>]
) -> AxisAlignedRect {
    AxisAlignedRect(
        minimum: SIMD2(
            points.map(\.x).min()!,
            points.map(\.y).min()!
        ),
        maximum: SIMD2(
            points.map(\.x).max()!,
            points.map(\.y).max()!
        )
    )
}

private func rectangularBounds(
    _ point0: SIMD2<Float>,
    _ point1: SIMD2<Float>,
    _ point2: SIMD2<Float>,
    _ point3: SIMD2<Float>
) -> AxisAlignedRect {
    AxisAlignedRect(
        minimum: SIMD2(
            min(point0.x, point1.x, point2.x, point3.x),
            min(point0.y, point1.y, point2.y, point3.y)
        ),
        maximum: SIMD2(
            max(point0.x, point1.x, point2.x, point3.x),
            max(point0.y, point1.y, point2.y, point3.y)
        )
    )
}

private func rectangularPoint(
    _ points: (
        SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>
    ),
    at index: Int
) -> SIMD2<Float> {
    switch index {
    case 0: points.0
    case 1: points.1
    case 2: points.2
    case 3: points.3
    default: preconditionFailure("Quadrilateral index is out of range")
    }
}

private func rectangularRectCorner(
    _ bounds: AxisAlignedRect,
    at index: Int
) -> SIMD2<Float> {
    switch index {
    case 0: bounds.minimum
    case 1: SIMD2(bounds.maximum.x, bounds.minimum.y)
    case 2: bounds.maximum
    case 3: SIMD2(bounds.minimum.x, bounds.maximum.y)
    default: preconditionFailure("Rectangle corner index is out of range")
    }
}

private func rectangularConvexClip(
    _ point0: SIMD2<Float>,
    _ point1: SIMD2<Float>,
    _ point2: SIMD2<Float>,
    _ point3: SIMD2<Float>
) -> ConvexClip {
    let points = (point0, point1, point2, point3)
    return ConvexClip(halfPlaneCount: 4) { index in
        let start = rectangularPoint(points, at: index)
        let end = rectangularPoint(points, at: (index + 1) % 4)
        let edge = end - start
        let inward = simd_normalize(SIMD2(-edge.y, edge.x))
        return HalfPlane2D(
            normal: inward,
            offset: simd_dot(inward, start)
        )
    }
}

private func convexClip(
    forCounterclockwisePolygon vertices: [SIMD2<Float>]
) -> ConvexClip {
    ConvexClip(halfPlanes: vertices.indices.map { index in
        let start = vertices[index]
        let end = vertices[(index + 1) % vertices.count]
        let edge = end - start
        let inward = simd_normalize(SIMD2(-edge.y, edge.x))
        return HalfPlane2D(
            normal: inward,
            offset: simd_dot(inward, start)
        )
    })
}

private func axisAlignedClip(_ bounds: AxisAlignedRect) -> ConvexClip {
    ConvexClip(halfPlaneCount: 4) { index in
        switch index {
        case 0:
            HalfPlane2D(
                normal: SIMD2(1, 0),
                offset: bounds.minimum.x
            )
        case 1:
            HalfPlane2D(
                normal: SIMD2(-1, 0),
                offset: -bounds.maximum.x
            )
        case 2:
            HalfPlane2D(
                normal: SIMD2(0, 1),
                offset: bounds.minimum.y
            )
        default:
            HalfPlane2D(
                normal: SIMD2(0, -1),
                offset: -bounds.maximum.y
            )
        }
    }
}

private func pointInRect(
    _ point: SIMD2<Float>,
    _ rect: AxisAlignedRect
) -> Bool {
    point.x >= rect.minimum.x
        && point.x <= rect.maximum.x
        && point.y >= rect.minimum.y
        && point.y <= rect.maximum.y
}

private func segmentsIntersect(
    _ firstStart: SIMD2<Float>,
    _ firstEnd: SIMD2<Float>,
    _ secondStart: SIMD2<Float>,
    _ secondEnd: SIMD2<Float>
) -> Bool {
    let firstA = signedTurn(firstStart, firstEnd, secondStart)
    let firstB = signedTurn(firstStart, firstEnd, secondEnd)
    let secondA = signedTurn(secondStart, secondEnd, firstStart)
    let secondB = signedTurn(secondStart, secondEnd, firstEnd)
    return (firstA == 0 || firstB == 0 || firstA.sign != firstB.sign)
        && (secondA == 0 || secondB == 0 || secondA.sign != secondB.sign)
}

private func signedTurn(
    _ start: SIMD2<Float>,
    _ end: SIMD2<Float>,
    _ point: SIMD2<Float>
) -> Float {
    let edge = end - start
    let relative = point - start
    return edge.x * relative.y - edge.y * relative.x
}

private func parity(_ value: Int) -> Float {
    value.isMultiple(of: 2) ? 0 : 1
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
