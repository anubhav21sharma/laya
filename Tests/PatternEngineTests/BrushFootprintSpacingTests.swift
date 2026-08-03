import Foundation
import PatternEngine
import Testing

@Suite("Brush footprint distance spacing")
struct BrushFootprintSpacingTests {
    @Test("authored spacing inside safety bounds is preserved")
    func authoredSpacingInsideSafetyBoundsIsPreserved() throws {
        let carry = try BrushFootprintSpacing.nextCarry(
            supportWidth: 20,
            baseSpacingFraction: 0.1,
            dynamicSpacing: 1.5,
            maximumSpacingFraction: 0.4
        )

        expectSpacingClose(carry, 3)
    }

    @Test("one world pixel floor prevents runaway density")
    func oneWorldPixelFloorPreventsRunawayDensity() throws {
        let carry = try BrushFootprintSpacing.nextCarry(
            supportWidth: 4,
            baseSpacingFraction: 0.05,
            dynamicSpacing: 0.5,
            maximumSpacingFraction: 0.25
        )

        expectSpacingClose(carry, 1)
    }

    @Test("support-relative ceiling prevents visible authored gaps")
    func supportRelativeCeilingPreventsVisibleAuthoredGaps() throws {
        let carry = try BrushFootprintSpacing.nextCarry(
            supportWidth: 20,
            baseSpacingFraction: 0.25,
            dynamicSpacing: 4,
            maximumSpacingFraction: 0.4
        )

        expectSpacingClose(carry, 8)
    }

    @Test("floor remains authoritative when support ceiling is subpixel")
    func floorRemainsAuthoritativeWhenSupportCeilingIsSubpixel() throws {
        let carry = try BrushFootprintSpacing.nextCarry(
            supportWidth: 0.5,
            baseSpacingFraction: 0.1,
            dynamicSpacing: 1,
            maximumSpacingFraction: 0.2
        )

        expectSpacingClose(carry, 1)
    }

