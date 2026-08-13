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
    let activeExternalLeaseCount: Int
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
        let strokeEpoch: DocumentPaintStrokePresentationEpoch
        let layerID: UUID
        let pixelSize: PixelSize
        let authoritative: TiledRasterSurface
        let prediction: TiledRasterSurface

        init(
            store: PaintTileStore,
            generation: UInt64,
            strokeEpoch: DocumentPaintStrokePresentationEpoch,
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
    private let store: PaintTileStore
    private let byteBudget: Int
    private let maximumTileCount: Int
    private var completionGate:
        (any InteractiveStrokePresentationCacheCompletionGating)?
    private var failureInjection:
        InteractiveStrokePresentationCacheFailureInjection?
    private let traceRecorder: InteractiveBrushTraceRecorder?
    private var generationState: GenerationState?
    private var published: InteractiveStrokePresentationSnapshot?
    private var updatingOwnerID: UUID?
    private var updatingRevision: InteractiveStrokePresentationRevision?
    private var cancelledEpochs:
        [UUID: DocumentPaintStrokePresentationEpoch] = [:]
    private var retiringEpochs:
        [UUID: DocumentPaintStrokePresentationEpoch] = [:]
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
        store = PaintTileStore(
            device: device,
            byteBudget: byteBudget,
            transferByteCapacity: byteBudget
        )
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
        guard update.descriptor.authenticates(
            presentationEpoch: update.presentationEpoch
        ), update.strokeEpoch == update.descriptor.authenticatedStrokeEpoch
        else { throw InteractiveStrokePresentationCacheError.foreignUpdate }
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
            strokeEpoch: update.descriptor.authenticatedStrokeEpoch,
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
        try authenticateTerminalEpoch(strokeEpoch)
        retiringEpochs[strokeEpoch.identity] = strokeEpoch
        strokeEpoch.retire()
        if updatingRevision?.strokeEpoch == strokeEpoch.identity {
            await withCheckedContinuation { continuation in
                retirementWaiters.append((strokeEpoch.identity, continuation))
                Task { await completionGate?.cacheRetirementDidWait() }
            }
        }
        try retireCompletedEpochRecordingFailure(strokeEpoch)
    }

    private func authenticateTerminalEpoch(
        _ strokeEpoch: DocumentPaintStrokePresentationEpoch
    ) throws {
        if let state = generationState,
           state.strokeEpoch.identity == strokeEpoch.identity,
           state.strokeEpoch !== strokeEpoch
        {
            throw InteractiveStrokePresentationCacheError.foreignUpdate
        }
        if let cancelled = cancelledEpochs[strokeEpoch.identity],
           cancelled !== strokeEpoch
        {
            throw InteractiveStrokePresentationCacheError.foreignUpdate
        }
        if let retiring = retiringEpochs[strokeEpoch.identity],
           retiring !== strokeEpoch
        {
            throw InteractiveStrokePresentationCacheError.foreignUpdate
        }
    }

    private func retireCompletedEpoch(
        _ strokeEpoch: DocumentPaintStrokePresentationEpoch
    ) throws {
        let identity = strokeEpoch.identity
        precondition(updatingRevision?.strokeEpoch != identity)
        try authenticateTerminalEpoch(strokeEpoch)
        if failureInjection?.consumeRetirementFailure() == true {
            throw InteractiveStrokePresentationCacheError
                .injectedRetirementFailure(identity)
        }
        guard let state = generationState,
              state.strokeEpoch === strokeEpoch
        else {
            if cancelledEpochs[identity] === strokeEpoch {
                cancelledEpochs.removeValue(forKey: identity)
            }
            return
        }
        try store.retireAtomically(
            authoritativeSurfaceID: state.authoritative.surfaceID,
            predictionSurfaceID: state.prediction.surfaceID,
            generation: state.generation
        )
        generationState = nil
        if published?.revision.strokeEpoch == identity { published = nil }
        cancelledEpochs.removeValue(forKey: identity)
    }

    private func retireCompletedEpochRecordingFailure(
        _ strokeEpoch: DocumentPaintStrokePresentationEpoch
    ) throws {
        let identity = strokeEpoch.identity
        do {
            try retireCompletedEpoch(strokeEpoch)
            if retirementFailure?.strokeEpoch == identity {
                retirementFailure = nil
            }
            reapTerminalEpochIfReclaimed(strokeEpoch)
        } catch {
            retirementFailure = (identity, String(describing: error))
            retirementFailureCount &+= 1
            throw error
        }
    }

    func cancel(
        strokeEpoch: DocumentPaintStrokePresentationEpoch
    ) async throws {
        try authenticateTerminalEpoch(strokeEpoch)
        retiringEpochs[strokeEpoch.identity] = strokeEpoch
        strokeEpoch.retire()
        cancelledEpochs[strokeEpoch.identity] = strokeEpoch
        if updatingRevision?.strokeEpoch == strokeEpoch.identity {
            await withCheckedContinuation { continuation in
                retirementWaiters.append((strokeEpoch.identity, continuation))
                Task { await completionGate?.cacheRetirementDidWait() }
            }
        }
        try retireCompletedEpochRecordingFailure(strokeEpoch)
    }

    func snapshot() -> InteractiveStrokePresentationCacheSnapshot {
        store.releasePersistentZeroSourceIfUnowned()
        let storeSnapshot = store.snapshot()
        reapTerminalEpochsIfReclaimed(storeSnapshot)
        let totalPhysicalBytes = physicalResidentBytes(storeSnapshot)
        observePhysicalHighWater(storeSnapshot)
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
            activeExternalLeaseCount: storeSnapshot.activeLeaseCount,
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
                && cancelledEpochs.isEmpty
                && retiringEpochs.isEmpty
                && retirementFailure == nil
                && storeSnapshot.activeLeaseCount == 0
                && totalPhysicalBytes == 0
        )
    }

    private func reapTerminalEpochIfReclaimed(
        _ strokeEpoch: DocumentPaintStrokePresentationEpoch
    ) {
        store.releasePersistentZeroSourceIfUnowned()
        let storeSnapshot = store.snapshot()
        guard physicalResidentBytes(storeSnapshot) == 0,
              storeSnapshot.activeLeaseCount == 0,
              retirementFailure?.strokeEpoch != strokeEpoch.identity
        else { return }
        if cancelledEpochs[strokeEpoch.identity] === strokeEpoch {
            cancelledEpochs.removeValue(forKey: strokeEpoch.identity)
        }
        if retiringEpochs[strokeEpoch.identity] === strokeEpoch {
            retiringEpochs.removeValue(forKey: strokeEpoch.identity)
        }
    }

    private func reapTerminalEpochsIfReclaimed(
        _ storeSnapshot: PaintTileStoreSnapshot
    ) {
        guard physicalResidentBytes(storeSnapshot) == 0,
              storeSnapshot.activeLeaseCount == 0,
              retirementFailure == nil
        else { return }
        for (identity, epoch) in retiringEpochs {
            if cancelledEpochs[identity] === epoch {
                cancelledEpochs.removeValue(forKey: identity)
            }
        }
        retiringEpochs.removeAll()
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

    func settleRejectedUpdateAcknowledgement(
        _ update: DocumentPaintTransientCacheUpdate
    ) async throws {
        guard pendingPreparedAcknowledgement == nil else {
            throw InteractiveStrokePresentationCacheError.foreignUpdate
        }
        let ownerID = UUID()
        guard update.acknowledgementSettlement.claimOwnership(
            ownerID: ownerID
        ) else {
            throw InteractiveStrokePresentationCacheError.foreignUpdate
        }
        do {
            try await settleAcknowledgement(update, ownerID: ownerID)
        } catch {
            pendingPreparedAcknowledgement = PendingPreparedAcknowledgement(
                acknowledgement: update.acknowledgement,
                settlement: update.acknowledgementSettlement,
                ownerID: ownerID
            )
            throw error
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

    #if DEBUG
    func installCompletionGateForTesting(
        _ completionGate:
            (any InteractiveStrokePresentationCacheCompletionGating)?
    ) {
        precondition(
            generationState == nil
                && published == nil
                && updatingOwnerID == nil
                && pendingPreparedAcknowledgement == nil
                && retirementWaiters.isEmpty
        )
        self.completionGate = completionGate
    }
    #endif

    private func adoptCore(
        _ update: DocumentPaintTransientCacheUpdate,
        revision: InteractiveStrokePresentationRevision,
        ownerID: UUID,
        parameters: InteractiveStrokeCompositeParameters
    ) async throws -> InteractiveStrokePresentationRevision {
        guard update.descriptor.authenticates(
            presentationEpoch: update.presentationEpoch
        ), update.strokeEpoch == update.descriptor.authenticatedStrokeEpoch
        else {
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
            guard revision.strokeEpoch == published.revision.strokeEpoch,
                  generationState?.strokeEpoch
                    === update.descriptor.authenticatedPresentationEpoch
            else {
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
                  existing.strokeEpoch
                    === update.descriptor.authenticatedPresentationEpoch,
                  existing.layerID == update.layerID,
                  existing.pixelSize == authoritativeSource.pixelSize
            else { throw InteractiveStrokePresentationCacheError.foreignUpdate }
            state = existing
        } else {
            state = GenerationState(
                store: store,
                generation: update.generation,
                strokeEpoch:
                    update.descriptor.authenticatedPresentationEpoch,
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
        if let cancelled = cancelledEpochs[update.strokeEpoch] {
            guard cancelled === update.descriptor.authenticatedPresentationEpoch
            else {
                throw InteractiveStrokePresentationCacheError.foreignUpdate
            }
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
        checkedPhysicalSum([
            snapshot.residentByteCount,
            snapshot.provisionalByteCount,
            snapshot.persistentZeroAllocationBytes,
            snapshot.backingByteCount,
        ])
    }

    private func observePhysicalHighWater(
        _ snapshot: PaintTileStoreSnapshot
    ) {
        totalPhysicalResidentByteHighWater = max(
            totalPhysicalResidentByteHighWater,
            physicalResidentBytes(snapshot),
            snapshot.transferPeakTrackedByteHighWater
        )
    }

    private func checkedPhysicalSum(_ values: [Int]) -> Int {
        var result = 0
        for value in values {
            let (next, overflow) = result.addingReportingOverflow(value)
            if overflow { return .max }
            result = next
        }
        return result
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
        lifecycleTerminal: @escaping @MainActor @Sendable (
            InteractiveStrokePresentationCacheSnapshot
        ) -> Void = { _ in }
    ) -> Task<Void, Never> {
        InteractiveStrokeCacheLifecycleCoordinator.shared.enqueueHandoff(
            cache: cache,
            update: update,
            parameters: parameters,
            terminal: terminal,
            lifecycleTerminal: lifecycleTerminal
        )
    }
}

/// Durable event-driven owner for every cache ACK/retirement obligation.
/// UI lifetime may change the requested terminal action but never owns credit.
@MainActor
final class InteractiveStrokeCacheLifecycleCoordinator {
    static let shared = InteractiveStrokeCacheLifecycleCoordinator()

    private enum Intent: Int {
        case acknowledgementOnly
        case retire
        case cancel
    }

    private enum DriverPhase {
        case handoff
        case acknowledgement
        case retirement
    }

    @MainActor
    private final class HandoffCompletion {
        var isFinished = false
        var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isFinished else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func finish() {
            guard !isFinished else { return }
            isFinished = true
            let waiters = waiters
            self.waiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private final class Handoff {
        let id = UUID()
        let update: DocumentPaintTransientCacheUpdate
        let parameters: InteractiveStrokeCompositeParameters
        let terminal: @MainActor @Sendable ((any Error)?) -> Bool
        let completion: HandoffCompletion
        var adoptionFinished = false
        var terminalError: (any Error)?

        init(
            update: DocumentPaintTransientCacheUpdate,
            parameters: InteractiveStrokeCompositeParameters,
            terminal: @escaping @MainActor @Sendable ((any Error)?) -> Bool,
            completion: HandoffCompletion
        ) {
            self.update = update
            self.parameters = parameters
            self.terminal = terminal
            self.completion = completion
        }
    }

    private final class Entry {
        let entryID = UUID()
        let cache: InteractiveStrokePresentationCache
        let strokeEpoch: DocumentPaintStrokePresentationEpoch
        var intent: Intent
        var handoffs: [Handoff] = []
        var handoffLifecycleTerminal: (@MainActor @Sendable (
            InteractiveStrokePresentationCacheSnapshot
        ) -> Void)?
        var terminalActionLifecycleTerminal: (@MainActor @Sendable (
            InteractiveStrokePresentationCacheSnapshot
        ) -> Void)?
        var failureTerminal: (@MainActor @Sendable (any Error) -> Void)?
        var didReportRetirementFailure = false
        var driverID: UUID?
        var driverTask: Task<Void, Never>?
        var retryTaskID: UUID?
        var retryTask: Task<Void, Never>?
        var retryAttemptCount = 0
        var completedHandoffCount: UInt64 = 0

        init(
            cache: InteractiveStrokePresentationCache,
            strokeEpoch: DocumentPaintStrokePresentationEpoch,
            intent: Intent,
            handoffLifecycleTerminal: (@MainActor @Sendable (
                InteractiveStrokePresentationCacheSnapshot
            ) -> Void)?,
            failureTerminal:
                (@MainActor @Sendable (any Error) -> Void)? = nil
        ) {
            self.cache = cache
            self.strokeEpoch = strokeEpoch
            self.intent = intent
            self.handoffLifecycleTerminal = handoffLifecycleTerminal
            self.failureTerminal = failureTerminal
        }
    }

    private var entries: [UUID: Entry] = [:]
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var lifecycleWaiters:
        [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var acknowledgementWaiters:
        [UUID: [(UInt64, CheckedContinuation<Void, Never>)]] = [:]
    /// The presentation cache has one affine prepared-ACK slot. Epoch-local
    /// queues therefore share one cache-wide owner until that epoch has also
    /// completed retirement; a later epoch must never mistake the earlier
    /// epoch's pending ACK for its own handoff obligation.
    private var cacheOwnerEntryIdentities: [ObjectIdentifier: UUID] = [:]
    private var cacheWaitingEntryIdentities:
        [ObjectIdentifier: [UUID]] = [:]

    func enqueueHandoff(
        cache: InteractiveStrokePresentationCache,
        update: DocumentPaintTransientCacheUpdate,
        parameters: InteractiveStrokeCompositeParameters,
        terminal: @escaping @MainActor @Sendable ((any Error)?) -> Bool,
        lifecycleTerminal: @escaping @MainActor @Sendable (
            InteractiveStrokePresentationCacheSnapshot
        ) -> Void
    ) -> Task<Void, Never> {
        let authenticatedEpoch =
            update.descriptor.authenticatedPresentationEpoch
        let authentic = update.descriptor.authenticates(
            presentationEpoch: update.presentationEpoch
        ) && update.strokeEpoch == update.descriptor.authenticatedStrokeEpoch
        let identity = authenticatedEpoch.identity
        let entry: Entry
        if let current = entries[identity] {
            precondition(current.cache === cache)
            precondition(current.strokeEpoch === authenticatedEpoch)
            entry = current
        } else {
            entry = Entry(
                cache: cache,
                strokeEpoch: authenticatedEpoch,
                intent: authenticatedEpoch.isRetired
                    ? .cancel : .acknowledgementOnly,
                handoffLifecycleTerminal: lifecycleTerminal
            )
            entries[identity] = entry
        }
        entry.handoffLifecycleTerminal = lifecycleTerminal
        let completion = HandoffCompletion()
        entry.handoffs.append(Handoff(
            update: update,
            parameters: parameters,
            terminal: { error in
                terminal(authentic ? error :
                    InteractiveStrokePresentationCacheError.foreignUpdate)
            },
            completion: completion
        ))
        startDriverIfPossible(entry)
        return Task { @MainActor in await completion.wait() }
    }

    func requestCancellation(
        cache: InteractiveStrokePresentationCache,
        strokeEpoch: DocumentPaintStrokePresentationEpoch,
        lifecycleTerminal: (@MainActor @Sendable (
            InteractiveStrokePresentationCacheSnapshot
        ) -> Void)? = nil,
        failureTerminal:
            (@MainActor @Sendable (any Error) -> Void)? = nil
    ) {
        requestTerminalAction(
            cache: cache,
            strokeEpoch: strokeEpoch,
            intent: .cancel,
            lifecycleTerminal: lifecycleTerminal,
            failureTerminal: failureTerminal
        )
    }

    func requestRetirement(
        cache: InteractiveStrokePresentationCache,
        strokeEpoch: DocumentPaintStrokePresentationEpoch,
        lifecycleTerminal: (@MainActor @Sendable (
            InteractiveStrokePresentationCacheSnapshot
        ) -> Void)? = nil,
        failureTerminal:
            (@MainActor @Sendable (any Error) -> Void)? = nil
    ) {
        requestTerminalAction(
            cache: cache,
            strokeEpoch: strokeEpoch,
            intent: .retire,
            lifecycleTerminal: lifecycleTerminal,
            failureTerminal: failureTerminal
        )
    }

    private func requestTerminalAction(
        cache: InteractiveStrokePresentationCache,
        strokeEpoch: DocumentPaintStrokePresentationEpoch,
        intent: Intent,
        lifecycleTerminal: (@MainActor @Sendable (
            InteractiveStrokePresentationCacheSnapshot
        ) -> Void)?,
        failureTerminal:
            (@MainActor @Sendable (any Error) -> Void)?
    ) {
        let identity = strokeEpoch.identity
        let entry: Entry
        if let current = entries[identity] {
            precondition(current.cache === cache)
            precondition(current.strokeEpoch === strokeEpoch)
            if let lifecycleTerminal {
                current.handoffLifecycleTerminal = nil
                current.terminalActionLifecycleTerminal = lifecycleTerminal
            }
            if current.failureTerminal == nil {
                current.failureTerminal = failureTerminal
            }
            entry = current
        } else {
            entry = Entry(
                cache: cache,
                strokeEpoch: strokeEpoch,
                intent: intent,
                handoffLifecycleTerminal: nil,
                failureTerminal: failureTerminal
            )
            entry.terminalActionLifecycleTerminal = lifecycleTerminal
            entries[identity] = entry
        }
        upgrade(entry, to: intent)
        // An intent upgrade is consumed by the already scheduled bounded
        // lifecycle turn. Replacing a suspended retry before its cancellation
        // handler unwinds can otherwise create two physical waiters even
        // though Entry exposes only one task field.
        if entry.retryTask == nil { startDriverIfPossible(entry) }
    }

    func advancePendingLifecycles() async {
        await waitForQuiescence()
        for entry in entries.values {
            if entry.retryTask == nil { startDriverIfPossible(entry) }
        }
        await waitForQuiescence()
    }

    private func startDriverIfPossible(_ entry: Entry) {
        guard entry.driverID == nil,
              entry.retryTask == nil,
              entries[entry.strokeEpoch.identity] === entry
        else { return }
        let cacheIdentity = ObjectIdentifier(entry.cache)
        if let ownerIdentity = cacheOwnerEntryIdentities[cacheIdentity] {
            guard ownerIdentity == entry.strokeEpoch.identity else {
                appendCacheWaiterIfNeeded(
                    entry.strokeEpoch.identity,
                    cacheIdentity: cacheIdentity
                )
                return
            }
        } else {
            var waiters = cacheWaitingEntryIdentities[cacheIdentity] ?? []
            while let first = waiters.first,
                  entries[first] == nil
            {
                waiters.removeFirst()
            }
            if let first = waiters.first,
               first != entry.strokeEpoch.identity
            {
                cacheWaitingEntryIdentities[cacheIdentity] = waiters
                appendCacheWaiterIfNeeded(
                    entry.strokeEpoch.identity,
                    cacheIdentity: cacheIdentity
                )
                return
            }
            if waiters.first == entry.strokeEpoch.identity {
                waiters.removeFirst()
            }
            cacheWaitingEntryIdentities[cacheIdentity] = waiters.isEmpty
                ? nil : waiters
            cacheOwnerEntryIdentities[cacheIdentity] =
                entry.strokeEpoch.identity
        }
        let driverID = UUID()
        entry.driverID = driverID
        entry.driverTask = Task { @MainActor [weak self, entry] in
            await self?.drive(entry, driverID: driverID)
        }
    }

    private func drive(_ entry: Entry, driverID: UUID) async {
        var phase = DriverPhase.handoff
        do {
            if let handoff = entry.handoffs.first {
                let authentic = handoff.update.descriptor.authenticates(
                    presentationEpoch: handoff.update.presentationEpoch
                ) && handoff.update.strokeEpoch
                    == handoff.update.descriptor.authenticatedStrokeEpoch
                let didFinishAdoption = !handoff.adoptionFinished
                if didFinishAdoption {
                    do {
                        if authentic {
                            _ = try await entry.cache.adopt(
                                handoff.update,
                                parameters: handoff.parameters
                            )
                        } else {
                            try await entry.cache
                                .settleRejectedUpdateAcknowledgement(
                                    handoff.update
                                )
                            handoff.terminalError =
                                InteractiveStrokePresentationCacheError
                                    .foreignUpdate
                        }
                    } catch {
                        handoff.terminalError = error
                    }
                    handoff.adoptionFinished = true
                }
                guard isCurrent(entry, driverID: driverID) else { return }
                var snapshot = await entry.cache.snapshot()
                guard isCurrent(entry, driverID: driverID) else { return }
                if didFinishAdoption,
                   snapshot.pendingPreparedAcknowledgementCount > 0
                {
                    finishDriver(entry, driverID: driverID, retry: true)
                    return
                }
                if snapshot.pendingPreparedAcknowledgementCount > 0 {
                    phase = .acknowledgement
                    try await entry.cache.retryPendingPreparedAcknowledgement()
                    guard isCurrent(entry, driverID: driverID) else { return }
                    snapshot = await entry.cache.snapshot()
                    guard isCurrent(entry, driverID: driverID) else { return }
                }
                guard snapshot.pendingPreparedAcknowledgementCount == 0 else {
                    finishDriver(entry, driverID: driverID, retry: true)
                    return
                }
                phase = .handoff
                let uiRetainsPresentation = handoff.terminal(
                    handoff.terminalError
                )
                if !uiRetainsPresentation { upgrade(entry, to: .retire) }
                guard entry.handoffs.first === handoff else { return }
                entry.handoffs.removeFirst()
                entry.completedHandoffCount &+= 1
                handoff.completion.finish()
                resumeAcknowledgementWaiters(entry.strokeEpoch.identity)
                finishDriver(entry, driverID: driverID, retry: false)
                if !entry.handoffs.isEmpty
                    || entry.intent != .acknowledgementOnly
                {
                    startDriverIfPossible(entry)
                }
                return
            }

            let before = await entry.cache.snapshot()
            guard isCurrent(entry, driverID: driverID) else { return }
            if before.pendingPreparedAcknowledgementCount > 0 {
                phase = .acknowledgement
                try await entry.cache.retryPendingPreparedAcknowledgement()
                guard isCurrent(entry, driverID: driverID) else { return }
                phase = .handoff
            }
            let acknowledged = await entry.cache.snapshot()
            guard isCurrent(entry, driverID: driverID) else { return }
            guard acknowledged.pendingPreparedAcknowledgementCount == 0
            else {
                finishDriver(entry, driverID: driverID, retry: true)
                return
            }
            switch entry.intent {
            case .acknowledgementOnly:
                parkAfterAcknowledgement(entry)
                return
            case .retire:
                phase = .retirement
                try await entry.cache.retire(strokeEpoch: entry.strokeEpoch)
            case .cancel:
                phase = .retirement
                try await entry.cache.cancel(strokeEpoch: entry.strokeEpoch)
            }
            guard isCurrent(entry, driverID: driverID) else { return }
            let terminal = await entry.cache.snapshot()
            guard isCurrent(entry, driverID: driverID) else { return }
            guard terminal.pendingPreparedAcknowledgementCount == 0,
                  terminal.activeUpdateOwnerCount == 0,
                  terminal.activeStrokeEpochCount == 0,
                  entry.handoffs.isEmpty,
                  terminal.isIdle
            else {
                finishDriver(entry, driverID: driverID, retry: true)
                return
            }
            complete(entry, snapshot: terminal)
        } catch {
            guard isCurrent(entry, driverID: driverID) else { return }
            if phase == .retirement {
                await entry.cache.waitBeforeRetirementRetry()
                guard isCurrent(entry, driverID: driverID) else { return }
                if !entry.didReportRetirementFailure,
                   let failureTerminal = entry.failureTerminal
                {
                    entry.didReportRetirementFailure = true
                    failureTerminal(error)
                }
            }
            finishDriver(entry, driverID: driverID, retry: true)
        }
    }

    private func scheduleAutomaticRetry(_ entry: Entry) {
        guard entries[entry.strokeEpoch.identity] === entry,
              entry.retryTask == nil,
              entry.driverID == nil
        else { return }
        let attempt = entry.retryAttemptCount
        entry.retryAttemptCount += 1
        let retryTaskID = UUID()
        entry.retryTaskID = retryTaskID
        entry.retryTask = Task { @MainActor [weak self, entry] in
            do {
                try await entry.cache.waitForLifecycleRetry(attempt: attempt)
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.entries[entry.strokeEpoch.identity] === entry,
                  entry.retryTaskID == retryTaskID
            else { return }
            entry.retryTaskID = nil
            entry.retryTask = nil
            self.startDriverIfPossible(entry)
        }
    }

    func cancelRetainedLifecycle(_ identity: UUID) async {
        guard let entry = entries[identity] else { return }
        upgrade(entry, to: .cancel)
        if entry.retryTask == nil { startDriverIfPossible(entry) }
    }

    func waitForLifecycle(_ identity: UUID) async {
        guard entries[identity] != nil else { return }
        await withCheckedContinuation {
            lifecycleWaiters[identity, default: []].append($0)
        }
    }

    func waitForAcknowledgement(_ identity: UUID) async {
        guard let entry = entries[identity] else { return }
        let generation = entry.completedHandoffCount
            + UInt64(entry.handoffs.count)
        guard entry.completedHandoffCount < generation else {
            return
        }
        await withCheckedContinuation {
            acknowledgementWaiters[identity, default: []].append(
                (generation, $0)
            )
        }
    }

    func retainsLifecycle(_ identity: UUID) -> Bool {
        entries[identity] != nil
    }

    private func waitForQuiescence() async {
        guard entries.values.contains(where: { $0.driverID != nil }) else {
            return
        }
        await withCheckedContinuation { quiescenceWaiters.append($0) }
    }

    private func isCurrent(_ entry: Entry, driverID: UUID) -> Bool {
        entries[entry.strokeEpoch.identity] === entry
            && entry.driverID == driverID
            && !Task.isCancelled
    }

    private func finishDriver(
        _ entry: Entry,
        driverID: UUID,
        retry: Bool
    ) {
        guard entry.driverID == driverID else { return }
        entry.driverID = nil
        entry.driverTask = nil
        resumeQuiescenceIfNeeded()
        if retry { scheduleAutomaticRetry(entry) }
    }

    private func complete(
        _ entry: Entry,
        snapshot: InteractiveStrokePresentationCacheSnapshot
    ) {
        let identity = entry.strokeEpoch.identity
        guard entries[identity] === entry else { return }
        entries.removeValue(forKey: identity)
        let nextCacheEntry = releaseCacheOwnership(entry)
        cancelRetry(entry)
        entry.driverID = nil
        entry.driverTask = nil
        let terminal = entry.terminalActionLifecycleTerminal
            ?? entry.handoffLifecycleTerminal
        entry.terminalActionLifecycleTerminal = nil
        entry.handoffLifecycleTerminal = nil
        terminal?(snapshot)
        let waiters = lifecycleWaiters.removeValue(forKey: identity) ?? []
        for waiter in waiters { waiter.resume() }
        resumeAcknowledgementWaiters(identity)
        resumeQuiescenceIfNeeded()
        if let nextCacheEntry { startDriverIfPossible(nextCacheEntry) }
    }

    private func appendCacheWaiterIfNeeded(
        _ identity: UUID,
        cacheIdentity: ObjectIdentifier
    ) {
        guard cacheWaitingEntryIdentities[cacheIdentity]?.contains(identity)
                != true
        else { return }
        cacheWaitingEntryIdentities[cacheIdentity, default: []]
            .append(identity)
    }

    private func releaseCacheOwnership(_ entry: Entry) -> Entry? {
        let cacheIdentity = ObjectIdentifier(entry.cache)
        let identity = entry.strokeEpoch.identity
        cacheWaitingEntryIdentities[cacheIdentity]?.removeAll {
            $0 == identity || entries[$0] == nil
        }
        guard cacheOwnerEntryIdentities[cacheIdentity] == identity else {
            return nil
        }
        cacheOwnerEntryIdentities.removeValue(forKey: cacheIdentity)
        var waiters = cacheWaitingEntryIdentities[cacheIdentity] ?? []
        while let nextIdentity = waiters.first {
            waiters.removeFirst()
            guard let next = entries[nextIdentity],
                  next.cache === entry.cache
            else { continue }
            cacheWaitingEntryIdentities[cacheIdentity] = waiters.isEmpty
                ? nil : waiters
            cacheOwnerEntryIdentities[cacheIdentity] = nextIdentity
            return next
        }
        cacheWaitingEntryIdentities.removeValue(forKey: cacheIdentity)
        return nil
    }

    private func parkAfterAcknowledgement(_ entry: Entry) {
        guard entries[entry.strokeEpoch.identity] === entry else { return }
        precondition(entry.handoffs.isEmpty)
        entry.driverID = nil
        entry.driverTask = nil
        cancelRetry(entry)
        resumeAcknowledgementWaiters(entry.strokeEpoch.identity)
        resumeQuiescenceIfNeeded()
    }

    private func resumeAcknowledgementWaiters(_ identity: UUID) {
        guard let entry = entries[identity] else {
            let waiters = acknowledgementWaiters.removeValue(forKey: identity)
                ?? []
            for (_, waiter) in waiters { waiter.resume() }
            return
        }
        var remaining: [(UInt64, CheckedContinuation<Void, Never>)] = []
        for (generation, waiter) in
            acknowledgementWaiters.removeValue(forKey: identity) ?? []
        {
            if generation <= entry.completedHandoffCount {
                waiter.resume()
            } else {
                remaining.append((generation, waiter))
            }
        }
        if !remaining.isEmpty { acknowledgementWaiters[identity] = remaining }
    }

    private func upgrade(_ entry: Entry, to intent: Intent) {
        if intent.rawValue > entry.intent.rawValue { entry.intent = intent }
    }

    private func cancelRetry(_ entry: Entry) {
        entry.retryTaskID = nil
        entry.retryTask?.cancel()
        entry.retryTask = nil
    }

    private func resumeQuiescenceIfNeeded() {
        guard !entries.values.contains(where: { $0.driverID != nil }) else {
            return
        }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
