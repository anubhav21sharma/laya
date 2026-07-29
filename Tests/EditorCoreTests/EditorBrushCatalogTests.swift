import EditorCore
import PatternEngine
import Testing

@Test
func editorCatalogUsesTheApprovedProfessionalPickerOrder() {
    #expect(EditorBrushCatalog.drawEntries.map(\.id.rawValue) == [
        "builtin.professional-technical-ink",
        "builtin.professional-graphite-pencil",
        "builtin.professional-natural-charcoal",
        "builtin.professional-chisel-marker",
        "builtin.native-glaze",
        "builtin.native-airbrush",
    ])
    #expect(EditorBrushCatalog.drawEntries.map(\.displayName) == [
        "Technical Ink",
        "Graphite Pencil",
        "Natural Charcoal",
        "Chisel Marker",
        "Native Glaze",
        "Native Airbrush",
    ])
    #expect(EditorBrushCatalog.defaultDraw.id == BrushRecipeID(
        "builtin.professional-technical-ink"
    ))
    #expect(EditorBrushCatalog.eraser == AnchorBrushCatalog.eraser)
}

@Test(arguments: [
    ("builtin.native-ink", "builtin.professional-technical-ink"),
    ("builtin.technical-ink", "builtin.professional-technical-ink"),
    ("builtin.native-dry-media", "builtin.professional-graphite-pencil"),
    ("builtin.dry-pencil", "builtin.professional-graphite-pencil"),
    ("builtin.native-marker", "builtin.professional-chisel-marker"),
    ("builtin.glaze-marker", "builtin.professional-chisel-marker"),
    ("builtin.native-glaze", "builtin.native-glaze"),
    ("builtin.native-airbrush", "builtin.native-airbrush"),
])
func editorCatalogMigratesEveryLegacyDrawSelection(
    incoming: String,
    expected: String
) {
    #expect(EditorBrushCatalog.resolveSelection(BrushRecipeID(incoming))
        == BrushRecipeID(expected))
}

@Test
func editorCatalogAcceptsCurrentSelectionsAndRejectsUnknownIDs() {
    for entry in EditorBrushCatalog.drawEntries {
        #expect(EditorBrushCatalog.resolveSelection(entry.id) == entry.id)
        #expect(EditorBrushCatalog.drawEntry(for: entry.id) == entry)
    }
    #expect(EditorBrushCatalog.resolveSelection(
        BrushRecipeID("builtin.unknown-professional-brush")
    ) == nil)
    #expect(EditorBrushCatalog.drawEntry(for: AnchorBrushCatalog.eraser.id) == nil)
}
