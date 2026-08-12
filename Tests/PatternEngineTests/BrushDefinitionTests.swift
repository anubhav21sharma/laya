import Foundation
import Testing
@testable import PatternEngine

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

@Test func definitionRejectsMappingDomainAndDeclaredLimitViolations() throws {
    let definition = try BrushDefinition.fixture()
    let invalidPositive = BrushMappingDefinition(input: .pressure, response: .linear, scale: 1, offset: 0, lowerClamp: 0, upperClamp: 1, inverted: false, jitter: 0, missingInputValue: 1)
    for dynamics in [
        replacing(definition.components[0].dynamics, size: invalidPositive),
        replacing(definition.components[0].dynamics, spacing: invalidPositive),
        replacing(definition.components[0].dynamics, grain: invalidPositive),
    ] {
        #expect(throws: BrushDefinitionValidationError.self) { try definition.replacing(dynamics: dynamics) }
    }
    let tooLarge = BrushMappingDefinition(input: .pressure, response: .linear, scale: 1, offset: 0, lowerClamp: 1, upperClamp: BrushRecipePolicy.maximumMappingMagnitude + 0.01, inverted: false, jitter: 0, missingInputValue: 1)
    #expect(throws: BrushDefinitionValidationError.self) { try definition.replacing(dynamics: replacing(definition.components[0].dynamics, size: tooLarge)) }
    let rotation = BrushMappingDefinition(input: .direction, response: .linear, scale: 1, offset: 0, lowerClamp: -2 * .pi, upperClamp: 2 * .pi + 0.01, inverted: false, jitter: 0, missingInputValue: 1)
    #expect(throws: BrushDefinitionValidationError.self) { try definition.replacing(dynamics: replacing(definition.components[0].dynamics, rotation: rotation)) }
    let opacityLimits = BrushDefinitionLimits(minimumDiameter: 0.01, maximumDiameter: 10, maximumOpacity: 0.5, maximumSpacingFraction: 4, maximumResourceDimension: 64, maximumResidentBytes: 1)
    let opacityPlacement = BrushPlacementDefinition(baseSpacingFraction: 0.1, maximumSpacingFraction: 0.1, baseFlow: 1, strokeOpacity: 0.5, baseScatterFraction: 0, baseRotation: 0, baseJitterFraction: 0, baseOffset: .zero)
    #expect(throws: BrushDefinitionValidationError.self) {
        try definition.replacing(dynamics: replacing(definition.components[0].dynamics, opacity: nativeConstant(0.6)), placement: opacityPlacement, limits: opacityLimits)
    }
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(limits: BrushDefinitionLimits(minimumDiameter: 0.01, maximumDiameter: 10, maximumOpacity: 1, maximumSpacingFraction: 0.05, maximumResourceDimension: 64, maximumResidentBytes: 1))
    }
}

@Test func definitionRejectsUnknownTaperEffectBitsDuringInitialization() throws {
    let definition = try BrushDefinition.fixture()
    for effects in [BrushTaperEffects(), .size, .flow, [.size, .flow]] {
        let taper = BrushTaperConfiguration(start: .disabled, end: .disabled, minimumSize: 1, minimumFlow: 1, effects: effects)
        #expect(try definition.replacing(taper: taper).components[0].taper.effects == effects)
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
    var components = try #require(object["components"] as? [[String: Any]])
    var taper = try #require(components[0]["taper"] as? [String: Any])
    for rawValue in [4, 5, 6, 7] {
        taper["effects"] = rawValue
        components[0]["taper"] = taper
        object["components"] = components
        let invalidData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: Error.self) {
            try JSONDecoder().decode(BrushDefinition.self, from: invalidData)
        }
    }
}

