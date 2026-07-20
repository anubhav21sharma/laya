import CShaderTypes
import PatternEngine

public extension PatternProjectedStampInstance {
    init(fragment: CellFragment, radius: Float) {
        precondition(
            radius.isFinite && (1...1_000).contains(radius),
            "Projected stamp radius must be finite and within 1...1000"
        )
        precondition(
            fragment.brushClip.halfPlanes.count <= 4,
            "Projected stamp clips must contain no more than four planes"
        )

        let zeroPlane = PatternClipHalfPlane(
            normal: .zero,
            offset: 0,
            padding: 0
        )
        var clip0 = zeroPlane
        var clip1 = zeroPlane
        var clip2 = zeroPlane
        var clip3 = zeroPlane
        for (index, plane) in fragment.brushClip.halfPlanes.enumerated() {
            let packed = PatternClipHalfPlane(
                normal: plane.normal,
                offset: plane.offset,
                padding: 0
            )
            switch index {
            case 0:
                clip0 = packed
            case 1:
                clip1 = packed
            case 2:
                clip2 = packed
            case 3:
                clip3 = packed
            default:
                preconditionFailure(
                    "Projected stamp clip index exceeds four planes"
                )
            }
        }

        self.init(
            canonicalXAxis: fragment.canonicalFromBrush.xAxis,
            canonicalYAxis: fragment.canonicalFromBrush.yAxis,
            canonicalTranslation: fragment.canonicalFromBrush.translation,
            radius: radius,
            clipCount: UInt32(fragment.brushClip.halfPlanes.count),
            clip0: clip0,
            clip1: clip1,
            clip2: clip2,
            clip3: clip3
        )
    }
}
