import Foundation

struct ForeignPropertyListObjectID:
    RawRepresentable,
    Hashable,
    Equatable,
    Sendable
{
    let rawValue: Int
}

struct ForeignPropertyListDictionaryEntry: Equatable, Sendable {
    let key: ForeignPropertyListObjectID
    let value: ForeignPropertyListObjectID
}

enum ForeignPropertyListNode: Equatable, Sendable {
    case dictionary([ForeignPropertyListDictionaryEntry])
    case array([ForeignPropertyListObjectID])
    case boolean(Bool)
    case integer(Int64)
    case real(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case uid(UInt64)

    var referencedObjectIDs: [ForeignPropertyListObjectID] {
        switch self {
        case let .dictionary(entries):
            return entries.flatMap { [$0.key, $0.value] }
        case let .array(values):
            return values
        default:
            return []
        }
    }
}

struct ForeignPropertyListGraph: Equatable, Sendable {
    let root: ForeignPropertyListObjectID
    let nodes: [ForeignPropertyListNode]

    func node(
        at identifier: ForeignPropertyListObjectID
    ) throws -> ForeignPropertyListNode {
        guard nodes.indices.contains(identifier.rawValue) else {
            throw ForeignPropertyListError.invalidReference(
                object: identifier.rawValue
            )
        }
        return nodes[identifier.rawValue]
    }
}

enum ForeignPropertyListScalarKind: UInt8, Equatable, Sendable {
    case integer
    case real
    case date
    case string
    case data
}

enum ForeignPropertyListError: Error, Equatable, Sendable {
    case invalidLimits
    case inputTooLarge(actual: Int, maximum: Int)
    case unsupportedSignature
    case malformedXML(offset: Int)
    case malformedBinary(offset: Int)
    case unsupportedXMLConstruct(offset: Int)
    case invalidScalar(kind: ForeignPropertyListScalarKind, offset: Int)
    case invalidDate(offset: Int)
    case invalidBase64(offset: Int)
    case unsupportedBinaryObject(marker: UInt8, object: Int)
    case invalidBinaryOffsetSize(UInt8)
    case invalidBinaryReferenceSize(UInt8)
    case duplicateBinaryObjectOffset
    case overlappingBinaryObjects
    case invalidBinaryReference
    case invalidReference(object: Int)
    case duplicateDictionaryKey(object: Int)
    case duplicateXMLDictionaryKey(offset: Int)
    case dictionaryKeyIsNotString(object: Int)
    case graphCycle(object: Int)
    case graphDepthExceeded(maximum: Int)
    case collectionLimitExceeded(maximum: Int)
    case nodeLimitExceeded(maximum: Int)
    case stringLimitExceeded(maximumUTF8Bytes: Int)
    case dataLimitExceeded(maximumBytes: Int)
    case XMLTextLimitExceeded(maximumUTF8Bytes: Int)
    case collectionReferenceLimitExceeded(maximum: Int)
    case resolvedUIDReferenceLimitExceeded(maximum: Int)
    case integerOutOfRange(object: Int)
    case nonFiniteNumber(object: Int)
    case notKeyedArchive
    case invalidKeyedArchive
    case invalidUIDReference(UInt64)
}

struct BoundedKeyedArchiveView: Equatable, Sendable {
    let graph: ForeignPropertyListGraph
    let objects: [ForeignPropertyListObjectID]
    let top: [ForeignPropertyListDictionaryEntry]

