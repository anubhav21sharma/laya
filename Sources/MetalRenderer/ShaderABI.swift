import CShaderTypes

public enum ShaderABI {
    public static let depositionStampInstanceStride =
        MemoryLayout<PatternDepositionStampInstance>.stride

    public static var isValid: Bool {
        MemoryLayout<PatternFrameUniforms>.size == 16
            && MemoryLayout<PatternFrameUniforms>.stride == 16
            && MemoryLayout<PatternFrameUniforms>.alignment == 8
            && MemoryLayout<PatternFrameUniforms>.offset(of: \.drawableSize) == 0
            && MemoryLayout<PatternFrameUniforms>.offset(of: \.inverseDrawableSize) == 8
            && MemoryLayout<PatternGridFrameUniforms>.size == 96
            && MemoryLayout<PatternGridFrameUniforms>.stride == 96
            && MemoryLayout<PatternGridFrameUniforms>.alignment == 8
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.drawableSize) == 0
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.worldCenter) == 8
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.tileSize) == 16
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.zoom) == 24
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.gridLineWidth) == 28
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.showGridLines) == 32
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.liveVisible) == 36
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.tilingKind) == 40
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.diagnosticMode) == 44
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.compositeMode) == 48
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.symmetryFamily)
                == 52
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.repeatSize)
                == 56
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.latticeXAxis)
                == 64
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.latticeYAxis)
                == 72
            && MemoryLayout<PatternGridFrameUniforms>.offset(
                of: \.latticeTranslation
            ) == 80
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.guideKind)
                == 88
            && MemoryLayout<PatternGridFrameUniforms>.offset(
                of: \.showCanvasBoundary
            ) == 92
            && MemoryLayout<PatternRadialFrameUniforms>.size == 64
            && MemoryLayout<PatternRadialFrameUniforms>.stride == 64
            && MemoryLayout<PatternRadialFrameUniforms>.alignment == 8
            && MemoryLayout<PatternRadialFrameUniforms>.offset(
                of: \.canvasSize
            ) == 0
            && MemoryLayout<PatternRadialFrameUniforms>.offset(of: \.center)
                == 8
            && MemoryLayout<PatternRadialFrameUniforms>.offset(
                of: \.referenceAngle
            ) == 16
            && MemoryLayout<PatternRadialFrameUniforms>.offset(
                of: \.sectorAngle
            ) == 20
            && MemoryLayout<PatternRadialFrameUniforms>.offset(
                of: \.displayedSectorCount
            ) == 24
            && MemoryLayout<PatternRadialFrameUniforms>.offset(
                of: \.dihedral
            ) == 28
            && MemoryLayout<PatternRadialFrameUniforms>.offset(
                of: \.pageOrigin
            ) == 32
            && MemoryLayout<PatternRadialFrameUniforms>.offset(
                of: \.pageTableSize
            ) == 40
            && MemoryLayout<PatternRadialFrameUniforms>.offset(
                of: \.atlasColumns
            ) == 48
            && MemoryLayout<PatternRadialFrameUniforms>.offset(
                of: \.pageSide
            ) == 52
            && MemoryLayout<PatternRadialFrameUniforms>.offset(
                of: \.atlasSize
            ) == 56
            && MemoryLayout<PatternRadialResizePageUniforms>.size == 16
            && MemoryLayout<PatternRadialResizePageUniforms>.stride == 16
            && MemoryLayout<PatternRadialResizePageUniforms>.alignment == 4
            && MemoryLayout<PatternRadialResizePageUniforms>.offset(
                of: \.logicalPageX
            ) == 0
            && MemoryLayout<PatternRadialResizePageUniforms>.offset(
                of: \.logicalPageY
            ) == 4
            && MemoryLayout<PatternRadialResizePageUniforms>.offset(
                of: \.destinationSlot
            ) == 8
            && MemoryLayout<PatternRadialResizePageUniforms>.offset(
                of: \.padding
            ) == 12
            && MemoryLayout<PatternClipHalfPlane>.size == 16
            && MemoryLayout<PatternClipHalfPlane>.stride == 16
            && MemoryLayout<PatternClipHalfPlane>.alignment == 8
            && MemoryLayout<PatternClipHalfPlane>.offset(of: \.normal) == 0
            && MemoryLayout<PatternClipHalfPlane>.offset(of: \.offset) == 8
            && MemoryLayout<PatternClipHalfPlane>.offset(of: \.padding) == 12
            && depositionStampInstanceIsValid
            && MemoryLayout<PatternCompositeUniforms>.size == 16
            && MemoryLayout<PatternCompositeUniforms>.stride == 16
            && MemoryLayout<PatternCompositeUniforms>.alignment == 16
            && MemoryLayout<PatternCompositeUniforms>.offset(
                of: \.parameters
            ) == 0
            && sparseSamplingIsValid
    }

    private static var depositionStampInstanceIsValid: Bool {
        MemoryLayout<PatternDepositionStampInstance>.size == 256
            && MemoryLayout<PatternDepositionStampInstance>.stride == 256
            && MemoryLayout<PatternDepositionStampInstance>.alignment == 16
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.tipFrame0
            ) == 0
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.tipFrame1
            ) == 16
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.primaryGrainFrame0
            ) == 32
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.primaryGrainFrame1
            ) == 48
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.secondaryGrainFrame0
            ) == 64
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.secondaryGrainFrame1
            ) == 80
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.premultipliedColor
            ) == 96
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.coverageInputs
            ) == 112
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.clip0
            ) == 128
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.clip1
            ) == 144
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.clip2
            ) == 160
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.clip3
            ) == 176
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.identity
            ) == 192
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.metadata
            ) == 208
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.reserved0
            ) == 224
            && MemoryLayout<PatternDepositionStampInstance>.offset(
                of: \.reserved1
            ) == 240
            && PatternDepositionStampInstanceOffsetTipFrame0() == 0
            && PatternDepositionStampInstanceOffsetTipFrame1() == 16
            && PatternDepositionStampInstanceOffsetPrimaryGrainFrame0() == 32
            && PatternDepositionStampInstanceOffsetPrimaryGrainFrame1() == 48
            && PatternDepositionStampInstanceOffsetSecondaryGrainFrame0() == 64
            && PatternDepositionStampInstanceOffsetSecondaryGrainFrame1() == 80
            && PatternDepositionStampInstanceOffsetPremultipliedColor() == 96
            && PatternDepositionStampInstanceOffsetCoverageInputs() == 112
            && PatternDepositionStampInstanceOffsetClip0() == 128
            && PatternDepositionStampInstanceOffsetClip1() == 144
            && PatternDepositionStampInstanceOffsetClip2() == 160
            && PatternDepositionStampInstanceOffsetClip3() == 176
            && PatternDepositionStampInstanceOffsetIdentity() == 192
            && PatternDepositionStampInstanceOffsetMetadata() == 208
            && PatternDepositionStampInstanceOffsetReserved0() == 224
            && PatternDepositionStampInstanceOffsetReserved1() == 240
            && PatternDepositionABIVersion == UInt32(DepositionABI.version)
    }

    private static var sparseSamplingIsValid: Bool {
        MemoryLayout<PatternSparseSamplingUniforms>.size == 64
            && MemoryLayout<PatternSparseSamplingUniforms>.stride == 64
            && MemoryLayout<PatternSparseSamplingUniforms>.alignment == 8
            && MemoryLayout<PatternSparseSamplingUniforms>.offset(
                of: \.outputSize
            ) == 0
            && MemoryLayout<PatternSparseSamplingUniforms>.offset(
                of: \.sourceOrigin
            ) == 8
            && MemoryLayout<PatternSparseSamplingUniforms>.offset(
                of: \.sourceStep
            ) == 16
            && MemoryLayout<PatternSparseSamplingUniforms>.offset(
                of: \.descriptorCount
            ) == 24
            && MemoryLayout<PatternSparseSamplingUniforms>.offset(
                of: \.layerCount
            ) == 28
            && MemoryLayout<PatternSparseSamplingUniforms>.offset(
                of: \.bindingCount
            ) == 32
            && MemoryLayout<PatternSparseSamplingUniforms>.offset(
                of: \.addressingFlags
            ) == 36
            && MemoryLayout<PatternSparseSamplingUniforms>.offset(
                of: \.period
            ) == 40
            && MemoryLayout<PatternSparseSamplingUniforms>.offset(
                of: \.compositeMode
            ) == 48
            && MemoryLayout<PatternSparseSamplingUniforms>.offset(
                of: \.liveVisible
            ) == 52
            && MemoryLayout<PatternSparseSamplingUniforms>.offset(
                of: \.reserved
            ) == 56
            && MemoryLayout<PatternSparsePageTableDescriptor>.size == 32
            && MemoryLayout<PatternSparsePageTableDescriptor>.stride == 32
            && MemoryLayout<PatternSparsePageTableDescriptor>.alignment == 8
            && MemoryLayout<PatternSparsePageTableDescriptor>.offset(
                of: \.entryOffset
            ) == 0
            && MemoryLayout<PatternSparsePageTableDescriptor>.offset(
                of: \.entryCount
            ) == 4
            && MemoryLayout<PatternSparsePageTableDescriptor>.offset(
                of: \.tableOrigin
            ) == 8
            && MemoryLayout<PatternSparsePageTableDescriptor>.offset(
                of: \.tableSize
            ) == 16
            && MemoryLayout<PatternSparsePageTableDescriptor>.offset(
                of: \.layerIndex
            ) == 24
            && MemoryLayout<PatternSparsePageTableDescriptor>.offset(
                of: \.role
            ) == 28
            && MemoryLayout<PatternSparseTilePageEntry>.size == 32
            && MemoryLayout<PatternSparseTilePageEntry>.stride == 32
            && MemoryLayout<PatternSparseTilePageEntry>.alignment == 8
            && MemoryLayout<PatternSparseTilePageEntry>.offset(
                of: \.logicalOrigin
            ) == 0
            && MemoryLayout<PatternSparseTilePageEntry>.offset(
                of: \.physicalOrigin
            ) == 8
            && MemoryLayout<PatternSparseTilePageEntry>.offset(
                of: \.globalBindingSlot
            ) == 16
            && MemoryLayout<PatternSparseTilePageEntry>.offset(
                of: \.packedLocalMinimum
            ) == 20
            && MemoryLayout<PatternSparseTilePageEntry>.offset(
                of: \.packedLocalMaximum
            ) == 24
            && MemoryLayout<PatternSparseTilePageEntry>.offset(
                of: \.flags
            ) == 28
            && PatternSparseSamplingUniformsOffsetOutputSize() == 0
            && PatternSparseSamplingUniformsOffsetSourceOrigin() == 8
            && PatternSparseSamplingUniformsOffsetSourceStep() == 16
            && PatternSparseSamplingUniformsOffsetDescriptorCount() == 24
            && PatternSparseSamplingUniformsOffsetLayerCount() == 28
            && PatternSparseSamplingUniformsOffsetBindingCount() == 32
            && PatternSparseSamplingUniformsOffsetAddressingFlags() == 36
            && PatternSparseSamplingUniformsOffsetPeriod() == 40
            && PatternSparseSamplingUniformsOffsetCompositeMode() == 48
            && PatternSparseSamplingUniformsOffsetLiveVisible() == 52
            && PatternSparseSamplingUniformsOffsetReserved() == 56
            && PatternSparsePageTableDescriptorOffsetEntryOffset() == 0
            && PatternSparsePageTableDescriptorOffsetEntryCount() == 4
            && PatternSparsePageTableDescriptorOffsetTableOrigin() == 8
            && PatternSparsePageTableDescriptorOffsetTableSize() == 16
            && PatternSparsePageTableDescriptorOffsetLayerIndex() == 24
            && PatternSparsePageTableDescriptorOffsetRole() == 28
            && PatternSparseTilePageEntryOffsetLogicalOrigin() == 0
            && PatternSparseTilePageEntryOffsetPhysicalOrigin() == 8
            && PatternSparseTilePageEntryOffsetGlobalBindingSlot() == 16
            && PatternSparseTilePageEntryOffsetPackedLocalMinimum() == 20
            && PatternSparseTilePageEntryOffsetPackedLocalMaximum() == 24
            && PatternSparseTilePageEntryOffsetFlags() == 28
            && PatternSparseSamplingABIVersion == UInt32(
                SparseSamplingABI.version
            )
    }

    public static func preconditionValid(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(isValid, "CPU/MSL shader layout mismatch", file: file, line: line)
    }
}

