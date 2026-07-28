import Foundation
import PatternEngine
import SafeArchive
import Testing
@testable import BrushFormat

@Test func conversionReportRoundTripsInsideVersionTwoPackage() throws {
    let package = try makeReportedPackage()
    let report = try #require(package.conversionReport)

    let first = try BrushPackageCodec.encode(package)
    let second = try BrushPackageCodec.encode(package)
    let decoded = try BrushPackageCodec.decode(first)

    #expect(first == second)
    #expect(decoded == package)
    #expect(decoded.manifest.schemaVersion == 2)
    #expect(decoded.conversionReport == report)
    #expect(
        try BrushFormatTestSupport.archiveEntries(decoded).keys.contains(
            BrushPackageConversionReportDescriptor.canonicalPath
        )
    )
}

@Test func versionOnePackageRemainsReadableWithoutReport() throws {
    let base = try BrushFormatTestSupport.package()
    let package = try BrushPackage(
        manifest: BrushPackageManifest(
            schemaVersion: 1,
            resources: base.manifest.resources
        ),
        definition: base.definition,
        resourceData: base.resourceData
    )

    let decoded = try BrushPackageCodec.decode(
        BrushPackageCodec.encode(package)
    )

    #expect(decoded == package)
    #expect(decoded.manifest.schemaVersion == 1)
    #expect(decoded.manifest.conversionReport == nil)
    #expect(decoded.conversionReport == nil)
    #expect(throws: BrushPackageError.invalidManifest(
        "schema v1 conversion report"
    )) {
        try BrushPackageManifest(
            schemaVersion: 1,
            resources: [],
            conversionReport: BrushPackageConversionReportDescriptor(
                report: makeConversionReport()
            )
        )
    }
}

@Test func frozenStageTwoVersionOneArchiveRemainsReadable() throws {
    let url = try #require(
        Bundle.module.url(
            forResource: "stage2-v1",
            withExtension: "layabrush",
            subdirectory: "Fixtures"
        )
    )
    let data = try Data(contentsOf: url)
    #expect(
        BrushContentHash.sha256Hex(of: data)
            == "12ab63f9c5588ccd7b625ebb41633221d7bc494e7f5fd21dd90f840efffbf98e"
    )

    let package = try BrushPackageCodec.decode(data)
    #expect(package.manifest.schemaVersion == 1)
    #expect(package.definition.id.rawValue == "fixture.stage2-v1")
    #expect(package.definition.metadata.displayName == "Stage 2 V1 Fixture")
    #expect(package.manifest.conversionReport == nil)
    #expect(package.conversionReport == nil)
}

@Test func reportDoesNotChangeRendererContentIdentity() throws {
    let reported = try makeReportedPackage()
    let plain = try BrushPackage(
        manifest: BrushPackageManifest(
            resources: reported.manifest.resources
        ),
        definition: reported.definition,
        resourceData: reported.resourceData
    )

    #expect(try reported.contentHash == plain.contentHash)
    #expect(reported != plain)
}

@Test func codecRejectsMissingTamperedAndUnexpectedReportEntries() throws {
    let package = try makeReportedPackage()
    var entries = try BrushFormatTestSupport.archiveEntries(package)
    entries.removeValue(
        forKey: BrushPackageConversionReportDescriptor.canonicalPath
    )
    #expect(throws: BrushPackageError.archive(.missingEntry(
        BrushPackageConversionReportDescriptor.canonicalPath
    ))) {
        try BrushPackageCodec.decode(
            BrushFormatTestSupport.encodeArchive(entries)
        )
    }

    entries = try BrushFormatTestSupport.archiveEntries(package)
    entries[BrushPackageConversionReportDescriptor.canonicalPath]!.append(0)
    #expect(throws: BrushPackageError.invalidConversionReport(
        .byteCountMismatch
    )) {
        try BrushPackageCodec.decode(
            BrushFormatTestSupport.encodeArchive(entries)
        )
    }

    entries = try BrushFormatTestSupport.archiveEntries(package)
    let reportPath =
        BrushPackageConversionReportDescriptor.canonicalPath
    var sameLengthTamper = entries[reportPath]!
    sameLengthTamper[sameLengthTamper.startIndex] ^= 1
    entries[reportPath] = sameLengthTamper
    #expect(throws: BrushPackageError.invalidConversionReport(
        .hashMismatch
    )) {
        try BrushPackageCodec.decode(
            BrushFormatTestSupport.encodeArchive(entries)
        )
    }

    entries = try BrushFormatTestSupport.archiveEntries(package)
    entries[reportPath] = Data(
        repeating: 0,
        count: BrushFormatLimits.maximumConversionReportBytes + 1
    )
    #expect(throws: BrushPackageError.invalidConversionReport(
        .byteCountMismatch
    )) {
        try BrushPackageCodec.decode(
            BrushFormatTestSupport.encodeArchive(entries)
        )
    }

    let plain = try BrushFormatTestSupport.package()
    entries = try BrushFormatTestSupport.archiveEntries(plain)
    entries[BrushPackageConversionReportDescriptor.canonicalPath] = Data(
        "{}".utf8
    )
    #expect(throws: BrushPackageError.unexpectedEntry(
        BrushPackageConversionReportDescriptor.canonicalPath
    )) {
        try BrushPackageCodec.decode(
            BrushFormatTestSupport.encodeArchive(entries)
        )
    }
}

