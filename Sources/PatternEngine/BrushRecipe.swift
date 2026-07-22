import Foundation
import simd

public struct BrushRecipeID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }
}

public enum BrushShapeDescriptor: Equatable, Sendable {
    case hardRound
    case softRound
    case chisel
    case asset(String)
}

public enum BrushGrainDescriptor: Equatable, Sendable {
    case opaque
    case paper
    case noise
    case asset(String)
}

public enum BrushGrainCoordinateMode: UInt8, Equatable, Sendable {
    case canonical
    case brushLocal
}

public struct BrushGrainTransform: Equatable, Sendable {
    public let scale: Float
    public let rotation: Float
    public let offset: SIMD2<Float>

    public init(
        scale: Float,
        rotation: Float,
        offset: SIMD2<Float>
    ) {
        self.scale = scale
        self.rotation = rotation
        self.offset = offset
    }

    public static let identity = BrushGrainTransform(
        scale: 1,
        rotation: 0,
        offset: .zero
    )
}

public enum BrushMaterialFamily: UInt8, Equatable, Sendable {
    case ink
    case dry
    case glaze
    case boundedWash
}

public struct BrushMaterial: Equatable, Sendable {
    public let family: BrushMaterialFamily
    public let strength: Float
    public let wetness: Float
    public let bleedRadius: Float
    public let softenPasses: Int
    public let accumulationLimit: Float

    public init(
        family: BrushMaterialFamily,
        strength: Float,
        wetness: Float,
        bleedRadius: Float,
        softenPasses: Int,
        accumulationLimit: Float
    ) {
        self.family = family
        self.strength = strength
        self.wetness = wetness
        self.bleedRadius = bleedRadius
        self.softenPasses = softenPasses
        self.accumulationLimit = accumulationLimit
    }

    public static let ink = BrushMaterial(
        family: .ink,
        strength: 1,
        wetness: 0,
        bleedRadius: 0,
        softenPasses: 0,
        accumulationLimit: 1
    )
}

public enum BrushDynamicsInput: UInt8, CaseIterable, Equatable, Sendable {
    case pressure
    case speed
    case direction
    case tilt
    case azimuth
    case roll
    case age
    case distance
}

public enum BrushMappingResponse: UInt8, Equatable, Sendable {
    case disabled
    case linear
    case boundedPower
}

/// One normalized-input response. Inputs are normalized to `0...1` by the
/// dynamics engine before this response maps them into its bounded output.
public struct BrushMapping: Equatable, Sendable {
    public let response: BrushMappingResponse
    public let input: BrushDynamicsInput
    public let outputMinimum: Float
    public let outputMaximum: Float
    public let exponent: Float

    public init(
        response: BrushMappingResponse,
        input: BrushDynamicsInput,
        outputMinimum: Float,
        outputMaximum: Float,
        exponent: Float
    ) {
        self.response = response
        self.input = input
        self.outputMinimum = outputMinimum
        self.outputMaximum = outputMaximum
        self.exponent = exponent
    }

    public static let disabled = BrushMapping(
        response: .disabled,
        input: .pressure,
        outputMinimum: 1,
        outputMaximum: 1,
        exponent: 1
    )

    public static func linear(
        input: BrushDynamicsInput,
        output: ClosedRange<Float>
    ) -> BrushMapping {
        BrushMapping(
            response: .linear,
            input: input,
            outputMinimum: output.lowerBound,
            outputMaximum: output.upperBound,
            exponent: 1
        )
    }

    public static func boundedPower(
        input: BrushDynamicsInput,
        output: ClosedRange<Float>,
        exponent: Float
    ) -> BrushMapping {
        BrushMapping(
            response: .boundedPower,
            input: input,
            outputMinimum: output.lowerBound,
            outputMaximum: output.upperBound,
            exponent: exponent
        )
    }
}

public struct BrushRandomization: Equatable, Sendable {
    public let spacing: Float
    public let scatter: Float
    public let rotation: Float
    public let grain: Float
    public let material: Float

