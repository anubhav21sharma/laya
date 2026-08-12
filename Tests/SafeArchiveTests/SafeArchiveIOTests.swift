import Foundation
@testable import SafeArchive
import Testing

@Suite("Safe archive I/O")
struct SafeArchiveIOTests {
    @Test
    func fileBackedOpenPreflightsMetadataAndStreamsBoundedPayloadReads()
        throws
    {
        let fixture = try TemporaryArchiveFixture()
        defer { fixture.close() }
        let limits = SafeArchiveLimits(
            maximumEntryCount: 2,
            maximumEntryBytes: 256 * 1_024,
            maximumExpandedBytes: 256 * 1_024,
            maximumPathBytes: 128
        )
        let payload = Data(repeating: 0x5A, count: 192 * 1_024)
        let encoded = try SafeArchiveCodec.encode(
            entries: ["tiles/large.bin": payload],
            limits: limits
        )
        try encoded.write(to: fixture.destination)
        var reads: [Int] = []
        let archive = try SafeArchiveIO.open(
            at: fixture.destination,
            limits: limits,
            readObserver: { reads.append($0) }
        )
        let preflightReadBytes = reads.reduce(0, +)
        #expect(preflightReadBytes < encoded.count / 2)
        #expect((reads.max() ?? 0) <= 65_557)

        var decoded = Data()
        try archive.consumeEntry(
            at: "tiles/large.bin",
            maximumChunkByteCount: 4_096
        ) { decoded.append($0) }
        #expect(decoded == payload)
        #expect((reads.max() ?? 0) <= 65_557)
        #expect(!reads.contains(encoded.count))
    }

