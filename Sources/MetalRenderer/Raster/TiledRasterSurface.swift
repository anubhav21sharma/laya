import Foundation
import Metal
import PatternEngine

public enum TiledRasterSurfaceError: Error, Equatable, Sendable {
    case revisionOverflow
    case generationOverflow
    case leaseLayerMismatch(expected: UUID, actual: UUID)
    case immutableReferenceView
    case foreignReferenceStore
    case duplicateReferenceCoordinate(PaintTileCoordinate)
    case unsortedReferenceCoordinate
    case missingReferenceCoordinate(PaintTileCoordinate)
    case duplicateExactReference
    case unsortedExactReference
    case exactReferenceNotCaptured
    case exactReferenceCaptureClosed
    case providerNotCaptured
    case providerLeaseAlreadyReturned
}

/// Immutable logical surface generation whose coordinates may point into
/// several physical namespaces in one PaintTileStore.
public struct TiledRasterCoordinateReferenceView: Equatable, Sendable {
    public let storeIdentity: PaintTileStoreIdentity
    public let surfaceID: UUID
    public let layerID: UUID
    public let pixelSize: PixelSize
    public let generation: UInt64
    public let revision: RasterRevision
    public let references: [PaintTileReference]

    public init(
        storeIdentity: PaintTileStoreIdentity,
        surfaceID: UUID,
        layerID: UUID,
        pixelSize: PixelSize,
        generation: UInt64,
        revision: RasterRevision,
        references: [PaintTileReference]
    ) throws {
        var previous: PaintTileCoordinate?
        for reference in references {
            guard reference.storeIdentity == storeIdentity else {
                throw TiledRasterSurfaceError.foreignReferenceStore
            }
            guard reference.layerID == layerID else {
                throw TiledRasterSurfaceError.leaseLayerMismatch(
                    expected: layerID,
                    actual: reference.layerID
                )
            }
            _ = try PaintTileDescriptor(
                coordinate: reference.coordinate,
                logicalPixelSize: pixelSize
            )
            if let previous {
                if previous == reference.coordinate {
                    throw TiledRasterSurfaceError
                        .duplicateReferenceCoordinate(reference.coordinate)
                }
                guard previous < reference.coordinate else {
                    throw TiledRasterSurfaceError.unsortedReferenceCoordinate
                }
            }
            previous = reference.coordinate
        }
        self.storeIdentity = storeIdentity
        self.surfaceID = surfaceID
        self.layerID = layerID
        self.pixelSize = pixelSize
        self.generation = generation
        self.revision = revision
        self.references = references
    }
}

public struct TiledRasterBackingSnapshot: Equatable, Sendable {
    public let surfaceID: UUID
    public let layerID: UUID
    public let pixelSize: PixelSize
    public let generation: UInt64
    public let revision: RasterRevision
    public let dirtyTileCoordinates: [PaintTileCoordinate]
    public let residentByteCount: Int
    public let backingByteCount: Int
    public let activeLeaseCount: Int
    public let entries: [PaintTileStoreEntrySnapshot]

    public var tileCoordinates: [PaintTileCoordinate] {
        entries.map(\.identity.coordinate).sorted()
    }
}

/// Unforgeable identity shared only by entitlement-restricted descendants of
/// one exact provider. Captures authorize this lineage plus an exact subset;
/// sharing a PaintTileStore never grants cross-provider authority.
private final class TiledRasterExactReferenceProviderLineage:
    @unchecked Sendable
{}

/// Frozen logical namespace plus its complete exact physical reference set.
/// The raw store is deliberately private to this file; sampling consumers can
/// acquire only through an aggregate capture capability.
final class TiledRasterExactReferenceProvider: @unchecked Sendable {
    let storeIdentity: PaintTileStoreIdentity
    let surfaceID: UUID
    let layerID: UUID
    let pixelSize: PixelSize
    let generation: UInt64
    let revision: RasterRevision
    /// Complete immutable logical content identity. Off-viewport references
    /// remain here so cache collision/invalidation checks see the whole source.
    let identityReferences: [PaintTileReference]
    /// Exact subset which the accompanying aggregate capture may retain/lease.
    let entitledReferences: [PaintTileReference]
    var references: [PaintTileReference] { identityReferences }
    fileprivate let store: PaintTileStore
    fileprivate let lineage: TiledRasterExactReferenceProviderLineage

    #if DEBUG
    var testingLineageAnchor: AnyObject { lineage }
    #endif

