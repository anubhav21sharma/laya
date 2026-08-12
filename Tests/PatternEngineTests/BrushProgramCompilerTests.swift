import Testing
@testable import PatternEngine

@Test
func compiledProgramAndStrokeReplayStateHaveBoundedValueFootprints() {
    let referenceSizedUpperBound = 2 * MemoryLayout<UnsafeRawPointer>.stride

    #expect(MemoryLayout<BrushProgram>.size <= referenceSizedUpperBound)
    #expect(MemoryLayout<StrokeVelocityFilter>.size <= 1_024)
    #expect(MemoryLayout<BrushInputDeriver>.size <= 1_088)
    #expect(MemoryLayout<BrushStrokeGenerator>.size <= 4_096)
    #expect(MemoryLayout<BrushStrokeGenerator.EmissionCursor>.size <= 12_288)
    #expect(MemoryLayout<TransientStrokeChunk>.size <= 6_144)
    #expect(MemoryLayout<TransientStrokeBuffer>.size <= 12_288)
}

@Test
func independentlyCompiledProgramsUseSemanticEquality() throws {
    let definition = try currentDefinition()
    let first = try BrushProgramCompiler.compile(definition)
    let second = try BrushProgramCompiler.compile(definition)
    let changedDefinitionProgram = try BrushProgramCompiler.compile(
        replacing(definition, seedPolicy: .fixed(99))
    )
    let stageCDefinition = try stageCV2Definition()
    let firstStageCProgram = try BrushProgramCompiler.compile(stageCDefinition)
    let secondStageCProgram = try BrushProgramCompiler.compile(stageCDefinition)
    let stageC = firstStageCProgram.primaryComponent.stageC
    let changedStageC = BrushStageCProgramMetadata(
        normalization: stageC.normalization,
        sensorProgram: stageC.sensorProgram,
        stabilization: stageC.stabilization,
        direction: stageC.direction,
        emission: stageC.emission,
        tipSupports: stageC.tipSupports,
        declaredEndpointLag: (stageC.declaredEndpointLag ?? 0) + 1,
        usesTravelDirection: stageC.usesTravelDirection,
        compiledSensorProgram: stageC.compiledSensorProgram
    )
    let compiledSensorProgram = stageC.compiledSensorProgram
    let rotation = compiledSensorProgram.rotation
    let rotationTerm = try #require(rotation.term0)
    let changedRotationTerm = CompiledBrushSensorTerm(
        input: rotationTerm.input,
        samples: rotationTerm.samples,
        inputInverted: rotationTerm.inputInverted,
        missingInputValue: rotationTerm.missingInputValue,
        responseScale: rotationTerm.responseScale + 1,
        responseOffset: rotationTerm.responseOffset,
        responseLowerClamp: rotationTerm.responseLowerClamp,
        responseUpperClamp: rotationTerm.responseUpperClamp,
        jitter: rotationTerm.jitter,
        operation: rotationTerm.operation
    )
    let changedRotation = CompiledBrushOutputProgram(
        baseValue: rotation.baseValue,
        term0: changedRotationTerm,
        term1: rotation.term1,
        term2: rotation.term2,
        term3: rotation.term3
    )
    let changedCompiledSensorProgram = CompiledBrushSensorProgram(
        size: compiledSensorProgram.size,
        flow: compiledSensorProgram.flow,
        opacity: compiledSensorProgram.opacity,
        spacing: compiledSensorProgram.spacing,
        rotation: changedRotation,
        scatter: compiledSensorProgram.scatter,
        hardness: compiledSensorProgram.hardness,
        grain: compiledSensorProgram.grain,
        offsetX: compiledSensorProgram.offsetX,
        offsetY: compiledSensorProgram.offsetY,
        hue: compiledSensorProgram.hue,
        saturation: compiledSensorProgram.saturation,
        brightness: compiledSensorProgram.brightness,
        secondaryColorMix: compiledSensorProgram.secondaryColorMix
    )

    let singleFieldVariants = [
        BrushProgram(
            definition: changedDefinitionProgram.definition,
            termination: first.termination,
            requiredCapabilities: first.requiredCapabilities,
            ignoredOptionalCapabilityIdentifiers:
                first.ignoredOptionalCapabilityIdentifiers,
            requestedBackend: first.requestedBackend,
            stageC: first.primaryComponent.stageC
        ),
        BrushProgram(
            definition: first.definition,
            termination: first.termination == .cap
                ? .pressureRelease(maximumWorldLength: 1)
                : .cap,
            requiredCapabilities: first.requiredCapabilities,
            ignoredOptionalCapabilityIdentifiers:
                first.ignoredOptionalCapabilityIdentifiers,
            requestedBackend: first.requestedBackend,
            stageC: first.primaryComponent.stageC
        ),
        BrushProgram(
            definition: first.definition,
            termination: first.termination,
            requiredCapabilities: first.requiredCapabilities == [.wetMix]
                ? []
                : [.wetMix],
            ignoredOptionalCapabilityIdentifiers:
                first.ignoredOptionalCapabilityIdentifiers,
            requestedBackend: first.requestedBackend,
            stageC: first.primaryComponent.stageC
        ),
        BrushProgram(
            definition: first.definition,
            termination: first.termination,
            requiredCapabilities: first.requiredCapabilities,
            ignoredOptionalCapabilityIdentifiers:
                first.ignoredOptionalCapabilityIdentifiers
                    == ["different.optional"]
                    ? []
                    : ["different.optional"],
            requestedBackend: first.requestedBackend,
            stageC: first.primaryComponent.stageC
        ),
        BrushProgram(
            definition: first.definition,
            termination: first.termination,
            requiredCapabilities: first.requiredCapabilities,
            ignoredOptionalCapabilityIdentifiers:
                first.ignoredOptionalCapabilityIdentifiers,
            requestedBackend: first.requestedBackend == .deposition
                ? .canvasInteraction
                : .deposition,
            stageC: first.primaryComponent.stageC
        ),
        BrushProgram(
            definition: first.definition,
            termination: first.termination,
            requiredCapabilities: first.requiredCapabilities,
            ignoredOptionalCapabilityIdentifiers:
                first.ignoredOptionalCapabilityIdentifiers,
            requestedBackend: first.requestedBackend,
            stageC: stageC
        ),
    ]

    #expect(first == first)
    #expect(first == second)
    #expect(firstStageCProgram == secondStageCProgram)
    #expect(stageC != changedStageC)
    #expect(compiledSensorProgram != changedCompiledSensorProgram)
    let stageCAlias = stageC
    let compiledSensorProgramAlias = compiledSensorProgram
    #expect(stageCAlias === stageC)
    #expect(compiledSensorProgramAlias === compiledSensorProgram)
    #expect(singleFieldVariants.count == 6)
    for variant in singleFieldVariants {
        #expect(first != variant)
    }
}

