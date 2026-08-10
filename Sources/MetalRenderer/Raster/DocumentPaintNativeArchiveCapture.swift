import EditorCore
import Foundation
import PatternEngine

public enum DocumentPaintNativeArchiveCaptureError:
    Error,
    Equatable,
    Sendable
{
    case unknownPersistedTileID(UUID)
}

public enum DocumentPaintNativeArchiveImportError:
    Error,
    Equatable,
    Sendable
{
    case layerStackMismatch(expected: [UUID], actual: [UUID])
    case duplicatePersistedTileID(UUID)
    case unexpectedPersistedTileID(UUID)
    case duplicatePayload(UUID)
    case missingPayload(UUID)
    case invalidPayloadByteCount(expected: Int, actual: Int)
    case writerAlreadyTerminal
}

public struct DocumentPaintNativeArchiveTile: Equatable, Sendable {
    public let persistedID: UUID
    public let coordinate: PaintTileCoordinate
    public let logicalBounds: PixelRect

    public init(
        persistedID: UUID,
        coordinate: PaintTileCoordinate,
        logicalBounds: PixelRect
    ) {
        self.persistedID = persistedID
        self.coordinate = coordinate
        self.logicalBounds = logicalBounds
    }
}

public struct DocumentPaintNativeArchiveLayer: Equatable, Sendable {
    public let layerID: UUID
    public let rasterRevision: UInt64
    public let tiles: [DocumentPaintNativeArchiveTile]

    public init(
        layerID: UUID,
        rasterRevision: UInt64,
        tiles: [DocumentPaintNativeArchiveTile]
    ) {
        self.layerID = layerID
        self.rasterRevision = rasterRevision
        self.tiles = tiles
    }
}

public struct DocumentPaintNativeArchiveImportManifest: Sendable {
    public let geometry: DocumentPaintGeometry
    public let layerStack: LayerStack
    public let layers: [DocumentPaintNativeArchiveLayer]

    public init(
        geometry: DocumentPaintGeometry,
        layerStack: LayerStack,
        layers: [DocumentPaintNativeArchiveLayer]
    ) throws {
        let expected = layerStack.orderedLayerIDs
        let actual = layers.map(\.layerID)
        guard actual == expected else {
            throw DocumentPaintNativeArchiveImportError.layerStackMismatch(
                expected: expected,
                actual: actual
            )
        }
        var persistedIDs = Set<UUID>()
        for layer in layers {
            for tile in layer.tiles {
                guard persistedIDs.insert(tile.persistedID).inserted else {
                    throw DocumentPaintNativeArchiveImportError
                        .duplicatePersistedTileID(tile.persistedID)
                }
            }
        }
        self.geometry = geometry
        self.layerStack = layerStack
        self.layers = layers
    }
}

/// One immutable native persistence root. Metadata and every raw payload are
/// bound to a single published document epoch and one exact retention owner.
public final class DocumentPaintNativeArchiveCapture:
    @unchecked Sendable
{
    struct PayloadAuthority {
        let provider: TiledRasterExactReferenceProvider
        let reference: PaintTileReference
    }

    public let documentGeneration: UInt64
    public let geometry: DocumentPaintGeometry
    public let layerStack: LayerStack
    public let layers: [DocumentPaintNativeArchiveLayer]

    private let root: TiledRasterExactReferenceCapture
    private let payloadAuthorityByPersistedID: [UUID: PayloadAuthority]

    init(
        documentGeneration: UInt64,
        geometry: DocumentPaintGeometry,
        layerStack: LayerStack,
        layers: [DocumentPaintNativeArchiveLayer],
        root: TiledRasterExactReferenceCapture,
        payloadAuthorityByPersistedID: [UUID: PayloadAuthority]
    ) {
        self.documentGeneration = documentGeneration
        self.geometry = geometry
        self.layerStack = layerStack
        self.layers = layers
        self.root = root
        self.payloadAuthorityByPersistedID = payloadAuthorityByPersistedID
    }

    public func payload(for persistedTileID: UUID) throws -> Data {
        guard let authority = payloadAuthorityByPersistedID[persistedTileID]
        else {
            throw DocumentPaintNativeArchiveCaptureError
                .unknownPersistedTileID(persistedTileID)
        }
        switch try root.payload(
            authority.reference,
            from: authority.provider
        ) {
        case .knownClear:
            return Data(count: PaintTileDescriptor.residentByteCount)
        case let .rgba16Float(data):
            return data
        }
    }

    public func close() { root.close() }

    deinit { close() }
}

/// Unpublished native-import candidate. PatternFile has already authenticated
/// archive bytes; this writer owns only runtime identity binding, one-tile
/// upload, and the eventual atomic registry publication.
public final class DocumentPaintNativeArchiveImportWriter:
    @unchecked Sendable
{
    private enum State { case open, finished, cancelled }

    private let lock = NSLock()
    private let store: DocumentPaintSurfaceStore
    private let candidate: DocumentPaintSurfaceCandidate
    private let expectedIDs: Set<UUID>
    private var installedIDs: Set<UUID> = []
    private var state: State = .open

    init(
        store: DocumentPaintSurfaceStore,
        candidate: DocumentPaintSurfaceCandidate,
        expectedIDs: Set<UUID>
    ) {
        self.store = store
        self.candidate = candidate
        self.expectedIDs = expectedIDs
    }

    public func install(
        _ rgba16FloatPayload: Data,
        for persistedTileID: UUID
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .open else {
            throw DocumentPaintNativeArchiveImportError.writerAlreadyTerminal
        }
        guard expectedIDs.contains(persistedTileID) else {
            throw DocumentPaintNativeArchiveImportError
                .unexpectedPersistedTileID(persistedTileID)
        }
        guard !installedIDs.contains(persistedTileID) else {
            throw DocumentPaintNativeArchiveImportError
                .duplicatePayload(persistedTileID)
        }
        guard rgba16FloatPayload.count
                == PaintTileDescriptor.residentByteCount
        else {
            throw DocumentPaintNativeArchiveImportError
                .invalidPayloadByteCount(
                    expected: PaintTileDescriptor.residentByteCount,
                    actual: rgba16FloatPayload.count
                )
        }
        try store.installNativeArchivePayload(
            rgba16FloatPayload,
            for: persistedTileID,
            into: candidate
        )
        installedIDs.insert(persistedTileID)
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .open else {
            throw DocumentPaintNativeArchiveImportError.writerAlreadyTerminal
        }
        if let missing = expectedIDs.first(where: {
            !installedIDs.contains($0)
        }) {
            throw DocumentPaintNativeArchiveImportError
                .missingPayload(missing)
        }
        let prepared = try store.prepareCommit(candidate)
        store.commitPrepared(prepared)
        state = .finished
    }

    func cancel() throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .open else { return }
        try store.discard(candidate)
        state = .cancelled
    }
}
