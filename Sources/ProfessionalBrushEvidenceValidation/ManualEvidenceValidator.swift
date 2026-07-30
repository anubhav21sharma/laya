import CoreFoundation
import Foundation

public enum ProfessionalManualEvidenceValidator {
    private static let cardKeys: Set<String> = [
        "cardID", "schemaVersion", "brushID", "gesture",
        "documentConfiguration", "background", "predictionEnabled",
        "paintRGBAHex", "passes",
    ]
    private static let passKeys: Set<String> = [
        "passIndex", "role", "tool", "brushID", "nominalDiameter",
        "inputSource", "capabilities", "strokes",
    ]
    private static let strokeKeys: Set<String> = [
        "strokeIndex", "samples",
    ]
    private static let sampleKeys: Set<String> = [
        "sampleIndex", "x", "y", "pressure", "timeOffset", "phase",
        "kind", "altitude", "azimuth", "roll",
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
    private static let orderedCapabilities = [
        "pressure", "altitude", "azimuth", "roll",
    ]
    private static let professionalDefinitionIDs = Set(
        ProfessionalBrushTruth.sceneTruth.values.map(\.definitionID)
    )
    private static let retainedEraserID = "builtin.native-eraser"

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
        guard integer(object["schemaVersion"]) == 3,
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
            guard integer(card["schemaVersion"]) == 2,
                  let cardID = ArtifactFileSystem.nonemptyString(
                      card,
                      "cardID"
                  ),
                  let brushID = card["brushID"] as? String,
                  professionalDefinitionIDs.contains(brushID),
                  let gesture = card["gesture"] as? String,
                  gestures.contains(gesture),
                  cardID.hasPrefix(
                      "\(brushID).review.\(gesture)."
                  ),
                  ["transparent", "opaque"].contains(
                      card["background"] as? String
                  ),
                  let predictionEnabled = card["predictionEnabled"] as? Bool,
                  ["#111111FF", "#C43A52FF", "#245EC7FF"].contains(
                      card["paintRGBAHex"] as? String
                  ),
                  let document =
                    card["documentConfiguration"] as? [String: Any],
                  let passes = card["passes"] as? [[String: Any]],
                  !passes.isEmpty
            else {
                throw ArtifactFileSystem.invalid(
                    "professional manual card identity or field is invalid"
                )
            }
            try validateDocument(document, gesture: gesture)
            let validatedPasses = try validatePasses(
                passes,
                cardBrushID: brushID,
                gesture: gesture,
                predictionEnabled: predictionEnabled
            )
            try validateGestureSemantics(
                gesture: gesture,
                cardID: cardID,
                passes: validatedPasses
            )
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
        let actualCanonicalHash = ArtifactFileSystem.sha256(canonicalCards)
        guard actualCanonicalHash
                == ProfessionalBrushTruth.canonicalManualCardsSHA256
        else {
            throw ArtifactFileSystem.invalid(
                "professional manual card truth changed: "
                    + actualCanonicalHash
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
        let states = try assessments.map(validateAssessment)
        if states.allSatisfy({ $0 == .pending }) {
            return false
        }
        guard states.allSatisfy({ $0 == .passed }) else {
            throw ArtifactFileSystem.invalid(
                "manual assessments must be uniformly pending or complete"
            )
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

    private struct ValidatedSample {
        let x: Double
        let y: Double
        let pressure: Double
        let altitude: Double?
        let azimuth: Double?
        let roll: Double?
    }

    private struct ValidatedStroke {
        let samples: [ValidatedSample]
    }

    private struct ValidatedPass {
        let role: String
        let tool: String
        let brushID: String
        let nominalDiameter: Double
        let inputSource: String
        let capabilities: [String]
        let strokes: [ValidatedStroke]
    }

    private enum AssessmentState {
        case pending
        case passed
    }

    private static func validatePasses(
        _ passes: [[String: Any]],
        cardBrushID: String,
        gesture: String,
        predictionEnabled: Bool
    ) throws -> [ValidatedPass] {
        var anyPredicted = false
        let validated = try passes.enumerated().map {
            passIndex,
            pass -> ValidatedPass in
            try ArtifactFileSystem.requireExactKeys(
                pass,
                passKeys,
                label: "professional manual pass"
            )
            guard integer(pass["passIndex"]) == passIndex,
                  let role = pass["role"] as? String,
                  [
                      "professionalDraw",
                      "retainedStageFourEraser",
                  ].contains(role),
                  let tool = pass["tool"] as? String,
                  ["draw", "erase"].contains(tool),
                  let brushID = pass["brushID"] as? String,
                  let nominalDiameter = number(pass["nominalDiameter"]),
                  nominalDiameter.isFinite,
                  (2...2_000).contains(nominalDiameter),
                  let inputSource = pass["inputSource"] as? String,
                  ["mouse", "pencil", "tablet"].contains(inputSource),
                  let capabilities = pass["capabilities"] as? [String],
                  capabilities
                    == orderedCapabilities.filter(capabilities.contains),
                  Set(capabilities).count == capabilities.count,
                  let strokes = pass["strokes"] as? [[String: Any]],
                  !strokes.isEmpty
            else {
                throw ArtifactFileSystem.invalid(
                    "professional manual pass is invalid"
                )
            }
            if role == "professionalDraw" {
                guard tool == "draw", brushID == cardBrushID else {
                    throw ArtifactFileSystem.invalid(
                        "professional draw pass identity is invalid"
                    )
                }
            } else {
                guard gesture == "eraserRetrace",
                      passIndex == 1,
                      tool == "erase",
                      brushID == retainedEraserID
                else {
                    throw ArtifactFileSystem.invalid(
                        "retained eraser pass identity is invalid"
                    )
                }
            }
            if inputSource == "mouse" {
                guard capabilities.isEmpty else {
                    throw ArtifactFileSystem.invalid(
                        "mouse pass cannot claim Pencil-only capabilities"
                    )
                }
            } else {
                guard capabilities.contains("pressure") else {
                    throw ArtifactFileSystem.invalid(
                        "Pencil/tablet pass must carry pressure"
                    )
                }
            }
            let validatedStrokes = try strokes.enumerated().map {
                strokeIndex,
                stroke -> ValidatedStroke in
                try ArtifactFileSystem.requireExactKeys(
                    stroke,
                    strokeKeys,
                    label: "professional manual stroke"
                )
                guard integer(stroke["strokeIndex"]) == strokeIndex,
                      let samples = stroke["samples"] as? [[String: Any]],
                      samples.count >= 2
                else {
                    throw ArtifactFileSystem.invalid(
                        "professional manual stroke is invalid"
                    )
                }
                var previousTime = -Double.infinity
                let validatedSamples = try samples.enumerated().map {
                    sampleIndex,
                    sample -> ValidatedSample in
                    try ArtifactFileSystem.requireExactKeys(
                        sample,
                        sampleKeys,
                        label: "professional manual sample"
                    )
                    guard integer(sample["sampleIndex"]) == sampleIndex,
                          let x = number(sample["x"]),
                          let y = number(sample["y"]),
                          let pressure = number(sample["pressure"]),
                          let timeOffset = number(sample["timeOffset"]),
                          x.isFinite,
                          y.isFinite,
                          pressure.isFinite,
                          (0...1).contains(pressure),
                          timeOffset.isFinite,
                          timeOffset >= 0,
                          timeOffset > previousTime,
                          let phase = sample["phase"] as? String,
                          let kind = sample["kind"] as? String,
                          ["actual", "predicted"].contains(kind)
                    else {
                        throw ArtifactFileSystem.invalid(
                            "professional manual sample is invalid"
                        )
                    }
                    let expectedPhase =
                        sampleIndex == 0
                        ? "began"
                        : sampleIndex == samples.count - 1
                            ? "ended"
                            : "moved"
                    guard phase == expectedPhase else {
                        throw ArtifactFileSystem.invalid(
                            "professional sample lifecycle is invalid"
                        )
                    }
                    previousTime = timeOffset
                    anyPredicted = anyPredicted || kind == "predicted"
                    let altitude = try optionalNumber(
                        sample["altitude"],
                        capability: "altitude",
                        capabilities: capabilities
                    )
                    let azimuth = try optionalNumber(
                        sample["azimuth"],
                        capability: "azimuth",
                        capabilities: capabilities
                    )
                    let roll = try optionalNumber(
                        sample["roll"],
                        capability: "roll",
                        capabilities: capabilities
                    )
                    guard altitude.map({
                        $0 > 0 && $0 <= .pi / 2
                    }) ?? true,
                    azimuth.map({
                        $0 >= 0 && $0 < 2 * .pi
                    }) ?? true,
                    roll.map({
                        (-Double.pi...Double.pi).contains($0)
                    }) ?? true
                    else {
                        throw ArtifactFileSystem.invalid(
                            "professional input angle is invalid"
                        )
                    }
                    return ValidatedSample(
                        x: x,
                        y: y,
                        pressure: pressure,
                        altitude: altitude,
                        azimuth: azimuth,
                        roll: roll
                    )
                }
                return ValidatedStroke(samples: validatedSamples)
            }
            return ValidatedPass(
                role: role,
                tool: tool,
                brushID: brushID,
                nominalDiameter: nominalDiameter,
                inputSource: inputSource,
                capabilities: capabilities,
                strokes: validatedStrokes
            )
        }
        guard anyPredicted == predictionEnabled else {
            throw ArtifactFileSystem.invalid(
                "professional prediction label does not match samples"
            )
        }
        return validated
    }

    private static func validateGestureSemantics(
        gesture: String,
        cardID: String,
        passes: [ValidatedPass]
    ) throws {
        guard passes[0].role == "professionalDraw" else {
            throw ArtifactFileSystem.invalid(
                "professional review must begin with its professional brush"
            )
        }
        switch gesture {
        case "tap":
            let expectedDiameter: Double
            if cardID.hasSuffix(".minimum") {
                expectedDiameter = 2
            } else if cardID.hasSuffix(".nominal") {
                expectedDiameter = 20
            } else if cardID.hasSuffix(".maximum") {
                expectedDiameter = 2_000
            } else {
                throw ArtifactFileSystem.invalid(
                    "tap review size label is invalid"
                )
            }
            guard passes.count == 1,
                  passes[0].nominalDiameter == expectedDiameter
            else {
                throw ArtifactFileSystem.invalid(
                    "tap review diameter does not match its label"
                )
            }
        case "pressureRamp":
            let samples = try oneStroke(passes, gesture: gesture)
            let pressure = samples.map(\.pressure)
            guard passes[0].inputSource == "pencil",
                  passes[0].capabilities == ["pressure"],
                  pressure.first == 0.1,
                  pressure.last == 1,
                  zip(pressure, pressure.dropFirst()).allSatisfy({
                      $0.0 < $0.1
                  })
            else {
                throw ArtifactFileSystem.invalid(
                    "pressure ramp must use monotonic Pencil pressure 0.1 through 1"
                )
            }
        case "tiltSweep":
            let samples = try oneStroke(passes, gesture: gesture)
            let altitude = samples.compactMap(\.altitude)
            guard passes[0].inputSource == "pencil",
                  passes[0].capabilities
                    == ["pressure", "altitude", "azimuth"],
                  altitude.count == samples.count,
                  samples.allSatisfy({ $0.azimuth != nil }),
                  zip(altitude, altitude.dropFirst()).allSatisfy({
                      $0.0 > $0.1
                  })
            else {
                throw ArtifactFileSystem.invalid(
                    "tilt sweep must use monotonic Pencil tilt and azimuth"
                )
            }
        case "tabletInput":
            let samples = try oneStroke(passes, gesture: gesture)
            guard passes[0].inputSource == "tablet",
                  passes[0].capabilities
                    == ["pressure", "altitude", "azimuth", "roll"],
                  Set(samples.map(\.pressure)).count > 1,
                  Set(samples.compactMap(\.altitude)).count > 1,
                  samples.allSatisfy({
                      $0.azimuth != nil && $0.roll != nil
                  })
            else {
                throw ArtifactFileSystem.invalid(
                    "tablet review must use useful tablet pressure and tilt"
                )
            }
        case "mouseFallback":
            let samples = try oneStroke(passes, gesture: gesture)
            guard passes[0].inputSource == "mouse",
                  passes[0].capabilities.isEmpty,
                  samples.allSatisfy({
                      $0.altitude == nil
                          && $0.azimuth == nil
                          && $0.roll == nil
                  })
            else {
                throw ArtifactFileSystem.invalid(
                    "mouse fallback contains Pencil-only input"
                )
            }
        case "crossHatch":
            guard passes.count == 1,
                  passes[0].strokes.count >= 4,
                  Set(passes[0].strokes.map(geometry)).count
                    == passes[0].strokes.count
            else {
                throw ArtifactFileSystem.invalid(
                    "cross-hatching must contain distinct strokes"
                )
            }
        case "repeatedBuildup":
            guard passes.count == 1,
                  passes[0].strokes.count >= 3,
                  Set(passes[0].strokes.map(geometry)).count == 1
            else {
                throw ArtifactFileSystem.invalid(
                    "buildup must repeat an overlapping stroke"
                )
            }
        case "eraserRetrace":
            guard passes.count == 2,
                  passes.map(\.role)
                    == [
                        "professionalDraw",
                        "retainedStageFourEraser",
                    ],
                  passes[1].brushID == retainedEraserID,
                  passes[0].strokes.count == 1,
                  passes[1].strokes.count == 1,
                  geometry(passes[0].strokes[0])
                    == geometry(passes[1].strokes[0])
            else {
                throw ArtifactFileSystem.invalid(
                    "eraser retrace must draw substrate then retrace with the retained eraser"
                )
            }
        default:
            _ = try oneStroke(passes, gesture: gesture)
        }
    }

    private static func oneStroke(
        _ passes: [ValidatedPass],
        gesture: String
    ) throws -> [ValidatedSample] {
        guard passes.count == 1, passes[0].strokes.count == 1 else {
            throw ArtifactFileSystem.invalid(
                "\(gesture) must contain one explicit stroke"
            )
        }
        return passes[0].strokes[0].samples
    }

    private static func geometry(_ stroke: ValidatedStroke) -> String {
        stroke.samples.map { "\($0.x),\($0.y)" }
            .joined(separator: ";")
    }

    private static func validateAssessment(
        _ assessment: [String: Any]
    ) throws -> AssessmentState {
        try ArtifactFileSystem.requireExactKeys(
            assessment,
            assessmentKeys,
            label: "professional manual assessment"
        )
        guard ArtifactFileSystem.nonemptyString(
            assessment,
            "cardID"
        ) != nil else {
            throw ArtifactFileSystem.invalid(
                "manual assessment card identity is invalid"
            )
        }
        let values = categoricalFields.map { assessment[$0] }
        if values.allSatisfy({ $0 is NSNull })
            && assessment["notes"] is NSNull
        {
            return .pending
        }
        guard values.allSatisfy({ $0 as? String == "pass" }) else {
            throw ArtifactFileSystem.invalid(
                "manual assessment values must be explicitly pass"
            )
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
        return .passed
    }

    private static func validateDocument(
        _ document: [String: Any],
        gesture: String
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
              required.allSatisfy({ !(document[$0] is NSNull) }),
              (gesture == "periodicSeamCrossing") == (mode == "periodic"),
              (["radialRotation", "radialReflection"].contains(gesture))
                == (mode == "radial")
        else {
            throw ArtifactFileSystem.invalid(
                "manual document does not match its review action"
            )
        }
        if gesture == "radialRotation" {
            guard integer(document["radialKind"]) == 1 else {
                throw ArtifactFileSystem.invalid(
                    "radial rotation card has the wrong symmetry kind"
                )
            }
        } else if gesture == "radialReflection" {
            guard integer(document["radialKind"]) == 0 else {
                throw ArtifactFileSystem.invalid(
                    "radial reflection card has the wrong symmetry kind"
                )
            }
        }
    }

    private static func optionalNumber(
        _ value: Any?,
        capability: String,
        capabilities: [String]
    ) throws -> Double? {
        if capabilities.contains(capability) {
            guard let result = number(value), result.isFinite else {
                throw ArtifactFileSystem.invalid(
                    "manual sample is missing \(capability)"
                )
            }
            return result
        }
        guard value is NSNull else {
            throw ArtifactFileSystem.invalid(
                "manual sample supplies undeclared \(capability)"
            )
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min),
              double <= Double(Int.max)
        else {
            return nil
        }
        return number.intValue
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.doubleValue
    }
}