@Test func definitionRejectsWetInteractionWithoutCapability() {
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(capabilities: [], interaction: .wetMix)
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
    let invalidGrain = BrushCoverageDefinition(shapes: definition.components[0].coverage.shapes, grains: [BrushGrainLayerDefinition(grain: .paper, coordinateMode: .canonical, transform: BrushGrainTransform(scale: .nan, rotation: 0, offset: .zero), grainMovementFraction: 0, grainFollowsBrushRotation: false, strength: 1)], baseHardness: 1, aspectRatio: 1, tipThreshold: 0, antialiasing: true)
    #expect(throws: BrushDefinitionValidationError.self) { try definition.replacing(coverage: invalidGrain) }
    let invalidColor = BrushColorBehaviorDefinition(baseAdjustment: BrushColorAdjustment(redMultiplier: 2, greenMultiplier: 1, blueMultiplier: 1, alphaMultiplier: 1), perStampJitter: definition.components[0].color.perStampJitter, perStrokeJitter: definition.components[0].color.perStrokeJitter)
    #expect(throws: BrushDefinitionValidationError.self) { try definition.replacing(color: invalidColor) }
}

@Test func definitionPreservesDualLayersAndValidatesDeclaredCapabilities() throws {
    let base = try BrushDefinition.fixture()
    let twoShapes = BrushCoverageDefinition(
        shapes: [
            BrushShapeLayerDefinition(shape: .hardRound, combination: .replace, scale: 1, rotation: 0, offset: .zero),
            BrushShapeLayerDefinition(shape: .softRound, combination: .multiply, scale: 1, rotation: 0, offset: .zero),
        ],
        grains: [], baseHardness: 1, aspectRatio: 1, tipThreshold: 0, antialiasing: true
    )
    let twoGrains = BrushCoverageDefinition(
        shapes: base.components[0].coverage.shapes,
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
    let definition = AnchorDefinitionFixtures.all[0].definition
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let first = try encoder.encode(definition)
    let decoded = try JSONDecoder().decode(BrushDefinition.self, from: first)
    #expect(try encoder.encode(decoded) == first)
}

@Test func definitionDecodingIgnoresUnknownSafeKeysAndAllowsOmittedReplayLimits() throws {
    let definition = AnchorDefinitionFixtures.all[0].definition
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

@Test func schemaV3DefinitionEncodesOnlyTheComponentWireLayout() throws {
    let definition = try BrushDefinition.stageCV2Fixture()
    let data = try JSONEncoder().encode(definition)
    let decoded = try JSONDecoder().decode(BrushDefinition.self, from: data)
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(BrushDefinition.currentSchemaVersion == 3)
    #expect(definition.schemaVersion == 3)
    #expect(decoded == definition)
    #expect(object["composition"] != nil)
    #expect((object["components"] as? [[String: Any]])?.count == 1)
    for retiredRootKey in [
        "resources", "coverage", "placement", "dynamics", "color",
        "material", "taper", "sensorProgram", "emission", "components.0.tipSupports",
    ] {
        #expect(object[retiredRootKey] == nil)
    }
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
        field: "components.0.sensorProgram.outputs"
    )) {
        _ = try BrushDefinition.stageCV2Fixture(
            sensorProgram: BrushSensorProgramDefinition(outputs: [
                .size: BrushOutputProgramDefinition(baseValue: 1, terms: []),
            ])
        )
    }
    #expect(throws: BrushDefinitionValidationError.invalidMapping(
        field: "components.0.sensorProgram.size.terms"
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
        field: "components.0.emission.timeInterval"
    )) {
        _ = try BrushDefinition.stageCV2Fixture(
            emission: BrushEmissionDefinition(mode: .time, timeInterval: nil)
        )
    }
    #expect(base.schemaVersion == BrushDefinition.currentSchemaVersion)
}

@Test(arguments: [UInt16(1), UInt16(2), UInt16(4)])
func definitionEnvelopeRejectsEveryNoncurrentVersionBeforeFieldDecode(
    _ schemaVersion: UInt16
) {
    let data = Data(#"{"schemaVersion":\#(schemaVersion)}"#.utf8)
    #expect(
        throws: BrushDefinitionValidationError.unsupportedSchemaVersion(
            schemaVersion
        )
    ) {
        _ = try JSONDecoder().decode(BrushDefinition.self, from: data)
    }
}

