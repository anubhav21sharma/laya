import Foundation
import Testing
@testable import PatternEngine

@Test func pressureCapabilitySelectsMeasuredOrRecipeNeutralPressure() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.pressure"),
        sizeMapping: .linear(input: .pressure, output: 0.5...1),
        noPressureNeutral: 0.8
    )
    let measured = evaluate(
        sample: sample(pressure: 0.2, capabilities: [.pressure]),
        recipe: recipe
    )
    let neutral = evaluate(
        sample: sample(pressure: 0.2, capabilities: []),
        recipe: recipe
    )

    #expect(close(measured.diameter, 12))
    #expect(close(neutral.diameter, 18))
}

@Test func mappingsCanReadSpeedDirectionTiltAzimuthRollAgeAndDistance() throws {
    let probes: [(BrushDynamicsInput, InterpolatedStrokeSample, BrushStrokeContext, Float)] = [
        (.speed, sample(velocity: 50), context(speedReference: 100), 30),
        (.direction, sample(), context(direction: .pi / 2), 35),
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
            35
        ),
        (
            .roll,
            sample(roll: -.pi / 2, capabilities: [.roll]),
            context(),
            25
        ),
        (.age, sample(), context(strokeAge: 5, ageReference: 10), 30),
        (
            .distance,
            sample(),
            context(traveledDistance: 25, distanceReference: 100),
            25
        ),
    ]

    for (input, sample, context, expectedDiameter) in probes {
        let recipe = try BrushRecipe(
            id: BrushRecipeID("test.input.\(input)"),
            sizeMapping: .linear(input: input, output: 1...2)
        )
        let dab = BrushDynamicsEngine().evaluate(
            sample: sample,
            context: context,
            recipe: recipe,
            random: .centered
        )
        #expect(close(dab.diameter, expectedDiameter))
    }
}

@Test func dynamicsPinsEveryGeneratedDabAttribute() throws {
    let color = try #require(
        InkColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 0.8)
    )
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.all.outputs"),
        shape: .chisel,
        grain: .paper,
        grainTransform: BrushGrainTransform(
            scale: 2,
            rotation: 0.3,
            offset: SIMD2(1, -1)
        ),
        material: BrushMaterial(
            family: .dry,
            strength: 0.6,
            wetness: 0,
            bleedRadius: 0,
            softenPasses: 0,
            accumulationLimit: 1
        ),
        baseSpacingFraction: 0.2,
        maximumSpacingFraction: 0.3,
        baseFlow: 0.8,
        strokeOpacity: 0.7,
        baseHardness: 0.8,
        baseScatterFraction: 0.1,
        baseRotation: 0.1,
        aspectRatio: 0.5,
        sizeMapping: .linear(input: .pressure, output: 0.5...1),
        flowMapping: .linear(input: .pressure, output: 0.5...1),
        spacingMapping: .linear(input: .pressure, output: 0.5...1),
        rotationMapping: .linear(input: .roll, output: -0.2...0.2),
        scatterMapping: .linear(input: .pressure, output: 0.5...1),
        hardnessMapping: .linear(input: .pressure, output: 0.5...1),
        grainMapping: .linear(input: .pressure, output: 0.5...1),
        randomization: BrushRandomization(
            spacing: 0.2,
            scatter: 1,
            rotation: 0.4,
            grain: 0.4,
            material: 0.4
        ),
        colorAdjustment: BrushColorAdjustment(
            redMultiplier: 0.5,
            greenMultiplier: 1,
            blueMultiplier: 0.25,
            alphaMultiplier: 0.5
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
        recipe: recipe,
        random: BrushRandomValues(
            spacing: 0.75,
            scatterX: 0.75,
            scatterY: 0.25,
            rotation: 0.75,
            grainX: 0.75,
            grainY: 0.25,
            materialVariation: 0.75
        )
    )

    #expect(close(dab.diameter, 15))
    #expect(close(dab.radius, 7.5))
    #expect(close(dab.spacing, 2.475))
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
    #expect(dab.colorAdjustment == recipe.colorAdjustment)
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

