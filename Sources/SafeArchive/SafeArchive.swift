import Foundation

public enum SafeArchiveError: Error, Equatable, LocalizedError, Sendable {
    case emptyArchive
    case malformedArchive
    case unsupportedZIP64
    case unsupportedArchiveFlags(path: String, flags: UInt16)
    case unsupportedCompression(path: String, method: UInt16)
    case unsafePath(String)
    case duplicateEntry(String)
    case symbolicLink(String)
    case entryCountOutOfRange(Int)
    case entryTooLarge(path: String, actual: UInt64, maximum: UInt64)
    case archiveTooLarge(actual: UInt64, maximum: UInt64)
    case checksumMismatch(String)
    case missingEntry(String)
    case invalidChunkByteCount(Int)
    case emptyChunk(String)
    case chunkTooLarge(path: String, actual: Int, maximum: Int)
    case entrySizeMismatch(path: String, expected: UInt64, actual: UInt64)
    case saveFailed

    public var errorDescription: String? {
        switch self {
        case .emptyArchive: "An archive cannot be empty."
        case .malformedArchive: "The archive is malformed."
        case .unsupportedZIP64: "ZIP64 archives are unsupported."
        case let .unsupportedArchiveFlags(path, flags):
            "Archive entry \(path) uses unsupported flags \(flags)."
        case let .unsupportedCompression(path, method):
            "Archive entry \(path) uses unsupported compression \(method)."
        case let .unsafePath(path): "Archive entry path \(path) is unsafe."
        case let .duplicateEntry(path): "Archive entry \(path) is duplicated."
        case let .symbolicLink(path): "Archive entry \(path) is a symbolic link."
        case let .entryCountOutOfRange(count):
            "Archive entry count \(count) is outside the supported range."
        case let .entryTooLarge(path, actual, maximum):
            "Archive entry \(path) is \(actual) bytes; the limit is \(maximum)."
        case let .archiveTooLarge(actual, maximum):
            "Expanded archive size \(actual) bytes exceeds \(maximum)."
        case let .checksumMismatch(path): "Archive entry \(path) failed its checksum."
        case let .missingEntry(path): "Archive entry \(path) is missing."
        case let .invalidChunkByteCount(count):
            "Archive chunk size \(count) must be positive."
        case let .emptyChunk(path):
            "Archive entry \(path) produced an empty chunk."
        case let .chunkTooLarge(path, actual, maximum):
            "Archive entry \(path) produced a \(actual)-byte chunk; the limit is \(maximum)."
        case let .entrySizeMismatch(path, expected, actual):
            "Archive entry \(path) produced \(actual) bytes; it declared \(expected)."
        case .saveFailed: "The archive could not be saved."
        }
    }
}

public struct SafeArchiveEntryDescriptor: Equatable, Sendable {
    public let path: String
    public let byteCount: UInt64

    public init(path: String, byteCount: UInt64) {
        self.path = path
        self.byteCount = byteCount
    }
}

/// Synchronous, close-once source of bounded entry chunks. Implementations
/// retain their snapshot/lease until `close()` and must not require the whole
/// archive payload to be materialized.
public protocol SafeArchiveEntryProvider: AnyObject {
    func archiveEntries() throws -> [SafeArchiveEntryDescriptor]
    func provideChunks(
        for path: String,
        maximumChunkByteCount: Int,
        consume: (Data) throws -> Void
    ) throws
    func close()
}

/// Synchronous destination for a fully preflighted archive. A consumer sees
/// sorted entries and bounded chunks, and is closed exactly once on success or
/// on any begin/chunk/finish failure.
public protocol SafeArchiveEntryConsumer: AnyObject {
    func beginEntry(_ entry: SafeArchiveEntryDescriptor) throws
    func consume(_ chunk: Data, for path: String) throws
    func finishEntry(_ entry: SafeArchiveEntryDescriptor) throws
    func close()
}

public struct SafeArchiveLimits: Equatable, Sendable {
    public let maximumEntryCount: Int
    public let maximumEntryBytes: UInt64
    public let maximumExpandedBytes: UInt64
    public let maximumPathBytes: Int

