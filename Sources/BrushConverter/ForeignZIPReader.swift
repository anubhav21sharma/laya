import Foundation
import SafeArchive
import zlib

enum ForeignContainerError: Error, Equatable, Sendable {
    case invalidLimits
    case sourceTooLarge(actual: Int, maximum: Int)
    case emptyArchive
    case malformedArchive
    case unsupportedZIP64
    case unsupportedFlags(path: String, flags: UInt16)
    case unsupportedCompression(path: String, method: UInt16)
    case nonASCIIPath
    case unsafePath(String)
    case duplicatePath(String)
    case symbolicLink(String)
    case entryCountExceeded(actual: Int, maximum: Int)
    case aggregateEntryCountExceeded(actual: Int, maximum: Int)
    case entryTooLarge(path: String, actual: Int, maximum: Int)
    case expansionBudgetExceeded(actual: Int, maximum: Int)
    case compressionRatioExceeded(
        path: String,
        expanded: Int,
        compressed: Int,
        maximum: Int
    )
    case checksumMismatch(String)
    case missingEntry(String)
    case nestingDepthExceeded(actual: Int, maximum: Int)
    case decompressionFailed(String)
}

struct ForeignZIPReader: Sendable {
    let paths: [String]
    let directoryPaths: [String]
    let depth: Int

    // Structure is validated once, while entry output is expanded on demand.
    // Retaining only the source and bounded metadata prevents aggregate
    // expanded residency from exceeding the per-access budget.
    private let source: Data
    private let entries: [String: EntryRecord]
    private let limits: ForeignContainerLimits
    private let budget: ForeignExpansionBudget

    init(
        _ data: Data,
        limits: ForeignContainerLimits = .standard,
        budget: ForeignExpansionBudget? = nil
    ) throws {
        try self.init(
            data,
            limits: limits,
            budget: budget ?? ForeignExpansionBudget(limits: limits),
            depth: 0
        )
    }

    private init(
        _ data: Data,
        limits: ForeignContainerLimits,
        budget: ForeignExpansionBudget,
        depth: Int
    ) throws {
        guard limits.isValid,
              budget.maximumExpandedBytes >= 0,
              budget.maximumEntries > 0,
              budget.maximumExpandedBytes <= limits.maximumExpandedBytes,
              budget.maximumEntries <= limits.maximumNestedEntries
        else {
            throw ForeignContainerError.invalidLimits
        }
        guard depth <= limits.maximumNestingDepth else {
            throw ForeignContainerError.nestingDepthExceeded(
                actual: depth,
                maximum: limits.maximumNestingDepth
            )
        }
        guard data.count <= limits.maximumSourceBytes else {
            throw ForeignContainerError.sourceTooLarge(
                actual: data.count,
                maximum: limits.maximumSourceBytes
            )
        }
        let normalizedData = data.startIndex == 0 ? data : Data(data)

        let result = try Self.read(
            normalizedData,
            limits: limits,
            budget: budget
        )
        source = normalizedData
        entries = result.entries
        paths = result.entries.keys.sorted()
        directoryPaths = result.directories.sorted()
        self.limits = limits
        self.budget = budget
        self.depth = depth
    }

    func contains(_ path: String) -> Bool {
        guard let normalized = try? canonicalPath(for: path) else {
            return false
        }
        return entries[normalized] != nil
    }

    func canonicalPath(for path: String) throws -> String {
        try normalizeForeignZIPPath(
            path,
            maximumUTF8Bytes: limits.maximumPathUTF8Bytes,
            permitsDirectory: false
        )
    }

    func data(for path: String) throws -> Data {
        let normalized: String
        do {
            normalized = try canonicalPath(for: path)
        } catch {
            throw ForeignContainerError.missingEntry(path)
        }
        guard let record = entries[normalized] else {
            throw ForeignContainerError.missingEntry(path)
        }
        var chargedBytes = 0
        do {
            let expanded = try Self.expand(
                source,
                record: record,
                limits: limits,
                budget: budget,
                chargedBytes: &chargedBytes
            )
            guard expanded.checksum == record.checksum else {
                throw ForeignContainerError.checksumMismatch(record.path)
            }
            return expanded.data
        } catch let error as ForeignContainerError {
            budget.refund(
                expandedByteCount: chargedBytes,
                entryCount: 0
            )
            throw error
        } catch {
            budget.refund(
                expandedByteCount: chargedBytes,
                entryCount: 0
            )
            throw ForeignContainerError.malformedArchive
        }
    }