@Test func boundedPowerResponseAndTaperRemainFinite() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.power.taper"),
        sizeMapping: .boundedPower(
            input: .pressure,
            output: 0.25...1,
            exponent: 2
        ),
        taper: BrushTaperConfiguration(
            start: .worldPixels(20),
            end: .diameterMultiples(1),
            minimumSize: 0.2,
            minimumFlow: 0.3,
            effects: [.size, .flow]
        ),
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    let dab = evaluate(
        sample: sample(pressure: 0.5, capabilities: [.pressure]),
        context: context(
            traveledDistance: 5,
            totalDistance: 15
        ),
        recipe: recipe
    )

    // Pressure factor 0.4375, then the minimum 25% taper envelope.
    #expect(close(dab.diameter, 3.5))
    #expect(close(dab.flow, 0.475))
    #expect(dab.diameter.isFinite)
    #expect(dab.spacing.isFinite)
}

@Test func endTaperRenormalizesAtRetainedReplayBoundaryAfterCapTruncation() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.taper.retained-boundary"),
        taper: BrushTaperConfiguration(
            start: .disabled,
            end: .worldPixels(100),
            minimumSize: 0.2,
            minimumFlow: 0.25,
            effects: [.size, .flow]
        ),
        replayMode: .replayTail,
        replayLimits: BrushReplayLimits(
            maximumSamples: 3,
            maximumDabs: 3,
            maximumProjectedInstances: 3
        )
    )
    let dynamics = BrushDynamicsEngine()
    var buffer = TransientStrokeBuffer(replayContract: recipe.replayContract)
    var lastUpdate = TransientStrokeBufferUpdate.noChange
    for (index, sourceDistance) in [Float(40), 60, 80, 100].enumerated() {
        let attributes = evaluate(
            context: context(traveledDistance: sourceDistance),
            recipe: recipe
        )
        let input = StrokeSample(
            position: ScreenPoint(x: sourceDistance, y: 0),
            pressure: 1,
            timestamp: TimeInterval(index),
            phase: index == 0 ? .began : .moved,
            source: .mouse
        )
        lastUpdate = buffer.appendActual(
            TransientStrokeChunk(
                sample: WorldStrokeSample(
                    sample: input,
                    position: WorldPoint(x: sourceDistance, y: 0),
                    velocity: 0
                ),
                dabs: [
                    TransientStrokeDab(
                        attributes: attributes,
                        projectedInstanceCount: 1
                    ),
                ]
            )
        )
    }
    let retained = buffer.actualDabs.map(\.attributes)

    #expect(
        lastUpdate.settledPrefix.first?.dabs.first?.attributes.sourceDistance
            == 40
    )
    #expect(retained.map(\.sourceDistance) == [60, 80, 100])

    let tapered = retained.map {
        dynamics.applyingKnownTotalDistance(
            $0,
            totalDistance: 100,
            nominalDiameter: 20,
            recipe: recipe,
            retainedReplayStartDistance: retained.first?.sourceDistance
        )
    }

    #expect(close(tapered[0].diameter, 20))
    #expect(close(tapered[1].diameter, 12))
    #expect(close(tapered[2].diameter, 4))
    #expect(close(tapered[0].flow, 1))
    #expect(close(tapered[1].flow, 0.625))
    #expect(close(tapered[2].flow, 0.25))
}

@Test func legacyEquivalentRecipeMatchesRecoveredHardRoundBehavior() throws {
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
        recipe: .legacyEquivalent,
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

@Test func legacyEquivalentSpacingMatchesRecoveredFormulaAcrossSizes() {
    for diameter: Float in [4, 20, 100] {
        let dab = evaluate(
            context: context(nominalDiameter: diameter),
            recipe: .legacyEquivalent
        )
        let expectedRadius = diameter * 0.5
        let expectedSpacing = max(1, min(8, expectedRadius * 0.25))

        #expect(dab.radius == expectedRadius)
        #expect(dab.spacing == expectedSpacing)
    }
}

private func evaluate(
    sample: InterpolatedStrokeSample = sample(),
    context: BrushStrokeContext = context(),
    recipe: BrushRecipe,
    random: BrushRandomValues = .centered
) -> DabAttributes {
    BrushDynamicsEngine().evaluate(
        sample: sample,
        context: context,
        recipe: recipe,
        random: random
    )
}

private func sample(
    position: WorldPoint = WorldPoint(x: 0, y: 0),
    pressure: Float = 1,
    altitude: Float? = nil,
    azimuth: Float? = nil,
    roll: Float? = nil,
    velocity: Float = 0,
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
