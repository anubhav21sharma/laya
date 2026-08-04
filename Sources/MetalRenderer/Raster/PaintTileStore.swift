import Foundation
import Metal
import PatternEngine

public enum PaintTileStoreError: Error, Equatable, Sendable {
    case emptyPinReasons
    case duplicateCoordinate(PaintTileCoordinate)
    case injectedAllocationFailure(reserveIndex: Int)
    case textureAllocationFailed(reserveIndex: Int)
    case commandQueueUnavailable
    case commandBufferUnavailable
    case blitEncoderUnavailable
    case stagingBufferAllocationFailed
    case gpuTransferFailed(String)
    case identityOverflow
    case leaseIdentityOverflow
    case stateRevisionOverflow
    case invalidLease(PaintTileLeaseID)
    case wrongSurface(expected: UUID, actual: UUID)
    case staleGeneration(expected: UInt64, actual: UInt64)
    case leaseBindingMismatch
    case outstandingLeases(surfaceID: UUID, generation: UInt64, count: Int)
}

public struct PaintTileLeaseID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct PaintTileBinding: @unchecked Sendable {
    public let identity: PaintTileIdentity
    public let descriptor: PaintTileDescriptor
    public let texture: any MTLTexture
}

public struct PaintTileLease: @unchecked Sendable {
    public let id: PaintTileLeaseID
    public let surfaceID: UUID
    public let layerID: UUID
    public let generation: UInt64
    public let pinReasons: [PaintTilePinReason]
    public let bindings: [PaintTileBinding]
}

public struct PaintTileAllocationFailureInjection: Sendable {
    private let failingReserveIndices: Set<Int>

    public init(failingAtReserveIndex index: Int) {
        failingReserveIndices = [index]
    }

    public init(failingAtReserveIndices indices: Set<Int>) {
        failingReserveIndices = indices
    }

    func shouldFail(at reserveIndex: Int) -> Bool {
        failingReserveIndices.contains(reserveIndex)
    }
}

public enum PaintTileBackingSnapshot: Equatable, Sendable {
    case residentOnly
    case knownClear
    case rgba16Float(Data)

    public var byteCount: Int {
        switch self {
        case .residentOnly, .knownClear: 0
        case let .rgba16Float(data): data.count
        }
    }
}

public struct PaintTileStoreEntrySnapshot: Equatable, Sendable {
    public let surfaceID: UUID
    public let generation: UInt64
    public let identity: PaintTileIdentity
    public let descriptor: PaintTileDescriptor
    public let isResident: Bool
    public let backing: PaintTileBackingSnapshot
    public let lastUseEpoch: UInt64?
    public let pinCounts: [PaintTilePinReason: Int]
}

public struct PaintTileStoreSnapshot: Equatable, Sendable {
    public let stateRevision: UInt64
    public let nextTileID: UInt64
    public let nextLeaseID: UInt64
    public let residentByteCount: Int
    public let backingByteCount: Int
    public let activeLeaseCount: Int
    public let entries: [PaintTileStoreEntrySnapshot]
    public let leastRecentlyUsedOrder: [PaintTileIdentity]
}

public struct PaintTilePressureResult: Equatable, Sendable {
    public let evictedIdentities: [PaintTileIdentity]
    public let residentByteCount: Int
    public let backingByteCount: Int
}

public final class PaintTileStore: @unchecked Sendable {
    private struct Key: Hashable {
        let surfaceID: UUID
        let layerID: UUID
        let generation: UInt64
        let coordinate: PaintTileCoordinate
    }

    private struct Record {
        let identity: PaintTileIdentity
        let descriptor: PaintTileDescriptor
        var texture: (any MTLTexture)?
        var backing: PaintTileBackingSnapshot?
    }

    private struct LeaseRecord {
        let surfaceID: UUID
        let generation: UInt64
        let identities: [PaintTileIdentity]
        let pinReasons: [PaintTilePinReason]
    }

    private struct Allocation {
        let key: Key
        let identity: PaintTileIdentity
        let descriptor: PaintTileDescriptor
        let texture: any MTLTexture
        let sourceBacking: PaintTileBackingSnapshot
        let isNew: Bool
    }

    private let device: any MTLDevice
    private let lock = NSLock()
    private var residency: PaintTileResidency
    private var records: [Key: Record] = [:]
    private var leases: [PaintTileLeaseID: LeaseRecord] = [:]
    private var nextTileID: UInt64 = 0
    private var nextLeaseID: UInt64 = 0
    private var stateRevision: UInt64 = 0