@Test func codecRejectsForgedV1AndNoncanonicalReportPayloads() throws {
    let package = try makeReportedPackage()
    var entries = try BrushFormatTestSupport.archiveEntries(package)
    entries["manifest.json"] = Data(
        String(decoding: entries["manifest.json"]!, as: UTF8.self)
            .replacingOccurrences(
                of: "\"schemaVersion\":2",
                with: "\"schemaVersion\":1"
            )
            .utf8
    )
    #expect(throws: BrushPackageError.invalidManifest(
        "schema v1 conversion report"
    )) {
        try BrushPackageCodec.decode(
            BrushFormatTestSupport.encodeArchive(entries)
        )
    }

    entries = try BrushFormatTestSupport.archiveEntries(package)
    let reportPath =
        BrushPackageConversionReportDescriptor.canonicalPath
    let reportObject = try JSONSerialization.jsonObject(
        with: entries[reportPath]!
    )
    let noncanonical = try JSONSerialization.data(
        withJSONObject: reportObject,
        options: [.prettyPrinted]
    )
    entries[reportPath] = noncanonical
    var manifest = try #require(
        JSONSerialization.jsonObject(
            with: entries["manifest.json"]!
        ) as? [String: Any]
    )
    var descriptor = try #require(
        manifest["conversionReport"] as? [String: Any]
    )
    descriptor["sha256"] = BrushContentHash.sha256Hex(of: noncanonical)
    descriptor["encodedByteCount"] = noncanonical.count
    manifest["conversionReport"] = descriptor
    entries["manifest.json"] = try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.sortedKeys]
    )
    let noncanonicalArchive = try BrushFormatTestSupport.encodeArchive(entries)
    let decoded = try BrushPackageCodec.decode(noncanonicalArchive)
    #expect(decoded.conversionReport == package.conversionReport)
    #expect(try BrushPackageCodec.encode(decoded) == noncanonicalArchive)
}

@Test func preservedReportBytesMustMatchDecodedReport() throws {
    let package = try makeReportedPackage()
    let originalReport = try #require(package.conversionReport)
    let originalData = try BrushConversionReportCodec.encode(originalReport)
    let changedReport = try BrushConversionReport(
        sourceFormat: originalReport.sourceFormat,
        sourceVersion: originalReport.sourceVersion,
        sourceContentHash: originalReport.sourceContentHash,
        converterIdentifier: originalReport.converterIdentifier,
        converterVersion: "different",
        targetDefinitionID: originalReport.targetDefinitionID,
        targetPackageContentHash: originalReport.targetPackageContentHash,
        entries: originalReport.entries,
        diagnostics: originalReport.diagnostics
    )

    #expect(throws: BrushPackageError.invalidConversionReport(
        .decodedReportMismatch
    )) {
        try BrushPackage(
            manifest: package.manifest,
            definition: package.definition,
            resourceData: package.resourceData,
            conversionReport: changedReport,
            preservedConversionReportData: originalData
        )
    }
}

