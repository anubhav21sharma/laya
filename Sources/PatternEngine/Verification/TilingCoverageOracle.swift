import Foundation
import simd

public enum OracleFootprint: Equatable, Sendable {
    case hardRound(radius: Float)
    case asymmetricTriangle
}

public struct OracleCoverage: Equatable, Sendable {
    public let pixelSize: PixelSize
    public let bytes: [UInt8]

    public init(pixelSize: PixelSize, bytes: [UInt8]) {
        let area = checkedPixelArea(
            pixelSize,
            message: "OracleCoverage pixel area must be Int-representable"
        )
        precondition(
            bytes.count == area,
            "OracleCoverage byte count must equal pixel area"
        )
        self.pixelSize = pixelSize
        self.bytes = bytes
    }
}

public struct OracleRasterResult: Equatable, Sendable {
    public let coverage: OracleCoverage
    public let canonicalCoordinatesBGRA: [UInt8]
    public let brushLocalCoordinatesBGRA: [UInt8]

    public init(
        coverage: OracleCoverage,
        canonicalCoordinatesBGRA: [UInt8],
        brushLocalCoordinatesBGRA: [UInt8]
    ) {
        let area = checkedPixelArea(
            coverage.pixelSize,
            message: "Oracle diagnostic pixel area must be Int-representable"
        )
        let (byteCount, overflowed) = area.multipliedReportingOverflow(by: 4)
        precondition(
            !overflowed,
            "Oracle diagnostic BGRA byte count must be Int-representable"
        )
        precondition(
            canonicalCoordinatesBGRA.count == byteCount,
            "Oracle canonical BGRA byte count must equal pixel area times four"
        )
        precondition(
            brushLocalCoordinatesBGRA.count == byteCount,
            "Oracle brush-local BGRA byte count must equal pixel area times four"
        )
        self.coverage = coverage
        self.canonicalCoordinatesBGRA = canonicalCoordinatesBGRA
        self.brushLocalCoordinatesBGRA = brushLocalCoordinatesBGRA
    }
}

public struct CoverageComparison: Equatable, Sendable {
    public let holeCount: Int
    public let phantomCount: Int
    public let maximumDelta: UInt8

    public init(
        holeCount: Int,
        phantomCount: Int,
        maximumDelta: UInt8
    ) {
        precondition(
            holeCount >= 0 && phantomCount >= 0,
            "Coverage comparison counts must be nonnegative"
        )
        self.holeCount = holeCount
        self.phantomCount = phantomCount
        self.maximumDelta = maximumDelta
    }
}

