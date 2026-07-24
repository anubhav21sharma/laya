import CShaderTypes

public enum ShaderABI {
    public static let projectedStampInstanceStride =
        MemoryLayout<PatternProjectedStampInstance>.stride

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
            && MemoryLayout<PatternProjectedStampInstance>.size == 128
            && MemoryLayout<PatternProjectedStampInstance>.stride == 128
            && MemoryLayout<PatternProjectedStampInstance>.alignment == 16
            && MemoryLayout<PatternProjectedStampInstance>.offset(
                of: \.canonicalXAxis
            ) == 0
            && MemoryLayout<PatternProjectedStampInstance>.offset(
                of: \.canonicalYAxis
            ) == 8
            && MemoryLayout<PatternProjectedStampInstance>.offset(
                of: \.canonicalTranslation
            ) == 16
            && MemoryLayout<PatternProjectedStampInstance>.offset(of: \.radius) == 24
            && MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clipCount) == 28
            && MemoryLayout<PatternProjectedStampInstance>.offset(of: \.color) == 32
            && MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip0) == 48
            && MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip1) == 64
            && MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip2) == 80
            && MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip3) == 96
            && MemoryLayout<PatternProjectedStampInstance>.offset(
                of: \.brushAttributes
            ) == 112
            && MemoryLayout<PatternBrushMaterialUniforms>.size == 48
            && MemoryLayout<PatternBrushMaterialUniforms>.stride == 48
            && MemoryLayout<PatternBrushMaterialUniforms>.alignment == 4
            && MemoryLayout<PatternBrushMaterialUniforms>.offset(
                of: \.materialFamily
            ) == 0
            && MemoryLayout<PatternBrushMaterialUniforms>.offset(
                of: \.grainCoordinateMode
            ) == 4
            && MemoryLayout<PatternBrushMaterialUniforms>.offset(
                of: \.strokeOpacity
            ) == 8
            && MemoryLayout<PatternBrushMaterialUniforms>.offset(
                of: \.materialStrength
            ) == 12
            && MemoryLayout<PatternBrushMaterialUniforms>.offset(of: \.wetness) == 16
            && MemoryLayout<PatternBrushMaterialUniforms>.offset(
                of: \.bleedRadius
            ) == 20
            && MemoryLayout<PatternBrushMaterialUniforms>.offset(
                of: \.softenPasses
            ) == 24
            && MemoryLayout<PatternBrushMaterialUniforms>.offset(
                of: \.accumulationLimit
            ) == 28
            && MemoryLayout<PatternBrushMaterialUniforms>.offset(
                of: \.shapeKind
            ) == 32
            && MemoryLayout<PatternBrushMaterialUniforms>.offset(
                of: \.grainKind
            ) == 36
            && MemoryLayout<PatternBrushMaterialUniforms>.offset(
                of: \.grainRotation
            ) == 40
            && MemoryLayout<PatternBrushMaterialUniforms>.offset(
                of: \.padding1
            ) == 44
    }

    public static func preconditionValid(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(isValid, "CPU/MSL shader layout mismatch", file: file, line: line)
    }
}