    public init(device: any MTLDevice, byteBudget: Int) {
        precondition(byteBudget > 0)
        self.device = device
        residency = PaintTileResidency(byteBudget: byteBudget)
    }

    public var byteBudget: Int { residency.byteBudget }

    public var residentByteCount: Int {
        withLock { residency.residentByteCount }
    }

    public var backingByteCount: Int {
        withLock { Self.backingByteCount(in: records) }
    }

    /// Metadata-only lookup. Texture access is deliberately available only
    /// through a generation-scoped lease returned by `reserve`.
    public func lookup(
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64,
        coordinate: PaintTileCoordinate
    ) -> PaintTileStoreEntrySnapshot? {
        snapshot().entries.first {
            $0.surfaceID == surfaceID
                && $0.identity.layerID == layerID
                && $0.generation == generation
                && $0.identity.coordinate == coordinate
        }
    }

    public func snapshot() -> PaintTileStoreSnapshot {
        withLock {
            let entrySnapshots = records.map { key, record in
                let entry = residency.entries[record.identity]
                return PaintTileStoreEntrySnapshot(
                    surfaceID: key.surfaceID,
                    generation: key.generation,
                    identity: record.identity,
                    descriptor: record.descriptor,
                    isResident: record.texture != nil,
                    backing: record.backing ?? .residentOnly,
                    lastUseEpoch: entry?.lastUseEpoch,
                    pinCounts: entry?.pinCounts ?? [:]
                )
            }
            .sorted { $0.identity < $1.identity }
            return PaintTileStoreSnapshot(
                stateRevision: stateRevision,
                nextTileID: nextTileID,
                nextLeaseID: nextLeaseID,
                residentByteCount: residency.residentByteCount,
                backingByteCount: Self.backingByteCount(in: records),
                activeLeaseCount: leases.count,
                entries: entrySnapshots,
                leastRecentlyUsedOrder: residency.leastRecentlyUsedOrder
            )
        }
    }

