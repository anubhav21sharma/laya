#if DEBUG
import EditorCore
import Foundation
import PatternEngine

enum BrushLabManualGesture:
    String, Codable, CaseIterable, Sendable
{
    case tap
    case slowLine
    case fastLine
    case curve
    case zigZag
    case directionReversal
}

enum BrushLabManualBackground:
    String, Codable, CaseIterable, Sendable
{
    case transparent
    case opaque
}

enum BrushLabManualTool: String, Codable, Sendable {
    case draw
    case erase
}

enum BrushLabManualSubstrate: String, Codable, Sendable {
    case none
    case recordedOpaqueStroke
}

struct BrushLabManualCard: Codable, Equatable, Sendable {
    static let schemaVersion: UInt16 = 1
    static let customAsymmetricFixture =
        "custom-asymmetric-shape-grain-v1"

    let cardID: String
    let schemaVersion: UInt16
    let brushID: String
    let gesture: BrushLabManualGesture
    let diameter: Float
    let pressureProfile: String
    let inputCapabilities: [String]
    let documentConfiguration: SymmetryDocumentConfiguration
    let background: BrushLabManualBackground
    let predictionEnabled: Bool
    let paintRGBAHex: String
    let customResourceFixture: String?
    let tool: BrushLabManualTool
    let substrate: BrushLabManualSubstrate

    var documentMode: String {
        Self.documentMode(documentConfiguration)
    }

    var paintColor: InkColor {
        switch paintRGBAHex {
        case "#C43A52FF":
            InkColor(
                red: 196 / 255,
                green: 58 / 255,
                blue: 82 / 255,
                alpha: 1
            )!
        case "#245EC7FF":
            InkColor(
                red: 36 / 255,
                green: 94 / 255,
                blue: 199 / 255,
                alpha: 1
            )!
        default:
            InkColor(
                red: 17 / 255,
                green: 17 / 255,
                blue: 17 / 255,
                alpha: 1
            )!
        }
    }

    static let fixedMatrix: [BrushLabManualCard] = {
        AnchorBrushCatalog.all.flatMap { anchor in
            scenarios.map { scenario in
                BrushLabManualCard(
                    anchor: anchor,
                    scenario: scenario
                )
            }
        }.sorted { $0.cardID < $1.cardID }
    }()

    private init(anchor: AnchorBrushEntry, scenario: Scenario) {
        schemaVersion = Self.schemaVersion
        brushID = anchor.id.rawValue
        gesture = scenario.gesture
        diameter = scenario.diameter
        pressureProfile = scenario.pressureProfile
        inputCapabilities = scenario.inputCapabilities
        documentConfiguration = scenario.documentConfiguration
        background = scenario.background
        predictionEnabled = scenario.predictionEnabled
        paintRGBAHex = scenario.paintRGBAHex
        customResourceFixture = scenario.customResourceFixture
        tool = anchor.role == .erase ? .erase : .draw
        substrate = anchor.role == .erase
            ? .recordedOpaqueStroke
            : .none
        cardID = Self.makeID(
            brushID: brushID,
            gesture: gesture,
            diameter: diameter,
            pressureProfile: pressureProfile,
            inputCapabilities: inputCapabilities,
            documentConfiguration: documentConfiguration,
            background: background,
            predictionEnabled: predictionEnabled,
            paintRGBAHex: paintRGBAHex,
            customResourceFixture: customResourceFixture,
            tool: tool,
            substrate: substrate
        )
    }

    func traceSamples() -> [StrokeSample] {
        makeTraceSamples(
            pressure: pressureValue,
            capabilities: strokeCapabilities,
            predictionEnabled: predictionEnabled
        )
    }

    func substrateTraceSamples() -> [StrokeSample] {
        makeTraceSamples(
            pressure: 1,
            capabilities: [],
            predictionEnabled: false
        )
    }

