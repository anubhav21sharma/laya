import BrushFormat
import Foundation
import PatternEngine

public enum ProfessionalBrushEvidenceValidationError:
    Error, Equatable, LocalizedError
{
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}

/// Producer-side validation only. Artifact acceptance lives in the
/// Metal-free `ProfessionalBrushEvidenceValidation` target.
public enum ProfessionalBrushEvidenceValidator {
    public static let positiveSceneNames = [
        "professional-chisel-marker",
        "professional-graphite-pencil",
        "professional-natural-charcoal",
        "professional-technical-ink",
    ]
    public static let negativeSceneNames = positiveSceneNames.map {
        "\($0)-negative-control"
    }
    public static let sceneNames =
        (positiveSceneNames + negativeSceneNames).sorted()

    public static let requiredInvariantNames = [
        "boundedLiveWork",
        "destinationOutEraserCompatible",
        "nonemptyVisibleOutput",
        "predictionOnOffEqual",
        "previewCommitMaximumDeltaWithinTolerance",
        "professionalDefinitionIdentityExact",
        "radialRotationAndReflectionCorrect",
        "resolvedResourcesAndMipsExact",
        "strokeCompilerCacheCountersUnchanged",
        "tilingPeriodTranslationEqual",
    ]

    private struct SceneRequirement {
        let family: String
        let definitionID: String
        let residentBytes: Int
        let resourceLevels: [String: Int]
    }

    private static let sceneRequirements: [String: SceneRequirement] = [
        "professional-chisel-marker": SceneRequirement(
            family: "Chisel Marker",
            definitionID: "builtin.professional-chisel-marker",
            residentBytes: 21_845,
            resourceLevels: ["builtin.shape.marker-chisel": 8]
        ),
        "professional-graphite-pencil": SceneRequirement(
            family: "Graphite Pencil",
            definitionID: "builtin.professional-graphite-pencil",
            residentBytes: 114_687,
            resourceLevels: [
                "builtin.grain.graphite": 9,
                "builtin.grain.paper": 7,
                "builtin.shape.graphite-tip": 8,
            ]
        ),
        "professional-natural-charcoal": SceneRequirement(
            family: "Natural Charcoal",
            definitionID: "builtin.professional-natural-charcoal",
            residentBytes: 120_148,
            resourceLevels: [
                "builtin.grain.charcoal": 9,
                "builtin.grain.paper": 7,
                "builtin.shape.charcoal-tip": 8,
                "builtin.shape.soft-round": 7,
            ]
        ),
        "professional-technical-ink": SceneRequirement(
            family: "Technical Ink",
            definitionID: "builtin.professional-technical-ink",
            residentBytes: 21_845,
            resourceLevels: ["builtin.shape.technical-nib": 8]
        ),
    ]

    public static func expectedResourceLevels(
        forPositiveScene scene: String
    ) -> [String: Int]? {
        sceneRequirements[scene]?.resourceLevels
    }

