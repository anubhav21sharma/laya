import Foundation

struct ForeignBinaryPropertyListReader {
    static let signature = Data("bplist00".utf8)

    private let data: Data
    private let limits: ForeignPropertyListLimits
    private let budget: ForeignPropertyListBudget?

    init(
        data: Data,
        limits: ForeignPropertyListLimits,
        budget: ForeignPropertyListBudget? = nil
    ) {
        self.data = data
        self.limits = limits
        self.budget = budget
    }

    func parse() throws -> ForeignPropertyListGraph {
        guard budget?.isCompatible(with: limits) != false else {
            throw ForeignPropertyListError.invalidLimits
        }
        var reservedNodes = 0
        var reservedReferences = 0
        var committedReservations = false
        defer {
            if !committedReservations {
                budget?.refund(
                    nodes: reservedNodes,
                    collectionReferences: reservedReferences
                )
            }
        }
        guard data.count <= limits.maximumInputBytes else {
            throw ForeignPropertyListError.inputTooLarge(
                actual: data.count,
                maximum: limits.maximumInputBytes
            )
        }
        if data.startIndex != 0 {
            return try ForeignBinaryPropertyListReader(
                data: Data(data),
                limits: limits,
                budget: budget
            ).parse()
        }
        guard data.starts(with: Self.signature) else {
            throw ForeignPropertyListError.unsupportedSignature
        }
        guard data.count >= Self.signature.count + 1 + 32 else {
            throw ForeignPropertyListError.malformedBinary(offset: data.count)
        }
        let trailerOffset = data.count - 32
        guard data[trailerOffset..<(trailerOffset + 6)].allSatisfy({
            $0 == 0
        }) else {
            throw ForeignPropertyListError.malformedBinary(
                offset: trailerOffset
            )
        }

        let offsetSize = data[trailerOffset + 6]
        let referenceSize = data[trailerOffset + 7]
        guard (1...8).contains(offsetSize) else {
            throw ForeignPropertyListError.invalidBinaryOffsetSize(offsetSize)
        }
        guard (1...8).contains(referenceSize) else {
            throw ForeignPropertyListError.invalidBinaryReferenceSize(
                referenceSize
            )
        }

        let objectCountValue = try readUInt(
            at: trailerOffset + 8,
            byteCount: 8
        )
        let topObjectValue = try readUInt(
            at: trailerOffset + 16,
            byteCount: 8
        )
        let offsetTableValue = try readUInt(
            at: trailerOffset + 24,
            byteCount: 8
        )
        guard objectCountValue > 0,
              objectCountValue <= UInt64(Int.max),
              topObjectValue < objectCountValue,
              offsetTableValue <= UInt64(Int.max)
        else {
            throw ForeignPropertyListError.malformedBinary(
                offset: trailerOffset
            )
        }
        let objectCount = Int(objectCountValue)
        guard objectCount <= limits.maximumTotalNodes else {
            throw ForeignPropertyListError.nodeLimitExceeded(
                maximum: limits.maximumTotalNodes
            )
        }
        try budget?.reserve(nodes: objectCount, collectionReferences: 0)
        reservedNodes = objectCount
        guard referenceSize == 8
                || objectCountValue - 1
                    <= ((UInt64(1) << (UInt64(referenceSize) * 8)) - 1)
        else {
            throw ForeignPropertyListError.invalidBinaryReferenceSize(
                referenceSize
            )
        }
        guard offsetSize == 8
                || offsetTableValue
                    <= ((UInt64(1) << (UInt64(offsetSize) * 8)) - 1)
        else {
            throw ForeignPropertyListError.invalidBinaryOffsetSize(offsetSize)
        }

        let offsetTableOffset = Int(offsetTableValue)
        guard offsetTableOffset >= Self.signature.count,
              offsetTableOffset <= trailerOffset
        else {
            throw ForeignPropertyListError.malformedBinary(
                offset: trailerOffset + 24
            )
        }
        let tableByteCount = try checkedMultiply(
            objectCount,
            Int(offsetSize),
            offset: offsetTableOffset
        )
        let tableEnd = try checkedAdd(
            offsetTableOffset,
            tableByteCount,
            offset: offsetTableOffset
        )
        guard tableEnd == trailerOffset else {
            throw ForeignPropertyListError.malformedBinary(
                offset: offsetTableOffset
            )
        }

        var objectOffsets = [Int]()
        objectOffsets.reserveCapacity(objectCount)
        var seenOffsets = Set<Int>()
        for index in 0..<objectCount {
            let entryOffset = try checkedAdd(
                offsetTableOffset,
                try checkedMultiply(
                    index,
                    Int(offsetSize),
                    offset: offsetTableOffset
                ),
                offset: offsetTableOffset
            )
            let value = try readUInt(
                at: entryOffset,
                byteCount: Int(offsetSize)
            )
            guard value <= UInt64(Int.max) else {
                throw ForeignPropertyListError.malformedBinary(
                    offset: entryOffset
                )
            }
            let objectOffset = Int(value)
            guard objectOffset >= Self.signature.count,
                  objectOffset < offsetTableOffset
            else {
                throw ForeignPropertyListError.malformedBinary(
                    offset: entryOffset
                )
            }
            guard seenOffsets.insert(objectOffset).inserted else {
                throw ForeignPropertyListError.duplicateBinaryObjectOffset
            }
            objectOffsets.append(objectOffset)
        }

        var ranges = [Range<Int>]()
        ranges.reserveCapacity(objectCount)
        var totalReferences = 0
        for (object, offset) in objectOffsets.enumerated() {
            let layout = try preflightObject(
                object: object,
                offset: offset,
                referenceSize: Int(referenceSize),
                objectTableEnd: offsetTableOffset
            )
            ranges.append(layout.range)
            let nextReferences = try checkedAdd(
                totalReferences,
                layout.referenceCount,
                offset: offset
            )
            guard nextReferences
                    <= limits.maximumTotalCollectionReferences
            else {
                throw ForeignPropertyListError
                    .collectionReferenceLimitExceeded(
                        maximum: limits.maximumTotalCollectionReferences
                    )
            }
            try budget?.reserve(
                nodes: 0,
                collectionReferences: layout.referenceCount
            )
            reservedReferences = nextReferences
            totalReferences = nextReferences
        }

        let sortedRanges = ranges.sorted {
            $0.lowerBound < $1.lowerBound
        }
        for index in sortedRanges.indices.dropFirst()
        where sortedRanges[index - 1].upperBound
            > sortedRanges[index].lowerBound {
            throw ForeignPropertyListError.overlappingBinaryObjects
        }
        var claimedEnd = Self.signature.count
        for range in sortedRanges {
            try validateFiller(in: claimedEnd..<range.lowerBound)
            claimedEnd = range.upperBound
        }
        try validateFiller(in: claimedEnd..<offsetTableOffset)

        var nodes = [ForeignPropertyListNode]()
        nodes.reserveCapacity(objectCount)
        for (object, offset) in objectOffsets.enumerated() {
            let parsed = try parseObject(
                object: object,
                offset: offset,
                referenceSize: Int(referenceSize),
                objectCount: objectCount,
                objectTableEnd: offsetTableOffset
            )
            nodes.append(parsed.node)
        }
        let graph = ForeignPropertyListGraph(
            root: ForeignPropertyListObjectID(rawValue: Int(topObjectValue)),
            nodes: nodes
        )
        try ForeignPropertyListGraphValidator.validate(
            graph,
            limits: limits
        )
        committedReservations = true
        return graph
    }

