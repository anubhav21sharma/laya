import BrushFormat
import CoreFoundation
import Foundation
import ImageIO
import PatternEngine
import Testing
@testable import BrushConverter

@Suite("Synthetic v1 brush mapper")
struct SyntheticV1BrushMapperTests {
    @Test
    func mapsEveryDrySettingAndRoundTripsTheReportedPackage() throws {
        let document = try syntheticDocument()

        let result = try SyntheticV1BrushMapper().map(document)
        let definition = result.package.definition

        #expect(definition.compatibility.sourceSettingKeys == SyntheticV1SemanticKeys.dry)
        #expect(definition.compatibility.requiredSemanticKeys == [])
        #expect(definition.coverage.shapes[0].shape == .asset("shape.synthetic"))
        #expect(definition.coverage.grains[0].grain == .asset("grain.synthetic"))
        #expect(definition.placement.baseSpacingFraction == 0.125)
        #expect(definition.placement.maximumSpacingFraction == 0.375)
        #expect(definition.placement.baseFlow == 0.625)
        #expect(definition.placement.strokeOpacity == 0.75)
        #expect(definition.placement.baseScatterFraction == 0.25)
        #expect(abs(definition.placement.baseRotation - (.pi / 2)) < 0.000_001)
        #expect(definition.material.accumulation == .uniformGlaze)
        #expect(definition.dynamics.size.input == .pressure)
        #expect(definition.dynamics.size.response == .linear)
        #expect(definition.dynamics.size.offset == 0.25)
        #expect(definition.dynamics.size.scale == 0.75)
        #expect(definition.dynamics.size.lowerClamp == 0.25)
        #expect(definition.dynamics.size.upperClamp == 1)

        let report = result.report
        #expect(report.entries.map(\.sourceSemanticKey) == SyntheticV1SemanticKeys.dry)
        #expect(report.summary.exact == SyntheticV1SemanticKeys.dry.count - 2)
        #expect(report.summary.approximated == 0)
        #expect(report.summary.unsupported == 0)
        #expect(report.summary.resourceResampled == 2)
        #expect(
            report.entries.first {
                $0.sourceSemanticKey
                    == SyntheticV1SemanticKeys.accumulation
            }?.nativeSemanticKeys
                == ["material.accumulation", "material.edgeTreatment"]
        )
        let packageHash = try result.package.contentHash
        #expect(report.targetPackageContentHash == packageHash)

