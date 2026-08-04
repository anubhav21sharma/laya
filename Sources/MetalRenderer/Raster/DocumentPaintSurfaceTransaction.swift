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
    case invalidResizeMapping
    case invalidEncodedImport(DocumentColorInterchangeError)
    case encodedImportGeometryMismatch(expected: PixelSize, actual: PixelSize)
    case encodedImportRadialUnsupported
    case emptyMutation
    case missingStrokeAuthoritativeLease
    case invalidStrokeCompositeParameters
    case strokeSourceStoreMismatch
    case strokeSourceOwnerMismatch
    case strokeSourceLayerMismatch(expected: UUID, actual: UUID)
    case strokeSourceGenerationMismatch(expected: UInt64, actual: UInt64)
    case strokeSourceGeometryMismatch(expected: PixelSize, actual: PixelSize)
    case strokeSourceRadialLayoutMismatch
    case strokeSourceCoordinateMismatch
    case strokeTextureAlias
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

/// Complete, immutable encoded-interchange source for opening a document.
/// Import is always a full candidate replacement without an undo-history pair;
/// the caller resets editor history only after publication succeeds.
public struct DocumentPaintSurfaceEncodedImportRequest: Equatable, Sendable {
    public let layerID: UUID
    public let candidateGeometry: DocumentPaintGeometry
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let encodedPremultipliedBGRA8: Data

