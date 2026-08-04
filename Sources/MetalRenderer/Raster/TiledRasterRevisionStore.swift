import Foundation
import Metal
import PatternEngine

public enum TiledRasterRevisionFailurePoint: Equatable, Sendable {
    case bufferAllocation(Int)
    case tileCapture(Int)
    case commandEncoding
    case completion
    case publish
    case consumeInstall
}

public struct TiledRasterRevisionFailureInjection: Sendable {
    let failingPoint: TiledRasterRevisionFailurePoint

    public init(failingAt point: TiledRasterRevisionFailurePoint) {
        failingPoint = point
    }

    func shouldFail(at point: TiledRasterRevisionFailurePoint) -> Bool {
        failingPoint == point
    }
}

public enum TiledRasterRevisionStoreError:
    Error, Equatable, Sendable
{
    case emptyCoordinateSet
    case duplicateCoordinate(PaintTileCoordinate)
    case unsortedCoordinate(
        previous: PaintTileCoordinate,
        current: PaintTileCoordinate
    )
    case coordinateOutsidePixelSize(PaintTileCoordinate)
    case coordinateSetMismatch
    case presentCoordinateOutsideDirtySet(PaintTileCoordinate)
    case missingRevision
    case forgedRevision
    case layerMismatch(expected: UUID, actual: UUID)
    case generationMismatch(expected: UInt64, actual: UInt64)
    case invalidTextureFormat
    case invalidTextureSize
    case presentStateMismatch(PaintTileCoordinate)
    case byteCountOverflow
    case byteBudgetExceeded(requiredBytes: Int, availableBytes: Int)
    case bufferAllocationFailed
    case blitEncoderUnavailable
    case invalidOperationToken
    case operationDidNotComplete
    case pairNotReady
    case pairAlreadyPublished
    case releaseAlreadyRequested
    case invalidInstallLease
    case injectedFailure(TiledRasterRevisionFailurePoint)
}

public enum TiledRasterRevisionTileSource: @unchecked Sendable {
    case knownClear(coordinate: PaintTileCoordinate)
    case texture(
        coordinate: PaintTileCoordinate,
        texture: any MTLTexture
    )

    public var coordinate: PaintTileCoordinate {
        switch self {
        case let .knownClear(coordinate), let .texture(coordinate, _):
            coordinate
        }
    }

    var texture: (any MTLTexture)? {
        guard case let .texture(_, texture) = self else { return nil }
        return texture
    }
}

public struct TiledRasterRevisionTileTarget: @unchecked Sendable {
    public let coordinate: PaintTileCoordinate
    public let texture: any MTLTexture

    public init(
        coordinate: PaintTileCoordinate,
        texture: any MTLTexture
    ) {
        self.coordinate = coordinate
        self.texture = texture
    }
}

/// One exact sparse side of a before/after history pair. Tile coordinates are
/// the authority; regions are only a deterministic compatibility and
/// invalidation summary derived from the clipped logical bounds.
public struct TiledRasterRevisionEndpoint: Equatable, Sendable {
    public let generation: UInt64
    public let pixelSize: PixelSize
    public let documentPixelSize: PixelSize
    public let coordinates: [PaintTileCoordinate]
    public let presentCoordinates: [PaintTileCoordinate]
    public let regions: PixelRegionSet

    public init(
        generation: UInt64,
        pixelSize: PixelSize,
        documentPixelSize: PixelSize,
        coordinates: [PaintTileCoordinate],
        presentCoordinates: [PaintTileCoordinate]
    ) throws {
        try Self.validateSortedUnique(coordinates)
        try Self.validateSortedUnique(presentCoordinates)
        let exact = Set(coordinates)
        for coordinate in presentCoordinates where !exact.contains(coordinate) {
            throw TiledRasterRevisionStoreError
                .presentCoordinateOutsideDirtySet(coordinate)
        }
        var bounds: [PixelRect] = []
        bounds.reserveCapacity(coordinates.count)
        for coordinate in coordinates {
            do {
                bounds.append(try PaintTileDescriptor(
                    coordinate: coordinate,
                    logicalPixelSize: pixelSize
                ).logicalBounds)
            } catch PaintTileError.boundsArithmeticOverflow {
                throw TiledRasterRevisionStoreError.byteCountOverflow
            } catch {
                throw TiledRasterRevisionStoreError
                    .coordinateOutsidePixelSize(coordinate)
            }
        }
        self.generation = generation
        self.pixelSize = pixelSize
        self.documentPixelSize = documentPixelSize
        self.coordinates = coordinates
        self.presentCoordinates = presentCoordinates
        regions = PixelRegionSet(bounds, clippedTo: pixelSize)
    }

    private static func validateSortedUnique(
        _ coordinates: [PaintTileCoordinate]
    ) throws {
        for index in coordinates.indices.dropFirst() {
            let previous = coordinates[index - 1]
            let current = coordinates[index]
            if previous == current {
                throw TiledRasterRevisionStoreError.duplicateCoordinate(current)
            }
            guard previous < current else {
                throw TiledRasterRevisionStoreError.unsortedCoordinate(
                    previous: previous,
                    current: current
                )
            }
        }
    }
}

public enum TiledRasterRevisionInstallDisposition:
    Equatable, Sendable
{
    case remove
    case replace
}

public struct TiledRasterRevisionInstallTile: Equatable, Sendable {
    public let descriptor: PaintTileDescriptor
    public let disposition: TiledRasterRevisionInstallDisposition
}

/// Opaque store-owned lease for preparing one canonical tile-set replacement.
/// It deliberately exposes no retained Metal buffers.
public struct TiledRasterRevisionInstallLease: Equatable, Sendable {
    fileprivate let storeIdentity: UInt64
    fileprivate let leaseID: UInt64
    public let reference: RasterRevisionReference
    public let layerID: UUID
    public let generation: UInt64
    public let tiles: [TiledRasterRevisionInstallTile]
    public let surfaceRevisionAdvance: UInt64 = 1

    fileprivate init(
        storeIdentity: UInt64,
        leaseID: UInt64,
        reference: RasterRevisionReference,
        layerID: UUID,
        generation: UInt64,
        tiles: [TiledRasterRevisionInstallTile]
    ) {
        self.storeIdentity = storeIdentity
        self.leaseID = leaseID
        self.reference = reference
        self.layerID = layerID
        self.generation = generation
        self.tiles = tiles
    }
}

