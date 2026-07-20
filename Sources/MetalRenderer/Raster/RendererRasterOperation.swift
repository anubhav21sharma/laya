import PatternEngine

public struct RendererOperationToken:
    RawRepresentable, Hashable, Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct RasterMutationReceipt: Equatable, Sendable {
    public let token: RendererOperationToken
    public let before: RasterRevisionReference
    public let after: RasterRevisionReference

    public init(
        token: RendererOperationToken,
        before: RasterRevisionReference,
        after: RasterRevisionReference
    ) {
        self.token = token
        self.before = before
        self.after = after
    }
}

public enum RendererOperationCompletion: Sendable {
    case rasterSuccess(RasterMutationReceipt)
    case operationSuccess(RendererOperationToken)
    case failure(RendererOperationToken, MetalRendererError)
}
