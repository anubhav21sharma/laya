import Foundation
import Testing
@testable import BrushConverter

@Suite("Foreign brush IR")
struct ForeignBrushIRTests {
    @Test
    func acceptsEveryTypedSettingAndRetainsFormatNeutralProvenance() throws {
        let resource = try fixtureResource()
        let settings = try [
            setting("synthetic.v1.boolean", domain: .boolean, value: .boolean(true)),
            setting(
                "synthetic.v1.color",
                unit: .sRGB,
                domain: .color,
                value: .color(
                    try ForeignBrushColor(
                        red: 0.1,
                        green: 0.2,
                        blue: 0.3,
                        alpha: 1
                    )
                )
            ),
            setting("synthetic.v1.curve", domain: .curve, value: .curve([
                try ForeignBrushCurvePoint(x: 0, y: 0),
                try ForeignBrushCurvePoint(x: 1, y: 0.75),
            ])),
            setting("synthetic.v1.integer", unit: .count, domain: .integer, value: .integer(7)),
            setting(
                "synthetic.v1.resource",
                domain: .resource,
                value: .resourceReference(resource.id)
            ),
            setting("synthetic.v1.scalar", unit: .pixels, domain: .scalar, value: .scalar(12.5)),
            setting("synthetic.v1.token", domain: .token, value: .token("multiply")),
            setting(
                "synthetic.v1.vector",
                unit: .degrees,
                domain: .vector,
                value: .vector([10, 20])
            ),
        ]
        let diagnostic = try ForeignBrushDiagnostic(
            severity: .information,
            code: "unknownMetadata",
            location: "metadata/vendor",
            message: "An unclassified metadata field was retained."
        )

        let ir = try ForeignBrushIR(
            provenance: fixtureProvenance(),
            sourceBrushIdentifier: "brush-1",
            displayName: "Fixture Brush",
            author: "Fixture Author",
            settings: settings,
            resources: [resource],
            diagnostics: [diagnostic]
        )

        #expect(ir.schemaVersion == 1)
        #expect(ir.provenance.sourceFormatFamily == "synthetic")
        #expect(ir.settings.map(\.semanticKey) == settings.map(\.semanticKey))
        #expect(ir.resources == [resource])
        #expect(ir.diagnostics == [diagnostic])
    }

