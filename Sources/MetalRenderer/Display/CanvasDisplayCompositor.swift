import CShaderTypes
import Foundation
import PatternEngine

/// Owns the policy and preparation step for presenting canonical paint plus
/// the active transient stroke. `GridRenderer` retains only MTKView scheduling
/// and the final drawable submission.
enum CanvasDisplayCompositor {
    static func prepare(
        context: DocumentPaintRenderContext,
        outputPixelSize: PixelSize,
        viewport: ViewportTransform,
        tilingStrategy: TilingStrategy,
        storagePixelSize: PixelSize,
        geometryRevision: UInt64,
        transient: DocumentPaintTransientDisplaySource?,
        transientMode: StrokeCompositeMode?,
        strokeOpacity: Float,
        eraserStrength: Float,
        showGridLines: Bool
    ) async throws -> PreparedLayerCompositeDisplaySubmission {
        let outputRegion = try SparseTileOutputRegion(
            minX: 0,
            minY: 0,
            maxX: outputPixelSize.width,
            maxY: outputPixelSize.height
        )
        let outputMapping = try outputMapping(
            viewport: viewport,
            tilingStrategy: tilingStrategy,
            outputPixelSize: outputPixelSize
        )
        return try await context.prepareLayerDisplaySubmission(
            transient: transient,
            addressing: addressing(
                tilingStrategy: tilingStrategy,
                storagePixelSize: storagePixelSize
            ),
            addressingRevision: geometryRevision,
            outputRegion: outputRegion,
            outputGeometryRevision: geometryRevision,
            outputMapping: outputMapping,
            parameters: parameters(
                outputMapping: outputMapping,
                transientMode: transientMode,
                strokeOpacity: strokeOpacity,
                eraserStrength: eraserStrength,
                showGridLines: showGridLines
            )
        )
    }

    static func parameters(
        outputMapping: SparseTileSamplingOutputMapping,
        transientMode: StrokeCompositeMode?,
        strokeOpacity: Float,
        eraserStrength: Float,
        showGridLines: Bool
    ) -> SparseTileSamplingEncodeParameters {
        guard let transientMode else {
            return SparseTileSamplingEncodeParameters(
                outputMapping: outputMapping,
                compositeMode: PatternCompositeWireDraw,
                liveVisible: false,
                strokeOpacity: 1,
                accumulationLimit: 1,
                eraserStrength: 1,
                showGridLines: showGridLines,
                showCanvasBoundary: true
            )
        }
        return SparseTileSamplingEncodeParameters(
            outputMapping: outputMapping,
            compositeMode: transientMode.rawValue,
            liveVisible: true,
            strokeOpacity: strokeOpacity,
            // Each native component applies its own authored accumulation
            // limit. A root clamp would make component zero control the union.
            accumulationLimit: 1,
            eraserStrength: transientMode == .erase ? eraserStrength : 1,
            showGridLines: showGridLines,
            showCanvasBoundary: true
        )
    }

    static func addressing(
        tilingStrategy: TilingStrategy,
        storagePixelSize: PixelSize
    ) -> SparseTileAddressing {
        if let layout = tilingStrategy.compiledSymmetry.domain.finite?.radial
            .layout
        {
            return .radial(layout: layout)
        }
        switch tilingStrategy.documentConfiguration {
        case .periodic:
            return .periodic(period: storagePixelSize)
        case .finite:
            return .finite(storagePixelSize)
        }
    }

    private static func outputMapping(
        viewport: ViewportTransform,
        tilingStrategy: TilingStrategy,
        outputPixelSize: PixelSize
    ) throws -> SparseTileSamplingOutputMapping {
        let inverseZoom = 1 / viewport.zoom
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: viewport.worldCenter.simd - SIMD2(
                Float(outputPixelSize.width) * 0.5 * inverseZoom,
                Float(outputPixelSize.height) * 0.5 * inverseZoom
            ),
            sourceStep: SIMD2(repeating: inverseZoom)
        )
        if tilingStrategy.compiledSymmetry.domain.finite?.radial.layout != nil {
            return try .finiteRadial(
                strategy: tilingStrategy,
                outputToWorldTransform: transform
            )
        }
        return .affine(transform)
    }
}
