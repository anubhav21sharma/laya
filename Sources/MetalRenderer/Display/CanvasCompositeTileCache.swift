import EditorCore
import Foundation
@preconcurrency import Metal
import PatternEngine

enum CanvasCompositeTileCacheError: Error, Equatable, Sendable {
    case staleIdentity(
        expected: CanvasCanonicalStateIdentity,
        current: CanvasCanonicalStateIdentity
    )
    case revisionGap(
        expectedBase: CanvasCanonicalStateIdentity,
        actualBase: CanvasCanonicalStateIdentity?
    )
    case invalidPlan
    case invalidRevision
    case closedSnapshot
    case shutdownSnapshotsOutstanding(count: Int)
    case isShutdown
    case cleanupPending(stage: CanvasCompositeCleanupStage)
    case snapshotMetadataCapacityExceeded(required: Int, maximum: Int)
    case sequenceOverflow
    case physicalCapacityExceeded(
        requested: Int,
        current: Int,
        highWater: Int,
        maximum: Int
    )
}

enum CanvasCompositeCleanupStage: Hashable, Sendable {
    case leaseReturn
    case retirementPrepare
    case retirementRequest
}

final class CanvasCompositeCleanupFailureInjection: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [CanvasCompositeCleanupStage: Int]

    init(
        leaseReturn: Int = 0,
        retirementPrepare: Int = 0,
        retirementRequest: Int = 0
    ) {
        remaining = [
            .leaseReturn: leaseReturn,
            .retirementPrepare: retirementPrepare,
            .retirementRequest: retirementRequest,
        ]
    }

    func shouldFail(_ stage: CanvasCompositeCleanupStage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let count = remaining[stage, default: 0]
        guard count > 0 else { return false }
        remaining[stage] = count - 1
        return true
    }
}

enum CanvasPresentationMemoryEnvelopeError: Error, Equatable, Sendable {
    case invalidPartition(required: Int, maximum: Int)
}

enum CanvasPresentationPlatform: Equatable, Sendable {
    case macOS
    case iOS

    static var current: CanvasPresentationPlatform {
        #if os(iOS)
        .iOS
        #else
        .macOS
        #endif
    }
}

/// One explicit physical-memory envelope for ordinary presentation storage.
/// Each child owns a disjoint partition; no cache may silently add another
/// nominal pool on top of this maximum.
struct CanvasPresentationMemoryEnvelope: Equatable, Sendable {
    let maximumPhysicalBytes: Int
    let documentStoreBytes: Int
    let transientCacheBytes: Int
    let canonicalCacheBytes: Int
    let canonicalResidentBytes: Int
    let canonicalBatchWorkspaceBytes: Int
    let canonicalCopyOnWriteHeadroomBytes: Int
    let canonicalSnapshotMetadataBytes: Int
    let canonicalStoreTransferBytes: Int

    func checkedPartitionByteCount() throws -> Int {
        let components = [
            maximumPhysicalBytes,
            documentStoreBytes,
            transientCacheBytes,
            canonicalCacheBytes,
            canonicalResidentBytes,
            canonicalBatchWorkspaceBytes,
            canonicalCopyOnWriteHeadroomBytes,
            canonicalSnapshotMetadataBytes,
            canonicalStoreTransferBytes,
        ]
        guard components.allSatisfy({ $0 >= 0 }) else {
            throw CanvasPresentationMemoryEnvelopeError.invalidPartition(
                required: components.min() ?? -1,
                maximum: maximumPhysicalBytes
            )
        }
        let (documentAndTransient, firstOverflow) = documentStoreBytes
            .addingReportingOverflow(transientCacheBytes)
        let (total, secondOverflow) = documentAndTransient
            .addingReportingOverflow(canonicalCacheBytes)
        guard !firstOverflow, !secondOverflow,
              total == maximumPhysicalBytes
        else {
            throw CanvasPresentationMemoryEnvelopeError.invalidPartition(
                required: total,
                maximum: maximumPhysicalBytes
            )
        }
        let (residentAndCOW, thirdOverflow) = canonicalResidentBytes
            .addingReportingOverflow(canonicalCopyOnWriteHeadroomBytes)
        guard !thirdOverflow,
              residentAndCOW == canonicalStoreTransferBytes
        else {
            throw CanvasPresentationMemoryEnvelopeError.invalidPartition(
                required: residentAndCOW,
                maximum: canonicalStoreTransferBytes
            )
        }
        let (storeAndWorkspace, fourthOverflow) = canonicalStoreTransferBytes
            .addingReportingOverflow(canonicalBatchWorkspaceBytes)
        let (canonical, fifthOverflow) = storeAndWorkspace
            .addingReportingOverflow(canonicalSnapshotMetadataBytes)
        guard !fourthOverflow, !fifthOverflow,
              canonical == canonicalCacheBytes
        else {
            throw CanvasPresentationMemoryEnvelopeError.invalidPartition(
                required: canonical,
                maximum: canonicalCacheBytes
            )
        }
        return total
    }

    static let legacyDocumentProductionBytes = 512 * 1_024 * 1_024
    static let legacyTransientProductionBytes = 512 * 1_024 * 1_024
    static let canonicalProductionStoreTransferBytes = 265 * 1_024 * 1_024
    static let canonicalProductionWorkspaceBytes = 16 * 1_024 * 1_024
    static let canonicalProductionSnapshotMetadataBytes =
        256 * PaintTileStore.snapshotRetentionFixedMetadataBytes
        + 262_144 * PaintTileStore.snapshotRetentionReferenceMetadataBytes

    private static let legacyProductionBytes =
        legacyDocumentProductionBytes + legacyTransientProductionBytes
    private static let fullCanonicalProductionBytes =
        canonicalProductionStoreTransferBytes
        + canonicalProductionWorkspaceBytes
        + canonicalProductionSnapshotMetadataBytes

    static let production = CanvasPresentationMemoryEnvelope(
        maximumPhysicalBytes: legacyProductionBytes
            + fullCanonicalProductionBytes,
        documentStoreBytes: legacyDocumentProductionBytes,
        transientCacheBytes: legacyTransientProductionBytes,
        canonicalCacheBytes: fullCanonicalProductionBytes,
        canonicalResidentBytes: 128 * 1_024 * 1_024,
        canonicalBatchWorkspaceBytes: canonicalProductionWorkspaceBytes,
        canonicalCopyOnWriteHeadroomBytes: 137 * 1_024 * 1_024,
        canonicalSnapshotMetadataBytes:
            canonicalProductionSnapshotMetadataBytes,
        canonicalStoreTransferBytes: canonicalProductionStoreTransferBytes
    )

    static func production(
        recommendedMaxWorkingSetSize: UInt64,
        platform: CanvasPresentationPlatform
    ) throws -> CanvasPresentationMemoryEnvelope {
        let availableCanonical: Int
        if recommendedMaxWorkingSetSize == 0 {
            availableCanonical = platform == .macOS
                ? fullCanonicalProductionBytes : 0
        } else if recommendedMaxWorkingSetSize <= UInt64(legacyProductionBytes) {
            availableCanonical = 0
        } else {
            availableCanonical = min(
                fullCanonicalProductionBytes,
                Int(clamping: recommendedMaxWorkingSetSize
                    - UInt64(legacyProductionBytes))
            )
        }
        let fixedCanonical = canonicalProductionWorkspaceBytes
            + canonicalProductionSnapshotMetadataBytes
        let (minimumStoreBytes, tileOverflow) = PaintTileDescriptor
            .residentByteCount.multipliedReportingOverflow(by: 3)
        guard !tileOverflow else {
            throw CanvasPresentationMemoryEnvelopeError.invalidPartition(
                required: .max,
                maximum: .max
            )
        }
        let (minimumEnabled, minimumOverflow) = fixedCanonical
            .addingReportingOverflow(minimumStoreBytes)
        guard !minimumOverflow else {
            throw CanvasPresentationMemoryEnvelopeError.invalidPartition(
                required: .max,
                maximum: .max
            )
        }
        let canonicalBytes = availableCanonical >= minimumEnabled
            ? availableCanonical : 0
        let storeBytes = canonicalBytes == 0
            ? 0 : canonicalBytes - fixedCanonical
        let residentBytes = min(128 * 1_024 * 1_024, storeBytes)
        let value = CanvasPresentationMemoryEnvelope(
            maximumPhysicalBytes: legacyProductionBytes + canonicalBytes,
            documentStoreBytes: legacyDocumentProductionBytes,
            transientCacheBytes: legacyTransientProductionBytes,
            canonicalCacheBytes: canonicalBytes,
            canonicalResidentBytes: residentBytes,
            canonicalBatchWorkspaceBytes: canonicalBytes == 0
                ? 0 : canonicalProductionWorkspaceBytes,
            canonicalCopyOnWriteHeadroomBytes: storeBytes - residentBytes,
            canonicalSnapshotMetadataBytes: canonicalBytes == 0
                ? 0 : canonicalProductionSnapshotMetadataBytes,
            canonicalStoreTransferBytes: storeBytes
        )
        _ = try value.checkedPartitionByteCount()
        return value
    }

