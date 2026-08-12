import Foundation
import Testing
@testable import BrushConverter

@Suite("Foreign brush document")
struct ForeignBrushDocumentTests {
    @Test
    func acceptsPayloadsOnlyInDocumentWhenDescriptorTableAgrees() throws {
        let bytes = Data([1, 2, 3, 4])
        let hash = ForeignBrushDocument.contentSHA256(bytes)
        let resource = try fixtureResource(hash: hash)
        let reference = try setting(
            "synthetic.v1.shape",
            domain: .resource,
            value: .resourceReference(resource.id)
        )
        let ir = try ForeignBrushIR(
            provenance: fixtureProvenance(),
            sourceBrushIdentifier: "brush",
            displayName: "Brush",
            settings: [reference],
            resources: [resource],
            diagnostics: []
        )

        let document = try ForeignBrushDocument(
            ir: ir,
            resourceData: [resource.id: bytes]
        )

        #expect(document.ir == ir)
        #expect(document.resourceData == [resource.id: bytes])
    }

    @Test
    func rejectsMissingUnexpectedWrongSizedAndHashMismatchedPayloads() throws {
        let bytes = Data([1, 2, 3, 4])
        let resource = try fixtureResource(
            hash: ForeignBrushDocument.contentSHA256(bytes)
        )
        let ir = try ForeignBrushIR(
            provenance: fixtureProvenance(),
            sourceBrushIdentifier: "brush",
            displayName: "Brush",
            settings: [],
            resources: [resource],
            diagnostics: []
        )

        #expect(
            throws: ForeignBrushValidationError.resourceTableMismatch(
                missing: [resource.id],
                unexpected: []
            )
        ) {
            _ = try ForeignBrushDocument(ir: ir, resourceData: [:])
        }
        #expect(
            throws: ForeignBrushValidationError.resourceTableMismatch(
                missing: [],
                unexpected: ["extra"]
            )
        ) {
            _ = try ForeignBrushDocument(
                ir: ir,
                resourceData: [
                    resource.id: bytes,
                    "extra": Data([9]),
                ]
            )
        }
        #expect(
            throws: ForeignBrushValidationError.resourceByteCountMismatch(
                resourceID: resource.id,
                expected: 4,
                actual: 3
            )
        ) {
            _ = try ForeignBrushDocument(
                ir: ir,
                resourceData: [resource.id: Data([1, 2, 3])]
            )
        }
        #expect(
            throws: ForeignBrushValidationError.resourceHashMismatch(resource.id)
        ) {
            _ = try ForeignBrushDocument(
                ir: ir,
                resourceData: [resource.id: Data([4, 3, 2, 1])]
            )
        }
    }
}

@Suite("Foreign brush deterministic coding")
struct ForeignBrushCodingTests {
    @Test
    func IRRoundTripsWithDeterministicBytes() throws {
        let bytes = Data([1, 2, 3, 4])
        let resource = try fixtureResource(
            hash: ForeignBrushDocument.contentSHA256(bytes)
        )
        let setting = try setting(
            "synthetic.v1.scalar",
            unit: .normalized,
            domain: .scalar,
            value: .scalar(0.75)
        )
        let ir = try ForeignBrushIR(
            provenance: fixtureProvenance(),
            sourceBrushIdentifier: "brush",
            displayName: "Brush",
            settings: [setting],
            resources: [resource],
            diagnostics: []
        )
        let irBytes = try ForeignBrushCoding.encode(ir)
        #expect(irBytes == (try ForeignBrushCoding.encode(ir)))
        #expect(try ForeignBrushCoding.decodeIR(irBytes) == ir)
    }

