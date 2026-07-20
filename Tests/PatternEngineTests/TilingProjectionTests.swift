import Foundation
@testable import PatternEngine
import simd
import Testing

private let projectionTileSize = PatternSize(width: 256, height: 256)
private let normalizedBrushBounds = AxisAlignedRect(
    minimum: SIMD2<Float>(-1, -1),
    maximum: SIMD2<Float>(1, 1)
)

@Test
func gridCornerFootprintEmitsFourExactOwnedFragments() {
    let footprint = squareFootprint(center: SIMD2(3, 3), radius: 10)
    let strategy = TilingStrategy(kind: .grid, tileSize: projectionTileSize)

    let fragments = TilingProjection.fragments(for: footprint, using: strategy)

    #expect(fragments == [
        expectedGridFragment(
            cell: CellIndex(column: -1, row: -1),
            canonicalCenter: SIMD2(259, 259),
            clipOffsets: SIMD4(-25.9, 0.3, -25.9, 0.3)
        ),
        expectedGridFragment(
            cell: CellIndex(column: 0, row: -1),
            canonicalCenter: SIMD2(3, 259),
            clipOffsets: SIMD4(-0.3, -25.3, -25.9, 0.3)
        ),
        expectedGridFragment(
            cell: CellIndex(column: -1, row: 0),
            canonicalCenter: SIMD2(259, 3),
            clipOffsets: SIMD4(-25.9, 0.3, -0.3, -25.3)
        ),
        expectedGridFragment(
            cell: CellIndex(column: 0, row: 0),
            canonicalCenter: SIMD2(3, 3),
            clipOffsets: SIMD4(-0.3, -25.3, -0.3, -25.3)
        ),
    ])
    #expect(fragments.allSatisfy { $0.brushClip.halfPlanes.count == 4 })

    let worldToBrush = footprint.brushToWorld.inverted()
    for integerY in -7..<13 {
        for integerX in -7..<13 {
            let pixelCenter = SIMD2<Float>(
                Float(integerX) + 0.5,
                Float(integerY) + 0.5
            )
            let brushPoint = worldToBrush.applying(to: pixelCenter)
            let owners = fragments.filter {
                $0.brushClip.contains(brushPoint, tolerance: 0)
            }
            #expect(owners.count == 1)
        }
    }

    var coveredCanonicalProbes = 0
    var maximumOwnerCount = 0
    for integerY in 0..<256 {
        for integerX in 0..<256 {
            let canonicalPoint = SIMD2<Float>(
                Float(integerX),
                Float(integerY)
            )
            let ownerCount = fragments.filter { fragment in
                let brushPoint = fragment.canonicalFromBrush.inverted()
                    .applying(to: canonicalPoint)
                return normalizedBrushBounds.containsClosed(brushPoint)
                    && fragment.brushClip.contains(brushPoint, tolerance: 0)
            }.count
            maximumOwnerCount = max(maximumOwnerCount, ownerCount)
            if ownerCount > 0 {
                coveredCanonicalProbes += 1
            }
        }
    }
    #expect(coveredCanonicalProbes > 0)
    #expect(maximumOwnerCount == 1)
}

