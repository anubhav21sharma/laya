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
    case transferCapacityExceeded(
        requiredBytes: Int,
        capacityBytes: Int,
        residentBytes: Int,
        allocationBytes: Int,
        stagingBytes: Int
    )
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

public enum PaintTilePayload: Equatable, Sendable {
    case knownClear
    case rgba16Float(Data)
}

public struct PaintTilePayloadEntry: Equatable, Sendable {
    public let identity: PaintTileIdentity
    public let descriptor: PaintTileDescriptor
    public let payload: PaintTilePayload
}

public struct PaintTilePayloadSnapshot: Equatable, Sendable {
    public let surfaceID: UUID
    public let layerID: UUID
    public let generation: UInt64
    public let storeStateRevision: UInt64
    public let entries: [PaintTilePayloadEntry]
    public let transferAccounting: PaintTileTransferAccounting
}

public struct PaintTileTransferAccounting: Equatable, Sendable {
    public let residentTextureBytesBefore: Int
    public let allocatedTextureBytes: Int
    public let uploadStagingBytes: Int
    public let readbackStagingBytes: Int
    public let capturedPayloadBytes: Int
    public let peakTrackedBytes: Int
    public let capacityBytes: Int

    public init(
        residentTextureBytesBefore: Int,
        allocatedTextureBytes: Int,
        uploadStagingBytes: Int,
        readbackStagingBytes: Int,
        capturedPayloadBytes: Int,
        peakTrackedBytes: Int,
        capacityBytes: Int
    ) {
        self.residentTextureBytesBefore = residentTextureBytesBefore
        self.allocatedTextureBytes = allocatedTextureBytes
        self.uploadStagingBytes = uploadStagingBytes
        self.readbackStagingBytes = readbackStagingBytes
        self.capturedPayloadBytes = capturedPayloadBytes
        self.peakTrackedBytes = peakTrackedBytes
        self.capacityBytes = capacityBytes
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
    public let lastTransferAccounting: PaintTileTransferAccounting?
}

public enum PaintTilePressureResult: Equatable, Sendable {
    case satisfied(
        evictedIdentities: [PaintTileIdentity],
        residentByteCount: Int,
        backingByteCount: Int
    )
    case unsatisfied(
        targetBytes: Int,
        remainingResidentBytes: Int,
        pinnedBytes: Int,
        backingByteCount: Int,
        evictedIdentities: [PaintTileIdentity]
    )

    public var evictedIdentities: [PaintTileIdentity] {
        switch self {
        case let .satisfied(identities, _, _): identities
        case let .unsatisfied(_, _, _, _, identities): identities
        }
    }

    public var residentByteCount: Int {
        switch self {
        case let .satisfied(_, bytes, _): bytes
        case let .unsatisfied(_, bytes, _, _, _): bytes
        }
    }

    public var backingByteCount: Int {
        switch self {
        case let .satisfied(_, _, bytes): bytes
        case let .unsatisfied(_, _, _, bytes, _): bytes
        }
    }
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
    public let transferByteCapacity: Int
    private let lock = NSLock()
    private var residency: PaintTileResidency
    private var records: [Key: Record] = [:]
    private var leases: [PaintTileLeaseID: LeaseRecord] = [:]
    private var nextTileID: UInt64 = 0
    private var nextLeaseID: UInt64 = 0
    private var stateRevision: UInt64 = 0
    private var lastTransferAccounting: PaintTileTransferAccounting?

    public convenience init(device: any MTLDevice, byteBudget: Int) {
        let (capacity, overflow) = byteBudget.multipliedReportingOverflow(by: 3)
        precondition(!overflow)
        self.init(
            device: device,
            byteBudget: byteBudget,
            transferByteCapacity: capacity
        )
    }