    @Test
    func rejectsUnsupportedSchemaAndInvalidIdentityStrings() throws {
        #expect(throws: ForeignBrushValidationError.unsupportedSchema(2)) {
            _ = try ForeignBrushIR(
                schemaVersion: 2,
                provenance: fixtureProvenance(),
                sourceBrushIdentifier: "brush",
                displayName: "Brush",
                settings: [],
                resources: [],
                diagnostics: []
            )
        }
        #expect(throws: ForeignBrushValidationError.empty("ir.displayName")) {
            _ = try fixtureIR(displayName: "")
        }
        #expect(throws: ForeignBrushValidationError.controlCharacter("ir.author")) {
            _ = try fixtureIR(author: "bad\nname")
        }
        #expect(
            throws: ForeignBrushValidationError.stringTooLong(
                field: "ir.sourceBrushIdentifier",
                maximumUTF8Bytes: ForeignBrushLimits.maximumStringUTF8Bytes
            )
        ) {
            _ = try fixtureIR(
                sourceBrushIdentifier: String(
                    repeating: "a",
                    count: ForeignBrushLimits.maximumStringUTF8Bytes + 1
                )
            )
        }
    }

    @Test
    func rejectsUnsortedAndDuplicateSettingsResourcesAndDiagnostics() throws {
        let alpha = try setting("synthetic.v1.alpha", domain: .scalar, value: .scalar(1))
        let beta = try setting("synthetic.v1.beta", domain: .scalar, value: .scalar(1))
        #expect(throws: ForeignBrushValidationError.unsorted("ir.settings")) {
            _ = try fixtureIR(settings: [beta, alpha])
        }
        #expect(
            throws: ForeignBrushValidationError.duplicate(
                field: "ir.settings",
                value: alpha.semanticKey
            )
        ) {
            _ = try fixtureIR(settings: [alpha, alpha])
        }

        let a = try fixtureResource(id: "a")
        let b = try fixtureResource(id: "b")
        #expect(throws: ForeignBrushValidationError.unsorted("ir.resources")) {
            _ = try fixtureIR(resources: [b, a])
        }
        #expect(
            throws: ForeignBrushValidationError.duplicate(
                field: "ir.resources",
                value: "a"
            )
        ) {
            _ = try fixtureIR(resources: [a, a])
        }

        let first = try ForeignBrushDiagnostic(
            severity: .warning,
            code: "a",
            location: "root/a",
            message: "A"
        )
        let second = try ForeignBrushDiagnostic(
            severity: .warning,
            code: "b",
            location: "root/b",
            message: "B"
        )
        #expect(throws: ForeignBrushValidationError.unsorted("ir.diagnostics")) {
            _ = try fixtureIR(diagnostics: [second, first])
        }
        #expect(
            throws: ForeignBrushValidationError.duplicate(
                field: "ir.diagnostics",
                value: first.stableIdentity
            )
        ) {
            _ = try fixtureIR(diagnostics: [first, first])
        }
    }

    @Test
    func enforcesSettingResourceAndDiagnosticCountBounds() throws {
        let settings = try (0...ForeignBrushLimits.maximumSettingsPerBrush).map {
            try setting(
                String(format: "synthetic.v1.setting.%05d", $0),
                domain: .integer,
                value: .integer(Int64($0))
            )
        }
        _ = try fixtureIR(settings: Array(settings.dropLast()))
        #expect(
            throws: ForeignBrushValidationError.countOutOfRange(
                field: "ir.settings",
                actual: settings.count,
                maximum: ForeignBrushLimits.maximumSettingsPerBrush
            )
        ) {
            _ = try fixtureIR(settings: settings)
        }

        let resources = try (0...ForeignBrushLimits.maximumResourcesPerBrush).map {
            try fixtureResource(id: String(format: "resource-%03d", $0))
        }
        _ = try fixtureIR(resources: Array(resources.dropLast()))
        #expect(
            throws: ForeignBrushValidationError.countOutOfRange(
                field: "ir.resources",
                actual: resources.count,
                maximum: ForeignBrushLimits.maximumResourcesPerBrush
            )
        ) {
            _ = try fixtureIR(resources: resources)
        }

        let diagnostics = try (0...ForeignBrushLimits.maximumDiagnosticsPerBrush).map {
            try ForeignBrushDiagnostic(
                severity: .information,
                code: String(format: "diagnostic-%05d", $0),
                location: nil,
                message: "Diagnostic"
            )
        }
        _ = try fixtureIR(diagnostics: Array(diagnostics.dropLast()))
        #expect(
            throws: ForeignBrushValidationError.countOutOfRange(
                field: "ir.diagnostics",
                actual: diagnostics.count,
                maximum: ForeignBrushLimits.maximumDiagnosticsPerBrush
            )
        ) {
            _ = try fixtureIR(diagnostics: diagnostics)
        }
    }

    @Test
    func rejectsDanglingSettingResourceReference() throws {
        let reference = try setting(
            "synthetic.v1.shape",
            domain: .resource,
            value: .resourceReference("shape.missing")
        )
        #expect(
            throws: ForeignBrushValidationError.danglingResourceReference(
                settingKey: reference.semanticKey,
                resourceID: "shape.missing"
            )
        ) {
            _ = try fixtureIR(settings: [reference])
        }
    }

    @Test
    func rejectsSemanticKeysOutsideStableVersionedASCIINamespace() throws {
        for key in [
            "spacing",
            "synthetic.spacing",
            "1synthetic.v1.spacing",
            "Synthetic.v1.spacing",
            "synthetic.v1.brush spacing",
            "synthetic.v1.brüsh",
            "synthetic.v1.",
            "synthetic..v1.spacing",
        ] {
            #expect(
                throws: ForeignBrushValidationError.invalidSemanticKey(key)
            ) {
                _ = try setting(
                    key,
                    domain: .scalar,
                    value: .scalar(1)
                )
            }
        }
        _ = try setting(
            "procreate.exported-container.v1.coverage.shapes[0]",
            domain: .scalar,
            value: .scalar(1)
        )
    }

    @Test
    func rejectsCumulativeDecodedPixelsBeyondPerBrushLimit() throws {
        let maximum = ForeignBrushLimits.maximumSourceImageDimension
        let resources = try [
            fixtureResource(
                id: "a",
                width: maximum,
                height: maximum
            ),
            fixtureResource(id: "b"),
        ]
        _ = try fixtureIR(resources: [resources[0]])
        #expect(
            throws: ForeignBrushValidationError
                .cumulativeDecodedPixelsExceeded(
                    maximum:
                        ForeignBrushLimits
                        .maximumCumulativeDecodedPixelsPerBrush
                )
        ) {
            _ = try fixtureIR(resources: resources)
        }
    }

    @Test
    func rejectsCumulativeEncodedResourceBytesBeforePayloadAllocation() throws {
        let resources = try (0..<5).map {
            try fixtureResource(
                id: String(format: "resource-%02d", $0),
                encodedByteCount:
                    ForeignBrushLimits.maximumEncodedResourceBytes
            )
        }
        _ = try fixtureIR(resources: Array(resources.prefix(4)))
        #expect(
            throws: ForeignBrushValidationError
                .cumulativeResourceBytesExceeded(
                    maximum:
                        ForeignBrushLimits.maximumCumulativeResourceBytes
                )
        ) {
            _ = try fixtureIR(resources: resources)
        }
    }
}

