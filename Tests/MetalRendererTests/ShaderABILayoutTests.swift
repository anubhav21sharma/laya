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
        MemoryLayout<PatternGridFrameUniforms>.offset(
            of: \.showCanvasBoundary
        ) == 92
    )

    #expect(MemoryLayout<PatternClipHalfPlane>.size == 16)
    #expect(MemoryLayout<PatternClipHalfPlane>.stride == 16)
    #expect(MemoryLayout<PatternClipHalfPlane>.alignment == 8)
    #expect(MemoryLayout<PatternClipHalfPlane>.offset(of: \.normal) == 0)
    #expect(MemoryLayout<PatternClipHalfPlane>.offset(of: \.offset) == 8)
    #expect(MemoryLayout<PatternClipHalfPlane>.offset(of: \.padding) == 12)

    #expect(MemoryLayout<PatternCompositeUniforms>.size == 16)
    #expect(MemoryLayout<PatternCompositeUniforms>.stride == 16)
    #expect(MemoryLayout<PatternCompositeUniforms>.alignment == 16)
    #expect(
        MemoryLayout<PatternCompositeUniforms>.offset(of: \.parameters) == 0
    )
    #expect(ShaderABI.isValid)
}

@Test
func depositionInstanceHasFrozenWireLayout() {
    #expect(MemoryLayout<PatternDepositionStampInstance>.size == 256)
    #expect(MemoryLayout<PatternDepositionStampInstance>.stride == 256)
    #expect(MemoryLayout<PatternDepositionStampInstance>.alignment == 16)

    let expectedOffsets: [Int?] = [
        0, 16, 32, 48, 64, 80, 96, 112,
        128, 144, 160, 176, 192, 208, 224, 240,
    ]
    let swiftOffsets = [
        MemoryLayout<PatternDepositionStampInstance>.offset(of: \.tipFrame0),
        MemoryLayout<PatternDepositionStampInstance>.offset(of: \.tipFrame1),
        MemoryLayout<PatternDepositionStampInstance>.offset(
            of: \.primaryGrainFrame0
        ),
        MemoryLayout<PatternDepositionStampInstance>.offset(
            of: \.primaryGrainFrame1
        ),
        MemoryLayout<PatternDepositionStampInstance>.offset(
            of: \.secondaryGrainFrame0
        ),
        MemoryLayout<PatternDepositionStampInstance>.offset(
            of: \.secondaryGrainFrame1
        ),
        MemoryLayout<PatternDepositionStampInstance>.offset(
            of: \.premultipliedColor
        ),
        MemoryLayout<PatternDepositionStampInstance>.offset(
            of: \.coverageInputs
        ),
        MemoryLayout<PatternDepositionStampInstance>.offset(of: \.clip0),
        MemoryLayout<PatternDepositionStampInstance>.offset(of: \.clip1),
        MemoryLayout<PatternDepositionStampInstance>.offset(of: \.clip2),
        MemoryLayout<PatternDepositionStampInstance>.offset(of: \.clip3),
        MemoryLayout<PatternDepositionStampInstance>.offset(of: \.identity),
        MemoryLayout<PatternDepositionStampInstance>.offset(of: \.metadata),
        MemoryLayout<PatternDepositionStampInstance>.offset(of: \.reserved0),
        MemoryLayout<PatternDepositionStampInstance>.offset(of: \.reserved1),
    ]
    #expect(swiftOffsets == expectedOffsets)

    let cOffsets = [
        PatternDepositionStampInstanceOffsetTipFrame0(),
        PatternDepositionStampInstanceOffsetTipFrame1(),
        PatternDepositionStampInstanceOffsetPrimaryGrainFrame0(),
        PatternDepositionStampInstanceOffsetPrimaryGrainFrame1(),
        PatternDepositionStampInstanceOffsetSecondaryGrainFrame0(),
        PatternDepositionStampInstanceOffsetSecondaryGrainFrame1(),
        PatternDepositionStampInstanceOffsetPremultipliedColor(),
        PatternDepositionStampInstanceOffsetCoverageInputs(),
        PatternDepositionStampInstanceOffsetClip0(),
        PatternDepositionStampInstanceOffsetClip1(),
        PatternDepositionStampInstanceOffsetClip2(),
        PatternDepositionStampInstanceOffsetClip3(),
        PatternDepositionStampInstanceOffsetIdentity(),
        PatternDepositionStampInstanceOffsetMetadata(),
        PatternDepositionStampInstanceOffsetReserved0(),
        PatternDepositionStampInstanceOffsetReserved1(),
    ]
    #expect(cOffsets == expectedOffsets.map { numericCast($0!) })
    #expect(UInt32(DepositionABI.version) == PatternDepositionABIVersion)
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