    @Test
    func fileBackedOpenDefersPayloadChecksumToBoundedConsumption() throws {
        let fixture = try TemporaryArchiveFixture()
        defer { fixture.close() }
        let payload = Data((0..<64).map(UInt8.init))
        var encoded = try SafeArchiveCodec.encode(
            entries: ["tile.bin": payload],
            limits: .testing
        )
        let payloadRange = try #require(encoded.range(of: payload))
        encoded[payloadRange.lowerBound] ^= 0xFF
        try encoded.write(to: fixture.destination)

        let archive = try SafeArchiveIO.open(
            at: fixture.destination,
            limits: .testing
        )
        #expect(throws: SafeArchiveError.checksumMismatch("tile.bin")) {
            try archive.consumeEntry(
                at: "tile.bin",
                maximumChunkByteCount: 7,
                consume: { _ in }
            )
        }
    }

    @Test
    func streamingProviderIsBoundedClosedOnceAndByteCanonical() throws {
        let fixture = try TemporaryArchiveFixture()
        defer { fixture.close() }
        let entries = [
            "b.bin": Data((0..<29).map(UInt8.init)),
            "a.bin": Data((100..<117).map(UInt8.init)),
        ]
        let provider = TestArchiveEntryProvider(entries: entries)

        try SafeArchiveIO.save(
            provider: provider,
            to: fixture.destination,
            limits: .testing,
            maximumChunkByteCount: 7
        )

        #expect(provider.closeCount == 1)
        #expect(provider.maximumRequestedChunkByteCount == 7)
        #expect(provider.maximumEmittedChunkByteCount <= 7)
        #expect(try Data(contentsOf: fixture.destination)
            == SafeArchiveCodec.encode(entries: entries, limits: .testing))
    }

    @Test
    func streamingProviderRejectsDeclaredSizeAndOversizedChunkAtomically() throws {
        let fixture = try TemporaryArchiveFixture()
        defer { fixture.close() }
        try SafeArchiveIO.save(
            entries: ["entry.bin": Data("old".utf8)],
            to: fixture.destination,
            limits: .testing
        )
        let original = try Data(contentsOf: fixture.destination)

        let short = TestArchiveEntryProvider(
            entries: ["entry.bin": Data([1, 2, 3])],
            declaredByteCounts: ["entry.bin": 4]
        )
        #expect(throws: SafeArchiveError.entrySizeMismatch(
            path: "entry.bin",
            expected: 4,
            actual: 3
        )) {
            try SafeArchiveIO.save(
                provider: short,
                to: fixture.destination,
                limits: .testing,
                maximumChunkByteCount: 2
            )
        }
        #expect(short.closeCount == 1)
        #expect(try Data(contentsOf: fixture.destination) == original)

        let oversized = TestArchiveEntryProvider(
            entries: ["entry.bin": Data([1, 2, 3])],
            ignoresRequestedChunkBound: true
        )
        #expect(throws: SafeArchiveError.chunkTooLarge(
            path: "entry.bin",
            actual: 3,
            maximum: 2
        )) {
            try SafeArchiveIO.save(
                provider: oversized,
                to: fixture.destination,
                limits: .testing,
                maximumChunkByteCount: 2
            )
        }
        #expect(oversized.closeCount == 1)
        #expect(try Data(contentsOf: fixture.destination) == original)
    }

    @Test
    func streamingProviderPreflightsDuplicateUnsafeAndAggregateLimits() throws {
        let fixture = try TemporaryArchiveFixture()
        defer { fixture.close() }
        let duplicateID = TestArchiveEntryProvider(
            descriptors: [
                .init(path: "same.bin", byteCount: 1),
                .init(path: "same.bin", byteCount: 1),
            ],
            entries: ["same.bin": Data([1])]
        )
        #expect(throws: SafeArchiveError.duplicateEntry("same.bin")) {
            try SafeArchiveIO.save(
                provider: duplicateID,
                to: fixture.destination,
                limits: .testing,
                maximumChunkByteCount: 8
            )
        }
        #expect(duplicateID.providedPaths.isEmpty)
        #expect(duplicateID.closeCount == 1)

        let unsafe = TestArchiveEntryProvider(
            entries: ["../bad": Data([1])]
        )
        #expect(throws: SafeArchiveError.unsafePath("../bad")) {
            try SafeArchiveIO.save(
                provider: unsafe,
                to: fixture.destination,
                limits: .testing,
                maximumChunkByteCount: 8
            )
        }
        #expect(unsafe.providedPaths.isEmpty)
        #expect(unsafe.closeCount == 1)

        let aggregate = TestArchiveEntryProvider(entries: [
            "a": Data(repeating: 1, count: 3),
            "b": Data(repeating: 2, count: 3),
        ])
        #expect(throws: SafeArchiveError.archiveTooLarge(
            actual: 6,
            maximum: 5
        )) {
            try SafeArchiveIO.save(
                provider: aggregate,
                to: fixture.destination,
                limits: SafeArchiveLimits(
                    maximumEntryCount: 2,
                    maximumEntryBytes: 4,
                    maximumExpandedBytes: 5,
                    maximumPathBytes: 32
                ),
                maximumChunkByteCount: 2
            )
        }
        #expect(aggregate.providedPaths.isEmpty)
        #expect(aggregate.closeCount == 1)
    }

    @Test(arguments: [0, 1, 2])
    func providerThrowAtEveryChunkPreservesDestinationAndCloses(
        failingChunk: Int
    ) throws {
        let fixture = try TemporaryArchiveFixture()
        defer { fixture.close() }
        try SafeArchiveIO.save(
            entries: ["entry.bin": Data("old".utf8)],
            to: fixture.destination,
            limits: .testing
        )
        let original = try Data(contentsOf: fixture.destination)
        let provider = TestArchiveEntryProvider(
            entries: ["entry.bin": Data((0..<12).map(UInt8.init))],
            failingChunkIndex: failingChunk
        )

        #expect(throws: TestArchiveStreamError.injected(failingChunk)) {
            try SafeArchiveIO.save(
                provider: provider,
                to: fixture.destination,
                limits: .testing,
                maximumChunkByteCount: 4
            )
        }
        #expect(provider.closeCount == 1)
        #expect(try Data(contentsOf: fixture.destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: fixture.directory.path
        ) == ["archive.zip"])
    }

    @Test
    func consumerReceivesBoundedSortedEntriesAndClosesOnce() throws {
        let encoded = try SafeArchiveCodec.encode(
            entries: [
                "b.bin": Data((0..<13).map(UInt8.init)),
                "a.bin": Data((30..<39).map(UInt8.init)),
            ],
            limits: .testing
        )
        let archive = try SafeArchiveCodec.open(encoded, limits: .testing)
        let consumer = TestArchiveEntryConsumer()

        try archive.consumeEntries(
            maximumChunkByteCount: 5,
            consumer: consumer
        )

        #expect(consumer.startedPaths == ["a.bin", "b.bin"])
        #expect(consumer.finishedPaths == ["a.bin", "b.bin"])
        #expect(consumer.maximumChunkByteCount <= 5)
        #expect(consumer.closeCount == 1)
        #expect(consumer.payloads["a.bin"] == Data((30..<39).map(UInt8.init)))
        #expect(consumer.payloads["b.bin"] == Data((0..<13).map(UInt8.init)))
    }

    @Test(arguments: [0, 1, 2])
    func consumerThrowAtEveryChunkClosesExactlyOnce(failingChunk: Int) throws {
        let encoded = try SafeArchiveCodec.encode(
            entries: ["entry.bin": Data((0..<12).map(UInt8.init))],
            limits: .testing
        )
        let archive = try SafeArchiveCodec.open(encoded, limits: .testing)
        let consumer = TestArchiveEntryConsumer(
            failingChunkIndex: failingChunk
        )

        #expect(throws: TestArchiveStreamError.injected(failingChunk)) {
            try archive.consumeEntries(
                maximumChunkByteCount: 4,
                consumer: consumer
            )
        }
        #expect(consumer.closeCount == 1)
    }

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