@Test func reportDescriptorAndJSONFailuresRemainBounded() throws {
    let hash = String(repeating: "a", count: 64)
    #expect(throws: BrushPackageError.invalidManifest(
        "conversion report byte count"
    )) {
        try BrushPackageConversionReportDescriptor(
            sha256: hash,
            encodedByteCount: BrushFormatLimits.maximumConversionReportBytes + 1
        )
    }
    #expect(throws: BrushPackageError.invalidManifest(
        "conversion report hash"
    )) {
        try BrushPackageConversionReportDescriptor(
            sha256: String(repeating: "A", count: 64),
            encodedByteCount: 1
        )
    }

    let report = try makeConversionReport()
    var object = try #require(
        JSONSerialization.jsonObject(
            with: BrushConversionReportCodec.encode(report)
        ) as? [String: Any]
    )
    var summary = try #require(object["summary"] as? [String: Any])
    summary["exact"] = 99
    object["summary"] = summary
    let tampered = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    #expect(throws: BrushConversionReportValidationError.invalidSummary) {
        try BrushConversionReportCodec.decode(tampered)
    }

    object["schemaVersion"] = 2
    let unsupportedSchema = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    #expect(throws: BrushConversionReportValidationError.unsupportedSchema(2)) {
        try BrushConversionReportCodec.decode(unsupportedSchema)
    }
}

@Test func reportRequiresSortedExhaustiveSemanticCoverage() throws {
    let first = try makeExactEntry(
        sourceKey: "synthetic.v1.a",
        nativeKey: "placement.baseFlow"
    )
    let second = try makeExactEntry(
        sourceKey: "synthetic.v1.b",
        nativeKey: "placement.baseSpacingFraction"
    )
    #expect(throws: BrushConversionReportValidationError.unsorted(
        "report.entries"
    )) {
        try makeConversionReport(entries: [second, first])
    }

    let definition = try BrushFormatTestSupport.definition(
        compatibility: BrushCompatibilityMetadata(
            nativeFeatureVersion: 1,
            sourceSettingKeys: ["synthetic.v1.a"],
            requiredSemanticKeys: []
        )
    )
    let report = try makeReportForDefinition(
        entries: [first, second],
        definition: definition
    )
    #expect(throws: BrushPackageError.invalidConversionReport(
        .validation(.sourceSettingCoverageMismatch)
    )) {
        try makeReportedPackage(
            definition: definition,
            reportOverride: report
        )
    }
}

@Test func requiredUnsupportedEntriesMustMatchDefinitionGate() throws {
    let unsupported = try BrushConversionEntry(
        sourceSemanticKey: "synthetic.v1.wetMix",
        nativeSemanticKeys: ["material.interaction"],
        disposition: .unsupported,
        sourceSummary: "enabled",
        targetSummary: nil,
        reasonCode: "backendUnavailable",
        message: "Wet Mix requires the canvas-interaction backend.",
        requiredForFaithfulRendering: true
    )
    let matching = try BrushFormatTestSupport.definition(
        compatibility: BrushCompatibilityMetadata(
            nativeFeatureVersion: 1,
            sourceSettingKeys: ["synthetic.v1.wetMix"],
            requiredSemanticKeys: ["synthetic.v1.wetMix"]
        )
    )
    let report = try makeReportForDefinition(
        entries: [unsupported],
        definition: matching
    )
    #expect(try makeReportedPackage(
        definition: matching,
        reportOverride: report
    ).conversionReport == report)

    let missingGate = try BrushFormatTestSupport.definition(
        compatibility: BrushCompatibilityMetadata(
            nativeFeatureVersion: 1,
            sourceSettingKeys: ["synthetic.v1.wetMix"],
            requiredSemanticKeys: []
        )
    )
    let missingGateReport = try makeReportForDefinition(
        entries: [unsupported],
        definition: missingGate
    )
    #expect(throws: BrushPackageError.invalidConversionReport(
        .validation(.requiredSemanticCoverageMismatch)
    )) {
        try makeReportedPackage(
            definition: missingGate,
            reportOverride: missingGateReport
        )
    }
}

@Test func reportIsBoundToTargetDefinitionAndPackageContent() throws {
    let package = try makeReportedPackage()
    let report = try #require(package.conversionReport)
    let changedDefinition = try BrushFormatTestSupport.definition(
        metadata: BrushMetadata(displayName: "Different Brush"),
        compatibility: package.definition.compatibility
    )

    #expect(throws: BrushPackageError.invalidConversionReport(
        .validation(.targetContentHashMismatch)
    )) {
        try makeReportedPackage(
            definition: changedDefinition,
            reportOverride: report
        )
    }
}

