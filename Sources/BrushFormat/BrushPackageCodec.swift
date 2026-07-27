import Foundation
import PatternEngine
import SafeArchive

public enum BrushPackageCodec {
    public static let archiveLimits = SafeArchiveLimits(
        maximumEntryCount: BrushFormatLimits.maximumArchiveEntries,
        maximumEntryBytes: UInt64(BrushFormatLimits.maximumEncodedResourceBytes),
        maximumExpandedBytes: UInt64(BrushFormatLimits.maximumExpandedPackageBytes),
        maximumPathBytes: BrushFormatLimits.maximumArchivePathBytes
    )

    public static func encode(_ package: BrushPackage) throws -> Data {
        let entries = try archiveEntries(for: package)
        do {
            return try SafeArchiveCodec.encode(entries: entries, limits: archiveLimits)
        } catch let error as SafeArchiveError {
            throw BrushPackageError.archive(error)
        }
    }

    public static func decode(_ data: Data) throws -> BrushPackage {
        let archive: SafeArchive
        do {
            archive = try SafeArchiveCodec.open(data, limits: archiveLimits)
        } catch let error as SafeArchiveError {
            throw BrushPackageError.archive(error)
        }

        guard archive.paths.contains("manifest.json") else {
            throw BrushPackageError.archive(.missingEntry("manifest.json"))
        }
        guard archive.paths.contains("definition.json") else {
            throw BrushPackageError.archive(.missingEntry("definition.json"))
        }

        let manifestData = try archiveData(archive, path: "manifest.json")
        let manifest: BrushPackageManifest = try decodeJSON(
            BrushPackageManifest.self,
            from: manifestData,
            label: "manifest"
        )
        let expectedPaths = Set(
            ["manifest.json", manifest.definitionPath] + manifest.resources.map(\.path)
        )
        let actualPaths = Set(archive.paths)
        guard expectedPaths == actualPaths else {
            if let extra = actualPaths.subtracting(expectedPaths).sorted().first {
                throw BrushPackageError.unexpectedEntry(extra)
            }
            let missing = expectedPaths.subtracting(actualPaths).sorted().first!
            throw BrushPackageError.archive(.missingEntry(missing))
        }

        let definitionData = try archiveData(archive, path: manifest.definitionPath)
        let definition: BrushDefinition
        do {
            definition = try decodeJSON(
                BrushDefinition.self,
                from: definitionData,
                label: "definition"
            )
        } catch BrushDefinitionValidationError.unsupportedSchema {
            throw BrushPackageError.unsupportedDefinitionSchema
        } catch is BrushDefinitionValidationError {
            throw BrushPackageError.invalidDefinition
        } catch {
            throw error
        }

        var resourceData: [String: Data] = [:]
        resourceData.reserveCapacity(manifest.resources.count)
        for resource in manifest.resources {
            resourceData[resource.id] = try archiveData(archive, path: resource.path)
        }
        return try BrushPackage(
            manifest: manifest,
            definition: definition,
            resourceData: resourceData
        )
    }

    package static func archiveEntries(for package: BrushPackage) throws -> [String: Data] {
        try BrushPackageValidator.validate(package)
        var entries: [String: Data] = [
            "manifest.json": try encodeJSON(package.manifest, label: "manifest"),
            package.manifest.definitionPath: try encodeJSON(
                package.definition,
                label: "definition"
            ),
        ]
        for resource in package.manifest.resources {
            guard entries[resource.path] == nil,
                  let data = package.resourceData[resource.id]
            else {
                throw BrushPackageError.invalidResource(
                    id: resource.id,
                    reason: "duplicate path or missing bytes"
                )
            }
            entries[resource.path] = data
        }
        return entries
    }

    private static func archiveData(_ archive: SafeArchive, path: String) throws -> Data {
        do {
            return try archive.data(for: path)
        } catch let error as SafeArchiveError {
            throw BrushPackageError.archive(error)
        }
    }

    private static func encodeJSON<T: Encodable>(_ value: T, label: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw BrushPackageError.malformedJSON(label)
        }
    }

    private static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        label: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as BrushPackageError {
            throw error
        } catch let error as BrushDefinitionValidationError {
            throw error
        } catch {
            throw BrushPackageError.malformedJSON(label)
        }
    }
}