    static func production(
        for device: any MTLDevice,
        platform: CanvasPresentationPlatform = .current
    ) throws
        -> CanvasPresentationMemoryEnvelope
    {
        try production(
            recommendedMaxWorkingSetSize:
                UInt64(device.recommendedMaxWorkingSetSize),
            platform: platform
        )
    }
}

enum CanvasCompositeInvalidation: Equatable, Sendable {
    case none
    case exact([PaintTileCoordinate])
    case full
    case metadataOnly

    var affectsPixels: Bool {
        switch self {
        case .exact, .full: true
        case .none, .metadataOnly: false
        }
    }

    static func classify(
        before: LayerStack,
        after: LayerStack,
        rasterDirtyCoordinates: [PaintTileCoordinate],
        geometryChanged: Bool,
        documentReplaced: Bool
    ) -> CanvasCompositeInvalidation {
        if geometryChanged || documentReplaced
            || pixelPresentation(before) != pixelPresentation(after) {
            return .full
        }
        if !rasterDirtyCoordinates.isEmpty {
            return .exact(sortedUnique(rasterDirtyCoordinates))
        }
        return before == after ? .none : .metadataOnly
    }

    private struct PixelLayer: Equatable {
        let id: UUID
        let isVisible: Bool
        let opacity: Float
        let blendMode: LayerBlendMode
    }

    private static func pixelPresentation(
        _ stack: LayerStack
    ) -> [PixelLayer] {
        stack.layers.map {
            PixelLayer(
                id: $0.id,
                isVisible: $0.isVisible,
                opacity: $0.opacity,
                blendMode: $0.blendMode
            )
        }
    }

    static func sortedUnique(
        _ coordinates: [PaintTileCoordinate]
    ) -> [PaintTileCoordinate] {
        let sorted = coordinates.sorted()
        var result: [PaintTileCoordinate] = []
        result.reserveCapacity(sorted.count)
        for coordinate in sorted where result.last != coordinate {
            result.append(coordinate)
        }
        return result
    }
}

struct CanvasCompositeBatchMetrics: Equatable, Sendable {
    let commandSubmissionCount: Int
    let commandWaitCount: Int
    let sampleEncodeCount: Int
    let scratchSetCount: Int
    let maximumScratchPixelCount: Int
    let maximumPreparedSubmissionCount: Int
}

enum CanvasCompositeBatchPolicyError: Error, Equatable, Sendable {
    case invalidLimit
    case arithmeticOverflow
}

struct CanvasCompositeBatchPolicy: Equatable, Sendable {
    let maximumTilesPerChunk: Int
    let maximumLayersPerTile: Int

    init(
        maximumTilesPerChunk: Int,
        maximumLayersPerTile: Int
    ) throws {
        guard maximumTilesPerChunk > 0, maximumLayersPerTile > 0 else {
            throw CanvasCompositeBatchPolicyError.invalidLimit
        }
        self.maximumTilesPerChunk = maximumTilesPerChunk
        self.maximumLayersPerTile = maximumLayersPerTile
    }

    func structuralMetrics(
        tileCount: Int,
        layerCount: Int
    ) throws -> CanvasCompositeBatchMetrics {
        guard tileCount >= 0, layerCount >= 0,
              layerCount <= maximumLayersPerTile
        else { throw CanvasCompositeBatchPolicyError.invalidLimit }
        let submissionCount = tileCount == 0
            ? 0 : 1 + (tileCount - 1) / maximumTilesPerChunk
        let (sampleCount, sampleOverflow) = tileCount
            .multipliedReportingOverflow(by: layerCount)
        let (preparedCount, preparedOverflow) = min(
            tileCount,
            maximumTilesPerChunk
        ).multipliedReportingOverflow(by: layerCount)
        guard !sampleOverflow, !preparedOverflow else {
            throw CanvasCompositeBatchPolicyError.arithmeticOverflow
        }
        return CanvasCompositeBatchMetrics(
            commandSubmissionCount: submissionCount,
            commandWaitCount: submissionCount,
            sampleEncodeCount: sampleCount,
            scratchSetCount: tileCount == 0 ? 0 : 1,
            maximumScratchPixelCount: tileCount == 0
                ? 0 : PaintTileDescriptor.side * PaintTileDescriptor.side,
            maximumPreparedSubmissionCount: preparedCount
        )
    }
}

struct PreparedLayerCompositeTile: @unchecked Sendable {
    let coordinate: PaintTileCoordinate
    let outputRegion: SparseTileOutputRegion
    let layers: [PreparedLayerCompositeLayer]
}

final class CanvasCompositeTileUpdatePlan: @unchecked Sendable {
    let baseIdentity: CanvasCanonicalStateIdentity
    let targetIdentity: CanvasCanonicalStateIdentity
    let invalidation: CanvasCompositeInvalidation
    let dirtyCoordinates: [PaintTileCoordinate]
    let preparedTiles: [PreparedLayerCompositeTile]
    let registryGeneration: UInt64
    let applicationDescriptor: CanvasCanonicalApplicationDescriptor

    private let identityClaim: CanvasCanonicalIdentityClaim
    private let epochIsCurrent: @Sendable () -> Bool
    private let sourceCapture: TiledRasterExactReferenceCapture
    private let lock = NSLock()
    private var closed = false

    init(
        baseIdentity: CanvasCanonicalStateIdentity,
        targetIdentity: CanvasCanonicalStateIdentity,
        invalidation: CanvasCompositeInvalidation,
        dirtyCoordinates: [PaintTileCoordinate],
        preparedTiles: [PreparedLayerCompositeTile],
        registryGeneration: UInt64,
        identityClaim: CanvasCanonicalIdentityClaim,
        epochIsCurrent: @escaping @Sendable () -> Bool,
        sourceCapture: TiledRasterExactReferenceCapture
    ) {
        self.baseIdentity = baseIdentity
        self.targetIdentity = targetIdentity
        self.invalidation = invalidation
        self.dirtyCoordinates = dirtyCoordinates
        self.preparedTiles = preparedTiles
        self.registryGeneration = registryGeneration
        applicationDescriptor = identityClaim.descriptor
        self.identityClaim = identityClaim
        self.epochIsCurrent = epochIsCurrent
        self.sourceCapture = sourceCapture
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func validatesPublicationClaim() -> Bool {
        lock.lock()
        let available = !closed
        lock.unlock()
        return available
            && identityClaim.validatesPendingPublication(
                applicationDescriptor
            )
            && epochIsCurrent()
    }

    func acquirePublicationClaim() -> Bool {
        lock.lock()
        let available = !closed
        lock.unlock()
        return available
            && epochIsCurrent()
            && identityClaim.acquirePublication(applicationDescriptor)
    }

    func completePublicationClaim() {
        identityClaim.completePublication()
    }

    var currentClaimIdentityForDiagnostics: CanvasCanonicalStateIdentity {
        identityClaim.currentIdentityForDiagnostics
    }

    func sourceBatch(
        for selection: SparseTileSourceSelection
    ) throws -> SparseTileOwnedSourceBatch {
        lock.lock()
        guard !closed else {
            lock.unlock()
            throw TiledRasterSurfaceError.exactReferenceCaptureClosed
        }
        lock.unlock()
        return try SparseTileOwnedSourceBatch.borrowing(
            selection,
            from: sourceCapture
        )
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        sourceCapture.close()
    }

    deinit { close() }

    static func outputRegions(
        dirtyCoordinates: [PaintTileCoordinate],
        storagePixelSize: PixelSize
    ) throws -> [SparseTileOutputRegion] {
        try CanvasCompositeInvalidation.sortedUnique(dirtyCoordinates).map {
            coordinate in
            let descriptor = try PaintTileDescriptor(
                coordinate: coordinate,
                logicalPixelSize: storagePixelSize
            )
            return try SparseTileOutputRegion(
                minX: descriptor.logicalBounds.minX,
                minY: descriptor.logicalBounds.minY,
                maxX: descriptor.logicalBounds.minX
                    + PaintTileDescriptor.side,
                maxY: descriptor.logicalBounds.minY
                    + PaintTileDescriptor.side
            )
        }
    }
}

struct CanvasCompositeRevision: Equatable, Comparable, Sendable {
    let identity: CanvasCanonicalStateIdentity
    let sequence: UInt64

