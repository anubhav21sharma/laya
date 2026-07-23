import Foundation
import simd

struct TriangularSymmetryKernel: Equatable, Sendable {
    let compiled: CompiledSymmetry
    let periodic: CompiledPeriodicDomain

    init(compiled: CompiledSymmetry) {
        precondition(compiled.family == .triangular)
        guard case let .periodic(periodic) = compiled.domain else {
            preconditionFailure(
                "TriangularSymmetryKernel requires a periodic descriptor"
            )
        }
        self.compiled = compiled
        self.periodic = periodic
    }

    func cell(containing point: WorldPoint) -> CellIndex {
        let lattice = periodic.worldToLattice.applying(to: point.simd)
        return CellIndex(
            column: checkedTriangularCellIndex(lattice.x, axis: "x"),
            row: checkedTriangularCellIndex(lattice.y, axis: "y")
        )
    }

    func displayFold(_ point: WorldPoint) -> CanonicalPoint {
        let lattice = periodic.worldToLattice.applying(to: point.simd)
        let local = SIMD2(
            triangularPositiveModulo(lattice.x, extent: 1),
            triangularPositiveModulo(lattice.y, extent: 1)
        )
        return CanonicalPoint(
            x: local.x * periodic.tileSize.width,
            y: local.y * periodic.tileSize.height
        )
    }

    func images(
        intersecting worldBounds: AxisAlignedRect
    ) -> [TilingImage] {
        var result: [TilingImage] = []
        for image in compiled.images {
            let worldToTransformedRaster =
                compiled.rasterMetric.worldToRaster
                    .concatenating(image.localToCanonical)
            let transformedCorners = worldBounds.corners.map(
                worldToTransformedRaster.applying
            )
            let transformedBounds = triangularBounds(
                enclosing: transformedCorners
            )
            guard
                let columns = triangularIntersectingIndices(
                    minimum: transformedBounds.minimum.x,
                    maximum: transformedBounds.maximum.x,
                    extent: periodic.tileSize.width,
                    axis: "x"
                ),
                let rows = triangularIntersectingIndices(
                    minimum: transformedBounds.minimum.y,
                    maximum: transformedBounds.maximum.y,
                    extent: periodic.tileSize.height,
                    axis: "y"
                )
            else {
                continue
            }

            let transformedRasterToWorld =
                worldToTransformedRaster.inverted()
            for row in rows {
                for column in columns {
                    let targetOrigin = SIMD2(
                        Float(column) * periodic.tileSize.width,
                        Float(row) * periodic.tileSize.height
                    )
                    var preimageVertices = [
                        targetOrigin,
                        targetOrigin + SIMD2(periodic.tileSize.width, 0),
                        targetOrigin + periodic.tileSize.simd,
                        targetOrigin + SIMD2(0, periodic.tileSize.height),
                    ].map(transformedRasterToWorld.applying)
                    if triangularSignedArea(preimageVertices) < 0 {
                        preimageVertices.reverse()
                    }
                    let preimageBounds = triangularBounds(
                        enclosing: preimageVertices
                    )
                    guard preimageBounds.intersects(worldBounds) else {
                        continue
                    }
                    let canonicalTranslation = Affine2D(
                        xAxis: SIMD2(1, 0),
                        yAxis: SIMD2(0, 1),
                        translation: -targetOrigin
                    )
                    result.append(
                        TilingImage(
                            cell: CellIndex(
                                column: column,
                                row: row
                            ),
                            ordinal: image.ordinal,
                            worldBounds: preimageBounds,
                            worldClip: triangularConvexClip(
                                counterclockwise: preimageVertices
                            ),
                            worldToCanonical: worldToTransformedRaster.concatenating(
                                canonicalTranslation
                            ),
                            operation: image.operation
                        )
                    )
                }
            }
        }
        result.sort(by: triangularImagePrecedes)
        return result
    }
}

private func triangularIntersectingIndices(
    minimum: Float,
    maximum: Float,
    extent: Float,
    axis: String
) -> ClosedRange<Int>? {
    precondition(
        minimum.isFinite && maximum.isFinite && extent.isFinite && extent > 0,
        "Triangular \(axis) enumeration inputs must be finite"
    )
    guard maximum > minimum else { return nil }
    let first = checkedTriangularCellIndex(
        minimum / extent,
        axis: axis
    )
    let last = checkedTriangularCellIndex(
        maximum.nextDown / extent,
        axis: axis
    )
    guard last >= first else { return nil }
    return first ... last
}

private func checkedTriangularCellIndex(
    _ latticeCoordinate: Float,
    axis: String
) -> Int {
    precondition(
        latticeCoordinate.isFinite,
        "Triangular \(axis) lattice coordinate must be finite"
    )
    let floored = floor(Double(latticeCoordinate))
    precondition(
        floored >= Double(Int.min) && floored <= Double(Int.max),
        "Triangular \(axis) cell index must fit Int"
    )
    let result = Int(floored)
    precondition(
        Float(result).isFinite,
        "Triangular \(axis) cell index must convert to Float"
    )
    return result
}

private func triangularPositiveModulo(
    _ value: Float,
    extent: Float
) -> Float {
    let normalized = abs(value) < Float.leastNormalMagnitude ? 0 : value
    let remainder = normalized.truncatingRemainder(dividingBy: extent)
    if remainder == 0 || abs(remainder) < Float.leastNormalMagnitude {
        return 0
    }
    if remainder < 0 {
        return min(remainder + extent, extent.nextDown)
    }
    return remainder
}

private func triangularBounds(
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

private func triangularConvexClip(
    counterclockwise vertices: [SIMD2<Float>]
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

private func triangularSignedArea(
    _ vertices: [SIMD2<Float>]
) -> Float {
    guard vertices.count >= 3 else { return 0 }
    var twiceArea: Float = 0
    for index in vertices.indices {
        let first = vertices[index]
        let second = vertices[(index + 1) % vertices.count]
        twiceArea += first.x * second.y - first.y * second.x
    }
    return twiceArea * 0.5
}

private func triangularImagePrecedes(
    _ lhs: TilingImage,
    _ rhs: TilingImage
) -> Bool {
    if lhs.cell.row != rhs.cell.row {
        return lhs.cell.row < rhs.cell.row
    }
    if lhs.cell.column != rhs.cell.column {
        return lhs.cell.column < rhs.cell.column
    }
    return lhs.ordinal < rhs.ordinal
}
