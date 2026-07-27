import Foundation
import Testing
@testable import PatternEngine

@Test(arguments: AnchorRecipeFixtures.all)
func legacyRecipeRoundTripsExactly(_ fixture: AnchorRecipeFixture) throws {
    let definition = try LegacyBrushRecipeAdapter.definition(from: fixture.recipe, displayName: fixture.displayName)
    let roundTrip = try LegacyBrushRecipeAdapter.recipe(from: definition)

    #expect(roundTrip == fixture.recipe)
    #expect(definition.id == fixture.recipe.id)
    #expect(definition.schemaVersion == BrushDefinition.currentSchemaVersion)
    #expect(definition.metadata == BrushMetadata(displayName: fixture.displayName))
    #expect(definition.capabilities.isEmpty)
    #expect(definition.resources.map(\.identifier).sorted() == definition.resources.map(\.identifier))
    #expect(definition.coverage.shapes == [BrushShapeLayerDefinition(shape: fixture.recipe.shape, combination: .replace, scale: 1, rotation: 0, offset: .zero)])
    #expect(definition.coverage.grains == (fixture.recipe.grain == .opaque ? [] : [BrushGrainLayerDefinition(grain: fixture.recipe.grain, coordinateMode: fixture.recipe.grainCoordinateMode, transform: fixture.recipe.grainTransform, grainMovementFraction: 0, grainFollowsBrushRotation: false, strength: 1)]))
    #expect(definition.coverage.baseHardness == fixture.recipe.baseHardness)
    #expect(definition.coverage.aspectRatio == fixture.recipe.aspectRatio)
    #expect(definition.coverage.tipThreshold == 0)
    #expect(definition.coverage.antialiasing)
    #expect(definition.placement.baseSpacingFraction == fixture.recipe.baseSpacingFraction)
    #expect(definition.placement.maximumSpacingFraction == fixture.recipe.maximumSpacingFraction)
    #expect(definition.placement.baseFlow == fixture.recipe.baseFlow)
    #expect(definition.placement.strokeOpacity == fixture.recipe.strokeOpacity)
    #expect(definition.placement.baseScatterFraction == fixture.recipe.baseScatterFraction)
    #expect(definition.placement.baseRotation == fixture.recipe.baseRotation)
    #expect(definition.placement.baseJitterFraction == 0)
    #expect(definition.placement.baseOffset == .zero)
    #expect(definition.dynamics.size == nativeMapping(fixture.recipe.sizeMapping, disabled: 1))
    #expect(definition.dynamics.flow == nativeMapping(fixture.recipe.flowMapping, disabled: 1))
    #expect(definition.dynamics.spacing == nativeMapping(fixture.recipe.spacingMapping, disabled: 1))
    #expect(definition.dynamics.rotation == nativeMapping(fixture.recipe.rotationMapping, disabled: 0))
    #expect(definition.dynamics.scatter == nativeMapping(fixture.recipe.scatterMapping, disabled: 1))
    #expect(definition.dynamics.hardness == nativeMapping(fixture.recipe.hardnessMapping, disabled: 1))
    #expect(definition.dynamics.grain == nativeMapping(fixture.recipe.grainMapping, disabled: 1))
    #expect(definition.dynamics.opacity == nativeConstant(1))
    #expect(definition.dynamics.offsetX == nativeConstant(0))
    #expect(definition.dynamics.offsetY == nativeConstant(0))
    #expect(definition.dynamics.hue == nativeConstant(0))
    #expect(definition.dynamics.saturation == nativeConstant(0))
    #expect(definition.dynamics.brightness == nativeConstant(0))
    #expect(definition.dynamics.secondaryColorMix == nativeConstant(0))
    #expect(definition.dynamics.noPressureNeutral == fixture.recipe.noPressureNeutral)
    #expect(definition.dynamics.randomization == fixture.recipe.randomization)
    #expect(definition.color.baseAdjustment == fixture.recipe.colorAdjustment)
    #expect(definition.color.perStampJitter == BrushColorJitter(hue: 0, saturation: 0, brightness: 0, secondaryColorMix: 0))
    #expect(definition.color.perStrokeJitter == BrushColorJitter(hue: 0, saturation: 0, brightness: 0, secondaryColorMix: 0))
    #expect(definition.material == expectedMaterial(fixture.recipe.material))
    #expect(definition.stabilization == fixture.recipe.stabilization)
    #expect(definition.taper == fixture.recipe.taper)
    #expect(definition.replayMode == fixture.recipe.replayMode)
    #expect(definition.replayLimits == fixture.recipe.replayLimits)
    #expect(definition.seedPolicy == .perStroke)
    #expect(definition.limits == BrushDefinitionLimits(minimumDiameter: 0.01, maximumDiameter: 16_384, maximumOpacity: 1, maximumSpacingFraction: 4, maximumResourceDimension: 4_096, maximumResidentBytes: 64 * 1_024 * 1_024))
    #expect(definition.performanceIntent == .realtime120)
    #expect(definition.compatibility == BrushCompatibilityMetadata(nativeFeatureVersion: 1, sourceSettingKeys: [], requiredSemanticKeys: []))
}

