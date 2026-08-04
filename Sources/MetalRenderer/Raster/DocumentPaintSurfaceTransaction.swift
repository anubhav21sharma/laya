import Foundation
import Metal
import PatternEngine

public enum DocumentPaintSurfaceTransactionKind:
    UInt8, Equatable, Sendable
{
    case stroke
    case clear
    case resize
    case encodedImport
    case restore
}

public enum DocumentPaintSurfaceTransactionPhase:
    UInt8, Equatable, Sendable
{
    case prepared
    case mutationEncoded
    case mutationCompleted
    case historyEncoded
    case historyCompleted
    case terminalPrepared
    case restorePrepared
    case restoreEncoded
    case restoreCompleted
    case restoreTerminalPrepared
    case published
    case discardPending
    case discarded
}

public enum DocumentPaintSurfaceTransactionState:
    Equatable, Sendable
{
    case idle
    case live
    case reducing
    case capturing
    case terminalReady
    case discardPending
}

public enum DocumentPaintSurfaceTransactionError:
    Error, Equatable, Sendable
{
    case transactionAlreadyLive
    case noLiveTransaction
    case sequenceOverflow
    case foreignHandle
    case staleHandle
    case handleAlreadyConsumed
    case wrongPhase(
        expected: DocumentPaintSurfaceTransactionPhase,
        actual: DocumentPaintSurfaceTransactionPhase
    )
    case unsupportedMutationKind(DocumentPaintSurfaceTransactionKind)
    case unknownLayerID(UUID)
    case baseGeometryMismatch(
        expected: DocumentPaintGeometry,
        actual: DocumentPaintGeometry
    )
    case duplicateCoordinate(PaintTileCoordinate)
    case unsortedCoordinate(
        previous: PaintTileCoordinate,
        current: PaintTileCoordinate
    )
    case coordinateOutsideBase(PaintTileCoordinate)
    case coordinateOutsideCandidate(PaintTileCoordinate)
    case missingBaseCoordinate(PaintTileCoordinate)
    case overlappingDirtyAndRemovedCoordinate(PaintTileCoordinate)
    case incompleteGeometryReplacement(PaintTileCoordinate)
    case emptyMutation
    case backendEncodingFailed
    case backendCompletionFailed
    case backendDiscardFailed
    case mutationCommandFailed
    case invalidReductionCoordinate(PaintTileCoordinate)
    case missingReductionCoordinate(PaintTileCoordinate)
    case duplicateReductionCoordinate(PaintTileCoordinate)
    case invalidReductionBounds(PaintTileCoordinate)
    case invalidReductionAlpha(PaintTileCoordinate)
    case invalidReductionFlag(PaintTileCoordinate)
    case reductionValidationFailed
    case destinationLeaseReturnFailed
    case sourceLeaseReturnFailed
    case candidatePruneFailed
    case historyNotRequired
    case historyAllocationFailed
    case historyCaptureFailed
    case historyFinalizationFailed
    case terminalPreflightFailed
    case registryPreparationFailed
    case revisionPublishFailed
    case restoreReferenceUnavailable
    case restoreLayerMismatch(expected: UUID, actual: UUID)
    case restoreGeometryMismatch
    case restoreDispositionMismatch
    case restorePreparationFailed
    case restoreEncodingFailed
    case restoreCompletionFailed
    case restoreCommandFailed
    case restoreConsumeFailed
    case cleanupFailed
}

public enum DocumentPaintSurfaceTransactionFailurePoint:
    Equatable, Sendable
{
    case candidateReserve(Int)
    case mutationEncode
    case mutationCompletion
    case reductionValidation
    case destinationLeaseReturn
    case candidatePrune
    case historyAllocation(Int)
    case historyCapture(Int)
    case historyEncoding
    case historyCompletion(Int)
    case sourceLeaseReturn
    case terminalPreflight
    case registryPrepare
    case revisionPublish
    case restoreEncoding
    case restoreCompletion
    case restoreDestinationLeaseReturn
    case restoreTerminalPreflight
    case restoreRegistryPrepare
    case restoreConsume
    case cleanup
}

public struct DocumentPaintSurfaceTransactionFailureInjection: Sendable {
    let failingPoint: DocumentPaintSurfaceTransactionFailurePoint

    public init(failingAt point: DocumentPaintSurfaceTransactionFailurePoint) {
        failingPoint = point
    }

    func shouldFail(
        at point: DocumentPaintSurfaceTransactionFailurePoint
    ) -> Bool {
        failingPoint == point
    }
}

public struct DocumentPaintSurfaceMutationRequest:
    Equatable, Sendable
{
    public let kind: DocumentPaintSurfaceTransactionKind
    public let layerID: UUID
    public let baseGeometry: DocumentPaintGeometry
    public let candidateGeometry: DocumentPaintGeometry
    public let dirtyCoordinates: [PaintTileCoordinate]
    public let explicitlyRemovedCoordinates: [PaintTileCoordinate]
    public let requiresHistoryPair: Bool

    public init(
        kind: DocumentPaintSurfaceTransactionKind,
        layerID: UUID,
        baseGeometry: DocumentPaintGeometry,
        candidateGeometry: DocumentPaintGeometry,
        dirtyCoordinates: [PaintTileCoordinate],
        explicitlyRemovedCoordinates: [PaintTileCoordinate],
        requiresHistoryPair: Bool
    ) {
        self.kind = kind
        self.layerID = layerID
        self.baseGeometry = baseGeometry
        self.candidateGeometry = candidateGeometry
        self.dirtyCoordinates = dirtyCoordinates
        self.explicitlyRemovedCoordinates = explicitlyRemovedCoordinates
        self.requiresHistoryPair = requiresHistoryPair
    }
}

public struct DocumentPaintSurfaceRestoreTileExpectation:
    Equatable, Sendable
{
    public let coordinate: PaintTileCoordinate
    public let disposition: TiledRasterRevisionInstallDisposition

    public init(
        coordinate: PaintTileCoordinate,
        disposition: TiledRasterRevisionInstallDisposition
    ) {
        self.coordinate = coordinate
        self.disposition = disposition
    }
}

public struct DocumentPaintSurfaceRestoreRequest: Equatable, Sendable {
    public let reference: RasterRevisionReference
    public let targetGeometry: DocumentPaintGeometry
    public let layerID: UUID
    public let expectedInstallDispositions:
        [DocumentPaintSurfaceRestoreTileExpectation]

    public init(
        reference: RasterRevisionReference,
        targetGeometry: DocumentPaintGeometry,
        layerID: UUID,
        expectedInstallDispositions:
            [DocumentPaintSurfaceRestoreTileExpectation]
    ) {
        self.reference = reference
        self.targetGeometry = targetGeometry
        self.layerID = layerID
        self.expectedInstallDispositions = expectedInstallDispositions
    }
}

public struct DocumentPaintSurfaceNoOp: Equatable, Sendable {
    public let kind: DocumentPaintSurfaceTransactionKind
    public let layerID: UUID
    public let generation: UInt64
}

public enum DocumentPaintMutationPreparation: Sendable {
    case prepared(DocumentPaintPreparedMutation)
    case noOp(DocumentPaintSurfaceNoOp)
}

public struct DocumentPaintSurfaceTransactionSnapshot:
    Equatable, Sendable
{
    public let state: DocumentPaintSurfaceTransactionState
    public let phase: DocumentPaintSurfaceTransactionPhase?
    public let sequence: UInt64?
    public let candidateCoordinates: [PaintTileCoordinate]
}

public struct DocumentPaintSurfaceCommitResult: Equatable, Sendable {
    public let layerID: UUID
    public let beforeGeneration: UInt64
    public let afterGeneration: UInt64
    public let dirtyCoordinates: [PaintTileCoordinate]
    public let historyPair: PendingRasterRevisionPair?
}

public struct DocumentPaintSurfaceRestoreResult: Equatable, Sendable {
    public let layerID: UUID
    public let beforeGeneration: UInt64
    public let afterGeneration: UInt64
    public let reference: RasterRevisionReference
    public let restoredCoordinates: [PaintTileCoordinate]
}

protocol DocumentPaintSurfaceTransactionHandle: Sendable {
    var coordinatorIdentity: UUID { get }
    var sequence: UInt64 { get }
    var phase: DocumentPaintSurfaceTransactionPhase { get }
}

public struct DocumentPaintPreparedMutation:
    DocumentPaintSurfaceTransactionHandle, Equatable, Sendable
{
    let coordinatorIdentity: UUID
    public let sequence: UInt64
    let phase = DocumentPaintSurfaceTransactionPhase.prepared
}

