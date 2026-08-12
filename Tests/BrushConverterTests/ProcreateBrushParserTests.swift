@testable import BrushConverter
import Foundation
import Testing

@Suite("Procreate brush parser")
struct ProcreateBrushParserTests {
    @Test
    func routesBySignatureAndStructureWithoutFilenameInput() throws {
        let source = try individualFixture()
        let router = ProcreateBrushParser()

        #expect(try router.probe(source))
        #expect(try ProcreateExportedBrushParser().probe(source))
        #expect(try !(ProcreateLegacyBrushSetParser().probe(source)))
        #expect(try !(router.probe(Data("not a brush".utf8))))
        #expect(try router.parse(Data("not a brush".utf8)).isEmpty)
    }

    @Test
    func parsesIndividualMetadataResourcesAndOpaqueSettingsDeterministically()
        throws
    {
        let source = try individualFixture()
        let parser = ProcreateBrushParser()

        let first = try parser.parse(source)
        let second = try parser.parse(source)

        #expect(first == second)
        let document = try #require(first.first)
        #expect(first.count == 1)
        #expect(document.ir.displayName == "Project Pencil")
        #expect(document.ir.author == "Laya")
        #expect(
            document.ir.provenance.sourceFormatVersion
                == ProcreateExportedBrushParser.sourceFormatVersion
        )
        #expect(
            document.ir.provenance.parserIdentifier
                == ProcreateExportedBrushParser.parserIdentifier
        )
        #expect(
            document.ir.provenance.sourceContentSHA256
                == ForeignBrushDocument.contentSHA256(source)
        )
        #expect(
            document.ir.resources.map(\.id)
                == [
                    "root.grain.procreate",
                    "root.preview.procreate",
                    "root.shape.procreate",
                ]
        )
        #expect(document.resourceData.count == 3)
        #expect(
            document.ir.settings.contains {
                $0.semanticKey == ProcreateBrushSemanticKeys.shape
                    && $0.value
                    == .resourceReference("root.shape.procreate")
            }
        )
        #expect(
            document.ir.settings.contains {
                $0.semanticKey == ProcreateBrushSemanticKeys.grain
                    && $0.value
                    == .resourceReference("root.grain.procreate")
            }
        )
        let raw = document.ir.settings.filter {
            $0.semanticKey.hasPrefix(
                ProcreateBrushSemanticKeys.rawPrefix
            )
        }
        #expect(raw.count == 1)
        #expect(raw[0].value == .scalar(0.375))
        #expect(
            document.ir.diagnostics.contains {
                $0.code == "procreate.unverified-setting"
            }
        )
        let encodedIR = try ForeignBrushCoding.encode(document.ir)
        #expect(
            String(decoding: encodedIR, as: UTF8.self)
                .contains("0.375")
        )
    }

    @Test
    func parsesLegacySetInStableMemberOrderWithPerBrushProvenance() throws {
        let source = try ProcreateTestFixtureFactory.zip([
            .init(
                path: "brushset.plist",
                data: ProcreateTestFixtureFactory
                    .brushSetManifest(["member-b", "member-a"])
            ),
            .init(
                path: "member-a/Brush.archive",
                data: ProcreateTestFixtureFactory.brushArchive(
                    name: "Alpha"
                )
            ),
            .init(
                path: "member-a/Shape.png",
                data: ProcreateTestFixtureFactory.png
            ),
            .init(
                path: "member-b/Brush.archive",
                data: ProcreateTestFixtureFactory.brushArchive(
                    name: "Beta"
                )
            ),
            .init(
                path: "member-b/Grain.png",
                data: ProcreateTestFixtureFactory.png
            ),
        ])

        let parser = ProcreateBrushParser()
        let documents = try parser.parse(source)

        #expect(documents.map(\.ir.sourceBrushIdentifier)
            == ["member-a", "member-b"])
        #expect(documents.map(\.ir.displayName) == ["Alpha", "Beta"])
        #expect(documents.allSatisfy {
            $0.ir.provenance.sourceFormatVersion
                == ProcreateLegacyBrushSetParser.sourceFormatVersion
        })
        #expect(documents.allSatisfy {
            $0.ir.provenance.parserIdentifier
                == ProcreateLegacyBrushSetParser.parserIdentifier
        })
        #expect(documents[0].ir.resources.map(\.id) == ["root.shape.procreate"])
        #expect(documents[1].ir.resources.map(\.id) == ["root.grain.procreate"])
    }

    @Test
    func parsesRootAndActiveSub01AsIndependentTypedComponents() throws {
        let source = try ProcreateTestFixtureFactory.zip([
            .init(
                path: "brushset.plist",
                data: ProcreateTestFixtureFactory.brushSetManifest(["member"])
            ),
            .init(
                path: "member/Brush.archive",
                data: ProcreateTestFixtureFactory.brushArchive(
                    name: "Composite",
                    unverifiedFields: ["paintSize": 0.25]
                )
            ),
            .init(
                path: "member/Sub01/Brush.archive",
                data: ProcreateTestFixtureFactory.brushArchive(
                    name: "Child",
                    unverifiedFields: ["paintSize": 0.75]
                )
            ),
            .init(
                path: "member/Reset/Sub01/Brush.archive",
                data: ProcreateTestFixtureFactory.brushArchive(
                    name: "Reset Copy",
                    unverifiedFields: ["paintSize": 0.99]
                )
            ),
        ])

        let document = try #require(ProcreateBrushParser().parse(source).first)
        #expect(document.ir.components.map(\.identifier) == ["root", "sub01"])
        #expect(document.ir.components.map(\.sourcePath) == [
            "member/Brush.archive",
            "member/Sub01/Brush.archive",
        ])
        #expect(document.ir.components.map { component in
            component.settings.first {
                $0.semanticKey == ProcreateBrushSemanticKeys.paintSize
            }?.value
        } == [.scalar(0.25), .scalar(0.75)])
        #expect(!document.ir.diagnostics.contains {
            $0.code == "procreate.unsupported-sub-brush"
        })
    }

    @Test
    func rejectsNonContiguousAndNestedActiveSubBrushes() throws {
        let root = try ProcreateTestFixtureFactory.brushArchive(name: "Root")
        let child = try ProcreateTestFixtureFactory.brushArchive(name: "Child")
        let manifest = ProcreateTestFixtureFactory.brushSetManifest(["member"])
        let nonContiguous = ProcreateTestFixtureFactory.zip([
            .init(path: "brushset.plist", data: manifest),
            .init(path: "member/Brush.archive", data: root),
            .init(path: "member/Sub02/Brush.archive", data: child),
        ])
        #expect(
            throws: ProcreateBrushParserError.nonContiguousActiveComponents(
                "member"
            )
        ) {
            _ = try ProcreateBrushParser().parse(nonContiguous)
        }

        let nested = ProcreateTestFixtureFactory.zip([
            .init(path: "brushset.plist", data: manifest),
            .init(path: "member/Brush.archive", data: root),
            .init(path: "member/Sub01/Sub01/Brush.archive", data: child),
        ])
        #expect(
            throws: ProcreateBrushParserError.invalidActiveComponentPath(
                "member/Sub01/Sub01/Brush.archive"
            )
        ) {
            _ = try ProcreateBrushParser().parse(nested)
        }
    }

    @Test
    func rejectsAmbiguityDanglingMembersAndMalformedPNGs() throws {
        let archive = try ProcreateTestFixtureFactory.brushArchive(name: "A")
        let ambiguous = ProcreateTestFixtureFactory.zip([
            .init(path: "Brush.archive", data: archive),
            .init(
                path: "brushset.plist",
                data: ProcreateTestFixtureFactory
                    .brushSetManifest(["member"])
            ),
        ])
        #expect(throws: ProcreateBrushParserError.ambiguousContainer) {
            _ = try ProcreateBrushParser().parse(ambiguous)
        }

        let dangling = ProcreateTestFixtureFactory.zip([
            .init(
                path: "brushset.plist",
                data: ProcreateTestFixtureFactory
                    .brushSetManifest(["missing"])
            ),
            .init(path: "unrelated", data: Data([1])),
        ])
        #expect(
            throws: ProcreateBrushParserError.invalidBrushMember("missing")
        ) {
            _ = try ProcreateBrushParser().parse(dangling)
        }

        let invalidPNG = ProcreateTestFixtureFactory.zip([
            .init(path: "Brush.archive", data: archive),
            .init(path: "Shape.png", data: Data("not png".utf8)),
        ])
        #expect(
            throws: ProcreateBrushParserError
                .invalidEmbeddedPNG("Shape.png")
        ) {
            _ = try ProcreateBrushParser().parse(invalidPNG)
        }
    }

    @Test
    func acceptsNonzeroIndexSlicesAndDoesNotRetainUnknownPayloads() throws {
        let source = try individualFixture()
        var wrapped = Data([7, 8, 9])
        wrapped.append(source)
        wrapped.append(contentsOf: [10, 11])
        let slice = wrapped[3 ..< (3 + source.count)]

        let document = try #require(
            ProcreateBrushParser().parse(slice).first
        )

        #expect(document.ir.displayName == "Project Pencil")
        #expect(!document.resourceData.values.contains(Data([99, 98, 97])))
    }

    @Test
    func fixtureManifestsAreByteFreeProjectOwnedAndVariantIsolated() throws {
        let directory = try #require(
            Bundle.module.url(
                forResource: "Procreate",
                withExtension: nil,
                subdirectory: "Fixtures"
            )
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.map(\.pathExtension) == ["json", "json"])
        let manifests = try files.map {
            try JSONDecoder().decode(
                FixtureManifest.self,
                from: Data(contentsOf: $0)
            )
        }
        #expect(manifests.map(\.containerVariant)
            == ["individual-export", "legacy-brushset"])
        #expect(manifests.allSatisfy {
            $0.schemaVersion == 1
                && !$0.identifier.isEmpty
                && $0.ownership == "project-owned"
                && !$0.rawFixtureCommitted
                && !$0.sourceApplicationVersion.isEmpty
                && !$0.observedStructure.isEmpty
        })
        #expect(Set(manifests.flatMap(\.evidenceBackedSemanticKeys))
            == [
                ProcreateBrushSemanticKeys.shape,
                ProcreateBrushSemanticKeys.grain,
            ])
    }

    private func individualFixture() throws -> Data {
        try ProcreateTestFixtureFactory.zip([
            .init(
                path: "Brush.archive",
                data: ProcreateTestFixtureFactory.brushArchive(
                    name: "Project Pencil",
                    author: "Laya",
                    unverifiedFields: ["spacing": 0.375]
                )
            ),
            .init(
                path: "Shape.png",
                data: ProcreateTestFixtureFactory.png
            ),
            .init(
                path: "Grain.png",
                data: ProcreateTestFixtureFactory.png
            ),
            .init(
                path: "QuickLook/Thumbnail.png",
                data: ProcreateTestFixtureFactory.png
            ),
            .init(path: "opaque.bin", data: Data([99, 98, 97])),
        ])
    }
}

private struct FixtureManifest: Decodable {
    let schemaVersion: Int
    let identifier: String
    let ownership: String
    let rawFixtureCommitted: Bool
    let containerVariant: String
    let sourceApplicationVersion: String
    let observedStructure: [String]
    let evidenceBackedSemanticKeys: [String]
}
