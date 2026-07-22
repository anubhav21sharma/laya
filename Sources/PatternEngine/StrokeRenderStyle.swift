public enum StrokeCompositeMode: UInt32, Equatable, Sendable {
    case draw = 0
    case erase = 1
}

public struct StrokeRenderStyle: Equatable, Sendable {
    public let color: InkColor
    public let diameter: Float
    public let compositeMode: StrokeCompositeMode
    public let eraserStrength: Float
    public let recipe: BrushRecipe
    public let seed: UInt64

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
            recipe: .legacyEquivalent,
            seed: 1
        )
    }

    public init(
        color: InkColor,
        diameter: Float,
        compositeMode: StrokeCompositeMode,
        eraserStrength: Float,
        recipe: BrushRecipe,
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
        self.recipe = recipe
        self.seed = seed
    }
}
