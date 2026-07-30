import Foundation

public enum ProfessionalBrushArtifactValidationError:
    Error, Equatable, LocalizedError
{
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}

public enum ProfessionalBrushArtifactValidationStatus:
    Equatable, Sendable
{
    case passed
    case pending
}

struct ProfessionalSceneTruth {
    let family: String
    let definitionID: String
    let semanticHash: String
    let pipelineKey: String
    let residentBytes: Int
    let resourceLevels: [String: Int]
}

enum ProfessionalBrushTruth {
    static let canonicalManualCardsSHA256 =
        "ef36da0a12c26ea335032b4f596005b762617da6f7057fe47ffc1031872fdf5e"
    static let professionalCharacterizationBaselineSHA256 =
        "d4758be3310facf05683c4e8560428aad8b5ff47e331c9f7632fb802aad94ea2"
    static let positiveSceneNames = [
        "professional-chisel-marker",
        "professional-graphite-pencil",
        "professional-natural-charcoal",
        "professional-technical-ink",
    ]
    static let negativeSceneNames = positiveSceneNames.map {
        "\($0)-negative-control"
    }
    static let sceneNames =
        (positiveSceneNames + negativeSceneNames).sorted()
    static let requiredInvariantNames: Set<String> = [
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
    static let traces = [
        "professional-corner",
        "professional-direction-turn",
        "professional-fast-line",
        "professional-grid-seam",
        "professional-hatching",
        "professional-pressure-ramp",
        "professional-radial-spoke",
        "professional-slow-line",
        "professional-tap",
        "professional-tilt-sweep",
    ]
    static let sceneTruth: [String: ProfessionalSceneTruth] = [
        "professional-chisel-marker": .init(
            family: "Chisel Marker",
            definitionID: "builtin.professional-chisel-marker",
            semanticHash:
                "2c1b9c2c7770dacfd4eee5e5fc6bbbf57b202bbcb15b6edca37de868ed2ec1f1",
            pipelineKey:
                "deposition:uniformGlaze:markerOverlap:s0:g0:h0:d0:abi1:format80:samples1",
            residentBytes: 21_845,
            resourceLevels: ["builtin.shape.marker-chisel": 8]
        ),
        "professional-graphite-pencil": .init(
            family: "Graphite Pencil",
            definitionID: "builtin.professional-graphite-pencil",
            semanticHash:
                "10af674df1d65e52efde75a68860e554c31e75dda12c17027bb728a47550aa52",
            pipelineKey:
                "deposition:flow:dryBreakup:s0:g1:h1:d0:abi1:format80:samples1",
            residentBytes: 114_687,
            resourceLevels: [
                "builtin.grain.graphite": 9,
                "builtin.grain.paper": 7,
                "builtin.shape.graphite-tip": 8,
            ]
        ),
        "professional-natural-charcoal": .init(
            family: "Natural Charcoal",
            definitionID: "builtin.professional-natural-charcoal",
            semanticHash:
                "c686a582f773263649cb5259851eeffbe2403d38ed9a2be4ae9114bb7c8bd007",
            pipelineKey:
                "deposition:flow:dryBreakup:s1:g1:h1:d0:abi1:format80:samples1",
            residentBytes: 120_148,
            resourceLevels: [
                "builtin.grain.charcoal": 9,
                "builtin.grain.paper": 7,
                "builtin.shape.charcoal-tip": 8,
                "builtin.shape.soft-round": 7,
            ]
        ),
        "professional-technical-ink": .init(
            family: "Technical Ink",
            definitionID: "builtin.professional-technical-ink",
            semanticHash:
                "394e34d6ddccb13978714550537cae9b2cab9e566032b6b3ddc25b6eab0d5534",
            pipelineKey:
                "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1",
            residentBytes: 21_845,
            resourceLevels: ["builtin.shape.technical-nib": 8]
        ),
    ]
    static let truthByDefinitionID: [String: ProfessionalSceneTruth] =
        Dictionary(
            uniqueKeysWithValues: sceneTruth.values.map {
                ($0.definitionID, $0)
            }
        )
}
