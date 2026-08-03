import Foundation
import PatternEngine

public struct BrushPackage: Equatable, Sendable {
    public let manifest: BrushPackageManifest
    public let definition: BrushDefinition
    public let resourceData: [String: Data]
    public let conversionReport: BrushConversionReport?
    package let conversionReportData: Data?

    public init(
        manifest: BrushPackageManifest,
        definition: BrushDefinition,
        resourceData: [String: Data],
        conversionReport: BrushConversionReport? = nil
    ) throws {
        try self.init(
            manifest: manifest,
            definition: definition,
            resourceData: resourceData,
            conversionReport: conversionReport,
            preservedConversionReportData: nil
        )
    }

    package init(
        manifest: BrushPackageManifest,
        definition: BrushDefinition,
        resourceData: [String: Data],
        conversionReport: BrushConversionReport?,
        preservedConversionReportData: Data?
    ) throws {
        let conversionReportData: Data?
        if let conversionReport {
            if let preservedConversionReportData {
                let decodedReport: BrushConversionReport
                do {
                    decodedReport = try BrushConversionReportCodec.decode(
                        preservedConversionReportData
                    )
                } catch let error as BrushConversionReportValidationError {
                    throw BrushFormatError.invalidConversionReport(
                        .validation(error)
                    )
                } catch {
                    throw BrushFormatError.malformedJSON("conversion report")
                }
                guard decodedReport == conversionReport else {
                    throw BrushFormatError.invalidConversionReport(
                        .decodedReportMismatch
                    )
                }
                conversionReportData = preservedConversionReportData
            } else {
                do {
                    conversionReportData = try BrushConversionReportCodec
                        .encode(conversionReport)
                } catch {
                    throw BrushFormatError.invalidConversionReport(
                        .encodingFailure
                    )
                }
            }
        } else {
            guard preservedConversionReportData == nil else {
                throw BrushFormatError.invalidConversionReport(
                    .missingDecodedReport
                )
            }
            conversionReportData = nil
        }
        self.manifest = manifest
        self.definition = definition
        self.resourceData = resourceData
        self.conversionReport = conversionReport
        self.conversionReportData = conversionReportData
        try BrushPackageValidator.validate(self)
    }

    public var contentHash: String {
        get throws { try BrushContentHash.digest(of: self) }
    }
}

enum BrushPackageValidator {
    static func validate(_ package: BrushPackage) throws {
        guard package.definition.schemaVersion == BrushDefinition.legacySchemaVersion
                || package.definition.schemaVersion
                    == BrushDefinition.currentSchemaVersion
        else {
            throw BrushFormatError.unsupportedDefinitionSchema
        }
        let manifestIDs = Set(package.manifest.resources.map(\.id))
        guard Set(package.resourceData.keys) == manifestIDs else {
            let missing = manifestIDs.subtracting(package.resourceData.keys).sorted().first
            throw BrushFormatError.missingResource(missing ?? "unexpected resource data")
        }

        var expandedBytes = 0
        for resource in package.manifest.resources {
            guard let data = package.resourceData[resource.id] else {
                throw BrushFormatError.missingResource(resource.id)
            }
            guard data.count == resource.encodedByteCount else {
                throw BrushFormatError.invalidResource(id: resource.id, reason: "byte-count mismatch")
            }
            guard BrushContentHash.sha256Hex(of: data) == resource.sha256 else {
                throw BrushFormatError.invalidResource(id: resource.id, reason: "hash mismatch")
            }
            let (next, overflow) = expandedBytes.addingReportingOverflow(data.count)
            guard !overflow, next <= BrushFormatLimits.maximumExpandedPackageBytes else {
                throw BrushFormatError.invalidManifest("expanded package size")
            }
            expandedBytes = next
        }
        let references = Dictionary(
            uniqueKeysWithValues: package.definition.resources.map { ($0.identifier, $0) }
        )
        for reference in package.definition.resources {
            if let resource = package.manifest.resources.first(where: { $0.id == reference.identifier }) {
                guard resource.kind == reference.kind else {
                    throw BrushFormatError.invalidResource(
                        id: reference.identifier,
                        reason: "definition kind mismatch"
                    )
                }
            } else {
                switch reference.kind {
                case .preview:
                    guard !reference.required else {
                        throw BrushFormatError.missingResource(reference.identifier)
                    }
                case .shape, .grain:
                    guard !reference.required,
                          validFallback(reference.fallback, for: reference.kind)
                    else {
                        throw BrushFormatError.missingResource(reference.identifier)
                    }
                }
            }
        }

        for resource in package.manifest.resources where resource.kind != .preview {
            guard let reference = references[resource.id],
                  reference.kind == resource.kind
            else {
                throw BrushFormatError.invalidResource(
                    id: resource.id,
                    reason: "unreferenced manifest resource"
                )
            }
        }

        let reportBytes: Data?
        switch (
            package.manifest.conversionReport,
            package.conversionReport,
            package.conversionReportData
        ) {
        case (nil, nil, nil):
            reportBytes = nil
        case let (descriptor?, report?, data?):
            let targetContentHash = try BrushContentHash
                .digestOfValidatedPackage(package)
            do {
                try report.validate(
                    against: package.definition,
                    resources: package.manifest.resources,
                    targetPackageContentHash: targetContentHash
                )
            } catch let error as BrushConversionReportValidationError {
                throw BrushFormatError.invalidConversionReport(
                    .validation(error)
                )
            }
            guard data.count == descriptor.encodedByteCount else {
                throw BrushFormatError.invalidConversionReport(
                    .byteCountMismatch
                )
            }
            guard BrushContentHash.sha256Hex(of: data) == descriptor.sha256
            else {
                throw BrushFormatError.invalidConversionReport(.hashMismatch)
            }
            reportBytes = data
        case (nil, _, _):
            throw BrushFormatError.invalidConversionReport(
                .missingManifestDescriptor
            )
        case (_, nil, _):
            throw BrushFormatError.invalidConversionReport(
                .missingDecodedReport
            )
        case (_, _, nil):
            throw BrushFormatError.invalidConversionReport(.encodingFailure)
        }

        if let reportBytes {
            let (next, overflow) = expandedBytes.addingReportingOverflow(
                reportBytes.count
            )
            guard !overflow,
                  next <= BrushFormatLimits.maximumExpandedPackageBytes
            else {
                throw BrushFormatError.invalidManifest(
                    "expanded package size"
                )
            }
        }
    }

    private static func validFallback(
        _ fallback: BrushResourceFallback?,
        for kind: BrushResourceKind
    ) -> Bool {
        guard case let .builtIn(identifier)? = fallback else { return false }
        switch kind {
        case .shape: return identifier.hasPrefix("builtin.shape.")
        case .grain: return identifier.hasPrefix("builtin.grain.")
        case .preview: return false
        }
    }
}
