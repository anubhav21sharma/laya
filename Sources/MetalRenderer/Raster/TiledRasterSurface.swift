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