    @Test("all nonfinite and nonpositive factors fail with typed errors")
    func invalidFactorsFailWithTypedErrors() {
        for supportWidth in [Float.nan, .infinity, 0, -1] {
            #expect(throws: BrushFootprintSpacingError.invalidSupportWidth) {
                try BrushFootprintSpacing.nextCarry(
                    supportWidth: supportWidth,
                    baseSpacingFraction: 0.1,
                    dynamicSpacing: 1,
                    maximumSpacingFraction: 0.2
                )
            }
        }
        for baseSpacingFraction in [Float.nan, .infinity, 0, -1] {
            #expect(
                throws: BrushFootprintSpacingError
                    .invalidBaseSpacingFraction
            ) {
                try BrushFootprintSpacing.nextCarry(
                    supportWidth: 10,
                    baseSpacingFraction: baseSpacingFraction,
                    dynamicSpacing: 1,
                    maximumSpacingFraction: 0.2
                )
            }
        }
        for dynamicSpacing in [Float.nan, .infinity, 0, -1] {
            #expect(throws: BrushFootprintSpacingError.invalidDynamicSpacing) {
                try BrushFootprintSpacing.nextCarry(
                    supportWidth: 10,
                    baseSpacingFraction: 0.1,
                    dynamicSpacing: dynamicSpacing,
                    maximumSpacingFraction: 0.2
                )
            }
        }
        for maximumSpacingFraction in [Float.nan, .infinity, 0, -1] {
            #expect(
                throws: BrushFootprintSpacingError
                    .invalidMaximumSpacingFraction
            ) {
                try BrushFootprintSpacing.nextCarry(
                    supportWidth: 10,
                    baseSpacingFraction: 0.1,
                    dynamicSpacing: 1,
                    maximumSpacingFraction: maximumSpacingFraction
                )
            }
        }
        #expect(
            throws: BrushFootprintSpacingError.invalidMaximumSpacingFraction
        ) {
            try BrushFootprintSpacing.nextCarry(
                supportWidth: 10,
                baseSpacingFraction: 0.3,
                dynamicSpacing: 1,
                maximumSpacingFraction: 0.2
            )
        }
    }

    @Test("overflow in authored or ceiling distance is rejected")
    func overflowingDistanceIsRejected() {
        #expect(throws: BrushFootprintSpacingError.arithmeticOverflow) {
            try BrushFootprintSpacing.nextCarry(
                supportWidth: .greatestFiniteMagnitude / 2,
                baseSpacingFraction: 1,
                dynamicSpacing: 4,
                maximumSpacingFraction: 1
            )
        }
        #expect(throws: BrushFootprintSpacingError.arithmeticOverflow) {
            try BrushFootprintSpacing.nextCarry(
                supportWidth: .greatestFiniteMagnitude / 2,
                baseSpacingFraction: 1,
                dynamicSpacing: 1,
                maximumSpacingFraction: 4
            )
        }
    }

    @Test("abrupt footprint turns recompute carry from current geometry")
    func abruptFootprintTurnsRecomputeCarryFromCurrentGeometry() throws {
        let layer = try BrushTipSupportLayer(
            definition: .analyticRectangle,
            xAxis: SIMD2(3, 0),
            yAxis: SIMD2(0, 0.5),
            offset: .zero
        )
        let forward = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(1, 0)
        )
        let turned = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(0, 1)
        )
        let reversed = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(-1, 0)
        )

        let forwardCarry = try nextHalfSupportCarry(width: forward.width)
        let turnedCarry = try nextHalfSupportCarry(width: turned.width)
        let reversedCarry = try nextHalfSupportCarry(width: reversed.width)

        expectSpacingClose(forwardCarry, 3)
        expectSpacingClose(turnedCarry, 1)
        expectSpacingClose(reversedCarry, 3)
    }

    @Test("independent CPU raster oracle rejects gaps at a conservative ceiling")
    func independentCPURasterOracleRejectsGapsAtConservativeCeiling() throws {
        let diagonalComponent = Float(1 / sqrt(2.0))
        let cases = [
            RasterOracleCase(
                name: "horizontal ellipse",
                tip: RasterTip(
                    kind: .ellipse,
                    xAxis: SIMD2(4, 0),
                    yAxis: SIMD2(0, 1),
                    offset: .zero
                ),
                tangent: SIMD2(1, 0),
                literalSupportWidth: 8
            ),
            RasterOracleCase(
                name: "diagonal rectangle",
                tip: RasterTip(
                    kind: .rectangle,
                    xAxis: SIMD2(
                        2 * diagonalComponent,
                        2 * diagonalComponent
                    ),
                    yAxis: SIMD2(
                        -diagonalComponent,
                        diagonalComponent
                    ),
                    offset: .zero
                ),
                tangent: SIMD2(repeating: diagonalComponent),
                literalSupportWidth: 4
            ),
            RasterOracleCase(
                name: "vertical rotated ellipse",
                tip: RasterTip(
                    kind: .ellipse,
                    xAxis: SIMD2(
                        3 * diagonalComponent,
                        3 * diagonalComponent
                    ),
                    yAxis: SIMD2(
                        -diagonalComponent,
                        diagonalComponent
                    ),
                    offset: .zero
                ),
                tangent: SIMD2(0, 1),
                literalSupportWidth: 4.472_136
            ),
            RasterOracleCase(
                name: "translated asymmetric bounds",
                tip: RasterTip(
                    kind: .bounds(
                        minX: -0.25,
                        maxX: 0.75,
                        minY: -0.5,
                        maxY: 0.5
                    ),
                    xAxis: SIMD2(2, 0),
                    yAxis: SIMD2(0, 1),
                    offset: SIMD2(0.5, 0)
                ),
                tangent: SIMD2(1, 0),
                literalSupportWidth: 2
            ),
        ]

        for fixture in cases {
            let carry = try BrushFootprintSpacing.nextCarry(
                supportWidth: fixture.literalSupportWidth,
                baseSpacingFraction: 0.25,
                dynamicSpacing: 5,
                maximumSpacingFraction: 0.4
            )
            let firstGap = firstUncoveredDistance(
                tip: fixture.tip,
                tangent: fixture.tangent,
                carry: carry,
                strokeLength: 24,
                samplingStep: 0.02
            )

            #expect(
                firstGap == nil,
                "\(fixture.name) left a raster gap at \(firstGap ?? -1)"
            )
        }
    }

    @Test("independent placement oracle rejects runaway floor density")
    func independentPlacementOracleRejectsRunawayFloorDensity() throws {
        let carry = try BrushFootprintSpacing.nextCarry(
            supportWidth: 0.000_1,
            baseSpacingFraction: 0.1,
            dynamicSpacing: 0.1,
            maximumSpacingFraction: 0.2
        )

        let count = rasterPlacementCount(pathLength: 64, carry: carry)

        #expect(count == 65)
    }
}

