import Foundation
import simd

public enum BrushCapability: String, Codable, CaseIterable, Sendable {
    case dualShape, dualGrain, packagedShape, packagedGrain, canvasInteraction, smudge, wetMix
}

public struct BrushCapabilityDeclaration: Codable, Equatable, Sendable {
    public let identifier: String
    public let required: Bool
    public init(identifier: String, required: Bool) { self.identifier = identifier; self.required = required }
}

public struct BrushMetadata: Codable, Equatable, Sendable {
    public let displayName: String
    public let author: String?
    public let sourceApplication: String?
    public let sourceIdentifier: String?
    public init(displayName: String, author: String? = nil, sourceApplication: String? = nil, sourceIdentifier: String? = nil) { self.displayName = displayName; self.author = author; self.sourceApplication = sourceApplication; self.sourceIdentifier = sourceIdentifier }
}

public enum BrushResourceKind: String, Codable, Hashable, Sendable { case shape, grain, preview }
public enum BrushResourceFallback: Codable, Equatable, Hashable, Sendable {
    case builtIn(identifier: String)
    private enum Keys: String, CodingKey { case kind, identifier }
    private enum Kind: String, Codable { case builtIn }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: Keys.self); guard try c.decode(Kind.self, forKey: .kind) == .builtIn else { throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown resource fallback") }; self = .builtIn(identifier: try c.decode(String.self, forKey: .identifier)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: Keys.self); try c.encode(Kind.builtIn, forKey: .kind); if case let .builtIn(identifier) = self { try c.encode(identifier, forKey: .identifier) } }
}
public struct BrushResourceReference: Codable, Equatable, Hashable, Sendable {
    public let identifier: String; public let kind: BrushResourceKind; public let required: Bool; public let fallback: BrushResourceFallback?
    public init(identifier: String, kind: BrushResourceKind, required: Bool, fallback: BrushResourceFallback?) { self.identifier = identifier; self.kind = kind; self.required = required; self.fallback = fallback }
}
public enum BrushShapeCombinationMode: String, Codable, Equatable, Sendable { case replace, multiply, minimum, maximum }
public struct BrushShapeLayerDefinition: Codable, Equatable, Sendable {
    public let shape: BrushShapeDescriptor; public let combination: BrushShapeCombinationMode; public let scale: Float; public let rotation: Float; public let offset: SIMD2<Float>
    public init(shape: BrushShapeDescriptor, combination: BrushShapeCombinationMode, scale: Float, rotation: Float, offset: SIMD2<Float>) { self.shape = shape; self.combination = combination; self.scale = scale; self.rotation = rotation; self.offset = offset }
    private enum Keys: String, CodingKey { case shape, combination, scale, rotation, offset }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: Keys.self); self.init(shape: try c.decode(BrushShapeDescriptor.self, forKey: .shape), combination: try c.decode(BrushShapeCombinationMode.self, forKey: .combination), scale: try c.decode(Float.self, forKey: .scale), rotation: try c.decode(Float.self, forKey: .rotation), offset: try c.decode(BrushSIMD2Codable.self, forKey: .offset).value) }
    public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: Keys.self); try c.encode(shape, forKey: .shape); try c.encode(combination, forKey: .combination); try c.encode(scale, forKey: .scale); try c.encode(rotation, forKey: .rotation); try c.encode(BrushSIMD2Codable(offset), forKey: .offset) }
}
public struct BrushGrainLayerDefinition: Codable, Equatable, Sendable {
    public let grain: BrushGrainDescriptor; public let coordinateMode: BrushGrainCoordinateMode; public let transform: BrushGrainTransform; public let grainMovementFraction: Float; public let grainFollowsBrushRotation: Bool; public let strength: Float
    public init(grain: BrushGrainDescriptor, coordinateMode: BrushGrainCoordinateMode, transform: BrushGrainTransform, grainMovementFraction: Float, grainFollowsBrushRotation: Bool, strength: Float) { self.grain = grain; self.coordinateMode = coordinateMode; self.transform = transform; self.grainMovementFraction = grainMovementFraction; self.grainFollowsBrushRotation = grainFollowsBrushRotation; self.strength = strength }
}
public struct BrushCoverageDefinition: Codable, Equatable, Sendable {
    public let shapes: [BrushShapeLayerDefinition]; public let grains: [BrushGrainLayerDefinition]; public let baseHardness: Float; public let aspectRatio: Float; public let tipThreshold: Float; public let antialiasing: Bool
    public init(shapes: [BrushShapeLayerDefinition], grains: [BrushGrainLayerDefinition], baseHardness: Float, aspectRatio: Float, tipThreshold: Float, antialiasing: Bool) { self.shapes = shapes; self.grains = grains; self.baseHardness = baseHardness; self.aspectRatio = aspectRatio; self.tipThreshold = tipThreshold; self.antialiasing = antialiasing }
}
public enum BrushAccumulationMode: String, Codable, Hashable, Sendable { case opaque, flow, uniformGlaze, intenseGlaze, destinationOut }
public enum BrushInteractionMode: String, Codable, Equatable, Sendable { case none, pickup, smudge, wetMix }
public enum BrushEdgeTreatment: String, Codable, Hashable, Sendable { case none, dryBreakup, markerOverlap, wetConcentration }
public struct BrushInteractionDefinition: Codable, Equatable, Sendable { public let pickup: Float; public let pull: Float; public let dilution: Float; public let charge: Float; public let persistence: Float; public let dirtyHaloRadius: Float; public init(pickup: Float, pull: Float, dilution: Float, charge: Float, persistence: Float, dirtyHaloRadius: Float) { self.pickup = pickup; self.pull = pull; self.dilution = dilution; self.charge = charge; self.persistence = persistence; self.dirtyHaloRadius = dirtyHaloRadius } }
public struct BrushMaterialDefinition: Codable, Equatable, Sendable { public let accumulation: BrushAccumulationMode; public let interaction: BrushInteractionMode; public let edgeTreatment: BrushEdgeTreatment; public let strength: Float; public let wetness: Float; public let bleedRadius: Float; public let softenPasses: Int; public let accumulationLimit: Float; public let interactionParameters: BrushInteractionDefinition?; public init(accumulation: BrushAccumulationMode, interaction: BrushInteractionMode, edgeTreatment: BrushEdgeTreatment, strength: Float, wetness: Float, bleedRadius: Float, softenPasses: Int, accumulationLimit: Float, interactionParameters: BrushInteractionDefinition?) { self.accumulation = accumulation; self.interaction = interaction; self.edgeTreatment = edgeTreatment; self.strength = strength; self.wetness = wetness; self.bleedRadius = bleedRadius; self.softenPasses = softenPasses; self.accumulationLimit = accumulationLimit; self.interactionParameters = interactionParameters } }
public struct BrushPlacementDefinition: Codable, Equatable, Sendable {
    public let baseSpacingFraction: Float; public let maximumSpacingFraction: Float; public let baseFlow: Float; public let strokeOpacity: Float; public let baseScatterFraction: Float; public let baseRotation: Float; public let baseJitterFraction: Float; public let baseOffset: SIMD2<Float>
    public init(baseSpacingFraction: Float, maximumSpacingFraction: Float, baseFlow: Float, strokeOpacity: Float, baseScatterFraction: Float, baseRotation: Float, baseJitterFraction: Float, baseOffset: SIMD2<Float>) { self.baseSpacingFraction = baseSpacingFraction; self.maximumSpacingFraction = maximumSpacingFraction; self.baseFlow = baseFlow; self.strokeOpacity = strokeOpacity; self.baseScatterFraction = baseScatterFraction; self.baseRotation = baseRotation; self.baseJitterFraction = baseJitterFraction; self.baseOffset = baseOffset }
    private enum Keys: String, CodingKey { case baseSpacingFraction, maximumSpacingFraction, baseFlow, strokeOpacity, baseScatterFraction, baseRotation, baseJitterFraction, baseOffset }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: Keys.self); self.init(baseSpacingFraction: try c.decode(Float.self, forKey: .baseSpacingFraction), maximumSpacingFraction: try c.decode(Float.self, forKey: .maximumSpacingFraction), baseFlow: try c.decode(Float.self, forKey: .baseFlow), strokeOpacity: try c.decode(Float.self, forKey: .strokeOpacity), baseScatterFraction: try c.decode(Float.self, forKey: .baseScatterFraction), baseRotation: try c.decode(Float.self, forKey: .baseRotation), baseJitterFraction: try c.decode(Float.self, forKey: .baseJitterFraction), baseOffset: try c.decode(BrushSIMD2Codable.self, forKey: .baseOffset).value) }
    public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: Keys.self); try c.encode(baseSpacingFraction, forKey: .baseSpacingFraction); try c.encode(maximumSpacingFraction, forKey: .maximumSpacingFraction); try c.encode(baseFlow, forKey: .baseFlow); try c.encode(strokeOpacity, forKey: .strokeOpacity); try c.encode(baseScatterFraction, forKey: .baseScatterFraction); try c.encode(baseRotation, forKey: .baseRotation); try c.encode(baseJitterFraction, forKey: .baseJitterFraction); try c.encode(BrushSIMD2Codable(baseOffset), forKey: .baseOffset) }
}

