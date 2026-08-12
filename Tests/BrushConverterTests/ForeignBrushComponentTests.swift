@testable import BrushConverter
import Foundation
import Testing

@Suite("Foreign brush components")
struct ForeignBrushComponentTests {
    @Test
    func versionTwoUsesOrderedComponentsAsItsSingleStoredSettingSource()
        throws
    {
        let root = try ForeignBrushComponent(
            identifier: "root",
            ordinal: 0,
            sourcePath: "Brush.archive",
            settings: [],
            resources: [],
            diagnostics: []
        )
        let child = try ForeignBrushComponent(
            identifier: "sub01",
            ordinal: 1,
            sourcePath: "Sub01/Brush.archive",
            settings: [],
            resources: [],
            diagnostics: []
        )
        let ir = try ForeignBrushIR(
            provenance: provenance(),
            sourceBrushIdentifier: "brush",
            displayName: "Brush",
            components: [root, child]
        )

        #expect(ir.schemaVersion == 2)
        #expect(ir.components.map(\.identifier) == ["root", "sub01"])
        #expect(ir.components.map(\.ordinal) == [0, 1])

        let encoded = try ForeignBrushCoding.encode(ir)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["components"] != nil)
        #expect(object["settings"] == nil)
        #expect(object["resources"] == nil)
        #expect(object["diagnostics"] == nil)
    }

    @Test
    func versionOneDecodesAsOneCanonicalRootComponent() throws {
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "provenance": [
                "sourceFormatFamily": "synthetic",
                "sourceFormatVersion": "1",
                "sourceContentSHA256": String(repeating: "a", count: 64),
                "parserIdentifier": "fixture",
                "parserVersion": "1",
            ],
            "sourceBrushIdentifier": "legacy",
            "displayName": "Legacy",
            "settings": [],
            "resources": [],
            "diagnostics": [],
        ]
        let decoded = try ForeignBrushCoding.decodeIR(
            JSONSerialization.data(withJSONObject: legacy)
        )

        #expect(decoded.schemaVersion == 2)
        #expect(decoded.components.count == 1)
        #expect(decoded.components[0].identifier == "root")
        #expect(decoded.components[0].ordinal == 0)
        #expect(decoded.components[0].sourcePath == "Brush.archive")
    }

    @Test
    func rejectsDuplicateIdentifiersAndNonCanonicalOrdinals() throws {
        let root = try component("root", ordinal: 0)
        let duplicate = try component("root", ordinal: 1)
        #expect(
            throws: ForeignBrushValidationError.duplicate(
                field: "ir.components.identifier",
                value: "root"
            )
        ) {
            _ = try ForeignBrushIR(
                provenance: provenance(),
                sourceBrushIdentifier: "brush",
                displayName: "Brush",
                components: [root, duplicate]
            )
        }

        let skipped = try component("sub01", ordinal: 2)
        #expect(
            throws: ForeignBrushValidationError.outOfRange(
                "ir.components.ordinal"
            )
        ) {
            _ = try ForeignBrushIR(
                provenance: provenance(),
                sourceBrushIdentifier: "brush",
                displayName: "Brush",
                components: [root, skipped]
            )
        }
    }

    private func component(
        _ identifier: String,
        ordinal: UInt16
    ) throws -> ForeignBrushComponent {
        try ForeignBrushComponent(
            identifier: identifier,
            ordinal: ordinal,
            sourcePath: "\(identifier)/Brush.archive",
            settings: [],
            resources: [],
            diagnostics: []
        )
    }

    private func provenance() throws -> ForeignBrushProvenance {
        try ForeignBrushProvenance(
            sourceFormatFamily: "synthetic",
            sourceFormatVersion: "1",
            sourceContentSHA256: String(repeating: "a", count: 64),
            parserIdentifier: "fixture",
            parserVersion: "1"
        )
    }
}
