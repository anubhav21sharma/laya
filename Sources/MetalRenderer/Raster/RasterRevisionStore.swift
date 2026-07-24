import Foundation
import Metal
import PatternEngine

public struct RasterRevisionOperationToken:
    Hashable, Sendable
{
    private let storeIdentity: UInt64
    private let sequence: UInt64

    fileprivate init(storeIdentity: UInt64, sequence: UInt64) {
        self.storeIdentity = storeIdentity
        self.sequence = sequence
    }
}

public enum RasterRevisionOperationOutcome: Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
}

public struct PendingRasterRevisionPair: Equatable, Sendable {
    public let before: RasterRevisionReference
    public let after: RasterRevisionReference

    init(
        before: RasterRevisionReference,
        after: RasterRevisionReference
    ) {
        precondition(before.id != after.id)
        self.before = before
        self.after = after
    }

    public var retainedBytes: Int {
        before.retainedBytes + after.retainedBytes
    }

    public var revisionIDs: Set<StoredRasterRevisionID> {
        Set([before.id, after.id])
    }
}

public final class RasterRevisionStore: @unchecked Sendable {
    private enum Lifetime {
        case provisional
        case published
    }

    private enum OperationKind {
        case capture
        case restore
    }

    private struct Slice {
        let region: PixelRect
        let bufferOffset: Int
        let bytesPerRow: Int
        let bytesPerImage: Int
    }

    private struct Layout {
        let slices: [Slice]
        let retainedBytes: Int
    }

    private struct Payload {
        let reference: RasterRevisionReference
        let buffer: any MTLBuffer
        let slices: [Slice]
    }

    private struct Entry {
        let payload: Payload
        var lifetime: Lifetime
        var capturePending: Bool
        var captureSucceeded: Bool
        var inFlightCount: Int
        var releaseRequested: Bool
    }

    private struct Operation {
        let revisionID: StoredRasterRevisionID
        let kind: OperationKind
        let commandBuffer: any MTLCommandBuffer
    }

    private let device: any MTLDevice
    private let storeIdentity =
        RasterRevisionStoreIdentitySource.shared.makeIdentity()
    private let lock = NSLock()
    private var entries: [StoredRasterRevisionID: Entry] = [:]
    private var operations: [RasterRevisionOperationToken: Operation] = [:]
    private var nextID: UInt64 = 1
    private var nextOperationToken: UInt64 = 1
    private var residentByteCount = 0

    public init(device: any MTLDevice) {
        self.device = device
    }

    public var residentBytes: Int {
        withLock { residentByteCount }
    }

    public func retainedBytes(
        pixelSize: PixelSize,
        regions: PixelRegionSet
    ) throws -> Int {
        try makeLayout(pixelSize: pixelSize, regions: regions).retainedBytes
    }

