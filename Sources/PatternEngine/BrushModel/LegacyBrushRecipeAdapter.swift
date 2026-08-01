import Foundation
import simd

/// The only module-internal authority allowed to mark a definition as an
/// exact schema-v1 compatibility object. Public initializers never install it.
enum LegacyBrushCompatibilityAdapter {
    static func marksDecodedSchemaV1(
        schemaVersion: UInt16,
        hasEncodedTermination: Bool
    ) -> Bool {
        schemaVersion == 1 && !hasEncodedTermination
    }
}

/// Exact, temporary bridge for the built-in recipes. The neutral values below
/// are deliberately explicit so a reverse conversion can reject semantic loss.
public enum LegacyBrushRecipeAdapter {
    private static let limits = BrushDefinitionLimits(
        minimumDiameter: 0.01,
        maximumDiameter: 16_384,
        maximumOpacity: 1,
        maximumSpacingFraction: 4,
        maximumResourceDimension: 4_096,
        maximumResidentBytes: 64 * 1_024 * 1_024
    )
    private static let neutralJitter = BrushColorJitter(hue: 0, saturation: 0, brightness: 0, secondaryColorMix: 0)
    private static let neutralColor = BrushColorBehaviorDefinition(baseAdjustment: .identity, perStampJitter: neutralJitter, perStrokeJitter: neutralJitter)
    private static let neutralCompatibility = BrushCompatibilityMetadata(nativeFeatureVersion: 1, sourceSettingKeys: [], requiredSemanticKeys: [])

    public static func definition(from recipe: BrushRecipe, displayName: String) throws -> BrushDefinition {
        guard recipe.schemaVersion == BrushDefinition.currentSchemaVersion else {
            throw BrushDefinitionValidationError.semanticLoss("recipe schema version")
        }
        let coverage = BrushCoverageDefinition(
            shapes: [BrushShapeLayerDefinition(shape: recipe.shape, combination: .replace, scale: 1, rotation: 0, offset: .zero)],
            grains: recipe.grain == .opaque ? [] : [BrushGrainLayerDefinition(grain: recipe.grain, coordinateMode: recipe.grainCoordinateMode, transform: recipe.grainTransform, grainMovementFraction: 0, grainFollowsBrushRotation: false, strength: 1)],
            baseHardness: recipe.baseHardness,
            aspectRatio: recipe.aspectRatio,
            tipThreshold: 0,
            antialiasing: true
        )
        let constantZero = constant(0)
        let dynamics = BrushDynamicsDefinition(
            size: map(recipe.sizeMapping, disabled: 1, noPressureNeutral: recipe.noPressureNeutral), flow: map(recipe.flowMapping, disabled: 1, noPressureNeutral: recipe.noPressureNeutral), opacity: constant(1), spacing: map(recipe.spacingMapping, disabled: 1, noPressureNeutral: recipe.noPressureNeutral), rotation: map(recipe.rotationMapping, disabled: 0, noPressureNeutral: recipe.noPressureNeutral), scatter: map(recipe.scatterMapping, disabled: 1, noPressureNeutral: recipe.noPressureNeutral), hardness: map(recipe.hardnessMapping, disabled: 1, noPressureNeutral: recipe.noPressureNeutral), grain: map(recipe.grainMapping, disabled: 1, noPressureNeutral: recipe.noPressureNeutral), offsetX: constantZero, offsetY: constantZero, hue: constantZero, saturation: constantZero, brightness: constantZero, secondaryColorMix: constantZero, noPressureNeutral: recipe.noPressureNeutral, randomization: recipe.randomization
        )
        return try BrushDefinition(
            legacySchemaV1Compatibility: true,
            id: recipe.id,
            schemaVersion: BrushDefinition.currentSchemaVersion,
            metadata: BrushMetadata(displayName: displayName),
            capabilities: [], resources: canonicalResources(shape: recipe.shape, grain: recipe.grain), coverage: coverage,
            placement: BrushPlacementDefinition(baseSpacingFraction: recipe.baseSpacingFraction, maximumSpacingFraction: recipe.maximumSpacingFraction, baseFlow: recipe.baseFlow, strokeOpacity: recipe.strokeOpacity, baseScatterFraction: recipe.baseScatterFraction, baseRotation: recipe.baseRotation, baseJitterFraction: 0, baseOffset: .zero),
            dynamics: dynamics, color: BrushColorBehaviorDefinition(baseAdjustment: recipe.colorAdjustment, perStampJitter: neutralJitter, perStrokeJitter: neutralJitter),
            material: material(recipe.material), stabilization: recipe.stabilization, taper: recipe.taper, replayMode: recipe.replayMode, replayLimits: recipe.replayLimits, termination: .cap, seedPolicy: .perStroke, limits: limits, performanceIntent: .realtime120, compatibility: neutralCompatibility
        )
    }

