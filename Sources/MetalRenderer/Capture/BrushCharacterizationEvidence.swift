import Foundation
import PatternEngine

public enum BrushCharacterizationEvidenceError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(UInt16)
    case invalidSceneName
    case invalidLogicalRecord
    case invalidDimensions
    case malformedDigest(String)
    case duplicateScene(String)
    case recordsNotSorted
    case recordCount(expected: Int, actual: Int)
    case sceneSetMismatch
    case digestMismatch

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Unsupported brush characterization schema version \(version)."
        case .invalidSceneName:
            "Brush characterization scene names must not be empty."
        case .invalidLogicalRecord:
            "Brush characterization logical record is invalid."
        case .invalidDimensions:
            "Brush characterization dimensions must be positive and match BGRA bytes."
        case let .malformedDigest(digest):
            "Brush characterization digest '\(digest)' must be 16 lowercase hexadecimal characters."
        case let .duplicateScene(scene):
            "Brush characterization contains duplicate scene '\(scene)'."
        case .recordsNotSorted:
            "Brush characterization records must be sorted by scene name."
        case let .recordCount(expected, actual):
            "Brush characterization expected \(expected) records, found \(actual)."
        case .sceneSetMismatch:
            "Brush characterization scene names do not match the expected Slice 4 matrix."
        case .digestMismatch:
            "Brush characterization canonical or logical digest does not match the baseline."
        }
    }
}

public struct BrushCharacterizationEvidence: Codable, Equatable, Sendable {
    public static let currentVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let sceneName: String
    public let logical: BrushCharacterizationRecord
    public let canonicalWidth: Int
    public let canonicalHeight: Int
    public let canonicalBGRA8Digest: String
    public let resolvedShapeIdentity: String
    public let resolvedGrainIdentity: String

    private init(
        schemaVersion: UInt16,
        sceneName: String,
        logical: BrushCharacterizationRecord,
        canonicalWidth: Int,
        canonicalHeight: Int,
        canonicalBGRA8Digest: String,
        resolvedShapeIdentity: String,
        resolvedGrainIdentity: String
    ) {
        self.schemaVersion = schemaVersion
        self.sceneName = sceneName
        self.logical = logical
        self.canonicalWidth = canonicalWidth
        self.canonicalHeight = canonicalHeight
        self.canonicalBGRA8Digest = canonicalBGRA8Digest
        self.resolvedShapeIdentity = resolvedShapeIdentity
        self.resolvedGrainIdentity = resolvedGrainIdentity
    }

    public static func validated(
        schemaVersion: UInt16,
        sceneName: String,
        logical: BrushCharacterizationRecord,
        canonicalWidth: Int,
        canonicalHeight: Int,
        canonicalBGRA8Digest: String,
        resolvedShapeIdentity: String,
        resolvedGrainIdentity: String
    ) throws -> Self {
        guard schemaVersion == currentVersion else {
            throw BrushCharacterizationEvidenceError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        guard !sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrushCharacterizationEvidenceError.invalidSceneName
        }
        guard logical.schemaVersion == BrushLogicalBaseline.schemaVersion,
              logical.sampleCount > 0,
              logical.logicalDabCount > 0,
              Self.isDigest(logical.logicalDabDigest)
        else {
            throw BrushCharacterizationEvidenceError.invalidLogicalRecord
        }
        guard canonicalWidth > 0, canonicalHeight > 0 else {
            throw BrushCharacterizationEvidenceError.invalidDimensions
        }
        guard Self.isDigest(canonicalBGRA8Digest) else {
            throw BrushCharacterizationEvidenceError.malformedDigest(
                canonicalBGRA8Digest
            )
        }
        return Self(
            schemaVersion: schemaVersion,
            sceneName: sceneName,
            logical: logical,
            canonicalWidth: canonicalWidth,
            canonicalHeight: canonicalHeight,
            canonicalBGRA8Digest: canonicalBGRA8Digest,
            resolvedShapeIdentity: resolvedShapeIdentity,
            resolvedGrainIdentity: resolvedGrainIdentity
        )
    }

