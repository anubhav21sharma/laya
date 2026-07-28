import Foundation

public enum SyntheticV1ParserError: Error, Equatable, Sendable {
    case sourceFormatMismatch
    case sourceVersionMismatch
    case parserIdentityMismatch
}

/// Parser for a project-owned, JSON diagnostic envelope.
///
/// It is not a production interchange format. The explicit signature prevents
/// a generic JSON document from being mistaken for this test format.
public struct SyntheticV1BrushParser: ForeignBrushParser {
    public static let sourceFormatFamily = "synthetic"
    public static let sourceFormatVersion = "1"
    public static let parserIdentifier = "laya.synthetic-v1"
    public static let parserVersion = "1"
    public static let rawGrayscaleMediaType =
        "application/x-laya-synthetic-r8"

    public let identifier = parserIdentifier

    private static let signature = Data(
        "LAYA-SYNTHETIC-BRUSH-V1\n".utf8
    )

    public init() {}

    public func probe(_ source: Data) throws -> Bool {
        source.starts(with: Self.signature)
    }

    public func parse(_ source: Data) throws -> [ForeignBrushDocument] {
        guard try probe(source) else { return [] }
        let payload = source.dropFirst(Self.signature.count)
        let envelope = try JSONDecoder().decode(
            Envelope.self,
            from: Data(payload)
        )
        let provenance = try ForeignBrushProvenance(
            sourceFormatFamily: Self.sourceFormatFamily,
            sourceFormatVersion: Self.sourceFormatVersion,
            sourceContentSHA256: ForeignBrushDocument.contentSHA256(source),
            parserIdentifier: Self.parserIdentifier,
            parserVersion: Self.parserVersion
        )
        let ir = try ForeignBrushIR(
            schemaVersion: envelope.schemaVersion,
            provenance: provenance,
            sourceBrushIdentifier: envelope.sourceBrushIdentifier,
            displayName: envelope.displayName,
            author: envelope.author,
            settings: envelope.settings,
            resources: envelope.resources,
            diagnostics: envelope.diagnostics
        )
        return [
            try ForeignBrushDocument(
                ir: ir,
                resourceData: envelope.resourceData
            ),
        ]
    }

    public func encode(_ document: ForeignBrushDocument) throws -> Data {
        try Self.validateProvenance(document.ir.provenance)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var encoded = Self.signature
        encoded.append(
            try encoder.encode(
                Envelope(
                    schemaVersion: document.ir.schemaVersion,
                    sourceBrushIdentifier:
                        document.ir.sourceBrushIdentifier,
                    displayName: document.ir.displayName,
                    author: document.ir.author,
                    settings: document.ir.settings,
                    resources: document.ir.resources,
                    diagnostics: document.ir.diagnostics,
                    resourceData: document.resourceData
                )
            )
        )
        return encoded
    }

    private static func validateProvenance(
        _ provenance: ForeignBrushProvenance
    ) throws {
        guard provenance.sourceFormatFamily == sourceFormatFamily else {
            throw SyntheticV1ParserError.sourceFormatMismatch
        }
        guard provenance.sourceFormatVersion == sourceFormatVersion else {
            throw SyntheticV1ParserError.sourceVersionMismatch
        }
        guard provenance.parserIdentifier == parserIdentifier,
              provenance.parserVersion == parserVersion
        else {
            throw SyntheticV1ParserError.parserIdentityMismatch
        }
    }

    private struct Envelope: Codable {
        let schemaVersion: UInt16
        let sourceBrushIdentifier: String
        let displayName: String
        let author: String?
        let settings: [ForeignBrushSetting]
        let resources: [ForeignBrushResourceDescriptor]
        let diagnostics: [ForeignBrushDiagnostic]
        let resourceData: [String: Data]
    }
}
