import Foundation

public enum PatternProjectArchiveError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
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
        case .emptyArchive:
            "A project archive cannot be empty."
        case .malformedArchive:
            "The project archive is malformed."
        case .unsupportedZIP64:
            "ZIP64 project archives are unsupported."
        case let .unsupportedArchiveFlags(path, flags):
            "Archive entry \(path) uses unsupported flags \(flags)."
        case let .unsupportedCompression(path, method):
            "Archive entry \(path) uses unsupported compression \(method)."
        case let .unsafePath(path):
            "Archive entry path \(path) is unsafe."
        case let .duplicateEntry(path):
            "Archive entry \(path) is duplicated."
        case let .symbolicLink(path):
            "Archive entry \(path) is a symbolic link."
        case let .entryCountOutOfRange(count):
            "Archive entry count \(count) is outside the supported range."
        case let .entryTooLarge(path, actual, maximum):
            "Archive entry \(path) is \(actual) bytes; the limit is \(maximum)."
        case let .archiveTooLarge(actual, maximum):
            "Expanded archive size \(actual) bytes exceeds \(maximum)."
        case let .checksumMismatch(path):
            "Archive entry \(path) failed its checksum."
        case let .missingEntry(path):
            "Archive entry \(path) is missing."
        case .saveFailed:
            "The project archive could not be saved."
        case .injectedSaveFailure:
            "The injected project-save failure occurred."
        }
    }
}

public struct PatternProjectArchive: Sendable {
    public let paths: [String]

    private let storage: Data
    private let records: [String: PatternProjectArchiveEntryRecord]

    fileprivate init(
        storage: Data,
        records: [String: PatternProjectArchiveEntryRecord]
    ) {
        self.storage = storage
        self.records = records
        paths = records.keys.sorted()
    }

    public func data(for path: String) throws -> Data {
        guard let record = records[path] else {
            throw PatternProjectArchiveError.missingEntry(path)
        }
        return storage.subdata(in: record.dataRange)
    }
}

public enum PatternProjectArchiveCodec {
    public static let maximumEntryCount = 16_384
    public static let maximumEntryBytes: UInt64 = 256 * 1_024 * 1_024
    public static let maximumExpandedBytes: UInt64 = 1_024 * 1_024 * 1_024

