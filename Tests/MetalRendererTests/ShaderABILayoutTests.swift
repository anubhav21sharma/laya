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
func documentPaintMutationWireContractIsFrozen() {
    #expect(PatternDocumentPaintMutationABIVersion == 1)
    #expect(PatternBufferIndexDocumentPaintMutationUniforms == 12)
    #expect(PatternBufferIndexDocumentPaintMutationReduction == 13)
    #expect(PatternBufferIndexDocumentPaintMutationSourceBytes == 14)
    #expect(PatternTextureIndexDocumentPaintBase == 22)
    #expect(PatternTextureIndexDocumentPaintAuthoritative == 23)
    #expect(PatternTextureIndexDocumentPaintDestination == 24)
    #expect(PatternDocumentPaintFlagBaseKnownClear == 1)
    #expect(PatternDocumentPaintFlagAuthoritativeKnownClear == 2)
    #expect(PatternDocumentPaintFlagRadialTargetMask == 4)

    #expect(MemoryLayout<PatternDocumentPaintMutationUniforms>.size == 80)
    #expect(MemoryLayout<PatternDocumentPaintMutationUniforms>.stride == 80)
    #expect(MemoryLayout<PatternDocumentPaintMutationUniforms>.alignment == 16)
    let swiftOffsets: [Int?] = [
        MemoryLayout<PatternDocumentPaintMutationUniforms>.offset(
            of: \.logicalExtent
        ),
        MemoryLayout<PatternDocumentPaintMutationUniforms>.offset(
            of: \.sourceOrigin
        ),
        MemoryLayout<PatternDocumentPaintMutationUniforms>.offset(
            of: \.destinationOrigin
        ),
        MemoryLayout<PatternDocumentPaintMutationUniforms>.offset(
            of: \.copyExtent
        ),
        MemoryLayout<PatternDocumentPaintMutationUniforms>.offset(
            of: \.logicalPage
        ),
        MemoryLayout<PatternDocumentPaintMutationUniforms>.offset(
            of: \.reserved0
        ),
        MemoryLayout<PatternDocumentPaintMutationUniforms>.offset(
            of: \.parameters
        ),
        MemoryLayout<PatternDocumentPaintMutationUniforms>.offset(
            of: \.compositeMode
        ),
        MemoryLayout<PatternDocumentPaintMutationUniforms>.offset(of: \.flags),
        MemoryLayout<PatternDocumentPaintMutationUniforms>.offset(
            of: \.sourceBytesPerRow
        ),
        MemoryLayout<PatternDocumentPaintMutationUniforms>.offset(
            of: \.sourceByteOffset
        ),
    ]
    let expectedOffsets: [Int?] = [0, 8, 16, 24, 32, 40, 48, 64, 68, 72, 76]
    #expect(swiftOffsets == expectedOffsets)
    let cOffsets = [
        PatternDocumentPaintMutationUniformsOffsetLogicalExtent(),
        PatternDocumentPaintMutationUniformsOffsetSourceOrigin(),
        PatternDocumentPaintMutationUniformsOffsetDestinationOrigin(),
        PatternDocumentPaintMutationUniformsOffsetCopyExtent(),
        PatternDocumentPaintMutationUniformsOffsetLogicalPage(),
        PatternDocumentPaintMutationUniformsOffsetReserved0(),
        PatternDocumentPaintMutationUniformsOffsetParameters(),
        PatternDocumentPaintMutationUniformsOffsetCompositeMode(),
        PatternDocumentPaintMutationUniformsOffsetFlags(),
        PatternDocumentPaintMutationUniformsOffsetSourceBytesPerRow(),
        PatternDocumentPaintMutationUniformsOffsetSourceByteOffset(),
    ]
    #expect(cOffsets == expectedOffsets.map { numericCast($0!) })

    #expect(MemoryLayout<PatternDocumentPaintMutationReduction>.size == 8)
    #expect(MemoryLayout<PatternDocumentPaintMutationReduction>.stride == 8)
    #expect(MemoryLayout<PatternDocumentPaintMutationReduction>.alignment == 4)
    #expect(MemoryLayout<PatternDocumentPaintMutationReduction>.offset(
        of: \.maximumAlphaBits
    ) == 0)
    #expect(MemoryLayout<PatternDocumentPaintMutationReduction>.offset(
        of: \.invalid
    ) == 4)
    #expect(ShaderABI.isValid)
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
    #expect(PatternTextureIndexRadialPageTable == 5)
}

