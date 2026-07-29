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
        var polygonA: [SIMD2<Float>] = []
        var polygonB: [SIMD2<Float>] = []
        var result: [TilingImage] = []
        populateImages(
            intersecting: worldBounds,
            polygonA: &polygonA,
            polygonB: &polygonB,
            result: &result
        )
        return result
    }

    func populateImages(
        intersecting worldBounds: AxisAlignedRect,
        polygonA: inout [SIMD2<Float>],
        polygonB: inout [SIMD2<Float>],
        result: inout [TilingImage]
    ) {
        result.removeAll(keepingCapacity: true)
        let canvasBounds = AxisAlignedRect(
            minimum: .zero,
            maximum: SIMD2(
                Float(radial.canvasSize.width),
                Float(radial.canvasSize.height)
            )
        )
        guard canvasBounds.intersects(worldBounds) else { return }

        guard let layout = radial.layout else {
            radialSetRectangle(canvasBounds, into: &polygonA)
            radialClipInPlace(
                &polygonA,
                scratch: &polygonB,
                to: worldBounds
            )
            radialAppendTriangulatedImages(
                polygon: &polygonA,
                cell: CellIndex(column: 0, row: 0),
                ordinal: 0,
                worldToCanonical: .identity,
                operation: .identity,
                result: &result
            )
            return
        }

        for image in compiled.images {
            let logicalToWorld = image.localToCanonical.inverted()
            for page in layout.residentPages {
                radialSetRectangle(
                    layout.logicalPageBounds(page),
                    into: &polygonA
                )
                radialClipToCanonicalSectorInPlace(
                    &polygonA,
                    scratch: &polygonB,
                    angle: radial.sectorAngleRadians
                )
                guard polygonA.count >= 3 else { continue }

                for index in polygonA.indices {
                    polygonA[index] = logicalToWorld.applying(
                        to: polygonA[index]
                    )
                }
                let preliminaryBounds = radialBounds(polygonA)
                guard preliminaryBounds.intersects(worldBounds),
                      preliminaryBounds.intersects(canvasBounds)
                else {
                    continue
                }
                radialClipInPlace(
                    &polygonA,
                    scratch: &polygonB,
                    to: canvasBounds
                )
                guard polygonA.count >= 3 else { continue }

                let worldToAtlas = image.localToCanonical.concatenating(
                    layout.logicalToAtlas(for: page)
                )
                radialAppendTriangulatedImages(
                    polygon: &polygonA,
                    cell: CellIndex(
                        column: page.coordinate.x,
                        row: page.coordinate.y
                    ),
                    ordinal: image.ordinal,
                    worldToCanonical: worldToAtlas,
                    operation: image.operation,
                    result: &result
                )
            }
        }
        result.sort(by: radialImagePrecedes)
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

private func radialSetRectangle(
    _ bounds: AxisAlignedRect,
    into polygon: inout [SIMD2<Float>]
) {
    polygon.removeAll(keepingCapacity: true)
    polygon.append(bounds.minimum)
    polygon.append(SIMD2(bounds.maximum.x, bounds.minimum.y))
    polygon.append(bounds.maximum)
    polygon.append(SIMD2(bounds.minimum.x, bounds.maximum.y))
}

private func radialClipToCanonicalSectorInPlace(
    _ polygon: inout [SIMD2<Float>],
    scratch: inout [SIMD2<Float>],
    angle: Float
) {
    radialClipInPlace(
        &polygon,
        scratch: &scratch,
        to: HalfPlane2D(normal: SIMD2(0, 1), offset: 0)
    )
    let direction = SIMD2(cos(angle), sin(angle))
    radialClipInPlace(
        &polygon,
        scratch: &scratch,
        to: HalfPlane2D(
            normal: SIMD2(direction.y, -direction.x),
            offset: 0
        )
    )
}

private func radialClipInPlace(
    _ polygon: inout [SIMD2<Float>],
    scratch: inout [SIMD2<Float>],
    to bounds: AxisAlignedRect
) {
    radialClipInPlace(
        &polygon,
        scratch: &scratch,
        to: HalfPlane2D(
            normal: SIMD2(1, 0),
            offset: bounds.minimum.x
        )
    )
    radialClipInPlace(
        &polygon,
        scratch: &scratch,
        to: HalfPlane2D(
            normal: SIMD2(-1, 0),
            offset: -bounds.maximum.x
        )
    )
    radialClipInPlace(
        &polygon,
        scratch: &scratch,
        to: HalfPlane2D(
            normal: SIMD2(0, 1),
            offset: bounds.minimum.y
        )
    )
    radialClipInPlace(
        &polygon,
        scratch: &scratch,
        to: HalfPlane2D(
            normal: SIMD2(0, -1),
            offset: -bounds.maximum.y
        )
    )
}

private func radialClipInPlace(
    _ polygon: inout [SIMD2<Float>],
    scratch: inout [SIMD2<Float>],
    to plane: HalfPlane2D
) {
    scratch.removeAll(keepingCapacity: true)
    guard let last = polygon.last else { return }
    var start = last
    var startDistance = simd_dot(plane.normal, start) - plane.offset
    for end in polygon {
        let endDistance = simd_dot(plane.normal, end) - plane.offset
        let startInside = startDistance >= 0
        let endInside = endDistance >= 0
        if startInside != endInside {
            let parameter =
                startDistance / (startDistance - endDistance)
            let intersection = start + (end - start) * parameter
            if scratch.last != intersection {
                scratch.append(intersection)
            }
        }
        if endInside, scratch.last != end {
            scratch.append(end)
        }
        start = end
        startDistance = endDistance
    }
    if scratch.count > 1, scratch.first == scratch.last {
        scratch.removeLast()
    }
    swap(&polygon, &scratch)
}

private func radialAppendTriangulatedImages(
    polygon: inout [SIMD2<Float>],
    cell: CellIndex,
    ordinal: UInt8,
    worldToCanonical: Affine2D,
    operation: CompiledGroupOperation,
    result: inout [TilingImage]
) {
    guard polygon.count >= 3 else { return }
    if radialSignedArea(polygon) < 0 {
        polygon.reverse()
    }
    let origin = polygon[0]
    for index in 1 ..< (polygon.count - 1) {
        let point1 = polygon[index]
        let point2 = polygon[index + 1]
        let twiceArea =
            (point1.x - origin.x) * (point2.y - origin.y)
                - (point1.y - origin.y) * (point2.x - origin.x)
        guard abs(twiceArea * 0.5) > 0.0001 else { continue }
        result.append(
            TilingImage(
                cell: cell,
                ordinal: ordinal,
                worldBounds: radialTriangleBounds(
                    origin,
                    point1,
                    point2
                ),
                worldClip: radialTriangleClip(
                    origin,
                    point1,
                    point2
                ),
                worldToCanonical: worldToCanonical,
                operation: operation
            )
        )
    }
}

private func radialTriangleBounds(
    _ point0: SIMD2<Float>,
    _ point1: SIMD2<Float>,
    _ point2: SIMD2<Float>
) -> AxisAlignedRect {
    AxisAlignedRect(
        minimum: SIMD2(
            min(point0.x, point1.x, point2.x),
            min(point0.y, point1.y, point2.y)
        ),
        maximum: SIMD2(
            max(point0.x, point1.x, point2.x),
            max(point0.y, point1.y, point2.y)
        )
    )
}

private func radialTrianglePoint(
    _ point0: SIMD2<Float>,
    _ point1: SIMD2<Float>,
    _ point2: SIMD2<Float>,
    at index: Int
) -> SIMD2<Float> {
    switch index {
    case 0: point0
    case 1: point1
    case 2: point2
    default: preconditionFailure("Triangle index is out of range")
    }
}

private func radialTriangleClip(
    _ point0: SIMD2<Float>,
    _ point1: SIMD2<Float>,
    _ point2: SIMD2<Float>
) -> ConvexClip {
    ConvexClip(halfPlaneCount: 3) { index in
        let start = radialTrianglePoint(
            point0, point1, point2, at: index
        )
        let end = radialTrianglePoint(
            point0, point1, point2, at: (index + 1) % 3
        )
        let edge = end - start
        let inward = simd_normalize(SIMD2(-edge.y, edge.x))
        return HalfPlane2D(
            normal: inward,
            offset: simd_dot(inward, start)
        )
    }
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