public struct TiledRasterRevisionOperationToken:
    Hashable, Sendable
{
    private let storeIdentity: UInt64
    private let sequence: UInt64

    fileprivate init(storeIdentity: UInt64, sequence: UInt64) {
        self.storeIdentity = storeIdentity
        self.sequence = sequence
    }
}

public struct TiledRasterRevisionStoreSnapshot:
    Equatable, Sendable
{
    public let maximumRetainedBytes: Int
    public let residentBytes: Int
    public let provisionalRevisionCount: Int
    public let publishedRevisionCount: Int
    public let inFlightOperationCount: Int
    public let inFlightInstallLeaseCount: Int

    public static func empty(
        maximumRetainedBytes: Int
    ) -> Self {
        Self(
            maximumRetainedBytes: maximumRetainedBytes,
            residentBytes: 0,
            provisionalRevisionCount: 0,
            publishedRevisionCount: 0,
            inFlightOperationCount: 0,
            inFlightInstallLeaseCount: 0
        )
    }
}

enum TiledRasterRevisionHarnessPayload: Equatable {
    case knownClear
    case rgba16Float(Data)
}

struct TiledRasterRevisionHarnessPayloadEntry: Equatable {
    let coordinate: PaintTileCoordinate
    let payload: TiledRasterRevisionHarnessPayload
}

struct TiledRasterRevisionHarnessSnapshot: Equatable {
    let reference: RasterRevisionReference
    let payloads: [TiledRasterRevisionHarnessPayloadEntry]
}

/// Tile-native history storage. The full-surface `RasterRevisionStore` remains
/// as a compatibility helper until the renderer atomically switches routes.
public final class TiledRasterRevisionStore: @unchecked Sendable {
    private enum Lifetime {
        case provisional
        case published
    }

    private enum OperationKind {
        case capture
        case restore
        case install
    }

    private enum InstallState {
        case prepared
        case encoding
        case readyToConsume
    }

    private struct Slice {
        let descriptor: PaintTileDescriptor
        let isPresent: Bool
        let bufferOffset: Int
        let bytesPerRow: Int
        let bytesPerImage: Int
        let compactBytesPerRow: Int
    }

    private struct Layout {
        let slices: [Slice]
        let retainedBytes: Int
    }

    private struct Entry {
        let reference: RasterRevisionReference
        let pairID: StoredRasterRevisionID
        let buffer: (any MTLBuffer)?
        let slices: [Slice]
        var lifetime: Lifetime
        var capturePending: Bool
        var captureSucceeded: Bool
        var inFlightCount: Int
        var releaseRequested: Bool
    }

    private struct PairRecord {
        let before: RasterRevisionReference
        let after: RasterRevisionReference
        var isPublished: Bool
    }

    private struct Operation {
        let revisionID: StoredRasterRevisionID
        let pairID: StoredRasterRevisionID
        let kind: OperationKind
        let installLeaseID: UInt64?
        let commandBuffer: any MTLCommandBuffer
        let transientBuffers: [any MTLBuffer]
    }

    private struct InstallRecord {
        let revisionID: StoredRasterRevisionID
        let pairID: StoredRasterRevisionID
        let layerID: UUID
        let generation: UInt64
        var state: InstallState
        var cancellationRequested: Bool
    }

    private let device: any MTLDevice
    public let maximumRetainedBytes: Int
    private let storeIdentity =
        RasterRevisionStoreIdentitySource.shared.makeIdentity()
    private let lock = NSLock()
    private var entries: [StoredRasterRevisionID: Entry] = [:]
    private var pairs: [StoredRasterRevisionID: PairRecord] = [:]
    private var operations: [TiledRasterRevisionOperationToken: Operation] = [:]
    private var installRecords: [UInt64: InstallRecord] = [:]
    private var nextRevisionID: UInt64 = 1
    private var nextOperationID: UInt64 = 1
    private var nextInstallLeaseID: UInt64 = 1
    private var residentByteCount = 0

    public init(
        device: any MTLDevice,
        maximumRetainedBytes: Int
    ) {
        precondition(maximumRetainedBytes > 0)
        self.device = device
        self.maximumRetainedBytes = maximumRetainedBytes
    }

    public var residentBytes: Int { withLock { residentByteCount } }

    public func snapshot() -> TiledRasterRevisionStoreSnapshot {
        withLock {
            TiledRasterRevisionStoreSnapshot(
                maximumRetainedBytes: maximumRetainedBytes,
                residentBytes: residentByteCount,
                provisionalRevisionCount: entries.values.reduce(into: 0) {
                    if $1.lifetime == .provisional { $0 += 1 }
                },
                publishedRevisionCount: entries.values.reduce(into: 0) {
                    if $1.lifetime == .published { $0 += 1 }
                },
                inFlightOperationCount: operations.count,
                inFlightInstallLeaseCount: installRecords.count
            )
        }
    }

    public func containsRevision(_ id: StoredRasterRevisionID) -> Bool {
        withLock {
            id.belongs(to: storeIdentity) && entries[id] != nil
        }
    }

    public func allocatePair(
        layerID: UUID,
        generation: UInt64,
        pixelSize: PixelSize,
        dirtyRegions: PixelRegionSet,
        beforePresentCoordinates: [PaintTileCoordinate],
        afterPresentCoordinates: [PaintTileCoordinate],
        failureInjection: TiledRasterRevisionFailureInjection? = nil
    ) throws -> PendingRasterRevisionPair {
        let dirtyCoordinates = try coordinates(
            for: dirtyRegions,
            pixelSize: pixelSize
        )
        guard !dirtyCoordinates.isEmpty else {
            throw TiledRasterRevisionStoreError.emptyCoordinateSet
        }
        let beforePresent = try validatedPresentCoordinates(
            beforePresentCoordinates,
            within: dirtyCoordinates
        ).sorted()
        let afterPresent = try validatedPresentCoordinates(
            afterPresentCoordinates,
            within: dirtyCoordinates
        ).sorted()
        return try allocatePair(
            layerID: layerID,
            before: TiledRasterRevisionEndpoint(
                generation: generation,
                pixelSize: pixelSize,
                documentPixelSize: pixelSize,
                coordinates: dirtyCoordinates,
                presentCoordinates: beforePresent
            ),
            after: TiledRasterRevisionEndpoint(
                generation: generation,
                pixelSize: pixelSize,
                documentPixelSize: pixelSize,
                coordinates: dirtyCoordinates,
                presentCoordinates: afterPresent
            ),
            failureInjection: failureInjection
        )
    }

