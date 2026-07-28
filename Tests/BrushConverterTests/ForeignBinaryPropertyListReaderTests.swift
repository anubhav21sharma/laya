import Foundation
import Testing
@testable import BrushConverter

@Suite("Bounded binary property lists")
struct ForeignBinaryPropertyListReaderTests {
    @Test
    func parsesSupportedScalarAndCollectionRecordsIntoObjectTable() throws {
        let records = [
            arrayRecord([1, 2, 3, 4, 5, 6, 7]),
            Data([0x09]),
            signedIntegerRecord(-5),
            realRecord(1.25),
            asciiRecord("hi"),
            dataRecord(Data([1, 2, 3])),
            dateRecord(60),
            uidRecord(2),
        ]

        let graph = try reader().parse(binaryPlist(records: records, top: 0))

        #expect(graph.root.rawValue == 0)
        #expect(graph.nodes == [
            .array((1...7).map(ForeignPropertyListObjectID.init)),
            .boolean(true),
            .integer(-5),
            .real(1.25),
            .string("hi"),
            .data(Data([1, 2, 3])),
            .date(Date(timeIntervalSinceReferenceDate: 60)),
            .uid(2),
        ])
    }

    @Test
    func parsesDataSlicesWithNonzeroStartIndices() throws {
        let source = binaryPlist(records: [Data([0x09])], top: 0)
        var padded = Data([0xFF])
        padded.append(source)
        let slice = padded.dropFirst()

        #expect(slice.startIndex != 0)
        #expect(try reader().parse(slice).nodes == [.boolean(true)])
        #expect(throws: ForeignPropertyListError.inputTooLarge(
            actual: source.count,
            maximum: source.count - 1
        )) {
            _ = try reader(
                limits: limits(maximumInputBytes: source.count - 1)
            ).parse(slice)
        }
    }

    @Test
    func parsesExtendedLengthsAndUTF16Strings() throws {
        let text = String(repeating: "é", count: 15)
        let encoded = text.data(using: .utf16BigEndian)!
        var string = Data([0x6F, 0x10, 0x0F])
        string.append(encoded)

        let graph = try reader().parse(
            binaryPlist(records: [string], top: 0)
        )

        #expect(graph.nodes == [.string(text)])
    }

    @Test
    func preservesDictionaryPairOrderAndReadsWideReferences() throws {
        let root = Data([
            0xD2,
            0x00, 0x01,
            0x00, 0x02,
            0x00, 0x03,
            0x00, 0x04,
        ])
        let graph = try reader().parse(
            binaryPlist(
                records: [
                    root,
                    asciiRecord("z"),
                    asciiRecord("a"),
                    Data([0x09]),
                    Data([0x08]),
                ],
                top: 0,
                referenceSize: 2
            )
        )

        #expect(graph.nodes[0] == .dictionary([
            .init(
                key: ForeignPropertyListObjectID(rawValue: 1),
                value: ForeignPropertyListObjectID(rawValue: 3)
            ),
            .init(
                key: ForeignPropertyListObjectID(rawValue: 2),
                value: ForeignPropertyListObjectID(rawValue: 4)
            ),
        ]))
    }

    @Test
    func parsesExtendedCollectionCount() throws {
        var root = Data([0xAF, 0x10, 0x0F])
        root.append(contentsOf: 1...15)
        let records = [root] + (0..<15).map { _ in Data([0x09]) }

        let graph = try reader().parse(
            binaryPlist(records: records, top: 0)
        )

        #expect(
            graph.nodes[0]
                == .array((1...15).map(ForeignPropertyListObjectID.init))
        )
    }

    @Test
    func treatsShortIntegersAndLengthsAsUnsigned() throws {
        var longData = Data([0x4F, 0x10, 0xFF])
        longData.append(Data(repeating: 7, count: 255))
        let graph = try reader().parse(
            binaryPlist(
                records: [
                    arrayRecord([1, 2, 3, 4]),
                    Data([0x10, 0xFF]),
                    Data([0x11, 0xFF, 0xFF]),
                    Data([0x12, 0xFF, 0xFF, 0xFF, 0xFF]),
                    longData,
                ],
                top: 0,
                offsetSize: 2
            )
        )

        #expect(graph.nodes[1] == .integer(255))
        #expect(graph.nodes[2] == .integer(65_535))
        #expect(graph.nodes[3] == .integer(4_294_967_295))
        #expect(graph.nodes[4] == .data(Data(repeating: 7, count: 255)))
    }

    @Test
    func rejectsNegativeEightByteExtendedLengthEncoding() {
        var record = Data([0x4F, 0x13])
        record.append(Data(repeating: 0xFF, count: 8))
        #expect(
            throws: ForeignPropertyListError.malformedBinary(offset: 10)
        ) {
            _ = try reader().parse(
                binaryPlist(records: [record], top: 0)
            )
        }
    }

    @Test
    func acceptsThreeByteOffsetsAndReferences() throws {
        let root = Data([0xA1, 0x00, 0x00, 0x01])
        let graph = try reader().parse(
            binaryPlist(
                records: [root, Data([0x09])],
                top: 0,
                offsetSize: 3,
                referenceSize: 3
            )
        )

        #expect(
            graph.nodes[0]
                == .array([ForeignPropertyListObjectID(rawValue: 1)])
        )
    }

    @Test
    func normalizesNegativeRealZero() throws {
        let graph = try reader().parse(
            binaryPlist(records: [realRecord(-0.0)], top: 0)
        )

        guard case let .real(value) = graph.nodes[0] else {
            Issue.record("Expected real node")
            return
        }
        #expect(value.bitPattern == 0)
    }

    @Test
    func acceptsOnlyFillMarkersInUnclaimedObjectTableGaps() throws {
        let valid = binaryPlistWithGap(0x0F)
        #expect(try reader().parse(valid).nodes == [.boolean(true)])

        let hidden = binaryPlistWithGap(0x01)
        #expect(
            throws: ForeignPropertyListError.malformedBinary(offset: 9)
        ) {
            _ = try reader().parse(hidden)
        }
    }

    @Test
    func requiresAtLeastOneObjectByteBeforeTrailer() {
        var bytes = Data("bplist00".utf8)
        bytes.append(Data(repeating: 0, count: 32))

        #expect(
            throws: ForeignPropertyListError.malformedBinary(offset: 40)
        ) {
            _ = try reader().parse(bytes)
        }
    }

    @Test
    func validatesEveryRecordIncludingUnreachableObjects() {
        let bytes = binaryPlist(
            records: [Data([0x09]), Data([0x00])],
            top: 0
        )

        #expect(
            throws: ForeignPropertyListError.unsupportedBinaryObject(
                marker: 0,
                object: 1
            )
        ) {
            _ = try reader().parse(bytes)
        }
    }

    @Test
    func rejectsBadTrailerSizesCountsTopAndTrailingBytes() {
        let valid = binaryPlist(records: [Data([0x09])], top: 0)

        var badOffsetSize = valid
        badOffsetSize[badOffsetSize.count - 26] = 9
        #expect(
            throws: ForeignPropertyListError.invalidBinaryOffsetSize(9)
        ) {
            _ = try reader().parse(badOffsetSize)
        }

        var badReferenceSize = valid
        badReferenceSize[badReferenceSize.count - 25] = 0
        #expect(
            throws: ForeignPropertyListError.invalidBinaryReferenceSize(0)
        ) {
            _ = try reader().parse(badReferenceSize)
        }

        var zeroObjects = valid
        replaceBigEndian(
            &zeroObjects,
            at: zeroObjects.count - 24,
            byteCount: 8,
            value: 0
        )
        #expect(throws: ForeignPropertyListError.self) {
            _ = try reader().parse(zeroObjects)
        }

        var badTop = valid
        replaceBigEndian(
            &badTop,
            at: badTop.count - 16,
            byteCount: 8,
            value: 1
        )
        #expect(throws: ForeignPropertyListError.self) {
            _ = try reader().parse(badTop)
        }

        var trailing = valid
        trailing.append(0)
        #expect(throws: ForeignPropertyListError.self) {
            _ = try reader().parse(trailing)
        }

        var undersizedOffsetWidth = valid
        let originalTable = binaryOffsetTableOffset(undersizedOffsetWidth)
        undersizedOffsetWidth.insert(
            contentsOf: Data(
                repeating: 0x0F,
                count: 256 - originalTable
            ),
            at: originalTable
        )
        replaceBigEndian(
            &undersizedOffsetWidth,
            at: undersizedOffsetWidth.count - 8,
            byteCount: 8,
            value: 256
        )
        #expect(
            throws: ForeignPropertyListError.invalidBinaryOffsetSize(1)
        ) {
            _ = try reader().parse(undersizedOffsetWidth)
        }
    }

    @Test
    func rejectsDuplicateOverlappingAndOutOfRegionOffsets() {
        let valid = binaryPlist(
            records: [Data([0x09]), Data([0x08])],
            top: 0
        )
        let table = binaryOffsetTableOffset(valid)

        var duplicate = valid
        duplicate[table + 1] = duplicate[table]
        #expect(
            throws: ForeignPropertyListError.duplicateBinaryObjectOffset
        ) {
            _ = try reader().parse(duplicate)
        }

        var overlap = binaryPlist(
            records: [asciiRecord("ab"), Data([0x09])],
            top: 0
        )
        let overlapTable = binaryOffsetTableOffset(overlap)
        overlap[overlapTable + 1] = overlap[overlapTable] + 1
        #expect(
            throws: ForeignPropertyListError.overlappingBinaryObjects
        ) {
            _ = try reader().parse(overlap)
        }

        var pointsIntoTable = valid
        pointsIntoTable[table] = UInt8(table)
        #expect(throws: ForeignPropertyListError.self) {
            _ = try reader().parse(pointsIntoTable)
        }
    }

    @Test
    func rejectsInvalidReferencesCyclesAndExcessiveDepth() {
        #expect(throws: ForeignPropertyListError.invalidBinaryReference) {
            _ = try reader().parse(
                binaryPlist(records: [arrayRecord([1])], top: 0)
            )
        }
        #expect(throws: ForeignPropertyListError.graphCycle(object: 0)) {
            _ = try reader().parse(
                binaryPlist(records: [arrayRecord([0])], top: 0)
            )
        }

        let depthLimits = limits(maximumGraphDepth: 2)
        let deep = binaryPlist(
            records: [
                arrayRecord([1]),
                arrayRecord([2]),
                Data([0x09]),
            ],
            top: 0
        )
        #expect(
            throws: ForeignPropertyListError.graphDepthExceeded(maximum: 2)
        ) {
            _ = try ForeignBinaryPropertyListReader(
                data: deep,
                limits: depthLimits
            ).parse()
        }
    }

    @Test
    func rejectsDuplicateAndNonStringDictionaryKeys() {
        let duplicate = binaryPlist(
            records: [
                dictionaryRecord(keys: [1, 1], values: [2, 3]),
                asciiRecord("key"),
                Data([0x08]),
                Data([0x09]),
            ],
            top: 0
        )
        #expect(
            throws: ForeignPropertyListError.duplicateDictionaryKey(object: 0)
        ) {
            _ = try reader().parse(duplicate)
        }

        let nonString = binaryPlist(
            records: [
                dictionaryRecord(keys: [1], values: [2]),
                Data([0x09]),
                Data([0x08]),
            ],
            top: 0
        )
        #expect(
            throws:
                ForeignPropertyListError.dictionaryKeyIsNotString(object: 0)
        ) {
            _ = try reader().parse(nonString)
        }
    }

    @Test
    func enforcesNodeCollectionReferenceStringAndDataLimits() {
        let twoNodes = binaryPlist(
            records: [arrayRecord([1]), Data([0x09])],
            top: 0
        )
        #expect(
            throws: ForeignPropertyListError.nodeLimitExceeded(maximum: 1)
        ) {
            _ = try ForeignBinaryPropertyListReader(
                data: twoNodes,
                limits: limits(maximumTotalNodes: 1)
            ).parse()
        }
        #expect(
            throws:
                ForeignPropertyListError.collectionLimitExceeded(maximum: 0)
        ) {
            _ = try ForeignBinaryPropertyListReader(
                data: twoNodes,
                limits: limits(maximumCollectionElements: 0)
            ).parse()
        }
        #expect(
            throws: ForeignPropertyListError
                .collectionReferenceLimitExceeded(maximum: 0)
        ) {
            _ = try ForeignBinaryPropertyListReader(
                data: twoNodes,
                limits: limits(maximumTotalCollectionReferences: 0)
            ).parse()
        }
        #expect(
            throws:
                ForeignPropertyListError.stringLimitExceeded(
                    maximumUTF8Bytes: 1
                )
        ) {
            _ = try ForeignBinaryPropertyListReader(
                data: binaryPlist(records: [asciiRecord("ab")], top: 0),
                limits: limits(maximumStringUTF8Bytes: 1)
            ).parse()
        }
        #expect(
            throws:
                ForeignPropertyListError.dataLimitExceeded(maximumBytes: 1)
        ) {
            _ = try ForeignBinaryPropertyListReader(
                data: binaryPlist(
                    records: [dataRecord(Data([1, 2]))],
                    top: 0
                ),
                limits: limits(maximumOpaqueDataBytes: 1)
            ).parse()
        }
    }

    @Test
    func rejectsNonFiniteAndUnsupportedNumericWidths() {
        #expect(
            throws: ForeignPropertyListError.nonFiniteNumber(object: 0)
        ) {
            _ = try reader().parse(
                binaryPlist(records: [realRecord(.infinity)], top: 0)
            )
        }
        #expect(
            throws: ForeignPropertyListError.integerOutOfRange(object: 0)
        ) {
            _ = try reader().parse(
                binaryPlist(
                    records: [Data([0x14]) + Data(repeating: 0, count: 16)],
                    top: 0
                )
            )
        }
    }

    @Test
    func rejectsInvalidUTF16NonFiniteDatesAndOversizedUIDs() {
        #expect(
            throws: ForeignPropertyListError.invalidScalar(
                kind: .string,
                offset: 9
            )
        ) {
            _ = try reader().parse(
                binaryPlist(
                    records: [Data([0x61, 0xD8, 0x00])],
                    top: 0
                )
            )
        }
        #expect(
            throws: ForeignPropertyListError.nonFiniteNumber(object: 0)
        ) {
            _ = try reader().parse(
                binaryPlist(records: [dateRecord(.infinity)], top: 0)
            )
        }
        #expect(
            throws: ForeignPropertyListError.unsupportedBinaryObject(
                marker: 0x88,
                object: 0
            )
        ) {
            _ = try reader().parse(
                binaryPlist(
                    records: [Data([0x88]) + Data(repeating: 0, count: 9)],
                    top: 0
                )
            )
        }
    }

    @Test
    func rejectsInputBeforeReadingBinaryStructure() {
        let bytes = binaryPlist(records: [Data([0x09])], top: 0)
        let constrained = limits(maximumInputBytes: bytes.count - 1)

        #expect(
            throws: ForeignPropertyListError.inputTooLarge(
                actual: bytes.count,
                maximum: bytes.count - 1
            )
        ) {
            _ = try reader(limits: constrained).parse(bytes)
        }
    }

    @Test
    func rejectsNonBinarySignatureEvenWhenTrailerIsWellFormed() {
        var bytes = binaryPlist(records: [Data([0x09])], top: 0)
        bytes.replaceSubrange(0..<8, with: Data("notplist".utf8))

        #expect(throws: ForeignPropertyListError.unsupportedSignature) {
            _ = try reader().parse(bytes)
        }
    }

    @Test
    func hostileBinaryCorpusProducesExactErrorsOnRepeat() {
        var badSignature = binaryPlist(records: [Data([0x09])], top: 0)
        badSignature.replaceSubrange(0..<8, with: Data("notplist".utf8))
        let cases: [(Data, ForeignPropertyListError)] = [
            (badSignature, .unsupportedSignature),
            (
                binaryPlist(records: [Data([0x00])], top: 0),
                .unsupportedBinaryObject(marker: 0, object: 0)
            ),
            (
                binaryPlist(records: [realRecord(.infinity)], top: 0),
                .nonFiniteNumber(object: 0)
            ),
            (
                binaryPlist(records: [arrayRecord([0])], top: 0),
                .graphCycle(object: 0)
            ),
        ]

        for (bytes, expected) in cases {
            for _ in 0..<2 {
                #expect(caughtPropertyListError {
                    _ = try reader().parse(bytes)
                } == expected)
            }
        }
    }
}

