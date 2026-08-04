import Foundation
import Metal
import PatternEngine

public enum DocumentPaintSurfaceRole: UInt8, Hashable, Sendable {
    case canonical
    case authoritative
    case prediction
    case provisional
    case historyInstall
}

public enum DocumentPaintSurfaceStoreError: Error, Equatable, Sendable {
    case geometryByteCountOverflow
    case radialStorageSizeMismatch(expected: PixelSize, actual: PixelSize)
    case duplicateLayerID(UUID)
    case unknownLayerID(UUID)
    case staleGeneration(expected: UInt64, actual: UInt64)
    case generationOverflow
    case duplicateCoordinate(PaintTileCoordinate)
    case unsortedCoordinate(
        previous: PaintTileCoordinate,
        current: PaintTileCoordinate
    )
    case unownedCandidateCoordinate(PaintTileCoordinate)
    case overlappingDirtyAndRemovedCoordinate(PaintTileCoordinate)
    case foreignCandidate
    case staleCandidate(expectedGeneration: UInt64, actualGeneration: UInt64)
    case candidateAlreadyConsumed
    case ambiguousPreparedCandidate
    case preparedCandidateRequiresExplicitCancellation
    case namespaceIdentityOverflow
    case transferByteCapacityOverflow
}

public struct DocumentPaintGeometry: Equatable, Sendable {
    public let documentPixelSize: PixelSize
    public let storagePixelSize: PixelSize
    public let radialLayout: RadialSectorLayout?
    public let storageResidentByteCount: Int

    public init(
        documentPixelSize: PixelSize,
        storagePixelSize: PixelSize,
        radialLayout: RadialSectorLayout?
    ) throws {
        func bytes(_ size: PixelSize) throws -> Int {
            let (pixels, pixelOverflow) = size.width
                .multipliedReportingOverflow(by: size.height)
            let (result, byteOverflow) = pixels
                .multipliedReportingOverflow(by: 8)
            guard !pixelOverflow, !byteOverflow else {
                throw DocumentPaintSurfaceStoreError.geometryByteCountOverflow
            }
            return result
        }
        _ = try bytes(documentPixelSize)
        let storageBytes: Int
        if let radialLayout {
            guard storagePixelSize == radialLayout.atlasPixelSize else {
                throw DocumentPaintSurfaceStoreError.radialStorageSizeMismatch(
                    expected: radialLayout.atlasPixelSize,
                    actual: storagePixelSize
                )
            }
            do {
                storageBytes = try radialLayout.residentByteCount(
                    bytesPerPixel: 8
                )
            } catch {
                throw DocumentPaintSurfaceStoreError.geometryByteCountOverflow
            }
        } else {
            storageBytes = try bytes(storagePixelSize)
        }
        self.documentPixelSize = documentPixelSize
        self.storagePixelSize = storagePixelSize
        self.radialLayout = radialLayout
        storageResidentByteCount = storageBytes
    }
}

public struct DocumentPaintSurfaceNamespace: Hashable, Sendable {
    public let storeIdentity: PaintTileStoreIdentity
    public let surfaceID: UUID
    public let layerID: UUID
    public let generation: UInt64
    public let role: DocumentPaintSurfaceRole
    let token: UInt64
}

public struct DocumentPaintLayerBinding: Sendable {
    public let layerID: UUID
    public let generation: UInt64
    public let canonical: TiledRasterSurface
}

public struct DocumentPaintSurfaceStoreSnapshot: Equatable, Sendable {
    public struct Layer: Equatable, Sendable {
        public let layerID: UUID
        public let references: [PaintTileReference]
    }

    public let generation: UInt64
    public let geometry: DocumentPaintGeometry
    public let layers: [Layer]
    public let tileByteBudget: Int
    public let residentTileBytes: Int
    public let backingTileBytes: Int
    public let activeTileLeaseCount: Int
    public let issuedNamespaceCount: Int
    public let preparedCandidateCount: Int
}