public struct DocumentPaintEncodedMutation:
    DocumentPaintSurfaceTransactionHandle, Equatable, Sendable
{
    let coordinatorIdentity: UUID
    public let sequence: UInt64
    let phase = DocumentPaintSurfaceTransactionPhase.mutationEncoded
}

public struct DocumentPaintReducedMutation:
    DocumentPaintSurfaceTransactionHandle, Equatable, Sendable
{
    let coordinatorIdentity: UUID
    public let sequence: UInt64
    let phase = DocumentPaintSurfaceTransactionPhase.mutationCompleted
}

public struct DocumentPaintEncodedHistory:
    DocumentPaintSurfaceTransactionHandle, Equatable, Sendable
{
    let coordinatorIdentity: UUID
    public let sequence: UInt64
    let phase = DocumentPaintSurfaceTransactionPhase.historyEncoded
}

public struct DocumentPaintCompletedHistory:
    DocumentPaintSurfaceTransactionHandle, Equatable, Sendable
{
    let coordinatorIdentity: UUID
    public let sequence: UInt64
    let phase = DocumentPaintSurfaceTransactionPhase.historyCompleted
}

public struct DocumentPaintTerminalCommit:
    DocumentPaintSurfaceTransactionHandle, Equatable, Sendable
{
    let coordinatorIdentity: UUID
    public let sequence: UInt64
    let phase = DocumentPaintSurfaceTransactionPhase.terminalPrepared
}

public struct DocumentPaintPreparedRestore:
    DocumentPaintSurfaceTransactionHandle, Equatable, Sendable
{
    let coordinatorIdentity: UUID
    public let sequence: UInt64
    let phase = DocumentPaintSurfaceTransactionPhase.restorePrepared
}

public struct DocumentPaintEncodedRestore:
    DocumentPaintSurfaceTransactionHandle, Equatable, Sendable
{
    let coordinatorIdentity: UUID
    public let sequence: UInt64
    let phase = DocumentPaintSurfaceTransactionPhase.restoreEncoded
}

public struct DocumentPaintCompletedRestore:
    DocumentPaintSurfaceTransactionHandle, Equatable, Sendable
{
    let coordinatorIdentity: UUID
    public let sequence: UInt64
    let phase = DocumentPaintSurfaceTransactionPhase.restoreCompleted
}

public struct DocumentPaintTerminalRestore:
    DocumentPaintSurfaceTransactionHandle, Equatable, Sendable
{
    let coordinatorIdentity: UUID
    public let sequence: UInt64
    let phase = DocumentPaintSurfaceTransactionPhase.restoreTerminalPrepared
}

public struct DocumentPaintTransparencyReduction: Equatable, Sendable {
    public let inspectedCoordinates: [PaintTileCoordinate]
    public let fullyTransparentCoordinates: [PaintTileCoordinate]
}

struct DocumentPaintSurfaceMutationDestination: @unchecked Sendable {
    let coordinate: PaintTileCoordinate
    let logicalBounds: PixelRect
    let texture: any MTLTexture
}

/// Complete restore payload presented to the inert backend preflight. It is
/// deliberately typed and contains no candidate, install lease, or registry
/// commit token.
struct DocumentPaintSurfaceRestoreBackendPayload: @unchecked Sendable {
    let reference: RasterRevisionReference
    let destinations: [DocumentPaintSurfaceMutationDestination]
}

enum DocumentPaintSurfaceBackendOperation: @unchecked Sendable {
    case mutation(
        kind: DocumentPaintSurfaceTransactionKind,
        destinations: [DocumentPaintSurfaceMutationDestination]
    )
    case restore(DocumentPaintSurfaceRestoreBackendPayload)
}

struct DocumentPaintSurfaceMutationBackendEncoding:
    Hashable, Sendable
{
    let rawValue: UUID

    init() { rawValue = UUID() }
}

struct DocumentPaintSurfaceMutationEvidence: Equatable, Sendable {
    let coordinate: PaintTileCoordinate
    let logicalBounds: PixelRect
    let maximumAlpha: Float
    let invalid: Bool

    init(
        coordinate: PaintTileCoordinate,
        logicalBounds: PixelRect,
        maximumAlpha: Float,
        invalid: Bool = false
    ) {
        self.coordinate = coordinate
        self.logicalBounds = logicalBounds
        self.maximumAlpha = maximumAlpha
        self.invalid = invalid
    }
}

protocol DocumentPaintSurfaceMutationBackend:
    AnyObject, Sendable
{
    func preflight(_ operation: DocumentPaintSurfaceBackendOperation) throws

    func encode(
        destinations: [DocumentPaintSurfaceMutationDestination]
    ) throws -> DocumentPaintSurfaceMutationBackendEncoding

    func complete(
        _ encoding: DocumentPaintSurfaceMutationBackendEncoding,
        as outcome: RasterRevisionOperationOutcome
    ) throws -> [DocumentPaintSurfaceMutationEvidence]

    /// Synchronously abandons an encoding. This must not return until every
    /// GPU operation represented by `encoding` is terminal and no longer
    /// accesses any destination texture. The coordinator retains all related
    /// tile leases until this method returns successfully.
    func discardAndWaitUntilTerminal(
        _ encoding: DocumentPaintSurfaceMutationBackendEncoding
    ) throws
}

/// Production-inert owner for one complete sparse document mutation. It is
/// intentionally independent from GridRenderer until the atomic Task 6 switch.
public final class DocumentPaintSurfaceTransaction: @unchecked Sendable {
    private final class LiveTransaction {
        let sequence: UInt64
        let request: DocumentPaintSurfaceMutationRequest
        let baseGeneration: UInt64
        let baseBinding: DocumentPaintLayerBinding
        let candidate: DocumentPaintSurfaceCandidate
        var phase: DocumentPaintSurfaceTransactionPhase

        var candidateBinding: DocumentPaintLayerBinding?
        var destinationLease: PaintTileLease?
        var backendEncoding: DocumentPaintSurfaceMutationBackendEncoding?
        var reduction: DocumentPaintTransparencyReduction?
        var revisionPair: PendingRasterRevisionPair?
        var historyCommandBuffer: (any MTLCommandBuffer)?
        var beforeCapture: TiledRasterRevisionOperationToken?
        var afterCapture: TiledRasterRevisionOperationToken?
        var baseSourceLease: PaintTileLease?
        var candidateSourceLease: PaintTileLease?
        var preparedCommit: DocumentPaintPreparedCommit?
        var commitResult: DocumentPaintSurfaceCommitResult?

        init(
            sequence: UInt64,
            request: DocumentPaintSurfaceMutationRequest,
            baseGeneration: UInt64,
            baseBinding: DocumentPaintLayerBinding,
            candidate: DocumentPaintSurfaceCandidate,
            phase: DocumentPaintSurfaceTransactionPhase
        ) {
            self.sequence = sequence
            self.request = request
            self.baseGeneration = baseGeneration
            self.baseBinding = baseBinding
            self.candidate = candidate
            self.phase = phase
        }
    }

    private final class LiveRestore {
        let sequence: UInt64
        let request: DocumentPaintSurfaceRestoreRequest
        let baseGeneration: UInt64
        let baseBinding: DocumentPaintLayerBinding
        let candidate: DocumentPaintSurfaceCandidate
        var installLease: TiledRasterRevisionInstallLease?
        var phase: DocumentPaintSurfaceTransactionPhase

        var candidateBinding: DocumentPaintLayerBinding?
        var destinationLease: PaintTileLease?
        var commandBuffer: (any MTLCommandBuffer)?
        var installOperation: TiledRasterRevisionOperationToken?
        var preparedCommit: DocumentPaintPreparedCommit?
        var result: DocumentPaintSurfaceRestoreResult?

        init(
            sequence: UInt64,
            request: DocumentPaintSurfaceRestoreRequest,
            baseGeneration: UInt64,
            baseBinding: DocumentPaintLayerBinding,
            candidate: DocumentPaintSurfaceCandidate,
            installLease: TiledRasterRevisionInstallLease
        ) {
            self.sequence = sequence
            self.request = request
            self.baseGeneration = baseGeneration
            self.baseBinding = baseBinding
            self.candidate = candidate
            self.installLease = installLease
            phase = .restorePrepared
        }
    }

