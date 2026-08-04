import Foundation
import Metal
import PatternEngine
import simd

enum SparseTileSamplingPlanError: Error, Equatable, Sendable {
    case invalidOutputRegion
    case invalidLimit
    case arithmeticOverflow
    case unsortedChangedCoordinates
    case duplicateChangedCoordinate(PaintTileCoordinate)
    case unsortedReference
    case duplicateReference(PaintTileCoordinate)
    case foreignReference(PaintTileReference)
    case contentRoleMismatch
    case sourceOrderMismatch
    case duplicateSource(layerID: UUID, role: SparseTileSampleRole)
    case duplicateLayer(UUID)
    case sourceLayerMismatch(expected: UUID, actual: UUID)
    case sourceGenerationMismatch(expected: UInt64, actual: UInt64)
    case sourcePixelSizeMismatch
    case inconsistentAddressing
    case contentKeyMismatch
    case pageEntryLimitExceeded(required: Int, maximum: Int)
    case pageChunkLimitExceeded(required: Int, maximum: Int)
    case pageTableByteLimitExceeded(required: Int, maximum: Int)
    case bindingSlotLimitExceeded(required: Int, maximum: Int)
    case bindingChunkLimitExceeded(required: Int, maximum: Int)
    case bindingByteLimitExceeded(required: Int, maximum: Int)
    case batchLimitExceeded(required: Int, maximum: Int)
    case onePixelBatchExceedsTextureLimit(required: Int, maximum: Int)
    case missingBinding(PaintTileReference)
    case bindingCountMismatch(references: Int, bindings: Int)
    case slotOwnerIdentityOverflow
    case staleSlotOwner
    case missingPageTable(layerID: UUID, role: SparseTileSampleRole)
    case nonFiniteSamplePoint
    case invalidOutputToSourceTransform
    case contentKeyCollision
    case consumerIdentityOverflow
    case leaseRetirementRequested
    case staleConsumer
    case leaseAlreadyRetired
}

enum SparseTileSampleRole: UInt8, CaseIterable, Hashable, Sendable {
    case canonical
    case authoritative
    case prediction
}

enum SparseTileAddressing: Equatable, Sendable {
    case finite(PixelSize)
    case periodic(period: PixelSize)
    case radial(layout: RadialSectorLayout)
}

/// Immutable axis-aligned mapping from target-local pixel centers into sparse
/// source pixel-center space. `sourceOffset` is relative to the P3 output
/// region's minimum; this keeps `.identity` correct for signed/nonzero regions.
struct SparseTileOutputToSourceTransform: Equatable, Hashable, Sendable {
    let sourceOffset: SIMD2<Float>
    let sourceStep: SIMD2<Float>

    static let identity = SparseTileOutputToSourceTransform(
        sourceOffset: .zero,
        sourceStep: SIMD2(repeating: 1)
    )

    fileprivate func shaderSourceOrigin(
        outputRegion: SparseTileOutputRegion
    ) throws -> SIMD2<Float> {
        let root = SIMD2(Float(outputRegion.minX), Float(outputRegion.minY))
        guard root.x.isFinite, root.y.isFinite,
              Double(root.x) == Double(outputRegion.minX),
              Double(root.y) == Double(outputRegion.minY),
              sourceOffset.x.isFinite, sourceOffset.y.isFinite,
              sourceStep.x.isFinite, sourceStep.y.isFinite
        else {
            throw SparseTileSamplingPlanError.invalidOutputToSourceTransform
        }
        let origin = root + sourceOffset
        guard origin.x.isFinite, origin.y.isFinite else {
            throw SparseTileSamplingPlanError.invalidOutputToSourceTransform
        }
        return origin
    }
}

struct SparseTileRoleContentKey: Hashable, Sendable {
    let role: SparseTileSampleRole
    let contentRevision: UInt64
    let bindingChunkRevision: UInt64
}

struct SparseTileLayerContentKey: Hashable, Sendable {
    let layerID: UUID
    let roles: [SparseTileRoleContentKey]
}

struct SparseTileSamplingPlanKey: Hashable, Sendable {
    let documentGeneration: UInt64
    let orderedLayers: [SparseTileLayerContentKey]
    let addressingRevision: UInt64
    let outputGeometryRevision: UInt64
    let outputToSourceTransform: SparseTileOutputToSourceTransform

    init(
        documentGeneration: UInt64,
        orderedLayers: [SparseTileLayerContentKey],
        addressingRevision: UInt64,
        outputGeometryRevision: UInt64,
        outputToSourceTransform: SparseTileOutputToSourceTransform = .identity
    ) {
        self.documentGeneration = documentGeneration
        self.orderedLayers = orderedLayers
        self.addressingRevision = addressingRevision
        self.outputGeometryRevision = outputGeometryRevision
        self.outputToSourceTransform = outputToSourceTransform
    }
}

enum SparseTileSourceDisposition: Equatable, Sendable {
    case fullSnapshot
    case delta
}

struct SparseTileSourceRequest: @unchecked Sendable {
    let contentKey: SparseTileRoleContentKey
    let addressing: SparseTileAddressing
    let surface: TiledRasterSurface
    /// Exact immutable visible set captured at adaptation time. The mutable
    /// surface remains only as the owner used to lease these exact references.
    let references: [PaintTileReference]
    let changedCoordinates: [PaintTileCoordinate]
    let disposition: SparseTileSourceDisposition

    init(
        contentKey: SparseTileRoleContentKey,
        addressing: SparseTileAddressing,
        surface: TiledRasterSurface,
        changedCoordinates: [PaintTileCoordinate],
        disposition: SparseTileSourceDisposition
    ) throws {
        for index in changedCoordinates.indices.dropFirst() {
            let previous = changedCoordinates[index - 1]
            let current = changedCoordinates[index]
            if previous == current {
                throw SparseTileSamplingPlanError
                    .duplicateChangedCoordinate(current)
            }
            guard previous < current else {
                throw SparseTileSamplingPlanError.unsortedChangedCoordinates
            }
        }
        self.contentKey = contentKey
        self.addressing = addressing
        self.surface = surface
        references = surface.references
        self.changedCoordinates = changedCoordinates
        self.disposition = disposition
    }

    var role: SparseTileSampleRole { contentKey.role }
    var layerID: UUID { surface.layerID }
}

/// Immutable, normalized metadata used to construct reusable plan content.
/// It intentionally contains no texture or lifetime ownership.
struct SparseTileSourceSnapshot: Sendable {
    let contentKey: SparseTileRoleContentKey
    let addressing: SparseTileAddressing
    let layerID: UUID
    let references: [PaintTileReference]
    let changedCoordinates: [PaintTileCoordinate]
    let disposition: SparseTileSourceDisposition

    init(
        contentKey: SparseTileRoleContentKey,
        addressing: SparseTileAddressing,
        layerID: UUID,
        references: [PaintTileReference],
        changedCoordinates: [PaintTileCoordinate],
        disposition: SparseTileSourceDisposition
    ) throws {
        for index in references.indices {
            let reference = references[index]
            guard reference.layerID == layerID,
                  reference.identity.layerID == layerID,
                  reference.identity.coordinate == reference.coordinate
            else {
                throw SparseTileSamplingPlanError.foreignReference(reference)
            }
            if index > references.startIndex {
                let previous = references[index - 1]
                if previous.coordinate == reference.coordinate {
                    throw SparseTileSamplingPlanError
                        .duplicateReference(reference.coordinate)
                }
                guard previous.coordinate < reference.coordinate else {
                    throw SparseTileSamplingPlanError.unsortedReference
                }
                guard previous.storeIdentity == reference.storeIdentity,
                      previous.physicalSurfaceID == reference.physicalSurfaceID,
                      previous.physicalGeneration == reference.physicalGeneration
                else {
                    throw SparseTileSamplingPlanError.foreignReference(reference)
                }
            }
        }
        for index in changedCoordinates.indices.dropFirst() {
            let previous = changedCoordinates[index - 1]
            let current = changedCoordinates[index]
            if previous == current {
                throw SparseTileSamplingPlanError
                    .duplicateChangedCoordinate(current)
            }
            guard previous < current else {
                throw SparseTileSamplingPlanError.unsortedChangedCoordinates
            }
        }
        self.contentKey = contentKey
        self.addressing = addressing
        self.layerID = layerID
        self.references = references
        self.changedCoordinates = changedCoordinates
        self.disposition = disposition
    }

    var role: SparseTileSampleRole { contentKey.role }
}

struct SparseTileOutputRegion: Equatable, Sendable {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int
    let width: Int
    let height: Int

    init(minX: Int, minY: Int, maxX: Int, maxY: Int) throws {
        guard maxX > minX, maxY > minY else {
            throw SparseTileSamplingPlanError.invalidOutputRegion
        }
        let (width, widthOverflow) = maxX.subtractingReportingOverflow(minX)
        let (height, heightOverflow) = maxY.subtractingReportingOverflow(minY)
        guard !widthOverflow, !heightOverflow else {
            throw SparseTileSamplingPlanError.arithmeticOverflow
        }
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
        self.width = width
        self.height = height
    }
}

struct SparseTilePlanLimits: Equatable, Sendable {
    let maximumPageEntries: Int
    let maximumPageChunks: Int
    let maximumPageTableBytes: Int
    let maximumBindingSlots: Int
    let maximumBindingChunks: Int
    let maximumBindingBytes: Int
    let maximumTexturesPerBatch: Int
    let maximumBatchCount: Int

    init(
        maximumPageEntries: Int,
        maximumPageChunks: Int,
        maximumPageTableBytes: Int,
        maximumBindingSlots: Int,
        maximumBindingChunks: Int,
        maximumBindingBytes: Int,
        maximumTexturesPerBatch: Int,
        maximumBatchCount: Int
    ) {
        self.maximumPageEntries = maximumPageEntries
        self.maximumPageChunks = maximumPageChunks
        self.maximumPageTableBytes = maximumPageTableBytes
        self.maximumBindingSlots = maximumBindingSlots
        self.maximumBindingChunks = maximumBindingChunks
        self.maximumBindingBytes = maximumBindingBytes
        self.maximumTexturesPerBatch = maximumTexturesPerBatch
        self.maximumBatchCount = maximumBatchCount
    }