    fileprivate init(
        store: PaintTileStore,
        surfaceID: UUID,
        layerID: UUID,
        pixelSize: PixelSize,
        generation: UInt64,
        revision: RasterRevision,
        references: [PaintTileReference],
        entitledReferences: [PaintTileReference]? = nil
    ) throws {
        var previous: PaintTileReference?
        for reference in references {
            guard reference.storeIdentity == store.identity else {
                throw TiledRasterSurfaceError.foreignReferenceStore
            }
            guard reference.layerID == layerID,
                  reference.identity.layerID == layerID
            else {
                throw TiledRasterSurfaceError.leaseLayerMismatch(
                    expected: layerID,
                    actual: reference.layerID
                )
            }
            let expectedDescriptor = try PaintTileDescriptor(
                coordinate: reference.coordinate,
                logicalPixelSize: pixelSize
            )
            guard reference.identity.coordinate == reference.coordinate,
                  reference.descriptor == expectedDescriptor
            else {
                throw TiledRasterSurfaceError.exactReferenceNotCaptured
            }
            if let previous {
                if previous == reference {
                    throw TiledRasterSurfaceError.duplicateExactReference
                }
                guard previous < reference else {
                    throw TiledRasterSurfaceError.unsortedExactReference
                }
                guard previous.coordinate != reference.coordinate else {
                    throw TiledRasterSurfaceError.duplicateExactReference
                }
            }
            previous = reference
        }
        self.store = store
        lineage = TiledRasterExactReferenceProviderLineage()
        storeIdentity = store.identity
        self.surfaceID = surfaceID
        self.layerID = layerID
        self.pixelSize = pixelSize
        self.generation = generation
        self.revision = revision
        let entitlement = entitledReferences ?? references
        try Self.validateExactSubset(entitlement, of: references)
        identityReferences = references
        self.entitledReferences = entitlement
    }

    func restrictingEntitlement(
        to selectedReferences: [PaintTileReference]
    ) throws -> TiledRasterExactReferenceProvider {
        try Self(
            validatedStore: store,
            source: self,
            entitledReferences: selectedReferences
        )
    }

    private init(
        validatedStore store: PaintTileStore,
        source: TiledRasterExactReferenceProvider,
        entitledReferences: [PaintTileReference]
    ) throws {
        try Self.validateExactSubset(
            entitledReferences,
            of: source.identityReferences
        )
        self.store = store
        lineage = source.lineage
        storeIdentity = source.storeIdentity
        surfaceID = source.surfaceID
        layerID = source.layerID
        pixelSize = source.pixelSize
        generation = source.generation
        revision = source.revision
        identityReferences = source.identityReferences
        self.entitledReferences = entitledReferences
    }

    func leaseExactReferences(
        _ selectedReferences: [PaintTileReference],
        using capture: TiledRasterExactReferenceCapture,
        pinReasons: [PaintTilePinReason]
    ) throws -> TiledRasterExactReferenceLease {
        try Self.validateExactSubset(
            selectedReferences,
            of: entitledReferences
        )
        return try capture.reserve(
            selectedReferences,
            from: self,
            pinReasons: Array(Set(pinReasons)).sorted()
        )
    }

    func leaseExactReferences(
        _ selectedReferences: [PaintTileReference],
        using borrow: TiledRasterExactReferenceCapture.Borrow,
        pinReasons: [PaintTilePinReason]
    ) throws -> TiledRasterExactReferenceLease {
        try Self.validateExactSubset(
            selectedReferences,
            of: entitledReferences
        )
        return try borrow.reserve(
            selectedReferences,
            from: self,
            pinReasons: Array(Set(pinReasons)).sorted()
        )
    }

    func backingSnapshot() -> TiledRasterBackingSnapshot {
        let entries = (try? store.snapshot(
            exactReferences: identityReferences
        )) ?? []
        return TiledRasterBackingSnapshot(
            surfaceID: surfaceID,
            layerID: layerID,
            pixelSize: pixelSize,
            generation: generation,
            revision: revision,
            dirtyTileCoordinates: identityReferences.map(\.coordinate),
            residentByteCount: entries.reduce(into: 0) {
                if $1.isResident {
                    $0 += PaintTileDescriptor.residentByteCount
                }
            },
            backingByteCount: entries.reduce(into: 0) {
                $0 += $1.backing.byteCount
            },
            activeLeaseCount: store.activeLeaseCount(
                surfaceID: surfaceID,
                generation: generation
            ),
            entries: entries
        )
    }

