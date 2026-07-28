import Foundation
import PatternEngine

public enum BrushConversionDisposition:
    String, Codable, CaseIterable, Equatable, Sendable
{
    case exact
    case approximated
    case unsupported
    case resourceResampled
}

public struct BrushConversionApproximationEvidence:
    Codable, Equatable, Sendable
{
    public let metric: String
    public let absoluteError: Double?
    public let relativeError: Double?

    public init(
        metric: String,
        absoluteError: Double? = nil,
        relativeError: Double? = nil
    ) throws {
        try BrushConversionReportValidator.boundedText(
            metric,
            field: "approximation.metric",
            maximumUTF8Bytes: 256
        )
        try BrushConversionReportValidator.nonnegativeFinite(
            absoluteError,
            field: "approximation.absoluteError"
        )
        try BrushConversionReportValidator.nonnegativeFinite(
            relativeError,
            field: "approximation.relativeError"
        )
        guard absoluteError != nil || relativeError != nil else {
            throw BrushConversionReportValidationError
                .invalidEvidence("approximation.error")
        }
        self.metric = metric
        self.absoluteError = absoluteError
        self.relativeError = relativeError
    }

    private enum CodingKeys: String, CodingKey {
        case metric, absoluteError, relativeError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metric: container.decode(String.self, forKey: .metric),
            absoluteError: container.decodeIfPresent(
                Double.self,
                forKey: .absoluteError
            ),
            relativeError: container.decodeIfPresent(
                Double.self,
                forKey: .relativeError
            )
        )
    }
}

public enum BrushResourceTransformOperation:
    String, Codable, CaseIterable, Equatable, Sendable
{
    case resize
    case transcode
    case channelNormalization
    case inversion
    case orientationCorrection
    case colorProfileConversion
}

public struct BrushConversionResourceTransformEvidence:
    Codable, Equatable, Sendable
{
    public let resourceIdentifier: String
    public let sourceMediaType: String
    public let targetMediaType: String
    public let sourcePixelWidth: Int
    public let sourcePixelHeight: Int
    public let targetPixelWidth: Int
    public let targetPixelHeight: Int
    public let operations: [BrushResourceTransformOperation]

    public init(
        resourceIdentifier: String,
        sourceMediaType: String,
        targetMediaType: String,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        targetPixelWidth: Int,
        targetPixelHeight: Int,
        operations: [BrushResourceTransformOperation]
    ) throws {
        try BrushConversionReportValidator.boundedText(
            resourceIdentifier,
            field: "resourceTransform.resourceIdentifier",
            maximumUTF8Bytes: 512
        )
        try BrushConversionReportValidator.mediaType(
            sourceMediaType,
            field: "resourceTransform.sourceMediaType"
        )
        try BrushConversionReportValidator.mediaType(
            targetMediaType,
            field: "resourceTransform.targetMediaType"
        )
        for (field, value) in [
            ("resourceTransform.sourcePixelWidth", sourcePixelWidth),
            ("resourceTransform.sourcePixelHeight", sourcePixelHeight),
            ("resourceTransform.targetPixelWidth", targetPixelWidth),
            ("resourceTransform.targetPixelHeight", targetPixelHeight),
        ] {
            guard (1...16_384).contains(value) else {
                throw BrushConversionReportValidationError.outOfRange(field)
            }
        }
        let sorted = operations.sorted { $0.rawValue < $1.rawValue }
        guard !sorted.isEmpty else {
            throw BrushConversionReportValidationError
                .invalidEvidence("resourceTransform.operations")
        }
        guard sorted == operations else {
            throw BrushConversionReportValidationError
                .unsorted("resourceTransform.operations")
        }
        guard Set(sorted).count == sorted.count else {
            throw BrushConversionReportValidationError
                .duplicate("resourceTransform.operations")
        }
        let dimensionsDiffer =
            sourcePixelWidth != targetPixelWidth
            || sourcePixelHeight != targetPixelHeight
        let hasResize = operations.contains(.resize)
        let hasOrientationCorrection = operations.contains(
            .orientationCorrection
        )
        guard !hasResize || dimensionsDiffer else {
            throw BrushConversionReportValidationError
                .invalidEvidence("resourceTransform.resize")
        }
        guard !dimensionsDiffer || hasResize || hasOrientationCorrection else {
            throw BrushConversionReportValidationError
                .invalidEvidence("resourceTransform.dimensions")
        }
        if dimensionsDiffer, !hasResize, hasOrientationCorrection {
            guard sourcePixelWidth == targetPixelHeight,
                  sourcePixelHeight == targetPixelWidth
            else {
                throw BrushConversionReportValidationError
                    .invalidEvidence(
                        "resourceTransform.orientationDimensions"
                    )
            }
        }
        let mediaTypesDiffer = sourceMediaType != targetMediaType
        guard mediaTypesDiffer == operations.contains(.transcode) else {
            throw BrushConversionReportValidationError
                .invalidEvidence("resourceTransform.transcode")
        }
        self.resourceIdentifier = resourceIdentifier
        self.sourceMediaType = sourceMediaType
        self.targetMediaType = targetMediaType
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.targetPixelWidth = targetPixelWidth
        self.targetPixelHeight = targetPixelHeight
        self.operations = operations
    }

    private enum CodingKeys: String, CodingKey {
        case resourceIdentifier
        case sourceMediaType
        case targetMediaType
        case sourcePixelWidth
        case sourcePixelHeight
        case targetPixelWidth
        case targetPixelHeight
        case operations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            resourceIdentifier: container.decode(
                String.self,
                forKey: .resourceIdentifier
            ),
            sourceMediaType: container.decode(
                String.self,
                forKey: .sourceMediaType
            ),
            targetMediaType: container.decode(
                String.self,
                forKey: .targetMediaType
            ),
            sourcePixelWidth: container.decode(
                Int.self,
                forKey: .sourcePixelWidth
            ),
            sourcePixelHeight: container.decode(
                Int.self,
                forKey: .sourcePixelHeight
            ),
            targetPixelWidth: container.decode(
                Int.self,
                forKey: .targetPixelWidth
            ),
            targetPixelHeight: container.decode(
                Int.self,
                forKey: .targetPixelHeight
            ),
            operations: container.decode(
                [BrushResourceTransformOperation].self,
                forKey: .operations
            )
        )
    }
}