    func nestedArchive(at path: String) throws -> ForeignZIPReader {
        let nextDepth = depth + 1
        guard nextDepth <= limits.maximumNestingDepth else {
            throw ForeignContainerError.nestingDepthExceeded(
                actual: nextDepth,
                maximum: limits.maximumNestingDepth
            )
        }
        return try ForeignZIPReader(
            data(for: path),
            limits: limits,
            budget: budget,
            depth: nextDepth
        )
    }
}

private extension ForeignZIPReader {
    struct ReadResult {
        let entries: [String: EntryRecord]
        let directories: [String]
    }

    struct EntryRecord: Sendable {
        let path: String
        let method: UInt16
        let checksum: UInt32
        let compressedSize: Int
        let expandedSize: Int
        let compressedRange: Range<Int>
    }

    struct CentralRecord {
        let path: String
        let isDirectory: Bool
        let rawName: Data
        let versionNeeded: UInt16
        let flags: UInt16
        let method: UInt16
        let modifiedTime: UInt16
        let modifiedDate: UInt16
        let checksum: UInt32
        let compressedSize: Int
        let expandedSize: Int
        let localOffset: Int
    }

    static func read(
        _ data: Data,
        limits: ForeignContainerLimits,
        budget: ForeignExpansionBudget
    ) throws -> ReadResult {
        var chargedEntries = 0
        do {
            let eocd = try findEOCD(in: data)
            let disk = try data.uint16(at: eocd + 4)
            let centralDisk = try data.uint16(at: eocd + 6)
            let entriesOnDisk = try data.uint16(at: eocd + 8)
            let entryCount = try data.uint16(at: eocd + 10)
            let centralSize = try data.uint32(at: eocd + 12)
            let centralOffset = try data.uint32(at: eocd + 16)
            let commentLength = try data.uint16(at: eocd + 20)

            guard disk != UInt16.max,
                  centralDisk != UInt16.max,
                  entriesOnDisk != UInt16.max,
                  entryCount != UInt16.max,
                  centralSize != UInt32.max,
                  centralOffset != UInt32.max
            else {
                throw ForeignContainerError.unsupportedZIP64
            }
            guard disk == 0,
                  centralDisk == 0,
                  entriesOnDisk == entryCount,
                  eocd + 22 + Int(commentLength) == data.count
            else {
                throw ForeignContainerError.malformedArchive
            }
            guard entryCount > 0 else {
                throw ForeignContainerError.emptyArchive
            }
            guard Int(entryCount) <= limits.maximumEntriesPerContainer else {
                throw ForeignContainerError.entryCountExceeded(
                    actual: Int(entryCount),
                    maximum: limits.maximumEntriesPerContainer
                )
            }
            try budget.charge(entryCount: Int(entryCount))
            chargedEntries = Int(entryCount)

            let centralStart = Int(centralOffset)
            let centralEnd = try checkedEnd(
                centralStart,
                adding: Int(centralSize),
                limit: data.count
            )
            guard centralEnd == eocd else {
                if try hasStructurallyPlacedZIP64EndRecords(
                    in: data,
                    centralEnd: centralEnd,
                    eocdOffset: eocd
                ) {
                    throw ForeignContainerError.unsupportedZIP64
                }
                throw ForeignContainerError.malformedArchive
            }

            var records: [CentralRecord] = []
            records.reserveCapacity(Int(entryCount))
            var identities = Set<String>()
            var cursor = centralStart
            for _ in 0..<entryCount {
                guard try data.uint32(at: cursor)
                    == ZIPSignature.centralDirectory
                else {
                    throw ForeignContainerError.malformedArchive
                }
                let versionMadeBy = try data.uint16(at: cursor + 4)
                let versionNeeded = try data.uint16(at: cursor + 6)
                let flags = try data.uint16(at: cursor + 8)
                let method = try data.uint16(at: cursor + 10)
                let modifiedTime = try data.uint16(at: cursor + 12)
                let modifiedDate = try data.uint16(at: cursor + 14)
                let checksum = try data.uint32(at: cursor + 16)
                let compressedSize32 = try data.uint32(at: cursor + 20)
                let expandedSize32 = try data.uint32(at: cursor + 24)
                let nameLength = Int(try data.uint16(at: cursor + 28))
                let extraLength = Int(try data.uint16(at: cursor + 30))
                let entryCommentLength = Int(
                    try data.uint16(at: cursor + 32)
                )
                let entryDisk = try data.uint16(at: cursor + 34)
                let externalAttributes = try data.uint32(at: cursor + 38)
                let localOffset32 = try data.uint32(at: cursor + 42)
                let headerEnd = try checkedEnd(
                    cursor,
                    adding: 46,
                    nameLength,
                    extraLength,
                    entryCommentLength,
                    limit: centralEnd
                )
                guard compressedSize32 != UInt32.max,
                      expandedSize32 != UInt32.max,
                      localOffset32 != UInt32.max,
                      entryDisk != UInt16.max
                else {
                    throw ForeignContainerError.unsupportedZIP64
                }
                guard entryDisk == 0 else {
                    throw ForeignContainerError.malformedArchive
                }
                guard versionNeeded < 45 else {
                    throw ForeignContainerError.unsupportedZIP64
                }

                let nameStart = cursor + 46
                let nameRange = nameStart..<(nameStart + nameLength)
                let extraRange = nameRange.upperBound..<(nameRange.upperBound
                    + extraLength)
                try validateZIPExtraFields(in: data, range: extraRange)
                let rawName = data.subdata(in: nameRange)
                let path = try decodePath(
                    rawName,
                    flags: flags,
                    maximumUTF8Bytes: limits.maximumPathUTF8Bytes
                )
                let isDirectory = path.hasSuffix("/")
                try validateFlags(flags, method: method, path: path)
                guard method == ZIPCompression.stored
                    || method == ZIPCompression.deflate
                else {
                    throw ForeignContainerError.unsupportedCompression(
                        path: path,
                        method: method
                    )
                }
                let minimumVersion: UInt16 =
                    method == ZIPCompression.deflate ? 20 : 10
                guard versionNeeded >= minimumVersion else {
                    throw ForeignContainerError.malformedArchive
                }
                let compressedSize = Int(compressedSize32)
                let expandedSize = Int(expandedSize32)
                guard expandedSize <= limits.maximumExpandedBytesPerEntry else {
                    throw ForeignContainerError.entryTooLarge(
                        path: path,
                        actual: expandedSize,
                        maximum: limits.maximumExpandedBytesPerEntry
                    )
                }
                guard method != ZIPCompression.stored
                    || compressedSize == expandedSize
                else {
                    throw ForeignContainerError.malformedArchive
                }
                guard !isDirectory
                    || (compressedSize == 0
                        && expandedSize == 0
                        && checksum == 0
                        && method == ZIPCompression.stored)
                else {
                    throw ForeignContainerError.malformedArchive
                }
                try validateFileType(
                    versionMadeBy: versionMadeBy,
                    externalAttributes: externalAttributes,
                    path: path,
                    isDirectory: isDirectory
                )
                let identity = isDirectory
                    ? String(path.dropLast())
                    : path
                guard identities.insert(identity).inserted else {
                    throw ForeignContainerError.duplicatePath(path)
                }
                records.append(CentralRecord(
                    path: path,
                    isDirectory: isDirectory,
                    rawName: rawName,
                    versionNeeded: versionNeeded,
                    flags: flags,
                    method: method,
                    modifiedTime: modifiedTime,
                    modifiedDate: modifiedDate,
                    checksum: checksum,
                    compressedSize: compressedSize,
                    expandedSize: expandedSize,
                    localOffset: Int(localOffset32)
                ))
                cursor = headerEnd
            }
            guard cursor == centralEnd else {
                throw ForeignContainerError.malformedArchive
            }

            records.sort {
                if $0.localOffset == $1.localOffset {
                    return $0.path < $1.path
                }
                return $0.localOffset < $1.localOffset
            }
            guard records.first?.localOffset == 0 else {
                throw ForeignContainerError.malformedArchive
            }

            var entries: [String: EntryRecord] = [:]
            var directories: [String] = []
            entries.reserveCapacity(records.count)
            for index in records.indices {
                let record = records[index]
                let nextOffset = index + 1 < records.count
                    ? records[index + 1].localOffset
                    : centralStart
                guard record.localOffset < nextOffset,
                      try data.uint32(at: record.localOffset)
                        == ZIPSignature.localFile
                else {
                    throw ForeignContainerError.malformedArchive
                }
                let localVersion = try data.uint16(
                    at: record.localOffset + 4
                )
                let localFlags = try data.uint16(at: record.localOffset + 6)
                let localMethod = try data.uint16(at: record.localOffset + 8)
                let localModifiedTime = try data.uint16(
                    at: record.localOffset + 10
                )
                let localModifiedDate = try data.uint16(
                    at: record.localOffset + 12
                )
                let localChecksum = try data.uint32(
                    at: record.localOffset + 14
                )
                let localCompressedSize = try data.uint32(
                    at: record.localOffset + 18
                )
                let localExpandedSize = try data.uint32(
                    at: record.localOffset + 22
                )
                let localNameLength = Int(
                    try data.uint16(at: record.localOffset + 26)
                )
                let localExtraLength = Int(
                    try data.uint16(at: record.localOffset + 28)
                )
                guard localCompressedSize != UInt32.max,
                      localExpandedSize != UInt32.max
                else {
                    throw ForeignContainerError.unsupportedZIP64
                }
                guard localVersion == record.versionNeeded,
                      localFlags == record.flags,
                      localMethod == record.method,
                      localModifiedTime == record.modifiedTime,
                      localModifiedDate == record.modifiedDate,
                      localChecksum == record.checksum,
                      Int(localCompressedSize) == record.compressedSize,
                      Int(localExpandedSize) == record.expandedSize,
                      localNameLength == record.rawName.count
                else {
                    throw ForeignContainerError.malformedArchive
                }
                let nameStart = record.localOffset + 30
                let localHeaderEnd = try checkedEnd(
                    nameStart,
                    adding: localNameLength,
                    localExtraLength,
                    limit: nextOffset
                )
                let localNameRange = nameStart..<(nameStart + localNameLength)
                let localExtraRange = localNameRange.upperBound..<localHeaderEnd
                try validateZIPExtraFields(in: data, range: localExtraRange)
                guard data.subdata(in: localNameRange) == record.rawName else {
                    throw ForeignContainerError.malformedArchive
                }
                let compressedEnd = try checkedEnd(
                    localHeaderEnd,
                    adding: record.compressedSize,
                    limit: nextOffset
                )
                guard compressedEnd == nextOffset else {
                    throw ForeignContainerError.malformedArchive
                }
                let compressedRange = localHeaderEnd..<compressedEnd
                if record.isDirectory {
                    directories.append(record.path)
                } else {
                    entries[record.path] = EntryRecord(
                        path: record.path,
                        method: record.method,
                        checksum: record.checksum,
                        compressedSize: record.compressedSize,
                        expandedSize: record.expandedSize,
                        compressedRange: compressedRange
                    )
                }
            }
            return ReadResult(entries: entries, directories: directories)
        } catch let error as ForeignContainerError {
            budget.refund(
                expandedByteCount: 0,
                entryCount: chargedEntries
            )
            throw error
        } catch let error as SafeArchiveError {
            budget.refund(
                expandedByteCount: 0,
                entryCount: chargedEntries
            )
            switch error {
            case .unsupportedZIP64:
                throw ForeignContainerError.unsupportedZIP64
            default:
                throw ForeignContainerError.malformedArchive
            }
        } catch {
            budget.refund(
                expandedByteCount: 0,
                entryCount: chargedEntries
            )
            throw ForeignContainerError.malformedArchive
        }
    }