@Test(arguments: AnchorDefinitionFixtures.all)
func compiledProgramCharacterizationIsDeterministic(
    _ fixture: AnchorDefinitionFixture
) throws {
    let program = try BrushProgramCompiler.compile(fixture.definition)

    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 256, height: 256),
        worldCenter: WorldPoint(x: 128, y: 128)
    )
    for trace in [
        StrokeTraceFixtures.pressureRamp,
        StrokeTraceFixtures.curved,
        StrokeTraceFixtures.predictionCorrection,
    ] {
        let first = BrushCharacterizer.record(
            trace: trace, program: program, nominalDiameter: 20,
            color: .black, seed: 71, viewport: viewport
        )
        let repeated = BrushCharacterizer.record(
            trace: trace, program: program, nominalDiameter: 20,
            color: .black, seed: 71, viewport: viewport
        )
        #expect(first == repeated)
    }
}

@Test
func dynamicsEvaluatesACompiledProgram() throws {
    let definition = nativeTestDefinition()
    let program = try BrushProgramCompiler.compile(definition)
    let sample = InterpolatedStrokeSample(
        position: WorldPoint(x: 2, y: 3), pressure: 0.5, timestamp: 0,
        altitude: nil, azimuth: nil, roll: nil, velocity: 0,
        artisticVelocity: 0, phase: .moved,
        source: .mouse, kind: .actual, capabilities: []
    )
    let context = BrushStrokeContext(
        nominalDiameter: 20, color: .black, direction: 0, strokeAge: 0,
        traveledDistance: 0, ordinal: 0, isPredicted: false
    )

    let dab = BrushDynamicsEngine().evaluate(
        sample: sample,
        context: context,
        program: program,
        random: .centered,
        strokeSeed: 1
    )

    #expect(dab.position == WorldPoint(x: 2, y: 3))
}

@Test
func compilerRejectsUnknownRequiredCapabilityAndPreservesOptionalOne() throws {
    let base = try currentDefinition()
    let optional = try replacing(
        base,
        capabilities: [BrushCapabilityDeclaration(identifier: "future.capability", required: false)]
    )
    let program = try BrushProgramCompiler.compile(optional)
    #expect(program.ignoredOptionalCapabilityIdentifiers == ["future.capability"])

    let required = try replacing(
        base,
        capabilities: [BrushCapabilityDeclaration(identifier: "future.capability", required: true)]
    )
    #expect(throws: BrushProgramCompilerError.unknownRequiredCapability("future.capability")) {
        try BrushProgramCompiler.compile(required)
    }
}

@Test
func definitionValidationRejectsMalformedCurvesAndWetComponents() throws {
    let base = try currentDefinition()
    let malformed = BrushMappingDefinition(
        input: .pressure,
        response: .curve(BrushCurveDefinition(points: [
            BrushCurvePoint(x: 0.2, y: 0),
            BrushCurvePoint(x: 1, y: 1),
        ])),
        scale: 0.9, offset: 0.1, lowerClamp: 0.1, upperClamp: 1,
        inverted: false, jitter: 0, missingInputValue: 1
    )
    #expect(throws: BrushDefinitionValidationError.invalidCurve) {
        try replacing(base, dynamics: replacing(base.components[0].dynamics, size: malformed))
    }
    let wetMix = BrushMaterialDefinition(
        accumulation: .flow, interaction: .wetMix, edgeTreatment: .none,
        strength: 1, wetness: 0, bleedRadius: 0, softenPasses: 0,
        accumulationLimit: 1,
        interactionParameters: BrushInteractionDefinition(
            pickup: 0, pull: 0, dilution: 0, charge: 0, persistence: 0,
            dirtyHaloRadius: 0
        )
    )
    #expect(throws: BrushDefinitionValidationError.unsupportedComponentInteraction(
        ordinal: 0,
        interaction: .wetMix
    )) {
        try replacing(base, material: wetMix)
    }
}