public struct BrushConversionEntry: Codable, Equatable, Sendable {
    public let sourceSemanticKey: String
    public let nativeSemanticKeys: [String]
    public let disposition: BrushConversionDisposition
    public let sourceSummary: String
    public let targetSummary: String?
    public let reasonCode: String
    public let message: String
    public let approximation: BrushConversionApproximationEvidence?
    public let resourceTransform: BrushConversionResourceTransformEvidence?
    public let requiredForFaithfulRendering: Bool

    public init(
        sourceSemanticKey: String,
        nativeSemanticKeys: [String],
        disposition: BrushConversionDisposition,
        sourceSummary: String,
        targetSummary: String?,
        reasonCode: String,
        message: String,
        approximation: BrushConversionApproximationEvidence? = nil,
        resourceTransform: BrushConversionResourceTransformEvidence? = nil,
        requiredForFaithfulRendering: Bool = false
    ) throws {
        try BrushConversionReportValidator.semanticKey(
            sourceSemanticKey,
            field: "entry.sourceSemanticKey"
        )
        try BrushConversionReportValidator.sortedUniqueNativeSemanticKeys(
            nativeSemanticKeys,
            field: "entry.nativeSemanticKeys"
        )
        try BrushConversionReportValidator.boundedText(
            sourceSummary,
            field: "entry.sourceSummary",
            maximumUTF8Bytes: 2_048
        )
        if let targetSummary {
            try BrushConversionReportValidator.boundedText(
                targetSummary,
                field: "entry.targetSummary",
                maximumUTF8Bytes: 2_048
            )
        }
        try BrushConversionReportValidator.token(
            reasonCode,
            field: "entry.reasonCode",
            maximumUTF8Bytes: 256
        )
        try BrushConversionReportValidator.boundedText(
            message,
            field: "entry.message",
            maximumUTF8Bytes: 4_096
        )

        switch disposition {
        case .exact:
            guard !nativeSemanticKeys.isEmpty,
                  targetSummary != nil,
                  approximation == nil,
                  resourceTransform == nil,
                  !requiredForFaithfulRendering
            else {
                throw BrushConversionReportValidationError
                    .invalidEvidence("entry.exact")
            }
        case .approximated:
            guard !nativeSemanticKeys.isEmpty,
                  targetSummary != nil,
                  approximation != nil,
                  resourceTransform == nil,
                  !requiredForFaithfulRendering
            else {
                throw BrushConversionReportValidationError
                    .invalidEvidence("entry.approximated")
            }
        case .unsupported:
            guard approximation == nil, resourceTransform == nil else {
                throw BrushConversionReportValidationError
                    .invalidEvidence("entry.unsupported")
            }
        case .resourceResampled:
            guard !nativeSemanticKeys.isEmpty,
                  targetSummary != nil,
                  approximation == nil,
                  resourceTransform != nil,
                  !requiredForFaithfulRendering
            else {
                throw BrushConversionReportValidationError
                    .invalidEvidence("entry.resourceResampled")
            }
        }

        self.sourceSemanticKey = sourceSemanticKey
        self.nativeSemanticKeys = nativeSemanticKeys
        self.disposition = disposition
        self.sourceSummary = sourceSummary
        self.targetSummary = targetSummary
        self.reasonCode = reasonCode
        self.message = message
        self.approximation = approximation
        self.resourceTransform = resourceTransform
        self.requiredForFaithfulRendering = requiredForFaithfulRendering
    }

