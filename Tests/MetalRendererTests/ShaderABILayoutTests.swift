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
    #expect(PatternTilingWireSquareRotation == 7)
    #expect(PatternTilingWireSquareKaleidoscope == 8)
    #expect(PatternTilingWireHexagons == 9)
    #expect(PatternTilingWireRotation3 == 10)
    #expect(PatternTilingWireRotation6 == 11)
    #expect(PatternTilingWireKaleidoscope60 == 12)
    #expect(PatternTilingWireKaleidoscope30 == 13)
    #expect(PatternTilingWirePlainCanvas == 14)
    #expect(PatternTilingWireRadialMirror == 15)
    #expect(PatternTilingWireRadialRotation == 16)
    #expect(PatternTilingWireRadialMandala == 17)
}

@Test
func guideWireValuesAreAppendOnly() {
    #expect(PatternGuideWireRectangular == 0)
    #expect(PatternGuideWireSquareRotation == 1)
    #expect(PatternGuideWireSquareKaleidoscope == 2)
    #expect(PatternGuideWireHexagons == 3)
    #expect(PatternGuideWireTriangularRotation3 == 4)
    #expect(PatternGuideWireTriangularRotation6 == 5)
    #expect(PatternGuideWireTriangularKaleidoscope60 == 6)
    #expect(PatternGuideWireTriangularKaleidoscope30 == 7)
    #expect(PatternGuideWireFinitePlain == 8)
    #expect(PatternGuideWireRadialRotation == 9)
    #expect(PatternGuideWireRadialMirror == 10)
    #expect(PatternGuideWireRadialMandala == 11)
}

@Test
func symmetryFamilyWireValuesAreAppendOnly() {
    #expect(PatternSymmetryFamilyWireRectangular == 0)
    #expect(PatternSymmetryFamilyWireTriangular == 1)
    #expect(PatternSymmetryFamilyWireRadial == 2)
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
    #expect(MemoryLayout<PatternGridFrameUniforms>.size == 96)
    #expect(MemoryLayout<PatternGridFrameUniforms>.stride == 96)
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
    #expect(
        MemoryLayout<PatternGridFrameUniforms>.offset(of: \.symmetryFamily)
            == 52
    )
    #expect(
        MemoryLayout<PatternGridFrameUniforms>.offset(of: \.repeatSize)
            == 56
    )
    #expect(
        MemoryLayout<PatternGridFrameUniforms>.offset(of: \.latticeXAxis)
            == 64
    )
    #expect(
        MemoryLayout<PatternGridFrameUniforms>.offset(of: \.latticeYAxis)
            == 72
    )
    #expect(
        MemoryLayout<PatternGridFrameUniforms>.offset(
            of: \.latticeTranslation
        ) == 80
    )
    #expect(
        MemoryLayout<PatternGridFrameUniforms>.offset(of: \.guideKind)
            == 88
    )
    #expect(
        MemoryLayout<PatternGridFrameUniforms>.offset(of: \.padding2)
            == 92
    )

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
func radialUniformLayoutMatchesTheMetalContract() {
    #expect(MemoryLayout<PatternRadialFrameUniforms>.size == 64)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.stride == 64)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.alignment == 8)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.offset(
        of: \.canvasSize
    ) == 0)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.offset(
        of: \.center
    ) == 8)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.offset(
        of: \.referenceAngle
    ) == 16)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.offset(
        of: \.sectorAngle
    ) == 20)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.offset(
        of: \.displayedSectorCount
    ) == 24)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.offset(
        of: \.dihedral
    ) == 28)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.offset(
        of: \.pageOrigin
    ) == 32)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.offset(
        of: \.pageTableSize
    ) == 40)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.offset(
        of: \.atlasColumns
    ) == 48)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.offset(
        of: \.pageSide
    ) == 52)
    #expect(MemoryLayout<PatternRadialFrameUniforms>.offset(
        of: \.atlasSize
    ) == 56)
}

@Test
func radialResizePageUniformLayoutMatchesTheMetalContract() {
    #expect(MemoryLayout<PatternRadialResizePageUniforms>.size == 16)
    #expect(MemoryLayout<PatternRadialResizePageUniforms>.stride == 16)
    #expect(MemoryLayout<PatternRadialResizePageUniforms>.alignment == 4)
    #expect(MemoryLayout<PatternRadialResizePageUniforms>.offset(
        of: \.logicalPageX
    ) == 0)
    #expect(MemoryLayout<PatternRadialResizePageUniforms>.offset(
        of: \.logicalPageY
    ) == 4)
    #expect(MemoryLayout<PatternRadialResizePageUniforms>.offset(
        of: \.destinationSlot
    ) == 8)
    #expect(MemoryLayout<PatternRadialResizePageUniforms>.offset(
        of: \.padding
    ) == 12)
    #expect(ShaderABI.isValid)
}

@Test
func gridWireIndicesAppendWithoutRenumberingSliceZero() {
    #expect(PatternBufferIndexFrameUniforms == 0)
    #expect(PatternBufferIndexGridFrameUniforms == 1)
    #expect(PatternBufferIndexDabInstances == 2)
    #expect(PatternBufferIndexBrushMaterial == 3)
    #expect(PatternBufferIndexRadialFrameUniforms == 4)
    #expect(PatternBufferIndexRadialResizeDestinationUniforms == 5)
    #expect(PatternBufferIndexRadialResizePage == 6)
    #expect(PatternTextureIndexCanonical == 0)
    #expect(PatternTextureIndexLive == 1)
    #expect(PatternTextureIndexBrushShape == 2)
    #expect(PatternTextureIndexBrushGrain == 3)
    #expect(PatternTextureIndexReplayLive == 4)
}