    init(
        graph: ForeignPropertyListGraph,
        limits: ForeignPropertyListLimits = .standard,
        budget: ForeignPropertyListBudget? = nil
    ) throws {
        guard budget?.isCompatible(with: limits) != false else {
            throw ForeignPropertyListError.invalidLimits
        }
        var reservedUIDReferences = 0
        var committedUIDReservation = false
        defer {
            if !committedUIDReservation {
                budget?.refund(
                    resolvedUIDReferences: reservedUIDReferences
                )
            }
        }
        try ForeignPropertyListGraphValidator.validate(
            graph,
            limits: limits
        )
        guard case let .dictionary(rootEntries) =
                try graph.node(at: graph.root)
        else {
            throw ForeignPropertyListError.notKeyedArchive
        }

        let rootFields = try Self.dictionaryFields(
            rootEntries,
            graph: graph,
            dictionary: graph.root.rawValue
        )
        guard let archiverID = rootFields["$archiver"],
              try graph.node(at: archiverID) == .string("NSKeyedArchiver"),
              let versionID = rootFields["$version"],
              try graph.node(at: versionID) == .integer(100_000),
              let objectsID = rootFields["$objects"],
              case let .array(objects) = try graph.node(at: objectsID),
              let topID = rootFields["$top"],
              case let .dictionary(top) = try graph.node(at: topID)
        else {
            throw ForeignPropertyListError.notKeyedArchive
        }
        guard let firstObject = objects.first,
              try graph.node(at: firstObject) == .string("$null")
        else {
            throw ForeignPropertyListError.invalidKeyedArchive
        }
        for entry in top {
            guard case .string = try graph.node(at: entry.key),
                  case .uid = try graph.node(at: entry.value)
            else {
                throw ForeignPropertyListError.invalidKeyedArchive
            }
        }

        for node in graph.nodes {
            guard case let .uid(identifier) = node else { continue }
            guard identifier < UInt64(objects.count) else {
                throw ForeignPropertyListError.invalidUIDReference(identifier)
            }
        }
        var resolvedUIDReferences = 0
        for node in graph.nodes {
            for child in node.referencedObjectIDs {
                guard graph.nodes.indices.contains(child.rawValue) else {
                    throw ForeignPropertyListError.invalidReference(
                        object: child.rawValue
                    )
                }
                guard case .uid = graph.nodes[child.rawValue] else { continue }
                resolvedUIDReferences += 1
                guard resolvedUIDReferences
                        <= limits.maximumTotalResolvedUIDReferences
                else {
                    throw ForeignPropertyListError
                        .resolvedUIDReferenceLimitExceeded(
                            maximum:
                                limits.maximumTotalResolvedUIDReferences
                        )
                }
            }
        }
        try budget?.reserve(
            resolvedUIDReferences: resolvedUIDReferences
        )
        reservedUIDReferences = resolvedUIDReferences

        try Self.validateResolvedGraph(
            graph,
            objects: objects,
            limits: limits
        )
        committedUIDReservation = true
        self.graph = graph
        self.objects = objects
        self.top = top
    }

    func object(
        referencedBy identifier: ForeignPropertyListObjectID
    ) throws -> ForeignPropertyListObjectID {
        guard case let .uid(value) = try graph.node(at: identifier),
              value < UInt64(objects.count)
        else {
            if case let .uid(value) = try graph.node(at: identifier) {
                throw ForeignPropertyListError.invalidUIDReference(value)
            }
            throw ForeignPropertyListError.invalidKeyedArchive
        }
        return objects[Int(value)]
    }

    private static func dictionaryFields(
        _ entries: [ForeignPropertyListDictionaryEntry],
        graph: ForeignPropertyListGraph,
        dictionary: Int
    ) throws -> [String: ForeignPropertyListObjectID] {
        var result: [String: ForeignPropertyListObjectID] = [:]
        for entry in entries {
            guard case let .string(key) = try graph.node(at: entry.key) else {
                throw ForeignPropertyListError.dictionaryKeyIsNotString(
                    object: dictionary
                )
            }
            guard result.updateValue(entry.value, forKey: key) == nil else {
                throw ForeignPropertyListError.duplicateDictionaryKey(
                    object: dictionary
                )
            }
        }
        return result
    }

    private static func validateResolvedGraph(
        _ graph: ForeignPropertyListGraph,
        objects: [ForeignPropertyListObjectID],
        limits: ForeignPropertyListLimits
    ) throws {
        var colors = Array(repeating: UInt8(0), count: graph.nodes.count)
        var longestDepth = Array(repeating: 1, count: graph.nodes.count)

        func children(of index: Int) throws -> [ForeignPropertyListObjectID] {
            let node = graph.nodes[index]
            if case let .uid(identifier) = node {
                guard identifier < UInt64(objects.count) else {
                    throw ForeignPropertyListError.invalidUIDReference(identifier)
                }
                return [objects[Int(identifier)]]
            }
            let children = node.referencedObjectIDs
            guard children.allSatisfy({
                graph.nodes.indices.contains($0.rawValue)
            }) else {
                throw ForeignPropertyListError.invalidReference(object: index)
            }
            return children
        }

        for start in graph.nodes.indices where colors[start] == 0 {
            var stack: [(Int, Bool)] = [(start, false)]
            while let (index, leaving) = stack.popLast() {
                if leaving {
                    let childDepth = try children(of: index).map {
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
                for child in try children(of: index).reversed() {
                    guard colors.indices.contains(child.rawValue) else {
                        throw ForeignPropertyListError.invalidReference(
                            object: child.rawValue
                        )
                    }
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
