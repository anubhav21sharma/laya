import EditorCore
import Foundation
@preconcurrency import Metal
import PatternEngine

enum InteractiveStrokePresentationCacheError: Error, Equatable, Sendable {
    case foreignUpdate
    case staleRevision(
        current: InteractiveStrokePresentationRevision,
        proposed: InteractiveStrokePresentationRevision
    )
    case updateSlotCapacityExceeded(maximum: Int)
    case tileCapacityExceeded(required: Int, maximum: Int)
    case physicalCapacityExceeded(
        requested: Int,
        current: Int,
        highWater: Int,
        maximum: Int
    )
    case commandBufferUnavailable
    case blitEncoderUnavailable
    case clearEncoderUnavailable
    case commandFailed(String)
    case injectedRolePreparationFailure(StrokePrivateSurfaceLayer)
    case injectedRetirementFailure(UUID)
}

final class InteractiveStrokePresentationCacheFailureInjection:
    @unchecked Sendable
{
    let sequence: UInt64?
    let role: StrokePrivateSurfaceLayer?
    private let lock = NSLock()
    private var retirementFailuresRemaining: Int

    init(
        sequence: UInt64? = nil,
        role: StrokePrivateSurfaceLayer? = nil,
        retirementFailureCount: Int = 0
    ) {
        precondition((sequence == nil) == (role == nil))
        precondition(retirementFailureCount >= 0)
        self.sequence = sequence
        self.role = role
        retirementFailuresRemaining = retirementFailureCount
    }

    func consumeRetirementFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard retirementFailuresRemaining > 0 else { return false }
        retirementFailuresRemaining -= 1
        return true
    }
}

struct InteractiveStrokeCompositeParameters: Equatable, Sendable {
    let blendMode: LayerBlendMode
    let opacity: Float
}

struct InteractiveStrokePresentationRevision:
    Equatable, Hashable, Comparable, Sendable
{
    let generation: UInt64
    let strokeEpoch: UUID
    let sequence: UInt64

    static func < (
        lhs: InteractiveStrokePresentationRevision,
        rhs: InteractiveStrokePresentationRevision
    ) -> Bool {
        if lhs.generation != rhs.generation {
            return lhs.generation < rhs.generation
        }
        if lhs.strokeEpoch != rhs.strokeEpoch {
            return lhs.strokeEpoch.uuidString < rhs.strokeEpoch.uuidString
        }
        return lhs.sequence < rhs.sequence
    }
}

struct InteractiveStrokePresentationSnapshot: @unchecked Sendable {
    let revision: InteractiveStrokePresentationRevision
    let canonicalIdentity: CanvasCanonicalStateIdentity
    let authoritative: TiledRasterExactReferenceProvider?
    let prediction: TiledRasterExactReferenceProvider?
    let parameters: InteractiveStrokeCompositeParameters
}

enum InteractiveStrokePresentationCacheRetirementState:
    Equatable, Sendable
{
    case idle
    case waiting(strokeEpoch: UUID)
    case failed(strokeEpoch: UUID)
}

struct InteractiveStrokePresentationCacheSnapshot: Equatable, Sendable {
    let maximumUpdateSlotCount: Int
    let activeUpdateSlotCount: Int
    let updateSlotHighWater: Int
    let residentBytes: Int
    let residentByteHighWater: Int
    let residentByteBudget: Int
    let totalPhysicalResidentBytes: Int
    let totalPhysicalResidentByteHighWater: Int
    let provisionalBytes: Int
    let componentCoverageBytes: Int
    let backingBytes: Int
    let publishedRevision: InteractiveStrokePresentationRevision?
    let submittedUpdateCount: UInt64
    let completedUpdateCount: UInt64
    let failedUpdateCount: UInt64
    let cancelledUpdateCount: UInt64
    let acknowledgementSettlementCount: UInt64
    let activeStrokeEpochCount: Int
    let activeUpdateOwnerCount: Int
    let retirementWaiterCount: Int
    let retirementResumeCount: UInt64
    let rolledBackRoleCommitCount: UInt64
    let retirementState: InteractiveStrokePresentationCacheRetirementState
    let retirementFailureCount: UInt64
    let retirementErrorDescription: String?
    let pendingPreparedAcknowledgementCount: Int
    let isIdle: Bool
}

protocol InteractiveStrokePresentationCacheCompletionGating: Sendable {
    func cacheCommandDidSubmit() async
    func waitAfterGPUCompletion() async
    func cacheRetirementDidWait() async
    func cacheRetirementDidFail() async
    func cacheAcknowledgementDidFail() async
    func waitForLifecycleRetry(attempt: Int) async throws
}

