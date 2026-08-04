import Foundation
import Metal
import PatternEngine

public enum PaintTileStoreError: Error, Equatable, Sendable {
    case emptyPinReasons
    case duplicateCoordinate(PaintTileCoordinate)
    case unsortedCoordinate(
        previous: PaintTileCoordinate,
        current: PaintTileCoordinate
    )
    case unsortedPinReason(
        previous: PaintTilePinReason,
        current: PaintTilePinReason
    )
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
    case provisionalReservationCapacityExceeded(maximum: Int)
    case invalidProvisionalReservation
    case provisionalReservationIDOverflow
    case outstandingProvisionalReservations(
        surfaceID: UUID,
        generation: UInt64,
        count: Int
    )
    case outstandingLeases(surfaceID: UUID, generation: UInt64, count: Int)
    case transferCapacityExceeded(
        requiredBytes: Int,
        capacityBytes: Int,
        residentBytes: Int,
        allocationBytes: Int,
        stagingBytes: Int
    )
    case foreignStoreReference
    case unsortedReference
    case duplicateReference
    case staleTileReference
    case retirementAlreadyPrepared
    case retirementIdentityOverflow
}

/// Opaque ownership identity for one physical tile store. References and
/// leases carry this value so no caller can accidentally mix stores that use
/// otherwise-identical surface/layer/generation coordinates.
public struct PaintTileStoreIdentity: Hashable, Comparable, Sendable {
    fileprivate let rawValue: UUID

    init() { rawValue = UUID() }

    public static func < (
        lhs: PaintTileStoreIdentity,
        rhs: PaintTileStoreIdentity
    ) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

/// Immutable metadata-only pointer to one exact physical tile entry.
public struct PaintTileReference: Hashable, Comparable, Sendable {
    public let storeIdentity: PaintTileStoreIdentity
    public let physicalSurfaceID: UUID
    public let layerID: UUID
    public let physicalGeneration: UInt64
    public let identity: PaintTileIdentity
    public let descriptor: PaintTileDescriptor

    public var coordinate: PaintTileCoordinate { descriptor.coordinate }

    public static func < (
        lhs: PaintTileReference,
        rhs: PaintTileReference
    ) -> Bool {
        if lhs.coordinate != rhs.coordinate {
            return lhs.coordinate < rhs.coordinate
        }
        if lhs.layerID != rhs.layerID {
            return lhs.layerID.uuidString < rhs.layerID.uuidString
        }
        if lhs.physicalSurfaceID != rhs.physicalSurfaceID {
            return lhs.physicalSurfaceID.uuidString
                < rhs.physicalSurfaceID.uuidString
        }
        if lhs.physicalGeneration != rhs.physicalGeneration {
            return lhs.physicalGeneration < rhs.physicalGeneration
        }
        if lhs.identity != rhs.identity { return lhs.identity < rhs.identity }
        return lhs.storeIdentity < rhs.storeIdentity
    }

    func replacing(
        identity: PaintTileIdentity
    ) -> PaintTileReference {
        PaintTileReference(
            storeIdentity: storeIdentity,
            physicalSurfaceID: physicalSurfaceID,
            layerID: layerID,
            physicalGeneration: physicalGeneration,
            identity: identity,
            descriptor: descriptor
        )
    }
}

/// Opaque single-use retirement transaction prepared under the store lock.
public final class PaintTilePreparedRetirement: @unchecked Sendable {
    fileprivate let storeIdentity: PaintTileStoreIdentity
    fileprivate let token: UInt64

    fileprivate init(storeIdentity: PaintTileStoreIdentity, token: UInt64) {
        self.storeIdentity = storeIdentity
        self.token = token
    }
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

/// Reusable storage for the single outstanding stroke-frame lease. The
/// ordinary public reserve API continues to return self-contained value
/// arrays; the stroke encoder borrows this workspace only while its existing
/// one-frame backpressure invariant is active.
final class PaintTileStrokeLeaseWorkspace: @unchecked Sendable {
    let maximumBindingCount: Int
    fileprivate var bindings: [PaintTileBinding] = []
    fileprivate var identities: [PaintTileIdentity] = []
    fileprivate var isOutstanding = false
    var retainedBindingCount: Int { bindings.count }

    init(maximumBindingCount: Int) {
        precondition(maximumBindingCount > 0)
        self.maximumBindingCount = maximumBindingCount
        bindings.reserveCapacity(maximumBindingCount)
        identities.reserveCapacity(maximumBindingCount)
    }

    fileprivate func prepareForReservation() throws {
        guard !isOutstanding else {
            throw PaintTileStoreError.leaseBindingMismatch
        }
        bindings.removeAll(keepingCapacity: true)
        identities.removeAll(keepingCapacity: true)
    }

    func abandonReservation() {
        bindings.removeAll(keepingCapacity: true)
        identities.removeAll(keepingCapacity: true)
        isOutstanding = false
    }

    fileprivate func completeReturn() {
        precondition(isOutstanding)
        bindings.removeAll(keepingCapacity: true)
        identities.removeAll(keepingCapacity: true)
        isOutstanding = false
    }

    fileprivate func installCommittedCandidates(
        from provisional: PaintTileProvisionalReservation
    ) {
        precondition(isOutstanding && bindings.count == provisional.count)
        for index in 0..<provisional.count {
            let candidate = provisional[index]
            precondition(bindings[index].identity == candidate.identity)
            bindings[index] = PaintTileBinding(
                identity: candidate.identity,
                descriptor: candidate.descriptor,
                texture: candidate.candidateTexture
            )
        }
    }
}

struct PaintTileProvisionalBinding: @unchecked Sendable {
    let identity: PaintTileIdentity
    let descriptor: PaintTileDescriptor
    let sourceTexture: any MTLTexture
    let candidateTexture: any MTLTexture
    let sourceIsKnownClear: Bool
}

final class PaintTileProvisionalWorkspace: @unchecked Sendable {
    let maximumBindingCount: Int
    fileprivate var bindings: [PaintTileProvisionalBinding?]
    fileprivate var count = 0
    fileprivate var isOutstanding = false
    var retainedBindingCount: Int { count }

    init(maximumBindingCount: Int) {
        precondition(maximumBindingCount > 0)
        self.maximumBindingCount = maximumBindingCount
        bindings = Array(repeating: nil, count: maximumBindingCount)
    }

    fileprivate func prepare(count: Int) throws {
        guard !isOutstanding, count <= maximumBindingCount else {
            throw PaintTileStoreError.leaseBindingMismatch
        }
        clear()
        self.count = count
        isOutstanding = true
    }

    fileprivate func install(
        _ binding: PaintTileProvisionalBinding,
        at index: Int
    ) {
        precondition(isOutstanding && index >= 0 && index < count)
        bindings[index] = binding
    }

    func clear() {
        for index in 0..<count { bindings[index] = nil }
        count = 0
        isOutstanding = false
    }
}

final class PaintTileProvisionalReservation: @unchecked Sendable {
    fileprivate let owner: ObjectIdentifier
    fileprivate let slotIndex: Int
    fileprivate let token: UInt64
    fileprivate let reservedBytes: Int
    fileprivate let workspace: PaintTileProvisionalWorkspace
    private(set) var isReserved = true
    private(set) var isCommitted = false

    fileprivate init(
        owner: ObjectIdentifier,
        slotIndex: Int,
        token: UInt64,
        reservedBytes: Int,
        workspace: PaintTileProvisionalWorkspace
    ) {
        self.owner = owner
        self.slotIndex = slotIndex
        self.token = token
        self.reservedBytes = reservedBytes
        self.workspace = workspace
    }

    var count: Int { workspace.count }

