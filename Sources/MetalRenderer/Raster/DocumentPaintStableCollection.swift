import Foundation
import PatternEngine

enum DocumentPaintStableCollectionError: Error, Equatable, Sendable {
    case arithmeticOverflow
    case outputByteLimitExceeded(required: Int, maximum: Int)
    case descriptorMismatch
    case alreadyBegan
    case notCollecting
    case alreadyTerminal
    case chunkOutsideOutput(SparseTileOutputRegion)
    case invalidChunkStride(expected: Int, actual: Int)
    case invalidChunkByteCount(expected: Int, actual: Int)
    case overlappingChunk(SparseTileOutputRegion)
    case incompleteCoverage(expectedPixels: Int, actualPixels: Int)
    case collectionUnavailable
}

struct DocumentPaintTightBGRA8Descriptor: Equatable, Sendable {
    let outputRegion: SparseTileOutputRegion
    let pixelSize: PixelSize
    let pixelCount: Int
    let bytesPerRow: Int
    let byteCount: Int

    init(
        outputRegion: SparseTileOutputRegion,
        maximumByteCount: Int
    ) throws {
        let (bytesPerRow, rowOverflow) = outputRegion.width
            .multipliedReportingOverflow(by: 4)
        let (byteCount, byteOverflow) = bytesPerRow
            .multipliedReportingOverflow(by: outputRegion.height)
        guard !rowOverflow, !byteOverflow else {
            throw DocumentPaintStableCollectionError.arithmeticOverflow
        }
        guard maximumByteCount >= 0, byteCount <= maximumByteCount else {
            throw DocumentPaintStableCollectionError.outputByteLimitExceeded(
                required: byteCount,
                maximum: maximumByteCount
            )
        }
        self.outputRegion = outputRegion
        pixelSize = PixelSize(
            width: outputRegion.width,
            height: outputRegion.height
        )
        pixelCount = byteCount / 4
        self.bytesPerRow = bytesPerRow
        self.byteCount = byteCount
    }

    func accepts(
        _ descriptor: DocumentPaintStableSnapshotSinkDescriptor
    ) -> Bool {
        descriptor.outputRegion == outputRegion
            && descriptor.bytesPerPixel == 4
            && descriptor.pixelFormatRawValue
                == DocumentColorPipeline.interchangePixelFormat.rawValue
    }
}

struct DocumentPaintEncodedPremultipliedBGRA8: Equatable, Sendable {
    let outputRegion: SparseTileOutputRegion
    let pixelSize: PixelSize
    let bytesPerRow: Int
    let bgra8PremultipliedBytes: Data
}

struct DocumentPaintStableCommittedRadialPage: Equatable, Sendable {
    let coordinate: RadialPageCoordinate
    let image: DocumentPaintEncodedPremultipliedBGRA8
}

enum DocumentPaintStableCommittedStorage: Equatable, Sendable {
    case singleRaster(DocumentPaintEncodedPremultipliedBGRA8)
    case radialPages([DocumentPaintStableCommittedRadialPage])
}

struct DocumentPaintStableCommittedCollection: Equatable, Sendable {
    let documentGeneration: UInt64
    let documentPixelSize: PixelSize
    let storagePixelSize: PixelSize
    let storage: DocumentPaintStableCommittedStorage
}

enum DocumentPaintStableCollectionEngine {
    static func collect(
        snapshot: DocumentPaintStableCanonicalSnapshot,
        renderer: DocumentPaintStableSnapshotRenderer,
        descriptor: DocumentPaintTightBGRA8Descriptor,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping
    ) async throws -> DocumentPaintEncodedPremultipliedBGRA8 {
        let collector = try DocumentPaintTightBGRA8Collector(
            descriptor: descriptor
        )
        try await renderer.render(
            DocumentPaintStableSnapshotRenderRequest(
                snapshot: snapshot,
                outputRegion: descriptor.outputRegion,
                outputGeometryRevision: outputGeometryRevision,
                outputMapping: outputMapping
            ),
            to: collector
        )
        return try await collector.result()
    }
}

/// Packed descriptor-sized coverage used by the collector. Its storage never
/// grows with the number or order of chunks.
struct DocumentPaintStablePixelCoverage: Sendable {
    private let pixelCount: Int
    private var words: [UInt64]
    private(set) var coveredPixelCount = 0

    init(pixelCount: Int) throws {
        guard pixelCount >= 0 else {
            throw DocumentPaintStableCollectionError.arithmeticOverflow
        }
        let (roundedCount, overflow) = pixelCount.addingReportingOverflow(63)
        guard !overflow else {
            throw DocumentPaintStableCollectionError.arithmeticOverflow
        }
        self.pixelCount = pixelCount
        words = [UInt64](repeating: 0, count: roundedCount / 64)
    }

    var storageByteCount: Int {
        words.count * MemoryLayout<UInt64>.stride
    }

    func contains(_ index: Int) -> Bool {
        precondition(index >= 0 && index < pixelCount)
        let mask = UInt64(1) << UInt64(index & 63)
        return words[index >> 6] & mask != 0
    }

    mutating func insert(_ index: Int) {
        precondition(index >= 0 && index < pixelCount)
        let wordIndex = index >> 6
        let mask = UInt64(1) << UInt64(index & 63)
        precondition(words[wordIndex] & mask == 0)
        words[wordIndex] |= mask
        coveredPixelCount += 1
    }
}

