import Foundation

public struct PersistedPaintTileImportBinding: Equatable, Sendable {
    public let persistedID: UUID
    public let layerID: UUID
    public let coordinate: PaintTileCoordinate

    public init(
        persistedID: UUID,
        layerID: UUID,
        coordinate: PaintTileCoordinate
    ) {
        self.persistedID = persistedID
        self.layerID = layerID
        self.coordinate = coordinate
    }
}

public struct PersistedPaintTileBinding: Equatable, Sendable {
    public let persistedID: UUID
    public let identity: PaintTileIdentity

    public init(persistedID: UUID, identity: PaintTileIdentity) {
        self.persistedID = persistedID
        self.identity = identity
    }
}

public enum PersistedPaintTileIdentityMapError:
    Error,
    Equatable,
    Sendable
{
    case duplicatePersistedID(UUID)
    case duplicateRuntimeIdentity(PaintTileIdentity)
    case duplicateLogicalCoordinate(
        layerID: UUID,
        coordinate: PaintTileCoordinate
    )
    case importCoordinateMissing(
        layerID: UUID,
        coordinate: PaintTileCoordinate
    )
    case importOverridesPublishedID(
        layerID: UUID,
        coordinate: PaintTileCoordinate,
        expected: UUID,
        actual: UUID
    )
    case missingRuntimeIdentity(PaintTileIdentity)
    case unexpectedRuntimeIdentity(PaintTileIdentity)
    case regeneratedRuntimeIdentity(
        layerID: UUID,
        coordinate: PaintTileCoordinate,
        expected: PaintTileIdentity,
        actual: PaintTileIdentity
    )
}

private struct PersistedPaintTileLogicalCoordinate: Hashable, Sendable {
    let layerID: UUID
    let coordinate: PaintTileCoordinate

    init(_ identity: PaintTileIdentity) {
        layerID = identity.layerID
        coordinate = identity.coordinate
    }

    init(layerID: UUID, coordinate: PaintTileCoordinate) {
        self.layerID = layerID
        self.coordinate = coordinate
    }
}

/// Immutable checked bijection for one coherently published document epoch.
/// Runtime identities are process-local; only `persistedID` crosses the native
/// archive boundary.
public struct PersistedPaintTileIdentitySnapshot: Equatable, Sendable {
    public let bindings: [PersistedPaintTileBinding]

    fileprivate let persistedIDByIdentity: [PaintTileIdentity: UUID]
    fileprivate let identityByPersistedID: [UUID: PaintTileIdentity]
    fileprivate let bindingByLogicalCoordinate:
        [PersistedPaintTileLogicalCoordinate: PersistedPaintTileBinding]

    init(validating bindings: [PersistedPaintTileBinding]) throws {
        var persistedIDByIdentity: [PaintTileIdentity: UUID] = [:]
        var identityByPersistedID: [UUID: PaintTileIdentity] = [:]
        var bindingByLogicalCoordinate:
            [PersistedPaintTileLogicalCoordinate: PersistedPaintTileBinding]
            = [:]
        for binding in bindings {
            guard identityByPersistedID[binding.persistedID] == nil else {
                throw PersistedPaintTileIdentityMapError
                    .duplicatePersistedID(binding.persistedID)
            }
            guard persistedIDByIdentity[binding.identity] == nil else {
                throw PersistedPaintTileIdentityMapError
                    .duplicateRuntimeIdentity(binding.identity)
            }
            let logical = PersistedPaintTileLogicalCoordinate(binding.identity)
            guard bindingByLogicalCoordinate[logical] == nil else {
                throw PersistedPaintTileIdentityMapError
                    .duplicateLogicalCoordinate(
                        layerID: logical.layerID,
                        coordinate: logical.coordinate
                    )
            }
            identityByPersistedID[binding.persistedID] = binding.identity
            persistedIDByIdentity[binding.identity] = binding.persistedID
            bindingByLogicalCoordinate[logical] = binding
        }
        self.bindings = bindings.sorted {
            if $0.identity != $1.identity { return $0.identity < $1.identity }
            return $0.persistedID.uuidString < $1.persistedID.uuidString
        }
        self.persistedIDByIdentity = persistedIDByIdentity
        self.identityByPersistedID = identityByPersistedID
        self.bindingByLogicalCoordinate = bindingByLogicalCoordinate
    }

    private init() {
        bindings = []
        persistedIDByIdentity = [:]
        identityByPersistedID = [:]
        bindingByLogicalCoordinate = [:]
    }

    static let empty = Self()

    public func persistedID(for identity: PaintTileIdentity) -> UUID? {
        persistedIDByIdentity[identity]
    }

    public func identity(for persistedID: UUID) -> PaintTileIdentity? {
        identityByPersistedID[persistedID]
    }

    fileprivate func binding(
        layerID: UUID,
        coordinate: PaintTileCoordinate
    ) -> PersistedPaintTileBinding? {
        bindingByLogicalCoordinate[.init(
            layerID: layerID,
            coordinate: coordinate
        )]
    }
}