    subscript(index: Int) -> PaintTileProvisionalBinding {
        guard index >= 0, index < workspace.count,
              let binding = workspace.bindings[index]
        else { preconditionFailure("Invalid provisional binding index") }
        return binding
    }

    func forEach(
        _ body: (PaintTileProvisionalBinding) throws -> Void
    ) rethrows {
        for index in 0..<workspace.count { try body(self[index]) }
    }

    fileprivate func markCommitted() {
        precondition(isReserved && !isCommitted)
        isCommitted = true
    }

    fileprivate func markCompleted() {
        precondition(isReserved && isCommitted)
        isReserved = false
    }

    fileprivate func markCancelled() {
        precondition(isReserved && !isCommitted)
        isReserved = false
    }
}

public struct PaintTileLease: @unchecked Sendable {
    public let id: PaintTileLeaseID
    public let surfaceID: UUID
    public let layerID: UUID
    public let generation: UInt64
    public let storeIdentity: PaintTileStoreIdentity
    private let ownedPinReasons: [PaintTilePinReason]
    private let ownedBindings: [PaintTileBinding]
    fileprivate let strokeWorkspace: PaintTileStrokeLeaseWorkspace?

    public var pinReasons: [PaintTilePinReason] { ownedPinReasons }
    public var bindings: [PaintTileBinding] {
        strokeWorkspace?.bindings ?? ownedBindings
    }

    init(
        id: PaintTileLeaseID,
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64,
        storeIdentity: PaintTileStoreIdentity,
        pinReasons: [PaintTilePinReason],
        bindings: [PaintTileBinding]
    ) {
        self.id = id
        self.surfaceID = surfaceID
        self.layerID = layerID
        self.generation = generation
        self.storeIdentity = storeIdentity
        ownedPinReasons = pinReasons
        ownedBindings = bindings
        strokeWorkspace = nil
    }

    fileprivate init(
        id: PaintTileLeaseID,
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64,
        storeIdentity: PaintTileStoreIdentity,
        pinReasons: [PaintTilePinReason],
        strokeWorkspace: PaintTileStrokeLeaseWorkspace
    ) {
        self.id = id
        self.surfaceID = surfaceID
        self.layerID = layerID
        self.generation = generation
        self.storeIdentity = storeIdentity
        ownedPinReasons = pinReasons
        ownedBindings = []
        self.strokeWorkspace = strokeWorkspace
    }

    fileprivate var retainedBindingCount: Int {
        strokeWorkspace?.retainedBindingCount ?? ownedBindings.count
    }

    fileprivate func installingCommittedCandidates(
        from provisional: PaintTileProvisionalReservation
    ) -> PaintTileLease {
        precondition(retainedBindingCount == provisional.count)
        if let strokeWorkspace {
            strokeWorkspace.installCommittedCandidates(from: provisional)
            return self
        }
        var committedBindings = ownedBindings
        for index in 0..<provisional.count {
            let candidate = provisional[index]
            precondition(committedBindings[index].identity == candidate.identity)
            committedBindings[index] = PaintTileBinding(
                identity: candidate.identity,
                descriptor: candidate.descriptor,
                texture: candidate.candidateTexture
            )
        }
        return PaintTileLease(
            id: id,
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            storeIdentity: storeIdentity,
            pinReasons: pinReasons,
            bindings: committedBindings
        )
    }
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
    public let provisionalReservationCount: Int
    public let provisionalByteCount: Int
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
    private struct ProvisionalReservationRecord {
        let token: UInt64
        let byteCount: Int
        let surfaceID: UUID
        let generation: UInt64
    }

    private static let maximumProvisionalReservationCount = 64
    private struct Key: Hashable {
        let surfaceID: UUID
        let layerID: UUID
        let generation: UInt64
        let coordinate: PaintTileCoordinate
    }

    private final class RecordStorage {
        var texture: (any MTLTexture)?
        var backing: PaintTileBackingSnapshot?
        var isStrokeActive: Bool

        init(
            texture: (any MTLTexture)?,
            backing: PaintTileBackingSnapshot?,
            isStrokeActive: Bool = false
        ) {
            self.texture = texture
            self.backing = backing
            self.isStrokeActive = isStrokeActive
        }
    }

    private struct Record {
        let identity: PaintTileIdentity
        let descriptor: PaintTileDescriptor
        let storage: RecordStorage

        var texture: (any MTLTexture)? { storage.texture }
        var backing: PaintTileBackingSnapshot? { storage.backing }

        init(
            identity: PaintTileIdentity,
            descriptor: PaintTileDescriptor,
            texture: (any MTLTexture)?,
            backing: PaintTileBackingSnapshot?,
            isStrokeActive: Bool = false
        ) {
            self.identity = identity
            self.descriptor = descriptor
            storage = RecordStorage(
                texture: texture,
                backing: backing,
                isStrokeActive: isStrokeActive
            )
        }

        func cloned() -> Record {
            Record(
                identity: identity,
                descriptor: descriptor,
                texture: texture,
                backing: backing,
                isStrokeActive: storage.isStrokeActive
            )
        }
    }

    private enum LeaseIdentityStorage {
        case owned([PaintTileIdentity])
        case strokeWorkspace(PaintTileStrokeLeaseWorkspace)

        var count: Int {
            switch self {
            case let .owned(identities): identities.count
            case let .strokeWorkspace(workspace): workspace.identities.count
            }
        }

        func forEach(_ body: (PaintTileIdentity) throws -> Void) rethrows {
            switch self {
            case let .owned(identities):
                for identity in identities { try body(identity) }
            case let .strokeWorkspace(workspace):
                for identity in workspace.identities { try body(identity) }
            }
        }

        func elementsEqual(_ bindings: [PaintTileBinding]) -> Bool {
            guard count == bindings.count else { return false }
            switch self {
            case let .owned(identities):
                return zip(identities, bindings).allSatisfy {
                    $0 == $1.identity
                }
            case let .strokeWorkspace(workspace):
                return zip(workspace.identities, bindings).allSatisfy {
                    $0 == $1.identity
                }
            }
        }

        func markReturned() {
            if case let .strokeWorkspace(workspace) = self {
                workspace.completeReturn()
            }
        }
    }

    private struct LeaseRecord {
        let surfaceID: UUID
        let generation: UInt64
        let identityStorage: LeaseIdentityStorage
        /// Present only for immutable leases spanning physical namespaces.
        /// Single-namespace hot leases derive keys without allocating.
        let mixedNamespaceKeys: [Key]?
        let pinReasons: [PaintTilePinReason]

        func referencesPhysicalNamespace(
            surfaceID: UUID,
            generation: UInt64
        ) -> Bool {
            if let mixedNamespaceKeys {
                return mixedNamespaceKeys.contains {
                    $0.surfaceID == surfaceID && $0.generation == generation
                }
            }
            return self.surfaceID == surfaceID && self.generation == generation
        }
    }

    private enum PreparedRetirementState {
        case prepared([Key])
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
    public let identity = PaintTileStoreIdentity()
    public let transferByteCapacity: Int
    private let lock = NSLock()
    private var residency: PaintTileResidency
    private var records: [Key: Record] = [:]
    private var leases: [PaintTileLeaseID: LeaseRecord] = [:]
    private var nextTileID: UInt64 = 0
    private var nextLeaseID: UInt64 = 0
    private var stateRevision: UInt64 = 0
    private var lastTransferAccounting: PaintTileTransferAccounting?
    private var provisionalReservations:
        [ProvisionalReservationRecord?] = Array(
            repeating: nil,
            count: maximumProvisionalReservationCount
        )
    private var provisionalByteCount = 0
    private var nextProvisionalReservationID: UInt64 = 0
    private var nextRetirementID: UInt64 = 0
    private var preparedRetirements: [UInt64: PreparedRetirementState] = [:]
    private var preparedRetirementKeys: Set<Key> = []
    private var pendingRetirementKeys: Set<Key> = []
    private let provisionalTextureDescriptor: MTLTextureDescriptor

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
        provisionalTextureDescriptor = MTLTextureDescriptor
            .texture2DDescriptor(
                pixelFormat: PaintTileDescriptor.pixelFormat,
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side,
                mipmapped: false
            )
        provisionalTextureDescriptor.storageMode = .private
        provisionalTextureDescriptor.usage = [
            .renderTarget, .shaderRead, .shaderWrite,
        ]
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

