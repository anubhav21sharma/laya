import EditorCore
import PatternEngine
import Testing

@Test func anchorCatalogPinsSixNativeBuiltInEntries() {
    let entries = AnchorBrushCatalog.all

    #expect(entries.allSatisfy {
        $0.definition.schemaVersion == BrushDefinition.currentSchemaVersion
    })
    #expect(entries.map(\.id.rawValue) == [
        "builtin.native-ink",
        "builtin.native-dry-media",
        "builtin.native-glaze",
        "builtin.native-marker",
        "builtin.native-airbrush",
        "builtin.native-eraser",
    ])
    #expect(entries.map(\.displayName) == [
        "Native Ink",
        "Native Dry Media",
        "Native Glaze",
        "Native Marker",
        "Native Airbrush",
        "Native Eraser",
    ])
    #expect(AnchorBrushCatalog.drawAnchors.count == 5)
    #expect(AnchorBrushCatalog.drawAnchors.allSatisfy { $0.role == .draw })
    #expect(AnchorBrushCatalog.eraser.role == .erase)
    #expect(Set(entries.map(\.id)).count == entries.count)
}

@Test
func anchorProgramsArePrecompiledNativeDefinitions() throws {
    for entry in AnchorBrushCatalog.all {
        #expect(entry.program.definition == entry.definition)
        #expect(entry.program.requestedBackend == .deposition)
        #expect(entry.definition.components[0].material.interaction == .none)
        #expect(entry.definition.performanceIntent == .realtime120)
    }
}

@Test
func programRenderStylePreservesNativeFields() throws {
    let entry = AnchorBrushCatalog.dryMedia
    let color = InkColor(
        red: 0.25,
        green: 0.5,
        blue: 0.75,
        alpha: 0.8
    )!
    let style = StrokeRenderStyle(
        color: color,
        diameter: 37,
        compositeMode: .draw,
        eraserStrength: 0.6,
        program: entry.program,
        renderIdentity: try BrushRenderIdentity(
            definitionID: entry.definition.id,
            semanticHash: String(repeating: "b", count: 64)
        ),
        seed: 91
    )
    #expect(style.color == color)
    #expect(style.diameter == 37)
    #expect(style.compositeMode == .draw)
    #expect(style.eraserStrength == 0.6)
    #expect(style.program == entry.program)
    #expect(style.seed == 91)
}

@Test func anchorCatalogDefinesApprovedDepositionFamilies() throws {
    #expect(AnchorBrushCatalog.ink.definition.components[0].material.accumulation == .flow)
    #expect(AnchorBrushCatalog.ink.definition.components[0].material.edgeTreatment == .none)
    #expect(AnchorBrushCatalog.dryMedia.definition.components[0].material.accumulation == .flow)
    #expect(AnchorBrushCatalog.dryMedia.definition.components[0].material.edgeTreatment == .dryBreakup)
    #expect(AnchorBrushCatalog.glaze.definition.components[0].material.accumulation == .uniformGlaze)
    #expect(AnchorBrushCatalog.glaze.definition.components[0].material.edgeTreatment == .none)
    #expect(AnchorBrushCatalog.marker.definition.components[0].material.accumulation == .uniformGlaze)
    #expect(AnchorBrushCatalog.marker.definition.components[0].material.edgeTreatment == .markerOverlap)
    #expect(AnchorBrushCatalog.airbrush.definition.components[0].material.accumulation == .flow)
    #expect(AnchorBrushCatalog.airbrush.definition.components[0].material.edgeTreatment == .none)
    #expect(AnchorBrushCatalog.eraser.definition.components[0].material.accumulation == .destinationOut)
    #expect(AnchorBrushCatalog.eraser.definition.components[0].material.edgeTreatment == .none)

    for entry in AnchorBrushCatalog.all {
        #expect(AnchorBrushCatalog.entry(for: entry.id) == entry)
        #expect(!entry.id.rawValue.localizedCaseInsensitiveContains("wash"))
        #expect(!entry.displayName.localizedCaseInsensitiveContains("wash"))
        #expect(try BrushProgramCompiler.compile(entry.definition) == entry.program)
    }
    #expect(
        AnchorBrushCatalog.entry(for: BrushRecipeID("missing.recipe")) == nil
    )
}

@Test func dedicatedEraserCannotBeSelectedAsADrawAnchor() {
    #expect(
        !AnchorBrushCatalog.drawAnchors.contains {
            $0.id == AnchorBrushCatalog.eraser.id
        }
    )
    #expect(AnchorBrushCatalog.defaultDraw == AnchorBrushCatalog.ink)
}

@Test func dedicatedEraserCanReachFullyTransparentCoverage() {
    let definition = AnchorBrushCatalog.eraser.definition
    let component = definition.components[0]

    #expect(component.placement.baseFlow == 1)
    #expect(component.placement.strokeOpacity == 1)
    #expect(component.placement.baseScatterFraction == 0)
    #expect(component.placement.baseJitterFraction == 0)
    #expect(component.coverage.baseHardness == 1)
    #expect(component.material.strength == 1)
    #expect(component.material.accumulationLimit == 1)
}

@Test func nativeAnchorsUseNominalDiameterWithoutPressureInput() {
    for entry in AnchorBrushCatalog.all {
        #expect(entry.definition.components[0].dynamics.size.missingInputValue == 1)
        #expect(entry.definition.components[0].dynamics.noPressureNeutral == 1)
    }
}

@Test func softAndMarkerAnchorsRetainVisibleNominalFootprints() {
    #expect(AnchorBrushCatalog.glaze.definition.components[0].coverage.baseHardness == 1)
    #expect(AnchorBrushCatalog.glaze.definition.components[0].placement.baseFlow >= 0.5)
    #expect(AnchorBrushCatalog.airbrush.definition.components[0].coverage.baseHardness == 1)
    #expect(AnchorBrushCatalog.airbrush.definition.components[0].placement.baseFlow >= 0.25)
    #expect(AnchorBrushCatalog.marker.definition.components[0].coverage.aspectRatio >= 0.8)
    #expect(AnchorBrushCatalog.marker.definition.components[0].placement.baseFlow >= 0.6)
}