@Test
func halfDropSeamUsesComplementaryPhasedClipsWithoutPhantomDisk() {
    let footprint = squareFootprint(center: SIMD2(300, 144), radius: 10)
    let strategy = TilingStrategy(
        kind: .halfDrop,
        tileSize: PatternSize(width: 288, height: 288)
    )

    let fragments = TilingProjection.fragments(for: footprint, using: strategy)

    #expect(fragments.count == 2)
    #expect(fragments.map(\.cell) == [
        CellIndex(column: 1, row: -1),
        CellIndex(column: 1, row: 0),
    ])
    #expect(fragments.map(\.canonicalFromBrush.translation) == [
        SIMD2<Float>(12, 288),
        SIMD2<Float>(12, 0),
    ])

    let upperPoint = SIMD2<Float>(0, -0.5)
    let lowerPoint = SIMD2<Float>(0, 0.5)
    #expect(fragments[0].brushClip.contains(upperPoint, tolerance: 0))
    #expect(!fragments[0].brushClip.contains(lowerPoint, tolerance: 0))
    #expect(!fragments[1].brushClip.contains(upperPoint, tolerance: 0))
    #expect(fragments[1].brushClip.contains(lowerPoint, tolerance: 0))
    #expect(!fragments.contains {
        $0.brushClip.contains(upperPoint, tolerance: 0)
            && $0.brushClip.contains(lowerPoint, tolerance: 0)
    })

    for localY in stride(from: Float(-0.95), through: 0.95, by: 0.1)
    where abs(localY) > 0.0001 {
        let point = SIMD2<Float>(0, localY)
        #expect(
            fragments.filter {
                $0.brushClip.contains(point, tolerance: 0)
            }.count == 1
        )
    }
}

@Test
func brickProjectionIsTheExactTransposeOfHalfDrop() {
    let tileSize = PatternSize(width: 288, height: 288)
    let halfDrop = TilingProjection.fragments(
        for: squareFootprint(center: SIMD2(300, 144), radius: 10),
        using: TilingStrategy(kind: .halfDrop, tileSize: tileSize)
    )
    let brick = TilingProjection.fragments(
        for: squareFootprint(center: SIMD2(144, 300), radius: 10),
        using: TilingStrategy(kind: .brick, tileSize: tileSize)
    )

    #expect(halfDrop.count == brick.count)
    for source in halfDrop {
        let transposedCell = CellIndex(
            column: source.cell.row,
            row: source.cell.column
        )
        let target = brick.first {
            $0.cell == transposedCell && $0.imageOrdinal == source.imageOrdinal
        }
        #expect(target != nil)
        guard let target else {
            continue
        }
        #expect(
            transpose(source.canonicalFromBrush.xAxis)
                == target.canonicalFromBrush.yAxis
        )
        #expect(
            transpose(source.canonicalFromBrush.yAxis)
                == target.canonicalFromBrush.xAxis
        )
        #expect(
            transpose(source.canonicalFromBrush.translation)
                == target.canonicalFromBrush.translation
        )
        #expect(
            Set(source.brushClip.halfPlanes.map(transposedPlaneSignature))
                == Set(target.brushClip.halfPlanes.map(planeSignature))
        )
    }
}

@Test
func mirrorXYProjectionPreservesBothNegativeBasisAxes() {
    let strategy = TilingStrategy(
        kind: .mirrorXY,
        tileSize: PatternSize(width: 288, height: 288)
    )
    let fragments = TilingProjection.fragments(
        for: squareFootprint(center: SIMD2(288, 288), radius: 10),
        using: strategy
    )
    let doublyReflected = fragments.first {
        $0.cell == CellIndex(column: 1, row: 1)
    }

    #expect(doublyReflected?.canonicalFromBrush.xAxis == SIMD2<Float>(-10, 0))
    #expect(doublyReflected?.canonicalFromBrush.yAxis == SIMD2<Float>(0, -10))
    #expect(
        doublyReflected?.canonicalFromBrush.translation
            == SIMD2<Float>(288, 288)
    )
}

