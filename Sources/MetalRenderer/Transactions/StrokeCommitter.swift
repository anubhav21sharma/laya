import PatternEngine

/// Bridges a sealed transient stroke into the canonical sparse document and
/// returns the history-bearing application result to the facade.
enum StrokeCommitter {
    static func parameters(
        mode: StrokeCompositeMode,
        strokeOpacity: Float,
        eraserStrength: Float
    ) -> DocumentPaintStrokeCompositeParameters {
        DocumentPaintStrokeCompositeParameters(
            mode: mode,
            strokeOpacity: strokeOpacity,
            accumulationLimit: 1,
            eraserStrength: mode == .erase ? eraserStrength : 1
        )
    }

    static func commit(
        _ mutation: StrokePreparedCommitMutation,
        context: DocumentPaintRenderContext,
        capability: DocumentPaintStrokeSurfaceCapability?,
        parameters: DocumentPaintStrokeCompositeParameters
    ) async throws -> DocumentPaintSurfaceApplicationResult {
        switch mutation {
        case let .source(source):
            return try await context.commitStroke(
                source,
                compositeParameters: parameters
            )
        case .noOp:
            guard let capability, capability.isTerminal else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            return DocumentPaintSurfaceApplicationResult(
                didPublish: false,
                layerID: capability.layerID,
                generation: capability.generation,
                historyPair: nil
            )
        }
    }
}
