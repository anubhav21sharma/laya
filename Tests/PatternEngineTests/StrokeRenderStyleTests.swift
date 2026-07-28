@testable import PatternEngine
import Testing

@Suite("Stroke render style")
struct StrokeRenderStyleTests {
    @Test
    func requiredRenderIdentityIsPreservedAndParticipatesInEquality() throws {
        let program = try styleProgram()
        let firstIdentity = try BrushRenderIdentity(
            definitionID: program.definition.id,
            semanticHash: String(repeating: "1a", count: 32)
        )
        let secondIdentity = try BrushRenderIdentity(
            definitionID: program.definition.id,
            semanticHash: String(repeating: "2b", count: 32)
        )
        let first = StrokeRenderStyle(
            color: .black,
            diameter: 20,
            compositeMode: .draw,
            eraserStrength: 1,
            program: program,
            renderIdentity: firstIdentity,
            seed: 41
        )
        let equal = StrokeRenderStyle(
            color: .black,
            diameter: 20,
            compositeMode: .draw,
            eraserStrength: 1,
            program: program,
            renderIdentity: firstIdentity,
            seed: 41
        )
        let different = StrokeRenderStyle(
            color: .black,
            diameter: 20,
            compositeMode: .draw,
            eraserStrength: 1,
            program: program,
            renderIdentity: secondIdentity,
            seed: 41
        )

        #expect(first.renderIdentity == firstIdentity)
        #expect(first == equal)
        #expect(first != different)
    }

    private func styleProgram() throws -> BrushProgram {
        let recipe = try BrushRecipe(id: BrushRecipeID("style.identity"))
        let definition = try LegacyBrushRecipeAdapter.definition(
            from: recipe,
            displayName: "Style Identity"
        )
        return try BrushProgramCompiler.compile(definition)
    }
}