    public init(
        spacing: Float,
        scatter: Float,
        rotation: Float,
        grain: Float,
        material: Float
    ) {
        self.spacing = spacing
        self.scatter = scatter
        self.rotation = rotation
        self.grain = grain
        self.material = material
    }

    public static let none = BrushRandomization(
        spacing: 0,
        scatter: 0,
        rotation: 0,
        grain: 0,
        material: 0
    )
}

public struct BrushColorAdjustment: Equatable, Sendable {
    public let redMultiplier: Float
    public let greenMultiplier: Float
    public let blueMultiplier: Float
    public let alphaMultiplier: Float

    public init(
        redMultiplier: Float,
        greenMultiplier: Float,
        blueMultiplier: Float,
        alphaMultiplier: Float
    ) {
        self.redMultiplier = redMultiplier
        self.greenMultiplier = greenMultiplier
        self.blueMultiplier = blueMultiplier
        self.alphaMultiplier = alphaMultiplier
    }

    public static let identity = BrushColorAdjustment(
        redMultiplier: 1,
        greenMultiplier: 1,
        blueMultiplier: 1,
        alphaMultiplier: 1
    )
}

public enum BrushTaperLength: Equatable, Sendable {
    case disabled
    case worldPixels(Float)
    case diameterMultiples(Float)
}

public struct BrushTaperEffects: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let size = BrushTaperEffects(rawValue: 1 << 0)
    public static let flow = BrushTaperEffects(rawValue: 1 << 1)
}

public struct BrushTaperConfiguration: Equatable, Sendable {
    public let start: BrushTaperLength
    public let end: BrushTaperLength
    public let minimumSize: Float
    public let minimumFlow: Float
    public let effects: BrushTaperEffects

    public init(
        start: BrushTaperLength,
        end: BrushTaperLength,
        minimumSize: Float,
        minimumFlow: Float,
        effects: BrushTaperEffects
    ) {
        self.start = start
        self.end = end
        self.minimumSize = minimumSize
        self.minimumFlow = minimumFlow
        self.effects = effects
    }

    public static let none = BrushTaperConfiguration(
        start: .disabled,
        end: .disabled,
        minimumSize: 1,
        minimumFlow: 1,
        effects: []
    )
}

public enum BrushReplayMode: UInt8, Equatable, Sendable {
    case appendOnly
    case replayTail
    case boundedWholeStroke
}

public struct BrushReplayLimits: Equatable, Sendable {
    public let maximumSamples: Int
    public let maximumDabs: Int
    public let maximumProjectedInstances: Int

    public init(
        maximumSamples: Int,
        maximumDabs: Int,
        maximumProjectedInstances: Int
    ) {
        self.maximumSamples = maximumSamples
        self.maximumDabs = maximumDabs
        self.maximumProjectedInstances = maximumProjectedInstances
    }
}

/// Replay policy derived only from a successfully validated brush recipe.
///
/// The initializer is intentionally module-internal so renderer code cannot
/// synthesize replay policy independently of recipe validation.
public struct BrushReplayContract: Equatable, Sendable {
    public let mode: BrushReplayMode
    public let limits: BrushReplayLimits?

    init(mode: BrushReplayMode, limits: BrushReplayLimits?) {
        self.mode = mode
        self.limits = limits
    }
}

public enum BrushRecipePolicy {
    public static let maximumMappingMagnitude: Float = 8
    public static let maximumWashBleedRadius: Float = 32
    public static let maximumWashSoftenPasses = 2
    public static let replayTailLimits = BrushReplayLimits(
        maximumSamples: 256,
        maximumDabs: 2_048,
        maximumProjectedInstances: 4_096
    )
    public static let wholeStrokeLimits = BrushReplayLimits(
        maximumSamples: 4_096,
        maximumDabs: 4_096,
        maximumProjectedInstances: 4_096
    )
}

public enum BrushRecipeValidationError: Error, Equatable, Sendable {
    case invalidIdentity
    case nonfinite(field: String)
    case outOfRange(field: String)
    case invalidMapping(field: String)
    case unsupportedAsset(String)
    case unboundedReplay
    case endTaperRequiresReplay
    case replayLimitsRequireReplayMode
    case replayLimitExceeded(field: String)
    case washLimitExceeded(field: String)
}

