import Foundation

public enum ProcreateBrushParserError: Error, Equatable, Sendable {
    case ambiguousContainer
    case invalidBrushSet
    case invalidBrushMember(String)
    case invalidBrushArchive(String)
    case invalidEmbeddedPNG(String)
}

/// Signature-and-structure router for the supported Procreate container
/// variants. Filename extensions are intentionally not part of this API.
public struct ProcreateBrushParser: ForeignBrushParser {
    public static let parserIdentifier = "laya.procreate-router"
    public static let parserVersion = "1"

    public let identifier = parserIdentifier

    public init() {}

    public func probe(_ source: Data) throws -> Bool {
        guard ProcreateContainerProbe.hasZIPSignature(source) else {
            return false
        }
        let archive = try ForeignZIPReader(source)
        return archive.contains("Brush.archive")
            || archive.contains("brushset.plist")
    }

    public func parse(_ source: Data) throws -> [ForeignBrushDocument] {
        guard ProcreateContainerProbe.hasZIPSignature(source) else {
            return []
        }
        let archive = try ForeignZIPReader(source)
        let individual = archive.contains("Brush.archive")
        let brushSet = archive.contains("brushset.plist")
        guard individual != brushSet else {
            if individual {
                throw ProcreateBrushParserError.ambiguousContainer
            }
            return []
        }
        if individual {
            return try ProcreateExportedBrushParser().parse(source)
        }
        return try ProcreateLegacyBrushSetParser().parse(source)
    }
}

public struct ProcreateExportedBrushParser: ForeignBrushParser {
    public static let sourceFormatFamily = "procreate"
    public static let sourceFormatVersion = "individual-export"
    public static let parserIdentifier = "laya.procreate-individual-export"
    public static let parserVersion = "1"

    public let identifier = parserIdentifier

    public init() {}

    public func probe(_ source: Data) throws -> Bool {
        guard ProcreateContainerProbe.hasZIPSignature(source) else {
            return false
        }
        let archive = try ForeignZIPReader(source)
        return archive.contains("Brush.archive")
            && !archive.contains("brushset.plist")
    }

    public func parse(_ source: Data) throws -> [ForeignBrushDocument] {
        guard try probe(source) else { return [] }
        let archive = try ForeignZIPReader(source)
        let sourceHash = ForeignBrushDocument.contentSHA256(source)
        let identifier = "brush-\(sourceHash.prefix(16))"
        return try [
            ProcreateArchiveAdapter.parseBrush(
                archive: archive,
                prefix: "",
                sourceHash: sourceHash,
                sourceBrushIdentifier: identifier,
                sourceFormatVersion: Self.sourceFormatVersion,
                parserIdentifier: Self.parserIdentifier,
                parserVersion: Self.parserVersion
            ),
        ]
    }
}

public struct ProcreateLegacyBrushSetParser: ForeignBrushParser {
    public static let sourceFormatFamily = "procreate"
    public static let sourceFormatVersion = "legacy-brushset"
    public static let parserIdentifier = "laya.procreate-legacy-brushset"
    public static let parserVersion = "1"

    public let identifier = parserIdentifier

    public init() {}

    public func probe(_ source: Data) throws -> Bool {
        guard ProcreateContainerProbe.hasZIPSignature(source) else {
            return false
        }
        let archive = try ForeignZIPReader(source)
        return archive.contains("brushset.plist")
            && !archive.contains("Brush.archive")
    }

    public func parse(_ source: Data) throws -> [ForeignBrushDocument] {
        guard try probe(source) else { return [] }
        let archive = try ForeignZIPReader(source)
        let memberPaths = try ProcreateBrushSetManifest.memberPaths(
            from: archive.data(for: "brushset.plist")
        )
        let sourceHash = ForeignBrushDocument.contentSHA256(source)
        return try memberPaths.sorted().map { member in
            let brushArchivePath = "\(member)/Brush.archive"
            guard archive.contains(brushArchivePath) else {
                throw ProcreateBrushParserError.invalidBrushMember(member)
            }
            return try ProcreateArchiveAdapter.parseBrush(
                archive: archive,
                prefix: "\(member)/",
                sourceHash: sourceHash,
                sourceBrushIdentifier: member,
                sourceFormatVersion: Self.sourceFormatVersion,
                parserIdentifier: Self.parserIdentifier,
                parserVersion: Self.parserVersion
            )
        }
    }
}

private enum ProcreateContainerProbe {
    static func hasZIPSignature(_ source: Data) -> Bool {
        source.count >= 4
            && source.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
    }
}

