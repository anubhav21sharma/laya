import Foundation
import Testing
@testable import PatternEngine

@Test(arguments: AnchorRecipeFixtures.all)
func legacyRecipeRoundTripsExactly(_ fixture: AnchorRecipeFixture) throws {
    let definition = try LegacyBrushRecipeAdapter.definition(from: fixture.recipe, displayName: fixture.displayName)
    let roundTrip = try LegacyBrushRecipeAdapter.recipe(from: definition)

    #expect(roundTrip == fixture.recipe)
    #expect(definition.id == fixture.recipe.id)
    #expect(definition.schemaVersion == 1)
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

@Test
func reverseAdapterRequiresLegacyCompatibilityAndRejectsNativeTermination()
    throws
{
    let fixture = AnchorRecipeFixtures.all[0]
    let legacy = try LegacyBrushRecipeAdapter.definition(
        from: fixture.recipe,
        displayName: fixture.displayName
    )
    #expect(try LegacyBrushRecipeAdapter.recipe(from: legacy) == fixture.recipe)
    #expect(
        try BrushProgramCompiler.compile(legacy).termination
            == .legacySchemaV1Cap
    )

    for termination in [
        BrushTerminationDefinition.cap,
        .pressureRelease(maximumWorldLength: 4),
        .boundedCorrection(
            maximumSamples: 3,
            maximumWorldLength: 8,
            maximumDabs: 5
        ),
    ] {
        let native = try legacy.replacing(termination: termination)
        #expect(
            throws: BrushDefinitionValidationError.semanticLoss(
                "definition is not marked legacy-compatible"
            )
        ) {
            try LegacyBrushRecipeAdapter.recipe(from: native)
        }
    }
}