public struct BrushRecipe: Equatable, Sendable {
    public let id: BrushRecipeID
    public let schemaVersion: UInt16
    public let shape: BrushShapeDescriptor
    public let grain: BrushGrainDescriptor
    public let grainCoordinateMode: BrushGrainCoordinateMode
    public let grainTransform: BrushGrainTransform
    public let material: BrushMaterial
    public let baseSpacingFraction: Float
    public let maximumSpacingFraction: Float
    public let baseFlow: Float
    public let strokeOpacity: Float
    public let baseHardness: Float
    public let baseScatterFraction: Float
    public let baseRotation: Float
    public let aspectRatio: Float
    public let sizeMapping: BrushMapping
    public let flowMapping: BrushMapping
    public let spacingMapping: BrushMapping
    public let rotationMapping: BrushMapping
    public let scatterMapping: BrushMapping
    public let hardnessMapping: BrushMapping
    public let grainMapping: BrushMapping
    public let noPressureNeutral: Float
    public let randomization: BrushRandomization
    public let colorAdjustment: BrushColorAdjustment
    public let stabilization: Float
    public let taper: BrushTaperConfiguration
    public let replayMode: BrushReplayMode
    public let replayLimits: BrushReplayLimits?

    public var replayContract: BrushReplayContract {
        BrushReplayContract(mode: replayMode, limits: replayLimits)
    }

    public init(
        id: BrushRecipeID,
        schemaVersion: UInt16 = 1,
        shape: BrushShapeDescriptor = .hardRound,
        grain: BrushGrainDescriptor = .opaque,
        grainCoordinateMode: BrushGrainCoordinateMode = .canonical,
        grainTransform: BrushGrainTransform = .identity,
        material: BrushMaterial = .ink,
        baseSpacingFraction: Float = 0.125,
        maximumSpacingFraction: Float = 0.125,
        baseFlow: Float = 1,
        strokeOpacity: Float = 1,
        baseHardness: Float = 1,
        baseScatterFraction: Float = 0,
        baseRotation: Float = 0,
        aspectRatio: Float = 1,
        sizeMapping: BrushMapping = .disabled,
        flowMapping: BrushMapping = .disabled,
        spacingMapping: BrushMapping = .disabled,
        rotationMapping: BrushMapping = .disabled,
        scatterMapping: BrushMapping = .disabled,
        hardnessMapping: BrushMapping = .disabled,
        grainMapping: BrushMapping = .disabled,
        noPressureNeutral: Float = 1,
        randomization: BrushRandomization = .none,
        colorAdjustment: BrushColorAdjustment = .identity,
        stabilization: Float = 0,
        taper: BrushTaperConfiguration = .none,
        replayMode: BrushReplayMode = .appendOnly,
        replayLimits: BrushReplayLimits? = nil
    ) throws {
        try Self.validateIdentity(id, schemaVersion: schemaVersion)
        try Self.validateAssets(shape: shape, grain: grain)
        try Self.validate(
            grainTransform: grainTransform,
            material: material
        )
        try Self.validateFiniteAndRanges(
            baseSpacingFraction: baseSpacingFraction,
            maximumSpacingFraction: maximumSpacingFraction,
            baseFlow: baseFlow,
            strokeOpacity: strokeOpacity,
            baseHardness: baseHardness,
            baseScatterFraction: baseScatterFraction,
            baseRotation: baseRotation,
            aspectRatio: aspectRatio,
            noPressureNeutral: noPressureNeutral,
            stabilization: stabilization
        )
        try Self.validateMappings([
            ("sizeMapping", sizeMapping, .positive),
            ("flowMapping", flowMapping, .nonnegative),
            ("spacingMapping", spacingMapping, .positive),
            ("rotationMapping", rotationMapping, .signed),
            ("scatterMapping", scatterMapping, .nonnegative),
            ("hardnessMapping", hardnessMapping, .nonnegative),
            ("grainMapping", grainMapping, .positive),
        ])
        try Self.validate(randomization: randomization)
        try Self.validate(colorAdjustment: colorAdjustment)
        try Self.validate(taper: taper)
        try Self.validate(
            replayMode: replayMode,
            limits: replayLimits,
            endTaper: taper.end
        )

        self.id = id
        self.schemaVersion = schemaVersion
        self.shape = shape
        self.grain = grain
        self.grainCoordinateMode = grainCoordinateMode
        self.grainTransform = grainTransform
        self.material = material
        self.baseSpacingFraction = baseSpacingFraction
        self.maximumSpacingFraction = maximumSpacingFraction
        self.baseFlow = baseFlow
        self.strokeOpacity = strokeOpacity
        self.baseHardness = baseHardness
        self.baseScatterFraction = baseScatterFraction
        self.baseRotation = baseRotation
        self.aspectRatio = aspectRatio
        self.sizeMapping = sizeMapping
        self.flowMapping = flowMapping
        self.spacingMapping = spacingMapping
        self.rotationMapping = rotationMapping
        self.scatterMapping = scatterMapping
        self.hardnessMapping = hardnessMapping
        self.grainMapping = grainMapping
        self.noPressureNeutral = noPressureNeutral
        self.randomization = randomization
        self.colorAdjustment = colorAdjustment
        self.stabilization = stabilization
        self.taper = taper
        self.replayMode = replayMode
        self.replayLimits = replayLimits
    }