    public static func encode(
        entries: [String: Data]
    ) throws -> Data {
        guard !entries.isEmpty else {
            throw PatternProjectArchiveError.emptyArchive
        }
        guard entries.count <= maximumEntryCount,
              entries.count <= Int(UInt16.max)
        else {
            throw PatternProjectArchiveError.entryCountOutOfRange(
                entries.count
            )
        }

        var total: UInt64 = 0
        var validated: [(path: String, name: Data, data: Data)] = []
        validated.reserveCapacity(entries.count)
        for path in entries.keys.sorted() {
            try validateArchivePath(path)
            let data = entries[path]!
            let count = UInt64(data.count)
            guard count <= maximumEntryBytes else {
                throw PatternProjectArchiveError.entryTooLarge(
                    path: path,
                    actual: count,
                    maximum: maximumEntryBytes
                )
            }
            let (nextTotal, overflow) = total.addingReportingOverflow(count)
            guard !overflow, nextTotal <= maximumExpandedBytes else {
                throw PatternProjectArchiveError.archiveTooLarge(
                    actual: overflow ? UInt64.max : nextTotal,
                    maximum: maximumExpandedBytes
                )
            }
            total = nextTotal
            guard let name = path.data(using: .utf8),
                  name.count <= Int(UInt16.max)
            else {
                throw PatternProjectArchiveError.unsafePath(path)
            }
            validated.append((path, name, data))
        }

        var output = Data()
        var central: [CentralWriteRecord] = []
        central.reserveCapacity(validated.count)
        for entry in validated {
            guard output.count <= Int(UInt32.max),
                  entry.data.count <= Int(UInt32.max)
            else {
                throw PatternProjectArchiveError.unsupportedZIP64
            }
            let offset = UInt32(output.count)
            let size = UInt32(entry.data.count)
            let checksum = CRC32.checksum(entry.data)
            output.appendUInt32(ZipSignature.localFile)
            output.appendUInt16(20)
            output.appendUInt16(ZipFlag.utf8)
            output.appendUInt16(ZipCompression.stored)
            output.appendUInt16(0)
            output.appendUInt16(ZipDate.firstJanuary1980)
            output.appendUInt32(checksum)
            output.appendUInt32(size)
            output.appendUInt32(size)
            output.appendUInt16(UInt16(entry.name.count))
            output.appendUInt16(0)
            output.append(entry.name)
            output.append(entry.data)
            central.append(CentralWriteRecord(
                path: entry.path,
                name: entry.name,
                checksum: checksum,
                size: size,
                localOffset: offset
            ))
        }

        guard output.count <= Int(UInt32.max) else {
            throw PatternProjectArchiveError.unsupportedZIP64
        }
        let centralOffset = UInt32(output.count)
        for entry in central {
            output.appendUInt32(ZipSignature.centralDirectory)
            output.appendUInt16(ZipVersion.unix20)
            output.appendUInt16(20)
            output.appendUInt16(ZipFlag.utf8)
            output.appendUInt16(ZipCompression.stored)
            output.appendUInt16(0)
            output.appendUInt16(ZipDate.firstJanuary1980)
            output.appendUInt32(entry.checksum)
            output.appendUInt32(entry.size)
            output.appendUInt32(entry.size)
            output.appendUInt16(UInt16(entry.name.count))
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt32(ZipExternalAttribute.regularFile0644)
            output.appendUInt32(entry.localOffset)
            output.append(entry.name)
        }
        let centralSize = output.count - Int(centralOffset)
        guard centralSize <= Int(UInt32.max) else {
            throw PatternProjectArchiveError.unsupportedZIP64
        }
        output.appendUInt32(ZipSignature.endOfCentralDirectory)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(central.count))
        output.appendUInt16(UInt16(central.count))
        output.appendUInt32(UInt32(centralSize))
        output.appendUInt32(centralOffset)
        output.appendUInt16(0)
        return output
    }

    public static func open(
        _ data: Data
    ) throws -> PatternProjectArchive {
        let eocdOffset = try findEndOfCentralDirectory(in: data)
        let disk = try data.uint16(at: eocdOffset + 4)
        let centralDisk = try data.uint16(at: eocdOffset + 6)
        let entriesOnDisk = try data.uint16(at: eocdOffset + 8)
        let entryCount = try data.uint16(at: eocdOffset + 10)
        let centralSize = try data.uint32(at: eocdOffset + 12)
        let centralOffset = try data.uint32(at: eocdOffset + 16)
        let commentLength = try data.uint16(at: eocdOffset + 20)
        guard disk == 0,
              centralDisk == 0,
              entriesOnDisk == entryCount,
              eocdOffset + 22 + Int(commentLength) == data.count
        else {
            throw PatternProjectArchiveError.malformedArchive
        }
        guard entryCount > 0 else {
            throw PatternProjectArchiveError.emptyArchive
        }
        guard Int(entryCount) <= maximumEntryCount else {
            throw PatternProjectArchiveError.entryCountOutOfRange(
                Int(entryCount)
            )
        }
        guard centralSize != UInt32.max,
              centralOffset != UInt32.max
        else {
            throw PatternProjectArchiveError.unsupportedZIP64
        }
        let centralStart = Int(centralOffset)
        let (centralEnd, centralOverflow) = centralStart
            .addingReportingOverflow(Int(centralSize))
        guard !centralOverflow,
              centralStart >= 0,
              centralEnd == eocdOffset,
              centralEnd <= data.count
        else {
            throw PatternProjectArchiveError.malformedArchive
        }

        var cursor = centralStart
        var records: [String: PatternProjectArchiveEntryRecord] = [:]
        records.reserveCapacity(Int(entryCount))
        var localRanges: [Range<Int>] = []
        localRanges.reserveCapacity(Int(entryCount))
        var total: UInt64 = 0
        for _ in 0..<entryCount {
            guard try data.uint32(at: cursor)
                    == ZipSignature.centralDirectory
            else {
                throw PatternProjectArchiveError.malformedArchive
            }
            let versionMadeBy = try data.uint16(at: cursor + 4)
            let flags = try data.uint16(at: cursor + 8)
            let method = try data.uint16(at: cursor + 10)
            let checksum = try data.uint32(at: cursor + 16)
            let compressedSize = try data.uint32(at: cursor + 20)
            let expandedSize = try data.uint32(at: cursor + 24)
            let nameLength = Int(try data.uint16(at: cursor + 28))
            let extraLength = Int(try data.uint16(at: cursor + 30))
            let entryCommentLength = Int(
                try data.uint16(at: cursor + 32)
            )
            let entryDisk = try data.uint16(at: cursor + 34)
            let externalAttributes = try data.uint32(at: cursor + 38)
            let localOffset = try data.uint32(at: cursor + 42)
            let headerEnd = try checkedEnd(
                start: cursor,
                lengths: [46, nameLength, extraLength, entryCommentLength],
                limit: centralEnd
            )
            let nameRange = (cursor + 46)..<(cursor + 46 + nameLength)
            guard let path = String(
                data: data.subdata(in: nameRange),
                encoding: .utf8
            ) else {
                throw PatternProjectArchiveError.malformedArchive
            }
            try validateArchivePath(path)
            guard records[path] == nil else {
                throw PatternProjectArchiveError.duplicateEntry(path)
            }
            guard entryDisk == 0 else {
                throw PatternProjectArchiveError.malformedArchive
            }
            try validateFlags(flags, path: path)
            guard method == ZipCompression.stored else {
                throw PatternProjectArchiveError.unsupportedCompression(
                    path: path,
                    method: method
                )
            }
            guard compressedSize == expandedSize else {
                throw PatternProjectArchiveError.malformedArchive
            }
            let expanded = UInt64(expandedSize)
            guard expanded <= maximumEntryBytes else {
                throw PatternProjectArchiveError.entryTooLarge(
                    path: path,
                    actual: expanded,
                    maximum: maximumEntryBytes
                )
            }
            let (newTotal, totalOverflow) = total.addingReportingOverflow(
                expanded
            )
            guard !totalOverflow, newTotal <= maximumExpandedBytes else {
                throw PatternProjectArchiveError.archiveTooLarge(
                    actual: totalOverflow ? UInt64.max : newTotal,
                    maximum: maximumExpandedBytes
                )
            }
            total = newTotal
            if versionMadeBy >> 8 == ZipVersion.unixHost {
                let fileType = (externalAttributes >> 16) & 0xF000
                guard fileType != ZipExternalAttribute.symbolicLink else {
                    throw PatternProjectArchiveError.symbolicLink(path)
                }
                guard fileType != ZipExternalAttribute.directory else {
                    throw PatternProjectArchiveError.unsafePath(path)
                }
            }

            let local = Int(localOffset)
            guard try data.uint32(at: local) == ZipSignature.localFile
            else {
                throw PatternProjectArchiveError.malformedArchive
            }
            let localFlags = try data.uint16(at: local + 6)
            let localMethod = try data.uint16(at: local + 8)
            let localChecksum = try data.uint32(at: local + 14)
            let localCompressedSize = try data.uint32(at: local + 18)
            let localExpandedSize = try data.uint32(at: local + 22)
            let localNameLength = Int(try data.uint16(at: local + 26))
            let localExtraLength = Int(try data.uint16(at: local + 28))
            try validateFlags(localFlags, path: path)
            guard localFlags == flags,
                  localMethod == method,
                  localChecksum == checksum,
                  localCompressedSize == compressedSize,
                  localExpandedSize == expandedSize,
                  localNameLength == nameLength
            else {
                throw PatternProjectArchiveError.malformedArchive
            }
            let localHeaderEnd = try checkedEnd(
                start: local,
                lengths: [30, localNameLength, localExtraLength],
                limit: centralStart
            )
            let localNameRange =
                (local + 30)..<(local + 30 + localNameLength)
            guard data.subdata(in: localNameRange)
                    == data.subdata(in: nameRange)
            else {
                throw PatternProjectArchiveError.malformedArchive
            }
            let dataEnd = try checkedEnd(
                start: localHeaderEnd,
                lengths: [Int(compressedSize)],
                limit: centralStart
            )
            let dataRange = localHeaderEnd..<dataEnd
            let completeLocalRange = local..<dataEnd
            guard localRanges.allSatisfy({
                !$0.overlaps(completeLocalRange)
            }) else {
                throw PatternProjectArchiveError.malformedArchive
            }
            guard CRC32.checksum(data, range: dataRange) == checksum else {
                throw PatternProjectArchiveError.checksumMismatch(path)
            }
            localRanges.append(completeLocalRange)
            records[path] = PatternProjectArchiveEntryRecord(
                dataRange: dataRange
            )
            cursor = headerEnd
        }
        guard cursor == centralEnd else {
            throw PatternProjectArchiveError.malformedArchive
        }
        return PatternProjectArchive(storage: data, records: records)
    }

    public static func open(
        at url: URL
    ) throws -> PatternProjectArchive {
        do {
            return try open(Data(contentsOf: url, options: [.mappedIfSafe]))
        } catch let error as PatternProjectArchiveError {
            throw error
        } catch {
            throw PatternProjectArchiveError.malformedArchive
        }
    }
}

