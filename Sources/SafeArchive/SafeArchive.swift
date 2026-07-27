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
        case .saveFailed: "The archive could not be saved."
        }
    }
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

    private let storage: Data
    private let records: [String: SafeArchiveEntryRecord]

    init(storage: Data, records: [String: SafeArchiveEntryRecord]) {
        self.storage = storage
        self.records = records
        paths = records.keys.sorted()
    }

    public func data(for path: String) throws -> Data {
        guard let record = records[path] else {
            throw SafeArchiveError.missingEntry(path)
        }
        return storage.subdata(in: record.dataRange)
    }
}

struct SafeArchiveEntryRecord: Sendable {
    let dataRange: Range<Int>
}
