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
        persistentZeroBytes: Int,
        stagingBytes: Int
    )
    case foreignStoreReference
    case unsortedReference
    case duplicateReference
    case staleTileReference
    case retirementAlreadyPrepared
    case retirementIdentityOverflow
    case snapshotRetentionTokenIdentityOverflow
    case invalidSnapshotRetentionToken
    case snapshotRetentionCountOverflow(PaintTileID)
    case snapshotRetentionArithmeticOverflow(
        PaintTileSnapshotRetentionLimit
    )
    case snapshotRetentionLimitExceeded(
        limit: PaintTileSnapshotRetentionLimit,
        required: Int,
        maximum: Int
    )
}

public enum PaintTileSnapshotRetentionLimit: Equatable, Sendable {
    case activeTokens
    case referencesPerToken
    case aggregateReferences
    case indexEntries
    case metadataBytes
    case payloadDebtBytes
}

public struct PaintTileSnapshotRetentionLimits: Equatable, Sendable {
    public let maximumActiveTokenCount: Int
    public let maximumReferencesPerToken: Int
    public let maximumAggregateReferenceCount: Int
    public let maximumIndexEntryCount: Int
    public let maximumMetadataBytes: Int
    public let maximumPayloadDebtBytes: Int

    public init(
        maximumActiveTokenCount: Int,
        maximumReferencesPerToken: Int,
        maximumAggregateReferenceCount: Int,
        maximumIndexEntryCount: Int,
        maximumMetadataBytes: Int,
        maximumPayloadDebtBytes: Int
    ) {
        precondition(maximumActiveTokenCount >= 0)
        precondition(maximumReferencesPerToken >= 0)
        precondition(maximumAggregateReferenceCount >= 0)
        precondition(maximumIndexEntryCount >= 0)
        precondition(maximumMetadataBytes >= 0)
        precondition(maximumPayloadDebtBytes >= 0)
        self.maximumActiveTokenCount = maximumActiveTokenCount
        self.maximumReferencesPerToken = maximumReferencesPerToken
        self.maximumAggregateReferenceCount = maximumAggregateReferenceCount
        self.maximumIndexEntryCount = maximumIndexEntryCount
        self.maximumMetadataBytes = maximumMetadataBytes
        self.maximumPayloadDebtBytes = maximumPayloadDebtBytes
    }

    public static func productionDefault(
        byteBudget: Int,
        snapshotPayloadLiabilityByteBudget: Int? = nil
    ) -> PaintTileSnapshotRetentionLimits {
        precondition(byteBudget > 0)
        let liabilityBudget = snapshotPayloadLiabilityByteBudget ?? byteBudget
        precondition(liabilityBudget >= 0)
        return PaintTileSnapshotRetentionLimits(
            maximumActiveTokenCount: 256,
            maximumReferencesPerToken: 65_536,
            maximumAggregateReferenceCount: 262_144,
            maximumIndexEntryCount: 1_048_576,
            maximumMetadataBytes: 64 * 1_024 * 1_024,
            // Every uniquely retained physical record remains a full-tile
            // payload liability regardless of its current resident/backing
            // representation. The legacy "payload debt" API name is retained
            // for source compatibility; callers may budget liability
            // independently from GPU residency.
            maximumPayloadDebtBytes: liabilityBudget
        )
    }
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

/// Opaque preflight proving that exact snapshot-retained references may be
/// made current again. Preparing it changes no store state; the owning
/// registry consumes it immediately before publishing the epoch that refers
/// to those entries.
final class PaintTilePreparedReactivation: @unchecked Sendable {
    fileprivate let storeIdentity: PaintTileStoreIdentity
    fileprivate let references: [PaintTileReference]
    fileprivate let retentionToken: PaintTileSnapshotToken

    fileprivate init(
        storeIdentity: PaintTileStoreIdentity,
        references: [PaintTileReference],
        retentionToken: PaintTileSnapshotToken
    ) {
        self.storeIdentity = storeIdentity
        self.references = references
        self.retentionToken = retentionToken
    }
}

/// Opaque, explicitly closed capability retaining exact physical tile
/// identities for immutable snapshot readers. Dropping the object is a
/// diagnostic only; it never changes store ownership.
final class PaintTileSnapshotToken: @unchecked Sendable {
    fileprivate let storeIdentity: PaintTileStoreIdentity
    fileprivate let token: UInt64
    private let stateLock = NSLock()
    private var closed = false
    private let closeAction: @Sendable (
        PaintTileSnapshotToken
    ) -> Void
    private let deinitDiagnostic: @Sendable (UInt64) -> Void

    fileprivate init(
        storeIdentity: PaintTileStoreIdentity,
        token: UInt64,
        closeAction: @escaping @Sendable (
            PaintTileSnapshotToken
        ) -> Void,
        deinitDiagnostic: @escaping @Sendable (UInt64) -> Void
    ) {
        self.storeIdentity = storeIdentity
        self.token = token
        self.closeAction = closeAction
        self.deinitDiagnostic = deinitDiagnostic
    }

    fileprivate var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    func close() {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()
        closeAction(self)
    }

