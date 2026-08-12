import Foundation

public enum SafeArchiveCodec {
    public static func encode(
        entries: [String: Data],
        limits: SafeArchiveLimits
    ) throws -> Data {
        let validated = try validateEntryDescriptors(
            entries.map {
                SafeArchiveEntryDescriptor(
                    path: $0.key,
                    byteCount: UInt64($0.value.count)
                )
            },
            limits: limits
        )

        var output = Data()
        var central: [CentralWriteRecord] = []
        central.reserveCapacity(validated.count)
        for entry in validated {
            guard output.count <= Int(UInt32.max),
                  let data = entries[entry.path]
            else {
                throw SafeArchiveError.unsupportedZIP64
            }
            let offset = UInt32(output.count)
            let checksum = CRC32.checksum(data)
            output.append(localHeader(
                name: entry.name,
                checksum: checksum,
                size: entry.size
            ))
            output.append(data)
            central.append(CentralWriteRecord(
                name: entry.name,
                checksum: checksum,
                size: entry.size,
                localOffset: offset
            ))
        }

        guard output.count <= Int(UInt32.max) else { throw SafeArchiveError.unsupportedZIP64 }
        let centralOffset = UInt32(output.count)
        for entry in central {
            output.append(centralHeader(entry))
        }
        let centralSize = output.count - Int(centralOffset)
        guard centralSize <= Int(UInt32.max) else { throw SafeArchiveError.unsupportedZIP64 }
        output.append(endOfCentralDirectory(
            entryCount: central.count,
            centralSize: UInt32(centralSize),
            centralOffset: centralOffset
        ))
        return output
    }

