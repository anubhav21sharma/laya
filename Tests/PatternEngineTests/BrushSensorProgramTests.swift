import Foundation
import Testing
@testable import PatternEngine

@Test
func schemaV1EvaluatorPinsEveryInputAndOutputBeforeOrderedPrograms() throws {
    let base = nativeTestDefinition()
    let dynamics = BrushDynamicsDefinition(
        size: legacyLinear(.pressure, 1...2),
        flow: legacyLinear(.speed, 0.5...1),
        opacity: legacyLinear(.direction, 0.5...1),
        spacing: legacyLinear(.tilt, 0.5...1),
        rotation: legacyLinear(.azimuth, -1...1),
        scatter: legacyLinear(.roll, 0.5...1),
        hardness: legacyLinear(.tangentialPressure, 0.5...1),
        grain: legacyLinear(.age, 0.5...1),
        offsetX: legacyLinear(.distance, -2...2),
        offsetY: legacyLinear(.pressure, -2...2),
        hue: legacyLinear(.pressure, -0.2...0.2),
        saturation: legacyLinear(.speed, -0.2...0.2),
        brightness: legacyLinear(.direction, -0.2...0.2),
        secondaryColorMix: legacyLinear(.tilt, 0...1),
        noPressureNeutral: 1,
        randomization: BrushRandomization(
            spacing: 0, scatter: 1, rotation: 0, grain: 0, material: 0
        )
    )
    let definition = try schemaV1Definition(base: base, dynamics: dynamics)
    let program = try BrushProgramCompiler.compile(definition)
    let sample = sensorSample(
        pressure: 0.25,
        velocity: 25,
        altitude: 3 * .pi / 8,
        azimuth: -.pi / 2,
        roll: -.pi / 2,
        tangentialPressure: -0.5,
        capabilities: .supported
    )
    let context = sensorContext(
        nominalDiameter: 64,
        color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!,
        direction: -.pi / 2,
        strokeAge: 2.5,
        traveledDistance: 25
    )
    let dab = BrushDynamicsEngine().evaluate(
        sample: sample,
        context: context,
        program: program,
        random: BrushRandomValues(
            spacing: 0.5,
            scatterX: 0.75,
            scatterY: 0.25,
            rotation: 0.5,
            grainX: 0.5,
            grainY: 0.5,
            materialVariation: 0.5
        ),
        strokeSeed: 0x0123_4567_89ab_cdef
    )

    #expect(program.stageC == nil)
    #expect(dab.diameter == 80)
    #expect(dab.flow == 0.625)
    #expect(dab.strokeOpacity == 0.625)
    #expect(dab.spacing == 6.25)
    #expect(dab.rotation == -0.5)
    #expect(dab.scatter == SIMD2<Float>(2, -2))
    #expect(dab.hardness == 0.625)
    #expect(dab.grainScale == 0.625)
    #expect(dab.position == WorldPoint(x: 1, y: -3))
    #expect(dab.color == InkColor(
        red: 0.9, green: 0.090_000_03, blue: 0.576_000_33, alpha: 1
    ))
    #expect(dab.secondaryColorMix == 0.249_999_94)
}

@Test
func schemaV1OptionalAbsenceAndCounterRandomStayPinned() throws {
    let base = nativeTestDefinition()
    let fallback = BrushMappingDefinition(
        input: .tilt,
        response: .linear,
        scale: 1,
        offset: 1,
        lowerClamp: 1,
        upperClamp: 2,
        inverted: false,
        jitter: 0,
        missingInputValue: 0.75
    )
    let randomOffset = BrushMappingDefinition(
        input: .random,
        response: .linear,
        scale: 2,
        offset: -1,
        lowerClamp: -1,
        upperClamp: 1,
        inverted: false,
        jitter: 0,
        missingInputValue: 0
    )
    let dynamics = BrushDynamicsDefinition(
        size: fallback,
        flow: base.dynamics.flow,
        opacity: base.dynamics.opacity,
        spacing: base.dynamics.spacing,
        rotation: base.dynamics.rotation,
        scatter: base.dynamics.scatter,
        hardness: base.dynamics.hardness,
        grain: base.dynamics.grain,
        offsetX: randomOffset,
        offsetY: base.dynamics.offsetY,
        hue: base.dynamics.hue,
        saturation: base.dynamics.saturation,
        brightness: base.dynamics.brightness,
        secondaryColorMix: base.dynamics.secondaryColorMix,
        noPressureNeutral: base.dynamics.noPressureNeutral,
        randomization: base.dynamics.randomization
    )
    let program = try BrushProgramCompiler.compile(
        schemaV1Definition(base: base, dynamics: dynamics)
    )
    let engine = BrushDynamicsEngine()
    let absent = engine.evaluate(
        sample: sensorSample(), context: sensorContext(), program: program,
        random: .centered, strokeSeed: 0x0123_4567_89ab_cdef
    )
    let presentZero = engine.evaluate(
        sample: sensorSample(
            altitude: .pi / 2, capabilities: [.altitude]
        ),
        context: sensorContext(), program: program, random: .centered,
        strokeSeed: 0x0123_4567_89ab_cdef
    )

    #expect(absent.diameter == 35)
    #expect(presentZero.diameter == 20)
    #expect(absent.position.x == 0.947_274_3)
    #expect(presentZero.position.x == absent.position.x)
}