    deinit {
        stateLock.lock()
        let leaked = !closed
        stateLock.unlock()
        if leaked { deinitDiagnostic(token) }
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
    fileprivate var identities: [PaintTileIdentity] = []
    fileprivate var descriptors: [PaintTileDescriptor] = []
    fileprivate var textures: [any MTLTexture] = []
    fileprivate var isOutstanding = false
    var retainedBindingCount: Int { identities.count }

    init(maximumBindingCount: Int) {
        precondition(maximumBindingCount > 0)
        self.maximumBindingCount = maximumBindingCount
        identities.reserveCapacity(maximumBindingCount)
        descriptors.reserveCapacity(maximumBindingCount)
        textures.reserveCapacity(maximumBindingCount)
    }

    fileprivate func prepareForReservation() throws {
        guard !isOutstanding else {
            throw PaintTileStoreError.leaseBindingMismatch
        }
        identities.removeAll(keepingCapacity: true)
        descriptors.removeAll(keepingCapacity: true)
        textures.removeAll(keepingCapacity: true)
    }

    func abandonReservation() {
        identities.removeAll(keepingCapacity: true)
        descriptors.removeAll(keepingCapacity: true)
        textures.removeAll(keepingCapacity: true)
        isOutstanding = false
    }

    fileprivate func completeReturn() {
        precondition(isOutstanding)
        identities.removeAll(keepingCapacity: true)
        descriptors.removeAll(keepingCapacity: true)
        textures.removeAll(keepingCapacity: true)
        isOutstanding = false
    }

    fileprivate func binding(at index: Int) -> PaintTileBinding {
        PaintTileBinding(
            identity: identities[index],
            descriptor: descriptors[index],
            texture: textures[index]
        )
    }

    fileprivate func bindingSnapshot() -> [PaintTileBinding] {
        identities.indices.map { binding(at: $0) }
    }

    fileprivate func installCommittedCandidates(
        from provisional: PaintTileProvisionalReservation
    ) {
        precondition(isOutstanding && identities.count == provisional.count)
        for index in 0..<provisional.count {
            let candidate = provisional[index]
            precondition(identities[index] == candidate.identity)
            precondition(descriptors[index] == candidate.descriptor)
            textures[index] = candidate.candidateTexture
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
        strokeWorkspace?.bindingSnapshot() ?? ownedBindings
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

    fileprivate func retainedBinding(at index: Int) -> PaintTileBinding {
        if let strokeWorkspace {
            return strokeWorkspace.binding(at: index)
        }
        return ownedBindings[index]
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
    public let persistentZeroAllocationBytes: Int
    public let persistentZeroAllocationCount: Int
    public let uploadStagingBytes: Int
    public let readbackStagingBytes: Int
    public let capturedPayloadBytes: Int
    public let peakTrackedBytes: Int
    public let capacityBytes: Int

    public init(
        residentTextureBytesBefore: Int,
        allocatedTextureBytes: Int,
        persistentZeroAllocationBytes: Int,
        persistentZeroAllocationCount: Int,
        uploadStagingBytes: Int,
        readbackStagingBytes: Int,
        capturedPayloadBytes: Int,
        peakTrackedBytes: Int,
        capacityBytes: Int
    ) {
        self.residentTextureBytesBefore = residentTextureBytesBefore
        self.allocatedTextureBytes = allocatedTextureBytes
        self.persistentZeroAllocationBytes = persistentZeroAllocationBytes
        self.persistentZeroAllocationCount = persistentZeroAllocationCount
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
    public let snapshotRetainCount: UInt32
}

public struct PaintTileStoreSnapshot: Equatable, Sendable {
    public let stateRevision: UInt64
    public let nextTileID: UInt64
    public let nextLeaseID: UInt64
    public let residentByteCount: Int
    public let backingByteCount: Int
    public let persistentZeroAllocationBytes: Int
    public let persistentZeroAllocationCount: Int
    public let activeLeaseCount: Int
    public let provisionalReservationCount: Int
    public let provisionalByteCount: Int
    public let preparedRetirementCount: Int
    public let pendingRetirementCount: Int
    public let tileIndexEntryCount: Int
    public let activeSnapshotTokenCount: Int
    public let aggregateSnapshotReferenceCount: Int
    public let snapshotMetadataByteCount: Int
    /// Conservative retained-payload liability. The legacy debt name remains
    /// public for compatibility; backing does not reduce this count.
    public let snapshotPayloadDebtByteCount: Int
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

    private struct SnapshotRetentionRecord {
        let capabilityIdentity: ObjectIdentifier
        /// The sole retained-member payload. IDs are globally unique within
        /// this store and sorted so authorization is logarithmic without a
        /// second Set/Dictionary allocation.
        let sortedTileIDs: [PaintTileID]
        let metadataBytes: Int
    }

    /// Exact static-value strides plus a conservative allowance for heap
    /// headers, Dictionary buckets, the token object, lock, and closures. The
    /// variable payload below is exact because the store retains only tile
    /// IDs; full frozen references belong to the later snapshot provider.
    private static let snapshotRetentionHeapOverheadAllowanceBytes = 256
    static let snapshotRetentionFixedMetadataBytes =
        snapshotRetentionHeapOverheadAllowanceBytes
        + MemoryLayout<UInt64>.stride
        + MemoryLayout<SnapshotRetentionRecord>.stride
        + MemoryLayout<PaintTileSnapshotToken>.stride
    static let snapshotRetentionReferenceMetadataBytes =
        MemoryLayout<PaintTileID>.stride

    private final class RecordStorage {
        var texture: (any MTLTexture)?
        var backing: PaintTileBackingSnapshot?
        var isStrokeActive: Bool
        var snapshotRetainCount: UInt32

        init(
            texture: (any MTLTexture)?,
            backing: PaintTileBackingSnapshot?,
            isStrokeActive: Bool = false,
            snapshotRetainCount: UInt32 = 0
        ) {
            self.texture = texture
            self.backing = backing
            self.isStrokeActive = isStrokeActive
            self.snapshotRetainCount = snapshotRetainCount
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
            isStrokeActive: Bool = false,
            snapshotRetainCount: UInt32 = 0
        ) {
            self.identity = identity
            self.descriptor = descriptor
            storage = RecordStorage(
                texture: texture,
                backing: backing,
                isStrokeActive: isStrokeActive,
                snapshotRetainCount: snapshotRetainCount
            )
        }

        func cloned() -> Record {
            Record(
                identity: identity,
                descriptor: descriptor,
                texture: texture,
                backing: backing,
                isStrokeActive: storage.isStrokeActive,
                snapshotRetainCount: storage.snapshotRetainCount
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

        func elementsEqual(_ lease: PaintTileLease) -> Bool {
            guard count == lease.retainedBindingCount else { return false }
            switch self {
            case let .owned(identities):
                return identities.indices.allSatisfy {
                    identities[$0] == lease.retainedBinding(at: $0).identity
                }
            case let .strokeWorkspace(workspace):
                return workspace.identities.indices.allSatisfy {
                    workspace.identities[$0]
                        == lease.retainedBinding(at: $0).identity
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

    private struct TransferResult {
        let captured: [PaintTileIdentity: PaintTileBackingSnapshot]
        let newlyAllocatedPersistentZeroSource: (any MTLBuffer)?
    }

    private let device: any MTLDevice
    public let identity = PaintTileStoreIdentity()
    public let transferByteCapacity: Int
    private let lock = NSLock()
    private var residency: PaintTileResidency
    private var records: [Key: Record] = [:]
    private var tileKeyByID: [PaintTileID: Key] = [:]
    private var leases: [PaintTileLeaseID: LeaseRecord] = [:]
    private var nextTileID: UInt64 = 0
    private var nextLeaseID: UInt64 = 0
    private var stateRevision: UInt64 = 0
    private var lastTransferAccounting: PaintTileTransferAccounting?
    private var persistentZeroSource: (any MTLBuffer)?
    private var persistentZeroAllocationCount = 0
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
    private var namespaceRetirementKeys: [Key] = []
    private var nextSnapshotRetentionTokenID: UInt64 = 0
    private var snapshotRetentions:
        [UInt64: SnapshotRetentionRecord] = [:]
    private var aggregateSnapshotReferenceCount = 0
    private var snapshotMetadataByteCount = 0
    private var snapshotRetainedPayloadLiabilityByteCount = 0
    private let snapshotRetentionLimits: PaintTileSnapshotRetentionLimits
    private let snapshotTokenDeinitDiagnostic: @Sendable (UInt64) -> Void
    private let snapshotRetainCountMaximum: UInt32
    private let provisionalTextureDescriptor: MTLTextureDescriptor

    #if DEBUG
    var testingSnapshotPayloadLiabilityByteBudget: Int {
        snapshotRetentionLimits.maximumPayloadDebtBytes
    }
    #endif

    public convenience init(
        device: any MTLDevice,
        byteBudget: Int,
        snapshotPayloadLiabilityByteBudget: Int? = nil
    ) {
        // Preserve the established 3x transfer headroom and add only the one
        // tile-sized shared allocation that this store may retain.
        let (transferHeadroom, multiplicationOverflow) = byteBudget
            .multipliedReportingOverflow(by: 3)
        let (capacity, additionOverflow) = transferHeadroom
            .addingReportingOverflow(PaintTileDescriptor.residentByteCount)
        precondition(!multiplicationOverflow && !additionOverflow)
        self.init(
            device: device,
            byteBudget: byteBudget,
            transferByteCapacity: capacity,
            snapshotPayloadLiabilityByteBudget:
                snapshotPayloadLiabilityByteBudget
        )
    }

    public convenience init(
        device: any MTLDevice,
        byteBudget: Int,
        transferByteCapacity: Int,
        snapshotPayloadLiabilityByteBudget: Int? = nil
    ) {
        self.init(
            device: device,
            byteBudget: byteBudget,
            transferByteCapacity: transferByteCapacity,
            snapshotRetentionLimits: .productionDefault(
                byteBudget: byteBudget,
                snapshotPayloadLiabilityByteBudget:
                    snapshotPayloadLiabilityByteBudget
            )
        )
    }

    public convenience init(
        device: any MTLDevice,
        byteBudget: Int,
        transferByteCapacity: Int,
        snapshotRetentionLimits: PaintTileSnapshotRetentionLimits
    ) {
        self.init(
            device: device,
            byteBudget: byteBudget,
            transferByteCapacity: transferByteCapacity,
            snapshotRetentionLimits: snapshotRetentionLimits,
            snapshotTokenDeinitDiagnostic: { _ in }
        )
    }

    init(
        device: any MTLDevice,
        byteBudget: Int,
        transferByteCapacity: Int,
        snapshotRetentionLimits: PaintTileSnapshotRetentionLimits,
        snapshotTokenDeinitDiagnostic: @escaping @Sendable (UInt64) -> Void,
        initialSnapshotRetentionTokenID: UInt64 = 0,
        snapshotRetainCountMaximum: UInt32 = UInt32.max
    ) {
        precondition(byteBudget > 0)
        precondition(transferByteCapacity > 0)
        self.device = device
        self.transferByteCapacity = transferByteCapacity
        self.snapshotRetentionLimits = snapshotRetentionLimits
        self.snapshotTokenDeinitDiagnostic = snapshotTokenDeinitDiagnostic
        nextSnapshotRetentionTokenID = initialSnapshotRetentionTokenID
        self.snapshotRetainCountMaximum = snapshotRetainCountMaximum
        residency = PaintTileResidency(byteBudget: byteBudget)
        namespaceRetirementKeys.reserveCapacity(
            max(1, byteBudget / PaintTileDescriptor.residentByteCount)
        )
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
            referencesLocked(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: generation,
                omittingKnownClear: false
            )
        }
    }

    /// Exact sampling providers omit physical records whose semantic value is
    /// known transparent. Such records may remain pinned until frame ACK, but
    /// their later physical removal must not change visible source identity.
    func samplingReferences(
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64
    ) -> [PaintTileReference] {
        withLock {
            referencesLocked(
                surfaceID: surfaceID,
                layerID: layerID,
                generation: generation,
                omittingKnownClear: true
            )
        }
    }

    private func referencesLocked(
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64,
        omittingKnownClear: Bool
    ) -> [PaintTileReference] {
        records.compactMap { key, record -> PaintTileReference? in
            guard key.surfaceID == surfaceID,
                  key.layerID == layerID,
                  key.generation == generation,
                  !omittingKnownClear || record.backing != .knownClear
            else { return nil }
            return reference(key: key, record: record)
        }
        .sorted()
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

    /// Reads one exact payload through the snapshot capability that retained
    /// it. The payload is bounded to one physical tile and never exposes a
    /// texture or a mutable store lease to the archive layer.
    func payload(
        exactReference reference: PaintTileReference,
        retainedBy token: PaintTileSnapshotToken
    ) throws -> PaintTilePayload {
        try withLock {
            guard reference.storeIdentity == identity else {
                throw PaintTileStoreError.foreignStoreReference
            }
            guard token.storeIdentity == identity,
                  !token.isClosed,
                  let retained = snapshotRetentions[token.token],
                  retained.capabilityIdentity == ObjectIdentifier(token),
                  Self.snapshotRetentionContains(
                    reference.identity.tileID,
                    in: retained.sortedTileIDs
                  )
            else {
                throw PaintTileStoreError.invalidSnapshotRetentionToken
            }
            let key = Key(
                surfaceID: reference.physicalSurfaceID,
                layerID: reference.layerID,
                generation: reference.physicalGeneration,
                coordinate: reference.coordinate
            )
            guard tileKeyByID[reference.identity.tileID] == key,
                  let record = records[key],
                  self.reference(key: key, record: record) == reference
            else { throw PaintTileStoreError.staleTileReference }

            let backing: PaintTileBackingSnapshot?
            if let installed = record.backing {
                backing = installed
            } else {
                backing = try transfer(
                    evicted: [record.identity],
                    allocations: []
                ).captured[record.identity]
            }
            switch backing {
            case .knownClear:
                return .knownClear
            case let .rgba16Float(data):
                guard data.count == PaintTileDescriptor.residentByteCount else {
                    throw PaintTileStoreError.leaseBindingMismatch
                }
                return .rgba16Float(data)
            case .residentOnly, nil:
                throw PaintTileStoreError.leaseBindingMismatch
            }
        }
    }

    /// Installs one already-authenticated native RGBA16F payload into an
    /// unpublished candidate reference. The caller owns candidate authority;
    /// this layer checks only exact store identity and byte geometry.
    func installNativeArchivePayload(
        _ payload: Data,
        exactReference reference: PaintTileReference
    ) throws {
        guard payload.count == PaintTileDescriptor.residentByteCount else {
            throw PaintTileStoreError.leaseBindingMismatch
        }
        try withLock {
            guard reference.storeIdentity == identity else {
                throw PaintTileStoreError.foreignStoreReference
            }
            let key = Key(
                surfaceID: reference.physicalSurfaceID,
                layerID: reference.layerID,
                generation: reference.physicalGeneration,
                coordinate: reference.coordinate
            )
            guard tileKeyByID[reference.identity.tileID] == key,
                  let record = records[key],
                  self.reference(key: key, record: record) == reference,
                  let texture = record.texture
            else { throw PaintTileStoreError.staleTileReference }
            guard let source = payload.withUnsafeBytes({ raw in
                raw.baseAddress.map {
                    device.makeBuffer(
                        bytes: $0,
                        length: payload.count,
                        options: .storageModeShared
                    )
                } ?? nil
            }) else {
                throw PaintTileStoreError.stagingBufferAllocationFailed
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
            let rowBytes = PaintTileDescriptor.side
                * PaintTileDescriptor.bytesPerPixel
            blit.copy(
                from: source,
                sourceOffset: 0,
                sourceBytesPerRow: rowBytes,
                sourceBytesPerImage: PaintTileDescriptor.residentByteCount,
                sourceSize: MTLSize(
                    width: PaintTileDescriptor.side,
                    height: PaintTileDescriptor.side,
                    depth: 1
                ),
                to: texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else {
                throw PaintTileStoreError.gpuTransferFailed(
                    command.error?.localizedDescription
                        ?? "Native paint tile upload did not complete."
                )
            }
            let nextRevision = try advancedStateRevision()
            records[key]?.storage.backing = nil
            stateRevision = nextRevision
        }
    }

    /// Retains one exact, sorted set across every referenced physical
    /// namespace. Capture may overlap a prepared-retirement barrier, but a
    /// retirement that is already pending has passed the capture boundary and
    /// is rejected.
    func retainSnapshotReferences(
        _ references: [PaintTileReference]
    ) throws -> PaintTileSnapshotToken {
        try withLock {
            let (tokenID, tokenOverflow) = nextSnapshotRetentionTokenID
                .addingReportingOverflow(1)
            guard !tokenOverflow else {
                throw PaintTileStoreError
                    .snapshotRetentionTokenIdentityOverflow
            }
            let nextActiveCount = try checkedSnapshotSum(
                snapshotRetentions.count,
                1,
                limit: .activeTokens
            )
            try enforceSnapshotLimit(
                nextActiveCount,
                maximum: snapshotRetentionLimits.maximumActiveTokenCount,
                limit: .activeTokens
            )
            try enforceSnapshotLimit(
                references.count,
                maximum: snapshotRetentionLimits.maximumReferencesPerToken,
                limit: .referencesPerToken
            )
            let nextAggregate = try checkedSnapshotSum(
                aggregateSnapshotReferenceCount,
                references.count,
                limit: .aggregateReferences
            )
            try enforceSnapshotLimit(
                nextAggregate,
                maximum: snapshotRetentionLimits
                    .maximumAggregateReferenceCount,
                limit: .aggregateReferences
            )
            let referenceMetadataBytes = try checkedSnapshotProduct(
                references.count,
                Self.snapshotRetentionReferenceMetadataBytes,
                limit: .metadataBytes
            )
            let tokenMetadataBytes = try checkedSnapshotSum(
                Self.snapshotRetentionFixedMetadataBytes,
                referenceMetadataBytes,
                limit: .metadataBytes
            )
            let nextMetadataBytes = try checkedSnapshotSum(
                snapshotMetadataByteCount,
                tokenMetadataBytes,
                limit: .metadataBytes
            )
            try enforceSnapshotLimit(
                nextMetadataBytes,
                maximum: snapshotRetentionLimits.maximumMetadataBytes,
                limit: .metadataBytes
            )

            var keys: [Key] = []
            var tileIDs: [PaintTileID] = []
            keys.reserveCapacity(references.count)
            tileIDs.reserveCapacity(references.count)
            var uniqueRetainCount = 0
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
                guard !pendingRetirementKeys.contains(key),
                      tileKeyByID[value.identity.tileID] == key,
                      let record = records[key],
                      reference(key: key, record: record) == value
                else { throw PaintTileStoreError.staleTileReference }
                guard record.storage.snapshotRetainCount
                        < snapshotRetainCountMaximum
                else {
                    throw PaintTileStoreError.snapshotRetentionCountOverflow(
                        value.identity.tileID
                    )
                }
                if record.storage.snapshotRetainCount == 0 {
                    uniqueRetainCount += 1
                }
                keys.append(key)
                tileIDs.append(value.identity.tileID)
            }
            tileIDs.sort()
            let addedPayloadDebt = try checkedSnapshotProduct(
                uniqueRetainCount,
                PaintTileDescriptor.residentByteCount,
                limit: .payloadDebtBytes
            )
            let nextPayloadDebt = try checkedSnapshotSum(
                snapshotRetainedPayloadLiabilityByteCount,
                addedPayloadDebt,
                limit: .payloadDebtBytes
            )
            try enforceSnapshotLimit(
                nextPayloadDebt,
                maximum: snapshotRetentionLimits.maximumPayloadDebtBytes,
                limit: .payloadDebtBytes
            )

            let token = PaintTileSnapshotToken(
                storeIdentity: identity,
                token: tokenID,
                closeAction: { [weak self] token in
                    self?.closeSnapshotRetention(token)
                },
                deinitDiagnostic: snapshotTokenDeinitDiagnostic
            )
            for key in keys {
                records[key]!.storage.snapshotRetainCount += 1
            }
            nextSnapshotRetentionTokenID = tokenID
            aggregateSnapshotReferenceCount = nextAggregate
            snapshotMetadataByteCount = nextMetadataBytes
            snapshotRetainedPayloadLiabilityByteCount = nextPayloadDebt
            snapshotRetentions[tokenID] = SnapshotRetentionRecord(
                capabilityIdentity: ObjectIdentifier(token),
                sortedTileIDs: tileIDs,
                metadataBytes: tokenMetadataBytes
            )
            return token
        }
    }

    private func closeSnapshotRetention(
        _ token: PaintTileSnapshotToken
    ) {
        guard token.storeIdentity == identity else { return }
        withLock {
            guard let retained = snapshotRetentions[token.token],
                  retained.capabilityIdentity == ObjectIdentifier(token)
            else { return }
            snapshotRetentions.removeValue(forKey: token.token)
            precondition(
                aggregateSnapshotReferenceCount
                    >= retained.sortedTileIDs.count
                    && snapshotMetadataByteCount >= retained.metadataBytes
            )
            aggregateSnapshotReferenceCount -= retained.sortedTileIDs.count
            snapshotMetadataByteCount -= retained.metadataBytes
            for tileID in retained.sortedTileIDs {
                guard let key = tileKeyByID[tileID],
                      let record = records[key],
                      record.identity.tileID == tileID,
                      record.storage.snapshotRetainCount > 0
                else { preconditionFailure("Retained tile index drift") }
                record.storage.snapshotRetainCount -= 1
                if record.storage.snapshotRetainCount == 0 {
                    precondition(
                        snapshotRetainedPayloadLiabilityByteCount
                            >= PaintTileDescriptor.residentByteCount
                    )
                    snapshotRetainedPayloadLiabilityByteCount -=
                        PaintTileDescriptor.residentByteCount
                    if pendingRetirementKeys.contains(key) {
                        _ = removeRecordIfEligible(for: key)
                    } else if !preparedRetirementKeys.contains(key),
                              record.backing == .knownClear
                    {
                        _ = removeRecordIfEligible(for: key)
                    }
                }
            }
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
        try reserveReferencesImpl(
            references,
            token: nil,
            leaseSurfaceID: leaseSurfaceID,
            leaseLayerID: leaseLayerID,
            leaseGeneration: leaseGeneration,
            pinReasons: pinReasons
        )
    }

    func reserveRetainedReferences(
        _ references: [PaintTileReference],
        token: PaintTileSnapshotToken,
        leaseSurfaceID: UUID,
        leaseLayerID: UUID,
        leaseGeneration: UInt64,
        pinReasons: [PaintTilePinReason]
    ) throws -> PaintTileLease {
        try reserveReferencesImpl(
            references,
            token: token,
            leaseSurfaceID: leaseSurfaceID,
            leaseLayerID: leaseLayerID,
            leaseGeneration: leaseGeneration,
            pinReasons: pinReasons
        )
    }

    private func reserveReferencesImpl(
        _ references: [PaintTileReference],
        token: PaintTileSnapshotToken?,
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
            let retainedRecord: SnapshotRetentionRecord?
            if let token {
                guard token.storeIdentity == identity,
                      !token.isClosed,
                      let retained = snapshotRetentions[token.token],
                      retained.capabilityIdentity == ObjectIdentifier(token)
                else {
                    throw PaintTileStoreError.invalidSnapshotRetentionToken
                }
                retainedRecord = retained
            } else {
                retainedRecord = nil
            }
            let requested: [(Key, Record)] = try references.map { reference in
                let key = Key(
                    surfaceID: reference.physicalSurfaceID,
                    layerID: reference.layerID,
                    generation: reference.physicalGeneration,
                    coordinate: reference.coordinate
                )
                let retirementAllowsReserve = retainedRecord != nil
                    || (!pendingRetirementKeys.contains(key)
                        && !preparedRetirementKeys.contains(key))
                let tokenAllowsReserve: Bool
                if let retainedRecord {
                    tokenAllowsReserve = Self.snapshotRetentionContains(
                        reference.identity.tileID,
                        in: retainedRecord.sortedTileIDs
                    )
                } else {
                    tokenAllowsReserve = true
                }
                guard retirementAllowsReserve,
                      tokenAllowsReserve,
                      tileKeyByID[reference.identity.tileID] == key,
                      let record = records[key],
                      self.reference(key: key, record: record) == reference
                else {
                    if retainedRecord != nil {
                        throw PaintTileStoreError
                            .invalidSnapshotRetentionToken
                    }
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
                allocationBackings: requested.compactMap {
                    $0.1.texture == nil ? ($0.1.backing ?? .knownClear) : nil
                }
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
            let transferResult = try transfer(
                evicted: evicted,
                allocations: allocations
            )
            let captured = transferResult.captured
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
            installPersistentZeroSource(from: transferResult)
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
                if !removeRecordIfEligible(for: key), records[key] != nil {
                    pendingRetirementKeys.insert(key)
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
            for key in keys {
                preparedRetirementKeys.remove(key)
                if records[key]?.backing == .knownClear {
                    _ = removeRecordIfEligible(for: key)
                }
            }
            preparedRetirements.removeValue(forKey: plan.token)
        }
    }

    /// Preflights restoration of references whose prior registry retirement
    /// is pending behind the supplied exact snapshot token.
    func prepareReactivation(
        _ references: [PaintTileReference],
        retainedBy token: PaintTileSnapshotToken
    ) throws -> PaintTilePreparedReactivation? {
        guard !references.isEmpty else { return nil }
        return try withLock {
            guard token.storeIdentity == identity,
                  !token.isClosed,
                  let retained = snapshotRetentions[token.token],
                  retained.capabilityIdentity == ObjectIdentifier(token)
            else { throw PaintTileStoreError.invalidSnapshotRetentionToken }
            let requestedTileIDs = references.map(\.identity.tileID).sorted()
            var retainedIndex = 0
            for tileID in requestedTileIDs {
                while retainedIndex < retained.sortedTileIDs.count,
                      retained.sortedTileIDs[retainedIndex] < tileID
                {
                    retainedIndex += 1
                }
                guard retainedIndex < retained.sortedTileIDs.count,
                      retained.sortedTileIDs[retainedIndex] == tileID
                else {
                    throw PaintTileStoreError.invalidSnapshotRetentionToken
                }
            }
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
                guard pendingRetirementKeys.contains(key),
                      let record = records[key],
                      reference(key: key, record: record) == value
                else { throw PaintTileStoreError.staleTileReference }
            }
            return PaintTilePreparedReactivation(
                storeIdentity: identity,
                references: references,
                retentionToken: token
            )
        }
    }

    /// Nonthrowing terminal paired with `prepareReactivation`. The retained
    /// token is still live here, so every preflighted physical record must be
    /// present and pending retirement.
    func commitReactivation(_ plan: PaintTilePreparedReactivation) {
        precondition(plan.storeIdentity == identity)
        withLock {
            let token = plan.retentionToken
            precondition(!token.isClosed)
            precondition(
                snapshotRetentions[token.token]?.capabilityIdentity
                    == ObjectIdentifier(token)
            )
            for value in plan.references {
                let key = Key(
                    surfaceID: value.physicalSurfaceID,
                    layerID: value.layerID,
                    generation: value.physicalGeneration,
                    coordinate: value.coordinate
                )
                precondition(pendingRetirementKeys.remove(key) != nil)
                precondition(records[key].map {
                    reference(key: key, record: $0) == value
                } == true)
            }
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
                persistentZeroAllocationBytes: persistentZeroSource == nil
                    ? 0 : PaintTileDescriptor.residentByteCount,
                persistentZeroAllocationCount: persistentZeroAllocationCount,
                activeLeaseCount: leases.count,
                provisionalReservationCount:
                    provisionalReservations.reduce(into: 0) {
                        if $1 != nil { $0 += 1 }
                    },
                provisionalByteCount: provisionalByteCount,
                preparedRetirementCount: preparedRetirements.count,
                pendingRetirementCount: pendingRetirementKeys.count,
                tileIndexEntryCount: tileKeyByID.count,
                activeSnapshotTokenCount: snapshotRetentions.count,
                aggregateSnapshotReferenceCount:
                    aggregateSnapshotReferenceCount,
                snapshotMetadataByteCount: snapshotMetadataByteCount,
                snapshotPayloadDebtByteCount:
                    snapshotRetainedPayloadLiabilityByteCount,
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
            pinCounts: entry?.pinCounts.dictionary ?? [:],
            snapshotRetainCount: record.storage.snapshotRetainCount
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
                allocationBackings: []
            )
            let captured = try transfer(
                evicted: identities,
                allocations: []
            ).captured
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
            let newRecordCount = requested.reduce(into: 0) {
                if records[$1.0] == nil { $0 += 1 }
            }
            let nextIndexEntryCount = try checkedSnapshotSum(
                tileKeyByID.count,
                newRecordCount,
                limit: .indexEntries
            )
            try enforceSnapshotLimit(
                nextIndexEntryCount,
                maximum: snapshotRetentionLimits.maximumIndexEntryCount,
                limit: .indexEntries
            )
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

            let accounting = try transferAccounting(
                captureIdentities: evicted,
                allocationBackings: requested.compactMap {
                    guard records[$0.0]?.texture == nil else { return nil }
                    return records[$0.0]?.backing ?? .knownClear
                }
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

            let transferResult = try transfer(
                evicted: evicted,
                allocations: allocations
            )
            let captured = transferResult.captured
            let (leaseRawID, leaseOverflow) = nextLeaseID
                .addingReportingOverflow(1)
            guard !leaseOverflow else {
                throw PaintTileStoreError.leaseIdentityOverflow
            }
            let nextStateRevision = try advancedStateRevision()

            var stagedRecords = Self.cloneRecords(records)
            var stagedTileKeyByID = tileKeyByID
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
                    guard stagedTileKeyByID.updateValue(
                        allocation.key,
                        forKey: allocation.identity.tileID
                    ) == nil else {
                        preconditionFailure("Duplicate paint tile identity")
                    }
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
            tileKeyByID = stagedTileKeyByID
            residency = stagedResidency
            leases = stagedLeases
            nextTileID = stagedNextTileID
            nextLeaseID = leaseRawID
            stateRevision = nextStateRevision
            installPersistentZeroSource(from: transferResult)
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
        let coldLease = try reserveSortedUnique(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            pixelSize: pixelSize,
            coordinates: coordinates,
            pinReasons: pinReasons,
            failureInjection: failureInjection
        )
        return try adoptStrokeWorkspace(
            workspace,
            for: coldLease,
            surfaceID: surfaceID,
            currentGeneration: generation
        )
    }

    /// Transfers a cold transactional stroke reservation into the bounded
    /// workspace before publication. The ordinary reserve path must build an
    /// owned result while allocating missing Metal tiles, but retaining that
    /// value array through commit would force copy-on-write when candidate
    /// textures replace its entries. Stroke callers instead keep one mutable,
    /// pre-reserved owner for both cold and warm reservations.
    private func adoptStrokeWorkspace(
        _ workspace: PaintTileStrokeLeaseWorkspace,
        for lease: PaintTileLease,
        surfaceID: UUID,
        currentGeneration: UInt64
    ) throws -> PaintTileLease {
        try withLock {
            let record = try validate(
                lease,
                surfaceID: surfaceID,
                currentGeneration: currentGeneration
            )
            precondition(record.mixedNamespaceKeys == nil)
            try workspace.prepareForReservation()
            for index in 0..<lease.retainedBindingCount {
                let binding = lease.retainedBinding(at: index)
                workspace.identities.append(binding.identity)
                workspace.descriptors.append(binding.descriptor)
                workspace.textures.append(binding.texture)
            }
            workspace.isOutstanding = true
            leases[lease.id] = LeaseRecord(
                surfaceID: record.surfaceID,
                generation: record.generation,
                identityStorage: .strokeWorkspace(workspace),
                mixedNamespaceKeys: nil,
                pinReasons: record.pinReasons
            )
            return PaintTileLease(
                id: lease.id,
                surfaceID: lease.surfaceID,
                layerID: lease.layerID,
                generation: lease.generation,
                storeIdentity: lease.storeIdentity,
                pinReasons: lease.pinReasons,
                strokeWorkspace: workspace
            )
        }
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
            workspace.descriptors.append(record.descriptor)
            workspace.textures.append(texture)
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
            let persistentZeroBytes = persistentZeroSource == nil
                ? 0 : PaintTileDescriptor.residentByteCount
            let (residentAndPersistent, persistentOverflow) = residentBytes
                .addingReportingOverflow(persistentZeroBytes)
            let (residentAndProvisional, provisionalOverflow) = residentAndPersistent
                .addingReportingOverflow(provisionalByteCount)
            let (requiredBytes, requiredOverflow) = residentAndProvisional
                .addingReportingOverflow(allocationBytes)
            guard !allocationOverflow, !persistentOverflow,
                  !provisionalOverflow, !requiredOverflow,
                  requiredBytes <= transferByteCapacity
            else {
                throw PaintTileStoreError.transferCapacityExceeded(
                    requiredBytes: allocationOverflow || persistentOverflow
                        || provisionalOverflow || requiredOverflow
                        ? .max : requiredBytes,
                    capacityBytes: transferByteCapacity,
                    residentBytes: residentBytes,
                    allocationBytes: allocationOverflow
                        ? .max : allocationBytes,
                    persistentZeroBytes: persistentZeroBytes,
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
                    persistentZeroBytes: persistentZeroBytes,
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
                while leaseIndex < lease.retainedBindingCount,
                      lease.retainedBinding(at: leaseIndex)
                        .descriptor.coordinate
                        < candidate.descriptor.coordinate
                {
                    leaseIndex += 1
                }
                guard leaseIndex < lease.retainedBindingCount,
                      lease.retainedBinding(at: leaseIndex).identity
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
            if pendingRetirementKeys.contains(key) {
                _ = removeRecordIfEligible(for: key)
            } else if !preparedRetirementKeys.contains(key),
                      records[key]?.backing == .knownClear {
                _ = removeRecordIfEligible(for: key)
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
                    allocationBackings: []
                )
                let captured = try transfer(
                    evicted: evicted,
                    allocations: []
                ).captured
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
            namespaceRetirementKeys.removeAll(keepingCapacity: true)
            defer {
                namespaceRetirementKeys.removeAll(keepingCapacity: true)
            }
            for key in records.keys
            where key.surfaceID == surfaceID && key.generation == generation {
                namespaceRetirementKeys.append(key)
            }
            guard !namespaceRetirementKeys.isEmpty else { return }
            try preflightStrokeActiveRetirement(
                for: namespaceRetirementKeys
            )
            let nextRevision = try advancedStateRevision()
            try clearStrokeActivePinsPreflighted(
                for: namespaceRetirementKeys
            )
            for key in namespaceRetirementKeys {
                if !removeRecordIfEligible(for: key), records[key] != nil {
                    pendingRetirementKeys.insert(key)
                }
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
            namespaceRetirementKeys.removeAll(keepingCapacity: true)
            defer {
                namespaceRetirementKeys.removeAll(keepingCapacity: true)
            }
            for key in records.keys
            where key.generation == generation
                && (key.surfaceID == authoritativeSurfaceID
                    || key.surfaceID == predictionSurfaceID)
            {
                namespaceRetirementKeys.append(key)
            }
            guard !namespaceRetirementKeys.isEmpty else { return }
            try preflightStrokeActiveRetirement(
                for: namespaceRetirementKeys
            )
            let nextRevision = try advancedStateRevision()
            try clearStrokeActivePinsPreflighted(
                for: namespaceRetirementKeys
            )
            for key in namespaceRetirementKeys {
                if !removeRecordIfEligible(for: key), records[key] != nil {
                    pendingRetirementKeys.insert(key)
                }
            }
            stateRevision = nextRevision
        }
    }

    /// Stroke publication owns one persistent `.active` pin per modified
    /// physical tile. Namespace retirement is the terminal owner of those
    /// pins, so validate the complete set before mutating either surface.
    private func preflightStrokeActiveRetirement(
        for keys: [Key]
    ) throws {
        for key in keys {
            guard let record = records[key], record.storage.isStrokeActive
            else { continue }
            guard residency.pinCount(record.identity, reason: .active) == 1
            else {
                throw PaintTileResidencyError.unbalancedUnpin(reason: .active)
            }
        }
    }

    /// Applies the already-preflighted terminal ownership transfer. The store
    /// lock prevents pin state from changing between preflight and mutation.
    private func clearStrokeActivePinsPreflighted(
        for keys: [Key]
    ) throws {
        for key in keys {
            guard let record = records[key], record.storage.isStrokeActive
            else { continue }
            try residency.unpin(record.identity, reason: .active)
            record.storage.isStrokeActive = false
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
              record.identityStorage.elementsEqual(lease),
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

    /// The sole physical-record deletion primitive. Retirement intent and the
    /// prepared barrier are managed by callers; deletion itself is possible
    /// only after both lease pins and snapshot ownership reach zero.
    @discardableResult
    private func removeRecordIfEligible(for key: Key) -> Bool {
        guard let record = records[key],
              !residency.isPinned(record.identity),
              record.storage.snapshotRetainCount == 0
        else { return false }
        records.removeValue(forKey: key)
        guard tileKeyByID.removeValue(forKey: record.identity.tileID) == key
        else { preconditionFailure("Paint tile identity index drift") }
        residency.remove(record.identity)
        pendingRetirementKeys.remove(key)
        return true
    }

    /// Binary-searches the compact authoritative membership payload. The
    /// counted overload is a lock-free structural test seam: each count is
    /// one inspected candidate, so a maximum-size token can prove O(log R)
    /// admission without timing a contended store lock.
    static func snapshotRetentionContains(
        _ tileID: PaintTileID,
        in sortedTileIDs: [PaintTileID]
    ) -> Bool {
        var ignoredProbeCount = 0
        return snapshotRetentionContains(
            tileID,
            in: sortedTileIDs,
            comparisonCount: &ignoredProbeCount
        )
    }

    static func snapshotRetentionContains(
        _ tileID: PaintTileID,
        in sortedTileIDs: [PaintTileID],
        comparisonCount: inout Int
    ) -> Bool {
        var lowerBound = 0
        var upperBound = sortedTileIDs.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            comparisonCount += 1
            let candidate = sortedTileIDs[middle]
            if candidate == tileID { return true }
            if candidate < tileID {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return false
    }

    private func checkedSnapshotSum(
        _ lhs: Int,
        _ rhs: Int,
        limit: PaintTileSnapshotRetentionLimit
    ) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw PaintTileStoreError.snapshotRetentionArithmeticOverflow(
                limit
            )
        }
        return result
    }

    private func checkedSnapshotProduct(
        _ lhs: Int,
        _ rhs: Int,
        limit: PaintTileSnapshotRetentionLimit
    ) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw PaintTileStoreError.snapshotRetentionArithmeticOverflow(
                limit
            )
        }
        return result
    }

    private func enforceSnapshotLimit(
        _ required: Int,
        maximum: Int,
        limit: PaintTileSnapshotRetentionLimit
    ) throws {
        guard required <= maximum else {
            throw PaintTileStoreError.snapshotRetentionLimitExceeded(
                limit: limit,
                required: required,
                maximum: maximum
            )
        }
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
        allocationBackings: [PaintTileBackingSnapshot]
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
            allocationBackings.count,
            PaintTileDescriptor.residentByteCount
        )
        let uploadCount = allocationBackings.reduce(into: 0) {
            if case .rgba16Float = $1 { $0 += 1 }
        }
        let uploadBytes = try checkedMultiply(
            uploadCount,
            PaintTileDescriptor.residentByteCount
        )
        let needsPersistentZeroSource = allocationBackings.contains {
            switch $0 {
            case .knownClear, .residentOnly: true
            case .rgba16Float: false
            }
        }
        let existingPersistentZeroBytes = persistentZeroSource == nil
            ? 0 : PaintTileDescriptor.residentByteCount
        let persistentZeroAllocationBytes =
            needsPersistentZeroSource && persistentZeroSource == nil
                ? PaintTileDescriptor.residentByteCount : 0
        let persistentZeroAllocationCount =
            persistentZeroAllocationBytes == 0 ? 0 : 1
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
            residentBytes,
            allocatedBytes,
            existingPersistentZeroBytes,
            persistentZeroAllocationBytes,
            stagingBytes,
        ])
        guard peakBytes <= transferByteCapacity else {
            let persistentZeroBytes = try checkedSum([
                existingPersistentZeroBytes,
                persistentZeroAllocationBytes,
            ])
            throw PaintTileStoreError.transferCapacityExceeded(
                requiredBytes: peakBytes,
                capacityBytes: transferByteCapacity,
                residentBytes: residentBytes,
                allocationBytes: allocatedBytes,
                persistentZeroBytes: persistentZeroBytes,
                stagingBytes: stagingBytes
            )
        }
        return PaintTileTransferAccounting(
            residentTextureBytesBefore: residentBytes,
            allocatedTextureBytes: allocatedBytes,
            persistentZeroAllocationBytes: persistentZeroAllocationBytes,
            persistentZeroAllocationCount: persistentZeroAllocationCount,
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
    ) throws -> TransferResult {
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
            return TransferResult(
                captured: captured,
                newlyAllocatedPersistentZeroSource: nil
            )
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
        let needsPersistentZeroSource = allocations.contains {
            switch $0.sourceBacking {
            case .knownClear, .residentOnly: true
            case .rgba16Float: false
            }
        }
        var newlyAllocatedPersistentZeroSource: (any MTLBuffer)?
        if needsPersistentZeroSource, persistentZeroSource == nil {
            guard let source = device.makeBuffer(
                length: imageBytes,
                options: .storageModeShared
            ) else {
                throw PaintTileStoreError.stagingBufferAllocationFailed
            }
            source.contents().initializeMemory(
                as: UInt8.self,
                repeating: 0,
                count: imageBytes
            )
            newlyAllocatedPersistentZeroSource = source
        }
        var transientSourceBuffers: [any MTLBuffer] = []
        transientSourceBuffers.reserveCapacity(allocations.count)
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
                source = persistentZeroSource
                    ?? newlyAllocatedPersistentZeroSource
            }
            guard let source else {
                throw PaintTileStoreError.stagingBufferAllocationFailed
            }
            if case .rgba16Float = allocation.sourceBacking {
                transientSourceBuffers.append(source)
            }
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
        _ = transientSourceBuffers
        return TransferResult(
            captured: captured,
            newlyAllocatedPersistentZeroSource:
                newlyAllocatedPersistentZeroSource
        )
    }

    private func installPersistentZeroSource(from result: TransferResult) {
        guard persistentZeroSource == nil,
              let source = result.newlyAllocatedPersistentZeroSource
        else { return }
        persistentZeroSource = source
        persistentZeroAllocationCount = 1
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
