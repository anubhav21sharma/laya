import Foundation
import simd

public struct CellFragment: Equatable, Sendable {
    public let cell: CellIndex
    public let imageOrdinal: UInt8
    public let canonicalFromBrush: Affine2D
    public let brushClip: ConvexClip
    public let operation: CompiledGroupOperation

    public init(
        cell: CellIndex,
        imageOrdinal: UInt8,
        canonicalFromBrush: Affine2D,
        brushClip: ConvexClip
    ) {
        self.init(
            cell: cell,
            imageOrdinal: imageOrdinal,
            canonicalFromBrush: canonicalFromBrush,
            brushClip: brushClip,
            operation: .identity
        )
    }

    public init(
        cell: CellIndex,
        imageOrdinal: UInt8,
        canonicalFromBrush: Affine2D,
        brushClip: ConvexClip,
        operation: CompiledGroupOperation
    ) {
        self.cell = cell
        self.imageOrdinal = imageOrdinal
        self.canonicalFromBrush = canonicalFromBrush
        self.brushClip = brushClip
        self.operation = operation
    }
}

public enum TilingProjection {
    public static func dirtyPixelRect(
        for fragment: CellFragment,
        radius: Float
    ) -> PixelRect {
        precondition(radius.isFinite && radius > 0)
        let expansion = 1 + 1 / radius
        let corners = [
            SIMD2(-expansion, -expansion),
            SIMD2(expansion, -expansion),
            SIMD2(-expansion, expansion),
            SIMD2(expansion, expansion),
        ].map(fragment.canonicalFromBrush.applying)
        return PixelRect(
            minX: Int(floor(corners.map(\.x).min()!)),
            minY: Int(floor(corners.map(\.y).min()!)),
            maxX: Int(ceil(corners.map(\.x).max()!)),
            maxY: Int(ceil(corners.map(\.y).max()!))
        )!
    }

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
        validateBrushToWorld(footprint.brushToWorld)
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
                for: image.worldClip,
                brushToWorld: footprint.brushToWorld
            )
            let localPolygon = planes.reduce(
                footprint.localBounds.corners
            ) { polygon, plane in
                clipPolygon(polygon, to: plane)
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
                        brushClip: ConvexClip(halfPlanes: planes),
                        operation: image.operation
                    ),
                    localPolygon: localPolygon
                )
            )
        }

        candidates = removingByteEqualCandidates(candidates)
        let policy: CoincidentImagePolicy
        switch strategy.compiledSymmetry.domain {
        case let .periodic(periodic):
            policy = periodic.coincidentImagePolicy
        case let .finite(finite):
            policy = finite.radial.coincidentImagePolicy
        }
        candidates = removingCoverageEqualCandidates(
            candidates,
            policy: policy,
            symmetry: footprint.coverageSymmetry,
            ownership: strategy.compiledSymmetry.ownership,
            canonicalSize: strategy.tileSize
        )
        candidates.sort {
            fragmentPrecedes($0.fragment, $1.fragment)
        }
        return candidates.map(\.fragment)
    }

    static func clipPolygon(
        _ polygon: [SIMD2<Float>],
        to plane: HalfPlane2D
    ) -> [SIMD2<Float>] {
        clip(polygon, to: plane)
    }

    static func canonicalPolygonKey(
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
}