private enum TestArchiveStreamError: Error, Equatable {
    case injected(Int)
}

private final class TestArchiveEntryProvider: SafeArchiveEntryProvider {
    let descriptors: [SafeArchiveEntryDescriptor]
    let entries: [String: Data]
    let failingChunkIndex: Int?
    let ignoresRequestedChunkBound: Bool
    private(set) var closeCount = 0
    private(set) var maximumRequestedChunkByteCount = 0
    private(set) var maximumEmittedChunkByteCount = 0
    private(set) var providedPaths: [String] = []

    init(
        entries: [String: Data],
        declaredByteCounts: [String: UInt64] = [:],
        failingChunkIndex: Int? = nil,
        ignoresRequestedChunkBound: Bool = false
    ) {
        self.entries = entries
        descriptors = entries.keys.map {
            SafeArchiveEntryDescriptor(
                path: $0,
                byteCount: declaredByteCounts[$0] ?? UInt64(entries[$0]!.count)
            )
        }
        self.failingChunkIndex = failingChunkIndex
        self.ignoresRequestedChunkBound = ignoresRequestedChunkBound
    }

    init(
        descriptors: [SafeArchiveEntryDescriptor],
        entries: [String: Data]
    ) {
        self.descriptors = descriptors
        self.entries = entries
        failingChunkIndex = nil
        ignoresRequestedChunkBound = false
    }

    func archiveEntries() throws -> [SafeArchiveEntryDescriptor] {
        descriptors
    }

    func provideChunks(
        for path: String,
        maximumChunkByteCount: Int,
        consume: (Data) throws -> Void
    ) throws {
        providedPaths.append(path)
        maximumRequestedChunkByteCount = max(
            self.maximumRequestedChunkByteCount,
            maximumChunkByteCount
        )
        let payload = entries[path] ?? Data()
        let step = ignoresRequestedChunkBound
            ? max(payload.count, 1)
            : maximumChunkByteCount
        var chunkIndex = 0
        var offset = 0
        while offset < payload.count {
            if failingChunkIndex == chunkIndex {
                throw TestArchiveStreamError.injected(chunkIndex)
            }
            let end = min(payload.count, offset + step)
            let chunk = payload.subdata(in: offset..<end)
            maximumEmittedChunkByteCount = max(
                maximumEmittedChunkByteCount,
                chunk.count
            )
            try consume(chunk)
            offset = end
            chunkIndex += 1
        }
    }

    func close() { closeCount += 1 }
}

private final class TestArchiveEntryConsumer: SafeArchiveEntryConsumer {
    let failingChunkIndex: Int?
    private(set) var startedPaths: [String] = []
    private(set) var finishedPaths: [String] = []
    private(set) var payloads: [String: Data] = [:]
    private(set) var maximumChunkByteCount = 0
    private(set) var closeCount = 0
    private var chunkIndex = 0

    init(failingChunkIndex: Int? = nil) {
        self.failingChunkIndex = failingChunkIndex
    }

    func beginEntry(_ entry: SafeArchiveEntryDescriptor) throws {
        startedPaths.append(entry.path)
        payloads[entry.path] = Data()
    }

    func consume(_ chunk: Data, for path: String) throws {
        if failingChunkIndex == chunkIndex {
            throw TestArchiveStreamError.injected(chunkIndex)
        }
        maximumChunkByteCount = max(maximumChunkByteCount, chunk.count)
        payloads[path]!.append(chunk)
        chunkIndex += 1
    }

    func finishEntry(_ entry: SafeArchiveEntryDescriptor) throws {
        finishedPaths.append(entry.path)
    }

    func close() { closeCount += 1 }
}

private final class TemporaryArchiveFixture {
    let directory: URL
    let destination: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        destination = directory.appendingPathComponent("archive.zip")
    }

    func close() { try? FileManager.default.removeItem(at: directory) }
}

private extension SafeArchiveLimits {
    static let testing = SafeArchiveLimits(
        maximumEntryCount: 16,
        maximumEntryBytes: 1_024,
        maximumExpandedBytes: 4_096,
        maximumPathBytes: 128
    )
}