public enum TilingCoverageOracle {
    public static func renderCanonical(
        footprint: OracleFootprint,
        brushToWorld: Affine2D,
        tileSize: PixelSize,
        tiling: TilingKind,
        supersampling: Int
    ) -> OracleRasterResult {
        validateRenderInputs(
            footprint: footprint,
            brushToWorld: brushToWorld,
            tileSize: tileSize,
            supersampling: supersampling
        )

        let area = checkedPixelArea(
            tileSize,
            message: "TilingCoverageOracle pixel area must be Int-representable"
        )
        let inverse = brushToWorld.inverted()
        let localBounds = bounds(for: footprint)
        let worldBounds = transformedBounds(
            localBounds,
            by: brushToWorld
        )
        let worldPixelBounds = integerPixelBounds(worldBounds)
        let samplesPerPixel = supersampling * supersampling
        var sampleMasks = [UInt64](repeating: 0, count: area)
        var brushRedSums = [UInt16](repeating: 0, count: area)
        var brushGreenSums = [UInt16](repeating: 0, count: area)

        for worldPixelY in worldPixelBounds.minimumY..<worldPixelBounds.maximumY {
            for worldPixelX in worldPixelBounds.minimumX..<worldPixelBounds.maximumX {
                for subY in 0..<supersampling {
                    for subX in 0..<supersampling {
                        let world = phaseAlignedWorldSample(
                            pixelX: worldPixelX,
                            pixelY: worldPixelY,
                            subpixelX: subX,
                            subpixelY: subY,
                            supersampling: supersampling,
                            tileSize: tileSize,
                            tiling: tiling
                        )
                        let brushLocal = inverse.applying(to: world)
                        guard contains(brushLocal, footprint: footprint) else {
                            continue
                        }
                        let normalizedBrushLocal = normalizedBrushCoordinate(
                            brushLocal,
                            footprint: footprint
                        )
                        let destinations = directFoldDestinations(
                            world,
                            tileSize: tileSize,
                            tiling: tiling
                        )

                        for destination in destinations {
                            let address = sampleAddress(
                                destination,
                                tileSize: tileSize,
                                supersampling: supersampling
                            )
                            let bit = UInt64(1) << UInt64(address.bitIndex)
                            guard sampleMasks[address.pixelIndex] & bit == 0 else {
                                continue
                            }
                            sampleMasks[address.pixelIndex] |= bit
                            brushRedSums[address.pixelIndex] += UInt16(
                                encodeSigned(normalizedBrushLocal.x)
                            )
                            brushGreenSums[address.pixelIndex] += UInt16(
                                encodeSigned(normalizedBrushLocal.y)
                            )
                        }
                    }
                }
            }
        }

        var coverageBytes = [UInt8](repeating: 0, count: area)
        var canonicalBGRA = [UInt8](repeating: 0, count: area * 4)
        var brushBGRA = [UInt8](repeating: 0, count: area * 4)
        for pixelIndex in 0..<area {
            let coveredSamples = sampleMasks[pixelIndex].nonzeroBitCount
            let alpha = averagedByte(
                sum: coveredSamples * 255,
                divisor: samplesPerPixel
            )
            coverageBytes[pixelIndex] = alpha
            let byteOffset = pixelIndex * 4
            let canonicalSums = canonicalCoordinateSums(
                pixelIndex: pixelIndex,
                sampleMask: sampleMasks[pixelIndex],
                tileSize: tileSize,
                supersampling: supersampling
            )
            canonicalBGRA[byteOffset + 1] = averagedByte(
                sum: canonicalSums.green,
                divisor: samplesPerPixel
            )
            canonicalBGRA[byteOffset + 2] = averagedByte(
                sum: canonicalSums.red,
                divisor: samplesPerPixel
            )
            canonicalBGRA[byteOffset + 3] = alpha
            brushBGRA[byteOffset + 1] = averagedByte(
                sum: Int(brushGreenSums[pixelIndex]),
                divisor: samplesPerPixel
            )
            brushBGRA[byteOffset + 2] = averagedByte(
                sum: Int(brushRedSums[pixelIndex]),
                divisor: samplesPerPixel
            )
            brushBGRA[byteOffset + 3] = alpha
        }

        return OracleRasterResult(
            coverage: OracleCoverage(
                pixelSize: tileSize,
                bytes: coverageBytes
            ),
            canonicalCoordinatesBGRA: canonicalBGRA,
            brushLocalCoordinatesBGRA: brushBGRA
        )
    }

    public static func compare(
        expected: OracleCoverage,
        actual: OracleCoverage,
        boundaryTolerance: UInt8
    ) -> CoverageComparison {
        precondition(
            expected.pixelSize == actual.pixelSize,
            "Coverage comparison requires equal pixel sizes"
        )
        precondition(
            boundaryTolerance <= 1,
            "Coverage comparison boundary tolerance must be 0 or 1"
        )

        var holeCount = 0
        var phantomCount = 0
        var maximumDelta: UInt8 = 0
        for (expectedByte, actualByte) in zip(expected.bytes, actual.bytes) {
            let signedDelta = Int(expectedByte) - Int(actualByte)
            let delta = UInt8(abs(signedDelta))
            maximumDelta = max(maximumDelta, delta)
            guard delta > boundaryTolerance else {
                continue
            }
            if signedDelta > 0 {
                holeCount += 1
            } else {
                phantomCount += 1
            }
        }
        return CoverageComparison(
            holeCount: holeCount,
            phantomCount: phantomCount,
            maximumDelta: maximumDelta
        )
    }
}

private struct FloatBounds {
    let minimum: SIMD2<Float>
    let maximum: SIMD2<Float>
}

private struct IntegerPixelBounds {
    let minimumX: Int
    let maximumX: Int
    let minimumY: Int
    let maximumY: Int
}

private struct SampleAddress {
    let pixelIndex: Int
    let bitIndex: Int
}

