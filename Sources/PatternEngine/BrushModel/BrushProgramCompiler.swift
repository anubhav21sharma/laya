import Foundation

public enum BrushProgramCompiler {
    public static let sampleCount = 256

    #if DEBUG
    @TaskLocal
    static var testInvocationObserver: (@Sendable () -> Void)?
    #endif

    public static func compile(_ definition: BrushDefinition) throws -> BrushProgram {
        #if DEBUG
        testInvocationObserver?()
        #endif
        guard definition.schemaVersion == BrushDefinition.currentSchemaVersion else {
            throw BrushProgramCompilerError.unsupportedSchemaVersion(
                definition.schemaVersion
            )
        }

        var requiredCapabilities = Set<BrushCapability>()
        var ignoredOptionalCapabilityIdentifiers: [String] = []
        for declaration in definition.capabilities {
            if let capability = BrushCapability(rawValue: declaration.identifier) {
                if declaration.required {
                    requiredCapabilities.insert(capability)
                }
            } else if declaration.required {
                throw BrushProgramCompilerError.unknownRequiredCapability(
                    declaration.identifier
                )
            } else {
                ignoredOptionalCapabilityIdentifiers.append(declaration.identifier)
            }
        }

        let dynamics = try BrushDynamicsProgram(
            size: compile(definition.dynamics.size),
            flow: compile(definition.dynamics.flow),
            opacity: compile(definition.dynamics.opacity),
            spacing: compile(definition.dynamics.spacing),
            rotation: compile(definition.dynamics.rotation),
            scatter: compile(definition.dynamics.scatter),
            hardness: compile(definition.dynamics.hardness),
            grain: compile(definition.dynamics.grain),
            offsetX: compile(definition.dynamics.offsetX),
            offsetY: compile(definition.dynamics.offsetY),
            hue: compile(definition.dynamics.hue),
            saturation: compile(definition.dynamics.saturation),
            brightness: compile(definition.dynamics.brightness),
            secondaryColorMix: compile(definition.dynamics.secondaryColorMix)
        )
        let requestedBackend: BrushBackendKind = definition.material.interaction == .none
            ? .deposition
            : .canvasInteraction
        let termination = compileTermination(definition)

        return BrushProgram(
            definition: definition,
            dynamics: dynamics,
            termination: termination,
            requiredCapabilities: requiredCapabilities,
            ignoredOptionalCapabilityIdentifiers: ignoredOptionalCapabilityIdentifiers,
            requestedBackend: requestedBackend
        )
    }

    package static func compileTermination(
        _ definition: BrushDefinition
    ) -> BrushTerminationProgram {
        if definition.hasLegacySchemaV1Compatibility {
            if case .disabled = definition.taper.end {
                guard definition.replayMode != .appendOnly else {
                    return .legacySchemaV1Cap
                }
                guard let replayLimits = definition.replayLimits else {
                    preconditionFailure(
                        "Validated legacy replay must carry replay limits"
                    )
                }
                return .legacySchemaV1Replay(
                    mode: definition.replayMode,
                    replayLimits: replayLimits
                )
            }
            guard let replayLimits = definition.replayLimits else {
                preconditionFailure(
                    "Validated legacy end taper must carry replay limits"
                )
            }
            return .legacySchemaV1EndTaper(
                taper: definition.taper,
                replayLimits: replayLimits
            )
        }

        return switch definition.termination {
        case .cap:
            .cap
        case let .pressureRelease(maximumWorldLength):
            .pressureRelease(
                maximumWorldLength: maximumWorldLength
            )
        case let .boundedCorrection(
            maximumSamples,
            maximumWorldLength,
            maximumDabs
        ):
            .boundedCorrection(
                maximumSamples: maximumSamples,
                maximumWorldLength: maximumWorldLength,
                maximumDabs: maximumDabs
            )
        }
    }

    private static func compile(
        _ mapping: BrushMappingDefinition
    ) throws -> CompiledBrushResponse {
        switch mapping.response {
        case let .constant(value):
            return .constant(value)
        case .linear where mapping.isLegacyAffine:
            return .legacyLinear(
                input: mapping.input,
                minimum: mapping.offset,
                maximum: mapping.offset + mapping.scale,
                missingInputValue: mapping.missingInputValue
            )
        case let .boundedPower(exponent) where mapping.isLegacyAffine:
            return .legacyBoundedPower(
                input: mapping.input,
                minimum: mapping.offset,
                maximum: mapping.offset + mapping.scale,
                exponent: exponent,
                missingInputValue: mapping.missingInputValue
            )
        default:
            return try compileSampledCurve(mapping)
        }
    }

    private static func compileSampledCurve(
        _ mapping: BrushMappingDefinition
    ) throws -> CompiledBrushResponse {
        let samples = try (0..<sampleCount).map { index in
            let input = Float(index) / Float(sampleCount - 1)
            return try responseValue(mapping.response, at: input)
        }
        return .sampledCurve(
            input: mapping.input,
            samples: samples,
            scale: mapping.scale,
            offset: mapping.offset,
            lowerClamp: mapping.lowerClamp,
            upperClamp: mapping.upperClamp,
            inverted: mapping.inverted,
            jitter: mapping.jitter,
            missingInputValue: mapping.missingInputValue
        )
    }

    private static func responseValue(
        _ response: BrushResponseDefinition,
        at input: Float
    ) throws -> Float {
        switch response {
        case let .constant(value):
            return value
        case .linear:
            return input
        case let .boundedPower(exponent):
            return pow(input, exponent)
        case let .curve(curve):
            return try curveValue(curve, at: input)
        }
    }

    /// The first point with x >= input is the lower-bound endpoint. The
    /// preceding point is the segment start; exact x values select that point.
    private static func curveValue(
        _ curve: BrushCurveDefinition,
        at input: Float
    ) throws -> Float {
        let points = curve.points
        guard points.count >= 2, points.first?.x == 0, points.last?.x == 1
        else { throw BrushProgramCompilerError.invalidCurve }
        var previousX: Float = -1
        for point in points {
            guard point.x.isFinite, point.y.isFinite,
                  (0...1).contains(point.x), (0...1).contains(point.y),
                  point.x > previousX
            else { throw BrushProgramCompilerError.invalidCurve }
            previousX = point.x
        }
        let lowerBound = points.partitioningIndex { $0.x < input }
        if lowerBound == 0 { return points[0].y }
        if lowerBound == points.count { return points[points.count - 1].y }
        let upper = points[lowerBound]
        let lower = points[lowerBound - 1]
        if upper.x == input { return upper.y }
        let fraction = (input - lower.x) / (upper.x - lower.x)
        return lower.y + (upper.y - lower.y) * fraction
    }
}

private extension BrushMappingDefinition {
    var isLegacyAffine: Bool {
        let upper = offset + scale
        return !inverted
            && jitter == 0
            && scale >= 0
            && lowerClamp == offset
            && upperClamp == upper
    }
}

private extension Array {
    func partitioningIndex(
        where predicate: (Element) -> Bool
    ) -> Int {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let midpoint = lower + distance(from: lower, to: upper) / 2
            if predicate(self[midpoint]) {
                lower = index(after: midpoint)
            } else {
                upper = midpoint
            }
        }
        return lower
    }
}
