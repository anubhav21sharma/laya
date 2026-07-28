import Foundation

public struct ForeignBrushProvenance: Codable, Equatable, Sendable {
    public let sourceFormatFamily: String
    public let sourceFormatVersion: String?
    public let sourceContentSHA256: String
    public let parserIdentifier: String
    public let parserVersion: String

    public init(
        sourceFormatFamily: String,
        sourceFormatVersion: String?,
        sourceContentSHA256: String,
        parserIdentifier: String,
        parserVersion: String
    ) throws {
        try ForeignBrushValidator.string(
            sourceFormatFamily,
            field: "provenance.sourceFormatFamily"
        )
        try ForeignBrushValidator.optionalString(
            sourceFormatVersion,
            field: "provenance.sourceFormatVersion"
        )
        try ForeignBrushValidator.sha256(
            sourceContentSHA256,
            field: "provenance.sourceContentSHA256"
        )
        try ForeignBrushValidator.string(
            parserIdentifier,
            field: "provenance.parserIdentifier"
        )
        try ForeignBrushValidator.string(
            parserVersion,
            field: "provenance.parserVersion"
        )
        self.sourceFormatFamily = sourceFormatFamily
        self.sourceFormatVersion = sourceFormatVersion
        self.sourceContentSHA256 = sourceContentSHA256
        self.parserIdentifier = parserIdentifier
        self.parserVersion = parserVersion
    }

    private enum CodingKeys: String, CodingKey {
        case sourceFormatFamily
        case sourceFormatVersion
        case sourceContentSHA256
        case parserIdentifier
        case parserVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sourceFormatFamily: container.decode(
                String.self,
                forKey: .sourceFormatFamily
            ),
            sourceFormatVersion: container.decodeIfPresent(
                String.self,
                forKey: .sourceFormatVersion
            ),
            sourceContentSHA256: container.decode(
                String.self,
                forKey: .sourceContentSHA256
            ),
            parserIdentifier: container.decode(
                String.self,
                forKey: .parserIdentifier
            ),
            parserVersion: container.decode(
                String.self,
                forKey: .parserVersion
            )
        )
    }
}

public enum ForeignBrushDiagnosticSeverity:
    String, Codable, CaseIterable, Sendable
{
    case information
    case warning
    case error
}

public struct ForeignBrushDiagnostic: Codable, Equatable, Sendable {
    public let severity: ForeignBrushDiagnosticSeverity
    public let code: String
    public let location: String?
    public let message: String

    public var stableIdentity: String {
        [
            location ?? "",
            code,
            severity.rawValue,
            message,
        ].joined(separator: "\u{001f}")
    }

    public init(
        severity: ForeignBrushDiagnosticSeverity,
        code: String,
        location: String?,
        message: String
    ) throws {
        try ForeignBrushValidator.string(code, field: "diagnostic.code")
        if let location {
            try ForeignBrushValidator.location(
                location,
                field: "diagnostic.location"
            )
        }
        try ForeignBrushValidator.string(
            message,
            field: "diagnostic.message"
        )
        self.severity = severity
        self.code = code
        self.location = location
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case severity, code, location, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            severity: container.decode(
                ForeignBrushDiagnosticSeverity.self,
                forKey: .severity
            ),
            code: container.decode(String.self, forKey: .code),
            location: container.decodeIfPresent(
                String.self,
                forKey: .location
            ),
            message: container.decode(String.self, forKey: .message)
        )
    }
}

public struct ForeignBrushIR: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let provenance: ForeignBrushProvenance
    public let sourceBrushIdentifier: String
    public let displayName: String
    public let author: String?
    public let settings: [ForeignBrushSetting]
    public let resources: [ForeignBrushResourceDescriptor]
    public let diagnostics: [ForeignBrushDiagnostic]

    public init(
        schemaVersion: UInt16 = currentSchemaVersion,
        provenance: ForeignBrushProvenance,
        sourceBrushIdentifier: String,
        displayName: String,
        author: String? = nil,
        settings: [ForeignBrushSetting],
        resources: [ForeignBrushResourceDescriptor],
        diagnostics: [ForeignBrushDiagnostic]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForeignBrushValidationError.unsupportedSchema(schemaVersion)
        }
        try ForeignBrushValidator.string(
            sourceBrushIdentifier,
            field: "ir.sourceBrushIdentifier"
        )
        try ForeignBrushValidator.string(
            displayName,
            field: "ir.displayName"
        )
        try ForeignBrushValidator.optionalString(author, field: "ir.author")
        try ForeignBrushValidator.count(
            settings.count,
            field: "ir.settings",
            maximum: ForeignBrushLimits.maximumSettingsPerBrush
        )
        try ForeignBrushValidator.sortedUnique(
            settings,
            field: "ir.settings",
            key: \.semanticKey
        )
        try ForeignBrushValidator.count(
            resources.count,
            field: "ir.resources",
            maximum: ForeignBrushLimits.maximumResourcesPerBrush
        )
        try ForeignBrushValidator.sortedUnique(
            resources,
            field: "ir.resources",
            key: \.id
        )
        var cumulativeDecodedPixels = 0
        var cumulativeEncodedBytes = 0
        for resource in resources {
            let (resourcePixels, multiplicationOverflow) =
                resource.pixelWidth.multipliedReportingOverflow(
                    by: resource.pixelHeight
                )
            let (next, additionOverflow) =
                cumulativeDecodedPixels.addingReportingOverflow(
                    resourcePixels
                )
            guard !multiplicationOverflow,
                  !additionOverflow,
                  next <= ForeignBrushLimits
                    .maximumCumulativeDecodedPixelsPerBrush
            else {
                throw ForeignBrushValidationError
                    .cumulativeDecodedPixelsExceeded(
                        maximum:
                            ForeignBrushLimits
                            .maximumCumulativeDecodedPixelsPerBrush
                    )
            }
            cumulativeDecodedPixels = next

            let (nextBytes, byteOverflow) =
                cumulativeEncodedBytes.addingReportingOverflow(
                    resource.encodedByteCount
                )
            guard !byteOverflow,
                  nextBytes <=
                    ForeignBrushLimits.maximumCumulativeResourceBytes
            else {
                throw ForeignBrushValidationError
                    .cumulativeResourceBytesExceeded(
                        maximum:
                            ForeignBrushLimits.maximumCumulativeResourceBytes
                    )
            }
            cumulativeEncodedBytes = nextBytes
        }
        try ForeignBrushValidator.count(
            diagnostics.count,
            field: "ir.diagnostics",
            maximum: ForeignBrushLimits.maximumDiagnosticsPerBrush
        )
        try ForeignBrushValidator.sortedUnique(
            diagnostics,
            field: "ir.diagnostics",
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

        self.schemaVersion = schemaVersion
        self.provenance = provenance
        self.sourceBrushIdentifier = sourceBrushIdentifier
        self.displayName = displayName
        self.author = author
        self.settings = settings
        self.resources = resources
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case provenance
        case sourceBrushIdentifier
        case displayName
        case author
        case settings
        case resources
        case diagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(
                UInt16.self,
                forKey: .schemaVersion
            ),
            provenance: container.decode(
                ForeignBrushProvenance.self,
                forKey: .provenance
            ),
            sourceBrushIdentifier: container.decode(
                String.self,
                forKey: .sourceBrushIdentifier
            ),
            displayName: container.decode(String.self, forKey: .displayName),
            author: container.decodeIfPresent(String.self, forKey: .author),
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