    static func < (
        lhs: CanvasCompositeRevision,
        rhs: CanvasCompositeRevision
    ) -> Bool { lhs.sequence < rhs.sequence }
}

struct CanvasCompositeTileCacheSnapshot: Equatable, Sendable {
    let acceptsUpdates: Bool
    let isShutDown: Bool
    let revision: CanvasCompositeRevision?
    let cachedCoordinates: [PaintTileCoordinate]
    let residentByteCount: Int
    let componentCoverageByteCount: Int
    let snapshotMetadataByteCount: Int
    let snapshotPayloadLiabilityByteCount: Int
    let totalStorePhysicalByteCount: Int
    let workspacePhysicalByteCount: Int
    let totalPhysicalByteCount: Int
    let physicalByteHighWater: Int
    let snapshotMetadataByteHighWater: Int
    let physicalAdmissionCount: UInt64
    let lastCausalTransferAccounting: PaintTileTransferAccounting?
    let storeTransferPeakByteHighWater: Int
    let workspacePhysicalByteHighWater: Int
    let maximumPhysicalBytes: Int
    let activeSnapshotCount: Int
    let activeUpdateCount: Int
    let sourceSnapshotTokenCount: Int
    let candidateLeaseCount: Int
    let preparedRetirementCount: Int
    let pendingRetirementCount: Int
    let maximumCandidateLeaseTileCount: Int
    let cleanupDebtCount: Int
    let compositorPendingPlanCompletionCount: Int
    let compositorPendingPlanMetalBufferBytes: Int
    let lastBatchMetrics: CanvasCompositeBatchMetrics?
    let leastRecentlyUsedCoordinates: [PaintTileCoordinate]
}

private enum CanvasCompositePayloadProbe: Sendable {
    case fingerprint
    case encodedBGRA8Fingerprint
    case rgba16Texel(x: Int, y: Int)
}

private enum CanvasCompositePayloadProbeResult: Sendable {
    case fingerprint(UInt64)
    case rgba16Texel(SIMD4<Float16>)
}

struct CanvasCompositeTileSnapshot: @unchecked Sendable {
    fileprivate final class Core: @unchecked Sendable {
        struct PendingReferenceLease: @unchecked Sendable {
            let provider: TiledRasterExactReferenceProvider
            let borrow: TiledRasterExactReferenceCapture.Borrow
            let reference: PaintTileReference
        }

        let provider: TiledRasterExactReferenceProvider
        let capture: TiledRasterExactReferenceCapture
        private let onClose: @Sendable () -> Void
        private let acquireReferenceLease: @Sendable (
            TiledRasterExactReferenceProvider,
            TiledRasterExactReferenceCapture.Borrow,
            [PaintTileReference],
            [PaintTilePinReason],
            (@Sendable () async -> Void)?
        ) async throws -> TiledRasterExactReferenceLease
        private let performPayloadProbe: @Sendable (
            TiledRasterExactReferenceProvider,
            TiledRasterExactReferenceCapture.Borrow,
            PaintTileReference,
            CanvasCompositePayloadProbe
        ) async throws -> CanvasCompositePayloadProbeResult
        private let lock = NSLock()
        private var closed = false
        private var activeReferenceLeaseOperations = 0
        private var finalized = false

        init(
            provider: TiledRasterExactReferenceProvider,
            capture: TiledRasterExactReferenceCapture,
            onClose: @escaping @Sendable () -> Void,
            acquireReferenceLease: @escaping @Sendable (
                TiledRasterExactReferenceProvider,
                TiledRasterExactReferenceCapture.Borrow,
                [PaintTileReference],
                [PaintTilePinReason],
                (@Sendable () async -> Void)?
            ) async throws -> TiledRasterExactReferenceLease,
            performPayloadProbe: @escaping @Sendable (
                TiledRasterExactReferenceProvider,
                TiledRasterExactReferenceCapture.Borrow,
                PaintTileReference,
                CanvasCompositePayloadProbe
            ) async throws -> CanvasCompositePayloadProbeResult
        ) {
            self.provider = provider
            self.capture = capture
            self.onClose = onClose
            self.acquireReferenceLease = acquireReferenceLease
            self.performPayloadProbe = performPayloadProbe
        }

        var isClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return closed
        }

        func withOpen<T>(
            _ operation: (
                TiledRasterExactReferenceProvider,
                TiledRasterExactReferenceCapture
            ) throws -> T
        ) throws -> T {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else {
                throw CanvasCompositeTileCacheError.closedSnapshot
            }
            return try operation(provider, capture)
        }

        func close() {
            lock.lock()
            guard !closed else {
                lock.unlock()
                return
            }
            closed = true
            let shouldFinalize = activeReferenceLeaseOperations == 0
                && !finalized
            if shouldFinalize { finalized = true }
            lock.unlock()
            if shouldFinalize {
                capture.close()
                onClose()
            }
        }

        func beginReferenceLease(
            at coordinate: PaintTileCoordinate
        ) throws -> PendingReferenceLease {
            lock.lock()
            defer { lock.unlock() }
            guard !closed,
                  let reference = provider.references.first(where: {
                      $0.coordinate == coordinate
                  })
            else { throw CanvasCompositeTileCacheError.closedSnapshot }
            let borrow = try capture.borrowing(providers: [provider])
            activeReferenceLeaseOperations += 1
            return PendingReferenceLease(
                provider: provider,
                borrow: borrow,
                reference: reference
            )
        }

        func acquire(
            _ pending: PendingReferenceLease,
            beforeWorkspaceObservationForTesting:
                (@Sendable () async -> Void)?
        ) async throws -> TiledRasterExactReferenceLease {
            try await acquireReferenceLease(
                pending.provider,
                pending.borrow,
                [pending.reference],
                [.inFlight],
                beforeWorkspaceObservationForTesting
            )
        }

        func probe(
            _ pending: PendingReferenceLease,
            operation: CanvasCompositePayloadProbe
        ) async throws -> CanvasCompositePayloadProbeResult {
            try await performPayloadProbe(
                pending.provider,
                pending.borrow,
                pending.reference,
                operation
            )
        }

        func finishReferenceLease(_ pending: PendingReferenceLease) {
            pending.borrow.close()
            lock.lock()
            precondition(activeReferenceLeaseOperations > 0)
            activeReferenceLeaseOperations -= 1
            let shouldFinalize = closed
                && activeReferenceLeaseOperations == 0
                && !finalized
            if shouldFinalize { finalized = true }
            lock.unlock()
            if shouldFinalize {
                capture.close()
                onClose()
            }
        }

        deinit { close() }
    }

    let revision: CanvasCompositeRevision
    let residentByteCount: Int
    let pixelSize: PixelSize
    private let core: Core

    fileprivate init(
        revision: CanvasCompositeRevision,
        residentByteCount: Int,
        provider: TiledRasterExactReferenceProvider,
        capture: TiledRasterExactReferenceCapture,
        onClose: @escaping @Sendable () -> Void,
        acquireReferenceLease: @escaping @Sendable (
            TiledRasterExactReferenceProvider,
            TiledRasterExactReferenceCapture.Borrow,
            [PaintTileReference],
            [PaintTilePinReason],
            (@Sendable () async -> Void)?
        ) async throws -> TiledRasterExactReferenceLease,
        performPayloadProbe: @escaping @Sendable (
            TiledRasterExactReferenceProvider,
            TiledRasterExactReferenceCapture.Borrow,
            PaintTileReference,
            CanvasCompositePayloadProbe
        ) async throws -> CanvasCompositePayloadProbeResult
    ) {
        self.revision = revision
        self.residentByteCount = residentByteCount
        pixelSize = provider.pixelSize
        core = Core(
            provider: provider,
            capture: capture,
            onClose: onClose,
            acquireReferenceLease: acquireReferenceLease,
            performPayloadProbe: performPayloadProbe
        )
    }

    var isClosed: Bool { core.isClosed }

    func exactReferences() throws -> [PaintTileReference] {
        try core.withOpen { provider, _ in provider.references }
    }

    #if DEBUG
    func testingPayloadFingerprint(
        at coordinate: PaintTileCoordinate
    ) async throws -> UInt64 {
        let pending = try core.beginReferenceLease(at: coordinate)
        defer { core.finishReferenceLease(pending) }
        switch try await core.probe(pending, operation: .fingerprint) {
        case .fingerprint(let value): return value
        case .rgba16Texel: throw CanvasCompositeTileCacheError.invalidPlan
        }
    }

    func testingRGBA16FirstTexel(
        at coordinate: PaintTileCoordinate
    ) async throws -> SIMD4<Float16> {
        try await testingRGBA16Texel(at: coordinate, x: 0, y: 0)
    }

    func testingEncodedBGRA8Fingerprint(
        at coordinate: PaintTileCoordinate
    ) async throws -> UInt64 {
        let pending = try core.beginReferenceLease(at: coordinate)
        defer { core.finishReferenceLease(pending) }
        switch try await core.probe(
            pending,
            operation: .encodedBGRA8Fingerprint
        ) {
        case .fingerprint(let value): return value
        case .rgba16Texel: throw CanvasCompositeTileCacheError.invalidPlan
        }
    }

    func testingRGBA16Texel(
        at coordinate: PaintTileCoordinate,
        x: Int,
        y: Int
    ) async throws -> SIMD4<Float16> {
        let pending = try core.beginReferenceLease(at: coordinate)
        defer { core.finishReferenceLease(pending) }
        switch try await core.probe(
            pending,
            operation: .rgba16Texel(x: x, y: y)
        ) {
        case .rgba16Texel(let value): return value
        case .fingerprint: throw CanvasCompositeTileCacheError.invalidPlan
        }
    }
    #endif

    func rehydrate(
        at coordinate: PaintTileCoordinate,
        beforeWorkspaceObservationForTesting:
            (@Sendable () async -> Void)? = nil
    ) async throws {
        let pending = try core.beginReferenceLease(at: coordinate)
        defer { core.finishReferenceLease(pending) }
        let lease = try await core.acquire(
            pending,
            beforeWorkspaceObservationForTesting:
                beforeWorkspaceObservationForTesting
        )
        try lease.returnLease()
    }