    public func reserve(
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64,
        pixelSize: PixelSize,
        coordinates: [PaintTileCoordinate],
        pinReasons: [PaintTilePinReason],
        failureInjection: PaintTileAllocationFailureInjection? = nil
    ) throws -> PaintTileLease {
        let reasons = Array(Set(pinReasons)).sorted()
        guard !reasons.isEmpty else { throw PaintTileStoreError.emptyPinReasons }
        let sortedCoordinates = coordinates.sorted()
        for index in sortedCoordinates.indices.dropFirst() {
            if sortedCoordinates[index] == sortedCoordinates[index - 1] {
                throw PaintTileStoreError.duplicateCoordinate(
                    sortedCoordinates[index]
                )
            }
        }
        let descriptors = try sortedCoordinates.map {
            try PaintTileDescriptor(
                coordinate: $0,
                logicalPixelSize: pixelSize
            )
        }

        return try withLock {
            let keys = sortedCoordinates.map {
                Key(
                    surfaceID: surfaceID,
                    layerID: layerID,
                    generation: generation,
                    coordinate: $0
                )
            }
            var stagedResidency = residency
            var stagedNextTileID = nextTileID
            var requested: [(Key, PaintTileIdentity, PaintTileDescriptor)] = []
            requested.reserveCapacity(keys.count)
            for (key, descriptor) in zip(keys, descriptors) {
                if let existing = records[key] {
                    requested.append((key, existing.identity, descriptor))
                } else {
                    let (rawID, overflow) = stagedNextTileID
                        .addingReportingOverflow(1)
                    guard !overflow else {
                        throw PaintTileStoreError.identityOverflow
                    }
                    stagedNextTileID = rawID
                    requested.append((
                        key,
                        PaintTileIdentity(
                            layerID: layerID,
                            coordinate: descriptor.coordinate,
                            tileID: PaintTileID(rawValue: rawID)
                        ),
                        descriptor
                    ))
                }
            }
            try preflightCapacity(
                requestedIdentities: requested.map(\.1),
                residency: stagedResidency
            )

            var evicted: [PaintTileIdentity] = []
            // Pin every already-resident requested tile before admitting any
            // missing tile, so no member of this all-or-nothing reservation
            // can become another member's eviction victim.
            for (_, identity, _) in requested
            where stagedResidency.entries[identity] != nil {
                evicted.append(contentsOf: try stagedResidency.admit(
                    identity,
                    byteCount: PaintTileDescriptor.residentByteCount,
                    pinReasons: reasons
                ))
            }
            for (_, identity, _) in requested
            where stagedResidency.entries[identity] == nil {
                evicted.append(contentsOf: try stagedResidency.admit(
                    identity,
                    byteCount: PaintTileDescriptor.residentByteCount,
                    pinReasons: reasons
                ))
            }
            var uniqueEvictions: [PaintTileIdentity] = []
            uniqueEvictions.reserveCapacity(evicted.count)
            for identity in evicted where !uniqueEvictions.contains(identity) {
                uniqueEvictions.append(identity)
            }
            evicted = uniqueEvictions

            var allocations: [Allocation] = []
            allocations.reserveCapacity(requested.count)
            for (key, identity, descriptor) in requested {
                if records[key]?.texture != nil { continue }
                let reserveIndex = allocations.count
                if failureInjection?.shouldFail(at: reserveIndex) == true {
                    throw PaintTileStoreError.injectedAllocationFailure(
                        reserveIndex: reserveIndex
                    )
                }
                let textureDescriptor = MTLTextureDescriptor
                    .texture2DDescriptor(
                        pixelFormat: PaintTileDescriptor.pixelFormat,
                        width: PaintTileDescriptor.side,
                        height: PaintTileDescriptor.side,
                        mipmapped: false
                    )
                textureDescriptor.storageMode = .private
                textureDescriptor.usage = [
                    .renderTarget, .shaderRead, .shaderWrite,
                ]
                guard let texture = device.makeTexture(
                    descriptor: textureDescriptor
                ) else {
                    throw PaintTileStoreError.textureAllocationFailed(
                        reserveIndex: reserveIndex
                    )
                }
                texture.label = "Paint Tile \(identity.tileID.rawValue)"
                allocations.append(Allocation(
                    key: key,
                    identity: identity,
                    descriptor: descriptor,
                    texture: texture,
                    sourceBacking: records[key]?.backing ?? .knownClear,
                    isNew: records[key] == nil
                ))
            }

            let captured = try transfer(
                evicted: evicted,
                allocations: allocations
            )
            let (leaseRawID, leaseOverflow) = nextLeaseID
                .addingReportingOverflow(1)
            guard !leaseOverflow else {
                throw PaintTileStoreError.leaseIdentityOverflow
            }
            let nextStateRevision = try advancedStateRevision()

            var stagedRecords = records
            for identity in evicted {
                guard let key = stagedRecords.first(where: {
                    $0.value.identity == identity
                })?.key else { continue }
                stagedRecords[key]?.texture = nil
                if let snapshot = captured[identity] {
                    stagedRecords[key]?.backing = snapshot
                }
            }
            for allocation in allocations {
                if allocation.isNew {
                    stagedRecords[allocation.key] = Record(
                        identity: allocation.identity,
                        descriptor: allocation.descriptor,
                        texture: allocation.texture,
                        backing: .knownClear
                    )
                } else {
                    stagedRecords[allocation.key]?.texture = allocation.texture
                    // The private texture is authoritative again after the
                    // upload; retaining the CPU copy would double owned bytes.
                    stagedRecords[allocation.key]?.backing = nil
                }
            }
            let bindings: [PaintTileBinding] = requested.compactMap {
                key, identity, descriptor -> PaintTileBinding? in
                guard let texture = stagedRecords[key]?.texture else {
                    return nil
                }
                return PaintTileBinding(
                    identity: identity,
                    descriptor: descriptor,
                    texture: texture
                )
            }
            guard bindings.count == requested.count else {
                throw PaintTileStoreError.leaseBindingMismatch
            }
            let leaseID = PaintTileLeaseID(rawValue: leaseRawID)
            var stagedLeases = leases
            stagedLeases[leaseID] = LeaseRecord(
                surfaceID: surfaceID,
                generation: generation,
                identities: requested.map(\.1),
                pinReasons: reasons
            )

            records = stagedRecords
            residency = stagedResidency
            leases = stagedLeases
            nextTileID = stagedNextTileID
            nextLeaseID = leaseRawID
            stateRevision = nextStateRevision
            return PaintTileLease(
                id: leaseID,
                surfaceID: surfaceID,
                layerID: layerID,
                generation: generation,
                pinReasons: reasons,
                bindings: bindings
            )
        }
    }

