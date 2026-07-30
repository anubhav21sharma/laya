import CoreFoundation
import Foundation

public enum ProfessionalManualSemanticError:
    String, Error, Equatable, LocalizedError, Sendable
{
    case tap
    case lineTiming
    case pressureRamp
    case tiltSweep
    case curve
    case sharpCorner
    case crossHatch
    case repeatedBuildup
    case periodicSeamCrossing
    case radialRotation
    case radialReflection
    case eraserRetrace
    case mouseFallback
    case tabletInput

    public var errorDescription: String? {
        "professional manual semantic: \(rawValue)"
    }
}

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
        try validateCatalog(data, requireCanonicalHash: true)
    }

    /// Validates the complete executable review meaning without consulting the
    /// canonical-card digest. This is the explicit boundary used to prove that
    /// named scenarios fail for their own semantic defect.
    public static func validateSemantics(_ data: Data) throws {
        _ = try validateCatalog(data, requireCanonicalHash: false)
    }

    private static func validateCatalog(
        _ data: Data,
        requireCanonicalHash: Bool
    ) throws -> Bool {
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
                background: card["background"] as! String,
                paintRGBAHex: card["paintRGBAHex"] as! String,
                predictionEnabled: predictionEnabled,
                document: document,
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
        if requireCanonicalHash {
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
        let timeOffset: Double
        let phase: String
        let kind: String
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
                        timeOffset: timeOffset,
                        phase: phase,
                        kind: kind,
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
        background: String,
        paintRGBAHex: String,
        predictionEnabled: Bool,
        document: [String: Any],
        passes: [ValidatedPass]
    ) throws {
        try validateScenarioLabels(
            gesture: gesture,
            cardID: cardID,
            background: background,
            paintRGBAHex: paintRGBAHex,
            predictionEnabled: predictionEnabled
        )
        guard passes[0].role == "professionalDraw" else {
            throw ArtifactFileSystem.invalid(
                "professional review must begin with its professional brush"
            )
        }
        let standardLine: [(Double, Double)] = [
            (48, 128), (88, 128), (128, 128), (168, 128), (208, 128),
        ]
        let expressiveLine: [(Double, Double)] = [
            (48, 128), (88, 112), (128, 128), (168, 144), (208, 128),
        ]
        let standardPressure = [Double](repeating: 0.55, count: 5)

        switch gesture {
        case "tap":
            let expectedDiameter: Double
            let expectedPressure: Double
            if cardID.hasSuffix(".minimum") {
                expectedDiameter = 2
                expectedPressure = 0.25
            } else if cardID.hasSuffix(".nominal") {
                expectedDiameter = 20
                expectedPressure = 0.55
            } else if cardID.hasSuffix(".maximum") {
                expectedDiameter = 2_000
                expectedPressure = 0.9
            } else {
                throw ProfessionalManualSemanticError.tap
            }
            guard passes.count == 1,
                  exactPass(
                      passes[0],
                      diameter: expectedDiameter,
                      source: "pencil",
                      capabilities: ["pressure"],
                      strokeCount: 1
                  ),
                  matchesStroke(
                      passes[0].strokes[0],
                      points: [(128, 128), (128, 128), (128, 128)],
                      pressures: [Double](
                          repeating: expectedPressure,
                          count: 3
                      ),
                      interval: 0.01
                  )
            else {
                throw ProfessionalManualSemanticError.tap
            }
        case "slowLine":
            guard background == "opaque",
                  !predictionEnabled,
                  passes.count == 1,
                  exactPass(
                      passes[0],
                      source: "pencil",
                      capabilities: ["pressure"],
                      strokeCount: 1
                  ),
                  matchesStroke(
                      passes[0].strokes[0],
                      points: standardLine,
                      pressures: standardPressure,
                      interval: 0.05
                  )
            else {
                throw ProfessionalManualSemanticError.lineTiming
            }
        case "fastLine":
            guard background == "opaque",
                  predictionEnabled,
                  passes.count == 1,
                  exactPass(
                      passes[0],
                      source: "pencil",
                      capabilities: ["pressure"],
                      strokeCount: 1
                  ),
                  matchesStroke(
                      passes[0].strokes[0],
                      points: standardLine,
                      pressures: standardPressure,
                      interval: 0.004,
                      predictedIndex: 3
                  )
            else {
                throw ProfessionalManualSemanticError.lineTiming
            }
        case "pressureRamp":
            guard passes.count == 1,
                  exactPass(
                      passes[0],
                      source: "pencil",
                      capabilities: ["pressure"],
                      strokeCount: 1
                  ),
                  matchesStroke(
                      passes[0].strokes[0],
                      points: expressiveLine,
                      pressures: [0.1, 0.325, 0.55, 0.775, 1],
                      interval: 0.014
                  )
            else {
                throw ProfessionalManualSemanticError.pressureRamp
            }
        case "tiltSweep":
            guard predictionEnabled,
                  passes.count == 1,
                  exactPass(
                      passes[0],
                      source: "pencil",
                      capabilities: [
                          "pressure", "altitude", "azimuth",
                      ],
                      strokeCount: 1
                  ),
                  matchesStroke(
                      passes[0].strokes[0],
                      points: expressiveLine,
                      pressures: [Double](repeating: 0.55, count: 5),
                      interval: 0.014,
                      predictedIndex: 3,
                      altitudes: [1.3, 1.05, 0.8, 0.55, 0.3],
                      azimuths: [0.2, 0.5, 0.8, 1.1, 1.4]
                  )
            else {
                throw ProfessionalManualSemanticError.tiltSweep
            }
        case "curve":
            guard passes.count == 1,
                  exactPass(
                      passes[0],
                      source: "pencil",
                      capabilities: ["pressure"],
                      strokeCount: 1
                  ),
                  matchesStroke(
                      passes[0].strokes[0],
                      points: [
                          (48, 160), (72, 112), (112, 80), (160, 88),
                          (208, 136),
                      ],
                      pressures: standardPressure,
                      interval: 0.014
                  )
            else {
                throw ProfessionalManualSemanticError.curve
            }
        case "sharpCorner":
            guard passes.count == 1,
                  exactPass(
                      passes[0],
                      source: "pencil",
                      capabilities: ["pressure"],
                      strokeCount: 1
                  ),
                  matchesStroke(
                      passes[0].strokes[0],
                      points: [
                          (48, 192), (128, 192), (128, 64), (208, 64),
                      ],
                      pressures: [Double](repeating: 0.55, count: 4),
                      interval: 0.014
                  )
            else {
                throw ProfessionalManualSemanticError.sharpCorner
            }
        case "tabletInput":
            guard predictionEnabled,
                  passes.count == 1,
                  exactPass(
                      passes[0],
                      source: "tablet",
                      capabilities: [
                          "pressure", "altitude", "azimuth", "roll",
                      ],
                      strokeCount: 1
                  ),
                  matchesStroke(
                      passes[0].strokes[0],
                      points: expressiveLine,
                      pressures: [0.25, 0.45, 0.65, 0.8, 0.6],
                      interval: 0.012,
                      predictedIndex: 3,
                      altitudes: [1.2, 1.05, 0.9, 0.7, 0.5],
                      azimuths: [0.1, 0.35, 0.6, 0.85, 1.1],
                      rolls: [-0.3, -0.15, 0, 0.15, 0.3]
                  )
            else {
                throw ProfessionalManualSemanticError.tabletInput
            }
        case "mouseFallback":
            guard passes.count == 1,
                  exactPass(
                      passes[0],
                      source: "mouse",
                      capabilities: [],
                      strokeCount: 1
                  ),
                  matchesStroke(
                      passes[0].strokes[0],
                      points: expressiveLine,
                      pressures: [Double](repeating: 1, count: 5),
                      interval: 0.012
                  )
            else {
                throw ProfessionalManualSemanticError.mouseFallback
            }
        case "crossHatch":
            let hatchPoints: [[(Double, Double)]] = [
                [(56, 72), (184, 200)],
                [(88, 56), (216, 184)],
                [(56, 184), (184, 56)],
                [(88, 200), (216, 72)],
            ]
            let hatchMatches = passes.count == 1
                && zip(
                    passes[0].strokes,
                    hatchPoints
                ).allSatisfy {
                    matchesStroke(
                        $0.0,
                        points: $0.1,
                        pressures: [0.72, 0.72],
                        interval: 0.025
                    )
                }
            guard passes.count == 1,
                  exactPass(
                      passes[0],
                      source: "pencil",
                      capabilities: ["pressure"],
                      strokeCount: 4
                  ),
                  hatchMatches
            else {
                throw ProfessionalManualSemanticError.crossHatch
            }
        case "repeatedBuildup":
            guard passes.count == 1,
                  exactPass(
                      passes[0],
                      source: "pencil",
                      capabilities: ["pressure"],
                      strokeCount: 4
                  ),
                  passes[0].strokes.allSatisfy({
                      matchesStroke(
                          $0,
                          points: standardLine,
                          pressures: [Double](repeating: 0.7, count: 5),
                          interval: 0.012
                      )
                  })
            else {
                throw ProfessionalManualSemanticError.repeatedBuildup
            }
        case "periodicSeamCrossing":
            guard predictionEnabled,
                  integer(document["presetID"]) == 0,
                  number(document["repeatWidth"]) == 256,
                  number(document["repeatHeight"]) == 256,
                  number(document["orientationRadians"]) == 0,
                  passes.count == 1,
                  exactPass(
                      passes[0],
                      source: "pencil",
                      capabilities: ["pressure"],
                      strokeCount: 1
                  ),
                  matchesStroke(
                      passes[0].strokes[0],
                      points: [(4, 128), (128, 128), (252, 128)],
                      pressures: [0.55, 0.55, 0.55],
                      interval: 0.014,
                      predictedIndex: 1
                  )
            else {
                throw ProfessionalManualSemanticError.periodicSeamCrossing
            }
        case "radialRotation":
            guard exactRadialDocument(document, kind: 1),
                  exactRadialStroke(
                      passes,
                      predictionEnabled: predictionEnabled
                  )
            else {
                throw ProfessionalManualSemanticError.radialRotation
            }
        case "radialReflection":
            guard exactRadialDocument(document, kind: 0),
                  exactRadialStroke(
                      passes,
                      predictionEnabled: predictionEnabled
                  )
            else {
                throw ProfessionalManualSemanticError.radialReflection
            }
        case "eraserRetrace":
            guard passes.count == 2,
                  background == "opaque",
                  passes.map(\.role)
                    == [
                        "professionalDraw",
                        "retainedStageFourEraser",
                    ],
                  passes[1].brushID == retainedEraserID,
                  exactPass(
                      passes[0],
                      source: "pencil",
                      capabilities: ["pressure"],
                      strokeCount: 1
                  ),
                  exactPass(
                      passes[1],
                      role: "retainedStageFourEraser",
                      tool: "erase",
                      diameter: 20,
                      source: "pencil",
                      capabilities: ["pressure"],
                      strokeCount: 1
                  ),
                  passes.allSatisfy({
                      matchesStroke(
                          $0.strokes[0],
                          points: [
                              (56, 72), (92, 104), (128, 136),
                              (164, 168), (200, 200),
                          ],
                          pressures: [Double](
                              repeating: 0.65,
                              count: 5
                          ),
                          interval: 0.012
                      )
                  })
            else {
                throw ProfessionalManualSemanticError.eraserRetrace
            }
        default:
            preconditionFailure("Unhandled professional review gesture")
        }
    }

    private static func validateScenarioLabels(
        gesture: String,
        cardID: String,
        background: String,
        paintRGBAHex: String,
        predictionEnabled: Bool
    ) throws {
        let expectedBackground: String
        let expectedPaint: String
        let expectedPrediction: Bool
        switch gesture {
        case "tap":
            expectedBackground = "transparent"
            expectedPaint = "#111111FF"
            expectedPrediction = false
        case "slowLine":
            expectedBackground = "opaque"
            expectedPaint = "#111111FF"
            expectedPrediction = false
        case "fastLine":
            expectedBackground = "opaque"
            expectedPaint = "#111111FF"
            expectedPrediction = true
        case "pressureRamp":
            expectedBackground = "transparent"
            expectedPaint = "#111111FF"
            expectedPrediction = false
        case "tiltSweep":
            expectedBackground = "transparent"
            expectedPaint = "#111111FF"
            expectedPrediction = true
        case "curve", "sharpCorner":
            expectedBackground = "opaque"
            expectedPaint = "#C43A52FF"
            expectedPrediction = false
        case "crossHatch", "repeatedBuildup":
            expectedBackground = "opaque"
            expectedPaint = "#245EC7FF"
            expectedPrediction = false
        case "periodicSeamCrossing",
             "radialRotation",
             "radialReflection":
            expectedBackground = "transparent"
            expectedPaint = "#111111FF"
            expectedPrediction = true
        case "eraserRetrace":
            expectedBackground = "opaque"
            expectedPaint = "#111111FF"
            expectedPrediction = false
        case "mouseFallback":
            expectedBackground = "transparent"
            expectedPaint = "#111111FF"
            expectedPrediction = false
        case "tabletInput":
            expectedBackground = "transparent"
            expectedPaint = "#111111FF"
            expectedPrediction = true
        default:
            preconditionFailure("Unhandled professional review gesture")
        }
        let suffixIsExact =
            gesture == "tap"
            ? cardID.hasSuffix(".minimum")
                || cardID.hasSuffix(".nominal")
                || cardID.hasSuffix(".maximum")
            : cardID.hasSuffix(".standard")
        guard suffixIsExact,
              background == expectedBackground,
              paintRGBAHex == expectedPaint,
              predictionEnabled == expectedPrediction
        else {
            throw semanticError(for: gesture)
        }
    }

    private static func semanticError(
        for gesture: String
    ) -> ProfessionalManualSemanticError {
        switch gesture {
        case "tap":
            .tap
        case "slowLine", "fastLine":
            .lineTiming
        case "pressureRamp":
            .pressureRamp
        case "tiltSweep":
            .tiltSweep
        case "curve":
            .curve
        case "sharpCorner":
            .sharpCorner
        case "crossHatch":
            .crossHatch
        case "repeatedBuildup":
            .repeatedBuildup
        case "periodicSeamCrossing":
            .periodicSeamCrossing
        case "radialRotation":
            .radialRotation
        case "radialReflection":
            .radialReflection
        case "eraserRetrace":
            .eraserRetrace
        case "mouseFallback":
            .mouseFallback
        case "tabletInput":
            .tabletInput
        default:
            preconditionFailure("Unhandled professional review gesture")
        }
    }

    private static func exactPass(
        _ pass: ValidatedPass,
        role: String = "professionalDraw",
        tool: String = "draw",
        diameter: Double = 20,
        source: String,
        capabilities: [String],
        strokeCount: Int
    ) -> Bool {
        pass.role == role
            && pass.tool == tool
            && pass.nominalDiameter == diameter
            && pass.inputSource == source
            && pass.capabilities == capabilities
            && pass.strokes.count == strokeCount
    }

    private static func matchesStroke(
        _ stroke: ValidatedStroke,
        points: [(Double, Double)],
        pressures: [Double],
        interval: Double,
        predictedIndex: Int? = nil,
        altitudes: [Double]? = nil,
        azimuths: [Double]? = nil,
        rolls: [Double]? = nil
    ) -> Bool {
        guard stroke.samples.count == points.count,
              pressures.count == points.count,
              altitudes == nil || altitudes?.count == points.count,
              azimuths == nil || azimuths?.count == points.count,
              rolls == nil || rolls?.count == points.count
        else {
            return false
        }
        return stroke.samples.indices.allSatisfy { index in
            let sample = stroke.samples[index]
            let expectedPhase =
                index == 0
                ? "began"
                : index == stroke.samples.count - 1 ? "ended" : "moved"
            let expectedKind =
                predictedIndex == index ? "predicted" : "actual"
            return sample.x == points[index].0
                && sample.y == points[index].1
                && sample.pressure == pressures[index]
                && abs(
                    sample.timeOffset - Double(index) * interval
                ) <= 1e-12
                && sample.phase == expectedPhase
                && sample.kind == expectedKind
                && sample.altitude == altitudes?[index]
                && sample.azimuth == azimuths?[index]
                && sample.roll == rolls?[index]
        }
    }

    private static func exactRadialDocument(
        _ document: [String: Any],
        kind: Int
    ) -> Bool {
        integer(document["radialKind"]) == kind
            && integer(document["rayCount"]) == 8
            && number(document["centerX"]) == 1_024
            && number(document["centerY"]) == 1_024
            && number(document["referenceAngleRadians"]) == 0
    }

    private static func exactRadialStroke(
        _ passes: [ValidatedPass],
        predictionEnabled: Bool
    ) -> Bool {
        predictionEnabled
            && passes.count == 1
            && exactPass(
                passes[0],
                source: "pencil",
                capabilities: ["pressure"],
                strokeCount: 1
            )
            && matchesStroke(
                passes[0].strokes[0],
                points: [(128, 24), (196, 92), (128, 232)],
                pressures: [0.55, 0.55, 0.55],
                interval: 0.014,
                predictedIndex: 1
            )
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