public struct BrushCurvePoint: Codable, Equatable, Sendable { public let x: Float; public let y: Float; public init(x: Float, y: Float) { self.x = x; self.y = y } }
public struct BrushCurveDefinition: Codable, Equatable, Sendable { public let points: [BrushCurvePoint]; public init(points: [BrushCurvePoint]) { self.points = points } }
public enum BrushResponseDefinition: Codable, Equatable, Sendable {
    case constant(Float), linear, boundedPower(exponent: Float), curve(BrushCurveDefinition)
    private enum Keys: String, CodingKey { case kind, value, exponent, curve }
    private enum Kind: String, Codable { case constant, linear, boundedPower, curve }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: Keys.self); switch try c.decode(Kind.self, forKey: .kind) { case .constant: self = .constant(try c.decode(Float.self, forKey: .value)); case .linear: self = .linear; case .boundedPower: self = .boundedPower(exponent: try c.decode(Float.self, forKey: .exponent)); case .curve: self = .curve(try c.decode(BrushCurveDefinition.self, forKey: .curve)) } }
    public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: Keys.self); switch self { case let .constant(value): try c.encode(Kind.constant, forKey: .kind); try c.encode(value, forKey: .value); case .linear: try c.encode(Kind.linear, forKey: .kind); case let .boundedPower(exponent): try c.encode(Kind.boundedPower, forKey: .kind); try c.encode(exponent, forKey: .exponent); case let .curve(curve): try c.encode(Kind.curve, forKey: .kind); try c.encode(curve, forKey: .curve) } }
}
public struct BrushMappingDefinition: Codable, Equatable, Sendable { public let input: BrushDynamicsInput; public let response: BrushResponseDefinition; public let scale: Float; public let offset: Float; public let lowerClamp: Float; public let upperClamp: Float; public let inverted: Bool; public let jitter: Float; public let missingInputValue: Float; public init(input: BrushDynamicsInput, response: BrushResponseDefinition, scale: Float, offset: Float, lowerClamp: Float, upperClamp: Float, inverted: Bool, jitter: Float, missingInputValue: Float) { self.input = input; self.response = response; self.scale = scale; self.offset = offset; self.lowerClamp = lowerClamp; self.upperClamp = upperClamp; self.inverted = inverted; self.jitter = jitter; self.missingInputValue = missingInputValue } }
public struct BrushDynamicsDefinition: Codable, Equatable, Sendable { public let size: BrushMappingDefinition; public let flow: BrushMappingDefinition; public let opacity: BrushMappingDefinition; public let spacing: BrushMappingDefinition; public let rotation: BrushMappingDefinition; public let scatter: BrushMappingDefinition; public let hardness: BrushMappingDefinition; public let grain: BrushMappingDefinition; public let offsetX: BrushMappingDefinition; public let offsetY: BrushMappingDefinition; public let hue: BrushMappingDefinition; public let saturation: BrushMappingDefinition; public let brightness: BrushMappingDefinition; public let secondaryColorMix: BrushMappingDefinition; public let noPressureNeutral: Float; public let randomization: BrushRandomization; public init(size: BrushMappingDefinition, flow: BrushMappingDefinition, opacity: BrushMappingDefinition, spacing: BrushMappingDefinition, rotation: BrushMappingDefinition, scatter: BrushMappingDefinition, hardness: BrushMappingDefinition, grain: BrushMappingDefinition, offsetX: BrushMappingDefinition, offsetY: BrushMappingDefinition, hue: BrushMappingDefinition, saturation: BrushMappingDefinition, brightness: BrushMappingDefinition, secondaryColorMix: BrushMappingDefinition, noPressureNeutral: Float, randomization: BrushRandomization) { self.size = size; self.flow = flow; self.opacity = opacity; self.spacing = spacing; self.rotation = rotation; self.scatter = scatter; self.hardness = hardness; self.grain = grain; self.offsetX = offsetX; self.offsetY = offsetY; self.hue = hue; self.saturation = saturation; self.brightness = brightness; self.secondaryColorMix = secondaryColorMix; self.noPressureNeutral = noPressureNeutral; self.randomization = randomization } }
public struct BrushColorJitter: Codable, Equatable, Sendable { public let hue: Float; public let saturation: Float; public let brightness: Float; public let secondaryColorMix: Float; public init(hue: Float, saturation: Float, brightness: Float, secondaryColorMix: Float) { self.hue = hue; self.saturation = saturation; self.brightness = brightness; self.secondaryColorMix = secondaryColorMix } }
public struct BrushColorBehaviorDefinition: Codable, Equatable, Sendable { public let baseAdjustment: BrushColorAdjustment; public let perStampJitter: BrushColorJitter; public let perStrokeJitter: BrushColorJitter; public init(baseAdjustment: BrushColorAdjustment, perStampJitter: BrushColorJitter, perStrokeJitter: BrushColorJitter) { self.baseAdjustment = baseAdjustment; self.perStampJitter = perStampJitter; self.perStrokeJitter = perStrokeJitter } }
public enum BrushSeedPolicy: Codable, Equatable, Sendable { case perStroke, fixed(UInt64); private enum Keys: String, CodingKey { case kind, value }; private enum Kind: String, Codable { case perStroke, fixed }; public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: Keys.self); switch try c.decode(Kind.self, forKey: .kind) { case .perStroke: self = .perStroke; case .fixed: self = .fixed(try c.decode(UInt64.self, forKey: .value)) } }; public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: Keys.self); switch self { case .perStroke: try c.encode(Kind.perStroke, forKey: .kind); case let .fixed(value): try c.encode(Kind.fixed, forKey: .kind); try c.encode(value, forKey: .value) } } }
public enum BrushPerformanceIntent: String, Codable, Equatable, Sendable { case realtime120, realtime60, quality }
public struct BrushDefinitionLimits: Codable, Equatable, Sendable { public let minimumDiameter: Float; public let maximumDiameter: Float; public let maximumOpacity: Float; public let maximumSpacingFraction: Float; public let maximumResourceDimension: Int; public let maximumResidentBytes: Int; public init(minimumDiameter: Float, maximumDiameter: Float, maximumOpacity: Float, maximumSpacingFraction: Float, maximumResourceDimension: Int, maximumResidentBytes: Int) { self.minimumDiameter = minimumDiameter; self.maximumDiameter = maximumDiameter; self.maximumOpacity = maximumOpacity; self.maximumSpacingFraction = maximumSpacingFraction; self.maximumResourceDimension = maximumResourceDimension; self.maximumResidentBytes = maximumResidentBytes } }
public struct BrushCompatibilityMetadata: Codable, Equatable, Sendable { public let nativeFeatureVersion: UInt16; public let sourceSettingKeys: [String]; public let requiredSemanticKeys: [String]; public init(nativeFeatureVersion: UInt16, sourceSettingKeys: [String], requiredSemanticKeys: [String]) { self.nativeFeatureVersion = nativeFeatureVersion; self.sourceSettingKeys = sourceSettingKeys; self.requiredSemanticKeys = requiredSemanticKeys } }