    private enum CodingKeys: String, CodingKey {
        case sourceSemanticKey
        case nativeSemanticKeys
        case disposition
        case sourceSummary
        case targetSummary
        case reasonCode
        case message
        case approximation
        case resourceTransform
        case requiredForFaithfulRendering
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sourceSemanticKey: container.decode(
                String.self,
                forKey: .sourceSemanticKey
            ),
            nativeSemanticKeys: container.decode(
                [String].self,
                forKey: .nativeSemanticKeys
            ),
            disposition: container.decode(
                BrushConversionDisposition.self,
                forKey: .disposition
            ),
            sourceSummary: container.decode(
                String.self,
                forKey: .sourceSummary
            ),
            targetSummary: container.decodeIfPresent(
                String.self,
                forKey: .targetSummary
            ),
            reasonCode: container.decode(String.self, forKey: .reasonCode),
            message: container.decode(String.self, forKey: .message),
            approximation: container.decodeIfPresent(
                BrushConversionApproximationEvidence.self,
                forKey: .approximation
            ),
            resourceTransform: container.decodeIfPresent(
                BrushConversionResourceTransformEvidence.self,
                forKey: .resourceTransform
            ),
            requiredForFaithfulRendering: container.decode(
                Bool.self,
                forKey: .requiredForFaithfulRendering
            )
        )
    }
}

public enum BrushConversionDiagnosticSeverity:
    String, Codable, CaseIterable, Equatable, Sendable
{
    case info
    case warning
    case error
}

public struct BrushConversionDiagnostic: Codable, Equatable, Sendable {
    public let severity: BrushConversionDiagnosticSeverity
    public let code: String
    public let message: String
    public let location: String?

    public init(
        severity: BrushConversionDiagnosticSeverity,
        code: String,
        message: String,
        location: String? = nil
    ) throws {
        try BrushConversionReportValidator.token(
            code,
            field: "diagnostic.code",
            maximumUTF8Bytes: 256
        )
        try BrushConversionReportValidator.boundedText(
            message,
            field: "diagnostic.message",
            maximumUTF8Bytes: 4_096
        )
        if let location {
            try BrushConversionReportValidator.boundedText(
                location,
                field: "diagnostic.location",
                maximumUTF8Bytes: 1_024
            )
        }
        self.severity = severity
        self.code = code
        self.message = message
        self.location = location
    }

    package var sortKey: String {
        "\(location ?? "")\u{0}\(code)\u{0}\(severity.rawValue)\u{0}\(message)"
    }

    private enum CodingKeys: String, CodingKey {
        case severity, code, message, location
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            severity: container.decode(
                BrushConversionDiagnosticSeverity.self,
                forKey: .severity
            ),
            code: container.decode(String.self, forKey: .code),
            message: container.decode(String.self, forKey: .message),
            location: container.decodeIfPresent(
                String.self,
                forKey: .location
            )
        )
    }
}

public struct BrushConversionSummary: Codable, Equatable, Sendable {
    public let exact: Int
    public let approximated: Int
    public let unsupported: Int
    public let resourceResampled: Int