@Suite("Bounded keyed archive view")
struct BoundedKeyedArchiveViewTests {
    @Test
    func validatesEnvelopeAndResolvesUIDWithoutInstantiatingClasses() throws {
        let fixture = keyedArchiveGraph()

        let view = try BoundedKeyedArchiveView(graph: fixture.graph)

        #expect(view.objects == fixture.objects)
        #expect(
            try view.object(referencedBy: fixture.rootUID)
                == fixture.objects[1]
        )
    }

    @Test
    func rejectsWrongEnvelopeNullAndUIDRange() {
        var fixture = keyedArchiveGraph()
        fixture.graph = replacingNode(
            fixture.graph,
            at: 2,
            with: .string("OtherArchiver")
        )
        #expect(throws: ForeignPropertyListError.notKeyedArchive) {
            _ = try BoundedKeyedArchiveView(graph: fixture.graph)
        }

        fixture = keyedArchiveGraph()
        fixture.graph = replacingNode(
            fixture.graph,
            at: fixture.objects[0].rawValue,
            with: .string("not-null")
        )
        #expect(throws: ForeignPropertyListError.invalidKeyedArchive) {
            _ = try BoundedKeyedArchiveView(graph: fixture.graph)
        }

        fixture = keyedArchiveGraph()
        fixture.graph = replacingNode(
            fixture.graph,
            at: fixture.rootUID.rawValue,
            with: .uid(99)
        )
        #expect(
            throws: ForeignPropertyListError.invalidUIDReference(99)
        ) {
            _ = try BoundedKeyedArchiveView(graph: fixture.graph)
        }
    }

    @Test
    func countsSharedUIDEdgesAndRejectsResolvedCycles() {
        var fixture = keyedArchiveGraph()
        let sharedArray = ForeignPropertyListNode.array([
            fixture.rootUID,
            fixture.rootUID,
        ])
        fixture.graph = replacingNode(
            fixture.graph,
            at: fixture.objects[1].rawValue,
            with: sharedArray
        )
        #expect(
            throws: ForeignPropertyListError
                .resolvedUIDReferenceLimitExceeded(maximum: 2)
        ) {
            _ = try BoundedKeyedArchiveView(
                graph: fixture.graph,
                limits: limits(maximumTotalResolvedUIDReferences: 2)
            )
        }

        fixture = keyedArchiveGraph()
        fixture.graph = replacingNode(
            fixture.graph,
            at: fixture.objects[1].rawValue,
            with: .array([fixture.rootUID])
        )
        #expect(throws: ForeignPropertyListError.graphCycle(object: 10)) {
            _ = try BoundedKeyedArchiveView(graph: fixture.graph)
        }
    }

    @Test
    func malformedGraphReferenceThrowsInsteadOfTrapping() {
        let graph = ForeignPropertyListGraph(
            root: ForeignPropertyListObjectID(rawValue: 0),
            nodes: [
                .array([ForeignPropertyListObjectID(rawValue: 99)]),
            ]
        )

        #expect(
            throws: ForeignPropertyListError.invalidReference(object: 0)
        ) {
            _ = try BoundedKeyedArchiveView(graph: graph)
        }
    }

    @Test
    func sharedPerBrushBudgetBoundsResolvedUIDReferences() throws {
        let fixture = keyedArchiveGraph()
        let constrained = limits(
            maximumTotalResolvedUIDReferences: 1
        )
        _ = try BoundedKeyedArchiveView(
            graph: fixture.graph,
            limits: constrained
        )
        _ = try BoundedKeyedArchiveView(
            graph: fixture.graph,
            limits: constrained
        )

        let budget = ForeignPropertyListBudget(limits: constrained)
        _ = try BoundedKeyedArchiveView(
            graph: fixture.graph,
            limits: constrained,
            budget: budget
        )
        #expect(
            throws:
                ForeignPropertyListError
                    .resolvedUIDReferenceLimitExceeded(maximum: 1)
        ) {
            _ = try BoundedKeyedArchiveView(
                graph: fixture.graph,
                limits: constrained,
                budget: budget
            )
        }
        #expect(budget.consumedTotalResolvedUIDReferences == 1)
    }
}