    func close() { core.close() }
}

private final class CanvasCompositeExternalSnapshotCounter:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func decrement() {
        lock.lock()
        precondition(value > 0)
        value -= 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

actor CanvasCompositeTileCache {
    private enum Lifecycle: Equatable {
        case active
        case shuttingDown
        case shutDown
    }

    private struct Published: @unchecked Sendable {
        let revision: CanvasCompositeRevision
        let provider: TiledRasterExactReferenceProvider
        let capture: TiledRasterExactReferenceCapture
    }

    private final class CleanupDebt: @unchecked Sendable {
        let surface: TiledRasterSurface
        var lease: PaintTileLease?
        var references: [PaintTileReference]
        var retirement: PaintTilePreparedRetirement?
        let failureInjection: CanvasCompositeCleanupFailureInjection?

        init(
            surface: TiledRasterSurface,
            lease: PaintTileLease?,
            references: [PaintTileReference],
            failureInjection: CanvasCompositeCleanupFailureInjection?
        ) {
            self.surface = surface
            self.lease = lease
            self.references = references
            self.failureInjection = failureInjection
        }
    }

    private let store: PaintTileStore
    private let compositor: CanonicalTileCompositor
    private var storagePixelSize: PixelSize
    private let logicalSurfaceID = UUID()
    private let layerID = UUID()
    private let policy: CanvasCompositeBatchPolicy
    private let baselineIdentity: CanvasCanonicalStateIdentity
    private let maximumPhysicalBytes: Int
    private let workspacePartitionBytes: Int
    private let snapshotMetadataPartitionBytes: Int
    private let externalSnapshots = CanvasCompositeExternalSnapshotCounter()
    private var published: Published?
    private var activeUpdateCount = 0
    private var physicalByteHighWater = 0
    private var snapshotMetadataByteHighWater = 0
    private var physicalAdmissionCount: UInt64 = 0
    private var lastCausalTransferAccounting:
        PaintTileTransferAccounting?
    private var lastBatchMetrics: CanvasCompositeBatchMetrics?
    private var maximumCandidateLeaseTileCount = 0
    private var lifecycle = Lifecycle.active
    private var activeUpdateWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, any Error>] = []
    private var cleanupDebts: [CleanupDebt] = []
    private var nextPublicationSequence: UInt64 = 1
    private var reservedSnapshotMetadataBytes = 0

    init(
        device: any MTLDevice,
        compositor: CanonicalTileCompositor,
        storagePixelSize: PixelSize,
        baselineIdentity: CanvasCanonicalStateIdentity,
        envelope: CanvasPresentationMemoryEnvelope = .production,
        policy: CanvasCompositeBatchPolicy = try! .init(
            maximumTilesPerChunk: 8,
            maximumLayersPerTile: LayerStack.maximumLayerCount
        )
    ) throws {
        _ = try envelope.checkedPartitionByteCount()
        guard compositor.declaredTileBatchWorkspaceBytes
                <= envelope.canonicalBatchWorkspaceBytes
        else {
            throw CanvasPresentationMemoryEnvelopeError.invalidPartition(
                required: compositor.declaredTileBatchWorkspaceBytes,
                maximum: envelope.canonicalBatchWorkspaceBytes
            )
        }
        self.compositor = compositor
        self.storagePixelSize = storagePixelSize
        self.baselineIdentity = baselineIdentity
        self.policy = policy
        maximumPhysicalBytes = envelope.canonicalCacheBytes
        workspacePartitionBytes = envelope.canonicalBatchWorkspaceBytes
        snapshotMetadataPartitionBytes =
            envelope.canonicalSnapshotMetadataBytes
        let storeCapacity = envelope.canonicalStoreTransferBytes
        store = PaintTileStore(
            device: device,
            byteBudget: envelope.canonicalResidentBytes,
            transferByteCapacity: storeCapacity,
            snapshotRetentionLimits: PaintTileSnapshotRetentionLimits(
                maximumActiveTokenCount: 256,
                maximumReferencesPerToken: 65_536,
                maximumAggregateReferenceCount: 262_144,
                maximumIndexEntryCount: 1_048_576,
                maximumMetadataBytes:
                    envelope.canonicalSnapshotMetadataBytes,
                maximumPayloadDebtBytes: storeCapacity
            )
        )
    }