    public static func validate(
        _ evidence: ProfessionalBrushSceneEvidence
    ) throws {
        guard evidence.schemaVersion
                == ProfessionalBrushSceneEvidence.currentSchemaVersion,
              let requirement = sceneRequirements[evidence.scene],
              evidence.family == requirement.family,
              evidence.definitionID == requirement.definitionID,
              isSHA256(evidence.definitionSemanticHash),
              isCurrentPipelineKey(evidence.pipelineKey),
              evidence.abiVersion == DepositionABI.version,
              evidence.residentResourceBytes == requirement.residentBytes,
              evidence.logicalDabCount > 0,
              evidence.projectedInstanceCount >= evidence.logicalDabCount,
              [
                  evidence.livePNGSHA256,
                  evidence.committedPNGSHA256,
                  evidence.canonicalPNGSHA256,
                  evidence.characterizationSHA256,
                  evidence.rendererExecutableSHA256,
              ].allSatisfy(isSHA256),
              evidence.previewCommitMaximumChannelDelta <= 1
        else {
            throw invalid(
                "professional scene identity, hashes, counts, pipeline, resources, or preview delta are invalid"
            )
        }

        let resourceNames = evidence.resolvedResources.map(\.identity)
        guard !resourceNames.isEmpty,
              resourceNames == resourceNames.sorted(),
              Set(resourceNames).count == resourceNames.count,
              Dictionary(
                  uniqueKeysWithValues: evidence.resolvedResources.map {
                      ($0.identity, $0.mipCount)
                  }
              ) == requirement.resourceLevels,
              evidence.resolvedResources.allSatisfy({
                  ["shape", "grain"].contains($0.kind)
                      && $0.mipCount > 0
                      && resourceKind(for: $0.identity) == $0.kind
              })
        else {
            throw invalid(
                "resolved professional resources are not the exact sorted identity and mip set"
            )
        }

        let expectedUploads = UInt64(requirement.resourceLevels.count)
        let afterCompile = ProfessionalBrushCompilerCounterSnapshot(
            packageDecodeCount: 1,
            imageDecodeCount: 0,
            textureUploadCount: expectedUploads,
            cacheHitCount: 0,
            activationCount: 1
        )
        let afterCacheHit = ProfessionalBrushCompilerCounterSnapshot(
            packageDecodeCount: 2,
            imageDecodeCount: 0,
            textureUploadCount: expectedUploads,
            cacheHitCount: expectedUploads,
            activationCount: 2
        )
        let counters = evidence.compilerCounters
        guard counters.beforeCompile == .zero,
              counters.afterCompile == afterCompile,
              counters.afterCacheHit == afterCacheHit,
              counters.beforeStroke == afterCacheHit,
              counters.afterStroke == afterCacheHit
        else {
            throw invalid(
                "compiler/cache counters do not prove one compile, one cache hit, and no input-path work: \(counters)"
            )
        }

        let telemetry = evidence.telemetry
        guard telemetry.authoritativeBacklog == 0,
              telemetry.predictedBacklog == 0,
              telemetry.backlogHighWater > 0,
              telemetry.backlogHighWater
                <= evidence.projectedInstanceCount,
              telemetry.encodedInstanceCount > 0,
              telemetry.encodedInstanceCount
                >= UInt64(evidence.projectedInstanceCount),
              (1...3).contains(telemetry.bufferHighWater)
        else {
            throw invalid(
                "professional telemetry is incomplete: telemetry=\(telemetry) projected=\(evidence.projectedInstanceCount)"
            )
        }

        let observations = evidence.observations
        guard [
            observations.liveBGRA8SHA256,
            observations.committedBGRA8SHA256,
            observations.canonicalBGRA8SHA256,
            observations.predictionOffBGRA8SHA256,
            observations.predictionOnBGRA8SHA256,
            observations.gridOriginBGRA8SHA256,
            observations.gridTranslatedBGRA8SHA256,
            observations.eraserBeforeBGRA8SHA256,
            observations.eraserAfterBGRA8SHA256,
            observations.radialRotationRenderedBGRA8SHA256,
            observations.radialRotationReferenceBGRA8SHA256,
            observations.radialReflectionRenderedBGRA8SHA256,
            observations.radialReflectionReferenceBGRA8SHA256,
        ].allSatisfy(isSHA256),
            observations.liveNontransparentPixelCount > 0,
            observations.committedNontransparentPixelCount > 0,
            observations.canonicalNontransparentPixelCount > 0,
            observations.predictionOffBGRA8SHA256
                == observations.predictionOnBGRA8SHA256,
            observations.predictionMaximumChannelDelta == 0,
            observations.gridOriginBGRA8SHA256
                == observations.gridTranslatedBGRA8SHA256,
            observations.gridMaximumChannelDelta == 0,
            observations.eraserBeforeBGRA8SHA256
                != observations.eraserAfterBGRA8SHA256,
            observations.eraserBeforeNontransparentPixelCount > 0,
            observations.eraserAfterNontransparentPixelCount >= 0,
            observations.eraserReducedAlphaPixelCount > 0,
            observations.radialRotationMaximumChannelDelta <= 8,
            observations.radialReflectionMaximumChannelDelta <= 8,
            observations.replayMode == "replayTail",
            observations.replayMaximumSamples == 256,
            observations.replayMaximumDabs == 2_048,
            observations.replayMaximumProjectedInstances == 4_096,
            observations.pipelinePrepareCallCountBeforeStroke
                == observations.pipelinePrepareCallCountAfterStroke
        else {
            throw invalid(
                "professional invariant observations are malformed: \(observations)"
            )
        }
        guard Set(evidence.invariantResults.keys)
                == Set(requiredInvariantNames),
              evidence.invariantResults.values.allSatisfy({ $0 })
        else {
            throw invalid(
                "professional invariant results are incomplete: \(evidence.invariantResults)"
            )
        }
    }