@Test
func compilerSamplesThreePointCurveAtBothEndpoints() throws {
    let base = try currentDefinition()
    let curve = BrushMappingDefinition(
        input: .pressure,
        response: .curve(BrushCurveDefinition(points: [
            BrushCurvePoint(x: 0, y: 0),
            BrushCurvePoint(x: 0.5, y: 0.25),
            BrushCurvePoint(x: 1, y: 1),
        ])),
        scale: 0.9, offset: 0.1, lowerClamp: 0.1, upperClamp: 1,
        inverted: false, jitter: 0, missingInputValue: 1
    )
    let dynamics = replacing(base.components[0].dynamics, size: curve)
    let program = try BrushProgramCompiler.compile(
        replacing(base, dynamics: dynamics)
    )
    let samples = try #require(
        program.primaryComponent.stageC.compiledSensorProgram.size.term0
    ).samples

    #expect(samples.count == BrushProgramCompiler.sampleCount)
    #expect(samples[0] == 0)
    #expect(samples[127] == Float(127) / 510)
    #expect(abs(samples[128] - (0.25 + Float(3) / 1020)) < 0.000_001)
    #expect(samples[255] == 1)
}

@Test
func fixedSeedPolicyOverridesPerStrokeSeed() throws {
    let base = try currentDefinition()
    let fixed = try replacing(base, seedPolicy: .fixed(99))
    let program = try BrushProgramCompiler.compile(fixed)
    let first = BrushStrokeGenerator(program: program, nominalDiameter: 20, color: .black, seed: 1)
    let second = BrushStrokeGenerator(program: program, nominalDiameter: 20, color: .black, seed: 2)
    #expect(first.seed == 99)
    #expect(first == second)
}

@Test
func extensionRandomChannelsDoNotAdvanceCompatibilityCursor() {
    var baseline = BrushRandom(seed: 73)
    var withHue = BrushRandom(seed: 73)
    _ = BrushRandom.extensionUnitFloat(
        strokeSeed: 73,
        logicalDabOrdinal: 4,
        outputChannel: .hue
    )
    #expect(baseline.nextValues() == withHue.nextValues())
}

@Test
func nativeDynamicsApplyColorChannelsAndCarrySecondaryMix() throws {
    let base = try currentDefinition()
    let dynamics = replacing(
        base.components[0].dynamics,
        hue: nativeConstant(0.5),
        saturation: nativeConstant(0),
        brightness: nativeConstant(0),
        secondaryColorMix: nativeConstant(0.35)
    )
    let program = try BrushProgramCompiler.compile(
        replacing(base, dynamics: dynamics)
    )
    let dab = evaluateNative(program, color: InkColor(red: 1, green: 0, blue: 0, alpha: 0.8)!)

    // Hue is expressed in turns; saturation and brightness are additive HSB
    // adjustments. Zero is the exact neutral for every channel.
    #expect(dab.color == InkColor(red: 0, green: 1, blue: 1, alpha: 0.8))
    #expect(dab.secondaryColorMix == 0.35)
}

@Test
func nativeSaturationAndBrightnessMappingsAdjustHSBColor() throws {
    let base = try currentDefinition()
    var outputs = base.components[0].sensorProgram.outputs
    outputs[.saturation] = currentConstantOutput(-1)
    outputs[.brightness] = currentConstantOutput(0.2)
    let program = try BrushProgramCompiler.compile(
        replacing(
            base,
            sensorProgram: BrushSensorProgramDefinition(outputs: outputs)
        )
    )
    let dab = evaluateNative(program, color: InkColor(red: 1, green: 0, blue: 0, alpha: 0.8)!)
    #expect(dab.color == InkColor(red: 1, green: 1, blue: 1, alpha: 0.8))
}

@Test
func presentZeroSensorsDoNotUseMissingInputFallback() throws {
    let base = try currentDefinition()
    let tiltSize = BrushMappingDefinition(
        input: .tilt, response: .linear, scale: 0.9, offset: 0.1,
        lowerClamp: 0.1, upperClamp: 1, inverted: false, jitter: 0,
        missingInputValue: 0.7
    )
    let program = try BrushProgramCompiler.compile(
        replacing(base, dynamics: replacing(base.components[0].dynamics, size: tiltSize))
    )
    let presentZero = evaluateNative(
        program,
        altitude: .pi / 2,
        azimuth: 0,
        roll: 0,
        capabilities: [.altitude]
    )
    let absent = evaluateNative(program)

    #expect(presentZero.diameter == 2)
    #expect(abs(absent.diameter - 14.6) < 0.000_01)
}

