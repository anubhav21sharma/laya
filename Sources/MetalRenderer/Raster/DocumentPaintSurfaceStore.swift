import CShaderTypes
import EditorCore
import Foundation
import Metal
import PatternEngine

public enum DocumentPaintSurfaceRole: UInt8, Hashable, Sendable {
    case canonical
    case authoritative
    case prediction
    case provisional
    case historyInstall
}

public enum DocumentPaintSurfaceStoreError: Error, Equatable, Sendable {
    case geometryByteCountOverflow
    case radialStorageSizeMismatch(expected: PixelSize, actual: PixelSize)
    case duplicateLayerID(UUID)
    case layerStackMismatch(expected: [UUID], actual: [UUID])
    case unknownLayerID(UUID)
    case staleGeneration(expected: UInt64, actual: UInt64)
    case generationOverflow
    case duplicateCoordinate(PaintTileCoordinate)
    case unsortedCoordinate(
        previous: PaintTileCoordinate,
        current: PaintTileCoordinate
    )
    case unownedCandidateCoordinate(PaintTileCoordinate)
    case overlappingDirtyAndRemovedCoordinate(PaintTileCoordinate)
    case foreignCandidate
    case staleCandidate(expectedGeneration: UInt64, actualGeneration: UInt64)
    case candidateAlreadyConsumed
    case ambiguousPreparedCandidate
    case preparedCandidateRequiresExplicitCancellation
    case namespaceIdentityOverflow
    case transferByteCapacityOverflow
    case visibleCaptureContention(maximumAttempts: Int)
    case closedLayerHistoryRevision
    case foreignLayerHistoryRevision
    case layerHistoryEndpointMismatch
    case layerHistoryByteCountOverflow
    case nativeImportRequiresEmptyStore
}

public struct DocumentPaintGeometry: Equatable, Sendable {
    public let documentPixelSize: PixelSize
    public let storagePixelSize: PixelSize
    public let radialLayout: RadialSectorLayout?
    public let storageResidentByteCount: Int

    public init(
        documentPixelSize: PixelSize,
        storagePixelSize: PixelSize,
        radialLayout: RadialSectorLayout?
    ) throws {
        func bytes(_ size: PixelSize) throws -> Int {
            let (pixels, pixelOverflow) = size.width
                .multipliedReportingOverflow(by: size.height)
            let (result, byteOverflow) = pixels
                .multipliedReportingOverflow(by: 8)
            guard !pixelOverflow, !byteOverflow else {
                throw DocumentPaintSurfaceStoreError.geometryByteCountOverflow
            }
            return result
        }
        _ = try bytes(documentPixelSize)
        let storageBytes: Int
        if let radialLayout {
            guard storagePixelSize == radialLayout.atlasPixelSize else {
                throw DocumentPaintSurfaceStoreError.radialStorageSizeMismatch(
                    expected: radialLayout.atlasPixelSize,
                    actual: storagePixelSize
                )
            }
            do {
                storageBytes = try radialLayout.residentByteCount(
                    bytesPerPixel: 8
                )
            } catch {
                throw DocumentPaintSurfaceStoreError.geometryByteCountOverflow
            }
        } else {
            storageBytes = try bytes(storagePixelSize)
        }
        self.documentPixelSize = documentPixelSize
        self.storagePixelSize = storagePixelSize
        self.radialLayout = radialLayout
        storageResidentByteCount = storageBytes
    }
}

struct CanvasCanonicalStateIdentity: Equatable, Sendable {
    let documentGeneration: UInt64
    let geometry: DocumentPaintGeometry
    let geometryRevision: UInt64
    let layerStackRevision: UInt64
    let compositeRevision: UInt64
}

public struct DocumentPaintSurfaceNamespace: Hashable, Sendable {
    public let storeIdentity: PaintTileStoreIdentity
    public let surfaceID: UUID
    public let layerID: UUID
    public let generation: UInt64
    public let role: DocumentPaintSurfaceRole
    let token: UInt64
}

final class StrokeTileSurfaceNamespaceOwnership: @unchecked Sendable {
    private enum State { case issued, claimed, finished }

    let retirementToken: UInt64
    private let lock = NSLock()
    private var state: State = .issued
    private let finishHandler: @Sendable (UInt64) -> Void

    init(
        retirementToken: UInt64,
        onFinished: @escaping @Sendable (UInt64) -> Void
    ) {
        self.retirementToken = retirementToken
        finishHandler = onFinished
    }

    var isOutstanding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state != .finished
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .issued else { return false }
        state = .claimed
        return true
    }

    func cancelIfUnclaimed() {
        finish(allowIssued: true, allowClaimed: false)
    }

    func abortClaimedInitialization() {
        finish(allowIssued: false, allowClaimed: true)
    }

    func retire() {
        finish(allowIssued: true, allowClaimed: true)
    }

    private func finish(allowIssued: Bool, allowClaimed: Bool) {
        lock.lock()
        let shouldFinish: Bool
        switch state {
        case .issued:
            shouldFinish = allowIssued
        case .claimed:
            shouldFinish = allowClaimed
        case .finished:
            shouldFinish = false
        }
        if shouldFinish { state = .finished }
        lock.unlock()
        if shouldFinish { finishHandler(retirementToken) }
    }

    deinit { retire() }
}

struct StrokeTileSurfaceNamespaceLease: Sendable {
    let authoritative: DocumentPaintSurfaceNamespace
    let prediction: DocumentPaintSurfaceNamespace
    let retirementToken: UInt64
    let isStandaloneTestOnly: Bool
    let ownership: StrokeTileSurfaceNamespaceOwnership
    private let authenticationHandler:
        @Sendable (StrokeTileSurfaceNamespaceLease) -> Bool

    private init(
        authoritative: DocumentPaintSurfaceNamespace,
        prediction: DocumentPaintSurfaceNamespace,
        retirementToken: UInt64,
        isStandaloneTestOnly: Bool,
        ownership: StrokeTileSurfaceNamespaceOwnership,
        authenticate: @escaping @Sendable
            (StrokeTileSurfaceNamespaceLease) -> Bool
    ) {
        self.authoritative = authoritative
        self.prediction = prediction
        self.retirementToken = retirementToken
        self.isStandaloneTestOnly = isStandaloneTestOnly
        self.ownership = ownership
        authenticationHandler = authenticate
    }

    var authoritativeSurfaceID: UUID { authoritative.surfaceID }
    var predictionSurfaceID: UUID { prediction.surfaceID }
    var storeIdentity: PaintTileStoreIdentity { authoritative.storeIdentity }
    var layerID: UUID { authoritative.layerID }
    var generation: UInt64 { authoritative.generation }

    static func registryIssued(
        authoritative: DocumentPaintSurfaceNamespace,
        prediction: DocumentPaintSurfaceNamespace,
        retirementToken: UInt64,
        authenticate: @escaping @Sendable
            (StrokeTileSurfaceNamespaceLease) -> Bool,
        onRetired: @escaping @Sendable (UInt64) -> Void
    ) -> Self {
        let ownership = StrokeTileSurfaceNamespaceOwnership(
            retirementToken: retirementToken,
            onFinished: onRetired
        )
        return Self(
            authoritative: authoritative,
            prediction: prediction,
            retirementToken: retirementToken,
            isStandaloneTestOnly: false,
            ownership: ownership,
            authenticate: authenticate
        )
    }

    func isAuthenticated(
        storeIdentity: PaintTileStoreIdentity,
        layerID: UUID,
        generation: UInt64
    ) -> Bool {
        authoritative.storeIdentity == prediction.storeIdentity
            && authoritative.layerID == prediction.layerID
            && authoritative.generation == prediction.generation
            && authoritative.role == .authoritative
            && prediction.role == .prediction
            && authoritative.storeIdentity == storeIdentity
            && authoritative.layerID == layerID
            && authoritative.generation == generation
            && ownership.isOutstanding
            && authenticationHandler(self)
    }

    func claimForResources() -> Bool { ownership.claim() }
    func abortClaimedInitialization() {
        ownership.abortClaimedInitialization()
    }
    func reportRetired() { ownership.retire() }
    func cancel() { ownership.cancelIfUnclaimed() }

    #if DEBUG
    static func testing(generation: UInt64) -> Self {
        let storeIdentity = PaintTileStoreIdentity()
        let layerID = UUID()
        let token = generation
        let ownership = StrokeTileSurfaceNamespaceOwnership(
            retirementToken: token,
            onFinished: { _ in }
        )
        return Self(
            authoritative: DocumentPaintSurfaceNamespace(
                storeIdentity: storeIdentity,
                surfaceID: UUID(),
                layerID: layerID,
                generation: generation,
                role: .authoritative,
                token: token
            ),
            prediction: DocumentPaintSurfaceNamespace(
                storeIdentity: storeIdentity,
                surfaceID: UUID(),
                layerID: layerID,
                generation: generation,
                role: .prediction,
                token: token
            ),
            retirementToken: token,
            isStandaloneTestOnly: true,
            ownership: ownership,
            authenticate: { $0.generation == generation }
        )
    }

    static func testing(
        storeIdentity: PaintTileStoreIdentity,
        layerID: UUID,
        generation: UInt64,
        authoritativeSurfaceID: UUID = UUID(),
        predictionSurfaceID: UUID = UUID(),
        retirementToken: UInt64 = 0,
        onRetired: @escaping @Sendable (UInt64) -> Void = { _ in }
    ) -> Self {
        let ownership = StrokeTileSurfaceNamespaceOwnership(
            retirementToken: retirementToken,
            onFinished: onRetired
        )
        return Self(
            authoritative: DocumentPaintSurfaceNamespace(
                storeIdentity: storeIdentity,
                surfaceID: authoritativeSurfaceID,
                layerID: layerID,
                generation: generation,
                role: .authoritative,
                token: retirementToken
            ),
            prediction: DocumentPaintSurfaceNamespace(
                storeIdentity: storeIdentity,
                surfaceID: predictionSurfaceID,
                layerID: layerID,
                generation: generation,
                role: .prediction,
                token: retirementToken
            ),
            retirementToken: retirementToken,
            isStandaloneTestOnly: true,
            ownership: ownership,
            authenticate: { _ in true }
        )
    }
    #endif
}

enum DocumentPaintStrokeSurfaceError: Error, Equatable, Sendable {
    case store(PaintTileStoreError)
    case residency(PaintTileResidencyError)
    case surface(TiledRasterSurfaceError)
    case unexpected(String)
    case foreignCapability
    case staleCapability
    case alreadyTerminal
    case alreadyClaimed
    case wrongTransaction
    case outstandingFrame
    case emptyCommitMutation
    case invalidLifecycle

    static func wrapping(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        if let error = error as? PaintTileStoreError { return .store(error) }
        if let error = error as? PaintTileResidencyError {
            return .residency(error)
        }
        if let error = error as? TiledRasterSurfaceError {
            return .surface(error)
        }
        return .unexpected(String(describing: error))
    }
}

enum DocumentPaintStrokeSurfaceRole: UInt8, Sendable {
    case authoritative
    case prediction
}

struct DocumentPaintStrokeFrameReservation: Sendable {
    fileprivate let capabilityToken: UUID
    let reservationToken: UUID
    let role: DocumentPaintStrokeSurfaceRole
    fileprivate let lease: PaintTileLease
    var bindings: [PaintTileBinding] { lease.bindings }
}

struct DocumentPaintStrokeProvisionalBinding: @unchecked Sendable {
    let identity: PaintTileIdentity
    let descriptor: PaintTileDescriptor
    let sourceTexture: any MTLTexture
    let candidateTexture: any MTLTexture
    let sourceComponentCoverageTexture: (any MTLTexture)?
    let candidateComponentCoverageTexture: any MTLTexture
    let sourceIsKnownClear: Bool
}

struct DocumentPaintStrokeProvisionalReservation: Sendable {
    fileprivate let capabilityToken: UUID
    fileprivate let reservationToken: UUID
    fileprivate let frameReservationToken: UUID
    let bindings: [DocumentPaintStrokeProvisionalBinding]
}

enum StrokePreparedCommitMutationCompletion: Sendable {
    case consumed
    case aborted
    case cancelled
}

/// Affine terminal source. Copies share capability-owned state and contain no
/// raw store lease, mutable surface, or encoder owner.
struct StrokePreparedCommitTileSources: @unchecked Sendable {
    let coordinate: PaintTileCoordinate
    let authoritative: PaintTileBinding?
    let prediction: PaintTileBinding?
}

struct StrokePreparedCommitMutationSource: Sendable {
    let contextIdentity: UUID
    let storeIdentity: PaintTileStoreIdentity
    let layerID: UUID
    let generation: UInt64
    let pixelSize: PixelSize
    let radialLayout: RadialSectorLayout?
    let coordinates: [PaintTileCoordinate]
    fileprivate let capability: DocumentPaintStrokeSurfaceCapability
    let sourceToken: UUID

    func claim(
        transactionID: UUID
    ) throws -> [StrokePreparedCommitTileSources] {
        try capability.claimCommitSource(
            sourceToken: sourceToken,
            transactionID: transactionID
        )
    }

    func complete(
        transactionID: UUID,
        as completion: StrokePreparedCommitMutationCompletion
    ) throws {
        try capability.completeCommitSource(
            sourceToken: sourceToken,
            transactionID: transactionID,
            completion: completion
        )
    }

    func cancelUnclaimed() throws {
        try capability.cancelUnclaimedCommitSource(
            sourceToken: sourceToken
        )
    }

}

/// Authenticated lifetime identity for one stroke's transient presentation.
/// A document generation can contain multiple strokes, so retirement must
/// follow this exact affine identity rather than the generation number.
final class DocumentPaintStrokePresentationEpoch: @unchecked Sendable {
    let identity: UUID
    private let lock = NSLock()
    private var retired = false

    init(identity: UUID) { self.identity = identity }

    var isRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retired
    }

    func retire() {
        lock.lock()
        retired = true
        lock.unlock()
    }
}

/// Document-issued authority for one transient stroke namespace. The raw tile
/// store and role surfaces remain confined to the raster owner; StrokeRuntime
/// receives operation-shaped methods as the sparse path is activated.
final class DocumentPaintStrokeSurfaceCapability: @unchecked Sendable {
    fileprivate enum State: Equatable {
        case active
        case sourceIssued(UUID)
        case terminal
    }

    private final class TerminalSourceRecord {
        let token: UUID
        let coordinates: [PaintTileCoordinate]
        var authoritativeLease: PaintTileLease?
        var predictionLease: PaintTileLease?
        var transactionID: UUID?

        init(
            token: UUID,
            coordinates: [PaintTileCoordinate],
            authoritativeLease: PaintTileLease?,
            predictionLease: PaintTileLease?
        ) {
            self.token = token
            self.coordinates = coordinates
            self.authoritativeLease = authoritativeLease
            self.predictionLease = predictionLease
        }
    }

    let ownerIdentity: UUID
    let capabilityToken: UUID
    let presentationEpoch: DocumentPaintStrokePresentationEpoch
    fileprivate let namespaceLease: StrokeTileSurfaceNamespaceLease
    fileprivate let store: PaintTileStore
    fileprivate let authoritative: TiledRasterSurface
    fileprivate let prediction: TiledRasterSurface
    private let lock = NSLock()
    private var state: State = .active
    private var frameReservations: [UUID: PaintTileLease] = [:]
    private var provisionalReservations:
        [UUID: PaintTileProvisionalReservation] = [:]
    private var terminalSource: TerminalSourceRecord?
    private let terminalHandler: @Sendable (UUID) -> Void

    let storeIdentity: PaintTileStoreIdentity
    let layerID: UUID
    let generation: UInt64
    let pixelSize: PixelSize
    let radialLayout: RadialSectorLayout?
    var authoritativeSurfaceID: UUID { authoritative.surfaceID }
    var predictionSurfaceID: UUID { prediction.surfaceID }