    public init(
        exact: Int,
        approximated: Int,
        unsupported: Int,
        resourceResampled: Int
    ) throws {
        guard exact >= 0,
              approximated >= 0,
              unsupported >= 0,
              resourceResampled >= 0
        else {
            throw BrushConversionReportValidationError
                .outOfRange("summary")
        }
        self.exact = exact
        self.approximated = approximated
        self.unsupported = unsupported
        self.resourceResampled = resourceResampled
    }

    private enum CodingKeys: String, CodingKey {
        case exact, approximated, unsupported, resourceResampled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            exact: container.decode(Int.self, forKey: .exact),
            approximated: container.decode(Int.self, forKey: .approximated),
            unsupported: container.decode(Int.self, forKey: .unsupported),
            resourceResampled: container.decode(
                Int.self,
                forKey: .resourceResampled
            )
        )
    }

    package init(entries: [BrushConversionEntry]) {
        exact = entries.count { $0.disposition == .exact }
        approximated = entries.count { $0.disposition == .approximated }
        unsupported = entries.count { $0.disposition == .unsupported }
        resourceResampled = entries.count {
            $0.disposition == .resourceResampled
        }
    }

    package var total: Int {
        exact + approximated + unsupported + resourceResampled
    }
}

public struct BrushConversionReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let maximumEntries = 4_096
    public static let maximumDiagnostics = 4_096

    public let schemaVersion: UInt16
    public let sourceFormat: String
    public let sourceVersion: String?
    public let sourceContentHash: String
    public let converterIdentifier: String
    public let converterVersion: String
    public let targetDefinitionID: String
    public let targetPackageContentHash: String
    public let entries: [BrushConversionEntry]
    public let diagnostics: [BrushConversionDiagnostic]
    public let summary: BrushConversionSummary

    public init(
        schemaVersion: UInt16 = currentSchemaVersion,
        sourceFormat: String,
        sourceVersion: String?,
        sourceContentHash: String,
        converterIdentifier: String,
        converterVersion: String,
        targetDefinitionID: String,
        targetPackageContentHash: String,
        entries: [BrushConversionEntry],
        diagnostics: [BrushConversionDiagnostic]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw BrushConversionReportValidationError
                .unsupportedSchema(schemaVersion)
        }
        for (field, value) in [
            ("report.sourceFormat", sourceFormat),
            ("report.converterIdentifier", converterIdentifier),
            ("report.converterVersion", converterVersion),
        ] {
            try BrushConversionReportValidator.token(
                value,
                field: field,
                maximumUTF8Bytes: 256
            )
        }
        if let sourceVersion {
            try BrushConversionReportValidator.boundedText(
                sourceVersion,
                field: "report.sourceVersion",
                maximumUTF8Bytes: 256
            )
        }
        try BrushConversionReportValidator.sha256(
            sourceContentHash,
            field: "report.sourceContentHash"
        )
        try BrushConversionReportValidator.boundedText(
            targetDefinitionID,
            field: "report.targetDefinitionID",
            maximumUTF8Bytes: 512
        )
        try BrushConversionReportValidator.sha256(
            targetPackageContentHash,
            field: "report.targetPackageContentHash"
        )
        guard entries.count <= Self.maximumEntries else {
            throw BrushConversionReportValidationError
                .tooManyEntries(entries.count)
        }
        guard diagnostics.count <= Self.maximumDiagnostics else {
            throw BrushConversionReportValidationError
                .tooManyDiagnostics(diagnostics.count)
        }
        let entryKeys = entries.map(\.sourceSemanticKey)
        try BrushConversionReportValidator.sortedUniqueSemanticKeys(
            entryKeys,
            field: "report.entries"
        )
        let diagnosticKeys = diagnostics.map(\.sortKey)
        guard diagnosticKeys == diagnosticKeys.sorted() else {
            throw BrushConversionReportValidationError
                .unsorted("report.diagnostics")
        }
        guard Set(diagnosticKeys).count == diagnosticKeys.count else {
            throw BrushConversionReportValidationError
                .duplicate("report.diagnostics")
        }
        self.schemaVersion = schemaVersion
        self.sourceFormat = sourceFormat
        self.sourceVersion = sourceVersion
        self.sourceContentHash = sourceContentHash
        self.converterIdentifier = converterIdentifier
        self.converterVersion = converterVersion
        self.targetDefinitionID = targetDefinitionID
        self.targetPackageContentHash = targetPackageContentHash
        self.entries = entries
        self.diagnostics = diagnostics
        summary = BrushConversionSummary(entries: entries)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourceFormat
        case sourceVersion
        case sourceContentHash
        case converterIdentifier
        case converterVersion
        case targetDefinitionID
        case targetPackageContentHash
        case entries
        case diagnostics
        case summary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode(
            [BrushConversionEntry].self,
            forKey: .entries
        )
        try self.init(
            schemaVersion: container.decode(
                UInt16.self,
                forKey: .schemaVersion
            ),
            sourceFormat: container.decode(
                String.self,
                forKey: .sourceFormat
            ),
            sourceVersion: container.decodeIfPresent(
                String.self,
                forKey: .sourceVersion
            ),
            sourceContentHash: container.decode(
                String.self,
                forKey: .sourceContentHash
            ),
            converterIdentifier: container.decode(
                String.self,
                forKey: .converterIdentifier
            ),
            converterVersion: container.decode(
                String.self,
                forKey: .converterVersion
            ),
            targetDefinitionID: container.decode(
                String.self,
                forKey: .targetDefinitionID
            ),
            targetPackageContentHash: container.decode(
                String.self,
                forKey: .targetPackageContentHash
            ),
            entries: entries,
            diagnostics: container.decode(
                [BrushConversionDiagnostic].self,
                forKey: .diagnostics
            )
        )
        let encodedSummary = try container.decode(
            BrushConversionSummary.self,
            forKey: .summary
        )
        guard encodedSummary == summary,
              encodedSummary.total == entries.count
        else {
            throw BrushConversionReportValidationError.invalidSummary
        }
    }

    package func validate(
        against definition: BrushDefinition,
        resources: [BrushPackageResource],
        targetPackageContentHash: String
    ) throws {
        guard targetDefinitionID == definition.id.rawValue else {
            throw BrushConversionReportValidationError
                .targetDefinitionMismatch
        }
        guard self.targetPackageContentHash == targetPackageContentHash else {
            throw BrushConversionReportValidationError
                .targetContentHashMismatch
        }
        let sourceKeys = entries.map(\.sourceSemanticKey)
        guard sourceKeys == definition.compatibility.sourceSettingKeys else {
            throw BrushConversionReportValidationError
                .sourceSettingCoverageMismatch
        }
        let requiredKeys = entries.compactMap { entry in
            entry.disposition == .unsupported
                && entry.requiredForFaithfulRendering
                ? entry.sourceSemanticKey
                : nil
        }
        guard requiredKeys == definition.compatibility.requiredSemanticKeys
        else {
            throw BrushConversionReportValidationError
                .requiredSemanticCoverageMismatch
        }
        for entry in entries {
            for nativeKey in entry.nativeSemanticKeys {
                guard BrushNativeSemanticKeyRegistry.supports(
                    nativeKey,
                    in: definition
                ) else {
                    throw BrushConversionReportValidationError
                        .unknownNativeSemanticKey(nativeKey)
                }
            }
        }
        let resourcesByID = Dictionary(
            uniqueKeysWithValues: resources.map { ($0.id, $0) }
        )
        for entry in entries {
            guard let transform = entry.resourceTransform else { continue }
            guard let resource = resourcesByID[transform.resourceIdentifier],
                  resource.mediaType == transform.targetMediaType,
                  resource.pixelWidth == transform.targetPixelWidth,
                  resource.pixelHeight == transform.targetPixelHeight
            else {
                throw BrushConversionReportValidationError
                    .resourceTransformMismatch(
                        transform.resourceIdentifier
                    )
            }
        }
    }
}