    private let identity = UUID()
    private let lock = NSLock()
    private let registry: DocumentPaintSurfaceStore
    private let revisionStore: TiledRasterRevisionStore
    private let commandQueue: any MTLCommandQueue
    private let mutationBackend: any DocumentPaintSurfaceMutationBackend
    private let afterBaseSnapshotForTesting: (@Sendable () throws -> Void)?
    private var nextSequence: UInt64 = 1
    private var lastCompletedSequence: UInt64 = 0
    private var live: LiveTransaction?
    private var liveRestore: LiveRestore?

    init(
        registry: DocumentPaintSurfaceStore,
        revisionStore: TiledRasterRevisionStore,
        commandQueue: any MTLCommandQueue,
        mutationBackend: any DocumentPaintSurfaceMutationBackend,
        afterBaseSnapshotForTesting: (@Sendable () throws -> Void)? = nil
    ) {
        self.registry = registry
        self.revisionStore = revisionStore
        self.commandQueue = commandQueue
        self.mutationBackend = mutationBackend
        self.afterBaseSnapshotForTesting = afterBaseSnapshotForTesting
    }

    public func snapshot() -> DocumentPaintSurfaceTransactionSnapshot {
        withLock {
            guard live != nil || liveRestore != nil else {
                return .init(
                    state: .idle,
                    phase: nil,
                    sequence: nil,
                    candidateCoordinates: []
                )
            }
            if let liveRestore {
                let coordinates: [PaintTileCoordinate]
                do {
                    coordinates = try liveRestore.candidate
                        .binding(for: liveRestore.request.layerID)
                        .canonical.references.map(\.coordinate)
                } catch {
                    coordinates = []
                }
                return .init(
                    state: Self.publicState(for: liveRestore.phase),
                    phase: liveRestore.phase,
                    sequence: liveRestore.sequence,
                    candidateCoordinates: coordinates
                )
            }
            guard let live else {
                preconditionFailure("Live transaction state was lost")
            }
            let coordinates: [PaintTileCoordinate]
            do {
                coordinates = try live.candidate
                    .binding(for: live.request.layerID)
                    .canonical.references.map(\.coordinate)
            } catch {
                coordinates = []
            }
            return .init(
                state: Self.publicState(for: live.phase),
                phase: live.phase,
                sequence: live.sequence,
                candidateCoordinates: coordinates
            )
        }
    }