private struct RasterOracleCase {
    let name: String
    let tip: RasterTip
    let tangent: SIMD2<Float>
    let literalSupportWidth: Float
}

/// Test-only oracle that rasterizes primitive membership by inverting the
/// affine frame. It intentionally does not call BrushTipSupport or duplicate
/// its projection formulas.
private struct RasterTip {
    enum Kind {
        case ellipse
        case rectangle
        case bounds(minX: Float, maxX: Float, minY: Float, maxY: Float)
    }

    let kind: Kind
    let xAxis: SIMD2<Float>
    let yAxis: SIMD2<Float>
    let offset: SIMD2<Float>

    func contains(
        worldPoint: SIMD2<Float>,
        dabOrigin: SIMD2<Float>
    ) -> Bool {
        let relative = worldPoint - dabOrigin - offset
        let determinant = xAxis.x * yAxis.y - xAxis.y * yAxis.x
        let localX = (
            relative.x * yAxis.y - relative.y * yAxis.x
        ) / determinant
        let localY = (
            xAxis.x * relative.y - xAxis.y * relative.x
        ) / determinant
        let tolerance: Float = 0.000_1

        switch kind {
        case .ellipse:
            return localX * localX + localY * localY <= 1 + tolerance
        case .rectangle:
            return abs(localX) <= 1 + tolerance
                && abs(localY) <= 1 + tolerance
        case let .bounds(minX, maxX, minY, maxY):
            return localX >= minX - tolerance
                && localX <= maxX + tolerance
                && localY >= minY - tolerance
                && localY <= maxY + tolerance
        }
    }
}

private func firstUncoveredDistance(
    tip: RasterTip,
    tangent: SIMD2<Float>,
    carry: Float,
    strokeLength: Float,
    samplingStep: Float
) -> Float? {
    let sampleCount = Int(ceil(strokeLength / samplingStep))
    let normal = SIMD2(-tangent.y, tangent.x)
    for sampleIndex in 0...sampleCount {
        let distance = min(
            strokeLength,
            Float(sampleIndex) * samplingStep
        )
        let nearbyIndex = Int(floor(distance / carry))
        for bandIndex in -1...1 {
            let worldPoint = tangent * distance
                + normal * (Float(bandIndex) * 0.2)
            var covered = false
            for dabIndex in (nearbyIndex - 2)...(nearbyIndex + 2) {
                let dabOrigin = tangent * (Float(dabIndex) * carry)
                if tip.contains(
                    worldPoint: worldPoint,
                    dabOrigin: dabOrigin
                ) {
                    covered = true
                    break
                }
            }
            if !covered {
                return distance
            }
        }
    }
    return nil
}

private func rasterPlacementCount(pathLength: Float, carry: Float) -> Int {
    Int(ceil(pathLength / carry)) + 1
}

private func nextHalfSupportCarry(width: Float) throws -> Float {
    try BrushFootprintSpacing.nextCarry(
        supportWidth: width,
        baseSpacingFraction: 0.5,
        dynamicSpacing: 1,
        maximumSpacingFraction: 0.5
    )
}

private func expectSpacingClose(
    _ actual: Float,
    _ expected: Float,
    tolerance: Float = 0.000_01,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(actual - expected) <= tolerance,
        "Expected \(actual) to be within \(tolerance) of \(expected)",
        sourceLocation: sourceLocation
    )
}
