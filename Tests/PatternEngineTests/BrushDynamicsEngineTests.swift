import Foundation
import Testing
@testable import PatternEngine

@Test func pressureCapabilitySelectsMeasuredOrRecipeNeutralPressure() throws {
    let definition = currentDynamicsDefinition(
        id: "test.pressure",
        size: currentMapping(
            input: .pressure,
            output: 0.5...1,
            missingInputValue: 0.8
        ),
        noPressureNeutral: 0.8
    )
    let measured = evaluate(
        sample: sample(pressure: 0.2, capabilities: [.pressure]),
        definition: definition
    )
    let neutral = evaluate(
        sample: sample(pressure: 0.2, capabilities: []),
        definition: definition
    )

    #expect(close(measured.diameter, 12))
    #expect(close(neutral.diameter, 18))
}

@Test func mappingsCanReadSpeedDirectionTiltAzimuthRollAgeAndDistance() throws {
    let probes: [(BrushDynamicsInput, InterpolatedStrokeSample, BrushStrokeContext, Float)] = [
        (.speed, sample(velocity: 50), context(speedReference: 100), 20.01),
        (
            .direction,
            sample(),
            context(direction: .pi / 2),
            34.941174
        ),
        (
            .tilt,
            sample(altitude: 0, capabilities: [.altitude]),
            context(),
            40
        ),
        (
            .azimuth,
            sample(azimuth: .pi / 2, capabilities: [.azimuth]),
            context(),
            34.941174
        ),
        (
            .roll,
            sample(roll: -.pi / 2, capabilities: [.roll]),
            context(),
            25
        ),
        (.age, sample(), context(strokeAge: 5, ageReference: 10), 40),
        (
            .distance,
            sample(),
            context(traveledDistance: 25, distanceReference: 100),
            22.5
        ),
    ]

    for (input, sample, context, expectedDiameter) in probes {
        let response: BrushResponseDefinition = switch input {
        case .direction, .azimuth, .roll:
            cyclicIdentityResponse()
        default:
            .linear
        }
        let definition = currentDynamicsDefinition(
            id: "test.input.\(input)",
            size: currentMapping(
                input: input,
                output: 1...2,
                response: response
            )
        )
        let dab = BrushDynamicsEngine().evaluate(
            sample: sample,
            context: context,
            program: nativeTestProgram(definition),
            random: .centered,
            strokeSeed: 1
        )
        #expect(close(dab.diameter, expectedDiameter))
    }
}