@Test func reverseAdapterRejectsEveryNativeOnlyDynamicsChannel() throws {
    let definition = try LegacyBrushRecipeAdapter.definition(from: AnchorRecipeFixtures.all[0].recipe, displayName: "Technical Ink")
    for dynamics in [
        replacing(definition.dynamics, opacity: nativeConstant(0.5)),
        replacing(definition.dynamics, offsetX: nativeConstant(1)),
        replacing(definition.dynamics, offsetY: nativeConstant(1)),
        replacing(definition.dynamics, hue: nativeConstant(1)),
        replacing(definition.dynamics, saturation: nativeConstant(1)),
        replacing(definition.dynamics, brightness: nativeConstant(1)),
        replacing(definition.dynamics, secondaryColorMix: nativeConstant(1)),
    ] {
        #expect(throws: BrushDefinitionValidationError.self) {
            try LegacyBrushRecipeAdapter.recipe(from: definition.replacing(dynamics: dynamics))
        }
    }
}

@Test func reverseAdapterRequiresChannelSpecificDisabledMappingNeutrals() throws {
    let definition = try LegacyBrushRecipeAdapter.definition(from: AnchorRecipeFixtures.all[0].recipe, displayName: "Technical Ink")
    #expect(throws: BrushDefinitionValidationError.self) {
        try LegacyBrushRecipeAdapter.recipe(from: definition.replacing(dynamics: replacing(definition.dynamics, size: nativeConstant(0))))
    }
    #expect(throws: BrushDefinitionValidationError.self) {
        try LegacyBrushRecipeAdapter.recipe(from: definition.replacing(dynamics: replacing(definition.dynamics, rotation: nativeConstant(1))))
    }
}