public enum SparseSamplingABIError: Error, Equatable, Sendable {
    case localBoundOutOfRange(Int)
    case invertedLocalBounds
}

public enum SparseSamplingABI {
    public static let version: UInt16 = 1
    public static let maximumFallbackTextures = 16
    public static let maximumTier2Textures = 512

    public static func packLocalBound(
        _ bound: SIMD2<Int>
    ) throws -> UInt32 {
        for component in [bound.x, bound.y] where !(0...256).contains(component) {
            throw SparseSamplingABIError.localBoundOutOfRange(component)
        }
        return UInt32(bound.x) | (UInt32(bound.y) << 16)
    }

    public static func unpackLocalBound(_ packed: UInt32) -> SIMD2<Int> {
        SIMD2(Int(packed & 0xffff), Int((packed >> 16) & 0xffff))
    }

    public static func packLocalBounds(
        minimum: SIMD2<Int>,
        maximum: SIMD2<Int>
    ) throws -> (minimum: UInt32, maximum: UInt32) {
        let packedMinimum = try packLocalBound(minimum)
        let packedMaximum = try packLocalBound(maximum)
        guard minimum.x <= maximum.x, minimum.y <= maximum.y else {
            throw SparseSamplingABIError.invertedLocalBounds
        }
        return (packedMinimum, packedMaximum)
    }
}