private struct DocumentPaintLayerState: Sendable {
    let logicalSurfaceID: UUID
    let revision: RasterRevision
    let references: [PaintTileReference]
}

public final class DocumentPaintSurfaceCandidate: @unchecked Sendable {
    fileprivate enum State: Equatable { case open, prepared, consumed }

    fileprivate let registryIdentity: UUID
    fileprivate let store: PaintTileStore
    fileprivate let geometry: DocumentPaintGeometry
    fileprivate let orderedLayerIDs: [UUID]
    fileprivate let lock = NSLock()
    fileprivate var state: State = .open
    fileprivate var preparedCommit: DocumentPaintPreparedCommit?
    fileprivate var layerStatesStorage: [UUID: DocumentPaintLayerState]
    fileprivate var ownedReferencesStorage: [PaintTileReference]

    public let baseGeneration: UInt64
    public let generation: UInt64
    public let ownedNamespaces: [DocumentPaintSurfaceNamespace]

    public var ownedReferences: [PaintTileReference] {
        withLock { ownedReferencesStorage }
    }

    fileprivate init(
        registryIdentity: UUID,
        store: PaintTileStore,
        geometry: DocumentPaintGeometry,
        orderedLayerIDs: [UUID],
        baseGeneration: UInt64,
        generation: UInt64,
        layerStates: [UUID: DocumentPaintLayerState],
        ownedReferences: [PaintTileReference],
        ownedNamespaces: [DocumentPaintSurfaceNamespace]
    ) {
        self.registryIdentity = registryIdentity
        self.store = store
        self.geometry = geometry
        self.orderedLayerIDs = orderedLayerIDs
        self.baseGeneration = baseGeneration
        self.generation = generation
        layerStatesStorage = layerStates
        ownedReferencesStorage = ownedReferences
        self.ownedNamespaces = ownedNamespaces
    }

    public func binding(for layerID: UUID) throws -> DocumentPaintLayerBinding {
        let layerState = try withLock {
            guard state != .consumed else {
                throw DocumentPaintSurfaceStoreError.candidateAlreadyConsumed
            }
            guard let layerState = layerStatesStorage[layerID] else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            return layerState
        }
        let view = try TiledRasterCoordinateReferenceView(
            storeIdentity: store.identity,
            surfaceID: layerState.logicalSurfaceID,
            layerID: layerID,
            pixelSize: geometry.storagePixelSize,
            generation: generation,
            revision: layerState.revision,
            references: layerState.references
        )
        return DocumentPaintLayerBinding(
            layerID: layerID,
            generation: generation,
            canonical: try TiledRasterSurface(store: store, referenceView: view)
        )
    }

    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public final class DocumentPaintPreparedCommit: @unchecked Sendable {
    fileprivate let candidate: DocumentPaintSurfaceCandidate
    fileprivate let replacedRetirement: PaintTilePreparedRetirement
    fileprivate let candidateRetirement: PaintTilePreparedRetirement

    fileprivate init(
        candidate: DocumentPaintSurfaceCandidate,
        replacedRetirement: PaintTilePreparedRetirement,
        candidateRetirement: PaintTilePreparedRetirement
    ) {
        self.candidate = candidate
        self.replacedRetirement = replacedRetirement
        self.candidateRetirement = candidateRetirement
    }
}

/// One document-wide sparse surface registry. It is the sole owner of the
/// physical PaintTileStore used by canonical, transient, and future layered
/// surfaces; this prerequisite remains production-inert until Task 6's atomic
/// activation commit.
public final class DocumentPaintSurfaceStore: @unchecked Sendable {
    private final class NamespaceRecord {
        let layerID: UUID
        let generation: UInt64
        let authoritativeSurfaceID: UUID
        let predictionSurfaceID: UUID
        weak var ownership: StrokeTileSurfaceNamespaceOwnership?

