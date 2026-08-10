import Foundation
import Metal
import PatternEngine

public enum PeriodicBakedRepeatExportError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case finiteDocument
    case byteCountOverflow
    case inconsistentPeriodicPreset

    public var errorDescription: String? {
        switch self {
        case .finiteDocument:
            "A baked repeat is available only for periodic documents."
        case .byteCountOverflow:
            "Baked-repeat storage size overflowed."
        case .inconsistentPeriodicPreset:
            "The compiled periodic preset has inconsistent export capabilities."
        }
    }
}

struct DocumentPaintStableBakedPiece {
    let outputRegion: SparseTileOutputRegion
    let outputMapping: SparseTileSamplingOutputMapping
}

struct DocumentPaintStableBakedPlan {
    let pixelSize: PixelSize
    let pieces: [DocumentPaintStableBakedPiece]

    init(strategy: TilingStrategy) throws {
        guard case .periodic = strategy.documentConfiguration else {
            throw PeriodicBakedRepeatExportError.finiteDocument
        }
        let multiplier: (width: Int, height: Int)
        switch strategy.presetID {
        case .halfDrop, .mirrorX:
            multiplier = (2, 1)
        case .brick, .mirrorY:
            multiplier = (1, 2)
        case .mirrorXY:
            multiplier = (2, 2)
        case .grid, .rotational:
            multiplier = (1, 1)
        case .squareRotation, .squareKaleidoscope, .hexagons,
             .rotation3, .rotation6, .kaleidoscope60, .kaleidoscope30:
            throw PeriodicBakedRepeatExportError.inconsistentPeriodicPreset
        case .plainCanvas, .radialMirror, .radialRotation, .radialMandala:
            throw PeriodicBakedRepeatExportError.finiteDocument
        }
        let sourceSize = strategy.canvasSize
        let (width, widthOverflow) = sourceSize.width
            .multipliedReportingOverflow(by: multiplier.width)
        let (height, heightOverflow) = sourceSize.height
            .multipliedReportingOverflow(by: multiplier.height)
        guard !widthOverflow, !heightOverflow else {
            throw PeriodicBakedRepeatExportError.byteCountOverflow
        }
        pixelSize = PixelSize(width: width, height: height)

        var result: [DocumentPaintStableBakedPiece] = []
        result.reserveCapacity(multiplier.width * multiplier.height)
        for row in 0..<multiplier.height {
            for column in 0..<multiplier.width {
                let minX = column * sourceSize.width
                let minY = row * sourceSize.height
                let region = try SparseTileOutputRegion(
                    minX: minX,
                    minY: minY,
                    maxX: minX + sourceSize.width,
                    maxY: minY + sourceSize.height
                )
                let first = strategy.displayFold(WorldPoint(
                    x: Float(minX) + 0.5,
                    y: Float(minY) + 0.5
                ))
                let nextX = strategy.displayFold(WorldPoint(
                    x: Float(minX) + 1.5,
                    y: Float(minY) + 0.5
                ))
                let nextY = strategy.displayFold(WorldPoint(
                    x: Float(minX) + 0.5,
                    y: Float(minY) + 1.5
                ))
                let step = SIMD2(
                    nextX.x - first.x,
                    nextY.y - first.y
                )
                guard abs(nextX.y - first.y) <= 0.0001,
                      abs(nextY.x - first.x) <= 0.0001,
                      abs(abs(step.x) - 1) <= 0.0001,
                      abs(abs(step.y) - 1) <= 0.0001
                else {
                    throw PeriodicBakedRepeatExportError
                        .inconsistentPeriodicPreset
                }
                let offset = SIMD2(
                    first.x - Float(minX) - 0.5 * step.x,
                    first.y - Float(minY) - 0.5 * step.y
                )
                result.append(DocumentPaintStableBakedPiece(
                    outputRegion: region,
                    outputMapping: .affine(
                        SparseTileOutputToSourceTransform(
                            sourceOffset: offset,
                            sourceStep: step
                        )
                    )
                ))
            }
        }
        pieces = result
    }
}

extension PeriodicRepeatExport {
    static func collectStableBaked(
        strategy: TilingStrategy,
        snapshot: DocumentPaintStableCanonicalSnapshot,
        renderer: DocumentPaintStableSnapshotRenderer,
        outputGeometryRevision: UInt64
    ) async throws -> PeriodicRepeatExport {
        defer { snapshot.close() }
        guard case .periodic = strategy.documentConfiguration else {
            throw PeriodicBakedRepeatExportError.finiteDocument
        }
        if strategy.presetID.supportsMetricRepeatExport {
            let metric = try DocumentPaintStableMetricRepeatPlan(
                strategy: strategy,
                density: strategy.canvasSize.width
            )
            let image = try await DocumentPaintStableExportAdapter.collect(
                snapshot: snapshot,
                renderer: renderer,
                outputRegion: try DocumentPaintStableExportAdapter.outputRegion(
                    pixelSize: metric.pixelSize
                ),
                outputGeometryRevision: outputGeometryRevision,
                outputMapping: metric.outputMapping
            )
            return PeriodicRepeatExport(
                pixelSize: metric.pixelSize,
                bytesPerRow: image.bytesPerRow,
                bgra8Bytes: [UInt8](image.bgra8PremultipliedBytes)
            )
        }

        let plan = try DocumentPaintStableBakedPlan(strategy: strategy)
        let fullRegion = try DocumentPaintStableExportAdapter.outputRegion(
            pixelSize: plan.pixelSize
        )
        let destination = try DocumentPaintTightBGRA8Descriptor(
            outputRegion: fullRegion,
            maximumByteCount:
                DocumentPaintStableExportAdapter.limits.maximumOutputBytes
        )
        try DocumentPaintStableSnapshotChunkPlanner.validateOutput(
            fullRegion,
            limits: DocumentPaintStableExportAdapter.limits
        )
        var bytes = [UInt8](repeating: 0, count: destination.byteCount)
        for piece in plan.pieces {
            try Task.checkCancellation()
            let image = try await DocumentPaintStableExportAdapter.collect(
                snapshot: snapshot,
                renderer: renderer,
                outputRegion: piece.outputRegion,
                outputGeometryRevision: outputGeometryRevision,
                outputMapping: piece.outputMapping
            )
            for row in 0..<piece.outputRegion.height {
                let sourceOffset = row * image.bytesPerRow
                let destinationOffset = (piece.outputRegion.minY + row)
                    * destination.bytesPerRow
                    + piece.outputRegion.minX * 4
                bytes.replaceSubrange(
                    destinationOffset..<(destinationOffset + image.bytesPerRow),
                    with: image.bgra8PremultipliedBytes[
                        sourceOffset..<(sourceOffset + image.bytesPerRow)
                    ]
                )
            }
        }
        return PeriodicRepeatExport(
            pixelSize: plan.pixelSize,
            bytesPerRow: destination.bytesPerRow,
            bgra8Bytes: bytes
        )
    }
}