@Test(arguments: BrushDynamicsInput.allCases)
func schemaV2OneTermMatchesIndependentScalarReferenceForEverySensor(
    input: BrushDynamicsInput
) throws {
    let isCyclic = input == .direction || input == .azimuth || input == .roll
    let response: BrushResponseDefinition = isCyclic
        ? .curve(BrushCurveDefinition(points: [
            BrushCurvePoint(x: 0, y: 0),
            BrushCurvePoint(x: 0.25, y: 0.25),
            BrushCurvePoint(x: 0.5, y: 0.5),
            BrushCurvePoint(x: 0.75, y: 0.25),
            BrushCurvePoint(x: 1, y: 0),
        ]))
        : .linear
    let term = BrushResponseTermDefinition(
        input: input,
        response: response,
        inputInverted: false,
        missingInputValue: 0.6,
        responseScale: 1,
        responseOffset: 1,
        responseLowerClamp: 1,
        responseUpperClamp: 2,
        jitter: 0,
        operation: .replace
    )
    let sensorProgram = sensorProgramReplacing(
        .size,
        with: BrushOutputProgramDefinition(baseValue: 1, terms: [term])
    )
    let program = try BrushProgramCompiler.compile(
        schemaV2Definition(sensorProgram: sensorProgram)
    )
    let seed: UInt64 = 0x0123_4567_89ab_cdef
    let sample = sensorSample(
        pressure: 0.25,
        velocity: 25,
        altitude: 3 * .pi / 8,
        azimuth: -.pi / 2,
        roll: -.pi / 2,
        tangentialPressure: -0.5,
        capabilities: .supported
    )
    let context = sensorContext(
        direction: -.pi / 2,
        strokeAge: 2.5,
        traveledDistance: 25
    )
    let expected = referenceOutput(
        output: .size,
        definition: sensorProgram.outputs[.size]!,
        normalizedInputs: referenceInputs(sample: sample, context: context),
        strokeSeed: seed,
        ordinal: context.ordinal,
        maximumOpacity: program.definition.limits.maximumOpacity
    )
    let dab = BrushDynamicsEngine().evaluate(
        sample: sample,
        context: context,
        program: program,
        random: .centered,
        strokeSeed: seed
    )

    #expect(closeSensor(dab.diameter / context.nominalDiameter, expected))
}

