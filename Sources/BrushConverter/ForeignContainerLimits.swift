import Foundation

struct ForeignContainerLimits: Equatable, Sendable {
    static let standard = ForeignContainerLimits()

    let maximumSourceBytes: Int
    let maximumEntriesPerContainer: Int
    let maximumNestedEntries: Int
    let maximumNestingDepth: Int
    let maximumExpandedBytes: Int
    let maximumExpandedBytesPerEntry: Int
    let maximumCompressionRatio: Int
    let maximumPathUTF8Bytes: Int
    let streamingChunkBytes: Int

    init(
        maximumSourceBytes: Int = 512 * 1_024 * 1_024,
        maximumEntriesPerContainer: Int = 4_096,
        maximumNestedEntries: Int = 4_096,
        maximumNestingDepth: Int = 2,
        maximumExpandedBytes: Int = 1_024 * 1_024 * 1_024,
        maximumExpandedBytesPerEntry: Int = 256 * 1_024 * 1_024,
        maximumCompressionRatio: Int = 200,
        maximumPathUTF8Bytes: Int = 1_024,
        streamingChunkBytes: Int = 32 * 1_024
    ) {
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumEntriesPerContainer = maximumEntriesPerContainer
        self.maximumNestedEntries = maximumNestedEntries
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumExpandedBytesPerEntry = maximumExpandedBytesPerEntry
        self.maximumCompressionRatio = maximumCompressionRatio
        self.maximumPathUTF8Bytes = maximumPathUTF8Bytes
        self.streamingChunkBytes = streamingChunkBytes
    }

    var isValid: Bool {
        maximumSourceBytes >= 0
            && maximumEntriesPerContainer > 0
            && maximumNestedEntries > 0
            && maximumNestingDepth >= 0
            && maximumExpandedBytes >= 0
            && maximumExpandedBytesPerEntry >= 0
            && maximumCompressionRatio > 0
            && maximumPathUTF8Bytes > 0
            && streamingChunkBytes > 0
            && streamingChunkBytes <= Int(UInt32.max)
    }
}