    static func expand(
        _ source: Data,
        record: EntryRecord,
        limits: ForeignContainerLimits,
        budget: ForeignExpansionBudget,
        chargedBytes: inout Int
    ) throws -> (data: Data, checksum: UInt32) {
        let maximumByRatio: Int
        let (ratioProduct, ratioOverflow) =
            record.compressedSize.multipliedReportingOverflow(
                by: limits.maximumCompressionRatio
            )
        maximumByRatio = ratioOverflow ? Int.max : ratioProduct

        func charge(_ byteCount: Int, total: Int) throws {
            guard total <= record.expandedSize,
                  total <= limits.maximumExpandedBytesPerEntry
            else {
                throw ForeignContainerError.entryTooLarge(
                    path: record.path,
                    actual: total,
                    maximum: min(
                        record.expandedSize,
                        limits.maximumExpandedBytesPerEntry
                    )
                )
            }
            guard total <= maximumByRatio else {
                throw ForeignContainerError.compressionRatioExceeded(
                    path: record.path,
                    expanded: total,
                    compressed: record.compressedSize,
                    maximum: limits.maximumCompressionRatio
                )
            }
            let (nextCharged, overflow) = chargedBytes.addingReportingOverflow(
                byteCount
            )
            guard !overflow else {
                throw ForeignContainerError.expansionBudgetExceeded(
                    actual: Int.max,
                    maximum: budget.maximumExpandedBytes
                )
            }
            try budget.charge(expandedByteCount: byteCount)
            chargedBytes = nextCharged
        }

        var output = Data()
        output.reserveCapacity(
            min(record.expandedSize, limits.streamingChunkBytes)
        )
        var checksum = CRC32Accumulator()
        if record.method == ZIPCompression.stored {
            guard record.compressedSize == record.expandedSize else {
                throw ForeignContainerError.malformedArchive
            }
            var cursor = record.compressedRange.lowerBound
            while cursor < record.compressedRange.upperBound {
                let end = min(
                    cursor + limits.streamingChunkBytes,
                    record.compressedRange.upperBound
                )
                let byteCount = end - cursor
                try charge(byteCount, total: output.count + byteCount)
                let bytes = source[cursor..<end]
                checksum.update(bytes)
                output.append(bytes)
                cursor = end
            }
        } else {
            try source.withUnsafeBytes { rawSource in
                var stream = z_stream()
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: rawSource
                        .bindMemory(to: Bytef.self)
                        .baseAddress?
                        .advanced(by: record.compressedRange.lowerBound)
                )
                stream.avail_in = uInt(record.compressedSize)
                guard inflateInit2_(
                    &stream,
                    -MAX_WBITS,
                    ZLIB_VERSION,
                    Int32(MemoryLayout<z_stream>.size)
                ) == Z_OK else {
                    throw ForeignContainerError.decompressionFailed(record.path)
                }
                defer { inflateEnd(&stream) }

                var chunk = [UInt8](
                    repeating: 0,
                    count: limits.streamingChunkBytes
                )
                let chunkSize = chunk.count
                while true {
                    let inputBefore = stream.avail_in
                    let status = chunk.withUnsafeMutableBytes { rawChunk in
                        stream.next_out = rawChunk
                            .bindMemory(to: Bytef.self)
                            .baseAddress
                        stream.avail_out = uInt(chunkSize)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        try charge(
                            produced,
                            total: output.count + produced
                        )
                        let bytes = chunk[0..<produced]
                        checksum.update(bytes)
                        output.append(contentsOf: bytes)
                    }
                    if status == Z_STREAM_END {
                        guard stream.avail_in == 0 else {
                            throw ForeignContainerError.decompressionFailed(
                                record.path
                            )
                        }
                        break
                    }
                    guard status == Z_OK,
                          produced > 0 || stream.avail_in < inputBefore
                    else {
                        throw ForeignContainerError.decompressionFailed(
                            record.path
                        )
                    }
                }
            }
        }
        guard output.count == record.expandedSize else {
            throw ForeignContainerError.decompressionFailed(record.path)
        }
        return (output, checksum.checksum)
    }
}

