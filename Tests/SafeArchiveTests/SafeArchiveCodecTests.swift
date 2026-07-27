import Foundation
@testable import SafeArchive
import Testing

@Suite("Safe archive codec")
struct SafeArchiveCodecTests {
    @Test
    func encodingIsDeterministicAndSorted() throws {
        let limits = SafeArchiveLimits.testing
        let first = try SafeArchiveCodec.encode(
            entries: ["b.bin": Data([2]), "a.bin": Data([1])],
            limits: limits
        )
        let second = try SafeArchiveCodec.encode(
            entries: ["a.bin": Data([1]), "b.bin": Data([2])],
            limits: limits
        )

        #expect(first == second)
        let archive = try SafeArchiveCodec.open(first, limits: limits)
        #expect(archive.paths == ["a.bin", "b.bin"])
        #expect(try archive.data(for: "a.bin") == Data([1]))
    }

    @Test
    func encoderRejectsEmptyUnsafeAndOversizedEntries() throws {
        let limits = SafeArchiveLimits(
            maximumEntryCount: 1,
            maximumEntryBytes: 2,
            maximumExpandedBytes: 2,
            maximumPathBytes: 128
        )

        #expect(throws: SafeArchiveError.emptyArchive) {
            try SafeArchiveCodec.encode(entries: [:], limits: limits)
        }
        #expect(throws: SafeArchiveError.unsafePath("../bad")) {
            try SafeArchiveCodec.encode(
                entries: ["../bad": Data()],
                limits: limits
            )
        }
        #expect(
            throws: SafeArchiveError.entryTooLarge(
                path: "a",
                actual: 3,
                maximum: 2
            )
        ) {
            try SafeArchiveCodec.encode(
                entries: ["a": Data([1, 2, 3])],
                limits: limits
            )
        }
        for path in ["C:/payload", "c:/payload", "C:payload", "c:payload"] {
            #expect(throws: SafeArchiveError.unsafePath(path)) {
                try SafeArchiveCodec.encode(entries: [path: Data()], limits: limits)
            }
        }
        #expect(try SafeArchiveCodec.encode(
            entries: ["metadata:version": Data()],
            limits: limits
        ).isEmpty == false)
    }

    @Test
    func readerRejectsUnsafeDuplicateAndDirectoryEntries() throws {
        var traversal = try archive(entries: ["safe.txt": Data("x".utf8)])
        replaceAll(
            bytes: Array("safe.txt".utf8),
            with: Array("../a.txt".utf8),
            in: &traversal
        )
        #expect(throws: SafeArchiveError.unsafePath("../a.txt")) {
            try SafeArchiveCodec.open(traversal, limits: .testing)
        }

        var driveQualified = try archive(entries: ["safe.txt": Data("x".utf8)])
        replaceAll(
            bytes: Array("safe.txt".utf8),
            with: Array("c:/x.txt".utf8),
            in: &driveQualified
        )
        #expect(throws: SafeArchiveError.unsafePath("c:/x.txt")) {
            try SafeArchiveCodec.open(driveQualified, limits: .testing)
        }

        var driveRelative = try archive(entries: ["entry.bin": Data("x".utf8)])
        replaceAll(
            bytes: Array("entry.bin".utf8),
            with: Array("c:payload".utf8),
            in: &driveRelative
        )
        #expect(throws: SafeArchiveError.unsafePath("c:payload")) {
            try SafeArchiveCodec.open(driveRelative, limits: .testing)
        }

        var duplicate = try archive(entries: [
            "a.txt": Data("a".utf8),
            "b.txt": Data("b".utf8),
        ])
        let secondCentral = try #require(
            signatureOffsets(0x0201_4B50, in: duplicate).last
        )
        duplicate.replaceSubrange(
            (secondCentral + 46)..<(secondCentral + 51),
            with: Data("a.txt".utf8)
        )
        #expect(throws: SafeArchiveError.duplicateEntry("a.txt")) {
            try SafeArchiveCodec.open(duplicate, limits: .testing)
        }

        var directory = try archive(entries: ["entry.bin": Data([1])])
        let central = try #require(
            signatureOffsets(0x0201_4B50, in: directory).first
        )
        setUInt32(0x41ED_0000, at: central + 38, in: &directory)
        #expect(throws: SafeArchiveError.unsafePath("entry.bin")) {
            try SafeArchiveCodec.open(directory, limits: .testing)
        }

        var dosDirectory = try archive(entries: ["entry.bin": Data([1])])
        let dosCentral = try #require(
            signatureOffsets(0x0201_4B50, in: dosDirectory).first
        )
        setUInt16(20, at: dosCentral + 4, in: &dosDirectory)
        setUInt32(0x10, at: dosCentral + 38, in: &dosDirectory)
        #expect(throws: SafeArchiveError.unsafePath("entry.bin")) {
            try SafeArchiveCodec.open(dosDirectory, limits: .testing)
        }

        var macOSSymlink = try archive(entries: ["entry.bin": Data([1])])
        let macOSSymlinkCentral = try #require(
            signatureOffsets(0x0201_4B50, in: macOSSymlink).first
        )
        setUInt16(0x1314, at: macOSSymlinkCentral + 4, in: &macOSSymlink)
        setUInt32(0xA1FF_0000, at: macOSSymlinkCentral + 38, in: &macOSSymlink)
        #expect(throws: SafeArchiveError.symbolicLink("entry.bin")) {
            try SafeArchiveCodec.open(macOSSymlink, limits: .testing)
        }

        var macOSDirectory = try archive(entries: ["entry.bin": Data([1])])
        let macOSDirectoryCentral = try #require(
            signatureOffsets(0x0201_4B50, in: macOSDirectory).first
        )
        setUInt16(0x1314, at: macOSDirectoryCentral + 4, in: &macOSDirectory)
        setUInt32(0x41ED_0000, at: macOSDirectoryCentral + 38, in: &macOSDirectory)
        #expect(throws: SafeArchiveError.unsafePath("entry.bin")) {
            try SafeArchiveCodec.open(macOSDirectory, limits: .testing)
        }

        var macOSRegularWithDOSDirectory = try archive(entries: ["entry.bin": Data([1])])
        let macOSRegularCentral = try #require(
            signatureOffsets(0x0201_4B50, in: macOSRegularWithDOSDirectory).first
        )
        setUInt16(0x1314, at: macOSRegularCentral + 4, in: &macOSRegularWithDOSDirectory)
        setUInt32(0x81A4_0010, at: macOSRegularCentral + 38, in: &macOSRegularWithDOSDirectory)
        #expect(throws: SafeArchiveError.unsafePath("entry.bin")) {
            try SafeArchiveCodec.open(macOSRegularWithDOSDirectory, limits: .testing)
        }
    }

    @Test
    func readerRejectsZIP64FlagsCompressionLinksAndDescriptors() throws {
        let original = try archive(entries: ["entry.bin": Data([1, 2, 3])])
        let local = try #require(
            signatureOffsets(0x0403_4B50, in: original).first
        )
        let central = try #require(
            signatureOffsets(0x0201_4B50, in: original).first
        )

        var zip64 = original
        setUInt32(UInt32.max, at: central + 20, in: &zip64)
        #expect(throws: SafeArchiveError.unsupportedZIP64) {
            try SafeArchiveCodec.open(zip64, limits: .testing)
        }

        var encrypted = original
        setUInt16(0x0801, at: local + 6, in: &encrypted)
        setUInt16(0x0801, at: central + 8, in: &encrypted)
        #expect(
            throws: SafeArchiveError.unsupportedArchiveFlags(
                path: "entry.bin",
                flags: 0x0801
            )
        ) {
            try SafeArchiveCodec.open(encrypted, limits: .testing)
        }

        var descriptor = original
        setUInt16(0x0808, at: local + 6, in: &descriptor)
        setUInt16(0x0808, at: central + 8, in: &descriptor)
        #expect(
            throws: SafeArchiveError.unsupportedArchiveFlags(
                path: "entry.bin",
                flags: 0x0808
            )
        ) {
            try SafeArchiveCodec.open(descriptor, limits: .testing)
        }

        var compressed = original
        setUInt16(8, at: local + 8, in: &compressed)
        setUInt16(8, at: central + 10, in: &compressed)
        #expect(
            throws: SafeArchiveError.unsupportedCompression(
                path: "entry.bin",
                method: 8
            )
        ) {
            try SafeArchiveCodec.open(compressed, limits: .testing)
        }

        var link = original
        setUInt32(0xA1FF_0000, at: central + 38, in: &link)
        #expect(throws: SafeArchiveError.symbolicLink("entry.bin")) {
            try SafeArchiveCodec.open(link, limits: .testing)
        }
    }

    @Test
    func readerRejectsZIP64SentinelsInLocalHeaders() throws {
        let original = try archive(entries: ["entry.bin": Data([1, 2, 3])])
        let local = try #require(
            signatureOffsets(0x0403_4B50, in: original).first
        )
        var zip64 = original
        setUInt32(UInt32.max, at: local + 18, in: &zip64)

        #expect(throws: SafeArchiveError.unsupportedZIP64) {
            try SafeArchiveCodec.open(zip64, limits: .testing)
        }
    }

    @Test
    func readerRejectsZIP64EOCDSentinelsAndMarkers() throws {
        let original = try archive(entries: ["entry.bin": Data([1, 2, 3])])
        let eocd = try #require(
            signatureOffsets(0x0605_4B50, in: original).first
        )

        var diskSentinel = original
        setUInt16(UInt16.max, at: eocd + 4, in: &diskSentinel)
        #expect(throws: SafeArchiveError.unsupportedZIP64) {
            try SafeArchiveCodec.open(diskSentinel, limits: .testing)
        }

        var entryCountSentinel = original
        setUInt16(UInt16.max, at: eocd + 10, in: &entryCountSentinel)
        #expect(throws: SafeArchiveError.unsupportedZIP64) {
            try SafeArchiveCodec.open(entryCountSentinel, limits: .testing)
        }

        var multiDisk = original
        setUInt16(1, at: eocd + 4, in: &multiDisk)
        #expect(throws: SafeArchiveError.malformedArchive) {
            try SafeArchiveCodec.open(multiDisk, limits: .testing)
        }

        let zip64Layout = try insertingZIP64EndRecords(into: original)
        #expect(throws: SafeArchiveError.unsupportedZIP64) {
            try SafeArchiveCodec.open(zip64Layout, limits: .testing)
        }

        var malformedLayout = zip64Layout
        let recordOffset = eocd
        setUInt32(0, at: recordOffset, in: &malformedLayout)
        #expect(throws: SafeArchiveError.malformedArchive) {
            try SafeArchiveCodec.open(malformedLayout, limits: .testing)
        }
    }

    @Test
    func ordinaryCentralNameBeginningWithZIP64LocatorBytesRoundTrips() throws {
        let path = "PK\u{0006}\u{0007}" + String(repeating: "x", count: 16)
        #expect(path.utf8.count == 20)
        let encoded = try SafeArchiveCodec.encode(
            entries: [path: Data([1, 2, 3])],
            limits: .testing
        )

        let archive = try SafeArchiveCodec.open(encoded, limits: .testing)
        #expect(archive.paths == [path])
        #expect(try archive.data(for: path) == Data([1, 2, 3]))
    }

    @Test
    func readerRejectsZIP64AndMalformedExtraFields() throws {
        let original = try archive(entries: ["entry.bin": Data([1, 0, 0, 0, 9])])
        let local = try #require(
            signatureOffsets(0x0403_4B50, in: original).first
        )
        let central = try #require(
            signatureOffsets(0x0201_4B50, in: original).first
        )

        var localZIP64 = original
        setUInt16(4, at: local + 28, in: &localZIP64)
        #expect(throws: SafeArchiveError.unsupportedZIP64) {
            try SafeArchiveCodec.open(localZIP64, limits: .testing)
        }

        var centralZIP64 = original
        setUInt16(5, at: central + 28, in: &centralZIP64)
        setUInt16(4, at: central + 30, in: &centralZIP64)
        centralZIP64.replaceSubrange(
            (central + 51)..<(central + 55),
            with: Data([1, 0, 0, 0])
        )
        #expect(throws: SafeArchiveError.unsupportedZIP64) {
            try SafeArchiveCodec.open(centralZIP64, limits: .testing)
        }

        var malformed = original
        setUInt16(8, at: local + 26, in: &malformed)
        setUInt16(1, at: local + 28, in: &malformed)
        setUInt16(8, at: central + 28, in: &malformed)
        setUInt16(1, at: central + 30, in: &malformed)
        #expect(throws: SafeArchiveError.malformedArchive) {
            try SafeArchiveCodec.open(malformed, limits: .testing)
        }
    }

    @Test
    func readerAcceptsUnrelatedWellFormedExtraFields() throws {
        let original = try archive(entries: ["entry.bin": Data([1, 2, 3])])
        let withExtras = try insertingUnrelatedExtraFields(into: original)

        let archive = try SafeArchiveCodec.open(withExtras, limits: .testing)
        #expect(try archive.data(for: "entry.bin") == Data([1, 2, 3]))
    }

    @Test
    func readerRejectsZIP64EntryDiskButKeepsOrdinaryMultiDiskMalformed() throws {
        let original = try archive(entries: ["entry.bin": Data([1])])
        let central = try #require(
            signatureOffsets(0x0201_4B50, in: original).first
        )

        var zip64 = original
        setUInt16(UInt16.max, at: central + 34, in: &zip64)
        #expect(throws: SafeArchiveError.unsupportedZIP64) {
            try SafeArchiveCodec.open(zip64, limits: .testing)
        }

        var multiDisk = original
        setUInt16(1, at: central + 34, in: &multiDisk)
        #expect(throws: SafeArchiveError.malformedArchive) {
            try SafeArchiveCodec.open(multiDisk, limits: .testing)
        }
    }

    @Test
    func readerRejectsChecksumTruncationAndConfiguredLimits() throws {
        let original = try archive(entries: ["entry.bin": Data([1, 2, 3])])
        let local = try #require(
            signatureOffsets(0x0403_4B50, in: original).first
        )
        let nameLength = Int(uint16(at: local + 26, in: original))
        let payload = local + 30 + nameLength
        var checksumMismatch = original
        checksumMismatch[payload] ^= 0xFF
        #expect(throws: SafeArchiveError.checksumMismatch("entry.bin")) {
            try SafeArchiveCodec.open(checksumMismatch, limits: .testing)
        }
        #expect(throws: SafeArchiveError.malformedArchive) {
            try SafeArchiveCodec.open(original.dropLast(), limits: .testing)
        }

        let limited = SafeArchiveLimits(
            maximumEntryCount: 1,
            maximumEntryBytes: 2,
            maximumExpandedBytes: 2,
            maximumPathBytes: 128
        )
        #expect(
            throws: SafeArchiveError.entryTooLarge(
                path: "entry.bin",
                actual: 3,
                maximum: 2
            )
        ) {
            try SafeArchiveCodec.open(original, limits: limited)
        }
        #expect(
            throws: SafeArchiveError.entryCountOutOfRange(2)
        ) {
            try SafeArchiveCodec.open(
                archive(entries: ["a": Data(), "b": Data()]),
                limits: limited
            )
        }
        #expect(
            throws: SafeArchiveError.archiveTooLarge(
                actual: 4,
                maximum: 2
            )
        ) {
            try SafeArchiveCodec.open(
                archive(entries: ["a": Data([1, 2]), "b": Data([3, 4])]),
                limits: SafeArchiveLimits(
                    maximumEntryCount: 2,
                    maximumEntryBytes: 2,
                    maximumExpandedBytes: 2,
                    maximumPathBytes: 8
                )
            )
        }
    }
}