@Test(arguments: BrushDynamicOutput.allCases)
func schemaV2FourTermProgramMatchesIndependentReferenceForEveryOutput(
    output: BrushDynamicOutput
) throws {
    let operations: [BrushResponseOperation] = switch output {
    case .offsetX, .offsetY:
        [.replace, .add, .minimum, .maximum]
    case .rotation, .hue:
        [.replace, .multiply, .add, .add]
    default:
        [.replace, .multiply, .add, .maximum]
    }
    let terms = [
        BrushResponseTermDefinition(
            input: .pressure,
            response: .curve(BrushCurveDefinition(points: [
                BrushCurvePoint(x: 0, y: 0),
                BrushCurvePoint(x: 0.5, y: 1),
                BrushCurvePoint(x: 1, y: 0),
            ])),
            inputInverted: false,
            missingInputValue: 0.6,
            responseScale: 0.5,
            responseOffset: 0.25,
            responseLowerClamp: -8,
            responseUpperClamp: 8,
            jitter: 0,
            operation: operations[0]
        ),
        BrushResponseTermDefinition(
            input: .speed,
            response: .linear,
            inputInverted: false,
            missingInputValue: 0.6,
            responseScale: 0.5,
            responseOffset: 1,
            responseLowerClamp: -8,
            responseUpperClamp: 8,
            jitter: 0,
            operation: operations[1]
        ),
        BrushResponseTermDefinition(
            input: .tilt,
            response: .boundedPower(exponent: 2),
            inputInverted: true,
            missingInputValue: 0.6,
            responseScale: 0.5,
            responseOffset: 0,
            responseLowerClamp: -8,
            responseUpperClamp: 8,
            jitter: 0,
            operation: operations[2]
        ),
        BrushResponseTermDefinition(
            input: .age,
            response: .constant(0.5),
            inputInverted: false,
            missingInputValue: 0.6,
            responseScale: 0.2,
            responseOffset: 0,
            responseLowerClamp: -8,
            responseUpperClamp: 8,
            jitter: 0.05,
            operation: operations[3]
        ),
    ]
    let initialBase: Float = switch output {
    case .size, .flow, .opacity, .spacing, .hardness, .grain: 1
    case .rotation, .scatter, .offsetX, .offsetY, .hue, .saturation,
         .brightness, .secondaryColorMix: 0
    }
    let outputDefinition = BrushOutputProgramDefinition(
        baseValue: initialBase,
        terms: terms
    )
    let sensorProgram = sensorProgramReplacing(
        output,
        with: outputDefinition
    )
    let program = try BrushProgramCompiler.compile(
        schemaV2Definition(sensorProgram: sensorProgram)
    )
    let seed: UInt64 = 0x0123_4567_89ab_cdef
    let sample = sensorSample(
        pressure: 0.25,
        velocity: 25,
        altitude: 3 * .pi / 8,
        capabilities: [.pressure, .altitude]
    )
    let color: InkColor = switch output {
    case .saturation, .brightness:
        InkColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1)!
    default:
        InkColor(red: 1, green: 0, blue: 0, alpha: 1)!
    }
    let context = sensorContext(
        color: color,
        strokeAge: 2.5,
        traveledDistance: 25
    )
    let expected = referenceOutput(
        output: output,
        definition: outputDefinition,
        normalizedInputs: referenceInputs(sample: sample, context: context),
        strokeSeed: seed,
        ordinal: context.ordinal,
        maximumOpacity: program.definition.limits.maximumOpacity
    )
    let dab = BrushDynamicsEngine().evaluate(
        sample: sample,
        context: context,
        program: program,
        random: BrushRandomValues(
            spacing: 0.5,
            scatterX: 0.75,
            scatterY: 0.25,
            rotation: 0.5,
            grainX: 0.5,
            grainY: 0.5,
            materialVariation: 0.5
        ),
        strokeSeed: seed
    )

    switch output {
    case .size:
        #expect(closeSensor(dab.diameter / context.nominalDiameter, expected))
    case .flow:
        #expect(closeSensor(dab.flow, expected))
    case .opacity:
        #expect(closeSensor(dab.strokeOpacity, expected))
    case .spacing:
        #expect(closeSensor(
            dab.spacing
                / (context.nominalDiameter
                    * program.definition.placement.baseSpacingFraction),
            expected
        ))
    case .rotation:
        #expect(closeSensor(dab.rotation, expected))
    case .scatter:
        #expect(closeSensor(
            dab.scatter.x
                / (context.nominalDiameter
                    * program.definition.placement.baseScatterFraction * 0.5),
            expected
        ))
    case .hardness:
        #expect(closeSensor(dab.hardness, expected))
    case .grain:
        #expect(closeSensor(dab.grainScale, expected))
    case .offsetX:
        #expect(closeSensor(
            dab.position.x / context.nominalDiameter,
            expected
        ))
    case .offsetY:
        #expect(closeSensor(
            dab.position.y / context.nominalDiameter,
            expected
        ))
    case .hue:
        #expect(colorsClose(
            dab.color,
            referenceApplyingColor(color, hue: expected)
        ))
    case .saturation:
        #expect(colorsClose(
            dab.color,
            referenceApplyingColor(color, saturation: expected)
        ))
    case .brightness:
        #expect(colorsClose(
            dab.color,
            referenceApplyingColor(color, brightness: expected)
        ))
    case .secondaryColorMix:
        #expect(closeSensor(dab.secondaryColorMix, expected))
    }
}

@Test
func schemaV2PresentZeroStaysZeroWhileAbsentUsesTermFallback() throws {
    let term = BrushResponseTermDefinition(
        input: .pressure,
        response: .linear,
        inputInverted: false,
        missingInputValue: 0.75,
        responseScale: 1,
        responseOffset: 1,
        responseLowerClamp: 1,
        responseUpperClamp: 2,
        jitter: 0,
        operation: .replace
    )
    let program = try BrushProgramCompiler.compile(schemaV2Definition(
        sensorProgram: sensorProgramReplacing(
            .size,
            with: BrushOutputProgramDefinition(baseValue: 1, terms: [term])
        )
    ))
    let context = sensorContext()
    let presentZero = BrushDynamicsEngine().evaluate(
        sample: sensorSample(pressure: 0, capabilities: [.pressure]),
        context: context,
        program: program,
        random: .centered,
        strokeSeed: 9
    )
    let absent = BrushDynamicsEngine().evaluate(
        sample: sensorSample(pressure: 0, capabilities: []),
        context: context,
        program: program,
        random: .centered,
        strokeSeed: 9
    )

    #expect(presentZero.diameter == context.nominalDiameter)
    #expect(absent.diameter == context.nominalDiameter * 1.75)
}