    func applyMemoryPressure(
        targetResidentBytes: Int
    ) throws -> PaintTilePressureResult {
        try store.applyMemoryPressure(targetResidentBytes: targetResidentBytes)
    }

    fileprivate func returnLease(_ lease: PaintTileLease) throws {
        try store.release(
            lease,
            surfaceID: surfaceID,
            currentGeneration: generation
        )
    }

    fileprivate static func validateExactSubset(
        _ selectedReferences: [PaintTileReference],
        of availableReferences: [PaintTileReference]
    ) throws {
        var previous: PaintTileReference?
        for selected in selectedReferences {
            if let previous {
                if previous == selected {
                    throw TiledRasterSurfaceError.duplicateExactReference
                }
                guard previous < selected else {
                    throw TiledRasterSurfaceError.unsortedExactReference
                }
            }
            previous = selected
            var lower = 0
            var upper = availableReferences.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if availableReferences[middle] < selected {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower < availableReferences.count,
                  availableReferences[lower] == selected
            else {
                throw TiledRasterSurfaceError.exactReferenceNotCaptured
            }
        }
    }
}

/// One aggregate B0 retention owner. Providers that share the exact same
/// PaintTileStore object share one unioned/deduplicated retention token.
final class TiledRasterExactReferenceCapture: @unchecked Sendable {
    private final class RetentionGroup {
        let store: PaintTileStore
        let token: PaintTileSnapshotToken

        init(store: PaintTileStore, token: PaintTileSnapshotToken) {
            self.store = store
            self.token = token
        }
    }

    private struct PendingGroup {
        let store: PaintTileStore
        var references: [PaintTileReference]
    }

    private struct CapturedLineage {
        let lineage: TiledRasterExactReferenceProviderLineage
        let store: PaintTileStore
        let group: RetentionGroup?
        let references: [PaintTileReference]
    }

    final class Borrow: @unchecked Sendable {
        private let capture: TiledRasterExactReferenceCapture
        private let id: UUID

        fileprivate init(
            capture: TiledRasterExactReferenceCapture,
            id: UUID
        ) {
            self.capture = capture
            self.id = id
        }

        fileprivate func reserve(
            _ references: [PaintTileReference],
            from provider: TiledRasterExactReferenceProvider,
            pinReasons: [PaintTilePinReason]
        ) throws -> TiledRasterExactReferenceLease {
            try capture.reserveBorrowed(
                references,
                from: provider,
                borrowID: id,
                pinReasons: pinReasons
            )
        }

        func close() {
            capture.closeBorrow(id)
        }

        deinit {
            capture.closeBorrow(id)
        }
    }

    private let lock = NSLock()
    private var capturedLineages: [ObjectIdentifier: CapturedLineage]
    private var groups: [RetentionGroup]
    private var activeBorrows: [UUID: Set<ObjectIdentifier>] = [:]
    private var closeRequested = false
    private var groupsClosed = false