@Test
func presentZeroAzimuthAndRollDoNotUseMissingFallback() throws {
    let base = try currentDefinition()
    let flow = BrushMappingDefinition(
        input: .azimuth, response: cyclicPresenceCurve(), scale: 0.8, offset: 0.1,
        lowerClamp: 0.1, upperClamp: 0.9, inverted: false, jitter: 0,
        missingInputValue: 0.2
    )
    let opacity = BrushMappingDefinition(
        input: .roll, response: cyclicPresenceCurve(), scale: 1, offset: 0,
        lowerClamp: 0, upperClamp: 1, inverted: false, jitter: 0,
        missingInputValue: 0.2
    )
    let program = try BrushProgramCompiler.compile(
        replacing(base, dynamics: replacing(base.components[0].dynamics, flow: flow, opacity: opacity))
    )
    let present = evaluateNative(
        program, azimuth: 0, roll: 0, capabilities: [.azimuth, .roll]
    )
    let absent = evaluateNative(program)
    #expect(abs(present.flow - 0.5) < 0.002)
    #expect(abs(present.strokeOpacity - 0.5) < 0.002)
    #expect(abs(absent.flow - 0.26) < 0.000_001)
    #expect(absent.strokeOpacity == 0.2)
}

@Test
func fixedSeedProgramAcceptsZeroCallerSeedAndPerStrokeRetainsNonzeroSeed() throws {
    let base = try currentDefinition()
    let fixed = try BrushProgramCompiler.compile(
        replacing(base, seedPolicy: .fixed(99))
    )
    let perStroke = try BrushProgramCompiler.compile(base)

    #expect(BrushStrokeGenerator(program: fixed, nominalDiameter: 20, color: .black, seed: 0).seed == 99)
    #expect(BrushStrokeGenerator(program: perStroke, nominalDiameter: 20, color: .black, seed: 7).seed == 7)
}

@Test
func hueJitterDoesNotChangeNativeScatterSpacingOrCompatibilityRandomValues() throws {
    let base = try currentDefinition()
    let nativeBase = try replacing(
        base,
        capabilities: [BrushCapabilityDeclaration(identifier: "future.capability", required: false)]
    )
    let hue = BrushMappingDefinition(
        input: .random, response: .linear, scale: 1, offset: -0.5,
        lowerClamp: -1, upperClamp: 1, inverted: false, jitter: 0.25,
        missingInputValue: 0
    )
    let baseline = try BrushProgramCompiler.compile(nativeBase)
    let withHue = try BrushProgramCompiler.compile(
        replacing(nativeBase, dynamics: replacing(nativeBase.components[0].dynamics, hue: hue))
    )
    var cursorA = BrushRandom(seed: 71)
    var cursorB = BrushRandom(seed: 71)
    let randomA = cursorA.nextValues()
    let randomB = cursorB.nextValues()
    let baselineDab = evaluateNative(baseline, random: randomA, seed: 71)
    let hueDab = evaluateNative(withHue, random: randomB, seed: 71)

    #expect(baselineDab.scatter == hueDab.scatter)
    #expect(baselineDab.spacing == hueDab.spacing)
    #expect(cursorA == cursorB)
}

@Test
func perStampColorJitterVariesByOrdinalAndLeavesSecondaryMixIsolated() throws {
    let base = try nativeDefinition()
    let color = BrushColorBehaviorDefinition(
        baseAdjustment: base.components[0].color.baseAdjustment,
        perStampJitter: BrushColorJitter(
            hue: 0.25, saturation: 0, brightness: 0, secondaryColorMix: 0
        ),
        perStrokeJitter: zeroColorJitter
    )
    let program = try BrushProgramCompiler.compile(replacing(base, color: color))

    let first = evaluateNative(
        program, color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!,
        seed: 71, ordinal: 2
    )
    let repeated = evaluateNative(
        program, color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!,
        seed: 71, ordinal: 2
    )
    let next = evaluateNative(
        program, color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!,
        seed: 71, ordinal: 3
    )
    let otherStroke = evaluateNative(
        program, color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!,
        seed: 72, ordinal: 2
    )

    #expect(first == repeated)
    #expect(first.color != next.color)
    #expect(first.color != otherStroke.color)
    #expect(first.secondaryColorMix == 0)
    #expect(next.secondaryColorMix == 0)
}

@Test
func perStrokeColorJitterIsConstantWithinStrokeAndVariesBySeed() throws {
    let base = try nativeDefinition()
    let color = BrushColorBehaviorDefinition(
        baseAdjustment: base.components[0].color.baseAdjustment,
        perStampJitter: zeroColorJitter,
        perStrokeJitter: BrushColorJitter(
            hue: 0.2, saturation: 0, brightness: 0, secondaryColorMix: 0.2
        )
    )
    let program = try BrushProgramCompiler.compile(replacing(base, color: color))
    let first = evaluateNative(
        program, color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!,
        seed: 71, ordinal: 0
    )
    let later = evaluateNative(
        program, color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!,
        seed: 71, ordinal: 9
    )
    let otherStroke = evaluateNative(
        program, color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!,
        seed: 72, ordinal: 0
    )

    #expect(first.color == later.color)
    #expect(first.secondaryColorMix == later.secondaryColorMix)
    #expect(first.color != otherStroke.color)
    #expect(first.secondaryColorMix != otherStroke.secondaryColorMix)
}

