import Foundation
import Metal
import PatternEngine

public struct FlattenedSceneExport: Equatable, Sendable {
    public let pixelSize: PixelSize
    public let bytesPerRow: Int
    public let bgra8Bytes: [UInt8]
    public let hasTransparentBackground: Bool

    public init(
        pixelSize: PixelSize,
        bytesPerRow: Int,
        bgra8Bytes: [UInt8],
        hasTransparentBackground: Bool
    ) {
        precondition(bytesPerRow == pixelSize.width * 4)
        precondition(bgra8Bytes.count == bytesPerRow * pixelSize.height)
        self.pixelSize = pixelSize
        self.bytesPerRow = bytesPerRow
        self.bgra8Bytes = bgra8Bytes
        self.hasTransparentBackground = hasTransparentBackground
    }
}

public enum FlattenedSceneExportError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidDimensions(width: Int, height: Int)
    case byteCountOverflow

    public var errorDescription: String? {
        switch self {
        case let .invalidDimensions(width, height):
            "Scene dimensions \(width)x\(height) are outside 64...4096."
        case .byteCountOverflow:
            "Flattened-scene storage size overflowed."
        }
    }
}

struct DocumentPaintStableFlattenedOutputRequest: Sendable {
    let pixelSize: PixelSize
    let outputMapping: SparseTileSamplingOutputMapping
    let transparentBackground: Bool

    init(
        pixelSize: PixelSize,
        outputMapping: SparseTileSamplingOutputMapping,
        transparentBackground: Bool
    ) throws {
        guard (64...4_096).contains(pixelSize.width),
              (64...4_096).contains(pixelSize.height)
        else {
            throw FlattenedSceneExportError.invalidDimensions(
                width: pixelSize.width,
                height: pixelSize.height
            )
        }
        let (bytesPerRow, rowOverflow) = pixelSize.width
            .multipliedReportingOverflow(by: 4)
        let (_, byteOverflow) = bytesPerRow
            .multipliedReportingOverflow(by: pixelSize.height)
        guard !rowOverflow, !byteOverflow else {
            throw FlattenedSceneExportError.byteCountOverflow
        }
        self.pixelSize = pixelSize
        self.outputMapping = outputMapping
        self.transparentBackground = transparentBackground
    }
}

extension FlattenedSceneExport {
    static func collectStable(
        request: DocumentPaintStableFlattenedOutputRequest,
        snapshot: DocumentPaintStableCanonicalSnapshot,
        renderer: DocumentPaintStableSnapshotRenderer,
        outputGeometryRevision: UInt64
    ) async throws -> FlattenedSceneExport {
        defer { snapshot.close() }
        let image = try await DocumentPaintStableExportAdapter.collect(
            snapshot: snapshot,
            renderer: renderer,
            outputRegion: try DocumentPaintStableExportAdapter.outputRegion(
                pixelSize: request.pixelSize
            ),
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: request.outputMapping
        )
        return FlattenedSceneExport(
            pixelSize: request.pixelSize,
            bytesPerRow: image.bytesPerRow,
            bgra8Bytes: try DocumentPaintStableExportAdapter.destinationBytes(
                image,
                transparentBackground: request.transparentBackground
            ),
            hasTransparentBackground: request.transparentBackground
        )
    }
}