    func apply(
        _ plan: CanvasCompositeTileUpdatePlan,
        destinationFailureInjection: PaintTileAllocationFailureInjection? = nil,
        failPublicationForTesting: Bool = false,
        afterCompositionForTesting:
            (@Sendable () async -> Void)? = nil,
        afterChunkForTesting:
            (@Sendable (_ chunkIndex: Int) async -> Void)? = nil,
        beforePublicationClaimForTesting:
            (@Sendable () async throws -> Void)? = nil,
        cleanupFailureInjection:
            CanvasCompositeCleanupFailureInjection? = nil,
        batchFailureInjection:
            LayerCompositeTileBatchFailureInjection? = nil
    ) async throws -> CanvasCompositeRevision {
        defer { plan.close() }
        guard lifecycle == .active else {
            throw CanvasCompositeTileCacheError.isShutdown
        }
        try await retryCleanup()
        guard plan.validatesPublicationClaim() else {
            throw CanvasCompositeTileCacheError.staleIdentity(
                expected: plan.targetIdentity,
                current: plan.currentClaimIdentityForDiagnostics
            )
        }
        try validateRevision(of: plan)
        try validateApplicationCoverage(of: plan)
        if plan.invalidation == .none {
            guard let published else {
                throw CanvasCompositeTileCacheError.invalidPlan
            }
            return published.revision
        }
        let metadataReservation = try reserveSnapshotMetadata(
            referenceCount: maximumPublishedReferenceCount(for: plan)
        )
        defer { releaseSnapshotMetadata(metadataReservation) }
        _ = try checkedNextSequence()
        activeUpdateCount += 1
        defer { finishActiveUpdate() }

        if plan.invalidation == .metadataOnly {
            return try await publishMetadataRebase(
                plan,
                beforePublicationClaimForTesting:
                    beforePublicationClaimForTesting
            )
        }
        if plan.dirtyCoordinates.isEmpty {
            guard plan.invalidation == .full,
                  published?.provider.references.isEmpty != false
                    || plan.baseIdentity.geometry != plan.targetIdentity.geometry
            else { throw CanvasCompositeTileCacheError.invalidPlan }
            return try await publishEmptyFullUpdate(
                plan,
                beforePublicationClaimForTesting:
                    beforePublicationClaimForTesting
            )
        }

        let targetStoragePixelSize = plan.targetIdentity.geometry.storagePixelSize
        let geometryChanged = plan.baseIdentity.geometry
            != plan.targetIdentity.geometry

        let candidate = TiledRasterSurface(
            store: store,
            layerID: layerID,
            pixelSize: targetStoragePixelSize,
            surfaceID: UUID(),
            generation: try checkedNextSequence(),
            initialRevision: RasterRevision(rawValue: 0)
        )
        var candidateLease: PaintTileLease?
        var allCandidateReferences: [PaintTileReference] = []
        do {
            var commandCount = 0
            var waitCount = 0
            var sampleCount = 0
            var maximumScratch = 0
            var maximumPrepared = 0
            var sampleOffset = 0
            var chunkIndex = 0
            var chunkStart = 0
            while chunkStart < plan.dirtyCoordinates.count {
                try Task.checkCancellation()
                guard lifecycle == .active else {
                    throw CanvasCompositeTileCacheError.isShutdown
                }
                let chunkEnd = min(
                    plan.dirtyCoordinates.count,
                    chunkStart + policy.maximumTilesPerChunk
                )
                let coordinates = Array(
                    plan.dirtyCoordinates[chunkStart..<chunkEnd]
                )
                let transferObservation = await compositor
                    .acquireWorkspaceObservation()
                let transferWorkspace = transferObservation.snapshot
                guard lifecycle == .active else {
                    transferObservation.close()
                    throw CanvasCompositeTileCacheError.isShutdown
                }
                do {
                    let reservation = try candidate
                        .reserveSortedUniqueTilesWithTransferReceipt(
                        at: coordinates,
                        pinReasons: [.inFlight],
                        failureInjection: destinationFailureInjection,
                        aggregateTransferAdmission:
                            PaintTileAggregateTransferAdmission(
                                additionalPhysicalBytes:
                                    transferWorkspace.physicalWorkspaceBytes,
                                maximumPhysicalBytes: maximumPhysicalBytes
                            )
                    )
                    candidateLease = reservation.value
                    recordCausalTransferAdmission(
                        reservation.transferAccounting
                    )
                } catch {
                    transferObservation.close()
                    throw error
                }
                transferObservation.close()
                maximumCandidateLeaseTileCount = max(
                    maximumCandidateLeaseTileCount,
                    candidateLease!.bindings.count
                )
                let chunkSampleCount = plan.preparedTiles.filter {
                    coordinates.contains($0.coordinate)
                }.reduce(0) { $0 + $1.layers.count }
                let localFailure = LayerCompositeTileBatchFailureInjection(
                    failingSampleEncodeIndex: batchFailureInjection?
                        .failingSampleEncodeIndex.flatMap { global in
                            global >= sampleOffset
                                && global < sampleOffset + chunkSampleCount
                                ? global - sampleOffset : nil
                        },
                    failingCommandTerminalChunkIndex:
                        batchFailureInjection?
                            .failingCommandTerminalChunkIndex == chunkIndex
                            ? 0 : nil
                )
                let batch = try await compositor.compositeTiles(
                    plan,
                    into: candidateLease!.bindings,
                    policy: policy,
                    failureInjection: localFailure
                )
                commandCount += batch.metrics.commandSubmissionCount
                waitCount += batch.metrics.commandWaitCount
                sampleCount += batch.metrics.sampleEncodeCount
                maximumScratch = max(
                    maximumScratch,
                    batch.metrics.maximumScratchPixelCount
                )
                maximumPrepared = max(
                    maximumPrepared,
                    batch.metrics.maximumPreparedSubmissionCount
                )
                let transparent = Set(batch.fullyTransparentCoordinates)
                let nontransparent = coordinates.filter {
                    !transparent.contains($0)
                }
                if !nontransparent.isEmpty {
                    try candidate.markDirty(
                        candidateLease!,
                        coordinates: nontransparent
                    )
                }
                if !transparent.isEmpty {
                    try candidate.markKnownClear(
                        candidateLease!,
                        coordinates: transparent.sorted()
                    )
                }
                try candidate.returnLease(candidateLease!)
                candidateLease = nil
                allCandidateReferences = candidate.references
                if let afterChunkForTesting {
                    await afterChunkForTesting(chunkIndex)
                }
                sampleOffset += chunkSampleCount
                chunkIndex += 1
                chunkStart = chunkEnd
            }
            lastBatchMetrics = CanvasCompositeBatchMetrics(
                commandSubmissionCount: commandCount,
                commandWaitCount: waitCount,
                sampleEncodeCount: sampleCount,
                scratchSetCount: commandCount == 0 ? 0 : 1,
                maximumScratchPixelCount: maximumScratch,
                maximumPreparedSubmissionCount: maximumPrepared
            )
            if let afterCompositionForTesting {
                await afterCompositionForTesting()
            }
            guard lifecycle == .active else {
                throw CanvasCompositeTileCacheError.isShutdown
            }
            try Task.checkCancellation()
            guard plan.validatesPublicationClaim() else {
                throw CanvasCompositeTileCacheError.staleIdentity(
                    expected: plan.targetIdentity,
                    current: plan.currentClaimIdentityForDiagnostics
                )
            }
            let candidateProvider = try candidate.makeExactReferenceProvider()
            let dirty = Set(plan.dirtyCoordinates)
            let carried = geometryChanged ? []
                : published?.provider.references.filter {
                    !dirty.contains($0.coordinate)
                } ?? []
            let merged = (carried + candidateProvider.references).sorted()
            let view = try TiledRasterCoordinateReferenceView(
                storeIdentity: store.identity,
                surfaceID: logicalSurfaceID,
                layerID: layerID,
                pixelSize: targetStoragePixelSize,
                generation: try checkedNextSequence(),
                revision: RasterRevision(rawValue: try checkedNextSequence()),
                references: merged
            )
            let logical = try TiledRasterSurface(
                store: store,
                referenceView: view
            )
            let provider = try logical.makeExactReferenceProvider()
            let capture = try TiledRasterExactReferenceCapture(
                providers: [provider]
            )
            await recordPhysicalAdmission()
            var capturePublished = false
            defer {
                if !capturePublished { capture.close() }
            }

            let mergedSet = Set(merged)
            let supersededPrior = geometryChanged
                ? published?.provider.references ?? []
                : (published?.provider.references ?? [])
                    .filter { dirty.contains($0.coordinate) }
            let superseded = (
                supersededPrior
                + allCandidateReferences.filter { !mergedSet.contains($0) }
            ).sorted()
            let retirement = superseded.isEmpty
                ? nil : try store.prepareRetirement(superseded)
            if failPublicationForTesting {
                if let retirement { store.cancelRetirement(retirement) }
                capture.close()
                throw CanvasCompositeTileCacheError.invalidPlan
            }
            try await beforePublicationClaimForTesting?()
            guard lifecycle == .active else {
                throw CanvasCompositeTileCacheError.isShutdown
            }
            guard plan.acquirePublicationClaim() else {
                if let retirement { store.cancelRetirement(retirement) }
                capture.close()
                throw CanvasCompositeTileCacheError.staleIdentity(
                    expected: plan.targetIdentity,
                    current: plan.currentClaimIdentityForDiagnostics
                )
            }
            let revision = CanvasCompositeRevision(
                identity: plan.targetIdentity,
                sequence: try checkedNextSequence()
            )
            let prior = published
            published = Published(
                revision: revision,
                provider: provider,
                capture: capture
            )
            plan.completePublicationClaim()
            consumeSequence()
            capturePublished = true
            storagePixelSize = targetStoragePixelSize
            prior?.capture.close()
            if let retirement { store.requestRetirement(retirement) }
            await updatePhysicalHighWater()
            return revision
        } catch {
            let operationError = error
            let debt = CleanupDebt(
                surface: candidate,
                lease: candidateLease,
                references: candidate.references,
                failureInjection: cleanupFailureInjection
            )
            do {
                try settleCleanupDebt(debt)
            } catch {
                cleanupDebts.append(debt)
                throw error
            }
            if let error = operationError as? PaintTileStoreError {
                throw await physicalCapacityError(for: error) ?? error
            }
            if let error = operationError as? PaintTileResidencyError,
               case let .insufficientCapacity(requested, _, _) = error {
                let compositorSnapshot = await compositor.snapshot()
                let value = store.snapshot()
                let current = Self.storePhysicalBytes(value)
                    + compositorSnapshot.physicalWorkspaceBytes
                throw CanvasCompositeTileCacheError
                    .physicalCapacityExceeded(
                        requested: requested + workspacePartitionBytes,
                        current: current,
                        highWater: max(physicalByteHighWater, current),
                        maximum: maximumPhysicalBytes
                    )
            }
            throw operationError
        }
    }

    func current(
        expected: CanvasCompositeRevision
    ) async throws -> CanvasCompositeTileSnapshot {
        guard lifecycle == .active else {
            throw CanvasCompositeTileCacheError.isShutdown
        }
        guard let publication = published,
              publication.revision == expected
        else {
            throw CanvasCompositeTileCacheError.invalidRevision
        }
        let metadataReservation = try reserveSnapshotMetadata(
            referenceCount: publication.provider.references.count
        )
        defer { releaseSnapshotMetadata(metadataReservation) }
        let capture = try TiledRasterExactReferenceCapture(
            providers: [publication.provider]
        )
        externalSnapshots.increment()
        var returnsSnapshot = false
        defer {
            if !returnsSnapshot {
                capture.close()
                externalSnapshots.decrement()
            }
        }
        let workspaceObservation = await compositor
            .acquireWorkspaceObservation()
        defer { workspaceObservation.close() }
        let compositorSnapshot = workspaceObservation.snapshot
        let value = store.snapshot()
        recordPhysicalObservation(
            store: value,
            compositor: compositorSnapshot,
            countsAsAdmission: true
        )
        guard lifecycle == .active else {
            throw CanvasCompositeTileCacheError.isShutdown
        }
        returnsSnapshot = true
        return CanvasCompositeTileSnapshot(
            revision: publication.revision,
            residentByteCount: publication.provider.backingSnapshot()
                .residentByteCount,
            provider: publication.provider,
            capture: capture,
            onClose: { [externalSnapshots] in
                externalSnapshots.decrement()
            },
            acquireReferenceLease: { [weak self]
                provider, borrow, references, pinReasons,
                beforeWorkspaceObservationForTesting in
                guard let self else {
                    throw CanvasCompositeTileCacheError.isShutdown
                }
                return try await self.acquireSnapshotReferenceLease(
                    provider: provider,
                    borrow: borrow,
                    references: references,
                    pinReasons: pinReasons,
                    beforeWorkspaceObservationForTesting:
                        beforeWorkspaceObservationForTesting
                )
            },
            performPayloadProbe: { [weak self]
                provider, borrow, reference, operation in
                guard let self else {
                    throw CanvasCompositeTileCacheError.isShutdown
                }
                return try await self.performSnapshotPayloadProbe(
                    provider: provider,
                    borrow: borrow,
                    reference: reference,
                    operation: operation
                )
            }
        )
    }