    private func makeTraceSamples(
        pressure: Float,
        capabilities: StrokeInputCapabilities,
        predictionEnabled: Bool
    ) -> [StrokeSample] {
        let points = tracePoints
        let source: StrokeSource = .mouse
        let interval: TimeInterval = gesture == .slowLine ? 0.05 : 0.008
        return points.enumerated().map { index, point in
            let phase: StrokePhase
            if index == 0 {
                phase = .began
            } else if index == points.count - 1 {
                phase = .ended
            } else {
                phase = .moved
            }
            let predictedIndex = max(1, points.count - 2)
            return StrokeSample(
                position: point,
                pressure: pressure,
                timestamp: 1 + Double(index) * interval,
                phase: phase,
                source: source,
                kind: predictionEnabled && index == predictedIndex
                    ? .predicted
                    : .actual,
                capabilities: capabilities,
                altitude: capabilities.contains(.altitude)
                    ? .pi / 4
                    : nil,
                azimuth: capabilities.contains(.azimuth) ? 0.7 : nil,
                roll: capabilities.contains(.roll) ? 0.3 : nil
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case cardID
        case schemaVersion
        case brushID
        case gesture
        case diameter
        case pressureProfile
        case inputCapabilities
        case documentConfiguration
        case background
        case predictionEnabled
        case paintRGBAHex
        case customResourceFixture
        case tool
        case substrate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cardID = try container.decode(String.self, forKey: .cardID)
        schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        brushID = try container.decode(String.self, forKey: .brushID)
        gesture = try container.decode(
            BrushLabManualGesture.self,
            forKey: .gesture
        )
        diameter = try container.decode(Float.self, forKey: .diameter)
        pressureProfile = try container.decode(
            String.self,
            forKey: .pressureProfile
        )
        inputCapabilities = try container.decode(
            [String].self,
            forKey: .inputCapabilities
        )
        documentConfiguration = try container.decode(
            DocumentConfigurationPayload.self,
            forKey: .documentConfiguration
        ).configuration
        background = try container.decode(
            BrushLabManualBackground.self,
            forKey: .background
        )
        predictionEnabled = try container.decode(
            Bool.self,
            forKey: .predictionEnabled
        )
        paintRGBAHex = try container.decode(
            String.self,
            forKey: .paintRGBAHex
        )
        customResourceFixture = try container.decodeIfPresent(
            String.self,
            forKey: .customResourceFixture
        )
        tool = try container.decode(
            BrushLabManualTool.self,
            forKey: .tool
        )
        substrate = try container.decode(
            BrushLabManualSubstrate.self,
            forKey: .substrate
        )
        let expectedID = Self.makeID(
            brushID: brushID,
            gesture: gesture,
            diameter: diameter,
            pressureProfile: pressureProfile,
            inputCapabilities: inputCapabilities,
            documentConfiguration: documentConfiguration,
            background: background,
            predictionEnabled: predictionEnabled,
            paintRGBAHex: paintRGBAHex,
            customResourceFixture: customResourceFixture,
            tool: tool,
            substrate: substrate
        )
        guard cardID == expectedID else {
            throw BrushLabManualCardCodingError.identityMismatch(
                expected: expectedID,
                actual: cardID
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cardID, forKey: .cardID)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(brushID, forKey: .brushID)
        try container.encode(gesture, forKey: .gesture)
        try container.encode(diameter, forKey: .diameter)
        try container.encode(pressureProfile, forKey: .pressureProfile)
        try container.encode(
            inputCapabilities,
            forKey: .inputCapabilities
        )
        try container.encode(
            DocumentConfigurationPayload(documentConfiguration),
            forKey: .documentConfiguration
        )
        try container.encode(background, forKey: .background)
        try container.encode(
            predictionEnabled,
            forKey: .predictionEnabled
        )
        try container.encode(paintRGBAHex, forKey: .paintRGBAHex)
        try container.encodeIfPresent(
            customResourceFixture,
            forKey: .customResourceFixture
        )
        try container.encode(tool, forKey: .tool)
        try container.encode(substrate, forKey: .substrate)
    }

    private var pressureValue: Float {
        switch pressureProfile {
        case "low": 0.2
        case "high": 0.9
        default: 0.5
        }
    }

    private var strokeCapabilities: StrokeInputCapabilities {
        inputCapabilities.reduce(into: StrokeInputCapabilities()) {
            capabilities,
            name in
            switch name {
            case "pressure": capabilities.insert(.pressure)
            case "altitude": capabilities.insert(.altitude)
            case "azimuth": capabilities.insert(.azimuth)
            case "roll": capabilities.insert(.roll)
            default: break
            }
        }
    }

    private var tracePoints: [ScreenPoint] {
        switch gesture {
        case .tap:
            [
                ScreenPoint(x: 128, y: 128),
                ScreenPoint(x: 128, y: 128),
                ScreenPoint(x: 128, y: 128),
            ]
        case .slowLine, .fastLine:
            [
                ScreenPoint(x: 48, y: 128),
                ScreenPoint(x: 88, y: 128),
                ScreenPoint(x: 128, y: 128),
                ScreenPoint(x: 168, y: 128),
                ScreenPoint(x: 208, y: 128),
            ]
        case .curve:
            [
                ScreenPoint(x: 48, y: 160),
                ScreenPoint(x: 72, y: 112),
                ScreenPoint(x: 112, y: 80),
                ScreenPoint(x: 160, y: 88),
                ScreenPoint(x: 208, y: 136),
            ]
        case .zigZag:
            [
                ScreenPoint(x: 40, y: 176),
                ScreenPoint(x: 72, y: 80),
                ScreenPoint(x: 104, y: 176),
                ScreenPoint(x: 136, y: 80),
                ScreenPoint(x: 168, y: 176),
                ScreenPoint(x: 208, y: 80),
            ]
        case .directionReversal:
            [
                ScreenPoint(x: 48, y: 128),
                ScreenPoint(x: 112, y: 128),
                ScreenPoint(x: 192, y: 128),
                ScreenPoint(x: 128, y: 128),
                ScreenPoint(x: 64, y: 128),
            ]
        }
    }

    private static func makeID(
        brushID: String,
        gesture: BrushLabManualGesture,
        diameter: Float,
        pressureProfile: String,
        inputCapabilities: [String],
        documentConfiguration: SymmetryDocumentConfiguration,
        background: BrushLabManualBackground,
        predictionEnabled: Bool,
        paintRGBAHex: String,
        customResourceFixture: String?,
        tool: BrushLabManualTool,
        substrate: BrushLabManualSubstrate
    ) -> String {
        let capability = inputCapabilities.isEmpty
            ? "none"
            : inputCapabilities.joined(separator: "-")
        let custom = customResourceFixture == nil
            ? "builtin"
            : "custom"
        let paint = paintRGBAHex
            .lowercased()
            .filter(\.isHexDigit)
        return [
            brushID,
            tool.rawValue,
            gesture.rawValue,
            "d\(Int(diameter))",
            pressureProfile,
            capability,
            documentMode(documentConfiguration),
            background.rawValue,
            predictionEnabled ? "prediction-on" : "prediction-off",
            "c\(paint)",
            substrate.rawValue,
            custom,
        ].joined(separator: ".")
    }

    private static func documentMode(
        _ configuration: SymmetryDocumentConfiguration
    ) -> String {
        switch configuration {
        case .finite(.plain):
            "plain"
        case .finite(.radial):
            "finite-radial"
        case let .periodic(periodic):
            periodic.presetID == .grid ? "periodic" : "reflected"
        }
    }

    private struct Scenario {
        let gesture: BrushLabManualGesture
        let diameter: Float
        let pressureProfile: String
        let inputCapabilities: [String]
        let documentConfiguration: SymmetryDocumentConfiguration
        let background: BrushLabManualBackground
        let predictionEnabled: Bool
        let paintRGBAHex: String
        let customResourceFixture: String?
    }

    private static let periodic = SymmetryDocumentConfiguration.periodic(
        PeriodicSymmetryConfiguration.defaultConfiguration(
            presetID: .grid,
            canonicalRasterSize: PixelSize(width: 256, height: 256)
        )
    )
    private static let reflected = SymmetryDocumentConfiguration.periodic(
        PeriodicSymmetryConfiguration.defaultConfiguration(
            presetID: .mirrorX,
            canonicalRasterSize: PixelSize(width: 256, height: 256)
        )
    )
    private static let radial = SymmetryDocumentConfiguration.finite(
        .radial(
            RadialSymmetryConfiguration(
                kind: .mirror,
                rayCount: 8,
                center: WorldPoint(x: 1_024, y: 1_024)
            )
        )
    )
    private static let capabilityProfiles = [
        [],
        ["pressure"],
        ["pressure", "altitude", "azimuth"],
        ["pressure", "altitude", "azimuth", "roll"],
    ]
    private static let scenarios: [Scenario] = {
        let diameters: [Float] = [2, 20, 2_000]
        let pressures = ["low", "medium", "high"]
        let documents: [SymmetryDocumentConfiguration] = [
            .finite(.plain),
            periodic,
            reflected,
            radial,
        ]
        let backgrounds = BrushLabManualBackground.allCases
        let paints = ["#111111FF", "#C43A52FF", "#245EC7FF"]
        // Deterministic mixed-level covering array. Every pair of levels
        // across gesture/diameter/pressure/capabilities/document/background/
        // prediction/paint occurs at least once.
        let coveringRows = [
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 1, 1, 1, 1, 1, 1, 1],
            [1, 2, 2, 2, 2, 0, 1, 2],
            [2, 0, 1, 3, 3, 1, 0, 2],
            [3, 1, 0, 2, 2, 1, 0, 0],
            [4, 2, 0, 1, 3, 0, 0, 1],
            [5, 2, 2, 3, 0, 1, 1, 0],
            [3, 0, 2, 0, 1, 0, 1, 1],
            [5, 1, 0, 3, 1, 0, 0, 2],
            [1, 1, 1, 0, 3, 1, 0, 0],
            [2, 1, 1, 2, 0, 0, 1, 1],
            [4, 0, 1, 0, 2, 1, 1, 2],
            [2, 2, 2, 1, 1, 0, 0, 0],
            [1, 0, 0, 1, 0, 0, 1, 2],
            [0, 0, 2, 2, 3, 0, 1, 2],
            [0, 2, 1, 3, 2, 0, 0, 1],
            [4, 1, 2, 2, 1, 0, 0, 0],
            [5, 0, 1, 1, 2, 0, 0, 1],
            [3, 2, 1, 0, 0, 0, 0, 2],
            [1, 0, 0, 3, 1, 0, 0, 1],
            [2, 0, 0, 0, 2, 0, 0, 0],
            [3, 0, 0, 1, 3, 0, 0, 0],
            [4, 0, 0, 3, 0, 0, 0, 0],
            [5, 0, 0, 0, 3, 0, 0, 0],
            [3, 0, 0, 3, 0, 0, 0, 0],
            [5, 0, 0, 2, 0, 0, 0, 0],
        ]
        return coveringRows.enumerated().map { index, row in
            Scenario(
                gesture: BrushLabManualGesture.allCases[row[0]],
                diameter: diameters[row[1]],
                pressureProfile: pressures[row[2]],
                inputCapabilities: capabilityProfiles[row[3]],
                documentConfiguration: documents[row[4]],
                background: backgrounds[row[5]],
                predictionEnabled: row[6] == 1,
                paintRGBAHex: paints[row[7]],
                customResourceFixture: [0, 11].contains(index)
                    ? customAsymmetricFixture
                    : nil
            )
        }
    }()
}

struct BrushLabManualAssessment: Codable, Equatable, Sendable {
    let cardID: String
    let responsiveness: String?
    let edgeQuality: String?
    let textureCohesion: String?
    let buildup: String?
    let symmetryBehavior: String?
    let eraserMatch: String?
    let notes: String?

    init(
        cardID: String,
        responsiveness: String? = nil,
        edgeQuality: String? = nil,
        textureCohesion: String? = nil,
        buildup: String? = nil,
        symmetryBehavior: String? = nil,
        eraserMatch: String? = nil,
        notes: String? = nil
    ) {
        self.cardID = cardID
        self.responsiveness = responsiveness
        self.edgeQuality = edgeQuality
        self.textureCohesion = textureCohesion
        self.buildup = buildup
        self.symmetryBehavior = symmetryBehavior
        self.eraserMatch = eraserMatch
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case cardID
        case responsiveness
        case edgeQuality
        case textureCohesion
        case buildup
        case symmetryBehavior
        case eraserMatch
        case notes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cardID, forKey: .cardID)
        try container.encode(responsiveness, forKey: .responsiveness)
        try container.encode(edgeQuality, forKey: .edgeQuality)
        try container.encode(textureCohesion, forKey: .textureCohesion)
        try container.encode(buildup, forKey: .buildup)
        try container.encode(
            symmetryBehavior,
            forKey: .symmetryBehavior
        )
        try container.encode(eraserMatch, forKey: .eraserMatch)
        try container.encode(notes, forKey: .notes)
    }
}

private struct DocumentConfigurationPayload: Codable {
    let mode: String
    let presetID: UInt32?
    let repeatWidth: Float?
    let repeatHeight: Float?
    let orientationRadians: Float?
    let radialKind: RadialSymmetryKind?
    let rayCount: Int?
    let centerX: Float?
    let centerY: Float?
    let referenceAngleRadians: Float?