    public static func recipe(from definition: BrushDefinition) throws -> BrushRecipe {
        guard definition.schemaVersion == BrushDefinition.currentSchemaVersion, definition.capabilities.isEmpty, definition.coverage.shapes.count == 1, definition.coverage.grains.count <= 1, definition.coverage.shapes[0].combination == .replace, definition.coverage.shapes[0].scale == 1, definition.coverage.shapes[0].rotation == 0, definition.coverage.shapes[0].offset == .zero, definition.coverage.tipThreshold == 0, definition.coverage.antialiasing, definition.placement.baseJitterFraction == 0, definition.placement.baseOffset == .zero, isCanonicalConstant(definition.dynamics.opacity, value: 1), isCanonicalConstant(definition.dynamics.offsetX, value: 0), isCanonicalConstant(definition.dynamics.offsetY, value: 0), isCanonicalConstant(definition.dynamics.hue, value: 0), isCanonicalConstant(definition.dynamics.saturation, value: 0), isCanonicalConstant(definition.dynamics.brightness, value: 0), isCanonicalConstant(definition.dynamics.secondaryColorMix, value: 0), definition.color.perStampJitter == neutralJitter, definition.color.perStrokeJitter == neutralJitter, definition.material.interaction == .none, definition.material.interactionParameters == nil, definition.seedPolicy == .perStroke, definition.limits == limits, definition.performanceIntent == .realtime120, isLegacyCompatible(definition.compatibility) else { throw BrushDefinitionValidationError.semanticLoss("definition contains a native-only field") }
        guard definition.hasLegacySchemaV1Compatibility else {
            throw BrushDefinitionValidationError.semanticLoss(
                "definition is not marked legacy-compatible"
            )
        }
        guard definition.termination == .cap else {
            throw BrushDefinitionValidationError.semanticLoss(
                "definition contains native termination semantics"
            )
        }
        let grain: BrushGrainDescriptor
        let coordinateMode: BrushGrainCoordinateMode
        let grainTransform: BrushGrainTransform
        if let layer = definition.coverage.grains.first {
            guard layer.grainMovementFraction == 0, !layer.grainFollowsBrushRotation, layer.strength == 1 else { throw BrushDefinitionValidationError.semanticLoss("grain layer") }
            grain = layer.grain; coordinateMode = layer.coordinateMode; grainTransform = layer.transform
        } else { grain = .opaque; coordinateMode = .canonical; grainTransform = .identity }
        guard definition.resources == canonicalResources(shape: definition.coverage.shapes[0].shape, grain: grain) else {
            throw BrushDefinitionValidationError.semanticLoss("resources")
        }
        return try BrushRecipe(
            id: definition.id, schemaVersion: definition.schemaVersion, shape: definition.coverage.shapes[0].shape, grain: grain, grainCoordinateMode: coordinateMode, grainTransform: grainTransform, material: recipeMaterial(definition.material), baseSpacingFraction: definition.placement.baseSpacingFraction, maximumSpacingFraction: definition.placement.maximumSpacingFraction, baseFlow: definition.placement.baseFlow, strokeOpacity: definition.placement.strokeOpacity, baseHardness: definition.coverage.baseHardness, baseScatterFraction: definition.placement.baseScatterFraction, baseRotation: definition.placement.baseRotation, aspectRatio: definition.coverage.aspectRatio, sizeMapping: recipeMapping(definition.dynamics.size, disabled: 1, noPressureNeutral: definition.dynamics.noPressureNeutral), flowMapping: recipeMapping(definition.dynamics.flow, disabled: 1, noPressureNeutral: definition.dynamics.noPressureNeutral), spacingMapping: recipeMapping(definition.dynamics.spacing, disabled: 1, noPressureNeutral: definition.dynamics.noPressureNeutral), rotationMapping: recipeMapping(definition.dynamics.rotation, disabled: 0, noPressureNeutral: definition.dynamics.noPressureNeutral), scatterMapping: recipeMapping(definition.dynamics.scatter, disabled: 1, noPressureNeutral: definition.dynamics.noPressureNeutral), hardnessMapping: recipeMapping(definition.dynamics.hardness, disabled: 1, noPressureNeutral: definition.dynamics.noPressureNeutral), grainMapping: recipeMapping(definition.dynamics.grain, disabled: 1, noPressureNeutral: definition.dynamics.noPressureNeutral), noPressureNeutral: definition.dynamics.noPressureNeutral, randomization: definition.dynamics.randomization, colorAdjustment: definition.color.baseAdjustment, stabilization: definition.stabilization, taper: definition.taper, replayMode: definition.replayMode, replayLimits: definition.replayLimits
        )
    }