@Test func definitionDecodingRejectsExplicitNullTermination() throws {
    let definition = try BrushDefinition.fixture()
    let encoded = try JSONEncoder().encode(definition)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["termination"] = NSNull()

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            BrushDefinition.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
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

@Test func reverseAdapterAllowsDryConversionProvenance() throws {
    let fixture = AnchorRecipeFixtures.all[0]
    let definition = try LegacyBrushRecipeAdapter.definition(
        from: fixture.recipe,
        displayName: fixture.displayName
    )
    let compatibility = BrushCompatibilityMetadata(
        nativeFeatureVersion: 1,
        sourceSettingKeys: [
            "synthetic.v1.coverage.shape",
            "synthetic.v1.placement.spacing",
        ],
        requiredSemanticKeys: []
    )

    let encoder = JSONEncoder()
    var object = try #require(
        JSONSerialization.jsonObject(
            with: encoder.encode(definition)
        ) as? [String: Any]
    )
    object["compatibility"] = try JSONSerialization.jsonObject(
        with: encoder.encode(compatibility)
    )
    let decodedLegacy = try JSONDecoder().decode(
        BrushDefinition.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(
        try LegacyBrushRecipeAdapter.recipe(from: decodedLegacy)
            == fixture.recipe
    )
}

@Test func reverseAdapterRejectsUnknownVersionAndRequiredSemantics() throws {
    let definition = try LegacyBrushRecipeAdapter.definition(
        from: AnchorRecipeFixtures.all[0].recipe,
        displayName: "Technical Ink"
    )
    let unsupported = [
        BrushCompatibilityMetadata(
            nativeFeatureVersion: 2,
            sourceSettingKeys: ["synthetic.v1.placement.spacing"],
            requiredSemanticKeys: []
        ),
        BrushCompatibilityMetadata(
            nativeFeatureVersion: 1,
            sourceSettingKeys: ["synthetic.v1.material.wet"],
            requiredSemanticKeys: ["synthetic.v1.material.wet"]
        ),
    ]

    for compatibility in unsupported {
        #expect(
            throws: BrushDefinitionValidationError.semanticLoss(
                "definition contains a native-only field"
            )
        ) {
            try LegacyBrushRecipeAdapter.recipe(
                from: definition.replacing(compatibility: compatibility)
            )
        }
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

@Test
func legacyEndTaperCanOnlyEnterAProgramThroughTheNamedAdapter() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.legacy-termination"),
        taper: BrushTaperConfiguration(
            start: .disabled,
            end: .worldPixels(12),
            minimumSize: 0.25,
            minimumFlow: 0.5,
            effects: [.size, .flow]
        ),
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    let adapted = try LegacyBrushRecipeAdapter.definition(
        from: recipe,
        displayName: "Legacy"
    )
    let legacyProgram = try BrushProgramCompiler.compile(adapted)

    #expect(
        legacyProgram.termination
            == .legacySchemaV1EndTaper(
                taper: recipe.taper,
                replayLimits: BrushRecipePolicy.replayTailLimits
            )
    )

    let rebuilt = try BrushDefinition(
        id: adapted.id,
        schemaVersion: adapted.schemaVersion,
        metadata: adapted.metadata,
        capabilities: adapted.capabilities,
        resources: adapted.resources,
        coverage: adapted.coverage,
        placement: adapted.placement,
        dynamics: adapted.dynamics,
        color: adapted.color,
        material: adapted.material,
        stabilization: adapted.stabilization,
        taper: adapted.taper,
        replayMode: adapted.replayMode,
        replayLimits: adapted.replayLimits,
        termination: .cap,
        seedPolicy: adapted.seedPolicy,
        limits: adapted.limits,
        performanceIntent: adapted.performanceIntent,
        compatibility: adapted.compatibility
    )

    #expect(try BrushProgramCompiler.compile(rebuilt).termination == .cap)

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let encodedLegacy = try encoder.encode(adapted)
    let encodedNative = try encoder.encode(rebuilt)
    let legacyObject = try #require(
        JSONSerialization.jsonObject(with: encodedLegacy) as? [String: Any]
    )
    let nativeObject = try #require(
        JSONSerialization.jsonObject(with: encodedNative) as? [String: Any]
    )
    #expect(legacyObject["termination"] == nil)
    #expect(nativeObject["termination"] != nil)
    #expect(
        try BrushProgramCompiler.compile(
            decoder.decode(BrushDefinition.self, from: encodedLegacy)
        ).termination == legacyProgram.termination
    )
    #expect(
        try BrushProgramCompiler.compile(
            decoder.decode(BrushDefinition.self, from: encodedNative)
        ).termination == .cap
    )
}

@Test
func legacyEndTaperPreservesItsDeclaredWholeStrokeReplayContract() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.legacy-whole-stroke-termination"),
        taper: BrushTaperConfiguration(
            start: .disabled,
            end: .worldPixels(12),
            minimumSize: 0.25,
            minimumFlow: 0.5,
            effects: [.size, .flow]
        ),
        replayMode: .boundedWholeStroke,
        replayLimits: BrushRecipePolicy.wholeStrokeLimits
    )
    let definition = try LegacyBrushRecipeAdapter.definition(
        from: recipe,
        displayName: "Legacy Whole Stroke"
    )

    #expect(
        try BrushProgramCompiler.compile(definition).replayContract
            == BrushReplayContract(
                mode: .boundedWholeStroke,
                limits: BrushRecipePolicy.wholeStrokeLimits
            )
    )
}

@Test
func legacyReplayWithoutEndTaperPreservesItsDeclaredContract() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.legacy-replay-without-taper"),
        replayMode: .boundedWholeStroke,
        replayLimits: BrushRecipePolicy.wholeStrokeLimits
    )
    let definition = try LegacyBrushRecipeAdapter.definition(
        from: recipe,
        displayName: "Legacy Replay"
    )
    let program = try BrushProgramCompiler.compile(definition)

    #expect(
        program.termination
            == .legacySchemaV1Replay(
                mode: .boundedWholeStroke,
                replayLimits: BrushRecipePolicy.wholeStrokeLimits
            )
    )
    #expect(
        program.replayContract
            == BrushReplayContract(
                mode: .boundedWholeStroke,
                limits: BrushRecipePolicy.wholeStrokeLimits
            )
    )
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

