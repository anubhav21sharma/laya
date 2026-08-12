@testable import BrushConverter
import CryptoKit
import Foundation
import Testing

@Suite("Procreate charcoal replacement corpus")
struct ProcreateCharcoalCorpusTests {
    private let memberOrder = [
        "C3A956C4-00DB-4CA9-B5A2-6F0199B591EC",
        "0DADE934-8FD1-4680-AA5E-66D699CF21A0",
        "21AF8C6B-3FB1-4BF8-8F89-F5768271DA35",
        "CC70504F-0D16-4D26-88A6-BF47BDA8ADE8",
        "89185C2C-2746-4934-A9DB-20983D28BEED",
        "ACF77570-AD91-4352-86C7-2C48BF0D7108",
        "77E04E60-98F7-4849-90E9-3F23C5B303DB",
        "C430FF39-0164-4E0B-A7E6-B6200BB89F86",
    ]

    @Test
    func pinsOwnedFilesManifestOrderAndAllBrushIdentities() throws {
        let directory = corpusDirectory
        let archiveData = try Data(contentsOf: directory.appendingPathComponent(
            "1_FREE_Charcoal_Set.brushset"
        ))
        #expect(sha256(archiveData)
            == "efa2a655620844fc3cc0b2c26f81bf28f31d7b9e74677c31933c352cf13156cf")
        #expect(sha256(try Data(contentsOf: directory.appendingPathComponent(
            "DSC_0006.jpg"
        ))) == "5ce41606b51036394f841f519b7af45e9316012145d48acbe76cc7a5e43d309f")
        #expect(sha256(try Data(contentsOf: directory.appendingPathComponent(
            "DSC_0175.jpg"
        ))) == "929f5c3b301bfcee2acd0367b0147af4c27bc775547f50a347d3dc8c24a172d0")

        let archive = try ForeignZIPReader(archiveData)
        let manifest = try #require(
            PropertyListSerialization.propertyList(
                from: archive.data(for: "brushset.plist"),
                format: nil
            ) as? [String: Any]
        )
        #expect(manifest["name"] as? String == "FREE Charcoal Set")
        #expect(manifest["brushes"] as? [String] == memberOrder)

        let documents = try ProcreateBrushParser().parse(archiveData)
        var inventory: [String: String] = [:]
        for document in documents {
            #expect(inventory.updateValue(
                document.ir.displayName,
                forKey: document.ir.sourceBrushIdentifier
            ) == nil)
        }
        #expect(inventory == [
            memberOrder[0]: "Procreate Pencil - Remake",
            memberOrder[1]: "COFE Pencil - F",
            memberOrder[2]: "C Charcoal Soft",
            memberOrder[3]: "C Charcoal",
            memberOrder[4]: "Finger Smudge",
            memberOrder[5]: "Eraser - Soft",
            memberOrder[6]: "Eraser - Medium",
            memberOrder[7]: "Eraser - Hard",
        ])
        #expect(documents.count == 8)
        for missingName in [
            "Haggard-Oval.png",
            "Brush-Preset-Bonobo.png",
            "Brush-Artery-Charcoal-Corse.jpg",
        ] {
            #expect(!archive.paths.contains { path in
                path == missingName || path.hasSuffix("/\(missingName)")
            })
        }
    }

    @Test
    func targetComponentsRetainIndependentCharacterizedValues() throws {
        let archiveData = try Data(contentsOf: corpusDirectory
            .appendingPathComponent("1_FREE_Charcoal_Set.brushset"))
        let documents = try ProcreateBrushParser().parse(archiveData)
        var inventory: [String: ForeignBrushIR] = [:]
        for document in documents {
            #expect(inventory.updateValue(
                document.ir,
                forKey: document.ir.sourceBrushIdentifier
            ) == nil)
        }
        for (identifier, textureScale) in [
            ("CC70504F-0D16-4D26-88A6-BF47BDA8ADE8", 2.0736),
            ("21AF8C6B-3FB1-4BF8-8F89-F5768271DA35", 0.9216),
        ] {
            let brush = try #require(inventory[identifier])
            #expect(brush.components.map(\.identifier) == ["root", "sub01"])
            #expect(brush.components.map(\.sourcePath) == [
                "\(identifier)/Brush.archive",
                "\(identifier)/Sub01/Brush.archive",
            ])
            expectScalars(
                brush,
                ProcreateBrushSemanticKeys.paintSize,
                equalTo: [0.1112989, 1]
            )
            expectScalars(
                brush,
                ProcreateBrushSemanticKeys.plotSpacing,
                equalTo: [0.01884642, 0.01884642]
            )
            expectScalars(
                brush,
                ProcreateBrushSemanticKeys.pressureSize,
                equalTo: [1, 1]
            )
            expectScalars(
                brush,
                ProcreateBrushSemanticKeys.pressureOpacity,
                equalTo: [0.66, 0.66]
            )
            expectScalars(
                brush,
                ProcreateBrushSemanticKeys.tiltSize,
                equalTo: [0.8, 0.8]
            )
            expectScalars(
                brush,
                ProcreateBrushSemanticKeys.tiltShapeRoundness,
                equalTo: [1, 1]
            )
            expectScalars(
                brush,
                ProcreateBrushSemanticKeys.textureScale,
                equalTo: [textureScale, textureScale]
            )
            expectScalars(
                brush,
                ProcreateBrushSemanticKeys.textureMovement,
                equalTo: [1, 1]
            )
            #expect(value(brush.components[0], ProcreateBrushSemanticKeys.dualBlendMode)
                == .integer(1))
            #expect(values(brush, ProcreateBrushSemanticKeys.bundledShapePath)
                == [.token("Haggard-Oval.png"), .token("Haggard-Oval.png")])
            #expect(values(brush, ProcreateBrushSemanticKeys.bundledGrainPath)
                == [
                    .token("Brush-Preset-Bonobo.png"),
                    .token("Brush-Artery-Charcoal-Corse.jpg"),
                ])
            #expect(!brush.components.map(\.sourcePath).contains {
                $0.contains("Reset")
            })
        }
    }

    private var corpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("brushes/procreate", isDirectory: true)
    }

    private func values(
        _ brush: ForeignBrushIR,
        _ key: String
    ) -> [ForeignBrushSettingValue?] {
        brush.components.map { value($0, key) }
    }

    private func expectScalars(
        _ brush: ForeignBrushIR,
        _ key: String,
        equalTo expected: [Double]
    ) {
        let actual = values(brush, key).compactMap { value -> Double? in
            guard case let .scalar(number) = value else { return nil }
            return number
        }
        #expect(actual.count == expected.count)
        for (actualValue, expectedValue) in zip(actual, expected) {
            #expect(abs(actualValue - expectedValue) < 0.000_001)
        }
    }

    private func value(
        _ component: ForeignBrushComponent,
        _ key: String
    ) -> ForeignBrushSettingValue? {
        component.settings.first { $0.semanticKey == key }?.value
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
