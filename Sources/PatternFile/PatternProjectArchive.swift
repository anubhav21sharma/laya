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
}

public enum PatternProjectArchiveCodec {
    public static let maximumEntryCount = 16_384
    public static let maximumEntryBytes: UInt64 = 256 * 1_024 * 1_024
    public static let maximumExpandedBytes: UInt64 = 1_024 * 1_024 * 1_024

    fileprivate static let limits = SafeArchiveLimits(
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

public extension PatternPaintTileCodec {
    static func decodeArchive(
        _ archive: PatternProjectArchive,
        surfaceManifestPaths: [String],
        maximumDecodedBytes: Int = PatternPaintTileCodec.maximumDecodedBytes
    ) throws -> [PatternPaintTileSurface] {
        guard (1...maximumLayerCount).contains(surfaceManifestPaths.count)
        else {
            throw PatternPaintTileError.layerCountOutOfRange(
                surfaceManifestPaths.count
            )
        }
        var manifestPaths = Set<String>()
        for path in surfaceManifestPaths {
            guard manifestPaths.insert(path).inserted else {
                throw PatternPaintTileError.duplicatePath(path)
            }
        }
        var surfaces: [PatternPaintTileSurface] = []
        surfaces.reserveCapacity(surfaceManifestPaths.count)

        for path in surfaceManifestPaths {
            let byteCount: Int
            do {
                byteCount = try archive.byteCount(for: path)
            } catch {
                throw PatternPaintTileError.missingPayload(path)
            }
            guard byteCount <= maximumManifestBytes else {
                throw PatternPaintTileError.invalidManifest
            }
        }
        for path in surfaceManifestPaths {
            let data: Data
            do {
                data = try archive.data(
                    for: path,
                    maximumByteCount: UInt64(maximumManifestBytes)
                )
            } catch {
                throw PatternPaintTileError.missingPayload(path)
            }
            surfaces.append(try decodeManifestMetadata(
                data,
                maximumDecodedBytes: maximumDecodedBytes
            ))
        }
        try validateMetadata(
            surfaces,
            maximumDecodedBytes: maximumDecodedBytes
        )

        var tileCount = 0
        var decodedBytes = 0
        for surface in surfaces {
            let (count, countOverflow) = tileCount.addingReportingOverflow(
                surface.tiles.count
            )
            guard !countOverflow else {
                throw PatternPaintTileError.tileCountOutOfRange(
                    actual: Int.max,
                    maximum: maximumDecodedBytes
                        / PatternPaintTileCodec.bytesPerTile
                )
            }
            tileCount = count
            for record in surface.tiles {
                guard !manifestPaths.contains(record.file) else {
                    throw PatternPaintTileError.duplicatePath(record.file)
                }
                let byteCount: Int
                do {
                    byteCount = try archive.byteCount(for: record.file)
                } catch {
                    throw PatternPaintTileError.missingPayload(record.file)
                }
                guard byteCount == record.byteCount else {
                    throw PatternPaintTileError.payloadByteCountMismatch(
                        tileID: record.id,
                        expected: record.byteCount,
                        actual: byteCount
                    )
                }
                let (sum, overflow) = decodedBytes.addingReportingOverflow(
                    byteCount
                )
                let actual = overflow ? Int.max : sum
                guard !overflow, actual <= maximumDecodedBytes else {
                    throw PatternPaintTileError.decodedByteLimitExceeded(
                        actual: actual,
                        maximum: maximumDecodedBytes
                    )
                }
                decodedBytes = sum
            }
        }

        var payloads: [String: Data] = [:]
        payloads.reserveCapacity(tileCount)
        for surface in surfaces {
            for record in surface.tiles {
                let payload: Data
                do {
                    payload = try archive.data(
                        for: record.file,
                        maximumByteCount: UInt64(record.byteCount)
                    )
                } catch {
                    throw PatternPaintTileError.missingPayload(record.file)
                }
                guard payloads.updateValue(payload, forKey: record.file) == nil
                else {
                    throw PatternPaintTileError.duplicatePath(record.file)
                }
            }
        }
        try validate(
            surfaces,
            payloadsByPath: payloads,
            maximumDecodedBytes: maximumDecodedBytes
        )
        return surfaces
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

private extension PatternProjectArchiveError {
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
        case .saveFailed: self = .saveFailed
        }
    }
}