@Test
func sparseSamplingWireValuesAppendWithoutRenumberingExistingSlots() {
    #expect(PatternBufferIndexFrameUniforms == 0)
    #expect(PatternBufferIndexGridFrameUniforms == 1)
    #expect(PatternBufferIndexDabInstances == 2)
    #expect(PatternBufferIndexBrushMaterial == 3)
    #expect(PatternBufferIndexRadialFrameUniforms == 4)
    #expect(PatternBufferIndexRadialResizeDestinationUniforms == 5)
    #expect(PatternBufferIndexRadialResizePage == 6)
    #expect(PatternBufferIndexSparseSamplingUniforms == 7)
    #expect(PatternBufferIndexSparsePageTableDescriptors == 8)
    #expect(PatternBufferIndexSparsePageEntries == 9)
    #expect(PatternBufferIndexSparseBindingRemap == 10)
    #expect(PatternBufferIndexSparseTextureArguments == 11)

    #expect(PatternTextureIndexCanonical == 0)
    #expect(PatternTextureIndexLive == 1)
    #expect(PatternTextureIndexBrushShape == 2)
    #expect(PatternTextureIndexBrushGrain == 3)
    #expect(PatternTextureIndexReplayLive == 4)
    #expect(PatternTextureIndexRadialPageTable == 5)
    #expect(PatternTextureIndexSparseFallbackBase == 6)
    #expect(PatternSparseMaximumFallbackTextures == 16)
    #expect(PatternSparseMaximumTier2Textures == 512)
    #expect(PatternSparseSamplingABIVersion == 1)

    #expect(PatternSparseRoleCanonical == 0)
    #expect(PatternSparseRoleAuthoritative == 1)
    #expect(PatternSparseRolePrediction == 2)
    #expect(PatternSparseAddressingPeriodic == 1)
    #expect(PatternSparseAddressingRadial == 2)
    #expect(PatternSparsePageEntryKnownClear == 1)
}

@Test
func sparseSamplingUniformLayoutMatchesMetalContract() {
    #expect(MemoryLayout<PatternSparseSamplingUniforms>.size == 64)
    #expect(MemoryLayout<PatternSparseSamplingUniforms>.stride == 64)
    #expect(MemoryLayout<PatternSparseSamplingUniforms>.alignment == 8)
    let swiftOffsets = [
        MemoryLayout<PatternSparseSamplingUniforms>.offset(of: \.outputSize),
        MemoryLayout<PatternSparseSamplingUniforms>.offset(of: \.sourceOrigin),
        MemoryLayout<PatternSparseSamplingUniforms>.offset(of: \.sourceStep),
        MemoryLayout<PatternSparseSamplingUniforms>.offset(of: \.descriptorCount),
        MemoryLayout<PatternSparseSamplingUniforms>.offset(of: \.layerCount),
        MemoryLayout<PatternSparseSamplingUniforms>.offset(of: \.bindingCount),
        MemoryLayout<PatternSparseSamplingUniforms>.offset(of: \.addressingFlags),
        MemoryLayout<PatternSparseSamplingUniforms>.offset(of: \.period),
        MemoryLayout<PatternSparseSamplingUniforms>.offset(of: \.compositeMode),
        MemoryLayout<PatternSparseSamplingUniforms>.offset(of: \.liveVisible),
        MemoryLayout<PatternSparseSamplingUniforms>.offset(of: \.reserved),
    ]
    let expected: [Int?] = [0, 8, 16, 24, 28, 32, 36, 40, 48, 52, 56]
    #expect(swiftOffsets == expected)
    let cOffsets = [
        PatternSparseSamplingUniformsOffsetOutputSize(),
        PatternSparseSamplingUniformsOffsetSourceOrigin(),
        PatternSparseSamplingUniformsOffsetSourceStep(),
        PatternSparseSamplingUniformsOffsetDescriptorCount(),
        PatternSparseSamplingUniformsOffsetLayerCount(),
        PatternSparseSamplingUniformsOffsetBindingCount(),
        PatternSparseSamplingUniformsOffsetAddressingFlags(),
        PatternSparseSamplingUniformsOffsetPeriod(),
        PatternSparseSamplingUniformsOffsetCompositeMode(),
        PatternSparseSamplingUniformsOffsetLiveVisible(),
        PatternSparseSamplingUniformsOffsetReserved(),
    ]
    #expect(cOffsets == expected.map { numericCast($0!) })
}

