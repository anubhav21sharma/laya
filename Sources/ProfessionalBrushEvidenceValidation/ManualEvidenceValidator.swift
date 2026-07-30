import Foundation

public enum ProfessionalManualEvidenceValidator {
    private static let canonicalCardsSHA256 =
        "e138be4bf9119565596f8dafde95edf776349978a8df179cc5b48277279415d7"
    private static let cardKeys: Set<String> = [
        "cardID", "schemaVersion", "brushID", "gesture", "diameter",
        "pressureProfile", "inputCapabilities",
        "documentConfiguration", "background", "predictionEnabled",
        "paintRGBAHex", "tool", "substrate",
    ]
    private static let documentValueKeys: Set<String> = [
        "mode", "presetID", "repeatWidth", "repeatHeight",
        "orientationRadians", "radialKind", "rayCount", "centerX",
        "centerY", "referenceAngleRadians",
    ]
    private static let assessmentKeys: Set<String> = [
        "cardID", "responsiveness", "edgeQuality", "taperTermination",
        "textureCohesion", "pressureResponse", "tiltDirectionResponse",
        "buildup", "symmetryBehavior", "eraserMatch", "notes",
    ]
    private static let pendingAssessmentKeys: Set<String> = [
        "cardID", "responsiveness", "edgeQuality", "textureCohesion",
        "buildup", "symmetryBehavior", "eraserMatch", "notes",
    ]
    private static let categoricalFields = [
        "responsiveness", "edgeQuality", "taperTermination",
        "textureCohesion", "pressureResponse", "tiltDirectionResponse",
        "buildup", "symmetryBehavior", "eraserMatch",
    ]
    private static let gestures: Set<String> = [
        "tap", "slowLine", "fastLine", "pressureRamp", "tiltSweep",
        "curve", "sharpCorner", "crossHatch", "repeatedBuildup",
        "periodicSeamCrossing", "radialRotation", "radialReflection",
        "eraserRetrace", "mouseFallback", "tabletInput",
    ]

