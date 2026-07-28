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
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.padding2)
                == 92
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

    public static func preconditionValid(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(isValid, "CPU/MSL shader layout mismatch", file: file, line: line)
    }
}