    public func prepareMutation(
        _ request: DocumentPaintSurfaceMutationRequest,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintMutationPreparation {
        try withLock {
            guard live == nil, liveRestore == nil else {
                throw DocumentPaintSurfaceTransactionError
                    .transactionAlreadyLive
            }
            guard request.kind != .restore else {
                throw DocumentPaintSurfaceTransactionError
                    .unsupportedMutationKind(request.kind)
            }
            let base: DocumentPaintSurfaceMutationBaseSnapshot
            do {
                base = try registry.captureMutationBase(for: request.layerID)
            } catch DocumentPaintSurfaceStoreError.unknownLayerID {
                throw DocumentPaintSurfaceTransactionError
                    .unknownLayerID(request.layerID)
            }
            try afterBaseSnapshotForTesting?()
            let activeGeometry = base.geometry
            guard request.baseGeometry == activeGeometry else {
                throw DocumentPaintSurfaceTransactionError
                    .baseGeometryMismatch(
                        expected: activeGeometry,
                        actual: request.baseGeometry
                    )
            }
            try Self.validateSortedUnique(request.dirtyCoordinates)
            try Self.validateSortedUnique(
                request.explicitlyRemovedCoordinates
            )
            let removed = Set(request.explicitlyRemovedCoordinates)
            if let overlap = request.dirtyCoordinates.first(
                where: removed.contains
            ) {
                throw DocumentPaintSurfaceTransactionError
                    .overlappingDirtyAndRemovedCoordinate(overlap)
            }
            for coordinate in request.dirtyCoordinates {
                try Self.validate(
                    coordinate,
                    in: request.candidateGeometry.storagePixelSize,
                    outside: .coordinateOutsideCandidate(coordinate)
                )
            }
            for coordinate in request.explicitlyRemovedCoordinates {
                try Self.validate(
                    coordinate,
                    in: request.baseGeometry.storagePixelSize,
                    outside: .coordinateOutsideBase(coordinate)
                )
            }

            let baseBinding = base.binding
            let baseCoordinates = baseBinding.canonical.references
                .map(\.coordinate)
            let baseSet = Set(baseCoordinates)
            for coordinate in request.explicitlyRemovedCoordinates
            where !baseSet.contains(coordinate) {
                throw DocumentPaintSurfaceTransactionError
                    .missingBaseCoordinate(coordinate)
            }
            if request.kind == .clear {
                guard request.dirtyCoordinates.isEmpty else {
                    throw DocumentPaintSurfaceTransactionError
                        .unsupportedMutationKind(.clear)
                }
                if baseCoordinates.isEmpty,
                   request.explicitlyRemovedCoordinates.isEmpty {
                    return .noOp(DocumentPaintSurfaceNoOp(
                        kind: .clear,
                        layerID: request.layerID,
                        generation: base.generation
                    ))
                }
                guard request.explicitlyRemovedCoordinates == baseCoordinates
                else {
                    guard let missing = baseCoordinates.first(where: {
                        !removed.contains($0)
                    }) else {
                        throw DocumentPaintSurfaceTransactionError
                            .unsupportedMutationKind(.clear)
                    }
                    throw DocumentPaintSurfaceTransactionError
                        .missingBaseCoordinate(missing)
                }
            } else if request.dirtyCoordinates.isEmpty,
                      request.explicitlyRemovedCoordinates.isEmpty {
                throw DocumentPaintSurfaceTransactionError.emptyMutation
            }

            if request.candidateGeometry != request.baseGeometry {
                let dirty = Set(request.dirtyCoordinates)
                for coordinate in baseCoordinates
                where !dirty.contains(coordinate)
                    && !removed.contains(coordinate) {
                    throw DocumentPaintSurfaceTransactionError
                        .incompleteGeometryReplacement(coordinate)
                }
            }

            guard nextSequence < UInt64.max else {
                throw DocumentPaintSurfaceTransactionError.sequenceOverflow
            }
            let sequence = nextSequence
            let candidate = try registry.makeCandidate(
                from: base,
                geometry: request.candidateGeometry,
                dirtyCoordinatesByLayer: [
                    request.layerID: request.dirtyCoordinates,
                ],
                removingCoordinatesByLayer: [
                    request.layerID:
                        request.explicitlyRemovedCoordinates,
                ],
                failureInjection: Self.candidateAllocationFailure(
                    failureInjection
                )
            )
            nextSequence += 1
            live = LiveTransaction(
                sequence: sequence,
                request: request,
                baseGeneration: baseBinding.generation,
                baseBinding: baseBinding,
                candidate: candidate,
                phase: .prepared
            )
            return .prepared(DocumentPaintPreparedMutation(
                coordinatorIdentity: identity,
                sequence: sequence
            ))
        }
    }

    public func prepareRestore(
        _ request: DocumentPaintSurfaceRestoreRequest,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintPreparedRestore {
        try withLock {
            guard live == nil, liveRestore == nil else {
                throw DocumentPaintSurfaceTransactionError.transactionAlreadyLive
            }
            guard let referenceLayer = request.reference.layerID else {
                throw DocumentPaintSurfaceTransactionError
                    .restoreReferenceUnavailable
            }
            guard referenceLayer == request.layerID else {
                throw DocumentPaintSurfaceTransactionError.restoreLayerMismatch(
                    expected: referenceLayer,
                    actual: request.layerID
                )
            }
            guard request.reference.pixelSize
                    == request.targetGeometry.storagePixelSize,
                  request.reference.documentPixelSize
                    == request.targetGeometry.documentPixelSize
            else {
                throw DocumentPaintSurfaceTransactionError
                    .restoreGeometryMismatch
            }
            try Self.validateRestoreExpectations(
                request.expectedInstallDispositions
            )

            let base: DocumentPaintSurfaceMutationBaseSnapshot
            do {
                base = try registry.captureMutationBase(for: request.layerID)
            } catch DocumentPaintSurfaceStoreError.unknownLayerID {
                throw DocumentPaintSurfaceTransactionError
                    .unknownLayerID(request.layerID)
            }
            let installLease: TiledRasterRevisionInstallLease
            do {
                installLease = try revisionStore.beginPublishedInstall(
                    for: request.reference
                )
            } catch {
                throw DocumentPaintSurfaceTransactionError
                    .restoreReferenceUnavailable
            }
            let actual = installLease.tiles.map {
                DocumentPaintSurfaceRestoreTileExpectation(
                    coordinate: $0.descriptor.coordinate,
                    disposition: $0.disposition
                )
            }
            guard actual == request.expectedInstallDispositions else {
                try abandonRestoreInstall(installLease)
                throw DocumentPaintSurfaceTransactionError
                    .restoreDispositionMismatch
            }

            let replacements = actual.compactMap {
                $0.disposition == .replace ? $0.coordinate : nil
            }
            for coordinate in replacements {
                do {
                    _ = try PaintTileDescriptor(
                        coordinate: coordinate,
                        logicalPixelSize:
                            request.targetGeometry.storagePixelSize
                    )
                } catch {
                    try abandonRestoreInstall(installLease)
                    throw DocumentPaintSurfaceTransactionError
                        .restoreGeometryMismatch
                }
            }
            let baseCoordinates = base.binding.canonical.references
                .map(\.coordinate)
            let historicalRemovals = actual.compactMap {
                $0.disposition == .remove ? $0.coordinate : nil
            }
            let removals: [PaintTileCoordinate]
            if request.targetGeometry != base.geometry {
                let replacementSet = Set(replacements)
                removals = Array(Set(
                    historicalRemovals
                        + baseCoordinates.filter { !replacementSet.contains($0) }
                )).sorted()
            } else {
                removals = historicalRemovals
            }

            guard nextSequence < UInt64.max else {
                try abandonRestoreInstall(installLease)
                throw DocumentPaintSurfaceTransactionError.sequenceOverflow
            }
            let sequence = nextSequence
            var candidateForCleanup: DocumentPaintSurfaceCandidate?
            let candidate: DocumentPaintSurfaceCandidate
            let binding: DocumentPaintLayerBinding
            let destinationLease: PaintTileLease
            do {
                candidate = try registry.makeCandidate(
                    from: base,
                    geometry: request.targetGeometry,
                    dirtyCoordinatesByLayer: [request.layerID: replacements],
                    removingCoordinatesByLayer: [request.layerID: removals],
                    failureInjection: Self.candidateAllocationFailure(
                        failureInjection
                    )
                )
                candidateForCleanup = candidate
                binding = try candidate.binding(for: request.layerID)
                destinationLease = try binding.canonical.leaseExistingTiles(
                    at: replacements,
                    pinReasons: [.dirty, .inFlight]
                )
            } catch {
                if let candidateForCleanup {
                    do {
                        try registry.discard(candidateForCleanup)
                    } catch {
                        try abandonRestoreInstall(installLease)
                        throw DocumentPaintSurfaceTransactionError.cleanupFailed
                    }
                }
                try abandonRestoreInstall(installLease)
                throw DocumentPaintSurfaceTransactionError
                    .restorePreparationFailed
            }
            nextSequence += 1
            let current = LiveRestore(
                sequence: sequence,
                request: request,
                baseGeneration: base.generation,
                baseBinding: base.binding,
                candidate: candidate,
                installLease: installLease
            )
            current.candidateBinding = binding
            current.destinationLease = destinationLease
            liveRestore = current
            return DocumentPaintPreparedRestore(
                coordinatorIdentity: identity,
                sequence: sequence
            )
        }
    }

    public func encodeRestore(
        _ handle: DocumentPaintPreparedRestore,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintEncodedRestore {
        try withLock {
            let current = try validatedRestore(handle)
            guard let installLease = current.installLease,
                  let destinationLease = current.destinationLease
            else {
                preconditionFailure("Prepared restore lost owned resources")
            }
            let destinations = destinationLease.bindings.map {
                DocumentPaintSurfaceMutationDestination(
                    coordinate: $0.descriptor.coordinate,
                    logicalBounds: $0.descriptor.logicalBounds,
                    texture: $0.texture
                )
            }
            let payload = DocumentPaintSurfaceRestoreBackendPayload(
                reference: current.request.reference,
                destinations: destinations
            )
            do {
                try mutationBackend.preflight(.restore(payload))
                try Self.validateRestoreDestinations(
                    destinations,
                    expected: current.request.expectedInstallDispositions
                )
            } catch {
                throw DocumentPaintSurfaceTransactionError.restoreEncodingFailed
            }
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.restoreEncodingFailed
            }
            commandBuffer.label = "Document Paint Restore"
            current.commandBuffer = commandBuffer
            let encodingFailure: TiledRasterRevisionFailureInjection?
            if failureInjection?.shouldFail(at: .restoreEncoding) == true {
                encodingFailure = .init(failingAt: .commandEncoding)
            } else {
                encodingFailure = nil
            }
            do {
                current.installOperation = try revisionStore.encodeInstall(
                    installLease,
                    layerID: installLease.layerID,
                    generation: installLease.generation,
                    targets: destinations.map {
                        TiledRasterRevisionTileTarget(
                            coordinate: $0.coordinate,
                            texture: $0.texture
                        )
                    },
                    on: commandBuffer,
                    failureInjection: encodingFailure
                )
                commandBuffer.commit()
            } catch {
                current.commandBuffer = nil
                current.installOperation = nil
                do {
                    let result = try revisionStore
                        .abandonInstallForCoordinatorIfOwned(
                            installLease,
                            layerID: installLease.layerID,
                            generation: installLease.generation
                        )
                    guard result != .cancellationPending else {
                        current.phase = .discardPending
                        throw DocumentPaintSurfaceTransactionError.cleanupFailed
                    }
                    current.installLease = nil
                } catch {
                    current.phase = .discardPending
                    throw DocumentPaintSurfaceTransactionError.cleanupFailed
                }
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.restoreEncodingFailed
            }
            current.phase = .restoreEncoded
            return DocumentPaintEncodedRestore(
                coordinatorIdentity: identity,
                sequence: current.sequence
            )
        }
    }

    public func completeRestore(
        _ handle: DocumentPaintEncodedRestore,
        as outcome: RasterRevisionOperationOutcome,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintCompletedRestore {
        try withLock {
            let current = try validatedRestore(handle)
            guard let commandBuffer = current.commandBuffer,
                  let operation = current.installOperation,
                  let binding = current.candidateBinding,
                  let destinationLease = current.destinationLease
            else {
                preconditionFailure("Encoded restore lost owned resources")
            }
            commandBuffer.waitUntilCompleted()
            let completionFailure: TiledRasterRevisionFailureInjection?
            if failureInjection?.shouldFail(at: .restoreCompletion) == true {
                completionFailure = .init(failingAt: .completion)
            } else {
                completionFailure = nil
            }
            do {
                try revisionStore.finalize(
                    operation,
                    as: outcome,
                    failureInjection: completionFailure
                )
                current.installOperation = nil
                current.commandBuffer = nil
                guard outcome == .succeeded else {
                    current.installLease = nil
                    current.phase = .discardPending
                    throw DocumentPaintSurfaceTransactionError
                        .restoreCommandFailed
                }
            } catch let error as DocumentPaintSurfaceTransactionError {
                throw error
            } catch {
                if let installLease = current.installLease {
                    do {
                        let disposition = try revisionStore
                            .abandonInstallForCoordinatorIfOwned(
                                installLease,
                                layerID: installLease.layerID,
                                generation: installLease.generation
                            )
                        if disposition != .cancellationPending {
                            current.installOperation = nil
                            current.commandBuffer = nil
                            current.installLease = nil
                        }
                    } catch {
                        current.phase = .discardPending
                        throw DocumentPaintSurfaceTransactionError.cleanupFailed
                    }
                }
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError
                    .restoreCompletionFailed
            }
            if failureInjection?.shouldFail(
                at: .restoreDestinationLeaseReturn
            ) == true {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError
                    .destinationLeaseReturnFailed
            }
            do {
                try binding.canonical.returnLease(destinationLease)
                current.destinationLease = nil
                current.candidateBinding = nil
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError
                    .destinationLeaseReturnFailed
            }
            current.phase = .restoreCompleted
            return DocumentPaintCompletedRestore(
                coordinatorIdentity: identity,
                sequence: current.sequence
            )
        }
    }

    public func prepareTerminalRestore(
        _ handle: DocumentPaintCompletedRestore,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintTerminalRestore {
        try withLock {
            let current = try validatedRestore(handle)
            if failureInjection?.shouldFail(
                at: .restoreTerminalPreflight
            ) == true {
                throw DocumentPaintSurfaceTransactionError
                    .terminalPreflightFailed
            }
            let prepared: DocumentPaintPreparedCommit
            do {
                if failureInjection?.shouldFail(
                    at: .restoreRegistryPrepare
                ) == true {
                    throw DocumentPaintSurfaceTransactionError
                        .registryPreparationFailed
                }
                prepared = try registry.prepareCommit(current.candidate)
            } catch let error as DocumentPaintSurfaceTransactionError {
                throw error
            } catch {
                throw DocumentPaintSurfaceTransactionError
                    .registryPreparationFailed
            }
            current.result = DocumentPaintSurfaceRestoreResult(
                layerID: current.request.layerID,
                beforeGeneration: current.baseGeneration,
                afterGeneration: current.candidate.generation,
                reference: current.request.reference,
                restoredCoordinates: current.request
                    .expectedInstallDispositions.map(\.coordinate)
            )
            current.preparedCommit = prepared
            current.phase = .restoreTerminalPrepared
            return DocumentPaintTerminalRestore(
                coordinatorIdentity: identity,
                sequence: current.sequence
            )
        }
    }

    public func publishRestore(
        _ handle: DocumentPaintTerminalRestore,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintSurfaceRestoreResult {
        try withLock {
            let current = try validatedRestore(handle)
            guard let prepared = current.preparedCommit,
                  let installLease = current.installLease,
                  let result = current.result
            else {
                preconditionFailure("Terminal restore lost owned resources")
            }
            let consumeFailure: TiledRasterRevisionFailureInjection?
            if failureInjection?.shouldFail(at: .restoreConsume) == true {
                consumeFailure = .init(failingAt: .consumeInstall)
            } else {
                consumeFailure = nil
            }
            do {
                try revisionStore.consumeInstall(
                    installLease,
                    layerID: installLease.layerID,
                    generation: installLease.generation,
                    failureInjection: consumeFailure
                )
            } catch {
                throw DocumentPaintSurfaceTransactionError.restoreConsumeFailed
            }
            registry.commitPreparedForCoordinator(prepared)
            current.installLease = nil
            current.preparedCommit = nil
            current.phase = .published
            lastCompletedSequence = current.sequence
            liveRestore = nil
            return result
        }
    }

    public func encodeMutation(
        _ handle: DocumentPaintPreparedMutation,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintEncodedMutation {
        try withLock {
            let current = try validated(handle)
            let binding: DocumentPaintLayerBinding
            let lease: PaintTileLease
            do {
                binding = try current.candidate.binding(
                    for: current.request.layerID
                )
                lease = try binding.canonical.leaseExistingTiles(
                    at: current.request.dirtyCoordinates,
                    pinReasons: [.dirty, .inFlight]
                )
            } catch {
                throw DocumentPaintSurfaceTransactionError
                    .backendEncodingFailed
            }
            current.candidateBinding = binding
            current.destinationLease = lease
            let destinations = lease.bindings.map {
                DocumentPaintSurfaceMutationDestination(
                    coordinate: $0.descriptor.coordinate,
                    logicalBounds: $0.descriptor.logicalBounds,
                    texture: $0.texture
                )
            }
            do {
                if failureInjection?.shouldFail(at: .mutationEncode) == true {
                    throw DocumentPaintSurfaceTransactionError
                        .backendEncodingFailed
                }
                try mutationBackend.preflight(.mutation(
                    kind: current.request.kind,
                    destinations: destinations
                ))
                current.backendEncoding = try mutationBackend.encode(
                    destinations: destinations
                )
            } catch {
                do {
                    try binding.canonical.returnLease(lease)
                    current.destinationLease = nil
                    current.candidateBinding = nil
                } catch {
                    current.phase = .discardPending
                    throw DocumentPaintSurfaceTransactionError.cleanupFailed
                }
                throw DocumentPaintSurfaceTransactionError.backendEncodingFailed
            }
            current.phase = .mutationEncoded
            return DocumentPaintEncodedMutation(
                coordinatorIdentity: identity,
                sequence: current.sequence
            )
        }
    }

    public func completeMutation(
        _ handle: DocumentPaintEncodedMutation,
        as outcome: RasterRevisionOperationOutcome,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintReducedMutation {
        try withLock {
            let current = try validated(handle)
            guard let encoding = current.backendEncoding,
                  let binding = current.candidateBinding,
                  let lease = current.destinationLease
            else {
                preconditionFailure("Encoded mutation lost owned resources")
            }
            let evidence: [DocumentPaintSurfaceMutationEvidence]
            do {
                if failureInjection?.shouldFail(at: .mutationCompletion) == true {
                    throw DocumentPaintSurfaceTransactionError
                        .backendCompletionFailed
                }
                evidence = try mutationBackend.complete(encoding, as: outcome)
                current.backendEncoding = nil
                guard outcome == .succeeded else {
                    throw DocumentPaintSurfaceTransactionError
                        .mutationCommandFailed
                }
                if failureInjection?.shouldFail(at: .reductionValidation) == true {
                    throw DocumentPaintSurfaceTransactionError
                        .reductionValidationFailed
                }
                current.reduction = try Self.validateReduction(
                    evidence,
                    dirtyCoordinates: current.request.dirtyCoordinates,
                    pixelSize: current.request.candidateGeometry.storagePixelSize
                )
            } catch let transactionError as DocumentPaintSurfaceTransactionError {
                try failAndCleanup(current, preserving: transactionError)
            } catch {
                try failAndCleanup(
                    current,
                    preserving: .backendCompletionFailed
                )
            }

            if failureInjection?.shouldFail(at: .destinationLeaseReturn) == true {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError
                    .destinationLeaseReturnFailed
            }
            do {
                try binding.canonical.returnLease(lease)
                current.destinationLease = nil
                current.candidateBinding = nil
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError
                    .destinationLeaseReturnFailed
            }
            guard let reduction = current.reduction else {
                preconditionFailure("Validated reduction was not retained")
            }
            do {
                if failureInjection?.shouldFail(at: .candidatePrune) == true {
                    throw DocumentPaintSurfaceTransactionError
                        .candidatePruneFailed
                }
                try registry.pruneFullyTransparentCoordinates(
                    reduction.fullyTransparentCoordinates,
                    from: current.candidate,
                    layerID: current.request.layerID
                )
            } catch {
                try failAndCleanup(
                    current,
                    preserving: .candidatePruneFailed
                )
            }
            current.phase = .mutationCompleted
            return DocumentPaintReducedMutation(
                coordinatorIdentity: identity,
                sequence: current.sequence
            )
        }
    }

    public func encodeHistoryCapture(
        _ handle: DocumentPaintReducedMutation,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintEncodedHistory {
        try withLock {
            let current = try validated(handle)
            guard current.request.requiresHistoryPair else {
                throw DocumentPaintSurfaceTransactionError.historyNotRequired
            }
            let candidateBinding: DocumentPaintLayerBinding
            do {
                candidateBinding = try current.candidate.binding(
                    for: current.request.layerID
                )
            } catch {
                try failAndCleanup(
                    current,
                    preserving: .historyCaptureFailed
                )
            }
            current.candidateBinding = candidateBinding

            let endpointCoordinates = Self.historyEndpointCoordinates(
                for: current.request
            )
            let basePresent = Set(
                current.baseBinding.canonical.references.map(\.coordinate)
            )
            let candidatePresent = Set(
                candidateBinding.canonical.references.map(\.coordinate)
            )
            let beforePresent = endpointCoordinates.before.filter(
                basePresent.contains
            )
            let afterPresent = endpointCoordinates.after.filter(
                candidatePresent.contains
            )
            let before: TiledRasterRevisionEndpoint
            let after: TiledRasterRevisionEndpoint
            do {
                before = try TiledRasterRevisionEndpoint(
                    generation: current.baseGeneration,
                    pixelSize: current.request.baseGeometry.storagePixelSize,
                    documentPixelSize:
                        current.request.baseGeometry.documentPixelSize,
                    coordinates: endpointCoordinates.before,
                    presentCoordinates: beforePresent
                )
                after = try TiledRasterRevisionEndpoint(
                    generation: current.candidate.generation,
                    pixelSize:
                        current.request.candidateGeometry.storagePixelSize,
                    documentPixelSize:
                        current.request.candidateGeometry.documentPixelSize,
                    coordinates: endpointCoordinates.after,
                    presentCoordinates: afterPresent
                )
                let allocationFailure = Self.allocationFailure(
                    failureInjection
                )
                current.revisionPair = try revisionStore.allocatePair(
                    layerID: current.request.layerID,
                    before: before,
                    after: after,
                    failureInjection: allocationFailure
                )
            } catch {
                try failAndCleanup(
                    current,
                    preserving: .historyAllocationFailed
                )
            }
            guard let pair = current.revisionPair else {
                preconditionFailure("History pair allocation lost ownership")
            }

            do {
                if !beforePresent.isEmpty {
                    current.baseSourceLease = try current.baseBinding.canonical
                        .leaseExistingTiles(
                            at: beforePresent,
                            pinReasons: [.historyBefore, .inFlight]
                        )
                }
                if !afterPresent.isEmpty {
                    current.candidateSourceLease = try candidateBinding.canonical
                        .leaseExistingTiles(
                            at: afterPresent,
                            pinReasons: [.inFlight]
                        )
                }
                guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                    throw DocumentPaintSurfaceTransactionError
                        .historyCaptureFailed
                }
                commandBuffer.label = "Document Paint History Capture"
                current.historyCommandBuffer = commandBuffer
                let beforeSources = Self.captureSources(
                    coordinates: endpointCoordinates.before,
                    lease: current.baseSourceLease
                )
                let afterSources = Self.captureSources(
                    coordinates: endpointCoordinates.after,
                    lease: current.candidateSourceLease
                )
                current.beforeCapture = try revisionStore.encodeCapture(
                    pair.before,
                    layerID: current.request.layerID,
                    generation: current.baseGeneration,
                    sources: beforeSources,
                    on: commandBuffer,
                    failureInjection: Self.captureFailure(
                        failureInjection,
                        endpointIndex: 0
                    )
                )
                current.afterCapture = try revisionStore.encodeCapture(
                    pair.after,
                    layerID: current.request.layerID,
                    generation: current.candidate.generation,
                    sources: afterSources,
                    on: commandBuffer,
                    failureInjection: Self.captureFailure(
                        failureInjection,
                        endpointIndex: 1
                    )
                )
                commandBuffer.commit()
            } catch {
                if !revisionStore.containsRevision(pair.before.id) {
                    current.revisionPair = nil
                    current.beforeCapture = nil
                    current.afterCapture = nil
                }
                try failAndCleanup(
                    current,
                    preserving: .historyCaptureFailed
                )
            }
            current.phase = .historyEncoded
            return DocumentPaintEncodedHistory(
                coordinatorIdentity: identity,
                sequence: current.sequence
            )
        }
    }

    public func completeHistoryCapture(
        _ handle: DocumentPaintEncodedHistory,
        as outcome: RasterRevisionOperationOutcome,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintCompletedHistory {
        try withLock {
            let current = try validated(handle)
            guard let pair = current.revisionPair,
                  let commandBuffer = current.historyCommandBuffer,
                  let beforeCapture = current.beforeCapture,
                  let afterCapture = current.afterCapture
            else {
                preconditionFailure("Encoded history lost owned resources")
            }
            commandBuffer.waitUntilCompleted()
            do {
                try revisionStore.finalize(
                    beforeCapture,
                    as: outcome,
                    failureInjection: Self.completionFailure(
                        failureInjection,
                        endpointIndex: 0
                    )
                )
                current.beforeCapture = nil
                try revisionStore.finalize(
                    afterCapture,
                    as: outcome,
                    failureInjection: Self.completionFailure(
                        failureInjection,
                        endpointIndex: 1
                    )
                )
                current.afterCapture = nil
                current.historyCommandBuffer = nil
                guard outcome == .succeeded else {
                    throw DocumentPaintSurfaceTransactionError
                        .historyFinalizationFailed
                }
            } catch {
                if !revisionStore.containsRevision(pair.before.id) {
                    current.revisionPair = nil
                    current.beforeCapture = nil
                    current.afterCapture = nil
                    current.historyCommandBuffer = nil
                }
                try failAndCleanup(
                    current,
                    preserving: .historyFinalizationFailed
                )
            }
            if failureInjection?.shouldFail(at: .sourceLeaseReturn) == true {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.sourceLeaseReturnFailed
            }
            do {
                if let lease = current.baseSourceLease {
                    try current.baseBinding.canonical.returnLease(lease)
                    current.baseSourceLease = nil
                }
                if let lease = current.candidateSourceLease {
                    try current.candidateBinding?.canonical.returnLease(lease)
                    current.candidateSourceLease = nil
                }
                current.candidateBinding = nil
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.sourceLeaseReturnFailed
            }
            current.phase = .historyCompleted
            return DocumentPaintCompletedHistory(
                coordinatorIdentity: identity,
                sequence: current.sequence
            )
        }
    }

    public func prepareTerminalCommit(
        _ handle: DocumentPaintCompletedHistory,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintTerminalCommit {
        try prepareTerminalCommit(
            handle,
            requiresHistoryPair: true,
            failureInjection: failureInjection
        )
    }

    public func prepareTerminalCommit(
        _ handle: DocumentPaintReducedMutation,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintTerminalCommit {
        try prepareTerminalCommit(
            handle,
            requiresHistoryPair: false,
            failureInjection: failureInjection
        )
    }

    public func publish(
        _ handle: DocumentPaintTerminalCommit,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintSurfaceCommitResult {
        try withLock {
            let current = try validated(handle)
            guard let prepared = current.preparedCommit,
                  let result = current.commitResult
            else {
                preconditionFailure("Terminal commit lost prepared ownership")
            }
            if let pair = current.revisionPair {
                let revisionFailure: TiledRasterRevisionFailureInjection?
                if failureInjection?.shouldFail(at: .revisionPublish) == true {
                    revisionFailure = TiledRasterRevisionFailureInjection(
                        failingAt: .publish
                    )
                } else {
                    revisionFailure = nil
                }
                do {
                    try revisionStore.publish(
                        pair,
                        failureInjection: revisionFailure
                    )
                } catch {
                    throw DocumentPaintSurfaceTransactionError
                        .revisionPublishFailed
                }
            }
            registry.commitPreparedForCoordinator(prepared)
            current.preparedCommit = nil
            current.phase = .published
            lastCompletedSequence = current.sequence
            live = nil
            return result
        }
    }

    public func discard(
        _ handle: DocumentPaintPreparedMutation,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws { try discardHandle(handle, failureInjection: failureInjection) }

    public func discard(
        _ handle: DocumentPaintEncodedMutation,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws { try discardHandle(handle, failureInjection: failureInjection) }

    public func discard(
        _ handle: DocumentPaintReducedMutation,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws { try discardHandle(handle, failureInjection: failureInjection) }

    public func discard(
        _ handle: DocumentPaintEncodedHistory,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws { try discardHandle(handle, failureInjection: failureInjection) }

    public func discard(
        _ handle: DocumentPaintCompletedHistory,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws { try discardHandle(handle, failureInjection: failureInjection) }

    public func discard(
        _ handle: DocumentPaintTerminalCommit,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws { try discardHandle(handle, failureInjection: failureInjection) }

    public func discard(
        _ handle: DocumentPaintPreparedRestore,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws {
        try discardRestoreHandle(handle, failureInjection: failureInjection)
    }

    public func discard(
        _ handle: DocumentPaintEncodedRestore,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws {
        try discardRestoreHandle(handle, failureInjection: failureInjection)
    }

    public func discard(
        _ handle: DocumentPaintCompletedRestore,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws {
        try discardRestoreHandle(handle, failureInjection: failureInjection)
    }

    public func discard(
        _ handle: DocumentPaintTerminalRestore,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws {
        try discardRestoreHandle(handle, failureInjection: failureInjection)
    }

    public func retryDiscard(
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws {
        try withLock {
            if let current = liveRestore {
                guard current.phase == .discardPending else {
                    throw DocumentPaintSurfaceTransactionError.wrongPhase(
                        expected: .discardPending,
                        actual: current.phase
                    )
                }
                try cleanupRestore(current, failureInjection: failureInjection)
                return
            }
            guard let current = live else {
                throw DocumentPaintSurfaceTransactionError.noLiveTransaction
            }
            guard current.phase == .discardPending else {
                throw DocumentPaintSurfaceTransactionError.wrongPhase(
                    expected: .discardPending,
                    actual: current.phase
                )
            }
            try cleanup(current, failureInjection: failureInjection)
        }
    }

    private func prepareTerminalCommit<
        H: DocumentPaintSurfaceTransactionHandle
    >(
        _ handle: H,
        requiresHistoryPair: Bool,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection?
    ) throws -> DocumentPaintTerminalCommit {
        try withLock {
            let current = try validated(handle)
            guard current.request.requiresHistoryPair == requiresHistoryPair,
                  (requiresHistoryPair
                    ? current.revisionPair != nil
                    : current.revisionPair == nil)
            else {
                throw DocumentPaintSurfaceTransactionError.historyNotRequired
            }
            if failureInjection?.shouldFail(at: .terminalPreflight) == true {
                throw DocumentPaintSurfaceTransactionError
                    .terminalPreflightFailed
            }
            let result = DocumentPaintSurfaceCommitResult(
                layerID: current.request.layerID,
                beforeGeneration: current.baseGeneration,
                afterGeneration: current.candidate.generation,
                dirtyCoordinates: Set(
                    current.request.dirtyCoordinates
                        + current.request.explicitlyRemovedCoordinates
                ).sorted(),
                historyPair: current.revisionPair
            )
            let prepared: DocumentPaintPreparedCommit
            do {
                if failureInjection?.shouldFail(at: .registryPrepare) == true {
                    throw DocumentPaintSurfaceTransactionError
                        .registryPreparationFailed
                }
                prepared = try registry.prepareCommit(current.candidate)
            } catch let error as DocumentPaintSurfaceTransactionError {
                throw error
            } catch {
                throw DocumentPaintSurfaceTransactionError
                    .registryPreparationFailed
            }
            current.preparedCommit = prepared
            current.commitResult = result
            current.phase = .terminalPrepared
            return DocumentPaintTerminalCommit(
                coordinatorIdentity: identity,
                sequence: current.sequence
            )
        }
    }

    private func discardHandle<H: DocumentPaintSurfaceTransactionHandle>(
        _ handle: H,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection?
    ) throws {
        try withLock {
            let current = try validated(handle)
            current.phase = .discardPending
            try cleanup(current, failureInjection: failureInjection)
        }
    }

    private func discardRestoreHandle<
        H: DocumentPaintSurfaceTransactionHandle
    >(
        _ handle: H,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection?
    ) throws {
        try withLock {
            let current = try validatedRestore(handle)
            current.phase = .discardPending
            try cleanupRestore(current, failureInjection: failureInjection)
        }
    }

    private func cleanupRestore(
        _ current: LiveRestore,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection?
    ) throws {
        if failureInjection?.shouldFail(at: .cleanup) == true {
            current.phase = .discardPending
            throw DocumentPaintSurfaceTransactionError.cleanupFailed
        }
        if let operation = current.installOperation {
            current.commandBuffer?.waitUntilCompleted()
            do {
                try revisionStore.finalize(operation, as: .cancelled)
                current.installOperation = nil
                current.commandBuffer = nil
                current.installLease = nil
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.cleanupFailed
            }
        }
        if let installLease = current.installLease {
            do {
                let disposition = try revisionStore
                    .abandonInstallForCoordinatorIfOwned(
                        installLease,
                        layerID: installLease.layerID,
                        generation: installLease.generation
                    )
                guard disposition != .cancellationPending else {
                    current.phase = .discardPending
                    throw DocumentPaintSurfaceTransactionError.cleanupFailed
                }
                current.installLease = nil
            } catch let error as DocumentPaintSurfaceTransactionError {
                throw error
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.cleanupFailed
            }
        }
        if let destinationLease = current.destinationLease,
           let binding = current.candidateBinding {
            do {
                try binding.canonical.returnLease(destinationLease)
                current.destinationLease = nil
                current.candidateBinding = nil
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError
                    .destinationLeaseReturnFailed
            }
        }
        if let prepared = current.preparedCommit {
            registry.cancelPrepared(prepared)
            current.preparedCommit = nil
        } else {
            do {
                try registry.discard(current.candidate)
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.cleanupFailed
            }
        }
        current.phase = .discarded
        lastCompletedSequence = current.sequence
        liveRestore = nil
    }

    private func failAndCleanup(
        _ current: LiveTransaction,
        preserving error: DocumentPaintSurfaceTransactionError
    ) throws -> Never {
        current.phase = .discardPending
        do {
            try cleanup(current, failureInjection: nil)
        } catch {
            throw DocumentPaintSurfaceTransactionError.cleanupFailed
        }
        throw error
    }

    private func cleanup(
        _ current: LiveTransaction,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection?
    ) throws {
        if failureInjection?.shouldFail(at: .cleanup) == true {
            current.phase = .discardPending
            throw DocumentPaintSurfaceTransactionError.cleanupFailed
        }
        if let encoding = current.backendEncoding {
            do {
                try mutationBackend.discardAndWaitUntilTerminal(encoding)
                current.backendEncoding = nil
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.backendDiscardFailed
            }
        }
        if let lease = current.destinationLease,
           let binding = current.candidateBinding {
            do {
                try binding.canonical.returnLease(lease)
                current.destinationLease = nil
                current.candidateBinding = nil
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError
                    .destinationLeaseReturnFailed
            }
        }
        if current.beforeCapture != nil || current.afterCapture != nil {
            current.historyCommandBuffer?.waitUntilCompleted()
            do {
                if let token = current.beforeCapture {
                    try revisionStore.finalize(token, as: .cancelled)
                } else if let token = current.afterCapture {
                    try revisionStore.finalize(token, as: .cancelled)
                }
                current.beforeCapture = nil
                current.afterCapture = nil
                current.historyCommandBuffer = nil
                if let pair = current.revisionPair,
                   !revisionStore.containsRevision(pair.before.id) {
                    current.revisionPair = nil
                }
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.cleanupFailed
            }
        }
        if let lease = current.baseSourceLease {
            do {
                try current.baseBinding.canonical.returnLease(lease)
                current.baseSourceLease = nil
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.sourceLeaseReturnFailed
            }
        }
        if let lease = current.candidateSourceLease,
           let binding = current.candidateBinding {
            do {
                try binding.canonical.returnLease(lease)
                current.candidateSourceLease = nil
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.sourceLeaseReturnFailed
            }
        }
        if let pair = current.revisionPair,
           revisionStore.containsRevision(pair.before.id) {
            do {
                try revisionStore.discard(pair)
                current.revisionPair = nil
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.cleanupFailed
            }
        }
        if let prepared = current.preparedCommit {
            registry.cancelPrepared(prepared)
            current.preparedCommit = nil
        } else {
            do {
                try registry.discard(current.candidate)
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError.cleanupFailed
            }
        }
        current.phase = .discarded
        lastCompletedSequence = current.sequence
        live = nil
    }

    private static func validateReduction(
        _ evidence: [DocumentPaintSurfaceMutationEvidence],
        dirtyCoordinates: [PaintTileCoordinate],
        pixelSize: PixelSize
    ) throws -> DocumentPaintTransparencyReduction {
        let expected = Set(dirtyCoordinates)
        var seen: Set<PaintTileCoordinate> = []
        var transparent: [PaintTileCoordinate] = []
        for item in evidence {
            guard expected.contains(item.coordinate) else {
                throw DocumentPaintSurfaceTransactionError
                    .invalidReductionCoordinate(item.coordinate)
            }
            guard seen.insert(item.coordinate).inserted else {
                throw DocumentPaintSurfaceTransactionError
                    .duplicateReductionCoordinate(item.coordinate)
            }
            let descriptor: PaintTileDescriptor
            do {
                descriptor = try PaintTileDescriptor(
                    coordinate: item.coordinate,
                    logicalPixelSize: pixelSize
                )
            } catch {
                throw DocumentPaintSurfaceTransactionError
                    .invalidReductionCoordinate(item.coordinate)
            }
            guard item.logicalBounds == descriptor.logicalBounds else {
                throw DocumentPaintSurfaceTransactionError
                    .invalidReductionBounds(item.coordinate)
            }
            guard !item.invalid else {
                throw DocumentPaintSurfaceTransactionError
                    .invalidReductionFlag(item.coordinate)
            }
            guard item.maximumAlpha.isFinite,
                  item.maximumAlpha >= 0,
                  item.maximumAlpha <= 1
            else {
                throw DocumentPaintSurfaceTransactionError
                    .invalidReductionAlpha(item.coordinate)
            }
            if item.maximumAlpha == 0 { transparent.append(item.coordinate) }
        }
        if let missing = dirtyCoordinates.first(where: { !seen.contains($0) }) {
            throw DocumentPaintSurfaceTransactionError
                .missingReductionCoordinate(missing)
        }
        return DocumentPaintTransparencyReduction(
            inspectedCoordinates: dirtyCoordinates,
            fullyTransparentCoordinates: transparent.sorted()
        )
    }

    private static func historyEndpointCoordinates(
        for request: DocumentPaintSurfaceMutationRequest
    ) -> (before: [PaintTileCoordinate], after: [PaintTileCoordinate]) {
        let changed = Set(
            request.dirtyCoordinates
                + request.explicitlyRemovedCoordinates
        ).sorted()
        if request.baseGeometry == request.candidateGeometry {
            return (changed, changed)
        }
        return (
            changed.filter {
                isValid(
                    $0,
                    in: request.baseGeometry.storagePixelSize
                )
            },
            changed.filter {
                isValid(
                    $0,
                    in: request.candidateGeometry.storagePixelSize
                )
            }
        )
    }

    private static func isValid(
        _ coordinate: PaintTileCoordinate,
        in size: PixelSize
    ) -> Bool {
        do {
            _ = try PaintTileDescriptor(
                coordinate: coordinate,
                logicalPixelSize: size
            )
            return true
        } catch {
            return false
        }
    }

    private static func captureSources(
        coordinates: [PaintTileCoordinate],
        lease: PaintTileLease?
    ) -> [TiledRasterRevisionTileSource] {
        let textures = Dictionary(
            uniqueKeysWithValues: (lease?.bindings ?? []).map {
                ($0.descriptor.coordinate, $0.texture)
            }
        )
        return coordinates.map { coordinate in
            if let texture = textures[coordinate] {
                return .texture(coordinate: coordinate, texture: texture)
            }
            return .knownClear(coordinate: coordinate)
        }
    }

    private static func allocationFailure(
        _ injection: DocumentPaintSurfaceTransactionFailureInjection?
    ) -> TiledRasterRevisionFailureInjection? {
        guard case let .historyAllocation(index)? = injection?.failingPoint
        else { return nil }
        return TiledRasterRevisionFailureInjection(
            failingAt: .bufferAllocation(index)
        )
    }

    private static func candidateAllocationFailure(
        _ injection: DocumentPaintSurfaceTransactionFailureInjection?
    ) -> PaintTileAllocationFailureInjection? {
        guard case let .candidateReserve(index)? = injection?.failingPoint
        else { return nil }
        return PaintTileAllocationFailureInjection(
            failingAtReserveIndex: index
        )
    }

    private static func captureFailure(
        _ injection: DocumentPaintSurfaceTransactionFailureInjection?,
        endpointIndex: Int
    ) -> TiledRasterRevisionFailureInjection? {
        if injection?.shouldFail(at: .historyEncoding) == true {
            return TiledRasterRevisionFailureInjection(
                failingAt: .commandEncoding
            )
        }
        guard injection?.shouldFail(at: .historyCapture(endpointIndex)) == true
        else { return nil }
        return TiledRasterRevisionFailureInjection(failingAt: .tileCapture(0))
    }

    private static func completionFailure(
        _ injection: DocumentPaintSurfaceTransactionFailureInjection?,
        endpointIndex: Int
    ) -> TiledRasterRevisionFailureInjection? {
        guard injection?.shouldFail(at: .historyCompletion(endpointIndex)) == true
        else { return nil }
        return TiledRasterRevisionFailureInjection(failingAt: .completion)
    }

    private func validated<H: DocumentPaintSurfaceTransactionHandle>(
        _ handle: H
    ) throws -> LiveTransaction {
        guard handle.coordinatorIdentity == identity else {
            throw DocumentPaintSurfaceTransactionError.foreignHandle
        }
        guard let live else {
            if handle.sequence <= lastCompletedSequence {
                throw DocumentPaintSurfaceTransactionError.staleHandle
            }
            throw DocumentPaintSurfaceTransactionError.noLiveTransaction
        }
        guard handle.sequence == live.sequence else {
            throw DocumentPaintSurfaceTransactionError.staleHandle
        }
        guard handle.phase == live.phase else {
            if handle.phase.rawValue < live.phase.rawValue {
                throw DocumentPaintSurfaceTransactionError
                    .handleAlreadyConsumed
            }
            throw DocumentPaintSurfaceTransactionError.wrongPhase(
                expected: live.phase,
                actual: handle.phase
            )
        }
        return live
    }

    private func validatedRestore<
        H: DocumentPaintSurfaceTransactionHandle
    >(
        _ handle: H
    ) throws -> LiveRestore {
        guard handle.coordinatorIdentity == identity else {
            throw DocumentPaintSurfaceTransactionError.foreignHandle
        }
        guard let liveRestore else {
            if handle.sequence <= lastCompletedSequence {
                throw DocumentPaintSurfaceTransactionError.staleHandle
            }
            throw DocumentPaintSurfaceTransactionError.noLiveTransaction
        }
        guard handle.sequence == liveRestore.sequence else {
            throw DocumentPaintSurfaceTransactionError.staleHandle
        }
        guard handle.phase == liveRestore.phase else {
            if handle.phase.rawValue < liveRestore.phase.rawValue {
                throw DocumentPaintSurfaceTransactionError
                    .handleAlreadyConsumed
            }
            throw DocumentPaintSurfaceTransactionError.wrongPhase(
                expected: liveRestore.phase,
                actual: handle.phase
            )
        }
        return liveRestore
    }

    private func abandonRestoreInstall(
        _ lease: TiledRasterRevisionInstallLease
    ) throws {
        do {
            let disposition = try revisionStore
                .abandonInstallForCoordinatorIfOwned(
                    lease,
                    layerID: lease.layerID,
                    generation: lease.generation
                )
            guard disposition != .cancellationPending else {
                throw DocumentPaintSurfaceTransactionError.cleanupFailed
            }
        } catch let error as DocumentPaintSurfaceTransactionError {
            throw error
        } catch {
            throw DocumentPaintSurfaceTransactionError.cleanupFailed
        }
    }

    private static func validateRestoreExpectations(
        _ expectations: [DocumentPaintSurfaceRestoreTileExpectation]
    ) throws {
        for index in expectations.indices.dropFirst() {
            let previous = expectations[index - 1].coordinate
            let current = expectations[index].coordinate
            if previous == current {
                throw DocumentPaintSurfaceTransactionError
                    .duplicateCoordinate(current)
            }
            guard previous < current else {
                throw DocumentPaintSurfaceTransactionError
                    .unsortedCoordinate(previous: previous, current: current)
            }
        }
    }

    private static func validateRestoreDestinations(
        _ destinations: [DocumentPaintSurfaceMutationDestination],
        expected: [DocumentPaintSurfaceRestoreTileExpectation]
    ) throws {
        let replacementCoordinates = expected.compactMap {
            $0.disposition == .replace ? $0.coordinate : nil
        }
        guard destinations.map(\.coordinate) == replacementCoordinates else {
            throw DocumentPaintSurfaceTransactionError
                .restoreDispositionMismatch
        }
        for destination in destinations {
            guard destination.texture.pixelFormat
                    == PaintTileDescriptor.pixelFormat,
                  destination.texture.width == PaintTileDescriptor.side,
                  destination.texture.height == PaintTileDescriptor.side
            else {
                throw DocumentPaintSurfaceTransactionError
                    .restoreEncodingFailed
            }
        }
    }

    private static func validateSortedUnique(
        _ coordinates: [PaintTileCoordinate]
    ) throws {
        for index in coordinates.indices.dropFirst() {
            let previous = coordinates[index - 1]
            let current = coordinates[index]
            if previous == current {
                throw DocumentPaintSurfaceTransactionError
                    .duplicateCoordinate(current)
            }
            guard previous < current else {
                throw DocumentPaintSurfaceTransactionError
                    .unsortedCoordinate(previous: previous, current: current)
            }
        }
    }

    private static func validate(
        _ coordinate: PaintTileCoordinate,
        in size: PixelSize,
        outside transactionError: DocumentPaintSurfaceTransactionError
    ) throws {
        do {
            _ = try PaintTileDescriptor(
                coordinate: coordinate,
                logicalPixelSize: size
            )
        } catch {
            throw transactionError
        }
    }

    private static func publicState(
        for phase: DocumentPaintSurfaceTransactionPhase
    ) -> DocumentPaintSurfaceTransactionState {
        switch phase {
        case .prepared, .mutationEncoded:
            .live
        case .mutationCompleted:
            .reducing
        case .historyEncoded, .historyCompleted:
            .capturing
        case .terminalPrepared, .restoreTerminalPrepared:
            .terminalReady
        case .discardPending:
            .discardPending
        case .restorePrepared, .restoreEncoded, .restoreCompleted:
            .live
        case .published, .discarded:
            .idle
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