@Test
func secondaryMixJitterDoesNotChangeColorChannels() throws {
    let base = try nativeDefinition()
    let color = BrushColorBehaviorDefinition(
        baseAdjustment: base.components[0].color.baseAdjustment,
        perStampJitter: BrushColorJitter(
            hue: 0, saturation: 0, brightness: 0, secondaryColorMix: 0.4
        ),
        perStrokeJitter: zeroColorJitter
    )
    let dynamics = replacing(
        base.components[0].dynamics, secondaryColorMix: nativeConstant(0.5)
    )
    let program = try BrushProgramCompiler.compile(
        replacing(base, dynamics: dynamics, color: color)
    )
    let first = evaluateNative(program, seed: 71, ordinal: 1)
    let next = evaluateNative(program, seed: 71, ordinal: 2)

    #expect(first.color == next.color)
    #expect(first.secondaryColorMix != next.secondaryColorMix)
}

@Test
func placementJitterIsDeterministicAndIsolatedFromOtherPlacementChannels() throws {
    let base = try nativeDefinition()
    let baseline = try BrushProgramCompiler.compile(base)
    let jitteredPlacement = BrushPlacementDefinition(
        baseSpacingFraction: base.components[0].placement.baseSpacingFraction,
        maximumSpacingFraction: base.components[0].placement.maximumSpacingFraction,
        baseFlow: base.components[0].placement.baseFlow,
        strokeOpacity: base.components[0].placement.strokeOpacity,
        baseScatterFraction: base.components[0].placement.baseScatterFraction,
        baseRotation: base.components[0].placement.baseRotation,
        baseJitterFraction: 0.25,
        baseOffset: base.components[0].placement.baseOffset
    )
    let jittered = try BrushProgramCompiler.compile(
        replacing(base, placement: jitteredPlacement)
    )
    let unchanged = evaluateNative(baseline, seed: 71, ordinal: 2)
    let first = evaluateNative(jittered, seed: 71, ordinal: 2)
    let repeated = evaluateNative(jittered, seed: 71, ordinal: 2)
    let next = evaluateNative(jittered, seed: 71, ordinal: 3)
    let otherStroke = evaluateNative(jittered, seed: 72, ordinal: 2)

    #expect(first == repeated)
    #expect(unchanged.position == WorldPoint(x: 2, y: 3))
    #expect(first.position != unchanged.position)
    #expect(first.position != next.position)
    #expect(first.position != otherStroke.position)
    #expect(first.scatter == unchanged.scatter)
    #expect(first.spacing == unchanged.spacing)
    #expect(first.brushToWorld.translation == first.position.simd)
}

@Test
func nativeLogicalDabCarriesShapeGrainMaterialAndCounterRandomFrames() throws {
    let base = try nativeDefinition()
    let coverage = BrushCoverageDefinition(
        shapes: [
            BrushShapeLayerDefinition(
                shape: .chisel,
                combination: .replace,
                scale: 0.5,
                rotation: .pi / 2,
                offset: SIMD2(0.25, -0.5)
            ),
        ],
        grains: [
            BrushGrainLayerDefinition(
                grain: .paper,
                coordinateMode: .canonical,
                transform: BrushGrainTransform(
                    scale: 2,
                    rotation: 0.25,
                    offset: SIMD2(3, 4)
                ),
                grainMovementFraction: 0,
                grainFollowsBrushRotation: false,
                strength: 1
            ),
            BrushGrainLayerDefinition(
                grain: .noise,
                coordinateMode: .brushLocal,
                transform: BrushGrainTransform(
                    scale: 3,
                    rotation: 0.5,
                    offset: SIMD2(5, 6)
                ),
                grainMovementFraction: 0,
                grainFollowsBrushRotation: true,
                strength: 1
            ),
        ],
        baseHardness: 1,
        aspectRatio: 1,
        tipThreshold: 0,
        antialiasing: true
    )
    let program = try BrushProgramCompiler.compile(replacing(
        base,
        capabilities: [
            BrushCapabilityDeclaration(identifier: "dualGrain", required: true),
            BrushCapabilityDeclaration(
                identifier: "future.capability",
                required: false
            ),
        ],
        coverage: coverage
    ))
    let random = BrushRandomValues(
        spacing: 0.1,
        scatterX: 0.2,
        scatterY: 0.3,
        rotation: 0.4,
        grainX: 0.5,
        grainY: 0.6,
        materialVariation: 0.7
    )
    let dab = evaluateNative(
        program,
        random: random,
        seed: 71,
        ordinal: 4
    )

    #expect(dab.brushToWorld.translation == SIMD2(4.5, -2))
    #expect(abs(dab.brushToWorld.xAxis.x) < 0.000_001)
    #expect(dab.brushToWorld.xAxis.y == 5)
    #expect(dab.brushToWorld.yAxis.x == -5)
    #expect(abs(dab.brushToWorld.yAxis.y) < 0.000_001)
    #expect(abs(dab.worldBounds.minimum.x - -0.5) < 0.000_01)
    #expect(abs(dab.worldBounds.minimum.y - -7) < 0.000_01)
    #expect(abs(dab.worldBounds.maximum.x - 9.5) < 0.000_01)
    #expect(abs(dab.worldBounds.maximum.y - 3) < 0.000_01)
    #expect(dab.primaryGrainToWorld != nil)
    #expect(dab.secondaryGrainToWorld != nil)
    #expect(dab.materialInputs.accumulation == base.components[0].material.accumulation)
    #expect(dab.randomValues.compatibility == random)
    #expect(dab.randomValues.size == BrushRandom.extensionUnitFloat(
        strokeSeed: 71,
        logicalDabOrdinal: 4,
        outputChannel: .size
    ))
}