    var snapshot: StrokeTileSurfaceResourceSnapshot {
        let raw = store.snapshot()
        let ownedLeaseCount = withLock {
            frameReservations.count
                + (terminalSource?.authoritativeLease == nil ? 0 : 1)
                + (terminalSource?.predictionLease == nil ? 0 : 1)
        }
        let matching = raw.entries.filter {
            $0.identity.layerID == layerID && $0.generation == generation
                && ($0.surfaceID == authoritative.surfaceID
                    || $0.surfaceID == prediction.surfaceID)
        }
        return StrokeTileSurfaceResourceSnapshot(
            residentTileCount: matching.filter(\.isResident).count,
            activeLeaseCount: ownedLeaseCount,
            residentByteCount: matching.reduce(into: 0) {
                if $1.isResident {
                    $0 += PaintTileDescriptor.residentByteCount
                }
                if $1.hasComponentCoverageTexture {
                    $0 += DepositionComponentCoverage.residentByteCount(
                        width: PaintTileDescriptor.side,
                        height: PaintTileDescriptor.side
                    ) ?? 0
                }
            },
            fullCanvasTextureCount: 0
        )
    }

    fileprivate init(
        ownerIdentity: UUID,
        capabilityToken: UUID,
        namespaceLease: StrokeTileSurfaceNamespaceLease,
        store: PaintTileStore,
        geometry: DocumentPaintGeometry,
        onTerminal: @escaping @Sendable (UUID) -> Void
    ) throws {
        #if DEBUG
        let permitsStandalone = namespaceLease.isStandaloneTestOnly
        #else
        let permitsStandalone = false
        #endif
        guard namespaceLease.isAuthenticated(
            storeIdentity: store.identity,
            layerID: namespaceLease.layerID,
            generation: namespaceLease.generation
        ) || permitsStandalone,
        namespaceLease.authoritativeSurfaceID
            != namespaceLease.predictionSurfaceID
        else {
            throw DocumentPaintStrokeSurfaceError.invalidLifecycle
        }
        guard namespaceLease.claimForResources() else {
            throw DocumentPaintStrokeSurfaceError.invalidLifecycle
        }
        var succeeded = false
        defer {
            if !succeeded { namespaceLease.abortClaimedInitialization() }
        }
        self.ownerIdentity = ownerIdentity
        self.capabilityToken = capabilityToken
        presentationEpoch = DocumentPaintStrokePresentationEpoch(
            identity: capabilityToken
        )
        self.namespaceLease = namespaceLease
        self.store = store
        storeIdentity = store.identity
        layerID = namespaceLease.layerID
        generation = namespaceLease.generation
        pixelSize = geometry.storagePixelSize
        radialLayout = geometry.radialLayout
        authoritative = TiledRasterSurface(
            store: store,
            layerID: namespaceLease.layerID,
            pixelSize: geometry.storagePixelSize,
            surfaceID: namespaceLease.authoritativeSurfaceID,
            generation: namespaceLease.generation
        )
        prediction = TiledRasterSurface(
            store: store,
            layerID: namespaceLease.layerID,
            pixelSize: geometry.storagePixelSize,
            surfaceID: namespaceLease.predictionSurfaceID,
            generation: namespaceLease.generation
        )
        terminalHandler = onTerminal
        succeeded = true
    }

    deinit {
        try? cancel(expectedOwnerIdentity: ownerIdentity)
    }

    #if DEBUG
    var testingStoreSnapshot: PaintTileStoreSnapshot { store.snapshot() }
    var testingStoreObject: AnyObject { store }
    var testingNamespaceIsOutstanding: Bool {
        namespaceLease.ownership.isOutstanding
    }
    var testingAuthoritativeSurfaceID: UUID { authoritative.surfaceID }
    var testingPredictionSurfaceID: UUID { prediction.surfaceID }

    func testingMarkDirty(
        _ frame: DocumentPaintStrokeFrameReservation
    ) throws {
        try withLock {
            let lease = try validatedFrame(frame)
            let surface = frame.role == .authoritative
                ? authoritative : prediction
            try surface.markDirty(lease)
            frameReservations[frame.reservationToken] = lease
        }
    }

    static func testing(
        store: PaintTileStore,
        layerID: UUID,
        pixelSize: PixelSize,
        generation: UInt64,
        radialLayout: RadialSectorLayout? = nil,
        ownerIdentity: UUID = UUID(),
        onTerminal: @escaping @Sendable (UUID) -> Void = { _ in }
    ) throws -> DocumentPaintStrokeSurfaceCapability {
        try testing(
            store: store,
            pixelSize: pixelSize,
            generation: generation,
            radialLayout: radialLayout,
            ownerIdentity: ownerIdentity,
            namespaceLease: StrokeTileSurfaceNamespaceLease.testing(
            storeIdentity: store.identity,
            layerID: layerID,
            generation: generation
            ),
            onTerminal: onTerminal
        )
    }

    static func testing(
        store: PaintTileStore,
        pixelSize: PixelSize,
        generation: UInt64,
        radialLayout: RadialSectorLayout? = nil,
        ownerIdentity: UUID = UUID(),
        namespaceLease: StrokeTileSurfaceNamespaceLease,
        onTerminal: @escaping @Sendable (UUID) -> Void = { _ in }
    ) throws -> DocumentPaintStrokeSurfaceCapability {
        return try DocumentPaintStrokeSurfaceCapability(
            ownerIdentity: ownerIdentity,
            capabilityToken: UUID(),
            namespaceLease: namespaceLease,
            store: store,
            geometry: DocumentPaintGeometry(
                documentPixelSize: pixelSize,
                storagePixelSize: pixelSize,
                radialLayout: radialLayout
            ),
            onTerminal: onTerminal
        )
    }
    #endif

    func reserveStrokeTiles(
        role: DocumentPaintStrokeSurfaceRole,
        coordinates: [PaintTileCoordinate],
        pinReasons: [PaintTilePinReason],
        workspace: PaintTileStrokeLeaseWorkspace,
        failureInjection: PaintTileAllocationFailureInjection?
    ) throws -> DocumentPaintStrokeFrameReservation {
        try withLock {
            guard state == .active else {
                throw DocumentPaintStrokeSurfaceError.invalidLifecycle
            }
            let surface = role == .authoritative
                ? authoritative : prediction
            let lease = try surface.reserveSortedUniqueStrokeTiles(
                at: coordinates,
                pinReasons: pinReasons,
                workspace: workspace,
                failureInjection: failureInjection
            )
            let token = UUID()
            frameReservations[token] = lease
            return Self.frameReservation(
                capabilityToken: capabilityToken,
                token: token,
                role: role,
                lease: lease
            )
        }
    }

    func makeProvisionalBindings(
        frame: DocumentPaintStrokeFrameReservation,
        coordinates: [PaintTileCoordinate],
        modifiedCoordinates: [PaintTileCoordinate]? = nil,
        workspace: PaintTileProvisionalWorkspace
    ) throws -> DocumentPaintStrokeProvisionalReservation {
        try withLock {
            let lease = try validatedFrame(frame)
            let surface = frame.role == .authoritative
                ? authoritative : prediction
            let raw = try surface.makeProvisionalBindings(
                for: lease,
                coordinates: coordinates,
                modifiedCoordinates: modifiedCoordinates ?? coordinates,
                workspace: workspace
            )
            let token = UUID()
            provisionalReservations[token] = raw
            return Self.provisionalReservation(
                capabilityToken: capabilityToken,
                token: token,
                frameToken: frame.reservationToken,
                reservation: raw
            )
        }
    }

    func commitProvisionalBindings(
        _ provisional: DocumentPaintStrokeProvisionalReservation,
        frame: DocumentPaintStrokeFrameReservation,
        modifiedCoordinates: [PaintTileCoordinate],
        knownClearCoordinates: [PaintTileCoordinate]
    ) throws -> DocumentPaintStrokeFrameReservation {
        try withLock {
            let lease = try validatedFrame(frame)
            let raw = try validatedProvisional(provisional, frame: frame)
            let surface = frame.role == .authoritative
                ? authoritative : prediction
            let committed = try surface.commitProvisionalBindings(
                raw,
                for: lease,
                modifiedCoordinates: modifiedCoordinates,
                knownClearCoordinates: knownClearCoordinates
            )
            frameReservations[frame.reservationToken] = committed
            return Self.frameReservation(
                capabilityToken: capabilityToken,
                token: frame.reservationToken,
                role: frame.role,
                lease: committed
            )
        }
    }

    func cancelProvisionalBindings(
        _ provisional: DocumentPaintStrokeProvisionalReservation
    ) throws {
        try withLock {
            guard provisional.capabilityToken == capabilityToken,
                  let raw = provisionalReservations[
                    provisional.reservationToken
                  ],
                  let frame = frameReservations[
                    provisional.frameReservationToken
                  ]
            else { throw DocumentPaintStrokeSurfaceError.staleCapability }
            let surface = frame.surfaceID == authoritative.surfaceID
                ? authoritative : prediction
            try surface.cancelProvisionalBindings(raw)
            provisionalReservations.removeValue(
                forKey: provisional.reservationToken
            )
        }
    }

    func completeProvisionalBindings(
        _ provisional: DocumentPaintStrokeProvisionalReservation
    ) throws {
        try withLock {
            guard provisional.capabilityToken == capabilityToken,
                  let raw = provisionalReservations.removeValue(
                    forKey: provisional.reservationToken
                  ),
                  let frame = frameReservations[
                    provisional.frameReservationToken
                  ]
            else { throw DocumentPaintStrokeSurfaceError.staleCapability }
            let surface = frame.surfaceID == authoritative.surfaceID
                ? authoritative : prediction
            surface.completeProvisionalBindings(raw)
        }
    }

    func releaseFrameReservations(
        authoritative authoritativeFrame:
            DocumentPaintStrokeFrameReservation?,
        prediction predictionFrame: DocumentPaintStrokeFrameReservation?
    ) throws {
        try withLock {
            let authoritativeLease = try authoritativeFrame.map(validatedFrame)
            let predictionLease = try predictionFrame.map(validatedFrame)
            try store.releaseAtomically(
                authoritative: authoritativeLease,
                authoritativeSurfaceID: authoritative.surfaceID,
                authoritativeGeneration: generation,
                prediction: predictionLease,
                predictionSurfaceID: prediction.surfaceID,
                predictionGeneration: generation
            )
            if let authoritativeFrame {
                frameReservations.removeValue(
                    forKey: authoritativeFrame.reservationToken
                )
            }
            if let predictionFrame {
                frameReservations.removeValue(
                    forKey: predictionFrame.reservationToken
                )
            }
        }
    }

    func issueCommitMutationSource() throws
        -> StrokePreparedCommitMutationSource?
    {
        try withLock {
            guard state == .active,
                  frameReservations.isEmpty,
                  provisionalReservations.isEmpty
            else { throw DocumentPaintStrokeSurfaceError.outstandingFrame }
            let authoritativeCoordinates = authoritative.references
                .map(\.coordinate)
            let predictionCoordinates = prediction.references
                .map(\.coordinate)
            let coordinates = Array(
                Set(authoritativeCoordinates + predictionCoordinates)
            ).sorted()
            guard !coordinates.isEmpty else {
                try retireSurfacesAndFinish()
                return nil
            }
            var authoritativeLease: PaintTileLease?
            var predictionLease: PaintTileLease?
            do {
                if !authoritativeCoordinates.isEmpty {
                    authoritativeLease = try authoritative
                        .leaseExistingTiles(
                            at: authoritativeCoordinates,
                            pinReasons: [.inFlight]
                        )
                }
                if !predictionCoordinates.isEmpty {
                    predictionLease = try prediction.leaseExistingTiles(
                        at: predictionCoordinates,
                        pinReasons: [.inFlight]
                    )
                }
            } catch {
                if let authoritativeLease {
                    try authoritative.returnLease(authoritativeLease)
                }
                throw error
            }
            let token = UUID()
            terminalSource = TerminalSourceRecord(
                token: token,
                coordinates: coordinates,
                authoritativeLease: authoritativeLease,
                predictionLease: predictionLease
            )
            state = .sourceIssued(token)
            return StrokePreparedCommitMutationSource(
                contextIdentity: ownerIdentity,
                storeIdentity: storeIdentity,
                layerID: layerID,
                generation: generation,
                pixelSize: pixelSize,
                radialLayout: radialLayout,
                coordinates: coordinates,
                capability: self,
                sourceToken: token
            )
        }
    }

    fileprivate func claimCommitSource(
        sourceToken: UUID,
        transactionID: UUID
    ) throws -> [StrokePreparedCommitTileSources] {
        try withLock {
            guard state == .sourceIssued(sourceToken),
                  let source = terminalSource,
                  source.token == sourceToken
            else { throw DocumentPaintStrokeSurfaceError.staleCapability }
            guard source.transactionID == nil else {
                throw DocumentPaintStrokeSurfaceError.alreadyClaimed
            }
            source.transactionID = transactionID
            let authoritative = Dictionary(
                uniqueKeysWithValues:
                    (source.authoritativeLease?.bindings ?? []).map {
                        ($0.descriptor.coordinate, $0)
                    }
            )
            let prediction = Dictionary(
                uniqueKeysWithValues:
                    (source.predictionLease?.bindings ?? []).map {
                        ($0.descriptor.coordinate, $0)
                    }
            )
            return source.coordinates.map { coordinate in
                StrokePreparedCommitTileSources(
                    coordinate: coordinate,
                    authoritative: authoritative[coordinate],
                    prediction: prediction[coordinate]
                )
            }
        }
    }

    fileprivate func completeCommitSource(
        sourceToken: UUID,
        transactionID: UUID,
        completion: StrokePreparedCommitMutationCompletion
    ) throws {
        try withLock {
            guard state == .sourceIssued(sourceToken),
                  let source = terminalSource,
                  source.token == sourceToken
            else { throw DocumentPaintStrokeSurfaceError.staleCapability }
            guard source.transactionID == transactionID else {
                throw DocumentPaintStrokeSurfaceError.wrongTransaction
            }
            _ = completion
            try finishTerminalSource(source)
        }
    }

    fileprivate func cancelUnclaimedCommitSource(
        sourceToken: UUID
    ) throws {
        try withLock {
            guard state == .sourceIssued(sourceToken),
                  let source = terminalSource,
                  source.token == sourceToken
            else { throw DocumentPaintStrokeSurfaceError.staleCapability }
            guard source.transactionID == nil else {
                throw DocumentPaintStrokeSurfaceError.alreadyClaimed
            }
            try finishTerminalSource(source)
        }
    }

    func cancel(expectedOwnerIdentity: UUID) throws {
        guard ownerIdentity == expectedOwnerIdentity else {
            throw DocumentPaintStrokeSurfaceError.foreignCapability
        }
        try withLock {
            if case .sourceIssued = state {
                guard let source = terminalSource,
                      source.transactionID == nil
                else { throw DocumentPaintStrokeSurfaceError.alreadyClaimed }
                try finishTerminalSource(source)
                return
            }
            guard state == .active else {
                throw DocumentPaintStrokeSurfaceError.alreadyTerminal
            }
            guard frameReservations.isEmpty,
                  provisionalReservations.isEmpty
            else { throw DocumentPaintStrokeSurfaceError.outstandingFrame }
            try retireSurfacesAndFinish()
        }
    }

    var isTerminal: Bool { withLock { state == .terminal } }