    /// Returns metadata-only references to the exact physical entries in one
    /// namespace. The returned order is stable row-major coordinate order.
    public func references(
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64
    ) throws -> [PaintTileReference] {
        withLock {
            records.compactMap { key, record -> PaintTileReference? in
                guard key.surfaceID == surfaceID,
                      key.layerID == layerID,
                      key.generation == generation
                else { return nil }
                return reference(key: key, record: record)
            }
            .sorted()
        }
    }

    /// Resolves metadata for an exact, sorted reference set under one store
    /// lock. A physical coordinate that was retired and later reused never
    /// aliases the stale reference because tile identity is revalidated.
    public func snapshot(
        exactReferences references: [PaintTileReference]
    ) throws -> [PaintTileStoreEntrySnapshot] {
        try withLock {
            var result: [PaintTileStoreEntrySnapshot] = []
            result.reserveCapacity(references.count)
            for index in references.indices {
                let value = references[index]
                guard value.storeIdentity == identity else {
                    throw PaintTileStoreError.foreignStoreReference
                }
                if index > references.startIndex {
                    if references[index - 1] == value {
                        throw PaintTileStoreError.duplicateReference
                    }
                    guard references[index - 1] < value else {
                        throw PaintTileStoreError.unsortedReference
                    }
                }
                let key = Key(
                    surfaceID: value.physicalSurfaceID,
                    layerID: value.layerID,
                    generation: value.physicalGeneration,
                    coordinate: value.coordinate
                )
                guard let record = records[key],
                      reference(key: key, record: record) == value
                else { throw PaintTileStoreError.staleTileReference }
                result.append(entrySnapshot(key: key, record: record))
            }
            return result
        }
    }