    public func markModified(
        _ lease: PaintTileLease,
        surfaceID: UUID,
        currentGeneration: UInt64
    ) throws {
        try withLock {
            let leaseRecord = try validate(
                lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration
            )
            let nextRevision = try advancedStateRevision()
            var staged = records
            for identity in leaseRecord.identities {
                guard let key = staged.first(where: {
                    $0.value.identity == identity
                })?.key else {
                    throw PaintTileStoreError.leaseBindingMismatch
                }
                staged[key]?.backing = nil
            }
            records = staged
            stateRevision = nextRevision
        }
    }

    public func release(
        _ lease: PaintTileLease,
        surfaceID: UUID,
        currentGeneration: UInt64
    ) throws {
        try withLock {
            let leaseRecord = try validate(
                lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration
            )
            var staged = residency
            for identity in leaseRecord.identities {
                for reason in leaseRecord.pinReasons {
                    try staged.unpin(identity, reason: reason)
                }
            }
            let nextRevision = try advancedStateRevision()
            residency = staged
            leases.removeValue(forKey: lease.id)
            stateRevision = nextRevision
        }
    }

    public func applyMemoryPressure(
        targetResidentBytes: Int
    ) throws -> PaintTilePressureResult {
        try withLock {
            var stagedResidency = residency
            let evicted = try stagedResidency.evictUnpinned(
                to: targetResidentBytes
            )
            guard !evicted.isEmpty else {
                return PaintTilePressureResult(
                    evictedIdentities: [],
                    residentByteCount: residency.residentByteCount,
                    backingByteCount: Self.backingByteCount(in: records)
                )
            }
            let captured = try transfer(evicted: evicted, allocations: [])
            let nextRevision = try advancedStateRevision()
            var stagedRecords = records
            for identity in evicted {
                guard let key = stagedRecords.first(where: {
                    $0.value.identity == identity
                })?.key else { continue }
                stagedRecords[key]?.texture = nil
                if let snapshot = captured[identity] {
                    stagedRecords[key]?.backing = snapshot
                }
            }
            records = stagedRecords
            residency = stagedResidency
            stateRevision = nextRevision
            return PaintTilePressureResult(
                evictedIdentities: evicted,
                residentByteCount: stagedResidency.residentByteCount,
                backingByteCount: Self.backingByteCount(in: stagedRecords)
            )
        }
    }

    public func retire(surfaceID: UUID, generation: UInt64) throws {
        try withLock {
            let matchingLeases = leases.values.filter {
                $0.surfaceID == surfaceID && $0.generation == generation
            }.count
            guard matchingLeases == 0 else {
                throw PaintTileStoreError.outstandingLeases(
                    surfaceID: surfaceID,
                    generation: generation,
                    count: matchingLeases
                )
            }
            let keys = records.keys.filter {
                $0.surfaceID == surfaceID && $0.generation == generation
            }
            guard !keys.isEmpty else { return }
            let nextRevision = try advancedStateRevision()
            for key in keys {
                if let identity = records[key]?.identity {
                    residency.remove(identity)
                }
                records.removeValue(forKey: key)
            }
            stateRevision = nextRevision
        }
    }

    public func activeLeaseCount(
        surfaceID: UUID,
        generation: UInt64
    ) -> Int {
        withLock {
            leases.values.filter {
                $0.surfaceID == surfaceID && $0.generation == generation
            }.count
        }
    }

    private func validate(
        _ lease: PaintTileLease,
        surfaceID: UUID,
        currentGeneration: UInt64
    ) throws -> LeaseRecord {
        guard lease.surfaceID == surfaceID else {
            throw PaintTileStoreError.wrongSurface(
                expected: surfaceID,
                actual: lease.surfaceID
            )
        }
        guard lease.generation == currentGeneration else {
            throw PaintTileStoreError.staleGeneration(
                expected: currentGeneration,
                actual: lease.generation
            )
        }
        guard let record = leases[lease.id] else {
            throw PaintTileStoreError.invalidLease(lease.id)
        }
        guard record.surfaceID == surfaceID,
              record.generation == currentGeneration,
              record.identities == lease.bindings.map(\.identity),
              record.pinReasons == lease.pinReasons
        else {
            throw PaintTileStoreError.leaseBindingMismatch
        }
        return record
    }

