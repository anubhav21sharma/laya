import EditorCore
import PatternEngine
import Testing

@Test
func editorCatalogKeepsProfessionalPresetsOutOfTheProductPicker() {
    #expect(EditorBrushCatalog.drawEntries.map(\.id.rawValue) == [
        "builtin.native-ink",
        "builtin.native-dry-media",
        "builtin.native-marker",
        "builtin.native-glaze",
        "builtin.native-airbrush",
    ])
    #expect(EditorBrushCatalog.drawEntries.map(\.displayName) == [
        "Native Ink",
        "Native Dry Media",
        "Native Marker",
        "Native Glaze",
        "Native Airbrush",
    ])
    #expect(EditorBrushCatalog.defaultDraw.id == BrushRecipeID(
        "builtin.native-ink"
    ))
    #expect(EditorBrushCatalog.eraser == AnchorBrushCatalog.eraser)
}

@Test(arguments: [
    ("builtin.native-ink", "builtin.native-ink"),
    ("builtin.technical-ink", "builtin.native-ink"),
    ("builtin.native-dry-media", "builtin.native-dry-media"),
    ("builtin.dry-pencil", "builtin.native-dry-media"),
    ("builtin.native-marker", "builtin.native-marker"),
    ("builtin.glaze-marker", "builtin.native-marker"),
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

@Test(arguments: [
    "builtin.professional-technical-ink",
    "builtin.professional-graphite-pencil",
    "builtin.professional-natural-charcoal",
    "builtin.professional-chisel-marker",
])
func editorCatalogRejectsEveryProfessionalPresetFromProductSelection(
    persistedID: String
) {
    let id = BrushRecipeID(persistedID)

    #expect(EditorBrushCatalog.drawEntry(for: id) == nil)
    #expect(EditorBrushCatalog.resolveSelection(id) == nil)
}