    private func preflightObject(
        object: Int,
        offset: Int,
        referenceSize: Int,
        objectTableEnd: Int
    ) throws -> (range: Range<Int>, referenceCount: Int) {
        let marker = data[offset]
        let kind = marker >> 4
        let info = marker & 0x0F
        let end: Int
        let referenceCount: Int
        switch kind {
        case 0x0:
            guard marker == 0x08 || marker == 0x09 else {
                throw ForeignPropertyListError.unsupportedBinaryObject(
                    marker: marker,
                    object: object
                )
            }
            end = offset + 1
            referenceCount = 0
        case 0x1:
            let byteCount = try fixedWidth(
                info,
                object: object,
                marker: marker
            )
            guard [1, 2, 4, 8].contains(byteCount) else {
                throw ForeignPropertyListError.integerOutOfRange(
                    object: object
                )
            }
            end = try checkedEnd(
                offset + 1,
                count: byteCount,
                limit: objectTableEnd
            )
            referenceCount = 0
        case 0x2:
            let byteCount = try fixedWidth(
                info,
                object: object,
                marker: marker
            )
            guard byteCount == 4 || byteCount == 8 else {
                throw ForeignPropertyListError.unsupportedBinaryObject(
                    marker: marker,
                    object: object
                )
            }
            end = try checkedEnd(
                offset + 1,
                count: byteCount,
                limit: objectTableEnd
            )
            referenceCount = 0
        case 0x3:
            guard info == 0x3 else {
                throw ForeignPropertyListError.unsupportedBinaryObject(
                    marker: marker,
                    object: object
                )
            }
            end = try checkedEnd(
                offset + 1,
                count: 8,
                limit: objectTableEnd
            )
            referenceCount = 0
        case 0x4:
            let length = try variableLength(
                info,
                after: offset,
                object: object,
                objectTableEnd: objectTableEnd
            )
            guard length.count <= limits.maximumOpaqueDataBytes else {
                throw ForeignPropertyListError.dataLimitExceeded(
                    maximumBytes: limits.maximumOpaqueDataBytes
                )
            }
            end = try checkedEnd(
                length.payloadOffset,
                count: length.count,
                limit: objectTableEnd
            )
            referenceCount = 0
        case 0x5, 0x6:
            let length = try variableLength(
                info,
                after: offset,
                object: object,
                objectTableEnd: objectTableEnd
            )
            let byteCount = kind == 0x6
                ? try checkedMultiply(
                    length.count,
                    2,
                    offset: length.payloadOffset
                )
                : length.count
            let maximumEncodedBytes = kind == 0x6
                ? try checkedMultiply(
                    limits.maximumStringUTF8Bytes,
                    2,
                    offset: length.payloadOffset
                )
                : limits.maximumStringUTF8Bytes
            guard byteCount <= maximumEncodedBytes else {
                throw ForeignPropertyListError.stringLimitExceeded(
                    maximumUTF8Bytes: limits.maximumStringUTF8Bytes
                )
            }
            end = try checkedEnd(
                length.payloadOffset,
                count: byteCount,
                limit: objectTableEnd
            )
            referenceCount = 0
        case 0x8:
            let byteCount = Int(info) + 1
            guard byteCount <= 8 else {
                throw ForeignPropertyListError.unsupportedBinaryObject(
                    marker: marker,
                    object: object
                )
            }
            end = try checkedEnd(
                offset + 1,
                count: byteCount,
                limit: objectTableEnd
            )
            referenceCount = 0
        case 0xA, 0xD:
            let length = try variableLength(
                info,
                after: offset,
                object: object,
                objectTableEnd: objectTableEnd
            )
            guard length.count <= limits.maximumCollectionElements else {
                throw ForeignPropertyListError.collectionLimitExceeded(
                    maximum: limits.maximumCollectionElements
                )
            }
            referenceCount = kind == 0xD
                ? try checkedMultiply(
                    length.count,
                    2,
                    offset: length.payloadOffset
                )
                : length.count
            let byteCount = try checkedMultiply(
                referenceCount,
                referenceSize,
                offset: length.payloadOffset
            )
            end = try checkedEnd(
                length.payloadOffset,
                count: byteCount,
                limit: objectTableEnd
            )
        default:
            throw ForeignPropertyListError.unsupportedBinaryObject(
                marker: marker,
                object: object
            )
        }
        return (offset..<end, referenceCount)
    }