private func validateBrushToWorld(_ affine: Affine2D) {
    let xRow = SIMD2(affine.xAxis.x, affine.yAxis.x)
    let xRowLength = simd_length(xRow)
    precondition(
        xRowLength.isFinite && xRowLength > 0,
        "TilingProjection brush-to-world x row must be finite and nonzero"
    )

    let yRow = SIMD2(affine.xAxis.y, affine.yAxis.y)
    let yRowLength = simd_length(yRow)
    precondition(
        yRowLength.isFinite && yRowLength > 0,
        "TilingProjection brush-to-world y row must be finite and nonzero"
    )

    let normalizedXRow = xRow / xRowLength
    let normalizedYRow = yRow / yRowLength
    let determinant = normalizedXRow.x * normalizedYRow.y
        - normalizedXRow.y * normalizedYRow.x
    precondition(
        determinant.isFinite && abs(determinant) >= Float.ulpOfOne,
        "TilingProjection brush-to-world determinant must be finite and nonsingular"
    )
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
    let centerX: Int64
    let centerY: Int64
    let xAxisLength: UInt32
    let yAxisLength: UInt32
    let polygon: [UInt32]

    private init(
        centerX: Int64,
        centerY: Int64,
        xAxisLength: UInt32,
        yAxisLength: UInt32,
        polygon: [UInt32]
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.xAxisLength = xAxisLength
        self.yAxisLength = yAxisLength
        self.polygon = polygon
    }

    init(
        _ candidate: FragmentCandidate,
        ownership: CompiledOwnership,
        canonicalSize: PatternSize
    ) {
        let affine = candidate.fragment.canonicalFromBrush
        switch ownership {
        case .rectangularHalfOpen:
            centerX = Int64(normalizedZero(affine.translation.x).bitPattern)
            centerY = Int64(normalizedZero(affine.translation.y).bitPattern)
        case .squareRotation, .squareMirrorTriangles,
             .triangularDomains, .radialSector:
            let center = canonicalizedCoverageCenter(
                affine.translation,
                ownership: ownership,
                canonicalSize: canonicalSize
            )
            centerX = Int64(normalizedZero(center.x).bitPattern)
            centerY = Int64(normalizedZero(center.y).bitPattern)
        }
        let lengths = [
            normalizedZero(simd_length(affine.xAxis)),
            normalizedZero(simd_length(affine.yAxis)),
        ].sorted()
        xAxisLength = lengths[0].bitPattern
        yAxisLength = lengths[1].bitPattern
        switch ownership {
        case .rectangularHalfOpen:
            polygon = TilingProjection.canonicalPolygonKey(
                candidate.localPolygon.map {
                    affine.applying(to: $0)
                }
            )
        case .squareRotation, .squareMirrorTriangles:
            // Square group images can have different canonical quad
            // orientations while an invariant brush covers the same clipped
            // local domain. Cell clipping itself is expressed in brush-local
            // coordinates, so this preserves complementary seam fragments.
            polygon = TilingProjection.canonicalPolygonKey(
                candidate.localPolygon
            )
        case .triangularDomains, .radialSector:
            polygon = TilingProjection.canonicalPolygonKey(
                candidate.localPolygon
            )
        }
    }
}

private func canonicalizedCoverageCenter(
    _ point: SIMD2<Float>,
    ownership: CompiledOwnership,
    canonicalSize: PatternSize
) -> SIMD2<Float> {
    let stabilizers: [CompiledStabilizer]
    let candidate: SIMD2<Float>
    switch ownership {
    case .rectangularHalfOpen:
        return point
    case let .squareRotation(_, values),
         let .squareMirrorTriangles(_, values):
        stabilizers = values
        candidate = point
    case let .triangularDomains(_, values):
        stabilizers = values
        candidate = SIMD2(
            triangularCanonicalBoundaryCoordinate(
                point.x,
                extent: canonicalSize.width
            ),
            triangularCanonicalBoundaryCoordinate(
                point.y,
                extent: canonicalSize.height
            )
        )
    case let .radialSector(values):
        stabilizers = values
        candidate = point
    }
    return stabilizers.first(where: {
        coverageCoordinatesAgree(
            candidate.x,
            $0.canonicalPoint.x,
            maximumULPDistance: 2
        )
            && coverageCoordinatesAgree(
                candidate.y,
                $0.canonicalPoint.y,
                maximumULPDistance: 2
            )
    })?.canonicalPoint ?? candidate
}

private func triangularCanonicalBoundaryCoordinate(
    _ value: Float,
    extent: Float
) -> Float {
    let tolerance = 2 * extent.ulp
    if abs(value) <= tolerance || abs(value - extent) <= tolerance {
        return 0
    }
    return value
}

private func coverageCoordinatesAgree(
    _ lhs: Float,
    _ rhs: Float,
    maximumULPDistance: UInt32
) -> Bool {
    guard lhs.isFinite, rhs.isFinite else { return false }
    let lhsBits = orderedCoverageBits(normalizedZero(lhs))
    let rhsBits = orderedCoverageBits(normalizedZero(rhs))
    return max(lhsBits, rhsBits) - min(lhsBits, rhsBits)
        <= maximumULPDistance
}

private func orderedCoverageBits(_ value: Float) -> UInt32 {
    let bits = value.bitPattern
    return bits & 0x8000_0000 == 0
        ? bits | 0x8000_0000
        : ~bits
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
    for worldClip: ConvexClip,
    brushToWorld: Affine2D
) -> [HalfPlane2D] {
    worldClip.halfPlanes.map {
        brushLocalPlane(
            worldNormal: $0.normal,
            worldOffset: $0.offset,
            brushToWorld: brushToWorld
        )
    }
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
    let vertices = polygon.map {
        ClipVertex(
            point: $0,
            distance: signedDistance(from: $0, to: plane)
        )
    }
    guard let last = vertices.last else {
        return []
    }

    var result: [SIMD2<Float>] = []
    result.reserveCapacity(polygon.count + 1)
    var start = last.point
    var startDistance = last.distance
    var startInside = last.distance >= 0

    for vertex in vertices {
        let end = vertex.point
        let endDistance = vertex.distance
        let endInside = endDistance >= 0
        if endInside {
            if !startInside {
                result.append(
                    intersection(
                        from: start,
                        to: end,
                        startDistance: startDistance,
                        endDistance: endDistance
                    )
                )
            }
            result.append(end)
        } else if startInside {
            result.append(
                intersection(
                    from: start,
                    to: end,
                    startDistance: startDistance,
                    endDistance: endDistance
                )
            )
        }
        start = end
        startDistance = endDistance
        startInside = endInside
    }
    return result
}