@Suite("Foreign brush setting values")
struct ForeignBrushSettingValueTests {
    @Test
    func rejectsNonFiniteNumbersAndInvalidCurves() throws {
        for number in [Double.nan, .infinity, -.infinity] {
            #expect(throws: ForeignBrushValidationError.nonFinite("setting.value.scalar")) {
                _ = try setting(
                    "synthetic.v1.scalar",
                    domain: .scalar,
                    value: .scalar(number)
                )
            }
            #expect(throws: ForeignBrushValidationError.nonFinite("setting.value.vector")) {
                _ = try setting(
                    "synthetic.v1.vector",
                    domain: .vector,
                    value: .vector([0, number])
                )
            }
        }
        #expect(throws: ForeignBrushValidationError.unsorted("setting.value.curve")) {
            _ = try setting(
                "synthetic.v1.curve",
                domain: .curve,
                value: .curve([
                    try ForeignBrushCurvePoint(x: 1, y: 1),
                    try ForeignBrushCurvePoint(x: 0, y: 0),
                ])
            )
        }
        #expect(
            throws: ForeignBrushValidationError.duplicate(
                field: "setting.value.curve",
                value: "0.0"
            )
        ) {
            _ = try setting(
                "synthetic.v1.curve",
                domain: .curve,
                value: .curve([
                    try ForeignBrushCurvePoint(x: 0, y: 0),
                    try ForeignBrushCurvePoint(x: 0, y: 1),
                ])
            )
        }
        let tooMany = try (0...ForeignBrushLimits.maximumCurvePointsPerSetting).map {
            try ForeignBrushCurvePoint(x: Double($0), y: 0)
        }
        #expect(
            throws: ForeignBrushValidationError.countOutOfRange(
                field: "setting.value.curve",
                actual: tooMany.count,
                maximum: ForeignBrushLimits.maximumCurvePointsPerSetting
            )
        ) {
            _ = try setting(
                "synthetic.v1.curve",
                domain: .curve,
                value: .curve(tooMany)
            )
        }
    }

    @Test
    func rejectsInvalidColorVectorTokenAndResourceReference() throws {
        #expect(throws: ForeignBrushValidationError.outOfRange("color.red")) {
            _ = try ForeignBrushColor(red: -0.01, green: 0, blue: 0, alpha: 1)
        }
        #expect(
            throws: ForeignBrushValidationError.countOutOfRange(
                field: "setting.value.vector",
                actual: 0,
                maximum: ForeignBrushLimits.maximumVectorComponents
            )
        ) {
            _ = try setting(
                "synthetic.v1.vector",
                domain: .vector,
                value: .vector([])
            )
        }
        #expect(
            throws: ForeignBrushValidationError.countOutOfRange(
                field: "setting.value.vector",
                actual: ForeignBrushLimits.maximumVectorComponents + 1,
                maximum: ForeignBrushLimits.maximumVectorComponents
            )
        ) {
            _ = try setting(
                "synthetic.v1.vector",
                domain: .vector,
                value: .vector(
                    [Double](
                        repeating: 0,
                        count:
                            ForeignBrushLimits.maximumVectorComponents + 1
                    )
                )
            )
        }
        #expect(throws: ForeignBrushValidationError.empty("setting.value.token")) {
            _ = try setting(
                "synthetic.v1.token",
                domain: .token,
                value: .token("")
            )
        }
        #expect(
            throws: ForeignBrushValidationError.controlCharacter(
                "setting.value.resourceReference"
            )
        ) {
            _ = try setting(
                "synthetic.v1.resource",
                domain: .resource,
                value: .resourceReference("bad\u{0000}id")
            )
        }
    }

    @Test
    func rejectsDomainAndUnitMismatches() throws {
        #expect(
            throws: ForeignBrushValidationError.domainMismatch(
                expected: .boolean,
                actual: .scalar
            )
        ) {
            _ = try setting(
                "synthetic.v1.boolean",
                domain: .scalar,
                value: .boolean(true)
            )
        }
        #expect(
            throws: ForeignBrushValidationError.unitMismatch(
                domain: .boolean,
                unit: .pixels
            )
        ) {
            _ = try setting(
                "synthetic.v1.boolean",
                unit: .pixels,
                domain: .boolean,
                value: .boolean(true)
            )
        }
    }
}