    func snapshot() async -> CanvasCompositeTileCacheSnapshot {
        let workspaceObservation = await compositor
            .acquireWorkspaceObservation()
        defer { workspaceObservation.close() }
        let compositorSnapshot = workspaceObservation.snapshot
        // Capture store/cache ownership after the only suspension point. This
        // is one actor-time view; no update can interleave with the remaining
        // synchronous reads.
        let value = store.snapshot()
        let storePhysical = Self.storePhysicalBytes(value)
        let workspacePhysical = compositorSnapshot.physicalWorkspaceBytes
        let physical = storePhysical + workspacePhysical
        recordPhysicalObservation(
            store: value,
            compositor: compositorSnapshot,
            countsAsAdmission: false
        )
        return CanvasCompositeTileCacheSnapshot(
            acceptsUpdates: lifecycle == .active,
            isShutDown: lifecycle == .shutDown,
            revision: published?.revision,
            cachedCoordinates: published?.provider.references
                .map(\.coordinate).sorted() ?? [],
            residentByteCount: value.residentByteCount,
            componentCoverageByteCount: value.componentCoverageByteCount,
            snapshotMetadataByteCount: value.snapshotMetadataByteCount,
            snapshotPayloadLiabilityByteCount:
                value.snapshotPayloadDebtByteCount,
            totalStorePhysicalByteCount: storePhysical,
            workspacePhysicalByteCount: workspacePhysical,
            totalPhysicalByteCount: physical,
            physicalByteHighWater: physicalByteHighWater,
            snapshotMetadataByteHighWater:
                snapshotMetadataByteHighWater,
            physicalAdmissionCount: physicalAdmissionCount,
            lastCausalTransferAccounting: lastCausalTransferAccounting,
            storeTransferPeakByteHighWater:
                value.transferPeakTrackedByteHighWater,
            workspacePhysicalByteHighWater:
                compositorSnapshot.physicalWorkspaceByteHighWater,
            maximumPhysicalBytes: maximumPhysicalBytes,
            activeSnapshotCount: externalSnapshots.count,
            activeUpdateCount: activeUpdateCount,
            sourceSnapshotTokenCount: value.activeSnapshotTokenCount,
            candidateLeaseCount: value.activeLeaseCount,
            preparedRetirementCount: value.preparedRetirementCount,
            pendingRetirementCount: value.pendingRetirementCount,
            maximumCandidateLeaseTileCount: maximumCandidateLeaseTileCount,
            cleanupDebtCount: cleanupDebts.count,
            compositorPendingPlanCompletionCount:
                compositorSnapshot.completion.pendingPlanCompletionCount,
            compositorPendingPlanMetalBufferBytes:
                compositorSnapshot.completion.pendingPlanMetalBufferBytes,
            lastBatchMetrics: lastBatchMetrics,
            leastRecentlyUsedCoordinates:
                value.leastRecentlyUsedOrder.compactMap { identity in
                    value.entries.first(where: {
                        $0.identity == identity
                    })?.descriptor.coordinate
                }
        )
    }

    func applyMemoryPressure(
        targetResidentBytes: Int,
        beforeWorkspaceObservationForTesting:
            (@Sendable () async -> Void)? = nil
    ) async throws -> PaintTilePressureResult {
        guard lifecycle == .active else {
            throw CanvasCompositeTileCacheError.isShutdown
        }
        await beforeWorkspaceObservationForTesting?()
        let workspaceObservation = await compositor
            .acquireWorkspaceObservation()
        defer { workspaceObservation.close() }
        let compositorSnapshot = workspaceObservation.snapshot
        guard lifecycle == .active else {
            throw CanvasCompositeTileCacheError.isShutdown
        }
        let operation = try store.applyMemoryPressureWithTransferReceipt(
            targetResidentBytes: targetResidentBytes,
            aggregateTransferAdmission: PaintTileAggregateTransferAdmission(
                additionalPhysicalBytes:
                    compositorSnapshot.physicalWorkspaceBytes,
                maximumPhysicalBytes: maximumPhysicalBytes
            )
        )
        recordCausalTransferAdmission(operation.transferAccounting)
        return operation.value
    }

