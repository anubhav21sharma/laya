public enum FootprintCoverageSymmetry: UInt8, Equatable, Sendable {
    case oriented = 0
    case halfTurnInvariant = 1
    case rotationInvariant = 2
    case reflectionInvariant = 3
    case rotationAndReflectionInvariant = 4
}

public struct StampFootprint: Equatable, Sendable {
    public let brushToWorld: Affine2D
    public let localBounds: AxisAlignedRect
    public let coverageSymmetry: FootprintCoverageSymmetry

    public init(
        brushToWorld: Affine2D,
        localBounds: AxisAlignedRect,
        coverageSymmetry: FootprintCoverageSymmetry
    ) {
        self.brushToWorld = brushToWorld
        self.localBounds = localBounds
        self.coverageSymmetry = coverageSymmetry
    }
}
