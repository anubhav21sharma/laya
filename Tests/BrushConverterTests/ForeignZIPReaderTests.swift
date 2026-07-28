@testable import BrushConverter
import BrushFormat
import Foundation
import Testing
import zlib

@Suite("Foreign ZIP reader")
struct ForeignZIPReaderTests {
    @Test
    func readsStoredDeflateAndSafeDirectoriesInLocalOffsetOrder() throws {
        let archive = try zip([
            ZIPTestEntry(name: "Assets/", bytes: Data(), isDirectory: true),
            ZIPTestEntry(
                name: "Assets/plain.bin",
                bytes: Data([1, 2, 3]),
                flags: 0
            ),
            ZIPTestEntry(
                name: "Assets/é.txt",
                bytes: Data(repeating: 0x61, count: 2_048),
                method: 8,
                flags: 0x0802
            ),
        ], reversesCentralDirectory: true)

        let reader = try ForeignZIPReader(archive)

        #expect(reader.paths == ["Assets/plain.bin", "Assets/é.txt"])
        #expect(reader.directoryPaths == ["Assets/"])
        #expect(try reader.data(for: "Assets/plain.bin") == Data([1, 2, 3]))
        #expect(
            try reader.data(for: "Assets/e\u{301}.txt")
                == Data(repeating: 0x61, count: 2_048)
        )
    }

    @Test
    func readsDataSlicesWithNonzeroStartIndices() throws {
        let archive = try zip([
            ZIPTestEntry(name: "entry.bin", bytes: Data([1, 2, 3])),
        ])
        var padded = Data([0xFF])
        padded.append(archive)
        let slice = padded.dropFirst()

        #expect(slice.startIndex != 0)
        let reader = try ForeignZIPReader(slice)
        #expect(try reader.data(for: "entry.bin") == Data([1, 2, 3]))
        #expect(throws: ForeignContainerError.sourceTooLarge(
            actual: archive.count,
            maximum: archive.count - 1
        )) {
            _ = try ForeignZIPReader(
                slice,
                limits: ForeignContainerLimits(
                    maximumSourceBytes: archive.count - 1
                )
            )
        }
    }

    @Test
    func defaultLimitsRejectEntriesBeyondPortableResourceBudget() throws {
        let maximum = BrushFormatLimits.maximumEncodedResourceBytes
        let archive = try zip([
            ZIPTestEntry(
                name: "oversized.bin",
                bytes: Data([0]),
                method: 8,
                declaredExpandedSize: maximum + 1
            ),
        ])

        #expect(throws: ForeignContainerError.entryTooLarge(
            path: "oversized.bin",
            actual: maximum + 1,
            maximum: maximum
        )) {
            _ = try ForeignZIPReader(archive)
        }
    }

    @Test
    func rejectsDataDescriptorsEncryptionUnknownFlagsAndInvalidEncodingFlags()
        throws
    {
        for flags: UInt16 in [0x0808, 0x0801, 0x0810] {
            let archive = try zip([
                ZIPTestEntry(
                    name: "entry.bin",
                    bytes: Data([1]),
                    flags: flags
                ),
            ])
            #expect(throws: ForeignContainerError.unsupportedFlags(
                path: "entry.bin",
                flags: flags
            )) {
                try ForeignZIPReader(archive)
            }
        }

        let storedWithDeflateOption = try zip([
            ZIPTestEntry(
                name: "entry.bin",
                bytes: Data([1]),
                flags: 0x0802
            ),
        ])
        #expect(throws: ForeignContainerError.unsupportedFlags(
            path: "entry.bin",
            flags: 0x0802
        )) {
            try ForeignZIPReader(storedWithDeflateOption)
        }

        let nonASCIIWithoutUTF8 = try zip([
            ZIPTestEntry(
                name: "é.bin",
                bytes: Data([1]),
                flags: 0
            ),
        ])
        #expect(throws: ForeignContainerError.nonASCIIPath) {
            try ForeignZIPReader(nonASCIIWithoutUTF8)
        }
    }

    @Test
    func rejectsTraversalNormalizedDuplicatesLinksAndUnsupportedMethods()
        throws
    {
        for path in [
            "../bad.bin",
            "/bad.bin",
            "C:/bad.bin",
            "a//bad.bin",
            "a/./bad.bin",
            "a/../bad.bin",
            "a\\bad.bin",
        ] {
            #expect(throws: ForeignContainerError.unsafePath(path)) {
                try ForeignZIPReader(try zip([
                    ZIPTestEntry(name: path, bytes: Data([1])),
                ]))
            }
        }

        let duplicate = try zip([
            ZIPTestEntry(name: "é.bin", bytes: Data([1])),
            ZIPTestEntry(name: "e\u{301}.bin", bytes: Data([2])),
        ])
        var rejectedDuplicate = false
        do {
            _ = try ForeignZIPReader(duplicate)
        } catch ForeignContainerError.duplicatePath(_) {
            rejectedDuplicate = true
        }
        #expect(rejectedDuplicate)

        let symlink = try zip([
            ZIPTestEntry(
                name: "link",
                bytes: Data([1]),
                externalAttributes: 0xA1FF_0000
            ),
        ])
        #expect(throws: ForeignContainerError.symbolicLink("link")) {
            try ForeignZIPReader(symlink)
        }

        let unsupported = try zip([
            ZIPTestEntry(name: "entry", bytes: Data([1]), method: 12),
        ])
        #expect(throws: ForeignContainerError.unsupportedCompression(
            path: "entry",
            method: 12
        )) {
            try ForeignZIPReader(unsupported)
        }
    }

    @Test
    func rejectsHeaderMismatchZIP64CRCAndMalformedDeflateStreams() throws {
        let valid = try zip([
            ZIPTestEntry(
                name: "entry.bin",
                bytes: Data(repeating: 0x41, count: 1_024),
                method: 8
            ),
        ])
        let local = try #require(signatureOffsets(0x0403_4B50, in: valid).first)
        let central = try #require(
            signatureOffsets(0x0201_4B50, in: valid).first
        )

        var mismatch = valid
        setUInt16(0, at: local + 8, in: &mismatch)
        #expect(throws: ForeignContainerError.malformedArchive) {
            try ForeignZIPReader(mismatch)
        }

        var timestampMismatch = valid
        setUInt16(1, at: local + 10, in: &timestampMismatch)
        #expect(throws: ForeignContainerError.malformedArchive) {
            try ForeignZIPReader(timestampMismatch)
        }

        var zip64 = valid
        setUInt32(UInt32.max, at: central + 20, in: &zip64)
        #expect(throws: ForeignContainerError.unsupportedZIP64) {
            try ForeignZIPReader(zip64)
        }

        var crc = valid
        setUInt32(0, at: local + 14, in: &crc)
        setUInt32(0, at: central + 16, in: &crc)
        #expect(throws: ForeignContainerError.checksumMismatch("entry.bin")) {
            try ForeignZIPReader(crc).data(for: "entry.bin")
        }

        let originalBytes = Data(repeating: 0x41, count: 1_024)
        let compressed = try rawDeflate(originalBytes)
        let trailing = try zip([
            ZIPTestEntry(
                name: "entry.bin",
                bytes: originalBytes,
                method: 8,
                compressedBytes: compressed + Data([0])
            ),
        ])
        #expect(throws: ForeignContainerError.decompressionFailed("entry.bin")) {
            try ForeignZIPReader(trailing).data(for: "entry.bin")
        }

        let truncated = try zip([
            ZIPTestEntry(
                name: "entry.bin",
                bytes: originalBytes,
                method: 8,
                compressedBytes: Data(compressed.dropLast())
            ),
        ])
        #expect(throws: ForeignContainerError.decompressionFailed("entry.bin")) {
            try ForeignZIPReader(truncated).data(for: "entry.bin")
        }

        let sizeLie = try zip([
            ZIPTestEntry(
                name: "entry.bin",
                bytes: originalBytes,
                method: 8,
                declaredExpandedSize: originalBytes.count + 1
            ),
        ])
        #expect(throws: ForeignContainerError.decompressionFailed("entry.bin")) {
            try ForeignZIPReader(sizeLie).data(for: "entry.bin")
        }

        let smallerSizeLie = try zip([
            ZIPTestEntry(
                name: "entry.bin",
                bytes: originalBytes,
                method: 8,
                declaredExpandedSize: originalBytes.count - 1
            ),
        ])
        #expect(throws: ForeignContainerError.entryTooLarge(
            path: "entry.bin",
            actual: originalBytes.count,
            maximum: originalBytes.count - 1
        )) {
            try ForeignZIPReader(smallerSizeLie).data(for: "entry.bin")
        }
    }

    @Test
    func enforcesActualOutputRatioByteAndNestedEntryBudgets() throws {
        let bytes = Data(repeating: 0, count: 4_096)
        let archive = try zip([
            ZIPTestEntry(name: "entry.bin", bytes: bytes, method: 8),
        ])
        let ratioLimits = ForeignContainerLimits(
            maximumSourceBytes: 1_000_000,
            maximumEntriesPerContainer: 10,
            maximumNestedEntries: 10,
            maximumNestingDepth: 2,
            maximumExpandedBytes: 10_000,
            maximumExpandedBytesPerEntry: 10_000,
            maximumCompressionRatio: 1,
            maximumPathUTF8Bytes: 100,
            streamingChunkBytes: 127
        )
        var rejectedRatio = false
        do {
            let reader = try ForeignZIPReader(archive, limits: ratioLimits)
            _ = try reader.data(for: "entry.bin")
        } catch ForeignContainerError.compressionRatioExceeded {
            rejectedRatio = true
        }
        #expect(rejectedRatio)

        let byteBudget = ForeignExpansionBudget(
            maximumExpandedBytes: bytes.count - 1,
            maximumEntries: 10
        )
        #expect(throws: ForeignContainerError.expansionBudgetExceeded(
            actual: bytes.count,
            maximum: bytes.count - 1
        )) {
            let reader = try ForeignZIPReader(
                try zip([ZIPTestEntry(name: "entry", bytes: bytes)]),
                limits: ratioLimits,
                budget: byteBudget
            )
            _ = try reader.data(for: "entry")
        }
        #expect(byteBudget.consumedExpandedBytes == 0)
        #expect(byteBudget.consumedEntries == 1)

        let leaf = try zip([ZIPTestEntry(name: "leaf", bytes: Data([1]))])
        let middle = try zip([ZIPTestEntry(name: "leaf.zip", bytes: leaf)])
        let root = try zip([ZIPTestEntry(name: "middle.zip", bytes: middle)])
        let nestedLimits = ForeignContainerLimits(
            maximumSourceBytes: 1_000_000,
            maximumEntriesPerContainer: 10,
            maximumNestedEntries: 2,
            maximumNestingDepth: 2,
            maximumExpandedBytes: 1_000_000,
            maximumExpandedBytesPerEntry: 1_000_000,
            maximumCompressionRatio: 200,
            maximumPathUTF8Bytes: 100,
            streamingChunkBytes: 31
        )
        let rootReader = try ForeignZIPReader(root, limits: nestedLimits)
        let middleReader = try rootReader.nestedArchive(at: "middle.zip")
        #expect(throws: ForeignContainerError.aggregateEntryCountExceeded(
            actual: 3,
            maximum: 2
        )) {
            try middleReader.nestedArchive(at: "leaf.zip")
        }
    }

    @Test
    func permitsTwoNestedLevelsAndRejectsTheThird() throws {
        let deepest = try zip([
            ZIPTestEntry(name: "payload", bytes: Data([1])),
        ])
        let levelTwo = try zip([
            ZIPTestEntry(name: "deepest.zip", bytes: deepest),
        ])
        let levelOne = try zip([
            ZIPTestEntry(name: "level-two.zip", bytes: levelTwo),
        ])
        let root = try zip([
            ZIPTestEntry(name: "level-one.zip", bytes: levelOne),
        ])

        let reader = try ForeignZIPReader(root)
        let one = try reader.nestedArchive(at: "level-one.zip")
        let two = try one.nestedArchive(at: "level-two.zip")
        #expect(throws: ForeignContainerError.nestingDepthExceeded(
            actual: 3,
            maximum: 2
        )) {
            try two.nestedArchive(at: "deepest.zip")
        }
    }

    @Test
    func initializationRetainsNoExpandedEntriesAndAccessDoesNotCache() throws {
        let entryBytes = Data(repeating: 0x5A, count: 512)
        let archive = try zip(
            (0..<8).map {
                ZIPTestEntry(
                    name: "entry-\($0)",
                    bytes: entryBytes
                )
            }
        )
        let limits = ForeignContainerLimits(
            maximumSourceBytes: archive.count,
            maximumEntriesPerContainer: 8,
            maximumNestedEntries: 8,
            maximumNestingDepth: 2,
            maximumExpandedBytes: 600,
            maximumExpandedBytesPerEntry: 512,
            maximumCompressionRatio: 1,
            maximumPathUTF8Bytes: 100,
            streamingChunkBytes: 127
        )
        let budget = ForeignExpansionBudget(limits: limits)

        let reader = try ForeignZIPReader(
            archive,
            limits: limits,
            budget: budget
        )

        #expect(reader.paths.count == 8)
        #expect(budget.consumedEntries == 8)
        #expect(budget.consumedExpandedBytes == 0)
        #expect(try reader.data(for: "entry-0") == entryBytes)
        #expect(budget.consumedExpandedBytes == entryBytes.count)
        #expect(throws: ForeignContainerError.expansionBudgetExceeded(
            actual: 639,
            maximum: 600
        )) {
            _ = try reader.data(for: "entry-0")
        }
        #expect(budget.consumedExpandedBytes == entryBytes.count)
    }

    @Test
    func injectedBudgetCannotExceedConfiguredContainerCeilings() throws {
        let archive = try zip([
            ZIPTestEntry(name: "entry", bytes: Data([1])),
        ])
        let limits = ForeignContainerLimits(
            maximumSourceBytes: archive.count,
            maximumEntriesPerContainer: 2,
            maximumNestedEntries: 2,
            maximumNestingDepth: 2,
            maximumExpandedBytes: 10,
            maximumExpandedBytesPerEntry: 10,
            maximumCompressionRatio: 10,
            maximumPathUTF8Bytes: 100,
            streamingChunkBytes: 4
        )

        #expect(throws: ForeignContainerError.invalidLimits) {
            try ForeignZIPReader(
                archive,
                limits: limits,
                budget: ForeignExpansionBudget(
                    maximumExpandedBytes: 11,
                    maximumEntries: 2
                )
            )
        }
        #expect(throws: ForeignContainerError.invalidLimits) {
            try ForeignZIPReader(
                archive,
                limits: limits,
                budget: ForeignExpansionBudget(
                    maximumExpandedBytes: 10,
                    maximumEntries: 3
                )
            )
        }
    }

    @Test
    func assetTableRejectsMissingAssetsAndDanglingReferences() throws {
        let reader = try ForeignZIPReader(try zip([
            ZIPTestEntry(name: "Assets/shape.bin", bytes: Data([1, 2])),
        ]))
        let declaration = ForeignAssetDeclaration(
            id: "shape.primary",
            path: "Assets/shape.bin"
        )
        let table = try ForeignAssetTable(
            archive: reader,
            declarations: [declaration],
            referencedAssetIDs: ["shape.primary"]
        )
        #expect(try table.data(forAssetID: "shape.primary") == Data([1, 2]))

        #expect(throws: ForeignAssetTableError.missingAsset(
            path: "Assets/missing.bin"
        )) {
            _ = try ForeignAssetTable(
                archive: reader,
                declarations: [
                    ForeignAssetDeclaration(
                        id: "shape.primary",
                        path: "Assets/missing.bin"
                    ),
                ],
                referencedAssetIDs: ["shape.primary"]
            )
        }
        #expect(throws: ForeignAssetTableError.danglingReference(
            assetID: "grain.missing"
        )) {
            _ = try ForeignAssetTable(
                archive: reader,
                declarations: [declaration],
                referencedAssetIDs: ["grain.missing"]
            )
        }

        #expect(throws: ForeignAssetTableError.duplicateAssetPath(
            "Assets/é.bin"
        )) {
            let normalizedReader = try ForeignZIPReader(try zip([
                ZIPTestEntry(name: "Assets/é.bin", bytes: Data([1])),
            ]))
            _ = try ForeignAssetTable(
                archive: normalizedReader,
                declarations: [
                    ForeignAssetDeclaration(
                        id: "first",
                        path: "Assets/é.bin"
                    ),
                    ForeignAssetDeclaration(
                        id: "second",
                        path: "Assets/e\u{301}.bin"
                    ),
                ],
                referencedAssetIDs: ["first", "second"]
            )
        }
    }

    @Test
    func assetTableBoundsMetadataBeforeExpandingPayloads() throws {
        let archive = try zip([
            ZIPTestEntry(
                name: "Assets/shape.bin",
                bytes: Data(repeating: 0x44, count: 32)
            ),
        ])
        let limits = ForeignContainerLimits(
            maximumSourceBytes: archive.count,
            maximumEntriesPerContainer: 1,
            maximumNestedEntries: 1,
            maximumNestingDepth: 0,
            maximumExpandedBytes: 64,
            maximumExpandedBytesPerEntry: 32,
            maximumCompressionRatio: 32,
            maximumPathUTF8Bytes: 100,
            streamingChunkBytes: 8
        )
        let budget = ForeignExpansionBudget(limits: limits)
        let reader = try ForeignZIPReader(
            archive,
            limits: limits,
            budget: budget
        )
        let declaration = ForeignAssetDeclaration(
            id: "shape.primary",
            path: "Assets/shape.bin"
        )

        #expect(throws: ForeignAssetTableError.danglingReference(
            assetID: "grain.missing"
        )) {
            _ = try ForeignAssetTable(
                archive: reader,
                declarations: [declaration],
                referencedAssetIDs: ["grain.missing"]
            )
        }
        #expect(budget.consumedExpandedBytes == 0)

        let tooMany = (0...ForeignBrushLimits.maximumResourcesPerBrush)
            .map {
                ForeignAssetDeclaration(
                    id: "asset.\($0)",
                    path: "Assets/shape.bin"
                )
            }
        #expect(throws: ForeignAssetTableError.resourceCountExceeded(
            actual: ForeignBrushLimits.maximumResourcesPerBrush + 1,
            maximum: ForeignBrushLimits.maximumResourcesPerBrush
        )) {
            _ = try ForeignAssetTable(
                archive: reader,
                declarations: tooMany,
                referencedAssetIDs: []
            )
        }
        #expect(budget.consumedExpandedBytes == 0)
    }

    @Test
    func enforcesConfiguredSourceEntryPathAndExpandedBoundaries() throws {
        let oneEntry = try zip([
            ZIPTestEntry(name: "four", bytes: Data([1, 2, 3, 4])),
        ])
        let exact = ForeignContainerLimits(
            maximumSourceBytes: oneEntry.count,
            maximumEntriesPerContainer: 1,
            maximumNestedEntries: 1,
            maximumNestingDepth: 0,
            maximumExpandedBytes: 4,
            maximumExpandedBytesPerEntry: 4,
            maximumCompressionRatio: 1,
            maximumPathUTF8Bytes: 4,
            streamingChunkBytes: 2
        )
        _ = try ForeignZIPReader(oneEntry, limits: exact)

        #expect(throws: ForeignContainerError.sourceTooLarge(
            actual: oneEntry.count,
            maximum: oneEntry.count - 1
        )) {
            try ForeignZIPReader(
                oneEntry,
                limits: replacing(exact, maximumSourceBytes: oneEntry.count - 1)
            )
        }

        let twoEntries = try zip([
            ZIPTestEntry(name: "a", bytes: Data()),
            ZIPTestEntry(name: "b", bytes: Data()),
        ])
        #expect(throws: ForeignContainerError.entryCountExceeded(
            actual: 2,
            maximum: 1
        )) {
            try ForeignZIPReader(
                twoEntries,
                limits: replacing(
                    exact,
                    maximumSourceBytes: twoEntries.count,
                    maximumPathUTF8Bytes: 4
                )
            )
        }

        let longPath = try zip([
            ZIPTestEntry(name: "five5", bytes: Data()),
        ])
        #expect(throws: ForeignContainerError.unsafePath("five5")) {
            try ForeignZIPReader(
                longPath,
                limits: replacing(
                    exact,
                    maximumSourceBytes: longPath.count
                )
            )
        }

        let decomposed = try zip([
            ZIPTestEntry(name: "e\u{301}", bytes: Data()),
        ])
        #expect(throws: ForeignContainerError.unsafePath("e\u{301}")) {
            try ForeignZIPReader(
                decomposed,
                limits: replacing(
                    exact,
                    maximumSourceBytes: decomposed.count,
                    maximumPathUTF8Bytes: 2
                )
            )
        }

        let expanded = try zip([
            ZIPTestEntry(name: "four", bytes: Data(repeating: 1, count: 5)),
        ])
        #expect(throws: ForeignContainerError.entryTooLarge(
            path: "four",
            actual: 5,
            maximum: 4
        )) {
            try ForeignZIPReader(
                expanded,
                limits: replacing(
                    exact,
                    maximumSourceBytes: expanded.count,
                    maximumExpandedBytes: 10
                )
            )
        }
    }

    @Test
    func rejectsEmptyDirectoriesWithDataAndMalformedStructureDeterministically()
        throws
    {
        #expect(throws: ForeignContainerError.emptyArchive) {
            try ForeignZIPReader(try zip([]))
        }

        #expect(throws: ForeignContainerError.malformedArchive) {
            try ForeignZIPReader(try zip([
                ZIPTestEntry(
                    name: "Assets/",
                    bytes: Data([1]),
                    isDirectory: true
                ),
            ]))
        }
        #expect(throws: ForeignContainerError.malformedArchive) {
            try ForeignZIPReader(try zip([
                ZIPTestEntry(
                    name: "file",
                    bytes: Data(),
                    externalAttributes: 0x41ED_0010
                ),
            ]))
        }

        let valid = try zip([
            ZIPTestEntry(name: "a", bytes: Data([1])),
            ZIPTestEntry(name: "b", bytes: Data([2])),
        ])
        let localOffsets = signatureOffsets(0x0403_4B50, in: valid)
        let centralOffsets = signatureOffsets(0x0201_4B50, in: valid)
        let eocd = try #require(signatureOffsets(0x0605_4B50, in: valid).first)

        for offset in [
            try #require(localOffsets.first),
            try #require(centralOffsets.first),
            eocd,
        ] {
            var malformed = valid
            setUInt32(0, at: offset, in: &malformed)
            #expect(throws: ForeignContainerError.malformedArchive) {
                try ForeignZIPReader(malformed)
            }
        }

        var duplicateOffset = valid
        let secondCentral = try #require(centralOffsets.last)
        setUInt32(0, at: secondCentral + 42, in: &duplicateOffset)
        let firstError = capturedContainerError(duplicateOffset)
        let secondError = capturedContainerError(duplicateOffset)
        #expect(firstError == .malformedArchive)
        #expect(secondError == firstError)
    }

    @Test
    func rejectsZIP64ExtraVersionAndEndRecords() throws {
        let extra = Data([0x01, 0x00, 0x00, 0x00])
        let withExtra = try zip([
            ZIPTestEntry(
                name: "entry",
                bytes: Data([1]),
                localExtra: extra,
                centralExtra: extra
            ),
        ])
        #expect(throws: ForeignContainerError.unsupportedZIP64) {
            try ForeignZIPReader(withExtra)
        }

        var version45 = try zip([
            ZIPTestEntry(name: "entry", bytes: Data([1])),
        ])
        let versionCentral = try #require(
            signatureOffsets(0x0201_4B50, in: version45).first
        )
        setUInt16(45, at: versionCentral + 6, in: &version45)
        #expect(throws: ForeignContainerError.unsupportedZIP64) {
            try ForeignZIPReader(version45)
        }

        let placedRecords = try insertingZIP64EndRecords(
            into: try zip([
                ZIPTestEntry(name: "entry", bytes: Data([1])),
            ])
        )
        #expect(throws: ForeignContainerError.unsupportedZIP64) {
            try ForeignZIPReader(placedRecords)
        }
    }

    @Test
    func hostileZIPCorpusProducesExactErrorsOnRepeat() throws {
        let empty = try zip([])
        let traversal = try zip([
            ZIPTestEntry(name: "../bad", bytes: Data([1])),
        ])
        let duplicate = try zip([
            ZIPTestEntry(name: "é", bytes: Data([1])),
            ZIPTestEntry(name: "e\u{301}", bytes: Data([2])),
        ])
        let symlink = try zip([
            ZIPTestEntry(
                name: "link",
                bytes: Data([1]),
                externalAttributes: 0xA1FF_0000
            ),
        ])
        let encrypted = try zip([
            ZIPTestEntry(name: "entry", bytes: Data([1]), flags: 0x0801),
        ])
        let unsupported = try zip([
            ZIPTestEntry(name: "entry", bytes: Data([1]), method: 12),
        ])

        var zip64 = try zip([
            ZIPTestEntry(name: "entry", bytes: Data([1])),
        ])
        let zip64Central = try #require(
            signatureOffsets(0x0201_4B50, in: zip64).first
        )
        setUInt32(UInt32.max, at: zip64Central + 20, in: &zip64)

        var badCRC = try zip([
            ZIPTestEntry(name: "entry", bytes: Data([1, 2, 3])),
        ])
        let crcLocal = try #require(
            signatureOffsets(0x0403_4B50, in: badCRC).first
        )
        let crcCentral = try #require(
            signatureOffsets(0x0201_4B50, in: badCRC).first
        )
        setUInt32(0, at: crcLocal + 14, in: &badCRC)
        setUInt32(0, at: crcCentral + 16, in: &badCRC)

        let deflatedBytes = Data(repeating: 0x41, count: 128)
        let trailingDeflate = try zip([
            ZIPTestEntry(
                name: "entry",
                bytes: deflatedBytes,
                method: 8,
                compressedBytes:
                    try rawDeflate(deflatedBytes) + Data([0])
            ),
        ])
        let budgetArchive = try zip([
            ZIPTestEntry(
                name: "entry",
                bytes: Data(repeating: 1, count: 8)
            ),
        ])
        let leaf = try zip([
            ZIPTestEntry(name: "leaf", bytes: Data([1])),
        ])
        let root = try zip([
            ZIPTestEntry(name: "leaf.zip", bytes: leaf),
        ])
        let sourceLimited = try zip([
            ZIPTestEntry(name: "entry", bytes: Data([1])),
        ])

        let cases: [
            (
                operation: () throws -> Void,
                expected: ForeignContainerError
            )
        ] = [
            (
                { _ = try ForeignZIPReader(empty) },
                .emptyArchive
            ),
            (
                { _ = try ForeignZIPReader(traversal) },
                .unsafePath("../bad")
            ),
            (
                { _ = try ForeignZIPReader(duplicate) },
                .duplicatePath("é")
            ),
            (
                { _ = try ForeignZIPReader(symlink) },
                .symbolicLink("link")
            ),
            (
                { _ = try ForeignZIPReader(encrypted) },
                .unsupportedFlags(path: "entry", flags: 0x0801)
            ),
            (
                { _ = try ForeignZIPReader(unsupported) },
                .unsupportedCompression(path: "entry", method: 12)
            ),
            (
                { _ = try ForeignZIPReader(zip64) },
                .unsupportedZIP64
            ),
            (
                {
                    _ = try ForeignZIPReader(badCRC)
                        .data(for: "entry")
                },
                .checksumMismatch("entry")
            ),
            (
                {
                    _ = try ForeignZIPReader(trailingDeflate)
                        .data(for: "entry")
                },
                .decompressionFailed("entry")
            ),
            (
                {
                    let reader = try ForeignZIPReader(
                        budgetArchive,
                        budget: ForeignExpansionBudget(
                            maximumExpandedBytes: 7,
                            maximumEntries: 1
                        )
                    )
                    _ = try reader.data(for: "entry")
                },
                .expansionBudgetExceeded(actual: 8, maximum: 7)
            ),
            (
                {
                    let reader = try ForeignZIPReader(
                        root,
                        budget: ForeignExpansionBudget(
                            maximumExpandedBytes: 1_024,
                            maximumEntries: 1
                        )
                    )
                    _ = try reader.nestedArchive(at: "leaf.zip")
                },
                .aggregateEntryCountExceeded(actual: 2, maximum: 1)
            ),
            (
                {
                    _ = try ForeignZIPReader(
                        sourceLimited,
                        limits: ForeignContainerLimits(
                            maximumSourceBytes: sourceLimited.count - 1
                        )
                    )
                },
                .sourceTooLarge(
                    actual: sourceLimited.count,
                    maximum: sourceLimited.count - 1
                )
            ),
        ]

        for testCase in cases {
            for _ in 0..<2 {
                #expect(
                    capturedContainerOperationError(testCase.operation)
                        == testCase.expected
                )
            }
        }
    }
}