    func makeSparseTransientSource(
        changedRole: StrokePrivateSurfaceLayer,
        changedCoordinates: [PaintTileCoordinate],
        addressing: SparseTileAddressing,
        disposition: SparseTileSourceDisposition = .delta
    ) throws -> [SparseTileSourceRequest] {
        try SparseTileAcceptedSourceAdapter.transient(
            layerID: layerID,
            authoritative: authoritative,
            prediction: prediction,
            changedRole: changedRole,
            changedCoordinates: changedCoordinates,
            addressing: addressing,
            disposition: disposition
        )
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func validatedFrame(
        _ frame: DocumentPaintStrokeFrameReservation
    ) throws -> PaintTileLease {
        guard frame.capabilityToken == capabilityToken,
              let lease = frameReservations[frame.reservationToken]
        else { throw DocumentPaintStrokeSurfaceError.staleCapability }
        return lease
    }

    private func validatedProvisional(
        _ provisional: DocumentPaintStrokeProvisionalReservation,
        frame: DocumentPaintStrokeFrameReservation
    ) throws -> PaintTileProvisionalReservation {
        guard provisional.capabilityToken == capabilityToken,
              provisional.frameReservationToken == frame.reservationToken,
              let raw = provisionalReservations[provisional.reservationToken]
        else { throw DocumentPaintStrokeSurfaceError.staleCapability }
        return raw
    }

    private func finishTerminalSource(
        _ source: TerminalSourceRecord
    ) throws {
        if source.authoritativeLease != nil || source.predictionLease != nil {
            try store.releaseAtomically(
                authoritative: source.authoritativeLease,
                authoritativeSurfaceID: authoritative.surfaceID,
                authoritativeGeneration: generation,
                prediction: source.predictionLease,
                predictionSurfaceID: prediction.surfaceID,
                predictionGeneration: generation
            )
            source.authoritativeLease = nil
            source.predictionLease = nil
        }
        try retireSurfacesAndFinish()
        terminalSource = nil
    }

    private func retireSurfacesAndFinish() throws {
        try store.retireAtomically(
            authoritativeSurfaceID: authoritative.surfaceID,
            predictionSurfaceID: prediction.surfaceID,
            generation: generation
        )
        state = .terminal
        namespaceLease.reportRetired()
        terminalHandler(capabilityToken)
    }

    private static func frameReservation(
        capabilityToken: UUID,
        token: UUID,
        role: DocumentPaintStrokeSurfaceRole,
        lease: PaintTileLease
    ) -> DocumentPaintStrokeFrameReservation {
        DocumentPaintStrokeFrameReservation(
            capabilityToken: capabilityToken,
            reservationToken: token,
            role: role,
            lease: lease
        )
    }

    private static func provisionalReservation(
        capabilityToken: UUID,
        token: UUID,
        frameToken: UUID,
        reservation: PaintTileProvisionalReservation
    ) -> DocumentPaintStrokeProvisionalReservation {
        var bindings: [DocumentPaintStrokeProvisionalBinding] = []
        bindings.reserveCapacity(reservation.count)
        reservation.forEach {
            bindings.append(DocumentPaintStrokeProvisionalBinding(
                identity: $0.identity,
                descriptor: $0.descriptor,
                sourceTexture: $0.sourceTexture,
                candidateTexture: $0.candidateTexture,
                sourceComponentCoverageTexture:
                    $0.sourceComponentCoverageTexture,
                candidateComponentCoverageTexture:
                    $0.candidateComponentCoverageTexture,
                sourceIsKnownClear: $0.sourceIsKnownClear
            ))
        }
        return DocumentPaintStrokeProvisionalReservation(
            capabilityToken: capabilityToken,
            reservationToken: token,
            frameReservationToken: frameToken,
            bindings: bindings
        )
    }
}

public struct DocumentPaintLayerBinding: Sendable {
    public let layerID: UUID
    public let generation: UInt64
    public let canonical: TiledRasterSurface
}

public struct DocumentPaintSurfaceStoreSnapshot: Equatable, Sendable {
    public struct Layer: Equatable, Sendable {
        public let layerID: UUID
        public let references: [PaintTileReference]
    }

    public let generation: UInt64
    public let geometry: DocumentPaintGeometry
    public let layerStack: LayerStack
    public let layers: [Layer]
    public let tileByteBudget: Int
    public let residentTileBytes: Int
    public let backingTileBytes: Int
    public let activeTileLeaseCount: Int
    public let issuedNamespaceCount: Int
    public let preparedCandidateCount: Int
}

/// One canonical visible-source snapshot whose logical key, full fingerprint,
/// selected entitlement, and exact retention all originate from the same
/// immutable registry epoch.
struct DocumentPaintCanonicalVisibleSourceCapture: @unchecked Sendable {
    let key: SparseTileSamplingPlanKey
    let outputRegion: SparseTileOutputRegion
    let sourceBatch: SparseTileOwnedSourceBatch
}

/// Frozen transient providers plus the exact registry-issued capability that
/// authorizes them. The registry derives the canonical source and plan key;
/// callers cannot splice an arbitrary canonical epoch into the union.
struct DocumentPaintTransientVisibleSourceDescriptor: @unchecked Sendable {
    fileprivate let capability: DocumentPaintStrokeSurfaceCapability
    let sources: [SparseTileSourceRequest]
    let authoritativeProvider: TiledRasterExactReferenceProvider
    let predictionProvider: TiledRasterExactReferenceProvider

    var authenticatedStrokeEpoch: UUID { capability.capabilityToken }
    var authenticatedPresentationEpoch: DocumentPaintStrokePresentationEpoch {
        capability.presentationEpoch
    }

    func authenticates(
        presentationEpoch: DocumentPaintStrokePresentationEpoch
    ) -> Bool {
        capability.presentationEpoch === presentationEpoch
            && presentationEpoch.identity == capability.capabilityToken
    }

    init(
        capability: DocumentPaintStrokeSurfaceCapability,
        changedRole: StrokePrivateSurfaceLayer,
        changedCoordinates: [PaintTileCoordinate],
        addressing: SparseTileAddressing,
        disposition: SparseTileSourceDisposition
    ) throws {
        self.capability = capability
        sources = try capability.makeSparseTransientSource(
            changedRole: changedRole,
            changedCoordinates: changedCoordinates,
            addressing: addressing,
            disposition: disposition
        )
        authoritativeProvider = try capability.authoritative
            .makeExactReferenceProvider()
        predictionProvider = try capability.prediction
            .makeExactReferenceProvider()
    }

    /// Cache-copy capture has no display-addressing semantics. The Context
    /// authenticates the registry epoch and freezes only exact physical source
    /// providers; viewport/periodic addressing is introduced later by display.
    init(
        cacheCapability capability: DocumentPaintStrokeSurfaceCapability
    ) throws {
        self.capability = capability
        sources = []
        authoritativeProvider = try capability.authoritative
            .makeExactReferenceProvider()
        predictionProvider = try capability.prediction
            .makeExactReferenceProvider()
    }
}

struct DocumentPaintLayerState: Equatable, Sendable {
    let logicalSurfaceID: UUID
    let revision: RasterRevision
    let references: [PaintTileReference]
}

enum LayerSurfaceRevisionEndpoint: Equatable, Sendable {
    case before
    case after
}

/// One exact before/after layer-registry revision. Metadata is copied as
/// immutable endpoint values while a single bounded snapshot token retains
/// the union of physical tile identities until history releases it.
final class LayerSurfaceHistoryRevision: @unchecked Sendable, Equatable {
    fileprivate struct Endpoint: Equatable, Sendable {
        let geometry: DocumentPaintGeometry
        let layerStack: LayerStack
        let layerStates: [UUID: DocumentPaintLayerState]
        let persistedTileIdentities: PersistedPaintTileIdentitySnapshot
    }

    final class Borrow: @unchecked Sendable {
        fileprivate let revision: LayerSurfaceHistoryRevision
        private let lock = NSLock()
        private var closed = false

        fileprivate init(revision: LayerSurfaceHistoryRevision) {
            self.revision = revision
        }

        func close() {
            lock.lock()
            guard !closed else {
                lock.unlock()
                return
            }
            closed = true
            lock.unlock()
            revision.closeBorrow()
        }

        deinit { close() }
    }

    fileprivate let identity = UUID()
    fileprivate let registryIdentity: UUID
    fileprivate let storeIdentity: PaintTileStoreIdentity
    fileprivate let before: Endpoint
    fileprivate let after: Endpoint
    fileprivate let token: PaintTileSnapshotToken?
    let retainedBytes: Int
    private let lock = NSLock()
    private var activeBorrowCount = 0
    private var closeRequested = false
    private var tokenClosed = false

    fileprivate init(
        registryIdentity: UUID,
        storeIdentity: PaintTileStoreIdentity,
        before: Endpoint,
        after: Endpoint,
        token: PaintTileSnapshotToken?,
        retainedBytes: Int
    ) {
        self.registryIdentity = registryIdentity
        self.storeIdentity = storeIdentity
        self.before = before
        self.after = after
        self.token = token
        self.retainedBytes = retainedBytes
    }

    static func == (
        lhs: LayerSurfaceHistoryRevision,
        rhs: LayerSurfaceHistoryRevision
    ) -> Bool { lhs === rhs }

    func geometry(for endpoint: LayerSurfaceRevisionEndpoint)
        -> DocumentPaintGeometry
    {
        switch endpoint {
        case .before: before.geometry
        case .after: after.geometry
        }
    }

    func layerStack(for endpoint: LayerSurfaceRevisionEndpoint) -> LayerStack {
        switch endpoint {
        case .before: before.layerStack
        case .after: after.layerStack
        }
    }

    func borrow() throws -> Borrow {
        lock.lock()
        defer { lock.unlock() }
        guard !closeRequested else {
            throw DocumentPaintSurfaceStoreError.closedLayerHistoryRevision
        }
        activeBorrowCount += 1
        return Borrow(revision: self)
    }

    func close() {
        lock.lock()
        guard !closeRequested else {
            lock.unlock()
            return
        }
        closeRequested = true
        let shouldClose = activeBorrowCount == 0 && !tokenClosed
        if shouldClose { tokenClosed = true }
        lock.unlock()
        if shouldClose { token?.close() }
    }

    private func closeBorrow() {
        lock.lock()
        precondition(activeBorrowCount > 0)
        activeBorrowCount -= 1
        let shouldClose = closeRequested
            && activeBorrowCount == 0
            && !tokenClosed
        if shouldClose { tokenClosed = true }
        lock.unlock()
        if shouldClose { token?.close() }
    }

    deinit { close() }
}

extension DocumentPaintSurfaceStore {
    func currentStateMatches(
        _ revision: LayerSurfaceHistoryRevision,
        endpoint: LayerSurfaceRevisionEndpoint
    ) -> Bool {
        let target: LayerSurfaceHistoryRevision.Endpoint
        switch endpoint {
        case .before: target = revision.before
        case .after: target = revision.after
        }
        return withLock {
            let epoch = currentEpoch
            return revision.registryIdentity == identity
                && revision.storeIdentity == sharedTileStore.identity
                && epoch.geometry == target.geometry
                && epoch.layerStack == target.layerStack
                && epoch.layerStates == target.layerStates
                && epoch.persistedTileIdentities
                    == target.persistedTileIdentities
        }
    }
}

/// One immutable, coherently published document registry state. Readers copy
/// this single reference under the registry lock, so generation, geometry,
/// layer order, and layer contents can never originate from different commits.
private final class DocumentPaintSurfaceEpoch: @unchecked Sendable {
    let generation: UInt64
    let geometry: DocumentPaintGeometry
    let layerStack: LayerStack
    let layerStates: [UUID: DocumentPaintLayerState]
    let persistedTileIdentities: PersistedPaintTileIdentitySnapshot

    var orderedLayerIDs: [UUID] { layerStack.orderedLayerIDs }

    init(
        generation: UInt64,
        geometry: DocumentPaintGeometry,
        layerStack: LayerStack,
        layerStates: [UUID: DocumentPaintLayerState],
        persistedTileIdentities: PersistedPaintTileIdentitySnapshot
    ) {
        self.generation = generation
        self.geometry = geometry
        self.layerStack = layerStack
        self.layerStates = layerStates
        self.persistedTileIdentities = persistedTileIdentities
    }
}

#if DEBUG
enum DocumentPaintSurfaceEpochTestingPoint: Sendable {
    case snapshotCaptured
    case strokeAuthorityCaptured
    case stableSnapshotCaptured
    case beforePublication
}
#endif

fileprivate struct DocumentPaintSurfaceCandidateBase: Sendable {
    let registryIdentity: UUID
    let generation: UInt64
    let geometry: DocumentPaintGeometry
    let layerStack: LayerStack
    let layers: [UUID: DocumentPaintLayerState]
    let persistedTileIdentities: PersistedPaintTileIdentitySnapshot

    var orderedLayerIDs: [UUID] { layerStack.orderedLayerIDs }
}

/// A transaction-only view captured under the registry lock. The binding and
/// candidate base are deliberately inseparable so a concurrent publication
/// cannot mix generations while a mutation is being prepared.
struct DocumentPaintSurfaceMutationBaseSnapshot: Sendable {
    let generation: UInt64
    let geometry: DocumentPaintGeometry
    let binding: DocumentPaintLayerBinding
    fileprivate let candidateBase: DocumentPaintSurfaceCandidateBase
}

public final class DocumentPaintSurfaceCandidate: @unchecked Sendable {
    fileprivate enum State: Equatable { case open, prepared, consumed }

    fileprivate let registryIdentity: UUID
    fileprivate let store: PaintTileStore
    fileprivate let geometry: DocumentPaintGeometry
    let baseLayerStack: LayerStack
    let layerStack: LayerStack
    fileprivate let basePersistedTileIdentities:
        PersistedPaintTileIdentitySnapshot
    fileprivate let lock = NSLock()
    fileprivate var state: State = .open
    fileprivate var preparedCommit: DocumentPaintPreparedCommit?
    fileprivate var layerStatesStorage: [UUID: DocumentPaintLayerState]
    fileprivate var ownedReferencesStorage: [PaintTileReference]
    fileprivate var persistedTileIdentitySnapshotStorage:
        PersistedPaintTileIdentitySnapshot

    public let baseGeneration: UInt64
    public let generation: UInt64
    public let ownedNamespaces: [DocumentPaintSurfaceNamespace]

    public var ownedReferences: [PaintTileReference] {
        withLock { ownedReferencesStorage }
    }

    var persistedTileIdentitySnapshot: PersistedPaintTileIdentitySnapshot {
        withLock { persistedTileIdentitySnapshotStorage }
    }

    fileprivate init(
        registryIdentity: UUID,
        store: PaintTileStore,
        geometry: DocumentPaintGeometry,
        baseLayerStack: LayerStack,
        layerStack: LayerStack,
        basePersistedTileIdentities: PersistedPaintTileIdentitySnapshot,
        persistedTileIdentitySnapshot: PersistedPaintTileIdentitySnapshot,
        baseGeneration: UInt64,
        generation: UInt64,
        layerStates: [UUID: DocumentPaintLayerState],
        ownedReferences: [PaintTileReference],
        ownedNamespaces: [DocumentPaintSurfaceNamespace]
    ) {
        self.registryIdentity = registryIdentity
        self.store = store
        self.geometry = geometry
        self.baseLayerStack = baseLayerStack
        self.layerStack = layerStack
        self.basePersistedTileIdentities = basePersistedTileIdentities
        self.baseGeneration = baseGeneration
        self.generation = generation
        layerStatesStorage = layerStates
        ownedReferencesStorage = ownedReferences
        persistedTileIdentitySnapshotStorage = persistedTileIdentitySnapshot
        self.ownedNamespaces = ownedNamespaces
    }