    private func preflightCapacity(
        requestedIdentities: [PaintTileIdentity],
        residency: PaintTileResidency
    ) throws {
        let requested = Set(requestedIdentities)
        let requestedBytes = try checkedMultiply(
            requested.count,
            PaintTileDescriptor.residentByteCount
        )
        var independentlyPinned = 0
        for (identity, entry) in residency.entries
        where entry.isPinned && !requested.contains(identity) {
            let (next, overflow) = independentlyPinned.addingReportingOverflow(
                entry.byteCount
            )
            guard !overflow else {
                throw PaintTileResidencyError.residentByteCountOverflow
            }
            independentlyPinned = next
        }
        let (required, overflow) = independentlyPinned.addingReportingOverflow(
            requestedBytes
        )
        guard !overflow else {
            throw PaintTileResidencyError.residentByteCountOverflow
        }
        guard required <= residency.byteBudget else {
            throw PaintTileResidencyError.insufficientCapacity(
                requestedBytes: requestedBytes,
                byteBudget: residency.byteBudget,
                pinnedBytes: independentlyPinned
            )
        }
    }

    private func transfer(
        evicted: [PaintTileIdentity],
        allocations: [Allocation]
    ) throws -> [PaintTileIdentity: PaintTileBackingSnapshot] {
        var captured: [PaintTileIdentity: PaintTileBackingSnapshot] = [:]
        var captureBuffers: [(PaintTileIdentity, any MTLBuffer)] = []
        for identity in evicted {
            guard let record = records.values.first(where: {
                $0.identity == identity
            }) else { continue }
            if let backing = record.backing {
                captured[identity] = backing
                continue
            }
            guard record.texture != nil else { continue }
            guard let buffer = device.makeBuffer(
                length: PaintTileDescriptor.residentByteCount,
                options: .storageModeShared
            ) else {
                throw PaintTileStoreError.stagingBufferAllocationFailed
            }
            captureBuffers.append((identity, buffer))
        }

        guard !captureBuffers.isEmpty || !allocations.isEmpty else {
            return captured
        }
        guard let queue = device.makeCommandQueue() else {
            throw PaintTileStoreError.commandQueueUnavailable
        }
        guard let command = queue.makeCommandBuffer() else {
            throw PaintTileStoreError.commandBufferUnavailable
        }
        guard let blit = command.makeBlitCommandEncoder() else {
            throw PaintTileStoreError.blitEncoderUnavailable
        }
        let rowBytes = PaintTileDescriptor.side * 8
        let imageBytes = PaintTileDescriptor.residentByteCount
        for (identity, buffer) in captureBuffers {
            guard let texture = records.values.first(where: {
                $0.identity == identity
            })?.texture else { continue }
            blit.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(
                    width: PaintTileDescriptor.side,
                    height: PaintTileDescriptor.side,
                    depth: 1
                ),
                to: buffer,
                destinationOffset: 0,
                destinationBytesPerRow: rowBytes,
                destinationBytesPerImage: imageBytes
            )
        }
        var sourceBuffers: [any MTLBuffer] = []
        sourceBuffers.reserveCapacity(allocations.count)
        for allocation in allocations {
            let data: Data
            switch allocation.sourceBacking {
            case let .rgba16Float(payload):
                guard payload.count == imageBytes else {
                    throw PaintTileStoreError.leaseBindingMismatch
                }
                data = payload
            case .knownClear, .residentOnly:
                data = Data(count: imageBytes)
            }
            let source: (any MTLBuffer)? = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return nil }
                return device.makeBuffer(
                    bytes: base,
                    length: data.count,
                    options: .storageModeShared
                )
            }
            guard let source else {
                throw PaintTileStoreError.stagingBufferAllocationFailed
            }
            sourceBuffers.append(source)
            blit.copy(
                from: source,
                sourceOffset: 0,
                sourceBytesPerRow: rowBytes,
                sourceBytesPerImage: imageBytes,
                sourceSize: MTLSize(
                    width: PaintTileDescriptor.side,
                    height: PaintTileDescriptor.side,
                    depth: 1
                ),
                to: allocation.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw PaintTileStoreError.gpuTransferFailed(
                command.error?.localizedDescription
                    ?? "Paint tile transfer did not complete."
            )
        }
        for (identity, buffer) in captureBuffers {
            captured[identity] = .rgba16Float(Data(
                bytes: buffer.contents(),
                count: imageBytes
            ))
        }
        _ = sourceBuffers
        return captured
    }

    private func advancedStateRevision() throws -> UInt64 {
        let (next, overflow) = stateRevision.addingReportingOverflow(1)
        guard !overflow else {
            throw PaintTileStoreError.stateRevisionOverflow
        }
        return next
    }

    private func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw PaintTileResidencyError.residentByteCountOverflow
        }
        return result
    }

    private static func backingByteCount(in records: [Key: Record]) -> Int {
        records.values.reduce(into: 0) {
            $0 += $1.backing?.byteCount ?? 0
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