private struct BinaryTestReader {
    let limits: ForeignPropertyListLimits

    func parse(_ data: Data) throws -> ForeignPropertyListGraph {
        try ForeignBinaryPropertyListReader(
            data: data,
            limits: limits
        ).parse()
    }
}

private func reader(
    limits: ForeignPropertyListLimits = .standard
) -> BinaryTestReader {
    BinaryTestReader(limits: limits)
}

private func limits(
    maximumInputBytes: Int = 512 * 1_024 * 1_024,
    maximumGraphDepth: Int = 64,
    maximumCollectionElements: Int = 16_384,
    maximumTotalNodes: Int = 100_000,
    maximumStringUTF8Bytes: Int = 64 * 1_024,
    maximumOpaqueDataBytes: Int = 256 * 1_024 * 1_024,
    maximumXMLTextUTF8Bytes: Int = 512 * 1_024 * 1_024,
    maximumTotalCollectionReferences: Int = 100_000,
    maximumTotalResolvedUIDReferences: Int = 100_000
) -> ForeignPropertyListLimits {
    ForeignPropertyListLimits(
        maximumInputBytes: maximumInputBytes,
        maximumGraphDepth: maximumGraphDepth,
        maximumCollectionElements: maximumCollectionElements,
        maximumTotalNodes: maximumTotalNodes,
        maximumStringUTF8Bytes: maximumStringUTF8Bytes,
        maximumOpaqueDataBytes: maximumOpaqueDataBytes,
        maximumXMLTextUTF8Bytes: maximumXMLTextUTF8Bytes,
        maximumTotalCollectionReferences: maximumTotalCollectionReferences,
        maximumTotalResolvedUIDReferences: maximumTotalResolvedUIDReferences
    )
}

