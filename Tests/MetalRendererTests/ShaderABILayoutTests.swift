import CShaderTypes
import MetalRenderer
import Testing

@Test
func frameUniformLayoutMatchesTheMetalContract() {
    #expect(MemoryLayout<PatternFrameUniforms>.size == 16)
    #expect(MemoryLayout<PatternFrameUniforms>.stride == 16)
    #expect(MemoryLayout<PatternFrameUniforms>.alignment == 8)
    #expect(MemoryLayout<PatternFrameUniforms>.offset(of: \.drawableSize) == 0)
    #expect(MemoryLayout<PatternFrameUniforms>.offset(of: \.inverseDrawableSize) == 8)
    #expect(ShaderABI.isValid)
}

@Test
func tilingWireValuesAreAppendOnly() {
    #expect(PatternTilingWireGrid == 0)
    #expect(PatternTilingWireHalfDrop == 1)
    #expect(PatternTilingWireBrick == 2)
    #expect(PatternTilingWireMirrorX == 3)
    #expect(PatternTilingWireMirrorY == 4)
    #expect(PatternTilingWireMirrorXY == 5)
    #expect(PatternTilingWireRotational == 6)
}

@Test
func diagnosticWireValuesAreAppendOnly() {
    #expect(PatternDiagnosticWireNone == 0)
    #expect(PatternDiagnosticWireAsymmetricCoverage == 1)
    #expect(PatternDiagnosticWireCanonicalCoordinates == 2)
    #expect(PatternDiagnosticWireBrushLocalCoordinates == 3)
}

@Test
func compositeWireValuesAreAppendOnly() {
    #expect(PatternCompositeWireDraw == 0)
    #expect(PatternCompositeWireErase == 1)
}

@Test
func gridUniformAndProjectedStampLayoutsMatchTheMetalContract() {
    #expect(MemoryLayout<PatternGridFrameUniforms>.size == 56)
    #expect(MemoryLayout<PatternGridFrameUniforms>.stride == 56)
    #expect(MemoryLayout<PatternGridFrameUniforms>.alignment == 8)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.drawableSize) == 0)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.worldCenter) == 8)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.tileSize) == 16)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.zoom) == 24)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.gridLineWidth) == 28)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.showGridLines) == 32)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.liveVisible) == 36)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.tilingKind) == 40)
    #expect(
        MemoryLayout<PatternGridFrameUniforms>.offset(of: \.diagnosticMode)
            == 44
    )
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.compositeMode) == 48)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.padding) == 52)

    #expect(MemoryLayout<PatternClipHalfPlane>.size == 16)
    #expect(MemoryLayout<PatternClipHalfPlane>.stride == 16)
    #expect(MemoryLayout<PatternClipHalfPlane>.alignment == 8)
    #expect(MemoryLayout<PatternClipHalfPlane>.offset(of: \.normal) == 0)
    #expect(MemoryLayout<PatternClipHalfPlane>.offset(of: \.offset) == 8)
    #expect(MemoryLayout<PatternClipHalfPlane>.offset(of: \.padding) == 12)

    #expect(MemoryLayout<PatternProjectedStampInstance>.size == 128)
    #expect(MemoryLayout<PatternProjectedStampInstance>.stride == 128)
    #expect(MemoryLayout<PatternProjectedStampInstance>.alignment == 16)
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(
            of: \.canonicalXAxis
        ) == 0
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(
            of: \.canonicalYAxis
        ) == 8
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(
            of: \.canonicalTranslation
        ) == 16
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(of: \.radius)
            == 24
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clipCount)
            == 28
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(of: \.color)
            == 32
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip0)
            == 48
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip1)
            == 64
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip2)
            == 80
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip3)
            == 96
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(
            of: \.brushAttributes
        ) == 112
    )

    #expect(MemoryLayout<PatternBrushMaterialUniforms>.size == 48)
    #expect(MemoryLayout<PatternBrushMaterialUniforms>.stride == 48)
    #expect(MemoryLayout<PatternBrushMaterialUniforms>.alignment == 4)
    #expect(
        MemoryLayout<PatternBrushMaterialUniforms>.offset(of: \.materialFamily)
            == 0
    )
    #expect(
        MemoryLayout<PatternBrushMaterialUniforms>.offset(
            of: \.grainCoordinateMode
        ) == 4
    )
    #expect(
        MemoryLayout<PatternBrushMaterialUniforms>.offset(of: \.strokeOpacity)
            == 8
    )
    #expect(
        MemoryLayout<PatternBrushMaterialUniforms>.offset(of: \.materialStrength)
            == 12
    )
    #expect(MemoryLayout<PatternBrushMaterialUniforms>.offset(of: \.wetness) == 16)
    #expect(
        MemoryLayout<PatternBrushMaterialUniforms>.offset(of: \.bleedRadius)
            == 20
    )
    #expect(
        MemoryLayout<PatternBrushMaterialUniforms>.offset(of: \.softenPasses)
            == 24
    )
    #expect(
        MemoryLayout<PatternBrushMaterialUniforms>.offset(
            of: \.accumulationLimit
        ) == 28
    )
    #expect(
        MemoryLayout<PatternBrushMaterialUniforms>.offset(of: \.shapeKind)
            == 32
    )
    #expect(
        MemoryLayout<PatternBrushMaterialUniforms>.offset(of: \.grainKind)
            == 36
    )
    #expect(
        MemoryLayout<PatternBrushMaterialUniforms>.offset(of: \.grainRotation)
            == 40
    )
    #expect(
        MemoryLayout<PatternBrushMaterialUniforms>.offset(of: \.padding1)
            == 44
    )
    #expect(ShaderABI.isValid)
}

@Test
func gridWireIndicesAppendWithoutRenumberingSliceZero() {
    #expect(PatternBufferIndexFrameUniforms == 0)
    #expect(PatternBufferIndexGridFrameUniforms == 1)
    #expect(PatternBufferIndexDabInstances == 2)
    #expect(PatternBufferIndexBrushMaterial == 3)
    #expect(PatternTextureIndexCanonical == 0)
    #expect(PatternTextureIndexLive == 1)
    #expect(PatternTextureIndexBrushShape == 2)
    #expect(PatternTextureIndexBrushGrain == 3)
    #expect(PatternTextureIndexReplayLive == 4)
}