        let archive = try BrushPackageCodec.encode(result.package)
        let decoded = try BrushPackageCodec.decode(archive)
        #expect(decoded == result.package)
        #expect(decoded.conversionReport == report)
        #expect(decoded.manifest.schemaVersion == 2)
    }

    @Test
    func retainsUnsupportedWetAndRoundTripsWithoutClaimingAMapping() throws {
        let result = try SyntheticV1BrushMapper().map(
            syntheticDocument(includeWet: true)
        )

        #expect(
            result.package.definition.compatibility.sourceSettingKeys
                == SyntheticV1SemanticKeys.all
        )
        #expect(
            result.package.definition.compatibility.requiredSemanticKeys
                == [SyntheticV1SemanticKeys.wet]
        )
        #expect(result.package.definition.material.interaction == .wetMix)
        #expect(
            result.package.definition.capabilities
                == [
                    BrushCapabilityDeclaration(
                        identifier: BrushCapability.wetMix.rawValue,
                        required: true
                    ),
                ]
        )
        #expect(
            result.package.definition.material.interactionParameters != nil
        )
        let wet = try #require(
            result.report.entries.first {
                $0.sourceSemanticKey == SyntheticV1SemanticKeys.wet
            }
        )
        #expect(wet.disposition == .unsupported)
        #expect(
            wet.nativeSemanticKeys
                == [
                    "capabilities",
                    "material.interaction",
                    "material.interactionParameters",
                ]
        )
        #expect(wet.targetSummary != nil)
        #expect(wet.requiredForFaithfulRendering)
        #expect(result.report.summary.unsupported == 1)

        let decoded = try BrushPackageCodec.decode(
            BrushPackageCodec.encode(result.package)
        )
        #expect(decoded == result.package)
        #expect(
            decoded.definition.compatibility.requiredSemanticKeys
                == [SyntheticV1SemanticKeys.wet]
        )
    }

    @Test
    func mapsDeterministically() throws {
        let document = try syntheticDocument()
        let first = try SyntheticV1BrushMapper().map(document)
        let second = try SyntheticV1BrushMapper().map(document)

        #expect(first == second)
        #expect(
            try BrushPackageCodec.encode(first.package)
                == BrushPackageCodec.encode(second.package)
        )
    }

    @Test
    func rejectsMismatchedParserIdentityAndForeignSettingNamespace() throws {
        let mismatched = try ForeignBrushProvenance(
            sourceFormatFamily: SyntheticV1BrushParser.sourceFormatFamily,
            sourceFormatVersion: SyntheticV1BrushParser.sourceFormatVersion,
            sourceContentSHA256: String(repeating: "a", count: 64),
            parserIdentifier: "other.synthetic-parser",
            parserVersion: SyntheticV1BrushParser.parserVersion
        )
        #expect(
            throws: SyntheticV1MappingError.unsupportedParser(
                identifier: "other.synthetic-parser",
                version: SyntheticV1BrushParser.parserVersion
            )
        ) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(provenance: mismatched)
            )
        }

        var foreignSettings = try syntheticSettings()
        foreignSettings.append(
            try syntheticSetting(
                "foreign.v1.unexpected",
                unit: .normalized,
                domain: .scalar,
                value: .scalar(0.5)
            )
        )
        foreignSettings.sort { $0.semanticKey < $1.semanticKey }
        #expect(
            throws: SyntheticV1MappingError
                .unexpectedSettingNamespace("foreign.v1.unexpected")
        ) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(settings: foreignSettings)
            )
        }
    }

    @Test
    func rejectsMissingWrongContractAndOutOfRangeSettings() throws {
        let valid = try syntheticSettings()

        #expect(throws: SyntheticV1MappingError.self) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(
                    settings: valid.filter {
                        $0.semanticKey != SyntheticV1SemanticKeys.opacity
                    }
                )
            )
        }

        let wideSpacing = try SyntheticV1BrushMapper().map(
            syntheticDocument(
                replacing: SyntheticV1SemanticKeys.spacing,
                with: try syntheticSetting(
                    SyntheticV1SemanticKeys.spacing,
                    unit: .normalized,
                    domain: .vector,
                    value: .vector([1.25, 3.5])
                )
            )
        )
        #expect(
            wideSpacing.package.definition.placement.baseSpacingFraction
                == 1.25
        )
        #expect(
            wideSpacing.package.definition.placement.maximumSpacingFraction
                == 3.5
        )

        #expect(throws: SyntheticV1MappingError.self) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(
                    replacing: SyntheticV1SemanticKeys.spacing,
                    with: try syntheticSetting(
                        SyntheticV1SemanticKeys.spacing,
                        unit: .normalized,
                        domain: .vector,
                        value: .vector([1.25, 4.25])
                    )
                )
            )
        }

        var unknown = valid
        unknown.append(
            try syntheticSetting(
                "synthetic.v1.unexpected",
                unit: .normalized,
                domain: .scalar,
                value: .scalar(0.5)
            )
        )
        unknown.sort { $0.semanticKey < $1.semanticKey }
        let retained = try SyntheticV1BrushMapper().map(
            syntheticDocument(settings: unknown)
        )
        let unsupported = try #require(
            retained.report.entries.first {
                $0.sourceSemanticKey == "synthetic.v1.unexpected"
            }
        )
        #expect(unsupported.disposition == .unsupported)
        #expect(unsupported.requiredForFaithfulRendering)
        #expect(
            retained.package.definition.compatibility.requiredSemanticKeys
                == ["synthetic.v1.unexpected"]
        )

        let unknownBytes = Data([42])
        let unknownResource = try syntheticResource(
            id: "source-only.synthetic",
            role: .auxiliary,
            location: "Resources/source-only.r8",
            mediaType: ForeignBrushResourceNormalizer.syntheticR8MediaType,
            bytes: unknownBytes,
            width: 1,
            height: 1
        )
        var unknownResourceSettings = valid
        unknownResourceSettings.append(
            try syntheticSetting(
                "synthetic.v1.unknown-resource",
                domain: .resource,
                value: .resourceReference(unknownResource.id)
            )
        )
        unknownResourceSettings.sort { $0.semanticKey < $1.semanticKey }
        let retainedResource = try SyntheticV1BrushMapper().map(
            syntheticDocument(
                settings: unknownResourceSettings,
                extraResources: [(unknownResource, unknownBytes)]
            )
        )
        #expect(
            retainedResource.report.entries.first {
                $0.sourceSemanticKey
                    == "synthetic.v1.unknown-resource"
            }?.disposition == .unsupported
        )
        #expect(
            retainedResource.package.manifest.resources.map(\.id)
                == ["grain.synthetic", "shape.synthetic"]
        )

        #expect(throws: SyntheticV1MappingError.self) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(
                    replacing: SyntheticV1SemanticKeys.flow,
                    with: try syntheticSetting(
                        SyntheticV1SemanticKeys.flow,
                        unit: .degrees,
                        domain: .scalar,
                        value: .scalar(0.5)
                    )
                )
            )
        }

        #expect(throws: SyntheticV1MappingError.self) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(
                    replacing: SyntheticV1SemanticKeys.opacity,
                    with: try syntheticSetting(
                        SyntheticV1SemanticKeys.opacity,
                        unit: .normalized,
                        domain: .scalar,
                        value: .scalar(1.01)
                    )
                )
            )
        }

        #expect(throws: SyntheticV1MappingError.self) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(
                    replacing: SyntheticV1SemanticKeys.spacing,
                    with: try syntheticSetting(
                        SyntheticV1SemanticKeys.spacing,
                        unit: .normalized,
                        domain: .vector,
                        value: .vector([0.5, 0.25])
                    )
                )
            )
        }

        #expect(throws: SyntheticV1MappingError.self) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(
                    replacing: SyntheticV1SemanticKeys.sizePressure,
                    with: try syntheticSetting(
                        SyntheticV1SemanticKeys.sizePressure,
                        unit: .normalized,
                        domain: .curve,
                        value: .curve([
                            try ForeignBrushCurvePoint(x: 0, y: 1),
                            try ForeignBrushCurvePoint(x: 1, y: 0.25),
                        ])
                    )
                )
            )
        }
    }

    @Test
    func rejectsFalseWetAndUnexpectedResources() throws {
        #expect(throws: SyntheticV1MappingError.self) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(
                    includeWet: true,
                    replacing: SyntheticV1SemanticKeys.wet,
                    with: try syntheticSetting(
                        SyntheticV1SemanticKeys.wet,
                        domain: .boolean,
                        value: .boolean(false)
                    )
                )
            )
        }

        let bytes = Data([0])
        let extra = try syntheticResource(
            id: "extra",
            role: .auxiliary,
            location: "Resources/extra.r8",
            mediaType: ForeignBrushResourceNormalizer.syntheticR8MediaType,
            bytes: bytes,
            width: 1,
            height: 1
        )
        #expect(throws: SyntheticV1MappingError.self) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(extraResources: [(extra, bytes)])
            )
        }
    }
}

