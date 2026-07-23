import PatternEngine

public enum AnchorBrushRole: UInt8, Equatable, Sendable {
    case draw
    case erase
}

public struct AnchorBrushEntry: Equatable, Sendable {
    public let displayName: String
    public let role: AnchorBrushRole
    public let recipe: BrushRecipe

    public init(
        displayName: String,
        role: AnchorBrushRole,
        recipe: BrushRecipe
    ) {
        self.displayName = displayName
        self.role = role
        self.recipe = recipe
    }

    public var id: BrushRecipeID { recipe.id }
}

/// Slice 4 acceptance fixtures, not a user-editable brush library.
public enum AnchorBrushCatalog {
    public static let technicalInk = AnchorBrushEntry(
        displayName: "Technical Ink",
        role: .draw,
        recipe: builtIn {
            try BrushRecipe(
                id: BrushRecipeID("builtin.technical-ink"),
                shape: .hardRound,
                grain: .opaque,
                material: .ink,
                baseSpacingFraction: 0.08,
                maximumSpacingFraction: 0.15,
                sizeMapping: .boundedPower(
                    input: .pressure,
                    output: 0.3...1,
                    exponent: 0.75
                )
            )
        }
    )

    public static let dryPencil = AnchorBrushEntry(
        displayName: "Dry Pencil",
        role: .draw,
        recipe: builtIn {
            try BrushRecipe(
                id: BrushRecipeID("builtin.dry-pencil"),
                shape: .hardRound,
                grain: .paper,
                grainCoordinateMode: .canonical,
                grainTransform: BrushGrainTransform(
                    scale: 1.5,
                    rotation: 0,
                    offset: .zero
                ),
                material: BrushMaterial(
                    family: .dry,
                    strength: 0.85,
                    wetness: 0,
                    bleedRadius: 0,
                    softenPasses: 0,
                    accumulationLimit: 1
                ),
                baseSpacingFraction: 0.1,
                maximumSpacingFraction: 0.2,
                baseFlow: 0.7,
                strokeOpacity: 0.9,
                baseHardness: 0.75,
                baseScatterFraction: 0.03,
                aspectRatio: 0.7,
                sizeMapping: .boundedPower(
                    input: .pressure,
                    output: 0.3...1,
                    exponent: 1.25
                ),
                flowMapping: .linear(
                    input: .pressure,
                    output: 0.35...1
                ),
                rotationMapping: .linear(
                    input: .direction,
                    output: -Float.pi...Float.pi
                ),
                scatterMapping: .linear(
                    input: .pressure,
                    output: 0.5...1
                ),
                randomization: BrushRandomization(
                    spacing: 0.1,
                    scatter: 1,
                    rotation: 0,
                    grain: 0.35,
                    material: 0.15
                )
            )
        }
    )

    public static let glazeMarker = AnchorBrushEntry(
        displayName: "Glaze Marker",
        role: .draw,
        recipe: builtIn {
            try BrushRecipe(
                id: BrushRecipeID("builtin.glaze-marker"),
                shape: .chisel,
                grain: .opaque,
                material: BrushMaterial(
                    family: .glaze,
                    strength: 0.8,
                    wetness: 0.2,
                    bleedRadius: 0,
                    softenPasses: 0,
                    accumulationLimit: 0.85
                ),
                baseSpacingFraction: 0.16,
                maximumSpacingFraction: 0.3,
                baseFlow: 0.35,
                strokeOpacity: 0.75,
                baseHardness: 0.7,
                aspectRatio: 0.7,
                sizeMapping: .linear(
                    input: .pressure,
                    output: 0.6...1
                ),
                flowMapping: .linear(
                    input: .pressure,
                    output: 0.5...1
                ),
                rotationMapping: .linear(
                    input: .direction,
                    output: -Float.pi...Float.pi
                )
            )
        }
    )

    public static let boundedWash = AnchorBrushEntry(
        displayName: "Bounded Wash",
        role: .draw,
        recipe: builtIn {
            try BrushRecipe(
                id: BrushRecipeID("builtin.bounded-wash"),
                shape: .softRound,
                grain: .paper,
                grainCoordinateMode: .canonical,
                grainTransform: BrushGrainTransform(
                    scale: 1.2,
                    rotation: 0,
                    offset: .zero
                ),
                material: BrushMaterial(
                    family: .boundedWash,
                    strength: 1,
                    wetness: 0.8,
                    bleedRadius: 12,
                    softenPasses: 2,
                    accumulationLimit: 0.75
                ),
                baseSpacingFraction: 0.15,
                maximumSpacingFraction: 0.3,
                baseFlow: 0.85,
                strokeOpacity: 0.85,
                baseHardness: 0.2,
                sizeMapping: .linear(
                    input: .pressure,
                    output: 0.6...1
                ),
                flowMapping: .linear(
                    input: .pressure,
                    output: 0.5...1
                ),
                randomization: BrushRandomization(
                    spacing: 0.05,
                    scatter: 0,
                    rotation: 0,
                    grain: 0.2,
                    material: 0.1
                ),
                replayMode: .boundedWholeStroke,
                replayLimits: BrushReplayLimits(
                    maximumSamples: 4_096,
                    maximumDabs: 4_096,
                    maximumProjectedInstances: 4_096
                )
            )
        }
    )

    public static let hardRoundEraser = AnchorBrushEntry(
        displayName: "Hard Round Eraser",
        role: .erase,
        recipe: builtIn {
            try BrushRecipe(
                id: BrushRecipeID("builtin.hard-round-eraser"),
                shape: .hardRound,
                grain: .opaque,
                material: .ink
            )
        }
    )

    public static let drawAnchors: [AnchorBrushEntry] = [
        technicalInk,
        dryPencil,
        glazeMarker,
        boundedWash,
    ]
    public static let all: [AnchorBrushEntry] = drawAnchors + [hardRoundEraser]
    public static let defaultDraw = technicalInk

    public static func entry(for id: BrushRecipeID) -> AnchorBrushEntry? {
        all.first { $0.id == id }
    }

    public static func recipe(for id: BrushRecipeID) -> BrushRecipe? {
        entry(for: id)?.recipe
    }

    public static func drawEntry(for id: BrushRecipeID) -> AnchorBrushEntry? {
        drawAnchors.first { $0.id == id }
    }

    private static func builtIn(
        _ makeRecipe: () throws -> BrushRecipe
    ) -> BrushRecipe {
        do {
            return try makeRecipe()
        } catch {
            preconditionFailure("Invalid built-in anchor recipe: \(error)")
        }
    }
}