@Test func definitionRejectsLegacyMappingDomainAndDeclaredLimitViolations() throws {
    let definition = try BrushDefinition.fixture()
    let invalidPositive = BrushMappingDefinition(input: .pressure, response: .linear, scale: 1, offset: 0, lowerClamp: 0, upperClamp: 1, inverted: false, jitter: 0, missingInputValue: 1)
    for dynamics in [
        replacing(definition.dynamics, size: invalidPositive),
        replacing(definition.dynamics, spacing: invalidPositive),
        replacing(definition.dynamics, grain: invalidPositive),
    ] {
        #expect(throws: BrushDefinitionValidationError.self) { try definition.replacing(dynamics: dynamics) }
    }
    let tooLarge = BrushMappingDefinition(input: .pressure, response: .linear, scale: 1, offset: 0, lowerClamp: 1, upperClamp: BrushRecipePolicy.maximumMappingMagnitude + 0.01, inverted: false, jitter: 0, missingInputValue: 1)
    #expect(throws: BrushDefinitionValidationError.self) { try definition.replacing(dynamics: replacing(definition.dynamics, size: tooLarge)) }
    let rotation = BrushMappingDefinition(input: .direction, response: .linear, scale: 1, offset: 0, lowerClamp: -2 * .pi, upperClamp: 2 * .pi + 0.01, inverted: false, jitter: 0, missingInputValue: 1)
    #expect(throws: BrushDefinitionValidationError.self) { try definition.replacing(dynamics: replacing(definition.dynamics, rotation: rotation)) }
    let opacityLimits = BrushDefinitionLimits(minimumDiameter: 0.01, maximumDiameter: 10, maximumOpacity: 0.5, maximumSpacingFraction: 4, maximumResourceDimension: 64, maximumResidentBytes: 1)
    let opacityPlacement = BrushPlacementDefinition(baseSpacingFraction: 0.1, maximumSpacingFraction: 0.1, baseFlow: 1, strokeOpacity: 0.5, baseScatterFraction: 0, baseRotation: 0, baseJitterFraction: 0, baseOffset: .zero)
    #expect(throws: BrushDefinitionValidationError.self) {
        try definition.replacing(dynamics: replacing(definition.dynamics, opacity: nativeConstant(0.6)), placement: opacityPlacement, limits: opacityLimits)
    }
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(limits: BrushDefinitionLimits(minimumDiameter: 0.01, maximumDiameter: 10, maximumOpacity: 1, maximumSpacingFraction: 0.05, maximumResourceDimension: 64, maximumResidentBytes: 1))
    }
}

@Test func definitionRejectsUnknownTaperEffectBitsDuringInitialization() throws {
    let definition = try BrushDefinition.fixture()
    for effects in [BrushTaperEffects(), .size, .flow, [.size, .flow]] {
        let taper = BrushTaperConfiguration(start: .disabled, end: .disabled, minimumSize: 1, minimumFlow: 1, effects: effects)
        #expect(try definition.replacing(taper: taper).taper.effects == effects)
    }
    for rawValue: UInt8 in [4, 5, 6, 7] {
        let taper = BrushTaperConfiguration(start: .disabled, end: .disabled, minimumSize: 1, minimumFlow: 1, effects: BrushTaperEffects(rawValue: rawValue))
        #expect(throws: BrushDefinitionValidationError.self) {
            try definition.replacing(taper: taper)
        }
    }
}

@Test func definitionDecodingRejectsUnknownTaperEffectBits() throws {
    let definition = try BrushDefinition.fixture()
    let data = try JSONEncoder().encode(definition)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var taper = try #require(object["taper"] as? [String: Any])
    for rawValue in [4, 5, 6, 7] {
        taper["effects"] = rawValue
        object["taper"] = taper
        let invalidData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: Error.self) {
            try JSONDecoder().decode(BrushDefinition.self, from: invalidData)
        }
    }
}

@Test func forwardAdapterRejectsRecipeSchemasTheDefinitionCannotRepresent() throws {
    let recipe = try BrushRecipe(id: BrushRecipeID("test.schema-two"), schemaVersion: 2)
    #expect(throws: BrushDefinitionValidationError.self) {
        try LegacyBrushRecipeAdapter.definition(from: recipe, displayName: "Schema Two")
    }
}

