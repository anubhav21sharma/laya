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

        let composition: CompiledBrushCompositionMode
        if definition.composition.identifier
            == BrushCompositionModeDeclaration.orderedSourceOverIdentifier
        {
            composition = .orderedSourceOver
        } else if definition.composition.required {
            throw BrushProgramCompilerError.unknownRequiredCompositionMode(
                definition.composition.identifier
            )
        } else {
            throw BrushProgramCompilerError.unsupportedCompositionMode(
                definition.composition.identifier
            )
        }

        let requestedBackend = BrushBackendKind.deposition
        let termination = compileTermination(definition)
        let componentPrograms = definition.components.map {
            compileComponent($0, root: definition)
        }
        let primaryComponent = componentPrograms[0]
        let secondaryComponent = componentPrograms.count == 2
            ? componentPrograms[1] : nil

        return BrushProgram(
            definition: definition,
            termination: termination,
            requiredCapabilities: requiredCapabilities,
            ignoredOptionalCapabilityIdentifiers: ignoredOptionalCapabilityIdentifiers,
            requestedBackend: requestedBackend,
            composition: composition,
            primaryComponent: primaryComponent,
            secondaryComponent: secondaryComponent
        )
    }

    private static func compileComponent(
        _ component: BrushComponentDefinition,
        root definition: BrushDefinition
    ) -> BrushComponentProgram {
        let stabilization = definition.stabilizationV2
        let sensorProgram = component.sensorProgram
        let endpointLag: Float? = switch stabilization {
        case .none, .weightedWindow: nil
        case let .delayed(distance): distance
        }
        let usesDirection = sensorProgram.outputs.values.contains { output in
            output.terms.contains { $0.input == .direction }
        }
        let compiledSensorProgram = compileSensorProgram(sensorProgram)
        let stageC = BrushStageCProgramMetadata(
            normalization: definition.sensorNormalization,
            sensorProgram: sensorProgram,
            stabilization: stabilization,
            direction: definition.direction,
            emission: component.emission,
            tipSupports: component.tipSupports,
            declaredEndpointLag: endpointLag,
            usesTravelDirection: usesDirection,
            compiledSensorProgram: compiledSensorProgram
        )

        return BrushComponentProgram(
            definition: component,
            stageC: stageC
        )
    }

    package static func compileTermination(
        _ definition: BrushDefinition
    ) -> BrushTerminationProgram {
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

    static func compileSensorProgram(
        _ definition: BrushSensorProgramDefinition
    ) -> CompiledBrushSensorProgram {
        CompiledBrushSensorProgram(
            size: compileSensorOutput(definition, output: .size),
            flow: compileSensorOutput(definition, output: .flow),
            opacity: compileSensorOutput(definition, output: .opacity),
            spacing: compileSensorOutput(definition, output: .spacing),
            rotation: compileSensorOutput(definition, output: .rotation),
            scatter: compileSensorOutput(definition, output: .scatter),
            hardness: compileSensorOutput(definition, output: .hardness),
            grain: compileSensorOutput(definition, output: .grain),
            offsetX: compileSensorOutput(definition, output: .offsetX),
            offsetY: compileSensorOutput(definition, output: .offsetY),
            hue: compileSensorOutput(definition, output: .hue),
            saturation: compileSensorOutput(definition, output: .saturation),
            brightness: compileSensorOutput(definition, output: .brightness),
            secondaryColorMix: compileSensorOutput(
                definition,
                output: .secondaryColorMix
            )
        )
    }

    private static func compileSensorOutput(
        _ program: BrushSensorProgramDefinition,
        output: BrushDynamicOutput
    ) -> CompiledBrushOutputProgram {
        let definition = program.outputs[output]!
        let terms = definition.terms.map(compileSensorTerm)
        return CompiledBrushOutputProgram(
            baseValue: definition.baseValue,
            term0: terms.indices.contains(0) ? terms[0] : nil,
            term1: terms.indices.contains(1) ? terms[1] : nil,
            term2: terms.indices.contains(2) ? terms[2] : nil,
            term3: terms.indices.contains(3) ? terms[3] : nil
        )
    }

    private static func compileSensorTerm(
        _ term: BrushResponseTermDefinition
    ) -> CompiledBrushSensorTerm {
        let samples = (0..<sampleCount).map { index in
            responseValue(
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

    private static func responseValue(
        _ response: BrushResponseDefinition,
        at input: Float
    ) -> Float {
        switch response {
        case let .constant(value):
            return value
        case .linear:
            return input
        case let .boundedPower(exponent):
            return pow(input, exponent)
        case let .curve(curve):
            return curveValue(curve, at: input)
        }
    }

    /// The first point with x >= input is the lower-bound endpoint. The
    /// preceding point is the segment start; exact x values select that point.
    private static func curveValue(
        _ curve: BrushCurveDefinition,
        at input: Float
    ) -> Float {
        let points = curve.points
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
