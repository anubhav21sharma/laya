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
func gridUniformAndDabLayoutsMatchTheMetalContract() {
    #expect(MemoryLayout<PatternGridFrameUniforms>.size == 40)
    #expect(MemoryLayout<PatternGridFrameUniforms>.stride == 40)
    #expect(MemoryLayout<PatternGridFrameUniforms>.alignment == 8)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.drawableSize) == 0)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.worldCenter) == 8)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.tileSize) == 16)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.zoom) == 24)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.gridLineWidth) == 28)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.showGridLines) == 32)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.liveVisible) == 36)

    #expect(MemoryLayout<PatternDabInstance>.size == 16)
    #expect(MemoryLayout<PatternDabInstance>.stride == 16)
    #expect(MemoryLayout<PatternDabInstance>.alignment == 8)
    #expect(MemoryLayout<PatternDabInstance>.offset(of: \.center) == 0)
    #expect(MemoryLayout<PatternDabInstance>.offset(of: \.radius) == 8)
    #expect(MemoryLayout<PatternDabInstance>.offset(of: \.padding) == 12)
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