@Test
func schemaV2FinalContractsClampAndWrapOnlyAfterComposition() throws {
    func term(_ value: Float, operation: BrushResponseOperation = .add)
        -> BrushResponseTermDefinition
    {
        BrushResponseTermDefinition(
            input: .pressure,
            response: .constant(1),
            inputInverted: false,
            missingInputValue: 0,
            responseScale: 0,
            responseOffset: value,
            responseLowerClamp: -100,
            responseUpperClamp: 100,
            jitter: 0,
            operation: operation
        )
    }
    var outputs = sensorProgramReplacing(
        .size,
        with: BrushOutputProgramDefinition(
            baseValue: 1,
            terms: [term(10), term(-3, operation: .multiply)]
        )
    ).outputs
    outputs[.offsetX] = BrushOutputProgramDefinition(
        baseValue: 0,
        terms: [term(-10)]
    )
    outputs[.rotation] = BrushOutputProgramDefinition(
        baseValue: .pi,
        terms: [term(4 * .pi)]
    )
    outputs[.hue] = BrushOutputProgramDefinition(
        baseValue: 0,
        terms: [term(2.25)]
    )
    let program = try BrushProgramCompiler.compile(schemaV2Definition(
        sensorProgram: BrushSensorProgramDefinition(outputs: outputs)
    ))
    let context = sensorContext(
        color: InkColor(red: 1, green: 0, blue: 0, alpha: 1)!
    )
    let dab = BrushDynamicsEngine().evaluate(
        sample: sensorSample(pressure: 0.5, capabilities: [.pressure]),
        context: context,
        program: program,
        random: .centered,
        strokeSeed: 9
    )

    #expect(dab.diameter == context.nominalDiameter / 1_024)
    #expect(dab.position.x == -8 * context.nominalDiameter)
    #expect(dab.rotation == -.pi)
    #expect(colorsClose(
        dab.color,
        InkColor(red: 0.5, green: 1, blue: 0, alpha: 1)!
    ))
}

@Test
func schemaV2PeriodicCurveHasEqualCyclicEndpointEvaluation() throws {
    let term = BrushResponseTermDefinition(
        input: .direction,
        response: .curve(BrushCurveDefinition(points: [
            BrushCurvePoint(x: 0, y: 0.25),
            BrushCurvePoint(x: 0.5, y: 0.75),
            BrushCurvePoint(x: 1, y: 0.25),
        ])),
        inputInverted: false,
        missingInputValue: 0,
        responseScale: 1,
        responseOffset: 0,
        responseLowerClamp: 0,
        responseUpperClamp: 1,
        jitter: 0,
        operation: .replace
    )
    let program = try BrushProgramCompiler.compile(schemaV2Definition(
        sensorProgram: sensorProgramReplacing(
            .rotation,
            with: BrushOutputProgramDefinition(baseValue: 0, terms: [term])
        )
    ))
    let engine = BrushDynamicsEngine()
    let negative = engine.evaluate(
        sample: sensorSample(),
        context: sensorContext(direction: -.pi),
        program: program,
        random: .centered,
        strokeSeed: 9
    )
    let positive = engine.evaluate(
        sample: sensorSample(),
        context: sensorContext(direction: .pi),
        program: program,
        random: .centered,
        strokeSeed: 9
    )

    #expect(negative.rotation == 0.25)
    #expect(positive.rotation == negative.rotation)
}

@Test
func schemaV2CompilerBoundaryRejectsEveryInvalidOrderedProgramClass() throws {
    let valid = BrushResponseTermDefinition(
        input: .pressure,
        response: .linear,
        inputInverted: false,
        missingInputValue: 0,
        responseScale: 1,
        responseOffset: 0,
        responseLowerClamp: 0,
        responseUpperClamp: 1,
        jitter: 0,
        operation: .replace
    )
    #expect(throws: BrushProgramCompilerError.invalidStageCDefinition) {
        _ = try BrushProgramCompiler.compileSensorProgram(
            sensorProgramReplacing(
            .size,
            with: BrushOutputProgramDefinition(
                baseValue: 1,
                terms: [valid, valid, valid, valid, valid]
            )
            ),
            maximumOpacity: 1
        )
    }
    #expect(throws: BrushProgramCompilerError.invalidStageCDefinition) {
        _ = try BrushProgramCompiler.compileSensorProgram(
            sensorProgramReplacing(
            .offsetX,
            with: BrushOutputProgramDefinition(
                baseValue: 0,
                terms: [BrushResponseTermDefinition(
                    input: .pressure,
                    response: .linear,
                    inputInverted: false,
                    missingInputValue: 0,
                    responseScale: 1,
                    responseOffset: 0,
                    responseLowerClamp: 0,
                    responseUpperClamp: 1,
                    jitter: 0,
                    operation: .multiply
                )]
            )
            ),
            maximumOpacity: 1
        )
    }
    #expect(throws: BrushProgramCompilerError.invalidStageCDefinition) {
        _ = try BrushProgramCompiler.compileSensorProgram(
            sensorProgramReplacing(
            .size,
            with: BrushOutputProgramDefinition(
                baseValue: 1,
                terms: [BrushResponseTermDefinition(
                    input: .pressure,
                    response: .linear,
                    inputInverted: false,
                    missingInputValue: 0,
                    responseScale: 1,
                    responseOffset: 0,
                    responseLowerClamp: 2,
                    responseUpperClamp: 1,
                    jitter: 0,
                    operation: .replace
                )]
            )
            ),
            maximumOpacity: 1
        )
    }
    #expect(throws: BrushProgramCompilerError.invalidStageCDefinition) {
        _ = try BrushProgramCompiler.compileSensorProgram(
            sensorProgramReplacing(
            .size,
            with: BrushOutputProgramDefinition(
                baseValue: 1,
                terms: [BrushResponseTermDefinition(
                    input: .pressure,
                    response: .curve(BrushCurveDefinition(points: [
                        BrushCurvePoint(x: 0, y: 0),
                        BrushCurvePoint(x: 0, y: 1),
                    ])),
                    inputInverted: false,
                    missingInputValue: 0,
                    responseScale: 1,
                    responseOffset: 0,
                    responseLowerClamp: 0,
                    responseUpperClamp: 1,
                    jitter: 0,
                    operation: .replace
                )]
            )
            ),
            maximumOpacity: 1
        )
    }
    #expect(throws: BrushProgramCompilerError.invalidStageCDefinition) {
        _ = try BrushProgramCompiler.compileSensorProgram(
            sensorProgramReplacing(
            .size,
            with: BrushOutputProgramDefinition(
                baseValue: 1,
                terms: [BrushResponseTermDefinition(
                    input: .pressure,
                    response: .linear,
                    inputInverted: false,
                    missingInputValue: 0,
                    responseScale: .nan,
                    responseOffset: 0,
                    responseLowerClamp: 0,
                    responseUpperClamp: 1,
                    jitter: 0,
                    operation: .replace
                )]
            )
            ),
            maximumOpacity: 1
        )
    }
    let cyclicConstant = sensorProgramReplacing(
            .rotation,
            with: BrushOutputProgramDefinition(
                baseValue: 0,
                terms: [BrushResponseTermDefinition(
                    input: .direction,
                    response: .constant(0.5),
                    inputInverted: false,
                    missingInputValue: 0,
                    responseScale: 1,
                    responseOffset: 0,
                    responseLowerClamp: 0,
                    responseUpperClamp: 1,
                    jitter: 0,
                    operation: .replace
                )]
            )
    )
    #expect(throws: BrushProgramCompilerError.invalidStageCDefinition) {
        _ = try BrushProgramCompiler.compileSensorProgram(
            cyclicConstant,
            maximumOpacity: 1
        )
    }
}