@Test func legacyBuiltInAssetsRoundTripThroughCanonicalResources() throws {
    let shapeRecipe = try BrushRecipe(id: BrushRecipeID("test.asset.shape"), shape: .asset("builtin.shape.chisel"))
    let grainRecipe = try BrushRecipe(id: BrushRecipeID("test.asset.grain"), grain: .asset("builtin.grain.paper"))
    let combinedRecipe = try BrushRecipe(id: BrushRecipeID("test.asset.combined"), shape: .asset("builtin.shape.chisel"), grain: .asset("builtin.grain.paper"))
    for recipe in [shapeRecipe, grainRecipe, combinedRecipe] {
        let definition = try LegacyBrushRecipeAdapter.definition(from: recipe, displayName: "Asset")
        var expectedResources: [BrushResourceReference] = []
        if case let .asset(identifier) = recipe.shape {
            expectedResources.append(BrushResourceReference(identifier: identifier, kind: .shape, required: false, fallback: .builtIn(identifier: identifier)))
        }
        if case let .asset(identifier) = recipe.grain {
            expectedResources.append(BrushResourceReference(identifier: identifier, kind: .grain, required: false, fallback: .builtIn(identifier: identifier)))
        }
        expectedResources.sort { $0.identifier < $1.identifier }
        #expect(definition.resources == expectedResources)
        #expect(try LegacyBrushRecipeAdapter.recipe(from: definition) == recipe)
    }
    let definition = try LegacyBrushRecipeAdapter.definition(from: combinedRecipe, displayName: "Asset")
    let extraPreview = BrushResourceReference(identifier: "preview", kind: .preview, required: false, fallback: nil)
    #expect(throws: BrushDefinitionValidationError.self) {
        try LegacyBrushRecipeAdapter.recipe(from: definition.replacing(resources: definition.resources + [extraPreview]))
    }
}

@Test func definitionRejectsWetInteractionWithoutCapability() {
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(capabilities: [], interaction: .wetMix)
    }
}

@Test
func definitionRejectsInteractionHaloBeyondTheBoundedMaterialPolicy() throws {
    let base = try BrushDefinition.fixture(capabilities: [
        BrushCapabilityDeclaration(identifier: "smudge", required: true),
    ])
    let interaction = BrushMaterialDefinition(
        accumulation: .flow,
        interaction: .smudge,
        edgeTreatment: .none,
        strength: 1,
        wetness: 0.5,
        bleedRadius: 0,
        softenPasses: 0,
        accumulationLimit: 1,
        interactionParameters: BrushInteractionDefinition(
            pickup: 0,
            pull: 0,
            dilution: 0,
            charge: 0,
            persistence: 0,
            dirtyHaloRadius: BrushRecipePolicy.maximumWashBleedRadius + 1
        )
    )

    #expect(throws: BrushDefinitionValidationError.outOfRange(
        field: "material.dirtyHaloRadius"
    )) {
        try base.replacing(material: interaction)
    }
}

@Test func definitionRejectsInvalidCollectionAndResourceSemantics() throws {
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(capabilities: [
            BrushCapabilityDeclaration(identifier: "wetMix", required: false),
            BrushCapabilityDeclaration(identifier: "dualShape", required: false),
        ])
    }
    let forwardCapability = try BrushDefinition.fixture(capabilities: [BrushCapabilityDeclaration(identifier: "future.capability", required: true)])
    #expect(forwardCapability.capabilities.map(\.identifier) == ["future.capability"])
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(sourceSettingKeys: ["z", "a"])
    }
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(resources: [
            BrushResourceReference(identifier: "a", kind: .shape, required: false, fallback: nil),
        ])
    }
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(
            resources: [BrushResourceReference(identifier: "preview", kind: .preview, required: false, fallback: nil)],
            shape: .asset("preview")
        )
    }
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(resources: [
            BrushResourceReference(identifier: "a", kind: .shape, required: false, fallback: .builtIn(identifier: "builtin.grain.paper")),
        ])
    }
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(resources: [
            BrushResourceReference(identifier: "a", kind: .preview, required: false, fallback: nil),
            BrushResourceReference(identifier: "a", kind: .shape, required: true, fallback: nil),
        ])
    }
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(resources: [
            BrushResourceReference(identifier: "b", kind: .shape, required: false, fallback: .builtIn(identifier: "builtin.shape.hard-round")),
            BrushResourceReference(identifier: "a", kind: .grain, required: false, fallback: .builtIn(identifier: "builtin.grain.paper")),
        ])
    }
}

