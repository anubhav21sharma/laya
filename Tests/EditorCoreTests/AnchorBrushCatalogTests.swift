import EditorCore
import PatternEngine
import Testing

@Test func anchorCatalogPinsFiveStableBuiltInEntries() {
    let entries = AnchorBrushCatalog.all

    #expect(entries.map(\.id.rawValue) == [
        "builtin.technical-ink",
        "builtin.dry-pencil",
        "builtin.glaze-marker",
        "builtin.bounded-wash",
        "builtin.hard-round-eraser",
    ])
    #expect(entries.map(\.displayName) == [
        "Technical Ink",
        "Dry Pencil",
        "Glaze Marker",
        "Bounded Wash",
        "Hard Round Eraser",
    ])
    #expect(AnchorBrushCatalog.drawAnchors.count == 4)
    #expect(AnchorBrushCatalog.drawAnchors.allSatisfy { $0.role == .draw })
    #expect(AnchorBrushCatalog.hardRoundEraser.role == .erase)
    #expect(Set(entries.map(\.id)).count == entries.count)
}

@Test func anchorCatalogRecipesAreDistinctValidatedFixtures() throws {
    let technical = AnchorBrushCatalog.technicalInk.recipe
    let pencil = AnchorBrushCatalog.dryPencil.recipe
    let glaze = AnchorBrushCatalog.glazeMarker.recipe
    let wash = AnchorBrushCatalog.boundedWash.recipe
    let eraser = AnchorBrushCatalog.hardRoundEraser.recipe

    #expect(technical.shape == .hardRound)
    #expect(technical.material.family == .ink)
    #expect(technical.baseScatterFraction == 0)

    #expect(pencil.grain == .paper)
    #expect(pencil.material.family == .dry)
    #expect(pencil.baseScatterFraction > 0)

    #expect(glaze.shape == .chisel)
    #expect(glaze.material.family == .glaze)
    #expect(glaze.baseFlow < 1)
    #expect(glaze.strokeOpacity < 1)

    #expect(wash.shape == .softRound)
    #expect(wash.material.family == .boundedWash)
    #expect(wash.material.bleedRadius <= 32)
    #expect(wash.material.softenPasses <= 2)
    #expect(wash.replayMode == .boundedWholeStroke)
    #expect(wash.replayLimits != nil)

    #expect(eraser.shape == .hardRound)
    #expect(eraser.grain == .opaque)
    #expect(eraser.material.family == .ink)
    #expect(eraser.baseScatterFraction == 0)

    for entry in AnchorBrushCatalog.all {
        #expect(AnchorBrushCatalog.entry(for: entry.id) == entry)
        #expect(AnchorBrushCatalog.recipe(for: entry.id) == entry.recipe)
    }
    #expect(
        AnchorBrushCatalog.entry(for: BrushRecipeID("missing.recipe")) == nil
    )
}

@Test func dedicatedEraserCannotBeSelectedAsADrawAnchor() {
    #expect(
        !AnchorBrushCatalog.drawAnchors.contains {
            $0.id == AnchorBrushCatalog.hardRoundEraser.id
        }
    )
    #expect(AnchorBrushCatalog.defaultDraw == AnchorBrushCatalog.technicalInk)
}
