public enum BlankCanvasContract {
    public static let canvasBGRA = SIMD4<UInt8>(241, 244, 242, 255)

    public static func matches(
        actual: SIMD4<UInt8>,
        expected: SIMD4<UInt8>,
        tolerance: UInt8
    ) -> Bool {
        let maximumDelta = Int(tolerance)
        return abs(Int(actual.x) - Int(expected.x)) <= maximumDelta
            && abs(Int(actual.y) - Int(expected.y)) <= maximumDelta
            && abs(Int(actual.z) - Int(expected.z)) <= maximumDelta
            && abs(Int(actual.w) - Int(expected.w)) <= maximumDelta
    }
}
