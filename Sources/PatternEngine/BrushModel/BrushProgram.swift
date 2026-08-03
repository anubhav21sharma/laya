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

/// One schema-v2 response term after validation and LUT compilation.
/// Construction is compiler-owned; stroke evaluation only reads this value.
struct CompiledBrushSensorTerm: Equatable, Sendable {
    let input: BrushDynamicsInput
    let samples: [Float]
    let inputInverted: Bool
    let missingInputValue: Float
    let responseScale: Float
    let responseOffset: Float
    let responseLowerClamp: Float
    let responseUpperClamp: Float
    let jitter: Float
    let operation: BrushResponseOperation
}

/// Fixed-capacity ordered term storage. Optional slots avoid allocating or
/// traversing a collection while input is arriving.
struct CompiledBrushOutputProgram: Equatable, Sendable {
    let baseValue: Float
    let term0: CompiledBrushSensorTerm?
    let term1: CompiledBrushSensorTerm?
    let term2: CompiledBrushSensorTerm?
    let term3: CompiledBrushSensorTerm?
}

/// Fixed output layout in the serialized `BrushDynamicOutput.allCases` order.
/// The source dictionary is consumed only by the off-path compiler.
final class CompiledBrushSensorProgram: Equatable, Sendable {
    let size: CompiledBrushOutputProgram
    let flow: CompiledBrushOutputProgram
    let opacity: CompiledBrushOutputProgram
    let spacing: CompiledBrushOutputProgram
    let rotation: CompiledBrushOutputProgram
    let scatter: CompiledBrushOutputProgram
    let hardness: CompiledBrushOutputProgram
    let grain: CompiledBrushOutputProgram
    let offsetX: CompiledBrushOutputProgram
    let offsetY: CompiledBrushOutputProgram
    let hue: CompiledBrushOutputProgram
    let saturation: CompiledBrushOutputProgram
    let brightness: CompiledBrushOutputProgram
    let secondaryColorMix: CompiledBrushOutputProgram

    init(
        size: CompiledBrushOutputProgram,
        flow: CompiledBrushOutputProgram,
        opacity: CompiledBrushOutputProgram,
        spacing: CompiledBrushOutputProgram,
        rotation: CompiledBrushOutputProgram,
        scatter: CompiledBrushOutputProgram,
        hardness: CompiledBrushOutputProgram,
        grain: CompiledBrushOutputProgram,
        offsetX: CompiledBrushOutputProgram,
        offsetY: CompiledBrushOutputProgram,
        hue: CompiledBrushOutputProgram,
        saturation: CompiledBrushOutputProgram,
        brightness: CompiledBrushOutputProgram,
        secondaryColorMix: CompiledBrushOutputProgram
    ) {
        self.size = size
        self.flow = flow
        self.opacity = opacity
        self.spacing = spacing
        self.rotation = rotation
        self.scatter = scatter
        self.hardness = hardness
        self.grain = grain
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.secondaryColorMix = secondaryColorMix
    }

    static func == (
        lhs: CompiledBrushSensorProgram,
        rhs: CompiledBrushSensorProgram
    ) -> Bool {
        lhs === rhs
            || (sizeEqual(lhs, rhs)
                && flowEqual(lhs, rhs)
                && opacityEqual(lhs, rhs)
                && spacingEqual(lhs, rhs)
                && rotationEqual(lhs, rhs)
                && scatterEqual(lhs, rhs)
                && hardnessEqual(lhs, rhs)
                && grainEqual(lhs, rhs)
                && offsetXEqual(lhs, rhs)
                && offsetYEqual(lhs, rhs)
                && hueEqual(lhs, rhs)
                && saturationEqual(lhs, rhs)
                && brightnessEqual(lhs, rhs)
                && secondaryColorMixEqual(lhs, rhs))
    }