private func checkedPixelArea(
    _ pixelSize: PixelSize,
    message: String
) -> Int {
    let (area, overflowed) = pixelSize.width.multipliedReportingOverflow(
        by: pixelSize.height
    )
    precondition(!overflowed, message)
    return area
}

private func validateRenderInputs(
    footprint: OracleFootprint,
    brushToWorld: Affine2D,
    tileSize: PixelSize,
    supersampling: Int
) {
    precondition(
        (64...4_096).contains(tileSize.width),
        "TilingCoverageOracle tile width must be in 64...4096"
    )
    precondition(
        (64...4_096).contains(tileSize.height),
        "TilingCoverageOracle tile height must be in 64...4096"
    )
    precondition(
        (1...8).contains(supersampling),
        "TilingCoverageOracle supersampling must be in 1...8"
    )
    if case let .hardRound(radius) = footprint {
        precondition(
            radius.isFinite && radius >= 1,
            "TilingCoverageOracle radius must be finite and at least 1"
        )
        let maximum = min(
            Float(1_000),
            4 * Float(min(tileSize.width, tileSize.height))
        )
        precondition(
            radius <= maximum,
            "TilingCoverageOracle radius exceeds the supported tile-relative maximum"
        )
    }

    let determinant = brushToWorld.xAxis.x * brushToWorld.yAxis.y
        - brushToWorld.xAxis.y * brushToWorld.yAxis.x
    precondition(
        determinant.isFinite && abs(determinant) >= Float.ulpOfOne,
        "TilingCoverageOracle brush-to-world transform must be nonsingular"
    )
    _ = checkedPixelArea(
        tileSize,
        message: "TilingCoverageOracle pixel area must be Int-representable"
    )
}

private func bounds(for footprint: OracleFootprint) -> FloatBounds {
    switch footprint {
    case let .hardRound(radius):
        return FloatBounds(
            minimum: SIMD2(repeating: -radius),
            maximum: SIMD2(repeating: radius)
        )
    case .asymmetricTriangle:
        return FloatBounds(
            minimum: SIMD2(-0.75, -0.60),
            maximum: SIMD2(0.85, 0.90)
        )
    }
}

private func transformedBounds(
    _ bounds: FloatBounds,
    by affine: Affine2D
) -> FloatBounds {
    let corners = [
        bounds.minimum,
        SIMD2(bounds.maximum.x, bounds.minimum.y),
        bounds.maximum,
        SIMD2(bounds.minimum.x, bounds.maximum.y),
    ].map { affine.applying(to: $0) }
    return FloatBounds(
        minimum: SIMD2(
            corners.map(\.x).min()!,
            corners.map(\.y).min()!
        ),
        maximum: SIMD2(
            corners.map(\.x).max()!,
            corners.map(\.y).max()!
        )
    )
}

private func integerPixelBounds(
    _ bounds: FloatBounds
) -> IntegerPixelBounds {
    let minimumX = floor(bounds.minimum.x)
    let maximumX = ceil(bounds.maximum.x)
    let minimumY = floor(bounds.minimum.y)
    let maximumY = ceil(bounds.maximum.y)
    for value in [minimumX, maximumX, minimumY, maximumY] {
        precondition(
            value.isFinite
                && value >= Float(Int.min)
                && value < Float(Int.max),
            "TilingCoverageOracle world sample bounds must be Int-representable"
        )
    }
    let (paddedMinimumX, minimumXOverflowed) =
        Int(minimumX).subtractingReportingOverflow(1)
    let (paddedMaximumX, maximumXOverflowed) =
        Int(maximumX).addingReportingOverflow(1)
    let (paddedMinimumY, minimumYOverflowed) =
        Int(minimumY).subtractingReportingOverflow(1)
    let (paddedMaximumY, maximumYOverflowed) =
        Int(maximumY).addingReportingOverflow(1)
    precondition(
        !minimumXOverflowed
            && !maximumXOverflowed
            && !minimumYOverflowed
            && !maximumYOverflowed,
        "TilingCoverageOracle padded world sample bounds must be Int-representable"
    )
    return IntegerPixelBounds(
        minimumX: paddedMinimumX,
        maximumX: paddedMaximumX,
        minimumY: paddedMinimumY,
        maximumY: paddedMaximumY
    )
}

private func sampleOffset(
    subpixel: Int,
    supersampling: Int
) -> Float {
    (Float(subpixel) + 0.5) / Float(supersampling)
}