@Test
func nativeLogicalDabBoundsEncloseEveryShapeLayer() throws {
    let base = try nativeDefinition()
    let coverage = BrushCoverageDefinition(
        shapes: [
            BrushShapeLayerDefinition(
                shape: .hardRound,
                combination: .replace,
                scale: 0.5,
                rotation: 0,
                offset: .zero
            ),
            BrushShapeLayerDefinition(
                shape: .chisel,
                combination: .maximum,
                scale: 0.25,
                rotation: .pi / 2,
                offset: SIMD2(3, -2)
            ),
        ],
        grains: [],
        baseHardness: 1,
        aspectRatio: 1,
        tipThreshold: 0,
        antialiasing: true
    )
    let program = try BrushProgramCompiler.compile(replacing(
        base,
        capabilities: [
            BrushCapabilityDeclaration(identifier: "dualShape", required: true),
            BrushCapabilityDeclaration(
                identifier: "future.capability",
                required: false
            ),
        ],
        coverage: coverage
    ))

    let dab = evaluateNative(program)

    #expect(dab.brushToWorld.translation == SIMD2(2, 3))
    #expect(dab.brushToWorld.xAxis == SIMD2(5, 0))
    #expect(dab.brushToWorld.yAxis == SIMD2(0, 5))
    #expect(dab.worldBounds.minimum == SIMD2(-3, -19.5))
    #expect(dab.worldBounds.maximum == SIMD2(34.5, 8))
}

@Test
func nativeGrainFramesHonorCoordinateModeAndMovementFraction() throws {
    let base = try nativeDefinition()

    func evaluate(
        mode: BrushGrainCoordinateMode,
        movement: Float
    ) throws -> DabAttributes {
        let grain = BrushGrainLayerDefinition(
            grain: .paper,
            coordinateMode: mode,
            transform: BrushGrainTransform(
                scale: 2,
                rotation: 0,
                offset: SIMD2(1, 0)
            ),
            grainMovementFraction: movement,
            grainFollowsBrushRotation: false,
            strength: 1
        )
        let coverage = BrushCoverageDefinition(
            shapes: base.components[0].coverage.shapes,
            grains: [grain],
            baseHardness: base.components[0].coverage.baseHardness,
            aspectRatio: base.components[0].coverage.aspectRatio,
            tipThreshold: base.components[0].coverage.tipThreshold,
            antialiasing: base.components[0].coverage.antialiasing
        )
        return evaluateNative(try BrushProgramCompiler.compile(replacing(
            base,
            coverage: coverage
        )))
    }

    let anchored = try evaluate(mode: .canonical, movement: 0)
    let halfway = try evaluate(mode: .canonical, movement: 0.5)
    let traveling = try evaluate(mode: .canonical, movement: 1)
    let local = try evaluate(mode: .brushLocal, movement: 0)

    #expect(anchored.primaryGrainToWorld?.translation == SIMD2(1, 0))
    #expect(halfway.primaryGrainToWorld?.translation == SIMD2(2, 1.5))
    #expect(traveling.primaryGrainToWorld?.translation == SIMD2(3, 3))
    #expect(local.primaryGrainToWorld?.translation == SIMD2(3, 3))
    #expect(anchored.primaryGrainToWorld?.xAxis == SIMD2(2, 0))
    #expect(anchored.primaryGrainToWorld?.yAxis == SIMD2(0, 2))
}

