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
func gridUniformAndProjectedStampLayoutsMatchTheMetalContract() {
    #expect(MemoryLayout<PatternGridFrameUniforms>.size == 48)
    #expect(MemoryLayout<PatternGridFrameUniforms>.stride == 48)
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

    #expect(MemoryLayout<PatternClipHalfPlane>.size == 16)
    #expect(MemoryLayout<PatternClipHalfPlane>.stride == 16)
    #expect(MemoryLayout<PatternClipHalfPlane>.alignment == 8)
    #expect(MemoryLayout<PatternClipHalfPlane>.offset(of: \.normal) == 0)
    #expect(MemoryLayout<PatternClipHalfPlane>.offset(of: \.offset) == 8)
    #expect(MemoryLayout<PatternClipHalfPlane>.offset(of: \.padding) == 12)

    #expect(MemoryLayout<PatternProjectedStampInstance>.size == 96)
    #expect(MemoryLayout<PatternProjectedStampInstance>.stride == 96)
    #expect(MemoryLayout<PatternProjectedStampInstance>.alignment == 8)
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
        MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip0)
            == 32
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip1)
            == 48
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip2)
            == 64
    )
    #expect(
        MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip3)
            == 80
    )
    #expect(ShaderABI.isValid)
}

@Test
func gridWireIndicesAppendWithoutRenumberingSliceZero() {
    #expect(PatternBufferIndexFrameUniforms == 0)
    #expect(PatternBufferIndexGridFrameUniforms == 1)
    #expect(PatternBufferIndexDabInstances == 2)
    #expect(PatternTextureIndexCanonical == 0)
    #expect(PatternTextureIndexLive == 1)
}