@Test func definitionPreservesLegacyDualLayersAndValidatesDeclaredCapabilities() throws {
    let base = try BrushDefinition.fixture()
    let twoShapes = BrushCoverageDefinition(
        shapes: [
            BrushShapeLayerDefinition(shape: .hardRound, combination: .replace, scale: 1, rotation: 0, offset: .zero),
            BrushShapeLayerDefinition(shape: .softRound, combination: .multiply, scale: 1, rotation: 0, offset: .zero),
        ],
        grains: [], baseHardness: 1, aspectRatio: 1, tipThreshold: 0, antialiasing: true
    )
    let twoGrains = BrushCoverageDefinition(
        shapes: base.coverage.shapes,
        grains: [
            BrushGrainLayerDefinition(grain: .paper, coordinateMode: .canonical, transform: .identity, grainMovementFraction: 0, grainFollowsBrushRotation: false, strength: 1),
            BrushGrainLayerDefinition(grain: .noise, coordinateMode: .brushLocal, transform: .identity, grainMovementFraction: 0, grainFollowsBrushRotation: false, strength: 1),
        ],
        baseHardness: 1, aspectRatio: 1, tipThreshold: 0, antialiasing: true
    )

    #expect(
        try base.replacing(coverage: twoShapes).capabilities.isEmpty
    )
    #expect(
        try base.replacing(coverage: twoGrains).capabilities.isEmpty
    )

    for capabilities in [
        [BrushCapabilityDeclaration(identifier: "dualShape", required: false)],
        [BrushCapabilityDeclaration(identifier: "dualGrain", required: true)],
    ] {
        #expect(throws: BrushDefinitionValidationError.missingCapability("dualShape")) {
            try base.replacing(capabilities: capabilities, coverage: twoShapes)
        }
    }
    for capabilities in [
        [BrushCapabilityDeclaration(identifier: "dualGrain", required: false)],
        [BrushCapabilityDeclaration(identifier: "dualShape", required: true)],
    ] {
        #expect(throws: BrushDefinitionValidationError.missingCapability("dualGrain")) {
            try base.replacing(capabilities: capabilities, coverage: twoGrains)
        }
    }
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

@Test func schemaV2DefinitionRoundTripsEveryStageCField() throws {
    let definition = try BrushDefinition.stageCV2Fixture()
    let data = try JSONEncoder().encode(definition)
    let decoded = try JSONDecoder().decode(BrushDefinition.self, from: data)

    #expect(BrushDefinition.legacySchemaVersion == 1)
    #expect(BrushDefinition.currentSchemaVersion == 2)
    #expect(definition.schemaVersion == 2)
    #expect(decoded == definition)
    #expect(decoded.sensorNormalization?.fullScaleWorldVelocity == 2_000)
    #expect(decoded.sensorProgram?.outputs[.rotation]?.terms.count == 1)
    #expect(decoded.stabilizationV2 == .weightedWindow(distance: 8))
    #expect(decoded.direction?.maximumAngularStep == .pi / 6)
    #expect(decoded.emission == BrushEmissionDefinition(
        mode: .distanceAndTime,
        timeInterval: 1.0 / 120
    ))
    #expect(decoded.tipSupports == [.analyticEllipse])
}