public enum BrushDefinitionValidationError: Error, Equatable, Sendable { case invalidIdentity, unsupportedSchema, unsupportedSchemaVersion(UInt16), unsorted(field: String), duplicate(field: String), invalidResource(field: String), invalidCoverage(field: String), nonfinite(field: String), outOfRange(field: String), invalidMapping(field: String), invalidCurve, missingCapability(String), invalidInteraction, invalidReplay, semanticLoss(String) }

public struct BrushDefinition: Codable, Equatable, Sendable {
    public static let legacySchemaVersion: UInt16 = 1
    public static let currentSchemaVersion: UInt16 = 2

    public let id: BrushRecipeID
    public let schemaVersion: UInt16
    public let metadata: BrushMetadata
    public let capabilities: [BrushCapabilityDeclaration]
    public let resources: [BrushResourceReference]
    public let coverage: BrushCoverageDefinition
    public let placement: BrushPlacementDefinition
    public let dynamics: BrushDynamicsDefinition
    public let color: BrushColorBehaviorDefinition
    public let material: BrushMaterialDefinition
    public let stabilization: Float
    public let taper: BrushTaperConfiguration
    public let replayMode: BrushReplayMode
    public let replayLimits: BrushReplayLimits?
    public let termination: BrushTerminationDefinition
    public let seedPolicy: BrushSeedPolicy
    public let limits: BrushDefinitionLimits
    public let performanceIntent: BrushPerformanceIntent
    public let compatibility: BrushCompatibilityMetadata
    public let sensorNormalization: BrushSensorNormalizationDefinition?
    public let sensorProgram: BrushSensorProgramDefinition?
    public let stabilizationV2: BrushStabilizationDefinition?
    public let direction: BrushDirectionDefinition?
    public let emission: BrushEmissionDefinition?
    public let tipSupports: [BrushTipSupportDefinition]?

    /// This marker is deliberately absent from public initializers and the
    /// wire format. It is derived only by the schema-v1 decoder or installed
    /// by `LegacyBrushRecipeAdapter`.
    let hasLegacySchemaV1Compatibility: Bool

    public init(
        id: BrushRecipeID,
        schemaVersion: UInt16 = BrushDefinition.legacySchemaVersion,
        metadata: BrushMetadata,
        capabilities: [BrushCapabilityDeclaration],
        resources: [BrushResourceReference],
        coverage: BrushCoverageDefinition,
        placement: BrushPlacementDefinition,
        dynamics: BrushDynamicsDefinition,
        color: BrushColorBehaviorDefinition,
        material: BrushMaterialDefinition,
        stabilization: Float,
        taper: BrushTaperConfiguration,
        replayMode: BrushReplayMode,
        replayLimits: BrushReplayLimits?,
        termination: BrushTerminationDefinition = .cap,
        seedPolicy: BrushSeedPolicy,
        limits: BrushDefinitionLimits,
        performanceIntent: BrushPerformanceIntent,
        compatibility: BrushCompatibilityMetadata
    ) throws {
        try self.init(
            legacySchemaV1Compatibility: false,
            id: id,
            schemaVersion: schemaVersion,
            metadata: metadata,
            capabilities: capabilities,
            resources: resources,
            coverage: coverage,
            placement: placement,
            dynamics: dynamics,
            color: color,
            material: material,
            stabilization: stabilization,
            taper: taper,
            replayMode: replayMode,
            replayLimits: replayLimits,
            termination: termination,
            seedPolicy: seedPolicy,
            limits: limits,
            performanceIntent: performanceIntent,
            compatibility: compatibility,
            sensorNormalization: nil,
            sensorProgram: nil,
            stabilizationV2: nil,
            direction: nil,
            emission: nil,
            tipSupports: nil
        )
    }

    public init(
        v2ID id: BrushRecipeID,
        metadata: BrushMetadata,
        capabilities: [BrushCapabilityDeclaration],
        resources: [BrushResourceReference],
        coverage: BrushCoverageDefinition,
        placement: BrushPlacementDefinition,
        dynamics: BrushDynamicsDefinition,
        color: BrushColorBehaviorDefinition,
        material: BrushMaterialDefinition,
        stabilization: Float,
        taper: BrushTaperConfiguration,
        replayMode: BrushReplayMode,
        replayLimits: BrushReplayLimits?,
        termination: BrushTerminationDefinition,
        seedPolicy: BrushSeedPolicy,
        limits: BrushDefinitionLimits,
        performanceIntent: BrushPerformanceIntent,
        compatibility: BrushCompatibilityMetadata,
        sensorNormalization: BrushSensorNormalizationDefinition,
        sensorProgram: BrushSensorProgramDefinition,
        stabilizationV2: BrushStabilizationDefinition,
        direction: BrushDirectionDefinition,
        emission: BrushEmissionDefinition,
        tipSupports: [BrushTipSupportDefinition]
    ) throws {
        try self.init(
            legacySchemaV1Compatibility: false,
            id: id,
            schemaVersion: Self.currentSchemaVersion,
            metadata: metadata,
            capabilities: capabilities,
            resources: resources,
            coverage: coverage,
            placement: placement,
            dynamics: dynamics,
            color: color,
            material: material,
            stabilization: stabilization,
            taper: taper,
            replayMode: replayMode,
            replayLimits: replayLimits,
            termination: termination,
            seedPolicy: seedPolicy,
            limits: limits,
            performanceIntent: performanceIntent,
            compatibility: compatibility,
            sensorNormalization: sensorNormalization,
            sensorProgram: sensorProgram,
            stabilizationV2: stabilizationV2,
            direction: direction,
            emission: emission,
            tipSupports: tipSupports
        )
    }

