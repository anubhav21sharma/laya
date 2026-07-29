import EditorCore
import Foundation
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
}

@Test
func professionalCatalogResolvesNaturalCharcoalWithOrderedDualLayers() throws {
    let charcoalID = BrushRecipeID("builtin.professional-natural-charcoal")
    let entry = try #require(ProfessionalBrushCatalog.entry(for: charcoalID))
    let compiled = try BrushProgramCompiler.compile(entry.definition)

    #expect(entry.id == charcoalID)
    #expect(entry.displayName == "Natural Charcoal")
    #expect(entry.program == compiled)
    #expect(compiled.definition.capabilities == [
        BrushCapabilityDeclaration(identifier: "dualGrain", required: true),
        BrushCapabilityDeclaration(identifier: "dualShape", required: true),
    ])
    #expect(compiled.requiredCapabilities == [.dualGrain, .dualShape])
    #expect(compiled.definition.resources == [
        BrushResourceReference(
            identifier: "builtin.grain.charcoal",
            kind: .grain,
            required: false,
            fallback: .builtIn(identifier: "builtin.grain.charcoal")
        ),
        BrushResourceReference(
            identifier: "builtin.grain.paper",
            kind: .grain,
            required: false,
            fallback: .builtIn(identifier: "builtin.grain.paper")
        ),
        BrushResourceReference(
            identifier: "builtin.shape.charcoal-tip",
            kind: .shape,
            required: false,
            fallback: .builtIn(identifier: "builtin.shape.charcoal-tip")
        ),
    ])
    #expect(compiled.definition.coverage.shapes.map(\.shape) == [
        .asset("builtin.shape.charcoal-tip"),
        .softRound,
    ])
    #expect(compiled.definition.coverage.shapes.map(\.combination) == [
        .replace,
        .multiply,
    ])
    #expect(compiled.definition.coverage.grains.map(\.grain) == [
        .asset("builtin.grain.charcoal"),
        .asset("builtin.grain.paper"),
    ])
    #expect(compiled.definition.coverage.grains.map(\.coordinateMode) == [
        .brushLocal,
        .canonical,
    ])
    #expect(compiled.definition.coverage.grains.map(\.grainFollowsBrushRotation) == [
        true,
        false,
    ])
    #expect(compiled.definition.coverage.grains.map(\.grainMovementFraction) == [0.12, 0.12])
    #expect(compiled.definition.material.accumulation == .flow)
    #expect(compiled.definition.material.edgeTreatment == .dryBreakup)
    #expect(compiled.definition.material.interaction == .none)
    #expect(compiled.definition.material.strength == 1)
    #expect(compiled.definition.material.accumulationLimit == 1)
    #expect(compiled.definition.performanceIntent == .realtime120)
}

@Test
func professionalCatalogResolvesChiselMarkerWithItsExactFallbackAndMaterial() throws {
    let markerID = BrushRecipeID("builtin.professional-chisel-marker")
    let entry = try #require(ProfessionalBrushCatalog.entry(for: markerID))
    let compiled = try BrushProgramCompiler.compile(entry.definition)

    #expect(entry.id == markerID)
    #expect(entry.displayName == "Chisel Marker")
    #expect(entry.program == compiled)
    #expect(compiled.definition.resources == [
        BrushResourceReference(
            identifier: "builtin.shape.marker-chisel",
            kind: .shape,
            required: false,
            fallback: .builtIn(identifier: "builtin.shape.marker-chisel")
        ),
    ])
    #expect(compiled.definition.coverage.shapes.map(\.shape) == [
        .asset("builtin.shape.marker-chisel"),
    ])
    #expect(compiled.definition.coverage.grains.isEmpty)
    #expect(compiled.definition.coverage.baseHardness == 0.96)
    #expect(compiled.definition.coverage.aspectRatio == 0.22)
    #expect(compiled.definition.placement.strokeOpacity == 0.82)
    #expect(compiled.definition.placement.baseSpacingFraction == 0.035)
    #expect(compiled.definition.placement.maximumSpacingFraction == 0.10)
    #expect(compiled.definition.dynamics.spacing == BrushMappingDefinition(
        input: .pressure,
        response: .constant(1),
        scale: 1,
        offset: 0,
        lowerClamp: 1,
        upperClamp: 1,
        inverted: false,
        jitter: 0,
        missingInputValue: 1
    ))
    #expect(compiled.definition.material.accumulation == .uniformGlaze)
    #expect(compiled.definition.material.edgeTreatment == .markerOverlap)
    #expect(compiled.definition.material.interaction == .none)
    #expect(compiled.definition.material.strength == 0.95)
    #expect(compiled.definition.material.accumulationLimit == 0.82)
    #expect(compiled.definition.performanceIntent == .realtime120)
    #expect(compiled.definition.stabilization == 0.12)
    #expect(compiled.definition.taper.start == .diameterMultiples(0.35))
    #expect(compiled.definition.taper.end == .diameterMultiples(0.35))
    #expect(compiled.definition.taper.minimumSize == 0.85)
    #expect(compiled.definition.taper.minimumFlow == 0.85)
    #expect(ProfessionalBrushCatalog.all.map(\.id) == [
        BrushRecipeID("builtin.professional-technical-ink"),
        BrushRecipeID("builtin.professional-graphite-pencil"),
        BrushRecipeID("builtin.professional-natural-charcoal"),
        markerID,
    ])
}

@Test
func naturalCharcoalValidationRejectsMissingOrOptionalDualLayerCapabilities() throws {
    #expect(throws: BrushDefinitionValidationError.missingCapability("dualShape")) {
        try decodeMutatedNaturalCharcoal(removing: "dualShape")
    }
    #expect(throws: BrushDefinitionValidationError.missingCapability("dualShape")) {
        try decodeMutatedNaturalCharcoal(markingOptional: "dualShape")
    }
    #expect(throws: BrushDefinitionValidationError.missingCapability("dualGrain")) {
        try decodeMutatedNaturalCharcoal(removing: "dualGrain")
    }
    #expect(throws: BrushDefinitionValidationError.missingCapability("dualGrain")) {
        try decodeMutatedNaturalCharcoal(markingOptional: "dualGrain")
    }
}

private func decodeMutatedNaturalCharcoal(
    removing identifier: String? = nil,
    markingOptional optionalIdentifier: String? = nil
) throws -> BrushDefinition {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(ProfessionalBrushCatalog.naturalCharcoal.definition)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var capabilities = try #require(object["capabilities"] as? [[String: Any]])
    if let identifier {
        capabilities.removeAll { $0["identifier"] as? String == identifier }
    }
    if let optionalIdentifier {
        let index = try #require(capabilities.firstIndex {
            $0["identifier"] as? String == optionalIdentifier
        })
        capabilities[index]["required"] = false
    }
    object["capabilities"] = capabilities
    let mutated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try JSONDecoder().decode(BrushDefinition.self, from: mutated)
}