@Test
func schemaV2RandomIsTermLocalOutputStableAndDictionaryOrderIndependent()
    throws
{
    let first = BrushResponseTermDefinition(
        input: .random,
        response: .linear,
        inputInverted: false,
        missingInputValue: 0,
        responseScale: 0.5,
        responseOffset: 1,
        responseLowerClamp: 0.5,
        responseUpperClamp: 1.5,
        jitter: 0.1,
        operation: .replace
    )
    let second = BrushResponseTermDefinition(
        input: .random,
        response: .linear,
        inputInverted: false,
        missingInputValue: 0,
        responseScale: 0.25,
        responseOffset: 0.25,
        responseLowerClamp: 0.25,
        responseUpperClamp: 0.5,
        jitter: 0.05,
        operation: .multiply
    )
    let orderedDefinition = BrushOutputProgramDefinition(
        baseValue: 1,
        terms: [first, second]
    )
    let reorderedDefinition = BrushOutputProgramDefinition(
        baseValue: 1,
        terms: [second, first]
    )
    let ordered = sensorProgramReplacing(.size, with: orderedDefinition)
    var withOtherOutput = ordered.outputs
    withOtherOutput[.flow] = BrushOutputProgramDefinition(
        baseValue: 1,
        terms: [second, first]
    )
    let reversedDictionary = BrushSensorProgramDefinition(outputs: Dictionary(
        uniqueKeysWithValues: withOtherOutput.reversed().map { ($0.key, $0.value) }
    ))
    let seed: UInt64 = 0x0123_4567_89ab_cdef
    let context = sensorContext()
    let inputs = referenceInputs(sample: sensorSample(), context: context)
    let expected = referenceOutput(
        output: .size,
        definition: orderedDefinition,
        normalizedInputs: inputs,
        strokeSeed: seed,
        ordinal: context.ordinal,
        maximumOpacity: 1
    )
    let expectedReordered = referenceOutput(
        output: .size,
        definition: reorderedDefinition,
        normalizedInputs: inputs,
        strokeSeed: seed,
        ordinal: context.ordinal,
        maximumOpacity: 1
    )
    let expectedLater = referenceOutput(
        output: .size,
        definition: orderedDefinition,
        normalizedInputs: inputs,
        strokeSeed: seed,
        ordinal: context.ordinal + 1,
        maximumOpacity: 1
    )
    func size(
        _ programDefinition: BrushSensorProgramDefinition,
        ordinal: UInt64 = context.ordinal
    ) throws -> Float {
        let program = try BrushProgramCompiler.compile(schemaV2Definition(
            sensorProgram: programDefinition
        ))
        let dab = BrushDynamicsEngine().evaluate(
            sample: sensorSample(),
            context: sensorContext(ordinal: ordinal),
            program: program,
            random: .centered,
            strokeSeed: seed
        )
        return dab.diameter / context.nominalDiameter
    }

    #expect(!closeSensor(expected, expectedReordered))
    #expect(!closeSensor(expected, expectedLater))
    #expect(closeSensor(try size(ordered), expected))
    #expect(closeSensor(try size(reversedDictionary), expected))
    #expect(closeSensor(
        try size(sensorProgramReplacing(.size, with: reorderedDefinition)),
        expectedReordered
    ))
    #expect(closeSensor(
        try size(ordered, ordinal: context.ordinal + 1),
        expectedLater
    ))
}