    public init(
        layerID: UUID,
        candidateGeometry: DocumentPaintGeometry,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        encodedPremultipliedBGRA8: Data
    ) {
        self.layerID = layerID
        self.candidateGeometry = candidateGeometry
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.encodedPremultipliedBGRA8 = Data(encodedPremultipliedBGRA8)
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

/// Internal ownership-only observability for failure/quiescence gates. Tests
/// can prove every owned category returns to its exact retryable baseline
/// without exposing these identities through the public API.
struct DocumentPaintSurfaceTransactionOwnershipSnapshot:
    Equatable, Sendable
{
    let candidateIdentity: ObjectIdentifier?
    let preparedCommitIdentity: ObjectIdentifier?
    let commandBufferIdentity: ObjectIdentifier?
    let destinationLeaseID: PaintTileLeaseID?
    let resizeSourceLeaseID: PaintTileLeaseID?
    let strokeBaseSourceLeaseID: PaintTileLeaseID?
    let strokeAuthoritativeSourceLeaseID: PaintTileLeaseID?
    let baseSourceLeaseID: PaintTileLeaseID?
    let candidateSourceLeaseID: PaintTileLeaseID?
    let backendEncodingID: UUID?
    let revisionPair: PendingRasterRevisionPair?
    let beforeCapture: TiledRasterRevisionOperationToken?
    let afterCapture: TiledRasterRevisionOperationToken?
    let installOperation: TiledRasterRevisionOperationToken?
    let installLease: TiledRasterRevisionInstallLease?
    let reduction: DocumentPaintTransparencyReduction?
    let commitResult: DocumentPaintSurfaceCommitResult?
    let restoreResult: DocumentPaintSurfaceRestoreResult?
    let hasResizePlan: Bool
    let hasEncodedImportPlan: Bool
    let candidateCount: Int
    let candidateBindingCount: Int
    let destinationLeaseCount: Int
    let sourceLeaseCount: Int
    let backendEncodingCount: Int
    let revisionPairCount: Int
    let commandBufferCount: Int
    let revisionOperationCount: Int
    let installLeaseCount: Int
    let preparedCommitCount: Int

    static let empty = Self(
        candidateIdentity: nil,
        preparedCommitIdentity: nil,
        commandBufferIdentity: nil,
        destinationLeaseID: nil,
        resizeSourceLeaseID: nil,
        strokeBaseSourceLeaseID: nil,
        strokeAuthoritativeSourceLeaseID: nil,
        baseSourceLeaseID: nil,
        candidateSourceLeaseID: nil,
        backendEncodingID: nil,
        revisionPair: nil,
        beforeCapture: nil,
        afterCapture: nil,
        installOperation: nil,
        installLease: nil,
        reduction: nil,
        commitResult: nil,
        restoreResult: nil,
        hasResizePlan: false,
        hasEncodedImportPlan: false,
        candidateCount: 0,
        candidateBindingCount: 0,
        destinationLeaseCount: 0,
        sourceLeaseCount: 0,
        backendEncodingCount: 0,
        revisionPairCount: 0,
        commandBufferCount: 0,
        revisionOperationCount: 0,
        installLeaseCount: 0,
        preparedCommitCount: 0
    )
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

struct DocumentPaintSurfaceMutationSource: @unchecked Sendable {
    let coordinate: PaintTileCoordinate
    let logicalBounds: PixelRect
    let texture: any MTLTexture
}

enum DocumentPaintSurfaceReadSource: @unchecked Sendable {
    case knownClear(
        coordinate: PaintTileCoordinate,
        logicalBounds: PixelRect
    )
    case texture(DocumentPaintSurfaceMutationSource)

    var coordinate: PaintTileCoordinate {
        switch self {
        case let .knownClear(coordinate, _): coordinate
        case let .texture(source): source.coordinate
        }
    }

    var logicalBounds: PixelRect {
        switch self {
        case let .knownClear(_, logicalBounds): logicalBounds
        case let .texture(source): source.logicalBounds
        }
    }
}

struct DocumentPaintStrokeCompositeParameters: Equatable, Sendable {
    let mode: StrokeCompositeMode
    let strokeOpacity: Float
    let accumulationLimit: Float
    let eraserStrength: Float

    static let opaqueDraw = Self(
        mode: .draw,
        strokeOpacity: 1,
        accumulationLimit: 1,
        eraserStrength: 1
    )

    var isValid: Bool {
        strokeOpacity.isFinite && (0...1).contains(strokeOpacity)
            && accumulationLimit.isFinite
            && (0...1).contains(accumulationLimit)
            && eraserStrength.isFinite
            && (0...1).contains(eraserStrength)
    }
}

struct DocumentPaintSurfaceStrokeBackendPayload: @unchecked Sendable {
    let geometry: DocumentPaintGeometry
    let compositeParameters: DocumentPaintStrokeCompositeParameters
    let baseSources: [DocumentPaintSurfaceReadSource]
    let authoritativeSources: [DocumentPaintSurfaceReadSource]
    let destinations: [DocumentPaintSurfaceMutationDestination]
}

struct DocumentPaintSurfaceResizeCopyMapping: Equatable, Sendable {
    let sourceCoordinate: PaintTileCoordinate
    let destinationCoordinate: PaintTileCoordinate
    let sourceOrigin: SIMD2<Int>
    let destinationOrigin: SIMD2<Int>
    let extent: PixelSize
    let logicalPage: RadialPageCoordinate?
    let masksToTargetOrbit: Bool
}

struct DocumentPaintSurfaceResizeBackendPayload: @unchecked Sendable {
    let sourceGeometry: DocumentPaintGeometry
    let candidateGeometry: DocumentPaintGeometry
    let clearsDestinationsBeforeCopy: Bool
    let sources: [DocumentPaintSurfaceMutationSource]
    let destinations: [DocumentPaintSurfaceMutationDestination]
    let mappings: [DocumentPaintSurfaceResizeCopyMapping]
}

enum DocumentPaintSurfaceEncodedImportConversion: Equatable, Sendable {
    /// For each texel: alpha-zero discards encoded RGB; otherwise divide the
    /// encoded RGB bytes by encoded alpha, clamp tolerant C8>A8 input to straight
    /// [0, 1], decode straight sRGB to linear, then premultiply linear RGB by
    /// alpha and store RGBA16F.
    case encodedPremultipliedSRGBBGRA8ToLinearPremultipliedRGBA16Float
}

struct DocumentPaintSurfaceEncodedImportTileRegion: Equatable, Sendable {
    let coordinate: PaintTileCoordinate
    let sourceOrigin: SIMD2<Int>
    let sourceByteOffset: Int
    let destinationOrigin: SIMD2<Int>
    let extent: PixelSize
}

struct DocumentPaintSurfaceEncodedImportBackendPayload: @unchecked Sendable {
    let candidateGeometry: DocumentPaintGeometry
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let encodedPremultipliedBGRA8: Data
    let conversion: DocumentPaintSurfaceEncodedImportConversion
    let clearsDestinationsBeforeConversion: Bool
    let destinations: [DocumentPaintSurfaceMutationDestination]
    let tileRegions: [DocumentPaintSurfaceEncodedImportTileRegion]
}

/// Complete restore payload presented to the inert backend preflight. It is
/// deliberately typed and contains no candidate, install lease, or registry
/// commit token.
struct DocumentPaintSurfaceRestoreBackendPayload: @unchecked Sendable {
    let reference: RasterRevisionReference
    let destinations: [DocumentPaintSurfaceMutationDestination]
}

enum DocumentPaintSurfaceBackendOperation: @unchecked Sendable {
    case stroke(DocumentPaintSurfaceStrokeBackendPayload)
    case clear
    case resize(DocumentPaintSurfaceResizeBackendPayload)
    case encodedImport(DocumentPaintSurfaceEncodedImportBackendPayload)
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

    func encode(_ operation: DocumentPaintSurfaceBackendOperation) throws
        -> DocumentPaintSurfaceMutationBackendEncoding

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
    private struct ResizePlan: Sendable {
        let sourceCoordinates: [PaintTileCoordinate]
        let beforeCoordinates: [PaintTileCoordinate]
        let afterCoordinates: [PaintTileCoordinate]
        let removedCoordinates: [PaintTileCoordinate]
        let mappings: [DocumentPaintSurfaceResizeCopyMapping]
    }

    private struct EncodedImportPlan: Sendable {
        let request: DocumentPaintSurfaceEncodedImportRequest
        let dirtyCoordinates: [PaintTileCoordinate]
        let tileRegions: [DocumentPaintSurfaceEncodedImportTileRegion]
    }

    private final class LiveTransaction {
        let sequence: UInt64
        let request: DocumentPaintSurfaceMutationRequest
        let baseGeneration: UInt64
        let baseBinding: DocumentPaintLayerBinding
        let candidate: DocumentPaintSurfaceCandidate
        let resizePlan: ResizePlan?
        let encodedImportPlan: EncodedImportPlan?
        var phase: DocumentPaintSurfaceTransactionPhase

        var candidateBinding: DocumentPaintLayerBinding?
        var destinationLease: PaintTileLease?
        var resizeSourceLease: PaintTileLease?
        var strokeBaseSourceLease: PaintTileLease?
        var strokeAuthoritativeSourceOwner: StrokeTileSurfaceEncoder?
        var strokeAuthoritativeSourceLease:
            StrokeAuthoritativeMutationLease?
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
            resizePlan: ResizePlan?,
            encodedImportPlan: EncodedImportPlan?,
            phase: DocumentPaintSurfaceTransactionPhase
        ) {
            self.sequence = sequence
            self.request = request
            self.baseGeneration = baseGeneration
            self.baseBinding = baseBinding
            self.candidate = candidate
            self.resizePlan = resizePlan
            self.encodedImportPlan = encodedImportPlan
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
    private let allowKnownClearAuthoritativeStrokeSourcesForTesting: Bool
    private let afterBaseSnapshotForTesting: (@Sendable () throws -> Void)?
    private let afterEncodedImportReplacementAuthorityForTesting:
        (@Sendable () throws -> Void)?
    private var nextSequence: UInt64 = 1
    private var lastCompletedSequence: UInt64 = 0
    private var live: LiveTransaction?
    private var liveRestore: LiveRestore?

    init(
        registry: DocumentPaintSurfaceStore,
        revisionStore: TiledRasterRevisionStore,
        commandQueue: any MTLCommandQueue,
        mutationBackend: any DocumentPaintSurfaceMutationBackend,
        allowKnownClearAuthoritativeStrokeSourcesForTesting: Bool = false,
        afterBaseSnapshotForTesting: (@Sendable () throws -> Void)? = nil,
        afterEncodedImportReplacementAuthorityForTesting:
            (@Sendable () throws -> Void)? = nil
    ) {
        self.registry = registry
        self.revisionStore = revisionStore
        self.commandQueue = commandQueue
        self.mutationBackend = mutationBackend
        #if DEBUG
        self.allowKnownClearAuthoritativeStrokeSourcesForTesting =
            allowKnownClearAuthoritativeStrokeSourcesForTesting
        #else
        self.allowKnownClearAuthoritativeStrokeSourcesForTesting = false
        #endif
        self.afterBaseSnapshotForTesting = afterBaseSnapshotForTesting
        self.afterEncodedImportReplacementAuthorityForTesting =
            afterEncodedImportReplacementAuthorityForTesting
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

    func ownershipSnapshotForTesting()
        -> DocumentPaintSurfaceTransactionOwnershipSnapshot
    {
        withLock {
            if let live {
                return .init(
                    candidateIdentity: ObjectIdentifier(live.candidate),
                    preparedCommitIdentity: live.preparedCommit.map(
                        ObjectIdentifier.init
                    ),
                    commandBufferIdentity: live.historyCommandBuffer.map {
                        ObjectIdentifier($0)
                    },
                    destinationLeaseID: live.destinationLease?.id,
                    resizeSourceLeaseID: live.resizeSourceLease?.id,
                    strokeBaseSourceLeaseID:
                        live.strokeBaseSourceLease?.id,
                    strokeAuthoritativeSourceLeaseID:
                        live.strokeAuthoritativeSourceLease?.id,
                    baseSourceLeaseID: live.baseSourceLease?.id,
                    candidateSourceLeaseID: live.candidateSourceLease?.id,
                    backendEncodingID: live.backendEncoding?.rawValue,
                    revisionPair: live.revisionPair,
                    beforeCapture: live.beforeCapture,
                    afterCapture: live.afterCapture,
                    installOperation: nil,
                    installLease: nil,
                    reduction: live.reduction,
                    commitResult: live.commitResult,
                    restoreResult: nil,
                    hasResizePlan: live.resizePlan != nil,
                    hasEncodedImportPlan: live.encodedImportPlan != nil,
                    candidateCount: 1,
                    candidateBindingCount: live.candidateBinding == nil ? 0 : 1,
                    destinationLeaseCount: live.destinationLease == nil ? 0 : 1,
                    sourceLeaseCount: [
                        live.resizeSourceLease,
                        live.strokeBaseSourceLease,
                        live.baseSourceLease,
                        live.candidateSourceLease,
                    ].compactMap { $0 }.count
                        + (live.strokeAuthoritativeSourceLease == nil ? 0 : 1),
                    backendEncodingCount: live.backendEncoding == nil ? 0 : 1,
                    revisionPairCount: live.revisionPair == nil ? 0 : 1,
                    commandBufferCount:
                        live.historyCommandBuffer == nil ? 0 : 1,
                    revisionOperationCount: [
                        live.beforeCapture,
                        live.afterCapture,
                    ].compactMap { $0 }.count,
                    installLeaseCount: 0,
                    preparedCommitCount: live.preparedCommit == nil ? 0 : 1
                )
            }
            if let liveRestore {
                return .init(
                    candidateIdentity: ObjectIdentifier(liveRestore.candidate),
                    preparedCommitIdentity: liveRestore.preparedCommit.map(
                        ObjectIdentifier.init
                    ),
                    commandBufferIdentity: liveRestore.commandBuffer.map {
                        ObjectIdentifier($0)
                    },
                    destinationLeaseID: liveRestore.destinationLease?.id,
                    resizeSourceLeaseID: nil,
                    strokeBaseSourceLeaseID: nil,
                    strokeAuthoritativeSourceLeaseID: nil,
                    baseSourceLeaseID: nil,
                    candidateSourceLeaseID: nil,
                    backendEncodingID: nil,
                    revisionPair: nil,
                    beforeCapture: nil,
                    afterCapture: nil,
                    installOperation: liveRestore.installOperation,
                    installLease: liveRestore.installLease,
                    reduction: nil,
                    commitResult: nil,
                    restoreResult: liveRestore.result,
                    hasResizePlan: false,
                    hasEncodedImportPlan: false,
                    candidateCount: 1,
                    candidateBindingCount:
                        liveRestore.candidateBinding == nil ? 0 : 1,
                    destinationLeaseCount:
                        liveRestore.destinationLease == nil ? 0 : 1,
                    sourceLeaseCount: 0,
                    backendEncodingCount: 0,
                    revisionPairCount: 0,
                    commandBufferCount:
                        liveRestore.commandBuffer == nil ? 0 : 1,
                    revisionOperationCount:
                        liveRestore.installOperation == nil ? 0 : 1,
                    installLeaseCount:
                        liveRestore.installLease == nil ? 0 : 1,
                    preparedCommitCount:
                        liveRestore.preparedCommit == nil ? 0 : 1
                )
            }
            return .empty
        }
    }

    public func prepareMutation(
        _ request: DocumentPaintSurfaceMutationRequest,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintMutationPreparation {
        guard request.kind != .encodedImport else {
            throw DocumentPaintSurfaceTransactionError
                .unsupportedMutationKind(.encodedImport)
        }
        return try prepareMutation(
            request,
            failureInjection: failureInjection,
            encodedImportPlan: nil
        )
    }

    public func prepareEncodedImport(
        _ request: DocumentPaintSurfaceEncodedImportRequest,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintMutationPreparation {
        let importPlan = try Self.makeEncodedImportPlan(request)
        return try prepareMutation(
            nil,
            failureInjection: failureInjection,
            encodedImportPlan: importPlan
        )
    }

    private func prepareMutation(
        _ suppliedRequest: DocumentPaintSurfaceMutationRequest?,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection?,
        encodedImportPlan: EncodedImportPlan?
    ) throws -> DocumentPaintMutationPreparation {
        try withLock {
            guard live == nil, liveRestore == nil else {
                throw DocumentPaintSurfaceTransactionError
                    .transactionAlreadyLive
            }
            let targetLayerID: UUID
            if let suppliedRequest {
                guard suppliedRequest.kind != .restore else {
                    throw DocumentPaintSurfaceTransactionError
                        .unsupportedMutationKind(suppliedRequest.kind)
                }
                guard encodedImportPlan == nil else {
                    throw DocumentPaintSurfaceTransactionError
                        .unsupportedMutationKind(suppliedRequest.kind)
                }
                targetLayerID = suppliedRequest.layerID
            } else if let encodedImportPlan {
                targetLayerID = encodedImportPlan.request.layerID
            } else {
                throw DocumentPaintSurfaceTransactionError
                    .unsupportedMutationKind(.encodedImport)
            }
            let base: DocumentPaintSurfaceMutationBaseSnapshot
            do {
                base = try registry.captureMutationBase(
                    for: targetLayerID
                )
            } catch DocumentPaintSurfaceStoreError.unknownLayerID {
                throw DocumentPaintSurfaceTransactionError
                    .unknownLayerID(targetLayerID)
            }
            try afterBaseSnapshotForTesting?()
            let request: DocumentPaintSurfaceMutationRequest
            if let suppliedRequest {
                request = suppliedRequest
            } else if let encodedImportPlan {
                let dirty = Set(encodedImportPlan.dirtyCoordinates)
                let removals = base.binding.canonical.references
                    .map(\.coordinate)
                    .filter { !dirty.contains($0) }
                request = DocumentPaintSurfaceMutationRequest(
                    kind: .encodedImport,
                    layerID: encodedImportPlan.request.layerID,
                    baseGeometry: base.geometry,
                    candidateGeometry:
                        encodedImportPlan.request.candidateGeometry,
                    dirtyCoordinates: encodedImportPlan.dirtyCoordinates,
                    explicitlyRemovedCoordinates: removals,
                    requiresHistoryPair: false
                )
            } else {
                preconditionFailure("Mutation preparation source was lost")
            }
            if request.kind == .encodedImport {
                try afterEncodedImportReplacementAuthorityForTesting?()
                guard let encodedImportPlan,
                      encodedImportPlan.request.layerID == request.layerID,
                      encodedImportPlan.request.candidateGeometry
                        == request.candidateGeometry,
                      !request.requiresHistoryPair
                else {
                    throw DocumentPaintSurfaceTransactionError
                        .unsupportedMutationKind(request.kind)
                }
            }
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
            let resizePlan: ResizePlan?
            if request.kind == .resize {
                guard request.candidateGeometry != request.baseGeometry else {
                    throw DocumentPaintSurfaceTransactionError
                        .invalidResizeMapping
                }
                resizePlan = try Self.makeResizePlan(
                    baseCoordinates: baseCoordinates,
                    sourceGeometry: request.baseGeometry,
                    candidateGeometry: request.candidateGeometry
                )
                guard request.dirtyCoordinates == resizePlan?.afterCoordinates,
                      request.explicitlyRemovedCoordinates
                        == resizePlan?.removedCoordinates
                else {
                    throw DocumentPaintSurfaceTransactionError
                        .invalidResizeMapping
                }
            } else {
                resizePlan = nil
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
            } else if request.kind == .encodedImport,
                      request.candidateGeometry == request.baseGeometry,
                      baseCoordinates.isEmpty,
                      request.dirtyCoordinates.isEmpty,
                      request.explicitlyRemovedCoordinates.isEmpty {
                return .noOp(DocumentPaintSurfaceNoOp(
                    kind: .encodedImport,
                    layerID: request.layerID,
                    generation: base.generation
                ))
            } else if request.dirtyCoordinates.isEmpty,
                      request.explicitlyRemovedCoordinates.isEmpty,
                      !(request.kind == .resize
                          && request.candidateGeometry != request.baseGeometry),
                      !(request.kind == .encodedImport
                          && request.candidateGeometry != request.baseGeometry) {
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
                resizePlan: resizePlan,
                encodedImportPlan: encodedImportPlan,
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
            commitPreparedTerminal(prepared)
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
        try encodeMutation(
            handle,
            strokeSourceOwner: nil,
            strokeSourceLease: nil,
            strokeCompositeParameters: nil,
            failureInjection: failureInjection
        )
    }

    func encodeStrokeMutation(
        _ handle: DocumentPaintPreparedMutation,
        sourceOwner: StrokeTileSurfaceEncoder,
        sourceLease: StrokeAuthoritativeMutationLease,
        compositeParameters: DocumentPaintStrokeCompositeParameters,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection? = nil
    ) throws -> DocumentPaintEncodedMutation {
        try encodeMutation(
            handle,
            strokeSourceOwner: sourceOwner,
            strokeSourceLease: sourceLease,
            strokeCompositeParameters: compositeParameters,
            failureInjection: failureInjection
        )
    }

    private func encodeMutation(
        _ handle: DocumentPaintPreparedMutation,
        strokeSourceOwner: StrokeTileSurfaceEncoder?,
        strokeSourceLease: StrokeAuthoritativeMutationLease?,
        strokeCompositeParameters: DocumentPaintStrokeCompositeParameters?,
        failureInjection: DocumentPaintSurfaceTransactionFailureInjection?
    ) throws -> DocumentPaintEncodedMutation {
        try withLock {
            let current = try validated(handle)
            let binding: DocumentPaintLayerBinding
            let lease: PaintTileLease?
            do {
                binding = try current.candidate.binding(
                    for: current.request.layerID
                )
                if current.request.dirtyCoordinates.isEmpty {
                    lease = nil
                } else {
                    lease = try binding.canonical.leaseExistingTiles(
                        at: current.request.dirtyCoordinates,
                        pinReasons: [.dirty, .inFlight]
                    )
                }
            } catch {
                throw DocumentPaintSurfaceTransactionError
                    .backendEncodingFailed
            }
            current.candidateBinding = binding
            current.destinationLease = lease
            let destinations = (lease?.bindings ?? []).map {
                DocumentPaintSurfaceMutationDestination(
                    coordinate: $0.descriptor.coordinate,
                    logicalBounds: $0.descriptor.logicalBounds,
                    texture: $0.texture
                )
            }
            let operation: DocumentPaintSurfaceBackendOperation
            if let importPlan = current.encodedImportPlan {
                do {
                    try Self.validateEncodedImportBindings(
                        destinations: destinations,
                        plan: importPlan
                    )
                    operation = .encodedImport(
                        DocumentPaintSurfaceEncodedImportBackendPayload(
                            candidateGeometry:
                                importPlan.request.candidateGeometry,
                            width: importPlan.request.width,
                            height: importPlan.request.height,
                            bytesPerRow: importPlan.request.bytesPerRow,
                            encodedPremultipliedBGRA8: importPlan.request
                                .encodedPremultipliedBGRA8,
                            conversion:
                                .encodedPremultipliedSRGBBGRA8ToLinearPremultipliedRGBA16Float,
                            clearsDestinationsBeforeConversion: true,
                            destinations: destinations,
                            tileRegions: importPlan.tileRegions
                        )
                    )
                } catch {
                    do {
                        if let lease {
                            try binding.canonical.returnLease(lease)
                        }
                        current.destinationLease = nil
                        current.candidateBinding = nil
                    } catch {
                        current.phase = .discardPending
                        throw DocumentPaintSurfaceTransactionError.cleanupFailed
                    }
                    throw DocumentPaintSurfaceTransactionError
                        .backendEncodingFailed
                }
            } else if let resizePlan = current.resizePlan {
                do {
                    if !resizePlan.sourceCoordinates.isEmpty {
                        current.resizeSourceLease = try current.baseBinding
                            .canonical.leaseExistingTiles(
                                at: resizePlan.sourceCoordinates,
                                pinReasons: [.inFlight]
                            )
                    }
                    let sources = (current.resizeSourceLease?.bindings ?? [])
                        .map {
                            DocumentPaintSurfaceMutationSource(
                                coordinate: $0.descriptor.coordinate,
                                logicalBounds: $0.descriptor.logicalBounds,
                                texture: $0.texture
                            )
                        }
                    try Self.validateResizeBindings(
                        sources: sources,
                        destinations: destinations,
                        plan: resizePlan
                    )
                    operation = .resize(
                        DocumentPaintSurfaceResizeBackendPayload(
                            sourceGeometry: current.request.baseGeometry,
                            candidateGeometry:
                                current.request.candidateGeometry,
                            clearsDestinationsBeforeCopy: true,
                            sources: sources,
                            destinations: destinations,
                            mappings: resizePlan.mappings
                        )
                    )
                } catch {
                    do {
                        if let sourceLease = current.resizeSourceLease {
                            try current.baseBinding.canonical.returnLease(
                                sourceLease
                            )
                            current.resizeSourceLease = nil
                        }
                        if let lease {
                            try binding.canonical.returnLease(lease)
                        }
                        current.destinationLease = nil
                        current.candidateBinding = nil
                    } catch {
                        current.phase = .discardPending
                        throw DocumentPaintSurfaceTransactionError.cleanupFailed
                    }
                    throw DocumentPaintSurfaceTransactionError
                        .backendEncodingFailed
                }
            } else if current.request.kind == .clear {
                operation = .clear
            } else if current.request.kind == .stroke {
                do {
                    let authoritativeSources:
                        [DocumentPaintSurfaceReadSource]
                    let compositeParameters:
                        DocumentPaintStrokeCompositeParameters
                    if let strokeSourceOwner,
                       let strokeSourceLease,
                       let suppliedParameters = strokeCompositeParameters {
                        try Self.validateStrokeAuthoritativeSource(
                            strokeSourceLease,
                            owner: strokeSourceOwner,
                            registry: registry,
                            request: current.request,
                            generation: current.baseGeneration
                        )
                        guard suppliedParameters.isValid else {
                            throw DocumentPaintSurfaceTransactionError
                                .invalidStrokeCompositeParameters
                        }
                        current.strokeAuthoritativeSourceOwner =
                            strokeSourceOwner
                        current.strokeAuthoritativeSourceLease =
                            strokeSourceLease
                        authoritativeSources = strokeSourceLease.bindings.map {
                            .texture(DocumentPaintSurfaceMutationSource(
                                coordinate: $0.descriptor.coordinate,
                                logicalBounds: $0.descriptor.logicalBounds,
                                texture: $0.texture
                            ))
                        }
                        compositeParameters = suppliedParameters
                    } else {
                        guard allowKnownClearAuthoritativeStrokeSourcesForTesting,
                              strokeSourceOwner == nil,
                              strokeSourceLease == nil,
                              strokeCompositeParameters == nil
                        else {
                            throw DocumentPaintSurfaceTransactionError
                                .missingStrokeAuthoritativeLease
                        }
                        authoritativeSources = try current.request
                            .dirtyCoordinates.map { coordinate in
                                let descriptor = try PaintTileDescriptor(
                                    coordinate: coordinate,
                                    logicalPixelSize: current.request
                                        .candidateGeometry.storagePixelSize
                                )
                                return .knownClear(
                                    coordinate: coordinate,
                                    logicalBounds: descriptor.logicalBounds
                                )
                            }
                        compositeParameters = .opaqueDraw
                    }

                    let baseReferenceCoordinates = Set(
                        current.baseBinding.canonical.references
                            .map(\.coordinate)
                    )
                    let presentBaseCoordinates = current.request
                        .dirtyCoordinates.filter {
                            baseReferenceCoordinates.contains($0)
                        }
                    if !presentBaseCoordinates.isEmpty {
                        current.strokeBaseSourceLease = try current.baseBinding
                            .canonical.leaseExistingTiles(
                                at: presentBaseCoordinates,
                                pinReasons: [.inFlight]
                            )
                    }
                    let presentBaseSources = Dictionary(
                        uniqueKeysWithValues:
                            (current.strokeBaseSourceLease?.bindings ?? []).map {
                                ($0.descriptor.coordinate, $0)
                            }
                    )
                    let baseSources = try current.request.dirtyCoordinates.map {
                        coordinate -> DocumentPaintSurfaceReadSource in
                        if let binding = presentBaseSources[coordinate] {
                            return .texture(
                                DocumentPaintSurfaceMutationSource(
                                    coordinate: coordinate,
                                    logicalBounds:
                                        binding.descriptor.logicalBounds,
                                    texture: binding.texture
                                )
                            )
                        }
                        let descriptor = try PaintTileDescriptor(
                            coordinate: coordinate,
                            logicalPixelSize: current.request
                                .baseGeometry.storagePixelSize
                        )
                        return .knownClear(
                            coordinate: coordinate,
                            logicalBounds: descriptor.logicalBounds
                        )
                    }
                    let payload = DocumentPaintSurfaceStrokeBackendPayload(
                        geometry: current.request.candidateGeometry,
                        compositeParameters: compositeParameters,
                        baseSources: baseSources,
                        authoritativeSources: authoritativeSources,
                        destinations: destinations
                    )
                    try Self.validateStrokePayload(
                        payload,
                        expectedCoordinates: current.request.dirtyCoordinates,
                        allowsKnownClearAuthoritativeSources:
                            strokeSourceLease == nil
                                && allowKnownClearAuthoritativeStrokeSourcesForTesting
                    )
                    operation = .stroke(payload)
                } catch {
                    do {
                        if let lease {
                            try binding.canonical.returnLease(lease)
                        }
                        current.destinationLease = nil
                        current.candidateBinding = nil
                        try releaseStrokeSources(current)
                    } catch {
                        current.phase = .discardPending
                        throw DocumentPaintSurfaceTransactionError.cleanupFailed
                    }
                    if let transactionError = error as?
                        DocumentPaintSurfaceTransactionError {
                        throw transactionError
                    }
                    throw DocumentPaintSurfaceTransactionError
                        .backendEncodingFailed
                }
            } else {
                throw DocumentPaintSurfaceTransactionError
                    .unsupportedMutationKind(current.request.kind)
            }
            do {
                if failureInjection?.shouldFail(at: .mutationEncode) == true {
                    throw DocumentPaintSurfaceTransactionError
                        .backendEncodingFailed
                }
                try mutationBackend.preflight(operation)
                current.backendEncoding = try mutationBackend.encode(operation)
            } catch {
                do {
                    if let lease {
                        try binding.canonical.returnLease(lease)
                    }
                    current.destinationLease = nil
                    current.candidateBinding = nil
                    try releaseStrokeSources(current)
                    if let sourceLease = current.resizeSourceLease {
                        try current.baseBinding.canonical.returnLease(
                            sourceLease
                        )
                        current.resizeSourceLease = nil
                    }
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
                  let binding = current.candidateBinding
            else {
                preconditionFailure("Encoded mutation lost owned resources")
            }
            let lease = current.destinationLease
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

            if let lease {
                if failureInjection?.shouldFail(
                    at: .destinationLeaseReturn
                ) == true {
                    current.phase = .discardPending
                    throw DocumentPaintSurfaceTransactionError
                        .destinationLeaseReturnFailed
                }
                do {
                    try binding.canonical.returnLease(lease)
                    current.destinationLease = nil
                } catch {
                    current.phase = .discardPending
                    throw DocumentPaintSurfaceTransactionError
                        .destinationLeaseReturnFailed
                }
            }
            current.candidateBinding = nil
            if current.strokeBaseSourceLease != nil
                || current.strokeAuthoritativeSourceLease != nil {
                if failureInjection?.shouldFail(at: .sourceLeaseReturn) == true {
                    current.phase = .discardPending
                    throw DocumentPaintSurfaceTransactionError
                        .sourceLeaseReturnFailed
                }
                do {
                    try releaseStrokeSources(current)
                } catch {
                    current.phase = .discardPending
                    throw DocumentPaintSurfaceTransactionError
                        .sourceLeaseReturnFailed
                }
            }
            if let sourceLease = current.resizeSourceLease {
                if failureInjection?.shouldFail(at: .sourceLeaseReturn) == true {
                    current.phase = .discardPending
                    throw DocumentPaintSurfaceTransactionError
                        .sourceLeaseReturnFailed
                }
                do {
                    try current.baseBinding.canonical.returnLease(sourceLease)
                    current.resizeSourceLease = nil
                } catch {
                    current.phase = .discardPending
                    throw DocumentPaintSurfaceTransactionError
                        .sourceLeaseReturnFailed
                }
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
                for: current.request,
                resizePlan: current.resizePlan
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
            if current.revisionPair == nil,
               failureInjection?.shouldFail(at: .revisionPublish) == true {
                throw DocumentPaintSurfaceTransactionError
                    .revisionPublishFailed
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
            commitPreparedTerminal(prepared)
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

    /// Single audited boundary for the irreversible registry publication used
    /// by both mutation and restore terminals.
    private func commitPreparedTerminal(
        _ prepared: DocumentPaintPreparedCommit
    ) {
        registry.commitPreparedForCoordinator(prepared)
    }

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

    private func releaseStrokeSources(
        _ current: LiveTransaction
    ) throws {
        if let baseLease = current.strokeBaseSourceLease {
            try current.baseBinding.canonical.returnLease(baseLease)
            current.strokeBaseSourceLease = nil
        }
        switch (
            current.strokeAuthoritativeSourceOwner,
            current.strokeAuthoritativeSourceLease
        ) {
        case let (owner?, lease?):
            try owner.returnAuthoritativeMutationLease(lease)
            current.strokeAuthoritativeSourceOwner = nil
            current.strokeAuthoritativeSourceLease = nil
        case (nil, nil):
            break
        default:
            throw DocumentPaintSurfaceTransactionError.cleanupFailed
        }
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
        if current.strokeBaseSourceLease != nil
            || current.strokeAuthoritativeSourceLease != nil {
            do {
                try releaseStrokeSources(current)
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError
                    .sourceLeaseReturnFailed
            }
        }
        if let sourceLease = current.resizeSourceLease {
            do {
                try current.baseBinding.canonical.returnLease(sourceLease)
                current.resizeSourceLease = nil
            } catch {
                current.phase = .discardPending
                throw DocumentPaintSurfaceTransactionError
                    .sourceLeaseReturnFailed
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

    private static func makeEncodedImportPlan(
        _ request: DocumentPaintSurfaceEncodedImportRequest
    ) throws -> EncodedImportPlan {
        guard request.width > 0, request.height > 0 else {
            throw DocumentPaintSurfaceTransactionError.invalidEncodedImport(
                .invalidDimensions(
                    width: request.width,
                    height: request.height
                )
            )
        }
        let (minimumBytesPerRow, rowOverflow) = request.width
            .multipliedReportingOverflow(by: 4)
        guard !rowOverflow else {
            throw DocumentPaintSurfaceTransactionError
                .invalidEncodedImport(.byteCountOverflow)
        }
        guard request.bytesPerRow >= minimumBytesPerRow else {
            throw DocumentPaintSurfaceTransactionError.invalidEncodedImport(
                .invalidRowStride(
                    minimum: minimumBytesPerRow,
                    actual: request.bytesPerRow
                )
            )
        }
        let (expectedByteCount, byteCountOverflow) = request.bytesPerRow
            .multipliedReportingOverflow(by: request.height)
        guard !byteCountOverflow else {
            throw DocumentPaintSurfaceTransactionError
                .invalidEncodedImport(.byteCountOverflow)
        }
        guard request.encodedPremultipliedBGRA8.count == expectedByteCount else {
            throw DocumentPaintSurfaceTransactionError.invalidEncodedImport(
                .invalidEncodedByteCount(
                    expected: expectedByteCount,
                    actual: request.encodedPremultipliedBGRA8.count
                )
            )
        }
        guard request.candidateGeometry.radialLayout == nil else {
            throw DocumentPaintSurfaceTransactionError
                .encodedImportRadialUnsupported
        }
        let actualSize = PixelSize(
            width: request.width,
            height: request.height
        )
        guard request.candidateGeometry.storagePixelSize == actualSize else {
            throw DocumentPaintSurfaceTransactionError
                .encodedImportGeometryMismatch(
                    expected: request.candidateGeometry.storagePixelSize,
                    actual: actualSize
                )
        }

        let maximumTileX = (request.width - 1) / PaintTileDescriptor.side
        let maximumTileY = (request.height - 1) / PaintTileDescriptor.side
        var coordinates: [PaintTileCoordinate] = []
        var regions: [DocumentPaintSurfaceEncodedImportTileRegion] = []
        let tileCount = (maximumTileX + 1) * (maximumTileY + 1)
        coordinates.reserveCapacity(tileCount)
        regions.reserveCapacity(tileCount)
        for y in 0...maximumTileY {
            for x in 0...maximumTileX {
                let coordinate = PaintTileCoordinate(x: x, y: y)
                let descriptor: PaintTileDescriptor
                do {
                    descriptor = try PaintTileDescriptor(
                        coordinate: coordinate,
                        logicalPixelSize:
                            request.candidateGeometry.storagePixelSize
                    )
                } catch {
                    throw DocumentPaintSurfaceTransactionError
                        .encodedImportGeometryMismatch(
                            expected:
                                request.candidateGeometry.storagePixelSize,
                            actual: actualSize
                        )
                }
                let (rowOffset, rowOffsetOverflow) = descriptor.logicalBounds
                    .minY.multipliedReportingOverflow(by: request.bytesPerRow)
                let (columnOffset, columnOffsetOverflow) = descriptor
                    .logicalBounds.minX.multipliedReportingOverflow(by: 4)
                let (sourceByteOffset, offsetOverflow) = rowOffset
                    .addingReportingOverflow(columnOffset)
                guard !rowOffsetOverflow, !columnOffsetOverflow,
                      !offsetOverflow
                else {
                    throw DocumentPaintSurfaceTransactionError
                        .invalidEncodedImport(.byteCountOverflow)
                }
                guard encodedImportTileContainsNonzeroAlpha(
                    request.encodedPremultipliedBGRA8,
                    bytesPerRow: request.bytesPerRow,
                    logicalBounds: descriptor.logicalBounds
                ) else {
                    continue
                }
                coordinates.append(coordinate)
                regions.append(DocumentPaintSurfaceEncodedImportTileRegion(
                    coordinate: coordinate,
                    sourceOrigin: SIMD2(
                        descriptor.logicalBounds.minX,
                        descriptor.logicalBounds.minY
                    ),
                    sourceByteOffset: sourceByteOffset,
                    destinationOrigin: .zero,
                    extent: PixelSize(
                        width: descriptor.logicalBounds.width,
                        height: descriptor.logicalBounds.height
                    )
                ))
            }
        }
        return EncodedImportPlan(
            request: request,
            dirtyCoordinates: coordinates,
            tileRegions: regions
        )
    }

    private static func encodedImportTileContainsNonzeroAlpha(
        _ data: Data,
        bytesPerRow: Int,
        logicalBounds: PixelRect
    ) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for y in logicalBounds.minY..<logicalBounds.maxY {
                var alphaOffset = y * bytesPerRow
                    + logicalBounds.minX * 4
                    + 3
                for _ in logicalBounds.minX..<logicalBounds.maxX {
                    if bytes[alphaOffset] != 0 { return true }
                    alphaOffset += 4
                }
            }
            return false
        }
    }

    private static func makeResizePlan(
        baseCoordinates: [PaintTileCoordinate],
        sourceGeometry: DocumentPaintGeometry,
        candidateGeometry: DocumentPaintGeometry
    ) throws -> ResizePlan {
        if let sourceLayout = sourceGeometry.radialLayout,
           let candidateLayout = candidateGeometry.radialLayout {
            return try makeRadialResizePlan(
                baseCoordinates: baseCoordinates,
                sourceLayout: sourceLayout,
                candidateLayout: candidateLayout
            )
        }
        guard sourceGeometry.radialLayout == nil,
              candidateGeometry.radialLayout == nil
        else {
            throw DocumentPaintSurfaceTransactionError.invalidResizeMapping
        }
        var mappings: [DocumentPaintSurfaceResizeCopyMapping] = []
        mappings.reserveCapacity(baseCoordinates.count)
        for coordinate in baseCoordinates {
            let source: PaintTileDescriptor
            let destination: PaintTileDescriptor
            do {
                source = try PaintTileDescriptor(
                    coordinate: coordinate,
                    logicalPixelSize: sourceGeometry.storagePixelSize
                )
                destination = try PaintTileDescriptor(
                    coordinate: coordinate,
                    logicalPixelSize: candidateGeometry.storagePixelSize
                )
            } catch PaintTileError.coordinateOutsideSurface {
                continue
            } catch {
                throw DocumentPaintSurfaceTransactionError.invalidResizeMapping
            }
            let minX = max(
                source.logicalBounds.minX,
                destination.logicalBounds.minX
            )
            let minY = max(
                source.logicalBounds.minY,
                destination.logicalBounds.minY
            )
            let maxX = min(
                source.logicalBounds.maxX,
                destination.logicalBounds.maxX
            )
            let maxY = min(
                source.logicalBounds.maxY,
                destination.logicalBounds.maxY
            )
            guard maxX > minX, maxY > minY else { continue }
            mappings.append(DocumentPaintSurfaceResizeCopyMapping(
                sourceCoordinate: coordinate,
                destinationCoordinate: coordinate,
                sourceOrigin: SIMD2(
                    minX - source.logicalBounds.minX,
                    minY - source.logicalBounds.minY
                ),
                destinationOrigin: SIMD2(
                    minX - destination.logicalBounds.minX,
                    minY - destination.logicalBounds.minY
                ),
                extent: PixelSize(width: maxX - minX, height: maxY - minY),
                logicalPage: nil,
                masksToTargetOrbit: false
            ))
        }
        let sourceCoordinates = mappings.map(\.sourceCoordinate).sorted()
        let afterCoordinates = mappings.map(\.destinationCoordinate).sorted()
        let afterSet = Set(afterCoordinates)
        return ResizePlan(
            sourceCoordinates: sourceCoordinates,
            beforeCoordinates: baseCoordinates,
            afterCoordinates: afterCoordinates,
            removedCoordinates: baseCoordinates.filter {
                !afterSet.contains($0)
            },
            mappings: mappings
        )
    }

    private static func makeRadialResizePlan(
        baseCoordinates: [PaintTileCoordinate],
        sourceLayout: RadialSectorLayout,
        candidateLayout: RadialSectorLayout
    ) throws -> ResizePlan {
        let sourcePages = Dictionary(
            uniqueKeysWithValues: sourceLayout.residentPages.map { page in
                (
                    radialPhysicalCoordinate(page, layout: sourceLayout),
                    page
                )
            }
        )
        var mappings: [DocumentPaintSurfaceResizeCopyMapping] = []
        mappings.reserveCapacity(baseCoordinates.count)
        for sourceCoordinate in baseCoordinates {
            guard let sourcePage = sourcePages[sourceCoordinate] else {
                throw DocumentPaintSurfaceTransactionError
                    .invalidResizeMapping
            }
            guard let candidatePage = candidateLayout.residentPage(
                at: sourcePage.coordinate
            ) else { continue }
            mappings.append(DocumentPaintSurfaceResizeCopyMapping(
                sourceCoordinate: sourceCoordinate,
                destinationCoordinate: radialPhysicalCoordinate(
                    candidatePage,
                    layout: candidateLayout
                ),
                sourceOrigin: .zero,
                destinationOrigin: .zero,
                extent: PixelSize(
                    width: RadialSectorLayout.pageSide,
                    height: RadialSectorLayout.pageSide
                ),
                logicalPage: sourcePage.coordinate,
                masksToTargetOrbit: true
            ))
        }
        mappings.sort {
            if $0.destinationCoordinate == $1.destinationCoordinate {
                return $0.sourceCoordinate < $1.sourceCoordinate
            }
            return $0.destinationCoordinate < $1.destinationCoordinate
        }
        let sourceCoordinates = mappings.map(\.sourceCoordinate).sorted()
        let afterCoordinates = mappings.map(\.destinationCoordinate).sorted()
        guard Set(afterCoordinates).count == afterCoordinates.count else {
            throw DocumentPaintSurfaceTransactionError.invalidResizeMapping
        }
        let afterSet = Set(afterCoordinates)
        return ResizePlan(
            sourceCoordinates: sourceCoordinates,
            beforeCoordinates: baseCoordinates,
            afterCoordinates: afterCoordinates,
            removedCoordinates: baseCoordinates.filter {
                !afterSet.contains($0)
            },
            mappings: mappings
        )
    }

    private static func radialPhysicalCoordinate(
        _ page: RadialResidentPage,
        layout: RadialSectorLayout
    ) -> PaintTileCoordinate {
        PaintTileCoordinate(
            x: page.atlasSlot % layout.atlasColumns,
            y: page.atlasSlot / layout.atlasColumns
        )
    }

    private static func validateResizeBindings(
        sources: [DocumentPaintSurfaceMutationSource],
        destinations: [DocumentPaintSurfaceMutationDestination],
        plan: ResizePlan
    ) throws {
        guard sources.map(\.coordinate) == plan.sourceCoordinates,
              destinations.map(\.coordinate) == plan.afterCoordinates,
              plan.mappings.map(\.sourceCoordinate).sorted()
                == plan.sourceCoordinates,
              plan.mappings.map(\.destinationCoordinate).sorted()
                == plan.afterCoordinates
        else {
            throw DocumentPaintSurfaceTransactionError.invalidResizeMapping
        }
        for source in sources {
            guard source.texture.pixelFormat == PaintTileDescriptor.pixelFormat,
                  source.texture.width == PaintTileDescriptor.side,
                  source.texture.height == PaintTileDescriptor.side
            else {
                throw DocumentPaintSurfaceTransactionError.invalidResizeMapping
            }
        }
        for destination in destinations {
            guard destination.texture.pixelFormat
                    == PaintTileDescriptor.pixelFormat,
                  destination.texture.width == PaintTileDescriptor.side,
                  destination.texture.height == PaintTileDescriptor.side
            else {
                throw DocumentPaintSurfaceTransactionError.invalidResizeMapping
            }
        }
    }

    private static func validateStrokeAuthoritativeSource(
        _ lease: StrokeAuthoritativeMutationLease,
        owner: StrokeTileSurfaceEncoder,
        registry: DocumentPaintSurfaceStore,
        request: DocumentPaintSurfaceMutationRequest,
        generation: UInt64
    ) throws {
        guard lease.storeIdentity == registry.tileStoreIdentity else {
            throw DocumentPaintSurfaceTransactionError
                .strokeSourceStoreMismatch
        }
        guard lease.layerID == request.layerID else {
            throw DocumentPaintSurfaceTransactionError
                .strokeSourceLayerMismatch(
                    expected: request.layerID,
                    actual: lease.layerID
                )
        }
        guard lease.generation == generation else {
            throw DocumentPaintSurfaceTransactionError
                .strokeSourceGenerationMismatch(
                    expected: generation,
                    actual: lease.generation
                )
        }
        let expectedSize = request.candidateGeometry.storagePixelSize
        guard request.baseGeometry == request.candidateGeometry,
              lease.pixelSize == expectedSize
        else {
            throw DocumentPaintSurfaceTransactionError
                .strokeSourceGeometryMismatch(
                    expected: expectedSize,
                    actual: lease.pixelSize
                )
        }
        guard lease.radialLayout == request.candidateGeometry.radialLayout else {
            throw DocumentPaintSurfaceTransactionError
                .strokeSourceRadialLayoutMismatch
        }
        guard lease.bindings.map(\.descriptor.coordinate)
                == request.dirtyCoordinates
        else {
            throw DocumentPaintSurfaceTransactionError
                .strokeSourceCoordinateMismatch
        }
        guard owner.ownsAuthoritativeMutationLease(lease) else {
            throw DocumentPaintSurfaceTransactionError
                .strokeSourceOwnerMismatch
        }
    }

    static func validateStrokePayload(
        _ payload: DocumentPaintSurfaceStrokeBackendPayload,
        expectedCoordinates: [PaintTileCoordinate],
        allowsKnownClearAuthoritativeSources: Bool
    ) throws {
        guard payload.compositeParameters.isValid,
              payload.baseSources.map(\.coordinate) == expectedCoordinates,
              payload.authoritativeSources.map(\.coordinate)
                == expectedCoordinates,
              payload.destinations.map(\.coordinate) == expectedCoordinates
        else {
            throw DocumentPaintSurfaceTransactionError
                .strokeSourceCoordinateMismatch
        }
        for coordinate in expectedCoordinates {
            let expected = try PaintTileDescriptor(
                coordinate: coordinate,
                logicalPixelSize: payload.geometry.storagePixelSize
            )
            guard payload.baseSources.first(where: {
                $0.coordinate == coordinate
            })?.logicalBounds == expected.logicalBounds,
                payload.authoritativeSources.first(where: {
                    $0.coordinate == coordinate
                })?.logicalBounds == expected.logicalBounds,
                payload.destinations.first(where: {
                    $0.coordinate == coordinate
                })?.logicalBounds == expected.logicalBounds
            else {
                throw DocumentPaintSurfaceTransactionError
                    .strokeSourceGeometryMismatch(
                        expected: payload.geometry.storagePixelSize,
                        actual: payload.geometry.storagePixelSize
                    )
            }
        }
        for source in payload.baseSources {
            switch source {
            case .knownClear:
                break
            case let .texture(textureSource):
                guard textureSource.texture.pixelFormat
                        == PaintTileDescriptor.pixelFormat,
                      textureSource.texture.width == PaintTileDescriptor.side,
                      textureSource.texture.height == PaintTileDescriptor.side
                else {
                    throw DocumentPaintSurfaceTransactionError
                        .strokeSourceGeometryMismatch(
                            expected: payload.geometry.storagePixelSize,
                            actual: payload.geometry.storagePixelSize
                        )
                }
            }
        }
        for source in payload.authoritativeSources {
            switch source {
            case .knownClear:
                guard allowsKnownClearAuthoritativeSources else {
                    throw DocumentPaintSurfaceTransactionError
                        .missingStrokeAuthoritativeLease
                }
            case let .texture(textureSource):
                guard textureSource.texture.pixelFormat
                        == PaintTileDescriptor.pixelFormat,
                      textureSource.texture.width == PaintTileDescriptor.side,
                      textureSource.texture.height == PaintTileDescriptor.side
                else {
                    throw DocumentPaintSurfaceTransactionError
                        .strokeSourceGeometryMismatch(
                            expected: payload.geometry.storagePixelSize,
                            actual: payload.geometry.storagePixelSize
                        )
                }
            }
        }
        var readTextureIdentities: Set<ObjectIdentifier> = []
        for source in payload.baseSources + payload.authoritativeSources {
            guard case let .texture(textureSource) = source else { continue }
            let identity = ObjectIdentifier(textureSource.texture as AnyObject)
            guard readTextureIdentities.insert(identity).inserted else {
                throw DocumentPaintSurfaceTransactionError.strokeTextureAlias
            }
        }
        var destinationTextureIdentities: Set<ObjectIdentifier> = []
        for destination in payload.destinations {
            let identity = ObjectIdentifier(destination.texture as AnyObject)
            guard destinationTextureIdentities.insert(identity).inserted,
                  !readTextureIdentities.contains(identity)
            else {
                throw DocumentPaintSurfaceTransactionError.strokeTextureAlias
            }
        }
        for destination in payload.destinations {
            guard destination.texture.pixelFormat
                    == PaintTileDescriptor.pixelFormat,
                  destination.texture.width == PaintTileDescriptor.side,
                  destination.texture.height == PaintTileDescriptor.side
            else {
                throw DocumentPaintSurfaceTransactionError
                    .strokeSourceGeometryMismatch(
                        expected: payload.geometry.storagePixelSize,
                        actual: payload.geometry.storagePixelSize
                    )
            }
        }
    }

    private static func validateEncodedImportBindings(
        destinations: [DocumentPaintSurfaceMutationDestination],
        plan: EncodedImportPlan
    ) throws {
        guard destinations.map(\.coordinate) == plan.dirtyCoordinates,
              plan.tileRegions.map(\.coordinate) == plan.dirtyCoordinates
        else {
            throw DocumentPaintSurfaceTransactionError.backendEncodingFailed
        }
        for (destination, region) in zip(
            destinations,
            plan.tileRegions
        ) {
            guard destination.texture.pixelFormat
                    == PaintTileDescriptor.pixelFormat,
                  destination.texture.width == PaintTileDescriptor.side,
                  destination.texture.height == PaintTileDescriptor.side,
                  region.destinationOrigin == .zero,
                  destination.logicalBounds.width == region.extent.width,
                  destination.logicalBounds.height == region.extent.height,
                  destination.logicalBounds.minX == region.sourceOrigin.x,
                  destination.logicalBounds.minY == region.sourceOrigin.y
            else {
                throw DocumentPaintSurfaceTransactionError.backendEncodingFailed
            }
        }
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
        for request: DocumentPaintSurfaceMutationRequest,
        resizePlan: ResizePlan?
    ) -> (before: [PaintTileCoordinate], after: [PaintTileCoordinate]) {
        if let resizePlan {
            return (
                resizePlan.beforeCoordinates,
                resizePlan.afterCoordinates
            )
        }
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