    @inline(never)
    private static func sizeEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.size == rhs.size }

    @inline(never)
    private static func flowEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.flow == rhs.flow }

    @inline(never)
    private static func opacityEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.opacity == rhs.opacity }

    @inline(never)
    private static func spacingEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.spacing == rhs.spacing }

    @inline(never)
    private static func rotationEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.rotation == rhs.rotation }

    @inline(never)
    private static func scatterEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.scatter == rhs.scatter }

    @inline(never)
    private static func hardnessEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.hardness == rhs.hardness }

    @inline(never)
    private static func grainEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.grain == rhs.grain }

    @inline(never)
    private static func offsetXEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.offsetX == rhs.offsetX }

    @inline(never)
    private static func offsetYEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.offsetY == rhs.offsetY }

    @inline(never)
    private static func hueEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.hue == rhs.hue }

    @inline(never)
    private static func saturationEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.saturation == rhs.saturation }

    @inline(never)
    private static func brightnessEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.brightness == rhs.brightness }

    @inline(never)
    private static func secondaryColorMixEqual(
        _ lhs: CompiledBrushSensorProgram,
        _ rhs: CompiledBrushSensorProgram
    ) -> Bool { lhs.secondaryColorMix == rhs.secondaryColorMix }
}

struct BrushOrderedDynamicValues: Equatable, Sendable {
    let size: Float
    let flow: Float
    let opacity: Float
    let spacing: Float
    let rotation: Float
    let scatter: Float
    let hardness: Float
    let grain: Float
    let offsetX: Float
    let offsetY: Float
    let hue: Float
    let saturation: Float
    let brightness: Float
    let secondaryColorMix: Float
}

public enum BrushBackendKind: String, Codable, Hashable, Sendable {
    case deposition
    case canvasInteraction
}

public final class BrushStageCProgramMetadata: Equatable, Sendable {
    public let normalization: BrushSensorNormalizationDefinition
    public let sensorProgram: BrushSensorProgramDefinition
    public let stabilization: BrushStabilizationDefinition
    public let direction: BrushDirectionDefinition
    public let emission: BrushEmissionDefinition
    public let tipSupports: [BrushTipSupportDefinition]
    public let declaredEndpointLag: Float?
    public let usesTravelDirection: Bool
    let compiledSensorProgram: CompiledBrushSensorProgram

    init(
        normalization: BrushSensorNormalizationDefinition,
        sensorProgram: BrushSensorProgramDefinition,
        stabilization: BrushStabilizationDefinition,
        direction: BrushDirectionDefinition,
        emission: BrushEmissionDefinition,
        tipSupports: [BrushTipSupportDefinition],
        declaredEndpointLag: Float?,
        usesTravelDirection: Bool,
        compiledSensorProgram: CompiledBrushSensorProgram
    ) {
        self.normalization = normalization
        self.sensorProgram = sensorProgram
        self.stabilization = stabilization
        self.direction = direction
        self.emission = emission
        self.tipSupports = tipSupports
        self.declaredEndpointLag = declaredEndpointLag
        self.usesTravelDirection = usesTravelDirection
        self.compiledSensorProgram = compiledSensorProgram
    }

    public static func == (
        lhs: BrushStageCProgramMetadata,
        rhs: BrushStageCProgramMetadata
    ) -> Bool {
        lhs === rhs
            || (normalizationsEqual(lhs, rhs)
                && sensorProgramsEqual(lhs, rhs)
                && stabilizationsEqual(lhs, rhs)
                && directionsEqual(lhs, rhs)
                && emissionsEqual(lhs, rhs)
                && tipSupportsEqual(lhs, rhs)
                && endpointLagsEqual(lhs, rhs)
                && travelDirectionFlagsEqual(lhs, rhs)
                && compiledSensorProgramsEqual(lhs, rhs))
    }

    @inline(never)
    private static func normalizationsEqual(
        _ lhs: BrushStageCProgramMetadata,
        _ rhs: BrushStageCProgramMetadata
    ) -> Bool { lhs.normalization == rhs.normalization }

    @inline(never)
    private static func sensorProgramsEqual(
        _ lhs: BrushStageCProgramMetadata,
        _ rhs: BrushStageCProgramMetadata
    ) -> Bool { lhs.sensorProgram == rhs.sensorProgram }