    public func binding(for layerID: UUID) throws -> DocumentPaintLayerBinding {
        let layerState = try withLock {
            guard state != .consumed else {
                throw DocumentPaintSurfaceStoreError.candidateAlreadyConsumed
            }
            guard let layerState = layerStatesStorage[layerID] else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            return layerState
        }
        let view = try TiledRasterCoordinateReferenceView(
            storeIdentity: store.identity,
            surfaceID: layerState.logicalSurfaceID,
            layerID: layerID,
            pixelSize: geometry.storagePixelSize,
            generation: generation,
            revision: layerState.revision,
            references: layerState.references
        )
        return DocumentPaintLayerBinding(
            layerID: layerID,
            generation: generation,
            canonical: try TiledRasterSurface(store: store, referenceView: view)
        )
    }

    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public final class DocumentPaintPreparedCommit: @unchecked Sendable {
    fileprivate let candidate: DocumentPaintSurfaceCandidate
    fileprivate let nextEpoch: DocumentPaintSurfaceEpoch
    fileprivate let replacedRetirement: PaintTilePreparedRetirement
    fileprivate let candidateRetirement: PaintTilePreparedRetirement
    fileprivate let reactivation: PaintTilePreparedReactivation?

    fileprivate init(
        candidate: DocumentPaintSurfaceCandidate,
        nextEpoch: DocumentPaintSurfaceEpoch,
        replacedRetirement: PaintTilePreparedRetirement,
        candidateRetirement: PaintTilePreparedRetirement,
        reactivation: PaintTilePreparedReactivation? = nil
    ) {
        self.candidate = candidate
        self.nextEpoch = nextEpoch
        self.replacedRetirement = replacedRetirement
        self.candidateRetirement = candidateRetirement
        self.reactivation = reactivation
    }

    #if DEBUG
    var testingEpochIdentity: ObjectIdentifier {
        ObjectIdentifier(nextEpoch)
    }
    #endif

    var layerTransactionBaseGeneration: UInt64 {
        candidate.baseGeneration
    }

    var layerTransactionGeneration: UInt64 {
        candidate.generation
    }

    var layerTransactionBefore: LayerStack {
        candidate.baseLayerStack
    }

    var layerTransactionAfter: LayerStack {
        candidate.layerStack
    }
}

/// A committed-collection plan is created only while the registry owns the
/// current epoch lock. Its construction is file-private so no caller can pair
/// descriptors derived from one geometry with another retained root.
fileprivate struct DocumentPaintStableCommittedCollectionPlan: Sendable {
    struct RadialPage: Sendable {
        let coordinate: RadialPageCoordinate
        let descriptor: DocumentPaintTightBGRA8Descriptor
    }

    enum Storage: Sendable {
        case single(DocumentPaintTightBGRA8Descriptor)
        case radialPages([RadialPage])
    }

    let storage: Storage

    init(
        addressing: SparseTileAddressing,
        geometry: DocumentPaintGeometry,
        rendererLimits: DocumentPaintStableSnapshotRendererLimits
    ) throws {
        switch addressing {
        case let .finite(size):
            guard geometry.radialLayout == nil,
                  size == geometry.storagePixelSize
            else { throw SparseTileSamplingPlanError.inconsistentAddressing }
            storage = .single(try Self.descriptor(
                for: geometry.storagePixelSize,
                limits: rendererLimits
            ))
        case let .periodic(period):
            guard geometry.radialLayout == nil,
                  period == geometry.storagePixelSize
            else { throw SparseTileSamplingPlanError.inconsistentAddressing }
            storage = .single(try Self.descriptor(
                for: geometry.storagePixelSize,
                limits: rendererLimits
            ))
        case let .radial(layout):
            guard geometry.radialLayout == layout,
                  geometry.storagePixelSize == layout.atlasPixelSize
            else { throw SparseTileSamplingPlanError.inconsistentAddressing }
            storage = .radialPages(try layout.residentPages
                .map(\.coordinate)
                .sorted()
                .map {
                    let descriptor = try DocumentPaintTightBGRA8Descriptor(
                        outputRegion: try Self.logicalPageRegion($0),
                        maximumByteCount: rendererLimits.maximumOutputBytes
                    )
                    try DocumentPaintStableSnapshotChunkPlanner
                        .validateOutput(
                            descriptor.outputRegion,
                            limits: rendererLimits
                        )
                    return RadialPage(
                        coordinate: $0,
                        descriptor: descriptor
                    )
                })
        }
    }

    private static func descriptor(
        for size: PixelSize,
        limits: DocumentPaintStableSnapshotRendererLimits
    ) throws -> DocumentPaintTightBGRA8Descriptor {
        let descriptor = try DocumentPaintTightBGRA8Descriptor(
            outputRegion: try SparseTileOutputRegion(
                minX: 0,
                minY: 0,
                maxX: size.width,
                maxY: size.height
            ),
            maximumByteCount: limits.maximumOutputBytes
        )
        try DocumentPaintStableSnapshotChunkPlanner.validateOutput(
            descriptor.outputRegion,
            limits: limits
        )
        return descriptor
    }

    private static func logicalPageRegion(
        _ coordinate: RadialPageCoordinate
    ) throws -> SparseTileOutputRegion {
        let side = RadialSectorLayout.pageSide
        let (minX, xOverflow) = coordinate.x
            .multipliedReportingOverflow(by: side)
        let (minY, yOverflow) = coordinate.y
            .multipliedReportingOverflow(by: side)
        let (maxX, maxXOverflow) = minX.addingReportingOverflow(side)
        let (maxY, maxYOverflow) = minY.addingReportingOverflow(side)
        guard !xOverflow, !yOverflow, !maxXOverflow, !maxYOverflow else {
            throw DocumentPaintStableCollectionError.arithmeticOverflow
        }
        return try SparseTileOutputRegion(
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY
        )
    }
}

/// The only authority accepted by committed collection. The registry binds
/// the immutable root and its geometry-derived plan in one locked operation;
/// callers can close the owner but cannot construct or separate its parts.
final class DocumentPaintStableCommittedCapture: @unchecked Sendable {
    fileprivate let snapshot: DocumentPaintStableCanonicalSnapshot
    fileprivate let plan: DocumentPaintStableCommittedCollectionPlan

    fileprivate init(
        snapshot: DocumentPaintStableCanonicalSnapshot,
        plan: DocumentPaintStableCommittedCollectionPlan
    ) {
        self.snapshot = snapshot
        self.plan = plan
    }

    var activeChildSelectionCount: Int {
        snapshot.activeChildSelectionCount
    }

    func close() { snapshot.close() }

    deinit { close() }
}

extension DocumentPaintStableCollectionEngine {
    static func collectCommitted(
        _ capture: DocumentPaintStableCommittedCapture,
        renderer: DocumentPaintStableSnapshotRenderer,
        outputGeometryRevision: UInt64
    ) async throws -> DocumentPaintStableCommittedCollection {
        let snapshot = capture.snapshot
        let storage: DocumentPaintStableCommittedStorage
        switch capture.plan.storage {
        case let .single(descriptor):
            storage = .singleRaster(try await collect(
                snapshot: snapshot,
                renderer: renderer,
                descriptor: descriptor,
                outputGeometryRevision: outputGeometryRevision,
                outputMapping: .affine(.identity)
            ))
        case let .radialPages(plannedPages):
            var pages: [DocumentPaintStableCommittedRadialPage] = []
            pages.reserveCapacity(plannedPages.count)
            for page in plannedPages {
                try Task.checkCancellation()
                let image = try await collect(
                    snapshot: snapshot,
                    renderer: renderer,
                    descriptor: page.descriptor,
                    outputGeometryRevision: outputGeometryRevision,
                    outputMapping: .affine(.identity)
                )
                if image.bgra8PremultipliedBytes.contains(where: { $0 != 0 }) {
                    pages.append(DocumentPaintStableCommittedRadialPage(
                        coordinate: page.coordinate,
                        image: image
                    ))
                }
            }
            storage = .radialPages(pages)
        }
        return DocumentPaintStableCommittedCollection(
            documentGeneration: snapshot.documentGeneration,
            documentPixelSize: snapshot.geometry.documentPixelSize,
            storagePixelSize: snapshot.geometry.storagePixelSize,
            storage: storage
        )
    }
}

/// One document-wide sparse surface registry. It is the sole owner of the
/// physical PaintTileStore used by canonical, transient, and future layered
/// surfaces.
public final class DocumentPaintSurfaceStore: @unchecked Sendable {
    static let maximumVisibleCaptureAttempts = 3

    private final class NamespaceRecord {
        let layerID: UUID
        let generation: UInt64
        let authoritativeSurfaceID: UUID
        let predictionSurfaceID: UUID
        weak var ownership: StrokeTileSurfaceNamespaceOwnership?

        init(
            layerID: UUID,
            generation: UInt64,
            authoritativeSurfaceID: UUID,
            predictionSurfaceID: UUID,
            ownership: StrokeTileSurfaceNamespaceOwnership
        ) {
            self.layerID = layerID
            self.generation = generation
            self.authoritativeSurfaceID = authoritativeSurfaceID
            self.predictionSurfaceID = predictionSurfaceID
            self.ownership = ownership
        }

        func matches(_ lease: StrokeTileSurfaceNamespaceLease) -> Bool {
            ownership === lease.ownership
                && ownership?.isOutstanding == true
                && layerID == lease.layerID
                && generation == lease.generation
                && authoritativeSurfaceID == lease.authoritative.surfaceID
                && predictionSurfaceID == lease.prediction.surfaceID
        }
    }

    private let identity = UUID()
    private let lock = NSLock()
    private var currentEpoch: DocumentPaintSurfaceEpoch
    private var preparedCandidateIdentity: ObjectIdentifier?
    private var nextNamespaceToken: UInt64 = 0
    private var namespaceRecords: [UInt64: NamespaceRecord] = [:]

    #if DEBUG
    /// Synchronization-only seam for deterministic publication race tests.
    /// Hooks run while the registry lock is held and must not call the store.
    var testingEpochHook:
        (@Sendable (DocumentPaintSurfaceEpochTestingPoint) -> Void)?
    /// Runs after pure Phase-A selection and before the epoch identity recheck.
    /// Unlike `testingEpochHook`, this seam deliberately runs without the
    /// registry lock so tests can publish a replacement epoch synchronously.
    var testingVisibleSelectionCompleted: (@Sendable () -> Void)?
    #endif

    let sharedTileStore: PaintTileStore

    public convenience init(
        device: any MTLDevice,
        byteBudget: Int,
        snapshotPayloadLiabilityByteBudget: Int? = nil,
        geometry: DocumentPaintGeometry,
        layerIDs: [UUID],
        layerStack: LayerStack? = nil,
        generation: UInt64 = 0
    ) throws {
        let (transferHeadroom, multiplicationOverflow) = byteBudget
            .multipliedReportingOverflow(by: 4)
        let (transferByteCapacity, additionOverflow) = transferHeadroom
            .addingReportingOverflow(PaintTileDescriptor.residentByteCount)
        guard !multiplicationOverflow, !additionOverflow else {
            throw DocumentPaintSurfaceStoreError.transferByteCapacityOverflow
        }
        try self.init(
            device: device,
            byteBudget: byteBudget,
            snapshotPayloadLiabilityByteBudget:
                snapshotPayloadLiabilityByteBudget,
            transferByteCapacity: transferByteCapacity,
            geometry: geometry,
            layerIDs: layerIDs,
            layerStack: layerStack,
            generation: generation
        )
    }

    public init(
        device: any MTLDevice,
        byteBudget: Int,
        snapshotPayloadLiabilityByteBudget: Int? = nil,
        transferByteCapacity: Int,
        geometry: DocumentPaintGeometry,
        layerIDs: [UUID],
        layerStack: LayerStack? = nil,
        generation: UInt64 = 0
    ) throws {
        var seen: Set<UUID> = []
        var states: [UUID: DocumentPaintLayerState] = [:]
        var initialNamespaceToken: UInt64 = 0
        for layerID in layerIDs {
            guard seen.insert(layerID).inserted else {
                throw DocumentPaintSurfaceStoreError.duplicateLayerID(layerID)
            }
            let (token, overflow) = initialNamespaceToken
                .addingReportingOverflow(1)
            guard !overflow else {
                throw DocumentPaintSurfaceStoreError.namespaceIdentityOverflow
            }
            initialNamespaceToken = token
            states[layerID] = DocumentPaintLayerState(
                logicalSurfaceID: Self.surfaceID(
                    role: .canonical,
                    token: token
                ),
                revision: RasterRevision(rawValue: 0),
                references: []
            )
        }
        let resolvedLayerStack: LayerStack
        if let layerStack {
            guard layerStack.orderedLayerIDs == layerIDs else {
                throw DocumentPaintSurfaceStoreError.layerStackMismatch(
                    expected: layerIDs,
                    actual: layerStack.orderedLayerIDs
                )
            }
            resolvedLayerStack = layerStack
        } else {
            guard let activeLayerID = layerIDs.first else {
                throw LayerStackError.emptyStack
            }
            let descriptors = try layerIDs.enumerated().map { index, id in
                try LayerDescriptor(id: id, name: "Layer \(index + 1)")
            }
            resolvedLayerStack = try LayerStack(
                layers: descriptors,
                activeLayerID: activeLayerID
            )
        }
        sharedTileStore = PaintTileStore(
            device: device,
            byteBudget: byteBudget,
            transferByteCapacity: transferByteCapacity,
            snapshotPayloadLiabilityByteBudget:
                snapshotPayloadLiabilityByteBudget
        )
        currentEpoch = DocumentPaintSurfaceEpoch(
            generation: generation,
            geometry: geometry,
            layerStack: resolvedLayerStack,
            layerStates: states,
            persistedTileIdentities: .empty
        )
        nextNamespaceToken = initialNamespaceToken
    }

    public var tileStoreIdentity: PaintTileStoreIdentity {
        sharedTileStore.identity
    }

    public var generation: UInt64 { withLock { currentEpoch.generation } }
    public var geometry: DocumentPaintGeometry { withLock { currentEpoch.geometry } }
    public var layerIDs: [UUID] { withLock { currentEpoch.orderedLayerIDs } }
    public var layerStack: LayerStack { withLock { currentEpoch.layerStack } }

    public func persistedTileIdentitySnapshot()
        -> PersistedPaintTileIdentitySnapshot
    {
        withLock { currentEpoch.persistedTileIdentities }
    }

    public func captureNativeArchive()
        throws -> DocumentPaintNativeArchiveCapture
    {
        try withLock {
            let epoch = currentEpoch
            let references = epoch.orderedLayerIDs.flatMap {
                epoch.layerStates[$0]?.references ?? []
            }
            try PersistedPaintTileIdentityMap.validateExact(
                epoch.persistedTileIdentities,
                references: references
            )

            var providers: [TiledRasterExactReferenceProvider] = []
            providers.reserveCapacity(epoch.orderedLayerIDs.count)
            var layers: [DocumentPaintNativeArchiveLayer] = []
            layers.reserveCapacity(epoch.orderedLayerIDs.count)
            var payloadAuthorities:
                [UUID: DocumentPaintNativeArchiveCapture.PayloadAuthority]
                = [:]
            for descriptor in epoch.layerStack.layers {
                guard let state = epoch.layerStates[descriptor.id] else {
                    throw DocumentPaintSurfaceStoreError
                        .unknownLayerID(descriptor.id)
                }
                let binding = try makeBinding(
                    for: descriptor.id,
                    state: state,
                    geometry: epoch.geometry,
                    generation: epoch.generation
                )
                let provider = try binding.canonical
                    .makeExactReferenceProvider()
                providers.append(provider)
                var tiles: [DocumentPaintNativeArchiveTile] = []
                tiles.reserveCapacity(state.references.count)
                for reference in state.references.sorted() {
                    guard let persistedID = epoch.persistedTileIdentities
                        .persistedID(for: reference.identity)
                    else {
                        throw PersistedPaintTileIdentityMapError
                            .missingRuntimeIdentity(reference.identity)
                    }
                    tiles.append(DocumentPaintNativeArchiveTile(
                        persistedID: persistedID,
                        coordinate: reference.coordinate,
                        logicalBounds: reference.descriptor.logicalBounds
                    ))
                    payloadAuthorities[persistedID] = .init(
                        provider: provider,
                        reference: reference
                    )
                }
                layers.append(DocumentPaintNativeArchiveLayer(
                    layerID: descriptor.id,
                    rasterRevision: state.revision.rawValue,
                    tiles: tiles
                ))
            }
            let root = try TiledRasterExactReferenceCapture(
                providers: providers
            )
            return DocumentPaintNativeArchiveCapture(
                documentGeneration: epoch.generation,
                geometry: epoch.geometry,
                layerStack: epoch.layerStack,
                layers: layers,
                root: root,
                payloadAuthorityByPersistedID: payloadAuthorities
            )
        }
    }

