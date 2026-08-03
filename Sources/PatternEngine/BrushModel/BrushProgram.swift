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

public struct BrushStageCProgramMetadata: Equatable, Sendable {
    public let normalization: BrushSensorNormalizationDefinition
    public let sensorProgram: BrushSensorProgramDefinition
    public let stabilization: BrushStabilizationDefinition
    public let direction: BrushDirectionDefinition
    public let emission: BrushEmissionDefinition
    public let tipSupports: [BrushTipSupportDefinition]
    public let declaredEndpointLag: Float?
    public let usesTravelDirection: Bool
}

/// Immutable stroke-finalization program selected before input begins.
/// Legacy cases are emitted only for definitions carrying the unforgeable
/// compatibility marker installed by the legacy adapter/decoder.
public enum BrushTerminationProgram: Equatable, Sendable {
    case cap
    case pressureRelease(maximumWorldLength: Float)
    case boundedCorrection(
        maximumSamples: Int,
        maximumWorldLength: Float,
        maximumDabs: Int
    )
    case legacySchemaV1Cap
    case legacySchemaV1EndTaper(
        taper: BrushTaperConfiguration,
        replayLimits: BrushReplayLimits
    )
    case legacySchemaV1Replay(
        mode: BrushReplayMode,
        replayLimits: BrushReplayLimits
    )

    var isLegacySchemaV1EndTaper: Bool {
        if case .legacySchemaV1EndTaper = self { return true }
        return false
    }

    var usesLegacySchemaV1EndpointFiltering: Bool {
        switch self {
        case .legacySchemaV1Cap, .legacySchemaV1EndTaper,
             .legacySchemaV1Replay:
            true
        case .cap, .pressureRelease, .boundedCorrection:
            false
        }
    }
}

/// Shared immutable result of brush compilation.
///
/// A program is retained by every generator snapshot in the replay buffer.
/// Reference storage keeps those snapshots value-semantic without repeatedly
/// embedding the compiled response tables and Stage C metadata in their value
/// footprint. Compilation remains the only point that allocates a program.
public final class BrushProgram: Equatable, Sendable {
    public let definition: BrushDefinition
    public let dynamics: BrushDynamicsProgram
    public let termination: BrushTerminationProgram
    public let requiredCapabilities: Set<BrushCapability>
    public let ignoredOptionalCapabilityIdentifiers: [String]
    public let requestedBackend: BrushBackendKind
    public let stageC: BrushStageCProgramMetadata?

    init(
        definition: BrushDefinition,
        dynamics: BrushDynamicsProgram,
        termination: BrushTerminationProgram,
        requiredCapabilities: Set<BrushCapability>,
        ignoredOptionalCapabilityIdentifiers: [String],
        requestedBackend: BrushBackendKind,
        stageC: BrushStageCProgramMetadata?
    ) {
        self.definition = definition
        self.dynamics = dynamics
        self.termination = termination
        self.requiredCapabilities = requiredCapabilities
        self.ignoredOptionalCapabilityIdentifiers =
            ignoredOptionalCapabilityIdentifiers
        self.requestedBackend = requestedBackend
        self.stageC = stageC
    }

    public static func == (lhs: BrushProgram, rhs: BrushProgram) -> Bool {
        lhs === rhs
            || (lhs.definition == rhs.definition
                && lhs.dynamics == rhs.dynamics
                && lhs.termination == rhs.termination
                && lhs.requiredCapabilities == rhs.requiredCapabilities
                && lhs.ignoredOptionalCapabilityIdentifiers
                    == rhs.ignoredOptionalCapabilityIdentifiers
                && lhs.requestedBackend == rhs.requestedBackend
                && lhs.stageC == rhs.stageC)
    }

    public var replayContract: BrushReplayContract {
        switch termination {
        case .cap, .pressureRelease:
            BrushReplayContract(mode: .appendOnly, limits: nil)
        case let .boundedCorrection(
            maximumSamples,
            maximumWorldLength,
            maximumDabs
        ):
            BrushReplayContract(
                mode: .replayTail,
                limits: BrushReplayLimits(
                    maximumSamples: maximumSamples,
                    maximumDabs: maximumDabs,
                    maximumProjectedInstances:
                        definition.replayLimits?.maximumProjectedInstances
                        ?? BrushRecipePolicy.replayTailLimits
                            .maximumProjectedInstances
                ),
                maximumWorldLength: maximumWorldLength
            )
        case .legacySchemaV1Cap:
            BrushReplayContract(mode: .appendOnly, limits: nil)
        case let .legacySchemaV1EndTaper(_, replayLimits):
            BrushReplayContract(
                mode: definition.replayMode,
                limits: replayLimits
            )
        case let .legacySchemaV1Replay(mode, replayLimits):
            BrushReplayContract(mode: mode, limits: replayLimits)
        }
    }
}

public enum BrushProgramCompilerError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt16)
    case unknownRequiredCapability(String)
    case invalidCurve
    case invalidStageCDefinition
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