    fileprivate var allValues: [Int] {
        [
            maximumPageEntries, maximumPageChunks, maximumPageTableBytes,
            maximumBindingSlots, maximumBindingChunks, maximumBindingBytes,
            maximumTexturesPerBatch, maximumBatchCount,
        ]
    }
}

struct SparseTilePageEntry: Equatable, Sendable {
    let globalBindingSlot: Int
    let logicalOrigin: SIMD2<Int>
    let physicalOrigin: SIMD2<Int>
    let localBounds: PixelRect

    var isMissing: Bool { globalBindingSlot < 0 }
}

final class SparseTilePageTableChunk: @unchecked Sendable {
    let entries: [SparseTilePageEntry]
    init(entries: [SparseTilePageEntry]) { self.entries = entries }
}

struct SparseTilePageTable: Sendable {
    static let chunkCapacity = 64

    let layerID: UUID
    let role: SparseTileSampleRole
    let origin: PaintTileCoordinate
    let size: PixelSize
    let entryCount: Int
    let chunks: [SparseTilePageTableChunk]

    func entry(at coordinate: PaintTileCoordinate) -> SparseTilePageEntry? {
        let (x, xOverflow) = coordinate.x.subtractingReportingOverflow(origin.x)
        let (y, yOverflow) = coordinate.y.subtractingReportingOverflow(origin.y)
        guard !xOverflow, !yOverflow else { return nil }
        guard x >= 0, y >= 0, x < size.width, y < size.height else {
            return nil
        }
        let (row, rowOverflow) = y.multipliedReportingOverflow(by: size.width)
        let (index, indexOverflow) = row.addingReportingOverflow(x)
        guard !rowOverflow, !indexOverflow else { return nil }
        let chunk = index / Self.chunkCapacity
        let offset = index % Self.chunkCapacity
        guard chunk < chunks.count, offset < chunks[chunk].entries.count else {
            return nil
        }
        return chunks[chunk].entries[offset]
    }
}

struct SparseTileBindingRecord: Hashable, Sendable {
    let globalSlot: Int
    let layerID: UUID
    let role: SparseTileSampleRole
    let reference: PaintTileReference
}

final class SparseTileBindingChunk: @unchecked Sendable {
    let layerID: UUID
    let role: SparseTileSampleRole
    let records: [SparseTileBindingRecord]
    init(
        layerID: UUID,
        role: SparseTileSampleRole,
        records: [SparseTileBindingRecord]
    ) {
        self.layerID = layerID
        self.role = role
        self.records = records
    }
}

struct SparseTileBindingBatch: Equatable, Sendable {
    let outputRegion: SparseTileOutputRegion
    let globalSlots: [Int]
    let compactRemap: [Int: Int]
}

struct SparseTilePlanTelemetry: Equatable, Sendable {
    let rebuiltPageEntryCount: Int
    let rebuiltBindingCount: Int
}

final class SparseTileSamplingPlanContent: @unchecked Sendable {
    let key: SparseTileSamplingPlanKey
    let addressing: SparseTileAddressing
    let pageTables: [SparseTilePageTable]
    let bindingRecords: [SparseTileBindingRecord]
    let bindingChunks: [SparseTileBindingChunk]
    let batches: [SparseTileBindingBatch]
    let telemetry: SparseTilePlanTelemetry
    let outputToSourceTransform: SparseTileOutputToSourceTransform
    let shaderSourceOrigin: SIMD2<Float>
    fileprivate let sourceFingerprints: [SparseTileSourceFingerprint]
    fileprivate let outputRegion: SparseTileOutputRegion
    private let recordsBySlot: [Int: SparseTileBindingRecord]

    fileprivate init(
        key: SparseTileSamplingPlanKey,
        addressing: SparseTileAddressing,
        pageTables: [SparseTilePageTable],
        bindingRecords: [SparseTileBindingRecord],
        bindingChunks: [SparseTileBindingChunk],
        batches: [SparseTileBindingBatch],
        telemetry: SparseTilePlanTelemetry,
        outputToSourceTransform: SparseTileOutputToSourceTransform,
        shaderSourceOrigin: SIMD2<Float>,
        sourceFingerprints: [SparseTileSourceFingerprint],
        outputRegion: SparseTileOutputRegion
    ) {
        self.key = key
        self.addressing = addressing
        self.pageTables = pageTables
        self.bindingRecords = bindingRecords
        self.bindingChunks = bindingChunks
        self.batches = batches
        self.telemetry = telemetry
        self.outputToSourceTransform = outputToSourceTransform
        self.shaderSourceOrigin = shaderSourceOrigin
        self.sourceFingerprints = sourceFingerprints
        self.outputRegion = outputRegion
        recordsBySlot = Dictionary(
            uniqueKeysWithValues: bindingRecords.map { ($0.globalSlot, $0) }
        )
    }

    func pageTable(
        layerID: UUID,
        role: SparseTileSampleRole
    ) -> SparseTilePageTable? {
        pageTables.first { $0.layerID == layerID && $0.role == role }
    }

    func bindingRecord(at slot: Int) -> SparseTileBindingRecord? {
        recordsBySlot[slot]
    }

    fileprivate func matches(
        slotAssignments: [SparseTileRecordCoordinateKey: Int]
    ) -> Bool {
        guard bindingRecords.count == slotAssignments.count else { return false }
        return bindingRecords.allSatisfy {
            slotAssignments[SparseTileRecordCoordinateKey(
                layerID: $0.layerID,
                role: $0.role,
                coordinate: $0.reference.coordinate
            )] == $0.globalSlot
        }
    }
}

private struct SparseTileSourceFingerprint: Equatable, Sendable {
    let layerID: UUID
    let contentKey: SparseTileRoleContentKey
    let addressing: SparseTileAddressing
    let references: [PaintTileReference]
}

struct SparseTileBoundTexture: @unchecked Sendable {
    let globalSlot: Int
    let texture: any MTLTexture
}

private struct SparseTileHeldLease {
    let surface: TiledRasterSurface
    let lease: PaintTileLease
}

final class SparseTileSamplingPlanConsumerHandle: @unchecked Sendable {
    fileprivate let rawValue: UInt64

    private let lock = NSLock()
    private var owner: SparseTileSamplingPlanLease?
    private var acknowledged = false
    private var completionInProgress = false

    fileprivate init(rawValue: UInt64, owner: SparseTileSamplingPlanLease) {
        self.rawValue = rawValue
        self.owner = owner
    }

    func complete() throws {
        lock.lock()
        guard let owner else {
            lock.unlock()
            throw SparseTileSamplingPlanError.staleConsumer
        }
        lock.unlock()
        try complete(using: owner)
    }

    fileprivate func complete(using expectedOwner: SparseTileSamplingPlanLease)
        throws
    {
        let owner: SparseTileSamplingPlanLease
        let needsAcknowledgement: Bool
        lock.lock()
        guard let retainedOwner = self.owner, retainedOwner === expectedOwner,
              !completionInProgress
        else {
            lock.unlock()
            throw SparseTileSamplingPlanError.staleConsumer
        }
        completionInProgress = true
        owner = retainedOwner
        needsAcknowledgement = !acknowledged
        lock.unlock()

        do {
            if needsAcknowledgement {
                try owner.acknowledgeConsumer(rawValue)
                lock.lock()
                acknowledged = true
                lock.unlock()
            }
            try owner.retryRetirementIfReady()
            lock.lock()
            self.owner = nil
            completionInProgress = false
            lock.unlock()
        } catch {
            lock.lock()
            completionInProgress = false
            lock.unlock()
            throw error
        }
    }

    deinit {
        lock.lock()
        guard let owner, !completionInProgress else {
            lock.unlock()
            return
        }
        let needsAcknowledgement = !acknowledged
        completionInProgress = true
        lock.unlock()
        if needsAcknowledgement { try? owner.acknowledgeConsumer(rawValue) }
        try? owner.retryRetirementIfReady()
    }
}

typealias SparseTileLeaseReturner = @Sendable (
    TiledRasterSurface, PaintTileLease
) throws -> Void

/// Cache-owned retirement state. It deliberately outlives the public lease:
/// failed store returns remain pinned and retryable instead of being forgotten
/// by a deinitializer that cannot throw.
private final class SparseTileLeaseRetirementCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var heldLeases: [SparseTileHeldLease]
    private var retirementRequested = false
    private var retirementInProgress = false
    private var completed = false
    private let returnLease: SparseTileLeaseReturner
    private let onFullyReturned: @Sendable () throws -> Void

    init(
        heldLeases: [SparseTileHeldLease],
        returnLease: @escaping SparseTileLeaseReturner,
        onFullyReturned: @escaping @Sendable () throws -> Void
    ) {
        self.heldLeases = heldLeases
        self.returnLease = returnLease
        self.onFullyReturned = onFullyReturned
    }

    func requestRetirement() throws -> Bool {
        lock.lock()
        retirementRequested = true
        lock.unlock()
        return try retryIfRequested()
    }

    func retryIfRequested() throws -> Bool {
        lock.lock()
        if completed {
            lock.unlock()
            return true
        }
        guard retirementRequested, !retirementInProgress else {
            lock.unlock()
            return false
        }
        retirementInProgress = true
        lock.unlock()

        do {
            while true {
                lock.lock()
                let value = heldLeases.last
                lock.unlock()
                guard let value else { break }

                try returnLease(value.surface, value.lease)
                lock.lock()
                guard heldLeases.last?.lease.id == value.lease.id else {
                    retirementInProgress = false
                    lock.unlock()
                    throw SparseTileSamplingPlanError.staleConsumer
                }
                heldLeases.removeLast()
                lock.unlock()
            }

            // The cache callback runs after the coordinator lock is released.
            // It removes exactly this opaque owner and cannot ABA-reuse it.
            try onFullyReturned()
            lock.lock()
            completed = true
            retirementInProgress = false
            lock.unlock()
            return true
        } catch {
            lock.lock()
            retirementInProgress = false
            lock.unlock()
            throw error
        }
    }
}