    public static func open(_ data: Data, limits: SafeArchiveLimits) throws -> SafeArchive {
        let eocdOffset = try findEndOfCentralDirectory(in: data)
        let disk = try data.uint16(at: eocdOffset + 4)
        let centralDisk = try data.uint16(at: eocdOffset + 6)
        let entriesOnDisk = try data.uint16(at: eocdOffset + 8)
        let entryCount = try data.uint16(at: eocdOffset + 10)
        let centralSize = try data.uint32(at: eocdOffset + 12)
        let centralOffset = try data.uint32(at: eocdOffset + 16)
        let commentLength = try data.uint16(at: eocdOffset + 20)
        guard disk != UInt16.max,
              centralDisk != UInt16.max,
              entriesOnDisk != UInt16.max,
              entryCount != UInt16.max,
              centralSize != UInt32.max,
              centralOffset != UInt32.max
        else { throw SafeArchiveError.unsupportedZIP64 }
        guard disk == 0, centralDisk == 0, entriesOnDisk == entryCount,
              eocdOffset + 22 + Int(commentLength) == data.count
        else { throw SafeArchiveError.malformedArchive }
        guard entryCount > 0 else { throw SafeArchiveError.emptyArchive }
        guard Int(entryCount) <= limits.maximumEntryCount else {
            throw SafeArchiveError.entryCountOutOfRange(Int(entryCount))
        }
        let centralStart = Int(centralOffset)
        let (centralEnd, centralOverflow) = centralStart.addingReportingOverflow(Int(centralSize))
        guard !centralOverflow, centralStart >= 0, centralEnd <= data.count else {
            throw SafeArchiveError.malformedArchive
        }
        guard centralEnd == eocdOffset else {
            if try hasStructurallyPlacedZIP64EndRecords(
                in: data,
                centralEnd: centralEnd,
                eocdOffset: eocdOffset
            ) {
                throw SafeArchiveError.unsupportedZIP64
            }
            throw SafeArchiveError.malformedArchive
        }

        var cursor = centralStart
        var records: [String: SafeArchiveEntryRecord] = [:]
        records.reserveCapacity(Int(entryCount))
        var localRanges: [Range<Int>] = []
        localRanges.reserveCapacity(Int(entryCount))
        var total: UInt64 = 0
        for _ in 0..<entryCount {
            guard try data.uint32(at: cursor) == ZipSignature.centralDirectory else {
                throw SafeArchiveError.malformedArchive
            }
            let versionMadeBy = try data.uint16(at: cursor + 4)
            let flags = try data.uint16(at: cursor + 8)
            let method = try data.uint16(at: cursor + 10)
            let checksum = try data.uint32(at: cursor + 16)
            let compressedSize = try data.uint32(at: cursor + 20)
            let expandedSize = try data.uint32(at: cursor + 24)
            let nameLength = Int(try data.uint16(at: cursor + 28))
            let extraLength = Int(try data.uint16(at: cursor + 30))
            let entryCommentLength = Int(try data.uint16(at: cursor + 32))
            let entryDisk = try data.uint16(at: cursor + 34)
            let externalAttributes = try data.uint32(at: cursor + 38)
            let localOffset = try data.uint32(at: cursor + 42)
            let headerEnd = try checkedEnd(
                start: cursor, lengths: [46, nameLength, extraLength, entryCommentLength], limit: centralEnd
            )
            let nameRange = (cursor + 46)..<(cursor + 46 + nameLength)
            let extraRange = (cursor + 46 + nameLength)..<(cursor + 46 + nameLength + extraLength)
            try validateZIPExtraFields(in: data, range: extraRange)
            guard let path = String(data: data.subdata(in: nameRange), encoding: .utf8) else {
                throw SafeArchiveError.malformedArchive
            }
            try validateArchivePath(path, limits: limits)
            guard records[path] == nil else { throw SafeArchiveError.duplicateEntry(path) }
            guard entryDisk != UInt16.max else {
                throw SafeArchiveError.unsupportedZIP64
            }
            guard entryDisk == 0 else { throw SafeArchiveError.malformedArchive }
            try validateFlags(flags, path: path)
            guard method == ZipCompression.stored else {
                throw SafeArchiveError.unsupportedCompression(path: path, method: method)
            }
            guard compressedSize != UInt32.max, expandedSize != UInt32.max,
                  localOffset != UInt32.max
            else { throw SafeArchiveError.unsupportedZIP64 }
            guard compressedSize == expandedSize else { throw SafeArchiveError.malformedArchive }
            let expanded = UInt64(expandedSize)
            guard expanded <= limits.maximumEntryBytes else {
                throw SafeArchiveError.entryTooLarge(
                    path: path, actual: expanded, maximum: limits.maximumEntryBytes
                )
            }
            let (newTotal, totalOverflow) = total.addingReportingOverflow(expanded)
            guard !totalOverflow, newTotal <= limits.maximumExpandedBytes else {
                throw SafeArchiveError.archiveTooLarge(
                    actual: totalOverflow ? UInt64.max : newTotal,
                    maximum: limits.maximumExpandedBytes
                )
            }
            total = newTotal
            if externalAttributes & ZipExternalAttribute.dosDirectory != 0 {
                throw SafeArchiveError.unsafePath(path)
            }
            if usesPOSIXExternalAttributes(host: versionMadeBy >> 8) {
                let fileType = (externalAttributes >> 16) & 0xF000
                guard fileType != ZipExternalAttribute.symbolicLink else {
                    throw SafeArchiveError.symbolicLink(path)
                }
                guard fileType != ZipExternalAttribute.directory else {
                    throw SafeArchiveError.unsafePath(path)
                }
            }

            let local = Int(localOffset)
            guard try data.uint32(at: local) == ZipSignature.localFile else {
                throw SafeArchiveError.malformedArchive
            }
            let localFlags = try data.uint16(at: local + 6)
            let localMethod = try data.uint16(at: local + 8)
            let localChecksum = try data.uint32(at: local + 14)
            let localCompressedSize = try data.uint32(at: local + 18)
            let localExpandedSize = try data.uint32(at: local + 22)
            let localNameLength = Int(try data.uint16(at: local + 26))
            let localExtraLength = Int(try data.uint16(at: local + 28))
            try validateFlags(localFlags, path: path)
            guard localCompressedSize != UInt32.max,
                  localExpandedSize != UInt32.max
            else { throw SafeArchiveError.unsupportedZIP64 }
            guard localFlags == flags, localMethod == method, localChecksum == checksum,
                  localCompressedSize == compressedSize, localExpandedSize == expandedSize,
                  localNameLength == nameLength
            else { throw SafeArchiveError.malformedArchive }
            let localHeaderEnd = try checkedEnd(
                start: local, lengths: [30, localNameLength, localExtraLength], limit: centralStart
            )
            let localNameRange = (local + 30)..<(local + 30 + localNameLength)
            let localExtraRange = (local + 30 + localNameLength)..<localHeaderEnd
            try validateZIPExtraFields(in: data, range: localExtraRange)
            guard data.subdata(in: localNameRange) == data.subdata(in: nameRange) else {
                throw SafeArchiveError.malformedArchive
            }
            let dataEnd = try checkedEnd(
                start: localHeaderEnd, lengths: [Int(compressedSize)], limit: centralStart
            )
            let dataRange = localHeaderEnd..<dataEnd
            let completeLocalRange = local..<dataEnd
            guard localRanges.allSatisfy({ !$0.overlaps(completeLocalRange) }) else {
                throw SafeArchiveError.malformedArchive
            }
            guard CRC32.checksum(data, range: dataRange) == checksum else {
                throw SafeArchiveError.checksumMismatch(path)
            }
            localRanges.append(completeLocalRange)
            records[path] = SafeArchiveEntryRecord(
                dataRange: dataRange,
                checksum: checksum
            )
            cursor = headerEnd
        }
        guard cursor == centralEnd else { throw SafeArchiveError.malformedArchive }
        return SafeArchive(storage: data, records: records)
    }

