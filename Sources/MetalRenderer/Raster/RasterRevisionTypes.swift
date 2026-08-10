import Foundation
import PatternEngine

final class RasterRevisionStoreIdentitySource: @unchecked Sendable {
    static let shared = RasterRevisionStoreIdentitySource()

    private let lock = NSLock()
    private var nextIdentity: UInt64 = 1

    func makeIdentity() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        precondition(
            nextIdentity < UInt64.max,
            "Raster revision store identity space exhausted."
        )
        let identity = nextIdentity
        nextIdentity += 1
        return identity
    }
}

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