    private static func constant(_ value: Float) -> BrushMappingDefinition { BrushMappingDefinition(input: .pressure, response: .constant(value), scale: 1, offset: 0, lowerClamp: value, upperClamp: value, inverted: false, jitter: 0, missingInputValue: 1) }
    private static func map(_ mapping: BrushMapping, disabled: Float, noPressureNeutral: Float) -> BrushMappingDefinition {
        switch mapping.response {
        case .disabled: return constant(disabled)
        case .linear: return BrushMappingDefinition(input: mapping.input, response: .linear, scale: mapping.outputMaximum - mapping.outputMinimum, offset: mapping.outputMinimum, lowerClamp: mapping.outputMinimum, upperClamp: mapping.outputMaximum, inverted: false, jitter: 0, missingInputValue: noPressureNeutral)
        case .boundedPower: return BrushMappingDefinition(input: mapping.input, response: .boundedPower(exponent: mapping.exponent), scale: mapping.outputMaximum - mapping.outputMinimum, offset: mapping.outputMinimum, lowerClamp: mapping.outputMinimum, upperClamp: mapping.outputMaximum, inverted: false, jitter: 0, missingInputValue: noPressureNeutral)
        }
    }
    private static func recipeMapping(_ mapping: BrushMappingDefinition, disabled: Float, noPressureNeutral: Float) throws -> BrushMapping {
        guard mapping.inverted == false, mapping.jitter == 0 else { throw BrushDefinitionValidationError.semanticLoss("mapping modifiers") }
        switch mapping.response {
        case .constant: guard isCanonicalConstant(mapping, value: disabled) else { throw BrushDefinitionValidationError.semanticLoss("constant mapping") }; return .disabled
        case .linear: guard mapping.offset == mapping.lowerClamp, mapping.scale == mapping.upperClamp - mapping.lowerClamp, mapping.missingInputValue == noPressureNeutral else { throw BrushDefinitionValidationError.semanticLoss("linear mapping") }; return BrushMapping(response: .linear, input: mapping.input, outputMinimum: mapping.lowerClamp, outputMaximum: mapping.upperClamp, exponent: 1)
        case let .boundedPower(exponent): guard mapping.offset == mapping.lowerClamp, mapping.scale == mapping.upperClamp - mapping.lowerClamp, mapping.missingInputValue == noPressureNeutral else { throw BrushDefinitionValidationError.semanticLoss("power mapping") }; return BrushMapping(response: .boundedPower, input: mapping.input, outputMinimum: mapping.lowerClamp, outputMaximum: mapping.upperClamp, exponent: exponent)
        case .curve: throw BrushDefinitionValidationError.semanticLoss("curve mapping")
        }
    }
    private static func isCanonicalConstant(_ mapping: BrushMappingDefinition, value: Float) -> Bool {
        guard case let .constant(responseValue) = mapping.response else { return false }
        return responseValue == value && mapping.input == .pressure && mapping.scale == 1 && mapping.offset == 0 && mapping.lowerClamp == value && mapping.upperClamp == value && !mapping.inverted && mapping.jitter == 0 && mapping.missingInputValue == 1
    }
    private static func isLegacyCompatible(_ compatibility: BrushCompatibilityMetadata) -> Bool {
        compatibility.nativeFeatureVersion == neutralCompatibility.nativeFeatureVersion
            && compatibility.requiredSemanticKeys.isEmpty
    }
    private static func canonicalResources(shape: BrushShapeDescriptor, grain: BrushGrainDescriptor) -> [BrushResourceReference] {
        var resources: [BrushResourceReference] = []
        if case let .asset(identifier) = shape { resources.append(BrushResourceReference(identifier: identifier, kind: .shape, required: false, fallback: .builtIn(identifier: identifier))) }
        if case let .asset(identifier) = grain { resources.append(BrushResourceReference(identifier: identifier, kind: .grain, required: false, fallback: .builtIn(identifier: identifier))) }
        return resources.sorted { $0.identifier < $1.identifier }
    }
    private static func material(_ material: BrushMaterial) -> BrushMaterialDefinition {
        let semantic: (BrushAccumulationMode, BrushEdgeTreatment) = switch material.family { case .ink: (.flow, .none); case .dry: (.flow, .dryBreakup); case .glaze: (.uniformGlaze, .markerOverlap); case .boundedWash: (.flow, .wetConcentration) }
        return BrushMaterialDefinition(accumulation: semantic.0, interaction: .none, edgeTreatment: semantic.1, strength: material.strength, wetness: material.wetness, bleedRadius: material.bleedRadius, softenPasses: material.softenPasses, accumulationLimit: material.accumulationLimit, interactionParameters: nil)
    }
    private static func recipeMaterial(_ material: BrushMaterialDefinition) throws -> BrushMaterial {
        let family: BrushMaterialFamily
        switch (material.accumulation, material.edgeTreatment) { case (.flow, .none): family = .ink; case (.flow, .dryBreakup): family = .dry; case (.uniformGlaze, .markerOverlap): family = .glaze; case (.flow, .wetConcentration): family = .boundedWash; default: throw BrushDefinitionValidationError.semanticLoss("material") }
        return BrushMaterial(family: family, strength: material.strength, wetness: material.wetness, bleedRadius: material.bleedRadius, softenPasses: material.softenPasses, accumulationLimit: material.accumulationLimit)
    }
}