private func binaryPlist(
    records: [Data],
    top: UInt64,
    offsetSize: UInt8 = 1,
    referenceSize: UInt8 = 1
) -> Data {
    var result = Data("bplist00".utf8)
    var offsets = [UInt64]()
    for record in records {
        offsets.append(UInt64(result.count))
        result.append(record)
    }
    let offsetTableOffset = UInt64(result.count)
    for offset in offsets {
        appendBigEndian(
            offset,
            byteCount: Int(offsetSize),
            to: &result
        )
    }
    result.append(Data(repeating: 0, count: 6))
    result.append(offsetSize)
    result.append(referenceSize)
    appendBigEndian(UInt64(records.count), byteCount: 8, to: &result)
    appendBigEndian(top, byteCount: 8, to: &result)
    appendBigEndian(offsetTableOffset, byteCount: 8, to: &result)
    return result
}

private func arrayRecord(_ references: [UInt8]) -> Data {
    precondition(references.count < 15)
    return Data([0xA0 | UInt8(references.count)] + references)
}

private func dictionaryRecord(keys: [UInt8], values: [UInt8]) -> Data {
    precondition(keys.count == values.count && keys.count < 15)
    return Data([0xD0 | UInt8(keys.count)] + keys + values)
}

private func asciiRecord(_ value: String) -> Data {
    let bytes = Array(value.utf8)
    precondition(bytes.count < 15 && bytes.allSatisfy { $0 < 0x80 })
    return Data([0x50 | UInt8(bytes.count)] + bytes)
}

