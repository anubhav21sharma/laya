@testable import BrushConverter
import Foundation
import Testing

@Suite("Procreate resource substitutions")
struct ProcreateResourceSubstitutionTests {
    @Test
    func loadsExactOwnedSubstitutionsWithPinnedBytesAndRoles() throws {
        let registry = try ProcreateResourceSubstitutionRegistry.load(
            manifestURL: manifestURL,
            baseURL: repositoryRoot
        )

        #expect(registry.sourceNames == [
            "Brush-Artery-Charcoal-Corse.jpg",
            "Brush-Preset-Bonobo.png",
            "Haggard-Oval.png",
        ])
        let tip = try registry.resolve(
            sourceName: "Haggard-Oval.png",
            expectedRole: .shape
        )
        #expect(tip.resourceID == "laya.charcoal.tip")
        #expect(tip.reason == "project-owned-source-library-substitute")
        #expect(tip.data.count == 7_186)
        #expect(tip.contentSHA256
            == "d894b2560a86e2c6425b1f197a2be1effe98ebed0beeb33269a8a595078014ad")

        #expect(
            throws: ProcreateResourceSubstitutionError.unknownSourceName(
                "haggard-oval.png"
            )
        ) {
            _ = try registry.resolve(
                sourceName: "haggard-oval.png",
                expectedRole: .shape
            )
        }
        #expect(
            throws: ProcreateResourceSubstitutionError.roleMismatch(
                sourceName: "Haggard-Oval.png",
                expected: .grain,
                actual: .shape
            )
        ) {
            _ = try registry.resolve(
                sourceName: "Haggard-Oval.png",
                expectedRole: .grain
            )
        }
    }

    @Test
    func rejectsDuplicateNamesAndHashMismatchesBeforeMapping() throws {
        let data = try Data(contentsOf: manifestURL)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var substitutions = try #require(
            object["substitutions"] as? [[String: Any]]
        )
        substitutions.append(substitutions[0])
        object["substitutions"] = substitutions
        #expect(
            throws: ProcreateResourceSubstitutionError.duplicateSourceName(
                "Haggard-Oval.png"
            )
        ) {
            _ = try ProcreateResourceSubstitutionRegistry(
                manifestData: JSONSerialization.data(withJSONObject: object),
                baseURL: repositoryRoot
            )
        }

        substitutions.removeLast()
        substitutions[0]["sha256"] = String(repeating: "0", count: 64)
        object["substitutions"] = substitutions
        #expect(
            throws: ProcreateResourceSubstitutionError.hashMismatch(
                "Haggard-Oval.png"
            )
        ) {
            _ = try ProcreateResourceSubstitutionRegistry(
                manifestData: JSONSerialization.data(withJSONObject: object),
                baseURL: repositoryRoot
            )
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var manifestURL: URL {
        repositoryRoot.appendingPathComponent(
            "brushes/procreate/substitutions.json"
        )
    }
}