public enum PatternProjectArchiveIO {
    public static func save(
        entries: [String: Data],
        to destination: URL
    ) throws {
        try save(entries: entries, to: destination, injecting: .none)
    }
}

enum PatternProjectArchiveSaveInjection: Equatable {
    case none
    case beforeReplacement
}

extension PatternProjectArchiveIO {
    static func save(
        entries: [String: Data],
        to destination: URL,
        injecting failure: PatternProjectArchiveSaveInjection
    ) throws {
        let archive = try PatternProjectArchiveCodec.encode(entries: entries)
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try archive.write(to: temporary, options: [.withoutOverwriting])
            _ = try PatternProjectArchiveCodec.open(at: temporary)
            if failure == .beforeReplacement {
                throw PatternProjectArchiveError.injectedSaveFailure
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(
                    at: temporary,
                    to: destination
                )
            }
        } catch let error as PatternProjectArchiveError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw PatternProjectArchiveError.saveFailed
        }
    }
}

private struct PatternProjectArchiveEntryRecord: Sendable {
    let dataRange: Range<Int>
}

private struct CentralWriteRecord {
    let path: String
    let name: Data
    let checksum: UInt32
    let size: UInt32
    let localOffset: UInt32
}

private enum ZipSignature {
    static let localFile: UInt32 = 0x0403_4B50
    static let centralDirectory: UInt32 = 0x0201_4B50
    static let endOfCentralDirectory: UInt32 = 0x0605_4B50
}