private func legacyLinear(
    _ input: BrushDynamicsInput,
    _ output: ClosedRange<Float>
) -> BrushMappingDefinition {
    BrushMappingDefinition(
        input: input,
        response: .linear,
        scale: output.upperBound - output.lowerBound,
        offset: output.lowerBound,
        lowerClamp: output.lowerBound,
        upperClamp: output.upperBound,
        inverted: false,
        jitter: 0,
        missingInputValue: 0.75
    )
}

private func schemaV1Definition(
    base: BrushDefinition,
    dynamics: BrushDynamicsDefinition
) throws -> BrushDefinition {
    try BrushDefinition(
        id: base.id,
        schemaVersion: BrushDefinition.legacySchemaVersion,
        metadata: base.metadata,
        capabilities: base.capabilities,
        resources: base.resources,
        coverage: base.coverage,
        placement: BrushPlacementDefinition(
            baseSpacingFraction: 0.125,
            maximumSpacingFraction: 0.125,
            baseFlow: 1,
            strokeOpacity: 1,
            baseScatterFraction: 0.1,
            baseRotation: 0,
            baseJitterFraction: 0,
            baseOffset: .zero
        ),
        dynamics: dynamics,
        color: base.color,
        material: base.material,
        stabilization: base.stabilization,
        taper: .none,
        replayMode: .appendOnly,
        replayLimits: nil,
        termination: .cap,
        seedPolicy: .perStroke,
        limits: base.limits,
        performanceIntent: base.performanceIntent,
        compatibility: base.compatibility
    )
}

private func sensorSample(
    pressure: Float = 0,
    velocity: Float = 0,
    altitude: Float? = nil,
    azimuth: Float? = nil,
    roll: Float? = nil,
    tangentialPressure: Float? = nil,
    capabilities: StrokeInputCapabilities = []
) -> InterpolatedStrokeSample {
    InterpolatedStrokeSample(
        position: WorldPoint(x: 0, y: 0),
        pressure: pressure,
        timestamp: 0,
        altitude: altitude,
        azimuth: azimuth,
        roll: roll,
        velocity: velocity,
        phase: .moved,
        source: .tablet,
        kind: .actual,
        capabilities: capabilities,
        tangentialPressure: tangentialPressure
    )
}

private func sensorContext(
    nominalDiameter: Float = 20,
    color: InkColor = .black,
    direction: Float = 0,
    strokeAge: Float = 0,
    traveledDistance: Float = 0,
    ordinal: UInt64 = 11
) -> BrushStrokeContext {
    BrushStrokeContext(
        nominalDiameter: nominalDiameter,
        color: color,
        direction: direction,
        strokeAge: strokeAge,
        traveledDistance: traveledDistance,
        ordinal: ordinal,
        isPredicted: false,
        speedReference: 100,
        ageReference: 10,
        distanceReference: 100
    )
}

private func schemaV2Definition(
    sensorProgram: BrushSensorProgramDefinition
) throws -> BrushDefinition {
    let base = nativeTestDefinition()
    return try BrushDefinition(
        v2ID: BrushRecipeID("test.stage-c.ordered"),
        metadata: base.metadata,
        capabilities: base.capabilities,
        resources: base.resources,
        coverage: base.coverage,
        placement: BrushPlacementDefinition(
            baseSpacingFraction: base.placement.baseSpacingFraction,
            maximumSpacingFraction: base.placement.maximumSpacingFraction,
            baseFlow: base.placement.baseFlow,
            strokeOpacity: base.placement.strokeOpacity,
            baseScatterFraction: 0.1,
            baseRotation: base.placement.baseRotation,
            baseJitterFraction: 0,
            baseOffset: .zero
        ),
        dynamics: BrushDynamicsDefinition(
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
            randomization: BrushRandomization(
                spacing: 0,
                scatter: 1,
                rotation: 0,
                grain: 0,
                material: 0
            )
        ),
        color: base.color,
        material: base.material,
        stabilization: base.stabilization,
        taper: .none,
        replayMode: .appendOnly,
        replayLimits: nil,
        termination: .cap,
        seedPolicy: .perStroke,
        limits: base.limits,
        performanceIntent: base.performanceIntent,
        compatibility: base.compatibility,
        sensorNormalization: BrushSensorNormalizationDefinition(
            fullScaleWorldVelocity: 100,
            minimumVelocityDeltaTime: 0.001,
            fullScaleStrokeAge: 10,
            fullScaleStrokeDistanceInDiameters: 5
        ),
        sensorProgram: sensorProgram,
        stabilizationV2: .none,
        direction: BrushDirectionDefinition(
            maximumAngularStep: .pi / 6,
            stationaryDirection: 0
        ),
        emission: BrushEmissionDefinition(mode: .distance, timeInterval: nil),
        tipSupports: [.analyticEllipse]
    )
}