    init(providers: [TiledRasterExactReferenceProvider]) throws {
        var pending: [ObjectIdentifier: PendingGroup] = [:]
        var referencesByLineage: [ObjectIdentifier: [PaintTileReference]] = [:]
        var lineageByID: [ObjectIdentifier:
            TiledRasterExactReferenceProviderLineage] = [:]
        var storeByLineage: [ObjectIdentifier: PaintTileStore] = [:]
        for provider in providers {
            let storeObject = ObjectIdentifier(provider.store)
            var group = pending[storeObject] ?? PendingGroup(
                store: provider.store,
                references: []
            )
            group.references.append(contentsOf: provider.entitledReferences)
            pending[storeObject] = group
            let lineageID = ObjectIdentifier(provider.lineage)
            referencesByLineage[lineageID, default: []]
                .append(contentsOf: provider.entitledReferences)
            if let existingLineage = lineageByID[lineageID] {
                precondition(existingLineage === provider.lineage)
            } else {
                lineageByID[lineageID] = provider.lineage
            }
            if let existingStore = storeByLineage[lineageID] {
                precondition(existingStore === provider.store)
            } else {
                storeByLineage[lineageID] = provider.store
            }
        }

        var installedGroups: [RetentionGroup] = []
        var installedByStore: [ObjectIdentifier: RetentionGroup] = [:]
        do {
            let ordered = pending.values.sorted {
                $0.store.identity < $1.store.identity
            }
            for pendingGroup in ordered {
                let sorted = pendingGroup.references.sorted()
                var union: [PaintTileReference] = []
                union.reserveCapacity(sorted.count)
                for reference in sorted where union.last != reference {
                    union.append(reference)
                }
                // A transparent/disjoint selection owns no store capability
                // and must not consume token or metadata capacity.
                guard !union.isEmpty else { continue }
                let token = try pendingGroup.store
                    .retainSnapshotReferences(union)
                let group = RetentionGroup(
                    store: pendingGroup.store,
                    token: token
                )
                installedGroups.append(group)
                installedByStore[ObjectIdentifier(pendingGroup.store)] = group
            }
        } catch {
            for group in installedGroups.reversed() { group.token.close() }
            throw error
        }
        groups = installedGroups
        capturedLineages = [:]
        for (lineageID, references) in referencesByLineage {
            let sorted = references.sorted()
            var union: [PaintTileReference] = []
            union.reserveCapacity(sorted.count)
            for reference in sorted where union.last != reference {
                union.append(reference)
            }
            guard let lineage = lineageByID[lineageID],
                  let store = storeByLineage[lineageID]
            else {
                preconditionFailure("captured lineage lost its store")
            }
            capturedLineages[lineageID] = CapturedLineage(
                lineage: lineage,
                store: store,
                group: installedByStore[ObjectIdentifier(store)],
                references: union
            )
        }
    }

    func close() {
        lock.lock()
        guard !closeRequested else {
            lock.unlock()
            return
        }
        closeRequested = true
        let retainedGroups = groupsToCloseIfReadyLocked()
        lock.unlock()
        for group in retainedGroups { group.token.close() }
    }

    func borrowing(
        providers: [TiledRasterExactReferenceProvider]
    ) throws -> Borrow {
        lock.lock()
        defer { lock.unlock() }
        guard !closeRequested else {
            throw TiledRasterSurfaceError.exactReferenceCaptureClosed
        }
        var lineages: Set<ObjectIdentifier> = []
        for provider in providers {
            let lineageID = ObjectIdentifier(provider.lineage)
            guard let captured = capturedLineages[lineageID],
                  captured.lineage === provider.lineage,
                  captured.store === provider.store
            else { throw TiledRasterSurfaceError.providerNotCaptured }
            try TiledRasterExactReferenceProvider.validateExactSubset(
                provider.entitledReferences,
                of: captured.references
            )
            lineages.insert(lineageID)
        }
        let id = UUID()
        activeBorrows[id] = lineages
        return Borrow(capture: self, id: id)
    }

    fileprivate func reserve(
        _ references: [PaintTileReference],
        from provider: TiledRasterExactReferenceProvider,
        pinReasons: [PaintTilePinReason]
    ) throws -> TiledRasterExactReferenceLease {
        lock.lock()
        defer { lock.unlock() }
        guard !closeRequested else {
            throw TiledRasterSurfaceError.exactReferenceCaptureClosed
        }
        let group = try retainedGroup(
            for: provider,
            references: references
        )
        let lease = try group.store.reserveRetainedReferences(
            references,
            token: group.token,
            leaseSurfaceID: provider.surfaceID,
            leaseLayerID: provider.layerID,
            leaseGeneration: provider.generation,
            pinReasons: pinReasons
        )
        return TiledRasterExactReferenceLease(
            provider: provider,
            lease: lease
        )
    }

    private func reserveBorrowed(
        _ references: [PaintTileReference],
        from provider: TiledRasterExactReferenceProvider,
        borrowID: UUID,
        pinReasons: [PaintTilePinReason]
    ) throws -> TiledRasterExactReferenceLease {
        lock.lock()
        defer { lock.unlock() }
        let lineageID = ObjectIdentifier(provider.lineage)
        guard activeBorrows[borrowID]?.contains(lineageID) == true else {
            throw TiledRasterSurfaceError.exactReferenceCaptureClosed
        }
        let group = try retainedGroup(
            for: provider,
            references: references
        )
        let lease = try group.store.reserveRetainedReferences(
            references,
            token: group.token,
            leaseSurfaceID: provider.surfaceID,
            leaseLayerID: provider.layerID,
            leaseGeneration: provider.generation,
            pinReasons: pinReasons
        )
        return TiledRasterExactReferenceLease(
            provider: provider,
            lease: lease
        )
    }