private enum ZIPSignature {
    static let localFile: UInt32 = 0x0403_4B50
    static let centralDirectory: UInt32 = 0x0201_4B50
    static let endOfCentralDirectory: UInt32 = 0x0605_4B50
}

private enum ZIPCompression {
    static let stored: UInt16 = 0
    static let deflate: UInt16 = 8
}

private enum ZIPFlag {
    static let encrypted: UInt16 = 1 << 0
    static let deflateOption1: UInt16 = 1 << 1
    static let deflateOption2: UInt16 = 1 << 2
    static let dataDescriptor: UInt16 = 1 << 3
    static let utf8: UInt16 = 1 << 11
}

private func validateFlags(
    _ flags: UInt16,
    method: UInt16,
    path: String
) throws {
    let deflateOptions = ZIPFlag.deflateOption1 | ZIPFlag.deflateOption2
    let permitted = ZIPFlag.utf8
        | (method == ZIPCompression.deflate ? deflateOptions : 0)
    guard flags & ~permitted == 0,
          flags & ZIPFlag.encrypted == 0,
          flags & ZIPFlag.dataDescriptor == 0
    else {
        throw ForeignContainerError.unsupportedFlags(
            path: path,
            flags: flags
        )
    }
}

private func decodePath(
    _ bytes: Data,
    flags: UInt16,
    maximumUTF8Bytes: Int
) throws -> String {
    guard bytes.count <= maximumUTF8Bytes else {
        throw ForeignContainerError.unsafePath(
            String(decoding: bytes, as: UTF8.self)
        )
    }
    if flags & ZIPFlag.utf8 == 0,
       bytes.contains(where: { $0 >= 0x80 }) {
        throw ForeignContainerError.nonASCIIPath
    }
    guard let raw = String(data: bytes, encoding: .utf8) else {
        throw ForeignContainerError.malformedArchive
    }
    return try normalizeForeignZIPPath(
        raw,
        maximumUTF8Bytes: maximumUTF8Bytes,
        permitsDirectory: true
    )
}

