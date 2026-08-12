import PatternEngine

func nativeTestDefinition(
    id: BrushRecipeID = BrushRecipeID("test.current.hard-round"),
    coverage: BrushCoverageDefinition? = nil,
    placement: BrushPlacementDefinition? = nil,
    dynamics: BrushDynamicsDefinition? = nil,
    color: BrushColorBehaviorDefinition? = nil,
    material: BrushMaterialDefinition? = nil,
    stabilization: Float = 0,
    taper: BrushTaperConfiguration = .none,
    replayMode: BrushReplayMode = .appendOnly,
    replayLimits: BrushReplayLimits? = nil,
    termination: BrushTerminationDefinition? = nil
) -> BrushDefinition {
    do {
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
        let resolvedCoverage = coverage ?? BrushCoverageDefinition(
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
        )
        let resources = (
            resolvedCoverage.shapes.compactMap {
                testResource(for: $0.shape, kind: .shape)
            }
            + resolvedCoverage.grains.compactMap {
                testResource(for: $0.grain, kind: .grain)
            }
        ).sorted { $0.identifier < $1.identifier }
        let jitter = BrushColorJitter(
            hue: 0,
            saturation: 0,
            brightness: 0,
            secondaryColorMix: 0
        )
        let resolvedDynamics = dynamics ?? BrushDynamicsDefinition(
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
        )
        let resolvedTermination = termination ?? {
            switch replayMode {
            case .appendOnly:
                return BrushTerminationDefinition.cap
            case .replayTail:
                guard let replayLimits else {
                    preconditionFailure("Replay-tail test definition needs limits")
                }
                return .boundedCorrection(
                    maximumSamples: replayLimits.maximumSamples,
                    maximumWorldLength: 4_096,
                    maximumDabs: replayLimits.maximumDabs
                )
            }
        }()
        return try BrushDefinition(
            id: id,
            metadata: BrushMetadata(displayName: id.rawValue),
            capabilities: [],
            resources: resources,
            coverage: resolvedCoverage,
            placement: placement ?? BrushPlacementDefinition(
                baseSpacingFraction: 0.125,
                maximumSpacingFraction: 0.125,
                baseFlow: 1,
                strokeOpacity: 1,
                baseScatterFraction: 0,
                baseRotation: 0,
                baseJitterFraction: 0,
                baseOffset: .zero
            ),
            dynamics: resolvedDynamics,
            color: color ?? BrushColorBehaviorDefinition(
                baseAdjustment: .identity,
                perStampJitter: jitter,
                perStrokeJitter: jitter
            ),
            material: material ?? BrushMaterialDefinition(
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
            stabilization: stabilization,
            taper: taper,
            replayMode: replayMode,
            replayLimits: replayLimits,
            termination: resolvedTermination,
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
    } catch {
        preconditionFailure("Current test definition must construct: \(error)")
    }
}

private func testResource(
    for descriptor: BrushShapeDescriptor,
    kind: BrushResourceKind
) -> BrushResourceReference? {
    guard case let .asset(identifier) = descriptor else { return nil }
    return BrushResourceReference(
        identifier: identifier,
        kind: kind,
        required: false,
        fallback: .builtIn(identifier: identifier)
    )
}

private func testResource(
    for descriptor: BrushGrainDescriptor,
    kind: BrushResourceKind
) -> BrushResourceReference? {
    guard case let .asset(identifier) = descriptor else { return nil }
    return BrushResourceReference(
        identifier: identifier,
        kind: kind,
        required: false,
        fallback: .builtIn(identifier: identifier)
    )
}

func nativeTestProgram(
    _ definition: BrushDefinition = nativeTestDefinition()
) -> BrushProgram {
    do {
        return try BrushProgramCompiler.compile(definition)
    } catch {
        preconditionFailure("Current test program must compile: \(error)")
    }
}

func nativeTestComponent(
    from definition: BrushDefinition,
    identifier: String,
    ordinal: UInt8,
    coverage: BrushCoverageDefinition? = nil,
    placement: BrushPlacementDefinition? = nil,
    dynamics: BrushDynamicsDefinition? = nil,
    color: BrushColorBehaviorDefinition? = nil,
    material: BrushMaterialDefinition? = nil,
    taper: BrushTaperConfiguration? = nil,
    sensorProgram: BrushSensorProgramDefinition? = nil,
    emission: BrushEmissionDefinition? = nil,
    tipSupports: [BrushTipSupportDefinition]? = nil
) -> BrushComponentDefinition {
    let component = definition.components[0]
    return BrushComponentDefinition(
        identifier: BrushComponentIdentifier(identifier),
        ordinal: ordinal,
        resources: component.resources,
        coverage: coverage ?? component.coverage,
        placement: placement ?? component.placement,
        dynamics: dynamics ?? component.dynamics,
        color: color ?? component.color,
        material: material ?? component.material,
        taper: taper ?? component.taper,
        sensorProgram: sensorProgram ?? component.sensorProgram,
        emission: emission ?? component.emission,
        tipSupports: tipSupports ?? component.tipSupports
    )
}

func nativeCompositeTestDefinition(
    from definition: BrushDefinition,
    composition: BrushCompositionModeDeclaration = .orderedSourceOver,
    components: [BrushComponentDefinition]
) throws -> BrushDefinition {
    try BrushDefinition(
        id: definition.id,
        metadata: definition.metadata,
        capabilities: definition.capabilities,
        composition: composition,
        components: components,
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
    )
}

func nativeTestMapping(
    input: BrushDynamicsInput,
    output: ClosedRange<Float>,
    response: BrushResponseDefinition = .linear,
    missingInputValue: Float = 1
) -> BrushMappingDefinition {
    BrushMappingDefinition(
        input: input,
        response: response,
        scale: output.upperBound - output.lowerBound,
        offset: output.lowerBound,
        lowerClamp: output.lowerBound,
        upperClamp: output.upperBound,
        inverted: false,
        jitter: 0,
        missingInputValue: missingInputValue
    )
}

func nativeTestDynamics(
    size: BrushMappingDefinition? = nil,
    flow: BrushMappingDefinition? = nil,
    spacing: BrushMappingDefinition? = nil,
    rotation: BrushMappingDefinition? = nil,
    scatter: BrushMappingDefinition? = nil,
    hardness: BrushMappingDefinition? = nil,
    grain: BrushMappingDefinition? = nil,
    noPressureNeutral: Float = 1,
    randomization: BrushRandomization = .none
) -> BrushDynamicsDefinition {
    let base = nativeTestDefinition().components[0].dynamics
    return BrushDynamicsDefinition(
        size: size ?? base.size,
        flow: flow ?? base.flow,
        opacity: base.opacity,
        spacing: spacing ?? base.spacing,
        rotation: rotation ?? base.rotation,
        scatter: scatter ?? base.scatter,
        hardness: hardness ?? base.hardness,
        grain: grain ?? base.grain,
        offsetX: base.offsetX,
        offsetY: base.offsetY,
        hue: base.hue,
        saturation: base.saturation,
        brightness: base.brightness,
        secondaryColorMix: base.secondaryColorMix,
        noPressureNeutral: noPressureNeutral,
        randomization: randomization
    )
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
    emission: BrushEmissionDefinition = BrushEmissionDefinition(
        mode: .distance,
        timeInterval: nil
    ),
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
    let coverage = coverage ?? base.components[0].coverage
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
            baseSpacingFraction ?? base.components[0].placement.baseSpacingFraction,
        maximumSpacingFraction:
            maximumSpacingFraction
                ?? base.components[0].placement.maximumSpacingFraction,
        baseFlow: base.components[0].placement.baseFlow,
        strokeOpacity: base.components[0].placement.strokeOpacity,
        baseScatterFraction: 0,
        baseRotation: 0,
        baseJitterFraction: 0,
        baseOffset: .zero
    )
    let definition = try BrushDefinition(
        id: BrushRecipeID(id),
        metadata: base.metadata,
        capabilities: capabilities,
        resources: base.components[0].resources,
        coverage: coverage,
        placement: placement,
        dynamics: randomization.map { value in
            BrushDynamicsDefinition(
                size: base.components[0].dynamics.size,
                flow: base.components[0].dynamics.flow,
                opacity: base.components[0].dynamics.opacity,
                spacing: base.components[0].dynamics.spacing,
                rotation: base.components[0].dynamics.rotation,
                scatter: base.components[0].dynamics.scatter,
                hardness: base.components[0].dynamics.hardness,
                grain: base.components[0].dynamics.grain,
                offsetX: base.components[0].dynamics.offsetX,
                offsetY: base.components[0].dynamics.offsetY,
                hue: base.components[0].dynamics.hue,
                saturation: base.components[0].dynamics.saturation,
                brightness: base.components[0].dynamics.brightness,
                secondaryColorMix: base.components[0].dynamics.secondaryColorMix,
                noPressureNeutral: base.components[0].dynamics.noPressureNeutral,
                randomization: value
            )
        } ?? base.components[0].dynamics,
        color: base.components[0].color,
        material: base.components[0].material,
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
        emission: emission,
        tipSupports: tipSupports
    )
    return try BrushProgramCompiler.compile(definition)
}
