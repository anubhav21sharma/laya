import simd

public struct CellFragment: Equatable, Sendable {
    public let cell: CellIndex
    public let imageOrdinal: UInt8
    public let canonicalFromBrush: Affine2D
    public let brushClip: ConvexClip

    public init(
        cell: CellIndex,
        imageOrdinal: UInt8,
        canonicalFromBrush: Affine2D,
        brushClip: ConvexClip
    ) {
        self.cell = cell
        self.imageOrdinal = imageOrdinal
        self.canonicalFromBrush = canonicalFromBrush
        self.brushClip = brushClip
    }
}

public enum TilingProjection {
    public static func clampedRadius(
        requested: Float,
        tileSize: PatternSize
    ) -> Float {
        precondition(
            requested.isFinite && requested >= 1,
            "TilingProjection radius must be finite and at least 1"
        )
        precondition(
            tileSize.width.isFinite && tileSize.height.isFinite,
            "TilingProjection tile dimensions must be finite"
        )
        return min(
            requested,
            1_000,
            4 * min(tileSize.width, tileSize.height)
        )
    }

    public static func fragments(
        for footprint: StampFootprint,
        using strategy: TilingStrategy
    ) -> [CellFragment] {
        let worldCorners = footprint.localBounds.corners.map {
            footprint.brushToWorld.applying(to: $0)
        }
        let worldBounds = bounds(enclosing: worldCorners)
        guard
            worldBounds.maximum.x > worldBounds.minimum.x,
            worldBounds.maximum.y > worldBounds.minimum.y
        else {
            return []
        }

        let images = strategy.images(intersecting: worldBounds)
        var candidates: [FragmentCandidate] = []
        candidates.reserveCapacity(images.count)

        for image in images
        where image.worldBounds.intersects(worldBounds) {
            let planes = brushLocalPlanes(
                for: image.worldBounds,
                brushToWorld: footprint.brushToWorld
            )
            let localPolygon = planes.reduce(
                footprint.localBounds.corners
            ) { polygon, plane in
                clip(polygon, to: plane)
            }
            guard localPolygon.count >= 3 else {
                continue
            }

            let worldPolygon = localPolygon.map {
                footprint.brushToWorld.applying(to: $0)
            }
            guard abs(signedArea(of: worldPolygon)) > 0.0001 else {
                continue
            }

            let canonicalFromBrush = footprint.brushToWorld.concatenating(
                image.worldToCanonical
            )
            candidates.append(
                FragmentCandidate(
                    fragment: CellFragment(
                        cell: image.cell,
                        imageOrdinal: image.ordinal,
                        canonicalFromBrush: canonicalFromBrush,
                        brushClip: ConvexClip(halfPlanes: planes)
                    ),
                    localPolygon: localPolygon
                )
            )
        }

        candidates = removingByteEqualCandidates(candidates)
        if
            strategy.kind == .rotational,
            footprint.coverageSymmetry == .halfTurnInvariant
        {
            candidates = removingCoverageEqualCandidates(candidates)
        }
        candidates.sort {
            fragmentPrecedes($0.fragment, $1.fragment)
        }
        return candidates.map(\.fragment)
    }
}

private struct FragmentCandidate {
    let fragment: CellFragment
    let localPolygon: [SIMD2<Float>]
}

private struct FragmentByteKey: Hashable {
    let words: [UInt64]

    init(_ fragment: CellFragment) {
        var words = [
            UInt64(bitPattern: Int64(fragment.cell.row)),
            UInt64(bitPattern: Int64(fragment.cell.column)),
            UInt64(fragment.imageOrdinal),
        ]
        words.append(contentsOf: affineScalars(fragment.canonicalFromBrush).map {
            UInt64($0.bitPattern)
        })
        words.append(UInt64(fragment.brushClip.halfPlanes.count))
        for plane in fragment.brushClip.halfPlanes {
            words.append(UInt64(plane.normal.x.bitPattern))
            words.append(UInt64(plane.normal.y.bitPattern))
            words.append(UInt64(plane.offset.bitPattern))
        }
        self.words = words
    }
}

