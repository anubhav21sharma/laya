import Foundation
@preconcurrency import Metal
import PatternEngine

enum DocumentPaintRenderContextError: Error, Equatable, Sendable {
    case activeStrokeExists
    case noActiveStroke
    case foreignTransientDisplayFrame
    case activeTransientDisplaySourceExists
    case staleTransientDisplaySource
    case activeCommandOperationExists
    case isShutdown
}

struct DocumentPaintSurfaceApplicationResult: Equatable, Sendable {
    let didPublish: Bool
    let layerID: UUID
    let generation: UInt64
    let historyPair: PendingRasterRevisionPair?
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
    let backingTileBytes: Int
    let activeSnapshotTokenCount: Int
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
    private let activeLayerID: UUID
    private var dispatchSequence: UInt64 = 0
    private var isShutdown = false

    init(
        transaction: DocumentPaintSurfaceTransaction,
        registry: DocumentPaintSurfaceStore,
        revisionStore: TiledRasterRevisionStore,
        activeLayerID: UUID
    ) {
        self.transaction = transaction
        self.registry = registry
        self.revisionStore = revisionStore
        self.activeLayerID = activeLayerID
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
        compositeParameters: DocumentPaintStrokeCompositeParameters
    ) async throws -> DocumentPaintSurfaceApplicationResult {
        do {
            try beginCommand()
            let current = registry.snapshot()
            let request = DocumentPaintSurfaceMutationRequest(
                kind: .stroke,
                layerID: activeLayerID,
                baseGeometry: current.geometry,
                candidateGeometry: current.geometry,
                dirtyCoordinates: source.coordinates,
                explicitlyRemovedCoordinates: [],
                requiresHistoryPair: true
            )
            return try executeMutation(
                transaction.prepareMutation(request),
                requiresHistory: true,
                strokeSource: source,
                compositeParameters: compositeParameters
            )
        } catch {
            try? source.cancelUnclaimed()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func clear() async throws -> DocumentPaintSurfaceApplicationResult {
        try beginCommand()
        let current = registry.snapshot()
        let references = current.layers.first {
            $0.layerID == activeLayerID
        }?.references ?? []
        let request = DocumentPaintSurfaceMutationRequest(
            kind: .clear,
            layerID: activeLayerID,
            baseGeometry: current.geometry,
            candidateGeometry: current.geometry,
            dirtyCoordinates: [],
            explicitlyRemovedCoordinates: references.map(\.coordinate),
            requiresHistoryPair: true
        )
        return try executeMutation(
            transaction.prepareMutation(request),
            requiresHistory: true
        )
    }

    func resize(
        to candidateGeometry: DocumentPaintGeometry,
        targetRadialConfiguration: RadialSymmetryConfiguration?
    ) async throws -> DocumentPaintSurfaceApplicationResult {
        try beginCommand()
        let current = registry.snapshot()
        if current.geometry == candidateGeometry {
            return DocumentPaintSurfaceApplicationResult(
                didPublish: false,
                layerID: activeLayerID,
                generation: current.generation,
                historyPair: nil
            )
        }
        let references = current.layers.first {
            $0.layerID == activeLayerID
        }?.references ?? []
        let resizePlan = try DocumentPaintSurfaceTransaction.makeResizePlan(
            baseCoordinates: references.map(\.coordinate),
            sourceGeometry: current.geometry,
            candidateGeometry: candidateGeometry
        )
        let request = DocumentPaintSurfaceMutationRequest(
            kind: .resize,
            layerID: activeLayerID,
            baseGeometry: current.geometry,
            candidateGeometry: candidateGeometry,
            targetRadialConfiguration: targetRadialConfiguration,
            dirtyCoordinates: resizePlan.afterCoordinates,
            explicitlyRemovedCoordinates: resizePlan.removedCoordinates,
            requiresHistoryPair: true
        )
        return try executeMutation(
            transaction.prepareMutation(request),
            requiresHistory: true
        )
    }

    func importEncoded(
        _ request: DocumentPaintSurfaceEncodedImportRequest
    ) async throws -> DocumentPaintSurfaceApplicationResult {
        try beginCommand()
        return try executeMutation(
            transaction.prepareEncodedImport(request),
            requiresHistory: false
        )
    }

    func restore(
        _ request: DocumentPaintSurfaceRestoreRequest
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
            let result = try transaction.publishRestore(terminal)
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
        compositeParameters: DocumentPaintStrokeCompositeParameters? = nil
    ) throws -> DocumentPaintSurfaceApplicationResult {
        var owned: OwnedMutation?
        do {
            switch try preparation() {
            case let .noOp(result):
                try? strokeSource?.cancelUnclaimed()
                return DocumentPaintSurfaceApplicationResult(
                    didPublish: false,
                    layerID: result.layerID,
                    generation: result.generation,
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
                let result = try transaction.publish(terminal)
                owned = nil
                return DocumentPaintSurfaceApplicationResult(
                    didPublish: true,
                    layerID: result.layerID,
                    generation: result.afterGeneration,
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
    let activeLayerID: UUID

    private let registry: DocumentPaintSurfaceStore
    private let revisionStore: TiledRasterRevisionStore
    private let transactionWorker: DocumentPaintTransactionWorker
    private let visiblePlanController: DocumentPaintVisiblePlanController
    private let stableCollectionRenderer: DocumentPaintStableSnapshotRenderer
    private let stableCollectionRendererLimits =
        DocumentPaintStableSnapshotRendererLimits.production
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
        initialLayerID: UUID,
        byteBudget: Int,
        snapshotPayloadLiabilityByteBudget: Int? = nil,
        transferByteCapacity: Int,
        maximumRevisionBytes: Int,
        generation: UInt64 = 0,
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
            layerIDs: [initialLayerID],
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

        activeLayerID = initialLayerID
        self.registry = registry
        self.revisionStore = revisionStore
        transactionWorker = DocumentPaintTransactionWorker(
            transaction: transaction,
            registry: registry,
            revisionStore: revisionStore,
            activeLayerID: initialLayerID
        )
        visiblePlanController = DocumentPaintVisiblePlanController(
            device: device,
            pipelines: DocumentPaintVisiblePlanPipelines(
                affine: affineSamplingPipeline,
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
    }

    func snapshot() async -> DocumentPaintRenderContextSnapshot {
        let registrySnapshot = registry.snapshot()
        let tileStoreSnapshot = registry.sharedTileStore.snapshot()
        async let transactionSnapshot = transactionWorker.snapshot()
        async let planSnapshot = visiblePlanController.snapshot()
        async let collectionRendererSnapshot =
            stableCollectionRenderer.snapshot()
        let transaction = await transactionSnapshot
        let visiblePlan = await planSnapshot
        let stableCollectionRenderer = await collectionRendererSnapshot
        return DocumentPaintRenderContextSnapshot(
            storeIdentity: registry.tileStoreIdentity,
            activeLayerID: activeLayerID,
            documentGeneration: registrySnapshot.generation,
            layerIDs: registrySnapshot.layers.map(\.layerID),
            tileByteBudget: registrySnapshot.tileByteBudget,
            residentTileBytes: registrySnapshot.residentTileBytes,
            backingTileBytes: registrySnapshot.backingTileBytes,
            activeSnapshotTokenCount:
                tileStoreSnapshot.activeSnapshotTokenCount,
            aggregateSnapshotReferenceCount:
                tileStoreSnapshot.aggregateSnapshotReferenceCount,
            activeTileLeaseCount: tileStoreSnapshot.activeLeaseCount,
            snapshotMetadataByteCount:
                tileStoreSnapshot.snapshotMetadataByteCount,
            snapshotPayloadLiabilityByteCount:
                tileStoreSnapshot.snapshotPayloadDebtByteCount,
            revisionResidentBytes: revisionStore.residentBytes,
            activeStrokeSurfaceCount:
                activeStrokeSurfaceSlot.current == nil ? 0 : 1,
            activeCommandOperationCount:
                activeCommandOperationID == nil ? 0 : 1,
            transaction: transaction,
            visiblePlan: visiblePlan,
            stableCollectionRenderer: stableCollectionRenderer
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
        let slot = activeStrokeSurfaceSlot
        let capability = try registry.issueCurrentStrokeSurfaceCapability(
            layerID: activeLayerID,
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
              frame.surface.layerID == activeLayerID,
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

    func exportFiniteCanvas(
        strategy: TilingStrategy,
        outputGeometryRevision: UInt64,
        transparentBackground: Bool
    ) async throws -> FiniteCanvasExport {
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: activeLayerID,
            addressing: Self.storageAddressing(for: strategy),
            addressingRevision: outputGeometryRevision,
            outputMapping: try Self.finiteOutputMapping(for: strategy)
        )
        return try await FiniteCanvasExport.collectStable(
            strategy: strategy,
            snapshot: snapshot,
            renderer: stableCollectionRenderer,
            outputGeometryRevision: outputGeometryRevision,
            transparentBackground: transparentBackground
        )
    }

    func exportPeriodicMetric(
        strategy: TilingStrategy,
        density: Int,
        outputGeometryRevision: UInt64
    ) async throws -> PeriodicRepeatExport {
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: activeLayerID,
            addressing: Self.storageAddressing(for: strategy),
            addressingRevision: outputGeometryRevision,
            outputMapping: .affine(.identity)
        )
        return try await PeriodicRepeatExport.collectStableMetric(
            strategy: strategy,
            density: density,
            snapshot: snapshot,
            renderer: stableCollectionRenderer,
            outputGeometryRevision: outputGeometryRevision
        )
    }

    func exportPeriodicBaked(
        strategy: TilingStrategy,
        outputGeometryRevision: UInt64
    ) async throws -> PeriodicRepeatExport {
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: activeLayerID,
            addressing: Self.storageAddressing(for: strategy),
            addressingRevision: outputGeometryRevision,
            outputMapping: .affine(.identity)
        )
        return try await PeriodicRepeatExport.collectStableBaked(
            strategy: strategy,
            snapshot: snapshot,
            renderer: stableCollectionRenderer,
            outputGeometryRevision: outputGeometryRevision
        )
    }

    func exportFlattenedScene(
        strategy: TilingStrategy,
        request: DocumentPaintStableFlattenedOutputRequest,
        outputGeometryRevision: UInt64
    ) async throws -> FlattenedSceneExport {
        let snapshot = try registry.captureStableCanonicalSnapshot(
            layerID: activeLayerID,
            addressing: Self.storageAddressing(for: strategy),
            addressingRevision: outputGeometryRevision,
            outputMapping: request.outputMapping
        )
        return try await FlattenedSceneExport.collectStable(
            request: request,
            snapshot: snapshot,
            renderer: stableCollectionRenderer,
            outputGeometryRevision: outputGeometryRevision
        )
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
        compositeParameters: DocumentPaintStrokeCompositeParameters
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
        return try await transactionWorker.commitStroke(
            source,
            compositeParameters: compositeParameters
        )
    }

    func clear() async throws -> DocumentPaintSurfaceApplicationResult {
        let claim = try beginCommandOperation()
        defer { finishCommandOperation(claim) }
        return try await transactionWorker.clear()
    }

    func resize(
        to candidateGeometry: DocumentPaintGeometry,
        targetRadialConfiguration: RadialSymmetryConfiguration? = nil
    ) async throws -> DocumentPaintSurfaceApplicationResult {
        let claim = try beginCommandOperation()
        defer { finishCommandOperation(claim) }
        return try await transactionWorker.resize(
            to: candidateGeometry,
            targetRadialConfiguration: targetRadialConfiguration
        )
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
        return try await transactionWorker.importEncoded(request)
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
        return try await transactionWorker.restore(request)
    }

    func releaseRevisions(
        _ revisionIDs: Set<StoredRasterRevisionID>
    ) async throws {
        try await transactionWorker.releaseRevisions(revisionIDs)
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

    func cancelDisplaySubmission(
        _ submission: DocumentPaintPreparedDisplaySubmission
    ) throws {
        try submission.cancel(expectedOwner: identity)
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
        hasShutdown = true
        return controller
    }

}