actor InteractiveStrokePresentationCache {
    private static let maximumUpdateSlotCount = 2

    private final class GenerationState: @unchecked Sendable {
        let generation: UInt64
        let strokeEpoch: UUID
        let layerID: UUID
        let pixelSize: PixelSize
        let authoritative: TiledRasterSurface
        let prediction: TiledRasterSurface

        init(
            store: PaintTileStore,
            generation: UInt64,
            strokeEpoch: UUID,
            layerID: UUID,
            pixelSize: PixelSize
        ) {
            self.generation = generation
            self.strokeEpoch = strokeEpoch
            self.layerID = layerID
            self.pixelSize = pixelSize
            authoritative = TiledRasterSurface(
                store: store,
                layerID: layerID,
                pixelSize: pixelSize,
                generation: generation
            )
            prediction = TiledRasterSurface(
                store: store,
                layerID: layerID,
                pixelSize: pixelSize,
                generation: generation
            )
        }
    }

    private struct GPUCompletion: Sendable {
        let succeeded: Bool
        let message: String?
    }

    private struct PendingPreparedAcknowledgement: Sendable {
        let acknowledgement: StrokePreparedFrameAcknowledgement
        let settlement:
            DocumentPaintTransientCacheAcknowledgementSettlement
        let ownerID: UUID
    }

    private final class GPUCompletionSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: GPUCompletion?
        private var waiter: CheckedContinuation<GPUCompletion, Never>?

        func finish(_ completion: GPUCompletion) {
            lock.lock()
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: completion)
            } else {
                self.completion = completion
                lock.unlock()
            }
        }

        func value() async -> GPUCompletion {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let completion {
                    lock.unlock()
                    continuation.resume(returning: completion)
                } else {
                    precondition(waiter == nil)
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }

    private final class DestinationUpdate: @unchecked Sendable {
        let role: StrokePrivateSurfaceLayer
        let surface: TiledRasterSurface
        let targetCoordinates: [PaintTileCoordinate]
        let modifiedCoordinates: [PaintTileCoordinate]
        var lease: PaintTileLease?
        var provisional: PaintTileProvisionalReservation?
        let initialRevision: RasterRevision
        let initialDirtyCoordinates: [PaintTileCoordinate]
        var wasCommitted = false
        var wasFinalized = false
        var wasSettled = false

        init(
            role: StrokePrivateSurfaceLayer,
            surface: TiledRasterSurface,
            targetCoordinates: [PaintTileCoordinate],
            modifiedCoordinates: [PaintTileCoordinate]
        ) {
            self.role = role
            self.surface = surface
            self.targetCoordinates = targetCoordinates
            self.modifiedCoordinates = modifiedCoordinates
            initialRevision = surface.revision
            initialDirtyCoordinates = surface.dirtyTileCoordinates
        }

        func reserve() throws {
            guard !targetCoordinates.isEmpty else { return }
            lease = try surface.reserveSortedUniqueTiles(
                at: targetCoordinates,
                pinReasons: [.inFlight]
            )
            provisional = try surface.makeProvisionalBindings(
                for: lease!,
                coordinates: targetCoordinates,
                modifiedCoordinates: modifiedCoordinates,
                workspace: PaintTileProvisionalWorkspace(
                    maximumBindingCount: targetCoordinates.count
                )
            )
        }

        func commit() throws {
            guard let provisional, let lease else { return }
            let modified = Set(modifiedCoordinates)
            self.lease = try surface.commitProvisionalBindings(
                provisional,
                for: lease,
                modifiedCoordinates: modifiedCoordinates,
                knownClearCoordinates: targetCoordinates.filter {
                    !modified.contains($0)
                }
            )
            wasCommitted = true
        }

        func rollback() throws {
            guard wasCommitted, !wasFinalized,
                  let provisional, let lease
            else { return }
            try surface.rollbackCommittedProvisionalBindings(
                provisional,
                for: lease,
                restoringRevision: initialRevision,
                dirtyCoordinates: initialDirtyCoordinates
            )
            wasCommitted = false
        }

        func finalize() {
            guard wasCommitted, !wasFinalized, let provisional else { return }
            surface.completeProvisionalBindings(provisional)
            wasFinalized = true
        }

        func settle() {
            guard !wasSettled else { return }
            wasSettled = true
            if let provisional, !wasFinalized {
                precondition(!wasCommitted)
                try? surface.cancelProvisionalBindings(provisional)
            }
            if let lease { try? surface.returnLease(lease) }
        }
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private var store: PaintTileStore
    private let byteBudget: Int
    private let maximumTileCount: Int
    private let completionGate:
        (any InteractiveStrokePresentationCacheCompletionGating)?
    private var failureInjection:
        InteractiveStrokePresentationCacheFailureInjection?
    private let traceRecorder: InteractiveBrushTraceRecorder?
    private var generationState: GenerationState?
    private var published: InteractiveStrokePresentationSnapshot?
    private var updatingOwnerID: UUID?
    private var updatingRevision: InteractiveStrokePresentationRevision?
    private var cancelledEpochs: Set<UUID> = []
    private var updateSlotHighWater = 0
    private var submittedUpdateCount: UInt64 = 0
    private var completedUpdateCount: UInt64 = 0
    private var failedUpdateCount: UInt64 = 0
    private var cancelledUpdateCount: UInt64 = 0
    private var acknowledgementSettlementCount: UInt64 = 0
    private var retirementWaiters:
        [(UUID, CheckedContinuation<Void, Never>)] = []
    private var retirementResumeCount: UInt64 = 0
    private var totalPhysicalResidentByteHighWater = 0
    private var rolledBackRoleCommitCount: UInt64 = 0
    private var retirementFailure: (strokeEpoch: UUID, description: String)?
    private var retirementFailureCount: UInt64 = 0
    private var pendingPreparedAcknowledgement:
        PendingPreparedAcknowledgement?

    init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        byteBudget: Int,
        maximumTileCount: Int,
        completionGate:
            (any InteractiveStrokePresentationCacheCompletionGating)? = nil,
        failureInjection:
            InteractiveStrokePresentationCacheFailureInjection? = nil,
        traceRecorder: InteractiveBrushTraceRecorder? = nil
    ) {
        precondition(byteBudget > 0 && maximumTileCount > 0)
        self.device = device
        self.commandQueue = commandQueue
        store = PaintTileStore(device: device, byteBudget: byteBudget)
        self.byteBudget = byteBudget
        self.maximumTileCount = maximumTileCount
        self.completionGate = completionGate
        self.failureInjection = failureInjection
        self.traceRecorder = traceRecorder
    }

    func adopt(
        _ update: DocumentPaintTransientCacheUpdate,
        parameters: InteractiveStrokeCompositeParameters
    ) async throws -> InteractiveStrokePresentationRevision {
        guard pendingPreparedAcknowledgement == nil else {
            throw InteractiveStrokePresentationCacheError.foreignUpdate
        }
        let ownerID = UUID()
        guard update.acknowledgementSettlement.claimOwnership(
            ownerID: ownerID
        ) else {
            throw InteractiveStrokePresentationCacheError.foreignUpdate
        }
        let revision = InteractiveStrokePresentationRevision(
            generation: update.generation,
            strokeEpoch: update.strokeEpoch,
            sequence: update.sequence
        )
        defer { finishUpdateSlotIfOwned(ownerID) }
        let result: InteractiveStrokePresentationRevision
        do {
            result = try await adoptCore(
                update,
                revision: revision,
                ownerID: ownerID,
                parameters: parameters
            )
        } catch {
            if error is CancellationError {
                cancelledUpdateCount &+= 1
            } else {
                failedUpdateCount &+= 1
            }
            do {
                try await settleAcknowledgement(
                    update,
                    ownerID: ownerID
                )
            } catch {
                pendingPreparedAcknowledgement =
                    PendingPreparedAcknowledgement(
                        acknowledgement: update.acknowledgement,
                        settlement: update.acknowledgementSettlement,
                        ownerID: ownerID
                    )
            }
            throw error
        }
        do {
            try await settleAcknowledgement(update, ownerID: ownerID)
            return result
        } catch {
            failedUpdateCount &+= 1
            pendingPreparedAcknowledgement = PendingPreparedAcknowledgement(
                acknowledgement: update.acknowledgement,
                settlement: update.acknowledgementSettlement,
                ownerID: ownerID
            )
            throw error
        }
    }

    func current(generation: UInt64) throws
        -> InteractiveStrokePresentationSnapshot?
    {
        guard let published, published.revision.generation == generation else {
            return nil
        }
        return published
    }

    func retire(
        strokeEpoch: DocumentPaintStrokePresentationEpoch
    ) async throws {
        strokeEpoch.retire()
        if updatingRevision?.strokeEpoch == strokeEpoch.identity {
            await withCheckedContinuation { continuation in
                retirementWaiters.append((strokeEpoch.identity, continuation))
                Task { await completionGate?.cacheRetirementDidWait() }
            }
        }
        try retireCompletedEpochRecordingFailure(strokeEpoch.identity)
    }

    private func retireCompletedEpoch(_ strokeEpoch: UUID) throws {
        precondition(updatingRevision?.strokeEpoch != strokeEpoch)
        if failureInjection?.consumeRetirementFailure() == true {
            throw InteractiveStrokePresentationCacheError
                .injectedRetirementFailure(strokeEpoch)
        }
        guard let state = generationState,
              state.strokeEpoch == strokeEpoch
        else {
            cancelledEpochs.remove(strokeEpoch)
            return
        }
        try state.authoritative.advanceGeneration()
        try state.prediction.advanceGeneration()
        generationState = nil
        if published?.revision.strokeEpoch == strokeEpoch { published = nil }
        cancelledEpochs.remove(strokeEpoch)
    }

    private func retireCompletedEpochRecordingFailure(
        _ strokeEpoch: UUID
    ) throws {
        do {
            try retireCompletedEpoch(strokeEpoch)
            if retirementFailure?.strokeEpoch == strokeEpoch {
                retirementFailure = nil
            }
        } catch {
            retirementFailure = (strokeEpoch, String(describing: error))
            retirementFailureCount &+= 1
            throw error
        }
    }

    func cancel(
        strokeEpoch: DocumentPaintStrokePresentationEpoch
    ) async throws {
        strokeEpoch.retire()
        cancelledEpochs.insert(strokeEpoch.identity)
        if updatingRevision?.strokeEpoch == strokeEpoch.identity {
            await withCheckedContinuation { continuation in
                retirementWaiters.append((strokeEpoch.identity, continuation))
                Task { await completionGate?.cacheRetirementDidWait() }
            }
        }
        try retireCompletedEpochRecordingFailure(strokeEpoch.identity)
    }

    func snapshot() -> InteractiveStrokePresentationCacheSnapshot {
        let storeSnapshot = store.snapshot()
        let totalPhysicalBytes = physicalResidentBytes(storeSnapshot)
        let activeSlots = (published == nil ? 0 : 1)
            + (updatingRevision == nil ? 0 : 1)
        let retirementState: InteractiveStrokePresentationCacheRetirementState
        if let retirementFailure {
            retirementState = .failed(
                strokeEpoch: retirementFailure.strokeEpoch
            )
        } else if let waiting = retirementWaiters.first {
            retirementState = .waiting(strokeEpoch: waiting.0)
        } else {
            retirementState = .idle
        }
        return InteractiveStrokePresentationCacheSnapshot(
            maximumUpdateSlotCount: Self.maximumUpdateSlotCount,
            activeUpdateSlotCount: activeSlots,
            updateSlotHighWater: updateSlotHighWater,
            residentBytes: storeSnapshot.residentByteCount,
            residentByteHighWater: totalPhysicalResidentByteHighWater,
            residentByteBudget: byteBudget,
            totalPhysicalResidentBytes: totalPhysicalBytes,
            totalPhysicalResidentByteHighWater:
                totalPhysicalResidentByteHighWater,
            provisionalBytes: storeSnapshot.provisionalByteCount,
            componentCoverageBytes: storeSnapshot.componentCoverageByteCount,
            backingBytes: storeSnapshot.backingByteCount,
            publishedRevision: published?.revision,
            submittedUpdateCount: submittedUpdateCount,
            completedUpdateCount: completedUpdateCount,
            failedUpdateCount: failedUpdateCount,
            cancelledUpdateCount: cancelledUpdateCount,
            acknowledgementSettlementCount: acknowledgementSettlementCount,
            activeStrokeEpochCount: generationState == nil ? 0 : 1,
            activeUpdateOwnerCount: updatingOwnerID == nil ? 0 : 1,
            retirementWaiterCount: retirementWaiters.count,
            retirementResumeCount: retirementResumeCount,
            rolledBackRoleCommitCount: rolledBackRoleCommitCount,
            retirementState: retirementState,
            retirementFailureCount: retirementFailureCount,
            retirementErrorDescription: retirementFailure?.description,
            pendingPreparedAcknowledgementCount:
                pendingPreparedAcknowledgement == nil ? 0 : 1,
            isIdle: generationState == nil
                && updatingOwnerID == nil
                && retirementWaiters.isEmpty
                && pendingPreparedAcknowledgement == nil
        )
    }

    func retryPendingPreparedAcknowledgement() async throws {
        guard let pendingPreparedAcknowledgement else { return }
        guard pendingPreparedAcknowledgement.settlement.beginFulfillment(
            ownerID: pendingPreparedAcknowledgement.ownerID
        ) else { return }
        do {
            try await pendingPreparedAcknowledgement.acknowledgement.fulfill()
        } catch {
            pendingPreparedAcknowledgement.settlement.failFulfillment(
                ownerID: pendingPreparedAcknowledgement.ownerID
            )
            await completionGate?.cacheAcknowledgementDidFail()
            throw error
        }
        guard pendingPreparedAcknowledgement.settlement.completeFulfillment(
            ownerID: pendingPreparedAcknowledgement.ownerID
        ) else { return }
        if self.pendingPreparedAcknowledgement?.ownerID
            == pendingPreparedAcknowledgement.ownerID
        {
            self.pendingPreparedAcknowledgement = nil
            acknowledgementSettlementCount &+= 1
        }
    }

    func waitBeforeRetirementRetry() async {
        await completionGate?.cacheRetirementDidFail()
    }

    func waitForLifecycleRetry(attempt: Int) async throws {
        if let completionGate {
            try await completionGate.waitForLifecycleRetry(attempt: attempt)
            return
        }
        let milliseconds = min(100, 1 << min(attempt, 7))
        try await ContinuousClock().sleep(
            for: .milliseconds(milliseconds)
        )
    }

    func terminallyAbandonFailedRetirement(
        strokeEpoch: DocumentPaintStrokePresentationEpoch
    ) {
        precondition(
            updatingOwnerID == nil
                && retirementWaiters.isEmpty
        )
        if generationState?.strokeEpoch == strokeEpoch.identity {
            generationState = nil
        }
        if published?.revision.strokeEpoch == strokeEpoch.identity {
            published = nil
        }
        cancelledEpochs.remove(strokeEpoch.identity)
        if retirementFailure?.strokeEpoch == strokeEpoch.identity {
            retirementFailure = nil
        }
        store = PaintTileStore(device: device, byteBudget: byteBudget)
    }

    func installFailureInjectionForTesting(
        _ failureInjection:
            InteractiveStrokePresentationCacheFailureInjection?
    ) {
        precondition(
            generationState == nil
                && updatingOwnerID == nil
                && retirementWaiters.isEmpty
        )
        self.failureInjection = failureInjection
    }

    private func adoptCore(
        _ update: DocumentPaintTransientCacheUpdate,
        revision: InteractiveStrokePresentationRevision,
        ownerID: UUID,
        parameters: InteractiveStrokeCompositeParameters
    ) async throws -> InteractiveStrokePresentationRevision {
        guard update.strokeEpoch == update.presentationEpoch.identity else {
            throw InteractiveStrokePresentationCacheError.foreignUpdate
        }
        guard !update.presentationEpoch.isRetired else {
            throw CancellationError()
        }
        guard parameters.opacity.isFinite,
              (0...1).contains(parameters.opacity)
        else { throw InteractiveStrokePresentationCacheError.foreignUpdate }
        guard updatingRevision == nil else {
            throw InteractiveStrokePresentationCacheError
                .updateSlotCapacityExceeded(
                    maximum: Self.maximumUpdateSlotCount
                )
        }
        if let published {
            guard revision.strokeEpoch == published.revision.strokeEpoch else {
                throw InteractiveStrokePresentationCacheError.foreignUpdate
            }
        }
        if let published, revision <= published.revision {
            throw InteractiveStrokePresentationCacheError.staleRevision(
                current: published.revision,
                proposed: revision
            )
        }
        let authoritativeSource = update.descriptor.authoritativeProvider
        let predictionSource = update.descriptor.predictionProvider
        guard authoritativeSource.layerID == update.layerID,
              predictionSource.layerID == update.layerID,
              authoritativeSource.generation == update.generation,
              predictionSource.generation == update.generation,
              authoritativeSource.pixelSize
                == update.canonicalIdentity.geometry.storagePixelSize,
              predictionSource.pixelSize == authoritativeSource.pixelSize
        else { throw InteractiveStrokePresentationCacheError.foreignUpdate }

        let state: GenerationState
        if let existing = generationState {
            guard existing.generation == update.generation,
                  existing.strokeEpoch == update.strokeEpoch,
                  existing.layerID == update.layerID,
                  existing.pixelSize == authoritativeSource.pixelSize
            else { throw InteractiveStrokePresentationCacheError.foreignUpdate }
            state = existing
        } else {
            state = GenerationState(
                store: store,
                generation: update.generation,
                strokeEpoch: update.strokeEpoch,
                layerID: update.layerID,
                pixelSize: authoritativeSource.pixelSize
            )
            generationState = state
        }

        updatingOwnerID = ownerID
        updatingRevision = revision
        updateSlotHighWater = max(
            updateSlotHighWater,
            (published == nil ? 0 : 1) + 1
        )

        let selectedSource = update.changedRole == .authoritative
            ? authoritativeSource : predictionSource
        let changedSet = Set(update.changedCoordinates)
        let sourceReferences = selectedSource.references.filter {
            changedSet.contains($0.coordinate)
        }
        guard sourceReferences.count == update.changedCoordinates.count else {
            throw InteractiveStrokePresentationCacheError.foreignUpdate
        }
        let modifiedCoordinates = sourceReferences.map(\.coordinate)
        let authoritativeNextCoordinates = nextCoordinates(
            existing: state.authoritative.references.map(\.coordinate),
            clearsExisting: update.clearedAuthoritativeSurface,
            modified: update.changedRole == .authoritative
                ? modifiedCoordinates : []
        )
        let predictionNextCoordinates = nextCoordinates(
            existing: state.prediction.references.map(\.coordinate),
            clearsExisting: update.clearedPredictionSurface,
            modified: update.changedRole == .prediction
                ? modifiedCoordinates : []
        )
        let (requiredTileCount, requiredTileCountOverflow) =
            authoritativeNextCoordinates.count.addingReportingOverflow(
                predictionNextCoordinates.count
            )
        guard !requiredTileCountOverflow,
              requiredTileCount <= maximumTileCount
        else {
            throw InteractiveStrokePresentationCacheError.tileCapacityExceeded(
                required: requiredTileCountOverflow ? .max : requiredTileCount,
                maximum: maximumTileCount
            )
        }
        let coverageBytes = DepositionComponentCoverage.residentByteCount(
            width: PaintTileDescriptor.side,
            height: PaintTileDescriptor.side
        )!
        let (bytesPerTile, bytesPerTileOverflow) = PaintTileDescriptor
            .residentByteCount.addingReportingOverflow(coverageBytes)
        let (requiredBytes, requiredBytesOverflow) = requiredTileCount
            .multipliedReportingOverflow(by: bytesPerTile)
        guard !bytesPerTileOverflow,
              !requiredBytesOverflow,
              requiredBytes <= byteBudget
        else {
            throw InteractiveStrokePresentationCacheError.tileCapacityExceeded(
                required: requiredTileCount,
                maximum: maximumTileCount
            )
        }
        let restrictedSource = try selectedSource.restrictingEntitlement(
            to: sourceReferences
        )
        let capture = try TiledRasterExactReferenceCapture(
            providers: [restrictedSource]
        )
        var sourceLease: TiledRasterExactReferenceLease?
        let authoritativeUpdate = destinationUpdate(
            role: .authoritative,
            surface: state.authoritative,
            clearsExisting: update.clearedAuthoritativeSurface,
            modified: update.changedRole == .authoritative
                ? modifiedCoordinates : []
        )
        let predictionUpdate = destinationUpdate(
            role: .prediction,
            surface: state.prediction,
            clearsExisting: update.clearedPredictionSurface,
            modified: update.changedRole == .prediction
                ? modifiedCoordinates : []
        )
        let destinationUpdates = [authoritativeUpdate, predictionUpdate]
            .compactMap { $0 }
        let currentStoreSnapshot = store.snapshot()
        let currentPhysicalBytes = physicalResidentBytes(currentStoreSnapshot)
        let provisionalBytesPerTarget = PaintTileDescriptor.residentByteCount
            + coverageBytes
        let additionalResidentColorBytes = destinationUpdates.reduce(into: 0) {
            bytes, destination in
            let existing = Set(destination.surface.references.map(\.coordinate))
            bytes += destination.targetCoordinates.reduce(into: 0) {
                if !existing.contains($1) {
                    $0 += PaintTileDescriptor.residentByteCount
                }
            }
        }
        let additionalPersistentZeroBytes =
            currentStoreSnapshot.persistentZeroAllocationBytes == 0
                && additionalResidentColorBytes > 0
            ? PaintTileDescriptor.residentByteCount : 0
        let provisionalTargetCount = destinationUpdates.reduce(into: 0) {
            $0 += $1.targetCoordinates.count
        }
        let (provisionalPlanBytes, provisionalPlanOverflow) =
            provisionalTargetCount.multipliedReportingOverflow(
                by: provisionalBytesPerTarget
            )
        let (withResidentColor, residentColorOverflow) = currentPhysicalBytes
            .addingReportingOverflow(additionalResidentColorBytes)
        let (withPersistentZero, persistentZeroOverflow) = withResidentColor
            .addingReportingOverflow(additionalPersistentZeroBytes)
        let (requiredPhysicalBytes, requiredPhysicalOverflow) =
            withPersistentZero.addingReportingOverflow(provisionalPlanBytes)
        guard !provisionalPlanOverflow,
              !residentColorOverflow,
              !persistentZeroOverflow,
              !requiredPhysicalOverflow,
              requiredPhysicalBytes <= byteBudget
        else {
            throw InteractiveStrokePresentationCacheError
                .physicalCapacityExceeded(
                    requested: provisionalPlanOverflow
                        || residentColorOverflow || persistentZeroOverflow
                        || requiredPhysicalOverflow
                        ? .max : requiredPhysicalBytes,
                    current: currentPhysicalBytes,
                    highWater: totalPhysicalResidentByteHighWater,
                    maximum: byteBudget
                )
        }
        totalPhysicalResidentByteHighWater = max(
            totalPhysicalResidentByteHighWater,
            requiredPhysicalBytes
        )
        defer {
            for destinationUpdate in destinationUpdates.reversed() {
                destinationUpdate.settle()
            }
            _ = try? store.applyMemoryPressure(
                targetResidentBytes: byteBudget
            )
            try? sourceLease?.returnLease()
            capture.close()
        }

        if !sourceReferences.isEmpty {
            sourceLease = try restrictedSource.leaseExactReferences(
                sourceReferences,
                using: capture,
                pinReasons: [.inFlight]
            )
        }
        for destinationUpdate in destinationUpdates {
            try destinationUpdate.reserve()
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw InteractiveStrokePresentationCacheError
                .commandBufferUnavailable
        }
        for destinationUpdate in destinationUpdates {
            guard let provisional = destinationUpdate.provisional else {
                continue
            }
            let modified = Set(destinationUpdate.modifiedCoordinates)
            try encodeCopy(
                sourceBindings: (sourceLease?.bindings ?? []).filter {
                    modified.contains($0.descriptor.coordinate)
                },
                targetCoordinates: destinationUpdate.targetCoordinates,
                provisional: provisional,
                commandBuffer: commandBuffer
            )
        }
        recordTrace(
            .transientCacheSubmitted,
            update: update,
            residentBytes: store.snapshot().residentByteCount
        )
        let completionSignal = commit(commandBuffer)
        submittedUpdateCount &+= 1
        await completionGate?.cacheCommandDidSubmit()
        let completion = await completionSignal.value()
        await completionGate?.waitAfterGPUCompletion()
        guard completion.succeeded else {
            throw InteractiveStrokePresentationCacheError.commandFailed(
                completion.message ?? "transient cache command failed"
            )
        }
        try Task.checkCancellation()
        guard !cancelledEpochs.contains(update.strokeEpoch) else {
            throw CancellationError()
        }

        let publicationOrder = destinationUpdates.sorted(by: {
            $0.modifiedCoordinates.isEmpty && !$1.modifiedCoordinates.isEmpty
        })
        let next: InteractiveStrokePresentationSnapshot
        do {
            for destinationUpdate in publicationOrder {
                if failureInjection?.sequence == update.sequence,
                   failureInjection?.role == destinationUpdate.role
                {
                    throw InteractiveStrokePresentationCacheError
                        .injectedRolePreparationFailure(
                            destinationUpdate.role
                        )
                }
                try destinationUpdate.commit()
            }
            next = InteractiveStrokePresentationSnapshot(
                revision: revision,
                canonicalIdentity: update.canonicalIdentity,
                authoritative:
                    try state.authoritative.makeExactReferenceProvider(),
                prediction: try state.prediction.makeExactReferenceProvider(),
                parameters: parameters
            )
        } catch {
            do {
                for destinationUpdate in publicationOrder.reversed()
                where destinationUpdate.wasCommitted
                {
                    try destinationUpdate.rollback()
                    rolledBackRoleCommitCount &+= 1
                }
            } catch let rollbackError {
                throw InteractiveStrokePresentationCacheError.commandFailed(
                    "transient cache atomic rollback failed: \(rollbackError)"
                )
            }
            throw error
        }
        for destinationUpdate in publicationOrder {
            destinationUpdate.finalize()
        }
        for destinationUpdate in destinationUpdates.reversed() {
            destinationUpdate.settle()
        }
        _ = try store.applyMemoryPressure(targetResidentBytes: byteBudget)
        published = next
        completedUpdateCount &+= 1
        recordTrace(
            .transientCacheCompleted,
            update: update,
            residentBytes: store.snapshot().residentByteCount
        )
        return revision
    }

    private func nextCoordinates(
        existing: [PaintTileCoordinate],
        clearsExisting: Bool,
        modified: [PaintTileCoordinate]
    ) -> [PaintTileCoordinate] {
        var coordinates = clearsExisting ? [] : existing
        coordinates.append(contentsOf: modified)
        return sortedUnique(coordinates)
    }

    private func destinationUpdate(
        role: StrokePrivateSurfaceLayer,
        surface: TiledRasterSurface,
        clearsExisting: Bool,
        modified: [PaintTileCoordinate]
    ) -> DestinationUpdate? {
        var targets = modified
        if clearsExisting {
            targets.append(contentsOf: surface.references.map(\.coordinate))
        }
        targets = sortedUnique(targets)
        guard !targets.isEmpty else { return nil }
        return DestinationUpdate(
            role: role,
            surface: surface,
            targetCoordinates: targets,
            modifiedCoordinates: modified
        )
    }

    private func sortedUnique(
        _ coordinates: [PaintTileCoordinate]
    ) -> [PaintTileCoordinate] {
        coordinates.sorted().reduce(into: []) {
            if $0.last != $1 { $0.append($1) }
        }
    }

    private func physicalResidentBytes(
        _ snapshot: PaintTileStoreSnapshot
    ) -> Int {
        snapshot.residentByteCount
            + snapshot.provisionalByteCount
            + snapshot.persistentZeroAllocationBytes
    }

    private func encodeCopy(
        sourceBindings: [PaintTileBinding],
        targetCoordinates: [PaintTileCoordinate],
        provisional: PaintTileProvisionalReservation,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        let sources = Dictionary(uniqueKeysWithValues: sourceBindings.map {
            ($0.descriptor.coordinate, $0.texture)
        })
        if !sources.isEmpty {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw InteractiveStrokePresentationCacheError
                    .blitEncoderUnavailable
            }
            for index in 0..<provisional.count {
                let candidate = provisional[index]
                guard let source = sources[candidate.descriptor.coordinate]
                else { continue }
                blit.copy(
                    from: source,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(
                        width: PaintTileDescriptor.side,
                        height: PaintTileDescriptor.side,
                        depth: 1
                    ),
                    to: candidate.candidateTexture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
            blit.endEncoding()
        }
        for index in 0..<provisional.count {
            let candidate = provisional[index]
            let pass = MTLRenderPassDescriptor()
            let colorIsClear = sources[candidate.descriptor.coordinate] == nil
            if colorIsClear {
                pass.colorAttachments[0].texture = candidate.candidateTexture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColorMake(
                    0, 0, 0, 0
                )
            }
            // These surfaces are presentation-only: they never continue
            // deposition. Initialize their private accumulation companion
            // deterministically instead of retaining undefined GPU memory.
            let coverageAttachment = colorIsClear ? 1 : 0
            pass.colorAttachments[coverageAttachment].texture =
                candidate.candidateComponentCoverageTexture
            pass.colorAttachments[coverageAttachment].loadAction = .clear
            pass.colorAttachments[coverageAttachment].storeAction = .store
            pass.colorAttachments[coverageAttachment].clearColor =
                MTLClearColorMake(0, 0, 0, 0)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: pass
            ) else {
                throw InteractiveStrokePresentationCacheError
                    .clearEncoderUnavailable
            }
            encoder.endEncoding()
        }
        precondition(provisional.count == targetCoordinates.count)
    }

    private func commit(
        _ commandBuffer: any MTLCommandBuffer
    ) -> GPUCompletionSignal {
        let signal = GPUCompletionSignal()
        commandBuffer.addCompletedHandler { completed in
            signal.finish(GPUCompletion(
                succeeded: completed.status == .completed,
                message: completed.error?.localizedDescription
            ))
        }
        commandBuffer.commit()
        return signal
    }

    private func settleAcknowledgement(
        _ update: DocumentPaintTransientCacheUpdate,
        ownerID: UUID
    ) async throws {
        guard update.acknowledgementSettlement.beginFulfillment(
            ownerID: ownerID
        ) else {
            return
        }
        do {
            try await update.acknowledgement.fulfill()
        } catch {
            update.acknowledgementSettlement.failFulfillment(ownerID: ownerID)
            await completionGate?.cacheAcknowledgementDidFail()
            throw error
        }
        guard update.acknowledgementSettlement.completeFulfillment(
            ownerID: ownerID
        ) else { return }
        acknowledgementSettlementCount &+= 1
    }

    private func finishUpdateSlotIfOwned(
        _ ownerID: UUID
    ) {
        guard updatingOwnerID == ownerID,
              let revision = updatingRevision
        else { return }
        updatingOwnerID = nil
        updatingRevision = nil
        var resumed: [CheckedContinuation<Void, Never>] = []
        retirementWaiters.removeAll { waiter in
            guard waiter.0 == revision.strokeEpoch else { return false }
            resumed.append(waiter.1)
            return true
        }
        retirementResumeCount &+= UInt64(resumed.count)
        for continuation in resumed { continuation.resume() }
    }

    private func recordTrace(
        _ stage: InteractiveBrushTraceStage,
        update: DocumentPaintTransientCacheUpdate,
        residentBytes: Int
    ) {
        for identity in update.traceIdentities {
            traceRecorder?.record(
                stage: stage,
                lineage: InteractiveBrushInputTrace(
                    identity: identity,
                    eventReceiptMonotonicNanoseconds: nil
                ),
                dirtyTileCount: update.changedCoordinates.count,
                residentBytes: residentBytes,
                activeOwnershipCount:
                    (published == nil ? 0 : 1)
                        + (updatingRevision == nil ? 0 : 1)
            )
        }
    }
}