    private static func isCurrentPipelineKey(_ value: String) -> Bool {
        let fields = value.split(separator: ":")
        return fields.count == 10
            && fields[0] == "deposition"
            && fields[7] == "abi\(DepositionABI.version)"
            && fields[8]
                == "format\(DocumentColorPipeline.workingPixelFormat.rawValue)"
            && fields[9].hasPrefix("samples")
            && Int(fields[9].dropFirst("samples".count)).map { $0 > 0 }
                == true
    }

    public static func loadScenes(from directory: URL) throws
        -> [HarnessScene]
    {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        .filter {
            $0.pathExtension == "json"
                && $0.deletingPathExtension().lastPathComponent
                    .hasPrefix("professional-")
        }
        .map { url in
            let scene = try HarnessScene.decode(Data(contentsOf: url))
            guard scene.name
                    == url.deletingPathExtension().lastPathComponent
            else {
                throw invalid(
                    "professional scene filename does not match its decoded name"
                )
            }
            return scene
        }
        .sorted { $0.name < $1.name }
    }

    public static func validateSceneSet(_ scenes: [HarnessScene]) throws {
        let names = scenes.map(\.name)
        guard names == names.sorted(),
              Set(names).count == names.count,
              names == sceneNames
        else {
            throw invalid(
                "professional scenes must be the exact sorted four positive and four negative set"
            )
        }
        for positiveName in positiveSceneNames {
            guard let positive = scenes.first(where: {
                $0.name == positiveName
            }),
                let negative = scenes.first(where: {
                    $0.name == "\(positiveName)-negative-control"
                })
            else {
                throw invalid("professional scene pair is missing")
            }
            let positiveExpectations =
                positive.depositionInvariantExpectations
            let negativeExpectations =
                negative.depositionInvariantExpectations
            let differences = positiveExpectations.keys.filter {
                positiveExpectations[$0] != negativeExpectations[$0]
            }
            guard Set(positiveExpectations.keys)
                    == Set(requiredInvariantNames),
                  Set(negativeExpectations.keys)
                    == Set(requiredInvariantNames),
                  positiveExpectations.values.allSatisfy({ $0 }),
                  differences == ["professionalDefinitionIdentityExact"],
                  negativeExpectations[
                    "professionalDefinitionIdentityExact"
                  ] == false
            else {
                throw invalid(
                    "professional positive/negative pair must flip exactly one named requirement"
                )
            }
        }
    }

    public static func validateExpectations(
        scene: HarnessScene,
        actual: [String: Bool]
    ) throws {
        for key in scene.depositionInvariantExpectations.keys.sorted() {
            guard actual[key] == scene.depositionInvariantExpectations[key]
            else {
                throw invalid(
                    "\(scene.name) expectation '\(key)' did not match"
                )
            }
        }
    }

    public static func sha256(_ data: Data) -> String {
        BrushContentHash.sha256Hex(of: data)
    }

    private static func resourceKind(for identity: String) -> String? {
        BrushTextureIdentity(rawValue: identity).map {
            $0.kind == .shape ? "shape" : "grain"
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(isLowerHex)
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    private static func invalid(
        _ message: String
    ) -> ProfessionalBrushEvidenceValidationError {
        .invalid(message)
    }
}
