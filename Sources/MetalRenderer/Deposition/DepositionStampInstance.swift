import CShaderTypes
import PatternEngine
import simd

enum DepositionIdentityFlags {
    static let predicted: UInt32 = 1 << 0
}

package enum DepositionShapeFlags {
    package static let reflected: UInt32 = 1 << 0
}

enum DepositionGrainFlags {
    static let primary: UInt32 = 1 << 0
    static let secondary: UInt32 = 1 << 1
}

enum DepositionStampPackingError: Error, Equatable, Sendable {
    case nonfiniteField(String)
    case invalidRadius
    case singularBrushFrame
    case tooManyClipPlanes(actual: Int, maximum: Int)
}

enum DepositionStampPacker {
    static let maximumClipPlaneCount = 4

    static func validateClipPlaneCount(_ count: Int) throws {
        guard count <= maximumClipPlaneCount else {
            throw DepositionStampPackingError.tooManyClipPlanes(
                actual: count,
                maximum: maximumClipPlaneCount
            )
        }
    }
}

package struct ProjectedDepositionRecord: Equatable, Sendable {
    package let identity: UInt64
    package let componentOrdinal: UInt8
    package let instance: PatternDepositionStampInstance
    package let radialPage: RadialPageCoordinate?

    package init(
        identity: UInt64,
        componentOrdinal: UInt8 = 0,
        instance: PatternDepositionStampInstance,
        radialPage: RadialPageCoordinate?
    ) {
        self.identity = identity
        self.componentOrdinal = componentOrdinal
        self.instance = instance
        self.radialPage = radialPage
    }

    package static func == (
        lhs: ProjectedDepositionRecord,
        rhs: ProjectedDepositionRecord
    ) -> Bool {
        lhs.identity == rhs.identity
            && lhs.componentOrdinal == rhs.componentOrdinal
            && lhs.radialPage == rhs.radialPage
            && lhs.instance.hasSameFrozenFields(as: rhs.instance)
    }
}

extension PatternDepositionStampInstance {
    package init(
        fragment: CellFragment,
        dab: LogicalDab,
        logicalOrdinal: UInt64,
        isometryOrdinal: UInt8
    ) throws {
        try DepositionStampPacker.validateClipPlaneCount(
            fragment.brushClip.halfPlanes.count
        )
        guard dab.radius.isFinite else {
            throw DepositionStampPackingError.nonfiniteField("radius")
        }
        guard dab.radius > 0 else {
            throw DepositionStampPackingError.invalidRadius
        }
        try Self.requireFinite(dab.strokeOpacity, field: "strokeOpacity")
        try Self.requireFinite(dab.flow, field: "flow")
        try Self.requireFinite(dab.hardness, field: "hardness")
        try Self.requireFinite(
            dab.materialContribution,
            field: "materialContribution"
        )

        let worldToCanonical = try Self.worldToCanonical(
            brushToWorld: dab.brushToWorld,
            brushToCanonical: fragment.canonicalFromBrush
        )
        let primaryGrainToCanonical = dab.primaryGrainToWorld?
            .concatenating(worldToCanonical)
        let secondaryGrainToCanonical = dab.secondaryGrainToWorld?
            .concatenating(worldToCanonical)
        let packedClips = Self.packClips(fragment.brushClip.halfPlanes)
        let premultipliedColor = DocumentColorPipeline.packShaderColor(
            EncodedSRGBColor(dab.color)
        )
        let identityFlags = dab.isPredicted
            ? DepositionIdentityFlags.predicted
            : 0
        let shapeFlags = fragment.operation.reflected
            ? DepositionShapeFlags.reflected
            : 0
        var grainFlags: UInt32 = 0
        if primaryGrainToCanonical != nil {
            grainFlags |= DepositionGrainFlags.primary
        }
        if secondaryGrainToCanonical != nil {
            grainFlags |= DepositionGrainFlags.secondary
        }
        let ordinal = (
            low: UInt32(truncatingIfNeeded: logicalOrdinal),
            high: UInt32(truncatingIfNeeded: logicalOrdinal >> 32)
        )

        self.init(
            tipFrame0: Self.axes(fragment.canonicalFromBrush),
            tipFrame1: SIMD4(
                fragment.canonicalFromBrush.translation.x,
                fragment.canonicalFromBrush.translation.y,
                dab.radius,
                0
            ),
            primaryGrainFrame0: primaryGrainToCanonical
                .map(Self.axes) ?? .zero,
            primaryGrainFrame1: primaryGrainToCanonical
                .map(Self.translation) ?? .zero,
            secondaryGrainFrame0: secondaryGrainToCanonical
                .map(Self.axes) ?? .zero,
            secondaryGrainFrame1: secondaryGrainToCanonical
                .map(Self.translation) ?? .zero,
            premultipliedColor: premultipliedColor,
            coverageInputs: SIMD4(
                dab.strokeOpacity,
                dab.flow,
                dab.hardness,
                dab.materialContribution
            ),
            clip0: packedClips.clip0,
            clip1: packedClips.clip1,
            clip2: packedClips.clip2,
            clip3: packedClips.clip3,
            identity: SIMD4(
                ordinal.low,
                ordinal.high,
                UInt32(isometryOrdinal),
                identityFlags
            ),
            metadata: SIMD4(
                UInt32(fragment.brushClip.halfPlanes.count),
                shapeFlags,
                grainFlags,
                UInt32(DepositionABI.version)
            ),
            reserved0: .zero,
            reserved1: .zero
        )
    }

