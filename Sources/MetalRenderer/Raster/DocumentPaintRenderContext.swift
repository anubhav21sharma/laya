import Foundation
@preconcurrency import Metal
import EditorCore
import PatternEngine

struct CanvasCanonicalApplicationDescriptor: Equatable, Sendable {
    let baseIdentity: CanvasCanonicalStateIdentity
    let targetIdentity: CanvasCanonicalStateIdentity
    let invalidation: CanvasCompositeInvalidation
    let targetVisibleCoordinates: [PaintTileCoordinate]

    init(
        baseIdentity: CanvasCanonicalStateIdentity,
        targetIdentity: CanvasCanonicalStateIdentity,
        invalidation: CanvasCompositeInvalidation,
        targetVisibleCoordinates: [PaintTileCoordinate]
    ) {
        self.baseIdentity = baseIdentity
        self.targetIdentity = targetIdentity
        switch invalidation {
        case .exact(let coordinates):
            self.invalidation = .exact(
                CanvasCompositeInvalidation.sortedUnique(coordinates)
            )
        case .none:
            self.invalidation = .none
        case .full:
            self.invalidation = .full
        case .metadataOnly:
            self.invalidation = .metadataOnly
        }
        self.targetVisibleCoordinates = CanvasCompositeInvalidation
            .sortedUnique(targetVisibleCoordinates)
    }
}

/// Synchronous one-shot publication capability minted only by one Context.
/// Validation for source preparation is non-consuming. Cache publication must
/// atomically acquire the claim immediately before assigning its published
/// root; a newer Context identity can revoke only a still-pending claim.
final class CanvasCanonicalIdentityClaim: @unchecked Sendable {
    private enum State {
        case pending
        case publicationOwned
        case published
        case revoked
    }

    let descriptor: CanvasCanonicalApplicationDescriptor
    private let contextIdentity: UUID
    private let lock = NSLock()
    private var state = State.pending
    private var revokingIdentity: CanvasCanonicalStateIdentity?

    fileprivate init(
        descriptor: CanvasCanonicalApplicationDescriptor,
        contextIdentity: UUID
    ) {
        self.descriptor = descriptor
        self.contextIdentity = contextIdentity
    }

    var identity: CanvasCanonicalStateIdentity {
        descriptor.targetIdentity
    }

    fileprivate func invalidate(
        from contextIdentity: UUID,
        currentIdentity: CanvasCanonicalStateIdentity
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard self.contextIdentity == contextIdentity else { return }
        if state == .pending {
            state = .revoked
            revokingIdentity = currentIdentity
        }
    }

    var currentIdentityForDiagnostics: CanvasCanonicalStateIdentity {
        lock.lock()
        defer { lock.unlock() }
        return revokingIdentity ?? descriptor.targetIdentity
    }

    func validatesPreparation(
        baseIdentity: CanvasCanonicalStateIdentity,
        targetIdentity: CanvasCanonicalStateIdentity,
        invalidation: CanvasCompositeInvalidation
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let expected = CanvasCanonicalApplicationDescriptor(
            baseIdentity: baseIdentity,
            targetIdentity: targetIdentity,
            invalidation: invalidation,
            targetVisibleCoordinates: descriptor.targetVisibleCoordinates
        )
        return state == .pending && expected == descriptor
    }

    func validatesPendingPublication(
        _ expected: CanvasCanonicalApplicationDescriptor
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .pending && expected == descriptor
    }

    func acquirePublication(
        _ expected: CanvasCanonicalApplicationDescriptor
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .pending, expected == descriptor else { return false }
        state = .publicationOwned
        return true
    }

    func completePublication() {
        lock.lock()
        defer { lock.unlock() }
        precondition(state == .publicationOwned)
        state = .published
    }
}

enum DocumentPaintRenderContextError: Error, Equatable, Sendable {
    case activeStrokeExists
    case noActiveStroke
    case foreignTransientDisplayFrame
    case activeTransientDisplaySourceExists
    case staleTransientDisplaySource
    case activeCommandOperationExists
    case activeLayerLocked(UUID)
    case layerHistoryBudgetExceeded(required: Int, available: Int)
    case layerHistoryIdentityOverflow
    case missingLayerHistoryRevision(StoredRasterRevisionID)
    case canonicalIdentityOverflow
    case isShutdown
}

struct DocumentPaintSurfaceApplicationResult: Equatable, Sendable {
    let didPublish: Bool
    let layerID: UUID
    let generation: UInt64
    let dirtyCoordinates: [PaintTileCoordinate]
    let baseCanonicalIdentity: CanvasCanonicalStateIdentity
    let canonicalIdentity: CanvasCanonicalStateIdentity
    let compositeInvalidation: CanvasCompositeInvalidation
    let historyPair: PendingRasterRevisionPair?
}

private struct DocumentPaintSurfaceWorkerResult: Equatable, Sendable {
    let didPublish: Bool
    let layerID: UUID
    let generation: UInt64
    let dirtyCoordinates: [PaintTileCoordinate]
    let historyPair: PendingRasterRevisionPair?
}

private struct DocumentPaintPreparedCanonicalRevisionAdvance: Sendable {
    let geometryRevision: UInt64
    let layerStackRevision: UInt64
    let compositeRevision: UInt64
}

private final class DocumentPaintCanonicalRevisionReservation:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let currentGeometryRevision: UInt64
    private let currentLayerStackRevision: UInt64
    private let currentCompositeRevision: UInt64
    private let advancesGeometry: Bool
    private let advancesLayerStack: Bool
    private let advancesComposite: Bool
    private let documentGeneration: UInt64
    private var prepared:
        DocumentPaintPreparedCanonicalRevisionAdvance?
    private var publishedIdentity: CanvasCanonicalStateIdentity?

    init(
        geometryRevision: UInt64,
        layerStackRevision: UInt64,
        compositeRevision: UInt64,
        documentGeneration: UInt64,
        advancesGeometry: Bool,
        advancesLayerStack: Bool,
        advancesComposite: Bool
    ) {
        currentGeometryRevision = geometryRevision
        currentLayerStackRevision = layerStackRevision
        currentCompositeRevision = compositeRevision
        self.documentGeneration = documentGeneration
        self.advancesGeometry = advancesGeometry
        self.advancesLayerStack = advancesLayerStack
        self.advancesComposite = advancesComposite
    }

    func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        if prepared != nil { return }
        func advanced(_ value: UInt64, when shouldAdvance: Bool) throws
            -> UInt64
        {
            guard shouldAdvance else { return value }
            let (next, overflow) = value.addingReportingOverflow(1)
            guard !overflow else {
                throw DocumentPaintRenderContextError
                    .canonicalIdentityOverflow
            }
            return next
        }
        prepared = try DocumentPaintPreparedCanonicalRevisionAdvance(
            geometryRevision: advanced(
                currentGeometryRevision,
                when: advancesGeometry
            ),
            layerStackRevision: advanced(
                currentLayerStackRevision,
                when: advancesLayerStack
            ),
            compositeRevision: advanced(
                currentCompositeRevision,
                when: advancesComposite
            )
        )
    }

    func result() -> DocumentPaintPreparedCanonicalRevisionAdvance? {
        lock.lock()
        defer { lock.unlock() }
        return prepared
    }

    func markPublished(geometry: DocumentPaintGeometry) {
        lock.lock()
        defer { lock.unlock() }
        guard let prepared else {
            preconditionFailure("Canonical publication was not preflighted")
        }
        publishedIdentity = CanvasCanonicalStateIdentity(
            documentGeneration: documentGeneration,
            geometry: geometry,
            geometryRevision: prepared.geometryRevision,
            layerStackRevision: prepared.layerStackRevision,
            compositeRevision: prepared.compositeRevision
        )
    }

    func publishedResult() -> CanvasCanonicalStateIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return publishedIdentity
    }
}

struct DocumentPaintLayerApplicationResult: Equatable, Sendable {
    let didPublish: Bool
    let before: LayerStack
    let after: LayerStack
    let beforeGeometry: DocumentPaintGeometry
    let afterGeometry: DocumentPaintGeometry
    let baseGeneration: UInt64
    let generation: UInt64
    let revision: LayerSurfaceRevisionReference?
    let baseCanonicalIdentity: CanvasCanonicalStateIdentity
    let targetCanonicalIdentity: CanvasCanonicalStateIdentity
    let compositeInvalidation: CanvasCompositeInvalidation
}

struct DocumentPaintTransientDisplaySource: @unchecked Sendable {
    fileprivate let contextIdentity: UUID
    let sourceIdentity: UUID
    fileprivate let addressing: SparseTileAddressing
    fileprivate let descriptor: DocumentPaintTransientVisibleSourceDescriptor
    fileprivate let acknowledgement: StrokePreparedFrameAcknowledgement

    let orderedRoles: [SparseTileSampleRole]
    let dispositions: [SparseTileSourceDisposition]
    let contentKeys: [SparseTileRoleContentKey]
    let changedCoordinateSets: [[PaintTileCoordinate]]

    var acknowledgementStatus: StrokePreparedFrameAcknowledgementStatus {
        acknowledgement.status
    }

    func requestAcknowledgement() throws {
        try acknowledgement.requestFulfillment()
    }

    #if DEBUG
    var testingAcknowledgementRequestCount: Int {
        acknowledgement.testingRequestCount
    }

    func testingCompleteDeferredAcknowledgement() {
        acknowledgement.testingCompleteDeferredFulfillment()
    }
    #endif
}

/// Authenticated, immutable cache-copy handoff. It deliberately contains no
/// viewport or periodic display addressing: exact physical providers and the
/// Context's captured canonical geometry are the complete copy contract.
struct DocumentPaintTransientCacheUpdate: @unchecked Sendable {
    let generation: UInt64
    let strokeEpoch: UUID
    let sequence: UInt64
    let layerID: UUID
    let canonicalIdentity: CanvasCanonicalStateIdentity
    let changedRole: StrokePrivateSurfaceLayer
    let changedCoordinates: [PaintTileCoordinate]
    let clearedAuthoritativeSurface: Bool
    let clearedPredictionSurface: Bool
    let descriptor: DocumentPaintTransientVisibleSourceDescriptor
    let acknowledgement: StrokePreparedFrameAcknowledgement
    let traceIdentities: [StrokeTraceIdentity]
    let acknowledgementSettlement:
        DocumentPaintTransientCacheAcknowledgementSettlement
    let presentationEpoch: DocumentPaintStrokePresentationEpoch
}

