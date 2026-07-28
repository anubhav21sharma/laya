import BrushConverter
import Foundation

public enum BrushConverterFuzzError: Error, Equatable, Sendable {
    case missingBundledCorpus
    case invalidBundledCorpus
    case invalidIterationCount(Int)
    case generatedInputTooLarge(Int)
    case nondeterministicObservation(iteration: Int)
    case invalidReplayArtifact
}

extension BrushConverterFuzzError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingBundledCorpus:
            "The bundled converter fuzz corpus is missing."
        case .invalidBundledCorpus:
            "The bundled converter fuzz corpus is invalid."
        case let .invalidIterationCount(count):
            "Invalid converter fuzz iteration count: \(count)."
        case let .generatedInputTooLarge(count):
            "Generated converter fuzz input exceeds its bound: \(count)."
        case let .nondeterministicObservation(iteration):
            "Converter fuzz observation changed on replay at iteration "
                + "\(iteration)."
        case .invalidReplayArtifact:
            "The converter fuzz replay artifact is invalid."
        }
    }
}

public struct BrushConverterFuzzCase: Codable, Equatable, Sendable {
    public let campaignSeed: UInt64
    public let iteration: Int
    public let sourceIdentifier: String
    public let mutation: String
    public let input: Data
}

public enum BrushConverterFuzzCaseEvent: Sendable {
    case willEvaluate(BrushConverterFuzzCase)
    case didEvaluate(BrushConverterFuzzCase)
}

public struct BrushConverterFuzzOperationObservation:
    Codable,
    Equatable,
    Sendable
{
    public enum State: String, Codable, Sendable {
        case matched
        case notMatched
        case accepted
        case ignored
        case rejected
    }

    public let state: State
    public let errorType: String?
    public let documentCount: Int
    public let documentSHA256: String?
}

public struct BrushConverterFuzzParserObservation:
    Codable,
    Equatable,
    Sendable
{
    public let parserIdentifier: String
    public let probe: BrushConverterFuzzOperationObservation
    public let parse: BrushConverterFuzzOperationObservation
}

public struct BrushConverterFuzzObservation:
    Codable,
    Equatable,
    Sendable
{
    public let inputSHA256: String
    public let procreate: BrushConverterFuzzParserObservation
    public let synthetic: BrushConverterFuzzParserObservation
}

public struct BrushConverterFuzzSummary: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let seed: UInt64
    public let iterations: Int
    public let corpusEntryCount: Int
    public let seedInputCount: Int
    public let totalInputBytes: Int
    public let largestInputBytes: Int
    public let acceptedDocumentCount: Int
    public let rejectedParserOperationCount: Int
    public let generatedInputSHA256: String
    public let observationSHA256: String
}

