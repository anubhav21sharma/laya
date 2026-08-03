public enum BrushFootprintSpacingError: Error, Equatable, Sendable {
    case invalidSupportWidth
    case invalidBaseSpacingFraction
    case invalidDynamicSpacing
    case invalidMaximumSpacingFraction
    case arithmeticOverflow
}

/// Portable distance-spacing oracle for one fully evaluated dab footprint.
public enum BrushFootprintSpacing {
    public static func nextCarry(
        supportWidth: Double,
        baseSpacingFraction: Float,
        dynamicSpacing: Float,
        maximumSpacingFraction: Float
    ) throws -> Double {
        guard supportWidth.isFinite, supportWidth > 0 else {
            throw BrushFootprintSpacingError.invalidSupportWidth
        }
        guard baseSpacingFraction.isFinite, baseSpacingFraction > 0 else {
            throw BrushFootprintSpacingError.invalidBaseSpacingFraction
        }
        guard dynamicSpacing.isFinite, dynamicSpacing > 0 else {
            throw BrushFootprintSpacingError.invalidDynamicSpacing
        }
        guard maximumSpacingFraction.isFinite,
              maximumSpacingFraction >= baseSpacingFraction
        else {
            throw BrushFootprintSpacingError.invalidMaximumSpacingFraction
        }

        let authored = supportWidth
            * Double(baseSpacingFraction)
            * Double(dynamicSpacing)
        let ceilingCandidate = supportWidth
            * Double(maximumSpacingFraction)
        guard authored.isFinite,
              ceilingCandidate.isFinite
        else {
            throw BrushFootprintSpacingError.arithmeticOverflow
        }

        let safetyFloor = 1.0
        let safetyCeiling = max(
            safetyFloor,
            ceilingCandidate
        )
        return min(max(authored, safetyFloor), safetyCeiling)
    }
}
