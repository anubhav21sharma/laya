import EditorCore
import PatternEngine
import Testing

@Test func anchorCatalogPinsSixNativeBuiltInEntries() {
    let entries = AnchorBrushCatalog.all

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
        #expect(entry.definition.material.interaction == .none)
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
    #expect(AnchorBrushCatalog.ink.definition.material.accumulation == .flow)
    #expect(AnchorBrushCatalog.ink.definition.material.edgeTreatment == .none)
    #expect(AnchorBrushCatalog.dryMedia.definition.material.accumulation == .flow)
    #expect(AnchorBrushCatalog.dryMedia.definition.material.edgeTreatment == .dryBreakup)
    #expect(AnchorBrushCatalog.glaze.definition.material.accumulation == .uniformGlaze)
    #expect(AnchorBrushCatalog.glaze.definition.material.edgeTreatment == .none)
    #expect(AnchorBrushCatalog.marker.definition.material.accumulation == .uniformGlaze)
    #expect(AnchorBrushCatalog.marker.definition.material.edgeTreatment == .markerOverlap)
    #expect(AnchorBrushCatalog.airbrush.definition.material.accumulation == .flow)
    #expect(AnchorBrushCatalog.airbrush.definition.material.edgeTreatment == .none)
    #expect(AnchorBrushCatalog.eraser.definition.material.accumulation == .destinationOut)
    #expect(AnchorBrushCatalog.eraser.definition.material.edgeTreatment == .none)

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

    #expect(definition.placement.baseFlow == 1)
    #expect(definition.placement.strokeOpacity == 1)
    #expect(definition.placement.baseScatterFraction == 0)
    #expect(definition.placement.baseJitterFraction == 0)
    #expect(definition.coverage.baseHardness == 1)
    #expect(definition.material.strength == 1)
    #expect(definition.material.accumulationLimit == 1)
}

@Test func nativeAnchorsUseNominalDiameterWithoutPressureInput() {
    for entry in AnchorBrushCatalog.all {
        #expect(entry.definition.dynamics.size.missingInputValue == 1)
        #expect(entry.definition.dynamics.noPressureNeutral == 1)
    }
}

@Test func softAndMarkerAnchorsRetainVisibleNominalFootprints() {
    #expect(AnchorBrushCatalog.glaze.definition.coverage.baseHardness == 1)
    #expect(AnchorBrushCatalog.glaze.definition.placement.baseFlow >= 0.5)
    #expect(AnchorBrushCatalog.airbrush.definition.coverage.baseHardness == 1)
    #expect(AnchorBrushCatalog.airbrush.definition.placement.baseFlow >= 0.25)
    #expect(AnchorBrushCatalog.marker.definition.coverage.aspectRatio >= 0.8)
    #expect(AnchorBrushCatalog.marker.definition.placement.baseFlow >= 0.6)
}
