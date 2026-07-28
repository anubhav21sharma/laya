import Foundation

enum ForeignXMLPropertyListReader {
    static func read(
        _ data: Data,
        limits: ForeignPropertyListLimits = .standard,
        budget: ForeignPropertyListBudget? = nil
    ) throws -> ForeignPropertyListGraph {
        guard budget?.isCompatible(with: limits) != false else {
            throw ForeignPropertyListError.invalidLimits
        }
        guard data.count <= limits.maximumInputBytes else {
            throw ForeignPropertyListError.inputTooLarge(
                actual: data.count,
                maximum: limits.maximumInputBytes
            )
        }
        let source = data.startIndex == 0 ? data : Data(data)
        return try source.withUnsafeBytes { rawBytes in
            var parser = Parser(
                bytes: rawBytes.bindMemory(to: UInt8.self),
                limits: limits,
                budget: budget
            )
            do {
                return try parser.parse()
            } catch {
                parser.refundReservations()
                throw error
            }
        }
    }
}

private extension ForeignXMLPropertyListReader {
    enum CollectionKind {
        case array
        case dictionary
    }

    struct Frame {
        let kind: CollectionKind
        let depth: Int
        var arrayValues: [ForeignPropertyListObjectID] = []
        var dictionaryEntries: [ForeignPropertyListDictionaryEntry] = []
        var dictionaryKeys: Set<String> = []
        var pendingKey: ForeignPropertyListObjectID?
    }

    struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        let limits: ForeignPropertyListLimits
        let budget: ForeignPropertyListBudget?

        var offset = 0
        var nodes: [ForeignPropertyListNode] = []
        var frames: [Frame] = []
        var root: ForeignPropertyListObjectID?
        var totalCollectionReferences = 0
        var totalXMLTextBytes = 0
        var reservedNodes = 0
        var reservedCollectionReferences = 0

        mutating func parse() throws -> ForeignPropertyListGraph {
            try parseProlog()
            try consume(xmlPlistOpen)

            while root == nil || !frames.isEmpty {
                skipWhitespace()
                if frames.isEmpty {
                    guard root == nil else {
                        throw ForeignPropertyListError.malformedXML(
                            offset: offset
                        )
                    }
                    try parseValue(at: 1)
                    continue
                }

                switch frames[frames.count - 1].kind {
                case .array:
                    if matches(xmlArrayClose) {
                        try closeCollection(expected: .array)
                    } else {
                        try parseValue(
                            at: frames[frames.count - 1].depth + 1
                        )
                    }
                case .dictionary:
                    if frames[frames.count - 1].pendingKey == nil {
                        if matches(xmlDictionaryClose) {
                            try closeCollection(expected: .dictionary)
                        } else {
                            try parseDictionaryKey()
                        }
                    } else {
                        try parseValue(
                            at: frames[frames.count - 1].depth + 1
                        )
                    }
                }
            }

            skipWhitespace()
            try consume(xmlPlistClose)
            skipWhitespace()
            guard offset == bytes.count, let root else {
                throw ForeignPropertyListError.malformedXML(offset: offset)
            }
            let graph = ForeignPropertyListGraph(root: root, nodes: nodes)
            try ForeignPropertyListGraphValidator.validate(
                graph,
                limits: limits
            )
            return graph
        }

        mutating func parseProlog() throws {
            if matches(xmlUTF8BOM) {
                offset += xmlUTF8BOM.count
            }
            skipWhitespace()
            if matches(xmlDeclaration) {
                offset += xmlDeclaration.count
                skipWhitespace()
            } else if matchesPrefix(xmlProcessingInstructionPrefix) {
                throw ForeignPropertyListError.unsupportedXMLConstruct(
                    offset: offset
                )
            }
            if matches(xmlDoctype) {
                offset += xmlDoctype.count
                skipWhitespace()
            } else if matchesPrefix(xmlDoctypePrefix) {
                throw ForeignPropertyListError.unsupportedXMLConstruct(
                    offset: offset
                )
            }
        }

