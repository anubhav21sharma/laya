import EditorCore
import PatternEngine
import Testing

@Test
func professionalCatalogExposesTechnicalInkAsACompiledNativeBrush() throws {
    let entry = ProfessionalBrushCatalog.technicalInk

    #expect(ProfessionalBrushCatalog.all == [entry])
    #expect(entry.id.rawValue == "builtin.professional-technical-ink")
    #expect(entry.displayName == "Technical Ink")
    #expect(ProfessionalBrushCatalog.entry(for: entry.id) == entry)
    #expect(ProfessionalBrushCatalog.entry(for: BrushRecipeID("missing.brush")) == nil)
    #expect(try BrushProgramCompiler.compile(entry.definition) == entry.program)
    #expect(entry.program.requestedBackend == .deposition)
    #expect(entry.definition.resources == [
        BrushResourceReference(
            identifier: "builtin.shape.technical-nib",
            kind: .shape,
            required: false,
            fallback: .builtIn(identifier: "builtin.shape.technical-nib")
        ),
    ])
}