    private func retainedGroup(
        for provider: TiledRasterExactReferenceProvider,
        references: [PaintTileReference]
    ) throws -> RetentionGroup {
        let lineageID = ObjectIdentifier(provider.lineage)
        guard let captured = capturedLineages[lineageID],
              captured.lineage === provider.lineage,
              captured.store === provider.store
        else { throw TiledRasterSurfaceError.providerNotCaptured }
        try TiledRasterExactReferenceProvider.validateExactSubset(
            references,
            of: captured.references
        )
        guard let group = captured.group else {
            throw TiledRasterSurfaceError.providerNotCaptured
        }
        return group
    }

    private func closeBorrow(_ id: UUID) {
        lock.lock()
        guard activeBorrows.removeValue(forKey: id) != nil else {
            lock.unlock()
            return
        }
        let retainedGroups = groupsToCloseIfReadyLocked()
        lock.unlock()
        for group in retainedGroups { group.token.close() }
    }

    private func groupsToCloseIfReadyLocked() -> [RetentionGroup] {
        guard closeRequested, activeBorrows.isEmpty, !groupsClosed else {
            return []
        }
        groupsClosed = true
        let retainedGroups = groups
        groups.removeAll(keepingCapacity: false)
        capturedLineages.removeAll(keepingCapacity: false)
        return retainedGroups
    }
}

/// Provider-bound lease. It exposes immutable bindings and the frozen logical
/// namespace, but never the raw PaintTileStore, B0 token, or raw lease.
final class TiledRasterExactReferenceLease: @unchecked Sendable {
    let surfaceID: UUID
    let layerID: UUID
    let generation: UInt64
    let bindings: [PaintTileBinding]

    private let lock = NSLock()
    private let provider: TiledRasterExactReferenceProvider
    private var lease: PaintTileLease?

    fileprivate init(
        provider: TiledRasterExactReferenceProvider,
        lease: PaintTileLease
    ) {
        self.provider = provider
        self.lease = lease
        surfaceID = provider.surfaceID
        layerID = provider.layerID
        generation = provider.generation
        bindings = lease.bindings
    }

    func returnLease() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let lease else {
            throw TiledRasterSurfaceError.providerLeaseAlreadyReturned
        }
        try provider.returnLease(lease)
        self.lease = nil
    }
}

/// Sparse RGBA16F storage core. Production paint routing remains on the
/// established surfaces until the Stage D atomic switch.
public final class TiledRasterSurface: RasterSurface, @unchecked Sendable {
    public let surfaceID: UUID
    public let layerID: UUID
    public let pixelSize: PixelSize

    private let lock = NSLock()
    private let store: PaintTileStore
    private let referenceView: TiledRasterCoordinateReferenceView?
    private var currentGeneration: UInt64
    private var currentRevision: RasterRevision
    private var dirtyCoordinates: Set<PaintTileCoordinate> = []

    public convenience init(
        device: any MTLDevice,
        layerID: UUID,
        pixelSize: PixelSize,
        surfaceID: UUID = UUID(),
        generation: UInt64 = 0,
        initialRevision: RasterRevision = RasterRevision(rawValue: 0),
        byteBudget: Int
    ) {
        self.init(
            store: PaintTileStore(device: device, byteBudget: byteBudget),
            layerID: layerID,
            pixelSize: pixelSize,
            surfaceID: surfaceID,
            generation: generation,
            initialRevision: initialRevision
        )
    }

    public init(
        store: PaintTileStore,
        layerID: UUID,
        pixelSize: PixelSize,
        surfaceID: UUID = UUID(),
        generation: UInt64 = 0,
        initialRevision: RasterRevision = RasterRevision(rawValue: 0)
    ) {
        self.surfaceID = surfaceID
        self.layerID = layerID
        self.pixelSize = pixelSize
        currentGeneration = generation
        currentRevision = initialRevision
        self.store = store
        referenceView = nil
        dirtyCoordinates.reserveCapacity(
            max(
                1,
                store.byteBudget / PaintTileDescriptor.residentByteCount
            )
        )
    }

    public init(
        store: PaintTileStore,
        referenceView: TiledRasterCoordinateReferenceView
    ) throws {
        guard referenceView.storeIdentity == store.identity else {
            throw TiledRasterSurfaceError.foreignReferenceStore
        }
        surfaceID = referenceView.surfaceID
        layerID = referenceView.layerID
        pixelSize = referenceView.pixelSize
        currentGeneration = referenceView.generation
        currentRevision = referenceView.revision
        self.store = store
        self.referenceView = referenceView
    }