/// Strict in-memory interchange boundary. The descriptor is checked once
/// before allocation. Each incoming chunk is then accepted or rejected as one
/// indivisible region; accepted bytes are copied directly into their final
/// tight row-major position and are not reinterpreted downstream.
actor DocumentPaintTightBGRA8Collector: DocumentPaintStableSnapshotSink {
    private enum State {
        case idle
        case collecting
        case finished
        case aborted
    }

    private let descriptor: DocumentPaintTightBGRA8Descriptor
    private var state = State.idle
    private var bytes = Data()
    private var coverage: DocumentPaintStablePixelCoverage?

    init(descriptor: DocumentPaintTightBGRA8Descriptor) throws {
        self.descriptor = descriptor
    }

    func begin(
        _ sinkDescriptor: DocumentPaintStableSnapshotSinkDescriptor
    ) throws {
        try Task.checkCancellation()
        switch state {
        case .idle: break
        case .collecting: throw DocumentPaintStableCollectionError.alreadyBegan
        case .finished, .aborted:
            throw DocumentPaintStableCollectionError.alreadyTerminal
        }
        guard descriptor.accepts(sinkDescriptor) else {
            throw DocumentPaintStableCollectionError.descriptorMismatch
        }
        coverage = try DocumentPaintStablePixelCoverage(
            pixelCount: descriptor.pixelCount
        )
        bytes = Data(count: descriptor.byteCount)
        state = .collecting
    }

    func consume(_ chunk: DocumentPaintStableSnapshotChunk) throws {
        try Task.checkCancellation()
        switch state {
        case .collecting: break
        case .idle: throw DocumentPaintStableCollectionError.notCollecting
        case .finished, .aborted:
            throw DocumentPaintStableCollectionError.alreadyTerminal
        }
        let region = chunk.outputRegion
        guard region.minX >= descriptor.outputRegion.minX,
              region.minY >= descriptor.outputRegion.minY,
              region.maxX <= descriptor.outputRegion.maxX,
              region.maxY <= descriptor.outputRegion.maxY
        else {
            throw DocumentPaintStableCollectionError.chunkOutsideOutput(region)
        }
        let (expectedStride, strideOverflow) = region.width
            .multipliedReportingOverflow(by: 4)
        guard !strideOverflow else {
            throw DocumentPaintStableCollectionError.arithmeticOverflow
        }
        guard chunk.bytesPerRow == expectedStride else {
            throw DocumentPaintStableCollectionError.invalidChunkStride(
                expected: expectedStride,
                actual: chunk.bytesPerRow
            )
        }
        let (expectedBytes, byteOverflow) = expectedStride
            .multipliedReportingOverflow(by: region.height)
        guard !byteOverflow else {
            throw DocumentPaintStableCollectionError.arithmeticOverflow
        }
        guard chunk.bytes.count == expectedBytes else {
            throw DocumentPaintStableCollectionError.invalidChunkByteCount(
                expected: expectedBytes,
                actual: chunk.bytes.count
            )
        }
        let destinationX = region.minX - descriptor.outputRegion.minX
        let destinationY = region.minY - descriptor.outputRegion.minY
        guard let coverage else {
            preconditionFailure("collecting without coverage")
        }
        for row in 0..<region.height {
            let pixelOffset = (destinationY + row)
                * descriptor.pixelSize.width + destinationX
            for column in 0..<region.width
            where coverage.contains(pixelOffset + column) {
                throw DocumentPaintStableCollectionError
                    .overlappingChunk(region)
            }
        }

        for row in 0..<region.height {
            let destinationOffset = (destinationY + row)
                * descriptor.bytesPerRow + destinationX * 4
            let sourceOffset = row * expectedStride
            bytes.replaceSubrange(
                destinationOffset..<(destinationOffset + expectedStride),
                with: chunk.bytes[
                    sourceOffset..<(sourceOffset + expectedStride)
                ]
            )
        }
        for row in 0..<region.height {
            let pixelOffset = (destinationY + row)
                * descriptor.pixelSize.width + destinationX
            for column in 0..<region.width {
                self.coverage?.insert(pixelOffset + column)
            }
        }
    }

    func finish() throws {
        try Task.checkCancellation()
        switch state {
        case .collecting: break
        case .idle: throw DocumentPaintStableCollectionError.notCollecting
        case .finished, .aborted:
            throw DocumentPaintStableCollectionError.alreadyTerminal
        }
        let acceptedPixelCount = coverage?.coveredPixelCount ?? 0
        guard acceptedPixelCount == descriptor.pixelCount else {
            throw DocumentPaintStableCollectionError.incompleteCoverage(
                expectedPixels: descriptor.pixelCount,
                actualPixels: acceptedPixelCount
            )
        }
        coverage = nil
        state = .finished
    }

    func abort() {
        switch state {
        case .finished, .aborted: return
        case .idle, .collecting:
            bytes.removeAll(keepingCapacity: false)
            coverage = nil
            state = .aborted
        }
    }

    func result() throws -> DocumentPaintEncodedPremultipliedBGRA8 {
        guard case .finished = state else {
            throw DocumentPaintStableCollectionError.collectionUnavailable
        }
        return DocumentPaintEncodedPremultipliedBGRA8(
            outputRegion: descriptor.outputRegion,
            pixelSize: descriptor.pixelSize,
            bytesPerRow: descriptor.bytesPerRow,
            bgra8PremultipliedBytes: bytes
        )
    }
}
