import BrushFormat
import Foundation
import PatternEngine

public enum SyntheticV1DiagnosticScenario: String, Codable, Sendable {
    case dry
    case wet
}

public struct SyntheticV1DiagnosticResult: Codable, Equatable, Sendable {
    public let activation: String
    public let adapter: String
    public let approximated: Int
    public let exact: Int
    public let packageRoundTrip: Bool
    public let requiredSemanticKeys: [String]
    public let resourceResampled: Int
    public let scenario: SyntheticV1DiagnosticScenario
    public let sourceSettingCount: Int
    public let unsupported: Int
}

enum SyntheticV1DiagnosticStage: String, Sendable {
    case fixture
    case probe
    case parse
    case map
    case roundTrip = "round-trip"
    case activation
}

struct SyntheticV1DiagnosticFailure: Error, Equatable, Sendable {
    let stage: SyntheticV1DiagnosticStage
}

public enum SyntheticV1DiagnosticRunner {
    public static func run(
        scenario: SyntheticV1DiagnosticScenario
    ) throws -> SyntheticV1DiagnosticResult {
        let includeWet = scenario == .wet
        let source: Data
        do {
            source = try SyntheticV1DiagnosticFixture.source(
                includeWet: includeWet
            )
        } catch {
            throw SyntheticV1DiagnosticFailure(stage: .fixture)
        }

        let parser = SyntheticV1BrushParser()
        let matches: Bool
        do {
            matches = try parser.probe(source)
        } catch {
            throw SyntheticV1DiagnosticFailure(stage: .probe)
        }
        guard matches else {
            throw SyntheticV1DiagnosticFailure(stage: .probe)
        }

        let documents: [ForeignBrushDocument]
        do {
            documents = try parser.parse(source)
        } catch {
            throw SyntheticV1DiagnosticFailure(stage: .parse)
        }
        guard documents.count == 1, let document = documents.first else {
            throw SyntheticV1DiagnosticFailure(stage: .parse)
        }

        let mapped: ForeignBrushMappingResult
        do {
            mapped = try SyntheticV1BrushMapper().map(document)
        } catch {
            throw SyntheticV1DiagnosticFailure(stage: .map)
        }

        let decoded: BrushPackage
        do {
            decoded = try BrushPackageCodec.decode(
                BrushPackageCodec.encode(mapped.package)
            )
        } catch {
            throw SyntheticV1DiagnosticFailure(stage: .roundTrip)
        }
        guard decoded == mapped.package,
              decoded.conversionReport == mapped.report,
              decoded.manifest.schemaVersion == 2
        else {
            throw SyntheticV1DiagnosticFailure(stage: .roundTrip)
        }

        let definition = decoded.definition
        let summary = mapped.report.summary
        let expectedSourceKeys = includeWet
            ? SyntheticV1SemanticKeys.all
            : SyntheticV1SemanticKeys.dry
        guard definition.compatibility.sourceSettingKeys == expectedSourceKeys,
              summary.exact == SyntheticV1SemanticKeys.dry.count - 2,
              summary.approximated == 0,
              summary.resourceResampled == 2,
              summary.unsupported == (includeWet ? 1 : 0)
        else {
            throw SyntheticV1DiagnosticFailure(stage: .activation)
        }

        guard scenario == .dry,
              definition.compatibility.requiredSemanticKeys.isEmpty,
              definition.components[0].material.interaction == .none,
              definition.capabilities.isEmpty
        else {
            throw SyntheticV1DiagnosticFailure(stage: .activation)
        }
        do {
            _ = try BrushProgramCompiler.compile(definition)
        } catch {
            throw SyntheticV1DiagnosticFailure(stage: .activation)
        }

        return SyntheticV1DiagnosticResult(
            activation: "supported",
            adapter: "synthetic-v1",
            approximated: summary.approximated,
            exact: summary.exact,
            packageRoundTrip: true,
            requiredSemanticKeys:
            definition.compatibility.requiredSemanticKeys,
            resourceResampled: summary.resourceResampled,
            scenario: scenario,
            sourceSettingCount:
            definition.compatibility.sourceSettingKeys.count,
            unsupported: summary.unsupported
        )
    }
}
