import Foundation
import PatternEngine

public struct BrushPackage: Equatable, Sendable {
    public let manifest: BrushPackageManifest
    public let definition: BrushDefinition
    public let resourceData: [String: Data]

    public init(
        manifest: BrushPackageManifest,
        definition: BrushDefinition,
        resourceData: [String: Data]
    ) throws {
        self.manifest = manifest
        self.definition = definition
        self.resourceData = resourceData
        try BrushPackageValidator.validate(self)
    }

    public var contentHash: String {
        get throws { try BrushContentHash.digest(of: self) }
    }
}

enum BrushPackageValidator {
    static func validate(_ package: BrushPackage) throws {
        guard package.definition.schemaVersion == BrushDefinition.currentSchemaVersion else {
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