    func prepareNativeArchiveImport(
        _ manifest: DocumentPaintNativeArchiveImportManifest
    ) throws -> DocumentPaintNativeArchiveImportWriter {
        let base = withLock {
            let epoch = currentEpoch
            return DocumentPaintSurfaceCandidateBase(
                registryIdentity: identity,
                generation: epoch.generation,
                geometry: epoch.geometry,
                layerStack: epoch.layerStack,
                layers: epoch.layerStates,
                persistedTileIdentities: epoch.persistedTileIdentities
            )
        }
        guard base.layerStack == manifest.layerStack,
              base.geometry == manifest.geometry,
              base.layers.values.allSatisfy({ $0.references.isEmpty }),
              base.persistedTileIdentities.bindings.isEmpty
        else {
            throw DocumentPaintSurfaceStoreError
                .nativeImportRequiresEmptyStore
        }
        var dirty: [UUID: [PaintTileCoordinate]] = [:]
        var imports: [PersistedPaintTileImportBinding] = []
        var revisions: [UUID: RasterRevision] = [:]
        var expectedIDs = Set<UUID>()
        for layer in manifest.layers {
            dirty[layer.layerID] = layer.tiles.map(\.coordinate)
            revisions[layer.layerID] = RasterRevision(
                rawValue: layer.rasterRevision
            )
            for tile in layer.tiles {
                imports.append(PersistedPaintTileImportBinding(
                    persistedID: tile.persistedID,
                    layerID: layer.layerID,
                    coordinate: tile.coordinate
                ))
                expectedIDs.insert(tile.persistedID)
            }
        }
        let candidate = try makeCandidate(
            from: base,
            geometry: manifest.geometry,
            layerStack: manifest.layerStack,
            dirtyCoordinatesByLayer: dirty,
            removingCoordinatesByLayer: [:],
            importedPersistedTileBindings: imports,
            importedRasterRevisionsByLayer: revisions,
            failureInjection: nil
        )
        return DocumentPaintNativeArchiveImportWriter(
            store: self,
            candidate: candidate,
            expectedIDs: expectedIDs
        )
    }

    func installNativeArchivePayload(
        _ payload: Data,
        for persistedTileID: UUID,
        into candidate: DocumentPaintSurfaceCandidate
    ) throws {
        let reference = try candidate.withLock { () throws
            -> PaintTileReference in
            guard candidate.registryIdentity == identity,
                  candidate.store === sharedTileStore,
                  candidate.state == .open,
                  let runtimeIdentity = candidate
                    .persistedTileIdentitySnapshotStorage
                    .identity(for: persistedTileID),
                  let reference = candidate.ownedReferencesStorage.first(
                    where: { $0.identity == runtimeIdentity }
                  )
            else {
                throw DocumentPaintNativeArchiveImportError
                    .unexpectedPersistedTileID(persistedTileID)
            }
            return reference
        }
        try sharedTileStore.installNativeArchivePayload(
            payload,
            exactReference: reference
        )
    }

    #if DEBUG
    var testingCurrentEpochIdentity: ObjectIdentifier {
        withLock { ObjectIdentifier(currentEpoch) }
    }
    #endif

    public func binding(for layerID: UUID) throws -> DocumentPaintLayerBinding {
        try withLock {
            let epoch = currentEpoch
            guard let state = epoch.layerStates[layerID] else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            return try makeBinding(
                for: layerID,
                state: state,
                geometry: epoch.geometry,
                generation: epoch.generation
            )
        }
    }

    /// Captures one complete canonical layer from exactly one immutable epoch.
    /// Root retention is installed while holding registry -> tile-store locks,
    /// the same order used by publication, so retirement cannot cross capture.
    func captureStableCanonicalSnapshot(
        layerID: UUID,
        addressing: SparseTileAddressing,
        addressingRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping? = nil,
        limits: DocumentPaintStableCanonicalSnapshotLimits = .documentProduction
    ) throws -> DocumentPaintStableCanonicalSnapshot {
        try withLock {
            let epoch = currentEpoch
            guard let state = epoch.layerStates[layerID] else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            try Self.validateVisibleAddressing(
                addressing,
                geometry: epoch.geometry
            )
            if let outputMapping {
                try Self.validateStableOutputMapping(
                    outputMapping,
                    addressing: addressing,
                    geometry: epoch.geometry
                )
            }
            #if DEBUG
            testingEpochHook?(.stableSnapshotCaptured)
            #endif
            return try makeStableCanonicalSnapshot(
                epoch: epoch,
                layerID: layerID,
                state: state,
                addressing: addressing,
                addressingRevision: addressingRevision,
                limits: limits
            )
        }
    }

    /// Creates the storage plan and retains its exact canonical root from the
    /// same immutable epoch while holding the registry lock. Plan and output
    /// limits fail before exact-reference retention is published.
    func captureStableCommittedCollection(
        layerID: UUID,
        addressing: SparseTileAddressing,
        addressingRevision: UInt64,
        rendererLimits: DocumentPaintStableSnapshotRendererLimits,
        snapshotLimits: DocumentPaintStableCanonicalSnapshotLimits =
            .documentProduction
    ) throws -> DocumentPaintStableCommittedCapture {
        try withLock {
            let epoch = currentEpoch
            guard let state = epoch.layerStates[layerID] else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            let plan = try DocumentPaintStableCommittedCollectionPlan(
                addressing: addressing,
                geometry: epoch.geometry,
                rendererLimits: rendererLimits
            )
            #if DEBUG
            testingEpochHook?(.stableSnapshotCaptured)
            #endif
            let snapshot = try makeStableCanonicalSnapshot(
                epoch: epoch,
                layerID: layerID,
                state: state,
                addressing: addressing,
                addressingRevision: addressingRevision,
                limits: snapshotLimits
            )
            return DocumentPaintStableCommittedCapture(
                snapshot: snapshot,
                plan: plan
            )
        }
    }

    /// Requires an addressing request already validated against `epoch`.
    /// Callers hold the registry lock across this exact-retention publication.
    private func makeStableCanonicalSnapshot(
        epoch: DocumentPaintSurfaceEpoch,
        layerID: UUID,
        state: DocumentPaintLayerState,
        addressing: SparseTileAddressing,
        addressingRevision: UInt64,
        limits: DocumentPaintStableCanonicalSnapshotLimits
    ) throws -> DocumentPaintStableCanonicalSnapshot {
        let binding = try makeBinding(
            for: layerID,
            state: state,
            geometry: epoch.geometry,
            generation: epoch.generation
        )
        let source = try SparseTileAcceptedSourceAdapter.canonical(
            binding,
            addressing: addressing
        )
        let capture = try TiledRasterExactReferenceCapture(
            providers: [source.provider]
        )
        return DocumentPaintStableCanonicalSnapshot(
            documentGeneration: epoch.generation,
            geometry: epoch.geometry,
            layerID: layerID,
            revision: state.revision,
            addressing: addressing,
            addressingRevision: addressingRevision,
            source: source,
            capture: capture,
            maximumReferenceCountFromStoreBudget:
                sharedTileStore.byteBudget
                    / PaintTileDescriptor.residentByteCount,
            limits: limits
        )
    }

    /// Selects and retains the current canonical visible source without any
    /// caller-supplied generation or content identity.
    ///
    /// Phase A copies one immutable epoch under the registry lock, then performs
    /// the pure viewport/halo selection outside all locks. Phase B reacquires
    /// the registry lock, retries only when the epoch reference changed, and
    /// installs exact retention while holding registry -> PaintTileStore locks.
    /// That ordering prevents publication retirement from crossing the exact
    /// capture boundary.
    func captureCanonicalVisibleSources(
        layerID: UUID,
        addressing: SparseTileAddressing,
        addressingRevision: UInt64,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping = .affine(.identity)
    ) throws -> DocumentPaintCanonicalVisibleSourceCapture {
        for _ in 0..<Self.maximumVisibleCaptureAttempts {
            let attempt = try withLock { () throws -> (
                epoch: DocumentPaintSurfaceEpoch,
                state: DocumentPaintLayerState,
                hook: (@Sendable () -> Void)?
            ) in
                let epoch = currentEpoch
                guard let state = epoch.layerStates[layerID] else {
                    throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
                }
                #if DEBUG
                let hook = testingVisibleSelectionCompleted
                #else
                let hook: (@Sendable () -> Void)? = nil
                #endif
                return (epoch, state, hook)
            }
            let binding = try makeBinding(
                for: layerID,
                state: attempt.state,
                geometry: attempt.epoch.geometry,
                generation: attempt.epoch.generation
            )
            try Self.validateVisibleAddressing(
                addressing,
                geometry: attempt.epoch.geometry
            )
            let source = try SparseTileAcceptedSourceAdapter.canonical(
                binding,
                addressing: addressing
            )
            let key = SparseTileSamplingPlanKey(
                documentGeneration: attempt.epoch.generation,
                orderedLayers: [SparseTileLayerContentKey(
                    layerID: layerID,
                    roles: [source.contentKey]
                )],
                addressingRevision: addressingRevision,
                outputGeometryRevision: outputGeometryRevision,
                outputMapping: outputMapping
            )
            let selection = try SparseTileOwnedSourceBatch.selecting(
                sources: [source],
                key: key,
                outputRegion: outputRegion
            )
            attempt.hook?()

            let batch: SparseTileOwnedSourceBatch? = try withLock {
                guard currentEpoch === attempt.epoch else { return nil }
                return try SparseTileOwnedSourceBatch.capturing(selection)
            }
            guard let batch else { continue }
            return DocumentPaintCanonicalVisibleSourceCapture(
                key: key,
                outputRegion: outputRegion,
                sourceBatch: batch
            )
        }
        throw DocumentPaintSurfaceStoreError.visibleCaptureContention(
            maximumAttempts: Self.maximumVisibleCaptureAttempts
        )
    }

    /// Freezes one validated stack and one immutable registry epoch into
    /// bottom-to-top sparse layer plans. Pure viewport selection and plan
    /// construction happen before Phase B installs one aggregate exact root.
    func prepareLayerCompositePlan(
        layerStack requestedLayerStack: LayerStack? = nil,
        transient: PreparedLayerCompositeTransientSource? = nil,
        addressing: SparseTileAddressing,
        addressingRevision: UInt64,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping = .affine(.identity),
        limits: SparseTilePlanLimits
    ) throws -> PreparedLayerCompositePlan {
        let transientLease = transient?.descriptor.capability.namespaceLease
        for _ in 0..<Self.maximumVisibleCaptureAttempts {
            let attempt = try withLock { () throws -> (
                epoch: DocumentPaintSurfaceEpoch,
                layers: [(LayerDescriptor, DocumentPaintLayerState)],
                transientNamespaceToken: UInt64?,
                hook: (@Sendable () -> Void)?
            ) in
                let epoch = currentEpoch
                let layerStack = requestedLayerStack ?? epoch.layerStack
                guard requestedLayerStack == nil
                    || epoch.layerStack == layerStack
                else {
                    throw DocumentPaintSurfaceStoreError.layerStackMismatch(
                        expected: epoch.orderedLayerIDs,
                        actual: layerStack.orderedLayerIDs
                    )
                }
                try Self.validateVisibleAddressing(
                    addressing,
                    geometry: epoch.geometry
                )
                try Self.validateStableOutputMapping(
                    outputMapping,
                    addressing: addressing,
                    geometry: epoch.geometry
                )
                if let transient, let transientLease {
                    try validateTransientDescriptorLocked(
                        transient.descriptor,
                        lease: transientLease,
                        layerID: transient.layerID,
                        epoch: epoch,
                        addressing: addressing
                    )
                }
                let layers = layerStack.layers.compactMap { layer
                    -> (LayerDescriptor, DocumentPaintLayerState)? in
                    guard layer.isVisible,
                          layer.opacity > 0,
                          let state = epoch.layerStates[layer.id],
                          !state.references.isEmpty
                            || transient?.layerID == layer.id
                    else { return nil }
                    return (layer, state)
                }
                #if DEBUG
                let hook = testingVisibleSelectionCompleted
                #else
                let hook: (@Sendable () -> Void)? = nil
                #endif
                return (
                    epoch,
                    layers,
                    transientLease?.retirementToken,
                    hook
                )
            }

            var preparedLayers: [PreparedLayerCompositeLayer] = []
            var capturedProviders: [TiledRasterExactReferenceProvider] = []
            preparedLayers.reserveCapacity(attempt.layers.count)
            capturedProviders.reserveCapacity(attempt.layers.count)
            for (layer, state) in attempt.layers {
                let binding = try makeBinding(
                    for: layer.id,
                    state: state,
                    geometry: attempt.epoch.geometry,
                    generation: attempt.epoch.generation
                )
                let source = try SparseTileAcceptedSourceAdapter.canonical(
                    binding,
                    addressing: addressing
                )
                let sources = transient?.layerID == layer.id
                    ? [source] + transient!.descriptor.sources
                    : [source]
                let key = SparseTileSamplingPlanKey(
                    documentGeneration: attempt.epoch.generation,
                    orderedLayers: [SparseTileLayerContentKey(
                        layerID: layer.id,
                        roles: sources.map(\.contentKey)
                    )],
                    addressingRevision: addressingRevision,
                    outputGeometryRevision: outputGeometryRevision,
                    outputMapping: outputMapping
                )
                let selection = try SparseTileOwnedSourceBatch.selecting(
                    sources: sources,
                    key: key,
                    outputRegion: outputRegion
                )
                guard try selection.selectedReferenceCount() > 0 else {
                    continue
                }
                let restrictedSources = try selection.restrictedSources()
                let snapshots = try restrictedSources.map {
                    try SparseTileSourceSnapshot(
                        contentKey: $0.contentKey,
                        addressing: $0.addressing,
                        layerID: $0.layerID,
                        references: $0.references,
                        changedCoordinates: $0.changedCoordinates,
                        disposition: $0.disposition
                    )
                }
                let content = try SparseTileSamplingPlanBuilder.buildFull(
                    key: key,
                    sources: snapshots,
                    outputRegion: outputRegion,
                    limits: limits
                )
                preparedLayers.append(PreparedLayerCompositeLayer(
                    layerID: layer.id,
                    opacity: layer.opacity,
                    blendMode: layer.blendMode,
                    samplingPlan: content,
                    samplingParameters: transient?.layerID == layer.id
                        ? transient!.samplingParameters
                        : SparseTileSamplingEncodeParameters(
                            outputMapping: outputMapping,
                            compositeMode: PatternCompositeWireDraw,
                            liveVisible: false,
                            strokeOpacity: 1,
                            accumulationLimit: 1,
                            eraserStrength: 1
                        ),
                    sourceSelection: selection
                ))
                capturedProviders.append(contentsOf:
                    restrictedSources.map(\.provider))
            }
            attempt.hook?()

            let capture: TiledRasterExactReferenceCapture? = try withLock {
                guard currentEpoch === attempt.epoch else { return nil }
                if let transient, let transientLease {
                    try validateTransientDescriptorLocked(
                        transient.descriptor,
                        lease: transientLease,
                        layerID: transient.layerID,
                        epoch: attempt.epoch,
                        addressing: addressing
                    )
                    guard transientLease.retirementToken
                            == attempt.transientNamespaceToken
                    else {
                        throw DocumentPaintStrokeSurfaceError.staleCapability
                    }
                }
                return try TiledRasterExactReferenceCapture(
                    providers: capturedProviders
                )
            }
            guard let capture else { continue }
            return PreparedLayerCompositePlan(
                documentGeneration: attempt.epoch.generation,
                geometry: attempt.epoch.geometry,
                outputRegion: outputRegion,
                outputMapping: outputMapping,
                layers: preparedLayers,
                sourceCapture: capture,
                planLimits: limits
            )
        }
        throw DocumentPaintSurfaceStoreError.visibleCaptureContention(
            maximumAttempts: Self.maximumVisibleCaptureAttempts
        )
    }