    init(
        legacySchemaV1Compatibility: Bool,
        id: BrushRecipeID,
        schemaVersion: UInt16,
        metadata: BrushMetadata,
        capabilities: [BrushCapabilityDeclaration],
        resources: [BrushResourceReference],
        coverage: BrushCoverageDefinition,
        placement: BrushPlacementDefinition,
        dynamics: BrushDynamicsDefinition,
        color: BrushColorBehaviorDefinition,
        material: BrushMaterialDefinition,
        stabilization: Float,
        taper: BrushTaperConfiguration,
        replayMode: BrushReplayMode,
        replayLimits: BrushReplayLimits?,
        termination: BrushTerminationDefinition,
        seedPolicy: BrushSeedPolicy,
        limits: BrushDefinitionLimits,
        performanceIntent: BrushPerformanceIntent,
        compatibility: BrushCompatibilityMetadata,
        sensorNormalization: BrushSensorNormalizationDefinition?,
        sensorProgram: BrushSensorProgramDefinition?,
        stabilizationV2: BrushStabilizationDefinition?,
        direction: BrushDirectionDefinition?,
        emission: BrushEmissionDefinition?,
        tipSupports: [BrushTipSupportDefinition]?
    ) throws {
        try BrushDefinitionValidator.validate(
            id: id,
            schemaVersion: schemaVersion,
            metadata: metadata,
            capabilities: capabilities,
            resources: resources,
            coverage: coverage,
            placement: placement,
            dynamics: dynamics,
            color: color,
            material: material,
            stabilization: stabilization,
            taper: taper,
            replayMode: replayMode,
            replayLimits: replayLimits,
            termination: termination,
            seedPolicy: seedPolicy,
            limits: limits,
            performanceIntent: performanceIntent,
            compatibility: compatibility,
            sensorNormalization: sensorNormalization,
            sensorProgram: sensorProgram,
            stabilizationV2: stabilizationV2,
            direction: direction,
            emission: emission,
            tipSupports: tipSupports
        )
        self.id = id
        self.schemaVersion = schemaVersion
        self.metadata = metadata
        self.capabilities = capabilities
        self.resources = resources
        self.coverage = coverage
        self.placement = placement
        self.dynamics = dynamics
        self.color = color
        self.material = material
        self.stabilization = stabilization
        self.taper = taper
        self.replayMode = replayMode
        self.replayLimits = replayLimits
        self.termination = termination
        self.seedPolicy = seedPolicy
        self.limits = limits
        self.performanceIntent = performanceIntent
        self.compatibility = compatibility
        self.sensorNormalization = sensorNormalization
        self.sensorProgram = sensorProgram
        self.stabilizationV2 = stabilizationV2
        self.direction = direction
        self.emission = emission
        self.tipSupports = tipSupports
        self.hasLegacySchemaV1Compatibility =
            legacySchemaV1Compatibility
    }

    fileprivate enum Keys: String, CodingKey {
        case id, schemaVersion, metadata, capabilities, resources, coverage
        case placement, dynamics, color, material, stabilization, taper
        case replayMode, replayLimits, termination, seedPolicy, limits
        case performanceIntent, compatibility
        case sensorNormalization, sensorProgram, stabilizationV2, direction
        case emission, tipSupports
    }

    public init(from decoder: Decoder) throws {
        let envelope = try BrushDefinitionVersionEnvelope(from: decoder)
        switch envelope.schemaVersion {
        case Self.legacySchemaVersion:
            self = try BrushDefinitionV1DTO(from: decoder).definition
        case Self.currentSchemaVersion:
            self = try BrushDefinitionV2DTO(from: decoder).definition
        default:
            throw BrushDefinitionValidationError.unsupportedSchemaVersion(
                envelope.schemaVersion
            )
        }
    }

    fileprivate static func decodeDTO(
        from decoder: Decoder,
        schemaVersion: UInt16
    ) throws -> BrushDefinition {
        let container = try decoder.container(keyedBy: Keys.self)
        let taper = try container.decode(
            BrushTaperConfiguration.self,
            forKey: .taper
        )
        let replayMode = try container.decode(
            BrushReplayMode.self,
            forKey: .replayMode
        )
        let hasEncodedTermination = container.contains(.termination)
        if hasEncodedTermination,
           try container.decodeNil(forKey: .termination)
        {
            throw DecodingError.valueNotFound(
                BrushTerminationDefinition.self,
                DecodingError.Context(
                    codingPath: container.codingPath + [Keys.termination],
                    debugDescription:
                        "Explicit null termination is not supported"
                )
            )
        }
        return try BrushDefinition(
            legacySchemaV1Compatibility: LegacyBrushCompatibilityAdapter
                .marksDecodedSchemaV1(
                    schemaVersion: schemaVersion,
                    hasEncodedTermination: hasEncodedTermination
                ),
            id: container.decode(BrushRecipeID.self, forKey: .id),
            schemaVersion: schemaVersion,
            metadata: container.decode(BrushMetadata.self, forKey: .metadata),
            capabilities: container.decode(
                [BrushCapabilityDeclaration].self,
                forKey: .capabilities
            ),
            resources: container.decode(
                [BrushResourceReference].self,
                forKey: .resources
            ),
            coverage: container.decode(
                BrushCoverageDefinition.self,
                forKey: .coverage
            ),
            placement: container.decode(
                BrushPlacementDefinition.self,
                forKey: .placement
            ),
            dynamics: container.decode(
                BrushDynamicsDefinition.self,
                forKey: .dynamics
            ),
            color: container.decode(
                BrushColorBehaviorDefinition.self,
                forKey: .color
            ),
            material: container.decode(
                BrushMaterialDefinition.self,
                forKey: .material
            ),
            stabilization: container.decode(Float.self, forKey: .stabilization),
            taper: taper,
            replayMode: replayMode,
            replayLimits: container.decodeIfPresent(
                BrushReplayLimits.self,
                forKey: .replayLimits
            ),
            termination: try container.decodeIfPresent(
                BrushTerminationDefinition.self,
                forKey: .termination
            ) ?? .cap,
            seedPolicy: container.decode(BrushSeedPolicy.self, forKey: .seedPolicy),
            limits: container.decode(BrushDefinitionLimits.self, forKey: .limits),
            performanceIntent: container.decode(
                BrushPerformanceIntent.self,
                forKey: .performanceIntent
            ),
            compatibility: container.decode(
                BrushCompatibilityMetadata.self,
                forKey: .compatibility
            ),
            sensorNormalization: schemaVersion == Self.currentSchemaVersion
                ? container.decode(
                    BrushSensorNormalizationDefinition.self,
                    forKey: .sensorNormalization
                ) : nil,
            sensorProgram: schemaVersion == Self.currentSchemaVersion
                ? container.decode(
                    BrushSensorProgramDefinition.self,
                    forKey: .sensorProgram
                ) : nil,
            stabilizationV2: schemaVersion == Self.currentSchemaVersion
                ? container.decode(
                    BrushStabilizationDefinition.self,
                    forKey: .stabilizationV2
                ) : nil,
            direction: schemaVersion == Self.currentSchemaVersion
                ? container.decode(
                    BrushDirectionDefinition.self,
                    forKey: .direction
                ) : nil,
            emission: schemaVersion == Self.currentSchemaVersion
                ? container.decode(
                    BrushEmissionDefinition.self,
                    forKey: .emission
                ) : nil,
            tipSupports: schemaVersion == Self.currentSchemaVersion
                ? container.decode(
                    [BrushTipSupportDefinition].self,
                    forKey: .tipSupports
                ) : nil
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(resources, forKey: .resources)
        try container.encode(coverage, forKey: .coverage)
        try container.encode(placement, forKey: .placement)
        try container.encode(dynamics, forKey: .dynamics)
        try container.encode(color, forKey: .color)
        try container.encode(material, forKey: .material)
        try container.encode(stabilization, forKey: .stabilization)
        try container.encode(taper, forKey: .taper)
        try container.encode(replayMode, forKey: .replayMode)
        try container.encodeIfPresent(replayLimits, forKey: .replayLimits)
        if !hasLegacySchemaV1Compatibility {
            try container.encode(termination, forKey: .termination)
        }
        try container.encode(seedPolicy, forKey: .seedPolicy)
        try container.encode(limits, forKey: .limits)
        try container.encode(performanceIntent, forKey: .performanceIntent)
        try container.encode(compatibility, forKey: .compatibility)
        if schemaVersion == Self.currentSchemaVersion {
            try container.encode(sensorNormalization, forKey: .sensorNormalization)
            try container.encode(sensorProgram, forKey: .sensorProgram)
            try container.encode(stabilizationV2, forKey: .stabilizationV2)
            try container.encode(direction, forKey: .direction)
            try container.encode(emission, forKey: .emission)
            try container.encode(tipSupports, forKey: .tipSupports)
        }
    }
}

private struct BrushDefinitionVersionEnvelope: Decodable {
    let schemaVersion: UInt16
}

private struct BrushDefinitionV1DTO: Decodable {
    let definition: BrushDefinition

