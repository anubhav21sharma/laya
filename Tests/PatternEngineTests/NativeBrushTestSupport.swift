import PatternEngine

func nativeTestDefinition(
    _ recipe: BrushRecipe = .legacyEquivalent
) -> BrushDefinition {
    do {
        return try LegacyBrushRecipeAdapter.definition(
            from: recipe,
            displayName: recipe.id.rawValue
        )
    } catch {
        preconditionFailure("Native test definition must adapt: \(error)")
    }
}

func nativeTestProgram(
    _ recipe: BrushRecipe = .legacyEquivalent
) -> BrushProgram {
    do {
        return try BrushProgramCompiler.compile(
            nativeTestDefinition(recipe)
        )
    } catch {
        preconditionFailure("Native test program must compile: \(error)")
    }
}

func stageCTestProgram(
    id: String,
    stabilization: BrushStabilizationDefinition = .none,
    usesTravelDirection: Bool = false,
    maximumAngularStep: Float = .pi / 6,
    stationaryDirection: Float = 0,
    baseSpacingFraction: Float? = nil,
    maximumSpacingFraction: Float? = nil,
    coverage: BrushCoverageDefinition? = nil,
    outputOverrides: [
        BrushDynamicOutput: BrushOutputProgramDefinition
    ] = [:],
    randomization: BrushRandomization? = nil,
    tipSupports: [BrushTipSupportDefinition] = [.analyticEllipse],
    replayMode: BrushReplayMode = .appendOnly,
    replayLimits: BrushReplayLimits? = nil
) throws -> BrushProgram {
    let base = nativeTestDefinition()
    var outputs: [BrushDynamicOutput: BrushOutputProgramDefinition] = [:]
    for output in BrushDynamicOutput.allCases {
        let baseValue: Float = switch output {
        case .size, .flow, .opacity, .spacing, .hardness, .grain: 1
        case .rotation, .scatter, .offsetX, .offsetY, .hue, .saturation,
             .brightness, .secondaryColorMix: 0
        }
        outputs[output] = BrushOutputProgramDefinition(
            baseValue: baseValue,
            terms: []
        )
    }
    if usesTravelDirection {
        outputs[.rotation] = BrushOutputProgramDefinition(
            baseValue: 0,
            terms: [BrushResponseTermDefinition(
                input: .direction,
                response: .linear,
                inputInverted: false,
                missingInputValue: 0.5,
                responseScale: 2 * .pi,
                responseOffset: -.pi,
                responseLowerClamp: -.pi,
                responseUpperClamp: .pi,
                jitter: 0,
                operation: .replace
            )]
        )
    }
    for (output, program) in outputOverrides {
        outputs[output] = program
    }
    let coverage = coverage ?? base.coverage
    var capabilities = base.capabilities
    if coverage.shapes.count == 2,
       !capabilities.contains(where: {
           $0.identifier == BrushCapability.dualShape.rawValue
       })
    {
        capabilities.append(BrushCapabilityDeclaration(
            identifier: BrushCapability.dualShape.rawValue,
            required: true
        ))
    }
    let placement = BrushPlacementDefinition(
        baseSpacingFraction:
            baseSpacingFraction ?? base.placement.baseSpacingFraction,
        maximumSpacingFraction:
            maximumSpacingFraction
                ?? base.placement.maximumSpacingFraction,
        baseFlow: base.placement.baseFlow,
        strokeOpacity: base.placement.strokeOpacity,
        baseScatterFraction: 0,
        baseRotation: 0,
        baseJitterFraction: 0,
        baseOffset: .zero
    )
    let definition = try BrushDefinition(
        v2ID: BrushRecipeID(id),
        metadata: base.metadata,
        capabilities: capabilities,
        resources: base.resources,
        coverage: coverage,
        placement: placement,
        dynamics: randomization.map { value in
            BrushDynamicsDefinition(
                size: base.dynamics.size,
                flow: base.dynamics.flow,
                opacity: base.dynamics.opacity,
                spacing: base.dynamics.spacing,
                rotation: base.dynamics.rotation,
                scatter: base.dynamics.scatter,
                hardness: base.dynamics.hardness,
                grain: base.dynamics.grain,
                offsetX: base.dynamics.offsetX,
                offsetY: base.dynamics.offsetY,
                hue: base.dynamics.hue,
                saturation: base.dynamics.saturation,
                brightness: base.dynamics.brightness,
                secondaryColorMix: base.dynamics.secondaryColorMix,
                noPressureNeutral: base.dynamics.noPressureNeutral,
                randomization: value
            )
        } ?? base.dynamics,
        color: base.color,
        material: base.material,
        stabilization: base.stabilization,
        taper: .none,
        replayMode: replayMode,
        replayLimits: replayLimits,
        termination: .cap,
        seedPolicy: .perStroke,
        limits: base.limits,
        performanceIntent: base.performanceIntent,
        compatibility: base.compatibility,
        sensorNormalization: BrushSensorNormalizationDefinition(
            fullScaleWorldVelocity: 2_000,
            minimumVelocityDeltaTime: 0.001,
            fullScaleStrokeAge: 4,
            fullScaleStrokeDistanceInDiameters: 32
        ),
        sensorProgram: BrushSensorProgramDefinition(outputs: outputs),
        stabilizationV2: stabilization,
        direction: BrushDirectionDefinition(
            maximumAngularStep: maximumAngularStep,
            stationaryDirection: stationaryDirection
        ),
        emission: BrushEmissionDefinition(mode: .distance, timeInterval: nil),
        tipSupports: tipSupports
    )
    return try BrushProgramCompiler.compile(definition)
}