private func phaseAlignedWorldSample(
    pixelX: Int,
    pixelY: Int,
    subpixelX: Int,
    subpixelY: Int,
    supersampling: Int,
    tileSize: PixelSize,
    tiling: TilingKind
) -> SIMD2<Float> {
    let baseX = sampleOffset(
        subpixel: subpixelX,
        supersampling: supersampling
    )
    let baseY = sampleOffset(
        subpixel: subpixelY,
        supersampling: supersampling
    )
    var worldX = Float(pixelX) + baseX
    var worldY = Float(pixelY) + baseY

    switch tiling {
    case .halfDrop:
        let width = Float(tileSize.width)
        let column = cellIndex(worldX, extent: width)
        let phase = column.isMultiple(of: 2)
            ? 0
            : Float(tileSize.height) * 0.5
        worldY = Float(pixelY) + phaseAlignedOffset(
            subpixel: subpixelY,
            supersampling: supersampling,
            phase: phase
        )
    case .brick:
        let height = Float(tileSize.height)
        let row = cellIndex(worldY, extent: height)
        let phase = row.isMultiple(of: 2)
            ? 0
            : Float(tileSize.width) * 0.5
        worldX = Float(pixelX) + phaseAlignedOffset(
            subpixel: subpixelX,
            supersampling: supersampling,
            phase: phase
        )
    case .grid, .mirrorX, .mirrorY, .mirrorXY, .rotational:
        break
    }
    return SIMD2(worldX, worldY)
}

private func phaseAlignedOffset(
    subpixel: Int,
    supersampling: Int,
    phase: Float
) -> Float {
    let spacing = 1 / Float(supersampling)
    var first = (phase + spacing * 0.5)
        .truncatingRemainder(dividingBy: spacing)
    if first < 0 {
        first += spacing
    }
    if first < 0.0001 || spacing - first < 0.0001 {
        first = 0
    }
    return first + Float(subpixel) * spacing
}

private func contains(
    _ point: SIMD2<Float>,
    footprint: OracleFootprint
) -> Bool {
    switch footprint {
    case let .hardRound(radius):
        return simd_dot(point, point) <= radius * radius
    case .asymmetricTriangle:
        let first = SIMD2<Float>(-0.75, -0.60)
        let second = SIMD2<Float>(0.85, -0.20)
        let third = SIMD2<Float>(-0.10, 0.90)
        return signedEdge(first, second, point) >= 0
            && signedEdge(second, third, point) >= 0
            && signedEdge(third, first, point) >= 0
    }
}

private func signedEdge(
    _ start: SIMD2<Float>,
    _ end: SIMD2<Float>,
    _ point: SIMD2<Float>
) -> Float {
    let edge = end - start
    let relative = point - start
    return edge.x * relative.y - edge.y * relative.x
}

private func normalizedBrushCoordinate(
    _ point: SIMD2<Float>,
    footprint: OracleFootprint
) -> SIMD2<Float> {
    switch footprint {
    case let .hardRound(radius):
        return point / radius
    case .asymmetricTriangle:
        return point
    }
}

private func directFoldDestinations(
    _ world: SIMD2<Float>,
    tileSize: PixelSize,
    tiling: TilingKind
) -> [SIMD2<Float>] {
    let width = Float(tileSize.width)
    let height = Float(tileSize.height)

    switch tiling {
    case .grid:
        return [
            SIMD2(
                positiveFold(world.x, extent: width),
                positiveFold(world.y, extent: height)
            ),
        ]
    case .halfDrop:
        let column = cellIndex(world.x, extent: width)
        let phaseY = column.isMultiple(of: 2) ? 0 : height * 0.5
        return [
            SIMD2(
                positiveFold(world.x, extent: width),
                positiveFold(world.y - phaseY, extent: height)
            ),
        ]
    case .brick:
        let row = cellIndex(world.y, extent: height)
        let phaseX = row.isMultiple(of: 2) ? 0 : width * 0.5
        return [
            SIMD2(
                positiveFold(world.x - phaseX, extent: width),
                positiveFold(world.y, extent: height)
            ),
        ]
    case .mirrorX, .mirrorY, .mirrorXY:
        let column = cellIndex(world.x, extent: width)
        let row = cellIndex(world.y, extent: height)
        let localX = positiveFold(world.x, extent: width)
        let localY = positiveFold(world.y, extent: height)
        let reflectsX = (tiling == .mirrorX || tiling == .mirrorXY)
            && !column.isMultiple(of: 2)
        let reflectsY = (tiling == .mirrorY || tiling == .mirrorXY)
            && !row.isMultiple(of: 2)
        return [
            SIMD2(
                reflectsX
                    ? positiveFold(width - localX, extent: width)
                    : localX,
                reflectsY
                    ? positiveFold(height - localY, extent: height)
                    : localY
            ),
        ]
    case .rotational:
        let identity = SIMD2(
            positiveFold(world.x, extent: width),
            positiveFold(world.y, extent: height)
        )
        let rotated = SIMD2(
            positiveFold(width - identity.x, extent: width),
            positiveFold(height - identity.y, extent: height)
        )
        return rotated == identity ? [identity] : [identity, rotated]
    }
}