final class SparseTileSamplingPlanLease: @unchecked Sendable {
    let content: SparseTileSamplingPlanContent
    let boundTextures: [SparseTileBoundTexture]

    private let lock = NSLock()
    private var consumers: Set<UInt64> = []
    private var nextConsumerID: UInt64 = 0
    private var retirementRequested = false
    private var retirementCompleted = false
    private let retirement: SparseTileLeaseRetirementCoordinator

    fileprivate init(
        content: SparseTileSamplingPlanContent,
        boundTextures: [SparseTileBoundTexture],
        retirement: SparseTileLeaseRetirementCoordinator
    ) {
        self.content = content
        self.boundTextures = boundTextures
        self.retirement = retirement
    }

    func retire() throws {
        lock.lock()
        guard !retirementCompleted else {
            lock.unlock()
            throw SparseTileSamplingPlanError.leaseAlreadyRetired
        }
        retirementRequested = true
        lock.unlock()
        try retryRetirementIfReady()
    }

    func beginConsumer() throws -> SparseTileSamplingPlanConsumerHandle {
        lock.lock()
        defer { lock.unlock() }
        guard !retirementRequested, !retirementCompleted else {
            throw SparseTileSamplingPlanError.leaseRetirementRequested
        }
        guard nextConsumerID < UInt64.max else {
            throw SparseTileSamplingPlanError.consumerIdentityOverflow
        }
        nextConsumerID += 1
        consumers.insert(nextConsumerID)
        return SparseTileSamplingPlanConsumerHandle(
            rawValue: nextConsumerID,
            owner: self
        )
    }

    func completeConsumer(_ handle: SparseTileSamplingPlanConsumerHandle) throws {
        try handle.complete(using: self)
    }

    fileprivate func acknowledgeConsumer(_ consumerID: UInt64) throws {
        lock.lock()
        guard consumers.remove(consumerID) != nil else {
            lock.unlock()
            throw SparseTileSamplingPlanError.staleConsumer
        }
        lock.unlock()
    }

    fileprivate func retryRetirementIfReady() throws {
        lock.lock()
        guard retirementRequested, consumers.isEmpty, !retirementCompleted else {
            lock.unlock()
            return
        }
        lock.unlock()
        let completed = try retirement.requestRetirement()
        if completed {
            lock.lock()
            retirementCompleted = true
            lock.unlock()
        }
    }

    deinit {
        lock.lock()
        retirementRequested = true
        consumers.removeAll(keepingCapacity: false)
        lock.unlock()
        _ = try? retirement.requestRetirement()
    }
}

private struct SparseTileSlotOwnerID: Hashable, Sendable {
    let rawValue: UInt64
}

private struct SparseTileLiveSlotEntry {
    let slot: Int
    var owners: Set<SparseTileSlotOwnerID>
}

private enum SparseTileSlotOwnerState: Equatable {
    case pending
    case live
}

private struct SparseTileSlotOwnerRecord {
    let generation: UInt64
    let generationEpoch: SparseTileGenerationEpoch
    let coordinateKeys: [SparseTileRecordCoordinateKey]
    var state: SparseTileSlotOwnerState
}

private final class SparseTileGenerationEpoch: @unchecked Sendable {}

private struct SparseTilePendingSlotReservation {
    let ownerID: SparseTileSlotOwnerID
    let assignments: [SparseTileRecordCoordinateKey: Int]
}