@Test
func rotatedAsymmetricFootprintKeepsBrushLocalCoordinatesAcrossSeam() {
    let footprint = StampFootprint(
        brushToWorld: Affine2D(
            xAxis: SIMD2(8, 6),
            yAxis: SIMD2(-6, 8),
            translation: SIMD2(254, 100)
        ),
        localBounds: AxisAlignedRect(
            minimum: SIMD2(-0.75, -0.5),
            maximum: SIMD2(1.25, 0.9)
        ),
        coverageSymmetry: .oriented
    )
    let fragments = TilingProjection.fragments(
        for: footprint,
        using: TilingStrategy(kind: .grid, tileSize: projectionTileSize)
    )
    let leftPoint = SIMD2<Float>(0.24, 0)
    let rightPoint = SIMD2<Float>(0.26, 0)
    let leftOwners = fragments.filter {
        $0.brushClip.contains(leftPoint, tolerance: 0)
    }
    let rightOwners = fragments.filter {
        $0.brushClip.contains(rightPoint, tolerance: 0)
    }

    #expect(leftOwners.count == 1)
    #expect(rightOwners.count == 1)
    #expect(leftOwners.first?.cell == CellIndex(column: 0, row: 0))
    #expect(rightOwners.first?.cell == CellIndex(column: 1, row: 0))
    guard let leftFragment = leftOwners.first, let rightFragment = rightOwners.first else {
        return
    }

    let recoveredLeft = leftFragment.canonicalFromBrush.inverted().applying(
        to: leftFragment.canonicalFromBrush.applying(to: leftPoint)
    )
    let recoveredRight = rightFragment.canonicalFromBrush.inverted().applying(
        to: rightFragment.canonicalFromBrush.applying(to: rightPoint)
    )
    #expect(simd_distance(recoveredLeft, leftPoint) < 0.0001)
    #expect(simd_distance(recoveredRight, rightPoint) < 0.0001)
    #expect(simd_distance(recoveredRight, recoveredLeft) < 0.021)
}

@Test
func exactConvexIntersectionRejectsEmptyRotatedAABBCorner() {
    let footprint = StampFootprint(
        brushToWorld: Affine2D(
            xAxis: SIMD2(4, 4),
            yAxis: SIMD2(-4, 4),
            translation: SIMD2(5, 5)
        ),
        localBounds: normalizedBrushBounds,
        coverageSymmetry: .oriented
    )
    let fragments = TilingProjection.fragments(
        for: footprint,
        using: TilingStrategy(kind: .grid, tileSize: projectionTileSize)
    )

    #expect(fragments.count == 3)
    #expect(!fragments.contains {
        $0.cell == CellIndex(column: -1, row: -1)
    })
    #expect(Set(fragments.map(\.cell)) == Set([
        CellIndex(column: 0, row: -1),
        CellIndex(column: -1, row: 0),
        CellIndex(column: 0, row: 0),
    ]))
    #expect(Set(fragments.map(\.canonicalFromBrush.translation)) == Set([
        SIMD2<Float>(5, 261),
        SIMD2<Float>(261, 5),
        SIMD2<Float>(5, 5),
    ]))
}

@Test
func exactConvexIntersectionRejectsPointOnlyCornerTangent() {
    let footprint = StampFootprint(
        brushToWorld: Affine2D(
            xAxis: SIMD2(3, 4),
            yAxis: SIMD2(-3, 4),
            translation: SIMD2(3, 4)
        ),
        localBounds: normalizedBrushBounds,
        coverageSymmetry: .oriented
    )
    let fragments = TilingProjection.fragments(
        for: footprint,
        using: TilingStrategy(kind: .grid, tileSize: projectionTileSize)
    )

    #expect(fragments.count == 3)
    #expect(!fragments.contains {
        $0.cell == CellIndex(column: -1, row: -1)
    })
    #expect(Set(fragments.map(\.canonicalFromBrush.translation)) == Set([
        SIMD2<Float>(3, 4),
        SIMD2<Float>(259, 4),
        SIMD2<Float>(3, 260),
    ]))
}

@Test
func endpointDistanceWitnessClipsToFinitePositivePolygon() {
    let normal = SIMD2<Float>(-0.8929465, -0.45016286)
    let start = SIMD2<Float>(-0.07052188, -0.96007323)
    let end = SIMD2<Float>(-0.07452252, -0.95213753)
    let plane = HalfPlane2D(normal: normal, offset: 0.4951616)
    let inside = start + normal * 0.25
    let polygon = [end, start, inside]

    let clipped = TilingProjection.clipPolygon(polygon, to: plane)

    #expect(clipped.count == 4)
    #expect(simd_distance(clipped[1], start) < 0.00001)
    #expect(clipped.allSatisfy { $0.isFinite })
    #expect(clipped.allSatisfy {
        plane.contains($0, tolerance: 0.000001)
    })
    #expect(abs(testSignedArea(clipped)) > 0.0001)
}