@Test func dynamicsPinsEveryGeneratedDabAttribute() throws {
    let color = try #require(
        InkColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 0.8)
    )
    let definition = currentDynamicsDefinition(
        id: "test.all.outputs",
        size: currentMapping(input: .pressure, output: 0.5...1),
        flow: currentMapping(input: .pressure, output: 0.5...1),
        spacing: currentMapping(input: .pressure, output: 0.5...1),
        rotation: currentMapping(input: .roll, output: -0.2...0.2),
        scatter: currentMapping(input: .pressure, output: 0.5...1),
        hardness: currentMapping(input: .pressure, output: 0.5...1),
        grain: currentMapping(input: .pressure, output: 0.5...1),
        randomization: BrushRandomization(
            spacing: 0.2,
            scatter: 1,
            rotation: 0.4,
            grain: 0.4,
            material: 0.4
        ),
        coverage: BrushCoverageDefinition(
            shapes: [BrushShapeLayerDefinition(
                shape: .chisel,
                combination: .replace,
                scale: 1,
                rotation: 0,
                offset: .zero
            )],
            grains: [BrushGrainLayerDefinition(
                grain: .paper,
                coordinateMode: .canonical,
                transform: BrushGrainTransform(
                    scale: 2,
                    rotation: 0.3,
                    offset: SIMD2(1, -1)
                ),
                grainMovementFraction: 0,
                grainFollowsBrushRotation: false,
                strength: 1
            )],
            baseHardness: 0.8,
            aspectRatio: 0.5,
            tipThreshold: 0,
            antialiasing: true
        ),
        placement: BrushPlacementDefinition(
            baseSpacingFraction: 0.2,
            maximumSpacingFraction: 0.3,
            baseFlow: 0.8,
            strokeOpacity: 0.7,
            baseScatterFraction: 0.1,
            baseRotation: 0.1,
            baseJitterFraction: 0,
            baseOffset: .zero
        ),
        colorAdjustment: BrushColorAdjustment(
            redMultiplier: 0.5,
            greenMultiplier: 1,
            blueMultiplier: 0.25,
            alphaMultiplier: 0.5
        ),
        material: BrushMaterialDefinition(
            accumulation: .flow,
            interaction: .none,
            edgeTreatment: .dryBreakup,
            strength: 0.6,
            wetness: 0,
            bleedRadius: 0,
            softenPasses: 0,
            accumulationLimit: 1,
            interactionParameters: nil
        )
    )
    let dab = BrushDynamicsEngine().evaluate(
        sample: sample(
            position: WorldPoint(x: 10, y: 20),
            pressure: 0.5,
            altitude: .pi / 4,
            azimuth: .pi / 2,
            roll: -.pi / 2,
            velocity: 50,
            capabilities: [.pressure, .altitude, .azimuth, .roll]
        ),
        context: context(
            color: color,
            direction: 0,
            strokeAge: 2,
            traveledDistance: 10,
            ordinal: 7,
            isPredicted: true
        ),
        program: nativeTestProgram(definition),
        random: BrushRandomValues(
            spacing: 0.75,
            scatterX: 0.75,
            scatterY: 0.25,
            rotation: 0.75,
            grainX: 0.75,
            grainY: 0.25,
            materialVariation: 0.75
        ),
        strokeSeed: 1
    )

    #expect(close(dab.diameter, 15))
    #expect(close(dab.radius, 7.5))
    #expect(close(dab.spacing, 2.6715183))
    #expect(close(dab.flow, 0.6))
    #expect(close(dab.strokeOpacity, 0.7))
    #expect(close(dab.rotation, 0.2))
    #expect(close(dab.scatter.x, 0.75))
    #expect(close(dab.scatter.y, -0.75))
    #expect(close(dab.hardness, 0.6))
    #expect(close(dab.grainScale, 1.5))
    #expect(close(dab.grainOffset.x, 1.2))
    #expect(close(dab.grainOffset.y, -1.2))
    #expect(close(dab.grainRotation, 0.3))
    #expect(dab.color == InkColor(red: 0.2, green: 0.5, blue: 0.15, alpha: 0.4))
    #expect(
        dab.colorAdjustment
            == definition.components[0].color.baseAdjustment
    )
    #expect(close(dab.materialContribution, 0.72))
    #expect(dab.materialFamily == .dry)
    #expect(close(dab.sourceDistance, 10))
    #expect(dab.ordinal == 7)
    #expect(dab.isPredicted)
    #expect(close(dab.position.x, 10.75))
    #expect(close(dab.position.y, 19.25))
    #expect(close(dab.brushToWorld.translation.x, 10.75))
    #expect(close(dab.brushToWorld.translation.y, 19.25))
    #expect(close(dab.brushToWorld.xAxis.x, cos(0.2) * 7.5))
    #expect(close(dab.brushToWorld.xAxis.y, sin(0.2) * 7.5))
    #expect(close(dab.brushToWorld.yAxis.x, -sin(0.2) * 3.75))
    #expect(close(dab.brushToWorld.yAxis.y, cos(0.2) * 3.75))
}

@Test func currentHardRoundDefinitionProducesExpectedBaseDab() throws {
    let color = try #require(
        InkColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)
    )
    let dab = evaluate(
        sample: sample(
            position: WorldPoint(x: 12, y: -3),
            pressure: 0.5,
            capabilities: []
        ),
        context: context(
            color: color,
            traveledDistance: 40,
            ordinal: 9
        ),
        definition: nativeTestDefinition(),
        random: BrushRandomValues(
            spacing: 0.99,
            scatterX: 0.01,
            scatterY: 0.9,
            rotation: 0.8,
            grainX: 0.4,
            grainY: 0.7,
            materialVariation: 0.2
        )
    )

    #expect(dab.position == WorldPoint(x: 12, y: -3))
    #expect(dab.diameter == 20)
    #expect(dab.radius == 10)
    #expect(dab.spacing == 2.5)
    #expect(dab.flow == 1)
    #expect(dab.strokeOpacity == 1)
    #expect(dab.hardness == 1)
    #expect(dab.rotation == 0)
    #expect(dab.scatter == .zero)
    #expect(dab.color == color)
    #expect(dab.brushToWorld == Affine2D(
        xAxis: SIMD2(10, 0),
        yAxis: SIMD2(0, 10),
        translation: SIMD2(12, -3)
    ))
    #expect(dab.sourceDistance == 40)
    #expect(dab.ordinal == 9)
    #expect(!dab.isPredicted)
}

@Test func currentHardRoundSpacingMatchesDiameterFormulaAcrossSizes() {
    for diameter: Float in [4, 20, 100] {
        let dab = evaluate(
            context: context(nominalDiameter: diameter),
            definition: nativeTestDefinition()
        )
        let expectedRadius = diameter * 0.5
        let expectedSpacing = max(1, diameter * 0.125)

        #expect(dab.radius == expectedRadius)
        #expect(dab.spacing == expectedSpacing)
    }
}

