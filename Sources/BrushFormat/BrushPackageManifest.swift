import Foundation
import PatternEngine
import SafeArchive

public enum BrushFormatLimits {
    public static let maximumArchiveEntries = 64
    public static let maximumEncodedResourceBytes = 64 * 1_024 * 1_024
    public static let maximumExpandedPackageBytes = 192 * 1_024 * 1_024
    public static let maximumArchivePathBytes = 512
    public static let maximumResources = 16
    public static let maximumImageDimension = 8_192
    public static let maximumConversionReportBytes = 2 * 1_024 * 1_024
}

public enum BrushPackageError: Error, Equatable, Sendable {
    case archive(SafeArchiveError)
    case invalidManifest(String)
    case invalidDefinition
    case unsupportedManifestSchema(UInt16)
    case unsupportedDefinitionSchema(UInt16)
    case invalidResource(id: String, reason: String)
    case missingResource(String)
    case unexpectedEntry(String)
    case malformedJSON(String)
    case invalidConversionReport(BrushPackageConversionReportError)
    case contentIdentityMismatch
    case ioFailure
}

public typealias BrushFormatError = BrushPackageError

public enum BrushPackageConversionReportError:
    Error, Equatable, Sendable
{
    case missingManifestDescriptor
    case missingDecodedReport
    case byteCountMismatch
    case hashMismatch
    case encodingFailure
    case decodedReportMismatch
    case duplicatePath
    case validation(BrushConversionReportValidationError)
}

public struct BrushPackageProvenance: Codable, Equatable, Sendable {
    public let buildTool: String?
    public let sourceApplication: String?
    public let sourceVersion: String?

    public init(
        buildTool: String? = nil,
        sourceApplication: String? = nil,
        sourceVersion: String? = nil
    ) {
        self.buildTool = buildTool
        self.sourceApplication = sourceApplication
        self.sourceVersion = sourceVersion
    }
}

public struct BrushPackageConversionReportDescriptor:
    Codable, Equatable, Sendable
{
    public static let canonicalPath = "conversion-report.json"

    public let path: String
    public let sha256: String
    public let encodedByteCount: Int

    public init(
        path: String = canonicalPath,
        sha256: String,
        encodedByteCount: Int
    ) throws {
        guard path == Self.canonicalPath else {
            throw BrushFormatError.invalidManifest("conversion report path")
        }
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              })
        else {
            throw BrushFormatError.invalidManifest("conversion report hash")
        }
        guard encodedByteCount > 0,
              encodedByteCount <= BrushFormatLimits.maximumConversionReportBytes
        else {
            throw BrushFormatError.invalidManifest(
                "conversion report byte count"
            )
        }
        self.path = path
        self.sha256 = sha256
        self.encodedByteCount = encodedByteCount
    }

    public init(report: BrushConversionReport) throws {
        let data = try BrushConversionReportCodec.encode(report)
        try self.init(
            sha256: BrushContentHash.sha256Hex(of: data),
            encodedByteCount: data.count
        )
    }

    private enum CodingKeys: String, CodingKey {
        case path, sha256, encodedByteCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: container.decode(String.self, forKey: .path),
            sha256: container.decode(String.self, forKey: .sha256),
            encodedByteCount: container.decode(
                Int.self,
                forKey: .encodedByteCount
            )
        )
    }
}