final class DocumentPaintTransientCacheAcknowledgementSettlement:
    @unchecked Sendable
{
    private enum State: Equatable {
        case unowned
        case available(ownerID: UUID)
        case fulfilling(ownerID: UUID)
        case fulfilled
    }

    private let lock = NSLock()
    private var state = State.unowned

    func claimOwnership(ownerID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .unowned else { return false }
        state = .available(ownerID: ownerID)
        return true
    }

    func beginFulfillment(ownerID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .available(ownerID: ownerID) else { return false }
        state = .fulfilling(ownerID: ownerID)
        return true
    }

    func failFulfillment(ownerID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .fulfilling(ownerID: ownerID) else { return }
        state = .available(ownerID: ownerID)
    }

    func completeFulfillment(ownerID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .fulfilling(ownerID: ownerID) else { return false }
        state = .fulfilled
        return true
    }
}

private final class DocumentPaintActiveStrokeSurfaceSlot:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value: DocumentPaintStrokeSurfaceCapability?

    var current: DocumentPaintStrokeSurfaceCapability? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func install(_ capability: DocumentPaintStrokeSurfaceCapability) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return false }
        value = capability
        return true
    }

    func finish(token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard value?.capabilityToken == token else { return }
        value = nil
    }
}

struct DocumentPaintCanonicalVisiblePlanRequest: @unchecked Sendable {
    fileprivate let controllerToken: DocumentPaintVisiblePlanRequestToken

    let specification: DocumentPaintVisiblePlanSpecification
}

struct DocumentPaintVisiblePlanOwnedSources: @unchecked Sendable {
    let contextIdentity: UUID
    let sourceBatch: SparseTileOwnedSourceBatch
    let transientSource: DocumentPaintTransientDisplaySource?

    fileprivate init(
        contextIdentity: UUID,
        sourceBatch: SparseTileOwnedSourceBatch,
        transientSource: DocumentPaintTransientDisplaySource? = nil
    ) {
        self.contextIdentity = contextIdentity
        self.sourceBatch = sourceBatch
        self.transientSource = transientSource
    }
}

struct DocumentPaintTransientVisiblePlanRequest: @unchecked Sendable {
    fileprivate let controllerToken: DocumentPaintVisiblePlanRequestToken
    let specification: DocumentPaintVisiblePlanSpecification
}

struct DocumentPaintTransactionWorkerSnapshot: Equatable, Sendable {
    let dispatchSequence: UInt64
    let transaction: DocumentPaintSurfaceTransactionSnapshot
}

struct DocumentPaintRenderContextSnapshot:
    Equatable, @unchecked Sendable
{
    let storeIdentity: PaintTileStoreIdentity
    let activeLayerID: UUID
    let documentGeneration: UInt64
    let layerIDs: [UUID]
    let tileByteBudget: Int
    let residentTileBytes: Int
    let residentTileHighWaterBytes: Int
    let backingTileBytes: Int
    let tileIndexEntryCount: Int
    let activeSnapshotTokenCount: Int
    let retainedHistorySnapshotTokenCount: Int
    let aggregateSnapshotReferenceCount: Int
    let activeTileLeaseCount: Int
    let snapshotMetadataByteCount: Int
    let snapshotPayloadLiabilityByteCount: Int
    let revisionResidentBytes: Int
    let activeStrokeSurfaceCount: Int
    let activeCommandOperationCount: Int
    let transaction: DocumentPaintTransactionWorkerSnapshot
    let visiblePlan: DocumentPaintVisiblePlanControllerSnapshot
    let stableCollectionRenderer:
        DocumentPaintStableSnapshotRendererSnapshot
    let layerCompositor: LayerCompositorSnapshot
    let pendingLayerDisplayAcknowledgementCount: Int
}

