import Foundation
import PatternEngine

/// Test-only geometric authority for opaque hard-round stamp support.
///
/// Renderer pixels are deliberately not used to construct expectations. Pixels
/// wholly inside the analytic support must be present, pixels wholly outside it
/// must be clear, and antialiased boundary pixels are ignored as color truth.
struct OpaqueStampSupportOracle {
    struct Mask: Equatable, Sendable {
        let pixelSize: PixelSize
        private(set) var values: [Bool]

        init(pixelSize: PixelSize, values: [Bool]) {
            precondition(values.count == pixelSize.width * pixelSize.height)
            self.pixelSize = pixelSize
            self.values = values
        }

        subscript(x: Int, y: Int) -> Bool {
            get { values[y * pixelSize.width + x] }
            set { values[y * pixelSize.width + x] = newValue }
        }

        func shifted(dx: Int, dy: Int) -> Self {
            var shifted = Self(
                pixelSize: pixelSize,
                values: .init(
                    repeating: false,
                    count: pixelSize.width * pixelSize.height
                )
            )
            for y in 0 ..< pixelSize.height {
                for x in 0 ..< pixelSize.width where self[x, y] {
                    let targetX = x + dx
                    let targetY = y + dy
                    guard targetX >= 0, targetX < pixelSize.width,
                          targetY >= 0, targetY < pixelSize.height
                    else { continue }
                    shifted[targetX, targetY] = true
                }
            }
            return shifted
        }

        func mirroredHorizontally() -> Self {
            var mirrored = self
            for y in 0 ..< pixelSize.height {
                for x in 0 ..< pixelSize.width {
                    mirrored[pixelSize.width - 1 - x, y] = self[x, y]
                }
            }
            return mirrored
        }

        func expandedSupportToTheRight(by pixelCount: Int) -> Self {
            precondition(pixelCount > 0)
            var expanded = self
            var maximumX = -1
            for y in 0 ..< pixelSize.height {
                for x in 0 ..< pixelSize.width where self[x, y] {
                    maximumX = max(maximumX, x)
                }
            }
            guard maximumX >= 0, maximumX + pixelCount < pixelSize.width else {
                return expanded
            }
            for y in 0 ..< pixelSize.height where self[maximumX, y] {
                for offset in 1 ... pixelCount {
                    expanded[maximumX + offset, y] = true
                }
            }
            return expanded
        }
    }

    struct Comparison: Equatable, Sendable {
        let missingInteriorPixelCount: Int
        let unexpectedExteriorPixelCount: Int
        let expectedSupportBounds: PixelRect?
        let actualSupportBounds: PixelRect?
        let maximumSupportBoundsEdgeDelta: Int
        let supportBoundsEdgeTolerance: Int

        /// Thresholded raster support may move one edge by one pixel inside
        /// the independently ignored AA/presentation annulus. Larger extent
        /// drift is geometry failure even when interior/exterior counts happen
        /// to miss it.
        var isAccepted: Bool {
            missingInteriorPixelCount == 0 && unexpectedExteriorPixelCount == 0
                && maximumSupportBoundsEdgeDelta
                    <= supportBoundsEdgeTolerance
        }
    }

    private enum Classification: UInt8, Sendable {
        case mustClear
        case boundary
        case mustCover
    }

    let pixelSize: PixelSize
    private let classifications: [Classification]
    private let supportBoundsEdgeTolerance: Int

    static func plainDisk(
        pixelSize: PixelSize,
        center: SIMD2<Float>,
        radius: Float
    ) -> Self {
        precondition(center.x.isFinite && center.y.isFinite)
        precondition(radius.isFinite && radius > 0)
        return diskUnion(
            pixelSize: pixelSize,
            centers: [center],
            radius: radius
        )
    }

