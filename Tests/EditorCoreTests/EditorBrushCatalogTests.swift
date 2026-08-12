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

@Test
func editorCatalogAcceptsCurrentSelectionsAndRejectsUnknownIDs() throws {
    for entry in EditorBrushCatalog.drawEntries {
        #expect(EditorBrushCatalog.resolveSelection(entry.id) == entry.id)
        #expect(EditorBrushCatalog.drawEntry(for: entry.id) == entry)
        #expect(try EditorBrushCatalog.resolveCurrentSelection(entry.id) == entry.id)
    }
    let unknownID = BrushRecipeID("builtin.unknown-professional-brush")
    #expect(EditorBrushCatalog.resolveSelection(unknownID) == nil)
    #expect(try EditorBrushCatalog.resolveCurrentSelection(unknownID) == nil)
    #expect(EditorBrushCatalog.drawEntry(for: AnchorBrushCatalog.eraser.id) == nil)
}

@Test
func editorCatalogReportsRetiredNativeSelectionWithoutAnAlias() {
    let retiredID = BrushRecipeID("builtin.bounded-wash")

    #expect(throws: EditorBrushSelectionError.retiredIdentifier(retiredID)) {
        _ = try EditorBrushCatalog.resolveCurrentSelection(retiredID)
    }
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