@Suite("Synthetic v1 resource normalization")
struct SyntheticV1ResourceNormalizationTests {
    @Test
    func normalizesOwnedR8WithOrientationAndInversionDeterministically() throws {
        let raw = Data([0, 1, 2, 3, 4, 5])
        let shape = try syntheticResource(
            id: "shape.synthetic",
            role: .shape,
            location: "Resources/shape.r8",
            mediaType: ForeignBrushResourceNormalizer.syntheticR8MediaType,
            bytes: raw,
            width: 2,
            height: 3,
            inverted: true,
            orientation: .right
        )
        let document = try syntheticDocument(
            shape: (shape, raw)
        )

        let first = try SyntheticV1BrushMapper().map(document)
        let second = try SyntheticV1BrushMapper().map(document)
        let bytes = try #require(
            first.package.resourceData["shape.synthetic"]
        )
        #expect(bytes == second.package.resourceData["shape.synthetic"])
        #expect(bytes.prefix(4) == Data([0x49, 0x49, 0x2A, 0x00]))
        #expect(bytes.suffix(6) == Data([251, 253, 255, 250, 252, 254]))

        let resource = try #require(
            first.package.manifest.resources.first {
                $0.id == "shape.synthetic"
            }
        )
        #expect(resource.mediaType == "image/tiff")
        #expect(resource.pixelWidth == 3)
        #expect(resource.pixelHeight == 2)

        let entry = try #require(
            first.report.entries.first {
                $0.sourceSemanticKey == SyntheticV1SemanticKeys.shape
            }
        )
        #expect(entry.disposition == .resourceResampled)
        #expect(
            entry.resourceTransform?.operations
                == [.inversion, .orientationCorrection, .transcode]
        )
        #expect(entry.resourceTransform?.targetPixelWidth == 3)
        #expect(entry.resourceTransform?.targetPixelHeight == 2)
    }

    @Test
    func rejectsRoleMismatchMalformedNativeBytesAndOversizedNativeDimensions()
        throws
    {
        let wrongRole = try syntheticResource(
            id: "shape.synthetic",
            role: .grain,
            location: "Resources/shape.r8",
            mediaType: ForeignBrushResourceNormalizer.syntheticR8MediaType,
            bytes: syntheticShapeR8,
            width: 2,
            height: 2
        )
        #expect(throws: SyntheticV1MappingError.self) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(shape: (wrongRole, syntheticShapeR8))
            )
        }

        let malformed = Data([0, 1, 2])
        let malformedResource = try syntheticResource(
            id: "shape.synthetic",
            role: .shape,
            location: "Resources/shape.r8",
            mediaType: ForeignBrushResourceNormalizer.syntheticR8MediaType,
            bytes: malformed,
            width: 2,
            height: 2
        )
        #expect(throws: SyntheticV1MappingError.self) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(shape: (malformedResource, malformed))
            )
        }

        let oversized = try syntheticResource(
            id: "shape.synthetic",
            role: .shape,
            location: "Resources/shape.r8",
            mediaType: ForeignBrushResourceNormalizer.syntheticR8MediaType,
            bytes: syntheticShapeR8,
            width: BrushFormatLimits.maximumImageDimension + 1,
            height: 2
        )
        #expect(throws: SyntheticV1MappingError.self) {
            _ = try SyntheticV1BrushMapper().map(
                syntheticDocument(shape: (oversized, syntheticShapeR8))
            )
        }
    }

    @Test
    func rejectsKnownOversizedTIFFBeforeRawPixelAllocation() throws {
        let tinyPayload = Data([0])
        let descriptor = try syntheticResource(
            id: "shape.synthetic",
            role: .shape,
            location: "Resources/shape.r8",
            mediaType: ForeignBrushResourceNormalizer.syntheticR8MediaType,
            bytes: tinyPayload,
            width: BrushFormatLimits.maximumImageDimension,
            height: BrushFormatLimits.maximumImageDimension
        )

        #expect(
            throws: SyntheticV1MappingError.unsupportedResource(
                resourceID: descriptor.id,
                reason: "native-byte-limit"
            )
        ) {
            _ = try ForeignBrushResourceNormalizer.normalize(
                descriptor,
                data: tinyPayload,
                kind: .shape
            )
        }
    }

    @Test
    func correctsAllEightOrientationsAndProducesDecodableStableTIFFs()
        throws
    {
        let source = Data([0, 1, 2, 3, 4, 5])
        let cases: [(
            ForeignBrushImageOrientation,
            Int,
            Int,
            [UInt8]
        )] = [
            (.up, 2, 3, [0, 1, 2, 3, 4, 5]),
            (.down, 2, 3, [5, 4, 3, 2, 1, 0]),
            (.left, 3, 2, [1, 3, 5, 0, 2, 4]),
            (.right, 3, 2, [4, 2, 0, 5, 3, 1]),
            (.upMirrored, 2, 3, [1, 0, 3, 2, 5, 4]),
            (.downMirrored, 2, 3, [4, 5, 2, 3, 0, 1]),
            (.leftMirrored, 3, 2, [0, 2, 4, 1, 3, 5]),
            (.rightMirrored, 3, 2, [5, 3, 1, 4, 2, 0]),
        ]

        for (orientation, width, height, expected) in cases {
            let descriptor = try syntheticResource(
                id: "shape.synthetic",
                role: .shape,
                location: "Resources/shape.r8",
                mediaType:
                    ForeignBrushResourceNormalizer.syntheticR8MediaType,
                bytes: source,
                width: 2,
                height: 3,
                orientation: orientation
            )
            let first = try ForeignBrushResourceNormalizer.normalize(
                descriptor,
                data: source,
                kind: .shape
            )
            let second = try ForeignBrushResourceNormalizer.normalize(
                descriptor,
                data: source,
                kind: .shape
            )
            #expect(first == second)
            #expect(first.descriptor.pixelWidth == width)
            #expect(first.descriptor.pixelHeight == height)
            #expect(first.data.suffix(6) == Data(expected))
            let imageSource = CGImageSourceCreateWithData(
                first.data as CFData,
                nil
            )
            #expect(imageSource != nil)
            #expect(
                imageSource.flatMap {
                    CGImageSourceCreateImageAtIndex($0, 0, nil)
                } != nil
            )
        }
    }

    @Test
    func appliesInversionWithoutOrientationCorrection() throws {
        let source = Data([0, 1, 2, 3, 4, 5])
        let descriptor = try syntheticResource(
            id: "shape.synthetic",
            role: .shape,
            location: "Resources/shape.r8",
            mediaType: ForeignBrushResourceNormalizer.syntheticR8MediaType,
            bytes: source,
            width: 2,
            height: 3,
            inverted: true
        )
        let normalized = try ForeignBrushResourceNormalizer.normalize(
            descriptor,
            data: source,
            kind: .shape
        )

        #expect(
            normalized.data.suffix(6)
                == Data([255, 254, 253, 252, 251, 250])
        )
        #expect(
            normalized.transform?.operations == [.inversion, .transcode]
        )
    }
}