    static func periodicHardRound(
        tileSize: PixelSize,
        worldCenter: SIMD2<Float>,
        radius: Float,
        tiling: TilingKind
    ) -> Self {
        let raster = TilingCoverageOracle.renderCanonical(
            footprint: .hardRound(radius: radius),
            brushToWorld: Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                translation: worldCenter
            ),
            tileSize: tileSize,
            tiling: tiling,
            supersampling: 4
        )
        return Self(
            pixelSize: tileSize,
            classifications: raster.coverage.bytes.map {
                switch $0 {
                case 0: .mustClear
                case 255: .mustCover
                default: .boundary
                }
            },
            supportBoundsEdgeTolerance: 1
        )
    }

    static func radialHardRound(
        canvasSize: PixelSize,
        sourceCenter: WorldPoint,
        radius: Float,
        configuration: RadialSymmetryConfiguration
    ) -> Self {
        let centers = RadialCoverageOracle.orbit(
            of: sourceCenter,
            configuration: configuration
        ).map(\.simd)
        return diskUnion(
            pixelSize: canvasSize,
            centers: centers,
            radius: radius,
            // The analytic pixel footprint contributes half a pixel diagonal.
            // Radial presentation then performs one bilinear lookup whose
            // support contributes one more half diagonal. Their sum is √2.
            boundaryRadius: Float(2).squareRoot()
        )
    }

    func analyticMask() -> Mask {
        Mask(
            pixelSize: pixelSize,
            values: classifications.map { $0 != .mustClear }
        )
    }

    func compare(_ actual: Mask) -> Comparison {
        precondition(actual.pixelSize == pixelSize)
        var missingInteriorPixelCount = 0
        var unexpectedExteriorPixelCount = 0
        for index in classifications.indices {
            switch classifications[index] {
            case .mustCover where !actual.values[index]:
                missingInteriorPixelCount += 1
            case .mustClear where actual.values[index]:
                unexpectedExteriorPixelCount += 1
            default:
                break
            }
        }
        let expectedBounds = supportBounds(
            classifications.map { $0 != .mustClear }
        )
        let actualBounds = supportBounds(actual.values)
        return Comparison(
            missingInteriorPixelCount: missingInteriorPixelCount,
            unexpectedExteriorPixelCount: unexpectedExteriorPixelCount,
            expectedSupportBounds: expectedBounds,
            actualSupportBounds: actualBounds,
            maximumSupportBoundsEdgeDelta: boundsEdgeDelta(
                expectedBounds,
                actualBounds
            ),
            supportBoundsEdgeTolerance: supportBoundsEdgeTolerance
        )
    }

    private func boundsEdgeDelta(
        _ expected: PixelRect?,
        _ actual: PixelRect?
    ) -> Int {
        switch (expected, actual) {
        case (nil, nil): 0
        case let (.some(expected), .some(actual)):
            max(
                abs(expected.minX - actual.minX),
                abs(expected.minY - actual.minY),
                abs(expected.maxX - actual.maxX),
                abs(expected.maxY - actual.maxY)
            )
        default: .max
        }
    }

    private func supportBounds(_ values: [Bool]) -> PixelRect? {
        var minX = pixelSize.width
        var minY = pixelSize.height
        var maxX = -1
        var maxY = -1
        for y in 0 ..< pixelSize.height {
            for x in 0 ..< pixelSize.width where values[y * pixelSize.width + x] {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return PixelRect(
            minX: minX,
            minY: minY,
            maxX: maxX + 1,
            maxY: maxY + 1
        )
    }

    private static func diskUnion(
        pixelSize: PixelSize,
        centers: [SIMD2<Float>],
        radius: Float,
        boundaryRadius: Float = Float(0.5).squareRoot()
    ) -> Self {
        precondition(boundaryRadius.isFinite && boundaryRadius >= 0)
        let mustCoverRadius = max(0, radius - boundaryRadius)
        let mustClearRadius = radius + boundaryRadius
        let mustCoverSquared = mustCoverRadius * mustCoverRadius
        let mustClearSquared = mustClearRadius * mustClearRadius
        var classifications = [Classification](
            repeating: .mustClear,
            count: pixelSize.width * pixelSize.height
        )

        for y in 0 ..< pixelSize.height {
            for x in 0 ..< pixelSize.width {
                let sample = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                var nearestSquared = Float.greatestFiniteMagnitude
                for center in centers {
                    let delta = sample - center
                    nearestSquared = min(
                        nearestSquared,
                        delta.x * delta.x + delta.y * delta.y
                    )
                }
                classifications[y * pixelSize.width + x] =
                    nearestSquared <= mustCoverSquared
                    ? .mustCover
                    : nearestSquared > mustClearSquared ? .mustClear : .boundary
            }
        }
        return Self(
            pixelSize: pixelSize,
            classifications: classifications,
            supportBoundsEdgeTolerance: max(
                1,
                Int(ceil(boundaryRadius))
            )
        )
    }
}
