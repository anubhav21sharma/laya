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
        let inverse = invertedBrushTransform(brushToWorld)
        let worldBounds = transformedFootprintBounds(
            footprint,
            by: brushToWorld
        )
        let worldPixelBounds = integerPixelBounds(worldBounds)
        validateSampleWork(
            worldPixelBounds,
            tileSize: tileSize,
            supersampling: supersampling
        )
        let samplesPerPixel = supersampling * supersampling
        var sampleMasks = [UInt64](repeating: 0, count: area)
        var candidateCells: Set<DirectCell> = []

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
                        candidateCells.insert(
                            directCell(
                                containing: world,
                                tileSize: tileSize,
                                tiling: tiling
                            )
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
                        }
                    }
                }
            }
        }

        let brushSums = brushCoordinateSums(
            sampleMasks: sampleMasks,
            candidateCells: candidateCells,
            footprint: footprint,
            brushToWorld: brushToWorld,
            worldToBrush: inverse,
            tileSize: tileSize,
            tiling: tiling,
            supersampling: supersampling
        )
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
                sum: Int(brushSums.green[pixelIndex]),
                divisor: samplesPerPixel
            )
            brushBGRA[byteOffset + 2] = averagedByte(
                sum: Int(brushSums.red[pixelIndex]),
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
            if expectedByte > 0 && actualByte == 0 {
                holeCount += 1
            } else if expectedByte == 0 && actualByte > 0 {
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

private struct DirectCell: Hashable {
    let column: Int
    let row: Int
}

private struct DirectCandidate {
    let cell: DirectCell
    let imageOrdinal: UInt8
}

private struct DirectCoverageDomainKey: Hashable {
    let centerX: UInt32
    let centerY: UInt32
    let xAxisLength: UInt32
    let yAxisLength: UInt32
    let polygon: [UInt32]
}

private struct DirectCanonicalVertex: Equatable {
    let x: Float
    let y: Float

    init(_ point: SIMD2<Float>) {
        x = point.x == 0 ? 0 : point.x
        y = point.y == 0 ? 0 : point.y
    }
}

private struct DirectLocalPlane {
    let normal: SIMD2<Float>
    let offset: Float
}

private struct PreciseBrushInverse {
    let firstRow: SIMD2<Double>
    let secondRow: SIMD2<Double>
    let worldTranslation: SIMD2<Double>

    func applying(to world: SIMD2<Float>) -> SIMD2<Float> {
        let delta = SIMD2(
            Double(world.x) - worldTranslation.x,
            Double(world.y) - worldTranslation.y
        )
        let localX = firstRow.x * delta.x + firstRow.y * delta.y
        let localY = secondRow.x * delta.x + secondRow.y * delta.y
        let local = SIMD2(Float(localX), Float(localY))
        precondition(
            localX.isFinite && localY.isFinite
                && local.x.isFinite && local.y.isFinite,
            "TilingCoverageOracle inverse transform must be finite"
        )
        return local
    }
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

    let firstRow = normalizedVector(
        SIMD2(brushToWorld.xAxis.x, brushToWorld.yAxis.x)
    )
    let secondRow = normalizedVector(
        SIMD2(brushToWorld.xAxis.y, brushToWorld.yAxis.y)
    )
    let normalizedDeterminant = firstRow.x * secondRow.y
        - firstRow.y * secondRow.x
    precondition(
        normalizedDeterminant.isFinite
            && abs(normalizedDeterminant) >= Float.ulpOfOne,
        "TilingCoverageOracle brush-to-world transform must be nonsingular"
    )
    validateTransformedFootprint(
        footprint,
        brushToWorld: brushToWorld,
        tileSize: tileSize
    )
    _ = checkedPixelArea(
        tileSize,
        message: "TilingCoverageOracle pixel area must be Int-representable"
    )
}

private func normalizedVector(_ value: SIMD2<Float>) -> SIMD2<Float> {
    let scale = max(abs(value.x), abs(value.y))
    precondition(
        scale.isFinite && scale > 0,
        "TilingCoverageOracle brush-to-world transform must be nonsingular"
    )
    let scaled = value / scale
    let length = sqrt(simd_dot(scaled, scaled))
    precondition(
        length.isFinite && length > 0,
        "TilingCoverageOracle brush-to-world transform must be nonsingular"
    )
    return scaled / length
}

private func vectorMagnitude(_ value: SIMD2<Float>) -> Float {
    let scale = max(abs(value.x), abs(value.y))
    guard scale > 0 else {
        return 0
    }
    let scaled = value / scale
    return scale * sqrt(simd_dot(scaled, scaled))
}

private func validateTransformedFootprint(
    _ footprint: OracleFootprint,
    brushToWorld: Affine2D,
    tileSize: PixelSize
) {
    let supportedDiameter = min(
        Float(2_000),
        8 * Float(min(tileSize.width, tileSize.height))
    )
    switch footprint {
    case let .hardRound(radius):
        let firstRow = SIMD2(
            brushToWorld.xAxis.x,
            brushToWorld.yAxis.x
        )
        let secondRow = SIMD2(
            brushToWorld.xAxis.y,
            brushToWorld.yAxis.y
        )
        let width = 2 * radius * vectorMagnitude(firstRow)
        let height = 2 * radius * vectorMagnitude(secondRow)
        precondition(
            width.isFinite && height.isFinite
                && width <= supportedDiameter
                && height <= supportedDiameter,
            "TilingCoverageOracle transformed hard-round dimensions exceed supported diameter"
        )
    case .asymmetricTriangle:
        let vertices = [
            SIMD2<Float>(-0.75, -0.60),
            SIMD2<Float>(0.85, -0.20),
            SIMD2<Float>(-0.10, 0.90),
        ].map {
            brushToWorld.xAxis * $0.x
                + brushToWorld.yAxis * $0.y
        }
        let minimumX = vertices.map(\.x).min()!
        let maximumX = vertices.map(\.x).max()!
        let minimumY = vertices.map(\.y).min()!
        let maximumY = vertices.map(\.y).max()!
        let width = maximumX - minimumX
        let height = maximumY - minimumY
        precondition(
            width.isFinite && height.isFinite
                && width <= supportedDiameter
                && height <= supportedDiameter,
            "TilingCoverageOracle transformed triangle dimensions exceed supported diameter"
        )
    }
}

private func invertedBrushTransform(
    _ affine: Affine2D
) -> PreciseBrushInverse {
    let firstX = Double(affine.xAxis.x)
    let firstY = Double(affine.xAxis.y)
    let secondX = Double(affine.yAxis.x)
    let secondY = Double(affine.yAxis.y)
    let determinant = firstX * secondY - firstY * secondX
    precondition(
        determinant.isFinite && determinant != 0,
        "TilingCoverageOracle inverse transform must be finite"
    )
    let firstRow = SIMD2(
        secondY / determinant,
        -secondX / determinant
    )
    let secondRow = SIMD2(
        -firstY / determinant,
        firstX / determinant
    )
    let maximumFloat = Double(Float.greatestFiniteMagnitude)
    precondition(
        firstRow.x.isFinite && firstRow.y.isFinite
            && secondRow.x.isFinite && secondRow.y.isFinite
            && abs(firstRow.x) <= maximumFloat
            && abs(firstRow.y) <= maximumFloat
            && abs(secondRow.x) <= maximumFloat
            && abs(secondRow.y) <= maximumFloat,
        "TilingCoverageOracle inverse transform must be finite"
    )
    return PreciseBrushInverse(
        firstRow: firstRow,
        secondRow: secondRow,
        worldTranslation: SIMD2(
            Double(affine.translation.x),
            Double(affine.translation.y)
        )
    )
}

private func transformedFootprintBounds(
    _ footprint: OracleFootprint,
    by affine: Affine2D
) -> FloatBounds {
    switch footprint {
    case let .hardRound(radius):
        let firstRow = SIMD2(
            affine.xAxis.x,
            affine.yAxis.x
        )
        let secondRow = SIMD2(
            affine.xAxis.y,
            affine.yAxis.y
        )
        let halfExtents = SIMD2(
            radius * vectorMagnitude(firstRow),
            radius * vectorMagnitude(secondRow)
        )
        return FloatBounds(
            minimum: affine.translation - halfExtents,
            maximum: affine.translation + halfExtents
        )
    case .asymmetricTriangle:
        let vertices = [
            SIMD2<Float>(-0.75, -0.60),
            SIMD2<Float>(0.85, -0.20),
            SIMD2<Float>(-0.10, 0.90),
        ].map { affine.applying(to: $0) }
        return FloatBounds(
            minimum: SIMD2(
                vertices.map(\.x).min()!,
                vertices.map(\.y).min()!
            ),
            maximum: SIMD2(
                vertices.map(\.x).max()!,
                vertices.map(\.y).max()!
            )
        )
    }
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

private func validateSampleWork(
    _ bounds: IntegerPixelBounds,
    tileSize: PixelSize,
    supersampling: Int
) {
    let (width, widthOverflowed) = bounds.maximumX
        .subtractingReportingOverflow(bounds.minimumX)
    let (height, heightOverflowed) = bounds.maximumY
        .subtractingReportingOverflow(bounds.minimumY)
    precondition(
        !widthOverflowed && !heightOverflowed && width >= 0 && height >= 0,
        "TilingCoverageOracle padded world sample span must be Int-representable"
    )
    let (maximumWidth, maximumWidthOverflowed) = tileSize.width
        .multipliedReportingOverflow(by: 9)
    let (maximumHeight, maximumHeightOverflowed) = tileSize.height
        .multipliedReportingOverflow(by: 9)
    precondition(
        !maximumWidthOverflowed && !maximumHeightOverflowed
            && width <= maximumWidth && height <= maximumHeight,
        "TilingCoverageOracle padded world sample span exceeds supported reach"
    )
    let (pixelWork, pixelWorkOverflowed) = width
        .multipliedReportingOverflow(by: height)
    let (samplesPerPixel, samplesPerPixelOverflowed) = supersampling
        .multipliedReportingOverflow(by: supersampling)
    let (_, sampleWorkOverflowed) = pixelWork
        .multipliedReportingOverflow(by: samplesPerPixel)
    precondition(
        !pixelWorkOverflowed
            && !samplesPerPixelOverflowed
            && !sampleWorkOverflowed,
        "TilingCoverageOracle supersample work must be Int-representable"
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

private func directCell(
    containing world: SIMD2<Float>,
    tileSize: PixelSize,
    tiling: TilingKind
) -> DirectCell {
    let width = Float(tileSize.width)
    let height = Float(tileSize.height)
    switch tiling {
    case .halfDrop:
        let column = cellIndex(world.x, extent: width)
        let phaseY = column.isMultiple(of: 2) ? 0 : height * 0.5
        return DirectCell(
            column: column,
            row: cellIndex(world.y - phaseY, extent: height)
        )
    case .brick:
        let row = cellIndex(world.y, extent: height)
        let phaseX = row.isMultiple(of: 2) ? 0 : width * 0.5
        return DirectCell(
            column: cellIndex(world.x - phaseX, extent: width),
            row: row
        )
    case .grid, .mirrorX, .mirrorY, .mirrorXY, .rotational:
        return DirectCell(
            column: cellIndex(world.x, extent: width),
            row: cellIndex(world.y, extent: height)
        )
    }
}

private func brushCoordinateSums(
    sampleMasks: [UInt64],
    candidateCells: Set<DirectCell>,
    footprint: OracleFootprint,
    brushToWorld: Affine2D,
    worldToBrush: PreciseBrushInverse,
    tileSize: PixelSize,
    tiling: TilingKind,
    supersampling: Int
) -> (red: [UInt16], green: [UInt16]) {
    let candidates = directCandidates(
        cells: candidateCells,
        footprint: footprint,
        brushToWorld: brushToWorld,
        tileSize: tileSize,
        tiling: tiling
    )
    var redSums = [UInt16](repeating: 0, count: sampleMasks.count)
    var greenSums = [UInt16](repeating: 0, count: sampleMasks.count)

    for pixelIndex in sampleMasks.indices {
        var remaining = sampleMasks[pixelIndex]
        while remaining != 0 {
            let bitIndex = remaining.trailingZeroBitCount
            remaining &= remaining &- 1
            let canonical = canonicalSample(
                pixelIndex: pixelIndex,
                bitIndex: bitIndex,
                tileSize: tileSize,
                supersampling: supersampling
            )
            var owningBrushLocal: SIMD2<Float>?
            for candidate in candidates {
                let world = candidateWorldSample(
                    canonical,
                    candidate: candidate,
                    tileSize: tileSize,
                    tiling: tiling
                )
                let brushLocal = worldToBrush.applying(to: world)
                if contains(brushLocal, footprint: footprint) {
                    owningBrushLocal = brushLocal
                }
            }
            precondition(
                owningBrushLocal != nil,
                "TilingCoverageOracle covered sample must have a diagnostic owner"
            )
            let normalized = normalizedBrushCoordinate(
                owningBrushLocal!,
                footprint: footprint
            )
            redSums[pixelIndex] += UInt16(encodeSigned(normalized.x))
            greenSums[pixelIndex] += UInt16(encodeSigned(normalized.y))
        }
    }
    return (redSums, greenSums)
}

private func directCandidates(
    cells: Set<DirectCell>,
    footprint: OracleFootprint,
    brushToWorld: Affine2D,
    tileSize: PixelSize,
    tiling: TilingKind
) -> [DirectCandidate] {
    let sortedCells = cells.sorted {
        if $0.row != $1.row {
            return $0.row < $1.row
        }
        return $0.column < $1.column
    }
    var candidates: [DirectCandidate] = []
    for cell in sortedCells {
        candidates.append(
            DirectCandidate(cell: cell, imageOrdinal: 0)
        )
        if tiling == .rotational {
            candidates.append(
                DirectCandidate(cell: cell, imageOrdinal: 1)
            )
        }
    }
    guard tiling == .rotational, case .hardRound = footprint else {
        return candidates
    }
    var seenDomains: Set<DirectCoverageDomainKey> = []
    return candidates.filter { candidate in
        let key = directCoverageDomainKey(
            candidate,
            footprint: footprint,
            brushToWorld: brushToWorld,
            tileSize: tileSize,
            tiling: tiling
        )
        return seenDomains.insert(key).inserted
    }
}

private func directCoverageDomainKey(
    _ candidate: DirectCandidate,
    footprint: OracleFootprint,
    brushToWorld: Affine2D,
    tileSize: PixelSize,
    tiling: TilingKind
) -> DirectCoverageDomainKey {
    guard case let .hardRound(radius) = footprint else {
        preconditionFailure(
            "TilingCoverageOracle coverage-domain keys require a hard round"
        )
    }
    let origin = directCellOrigin(
        candidate.cell,
        tileSize: tileSize,
        tiling: tiling
    )
    let tile = SIMD2(
        Float(tileSize.width),
        Float(tileSize.height)
    )
    let scaledXAxis = brushToWorld.xAxis * radius
    let scaledYAxis = brushToWorld.yAxis * radius
    let localPolygon = directBrushLocalPlanes(
        origin: origin,
        tile: tile,
        xAxis: scaledXAxis,
        yAxis: scaledYAxis,
        translation: brushToWorld.translation
    ).reduce(
        [
            SIMD2<Float>(-1, -1),
            SIMD2<Float>(1, -1),
            SIMD2<Float>(1, 1),
            SIMD2<Float>(-1, 1),
        ]
    ) { polygon, plane in
        clipDirectLocalPolygon(polygon, to: plane)
    }
    let worldToCanonicalXAxis: SIMD2<Float>
    let worldToCanonicalYAxis: SIMD2<Float>
    let worldToCanonicalTranslation: SIMD2<Float>
    if candidate.imageOrdinal == 0 {
        worldToCanonicalXAxis = SIMD2(1, 0)
        worldToCanonicalYAxis = SIMD2(0, 1)
        worldToCanonicalTranslation = -origin
    } else {
        worldToCanonicalXAxis = SIMD2(-1, 0)
        worldToCanonicalYAxis = SIMD2(0, -1)
        worldToCanonicalTranslation = origin + tile
    }
    let canonicalXAxis = worldToCanonicalXAxis * scaledXAxis.x
        + worldToCanonicalYAxis * scaledXAxis.y
    let canonicalYAxis = worldToCanonicalXAxis * scaledYAxis.x
        + worldToCanonicalYAxis * scaledYAxis.y
    let canonicalCenter = worldToCanonicalXAxis
        * brushToWorld.translation.x
        + worldToCanonicalYAxis * brushToWorld.translation.y
        + worldToCanonicalTranslation
    let canonicalPolygon = localPolygon.map {
        canonicalXAxis * $0.x + canonicalYAxis * $0.y + canonicalCenter
    }
    return DirectCoverageDomainKey(
        centerX: normalizedZeroBitPattern(canonicalCenter.x),
        centerY: normalizedZeroBitPattern(canonicalCenter.y),
        xAxisLength: normalizedZeroBitPattern(
            directCoverageMagnitude(canonicalXAxis)
        ),
        yAxisLength: normalizedZeroBitPattern(
            directCoverageMagnitude(canonicalYAxis)
        ),
        polygon: directCanonicalPolygonKey(canonicalPolygon)
    )
}

private func directBrushLocalPlanes(
    origin: SIMD2<Float>,
    tile: SIMD2<Float>,
    xAxis: SIMD2<Float>,
    yAxis: SIMD2<Float>,
    translation: SIMD2<Float>
) -> [DirectLocalPlane] {
    [
        directBrushLocalPlane(
            worldNormal: SIMD2(1, 0),
            worldOffset: origin.x,
            xAxis: xAxis,
            yAxis: yAxis,
            translation: translation
        ),
        directBrushLocalPlane(
            worldNormal: SIMD2(-1, 0),
            worldOffset: -(origin.x + tile.x),
            xAxis: xAxis,
            yAxis: yAxis,
            translation: translation
        ),
        directBrushLocalPlane(
            worldNormal: SIMD2(0, 1),
            worldOffset: origin.y,
            xAxis: xAxis,
            yAxis: yAxis,
            translation: translation
        ),
        directBrushLocalPlane(
            worldNormal: SIMD2(0, -1),
            worldOffset: -(origin.y + tile.y),
            xAxis: xAxis,
            yAxis: yAxis,
            translation: translation
        ),
    ]
}

private func directBrushLocalPlane(
    worldNormal: SIMD2<Float>,
    worldOffset: Float,
    xAxis: SIMD2<Float>,
    yAxis: SIMD2<Float>,
    translation: SIMD2<Float>
) -> DirectLocalPlane {
    let unscaledNormal = SIMD2<Float>(
        simd_dot(worldNormal, xAxis),
        simd_dot(worldNormal, yAxis)
    )
    let unscaledOffset = worldOffset - simd_dot(worldNormal, translation)
    let length = directCoverageMagnitude(unscaledNormal)
    precondition(
        length.isFinite && length > 0 && unscaledOffset.isFinite,
        "TilingCoverageOracle mapped cell plane must be finite and nonzero"
    )
    return DirectLocalPlane(
        normal: unscaledNormal / length,
        offset: unscaledOffset / length
    )
}

private func directCoverageMagnitude(_ value: SIMD2<Float>) -> Float {
    let ordinary = simd_length(value)
    if ordinary == 0 && (value.x != 0 || value.y != 0) {
        return vectorMagnitude(value)
    }
    return ordinary
}

private func clipDirectLocalPolygon(
    _ polygon: [SIMD2<Float>],
    to plane: DirectLocalPlane
) -> [SIMD2<Float>] {
    let distances = polygon.map {
        let distance = simd_dot(plane.normal, $0) - plane.offset
        precondition(
            distance.isFinite,
            "TilingCoverageOracle clip endpoint distance must be finite"
        )
        return distance
    }
    guard let lastPoint = polygon.last, let lastDistance = distances.last else {
        return []
    }
    var result: [SIMD2<Float>] = []
    var start = lastPoint
    var startDistance = lastDistance
    var startInside = startDistance >= 0

    for (end, endDistance) in zip(polygon, distances) {
        let endInside = endDistance >= 0
        if endInside {
            if !startInside {
                result.append(
                    directClipIntersection(
                        start: start,
                        end: end,
                        startDistance: startDistance,
                        endDistance: endDistance
                    )
                )
            }
            result.append(end)
        } else if startInside {
            result.append(
                directClipIntersection(
                    start: start,
                    end: end,
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

private func directClipIntersection(
    start: SIMD2<Float>,
    end: SIMD2<Float>,
    startDistance: Float,
    endDistance: Float
) -> SIMD2<Float> {
    let denominator = startDistance - endDistance
    precondition(
        denominator.isFinite && denominator != 0,
        "TilingCoverageOracle clip distance denominator must be finite and nonzero"
    )
    let parameter = startDistance / denominator
    precondition(
        parameter.isFinite,
        "TilingCoverageOracle clip parameter must be finite"
    )
    return start + (end - start) * parameter
}

private func directCanonicalPolygonKey(
    _ polygon: [SIMD2<Float>]
) -> [UInt32] {
    var vertices = polygon.map(DirectCanonicalVertex.init)
    vertices = removingDirectConsecutiveDuplicates(vertices)
    guard !vertices.isEmpty else {
        return []
    }

    var best: [DirectCanonicalVertex]?
    for orientation in [vertices, Array(vertices.reversed())] {
        for startIndex in orientation.indices {
            let rotated = Array(
                orientation[startIndex...] + orientation[..<startIndex]
            )
            if best == nil || directVerticesPrecede(rotated, best!) {
                best = rotated
            }
        }
    }
    return best!.flatMap { [$0.x.bitPattern, $0.y.bitPattern] }
}

private func removingDirectConsecutiveDuplicates(
    _ vertices: [DirectCanonicalVertex]
) -> [DirectCanonicalVertex] {
    var result: [DirectCanonicalVertex] = []
    for vertex in vertices where result.last != vertex {
        result.append(vertex)
    }
    if result.count > 1 && result.first == result.last {
        result.removeLast()
    }
    return result
}

private func directVerticesPrecede(
    _ lhs: [DirectCanonicalVertex],
    _ rhs: [DirectCanonicalVertex]
) -> Bool {
    for (left, right) in zip(lhs, rhs) {
        if left.x != right.x {
            return directFloatPrecedes(left.x, right.x)
        }
        if left.y != right.y {
            return directFloatPrecedes(left.y, right.y)
        }
    }
    return lhs.count < rhs.count
}

private func directFloatPrecedes(_ lhs: Float, _ rhs: Float) -> Bool {
    if lhs != rhs {
        return lhs < rhs
    }
    return lhs.bitPattern < rhs.bitPattern
}

private func normalizedZeroBitPattern(_ value: Float) -> UInt32 {
    (value == 0 ? Float(0) : value).bitPattern
}

private func candidateWorldSample(
    _ canonical: SIMD2<Float>,
    candidate: DirectCandidate,
    tileSize: PixelSize,
    tiling: TilingKind
) -> SIMD2<Float> {
    let width = Float(tileSize.width)
    let height = Float(tileSize.height)
    let origin = directCellOrigin(
        candidate.cell,
        tileSize: tileSize,
        tiling: tiling
    )
    if tiling == .rotational && candidate.imageOrdinal == 1 {
        return origin + SIMD2(width, height) - canonical
    }

    let reflectsX = (tiling == .mirrorX || tiling == .mirrorXY)
        && !candidate.cell.column.isMultiple(of: 2)
    let reflectsY = (tiling == .mirrorY || tiling == .mirrorXY)
        && !candidate.cell.row.isMultiple(of: 2)
    return origin + SIMD2(
        reflectsX ? width - canonical.x : canonical.x,
        reflectsY ? height - canonical.y : canonical.y
    )
}

private func directCellOrigin(
    _ cell: DirectCell,
    tileSize: PixelSize,
    tiling: TilingKind
) -> SIMD2<Float> {
    let width = Float(tileSize.width)
    let height = Float(tileSize.height)
    switch tiling {
    case .halfDrop:
        return SIMD2(
            Float(cell.column) * width,
            Float(cell.row) * height
                + (cell.column.isMultiple(of: 2) ? 0 : height * 0.5)
        )
    case .brick:
        return SIMD2(
            Float(cell.column) * width
                + (cell.row.isMultiple(of: 2) ? 0 : width * 0.5),
            Float(cell.row) * height
        )
    case .grid, .mirrorX, .mirrorY, .mirrorXY, .rotational:
        return SIMD2(
            Float(cell.column) * width,
            Float(cell.row) * height
        )
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

private func canonicalSample(
    pixelIndex: Int,
    bitIndex: Int,
    tileSize: PixelSize,
    supersampling: Int
) -> SIMD2<Float> {
    SIMD2(
        Float(pixelIndex % tileSize.width)
            + sampleOffset(
                subpixel: bitIndex % supersampling,
                supersampling: supersampling
            ),
        Float(pixelIndex / tileSize.width)
            + sampleOffset(
                subpixel: bitIndex / supersampling,
                supersampling: supersampling
            )
    )
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
