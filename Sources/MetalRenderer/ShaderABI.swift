import CShaderTypes

public enum ShaderABI {
    public static var isValid: Bool {
        MemoryLayout<PatternFrameUniforms>.size == 16
            && MemoryLayout<PatternFrameUniforms>.stride == 16
            && MemoryLayout<PatternFrameUniforms>.alignment == 8
            && MemoryLayout<PatternFrameUniforms>.offset(of: \.drawableSize) == 0
            && MemoryLayout<PatternFrameUniforms>.offset(of: \.inverseDrawableSize) == 8
            && MemoryLayout<PatternGridFrameUniforms>.size == 56
            && MemoryLayout<PatternGridFrameUniforms>.stride == 56
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
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.padding) == 52
            && MemoryLayout<PatternClipHalfPlane>.size == 16
            && MemoryLayout<PatternClipHalfPlane>.stride == 16
            && MemoryLayout<PatternClipHalfPlane>.alignment == 8
            && MemoryLayout<PatternClipHalfPlane>.offset(of: \.normal) == 0
            && MemoryLayout<PatternClipHalfPlane>.offset(of: \.offset) == 8
            && MemoryLayout<PatternClipHalfPlane>.offset(of: \.padding) == 12
            && MemoryLayout<PatternProjectedStampInstance>.size == 112
            && MemoryLayout<PatternProjectedStampInstance>.stride == 112
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
    }

    public static func preconditionValid(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(isValid, "CPU/MSL shader layout mismatch", file: file, line: line)
    }
}