@Test func definitionRejectsInvalidCurvesLimitsAndSeed() {
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(response: .curve(BrushCurveDefinition(points: [
            BrushCurvePoint(x: 0, y: 0), BrushCurvePoint(x: 0, y: 1), BrushCurvePoint(x: 1, y: 1),
        ])))
    }
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(response: .curve(BrushCurveDefinition(points: [
            BrushCurvePoint(x: 0, y: .nan), BrushCurvePoint(x: 1, y: 1),
        ])))
    }
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(limits: BrushDefinitionLimits(minimumDiameter: 2, maximumDiameter: 1, maximumOpacity: 1, maximumSpacingFraction: 1, maximumResourceDimension: 64, maximumResidentBytes: 1))
    }
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(seedPolicy: .fixed(0))
    }
}

@Test func definitionRejectsNonfiniteLayerTransformsAndOutOfRangeBaseColor() throws {
    let definition = try BrushDefinition.fixture()
    let invalidShape = BrushCoverageDefinition(shapes: [BrushShapeLayerDefinition(shape: .hardRound, combination: .replace, scale: .infinity, rotation: 0, offset: .zero)], grains: [], baseHardness: 1, aspectRatio: 1, tipThreshold: 0, antialiasing: true)
    #expect(throws: BrushDefinitionValidationError.self) { try definition.replacing(coverage: invalidShape) }
    let invalidGrain = BrushCoverageDefinition(shapes: definition.coverage.shapes, grains: [BrushGrainLayerDefinition(grain: .paper, coordinateMode: .canonical, transform: BrushGrainTransform(scale: .nan, rotation: 0, offset: .zero), grainMovementFraction: 0, grainFollowsBrushRotation: false, strength: 1)], baseHardness: 1, aspectRatio: 1, tipThreshold: 0, antialiasing: true)
    #expect(throws: BrushDefinitionValidationError.self) { try definition.replacing(coverage: invalidGrain) }
    let invalidColor = BrushColorBehaviorDefinition(baseAdjustment: BrushColorAdjustment(redMultiplier: 2, greenMultiplier: 1, blueMultiplier: 1, alphaMultiplier: 1), perStampJitter: definition.color.perStampJitter, perStrokeJitter: definition.color.perStrokeJitter)
    #expect(throws: BrushDefinitionValidationError.self) { try definition.replacing(color: invalidColor) }
}

@Test func definitionCodableRoundTripIsStable() throws {
    let definition = try LegacyBrushRecipeAdapter.definition(from: AnchorRecipeFixtures.all[0].recipe, displayName: "Technical Ink")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let first = try encoder.encode(definition)
    let decoded = try JSONDecoder().decode(BrushDefinition.self, from: first)
    #expect(try encoder.encode(decoded) == first)
}

@Test func definitionDecodingIgnoresUnknownSafeKeysAndAllowsOmittedReplayLimits() throws {
    let definition = try LegacyBrushRecipeAdapter.definition(from: AnchorRecipeFixtures.all[0].recipe, displayName: "Technical Ink")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let canonical = try encoder.encode(definition)
    var object = try #require(JSONSerialization.jsonObject(with: canonical) as? [String: Any])
    object["safeFutureKey"] = ["ignored": true]
    object.removeValue(forKey: "replayLimits")
    let decoded = try JSONDecoder().decode(BrushDefinition.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.replayLimits == nil)
    #expect(try encoder.encode(decoded) == canonical)
    object.removeValue(forKey: "id")
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(BrushDefinition.self, from: JSONSerialization.data(withJSONObject: object)) }
}