/// Strongly owns the exact cache handoff until acknowledgement settlement.
/// The UI owner participates only in terminal signalling; when it is already
/// gone, this operation also retires the epoch it just terminally adopted.
@MainActor
enum InteractiveStrokeCacheAdoptionOperation {
    static func start(
        cache: InteractiveStrokePresentationCache,
        update: DocumentPaintTransientCacheUpdate,
        parameters: InteractiveStrokeCompositeParameters,
        terminal: @escaping @MainActor @Sendable ((any Error)?) -> Bool,
        lifecycleTerminal: @escaping @Sendable (
            InteractiveStrokePresentationCacheSnapshot
        ) -> Void = { _ in }
    ) -> Task<Void, Never> {
        Task { @MainActor [
            cache,
            update,
            parameters,
            terminal,
            lifecycleTerminal,
        ] in
            let terminalError: (any Error)?
            do {
                _ = try await cache.adopt(update, parameters: parameters)
                terminalError = nil
            } catch {
                terminalError = error
            }
            guard !terminal(terminalError) else { return }
            InteractiveStrokeCacheLifecycleCoordinator.shared.retain(
                cache: cache,
                update: update,
                lifecycleTerminal: lifecycleTerminal
            )
        }
    }
}

/// Durable event-driven owner for cache obligations whose UI owner vanished.
/// Entries are removed only after ACK success plus epoch retirement.
@MainActor
final class InteractiveStrokeCacheLifecycleCoordinator {
    static let shared = InteractiveStrokeCacheLifecycleCoordinator()