private enum ZipCompression {
    static let stored: UInt16 = 0
}

private enum ZipFlag {
    static let utf8: UInt16 = 1 << 11
}

private enum ZipDate {
    static let firstJanuary1980: UInt16 = 0x0021
}

private enum ZipVersion {
    static let unix20: UInt16 = 0x0314
    static let unixHost: UInt16 = 3
}

private enum ZipExternalAttribute {
    static let regularFile0644: UInt32 = 0x81A4_0000
    static let symbolicLink: UInt32 = 0xA000
    static let directory: UInt32 = 0x4000
}

private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { value in
        var result = UInt32(value)
        for _ in 0..<8 {
            result = (result & 1) == 0
                ? result >> 1
                : 0xEDB8_8320 ^ (result >> 1)
        }
        return result
    }

    static func checksum(_ data: Data) -> UInt32 {
        checksum(data, range: 0..<data.count)
    }

    static func checksum(
        _ data: Data,
        range: Range<Int>
    ) -> UInt32 {
        var result = UInt32.max
        for index in range {
            let tableIndex = Int((result ^ UInt32(data[index])) & 0xFF)
            result = table[tableIndex] ^ (result >> 8)
        }
        return result ^ UInt32.max
    }
}

private func validateArchivePath(_ path: String) throws {
    guard !path.isEmpty,
          path.utf8.count <= 512,
          !path.hasPrefix("/"),
          !path.contains("\\"),
          !path.contains("\0")
    else {
        throw PatternProjectArchiveError.unsafePath(path)
    }
    let components = path.split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    guard !components.isEmpty,
          components.allSatisfy({
              !$0.isEmpty && $0 != "." && $0 != ".."
          })
    else {
        throw PatternProjectArchiveError.unsafePath(path)
    }
}

private func validateFlags(
    _ flags: UInt16,
    path: String
) throws {
    guard flags & ~ZipFlag.utf8 == 0 else {
        throw PatternProjectArchiveError.unsupportedArchiveFlags(
            path: path,
            flags: flags
        )
    }
}

private func findEndOfCentralDirectory(
    in data: Data
) throws -> Int {
    guard data.count >= 22 else {
        throw PatternProjectArchiveError.malformedArchive
    }
    let lowerBound = max(0, data.count - 22 - Int(UInt16.max))
    for offset in stride(
        from: data.count - 22,
        through: lowerBound,
        by: -1
    ) {
        if try data.uint32(at: offset)
            == ZipSignature.endOfCentralDirectory,
           let commentLength = try? data.uint16(at: offset + 20),
           offset + 22 + Int(commentLength) == data.count
        {
            return offset
        }
    }
    throw PatternProjectArchiveError.malformedArchive
}

private func checkedEnd(
    start: Int,
    lengths: [Int],
    limit: Int
) throws -> Int {
    var value = start
    for length in lengths {
        guard length >= 0 else {
            throw PatternProjectArchiveError.malformedArchive
        }
        let (next, overflow) = value.addingReportingOverflow(length)
        guard !overflow, next <= limit else {
            throw PatternProjectArchiveError.malformedArchive
        }
        value = next
    }
    return value
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    func uint16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else {
            throw PatternProjectArchiveError.malformedArchive
        }
        return UInt16(self[offset])
            | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else {
            throw PatternProjectArchiveError.malformedArchive
        }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