    public static func validate(_ data: Data) throws -> Bool {
        let object = try ArtifactFileSystem.jsonObject(
            data,
            label: "professional manual catalog"
        )
        try ArtifactFileSystem.requireExactKeys(
            object,
            ["schemaVersion", "cards", "assessments"],
            label: "professional manual catalog"
        )
        guard object["schemaVersion"] as? Int == 2,
              let cards = object["cards"] as? [[String: Any]],
              let assessments =
                object["assessments"] as? [[String: Any]],
              cards.count == 68,
              assessments.count == 68
        else {
            throw ArtifactFileSystem.invalid(
                "professional manual catalog must contain 68 cards and assessments"
            )
        }

        var cardIDs: [String] = []
        var brushGestures: [String: [String: Int]] = [:]
        for card in cards {
            try ArtifactFileSystem.requireExactKeys(
                card,
                cardKeys,
                label: "professional manual card"
            )
            guard card["schemaVersion"] as? Int == 1,
                  let cardID = ArtifactFileSystem.nonemptyString(
                      card,
                      "cardID"
                  ),
                  let brushID = card["brushID"] as? String,
                  Set(
                      ProfessionalBrushTruth.sceneTruth.values.map(
                          \.definitionID
                      )
                  ).contains(brushID),
                  let gesture = card["gesture"] as? String,
                  gestures.contains(gesture),
                  cardID.hasPrefix("\(brushID).draw.\(gesture)."),
                  let diameter = (card["diameter"] as? NSNumber)?
                    .doubleValue,
                  diameter.isFinite,
                  diameter > 0,
                  ["low", "medium", "high"].contains(
                      card["pressureProfile"] as? String
                  ),
                  let capabilities =
                    card["inputCapabilities"] as? [String],
                  Set(capabilities).count == capabilities.count,
                  Set(capabilities).isSubset(
                      of: ["pressure", "altitude", "azimuth", "roll"]
                  ),
                  ["transparent", "opaque"].contains(
                      card["background"] as? String
                  ),
                  card["predictionEnabled"] is Bool,
                  ["#111111FF", "#C43A52FF", "#245EC7FF"].contains(
                      card["paintRGBAHex"] as? String
                  ),
                  card["tool"] as? String == "draw",
                  card["substrate"] as? String == "none",
                  let document =
                    card["documentConfiguration"] as? [String: Any]
            else {
                throw ArtifactFileSystem.invalid(
                    "professional manual card identity or field is invalid"
                )
            }
            try validateDocument(document)
            cardIDs.append(cardID)
            brushGestures[brushID, default: [:]][gesture, default: 0] += 1
        }
        guard cardIDs == cardIDs.sorted(),
              Set(cardIDs).count == 68,
              brushGestures.count == 4,
              brushGestures.values.allSatisfy({
                  Set($0.keys) == gestures
                      && $0["tap"] == 3
                      && $0.filter({ $0.key != "tap" })
                        .values.allSatisfy({ $0 == 1 })
              })
        else {
            throw ArtifactFileSystem.invalid(
                "professional manual cards are not the exact sorted brush/gesture matrix"
            )
        }
        let canonicalCards = try JSONSerialization.data(
            withJSONObject: cards,
            options: [.sortedKeys]
        )
        guard ArtifactFileSystem.sha256(canonicalCards)
                == canonicalCardsSHA256
        else {
            throw ArtifactFileSystem.invalid(
                "professional manual card identities or scenarios changed"
            )
        }

        let assessmentIDs = assessments.compactMap {
            $0["cardID"] as? String
        }
        guard assessmentIDs == cardIDs else {
            throw ArtifactFileSystem.invalid(
                "manual assessment identities do not match the cards"
            )
        }
        let allPending = assessments.allSatisfy { assessment in
            Set(assessment.keys) == pendingAssessmentKeys
                && pendingAssessmentKeys.subtracting(["cardID"])
                    .allSatisfy { assessment[$0] is NSNull }
        }
        if allPending {
            return false
        }
        for assessment in assessments {
            try ArtifactFileSystem.requireExactKeys(
                assessment,
                assessmentKeys,
                label: "professional manual assessment"
            )
            for field in categoricalFields {
                guard assessment[field] as? String == "pass" else {
                    throw ArtifactFileSystem.invalid(
                        "manual assessment \(field) must be explicitly pass"
                    )
                }
            }
            if !(assessment["notes"] is NSNull) {
                guard let notes = assessment["notes"] as? String,
                      !notes.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty,
                      notes.utf8.count <= 2_000
                else {
                    throw ArtifactFileSystem.invalid(
                        "manual assessment notes are malformed"
                    )
                }
            }
        }
        return true
    }

    static func validate(root: URL) throws -> Bool {
        guard try ArtifactFileSystem.entryNames(root) == ["catalog.json"]
        else {
            throw ArtifactFileSystem.invalid(
                "manual-card root file set is not exact"
            )
        }
        return try validate(
            ArtifactFileSystem.regularFileData(
                root.appendingPathComponent("catalog.json"),
                label: "professional manual catalog"
            )
        )
    }

    private static func validateDocument(
        _ document: [String: Any]
    ) throws {
        guard let mode = document["mode"] as? String,
              ["plain", "periodic", "radial"].contains(mode)
        else {
            throw ArtifactFileSystem.invalid(
                "manual card document mode is invalid"
            )
        }
        let required: Set<String>
        switch mode {
        case "plain":
            required = []
        case "periodic":
            required = [
                "presetID", "repeatWidth", "repeatHeight",
                "orientationRadians",
            ]
        default:
            required = [
                "radialKind", "rayCount", "centerX", "centerY",
                "referenceAngleRadians",
            ]
        }
        try ArtifactFileSystem.requireExactKeys(
            document,
            required.union(["mode"]),
            label: "manual card document configuration"
        )
        guard required.isSubset(of: documentValueKeys),
              required.allSatisfy({ !(document[$0] is NSNull) })
        else {
            throw ArtifactFileSystem.invalid(
                "manual document required value is null"
            )
        }
    }
}