@Test func schemaV3AcceptsOneOrTwoOrderedDryComponents() throws {
    let base = try BrushDefinition.fixture()
    let primary = base.component(identifier: "primary", ordinal: 0)
    let texture = base.component(identifier: "texture", ordinal: 1)

    let single = try base.replacing(components: [primary])
    let composite = try base.replacing(components: [primary, texture])

    #expect(single.components.map(\.identifier.rawValue) == ["primary"])
    #expect(composite.components.map(\.identifier.rawValue) == [
        "primary", "texture",
    ])
    #expect(composite.components.map(\.ordinal) == [0, 1])
    let encoded = try JSONEncoder().encode(composite)
    #expect(try JSONDecoder().decode(BrushDefinition.self, from: encoded) == composite)
}

@Test func schemaV3RejectsInvalidComponentTopologyAndMaterial() throws {
    let base = try BrushDefinition.fixture()
    let primary = base.component(identifier: "primary", ordinal: 0)
    let texture = base.component(identifier: "texture", ordinal: 1)

    #expect(throws: BrushDefinitionValidationError.invalidComponentCount(
        actual: 0,
        maximum: 2
    )) {
        _ = try base.replacing(components: [])
    }
    #expect(throws: BrushDefinitionValidationError.invalidComponentCount(
        actual: 3,
        maximum: 2
    )) {
        _ = try base.replacing(components: [
            primary,
            texture,
            base.component(identifier: "third", ordinal: 2),
        ])
    }
    #expect(throws: BrushDefinitionValidationError.duplicateComponentIdentifier(
        "primary"
    )) {
        _ = try base.replacing(components: [
            primary,
            base.component(identifier: "primary", ordinal: 1),
        ])
    }
    #expect(throws: BrushDefinitionValidationError.invalidComponentOrdinal(
        expected: 1,
        actual: 2
    )) {
        _ = try base.replacing(components: [
            primary,
            base.component(identifier: "texture", ordinal: 2),
        ])
    }
    for identifier in ["", "../texture", "texture layer"] {
        #expect(throws: BrushDefinitionValidationError.invalidComponentIdentifier(
            identifier
        )) {
            _ = try base.replacing(components: [
                base.component(identifier: identifier, ordinal: 0),
            ])
        }
    }
    let wet = BrushMaterialDefinition(
        accumulation: .flow,
        interaction: .smudge,
        edgeTreatment: .none,
        strength: 1,
        wetness: 0,
        bleedRadius: 0,
        softenPasses: 0,
        accumulationLimit: 1,
        interactionParameters: BrushInteractionDefinition(
            pickup: 0,
            pull: 0,
            dilution: 0,
            charge: 0,
            persistence: 0,
            dirtyHaloRadius: 0
        )
    )
    #expect(throws: BrushDefinitionValidationError.unsupportedComponentInteraction(
        ordinal: 0,
        interaction: .smudge
    )) {
        _ = try base.replacing(components: [
            base.component(
                identifier: "primary",
                ordinal: 0,
                material: wet
            ),
        ])
    }

    let invalidMaterial = BrushMaterialDefinition(
        accumulation: .flow,
        interaction: .none,
        edgeTreatment: .none,
        strength: .nan,
        wetness: 0,
        bleedRadius: 0,
        softenPasses: 0,
        accumulationLimit: 1,
        interactionParameters: nil
    )
    #expect(throws: BrushDefinitionValidationError.nonfinite(
        field: "components.1.material.strength"
    )) {
        _ = try base.replacing(components: [
            primary,
            base.component(
                identifier: "texture",
                ordinal: 1,
                material: invalidMaterial
            ),
        ])
    }
}