    public convenience init(
        device: any MTLDevice,
        layerID: UUID,
        pixelSize: PixelSize,
        surfaceID: UUID = UUID(),
        generation: UInt64 = 0,
        initialRevision: RasterRevision = RasterRevision(rawValue: 0),
        budgetFallback: PaintTileBudgetFallback
    ) throws {
        try self.init(
            device: device,
            layerID: layerID,
            pixelSize: pixelSize,
            surfaceID: surfaceID,
            generation: generation,
            initialRevision: initialRevision,
            byteBudget: PaintTileBudget.bytes(
                for: device,
                fallback: budgetFallback
            )
        )
    }

    public var generation: UInt64 {
        withLock { currentGeneration }
    }

    public var revision: RasterRevision {
        withLock { currentRevision }
    }

    public var isEmpty: Bool {
        withLock { currentEntries().isEmpty }
    }

    public var residentTileCount: Int {
        withLock { currentEntries().filter(\.isResident).count }
    }

    public var residentByteCount: Int {
        withLock {
            currentEntries().reduce(into: 0) {
                if $1.isResident {
                    $0 += PaintTileDescriptor.residentByteCount
                }
            }
        }
    }

    public var backingByteCount: Int {
        withLock {
            currentEntries().reduce(into: 0) {
                $0 += $1.backing.byteCount
            }
        }
    }

    public var dirtyTileCoordinates: [PaintTileCoordinate] {
        withLock { dirtyCoordinates.sorted() }
    }

    public var references: [PaintTileReference] {
        withLock {
            if let referenceView { return referenceView.references }
            return (try? store.references(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: currentGeneration
            )) ?? []
        }
    }

    /// Freezes logical namespace metadata and the complete exact reference
    /// set under the surface lock. Aggregate B0 retention is deliberately a
    /// separate batch step so sibling providers can share one store token.
    func makeExactReferenceProvider() throws
        -> TiledRasterExactReferenceProvider
    {
        try withLock {
            let frozenReferences: [PaintTileReference]
            if let referenceView {
                frozenReferences = referenceView.references
            } else {
                frozenReferences = store.samplingReferences(
                    surfaceID: surfaceID,
                    layerID: layerID,
                    generation: currentGeneration
                )
            }
            return try TiledRasterExactReferenceProvider(
                store: store,
                surfaceID: surfaceID,
                layerID: layerID,
                pixelSize: pixelSize,
                generation: currentGeneration,
                revision: currentRevision,
                references: frozenReferences
            )
        }
    }

    /// Pins exact existing entries without allocating new coordinates. Both
    /// mutable namespace surfaces and immutable coordinate views expose this
    /// same sampler-facing lease contract.
    public func leaseExistingTiles(
        at coordinates: [PaintTileCoordinate],
        pinReasons: [PaintTilePinReason]
    ) throws -> PaintTileLease {
        try withLock {
            let available: [PaintTileReference]
            if let referenceView {
                available = referenceView.references
            } else {
                available = try store.references(
                    surfaceID: surfaceID,
                    layerID: layerID,
                    generation: currentGeneration
                )
            }
            let byCoordinate = Dictionary(
                uniqueKeysWithValues: available.map { ($0.coordinate, $0) }
            )
            let sorted = coordinates.sorted()
            for index in sorted.indices.dropFirst()
            where sorted[index] == sorted[index - 1] {
                throw PaintTileStoreError.duplicateCoordinate(sorted[index])
            }
            let selected = try sorted.map { coordinate in
                guard let reference = byCoordinate[coordinate] else {
                    throw TiledRasterSurfaceError
                        .missingReferenceCoordinate(coordinate)
                }
                return reference
            }
            return try store.reserveReferences(
                selected,
                leaseSurfaceID: surfaceID,
                leaseLayerID: layerID,
                leaseGeneration: currentGeneration,
                pinReasons: Array(Set(pinReasons)).sorted()
            )
        }
    }