        init(
            layerID: UUID,
            generation: UInt64,
            authoritativeSurfaceID: UUID,
            predictionSurfaceID: UUID,
            ownership: StrokeTileSurfaceNamespaceOwnership
        ) {
            self.layerID = layerID
            self.generation = generation
            self.authoritativeSurfaceID = authoritativeSurfaceID
            self.predictionSurfaceID = predictionSurfaceID
            self.ownership = ownership
        }

        func matches(_ lease: StrokeTileSurfaceNamespaceLease) -> Bool {
            ownership === lease.ownership
                && ownership?.isOutstanding == true
                && layerID == lease.layerID
                && generation == lease.generation
                && authoritativeSurfaceID == lease.authoritative.surfaceID
                && predictionSurfaceID == lease.prediction.surfaceID
        }
    }

    private let identity = UUID()
    private let lock = NSLock()
    private var currentGeneration: UInt64
    private var currentGeometry: DocumentPaintGeometry
    private let orderedLayerIDs: [UUID]
    private var activeLayers: [UUID: DocumentPaintLayerState]
    private var preparedCandidateIdentity: ObjectIdentifier?
    private var nextNamespaceToken: UInt64 = 0
    private var namespaceRecords: [UInt64: NamespaceRecord] = [:]

    let sharedTileStore: PaintTileStore

    public convenience init(
        device: any MTLDevice,
        byteBudget: Int,
        geometry: DocumentPaintGeometry,
        layerIDs: [UUID],
        generation: UInt64 = 0
    ) throws {
        let (transferByteCapacity, overflow) = byteBudget
            .multipliedReportingOverflow(by: 3)
        guard !overflow else {
            throw DocumentPaintSurfaceStoreError.transferByteCapacityOverflow
        }
        try self.init(
            device: device,
            byteBudget: byteBudget,
            transferByteCapacity: transferByteCapacity,
            geometry: geometry,
            layerIDs: layerIDs,
            generation: generation
        )
    }

    public init(
        device: any MTLDevice,
        byteBudget: Int,
        transferByteCapacity: Int,
        geometry: DocumentPaintGeometry,
        layerIDs: [UUID],
        generation: UInt64 = 0
    ) throws {
        var seen: Set<UUID> = []
        var states: [UUID: DocumentPaintLayerState] = [:]
        var initialNamespaceToken: UInt64 = 0
        for layerID in layerIDs {
            guard seen.insert(layerID).inserted else {
                throw DocumentPaintSurfaceStoreError.duplicateLayerID(layerID)
            }
            let (token, overflow) = initialNamespaceToken
                .addingReportingOverflow(1)
            guard !overflow else {
                throw DocumentPaintSurfaceStoreError.namespaceIdentityOverflow
            }
            initialNamespaceToken = token
            states[layerID] = DocumentPaintLayerState(
                logicalSurfaceID: Self.surfaceID(
                    role: .canonical,
                    token: token
                ),
                revision: RasterRevision(rawValue: 0),
                references: []
            )
        }
        sharedTileStore = PaintTileStore(
            device: device,
            byteBudget: byteBudget,
            transferByteCapacity: transferByteCapacity
        )
        currentGeometry = geometry
        currentGeneration = generation
        orderedLayerIDs = layerIDs
        activeLayers = states
        nextNamespaceToken = initialNamespaceToken
    }

    public var tileStoreIdentity: PaintTileStoreIdentity {
        sharedTileStore.identity
    }

    public var generation: UInt64 { withLock { currentGeneration } }
    public var geometry: DocumentPaintGeometry { withLock { currentGeometry } }
    public var layerIDs: [UUID] { orderedLayerIDs }

    public func binding(for layerID: UUID) throws -> DocumentPaintLayerBinding {
        try withLock {
            guard let state = activeLayers[layerID] else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            let view = try TiledRasterCoordinateReferenceView(
                storeIdentity: sharedTileStore.identity,
                surfaceID: state.logicalSurfaceID,
                layerID: layerID,
                pixelSize: currentGeometry.storagePixelSize,
                generation: currentGeneration,
                revision: state.revision,
                references: state.references
            )
            return DocumentPaintLayerBinding(
                layerID: layerID,
                generation: currentGeneration,
                canonical: try TiledRasterSurface(
                    store: sharedTileStore,
                    referenceView: view
                )
            )
        }
    }