@Suite("Synthetic v1 parser")
struct SyntheticV1BrushParserTests {
    @Test
    func deterministicEnvelopeProbesAndParses() throws {
        let parser = SyntheticV1BrushParser()
        let document = try syntheticDocument(includeWet: true)

        let first = try parser.encode(document)
        let second = try parser.encode(document)
        #expect(first == second)
        #expect(try parser.probe(first))
        let parsed = try #require(try parser.parse(first).first)
        #expect(parsed.ir.settings == document.ir.settings)
        #expect(parsed.ir.resources == document.ir.resources)
        #expect(parsed.resourceData == document.resourceData)
        #expect(
            parsed.ir.provenance.sourceContentSHA256
                == ForeignBrushDocument.contentSHA256(first)
        )
        #expect(try parser.parse(Data("not synthetic".utf8)).isEmpty)
    }

    @Test
    func exactSourceHashAndDiagnosticsSurviveMapAndArchiveWithoutPayloadLeak()
        throws
    {
        let diagnostic = try ForeignBrushDiagnostic(
            severity: .warning,
            code: "source-warning",
            location: "Settings/notice",
            message: "Synthetic source warning."
        )
        let boundaryDiagnostic = try ForeignBrushDiagnostic(
            severity: .information,
            code: String(
                repeating: "a",
                count: ForeignBrushLimits.maximumDiagnosticCodeUTF8Bytes
            ),
            location: String(
                repeating: "z",
                count: ForeignBrushLimits.maximumLocationUTF8Bytes
            ),
            message: String(
                repeating: "m",
                count: ForeignBrushLimits.maximumDiagnosticMessageUTF8Bytes
            )
        )
        let secret = Data("SECRET".utf8)
        let shape = try syntheticResource(
            id: "shape.synthetic",
            role: .shape,
            location: "Resources/shape.r8",
            mediaType: ForeignBrushResourceNormalizer.syntheticR8MediaType,
            bytes: secret,
            width: 2,
            height: 3
        )
        let parser = SyntheticV1BrushParser()
        let encoded = try parser.encode(
            syntheticDocument(
                shape: (shape, secret),
                diagnostics: [diagnostic, boundaryDiagnostic].sorted {
                    $0.stableIdentity < $1.stableIdentity
                }
            )
        )
        let parsed = try #require(try parser.parse(encoded).first)
        let result = try SyntheticV1BrushMapper().map(parsed)

        #expect(
            result.report.sourceContentHash
                == ForeignBrushDocument.contentSHA256(encoded)
        )
        #expect(result.report.diagnostics.count == 2)
        let preserved = try #require(
            result.report.diagnostics.first {
                $0.code == diagnostic.code
            }
        )
        #expect(preserved.severity == .warning)
        #expect(preserved.message == diagnostic.message)
        #expect(preserved.location == diagnostic.location)
        let preservedBoundary = try #require(
            result.report.diagnostics.first {
                $0.code == boundaryDiagnostic.code
            }
        )
        #expect(preservedBoundary.severity == .info)
        #expect(preservedBoundary.message == boundaryDiagnostic.message)
        #expect(preservedBoundary.location == boundaryDiagnostic.location)
        let reportJSON = try JSONEncoder().encode(result.report)
        #expect(!reportJSON.contains(Data("U0VDUkVU".utf8)))
        #expect(!reportJSON.contains(Data("SECRET".utf8)))

        let decoded = try BrushPackageCodec.decode(
            BrushPackageCodec.encode(result.package)
        )
        #expect(decoded.conversionReport?.diagnostics == result.report.diagnostics)
    }
}