private func normalizeForeignZIPPath(
    _ raw: String,
    maximumUTF8Bytes: Int,
    permitsDirectory: Bool
) throws -> String {
    let normalized = raw.precomposedStringWithCanonicalMapping
    let bytes = Array(normalized.utf8)
    let isDirectory = normalized.hasSuffix("/")
    let body = isDirectory ? String(normalized.dropLast()) : normalized
    let bodyBytes = Array(body.utf8)
    let driveQualified = bodyBytes.count >= 2
        && ((0x41...0x5A).contains(bodyBytes[0])
            || (0x61...0x7A).contains(bodyBytes[0]))
        && bodyBytes[1] == 0x3A
    guard !body.isEmpty,
          raw.utf8.count <= maximumUTF8Bytes,
          bytes.count <= maximumUTF8Bytes,
          !normalized.hasPrefix("/"),
          !normalized.contains("\\"),
          !normalized.contains("\0"),
          !driveQualified,
          permitsDirectory || !isDirectory,
          normalized.unicodeScalars.allSatisfy({
              !CharacterSet.controlCharacters.contains($0)
          })
    else {
        throw ForeignContainerError.unsafePath(raw)
    }
    let components = body.split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    guard !components.isEmpty,
          components.allSatisfy({
              !$0.isEmpty && $0 != "." && $0 != ".."
          })
    else {
        throw ForeignContainerError.unsafePath(raw)
    }
    return normalized
}