    public func reserveTiles(
        intersecting supportBounds: PixelRect,
        antialiasHalo: Int = 1,
        pinReasons: [PaintTilePinReason],
        failureInjection: PaintTileAllocationFailureInjection? = nil
    ) throws -> PaintTileLease {
        guard referenceView == nil else {
            throw TiledRasterSurfaceError.immutableReferenceView
        }
        let coordinates = try PaintTileDescriptor.coordinates(
            intersecting: supportBounds,
            in: pixelSize,
            antialiasHalo: antialiasHalo
        )
        return try reserveTiles(
            at: coordinates,
            pinReasons: pinReasons,
            failureInjection: failureInjection
        )
    }

    public func reserveTiles(
        at coordinates: [PaintTileCoordinate],
        pinReasons: [PaintTilePinReason],
        failureInjection: PaintTileAllocationFailureInjection? = nil
    ) throws -> PaintTileLease {
        guard referenceView == nil else {
            throw TiledRasterSurfaceError.immutableReferenceView
        }
        return try withLock {
            try store.reserve(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: currentGeneration,
                pixelSize: pixelSize,
                coordinates: coordinates,
                pinReasons: pinReasons,
                failureInjection: failureInjection
            )
        }
    }

    public func reserveSortedUniqueTiles(
        at coordinates: [PaintTileCoordinate],
        pinReasons: [PaintTilePinReason],
        failureInjection: PaintTileAllocationFailureInjection? = nil
    ) throws -> PaintTileLease {
        guard referenceView == nil else {
            throw TiledRasterSurfaceError.immutableReferenceView
        }
        return try withLock {
            try store.reserveSortedUnique(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: currentGeneration,
                pixelSize: pixelSize,
                coordinates: coordinates,
                pinReasons: pinReasons,
                failureInjection: failureInjection
            )
        }
    }

    func reserveSortedUniqueStrokeTiles(
        at coordinates: [PaintTileCoordinate],
        pinReasons: [PaintTilePinReason],
        workspace: PaintTileStrokeLeaseWorkspace,
        failureInjection: PaintTileAllocationFailureInjection? = nil
    ) throws -> PaintTileLease {
        guard referenceView == nil else {
            throw TiledRasterSurfaceError.immutableReferenceView
        }
        return try withLock {
            try store.reserveSortedUniqueForStroke(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: currentGeneration,
                pixelSize: pixelSize,
                coordinates: coordinates,
                pinReasons: pinReasons,
                workspace: workspace,
                failureInjection: failureInjection
            )
        }
    }

    public func markDirty(_ lease: PaintTileLease) throws {
        try markDirty(
            lease,
            coordinates: lease.bindings.map(\.descriptor.coordinate)
        )
    }

    public func markDirty(
        _ lease: PaintTileLease,
        coordinates: [PaintTileCoordinate]
    ) throws {
        guard referenceView == nil else {
            throw TiledRasterSurfaceError.immutableReferenceView
        }
        guard lease.layerID == layerID else {
            throw TiledRasterSurfaceError.leaseLayerMismatch(
                expected: layerID,
                actual: lease.layerID
            )
        }
        return try withLock {
            guard currentRevision.rawValue < UInt64.max else {
                throw TiledRasterSurfaceError.revisionOverflow
            }
            try store.markModified(
                lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration,
                coordinates: coordinates
            )
            dirtyCoordinates.formUnion(coordinates)
            currentRevision = RasterRevision(
                rawValue: currentRevision.rawValue + 1
            )
        }
    }

    func makeProvisionalBindings(
        for lease: PaintTileLease,
        coordinates: [PaintTileCoordinate],
        workspace: PaintTileProvisionalWorkspace
    ) throws -> PaintTileProvisionalReservation {
        guard referenceView == nil else {
            throw TiledRasterSurfaceError.immutableReferenceView
        }
        guard lease.layerID == layerID else {
            throw TiledRasterSurfaceError.leaseLayerMismatch(
                expected: layerID,
                actual: lease.layerID
            )
        }
        return try withLock {
            try store.makeProvisionalBindings(
                for: lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration,
                coordinates: coordinates,
                workspace: workspace
            )
        }
    }

    func commitProvisionalBindings(
        _ provisional: PaintTileProvisionalReservation,
        for lease: PaintTileLease,
        modifiedCoordinates: [PaintTileCoordinate],
        knownClearCoordinates: [PaintTileCoordinate]
    ) throws -> PaintTileLease {
        guard referenceView == nil else {
            throw TiledRasterSurfaceError.immutableReferenceView
        }
        return try withLock {
            guard currentRevision.rawValue < UInt64.max else {
                throw TiledRasterSurfaceError.revisionOverflow
            }
            let committed = try store.commitProvisionalBindings(
                provisional,
                for: lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration,
                modifiedCoordinates: modifiedCoordinates,
                knownClearCoordinates: knownClearCoordinates
            )
            dirtyCoordinates.formUnion(modifiedCoordinates)
            dirtyCoordinates.subtract(knownClearCoordinates)
            currentRevision = RasterRevision(
                rawValue: currentRevision.rawValue + 1
            )
            return committed
        }
    }