public struct BrushPackageResource: Codable, Equatable, Sendable {
    public let id: String
    public let kind: BrushResourceKind
    public let path: String
    public let mediaType: String
    public let sha256: String
    public let encodedByteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        id: String,
        kind: BrushResourceKind,
        path: String,
        mediaType: String,
        sha256: String,
        encodedByteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        try Self.validate(
            id: id,
            path: path,
            mediaType: mediaType,
            sha256: sha256,
            encodedByteCount: encodedByteCount,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        self.id = id
        self.kind = kind
        self.path = path
        self.mediaType = mediaType
        self.sha256 = sha256
        self.encodedByteCount = encodedByteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public init(
        id: String,
        kind: BrushResourceKind,
        mediaType: String,
        data: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        let sha256 = BrushContentHash.sha256Hex(of: data)
        try self.init(
            id: id,
            kind: kind,
            path: Self.canonicalPath(sha256: sha256, mediaType: mediaType),
            mediaType: mediaType,
            sha256: sha256,
            encodedByteCount: data.count,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    public static func canonicalPath(sha256: String, mediaType: String) -> String {
        let suffix: String
        switch mediaType {
        case "image/png": suffix = "png"
        case "image/tiff": suffix = "tiff"
        default: suffix = ""
        }
        return "resources/\(sha256).\(suffix)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, path, mediaType, sha256, encodedByteCount, pixelWidth, pixelHeight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            kind: container.decode(BrushResourceKind.self, forKey: .kind),
            path: container.decode(String.self, forKey: .path),
            mediaType: container.decode(String.self, forKey: .mediaType),
            sha256: container.decode(String.self, forKey: .sha256),
            encodedByteCount: container.decode(Int.self, forKey: .encodedByteCount),
            pixelWidth: container.decode(Int.self, forKey: .pixelWidth),
            pixelHeight: container.decode(Int.self, forKey: .pixelHeight)
        )
    }

    private static func validate(
        id: String,
        path: String,
        mediaType: String,
        sha256: String,
        encodedByteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        guard !id.isEmpty else {
            throw BrushFormatError.invalidResource(id: id, reason: "empty id")
        }
        guard mediaType == "image/png" || mediaType == "image/tiff" else {
            throw BrushFormatError.invalidResource(id: id, reason: "unsupported media type")
        }
        guard sha256.count == 64,
              sha256.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
        else {
            throw BrushFormatError.invalidResource(id: id, reason: "invalid SHA-256")
        }
        guard path == canonicalPath(sha256: sha256, mediaType: mediaType),
              !path.utf8.isEmpty,
              path.utf8.count <= BrushFormatLimits.maximumArchivePathBytes
        else {
            throw BrushFormatError.invalidResource(id: id, reason: "noncanonical path")
        }
        guard encodedByteCount > 0,
              encodedByteCount <= BrushFormatLimits.maximumEncodedResourceBytes
        else {
            throw BrushFormatError.invalidResource(id: id, reason: "encoded byte count")
        }
        guard (1...BrushFormatLimits.maximumImageDimension).contains(pixelWidth),
              (1...BrushFormatLimits.maximumImageDimension).contains(pixelHeight)
        else {
            throw BrushFormatError.invalidResource(id: id, reason: "image dimensions")
        }
    }
}

public struct BrushPackageManifest: Codable, Equatable, Sendable {
    public static let currentVersion: UInt16 = 2

    public let schemaVersion: UInt16
    public let definitionPath: String
    public let resources: [BrushPackageResource]
    public let provenance: BrushPackageProvenance?
    public let conversionReport: BrushPackageConversionReportDescriptor?

    public init(
        definitionPath: String = "definition.json",
        resources: [BrushPackageResource],
        provenance: BrushPackageProvenance? = nil,
        conversionReport: BrushPackageConversionReportDescriptor? = nil
    ) throws {
        guard definitionPath == "definition.json" else {
            throw BrushFormatError.invalidManifest("definitionPath")
        }
        guard resources.count <= BrushFormatLimits.maximumResources else {
            throw BrushFormatError.invalidManifest("resource count")
        }
        let sorted = resources.sorted { $0.id < $1.id }
        guard Set(sorted.map(\.id)).count == sorted.count else {
            throw BrushFormatError.invalidManifest("duplicate resource id")
        }
        guard Set(sorted.map(\.path)).count == sorted.count else {
            throw BrushFormatError.invalidManifest("duplicate resource path")
        }
        guard sorted.filter({ $0.kind == .preview }).count <= 1 else {
            throw BrushFormatError.invalidManifest("multiple previews")
        }
        self.schemaVersion = Self.currentVersion
        self.definitionPath = definitionPath
        self.resources = sorted
        self.provenance = provenance
        self.conversionReport = conversionReport
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case definitionPath
        case resources
        case provenance
        case conversionReport
    }

    public init(from decoder: Decoder) throws {
        let envelope = try BrushPackageManifestVersionEnvelope(from: decoder)
        guard envelope.schemaVersion == Self.currentVersion else {
            throw BrushFormatError.unsupportedManifestSchema(
                envelope.schemaVersion
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            definitionPath: container.decode(String.self, forKey: .definitionPath),
            resources: container.decode([BrushPackageResource].self, forKey: .resources),
            provenance: container.decodeIfPresent(
                BrushPackageProvenance.self,
                forKey: .provenance
            ),
            conversionReport: container.decodeIfPresent(
                BrushPackageConversionReportDescriptor.self,
                forKey: .conversionReport
            )
        )
    }
}

private struct BrushPackageManifestVersionEnvelope: Decodable {
    let schemaVersion: UInt16
}