    static func validateEntryDescriptors(
        _ entries: [SafeArchiveEntryDescriptor],
        limits: SafeArchiveLimits
    ) throws -> [SafeArchiveValidatedEntry] {
        guard !entries.isEmpty else { throw SafeArchiveError.emptyArchive }
        guard entries.count <= limits.maximumEntryCount,
              entries.count <= Int(UInt16.max)
        else { throw SafeArchiveError.entryCountOutOfRange(entries.count) }

        var seenPaths = Set<String>()
        var total: UInt64 = 0
        var validated: [SafeArchiveValidatedEntry] = []
        validated.reserveCapacity(entries.count)
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            guard seenPaths.insert(entry.path).inserted else {
                throw SafeArchiveError.duplicateEntry(entry.path)
            }
            try validateArchivePath(entry.path, limits: limits)
            guard entry.byteCount <= limits.maximumEntryBytes else {
                throw SafeArchiveError.entryTooLarge(
                    path: entry.path,
                    actual: entry.byteCount,
                    maximum: limits.maximumEntryBytes
                )
            }
            let (nextTotal, overflow) = total.addingReportingOverflow(
                entry.byteCount
            )
            guard !overflow,
                  nextTotal <= limits.maximumExpandedBytes
            else {
                throw SafeArchiveError.archiveTooLarge(
                    actual: overflow ? UInt64.max : nextTotal,
                    maximum: limits.maximumExpandedBytes
                )
            }
            total = nextTotal
            guard entry.byteCount <= UInt64(UInt32.max),
                  let name = entry.path.data(using: .utf8),
                  name.count <= Int(UInt16.max)
            else {
                if entry.byteCount > UInt64(UInt32.max) {
                    throw SafeArchiveError.unsupportedZIP64
                }
                throw SafeArchiveError.unsafePath(entry.path)
            }
            validated.append(SafeArchiveValidatedEntry(
                path: entry.path,
                name: name,
                size: UInt32(entry.byteCount)
            ))
        }
        return validated
    }

    static func localHeader(
        name: Data,
        checksum: UInt32,
        size: UInt32
    ) -> Data {
        var output = Data()
        output.reserveCapacity(30 + name.count)
        output.appendUInt32(ZipSignature.localFile)
        output.appendUInt16(20)
        output.appendUInt16(ZipFlag.utf8)
        output.appendUInt16(ZipCompression.stored)
        output.appendUInt16(0)
        output.appendUInt16(ZipDate.firstJanuary1980)
        output.appendUInt32(checksum)
        output.appendUInt32(size)
        output.appendUInt32(size)
        output.appendUInt16(UInt16(name.count))
        output.appendUInt16(0)
        output.append(name)
        return output
    }

    static func centralHeader(_ entry: CentralWriteRecord) -> Data {
        var output = Data()
        output.reserveCapacity(46 + entry.name.count)
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
        return output
    }

    static func endOfCentralDirectory(
        entryCount: Int,
        centralSize: UInt32,
        centralOffset: UInt32
    ) -> Data {
        precondition(entryCount <= Int(UInt16.max))
        var output = Data()
        output.reserveCapacity(22)
        output.appendUInt32(ZipSignature.endOfCentralDirectory)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(entryCount))
        output.appendUInt16(UInt16(entryCount))
        output.appendUInt32(centralSize)
        output.appendUInt32(centralOffset)
        output.appendUInt16(0)
        return output
    }
}

struct SafeArchiveValidatedEntry {
    let path: String
    let name: Data
    let size: UInt32
}

struct CentralWriteRecord {
    let name: Data
    let checksum: UInt32
    let size: UInt32
    let localOffset: UInt32
}