    init(_ configuration: SymmetryDocumentConfiguration) {
        switch configuration {
        case let .periodic(periodic):
            mode = "periodic"
            presetID = periodic.presetID.rawValue
            repeatWidth = periodic.repeatSize.width
            repeatHeight = periodic.repeatSize.height
            orientationRadians = periodic.orientationRadians
            radialKind = nil
            rayCount = nil
            centerX = nil
            centerY = nil
            referenceAngleRadians = nil
        case .finite(.plain):
            mode = "plain"
            presetID = nil
            repeatWidth = nil
            repeatHeight = nil
            orientationRadians = nil
            radialKind = nil
            rayCount = nil
            centerX = nil
            centerY = nil
            referenceAngleRadians = nil
        case let .finite(.radial(radial)):
            mode = "radial"
            presetID = nil
            repeatWidth = nil
            repeatHeight = nil
            orientationRadians = nil
            radialKind = radial.kind
            rayCount = radial.rayCount
            centerX = radial.center.x
            centerY = radial.center.y
            referenceAngleRadians = radial.referenceAngleRadians
        }
    }

    var configuration: SymmetryDocumentConfiguration {
        get throws {
            switch mode {
            case "periodic":
                guard let rawPresetID = presetID,
                      let presetID = SymmetryPresetID(rawValue: rawPresetID),
                      let repeatWidth,
                      let repeatHeight,
                      let orientationRadians
                else {
                    throw BrushLabManualCardCodingError
                        .invalidDocumentConfiguration
                }
                return .periodic(
                    PeriodicSymmetryConfiguration(
                        presetID: presetID,
                        repeatSize: PatternSize(
                            width: repeatWidth,
                            height: repeatHeight
                        ),
                        orientationRadians: orientationRadians
                    )
                )
            case "plain":
                return .finite(.plain)
            case "radial":
                guard let radialKind,
                      let rayCount,
                      let centerX,
                      let centerY,
                      let referenceAngleRadians
                else {
                    throw BrushLabManualCardCodingError
                        .invalidDocumentConfiguration
                }
                return .finite(
                    .radial(
                        RadialSymmetryConfiguration(
                            kind: radialKind,
                            rayCount: rayCount,
                            center: WorldPoint(x: centerX, y: centerY),
                            referenceAngleRadians:
                                referenceAngleRadians
                        )
                    )
                )
            default:
                throw BrushLabManualCardCodingError
                    .invalidDocumentConfiguration
            }
        }
    }
}

private enum BrushLabManualCardCodingError: Error {
    case invalidDocumentConfiguration
    case identityMismatch(expected: String, actual: String)
}
#endif
