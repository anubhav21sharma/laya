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
        recipe: .legacyEquivalent,
        nominalDiameter: 20,
        color: .black,
        seed: 41,
        viewport: viewport
    )
    let repeated = BrushCharacterizer.record(
        trace: StrokeTraceFixtures.pressureRamp,
        recipe: .legacyEquivalent,
        nominalDiameter: 20,
        color: .black,
        seed: 41,
        viewport: viewport
    )
    let changed = BrushCharacterizer.record(
        trace: StrokeTraceFixtures.pressureRamp,
        recipe: try BrushRecipe(
            id: BrushRecipeID("characterization.random"),
            randomization: BrushRandomization(
                spacing: 0.2,
                scatter: 1,
                rotation: 1,
                grain: 1,
                material: 1
            )
        ),
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
        recipe: .legacyEquivalent,
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
        recipe: .legacyEquivalent,
        nominalDiameter: 20,
        color: .black,
        seed: 41,
        viewport: viewport
    )
    let repeated = BrushCharacterizer.record(
        trace: StrokeTraceFixtures.long,
        recipe: .legacyEquivalent,
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

    let payload = BrushCharacterizationDigestPayload.legacy(
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
func logicalDabFactoryPreservesFrozenLegacyPayloadWhileRuntimeBoundsUseHalo()
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
    let legacy = BrushCharacterizationDigestPayload.legacy(
        recipe: recipe,
        dab: dab,
        seed: 41,
        ordinal: 0
    )
    let logical = BrushCharacterizationDigestPayload.logicalDab(
        dab,
        compatibilityRecipe: recipe
    )

    #expect(logical == legacy)
    #expect(dab.worldBounds.minimum.x < logical.worldBoundsMinimum.x)
    #expect(dab.worldBounds.maximum.x > logical.worldBoundsMaximum.x)
    #expect(BrushCharacterizationDigest.digest([logical])
        == BrushCharacterizationDigest.digest([legacy]))
}

@Test
func everyAnchorTracePreservesLegacyPayloadsAndDigests() throws {
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
            var input = BrushInputDeriver()
            var generator = BrushStrokeGenerator(
                program: program,
                nominalDiameter: 20,
                color: .black,
                seed: 41
            )
            var dabs: [LogicalDab] = []

            for sample in trace.samples where sample.kind != .predicted {
                let worldSample = input.derive(sample, viewport: viewport)
                switch worldSample.phase {
                case .began:
                    dabs.append(contentsOf: generator.beginBatches(worldSample)
                        .flatMap(\.dabs))
                case .moved:
                    dabs.append(contentsOf: generator.appendBatches(worldSample)
                        .flatMap(\.dabs))
                case .ended:
                    dabs.append(contentsOf: generator.finishBatches(worldSample)
                        .flatMap(\.dabs))
                case .cancelled:
                    generator.cancel()
                }
            }

            let legacy = dabs.map {
                BrushCharacterizationDigestPayload.legacy(
                    recipe: fixture.recipe,
                    dab: $0,
                    seed: 41,
                    ordinal: $0.ordinal
                )
            }
            let logical = dabs.map {
                BrushCharacterizationDigestPayload.logicalDab(
                    $0,
                    compatibilityRecipe: fixture.recipe
                )
            }

            #expect(logical == legacy)
            #expect(
                BrushCharacterizationDigest.digest(logical)
                    == BrushCharacterizationDigest.digest(legacy)
            )
            comparisonCount += 1
        }
    }

    #expect(comparisonCount == 15)
}
