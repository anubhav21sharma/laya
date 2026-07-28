import BrushConverterFuzzSupport
import Foundation
import Testing

@Suite("Brush converter fuzz harness")
struct BrushConverterFuzzHarnessTests {
    @Test
    func bundledCorpusIsOwnedSortedAndBounded() throws {
        let corpus = try BrushConverterFuzzCorpus.loadBundled()

        #expect(corpus.schemaVersion == 1)
        #expect(corpus.ownership == "project-owned")
        #expect(
            corpus.entries.map(\.identifier)
                == [
                    "empty",
                    "empty-zip-eocd",
                    "non-archive-text",
                    "synthetic-signature-only",
                    "truncated-binary-plist",
                    "truncated-zip-local-header",
                    "xml-external-entity-probe",
                ]
        )
        #expect(
            corpus.entries.allSatisfy {
                $0.data.count
                    <= BrushConverterFuzzHarness.maximumGeneratedInputBytes
            }
        )
    }

    @Test
    func fixedSeedProducesIdenticalCasesAndObservations() throws {
        let firstHarness = try BrushConverterFuzzHarness()
        let secondHarness = try BrushConverterFuzzHarness()

        let firstCases = try firstHarness.generateCases(
            seed: 0x1234_5678_9ABC_DEF0,
            iterations: 64
        )
        let secondCases = try secondHarness.generateCases(
            seed: 0x1234_5678_9ABC_DEF0,
            iterations: 64
        )
        let first = try firstHarness.run(
            seed: 0x1234_5678_9ABC_DEF0,
            iterations: 64
        )
        let second = try secondHarness.run(
            seed: 0x1234_5678_9ABC_DEF0,
            iterations: 64
        )

        #expect(firstCases == secondCases)
        #expect(first == second)
        #expect(first.iterations == 64)
        #expect(first.totalInputBytes > 0)
        #expect(first.largestInputBytes > 0)
        #expect(
            first.largestInputBytes
                <= BrushConverterFuzzHarness.maximumGeneratedInputBytes
        )
        #expect(first.acceptedDocumentCount > 0)
        #expect(first.rejectedParserOperationCount > 0)
    }

    @Test
    func changingSeedChangesTheGeneratedCampaign() throws {
        let harness = try BrushConverterFuzzHarness()

        let first = try harness.run(seed: 41, iterations: 48)
        let second = try harness.run(seed: 42, iterations: 48)

        #expect(first.generatedInputSHA256 != second.generatedInputSHA256)
        #expect(first.observationSHA256 != second.observationSHA256)
    }

    @Test
    func iterationBoundsFailBeforeGeneratingInputs() throws {
        let harness = try BrushConverterFuzzHarness()

        #expect(
            throws: BrushConverterFuzzError.invalidIterationCount(0)
        ) {
            _ = try harness.generateCases(seed: 1, iterations: 0)
        }
        #expect(
            throws: BrushConverterFuzzError.invalidIterationCount(
                BrushConverterFuzzHarness.maximumIterations + 1
            )
        ) {
            _ = try harness.run(
                seed: 1,
                iterations:
                    BrushConverterFuzzHarness.maximumIterations + 1
            )
        }
    }

    @Test
    func lifecycleObserverBracketsEveryCompletedCase() throws {
        let harness = try BrushConverterFuzzHarness()
        var events = [String]()

        _ = try harness.run(seed: 91, iterations: 16) { event in
            switch event {
            case let .willEvaluate(fuzzCase):
                events.append("will:\(fuzzCase.iteration)")
            case let .didEvaluate(fuzzCase):
                events.append("did:\(fuzzCase.iteration)")
            }
        }

        #expect(events.count == 32)
        for iteration in 0 ..< 16 {
            #expect(events[iteration * 2] == "will:\(iteration)")
            #expect(events[iteration * 2 + 1] == "did:\(iteration)")
        }
    }

    @Test
    func replayArtifactRoundTripsExactCrashInput() throws {
        let harness = try BrushConverterFuzzHarness()
        let fuzzCase = try #require(
            harness.generateCases(seed: 73, iterations: 1).first
        )
        let artifact = BrushConverterFuzzReplayArtifact(fuzzCase: fuzzCase)
        let encoded = try artifact.encoded()
        let decoded = try BrushConverterFuzzReplayArtifact.decode(encoded)

        #expect(decoded == artifact)
        #expect(decoded.input == fuzzCase.input)
        #expect(
            decoded.inputSHA256
                == BrushConverterFuzzReplayArtifact.sha256(fuzzCase.input)
        )

        var object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object["inputSHA256"] = String(repeating: "0", count: 64)
        let tampered = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        #expect(throws: BrushConverterFuzzError.invalidReplayArtifact) {
            _ = try BrushConverterFuzzReplayArtifact.decode(tampered)
        }
    }
}