@Test
func rotationalFixedPointDeduplicatesOnlyHalfTurnInvariantCoverage() {
    let tileSize = PatternSize(width: 288, height: 288)
    let strategy = TilingStrategy(kind: .rotational, tileSize: tileSize)
    let invariant = squareFootprint(
        center: SIMD2(144, 144),
        radius: 10,
        symmetry: .halfTurnInvariant
    )
    let oriented = squareFootprint(
        center: SIMD2(144, 144),
        radius: 10,
        symmetry: .oriented
    )

    let invariantFragments = TilingProjection.fragments(
        for: invariant,
        using: strategy
    )
    let orientedFragments = TilingProjection.fragments(
        for: oriented,
        using: strategy
    )

    #expect(invariantFragments.count == 1)
    #expect(invariantFragments[0].imageOrdinal == 0)
    #expect(orientedFragments.count == 2)
    #expect(orientedFragments.map(\.imageOrdinal) == [0, 1])
    #expect(
        orientedFragments[0].canonicalFromBrush.xAxis
            == SIMD2<Float>(10, 0)
    )
    #expect(
        orientedFragments[1].canonicalFromBrush.xAxis
            == SIMD2<Float>(-10, 0)
    )
}

@Test
func rotationalEqualCentersKeepDifferentClippedCoverageDomains() {
    let strategy = TilingStrategy(
        kind: .rotational,
        tileSize: PatternSize(width: 64, height: 64)
    )
    let footprint = StampFootprint(
        brushToWorld: Affine2D(
            xAxis: SIMD2(50, 0),
            yAxis: SIMD2(0, 10),
            translation: SIMD2(64, 32)
        ),
        localBounds: AxisAlignedRect(
            minimum: SIMD2(-1, -1),
            maximum: SIMD2(0.5, 1)
        ),
        coverageSymmetry: .halfTurnInvariant
    )

    let fragments = TilingProjection.fragments(
        for: footprint,
        using: strategy
    )
    let equalCenterFragments = fragments.filter {
        $0.canonicalFromBrush.translation == SIMD2<Float>(0, 32)
    }

    #expect(equalCenterFragments.count == 2)
    #expect(Set(equalCenterFragments.map(\.cell)) == Set([
        CellIndex(column: 0, row: 0),
        CellIndex(column: 1, row: 0),
    ]))
    #expect(Set(equalCenterFragments.map(\.imageOrdinal)) == Set([0, 1]))
    #expect(equalCenterFragments.contains {
        $0.brushClip.contains(SIMD2(-0.75, 0), tolerance: 0)
    })
    #expect(equalCenterFragments.contains {
        $0.brushClip.contains(SIMD2(0.25, 0), tolerance: 0)
    })
}