        mutating func parseValue(at depth: Int) throws {
            guard depth <= limits.maximumGraphDepth else {
                throw ForeignPropertyListError.graphDepthExceeded(
                    maximum: limits.maximumGraphDepth
                )
            }
            let start = offset
            if matches(xmlArrayEmpty) || matches(xmlArraySpacedEmpty) {
                if matches(xmlArrayEmpty) {
                    offset += xmlArrayEmpty.count
                } else {
                    offset += xmlArraySpacedEmpty.count
                }
                try attach(try addNode(.array([])))
            } else if matches(xmlDictionaryEmpty)
                || matches(xmlDictionarySpacedEmpty) {
                if matches(xmlDictionaryEmpty) {
                    offset += xmlDictionaryEmpty.count
                } else {
                    offset += xmlDictionarySpacedEmpty.count
                }
                try attach(try addNode(.dictionary([])))
            } else if matches(xmlStringEmpty)
                || matches(xmlStringSpacedEmpty) {
                if matches(xmlStringEmpty) {
                    offset += xmlStringEmpty.count
                } else {
                    offset += xmlStringSpacedEmpty.count
                }
                try attach(try addNode(.string("")))
            } else if matches(xmlDataEmpty) || matches(xmlDataSpacedEmpty) {
                if matches(xmlDataEmpty) {
                    offset += xmlDataEmpty.count
                } else {
                    offset += xmlDataSpacedEmpty.count
                }
                try attach(try addNode(.data(Data())))
            } else if matches(xmlArrayOpen) {
                try openCollection(.array, depth: depth)
            } else if matches(xmlDictionaryOpen) {
                try openCollection(.dictionary, depth: depth)
            } else if matches(xmlTrueEmpty) || matches(xmlTrueSpacedEmpty) {
                if matches(xmlTrueEmpty) {
                    offset += xmlTrueEmpty.count
                } else {
                    offset += xmlTrueSpacedEmpty.count
                }
                try attach(try addNode(.boolean(true)))
            } else if matches(xmlFalseEmpty)
                || matches(xmlFalseSpacedEmpty) {
                if matches(xmlFalseEmpty) {
                    offset += xmlFalseEmpty.count
                } else {
                    offset += xmlFalseSpacedEmpty.count
                }
                try attach(try addNode(.boolean(false)))
            } else if matches(xmlTrueOpen) {
                offset += xmlTrueOpen.count
                guard matches(xmlTrueClose) else {
                    throw ForeignPropertyListError.malformedXML(offset: offset)
                }
                offset += xmlTrueClose.count
                try attach(try addNode(.boolean(true)))
            } else if matches(xmlFalseOpen) {
                offset += xmlFalseOpen.count
                guard matches(xmlFalseClose) else {
                    throw ForeignPropertyListError.malformedXML(offset: offset)
                }
                offset += xmlFalseClose.count
                try attach(try addNode(.boolean(false)))
            } else if matches(xmlStringOpen) {
                offset += xmlStringOpen.count
                let value = try parseText(
                    until: xmlStringClose,
                    maximumDecodedBytes: limits.maximumStringUTF8Bytes
                )
                try attach(try addNode(.string(value)))
            } else if matches(xmlIntegerOpen) {
                offset += xmlIntegerOpen.count
                let text = try parseText(
                    until: xmlIntegerClose,
                    maximumDecodedBytes: limits.maximumStringUTF8Bytes
                )
                let value = try parseInteger(text, sourceOffset: start)
                try attach(try addNode(.integer(value)))
            } else if matches(xmlRealOpen) {
                offset += xmlRealOpen.count
                let text = try parseText(
                    until: xmlRealClose,
                    maximumDecodedBytes: limits.maximumStringUTF8Bytes
                )
                let value = try parseReal(text, sourceOffset: start)
                try attach(try addNode(.real(value)))
            } else if matches(xmlDateOpen) {
                offset += xmlDateOpen.count
                let text = try parseText(
                    until: xmlDateClose,
                    maximumDecodedBytes: limits.maximumStringUTF8Bytes
                )
                let value = try parseDate(text, sourceOffset: start)
                try attach(try addNode(.date(value)))
            } else if matches(xmlDataOpen) {
                offset += xmlDataOpen.count
                let value = try parseBase64Text(
                    until: xmlDataClose,
                    sourceOffset: start
                )
                try attach(try addNode(.data(value)))
            } else {
                throw ForeignPropertyListError.unsupportedXMLConstruct(
                    offset: offset
                )
            }
        }

        mutating func openCollection(
            _ kind: CollectionKind,
            depth: Int
        ) throws {
            try ensureNodeCapacity(additionalNodes: 1)
            try reserveNode()
            switch kind {
            case .array:
                offset += xmlArrayOpen.count
            case .dictionary:
                offset += xmlDictionaryOpen.count
            }
            frames.append(Frame(kind: kind, depth: depth))
        }

        mutating func closeCollection(
            expected: CollectionKind
        ) throws {
            guard let frame = frames.popLast(), frame.kind == expected else {
                throw ForeignPropertyListError.malformedXML(offset: offset)
            }
            switch expected {
            case .array:
                offset += xmlArrayClose.count
                let identifier = try addNode(
                    .array(frame.arrayValues),
                    reservationAlreadyHeld: true
                )
                try attach(identifier)
            case .dictionary:
                guard frame.pendingKey == nil else {
                    throw ForeignPropertyListError.malformedXML(offset: offset)
                }
                offset += xmlDictionaryClose.count
                let identifier = try addNode(
                    .dictionary(frame.dictionaryEntries),
                    reservationAlreadyHeld: true
                )
                try attach(identifier)
            }
        }

