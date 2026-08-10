import CShaderTypes
import Foundation
import Metal
import PatternEngine

public struct PeriodicRepeatExport: Equatable, Sendable {
    public let pixelSize: PixelSize
    public let bytesPerRow: Int
    public let bgra8Bytes: [UInt8]

    public init(
        pixelSize: PixelSize,
        bytesPerRow: Int,
        bgra8Bytes: [UInt8]
    ) {
        let (expectedBytesPerRow, rowOverflow) = pixelSize.width
            .multipliedReportingOverflow(by: 4)
        let (expectedByteCount, imageOverflow) = expectedBytesPerRow
            .multipliedReportingOverflow(by: pixelSize.height)
        precondition(
            !rowOverflow && !imageOverflow
                && bytesPerRow == expectedBytesPerRow
                && bgra8Bytes.count == expectedByteCount,
            "PeriodicRepeatExport bytes must be tightly packed BGRA8"
        )
        self.pixelSize = pixelSize
        self.bytesPerRow = bytesPerRow
        self.bgra8Bytes = bgra8Bytes
    }
}

public enum PeriodicRepeatExportError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case unsupportedPreset(SymmetryPresetID)
    case invalidDensity(Int)
    case derivedDimensionOutOfRange(width: Int, height: Int)
    case byteCountOverflow

    public var errorDescription: String? {
        switch self {
        case let .unsupportedPreset(preset):
            "Preset \(preset.rawValue) does not expose a metric repeat export."
        case let .invalidDensity(density):
            "Repeat-export density \(density) is outside 64...4096."
        case let .derivedDimensionOutOfRange(width, height):
            "Repeat-export dimensions \(width)x\(height) are outside 64...4096."
        case .byteCountOverflow:
            "Repeat-export storage size overflowed."
        }
    }
}

struct DocumentPaintStableMetricRepeatPlan: Sendable {
    let pixelSize: PixelSize
    let outputMapping: SparseTileSamplingOutputMapping

    init(strategy: TilingStrategy, density: Int) throws {
        guard strategy.presetID.supportsMetricRepeatExport else {
            throw PeriodicRepeatExportError.unsupportedPreset(
                strategy.presetID
            )
        }
        guard (64...4_096).contains(density) else {
            throw PeriodicRepeatExportError.invalidDensity(density)
        }
        guard let periodic = strategy.compiledSymmetry.domain.periodic else {
            throw PeriodicRepeatExportError.unsupportedPreset(
                strategy.presetID
            )
        }
        let height: Int
        if strategy.compiledSymmetry.family == .triangular {
            let horizontal = Double(simd_length(
                periodic.translationBasis.u
            ))
            let vertical = Double(simd_length(
                periodic.translationBasis.v
            ))
            let derived = Double(density) * vertical / horizontal
            guard derived.isFinite, derived <= Double(Int.max) else {
                throw PeriodicRepeatExportError.byteCountOverflow
            }
            height = Int(derived.rounded())
        } else {
            height = density
        }
        guard (64...8_192).contains(height) else {
            throw PeriodicRepeatExportError.derivedDimensionOutOfRange(
                width: density,
                height: height
            )
        }
        pixelSize = PixelSize(width: density, height: height)
        outputMapping = .affine(SparseTileOutputToSourceTransform(
            sourceOffset: .zero,
            sourceStep: SIMD2(
                Float(strategy.canvasSize.width) / Float(density),
                Float(strategy.canvasSize.height) / Float(height)
            )
        ))
    }
}

extension PeriodicRepeatExport {
    static func collectStableMetric(
        strategy: TilingStrategy,
        density: Int,
        snapshot: DocumentPaintStableCanonicalSnapshot,
        renderer: DocumentPaintStableSnapshotRenderer,
        outputGeometryRevision: UInt64
    ) async throws -> PeriodicRepeatExport {
        defer { snapshot.close() }
        let plan = try DocumentPaintStableMetricRepeatPlan(
            strategy: strategy,
            density: density
        )
        let image = try await DocumentPaintStableExportAdapter.collect(
            snapshot: snapshot,
            renderer: renderer,
            outputRegion: try DocumentPaintStableExportAdapter.outputRegion(
                pixelSize: plan.pixelSize
            ),
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: plan.outputMapping
        )
        return PeriodicRepeatExport(
            pixelSize: plan.pixelSize,
            bytesPerRow: image.bytesPerRow,
            bgra8Bytes: [UInt8](image.bgra8PremultipliedBytes)
        )
    }
}
