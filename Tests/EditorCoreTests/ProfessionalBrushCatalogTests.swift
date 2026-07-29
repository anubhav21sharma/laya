import EditorCore
import PatternEngine
import Testing

@Test
func professionalCatalogExposesTechnicalInkAsACompiledNativeBrush() throws {
    let entry = ProfessionalBrushCatalog.technicalInk

    #expect(ProfessionalBrushCatalog.all.first == entry)
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

@Test
func professionalCatalogResolvesGraphitePencilWithItsStableIdentity() throws {
    let graphiteID = BrushRecipeID("builtin.professional-graphite-pencil")
    let entry = try #require(ProfessionalBrushCatalog.entry(for: graphiteID))
    let compiled = try BrushProgramCompiler.compile(entry.definition)

    #expect(entry.id == graphiteID)
    #expect(entry.displayName == "Graphite Pencil")
    #expect(entry.program == compiled)
    #expect(compiled.definition.resources == [
        BrushResourceReference(
            identifier: "builtin.grain.graphite",
            kind: .grain,
            required: false,
            fallback: .builtIn(identifier: "builtin.grain.graphite")
        ),
        BrushResourceReference(
            identifier: "builtin.grain.paper",
            kind: .grain,
            required: false,
            fallback: .builtIn(identifier: "builtin.grain.paper")
        ),
        BrushResourceReference(
            identifier: "builtin.shape.graphite-tip",
            kind: .shape,
            required: false,
            fallback: .builtIn(identifier: "builtin.shape.graphite-tip")
        ),
    ])
    #expect(compiled.definition.material.accumulation == .flow)
    #expect(compiled.definition.material.accumulationLimit == 1)
    #expect(ProfessionalBrushCatalog.all.map(\.id) == [
        BrushRecipeID("builtin.professional-technical-ink"),
        graphiteID,
    ])
}