private struct ClipVertex {
    let point: SIMD2<Float>
    let distance: Float
}

private func signedDistance(
    from point: SIMD2<Float>,
    to plane: HalfPlane2D
) -> Float {
    let distance = simd_dot(plane.normal, point) - plane.offset
    precondition(
        distance.isFinite,
        "TilingProjection clip endpoint distance must be finite"
    )
    return distance
}

private func intersection(
    from start: SIMD2<Float>,
    to end: SIMD2<Float>,
    startDistance: Float,
    endDistance: Float
) -> SIMD2<Float> {
    let denominator = startDistance - endDistance
    precondition(
        denominator.isFinite && denominator != 0,
        "TilingProjection clip distance denominator must be finite and nonzero"
    )
    let parameter = startDistance / denominator
    precondition(
        parameter.isFinite,
        "TilingProjection clip parameter must be finite"
    )
    return start + (end - start) * parameter
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
    _ candidates: [FragmentCandidate],
    policy: CoincidentImagePolicy,
    symmetry: FootprintCoverageSymmetry,
    ownership: CompiledOwnership,
    canonicalSize: PatternSize
) -> [FragmentCandidate] {
    guard policy != .byteEqualOnly, symmetry != .oriented else {
        return candidates
    }
    if case .triangularDomains = ownership {
        return removingTriangularCoverageEqualCandidates(
            candidates,
            policy: policy,
            symmetry: symmetry,
            ownership: ownership,
            canonicalSize: canonicalSize
        )
    }
    if case .radialSector = ownership {
        return removingTriangularCoverageEqualCandidates(
            candidates,
            policy: policy,
            symmetry: symmetry,
            ownership: ownership,
            canonicalSize: canonicalSize
        )
    }
    let ordered = candidates.enumerated().sorted { lhs, rhs in
        let lhsRank = ownershipRank(lhs.element, ownership: ownership)
        let rhsRank = ownershipRank(rhs.element, ownership: ownership)
        return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
    }.map(\.element)
    var seen: [CoverageDomainKey: [CompiledGroupOperation]] = [:]
    return ordered.filter { candidate in
        let key = CoverageDomainKey(
            candidate,
            ownership: ownership,
            canonicalSize: canonicalSize
        )
        let operation = candidate.fragment.operation
        if seen[key, default: []].contains(where: {
            operationsAreEquivalent(
                $0,
                operation,
                policy: policy,
                symmetry: symmetry
            )
        }) {
            return false
        }
        seen[key, default: []].append(operation)
        return true
    }
}

private struct TriangularCoverageCenterKey: Hashable {
    let x: UInt32
    let y: UInt32
}

private func removingTriangularCoverageEqualCandidates(
    _ candidates: [FragmentCandidate],
    policy: CoincidentImagePolicy,
    symmetry: FootprintCoverageSymmetry,
    ownership: CompiledOwnership,
    canonicalSize: PatternSize
) -> [FragmentCandidate] {
    let ordered = candidates.enumerated().sorted { lhs, rhs in
        let lhsRank = ownershipRank(lhs.element, ownership: ownership)
        let rhsRank = ownershipRank(rhs.element, ownership: ownership)
        return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
    }.map(\.element)
    var selectedOperations:
        [TriangularCoverageCenterKey: [CompiledGroupOperation]] = [:]

    return ordered.filter { candidate in
        let center = canonicalizedCoverageCenter(
            candidate.fragment.canonicalFromBrush.translation,
            ownership: ownership,
            canonicalSize: canonicalSize
        )
        let key = TriangularCoverageCenterKey(
            x: normalizedZero(center.x).bitPattern,
            y: normalizedZero(center.y).bitPattern
        )
        let operation = candidate.fragment.operation
        let selected = selectedOperations[key, default: []]
        if selected.contains(operation) {
            // A chosen operation may be split into complementary fragments at
            // a rectangular-supercell seam. Retain every one of its pieces.
            return true
        }
        if selected.contains(where: {
            operationsAreEquivalent(
                $0,
                operation,
                policy: policy,
                symmetry: symmetry
            )
        }) {
            return false
        }
        selectedOperations[key, default: []].append(operation)
        return true
    }
}

