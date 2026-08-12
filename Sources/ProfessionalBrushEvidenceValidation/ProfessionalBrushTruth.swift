import Foundation
import PatternEngine

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

struct ProfessionalSceneContract {
    let family: String
    let definitionID: String
    let residentBytes: Int
    let resourceLevels: [String: Int]
}

struct ProfessionalSceneIdentity: Equatable, Sendable {
    let scene: String
    let family: String
    let definitionID: String
    let definitionSemanticHash: String
    let pipelineKey: String
    let abiVersion: Int
}

struct ProfessionalSceneIdentitySet: Equatable, Sendable {
    private let byScene: [String: ProfessionalSceneIdentity]

    init(validating identities: [ProfessionalSceneIdentity]) throws {
        let scenes = identities.map(\.scene)
        let definitions = identities.map(\.definitionID)
        guard Set(scenes) == Set(ProfessionalBrushTruth.positiveSceneNames),
              scenes.count == ProfessionalBrushTruth.positiveSceneNames.count,
              Set(definitions).count == definitions.count
        else {
            throw ArtifactFileSystem.invalid(
                "professional scene identities are not the exact current four-scene set"
            )
        }
        byScene = Dictionary(uniqueKeysWithValues: identities.map {
            ($0.scene, $0)
        })
    }

    subscript(scene: String) -> ProfessionalSceneIdentity? {
        byScene[scene]
    }

    var definitionIDs: [String] {
        byScene.values.map(\.definitionID).sorted()
    }

    func identity(definitionID: String) -> ProfessionalSceneIdentity? {
        byScene.values.first { $0.definitionID == definitionID }
    }
}

struct ProfessionalPositiveEvidence {
    let identities: ProfessionalSceneIdentitySet
    let characterizations: [ProfessionalBrushCharacterizationRecord]
}

enum ProfessionalBrushTruth {
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
    static let sceneContracts: [String: ProfessionalSceneContract] = [
        "professional-chisel-marker": .init(
            family: "Chisel Marker",
            definitionID: "builtin.professional-chisel-marker",
            residentBytes: 21_845,
            resourceLevels: ["builtin.shape.marker-chisel": 8]
        ),
        "professional-graphite-pencil": .init(
            family: "Graphite Pencil",
            definitionID: "builtin.professional-graphite-pencil",
            residentBytes: 196_607,
            resourceLevels: [
                "builtin.grain.graphite": 9,
                "builtin.grain.graphite-paper": 9,
                "builtin.shape.graphite-tip": 8,
            ]
        ),
        "professional-natural-charcoal": .init(
            family: "Natural Charcoal",
            definitionID: "builtin.professional-natural-charcoal",
            residentBytes: 196_607,
            resourceLevels: [
                "builtin.grain.charcoal": 9,
                "builtin.grain.charcoal-fine-paper": 9,
                "builtin.shape.charcoal-tip": 8,
            ]
        ),
        "professional-technical-ink": .init(
            family: "Technical Ink",
            definitionID: "builtin.professional-technical-ink",
            residentBytes: 21_845,
            resourceLevels: ["builtin.shape.technical-nib": 8]
        ),
    ]
    static let contractByDefinitionID: [String: ProfessionalSceneContract] =
        Dictionary(
            uniqueKeysWithValues: sceneContracts.values.map {
                ($0.definitionID, $0)
            }
        )
}
