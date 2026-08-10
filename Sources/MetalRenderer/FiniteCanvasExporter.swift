import Foundation
import Metal
import PatternEngine

public struct FiniteCanvasExport: Equatable, Sendable {
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

public enum FiniteCanvasExportError: Error, Equatable, LocalizedError, Sendable {
    case periodicDocument
    case byteCountOverflow

    public var errorDescription: String? {
        switch self {
        case .periodicDocument:
            "Full-canvas finite export requires a finite document."
        case .byteCountOverflow:
            "Finite export storage size overflowed."
        }
    }
}

extension FiniteCanvasExport {
    static func collectStable(
        strategy: TilingStrategy,
        snapshot: DocumentPaintStableCanonicalSnapshot,
        renderer: DocumentPaintStableSnapshotRenderer,
        outputGeometryRevision: UInt64,
        transparentBackground: Bool
    ) async throws -> FiniteCanvasExport {
        defer { snapshot.close() }
        guard case .finite = strategy.documentConfiguration else {
            throw FiniteCanvasExportError.periodicDocument
        }
        let pixelSize = strategy.canvasSize
        let outputMapping: SparseTileSamplingOutputMapping
        if strategy.compiledSymmetry.domain.finite?.radial.layout != nil {
            outputMapping = try .finiteRadial(strategy: strategy)
        } else {
            outputMapping = .affine(.identity)
        }
        let image = try await DocumentPaintStableExportAdapter.collect(
            snapshot: snapshot,
            renderer: renderer,
            outputRegion: try DocumentPaintStableExportAdapter.outputRegion(
                pixelSize: pixelSize
            ),
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: outputMapping
        )
        return FiniteCanvasExport(
            pixelSize: pixelSize,
            bytesPerRow: image.bytesPerRow,
            bgra8Bytes: try DocumentPaintStableExportAdapter.destinationBytes(
                image,
                transparentBackground: transparentBackground
            ),
            hasTransparentBackground: transparentBackground
        )
    }
}