private func dataRecord(_ value: Data) -> Data {
    precondition(value.count < 15)
    return Data([0x40 | UInt8(value.count)]) + value
}

private func uidRecord(_ value: UInt8) -> Data {
    Data([0x80, value])
}

private func signedIntegerRecord(_ value: Int64) -> Data {
    var result = Data([0x13])
    appendBigEndian(
        UInt64(bitPattern: value),
        byteCount: 8,
        to: &result
    )
    return result
}

private func realRecord(_ value: Double) -> Data {
    var result = Data([0x23])
    appendBigEndian(value.bitPattern, byteCount: 8, to: &result)
    return result
}

private func dateRecord(_ seconds: Double) -> Data {
    var result = Data([0x33])
    appendBigEndian(seconds.bitPattern, byteCount: 8, to: &result)
    return result
}

private func appendBigEndian(
    _ value: UInt64,
    byteCount: Int,
    to data: inout Data
) {
    for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
        data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
    }
}

private func replaceBigEndian(
    _ data: inout Data,
    at offset: Int,
    byteCount: Int,
    value: UInt64
) {
    for index in 0..<byteCount {
        let shift = (byteCount - index - 1) * 8
        data[offset + index] = UInt8(
            truncatingIfNeeded: value >> UInt64(shift)
        )
    }
}