public enum BrushConversionReportValidationError:
    Error, Equatable, Sendable
{
    case unsupportedSchema(UInt16)
    case invalidText(String)
    case invalidToken(String)
    case invalidHash(String)
    case nonfinite(String)
    case outOfRange(String)
    case unsorted(String)
    case duplicate(String)
    case invalidEvidence(String)
    case invalidSummary
    case tooManyEntries(Int)
    case tooManyDiagnostics(Int)
    case sourceSettingCoverageMismatch
    case requiredSemanticCoverageMismatch
    case targetDefinitionMismatch
    case targetContentHashMismatch
    case resourceTransformMismatch(String)
    case unknownNativeSemanticKey(String)
}

package enum BrushConversionReportCodec {
    static func encode(_ report: BrushConversionReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(report)
    }

    static func decode(_ data: Data) throws -> BrushConversionReport {
        try JSONDecoder().decode(BrushConversionReport.self, from: data)
    }
}

private enum BrushConversionReportValidator {
    static func boundedText(
        _ value: String,
        field: String,
        maximumUTF8Bytes: Int
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Bytes,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw BrushConversionReportValidationError.invalidText(field)
        }
    }

    static func token(
        _ value: String,
        field: String,
        maximumUTF8Bytes: Int
    ) throws {
        try boundedText(
            value,
            field: field,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
        guard value.unicodeScalars.allSatisfy({
            $0.isASCII
                && ((48...57).contains($0.value)
                    || (65...90).contains($0.value)
                    || (97...122).contains($0.value)
                    || $0 == "." || $0 == "-" || $0 == "_")
        }) else {
            throw BrushConversionReportValidationError.invalidToken(field)
        }
    }

    static func semanticKey(_ value: String, field: String) throws {
        try token(value, field: field, maximumUTF8Bytes: 512)
    }

    static func sortedUniqueSemanticKeys(
        _ values: [String],
        field: String
    ) throws {
        for value in values {
            try semanticKey(value, field: field)
        }
        guard values == values.sorted() else {
            throw BrushConversionReportValidationError.unsorted(field)
        }
        guard Set(values).count == values.count else {
            throw BrushConversionReportValidationError.duplicate(field)
        }
    }

    static func sortedUniqueNativeSemanticKeys(
        _ values: [String],
        field: String
    ) throws {
        for value in values {
            try boundedText(
                value,
                field: field,
                maximumUTF8Bytes: 512
            )
            guard value.unicodeScalars.allSatisfy({
                $0.isASCII
                    && ((48...57).contains($0.value)
                        || (65...90).contains($0.value)
                        || (97...122).contains($0.value)
                        || $0 == "." || $0 == "-" || $0 == "_"
                        || $0 == "[" || $0 == "]")
            }) else {
                throw BrushConversionReportValidationError
                    .invalidToken(field)
            }
        }
        guard values == values.sorted() else {
            throw BrushConversionReportValidationError.unsorted(field)
        }
        guard Set(values).count == values.count else {
            throw BrushConversionReportValidationError.duplicate(field)
        }
    }

    static func sha256(_ value: String, field: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              })
        else {
            throw BrushConversionReportValidationError.invalidHash(field)
        }
    }

    static func mediaType(_ value: String, field: String) throws {
        try boundedText(value, field: field, maximumUTF8Bytes: 128)
        guard value.contains("/"),
              !value.contains(" "),
              value.unicodeScalars.allSatisfy({ $0.isASCII })
        else {
            throw BrushConversionReportValidationError.invalidToken(field)
        }
    }

    static func nonnegativeFinite(
        _ value: Double?,
        field: String
    ) throws {
        guard let value else { return }
        guard value.isFinite else {
            throw BrushConversionReportValidationError.nonfinite(field)
        }
        guard value >= 0 else {
            throw BrushConversionReportValidationError.outOfRange(field)
        }
    }
}