@Test
func nativeGrainFollowRotatesAxesAndOffsetBeforeProjection() throws {
    let base = try nativeDefinition()

    func evaluate(followsBrush: Bool) throws -> DabAttributes {
        let grain = BrushGrainLayerDefinition(
            grain: .paper,
            coordinateMode: .canonical,
            transform: BrushGrainTransform(
                scale: 2,
                rotation: 0,
                offset: SIMD2(1, 0)
            ),
            grainMovementFraction: 0,
            grainFollowsBrushRotation: followsBrush,
            strength: 1
        )
        let coverage = BrushCoverageDefinition(
            shapes: base.components[0].coverage.shapes,
            grains: [grain],
            baseHardness: base.components[0].coverage.baseHardness,
            aspectRatio: base.components[0].coverage.aspectRatio,
            tipThreshold: base.components[0].coverage.tipThreshold,
            antialiasing: base.components[0].coverage.antialiasing
        )
        let placement = BrushPlacementDefinition(
            baseSpacingFraction: base.components[0].placement.baseSpacingFraction,
            maximumSpacingFraction: base.components[0].placement.maximumSpacingFraction,
            baseFlow: base.components[0].placement.baseFlow,
            strokeOpacity: base.components[0].placement.strokeOpacity,
            baseScatterFraction: base.components[0].placement.baseScatterFraction,
            baseRotation: .pi / 2,
            baseJitterFraction: base.components[0].placement.baseJitterFraction,
            baseOffset: base.components[0].placement.baseOffset
        )
        return evaluateNative(try BrushProgramCompiler.compile(replacing(
            base,
            placement: placement,
            coverage: coverage
        )))
    }

    let fixed = try evaluate(followsBrush: false)
    let following = try evaluate(followsBrush: true)
    let fixedFrame = try #require(fixed.primaryGrainToWorld)
    let followingFrame = try #require(following.primaryGrainToWorld)

    #expect(fixedFrame.translation == SIMD2(1, 0))
    #expect(fixedFrame.xAxis == SIMD2(2, 0))
    #expect(abs(followingFrame.translation.x) < 0.000_001)
    #expect(abs(followingFrame.translation.y - 1) < 0.000_001)
    #expect(abs(followingFrame.xAxis.x) < 0.000_001)
    #expect(abs(followingFrame.xAxis.y - 2) < 0.000_001)
    #expect(abs(followingFrame.yAxis.x + 2) < 0.000_001)
    #expect(abs(followingFrame.yAxis.y) < 0.000_001)

    let source = try LogicalDabBatch(
        seed: 9,
        startingOrdinal: following.ordinal,
        isPredicted: false,
        dabs: [following]
    )
    let projection = Affine2D(
        xAxis: SIMD2(0, 1),
        yAxis: SIMD2(-1, 0),
        translation: SIMD2(20, 30)
    )
    let frames = LogicalDabTransformer.transform(
        batch: source,
        through: [CompiledIsometry(
            ordinal: 0,
            localToCanonical: projection,
            operation: .identity
        )]
    )

    #expect(
        frames[0].primaryGrainToCanonical
            == followingFrame.concatenating(projection)
    )
}

private let zeroColorJitter = BrushColorJitter(
    hue: 0, saturation: 0, brightness: 0, secondaryColorMix: 0
)

@Test
func compilerPublishesStageCMetadataWithoutEvaluatingIt() throws {
    let definition = try stageCV2Definition()
    let program = try BrushProgramCompiler.compile(definition)
    let stageC = program.primaryComponent.stageC
    let component = definition.components[0]

    #expect(stageC.normalization == definition.sensorNormalization)
    #expect(stageC.sensorProgram == component.sensorProgram)
    #expect(stageC.stabilization == definition.stabilizationV2)
    #expect(stageC.direction == definition.direction)
    #expect(stageC.emission == component.emission)
    #expect(stageC.tipSupports == component.tipSupports)
    #expect(stageC.declaredEndpointLag == 6)
    #expect(stageC.usesTravelDirection)
}

private func stageCV2Definition() throws -> BrushDefinition {
    let base = try nativeDefinition()
    let component = base.components[0]
    var outputs = Dictionary(
        uniqueKeysWithValues: BrushDynamicOutput.allCases.map {
            ($0, BrushOutputProgramDefinition(baseValue: 1, terms: []))
        }
    )
    outputs[.rotation] = BrushOutputProgramDefinition(
        baseValue: 0,
        terms: [BrushResponseTermDefinition(
            input: .direction,
            response: .linear,
            inputInverted: false,
            missingInputValue: 0,
            responseScale: 1,
            responseOffset: 0,
            responseLowerClamp: -.pi,
            responseUpperClamp: .pi,
            jitter: 0,
            operation: .replace
        )]
    )
    return try BrushDefinition(
        id: base.id,
        metadata: base.metadata,
        capabilities: base.capabilities,
        resources: component.resources,
        coverage: component.coverage,
        placement: component.placement,
        dynamics: component.dynamics,
        color: component.color,
        material: component.material,
        stabilization: base.stabilization,
        taper: component.taper,
        replayMode: base.replayMode,
        replayLimits: base.replayLimits,
        termination: base.termination,
        seedPolicy: base.seedPolicy,
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
        stabilizationV2: .delayed(distance: 6),
        direction: BrushDirectionDefinition(
            maximumAngularStep: .pi / 6,
            stationaryDirection: 0
        ),
        emission: BrushEmissionDefinition(
            mode: .distanceAndTime,
            timeInterval: 1.0 / 120
        ),
        tipSupports: [.analyticEllipse]
    )
}

private func nativeDefinition() throws -> BrushDefinition {
    try replacing(
        currentDefinition(),
        capabilities: [
            BrushCapabilityDeclaration(
                identifier: "future.capability", required: false
            ),
        ]
    )
}

private func currentDefinition() throws -> BrushDefinition {
    nativeTestDefinition()
}