        mutating func parseDictionaryKey() throws {
            let start = offset
            let key: String
            if matches(xmlKeyEmpty) || matches(xmlKeySpacedEmpty) {
                if matches(xmlKeyEmpty) {
                    offset += xmlKeyEmpty.count
                } else {
                    offset += xmlKeySpacedEmpty.count
                }
                key = ""
            } else {
                try consume(xmlKeyOpen)
                key = try parseText(
                    until: xmlKeyClose,
                    maximumDecodedBytes: limits.maximumStringUTF8Bytes
                )
            }
            guard frames.indices.contains(frames.count - 1),
                  frames[frames.count - 1].kind == .dictionary,
                  frames[frames.count - 1].pendingKey == nil
            else {
                throw ForeignPropertyListError.malformedXML(offset: start)
            }
            guard frames[frames.count - 1].dictionaryKeys.insert(key).inserted
            else {
                throw ForeignPropertyListError.duplicateXMLDictionaryKey(
                    offset: start
                )
            }
            let identifier = try addNode(.string(key))
            frames[frames.count - 1].pendingKey = identifier
        }

        mutating func attach(
            _ identifier: ForeignPropertyListObjectID
        ) throws {
            guard !frames.isEmpty else {
                guard root == nil else {
                    throw ForeignPropertyListError.malformedXML(offset: offset)
                }
                root = identifier
                return
            }

            let frameIndex = frames.count - 1
            switch frames[frameIndex].kind {
            case .array:
                guard frames[frameIndex].arrayValues.count
                        < limits.maximumCollectionElements
                else {
                    throw ForeignPropertyListError.collectionLimitExceeded(
                        maximum: limits.maximumCollectionElements
                    )
                }
                try chargeCollectionReferences(1)
                frames[frameIndex].arrayValues.append(identifier)
            case .dictionary:
                guard let key = frames[frameIndex].pendingKey else {
                    throw ForeignPropertyListError.malformedXML(offset: offset)
                }
                guard frames[frameIndex].dictionaryEntries.count
                        < limits.maximumCollectionElements
                else {
                    throw ForeignPropertyListError.collectionLimitExceeded(
                        maximum: limits.maximumCollectionElements
                    )
                }
                try chargeCollectionReferences(2)
                frames[frameIndex].dictionaryEntries.append(
                    ForeignPropertyListDictionaryEntry(
                        key: key,
                        value: identifier
                    )
                )
                frames[frameIndex].pendingKey = nil
            }
        }

        mutating func addNode(
            _ node: ForeignPropertyListNode,
            reservationAlreadyHeld: Bool = false
        ) throws -> ForeignPropertyListObjectID {
            try ensureNodeCapacity(additionalNodes: 1)
            if !reservationAlreadyHeld {
                try reserveNode()
            }
            let identifier = ForeignPropertyListObjectID(
                rawValue: nodes.count
            )
            nodes.append(node)
            return identifier
        }

        func ensureNodeCapacity(additionalNodes: Int) throws {
            let (existing, existingOverflow) = nodes.count
                .addingReportingOverflow(frames.count)
            let (projected, projectedOverflow) = existing
                .addingReportingOverflow(additionalNodes)
            guard !existingOverflow,
                  !projectedOverflow,
                  projected <= limits.maximumTotalNodes
            else {
                throw ForeignPropertyListError.nodeLimitExceeded(
                    maximum: limits.maximumTotalNodes
                )
            }
        }

        mutating func chargeCollectionReferences(_ count: Int) throws {
            let (next, overflow) = totalCollectionReferences
                .addingReportingOverflow(count)
            guard !overflow,
                  next <= limits.maximumTotalCollectionReferences
            else {
                throw ForeignPropertyListError
                    .collectionReferenceLimitExceeded(
                        maximum: limits.maximumTotalCollectionReferences
                    )
            }
            try budget?.reserve(nodes: 0, collectionReferences: count)
            reservedCollectionReferences += count
            totalCollectionReferences = next
        }

        mutating func reserveNode() throws {
            try budget?.reserve(nodes: 1, collectionReferences: 0)
            reservedNodes += 1
        }

        mutating func refundReservations() {
            budget?.refund(
                nodes: reservedNodes,
                collectionReferences: reservedCollectionReferences
            )
            reservedNodes = 0
            reservedCollectionReferences = 0
        }