    func cancelProvisionalBindings(
        _ provisional: PaintTileProvisionalReservation
    ) throws {
        try store.cancelProvisionalBindings(provisional)
    }

    func completeProvisionalBindings(
        _ provisional: PaintTileProvisionalReservation
    ) {
        store.completeProvisionalBindings(provisional)
    }

    func markKnownClear(
        _ lease: PaintTileLease,
        coordinates: [PaintTileCoordinate]
    ) throws {
        guard referenceView == nil else {
            throw TiledRasterSurfaceError.immutableReferenceView
        }
        guard lease.layerID == layerID else {
            throw TiledRasterSurfaceError.leaseLayerMismatch(
                expected: layerID,
                actual: lease.layerID
            )
        }
        guard !coordinates.isEmpty else { return }
        try withLock {
            guard currentRevision.rawValue < UInt64.max else {
                throw TiledRasterSurfaceError.revisionOverflow
            }
            try store.markKnownClear(
                lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration,
                coordinates: coordinates
            )
            dirtyCoordinates.subtract(coordinates)
            currentRevision = RasterRevision(
                rawValue: currentRevision.rawValue + 1
            )
        }
    }

    public func returnLease(_ lease: PaintTileLease) throws {
        guard lease.layerID == layerID else {
            throw TiledRasterSurfaceError.leaseLayerMismatch(
                expected: layerID,
                actual: lease.layerID
            )
        }
        try withLock {
            try store.release(
                lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration
            )
        }
    }

    public func applyMemoryPressure(
        targetResidentBytes: Int
    ) throws -> PaintTilePressureResult {
        try withLock {
            try store.applyMemoryPressure(
                targetResidentBytes: targetResidentBytes
            )
        }
    }

    public func advanceGeneration() throws {
        guard referenceView == nil else {
            throw TiledRasterSurfaceError.immutableReferenceView
        }
        try withLock {
            guard currentGeneration < UInt64.max else {
                throw TiledRasterSurfaceError.generationOverflow
            }
            guard currentRevision.rawValue < UInt64.max else {
                throw TiledRasterSurfaceError.revisionOverflow
            }
            // Retire validates outstanding leases before changing any state.
            try store.retire(
                surfaceID: surfaceID,
                generation: currentGeneration
            )
            currentGeneration += 1
            currentRevision = RasterRevision(
                rawValue: currentRevision.rawValue + 1
            )
            dirtyCoordinates.removeAll(keepingCapacity: true)
        }
    }

    public func backingSnapshot() -> TiledRasterBackingSnapshot {
        withLock {
            let entries = currentEntries()
            return TiledRasterBackingSnapshot(
                surfaceID: surfaceID,
                layerID: layerID,
                pixelSize: pixelSize,
                generation: currentGeneration,
                revision: currentRevision,
                dirtyTileCoordinates: dirtyCoordinates.sorted(),
                residentByteCount: entries.reduce(into: 0) {
                    if $1.isResident {
                        $0 += PaintTileDescriptor.residentByteCount
                    }
                },
                backingByteCount: entries.reduce(into: 0) {
                    $0 += $1.backing.byteCount
                },
                activeLeaseCount: store.activeLeaseCount(
                    surfaceID: surfaceID,
                    generation: currentGeneration
                ),
                entries: entries
            )
        }
    }

    public func payloadSnapshot() throws -> PaintTilePayloadSnapshot {
        guard referenceView == nil else {
            throw TiledRasterSurfaceError.immutableReferenceView
        }
        return try withLock {
            try store.payloadSnapshot(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: currentGeneration
            )
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func currentEntries() -> [PaintTileStoreEntrySnapshot] {
        if let referenceView {
            return (try? store.snapshot(
                exactReferences: referenceView.references
            )) ?? []
        }
        return store.snapshot().entries.filter {
            $0.surfaceID == surfaceID
                && $0.generation == currentGeneration
                && $0.identity.layerID == layerID
        }
    }
}
