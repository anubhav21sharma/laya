@testable import BrushConverter
import Foundation
import Testing

@Suite("Synthetic v1 CLI diagnostic")
struct SyntheticV1DiagnosticTests {
    private let dryJSON =
        #"{"activation":"supported","adapter":"synthetic-v1","approximated":0,"exact":7,"packageRoundTrip":true,"requiredSemanticKeys":[],"resourceResampled":2,"scenario":"dry","sourceSettingCount":9,"unsupported":0}"#
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

    @Test
    func dryCommandRunsDeterministically() {
        let arguments = ["diagnostic", "synthetic-v1", "dry"]
        let first = LayabrushConvertCommandRunner.run(arguments: arguments)
        let second = LayabrushConvertCommandRunner.run(arguments: arguments)

        #expect(first == second)
        #expect(first.exitStatus == 0)
        #expect(first.standardError.isEmpty)
        #expect(first.standardOutput == dryJSON)
    }

    @Test
    func wetCommandReportsTheNativeSchemaThreeMapBoundary() {
        let arguments = ["diagnostic", "synthetic-v1", "wet"]
        let first = LayabrushConvertCommandRunner.run(arguments: arguments)
        let second = LayabrushConvertCommandRunner.run(arguments: arguments)

        #expect(first == second)
        #expect(first.exitStatus == LayabrushConvertExitStatus.internalFailure)
        #expect(first.standardOutput.isEmpty)
        #expect(
            first.standardError
                == "layabrush-convert: synthetic-v1 diagnostic failed at map\n"
        )
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

    @Test(arguments: [
        ["probe"],
        ["probe", "--replace", "input"],
        ["inspect", "--output", "output", "input"],
        ["inspect", "--brush", "id", "input"],
        ["convert", "one", "two"],
        ["convert", "--brush", "one", "--brush", "two", "input"],
        ["convert", "--substitutions", "one", "--substitutions", "two", "input"],
        ["convert", "--brush", "one", "input"],
        ["convert", "--substitutions", "manifest", "input"],
        ["batch", "--output", "--json", "input"],
        ["batch", "--unknown", "input"],
    ])
    func productionCommandsRejectInvalidArgumentShapes(arguments: [String]) {
        let output = LayabrushConvertCommandRunner.run(arguments: arguments)

        #expect(output.exitStatus == LayabrushConvertExitStatus.usage)
        #expect(output.standardOutput.isEmpty)
        #expect(output.standardError == LayabrushConvertCommandRunner.usage)
    }

    @Test
    func missingProbeInputHasStableMachineReportAndExitStatus() throws {
        let missing = "/tmp/laya-missing-\(UUID().uuidString)"

        let output = LayabrushConvertCommandRunner.run(
            arguments: ["probe", "--json", missing]
        )

        #expect(output.exitStatus == LayabrushConvertExitStatus.missingInput)
        #expect(output.standardError.contains("input-missing"))
        let report = try JSONDecoder().decode(
            LayabrushConvertReport.self,
            from: Data(output.standardOutput.utf8)
        )
        #expect(report.succeeded == 0)
        #expect(report.failed == 1)
        #expect(report.results.first?.reasonCode == "input-missing")
    }
}