private func cyclicIdentityResponse() -> BrushResponseDefinition {
    .curve(BrushCurveDefinition(points: [
        BrushCurvePoint(x: 0, y: 0),
        BrushCurvePoint(x: 0.25, y: 0.25),
        BrushCurvePoint(x: 0.75, y: 0.75),
        BrushCurvePoint(x: 1, y: 0),
    ]))
}

private func currentMapping(
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

private func currentDynamicsDefinition(
    id: String,
    size: BrushMappingDefinition? = nil,
    flow: BrushMappingDefinition? = nil,
    spacing: BrushMappingDefinition? = nil,
    rotation: BrushMappingDefinition? = nil,
    scatter: BrushMappingDefinition? = nil,
    hardness: BrushMappingDefinition? = nil,
    grain: BrushMappingDefinition? = nil,
    noPressureNeutral: Float = 1,
    randomization: BrushRandomization = .none,
    coverage: BrushCoverageDefinition? = nil,
    placement: BrushPlacementDefinition? = nil,
    colorAdjustment: BrushColorAdjustment = .identity,
    material: BrushMaterialDefinition? = nil
) -> BrushDefinition {
    let base = nativeTestDefinition()
    let dynamics = BrushDynamicsDefinition(
        size: size ?? base.components[0].dynamics.size,
        flow: flow ?? base.components[0].dynamics.flow,
        opacity: base.components[0].dynamics.opacity,
        spacing: spacing ?? base.components[0].dynamics.spacing,
        rotation: rotation ?? base.components[0].dynamics.rotation,
        scatter: scatter ?? base.components[0].dynamics.scatter,
        hardness: hardness ?? base.components[0].dynamics.hardness,
        grain: grain ?? base.components[0].dynamics.grain,
        offsetX: base.components[0].dynamics.offsetX,
        offsetY: base.components[0].dynamics.offsetY,
        hue: base.components[0].dynamics.hue,
        saturation: base.components[0].dynamics.saturation,
        brightness: base.components[0].dynamics.brightness,
        secondaryColorMix: base.components[0].dynamics.secondaryColorMix,
        noPressureNeutral: noPressureNeutral,
        randomization: randomization
    )
    let color = BrushColorBehaviorDefinition(
        baseAdjustment: colorAdjustment,
        perStampJitter: base.components[0].color.perStampJitter,
        perStrokeJitter: base.components[0].color.perStrokeJitter
    )
    return nativeTestDefinition(
        id: BrushRecipeID(id),
        coverage: coverage,
        placement: placement,
        dynamics: dynamics,
        color: color,
        material: material
    )
}

private func evaluate(
    sample: InterpolatedStrokeSample = sample(),
    context: BrushStrokeContext = context(),
    definition: BrushDefinition,
    random: BrushRandomValues = .centered
) -> DabAttributes {
    BrushDynamicsEngine().evaluate(
        sample: sample,
        context: context,
        program: nativeTestProgram(definition),
        random: random,
        strokeSeed: 1
    )
}

private func sample(
    position: WorldPoint = WorldPoint(x: 0, y: 0),
    pressure: Float = 1,
    altitude: Float? = nil,
    azimuth: Float? = nil,
    roll: Float? = nil,
    velocity: Float = 0,
    artisticVelocity: Float? = nil,
    capabilities: StrokeInputCapabilities = []
) -> InterpolatedStrokeSample {
    InterpolatedStrokeSample(
        position: position,
        pressure: pressure,
        timestamp: 0,
        altitude: altitude,
        azimuth: azimuth,
        roll: roll,
        velocity: velocity,
        artisticVelocity: artisticVelocity ?? velocity,
        phase: .moved,
        source: .tablet,
        kind: .actual,
        capabilities: capabilities
    )
}

private func context(
    nominalDiameter: Float = 20,
    color: InkColor = .black,
    direction: Float = 0,
    strokeAge: Float = 0,
    traveledDistance: Float = 0,
    totalDistance: Float? = nil,
    ordinal: UInt64 = 0,
    isPredicted: Bool = false,
    speedReference: Float = 100,
    ageReference: Float = 10,
    distanceReference: Float = 100
) -> BrushStrokeContext {
    BrushStrokeContext(
        nominalDiameter: nominalDiameter,
        color: color,
        direction: direction,
        strokeAge: strokeAge,
        traveledDistance: traveledDistance,
        totalDistance: totalDistance,
        ordinal: ordinal,
        isPredicted: isPredicted,
        speedReference: speedReference,
        ageReference: ageReference,
        distanceReference: distanceReference
    )
}

private func close(
    _ lhs: Float,
    _ rhs: Float,
    tolerance: Float = 0.000_01
) -> Bool {
    abs(lhs - rhs) <= tolerance
}