    func shutdown(
        afterSnapshotCheckForTesting:
            (@Sendable () async -> Void)? = nil
    ) async throws {
        switch lifecycle {
        case .shutDown:
            return
        case .shuttingDown:
            try await withCheckedThrowingContinuation {
                shutdownWaiters.append($0)
            }
            return
        case .active:
            break
        }
        let externalCount = externalSnapshots.count
        guard externalCount == 0 else {
            throw CanvasCompositeTileCacheError
                .shutdownSnapshotsOutstanding(count: externalCount)
        }
        lifecycle = .shuttingDown
        do {
            await afterSnapshotCheckForTesting?()
            let recheckedExternalCount = externalSnapshots.count
            guard recheckedExternalCount == 0 else {
                throw CanvasCompositeTileCacheError
                    .shutdownSnapshotsOutstanding(
                        count: recheckedExternalCount
                    )
            }
            if activeUpdateCount > 0 {
                await withCheckedContinuation {
                    activeUpdateWaiters.append($0)
                }
            }
            try await retryCleanup()
            if let published {
                let references = published.provider.references
                let retirement = references.isEmpty
                    ? nil : try store.prepareRetirement(references)
                published.capture.close()
                self.published = nil
                if let retirement { store.requestRetirement(retirement) }
            }
            try await compositor.shutdown()
            store.releasePersistentZeroSourceIfUnowned()
            lifecycle = .shutDown
            let waiters = shutdownWaiters
            shutdownWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        } catch {
            // Every throwing shutdown stage occurs before destructive
            // compositor teardown. Restore admission so cleanup can be
            // retried; never strand callers behind `.shuttingDown`.
            lifecycle = .active
            let waiters = shutdownWaiters
            shutdownWaiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: error) }
            throw error
        }
    }

    func retryCleanup() async throws {
        while let debt = cleanupDebts.first {
            try settleCleanupDebt(debt)
            cleanupDebts.removeFirst()
        }
        store.releasePersistentZeroSourceIfUnowned()
        try await compositor.retryCleanup()
    }

    private func finishActiveUpdate() {
        precondition(activeUpdateCount > 0)
        activeUpdateCount -= 1
        guard activeUpdateCount == 0 else { return }
        let waiters = activeUpdateWaiters
        activeUpdateWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func maximumPublishedReferenceCount(
        for plan: CanvasCompositeTileUpdatePlan
    ) -> Int {
        guard plan.invalidation != .none else { return 0 }
        if plan.invalidation == .metadataOnly {
            return published?.provider.references.count ?? 0
        }
        guard !plan.dirtyCoordinates.isEmpty else { return 0 }
        let geometryChanged = plan.baseIdentity.geometry
            != plan.targetIdentity.geometry
        guard !geometryChanged else { return plan.dirtyCoordinates.count }
        let dirty = Set(plan.dirtyCoordinates)
        let carriedCount = published?.provider.references.reduce(into: 0) {
            if !dirty.contains($1.coordinate) { $0 += 1 }
        } ?? 0
        return carriedCount + plan.dirtyCoordinates.count
    }

    private func reserveSnapshotMetadata(
        referenceCount: Int
    ) throws -> Int {
        guard referenceCount > 0 else { return 0 }
        let (referenceBytes, productOverflow) = referenceCount
            .multipliedReportingOverflow(
                by: PaintTileStore.snapshotRetentionReferenceMetadataBytes
            )
        let (required, sumOverflow) = referenceBytes.addingReportingOverflow(
            PaintTileStore.snapshotRetentionFixedMetadataBytes
        )
        let actual = store.snapshot().snapshotMetadataByteCount
        let (withReserved, reservedOverflow) = actual.addingReportingOverflow(
            reservedSnapshotMetadataBytes
        )
        let (next, nextOverflow) = withReserved.addingReportingOverflow(
            required
        )
        guard !productOverflow, !sumOverflow, !reservedOverflow,
              !nextOverflow, next <= snapshotMetadataPartitionBytes
        else {
            throw CanvasCompositeTileCacheError
                .snapshotMetadataCapacityExceeded(
                    required: productOverflow || sumOverflow
                        || reservedOverflow || nextOverflow ? .max : next,
                    maximum: snapshotMetadataPartitionBytes
                )
        }
        reservedSnapshotMetadataBytes += required
        return required
    }

    private func releaseSnapshotMetadata(_ bytes: Int) {
        precondition(bytes >= 0 && reservedSnapshotMetadataBytes >= bytes)
        reservedSnapshotMetadataBytes -= bytes
    }

    private func checkedNextSequence() throws -> UInt64 {
        guard nextPublicationSequence != .max else {
            throw CanvasCompositeTileCacheError.sequenceOverflow
        }
        return nextPublicationSequence
    }

    private func consumeSequence() {
        nextPublicationSequence += 1
    }

    #if DEBUG
    func testingSetSequenceForNextPublication(_ value: UInt64) {
        nextPublicationSequence = value
    }
    #endif

    private func validateRevision(
        of plan: CanvasCompositeTileUpdatePlan
    ) throws {
        if let published {
            guard published.revision.identity == plan.baseIdentity else {
                throw CanvasCompositeTileCacheError.revisionGap(
                    expectedBase: published.revision.identity,
                    actualBase: plan.baseIdentity
                )
            }
        } else {
            guard plan.invalidation == .full else {
                throw CanvasCompositeTileCacheError.revisionGap(
                    expectedBase: plan.baseIdentity,
                    actualBase: nil
                )
            }
            if plan.baseIdentity == plan.targetIdentity {
                return
            }
            guard plan.baseIdentity == baselineIdentity else {
                throw CanvasCompositeTileCacheError.revisionGap(
                    expectedBase: baselineIdentity,
                    actualBase: plan.baseIdentity
                )
            }
        }
        let base = plan.baseIdentity
        let target = plan.targetIdentity
        switch plan.invalidation {
        case .exact:
            let (nextComposite, overflow) = base.compositeRevision
                .addingReportingOverflow(1)
            guard !overflow,
                  target.documentGeneration == base.documentGeneration,
                  target.geometryRevision == base.geometryRevision,
                  target.layerStackRevision == base.layerStackRevision,
                  target.compositeRevision == nextComposite
            else {
                throw CanvasCompositeTileCacheError.revisionGap(
                    expectedBase: base,
                    actualBase: target
                )
            }
        case .full:
            let (nextComposite, compositeOverflow) = base.compositeRevision
                .addingReportingOverflow(1)
            let geometryIsCurrentOrNext = Self.isCurrentOrNext(
                target.geometryRevision,
                from: base.geometryRevision
            )
            let layerIsCurrentOrNext = Self.isCurrentOrNext(
                target.layerStackRevision,
                from: base.layerStackRevision
            )
            guard !compositeOverflow,
                  target.documentGeneration == base.documentGeneration,
                  geometryIsCurrentOrNext,
                  layerIsCurrentOrNext,
                  target.compositeRevision == nextComposite
            else {
                throw CanvasCompositeTileCacheError.revisionGap(
                    expectedBase: base,
                    actualBase: target
                )
            }
        case .metadataOnly:
            let (nextLayer, layerOverflow) = base.layerStackRevision
                .addingReportingOverflow(1)
            guard !layerOverflow,
                  target.documentGeneration == base.documentGeneration,
                  target.geometryRevision == base.geometryRevision,
                  target.layerStackRevision == nextLayer,
                  target.compositeRevision == base.compositeRevision
            else {
                throw CanvasCompositeTileCacheError.revisionGap(
                    expectedBase: base,
                    actualBase: target
                )
            }
        case .none:
            guard target == base else {
                throw CanvasCompositeTileCacheError.revisionGap(
                    expectedBase: base,
                    actualBase: target
                )
            }
        }
    }

    private func validateApplicationCoverage(
        of plan: CanvasCompositeTileUpdatePlan
    ) throws {
        let actual = CanvasCompositeInvalidation.sortedUnique(
            plan.dirtyCoordinates
        )
        guard actual == plan.dirtyCoordinates,
              plan.applicationDescriptor.baseIdentity == plan.baseIdentity,
              plan.applicationDescriptor.targetIdentity == plan.targetIdentity,
              plan.applicationDescriptor.invalidation == plan.invalidation
        else { throw CanvasCompositeTileCacheError.invalidPlan }

        let expected: [PaintTileCoordinate]
        switch plan.invalidation {
        case .none, .metadataOnly:
            expected = []
        case .exact(let coordinates):
            expected = CanvasCompositeInvalidation.sortedUnique(coordinates)
        case .full:
            let carried = plan.baseIdentity.geometry == plan.targetIdentity.geometry
                ? published?.provider.references.map(\.coordinate) ?? []
                : []
            expected = CanvasCompositeInvalidation.sortedUnique(
                carried
                    + plan.applicationDescriptor.targetVisibleCoordinates
            )
        }
        guard actual == expected,
              plan.preparedTiles.map(\.coordinate) == actual
                    || !plan.invalidation.affectsPixels
        else { throw CanvasCompositeTileCacheError.invalidPlan }
    }

    private static func isCurrentOrNext(
        _ candidate: UInt64,
        from current: UInt64
    ) -> Bool {
        candidate == current
            || (current != .max && candidate == current + 1)
    }

    private func publishMetadataRebase(
        _ plan: CanvasCompositeTileUpdatePlan,
        beforePublicationClaimForTesting:
            (@Sendable () async throws -> Void)?
    ) async throws -> CanvasCompositeRevision {
        guard let prior = published,
              plan.dirtyCoordinates.isEmpty,
              plan.validatesPublicationClaim()
        else { throw CanvasCompositeTileCacheError.invalidPlan }
        let view = try TiledRasterCoordinateReferenceView(
            storeIdentity: store.identity,
            surfaceID: logicalSurfaceID,
            layerID: layerID,
            pixelSize: storagePixelSize,
            generation: try checkedNextSequence(),
            revision: RasterRevision(rawValue: try checkedNextSequence()),
            references: prior.provider.references
        )
        let logical = try TiledRasterSurface(store: store, referenceView: view)
        let provider = try logical.makeExactReferenceProvider()
        let capture = try TiledRasterExactReferenceCapture(
            providers: [provider]
        )
        await recordPhysicalAdmission()
        var capturePublished = false
        defer {
            if !capturePublished { capture.close() }
        }
        try await beforePublicationClaimForTesting?()
        guard lifecycle == .active else {
            throw CanvasCompositeTileCacheError.isShutdown
        }
        guard plan.acquirePublicationClaim() else {
            capture.close()
            throw CanvasCompositeTileCacheError.staleIdentity(
                expected: plan.targetIdentity,
                current: plan.currentClaimIdentityForDiagnostics
            )
        }
        let revision = CanvasCompositeRevision(
            identity: plan.targetIdentity,
            sequence: try checkedNextSequence()
        )
        published = Published(
            revision: revision,
            provider: provider,
            capture: capture
        )
        plan.completePublicationClaim()
        consumeSequence()
        capturePublished = true
        prior.capture.close()
        return revision
    }

    private func publishEmptyFullUpdate(
        _ plan: CanvasCompositeTileUpdatePlan,
        beforePublicationClaimForTesting:
            (@Sendable () async throws -> Void)?
    ) async throws -> CanvasCompositeRevision {
        guard plan.preparedTiles.isEmpty,
              plan.validatesPublicationClaim()
        else { throw CanvasCompositeTileCacheError.invalidPlan }
        let targetStoragePixelSize = plan.targetIdentity.geometry.storagePixelSize
        let view = try TiledRasterCoordinateReferenceView(
            storeIdentity: store.identity,
            surfaceID: logicalSurfaceID,
            layerID: layerID,
            pixelSize: targetStoragePixelSize,
            generation: try checkedNextSequence(),
            revision: RasterRevision(rawValue: try checkedNextSequence()),
            references: []
        )
        let logical = try TiledRasterSurface(store: store, referenceView: view)
        let provider = try logical.makeExactReferenceProvider()
        let capture = try TiledRasterExactReferenceCapture(
            providers: [provider]
        )
        await recordPhysicalAdmission()
        var capturePublished = false
        defer {
            if !capturePublished { capture.close() }
        }
        guard plan.validatesPublicationClaim() else {
            capture.close()
            throw CanvasCompositeTileCacheError.staleIdentity(
                expected: plan.targetIdentity,
                current: plan.currentClaimIdentityForDiagnostics
            )
        }
        let superseded = published?.provider.references ?? []
        let retirement = superseded.isEmpty
            ? nil : try store.prepareRetirement(superseded)
        try await beforePublicationClaimForTesting?()
        guard lifecycle == .active else {
            if let retirement { store.cancelRetirement(retirement) }
            throw CanvasCompositeTileCacheError.isShutdown
        }
        guard plan.acquirePublicationClaim() else {
            if let retirement { store.cancelRetirement(retirement) }
            capture.close()
            throw CanvasCompositeTileCacheError.staleIdentity(
                expected: plan.targetIdentity,
                current: plan.currentClaimIdentityForDiagnostics
            )
        }
        let revision = CanvasCompositeRevision(
            identity: plan.targetIdentity,
            sequence: try checkedNextSequence()
        )
        let prior = published
        published = Published(
            revision: revision,
            provider: provider,
            capture: capture
        )
        plan.completePublicationClaim()
        consumeSequence()
        capturePublished = true
        storagePixelSize = targetStoragePixelSize
        prior?.capture.close()
        if let retirement { store.requestRetirement(retirement) }
        lastBatchMetrics = try? policy.structuralMetrics(
            tileCount: 0,
            layerCount: 0
        )
        return revision
    }

    private func settleCleanupDebt(_ debt: CleanupDebt) throws {
        if let lease = debt.lease {
            if debt.failureInjection?.shouldFail(.leaseReturn) == true {
                throw CanvasCompositeTileCacheError.cleanupPending(
                    stage: .leaseReturn
                )
            }
            try debt.surface.returnLease(lease)
            debt.lease = nil
            debt.references = debt.surface.references
        }
        guard !debt.references.isEmpty || debt.retirement != nil else { return }
        if debt.retirement == nil {
            if debt.failureInjection?.shouldFail(.retirementPrepare) == true {
                throw CanvasCompositeTileCacheError.cleanupPending(
                    stage: .retirementPrepare
                )
            }
            debt.retirement = try store.prepareRetirement(
                debt.references.sorted()
            )
        }
        if debt.failureInjection?.shouldFail(.retirementRequest) == true {
            throw CanvasCompositeTileCacheError.cleanupPending(
                stage: .retirementRequest
            )
        }
        store.requestRetirement(debt.retirement!)
        debt.retirement = nil
        debt.references = []
        store.releasePersistentZeroSourceIfUnowned()
    }

    private func updatePhysicalHighWater() async {
        let workspaceObservation = await compositor
            .acquireWorkspaceObservation()
        defer { workspaceObservation.close() }
        let compositorSnapshot = workspaceObservation.snapshot
        let value = store.snapshot()
        recordPhysicalObservation(
            store: value,
            compositor: compositorSnapshot,
            countsAsAdmission: false
        )
    }

    private func recordPhysicalAdmission() async {
        let workspaceObservation = await compositor
            .acquireWorkspaceObservation()
        defer { workspaceObservation.close() }
        let compositorSnapshot = workspaceObservation.snapshot
        let value = store.snapshot()
        recordPhysicalObservation(
            store: value,
            compositor: compositorSnapshot,
            countsAsAdmission: true
        )
    }

    private func recordPhysicalObservation(
        store value: PaintTileStoreSnapshot,
        compositor compositorSnapshot: LayerCompositorSnapshot,
        countsAsAdmission: Bool
    ) {
        snapshotMetadataByteHighWater = max(
            snapshotMetadataByteHighWater,
            value.snapshotMetadataByteCount
        )
        let (physical, overflow) = Self.storePhysicalBytes(value)
            .addingReportingOverflow(
                compositorSnapshot.physicalWorkspaceBytes
            )
        physicalByteHighWater = max(
            physicalByteHighWater,
            overflow ? .max : physical
        )
        if countsAsAdmission {
            let (next, admissionOverflow) = physicalAdmissionCount
                .addingReportingOverflow(1)
            physicalAdmissionCount = admissionOverflow ? .max : next
        }
    }

    private func recordCausalTransferAdmission(
        _ accounting: PaintTileTransferAccounting?
    ) {
        guard let accounting else { return }
        snapshotMetadataByteHighWater = max(
            snapshotMetadataByteHighWater,
            accounting.snapshotMetadataBytesAtPeak
        )
        physicalByteHighWater = max(
            physicalByteHighWater,
            accounting.aggregatePeakTrackedBytes
        )
        lastCausalTransferAccounting = accounting
        let (next, overflow) = physicalAdmissionCount
            .addingReportingOverflow(1)
        physicalAdmissionCount = overflow ? .max : next
    }

    private func acquireSnapshotReferenceLease(
        provider: TiledRasterExactReferenceProvider,
        borrow: TiledRasterExactReferenceCapture.Borrow,
        references: [PaintTileReference],
        pinReasons: [PaintTilePinReason],
        beforeWorkspaceObservationForTesting:
            (@Sendable () async -> Void)?
    ) async throws -> TiledRasterExactReferenceLease {
        guard lifecycle == .active else {
            throw CanvasCompositeTileCacheError.isShutdown
        }
        await beforeWorkspaceObservationForTesting?()
        let workspaceObservation = await compositor
            .acquireWorkspaceObservation()
        defer { workspaceObservation.close() }
        let compositorSnapshot = workspaceObservation.snapshot
        guard lifecycle == .active else {
            throw CanvasCompositeTileCacheError.isShutdown
        }
        let lease = try provider.leaseExactReferences(
            references,
            using: borrow,
            pinReasons: pinReasons,
            aggregateTransferAdmission: PaintTileAggregateTransferAdmission(
                additionalPhysicalBytes:
                    compositorSnapshot.physicalWorkspaceBytes,
                maximumPhysicalBytes: maximumPhysicalBytes
            )
        )
        recordCausalTransferAdmission(lease.transferAccounting)
        return lease
    }

    private func performSnapshotPayloadProbe(
        provider: TiledRasterExactReferenceProvider,
        borrow: TiledRasterExactReferenceCapture.Borrow,
        reference: PaintTileReference,
        operation: CanvasCompositePayloadProbe
    ) async throws -> CanvasCompositePayloadProbeResult {
        guard lifecycle == .active else {
            throw CanvasCompositeTileCacheError.isShutdown
        }
        let workspaceObservation = await compositor
            .acquireWorkspaceObservation()
        defer { workspaceObservation.close() }
        let compositorSnapshot = workspaceObservation.snapshot
        guard lifecycle == .active else {
            throw CanvasCompositeTileCacheError.isShutdown
        }
        let payload = try borrow.payloadWithTransferReceipt(
            reference,
            from: provider,
            aggregateTransferAdmission: PaintTileAggregateTransferAdmission(
                additionalPhysicalBytes:
                    compositorSnapshot.physicalWorkspaceBytes,
                maximumPhysicalBytes: maximumPhysicalBytes
            )
        )
        recordCausalTransferAdmission(payload.transferAccounting)
        switch (operation, payload.value) {
        case (.fingerprint, .knownClear):
            return .fingerprint(0)
        case (.fingerprint, .rgba16Float(let data)):
            return .fingerprint(data.withUnsafeBytes { bytes in
                var hash: UInt64 = 1_469_598_103_934_665_603
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash &*= 1_099_511_628_211
                }
                return hash
            })
        case (.encodedBGRA8Fingerprint, .knownClear):
            return .fingerprint(0)
        case (.encodedBGRA8Fingerprint, .rgba16Float(let data)):
            let hash: UInt64 = try data.withUnsafeBytes { bytes in
                var hash: UInt64 = 1_469_598_103_934_665_603
                for offset in stride(from: 0, to: bytes.count, by: 8) {
                    guard let color = LinearPremultipliedColor(
                        red: Float(Float16(bitPattern: bytes.loadUnaligned(
                            fromByteOffset: offset,
                            as: UInt16.self
                        ))),
                        green: Float(Float16(bitPattern: bytes.loadUnaligned(
                            fromByteOffset: offset + 2,
                            as: UInt16.self
                        ))),
                        blue: Float(Float16(bitPattern: bytes.loadUnaligned(
                            fromByteOffset: offset + 4,
                            as: UInt16.self
                        ))),
                        alpha: Float(Float16(bitPattern: bytes.loadUnaligned(
                            fromByteOffset: offset + 6,
                            as: UInt16.self
                        )))
                    ) else { throw CanvasCompositeTileCacheError.invalidPlan }
                    let pixel = DocumentColorPipeline
                        .exportEncodedPremultipliedBGRA8(color)
                    for byte in [
                        pixel.blue, pixel.green, pixel.red, pixel.alpha,
                    ] {
                        hash ^= UInt64(byte)
                        hash &*= 1_099_511_628_211
                    }
                }
                return hash
            }
            return .fingerprint(hash)
        case (.rgba16Texel, .knownClear):
            return .rgba16Texel(.zero)
        case let (.rgba16Texel(x, y), .rgba16Float(data)):
            guard x >= 0, y >= 0,
                  x < PaintTileDescriptor.side,
                  y < PaintTileDescriptor.side
            else { throw CanvasCompositeTileCacheError.invalidPlan }
            let offset = (y * PaintTileDescriptor.side + x) * 8
            let texel: SIMD4<Float16> = data.withUnsafeBytes { bytes in
                let red = bytes.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt16.self
                )
                let green = bytes.loadUnaligned(
                    fromByteOffset: offset + 2,
                    as: UInt16.self
                )
                let blue = bytes.loadUnaligned(
                    fromByteOffset: offset + 4,
                    as: UInt16.self
                )
                let alpha = bytes.loadUnaligned(
                    fromByteOffset: offset + 6,
                    as: UInt16.self
                )
                return SIMD4(
                    Float16(bitPattern: red),
                    Float16(bitPattern: green),
                    Float16(bitPattern: blue),
                    Float16(bitPattern: alpha)
                )
            }
            return .rgba16Texel(texel)
        }
    }

    private func physicalCapacityError(
        for error: PaintTileStoreError
    ) async -> CanvasCompositeTileCacheError? {
        guard case let .transferCapacityExceeded(
            required,
            _,
            _,
            _,
            _,
            _
        ) = error else { return nil }
        let workspaceObservation = await compositor
            .acquireWorkspaceObservation()
        defer { workspaceObservation.close() }
        let compositorSnapshot = workspaceObservation.snapshot
        let value = store.snapshot()
        let current = Self.storePhysicalBytes(value)
            + compositorSnapshot.physicalWorkspaceBytes
        let requestedParts = [
            required,
            workspacePartitionBytes,
            value.snapshotMetadataByteCount,
            reservedSnapshotMetadataBytes,
        ]
        var requested = 0
        for part in requestedParts {
            let (next, overflow) = requested.addingReportingOverflow(part)
            if overflow {
                requested = .max
                break
            }
            requested = next
        }
        let highWater = max(
            physicalByteHighWater,
            current
        )
        return .physicalCapacityExceeded(
            requested: requested,
            current: current,
            highWater: highWater,
            maximum: maximumPhysicalBytes
        )
    }

    private static func storePhysicalBytes(
        _ value: PaintTileStoreSnapshot
    ) -> Int {
        value.residentByteCount
            + value.backingByteCount
            + value.persistentZeroAllocationBytes
            + value.provisionalByteCount
            + value.snapshotMetadataByteCount
    }
}