    public static let legacyEquivalent: BrushRecipe = {
        do {
            return try BrushRecipe(
                id: BrushRecipeID("builtin.legacy-hard-round")
            )
        } catch {
            preconditionFailure("Invalid built-in legacy recipe: \(error)")
        }
    }()
}

private extension BrushRecipe {
    enum MappingDomain {
        case positive
        case nonnegative
        case signed
    }

    static func validateIdentity(
        _ id: BrushRecipeID,
        schemaVersion: UInt16
    ) throws {
        guard !id.rawValue.isEmpty, schemaVersion > 0 else {
            throw BrushRecipeValidationError.invalidIdentity
        }
    }

    static func validateAssets(
        shape: BrushShapeDescriptor,
        grain: BrushGrainDescriptor
    ) throws {
        if case let .asset(identity) = shape,
           !Set([
               "builtin.shape.hard-round",
               "builtin.shape.soft-round",
               "builtin.shape.chisel",
           ]).contains(identity)
        {
            throw BrushRecipeValidationError.unsupportedAsset(identity)
        }
        if case let .asset(identity) = grain,
           !Set([
               "builtin.grain.opaque",
               "builtin.grain.paper",
               "builtin.grain.noise",
           ]).contains(identity)
        {
            throw BrushRecipeValidationError.unsupportedAsset(identity)
        }
    }

    static func validate(
        grainTransform: BrushGrainTransform,
        material: BrushMaterial
    ) throws {
        try requireFinite(grainTransform.scale, field: "grainTransform.scale")
        try requireFinite(
            grainTransform.rotation,
            field: "grainTransform.rotation"
        )
        try requireFinite(
            grainTransform.offset.x,
            field: "grainTransform.offset.x"
        )
        try requireFinite(
            grainTransform.offset.y,
            field: "grainTransform.offset.y"
        )
        guard grainTransform.scale > 0, grainTransform.scale <= 1_024 else {
            throw BrushRecipeValidationError.outOfRange(
                field: "grainTransform.scale"
            )
        }

        for (field, value) in [
            ("material.strength", material.strength),
            ("material.wetness", material.wetness),
            ("material.bleedRadius", material.bleedRadius),
            ("material.accumulationLimit", material.accumulationLimit),
        ] {
            try requireFinite(value, field: field)
        }
        guard (0...1).contains(material.strength) else {
            throw BrushRecipeValidationError.outOfRange(
                field: "material.strength"
            )
        }
        guard (0...1).contains(material.wetness) else {
            throw BrushRecipeValidationError.outOfRange(
                field: "material.wetness"
            )
        }
        guard (0...1).contains(material.accumulationLimit) else {
            throw BrushRecipeValidationError.outOfRange(
                field: "material.accumulationLimit"
            )
        }
        guard material.bleedRadius >= 0, material.softenPasses >= 0 else {
            throw BrushRecipeValidationError.outOfRange(field: "material")
        }
        if material.bleedRadius > BrushRecipePolicy.maximumWashBleedRadius {
            throw BrushRecipeValidationError.washLimitExceeded(
                field: "bleedRadius"
            )
        }
        if material.softenPasses > BrushRecipePolicy.maximumWashSoftenPasses {
            throw BrushRecipeValidationError.washLimitExceeded(
                field: "softenPasses"
            )
        }
        if material.family != .boundedWash,
           material.bleedRadius != 0 || material.softenPasses != 0
        {
            throw BrushRecipeValidationError.outOfRange(field: "material")
        }
    }

