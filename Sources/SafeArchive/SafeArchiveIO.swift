import Foundation

public enum SafeArchiveIO {
    public static func open(
        at source: URL,
        limits: SafeArchiveLimits
    ) throws -> SafeArchive {
        try open(at: source, limits: limits, readObserver: nil)
    }

    package static func open(
        at source: URL,
        limits: SafeArchiveLimits,
        readObserver: ((Int) -> Void)?
    ) throws -> SafeArchive {
        do {
            let storage = try SafeArchiveFileStorage(
                source: source,
                readObserver: readObserver
            )
            return try open(storage: storage, limits: limits)
        } catch let error as SafeArchiveError {
            throw error
        } catch {
            throw SafeArchiveError.malformedArchive
        }
    }

    public static func save(
        provider: any SafeArchiveEntryProvider,
        to destination: URL,
        limits: SafeArchiveLimits,
        maximumChunkByteCount: Int
    ) throws {
        try save(
            provider: provider,
            to: destination,
            limits: limits,
            maximumChunkByteCount: maximumChunkByteCount,
            beforeReplacement: { _ in }
        )
    }

    package static func save(
        provider: any SafeArchiveEntryProvider,
        to destination: URL,
        limits: SafeArchiveLimits,
        maximumChunkByteCount: Int,
        beforeReplacement: (URL) throws -> Void
    ) throws {
        defer { provider.close() }
        guard maximumChunkByteCount > 0 else {
            throw SafeArchiveError.invalidChunkByteCount(
                maximumChunkByteCount
            )
        }
        let entries = try SafeArchiveCodec.validateEntryDescriptors(
            provider.archiveEntries(),
            limits: limits
        )
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: nil
            ) else { throw SafeArchiveError.saveFailed }
            let output = try FileHandle(forWritingTo: temporary)
            var outputClosed = false
            defer {
                if !outputClosed { try? output.close() }
            }
            var outputOffset: UInt64 = 0
            var central: [CentralWriteRecord] = []
            central.reserveCapacity(entries.count)