    private struct Entry {
        let cache: InteractiveStrokePresentationCache
        let update: DocumentPaintTransientCacheUpdate
        let lifecycleTerminal: @Sendable (
            InteractiveStrokePresentationCacheSnapshot
        ) -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private var active: Set<UUID> = []
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var retryAttemptCount: [UUID: Int] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]

    func retain(
        cache: InteractiveStrokePresentationCache,
        update: DocumentPaintTransientCacheUpdate,
        lifecycleTerminal: @escaping @Sendable (
            InteractiveStrokePresentationCacheSnapshot
        ) -> Void
    ) {
        let identity = update.presentationEpoch.identity
        precondition(entries[identity] == nil)
        entries[identity] = Entry(
            cache: cache,
            update: update,
            lifecycleTerminal: lifecycleTerminal
        )
        retryAttemptCount[identity] = 0
        scheduleAutomaticRetry(identity)
    }

    func advancePendingLifecycles() async {
        await waitForQuiescence()
        for identity in entries.keys { advance(identity) }
        await waitForQuiescence()
    }

    private func advance(_ identity: UUID) {
        guard entries[identity] != nil, active.insert(identity).inserted else {
            return
        }
        Task { @MainActor [weak self] in
            await self?.attempt(identity)
        }
    }

    private func attempt(_ identity: UUID) async {
        guard let entry = entries[identity] else {
            finishAttempt(identity)
            return
        }
        do {
            if (await entry.cache.snapshot())
                .pendingPreparedAcknowledgementCount > 0
            {
                try await entry.cache.retryPendingPreparedAcknowledgement()
            }
            guard (await entry.cache.snapshot())
                    .pendingPreparedAcknowledgementCount == 0
            else {
                finishAttempt(identity)
                return
            }
            try await entry.cache.retire(
                strokeEpoch: entry.update.presentationEpoch
            )
            let snapshot = await entry.cache.snapshot()
            retryTasks.removeValue(forKey: identity)?.cancel()
            entries.removeValue(forKey: identity)
            retryAttemptCount.removeValue(forKey: identity)
            entry.lifecycleTerminal(snapshot)
            finishAttempt(identity)
        } catch {
            await entry.cache.waitBeforeRetirementRetry()
            finishAttempt(identity)
            scheduleAutomaticRetry(identity)
        }
    }