    private func parseObject(
        object: Int,
        offset: Int,
        referenceSize: Int,
        objectCount: Int,
        objectTableEnd: Int
    ) throws -> (node: ForeignPropertyListNode, range: Range<Int>) {
        let marker = data[offset]
        let kind = marker >> 4
        let info = marker & 0x0F
        switch kind {
        case 0x0:
            switch marker {
            case 0x08:
                return (.boolean(false), offset..<(offset + 1))
            case 0x09:
                return (.boolean(true), offset..<(offset + 1))
            default:
                throw ForeignPropertyListError.unsupportedBinaryObject(
                    marker: marker,
                    object: object
                )
            }
        case 0x1:
            let byteCount = try fixedWidth(
                info,
                object: object,
                marker: marker
            )
            guard [1, 2, 4, 8].contains(byteCount) else {
                throw ForeignPropertyListError.integerOutOfRange(
                    object: object
                )
            }
            let end = try checkedEnd(
                offset + 1,
                count: byteCount,
                limit: objectTableEnd
            )
            let unsigned = try readUInt(at: offset + 1, byteCount: byteCount)
            let value = byteCount == 8
                ? Int64(bitPattern: unsigned)
                : Int64(unsigned)
            return (
                .integer(value),
                offset..<end
            )
        case 0x2:
            let byteCount = try fixedWidth(
                info,
                object: object,
                marker: marker
            )
            let end = try checkedEnd(
                offset + 1,
                count: byteCount,
                limit: objectTableEnd
            )
            let value: Double
            switch byteCount {
            case 4:
                value = Double(
                    Float(
                        bitPattern: UInt32(
                            try readUInt(at: offset + 1, byteCount: 4)
                        )
                    )
                )
            case 8:
                value = Double(
                    bitPattern: try readUInt(at: offset + 1, byteCount: 8)
                )
            default:
                throw ForeignPropertyListError.unsupportedBinaryObject(
                    marker: marker,
                    object: object
                )
            }
            guard value.isFinite else {
                throw ForeignPropertyListError.nonFiniteNumber(object: object)
            }
            return (.real(value == 0 ? 0 : value), offset..<end)
        case 0x3:
            guard info == 0x3 else {
                throw ForeignPropertyListError.unsupportedBinaryObject(
                    marker: marker,
                    object: object
                )
            }
            let end = try checkedEnd(
                offset + 1,
                count: 8,
                limit: objectTableEnd
            )
            let seconds = Double(
                bitPattern: try readUInt(at: offset + 1, byteCount: 8)
            )
            guard seconds.isFinite else {
                throw ForeignPropertyListError.nonFiniteNumber(object: object)
            }
            return (
                .date(Date(timeIntervalSinceReferenceDate: seconds)),
                offset..<end
            )
        case 0x4:
            let length = try variableLength(
                info,
                after: offset,
                object: object,
                objectTableEnd: objectTableEnd
            )
            guard length.count <= limits.maximumOpaqueDataBytes else {
                throw ForeignPropertyListError.dataLimitExceeded(
                    maximumBytes: limits.maximumOpaqueDataBytes
                )
            }
            let end = try checkedEnd(
                length.payloadOffset,
                count: length.count,
                limit: objectTableEnd
            )
            return (
                .data(data.subdata(in: length.payloadOffset..<end)),
                offset..<end
            )
        case 0x5, 0x6:
            let length = try variableLength(
                info,
                after: offset,
                object: object,
                objectTableEnd: objectTableEnd
            )
            let byteCount: Int
            if kind == 0x6 {
                byteCount = try checkedMultiply(
                    length.count,
                    2,
                    offset: length.payloadOffset
                )
            } else {
                byteCount = length.count
            }
            let maximumEncodedBytes = kind == 0x6
                ? try checkedMultiply(
                    limits.maximumStringUTF8Bytes,
                    2,
                    offset: length.payloadOffset
                )
                : limits.maximumStringUTF8Bytes
            guard byteCount <= maximumEncodedBytes else {
                throw ForeignPropertyListError.stringLimitExceeded(
                    maximumUTF8Bytes: limits.maximumStringUTF8Bytes
                )
            }
            let end = try checkedEnd(
                length.payloadOffset,
                count: byteCount,
                limit: objectTableEnd
            )
            let bytes = data.subdata(in: length.payloadOffset..<end)
            let value: String?
            switch kind {
            case 0x5:
                value = bytes.allSatisfy({ $0 < 0x80 })
                    ? String(data: bytes, encoding: .ascii)
                    : nil
            case 0x6:
                value = String(data: bytes, encoding: .utf16BigEndian)
            default:
                value = nil
            }
            guard let value else {
                throw ForeignPropertyListError.invalidScalar(
                    kind: .string,
                    offset: length.payloadOffset
                )
            }
            guard value.utf8.count <= limits.maximumStringUTF8Bytes else {
                throw ForeignPropertyListError.stringLimitExceeded(
                    maximumUTF8Bytes: limits.maximumStringUTF8Bytes
                )
            }
            return (.string(value), offset..<end)
        case 0x8:
            let byteCount = Int(info) + 1
            guard byteCount <= 8 else {
                throw ForeignPropertyListError.unsupportedBinaryObject(
                    marker: marker,
                    object: object
                )
            }
            let end = try checkedEnd(
                offset + 1,
                count: byteCount,
                limit: objectTableEnd
            )
            return (
                .uid(try readUInt(at: offset + 1, byteCount: byteCount)),
                offset..<end
            )
        case 0xA:
            let length = try variableLength(
                info,
                after: offset,
                object: object,
                objectTableEnd: objectTableEnd
            )
            guard length.count <= limits.maximumCollectionElements else {
                throw ForeignPropertyListError.collectionLimitExceeded(
                    maximum: limits.maximumCollectionElements
                )
            }
            let byteCount = try checkedMultiply(
                length.count,
                referenceSize,
                offset: length.payloadOffset
            )
            let end = try checkedEnd(
                length.payloadOffset,
                count: byteCount,
                limit: objectTableEnd
            )
            let values = try readReferences(
                at: length.payloadOffset,
                count: length.count,
                referenceSize: referenceSize,
                objectCount: objectCount
            )
            return (.array(values), offset..<end)
        case 0xD:
            let length = try variableLength(
                info,
                after: offset,
                object: object,
                objectTableEnd: objectTableEnd
            )
            guard length.count <= limits.maximumCollectionElements else {
                throw ForeignPropertyListError.collectionLimitExceeded(
                    maximum: limits.maximumCollectionElements
                )
            }
            let referenceCount = try checkedMultiply(
                length.count,
                2,
                offset: length.payloadOffset
            )
            let byteCount = try checkedMultiply(
                referenceCount,
                referenceSize,
                offset: length.payloadOffset
            )
            let end = try checkedEnd(
                length.payloadOffset,
                count: byteCount,
                limit: objectTableEnd
            )
            let keys = try readReferences(
                at: length.payloadOffset,
                count: length.count,
                referenceSize: referenceSize,
                objectCount: objectCount
            )
            let valueOffset = try checkedAdd(
                length.payloadOffset,
                try checkedMultiply(
                    length.count,
                    referenceSize,
                    offset: length.payloadOffset
                ),
                offset: length.payloadOffset
            )
            let values = try readReferences(
                at: valueOffset,
                count: length.count,
                referenceSize: referenceSize,
                objectCount: objectCount
            )
            let entries = zip(keys, values).map {
                ForeignPropertyListDictionaryEntry(key: $0, value: $1)
            }
            return (.dictionary(entries), offset..<end)
        default:
            throw ForeignPropertyListError.unsupportedBinaryObject(
                marker: marker,
                object: object
            )
        }
    }