private struct CoverageDomainKey: Hashable {
    let centerX: UInt32
    let centerY: UInt32
    let xAxisLength: UInt32
    let yAxisLength: UInt32
    let polygon: [UInt32]

    init(_ candidate: FragmentCandidate) {
        let affine = candidate.fragment.canonicalFromBrush
        centerX = normalizedZero(affine.translation.x).bitPattern
        centerY = normalizedZero(affine.translation.y).bitPattern
        xAxisLength = normalizedZero(simd_length(affine.xAxis)).bitPattern
        yAxisLength = normalizedZero(simd_length(affine.yAxis)).bitPattern
        polygon = canonicalPolygonKey(
            candidate.localPolygon.map {
                affine.applying(to: $0)
            }
        )
    }
}

private struct CanonicalVertex: Equatable {
    let x: Float
    let y: Float

    init(_ point: SIMD2<Float>) {
        x = normalizedZero(point.x)
        y = normalizedZero(point.y)
    }
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

private func brushLocalPlanes(
    for worldBounds: AxisAlignedRect,
    brushToWorld: Affine2D
) -> [HalfPlane2D] {
    [
        brushLocalPlane(
            worldNormal: SIMD2(1, 0),
            worldOffset: worldBounds.minimum.x,
            brushToWorld: brushToWorld
        ),
        brushLocalPlane(
            worldNormal: SIMD2(-1, 0),
            worldOffset: -worldBounds.maximum.x,
            brushToWorld: brushToWorld
        ),
        brushLocalPlane(
            worldNormal: SIMD2(0, 1),
            worldOffset: worldBounds.minimum.y,
            brushToWorld: brushToWorld
        ),
        brushLocalPlane(
            worldNormal: SIMD2(0, -1),
            worldOffset: -worldBounds.maximum.y,
            brushToWorld: brushToWorld
        ),
    ]
}

private func brushLocalPlane(
    worldNormal: SIMD2<Float>,
    worldOffset: Float,
    brushToWorld: Affine2D
) -> HalfPlane2D {
    let localNormalUnscaled = SIMD2<Float>(
        simd_dot(worldNormal, brushToWorld.xAxis),
        simd_dot(worldNormal, brushToWorld.yAxis)
    )
    let localOffsetUnscaled = worldOffset
        - simd_dot(worldNormal, brushToWorld.translation)
    let length = simd_length(localNormalUnscaled)
    precondition(
        length.isFinite && length > 0 && localOffsetUnscaled.isFinite,
        "TilingProjection mapped cell plane must be finite and nonzero"
    )
    return HalfPlane2D(
        normal: localNormalUnscaled / length,
        offset: localOffsetUnscaled / length
    )
}

private func clip(
    _ polygon: [SIMD2<Float>],
    to plane: HalfPlane2D
) -> [SIMD2<Float>] {
    guard let last = polygon.last else {
        return []
    }

    var result: [SIMD2<Float>] = []
    result.reserveCapacity(polygon.count + 1)
    var start = last
    var startInside = plane.contains(start, tolerance: 0)

    for end in polygon {
        let endInside = plane.contains(end, tolerance: 0)
        if endInside {
            if !startInside {
                result.append(intersection(from: start, to: end, with: plane))
            }
            result.append(end)
        } else if startInside {
            result.append(intersection(from: start, to: end, with: plane))
        }
        start = end
        startInside = endInside
    }
    return result
}

private func intersection(
    from start: SIMD2<Float>,
    to end: SIMD2<Float>,
    with plane: HalfPlane2D
) -> SIMD2<Float> {
    let direction = end - start
    let denominator = simd_dot(plane.normal, direction)
    precondition(
        denominator.isFinite && denominator != 0,
        "TilingProjection clip intersection must be finite and nonparallel"
    )
    let distance = plane.offset - simd_dot(plane.normal, start)
    let parameter = distance / denominator
    precondition(
        parameter.isFinite,
        "TilingProjection clip parameter must be finite"
    )
    return start + direction * parameter
}

private func signedArea(of polygon: [SIMD2<Float>]) -> Float {
    guard polygon.count >= 3 else {
        return 0
    }
    let origin = polygon[0]
    var twiceArea: Float = 0
    for index in 1..<(polygon.count - 1) {
        let first = polygon[index] - origin
        let second = polygon[index + 1] - origin
        twiceArea += first.x * second.y - first.y * second.x
    }
    return twiceArea * 0.5
}

private func removingByteEqualCandidates(
    _ candidates: [FragmentCandidate]
) -> [FragmentCandidate] {
    var seen: Set<FragmentByteKey> = []
    return candidates.filter {
        seen.insert(FragmentByteKey($0.fragment)).inserted
    }
}

private func removingCoverageEqualCandidates(
    _ candidates: [FragmentCandidate]
) -> [FragmentCandidate] {
    var seen: Set<CoverageDomainKey> = []
    return candidates.filter {
        seen.insert(CoverageDomainKey($0)).inserted
    }
}

private func canonicalPolygonKey(
    _ polygon: [SIMD2<Float>]
) -> [UInt32] {
    var vertices = polygon.map(CanonicalVertex.init)
    vertices = removingConsecutiveDuplicates(vertices)
    guard !vertices.isEmpty else {
        return []
    }

    var orientations = [vertices]
    orientations.append(Array(vertices.reversed()))
    var best: [CanonicalVertex]?
    for orientation in orientations {
        for startIndex in orientation.indices {
            let rotated = Array(
                orientation[startIndex...] + orientation[..<startIndex]
            )
            if best == nil || verticesPrecede(rotated, best!) {
                best = rotated
            }
        }
    }

    return best!.flatMap { [$0.x.bitPattern, $0.y.bitPattern] }
}

private func removingConsecutiveDuplicates(
    _ vertices: [CanonicalVertex]
) -> [CanonicalVertex] {
    var result: [CanonicalVertex] = []
    for vertex in vertices where result.last != vertex {
        result.append(vertex)
    }
    if result.count > 1 && result.first == result.last {
        result.removeLast()
    }
    return result
}

private func verticesPrecede(
    _ lhs: [CanonicalVertex],
    _ rhs: [CanonicalVertex]
) -> Bool {
    for (left, right) in zip(lhs, rhs) {
        if left.x != right.x {
            return floatPrecedes(left.x, right.x)
        }
        if left.y != right.y {
            return floatPrecedes(left.y, right.y)
        }
    }
    return lhs.count < rhs.count
}

private func fragmentPrecedes(
    _ lhs: CellFragment,
    _ rhs: CellFragment
) -> Bool {
    if lhs.cell.row != rhs.cell.row {
        return lhs.cell.row < rhs.cell.row
    }
    if lhs.cell.column != rhs.cell.column {
        return lhs.cell.column < rhs.cell.column
    }
    if lhs.imageOrdinal != rhs.imageOrdinal {
        return lhs.imageOrdinal < rhs.imageOrdinal
    }

    let lhsScalars = affineScalars(lhs.canonicalFromBrush)
        + clipScalars(lhs.brushClip)
    let rhsScalars = affineScalars(rhs.canonicalFromBrush)
        + clipScalars(rhs.brushClip)
    for (left, right) in zip(lhsScalars, rhsScalars) {
        if left != right || left.bitPattern != right.bitPattern {
            return floatPrecedes(left, right)
        }
    }
    return lhsScalars.count < rhsScalars.count
}

private func affineScalars(_ affine: Affine2D) -> [Float] {
    [
        affine.xAxis.x,
        affine.xAxis.y,
        affine.yAxis.x,
        affine.yAxis.y,
        affine.translation.x,
        affine.translation.y,
    ]
}

private func clipScalars(_ clip: ConvexClip) -> [Float] {
    clip.halfPlanes.flatMap {
        [$0.normal.x, $0.normal.y, $0.offset]
    }
}

private func floatPrecedes(_ lhs: Float, _ rhs: Float) -> Bool {
    if lhs != rhs {
        return lhs < rhs
    }
    return lhs.bitPattern < rhs.bitPattern
}

private func normalizedZero(_ value: Float) -> Float {
    value == 0 ? 0 : value
}