        mutating func parseText(
            until closingTag: [UInt8],
            maximumDecodedBytes: Int
        ) throws -> String {
            let start = offset
            guard let closingOffset = find(closingTag, from: offset) else {
                throw ForeignPropertyListError.malformedXML(offset: start)
            }
            guard !containsByte(0x3C, in: offset..<closingOffset) else {
                throw ForeignPropertyListError.unsupportedXMLConstruct(
                    offset: offset
                )
            }
            guard !containsSequence(
                xmlCDATAEnd,
                in: offset..<closingOffset
            ) else {
                throw ForeignPropertyListError.unsupportedXMLConstruct(
                    offset: offset
                )
            }
            let rawCount = closingOffset - offset
            let (nextXMLTextBytes, overflow) = totalXMLTextBytes
                .addingReportingOverflow(rawCount)
            guard !overflow,
                  nextXMLTextBytes <= limits.maximumXMLTextUTF8Bytes
            else {
                throw ForeignPropertyListError.XMLTextLimitExceeded(
                    maximumUTF8Bytes: limits.maximumXMLTextUTF8Bytes
                )
            }
            totalXMLTextBytes = nextXMLTextBytes

            let value = try decodeXMLText(
                offset..<closingOffset,
                maximumDecodedBytes: maximumDecodedBytes
            )
            offset = closingOffset + closingTag.count
            return value
        }

