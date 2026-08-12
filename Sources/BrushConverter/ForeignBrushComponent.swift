import Foundation

public struct ForeignBrushComponent: Codable, Equatable, Sendable {
    public let identifier: String
    public let ordinal: UInt16
    public let sourcePath: String
    public let settings: [ForeignBrushSetting]
    public let resources: [ForeignBrushResourceDescriptor]
    public let diagnostics: [ForeignBrushDiagnostic]

    public init(
        identifier: String,
        ordinal: UInt16,
        sourcePath: String,
        settings: [ForeignBrushSetting],
        resources: [ForeignBrushResourceDescriptor],
        diagnostics: [ForeignBrushDiagnostic]
    ) throws {
        try ForeignBrushValidator.string(
            identifier,
            field: "component.identifier"
        )
        try ForeignBrushValidator.location(
            sourcePath,
            field: "component.sourcePath"
        )
        try ForeignBrushValidator.sortedUnique(
            settings,
            field: "component.settings",
            key: \.semanticKey
        )
        try ForeignBrushValidator.sortedUnique(
            resources,
            field: "component.resources",
            key: \.id
        )
        try ForeignBrushValidator.sortedUnique(
            diagnostics,
            field: "component.diagnostics",
            key: \.stableIdentity
        )
        let resourceIDs = Set(resources.map(\.id))
        for setting in settings {
            guard let reference = setting.value.resourceReference else {
                continue
            }
            guard resourceIDs.contains(reference) else {
                throw ForeignBrushValidationError.danglingResourceReference(
                    settingKey: setting.semanticKey,
                    resourceID: reference
                )
            }
        }
        self.identifier = identifier
        self.ordinal = ordinal
        self.sourcePath = sourcePath
        self.settings = settings
        self.resources = resources
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case ordinal
        case sourcePath
        case settings
        case resources
        case diagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: container.decode(String.self, forKey: .identifier),
            ordinal: container.decode(UInt16.self, forKey: .ordinal),
            sourcePath: container.decode(String.self, forKey: .sourcePath),
            settings: container.decode(
                [ForeignBrushSetting].self,
                forKey: .settings
            ),
            resources: container.decode(
                [ForeignBrushResourceDescriptor].self,
                forKey: .resources
            ),
            diagnostics: container.decode(
                [ForeignBrushDiagnostic].self,
                forKey: .diagnostics
            )
        )
    }
}