    /// Atomically pins exact entries that may belong to different physical
    /// surface namespaces. No entry is created and every reference is
    /// validated before residency or lease bookkeeping changes.
    public func reserveReferences(
        _ references: [PaintTileReference],
        leaseSurfaceID: UUID,
        leaseLayerID: UUID,
        leaseGeneration: UInt64,
        pinReasons: [PaintTilePinReason]
    ) throws -> PaintTileLease {
        guard !pinReasons.isEmpty else {
            throw PaintTileStoreError.emptyPinReasons
        }
        for index in pinReasons.indices.dropFirst() {
            guard pinReasons[index - 1] < pinReasons[index] else {
                throw PaintTileStoreError.unsortedPinReason(
                    previous: pinReasons[index - 1],
                    current: pinReasons[index]
                )
            }
        }
        for index in references.indices {
            guard references[index].storeIdentity == identity else {
                throw PaintTileStoreError.foreignStoreReference
            }
            if index > references.startIndex {
                let previous = references[index - 1]
                let current = references[index]
                if previous == current {
                    throw PaintTileStoreError.duplicateReference
                }
                guard previous < current else {
                    throw PaintTileStoreError.unsortedReference
                }
            }
        }

        return try withLock {
            let requested: [(Key, Record)] = try references.map { reference in
                let key = Key(
                    surfaceID: reference.physicalSurfaceID,
                    layerID: reference.layerID,
                    generation: reference.physicalGeneration,
                    coordinate: reference.coordinate
                )
                guard !pendingRetirementKeys.contains(key),
                      !preparedRetirementKeys.contains(key),
                      let record = records[key],
                      self.reference(key: key, record: record) == reference
                else {
                    throw PaintTileStoreError.staleTileReference
                }
                return (key, record)
            }
            var stagedResidency = residency
            let identities = requested.map { $0.1.identity }
            try preflightCapacity(
                requestedIdentities: identities,
                residency: stagedResidency
            )

            var evicted: [PaintTileIdentity] = []
            for identity in identities
            where stagedResidency.entries[identity] != nil {
                evicted.append(contentsOf: try stagedResidency.admit(
                    identity,
                    byteCount: PaintTileDescriptor.residentByteCount,
                    pinReasons: pinReasons
                ))
            }
            for identity in identities
            where stagedResidency.entries[identity] == nil {
                evicted.append(contentsOf: try stagedResidency.admit(
                    identity,
                    byteCount: PaintTileDescriptor.residentByteCount,
                    pinReasons: pinReasons
                ))
            }
            var uniqueEvictions: [PaintTileIdentity] = []
            for value in evicted where !uniqueEvictions.contains(value) {
                uniqueEvictions.append(value)
            }
            evicted = uniqueEvictions

            let allocationCount = requested.reduce(into: 0) {
                if $1.1.texture == nil { $0 += 1 }
            }
            let accounting = try transferAccounting(
                captureIdentities: evicted,
                allocationCount: allocationCount
            )
            var allocations: [Allocation] = []
            allocations.reserveCapacity(allocationCount)
            for (key, record) in requested where record.texture == nil {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: PaintTileDescriptor.pixelFormat,
                    width: PaintTileDescriptor.side,
                    height: PaintTileDescriptor.side,
                    mipmapped: false
                )
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw PaintTileStoreError.textureAllocationFailed(
                        reserveIndex: allocations.count
                    )
                }
                texture.label = "Paint Tile \(record.identity.tileID.rawValue)"
                allocations.append(Allocation(
                    key: key,
                    identity: record.identity,
                    descriptor: record.descriptor,
                    texture: texture,
                    sourceBacking: record.backing ?? .knownClear,
                    isNew: false
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
            let nextRevision = try advancedStateRevision()
            let stagedRecords = Self.cloneRecords(records)
            for evictedIdentity in evicted {
                guard let key = stagedRecords.first(where: {
                    $0.value.identity == evictedIdentity
                })?.key else { continue }
                stagedRecords[key]?.storage.texture = nil
                if let payload = captured[evictedIdentity] {
                    stagedRecords[key]?.storage.backing = payload
                }
            }
            for allocation in allocations {
                stagedRecords[allocation.key]?.storage.texture = allocation.texture
                switch allocation.sourceBacking {
                case .knownClear:
                    stagedRecords[allocation.key]?.storage.backing = .knownClear
                case .residentOnly, .rgba16Float:
                    stagedRecords[allocation.key]?.storage.backing = nil
                }
            }
            let bindings = requested.compactMap { key, record in
                stagedRecords[key]?.texture.map {
                    PaintTileBinding(
                        identity: record.identity,
                        descriptor: record.descriptor,
                        texture: $0
                    )
                }
            }
            guard bindings.count == requested.count else {
                throw PaintTileStoreError.leaseBindingMismatch
            }
            let leaseID = PaintTileLeaseID(rawValue: leaseRawID)
            var stagedLeases = leases
            stagedLeases[leaseID] = LeaseRecord(
                surfaceID: leaseSurfaceID,
                generation: leaseGeneration,
                identityStorage: .owned(identities),
                mixedNamespaceKeys: requested.map(\.0),
                pinReasons: pinReasons
            )
            records = stagedRecords
            residency = stagedResidency
            leases = stagedLeases
            nextLeaseID = leaseRawID
            stateRevision = nextRevision
            lastTransferAccounting = accounting
            return PaintTileLease(
                id: leaseID,
                surfaceID: leaseSurfaceID,
                layerID: leaseLayerID,
                generation: leaseGeneration,
                storeIdentity: identity,
                pinReasons: pinReasons,
                bindings: bindings
            )
        }
    }

    /// Validates and reserves an exact set of entries for a later nonthrowing
    /// retirement request. Preparation prevents new leases from racing the
    /// candidate's final registry swap.
    public func prepareRetirement(
        _ references: [PaintTileReference]
    ) throws -> PaintTilePreparedRetirement {
        try withLock {
            var keys: [Key] = []
            keys.reserveCapacity(references.count)
            for index in references.indices {
                let value = references[index]
                guard value.storeIdentity == identity else {
                    throw PaintTileStoreError.foreignStoreReference
                }
                if index > references.startIndex {
                    if references[index - 1] == value {
                        throw PaintTileStoreError.duplicateReference
                    }
                    guard references[index - 1] < value else {
                        throw PaintTileStoreError.unsortedReference
                    }
                }
                let key = Key(
                    surfaceID: value.physicalSurfaceID,
                    layerID: value.layerID,
                    generation: value.physicalGeneration,
                    coordinate: value.coordinate
                )
                guard !preparedRetirementKeys.contains(key),
                      !pendingRetirementKeys.contains(key)
                else { throw PaintTileStoreError.retirementAlreadyPrepared }
                guard let record = records[key],
                      reference(key: key, record: record) == value
                else { throw PaintTileStoreError.staleTileReference }
                keys.append(key)
            }
            let (token, overflow) = nextRetirementID.addingReportingOverflow(1)
            guard !overflow else {
                throw PaintTileStoreError.retirementIdentityOverflow
            }
            let nextRevision = try advancedStateRevision()
            nextRetirementID = token
            preparedRetirements[token] = .prepared(keys)
            preparedRetirementKeys.formUnion(keys)
            stateRevision = nextRevision
            return PaintTilePreparedRetirement(
                storeIdentity: identity,
                token: token
            )
        }
    }

    /// Commits a prepared retirement without any remaining fallible work.
    /// Unpinned entries disappear immediately; pinned entries are deleted by
    /// the final balanced lease return.
    public func requestRetirement(_ plan: PaintTilePreparedRetirement) {
        guard plan.storeIdentity == identity else { return }
        withLock {
            guard case let .prepared(keys)? = preparedRetirements[plan.token]
            else { return }
            for key in keys {
                preparedRetirementKeys.remove(key)
                if let record = records[key], residency.isPinned(record.identity) {
                    pendingRetirementKeys.insert(key)
                } else {
                    removeRecord(for: key)
                }
            }
            preparedRetirements.removeValue(forKey: plan.token)
        }
    }

    public func cancelRetirement(_ plan: PaintTilePreparedRetirement) {
        guard plan.storeIdentity == identity else { return }
        withLock {
            guard case let .prepared(keys)? = preparedRetirements[plan.token]
            else { return }
            for key in keys { preparedRetirementKeys.remove(key) }
            preparedRetirements.removeValue(forKey: plan.token)
        }
    }

    public func isRetirementPending(_ reference: PaintTileReference) -> Bool {
        guard reference.storeIdentity == identity else { return false }
        return withLock {
            pendingRetirementKeys.contains(Key(
                surfaceID: reference.physicalSurfaceID,
                layerID: reference.layerID,
                generation: reference.physicalGeneration,
                coordinate: reference.coordinate
            ))
        }
    }

    /// Cheap metadata snapshot. A `.residentOnly` entry deliberately omits
    /// private texture bytes; use `payloadSnapshot` for a restorable snapshot.
    public func snapshot() -> PaintTileStoreSnapshot {
        withLock {
            let entrySnapshots = records.map { key, record in
                entrySnapshot(key: key, record: record)
            }
            .sorted { $0.identity < $1.identity }
            return PaintTileStoreSnapshot(
                stateRevision: stateRevision,
                nextTileID: nextTileID,
                nextLeaseID: nextLeaseID,
                residentByteCount: residency.residentByteCount,
                backingByteCount: Self.backingByteCount(in: records),
                activeLeaseCount: leases.count,
                provisionalReservationCount:
                    provisionalReservations.reduce(into: 0) {
                        if $1 != nil { $0 += 1 }
                    },
                provisionalByteCount: provisionalByteCount,
                entries: entrySnapshots,
                leastRecentlyUsedOrder: residency.leastRecentlyUsedOrder,
                lastTransferAccounting: lastTransferAccounting
            )
        }
    }

    private func entrySnapshot(
        key: Key,
        record: Record
    ) -> PaintTileStoreEntrySnapshot {
        let entry = residency.entries[record.identity]
        return PaintTileStoreEntrySnapshot(
            surfaceID: key.surfaceID,
            generation: key.generation,
            identity: record.identity,
            descriptor: record.descriptor,
            isResident: record.texture != nil,
            backing: record.backing ?? .residentOnly,
            lastUseEpoch: entry?.lastUseEpoch,
            pinCounts: entry?.pinCounts.dictionary ?? [:]
        )
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
        let sortedCoordinates = coordinates.sorted()
        let sortedPinReasons = Array(Set(pinReasons)).sorted()
        for index in sortedCoordinates.indices.dropFirst() {
            if sortedCoordinates[index] == sortedCoordinates[index - 1] {
                throw PaintTileStoreError.duplicateCoordinate(
                    sortedCoordinates[index]
                )
            }
        }
        return try reserveSortedUnique(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            pixelSize: pixelSize,
            coordinates: sortedCoordinates,
            pinReasons: sortedPinReasons,
            failureInjection: failureInjection
        )
    }

    /// Allocation-stable caller path. Coordinates must already be unique and
    /// row-major; this entry point never creates a sorted copy.
    public func reserveSortedUnique(
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64,
        pixelSize: PixelSize,
        coordinates: [PaintTileCoordinate],
        pinReasons: [PaintTilePinReason],
        failureInjection: PaintTileAllocationFailureInjection? = nil
    ) throws -> PaintTileLease {
        guard !pinReasons.isEmpty else {
            throw PaintTileStoreError.emptyPinReasons
        }
        for index in pinReasons.indices.dropFirst() {
            let previous = pinReasons[index - 1]
            let current = pinReasons[index]
            guard previous < current else {
                throw PaintTileStoreError.unsortedPinReason(
                    previous: previous,
                    current: current
                )
            }
        }
        for index in coordinates.indices.dropFirst() {
            let previous = coordinates[index - 1]
            let current = coordinates[index]
            if current == previous {
                throw PaintTileStoreError.duplicateCoordinate(current)
            }
            guard previous < current else {
                throw PaintTileStoreError.unsortedCoordinate(
                    previous: previous,
                    current: current
                )
            }
        }
        let sortedCoordinates = coordinates
        if let existing = try withLock({
            try reserveExistingResidentTiles(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: generation,
                coordinates: sortedCoordinates,
                pinReasons: pinReasons
            )
        }) {
            return existing
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
            guard !keys.contains(where: {
                preparedRetirementKeys.contains($0)
                    || pendingRetirementKeys.contains($0)
            }) else {
                throw PaintTileStoreError.staleTileReference
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
                    pinReasons: pinReasons
                ))
            }
            for (_, identity, _) in requested
            where stagedResidency.entries[identity] == nil {
                evicted.append(contentsOf: try stagedResidency.admit(
                    identity,
                    byteCount: PaintTileDescriptor.residentByteCount,
                    pinReasons: pinReasons
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

            var stagedRecords = Self.cloneRecords(records)
            for identity in evicted {
                guard let key = stagedRecords.first(where: {
                    $0.value.identity == identity
                })?.key else { continue }
                stagedRecords[key]?.storage.texture = nil
                if let snapshot = captured[identity] {
                    stagedRecords[key]?.storage.backing = snapshot
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
                    stagedRecords[allocation.key]?.storage.texture = allocation.texture
                    switch allocation.sourceBacking {
                    case .knownClear:
                        stagedRecords[allocation.key]?.storage.backing = .knownClear
                    case .residentOnly, .rgba16Float:
                        // The private texture is authoritative again after the
                        // upload; retaining pixel bytes would double ownership.
                        stagedRecords[allocation.key]?.storage.backing = nil
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
                identityStorage: .owned(requested.map(\.1)),
                mixedNamespaceKeys: nil,
                pinReasons: pinReasons
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
                storeIdentity: identity,
                pinReasons: pinReasons,
                bindings: bindings
            )
        }
    }

    /// Stroke-only warmed reservation. The workspace remains borrowed until
    /// the returned lease is released, which matches the scheduler's existing
    /// single-outstanding-frame backpressure. A cold/missing-tile request falls
    /// back to the ordinary transactional reserve path.
    func reserveSortedUniqueForStroke(
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64,
        pixelSize: PixelSize,
        coordinates: [PaintTileCoordinate],
        pinReasons: [PaintTilePinReason],
        workspace: PaintTileStrokeLeaseWorkspace,
        failureInjection: PaintTileAllocationFailureInjection? = nil
    ) throws -> PaintTileLease {
        guard coordinates.count <= workspace.maximumBindingCount else {
            throw PaintTileStoreError.leaseBindingMismatch
        }
        guard !pinReasons.isEmpty else {
            throw PaintTileStoreError.emptyPinReasons
        }
        for index in pinReasons.indices.dropFirst() {
            let previous = pinReasons[index - 1]
            let current = pinReasons[index]
            guard previous < current else {
                throw PaintTileStoreError.unsortedPinReason(
                    previous: previous,
                    current: current
                )
            }
        }
        for index in coordinates.indices.dropFirst() {
            let previous = coordinates[index - 1]
            let current = coordinates[index]
            if current == previous {
                throw PaintTileStoreError.duplicateCoordinate(current)
            }
            guard previous < current else {
                throw PaintTileStoreError.unsortedCoordinate(
                    previous: previous,
                    current: current
                )
            }
        }
        if let existing = try withLock({
            try reserveExistingResidentTiles(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: generation,
                coordinates: coordinates,
                pinReasons: pinReasons,
                workspace: workspace
            )
        }) {
            return existing
        }
        workspace.abandonReservation()
        return try reserveSortedUnique(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            pixelSize: pixelSize,
            coordinates: coordinates,
            pinReasons: pinReasons,
            failureInjection: failureInjection
        )
    }

    /// Hot path for a warmed stroke footprint. Every requested record and
    /// texture is validated and both immutable lease arrays are built before
    /// residency or lease dictionaries mutate.
    private func reserveExistingResidentTiles(
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64,
        coordinates: [PaintTileCoordinate],
        pinReasons: [PaintTilePinReason]
    ) throws -> PaintTileLease? {
        guard !coordinates.isEmpty else { return nil }
        var bindings: [PaintTileBinding] = []
        var identities: [PaintTileIdentity] = []
        bindings.reserveCapacity(coordinates.count)
        identities.reserveCapacity(coordinates.count)
        for coordinate in coordinates {
            let key = Key(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: generation,
                coordinate: coordinate
            )
            if preparedRetirementKeys.contains(key)
                || pendingRetirementKeys.contains(key) {
                throw PaintTileStoreError.staleTileReference
            }
            guard let record = records[key], let texture = record.texture else {
                return nil
            }
            identities.append(record.identity)
            bindings.append(PaintTileBinding(
                identity: record.identity,
                descriptor: record.descriptor,
                texture: texture
            ))
        }
        let (leaseRawID, leaseOverflow) = nextLeaseID
            .addingReportingOverflow(1)
        guard !leaseOverflow else {
            throw PaintTileStoreError.leaseIdentityOverflow
        }
        try residency.preflightPinExisting(identities, reasons: pinReasons)
        let nextRevision = try advancedStateRevision()
        for identity in identities {
            residency.pinExistingPreflighted(identity, reasons: pinReasons)
        }
        let leaseID = PaintTileLeaseID(rawValue: leaseRawID)
        leases[leaseID] = LeaseRecord(
            surfaceID: surfaceID,
            generation: generation,
            identityStorage: .owned(identities),
            mixedNamespaceKeys: nil,
            pinReasons: pinReasons
        )
        nextLeaseID = leaseRawID
        stateRevision = nextRevision
        return PaintTileLease(
            id: leaseID,
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            storeIdentity: identity,
            pinReasons: pinReasons,
            bindings: bindings
        )
    }

    private func reserveExistingResidentTiles(
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64,
        coordinates: [PaintTileCoordinate],
        pinReasons: [PaintTilePinReason],
        workspace: PaintTileStrokeLeaseWorkspace
    ) throws -> PaintTileLease? {
        guard !coordinates.isEmpty else { return nil }
        try workspace.prepareForReservation()
        for coordinate in coordinates {
            let key = Key(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: generation,
                coordinate: coordinate
            )
            if preparedRetirementKeys.contains(key)
                || pendingRetirementKeys.contains(key) {
                workspace.abandonReservation()
                throw PaintTileStoreError.staleTileReference
            }
            guard let record = records[key], let texture = record.texture else {
                workspace.abandonReservation()
                return nil
            }
            workspace.identities.append(record.identity)
            workspace.bindings.append(PaintTileBinding(
                identity: record.identity,
                descriptor: record.descriptor,
                texture: texture
            ))
        }
        let (leaseRawID, leaseOverflow) = nextLeaseID
            .addingReportingOverflow(1)
        guard !leaseOverflow else {
            workspace.abandonReservation()
            throw PaintTileStoreError.leaseIdentityOverflow
        }
        do {
            try residency.preflightPinExisting(
                workspace.identities,
                reasons: pinReasons
            )
            let nextRevision = try advancedStateRevision()
            for identity in workspace.identities {
                residency.pinExistingPreflighted(
                    identity,
                    reasons: pinReasons
                )
            }
            let leaseID = PaintTileLeaseID(rawValue: leaseRawID)
            leases[leaseID] = LeaseRecord(
                surfaceID: surfaceID,
                generation: generation,
                identityStorage: .strokeWorkspace(workspace),
                mixedNamespaceKeys: nil,
                pinReasons: pinReasons
            )
            workspace.isOutstanding = true
            nextLeaseID = leaseRawID
            stateRevision = nextRevision
            return PaintTileLease(
                id: leaseID,
                surfaceID: surfaceID,
                layerID: layerID,
                generation: generation,
                storeIdentity: identity,
                pinReasons: pinReasons,
                strokeWorkspace: workspace
            )
        } catch {
            workspace.abandonReservation()
            throw error
        }
    }

    public func markModified(
        _ lease: PaintTileLease,
        surfaceID: UUID,
        currentGeneration: UInt64
    ) throws {
        try markModified(
            lease,
            surfaceID: surfaceID,
            currentGeneration: currentGeneration,
            coordinates: lease.bindings.map(\.descriptor.coordinate)
        )
    }

    func makeProvisionalBindings(
        for lease: PaintTileLease,
        surfaceID: UUID,
        currentGeneration: UInt64,
        coordinates: [PaintTileCoordinate],
        workspace: PaintTileProvisionalWorkspace
    ) throws -> PaintTileProvisionalReservation {
        try withLock {
            try workspace.prepare(count: coordinates.count)
            var provisionalSlot: Int?
            var provisionalToken: UInt64?
            var allocationBytes = 0
            func rollbackReservation() {
                if let provisionalSlot,
                   let record = provisionalReservations[provisionalSlot]
                {
                    provisionalReservations[provisionalSlot] = nil
                    provisionalByteCount -= record.byteCount
                }
                workspace.clear()
            }
            do {
            _ = try validate(
                lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration
            )
            let (computedAllocationBytes, allocationOverflow) = coordinates.count
                .multipliedReportingOverflow(
                    by: PaintTileDescriptor.residentByteCount
                )
            allocationBytes = allocationOverflow ? .max : computedAllocationBytes
            let residentBytes = residency.residentByteCount
            let (residentAndProvisional, provisionalOverflow) = residentBytes
                .addingReportingOverflow(provisionalByteCount)
            let (requiredBytes, requiredOverflow) = residentAndProvisional
                .addingReportingOverflow(allocationBytes)
            guard !allocationOverflow, !provisionalOverflow, !requiredOverflow,
                  requiredBytes <= transferByteCapacity
            else {
                throw PaintTileStoreError.transferCapacityExceeded(
                    requiredBytes: allocationOverflow || provisionalOverflow
                        || requiredOverflow
                        ? .max : requiredBytes,
                    capacityBytes: transferByteCapacity,
                    residentBytes: residentBytes,
                    allocationBytes: allocationOverflow
                        ? .max : allocationBytes,
                    stagingBytes: provisionalOverflow
                        ? .max : provisionalByteCount
                )
            }
            guard let freeSlot = provisionalReservations.firstIndex(where: {
                $0 == nil
            }) else {
                throw PaintTileStoreError
                    .provisionalReservationCapacityExceeded(
                        maximum: Self.maximumProvisionalReservationCount
                    )
            }
            let (token, tokenOverflow) = nextProvisionalReservationID
                .addingReportingOverflow(1)
            guard !tokenOverflow else {
                throw PaintTileStoreError.provisionalReservationIDOverflow
            }
            let (nextProvisionalBytes, bytesOverflow) = provisionalByteCount
                .addingReportingOverflow(allocationBytes)
            guard !bytesOverflow else {
                throw PaintTileStoreError.transferCapacityExceeded(
                    requiredBytes: .max,
                    capacityBytes: transferByteCapacity,
                    residentBytes: residentBytes,
                    allocationBytes: allocationBytes,
                    stagingBytes: provisionalByteCount
                )
            }
            provisionalReservations[freeSlot] = ProvisionalReservationRecord(
                token: token,
                byteCount: allocationBytes,
                surfaceID: surfaceID,
                generation: currentGeneration
            )
            provisionalByteCount = nextProvisionalBytes
            nextProvisionalReservationID = token
            provisionalSlot = freeSlot
            provisionalToken = token
            var bindingIndex = 0
            var previousCoordinate: PaintTileCoordinate?
            for (outputIndex, coordinate) in coordinates.enumerated() {
                if let previousCoordinate,
                   !(previousCoordinate < coordinate)
                {
                    throw PaintTileStoreError.leaseBindingMismatch
                }
                previousCoordinate = coordinate
                while bindingIndex < lease.bindings.count,
                      lease.bindings[bindingIndex].descriptor.coordinate
                        < coordinate
                {
                    bindingIndex += 1
                }
                guard bindingIndex < lease.bindings.count,
                      lease.bindings[bindingIndex].descriptor.coordinate
                        == coordinate
                else { throw PaintTileStoreError.leaseBindingMismatch }
                let binding = lease.bindings[bindingIndex]
                let key = Key(
                    surfaceID: surfaceID,
                    layerID: lease.layerID,
                    generation: currentGeneration,
                    coordinate: coordinate
                )
                guard let record = records[key],
                      record.identity == binding.identity,
                let sourceTexture = record.texture
                else { throw PaintTileStoreError.leaseBindingMismatch }
                guard let candidate = device.makeTexture(
                    descriptor: provisionalTextureDescriptor
                )
                else {
                    throw PaintTileStoreError.textureAllocationFailed(
                        reserveIndex: outputIndex
                    )
                }
                workspace.install(PaintTileProvisionalBinding(
                    identity: binding.identity,
                    descriptor: binding.descriptor,
                    sourceTexture: sourceTexture,
                    candidateTexture: candidate,
                    sourceIsKnownClear: record.backing == .knownClear
                ), at: outputIndex)
            }
            return PaintTileProvisionalReservation(
                owner: ObjectIdentifier(self),
                slotIndex: provisionalSlot!,
                token: provisionalToken!,
                reservedBytes: allocationBytes,
                workspace: workspace
            )
            } catch {
                rollbackReservation()
                throw error
            }
        }
    }

    func commitProvisionalBindings(
        _ provisional: PaintTileProvisionalReservation,
        for lease: PaintTileLease,
        surfaceID: UUID,
        currentGeneration: UInt64,
        modifiedCoordinates: [PaintTileCoordinate],
        knownClearCoordinates: [PaintTileCoordinate]
    ) throws -> PaintTileLease {
        return try withLock {
            try validateProvisionalReservation(provisional)
            _ = try validate(
                lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration
            )
            guard Self.isStrictlySortedUnique(modifiedCoordinates),
                  Self.isStrictlySortedUnique(knownClearCoordinates)
            else { throw PaintTileStoreError.leaseBindingMismatch }
            guard lease.retainedBindingCount == provisional.count
            else { throw PaintTileStoreError.leaseBindingMismatch }
            var leaseIndex = 0
            var newActivePinCount = 0
            for candidateIndex in 0..<provisional.count {
                let candidate = provisional[candidateIndex]
                while leaseIndex < lease.bindings.count,
                      lease.bindings[leaseIndex].descriptor.coordinate
                        < candidate.descriptor.coordinate
                {
                    leaseIndex += 1
                }
                guard leaseIndex < lease.bindings.count,
                      lease.bindings[leaseIndex].identity
                        == candidate.identity,
                      let current = records[Key(
                          surfaceID: surfaceID,
                          layerID: lease.layerID,
                          generation: currentGeneration,
                          coordinate: candidate.descriptor.coordinate
                      )]?.texture,
                      (current as AnyObject)
                        === (candidate.sourceTexture as AnyObject)
                else { throw PaintTileStoreError.leaseBindingMismatch }
                let key = Key(
                    surfaceID: surfaceID,
                    layerID: lease.layerID,
                    generation: currentGeneration,
                    coordinate: candidate.descriptor.coordinate
                )
                guard let record = records[key] else {
                    throw PaintTileStoreError.leaseBindingMismatch
                }
                let isModified = Self.containsSorted(
                    modifiedCoordinates,
                    candidate.descriptor.coordinate
                )
                let isKnownClear = Self.containsSorted(
                    knownClearCoordinates,
                    candidate.descriptor.coordinate
                )
                guard isModified != isKnownClear else {
                    throw PaintTileStoreError.leaseBindingMismatch
                }
                if isModified, !record.storage.isStrokeActive {
                    try residency.preflightPinExisting(
                        candidate.identity,
                        reasons: [.active]
                    )
                    newActivePinCount += 1
                } else if isKnownClear, record.storage.isStrokeActive,
                   residency.pinCount(candidate.identity, reason: .active) == 0
                {
                    throw PaintTileResidencyError.unbalancedUnpin(
                        reason: .active
                    )
                }
            }
            try residency.preflightUseEpochAdvance(by: newActivePinCount)
            let nextRevision = try advancedStateRevision()
            for candidateIndex in 0..<provisional.count {
                let candidate = provisional[candidateIndex]
                let recordKey = Key(
                    surfaceID: surfaceID,
                    layerID: lease.layerID,
                    generation: currentGeneration,
                    coordinate: candidate.descriptor.coordinate
                )
                precondition(records[recordKey]?.identity == candidate.identity)
                records[recordKey]?.storage.texture = candidate.candidateTexture
                if Self.containsSorted(
                    knownClearCoordinates,
                    candidate.descriptor.coordinate
                ) {
                    if records[recordKey]?.storage.isStrokeActive == true {
                        try residency.unpin(
                            candidate.identity,
                            reason: .active
                        )
                        records[recordKey]?.storage.isStrokeActive = false
                    }
                    records[recordKey]?.storage.backing = .knownClear
                } else if Self.containsSorted(
                    modifiedCoordinates,
                    candidate.descriptor.coordinate
                ) {
                    if records[recordKey]?.storage.isStrokeActive == false {
                        residency.pinExistingPreflighted(
                            candidate.identity,
                            reasons: [.active]
                        )
                        records[recordKey]?.storage.isStrokeActive = true
                    }
                    records[recordKey]?.storage.backing = nil
                } else {
                    preconditionFailure("Publication inputs were preflighted")
                }
            }
            let committedLease = lease.installingCommittedCandidates(
                from: provisional
            )
            provisional.markCommitted()
            stateRevision = nextRevision
            return committedLease
        }
    }

    func completeProvisionalBindings(
        _ provisional: PaintTileProvisionalReservation
    ) {
        withLock {
            precondition(
                provisional.owner == ObjectIdentifier(self)
                    && provisional.isReserved
                    && provisional.isCommitted
                    && provisional.slotIndex >= 0
                    && provisional.slotIndex < provisionalReservations.count
                    && provisionalReservations[provisional.slotIndex]?.token
                        == provisional.token
            )
            releaseProvisionalReservation(provisional)
            provisional.markCompleted()
            provisional.workspace.clear()
        }
    }

    func cancelProvisionalBindings(
        _ provisional: PaintTileProvisionalReservation
    ) throws {
        try withLock {
            try validateProvisionalReservation(provisional)
            guard !provisional.isCommitted else {
                throw PaintTileStoreError.invalidProvisionalReservation
            }
            releaseProvisionalReservation(provisional)
            provisional.markCancelled()
            provisional.workspace.clear()
        }
    }

    private func validateProvisionalReservation(
        _ provisional: PaintTileProvisionalReservation
    ) throws {
        guard provisional.owner == ObjectIdentifier(self),
              provisional.isReserved,
              provisional.slotIndex >= 0,
              provisional.slotIndex < provisionalReservations.count,
              let record = provisionalReservations[provisional.slotIndex],
              record.token == provisional.token,
              record.byteCount == provisional.reservedBytes
        else { throw PaintTileStoreError.invalidProvisionalReservation }
    }

    private func releaseProvisionalReservation(
        _ provisional: PaintTileProvisionalReservation
    ) {
        precondition(
            provisionalReservations[provisional.slotIndex]?.token
                == provisional.token
        )
        provisionalReservations[provisional.slotIndex] = nil
        precondition(provisionalByteCount >= provisional.reservedBytes)
        provisionalByteCount -= provisional.reservedBytes
    }

    private static func containsSorted(
        _ coordinates: [PaintTileCoordinate],
        _ candidate: PaintTileCoordinate
    ) -> Bool {
        var lower = 0
        var upper = coordinates.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if coordinates[middle] < candidate {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < coordinates.count && coordinates[lower] == candidate
    }

    private static func isStrictlySortedUnique(
        _ coordinates: [PaintTileCoordinate]
    ) -> Bool {
        for index in coordinates.indices.dropFirst()
        where !(coordinates[index - 1] < coordinates[index]) {
            return false
        }
        return true
    }

    func markKnownClear(
        _ lease: PaintTileLease,
        surfaceID: UUID,
        currentGeneration: UInt64,
        coordinates: [PaintTileCoordinate]
    ) throws {
        guard !coordinates.isEmpty else { return }
        try withLock {
            _ = try validate(
                lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration
            )
            var keys: [Key] = []
            keys.reserveCapacity(coordinates.count)
            var bindingIndex = 0
            for coordinate in coordinates {
                while bindingIndex < lease.bindings.count,
                      lease.bindings[bindingIndex].descriptor.coordinate
                        < coordinate
                {
                    bindingIndex += 1
                }
                guard bindingIndex < lease.bindings.count,
                      lease.bindings[bindingIndex].descriptor.coordinate
                        == coordinate,
                      let key = records.first(where: {
                          $0.value.identity
                            == lease.bindings[bindingIndex].identity
                      })?.key
                else { throw PaintTileStoreError.leaseBindingMismatch }
                keys.append(key)
            }
            let nextRevision = try advancedStateRevision()
            for key in keys { records[key]?.storage.backing = .knownClear }
            stateRevision = nextRevision
        }
    }

    public func markModified(
        _ lease: PaintTileLease,
        surfaceID: UUID,
        currentGeneration: UInt64,
        coordinates: [PaintTileCoordinate]
    ) throws {
        try withLock {
            _ = try validate(
                lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration
            )
            let nextRevision = try advancedStateRevision()
            let staged = Self.cloneRecords(records)
            var bindingIndex = 0
            var previousCoordinate: PaintTileCoordinate?
            for coordinate in coordinates {
                if let previousCoordinate,
                   !(previousCoordinate < coordinate)
                {
                    throw PaintTileStoreError.leaseBindingMismatch
                }
                previousCoordinate = coordinate
                while bindingIndex < lease.bindings.count,
                      lease.bindings[bindingIndex].descriptor.coordinate
                        < coordinate
                {
                    bindingIndex += 1
                }
                guard bindingIndex < lease.bindings.count,
                      lease.bindings[bindingIndex].descriptor.coordinate
                        == coordinate
                else { throw PaintTileStoreError.leaseBindingMismatch }
                let identity = lease.bindings[bindingIndex].identity
                guard let key = staged.first(where: {
                    $0.value.identity == identity
                })?.key else {
                    throw PaintTileStoreError.leaseBindingMismatch
                }
                staged[key]?.storage.backing = nil
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
            let nextRevision = try advancedStateRevision()
            try preflightRelease(leaseRecord)
            try applyRelease(leaseRecord)
            leases.removeValue(forKey: lease.id)
            leaseRecord.identityStorage.markReturned()
            stateRevision = nextRevision
        }
    }

    /// Returns the authoritative and prediction leases as one store
    /// transaction. Every identity and pin is preflighted before either lease
    /// mutates residency, so a malformed second lease cannot half-ACK a frame.
    func releaseAtomically(
        authoritative: PaintTileLease?,
        authoritativeSurfaceID: UUID,
        authoritativeGeneration: UInt64,
        prediction: PaintTileLease?,
        predictionSurfaceID: UUID,
        predictionGeneration: UInt64
    ) throws {
        try withLock {
            if let authoritative, let prediction,
               authoritative.id == prediction.id
            {
                throw PaintTileStoreError.leaseBindingMismatch
            }
            let authoritativeRecord = try authoritative.map {
                try validate(
                    $0,
                    surfaceID: authoritativeSurfaceID,
                    currentGeneration: authoritativeGeneration
                )
            }
            let predictionRecord = try prediction.map {
                try validate(
                    $0,
                    surfaceID: predictionSurfaceID,
                    currentGeneration: predictionGeneration
                )
            }
            guard authoritativeRecord != nil || predictionRecord != nil else {
                return
            }
            let nextRevision = try advancedStateRevision()
            if let authoritativeRecord {
                try preflightRelease(authoritativeRecord)
            }
            if let predictionRecord {
                try preflightRelease(predictionRecord)
            }
            if let authoritativeRecord {
                try applyRelease(authoritativeRecord)
            }
            if let predictionRecord {
                try applyRelease(predictionRecord)
            }
            if let authoritative {
                leases.removeValue(forKey: authoritative.id)
            }
            if let prediction {
                leases.removeValue(forKey: prediction.id)
            }
            authoritativeRecord?.identityStorage.markReturned()
            predictionRecord?.identityStorage.markReturned()
            stateRevision = nextRevision
        }
    }

    private func preflightRelease(_ leaseRecord: LeaseRecord) throws {
        try leaseRecord.identityStorage.forEach { identity in
            for reason in leaseRecord.pinReasons {
                guard residency.pinCount(identity, reason: reason) > 0 else {
                    throw PaintTileResidencyError.unbalancedUnpin(
                        reason: reason
                    )
                }
            }
        }
    }

    private func applyRelease(_ leaseRecord: LeaseRecord) throws {
        try leaseRecord.identityStorage.forEach { identity in
            for reason in leaseRecord.pinReasons {
                try residency.unpin(identity, reason: reason)
            }
        }
        var identityIndex = 0
        leaseRecord.identityStorage.forEach { identity in
            let key: Key
            if let mixedNamespaceKeys = leaseRecord.mixedNamespaceKeys {
                key = mixedNamespaceKeys[identityIndex]
            } else {
                key = Key(
                    surfaceID: leaseRecord.surfaceID,
                    layerID: identity.layerID,
                    generation: leaseRecord.generation,
                    coordinate: identity.coordinate
                )
            }
            identityIndex += 1
            guard !residency.isPinned(identity) else { return }
            if pendingRetirementKeys.remove(key) != nil {
                removeRecord(for: key)
            } else if !preparedRetirementKeys.contains(key),
                      records[key]?.backing == .knownClear {
                removeRecord(for: key)
            }
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
            let stagedRecords = Self.cloneRecords(records)
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
                    stagedRecords[key]?.storage.texture = nil
                    if let snapshot = captured[identity] {
                        stagedRecords[key]?.storage.backing = snapshot
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
            var matchingLeases = 0
            for lease in leases.values {
                if lease.referencesPhysicalNamespace(
                    surfaceID: surfaceID,
                    generation: generation
                ) {
                    matchingLeases += 1
                }
            }
            guard matchingLeases == 0 else {
                throw PaintTileStoreError.outstandingLeases(
                    surfaceID: surfaceID,
                    generation: generation,
                    count: matchingLeases
                )
            }
            let provisionalCount = provisionalReservations.reduce(into: 0) {
                if $1?.surfaceID == surfaceID,
                   $1?.generation == generation { $0 += 1 }
            }
            guard provisionalCount == 0 else {
                throw PaintTileStoreError.outstandingProvisionalReservations(
                    surfaceID: surfaceID,
                    generation: generation,
                    count: provisionalCount
                )
            }
            guard !preparedRetirementKeys.contains(where: {
                $0.surfaceID == surfaceID && $0.generation == generation
            }) else {
                throw PaintTileStoreError.retirementAlreadyPrepared
            }
            guard var matchingKey = records.first(where: {
                $0.key.surfaceID == surfaceID
                    && $0.key.generation == generation
            })?.key else { return }
            let nextRevision = try advancedStateRevision()
            while true {
                removeRecord(for: matchingKey)
                guard let nextKey = records.first(where: {
                    $0.key.surfaceID == surfaceID
                        && $0.key.generation == generation
                })?.key else { break }
                matchingKey = nextKey
            }
            stateRevision = nextRevision
        }
    }

    /// Retires the authoritative/prediction namespace as one transaction.
    /// Both lease sets and the revision advance are preflighted before either
    /// surface record is removed, so failure cannot strand one half.
    func retireAtomically(
        authoritativeSurfaceID: UUID,
        predictionSurfaceID: UUID,
        generation: UInt64
    ) throws {
        try withLock {
            precondition(authoritativeSurfaceID != predictionSurfaceID)
            var authoritativeLeaseCount = 0
            var predictionLeaseCount = 0
            var authoritativeProvisionalCount = 0
            var predictionProvisionalCount = 0
            for lease in leases.values {
                if lease.referencesPhysicalNamespace(
                    surfaceID: authoritativeSurfaceID,
                    generation: generation
                ) {
                    authoritativeLeaseCount += 1
                } else if lease.referencesPhysicalNamespace(
                    surfaceID: predictionSurfaceID,
                    generation: generation
                ) {
                    predictionLeaseCount += 1
                }
            }
            for reservation in provisionalReservations
            where reservation?.generation == generation {
                if reservation?.surfaceID == authoritativeSurfaceID {
                    authoritativeProvisionalCount += 1
                } else if reservation?.surfaceID == predictionSurfaceID {
                    predictionProvisionalCount += 1
                }
            }
            guard authoritativeLeaseCount == 0 else {
                throw PaintTileStoreError.outstandingLeases(
                    surfaceID: authoritativeSurfaceID,
                    generation: generation,
                    count: authoritativeLeaseCount
                )
            }
            guard predictionLeaseCount == 0 else {
                throw PaintTileStoreError.outstandingLeases(
                    surfaceID: predictionSurfaceID,
                    generation: generation,
                    count: predictionLeaseCount
                )
            }
            guard authoritativeProvisionalCount == 0 else {
                throw PaintTileStoreError.outstandingProvisionalReservations(
                    surfaceID: authoritativeSurfaceID,
                    generation: generation,
                    count: authoritativeProvisionalCount
                )
            }
            guard predictionProvisionalCount == 0 else {
                throw PaintTileStoreError.outstandingProvisionalReservations(
                    surfaceID: predictionSurfaceID,
                    generation: generation,
                    count: predictionProvisionalCount
                )
            }
            guard !preparedRetirementKeys.contains(where: {
                $0.generation == generation
                    && ($0.surfaceID == authoritativeSurfaceID
                        || $0.surfaceID == predictionSurfaceID)
            }) else {
                throw PaintTileStoreError.retirementAlreadyPrepared
            }
            let hasMatchingRecord = records.keys.contains {
                $0.generation == generation
                    && ($0.surfaceID == authoritativeSurfaceID
                        || $0.surfaceID == predictionSurfaceID)
            }
            guard hasMatchingRecord else { return }
            let nextRevision = try advancedStateRevision()
            while let key = records.first(where: {
                $0.key.generation == generation
                    && ($0.key.surfaceID == authoritativeSurfaceID
                        || $0.key.surfaceID == predictionSurfaceID)
            })?.key {
                removeRecord(for: key)
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

    /// Cold transactional paths clone mutable record storage before staging.
    /// The warmed stroke publication path mutates the uniquely owned storage
    /// object directly, avoiding Dictionary value writeback and its heap work.
    private static func cloneRecords(
        _ source: [Key: Record]
    ) -> [Key: Record] {
        var result = source
        for (key, record) in source { result[key] = record.cloned() }
        return result
    }

    private func validate(
        _ lease: PaintTileLease,
        surfaceID: UUID,
        currentGeneration: UInt64
    ) throws -> LeaseRecord {
        guard lease.storeIdentity == identity else {
            throw PaintTileStoreError.foreignStoreReference
        }
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
              record.identityStorage.elementsEqual(lease.bindings),
              record.pinReasons == lease.pinReasons
        else {
            throw PaintTileStoreError.leaseBindingMismatch
        }
        return record
    }

    private func reference(key: Key, record: Record) -> PaintTileReference {
        PaintTileReference(
            storeIdentity: identity,
            physicalSurfaceID: key.surfaceID,
            layerID: key.layerID,
            physicalGeneration: key.generation,
            identity: record.identity,
            descriptor: record.descriptor
        )
    }

    private func removeRecord(for key: Key) {
        if let record = records.removeValue(forKey: key) {
            residency.remove(record.identity)
        }
        pendingRetirementKeys.remove(key)
        preparedRetirementKeys.remove(key)
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