/// Serialized command boundary around the transaction coordinator. Every phase
/// handle and all retryable cleanup ownership remain private to this actor.
private actor DocumentPaintTransactionWorker {
    private enum OwnedMutation {
        case prepared(DocumentPaintPreparedMutation)
        case encoded(DocumentPaintEncodedMutation)
        case reduced(DocumentPaintReducedMutation)
        case historyEncoded(DocumentPaintEncodedHistory)
        case historyCompleted(DocumentPaintCompletedHistory)
        case terminal(DocumentPaintTerminalCommit)
    }

    private enum OwnedRestore {
        case prepared(DocumentPaintPreparedRestore)
        case encoded(DocumentPaintEncodedRestore)
        case completed(DocumentPaintCompletedRestore)
        case terminal(DocumentPaintTerminalRestore)
    }

    private let transaction: DocumentPaintSurfaceTransaction
    private let registry: DocumentPaintSurfaceStore
    private let revisionStore: TiledRasterRevisionStore
    private let mutationBackend: any DocumentPaintSurfaceMutationBackend
    private var dispatchSequence: UInt64 = 0
    private var isShutdown = false
    #if DEBUG
    private var beforeMutationPublicationClaimForTesting:
        (@Sendable () async -> Void)?
    private var afterMutationPublicationForTesting:
        (@Sendable () async -> Void)?
    #endif

    init(
        transaction: DocumentPaintSurfaceTransaction,
        registry: DocumentPaintSurfaceStore,
        revisionStore: TiledRasterRevisionStore,
        mutationBackend: any DocumentPaintSurfaceMutationBackend
    ) {
        self.transaction = transaction
        self.registry = registry
        self.revisionStore = revisionStore
        self.mutationBackend = mutationBackend
    }

    func snapshot() -> DocumentPaintTransactionWorkerSnapshot {
        dispatchSequence &+= 1
        precondition(dispatchSequence != 0, "Transaction dispatch overflow")
        return DocumentPaintTransactionWorkerSnapshot(
            dispatchSequence: dispatchSequence,
            transaction: transaction.snapshot()
        )
    }

    func commitStroke(
        _ source: StrokePreparedCommitMutationSource,
        compositeParameters: DocumentPaintStrokeCompositeParameters,
        canonicalReservation: DocumentPaintCanonicalRevisionReservation,
        publicationState: StrokeCommitPublicationState?
    ) async throws -> DocumentPaintSurfaceWorkerResult {
        do {
            try beginCommand()
            let current = registry.snapshot()
            let request = DocumentPaintSurfaceMutationRequest(
                kind: .stroke,
                layerID: source.layerID,
                baseGeometry: current.geometry,
                candidateGeometry: current.geometry,
                dirtyCoordinates: source.coordinates,
                explicitlyRemovedCoordinates: [],
                requiresHistoryPair: true
            )
            return try await executeMutation(
                transaction.prepareMutation(request),
                requiresHistory: true,
                strokeSource: source,
                compositeParameters: compositeParameters,
                canonicalReservation: canonicalReservation,
                publicationState: publicationState
            )
        } catch {
            try? source.cancelUnclaimed()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func clear(
        layerID: UUID,
        canonicalReservation: DocumentPaintCanonicalRevisionReservation
    ) async throws -> DocumentPaintSurfaceWorkerResult {
        try beginCommand()
        let current = registry.snapshot()
        let references = current.layers.first {
            $0.layerID == layerID
        }?.references ?? []
        let request = DocumentPaintSurfaceMutationRequest(
            kind: .clear,
            layerID: layerID,
            baseGeometry: current.geometry,
            candidateGeometry: current.geometry,
            dirtyCoordinates: [],
            explicitlyRemovedCoordinates: references.map(\.coordinate),
            requiresHistoryPair: true
        )
        return try await executeMutation(
            transaction.prepareMutation(request),
            requiresHistory: true,
            canonicalReservation: canonicalReservation
        )
    }

    func resizeAllLayers(
        to candidateGeometry: DocumentPaintGeometry,
        targetRadialConfiguration: RadialSymmetryConfiguration?
    ) throws -> LayerSurfaceTransaction? {
        try beginCommand()
        let current = registry.snapshot()
        if current.geometry == candidateGeometry {
            return nil
        }
        return try registry.prepareLayerSurfaceResizeTransaction(
            layerStack: current.layerStack,
            geometry: candidateGeometry,
            targetRadialConfiguration: targetRadialConfiguration,
            backend: mutationBackend
        )
    }

    func importEncoded(
        _ request: DocumentPaintSurfaceEncodedImportRequest,
        canonicalReservation: DocumentPaintCanonicalRevisionReservation
    ) async throws -> DocumentPaintSurfaceWorkerResult {
        try beginCommand()
        return try await executeMutation(
            transaction.prepareEncodedImport(request),
            requiresHistory: false,
            canonicalReservation: canonicalReservation
        )
    }

    func restore(
        _ request: DocumentPaintSurfaceRestoreRequest,
        canonicalReservation: DocumentPaintCanonicalRevisionReservation
    ) async throws -> DocumentPaintSurfaceRestoreResult {
        try beginCommand()
        var owned: OwnedRestore?
        do {
            let prepared = try transaction.prepareRestore(request)
            owned = .prepared(prepared)
            try throwIfCancelled(afterOwning: owned)
            let encoded = try transaction.encodeRestore(prepared)
            owned = .encoded(encoded)
            let wasCancelled = Task.isCancelled
            let completed = try transaction.completeRestore(
                encoded,
                as: wasCancelled ? .cancelled : .succeeded
            )
            owned = .completed(completed)
            if wasCancelled || Task.isCancelled {
                try settle(owned)
                throw CancellationError()
            }
            let terminal = try transaction.prepareTerminalRestore(completed)
            owned = .terminal(terminal)
            if Task.isCancelled {
                try settle(owned)
                throw CancellationError()
            }
            try canonicalReservation.prepare()
            let result = try transaction.publishRestore(terminal)
            canonicalReservation.markPublished(geometry: registry.geometry)
            owned = nil
            return result
        } catch {
            try settle(owned)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func releaseRevisions(
        _ revisionIDs: Set<StoredRasterRevisionID>
    ) throws {
        try beginCommand()
        try revisionStore.release(revisionIDs)
    }

    func retry() throws {
        try retryPendingCleanup()
    }

    func shutdown() throws {
        if isShutdown { return }
        try retryPendingCleanup()
        isShutdown = true
    }

    private func beginCommand() throws {
        guard !isShutdown else {
            throw DocumentPaintRenderContextError.isShutdown
        }
        try retryPendingCleanup()
        try Task.checkCancellation()
    }

    private func executeMutation(
        _ preparation: @autoclosure () throws
            -> DocumentPaintMutationPreparation,
        requiresHistory: Bool,
        strokeSource: StrokePreparedCommitMutationSource? = nil,
        compositeParameters: DocumentPaintStrokeCompositeParameters? = nil,
        canonicalReservation: DocumentPaintCanonicalRevisionReservation,
        publicationState: StrokeCommitPublicationState? = nil
    ) async throws -> DocumentPaintSurfaceWorkerResult {
        var owned: OwnedMutation?
        do {
            switch try preparation() {
            case let .noOp(result):
                try? strokeSource?.cancelUnclaimed()
                return DocumentPaintSurfaceWorkerResult(
                    didPublish: false,
                    layerID: result.layerID,
                    generation: result.generation,
                    dirtyCoordinates: [],
                    historyPair: nil
                )
            case let .prepared(prepared):
                owned = .prepared(prepared)
                try throwIfCancelled(afterOwning: owned)
                let encoded: DocumentPaintEncodedMutation
                if let strokeSource, let compositeParameters {
                    encoded = try transaction.encodeStrokeMutation(
                        prepared,
                        source: strokeSource,
                        compositeParameters: compositeParameters
                    )
                } else {
                    encoded = try transaction.encodeMutation(prepared)
                }
                owned = .encoded(encoded)
                let mutationWasCancelled = Task.isCancelled
                let reduced = try transaction.completeMutation(
                    encoded,
                    as: mutationWasCancelled ? .cancelled : .succeeded
                )
                owned = .reduced(reduced)
                if mutationWasCancelled || Task.isCancelled {
                    try settle(owned)
                    throw CancellationError()
                }

                let terminal: DocumentPaintTerminalCommit
                if requiresHistory {
                    let encodedHistory = try transaction
                        .encodeHistoryCapture(reduced)
                    owned = .historyEncoded(encodedHistory)
                    let historyWasCancelled = Task.isCancelled
                    let completedHistory = try transaction
                        .completeHistoryCapture(
                            encodedHistory,
                            as: historyWasCancelled
                                ? .cancelled : .succeeded
                        )
                    owned = .historyCompleted(completedHistory)
                    if historyWasCancelled || Task.isCancelled {
                        try settle(owned)
                        throw CancellationError()
                    }
                    terminal = try transaction.prepareTerminalCommit(
                        completedHistory
                    )
                } else {
                    terminal = try transaction.prepareTerminalCommit(reduced)
                }
                owned = .terminal(terminal)
                if Task.isCancelled {
                    try settle(owned)
                    throw CancellationError()
                }
                #if DEBUG
                await beforeMutationPublicationClaimForTesting?()
                #endif
                guard publicationState?.claimPublication() ?? true else {
                    try settle(owned)
                    throw CancellationError()
                }
                try canonicalReservation.prepare()
                let result = try transaction.publish(terminal)
                canonicalReservation.markPublished(geometry: registry.geometry)
                #if DEBUG
                await afterMutationPublicationForTesting?()
                #endif
                owned = nil
                return DocumentPaintSurfaceWorkerResult(
                    didPublish: true,
                    layerID: result.layerID,
                    generation: result.afterGeneration,
                    dirtyCoordinates: result.dirtyCoordinates,
                    historyPair: result.historyPair
                )
            }
        } catch let operationError {
            do {
                try settle(owned)
            } catch {
                try? strokeSource?.cancelUnclaimed()
                throw error
            }
            try? strokeSource?.cancelUnclaimed()
            if Task.isCancelled { throw CancellationError() }
            throw operationError
        }
    }

    private func throwIfCancelled(afterOwning owned: OwnedMutation?) throws {
        guard Task.isCancelled else { return }
        try settle(owned)
        throw CancellationError()
    }

    private func throwIfCancelled(afterOwning owned: OwnedRestore?) throws {
        guard Task.isCancelled else { return }
        try settle(owned)
        throw CancellationError()
    }

    private func retryPendingCleanup() throws {
        if transaction.snapshot().phase == .discardPending {
            try transaction.retryDiscard()
        }
        guard transaction.snapshot().state == .idle else {
            throw DocumentPaintSurfaceTransactionError.transactionAlreadyLive
        }
    }

    private func settle(_ owned: OwnedMutation?) throws {
        guard transaction.snapshot().state != .idle else { return }
        if transaction.snapshot().phase == .discardPending {
            try transaction.retryDiscard()
            return
        }
        guard let owned else {
            throw DocumentPaintSurfaceTransactionError.cleanupFailed
        }
        switch owned {
        case let .prepared(handle): try transaction.discard(handle)
        case let .encoded(handle): try transaction.discard(handle)
        case let .reduced(handle): try transaction.discard(handle)
        case let .historyEncoded(handle): try transaction.discard(handle)
        case let .historyCompleted(handle): try transaction.discard(handle)
        case let .terminal(handle): try transaction.discard(handle)
        }
    }

    private func settle(_ owned: OwnedRestore?) throws {
        guard transaction.snapshot().state != .idle else { return }
        if transaction.snapshot().phase == .discardPending {
            try transaction.retryDiscard()
            return
        }
        guard let owned else {
            throw DocumentPaintSurfaceTransactionError.cleanupFailed
        }
        switch owned {
        case let .prepared(handle): try transaction.discard(handle)
        case let .encoded(handle): try transaction.discard(handle)
        case let .completed(handle): try transaction.discard(handle)
        case let .terminal(handle): try transaction.discard(handle)
        }
    }

    #if DEBUG
    func testingSetBeforeMutationPublicationClaimHook(
        _ hook: (@Sendable () async -> Void)?
    ) {
        beforeMutationPublicationClaimForTesting = hook
    }

    func testingSetAfterMutationPublicationHook(
        _ hook: (@Sendable () async -> Void)?
    ) {
        afterMutationPublicationForTesting = hook
    }
    #endif
}

/// The single production ownership root for sparse document paint state.
///
/// Mutable registry, history, transaction, CPU/GPU plan, upload, and pipeline
/// authority is private. MainActor methods issue the current stroke surface,
/// submit operation-shaped commands, encode already-prepared submissions, and
/// read immutable snapshots. Fallible work runs on owned actors off MainActor.
@MainActor
final class DocumentPaintRenderContext {
    private let identity = UUID()
    private let canonicalDocumentGeneration: UInt64
    private var canonicalGeometry: DocumentPaintGeometry
    var activeLayerID: UUID { registry.layerStack.activeLayerID }
    var layerStack: LayerStack { registry.layerStack }

    private let registry: DocumentPaintSurfaceStore
    private let revisionStore: TiledRasterRevisionStore
    private let transactionWorker: DocumentPaintTransactionWorker
    private let visiblePlanController: DocumentPaintVisiblePlanController
    private let stableCollectionRenderer: DocumentPaintStableSnapshotRenderer
    private let layerCompositor: LayerCompositor
    private let stableCollectionRendererLimits =
        DocumentPaintStableSnapshotRendererLimits.production
    private let maximumRevisionBytes: Int
    private let layerRevisionStoreIdentity =
        RasterRevisionStoreIdentitySource.shared.makeIdentity()
    private var nextLayerRevisionID: UInt64 = 1
    private var geometryRevision: UInt64 = 0
    private var layerStackRevision: UInt64 = 0
    private var compositeRevision: UInt64 = 0
    private var canonicalIdentityClaim: CanvasCanonicalIdentityClaim?
    private var activeCanonicalReservation:
        DocumentPaintCanonicalRevisionReservation?
    private var activeRasterEndpoint: RasterRevisionReference?
    private var layerHistoryRevisions:
        [StoredRasterRevisionID: LayerSurfaceHistoryRevision] = [:]
    private var layerHistoryResidentBytes = 0
    private let maximumEncodedImportBytes =
        DocumentPaintStableSnapshotRendererLimits.production.maximumOutputBytes
    private let activeStrokeSurfaceSlot = DocumentPaintActiveStrokeSurfaceSlot()
    private var activeTransientDisplaySource:
        DocumentPaintTransientDisplaySource?
    private var activeCommandOperationID: UUID?
    private var hasPublishedTransientSurfaceSnapshot = false
    private var hasRequestedShutdown = false
    private var hasShutdown = false

    #if DEBUG
    func testingInvalidateCanonicalIdentityClaim() {
        canonicalIdentityClaim?.invalidate(
            from: identity,
            currentIdentity: canonicalStateIdentity()
        )
    }

    func testingReleaseTransientDisplaySourceWithoutAcknowledgement(
        _ source: DocumentPaintTransientDisplaySource
    ) throws {
        guard source.contextIdentity == identity,
              activeTransientDisplaySource?.sourceIdentity
                == source.sourceIdentity
        else {
            throw DocumentPaintRenderContextError.staleTransientDisplaySource
        }
        activeTransientDisplaySource = nil
    }
    #endif

    #if DEBUG
    var testingActiveStrokeSurfaceSlot: AnyObject {
        activeStrokeSurfaceSlot
    }

    var testingSnapshotPayloadLiabilityByteBudget: Int {
        registry.sharedTileStore.testingSnapshotPayloadLiabilityByteBudget
    }

    func testingShutdownVisiblePlanControllerOnly() async throws
        -> DocumentPaintRenderContextShutdownSnapshot
    {
        try await visiblePlanController.shutdown(reason: .sessionReplacement)
    }
    #endif

    init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        library: any MTLLibrary,
        geometry: DocumentPaintGeometry,
        initialLayerStack: LayerStack,
        byteBudget: Int,
        snapshotPayloadLiabilityByteBudget: Int? = nil,
        transferByteCapacity: Int,
        maximumRevisionBytes: Int,
        generation: UInt64 = 0,
        geometryRevision: UInt64 = 0,
        layerStackRevision: UInt64 = 0,
        compositeRevision: UInt64 = 0,
        visiblePlanConfiguration:
            DocumentPaintVisiblePlanControllerConfiguration = .production
    ) throws {
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: byteBudget,
            snapshotPayloadLiabilityByteBudget:
                snapshotPayloadLiabilityByteBudget,
            transferByteCapacity: transferByteCapacity,
            geometry: geometry,
            layerIDs: initialLayerStack.orderedLayerIDs,
            layerStack: initialLayerStack,
            generation: generation
        )
        let revisionStore = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: maximumRevisionBytes
        )
        let mutationPipelines = try
            DocumentPaintSurfaceMutationPipelineLibrary.prepare(
                device: device,
                library: library
            )
        let mutationBackend = try DocumentPaintSurfaceMetalBackend(
            device: device,
            commandQueue: commandQueue,
            pipelines: mutationPipelines
        )
        let transaction = DocumentPaintSurfaceTransaction(
            registry: registry,
            revisionStore: revisionStore,
            commandQueue: commandQueue,
            mutationBackend: mutationBackend,
            expectedStrokeSourceContextIdentity: identity
        )
        let samplingBackend = try SparseTileSamplingBackend.select(
            request: .automatic,
            capabilities: SparseTileSamplingDeviceCapabilities(device: device)
        )
        let affineSamplingPipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: library,
            key: SparseTileSamplingPipelineKey(
                backend: samplingBackend,
                outputPixelFormatRawValue:
                    DocumentColorPipeline.displayPixelFormat.rawValue,
                sampleCount: 1,
                abiVersion: SparseSamplingABI.version,
                outputMappingKind: .affine
            )
        )
        let radialSamplingPipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: library,
            key: SparseTileSamplingPipelineKey(
                backend: samplingBackend,
                outputPixelFormatRawValue:
                    DocumentColorPipeline.displayPixelFormat.rawValue,
                sampleCount: 1,
                abiVersion: SparseSamplingABI.version,
                outputMappingKind: .finiteRadial
            )
        )
        let periodicSamplingPipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: library,
            key: SparseTileSamplingPipelineKey(
                backend: samplingBackend,
                outputPixelFormatRawValue:
                    DocumentColorPipeline.displayPixelFormat.rawValue,
                sampleCount: 1,
                abiVersion: SparseSamplingABI.version,
                outputMappingKind: .periodic
            )
        )

        self.registry = registry
        self.revisionStore = revisionStore
        self.maximumRevisionBytes = maximumRevisionBytes
        canonicalDocumentGeneration = generation
        canonicalGeometry = geometry
        self.geometryRevision = geometryRevision
        self.layerStackRevision = layerStackRevision
        self.compositeRevision = compositeRevision
        transactionWorker = DocumentPaintTransactionWorker(
            transaction: transaction,
            registry: registry,
            revisionStore: revisionStore,
            mutationBackend: mutationBackend
        )
        visiblePlanController = DocumentPaintVisiblePlanController(
            device: device,
            pipelines: DocumentPaintVisiblePlanPipelines(
                affine: affineSamplingPipeline,
                periodic: periodicSamplingPipeline,
                finiteRadial: radialSamplingPipeline
            ),
            submissionOwnerIdentity: identity,
            configuration: visiblePlanConfiguration
        )
        stableCollectionRenderer = try DocumentPaintStableSnapshotRenderer
            .make(
                device: device,
                library: library,
                limits: .production,
                planLimits: .documentProduction
            )
        layerCompositor = try LayerCompositor.make(
            device: device,
            library: library,
            limits: .production,
            planLimits: .documentProduction
        )
    }

    func canonicalStateIdentity() -> CanvasCanonicalStateIdentity {
        if let published = activeCanonicalReservation?.publishedResult() {
            return published
        }
        return CanvasCanonicalStateIdentity(
            documentGeneration: canonicalDocumentGeneration,
            geometry: canonicalGeometry,
            geometryRevision: geometryRevision,
            layerStackRevision: layerStackRevision,
            compositeRevision: compositeRevision
        )
    }

    private func canonicalRevisionReservation(
        geometry: Bool = false,
        layerStack: Bool = false,
        composite: Bool = true
    ) -> DocumentPaintCanonicalRevisionReservation {
        DocumentPaintCanonicalRevisionReservation(
            geometryRevision: geometryRevision,
            layerStackRevision: layerStackRevision,
            compositeRevision: compositeRevision,
            documentGeneration: canonicalDocumentGeneration,
            advancesGeometry: geometry,
            advancesLayerStack: layerStack,
            advancesComposite: composite
        )
    }

    private func publishCanonicalRevisionAdvance(
        _ prepared: DocumentPaintPreparedCanonicalRevisionAdvance,
        baseIdentity: CanvasCanonicalStateIdentity,
        invalidation: CanvasCompositeInvalidation
    ) -> CanvasCanonicalStateIdentity {
        let priorClaim = canonicalIdentityClaim
        canonicalGeometry = registry.geometry
        geometryRevision = prepared.geometryRevision
        layerStackRevision = prepared.layerStackRevision
        compositeRevision = prepared.compositeRevision
        let published = canonicalStateIdentity()
        priorClaim?.invalidate(
            from: identity,
            currentIdentity: published
        )
        canonicalIdentityClaim = CanvasCanonicalIdentityClaim(
            descriptor: CanvasCanonicalApplicationDescriptor(
                baseIdentity: baseIdentity,
                targetIdentity: published,
                invalidation: invalidation,
                targetVisibleCoordinates: canonicalVisibleCoordinates()
            ),
            contextIdentity: identity
        )
        return published
    }

    private func canonicalVisibleCoordinates() -> [PaintTileCoordinate] {
        let snapshot = registry.snapshot()
        let visibleLayerIDs = Set(snapshot.layerStack.layers.compactMap {
            layer in
            layer.isVisible && layer.opacity > 0 ? layer.id : nil
        })
        return CanvasCompositeInvalidation.sortedUnique(
            snapshot.layers.filter {
                visibleLayerIDs.contains($0.layerID)
            }.flatMap(\.references).map(\.coordinate)
        )
    }

    private func claimCurrentCanonicalIdentity()
        -> CanvasCanonicalIdentityClaim
    {
        let current = canonicalStateIdentity()
        if let canonicalIdentityClaim,
           canonicalIdentityClaim.identity == current {
            return canonicalIdentityClaim
        }
        let claim = CanvasCanonicalIdentityClaim(
            descriptor: CanvasCanonicalApplicationDescriptor(
                baseIdentity: current,
                targetIdentity: current,
                invalidation: .full,
                targetVisibleCoordinates: canonicalVisibleCoordinates()
            ),
            contextIdentity: identity
        )
        canonicalIdentityClaim = claim
        return claim
    }

    func prepareCompositeTileUpdatePlan(
        baseIdentity: CanvasCanonicalStateIdentity,
        targetIdentity: CanvasCanonicalStateIdentity,
        invalidation: CanvasCompositeInvalidation,
        cachedCoordinates: [PaintTileCoordinate],
        limits: SparseTilePlanLimits = .documentProduction
    ) throws -> CanvasCompositeTileUpdatePlan {
        let current = canonicalStateIdentity()
        guard current == targetIdentity else {
            throw CanvasCompositeTileCacheError.staleIdentity(
                expected: targetIdentity,
                current: current
            )
        }
        var identityClaim = claimCurrentCanonicalIdentity()
        if !identityClaim.validatesPreparation(
            baseIdentity: baseIdentity,
            targetIdentity: targetIdentity,
            invalidation: invalidation
        ), baseIdentity == targetIdentity,
           invalidation == .full || invalidation == .none {
            identityClaim = CanvasCanonicalIdentityClaim(
                descriptor: CanvasCanonicalApplicationDescriptor(
                    baseIdentity: baseIdentity,
                    targetIdentity: targetIdentity,
                    invalidation: invalidation,
                    targetVisibleCoordinates: canonicalVisibleCoordinates()
                ),
                contextIdentity: identity
            )
            canonicalIdentityClaim = identityClaim
        }
        guard identityClaim.validatesPreparation(
            baseIdentity: baseIdentity,
            targetIdentity: targetIdentity,
            invalidation: invalidation
        ) else {
            throw CanvasCompositeTileCacheError.invalidPlan
        }
        return try registry.prepareCompositeTileUpdatePlan(
            baseIdentity: baseIdentity,
            targetIdentity: targetIdentity,
            invalidation: invalidation,
            cachedCoordinates: cachedCoordinates,
            identityClaim: identityClaim,
            limits: limits
        )
    }

    private func applicationResult(
        _ result: DocumentPaintSurfaceWorkerResult,
        reservation: DocumentPaintCanonicalRevisionReservation,
        baseIdentity: CanvasCanonicalStateIdentity,
        publishedInvalidation: CanvasCompositeInvalidation? = nil
    ) -> DocumentPaintSurfaceApplicationResult {
        let identity: CanvasCanonicalStateIdentity
        if result.didPublish {
            guard let prepared = reservation.result() else {
                preconditionFailure("Published mutation lost revision reservation")
            }
            let invalidation = publishedInvalidation
                ?? .exact(result.dirtyCoordinates)
            identity = publishCanonicalRevisionAdvance(
                prepared,
                baseIdentity: baseIdentity,
                invalidation: invalidation
            )
            activeRasterEndpoint = result.historyPair?.after
        } else {
            identity = canonicalStateIdentity()
        }
        return DocumentPaintSurfaceApplicationResult(
            didPublish: result.didPublish,
            layerID: result.layerID,
            generation: result.generation,
            dirtyCoordinates: result.dirtyCoordinates,
            baseCanonicalIdentity: baseIdentity,
            canonicalIdentity: identity,
            compositeInvalidation: result.didPublish
                ? publishedInvalidation ?? .exact(result.dirtyCoordinates)
                : .none,
            historyPair: result.historyPair
        )
    }

    func snapshot() async -> DocumentPaintRenderContextSnapshot {
        let registrySnapshot = registry.snapshot()
        let tileStoreSnapshot = registry.sharedTileStore.snapshot()
        async let transactionSnapshot = transactionWorker.snapshot()
        async let planSnapshot = visiblePlanController.snapshot()
        async let collectionRendererSnapshot =
            stableCollectionRenderer.snapshot()
        async let layerCompositorSnapshot = layerCompositor.snapshot()
        let transaction = await transactionSnapshot
        let visiblePlan = await planSnapshot
        let stableCollectionRenderer = await collectionRendererSnapshot
        let layerCompositor = await layerCompositorSnapshot
        let (revisionResidentBytes, revisionOverflow) = revisionStore
            .residentBytes.addingReportingOverflow(layerHistoryResidentBytes)
        precondition(!revisionOverflow, "Revision diagnostics overflow")
        return DocumentPaintRenderContextSnapshot(
            storeIdentity: registry.tileStoreIdentity,
            activeLayerID: activeLayerID,
            documentGeneration: registrySnapshot.generation,
            layerIDs: registrySnapshot.layers.map(\.layerID),
            tileByteBudget: registrySnapshot.tileByteBudget,
            residentTileBytes: registrySnapshot.residentTileBytes,
            residentTileHighWaterBytes:
                tileStoreSnapshot.residentByteHighWater,
            backingTileBytes: registrySnapshot.backingTileBytes,
            tileIndexEntryCount: tileStoreSnapshot.tileIndexEntryCount,
            activeSnapshotTokenCount:
                tileStoreSnapshot.activeSnapshotTokenCount,
            retainedHistorySnapshotTokenCount:
                layerHistoryRevisions.values.reduce(into: 0) {
                    if $1.retainedBytes > 0 { $0 += 1 }
                },
            aggregateSnapshotReferenceCount:
                tileStoreSnapshot.aggregateSnapshotReferenceCount,
            activeTileLeaseCount: tileStoreSnapshot.activeLeaseCount,
            snapshotMetadataByteCount:
                tileStoreSnapshot.snapshotMetadataByteCount,
            snapshotPayloadLiabilityByteCount:
                tileStoreSnapshot.snapshotPayloadDebtByteCount,
            revisionResidentBytes: revisionResidentBytes,
            activeStrokeSurfaceCount:
                activeStrokeSurfaceSlot.current == nil ? 0 : 1,
            activeCommandOperationCount:
                activeCommandOperationID == nil ? 0 : 1,
            transaction: transaction,
            visiblePlan: visiblePlan,
            stableCollectionRenderer: stableCollectionRenderer,
            layerCompositor: layerCompositor,
            pendingLayerDisplayAcknowledgementCount: 0
        )
    }

    func beginStrokeSurface() throws
        -> DocumentPaintStrokeSurfaceCapability
    {
        guard !hasRequestedShutdown else {
            throw DocumentPaintRenderContextError.isShutdown
        }
        guard activeStrokeSurfaceSlot.current == nil else {
            throw DocumentPaintRenderContextError.activeStrokeExists
        }
        guard activeCommandOperationID == nil else {
            throw DocumentPaintRenderContextError
                .activeCommandOperationExists
        }
        let activeLayer: LayerDescriptor
        do {
            activeLayer = try registry.layerStack
                .activeLayerForRasterMutation()
        } catch LayerStackError.activeLayerLocked(let layerID) {
            throw DocumentPaintRenderContextError.activeLayerLocked(layerID)
        }
        let slot = activeStrokeSurfaceSlot
        let capability = try registry.issueCurrentStrokeSurfaceCapability(
            layerID: activeLayer.id,
            ownerIdentity: identity,
            onTerminal: { [weak slot] token in
                slot?.finish(token: token)
            }
        )
        guard slot.install(capability) else {
            try capability.cancel(expectedOwnerIdentity: identity)
            throw DocumentPaintRenderContextError.activeStrokeExists
        }
        hasPublishedTransientSurfaceSnapshot = false
        return capability
    }

    func adoptTransientDisplayFrame(
        _ frame: StrokePreparedDisplayFrame,
        addressing: SparseTileAddressing
    ) throws -> DocumentPaintTransientDisplaySource {
        guard !hasRequestedShutdown else {
            throw DocumentPaintRenderContextError.isShutdown
        }
        if activeTransientDisplaySource?.acknowledgementStatus == .fulfilled {
            activeTransientDisplaySource = nil
        }
        guard activeTransientDisplaySource == nil else {
            throw DocumentPaintRenderContextError
                .activeTransientDisplaySourceExists
        }
        guard let capability = activeStrokeSurfaceSlot.current,
              frame.surface.authenticates(capability),
              frame.generation == capability.generation,
              frame.surface.storeIdentity == registry.tileStoreIdentity,
              frame.surface.layerID == capability.layerID,
              frame.surface.pixelSize == capability.pixelSize,
              frame.surface.radialLayout == capability.radialLayout,
              frame.surface.authoritativeSurfaceID
                == capability.authoritativeSurfaceID,
              frame.surface.predictionSurfaceID
                == capability.predictionSurfaceID
        else {
            throw DocumentPaintRenderContextError.foreignTransientDisplayFrame
        }
        let disposition: SparseTileSourceDisposition =
            hasPublishedTransientSurfaceSnapshot ? .delta : .fullSnapshot
        guard let displayCapability = frame.surface.capability else {
            throw DocumentPaintRenderContextError.foreignTransientDisplayFrame
        }
        let descriptor = try DocumentPaintTransientVisibleSourceDescriptor(
            capability: displayCapability,
            changedRole: frame.surface.changedRole,
            changedCoordinates: frame.surface.changedCoordinates,
            addressing: addressing,
            disposition: disposition
        )
        let transient = descriptor.sources
        guard transient.map(\.contentKey.role)
                == [.authoritative, .prediction]
        else {
            throw DocumentPaintRenderContextError.foreignTransientDisplayFrame
        }
        let source = DocumentPaintTransientDisplaySource(
            contextIdentity: identity,
            sourceIdentity: UUID(),
            addressing: addressing,
            descriptor: descriptor,
            acknowledgement: frame.acknowledgement,
            orderedRoles: transient.map(\.contentKey.role),
            dispositions: transient.map(\.disposition),
            contentKeys: transient.map(\.contentKey),
            changedCoordinateSets: transient.map(\.changedCoordinates)
        )
        activeTransientDisplaySource = source
        hasPublishedTransientSurfaceSnapshot = true
        return source
    }

    func makeTransientCacheUpdate(
        frame: StrokePreparedDisplayFrame,
        sequence: UInt64
    ) throws -> DocumentPaintTransientCacheUpdate {
        guard !hasRequestedShutdown else {
            throw DocumentPaintRenderContextError.isShutdown
        }
        guard let capability = activeStrokeSurfaceSlot.current,
              frame.acknowledgement.status == .available,
              frame.surface.authenticates(capability),
              frame.generation == capability.generation,
              frame.surface.storeIdentity == registry.tileStoreIdentity,
              frame.surface.layerID == capability.layerID,
              frame.surface.pixelSize == capability.pixelSize,
              frame.surface.radialLayout == capability.radialLayout,
              frame.surface.authoritativeSurfaceID
                == capability.authoritativeSurfaceID,
              frame.surface.predictionSurfaceID
                == capability.predictionSurfaceID
        else {
            throw DocumentPaintRenderContextError.foreignTransientDisplayFrame
        }
        let coordinates = frame.surface.changedCoordinates.sorted()
        for index in coordinates.indices.dropFirst()
        where coordinates[index - 1] == coordinates[index] {
            throw DocumentPaintSurfaceStoreError.duplicateCoordinate(
                coordinates[index]
            )
        }
        let descriptor = try DocumentPaintTransientVisibleSourceDescriptor(
            cacheCapability: capability
        )
        guard let acknowledgementSettlement = frame.acknowledgement
            .claimTransientCacheSettlement()
        else {
            throw DocumentPaintRenderContextError.foreignTransientDisplayFrame
        }
        return DocumentPaintTransientCacheUpdate(
            generation: frame.generation,
            strokeEpoch: capability.presentationEpoch.identity,
            sequence: sequence,
            layerID: capability.layerID,
            canonicalIdentity: canonicalStateIdentity(),
            changedRole: frame.surface.changedRole,
            changedCoordinates: coordinates,
            clearedAuthoritativeSurface:
                frame.clearedAuthoritativeSurface,
            clearedPredictionSurface: frame.clearedPredictionSurface,
            descriptor: descriptor,
            acknowledgement: frame.acknowledgement,
            traceIdentities: frame.traceIdentities,
            acknowledgementSettlement: acknowledgementSettlement,
            presentationEpoch: capability.presentationEpoch
        )
    }

    func interactiveStrokeCompositeParameters(
        layerID: UUID
    ) throws -> InteractiveStrokeCompositeParameters {
        guard !hasRequestedShutdown else {
            throw DocumentPaintRenderContextError.isShutdown
        }
        guard activeStrokeSurfaceSlot.current?.layerID == layerID,
              let layer = registry.layerStack.layer(id: layerID)
        else {
            throw DocumentPaintRenderContextError.foreignTransientDisplayFrame
        }
        return InteractiveStrokeCompositeParameters(
            blendMode: layer.blendMode,
            opacity: layer.opacity
        )
    }

    func abandonTransientDisplaySource(
        _ source: DocumentPaintTransientDisplaySource
    ) async throws {
        guard !hasRequestedShutdown else {
            throw DocumentPaintRenderContextError.isShutdown
        }
        guard source.contextIdentity == identity,
              activeTransientDisplaySource?.sourceIdentity
                == source.sourceIdentity
        else {
            throw DocumentPaintRenderContextError.staleTransientDisplaySource
        }
        try await visiblePlanController.retireTransientSource(source)
        try await visiblePlanController.retryRetirementsAndCompletions()
        // Once the controller has accepted the source it owns every remaining
        // plan, GPU-completion, retirement, and acknowledgement obligation.
        // Keeping the context admission claim until acknowledgement would
        // deadlock the next committed mutation when an installed transient
        // plan legitimately retains the source until its canonical successor.
        activeTransientDisplaySource = nil
    }

    func cancelStrokeSurface(
        _ capability: DocumentPaintStrokeSurfaceCapability
    ) throws {
        guard !hasRequestedShutdown else {
            throw DocumentPaintRenderContextError.isShutdown
        }
        guard activeCommandOperationID == nil else {
            throw DocumentPaintRenderContextError
                .activeCommandOperationExists
        }
        guard capability.ownerIdentity == identity else {
            throw DocumentPaintStrokeSurfaceError.foreignCapability
        }
        guard activeStrokeSurfaceSlot.current === capability else {
            throw DocumentPaintRenderContextError.noActiveStroke
        }
        try capability.cancel(expectedOwnerIdentity: identity)
    }

    func requestCanonicalVisiblePlan(
        addressing: SparseTileAddressing,
        addressingRevision: UInt64,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping = .affine(.identity)
    ) async throws -> DocumentPaintCanonicalVisiblePlanRequest {
        let capture = try registry.captureCanonicalVisibleSources(
            layerID: activeLayerID,
            addressing: addressing,
            addressingRevision: addressingRevision,
            outputRegion: outputRegion,
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: outputMapping
        )
        let specification = DocumentPaintVisiblePlanSpecification(
            key: capture.key,
            outputRegion: capture.outputRegion
        )
        let owned = DocumentPaintVisiblePlanOwnedSources(
            contextIdentity: identity,
            sourceBatch: capture.sourceBatch
        )
        let token: DocumentPaintVisiblePlanRequestToken
        do {
            token = try await visiblePlanController.request(
                specification,
                ownedSources: owned
            )
        } catch {
            try capture.sourceBatch.abandon()
            throw error
        }
        return DocumentPaintCanonicalVisiblePlanRequest(
            controllerToken: token,
            specification: specification
        )
    }

    func captureStableCanonicalSnapshot(
        addressing: SparseTileAddressing,
        addressingRevision: UInt64,
        limits: DocumentPaintStableCanonicalSnapshotLimits = .documentProduction
    ) throws -> DocumentPaintStableCanonicalSnapshot {
        try registry.captureStableCanonicalSnapshot(
            layerID: activeLayerID,
            addressing: addressing,
            addressingRevision: addressingRevision,
            limits: limits
        )
    }

    func collectStableFiniteCanonical(
        addressing: SparseTileAddressing,
        addressingRevision: UInt64,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping
    ) async throws -> DocumentPaintEncodedPremultipliedBGRA8 {
        try DocumentPaintStableSnapshotChunkPlanner.validateOutput(
            outputRegion,
            limits: stableCollectionRendererLimits
        )
        let descriptor = try DocumentPaintTightBGRA8Descriptor(
            outputRegion: outputRegion,
            maximumByteCount:
                stableCollectionRendererLimits.maximumOutputBytes
        )
        let root = try registry.captureStableCanonicalSnapshot(
            layerID: activeLayerID,
            addressing: addressing,
            addressingRevision: addressingRevision,
            outputMapping: outputMapping
        )
        defer { root.close() }
        return try await DocumentPaintStableCollectionEngine.collect(
            snapshot: root,
            renderer: stableCollectionRenderer,
            descriptor: descriptor,
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: outputMapping
        )
    }

    func collectStableCommittedStorage(
        addressing: SparseTileAddressing,
        addressingRevision: UInt64,
        outputGeometryRevision: UInt64
    ) async throws -> DocumentPaintStableCommittedCollection {
        let capture = try registry.captureStableCommittedCollection(
            layerID: activeLayerID,
            addressing: addressing,
            addressingRevision: addressingRevision,
            rendererLimits: stableCollectionRendererLimits
        )
        defer { capture.close() }
        return try await DocumentPaintStableCollectionEngine.collectCommitted(
            capture,
            renderer: stableCollectionRenderer,
            outputGeometryRevision: outputGeometryRevision
        )
    }

    func captureCommittedDocument(
        strategy: TilingStrategy,
        documentDomainLocked: Bool,
        radialGeometryLocked: Bool,
        outputGeometryRevision: UInt64
    ) async throws -> CommittedDocumentSnapshot {
        let capture = try registry.captureStableCommittedCollection(
            layerID: activeLayerID,
            addressing: Self.storageAddressing(for: strategy),
            addressingRevision: outputGeometryRevision,
            rendererLimits: stableCollectionRendererLimits
        )
        return try await CommittedDocumentSnapshot.collectStable(
            canvasSize: strategy.canvasSize,
            documentConfiguration: strategy.documentConfiguration,
            documentDomainLocked: documentDomainLocked,
            radialGeometryLocked: radialGeometryLocked,
            capture: capture,
            renderer: stableCollectionRenderer,
            outputGeometryRevision: outputGeometryRevision
        )
    }

    func captureNativeArchive() throws
        -> DocumentPaintNativeArchiveCapture
    {
        try registry.captureNativeArchive()
    }

    func importNativeArchive(
        _ manifest: DocumentPaintNativeArchiveImportManifest,
        consume: @escaping @Sendable
            (DocumentPaintNativeArchiveImportWriter) throws -> Void
    ) async throws {
        let claim = try beginCommandOperation()
        defer { finishCommandOperation(claim) }
        let baseIdentity = canonicalStateIdentity()
        let canonicalReservation = canonicalRevisionReservation(
            geometry: true,
            layerStack: true
        )
        activeCanonicalReservation = canonicalReservation
        defer { activeCanonicalReservation = nil }
        try canonicalReservation.prepare()
        let writer = try registry.prepareNativeArchiveImport(manifest)
        do {
            try await Task.detached(priority: .utility) {
                try consume(writer)
                try writer.finish()
                canonicalReservation.markPublished(
                    geometry: manifest.geometry
                )
            }.value
            guard let prepared = canonicalReservation.result() else {
                preconditionFailure("Native import lost revision reservation")
            }
            _ = publishCanonicalRevisionAdvance(
                prepared,
                baseIdentity: baseIdentity,
                invalidation: .full
            )
            activeRasterEndpoint = nil
        } catch {
            do {
                try writer.cancel()
            } catch let cleanupError {
                throw cleanupError
            }
            throw error
        }
    }

    func exportFiniteCanvas(
        strategy: TilingStrategy,
        outputGeometryRevision: UInt64,
        transparentBackground: Bool
    ) async throws -> FiniteCanvasExport {
        guard case .finite = strategy.documentConfiguration else {
            throw FiniteCanvasExportError.periodicDocument
        }
        let image = try await collectLayerComposite(
            strategy: strategy,
            outputRegion: try DocumentPaintStableExportAdapter.outputRegion(
                pixelSize: strategy.canvasSize
            ),
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: try Self.finiteOutputMapping(for: strategy)
        ).image
        return FiniteCanvasExport(
            pixelSize: strategy.canvasSize,
            bytesPerRow: image.bytesPerRow,
            bgra8Bytes: try DocumentPaintStableExportAdapter.destinationBytes(
                image,
                transparentBackground: transparentBackground
            ),
            hasTransparentBackground: transparentBackground
        )
    }

    func exportPeriodicMetric(
        strategy: TilingStrategy,
        density: Int,
        outputGeometryRevision: UInt64
    ) async throws -> PeriodicRepeatExport {
        let plan = try DocumentPaintStableMetricRepeatPlan(
            strategy: strategy,
            density: density
        )
        let image = try await collectLayerComposite(
            strategy: strategy,
            outputRegion: try DocumentPaintStableExportAdapter.outputRegion(
                pixelSize: plan.pixelSize
            ),
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: plan.outputMapping
        ).image
        return PeriodicRepeatExport(
            pixelSize: plan.pixelSize,
            bytesPerRow: image.bytesPerRow,
            bgra8Bytes: [UInt8](image.bgra8PremultipliedBytes)
        )
    }

    func exportPeriodicBaked(
        strategy: TilingStrategy,
        outputGeometryRevision: UInt64
    ) async throws -> PeriodicRepeatExport {
        guard case .periodic = strategy.documentConfiguration else {
            throw PeriodicBakedRepeatExportError.finiteDocument
        }
        if strategy.presetID.supportsMetricRepeatExport {
            return try await exportPeriodicMetric(
                strategy: strategy,
                density: strategy.canvasSize.width,
                outputGeometryRevision: outputGeometryRevision
            )
        }
        let plan = try DocumentPaintStableBakedPlan(strategy: strategy)
        let fullRegion = try DocumentPaintStableExportAdapter.outputRegion(
            pixelSize: plan.pixelSize
        )
        let destination = try DocumentPaintTightBGRA8Descriptor(
            outputRegion: fullRegion,
            maximumByteCount:
                DocumentPaintStableExportAdapter.limits.maximumOutputBytes
        )
        var bytes = [UInt8](repeating: 0, count: destination.byteCount)
        var expectedGeneration: UInt64?
        for piece in plan.pieces {
            let collected = try await collectLayerComposite(
                strategy: strategy,
                outputRegion: piece.outputRegion,
                outputGeometryRevision: outputGeometryRevision,
                outputMapping: piece.outputMapping,
                expectedGeneration: expectedGeneration
            )
            expectedGeneration = collected.generation
            let image = collected.image
            for row in 0..<piece.outputRegion.height {
                let sourceOffset = row * image.bytesPerRow
                let destinationOffset = (piece.outputRegion.minY + row)
                    * destination.bytesPerRow
                    + piece.outputRegion.minX * 4
                bytes.replaceSubrange(
                    destinationOffset..<(destinationOffset + image.bytesPerRow),
                    with: image.bgra8PremultipliedBytes[
                        sourceOffset..<(sourceOffset + image.bytesPerRow)
                    ]
                )
            }
        }
        return PeriodicRepeatExport(
            pixelSize: plan.pixelSize,
            bytesPerRow: destination.bytesPerRow,
            bgra8Bytes: bytes
        )
    }

    func exportFlattenedScene(
        strategy: TilingStrategy,
        request: DocumentPaintStableFlattenedOutputRequest,
        outputGeometryRevision: UInt64
    ) async throws -> FlattenedSceneExport {
        let image = try await collectLayerComposite(
            strategy: strategy,
            outputRegion: try DocumentPaintStableExportAdapter.outputRegion(
                pixelSize: request.pixelSize
            ),
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: request.outputMapping
        ).image
        return FlattenedSceneExport(
            pixelSize: request.pixelSize,
            bytesPerRow: image.bytesPerRow,
            bgra8Bytes: try DocumentPaintStableExportAdapter.destinationBytes(
                image,
                transparentBackground: request.transparentBackground
            ),
            hasTransparentBackground: request.transparentBackground
        )
    }

    private func collectLayerComposite(
        strategy: TilingStrategy,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping,
        expectedGeneration: UInt64? = nil
    ) async throws -> (
        generation: UInt64,
        image: DocumentPaintEncodedPremultipliedBGRA8
    ) {
        try DocumentPaintStableSnapshotChunkPlanner.validateOutput(
            outputRegion,
            limits: stableCollectionRendererLimits
        )
        let descriptor = try DocumentPaintTightBGRA8Descriptor(
            outputRegion: outputRegion,
            maximumByteCount: stableCollectionRendererLimits.maximumOutputBytes
        )
        let plan = try registry.prepareLayerCompositePlan(
            addressing: Self.storageAddressing(for: strategy),
            addressingRevision: outputGeometryRevision,
            outputRegion: outputRegion,
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: outputMapping,
            limits: .documentProduction
        )
        if let expectedGeneration,
           expectedGeneration != plan.documentGeneration {
            plan.close()
            throw DocumentPaintSurfaceStoreError.visibleCaptureContention(
                maximumAttempts: 1
            )
        }
        let collector = try DocumentPaintTightBGRA8Collector(
            descriptor: descriptor
        )
        try await layerCompositor.collect(
            plan,
            to: collector
        )
        return (plan.documentGeneration, try await collector.result())
    }

    private static func storageAddressing(
        for strategy: TilingStrategy
    ) -> SparseTileAddressing {
        if let layout = strategy.compiledSymmetry.domain.finite?.radial.layout {
            return .radial(layout: layout)
        }
        let storageSize = PixelSize(
            width: Int(strategy.tileSize.width),
            height: Int(strategy.tileSize.height)
        )
        switch strategy.documentConfiguration {
        case .periodic:
            return .periodic(period: storageSize)
        case .finite:
            return .finite(storageSize)
        }
    }

    private static func finiteOutputMapping(
        for strategy: TilingStrategy
    ) throws -> SparseTileSamplingOutputMapping {
        if strategy.compiledSymmetry.domain.finite?.radial.layout != nil {
            return try .finiteRadial(strategy: strategy)
        }
        return .affine(.identity)
    }

    func commitStroke(
        _ source: StrokePreparedCommitMutationSource,
        compositeParameters: DocumentPaintStrokeCompositeParameters,
        publicationState: StrokeCommitPublicationState? = nil
    ) async throws -> DocumentPaintSurfaceApplicationResult {
        guard activeStrokeSurfaceSlot.current != nil else {
            try? source.cancelUnclaimed()
            throw DocumentPaintRenderContextError.noActiveStroke
        }
        let claim = try beginCommandOperation(
            requiresQuiescentStroke: false,
            allowsTransientDisplay: true
        )
        defer { finishCommandOperation(claim) }
        if let source = activeTransientDisplaySource {
            try await abandonTransientDisplaySource(source)
        }
        let baseIdentity = canonicalStateIdentity()
        let reservation = canonicalRevisionReservation()
        activeCanonicalReservation = reservation
        defer { activeCanonicalReservation = nil }
        let result = try await transactionWorker.commitStroke(
            source,
            compositeParameters: compositeParameters,
            canonicalReservation: reservation,
            publicationState: publicationState
        )
        return applicationResult(
            result,
            reservation: reservation,
            baseIdentity: baseIdentity
        )
    }

    func clear() async throws -> DocumentPaintSurfaceApplicationResult {
        let claim = try beginCommandOperation()
        defer { finishCommandOperation(claim) }
        let layerID: UUID
        do {
            layerID = try registry.layerStack
                .activeLayerForRasterMutation().id
        } catch LayerStackError.activeLayerLocked(let lockedID) {
            throw DocumentPaintRenderContextError.activeLayerLocked(lockedID)
        }
        let baseIdentity = canonicalStateIdentity()
        let reservation = canonicalRevisionReservation()
        activeCanonicalReservation = reservation
        defer { activeCanonicalReservation = nil }
        let result = try await transactionWorker.clear(
            layerID: layerID,
            canonicalReservation: reservation
        )
        return applicationResult(
            result,
            reservation: reservation,
            baseIdentity: baseIdentity
        )
    }

    func applyLayerStack(
        _ target: LayerStack
    ) throws -> DocumentPaintLayerApplicationResult {
        let claim = try beginCommandOperation()
        defer { finishCommandOperation(claim) }
        let current = registry.snapshot()
        let baseIdentity = canonicalStateIdentity()
        if target == current.layerStack {
            return DocumentPaintLayerApplicationResult(
                didPublish: false,
                before: current.layerStack,
                after: current.layerStack,
                beforeGeometry: current.geometry,
                afterGeometry: current.geometry,
                baseGeneration: current.generation,
                generation: current.generation,
                revision: nil,
                baseCanonicalIdentity: baseIdentity,
                targetCanonicalIdentity: baseIdentity,
                compositeInvalidation: .none
            )
        }
        let invalidation = CanvasCompositeInvalidation.classify(
            before: current.layerStack,
            after: target,
            rasterDirtyCoordinates: [],
            geometryChanged: false,
            documentReplaced: false
        )
        let transaction = try registry.prepareLayerSurfaceTransaction(
            layerStack: target
        )
        return try publishLayerTransaction(
            transaction,
            geometryChanges: false,
            compositeInvalidation: invalidation
        )
    }

    private func publishLayerTransaction(
        _ transaction: LayerSurfaceTransaction,
        geometryChanges: Bool,
        compositeInvalidation: CanvasCompositeInvalidation
    ) throws -> DocumentPaintLayerApplicationResult {
        let baseIdentity = canonicalStateIdentity()
        let canonicalReservation = canonicalRevisionReservation(
            geometry: geometryChanges,
            layerStack: true,
            composite: compositeInvalidation.affectsPixels
        )
        try canonicalReservation.prepare()
        let retainedBytes = transaction.historyRetainedBytes
        let (usedBytes, usedOverflow) = revisionStore.residentBytes
            .addingReportingOverflow(layerHistoryResidentBytes)
        guard !usedOverflow, usedBytes <= maximumRevisionBytes else {
            transaction.cancel()
            throw DocumentPaintRenderContextError.layerHistoryBudgetExceeded(
                required: retainedBytes,
                available: 0
            )
        }
        let availableBytes = maximumRevisionBytes - usedBytes
        guard retainedBytes <= availableBytes else {
            transaction.cancel()
            throw DocumentPaintRenderContextError.layerHistoryBudgetExceeded(
                required: retainedBytes,
                available: availableBytes
            )
        }
        guard nextLayerRevisionID < UInt64.max else {
            transaction.cancel()
            throw DocumentPaintRenderContextError
                .layerHistoryIdentityOverflow
        }
        let (nextResidentBytes, residentOverflow) = layerHistoryResidentBytes
            .addingReportingOverflow(retainedBytes)
        guard !residentOverflow else {
            transaction.cancel()
            throw DocumentPaintRenderContextError.layerHistoryBudgetExceeded(
                required: retainedBytes,
                available: availableBytes
            )
        }
        let beforeGeometry = registry.geometry
        let id = StoredRasterRevisionID(
            rawValue: nextLayerRevisionID,
            namespace: layerRevisionStoreIdentity
        )
        let receipt = transaction.commit()
        guard let prepared = canonicalReservation.result() else {
            preconditionFailure("Layer transaction lost revision reservation")
        }
        let targetIdentity = publishCanonicalRevisionAdvance(
            prepared,
            baseIdentity: baseIdentity,
            invalidation: compositeInvalidation
        )
        activeRasterEndpoint = nil
        nextLayerRevisionID += 1
        layerHistoryRevisions[id] = receipt.historyRevision
        layerHistoryResidentBytes = nextResidentBytes
        return DocumentPaintLayerApplicationResult(
            didPublish: true,
            before: receipt.before,
            after: receipt.after,
            beforeGeometry: beforeGeometry,
            afterGeometry: registry.geometry,
            baseGeneration: receipt.baseGeneration,
            generation: receipt.generation,
            revision: LayerSurfaceRevisionReference(
                id: id,
                retainedBytes: retainedBytes
            ),
            baseCanonicalIdentity: baseIdentity,
            targetCanonicalIdentity: targetIdentity,
            compositeInvalidation: compositeInvalidation
        )
    }

    func restoreLayerStack(
        _ reference: LayerSurfaceRevisionReference,
        endpoint: LayerSurfaceRevisionEndpoint
    ) throws -> DocumentPaintLayerApplicationResult {
        let claim = try beginCommandOperation()
        defer { finishCommandOperation(claim) }
        guard let revision = layerHistoryRevisions[reference.id],
              revision.retainedBytes == reference.retainedBytes
        else {
            throw DocumentPaintRenderContextError
                .missingLayerHistoryRevision(reference.id)
        }
        if registry.currentStateMatches(revision, endpoint: endpoint) {
            let current = registry.snapshot()
            let identity = canonicalStateIdentity()
            return DocumentPaintLayerApplicationResult(
                didPublish: false,
                before: current.layerStack,
                after: current.layerStack,
                beforeGeometry: current.geometry,
                afterGeometry: current.geometry,
                baseGeneration: current.generation,
                generation: current.generation,
                revision: reference,
                baseCanonicalIdentity: identity,
                targetCanonicalIdentity: identity,
                compositeInvalidation: .none
            )
        }
        let targetGeometry = revision.geometry(for: endpoint)
        let beforeGeometry = registry.geometry
        let baseIdentity = canonicalStateIdentity()
        let invalidation = CanvasCompositeInvalidation.classify(
            before: registry.layerStack,
            after: revision.layerStack(for: endpoint),
            rasterDirtyCoordinates: [],
            geometryChanged: targetGeometry != beforeGeometry,
            documentReplaced: false
        )
        let canonicalReservation = canonicalRevisionReservation(
            geometry: targetGeometry != beforeGeometry,
            layerStack: true,
            composite: invalidation.affectsPixels
        )
        try canonicalReservation.prepare()
        let receipt = try registry.prepareLayerSurfaceRestore(
            revision,
            endpoint: endpoint
        ).commit()
        guard let prepared = canonicalReservation.result() else {
            preconditionFailure("Layer restore lost revision reservation")
        }
        let targetIdentity = publishCanonicalRevisionAdvance(
            prepared,
            baseIdentity: baseIdentity,
            invalidation: invalidation
        )
        activeRasterEndpoint = nil
        return DocumentPaintLayerApplicationResult(
            didPublish: true,
            before: receipt.before,
            after: receipt.after,
            beforeGeometry: beforeGeometry,
            afterGeometry: registry.geometry,
            baseGeneration: receipt.baseGeneration,
            generation: receipt.generation,
            revision: reference,
            baseCanonicalIdentity: baseIdentity,
            targetCanonicalIdentity: targetIdentity,
            compositeInvalidation: invalidation
        )
    }

    func containsLayerRevision(_ id: StoredRasterRevisionID) -> Bool {
        layerHistoryRevisions[id] != nil
    }

    func resize(
        to candidateGeometry: DocumentPaintGeometry,
        targetRadialConfiguration: RadialSymmetryConfiguration? = nil
    ) async throws -> DocumentPaintLayerApplicationResult? {
        let claim = try beginCommandOperation()
        defer { finishCommandOperation(claim) }
        guard let transaction = try await transactionWorker.resizeAllLayers(
            to: candidateGeometry,
            targetRadialConfiguration: targetRadialConfiguration
        ) else { return nil }
        do {
            try Task.checkCancellation()
            return try publishLayerTransaction(
                transaction,
                geometryChanges: true,
                compositeInvalidation: .full
            )
        } catch {
            transaction.cancel()
            throw error
        }
    }

    func importEncodedBGRA8(
        candidateGeometry: DocumentPaintGeometry,
        input: DocumentPaintEncodedImportInput
    ) async throws -> DocumentPaintSurfaceApplicationResult {
        let claim = try beginCommandOperation()
        defer { finishCommandOperation(claim) }
        try Task.checkCancellation()
        let layerID = activeLayerID
        let maximumUploadBytes = maximumEncodedImportBytes
        let request = try await Task.detached {
            try Task.checkCancellation()
            return try DocumentPaintSurfaceEncodedImportRequest.validate(
                layerID: layerID,
                candidateGeometry: candidateGeometry,
                input: input,
                maximumUploadBytes: maximumUploadBytes
            )
        }.value
        try Task.checkCancellation()
        let baseIdentity = canonicalStateIdentity()
        let reservation = canonicalRevisionReservation(
            geometry: true,
            layerStack: true
        )
        activeCanonicalReservation = reservation
        defer { activeCanonicalReservation = nil }
        let result = try await transactionWorker.importEncoded(
            request,
            canonicalReservation: reservation
        )
        return applicationResult(
            result,
            reservation: reservation,
            baseIdentity: baseIdentity,
            publishedInvalidation: .full
        )
    }

    func restorePublishedRevision(
        _ reference: RasterRevisionReference,
        targetGeometry: DocumentPaintGeometry
    ) async throws -> DocumentPaintSurfaceRestoreResult {
        let claim = try beginCommandOperation()
        defer { finishCommandOperation(claim) }
        try Task.checkCancellation()
        let request = DocumentPaintSurfaceRestoreRequest(
            reference: reference,
            targetGeometry: targetGeometry
        )
        if activeRasterEndpoint == reference,
           targetGeometry == canonicalGeometry {
            let generation = registry.snapshot().generation
            return DocumentPaintSurfaceRestoreResult(
                didPublish: false,
                layerID: reference.layerID,
                beforeGeneration: generation,
                afterGeneration: generation,
                reference: reference,
                restoredCoordinates: []
            )
        }
        let baseIdentity = canonicalStateIdentity()
        let geometryChanges = targetGeometry != registry.geometry
        let canonicalReservation = canonicalRevisionReservation(
            geometry: geometryChanges,
            layerStack: geometryChanges
        )
        activeCanonicalReservation = canonicalReservation
        defer { activeCanonicalReservation = nil }
        let result = try await transactionWorker.restore(
            request,
            canonicalReservation: canonicalReservation
        )
        if result.afterGeneration != result.beforeGeneration {
            guard let prepared = canonicalReservation.result() else {
                preconditionFailure("Raster restore lost revision reservation")
            }
            _ = publishCanonicalRevisionAdvance(
                prepared,
                baseIdentity: baseIdentity,
                invalidation: geometryChanges
                    ? .full : .exact(result.restoredCoordinates)
            )
            activeRasterEndpoint = reference
        }
        return result
    }

    #if DEBUG
    func testingSetBeforeMutationPublicationClaimHook(
        _ hook: (@Sendable () async -> Void)?
    ) async {
        await transactionWorker
            .testingSetBeforeMutationPublicationClaimHook(hook)
    }

    func testingSetAfterMutationPublicationHook(
        _ hook: (@Sendable () async -> Void)?
    ) async {
        await transactionWorker.testingSetAfterMutationPublicationHook(hook)
    }
    #endif

    func releaseRevisions(
        _ revisionIDs: Set<StoredRasterRevisionID>
    ) async throws {
        let layerRevisionIDs = revisionIDs.filter {
            layerHistoryRevisions[$0] != nil
        }
        let rasterRevisionIDs = revisionIDs.subtracting(layerRevisionIDs)
        if !rasterRevisionIDs.isEmpty {
            try await transactionWorker.releaseRevisions(rasterRevisionIDs)
            if let activeRasterEndpoint,
               rasterRevisionIDs.contains(activeRasterEndpoint.id) {
                self.activeRasterEndpoint = nil
            }
        }
        for id in layerRevisionIDs {
            guard let revision = layerHistoryRevisions.removeValue(forKey: id)
            else { preconditionFailure("Layer revision vanished during release") }
            precondition(layerHistoryResidentBytes >= revision.retainedBytes)
            layerHistoryResidentBytes -= revision.retainedBytes
            revision.close()
        }
    }

    func retryTransactionCleanup() async throws {
        try await transactionWorker.retry()
    }

    private func beginCommandOperation(
        requiresQuiescentStroke: Bool = true,
        allowsTransientDisplay: Bool = false
    ) throws -> UUID {
        guard !hasRequestedShutdown else {
            throw DocumentPaintRenderContextError.isShutdown
        }
        guard activeCommandOperationID == nil else {
            throw DocumentPaintRenderContextError
                .activeCommandOperationExists
        }
        if requiresQuiescentStroke,
           activeStrokeSurfaceSlot.current != nil {
            throw DocumentPaintRenderContextError.activeStrokeExists
        }
        if !allowsTransientDisplay,
           activeTransientDisplaySource != nil {
            throw DocumentPaintRenderContextError
                .activeTransientDisplaySourceExists
        }
        let claim = UUID()
        activeCommandOperationID = claim
        return claim
    }

    private func finishCommandOperation(_ claim: UUID) {
        precondition(activeCommandOperationID == claim)
        activeCommandOperationID = nil
    }

    private func beginShutdownOperation() throws -> UUID {
        guard activeCommandOperationID == nil else {
            throw DocumentPaintRenderContextError
                .activeCommandOperationExists
        }
        let claim = UUID()
        activeCommandOperationID = claim
        return claim
    }

    func prepareVisiblePlan(
        _ request: DocumentPaintCanonicalVisiblePlanRequest,
        limits: SparseTilePlanLimits = .documentProduction
    ) async throws -> DocumentPaintPreparedVisiblePlanToken {
        try await visiblePlanController.prepare(
            request: request.controllerToken,
            limits: limits
        )
    }

    func requestTransientVisiblePlan(
        _ source: DocumentPaintTransientDisplaySource,
        addressingRevision: UInt64,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping = .affine(.identity)
    ) async throws -> DocumentPaintTransientVisiblePlanRequest {
        guard source.contextIdentity == identity,
              activeTransientDisplaySource?.sourceIdentity
                == source.sourceIdentity
        else {
            throw DocumentPaintRenderContextError.staleTransientDisplaySource
        }
        guard source.acknowledgementStatus == .available else {
            throw DocumentPaintVisiblePlanControllerError
                .transientSourceNotAvailable
        }
        let capture = try registry.captureTransientVisibleSources(
            layerID: activeLayerID,
            descriptor: source.descriptor,
            addressing: source.addressing,
            addressingRevision: addressingRevision,
            outputRegion: outputRegion,
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: outputMapping
        )
        let specification = DocumentPaintVisiblePlanSpecification(
            key: capture.key,
            outputRegion: capture.outputRegion
        )
        let owned = DocumentPaintVisiblePlanOwnedSources(
            contextIdentity: identity,
            sourceBatch: capture.sourceBatch,
            transientSource: source
        )
        let token: DocumentPaintVisiblePlanRequestToken
        do {
            token = try await visiblePlanController.request(
                specification,
                ownedSources: owned
            )
        } catch {
            try capture.sourceBatch.abandon()
            throw error
        }
        return DocumentPaintTransientVisiblePlanRequest(
            controllerToken: token,
            specification: specification
        )
    }

    func prepareTransientVisiblePlan(
        _ request: DocumentPaintTransientVisiblePlanRequest,
        limits: SparseTilePlanLimits = .documentProduction
    ) async throws -> DocumentPaintPreparedVisiblePlanToken {
        return try await visiblePlanController.prepare(
            request: request.controllerToken,
            limits: limits
        )
    }

    func cancelVisiblePlanRequest(
        _ request: DocumentPaintCanonicalVisiblePlanRequest
    ) async throws {
        try await visiblePlanController.cancel(request.controllerToken)
    }

    func cancelVisiblePlanRequest(
        _ request: DocumentPaintTransientVisiblePlanRequest
    ) async throws {
        try await visiblePlanController.cancel(request.controllerToken)
    }

    func installVisiblePlan(
        _ prepared: DocumentPaintPreparedVisiblePlanToken
    ) async throws -> DocumentPaintInstalledVisiblePlanToken {
        try await visiblePlanController.install(prepared)
    }

    func prepareDisplaySubmission(
        parameters: SparseTileSamplingEncodeParameters = .identity
    ) async throws -> DocumentPaintPreparedDisplaySubmission {
        try await visiblePlanController.prepareDisplaySubmission(
            parameters: parameters
        )
    }

    func prepareLayerDisplaySubmission(
        transient: DocumentPaintTransientDisplaySource?,
        addressing: SparseTileAddressing,
        addressingRevision: UInt64,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping,
        parameters: SparseTileSamplingEncodeParameters
    ) async throws -> PreparedLayerCompositeDisplaySubmission {
        if let transient {
            guard transient.contextIdentity == identity,
                  activeTransientDisplaySource?.sourceIdentity
                    == transient.sourceIdentity
            else {
                throw DocumentPaintRenderContextError
                    .staleTransientDisplaySource
            }
            guard transient.acknowledgementStatus == .available else {
                throw DocumentPaintVisiblePlanControllerError
                    .transientSourceNotAvailable
            }
        }
        let samplingParameters = SparseTileSamplingEncodeParameters(
            outputMapping: outputMapping,
            compositeMode: parameters.compositeMode,
            liveVisible: parameters.liveVisible,
            strokeOpacity: parameters.strokeOpacity,
            accumulationLimit: parameters.accumulationLimit,
            eraserStrength: parameters.eraserStrength
        )
        let transientInput = transient.map {
            PreparedLayerCompositeTransientSource(
                layerID: activeLayerID,
                descriptor: $0.descriptor,
                samplingParameters: samplingParameters
            )
        }
        let plan = try registry.prepareLayerCompositePlan(
            transient: transientInput,
            addressing: addressing,
            addressingRevision: addressingRevision,
            outputRegion: outputRegion,
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: outputMapping,
            limits: .documentProduction
        )
        do {
            let submission = try await layerCompositor.prepareDisplay(
                plan,
                parameters: parameters
            )
            return submission
        } catch {
            if let transient {
                await visiblePlanController
                    .retainAndSettleUnrequestedTransientSource(transient)
            }
            throw error
        }
    }

    /// Synchronous MainActor draw boundary. All fallible preparation and
    /// capacity reservation completed before this one-shot submission returned.
    func encodeDisplaySubmission(
        _ submission: DocumentPaintPreparedDisplaySubmission,
        target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) throws {
        try submission.encode(
            expectedOwner: identity,
            target: target,
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPassDescriptor
        )
    }

    func encodeLayerDisplaySubmission(
        _ submission: PreparedLayerCompositeDisplaySubmission,
        target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) throws {
        try submission.encode(
            target: target,
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPassDescriptor
        )
    }

    func cancelDisplaySubmission(
        _ submission: DocumentPaintPreparedDisplaySubmission
    ) throws {
        try submission.cancel(expectedOwner: identity)
    }

    func cancelLayerDisplaySubmission(
        _ submission: PreparedLayerCompositeDisplaySubmission
    ) throws {
        try submission.cancel()
    }

    func retryLayerDisplayCompletions() async throws {
        try await layerCompositor.retryDisplayCompletion()
        try await visiblePlanController.retryRetirementsAndCompletions()
    }

    func retryVisiblePlanRetirementsAndCompletions() async throws {
        try await visiblePlanController.retryRetirementsAndCompletions()
    }

    func shutdown(
        reason: DocumentPaintRenderContextShutdownReason
    ) async throws -> DocumentPaintRenderContextShutdownSnapshot {
        if hasShutdown {
            return try await visiblePlanController.shutdown(reason: reason)
        }
        let claim = try beginShutdownOperation()
        defer { finishCommandOperation(claim) }
        hasRequestedShutdown = true
        try await layerCompositor.shutdown()
        if let source = activeTransientDisplaySource {
            await visiblePlanController
                .retainAndSettleUnrequestedTransientSource(source)
        }
        let controller = try await visiblePlanController.shutdown(reason: reason)
        guard controller.isComplete else { return controller }
        try await stableCollectionRenderer.shutdown()
        activeTransientDisplaySource = nil
        if let capability = activeStrokeSurfaceSlot.current {
            try capability.cancel(expectedOwnerIdentity: identity)
        }
        try await transactionWorker.shutdown()
        let layerRevisions = Array(layerHistoryRevisions.values)
        layerHistoryRevisions.removeAll(keepingCapacity: false)
        layerHistoryResidentBytes = 0
        for revision in layerRevisions { revision.close() }
        hasShutdown = true
        return controller
    }

}
