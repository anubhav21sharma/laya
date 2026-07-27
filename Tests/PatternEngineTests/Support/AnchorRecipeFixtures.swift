@testable import PatternEngine

struct AnchorRecipeFixture: Sendable {
    let displayName: String
    let recipe: BrushRecipe
}

enum AnchorRecipeFixtures {
    static let all: [AnchorRecipeFixture] = [
        AnchorRecipeFixture(displayName: "Technical Ink", recipe: make {
            try BrushRecipe(
                id: BrushRecipeID("builtin.technical-ink"),
                baseSpacingFraction: 0.08,
                maximumSpacingFraction: 0.15,
                sizeMapping: .boundedPower(input: .pressure, output: 0.3...1, exponent: 0.75)
            )
        }),
        AnchorRecipeFixture(displayName: "Dry Pencil", recipe: make {
            try BrushRecipe(
                id: BrushRecipeID("builtin.dry-pencil"),
                grain: .paper,
                grainTransform: BrushGrainTransform(scale: 1.5, rotation: 0, offset: .zero),
                material: BrushMaterial(family: .dry, strength: 0.85, wetness: 0, bleedRadius: 0, softenPasses: 0, accumulationLimit: 1),
                baseSpacingFraction: 0.1, maximumSpacingFraction: 0.2, baseFlow: 0.7, strokeOpacity: 0.9, baseHardness: 0.75, baseScatterFraction: 0.03, aspectRatio: 0.7,
                sizeMapping: .boundedPower(input: .pressure, output: 0.3...1, exponent: 1.25),
                flowMapping: .linear(input: .pressure, output: 0.35...1),
                rotationMapping: .linear(input: .direction, output: -Float.pi...Float.pi),
                scatterMapping: .linear(input: .pressure, output: 0.5...1),
                randomization: BrushRandomization(spacing: 0.1, scatter: 1, rotation: 0, grain: 0.35, material: 0.15)
            )
        }),
        AnchorRecipeFixture(displayName: "Glaze Marker", recipe: make {
            try BrushRecipe(
                id: BrushRecipeID("builtin.glaze-marker"), shape: .chisel,
                material: BrushMaterial(family: .glaze, strength: 0.8, wetness: 0.2, bleedRadius: 0, softenPasses: 0, accumulationLimit: 0.85),
                baseSpacingFraction: 0.16, maximumSpacingFraction: 0.3, baseFlow: 0.35, strokeOpacity: 0.75, baseHardness: 0.7, aspectRatio: 0.7,
                sizeMapping: .linear(input: .pressure, output: 0.6...1),
                flowMapping: .linear(input: .pressure, output: 0.5...1),
                rotationMapping: .linear(input: .direction, output: -Float.pi...Float.pi)
            )
        }),
        AnchorRecipeFixture(displayName: "Bounded Wash", recipe: make {
            try BrushRecipe(
                id: BrushRecipeID("builtin.bounded-wash"), shape: .softRound, grain: .paper,
                grainTransform: BrushGrainTransform(scale: 1.2, rotation: 0, offset: .zero),
                material: BrushMaterial(family: .boundedWash, strength: 1, wetness: 0.8, bleedRadius: 12, softenPasses: 2, accumulationLimit: 0.75),
                baseSpacingFraction: 0.15, maximumSpacingFraction: 0.3, baseFlow: 0.85, strokeOpacity: 0.85, baseHardness: 0.2,
                sizeMapping: .linear(input: .pressure, output: 0.6...1), flowMapping: .linear(input: .pressure, output: 0.5...1),
                randomization: BrushRandomization(spacing: 0.05, scatter: 0, rotation: 0, grain: 0.2, material: 0.1),
                replayMode: .boundedWholeStroke,
                replayLimits: BrushReplayLimits(maximumSamples: 4_096, maximumDabs: 4_096, maximumProjectedInstances: 4_096)
            )
        }),
        AnchorRecipeFixture(displayName: "Hard Round Eraser", recipe: make {
            try BrushRecipe(id: BrushRecipeID("builtin.hard-round-eraser"))
        }),
    ]

    private static func make(_ operation: () throws -> BrushRecipe) -> BrushRecipe {
        do { return try operation() }
        catch { preconditionFailure("Invalid anchor fixture: \(error)") }
    }
}