@Test
func rotationalFixedCoverageCanonicalizesCyclicWindingAndNegativeZeroVariants() {
    let tileSize = PatternSize(width: 64, height: 64)
    let strategy = TilingStrategy(kind: .rotational, tileSize: tileSize)
    let fixedAffines = [
        Affine2D(
            xAxis: SIMD2(10, 0),
            yAxis: SIMD2(0, 10),
            translation: SIMD2(32, 32)
        ),
        Affine2D(
            xAxis: SIMD2(-10, 0),
            yAxis: SIMD2(0, 10),
            translation: SIMD2(32, 32)
        ),
        Affine2D(
            xAxis: SIMD2(10, -0.0),
            yAxis: SIMD2(-0.0, 10),
            translation: SIMD2(32, 32)
        ),
    ]

    for affine in fixedAffines {
        let invariant = TilingProjection.fragments(
            for: StampFootprint(
                brushToWorld: affine,
                localBounds: normalizedBrushBounds,
                coverageSymmetry: .halfTurnInvariant
            ),
            using: strategy
        )
        let oriented = TilingProjection.fragments(
            for: StampFootprint(
                brushToWorld: affine,
                localBounds: normalizedBrushBounds,
                coverageSymmetry: .oriented
            ),
            using: strategy
        )

        #expect(invariant.count == 1)
        #expect(oriented.count == 2)
        let firstPolygon = normalizedBrushBounds.corners.map {
            oriented[0].canonicalFromBrush.applying(to: $0)
        }
        let secondPolygon = normalizedBrushBounds.corners.map {
            oriented[1].canonicalFromBrush.applying(to: $0)
        }
        #expect(firstPolygon != secondPolygon)
        #expect(Set(firstPolygon) == Set(secondPolygon))
    }

    let negativeZeroSeam = Affine2D(
        xAxis: SIMD2(10, 0),
        yAxis: SIMD2(0, 10),
        translation: SIMD2(-0.0, -0.0)
    )
    let orientedSeam = TilingProjection.fragments(
        for: StampFootprint(
            brushToWorld: negativeZeroSeam,
            localBounds: normalizedBrushBounds,
            coverageSymmetry: .oriented
        ),
        using: strategy
    )
    let invariantSeam = TilingProjection.fragments(
        for: StampFootprint(
            brushToWorld: negativeZeroSeam,
            localBounds: normalizedBrushBounds,
            coverageSymmetry: .halfTurnInvariant
        ),
        using: strategy
    )
    let zeroCentered = orientedSeam.filter {
        $0.canonicalFromBrush.translation == SIMD2<Float>(0, 0)
    }

    #expect(orientedSeam.count == 8)
    #expect(invariantSeam.count == 4)
    #expect(zeroCentered.count == 2)
    #expect(negativeZeroSeam.translation.x.bitPattern == 0x8000_0000)
    #expect(negativeZeroSeam.translation.y.bitPattern == 0x8000_0000)
}

@Test
func radiusUsesExactMinimumAndApprovedMaximumClamp() {
    let tileSize = PatternSize(width: 64, height: 96)

    #expect(TilingProjection.clampedRadius(requested: 1, tileSize: tileSize) == 1)
    #expect(
        TilingProjection.clampedRadius(requested: 10_000, tileSize: tileSize)
            == 256
    )
}

@Test
func radiusBelowMinimumIsRejectedBeforeProjection() throws {
    if ProcessInfo.processInfo.environment["PATTERN_ENGINE_RADIUS_BELOW_MINIMUM"] == "1" {
        _ = TilingProjection.clampedRadius(
            requested: Float(1).nextDown,
            tileSize: PatternSize(width: 64, height: 96)
        )
        return
    }

    let result = try runRadiusValidationSubprocess()
    #expect(result.status != 0)
    #expect(
        result.standardError.contains(
            "Precondition failed: TilingProjection radius must be finite and at least 1"
        )
    )
}

@Test
func footprintAffineValidationRunsBeforeProjectionInSubprocesses() throws {
    if let validationCase = ProcessInfo.processInfo.environment[
        "PATTERN_ENGINE_FOOTPRINT_AFFINE_CASE"
    ] {
        exerciseFootprintAffineValidation(named: validationCase)
        return
    }

    let invalidCases = [
        (
            "axisCollapsed",
            "TilingProjection brush-to-world x row must be finite and nonzero"
        ),
        (
            "axisCollapsedY",
            "TilingProjection brush-to-world y row must be finite and nonzero"
        ),
        (
            "singular",
            "TilingProjection brush-to-world determinant must be finite and nonsingular"
        ),
    ]
    for (validationCase, expectedMessage) in invalidCases {
        let result = try runFootprintAffineValidationSubprocess(
            for: validationCase
        )
        #expect(result.status != 0)
        #expect(
            result.standardError.contains(
                "Precondition failed: \(expectedMessage)"
            )
        )
    }

    for validationCase in ["identitySurvivor", "rotatedSurvivor"] {
        let result = try runFootprintAffineValidationSubprocess(
            for: validationCase
        )
        #expect(result.status == 0)
    }
}