    public static func canonicalBGRA8Digest(
        width: Int,
        height: Int,
        bytes: [UInt8]
    ) -> String {
        precondition(width > 0 && height > 0)
        precondition(bytes.count == width * height * 4)
        var fnv = FNV1a64()
        fnv.append(UInt32(width))
        fnv.append(UInt32(height))
        fnv.append(UInt8(1))
        fnv.append(bytes)
        return fnv.hexDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self.validated(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            sceneName: container.decode(String.self, forKey: .sceneName),
            logical: container.decode(BrushCharacterizationRecord.self, forKey: .logical),
            canonicalWidth: container.decode(Int.self, forKey: .canonicalWidth),
            canonicalHeight: container.decode(Int.self, forKey: .canonicalHeight),
            canonicalBGRA8Digest: container.decode(String.self, forKey: .canonicalBGRA8Digest),
            resolvedShapeIdentity: container.decode(String.self, forKey: .resolvedShapeIdentity),
            resolvedGrainIdentity: container.decode(String.self, forKey: .resolvedGrainIdentity)
        )
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 16 && value.unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character(String($0)))
                || ("a"..."f").contains(Character(String($0)))
        }
    }
}

public struct BrushCharacterizationBaseline: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let records: [BrushCharacterizationEvidence]

    private init(schemaVersion: UInt16, records: [BrushCharacterizationEvidence]) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    public static func validated(
        schemaVersion: UInt16,
        records: [BrushCharacterizationEvidence]
    ) throws -> Self {
        guard schemaVersion == BrushCharacterizationEvidence.currentVersion,
              records.allSatisfy({ $0.schemaVersion == schemaVersion })
        else {
            throw BrushCharacterizationEvidenceError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        guard records == records.sorted(by: { $0.sceneName < $1.sceneName }) else {
            throw BrushCharacterizationEvidenceError.recordsNotSorted
        }
        for pair in zip(records, records.dropFirst()) where pair.0.sceneName == pair.1.sceneName {
            throw BrushCharacterizationEvidenceError.duplicateScene(pair.0.sceneName)
        }
        return Self(schemaVersion: schemaVersion, records: records)
    }

    public static func merge(
        inputRoot: URL,
        expectedSceneNames: [String] = DepositionEvidenceValidator.sceneNames
    ) throws -> Self {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: inputRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var records: [BrushCharacterizationEvidence] = []
        for case let url as URL in enumerator
        where url.lastPathComponent.hasSuffix(".brush-characterization.json") {
            records.append(try JSONDecoder().decode(
                BrushCharacterizationEvidence.self,
                from: Data(contentsOf: url)
            ))
        }
        let baseline = try validated(
            schemaVersion: BrushCharacterizationEvidence.currentVersion,
            records: records.sorted { $0.sceneName < $1.sceneName }
        )
        guard baseline.records.count == expectedSceneNames.count else {
            throw BrushCharacterizationEvidenceError.recordCount(
                expected: expectedSceneNames.count,
                actual: baseline.records.count
            )
        }
        guard baseline.records.map(\.sceneName) == expectedSceneNames.sorted() else {
            throw BrushCharacterizationEvidenceError.sceneSetMismatch
        }
        return baseline
    }

    public func validate(expectedRecordCount: Int) throws {
        guard records.count == expectedRecordCount else {
            throw BrushCharacterizationEvidenceError.recordCount(
                expected: expectedRecordCount,
                actual: records.count
            )
        }
    }

    public func requireMatches(_ actual: [BrushCharacterizationEvidence]) throws {
        guard records.count == actual.count,
              records.map(\.sceneName) == actual.map(\.sceneName)
        else {
            throw BrushCharacterizationEvidenceError.sceneSetMismatch
        }
        guard records == actual else {
            throw BrushCharacterizationEvidenceError.digestMismatch
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self.validated(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            records: container.decode([BrushCharacterizationEvidence].self, forKey: .records)
        )
    }

    public func writeAtomically(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

private struct FNV1a64 {
    private var value: UInt64 = 0xcbf29ce484222325

    mutating func append(_ value: UInt8) {
        self.value ^= UInt64(value)
        self.value &*= 0x100000001b3
    }

    mutating func append(_ value: UInt32) {
        for byte in value.littleEndian.bytes { append(byte) }
    }

    mutating func append(_ values: [UInt8]) {
        for value in values { append(value) }
    }

    var hexDigest: String { String(format: "%016llx", value) }
}

private extension UInt32 {
    var bytes: [UInt8] {
        withUnsafeBytes(of: self) { Array($0) }
    }
}