    public init(
        device: any MTLDevice,
        byteBudget: Int,
        transferByteCapacity: Int
    ) {
        precondition(byteBudget > 0)
        precondition(transferByteCapacity > 0)
        self.device = device
        self.transferByteCapacity = transferByteCapacity
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

    /// Cheap metadata snapshot. A `.residentOnly` entry deliberately omits
    /// private texture bytes; use `payloadSnapshot` for a restorable snapshot.
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
                leastRecentlyUsedOrder: residency.leastRecentlyUsedOrder,
                lastTransferAccounting: lastTransferAccounting
            )
        }
    }

    /// Payload-complete immutable snapshot. Unlike `snapshot()`, this API
    /// reads modified resident private textures so every entry is immediately
    /// restorable without first forcing memory-pressure eviction.
    public func payloadSnapshot(
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64
    ) throws -> PaintTilePayloadSnapshot {
        try withLock {
            let matching = records.filter { key, _ in
                key.surfaceID == surfaceID
                    && key.layerID == layerID
                    && key.generation == generation
            }
            .sorted { $0.value.identity < $1.value.identity }
            let identities = matching.map(\.value.identity)
            let accounting = try transferAccounting(
                captureIdentities: identities,
                allocationCount: 0
            )
            let captured = try transfer(
                evicted: identities,
                allocations: []
            )
            let entries = try matching.map { _, record in
                let backing = record.backing ?? captured[record.identity]
                let payload: PaintTilePayload
                switch backing {
                case .knownClear:
                    payload = .knownClear
                case let .rgba16Float(data):
                    payload = .rgba16Float(data)
                case .residentOnly, nil:
                    throw PaintTileStoreError.leaseBindingMismatch
                }
                return PaintTilePayloadEntry(
                    identity: record.identity,
                    descriptor: record.descriptor,
                    payload: payload
                )
            }
            return PaintTilePayloadSnapshot(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: generation,
                storeStateRevision: stateRevision,
                entries: entries,
                transferAccounting: accounting
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

            let allocationCount = requested.reduce(into: 0) {
                if records[$1.0]?.texture == nil { $0 += 1 }
            }
            let accounting = try transferAccounting(
                captureIdentities: evicted,
                allocationCount: allocationCount
            )

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
                    switch allocation.sourceBacking {
                    case .knownClear:
                        stagedRecords[allocation.key]?.backing = .knownClear
                    case .residentOnly, .rgba16Float:
                        // The private texture is authoritative again after the
                        // upload; retaining pixel bytes would double ownership.
                        stagedRecords[allocation.key]?.backing = nil
                    }
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
            lastTransferAccounting = accounting
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
            var stagedRecords = records
            for identity in leaseRecord.identities
            where !staged.isPinned(identity) {
                guard let key = stagedRecords.first(where: {
                    $0.value.identity == identity
                })?.key,
                stagedRecords[key]?.backing == .knownClear
                else { continue }
                stagedRecords.removeValue(forKey: key)
                staged.remove(identity)
            }
            residency = staged
            records = stagedRecords
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
            let remainingBytes = stagedResidency.residentByteCount
            let pinnedBytes = stagedResidency.pinnedByteCount
            var stagedRecords = records
            var accounting: PaintTileTransferAccounting?
            if !evicted.isEmpty {
                let measured = try transferAccounting(
                    captureIdentities: evicted,
                    allocationCount: 0
                )
                let captured = try transfer(
                    evicted: evicted,
                    allocations: []
                )
                for identity in evicted {
                    guard let key = stagedRecords.first(where: {
                        $0.value.identity == identity
                    })?.key else { continue }
                    stagedRecords[key]?.texture = nil
                    if let snapshot = captured[identity] {
                        stagedRecords[key]?.backing = snapshot
                    }
                }
                accounting = measured
                stateRevision = try advancedStateRevision()
            }
            records = stagedRecords
            residency = stagedResidency
            if let accounting { lastTransferAccounting = accounting }
            let backingBytes = Self.backingByteCount(in: stagedRecords)
            if remainingBytes > targetResidentBytes {
                return .unsatisfied(
                    targetBytes: targetResidentBytes,
                    remainingResidentBytes: remainingBytes,
                    pinnedBytes: pinnedBytes,
                    backingByteCount: backingBytes,
                    evictedIdentities: evicted
                )
            }
            return .satisfied(
                evictedIdentities: evicted,
                residentByteCount: remainingBytes,
                backingByteCount: backingBytes
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

    private func transferAccounting(
        captureIdentities: [PaintTileIdentity],
        allocationCount: Int
    ) throws -> PaintTileTransferAccounting {
        let captureCount = captureIdentities.reduce(into: 0) {
            count, identity in
            guard let record = records.values.first(where: {
                $0.identity == identity
            }), record.texture != nil, record.backing == nil
            else { return }
            count += 1
        }
        let allocatedBytes = try checkedMultiply(
            allocationCount,
            PaintTileDescriptor.residentByteCount
        )
        let uploadBytes = allocatedBytes
        let readbackBytes = try checkedMultiply(
            captureCount,
            PaintTileDescriptor.residentByteCount
        )
        let capturedBytes = readbackBytes
        let stagingBytes = try checkedSum([
            uploadBytes, readbackBytes, capturedBytes,
        ])
        let residentBytes = residency.residentByteCount
        let peakBytes = try checkedSum([
            residentBytes, allocatedBytes, stagingBytes,
        ])
        guard peakBytes <= transferByteCapacity else {
            throw PaintTileStoreError.transferCapacityExceeded(
                requiredBytes: peakBytes,
                capacityBytes: transferByteCapacity,
                residentBytes: residentBytes,
                allocationBytes: allocatedBytes,
                stagingBytes: stagingBytes
            )
        }
        return PaintTileTransferAccounting(
            residentTextureBytesBefore: residentBytes,
            allocatedTextureBytes: allocatedBytes,
            uploadStagingBytes: uploadBytes,
            readbackStagingBytes: readbackBytes,
            capturedPayloadBytes: capturedBytes,
            peakTrackedBytes: peakBytes,
            capacityBytes: transferByteCapacity
        )
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
            let source: (any MTLBuffer)?
            switch allocation.sourceBacking {
            case let .rgba16Float(payload):
                guard payload.count == imageBytes else {
                    throw PaintTileStoreError.leaseBindingMismatch
                }
                source = payload.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return nil }
                    return device.makeBuffer(
                        bytes: base,
                        length: payload.count,
                        options: .storageModeShared
                    )
                }
            case .knownClear, .residentOnly:
                source = device.makeBuffer(
                    length: imageBytes,
                    options: .storageModeShared
                )
                source?.contents().initializeMemory(
                    as: UInt8.self,
                    repeating: 0,
                    count: imageBytes
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

    private func checkedSum(_ values: [Int]) throws -> Int {
        var result = 0
        for value in values {
            let (next, overflow) = result.addingReportingOverflow(value)
            guard !overflow else {
                throw PaintTileResidencyError.residentByteCountOverflow
            }
            result = next
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
