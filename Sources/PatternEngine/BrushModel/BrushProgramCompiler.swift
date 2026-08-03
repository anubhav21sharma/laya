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
        guard definition.schemaVersion == BrushDefinition.legacySchemaVersion
                || definition.schemaVersion == BrushDefinition.currentSchemaVersion
        else {
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
        let stageC: BrushStageCProgramMetadata?
        if definition.schemaVersion == BrushDefinition.currentSchemaVersion {
            guard let normalization = definition.sensorNormalization,
                  let sensorProgram = definition.sensorProgram,
                  let stabilization = definition.stabilizationV2,
                  let direction = definition.direction,
                  let emission = definition.emission,
                  let tipSupports = definition.tipSupports
            else {
                throw BrushProgramCompilerError.invalidStageCDefinition
            }
            let endpointLag: Float? = switch stabilization {
            case .none, .weightedWindow: nil
            case let .delayed(distance): distance
            }
            let usesDirection = sensorProgram.outputs.values.contains { output in
                output.terms.contains { $0.input == .direction }
            }
            let compiledSensorProgram = try compileSensorProgram(
                sensorProgram,
                maximumOpacity: definition.limits.maximumOpacity
            )
            stageC = BrushStageCProgramMetadata(
                normalization: normalization,
                sensorProgram: sensorProgram,
                stabilization: stabilization,
                direction: direction,
                emission: emission,
                tipSupports: tipSupports,
                declaredEndpointLag: endpointLag,
                usesTravelDirection: usesDirection,
                compiledSensorProgram: compiledSensorProgram
            )
        } else {
            stageC = nil
        }

        return BrushProgram(
            definition: definition,
            dynamics: dynamics,
            termination: termination,
            requiredCapabilities: requiredCapabilities,
            ignoredOptionalCapabilityIdentifiers: ignoredOptionalCapabilityIdentifiers,
            requestedBackend: requestedBackend,
            stageC: stageC
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

    static func compileSensorProgram(
        _ definition: BrushSensorProgramDefinition,
        maximumOpacity: Float
    ) throws -> CompiledBrushSensorProgram {
        guard definition.outputs.count == 14 else {
            throw BrushProgramCompilerError.invalidStageCDefinition
        }
        return try CompiledBrushSensorProgram(
            size: compileSensorOutput(
                definition, output: .size, maximumOpacity: maximumOpacity
            ),
            flow: compileSensorOutput(
                definition, output: .flow, maximumOpacity: maximumOpacity
            ),
            opacity: compileSensorOutput(
                definition, output: .opacity, maximumOpacity: maximumOpacity
            ),
            spacing: compileSensorOutput(
                definition, output: .spacing, maximumOpacity: maximumOpacity
            ),
            rotation: compileSensorOutput(
                definition, output: .rotation, maximumOpacity: maximumOpacity
            ),
            scatter: compileSensorOutput(
                definition, output: .scatter, maximumOpacity: maximumOpacity
            ),
            hardness: compileSensorOutput(
                definition, output: .hardness, maximumOpacity: maximumOpacity
            ),
            grain: compileSensorOutput(
                definition, output: .grain, maximumOpacity: maximumOpacity
            ),
            offsetX: compileSensorOutput(
                definition, output: .offsetX, maximumOpacity: maximumOpacity
            ),
            offsetY: compileSensorOutput(
                definition, output: .offsetY, maximumOpacity: maximumOpacity
            ),
            hue: compileSensorOutput(
                definition, output: .hue, maximumOpacity: maximumOpacity
            ),
            saturation: compileSensorOutput(
                definition, output: .saturation,
                maximumOpacity: maximumOpacity
            ),
            brightness: compileSensorOutput(
                definition, output: .brightness,
                maximumOpacity: maximumOpacity
            ),
            secondaryColorMix: compileSensorOutput(
                definition, output: .secondaryColorMix,
                maximumOpacity: maximumOpacity
            )
        )
    }

    private static func compileSensorOutput(
        _ program: BrushSensorProgramDefinition,
        output: BrushDynamicOutput,
        maximumOpacity: Float
    ) throws -> CompiledBrushOutputProgram {
        guard let definition = program.outputs[output],
              definition.terms.count <= 4,
              validBaseValue(
                definition.baseValue,
                output: output,
                maximumOpacity: maximumOpacity
              )
        else {
            throw BrushProgramCompilerError.invalidStageCDefinition
        }
        var terms: [CompiledBrushSensorTerm] = []
        terms.reserveCapacity(definition.terms.count)
        for term in definition.terms {
            terms.append(try compileSensorTerm(term, output: output))
        }
        return CompiledBrushOutputProgram(
            baseValue: definition.baseValue,
            term0: terms.indices.contains(0) ? terms[0] : nil,
            term1: terms.indices.contains(1) ? terms[1] : nil,
            term2: terms.indices.contains(2) ? terms[2] : nil,
            term3: terms.indices.contains(3) ? terms[3] : nil
        )
    }

    private static func compileSensorTerm(
        _ term: BrushResponseTermDefinition,
        output: BrushDynamicOutput
    ) throws -> CompiledBrushSensorTerm {
        let finiteValues = [
            term.missingInputValue,
            term.responseScale,
            term.responseOffset,
            term.responseLowerClamp,
            term.responseUpperClamp,
            term.jitter,
        ]
        guard finiteValues.allSatisfy(\.isFinite),
              (0...1).contains(term.missingInputValue),
              term.responseLowerClamp <= term.responseUpperClamp,
              term.jitter >= 0,
              validOperation(term.operation, output: output),
              validResponse(term.response)
        else {
            throw BrushProgramCompilerError.invalidStageCDefinition
        }
        if isCyclic(term.input) {
            switch term.response {
            case let .curve(curve):
                guard curve.points.first?.y == curve.points.last?.y else {
                    throw BrushProgramCompilerError.invalidStageCDefinition
                }
            case .linear:
                guard output == .rotation || output == .hue else {
                    throw BrushProgramCompilerError.invalidStageCDefinition
                }
            case .constant, .boundedPower:
                throw BrushProgramCompilerError.invalidStageCDefinition
            }
        }
        let samples = try (0..<sampleCount).map { index in
            try responseValue(
                term.response,
                at: Float(index) / Float(sampleCount - 1)
            )
        }
        return CompiledBrushSensorTerm(
            input: term.input,
            samples: samples,
            inputInverted: term.inputInverted,
            missingInputValue: term.missingInputValue,
            responseScale: term.responseScale,
            responseOffset: term.responseOffset,
            responseLowerClamp: term.responseLowerClamp,
            responseUpperClamp: term.responseUpperClamp,
            jitter: term.jitter,
            operation: term.operation
        )
    }

    private static func validBaseValue(
        _ value: Float,
        output: BrushDynamicOutput,
        maximumOpacity: Float
    ) -> Bool {
        guard value.isFinite else { return false }
        return switch output {
        case .size, .spacing, .grain:
            (Float(1) / 1_024...8).contains(value)
        case .flow, .hardness, .scatter:
            (0...8).contains(value)
        case .opacity:
            (0...maximumOpacity).contains(value)
        case .secondaryColorMix:
            (0...1).contains(value)
        case .offsetX, .offsetY:
            (-8...8).contains(value)
        case .rotation, .hue:
            true
        case .saturation, .brightness:
            (-1...1).contains(value)
        }
    }

    private static func validOperation(
        _ operation: BrushResponseOperation,
        output: BrushDynamicOutput
    ) -> Bool {
        switch output {
        case .offsetX, .offsetY:
            operation != .multiply
        case .rotation, .hue:
            operation == .replace || operation == .multiply
                || operation == .add
        default:
            true
        }
    }

    private static func isCyclic(_ input: BrushDynamicsInput) -> Bool {
        input == .direction || input == .azimuth || input == .roll
    }

    private static func validResponse(_ response: BrushResponseDefinition)
        -> Bool
    {
        switch response {
        case let .constant(value):
            return value.isFinite && (0...1).contains(value)
        case .linear:
            return true
        case let .boundedPower(exponent):
            return exponent.isFinite && (0.125...8).contains(exponent)
        case let .curve(curve):
            guard curve.points.count >= 2,
                  curve.points.first?.x == 0,
                  curve.points.last?.x == 1
            else { return false }
            var previous: Float = -1
            for point in curve.points {
                guard point.x.isFinite, point.y.isFinite,
                      (0...1).contains(point.x), (0...1).contains(point.y),
                      point.x > previous
                else { return false }
                previous = point.x
            }
            return true
        }
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