private func binaryOffsetTableOffset(_ data: Data) -> Int {
    let start = data.count - 8
    return data[start..<data.count].reduce(0) {
        ($0 << 8) | Int($1)
    }
}

private func binaryPlistWithGap(_ byte: UInt8) -> Data {
    var result = binaryPlist(records: [Data([0x09])], top: 0)
    let oldTableOffset = binaryOffsetTableOffset(result)
    result.insert(byte, at: oldTableOffset)
    replaceBigEndian(
        &result,
        at: result.count - 8,
        byteCount: 8,
        value: UInt64(oldTableOffset + 1)
    )
    return result
}

private struct KeyedArchiveFixture {
    var graph: ForeignPropertyListGraph
    let objects: [ForeignPropertyListObjectID]
    let rootUID: ForeignPropertyListObjectID
}

private func keyedArchiveGraph() -> KeyedArchiveFixture {
    func id(_ value: Int) -> ForeignPropertyListObjectID {
        ForeignPropertyListObjectID(rawValue: value)
    }
    let objects = [id(9), id(10)]
    let rootUID = id(12)
    let nodes: [ForeignPropertyListNode] = [
        .dictionary([
            .init(key: id(1), value: id(2)),
            .init(key: id(3), value: id(4)),
            .init(key: id(5), value: id(6)),
            .init(key: id(7), value: id(8)),
        ]),
        .string("$archiver"),
        .string("NSKeyedArchiver"),
        .string("$version"),
        .integer(100_000),
        .string("$objects"),
        .array(objects),
        .string("$top"),
        .dictionary([.init(key: id(11), value: rootUID)]),
        .string("$null"),
        .string("payload"),
        .string("root"),
        .uid(1),
    ]
    return KeyedArchiveFixture(
        graph: ForeignPropertyListGraph(root: id(0), nodes: nodes),
        objects: objects,
        rootUID: rootUID
    )
}

private func replacingNode(
    _ graph: ForeignPropertyListGraph,
    at index: Int,
    with node: ForeignPropertyListNode
) -> ForeignPropertyListGraph {
    var nodes = graph.nodes
    nodes[index] = node
    return ForeignPropertyListGraph(root: graph.root, nodes: nodes)
}

private func caughtPropertyListError(
    _ operation: () throws -> Void
) -> ForeignPropertyListError? {
    do {
        try operation()
        return nil
    } catch let error as ForeignPropertyListError {
        return error
    } catch {
        return nil
    }
}
