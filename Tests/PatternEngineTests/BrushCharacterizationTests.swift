import Foundation
import PatternEngine
import Testing

@Test
func characterizationIsStableAndSensitiveToSeed() throws {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 256, height: 256),
        worldCenter: WorldPoint(x: 128, y: 128)
    )
    let first = BrushCharacterizer.record(
        trace: StrokeTraceFixtures.pressureRamp,
        program: nativeTestProgram(),
        nominalDiameter: 20,
        color: .black,
        seed: 41,
        viewport: viewport
    )
    let repeated = BrushCharacterizer.record(
        trace: StrokeTraceFixtures.pressureRamp,
        program: nativeTestProgram(),
        nominalDiameter: 20,
        color: .black,
        seed: 41,
        viewport: viewport
    )
    let changed = BrushCharacterizer.record(
        trace: StrokeTraceFixtures.pressureRamp,
        program: nativeTestProgram(try BrushRecipe(
            id: BrushRecipeID("characterization.random"),
            randomization: BrushRandomization(
                spacing: 0.2,
                scatter: 1,
                rotation: 1,
                grain: 1,
                material: 1
            )
        )),
        nominalDiameter: 20,
        color: .black,
        seed: 42,
        viewport: viewport
    )

    #expect(first == repeated)
    #expect(first.schemaVersion == 1)
    #expect(first.sampleCount == 4)
    #expect(first.logicalDabCount > 0)
    #expect(first.logicalDabDigest.count == 16)
    #expect(first.logicalDabDigest != changed.logicalDabDigest)
}

@Test
func characterizationIgnoresPredictedTailAndUsesReplacementActualSamples() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 256, height: 256),
        worldCenter: WorldPoint(x: 128, y: 128)
    )
    let record = BrushCharacterizer.record(
        trace: StrokeTraceFixtures.predictionCorrection,
        program: nativeTestProgram(),
        nominalDiameter: 20,
        color: .black,
        seed: 41,
        viewport: viewport
    )

    #expect(record.sampleCount == 6)
    #expect(record.logicalDabCount > 0)
}

@Test
func characterizationCompletesTheLongTraceWithStableLogicalOutput() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 256, height: 256),
        worldCenter: WorldPoint(x: 128, y: 128)
    )
    let first = BrushCharacterizer.record(
        trace: StrokeTraceFixtures.long,
        program: nativeTestProgram(),
        nominalDiameter: 20,
        color: .black,
        seed: 41,
        viewport: viewport
    )
    let repeated = BrushCharacterizer.record(
        trace: StrokeTraceFixtures.long,
        program: nativeTestProgram(),
        nominalDiameter: 20,
        color: .black,
        seed: 41,
        viewport: viewport
    )

    #expect(first == repeated)
    #expect(first.logicalDabCount > 0)
}

@Test
func baselineRejectsSchemaMismatchDigestMutationAndOrderMismatch() throws {
    let record = BrushCharacterizationRecord(
        schemaVersion: 1,
        traceName: "trace",
        recipeID: "recipe",
        nominalDiameter: 20,
        seed: 41,
        sampleCount: 4,
        logicalDabCount: 1,
        logicalDabDigest: "0000000000000000"
    )

    #expect(throws: Error.self) {
        _ = try BrushLogicalBaseline(
            validatingSchemaVersion: 2,
            records: [record]
        )
    }

    let baseline = try BrushLogicalBaseline(
        validatingSchemaVersion: 1,
        records: [record]
    )
    var changed = record
    changed = BrushCharacterizationRecord(
        schemaVersion: changed.schemaVersion,
        traceName: changed.traceName,
        recipeID: changed.recipeID,
        nominalDiameter: changed.nominalDiameter,
        seed: changed.seed,
        sampleCount: changed.sampleCount,
        logicalDabCount: changed.logicalDabCount,
        logicalDabDigest: "0000000000000001"
    )
    #expect(throws: Error.self) {
        try baseline.requireMatches([changed])
    }
}

@Test
func decodedBaselineRejectsUnsortedRecords() {
    let data = Data(
        """
        {"schemaVersion":1,"records":[
          {"schemaVersion":1,"traceName":"z","recipeID":"recipe","nominalDiameter":20,"seed":41,"sampleCount":4,"logicalDabCount":1,"logicalDabDigest":"0000000000000000"},
          {"schemaVersion":1,"traceName":"a","recipeID":"recipe","nominalDiameter":20,"seed":41,"sampleCount":4,"logicalDabCount":1,"logicalDabDigest":"0000000000000000"}
        ]}
        """.utf8
    )

    #expect(throws: Error.self) {
        _ = try JSONDecoder().decode(BrushLogicalBaseline.self, from: data)
    }
}

