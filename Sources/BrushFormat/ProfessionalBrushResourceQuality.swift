import Foundation
import PatternEngine

public struct ProfessionalBrushResourceQualityMeasurement:
    Equatable, Sendable
{
    public let minimum: UInt8
    public let maximum: UInt8
    public let mean: Double
    public let variance: Double
    public let horizontalSeamError: Double
    public let verticalSeamError: Double
    public let lowFrequencyEnergy: Double
    public let midFrequencyEnergy: Double
    public let highFrequencyEnergy: Double
    public let activePixelCount: Int
    public let activeBounds: ProfessionalBrushPixelBounds?
}

public struct ProfessionalBrushPixelBounds: Equatable, Sendable {
    public let minimumX: Int
    public let minimumY: Int
    public let maximumX: Int
    public let maximumY: Int
}

public enum ProfessionalBrushResourceQualityError:
    Error, Equatable, Sendable
{
    case invalidDimensions(width: Int, height: Int)
    case invalidByteCount(expected: Int, actual: Int)
    case insufficientRange
    case insufficientSupport
    case clippedSupport
    case excessiveSeamError
    case insufficientFrequencyEnergy
    case dominantLine
}

public enum ProfessionalBrushResourceQuality {
    public static func validate(
        bytes: [UInt8],
        width: Int,
        height: Int,
        kind: BrushResourceKind
    ) throws -> ProfessionalBrushResourceQualityMeasurement {
        guard width >= 64, height >= 64 else {
            throw ProfessionalBrushResourceQualityError.invalidDimensions(
                width: width,
                height: height
            )
        }
        guard bytes.count == width * height else {
            throw ProfessionalBrushResourceQualityError.invalidByteCount(
                expected: width * height,
                actual: bytes.count
            )
        }
        let measurement = measure(bytes: bytes, width: width, height: height)
        guard Int(measurement.maximum) - Int(measurement.minimum) >= 48 else {
            throw ProfessionalBrushResourceQualityError.insufficientRange
        }
        switch kind {
        case .shape:
            guard measurement.activePixelCount >= 128,
                  measurement.activeBounds != nil
            else {
                throw ProfessionalBrushResourceQualityError
                    .insufficientSupport
            }
            let bounds = measurement.activeBounds!
            guard bounds.minimumX > 0, bounds.minimumY > 0,
                  bounds.maximumX < width - 1,
                  bounds.maximumY < height - 1
            else {
                throw ProfessionalBrushResourceQualityError.clippedSupport
            }
        case .grain:
            guard measurement.horizontalSeamError <= 12,
                  measurement.verticalSeamError <= 12
            else {
                throw ProfessionalBrushResourceQualityError
                    .excessiveSeamError
            }
            guard measurement.highFrequencyEnergy >= 4,
                  measurement.midFrequencyEnergy >= 3,
                  measurement.lowFrequencyEnergy >= 2
            else {
                throw ProfessionalBrushResourceQualityError
                    .insufficientFrequencyEnergy
            }
            guard maximumLineMeanDeviation(
                bytes: bytes,
                width: width,
                height: height
            ) <= 40 else {
                throw ProfessionalBrushResourceQualityError.dominantLine
            }
        case .preview:
            break
        }
        return measurement
    }

    public static func measure(
        bytes: [UInt8],
        width: Int,
        height: Int
    ) -> ProfessionalBrushResourceQualityMeasurement {
        precondition(width > 0 && height > 0 && bytes.count == width * height)
        let minimum = bytes.min()!
        let maximum = bytes.max()!
        let mean = bytes.reduce(0.0) { $0 + Double($1) }
            / Double(bytes.count)
        let variance = bytes.reduce(0.0) {
            let delta = Double($1) - mean
            return $0 + delta * delta
        } / Double(bytes.count)
        let threshold = UInt8(max(8, Int(maximum) / 16))
        let active = bytes.indices.filter { bytes[$0] >= threshold }
        let bounds: ProfessionalBrushPixelBounds? = if active.isEmpty {
            nil
        } else {
            ProfessionalBrushPixelBounds(
                minimumX: active.map { $0 % width }.min()!,
                minimumY: active.map { $0 / width }.min()!,
                maximumX: active.map { $0 % width }.max()!,
                maximumY: active.map { $0 / width }.max()!
            )
        }
        return ProfessionalBrushResourceQualityMeasurement(
            minimum: minimum,
            maximum: maximum,
            mean: mean,
            variance: variance,
            horizontalSeamError: meanAbsoluteDifference(
                bytes: bytes,
                width: width,
                height: height,
                offsetX: width - 1,
                offsetY: 0,
                samples: (0..<height).map { (0, $0) }
            ),
            verticalSeamError: meanAbsoluteDifference(
                bytes: bytes,
                width: width,
                height: height,
                offsetX: 0,
                offsetY: height - 1,
                samples: (0..<width).map { ($0, 0) }
            ),
            lowFrequencyEnergy: frequencyEnergy(
                bytes: bytes, width: width, height: height, stride: 16
            ),
            midFrequencyEnergy: frequencyEnergy(
                bytes: bytes, width: width, height: height, stride: 4
            ),
            highFrequencyEnergy: frequencyEnergy(
                bytes: bytes, width: width, height: height, stride: 1
            ),
            activePixelCount: active.count,
            activeBounds: bounds
        )
    }

    private static func frequencyEnergy(
        bytes: [UInt8],
        width: Int,
        height: Int,
        stride: Int
    ) -> Double {
        var total = 0.0
        var count = 0
        for y in 0..<height {
            for x in 0..<(width - stride) {
                total += abs(
                    Double(bytes[y * width + x])
                        - Double(bytes[y * width + x + stride])
                )
                count += 1
            }
        }
        return total / Double(max(1, count))
    }

    private static func meanAbsoluteDifference(
        bytes: [UInt8],
        width: Int,
        height: Int,
        offsetX: Int,
        offsetY: Int,
        samples: [(Int, Int)]
    ) -> Double {
        let total = samples.reduce(0.0) { result, point in
            let first = bytes[point.1 * width + point.0]
            let second = bytes[
                (point.1 + offsetY) * width + point.0 + offsetX
            ]
            return result + abs(Double(first) - Double(second))
        }
        return total / Double(max(1, samples.count))
    }

    private static func maximumLineMeanDeviation(
        bytes: [UInt8],
        width: Int,
        height: Int
    ) -> Double {
        let globalMean = bytes.reduce(0.0) { $0 + Double($1) }
            / Double(bytes.count)
        let rowDeviation = (0..<height).map { y in
            let mean = bytes[(y * width)..<((y + 1) * width)]
                .reduce(0.0) { $0 + Double($1) } / Double(width)
            return abs(mean - globalMean)
        }.max() ?? 0
        let columnDeviation = (0..<width).map { x in
            let mean = (0..<height).reduce(0.0) {
                $0 + Double(bytes[$1 * width + x])
            } / Double(height)
            return abs(mean - globalMean)
        }.max() ?? 0
        return max(rowDeviation, columnDeviation)
    }
}
