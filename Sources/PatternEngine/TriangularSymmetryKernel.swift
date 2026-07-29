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
        populateImages(intersecting: worldBounds, result: &result)
        return result
    }

    func populateImages(
        intersecting worldBounds: AxisAlignedRect,
        result: inout [TilingImage]
    ) {
        result.removeAll(keepingCapacity: true)
        for image in compiled.images {
            let worldToTransformedRaster =
                compiled.rasterMetric.worldToRaster
                    .concatenating(image.localToCanonical)
            let transformed0 = worldToTransformedRaster.applying(
                to: worldBounds.minimum
            )
            let transformed1 = worldToTransformedRaster.applying(
                to: SIMD2(
                    worldBounds.maximum.x,
                    worldBounds.minimum.y
                )
            )
            let transformed2 = worldToTransformedRaster.applying(
                to: worldBounds.maximum
            )
            let transformed3 = worldToTransformedRaster.applying(
                to: SIMD2(
                    worldBounds.minimum.x,
                    worldBounds.maximum.y
                )
            )
            let transformedBounds = triangularBounds(
                transformed0, transformed1, transformed2, transformed3
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
                    var preimage0 = transformedRasterToWorld.applying(
                        to: targetOrigin
                    )
                    var preimage1 = transformedRasterToWorld.applying(
                        to: targetOrigin
                            + SIMD2(periodic.tileSize.width, 0)
                    )
                    var preimage2 = transformedRasterToWorld.applying(
                        to: targetOrigin + periodic.tileSize.simd
                    )
                    var preimage3 = transformedRasterToWorld.applying(
                        to: targetOrigin
                            + SIMD2(0, periodic.tileSize.height)
                    )
                    if triangularSignedArea(
                        preimage0, preimage1, preimage2, preimage3
                    ) < 0 {
                        swap(&preimage0, &preimage3)
                        swap(&preimage1, &preimage2)
                    }
                    let preimageBounds = triangularBounds(
                        preimage0, preimage1, preimage2, preimage3
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
                                preimage0,
                                preimage1,
                                preimage2,
                                preimage3
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

private func triangularBounds(
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

private func triangularPoint(
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

private func triangularConvexClip(
    _ point0: SIMD2<Float>,
    _ point1: SIMD2<Float>,
    _ point2: SIMD2<Float>,
    _ point3: SIMD2<Float>
) -> ConvexClip {
    let points = (point0, point1, point2, point3)
    return ConvexClip(halfPlaneCount: 4) { index in
        let start = triangularPoint(points, at: index)
        let end = triangularPoint(points, at: (index + 1) % 4)
        let edge = end - start
        let inward = simd_normalize(SIMD2(-edge.y, edge.x))
        return HalfPlane2D(
            normal: inward,
            offset: simd_dot(inward, start)
        )
    }
}

private func triangularSignedArea(
    _ point0: SIMD2<Float>,
    _ point1: SIMD2<Float>,
    _ point2: SIMD2<Float>,
    _ point3: SIMD2<Float>
) -> Float {
    let points = (point0, point1, point2, point3)
    var twiceArea: Float = 0
    for index in 0 ..< 4 {
        let first = triangularPoint(points, at: index)
        let second = triangularPoint(points, at: (index + 1) % 4)
        twiceArea += first.x * second.y - first.y * second.x
    }
    return twiceArea * 0.5
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