@Test
func maximumRadiusEnumeratesAtMostNineByNineTranslationCells() {
    let tileSize = PatternSize(width: 64, height: 64)
    let radius = TilingProjection.clampedRadius(
        requested: 10_000,
        tileSize: tileSize
    )
    let footprint = squareFootprint(
        center: SIMD2(32, 32),
        radius: radius,
        symmetry: .oriented
    )
    let worldBounds = footprint.localBounds.transformed(
        by: footprint.brushToWorld
    )
    let strategy = TilingStrategy(kind: .rotational, tileSize: tileSize)
    let enumeratedImages = strategy.images(intersecting: worldBounds)
    let translationCells = Set(enumeratedImages.map(\.cell))
    let fragments = TilingProjection.fragments(
        for: footprint,
        using: strategy
    )

    #expect(translationCells.count == 81)
    #expect(translationCells.count <= 81)
    #expect(enumeratedImages.count == translationCells.count * 2)
    #expect(fragments.count <= translationCells.count * 2)
}

@Test
func repeatedProjectionHasBitIdenticalTotalOrder() {
    let footprint = StampFootprint(
        brushToWorld: Affine2D(
            xAxis: SIMD2(23, 11),
            yAxis: SIMD2(-7, 19),
            translation: SIMD2(290, 143)
        ),
        localBounds: AxisAlignedRect(
            minimum: SIMD2(-1.25, -0.75),
            maximum: SIMD2(1.5, 1)
        ),
        coverageSymmetry: .oriented
    )
    let strategy = TilingStrategy(
        kind: .rotational,
        tileSize: PatternSize(width: 288, height: 192)
    )

    let first = TilingProjection.fragments(for: footprint, using: strategy)
    let second = TilingProjection.fragments(for: footprint, using: strategy)

    #expect(first == second)
    #expect(fragmentBitPatterns(first) == fragmentBitPatterns(second))
    #expect(isInRequiredFragmentOrder(first))
}

@Test
func legacyGridInteriorEdgeCornerAndTangentPlacementsAreRepresentedByFragments() {
    let strategy = TilingStrategy(kind: .grid, tileSize: projectionTileSize)
    let cases: [(SIMD2<Float>, Float, Set<SIMD2<Float>>)] = [
        (SIMD2(100, 100), 10, Set([SIMD2(100, 100)])),
        (SIMD2(3, 100), 10, Set([SIMD2(3, 100), SIMD2(259, 100)])),
        (
            SIMD2(-2, -2),
            10,
            Set([
                SIMD2(254, 254),
                SIMD2(-2, 254),
                SIMD2(254, -2),
                SIMD2(-2, -2),
            ])
        ),
        (SIMD2(10, 100), 10, Set([SIMD2(10, 100)])),
    ]

    for (center, radius, expectedCanonicalCenters) in cases {
        let fragments = TilingProjection.fragments(
            for: squareFootprint(center: center, radius: radius),
            using: strategy
        )
        #expect(
            Set(fragments.map(\.canonicalFromBrush.translation))
                == expectedCanonicalCenters
        )
        #expect(fragments.allSatisfy {
            simd_length($0.canonicalFromBrush.xAxis) == radius
                && simd_length($0.canonicalFromBrush.yAxis) == radius
        })
    }
}

private func squareFootprint(
    center: SIMD2<Float>,
    radius: Float,
    symmetry: FootprintCoverageSymmetry = .halfTurnInvariant
) -> StampFootprint {
    StampFootprint(
        brushToWorld: Affine2D(
            xAxis: SIMD2(radius, 0),
            yAxis: SIMD2(0, radius),
            translation: center
        ),
        localBounds: normalizedBrushBounds,
        coverageSymmetry: symmetry
    )
}

