import Foundation

public enum ProcreateResourceSubstitutionError:
    Error, Equatable, Sendable
{
    case unsupportedSchema(Int)
    case duplicateSourceName(String)
    case duplicateResourceID(String)
    case unknownSourceName(String)
    case invalidReason(String)
    case invalidPath(String)
    case missingFile(String)
    case byteCountMismatch(String)
    case hashMismatch(String)
    case imageMetadataMismatch(String)
    case roleMismatch(
        sourceName: String,
        expected: ForeignBrushResourceRole,
        actual: ForeignBrushResourceRole
    )
}

public struct ProcreateResourceSubstitution: Equatable, Sendable {
    public let sourceName: String
    public let resourceID: String
    public let role: ForeignBrushResourceRole
    public let path: String
    public let mediaType: String
    public let contentSHA256: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let reason: String
    public let data: Data
}

public struct ProcreateResourceSubstitutionRegistry: Sendable {
    public static let requiredReason =
        "project-owned-source-library-substitute"

    private let substitutions: [String: ProcreateResourceSubstitution]

    public var sourceNames: [String] { substitutions.keys.sorted() }

    public init(manifestData: Data, baseURL: URL) throws {
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: manifestData
        )
        guard manifest.schemaVersion == 1 else {
            throw ProcreateResourceSubstitutionError.unsupportedSchema(
                manifest.schemaVersion
            )
        }
        let canonicalBase = baseURL.standardizedFileURL
        let basePath = canonicalBase.path.hasSuffix("/")
            ? canonicalBase.path
            : canonicalBase.path + "/"
        var result: [String: ProcreateResourceSubstitution] = [:]
        var resourceIDs = Set<String>()
        for entry in manifest.substitutions {
            guard result[entry.sourceName] == nil else {
                throw ProcreateResourceSubstitutionError.duplicateSourceName(
                    entry.sourceName
                )
            }
            guard resourceIDs.insert(entry.resourceID).inserted else {
                throw ProcreateResourceSubstitutionError.duplicateResourceID(
                    entry.resourceID
                )
            }
            try ForeignBrushValidator.string(
                entry.sourceName,
                field: "substitution.sourceName"
            )
            try ForeignBrushValidator.string(
                entry.resourceID,
                field: "substitution.resourceID"
            )
            try ForeignBrushValidator.location(
                entry.path,
                field: "substitution.path"
            )
            try ForeignBrushValidator.mediaType(entry.mediaType)
            try ForeignBrushValidator.sha256(
                entry.sha256,
                field: "substitution.sha256"
            )
            guard entry.reason == Self.requiredReason else {
                throw ProcreateResourceSubstitutionError.invalidReason(
                    entry.sourceName
                )
            }
            let url = canonicalBase.appendingPathComponent(entry.path)
                .standardizedFileURL
            guard url.path.hasPrefix(basePath) else {
                throw ProcreateResourceSubstitutionError.invalidPath(
                    entry.path
                )
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else {
                throw ProcreateResourceSubstitutionError.missingFile(
                    entry.sourceName
                )
            }
            guard data.count == entry.byteCount else {
                throw ProcreateResourceSubstitutionError.byteCountMismatch(
                    entry.sourceName
                )
            }
            guard ForeignBrushDocument.contentSHA256(data) == entry.sha256 else {
                throw ProcreateResourceSubstitutionError.hashMismatch(
                    entry.sourceName
                )
            }
            guard entry.mediaType == "image/png",
                  let metadata = try? ProcreatePNGInspector.inspect(data),
                  metadata.width == entry.pixelWidth,
                  metadata.height == entry.pixelHeight
            else {
                throw ProcreateResourceSubstitutionError.imageMetadataMismatch(
                    entry.sourceName
                )
            }
            result[entry.sourceName] = ProcreateResourceSubstitution(
                sourceName: entry.sourceName,
                resourceID: entry.resourceID,
                role: entry.role,
                path: entry.path,
                mediaType: entry.mediaType,
                contentSHA256: entry.sha256,
                pixelWidth: entry.pixelWidth,
                pixelHeight: entry.pixelHeight,
                reason: entry.reason,
                data: data
            )
        }
        substitutions = result
    }

    public static func load(
        manifestURL: URL,
        baseURL: URL
    ) throws -> Self {
        try Self(
            manifestData: Data(contentsOf: manifestURL),
            baseURL: baseURL
        )
    }

    public func resolve(
        sourceName: String,
        expectedRole: ForeignBrushResourceRole
    ) throws -> ProcreateResourceSubstitution {
        guard let substitution = substitutions[sourceName] else {
            throw ProcreateResourceSubstitutionError.unknownSourceName(
                sourceName
            )
        }
        guard substitution.role == expectedRole else {
            throw ProcreateResourceSubstitutionError.roleMismatch(
                sourceName: sourceName,
                expected: expectedRole,
                actual: substitution.role
            )
        }
        return substitution
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let substitutions: [Entry]
    }

    private struct Entry: Decodable {
        let sourceName: String
        let resourceID: String
        let role: ForeignBrushResourceRole
        let path: String
        let mediaType: String
        let sha256: String
        let byteCount: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let reason: String
    }
}