    public init(
        maximumEntryCount: Int,
        maximumEntryBytes: UInt64,
        maximumExpandedBytes: UInt64,
        maximumPathBytes: Int
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumPathBytes = maximumPathBytes
    }
}

public struct SafeArchive: Sendable {
    public let paths: [String]

    private let storage: any SafeArchiveStorage
    private let records: [String: SafeArchiveEntryRecord]

    init(storage: Data, records: [String: SafeArchiveEntryRecord]) {
        self.init(
            storage: SafeArchiveMemoryStorage(data: storage),
            records: records
        )
    }

    init(
        storage: any SafeArchiveStorage,
        records: [String: SafeArchiveEntryRecord]
    ) {
        self.storage = storage
        self.records = records
        paths = records.keys.sorted()
    }

    public func data(for path: String) throws -> Data {
        try data(for: path, maximumByteCount: UInt64.max)
    }

    public func data(
        for path: String,
        maximumByteCount: UInt64
    ) throws -> Data {
        guard let record = records[path] else {
            throw SafeArchiveError.missingEntry(path)
        }
        let byteCount = UInt64(record.dataRange.count)
        guard byteCount <= maximumByteCount else {
            throw SafeArchiveError.entryTooLarge(
                path: path,
                actual: byteCount,
                maximum: maximumByteCount
            )
        }
        let data = try storage.read(record.dataRange)
        guard CRC32.checksum(data) == record.checksum else {
            throw SafeArchiveError.checksumMismatch(path)
        }
        return data
    }

    public func byteCount(for path: String) throws -> Int {
        guard let record = records[path] else {
            throw SafeArchiveError.missingEntry(path)
        }
        return record.dataRange.count
    }

    public func consumeEntries(
        maximumChunkByteCount: Int,
        consumer: any SafeArchiveEntryConsumer
    ) throws {
        defer { consumer.close() }
        guard maximumChunkByteCount > 0 else {
            throw SafeArchiveError.invalidChunkByteCount(
                maximumChunkByteCount
            )
        }
        for path in paths {
            guard let record = records[path] else {
                throw SafeArchiveError.missingEntry(path)
            }
            let entry = SafeArchiveEntryDescriptor(
                path: path,
                byteCount: UInt64(record.dataRange.count)
            )
            try consumer.beginEntry(entry)
            var checksum = CRC32Accumulator()
            var cursor = record.dataRange.lowerBound
            while cursor < record.dataRange.upperBound {
                let end = min(
                    record.dataRange.upperBound,
                    cursor + maximumChunkByteCount
                )
                let chunk = try storage.read(cursor..<end)
                checksum.update(chunk)
                try consumer.consume(chunk, for: path)
                cursor = end
            }
            guard checksum.checksum == record.checksum else {
                throw SafeArchiveError.checksumMismatch(path)
            }
            try consumer.finishEntry(entry)
        }
    }

    public func consumeEntry(
        at path: String,
        maximumChunkByteCount: Int,
        consume: (Data) throws -> Void
    ) throws {
        guard maximumChunkByteCount > 0 else {
            throw SafeArchiveError.invalidChunkByteCount(
                maximumChunkByteCount
            )
        }
        guard let record = records[path] else {
            throw SafeArchiveError.missingEntry(path)
        }
        var checksum = CRC32Accumulator()
        var cursor = record.dataRange.lowerBound
        while cursor < record.dataRange.upperBound {
            let end = min(
                record.dataRange.upperBound,
                cursor + maximumChunkByteCount
            )
            let chunk = try storage.read(cursor..<end)
            checksum.update(chunk)
            try consume(chunk)
            cursor = end
        }
        guard checksum.checksum == record.checksum else {
            throw SafeArchiveError.checksumMismatch(path)
        }
    }
}

struct SafeArchiveEntryRecord: Sendable {
    let dataRange: Range<Int>
    let checksum: UInt32
}

protocol SafeArchiveStorage: Sendable {
    func read(_ range: Range<Int>) throws -> Data
}

private struct SafeArchiveMemoryStorage: SafeArchiveStorage {
    let data: Data

    func read(_ range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= data.count else {
            throw SafeArchiveError.malformedArchive
        }
        return data.subdata(in: range)
    }
}
