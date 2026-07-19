import CShaderTypes

public enum ShaderABI {
    public static var isValid: Bool {
        MemoryLayout<PatternFrameUniforms>.size == 16
            && MemoryLayout<PatternFrameUniforms>.stride == 16
            && MemoryLayout<PatternFrameUniforms>.alignment == 8
            && MemoryLayout<PatternFrameUniforms>.offset(of: \.drawableSize) == 0
            && MemoryLayout<PatternFrameUniforms>.offset(of: \.inverseDrawableSize) == 8
            && MemoryLayout<PatternGridFrameUniforms>.size == 40
            && MemoryLayout<PatternGridFrameUniforms>.stride == 40
            && MemoryLayout<PatternGridFrameUniforms>.alignment == 8
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.drawableSize) == 0
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.worldCenter) == 8
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.tileSize) == 16
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.zoom) == 24
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.gridLineWidth) == 28
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.showGridLines) == 32
            && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.liveVisible) == 36
            && MemoryLayout<PatternDabInstance>.size == 16
            && MemoryLayout<PatternDabInstance>.stride == 16
            && MemoryLayout<PatternDabInstance>.alignment == 8
            && MemoryLayout<PatternDabInstance>.offset(of: \.center) == 0
            && MemoryLayout<PatternDabInstance>.offset(of: \.radius) == 8
            && MemoryLayout<PatternDabInstance>.offset(of: \.padding) == 12
    }

    public static func preconditionValid(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(isValid, "CPU/MSL shader layout mismatch", file: file, line: line)
    }
}