            for (entryIndex, entry) in entries.enumerated() {
                let spool = directory.appendingPathComponent(
                    ".\(destination.lastPathComponent).\(UUID().uuidString)."
                        + "\(entryIndex).entry.tmp",
                    isDirectory: false
                )
                defer { try? fileManager.removeItem(at: spool) }
                guard fileManager.createFile(atPath: spool.path, contents: nil)
                else { throw SafeArchiveError.saveFailed }
                let spoolWriter = try FileHandle(forWritingTo: spool)
                var spoolWriterClosed = false
                defer {
                    if !spoolWriterClosed { try? spoolWriter.close() }
                }
                var checksum = CRC32Accumulator()
                var actualByteCount: UInt64 = 0
                try provider.provideChunks(
                    for: entry.path,
                    maximumChunkByteCount: maximumChunkByteCount
                ) { chunk in
                    guard !chunk.isEmpty else {
                        throw SafeArchiveError.emptyChunk(entry.path)
                    }
                    guard chunk.count <= maximumChunkByteCount else {
                        throw SafeArchiveError.chunkTooLarge(
                            path: entry.path,
                            actual: chunk.count,
                            maximum: maximumChunkByteCount
                        )
                    }
                    let (nextCount, overflow) = actualByteCount
                        .addingReportingOverflow(UInt64(chunk.count))
                    guard !overflow, nextCount <= UInt64(UInt32.max) else {
                        throw SafeArchiveError.unsupportedZIP64
                    }
                    actualByteCount = nextCount
                    checksum.update(chunk)
                    try spoolWriter.write(contentsOf: chunk)
                }
                guard actualByteCount == UInt64(entry.size) else {
                    throw SafeArchiveError.entrySizeMismatch(
                        path: entry.path,
                        expected: UInt64(entry.size),
                        actual: actualByteCount
                    )
                }
                try spoolWriter.synchronize()
                try spoolWriter.close()
                spoolWriterClosed = true

                guard outputOffset <= UInt64(UInt32.max) else {
                    throw SafeArchiveError.unsupportedZIP64
                }
                let localOffset = UInt32(outputOffset)
                let header = SafeArchiveCodec.localHeader(
                    name: entry.name,
                    checksum: checksum.checksum,
                    size: entry.size
                )
                try output.write(contentsOf: header)
                outputOffset = try checkedArchiveOffset(
                    outputOffset,
                    adding: UInt64(header.count)
                )
                let spoolReader = try FileHandle(forReadingFrom: spool)
                defer { try? spoolReader.close() }
                while let chunk = try spoolReader.read(
                    upToCount: maximumChunkByteCount
                ), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                    outputOffset = try checkedArchiveOffset(
                        outputOffset,
                        adding: UInt64(chunk.count)
                    )
                }
                central.append(CentralWriteRecord(
                    name: entry.name,
                    checksum: checksum.checksum,
                    size: entry.size,
                    localOffset: localOffset
                ))
            }

            guard outputOffset <= UInt64(UInt32.max) else {
                throw SafeArchiveError.unsupportedZIP64
            }
            let centralOffset = UInt32(outputOffset)
            for entry in central {
                let header = SafeArchiveCodec.centralHeader(entry)
                try output.write(contentsOf: header)
                outputOffset = try checkedArchiveOffset(
                    outputOffset,
                    adding: UInt64(header.count)
                )
            }
            let centralSize64 = outputOffset - UInt64(centralOffset)
            guard centralSize64 <= UInt64(UInt32.max) else {
                throw SafeArchiveError.unsupportedZIP64
            }
            let end = SafeArchiveCodec.endOfCentralDirectory(
                entryCount: central.count,
                centralSize: UInt32(centralSize64),
                centralOffset: centralOffset
            )
            try output.write(contentsOf: end)
            _ = try checkedArchiveOffset(
                outputOffset,
                adding: UInt64(end.count)
            )
            try output.synchronize()
            try output.close()
            outputClosed = true

            try verifyArchive(
                at: temporary,
                limits: limits,
                maximumChunkByteCount: maximumChunkByteCount
            )
            try beforeReplacement(temporary)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    public static func save(
        entries: [String: Data],
        to destination: URL,
        limits: SafeArchiveLimits
    ) throws {
        try save(
            entries: entries,
            to: destination,
            limits: limits,
            beforeReplacement: { _ in }
        )
    }

    package static func save(
        entries: [String: Data],
        to destination: URL,
        limits: SafeArchiveLimits,
        beforeReplacement: (URL) throws -> Void
    ) throws {
        let archive = try SafeArchiveCodec.encode(entries: entries, limits: limits)
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try archive.write(to: temporary, options: [.withoutOverwriting])
            try verifyArchive(
                at: temporary,
                limits: limits,
                maximumChunkByteCount: 64 * 1_024
            )
            try beforeReplacement(temporary)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination, withItemAt: temporary, backupItemName: nil, options: []
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch let error as SafeArchiveError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch let error as SafeArchiveSaveHookError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw SafeArchiveError.saveFailed
        }
    }
}