private func sensorProgramReplacing(
    _ output: BrushDynamicOutput,
    with replacement: BrushOutputProgramDefinition
) -> BrushSensorProgramDefinition {
    var outputs: [BrushDynamicOutput: BrushOutputProgramDefinition] = [:]
    for item in BrushDynamicOutput.allCases {
        let base: Float = switch item {
        case .size, .flow, .opacity, .spacing, .hardness, .grain: 1
        case .rotation, .scatter, .offsetX, .offsetY, .hue, .saturation,
             .brightness, .secondaryColorMix: 0
        }
        outputs[item] = BrushOutputProgramDefinition(
            baseValue: base,
            terms: []
        )
    }
    outputs[output] = replacement
    return BrushSensorProgramDefinition(outputs: outputs)
}

private struct ReferenceNormalizedInputs {
    let pressure: Float?
    let speed: Float
    let direction: Float
    let tilt: Float?
    let azimuth: Float?
    let roll: Float?
    let tangentialPressure: Float?
    let age: Float
    let distance: Float

    func value(
        for input: BrushDynamicsInput,
        missing: Float,
        random: Float
    ) -> Float {
        switch input {
        case .pressure: pressure ?? missing
        case .speed: speed
        case .direction: direction
        case .tilt: tilt ?? missing
        case .azimuth: azimuth ?? missing
        case .roll: roll ?? missing
        case .tangentialPressure: tangentialPressure ?? missing
        case .age: age
        case .distance: distance
        case .random: random
        }
    }
}

private func referenceInputs(
    sample: InterpolatedStrokeSample,
    context: BrushStrokeContext
) -> ReferenceNormalizedInputs {
    func unit(_ value: Float) -> Float { min(1, max(0, value)) }
    func angle(_ value: Float) -> Float {
        unit((atan2(sin(value), cos(value)) + .pi) / (2 * .pi))
    }
    return ReferenceNormalizedInputs(
        pressure: sample.capabilities.contains(.pressure)
            ? unit(sample.pressure) : nil,
        speed: unit(sample.velocity / 100),
        direction: angle(context.direction),
        tilt: sample.capabilities.contains(.altitude)
            ? sample.altitude.map { unit(1 - $0 / (.pi / 2)) } : nil,
        azimuth: sample.capabilities.contains(.azimuth)
            ? sample.azimuth.map(angle) : nil,
        roll: sample.capabilities.contains(.roll)
            ? sample.roll.map(angle) : nil,
        tangentialPressure:
            sample.capabilities.contains(.tangentialPressure)
                ? sample.tangentialPressure.map { unit(($0 + 1) * 0.5) }
                : nil,
        age: unit(context.strokeAge / 10),
        distance: unit(
            context.traveledDistance / (context.nominalDiameter * 5)
        )
    )
}

private func referenceOutput(
    output: BrushDynamicOutput,
    definition: BrushOutputProgramDefinition,
    normalizedInputs: ReferenceNormalizedInputs,
    strokeSeed: UInt64,
    ordinal: UInt64,
    maximumOpacity: Float
) -> Float {
    var accumulator = Double(definition.baseValue)
    for (index, term) in definition.terms.enumerated() {
        let random = referenceCounterRandom(
            strokeSeed: strokeSeed,
            ordinal: ordinal,
            outputID: referenceOutputID(output),
            termIndex: UInt64(index)
        )
        var input = normalizedInputs.value(
            for: term.input,
            missing: term.missingInputValue,
            random: random
        )
        if term.inputInverted { input = 1 - input }
        let response = referenceSampledResponse(term.response, at: input)
        let jittered = term.responseOffset
            + term.responseScale * response
            + (random * 2 - 1) * term.jitter
        let bounded = min(
            term.responseUpperClamp,
            max(term.responseLowerClamp, jittered)
        )
        switch term.operation {
        case .replace: accumulator = Double(bounded)
        case .multiply: accumulator *= Double(bounded)
        case .add: accumulator += Double(bounded)
        case .minimum: accumulator = min(accumulator, Double(bounded))
        case .maximum: accumulator = max(accumulator, Double(bounded))
        }
    }
    let value = Float(accumulator)
    switch output {
    case .size, .spacing, .grain:
        return min(8, max(Float(1) / 1_024, value))
    case .flow, .hardness, .scatter:
        return min(8, max(0, value))
    case .opacity:
        return min(maximumOpacity, max(0, value))
    case .secondaryColorMix:
        return min(1, max(0, value))
    case .offsetX, .offsetY:
        return min(8, max(-8, value))
    case .rotation:
        let turn = 2 * Float.pi
        return value - floor((value + .pi) / turn) * turn
    case .hue:
        return value - floor(value)
    case .saturation, .brightness:
        return min(1, max(-1, value))
    }
}

