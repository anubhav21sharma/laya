import Foundation
import simd

struct RadialSymmetryKernel: Equatable, Sendable {
    let compiled: CompiledSymmetry
    let finite: CompiledFiniteDomain
    let radial: CompiledRadialDomain

    init(compiled: CompiledSymmetry) {
        precondition(compiled.family == .radial)
        guard case let .finite(finite) = compiled.domain else {
            preconditionFailure(
                "RadialSymmetryKernel requires a finite descriptor"
            )
        }
        self.compiled = compiled
        self.finite = finite
        radial = finite.radial
    }

    func cell(containing point: WorldPoint) -> CellIndex {
        guard let logical = foldedLogicalPoint(point.simd),
              let layout = radial.layout,
              let page = layout.residentPage(containing: logical)
        else {
            return CellIndex(column: 0, row: 0)
        }
        return CellIndex(
            column: page.coordinate.x,
            row: page.coordinate.y
        )
    }

    func displayFold(_ point: WorldPoint) -> CanonicalPoint {
        guard let logical = foldedLogicalPoint(point.simd) else {
            return CanonicalPoint(x: -1, y: -1)
        }
        guard let layout = radial.layout else {
            return CanonicalPoint(x: logical.x, y: logical.y)
        }
        guard let atlas = layout.atlasPoint(forLogical: logical) else {
            return CanonicalPoint(x: -1, y: -1)
        }
        return CanonicalPoint(x: atlas.x, y: atlas.y)
    }

    func images(
        intersecting worldBounds: AxisAlignedRect
    ) -> [TilingImage] {
        let canvasBounds = AxisAlignedRect(
            minimum: .zero,
            maximum: SIMD2(
                Float(radial.canvasSize.width),
                Float(radial.canvasSize.height)
            )
        )
        guard canvasBounds.intersects(worldBounds) else { return [] }

        guard let layout = radial.layout else {
            let clipped = radialClipPolygon(
                canvasBounds.corners,
                to: worldBounds
            )
            return radialTriangulatedImages(
                polygon: clipped,
                cell: CellIndex(column: 0, row: 0),
                ordinal: 0,
                worldToCanonical: .identity,
                operation: .identity
            )
        }

        var result: [TilingImage] = []
        for image in compiled.images {
            let logicalToWorld = image.localToCanonical.inverted()
            for page in layout.residentPages {
                var logicalPolygon = layout.logicalPageBounds(page).corners
                logicalPolygon = radialClipToCanonicalSector(
                    logicalPolygon,
                    angle: radial.sectorAngleRadians
                )
                guard logicalPolygon.count >= 3 else { continue }

                var worldPolygon = logicalPolygon.map(
                    logicalToWorld.applying
                )
                let preliminaryBounds = radialBounds(worldPolygon)
                guard preliminaryBounds.intersects(worldBounds),
                      preliminaryBounds.intersects(canvasBounds)
                else {
                    continue
                }
                worldPolygon = radialClipPolygon(
                    worldPolygon,
                    to: canvasBounds
                )
                guard worldPolygon.count >= 3 else { continue }

                let worldToAtlas = image.localToCanonical.concatenating(
                    layout.logicalToAtlas(for: page)
                )
                result.append(contentsOf: radialTriangulatedImages(
                    polygon: worldPolygon,
                    cell: CellIndex(
                        column: page.coordinate.x,
                        row: page.coordinate.y
                    ),
                    ordinal: image.ordinal,
                    worldToCanonical: worldToAtlas,
                    operation: image.operation
                ))
            }
        }
        result.sort(by: radialImagePrecedes)
        return result
    }

    private func foldedLogicalPoint(
        _ point: SIMD2<Float>
    ) -> SIMD2<Float>? {
        guard radialCanvasContains(point, size: radial.canvasSize) else {
            return nil
        }
        guard let configuration = radial.configuration else {
            return point
        }
        let relative = point - configuration.center.simd
        let radius = simd_length(relative)
        if radius == 0 {
            return .zero
        }
        var angle = atan2(relative.y, relative.x)
            - configuration.referenceAngleRadians
        let fullTurn = 2 * Float.pi
        angle = angle.truncatingRemainder(dividingBy: fullTurn)
        if angle < 0 { angle += fullTurn }
        let sectorAngle = radial.sectorAngleRadians
        var sector = Int(floor(angle / sectorAngle))
        sector = min(sector, radial.displayedSectorCount - 1)
        var localAngle = angle - Float(sector) * sectorAngle
        if configuration.kind != .rotation && !sector.isMultiple(of: 2) {
            localAngle = sectorAngle - localAngle
        }
        if localAngle == sectorAngle {
            localAngle = sectorAngle.nextDown
        }
        return SIMD2(
            radius * cos(localAngle),
            radius * sin(localAngle)
        )
    }
}