@Test func schemaV2RejectsEveryStageCValidationBoundary() throws {
    let base = try BrushDefinition.fixture()
    let normalization = BrushSensorNormalizationDefinition(
        fullScaleWorldVelocity: 2_000,
        minimumVelocityDeltaTime: 0.001,
        fullScaleStrokeAge: 4,
        fullScaleStrokeDistanceInDiameters: 32
    )
    let program = BrushSensorProgramDefinition(outputs: Dictionary(
        uniqueKeysWithValues: BrushDynamicOutput.allCases.map {
            ($0, BrushOutputProgramDefinition(baseValue: 1, terms: []))
        }
    ))

    #expect(throws: BrushDefinitionValidationError.outOfRange(
        field: "sensorNormalization.fullScaleWorldVelocity"
    )) {
        _ = try BrushDefinition.stageCV2Fixture(
            normalization: BrushSensorNormalizationDefinition(
                fullScaleWorldVelocity: 100_001,
                minimumVelocityDeltaTime: normalization.minimumVelocityDeltaTime,
                fullScaleStrokeAge: normalization.fullScaleStrokeAge,
                fullScaleStrokeDistanceInDiameters:
                    normalization.fullScaleStrokeDistanceInDiameters
            )
        )
    }
    #expect(throws: BrushDefinitionValidationError.invalidMapping(
        field: "sensorProgram.outputs"
    )) {
        _ = try BrushDefinition.stageCV2Fixture(
            sensorProgram: BrushSensorProgramDefinition(outputs: [
                .size: BrushOutputProgramDefinition(baseValue: 1, terms: []),
            ])
        )
    }
    #expect(throws: BrushDefinitionValidationError.invalidMapping(
        field: "sensorProgram.size.terms"
    )) {
        let term = BrushResponseTermDefinition.fixture()
        var outputs = program.outputs
        outputs[.size] = BrushOutputProgramDefinition(
            baseValue: 1,
            terms: [term, term, term, term, term]
        )
        _ = try BrushDefinition.stageCV2Fixture(
            sensorProgram: BrushSensorProgramDefinition(outputs: outputs)
        )
    }
    #expect(throws: BrushDefinitionValidationError.outOfRange(
        field: "stabilizationV2.distance"
    )) {
        _ = try BrushDefinition.stageCV2Fixture(
            stabilizationV2: .weightedWindow(distance: 0)
        )
    }
    #expect(throws: BrushDefinitionValidationError.outOfRange(
        field: "direction.maximumAngularStep"
    )) {
        _ = try BrushDefinition.stageCV2Fixture(
            direction: BrushDirectionDefinition(
                maximumAngularStep: 0,
                stationaryDirection: 0
            )
        )
    }
    #expect(throws: BrushDefinitionValidationError.outOfRange(
        field: "emission.timeInterval"
    )) {
        _ = try BrushDefinition.stageCV2Fixture(
            emission: BrushEmissionDefinition(mode: .time, timeInterval: nil)
        )
    }
    #expect(base.schemaVersion == 1)
}

@Test func definitionEnvelopeRejectsUnsupportedVersionBeforeFieldDecode() {
    let data = Data(#"{"schemaVersion":99}"#.utf8)
    #expect(throws: BrushDefinitionValidationError.unsupportedSchemaVersion(99)) {
        _ = try JSONDecoder().decode(BrushDefinition.self, from: data)
    }
}

