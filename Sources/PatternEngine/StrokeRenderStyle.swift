public enum StrokeCompositeMode: UInt32, Equatable, Sendable {
    case draw = 0
    case erase = 1
}

public struct StrokeRenderStyle: Equatable, Sendable {
    public let color: InkColor
    public let diameter: Float
    public let compositeMode: StrokeCompositeMode
    public let eraserStrength: Float
    public let program: BrushProgram
    public let seed: UInt64

    private static let legacyEquivalentProgram: BrushProgram = {
        do {
            let definition = try LegacyBrushRecipeAdapter.definition(
                from: .legacyEquivalent,
                displayName: BrushRecipe.legacyEquivalent.id.rawValue
            )
            return try BrushProgramCompiler.compile(definition)
        } catch {
            preconditionFailure(
                "The legacy-equivalent stroke style must compile: \(error)"
            )
        }
    }()

    public init(
        color: InkColor,
        diameter: Float,
        compositeMode: StrokeCompositeMode,
        eraserStrength: Float
    ) {
        self.init(
            color: color,
            diameter: diameter,
            compositeMode: compositeMode,
            eraserStrength: eraserStrength,
            program: Self.legacyEquivalentProgram,
            seed: 1
        )
    }

    public init(
        color: InkColor,
        diameter: Float,
        compositeMode: StrokeCompositeMode,
        eraserStrength: Float,
        program: BrushProgram,
        seed: UInt64
    ) {
        precondition(diameter.isFinite && diameter > 0)
        precondition(
            eraserStrength.isFinite && (0...1).contains(eraserStrength)
        )
        precondition(seed != 0, "Stroke seed must be nonzero")
        self.color = color
        self.diameter = diameter
        self.compositeMode = compositeMode
        self.eraserStrength = eraserStrength
        self.program = program
        self.seed = seed
    }

    @available(
        *,
        deprecated,
        message: "Compile BrushDefinition to BrushProgram and initialize StrokeRenderStyle(program:)."
    )
    public init(
        color: InkColor,
        diameter: Float,
        compositeMode: StrokeCompositeMode,
        eraserStrength: Float,
        recipe: BrushRecipe,
        seed: UInt64
    ) {
        do {
            let definition = try LegacyBrushRecipeAdapter.definition(
                from: recipe,
                displayName: recipe.id.rawValue
            )
            self.init(
                color: color,
                diameter: diameter,
                compositeMode: compositeMode,
                eraserStrength: eraserStrength,
                program: try BrushProgramCompiler.compile(definition),
                seed: seed
            )
        } catch {
            preconditionFailure(
                "Legacy stroke recipe must compile before rendering: \(error)"
            )
        }
    }

    /// Temporary Stage-2 view for compatibility-only renderer and harness
    /// seams. Native programs must use the compiled renderer instead.
    public var recipe: BrushRecipe {
        guard let recipe = program.compatibilityRecipe else {
            preconditionFailure(
                "The legacy renderer requires a compatible brush program"
            )
        }
        return recipe
    }
}