    @inline(never)
    private static func stabilizationsEqual(
        _ lhs: BrushStageCProgramMetadata,
        _ rhs: BrushStageCProgramMetadata
    ) -> Bool { lhs.stabilization == rhs.stabilization }

    @inline(never)
    private static func directionsEqual(
        _ lhs: BrushStageCProgramMetadata,
        _ rhs: BrushStageCProgramMetadata
    ) -> Bool { lhs.direction == rhs.direction }

    @inline(never)
    private static func emissionsEqual(
        _ lhs: BrushStageCProgramMetadata,
        _ rhs: BrushStageCProgramMetadata
    ) -> Bool { lhs.emission == rhs.emission }

    @inline(never)
    private static func tipSupportsEqual(
        _ lhs: BrushStageCProgramMetadata,
        _ rhs: BrushStageCProgramMetadata
    ) -> Bool { lhs.tipSupports == rhs.tipSupports }

    @inline(never)
    private static func endpointLagsEqual(
        _ lhs: BrushStageCProgramMetadata,
        _ rhs: BrushStageCProgramMetadata
    ) -> Bool { lhs.declaredEndpointLag == rhs.declaredEndpointLag }

    @inline(never)
    private static func travelDirectionFlagsEqual(
        _ lhs: BrushStageCProgramMetadata,
        _ rhs: BrushStageCProgramMetadata
    ) -> Bool { lhs.usesTravelDirection == rhs.usesTravelDirection }

    @inline(never)
    private static func compiledSensorProgramsEqual(
        _ lhs: BrushStageCProgramMetadata,
        _ rhs: BrushStageCProgramMetadata
    ) -> Bool {
        lhs.compiledSensorProgram == rhs.compiledSensorProgram
    }
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
            || (definitionsEqual(lhs, rhs)
                && dynamicsEqual(lhs, rhs)
                && terminationsEqual(lhs, rhs)
                && requiredCapabilitiesEqual(lhs, rhs)
                && ignoredOptionalCapabilitiesEqual(lhs, rhs)
                && requestedBackendsEqual(lhs, rhs)
                && stageCMetadataEqual(lhs, rhs))
    }

    @inline(never)
    private static func definitionsEqual(
        _ lhs: BrushProgram,
        _ rhs: BrushProgram
    ) -> Bool {
        lhs.definition == rhs.definition
    }

    @inline(never)
    private static func dynamicsEqual(
        _ lhs: BrushProgram,
        _ rhs: BrushProgram
    ) -> Bool {
        lhs.dynamics == rhs.dynamics
    }

    @inline(never)
    private static func terminationsEqual(
        _ lhs: BrushProgram,
        _ rhs: BrushProgram
    ) -> Bool {
        lhs.termination == rhs.termination
    }

    @inline(never)
    private static func requiredCapabilitiesEqual(
        _ lhs: BrushProgram,
        _ rhs: BrushProgram
    ) -> Bool {
        lhs.requiredCapabilities == rhs.requiredCapabilities
    }

    @inline(never)
    private static func ignoredOptionalCapabilitiesEqual(
        _ lhs: BrushProgram,
        _ rhs: BrushProgram
    ) -> Bool {
        lhs.ignoredOptionalCapabilityIdentifiers
            == rhs.ignoredOptionalCapabilityIdentifiers
    }

    @inline(never)
    private static func requestedBackendsEqual(
        _ lhs: BrushProgram,
        _ rhs: BrushProgram
    ) -> Bool {
        lhs.requestedBackend == rhs.requestedBackend
    }

    @inline(never)
    private static func stageCMetadataEqual(
        _ lhs: BrushProgram,
        _ rhs: BrushProgram
    ) -> Bool {
        switch (lhs.stageC, rhs.stageC) {
        case (nil, nil):
            true
        case let (.some(lhsMetadata), .some(rhsMetadata)):
            lhsMetadata == rhsMetadata
        case (.some, nil), (nil, .some):
            false
        }
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