final class SparseTileSamplingPlanCache: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [SparseTileSamplingPlanKey: SparseTileSamplingPlanContent]
        = [:]
    private var liveSlots: [UInt64:
        [SparseTileRecordCoordinateKey: SparseTileLiveSlotEntry]] = [:]
    private var generationEpochs: [UInt64: SparseTileGenerationEpoch] = [:]
    private var slotOwners: [SparseTileSlotOwnerID: SparseTileSlotOwnerRecord]
        = [:]
    private var retirements: [SparseTileSlotOwnerID:
        SparseTileLeaseRetirementCoordinator] = [:]
    private var nextSlotOwnerID: UInt64 = 1
    private let returnLease: SparseTileLeaseReturner
    private let afterSlotReservation: @Sendable () -> Void

    init(
        returnLease: @escaping SparseTileLeaseReturner = { surface, lease in
            try surface.returnLease(lease)
        },
        afterSlotReservation: @escaping @Sendable () -> Void = {}
    ) {
        self.returnLease = returnLease
        self.afterSlotReservation = afterSlotReservation
    }

    func acquire(
        key: SparseTileSamplingPlanKey,
        sources: [SparseTileSourceRequest],
        outputRegion: SparseTileOutputRegion,
        limits: SparseTilePlanLimits,
        updating previous: SparseTileSamplingPlanContent? = nil
    ) throws -> SparseTileSamplingPlanLease {
        try Self.validate(key: key, sources: sources, limits: limits)
        let metadata = try sources.map {
            try SparseTileSourceSnapshot(
                contentKey: $0.contentKey,
                addressing: $0.addressing,
                layerID: $0.layerID,
                references: $0.references,
                changedCoordinates: $0.changedCoordinates,
                disposition: $0.disposition
            )
        }

        let cachedBeforeBuild: SparseTileSamplingPlanContent?
        let reservation: SparseTilePendingSlotReservation
        lock.lock()
        do {
            cachedBeforeBuild = contents[key]
            if let cachedBeforeBuild {
                guard cachedBeforeBuild.sourceFingerprints == metadata.fingerprints,
                      cachedBeforeBuild.outputRegion == outputRegion
                else {
                    throw SparseTileSamplingPlanError.contentKeyCollision
                }
            }
            reservation = try reserveSlotsLocked(
                generation: key.documentGeneration,
                sources: metadata,
                maximum: min(limits.maximumBindingSlots, 512),
                previous: previous
            )
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        afterSlotReservation()

        let candidate: SparseTileSamplingPlanContent
        if let cachedBeforeBuild,
           cachedBeforeBuild.matches(slotAssignments: reservation.assignments),
           Self.content(cachedBeforeBuild, satisfies: limits) {
            candidate = cachedBeforeBuild
        } else {
            do {
                candidate = try SparseTileSamplingPlanBuilder.buildFull(
                    key: key,
                    sources: metadata,
                    outputRegion: outputRegion,
                    limits: limits,
                    previous: cachedBeforeBuild ?? previous,
                    slotAssignments: reservation.assignments
                )
            } catch {
                try? cancelSlotOwner(reservation.ownerID)
                throw error
            }
        }

        var held: [SparseTileHeldLease] = []
        var acquired: [(request: SparseTileSourceRequest,
                        references: [PaintTileReference],
                        bindings: [PaintTileBinding])] = []
        var installedCandidate = false
        var displacedContent: SparseTileSamplingPlanContent?
        do {
            try ensureSlotOwnerCurrent(reservation.ownerID)
            for (request, snapshot) in zip(sources, metadata) {
                let references = snapshot.references
                if references.isEmpty {
                    acquired.append((request, [], []))
                    continue
                }
                let lease = try request.surface.leaseExistingTiles(
                    at: references.map(\.coordinate),
                    pinReasons: [.visible, .inFlight]
                )
                held.append(.init(surface: request.surface, lease: lease))
                acquired.append((request, references, lease.bindings))
            }

            let selected: SparseTileSamplingPlanContent
            lock.lock()
            do {
                try ensureSlotOwnerCurrentLocked(reservation.ownerID)
                if let raced = contents[key] {
                    guard raced.sourceFingerprints == metadata.fingerprints,
                          raced.outputRegion == outputRegion
                    else {
                        throw SparseTileSamplingPlanError.contentKeyCollision
                    }
                    if raced.matches(slotAssignments: reservation.assignments),
                       Self.content(raced, satisfies: limits) {
                        selected = raced
                    } else {
                        displacedContent = raced
                        contents[key] = candidate
                        installedCandidate = true
                        selected = candidate
                    }
                } else {
                    contents[key] = candidate
                    installedCandidate = true
                    selected = candidate
                }
                lock.unlock()
            } catch {
                lock.unlock()
                throw error
            }

            let textures = try Self.boundTextures(
                content: selected,
                acquired: acquired
            )
            let retirement = SparseTileLeaseRetirementCoordinator(
                heldLeases: held,
                returnLease: returnLease,
                onFullyReturned: { [self] in
                    try finishRetirement(reservation.ownerID)
                }
            )
            try publishSlotOwner(reservation.ownerID, retirement: retirement)
            return SparseTileSamplingPlanLease(
                content: selected,
                boundTextures: textures,
                retirement: retirement
            )
        } catch {
            if installedCandidate {
                lock.lock()
                if contents[key] === candidate {
                    if let displacedContent {
                        contents[key] = displacedContent
                    } else {
                        contents.removeValue(forKey: key)
                    }
                }
                lock.unlock()
            }
            if held.isEmpty {
                try? cancelSlotOwner(reservation.ownerID)
            } else {
                let retirement = SparseTileLeaseRetirementCoordinator(
                    heldLeases: held,
                    returnLease: returnLease,
                    onFullyReturned: { [self] in
                        try finishRetirement(reservation.ownerID)
                    }
                )
                try registerPendingRetirement(
                    reservation.ownerID,
                    retirement: retirement
                )
                do {
                    _ = try retirement.requestRetirement()
                } catch {
                    throw error
                }
            }
            throw error
        }
    }

    func invalidate(documentGeneration: UInt64) {
        lock.lock()
        contents = contents.filter {
            $0.key.documentGeneration != documentGeneration
        }
        generationEpochs[documentGeneration] = SparseTileGenerationEpoch()
        lock.unlock()
    }

    /// Retries cache-owned retirement state left by a fallible tile-store
    /// return. Active leases are skipped; failed leases remain registered.
    func retryPendingRetirements() throws {
        lock.lock()
        let snapshot = Array(retirements.values)
        lock.unlock()
        var firstError: (any Error)?
        for retirement in snapshot {
            do {
                _ = try retirement.retryIfRequested()
            } catch where firstError == nil {
                firstError = error
            } catch {}
        }
        if let firstError { throw firstError }
    }

    var pendingRetirementCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retirements.count
    }

    private func reserveSlotsLocked(
        generation: UInt64,
        sources: [SparseTileSourceSnapshot],
        maximum: Int,
        previous: SparseTileSamplingPlanContent?
    ) throws -> SparseTilePendingSlotReservation {
        guard maximum > 0 else {
            throw SparseTileSamplingPlanError.invalidLimit
        }
        let coordinateKeys = sources.flatMap { source in
            source.references.map {
                SparseTileRecordCoordinateKey(
                    layerID: source.layerID,
                    role: source.role,
                    coordinate: $0.coordinate
                )
            }
        }
        var entries = liveSlots[generation] ?? [:]
        let generationEpoch: SparseTileGenerationEpoch
        if let current = generationEpochs[generation] {
            generationEpoch = current
        } else {
            let initial = SparseTileGenerationEpoch()
            generationEpochs[generation] = initial
            generationEpoch = initial
        }
        var occupiedBySlot = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.value.slot, $0.key) }
        )
        let previousAssignments = Dictionary(
            uniqueKeysWithValues: (previous?.bindingRecords ?? []).map {
                (SparseTileRecordCoordinateKey(
                    layerID: $0.layerID,
                    role: $0.role,
                    coordinate: $0.reference.coordinate
                ), $0.globalSlot)
            }
        )
        for (coordinateKey, slot) in previousAssignments {
            guard slot >= 0, slot < maximum else {
                let required = slot == Int.max ? Int.max : max(0, slot) + 1
                throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                    required: required,
                    maximum: maximum
                )
            }
            if let occupiedCoordinate = occupiedBySlot[slot],
               occupiedCoordinate != coordinateKey {
                throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                    required: occupiedBySlot.count + 1,
                    maximum: maximum
                )
            }
            occupiedBySlot[slot] = coordinateKey
        }
        var assignments: [SparseTileRecordCoordinateKey: Int] = [:]
        for coordinateKey in coordinateKeys {
            if let existing = entries[coordinateKey] {
                guard existing.slot < maximum else {
                    throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                        required: existing.slot + 1,
                        maximum: maximum
                    )
                }
                assignments[coordinateKey] = existing.slot
                continue
            }
            if let previousSlot = previousAssignments[coordinateKey] {
                entries[coordinateKey] = SparseTileLiveSlotEntry(
                    slot: previousSlot,
                    owners: []
                )
                assignments[coordinateKey] = previousSlot
                continue
            }
            var slot = 0
            while slot < maximum, occupiedBySlot[slot] != nil { slot += 1 }
            guard slot < maximum else {
                throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                    required: occupiedBySlot.count + 1,
                    maximum: maximum
                )
            }
            occupiedBySlot[slot] = coordinateKey
            entries[coordinateKey] = SparseTileLiveSlotEntry(
                slot: slot,
                owners: []
            )
            assignments[coordinateKey] = slot
        }
        guard nextSlotOwnerID < UInt64.max else {
            throw SparseTileSamplingPlanError.slotOwnerIdentityOverflow
        }
        let ownerID = SparseTileSlotOwnerID(rawValue: nextSlotOwnerID)
        nextSlotOwnerID += 1
        for coordinateKey in coordinateKeys {
            entries[coordinateKey]!.owners.insert(ownerID)
        }
        liveSlots[generation] = entries
        slotOwners[ownerID] = SparseTileSlotOwnerRecord(
            generation: generation,
            generationEpoch: generationEpoch,
            coordinateKeys: coordinateKeys,
            state: .pending
        )
        return SparseTilePendingSlotReservation(
            ownerID: ownerID,
            assignments: assignments
        )
    }

    private func publishSlotOwner(
        _ ownerID: SparseTileSlotOwnerID,
        retirement: SparseTileLeaseRetirementCoordinator
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var owner = slotOwners[ownerID], owner.state == .pending,
              generationEpochs[owner.generation] === owner.generationEpoch
        else {
            throw SparseTileSamplingPlanError.staleSlotOwner
        }
        owner.state = .live
        slotOwners[ownerID] = owner
        retirements[ownerID] = retirement
    }

    private func registerPendingRetirement(
        _ ownerID: SparseTileSlotOwnerID,
        retirement: SparseTileLeaseRetirementCoordinator
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard slotOwners[ownerID]?.state == .pending,
              retirements[ownerID] == nil
        else { throw SparseTileSamplingPlanError.staleSlotOwner }
        retirements[ownerID] = retirement
    }

    private func ensureSlotOwnerCurrent(_ ownerID: SparseTileSlotOwnerID) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureSlotOwnerCurrentLocked(ownerID)
    }

    private func ensureSlotOwnerCurrentLocked(
        _ ownerID: SparseTileSlotOwnerID
    ) throws {
        guard let owner = slotOwners[ownerID], owner.state == .pending,
              generationEpochs[owner.generation] === owner.generationEpoch
        else { throw SparseTileSamplingPlanError.staleSlotOwner }
    }

    private func cancelSlotOwner(_ ownerID: SparseTileSlotOwnerID) throws {
        try removeSlotOwner(ownerID, expected: .pending)
    }

    private func removeSlotOwner(
        _ ownerID: SparseTileSlotOwnerID,
        expected: SparseTileSlotOwnerState
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try removeSlotOwnerLocked(ownerID, expected: expected)
    }

    private func finishRetirement(_ ownerID: SparseTileSlotOwnerID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard retirements[ownerID] != nil,
              let owner = slotOwners[ownerID]
        else { throw SparseTileSamplingPlanError.staleSlotOwner }
        try removeSlotOwnerLocked(ownerID, expected: owner.state)
        retirements.removeValue(forKey: ownerID)
    }

    private func removeSlotOwnerLocked(
        _ ownerID: SparseTileSlotOwnerID,
        expected: SparseTileSlotOwnerState
    ) throws {
        guard let owner = slotOwners[ownerID], owner.state == expected else {
            throw SparseTileSamplingPlanError.staleSlotOwner
        }
        var entries = liveSlots[owner.generation] ?? [:]
        for coordinateKey in owner.coordinateKeys {
            guard var entry = entries[coordinateKey],
                  entry.owners.remove(ownerID) != nil
            else { throw SparseTileSamplingPlanError.staleSlotOwner }
            if entry.owners.isEmpty {
                entries.removeValue(forKey: coordinateKey)
            } else {
                entries[coordinateKey] = entry
            }
        }
        if entries.isEmpty {
            liveSlots.removeValue(forKey: owner.generation)
        } else {
            liveSlots[owner.generation] = entries
        }
        slotOwners.removeValue(forKey: ownerID)
    }

    private static func content(
        _ content: SparseTileSamplingPlanContent,
        satisfies limits: SparseTilePlanLimits
    ) -> Bool {
        var pageEntries = 0
        var pageChunks = 0
        for table in content.pageTables {
            let (entries, entryOverflow) = pageEntries.addingReportingOverflow(
                table.entryCount
            )
            let (chunks, chunkOverflow) = pageChunks.addingReportingOverflow(
                table.chunks.count
            )
            guard !entryOverflow, !chunkOverflow else { return false }
            pageEntries = entries
            pageChunks = chunks
        }
        guard pageEntries <= limits.maximumPageEntries,
              pageChunks <= limits.maximumPageChunks,
              pageEntries <= limits.maximumPageTableBytes / 32,
              content.bindingRecords.count <= limits.maximumBindingSlots,
              content.bindingRecords.count <= limits.maximumBindingBytes / 64,
              content.bindingChunks.count <= limits.maximumBindingChunks,
              content.batches.count <= limits.maximumBatchCount,
              content.bindingRecords.allSatisfy({
                  $0.globalSlot >= 0
                      && $0.globalSlot < min(limits.maximumBindingSlots, 512)
              }),
              content.batches.allSatisfy({
                  $0.globalSlots.count <= limits.maximumTexturesPerBatch
              })
        else { return false }
        return true
    }

    private static func validate(
        key: SparseTileSamplingPlanKey,
        sources: [SparseTileSourceRequest],
        limits: SparseTilePlanLimits
    ) throws {
        guard limits.allValues.allSatisfy({ $0 > 0 }) else {
            throw SparseTileSamplingPlanError.invalidLimit
        }
        guard !sources.isEmpty else {
            throw SparseTileSamplingPlanError.contentKeyMismatch
        }
        let addressing = sources[0].addressing
        guard sources.allSatisfy({ $0.addressing == addressing }) else {
            throw SparseTileSamplingPlanError.inconsistentAddressing
        }
        var expected: [(UUID, SparseTileRoleContentKey)] = []
        var seenLayerIDs: Set<UUID> = []
        for layer in key.orderedLayers {
            guard seenLayerIDs.insert(layer.layerID).inserted else {
                throw SparseTileSamplingPlanError.duplicateLayer(layer.layerID)
            }
            var previousRole: SparseTileSampleRole?
            for role in layer.roles {
                guard previousRole.map({ $0.rawValue < role.role.rawValue })
                        ?? true
                else {
                    throw SparseTileSamplingPlanError.contentRoleMismatch
                }
                previousRole = role.role
                expected.append((layer.layerID, role))
            }
        }
        let actual = sources.map { ($0.layerID, $0.contentKey) }
        guard expected.count == actual.count else {
            throw SparseTileSamplingPlanError.contentKeyMismatch
        }
        for index in expected.indices {
            guard expected[index].0 == actual[index].0,
                  expected[index].1 == actual[index].1
            else { throw SparseTileSamplingPlanError.sourceOrderMismatch }
        }
        var seen: Set<String> = []
        for source in sources {
            let token = source.layerID.uuidString + ":" + String(source.role.rawValue)
            guard seen.insert(token).inserted else {
                throw SparseTileSamplingPlanError.duplicateSource(
                    layerID: source.layerID,
                    role: source.role
                )
            }
        }
    }

    private static func boundTextures(
        content: SparseTileSamplingPlanContent,
        acquired: [(request: SparseTileSourceRequest,
                    references: [PaintTileReference],
                    bindings: [PaintTileBinding])]
    ) throws -> [SparseTileBoundTexture] {
        var byReference: [PaintTileReference: any MTLTexture] = [:]
        for source in acquired {
            guard source.references.count == source.bindings.count else {
                throw SparseTileSamplingPlanError.bindingCountMismatch(
                    references: source.references.count,
                    bindings: source.bindings.count
                )
            }
            for (reference, binding) in zip(
                source.references, source.bindings
            ) {
                guard reference.identity == binding.identity,
                      reference.descriptor == binding.descriptor
                else {
                    throw SparseTileSamplingPlanError.missingBinding(reference)
                }
                byReference[reference] = binding.texture
            }
        }
        return try content.bindingRecords.map { record in
            guard let texture = byReference[record.reference] else {
                throw SparseTileSamplingPlanError.missingBinding(record.reference)
            }
            return SparseTileBoundTexture(
                globalSlot: record.globalSlot,
                texture: texture
            )
        }
    }
}