    @Test
    func signedZeroHasOneCanonicalIRRepresentation() throws {
        let positiveSettings = try [
            setting(
                "synthetic.v1.color",
                unit: .sRGB,
                domain: .color,
                value: .color(
                    ForeignBrushColor(
                        red: 0,
                        green: 0.5,
                        blue: 0,
                        alpha: 1
                    )
                )
            ),
            setting(
                "synthetic.v1.curve",
                domain: .curve,
                value: .curve([
                    ForeignBrushCurvePoint(x: 0, y: 0),
                    ForeignBrushCurvePoint(x: 1, y: 0),
                ])
            ),
            setting(
                "synthetic.v1.scalar",
                domain: .scalar,
                value: .scalar(0)
            ),
            setting(
                "synthetic.v1.vector",
                domain: .vector,
                value: .vector([0, 1])
            ),
        ]
        let negativeSettings = try [
            setting(
                "synthetic.v1.color",
                unit: .sRGB,
                domain: .color,
                value: .color(
                    ForeignBrushColor(
                        red: -0.0,
                        green: 0.5,
                        blue: -0.0,
                        alpha: 1
                    )
                )
            ),
            setting(
                "synthetic.v1.curve",
                domain: .curve,
                value: .curve([
                    ForeignBrushCurvePoint(x: -0.0, y: -0.0),
                    ForeignBrushCurvePoint(x: 1, y: -0.0),
                ])
            ),
            setting(
                "synthetic.v1.scalar",
                domain: .scalar,
                value: .scalar(-0.0)
            ),
            setting(
                "synthetic.v1.vector",
                domain: .vector,
                value: .vector([-0.0, 1])
            ),
        ]
        let positive = try ForeignBrushIR(
            provenance: fixtureProvenance(),
            sourceBrushIdentifier: "brush",
            displayName: "Brush",
            settings: positiveSettings,
            resources: [],
            diagnostics: []
        )
        let negative = try ForeignBrushIR(
            provenance: fixtureProvenance(),
            sourceBrushIdentifier: "brush",
            displayName: "Brush",
            settings: negativeSettings,
            resources: [],
            diagnostics: []
        )

        #expect(positive == negative)
        #expect(
            try ForeignBrushCoding.encode(positive)
                == ForeignBrushCoding.encode(negative)
        )
    }

    @Test
    func decoderRevalidatesTamperedOrderingAndNonFiniteValues() throws {
        let valid = try ForeignBrushIR(
            provenance: fixtureProvenance(),
            sourceBrushIdentifier: "brush",
            displayName: "Brush",
            settings: [
                try setting("synthetic.v1.a", domain: .scalar, value: .scalar(1)),
                try setting("synthetic.v1.b", domain: .scalar, value: .scalar(2)),
            ],
            resources: [],
            diagnostics: []
        )
        let encoded = try ForeignBrushCoding.encode(valid)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        var tampered = object
        var components = try #require(
            object["components"] as? [[String: Any]]
        )
        components[0]["settings"] = Array(
            (try #require(components[0]["settings"] as? [Any])).reversed()
        )
        tampered["components"] = components
        let tamperedData = try JSONSerialization.data(withJSONObject: tampered)

        #expect(throws: ForeignBrushValidationError.unsorted("component.settings")) {
            _ = try ForeignBrushCoding.decodeIR(tamperedData)
        }

        var nonFiniteObject = object
        var nonFiniteComponents = try #require(
            object["components"] as? [[String: Any]]
        )
        var nonFiniteSettings = try #require(
            nonFiniteComponents[0]["settings"] as? [[String: Any]]
        )
        var value = try #require(
            nonFiniteSettings[0]["value"] as? [String: Any]
        )
        value["value"] = "NaN"
        nonFiniteSettings[0]["value"] = value
        nonFiniteComponents[0]["settings"] = nonFiniteSettings
        nonFiniteObject["components"] = nonFiniteComponents
        let nonFinite = try JSONSerialization.data(
            withJSONObject: nonFiniteObject
        )
        #expect(throws: (any Error).self) {
            _ = try ForeignBrushCoding.decodeIR(nonFinite)
        }
    }

    @Test
    func decoderRevalidatesCountsDuplicatesReferencesDomainsAndUnits() throws {
        let resourceBytes = Data([1, 2, 3, 4])
        let resource = try fixtureResource(
            hash: ForeignBrushDocument.contentSHA256(resourceBytes)
        )
        let valid = try ForeignBrushIR(
            provenance: fixtureProvenance(),
            sourceBrushIdentifier: "brush",
            displayName: "Brush",
            settings: [
                try setting(
                    "synthetic.v1.scalar",
                    domain: .scalar,
                    value: .scalar(1)
                ),
                try setting(
                    "synthetic.v1.shape",
                    domain: .resource,
                    value: .resourceReference(resource.id)
                ),
            ],
            resources: [resource],
            diagnostics: []
        )
        let encoded = try ForeignBrushCoding.encode(valid)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        let components = try #require(
            object["components"] as? [[String: Any]]
        )
        let settings = try #require(
            components[0]["settings"] as? [[String: Any]]
        )

        var duplicate = object
        var duplicateComponents = components
        duplicateComponents[0]["settings"] = [settings[0], settings[0]]
        duplicate["components"] = duplicateComponents
        #expect(throws: ForeignBrushValidationError.duplicate(
            field: "component.settings",
            value: "synthetic.v1.scalar"
        )) {
            _ = try ForeignBrushCoding.decodeIR(
                JSONSerialization.data(withJSONObject: duplicate)
            )
        }

        var oversized = object
        var oversizedComponents = components
        oversizedComponents[0]["settings"] =
            (0...ForeignBrushLimits.maximumSettingsPerBrush).map { index in
                var setting = settings[0]
                setting["semanticKey"] = String(
                    format: "synthetic.v1.scalar.%04d",
                    index
                )
                return setting
            }
        oversized["components"] = oversizedComponents
        #expect(throws: ForeignBrushValidationError.countOutOfRange(
            field: "ir.settings",
            actual: ForeignBrushLimits.maximumSettingsPerBrush + 1,
            maximum: ForeignBrushLimits.maximumSettingsPerBrush
        )) {
            _ = try ForeignBrushCoding.decodeIR(
                JSONSerialization.data(withJSONObject: oversized)
            )
        }

        var dangling = object
        var danglingComponents = components
        danglingComponents[0]["resources"] = []
        dangling["components"] = danglingComponents
        #expect(throws: ForeignBrushValidationError.danglingResourceReference(
            settingKey: "synthetic.v1.shape",
            resourceID: resource.id
        )) {
            _ = try ForeignBrushCoding.decodeIR(
                JSONSerialization.data(withJSONObject: dangling)
            )
        }

        var wrongDomain = object
        var wrongDomainComponents = components
        var wrongDomainSettings = settings
        wrongDomainSettings[0]["domain"] = "boolean"
        wrongDomainComponents[0]["settings"] = wrongDomainSettings
        wrongDomain["components"] = wrongDomainComponents
        #expect(throws: ForeignBrushValidationError.domainMismatch(
            expected: .scalar,
            actual: .boolean
        )) {
            _ = try ForeignBrushCoding.decodeIR(
                JSONSerialization.data(withJSONObject: wrongDomain)
            )
        }

        var wrongUnit = object
        var wrongUnitComponents = components
        var wrongUnitSettings = settings
        wrongUnitSettings[1]["unit"] = "pixels"
        wrongUnitComponents[0]["settings"] = wrongUnitSettings
        wrongUnit["components"] = wrongUnitComponents
        #expect(throws: ForeignBrushValidationError.unitMismatch(
            domain: .resource,
            unit: .pixels
        )) {
            _ = try ForeignBrushCoding.decodeIR(
                JSONSerialization.data(withJSONObject: wrongUnit)
            )
        }
    }
}