        func decodeXMLText(
            _ range: Range<Int>,
            maximumDecodedBytes: Int
        ) throws -> String {
            var result = ""
            var decodedBytes = 0
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                let segmentStart = cursor
                while cursor < range.upperBound, bytes[cursor] != 0x26 {
                    cursor += 1
                }
                if segmentStart < cursor {
                    let segmentByteCount = cursor - segmentStart
                    guard segmentByteCount
                            <= maximumDecodedBytes - decodedBytes
                    else {
                        throw ForeignPropertyListError.stringLimitExceeded(
                            maximumUTF8Bytes: maximumDecodedBytes
                        )
                    }
                    let segmentBytes = UnsafeBufferPointer(
                        rebasing: bytes[segmentStart..<cursor]
                    )
                    guard let segment = String(
                        bytes: segmentBytes,
                        encoding: .utf8
                    ), segment.unicodeScalars.allSatisfy(isValidXMLScalar)
                    else {
                        throw ForeignPropertyListError.malformedXML(
                            offset: segmentStart
                        )
                    }
                    decodedBytes += segmentByteCount
                    result.append(segment)
                }
                guard cursor < range.upperBound else { break }

                let entityOffset = cursor
                cursor += 1
                let bodyStart = cursor
                while cursor < range.upperBound,
                      bytes[cursor] != 0x3B,
                      cursor - bodyStart <= 16 {
                    cursor += 1
                }
                guard cursor < range.upperBound,
                      bytes[cursor] == 0x3B,
                      cursor > bodyStart
                else {
                    throw ForeignPropertyListError.malformedXML(
                        offset: entityOffset
                    )
                }
                let scalar = try decodeEntity(
                    bodyStart..<cursor,
                    sourceOffset: entityOffset
                )
                let scalarBytes = scalar.utf8.count
                let (next, overflow) = decodedBytes.addingReportingOverflow(
                    scalarBytes
                )
                guard !overflow, next <= maximumDecodedBytes else {
                    throw ForeignPropertyListError.stringLimitExceeded(
                        maximumUTF8Bytes: maximumDecodedBytes
                    )
                }
                decodedBytes = next
                result.unicodeScalars.append(scalar)
                cursor += 1
            }
            return result
        }

        func decodeEntity(
            _ range: Range<Int>,
            sourceOffset: Int
        ) throws -> Unicode.Scalar {
            if equals(range, asciiAmp) { return "&" }
            if equals(range, asciiApostrophe) { return "'" }
            if equals(range, asciiGreaterThan) { return ">" }
            if equals(range, asciiLessThan) { return "<" }
            if equals(range, asciiQuotationMark) { return "\"" }

            guard bytes[range.lowerBound] == 0x23 else {
                throw ForeignPropertyListError.unsupportedXMLConstruct(
                    offset: sourceOffset
                )
            }
            var cursor = range.lowerBound + 1
            var radix: UInt32 = 10
            if cursor < range.upperBound, bytes[cursor] == 0x78 {
                radix = 16
                cursor += 1
            }
            guard cursor < range.upperBound else {
                throw ForeignPropertyListError.malformedXML(
                    offset: sourceOffset
                )
            }
            var value: UInt32 = 0
            while cursor < range.upperBound {
                let digit: UInt32
                switch bytes[cursor] {
                case 0x30...0x39:
                    digit = UInt32(bytes[cursor] - 0x30)
                case 0x41...0x46 where radix == 16:
                    digit = UInt32(bytes[cursor] - 0x41 + 10)
                case 0x61...0x66 where radix == 16:
                    digit = UInt32(bytes[cursor] - 0x61 + 10)
                default:
                    throw ForeignPropertyListError.malformedXML(
                        offset: sourceOffset
                    )
                }
                guard digit < radix,
                      value <= (UInt32.max - digit) / radix
                else {
                    throw ForeignPropertyListError.malformedXML(
                        offset: sourceOffset
                    )
                }
                value = value * radix + digit
                cursor += 1
            }
            guard let scalar = Unicode.Scalar(value),
                  isValidXMLScalar(scalar)
            else {
                throw ForeignPropertyListError.malformedXML(
                    offset: sourceOffset
                )
            }
            return scalar
        }

        func parseInteger(
            _ source: String,
            sourceOffset: Int
        ) throws -> Int64 {
            let text = trimASCIIWhitespace(source)
            let scalars = Array(text.utf8)
            guard !scalars.isEmpty else {
                throw ForeignPropertyListError.invalidScalar(
                    kind: .integer,
                    offset: sourceOffset
                )
            }
            var cursor = 0
            var negative = false
            if scalars[cursor] == 0x2B || scalars[cursor] == 0x2D {
                negative = scalars[cursor] == 0x2D
                cursor += 1
            }
            guard cursor < scalars.count else {
                throw ForeignPropertyListError.invalidScalar(
                    kind: .integer,
                    offset: sourceOffset
                )
            }
            let limit = negative
                ? UInt64(Int64.max) + 1
                : UInt64(Int64.max)
            var magnitude: UInt64 = 0
            while cursor < scalars.count {
                let byte = scalars[cursor]
                guard (0x30...0x39).contains(byte) else {
                    throw ForeignPropertyListError.invalidScalar(
                        kind: .integer,
                        offset: sourceOffset
                    )
                }
                let digit = UInt64(byte - 0x30)
                guard magnitude <= (limit - digit) / 10 else {
                    throw ForeignPropertyListError.integerOutOfRange(
                        object: sourceOffset
                    )
                }
                magnitude = magnitude * 10 + digit
                cursor += 1
            }
            if negative {
                return magnitude == UInt64(Int64.max) + 1
                    ? Int64.min
                    : -Int64(magnitude)
            }
            return Int64(magnitude)
        }

        func parseReal(
            _ source: String,
            sourceOffset: Int
        ) throws -> Double {
            let text = trimASCIIWhitespace(source)
            let bytes = Array(text.utf8)
            guard isValidDecimalReal(bytes),
                  let value = Double(text),
                  value.isFinite
            else {
                if let value = Double(text), !value.isFinite {
                    throw ForeignPropertyListError.nonFiniteNumber(
                        object: sourceOffset
                    )
                }
                throw ForeignPropertyListError.invalidScalar(
                    kind: .real,
                    offset: sourceOffset
                )
            }
            return value == 0 ? 0 : value
        }

        func parseDate(
            _ source: String,
            sourceOffset: Int
        ) throws -> Date {
            let text = trimASCIIWhitespace(source)
            let value = Array(text.utf8)
            guard value.count == 20,
                  value[4] == 0x2D,
                  value[7] == 0x2D,
                  value[10] == 0x54,
                  value[13] == 0x3A,
                  value[16] == 0x3A,
                  value[19] == 0x5A,
                  let year = decimal(value, 0..<4),
                  let month = decimal(value, 5..<7),
                  let day = decimal(value, 8..<10),
                  let hour = decimal(value, 11..<13),
                  let minute = decimal(value, 14..<16),
                  let second = decimal(value, 17..<19),
                  (1...9_999).contains(year),
                  (1...12).contains(month),
                  (0...23).contains(hour),
                  (0...59).contains(minute),
                  (0...59).contains(second)
            else {
                throw ForeignPropertyListError.invalidDate(
                    offset: sourceOffset
                )
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = DateComponents()
            components.timeZone = calendar.timeZone
            components.calendar = calendar
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = second
            guard let date = calendar.date(from: components) else {
                throw ForeignPropertyListError.invalidDate(
                    offset: sourceOffset
                )
            }
            let roundTrip = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: date
            )
            guard roundTrip.year == year,
                  roundTrip.month == month,
                  roundTrip.day == day,
                  roundTrip.hour == hour,
                  roundTrip.minute == minute,
                  roundTrip.second == second
            else {
                throw ForeignPropertyListError.invalidDate(
                    offset: sourceOffset
                )
            }
            return date
        }

        mutating func parseBase64Text(
            until closingTag: [UInt8],
            sourceOffset: Int
        ) throws -> Data {
            let textStart = offset
            guard let closingOffset = find(closingTag, from: offset) else {
                throw ForeignPropertyListError.malformedXML(offset: textStart)
            }
            guard !containsByte(0x3C, in: offset..<closingOffset) else {
                throw ForeignPropertyListError.unsupportedXMLConstruct(
                    offset: offset
                )
            }
            guard !containsSequence(
                xmlCDATAEnd,
                in: offset..<closingOffset
            ) else {
                throw ForeignPropertyListError.unsupportedXMLConstruct(
                    offset: offset
                )
            }
            let rawCount = closingOffset - offset
            let (nextXMLTextBytes, textOverflow) = totalXMLTextBytes
                .addingReportingOverflow(rawCount)
            guard !textOverflow,
                  nextXMLTextBytes <= limits.maximumXMLTextUTF8Bytes
            else {
                throw ForeignPropertyListError.XMLTextLimitExceeded(
                    maximumUTF8Bytes: limits.maximumXMLTextUTF8Bytes
                )
            }
            totalXMLTextBytes = nextXMLTextBytes

            var compactCount = 0
            var paddingCount = 0
            var sawPadding = false
            try forEachBase64Byte(in: textStart..<closingOffset) { byte in
                guard base64AlphabetContains(byte) || byte == 0x3D else {
                    throw ForeignPropertyListError.invalidBase64(
                        offset: sourceOffset
                    )
                }
                if byte == 0x3D {
                    guard compactCount % 4 >= 2, paddingCount < 2 else {
                        throw ForeignPropertyListError.invalidBase64(
                            offset: sourceOffset
                        )
                    }
                    sawPadding = true
                    paddingCount += 1
                } else if sawPadding {
                    throw ForeignPropertyListError.invalidBase64(
                        offset: sourceOffset
                    )
                }
                compactCount += 1
            }
            guard compactCount.isMultiple(of: 4) else {
                throw ForeignPropertyListError.invalidBase64(
                    offset: sourceOffset
                )
            }
            guard compactCount > 0 else {
                offset = closingOffset + closingTag.count
                return Data()
            }

            let (groups, multiplicationOverflow) = (compactCount / 4)
                .multipliedReportingOverflow(by: 3)
            guard !multiplicationOverflow, groups >= paddingCount else {
                throw ForeignPropertyListError.invalidBase64(
                    offset: sourceOffset
                )
            }
            let decodedCount = groups - paddingCount
            guard decodedCount <= limits.maximumOpaqueDataBytes else {
                throw ForeignPropertyListError.dataLimitExceeded(
                    maximumBytes: limits.maximumOpaqueDataBytes
                )
            }

            var output = Data()
            output.reserveCapacity(decodedCount)
            var quartet = [UInt8](repeating: 0, count: 4)
            var quartetCount = 0
            var consumed = 0
            try forEachBase64Byte(in: textStart..<closingOffset) { byte in
                quartet[quartetCount] = byte
                quartetCount += 1
                consumed += 1
                guard quartetCount == 4 else { return }
                let isLast = consumed == compactCount
                let a = try base64Value(
                    quartet[0],
                    permitsPadding: false,
                    sourceOffset: sourceOffset
                )
                let b = try base64Value(
                    quartet[1],
                    permitsPadding: false,
                    sourceOffset: sourceOffset
                )
                let cByte = quartet[2]
                let dByte = quartet[3]
                guard (cByte != 0x3D || (isLast && dByte == 0x3D)),
                      dByte != 0x3D || isLast
                else {
                    throw ForeignPropertyListError.invalidBase64(
                        offset: sourceOffset
                    )
                }
                let c = try base64Value(
                    cByte,
                    permitsPadding: isLast,
                    sourceOffset: sourceOffset
                )
                let d = try base64Value(
                    dByte,
                    permitsPadding: isLast,
                    sourceOffset: sourceOffset
                )
                output.append(UInt8((a << 2) | (b >> 4)))
                if cByte != 0x3D {
                    output.append(UInt8(((b & 0x0F) << 4) | (c >> 2)))
                }
                if dByte != 0x3D {
                    output.append(UInt8(((c & 0x03) << 6) | d))
                }
                if cByte == 0x3D {
                    guard b & 0x0F == 0 else {
                        throw ForeignPropertyListError.invalidBase64(
                            offset: sourceOffset
                        )
                    }
                } else if dByte == 0x3D {
                    guard c & 0x03 == 0 else {
                        throw ForeignPropertyListError.invalidBase64(
                            offset: sourceOffset
                        )
                    }
                }
                quartetCount = 0
            }
            guard output.count == decodedCount else {
                throw ForeignPropertyListError.invalidBase64(
                    offset: sourceOffset
                )
            }
            offset = closingOffset + closingTag.count
            return output
        }

        func forEachBase64Byte(
            in range: Range<Int>,
            _ body: (UInt8) throws -> Void
        ) throws {
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                let byte = bytes[cursor]
                if isWhitespace(byte) {
                    cursor += 1
                    continue
                }
                if byte == 0x26 {
                    let entityOffset = cursor
                    cursor += 1
                    let bodyStart = cursor
                    while cursor < range.upperBound,
                          bytes[cursor] != 0x3B,
                          cursor - bodyStart <= 16 {
                        cursor += 1
                    }
                    guard cursor < range.upperBound,
                          bytes[cursor] == 0x3B,
                          cursor > bodyStart
                    else {
                        throw ForeignPropertyListError.invalidBase64(
                            offset: entityOffset
                        )
                    }
                    let scalar = try decodeEntity(
                        bodyStart..<cursor,
                        sourceOffset: entityOffset
                    )
                    guard scalar.value < 0x80 else {
                        throw ForeignPropertyListError.invalidBase64(
                            offset: entityOffset
                        )
                    }
                    try body(UInt8(scalar.value))
                    cursor += 1
                    continue
                }
                guard byte < 0x80, isValidXMLScalar(Unicode.Scalar(byte)) else {
                    throw ForeignPropertyListError.invalidBase64(
                        offset: cursor
                    )
                }
                try body(byte)
                cursor += 1
            }
        }

        func base64AlphabetContains(_ byte: UInt8) -> Bool {
            (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte)
                || (0x30...0x39).contains(byte)
                || byte == 0x2B
                || byte == 0x2F
        }

        func base64Value(
            _ byte: UInt8,
            permitsPadding: Bool,
            sourceOffset: Int
        ) throws -> UInt8 {
            switch byte {
            case 0x41...0x5A: return byte - 0x41
            case 0x61...0x7A: return byte - 0x61 + 26
            case 0x30...0x39: return byte - 0x30 + 52
            case 0x2B: return 62
            case 0x2F: return 63
            case 0x3D where permitsPadding: return 0
            default:
                throw ForeignPropertyListError.invalidBase64(
                    offset: sourceOffset
                )
            }
        }

        func isValidDecimalReal(_ bytes: [UInt8]) -> Bool {
            guard !bytes.isEmpty else { return false }
            var cursor = 0
            if bytes[cursor] == 0x2B || bytes[cursor] == 0x2D {
                cursor += 1
            }
            guard cursor < bytes.count else { return false }

            var wholeDigits = 0
            while cursor < bytes.count, (0x30...0x39).contains(bytes[cursor]) {
                wholeDigits += 1
                cursor += 1
            }
            var fractionalDigits = 0
            if cursor < bytes.count, bytes[cursor] == 0x2E {
                cursor += 1
                while cursor < bytes.count,
                      (0x30...0x39).contains(bytes[cursor]) {
                    fractionalDigits += 1
                    cursor += 1
                }
            }
            guard wholeDigits > 0 || fractionalDigits > 0 else {
                return false
            }
            if cursor < bytes.count,
               bytes[cursor] == 0x65 || bytes[cursor] == 0x45 {
                cursor += 1
                if cursor < bytes.count,
                   bytes[cursor] == 0x2B || bytes[cursor] == 0x2D {
                    cursor += 1
                }
                let exponentStart = cursor
                while cursor < bytes.count,
                      (0x30...0x39).contains(bytes[cursor]) {
                    cursor += 1
                }
                guard cursor > exponentStart else { return false }
            }
            return cursor == bytes.count
        }

        func decimal(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard (0x30...0x39).contains(bytes[index]) else {
                    return nil
                }
                value = value * 10 + Int(bytes[index] - 0x30)
            }
            return value
        }

        func trimASCIIWhitespace(_ value: String) -> String {
            let bytes = Array(value.utf8)
            var lower = 0
            var upper = bytes.count
            while lower < upper, isWhitespace(bytes[lower]) {
                lower += 1
            }
            while upper > lower, isWhitespace(bytes[upper - 1]) {
                upper -= 1
            }
            return String(decoding: bytes[lower..<upper], as: UTF8.self)
        }

        mutating func consume(_ literal: [UInt8]) throws {
            guard matches(literal) else {
                throw ForeignPropertyListError.malformedXML(offset: offset)
            }
            offset += literal.count
        }

        mutating func skipWhitespace() {
            while offset < bytes.count, isWhitespace(bytes[offset]) {
                offset += 1
            }
        }

        func matches(_ literal: [UInt8]) -> Bool {
            guard offset <= bytes.count - literal.count else { return false }
            for index in literal.indices
            where bytes[offset + index] != literal[index] {
                return false
            }
            return true
        }

        func matchesPrefix(_ literal: [UInt8]) -> Bool {
            matches(literal)
        }

        func find(_ literal: [UInt8], from start: Int) -> Int? {
            guard !literal.isEmpty,
                  start <= bytes.count - literal.count
            else {
                return nil
            }
            for candidate in start...(bytes.count - literal.count) {
                var matched = true
                for index in literal.indices
                where bytes[candidate + index] != literal[index] {
                    matched = false
                    break
                }
                if matched { return candidate }
            }
            return nil
        }

        func containsByte(_ byte: UInt8, in range: Range<Int>) -> Bool {
            range.contains(where: { bytes[$0] == byte })
        }

        func containsSequence(
            _ sequence: [UInt8],
            in range: Range<Int>
        ) -> Bool {
            guard !sequence.isEmpty, range.count >= sequence.count else {
                return false
            }
            let lastStart = range.upperBound - sequence.count
            for candidate in range.lowerBound...lastStart {
                var matches = true
                for index in sequence.indices
                where bytes[candidate + index] != sequence[index] {
                    matches = false
                    break
                }
                if matches { return true }
            }
            return false
        }

        func equals(_ range: Range<Int>, _ literal: [UInt8]) -> Bool {
            guard range.count == literal.count else { return false }
            for index in literal.indices
            where bytes[range.lowerBound + index] != literal[index] {
                return false
            }
            return true
        }

        func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        func isValidXMLScalar(_ scalar: Unicode.Scalar) -> Bool {
            let value = scalar.value
            return value == 0x09
                || value == 0x0A
                || value == 0x0D
                || (0x20...0xD7FF).contains(value)
                || (0xE000...0xFFFD).contains(value)
                || (0x10000...0x10FFFF).contains(value)
        }
    }
}

