import PatternEngine

public enum RasterRevisionOperationOutcome: Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
}

public struct PendingRasterRevisionPair: Equatable, Sendable {
    public let before: RasterRevisionReference
    public let after: RasterRevisionReference

    init(
        before: RasterRevisionReference,
        after: RasterRevisionReference
    ) {
        precondition(before.id != after.id)
        self.before = before
        self.after = after
    }

    public var retainedBytes: Int {
        before.retainedBytes + after.retainedBytes
    }

    public var revisionIDs: Set<StoredRasterRevisionID> {
        Set([before.id, after.id])
    }
}
