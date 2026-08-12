import Foundation
import simd

public struct BrushRecipeID: RawRepresentable, Hashable, Codable, Sendable {
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

public enum BrushGrainCoordinateMode: UInt8, Codable, Equatable, Sendable {
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

public enum BrushMaterialFamily: UInt8, Codable, Equatable, Sendable {
    case ink
    case dry
    case glaze
    case boundedWash
}

public enum BrushDynamicsInput: String, CaseIterable, Codable, Equatable, Sendable {
    case pressure
    case speed
    case direction
    case tilt
    case azimuth
    case roll
    case tangentialPressure
    case age
    case distance
    case random
}

public struct BrushRandomization: Codable, Equatable, Sendable {
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

public struct BrushColorAdjustment: Codable, Equatable, Sendable {
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

public struct BrushTaperEffects: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let size = BrushTaperEffects(rawValue: 1 << 0)
    public static let flow = BrushTaperEffects(rawValue: 1 << 1)
}

public struct BrushTaperConfiguration: Codable, Equatable, Sendable {
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

/// Causal stroke-finalization semantics for current native definitions.
public enum BrushTerminationDefinition: Codable, Equatable, Sendable {
    case cap
    case pressureRelease(maximumWorldLength: Float)
    case boundedCorrection(
        maximumSamples: Int,
        maximumWorldLength: Float,
        maximumDabs: Int
    )

    private enum Keys: String, CodingKey {
        case kind
        case maximumSamples
        case maximumWorldLength
        case maximumDabs
    }

    private enum Kind: String, Codable {
        case cap
        case pressureRelease
        case boundedCorrection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .cap:
            self = .cap
        case .pressureRelease:
            self = .pressureRelease(
                maximumWorldLength: try container.decode(
                    Float.self,
                    forKey: .maximumWorldLength
                )
            )
        case .boundedCorrection:
            self = .boundedCorrection(
                maximumSamples: try container.decode(
                    Int.self,
                    forKey: .maximumSamples
                ),
                maximumWorldLength: try container.decode(
                    Float.self,
                    forKey: .maximumWorldLength
                ),
                maximumDabs: try container.decode(
                    Int.self,
                    forKey: .maximumDabs
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .cap:
            try container.encode(Kind.cap, forKey: .kind)
        case let .pressureRelease(maximumWorldLength):
            try container.encode(Kind.pressureRelease, forKey: .kind)
            try container.encode(
                maximumWorldLength,
                forKey: .maximumWorldLength
            )
        case let .boundedCorrection(
            maximumSamples,
            maximumWorldLength,
            maximumDabs
        ):
            try container.encode(Kind.boundedCorrection, forKey: .kind)
            try container.encode(maximumSamples, forKey: .maximumSamples)
            try container.encode(
                maximumWorldLength,
                forKey: .maximumWorldLength
            )
            try container.encode(maximumDabs, forKey: .maximumDabs)
        }
    }
}

public enum BrushReplayMode: UInt8, Codable, Equatable, Sendable {
    case appendOnly
    case replayTail
}

public struct BrushReplayLimits: Codable, Equatable, Sendable {
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

/// Replay policy derived only from a successfully validated brush definition.
///
/// The initializer is intentionally module-internal so renderer code cannot
/// synthesize replay policy independently of definition validation.
public struct BrushReplayContract: Equatable, Sendable {
    public let mode: BrushReplayMode
    public let limits: BrushReplayLimits?
    public let maximumWorldLength: Float?

    init(
        mode: BrushReplayMode,
        limits: BrushReplayLimits?,
        maximumWorldLength: Float? = nil
    ) {
        self.mode = mode
        self.limits = limits
        self.maximumWorldLength = maximumWorldLength
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
}

struct BrushSIMD2Codable: Codable {
    let x: Float
    let y: Float

    init(_ value: SIMD2<Float>) { x = value.x; y = value.y }
    var value: SIMD2<Float> { SIMD2(x, y) }
}

extension BrushShapeDescriptor: Codable {
    private enum CodingKeys: String, CodingKey { case kind, identifier }
    private enum Kind: String, Codable { case hardRound, softRound, chisel, asset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .hardRound: self = .hardRound
        case .softRound: self = .softRound
        case .chisel: self = .chisel
        case .asset: self = .asset(try container.decode(String.self, forKey: .identifier))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hardRound: try container.encode(Kind.hardRound, forKey: .kind)
        case .softRound: try container.encode(Kind.softRound, forKey: .kind)
        case .chisel: try container.encode(Kind.chisel, forKey: .kind)
        case let .asset(identifier):
            try container.encode(Kind.asset, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
        }
    }
}

extension BrushGrainDescriptor: Codable {
    private enum CodingKeys: String, CodingKey { case kind, identifier }
    private enum Kind: String, Codable { case opaque, paper, noise, asset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .opaque: self = .opaque
        case .paper: self = .paper
        case .noise: self = .noise
        case .asset: self = .asset(try container.decode(String.self, forKey: .identifier))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .opaque: try container.encode(Kind.opaque, forKey: .kind)
        case .paper: try container.encode(Kind.paper, forKey: .kind)
        case .noise: try container.encode(Kind.noise, forKey: .kind)
        case let .asset(identifier):
            try container.encode(Kind.asset, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
        }
    }
}

extension BrushGrainTransform: Codable {
    private enum CodingKeys: String, CodingKey { case scale, rotation, offset }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scale: try container.decode(Float.self, forKey: .scale), rotation: try container.decode(Float.self, forKey: .rotation), offset: try container.decode(BrushSIMD2Codable.self, forKey: .offset).value)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scale, forKey: .scale)
        try container.encode(rotation, forKey: .rotation)
        try container.encode(BrushSIMD2Codable(offset), forKey: .offset)
    }
}

extension BrushTaperLength: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case disabled, worldPixels, diameterMultiples }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .disabled: self = .disabled
        case .worldPixels: self = .worldPixels(try container.decode(Float.self, forKey: .value))
        case .diameterMultiples: self = .diameterMultiples(try container.decode(Float.self, forKey: .value))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disabled: try container.encode(Kind.disabled, forKey: .kind)
        case let .worldPixels(value): try container.encode(Kind.worldPixels, forKey: .kind); try container.encode(value, forKey: .value)
        case let .diameterMultiples(value): try container.encode(Kind.diameterMultiples, forKey: .kind); try container.encode(value, forKey: .value)
        }
    }
}