@Test
func sharedDigestPayloadHasAPublicFutureFactoryInitializer() {
    let dab = DabAttributes(
        position: WorldPoint(x: 0, y: 0),
        brushToWorld: .identity,
        radius: 1,
        diameter: 2,
        spacing: 1,
        flow: 1,
        strokeOpacity: 1,
        rotation: 0,
        scatter: .zero,
        hardness: 1,
        grainOffset: .zero,
        grainScale: 1,
        grainRotation: 0,
        color: .black,
        colorAdjustment: .identity,
        materialFamily: .ink,
        materialContribution: 1,
        sourceDistance: 0,
        ordinal: 0,
        isPredicted: false
    )
    let payload = BrushCharacterizationDigestPayload(
        ordinal: 0,
        dab: dab,
        primaryGrainFrame: .identity,
        secondaryGrainFrame: .identity,
        hasPrimaryGrain: false,
        hasSecondaryGrain: false,
        secondaryColorMix: 0,
        accumulationEnabled: false,
        interactionEnabled: false,
        edgeEnabled: false,
        materialStrength: 1,
        materialWetness: 0,
        materialBleedRadius: 0,
        materialSoftenPasses: 0,
        materialAccumulationLimit: 1,
        compatibilityRandom: .centered,
        extensionRandom: .zero,
        worldBoundsMinimum: .zero,
        worldBoundsMaximum: .zero
    )

    #expect(payload.extensionRandom.values == Array(repeating: 0, count: 10))
}

@Test
func legacyPayloadUsesTheFullyEvaluatedGrainFrameFromItsDab() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("characterization.grain-frame"),
        grain: .paper,
        grainTransform: BrushGrainTransform(
            scale: 2,
            rotation: 0,
            offset: SIMD2(10, 20)
        ),
        randomization: BrushRandomization(
            spacing: 0,
            scatter: 0,
            rotation: 0,
            grain: 1,
            material: 0
        )
    )
    let dab = DabAttributes(
        position: WorldPoint(x: 0, y: 0),
        brushToWorld: .identity,
        radius: 1,
        diameter: 2,
        spacing: 1,
        flow: 1,
        strokeOpacity: 1,
        rotation: 0,
        scatter: .zero,
        hardness: 1,
        grainOffset: SIMD2(4, 5),
        grainScale: 3,
        grainRotation: .pi * 0.5,
        color: .black,
        colorAdjustment: .identity,
        materialFamily: .ink,
        materialContribution: 1,
        sourceDistance: 0,
        ordinal: 0,
        isPredicted: false
    )

    let payload = frozenSchemaPayload(
        recipe: recipe,
        dab: dab,
        seed: 1,
        ordinal: 0
    )

    #expect(abs(payload.primaryGrainFrame.xAxis.x) < 0.000_001)
    #expect(payload.primaryGrainFrame.xAxis.y == 3)
    #expect(payload.primaryGrainFrame.yAxis.x == -3)
    #expect(abs(payload.primaryGrainFrame.yAxis.y) < 0.000_001)
    #expect(payload.primaryGrainFrame.translation == SIMD2(4, 5))
}

