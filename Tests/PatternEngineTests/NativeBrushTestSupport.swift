import PatternEngine

func nativeTestDefinition(
    _ recipe: BrushRecipe = .legacyEquivalent
) -> BrushDefinition {
    do {
        return try LegacyBrushRecipeAdapter.definition(
            from: recipe,
            displayName: recipe.id.rawValue
        )
    } catch {
        preconditionFailure("Native test definition must adapt: \(error)")
    }
}

func nativeTestProgram(
    _ recipe: BrushRecipe = .legacyEquivalent
) -> BrushProgram {
    do {
        return try BrushProgramCompiler.compile(
            nativeTestDefinition(recipe)
        )
    } catch {
        preconditionFailure("Native test program must compile: \(error)")
    }
}