@Test func schemaV3AllowsOnlyIdenticalSharedComponentResourceReferences() throws {
    let base = try BrushDefinition.fixture()
    let coverage = BrushCoverageDefinition(
        shapes: [BrushShapeLayerDefinition(
            shape: .asset("shared.shape"),
            combination: .replace,
            scale: 1,
            rotation: 0,
            offset: .zero
        )],
        grains: [],
        baseHardness: 1,
        aspectRatio: 1,
        tipThreshold: 0,
        antialiasing: true
    )
    let optional = BrushResourceReference(
        identifier: "shared.shape",
        kind: .shape,
        required: false,
        fallback: .builtIn(identifier: "builtin.shape.hard-round")
    )
    let required = BrushResourceReference(
        identifier: "shared.shape",
        kind: .shape,
        required: true,
        fallback: nil
    )
    let primary = base.component(
        identifier: "primary",
        ordinal: 0,
        resources: [optional],
        coverage: coverage
    )
    let shared = base.component(
        identifier: "texture",
        ordinal: 1,
        resources: [optional],
        coverage: coverage
    )
    #expect(try base.replacing(components: [primary, shared]).components.count == 2)

    #expect(throws: BrushDefinitionValidationError.conflictingComponentResource(
        "shared.shape"
    )) {
        _ = try base.replacing(components: [
            primary,
            base.component(
                identifier: "texture",
                ordinal: 1,
                resources: [required],
                coverage: coverage
            ),
        ])
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
        field: "components.0.tipSupports"
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

    let constantField = "components.0.sensorProgram.rotation.response.constant"
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
        "components.0.sensorProgram.rotation.response.boundedPower.exponent"
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
    func component(
        identifier: String,
        ordinal: UInt8,
        resources: [BrushResourceReference]? = nil,
        coverage: BrushCoverageDefinition? = nil,
        material: BrushMaterialDefinition? = nil
    ) -> BrushComponentDefinition {
        let primary = components[0]
        return BrushComponentDefinition(
            identifier: BrushComponentIdentifier(identifier),
            ordinal: ordinal,
            resources: resources ?? primary.resources,
            coverage: coverage ?? primary.coverage,
            placement: primary.placement,
            dynamics: primary.dynamics,
            color: primary.color,
            material: material ?? primary.material,
            taper: primary.taper,
            sensorProgram: primary.sensorProgram,
            emission: primary.emission,
            tipSupports: primary.tipSupports
        )
    }

    func replacing(
        components: [BrushComponentDefinition]
    ) throws -> BrushDefinition {
        try BrushDefinition(
            id: id,
            metadata: metadata,
            capabilities: capabilities,
            composition: composition,
            components: components,
            stabilization: stabilization,
            replayMode: replayMode,
            replayLimits: replayLimits,
            termination: termination,
            seedPolicy: seedPolicy,
            limits: limits,
            performanceIntent: performanceIntent,
            compatibility: compatibility,
            sensorNormalization: sensorNormalization,
            stabilizationV2: stabilizationV2,
            direction: direction
        )
    }

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
            id: base.id,
            metadata: base.metadata,
            capabilities: base.capabilities,
            resources: base.components[0].resources,
            coverage: base.components[0].coverage,
            placement: base.components[0].placement,
            dynamics: base.components[0].dynamics,
            color: base.components[0].color,
            material: base.components[0].material,
            stabilization: base.stabilization,
            taper: base.components[0].taper,
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
            stabilization: 0, taper: .none, replayMode: .appendOnly, replayLimits: nil, seedPolicy: seedPolicy, limits: limits, performanceIntent: .realtime120, compatibility: BrushCompatibilityMetadata(sourceSettingKeys: sourceSettingKeys, requiredSemanticKeys: [])
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
        let primary = components[0]
        let resolvedCoverage = coverage ?? primary.coverage
        let resolvedTipSupports = coverage == nil
            ? primary.tipSupports
            : resolvedCoverage.shapes.map { layer in
                switch layer.shape {
                case .chisel: .analyticRectangle
                case .hardRound, .softRound, .asset: .analyticEllipse
                }
            }
        return try BrushDefinition(
            id: id, metadata: metadata,
            capabilities: capabilities ?? self.capabilities,
            resources: resources ?? primary.resources,
            coverage: resolvedCoverage,
            placement: placement ?? primary.placement,
            dynamics: dynamics ?? primary.dynamics,
            color: color ?? primary.color,
            material: material ?? primary.material,
            stabilization: stabilization,
            taper: taper ?? primary.taper,
            replayMode: replayMode, replayLimits: replayLimits,
            termination: termination ?? self.termination,
            seedPolicy: seedPolicy, limits: limits ?? self.limits,
            performanceIntent: performanceIntent,
            compatibility: compatibility ?? self.compatibility,
            sensorNormalization: sensorNormalization,
            sensorProgram: primary.sensorProgram,
            stabilizationV2: stabilizationV2,
            direction: direction,
            emission: primary.emission,
            tipSupports: resolvedTipSupports
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