@Test func resourceTransformMustDescribeAnActualNativeResource() throws {
    let missingResourceTransform =
        try BrushConversionResourceTransformEvidence(
            resourceIdentifier: "missing.shape",
            sourceMediaType: "image/tiff",
            targetMediaType: "image/png",
            sourcePixelWidth: 4,
            sourcePixelHeight: 4,
            targetPixelWidth: 4,
            targetPixelHeight: 4,
            operations: [.transcode]
        )
    let entry = try BrushConversionEntry(
        sourceSemanticKey: "synthetic.v1.shape",
        nativeSemanticKeys: ["coverage.shapes[0]"],
        disposition: .resourceResampled,
        sourceSummary: "TIFF shape",
        targetSummary: "PNG shape",
        reasonCode: "normalizedResource",
        message: "The source shape was normalized.",
        resourceTransform: missingResourceTransform
    )
    let definition = try BrushFormatTestSupport.definition(
        compatibility: BrushCompatibilityMetadata(
            nativeFeatureVersion: 1,
            sourceSettingKeys: [entry.sourceSemanticKey],
            requiredSemanticKeys: []
        )
    )
    let report = try makeReportForDefinition(
        entries: [entry],
        definition: definition
    )

    #expect(throws: BrushPackageError.invalidConversionReport(
        .validation(.resourceTransformMismatch("missing.shape"))
    )) {
        try makeReportedPackage(
            definition: definition,
            reportOverride: report
        )
    }
}

@Test func reportRejectsUnknownAndMalformedNativeSemanticKeys() throws {
    for nativeKey in [
        "notARealDefinitionField",
        "coverage.shapes[[0]",
        "coverage.shapes[1]",
        "coverage.grains[0]",
        "coverage.shapes[99]",
        "material.interactionParameters.pickup",
        "replayLimits.maximumSamples",
    ] {
        let entry = try makeExactEntry(
            sourceKey: "synthetic.v1.setting",
            nativeKey: nativeKey
        )
        let definition = try BrushFormatTestSupport.definition(
            compatibility: BrushCompatibilityMetadata(
                nativeFeatureVersion: 1,
                sourceSettingKeys: [entry.sourceSemanticKey],
                requiredSemanticKeys: []
            )
        )
        let report = try makeReportForDefinition(
            entries: [entry],
            definition: definition
        )
        #expect(throws: BrushPackageError.invalidConversionReport(
            .validation(.unknownNativeSemanticKey(nativeKey))
        )) {
            try makeReportedPackage(
                definition: definition,
                reportOverride: report
            )
        }
    }
}

@Test func dispositionEvidenceIsStructuredAndFinite() throws {
    #expect(throws: BrushConversionReportValidationError.invalidEvidence(
        "entry.approximated"
    )) {
        try BrushConversionEntry(
            sourceSemanticKey: "synthetic.v1.spacing",
            nativeSemanticKeys: ["placement.baseSpacingFraction"],
            disposition: .approximated,
            sourceSummary: "10 percent",
            targetSummary: "0.1",
            reasonCode: "unitMapping",
            message: "Converted spacing units."
        )
    }
    #expect(throws: BrushConversionReportValidationError.nonfinite(
        "approximation.absoluteError"
    )) {
        try BrushConversionApproximationEvidence(
            metric: "absolute",
            absoluteError: .infinity
        )
    }
    #expect(throws: BrushConversionReportValidationError.invalidEvidence(
        "approximation.error"
    )) {
        try BrushConversionApproximationEvidence(metric: "absolute")
    }
    #expect(throws: BrushConversionReportValidationError.invalidToken(
        "entry.sourceSemanticKey"
    )) {
        try makeExactEntry(
            sourceKey: "synthetic.v1.späcing",
            nativeKey: "placement.baseSpacingFraction"
        )
    }
    #expect(throws: BrushConversionReportValidationError.unsorted(
        "resourceTransform.operations"
    )) {
        try BrushConversionResourceTransformEvidence(
            resourceIdentifier: "shape",
            sourceMediaType: "image/tiff",
            targetMediaType: "image/png",
            sourcePixelWidth: 4,
            sourcePixelHeight: 4,
            targetPixelWidth: 4,
            targetPixelHeight: 4,
            operations: [.transcode, .channelNormalization]
        )
    }
    #expect(throws: BrushConversionReportValidationError.invalidEvidence(
        "resourceTransform.resize"
    )) {
        try BrushConversionResourceTransformEvidence(
            resourceIdentifier: "shape",
            sourceMediaType: "image/png",
            targetMediaType: "image/png",
            sourcePixelWidth: 4,
            sourcePixelHeight: 4,
            targetPixelWidth: 4,
            targetPixelHeight: 4,
            operations: [.resize]
        )
    }
    #expect(throws: BrushConversionReportValidationError.invalidEvidence(
        "resourceTransform.dimensions"
    )) {
        try BrushConversionResourceTransformEvidence(
            resourceIdentifier: "shape",
            sourceMediaType: "image/png",
            targetMediaType: "image/png",
            sourcePixelWidth: 8,
            sourcePixelHeight: 8,
            targetPixelWidth: 4,
            targetPixelHeight: 4,
            operations: [.inversion]
        )
    }
    #expect(throws: BrushConversionReportValidationError.invalidEvidence(
        "resourceTransform.transcode"
    )) {
        try BrushConversionResourceTransformEvidence(
            resourceIdentifier: "shape",
            sourceMediaType: "image/tiff",
            targetMediaType: "image/png",
            sourcePixelWidth: 4,
            sourcePixelHeight: 4,
            targetPixelWidth: 4,
            targetPixelHeight: 4,
            operations: [.channelNormalization]
        )
    }
    #expect(throws: BrushConversionReportValidationError.invalidEvidence(
        "resourceTransform.orientationDimensions"
    )) {
        try BrushConversionResourceTransformEvidence(
            resourceIdentifier: "shape",
            sourceMediaType: "image/png",
            targetMediaType: "image/png",
            sourcePixelWidth: 8,
            sourcePixelHeight: 8,
            targetPixelWidth: 4,
            targetPixelHeight: 4,
            operations: [.orientationCorrection]
        )
    }
}

