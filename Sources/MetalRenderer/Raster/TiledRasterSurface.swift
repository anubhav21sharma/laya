import Foundation
import Metal
import PatternEngine

public enum TiledRasterSurfaceError: Error, Equatable, Sendable {
    case revisionOverflow
    case generationOverflow
    case leaseLayerMismatch(expected: UUID, actual: UUID)
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

    public func reserveTiles(
        intersecting supportBounds: PixelRect,
        antialiasHalo: Int = 1,
        pinReasons: [PaintTilePinReason],
        failureInjection: PaintTileAllocationFailureInjection? = nil
    ) throws -> PaintTileLease {
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
        try withLock {
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

    public func markDirty(_ lease: PaintTileLease) throws {
        guard lease.layerID == layerID else {
            throw TiledRasterSurfaceError.leaseLayerMismatch(
                expected: layerID,
                actual: lease.layerID
            )
        }
        try withLock {
            guard currentRevision.rawValue < UInt64.max else {
                throw TiledRasterSurfaceError.revisionOverflow
            }
            try store.markModified(
                lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration
            )
            dirtyCoordinates.formUnion(
                lease.bindings.map(\.descriptor.coordinate)
            )
            currentRevision = RasterRevision(
                rawValue: currentRevision.rawValue + 1
            )
        }
    }

    public func returnLease(_ lease: PaintTileLease) throws {
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
            let storeSnapshot = store.snapshot()
            let entries = storeSnapshot.entries.filter {
                $0.surfaceID == surfaceID
                    && $0.generation == currentGeneration
                    && $0.identity.layerID == layerID
            }
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

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func currentEntries() -> [PaintTileStoreEntrySnapshot] {
        store.snapshot().entries.filter {
            $0.surfaceID == surfaceID
                && $0.generation == currentGeneration
                && $0.identity.layerID == layerID
        }
    }
}