@Test func schemaV2NormalizationAndStabilizationBoundsAreClosedAndFinite() throws {
    for normalization in [
        BrushSensorNormalizationDefinition(
            fullScaleWorldVelocity: 0,
            minimumVelocityDeltaTime: 0.001,
            fullScaleStrokeAge: 1,
            fullScaleStrokeDistanceInDiameters: 1
        ),
        BrushSensorNormalizationDefinition(
            fullScaleWorldVelocity: .infinity,
            minimumVelocityDeltaTime: 0.001,
            fullScaleStrokeAge: 1,
            fullScaleStrokeDistanceInDiameters: 1
        ),
        BrushSensorNormalizationDefinition(
            fullScaleWorldVelocity: 1,
            minimumVelocityDeltaTime: 0.000_624,
            fullScaleStrokeAge: 1,
            fullScaleStrokeDistanceInDiameters: 1
        ),
        BrushSensorNormalizationDefinition(
            fullScaleWorldVelocity: 1,
            minimumVelocityDeltaTime: 0.011,
            fullScaleStrokeAge: 1,
            fullScaleStrokeDistanceInDiameters: 1
        ),
        BrushSensorNormalizationDefinition(
            fullScaleWorldVelocity: 1,
            minimumVelocityDeltaTime: 0.001,
            fullScaleStrokeAge: 0.000_9,
            fullScaleStrokeDistanceInDiameters: 1
        ),
        BrushSensorNormalizationDefinition(
            fullScaleWorldVelocity: 1,
            minimumVelocityDeltaTime: 0.001,
            fullScaleStrokeAge: 86_401,
            fullScaleStrokeDistanceInDiameters: 1
        ),
        BrushSensorNormalizationDefinition(
            fullScaleWorldVelocity: 1,
            minimumVelocityDeltaTime: 0.001,
            fullScaleStrokeAge: 1,
            fullScaleStrokeDistanceInDiameters: 0.000_9
        ),
        BrushSensorNormalizationDefinition(
            fullScaleWorldVelocity: 1,
            minimumVelocityDeltaTime: 0.001,
            fullScaleStrokeAge: 1,
            fullScaleStrokeDistanceInDiameters: 1_000_001
        ),
    ] {
        #expect(throws: BrushDefinitionValidationError.self) {
            _ = try BrushDefinition.stageCV2Fixture(
                normalization: normalization
            )
        }
    }
    for stabilization in [
        BrushStabilizationDefinition.weightedWindow(distance: 0),
        .weightedWindow(distance: .infinity),
        .delayed(distance: Float(1) / 2_048),
        .delayed(distance: 4_097),
    ] {
        #expect(throws: BrushDefinitionValidationError.self) {
            _ = try BrushDefinition.stageCV2Fixture(
                stabilizationV2: stabilization
            )
        }
    }
}

@Test func schemaV2DirectionEmissionAndTipSupportBoundariesReject() throws {
    for direction in [
        BrushDirectionDefinition(
            maximumAngularStep: Float.pi / 181,
            stationaryDirection: 0
        ),
        BrushDirectionDefinition(
            maximumAngularStep: Float.pi.nextUp,
            stationaryDirection: 0
        ),
        BrushDirectionDefinition(
            maximumAngularStep: Float.pi / 6,
            stationaryDirection: .nan
        ),
    ] {
        #expect(throws: BrushDefinitionValidationError.self) {
            _ = try BrushDefinition.stageCV2Fixture(direction: direction)
        }
    }
    for emission in [
        BrushEmissionDefinition(mode: .distance, timeInterval: 1),
        BrushEmissionDefinition(mode: .time, timeInterval: nil),
        BrushEmissionDefinition(mode: .time, timeInterval: 1.0 / 241),
        BrushEmissionDefinition(mode: .distanceAndTime, timeInterval: 10.1),
    ] {
        #expect(throws: BrushDefinitionValidationError.self) {
            _ = try BrushDefinition.stageCV2Fixture(emission: emission)
        }
    }
    #expect(throws: BrushDefinitionValidationError.invalidCoverage(
        field: "tipSupports"
    )) {
        _ = try BrushDefinition.stageCV2Fixture(tipSupports: [])
    }
}

