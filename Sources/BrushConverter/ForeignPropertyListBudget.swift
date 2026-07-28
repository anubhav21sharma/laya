import Foundation

final class ForeignPropertyListBudget: @unchecked Sendable {
    let maximumTotalNodes: Int
    let maximumTotalCollectionReferences: Int
    let maximumTotalResolvedUIDReferences: Int

    private let lock = NSLock()
    private var totalNodes = 0
    private var totalCollectionReferences = 0
    private var totalResolvedUIDReferences = 0

    init(limits: ForeignPropertyListLimits = .standard) {
        maximumTotalNodes = limits.maximumTotalNodes
        maximumTotalCollectionReferences =
            limits.maximumTotalCollectionReferences
        maximumTotalResolvedUIDReferences =
            limits.maximumTotalResolvedUIDReferences
    }

    var consumedTotalNodes: Int {
        lock.withLock { totalNodes }
    }

    var consumedTotalCollectionReferences: Int {
        lock.withLock { totalCollectionReferences }
    }

    var consumedTotalResolvedUIDReferences: Int {
        lock.withLock { totalResolvedUIDReferences }
    }

    func isCompatible(with limits: ForeignPropertyListLimits) -> Bool {
        maximumTotalNodes <= limits.maximumTotalNodes
            && maximumTotalCollectionReferences
                <= limits.maximumTotalCollectionReferences
            && maximumTotalResolvedUIDReferences
                <= limits.maximumTotalResolvedUIDReferences
    }

    func reserve(nodes: Int, collectionReferences: Int) throws {
        try lock.withLock {
            let (nextNodes, nodeOverflow) = totalNodes
                .addingReportingOverflow(nodes)
            guard nodes >= 0,
                  !nodeOverflow,
                  nextNodes <= maximumTotalNodes
            else {
                throw ForeignPropertyListError.nodeLimitExceeded(
                    maximum: maximumTotalNodes
                )
            }
            let (nextReferences, referenceOverflow) =
                totalCollectionReferences.addingReportingOverflow(
                    collectionReferences
                )
            guard collectionReferences >= 0,
                  !referenceOverflow,
                  nextReferences <= maximumTotalCollectionReferences
            else {
                throw ForeignPropertyListError
                    .collectionReferenceLimitExceeded(
                        maximum: maximumTotalCollectionReferences
                    )
            }
            totalNodes = nextNodes
            totalCollectionReferences = nextReferences
        }
    }

    func refund(nodes: Int, collectionReferences: Int) {
        lock.withLock {
            totalNodes -= nodes
            totalCollectionReferences -= collectionReferences
        }
    }

    func reserve(resolvedUIDReferences count: Int) throws {
        try lock.withLock {
            let (next, overflow) = totalResolvedUIDReferences
                .addingReportingOverflow(count)
            guard count >= 0,
                  !overflow,
                  next <= maximumTotalResolvedUIDReferences
            else {
                throw ForeignPropertyListError
                    .resolvedUIDReferenceLimitExceeded(
                        maximum: maximumTotalResolvedUIDReferences
                    )
            }
            totalResolvedUIDReferences = next
        }
    }

    func refund(resolvedUIDReferences count: Int) {
        lock.withLock {
            totalResolvedUIDReferences -= count
        }
    }
}