private enum ProcreateBrushSetManifest {
    static func memberPaths(from data: Data) throws -> [String] {
        let graph: ForeignPropertyListGraph
        do {
            graph = try ForeignPropertyListReader.parse(data)
        } catch {
            throw ProcreateBrushParserError.invalidBrushSet
        }
        guard case let .dictionary(entries) = try graph.node(at: graph.root),
              let brushesID = try graph.dictionaryFields(
                  entries,
                  dictionary: graph.root.rawValue
              )["brushes"],
              case let .array(memberIDs) = try graph.node(at: brushesID),
              !memberIDs.isEmpty
        else {
            throw ProcreateBrushParserError.invalidBrushSet
        }
        var members = Set<String>()
        for identifier in memberIDs {
            guard case let .string(member) = try graph.node(at: identifier),
                  !member.isEmpty,
                  member.utf8.count <=
                  ForeignBrushLimits.maximumLocationUTF8Bytes
            else {
                throw ProcreateBrushParserError.invalidBrushSet
            }
            let canonical: String
            do {
                canonical = try normalizeForeignZIPPath(
                    member,
                    maximumUTF8Bytes:
                    ForeignBrushLimits.maximumLocationUTF8Bytes,
                    permitsDirectory: false
                )
            } catch {
                throw ProcreateBrushParserError.invalidBrushSet
            }
            guard members.insert(canonical).inserted else {
                throw ProcreateBrushParserError.invalidBrushSet
            }
        }
        return members.sorted()
    }
}

private enum ProcreateArchiveAdapter {
    private static let metadataKeys = Set([
        "$class",
        "authorName",
        "creationDate",
        "name",
        "version",
    ])

    private struct ResourceSpec {
        let id: String
        let relativePath: String
        let role: ForeignBrushResourceRole
        let semanticKey: String?
    }

    private static let resourceSpecs = [
        ResourceSpec(
            id: "grain.procreate",
            relativePath: "Grain.png",
            role: .grain,
            semanticKey: ProcreateBrushSemanticKeys.grain
        ),
        ResourceSpec(
            id: "preview.procreate",
            relativePath: "QuickLook/Thumbnail.png",
            role: .preview,
            semanticKey: nil
        ),
        ResourceSpec(
            id: "shape.procreate",
            relativePath: "Shape.png",
            role: .shape,
            semanticKey: ProcreateBrushSemanticKeys.shape
        ),
    ]

    static func parseBrush(
        archive: ForeignZIPReader,
        prefix: String,
        sourceHash: String,
        sourceBrushIdentifier: String,
        sourceFormatVersion: String,
        parserIdentifier: String,
        parserVersion: String
    ) throws -> ForeignBrushDocument {
        let archivePath = "\(prefix)Brush.archive"
        let graph: ForeignPropertyListGraph
        let view: BoundedKeyedArchiveView
        do {
            graph = try ForeignPropertyListReader.parse(
                archive.data(for: archivePath)
            )
            view = try BoundedKeyedArchiveView(graph: graph)
        } catch {
            throw ProcreateBrushParserError.invalidBrushArchive(archivePath)
        }
        guard let root = try view.topObject(forKey: "root") else {
            throw ProcreateBrushParserError.invalidBrushArchive(archivePath)
        }
        let fields: [String: ForeignPropertyListObjectID]
        do {
            fields = try view.dictionaryFields(at: root)
        } catch {
            throw ProcreateBrushParserError.invalidBrushArchive(archivePath)
        }

        let displayName = try optionalString(
            key: "name",
            fields: fields,
            view: view
        ) ?? "Untitled Procreate Brush"
        let author = try optionalString(
            key: "authorName",
            fields: fields,
            view: view
        )

        var diagnostics = try structuralDiagnostics(
            archive: archive,
            prefix: prefix,
            fields: fields,
            hasName: fields["name"] != nil
        )
        let extracted = try resources(
            archive: archive,
            prefix: prefix
        )
        diagnostics.append(contentsOf: extracted.diagnostics)

        var settings = try rawSettings(fields: fields)
        for resource in extracted.resources {
            guard let spec = resourceSpecs.first(where: {
                $0.id == resource.id
            }), let semanticKey = spec.semanticKey else {
                continue
            }
            try settings.append(ForeignBrushSetting(
                semanticKey: semanticKey,
                unit: .unitless,
                domain: .resource,
                location: "\(prefix)\(spec.relativePath)",
                value: .resourceReference(resource.id)
            ))
        }
        settings.sort { $0.semanticKey < $1.semanticKey }
        diagnostics.sort { $0.stableIdentity < $1.stableIdentity }

        let provenance = try ForeignBrushProvenance(
            sourceFormatFamily: ProcreateExportedBrushParser.sourceFormatFamily,
            sourceFormatVersion: sourceFormatVersion,
            sourceContentSHA256: sourceHash,
            parserIdentifier: parserIdentifier,
            parserVersion: parserVersion
        )
        let ir = try ForeignBrushIR(
            provenance: provenance,
            sourceBrushIdentifier: sourceBrushIdentifier,
            displayName: displayName,
            author: author,
            settings: settings,
            resources: extracted.resources,
            diagnostics: diagnostics
        )
        return try ForeignBrushDocument(
            ir: ir,
            resourceData: extracted.data
        )
    }

    private static func optionalString(
        key: String,
        fields: [String: ForeignPropertyListObjectID],
        view: BoundedKeyedArchiveView
    ) throws -> String? {
        guard let identifier = fields[key] else { return nil }
        guard case let .string(value) = try view.resolvedNode(at: identifier),
              !value.isEmpty
        else {
            throw ProcreateBrushParserError.invalidBrushArchive(
                "Brush.archive/\(key)"
            )
        }
        return value
    }