    private func fixedWidth(
        _ info: UInt8,
        object: Int,
        marker: UInt8
    ) throws -> Int {
        guard info <= 4 else {
            throw ForeignPropertyListError.unsupportedBinaryObject(
                marker: marker,
                object: object
            )
        }
        return 1 << Int(info)
    }

    private func variableLength(
        _ info: UInt8,
        after objectOffset: Int,
        object: Int,
        objectTableEnd: Int
    ) throws -> (count: Int, payloadOffset: Int) {
        if info < 0xF {
            return (Int(info), objectOffset + 1)
        }
        let lengthMarkerOffset = objectOffset + 1
        guard lengthMarkerOffset < objectTableEnd else {
            throw ForeignPropertyListError.malformedBinary(
                offset: lengthMarkerOffset
            )
        }
        let marker = data[lengthMarkerOffset]
        guard marker >> 4 == 0x1 else {
            throw ForeignPropertyListError.malformedBinary(
                offset: lengthMarkerOffset
            )
        }
        let byteCount = try fixedWidth(
            marker & 0x0F,
            object: object,
            marker: marker
        )
        guard byteCount <= 8 else {
            throw ForeignPropertyListError.malformedBinary(
                offset: lengthMarkerOffset
            )
        }
        let valueOffset = lengthMarkerOffset + 1
        _ = try checkedEnd(
            valueOffset,
            count: byteCount,
            limit: objectTableEnd
        )
        guard byteCount < 8 || data[valueOffset] & 0x80 == 0 else {
            throw ForeignPropertyListError.malformedBinary(offset: valueOffset)
        }
        let count = try readUInt(at: valueOffset, byteCount: byteCount)
        guard count <= UInt64(Int.max) else {
            throw ForeignPropertyListError.malformedBinary(offset: valueOffset)
        }
        return (
            Int(count),
            try checkedEnd(
                valueOffset,
                count: byteCount,
                limit: objectTableEnd
            )
        )
    }