enum SparseTileAcceptedSourceAdapter {
    static func canonical(
        _ binding: DocumentPaintLayerBinding,
        addressing: SparseTileAddressing
    ) throws -> SparseTileSourceRequest {
        let references = binding.canonical.references
        let revision = binding.canonical.revision.rawValue
        return try SparseTileSourceRequest(
            contentKey: SparseTileRoleContentKey(
                role: .canonical,
                contentRevision: revision,
                bindingChunkRevision: revision
            ),
            addressing: addressing,
            surface: binding.canonical,
            changedCoordinates: references.map(\.coordinate),
            disposition: .fullSnapshot
        )
    }

    static func transient(
        layerID: UUID,
        authoritative: TiledRasterSurface,
        prediction: TiledRasterSurface,
        changedRole: StrokePrivateSurfaceLayer,
        changedCoordinates: [PaintTileCoordinate],
        addressing: SparseTileAddressing
    ) throws -> [SparseTileSourceRequest] {
        guard authoritative.layerID == layerID else {
            throw SparseTileSamplingPlanError.sourceLayerMismatch(
                expected: layerID, actual: authoritative.layerID
            )
        }
        guard prediction.layerID == layerID else {
            throw SparseTileSamplingPlanError.sourceLayerMismatch(
                expected: layerID, actual: prediction.layerID
            )
        }
        guard authoritative.generation == prediction.generation else {
            throw SparseTileSamplingPlanError.sourceGenerationMismatch(
                expected: authoritative.generation,
                actual: prediction.generation
            )
        }
        guard authoritative.pixelSize == prediction.pixelSize else {
            throw SparseTileSamplingPlanError.sourcePixelSizeMismatch
        }
        let sortedChanges = changedCoordinates.sorted()
        let authoritativeRevision = authoritative.revision.rawValue
        let predictionRevision = prediction.revision.rawValue
        return [
            try SparseTileSourceRequest(
                contentKey: SparseTileRoleContentKey(
                    role: .authoritative,
                    contentRevision: authoritativeRevision,
                    bindingChunkRevision: authoritativeRevision
                ),
                addressing: addressing,
                surface: authoritative,
                changedCoordinates: changedRole == .authoritative
                    ? sortedChanges : [],
                disposition: .delta
            ),
            try SparseTileSourceRequest(
                contentKey: SparseTileRoleContentKey(
                    role: .prediction,
                    contentRevision: predictionRevision,
                    bindingChunkRevision: predictionRevision
                ),
                addressing: addressing,
                surface: prediction,
                changedCoordinates: changedRole == .prediction
                    ? sortedChanges : [],
                disposition: .delta
            ),
        ]
    }

}

extension DocumentPaintLayerBinding {
    func sparseTileSourceRequest(
        addressing: SparseTileAddressing
    ) throws -> SparseTileSourceRequest {
        try SparseTileAcceptedSourceAdapter.canonical(
            self, addressing: addressing
        )
    }
}

extension StrokePreparedSurfaceLease {
    func sparseTileSourceRequests(
        addressing: SparseTileAddressing
    ) throws -> [SparseTileSourceRequest] {
        guard case let .tiled(backing) = backing else {
            throw SparseTileSamplingPlanError.contentRoleMismatch
        }
        return try SparseTileAcceptedSourceAdapter.transient(
            layerID: backing.layerID,
            authoritative: backing.resources.authoritative,
            prediction: backing.resources.prediction,
            changedRole: layer,
            changedCoordinates: backing.bindingDeltaCoordinates,
            addressing: addressing
        )
    }
}

private extension Array where Element == SparseTileSourceSnapshot {
    var fingerprints: [SparseTileSourceFingerprint] {
        map {
            SparseTileSourceFingerprint(
                layerID: $0.layerID,
                contentKey: $0.contentKey,
                addressing: $0.addressing,
                references: $0.references
            )
        }
    }
}

struct SparseTileRecordCoordinateKey: Hashable {
    let layerID: UUID
    let role: SparseTileSampleRole
    let coordinate: PaintTileCoordinate
}

private struct SparseTilePageTableGeometry {
    let origin: PaintTileCoordinate
    let size: PixelSize
    let entryCount: Int
    let chunkCount: Int
}

enum SparseTilePlanAllocationKind: Sendable {
    case bindingRecords
    case bindingChunks
    case pageEntries
}

enum SparseTileSamplingPlanBuilder {
    static func buildFull(
        key: SparseTileSamplingPlanKey,
        sources: [SparseTileSourceSnapshot],
        outputRegion: SparseTileOutputRegion,
        limits: SparseTilePlanLimits,
        previous: SparseTileSamplingPlanContent? = nil,
        slotAssignments: [SparseTileRecordCoordinateKey: Int]? = nil,
        allocationObserver: (@Sendable (
            SparseTilePlanAllocationKind, Int
        ) -> Void)? = nil
    ) throws -> SparseTileSamplingPlanContent {
        guard !sources.isEmpty else {
            throw SparseTileSamplingPlanError.contentKeyMismatch
        }
        guard limits.allValues.allSatisfy({ $0 > 0 }) else {
            throw SparseTileSamplingPlanError.invalidLimit
        }
        guard sources.dropFirst().allSatisfy({
            $0.addressing == sources[0].addressing
        }) else {
            throw SparseTileSamplingPlanError.inconsistentAddressing
        }
        let shaderSourceOrigin = try key.outputToSourceTransform
            .shaderSourceOrigin(outputRegion: outputRegion)
        let maximumGlobalSlots = min(limits.maximumBindingSlots, 512)
        let bindingCount = try sources.reduce(into: 0) { count, source in
            count = try checkedSum(count, source.references.count)
        }
        guard bindingCount <= maximumGlobalSlots else {
            throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                required: bindingCount,
                maximum: maximumGlobalSlots
            )
        }
        let bindingBytes = try checkedProduct(bindingCount, 64)
        guard bindingBytes <= limits.maximumBindingBytes else {
            throw SparseTileSamplingPlanError.bindingByteLimitExceeded(
                required: bindingBytes,
                maximum: limits.maximumBindingBytes
            )
        }
        let bindingChunkCount = try sources.reduce(into: 0) { count, source in
            count = try checkedSum(
                count,
                try checkedChunkCount(
                    itemCount: source.references.count,
                    capacity: 64
                )
            )
        }
        guard bindingChunkCount <= limits.maximumBindingChunks else {
            throw SparseTileSamplingPlanError.bindingChunkLimitExceeded(
                required: bindingChunkCount,
                maximum: limits.maximumBindingChunks
            )
        }

        let geometries = try sources.map(pageTableGeometry)
        var totalPageEntries = 0
        var totalPageChunks = 0
        for geometry in geometries {
            totalPageEntries = try checkedSum(
                totalPageEntries, geometry.entryCount
            )
            totalPageChunks = try checkedSum(
                totalPageChunks, geometry.chunkCount
            )
        }
        guard totalPageEntries <= limits.maximumPageEntries else {
            throw SparseTileSamplingPlanError.pageEntryLimitExceeded(
                required: totalPageEntries,
                maximum: limits.maximumPageEntries
            )
        }
        guard totalPageChunks <= limits.maximumPageChunks else {
            throw SparseTileSamplingPlanError.pageChunkLimitExceeded(
                required: totalPageChunks,
                maximum: limits.maximumPageChunks
            )
        }
        let pageBytes = try checkedProduct(totalPageEntries, 32)
        guard pageBytes <= limits.maximumPageTableBytes else {
            throw SparseTileSamplingPlanError.pageTableByteLimitExceeded(
                required: pageBytes,
                maximum: limits.maximumPageTableBytes
            )
        }

        // Validate the complete deterministic subdivision before allocating
        // records, chunks, or page entries. This includes terminal child
        // regions, not only an output that starts at one pixel.
        try preflightOutputHalo(
            outputRegion,
            transform: key.outputToSourceTransform,
            shaderSourceOrigin: shaderSourceOrigin,
            addressing: sources[0].addressing
        )
        try preflightBatches(
            sources: sources,
            outputRegion: outputRegion,
            transform: key.outputToSourceTransform,
            shaderSourceOrigin: shaderSourceOrigin,
            limits: limits
        )
        allocationObserver?(.bindingRecords, bindingCount)