    public func makeCandidate(
        geometry: DocumentPaintGeometry? = nil,
        dirtyCoordinatesByLayer: [UUID: [PaintTileCoordinate]] = [:],
        removingCoordinatesByLayer: [UUID: [PaintTileCoordinate]] = [:],
        failureInjection: PaintTileAllocationFailureInjection? = nil
    ) throws -> DocumentPaintSurfaceCandidate {
        let base: (
            generation: UInt64,
            geometry: DocumentPaintGeometry,
            layers: [UUID: DocumentPaintLayerState]
        ) = try withLock {
            for layerID in dirtyCoordinatesByLayer.keys
            where activeLayers[layerID] == nil {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            for layerID in removingCoordinatesByLayer.keys
            where activeLayers[layerID] == nil {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            guard currentGeneration < UInt64.max else {
                throw DocumentPaintSurfaceStoreError.generationOverflow
            }
            return (currentGeneration, currentGeometry, activeLayers)
        }
        let candidateGeneration = base.generation + 1
        let candidateGeometry = geometry ?? base.geometry
        let geometryChanged = candidateGeometry != base.geometry
        var candidateLayers = base.layers
        var owned: [PaintTileReference] = []
        var ownedNamespaces: [DocumentPaintSurfaceNamespace] = []

        do {
            for layerID in orderedLayerIDs {
                let dirty = try Self.sortedUnique(
                    dirtyCoordinatesByLayer[layerID] ?? []
                )
                let removed = try Self.sortedUnique(
                    removingCoordinatesByLayer[layerID] ?? []
                )
                let removedSet = Set(removed)
                if let overlap = dirty.first(where: removedSet.contains) {
                    throw DocumentPaintSurfaceStoreError
                        .overlappingDirtyAndRemovedCoordinate(overlap)
                }
                guard let old = candidateLayers[layerID] else {
                    throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
                }
                var mapping: [PaintTileCoordinate: PaintTileReference]
                if geometryChanged {
                    mapping = [:]
                } else {
                    mapping = Dictionary(
                        uniqueKeysWithValues: old.references.map {
                            ($0.coordinate, $0)
                        }
                    )
                }
                for coordinate in removed { mapping.removeValue(forKey: coordinate) }
                if !dirty.isEmpty {
                    let namespace = try issueSurfaceNamespace(
                        layerID: layerID,
                        generation: candidateGeneration,
                        role: .provisional,
                        expectedActiveGeneration: base.generation
                    )
                    ownedNamespaces.append(namespace)
                    let physicalSurfaceID = namespace.surfaceID
                    let lease = try sharedTileStore.reserveSortedUnique(
                        surfaceID: physicalSurfaceID,
                        layerID: layerID,
                        generation: candidateGeneration,
                        pixelSize: candidateGeometry.storagePixelSize,
                        coordinates: dirty,
                        pinReasons: [.dirty],
                        failureInjection: failureInjection
                    )
                    try sharedTileStore.markModified(
                        lease,
                        surfaceID: physicalSurfaceID,
                        currentGeneration: candidateGeneration
                    )
                    try sharedTileStore.release(
                        lease,
                        surfaceID: physicalSurfaceID,
                        currentGeneration: candidateGeneration
                    )
                    let newReferences = try sharedTileStore.references(
                        surfaceID: physicalSurfaceID,
                        layerID: layerID,
                        generation: candidateGeneration
                    )
                    owned.append(contentsOf: newReferences)
                    for reference in newReferences {
                        mapping[reference.coordinate] = reference
                    }
                }
                let (revisionValue, overflow) = old.revision.rawValue
                    .addingReportingOverflow(
                        geometryChanged || !dirty.isEmpty || !removed.isEmpty
                            ? 1 : 0
                    )
                guard !overflow else {
                    throw TiledRasterSurfaceError.revisionOverflow
                }
                candidateLayers[layerID] = DocumentPaintLayerState(
                    logicalSurfaceID: old.logicalSurfaceID,
                    revision: RasterRevision(rawValue: revisionValue),
                    references: mapping.values.sorted {
                        $0.coordinate < $1.coordinate
                    }
                )
            }
        } catch let constructionError {
            do {
                try retireCandidateOwnedReferences(owned.sorted())
            } catch let cleanupError {
                throw cleanupError
            }
            throw constructionError
        }
        return DocumentPaintSurfaceCandidate(
            registryIdentity: identity,
            store: sharedTileStore,
            geometry: candidateGeometry,
            orderedLayerIDs: orderedLayerIDs,
            baseGeneration: base.generation,
            generation: candidateGeneration,
            layerStates: candidateLayers,
            ownedReferences: owned.sorted(),
            ownedNamespaces: ownedNamespaces
        )
    }

    public func prepareCommit(
        _ candidate: DocumentPaintSurfaceCandidate
    ) throws -> DocumentPaintPreparedCommit {
        try withLock {
            guard candidate.registryIdentity == identity,
                  candidate.store === sharedTileStore
            else { throw DocumentPaintSurfaceStoreError.foreignCandidate }
            let candidateSnapshot = try candidate.withLock { () throws -> (
                layers: [UUID: DocumentPaintLayerState],
                ownedReferences: [PaintTileReference]
            ) in
                guard candidate.state == .open else {
                    throw DocumentPaintSurfaceStoreError.candidateAlreadyConsumed
                }
                return (
                    candidate.layerStatesStorage,
                    candidate.ownedReferencesStorage
                )
            }
            guard candidate.baseGeneration == currentGeneration else {
                throw DocumentPaintSurfaceStoreError.staleCandidate(
                    expectedGeneration: currentGeneration,
                    actualGeneration: candidate.baseGeneration
                )
            }
            guard preparedCandidateIdentity == nil else {
                throw DocumentPaintSurfaceStoreError.ambiguousPreparedCandidate
            }
            let retained = Set(candidateSnapshot.layers.values.flatMap(\.references))
            let replaced = activeLayers.values
                .flatMap(\.references)
                .filter { !retained.contains($0) }
                .sorted()
            let replacedRetirement = try sharedTileStore.prepareRetirement(
                replaced
            )
            let candidateRetirement: PaintTilePreparedRetirement
            do {
                candidateRetirement = try sharedTileStore.prepareRetirement(
                    candidateSnapshot.ownedReferences
                )
            } catch {
                sharedTileStore.cancelRetirement(replacedRetirement)
                throw error
            }
            let prepared = DocumentPaintPreparedCommit(
                candidate: candidate,
                replacedRetirement: replacedRetirement,
                candidateRetirement: candidateRetirement
            )
            candidate.withLock {
                precondition(candidate.state == .open)
                candidate.state = .prepared
                candidate.preparedCommit = prepared
            }
            preparedCandidateIdentity = ObjectIdentifier(candidate)
            return prepared
        }
    }

    /// All validation and retirement preparation happened in prepareCommit;
    /// this is the one nonthrowing logical registry swap.
    public func commitPrepared(_ prepared: DocumentPaintPreparedCommit) {
        withLock {
            let candidate = prepared.candidate
            let isPrepared = candidate.withLock {
                candidate.state == .prepared
                    && candidate.preparedCommit === prepared
            }
            guard isPrepared,
                  preparedCandidateIdentity == ObjectIdentifier(candidate)
            else { return }
            commitPreparedLocked(prepared)
        }
    }

    /// Coordinator-only irreversible terminal. Every fallible preflight must
    /// finish before this call; unlike the compatibility terminal, misuse is a
    /// programmer error and cannot silently leave a published revision pair
    /// without its matching registry generation.
    func commitPreparedForCoordinator(_ prepared: DocumentPaintPreparedCommit) {
        withLock {
            let candidate = prepared.candidate
            precondition(candidate.registryIdentity == identity)
            precondition(candidate.store === sharedTileStore)
            precondition(
                preparedCandidateIdentity == ObjectIdentifier(candidate)
            )
            candidate.withLock {
                precondition(candidate.state == .prepared)
                precondition(candidate.preparedCommit === prepared)
            }
            commitPreparedLocked(prepared)
        }
    }

    /// Explicitly consumes a prepared candidate without publishing it. The
    /// old active references are unblocked and only candidate-owned entries
    /// are retired. Repeated commit/cancel calls are harmless no-ops.
    public func cancelPrepared(_ prepared: DocumentPaintPreparedCommit) {
        withLock {
            let candidate = prepared.candidate
            let isPrepared = candidate.withLock {
                candidate.state == .prepared
                    && candidate.preparedCommit === prepared
            }
            guard isPrepared,
                  preparedCandidateIdentity == ObjectIdentifier(candidate)
            else { return }
            candidate.withLock {
                candidate.state = .consumed
                candidate.preparedCommit = nil
            }
            preparedCandidateIdentity = nil
            sharedTileStore.cancelRetirement(prepared.replacedRetirement)
            sharedTileStore.requestRetirement(prepared.candidateRetirement)
        }
    }

    public func discard(_ candidate: DocumentPaintSurfaceCandidate) throws {
        try withLock {
            guard candidate.registryIdentity == identity,
                  candidate.store === sharedTileStore
            else { throw DocumentPaintSurfaceStoreError.foreignCandidate }
            let candidateSnapshot = candidate.withLock {
                (candidate.state, candidate.ownedReferencesStorage)
            }
            let candidateState = candidateSnapshot.0
            guard candidateState != .consumed else {
                throw DocumentPaintSurfaceStoreError.candidateAlreadyConsumed
            }
            guard candidateState == .open else {
                throw DocumentPaintSurfaceStoreError
                    .preparedCandidateRequiresExplicitCancellation
            }
            let retirement = try sharedTileStore.prepareRetirement(
                candidateSnapshot.1
            )
            candidate.withLock { candidate.state = .consumed }
            sharedTileStore.requestRetirement(retirement)
        }
    }

    /// Removes exact, fully transparent candidate-owned dirty tiles before the
    /// candidate can be prepared for publication. Coordinates are authority:
    /// callers must provide a sorted, duplicate-free set and may never prune a
    /// shared reference inherited from the active generation.
    public func pruneFullyTransparentCoordinates(
        _ coordinates: [PaintTileCoordinate],
        from candidate: DocumentPaintSurfaceCandidate,
        layerID: UUID
    ) throws {
        try withLock {
            guard candidate.registryIdentity == identity,
                  candidate.store === sharedTileStore
            else { throw DocumentPaintSurfaceStoreError.foreignCandidate }
            guard activeLayers[layerID] != nil else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            guard candidate.baseGeneration == currentGeneration else {
                throw DocumentPaintSurfaceStoreError.staleCandidate(
                    expectedGeneration: currentGeneration,
                    actualGeneration: candidate.baseGeneration
                )
            }
            try Self.validateSortedUnique(coordinates)
            let references = try candidate.withLock { () throws
                -> [PaintTileReference] in
                guard candidate.state == .open else {
                    throw DocumentPaintSurfaceStoreError.candidateAlreadyConsumed
                }
                guard let layer = candidate.layerStatesStorage[layerID] else {
                    throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
                }
                return try coordinates.map { coordinate in
                    guard let reference = candidate.ownedReferencesStorage
                        .first(where: {
                            $0.layerID == layerID
                                && $0.coordinate == coordinate
                        }),
                          layer.references.first(where: {
                              $0.coordinate == coordinate
                          }) == reference
                    else {
                        throw DocumentPaintSurfaceStoreError
                            .unownedCandidateCoordinate(coordinate)
                    }
                    return reference
                }
            }
            guard !references.isEmpty else { return }

            let retirement = try sharedTileStore.prepareRetirement(references)
            candidate.withLock {
                precondition(candidate.state == .open)
                let removed = Set(references)
                let layer = candidate.layerStatesStorage[layerID]!
                candidate.layerStatesStorage[layerID] = DocumentPaintLayerState(
                    logicalSurfaceID: layer.logicalSurfaceID,
                    revision: layer.revision,
                    references: layer.references.filter { !removed.contains($0) }
                )
                candidate.ownedReferencesStorage.removeAll {
                    removed.contains($0)
                }
            }
            sharedTileStore.requestRetirement(retirement)
        }
    }

    public func snapshot() -> DocumentPaintSurfaceStoreSnapshot {
        withLock {
            sweepAbandonedNamespacesLocked()
            let tileSnapshot = sharedTileStore.snapshot()
            return DocumentPaintSurfaceStoreSnapshot(
                generation: currentGeneration,
                geometry: currentGeometry,
                layers: orderedLayerIDs.compactMap { layerID in
                    activeLayers[layerID].map {
                        .init(layerID: layerID, references: $0.references)
                    }
                },
                tileByteBudget: sharedTileStore.byteBudget,
                residentTileBytes: tileSnapshot.residentByteCount,
                backingTileBytes: tileSnapshot.backingByteCount,
                activeTileLeaseCount: tileSnapshot.activeLeaseCount,
                issuedNamespaceCount: namespaceRecords.count,
                preparedCandidateCount: preparedCandidateIdentity == nil ? 0 : 1
            )
        }
    }

    func issueStrokeNamespace(
        layerID: UUID,
        generation: UInt64
    ) throws -> StrokeTileSurfaceNamespaceLease {
        try withLock {
            guard activeLayers[layerID] != nil else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            guard generation == currentGeneration else {
                throw DocumentPaintSurfaceStoreError.staleGeneration(
                    expected: currentGeneration,
                    actual: generation
                )
            }
            let (token, overflow) = nextNamespaceToken
                .addingReportingOverflow(1)
            guard !overflow else {
                throw DocumentPaintSurfaceStoreError.namespaceIdentityOverflow
            }
            let authoritative = DocumentPaintSurfaceNamespace(
                storeIdentity: sharedTileStore.identity,
                surfaceID: Self.surfaceID(
                    role: .authoritative,
                    token: token
                ),
                layerID: layerID,
                generation: generation,
                role: .authoritative,
                token: token
            )
            let prediction = DocumentPaintSurfaceNamespace(
                storeIdentity: sharedTileStore.identity,
                surfaceID: Self.surfaceID(
                    role: .prediction,
                    token: token
                ),
                layerID: layerID,
                generation: generation,
                role: .prediction,
                token: token
            )
            let lease = StrokeTileSurfaceNamespaceLease.registryIssued(
                authoritative: authoritative,
                prediction: prediction,
                retirementToken: token,
                authenticate: { [weak self] lease in
                    self?.authenticate(lease) == true
                },
                onRetired: { [weak self] value in
                    self?.retireNamespace(token: value)
                }
            )
            namespaceRecords[token] = NamespaceRecord(
                layerID: layerID,
                generation: generation,
                authoritativeSurfaceID: authoritative.surfaceID,
                predictionSurfaceID: prediction.surfaceID,
                ownership: lease.ownership
            )
            nextNamespaceToken = token
            return lease
        }
    }

    private func authenticate(_ lease: StrokeTileSurfaceNamespaceLease) -> Bool {
        withLock {
            guard lease.storeIdentity == sharedTileStore.identity,
                  let record = namespaceRecords[lease.retirementToken]
            else { return false }
            return record.matches(lease)
        }
    }

    /// Defensive registry sweep for namespace owners abandoned before a
    /// resource object could claim them. Normal cancellation/deinit removes
    /// records immediately; this makes the evidence count self-healing too.
    func sweepAbandonedNamespaces() {
        withLock { sweepAbandonedNamespacesLocked() }
    }

    private func sweepAbandonedNamespacesLocked() {
        namespaceRecords = namespaceRecords.filter {
            $0.value.ownership?.isOutstanding == true
        }
    }

    private func issueSurfaceNamespace(
        layerID: UUID,
        generation: UInt64,
        role: DocumentPaintSurfaceRole,
        expectedActiveGeneration: UInt64
    ) throws -> DocumentPaintSurfaceNamespace {
        try withLock {
            guard activeLayers[layerID] != nil else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            guard currentGeneration == expectedActiveGeneration else {
                throw DocumentPaintSurfaceStoreError.staleGeneration(
                    expected: currentGeneration,
                    actual: expectedActiveGeneration
                )
            }
            let (token, overflow) = nextNamespaceToken
                .addingReportingOverflow(1)
            guard !overflow else {
                throw DocumentPaintSurfaceStoreError.namespaceIdentityOverflow
            }
            nextNamespaceToken = token
            return DocumentPaintSurfaceNamespace(
                storeIdentity: sharedTileStore.identity,
                surfaceID: Self.surfaceID(role: role, token: token),
                layerID: layerID,
                generation: generation,
                role: role,
                token: token
            )
        }
    }

    private static func surfaceID(
        role: DocumentPaintSurfaceRole,
        token: UInt64
    ) -> UUID {
        let bytes = token.bigEndian
        return withUnsafeBytes(of: bytes) { raw in
            UUID(uuid: (
                0x4C, 0x41, 0x59, 0x41,
                role.rawValue, 0xD6, 0, 0,
                raw[0], raw[1], raw[2], raw[3],
                raw[4], raw[5], raw[6], raw[7]
            ))
        }
    }

    private func retireNamespace(token: UInt64) {
        _ = withLock { namespaceRecords.removeValue(forKey: token) }
    }

    private func retireCandidateOwnedReferences(
        _ references: [PaintTileReference]
    ) throws {
        let plan = try sharedTileStore.prepareRetirement(references)
        sharedTileStore.requestRetirement(plan)
    }

    private func commitPreparedLocked(
        _ prepared: DocumentPaintPreparedCommit
    ) {
        let candidate = prepared.candidate
        candidate.withLock {
            // The logical publication is guaranteed first. Retirement work is
            // nonthrowing but may mutate hash tables, so it follows the swap.
            activeLayers = candidate.layerStatesStorage
            currentGeneration = candidate.generation
            currentGeometry = candidate.geometry
            candidate.state = .consumed
            candidate.preparedCommit = nil
        }
        preparedCandidateIdentity = nil
        sharedTileStore.requestRetirement(prepared.replacedRetirement)
        sharedTileStore.cancelRetirement(prepared.candidateRetirement)
    }

    private static func sortedUnique(
        _ coordinates: [PaintTileCoordinate]
    ) throws -> [PaintTileCoordinate] {
        let sorted = coordinates.sorted()
        for index in sorted.indices.dropFirst()
        where sorted[index] == sorted[index - 1] {
            throw DocumentPaintSurfaceStoreError
                .duplicateCoordinate(sorted[index])
        }
        return sorted
    }

    private static func validateSortedUnique(
        _ coordinates: [PaintTileCoordinate]
    ) throws {
        for index in coordinates.indices.dropFirst() {
            let previous = coordinates[index - 1]
            let current = coordinates[index]
            if previous == current {
                throw DocumentPaintSurfaceStoreError.duplicateCoordinate(current)
            }
            guard previous < current else {
                throw DocumentPaintSurfaceStoreError.unsortedCoordinate(
                    previous: previous,
                    current: current
                )
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
