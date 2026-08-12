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
        try ForeignBrushValidator.diagnosticCode(code)
        if let location {
            try ForeignBrushValidator.location(
                location,
                field: "diagnostic.location"
            )
        }
        try ForeignBrushValidator.string(
            message,
            field: "diagnostic.message",
            maximumUTF8Bytes:
                ForeignBrushLimits.maximumDiagnosticMessageUTF8Bytes
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
    public static let currentSchemaVersion: UInt16 = 2

    public let schemaVersion: UInt16
    public let provenance: ForeignBrushProvenance
    public let sourceBrushIdentifier: String
    public let displayName: String
    public let author: String?
    public let components: [ForeignBrushComponent]

    public var settings: [ForeignBrushSetting] {
        components.flatMap(\.settings)
    }

    public var resources: [ForeignBrushResourceDescriptor] {
        components.flatMap(\.resources)
    }

    public var diagnostics: [ForeignBrushDiagnostic] {
        components.flatMap(\.diagnostics)
    }

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
        guard schemaVersion == 1 || schemaVersion == Self.currentSchemaVersion else {
            throw ForeignBrushValidationError.unsupportedSchema(schemaVersion)
        }
        try ForeignBrushValidator.sortedUnique(
            settings,
            field: "ir.settings",
            key: \.semanticKey
        )
        try ForeignBrushValidator.sortedUnique(
            resources,
            field: "ir.resources",
            key: \.id
        )
        try ForeignBrushValidator.sortedUnique(
            diagnostics,
            field: "ir.diagnostics",
            key: \.stableIdentity
        )
        let root = try ForeignBrushComponent(
            identifier: "root",
            ordinal: 0,
            sourcePath: "Brush.archive",
            settings: settings,
            resources: resources,
            diagnostics: diagnostics
        )
        try self.init(
            provenance: provenance,
            sourceBrushIdentifier: sourceBrushIdentifier,
            displayName: displayName,
            author: author,
            components: [root]
        )
    }

    public init(
        provenance: ForeignBrushProvenance,
        sourceBrushIdentifier: String,
        displayName: String,
        author: String? = nil,
        components: [ForeignBrushComponent]
    ) throws {
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
            components.count,
            field: "ir.components",
            maximum: ForeignBrushLimits.maximumComponentsPerBrush,
            minimum: 1
        )
        let identifiers = components.map(\.identifier)
        if Set(identifiers).count != identifiers.count {
            let duplicate = identifiers.first { identifier in
                identifiers.filter { $0 == identifier }.count > 1
            }!
            throw ForeignBrushValidationError.duplicate(
                field: "ir.components.identifier",
                value: duplicate
            )
        }
        for (index, component) in components.enumerated() {
            guard component.ordinal == UInt16(index),
                  (index == 0 && component.identifier == "root")
                    || (index == 1 && component.identifier == "sub01")
            else {
                throw ForeignBrushValidationError.outOfRange(
                    "ir.components.ordinal"
                )
            }
        }
        let settings = components.flatMap(\.settings)
        try ForeignBrushValidator.count(
            settings.count,
            field: "ir.settings",
            maximum: ForeignBrushLimits.maximumSettingsPerBrush
        )
        let resources = components.flatMap(\.resources)
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
        let diagnostics = components.flatMap(\.diagnostics)
        try ForeignBrushValidator.count(
            diagnostics.count,
            field: "ir.diagnostics",
            maximum: ForeignBrushLimits.maximumDiagnosticsPerBrush
        )

        self.schemaVersion = Self.currentSchemaVersion
        self.provenance = provenance
        self.sourceBrushIdentifier = sourceBrushIdentifier
        self.displayName = displayName
        self.author = author
        self.components = components
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case provenance
        case sourceBrushIdentifier
        case displayName
        case author
        case components
        case settings
        case resources
        case diagnostics
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(
            sourceBrushIdentifier,
            forKey: .sourceBrushIdentifier
        )
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encode(components, forKey: .components)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        let provenance = try container.decode(
            ForeignBrushProvenance.self,
            forKey: .provenance
        )
        let sourceBrushIdentifier = try container.decode(
            String.self,
            forKey: .sourceBrushIdentifier
        )
        let displayName = try container.decode(
            String.self,
            forKey: .displayName
        )
        let author = try container.decodeIfPresent(
            String.self,
            forKey: .author
        )
        switch schemaVersion {
        case 1:
            try self.init(
                schemaVersion: 1,
                provenance: provenance,
                sourceBrushIdentifier: sourceBrushIdentifier,
                displayName: displayName,
                author: author,
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
        case Self.currentSchemaVersion:
            try self.init(
                provenance: provenance,
                sourceBrushIdentifier: sourceBrushIdentifier,
                displayName: displayName,
                author: author,
                components: container.decode(
                    [ForeignBrushComponent].self,
                    forKey: .components
                )
            )
        default:
            throw ForeignBrushValidationError.unsupportedSchema(schemaVersion)
        }
    }
}