    fileprivate func hasSameFrozenFields(
        as other: PatternDepositionStampInstance
    ) -> Bool {
        tipFrame0 == other.tipFrame0
            && tipFrame1 == other.tipFrame1
            && primaryGrainFrame0 == other.primaryGrainFrame0
            && primaryGrainFrame1 == other.primaryGrainFrame1
            && secondaryGrainFrame0 == other.secondaryGrainFrame0
            && secondaryGrainFrame1 == other.secondaryGrainFrame1
            && premultipliedColor == other.premultipliedColor
            && coverageInputs == other.coverageInputs
            && Self.equal(clip0, other.clip0)
            && Self.equal(clip1, other.clip1)
            && Self.equal(clip2, other.clip2)
            && Self.equal(clip3, other.clip3)
            && identity == other.identity
            && metadata == other.metadata
            && reserved0 == other.reserved0
            && reserved1 == other.reserved1
    }

    private static func requireFinite(
        _ value: Float,
        field: String
    ) throws {
        guard value.isFinite else {
            throw DepositionStampPackingError.nonfiniteField(field)
        }
    }

    private static func worldToCanonical(
        brushToWorld: Affine2D,
        brushToCanonical: Affine2D
    ) throws -> Affine2D {
        let determinant =
            brushToWorld.xAxis.x * brushToWorld.yAxis.y
                - brushToWorld.xAxis.y * brushToWorld.yAxis.x
        guard determinant.isFinite,
              abs(determinant) >= Float.ulpOfOne
        else {
            throw DepositionStampPackingError.singularBrushFrame
        }
        return brushToWorld.inverted().concatenating(brushToCanonical)
    }

    private static func packClips(
        _ halfPlanes: HalfPlaneCollection
    ) -> PackedClipPlanes {
        let zero = PatternClipHalfPlane(
            normal: .zero,
            offset: 0,
            padding: 0
        )
        var packed = PackedClipPlanes(
            clip0: zero,
            clip1: zero,
            clip2: zero,
            clip3: zero
        )
        for (index, plane) in halfPlanes.enumerated() {
            let value = PatternClipHalfPlane(
                normal: plane.normal,
                offset: plane.offset,
                padding: 0
            )
            switch index {
            case 0:
                packed.clip0 = value
            case 1:
                packed.clip1 = value
            case 2:
                packed.clip2 = value
            case 3:
                packed.clip3 = value
            default:
                preconditionFailure(
                    "Validated deposition clip count exceeded four"
                )
            }
        }
        return packed
    }

    private static func axes(_ frame: Affine2D) -> SIMD4<Float> {
        SIMD4(
            frame.xAxis.x,
            frame.xAxis.y,
            frame.yAxis.x,
            frame.yAxis.y
        )
    }

    private static func translation(_ frame: Affine2D) -> SIMD4<Float> {
        SIMD4(
            frame.translation.x,
            frame.translation.y,
            0,
            0
        )
    }

    private static func equal(
        _ lhs: PatternClipHalfPlane,
        _ rhs: PatternClipHalfPlane
    ) -> Bool {
        lhs.normal == rhs.normal
            && lhs.offset == rhs.offset
            && lhs.padding == rhs.padding
    }
}

private struct PackedClipPlanes {
    var clip0: PatternClipHalfPlane
    var clip1: PatternClipHalfPlane
    var clip2: PatternClipHalfPlane
    var clip3: PatternClipHalfPlane
}
