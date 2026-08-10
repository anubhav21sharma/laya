import Foundation
import SafeArchive

public enum PatternProjectArchiveError: Error, Equatable, LocalizedError, Sendable {
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
    case injectedSaveFailure

    public var errorDescription: String? {
        switch self {
        case .emptyArchive: "A project archive cannot be empty."
        case .malformedArchive: "The project archive is malformed."
        case .unsupportedZIP64: "ZIP64 project archives are unsupported."
        case let .unsupportedArchiveFlags(path, flags): "Archive entry \(path) uses unsupported flags \(flags)."
        case let .unsupportedCompression(path, method): "Archive entry \(path) uses unsupported compression \(method)."
        case let .unsafePath(path): "Archive entry path \(path) is unsafe."
        case let .duplicateEntry(path): "Archive entry \(path) is duplicated."
        case let .symbolicLink(path): "Archive entry \(path) is a symbolic link."
        case let .entryCountOutOfRange(count): "Archive entry count \(count) is outside the supported range."
        case let .entryTooLarge(path, actual, maximum): "Archive entry \(path) is \(actual) bytes; the limit is \(maximum)."
        case let .archiveTooLarge(actual, maximum): "Expanded archive size \(actual) bytes exceeds \(maximum)."
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
        case .saveFailed: "The project archive could not be saved."
        case .injectedSaveFailure: "The injected project-save failure occurred."
        }
    }
}

public struct PatternProjectArchive: Sendable {
    public let paths: [String]
    private let archive: SafeArchive

    fileprivate init(_ archive: SafeArchive) {
        self.archive = archive
        paths = archive.paths
    }

    public func data(for path: String) throws -> Data {
        do { return try archive.data(for: path) }
        catch let error as SafeArchiveError { throw PatternProjectArchiveError(error) }
    }

    public func data(
        for path: String,
        maximumByteCount: UInt64
    ) throws -> Data {
        do {
            return try archive.data(
                for: path,
                maximumByteCount: maximumByteCount
            )
        } catch let error as SafeArchiveError {
            throw PatternProjectArchiveError(error)
        }
    }

    public func byteCount(for path: String) throws -> Int {
        do { return try archive.byteCount(for: path) }
        catch let error as SafeArchiveError {
            throw PatternProjectArchiveError(error)
        }
    }

    public func consumeEntry(
        at path: String,
        maximumChunkByteCount: Int,
        consume: (Data) throws -> Void
    ) throws {
        do {
            try archive.consumeEntry(
                at: path,
                maximumChunkByteCount: maximumChunkByteCount,
                consume: consume
            )
        } catch let error as SafeArchiveError {
            throw PatternProjectArchiveError(error)
        }
    }
}

public enum PatternProjectArchiveCodec {
    public static let maximumEntryCount = 16_384
    public static let maximumEntryBytes: UInt64 = 256 * 1_024 * 1_024
    public static let maximumExpandedBytes: UInt64 = 1_024 * 1_024 * 1_024

    static let limits = SafeArchiveLimits(
        maximumEntryCount: maximumEntryCount,
        maximumEntryBytes: maximumEntryBytes,
        maximumExpandedBytes: maximumExpandedBytes,
        maximumPathBytes: 512
    )

    public static func encode(entries: [String: Data]) throws -> Data {
        do { return try SafeArchiveCodec.encode(entries: entries, limits: limits) }
        catch let error as SafeArchiveError { throw PatternProjectArchiveError(error) }
    }

    public static func open(_ data: Data) throws -> PatternProjectArchive {
        do { return PatternProjectArchive(try SafeArchiveCodec.open(data, limits: limits)) }
        catch let error as SafeArchiveError { throw PatternProjectArchiveError(error) }
    }

    public static func open(at url: URL) throws -> PatternProjectArchive {
        do { return try open(Data(contentsOf: url, options: [.mappedIfSafe])) }
        catch let error as PatternProjectArchiveError { throw error }
        catch { throw PatternProjectArchiveError.malformedArchive }
    }
}

public enum PatternProjectArchiveIO {
    public static func save(entries: [String: Data], to destination: URL) throws {
        do { try SafeArchiveIO.save(entries: entries, to: destination, limits: PatternProjectArchiveCodec.limits) }
        catch let error as SafeArchiveError { throw PatternProjectArchiveError(error) }
    }
}

enum PatternProjectArchiveSaveInjection: Equatable { case none; case beforeReplacement }

extension PatternProjectArchiveIO {
    static func save(
        entries: [String: Data],
        to destination: URL,
        injecting failure: PatternProjectArchiveSaveInjection
    ) throws {
        do {
            try SafeArchiveIO.save(
                entries: entries,
                to: destination,
                limits: PatternProjectArchiveCodec.limits,
                beforeReplacement: { _ in
                    if failure == .beforeReplacement {
                        throw SafeArchiveSaveHookError.beforeReplacement
                    }
                }
            )
        } catch let error as SafeArchiveError {
            throw PatternProjectArchiveError(error)
        } catch SafeArchiveSaveHookError.beforeReplacement {
            throw PatternProjectArchiveError.injectedSaveFailure
        }
    }
}

extension PatternProjectArchiveError {
    init(_ error: SafeArchiveError) {
        switch error {
        case .emptyArchive: self = .emptyArchive
        case .malformedArchive: self = .malformedArchive
        case .unsupportedZIP64: self = .unsupportedZIP64
        case let .unsupportedArchiveFlags(path, flags): self = .unsupportedArchiveFlags(path: path, flags: flags)
        case let .unsupportedCompression(path, method): self = .unsupportedCompression(path: path, method: method)
        case let .unsafePath(path): self = .unsafePath(path)
        case let .duplicateEntry(path): self = .duplicateEntry(path)
        case let .symbolicLink(path): self = .symbolicLink(path)
        case let .entryCountOutOfRange(count): self = .entryCountOutOfRange(count)
        case let .entryTooLarge(path, actual, maximum): self = .entryTooLarge(path: path, actual: actual, maximum: maximum)
        case let .archiveTooLarge(actual, maximum): self = .archiveTooLarge(actual: actual, maximum: maximum)
        case let .checksumMismatch(path): self = .checksumMismatch(path)
        case let .missingEntry(path): self = .missingEntry(path)
        case let .invalidChunkByteCount(count):
            self = .invalidChunkByteCount(count)
        case let .emptyChunk(path): self = .emptyChunk(path)
        case let .chunkTooLarge(path, actual, maximum):
            self = .chunkTooLarge(
                path: path,
                actual: actual,
                maximum: maximum
            )
        case let .entrySizeMismatch(path, expected, actual):
            self = .entrySizeMismatch(
                path: path,
                expected: expected,
                actual: actual
            )
        case .saveFailed: self = .saveFailed
        }
    }
}