private func makeConversionReport(
    entries: [BrushConversionEntry]? = nil,
    targetDefinitionID: String = "test.package",
    targetPackageContentHash: String = String(repeating: "b", count: 64)
) throws -> BrushConversionReport {
    try BrushConversionReport(
        sourceFormat: "synthetic",
        sourceVersion: "1",
        sourceContentHash: String(repeating: "a", count: 64),
        converterIdentifier: "laya.brush-converter",
        converterVersion: "1",
        targetDefinitionID: targetDefinitionID,
        targetPackageContentHash: targetPackageContentHash,
        entries: entries ?? [
            makeExactEntry(
                sourceKey: "synthetic.v1.spacing",
                nativeKey: "placement.baseSpacingFraction"
            ),
        ],
        diagnostics: []
    )
}

private func makeExactEntry(
    sourceKey: String,
    nativeKey: String
) throws -> BrushConversionEntry {
    try BrushConversionEntry(
        sourceSemanticKey: sourceKey,
        nativeSemanticKeys: [nativeKey],
        disposition: .exact,
        sourceSummary: "0.125",
        targetSummary: "0.125",
        reasonCode: "sameSemantic",
        message: "The source and native settings have the same semantic."
    )
}

private func makeReportedPackage(
    entries: [BrushConversionEntry]? = nil,
    definition: BrushDefinition? = nil,
    reportOverride: BrushConversionReport? = nil
) throws -> BrushPackage {
    let base = try BrushFormatTestSupport.package()
    let entries = try entries
        ?? reportOverride?.entries
        ?? [
            makeExactEntry(
                sourceKey: "synthetic.v1.spacing",
                nativeKey: "placement.baseSpacingFraction"
            ),
        ]
    let definition = try definition ?? BrushFormatTestSupport.definition(
        compatibility: BrushCompatibilityMetadata(
            nativeFeatureVersion: 1,
            sourceSettingKeys: entries.map(\.sourceSemanticKey),
            requiredSemanticKeys: entries.compactMap {
                $0.disposition == .unsupported
                    && $0.requiredForFaithfulRendering
                    ? $0.sourceSemanticKey
                    : nil
            }
        )
    )
    let report = try reportOverride ?? makeReportForDefinition(
        entries: entries,
        definition: definition,
        base: base
    )
    return try BrushPackage(
        manifest: BrushPackageManifest(
            resources: base.manifest.resources,
            provenance: BrushPackageProvenance(
                buildTool: "layabrush-convert",
                sourceApplication: "Synthetic",
                sourceVersion: "1"
            ),
            conversionReport: BrushPackageConversionReportDescriptor(
                report: report
            )
        ),
        definition: definition,
        resourceData: base.resourceData,
        conversionReport: report
    )
}

private func makeReportForDefinition(
    entries: [BrushConversionEntry],
    definition: BrushDefinition,
    base: BrushPackage? = nil
) throws -> BrushConversionReport {
    let base = try base ?? BrushFormatTestSupport.package()
    let plain = try BrushPackage(
        manifest: BrushPackageManifest(resources: base.manifest.resources),
        definition: definition,
        resourceData: base.resourceData
    )
    return try makeConversionReport(
        entries: entries,
        targetDefinitionID: definition.id.rawValue,
        targetPackageContentHash: plain.contentHash
    )
}