private struct ZIPTestEntry {
    let name: String
    let bytes: Data
    let method: UInt16
    let flags: UInt16
    let isDirectory: Bool
    let externalAttributes: UInt32
    let compressedBytes: Data?
    let declaredExpandedSize: Int?
    let localExtra: Data
    let centralExtra: Data

    init(
        name: String,
        bytes: Data,
        method: UInt16 = 0,
        flags: UInt16 = 0x0800,
        isDirectory: Bool = false,
        externalAttributes: UInt32? = nil,
        compressedBytes: Data? = nil,
        declaredExpandedSize: Int? = nil,
        localExtra: Data = Data(),
        centralExtra: Data = Data()
    ) {
        self.name = name
        self.bytes = bytes
        self.method = method
        self.flags = flags
        self.isDirectory = isDirectory
        self.externalAttributes = externalAttributes
            ?? (isDirectory ? 0x41ED_0010 : 0x81A4_0000)
        self.compressedBytes = compressedBytes
        self.declaredExpandedSize = declaredExpandedSize
        self.localExtra = localExtra
        self.centralExtra = centralExtra
    }
}

private struct ZIPCentralFixture {
    let entry: ZIPTestEntry
    let name: Data
    let compressed: Data
    let checksum: UInt32
    let expandedSize: UInt32
    let localOffset: UInt32
}