private let syntheticShapeR8 = Data([0, 64, 128, 255])
private let syntheticGrainR8 = Data([255, 128, 64, 1])

private func syntheticDocument(
    includeWet: Bool = false,
    settings: [ForeignBrushSetting]? = nil,
    shape: (ForeignBrushResourceDescriptor, Data)? = nil,
    extraResources: [(ForeignBrushResourceDescriptor, Data)] = [],
    diagnostics: [ForeignBrushDiagnostic] = [],
    provenance: ForeignBrushProvenance? = nil
) throws -> ForeignBrushDocument {
    let shape = try shape ?? (
        syntheticResource(
            id: "shape.synthetic",
            role: .shape,
            location: "Resources/shape.r8",
            mediaType: ForeignBrushResourceNormalizer.syntheticR8MediaType,
            bytes: syntheticShapeR8,
            width: 2,
            height: 2
        ),
        syntheticShapeR8
    )
    let grain = try (
        syntheticResource(
            id: "grain.synthetic",
            role: .grain,
            location: "Resources/grain.r8",
            mediaType: ForeignBrushResourceNormalizer.syntheticR8MediaType,
            bytes: syntheticGrainR8,
            width: 2,
            height: 2
        ),
        syntheticGrainR8
    )
    var resources = [shape.0, grain.0]
    resources.append(contentsOf: extraResources.map(\.0))
    resources.sort { $0.id < $1.id }
    var resourceData = [
        shape.0.id: shape.1,
        grain.0.id: grain.1,
    ]
    for item in extraResources {
        resourceData[item.0.id] = item.1
    }

    let settings = try settings ?? syntheticSettings(includeWet: includeWet)
    let provenance = try provenance ?? ForeignBrushProvenance(
        sourceFormatFamily: SyntheticV1BrushParser.sourceFormatFamily,
        sourceFormatVersion: SyntheticV1BrushParser.sourceFormatVersion,
        sourceContentSHA256: String(repeating: "a", count: 64),
        parserIdentifier: SyntheticV1BrushParser.parserIdentifier,
        parserVersion: SyntheticV1BrushParser.parserVersion
    )
    let ir = try ForeignBrushIR(
        provenance: provenance,
        sourceBrushIdentifier: "fixture-brush",
        displayName: "Synthetic Fixture",
        author: "Laya Tests",
        settings: settings,
        resources: resources,
        diagnostics: diagnostics
    )
    return try ForeignBrushDocument(ir: ir, resourceData: resourceData)
}