private extension SafeArchiveLimits {
    static let testing = SafeArchiveLimits(
        maximumEntryCount: 16,
        maximumEntryBytes: 1_024,
        maximumExpandedBytes: 4_096,
        maximumPathBytes: 128
    )
}

private func archive(entries: [String: Data]) throws -> Data {
    try SafeArchiveCodec.encode(entries: entries, limits: .testing)
}

private func signatureOffsets(_ signature: UInt32, in data: Data) -> [Int] {
    guard data.count >= 4 else { return [] }
    return (0...(data.count - 4)).filter { uint32(at: $0, in: data) == signature }
}

private func replaceAll(bytes: [UInt8], with replacement: [UInt8], in data: inout Data) {
    precondition(bytes.count == replacement.count)
    guard data.count >= bytes.count else { return }
    for offset in stride(from: data.count - bytes.count, through: 0, by: -1)
    where Array(data[offset..<(offset + bytes.count)]) == bytes {
        data.replaceSubrange(offset..<(offset + bytes.count), with: replacement)
    }
}

private func uint16(at offset: Int, in data: Data) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func uint32(at offset: Int, in data: Data) -> UInt32 {
    UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
}

private func setUInt16(_ value: UInt16, at offset: Int, in data: inout Data) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

private func setUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}

private func insertingUnrelatedExtraFields(into data: Data) throws -> Data {
    var result = data
    let local = try #require(signatureOffsets(0x0403_4B50, in: result).first)
    let localNameLength = Int(uint16(at: local + 26, in: result))
    let localExtra = Data([0xFE, 0xCA, 0, 0])
    let localExtraOffset = local + 30 + localNameLength
    result.insert(contentsOf: localExtra, at: localExtraOffset)
    setUInt16(UInt16(localExtra.count), at: local + 28, in: &result)

    let central = try #require(signatureOffsets(0x0201_4B50, in: result).first)
    let centralNameLength = Int(uint16(at: central + 28, in: result))
    let centralExtra = Data([0xFE, 0xCA, 0, 0])
    let centralExtraOffset = central + 46 + centralNameLength
    result.insert(contentsOf: centralExtra, at: centralExtraOffset)
    setUInt16(UInt16(centralExtra.count), at: central + 30, in: &result)

    let eocd = try #require(signatureOffsets(0x0605_4B50, in: result).first)
    setUInt32(uint32(at: eocd + 12, in: result) + UInt32(centralExtra.count), at: eocd + 12, in: &result)
    setUInt32(uint32(at: eocd + 16, in: result) + UInt32(localExtra.count), at: eocd + 16, in: &result)
    return result
}