@Test
func sparsePageTableLayoutsMatchMetalContract() {
    #expect(MemoryLayout<PatternSparsePageTableDescriptor>.size == 32)
    #expect(MemoryLayout<PatternSparsePageTableDescriptor>.stride == 32)
    #expect(MemoryLayout<PatternSparsePageTableDescriptor>.alignment == 8)
    let descriptorSwiftOffsets = [
        MemoryLayout<PatternSparsePageTableDescriptor>.offset(of: \.entryOffset),
        MemoryLayout<PatternSparsePageTableDescriptor>.offset(of: \.entryCount),
        MemoryLayout<PatternSparsePageTableDescriptor>.offset(of: \.tableOrigin),
        MemoryLayout<PatternSparsePageTableDescriptor>.offset(of: \.tableSize),
        MemoryLayout<PatternSparsePageTableDescriptor>.offset(of: \.layerIndex),
        MemoryLayout<PatternSparsePageTableDescriptor>.offset(of: \.role),
    ]
    let descriptorExpected: [Int?] = [0, 4, 8, 16, 24, 28]
    #expect(descriptorSwiftOffsets == descriptorExpected)
    #expect([
        PatternSparsePageTableDescriptorOffsetEntryOffset(),
        PatternSparsePageTableDescriptorOffsetEntryCount(),
        PatternSparsePageTableDescriptorOffsetTableOrigin(),
        PatternSparsePageTableDescriptorOffsetTableSize(),
        PatternSparsePageTableDescriptorOffsetLayerIndex(),
        PatternSparsePageTableDescriptorOffsetRole(),
    ] == descriptorExpected.map { numericCast($0!) })

    #expect(MemoryLayout<PatternSparseTilePageEntry>.size == 32)
    #expect(MemoryLayout<PatternSparseTilePageEntry>.stride == 32)
    #expect(MemoryLayout<PatternSparseTilePageEntry>.alignment == 8)
    let entrySwiftOffsets = [
        MemoryLayout<PatternSparseTilePageEntry>.offset(of: \.logicalOrigin),
        MemoryLayout<PatternSparseTilePageEntry>.offset(of: \.physicalOrigin),
        MemoryLayout<PatternSparseTilePageEntry>.offset(of: \.globalBindingSlot),
        MemoryLayout<PatternSparseTilePageEntry>.offset(of: \.packedLocalMinimum),
        MemoryLayout<PatternSparseTilePageEntry>.offset(of: \.packedLocalMaximum),
        MemoryLayout<PatternSparseTilePageEntry>.offset(of: \.flags),
    ]
    let entryExpected: [Int?] = [0, 8, 16, 20, 24, 28]
    #expect(entrySwiftOffsets == entryExpected)
    #expect([
        PatternSparseTilePageEntryOffsetLogicalOrigin(),
        PatternSparseTilePageEntryOffsetPhysicalOrigin(),
        PatternSparseTilePageEntryOffsetGlobalBindingSlot(),
        PatternSparseTilePageEntryOffsetPackedLocalMinimum(),
        PatternSparseTilePageEntryOffsetPackedLocalMaximum(),
        PatternSparseTilePageEntryOffsetFlags(),
    ] == entryExpected.map { numericCast($0!) })
    #expect(ShaderABI.isValid)
}

@Test
func sparsePackedBoundsAdmitOnlyCheckedZeroThroughTileSide() throws {
    let packed = try SparseSamplingABI.packLocalBounds(
        minimum: SIMD2(0, 17),
        maximum: SIMD2(256, 255)
    )
    #expect(SparseSamplingABI.unpackLocalBound(packed.minimum) == SIMD2(0, 17))
    #expect(SparseSamplingABI.unpackLocalBound(packed.maximum) == SIMD2(256, 255))
    #expect(throws: SparseSamplingABIError.localBoundOutOfRange(-1)) {
        _ = try SparseSamplingABI.packLocalBound(SIMD2(-1, 0))
    }
    #expect(throws: SparseSamplingABIError.localBoundOutOfRange(257)) {
        _ = try SparseSamplingABI.packLocalBound(SIMD2(0, 257))
    }
    #expect(throws: SparseSamplingABIError.invertedLocalBounds) {
        _ = try SparseSamplingABI.packLocalBounds(
            minimum: SIMD2(8, 9),
            maximum: SIMD2(7, 10)
        )
    }
}