@Test
func logicalDabFactoryPreservesNativeRandomPayloadWhileDigestBoundsExcludeHalo()
    throws
{
    let recipe = try BrushRecipe(
        id: BrushRecipeID("characterization.logical-dab"),
        grain: .paper,
        material: BrushMaterial(
            family: .boundedWash,
            strength: 0.8,
            wetness: 0.7,
            bleedRadius: 12,
            softenPasses: 2,
            accumulationLimit: 0.75
        ),
        randomization: BrushRandomization(
            spacing: 0.2,
            scatter: 0.3,
            rotation: 0.4,
            grain: 0.5,
            material: 0.6
        )
    )
    let definition = try LegacyBrushRecipeAdapter.definition(
        from: recipe,
        displayName: "Logical"
    )
    let program = try BrushProgramCompiler.compile(definition)
    let sample = InterpolatedStrokeSample(
        position: WorldPoint(x: 20, y: 30),
        pressure: 0.5,
        timestamp: 0,
        altitude: nil,
        azimuth: nil,
        roll: nil,
        velocity: 0,
        artisticVelocity: 0,
        phase: .began,
        source: .mouse,
        kind: .actual,
        capabilities: []
    )
    let dab = BrushDynamicsEngine().evaluate(
        sample: sample,
        context: BrushStrokeContext(
            nominalDiameter: 20,
            color: .black,
            direction: 0,
            strokeAge: 0,
            traveledDistance: 0,
            ordinal: 0,
            isPredicted: false
        ),
        program: program,
        random: BrushRandom(seed: 41).predictedValues(),
        strokeSeed: 41
    )
    let logical = BrushCharacterizationDigestPayload.logicalDab(
        dab,
        definition: definition
    )

    #expect(logical.compatibilityRandom == dab.randomValues.compatibility)
    #expect(logical.extensionRandom.values == [
        dab.randomValues.size,
        dab.randomValues.flow,
        dab.randomValues.opacity,
        dab.randomValues.hardness,
        dab.randomValues.offsetX,
        dab.randomValues.offsetY,
        dab.randomValues.hue,
        dab.randomValues.saturation,
        dab.randomValues.brightness,
        dab.randomValues.secondaryColorMix,
    ])
    #expect(logical.extensionRandom.values.contains { $0 != 0 })
    #expect(dab.worldBounds.minimum.x < logical.worldBoundsMinimum.x)
    #expect(dab.worldBounds.maximum.x > logical.worldBoundsMaximum.x)
    #expect(BrushCharacterizationDigest.digest([logical]).count == 16)
}

@Test
func everyAnchorTraceHasDeterministicNativeCharacterization() throws {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 256, height: 256),
        worldCenter: WorldPoint(x: 128, y: 128)
    )
    let traces = [
        StrokeTraceFixtures.pressureRamp,
        StrokeTraceFixtures.curved,
        StrokeTraceFixtures.predictionCorrection,
    ]
    var comparisonCount = 0

    for fixture in AnchorRecipeFixtures.all {
        let definition = try LegacyBrushRecipeAdapter.definition(
            from: fixture.recipe,
            displayName: fixture.displayName
        )
        let program = try BrushProgramCompiler.compile(definition)

        for trace in traces {
            let first = BrushCharacterizer.record(
                trace: trace,
                program: program,
                nominalDiameter: 20,
                color: .black,
                seed: 41,
                viewport: viewport
            )
            let repeated = BrushCharacterizer.record(
                trace: trace,
                program: program,
                nominalDiameter: 20,
                color: .black,
                seed: 41,
                viewport: viewport
            )

            #expect(first == repeated)
            #expect(first.logicalDabCount > 0)
            #expect(first.logicalDabDigest.count == 16)
            comparisonCount += 1
        }
    }

    #expect(comparisonCount == 15)
}

private func frozenSchemaPayload(
    recipe: BrushRecipe,
    dab: LogicalDab,
    seed: UInt64,
    ordinal: UInt64
) -> BrushCharacterizationDigestPayload {
    let cosine = cos(dab.grainRotation) * dab.grainScale
    let sine = sin(dab.grainRotation) * dab.grainScale
    let primaryGrainFrame = Affine2D(
        xAxis: SIMD2(cosine, sine),
        yAxis: SIMD2(-sine, cosine),
        translation: dab.grainOffset
    )
    let extent = SIMD2(
        abs(dab.brushToWorld.xAxis.x) + abs(dab.brushToWorld.yAxis.x),
        abs(dab.brushToWorld.xAxis.y) + abs(dab.brushToWorld.yAxis.y)
    )
    var random = BrushRandom(seed: seed)
    var compatibilityRandom = BrushRandomValues.centered
    for _ in 0...ordinal {
        compatibilityRandom = random.nextValues()
    }
    return BrushCharacterizationDigestPayload(
        ordinal: ordinal,
        dab: dab,
        primaryGrainFrame: primaryGrainFrame,
        secondaryGrainFrame: .identity,
        hasPrimaryGrain: recipe.grain != .opaque,
        hasSecondaryGrain: false,
        secondaryColorMix: 0,
        accumulationEnabled: recipe.material.accumulationLimit < 1,
        interactionEnabled: recipe.material.wetness > 0,
        edgeEnabled: recipe.material.bleedRadius > 0,
        materialStrength: recipe.material.strength,
        materialWetness: recipe.material.wetness,
        materialBleedRadius: recipe.material.bleedRadius,
        materialSoftenPasses: UInt64(recipe.material.softenPasses),
        materialAccumulationLimit: recipe.material.accumulationLimit,
        compatibilityRandom: compatibilityRandom,
        extensionRandom: .zero,
        worldBoundsMinimum: dab.position.simd - extent,
        worldBoundsMaximum: dab.position.simd + extent
    )
}