    static func validateFiniteAndRanges(
        baseSpacingFraction: Float,
        maximumSpacingFraction: Float,
        baseFlow: Float,
        strokeOpacity: Float,
        baseHardness: Float,
        baseScatterFraction: Float,
        baseRotation: Float,
        aspectRatio: Float,
        noPressureNeutral: Float,
        stabilization: Float
    ) throws {
        let values: [(String, Float)] = [
            ("baseSpacingFraction", baseSpacingFraction),
            ("maximumSpacingFraction", maximumSpacingFraction),
            ("baseFlow", baseFlow),
            ("strokeOpacity", strokeOpacity),
            ("baseHardness", baseHardness),
            ("baseScatterFraction", baseScatterFraction),
            ("baseRotation", baseRotation),
            ("aspectRatio", aspectRatio),
            ("noPressureNeutral", noPressureNeutral),
            ("stabilization", stabilization),
        ]
        for (field, value) in values {
            try requireFinite(value, field: field)
        }
        guard baseSpacingFraction > 0 else {
            throw BrushRecipeValidationError.outOfRange(
                field: "baseSpacingFraction"
            )
        }
        guard maximumSpacingFraction >= baseSpacingFraction,
              maximumSpacingFraction <= 4
        else {
            throw BrushRecipeValidationError.outOfRange(
                field: "maximumSpacingFraction"
            )
        }
        for (field, value) in [
            ("baseFlow", baseFlow),
            ("strokeOpacity", strokeOpacity),
            ("baseHardness", baseHardness),
            ("noPressureNeutral", noPressureNeutral),
        ] where !(0...1).contains(value) {
            throw BrushRecipeValidationError.outOfRange(field: field)
        }
        guard (0...1).contains(baseScatterFraction) else {
            throw BrushRecipeValidationError.outOfRange(
                field: "baseScatterFraction"
            )
        }
        guard abs(baseRotation) <= 2 * .pi else {
            throw BrushRecipeValidationError.outOfRange(field: "baseRotation")
        }
        guard aspectRatio > 0, aspectRatio <= 1 else {
            throw BrushRecipeValidationError.outOfRange(field: "aspectRatio")
        }
        guard stabilization >= 0, stabilization < 1 else {
            throw BrushRecipeValidationError.outOfRange(field: "stabilization")
        }
    }

    static func validateMappings(
        _ mappings: [(String, BrushMapping, MappingDomain)]
    ) throws {
        for (field, mapping, domain) in mappings {
            guard mapping.outputMinimum.isFinite,
                  mapping.outputMaximum.isFinite,
                  mapping.exponent.isFinite,
                  mapping.outputMinimum <= mapping.outputMaximum,
                  mapping.exponent >= 0.125,
                  mapping.exponent <= 8
            else {
                throw BrushRecipeValidationError.invalidMapping(field: field)
            }
            guard mapping.response != .disabled else { continue }
            switch domain {
            case .positive:
                guard mapping.outputMinimum > 0,
                      mapping.outputMaximum <= BrushRecipePolicy.maximumMappingMagnitude
                else {
                    throw BrushRecipeValidationError.invalidMapping(field: field)
                }
            case .nonnegative:
                guard mapping.outputMinimum >= 0,
                      mapping.outputMaximum <= BrushRecipePolicy.maximumMappingMagnitude
                else {
                    throw BrushRecipeValidationError.invalidMapping(field: field)
                }
            case .signed:
                guard abs(mapping.outputMinimum) <= 2 * .pi,
                      abs(mapping.outputMaximum) <= 2 * .pi
                else {
                    throw BrushRecipeValidationError.invalidMapping(field: field)
                }
            }
        }
    }