    /// Freezes raw canonical storage pixels for a cache update. Unlike display
    /// preparation this path always uses finite storage addressing and an
    /// identity output mapping, including periodic and radial documents.
    func prepareCompositeTileUpdatePlan(
        baseIdentity: CanvasCanonicalStateIdentity,
        targetIdentity: CanvasCanonicalStateIdentity,
        invalidation: CanvasCompositeInvalidation,
        cachedCoordinates: [PaintTileCoordinate],
        identityClaim: CanvasCanonicalIdentityClaim,
        limits: SparseTilePlanLimits
    ) throws -> CanvasCompositeTileUpdatePlan {
        for _ in 0..<Self.maximumVisibleCaptureAttempts {
            let attempt = try withLock { () throws -> (
                epoch: DocumentPaintSurfaceEpoch,
                dirty: [PaintTileCoordinate],
                layers: [(LayerDescriptor, DocumentPaintLayerState)],
                hook: (@Sendable () -> Void)?
            ) in
                let epoch = currentEpoch
                guard targetIdentity.geometry == epoch.geometry,
                      identityClaim.validatesPreparation(
                        baseIdentity: baseIdentity,
                        targetIdentity: targetIdentity,
                        invalidation: invalidation
                      )
                else {
                    throw CanvasCompositeTileCacheError.staleIdentity(
                        expected: targetIdentity,
                        current: identityClaim.identity
                    )
                }
                let visible = epoch.layerStack.layers.compactMap { layer
                    -> (LayerDescriptor, DocumentPaintLayerState)? in
                    guard layer.isVisible, layer.opacity > 0,
                          let state = epoch.layerStates[layer.id]
                    else { return nil }
                    return (layer, state)
                }
                let requested: [PaintTileCoordinate]
                switch invalidation {
                case .none, .metadataOnly:
                    requested = []
                case .exact(let coordinates):
                    requested = coordinates
                case .full:
                    let targetCoordinates = visible.flatMap {
                        $0.1.references.map(\.coordinate)
                    }
                    // A geometry replacement discards the prior cache
                    // namespace wholesale. Old coordinates outside the new
                    // storage extent must not be validated or prepared in the
                    // target geometry; the cache retires every old reference.
                    requested = targetCoordinates
                        + (baseIdentity.geometry == targetIdentity.geometry
                            ? cachedCoordinates : [])
                }
                let dirty = CanvasCompositeInvalidation.sortedUnique(requested)
                for coordinate in dirty {
                    _ = try PaintTileDescriptor(
                        coordinate: coordinate,
                        logicalPixelSize: epoch.geometry.storagePixelSize
                    )
                }
                #if DEBUG
                let hook = testingVisibleSelectionCompleted
                #else
                let hook: (@Sendable () -> Void)? = nil
                #endif
                return (epoch, dirty, visible, hook)
            }

            let regions = try CanvasCompositeTileUpdatePlan.outputRegions(
                dirtyCoordinates: attempt.dirty,
                storagePixelSize: attempt.epoch.geometry.storagePixelSize
            )
            var preparedTiles: [PreparedLayerCompositeTile] = []
            var capturedProviders: [TiledRasterExactReferenceProvider] = []
            preparedTiles.reserveCapacity(attempt.dirty.count)
            for (coordinate, outputRegion) in zip(attempt.dirty, regions) {
                var preparedLayers: [PreparedLayerCompositeLayer] = []
                for (layer, state) in attempt.layers {
                    let binding = try makeBinding(
                        for: layer.id,
                        state: state,
                        geometry: attempt.epoch.geometry,
                        generation: attempt.epoch.generation
                    )
                    let source = try SparseTileAcceptedSourceAdapter.canonical(
                        binding,
                        addressing: .finite(
                            attempt.epoch.geometry.storagePixelSize
                        )
                    )
                    let key = SparseTileSamplingPlanKey(
                        documentGeneration: attempt.epoch.generation,
                        orderedLayers: [SparseTileLayerContentKey(
                            layerID: layer.id,
                            roles: [source.contentKey]
                        )],
                        addressingRevision: targetIdentity.compositeRevision,
                        outputGeometryRevision: targetIdentity.geometryRevision,
                        outputMapping: .affine(.identity)
                    )
                    let selection = try SparseTileOwnedSourceBatch.selecting(
                        sources: [source],
                        key: key,
                        outputRegion: outputRegion
                    )
                    guard try selection.selectedReferenceCount() > 0 else {
                        continue
                    }
                    let restricted = try selection.restrictedSources(
                        referenceScope: .entitlement
                    )
                    let snapshots = try restricted.map {
                        try SparseTileSourceSnapshot(
                            contentKey: $0.contentKey,
                            addressing: $0.addressing,
                            layerID: $0.layerID,
                            references: $0.references,
                            changedCoordinates: $0.changedCoordinates,
                            disposition: $0.disposition
                        )
                    }
                    preparedLayers.append(PreparedLayerCompositeLayer(
                        layerID: layer.id,
                        opacity: layer.opacity,
                        blendMode: layer.blendMode,
                        samplingPlan: try SparseTileSamplingPlanBuilder.buildFull(
                            key: key,
                            sources: snapshots,
                            outputRegion: outputRegion,
                            limits: limits
                        ),
                        samplingParameters: SparseTileSamplingEncodeParameters(
                            outputMapping: .affine(.identity),
                            compositeMode: PatternCompositeWireDraw,
                            liveVisible: false,
                            strokeOpacity: 1,
                            accumulationLimit: 1,
                            eraserStrength: 1
                        ),
                        sourceSelection: selection
                    ))
                    capturedProviders.append(contentsOf: restricted.map {
                        $0.provider
                    })
                }
                preparedTiles.append(PreparedLayerCompositeTile(
                    coordinate: coordinate,
                    outputRegion: outputRegion,
                    layers: preparedLayers
                ))
            }
            attempt.hook?()

            let capture: TiledRasterExactReferenceCapture? = try withLock {
                guard currentEpoch === attempt.epoch else { return nil }
                guard identityClaim.validatesPreparation(
                    baseIdentity: baseIdentity,
                    targetIdentity: targetIdentity,
                    invalidation: invalidation
                ) else {
                    throw CanvasCompositeTileCacheError.staleIdentity(
                        expected: targetIdentity,
                        current: identityClaim.identity
                    )
                }
                return try TiledRasterExactReferenceCapture(
                    providers: capturedProviders
                )
            }
            guard let capture else { continue }
            let epochID = ObjectIdentifier(attempt.epoch)
            return CanvasCompositeTileUpdatePlan(
                baseIdentity: baseIdentity,
                targetIdentity: targetIdentity,
                invalidation: invalidation,
                dirtyCoordinates: attempt.dirty,
                preparedTiles: preparedTiles,
                registryGeneration: attempt.epoch.generation,
                identityClaim: identityClaim,
                epochIsCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.withLock {
                        ObjectIdentifier(self.currentEpoch) == epochID
                    }
                },
                sourceCapture: capture
            )
        }
        throw DocumentPaintSurfaceStoreError.visibleCaptureContention(
            maximumAttempts: Self.maximumVisibleCaptureAttempts
        )
    }

    /// Captures one coherent canonical + authoritative + prediction union.
    /// Capability/provider freezing happens before this call. Registry state is
    /// consulted only under its lock; no capability or ownership lock is taken
    /// while the registry lock is held.
    func captureTransientVisibleSources(
        layerID: UUID,
        descriptor: DocumentPaintTransientVisibleSourceDescriptor,
        addressing: SparseTileAddressing,
        addressingRevision: UInt64,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping = .affine(.identity)
    ) throws -> DocumentPaintCanonicalVisibleSourceCapture {
        let capability = descriptor.capability
        let lease = capability.namespaceLease
        for _ in 0..<Self.maximumVisibleCaptureAttempts {
            let attempt = try withLock { () throws -> (
                epoch: DocumentPaintSurfaceEpoch,
                state: DocumentPaintLayerState,
                namespaceToken: UInt64,
                hook: (@Sendable () -> Void)?
            ) in
                let epoch = currentEpoch
                guard let state = epoch.layerStates[layerID] else {
                    throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
                }
                try validateTransientDescriptorLocked(
                    descriptor,
                    lease: lease,
                    layerID: layerID,
                    epoch: epoch,
                    addressing: addressing
                )
                try Self.validateVisibleAddressing(
                    addressing,
                    geometry: epoch.geometry
                )
                #if DEBUG
                let hook = testingVisibleSelectionCompleted
                #else
                let hook: (@Sendable () -> Void)? = nil
                #endif
                return (epoch, state, lease.retirementToken, hook)
            }
            let binding = try makeBinding(
                for: layerID,
                state: attempt.state,
                geometry: attempt.epoch.geometry,
                generation: attempt.epoch.generation
            )
            let canonical = try SparseTileAcceptedSourceAdapter.canonical(
                binding,
                addressing: addressing
            )
            let sources = [canonical] + descriptor.sources
            let key = SparseTileSamplingPlanKey(
                documentGeneration: attempt.epoch.generation,
                orderedLayers: [SparseTileLayerContentKey(
                    layerID: layerID,
                    roles: sources.map(\.contentKey)
                )],
                addressingRevision: addressingRevision,
                outputGeometryRevision: outputGeometryRevision,
                outputMapping: outputMapping
            )
            let selection = try SparseTileOwnedSourceBatch.selecting(
                sources: sources,
                key: key,
                outputRegion: outputRegion
            )
            attempt.hook?()

            let batch: SparseTileOwnedSourceBatch? = try withLock {
                guard currentEpoch === attempt.epoch else { return nil }
                try validateTransientDescriptorLocked(
                    descriptor,
                    lease: lease,
                    layerID: layerID,
                    epoch: attempt.epoch,
                    addressing: addressing
                )
                guard lease.retirementToken == attempt.namespaceToken else {
                    throw DocumentPaintStrokeSurfaceError.staleCapability
                }
                return try SparseTileOwnedSourceBatch.capturing(selection)
            }
            guard let batch else { continue }
            return DocumentPaintCanonicalVisibleSourceCapture(
                key: key,
                outputRegion: outputRegion,
                sourceBatch: batch
            )
        }
        throw DocumentPaintSurfaceStoreError.visibleCaptureContention(
            maximumAttempts: Self.maximumVisibleCaptureAttempts
        )
    }

    /// Requires the registry lock. Deliberately compares only immutable
    /// capability/lease fields and registry record identity: it never calls
    /// capability state or namespace ownership methods while this lock is held.
    private func validateTransientDescriptorLocked(
        _ descriptor: DocumentPaintTransientVisibleSourceDescriptor,
        lease: StrokeTileSurfaceNamespaceLease,
        layerID: UUID,
        epoch: DocumentPaintSurfaceEpoch,
        addressing: SparseTileAddressing
    ) throws {
        let capability = descriptor.capability
        guard capability.storeIdentity == sharedTileStore.identity,
              capability.layerID == layerID,
              capability.generation == epoch.generation,
              capability.pixelSize == epoch.geometry.storagePixelSize,
              capability.radialLayout == epoch.geometry.radialLayout,
              lease.storeIdentity == sharedTileStore.identity,
              lease.layerID == layerID,
              lease.generation == epoch.generation,
              let record = namespaceRecords[lease.retirementToken],
              record.ownership === lease.ownership,
              record.layerID == layerID,
              record.generation == epoch.generation,
              record.authoritativeSurfaceID
                == capability.authoritativeSurfaceID,
              record.predictionSurfaceID == capability.predictionSurfaceID,
              descriptor.sources.map(\.role)
                == [.authoritative, .prediction]
        else { throw DocumentPaintStrokeSurfaceError.staleCapability }

        for (source, expectedSurfaceID) in zip(
            descriptor.sources,
            [capability.authoritativeSurfaceID, capability.predictionSurfaceID]
        ) {
            guard source.provider.storeIdentity == sharedTileStore.identity,
                  source.addressing == addressing,
                  source.layerID == layerID,
                  source.provider.generation == epoch.generation,
                  source.provider.pixelSize == epoch.geometry.storagePixelSize,
                  source.provider.surfaceID == expectedSurfaceID,
                  source.contentKey.surfaceIdentity == expectedSurfaceID,
                  source.contentKey.contentRevision
                    == source.provider.revision.rawValue,
                  source.contentKey.bindingChunkRevision
                    == source.provider.revision.rawValue
            else { throw DocumentPaintStrokeSurfaceError.staleCapability }
        }
    }

    private static func validateVisibleAddressing(
        _ addressing: SparseTileAddressing,
        geometry: DocumentPaintGeometry
    ) throws {
        switch addressing {
        case let .finite(size):
            guard geometry.radialLayout == nil,
                  size == geometry.storagePixelSize
            else { throw SparseTileSamplingPlanError.inconsistentAddressing }
        case let .periodic(period):
            guard geometry.radialLayout == nil,
                  period == geometry.storagePixelSize
            else { throw SparseTileSamplingPlanError.inconsistentAddressing }
        case let .radial(layout):
            guard geometry.radialLayout == layout,
                  geometry.storagePixelSize == layout.atlasPixelSize
            else { throw SparseTileSamplingPlanError.inconsistentAddressing }
        }
    }

    private static func validateStableOutputMapping(
        _ outputMapping: SparseTileSamplingOutputMapping,
        addressing: SparseTileAddressing,
        geometry: DocumentPaintGeometry
    ) throws {
        switch outputMapping {
        case let .affine(transform):
            guard transform.sourceOffset.x.isFinite,
                  transform.sourceOffset.y.isFinite,
                  transform.sourceStep.x.isFinite,
                  transform.sourceStep.y.isFinite
            else {
                throw DocumentPaintStableSnapshotRendererError.invalidRequest
            }
        case let .finiteRadial(mapping):
            guard case let .radial(layout) = addressing,
                  layout == mapping.layout,
                  geometry.radialLayout == mapping.layout,
                  geometry.documentPixelSize == mapping.strategy.canvasSize,
                  mapping.outputToWorldTransform.sourceOffset.x.isFinite,
                  mapping.outputToWorldTransform.sourceOffset.y.isFinite,
                  mapping.outputToWorldTransform.sourceStep.x.isFinite,
                  mapping.outputToWorldTransform.sourceStep.y.isFinite
            else { throw SparseTileSamplingPlanError.inconsistentAddressing }
        }
    }

    func captureMutationBase(
        for layerID: UUID
    ) throws -> DocumentPaintSurfaceMutationBaseSnapshot {
        try withLock {
            let epoch = currentEpoch
            guard let state = epoch.layerStates[layerID] else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            let candidateBase = DocumentPaintSurfaceCandidateBase(
                registryIdentity: identity,
                generation: epoch.generation,
                geometry: epoch.geometry,
                layerStack: epoch.layerStack,
                layers: epoch.layerStates,
                persistedTileIdentities: epoch.persistedTileIdentities
            )
            return DocumentPaintSurfaceMutationBaseSnapshot(
                generation: candidateBase.generation,
                geometry: candidateBase.geometry,
                binding: try makeBinding(
                    for: layerID,
                    state: state,
                    geometry: candidateBase.geometry,
                    generation: candidateBase.generation
                ),
                candidateBase: candidateBase
            )
        }
    }

    public func makeCandidate(
        geometry: DocumentPaintGeometry? = nil,
        layerStack: LayerStack? = nil,
        dirtyCoordinatesByLayer: [UUID: [PaintTileCoordinate]] = [:],
        removingCoordinatesByLayer: [UUID: [PaintTileCoordinate]] = [:],
        importedPersistedTileBindings:
            [PersistedPaintTileImportBinding] = [],
        failureInjection: PaintTileAllocationFailureInjection? = nil
    ) throws -> DocumentPaintSurfaceCandidate {
        let base = withLock {
            let epoch = currentEpoch
            return DocumentPaintSurfaceCandidateBase(
                registryIdentity: identity,
                generation: epoch.generation,
                geometry: epoch.geometry,
                layerStack: epoch.layerStack,
                layers: epoch.layerStates,
                persistedTileIdentities: epoch.persistedTileIdentities
            )
        }
        return try makeCandidate(
            from: base,
            geometry: geometry,
            layerStack: layerStack,
            dirtyCoordinatesByLayer: dirtyCoordinatesByLayer,
            removingCoordinatesByLayer: removingCoordinatesByLayer,
            importedPersistedTileBindings: importedPersistedTileBindings,
            failureInjection: failureInjection
        )
    }