@Test func schemaV2SensorProgramRejectsInvalidValuesAndOperationDomains() throws {
    func program(
        output: BrushDynamicOutput,
        baseValue: Float? = nil,
        term: BrushResponseTermDefinition? = nil
    ) -> BrushSensorProgramDefinition {
        var outputs = Dictionary(
            uniqueKeysWithValues: BrushDynamicOutput.allCases.map {
                ($0, BrushOutputProgramDefinition(baseValue: 1, terms: []))
            }
        )
        outputs[output] = BrushOutputProgramDefinition(
            baseValue: baseValue ?? (output == .rotation ? 0 : 1),
            terms: term.map { [$0] } ?? []
        )
        return BrushSensorProgramDefinition(outputs: outputs)
    }
    for (output, value) in [
        (BrushDynamicOutput.size, Float(0)),
        (.spacing, 9),
        (.offsetX, -9),
        (.opacity, 1.1),
        (.secondaryColorMix, 1.1),
        (.saturation, -1.1),
    ] {
        #expect(throws: BrushDefinitionValidationError.self) {
            _ = try BrushDefinition.stageCV2Fixture(
                sensorProgram: program(output: output, baseValue: value)
            )
        }
    }
    let multiplyOffset = BrushResponseTermDefinition(
        input: .pressure, response: .linear, inputInverted: false,
        missingInputValue: 0, responseScale: 1, responseOffset: 0,
        responseLowerClamp: -1, responseUpperClamp: 1, jitter: 0,
        operation: .multiply
    )
    let minimumRotation = BrushResponseTermDefinition(
        input: .pressure, response: .linear, inputInverted: false,
        missingInputValue: 0, responseScale: 1, responseOffset: 0,
        responseLowerClamp: -1, responseUpperClamp: 1, jitter: 0,
        operation: .minimum
    )
    for invalid in [
        program(output: .offsetX, baseValue: 0, term: multiplyOffset),
        program(output: .rotation, baseValue: 0, term: minimumRotation),
    ] {
        #expect(throws: BrushDefinitionValidationError.self) {
            _ = try BrushDefinition.stageCV2Fixture(sensorProgram: invalid)
        }
    }
    let nonperiodicDirectionCurve = BrushResponseTermDefinition(
        input: .direction,
        response: .curve(BrushCurveDefinition(points: [
            BrushCurvePoint(x: 0, y: 0),
            BrushCurvePoint(x: 1, y: 1),
        ])),
        inputInverted: false, missingInputValue: 0, responseScale: 1,
        responseOffset: 0, responseLowerClamp: 0,
        responseUpperClamp: 1, jitter: 0, operation: .replace
    )
    #expect(throws: BrushDefinitionValidationError.self) {
        _ = try BrushDefinition.stageCV2Fixture(
            sensorProgram: program(
                output: .rotation,
                baseValue: 0,
                term: nonperiodicDirectionCurve
            )
        )
    }
}

@Test func schemaV2RejectsNonfiniteOrOutOfDomainResponsePayloads() throws {
    func program(
        response: BrushResponseDefinition
    ) -> BrushSensorProgramDefinition {
        var outputs = Dictionary(
            uniqueKeysWithValues: BrushDynamicOutput.allCases.map {
                ($0, BrushOutputProgramDefinition(
                    baseValue: $0 == .rotation ? 0 : 1,
                    terms: []
                ))
            }
        )
        outputs[.rotation] = BrushOutputProgramDefinition(
            baseValue: 0,
            terms: [BrushResponseTermDefinition(
                input: .pressure,
                response: response,
                inputInverted: false,
                missingInputValue: 0,
                responseScale: 1,
                responseOffset: 0,
                responseLowerClamp: 0,
                responseUpperClamp: 1,
                jitter: 0,
                operation: .add
            )]
        )
        return BrushSensorProgramDefinition(outputs: outputs)
    }

    let constantField = "sensorProgram.rotation.response.constant"
    for value in [Float.nan, .infinity, -.infinity] {
        #expect(throws: BrushDefinitionValidationError.nonfinite(
            field: constantField
        )) {
            _ = try BrushDefinition.stageCV2Fixture(
                sensorProgram: program(response: .constant(value))
            )
        }
    }
    for value in [-Float.ulpOfOne, Float(1).nextUp] {
        #expect(throws: BrushDefinitionValidationError.outOfRange(
            field: constantField
        )) {
            _ = try BrushDefinition.stageCV2Fixture(
                sensorProgram: program(response: .constant(value))
            )
        }
    }

    let exponentField =
        "sensorProgram.rotation.response.boundedPower.exponent"
    for exponent in [Float.nan, .infinity, -.infinity] {
        #expect(throws: BrushDefinitionValidationError.nonfinite(
            field: exponentField
        )) {
            _ = try BrushDefinition.stageCV2Fixture(
                sensorProgram: program(
                    response: .boundedPower(exponent: exponent)
                )
            )
        }
    }
    for exponent in [Float(0.125).nextDown, Float(8).nextUp] {
        #expect(throws: BrushDefinitionValidationError.outOfRange(
            field: exponentField
        )) {
            _ = try BrushDefinition.stageCV2Fixture(
                sensorProgram: program(
                    response: .boundedPower(exponent: exponent)
                )
            )
        }
    }
}

