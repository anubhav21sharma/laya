import Testing
@testable import PatternEngine

@Test func recipeValidationAcceptsACompleteBoundedRecipe() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.complete"),
        schemaVersion: 4,
        shape: .chisel,
        grain: .paper,
        grainCoordinateMode: .canonical,
        grainTransform: BrushGrainTransform(
            scale: 2,
            rotation: 0.25,
            offset: SIMD2(3, -2)
        ),
        material: BrushMaterial(
            family: .dry,
            strength: 0.75,
            wetness: 0,
            bleedRadius: 0,
            softenPasses: 0,
            accumulationLimit: 1
        ),
        baseSpacingFraction: 0.15,
        maximumSpacingFraction: 0.25,
        baseFlow: 0.8,
        strokeOpacity: 0.9,
        baseHardness: 0.6,
        baseScatterFraction: 0.05,
        baseRotation: 0.2,
        aspectRatio: 0.5,
        sizeMapping: .boundedPower(
            input: .pressure,
            output: 0.25...1,
            exponent: 1.5
        ),
        replayMode: .replayTail,
        replayLimits: BrushReplayLimits(
            maximumSamples: 128,
            maximumDabs: 1_024,
            maximumProjectedInstances: 2_048
        )
    )

    #expect(recipe.id == BrushRecipeID("test.complete"))
    #expect(recipe.schemaVersion == 4)
    #expect(recipe == recipe)
}

@Test func recipeValidationRejectsNonfiniteAndOutOfRangeValues() {
    expectRecipeError(.nonfinite(field: "baseSpacingFraction")) {
        try BrushRecipe(
            id: BrushRecipeID("test.nan"),
            baseSpacingFraction: .nan
        )
    }
    expectRecipeError(.outOfRange(field: "baseFlow")) {
        try BrushRecipe(
            id: BrushRecipeID("test.flow"),
            baseFlow: 1.01
        )
    }
    expectRecipeError(.outOfRange(field: "strokeOpacity")) {
        try BrushRecipe(
            id: BrushRecipeID("test.opacity"),
            strokeOpacity: -0.01
        )
    }
    expectRecipeError(.invalidMapping(field: "sizeMapping")) {
        try BrushRecipe(
            id: BrushRecipeID("test.mapping.nan"),
            sizeMapping: BrushMapping(
                response: .linear,
                input: .pressure,
                outputMinimum: .nan,
                outputMaximum: 1,
                exponent: 1
            )
        )
    }
    expectRecipeError(.invalidMapping(field: "sizeMapping")) {
        try BrushRecipe(
            id: BrushRecipeID("test.mapping.range"),
            sizeMapping: .linear(input: .pressure, output: 0.5...9)
        )
    }
}

@Test func recipeValidationRejectsUnsupportedAssets() {
    expectRecipeError(.unsupportedAsset("external.shape.custom")) {
        try BrushRecipe(
            id: BrushRecipeID("test.shape.asset"),
            shape: .asset("external.shape.custom")
        )
    }
    expectRecipeError(.unsupportedAsset("external.grain.custom")) {
        try BrushRecipe(
            id: BrushRecipeID("test.grain.asset"),
            grain: .asset("external.grain.custom")
        )
    }
}

@Test func recipeValidationRejectsUnboundedOrExcessiveReplay() {
    expectRecipeError(.unboundedReplay) {
        try BrushRecipe(
            id: BrushRecipeID("test.unbounded"),
            replayMode: .replayTail
        )
    }
    expectRecipeError(.replayLimitExceeded(field: "maximumDabs")) {
        try BrushRecipe(
            id: BrushRecipeID("test.replay.cap"),
            replayMode: .replayTail,
            replayLimits: BrushReplayLimits(
                maximumSamples: 256,
                maximumDabs: 2_049,
                maximumProjectedInstances: 4_096
            )
        )
    }
    expectRecipeError(.replayLimitExceeded(field: "maximumSamples")) {
        try BrushRecipe(
            id: BrushRecipeID("test.whole.cap"),
            replayMode: .boundedWholeStroke,
            replayLimits: BrushReplayLimits(
                maximumSamples: 4_097,
                maximumDabs: 4_096,
                maximumProjectedInstances: 4_096
            )
        )
    }
}

@Test func recipeValidationRejectsImplicitEndTaperReplay() {
    expectRecipeError(.endTaperRequiresReplay) {
        try BrushRecipe(
            id: BrushRecipeID("test.taper.requires-replay"),
            taper: BrushTaperConfiguration(
                start: .disabled,
                end: .worldPixels(12),
                minimumSize: 0.2,
                minimumFlow: 0.2,
                effects: [.size, .flow]
            )
        )
    }
}

@Test func recipeValidationRejectsReplayLimitsForAppendOnlyMode() {
    expectRecipeError(.replayLimitsRequireReplayMode) {
        try BrushRecipe(
            id: BrushRecipeID("test.append-only.limits"),
            replayLimits: BrushReplayLimits(
                maximumSamples: 8,
                maximumDabs: 16,
                maximumProjectedInstances: 32
            )
        )
    }
}

@Test func recipeExposesItsValidatedDeclaredReplayContract() throws {
    let limits = BrushReplayLimits(
        maximumSamples: 7,
        maximumDabs: 11,
        maximumProjectedInstances: 13
    )
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.replay.contract"),
        replayMode: .replayTail,
        replayLimits: limits
    )

    #expect(recipe.replayContract.mode == .replayTail)
    #expect(recipe.replayContract.limits == limits)
}

@Test func recipeValidationRejectsExcessiveWashWork() {
    expectRecipeError(.washLimitExceeded(field: "bleedRadius")) {
        try BrushRecipe(
            id: BrushRecipeID("test.wash.bleed"),
            material: BrushMaterial(
                family: .boundedWash,
                strength: 1,
                wetness: 1,
                bleedRadius: 33,
                softenPasses: 2,
                accumulationLimit: 1
            )
        )
    }
    expectRecipeError(.washLimitExceeded(field: "softenPasses")) {
        try BrushRecipe(
            id: BrushRecipeID("test.wash.passes"),
            material: BrushMaterial(
                family: .boundedWash,
                strength: 1,
                wetness: 1,
                bleedRadius: 32,
                softenPasses: 3,
                accumulationLimit: 1
            )
        )
    }
}

@Test func legacyEquivalentRecipeIsStableAndBounded() {
    let recipe = BrushRecipe.legacyEquivalent

    #expect(recipe.id == BrushRecipeID("builtin.legacy-hard-round"))
    #expect(recipe.schemaVersion == 1)
    #expect(recipe.shape == .hardRound)
    #expect(recipe.grain == .opaque)
    #expect(recipe.material.family == .ink)
    #expect(recipe.baseSpacingFraction == 0.125)
    #expect(recipe.maximumSpacingFraction == 0.125)
    #expect(recipe.noPressureNeutral == 1)
    #expect(recipe.replayMode == .appendOnly)
}

private func expectRecipeError(
    _ expected: BrushRecipeValidationError,
    operation: () throws -> BrushRecipe
) {
    do {
        _ = try operation()
        Issue.record("Expected BrushRecipe validation to fail")
    } catch let error as BrushRecipeValidationError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