private func validateFileType(
    versionMadeBy: UInt16,
    externalAttributes: UInt32,
    path: String,
    isDirectory: Bool
) throws {
    let host = versionMadeBy >> 8
    let dosDirectory = externalAttributes & 0x10 != 0
    if host == 3 || host == 19 {
        let fileType = (externalAttributes >> 16) & 0xF000
        if fileType == 0xA000 {
            throw ForeignContainerError.symbolicLink(path)
        }
        if fileType != 0,
           fileType != 0x8000,
           fileType != 0x4000 {
            throw ForeignContainerError.malformedArchive
        }
        guard (fileType == 0x4000) == isDirectory else {
            throw ForeignContainerError.malformedArchive
        }
    }
    guard !dosDirectory || isDirectory else {
        throw ForeignContainerError.malformedArchive
    }
}

private func findEOCD(in data: Data) throws -> Int {
    guard data.count >= 22 else {
        throw ForeignContainerError.malformedArchive
    }
    let lower = max(0, data.count - 22 - Int(UInt16.max))
    for offset in stride(from: data.count - 22, through: lower, by: -1) {
        if try data.uint32(at: offset) == ZIPSignature.endOfCentralDirectory,
           let commentLength = try? data.uint16(at: offset + 20),
           offset + 22 + Int(commentLength) == data.count {
            return offset
        }
    }
    throw ForeignContainerError.malformedArchive
}

private func checkedEnd(
    _ start: Int,
    adding lengths: Int...,
    limit: Int
) throws -> Int {
    var result = start
    for length in lengths {
        guard length >= 0 else {
            throw ForeignContainerError.malformedArchive
        }
        let (next, overflow) = result.addingReportingOverflow(length)
        guard !overflow, next <= limit else {
            throw ForeignContainerError.malformedArchive
        }
        result = next
    }
    return result
}
