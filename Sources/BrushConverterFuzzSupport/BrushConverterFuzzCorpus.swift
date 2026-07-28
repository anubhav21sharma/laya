import Foundation

public struct BrushConverterFuzzCorpus: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let identifier: String
        public let data: Data

        public init(identifier: String, data: Data) {
            self.identifier = identifier
            self.data = data
        }
    }

    public let schemaVersion: UInt16
    public let ownership: String
    public let entries: [Entry]

    public static func loadBundled() throws -> Self {
        guard let url = Bundle.module.url(
            forResource: "seed-corpus-v1",
            withExtension: "json",
            subdirectory: "Corpus"
        ) else {
            throw BrushConverterFuzzError.missingBundledCorpus
        }
        let stored: StoredCorpus
        do {
            stored = try JSONDecoder().decode(
                StoredCorpus.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw BrushConverterFuzzError.invalidBundledCorpus
        }
        guard stored.schemaVersion == 1,
              stored.ownership == "project-owned",
              !stored.entries.isEmpty,
              stored.entries.count <= 128
        else {
            throw BrushConverterFuzzError.invalidBundledCorpus
        }

        var identifiers = Set<String>()
        let entries = try stored.entries.map { storedEntry in
            guard Self.isValidIdentifier(storedEntry.identifier),
                  identifiers.insert(storedEntry.identifier).inserted,
                  let data = Data(base64Encoded: storedEntry.base64),
                  data.count <=
                  BrushConverterFuzzHarness.maximumGeneratedInputBytes
            else {
                throw BrushConverterFuzzError.invalidBundledCorpus
            }
            return Entry(identifier: storedEntry.identifier, data: data)
        }.sorted { $0.identifier < $1.identifier }

        return Self(
            schemaVersion: stored.schemaVersion,
            ownership: stored.ownership,
            entries: entries
        )
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            ("a" ... "z").contains(Character($0))
                || ("0" ... "9").contains(Character($0))
                || $0 == "-"
        }
    }
}

private struct StoredCorpus: Decodable {
    struct Entry: Decodable {
        let identifier: String
        let base64: String
    }

    let schemaVersion: UInt16
    let ownership: String
    let entries: [Entry]
}