    private func readReferences(
        at offset: Int,
        count: Int,
        referenceSize: Int,
        objectCount: Int
    ) throws -> [ForeignPropertyListObjectID] {
        var result = [ForeignPropertyListObjectID]()
        result.reserveCapacity(count)
        for index in 0..<count {
            let referenceOffset = try checkedAdd(
                offset,
                try checkedMultiply(index, referenceSize, offset: offset),
                offset: offset
            )
            let value = try readUInt(
                at: referenceOffset,
                byteCount: referenceSize
            )
            guard value < UInt64(objectCount) else {
                throw ForeignPropertyListError.invalidBinaryReference
            }
            result.append(
                ForeignPropertyListObjectID(rawValue: Int(value))
            )
        }
        return result
    }

    private func readUInt(at offset: Int, byteCount: Int) throws -> UInt64 {
        let end = try checkedEnd(offset, count: byteCount, limit: data.count)
        var value: UInt64 = 0
        for byte in data[offset..<end] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private func validateFiller(in range: Range<Int>) throws {
        for index in range where data[index] != 0x0F {
            throw ForeignPropertyListError.malformedBinary(offset: index)
        }
    }

    private func checkedEnd(
        _ start: Int,
        count: Int,
        limit: Int
    ) throws -> Int {
        let end = try checkedAdd(start, count, offset: start)
        guard start >= 0, count >= 0, end <= limit else {
            throw ForeignPropertyListError.malformedBinary(offset: start)
        }
        return end
    }

    private func checkedAdd(
        _ lhs: Int,
        _ rhs: Int,
        offset: Int
    ) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw ForeignPropertyListError.malformedBinary(offset: offset)
        }
        return value
    }

    private func checkedMultiply(
        _ lhs: Int,
        _ rhs: Int,
        offset: Int
    ) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw ForeignPropertyListError.malformedBinary(offset: offset)
        }
        return value
    }
}