        let previousRecords = previous?.bindingRecords ?? []
        guard previousRecords.allSatisfy({
            $0.globalSlot >= 0 && $0.globalSlot < maximumGlobalSlots
        }) else {
            throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                required: previousRecords.count,
                maximum: maximumGlobalSlots
            )
        }
        let previousByCoordinate = Dictionary(
            uniqueKeysWithValues: previousRecords.map {
                (SparseTileRecordCoordinateKey(
                    layerID: $0.layerID,
                    role: $0.role,
                    coordinate: $0.reference.coordinate
                ), $0)
            }
        )
        let reservedSlots = Set(previousRecords.map(\.globalSlot))
        var assignedSlots: Set<Int> = []
        var records: [SparseTileBindingRecord] = []
        for source in sources {
            for reference in source.references {
                let coordinateKey = SparseTileRecordCoordinateKey(
                    layerID: source.layerID,
                    role: source.role,
                    coordinate: reference.coordinate
                )
                let slot: Int
                if let assigned = slotAssignments?[coordinateKey] {
                    slot = assigned
                } else if let existing = previousByCoordinate[coordinateKey] {
                    slot = existing.globalSlot
                } else {
                    var candidate = 0
                    while reservedSlots.contains(candidate)
                            || assignedSlots.contains(candidate) {
                        candidate = try checkedSum(candidate, 1)
                    }
                    slot = candidate
                }
                guard slot < maximumGlobalSlots else {
                    let union = reservedSlots.union(assignedSlots).count + 1
                    throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                        required: union,
                        maximum: maximumGlobalSlots
                    )
                }
                guard assignedSlots.insert(slot).inserted else {
                    throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                        required: assignedSlots.count + 1,
                        maximum: maximumGlobalSlots
                    )
                }
                records.append(SparseTileBindingRecord(
                    globalSlot: slot,
                    layerID: source.layerID,
                    role: source.role,
                    reference: reference
                ))
            }
        }
        allocationObserver?(.bindingChunks, bindingChunkCount)
        var bindingChunks: [SparseTileBindingChunk] = []
        var rebuiltBindingCount = 0
        for source in sources {
            let sourceRecords = records.filter {
                $0.layerID == source.layerID
                    && $0.role == source.role
            }
            let previousChunks = previous?.bindingChunks.filter {
                $0.layerID == source.layerID
                    && $0.role == source.role
            } ?? []
            for (index, chunkRecords) in sourceRecords.chunked(capacity: 64)
                .enumerated() {
                if index < previousChunks.count,
                   previousChunks[index].records == chunkRecords {
                    bindingChunks.append(previousChunks[index])
                } else {
                    bindingChunks.append(SparseTileBindingChunk(
                        layerID: source.layerID,
                        role: source.role,
                        records: chunkRecords
                    ))
                    rebuiltBindingCount = try checkedSum(
                        rebuiltBindingCount, chunkRecords.count
                    )
                }
            }
        }
        allocationObserver?(.pageEntries, totalPageEntries)
        var pageTables: [SparseTilePageTable] = []
        for (source, geometry) in zip(sources, geometries) {
            let recordsForSource = records.filter {
                $0.layerID == source.layerID
                    && $0.role == source.role
            }
            let sourceFingerprint = SparseTileSourceFingerprint(
                layerID: source.layerID,
                contentKey: source.contentKey,
                addressing: source.addressing,
                references: source.references
            )
            let previousFingerprint = previous?.sourceFingerprints.first {
                $0.layerID == source.layerID
                    && $0.contentKey.role == source.role
            }
            let table = try makePageTable(
                source: source,
                geometry: geometry,
                records: recordsForSource,
                previous: previous?.pageTable(
                    layerID: source.layerID,
                    role: source.role
                ),
                changedCoordinates: sourceFingerprint == previousFingerprint
                    ? [] : source.changedCoordinates
            )
            pageTables.append(table)
        }
        let batches = try makeBatches(
            pageTables: pageTables,
            addressing: sources[0].addressing,
            outputRegion: outputRegion,
            transform: key.outputToSourceTransform,
            shaderSourceOrigin: shaderSourceOrigin,
            limits: limits
        )
        let rebuiltPageEntries = pageTables.reduce(into: 0) { result, table in
            let oldChunks = previous?.pageTable(
                layerID: table.layerID, role: table.role
            )?.chunks ?? []
            for (index, chunk) in table.chunks.enumerated()
                where index >= oldChunks.count || chunk !== oldChunks[index] {
                result += chunk.entries.count
            }
        }
        return SparseTileSamplingPlanContent(
            key: key,
            addressing: sources[0].addressing,
            pageTables: pageTables,
            bindingRecords: records,
            bindingChunks: bindingChunks,
            batches: batches,
            telemetry: .init(
                rebuiltPageEntryCount: rebuiltPageEntries,
                rebuiltBindingCount: rebuiltBindingCount
            ),
            outputToSourceTransform: key.outputToSourceTransform,
            shaderSourceOrigin: shaderSourceOrigin,
            sourceFingerprints: sources.fingerprints,
            outputRegion: outputRegion
        )
    }

    private static func makePageTable(
        source: SparseTileSourceSnapshot,
        geometry: SparseTilePageTableGeometry,
        records: [SparseTileBindingRecord],
        previous: SparseTilePageTable?,
        changedCoordinates: [PaintTileCoordinate]
    ) throws -> SparseTilePageTable {
        let origin = geometry.origin
        let size = geometry.size
        var slotByPhysicalCoordinate: [PaintTileCoordinate: Int] = [:]
        for record in records {
            slotByPhysicalCoordinate[record.reference.coordinate] = record.globalSlot
        }
        var entries: [SparseTilePageEntry] = []
        entries.reserveCapacity(geometry.entryCount)
        for tableY in 0..<size.height {
            for tableX in 0..<size.width {
                let logical = PaintTileCoordinate(
                    x: try checkedSum(origin.x, tableX),
                    y: try checkedSum(origin.y, tableY)
                )
                let physical: PaintTileCoordinate?
                switch source.addressing {
                case .finite, .periodic:
                    physical = logical
                case let .radial(layout):
                    if let page = layout.residentPage(at: .init(
                        x: logical.x, y: logical.y
                    )) {
                        physical = PaintTileCoordinate(
                            x: page.atlasSlot % layout.atlasColumns,
                            y: page.atlasSlot / layout.atlasColumns
                        )
                    } else {
                        physical = nil
                    }
                }
                let slot = physical.flatMap { slotByPhysicalCoordinate[$0] } ?? -1
                let logicalX = try checkedProduct(logical.x, PaintTileDescriptor.side)
                let logicalY = try checkedProduct(logical.y, PaintTileDescriptor.side)
                let physicalX = try checkedProduct(
                    physical?.x ?? 0, PaintTileDescriptor.side
                )
                let physicalY = try checkedProduct(
                    physical?.y ?? 0, PaintTileDescriptor.side
                )
                let localBounds: PixelRect
                if slot >= 0,
                   let record = records.first(where: { $0.globalSlot == slot }),
                   case .radial = source.addressing {
                    _ = record
                    localBounds = PixelRect(
                        minX: 0, minY: 0,
                        maxX: PaintTileDescriptor.side,
                        maxY: PaintTileDescriptor.side
                    )!
                } else if slot >= 0,
                          let record = records.first(where: { $0.globalSlot == slot }) {
                    let bounds = record.reference.descriptor.logicalBounds
                    localBounds = PixelRect(
                        minX: bounds.minX - physicalX,
                        minY: bounds.minY - physicalY,
                        maxX: bounds.maxX - physicalX,
                        maxY: bounds.maxY - physicalY
                    )!
                } else {
                    localBounds = PixelRect(
                        minX: 0, minY: 0,
                        maxX: PaintTileDescriptor.side,
                        maxY: PaintTileDescriptor.side
                    )!
                }
                entries.append(.init(
                    globalBindingSlot: slot,
                    logicalOrigin: SIMD2(logicalX, logicalY),
                    physicalOrigin: SIMD2(physicalX, physicalY),
                    localBounds: localBounds
                ))
            }
        }
        let entryChunks = entries.chunked(
            capacity: SparseTilePageTable.chunkCapacity
        )
        let changed = Set(changedCoordinates)
        let chunks = entryChunks.enumerated().map { index, chunkEntries in
            let intersectsChange = chunkEntries.contains { entry in
                let physical = PaintTileCoordinate(
                    x: floorDivide(
                        entry.physicalOrigin.x,
                        divisor: PaintTileDescriptor.side
                    ),
                    y: floorDivide(
                        entry.physicalOrigin.y,
                        divisor: PaintTileDescriptor.side
                    )
                )
                return changed.contains(physical)
            }
            if !intersectsChange,
               let old = previous?.chunks[safe: index],
               old.entries == chunkEntries {
                return old
            }
            return SparseTilePageTableChunk(entries: chunkEntries)
        }
        return SparseTilePageTable(
            layerID: source.layerID,
            role: source.role,
            origin: origin,
            size: size,
            entryCount: geometry.entryCount,
            chunks: chunks
        )
    }

    private static func pageTableGeometry(
        for source: SparseTileSourceSnapshot
    ) throws -> SparseTilePageTableGeometry {
        let origin: PaintTileCoordinate
        let size: PixelSize
        switch source.addressing {
        case let .finite(pixelSize), let .periodic(pixelSize):
            origin = PaintTileCoordinate(x: 0, y: 0)
            size = PixelSize(
                width: try ceilDivide(pixelSize.width, by: PaintTileDescriptor.side),
                height: try ceilDivide(pixelSize.height, by: PaintTileDescriptor.side)
            )
        case let .radial(layout):
            origin = PaintTileCoordinate(
                x: layout.pageOrigin.x,
                y: layout.pageOrigin.y
            )
            size = layout.pageTableSize
        }
        let entryCount = try checkedProduct(size.width, size.height)
        let chunkCount = try checkedChunkCount(
            itemCount: entryCount,
            capacity: SparseTilePageTable.chunkCapacity
        )
        return SparseTilePageTableGeometry(
            origin: origin,
            size: size,
            entryCount: entryCount,
            chunkCount: chunkCount
        )
    }

    private static func preflightOutputHalo(
        _ outputRegion: SparseTileOutputRegion,
        transform: SparseTileOutputToSourceTransform,
        shaderSourceOrigin: SIMD2<Float>,
        addressing: SparseTileAddressing
    ) throws {
        let halo = try mappedSourceHalo(
            for: outputRegion,
            within: outputRegion,
            transform: transform,
            shaderSourceOrigin: shaderSourceOrigin
        )
        _ = try addressedIntervals(
            minimum: halo.minX,
            maximumInclusive: halo.maxX,
            axisLimit: addressing.axisWidth,
            wraps: addressing.wraps
        )
        _ = try addressedIntervals(
            minimum: halo.minY,
            maximumInclusive: halo.maxY,
            axisLimit: addressing.axisHeight,
            wraps: addressing.wraps
        )
    }

    private static func requiredSourceBindingCount(
        for region: SparseTileOutputRegion,
        within outputRegion: SparseTileOutputRegion,
        transform: SparseTileOutputToSourceTransform,
        shaderSourceOrigin: SIMD2<Float>,
        sources: [SparseTileSourceSnapshot]
    ) throws -> Int {
        let addressing = sources[0].addressing
        let halo = try mappedSourceHalo(
            for: region,
            within: outputRegion,
            transform: transform,
            shaderSourceOrigin: shaderSourceOrigin
        )
        let xIntervals = try addressedIntervals(
            minimum: halo.minX,
            maximumInclusive: halo.maxX,
            axisLimit: addressing.axisWidth,
            wraps: addressing.wraps
        )
        let yIntervals = try addressedIntervals(
            minimum: halo.minY,
            maximumInclusive: halo.maxY,
            axisLimit: addressing.axisHeight,
            wraps: addressing.wraps
        )
        var required: Set<SparseTileRecordCoordinateKey> = []
        for source in sources {
            switch source.addressing {
            case .finite, .periodic:
                for reference in source.references {
                    let bounds = reference.descriptor.logicalBounds
                    if intervals(xIntervals, overlap: bounds.minX..<bounds.maxX),
                       intervals(yIntervals, overlap: bounds.minY..<bounds.maxY) {
                        required.insert(SparseTileRecordCoordinateKey(
                            layerID: source.layerID,
                            role: source.role,
                            coordinate: reference.coordinate
                        ))
                    }
                }
            case let .radial(layout):
                let referenceCoordinates = Set(
                    source.references.map(\.coordinate)
                )
                for page in layout.residentPages {
                    let minX = try checkedProduct(
                        page.coordinate.x, PaintTileDescriptor.side
                    )
                    let minY = try checkedProduct(
                        page.coordinate.y, PaintTileDescriptor.side
                    )
                    let maxX = try checkedSum(minX, PaintTileDescriptor.side)
                    let maxY = try checkedSum(minY, PaintTileDescriptor.side)
                    guard intervals(xIntervals, overlap: minX..<maxX),
                          intervals(yIntervals, overlap: minY..<maxY)
                    else { continue }
                    let physical = PaintTileCoordinate(
                        x: page.atlasSlot % layout.atlasColumns,
                        y: page.atlasSlot / layout.atlasColumns
                    )
                    if referenceCoordinates.contains(physical) {
                        required.insert(SparseTileRecordCoordinateKey(
                            layerID: source.layerID,
                            role: source.role,
                            coordinate: physical
                        ))
                    }
                }
            }
        }
        return required.count
    }

    private static func preflightBatches(
        sources: [SparseTileSourceSnapshot],
        outputRegion: SparseTileOutputRegion,
        transform: SparseTileOutputToSourceTransform,
        shaderSourceOrigin: SIMD2<Float>,
        limits: SparseTilePlanLimits
    ) throws {
        var batchCount = 0
        var examinedRegionCount = 0
        let maximumExaminedRegions = limits.maximumBatchCount > Int.max / 2
            ? Int.max
            : limits.maximumBatchCount * 2 - 1

        func split(_ region: SparseTileOutputRegion) throws {
            examinedRegionCount = try checkedSum(examinedRegionCount, 1)
            guard examinedRegionCount <= maximumExaminedRegions else {
                throw SparseTileSamplingPlanError.batchLimitExceeded(
                    required: try checkedSum(limits.maximumBatchCount, 1),
                    maximum: limits.maximumBatchCount
                )
            }
            let required = try requiredSourceBindingCount(
                for: region,
                within: outputRegion,
                transform: transform,
                shaderSourceOrigin: shaderSourceOrigin,
                sources: sources
            )
            if required <= limits.maximumTexturesPerBatch {
                batchCount = try checkedSum(batchCount, 1)
                guard batchCount <= limits.maximumBatchCount else {
                    throw SparseTileSamplingPlanError.batchLimitExceeded(
                        required: batchCount,
                        maximum: limits.maximumBatchCount
                    )
                }
                return
            }
            guard region.width > 1 || region.height > 1 else {
                throw SparseTileSamplingPlanError
                    .onePixelBatchExceedsTextureLimit(
                        required: required,
                        maximum: limits.maximumTexturesPerBatch
                    )
            }
            if region.width >= region.height, region.width > 1 {
                let midpoint = try checkedSum(region.minX, region.width / 2)
                try split(SparseTileOutputRegion(
                    minX: region.minX,
                    minY: region.minY,
                    maxX: midpoint,
                    maxY: region.maxY
                ))
                try split(SparseTileOutputRegion(
                    minX: midpoint,
                    minY: region.minY,
                    maxX: region.maxX,
                    maxY: region.maxY
                ))
            } else {
                let midpoint = try checkedSum(region.minY, region.height / 2)
                try split(SparseTileOutputRegion(
                    minX: region.minX,
                    minY: region.minY,
                    maxX: region.maxX,
                    maxY: midpoint
                ))
                try split(SparseTileOutputRegion(
                    minX: region.minX,
                    minY: midpoint,
                    maxX: region.maxX,
                    maxY: region.maxY
                ))
            }
        }

        try split(outputRegion)
    }

    private static func intervals(
        _ intervals: [Range<Int>],
        overlap target: Range<Int>
    ) -> Bool {
        intervals.contains {
            $0.lowerBound < target.upperBound
                && target.lowerBound < $0.upperBound
        }
    }

    private static func makeBatches(
        pageTables: [SparseTilePageTable],
        addressing: SparseTileAddressing,
        outputRegion: SparseTileOutputRegion,
        transform: SparseTileOutputToSourceTransform,
        shaderSourceOrigin: SIMD2<Float>,
        limits: SparseTilePlanLimits
    ) throws -> [SparseTileBindingBatch] {
        var batches: [SparseTileBindingBatch] = []
        func split(_ region: SparseTileOutputRegion) throws {
            let slots = try requiredSlots(
                for: region,
                within: outputRegion,
                transform: transform,
                shaderSourceOrigin: shaderSourceOrigin,
                pageTables: pageTables,
                addressing: addressing
            )
            if slots.count <= limits.maximumTexturesPerBatch {
                let remap = Dictionary(
                    uniqueKeysWithValues: slots.enumerated().map {
                        ($0.element, $0.offset)
                    }
                )
                batches.append(SparseTileBindingBatch(
                    outputRegion: region,
                    globalSlots: slots,
                    compactRemap: remap
                ))
                guard batches.count <= limits.maximumBatchCount else {
                    throw SparseTileSamplingPlanError.batchLimitExceeded(
                        required: batches.count,
                        maximum: limits.maximumBatchCount
                    )
                }
                return
            }
            guard region.width > 1 || region.height > 1 else {
                throw SparseTileSamplingPlanError
                    .onePixelBatchExceedsTextureLimit(
                        required: slots.count,
                        maximum: limits.maximumTexturesPerBatch
                    )
            }
            if region.width >= region.height, region.width > 1 {
                let midpoint = try checkedSum(region.minX, region.width / 2)
                try split(SparseTileOutputRegion(
                    minX: region.minX, minY: region.minY,
                    maxX: midpoint, maxY: region.maxY
                ))
                try split(SparseTileOutputRegion(
                    minX: midpoint, minY: region.minY,
                    maxX: region.maxX, maxY: region.maxY
                ))
            } else {
                let midpoint = try checkedSum(region.minY, region.height / 2)
                try split(SparseTileOutputRegion(
                    minX: region.minX, minY: region.minY,
                    maxX: region.maxX, maxY: midpoint
                ))
                try split(SparseTileOutputRegion(
                    minX: region.minX, minY: midpoint,
                    maxX: region.maxX, maxY: region.maxY
                ))
            }
        }
        try split(outputRegion)
        return batches
    }

    private static func requiredSlots(
        for region: SparseTileOutputRegion,
        within outputRegion: SparseTileOutputRegion,
        transform: SparseTileOutputToSourceTransform,
        shaderSourceOrigin: SIMD2<Float>,
        pageTables: [SparseTilePageTable],
        addressing: SparseTileAddressing
    ) throws -> [Int] {
        let halo = try mappedSourceHalo(
            for: region,
            within: outputRegion,
            transform: transform,
            shaderSourceOrigin: shaderSourceOrigin
        )
        let xIntervals = try addressedIntervals(
            minimum: halo.minX,
            maximumInclusive: halo.maxX,
            axisLimit: addressing.axisWidth,
            wraps: addressing.wraps
        )
        let yIntervals = try addressedIntervals(
            minimum: halo.minY,
            maximumInclusive: halo.maxY,
            axisLimit: addressing.axisHeight,
            wraps: addressing.wraps
        )
        var slots: Set<Int> = []
        for table in pageTables {
            for chunk in table.chunks {
                for entry in chunk.entries where !entry.isMissing {
                    let minX = try checkedSum(
                        entry.logicalOrigin.x, entry.localBounds.minX
                    )
                    let maxX = try checkedSum(
                        entry.logicalOrigin.x, entry.localBounds.maxX
                    )
                    let minY = try checkedSum(
                        entry.logicalOrigin.y, entry.localBounds.minY
                    )
                    let maxY = try checkedSum(
                        entry.logicalOrigin.y, entry.localBounds.maxY
                    )
                    guard xIntervals.contains(where: {
                        $0.lowerBound < maxX && minX < $0.upperBound
                    }), yIntervals.contains(where: {
                        $0.lowerBound < maxY && minY < $0.upperBound
                    }) else { continue }
                    slots.insert(entry.globalBindingSlot)
                }
            }
        }
        return slots.sorted()
    }

    private struct SparseTileMappedSourceHalo {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
    }

    private static func mappedSourceHalo(
        for region: SparseTileOutputRegion,
        within outputRegion: SparseTileOutputRegion,
        transform: SparseTileOutputToSourceTransform,
        shaderSourceOrigin: SIMD2<Float>
    ) throws -> SparseTileMappedSourceHalo {
        let localMinX = try region.minX.subtractingChecked(outputRegion.minX)
        let localMinY = try region.minY.subtractingChecked(outputRegion.minY)
        let localMaxX = try region.maxX.subtractingChecked(outputRegion.minX)
        let localMaxY = try region.maxY.subtractingChecked(outputRegion.minY)
        guard localMinX >= 0, localMinY >= 0,
              localMaxX <= outputRegion.width,
              localMaxY <= outputRegion.height
        else { throw SparseTileSamplingPlanError.invalidOutputRegion }

        func axis(
            localMinimum: Int,
            localMaximum: Int,
            origin: Float,
            step: Float
        ) throws -> (minimum: Int, maximum: Int) {
            guard localMaximum > localMinimum else {
                throw SparseTileSamplingPlanError.invalidOutputRegion
            }
            let firstCenter = Float(localMinimum) + 0.5
            let lastCenter = Float(localMaximum - 1) + 0.5
            guard firstCenter.isFinite, lastCenter.isFinite else {
                throw SparseTileSamplingPlanError.invalidOutputToSourceTransform
            }
            let first = origin + firstCenter * step - 0.5
            let last = origin + lastCenter * step - 0.5
            guard first.isFinite, last.isFinite else {
                throw SparseTileSamplingPlanError.invalidOutputToSourceTransform
            }
            let minimum = try checkedFloorToInt(Double(min(first, last)))
            let upperLower = try checkedFloorToInt(Double(max(first, last)))
            return (minimum, try checkedSum(upperLower, 1))
        }

        let x = try axis(
            localMinimum: localMinX,
            localMaximum: localMaxX,
            origin: shaderSourceOrigin.x,
            step: transform.sourceStep.x
        )
        let y = try axis(
            localMinimum: localMinY,
            localMaximum: localMaxY,
            origin: shaderSourceOrigin.y,
            step: transform.sourceStep.y
        )
        return SparseTileMappedSourceHalo(
            minX: x.minimum,
            minY: y.minimum,
            maxX: x.maximum,
            maxY: y.maximum
        )
    }

    private static func addressedIntervals(
        minimum: Int,
        maximumInclusive: Int,
        axisLimit: Int?,
        wraps: Bool
    ) throws -> [Range<Int>] {
        let exclusiveMaximum = try checkedSum(maximumInclusive, 1)
        guard let axisLimit else { return [minimum..<exclusiveMaximum] }
        if !wraps {
            let lower = max(0, minimum)
            let upper = min(axisLimit, exclusiveMaximum)
            return lower < upper ? [lower..<upper] : []
        }
        let span = try checkedSum(
            try maximumInclusive.subtractingChecked(minimum), 1
        )
        if span >= axisLimit { return [0..<axisLimit] }
        let start = positiveRemainder(minimum, modulus: axisLimit)
        let end = try checkedSum(start, span)
        if end <= axisLimit { return [start..<end] }
        return [start..<axisLimit, 0..<(end - axisLimit)]
    }
}

