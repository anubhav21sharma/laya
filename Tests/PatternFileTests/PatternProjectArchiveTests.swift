import Foundation
@testable import PatternFile
import Testing

@Suite("Pattern project archive")
struct PatternProjectArchiveTests {
    @Test
    func storedZIPRoundTripsDeterministically() throws {
        let entries: [String: Data] = [
            "manifest.json": Data("{\"schemaVersion\":2}".utf8),
            "layers/layer.json": Data("layer".utf8),
            "rasters/layer.png": Data((0..<251).map(UInt8.init)),
        ]

        let first = try PatternProjectArchiveCodec.encode(entries: entries)
        let second = try PatternProjectArchiveCodec.encode(entries: entries)
        #expect(first == second)

        let archive = try PatternProjectArchiveCodec.open(first)
        #expect(archive.paths == entries.keys.sorted())
        for (path, expected) in entries {
            #expect(try archive.data(for: path) == expected)
        }
        #expect(
            throws: PatternProjectArchiveError.missingEntry("absent")
        ) {
            try archive.data(for: "absent")
        }
    }

    @Test
    func generatedArchiveIsAcceptedBySystemUnzip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appendingPathComponent("interop.zip")
        try PatternProjectArchiveIO.save(
            entries: [
                "manifest.json": Data("{\"schemaVersion\":2}".utf8),
                "rasters/layer.png": Data((0..<251).map(UInt8.init)),
            ],
            to: archiveURL
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tqq", archiveURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func encoderRejectsEmptyAndUnsafeArchives() {
        #expect(throws: PatternProjectArchiveError.emptyArchive) {
            try PatternProjectArchiveCodec.encode(entries: [:])
        }
        for path in [
            "../outside",
            "/absolute",
            "nested//empty",
            "nested/./dot",
            "nested/../parent",
            "windows\\path",
        ] {
            #expect(
                throws: PatternProjectArchiveError.unsafePath(path),
                "path \(path)"
            ) {
                try PatternProjectArchiveCodec.encode(
                    entries: [path: Data()]
                )
            }
        }
    }

    @Test
    func readerRejectsTraversalAndDuplicateNames() throws {
        var traversal = try PatternProjectArchiveCodec.encode(entries: [
            "safe.txt": Data("payload".utf8),
        ])
        replaceAll(
            bytes: Array("safe.txt".utf8),
            with: Array("../a.txt".utf8),
            in: &traversal
        )
        #expect(
            throws: PatternProjectArchiveError.unsafePath("../a.txt")
        ) {
            try PatternProjectArchiveCodec.open(traversal)
        }

        var duplicate = try PatternProjectArchiveCodec.encode(entries: [
            "a.txt": Data("a".utf8),
            "b.txt": Data("b".utf8),
        ])
        let centralOffsets = signatureOffsets(
            0x0201_4B50,
            in: duplicate
        )
        let second = try #require(centralOffsets.last)
        duplicate.replaceSubrange(
            (second + 46)..<(second + 51),
            with: Data("a.txt".utf8)
        )
        #expect(
            throws: PatternProjectArchiveError.duplicateEntry("a.txt")
        ) {
            try PatternProjectArchiveCodec.open(duplicate)
        }
    }

    @Test
    func readerRejectsCompressionFlagsLinksAndChecksumDamage() throws {
        let original = try PatternProjectArchiveCodec.encode(entries: [
            "entry.bin": Data([1, 2, 3, 4, 5]),
        ])
        let local = try #require(
            signatureOffsets(0x0403_4B50, in: original).first
        )
        let central = try #require(
            signatureOffsets(0x0201_4B50, in: original).first
        )

        var compressed = original
        setUInt16(8, at: local + 8, in: &compressed)
        setUInt16(8, at: central + 10, in: &compressed)
        #expect(
            throws: PatternProjectArchiveError.unsupportedCompression(
                path: "entry.bin",
                method: 8
            )
        ) {
            try PatternProjectArchiveCodec.open(compressed)
        }

        var encrypted = original
        setUInt16(0x0801, at: local + 6, in: &encrypted)
        setUInt16(0x0801, at: central + 8, in: &encrypted)
        #expect(
            throws: PatternProjectArchiveError.unsupportedArchiveFlags(
                path: "entry.bin",
                flags: 0x0801
            )
        ) {
            try PatternProjectArchiveCodec.open(encrypted)
        }

        var link = original
        setUInt32(0xA1FF_0000, at: central + 38, in: &link)
        #expect(
            throws: PatternProjectArchiveError.symbolicLink("entry.bin")
        ) {
            try PatternProjectArchiveCodec.open(link)
        }

        var damaged = original
        let nameLength = Int(uint16(at: local + 26, in: damaged))
        let extraLength = Int(uint16(at: local + 28, in: damaged))
        let payload = local + 30 + nameLength + extraLength
        damaged[payload] ^= 0xFF
        #expect(
            throws: PatternProjectArchiveError.checksumMismatch("entry.bin")
        ) {
            try PatternProjectArchiveCodec.open(damaged)
        }
    }

    @Test
    func atomicSaveReopensAndInjectedFailurePreservesOldFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent(
            "project.patternproj"
        )
        let oldEntries = ["manifest.json": Data("old".utf8)]
        let newEntries = ["manifest.json": Data("new".utf8)]

        try PatternProjectArchiveIO.save(
            entries: oldEntries,
            to: destination
        )
        #expect(
            try PatternProjectArchiveCodec.open(at: destination)
                .data(for: "manifest.json") == Data("old".utf8)
        )

        #expect(
            throws: PatternProjectArchiveError.injectedSaveFailure
        ) {
            try PatternProjectArchiveIO.save(
                entries: newEntries,
                to: destination,
                injecting: .beforeReplacement
            )
        }
        #expect(
            try PatternProjectArchiveCodec.open(at: destination)
                .data(for: "manifest.json") == Data("old".utf8)
        )
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(leftovers == ["project.patternproj"])

        try PatternProjectArchiveIO.save(
            entries: newEntries,
            to: destination
        )
        #expect(
            try PatternProjectArchiveCodec.open(at: destination)
                .data(for: "manifest.json") == Data("new".utf8)
        )
    }

    @Test
    func truncatedAndNonZIPDataFailClosed() throws {
        #expect(throws: PatternProjectArchiveError.malformedArchive) {
            try PatternProjectArchiveCodec.open(Data("not zip".utf8))
        }
        let valid = try PatternProjectArchiveCodec.encode(entries: [
            "manifest.json": Data("{}".utf8),
        ])
        #expect(throws: PatternProjectArchiveError.malformedArchive) {
            try PatternProjectArchiveCodec.open(valid.dropLast())
        }
    }
}

private func signatureOffsets(
    _ signature: UInt32,
    in data: Data
) -> [Int] {
    guard data.count >= 4 else { return [] }
    return (0...(data.count - 4)).filter {
        uint32(at: $0, in: data) == signature
    }
}

private func replaceAll(
    bytes: [UInt8],
    with replacement: [UInt8],
    in data: inout Data
) {
    precondition(bytes.count == replacement.count)
    guard data.count >= bytes.count else { return }
    for offset in stride(
        from: data.count - bytes.count,
        through: 0,
        by: -1
    ) where Array(data[offset..<(offset + bytes.count)]) == bytes {
        data.replaceSubrange(
            offset..<(offset + bytes.count),
            with: replacement
        )
    }
}

private func uint16(at offset: Int, in data: Data) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func uint32(at offset: Int, in data: Data) -> UInt32 {
    UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

private func setUInt16(
    _ value: UInt16,
    at offset: Int,
    in data: inout Data
) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

private func setUInt32(
    _ value: UInt32,
    at offset: Int,
    in data: inout Data
) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}