private func radialCanvasContains(
    _ point: SIMD2<Float>,
    size: PixelSize
) -> Bool {
    point.x.isFinite && point.y.isFinite
        && point.x >= 0 && point.y >= 0
        && point.x < Float(size.width)
        && point.y < Float(size.height)
}

private func radialClipToCanonicalSector(
    _ polygon: [SIMD2<Float>],
    angle: Float
) -> [SIMD2<Float>] {
    var result = radialClip(
        polygon,
        to: HalfPlane2D(normal: SIMD2(0, 1), offset: 0)
    )
    let direction = SIMD2(cos(angle), sin(angle))
    result = radialClip(
        result,
        to: HalfPlane2D(
            normal: SIMD2(direction.y, -direction.x),
            offset: 0
        )
    )
    return result
}

private func radialClipPolygon(
    _ polygon: [SIMD2<Float>],
    to bounds: AxisAlignedRect
) -> [SIMD2<Float>] {
    [
        HalfPlane2D(normal: SIMD2(1, 0), offset: bounds.minimum.x),
        HalfPlane2D(normal: SIMD2(-1, 0), offset: -bounds.maximum.x),
        HalfPlane2D(normal: SIMD2(0, 1), offset: bounds.minimum.y),
        HalfPlane2D(normal: SIMD2(0, -1), offset: -bounds.maximum.y),
    ].reduce(polygon, radialClip)
}

private func radialClip(
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
        if startInside != endInside {
            let parameter =
                startDistance / (startDistance - endDistance)
            result.append(start + (end - start) * parameter)
        }
        if endInside { result.append(end) }
        start = end
        startDistance = endDistance
    }
    return radialRemovingConsecutiveDuplicates(result)
}

private func radialTriangulatedImages(
    polygon: [SIMD2<Float>],
    cell: CellIndex,
    ordinal: UInt8,
    worldToCanonical: Affine2D,
    operation: CompiledGroupOperation
) -> [TilingImage] {
    guard polygon.count >= 3 else { return [] }
    let oriented = radialSignedArea(polygon) < 0
        ? Array(polygon.reversed())
        : polygon
    return (1..<(oriented.count - 1)).compactMap { index in
        let triangle = [
            oriented[0],
            oriented[index],
            oriented[index + 1],
        ]
        guard abs(radialSignedArea(triangle)) > 0.0001 else {
            return nil
        }
        return TilingImage(
            cell: cell,
            ordinal: ordinal,
            worldBounds: radialBounds(triangle),
            worldClip: radialConvexClip(triangle),
            worldToCanonical: worldToCanonical,
            operation: operation
        )
    }
}

private func radialConvexClip(
    _ counterclockwise: [SIMD2<Float>]
) -> ConvexClip {
    ConvexClip(halfPlanes: counterclockwise.indices.map { index in
        let start = counterclockwise[index]
        let end = counterclockwise[
            (index + 1) % counterclockwise.count
        ]
        let edge = end - start
        let inward = simd_normalize(SIMD2(-edge.y, edge.x))
        return HalfPlane2D(
            normal: inward,
            offset: simd_dot(inward, start)
        )
    })
}

private func radialBounds(
    _ points: [SIMD2<Float>]
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

private func radialSignedArea(
    _ polygon: [SIMD2<Float>]
) -> Float {
    guard polygon.count >= 3 else { return 0 }
    var twiceArea: Float = 0
    for index in polygon.indices {
        let next = (index + 1) % polygon.count
        twiceArea += polygon[index].x * polygon[next].y
            - polygon[index].y * polygon[next].x
    }
    return twiceArea * 0.5
}

private func radialRemovingConsecutiveDuplicates(
    _ polygon: [SIMD2<Float>]
) -> [SIMD2<Float>] {
    var result: [SIMD2<Float>] = []
    for point in polygon where result.last != point {
        result.append(point)
    }
    if result.count > 1, result.first == result.last {
        result.removeLast()
    }
    return result
}

private func radialImagePrecedes(
    _ lhs: TilingImage,
    _ rhs: TilingImage
) -> Bool {
    if lhs.cell.row != rhs.cell.row {
        return lhs.cell.row < rhs.cell.row
    }
    if lhs.cell.column != rhs.cell.column {
        return lhs.cell.column < rhs.cell.column
    }
    if lhs.ordinal != rhs.ordinal {
        return lhs.ordinal < rhs.ordinal
    }
    let l = lhs.worldBounds.minimum
    let r = rhs.worldBounds.minimum
    return l.y == r.y ? l.x < r.x : l.y < r.y
}

private extension SIMD2 where Scalar == Float {
    var isFinite: Bool { x.isFinite && y.isFinite }
}