protocol SparseTileCPUTexelProvider: Sendable {
    func texel(
        reference: PaintTileReference,
        localX: Int,
        localY: Int
    ) throws -> SIMD4<Float>
}

struct SparseTileResolvedTexelAddress: Equatable, Sendable {
    let layerID: UUID
    let role: SparseTileSampleRole
    let globalBindingSlot: Int
    let reference: PaintTileReference
    let localX: Int
    let localY: Int
}

struct SparseTileResolvedIntegerNeighbor: Equatable, Sendable {
    let logicalPixel: SIMD2<Int>
    /// Fixed layer order, then canonical/authoritative/prediction role order.
    /// Missing sources are absent and therefore contribute transparent black.
    let contributions: [SparseTileResolvedTexelAddress]
}

struct SparseTileFourNeighborResolution: Equatable, Sendable {
    /// Fraction of `point - 0.5` used by the one final bilinear mix.
    let fraction: SIMD2<Float>
    /// Ordered 00, 10, 01, 11.
    let neighbors: [SparseTileResolvedIntegerNeighbor]
}

enum SparseTileCPUReferenceSampler {
    static func resolveFourNeighbors(
        at point: SIMD2<Double>,
        content: SparseTileSamplingPlanContent
    ) throws -> SparseTileFourNeighborResolution {
        guard point.x.isFinite, point.y.isFinite else {
            throw SparseTileSamplingPlanError.nonFiniteSamplePoint
        }
        let sampleX = point.x - 0.5
        let sampleY = point.y - 0.5
        let x0 = try checkedFloorToInt(sampleX)
        let y0 = try checkedFloorToInt(sampleY)
        let x1 = try checkedSum(x0, 1)
        let y1 = try checkedSum(y0, 1)
        let pixels = [
            SIMD2(x0, y0), SIMD2(x1, y0),
            SIMD2(x0, y1), SIMD2(x1, y1),
        ]
        let neighbors = try pixels.map { pixel in
            SparseTileResolvedIntegerNeighbor(
                logicalPixel: pixel,
                contributions: try content.pageTables.compactMap { table in
                    try resolveAddress(
                        x: pixel.x,
                        y: pixel.y,
                        table: table,
                        content: content
                    )
                }
            )
        }
        return SparseTileFourNeighborResolution(
            fraction: SIMD2(
                Float(sampleX - floor(sampleX)),
                Float(sampleY - floor(sampleY))
            ),
            neighbors: neighbors
        )
    }

