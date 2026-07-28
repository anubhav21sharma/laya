import Foundation

struct ForeignAssetDeclaration: Equatable, Hashable, Sendable {
    let id: String
    let path: String

    init(id: String, path: String) {
        self.id = id
        self.path = path
    }
}

enum ForeignAssetTableError: Error, Equatable, Sendable {
    case resourceCountExceeded(actual: Int, maximum: Int)
    case emptyAssetID
    case duplicateAssetID(String)
    case duplicateAssetPath(String)
    case missingAsset(path: String)
    case danglingReference(assetID: String)
    case missingAssetID(String)
}

struct ForeignAssetTable: Sendable {
    let assetIDs: [String]

    private let dataByID: [String: Data]

    init(
        archive: ForeignZIPReader,
        declarations: [ForeignAssetDeclaration],
        referencedAssetIDs: Set<String>
    ) throws {
        guard declarations.count <= ForeignBrushLimits.maximumResourcesPerBrush
        else {
            throw ForeignAssetTableError.resourceCountExceeded(
                actual: declarations.count,
                maximum: ForeignBrushLimits.maximumResourcesPerBrush
            )
        }
        var ids = Set<String>()
        var paths = Set<String>()
        var canonicalDeclarations: [(id: String, path: String)] = []
        canonicalDeclarations.reserveCapacity(declarations.count)
        for declaration in declarations {
            guard !declaration.id.isEmpty else {
                throw ForeignAssetTableError.emptyAssetID
            }
            guard ids.insert(declaration.id).inserted else {
                throw ForeignAssetTableError.duplicateAssetID(declaration.id)
            }
            let canonicalPath: String
            do {
                canonicalPath = try archive.canonicalPath(
                    for: declaration.path
                )
            } catch {
                throw ForeignAssetTableError.missingAsset(
                    path: declaration.path
                )
            }
            guard paths.insert(canonicalPath).inserted else {
                throw ForeignAssetTableError.duplicateAssetPath(
                    canonicalPath
                )
            }
            guard archive.contains(canonicalPath) else {
                throw ForeignAssetTableError.missingAsset(
                    path: declaration.path
                )
            }
            canonicalDeclarations.append(
                (id: declaration.id, path: canonicalPath)
            )
        }
        if let dangling = referencedAssetIDs
            .subtracting(ids)
            .sorted()
            .first {
            throw ForeignAssetTableError.danglingReference(
                assetID: dangling
            )
        }

        var dataByID: [String: Data] = [:]
        dataByID.reserveCapacity(canonicalDeclarations.count)
        for declaration in canonicalDeclarations {
            dataByID[declaration.id] = try archive.data(
                for: declaration.path
            )
        }
        self.dataByID = dataByID
        assetIDs = ids.sorted()
    }

    func data(forAssetID id: String) throws -> Data {
        guard let data = dataByID[id] else {
            throw ForeignAssetTableError.missingAssetID(id)
        }
        return data
    }
}
