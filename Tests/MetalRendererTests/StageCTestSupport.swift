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
    }
    let base = try stageCMetalBaseDefinition(id: id)
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
    case .replayTail:
        .boundedCorrection(
            maximumSamples: resolvedReplayLimits!.maximumSamples,
            maximumWorldLength: 4_096,
            maximumDabs: resolvedReplayLimits!.maximumDabs
        )
    }
    let definition = try BrushDefinition(
        id: BrushRecipeID(id),
        metadata: base.metadata,
        capabilities: base.capabilities,
        resources: base.components[0].resources,
        coverage: base.components[0].coverage,
        placement: BrushPlacementDefinition(
            baseSpacingFraction: baseSpacingFraction,
            maximumSpacingFraction: max(
                baseSpacingFraction,
                base.components[0].placement.maximumSpacingFraction
            ),
            baseFlow: base.components[0].placement.baseFlow,
            strokeOpacity: base.components[0].placement.strokeOpacity,
            baseScatterFraction: 0,
            baseRotation: 0,
            baseJitterFraction: 0,
            baseOffset: .zero
        ),
        dynamics: base.components[0].dynamics,
        color: base.components[0].color,
        material: base.components[0].material,
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

func stageCMetalBaseDefinition(id: String) throws -> BrushDefinition {
    func constant(_ value: Float) -> BrushMappingDefinition {
        BrushMappingDefinition(
            input: .pressure,
            response: .constant(value),
            scale: 1,
            offset: 0,
            lowerClamp: value,
            upperClamp: value,
            inverted: false,
            jitter: 0,
            missingInputValue: 1
        )
    }
    let jitter = BrushColorJitter(
        hue: 0,
        saturation: 0,
        brightness: 0,
        secondaryColorMix: 0
    )
    return try BrushDefinition(
        id: BrushRecipeID(id),
        metadata: BrushMetadata(displayName: id),
        capabilities: [],
        resources: [],
        coverage: BrushCoverageDefinition(
            shapes: [BrushShapeLayerDefinition(
                shape: .hardRound,
                combination: .replace,
                scale: 1,
                rotation: 0,
                offset: .zero
            )],
            grains: [],
            baseHardness: 1,
            aspectRatio: 1,
            tipThreshold: 0,
            antialiasing: true
        ),
        placement: BrushPlacementDefinition(
            baseSpacingFraction: 0.125,
            maximumSpacingFraction: 0.125,
            baseFlow: 1,
            strokeOpacity: 1,
            baseScatterFraction: 0,
            baseRotation: 0,
            baseJitterFraction: 0,
            baseOffset: .zero
        ),
        dynamics: BrushDynamicsDefinition(
            size: constant(1),
            flow: constant(1),
            opacity: constant(1),
            spacing: constant(1),
            rotation: constant(0),
            scatter: constant(1),
            hardness: constant(1),
            grain: constant(1),
            offsetX: constant(0),
            offsetY: constant(0),
            hue: constant(0),
            saturation: constant(0),
            brightness: constant(0),
            secondaryColorMix: constant(0),
            noPressureNeutral: 1,
            randomization: .none
        ),
        color: BrushColorBehaviorDefinition(
            baseAdjustment: .identity,
            perStampJitter: jitter,
            perStrokeJitter: jitter
        ),
        material: BrushMaterialDefinition(
            accumulation: .flow,
            interaction: .none,
            edgeTreatment: .none,
            strength: 1,
            wetness: 0,
            bleedRadius: 0,
            softenPasses: 0,
            accumulationLimit: 1,
            interactionParameters: nil
        ),
        stabilization: 0,
        taper: .none,
        replayMode: .appendOnly,
        replayLimits: nil,
        termination: .cap,
        seedPolicy: .perStroke,
        limits: BrushDefinitionLimits(
            minimumDiameter: 0.01,
            maximumDiameter: 16_384,
            maximumOpacity: 1,
            maximumSpacingFraction: 4,
            maximumResourceDimension: 4_096,
            maximumResidentBytes: 64 * 1_024 * 1_024
        ),
        performanceIntent: .realtime120,
        compatibility: BrushCompatibilityMetadata(
            sourceSettingKeys: [],
            requiredSemanticKeys: []
        )
    )
}

func stageCMetalCompositeProgram(
    id: String,
    replayMode: BrushReplayMode = .replayTail,
    replayLimits: BrushReplayLimits? = nil
) throws -> BrushProgram {
    let primaryProgram = try stageCMetalTestProgram(
        id: id,
        replayMode: replayMode,
        replayLimits: replayLimits
    )
    let definition = primaryProgram.definition
    let primary = definition.components[0]
    let secondary = BrushComponentDefinition(
        identifier: BrushComponentIdentifier("secondary"),
        ordinal: 1,
        resources: primary.resources,
        coverage: primary.coverage,
        placement: primary.placement,
        dynamics: primary.dynamics,
        color: primary.color,
        material: primary.material,
        taper: primary.taper,
        sensorProgram: primary.sensorProgram,
        emission: primary.emission,
        tipSupports: primary.tipSupports
    )
    return try BrushProgramCompiler.compile(BrushDefinition(
        id: definition.id,
        metadata: definition.metadata,
        capabilities: definition.capabilities,
        composition: .orderedSourceOver,
        components: [primary, secondary],
        stabilization: definition.stabilization,
        replayMode: definition.replayMode,
        replayLimits: definition.replayLimits,
        termination: definition.termination,
        seedPolicy: definition.seedPolicy,
        limits: definition.limits,
        performanceIntent: definition.performanceIntent,
        compatibility: definition.compatibility,
        sensorNormalization: definition.sensorNormalization,
        stabilizationV2: definition.stabilizationV2,
        direction: definition.direction
    ))
}
