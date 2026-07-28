public enum StrokeCompositeMode: UInt32, Equatable, Sendable {
    case draw = 0
    case erase = 1
}

public enum BrushRenderIdentityError: Error, Equatable, Sendable {
    case emptyDefinitionID
    case invalidSemanticHash
}

public struct BrushRenderIdentity: Equatable, Sendable {
    public let definitionID: BrushRecipeID
    public let semanticHash: String

    public init(
        definitionID: BrushRecipeID,
        semanticHash: String
    ) throws {
        guard !definitionID.rawValue.isEmpty else {
            throw BrushRenderIdentityError.emptyDefinitionID
        }
        let bytes = semanticHash.utf8
        guard bytes.count == 64,
              bytes.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              })
        else {
            throw BrushRenderIdentityError.invalidSemanticHash
        }
        self.definitionID = definitionID
        self.semanticHash = semanticHash
    }
}

public struct StrokeRenderStyle: Equatable, Sendable {
    private static let uncompiledCompatibilitySemanticHash =
        "b29442ec35ff6345e89176318f449c4e"
        + "57d31b68a007fbea32d8176383a55f9e"

    public let color: InkColor
    public let diameter: Float
    public let compositeMode: StrokeCompositeMode
    public let eraserStrength: Float
    public let program: BrushProgram
    public let renderIdentity: BrushRenderIdentity
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
            renderIdentity: Self.compatibilityRenderIdentity(
                for: Self.legacyEquivalentProgram
            ),
            seed: 1
        )
    }

    /// Compatibility-only bridge for the renderer that predates compiled
    /// package activation. Stage 4 production call sites pass the package
    /// identity through the designated initializer below.
    @available(
        *,
        deprecated,
        message: "Pass the prepared CompiledBrush render identity."
    )
    public init(
        color: InkColor,
        diameter: Float,
        compositeMode: StrokeCompositeMode,
        eraserStrength: Float,
        program: BrushProgram,
        seed: UInt64
    ) {
        self.init(
            color: color,
            diameter: diameter,
            compositeMode: compositeMode,
            eraserStrength: eraserStrength,
            program: program,
            renderIdentity: Self.compatibilityRenderIdentity(for: program),
            seed: seed
        )
    }

    public init(
        color: InkColor,
        diameter: Float,
        compositeMode: StrokeCompositeMode,
        eraserStrength: Float,
        program: BrushProgram,
        renderIdentity: BrushRenderIdentity,
        seed: UInt64
    ) {
        precondition(diameter.isFinite && diameter > 0)
        precondition(
            eraserStrength.isFinite && (0...1).contains(eraserStrength)
        )
        precondition(seed != 0, "Stroke seed must be nonzero")
        precondition(
            renderIdentity.definitionID == program.definition.id,
            "Render identity must match the compiled brush program"
        )
        self.color = color
        self.diameter = diameter
        self.compositeMode = compositeMode
        self.eraserStrength = eraserStrength
        self.program = program
        self.renderIdentity = renderIdentity
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

    private static func compatibilityRenderIdentity(
        for program: BrushProgram
    ) -> BrushRenderIdentity {
        do {
            return try BrushRenderIdentity(
                definitionID: program.definition.id,
                semanticHash: Self.uncompiledCompatibilitySemanticHash
            )
        } catch {
            preconditionFailure(
                "A compiled brush program must have a valid identity: \(error)"
            )
        }
    }
}