@Suite("Foreign brush contracts")
struct ForeignBrushProtocolTests {
    @Test
    func parserAndMapperContractsRemainPureAndSendable() throws {
        let parser = FixtureParser()
        let source = Data([0x46, 0x42])
        #expect(try parser.probe(source))
        let document = try #require(try parser.parse(source).first)
        let mapper = FixtureMapper()
        #expect(try mapper.map(document) == document.ir.displayName)
        requireSendable(parser)
        requireSendable(mapper)
        requireSendable(document)
    }
}

private struct FixtureParser: ForeignBrushParser {
    let identifier = "test.fixture"

    func probe(_ source: Data) throws -> Bool {
        source.starts(with: [0x46, 0x42])
    }

    func parse(_ source: Data) throws -> [ForeignBrushDocument] {
        guard try probe(source) else { return [] }
        return [
            try ForeignBrushDocument(
                ir: ForeignBrushIR(
                    provenance: fixtureProvenance(),
                    sourceBrushIdentifier: "fixture",
                    displayName: "Fixture",
                    settings: [],
                    resources: [],
                    diagnostics: []
                ),
                resourceData: [:]
            ),
        ]
    }
}

private struct FixtureMapper: ForeignBrushMapper {
    func map(_ document: ForeignBrushDocument) throws -> String {
        document.ir.displayName
    }
}

private func requireSendable<T: Sendable>(_ value: T) {
    _ = value
}