    func makeCandidate(
        from snapshot: DocumentPaintSurfaceMutationBaseSnapshot,
        geometry: DocumentPaintGeometry? = nil,
        layerStack: LayerStack? = nil,
        dirtyCoordinatesByLayer: [UUID: [PaintTileCoordinate]] = [:],
        removingCoordinatesByLayer: [UUID: [PaintTileCoordinate]] = [:],
        importedPersistedTileBindings:
            [PersistedPaintTileImportBinding] = [],
        failureInjection: PaintTileAllocationFailureInjection? = nil
    ) throws -> DocumentPaintSurfaceCandidate {
        guard snapshot.candidateBase.registryIdentity == identity else {
            throw DocumentPaintSurfaceStoreError.foreignCandidate
        }
        return try makeCandidate(
            from: snapshot.candidateBase,
            geometry: geometry,
            layerStack: layerStack,
            dirtyCoordinatesByLayer: dirtyCoordinatesByLayer,
            removingCoordinatesByLayer: removingCoordinatesByLayer,
            importedPersistedTileBindings: importedPersistedTileBindings,
            failureInjection: failureInjection
        )
    }

    private func makeCandidate(
        from base: DocumentPaintSurfaceCandidateBase,
        geometry: DocumentPaintGeometry?,
        layerStack: LayerStack?,
        dirtyCoordinatesByLayer: [UUID: [PaintTileCoordinate]],
        removingCoordinatesByLayer: [UUID: [PaintTileCoordinate]],
        importedPersistedTileBindings:
            [PersistedPaintTileImportBinding],
        importedRasterRevisionsByLayer:
            [UUID: RasterRevision]? = nil,
        failureInjection: PaintTileAllocationFailureInjection?
    ) throws -> DocumentPaintSurfaceCandidate {
        let candidateLayerStack = layerStack ?? base.layerStack
        let candidateLayerIDs = Set(candidateLayerStack.orderedLayerIDs)
        if let importedRasterRevisionsByLayer,
           Set(importedRasterRevisionsByLayer.keys) != candidateLayerIDs {
            throw DocumentPaintSurfaceStoreError.layerStackMismatch(
                expected: candidateLayerStack.orderedLayerIDs,
                actual: Array(importedRasterRevisionsByLayer.keys)
            )
        }
        for layerID in dirtyCoordinatesByLayer.keys
        where !candidateLayerIDs.contains(layerID) {
            throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
        }
        for layerID in removingCoordinatesByLayer.keys
        where !candidateLayerIDs.contains(layerID) {
            throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
        }
        guard base.generation < UInt64.max else {
            throw DocumentPaintSurfaceStoreError.generationOverflow
        }
        let candidateGeneration = base.generation + 1
        let candidateGeometry = geometry ?? base.geometry
        let geometryChanged = candidateGeometry != base.geometry
        var candidateLayers = base.layers.filter {
            candidateLayerIDs.contains($0.key)
        }
        for layerID in candidateLayerStack.orderedLayerIDs
        where candidateLayers[layerID] == nil {
            candidateLayers[layerID] = DocumentPaintLayerState(
                logicalSurfaceID: try nextLogicalSurfaceID(),
                revision: RasterRevision(rawValue: 0),
                references: []
            )
        }
        var owned: [PaintTileReference] = []
        var ownedNamespaces: [DocumentPaintSurfaceNamespace] = []

        do {
            for layerID in candidateLayerStack.orderedLayerIDs {
                let dirty = try Self.sortedUnique(
                    dirtyCoordinatesByLayer[layerID] ?? []
                )
                let removed = try Self.sortedUnique(
                    removingCoordinatesByLayer[layerID] ?? []
                )
                let removedSet = Set(removed)
                if let overlap = dirty.first(where: removedSet.contains) {
                    throw DocumentPaintSurfaceStoreError
                        .overlappingDirtyAndRemovedCoordinate(overlap)
                }
                guard let old = candidateLayers[layerID] else {
                    throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
                }
                var mapping: [PaintTileCoordinate: PaintTileReference]
                if geometryChanged {
                    mapping = [:]
                } else {
                    mapping = Dictionary(
                        uniqueKeysWithValues: old.references.map {
                            ($0.coordinate, $0)
                        }
                    )
                }
                for coordinate in removed { mapping.removeValue(forKey: coordinate) }
                if !dirty.isEmpty {
                    let namespace = try issueSurfaceNamespace(
                        layerID: layerID,
                        generation: candidateGeneration,
                        role: .provisional,
                        expectedActiveGeneration: base.generation,
                        requiresCurrentLayer: base.layers[layerID] != nil
                    )
                    ownedNamespaces.append(namespace)
                    let physicalSurfaceID = namespace.surfaceID
                    let lease = try sharedTileStore.reserveSortedUnique(
                        surfaceID: physicalSurfaceID,
                        layerID: layerID,
                        generation: candidateGeneration,
                        pixelSize: candidateGeometry.storagePixelSize,
                        coordinates: dirty,
                        pinReasons: [.dirty],
                        failureInjection: failureInjection
                    )
                    try sharedTileStore.markModified(
                        lease,
                        surfaceID: physicalSurfaceID,
                        currentGeneration: candidateGeneration
                    )
                    try sharedTileStore.release(
                        lease,
                        surfaceID: physicalSurfaceID,
                        currentGeneration: candidateGeneration
                    )
                    let newReferences = try sharedTileStore.references(
                        surfaceID: physicalSurfaceID,
                        layerID: layerID,
                        generation: candidateGeneration
                    )
                    owned.append(contentsOf: newReferences)
                    for reference in newReferences {
                        mapping[reference.coordinate] = reference
                    }
                }
                let (revisionValue, overflow) = old.revision.rawValue
                    .addingReportingOverflow(
                        geometryChanged || !dirty.isEmpty || !removed.isEmpty
                            ? 1 : 0
                    )
                guard !overflow else {
                    throw TiledRasterSurfaceError.revisionOverflow
                }
                candidateLayers[layerID] = DocumentPaintLayerState(
                    logicalSurfaceID: old.logicalSurfaceID,
                    revision: importedRasterRevisionsByLayer?[layerID]
                        ?? RasterRevision(rawValue: revisionValue),
                    references: mapping.values.sorted {
                        $0.coordinate < $1.coordinate
                    }
                )
            }
        } catch let constructionError {
            do {
                try retireCandidateOwnedReferences(owned.sorted())
            } catch let cleanupError {
                throw cleanupError
            }
            throw constructionError
        }
        let persistedTileIdentities: PersistedPaintTileIdentitySnapshot
        do {
            persistedTileIdentities = try PersistedPaintTileIdentityMap
                .transition(
                    from: base.persistedTileIdentities,
                    baseReferences: base.layers.values
                        .flatMap(\.references),
                    candidateReferences: candidateLayers.values
                        .flatMap(\.references),
                    candidateOwnedReferences: owned,
                    imports: importedPersistedTileBindings
                )
        } catch let identityError {
            do {
                try retireCandidateOwnedReferences(owned.sorted())
            } catch let cleanupError {
                throw cleanupError
            }
            throw identityError
        }
        return DocumentPaintSurfaceCandidate(
            registryIdentity: identity,
            store: sharedTileStore,
            geometry: candidateGeometry,
            baseLayerStack: base.layerStack,
            layerStack: candidateLayerStack,
            basePersistedTileIdentities: base.persistedTileIdentities,
            persistedTileIdentitySnapshot: persistedTileIdentities,
            baseGeneration: base.generation,
            generation: candidateGeneration,
            layerStates: candidateLayers,
            ownedReferences: owned.sorted(),
            ownedNamespaces: ownedNamespaces
        )
    }

    private func makeBinding(
        for layerID: UUID,
        state: DocumentPaintLayerState,
        geometry: DocumentPaintGeometry,
        generation: UInt64
    ) throws -> DocumentPaintLayerBinding {
        let view = try TiledRasterCoordinateReferenceView(
            storeIdentity: sharedTileStore.identity,
            surfaceID: state.logicalSurfaceID,
            layerID: layerID,
            pixelSize: geometry.storagePixelSize,
            generation: generation,
            revision: state.revision,
            references: state.references
        )
        return DocumentPaintLayerBinding(
            layerID: layerID,
            generation: generation,
            canonical: try TiledRasterSurface(
                store: sharedTileStore,
                referenceView: view
            )
        )
    }

    func prepareLayerSurfaceHistoryRevision(
        for candidate: DocumentPaintSurfaceCandidate
    ) throws -> LayerSurfaceHistoryRevision {
        try withLock {
            guard candidate.registryIdentity == identity,
                  candidate.store === sharedTileStore
            else { throw DocumentPaintSurfaceStoreError.foreignCandidate }
            let candidateSnapshot = try candidate.withLock { () throws -> (
                layers: [UUID: DocumentPaintLayerState],
                persistedTileIdentities: PersistedPaintTileIdentitySnapshot
            ) in
                guard candidate.state == .open else {
                    throw DocumentPaintSurfaceStoreError
                        .candidateAlreadyConsumed
                }
                return (
                    candidate.layerStatesStorage,
                    candidate.persistedTileIdentitySnapshotStorage
                )
            }
            let epoch = currentEpoch
            guard candidate.baseGeneration == epoch.generation else {
                throw DocumentPaintSurfaceStoreError.staleCandidate(
                    expectedGeneration: epoch.generation,
                    actualGeneration: candidate.baseGeneration
                )
            }
            let beforeReferences = Set(
                epoch.layerStates.values.flatMap(\.references)
            )
            let afterReferences = Set(
                candidateSnapshot.layers.values.flatMap(\.references)
            )
            let sorted = beforeReferences
                .symmetricDifference(afterReferences)
                .sorted()
            var union: [PaintTileReference] = []
            union.reserveCapacity(sorted.count)
            for reference in sorted where union.last != reference {
                union.append(reference)
            }
            let token = union.isEmpty
                ? nil
                : try sharedTileStore.retainSnapshotReferences(union)
            let (retainedBytes, overflow) = union.count
                .multipliedReportingOverflow(
                    by: PaintTileDescriptor.residentByteCount
                )
            guard !overflow else {
                token?.close()
                throw DocumentPaintSurfaceStoreError
                    .layerHistoryByteCountOverflow
            }
            return LayerSurfaceHistoryRevision(
                registryIdentity: identity,
                storeIdentity: sharedTileStore.identity,
                before: .init(
                    geometry: epoch.geometry,
                    layerStack: epoch.layerStack,
                    layerStates: epoch.layerStates,
                    persistedTileIdentities: epoch.persistedTileIdentities
                ),
                after: .init(
                    geometry: candidate.geometry,
                    layerStack: candidate.layerStack,
                    layerStates: candidateSnapshot.layers,
                    persistedTileIdentities:
                        candidateSnapshot.persistedTileIdentities
                ),
                token: token,
                retainedBytes: retainedBytes
            )
        }
    }

    func prepareLayerSurfaceRestoreCommit(
        _ borrow: LayerSurfaceHistoryRevision.Borrow,
        endpoint: LayerSurfaceRevisionEndpoint
    ) throws -> DocumentPaintPreparedCommit {
        let revision = borrow.revision
        guard revision.registryIdentity == identity,
              revision.storeIdentity == sharedTileStore.identity
        else {
            throw DocumentPaintSurfaceStoreError.foreignLayerHistoryRevision
        }
        let source: LayerSurfaceHistoryRevision.Endpoint
        let target: LayerSurfaceHistoryRevision.Endpoint
        switch endpoint {
        case .before:
            source = revision.after
            target = revision.before
        case .after:
            source = revision.before
            target = revision.after
        }
        let preparedBase = try withLock { () throws -> (
            candidate: DocumentPaintSurfaceCandidate,
            reactivation: PaintTilePreparedReactivation?
        ) in
            let epoch = currentEpoch
            guard epoch.geometry == source.geometry,
                  epoch.layerStack == source.layerStack,
                  epoch.layerStates == source.layerStates,
                  epoch.persistedTileIdentities
                    == source.persistedTileIdentities
            else {
                throw DocumentPaintSurfaceStoreError
                    .layerHistoryEndpointMismatch
            }
            guard epoch.generation < UInt64.max else {
                throw DocumentPaintSurfaceStoreError.generationOverflow
            }
            try PersistedPaintTileIdentityMap.validateExact(
                target.persistedTileIdentities,
                references: target.layerStates.values.flatMap(\.references)
            )
            let currentReferences = Set(
                epoch.layerStates.values.flatMap(\.references)
            )
            let reactivated = target.layerStates.values
                .flatMap(\.references)
                .filter { !currentReferences.contains($0) }
                .sorted()
            let reactivation: PaintTilePreparedReactivation?
            if reactivated.isEmpty {
                reactivation = nil
            } else {
                guard let token = revision.token else {
                    throw DocumentPaintSurfaceStoreError
                        .closedLayerHistoryRevision
                }
                reactivation = try sharedTileStore.prepareReactivation(
                    reactivated,
                    retainedBy: token
                )
            }
            return (
                DocumentPaintSurfaceCandidate(
                    registryIdentity: identity,
                    store: sharedTileStore,
                    geometry: target.geometry,
                    baseLayerStack: epoch.layerStack,
                    layerStack: target.layerStack,
                    basePersistedTileIdentities:
                        epoch.persistedTileIdentities,
                    persistedTileIdentitySnapshot:
                        target.persistedTileIdentities,
                    baseGeneration: epoch.generation,
                    generation: epoch.generation + 1,
                    layerStates: target.layerStates,
                    ownedReferences: [],
                    ownedNamespaces: []
                ),
                reactivation
            )
        }
        do {
            return try prepareCommit(
                preparedBase.candidate,
                reactivation: preparedBase.reactivation
            )
        } catch {
            try? discard(preparedBase.candidate)
            throw error
        }
    }

    public func prepareCommit(
        _ candidate: DocumentPaintSurfaceCandidate
    ) throws -> DocumentPaintPreparedCommit {
        try prepareCommit(candidate, reactivation: nil)
    }

    private func prepareCommit(
        _ candidate: DocumentPaintSurfaceCandidate,
        reactivation: PaintTilePreparedReactivation?
    ) throws -> DocumentPaintPreparedCommit {
        try withLock {
            guard candidate.registryIdentity == identity,
                  candidate.store === sharedTileStore
            else { throw DocumentPaintSurfaceStoreError.foreignCandidate }
            let candidateSnapshot = try candidate.withLock { () throws -> (
                layers: [UUID: DocumentPaintLayerState],
                ownedReferences: [PaintTileReference],
                persistedTileIdentities: PersistedPaintTileIdentitySnapshot
            ) in
                guard candidate.state == .open else {
                    throw DocumentPaintSurfaceStoreError.candidateAlreadyConsumed
                }
                return (
                    candidate.layerStatesStorage,
                    candidate.ownedReferencesStorage,
                    candidate.persistedTileIdentitySnapshotStorage
                )
            }
            let current = currentEpoch
            guard candidate.baseGeneration == current.generation else {
                throw DocumentPaintSurfaceStoreError.staleCandidate(
                    expectedGeneration: current.generation,
                    actualGeneration: candidate.baseGeneration
                )
            }
            guard candidate.basePersistedTileIdentities
                    == current.persistedTileIdentities
            else {
                throw DocumentPaintSurfaceStoreError.staleCandidate(
                    expectedGeneration: current.generation,
                    actualGeneration: candidate.baseGeneration
                )
            }
            try PersistedPaintTileIdentityMap.validateExact(
                candidateSnapshot.persistedTileIdentities,
                references: candidateSnapshot.layers.values
                    .flatMap(\.references)
            )
            guard preparedCandidateIdentity == nil else {
                throw DocumentPaintSurfaceStoreError.ambiguousPreparedCandidate
            }
            let retained = Set(candidateSnapshot.layers.values.flatMap(\.references))
            let replaced = current.layerStates.values
                .flatMap(\.references)
                .filter { !retained.contains($0) }
                .sorted()
            let replacedRetirement = try sharedTileStore.prepareRetirement(
                replaced
            )
            let candidateRetirement: PaintTilePreparedRetirement
            do {
                candidateRetirement = try sharedTileStore.prepareRetirement(
                    candidateSnapshot.ownedReferences
                )
            } catch {
                sharedTileStore.cancelRetirement(replacedRetirement)
                throw error
            }
            let nextEpoch = DocumentPaintSurfaceEpoch(
                generation: candidate.generation,
                geometry: candidate.geometry,
                layerStack: candidate.layerStack,
                layerStates: candidateSnapshot.layers,
                persistedTileIdentities:
                    candidateSnapshot.persistedTileIdentities
            )
            let prepared = DocumentPaintPreparedCommit(
                candidate: candidate,
                nextEpoch: nextEpoch,
                replacedRetirement: replacedRetirement,
                candidateRetirement: candidateRetirement,
                reactivation: reactivation
            )
            candidate.withLock {
                precondition(candidate.state == .open)
                candidate.state = .prepared
                candidate.preparedCommit = prepared
            }
            preparedCandidateIdentity = ObjectIdentifier(candidate)
            return prepared
        }
    }