private extension BrushDefinition {
    static func stageCV2Fixture(
        normalization: BrushSensorNormalizationDefinition =
            BrushSensorNormalizationDefinition(
                fullScaleWorldVelocity: 2_000,
                minimumVelocityDeltaTime: 0.001,
                fullScaleStrokeAge: 4,
                fullScaleStrokeDistanceInDiameters: 32
            ),
        sensorProgram: BrushSensorProgramDefinition? = nil,
        stabilizationV2: BrushStabilizationDefinition =
            .weightedWindow(distance: 8),
        direction: BrushDirectionDefinition = BrushDirectionDefinition(
            maximumAngularStep: .pi / 6,
            stationaryDirection: 0
        ),
        emission: BrushEmissionDefinition = BrushEmissionDefinition(
            mode: .distanceAndTime,
            timeInterval: 1.0 / 120
        ),
        tipSupports: [BrushTipSupportDefinition] = [.analyticEllipse]
    ) throws -> BrushDefinition {
        let base = try fixture()
        var outputs = Dictionary(
            uniqueKeysWithValues: BrushDynamicOutput.allCases.map {
                ($0, BrushOutputProgramDefinition(baseValue: 1, terms: []))
            }
        )
        outputs[.rotation] = BrushOutputProgramDefinition(
            baseValue: 0,
            terms: [.fixture()]
        )
        return try BrushDefinition(
            v2ID: base.id,
            metadata: base.metadata,
            capabilities: base.capabilities,
            resources: base.resources,
            coverage: base.coverage,
            placement: base.placement,
            dynamics: base.dynamics,
            color: base.color,
            material: base.material,
            stabilization: base.stabilization,
            taper: base.taper,
            replayMode: base.replayMode,
            replayLimits: base.replayLimits,
            termination: base.termination,
            seedPolicy: base.seedPolicy,
            limits: base.limits,
            performanceIntent: base.performanceIntent,
            compatibility: base.compatibility,
            sensorNormalization: normalization,
            sensorProgram: sensorProgram
                ?? BrushSensorProgramDefinition(outputs: outputs),
            stabilizationV2: stabilizationV2,
            direction: direction,
            emission: emission,
            tipSupports: tipSupports
        )
    }

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
        capabilities: [BrushCapabilityDeclaration]? = nil,
        coverage: BrushCoverageDefinition? = nil,
        color: BrushColorBehaviorDefinition? = nil,
        material: BrushMaterialDefinition? = nil,
        resources: [BrushResourceReference]? = nil,
        placement: BrushPlacementDefinition? = nil,
        limits: BrushDefinitionLimits? = nil,
        taper: BrushTaperConfiguration? = nil,
        compatibility: BrushCompatibilityMetadata? = nil,
        termination: BrushTerminationDefinition? = nil
    ) throws -> BrushDefinition {
        try BrushDefinition(
            id: id, schemaVersion: schemaVersion, metadata: metadata,
            capabilities: capabilities ?? self.capabilities, resources: resources ?? self.resources,
            coverage: coverage ?? self.coverage, placement: placement ?? self.placement,
            dynamics: dynamics ?? self.dynamics, color: color ?? self.color,
            material: material ?? self.material,
            stabilization: stabilization, taper: taper ?? self.taper,
            replayMode: replayMode, replayLimits: replayLimits,
            termination: termination ?? self.termination,
            seedPolicy: seedPolicy, limits: limits ?? self.limits,
            performanceIntent: performanceIntent,
            compatibility: compatibility ?? self.compatibility
        )
    }
}

private extension BrushResponseTermDefinition {
    static func fixture() -> BrushResponseTermDefinition {
        BrushResponseTermDefinition(
            input: .direction,
            response: .linear,
            inputInverted: false,
            missingInputValue: 0,
            responseScale: 1,
            responseOffset: 0,
            responseLowerClamp: -.pi,
            responseUpperClamp: .pi,
            jitter: 0,
            operation: .replace
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