@Suite("Foreign brush resources and provenance")
struct ForeignBrushResourceTests {
    @Test
    func validatesProvenanceHashesPathsAndResourceBounds() throws {
        #expect(
            throws: ForeignBrushValidationError.invalidSHA256(
                "provenance.sourceContentSHA256"
            )
        ) {
            _ = try ForeignBrushProvenance(
                sourceFormatFamily: "synthetic",
                sourceFormatVersion: "1",
                sourceContentSHA256: "BAD",
                parserIdentifier: "test.parser",
                parserVersion: "1"
            )
        }
        #expect(throws: ForeignBrushValidationError.unsafeLocation("resource.containerLocation")) {
            _ = try fixtureResource(location: "../Shape.png")
        }
        #expect(throws: ForeignBrushValidationError.outOfRange("resource.pixelWidth")) {
            _ = try fixtureResource(
                width: ForeignBrushLimits.maximumSourceImageDimension + 1
            )
        }
        #expect(throws: ForeignBrushValidationError.outOfRange("resource.encodedByteCount")) {
            _ = try fixtureResource(
                encodedByteCount:
                    ForeignBrushLimits.maximumEncodedResourceBytes + 1
            )
        }
        for mediaType in [
            "image",
            "image/",
            "/png",
            "IMAGE/PNG",
            "image/png;profile=sRGB",
            "image/p ng",
        ] {
            #expect(
                throws: ForeignBrushValidationError.invalidMediaType(
                    mediaType
                )
            ) {
                _ = try fixtureResource(mediaType: mediaType)
            }
        }
        #expect(
            try fixtureResource(role: .unknown).role == .unknown
        )
    }

    @Test
    func rejectsInvalidSettingAndDiagnosticLocations() throws {
        #expect(throws: ForeignBrushValidationError.unsafeLocation("setting.location")) {
            _ = try setting(
                "synthetic.v1.bad",
                location: "/absolute/path",
                domain: .scalar,
                value: .scalar(1)
            )
        }
        #expect(throws: ForeignBrushValidationError.unsafeLocation("diagnostic.location")) {
            _ = try ForeignBrushDiagnostic(
                severity: .error,
                code: "badPath",
                location: "a/../../b",
                message: "Bad path"
            )
        }
    }
}

private func fixtureIR(
    sourceBrushIdentifier: String = "brush",
    displayName: String = "Brush",
    author: String? = nil,
    settings: [ForeignBrushSetting] = [],
    resources: [ForeignBrushResourceDescriptor] = [],
    diagnostics: [ForeignBrushDiagnostic] = []
) throws -> ForeignBrushIR {
    try ForeignBrushIR(
        provenance: fixtureProvenance(),
        sourceBrushIdentifier: sourceBrushIdentifier,
        displayName: displayName,
        author: author,
        settings: settings,
        resources: resources,
        diagnostics: diagnostics
    )
}

func fixtureProvenance() throws -> ForeignBrushProvenance {
    try ForeignBrushProvenance(
        sourceFormatFamily: "synthetic",
        sourceFormatVersion: "1",
        sourceContentSHA256: String(repeating: "a", count: 64),
        parserIdentifier: "laya.synthetic",
        parserVersion: "1"
    )
}

func fixtureResource(
    id: String = "shape.primary",
    role: ForeignBrushResourceRole = .shape,
    location: String = "Brush/Shape.png",
    mediaType: String = "image/png",
    hash: String = String(repeating: "b", count: 64),
    encodedByteCount: Int = 4,
    width: Int = 1,
    height: Int = 1
) throws -> ForeignBrushResourceDescriptor {
    try ForeignBrushResourceDescriptor(
        id: id,
        role: role,
        containerLocation: location,
        mediaType: mediaType,
        contentSHA256: hash,
        encodedByteCount: encodedByteCount,
        pixelWidth: width,
        pixelHeight: height,
        channelModel: .grayscale,
        colorInterpretation: .linear,
        inverted: false,
        orientation: .up
    )
}

func setting(
    _ key: String,
    location: String = "settings/value",
    unit: ForeignBrushSettingUnit = .unitless,
    domain: ForeignBrushSettingDomain,
    value: ForeignBrushSettingValue
) throws -> ForeignBrushSetting {
    try ForeignBrushSetting(
        semanticKey: key,
        unit: unit,
        domain: domain,
        location: location,
        value: value
    )
}