    public func allocatePair(
        beforePixelSize: PixelSize,
        beforeDocumentPixelSize: PixelSize? = nil,
        beforeRegions: PixelRegionSet,
        afterPixelSize: PixelSize,
        afterDocumentPixelSize: PixelSize? = nil,
        afterRegions: PixelRegionSet
    ) throws -> PendingRasterRevisionPair {
        let beforeLayout = try makeLayout(
            pixelSize: beforePixelSize,
            regions: beforeRegions
        )
        let afterLayout = try makeLayout(
            pixelSize: afterPixelSize,
            regions: afterRegions
        )
        guard
            beforeLayout.retainedBytes
                <= Int.max - afterLayout.retainedBytes
        else {
            throw MetalRendererError.rasterRevisionStorageOverflow
        }

        guard
            let beforeBuffer = device.makeBuffer(
                length: beforeLayout.retainedBytes,
                options: .storageModePrivate
            ),
            let afterBuffer = device.makeBuffer(
                length: afterLayout.retainedBytes,
                options: .storageModePrivate
            )
        else {
            throw MetalRendererError.rasterRevisionBufferAllocationFailed
        }
        beforeBuffer.label = "Raster Revision Before"
        afterBuffer.label = "Raster Revision After"

        return try withLock {
            let pairBytes = beforeLayout.retainedBytes
                + afterLayout.retainedBytes
            guard residentByteCount <= Int.max - pairBytes else {
                throw MetalRendererError.rasterRevisionStorageOverflow
            }
            precondition(
                nextID <= UInt64.max - 2,
                "Raster revision identity space exhausted."
            )
            let beforeID = StoredRasterRevisionID(
                rawValue: nextID,
                namespace: storeIdentity
            )
            let afterID = StoredRasterRevisionID(
                rawValue: nextID + 1,
                namespace: storeIdentity
            )
            nextID += 2

            let beforeReference = RasterRevisionReference(
                id: beforeID,
                pixelSize: beforePixelSize,
                documentPixelSize:
                    beforeDocumentPixelSize ?? beforePixelSize,
                regions: beforeRegions,
                retainedBytes: beforeLayout.retainedBytes
            )
            let afterReference = RasterRevisionReference(
                id: afterID,
                pixelSize: afterPixelSize,
                documentPixelSize:
                    afterDocumentPixelSize ?? afterPixelSize,
                regions: afterRegions,
                retainedBytes: afterLayout.retainedBytes
            )
            let beforePayload = Payload(
                reference: beforeReference,
                buffer: beforeBuffer,
                slices: beforeLayout.slices
            )
            let afterPayload = Payload(
                reference: afterReference,
                buffer: afterBuffer,
                slices: afterLayout.slices
            )
            entries[beforeID] = Entry(
                payload: beforePayload,
                lifetime: .provisional,
                capturePending: false,
                captureSucceeded: false,
                inFlightCount: 0,
                releaseRequested: false
            )
            entries[afterID] = Entry(
                payload: afterPayload,
                lifetime: .provisional,
                capturePending: false,
                captureSucceeded: false,
                inFlightCount: 0,
                releaseRequested: false
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
        from texture: any MTLTexture,
        on commandBuffer: any MTLCommandBuffer
    ) throws -> RasterRevisionOperationToken {
        let reservation = try withLock {
            guard
                var entry = entries[reference.id],
                entry.payload.reference == reference,
                !entry.releaseRequested
            else {
                throw MetalRendererError.missingRasterRevision
            }
            try validate(texture: texture, for: reference)
            precondition(
                entry.lifetime == .provisional,
                "Published raster revisions are immutable."
            )
            precondition(
                !entry.capturePending && !entry.captureSucceeded,
                "A raster revision can have only one successful capture."
            )
            entry.capturePending = true
            entry.inFlightCount += 1
            entries[reference.id] = entry
            let token = makeOperationToken()
            operations[token] = Operation(
                revisionID: reference.id,
                kind: .capture,
                commandBuffer: commandBuffer
            )
            return (entry.payload, token)
        }

        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            finalizeAfterEncodingFailure(reservation.1)
            throw MetalRendererError.commandFailed(
                "Metal blit encoder creation failed."
            )
        }
        encoder.label = "Capture Raster Revision"
        for slice in reservation.0.slices {
            encoder.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(
                    x: slice.region.minX,
                    y: slice.region.minY,
                    z: 0
                ),
                sourceSize: MTLSize(
                    width: slice.region.width,
                    height: slice.region.height,
                    depth: 1
                ),
                to: reservation.0.buffer,
                destinationOffset: slice.bufferOffset,
                destinationBytesPerRow: slice.bytesPerRow,
                destinationBytesPerImage: slice.bytesPerImage
            )
        }
        encoder.endEncoding()
        return reservation.1
    }

