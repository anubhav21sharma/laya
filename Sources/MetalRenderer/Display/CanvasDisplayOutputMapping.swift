import PatternEngine

enum CanvasDisplayOutputMapping {
    static func make(
        viewport: ViewportTransform,
        strategy: TilingStrategy,
        outputPixelSize: PixelSize
    ) throws -> SparseTileSamplingOutputMapping {
        let inverseZoom = 1 / viewport.zoom
        let outputToWorld = SparseTileOutputToSourceTransform(
            sourceOffset: viewport.worldCenter.simd - SIMD2(
                Float(outputPixelSize.width) * 0.5 * inverseZoom,
                Float(outputPixelSize.height) * 0.5 * inverseZoom
            ),
            sourceStep: SIMD2(repeating: inverseZoom)
        )
        if strategy.compiledSymmetry.domain.finite?.radial.layout != nil {
            return try .finiteRadial(
                strategy: strategy,
                outputToWorldTransform: outputToWorld
            )
        }
        if let fold = strategy.compiledSymmetry.domain.periodic?.displayFold {
            return .periodic(SparseTilePeriodicOutputMapping(
                fold: fold,
                outputToWorldTransform: outputToWorld
            ))
        }
        return .affine(outputToWorld)
    }
}