    init(from decoder: Decoder) throws {
        definition = try BrushDefinition.decodeDTO(
            from: decoder,
            schemaVersion: BrushDefinition.legacySchemaVersion
        )
    }
}

private struct BrushDefinitionV2DTO: Decodable {
    let definition: BrushDefinition

    init(from decoder: Decoder) throws {
        definition = try BrushDefinition.decodeDTO(
            from: decoder,
            schemaVersion: BrushDefinition.currentSchemaVersion
        )
    }
}

private enum BrushDefinitionValidator {
    static func validate(id: BrushRecipeID, schemaVersion: UInt16, metadata: BrushMetadata, capabilities: [BrushCapabilityDeclaration], resources: [BrushResourceReference], coverage: BrushCoverageDefinition, placement: BrushPlacementDefinition, dynamics: BrushDynamicsDefinition, color: BrushColorBehaviorDefinition, material: BrushMaterialDefinition, stabilization: Float, taper: BrushTaperConfiguration, replayMode: BrushReplayMode, replayLimits: BrushReplayLimits?, termination: BrushTerminationDefinition, seedPolicy: BrushSeedPolicy, limits: BrushDefinitionLimits, performanceIntent: BrushPerformanceIntent, compatibility: BrushCompatibilityMetadata, sensorNormalization: BrushSensorNormalizationDefinition?, sensorProgram: BrushSensorProgramDefinition?, stabilizationV2: BrushStabilizationDefinition?, direction: BrushDirectionDefinition?, emission: BrushEmissionDefinition?, tipSupports: [BrushTipSupportDefinition]?) throws {
        guard !id.rawValue.isEmpty, !metadata.displayName.isEmpty else { throw BrushDefinitionValidationError.invalidIdentity }
        guard schemaVersion == BrushDefinition.legacySchemaVersion
                || schemaVersion == BrushDefinition.currentSchemaVersion
        else {
            throw BrushDefinitionValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        try sortedUnique(capabilities.map(\.identifier), field: "capabilities")
        try sortedUnique(compatibility.sourceSettingKeys, field: "compatibility.sourceSettingKeys")
        try sortedUnique(compatibility.requiredSemanticKeys, field: "compatibility.requiredSemanticKeys")
        try resourcesValidation(resources, coverage: coverage)
        try coverageValidation(coverage, capabilities: capabilities)
        try limitsValidation(limits)
        try placementValidation(placement, limits: limits)
        try dynamicsValidation(dynamics, limits: limits)
        try range(color.baseAdjustment.redMultiplier, "color.baseAdjustment.redMultiplier"); try range(color.baseAdjustment.greenMultiplier, "color.baseAdjustment.greenMultiplier"); try range(color.baseAdjustment.blueMultiplier, "color.baseAdjustment.blueMultiplier"); try range(color.baseAdjustment.alphaMultiplier, "color.baseAdjustment.alphaMultiplier")
        for value in [color.perStampJitter.hue, color.perStampJitter.saturation, color.perStampJitter.brightness, color.perStampJitter.secondaryColorMix, color.perStrokeJitter.hue, color.perStrokeJitter.saturation, color.perStrokeJitter.brightness, color.perStrokeJitter.secondaryColorMix] { try finite(value, "color.jitter"); guard (0...1).contains(value) else { throw BrushDefinitionValidationError.outOfRange(field: "color.jitter") } }
        try materialValidation(material, capabilities: capabilities)
        try finite(stabilization, "stabilization"); guard stabilization >= 0, stabilization < 1 else { throw BrushDefinitionValidationError.outOfRange(field: "stabilization") }
        try taperValidation(taper)
        try replayValidation(replayMode, replayLimits, taper.end)
        try terminationValidation(termination)
        if case let .fixed(seed) = seedPolicy, seed == 0 { throw BrushDefinitionValidationError.outOfRange(field: "seedPolicy") }
        if schemaVersion == BrushDefinition.legacySchemaVersion {
            guard sensorNormalization == nil, sensorProgram == nil,
                  stabilizationV2 == nil, direction == nil, emission == nil,
                  tipSupports == nil
            else { throw BrushDefinitionValidationError.unsupportedSchema }
        } else {
            guard let sensorNormalization, let sensorProgram,
                  let stabilizationV2, let direction, let emission,
                  let tipSupports
            else { throw BrushDefinitionValidationError.unsupportedSchema }
            try stageCValidation(
                normalization: sensorNormalization,
                program: sensorProgram,
                stabilization: stabilizationV2,
                direction: direction,
                emission: emission,
                tipSupports: tipSupports,
                shapeCount: coverage.shapes.count,
                maximumOpacity: limits.maximumOpacity
            )
        }
    }

    static func stageCValidation(
        normalization: BrushSensorNormalizationDefinition,
        program: BrushSensorProgramDefinition,
        stabilization: BrushStabilizationDefinition,
        direction: BrushDirectionDefinition,
        emission: BrushEmissionDefinition,
        tipSupports: [BrushTipSupportDefinition],
        shapeCount: Int,
        maximumOpacity: Float
    ) throws {
        guard normalization.fullScaleWorldVelocity.isFinite,
              normalization.fullScaleWorldVelocity > 0,
              normalization.fullScaleWorldVelocity <= 100_000
        else {
            throw BrushDefinitionValidationError.outOfRange(
                field: "sensorNormalization.fullScaleWorldVelocity"
            )
        }
        guard normalization.minimumVelocityDeltaTime.isFinite,
              (0.000_625...0.01).contains(
                normalization.minimumVelocityDeltaTime
              )
        else {
            throw BrushDefinitionValidationError.outOfRange(
                field: "sensorNormalization.minimumVelocityDeltaTime"
            )
        }
        guard normalization.fullScaleStrokeAge.isFinite,
              (0.001...86_400).contains(normalization.fullScaleStrokeAge)
        else {
            throw BrushDefinitionValidationError.outOfRange(
                field: "sensorNormalization.fullScaleStrokeAge"
            )
        }
        guard normalization.fullScaleStrokeDistanceInDiameters.isFinite,
              (0.001...1_000_000).contains(
                normalization.fullScaleStrokeDistanceInDiameters
              )
        else {
            throw BrushDefinitionValidationError.outOfRange(
                field: "sensorNormalization.fullScaleStrokeDistanceInDiameters"
            )
        }
        guard Set(program.outputs.keys) == Set(BrushDynamicOutput.allCases)
        else {
            throw BrushDefinitionValidationError.invalidMapping(
                field: "sensorProgram.outputs"
            )
        }
        for output in BrushDynamicOutput.allCases {
            guard let definition = program.outputs[output] else {
                throw BrushDefinitionValidationError.invalidMapping(
                    field: "sensorProgram.outputs"
                )
            }
            guard definition.terms.count <= 4 else {
                throw BrushDefinitionValidationError.invalidMapping(
                    field: "sensorProgram.\(output.rawValue).terms"
                )
            }
            try outputValueValidation(
                definition.baseValue,
                output: output,
                maximumOpacity: maximumOpacity
            )
            for term in definition.terms {
                for (field, value) in [
                    ("missingInputValue", term.missingInputValue),
                    ("responseScale", term.responseScale),
                    ("responseOffset", term.responseOffset),
                    ("responseLowerClamp", term.responseLowerClamp),
                    ("responseUpperClamp", term.responseUpperClamp),
                    ("jitter", term.jitter),
                ] {
                    guard value.isFinite else {
                        throw BrushDefinitionValidationError.nonfinite(
                            field: "sensorProgram.\(output.rawValue).\(field)"
                        )
                    }
                }
                guard (0...1).contains(term.missingInputValue),
                      term.responseLowerClamp <= term.responseUpperClamp,
                      term.jitter >= 0
                else {
                    throw BrushDefinitionValidationError.invalidMapping(
                        field: "sensorProgram.\(output.rawValue).term"
                    )
                }
                try responseValidation(
                    term.response,
                    field: "sensorProgram.\(output.rawValue).response"
                )
                if term.input == .direction || term.input == .azimuth
                    || term.input == .roll
                {
                    switch term.response {
                    case .constant:
                        break
                    case let .curve(curve):
                        guard curve.points.first?.y == curve.points.last?.y
                        else {
                            throw BrushDefinitionValidationError.invalidMapping(
                                field: "sensorProgram.\(output.rawValue).cyclicResponse"
                            )
                        }
                    case .linear:
                        guard output == .rotation || output == .hue else {
                            throw BrushDefinitionValidationError.invalidMapping(
                                field: "sensorProgram.\(output.rawValue).cyclicResponse"
                            )
                        }
                    case .boundedPower:
                        throw BrushDefinitionValidationError.invalidMapping(
                            field: "sensorProgram.\(output.rawValue).cyclicResponse"
                        )
                    }
                }
                switch output {
                case .offsetX, .offsetY:
                    guard term.operation != .multiply else {
                        throw BrushDefinitionValidationError.invalidMapping(
                            field: "sensorProgram.\(output.rawValue).operation"
                        )
                    }
                case .rotation, .hue:
                    guard term.operation == .replace
                            || term.operation == .add
                            || term.operation == .multiply
                    else {
                        throw BrushDefinitionValidationError.invalidMapping(
                            field: "sensorProgram.\(output.rawValue).operation"
                        )
                    }
                default: break
                }
            }
        }
        switch stabilization {
        case .none: break
        case let .weightedWindow(distance), let .delayed(distance):
            guard distance.isFinite,
                  (Float(1) / 1_024...4_096).contains(distance)
            else {
                throw BrushDefinitionValidationError.outOfRange(
                    field: "stabilizationV2.distance"
                )
            }
        }
        guard direction.maximumAngularStep.isFinite,
              (Float.pi / 180...Float.pi).contains(
                direction.maximumAngularStep
              )
        else {
            throw BrushDefinitionValidationError.outOfRange(
                field: "direction.maximumAngularStep"
            )
        }
        guard direction.stationaryDirection.isFinite else {
            throw BrushDefinitionValidationError.nonfinite(
                field: "direction.stationaryDirection"
            )
        }
        switch (emission.mode, emission.timeInterval) {
        case (.distance, nil): break
        case (.time, let interval?), (.distanceAndTime, let interval?):
            guard interval.isFinite, (1.0 / 240...10).contains(interval)
            else {
                throw BrushDefinitionValidationError.outOfRange(
                    field: "emission.timeInterval"
                )
            }
        default:
            throw BrushDefinitionValidationError.outOfRange(
                field: "emission.timeInterval"
            )
        }
        guard tipSupports.count == shapeCount, !tipSupports.isEmpty else {
            throw BrushDefinitionValidationError.invalidCoverage(
                field: "tipSupports"
            )
        }
    }

    static func outputValueValidation(
        _ value: Float,
        output: BrushDynamicOutput,
        maximumOpacity: Float
    ) throws {
        guard value.isFinite else {
            throw BrushDefinitionValidationError.nonfinite(
                field: "sensorProgram.\(output.rawValue).baseValue"
            )
        }
        let valid: Bool = switch output {
        case .size, .spacing, .grain:
            (Float(1) / 1_024...8).contains(value)
        case .flow, .hardness, .scatter:
            (0...8).contains(value)
        case .opacity:
            (0...maximumOpacity).contains(value)
        case .secondaryColorMix:
            (0...1).contains(value)
        case .offsetX, .offsetY:
            (-8...8).contains(value)
        case .rotation:
            true
        case .hue:
            true
        case .saturation, .brightness:
            (-1...1).contains(value)
        }
        guard valid else {
            throw BrushDefinitionValidationError.outOfRange(
                field: "sensorProgram.\(output.rawValue).baseValue"
            )
        }
    }

    static func responseValidation(
        _ response: BrushResponseDefinition,
        field: String
    ) throws {
        switch response {
        case let .constant(value):
            guard value.isFinite else {
                throw BrushDefinitionValidationError.nonfinite(
                    field: "\(field).constant"
                )
            }
            guard (0...1).contains(value) else {
                throw BrushDefinitionValidationError.outOfRange(
                    field: "\(field).constant"
                )
            }
        case .linear:
            break
        case let .boundedPower(exponent):
            guard exponent.isFinite else {
                throw BrushDefinitionValidationError.nonfinite(
                    field: "\(field).boundedPower.exponent"
                )
            }
            guard (0.125...8).contains(exponent) else {
                throw BrushDefinitionValidationError.outOfRange(
                    field: "\(field).boundedPower.exponent"
                )
            }
        case let .curve(curve):
            try curveValidation(curve)
        }
    }

    static func sortedUnique(_ values: [String], field: String) throws { guard values.allSatisfy({ !$0.isEmpty }) else { throw BrushDefinitionValidationError.invalidIdentity }; guard values == values.sorted() else { throw BrushDefinitionValidationError.unsorted(field: field) }; guard Set(values).count == values.count else { throw BrushDefinitionValidationError.duplicate(field: field) } }
    static func finite(_ value: Float, _ field: String) throws { guard value.isFinite else { throw BrushDefinitionValidationError.nonfinite(field: field) } }
    static func range(_ value: Float, _ field: String, _ values: ClosedRange<Float> = 0...1) throws { try finite(value, field); guard values.contains(value) else { throw BrushDefinitionValidationError.outOfRange(field: field) } }
    static func resourcesValidation(_ resources: [BrushResourceReference], coverage: BrushCoverageDefinition) throws {
        let ids = resources.map(\.identifier); try sortedUnique(ids, field: "resources")
        for resource in resources {
            guard !resource.identifier.isEmpty else { throw BrushDefinitionValidationError.invalidResource(field: "identifier") }
            switch resource.kind {
            case .preview: guard !resource.required, resource.fallback == nil else { throw BrushDefinitionValidationError.invalidResource(field: resource.identifier) }
            case .shape, .grain:
                if resource.required { guard resource.fallback == nil else { throw BrushDefinitionValidationError.invalidResource(field: resource.identifier) } }
                else { guard case let .builtIn(identifier)? = resource.fallback, fallbackKind(identifier) == resource.kind else { throw BrushDefinitionValidationError.invalidResource(field: resource.identifier) } }
            }
        }
        for shape in coverage.shapes { if case let .asset(identifier) = shape.shape { guard resources.contains(where: { $0.identifier == identifier && $0.kind == .shape }) else { throw BrushDefinitionValidationError.invalidResource(field: identifier) } } }
        for grain in coverage.grains { if case let .asset(identifier) = grain.grain { guard resources.contains(where: { $0.identifier == identifier && $0.kind == .grain }) else { throw BrushDefinitionValidationError.invalidResource(field: identifier) } } }
    }
    static func fallbackKind(_ identifier: String) -> BrushResourceKind? { identifier.hasPrefix("builtin.shape.") ? .shape : identifier.hasPrefix("builtin.grain.") ? .grain : nil }
    static func coverageValidation(
        _ coverage: BrushCoverageDefinition,
        capabilities: [BrushCapabilityDeclaration]
    ) throws {
        guard (1...2).contains(coverage.shapes.count), coverage.grains.count <= 2, coverage.shapes[0].combination == .replace else { throw BrushDefinitionValidationError.invalidCoverage(field: "layers") }
        let declaresDualLayerCapability = capabilities.contains(where: {
            $0.identifier == BrushCapability.dualShape.rawValue
                || $0.identifier == BrushCapability.dualGrain.rawValue
        })
        if declaresDualLayerCapability,
           coverage.shapes.count == 2,
           !capabilities.contains(where: {
               $0.identifier == BrushCapability.dualShape.rawValue && $0.required
           })
        {
            throw BrushDefinitionValidationError.missingCapability(
                BrushCapability.dualShape.rawValue
            )
        }
        if declaresDualLayerCapability,
           coverage.grains.count == 2,
           !capabilities.contains(where: {
               $0.identifier == BrushCapability.dualGrain.rawValue && $0.required
           })
        {
            throw BrushDefinitionValidationError.missingCapability(
                BrushCapability.dualGrain.rawValue
            )
        }
        if coverage.shapes.count == 2, coverage.shapes[1].combination == .replace { throw BrushDefinitionValidationError.invalidCoverage(field: "shapes[1].combination") }
        for (index, shape) in coverage.shapes.enumerated() { for (field, value) in [("coverage.shapes[\(index)].scale", shape.scale), ("coverage.shapes[\(index)].rotation", shape.rotation), ("coverage.shapes[\(index)].offset.x", shape.offset.x), ("coverage.shapes[\(index)].offset.y", shape.offset.y)] { try finite(value, field) }; guard shape.scale > 0, shape.scale <= 1_024, abs(shape.rotation) <= 2 * .pi else { throw BrushDefinitionValidationError.outOfRange(field: "coverage.shapes[\(index)]") } }
        for (index, grain) in coverage.grains.enumerated() { for (field, value) in [("coverage.grains[\(index)].transform.scale", grain.transform.scale), ("coverage.grains[\(index)].transform.rotation", grain.transform.rotation), ("coverage.grains[\(index)].transform.offset.x", grain.transform.offset.x), ("coverage.grains[\(index)].transform.offset.y", grain.transform.offset.y)] { try finite(value, field) }; guard grain.transform.scale > 0, grain.transform.scale <= 1_024, abs(grain.transform.rotation) <= 2 * .pi else { throw BrushDefinitionValidationError.outOfRange(field: "coverage.grains[\(index)].transform") }; try range(grain.grainMovementFraction, "coverage.grains[\(index)].grainMovementFraction"); try range(grain.strength, "coverage.grains[\(index)].strength") }
        try range(coverage.baseHardness, "coverage.baseHardness"); try finite(coverage.aspectRatio, "coverage.aspectRatio"); guard coverage.aspectRatio > 0, coverage.aspectRatio <= 1 else { throw BrushDefinitionValidationError.outOfRange(field: "coverage.aspectRatio") }; try range(coverage.tipThreshold, "coverage.tipThreshold")
    }
    static func limitsValidation(_ limits: BrushDefinitionLimits) throws { for (field, value) in [("limits.minimumDiameter", limits.minimumDiameter), ("limits.maximumDiameter", limits.maximumDiameter), ("limits.maximumOpacity", limits.maximumOpacity), ("limits.maximumSpacingFraction", limits.maximumSpacingFraction)] { try finite(value, field) }; guard limits.minimumDiameter > 0, limits.maximumDiameter >= limits.minimumDiameter, (0...1).contains(limits.maximumOpacity), limits.maximumSpacingFraction > 0, limits.maximumSpacingFraction <= 4, limits.maximumResourceDimension > 0, limits.maximumResidentBytes > 0 else { throw BrushDefinitionValidationError.outOfRange(field: "limits") } }
    static func placementValidation(_ placement: BrushPlacementDefinition, limits: BrushDefinitionLimits) throws { for (field, value) in [("placement.baseSpacingFraction", placement.baseSpacingFraction), ("placement.maximumSpacingFraction", placement.maximumSpacingFraction), ("placement.baseFlow", placement.baseFlow), ("placement.strokeOpacity", placement.strokeOpacity), ("placement.baseScatterFraction", placement.baseScatterFraction), ("placement.baseRotation", placement.baseRotation), ("placement.baseJitterFraction", placement.baseJitterFraction), ("placement.baseOffset.x", placement.baseOffset.x), ("placement.baseOffset.y", placement.baseOffset.y)] { try finite(value, field) }; guard placement.baseSpacingFraction > 0, placement.maximumSpacingFraction >= placement.baseSpacingFraction, placement.maximumSpacingFraction <= limits.maximumSpacingFraction, (0...1).contains(placement.baseFlow), placement.strokeOpacity >= 0, placement.strokeOpacity <= limits.maximumOpacity, (0...1).contains(placement.baseScatterFraction), (0...1).contains(placement.baseJitterFraction), abs(placement.baseRotation) <= 2 * .pi else { throw BrushDefinitionValidationError.outOfRange(field: "placement") } }
    enum MappingDomain { case positiveMultiplier, nonnegativeMultiplier, rotation, opacity, unconstrained }
    static func dynamicsValidation(_ dynamics: BrushDynamicsDefinition, limits: BrushDefinitionLimits) throws {
        let entries: [(BrushMappingDefinition, MappingDomain)] = [
            (dynamics.size, .positiveMultiplier), (dynamics.flow, .nonnegativeMultiplier), (dynamics.opacity, .opacity), (dynamics.spacing, .positiveMultiplier), (dynamics.rotation, .rotation), (dynamics.scatter, .nonnegativeMultiplier), (dynamics.hardness, .nonnegativeMultiplier), (dynamics.grain, .positiveMultiplier), (dynamics.offsetX, .unconstrained), (dynamics.offsetY, .unconstrained), (dynamics.hue, .unconstrained), (dynamics.saturation, .unconstrained), (dynamics.brightness, .unconstrained), (dynamics.secondaryColorMix, .unconstrained),
        ]
        for (mapping, domain) in entries { try mappingValidation(mapping, domain: domain, maximumOpacity: limits.maximumOpacity) }
        try range(dynamics.noPressureNeutral, "dynamics.noPressureNeutral"); for value in [dynamics.randomization.spacing, dynamics.randomization.scatter, dynamics.randomization.grain, dynamics.randomization.material] { try range(value, "dynamics.randomization") }; try finite(dynamics.randomization.rotation, "dynamics.randomization.rotation"); guard (0...Float.pi).contains(dynamics.randomization.rotation) else { throw BrushDefinitionValidationError.outOfRange(field: "dynamics.randomization.rotation") }
    }
    static func mappingValidation(_ mapping: BrushMappingDefinition, domain: MappingDomain, maximumOpacity: Float) throws {
        for (field, value) in [("mapping.scale", mapping.scale), ("mapping.offset", mapping.offset), ("mapping.lowerClamp", mapping.lowerClamp), ("mapping.upperClamp", mapping.upperClamp), ("mapping.jitter", mapping.jitter), ("mapping.missingInputValue", mapping.missingInputValue)] { try finite(value, field) }
        guard mapping.lowerClamp <= mapping.upperClamp, (0...1).contains(mapping.missingInputValue), mapping.jitter >= 0, mapping.jitter <= BrushRecipePolicy.maximumMappingMagnitude else { throw BrushDefinitionValidationError.invalidMapping(field: "mapping") }
        switch domain {
        case .positiveMultiplier: guard mapping.lowerClamp > 0, mapping.upperClamp <= BrushRecipePolicy.maximumMappingMagnitude else { throw BrushDefinitionValidationError.invalidMapping(field: "positive multiplier") }
        case .nonnegativeMultiplier: guard mapping.lowerClamp >= 0, mapping.upperClamp <= BrushRecipePolicy.maximumMappingMagnitude else { throw BrushDefinitionValidationError.invalidMapping(field: "nonnegative multiplier") }
        case .rotation: guard abs(mapping.lowerClamp) <= 2 * .pi, abs(mapping.upperClamp) <= 2 * .pi else { throw BrushDefinitionValidationError.invalidMapping(field: "rotation") }
        case .opacity: guard mapping.lowerClamp >= 0, mapping.upperClamp <= maximumOpacity else { throw BrushDefinitionValidationError.invalidMapping(field: "opacity") }
        case .unconstrained: break
        }
        switch mapping.response { case let .constant(value): try finite(value, "mapping.constant"); guard mapping.scale == 1, mapping.offset == 0, !mapping.inverted, mapping.jitter == 0, mapping.lowerClamp == value, mapping.upperClamp == value else { throw BrushDefinitionValidationError.invalidMapping(field: "constant") }; case .linear: break; case let .boundedPower(exponent): guard exponent.isFinite, exponent >= 0.125, exponent <= 8 else { throw BrushDefinitionValidationError.invalidMapping(field: "boundedPower") }; case let .curve(curve): try curveValidation(curve) }
    }
    static func curveValidation(_ curve: BrushCurveDefinition) throws { guard (2...32).contains(curve.points.count), curve.points.first?.x == 0, curve.points.last?.x == 1 else { throw BrushDefinitionValidationError.invalidCurve }; var previous: Float = -1; for point in curve.points { guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y), point.x > previous else { throw BrushDefinitionValidationError.invalidCurve }; previous = point.x } }
    static func materialValidation(
        _ material: BrushMaterialDefinition,
        capabilities: [BrushCapabilityDeclaration]
    ) throws {
        for (field, value) in [
            ("material.strength", material.strength),
            ("material.wetness", material.wetness),
            ("material.accumulationLimit", material.accumulationLimit),
        ] {
            try range(value, field)
        }
        try finite(material.bleedRadius, "material.bleedRadius")
        guard material.bleedRadius >= 0,
              material.bleedRadius <= BrushRecipePolicy.maximumWashBleedRadius,
              material.softenPasses >= 0,
              material.softenPasses <= BrushRecipePolicy.maximumWashSoftenPasses
        else {
            throw BrushDefinitionValidationError.outOfRange(field: "material")
        }
        let needed: BrushCapability? = switch material.interaction {
        case .none: nil
        case .pickup: .canvasInteraction
        case .smudge: .smudge
        case .wetMix: .wetMix
        }
        if let needed,
           !capabilities.contains(where: { $0.identifier == needed.rawValue })
        {
            throw BrushDefinitionValidationError.missingCapability(
                needed.rawValue
            )
        }
        if material.interaction == .none {
            guard material.interactionParameters == nil else {
                throw BrushDefinitionValidationError.invalidInteraction
            }
        } else {
            guard let parameters = material.interactionParameters else {
                throw BrushDefinitionValidationError.invalidInteraction
            }
            for value in [
                parameters.pickup,
                parameters.pull,
                parameters.dilution,
                parameters.charge,
                parameters.persistence,
            ] {
                try range(value, "material.interaction")
            }
            try finite(
                parameters.dirtyHaloRadius,
                "material.dirtyHaloRadius"
            )
            guard parameters.dirtyHaloRadius >= 0,
                  parameters.dirtyHaloRadius
                    <= BrushRecipePolicy.maximumWashBleedRadius
            else {
                throw BrushDefinitionValidationError.outOfRange(
                    field: "material.dirtyHaloRadius"
                )
            }
        }
    }
    static func taperValidation(_ taper: BrushTaperConfiguration) throws { for length in [taper.start, taper.end] { switch length { case .disabled: break; case let .worldPixels(value), let .diameterMultiples(value): try finite(value, "taper"); guard value > 0 else { throw BrushDefinitionValidationError.outOfRange(field: "taper") } } }; try range(taper.minimumSize, "taper.minimumSize"); try range(taper.minimumFlow, "taper.minimumFlow"); let supportedEffects = BrushTaperEffects.size.rawValue | BrushTaperEffects.flow.rawValue; guard taper.effects.rawValue & ~supportedEffects == 0 else { throw BrushDefinitionValidationError.outOfRange(field: "taper.effects") } }
    static func terminationValidation(_ termination: BrushTerminationDefinition) throws {
        switch termination {
        case .cap:
            return
        case let .pressureRelease(maximumWorldLength):
            try finite(maximumWorldLength, "termination.maximumWorldLength")
            guard maximumWorldLength > 0 else {
                throw BrushDefinitionValidationError.outOfRange(
                    field: "termination.maximumWorldLength"
                )
            }
        case let .boundedCorrection(
            maximumSamples,
            maximumWorldLength,
            maximumDabs
        ):
            try finite(maximumWorldLength, "termination.maximumWorldLength")
            let policy = BrushRecipePolicy.replayTailLimits
            guard maximumSamples > 0,
                  maximumSamples <= policy.maximumSamples,
                  maximumWorldLength > 0,
                  maximumDabs > 0,
                  maximumDabs <= policy.maximumDabs
            else {
                throw BrushDefinitionValidationError.outOfRange(
                    field: "termination.boundedCorrection"
                )
            }
        }
    }
    static func replayValidation(_ mode: BrushReplayMode, _ limits: BrushReplayLimits?, _ end: BrushTaperLength) throws { if mode == .appendOnly { guard limits == nil, { if case .disabled = end { return true }; return false }() else { throw BrushDefinitionValidationError.invalidReplay }; return }; guard let limits else { throw BrushDefinitionValidationError.invalidReplay }; let cap = mode == .replayTail ? BrushRecipePolicy.replayTailLimits : BrushRecipePolicy.wholeStrokeLimits; guard limits.maximumSamples > 0, limits.maximumSamples <= cap.maximumSamples, limits.maximumDabs > 0, limits.maximumDabs <= cap.maximumDabs, limits.maximumProjectedInstances > 0, limits.maximumProjectedInstances <= cap.maximumProjectedInstances else { throw BrushDefinitionValidationError.invalidReplay } }
}