private extension SafeArchiveIO {
    static func open(
        storage: SafeArchiveFileStorage,
        limits: SafeArchiveLimits
    ) throws -> SafeArchive {
        let tailByteCount = min(storage.byteCount, 22 + Int(UInt16.max))
        guard tailByteCount >= 22 else {
            throw SafeArchiveError.malformedArchive
        }
        let tailStart = storage.byteCount - tailByteCount
        let tail = try storage.read(tailStart..<storage.byteCount)
        let localEOCDOffset = try findEndOfCentralDirectory(in: tail)
        let eocdOffset = tailStart + localEOCDOffset
        let disk = try tail.uint16(at: localEOCDOffset + 4)
        let centralDisk = try tail.uint16(at: localEOCDOffset + 6)
        let entriesOnDisk = try tail.uint16(at: localEOCDOffset + 8)
        let entryCount = try tail.uint16(at: localEOCDOffset + 10)
        let centralSize = try tail.uint32(at: localEOCDOffset + 12)
        let centralOffset = try tail.uint32(at: localEOCDOffset + 16)
        let commentLength = try tail.uint16(at: localEOCDOffset + 20)
        guard disk != UInt16.max,
              centralDisk != UInt16.max,
              entriesOnDisk != UInt16.max,
              entryCount != UInt16.max,
              centralSize != UInt32.max,
              centralOffset != UInt32.max
        else { throw SafeArchiveError.unsupportedZIP64 }
        guard disk == 0,
              centralDisk == 0,
              entriesOnDisk == entryCount,
              eocdOffset + 22 + Int(commentLength) == storage.byteCount
        else { throw SafeArchiveError.malformedArchive }
        guard entryCount > 0 else { throw SafeArchiveError.emptyArchive }
        guard Int(entryCount) <= limits.maximumEntryCount else {
            throw SafeArchiveError.entryCountOutOfRange(Int(entryCount))
        }

        let centralStart = Int(centralOffset)
        let centralEnd = try checkedEnd(
            start: centralStart,
            lengths: [Int(centralSize)],
            limit: storage.byteCount
        )
        guard centralEnd == eocdOffset else {
            if try hasStructurallyPlacedZIP64EndRecords(
                storage: storage,
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
            let fixedEnd = try checkedEnd(
                start: cursor,
                lengths: [46],
                limit: centralEnd
            )
            let central = try storage.read(cursor..<fixedEnd)
            guard try central.uint32(at: 0) == ZipSignature.centralDirectory else {
                throw SafeArchiveError.malformedArchive
            }
            let versionMadeBy = try central.uint16(at: 4)
            let flags = try central.uint16(at: 8)
            let method = try central.uint16(at: 10)
            let checksum = try central.uint32(at: 16)
            let compressedSize = try central.uint32(at: 20)
            let expandedSize = try central.uint32(at: 24)
            let nameLength = Int(try central.uint16(at: 28))
            let extraLength = Int(try central.uint16(at: 30))
            let entryCommentLength = Int(try central.uint16(at: 32))
            let entryDisk = try central.uint16(at: 34)
            let externalAttributes = try central.uint32(at: 38)
            let localOffset = try central.uint32(at: 42)
            let headerEnd = try checkedEnd(
                start: cursor,
                lengths: [46, nameLength, extraLength, entryCommentLength],
                limit: centralEnd
            )
            let nameStart = cursor + 46
            let name = try storage.read(nameStart..<(nameStart + nameLength))
            let extraStart = nameStart + nameLength
            let extra = try storage.read(extraStart..<(extraStart + extraLength))
            try validateZIPExtraFields(in: extra, range: 0..<extra.count)
            guard let path = String(data: name, encoding: .utf8) else {
                throw SafeArchiveError.malformedArchive
            }
            try validateArchivePath(path, limits: limits)
            guard records[path] == nil else {
                throw SafeArchiveError.duplicateEntry(path)
            }
            guard entryDisk != UInt16.max else {
                throw SafeArchiveError.unsupportedZIP64
            }
            guard entryDisk == 0 else { throw SafeArchiveError.malformedArchive }
            try validateFlags(flags, path: path)
            guard method == ZipCompression.stored else {
                throw SafeArchiveError.unsupportedCompression(
                    path: path,
                    method: method
                )
            }
            guard compressedSize != UInt32.max,
                  expandedSize != UInt32.max,
                  localOffset != UInt32.max
            else { throw SafeArchiveError.unsupportedZIP64 }
            guard compressedSize == expandedSize else {
                throw SafeArchiveError.malformedArchive
            }
            let expanded = UInt64(expandedSize)
            guard expanded <= limits.maximumEntryBytes else {
                throw SafeArchiveError.entryTooLarge(
                    path: path,
                    actual: expanded,
                    maximum: limits.maximumEntryBytes
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
            let localFixedEnd = try checkedEnd(
                start: local,
                lengths: [30],
                limit: centralStart
            )
            let localHeader = try storage.read(local..<localFixedEnd)
            guard try localHeader.uint32(at: 0) == ZipSignature.localFile else {
                throw SafeArchiveError.malformedArchive
            }
            let localFlags = try localHeader.uint16(at: 6)
            let localMethod = try localHeader.uint16(at: 8)
            let localChecksum = try localHeader.uint32(at: 14)
            let localCompressedSize = try localHeader.uint32(at: 18)
            let localExpandedSize = try localHeader.uint32(at: 22)
            let localNameLength = Int(try localHeader.uint16(at: 26))
            let localExtraLength = Int(try localHeader.uint16(at: 28))
            try validateFlags(localFlags, path: path)
            guard localCompressedSize != UInt32.max,
                  localExpandedSize != UInt32.max
            else { throw SafeArchiveError.unsupportedZIP64 }
            guard localFlags == flags,
                  localMethod == method,
                  localChecksum == checksum,
                  localCompressedSize == compressedSize,
                  localExpandedSize == expandedSize,
                  localNameLength == nameLength
            else { throw SafeArchiveError.malformedArchive }
            let localHeaderEnd = try checkedEnd(
                start: local,
                lengths: [30, localNameLength, localExtraLength],
                limit: centralStart
            )
            let localNameStart = local + 30
            let localName = try storage.read(
                localNameStart..<(localNameStart + localNameLength)
            )
            let localExtraStart = localNameStart + localNameLength
            let localExtra = try storage.read(
                localExtraStart..<(localExtraStart + localExtraLength)
            )
            try validateZIPExtraFields(
                in: localExtra,
                range: 0..<localExtra.count
            )
            guard localName == name else {
                throw SafeArchiveError.malformedArchive
            }
            let dataEnd = try checkedEnd(
                start: localHeaderEnd,
                lengths: [Int(compressedSize)],
                limit: centralStart
            )
            let dataRange = localHeaderEnd..<dataEnd
            let completeLocalRange = local..<dataEnd
            guard localRanges.allSatisfy({ !$0.overlaps(completeLocalRange) }) else {
                throw SafeArchiveError.malformedArchive
            }
            localRanges.append(completeLocalRange)
            records[path] = SafeArchiveEntryRecord(
                dataRange: dataRange,
                checksum: checksum
            )
            cursor = headerEnd
        }
        guard cursor == centralEnd else {
            throw SafeArchiveError.malformedArchive
        }
        return SafeArchive(storage: storage, records: records)
    }

    static func findEndOfCentralDirectory(in tail: Data) throws -> Int {
        guard tail.count >= 22 else {
            throw SafeArchiveError.malformedArchive
        }
        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            if try tail.uint32(at: offset)
                    == ZipSignature.endOfCentralDirectory,
               let commentLength = try? tail.uint16(at: offset + 20),
               offset + 22 + Int(commentLength) == tail.count {
                return offset
            }
        }
        throw SafeArchiveError.malformedArchive
    }

    static func hasStructurallyPlacedZIP64EndRecords(
        storage: SafeArchiveFileStorage,
        centralEnd: Int,
        eocdOffset: Int
    ) throws -> Bool {
        let locatorOffset = eocdOffset - 20
        guard centralEnd >= 0,
              centralEnd <= locatorOffset,
              locatorOffset >= 0
        else { return false }
        let locator = try storage.read(locatorOffset..<eocdOffset)
        guard try locator.uint32(at: 0)
                == ZipSignature.zip64EndOfCentralDirectoryLocator,
              try locator.uint32(at: 4) == 0,
              try locator.uint32(at: 16) == 1,
              try locator.uint64(at: 8) == UInt64(centralEnd)
        else { return false }
        let recordHeaderEnd = try checkedEnd(
            start: centralEnd,
            lengths: [12],
            limit: locatorOffset
        )
        let record = try storage.read(centralEnd..<recordHeaderEnd)
        guard try record.uint32(at: 0)
                == ZipSignature.zip64EndOfCentralDirectory else {
            return false
        }
        let recordSize = try record.uint64(at: 4)
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
}

private final class SafeArchiveFileStorage: SafeArchiveStorage,
    @unchecked Sendable
{
    let byteCount: Int

    private let handle: FileHandle
    private let lock = NSLock()
    private let readObserver: ((Int) -> Void)?

    init(source: URL, readObserver: ((Int) -> Void)?) throws {
        handle = try FileHandle(forReadingFrom: source)
        self.readObserver = readObserver
        do {
            let length = try handle.seekToEnd()
            guard length <= UInt64(Int.max) else {
                throw SafeArchiveError.unsupportedZIP64
            }
            byteCount = Int(length)
            try handle.seek(toOffset: 0)
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit { try? handle.close() }

    func read(_ range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              range.upperBound <= byteCount
        else { throw SafeArchiveError.malformedArchive }
        guard !range.isEmpty else { return Data() }

        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            var output = Data()
            output.reserveCapacity(range.count)
            while output.count < range.count {
                let remaining = range.count - output.count
                guard let chunk = try handle.read(upToCount: remaining),
                      !chunk.isEmpty
                else { throw SafeArchiveError.malformedArchive }
                readObserver?(chunk.count)
                output.append(chunk)
            }
            return output
        } catch let error as SafeArchiveError {
            throw error
        } catch {
            throw SafeArchiveError.malformedArchive
        }
    }
}

private func checkedArchiveOffset(
    _ value: UInt64,
    adding count: UInt64
) throws -> UInt64 {
    let (next, overflow) = value.addingReportingOverflow(count)
    guard !overflow, next <= UInt64(UInt32.max) else {
        throw SafeArchiveError.unsupportedZIP64
    }
    return next
}

private func verifyArchive(
    at source: URL,
    limits: SafeArchiveLimits,
    maximumChunkByteCount: Int
) throws {
    let archive = try SafeArchiveIO.open(at: source, limits: limits)
    for path in archive.paths {
        try archive.consumeEntry(
            at: path,
            maximumChunkByteCount: maximumChunkByteCount,
            consume: { _ in }
        )
    }
}

package enum SafeArchiveSaveHookError: Error, Equatable {
    case beforeReplacement
}