private func syntheticDocument(
    includeWet: Bool = false,
    replacing key: String,
    with replacement: ForeignBrushSetting
) throws -> ForeignBrushDocument {
    var settings = try syntheticSettings(includeWet: includeWet)
    settings.removeAll { $0.semanticKey == key }
    settings.append(replacement)
    settings.sort { $0.semanticKey < $1.semanticKey }
    return try syntheticDocument(
        includeWet: includeWet,
        settings: settings
    )
}

private func syntheticSettings(
    includeWet: Bool = false
) throws -> [ForeignBrushSetting] {
    var settings = try [
        syntheticSetting(
            SyntheticV1SemanticKeys.accumulation,
            domain: .token,
            value: .token("uniform-glaze")
        ),
        syntheticSetting(
            SyntheticV1SemanticKeys.flow,
            unit: .normalized,
            domain: .scalar,
            value: .scalar(0.625)
        ),
        syntheticSetting(
            SyntheticV1SemanticKeys.grain,
            domain: .resource,
            value: .resourceReference("grain.synthetic")
        ),
        syntheticSetting(
            SyntheticV1SemanticKeys.opacity,
            unit: .normalized,
            domain: .scalar,
            value: .scalar(0.75)
        ),
        syntheticSetting(
            SyntheticV1SemanticKeys.rotation,
            unit: .degrees,
            domain: .scalar,
            value: .scalar(90)
        ),
        syntheticSetting(
            SyntheticV1SemanticKeys.scatter,
            unit: .normalized,
            domain: .scalar,
            value: .scalar(0.25)
        ),
        syntheticSetting(
            SyntheticV1SemanticKeys.shape,
            domain: .resource,
            value: .resourceReference("shape.synthetic")
        ),
        syntheticSetting(
            SyntheticV1SemanticKeys.sizePressure,
            unit: .normalized,
            domain: .curve,
            value: .curve([
                try ForeignBrushCurvePoint(x: 0, y: 0.25),
                try ForeignBrushCurvePoint(x: 1, y: 1),
            ])
        ),
        syntheticSetting(
            SyntheticV1SemanticKeys.spacing,
            unit: .normalized,
            domain: .vector,
            value: .vector([0.125, 0.375])
        ),
    ]
    if includeWet {
        settings.append(
            try syntheticSetting(
                SyntheticV1SemanticKeys.wet,
                domain: .boolean,
                value: .boolean(true)
            )
        )
    }
    return settings.sorted { $0.semanticKey < $1.semanticKey }
}

private func syntheticSetting(
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

private func syntheticResource(
    id: String,
    role: ForeignBrushResourceRole,
    location: String,
    mediaType: String,
    bytes: Data,
    width: Int,
    height: Int,
    inverted: Bool = false,
    orientation: ForeignBrushImageOrientation = .up
) throws -> ForeignBrushResourceDescriptor {
    try ForeignBrushResourceDescriptor(
        id: id,
        role: role,
        containerLocation: location,
        mediaType: mediaType,
        contentSHA256: ForeignBrushDocument.contentSHA256(bytes),
        encodedByteCount: bytes.count,
        pixelWidth: width,
        pixelHeight: height,
        channelModel: .grayscale,
        colorInterpretation: .linear,
        inverted: inverted,
        orientation: orientation
    )
}