private extension BrushDefinition {
    static func fixture(
        capabilities: [BrushCapabilityDeclaration] = [],
        resources: [BrushResourceReference] = [],
        response: BrushResponseDefinition = .constant(1),
        interaction: BrushInteractionMode = .none,
        shape: BrushShapeDescriptor = .hardRound,
        sourceSettingKeys: [String] = [],
        limits: BrushDefinitionLimits = BrushDefinitionLimits(minimumDiameter: 0.01, maximumDiameter: 10, maximumOpacity: 1, maximumSpacingFraction: 4, maximumResourceDimension: 64, maximumResidentBytes: 1),
        seedPolicy: BrushSeedPolicy = .perStroke
    ) throws -> BrushDefinition {
        let one = BrushMappingDefinition(input: .pressure, response: .constant(1), scale: 1, offset: 0, lowerClamp: 1, upperClamp: 1, inverted: false, jitter: 0, missingInputValue: 1)
        let zero = BrushMappingDefinition(input: .pressure, response: .constant(0), scale: 1, offset: 0, lowerClamp: 0, upperClamp: 0, inverted: false, jitter: 0, missingInputValue: 1)
        let mapping: BrushMappingDefinition
        if case let .constant(value) = response {
            mapping = BrushMappingDefinition(input: .pressure, response: response, scale: 1, offset: 0, lowerClamp: value, upperClamp: value, inverted: false, jitter: 0, missingInputValue: 1)
        } else {
            mapping = BrushMappingDefinition(input: .pressure, response: response, scale: 1, offset: 0, lowerClamp: 0, upperClamp: 1, inverted: false, jitter: 0, missingInputValue: 1)
        }
        return try BrushDefinition(
            id: BrushRecipeID("test.definition"), metadata: BrushMetadata(displayName: "Test"), capabilities: capabilities, resources: resources,
            coverage: BrushCoverageDefinition(shapes: [BrushShapeLayerDefinition(shape: shape, combination: .replace, scale: 1, rotation: 0, offset: .zero)], grains: [], baseHardness: 1, aspectRatio: 1, tipThreshold: 0, antialiasing: true),
            placement: BrushPlacementDefinition(baseSpacingFraction: 0.1, maximumSpacingFraction: 0.1, baseFlow: 1, strokeOpacity: 1, baseScatterFraction: 0, baseRotation: 0, baseJitterFraction: 0, baseOffset: .zero),
            dynamics: BrushDynamicsDefinition(size: mapping, flow: one, opacity: one, spacing: one, rotation: zero, scatter: one, hardness: one, grain: one, offsetX: zero, offsetY: zero, hue: zero, saturation: zero, brightness: zero, secondaryColorMix: zero, noPressureNeutral: 1, randomization: .none),
            color: BrushColorBehaviorDefinition(baseAdjustment: .identity, perStampJitter: BrushColorJitter(hue: 0, saturation: 0, brightness: 0, secondaryColorMix: 0), perStrokeJitter: BrushColorJitter(hue: 0, saturation: 0, brightness: 0, secondaryColorMix: 0)),
            material: BrushMaterialDefinition(accumulation: .flow, interaction: interaction, edgeTreatment: .none, strength: 1, wetness: 0, bleedRadius: 0, softenPasses: 0, accumulationLimit: 1, interactionParameters: interaction == .none ? nil : BrushInteractionDefinition(pickup: 0, pull: 0, dilution: 0, charge: 0, persistence: 0, dirtyHaloRadius: 0)),
            stabilization: 0, taper: .none, replayMode: .appendOnly, replayLimits: nil, seedPolicy: seedPolicy, limits: limits, performanceIntent: .realtime120, compatibility: BrushCompatibilityMetadata(nativeFeatureVersion: 1, sourceSettingKeys: sourceSettingKeys, requiredSemanticKeys: [])
        )
    }