private func replacing(
    _ definition: BrushDefinition,
    dynamics: BrushDynamicsDefinition? = nil,
    capabilities: [BrushCapabilityDeclaration]? = nil,
    seedPolicy: BrushSeedPolicy? = nil,
    material: BrushMaterialDefinition? = nil,
    placement: BrushPlacementDefinition? = nil,
    color: BrushColorBehaviorDefinition? = nil,
    coverage: BrushCoverageDefinition? = nil,
    sensorProgram: BrushSensorProgramDefinition? = nil
) throws -> BrushDefinition {
    let component = definition.components[0]
    if let sensorProgram {
        return try BrushDefinition(
            id: definition.id,
            metadata: definition.metadata,
            capabilities: capabilities ?? definition.capabilities,
            resources: component.resources,
            coverage: coverage ?? component.coverage,
            placement: placement ?? component.placement,
            dynamics: dynamics ?? component.dynamics,
            color: color ?? component.color,
            material: material ?? component.material,
            stabilization: definition.stabilization,
            taper: component.taper,
            replayMode: definition.replayMode,
            replayLimits: definition.replayLimits,
            termination: definition.termination,
            seedPolicy: seedPolicy ?? definition.seedPolicy,
            limits: definition.limits,
            performanceIntent: definition.performanceIntent,
            compatibility: definition.compatibility,
            sensorNormalization: definition.sensorNormalization,
            sensorProgram: sensorProgram,
            stabilizationV2: definition.stabilizationV2,
            direction: definition.direction,
            emission: component.emission,
            tipSupports: component.tipSupports
        )
    }
    return try BrushDefinition(
        id: definition.id,
        metadata: definition.metadata,
        capabilities: capabilities ?? definition.capabilities,
        resources: component.resources,
        coverage: coverage ?? component.coverage,
        placement: placement ?? component.placement,
        dynamics: dynamics ?? component.dynamics,
        color: color ?? component.color,
        material: material ?? component.material,
        stabilization: definition.stabilization,
        taper: component.taper,
        replayMode: definition.replayMode,
        replayLimits: definition.replayLimits,
        seedPolicy: seedPolicy ?? definition.seedPolicy,
        limits: definition.limits,
        performanceIntent: definition.performanceIntent,
        compatibility: definition.compatibility
    )
}

private func currentConstantOutput(
    _ value: Float
) -> BrushOutputProgramDefinition {
    BrushOutputProgramDefinition(
        baseValue: 0,
        terms: [BrushResponseTermDefinition(
            input: .pressure,
            response: .constant(0),
            inputInverted: false,
            missingInputValue: 1,
            responseScale: 1,
            responseOffset: value,
            responseLowerClamp: value,
            responseUpperClamp: value,
            jitter: 0,
            operation: .replace
        )]
    )
}

private func cyclicPresenceCurve() -> BrushResponseDefinition {
    .curve(BrushCurveDefinition(points: [
        BrushCurvePoint(x: 0, y: 0),
        BrushCurvePoint(x: 0.5, y: 0.5),
        BrushCurvePoint(x: 1, y: 0),
    ]))
}

private func replacing(
    _ dynamics: BrushDynamicsDefinition,
    size: BrushMappingDefinition? = nil,
    flow: BrushMappingDefinition? = nil,
    opacity: BrushMappingDefinition? = nil,
    hue: BrushMappingDefinition? = nil,
    saturation: BrushMappingDefinition? = nil,
    brightness: BrushMappingDefinition? = nil,
    secondaryColorMix: BrushMappingDefinition? = nil
) -> BrushDynamicsDefinition {
    BrushDynamicsDefinition(
        size: size ?? dynamics.size, flow: flow ?? dynamics.flow,
        opacity: opacity ?? dynamics.opacity,
        spacing: dynamics.spacing, rotation: dynamics.rotation,
        scatter: dynamics.scatter, hardness: dynamics.hardness,
        grain: dynamics.grain, offsetX: dynamics.offsetX,
        offsetY: dynamics.offsetY, hue: hue ?? dynamics.hue,
        saturation: saturation ?? dynamics.saturation,
        brightness: brightness ?? dynamics.brightness,
        secondaryColorMix: secondaryColorMix ?? dynamics.secondaryColorMix,
        noPressureNeutral: dynamics.noPressureNeutral,
        randomization: dynamics.randomization
    )
}

private func nativeConstant(_ value: Float) -> BrushMappingDefinition {
    BrushMappingDefinition(
        input: .pressure, response: .constant(value), scale: 1, offset: 0,
        lowerClamp: value, upperClamp: value, inverted: false, jitter: 0,
        missingInputValue: 1
    )
}

private func evaluateNative(
    _ program: BrushProgram,
    color: InkColor = .black,
    altitude: Float? = nil,
    azimuth: Float? = nil,
    roll: Float? = nil,
    capabilities: StrokeInputCapabilities = [],
    random: BrushRandomValues = .centered,
    seed: UInt64 = 1,
    ordinal: UInt64 = 0
) -> DabAttributes {
    let sample = InterpolatedStrokeSample(
        position: WorldPoint(x: 2, y: 3), pressure: 0.5, timestamp: 0,
        altitude: altitude, azimuth: azimuth, roll: roll, velocity: 0,
        artisticVelocity: 0,
        phase: .moved, source: .mouse, kind: .actual, capabilities: capabilities
    )
    return BrushDynamicsEngine().evaluate(
        sample: sample,
        context: BrushStrokeContext(
            nominalDiameter: 20, color: color, direction: 0, strokeAge: 0,
            traveledDistance: 0, ordinal: ordinal, isPredicted: false
        ),
        program: program,
        random: random,
        strokeSeed: seed
    )
}
