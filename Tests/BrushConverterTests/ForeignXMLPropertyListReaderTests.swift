@testable import BrushConverter
import BrushFormat
import Foundation
import Testing

@Suite("Foreign XML property-list reader")
struct ForeignXMLPropertyListReaderTests {
    @Test
    func productionLimitsMatchTheApprovedPlan() {
        let container = ForeignContainerLimits.standard
        #expect(
            container.maximumSourceBytes
                == BrushFormatLimits.maximumExpandedPackageBytes
        )
        #expect(container.maximumEntriesPerContainer == 4_096)
        #expect(container.maximumNestedEntries == 4_096)
        #expect(container.maximumNestingDepth == 2)
        #expect(
            container.maximumExpandedBytes
                == BrushFormatLimits.maximumExpandedPackageBytes
        )
        #expect(
            container.maximumExpandedBytesPerEntry
                == BrushFormatLimits.maximumEncodedResourceBytes
        )
        #expect(container.maximumCompressionRatio == 200)
        #expect(container.maximumPathUTF8Bytes == 1_024)

        let propertyList = ForeignPropertyListLimits.standard
        #expect(
            propertyList.maximumInputBytes
                == BrushFormatLimits.maximumEncodedResourceBytes
        )
        #expect(propertyList.maximumGraphDepth == 64)
        #expect(propertyList.maximumCollectionElements == 16_384)
        #expect(propertyList.maximumTotalNodes == 100_000)
        #expect(propertyList.maximumStringUTF8Bytes == 64 * 1_024)
        #expect(
            propertyList.maximumOpaqueDataBytes
                == BrushFormatLimits.maximumEncodedResourceBytes
        )
        #expect(
            propertyList.maximumXMLTextUTF8Bytes
                == BrushFormatLimits.maximumEncodedResourceBytes
        )
        #expect(
            propertyList.maximumTotalCollectionReferences == 100_000
        )
        #expect(
            propertyList.maximumTotalResolvedUIDReferences == 100_000
        )
    }

    @Test
    func productionParserDoesNotUseObjectGraphDecoders() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = repository
            .appendingPathComponent("Sources/BrushConverter")
        let files = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let forbidden = [
            "PropertyListSerialization",
            "NSKeyedUnarchiver",
            "XMLParser",
            "AnyObject",
            "NSObject",
            ": Any",
        ]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                #expect(!source.contains(token))
            }
        }
        let completeSource = try files
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let forbiddenPublicSurface = [
            "public struct ForeignZIPReader",
            "public enum ForeignContainerError",
            "public struct ForeignContainerLimits",
            "public final class ForeignExpansionBudget",
            "public struct ForeignAssetTable",
            "public struct ForeignPropertyListGraph",
            "public enum ForeignPropertyListNode",
            "public struct BoundedKeyedArchiveView",
        ]
        for declaration in forbiddenPublicSurface {
            #expect(!completeSource.contains(declaration))
        }
    }

    @Test
    func parsesExactEnvelopeScalarsCollectionsAndEntities() throws {
        var source = Data([0xEF, 0xBB, 0xBF])
        source.append(Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
              <dict>
                <key>a&amp;b</key>
                <string>&lt;x&gt;&#x1F642;</string>
                <key>array</key>
                <array><true/><false /><integer>-42</integer></array>
                <key>real</key><real>-0.0</real>
                <key>date</key><date>2024-02-29T12:34:56Z</date>
                <key>data</key><data>AQID\nBA==</data>
              </dict>
            </plist>
            """.utf8
        ))

        let graph = try ForeignPropertyListReader.parse(source)
        let root = try dictionary(graph.root, in: graph)

        #expect(
            try graph.node(at: try valueID("a&b", in: root, graph: graph))
                == .string("<x>🙂")
        )
        let arrayID = try valueID("array", in: root, graph: graph)
        let array = try #require({
            if case let .array(values) = try graph.node(at: arrayID) {
                return values
            }
            return nil
        }())
        #expect(try graph.node(at: array[0]) == .boolean(true))
        #expect(try graph.node(at: array[1]) == .boolean(false))
        #expect(try graph.node(at: array[2]) == .integer(-42))

        let real = try graph.node(
            at: valueID("real", in: root, graph: graph)
        )
        guard case let .real(realValue) = real else {
            Issue.record("Expected real")
            return
        }
        #expect(realValue == 0)
        #expect(realValue.bitPattern == Double(0).bitPattern)

        let date = try graph.node(
            at: valueID("date", in: root, graph: graph)
        )
        guard case let .date(dateValue) = date else {
            Issue.record("Expected date")
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: dateValue
        )
        #expect(components.year == 2024)
        #expect(components.month == 2)
        #expect(components.day == 29)
        #expect(components.hour == 12)
        #expect(components.minute == 34)
        #expect(components.second == 56)

        #expect(
            try graph.node(at: valueID("data", in: root, graph: graph))
                == .data(Data([1, 2, 3, 4]))
        )
    }

    @Test
    func parsesDataSlicesWithNonzeroStartIndices() throws {
        let source = xml(
            "<string>slice</string>",
            includesDeclaration: false,
            includesDoctype: false
        )
        var padded = Data([0xFF])
        padded.append(source)
        let slice = padded.dropFirst()

        #expect(slice.startIndex != 0)
        let graph = try ForeignPropertyListReader.parse(slice)
        #expect(try graph.node(at: graph.root) == .string("slice"))
        #expect(throws: ForeignPropertyListError.inputTooLarge(
            actual: source.count,
            maximum: source.count - 1
        )) {
            _ = try ForeignPropertyListReader.parse(
                slice,
                limits: ForeignPropertyListLimits(
                    maximumInputBytes: source.count - 1
                )
            )
        }
    }

    @Test
    func acceptsEmptyElementFormsAndEntityEncodedBase64() throws {
        let graph = try ForeignPropertyListReader.parse(
            xml(
                """
                <array>
                  <array/><dict /><string/><string />
                  <data/><data /> <data>&#x41;QID</data>
                  <dict><key/><true/></dict>
                </array>
                """,
                includesDeclaration: false,
                includesDoctype: false
            )
        )
        guard case let .array(values) = try graph.node(at: graph.root) else {
            Issue.record("Expected root array")
            return
        }
        #expect(try graph.node(at: values[0]) == .array([]))
        #expect(try graph.node(at: values[1]) == .dictionary([]))
        #expect(try graph.node(at: values[2]) == .string(""))
        #expect(try graph.node(at: values[3]) == .string(""))
        #expect(try graph.node(at: values[4]) == .data(Data()))
        #expect(try graph.node(at: values[5]) == .data(Data()))
        #expect(try graph.node(at: values[6]) == .data(Data([1, 2, 3])))
        let dictionaryEntries = try dictionary(values[7], in: graph)
        #expect(
            try graph.node(
                at: valueID("", in: dictionaryEntries, graph: graph)
            ) == .boolean(true)
        )
    }

    @Test
    func enforcesDepthCollectionNodeReferenceAndInputBoundaries() throws {
        let depthSource = xml(
            "<array><array><true/></array></array>",
            includesDeclaration: false,
            includesDoctype: false
        )
        _ = try ForeignPropertyListReader.parse(
            depthSource,
            limits: ForeignPropertyListLimits(maximumGraphDepth: 3)
        )
        #expect(throws: ForeignPropertyListError.graphDepthExceeded(
            maximum: 2
        )) {
            try ForeignPropertyListReader.parse(
                depthSource,
                limits: ForeignPropertyListLimits(maximumGraphDepth: 2)
            )
        }

        let collectionSource = xml(
            "<array><true/><false/></array>",
            includesDeclaration: false,
            includesDoctype: false
        )
        _ = try ForeignPropertyListReader.parse(
            collectionSource,
            limits: ForeignPropertyListLimits(maximumCollectionElements: 2)
        )
        #expect(throws: ForeignPropertyListError.collectionLimitExceeded(
            maximum: 1
        )) {
            try ForeignPropertyListReader.parse(
                collectionSource,
                limits: ForeignPropertyListLimits(
                    maximumCollectionElements: 1
                )
            )
        }

        let nodeSource = xml(
            "<dict><key>k</key><true/></dict>",
            includesDeclaration: false,
            includesDoctype: false
        )
        _ = try ForeignPropertyListReader.parse(
            nodeSource,
            limits: ForeignPropertyListLimits(maximumTotalNodes: 3)
        )
        #expect(throws: ForeignPropertyListError.nodeLimitExceeded(
            maximum: 2
        )) {
            try ForeignPropertyListReader.parse(
                nodeSource,
                limits: ForeignPropertyListLimits(maximumTotalNodes: 2)
            )
        }
        _ = try ForeignPropertyListReader.parse(
            nodeSource,
            limits: ForeignPropertyListLimits(
                maximumTotalCollectionReferences: 2
            )
        )
        #expect(
            throws:
                ForeignPropertyListError.collectionReferenceLimitExceeded(
                    maximum: 1
                )
        ) {
            try ForeignPropertyListReader.parse(
                nodeSource,
                limits: ForeignPropertyListLimits(
                    maximumTotalCollectionReferences: 1
                )
            )
        }

        _ = try ForeignPropertyListReader.parse(
            collectionSource,
            limits: ForeignPropertyListLimits(
                maximumInputBytes: collectionSource.count
            )
        )
        #expect(throws: ForeignPropertyListError.inputTooLarge(
            actual: collectionSource.count,
            maximum: collectionSource.count - 1
        )) {
            try ForeignPropertyListReader.parse(
                collectionSource,
                limits: ForeignPropertyListLimits(
                    maximumInputBytes: collectionSource.count - 1
                )
            )
        }
    }

    @Test
    func sharedPerBrushBudgetRejectsASecondOtherwiseValidPlist() throws {
        let scalar = xml(
            "<true/>",
            includesDeclaration: false,
            includesDoctype: false
        )
        let nodeLimits = ForeignPropertyListLimits(maximumTotalNodes: 1)
        _ = try ForeignPropertyListReader.parse(scalar, limits: nodeLimits)
        _ = try ForeignPropertyListReader.parse(scalar, limits: nodeLimits)

        let nodeBudget = ForeignPropertyListBudget(limits: nodeLimits)
        _ = try ForeignPropertyListReader.parse(
            scalar,
            limits: nodeLimits,
            budget: nodeBudget
        )
        #expect(throws: ForeignPropertyListError.nodeLimitExceeded(
            maximum: 1
        )) {
            try ForeignPropertyListReader.parse(
                scalar,
                limits: nodeLimits,
                budget: nodeBudget
            )
        }
        #expect(nodeBudget.consumedTotalNodes == 1)

        let array = xml(
            "<array><true/></array>",
            includesDeclaration: false,
            includesDoctype: false
        )
        let referenceLimits = ForeignPropertyListLimits(
            maximumTotalNodes: 4,
            maximumTotalCollectionReferences: 1
        )
        let referenceBudget = ForeignPropertyListBudget(
            limits: referenceLimits
        )
        _ = try ForeignPropertyListReader.parse(
            array,
            limits: referenceLimits,
            budget: referenceBudget
        )
        #expect(
            throws:
                ForeignPropertyListError.collectionReferenceLimitExceeded(
                    maximum: 1
                )
        ) {
            try ForeignPropertyListReader.parse(
                array,
                limits: referenceLimits,
                budget: referenceBudget
            )
        }
        #expect(referenceBudget.consumedTotalNodes == 2)
        #expect(
            referenceBudget.consumedTotalCollectionReferences == 1
        )

        let looserBudget = ForeignPropertyListBudget()
        #expect(throws: ForeignPropertyListError.invalidLimits) {
            try ForeignPropertyListReader.parse(
                scalar,
                limits: nodeLimits,
                budget: looserBudget
            )
        }

        let mixedLimits = ForeignPropertyListLimits(maximumTotalNodes: 5)
        let mixedBudget = ForeignPropertyListBudget(limits: mixedLimits)
        _ = try ForeignPropertyListReader.parse(
            equivalentBinaryFixture(),
            limits: mixedLimits,
            budget: mixedBudget
        )
        #expect(throws: ForeignPropertyListError.nodeLimitExceeded(
            maximum: 5
        )) {
            try ForeignPropertyListReader.parse(
                scalar,
                limits: mixedLimits,
                budget: mixedBudget
            )
        }
        #expect(mixedBudget.consumedTotalNodes == 5)
    }

    @Test
    func enforcesDecodedStringDataAndTextBoundaries() throws {
        let stringSource = xml(
            "<string>éé</string>",
            includesDeclaration: false,
            includesDoctype: false
        )
        _ = try ForeignPropertyListReader.parse(
            stringSource,
            limits: ForeignPropertyListLimits(
                maximumStringUTF8Bytes: 4
            )
        )
        #expect(throws: ForeignPropertyListError.stringLimitExceeded(
            maximumUTF8Bytes: 3
        )) {
            try ForeignPropertyListReader.parse(
                stringSource,
                limits: ForeignPropertyListLimits(
                    maximumStringUTF8Bytes: 3
                )
            )
        }
        let longPlainSegment = xml(
            "<string>\(String(repeating: "a", count: 4_096))</string>",
            includesDeclaration: false,
            includesDoctype: false
        )
        #expect(throws: ForeignPropertyListError.stringLimitExceeded(
            maximumUTF8Bytes: 8
        )) {
            try ForeignPropertyListReader.parse(
                longPlainSegment,
                limits: ForeignPropertyListLimits(
                    maximumStringUTF8Bytes: 8
                )
            )
        }

        let dataSource = xml(
            "<data>AQID</data>",
            includesDeclaration: false,
            includesDoctype: false
        )
        _ = try ForeignPropertyListReader.parse(
            dataSource,
            limits: ForeignPropertyListLimits(maximumOpaqueDataBytes: 3)
        )
        #expect(throws: ForeignPropertyListError.dataLimitExceeded(
            maximumBytes: 2
        )) {
            try ForeignPropertyListReader.parse(
                dataSource,
                limits: ForeignPropertyListLimits(
                    maximumOpaqueDataBytes: 2
                )
            )
        }

        let textSource = xml(
            "<string>abcd</string>",
            includesDeclaration: false,
            includesDoctype: false
        )
        _ = try ForeignPropertyListReader.parse(
            textSource,
            limits: ForeignPropertyListLimits(
                maximumXMLTextUTF8Bytes: 4
            )
        )
        #expect(throws: ForeignPropertyListError.XMLTextLimitExceeded(
            maximumUTF8Bytes: 3
        )) {
            try ForeignPropertyListReader.parse(
                textSource,
                limits: ForeignPropertyListLimits(
                    maximumXMLTextUTF8Bytes: 3
                )
            )
        }
    }

    @Test
    func rejectsDoctypeEntityNamespaceCDATAAndProcessingInstructionAttacks()
        throws
    {
        let attacks = [
            """
            <!DOCTYPE plist SYSTEM "https://example.com/evil.dtd">
            <plist version="1.0"><string>x</string></plist>
            """,
            """
            <!DOCTYPE plist [<!ENTITY x "boom">]>
            <plist version="1.0"><string>&x;</string></plist>
            """,
            """
            <plist version="1.0"><string><![CDATA[x]]></string></plist>
            """,
            """
            <plist version="1.0"><string>]]></string></plist>
            """,
            """
            <plist version="1.0" xmlns="urn:evil"><string>x</string></plist>
            """,
            """
            <?evil value?>
            <plist version="1.0"><string>x</string></plist>
            """,
            """
            <plist version="1.0"><!-- comment --><string>x</string></plist>
            """,
        ]
        for source in attacks {
            #expect(throws: (any Error).self) {
                try ForeignPropertyListReader.parse(Data(source.utf8))
            }
        }

        let standard = xml("<string>safe</string>")
        let first = try ForeignPropertyListReader.parse(standard)
        let second = try ForeignPropertyListReader.parse(standard)
        #expect(first == second)
    }

    @Test
    func rejectsMalformedDictionariesMarkupAndMultipleRoots() {
        let invalidBodies = [
            "<dict><key>k</key></dict>",
            "<dict><key>k</key><true/><key>k</key><false/></dict>",
            "<dict><string>not-a-key</string><true/></dict>",
            "<array>text<true/></array>",
            "<array><unknown/></array>",
            "<array><true/></dict>",
            "<string>x</string><string>y</string>",
            "<string>x</string></plist>junk",
        ]
        for body in invalidBodies {
            #expect(throws: (any Error).self) {
                try ForeignPropertyListReader.parse(
                    xml(
                        body,
                        includesDeclaration: false,
                        includesDoctype: false
                    )
                )
            }
        }
    }

    @Test
    func rejectsInvalidUTF8EntitiesNumbersDatesAndBase64() throws {
        let invalidBodies = [
            "<string>&unknown;</string>",
            "<string>&#xD800;</string>",
            "<string>&#0;</string>",
            "<integer></integer>",
            "<integer>9223372036854775808</integer>",
            "<integer>1.0</integer>",
            "<real>NaN</real>",
            "<real>+Inf</real>",
            "<real>0x1p2</real>",
            "<real>1e</real>",
            "<date>2023-02-29T00:00:00Z</date>",
            "<date>2024-01-01T00:00:00+00:00</date>",
            "<data>A===</data>",
            "<data>AB==</data>",
            "<data>AQ=Z</data>",
            "<data>AQID*</data>",
        ]
        for body in invalidBodies {
            #expect(throws: (any Error).self) {
                try ForeignPropertyListReader.parse(
                    xml(
                        body,
                        includesDeclaration: false,
                        includesDoctype: false
                    )
                )
            }
        }

        var invalidUTF8 = Data(
            #"<plist version="1.0"><string>"#.utf8
        )
        invalidUTF8.append(contentsOf: [0xC0, 0xAF])
        invalidUTF8.append(Data("</string></plist>".utf8))
        #expect(throws: (any Error).self) {
            try ForeignPropertyListReader.parse(invalidUTF8)
        }

        let bounds = [
            ("<integer>9223372036854775807</integer>", Int64.max),
            ("<integer>-9223372036854775808</integer>", Int64.min),
        ]
        for (body, expected) in bounds {
            let graph = try ForeignPropertyListReader.parse(
                xml(
                    body,
                    includesDeclaration: false,
                    includesDoctype: false
                )
            )
            #expect(try graph.node(at: graph.root) == .integer(expected))
        }
    }

    @Test
    func XMLAndBinaryDispatchProduceTheSameCanonicalGraph() throws {
        let binary = equivalentBinaryFixture()
        let xmlSource = xml(
            """
            <array>
              <integer>7</integer><true/>
              <string>brush</string><data>CQgH</data>
            </array>
            """,
            includesDeclaration: false,
            includesDoctype: false
        )

        let binaryGraph = try ForeignPropertyListReader.parse(binary)
        let XMLGraph = try ForeignPropertyListReader.parse(xmlSource)

        #expect(
            try canonical(binaryGraph.root, in: binaryGraph)
                == canonical(XMLGraph.root, in: XMLGraph)
        )
    }

    @Test
    func hostileXMLCorpusProducesExactErrorsOnRepeat() {
        let cases: [(Data, ForeignPropertyListError)] = [
            (Data("not a plist".utf8), .unsupportedSignature),
            (
                Data(
                    #"<plist version="1.0"><unknown/></plist>"#.utf8
                ),
                .unsupportedXMLConstruct(offset: 21)
            ),
            (
                Data(
                    #"<plist version="1.0"><real>NaN</real></plist>"#.utf8
                ),
                .nonFiniteNumber(object: 21)
            ),
            (
                Data(
                    #"<plist version="1.0"><data>AB==</data></plist>"#.utf8
                ),
                .invalidBase64(offset: 21)
            ),
        ]

        for (bytes, expected) in cases {
            for _ in 0..<2 {
                #expect(caughtPropertyListError {
                    _ = try ForeignPropertyListReader.parse(bytes)
                } == expected)
            }
        }
    }
}

private indirect enum CanonicalPropertyList: Equatable {
    case dictionary([(String, CanonicalPropertyList)])
    case array([CanonicalPropertyList])
    case boolean(Bool)
    case integer(Int64)
    case real(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case uid(UInt64)

    static func == (
        lhs: CanonicalPropertyList,
        rhs: CanonicalPropertyList
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.dictionary(left), .dictionary(right)):
            guard left.count == right.count else { return false }
            return zip(left, right).allSatisfy {
                $0.0 == $1.0 && $0.1 == $1.1
            }
        case let (.array(left), .array(right)):
            return left == right
        case let (.boolean(left), .boolean(right)):
            return left == right
        case let (.integer(left), .integer(right)):
            return left == right
        case let (.real(left), .real(right)):
            return left == right
        case let (.string(left), .string(right)):
            return left == right
        case let (.data(left), .data(right)):
            return left == right
        case let (.date(left), .date(right)):
            return left == right
        case let (.uid(left), .uid(right)):
            return left == right
        default:
            return false
        }
    }
}

private func canonical(
    _ identifier: ForeignPropertyListObjectID,
    in graph: ForeignPropertyListGraph
) throws -> CanonicalPropertyList {
    switch try graph.node(at: identifier) {
    case let .dictionary(entries):
        let pairs = try entries.map { entry -> (String, CanonicalPropertyList) in
            guard case let .string(key) = try graph.node(at: entry.key) else {
                throw ForeignPropertyListError.dictionaryKeyIsNotString(
                    object: identifier.rawValue
                )
            }
            return (key, try canonical(entry.value, in: graph))
        }.sorted { $0.0 < $1.0 }
        return .dictionary(pairs)
    case let .array(values):
        return .array(try values.map { try canonical($0, in: graph) })
    case let .boolean(value):
        return .boolean(value)
    case let .integer(value):
        return .integer(value)
    case let .real(value):
        return .real(value)
    case let .string(value):
        return .string(value)
    case let .data(value):
        return .data(value)
    case let .date(value):
        return .date(value)
    case let .uid(value):
        return .uid(value)
    }
}

private func dictionary(
    _ identifier: ForeignPropertyListObjectID,
    in graph: ForeignPropertyListGraph
) throws -> [ForeignPropertyListDictionaryEntry] {
    guard case let .dictionary(entries) = try graph.node(at: identifier) else {
        throw ForeignPropertyListError.dictionaryKeyIsNotString(
            object: identifier.rawValue
        )
    }
    return entries
}

private func valueID(
    _ key: String,
    in entries: [ForeignPropertyListDictionaryEntry],
    graph: ForeignPropertyListGraph
) throws -> ForeignPropertyListObjectID {
    for entry in entries where try graph.node(at: entry.key) == .string(key) {
        return entry.value
    }
    throw ForeignPropertyListError.invalidReference(object: -1)
}

private func xml(
    _ body: String,
    includesDeclaration: Bool = true,
    includesDoctype: Bool = true
) -> Data {
    var parts: [String] = []
    if includesDeclaration {
        parts.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
    }
    if includesDoctype {
        parts.append(
            #"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#
        )
    }
    parts.append(#"<plist version="1.0">"#)
    parts.append(body)
    parts.append("</plist>")
    return Data(parts.joined(separator: "\n").utf8)
}

private func equivalentBinaryFixture() -> Data {
    var result = Data("bplist00".utf8)
    result.append(contentsOf: [0xA4, 1, 2, 3, 4])
    result.append(contentsOf: [0x10, 7])
    result.append(0x09)
    result.append(0x55)
    result.append(Data("brush".utf8))
    result.append(contentsOf: [0x43, 9, 8, 7])
    result.append(contentsOf: [8, 13, 15, 16, 22])
    result.append(Data(repeating: 0, count: 6))
    result.append(contentsOf: [1, 1])
    appendBigEndianUInt64(5, to: &result)
    appendBigEndianUInt64(0, to: &result)
    appendBigEndianUInt64(26, to: &result)
    return result
}

private func appendBigEndianUInt64(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
    }
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
