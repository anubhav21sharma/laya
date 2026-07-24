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
        switch tiling {
        case .squareRotation, .squareKaleidoscope:
            return renderSquareCanonical(
                footprint: footprint,
                brushToWorld: brushToWorld,
                configuration: .defaultConfiguration(
                    presetID: tiling,
                    canonicalRasterSize: tileSize
                ),
                canonicalRasterSize: tileSize,
                supersampling: supersampling,
                coverageSymmetry: legacySquareCoverageSymmetry(
                    for: footprint
                )
            )
        case .hexagons, .rotation3, .rotation6, .kaleidoscope60,
             .kaleidoscope30:
            return renderTriangularCanonical(
                footprint: footprint,
                brushToWorld: brushToWorld,
                configuration: .defaultConfiguration(
                    presetID: tiling,
                    canonicalRasterSize: tileSize
                ),
                canonicalRasterSize: tileSize,
                supersampling: supersampling,
                coverageSymmetry: naturalCoverageSymmetry(for: footprint)
            )
        case .grid, .halfDrop, .brick, .mirrorX, .mirrorY, .mirrorXY,
             .rotational:
            break
        case .plainCanvas, .radialMirror, .radialRotation,
             .radialMandala:
            preconditionFailure(
                "Finite presets require the radial coverage oracle"
            )
        }
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

    public static func renderCanonical(
        footprint: OracleFootprint,
        brushToWorld: Affine2D,
        configuration: PeriodicSymmetryConfiguration,
        canonicalRasterSize: PixelSize,
        supersampling: Int,
        coverageSymmetry: FootprintCoverageSymmetry? = nil
    ) -> OracleRasterResult {
        switch configuration.presetID {
        case .squareRotation, .squareKaleidoscope:
            return renderSquareCanonical(
                footprint: footprint,
                brushToWorld: brushToWorld,
                configuration: configuration,
                canonicalRasterSize: canonicalRasterSize,
                supersampling: supersampling,
                coverageSymmetry: coverageSymmetry
                    ?? naturalCoverageSymmetry(for: footprint)
            )
        case .hexagons, .rotation3, .rotation6, .kaleidoscope60,
             .kaleidoscope30:
            return renderTriangularCanonical(
                footprint: footprint,
                brushToWorld: brushToWorld,
                configuration: configuration,
                canonicalRasterSize: canonicalRasterSize,
                supersampling: supersampling,
                coverageSymmetry: coverageSymmetry
                    ?? naturalCoverageSymmetry(for: footprint)
            )
        case .grid, .halfDrop, .brick, .mirrorX, .mirrorY, .mirrorXY,
             .rotational:
            let rasterRepeat = PatternSize(
                width: Float(canonicalRasterSize.width),
                height: Float(canonicalRasterSize.height)
            )
            precondition(
                configuration.repeatSize == rasterRepeat,
                "TilingCoverageOracle legacy configuration repeat must match the canonical raster"
            )
            precondition(
                normalizedPeriodicAngle(configuration.orientationRadians) == 0,
                "TilingCoverageOracle legacy configuration orientation must be zero"
            )
            return renderCanonical(
                footprint: footprint,
                brushToWorld: brushToWorld,
                tileSize: canonicalRasterSize,
                tiling: configuration.presetID,
                supersampling: supersampling
            )
        case .plainCanvas, .radialMirror, .radialRotation,
             .radialMandala:
            preconditionFailure(
                "Finite presets cannot form a periodic oracle configuration"
            )
        }
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

private extension TilingCoverageOracle {
    static func renderTriangularCanonical(
        footprint: OracleFootprint,
        brushToWorld: Affine2D,
        configuration: PeriodicSymmetryConfiguration,
        canonicalRasterSize: PixelSize,
        supersampling: Int,
        coverageSymmetry: FootprintCoverageSymmetry
    ) -> OracleRasterResult {
        validateRenderInputs(
            footprint: footprint,
            brushToWorld: brushToWorld,
            tileSize: canonicalRasterSize,
            supersampling: supersampling
        )
        let geometry = directTriangularGeometry(
            configuration: configuration,
            canonicalRasterSize: canonicalRasterSize
        )
        let worldBounds = transformedFootprintBounds(
            footprint,
            by: brushToWorld
        )
        validateSampleWork(
            integerPixelBounds(worldBounds),
            tileSize: canonicalRasterSize,
            supersampling: supersampling
        )
        let candidates = directTriangularCandidates(
            worldBounds: worldBounds,
            footprint: footprint,
            brushToWorld: brushToWorld,
            geometry: geometry
        )
        _ = coverageSymmetry
        // Coverage is a set union. Complete-stamp-equivalent images may
        // remain in this independent list because each sample is recorded
        // once, so fixed points cannot multiply opacity or eraser strength.
        let area = checkedPixelArea(
            canonicalRasterSize,
            message: "TilingCoverageOracle pixel area must be Int-representable"
        )
        let samplesPerPixel = supersampling * supersampling
        var coverageBytes = [UInt8](repeating: 0, count: area)
        var canonicalBGRA = [UInt8](repeating: 0, count: area * 4)
        var brushBGRA = [UInt8](repeating: 0, count: area * 4)

        for pixelY in 0..<canonicalRasterSize.height {
            for pixelX in 0..<canonicalRasterSize.width {
                var coveredSamples = 0
                var canonicalRedSum = 0
                var canonicalGreenSum = 0
                var brushRedSum = 0
                var brushGreenSum = 0

                for subY in 0..<supersampling {
                    for subX in 0..<supersampling {
                        let canonical = SIMD2<Float>(
                            Float(pixelX) + sampleOffset(
                                subpixel: subX,
                                supersampling: supersampling
                            ),
                            Float(pixelY) + sampleOffset(
                                subpixel: subY,
                                supersampling: supersampling
                            )
                        )
                        var owningBrushLocal: SIMD2<Float>?
                        for candidate in candidates {
                            let brushLocal = candidate.brushFromCanonical
                                .applying(to: canonical)
                            if directTriangularContains(
                                brushLocal,
                                footprint: footprint
                            ) {
                                owningBrushLocal = brushLocal
                            }
                        }
                        guard let brushLocal = owningBrushLocal else {
                            continue
                        }

                        coveredSamples += 1
                        canonicalRedSum += Int(
                            encodeUnit(
                                canonical.x
                                    / Float(canonicalRasterSize.width)
                            )
                        )
                        canonicalGreenSum += Int(
                            encodeUnit(
                                canonical.y
                                    / Float(canonicalRasterSize.height)
                            )
                        )
                        brushRedSum += Int(encodeSigned(brushLocal.x))
                        brushGreenSum += Int(encodeSigned(brushLocal.y))
                    }
                }

                let pixelIndex = pixelY * canonicalRasterSize.width + pixelX
                let byteOffset = pixelIndex * 4
                let alpha = averagedByte(
                    sum: coveredSamples * 255,
                    divisor: samplesPerPixel
                )
                coverageBytes[pixelIndex] = alpha
                canonicalBGRA[byteOffset + 1] = averagedByte(
                    sum: canonicalGreenSum,
                    divisor: samplesPerPixel
                )
                canonicalBGRA[byteOffset + 2] = averagedByte(
                    sum: canonicalRedSum,
                    divisor: samplesPerPixel
                )
                canonicalBGRA[byteOffset + 3] = alpha
                brushBGRA[byteOffset + 1] = averagedByte(
                    sum: brushGreenSum,
                    divisor: samplesPerPixel
                )
                brushBGRA[byteOffset + 2] = averagedByte(
                    sum: brushRedSum,
                    divisor: samplesPerPixel
                )
                brushBGRA[byteOffset + 3] = alpha
            }
        }

        return OracleRasterResult(
            coverage: OracleCoverage(
                pixelSize: canonicalRasterSize,
                bytes: coverageBytes
            ),
            canonicalCoordinatesBGRA: canonicalBGRA,
            brushLocalCoordinatesBGRA: brushBGRA
        )
    }

    static func renderSquareCanonical(
        footprint: OracleFootprint,
        brushToWorld: Affine2D,
        configuration: PeriodicSymmetryConfiguration,
        canonicalRasterSize: PixelSize,
        supersampling: Int,
        coverageSymmetry: FootprintCoverageSymmetry
    ) -> OracleRasterResult {
        validateRenderInputs(
            footprint: footprint,
            brushToWorld: brushToWorld,
            tileSize: canonicalRasterSize,
            supersampling: supersampling
        )
        let geometry = directSquareGeometry(
            configuration: configuration,
            canonicalRasterSize: canonicalRasterSize
        )
        let worldBounds = transformedFootprintBounds(
            footprint,
            by: brushToWorld
        )
        validateSampleWork(
            integerPixelBounds(worldBounds),
            tileSize: canonicalRasterSize,
            supersampling: supersampling
        )
        let candidates = directSquareCandidates(
            worldBounds: worldBounds,
            footprint: footprint,
            brushToWorld: brushToWorld,
            geometry: geometry,
            coverageSymmetry: coverageSymmetry
        )
        let area = checkedPixelArea(
            canonicalRasterSize,
            message: "TilingCoverageOracle pixel area must be Int-representable"
        )
        let samplesPerPixel = supersampling * supersampling
        var coverageBytes = [UInt8](repeating: 0, count: area)
        var canonicalBGRA = [UInt8](repeating: 0, count: area * 4)
        var brushBGRA = [UInt8](repeating: 0, count: area * 4)

        for pixelY in 0..<canonicalRasterSize.height {
            for pixelX in 0..<canonicalRasterSize.width {
                var coveredSamples = 0
                var canonicalRedSum = 0
                var canonicalGreenSum = 0
                var brushRedSum = 0
                var brushGreenSum = 0

                for subY in 0..<supersampling {
                    for subX in 0..<supersampling {
                        let canonical = SIMD2<Float>(
                            Float(pixelX) + sampleOffset(
                                subpixel: subX,
                                supersampling: supersampling
                            ),
                            Float(pixelY) + sampleOffset(
                                subpixel: subY,
                                supersampling: supersampling
                            )
                        )
                        var owningBrushLocal: SIMD2<Float>?
                        for candidate in candidates {
                            let brushLocal = candidate.brushFromCanonical.applying(
                                to: canonical
                            )
                            if directSquareContains(
                                brushLocal,
                                footprint: footprint
                            ) {
                                owningBrushLocal = brushLocal
                            }
                        }
                        guard let brushLocal = owningBrushLocal else {
                            continue
                        }

                        coveredSamples += 1
                        canonicalRedSum += Int(
                            encodeUnit(
                                canonical.x
                                    / Float(canonicalRasterSize.width)
                            )
                        )
                        canonicalGreenSum += Int(
                            encodeUnit(
                                canonical.y
                                    / Float(canonicalRasterSize.height)
                            )
                        )
                        brushRedSum += Int(encodeSigned(brushLocal.x))
                        brushGreenSum += Int(encodeSigned(brushLocal.y))
                    }
                }

                let pixelIndex = pixelY * canonicalRasterSize.width + pixelX
                let byteOffset = pixelIndex * 4
                let alpha = averagedByte(
                    sum: coveredSamples * 255,
                    divisor: samplesPerPixel
                )
                coverageBytes[pixelIndex] = alpha
                canonicalBGRA[byteOffset + 1] = averagedByte(
                    sum: canonicalGreenSum,
                    divisor: samplesPerPixel
                )
                canonicalBGRA[byteOffset + 2] = averagedByte(
                    sum: canonicalRedSum,
                    divisor: samplesPerPixel
                )
                canonicalBGRA[byteOffset + 3] = alpha
                brushBGRA[byteOffset + 1] = averagedByte(
                    sum: brushGreenSum,
                    divisor: samplesPerPixel
                )
                brushBGRA[byteOffset + 2] = averagedByte(
                    sum: brushRedSum,
                    divisor: samplesPerPixel
                )
                brushBGRA[byteOffset + 3] = alpha
            }
        }

        return OracleRasterResult(
            coverage: OracleCoverage(
                pixelSize: canonicalRasterSize,
                bytes: coverageBytes
            ),
            canonicalCoordinatesBGRA: canonicalBGRA,
            brushLocalCoordinatesBGRA: brushBGRA
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

private struct DirectSquareGeometry {
    let presetID: SymmetryPresetID
    let side: Float
    let cosine: Float
    let sine: Float
    let u: SIMD2<Float>
    let v: SIMD2<Float>
    let canonicalRasterSize: PixelSize
}

private struct DirectSquareOperation: Equatable {
    let quarterTurns: UInt8
    let reflected: Bool
}

private struct DirectSquareCandidate {
    let cell: DirectCell
    let imageOrdinal: UInt8
    let operation: DirectSquareOperation
    let brushFromCanonical: Affine2D
    let coverageKey: DirectCoverageDomainKey
}

private struct DirectTriangularGeometry {
    let presetID: SymmetryPresetID
    let worldToRaster: Affine2D
    let canonicalRasterSize: PixelSize
}

private struct DirectTriangularOperation: Equatable {
    let sixthTurn: UInt8
    let reflected: Bool
    let reflectionAtThirtyDegrees: Bool
}

private struct DirectTriangularCandidate {
    let cell: DirectCell
    let imageOrdinal: UInt8
    let brushFromCanonical: Affine2D
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
    case .grid, .mirrorX, .mirrorY, .mirrorXY, .rotational,
         .squareRotation, .squareKaleidoscope, .hexagons, .rotation3,
         .rotation6, .kaleidoscope60, .kaleidoscope30, .plainCanvas,
         .radialMirror, .radialRotation, .radialMandala:
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

private func naturalCoverageSymmetry(
    for footprint: OracleFootprint
) -> FootprintCoverageSymmetry {
    switch footprint {
    case .hardRound:
        return .rotationAndReflectionInvariant
    case .asymmetricTriangle:
        return .oriented
    }
}

private func legacySquareCoverageSymmetry(
    for footprint: OracleFootprint
) -> FootprintCoverageSymmetry {
    switch footprint {
    case .hardRound:
        return .halfTurnInvariant
    case .asymmetricTriangle:
        return .oriented
    }
}

private func normalizedPeriodicAngle(_ value: Float) -> Float {
    precondition(
        value.isFinite,
        "TilingCoverageOracle orientation must be finite"
    )
    let fullTurn = 2 * Float.pi
    var result = value.truncatingRemainder(dividingBy: fullTurn)
    if result >= Float.pi {
        result -= fullTurn
    } else if result < -Float.pi {
        result += fullTurn
    }
    return result == 0 ? 0 : result
}

private func directTriangularGeometry(
    configuration: PeriodicSymmetryConfiguration,
    canonicalRasterSize: PixelSize
) -> DirectTriangularGeometry {
    switch configuration.presetID {
    case .hexagons, .rotation3, .rotation6, .kaleidoscope60,
         .kaleidoscope30:
        break
    case .grid, .halfDrop, .brick, .mirrorX, .mirrorY, .mirrorXY,
         .rotational, .squareRotation, .squareKaleidoscope, .plainCanvas,
         .radialMirror, .radialRotation, .radialMandala:
        preconditionFailure(
            "TilingCoverageOracle triangular geometry requires a triangular preset"
        )
    }
    let width = configuration.repeatSize.width
    let height = configuration.repeatSize.height
    precondition(
        width.isFinite && height.isFinite,
        "TilingCoverageOracle triangular repeat must be finite"
    )
    precondition(
        width == height,
        "TilingCoverageOracle triangular spacing values must be equal"
    )
    precondition(
        width > 0,
        "TilingCoverageOracle triangular spacing must be positive"
    )
    let angle = normalizedPeriodicAngle(configuration.orientationRadians)
    let cosine = cos(angle)
    let sine = sin(angle)
    let rasterWidth = Float(canonicalRasterSize.width)
    let rasterHeight = Float(canonicalRasterSize.height)
    let verticalSpacing = sqrt(Float(3)) * width
    let rectangularSupercellToWorld = Affine2D(
        xAxis: SIMD2(width * cosine, width * sine),
        yAxis: SIMD2(
            -verticalSpacing * sine,
            verticalSpacing * cosine
        ),
        translation: .zero
    )
    let latticeToRaster = Affine2D(
        xAxis: SIMD2(rasterWidth, 0),
        yAxis: SIMD2(0, rasterHeight),
        translation: .zero
    )
    let worldToRaster = rectangularSupercellToWorld.inverted()
        .concatenating(latticeToRaster)
    return DirectTriangularGeometry(
        presetID: configuration.presetID,
        worldToRaster: worldToRaster,
        canonicalRasterSize: canonicalRasterSize
    )
}

private func directTriangularCandidates(
    worldBounds: FloatBounds,
    footprint: OracleFootprint,
    brushToWorld: Affine2D,
    geometry: DirectTriangularGeometry
) -> [DirectTriangularCandidate] {
    let operations = directTriangularOperations(for: geometry.presetID)
    let rasterWidth = Float(geometry.canonicalRasterSize.width)
    let rasterHeight = Float(geometry.canonicalRasterSize.height)
    let cosets = [
        SIMD2<Float>.zero,
        SIMD2(rasterWidth * 0.5, rasterHeight * 0.5),
    ]
    let corners = [
        worldBounds.minimum,
        SIMD2(worldBounds.maximum.x, worldBounds.minimum.y),
        worldBounds.maximum,
        SIMD2(worldBounds.minimum.x, worldBounds.maximum.y),
    ]
    let effectiveBrush = directSquareEffectiveBrush(
        footprint: footprint,
        brushToWorld: brushToWorld
    )
    var candidates: [DirectTriangularCandidate] = []

    for (cosetIndex, coset) in cosets.enumerated() {
        for (operationIndex, operation) in operations.enumerated() {
            let imageOrdinal = UInt8(
                cosetIndex * operations.count + operationIndex
            )
            let rasterOperation = directTriangularRasterOperation(
                operation,
                canonicalRasterSize: geometry.canonicalRasterSize,
                translation: coset
            )
            let worldToTransformedRaster = geometry.worldToRaster
                .concatenating(rasterOperation)
            let transformed = corners.map(
                worldToTransformedRaster.applying
            )
            let minimumX = transformed.map(\.x).min()!
            let maximumX = transformed.map(\.x).max()!
            let minimumY = transformed.map(\.y).min()!
            let maximumY = transformed.map(\.y).max()!
            guard
                let columns = directTriangularIntersectingCells(
                    minimum: minimumX,
                    maximum: maximumX,
                    extent: rasterWidth
                ),
                let rows = directTriangularIntersectingCells(
                    minimum: minimumY,
                    maximum: maximumY,
                    extent: rasterHeight
                )
            else {
                continue
            }

            for row in rows {
                for column in columns {
                    let targetOrigin = SIMD2(
                        Float(column) * rasterWidth,
                        Float(row) * rasterHeight
                    )
                    let subtractTarget = Affine2D(
                        xAxis: SIMD2(1, 0),
                        yAxis: SIMD2(0, 1),
                        translation: -targetOrigin
                    )
                    let canonicalFromBrush = effectiveBrush
                        .concatenating(worldToTransformedRaster)
                        .concatenating(subtractTarget)
                    candidates.append(
                        DirectTriangularCandidate(
                            cell: DirectCell(
                                column: column,
                                row: row
                            ),
                            imageOrdinal: imageOrdinal,
                            brushFromCanonical: canonicalFromBrush.inverted()
                        )
                    )
                }
            }
        }
    }

    candidates.sort {
        if $0.cell.row != $1.cell.row {
            return $0.cell.row < $1.cell.row
        }
        if $0.cell.column != $1.cell.column {
            return $0.cell.column < $1.cell.column
        }
        return $0.imageOrdinal < $1.imageOrdinal
    }
    return candidates
}

private func directTriangularContains(
    _ point: SIMD2<Float>,
    footprint: OracleFootprint
) -> Bool {
    switch footprint {
    case .hardRound:
        return simd_dot(point, point) <= 1
    case .asymmetricTriangle:
        return contains(point, footprint: .asymmetricTriangle)
    }
}

private func directTriangularOperations(
    for presetID: SymmetryPresetID
) -> [DirectTriangularOperation] {
    let order: UInt8
    let includesReflections: Bool
    switch presetID {
    case .hexagons:
        order = 1
        includesReflections = false
    case .rotation3:
        order = 3
        includesReflections = false
    case .rotation6:
        order = 6
        includesReflections = false
    case .kaleidoscope60:
        order = 3
        includesReflections = true
    case .kaleidoscope30:
        order = 6
        includesReflections = true
    case .grid, .halfDrop, .brick, .mirrorX, .mirrorY, .mirrorXY,
         .rotational, .squareRotation, .squareKaleidoscope, .plainCanvas,
         .radialMirror, .radialRotation, .radialMandala:
        preconditionFailure(
            "TilingCoverageOracle triangular operations require a triangular preset"
        )
    }
    let turnMultiplier: UInt8 = order == 3 ? 2 : order == 1 ? 0 : 1
    var result = (0..<order).map {
        DirectTriangularOperation(
            sixthTurn: $0 * turnMultiplier,
            reflected: false,
            reflectionAtThirtyDegrees: false
        )
    }
    if includesReflections {
        result.append(contentsOf: (0..<order).map {
            DirectTriangularOperation(
                sixthTurn: $0 * turnMultiplier,
                reflected: true,
                reflectionAtThirtyDegrees: presetID == .kaleidoscope60
            )
        })
    }
    return result
}

private func directTriangularRasterOperation(
    _ operation: DirectTriangularOperation,
    canonicalRasterSize: PixelSize,
    translation: SIMD2<Float>
) -> Affine2D {
    let rotation = directTriangularNormalizedRotation(operation.sixthTurn)
    let normalized: Affine2D
    if operation.reflected {
        let reflection = operation.reflectionAtThirtyDegrees
            ? Affine2D(
                xAxis: SIMD2(0.5, 0.5),
                yAxis: SIMD2(1.5, -0.5),
                translation: .zero
            )
            : Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, -1),
                translation: .zero
            )
        normalized = reflection.concatenating(rotation)
    } else {
        normalized = rotation
    }
    let width = Float(canonicalRasterSize.width)
    let height = Float(canonicalRasterSize.height)
    return Affine2D(
        xAxis: SIMD2(
            normalized.xAxis.x,
            normalized.xAxis.y * height / width
        ),
        yAxis: SIMD2(
            normalized.yAxis.x * width / height,
            normalized.yAxis.y
        ),
        translation: translation
    )
}

private func directTriangularNormalizedRotation(
    _ sixthTurn: UInt8
) -> Affine2D {
    switch sixthTurn % 6 {
    case 0:
        return .identity
    case 1:
        return Affine2D(
            xAxis: SIMD2(0.5, 0.5),
            yAxis: SIMD2(-1.5, 0.5),
            translation: .zero
        )
    case 2:
        return Affine2D(
            xAxis: SIMD2(-0.5, 0.5),
            yAxis: SIMD2(-1.5, -0.5),
            translation: .zero
        )
    case 3:
        return Affine2D(
            xAxis: SIMD2(-1, 0),
            yAxis: SIMD2(0, -1),
            translation: .zero
        )
    case 4:
        return Affine2D(
            xAxis: SIMD2(-0.5, -0.5),
            yAxis: SIMD2(1.5, -0.5),
            translation: .zero
        )
    case 5:
        return Affine2D(
            xAxis: SIMD2(0.5, -0.5),
            yAxis: SIMD2(1.5, 0.5),
            translation: .zero
        )
    default:
        preconditionFailure(
            "TilingCoverageOracle sixth-turn modulo must be in 0...5"
        )
    }
}

private func directTriangularIntersectingCells(
    minimum: Float,
    maximum: Float,
    extent: Float
) -> ClosedRange<Int>? {
    precondition(
        minimum.isFinite && maximum.isFinite
            && extent.isFinite && extent > 0,
        "TilingCoverageOracle triangular cell bounds must be finite"
    )
    guard maximum > minimum else { return nil }
    let lower = floor(Double(minimum / extent))
    let upper = floor(Double(maximum.nextDown / extent))
    precondition(
        lower >= Double(Int.min) && lower <= Double(Int.max)
            && upper >= Double(Int.min) && upper <= Double(Int.max),
        "TilingCoverageOracle triangular cell range must be Int-representable"
    )
    let first = Int(lower)
    let last = Int(upper)
    return last >= first ? first...last : nil
}

private func directSquareGeometry(
    configuration: PeriodicSymmetryConfiguration,
    canonicalRasterSize: PixelSize
) -> DirectSquareGeometry {
    precondition(
        configuration.presetID == .squareRotation
            || configuration.presetID == .squareKaleidoscope,
        "TilingCoverageOracle square geometry requires a square preset"
    )
    let width = configuration.repeatSize.width
    let height = configuration.repeatSize.height
    precondition(
        width.isFinite && height.isFinite,
        "TilingCoverageOracle square repeat must be finite"
    )
    precondition(
        width == height,
        "TilingCoverageOracle square repeat extents must be equal"
    )
    precondition(
        width > 0,
        "TilingCoverageOracle square repeat side must be positive"
    )
    let angle = normalizedPeriodicAngle(configuration.orientationRadians)
    let cosine = cos(angle)
    let sine = sin(angle)
    let u = SIMD2(width * cosine, width * sine)
    let v = SIMD2(-width * sine, width * cosine)
    let determinant = u.x * v.y - u.y * v.x
    precondition(
        determinant.isFinite && abs(determinant) >= Float.ulpOfOne,
        "TilingCoverageOracle square basis must be nonsingular"
    )
    return DirectSquareGeometry(
        presetID: configuration.presetID,
        side: width,
        cosine: cosine,
        sine: sine,
        u: u,
        v: v,
        canonicalRasterSize: canonicalRasterSize
    )
}

private func directSquareCandidates(
    worldBounds: FloatBounds,
    footprint: OracleFootprint,
    brushToWorld: Affine2D,
    geometry: DirectSquareGeometry,
    coverageSymmetry: FootprintCoverageSymmetry
) -> [DirectSquareCandidate] {
    let latticeCorners = [
        worldBounds.minimum,
        SIMD2(worldBounds.maximum.x, worldBounds.minimum.y),
        worldBounds.maximum,
        SIMD2(worldBounds.minimum.x, worldBounds.maximum.y),
    ].map { directSquareLatticeCoordinate($0, geometry: geometry) }
    let columns = directSquareCandidateRange(
        minimum: latticeCorners.map(\.x).min()!,
        maximum: latticeCorners.map(\.x).max()!
    )
    let rows = directSquareCandidateRange(
        minimum: latticeCorners.map(\.y).min()!,
        maximum: latticeCorners.map(\.y).max()!
    )
    let effectiveBrush = directSquareEffectiveBrush(
        footprint: footprint,
        brushToWorld: brushToWorld
    )
    let localBounds = directSquareLocalBounds(for: footprint)
    let ordinals: Range<UInt8> = geometry.presetID == .squareRotation
        ? 0..<4
        : 0..<8
    var candidates: [DirectSquareCandidate] = []

    for row in rows {
        for column in columns {
            let cell = DirectCell(column: column, row: row)
            let origin = directSquareCellOrigin(cell, geometry: geometry)
            let planes = directSquareCellPlanes(
                origin: origin,
                geometry: geometry,
                brushToWorld: effectiveBrush
            )
            let polygon = planes.reduce(localBounds) {
                clipDirectLocalPolygon($0, to: $1)
            }
            guard polygon.count >= 3 else { continue }
            let worldPolygon = polygon.map(effectiveBrush.applying)
            guard abs(directSquareSignedArea(worldPolygon)) > 0.0001 else {
                continue
            }

            for ordinal in ordinals {
                let operation = DirectSquareOperation(
                    quarterTurns: ordinal % 4,
                    reflected: ordinal >= 4
                )
                let canonicalFromBrush = directSquareCanonicalFromBrush(
                    cell: cell,
                    imageOrdinal: ordinal,
                    brushToWorld: effectiveBrush,
                    geometry: geometry
                )
                let center = directSquareCanonicalizedCenter(
                    canonicalFromBrush.translation,
                    rasterSize: geometry.canonicalRasterSize
                )
                let axisLengths = [
                    directCoverageMagnitude(canonicalFromBrush.xAxis),
                    directCoverageMagnitude(canonicalFromBrush.yAxis),
                ].sorted()
                let key = DirectCoverageDomainKey(
                    centerX: normalizedZeroBitPattern(
                        center.x
                    ),
                    centerY: normalizedZeroBitPattern(
                        center.y
                    ),
                    xAxisLength: normalizedZeroBitPattern(
                        axisLengths[0]
                    ),
                    yAxisLength: normalizedZeroBitPattern(
                        axisLengths[1]
                    ),
                    polygon: directCanonicalPolygonKey(polygon)
                )
                candidates.append(
                    DirectSquareCandidate(
                        cell: cell,
                        imageOrdinal: ordinal,
                        operation: operation,
                        brushFromCanonical: canonicalFromBrush.inverted(),
                        coverageKey: key
                    )
                )
            }
        }
    }

    guard coverageSymmetry != .oriented else {
        return candidates
    }
    var seen: [DirectCoverageDomainKey: [DirectSquareOperation]] = [:]
    return candidates.filter { candidate in
        if seen[candidate.coverageKey, default: []].contains(where: {
            directSquareOperationsAreEquivalent(
                $0,
                candidate.operation,
                presetID: geometry.presetID,
                coverageSymmetry: coverageSymmetry
            )
        }) {
            return false
        }
        seen[candidate.coverageKey, default: []].append(candidate.operation)
        return true
    }
}

private func directSquareCanonicalizedCenter(
    _ point: SIMD2<Float>,
    rasterSize: PixelSize
) -> SIMD2<Float> {
    let width = Float(rasterSize.width)
    let height = Float(rasterSize.height)
    let fixedPoints = [
        SIMD2<Float>(0, 0),
        SIMD2(width * 0.5, height * 0.5),
        SIMD2(width * 0.5, 0),
        SIMD2(0, height * 0.5),
    ]
    return fixedPoints.first(where: {
        directCoordinatesAreWithinULPs(point.x, $0.x, maximum: 2)
            && directCoordinatesAreWithinULPs(
                point.y,
                $0.y,
                maximum: 2
            )
    }) ?? point
}

private func directCoordinatesAreWithinULPs(
    _ lhs: Float,
    _ rhs: Float,
    maximum: UInt32
) -> Bool {
    guard lhs.isFinite, rhs.isFinite else { return false }
    let lhsBits = directOrderedFloatBits(lhs == 0 ? 0 : lhs)
    let rhsBits = directOrderedFloatBits(rhs == 0 ? 0 : rhs)
    return max(lhsBits, rhsBits) - min(lhsBits, rhsBits) <= maximum
}

private func directOrderedFloatBits(_ value: Float) -> UInt32 {
    let bits = value.bitPattern
    return bits & 0x8000_0000 == 0
        ? bits | 0x8000_0000
        : ~bits
}

private func directSquareCandidateRange(
    minimum: Float,
    maximum: Float
) -> ClosedRange<Int> {
    let lower = floor(minimum)
    let upper = floor(maximum)
    precondition(
        lower.isFinite && upper.isFinite
            && lower >= Float(Int.min) && upper < Float(Int.max),
        "TilingCoverageOracle square cell range must be Int-representable"
    )
    return Int(lower)...Int(upper)
}

private func directSquareLatticeCoordinate(
    _ world: SIMD2<Float>,
    geometry: DirectSquareGeometry
) -> SIMD2<Float> {
    SIMD2(
        (geometry.cosine * world.x + geometry.sine * world.y)
            / geometry.side,
        (-geometry.sine * world.x + geometry.cosine * world.y)
            / geometry.side
    )
}

private func directSquareCellOrigin(
    _ cell: DirectCell,
    geometry: DirectSquareGeometry
) -> SIMD2<Float> {
    geometry.u * Float(cell.column) + geometry.v * Float(cell.row)
}

private func directSquareEffectiveBrush(
    footprint: OracleFootprint,
    brushToWorld: Affine2D
) -> Affine2D {
    switch footprint {
    case let .hardRound(radius):
        return Affine2D(
            xAxis: brushToWorld.xAxis * radius,
            yAxis: brushToWorld.yAxis * radius,
            translation: brushToWorld.translation
        )
    case .asymmetricTriangle:
        return brushToWorld
    }
}

private func directSquareLocalBounds(
    for footprint: OracleFootprint
) -> [SIMD2<Float>] {
    switch footprint {
    case .hardRound:
        return [
            SIMD2(-1, -1),
            SIMD2(1, -1),
            SIMD2(1, 1),
            SIMD2(-1, 1),
        ]
    case .asymmetricTriangle:
        return [
            SIMD2(-0.75, -0.60),
            SIMD2(0.85, -0.60),
            SIMD2(0.85, 0.90),
            SIMD2(-0.75, 0.90),
        ]
    }
}

private func directSquareCellPlanes(
    origin: SIMD2<Float>,
    geometry: DirectSquareGeometry,
    brushToWorld: Affine2D
) -> [DirectLocalPlane] {
    let vertices = [
        origin,
        origin + geometry.u,
        origin + geometry.u + geometry.v,
        origin + geometry.v,
    ]
    return vertices.indices.map { index in
        let start = vertices[index]
        let end = vertices[(index + 1) % vertices.count]
        let edge = end - start
        let inward = SIMD2(-edge.y, edge.x) / directCoverageMagnitude(edge)
        return directBrushLocalPlane(
            worldNormal: inward,
            worldOffset: simd_dot(inward, start),
            xAxis: brushToWorld.xAxis,
            yAxis: brushToWorld.yAxis,
            translation: brushToWorld.translation
        )
    }
}

private func directSquareCanonicalFromBrush(
    cell: DirectCell,
    imageOrdinal: UInt8,
    brushToWorld: Affine2D,
    geometry: DirectSquareGeometry
) -> Affine2D {
    let worldToLattice = Affine2D(
        xAxis: SIMD2(
            geometry.cosine / geometry.side,
            -geometry.sine / geometry.side
        ),
        yAxis: SIMD2(
            geometry.sine / geometry.side,
            geometry.cosine / geometry.side
        ),
        translation: .zero
    )
    let subtractCell = Affine2D(
        xAxis: SIMD2(1, 0),
        yAxis: SIMD2(0, 1),
        translation: SIMD2(
            -Float(cell.column),
            -Float(cell.row)
        )
    )
    let scaleToRaster = Affine2D(
        xAxis: SIMD2(Float(geometry.canonicalRasterSize.width), 0),
        yAxis: SIMD2(0, Float(geometry.canonicalRasterSize.height)),
        translation: .zero
    )
    return brushToWorld
        .concatenating(worldToLattice)
        .concatenating(subtractCell)
        .concatenating(scaleToRaster)
        .concatenating(
            directSquareRasterImage(
                ordinal: imageOrdinal,
                canonicalRasterSize: geometry.canonicalRasterSize
            )
        )
}

private func directSquareForwardImage(
    _ local: SIMD2<Float>,
    ordinal: UInt8
) -> SIMD2<Float> {
    switch ordinal {
    case 0:
        return local
    case 1:
        return SIMD2(1 - local.y, local.x)
    case 2:
        return SIMD2(1 - local.x, 1 - local.y)
    case 3:
        return SIMD2(local.y, 1 - local.x)
    case 4:
        return SIMD2(local.x, 1 - local.y)
    case 5:
        return SIMD2(local.y, local.x)
    case 6:
        return SIMD2(1 - local.x, local.y)
    case 7:
        return SIMD2(1 - local.y, 1 - local.x)
    default:
        preconditionFailure(
            "TilingCoverageOracle square image ordinal must be in 0...7"
        )
    }
}

private func directSquareRasterImage(
    ordinal: UInt8,
    canonicalRasterSize: PixelSize
) -> Affine2D {
    let width = Float(canonicalRasterSize.width)
    let height = Float(canonicalRasterSize.height)
    let widthPerHeight = width / height
    let heightPerWidth = height / width
    switch ordinal {
    case 0:
        return .identity
    case 1:
        return Affine2D(
            xAxis: SIMD2(0, heightPerWidth),
            yAxis: SIMD2(-widthPerHeight, 0),
            translation: SIMD2(width, 0)
        )
    case 2:
        return Affine2D(
            xAxis: SIMD2(-1, 0),
            yAxis: SIMD2(0, -1),
            translation: SIMD2(width, height)
        )
    case 3:
        return Affine2D(
            xAxis: SIMD2(0, -heightPerWidth),
            yAxis: SIMD2(widthPerHeight, 0),
            translation: SIMD2(0, height)
        )
    case 4:
        return Affine2D(
            xAxis: SIMD2(1, 0),
            yAxis: SIMD2(0, -1),
            translation: SIMD2(0, height)
        )
    case 5:
        return Affine2D(
            xAxis: SIMD2(0, heightPerWidth),
            yAxis: SIMD2(widthPerHeight, 0),
            translation: .zero
        )
    case 6:
        return Affine2D(
            xAxis: SIMD2(-1, 0),
            yAxis: SIMD2(0, 1),
            translation: SIMD2(width, 0)
        )
    case 7:
        return Affine2D(
            xAxis: SIMD2(0, -heightPerWidth),
            yAxis: SIMD2(-widthPerHeight, 0),
            translation: SIMD2(width, height)
        )
    default:
        preconditionFailure(
            "TilingCoverageOracle square image ordinal must be in 0...7"
        )
    }
}

private func directSquareContains(
    _ point: SIMD2<Float>,
    footprint: OracleFootprint
) -> Bool {
    switch footprint {
    case .hardRound:
        return simd_dot(point, point) <= 1
    case .asymmetricTriangle:
        return contains(point, footprint: .asymmetricTriangle)
    }
}

private func directSquareOperationsAreEquivalent(
    _ lhs: DirectSquareOperation,
    _ rhs: DirectSquareOperation,
    presetID: SymmetryPresetID,
    coverageSymmetry: FootprintCoverageSymmetry
) -> Bool {
    let changesReflection = lhs.reflected != rhs.reflected
    let difference = Int(rhs.quarterTurns) - Int(lhs.quarterTurns)
    let turns = (difference % 4 + 4) % 4
    let policyAllows = presetID == .squareKaleidoscope
        || !changesReflection
    guard policyAllows else { return false }

    switch coverageSymmetry {
    case .oriented:
        return false
    case .halfTurnInvariant:
        return !changesReflection && turns == 2
    case .rotationInvariant:
        return !changesReflection
    case .reflectionInvariant:
        return changesReflection
    case .rotationAndReflectionInvariant:
        return true
    }
}

private func directSquareSignedArea(_ polygon: [SIMD2<Float>]) -> Float {
    guard polygon.count >= 3 else { return 0 }
    let origin = polygon[0]
    var twiceArea: Float = 0
    for index in 1..<(polygon.count - 1) {
        let first = polygon[index] - origin
        let second = polygon[index + 1] - origin
        twiceArea += first.x * second.y - first.y * second.x
    }
    return twiceArea * 0.5
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
    case .squareRotation, .squareKaleidoscope:
        let side = Float(min(tileSize.width, tileSize.height))
        let local = SIMD2(
            positiveFold(world.x, extent: side) / side,
            positiveFold(world.y, extent: side) / side
        )
        let imageCount: UInt8 = tiling == .squareRotation ? 4 : 8
        return (0..<imageCount).map {
            let image = directSquareForwardImage(local, ordinal: $0)
            return SIMD2(image.x * width, image.y * height)
        }
    case .hexagons, .rotation3, .rotation6, .kaleidoscope60,
         .kaleidoscope30:
        preconditionFailure(
            "Triangular folds must use the direct triangular oracle"
        )
    case .plainCanvas, .radialMirror, .radialRotation, .radialMandala:
        preconditionFailure(
            "Finite folds must use the radial coverage oracle"
        )
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
    case .squareRotation, .squareKaleidoscope:
        let side = Float(min(tileSize.width, tileSize.height))
        return DirectCell(
            column: cellIndex(world.x, extent: side),
            row: cellIndex(world.y, extent: side)
        )
    case .hexagons, .rotation3, .rotation6, .kaleidoscope60,
         .kaleidoscope30:
        preconditionFailure(
            "Triangular cells must use the direct triangular oracle"
        )
    case .plainCanvas, .radialMirror, .radialRotation, .radialMandala:
        preconditionFailure(
            "Finite cells must use the radial coverage oracle"
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
    case .squareRotation, .squareKaleidoscope:
        let side = Float(min(tileSize.width, tileSize.height))
        return SIMD2(
            Float(cell.column) * side,
            Float(cell.row) * side
        )
    case .hexagons, .rotation3, .rotation6, .kaleidoscope60,
         .kaleidoscope30:
        preconditionFailure(
            "Triangular origins must use the direct triangular oracle"
        )
    case .plainCanvas, .radialMirror, .radialRotation, .radialMandala:
        preconditionFailure(
            "Finite origins must use the radial coverage oracle"
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