private let xmlUTF8BOM = [UInt8]([0xEF, 0xBB, 0xBF])
private let xmlDeclaration = Array(
    #"<?xml version="1.0" encoding="UTF-8"?>"#.utf8
)
private let xmlProcessingInstructionPrefix = Array("<?".utf8)
private let xmlDoctypePrefix = Array("<!DOCTYPE".utf8)
private let xmlDoctype = Array(
    #"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#.utf8
)
private let xmlPlistOpen = Array(#"<plist version="1.0">"#.utf8)
private let xmlPlistClose = Array("</plist>".utf8)
private let xmlArrayOpen = Array("<array>".utf8)
private let xmlArrayClose = Array("</array>".utf8)
private let xmlArrayEmpty = Array("<array/>".utf8)
private let xmlArraySpacedEmpty = Array("<array />".utf8)
private let xmlDictionaryOpen = Array("<dict>".utf8)
private let xmlDictionaryClose = Array("</dict>".utf8)
private let xmlDictionaryEmpty = Array("<dict/>".utf8)
private let xmlDictionarySpacedEmpty = Array("<dict />".utf8)
private let xmlKeyOpen = Array("<key>".utf8)
private let xmlKeyClose = Array("</key>".utf8)
private let xmlKeyEmpty = Array("<key/>".utf8)
private let xmlKeySpacedEmpty = Array("<key />".utf8)
private let xmlStringOpen = Array("<string>".utf8)
private let xmlStringClose = Array("</string>".utf8)
private let xmlStringEmpty = Array("<string/>".utf8)
private let xmlStringSpacedEmpty = Array("<string />".utf8)
private let xmlIntegerOpen = Array("<integer>".utf8)
private let xmlIntegerClose = Array("</integer>".utf8)
private let xmlRealOpen = Array("<real>".utf8)
private let xmlRealClose = Array("</real>".utf8)
private let xmlDateOpen = Array("<date>".utf8)
private let xmlDateClose = Array("</date>".utf8)
private let xmlDataOpen = Array("<data>".utf8)
private let xmlDataClose = Array("</data>".utf8)
private let xmlDataEmpty = Array("<data/>".utf8)
private let xmlDataSpacedEmpty = Array("<data />".utf8)
private let xmlTrueEmpty = Array("<true/>".utf8)
private let xmlTrueSpacedEmpty = Array("<true />".utf8)
private let xmlFalseEmpty = Array("<false/>".utf8)
private let xmlFalseSpacedEmpty = Array("<false />".utf8)
private let xmlTrueOpen = Array("<true>".utf8)
private let xmlTrueClose = Array("</true>".utf8)
private let xmlFalseOpen = Array("<false>".utf8)
private let xmlFalseClose = Array("</false>".utf8)
private let asciiAmp = Array("amp".utf8)
private let asciiApostrophe = Array("apos".utf8)
private let asciiGreaterThan = Array("gt".utf8)
private let asciiLessThan = Array("lt".utf8)
private let asciiQuotationMark = Array("quot".utf8)
private let xmlCDATAEnd = Array("]]>".utf8)
