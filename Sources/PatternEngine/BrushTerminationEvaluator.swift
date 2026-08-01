import Foundation

/// Measured, already-retained suffix offered to a termination program.
public struct BrushTerminationCorrection: Equatable, Sendable {
    public let sampleCount: Int
    public let worldLength: Float
    public let dabCount: Int
    public let ordinalRange: Range<UInt64>

    public init(
        sampleCount: Int,
        worldLength: Float,
        dabCount: Int,
        ordinalRange: Range<UInt64>
    ) {
        self.sampleCount = sampleCount
        self.worldLength = worldLength
        self.dabCount = dabCount
        self.ordinalRange = ordinalRange
    }
}

public enum BrushTerminationDecision: Equatable, Sendable {
    case appendCap
    case appendPressureRelease(maximumWorldLength: Float)
    case replaceBoundedCorrection(ordinalRange: Range<UInt64>)
    case replaceLegacySchemaV1EndTaper(ordinalRange: Range<UInt64>)
}

public enum BrushTerminationEvaluationError: Error, Equatable, Sendable {
    case invalidCorrection
    case maximumSamplesExceeded(actual: Int, maximum: Int)
    case maximumWorldLengthExceeded(actual: Float, maximum: Float)
    case maximumDabsExceeded(actual: Int, maximum: Int)
}

/// Pure, allocation-free policy evaluation. Causal programs intentionally do
/// not return an ordinal range, so callers cannot reinterpret cap or pressure
/// release as permission to rewrite deposited body dabs.
public struct BrushTerminationEvaluator: Equatable, Sendable {
    public let program: BrushTerminationProgram

    public init(program: BrushTerminationProgram) {
        self.program = program
    }

    public func evaluate(
        _ correction: BrushTerminationCorrection
    ) throws -> BrushTerminationDecision {
        guard correction.sampleCount >= 0,
              correction.worldLength.isFinite,
              correction.worldLength >= 0,
              correction.dabCount >= 0,
              correction.ordinalRange.upperBound
                >= correction.ordinalRange.lowerBound,
              correction.ordinalRange.upperBound
                - correction.ordinalRange.lowerBound
                == UInt64(correction.dabCount)
        else {
            throw BrushTerminationEvaluationError.invalidCorrection
        }

        switch program {
        case .cap:
            return .appendCap
        case let .pressureRelease(maximumWorldLength):
            return .appendPressureRelease(
                maximumWorldLength: maximumWorldLength
            )
        case let .boundedCorrection(
            maximumSamples,
            maximumWorldLength,
            maximumDabs
        ):
            if correction.sampleCount > maximumSamples {
                throw BrushTerminationEvaluationError.maximumSamplesExceeded(
                    actual: correction.sampleCount,
                    maximum: maximumSamples
                )
            }
            if correction.worldLength > maximumWorldLength {
                throw BrushTerminationEvaluationError
                    .maximumWorldLengthExceeded(
                        actual: correction.worldLength,
                        maximum: maximumWorldLength
                    )
            }
            if correction.dabCount > maximumDabs {
                throw BrushTerminationEvaluationError.maximumDabsExceeded(
                    actual: correction.dabCount,
                    maximum: maximumDabs
                )
            }
            return .replaceBoundedCorrection(
                ordinalRange: correction.ordinalRange
            )
        case .legacySchemaV1Cap:
            return .appendCap
        case .legacySchemaV1EndTaper:
            return .replaceLegacySchemaV1EndTaper(
                ordinalRange: correction.ordinalRange
            )
        case .legacySchemaV1Replay:
            return .appendCap
        }
    }
}