    func replacing(
        dynamics: BrushDynamicsDefinition? = nil,
        coverage: BrushCoverageDefinition? = nil,
        color: BrushColorBehaviorDefinition? = nil,
        material: BrushMaterialDefinition? = nil,
        resources: [BrushResourceReference]? = nil,
        placement: BrushPlacementDefinition? = nil,
        limits: BrushDefinitionLimits? = nil,
        taper: BrushTaperConfiguration? = nil
    ) throws -> BrushDefinition {
        try BrushDefinition(
            id: id, schemaVersion: schemaVersion, metadata: metadata,
            capabilities: capabilities, resources: resources ?? self.resources,
            coverage: coverage ?? self.coverage, placement: placement ?? self.placement,
            dynamics: dynamics ?? self.dynamics, color: color ?? self.color,
            material: material ?? self.material,
            stabilization: stabilization, taper: taper ?? self.taper,
            replayMode: replayMode, replayLimits: replayLimits,
            seedPolicy: seedPolicy, limits: limits ?? self.limits,
            performanceIntent: performanceIntent, compatibility: compatibility
        )
    }
}

private func nativeConstant(_ value: Float) -> BrushMappingDefinition {
    BrushMappingDefinition(input: .pressure, response: .constant(value), scale: 1, offset: 0, lowerClamp: value, upperClamp: value, inverted: false, jitter: 0, missingInputValue: 1)
}

private func nativeMapping(_ mapping: BrushMapping, disabled: Float) -> BrushMappingDefinition {
    switch mapping.response {
    case .disabled: nativeConstant(disabled)
    case .linear: BrushMappingDefinition(input: mapping.input, response: .linear, scale: mapping.outputMaximum - mapping.outputMinimum, offset: mapping.outputMinimum, lowerClamp: mapping.outputMinimum, upperClamp: mapping.outputMaximum, inverted: false, jitter: 0, missingInputValue: 1)
    case .boundedPower: BrushMappingDefinition(input: mapping.input, response: .boundedPower(exponent: mapping.exponent), scale: mapping.outputMaximum - mapping.outputMinimum, offset: mapping.outputMinimum, lowerClamp: mapping.outputMinimum, upperClamp: mapping.outputMaximum, inverted: false, jitter: 0, missingInputValue: 1)
    }
}

private func expectedMaterial(_ material: BrushMaterial) -> BrushMaterialDefinition {
    let semantic: (BrushAccumulationMode, BrushEdgeTreatment) = switch material.family {
    case .ink: (.flow, .none)
    case .dry: (.flow, .dryBreakup)
    case .glaze: (.uniformGlaze, .markerOverlap)
    case .boundedWash: (.flow, .wetConcentration)
    }
    return BrushMaterialDefinition(accumulation: semantic.0, interaction: .none, edgeTreatment: semantic.1, strength: material.strength, wetness: material.wetness, bleedRadius: material.bleedRadius, softenPasses: material.softenPasses, accumulationLimit: material.accumulationLimit, interactionParameters: nil)
}

private func replacing(
    _ dynamics: BrushDynamicsDefinition,
    size: BrushMappingDefinition? = nil,
    spacing: BrushMappingDefinition? = nil,
    opacity: BrushMappingDefinition? = nil,
    rotation: BrushMappingDefinition? = nil,
    grain: BrushMappingDefinition? = nil,
    offsetX: BrushMappingDefinition? = nil,
    offsetY: BrushMappingDefinition? = nil,
    hue: BrushMappingDefinition? = nil,
    saturation: BrushMappingDefinition? = nil,
    brightness: BrushMappingDefinition? = nil,
    secondaryColorMix: BrushMappingDefinition? = nil
) -> BrushDynamicsDefinition {
    BrushDynamicsDefinition(size: size ?? dynamics.size, flow: dynamics.flow, opacity: opacity ?? dynamics.opacity, spacing: spacing ?? dynamics.spacing, rotation: rotation ?? dynamics.rotation, scatter: dynamics.scatter, hardness: dynamics.hardness, grain: grain ?? dynamics.grain, offsetX: offsetX ?? dynamics.offsetX, offsetY: offsetY ?? dynamics.offsetY, hue: hue ?? dynamics.hue, saturation: saturation ?? dynamics.saturation, brightness: brightness ?? dynamics.brightness, secondaryColorMix: secondaryColorMix ?? dynamics.secondaryColorMix, noPressureNeutral: dynamics.noPressureNeutral, randomization: dynamics.randomization)
}