private func referenceSampledResponse(
    _ response: BrushResponseDefinition,
    at input: Float
) -> Float {
    func raw(_ x: Float) -> Float {
        switch response {
        case let .constant(value): value
        case .linear: x
        case let .boundedPower(exponent): pow(x, exponent)
        case let .curve(curve): referenceCurve(curve, at: x)
        }
    }
    let samples = (0..<256).map { raw(Float($0) / 255) }
    let bounded = min(1, max(0, input))
    let scaled = bounded * 255
    let lower = Int(scaled.rounded(.down))
    let upper = min(255, lower + 1)
    let fraction = scaled - Float(lower)
    return samples[lower] + (samples[upper] - samples[lower]) * fraction
}

private func referenceCurve(
    _ curve: BrushCurveDefinition,
    at input: Float
) -> Float {
    if input <= curve.points[0].x { return curve.points[0].y }
    for index in 1..<curve.points.count {
        let upper = curve.points[index]
        guard input <= upper.x else { continue }
        let lower = curve.points[index - 1]
        let fraction = (input - lower.x) / (upper.x - lower.x)
        return lower.y + (upper.y - lower.y) * fraction
    }
    return curve.points[curve.points.count - 1].y
}

private func referenceCounterRandom(
    strokeSeed: UInt64,
    ordinal: UInt64,
    outputID: UInt64,
    termIndex: UInt64
) -> Float {
    var word = strokeSeed
        &+ ordinal &* 0xd2b7_4407_b1ce_6e93
        &+ (outputID &* 4 &+ termIndex) &* 0xca5a_8263_9512_1157
    word = (word ^ (word >> 30)) &* 0xbf58_476d_1ce4_e5b9
    word = (word ^ (word >> 27)) &* 0x94d0_49bb_1331_11eb
    word ^= word >> 31
    return Float(UInt32(truncatingIfNeeded: word >> 40))
        * (1 / Float(1 << 24))
}

private func referenceOutputID(_ output: BrushDynamicOutput) -> UInt64 {
    switch output {
    case .size: 0
    case .flow: 1
    case .opacity: 2
    case .spacing: 3
    case .rotation: 4
    case .scatter: 5
    case .hardness: 6
    case .grain: 7
    case .offsetX: 8
    case .offsetY: 9
    case .hue: 10
    case .saturation: 11
    case .brightness: 12
    case .secondaryColorMix: 13
    }
}

private func closeSensor(
    _ lhs: Float,
    _ rhs: Float,
    tolerance: Float = 0.000_02
) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func referenceApplyingColor(
    _ color: InkColor,
    hue: Float = 0,
    saturation: Float = 0,
    brightness: Float = 0
) -> InkColor {
    let maximum = max(color.red, max(color.green, color.blue))
    let minimum = min(color.red, min(color.green, color.blue))
    let chroma = maximum - minimum
    let sourceHue: Float
    if chroma == 0 {
        sourceHue = 0
    } else if maximum == color.red {
        sourceHue = ((color.green - color.blue) / chroma)
            .truncatingRemainder(dividingBy: 6) / 6
    } else if maximum == color.green {
        sourceHue = ((color.blue - color.red) / chroma + 2) / 6
    } else {
        sourceHue = ((color.red - color.green) / chroma + 4) / 6
    }
    let adjustedHue = sourceHue + hue - floor(sourceHue + hue)
    let adjustedSaturation = maximum == 0
        ? 0 : min(1, max(0, chroma / maximum + saturation))
    let adjustedBrightness = min(1, max(0, maximum + brightness))
    let sector = adjustedHue * 6
    let adjustedChroma = adjustedBrightness * adjustedSaturation
    let x = adjustedChroma
        * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
    let m = adjustedBrightness - adjustedChroma
    let rgb: SIMD3<Float> = switch Int(floor(sector)) {
    case 0: SIMD3(adjustedChroma, x, 0)
    case 1: SIMD3(x, adjustedChroma, 0)
    case 2: SIMD3(0, adjustedChroma, x)
    case 3: SIMD3(0, x, adjustedChroma)
    case 4: SIMD3(x, 0, adjustedChroma)
    default: SIMD3(adjustedChroma, 0, x)
    }
    return InkColor(
        red: rgb.x + m,
        green: rgb.y + m,
        blue: rgb.z + m,
        alpha: color.alpha
    )!
}

private func colorsClose(
    _ lhs: InkColor,
    _ rhs: InkColor,
    tolerance: Float = 0.000_03
) -> Bool {
    closeSensor(lhs.red, rhs.red, tolerance: tolerance)
        && closeSensor(lhs.green, rhs.green, tolerance: tolerance)
        && closeSensor(lhs.blue, rhs.blue, tolerance: tolerance)
        && closeSensor(lhs.alpha, rhs.alpha, tolerance: tolerance)
}