private func zip(
    _ entries: [ZIPTestEntry],
    reversesCentralDirectory: Bool = false
) throws -> Data {
    var output = Data()
    var central: [ZIPCentralFixture] = []
    for entry in entries {
        let name = Data(entry.name.utf8)
        let compressed = try entry.compressedBytes
            ?? (entry.method == 8 ? rawDeflate(entry.bytes) : entry.bytes)
        let checksum = testCRC32(entry.bytes)
        let expandedSize = UInt32(
            entry.declaredExpandedSize ?? entry.bytes.count
        )
        let localOffset = UInt32(output.count)
        appendUInt32(0x0403_4B50, to: &output)
        appendUInt16(entry.method == 8 ? 20 : 10, to: &output)
        appendUInt16(entry.flags, to: &output)
        appendUInt16(entry.method, to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(0, to: &output)
        appendUInt32(checksum, to: &output)
        appendUInt32(UInt32(compressed.count), to: &output)
        appendUInt32(expandedSize, to: &output)
        appendUInt16(UInt16(name.count), to: &output)
        appendUInt16(UInt16(entry.localExtra.count), to: &output)
        output.append(name)
        output.append(entry.localExtra)
        output.append(compressed)
        central.append(ZIPCentralFixture(
            entry: entry,
            name: name,
            compressed: compressed,
            checksum: checksum,
            expandedSize: expandedSize,
            localOffset: localOffset
        ))
    }

    let centralOffset = UInt32(output.count)
    let centralRecords = reversesCentralDirectory
        ? Array(central.reversed())
        : central
    for fixture in centralRecords {
        appendUInt32(0x0201_4B50, to: &output)
        appendUInt16(0x0314, to: &output)
        appendUInt16(fixture.entry.method == 8 ? 20 : 10, to: &output)
        appendUInt16(fixture.entry.flags, to: &output)
        appendUInt16(fixture.entry.method, to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(0, to: &output)
        appendUInt32(fixture.checksum, to: &output)
        appendUInt32(UInt32(fixture.compressed.count), to: &output)
        appendUInt32(fixture.expandedSize, to: &output)
        appendUInt16(UInt16(fixture.name.count), to: &output)
        appendUInt16(UInt16(fixture.entry.centralExtra.count), to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(0, to: &output)
        appendUInt32(fixture.entry.externalAttributes, to: &output)
        appendUInt32(fixture.localOffset, to: &output)
        output.append(fixture.name)
        output.append(fixture.entry.centralExtra)
    }
    let centralSize = UInt32(output.count) - centralOffset
    appendUInt32(0x0605_4B50, to: &output)
    appendUInt16(0, to: &output)
    appendUInt16(0, to: &output)
    appendUInt16(UInt16(entries.count), to: &output)
    appendUInt16(UInt16(entries.count), to: &output)
    appendUInt32(centralSize, to: &output)
    appendUInt32(centralOffset, to: &output)
    appendUInt16(0, to: &output)
    return output
}

private func rawDeflate(_ data: Data) throws -> Data {
    try data.withUnsafeBytes { rawData in
        var stream = z_stream()
        guard deflateInit2_(
            &stream,
            Z_BEST_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw ZIPTestError.deflate
        }
        defer { deflateEnd(&stream) }
        stream.next_in = UnsafeMutablePointer<Bytef>(
            mutating: rawData.bindMemory(to: Bytef.self).baseAddress
        )
        stream.avail_in = uInt(data.count)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 257)
        let chunkSize = chunk.count
        while true {
            let status = chunk.withUnsafeMutableBytes { rawChunk in
                stream.next_out = rawChunk.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(chunkSize)
                return deflate(&stream, Z_FINISH)
            }
            let produced = chunkSize - Int(stream.avail_out)
            output.append(contentsOf: chunk[0..<produced])
            if status == Z_STREAM_END {
                return output
            }
            guard status == Z_OK else {
                throw ZIPTestError.deflate
            }
        }
    }
}

private enum ZIPTestError: Error {
    case deflate
}

private func testCRC32(_ data: Data) -> UInt32 {
    var result = UInt32.max
    for byte in data {
        result ^= UInt32(byte)
        for _ in 0..<8 {
            result = result & 1 == 0
                ? result >> 1
                : 0xEDB8_8320 ^ (result >> 1)
        }
    }
    return result ^ UInt32.max
}

private func signatureOffsets(_ signature: UInt32, in data: Data) -> [Int] {
    guard data.count >= 4 else { return [] }
    return (0...(data.count - 4)).filter {
        uint32(at: $0, in: data) == signature
    }
}

private func uint32(at offset: Int, in data: Data) -> UInt32 {
    UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
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

private func replacing(
    _ limits: ForeignContainerLimits,
    maximumSourceBytes: Int? = nil,
    maximumExpandedBytes: Int? = nil,
    maximumPathUTF8Bytes: Int? = nil
) -> ForeignContainerLimits {
    ForeignContainerLimits(
        maximumSourceBytes: maximumSourceBytes ?? limits.maximumSourceBytes,
        maximumEntriesPerContainer: limits.maximumEntriesPerContainer,
        maximumNestedEntries: limits.maximumNestedEntries,
        maximumNestingDepth: limits.maximumNestingDepth,
        maximumExpandedBytes:
            maximumExpandedBytes ?? limits.maximumExpandedBytes,
        maximumExpandedBytesPerEntry: limits.maximumExpandedBytesPerEntry,
        maximumCompressionRatio: limits.maximumCompressionRatio,
        maximumPathUTF8Bytes:
            maximumPathUTF8Bytes ?? limits.maximumPathUTF8Bytes,
        streamingChunkBytes: limits.streamingChunkBytes
    )
}

private func capturedContainerError(_ data: Data) -> ForeignContainerError? {
    do {
        _ = try ForeignZIPReader(data)
        return nil
    } catch let error as ForeignContainerError {
        return error
    } catch {
        return nil
    }
}

private func capturedContainerOperationError(
    _ operation: () throws -> Void
) -> ForeignContainerError? {
    do {
        try operation()
        return nil
    } catch let error as ForeignContainerError {
        return error
    } catch {
        return nil
    }
}

private func insertingZIP64EndRecords(into data: Data) throws -> Data {
    let eocd = try #require(signatureOffsets(0x0605_4B50, in: data).first)
    let centralOffset = uint32(at: eocd + 16, in: data)
    let centralSize = uint32(at: eocd + 12, in: data)
    let entryCount = UInt64(
        UInt16(data[eocd + 10]) | UInt16(data[eocd + 11]) << 8
    )
    var records = Data()
    appendUInt32(0x0606_4B50, to: &records)
    appendUInt64(44, to: &records)
    appendUInt16(45, to: &records)
    appendUInt16(45, to: &records)
    appendUInt32(0, to: &records)
    appendUInt32(0, to: &records)
    appendUInt64(entryCount, to: &records)
    appendUInt64(entryCount, to: &records)
    appendUInt64(UInt64(centralSize), to: &records)
    appendUInt64(UInt64(centralOffset), to: &records)
    appendUInt32(0x0706_4B50, to: &records)
    appendUInt32(0, to: &records)
    appendUInt64(UInt64(eocd), to: &records)
    appendUInt32(1, to: &records)

    var output = data
    output.insert(contentsOf: records, at: eocd)
    return output
}
