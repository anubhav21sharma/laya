import Foundation

public enum DepositionEvidenceValidationError:
    Error, Equatable, LocalizedError
{
    case malformedEvidence
    case invalidEvidence(String)
    case sceneSetMismatch
    case duplicateScene(String)
    case scenesNotSorted
    case wrongSceneSchema(name: String, actual: Int)
    case invalidExpectationPair(String)

    public var errorDescription: String? {
        switch self {
        case .malformedEvidence:
            "Deposition evidence JSON is malformed."
        case let .invalidEvidence(message):
            "Invalid deposition evidence: \(message)."
        case .sceneSetMismatch:
            "Deposition scenes do not match the exact 32-scene matrix."
        case let .duplicateScene(name):
            "Deposition scene '\(name)' is duplicated."
        case .scenesNotSorted:
            "Deposition scenes must be sorted by scene name."
        case let .wrongSceneSchema(name, actual):
            "Deposition scene '\(name)' uses schema \(actual), expected 6."
        case let .invalidExpectationPair(name):
            "Deposition scene pair '\(name)' must differ in exactly one authoritative expectation."
        }
    }
}

public enum DepositionEvidenceValidator {
    public static let positiveSceneNames = [
        "deposition-airbrush",
        "deposition-cache-pinning",
        "deposition-custom-asymmetric",
        "deposition-dry",
        "deposition-erase",
        "deposition-failure-matrix",
        "deposition-glaze",
        "deposition-ink",
        "deposition-kinematics",
        "deposition-layer-matrix",
        "deposition-marker",
        "deposition-periodic-seams",
        "deposition-prediction",
        "deposition-preview-commit",
        "deposition-radial-reflection",
        "deposition-stamp-size-mips",
    ]

    public static let negativeSceneNames = positiveSceneNames.map {
        "\($0)-negative-control"
    }

    public static let sceneNames =
        (positiveSceneNames + negativeSceneNames).sorted()

    public static let namedMetamorphicInvariants: Set<String> = [
        "predictionOnOffEqual",
        "batchPartitionsEqual",
        "symmetryOrderEqual",
        "tilingPeriodTranslationEqual",
        "zoomIndependent",
        "eraseColorIndependent",
        "reflectionHandednessCorrect",
        "cancelPreservesCanonical",
    ]

    public static let allowedInvariantNames: Set<String> =
        namedMetamorphicInvariants.union([
            "activeCompiledBrushPinned",
            "customTexturesExact",
            "failurePreservesCanonicalAndHistory",
            "familyAndAccumulationCorrect",
            "previewCommitMaximumDeltaWithinTolerance",
            "secondaryLayerPresent",
            "strokeCompilerCountersUnchanged",
            "textureMipSelectionCorrect",
        ])

    public static func validate(
        _ evidence: DepositionSceneEvidence
    ) throws {
        guard evidence.schemaVersion
                == DepositionSceneEvidence.currentSchemaVersion
        else {
            throw invalid("unsupported schema \(evidence.schemaVersion)")
        }
        guard positiveSceneNames.contains(evidence.scene),
              !evidence.definitionID.isEmpty,
              !evidence.pipelineKey.isEmpty
        else {
            throw invalid("scene or native identity is invalid")
        }
        guard isSHA256(evidence.semanticHash),
              isSHA256(evidence.canonicalSHA256),
              evidence.cpuReferenceSHA256.map(isSHA256) ?? true
        else {
            throw invalid("SHA-256 fields must be lowercase hexadecimal")
        }
        guard evidence.abiVersion == DepositionABI.version,
              evidence.resourceBytes >= 0,
              evidence.textureLevels.allSatisfy({
                  !$0.key.isEmpty && $0.value > 0
              }),
              evidence.logicalDabCount > 0,
              evidence.projectedInstanceCount > 0
        else {
            throw invalid("ABI, resource, texture, or dab counts are invalid")
        }
        guard
            (evidence.cpuReferenceSHA256 == nil)
                == (evidence.maximumCPUGPUChannelDelta == nil)
        else {
            throw invalid("CPU reference digest and delta must appear together")
        }
        let telemetry = evidence.telemetry
        guard telemetry.authoritativeBacklog >= 0,
              telemetry.predictedBacklog >= 0,
              telemetry.backlogHighWater >= 0,
              telemetry.bufferHighWater >= 0
        else {
            throw invalid("telemetry counts must be nonnegative")
        }
        guard !evidence.invariantResults.isEmpty,
              Set(evidence.invariantResults.keys).isSubset(
                  of: allowedInvariantNames
              )
        else {
            throw invalid("invariant results are empty or unknown")
        }
    }

    public static func loadScenes(from directory: URL) throws
        -> [HarnessScene]
    {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.pathExtension == "json"
                && $0.deletingPathExtension().lastPathComponent
                    .hasPrefix("deposition-")
        }
        let scenes = try urls.map {
            try HarnessScene.decode(Data(contentsOf: $0))
        }
        return scenes.sorted { $0.name < $1.name }
    }

    public static func validateSceneSet(_ scenes: [HarnessScene]) throws {
        let names = scenes.map(\.name)
        guard names == names.sorted() else {
            throw DepositionEvidenceValidationError.scenesNotSorted
        }
        for pair in zip(names, names.dropFirst()) where pair.0 == pair.1 {
            throw DepositionEvidenceValidationError.duplicateScene(pair.0)
        }
        guard names == sceneNames else {
            throw DepositionEvidenceValidationError.sceneSetMismatch
        }
        for scene in scenes where scene.schemaVersion != 6 {
            throw DepositionEvidenceValidationError.wrongSceneSchema(
                name: scene.name,
                actual: scene.schemaVersion
            )
        }
        for positiveName in positiveSceneNames {
            guard
                let positive = scenes.first(where: {
                    $0.name == positiveName
                }),
                let negative = scenes.first(where: {
                    $0.name == "\(positiveName)-negative-control"
                })
            else {
                throw DepositionEvidenceValidationError.sceneSetMismatch
            }
            let positiveKeys = Set(
                positive.depositionInvariantExpectations.keys
            )
            let negativeKeys = Set(
                negative.depositionInvariantExpectations.keys
            )
            let differences = positiveKeys.filter {
                positive.depositionInvariantExpectations[$0]
                    != negative.depositionInvariantExpectations[$0]
            }
            guard !positiveKeys.isEmpty,
                  positiveKeys == negativeKeys,
                  positiveKeys.isSubset(of: allowedInvariantNames),
                  positive.depositionInvariantExpectations.values
                    .allSatisfy({ $0 }),
                  differences.count == 1,
                  differences.allSatisfy({
                      negative.depositionInvariantExpectations[$0] == false
                  })
            else {
                throw DepositionEvidenceValidationError
                    .invalidExpectationPair(positiveName)
            }
        }
    }

    public static func validateExpectations(
        scene: HarnessScene,
        actual: [String: Bool]
    ) throws {
        for key in scene.depositionInvariantExpectations.keys.sorted() {
            guard let actualValue = actual[key],
                  actualValue
                    == scene.depositionInvariantExpectations[key]
            else {
                throw invalid(
                    "\(scene.name) expectation '\(key)' did not match"
                )
            }
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func invalid(
        _ message: String
    ) -> DepositionEvidenceValidationError {
        .invalidEvidence(message)
    }
}
