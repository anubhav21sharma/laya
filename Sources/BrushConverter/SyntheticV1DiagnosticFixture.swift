import Foundation

/// Project-owned source bytes for converter and activation integration tests.
public enum SyntheticV1DiagnosticFixture {
    private static let shapeData = Data([0, 64, 128, 255])
    private static let grainData = Data([255, 128, 64, 1])

    public static func source(includeWet: Bool) throws -> Data {
        try SyntheticV1BrushParser().encode(
            document(includeWet: includeWet)
        )
    }

    private static func document(
        includeWet: Bool
    ) throws -> ForeignBrushDocument {
        let shape = try resource(
            id: "shape.synthetic",
            role: .shape,
            location: "Resources/shape.r8",
            data: shapeData
        )
        let grain = try resource(
            id: "grain.synthetic",
            role: .grain,
            location: "Resources/grain.r8",
            data: grainData
        )
        let provenance = try ForeignBrushProvenance(
            sourceFormatFamily: SyntheticV1BrushParser.sourceFormatFamily,
            sourceFormatVersion: SyntheticV1BrushParser.sourceFormatVersion,
            sourceContentSHA256: String(repeating: "0", count: 64),
            parserIdentifier: SyntheticV1BrushParser.parserIdentifier,
            parserVersion: SyntheticV1BrushParser.parserVersion
        )
        let ir = try ForeignBrushIR(
            provenance: provenance,
            sourceBrushIdentifier: "diagnostic-brush",
            displayName: "Synthetic Diagnostic Brush",
            author: "Laya",
            settings: settings(includeWet: includeWet),
            resources: [grain, shape],
            diagnostics: []
        )
        return try ForeignBrushDocument(
            ir: ir,
            resourceData: [
                grain.id: grainData,
                shape.id: shapeData,
            ]
        )
    }

    private static func settings(
        includeWet: Bool
    ) throws -> [ForeignBrushSetting] {
        var values = try [
            setting(
                SyntheticV1SemanticKeys.accumulation,
                domain: .token,
                value: .token("uniform-glaze")
            ),
            setting(
                SyntheticV1SemanticKeys.flow,
                unit: .normalized,
                domain: .scalar,
                value: .scalar(0.625)
            ),
            setting(
                SyntheticV1SemanticKeys.grain,
                domain: .resource,
                value: .resourceReference("grain.synthetic")
            ),
            setting(
                SyntheticV1SemanticKeys.opacity,
                unit: .normalized,
                domain: .scalar,
                value: .scalar(0.75)
            ),
            setting(
                SyntheticV1SemanticKeys.rotation,
                unit: .degrees,
                domain: .scalar,
                value: .scalar(90)
            ),
            setting(
                SyntheticV1SemanticKeys.scatter,
                unit: .normalized,
                domain: .scalar,
                value: .scalar(0.25)
            ),
            setting(
                SyntheticV1SemanticKeys.shape,
                domain: .resource,
                value: .resourceReference("shape.synthetic")
            ),
            setting(
                SyntheticV1SemanticKeys.sizePressure,
                unit: .normalized,
                domain: .curve,
                value: .curve([
                    ForeignBrushCurvePoint(x: 0, y: 0.25),
                    ForeignBrushCurvePoint(x: 1, y: 1),
                ])
            ),
            setting(
                SyntheticV1SemanticKeys.spacing,
                unit: .normalized,
                domain: .vector,
                value: .vector([0.125, 0.375])
            ),
        ]
        if includeWet {
            values.append(
                try setting(
                    SyntheticV1SemanticKeys.wet,
                    domain: .boolean,
                    value: .boolean(true)
                )
            )
        }
        return values.sorted { $0.semanticKey < $1.semanticKey }
    }

    private static func setting(
        _ key: String,
        unit: ForeignBrushSettingUnit = .unitless,
        domain: ForeignBrushSettingDomain,
        value: ForeignBrushSettingValue
    ) throws -> ForeignBrushSetting {
        try ForeignBrushSetting(
            semanticKey: key,
            unit: unit,
            domain: domain,
            location: "Settings/\(key)",
            value: value
        )
    }

    private static func resource(
        id: String,
        role: ForeignBrushResourceRole,
        location: String,
        data: Data
    ) throws -> ForeignBrushResourceDescriptor {
        try ForeignBrushResourceDescriptor(
            id: id,
            role: role,
            containerLocation: location,
            mediaType: SyntheticV1BrushParser.rawGrayscaleMediaType,
            contentSHA256: ForeignBrushDocument.contentSHA256(data),
            encodedByteCount: data.count,
            pixelWidth: 2,
            pixelHeight: 2,
            channelModel: .grayscale,
            colorInterpretation: .linear,
            inverted: false,
            orientation: .up
        )
    }
}