    public func allocatePair(
        layerID: UUID,
        before: TiledRasterRevisionEndpoint,
        after: TiledRasterRevisionEndpoint,
        failureInjection: TiledRasterRevisionFailureInjection? = nil
    ) throws -> PendingRasterRevisionPair {
        guard !before.coordinates.isEmpty || !after.coordinates.isEmpty else {
            throw TiledRasterRevisionStoreError.emptyCoordinateSet
        }
        let beforeLayout = try makeLayout(
            coordinates: before.coordinates,
            present: Set(before.presentCoordinates),
            pixelSize: before.pixelSize
        )
        let afterLayout = try makeLayout(
            coordinates: after.coordinates,
            present: Set(after.presentCoordinates),
            pixelSize: after.pixelSize
        )
        let pairBytes = try checkedSum(
            beforeLayout.retainedBytes,
            afterLayout.retainedBytes
        )
        let available = withLock { maximumRetainedBytes - residentByteCount }
        guard pairBytes <= available else {
            throw TiledRasterRevisionStoreError.byteBudgetExceeded(
                requiredBytes: pairBytes,
                availableBytes: available
            )
        }

        var allocationIndex = 0
        let beforeBuffer = try makeBuffer(
            length: beforeLayout.retainedBytes,
            allocationIndex: &allocationIndex,
            failureInjection: failureInjection
        )
        let afterBuffer = try makeBuffer(
            length: afterLayout.retainedBytes,
            allocationIndex: &allocationIndex,
            failureInjection: failureInjection
        )

        return try withLock {
            let currentAvailable = maximumRetainedBytes - residentByteCount
            guard pairBytes <= currentAvailable else {
                throw TiledRasterRevisionStoreError.byteBudgetExceeded(
                    requiredBytes: pairBytes,
                    availableBytes: currentAvailable
                )
            }
            guard nextRevisionID <= UInt64.max - 2 else {
                throw TiledRasterRevisionStoreError.byteCountOverflow
            }
            let beforeID = StoredRasterRevisionID(
                rawValue: nextRevisionID,
                namespace: storeIdentity
            )
            let afterID = StoredRasterRevisionID(
                rawValue: nextRevisionID + 1,
                namespace: storeIdentity
            )
            nextRevisionID += 2
            let beforeStorage = RasterRevisionStorage.tiledRGBA16Float(
                layerID: layerID,
                generation: before.generation,
                tileCoordinates: before.coordinates.map(\.revisionCoordinate)
            )
            let afterStorage = RasterRevisionStorage.tiledRGBA16Float(
                layerID: layerID,
                generation: after.generation,
                tileCoordinates: after.coordinates.map(\.revisionCoordinate)
            )
            let beforeReference = RasterRevisionReference(
                id: beforeID,
                pixelSize: before.pixelSize,
                documentPixelSize: before.documentPixelSize,
                regions: before.regions,
                retainedBytes: beforeLayout.retainedBytes,
                storage: beforeStorage
            )
            let afterReference = RasterRevisionReference(
                id: afterID,
                pixelSize: after.pixelSize,
                documentPixelSize: after.documentPixelSize,
                regions: after.regions,
                retainedBytes: afterLayout.retainedBytes,
                storage: afterStorage
            )
            let pairID = beforeID
            entries[beforeID] = Entry(
                reference: beforeReference,
                pairID: pairID,
                buffer: beforeBuffer,
                slices: beforeLayout.slices,
                lifetime: .provisional,
                capturePending: false,
                captureSucceeded: false,
                inFlightCount: 0,
                releaseRequested: false
            )
            entries[afterID] = Entry(
                reference: afterReference,
                pairID: pairID,
                buffer: afterBuffer,
                slices: afterLayout.slices,
                lifetime: .provisional,
                capturePending: false,
                captureSucceeded: false,
                inFlightCount: 0,
                releaseRequested: false
            )
            pairs[pairID] = PairRecord(
                before: beforeReference,
                after: afterReference,
                isPublished: false
            )
            residentByteCount += pairBytes
            return PendingRasterRevisionPair(
                before: beforeReference,
                after: afterReference
            )
        }
    }