    static func validate(randomization: BrushRandomization) throws {
        for (field, value) in [
            ("randomization.spacing", randomization.spacing),
            ("randomization.scatter", randomization.scatter),
            ("randomization.grain", randomization.grain),
            ("randomization.material", randomization.material),
        ] {
            try requireFinite(value, field: field)
            guard (0...1).contains(value) else {
                throw BrushRecipeValidationError.outOfRange(field: field)
            }
        }
        try requireFinite(
            randomization.rotation,
            field: "randomization.rotation"
        )
        guard (0...Float.pi).contains(randomization.rotation) else {
            throw BrushRecipeValidationError.outOfRange(
                field: "randomization.rotation"
            )
        }
    }

    static func validate(colorAdjustment: BrushColorAdjustment) throws {
        for (field, value) in [
            ("colorAdjustment.redMultiplier", colorAdjustment.redMultiplier),
            ("colorAdjustment.greenMultiplier", colorAdjustment.greenMultiplier),
            ("colorAdjustment.blueMultiplier", colorAdjustment.blueMultiplier),
            ("colorAdjustment.alphaMultiplier", colorAdjustment.alphaMultiplier),
        ] {
            try requireFinite(value, field: field)
            guard (0...1).contains(value) else {
                throw BrushRecipeValidationError.outOfRange(field: field)
            }
        }
    }

    static func validate(taper: BrushTaperConfiguration) throws {
        try validate(taper.start, field: "taper.start")
        try validate(taper.end, field: "taper.end")
        for (field, value) in [
            ("taper.minimumSize", taper.minimumSize),
            ("taper.minimumFlow", taper.minimumFlow),
        ] {
            try requireFinite(value, field: field)
            guard (0...1).contains(value) else {
                throw BrushRecipeValidationError.outOfRange(field: field)
            }
        }
    }

    static func validate(
        _ length: BrushTaperLength,
        field: String
    ) throws {
        let value: Float
        switch length {
        case .disabled:
            return
        case let .worldPixels(length), let .diameterMultiples(length):
            value = length
        }
        try requireFinite(value, field: field)
        guard value > 0 else {
            throw BrushRecipeValidationError.outOfRange(field: field)
        }
    }

    static func validate(
        replayMode: BrushReplayMode,
        limits: BrushReplayLimits?,
        endTaper: BrushTaperLength
    ) throws {
        guard replayMode != .appendOnly else {
            guard limits == nil else {
                throw BrushRecipeValidationError
                    .replayLimitsRequireReplayMode
            }
            guard case .disabled = endTaper else {
                throw BrushRecipeValidationError.endTaperRequiresReplay
            }
            return
        }
        guard let limits else {
            throw BrushRecipeValidationError.unboundedReplay
        }
        let cap = replayMode == .replayTail
            ? BrushRecipePolicy.replayTailLimits
            : BrushRecipePolicy.wholeStrokeLimits
        for (field, value, maximum) in [
            ("maximumSamples", limits.maximumSamples, cap.maximumSamples),
            ("maximumDabs", limits.maximumDabs, cap.maximumDabs),
            (
                "maximumProjectedInstances",
                limits.maximumProjectedInstances,
                cap.maximumProjectedInstances
            ),
        ] where value <= 0 || value > maximum {
            throw BrushRecipeValidationError.replayLimitExceeded(field: field)
        }
    }

    static func requireFinite(_ value: Float, field: String) throws {
        guard value.isFinite else {
            throw BrushRecipeValidationError.nonfinite(field: field)
        }
    }
}