public struct BrushConverterFuzzReplayArtifact:
    Codable,
    Equatable,
    Sendable
{
    public let schemaVersion: UInt16
    public let campaignSeed: UInt64
    public let iteration: Int
    public let sourceIdentifier: String
    public let mutation: String
    public let inputSHA256: String
    public let input: Data

    public init(fuzzCase: BrushConverterFuzzCase) {
        schemaVersion = 1
        campaignSeed = fuzzCase.campaignSeed
        iteration = fuzzCase.iteration
        sourceIdentifier = fuzzCase.sourceIdentifier
        mutation = fuzzCase.mutation
        inputSHA256 = Self.sha256(fuzzCase.input)
        input = fuzzCase.input
    }

    public func encoded() throws -> Data {
        try canonicalJSON(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        let artifact: Self
        do {
            artifact = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw BrushConverterFuzzError.invalidReplayArtifact
        }
        guard artifact.schemaVersion == 1,
              artifact.iteration >= 0,
              !artifact.sourceIdentifier.isEmpty,
              !artifact.mutation.isEmpty,
              artifact.input.count <=
              BrushConverterFuzzHarness.maximumGeneratedInputBytes,
              artifact.inputSHA256 == sha256(artifact.input)
        else {
            throw BrushConverterFuzzError.invalidReplayArtifact
        }
        return artifact
    }

    public static func sha256(_ data: Data) -> String {
        ForeignBrushDocument.contentSHA256(data)
    }
}

public struct BrushConverterFuzzHarness: Sendable {
    public static let maximumGeneratedInputBytes = 1_048_576
    public static let maximumIterations = 1_000_000

    private struct SeedInput: Sendable {
        let identifier: String
        let data: Data
    }

    private struct RecordedObservation: Codable {
        let fuzzCase: BrushConverterFuzzCase
        let observation: BrushConverterFuzzObservation
    }

    private let corpus: BrushConverterFuzzCorpus
    private let seedInputs: [SeedInput]

    public init() throws {
        try self.init(corpus: .loadBundled())
    }

    public init(corpus: BrushConverterFuzzCorpus) throws {
        self.corpus = corpus
        seedInputs = try [
            SeedInput(
                identifier: "synthetic-dry",
                data: SyntheticV1DiagnosticFixture.source(includeWet: false)
            ),
            SeedInput(
                identifier: "synthetic-wet",
                data: SyntheticV1DiagnosticFixture.source(includeWet: true)
            ),
            SeedInput(
                identifier: "procreate-individual",
                data: OwnedProcreateFuzzFixtures.individual()
            ),
            SeedInput(
                identifier: "procreate-legacy-set",
                data: OwnedProcreateFuzzFixtures.legacySet()
            ),
        ] + corpus.entries.map {
            SeedInput(identifier: $0.identifier, data: $0.data)
        }
        guard seedInputs.allSatisfy({
            $0.data.count <= Self.maximumGeneratedInputBytes
        }) else {
            throw BrushConverterFuzzError.invalidBundledCorpus
        }
    }

    public func generateCases(
        seed: UInt64,
        iterations: Int
    ) throws -> [BrushConverterFuzzCase] {
        guard iterations > 0, iterations <= Self.maximumIterations else {
            throw BrushConverterFuzzError.invalidIterationCount(iterations)
        }
        var random = SplitMix64(seed: seed)
        var result = [BrushConverterFuzzCase]()
        result.reserveCapacity(iterations)
        for iteration in 0 ..< iterations {
            let source: SeedInput
            let mutation: Mutation
            if iteration < seedInputs.count {
                source = seedInputs[iteration]
                mutation = .identity
            } else {
                source = seedInputs[
                    random.nextInt(upperBound: seedInputs.count)
                ]
                mutation = Mutation.random(using: &random)
            }
            let input = try mutate(
                source.data,
                mutation: mutation,
                random: &random
            )
            result.append(BrushConverterFuzzCase(
                campaignSeed: seed,
                iteration: iteration,
                sourceIdentifier: source.identifier,
                mutation: mutation.rawValue,
                input: input
            ))
        }
        return result
    }

    public func run(
        seed: UInt64,
        iterations: Int,
        observe: ((BrushConverterFuzzCaseEvent) throws -> Void)? = nil
    ) throws -> BrushConverterFuzzSummary {
        let cases = try generateCases(seed: seed, iterations: iterations)
        var recorded = [RecordedObservation]()
        recorded.reserveCapacity(cases.count)
        var inputDigestBytes = Data()
        var totalInputBytes = 0
        var largestInputBytes = 0
        var acceptedDocumentCount = 0
        var rejectedParserOperationCount = 0

        for fuzzCase in cases {
            try observe?(.willEvaluate(fuzzCase))
            let first = evaluate(fuzzCase.input)
            let second = evaluate(fuzzCase.input)
            guard first == second else {
                throw BrushConverterFuzzError
                    .nondeterministicObservation(
                        iteration: fuzzCase.iteration
                    )
            }
            try observe?(.didEvaluate(fuzzCase))

            appendLengthPrefixed(fuzzCase.input, to: &inputDigestBytes)
            totalInputBytes += fuzzCase.input.count
            largestInputBytes = max(largestInputBytes, fuzzCase.input.count)
            acceptedDocumentCount += first.procreate.parse.documentCount
            acceptedDocumentCount += first.synthetic.parse.documentCount
            rejectedParserOperationCount += [
                first.procreate.probe,
                first.procreate.parse,
                first.synthetic.probe,
                first.synthetic.parse,
            ].filter { $0.state == .rejected }.count
            recorded.append(RecordedObservation(
                fuzzCase: fuzzCase,
                observation: first
            ))
        }

        return BrushConverterFuzzSummary(
            schemaVersion: 1,
            seed: seed,
            iterations: cases.count,
            corpusEntryCount: corpus.entries.count,
            seedInputCount: seedInputs.count,
            totalInputBytes: totalInputBytes,
            largestInputBytes: largestInputBytes,
            acceptedDocumentCount: acceptedDocumentCount,
            rejectedParserOperationCount: rejectedParserOperationCount,
            generatedInputSHA256:
                ForeignBrushDocument.contentSHA256(inputDigestBytes),
            observationSHA256:
                ForeignBrushDocument.contentSHA256(
                    try canonicalJSON(recorded)
                )
        )
    }

    private func evaluate(_ input: Data) -> BrushConverterFuzzObservation {
        BrushConverterFuzzObservation(
            inputSHA256: ForeignBrushDocument.contentSHA256(input),
            procreate: observeParser(
                ProcreateBrushParser(),
                source: input
            ),
            synthetic: observeParser(
                SyntheticV1BrushParser(),
                source: input
            )
        )
    }

    private func observeParser(
        _ parser: any ForeignBrushParser,
        source: Data
    ) -> BrushConverterFuzzParserObservation {
        let probe: BrushConverterFuzzOperationObservation
        do {
            probe = BrushConverterFuzzOperationObservation(
                state: try parser.probe(source) ? .matched : .notMatched,
                errorType: nil,
                documentCount: 0,
                documentSHA256: nil
            )
        } catch {
            probe = rejectedObservation(error)
        }

        let parse: BrushConverterFuzzOperationObservation
        do {
            let documents = try parser.parse(source)
            if documents.isEmpty {
                parse = BrushConverterFuzzOperationObservation(
                    state: .ignored,
                    errorType: nil,
                    documentCount: 0,
                    documentSHA256: nil
                )
            } else {
                parse = BrushConverterFuzzOperationObservation(
                    state: .accepted,
                    errorType: nil,
                    documentCount: documents.count,
                    documentSHA256: try documentDigest(documents)
                )
            }
        } catch {
            parse = rejectedObservation(error)
        }

        return BrushConverterFuzzParserObservation(
            parserIdentifier: parser.identifier,
            probe: probe,
            parse: parse
        )
    }

    private func rejectedObservation(
        _ error: any Error
    ) -> BrushConverterFuzzOperationObservation {
        BrushConverterFuzzOperationObservation(
            state: .rejected,
            errorType: String(reflecting: type(of: error)),
            documentCount: 0,
            documentSHA256: nil
        )
    }

    private func documentDigest(
        _ documents: [ForeignBrushDocument]
    ) throws -> String {
        var data = Data()
        for document in documents {
            appendLengthPrefixed(
                try ForeignBrushCoding.encode(document.ir),
                to: &data
            )
            for identifier in document.resourceData.keys.sorted() {
                appendLengthPrefixed(Data(identifier.utf8), to: &data)
                guard let bytes = document.resourceData[identifier] else {
                    preconditionFailure(
                        "Sorted document resource disappeared."
                    )
                }
                appendLengthPrefixed(bytes, to: &data)
            }
        }
        return ForeignBrushDocument.contentSHA256(data)
    }

    private func mutate(
        _ source: Data,
        mutation: Mutation,
        random: inout SplitMix64
    ) throws -> Data {
        var data = Data(source)
        switch mutation {
        case .identity:
            break
        case .flipBits:
            if data.isEmpty {
                data.append(random.nextByte())
            } else {
                let count = 1 + random.nextInt(
                    upperBound: min(8, data.count)
                )
                for _ in 0 ..< count {
                    let index = random.nextInt(upperBound: data.count)
                    data[index] ^= UInt8(
                        1 << random.nextInt(upperBound: 8)
                    )
                }
            }
        case .truncate:
            data = Data(
                data.prefix(random.nextInt(upperBound: data.count + 1))
            )
        case .deleteSpan:
            if data.isEmpty {
                data.append(random.nextByte())
            } else {
                let start = random.nextInt(upperBound: data.count)
                let maximum = min(64, data.count - start)
                let length = 1 + random.nextInt(upperBound: maximum)
                data.removeSubrange(start ..< (start + length))
            }
        case .insertBytes:
            let index = random.nextInt(upperBound: data.count + 1)
            let count = 1 + random.nextInt(upperBound: 32)
            let inserted = Data((0 ..< count).map { _ in
                random.nextByte()
            })
            data.insert(contentsOf: inserted, at: index)
        case .overwriteSpan:
            if data.isEmpty {
                data.append(random.nextByte())
            } else {
                let start = random.nextInt(upperBound: data.count)
                let count = 1 + random.nextInt(
                    upperBound: min(32, data.count - start)
                )
                for index in start ..< (start + count) {
                    data[index] = random.nextByte()
                }
            }
        case .appendBytes:
            let count = 1 + random.nextInt(upperBound: 64)
            data.append(contentsOf: (0 ..< count).map { _ in
                random.nextByte()
            })
        case .splice:
            let other = seedInputs[
                random.nextInt(upperBound: seedInputs.count)
            ].data
            let prefixCount = random.nextInt(upperBound: data.count + 1)
            let suffixStart = random.nextInt(upperBound: other.count + 1)
            data = Data(data.prefix(prefixCount))
                + Data(other.suffix(from: suffixStart))
        }
        guard data.count <= Self.maximumGeneratedInputBytes else {
            throw BrushConverterFuzzError.generatedInputTooLarge(data.count)
        }
        return data
    }
}

private enum Mutation: String, CaseIterable {
    case identity
    case flipBits = "flip-bits"
    case truncate
    case deleteSpan = "delete-span"
    case insertBytes = "insert-bytes"
    case overwriteSpan = "overwrite-span"
    case appendBytes = "append-bytes"
    case splice

    static func random(using random: inout SplitMix64) -> Self {
        let mutable = Array(allCases.dropFirst())
        return mutable[random.nextInt(upperBound: mutable.count)]
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    mutating func nextByte() -> UInt8 {
        UInt8(truncatingIfNeeded: next())
    }
}

private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .sortedKeys,
        .withoutEscapingSlashes,
    ]
    return try encoder.encode(value)
}

private func appendLengthPrefixed(_ value: Data, to output: inout Data) {
    var count = UInt64(value.count)
    for _ in 0 ..< 8 {
        output.append(UInt8(truncatingIfNeeded: count))
        count >>= 8
    }
    output.append(value)
}