enum ForeignPropertyListGraphValidator {
    static func validate(
        _ graph: ForeignPropertyListGraph,
        limits: ForeignPropertyListLimits
    ) throws {
        guard graph.nodes.count <= limits.maximumTotalNodes else {
            throw ForeignPropertyListError.nodeLimitExceeded(
                maximum: limits.maximumTotalNodes
            )
        }
        guard graph.nodes.indices.contains(graph.root.rawValue) else {
            throw ForeignPropertyListError.invalidReference(
                object: graph.root.rawValue
            )
        }

        var references = 0
        for (index, node) in graph.nodes.enumerated() {
            switch node {
            case let .dictionary(entries):
                guard entries.count <= limits.maximumCollectionElements else {
                    throw ForeignPropertyListError.collectionLimitExceeded(
                        maximum: limits.maximumCollectionElements
                    )
                }
                var keys = Set<String>()
                for entry in entries {
                    guard graph.nodes.indices.contains(entry.key.rawValue),
                          graph.nodes.indices.contains(entry.value.rawValue)
                    else {
                        throw ForeignPropertyListError.invalidReference(
                            object: index
                        )
                    }
                    guard case let .string(key) =
                            graph.nodes[entry.key.rawValue]
                    else {
                        throw ForeignPropertyListError
                            .dictionaryKeyIsNotString(object: index)
                    }
                    guard keys.insert(key).inserted else {
                        throw ForeignPropertyListError.duplicateDictionaryKey(
                            object: index
                        )
                    }
                }
            case let .array(values):
                guard values.count <= limits.maximumCollectionElements else {
                    throw ForeignPropertyListError.collectionLimitExceeded(
                        maximum: limits.maximumCollectionElements
                    )
                }
                guard values.allSatisfy({
                    graph.nodes.indices.contains($0.rawValue)
                }) else {
                    throw ForeignPropertyListError.invalidReference(
                        object: index
                    )
                }
            case let .real(value):
                guard value.isFinite else {
                    throw ForeignPropertyListError.nonFiniteNumber(object: index)
                }
            case let .date(value):
                guard value.timeIntervalSinceReferenceDate.isFinite else {
                    throw ForeignPropertyListError.nonFiniteNumber(object: index)
                }
            case let .string(value):
                guard value.utf8.count <= limits.maximumStringUTF8Bytes else {
                    throw ForeignPropertyListError.stringLimitExceeded(
                        maximumUTF8Bytes: limits.maximumStringUTF8Bytes
                    )
                }
            case let .data(value):
                guard value.count <= limits.maximumOpaqueDataBytes else {
                    throw ForeignPropertyListError.dataLimitExceeded(
                        maximumBytes: limits.maximumOpaqueDataBytes
                    )
                }
            default:
                break
            }
            let (nextReferences, overflow) = references
                .addingReportingOverflow(node.referencedObjectIDs.count)
            guard !overflow,
                  nextReferences
                    <= limits.maximumTotalCollectionReferences
            else {
                throw ForeignPropertyListError
                    .collectionReferenceLimitExceeded(
                        maximum: limits.maximumTotalCollectionReferences
                    )
            }
            references = nextReferences
        }

        var colors = Array(repeating: UInt8(0), count: graph.nodes.count)
        var longestDepth = Array(repeating: 1, count: graph.nodes.count)
        for start in graph.nodes.indices where colors[start] == 0 {
            var stack: [(Int, Bool)] = [(start, false)]
            while let (index, leaving) = stack.popLast() {
                if leaving {
                    let childDepth = graph.nodes[index].referencedObjectIDs.map {
                        longestDepth[$0.rawValue]
                    }.max() ?? 0
                    let (depth, overflow) = childDepth.addingReportingOverflow(1)
                    guard !overflow, depth <= limits.maximumGraphDepth else {
                        throw ForeignPropertyListError.graphDepthExceeded(
                            maximum: limits.maximumGraphDepth
                        )
                    }
                    longestDepth[index] = depth
                    colors[index] = 2
                    continue
                }
                if colors[index] == 1 {
                    throw ForeignPropertyListError.graphCycle(object: index)
                }
                if colors[index] == 2 { continue }
                colors[index] = 1
                stack.append((index, true))
                for child in graph.nodes[index].referencedObjectIDs.reversed() {
                    if colors[child.rawValue] == 1 {
                        throw ForeignPropertyListError.graphCycle(
                            object: child.rawValue
                        )
                    }
                    if colors[child.rawValue] == 0 {
                        stack.append((child.rawValue, false))
                    }
                }
            }
        }
    }
}
