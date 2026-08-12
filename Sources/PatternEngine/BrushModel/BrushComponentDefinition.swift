public struct BrushComponentIdentifier:
    RawRepresentable, Codable, Equatable, Hashable, Sendable
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }
}

public struct BrushCompositionModeDeclaration:
    Codable, Equatable, Sendable
{
    public static let orderedSourceOverIdentifier =
        "native.ordered-source-over"

    public let identifier: String
    public let required: Bool

    public init(identifier: String, required: Bool) {
        self.identifier = identifier
        self.required = required
    }

    public static let orderedSourceOver = BrushCompositionModeDeclaration(
        identifier: orderedSourceOverIdentifier,
        required: true
    )
}

public struct BrushComponentDefinition: Codable, Equatable, Sendable {
    public let identifier: BrushComponentIdentifier
    public let ordinal: UInt8
    public let resources: [BrushResourceReference]
    public let coverage: BrushCoverageDefinition
    public let placement: BrushPlacementDefinition
    public let dynamics: BrushDynamicsDefinition
    public let color: BrushColorBehaviorDefinition
    public let material: BrushMaterialDefinition
    public let taper: BrushTaperConfiguration
    public let sensorProgram: BrushSensorProgramDefinition
    public let emission: BrushEmissionDefinition
    public let tipSupports: [BrushTipSupportDefinition]

    public init(
        identifier: BrushComponentIdentifier,
        ordinal: UInt8,
        resources: [BrushResourceReference],
        coverage: BrushCoverageDefinition,
        placement: BrushPlacementDefinition,
        dynamics: BrushDynamicsDefinition,
        color: BrushColorBehaviorDefinition,
        material: BrushMaterialDefinition,
        taper: BrushTaperConfiguration,
        sensorProgram: BrushSensorProgramDefinition,
        emission: BrushEmissionDefinition,
        tipSupports: [BrushTipSupportDefinition]
    ) {
        self.identifier = identifier
        self.ordinal = ordinal
        self.resources = resources
        self.coverage = coverage
        self.placement = placement
        self.dynamics = dynamics
        self.color = color
        self.material = material
        self.taper = taper
        self.sensorProgram = sensorProgram
        self.emission = emission
        self.tipSupports = tipSupports
    }
}