    static func sample<P: SparseTileCPUTexelProvider>(
        at point: SIMD2<Double>,
        layerID: UUID,
        role: SparseTileSampleRole,
        content: SparseTileSamplingPlanContent,
        provider: P
    ) throws -> SIMD4<Float> {
        _ = try content.pageTable(layerID: layerID, role: role).unwrap(
            SparseTileSamplingPlanError.missingPageTable(
                layerID: layerID, role: role
            )
        )
        let resolution = try resolveFourNeighbors(at: point, content: content)
        let colors = try resolution.neighbors.map { neighbor in
            guard let address = neighbor.contributions.first(where: {
                $0.layerID == layerID && $0.role == role
            }) else { return SIMD4<Float>.zero }
            return try provider.texel(
                reference: address.reference,
                localX: address.localX,
                localY: address.localY
            )
        }
        let c00 = colors[0]
        let c10 = colors[1]
        let c01 = colors[2]
        let c11 = colors[3]
        let fx = resolution.fraction.x
        let fy = resolution.fraction.y
        return simd_mix(simd_mix(c00, c10, SIMD4(repeating: fx)),
                        simd_mix(c01, c11, SIMD4(repeating: fx)),
                        SIMD4(repeating: fy))
    }

    private static func resolveAddress(
        x: Int,
        y: Int,
        table: SparseTilePageTable,
        content: SparseTileSamplingPlanContent
    ) throws -> SparseTileResolvedTexelAddress? {
        let addressed: SIMD2<Int>?
        switch content.addressing {
        case let .finite(size):
            guard x >= 0, y >= 0, x < size.width, y < size.height else {
                return nil
            }
            addressed = SIMD2(x, y)
        case let .periodic(period):
            addressed = SIMD2(
                positiveRemainder(x, modulus: period.width),
                positiveRemainder(y, modulus: period.height)
            )
        case .radial:
            addressed = SIMD2(x, y)
        }
        guard let addressed else { return nil }
        let pageX = floorDivide(addressed.x, divisor: PaintTileDescriptor.side)
        let pageY = floorDivide(addressed.y, divisor: PaintTileDescriptor.side)
        let localX = positiveRemainder(
            addressed.x, modulus: PaintTileDescriptor.side
        )
        let localY = positiveRemainder(
            addressed.y, modulus: PaintTileDescriptor.side
        )
        guard let entry = table.entry(at: .init(x: pageX, y: pageY)),
              !entry.isMissing,
              localX >= entry.localBounds.minX,
              localY >= entry.localBounds.minY,
              localX < entry.localBounds.maxX,
              localY < entry.localBounds.maxY,
              let record = content.bindingRecord(at: entry.globalBindingSlot)
        else { return nil }
        return SparseTileResolvedTexelAddress(
            layerID: table.layerID,
            role: table.role,
            globalBindingSlot: entry.globalBindingSlot,
            reference: record.reference,
            localX: localX,
            localY: localY
        )
    }
}

private func positiveRemainder(_ value: Int, modulus: Int) -> Int {
    let remainder = value % modulus
    return remainder >= 0 ? remainder : remainder + modulus
}

private func floorDivide(_ value: Int, divisor: Int) -> Int {
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder < 0 ? quotient - 1 : quotient
}

private extension SparseTileAddressing {
    var wraps: Bool {
        if case .periodic = self { return true }
        return false
    }

    var axisWidth: Int? {
        switch self {
        case let .finite(size), let .periodic(size): size.width
        case .radial: nil
        }
    }

    var axisHeight: Int? {
        switch self {
        case let .finite(size), let .periodic(size): size.height
        case .radial: nil
        }
    }
}

private extension Int {
    func subtractingChecked(_ other: Int) throws -> Int {
        let (value, overflow) = subtractingReportingOverflow(other)
        guard !overflow else {
            throw SparseTileSamplingPlanError.arithmeticOverflow
        }
        return value
    }
}

private func ceilDivide(_ value: Int, by divisor: Int) throws -> Int {
    guard value >= 0, divisor > 0 else {
        throw SparseTileSamplingPlanError.arithmeticOverflow
    }
    return try checkedSum(value / divisor, value % divisor == 0 ? 0 : 1)
}

private func checkedChunkCount(itemCount: Int, capacity: Int) throws -> Int {
    guard itemCount >= 0, capacity > 0 else {
        throw SparseTileSamplingPlanError.arithmeticOverflow
    }
    return try checkedSum(
        itemCount / capacity,
        itemCount % capacity == 0 ? 0 : 1
    )
}

private func checkedFloorToInt(_ value: Double) throws -> Int {
    let rounded = floor(value)
    guard let exact = Int(exactly: rounded) else {
        throw SparseTileSamplingPlanError.arithmeticOverflow
    }
    return exact
}

private func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw SparseTileSamplingPlanError.arithmeticOverflow }
    return value
}

private func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw SparseTileSamplingPlanError.arithmeticOverflow }
    return value
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }

    func chunked(capacity: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        var result: [[Element]] = []
        result.reserveCapacity((count + capacity - 1) / capacity)
        var start = 0
        while start < count {
            let end = Swift.min(count, start + capacity)
            result.append(Array(self[start..<end]))
            start = end
        }
        return result
    }
}

private extension Optional {
    func unwrap(_ error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