private enum BrushNativeSemanticKeyRegistry {
    private static let versionOneExact: Set<String> = [
        "capabilities",
        "resources",
        "coverage.shapes",
        "coverage.grains",
        "coverage.baseHardness",
        "coverage.aspectRatio",
        "coverage.tipThreshold",
        "coverage.antialiasing",
        "placement.baseSpacingFraction",
        "placement.maximumSpacingFraction",
        "placement.baseFlow",
        "placement.strokeOpacity",
        "placement.baseScatterFraction",
        "placement.baseRotation",
        "placement.baseJitterFraction",
        "placement.baseOffset",
        "placement.baseOffset.x",
        "placement.baseOffset.y",
        "dynamics.size",
        "dynamics.flow",
        "dynamics.opacity",
        "dynamics.spacing",
        "dynamics.rotation",
        "dynamics.scatter",
        "dynamics.hardness",
        "dynamics.grain",
        "dynamics.offsetX",
        "dynamics.offsetY",
        "dynamics.hue",
        "dynamics.saturation",
        "dynamics.brightness",
        "dynamics.secondaryColorMix",
        "dynamics.noPressureNeutral",
        "dynamics.randomization",
        "dynamics.randomization.spacing",
        "dynamics.randomization.scatter",
        "dynamics.randomization.rotation",
        "dynamics.randomization.grain",
        "dynamics.randomization.material",
        "color.baseAdjustment",
        "color.baseAdjustment.redMultiplier",
        "color.baseAdjustment.greenMultiplier",
        "color.baseAdjustment.blueMultiplier",
        "color.baseAdjustment.alphaMultiplier",
        "color.perStampJitter",
        "color.perStampJitter.hue",
        "color.perStampJitter.saturation",
        "color.perStampJitter.brightness",
        "color.perStampJitter.secondaryColorMix",
        "color.perStrokeJitter",
        "color.perStrokeJitter.hue",
        "color.perStrokeJitter.saturation",
        "color.perStrokeJitter.brightness",
        "color.perStrokeJitter.secondaryColorMix",
        "material.accumulation",
        "material.interaction",
        "material.edgeTreatment",
        "material.strength",
        "material.wetness",
        "material.bleedRadius",
        "material.softenPasses",
        "material.accumulationLimit",
        "material.interactionParameters",
        "material.interactionParameters.pickup",
        "material.interactionParameters.pull",
        "material.interactionParameters.dilution",
        "material.interactionParameters.charge",
        "material.interactionParameters.persistence",
        "material.interactionParameters.dirtyHaloRadius",
        "stabilization",
        "taper.start",
        "taper.end",
        "taper.minimumSize",
        "taper.minimumFlow",
        "taper.effects",
        "replayMode",
        "replayLimits.maximumSamples",
        "replayLimits.maximumDabs",
        "replayLimits.maximumProjectedInstances",
        "seedPolicy",
        "limits.minimumDiameter",
        "limits.maximumDiameter",
        "limits.maximumOpacity",
        "limits.maximumSpacingFraction",
        "limits.maximumResourceDimension",
        "limits.maximumResidentBytes",
        "performanceIntent",
    ]

