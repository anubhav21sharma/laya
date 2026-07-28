import Foundation

struct ForeignPropertyListLimits: Equatable, Sendable {
    static let standard = ForeignPropertyListLimits()

    let maximumInputBytes: Int
    let maximumGraphDepth: Int
    let maximumCollectionElements: Int
    let maximumTotalNodes: Int
    let maximumStringUTF8Bytes: Int
    let maximumOpaqueDataBytes: Int
    let maximumXMLTextUTF8Bytes: Int
    let maximumTotalCollectionReferences: Int
    let maximumTotalResolvedUIDReferences: Int

    init(
        maximumInputBytes: Int = 512 * 1_024 * 1_024,
        maximumGraphDepth: Int = 64,
        maximumCollectionElements: Int = 16_384,
        maximumTotalNodes: Int = 100_000,
        maximumStringUTF8Bytes: Int = 64 * 1_024,
        maximumOpaqueDataBytes: Int = 256 * 1_024 * 1_024,
        maximumXMLTextUTF8Bytes: Int = 512 * 1_024 * 1_024,
        maximumTotalCollectionReferences: Int = 100_000,
        maximumTotalResolvedUIDReferences: Int = 100_000
    ) {
        precondition(maximumInputBytes >= 0)
        precondition(maximumGraphDepth >= 0)
        precondition(maximumCollectionElements >= 0)
        precondition(maximumTotalNodes >= 0)
        precondition(maximumStringUTF8Bytes >= 0)
        precondition(maximumOpaqueDataBytes >= 0)
        precondition(maximumXMLTextUTF8Bytes >= 0)
        precondition(maximumTotalCollectionReferences >= 0)
        precondition(maximumTotalResolvedUIDReferences >= 0)
        self.maximumInputBytes = maximumInputBytes
        self.maximumGraphDepth = maximumGraphDepth
        self.maximumCollectionElements = maximumCollectionElements
        self.maximumTotalNodes = maximumTotalNodes
        self.maximumStringUTF8Bytes = maximumStringUTF8Bytes
        self.maximumOpaqueDataBytes = maximumOpaqueDataBytes
        self.maximumXMLTextUTF8Bytes = maximumXMLTextUTF8Bytes
        self.maximumTotalCollectionReferences =
            maximumTotalCollectionReferences
        self.maximumTotalResolvedUIDReferences =
            maximumTotalResolvedUIDReferences
    }
}