    public func encodeRestore(
        _ reference: RasterRevisionReference,
        into texture: any MTLTexture,
        on commandBuffer: any MTLCommandBuffer
    ) throws -> RasterRevisionOperationToken {
        let reservation = try withLock {
            guard
                var entry = entries[reference.id],
                entry.payload.reference == reference,
                !entry.releaseRequested
            else {
                throw MetalRendererError.missingRasterRevision
            }
            try validate(texture: texture, for: reference)
            precondition(
                entry.lifetime == .published,
                "Only published raster revisions may be restored."
            )
            precondition(
                entry.captureSucceeded,
                "An uncaptured raster revision cannot be restored."
            )
            entry.inFlightCount += 1
            entries[reference.id] = entry
            let token = makeOperationToken()
            operations[token] = Operation(
                revisionID: reference.id,
                kind: .restore,
                commandBuffer: commandBuffer
            )
            return (entry.payload, token)
        }

        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            finalizeAfterEncodingFailure(reservation.1)
            throw MetalRendererError.commandFailed(
                "Metal blit encoder creation failed."
            )
        }
        encoder.label = "Restore Raster Revision"
        for slice in reservation.0.slices {
            encoder.copy(
                from: reservation.0.buffer,
                sourceOffset: slice.bufferOffset,
                sourceBytesPerRow: slice.bytesPerRow,
                sourceBytesPerImage: slice.bytesPerImage,
                sourceSize: MTLSize(
                    width: slice.region.width,
                    height: slice.region.height,
                    depth: 1
                ),
                to: texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(
                    x: slice.region.minX,
                    y: slice.region.minY,
                    z: 0
                )
            )
        }
        encoder.endEncoding()
        return reservation.1
    }

    public func finalize(
        _ token: RasterRevisionOperationToken,
        as outcome: RasterRevisionOperationOutcome
    ) throws {
        let successWasRejected = try withLock {
            guard let operation = operations[token] else {
                throw MetalRendererError.invalidRasterRevisionOperationToken
            }
            switch operation.commandBuffer.status {
            case .enqueued, .committed, .scheduled:
                throw MetalRendererError.rasterRevisionOperationDidNotComplete
            case .notEnqueued, .completed, .error:
                break
            @unknown default:
                throw MetalRendererError.rasterRevisionOperationDidNotComplete
            }
            let succeeded: Bool
            if outcome == .succeeded {
                succeeded = operation.commandBuffer.status == .completed
            } else {
                succeeded = false
            }
            finishOperation(token, operation: operation, succeeded: succeeded)
            return outcome == .succeeded && !succeeded
        }

        if successWasRejected {
            throw MetalRendererError.rasterRevisionOperationDidNotComplete
        }
    }

    public func publish(_ pair: PendingRasterRevisionPair) {
        withLock {
            let ids = [pair.before.id, pair.after.id]
            let references = [pair.before, pair.after]
            for (id, reference) in zip(ids, references) {
                guard let entry = entries[id] else {
                    preconditionFailure(
                        "Cannot publish a missing raster revision."
                    )
                }
                precondition(
                    entry.payload.reference == reference,
                    "Cannot publish a forged raster revision reference."
                )
                precondition(
                    entry.lifetime == .provisional,
                    "Raster revision was already published."
                )
                precondition(
                    entry.inFlightCount == 0,
                    "Cannot publish an in-flight raster revision."
                )
                precondition(
                    entry.captureSucceeded,
                    "Cannot publish an uncaptured raster revision."
                )
            }
            for id in ids {
                entries[id]!.lifetime = .published
            }
        }
    }

    public func discard(_ pair: PendingRasterRevisionPair) {
        withLock {
            let ids = [pair.before.id, pair.after.id]
            let references = [pair.before, pair.after]
            for (id, reference) in zip(ids, references) {
                guard let entry = entries[id] else {
                    preconditionFailure(
                        "Cannot discard a missing raster revision."
                    )
                }
                precondition(
                    entry.payload.reference == reference,
                    "Cannot discard a forged raster revision reference."
                )
                precondition(
                    entry.lifetime == .provisional,
                    "Published raster revisions must be released."
                )
                precondition(
                    entry.inFlightCount == 0,
                    "Cannot discard an in-flight raster revision."
                )
            }
            for id in ids {
                remove(id)
            }
        }
    }

    public func release(_ ids: Set<StoredRasterRevisionID>) {
        withLock {
            let localIDs = ids.filter { $0.belongs(to: storeIdentity) }
            for id in localIDs {
                guard let entry = entries[id] else {
                    preconditionFailure(
                        "Cannot release a missing raster revision."
                    )
                }
                precondition(
                    entry.lifetime == .published,
                    "Provisional raster revisions must be discarded."
                )
                precondition(
                    !entry.releaseRequested,
                    "Raster revision release was already requested."
                )
            }

            for id in localIDs {
                if entries[id]!.inFlightCount == 0 {
                    remove(id)
                } else {
                    entries[id]!.releaseRequested = true
                }
            }
        }
    }

    private func makeLayout(
        pixelSize: PixelSize,
        regions: PixelRegionSet
    ) throws -> Layout {
        guard !regions.rectangles.isEmpty else {
            throw MetalRendererError.emptyRasterRevisionRegions
        }
        let alignment = device.minimumTextureBufferAlignment(
            for: .bgra8Unorm
        )
        precondition(alignment > 0)

        var slices: [Slice] = []
        slices.reserveCapacity(regions.rectangles.count)
        var offset = 0
        for region in regions.rectangles {
            guard
                region.minX >= 0,
                region.minY >= 0,
                region.maxX <= pixelSize.width,
                region.maxY <= pixelSize.height
            else {
                throw MetalRendererError.rasterRevisionRegionOutOfBounds
            }
            guard region.width <= Int.max / 4 else {
                throw MetalRendererError.rasterRevisionStorageOverflow
            }
            let unalignedBytesPerRow = region.width * 4
            guard unalignedBytesPerRow <= Int.max - (alignment - 1) else {
                throw MetalRendererError.rasterRevisionStorageOverflow
            }
            let bytesPerRow = (
                (unalignedBytesPerRow + alignment - 1) / alignment
            ) * alignment
            guard region.height <= Int.max / bytesPerRow else {
                throw MetalRendererError.rasterRevisionStorageOverflow
            }
            let bytesPerImage = bytesPerRow * region.height
            guard offset <= Int.max - bytesPerImage else {
                throw MetalRendererError.rasterRevisionStorageOverflow
            }
            slices.append(
                Slice(
                    region: region,
                    bufferOffset: offset,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerImage
                )
            )
            offset += bytesPerImage
        }
        return Layout(slices: slices, retainedBytes: offset)
    }

    private func validate(
        texture: any MTLTexture,
        for reference: RasterRevisionReference
    ) throws {
        guard texture.pixelFormat == .bgra8Unorm else {
            throw MetalRendererError.invalidRasterRevisionTextureFormat
        }
        guard
            texture.width == reference.pixelSize.width,
            texture.height == reference.pixelSize.height
        else {
            throw MetalRendererError.rasterRevisionTextureSizeMismatch(
                expectedWidth: reference.pixelSize.width,
                expectedHeight: reference.pixelSize.height,
                actualWidth: texture.width,
                actualHeight: texture.height
            )
        }
        for region in reference.regions.rectangles {
            guard
                region.minX >= 0,
                region.minY >= 0,
                region.maxX <= texture.width,
                region.maxY <= texture.height
            else {
                throw MetalRendererError.rasterRevisionRegionOutOfBounds
            }
        }
    }

    private func makeOperationToken() -> RasterRevisionOperationToken {
        precondition(
            nextOperationToken < UInt64.max,
            "Raster revision operation identity space exhausted."
        )
        let token = RasterRevisionOperationToken(
            storeIdentity: storeIdentity,
            sequence: nextOperationToken
        )
        nextOperationToken += 1
        return token
    }

    private func finalizeAfterEncodingFailure(
        _ token: RasterRevisionOperationToken
    ) {
        withLock {
            guard let operation = operations[token] else {
                preconditionFailure(
                    "A just-created raster revision operation must be valid."
                )
            }
            finishOperation(token, operation: operation, succeeded: false)
        }
    }

    private func finishOperation(
        _ token: RasterRevisionOperationToken,
        operation: Operation,
        succeeded: Bool
    ) {
        guard operations.removeValue(forKey: token) != nil else {
            preconditionFailure("Raster revision operation was already final.")
        }
        guard var entry = entries[operation.revisionID] else {
            preconditionFailure(
                "An in-flight raster revision cannot disappear."
            )
        }
        precondition(entry.inFlightCount > 0)

        switch operation.kind {
        case .capture:
            precondition(entry.capturePending)
            entry.capturePending = false
            entry.captureSucceeded = succeeded
        case .restore:
            break
        }

        entry.inFlightCount -= 1
        entries[operation.revisionID] = entry
        if entry.inFlightCount == 0, entry.releaseRequested {
            remove(operation.revisionID)
        }
    }

    private func remove(_ id: StoredRasterRevisionID) {
        guard let entry = entries.removeValue(forKey: id) else {
            preconditionFailure("Raster revision was already removed.")
        }
        precondition(residentByteCount >= entry.payload.reference.retainedBytes)
        residentByteCount -= entry.payload.reference.retainedBytes
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class RasterRevisionStoreIdentitySource: @unchecked Sendable {
    static let shared = RasterRevisionStoreIdentitySource()

    private let lock = NSLock()
    private var nextIdentity: UInt64 = 1

    func makeIdentity() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        precondition(
            nextIdentity < UInt64.max,
            "Raster revision store identity space exhausted."
        )
        let identity = nextIdentity
        nextIdentity += 1
        return identity
    }
}
