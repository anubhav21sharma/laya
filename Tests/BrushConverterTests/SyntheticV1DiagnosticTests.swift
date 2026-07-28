import Foundation
import Testing
@testable import BrushConverter

@Suite("Synthetic v1 CLI diagnostic")
struct SyntheticV1DiagnosticTests {
    private let dryJSON =
        #"{"activation":"supported","adapter":"synthetic-v1","approximated":0,"exact":7,"nativeFeatureVersion":1,"packageRoundTrip":true,"requiredSemanticKeys":[],"resourceResampled":2,"scenario":"dry","sourceSettingCount":9,"unsupported":0}"#
        + "\n"
    private let wetJSON =
        #"{"activation":"blocked-required-semantics","adapter":"synthetic-v1","approximated":0,"exact":7,"nativeFeatureVersion":1,"packageRoundTrip":true,"requiredSemanticKeys":["synthetic.v1.wet"],"resourceResampled":2,"scenario":"wet","sourceSettingCount":10,"unsupported":1}"#
        + "\n"

    @Test
    func publicFixtureIsDeterministicAndParseable() throws {
        for includeWet in [false, true] {
            let first = try SyntheticV1DiagnosticFixture.source(
                includeWet: includeWet
            )
            let second = try SyntheticV1DiagnosticFixture.source(
                includeWet: includeWet
            )
            #expect(first == second)
            let parser = SyntheticV1BrushParser()
            #expect(try parser.probe(first))
            let documents = try parser.parse(first)
            #expect(documents.count == 1)
            #expect(
                documents[0].ir.settings.map(\.semanticKey)
                    == (
                        includeWet
                            ? SyntheticV1SemanticKeys.all
                            : SyntheticV1SemanticKeys.dry
                    )
            )
        }
    }

    @Test(arguments: [
        (["diagnostic", "synthetic-v1", "dry"], false),
        (["diagnostic", "synthetic-v1", "wet"], true),
    ])
    func commandRunsDeterministically(
        arguments: [String],
        includeWet: Bool
    ) {
        let first = LayabrushConvertCommandRunner.run(arguments: arguments)
        let second = LayabrushConvertCommandRunner.run(arguments: arguments)

        #expect(first == second)
        #expect(first.exitStatus == 0)
        #expect(first.standardError.isEmpty)
        #expect(first.standardOutput == (includeWet ? wetJSON : dryJSON))
    }

    @Test(arguments: [
        [],
        ["diagnostic"],
        ["diagnostic", "unknown", "dry"],
        ["diagnostic", "synthetic-v1", "unknown"],
        ["diagnostic", "synthetic-v1", "dry", "extra"],
    ])
    func commandRejectsEveryOtherInvocation(arguments: [String]) {
        let output = LayabrushConvertCommandRunner.run(arguments: arguments)

        #expect(output.exitStatus == 64)
        #expect(output.standardOutput.isEmpty)
        #expect(output.standardError == LayabrushConvertCommandRunner.usage)
    }

    @Test
    func commandReportsTypedInvariantFailureWithoutLeakingErrorText() {
        let output = LayabrushConvertCommandRunner.run(
            arguments: ["diagnostic", "synthetic-v1", "dry"]
        ) { _ in
            throw SyntheticV1DiagnosticFailure(stage: .roundTrip)
        }

        #expect(output.exitStatus == 70)
        #expect(output.standardOutput.isEmpty)
        #expect(
            output.standardError
                == "layabrush-convert: synthetic-v1 diagnostic failed at round-trip\n"
        )
    }
}