private func expectedGridFragment(
    cell: CellIndex,
    canonicalCenter: SIMD2<Float>,
    clipOffsets: SIMD4<Float>
) -> CellFragment {
    CellFragment(
        cell: cell,
        imageOrdinal: 0,
        canonicalFromBrush: Affine2D(
            xAxis: SIMD2(10, 0),
            yAxis: SIMD2(0, 10),
            translation: canonicalCenter
        ),
        brushClip: ConvexClip(halfPlanes: [
            HalfPlane2D(
                normal: SIMD2(1, 0),
                offset: clipOffsets.x
            ),
            HalfPlane2D(
                normal: SIMD2(-1, 0),
                offset: clipOffsets.y
            ),
            HalfPlane2D(
                normal: SIMD2(0, 1),
                offset: clipOffsets.z
            ),
            HalfPlane2D(
                normal: SIMD2(0, -1),
                offset: clipOffsets.w
            ),
        ])
    )
}

private func transpose(_ vector: SIMD2<Float>) -> SIMD2<Float> {
    SIMD2(vector.y, vector.x)
}

private struct PlaneSignature: Hashable {
    let normalX: UInt32
    let normalY: UInt32
    let offset: UInt32
}

private func planeSignature(_ plane: HalfPlane2D) -> PlaneSignature {
    PlaneSignature(
        normalX: normalizedZero(plane.normal.x).bitPattern,
        normalY: normalizedZero(plane.normal.y).bitPattern,
        offset: normalizedZero(plane.offset).bitPattern
    )
}

private func transposedPlaneSignature(_ plane: HalfPlane2D) -> PlaneSignature {
    planeSignature(
        HalfPlane2D(
            normal: transpose(plane.normal),
            offset: plane.offset
        )
    )
}

private func fragmentBitPatterns(_ fragments: [CellFragment]) -> [[UInt64]] {
    fragments.map { fragment in
        var result = [
            UInt64(bitPattern: Int64(fragment.cell.row)),
            UInt64(bitPattern: Int64(fragment.cell.column)),
            UInt64(fragment.imageOrdinal),
        ]
        result.append(contentsOf: affineScalars(fragment.canonicalFromBrush).map {
            UInt64($0.bitPattern)
        })
        result.append(UInt64(fragment.brushClip.halfPlanes.count))
        for plane in fragment.brushClip.halfPlanes {
            result.append(UInt64(plane.normal.x.bitPattern))
            result.append(UInt64(plane.normal.y.bitPattern))
            result.append(UInt64(plane.offset.bitPattern))
        }
        return result
    }
}

private func isInRequiredFragmentOrder(_ fragments: [CellFragment]) -> Bool {
    zip(fragments, fragments.dropFirst()).allSatisfy {
        fragmentSortScalars($0) < fragmentSortScalars($1)
    }
}

private func fragmentSortScalars(_ fragment: CellFragment) -> FragmentSortScalars {
    FragmentSortScalars(
        row: fragment.cell.row,
        column: fragment.cell.column,
        ordinal: fragment.imageOrdinal,
        scalars: affineScalars(fragment.canonicalFromBrush)
            + fragment.brushClip.halfPlanes.flatMap {
                [$0.normal.x, $0.normal.y, $0.offset]
            }
    )
}

private struct FragmentSortScalars: Comparable {
    let row: Int
    let column: Int
    let ordinal: UInt8
    let scalars: [Float]

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.row != rhs.row {
            return lhs.row < rhs.row
        }
        if lhs.column != rhs.column {
            return lhs.column < rhs.column
        }
        if lhs.ordinal != rhs.ordinal {
            return lhs.ordinal < rhs.ordinal
        }
        return lexicographicallyPrecedes(lhs.scalars, rhs.scalars)
    }
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

private func lexicographicallyPrecedes(
    _ lhs: [Float],
    _ rhs: [Float]
) -> Bool {
    for (left, right) in zip(lhs, rhs) where left != right {
        return left < right
    }
    return lhs.count < rhs.count
}

