import Foundation

/// A response whose validation and representation selection were completed
/// before a stroke begins. The legacy cases deliberately retain the exact
/// operations used by `BrushMapping` so built-in brushes keep their pixels.
public enum CompiledBrushResponse: Equatable, Sendable {
    case constant(Float)
    case legacyLinear(
        input: BrushDynamicsInput,
        minimum: Float,
        maximum: Float,
        missingInputValue: Float
    )
    case legacyBoundedPower(
        input: BrushDynamicsInput,
        minimum: Float,
        maximum: Float,
        exponent: Float,
        missingInputValue: Float
    )
    case sampledCurve(
        input: BrushDynamicsInput,
        samples: [Float],
        scale: Float,
        offset: Float,
        lowerClamp: Float,
        upperClamp: Float,
        inverted: Bool,
        jitter: Float,
        missingInputValue: Float
    )
}

public struct BrushDynamicsProgram: Equatable, Sendable {
    public let size: CompiledBrushResponse
    public let flow: CompiledBrushResponse
    public let opacity: CompiledBrushResponse
    public let spacing: CompiledBrushResponse
    public let rotation: CompiledBrushResponse
    public let scatter: CompiledBrushResponse
    public let hardness: CompiledBrushResponse
    public let grain: CompiledBrushResponse
    public let offsetX: CompiledBrushResponse
    public let offsetY: CompiledBrushResponse
    public let hue: CompiledBrushResponse
    public let saturation: CompiledBrushResponse
    public let brightness: CompiledBrushResponse
    public let secondaryColorMix: CompiledBrushResponse
}

public enum BrushBackendKind: String, Codable, Hashable, Sendable {
    case deposition
    case canvasInteraction
}

public struct BrushProgram: Equatable, Sendable {
    public let definition: BrushDefinition
    public let dynamics: BrushDynamicsProgram
    /// Present only when this definition is exactly representable by the old
    /// renderer. PatternEngine never relies on this optional value.
    public let compatibilityRecipe: BrushRecipe?
    public let requiredCapabilities: Set<BrushCapability>
    public let ignoredOptionalCapabilityIdentifiers: [String]
    public let requestedBackend: BrushBackendKind

    public var replayContract: BrushReplayContract {
        BrushReplayContract(
            mode: definition.replayMode,
            limits: definition.replayLimits
        )
    }
}

public enum BrushProgramCompilerError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt16)
    case unknownRequiredCapability(String)
    case invalidCurve
}

/// Namespaces counter-based extension randomness. Adding a channel must never
/// consume a word from the seven-word compatibility cursor.
public enum BrushProgramRandomChannel: UInt64, CaseIterable, Sendable {
    case size = 0
    case flow
    case opacity
    case spacing
    case rotation
    case scatter
    case hardness
    case grain
    case offsetX
    case offsetY
    case hue
    case saturation
    case brightness
    case secondaryColorMix
    case perStampHue
    case perStampSaturation
    case perStampBrightness
    case perStampSecondaryColorMix
    case perStrokeHue
    case perStrokeSaturation
    case perStrokeBrightness
    case perStrokeSecondaryColorMix
    case placementJitterX
    case placementJitterY
}