private func insertingZIP64EndRecords(into data: Data) throws -> Data {
    var result = data
    let eocd = try #require(signatureOffsets(0x0605_4B50, in: result).first)
    let centralSize = UInt64(uint32(at: eocd + 12, in: result))
    let entryCount = UInt64(uint16(at: eocd + 10, in: result))

    var record = Data()
    appendUInt32(0x0606_4B50, to: &record)
    appendUInt64(44, to: &record)
    appendUInt16(45, to: &record)
    appendUInt16(45, to: &record)
    appendUInt32(0, to: &record)
    appendUInt32(0, to: &record)
    appendUInt64(entryCount, to: &record)
    appendUInt64(entryCount, to: &record)
    appendUInt64(centralSize, to: &record)
    appendUInt64(UInt64(eocd), to: &record)

    var locator = Data()
    appendUInt32(0x0706_4B50, to: &locator)
    appendUInt32(0, to: &locator)
    appendUInt64(UInt64(eocd), to: &locator)
    appendUInt32(1, to: &locator)

    result.insert(contentsOf: record + locator, at: eocd)
    return result
}

private func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
}

private func appendUInt64(_ value: UInt64, to data: inout Data) {
    appendUInt32(UInt32(truncatingIfNeeded: value), to: &data)
    appendUInt32(UInt32(truncatingIfNeeded: value >> 32), to: &data)
}