private func normalizedZero(_ value: Float) -> Float {
    value == 0 ? 0 : value
}

private func testSignedArea(_ polygon: [SIMD2<Float>]) -> Float {
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

private extension SIMD2 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}

private extension AxisAlignedRect {
    func containsClosed(_ point: SIMD2<Float>) -> Bool {
        point.x >= minimum.x
            && point.x <= maximum.x
            && point.y >= minimum.y
            && point.y <= maximum.y
    }
}

private func runRadiusValidationSubprocess()
    throws -> (status: Int32, standardError: String)
{
    let testExecutablePath = projectionTestExecutablePath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
        "--test-bundle-path", testExecutablePath,
        "--filter", "radiusBelowMinimumIsRejectedBeforeProjection",
        testExecutablePath,
        "--testing-library", "swift-testing",
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["PATTERN_ENGINE_RADIUS_BELOW_MINIMUM": "1"],
        uniquingKeysWith: { _, new in new }
    )
    process.standardOutput = FileHandle.nullDevice
    let standardError = Pipe()
    process.standardError = standardError

    try process.run()
    process.waitUntilExit()
    let errorOutput = String(
        decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    return (process.terminationStatus, errorOutput)
}

private func runFootprintAffineValidationSubprocess(
    for validationCase: String
) throws -> (status: Int32, standardError: String) {
    let testExecutablePath = projectionTestExecutablePath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
        "--test-bundle-path", testExecutablePath,
        "--filter", "footprintAffineValidationRunsBeforeProjectionInSubprocesses",
        testExecutablePath,
        "--testing-library", "swift-testing",
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["PATTERN_ENGINE_FOOTPRINT_AFFINE_CASE": validationCase],
        uniquingKeysWith: { _, new in new }
    )
    process.standardOutput = FileHandle.nullDevice
    let standardError = Pipe()
    process.standardError = standardError

    try process.run()
    process.waitUntilExit()
    let errorOutput = String(
        decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    return (process.terminationStatus, errorOutput)
}

private func exerciseFootprintAffineValidation(named validationCase: String) {
    let affine: Affine2D
    switch validationCase {
    case "axisCollapsed":
        affine = Affine2D(
            xAxis: SIMD2(0, 8),
            yAxis: SIMD2(0, 4),
            translation: SIMD2(32, 32)
        )
    case "singular":
        affine = Affine2D(
            xAxis: SIMD2(8, 8),
            yAxis: SIMD2(4, 4),
            translation: SIMD2(32, 32)
        )
    case "axisCollapsedY":
        affine = Affine2D(
            xAxis: SIMD2(8, 0),
            yAxis: SIMD2(4, 0),
            translation: SIMD2(32, 32)
        )
    case "identitySurvivor":
        affine = Affine2D(
            xAxis: SIMD2(8, 0),
            yAxis: SIMD2(0, 8),
            translation: SIMD2(32, 32)
        )
    case "rotatedSurvivor":
        affine = Affine2D(
            xAxis: SIMD2(0, 8),
            yAxis: SIMD2(-8, 0),
            translation: SIMD2(32, 32)
        )
    default:
        preconditionFailure(
            "Unknown footprint affine validation case: \(validationCase)"
        )
    }

    let fragments = TilingProjection.fragments(
        for: StampFootprint(
            brushToWorld: affine,
            localBounds: normalizedBrushBounds,
            coverageSymmetry: .oriented
        ),
        using: TilingStrategy(
            kind: .grid,
            tileSize: PatternSize(width: 64, height: 64)
        )
    )
    precondition(
        !fragments.isEmpty,
        "Valid footprint affine must survive projection"
    )
}

private func projectionTestExecutablePath() -> String {
    guard
        let optionIndex = CommandLine.arguments.firstIndex(of: "--test-bundle-path"),
        CommandLine.arguments.indices.contains(optionIndex + 1)
    else {
        preconditionFailure("Swift Testing test executable path is unavailable")
    }
    return CommandLine.arguments[optionIndex + 1]
}
