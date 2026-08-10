import Foundation

public enum SafeArchiveIO {
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

            _ = try SafeArchiveCodec.open(
                Data(contentsOf: temporary, options: [.mappedIfSafe]),
                limits: limits
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
            _ = try SafeArchiveCodec.open(
                Data(contentsOf: temporary, options: [.mappedIfSafe]),
                limits: limits
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

package enum SafeArchiveSaveHookError: Error, Equatable {
    case beforeReplacement
}