    private func scheduleAutomaticRetry(_ identity: UUID) {
        guard let entry = entries[identity], retryTasks[identity] == nil else {
            return
        }
        let attempt = retryAttemptCount[identity, default: 0]
        retryAttemptCount[identity] = attempt + 1
        retryTasks[identity] = Task { @MainActor [weak self, entry] in
            do {
                try await entry.cache.waitForLifecycleRetry(attempt: attempt)
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.entries[identity] != nil
            else { return }
            self.retryTasks[identity] = nil
            self.advance(identity)
        }
    }

    func cancelRetainedLifecycle(_ identity: UUID) async {
        guard let entry = entries.removeValue(forKey: identity) else { return }
        retryTasks.removeValue(forKey: identity)?.cancel()
        retryAttemptCount.removeValue(forKey: identity)
        active.remove(identity)
        await entry.cache.terminallyAbandonFailedRetirement(
            strokeEpoch: entry.update.presentationEpoch
        )
        entry.lifecycleTerminal(await entry.cache.snapshot())
        if active.isEmpty {
            let waiters = quiescenceWaiters
            quiescenceWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func waitForQuiescence() async {
        guard !active.isEmpty else { return }
        await withCheckedContinuation { quiescenceWaiters.append($0) }
    }

    private func finishAttempt(_ identity: UUID) {
        active.remove(identity)
        guard active.isEmpty else { return }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