    private static let shapeSuffixes: Set<String> = [
        "",
        ".shape",
        ".combination",
        ".scale",
        ".rotation",
        ".offset",
        ".offset.x",
        ".offset.y",
    ]

    private static let grainSuffixes: Set<String> = [
        "",
        ".grain",
        ".coordinateMode",
        ".transform",
        ".transform.scale",
        ".transform.rotation",
        ".transform.offset",
        ".transform.offset.x",
        ".transform.offset.y",
        ".grainMovementFraction",
        ".grainFollowsBrushRotation",
        ".strength",
    ]

    static func supports(_ key: String, in definition: BrushDefinition) -> Bool {
        guard definition.compatibility.nativeFeatureVersion == 1 else {
            return false
        }
        if key.hasPrefix("material.interactionParameters"),
           definition.material.interactionParameters == nil
        {
            return false
        }
        if key.hasPrefix("replayLimits."),
           definition.replayLimits == nil
        {
            return false
        }
        if versionOneExact.contains(key) { return true }
        return matchesIndexed(
            key,
            prefix: "coverage.shapes[",
            elementCount: definition.coverage.shapes.count,
            suffixes: shapeSuffixes
        ) || matchesIndexed(
            key,
            prefix: "coverage.grains[",
            elementCount: definition.coverage.grains.count,
            suffixes: grainSuffixes
        )
    }

    private static func matchesIndexed(
        _ key: String,
        prefix: String,
        elementCount: Int,
        suffixes: Set<String>
    ) -> Bool {
        guard key.hasPrefix(prefix) else { return false }
        let remainder = key.dropFirst(prefix.count)
        guard let closingBracket = remainder.firstIndex(of: "]"),
              let index = Int(remainder[..<closingBracket]),
              index >= 0,
              index < elementCount
        else {
            return false
        }
        let suffix = String(remainder[remainder.index(after: closingBracket)...])
        return suffixes.contains(suffix)
    }
}
