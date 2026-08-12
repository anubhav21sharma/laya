@testable import BrushConverter
import BrushFormat
import Foundation
import PatternEngine
import Testing

@Suite("Procreate classic-v1 charcoal mapper")
struct ProcreateClassicV1BrushMapperTests {
    @Test(arguments: [
        "CC70504F-0D16-4D26-88A6-BF47BDA8ADE8",
        "21AF8C6B-3FB1-4BF8-8F89-F5768271DA35",
    ])
    func mapsBothTargetsToDeterministicDryCompositePackages(
        identifier: String
    ) throws {
        let document = try target(identifier)
        let mapper = try ProcreateClassicV1BrushMapper(
            substitutions: registry
        )

        let first = try mapper.map(document)
        let second = try mapper.map(document)
        let definition = first.package.definition

        #expect(first == second)
        #expect(definition.components.map { $0.identifier.rawValue }
            == ["root", "sub01"])
        #expect(definition.components.map(\.ordinal) == [0, 1])
        #expect(definition.composition == .orderedSourceOver)
        #expect(definition.components.allSatisfy {
            $0.material.interaction == .none
        })
        #expect(definition.replayMode == .appendOnly)
        #expect(definition.termination == .cap)
        #expect(definition.replayLimits == nil)
        #expect(first.package.manifest.resources.map(\.id) == [
            "laya.charcoal.grain.coarse",
            "laya.charcoal.grain.fine",
            "laya.charcoal.tip",
        ])
        #expect(first.package.resourceData.count == 3)
        #expect(try BrushProgramCompiler.compile(definition)
            .secondaryComponent != nil)

        let expectedEntryCount = document.ir.components
            .reduce(0) { $0 + $1.settings.count }
        #expect(first.report.entries.count == expectedEntryCount)
        #expect(Set(first.report.entries.map(\.sourceSemanticKey)).count
            == expectedEntryCount)
        #expect(first.report.entries.filter {
            $0.reasonCode
                == ProcreateResourceSubstitutionRegistry.requiredReason
        }.count == 4)
        #expect(definition.compatibility.sourceSettingKeys
            == first.report.entries.map(\.sourceSemanticKey))
        #expect(definition.compatibility.requiredSemanticKeys
            == first.report.entries.compactMap {
                $0.disposition == .unsupported
                    && $0.requiredForFaithfulRendering
                    ? $0.sourceSemanticKey
                    : nil
            })

        let encoded = try BrushPackageCodec.encode(first.package)
        #expect(try BrushPackageCodec.decode(encoded) == first.package)
    }

    @Test
    func rejectsNonTargetBrushesAndMissingExactSubstitutions() throws {
        let other = try target("89185C2C-2746-4934-A9DB-20983D28BEED")
        #expect(
            throws: ProcreateClassicV1MappingError.unsupportedBrush(
                "89185C2C-2746-4934-A9DB-20983D28BEED"
            )
        ) {
            _ = try ProcreateClassicV1BrushMapper(
                substitutions: registry
            ).map(other)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var registry: ProcreateResourceSubstitutionRegistry {
        get throws {
            try .load(
                manifestURL: repositoryRoot.appendingPathComponent(
                    "brushes/procreate/substitutions.json"
                ),
                baseURL: repositoryRoot
            )
        }
    }

    private func target(_ identifier: String) throws -> ForeignBrushDocument {
        let source = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "brushes/procreate/1_FREE_Charcoal_Set.brushset"
        ))
        return try #require(ProcreateBrushParser().parse(source).first {
            $0.ir.sourceBrushIdentifier == identifier
        })
    }
}
