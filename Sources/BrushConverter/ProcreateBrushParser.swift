import Foundation

public enum ProcreateBrushParserError: Error, Equatable, Sendable {
    case ambiguousContainer
    case invalidBrushSet
    case invalidBrushMember(String)
    case invalidBrushArchive(String)
    case invalidEmbeddedPNG(String)
    case nonContiguousActiveComponents(String)
    case invalidActiveComponentPath(String)
    case tooManyActiveComponents(String)
}

/// Signature-and-structure router for the supported Procreate container
/// variants. Filename extensions are intentionally not part of this API.
public struct ProcreateBrushParser: ForeignBrushParser {
    public static let parserIdentifier = "laya.procreate-router"
    public static let parserVersion = "2"

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
    public static let parserVersion = "2"

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
    public static let parserVersion = "2"

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

    private struct ComponentSpec {
        let identifier: String
        let ordinal: UInt16
        let archivePath: String
        let resourcePrefix: String
    }

    private struct ParsedComponent {
        let component: ForeignBrushComponent
        let displayName: String?
        let author: String?
        let resourceData: [String: Data]
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
        let specs = try componentSpecs(archive: archive, prefix: prefix)
        let propertyListBudget = ForeignPropertyListBudget()
        var parsed = [ParsedComponent]()
        parsed.reserveCapacity(specs.count)
        for spec in specs {
            try parsed.append(parseComponent(
                archive: archive,
                spec: spec,
                propertyListBudget: propertyListBudget
            ))
        }
        guard let root = parsed.first else {
            throw ProcreateBrushParserError.invalidBrushArchive(
                "\(prefix)Brush.archive"
            )
        }
        var resourceData: [String: Data] = [:]
        for component in parsed {
            for (identifier, data) in component.resourceData {
                guard resourceData.updateValue(data, forKey: identifier) == nil
                else {
                    throw ProcreateBrushParserError.invalidBrushArchive(
                        component.component.sourcePath
                    )
                }
            }
        }
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
            displayName: root.displayName ?? "Untitled Procreate Brush",
            author: root.author,
            components: parsed.map(\.component)
        )
        return try ForeignBrushDocument(ir: ir, resourceData: resourceData)
    }

    private static func parseComponent(
        archive: ForeignZIPReader,
        spec: ComponentSpec,
        propertyListBudget: ForeignPropertyListBudget
    ) throws -> ParsedComponent {
        let graph: ForeignPropertyListGraph
        let view: BoundedKeyedArchiveView
        do {
            graph = try ForeignPropertyListReader.parse(
                archive.data(for: spec.archivePath),
                budget: propertyListBudget
            )
            view = try BoundedKeyedArchiveView(
                graph: graph,
                budget: propertyListBudget
            )
        } catch {
            throw ProcreateBrushParserError.invalidBrushArchive(
                spec.archivePath
            )
        }
        guard let root = try view.topObject(forKey: "root") else {
            throw ProcreateBrushParserError.invalidBrushArchive(
                spec.archivePath
            )
        }
        let fields: [String: ForeignPropertyListObjectID]
        do {
            fields = try view.dictionaryFields(at: root)
        } catch {
            throw ProcreateBrushParserError.invalidBrushArchive(
                spec.archivePath
            )
        }

        let displayName = try optionalString(
            key: "name",
            fields: fields,
            view: view
        )
        let author = try optionalString(
            key: "authorName",
            fields: fields,
            view: view
        )

        let decoded = try rawSettings(
            fields: fields,
            view: view,
            archivePath: spec.archivePath
        )
        var diagnostics = decoded.diagnostics
        if fields["name"] == nil {
            try diagnostics.append(ForeignBrushDiagnostic(
                severity: .warning,
                code: "procreate.missing-name",
                location: spec.archivePath,
                message: "The source brush has no supported display name."
            ))
        }
        let extracted = try resources(
            archive: archive,
            prefix: spec.resourcePrefix,
            componentIdentifier: spec.identifier
        )
        diagnostics.append(contentsOf: extracted.diagnostics)

        var settings = decoded.settings
        for resource in extracted.resources {
            guard let resourceSpec = resourceSpecs.first(where: {
                resource.id.hasSuffix(".\($0.id)")
            }), let semanticKey = resourceSpec.semanticKey else {
                continue
            }
            try settings.append(ForeignBrushSetting(
                semanticKey: semanticKey,
                unit: .unitless,
                domain: .resource,
                location: "\(spec.resourcePrefix)\(resourceSpec.relativePath)",
                value: .resourceReference(resource.id)
            ))
        }
        settings.sort { $0.semanticKey < $1.semanticKey }
        diagnostics.sort { $0.stableIdentity < $1.stableIdentity }

        let component = try ForeignBrushComponent(
            identifier: spec.identifier,
            ordinal: spec.ordinal,
            sourcePath: spec.archivePath,
            settings: settings,
            resources: extracted.resources,
            diagnostics: diagnostics
        )
        return ParsedComponent(
            component: component,
            displayName: displayName,
            author: author,
            resourceData: extracted.data
        )
    }

    private static func componentSpecs(
        archive: ForeignZIPReader,
        prefix: String
    ) throws -> [ComponentSpec] {
        let rootPath = "\(prefix)Brush.archive"
        guard archive.contains(rootPath) else {
            throw ProcreateBrushParserError.invalidBrushArchive(rootPath)
        }
        var active: [Int: String] = [:]
        for path in archive.paths where path.hasPrefix(prefix) {
            let relative = String(path.dropFirst(prefix.count))
            guard relative != "Brush.archive",
                  !relative.hasPrefix("Reset/")
            else { continue }
            let parts = relative.split(separator: "/").map(String.init)
            if parts.count >= 2,
               parts[0].hasPrefix("Sub"),
               parts[1] == "Reset"
            {
                continue
            }
            guard relative.lowercased().hasSuffix("brush.archive"),
                  relative.lowercased().hasPrefix("sub")
            else { continue }
            guard parts.count == 2,
                  parts[1] == "Brush.archive",
                  parts[0].hasPrefix("Sub"),
                  parts[0].count == 5,
                  let index = Int(parts[0].dropFirst(3)),
                  index > 0
            else {
                throw ProcreateBrushParserError.invalidActiveComponentPath(
                    path
                )
            }
            guard active.updateValue(path, forKey: index) == nil else {
                throw ProcreateBrushParserError.invalidActiveComponentPath(
                    path
                )
            }
        }
        let indices = active.keys.sorted()
        let expectedIndices = indices.isEmpty
            ? []
            : Array(1...indices.count)
        guard indices == expectedIndices else {
            throw ProcreateBrushParserError.nonContiguousActiveComponents(
                prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            )
        }
        guard indices.count + 1
                <= ForeignBrushLimits.maximumComponentsPerBrush
        else {
            throw ProcreateBrushParserError.tooManyActiveComponents(
                prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            )
        }
        var result = [ComponentSpec(
            identifier: "root",
            ordinal: 0,
            archivePath: rootPath,
            resourcePrefix: prefix
        )]
        for index in indices {
            let directory = String(format: "Sub%02d", index)
            result.append(ComponentSpec(
                identifier: directory.lowercased(),
                ordinal: UInt16(index),
                archivePath: "\(prefix)\(directory)/Brush.archive",
                resourcePrefix: "\(prefix)\(directory)/"
            ))
        }
        return result
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
        fields: [String: ForeignPropertyListObjectID],
        view: BoundedKeyedArchiveView,
        archivePath: String
    ) throws -> (
        settings: [ForeignBrushSetting],
        diagnostics: [ForeignBrushDiagnostic]
    ) {
        var settings = [ForeignBrushSetting]()
        var diagnostics = [ForeignBrushDiagnostic]()
        for sourceKey in fields.keys.sorted()
            where !metadataKeys.contains(sourceKey)
        {
            let verified = ProcreateBrushSemanticKeys.verified(sourceKey)
            let semanticKey = verified
                ?? ProcreateBrushSemanticKeys.raw(sourceKey)
            let location = "\(archivePath)/fields/\(semanticKey)"
            let decoded = try ProcreateArchiveValueDecoder.decode(
                fields[sourceKey]!,
                from: view
            )
            let value = decoded ?? .token("present")
            try settings.append(ForeignBrushSetting(
                semanticKey: semanticKey,
                unit: unit(for: semanticKey, value: value),
                domain: value.domain,
                location: location,
                value: value
            ))
            if verified == nil || decoded == nil {
                try diagnostics.append(ForeignBrushDiagnostic(
                    severity: .information,
                    code: decoded == nil
                        ? "procreate.uncharacterized-object"
                        : "procreate.unverified-setting",
                    location: location,
                    message: decoded == nil
                        ? "An uncharacterized source object is retained as presence-only."
                        : "A direct source scalar is retained without a verified native mapping."
                ))
            }
        }
        settings.sort { $0.semanticKey < $1.semanticKey }
        diagnostics.sort { $0.stableIdentity < $1.stableIdentity }
        return (settings, diagnostics)
    }

    private static func unit(
        for semanticKey: String,
        value: ForeignBrushSettingValue
    ) -> ForeignBrushSettingUnit {
        guard case .scalar = value else { return .unitless }
        return semanticKey.hasPrefix(ProcreateBrushSemanticKeys.rawPrefix)
            ? .unitless
            : .normalized
    }

    private static func resources(
        archive: ForeignZIPReader,
        prefix: String,
        componentIdentifier: String
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
                id: "\(componentIdentifier).\(spec.id)",
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
            payloads["\(componentIdentifier).\(spec.id)"] = data
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
