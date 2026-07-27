import Foundation
@testable import SafeArchive
import Testing

@Suite("Safe archive I/O")
struct SafeArchiveIOTests {
    @Test
    func saveWritesAnArchiveThatCanBeReopened() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("archive.zip")
        try SafeArchiveIO.save(
            entries: ["entry.bin": Data([1, 2, 3])],
            to: destination,
            limits: .testing
        )
        let reopened = try SafeArchiveCodec.open(
            Data(contentsOf: destination),
            limits: .testing
        )
        #expect(try reopened.data(for: "entry.bin") == Data([1, 2, 3]))
    }

    @Test
    func beforeReplacementHookSeesValidatedTemporaryAndCleansItUp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("archive.zip")
        try SafeArchiveIO.save(
            entries: ["entry.bin": Data("old".utf8)],
            to: destination,
            limits: .testing
        )
        var sawValidatedTemporary = false
        #expect(throws: SafeArchiveSaveHookError.beforeReplacement) {
            try SafeArchiveIO.save(
                entries: ["entry.bin": Data("new".utf8)],
                to: destination,
                limits: .testing,
                beforeReplacement: { temporary in
                    let archive = try SafeArchiveCodec.open(
                        Data(contentsOf: temporary),
                        limits: .testing
                    )
                    #expect(
                        try archive.data(for: "entry.bin") == Data("new".utf8)
                    )
                    sawValidatedTemporary = true
                    throw SafeArchiveSaveHookError.beforeReplacement
                }
            )
        }
        #expect(sawValidatedTemporary)
        let destinationArchive = try SafeArchiveCodec.open(
            Data(contentsOf: destination),
            limits: .testing
        )
        #expect(
            try destinationArchive.data(for: "entry.bin") == Data("old".utf8)
        )
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                == ["archive.zip"]
        )
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
