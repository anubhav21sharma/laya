import PatternEngine

func stageCMetalTestProgram(
    id: String,
    stabilization: BrushStabilizationDefinition = .none,
    usesTravelDirection: Bool = false,
    maximumAngularStep: Float = .pi / 6,
    stationaryDirection: Float = 0,
    baseSpacingFraction: Float = 0.1,
    replayMode: BrushReplayMode = .replayTail,
    replayLimits: BrushReplayLimits? = nil,
    emission: BrushEmissionDefinition = BrushEmissionDefinition(
        mode: .distance,
        timeInterval: nil
    )
) throws -> BrushProgram {
    let resolvedReplayLimits: BrushReplayLimits?
    switch replayMode {
    case .appendOnly:
        guard replayLimits == nil else {
            throw BrushDefinitionValidationError.invalidReplay
        }
        resolvedReplayLimits = nil
    case .replayTail:
        resolvedReplayLimits = replayLimits
            ?? BrushRecipePolicy.replayTailLimits
    case .boundedWholeStroke:
        resolvedReplayLimits = replayLimits
            ?? BrushRecipePolicy.wholeStrokeLimits
    }
    let base = try LegacyBrushRecipeAdapter.definition(
        from: .legacyEquivalent,
        displayName: id
    )
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
            terms: [
                BrushResponseTermDefinition(
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
                ),
            ]
        )
    }
    let termination: BrushTerminationDefinition = switch replayMode {
    case .appendOnly:
        .cap
    case .replayTail, .boundedWholeStroke:
        .boundedCorrection(
            maximumSamples: resolvedReplayLimits!.maximumSamples,
            maximumWorldLength: 4_096,
            maximumDabs: resolvedReplayLimits!.maximumDabs
        )
    }
    let definition = try BrushDefinition(
        v2ID: BrushRecipeID(id),
        metadata: base.metadata,
        capabilities: base.capabilities,
        resources: base.resources,
        coverage: base.coverage,
        placement: BrushPlacementDefinition(
            baseSpacingFraction: baseSpacingFraction,
            maximumSpacingFraction: max(
                baseSpacingFraction,
                base.placement.maximumSpacingFraction
            ),
            baseFlow: base.placement.baseFlow,
            strokeOpacity: base.placement.strokeOpacity,
            baseScatterFraction: 0,
            baseRotation: 0,
            baseJitterFraction: 0,
            baseOffset: .zero
        ),
        dynamics: base.dynamics,
        color: base.color,
        material: base.material,
        stabilization: base.stabilization,
        taper: .none,
        replayMode: replayMode,
        replayLimits: resolvedReplayLimits,
        termination: termination,
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
        emission: emission,
        tipSupports: [.analyticEllipse]
    )
    return try BrushProgramCompiler.compile(definition)
}