    private static func rawSettings(
        fields: [String: ForeignPropertyListObjectID]
    ) throws -> [ForeignBrushSetting] {
        try fields.keys
            .filter { !metadataKeys.contains($0) }
            .map { sourceKey in
                let semanticKey = ProcreateBrushSemanticKeys.raw(sourceKey)
                return try ForeignBrushSetting(
                    semanticKey: semanticKey,
                    unit: .unitless,
                    domain: .token,
                    location: "Brush.archive/fields/\(semanticKey)",
                    value: .token("present")
                )
            }
            .sorted { $0.semanticKey < $1.semanticKey }
    }

    private static func structuralDiagnostics(
        archive: ForeignZIPReader,
        prefix: String,
        fields: [String: ForeignPropertyListObjectID],
        hasName: Bool
    ) throws -> [ForeignBrushDiagnostic] {
        var result = [ForeignBrushDiagnostic]()
        if !hasName {
            try result.append(ForeignBrushDiagnostic(
                severity: .warning,
                code: "procreate.missing-name",
                location: "\(prefix)Brush.archive",
                message: "The source brush has no supported display name."
            ))
        }
        for sourceKey in fields.keys.sorted()
            where !metadataKeys.contains(sourceKey)
        {
            let semanticKey = ProcreateBrushSemanticKeys.raw(sourceKey)
            try result.append(ForeignBrushDiagnostic(
                severity: .information,
                code: "procreate.unverified-setting",
                location: "Brush.archive/fields/\(semanticKey)",
                message:
                "A source field is retained as present but has no verified semantic mapping."
            ))
        }
        if archive.paths.contains(where: {
            $0.hasPrefix("\(prefix)Sub")
                && $0.hasSuffix("/Brush.archive")
        }) {
            try result.append(ForeignBrushDiagnostic(
                severity: .warning,
                code: "procreate.unsupported-sub-brush",
                location: "\(prefix)Brush.archive",
                message:
                "The source contains a sub-brush that is not supported by this adapter."
            ))
        }
        return result
    }

    private static func resources(
        archive: ForeignZIPReader,
        prefix: String
    ) throws -> (
        resources: [ForeignBrushResourceDescriptor],
        data: [String: Data],
        diagnostics: [ForeignBrushDiagnostic]
    ) {
        let available = resourceSpecs.filter {
            archive.contains("\(prefix)\($0.relativePath)")
        }
        let declarations = available.map {
            ForeignAssetDeclaration(
                id: $0.id,
                path: "\(prefix)\($0.relativePath)"
            )
        }
        let table = try ForeignAssetTable(
            archive: archive,
            declarations: declarations,
            referencedAssetIDs: Set(available.map(\.id))
        )
        var descriptors = [ForeignBrushResourceDescriptor]()
        var payloads = [String: Data]()
        for spec in available {
            let data = try table.data(forAssetID: spec.id)
            let metadata: ProcreatePNGMetadata
            do {
                metadata = try ProcreatePNGInspector.inspect(data)
            } catch {
                throw ProcreateBrushParserError.invalidEmbeddedPNG(
                    "\(prefix)\(spec.relativePath)"
                )
            }
            try descriptors.append(ForeignBrushResourceDescriptor(
                id: spec.id,
                role: spec.role,
                containerLocation: "\(prefix)\(spec.relativePath)",
                mediaType: "image/png",
                contentSHA256:
                ForeignBrushDocument.contentSHA256(data),
                encodedByteCount: data.count,
                pixelWidth: metadata.width,
                pixelHeight: metadata.height,
                channelModel: metadata.channelModel,
                colorInterpretation: .unspecified,
                inverted: false,
                orientation: .up
            ))
            payloads[spec.id] = data
        }
        descriptors.sort { $0.id < $1.id }

        var diagnostics = [ForeignBrushDiagnostic]()
        for spec in resourceSpecs
            where spec.role != .preview
            && !available.contains(where: { $0.id == spec.id })
        {
            try diagnostics.append(ForeignBrushDiagnostic(
                severity: .warning,
                code: "procreate.unavailable-source-resource",
                location: "\(prefix)\(spec.relativePath)",
                message:
                "A supported embedded source image is absent; a Source Library asset may be required."
            ))
        }
        return (descriptors, payloads, diagnostics)
    }
}

private extension ForeignPropertyListGraph {
    func dictionaryFields(
        _ entries: [ForeignPropertyListDictionaryEntry],
        dictionary: Int
    ) throws -> [String: ForeignPropertyListObjectID] {
        var result = [String: ForeignPropertyListObjectID]()
        for entry in entries {
            guard case let .string(key) = try node(at: entry.key) else {
                throw ForeignPropertyListError.dictionaryKeyIsNotString(
                    object: dictionary
                )
            }
            guard result.updateValue(entry.value, forKey: key) == nil else {
                throw ForeignPropertyListError.duplicateDictionaryKey(
                    object: dictionary
                )
            }
        }
        return result
    }
}