    public func encodeCapture(
        _ reference: RasterRevisionReference,
        layerID: UUID,
        generation: UInt64,
        sources: [TiledRasterRevisionTileSource],
        on commandBuffer: any MTLCommandBuffer,
        failureInjection: TiledRasterRevisionFailureInjection? = nil
    ) throws -> TiledRasterRevisionOperationToken {
        let reservation = try withLock {
            let entry = try validatedEntry(
                reference,
                layerID: layerID,
                generation: generation
            )
            guard entry.lifetime == .provisional,
                  !entry.capturePending,
                  !entry.captureSucceeded,
                  !entry.releaseRequested
            else {
                throw TiledRasterRevisionStoreError.pairNotReady
            }
            let orderedSources = try validate(
                sources: sources,
                for: entry
            )
            return (entry, orderedSources)
        }

        let token = try reserveOperation(
            revisionID: reference.id,
            kind: .capture,
            commandBuffer: commandBuffer,
            transientBuffers: []
        )
        do {
            if failureInjection?.shouldFail(at: .commandEncoding) == true {
                throw TiledRasterRevisionStoreError.injectedFailure(
                    .commandEncoding
                )
            }
            guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
                throw TiledRasterRevisionStoreError.blitEncoderUnavailable
            }
            encoder.label = "Capture Tiled Raster Revision"
            if let buffer = reservation.0.buffer,
               reference.retainedBytes > 0
            {
                encoder.fill(
                    buffer: buffer,
                    range: 0..<reference.retainedBytes,
                    value: 0
                )
            }
            for (index, source) in reservation.1.enumerated() {
                if failureInjection?.shouldFail(at: .tileCapture(index)) == true {
                    encoder.endEncoding()
                    throw TiledRasterRevisionStoreError.injectedFailure(
                        .tileCapture(index)
                    )
                }
                let slice = reservation.0.slices[index]
                guard let texture = source.texture,
                      let buffer = reservation.0.buffer
                else { continue }
                encoder.copy(
                    from: texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(
                        width: slice.descriptor.logicalBounds.width,
                        height: slice.descriptor.logicalBounds.height,
                        depth: 1
                    ),
                    to: buffer,
                    destinationOffset: slice.bufferOffset,
                    destinationBytesPerRow: slice.bytesPerRow,
                    destinationBytesPerImage: slice.bytesPerImage
                )
            }
            encoder.endEncoding()
            return token
        } catch {
            failPair(containing: reference.id)
            throw error
        }
    }

    public func encodeRestore(
        _ reference: RasterRevisionReference,
        layerID: UUID,
        generation: UInt64,
        targets: [TiledRasterRevisionTileTarget],
        on commandBuffer: any MTLCommandBuffer,
        failureInjection: TiledRasterRevisionFailureInjection? = nil
    ) throws -> TiledRasterRevisionOperationToken {
        let entry = try withLock {
            let entry = try validatedEntry(
                reference,
                layerID: layerID,
                generation: generation
            )
            guard entry.lifetime == .published,
                  entry.captureSucceeded,
                  !entry.releaseRequested
            else {
                throw TiledRasterRevisionStoreError.missingRevision
            }
            try validate(targets: targets, for: entry)
            return entry
        }
        let orderedTargets = targets.sorted { $0.coordinate < $1.coordinate }
        var transientBuffers: [any MTLBuffer] = []
        let clearByteCount = entry.slices
            .filter { !$0.isPresent }
            .map(\.bytesPerImage)
            .max() ?? 0
        if clearByteCount > 0 {
            if failureInjection?.shouldFail(at: .bufferAllocation(0)) == true {
                throw TiledRasterRevisionStoreError.injectedFailure(
                    .bufferAllocation(0)
                )
            }
            guard let clear = device.makeBuffer(
                length: clearByteCount,
                options: .storageModeShared
            ) else {
                throw TiledRasterRevisionStoreError.bufferAllocationFailed
            }
            clear.contents().initializeMemory(
                as: UInt8.self,
                repeating: 0,
                count: clearByteCount
            )
            transientBuffers.append(clear)
        }
        let token = try reserveOperation(
            revisionID: reference.id,
            kind: .restore,
            commandBuffer: commandBuffer,
            transientBuffers: transientBuffers
        )
        do {
            if failureInjection?.shouldFail(at: .commandEncoding) == true {
                throw TiledRasterRevisionStoreError.injectedFailure(
                    .commandEncoding
                )
            }
            guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
                throw TiledRasterRevisionStoreError.blitEncoderUnavailable
            }
            encoder.label = "Restore Tiled Raster Revision"
            for (index, target) in orderedTargets.enumerated() {
                let slice = entry.slices[index]
                let sourceBuffer: any MTLBuffer
                let sourceOffset: Int
                if slice.isPresent {
                    guard let retained = entry.buffer else {
                        preconditionFailure("Present slice must retain a buffer")
                    }
                    sourceBuffer = retained
                    sourceOffset = slice.bufferOffset
                } else {
                    guard let clear = transientBuffers.first else {
                        preconditionFailure("Clear slice needs transient zeros")
                    }
                    sourceBuffer = clear
                    sourceOffset = 0
                }
                encoder.copy(
                    from: sourceBuffer,
                    sourceOffset: sourceOffset,
                    sourceBytesPerRow: slice.bytesPerRow,
                    sourceBytesPerImage: slice.bytesPerImage,
                    sourceSize: MTLSize(
                        width: slice.descriptor.logicalBounds.width,
                        height: slice.descriptor.logicalBounds.height,
                        depth: 1
                    ),
                    to: target.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
            encoder.endEncoding()
            return token
        } catch {
            cancelOperation(token)
            throw error
        }
    }

    public func finalize(
        _ token: TiledRasterRevisionOperationToken,
        as outcome: RasterRevisionOperationOutcome,
        failureInjection: TiledRasterRevisionFailureInjection? = nil
    ) throws {
        let operation = try withLock {
            guard let operation = operations[token] else {
                throw TiledRasterRevisionStoreError.invalidOperationToken
            }
            return operation
        }
        let completed: Bool
        switch operation.commandBuffer.status {
        case .completed:
            completed = true
        case .notEnqueued, .error:
            completed = false
        case .enqueued, .committed, .scheduled:
            throw TiledRasterRevisionStoreError.operationDidNotComplete
        @unknown default:
            throw TiledRasterRevisionStoreError.operationDidNotComplete
        }
        let injectedCompletionFailure =
            failureInjection?.shouldFail(at: .completion) == true
        let succeeded = outcome == .succeeded
            && completed
            && !injectedCompletionFailure

        try withLock {
            guard let liveOperation = operations[token] else {
                throw TiledRasterRevisionStoreError.invalidOperationToken
            }
            finishOperation(
                token,
                operation: liveOperation,
                succeeded: succeeded
            )
        }
        if operation.kind == .capture, !succeeded {
            failPair(pairID: operation.pairID)
        }
        if injectedCompletionFailure {
            throw TiledRasterRevisionStoreError.injectedFailure(.completion)
        }
        if outcome == .succeeded, !completed {
            throw TiledRasterRevisionStoreError.operationDidNotComplete
        }
    }

    public func publish(
        _ pair: PendingRasterRevisionPair,
        failureInjection: TiledRasterRevisionFailureInjection? = nil
    ) throws {
        try withLock {
            guard let record = pairs[pair.before.id],
                  record.before == pair.before,
                  record.after == pair.after
            else {
                throw TiledRasterRevisionStoreError.forgedRevision
            }
            guard !record.isPublished else {
                throw TiledRasterRevisionStoreError.pairAlreadyPublished
            }
            guard let before = entries[pair.before.id],
                  let after = entries[pair.after.id],
                  before.lifetime == .provisional,
                  after.lifetime == .provisional,
                  before.captureSucceeded,
                  after.captureSucceeded,
                  before.inFlightCount == 0,
                  after.inFlightCount == 0
            else {
                throw TiledRasterRevisionStoreError.pairNotReady
            }
            if failureInjection?.shouldFail(at: .publish) == true {
                throw TiledRasterRevisionStoreError.injectedFailure(.publish)
            }
            entries[pair.before.id]!.lifetime = .published
            entries[pair.after.id]!.lifetime = .published
            pairs[pair.before.id]!.isPublished = true
        }
    }

    public func discard(_ pair: PendingRasterRevisionPair) throws {
        try withLock {
            guard let record = pairs[pair.before.id],
                  record.before == pair.before,
                  record.after == pair.after
            else {
                throw TiledRasterRevisionStoreError.forgedRevision
            }
            guard !record.isPublished else {
                throw TiledRasterRevisionStoreError.pairAlreadyPublished
            }
            let pairOperations = operations.values.filter {
                $0.pairID == pair.before.id
            }
            guard pairOperations.isEmpty else {
                throw TiledRasterRevisionStoreError.pairNotReady
            }
            removePair(pair.before.id)
        }
    }

    public func release(
        _ ids: Set<StoredRasterRevisionID>
    ) throws {
        try withLock {
            let localIDs = ids.filter { $0.belongs(to: storeIdentity) }
            for id in localIDs {
                guard let entry = entries[id],
                      entry.lifetime == .published
                else {
                    throw TiledRasterRevisionStoreError.missingRevision
                }
                guard !entry.releaseRequested else {
                    throw TiledRasterRevisionStoreError.releaseAlreadyRequested
                }
            }
            for id in localIDs {
                if entries[id]!.inFlightCount == 0 {
                    removeRevision(id)
                } else {
                    entries[id]!.releaseRequested = true
                }
            }
        }
    }

    public func beginInstall(
        for reference: RasterRevisionReference
    ) throws -> TiledRasterRevisionInstallLease {
        try beginInstall(for: reference, requiresPublishedPair: false)
    }

    /// Coordinator-only restore entry. Capture-ready provisional revisions are
    /// intentionally accepted by `beginInstall` for compatibility, but an
    /// irreversible history restore may lease only a published entry whose
    /// owning pair has been published atomically.
    public func beginPublishedInstall(
        for reference: RasterRevisionReference
    ) throws -> TiledRasterRevisionInstallLease {
        try beginInstall(for: reference, requiresPublishedPair: true)
    }

    private func beginInstall(
        for reference: RasterRevisionReference,
        requiresPublishedPair: Bool
    ) throws -> TiledRasterRevisionInstallLease {
        try withLock {
            guard reference.id.belongs(to: storeIdentity),
                  var entry = entries[reference.id],
                  entry.reference == reference,
                  !entry.releaseRequested,
                  let pair = pairs[entry.pairID],
                  let before = entries[pair.before.id],
                  let after = entries[pair.after.id],
                  before.captureSucceeded,
                  after.captureSucceeded,
                  before.inFlightCount == 0,
                  after.inFlightCount == 0,
                  !before.capturePending,
                  !after.capturePending,
                  let layerID = reference.layerID,
                  let generation = reference.generation
            else {
                throw TiledRasterRevisionStoreError.pairNotReady
            }
            if requiresPublishedPair {
                guard entry.lifetime == .published,
                      pair.isPublished,
                      before.lifetime == .published,
                      after.lifetime == .published
                else {
                    throw TiledRasterRevisionStoreError.pairNotReady
                }
            }
            guard !installRecords.values.contains(where: {
                $0.pairID == entry.pairID
            }) else {
                throw TiledRasterRevisionStoreError.pairNotReady
            }
            guard nextInstallLeaseID < UInt64.max else {
                throw TiledRasterRevisionStoreError.byteCountOverflow
            }
            let leaseID = nextInstallLeaseID
            nextInstallLeaseID += 1
            installRecords[leaseID] = InstallRecord(
                revisionID: reference.id,
                pairID: entry.pairID,
                layerID: layerID,
                generation: generation,
                state: .prepared,
                cancellationRequested: false
            )
            entry.inFlightCount += 1
            entries[reference.id] = entry
            return TiledRasterRevisionInstallLease(
                storeIdentity: storeIdentity,
                leaseID: leaseID,
                reference: reference,
                layerID: layerID,
                generation: generation,
                tiles: entry.slices.map {
                    TiledRasterRevisionInstallTile(
                        descriptor: $0.descriptor,
                        disposition: $0.isPresent ? .replace : .remove
                    )
                }
            )
        }
    }

    public func encodeInstall(
        _ lease: TiledRasterRevisionInstallLease,
        layerID: UUID,
        generation: UInt64,
        targets: [TiledRasterRevisionTileTarget],
        on commandBuffer: any MTLCommandBuffer,
        failureInjection: TiledRasterRevisionFailureInjection? = nil
    ) throws -> TiledRasterRevisionOperationToken {
        let entry = try withLock {
            let record = try validatedInstallRecord(
                lease,
                layerID: layerID,
                generation: generation
            )
            guard record.state == .prepared,
                  !record.cancellationRequested,
                  let entry = entries[record.revisionID]
            else {
                throw TiledRasterRevisionStoreError.invalidInstallLease
            }
            try validateInstall(targets: targets, for: entry)
            return entry
        }
        let orderedTargets = targets.sorted { $0.coordinate < $1.coordinate }
        let token = try reserveOperation(
            revisionID: lease.reference.id,
            kind: .install,
            installLeaseID: lease.leaseID,
            commandBuffer: commandBuffer,
            transientBuffers: []
        )
        do {
            if failureInjection?.shouldFail(at: .commandEncoding) == true {
                throw TiledRasterRevisionStoreError.injectedFailure(
                    .commandEncoding
                )
            }
            guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
                throw TiledRasterRevisionStoreError.blitEncoderUnavailable
            }
            encoder.label = "Install Tiled Raster Revision"
            let presentSlices = entry.slices.filter(\.isPresent)
            for (slice, target) in zip(presentSlices, orderedTargets) {
                guard let buffer = entry.buffer else {
                    preconditionFailure("Present slice must retain bytes")
                }
                encoder.copy(
                    from: buffer,
                    sourceOffset: slice.bufferOffset,
                    sourceBytesPerRow: slice.bytesPerRow,
                    sourceBytesPerImage: slice.bytesPerImage,
                    sourceSize: MTLSize(
                        width: slice.descriptor.logicalBounds.width,
                        height: slice.descriptor.logicalBounds.height,
                        depth: 1
                    ),
                    to: target.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
            encoder.endEncoding()
            return token
        } catch {
            cancelOperation(token)
            throw error
        }
    }

    public func consumeInstall(
        _ lease: TiledRasterRevisionInstallLease,
        layerID: UUID,
        generation: UInt64,
        failureInjection: TiledRasterRevisionFailureInjection? = nil
    ) throws {
        try withLock {
            let record = try validatedInstallRecord(
                lease,
                layerID: layerID,
                generation: generation
            )
            guard record.state == .readyToConsume,
                  !record.cancellationRequested,
                  var entry = entries[record.revisionID],
                  entry.inFlightCount > 0
            else {
                throw TiledRasterRevisionStoreError.invalidInstallLease
            }
            if failureInjection?.shouldFail(at: .consumeInstall) == true {
                throw TiledRasterRevisionStoreError.injectedFailure(
                    .consumeInstall
                )
            }
            installRecords.removeValue(forKey: lease.leaseID)
            entry.inFlightCount -= 1
            entries[record.revisionID] = entry
            if entry.inFlightCount == 0, entry.releaseRequested {
                removeRevision(record.revisionID)
            }
        }
    }

    /// Abandons a prepared or completed install lease. If its GPU copy is
    /// already encoded, cancellation is tombstoned until finalization so the
    /// retained source payload remains owned and accounted while Metal uses it.
    public func cancelInstall(
        _ lease: TiledRasterRevisionInstallLease,
        layerID: UUID,
        generation: UInt64
    ) throws {
        try withLock {
            var record = try validatedInstallRecord(
                lease,
                layerID: layerID,
                generation: generation
            )
            guard !record.cancellationRequested else {
                throw TiledRasterRevisionStoreError.invalidInstallLease
            }
            switch record.state {
            case .prepared, .readyToConsume:
                releaseInstallLeaseLocked(lease.leaseID)
            case .encoding:
                record.cancellationRequested = true
                installRecords[lease.leaseID] = record
            }
        }
    }

    func snapshotsForHarness() throws
        -> [TiledRasterRevisionHarnessSnapshot]
    {
        let payloads = withLock {
            entries.values.filter { $0.lifetime == .published }
                .sorted { $0.reference.id.rawValue < $1.reference.id.rawValue }
        }
        guard !payloads.isEmpty else { return [] }
        let queue = try requiredCommandQueue()
        var result: [TiledRasterRevisionHarnessSnapshot] = []
        result.reserveCapacity(payloads.count)
        for payload in payloads {
            let staging: (any MTLBuffer)?
            if payload.reference.retainedBytes > 0 {
                guard let allocated = device.makeBuffer(
                    length: payload.reference.retainedBytes,
                    options: .storageModeShared
                ) else {
                    throw TiledRasterRevisionStoreError.bufferAllocationFailed
                }
                guard let source = payload.buffer,
                      let command = queue.makeCommandBuffer(),
                      let encoder = command.makeBlitCommandEncoder()
                else {
                    throw TiledRasterRevisionStoreError.blitEncoderUnavailable
                }
                encoder.copy(
                    from: source,
                    sourceOffset: 0,
                    to: allocated,
                    destinationOffset: 0,
                    size: payload.reference.retainedBytes
                )
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                guard command.status == .completed else {
                    throw TiledRasterRevisionStoreError.operationDidNotComplete
                }
                staging = allocated
            } else {
                staging = nil
            }
            let entries = payload.slices.map { slice in
                let captured: TiledRasterRevisionHarnessPayload
                if slice.isPresent {
                    guard let staging else {
                        preconditionFailure("Present slice needs staging bytes")
                    }
                    var compact = Data()
                    compact.reserveCapacity(
                        slice.compactBytesPerRow
                            * slice.descriptor.logicalBounds.height
                    )
                    for row in 0..<slice.descriptor.logicalBounds.height {
                        let start = slice.bufferOffset
                            + row * slice.bytesPerRow
                        compact.append(
                            Data(
                                bytes: staging.contents().advanced(by: start),
                                count: slice.compactBytesPerRow
                            )
                        )
                    }
                    captured = .rgba16Float(compact)
                } else {
                    captured = .knownClear
                }
                return TiledRasterRevisionHarnessPayloadEntry(
                    coordinate: slice.descriptor.coordinate,
                    payload: captured
                )
            }
            result.append(
                TiledRasterRevisionHarnessSnapshot(
                    reference: payload.reference,
                    payloads: entries
                )
            )
        }
        return result
    }

    private func coordinates(
        for regions: PixelRegionSet,
        pixelSize: PixelSize
    ) throws -> [PaintTileCoordinate] {
        var coordinates = Set<PaintTileCoordinate>()
        for region in regions.rectangles {
            coordinates.formUnion(try PaintTileDescriptor.coordinates(
                intersecting: region,
                in: pixelSize,
                antialiasHalo: 0
            ))
        }
        return coordinates.sorted()
    }

    private func validatedPresentCoordinates(
        _ coordinates: [PaintTileCoordinate],
        within dirtyCoordinates: [PaintTileCoordinate]
    ) throws -> Set<PaintTileCoordinate> {
        var unique = Set<PaintTileCoordinate>()
        let dirty = Set(dirtyCoordinates)
        for coordinate in coordinates {
            guard unique.insert(coordinate).inserted else {
                throw TiledRasterRevisionStoreError.duplicateCoordinate(
                    coordinate
                )
            }
            guard dirty.contains(coordinate) else {
                throw TiledRasterRevisionStoreError
                    .presentCoordinateOutsideDirtySet(coordinate)
            }
        }
        return unique
    }

    private func makeLayout(
        coordinates: [PaintTileCoordinate],
        present: Set<PaintTileCoordinate>,
        pixelSize: PixelSize
    ) throws -> Layout {
        let alignment = device.minimumTextureBufferAlignment(
            for: PaintTileDescriptor.pixelFormat
        )
        precondition(alignment > 0)
        var offset = 0
        var slices: [Slice] = []
        slices.reserveCapacity(coordinates.count)
        for coordinate in coordinates {
            let descriptor = try PaintTileDescriptor(
                coordinate: coordinate,
                logicalPixelSize: pixelSize
            )
            let compactBytesPerRow = try checkedMultiply(
                descriptor.logicalBounds.width,
                8
            )
            let bytesPerRow = try aligned(
                compactBytesPerRow,
                to: alignment
            )
            let bytesPerImage = try checkedMultiply(
                bytesPerRow,
                descriptor.logicalBounds.height
            )
            let isPresent = present.contains(coordinate)
            slices.append(
                Slice(
                    descriptor: descriptor,
                    isPresent: isPresent,
                    bufferOffset: offset,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerImage,
                    compactBytesPerRow: compactBytesPerRow
                )
            )
            if isPresent {
                offset = try checkedSum(offset, bytesPerImage)
            }
        }
        return Layout(slices: slices, retainedBytes: offset)
    }

    private func makeBuffer(
        length: Int,
        allocationIndex: inout Int,
        failureInjection: TiledRasterRevisionFailureInjection?
    ) throws -> (any MTLBuffer)? {
        guard length > 0 else { return nil }
        let index = allocationIndex
        allocationIndex += 1
        if failureInjection?.shouldFail(at: .bufferAllocation(index)) == true {
            throw TiledRasterRevisionStoreError.injectedFailure(
                .bufferAllocation(index)
            )
        }
        guard let buffer = device.makeBuffer(
            length: length,
            options: .storageModePrivate
        ) else {
            throw TiledRasterRevisionStoreError.bufferAllocationFailed
        }
        return buffer
    }

    private func validatedEntry(
        _ reference: RasterRevisionReference,
        layerID: UUID,
        generation: UInt64
    ) throws -> Entry {
        guard reference.id.belongs(to: storeIdentity),
              let entry = entries[reference.id]
        else {
            throw TiledRasterRevisionStoreError.missingRevision
        }
        guard entry.reference == reference else {
            throw TiledRasterRevisionStoreError.forgedRevision
        }
        guard let expectedLayer = reference.layerID else {
            throw TiledRasterRevisionStoreError.forgedRevision
        }
        guard expectedLayer == layerID else {
            throw TiledRasterRevisionStoreError.layerMismatch(
                expected: expectedLayer,
                actual: layerID
            )
        }
        guard let expectedGeneration = reference.generation else {
            throw TiledRasterRevisionStoreError.forgedRevision
        }
        guard expectedGeneration == generation else {
            throw TiledRasterRevisionStoreError.generationMismatch(
                expected: expectedGeneration,
                actual: generation
            )
        }
        return entry
    }

    private func validate(
        sources: [TiledRasterRevisionTileSource],
        for entry: Entry
    ) throws -> [TiledRasterRevisionTileSource] {
        var unique = Set<PaintTileCoordinate>()
        for source in sources {
            guard unique.insert(source.coordinate).inserted else {
                throw TiledRasterRevisionStoreError.duplicateCoordinate(
                    source.coordinate
                )
            }
        }
        let expected = entry.slices.map(\.descriptor.coordinate)
        guard unique == Set(expected), sources.count == expected.count else {
            throw TiledRasterRevisionStoreError.coordinateSetMismatch
        }
        let ordered = sources.sorted { $0.coordinate < $1.coordinate }
        for (source, slice) in zip(ordered, entry.slices) {
            guard (source.texture != nil) == slice.isPresent else {
                throw TiledRasterRevisionStoreError.presentStateMismatch(
                    source.coordinate
                )
            }
            if let texture = source.texture {
                try validate(texture: texture)
            }
        }
        return ordered
    }

    private func validate(
        targets: [TiledRasterRevisionTileTarget],
        for entry: Entry
    ) throws {
        var unique = Set<PaintTileCoordinate>()
        for target in targets {
            guard unique.insert(target.coordinate).inserted else {
                throw TiledRasterRevisionStoreError.duplicateCoordinate(
                    target.coordinate
                )
            }
            try validate(texture: target.texture)
        }
        let expected = Set(entry.slices.map(\.descriptor.coordinate))
        guard unique == expected, targets.count == expected.count else {
            throw TiledRasterRevisionStoreError.coordinateSetMismatch
        }
    }

    private func validateInstall(
        targets: [TiledRasterRevisionTileTarget],
        for entry: Entry
    ) throws {
        var unique = Set<PaintTileCoordinate>()
        for target in targets {
            guard unique.insert(target.coordinate).inserted else {
                throw TiledRasterRevisionStoreError.duplicateCoordinate(
                    target.coordinate
                )
            }
            try validate(texture: target.texture)
        }
        let expected = Set(
            entry.slices.lazy
                .filter(\.isPresent)
                .map(\.descriptor.coordinate)
        )
        guard unique == expected, targets.count == expected.count else {
            throw TiledRasterRevisionStoreError.coordinateSetMismatch
        }
    }

    private func validatedInstallRecord(
        _ lease: TiledRasterRevisionInstallLease,
        layerID: UUID,
        generation: UInt64
    ) throws -> InstallRecord {
        guard lease.storeIdentity == storeIdentity,
              let record = installRecords[lease.leaseID],
              record.revisionID == lease.reference.id,
              record.layerID == lease.layerID,
              record.generation == lease.generation,
              let entry = entries[record.revisionID],
              entry.reference == lease.reference,
              entry.pairID == record.pairID
        else {
            throw TiledRasterRevisionStoreError.invalidInstallLease
        }
        guard record.layerID == layerID else {
            throw TiledRasterRevisionStoreError.layerMismatch(
                expected: record.layerID,
                actual: layerID
            )
        }
        guard record.generation == generation else {
            throw TiledRasterRevisionStoreError.generationMismatch(
                expected: record.generation,
                actual: generation
            )
        }
        return record
    }

    private func validate(texture: any MTLTexture) throws {
        guard texture.pixelFormat == PaintTileDescriptor.pixelFormat else {
            throw TiledRasterRevisionStoreError.invalidTextureFormat
        }
        guard texture.width == PaintTileDescriptor.side,
              texture.height == PaintTileDescriptor.side
        else {
            throw TiledRasterRevisionStoreError.invalidTextureSize
        }
    }

    private func reserveOperation(
        revisionID: StoredRasterRevisionID,
        kind: OperationKind,
        installLeaseID: UInt64? = nil,
        commandBuffer: any MTLCommandBuffer,
        transientBuffers: [any MTLBuffer]
    ) throws -> TiledRasterRevisionOperationToken {
        try withLock {
            guard var entry = entries[revisionID] else {
                throw TiledRasterRevisionStoreError.missingRevision
            }
            guard nextOperationID < UInt64.max else {
                throw TiledRasterRevisionStoreError.byteCountOverflow
            }
            if kind == .capture {
                guard !entry.capturePending, !entry.captureSucceeded else {
                    throw TiledRasterRevisionStoreError.pairNotReady
                }
                entry.capturePending = true
            } else if kind == .install {
                guard let installLeaseID,
                      var record = installRecords[installLeaseID],
                      record.revisionID == revisionID,
                      record.pairID == entry.pairID,
                      record.state == .prepared,
                      !record.cancellationRequested
                else {
                    throw TiledRasterRevisionStoreError.invalidInstallLease
                }
                record.state = .encoding
                installRecords[installLeaseID] = record
            } else {
                precondition(installLeaseID == nil)
            }
            entry.inFlightCount += 1
            entries[revisionID] = entry
            let token = TiledRasterRevisionOperationToken(
                storeIdentity: storeIdentity,
                sequence: nextOperationID
            )
            nextOperationID += 1
            operations[token] = Operation(
                revisionID: revisionID,
                pairID: entry.pairID,
                kind: kind,
                installLeaseID: installLeaseID,
                commandBuffer: commandBuffer,
                transientBuffers: transientBuffers
            )
            return token
        }
    }

    private func cancelOperation(
        _ token: TiledRasterRevisionOperationToken
    ) {
        withLock {
            guard let operation = operations[token] else { return }
            finishOperation(token, operation: operation, succeeded: false)
        }
    }

    private func finishOperation(
        _ token: TiledRasterRevisionOperationToken,
        operation: Operation,
        succeeded: Bool
    ) {
        guard operations.removeValue(forKey: token) != nil,
              var entry = entries[operation.revisionID]
        else { return }
        if operation.kind == .capture {
            entry.capturePending = false
            entry.captureSucceeded = succeeded
        }
        precondition(entry.inFlightCount > 0)
        entry.inFlightCount -= 1
        if operation.kind == .install {
            guard let leaseID = operation.installLeaseID,
                  var record = installRecords[leaseID]
            else {
                preconditionFailure("Install operation must own a live lease")
            }
            if succeeded, !record.cancellationRequested {
                precondition(record.state == .encoding)
                record.state = .readyToConsume
                installRecords[leaseID] = record
            } else {
                installRecords.removeValue(forKey: leaseID)
                precondition(entry.inFlightCount > 0)
                entry.inFlightCount -= 1
            }
        }
        entries[operation.revisionID] = entry
        if entry.inFlightCount == 0, entry.releaseRequested {
            removeRevision(operation.revisionID)
        }
    }

    private func releaseInstallLeaseLocked(_ leaseID: UInt64) {
        guard let record = installRecords.removeValue(forKey: leaseID),
              var entry = entries[record.revisionID]
        else { return }
        precondition(entry.inFlightCount > 0)
        entry.inFlightCount -= 1
        entries[record.revisionID] = entry
        if entry.inFlightCount == 0, entry.releaseRequested {
            removeRevision(record.revisionID)
        }
    }

    private func failPair(containing revisionID: StoredRasterRevisionID) {
        withLock {
            guard let pairID = entries[revisionID]?.pairID else { return }
            failPairLocked(pairID: pairID)
        }
    }

    private func failPair(pairID: StoredRasterRevisionID) {
        withLock { failPairLocked(pairID: pairID) }
    }

    private func failPairLocked(pairID: StoredRasterRevisionID) {
        let tokens = operations.compactMap { token, operation in
            operation.pairID == pairID ? token : nil
        }
        for token in tokens {
            operations.removeValue(forKey: token)
        }
        removePair(pairID)
    }

    private func removePair(_ pairID: StoredRasterRevisionID) {
        let operationTokens = operations.compactMap { token, operation in
            operation.pairID == pairID ? token : nil
        }
        for token in operationTokens {
            operations.removeValue(forKey: token)
        }
        let leaseIDs = installRecords.compactMap { leaseID, record in
            record.pairID == pairID ? leaseID : nil
        }
        for leaseID in leaseIDs {
            installRecords.removeValue(forKey: leaseID)
        }
        guard let pair = pairs.removeValue(forKey: pairID) else { return }
        removeRevision(pair.before.id)
        removeRevision(pair.after.id)
    }

    private func removeRevision(_ id: StoredRasterRevisionID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        precondition(residentByteCount >= entry.reference.retainedBytes)
        residentByteCount -= entry.reference.retainedBytes
        if let pair = pairs[entry.pairID] {
            let otherID = pair.before.id == id
                ? pair.after.id
                : pair.before.id
            if entries[otherID] == nil {
                pairs.removeValue(forKey: entry.pairID)
            }
        }
    }

    private func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw TiledRasterRevisionStoreError.byteCountOverflow
        }
        return result
    }

    private func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw TiledRasterRevisionStoreError.byteCountOverflow
        }
        return result
    }

    private func aligned(_ value: Int, to alignment: Int) throws -> Int {
        let padded = try checkedSum(value, alignment - 1)
        return (padded / alignment) * alignment
    }

    private func requiredCommandQueue() throws -> any MTLCommandQueue {
        guard let queue = device.makeCommandQueue() else {
            throw TiledRasterRevisionStoreError.operationDidNotComplete
        }
        return queue
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private extension PaintTileCoordinate {
    var revisionCoordinate: RasterRevisionTileCoordinate {
        RasterRevisionTileCoordinate(x: x, y: y)
    }
}
