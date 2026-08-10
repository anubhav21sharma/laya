import Foundation
import Metal
import PatternEngine

public struct CommittedRadialPagePixels: Equatable, Sendable {
    public let coordinate: RadialPageCoordinate
    public let bgra8PremultipliedBytes: [UInt8]

    public init(
        coordinate: RadialPageCoordinate,
        bgra8PremultipliedBytes: [UInt8]
    ) {
        self.coordinate = coordinate
        self.bgra8PremultipliedBytes = bgra8PremultipliedBytes
    }
}

public enum CommittedRasterStorage: Equatable, Sendable {
    case singleRaster(bgra8PremultipliedBytes: [UInt8])
    case radialPages([CommittedRadialPagePixels])
}

public struct CommittedDocumentSnapshot: Equatable, Sendable {
    public let canvasSize: PixelSize
    public let documentConfiguration: SymmetryDocumentConfiguration
    public let documentDomainLocked: Bool
    public let radialGeometryLocked: Bool
    public let storage: CommittedRasterStorage

    public init(
        canvasSize: PixelSize,
        documentConfiguration: SymmetryDocumentConfiguration,
        documentDomainLocked: Bool? = nil,
        radialGeometryLocked: Bool,
        storage: CommittedRasterStorage
    ) {
        self.canvasSize = canvasSize
        self.documentConfiguration = documentConfiguration
        self.documentDomainLocked = documentDomainLocked
            ?? (radialGeometryLocked || storage.containsNonzeroBytes)
        self.radialGeometryLocked = radialGeometryLocked
        self.storage = storage
    }
}

private extension CommittedRasterStorage {
    var containsNonzeroBytes: Bool {
        switch self {
        case let .singleRaster(bytes):
            bytes.contains(where: { $0 != 0 })
        case let .radialPages(pages):
            pages.contains {
                $0.bgra8PremultipliedBytes.contains(where: { $0 != 0 })
            }
        }
    }
}

enum DocumentPaintStableExportAdapter {
    static let limits = DocumentPaintStableSnapshotRendererLimits.production

    static func outputRegion(
        pixelSize: PixelSize
    ) throws -> SparseTileOutputRegion {
        try SparseTileOutputRegion(
            minX: 0,
            minY: 0,
            maxX: pixelSize.width,
            maxY: pixelSize.height
        )
    }

    static func collect(
        snapshot: DocumentPaintStableCanonicalSnapshot,
        renderer: DocumentPaintStableSnapshotRenderer,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping
    ) async throws -> DocumentPaintEncodedPremultipliedBGRA8 {
        try DocumentPaintStableSnapshotChunkPlanner.validateOutput(
            outputRegion,
            limits: limits
        )
        return try await DocumentPaintStableCollectionEngine.collect(
            snapshot: snapshot,
            renderer: renderer,
            descriptor: try DocumentPaintTightBGRA8Descriptor(
                outputRegion: outputRegion,
                maximumByteCount: limits.maximumOutputBytes
            ),
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: outputMapping
        )
    }

    static func destinationBytes(
        _ image: DocumentPaintEncodedPremultipliedBGRA8,
        transparentBackground: Bool
    ) throws -> [UInt8] {
        try Task.checkCancellation()
        var bytes = [UInt8](image.bgra8PremultipliedBytes)
        guard !transparentBackground else { return bytes }
        let paper = GridCanvasContract.paperLinearPremultiplied
        for rowStart in stride(
            from: 0,
            to: bytes.count,
            by: image.bytesPerRow
        ) {
            try Task.checkCancellation()
            for offset in stride(
                from: rowStart,
                to: rowStart + image.bytesPerRow,
                by: 4
            ) {
                let source = DocumentColorPipeline
                    .importEncodedPremultipliedBGRA8(
                        EncodedPremultipliedBGRA8(
                            blue: bytes[offset],
                            green: bytes[offset + 1],
                            red: bytes[offset + 2],
                            alpha: bytes[offset + 3]
                        )
                    )
                let output = DocumentColorPipeline
                    .exportEncodedPremultipliedBGRA8(
                        DocumentColorPipeline.referenceSourceOver(
                            source: source,
                            destination: paper
                        )
                    )
                bytes[offset] = output.blue
                bytes[offset + 1] = output.green
                bytes[offset + 2] = output.red
                bytes[offset + 3] = output.alpha
            }
        }
        return bytes
    }
}

extension CommittedDocumentSnapshot {
    static func collectStable(
        canvasSize: PixelSize,
        documentConfiguration: SymmetryDocumentConfiguration,
        documentDomainLocked: Bool,
        radialGeometryLocked: Bool,
        capture: DocumentPaintStableCommittedCapture,
        renderer: DocumentPaintStableSnapshotRenderer,
        outputGeometryRevision: UInt64
    ) async throws -> CommittedDocumentSnapshot {
        defer { capture.close() }
        let collected = try await DocumentPaintStableCollectionEngine
            .collectCommitted(
                capture,
                renderer: renderer,
                outputGeometryRevision: outputGeometryRevision
            )
        guard collected.documentPixelSize == canvasSize else {
            throw MetalRendererError.committedSnapshotIncompatible
        }
        let strategy: TilingStrategy
        do {
            strategy = try TilingStrategy(
                documentConfiguration: documentConfiguration,
                canvasSize: canvasSize
            )
        } catch {
            throw MetalRendererError.committedSnapshotIncompatible
        }
        let expectedStorageSize = PixelSize(
            width: Int(strategy.tileSize.width),
            height: Int(strategy.tileSize.height)
        )
        guard collected.storagePixelSize == expectedStorageSize else {
            throw MetalRendererError.committedSnapshotIncompatible
        }

        let storage: CommittedRasterStorage
        try Task.checkCancellation()
        let radialLayout = strategy.compiledSymmetry.domain.finite?
            .radial.layout
        switch (collected.storage, radialLayout) {
        case let (.singleRaster(image), nil):
            storage = .singleRaster(
                bgra8PremultipliedBytes: [UInt8](
                    image.bgra8PremultipliedBytes
                )
            )
        case let (.radialPages(pages), .some):
            storage = .radialPages(pages.map {
                CommittedRadialPagePixels(
                    coordinate: $0.coordinate,
                    bgra8PremultipliedBytes: [UInt8](
                        $0.image.bgra8PremultipliedBytes
                    )
                )
            }.sorted { $0.coordinate < $1.coordinate })
        default:
            throw MetalRendererError.committedSnapshotIncompatible
        }
        return CommittedDocumentSnapshot(
            canvasSize: canvasSize,
            documentConfiguration: documentConfiguration,
            documentDomainLocked: documentDomainLocked,
            radialGeometryLocked: radialGeometryLocked,
            storage: storage
        )
    }
}