private func positiveFold(_ value: Float, extent: Float) -> Float {
    let remainder = value.truncatingRemainder(dividingBy: extent)
    if remainder == 0 {
        return 0
    }
    if remainder < 0 {
        return min(remainder + extent, extent.nextDown)
    }
    return remainder
}

private func cellIndex(_ coordinate: Float, extent: Float) -> Int {
    let value = floor(coordinate / extent)
    precondition(
        value.isFinite
            && value >= Float(Int.min)
            && value < Float(Int.max),
        "TilingCoverageOracle cell index must be Int-representable"
    )
    return Int(value)
}

private func sampleAddress(
    _ destination: SIMD2<Float>,
    tileSize: PixelSize,
    supersampling: Int
) -> SampleAddress {
    let scaledX = destination.x * Float(supersampling) - 0.5
    let scaledY = destination.y * Float(supersampling) - 0.5
    let roundedX = scaledX.rounded()
    let roundedY = scaledY.rounded()
    precondition(
        abs(scaledX - roundedX) <= 0.01
            && abs(scaledY - roundedY) <= 0.01,
        "TilingCoverageOracle folded sample must remain on the supersample lattice"
    )
    let sampleX = Int(roundedX)
    let sampleY = Int(roundedY)
    let sampleWidth = tileSize.width * supersampling
    let sampleHeight = tileSize.height * supersampling
    precondition(
        sampleX >= 0 && sampleX < sampleWidth
            && sampleY >= 0 && sampleY < sampleHeight,
        "TilingCoverageOracle folded sample must remain inside canonical storage"
    )
    let pixelX = sampleX / supersampling
    let pixelY = sampleY / supersampling
    let subX = sampleX % supersampling
    let subY = sampleY % supersampling
    return SampleAddress(
        pixelIndex: pixelY * tileSize.width + pixelX,
        bitIndex: subY * supersampling + subX
    )
}

private func canonicalCoordinateSums(
    pixelIndex: Int,
    sampleMask: UInt64,
    tileSize: PixelSize,
    supersampling: Int
) -> (red: Int, green: Int) {
    let pixelX = pixelIndex % tileSize.width
    let pixelY = pixelIndex / tileSize.width
    var red = 0
    var green = 0
    var remaining = sampleMask
    while remaining != 0 {
        let bitIndex = remaining.trailingZeroBitCount
        remaining &= remaining &- 1
        let subpixelX = bitIndex % supersampling
        let subpixelY = bitIndex / supersampling
        let canonicalX = Float(pixelX) + sampleOffset(
            subpixel: subpixelX,
            supersampling: supersampling
        )
        let canonicalY = Float(pixelY) + sampleOffset(
            subpixel: subpixelY,
            supersampling: supersampling
        )
        red += Int(encodeUnit(canonicalX / Float(tileSize.width)))
        green += Int(encodeUnit(canonicalY / Float(tileSize.height)))
    }
    return (red, green)
}

private func encodeUnit(_ value: Float) -> UInt8 {
    UInt8(max(0, min(255, Int((value * 255).rounded()))))
}

private func encodeSigned(_ value: Float) -> UInt8 {
    encodeUnit(value * 0.5 + 0.5)
}

private func averagedByte(sum: Int, divisor: Int) -> UInt8 {
    UInt8((sum + divisor / 2) / divisor)
}