enum ZipSignature {
    static let localFile: UInt32 = 0x0403_4B50
    static let centralDirectory: UInt32 = 0x0201_4B50
    static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    static let zip64EndOfCentralDirectory: UInt32 = 0x0606_4B50
    static let zip64EndOfCentralDirectoryLocator: UInt32 = 0x0706_4B50
}
enum ZipCompression { static let stored: UInt16 = 0 }
private enum ZipFlag { static let utf8: UInt16 = 1 << 11 }
private enum ZipDate { static let firstJanuary1980: UInt16 = 0x0021 }
private enum ZipVersion { static let unix20: UInt16 = 0x0314; static let unixHost: UInt16 = 3 }
enum ZipHost {
    static let unix: UInt16 = 3
    static let macOS: UInt16 = 19
}
enum ZipExternalAttribute {
    static let regularFile0644: UInt32 = 0x81A4_0000
    static let symbolicLink: UInt32 = 0xA000
    static let directory: UInt32 = 0x4000
    static let dosDirectory: UInt32 = 0x10
}

package func hasStructurallyPlacedZIP64EndRecords(
    in data: Data,
    centralEnd: Int,
    eocdOffset: Int
) throws -> Bool {
    let locatorOffset = eocdOffset - 20
    guard centralEnd >= 0,
          centralEnd <= locatorOffset,
          locatorOffset >= 0,
          try data.uint32(at: locatorOffset)
              == ZipSignature.zip64EndOfCentralDirectoryLocator,
          try data.uint32(at: centralEnd)
              == ZipSignature.zip64EndOfCentralDirectory,
          try data.uint32(at: locatorOffset + 4) == 0,
          try data.uint32(at: locatorOffset + 16) == 1,
          try data.uint64(at: locatorOffset + 8) == UInt64(centralEnd)
    else { return false }

    let recordSize = try data.uint64(at: centralEnd + 4)
    guard recordSize >= 44, recordSize <= UInt64(Int.max) else {
        return false
    }
    let recordEnd = try checkedEnd(
        start: centralEnd + 12,
        lengths: [Int(recordSize)],
        limit: locatorOffset
    )
    return recordEnd == locatorOffset
}

func validateArchivePath(_ path: String, limits: SafeArchiveLimits) throws {
    let bytes = Array(path.utf8)
    let isDriveQualified = bytes.count >= 2
        && ((0x41...0x5A).contains(bytes[0]) || (0x61...0x7A).contains(bytes[0]))
        && bytes[1] == 0x3A
    guard !path.isEmpty, bytes.count <= limits.maximumPathBytes,
          !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
          !isDriveQualified
    else { throw SafeArchiveError.unsafePath(path) }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw SafeArchiveError.unsafePath(path) }
}

func usesPOSIXExternalAttributes(host: UInt16) -> Bool {
    host == ZipHost.unix || host == ZipHost.macOS
}

package func validateZIPExtraFields(
    in data: Data,
    range: Range<Int>
) throws {
    var cursor = range.lowerBound
    while cursor < range.upperBound {
        guard range.upperBound - cursor >= 4 else {
            throw SafeArchiveError.malformedArchive
        }
        let fieldID = try data.uint16(at: cursor)
        let fieldLength = Int(try data.uint16(at: cursor + 2))
        let fieldDataStart = cursor + 4
        let fieldEnd = try checkedEnd(
            start: fieldDataStart,
            lengths: [fieldLength],
            limit: range.upperBound
        )
        guard fieldID != ZipExtraField.zip64 else {
            throw SafeArchiveError.unsupportedZIP64
        }
        cursor = fieldEnd
    }
}

private enum ZipExtraField {
    static let zip64: UInt16 = 0x0001
}

func validateFlags(_ flags: UInt16, path: String) throws {
    guard flags & ~ZipFlag.utf8 == 0 else {
        throw SafeArchiveError.unsupportedArchiveFlags(path: path, flags: flags)
    }
}

private func findEndOfCentralDirectory(in data: Data) throws -> Int {
    guard data.count >= 22 else { throw SafeArchiveError.malformedArchive }
    let lowerBound = max(0, data.count - 22 - Int(UInt16.max))
    for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
        if try data.uint32(at: offset) == ZipSignature.endOfCentralDirectory,
           let commentLength = try? data.uint16(at: offset + 20),
           offset + 22 + Int(commentLength) == data.count {
            return offset
        }
    }
    throw SafeArchiveError.malformedArchive
}

func checkedEnd(start: Int, lengths: [Int], limit: Int) throws -> Int {
    var value = start
    for length in lengths {
        guard length >= 0 else { throw SafeArchiveError.malformedArchive }
        let (next, overflow) = value.addingReportingOverflow(length)
        guard !overflow, next <= limit else { throw SafeArchiveError.malformedArchive }
        value = next
    }
    return value
}