    /// All validation and retirement preparation happened in prepareCommit;
    /// this is the one nonthrowing logical registry swap.
    public func commitPrepared(_ prepared: DocumentPaintPreparedCommit) {
        withLock {
            let candidate = prepared.candidate
            let isPrepared = candidate.withLock {
                candidate.state == .prepared
                    && candidate.preparedCommit === prepared
            }
            guard isPrepared,
                  preparedCandidateIdentity == ObjectIdentifier(candidate)
            else { return }
            commitPreparedLocked(prepared)
        }
    }

    /// Coordinator-only irreversible terminal. Every fallible preflight must
    /// finish before this call; unlike the compatibility terminal, misuse is a
    /// programmer error and cannot silently leave a published revision pair
    /// without its matching registry generation.
    func commitPreparedForCoordinator(_ prepared: DocumentPaintPreparedCommit) {
        withLock {
            let candidate = prepared.candidate
            precondition(candidate.registryIdentity == identity)
            precondition(candidate.store === sharedTileStore)
            precondition(
                preparedCandidateIdentity == ObjectIdentifier(candidate)
            )
            candidate.withLock {
                precondition(candidate.state == .prepared)
                precondition(candidate.preparedCommit === prepared)
            }
            commitPreparedLocked(prepared)
        }
    }

    /// Explicitly consumes a prepared candidate without publishing it. The
    /// old active references are unblocked and only candidate-owned entries
    /// are retired. Repeated commit/cancel calls are harmless no-ops.
    public func cancelPrepared(_ prepared: DocumentPaintPreparedCommit) {
        withLock {
            let candidate = prepared.candidate
            let isPrepared = candidate.withLock {
                candidate.state == .prepared
                    && candidate.preparedCommit === prepared
            }
            guard isPrepared,
                  preparedCandidateIdentity == ObjectIdentifier(candidate)
            else { return }
            candidate.withLock {
                candidate.state = .consumed
                candidate.preparedCommit = nil
            }
            preparedCandidateIdentity = nil
            sharedTileStore.cancelRetirement(prepared.replacedRetirement)
            sharedTileStore.requestRetirement(prepared.candidateRetirement)
        }
    }

    public func discard(_ candidate: DocumentPaintSurfaceCandidate) throws {
        try withLock {
            guard candidate.registryIdentity == identity,
                  candidate.store === sharedTileStore
            else { throw DocumentPaintSurfaceStoreError.foreignCandidate }
            let candidateSnapshot = candidate.withLock {
                (candidate.state, candidate.ownedReferencesStorage)
            }
            let candidateState = candidateSnapshot.0
            guard candidateState != .consumed else {
                throw DocumentPaintSurfaceStoreError.candidateAlreadyConsumed
            }
            guard candidateState == .open else {
                throw DocumentPaintSurfaceStoreError
                    .preparedCandidateRequiresExplicitCancellation
            }
            let retirement = try sharedTileStore.prepareRetirement(
                candidateSnapshot.1
            )
            candidate.withLock { candidate.state = .consumed }
            sharedTileStore.requestRetirement(retirement)
        }
    }

    /// Removes exact, fully transparent candidate-owned dirty tiles before the
    /// candidate can be prepared for publication. Coordinates are authority:
    /// callers must provide a sorted, duplicate-free set and may never prune a
    /// shared reference inherited from the active generation.
    public func pruneFullyTransparentCoordinates(
        _ coordinates: [PaintTileCoordinate],
        from candidate: DocumentPaintSurfaceCandidate,
        layerID: UUID
    ) throws {
        try withLock {
            guard candidate.registryIdentity == identity,
                  candidate.store === sharedTileStore
            else { throw DocumentPaintSurfaceStoreError.foreignCandidate }
            let current = currentEpoch
            guard current.layerStates[layerID] != nil else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            guard candidate.baseGeneration == current.generation else {
                throw DocumentPaintSurfaceStoreError.staleCandidate(
                    expectedGeneration: current.generation,
                    actualGeneration: candidate.baseGeneration
                )
            }
            try Self.validateSortedUnique(coordinates)
            let references = try candidate.withLock { () throws
                -> [PaintTileReference] in
                guard candidate.state == .open else {
                    throw DocumentPaintSurfaceStoreError.candidateAlreadyConsumed
                }
                guard let layer = candidate.layerStatesStorage[layerID] else {
                    throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
                }
                return try coordinates.map { coordinate in
                    guard let reference = candidate.ownedReferencesStorage
                        .first(where: {
                            $0.layerID == layerID
                                && $0.coordinate == coordinate
                        }),
                          layer.references.first(where: {
                              $0.coordinate == coordinate
                          }) == reference
                    else {
                        throw DocumentPaintSurfaceStoreError
                            .unownedCandidateCoordinate(coordinate)
                    }
                    return reference
                }
            }
            guard !references.isEmpty else { return }

            let retirement = try sharedTileStore.prepareRetirement(references)
            do {
                try candidate.withLock {
                    precondition(candidate.state == .open)
                    let removed = Set(references)
                    let nextPersistedTileIdentities = try
                        PersistedPaintTileIdentityMap.removing(
                            Set(references.map(\.identity)),
                            from: candidate
                                .persistedTileIdentitySnapshotStorage
                        )
                    let layer = candidate.layerStatesStorage[layerID]!
                    candidate.layerStatesStorage[layerID] =
                        DocumentPaintLayerState(
                            logicalSurfaceID: layer.logicalSurfaceID,
                            revision: layer.revision,
                            references: layer.references.filter {
                                !removed.contains($0)
                            }
                        )
                    candidate.ownedReferencesStorage.removeAll {
                        removed.contains($0)
                    }
                    candidate.persistedTileIdentitySnapshotStorage =
                        nextPersistedTileIdentities
                }
            } catch {
                sharedTileStore.cancelRetirement(retirement)
                throw error
            }
            sharedTileStore.requestRetirement(retirement)
        }
    }

    public func snapshot() -> DocumentPaintSurfaceStoreSnapshot {
        withLock {
            sweepAbandonedNamespacesLocked()
            let epoch = currentEpoch
            #if DEBUG
            testingEpochHook?(.snapshotCaptured)
            #endif
            let tileSnapshot = sharedTileStore.snapshot()
            return DocumentPaintSurfaceStoreSnapshot(
                generation: epoch.generation,
                geometry: epoch.geometry,
                layerStack: epoch.layerStack,
                layers: epoch.orderedLayerIDs.compactMap { layerID in
                    epoch.layerStates[layerID].map {
                        .init(layerID: layerID, references: $0.references)
                    }
                },
                tileByteBudget: sharedTileStore.byteBudget,
                residentTileBytes: tileSnapshot.residentByteCount,
                backingTileBytes: tileSnapshot.backingByteCount,
                activeTileLeaseCount: tileSnapshot.activeLeaseCount,
                issuedNamespaceCount: namespaceRecords.count,
                preparedCandidateCount: preparedCandidateIdentity == nil ? 0 : 1
            )
        }
    }

    /// Issues authority for the current epoch only. The generation is selected
    /// by the registry under the same lock that validates layer membership.
    func issueCurrentStrokeNamespace(
        layerID: UUID
    ) throws -> StrokeTileSurfaceNamespaceLease {
        try withLock {
            let epoch = currentEpoch
            guard epoch.layerStates[layerID] != nil else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            return try issueStrokeNamespaceLocked(
                layerID: layerID,
                generation: epoch.generation
            )
        }
    }

    /// Captures namespace generation and geometry from one current epoch under
    /// one registry lock; capability construction intentionally happens after
    /// releasing that lock.
    func issueCurrentStrokeSurfaceCapability(
        layerID: UUID,
        ownerIdentity: UUID,
        onTerminal: @escaping @Sendable (UUID) -> Void
    ) throws -> DocumentPaintStrokeSurfaceCapability {
        let authority = try withLock {
            try captureStrokeSurfaceAuthorityLocked(
                layerID: layerID
            )
        }
        return try makeStrokeSurfaceCapability(
            lease: authority.lease,
            geometry: authority.geometry,
            ownerIdentity: ownerIdentity,
            onTerminal: onTerminal
        )
    }

    private func makeStrokeSurfaceCapability(
        lease: StrokeTileSurfaceNamespaceLease,
        geometry: DocumentPaintGeometry,
        ownerIdentity: UUID,
        onTerminal: @escaping @Sendable (UUID) -> Void
    ) throws -> DocumentPaintStrokeSurfaceCapability {
        do {
            return try DocumentPaintStrokeSurfaceCapability(
                ownerIdentity: ownerIdentity,
                capabilityToken: UUID(),
                namespaceLease: lease,
                store: sharedTileStore,
                geometry: geometry,
                onTerminal: onTerminal
            )
        } catch {
            lease.cancel()
            throw error
        }
    }

    private func captureStrokeSurfaceAuthorityLocked(
        layerID: UUID
    ) throws -> (
        geometry: DocumentPaintGeometry,
        lease: StrokeTileSurfaceNamespaceLease
    ) {
        let epoch = currentEpoch
        #if DEBUG
        testingEpochHook?(.strokeAuthorityCaptured)
        #endif
        guard epoch.layerStates[layerID] != nil else {
            throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
        }
        return (
            epoch.geometry,
            try issueStrokeNamespaceLocked(
                layerID: layerID,
                generation: epoch.generation
            )
        )
    }

    /// Requires `lock` to be held and a current-epoch layer to be validated.
    private func issueStrokeNamespaceLocked(
        layerID: UUID,
        generation: UInt64
    ) throws -> StrokeTileSurfaceNamespaceLease {
        let (token, overflow) = nextNamespaceToken.addingReportingOverflow(1)
        guard !overflow else {
            throw DocumentPaintSurfaceStoreError.namespaceIdentityOverflow
        }
        let authoritative = DocumentPaintSurfaceNamespace(
            storeIdentity: sharedTileStore.identity,
            surfaceID: Self.surfaceID(role: .authoritative, token: token),
            layerID: layerID,
            generation: generation,
            role: .authoritative,
            token: token
        )
        let prediction = DocumentPaintSurfaceNamespace(
            storeIdentity: sharedTileStore.identity,
            surfaceID: Self.surfaceID(role: .prediction, token: token),
            layerID: layerID,
            generation: generation,
            role: .prediction,
            token: token
        )
        let lease = StrokeTileSurfaceNamespaceLease.registryIssued(
            authoritative: authoritative,
            prediction: prediction,
            retirementToken: token,
            authenticate: { [weak self] lease in
                self?.authenticate(lease) == true
            },
            onRetired: { [weak self] value in
                self?.retireNamespace(token: value)
            }
        )
        namespaceRecords[token] = NamespaceRecord(
            layerID: layerID,
            generation: generation,
            authoritativeSurfaceID: authoritative.surfaceID,
            predictionSurfaceID: prediction.surfaceID,
            ownership: lease.ownership
        )
        nextNamespaceToken = token
        return lease
    }

    private func authenticate(_ lease: StrokeTileSurfaceNamespaceLease) -> Bool {
        withLock {
            guard lease.storeIdentity == sharedTileStore.identity,
                  let record = namespaceRecords[lease.retirementToken]
            else { return false }
            return record.matches(lease)
        }
    }

    /// Defensive registry sweep for namespace owners abandoned before a
    /// resource object could claim them. Normal cancellation/deinit removes
    /// records immediately; this makes the evidence count self-healing too.
    func sweepAbandonedNamespaces() {
        withLock { sweepAbandonedNamespacesLocked() }
    }

    private func sweepAbandonedNamespacesLocked() {
        namespaceRecords = namespaceRecords.filter {
            $0.value.ownership?.isOutstanding == true
        }
    }

    private func nextLogicalSurfaceID() throws -> UUID {
        try withLock {
            let (token, overflow) = nextNamespaceToken
                .addingReportingOverflow(1)
            guard !overflow else {
                throw DocumentPaintSurfaceStoreError.namespaceIdentityOverflow
            }
            nextNamespaceToken = token
            return Self.surfaceID(role: .canonical, token: token)
        }
    }

    private func issueSurfaceNamespace(
        layerID: UUID,
        generation: UInt64,
        role: DocumentPaintSurfaceRole,
        expectedActiveGeneration: UInt64,
        requiresCurrentLayer: Bool = true
    ) throws -> DocumentPaintSurfaceNamespace {
        try withLock {
            let epoch = currentEpoch
            guard !requiresCurrentLayer || epoch.layerStates[layerID] != nil else {
                throw DocumentPaintSurfaceStoreError.unknownLayerID(layerID)
            }
            guard epoch.generation == expectedActiveGeneration else {
                throw DocumentPaintSurfaceStoreError.staleGeneration(
                    expected: epoch.generation,
                    actual: expectedActiveGeneration
                )
            }
            let (token, overflow) = nextNamespaceToken
                .addingReportingOverflow(1)
            guard !overflow else {
                throw DocumentPaintSurfaceStoreError.namespaceIdentityOverflow
            }
            nextNamespaceToken = token
            return DocumentPaintSurfaceNamespace(
                storeIdentity: sharedTileStore.identity,
                surfaceID: Self.surfaceID(role: role, token: token),
                layerID: layerID,
                generation: generation,
                role: role,
                token: token
            )
        }
    }

    private static func surfaceID(
        role: DocumentPaintSurfaceRole,
        token: UInt64
    ) -> UUID {
        let bytes = token.bigEndian
        return withUnsafeBytes(of: bytes) { raw in
            UUID(uuid: (
                0x4C, 0x41, 0x59, 0x41,
                role.rawValue, 0xD6, 0, 0,
                raw[0], raw[1], raw[2], raw[3],
                raw[4], raw[5], raw[6], raw[7]
            ))
        }
    }

    private func retireNamespace(token: UInt64) {
        _ = withLock { namespaceRecords.removeValue(forKey: token) }
    }

    private func retireCandidateOwnedReferences(
        _ references: [PaintTileReference]
    ) throws {
        let plan = try sharedTileStore.prepareRetirement(references)
        sharedTileStore.requestRetirement(plan)
    }

    private func commitPreparedLocked(
        _ prepared: DocumentPaintPreparedCommit
    ) {
        let candidate = prepared.candidate
        if let reactivation = prepared.reactivation {
            sharedTileStore.commitReactivation(reactivation)
        }
        // This is the sole logical publication point. Everything describing
        // the registry changes with one immutable epoch-reference assignment.
        #if DEBUG
        testingEpochHook?(.beforePublication)
        #endif
        currentEpoch = prepared.nextEpoch
        candidate.withLock {
            candidate.state = .consumed
            candidate.preparedCommit = nil
        }
        preparedCandidateIdentity = nil
        sharedTileStore.requestRetirement(prepared.replacedRetirement)
        sharedTileStore.cancelRetirement(prepared.candidateRetirement)
    }

    private static func sortedUnique(
        _ coordinates: [PaintTileCoordinate]
    ) throws -> [PaintTileCoordinate] {
        let sorted = coordinates.sorted()
        for index in sorted.indices.dropFirst()
        where sorted[index] == sorted[index - 1] {
            throw DocumentPaintSurfaceStoreError
                .duplicateCoordinate(sorted[index])
        }
        return sorted
    }

    private static func validateSortedUnique(
        _ coordinates: [PaintTileCoordinate]
    ) throws {
        for index in coordinates.indices.dropFirst() {
            let previous = coordinates[index - 1]
            let current = coordinates[index]
            if previous == current {
                throw DocumentPaintSurfaceStoreError.duplicateCoordinate(current)
            }
            guard previous < current else {
                throw DocumentPaintSurfaceStoreError.unsortedCoordinate(
                    previous: previous,
                    current: current
                )
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