private func ownershipRank(
    _ candidate: FragmentCandidate,
    ownership: CompiledOwnership
) -> Int {
    guard let owner = preferredOwnershipOwner(
        at: candidate.fragment.canonicalFromBrush.translation,
        ownership: ownership
    ) else {
        return 1
    }
    return candidate.fragment.imageOrdinal == owner ? 0 : 1
}

func preferredOwnershipOwner(
    at canonicalPoint: SIMD2<Float>,
    ownership: CompiledOwnership
) -> UInt8? {
    let fragments: [CompiledOwnershipFragment]
    switch ownership {
    case .rectangularHalfOpen:
        return nil
    case let .squareRotation(sectors, _):
        fragments = sectors
    case let .squareMirrorTriangles(triangles, _):
        fragments = triangles
    case let .triangularDomains(triangles, _):
        fragments = triangles
    case .radialSector:
        return nil
    }

    // Every nonrectangular ownership fragment is a triangle. Inclusive
    // containment
    // deliberately gives an exact edge or stabilizer point to the smallest
    // declared owner, making half-open boundary ties independent of discovery
    // order.
    return fragments.compactMap { fragment -> UInt8? in
        guard triangleContains(
            canonicalPoint,
            vertices: fragment.canonicalVertices
        ) else {
            return nil
        }
        return fragment.ownerOrdinal
    }.min()
}

private func triangleContains(
    _ point: SIMD2<Float>,
    vertices: [SIMD2<Float>]
) -> Bool {
    guard vertices.count == 3 else {
        return false
    }
    let edges = [
        (vertices[0], vertices[1]),
        (vertices[1], vertices[2]),
        (vertices[2], vertices[0]),
    ]
    let crosses = edges.map { edgeVertices in
        let edge = edgeVertices.1 - edgeVertices.0
        let relative = point - edgeVertices.0
        return edge.x * relative.y - edge.y * relative.x
    }
    let scale = max(
        vertices.flatMap { [abs($0.x), abs($0.y)] }.max() ?? 1,
        1
    )
    let tolerance = scale * scale * 8 * Float.ulpOfOne
    return crosses.allSatisfy { $0 >= -tolerance }
        || crosses.allSatisfy { $0 <= tolerance }
}

private func operationsAreEquivalent(
    _ lhs: CompiledGroupOperation,
    _ rhs: CompiledGroupOperation,
    policy: CoincidentImagePolicy,
    symmetry: FootprintCoverageSymmetry
) -> Bool {
    let changesReflection = lhs.reflected != rhs.reflected
    let commonOrder = leastCommonMultiple(
        Int(lhs.rotationOrder),
        Int(rhs.rotationOrder)
    )
    let lhsStep = Int(lhs.rotationStep)
        * commonOrder / Int(lhs.rotationOrder)
    let rhsStep = Int(rhs.rotationStep)
        * commonOrder / Int(rhs.rotationOrder)
    let turnDifference = rhsStep - lhsStep
    let normalizedTurns =
        (turnDifference % commonOrder + commonOrder) % commonOrder
    let changesByHalfTurn = commonOrder.isMultiple(of: 2)
        && normalizedTurns == commonOrder / 2

    let policyAllows: Bool
    switch policy {
    case .byteEqualOnly:
        policyAllows = false
    case .halfTurnInvariantCoverage:
        policyAllows = !changesReflection && changesByHalfTurn
    case .quarterTurnInvariantCoverage,
         .triangularCyclicInvariantCoverage,
         .radialCyclicInvariantCoverage:
        policyAllows = !changesReflection
    case .squareDihedralInvariantCoverage,
         .triangularDihedralInvariantCoverage,
         .radialDihedralInvariantCoverage:
        policyAllows = true
    }
    guard policyAllows else { return false }

    switch symmetry {
    case .oriented:
        return false
    case .halfTurnInvariant:
        return !changesReflection && changesByHalfTurn
    case .rotationInvariant:
        return !changesReflection
    case .reflectionInvariant:
        return changesReflection
    case .rotationAndReflectionInvariant:
        return true
    }
}

private func leastCommonMultiple(_ lhs: Int, _ rhs: Int) -> Int {
    lhs / greatestCommonDivisor(lhs, rhs) * rhs
}

private func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
    var first = lhs
    var second = rhs
    while second != 0 {
        let remainder = first % second
        first = second
        second = remainder
    }
    return first
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