/// Pure transition builder used under `DocumentPaintSurfaceStore`'s registry
/// lock. It never mutates the installed epoch and therefore cannot publish a
/// partial UUID/runtime-identity association.
enum PersistedPaintTileIdentityMap {
    static func removing(
        _ identities: Set<PaintTileIdentity>,
        from snapshot: PersistedPaintTileIdentitySnapshot
    ) throws -> PersistedPaintTileIdentitySnapshot {
        guard !identities.isEmpty else { return snapshot }
        return try PersistedPaintTileIdentitySnapshot(validating:
            snapshot.bindings.filter { !identities.contains($0.identity) }
        )
    }

    static func validateExact(
        _ snapshot: PersistedPaintTileIdentitySnapshot,
        references: [PaintTileReference]
    ) throws {
        var referenceIdentities = Set<PaintTileIdentity>()
        for reference in references {
            guard reference.identity.layerID == reference.layerID,
                  reference.identity.coordinate == reference.coordinate
            else {
                throw PersistedPaintTileIdentityMapError
                    .unexpectedRuntimeIdentity(reference.identity)
            }
            guard referenceIdentities.insert(reference.identity).inserted else {
                throw PersistedPaintTileIdentityMapError
                    .duplicateRuntimeIdentity(reference.identity)
            }
            guard snapshot.persistedID(for: reference.identity) != nil else {
                throw PersistedPaintTileIdentityMapError
                    .missingRuntimeIdentity(reference.identity)
            }
        }
        for binding in snapshot.bindings
        where !referenceIdentities.contains(binding.identity) {
            throw PersistedPaintTileIdentityMapError
                .unexpectedRuntimeIdentity(binding.identity)
        }
    }

    static func transition(
        from current: PersistedPaintTileIdentitySnapshot,
        baseReferences: [PaintTileReference],
        candidateReferences: [PaintTileReference],
        candidateOwnedReferences: [PaintTileReference],
        imports: [PersistedPaintTileImportBinding],
        makePersistedID: () -> UUID = UUID.init
    ) throws -> PersistedPaintTileIdentitySnapshot {
        try validateExact(current, references: baseReferences)

        let authorizedReplacementIdentities = Set(
            candidateOwnedReferences.map(\.identity)
        )
        var importsByCoordinate:
            [PersistedPaintTileLogicalCoordinate: PersistedPaintTileImportBinding]
            = [:]
        var importedIDs = Set<UUID>()
        for binding in imports {
            guard importedIDs.insert(binding.persistedID).inserted else {
                throw PersistedPaintTileIdentityMapError
                    .duplicatePersistedID(binding.persistedID)
            }
            let logical = PersistedPaintTileLogicalCoordinate(
                layerID: binding.layerID,
                coordinate: binding.coordinate
            )
            guard importsByCoordinate[logical] == nil else {
                throw PersistedPaintTileIdentityMapError
                    .duplicateLogicalCoordinate(
                        layerID: binding.layerID,
                        coordinate: binding.coordinate
                    )
            }
            importsByCoordinate[logical] = binding
        }

        var candidateByLogical:
            [PersistedPaintTileLogicalCoordinate: PaintTileIdentity] = [:]
        for reference in candidateReferences {
            let logical = PersistedPaintTileLogicalCoordinate(reference.identity)
            guard candidateByLogical[logical] == nil else {
                throw PersistedPaintTileIdentityMapError
                    .duplicateLogicalCoordinate(
                        layerID: logical.layerID,
                        coordinate: logical.coordinate
                    )
            }
            candidateByLogical[logical] = reference.identity
        }
        for (logical, _) in importsByCoordinate
        where candidateByLogical[logical] == nil {
            throw PersistedPaintTileIdentityMapError.importCoordinateMissing(
                layerID: logical.layerID,
                coordinate: logical.coordinate
            )
        }

        var next: [PersistedPaintTileBinding] = []
        next.reserveCapacity(candidateReferences.count)
        var assignedIDs = Set<UUID>()
        for reference in candidateReferences.sorted() {
            let identity = reference.identity
            let logical = PersistedPaintTileLogicalCoordinate(identity)
            let previous = current.binding(
                layerID: identity.layerID,
                coordinate: identity.coordinate
            )
            let persistedID: UUID
            if let imported = importsByCoordinate[logical] {
                if let previous,
                   previous.persistedID != imported.persistedID {
                    throw PersistedPaintTileIdentityMapError
                        .importOverridesPublishedID(
                            layerID: logical.layerID,
                            coordinate: logical.coordinate,
                            expected: previous.persistedID,
                            actual: imported.persistedID
                        )
                }
                persistedID = imported.persistedID
            } else if let previous {
                if previous.identity != identity,
                   !authorizedReplacementIdentities.contains(identity) {
                    throw PersistedPaintTileIdentityMapError
                        .regeneratedRuntimeIdentity(
                            layerID: logical.layerID,
                            coordinate: logical.coordinate,
                            expected: previous.identity,
                            actual: identity
                        )
                }
                persistedID = previous.persistedID
            } else {
                persistedID = makePersistedID()
            }
            guard assignedIDs.insert(persistedID).inserted else {
                throw PersistedPaintTileIdentityMapError
                    .duplicatePersistedID(persistedID)
            }
            next.append(.init(
                persistedID: persistedID,
                identity: identity
            ))
        }

        let snapshot = try PersistedPaintTileIdentitySnapshot(validating: next)
        try validateExact(snapshot, references: candidateReferences)
        return snapshot
    }
}
