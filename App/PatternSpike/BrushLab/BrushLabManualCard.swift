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
    case pressureRamp
    case tiltSweep
    case sharpCorner
    case crossHatch
    case repeatedBuildup
    case periodicSeamCrossing
    case radialRotation
    case radialReflection
    case eraserRetrace
    case mouseFallback
    case tabletInput
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

    /// Compatibility spelling for callers that enumerate both evidence
    /// families. The returned value has the independent Stage 5 schema.
    static var professionalFixedMatrix: [BrushLabProfessionalManualCard] {
        BrushLabProfessionalManualCard.fixedMatrix
    }

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
        try Self.validateCustomResourceFixture(customResourceFixture)
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
        case .pressureRamp, .tiltSweep, .mouseFallback, .tabletInput:
            [
                ScreenPoint(x: 48, y: 128),
                ScreenPoint(x: 88, y: 112),
                ScreenPoint(x: 128, y: 128),
                ScreenPoint(x: 168, y: 144),
                ScreenPoint(x: 208, y: 128),
            ]
        case .sharpCorner:
            [
                ScreenPoint(x: 48, y: 192),
                ScreenPoint(x: 128, y: 192),
                ScreenPoint(x: 128, y: 64),
                ScreenPoint(x: 208, y: 64),
            ]
        case .crossHatch, .repeatedBuildup, .eraserRetrace:
            [
                ScreenPoint(x: 56, y: 64),
                ScreenPoint(x: 200, y: 192),
                ScreenPoint(x: 56, y: 192),
                ScreenPoint(x: 200, y: 64),
            ]
        case .periodicSeamCrossing:
            [
                ScreenPoint(x: 4, y: 128),
                ScreenPoint(x: 128, y: 128),
                ScreenPoint(x: 252, y: 128),
            ]
        case .radialRotation, .radialReflection:
            [
                ScreenPoint(x: 128, y: 24),
                ScreenPoint(x: 196, y: 92),
                ScreenPoint(x: 128, y: 232),
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
        let paint = paintRGBAHex
            .lowercased()
            .filter(\.isHexDigit)
        return [
            brushID,
            tool.rawValue,
            gesture.rawValue,
            "d\(floatIdentity(diameter))",
            pressureProfile,
            capability,
            documentIdentity(documentConfiguration),
            background.rawValue,
            predictionEnabled ? "prediction-on" : "prediction-off",
            "c\(paint)",
            substrate.rawValue,
            "f\(customResourceFixture ?? "builtin")",
        ].joined(separator: ".")
    }

    private static func documentIdentity(
        _ configuration: SymmetryDocumentConfiguration
    ) -> String {
        switch configuration {
        case let .periodic(periodic):
            return [
                "periodic",
                "p\(periodic.presetID.rawValue)",
                "w\(floatIdentity(periodic.repeatSize.width))",
                "h\(floatIdentity(periodic.repeatSize.height))",
                "o\(floatIdentity(periodic.orientationRadians))",
            ].joined(separator: "-")
        case .finite(.plain):
            return "finite-plain"
        case let .finite(.radial(radial)):
            return [
                "finite-radial",
                "k\(radial.kind.rawValue)",
                "r\(radial.rayCount)",
                "x\(floatIdentity(radial.center.x))",
                "y\(floatIdentity(radial.center.y))",
                "a\(floatIdentity(radial.referenceAngleRadians))",
            ].joined(separator: "-")
        }
    }

    private static func floatIdentity(_ value: Float) -> String {
        String(value.bitPattern, radix: 16)
    }

    private static func validateCustomResourceFixture(
        _ fixture: String?
    ) throws {
        guard fixture == nil || fixture == customAsymmetricFixture else {
            throw BrushLabManualCardCodingError
                .unsupportedCustomResourceFixture(fixture!)
        }
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
        // Deterministic mixed-level covering array. Crossing each base row
        // with both real fixture levels makes fixture identity independent
        // from gesture/diameter/pressure/capabilities/document/background/
        // prediction/paint.
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
        return coveringRows.flatMap { row in
            [nil, customAsymmetricFixture].map { fixture in
                Scenario(
                    gesture: BrushLabManualGesture.allCases[row[0]],
                    diameter: diameters[row[1]],
                    pressureProfile: pressures[row[2]],
                    inputCapabilities: capabilityProfiles[row[3]],
                    documentConfiguration: documents[row[4]],
                    background: backgrounds[row[5]],
                    predictionEnabled: row[6] == 1,
                    paintRGBAHex: paints[row[7]],
                    customResourceFixture: fixture
                )
            }
        }
    }()

}

enum BrushLabProfessionalBrushRole:
    String, Codable, Hashable, Sendable
{
    case professionalDraw
    case nativeEraser
}

enum BrushLabProfessionalInputSource: String, Codable, Sendable {
    case mouse
    case pencil
    case tablet

    var strokeSource: StrokeSource {
        switch self {
        case .mouse: .mouse
        case .pencil: .pencil
        case .tablet: .tablet
        }
    }
}

enum BrushLabProfessionalSamplePhase: String, Codable, Sendable {
    case began
    case moved
    case ended

    var strokePhase: StrokePhase {
        switch self {
        case .began: .began
        case .moved: .moved
        case .ended: .ended
        }
    }
}

enum BrushLabProfessionalSampleKind: String, Codable, Sendable {
    case actual
    case predicted

    var strokeKind: StrokeSampleKind {
        switch self {
        case .actual: .actual
        case .predicted: .predicted
        }
    }
}

struct BrushLabProfessionalManualSample: Codable, Equatable, Sendable {
    let sampleIndex: Int
    let x: Float
    let y: Float
    let pressure: Float
    let timeOffset: TimeInterval
    let phase: BrushLabProfessionalSamplePhase
    let kind: BrushLabProfessionalSampleKind
    let altitude: Float?
    let azimuth: Float?
    let roll: Float?

    private enum CodingKeys: String, CodingKey {
        case sampleIndex
        case x
        case y
        case pressure
        case timeOffset
        case phase
        case kind
        case altitude
        case azimuth
        case roll
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sampleIndex, forKey: .sampleIndex)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(pressure, forKey: .pressure)
        try container.encode(timeOffset, forKey: .timeOffset)
        try container.encode(phase, forKey: .phase)
        try container.encode(kind, forKey: .kind)
        try container.encode(altitude, forKey: .altitude)
        try container.encode(azimuth, forKey: .azimuth)
        try container.encode(roll, forKey: .roll)
    }
}

struct BrushLabProfessionalManualStroke: Codable, Equatable, Sendable {
    let strokeIndex: Int
    let samples: [BrushLabProfessionalManualSample]
}

struct BrushLabProfessionalManualPass: Codable, Equatable, Sendable {
    let passIndex: Int
    let role: BrushLabProfessionalBrushRole
    let tool: BrushLabManualTool
    let brushID: String
    let nominalDiameter: Float
    let inputSource: BrushLabProfessionalInputSource
    let capabilities: [String]
    let strokes: [BrushLabProfessionalManualStroke]

    var strokeCapabilities: StrokeInputCapabilities {
        capabilities.reduce(into: StrokeInputCapabilities()) {
            result,
            name in
            switch name {
            case "pressure": result.insert(.pressure)
            case "altitude": result.insert(.altitude)
            case "azimuth": result.insert(.azimuth)
            case "roll": result.insert(.roll)
            default: break
            }
        }
    }

    func samples(
        for stroke: BrushLabProfessionalManualStroke,
        baseTimestamp: TimeInterval
    ) -> [StrokeSample] {
        stroke.samples.map { sample in
            StrokeSample(
                position: ScreenPoint(x: sample.x, y: sample.y),
                pressure: sample.pressure,
                timestamp: baseTimestamp + sample.timeOffset,
                phase: sample.phase.strokePhase,
                source: inputSource.strokeSource,
                kind: sample.kind.strokeKind,
                capabilities: strokeCapabilities,
                altitude: sample.altitude,
                azimuth: sample.azimuth,
                roll: sample.roll
            )
        }
    }
}

/// Stage 5 cards encode the exact ordered review actions. Stage 4 continues to
/// use `BrushLabManualCard` schema v1 and its frozen encoder.
struct BrushLabProfessionalManualCard: Codable, Equatable, Sendable {
    static let schemaVersion: UInt16 = 2

    let cardID: String
    let schemaVersion: UInt16
    let brushID: String
    let gesture: BrushLabManualGesture
    let documentConfiguration: SymmetryDocumentConfiguration
    let background: BrushLabManualBackground
    let predictionEnabled: Bool
    let paintRGBAHex: String
    let passes: [BrushLabProfessionalManualPass]

    var nominalDiameter: Float {
        passes.first?.nominalDiameter ?? 0
    }

    var documentMode: String {
        switch documentConfiguration {
        case .finite(.plain): "plain"
        case .finite(.radial): "finite-radial"
        case .periodic: "periodic"
        }
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

    static let fixedMatrix: [BrushLabProfessionalManualCard] =
        ProfessionalBrushCatalog.all.flatMap(makeCards).sorted {
            $0.cardID < $1.cardID
        }

    func traceSamples() -> [StrokeSample] {
        passes.flatMap { pass in
            pass.strokes.flatMap { stroke in
                pass.samples(
                    for: stroke,
                    baseTimestamp:
                        1 + Double(pass.passIndex * 100 + stroke.strokeIndex * 10)
                )
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case cardID
        case schemaVersion
        case brushID
        case gesture
        case documentConfiguration
        case background
        case predictionEnabled
        case paintRGBAHex
        case passes
    }

    private init(
        entry: ProfessionalBrushEntry,
        gesture: BrushLabManualGesture,
        variant: String = "standard",
        documentConfiguration: SymmetryDocumentConfiguration = .finite(.plain),
        background: BrushLabManualBackground,
        predictionEnabled: Bool,
        paintRGBAHex: String,
        passes: [BrushLabProfessionalManualPass]
    ) {
        schemaVersion = Self.schemaVersion
        brushID = entry.id.rawValue
        self.gesture = gesture
        self.documentConfiguration = documentConfiguration
        self.background = background
        self.predictionEnabled = predictionEnabled
        self.paintRGBAHex = paintRGBAHex
        self.passes = passes
        cardID = Self.makeID(
            brushID: entry.id.rawValue,
            gesture: gesture,
            variant: variant
        )
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
        passes = try container.decode(
            [BrushLabProfessionalManualPass].self,
            forKey: .passes
        )
        let variant: String
        if gesture == .tap {
            switch passes.first?.nominalDiameter {
            case 2: variant = "minimum"
            case 20: variant = "nominal"
            case 2_000: variant = "maximum"
            default:
                throw BrushLabManualCardCodingError
                    .invalidProfessionalReviewCard
            }
        } else {
            variant = "standard"
        }
        guard schemaVersion == Self.schemaVersion,
              cardID == Self.makeID(
                  brushID: brushID,
                  gesture: gesture,
                  variant: variant
              )
        else {
            throw BrushLabManualCardCodingError.identityMismatch(
                expected: Self.makeID(
                    brushID: brushID,
                    gesture: gesture,
                    variant: variant
                ),
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
        try container.encode(passes, forKey: .passes)
    }

    private static func makeID(
        brushID: String,
        gesture: BrushLabManualGesture,
        variant: String
    ) -> String {
        "\(brushID).review.\(gesture.rawValue).\(variant)"
    }

    private static func makeCards(
        _ entry: ProfessionalBrushEntry
    ) -> [BrushLabProfessionalManualCard] {
        let brushID = entry.id.rawValue
        let pencil = BrushLabProfessionalInputSource.pencil
        let pressure = ["pressure"]
        let standardLine = [
            ScreenPoint(x: 48, y: 128),
            ScreenPoint(x: 88, y: 128),
            ScreenPoint(x: 128, y: 128),
            ScreenPoint(x: 168, y: 128),
            ScreenPoint(x: 208, y: 128),
        ]
        let expressiveLine = [
            ScreenPoint(x: 48, y: 128),
            ScreenPoint(x: 88, y: 112),
            ScreenPoint(x: 128, y: 128),
            ScreenPoint(x: 168, y: 144),
            ScreenPoint(x: 208, y: 128),
        ]
        func drawPass(
            diameter: Float = 20,
            source: BrushLabProfessionalInputSource = pencil,
            capabilities: [String] = pressure,
            strokes: [BrushLabProfessionalManualStroke]
        ) -> BrushLabProfessionalManualPass {
            BrushLabProfessionalManualPass(
                passIndex: 0,
                role: .professionalDraw,
                tool: .draw,
                brushID: brushID,
                nominalDiameter: diameter,
                inputSource: source,
                capabilities: capabilities,
                strokes: strokes
            )
        }
        func card(
            _ gesture: BrushLabManualGesture,
            variant: String = "standard",
            document: SymmetryDocumentConfiguration = .finite(.plain),
            background: BrushLabManualBackground = .transparent,
            prediction: Bool = false,
            paint: String = "#111111FF",
            passes: [BrushLabProfessionalManualPass]
        ) -> BrushLabProfessionalManualCard {
            BrushLabProfessionalManualCard(
                entry: entry,
                gesture: gesture,
                variant: variant,
                documentConfiguration: document,
                background: background,
                predictionEnabled: prediction,
                paintRGBAHex: paint,
                passes: passes
            )
        }
        let tapPoints = Array(
            repeating: ScreenPoint(x: 128, y: 128),
            count: 3
        )
        let retracePoints = [
            ScreenPoint(x: 56, y: 72),
            ScreenPoint(x: 92, y: 104),
            ScreenPoint(x: 128, y: 136),
            ScreenPoint(x: 164, y: 168),
            ScreenPoint(x: 200, y: 200),
        ]
        let retraceStroke = makeStroke(
            index: 0,
            points: retracePoints,
            pressures: Array(repeating: 0.65, count: retracePoints.count),
            interval: 0.012
        )
        let eraserPass = BrushLabProfessionalManualPass(
            passIndex: 1,
            role: .nativeEraser,
            tool: .erase,
            brushID: EditorBrushCatalog.eraser.id.rawValue,
            nominalDiameter: 20,
            inputSource: pencil,
            capabilities: pressure,
            strokes: [retraceStroke]
        )
        let periodic = SymmetryDocumentConfiguration.periodic(
            PeriodicSymmetryConfiguration.defaultConfiguration(
                presetID: .grid,
                canonicalRasterSize: PixelSize(width: 256, height: 256)
            )
        )
        let radialRotation = SymmetryDocumentConfiguration.finite(
            .radial(
                RadialSymmetryConfiguration(
                    kind: .rotation,
                    rayCount: 8,
                    center: WorldPoint(x: 1_024, y: 1_024)
                )
            )
        )
        let radialReflection = SymmetryDocumentConfiguration.finite(
            .radial(
                RadialSymmetryConfiguration(
                    kind: .mirror,
                    rayCount: 8,
                    center: WorldPoint(x: 1_024, y: 1_024)
                )
            )
        )
        let crossHatchStrokes = [
            [ScreenPoint(x: 56, y: 72), ScreenPoint(x: 184, y: 200)],
            [ScreenPoint(x: 88, y: 56), ScreenPoint(x: 216, y: 184)],
            [ScreenPoint(x: 56, y: 184), ScreenPoint(x: 184, y: 56)],
            [ScreenPoint(x: 88, y: 200), ScreenPoint(x: 216, y: 72)],
        ].enumerated().map {
            makeStroke(
                index: $0.offset,
                points: $0.element,
                pressures: [0.72, 0.72],
                interval: 0.025
            )
        }
        let buildupStroke = makeStroke(
            index: 0,
            points: standardLine,
            pressures: Array(repeating: 0.7, count: standardLine.count),
            interval: 0.012
        )
        let buildupStrokes = (0..<4).map {
            BrushLabProfessionalManualStroke(
                strokeIndex: $0,
                samples: buildupStroke.samples
            )
        }
        let pressureRamp = makeStroke(
            index: 0,
            points: expressiveLine,
            pressures: [0.1, 0.325, 0.55, 0.775, 1],
            interval: 0.014
        )
        let tiltSweep = makeStroke(
            index: 0,
            points: expressiveLine,
            pressures: [0.55, 0.55, 0.55, 0.55, 0.55],
            interval: 0.014,
            altitudes: [1.3, 1.05, 0.8, 0.55, 0.3],
            azimuths: [0.2, 0.5, 0.8, 1.1, 1.4],
            predicted: true
        )
        let tabletStroke = makeStroke(
            index: 0,
            points: expressiveLine,
            pressures: [0.25, 0.45, 0.65, 0.8, 0.6],
            interval: 0.012,
            altitudes: [1.2, 1.05, 0.9, 0.7, 0.5],
            azimuths: [0.1, 0.35, 0.6, 0.85, 1.1],
            rolls: [-0.3, -0.15, 0, 0.15, 0.3],
            predicted: true
        )
        return [
            card(.tap, variant: "minimum", passes: [
                drawPass(
                    diameter: 2,
                    strokes: [makeStroke(
                        index: 0,
                        points: tapPoints,
                        pressures: [0.25, 0.25, 0.25],
                        interval: 0.01
                    )]
                ),
            ]),
            card(.tap, variant: "nominal", passes: [
                drawPass(strokes: [makeStroke(
                    index: 0,
                    points: tapPoints,
                    pressures: [0.55, 0.55, 0.55],
                    interval: 0.01
                )]),
            ]),
            card(.tap, variant: "maximum", passes: [
                drawPass(
                    diameter: 2_000,
                    strokes: [makeStroke(
                        index: 0,
                        points: tapPoints,
                        pressures: [0.9, 0.9, 0.9],
                        interval: 0.01
                    )]
                ),
            ]),
            card(.slowLine, background: .opaque, passes: [
                drawPass(strokes: [makeStroke(
                    index: 0,
                    points: standardLine,
                    pressures: Array(repeating: 0.55, count: 5),
                    interval: 0.05
                )]),
            ]),
            card(
                .fastLine,
                background: .opaque,
                prediction: true,
                passes: [drawPass(strokes: [makeStroke(
                    index: 0,
                    points: standardLine,
                    pressures: Array(repeating: 0.55, count: 5),
                    interval: 0.004,
                    predicted: true
                )])]
            ),
            card(.pressureRamp, passes: [
                drawPass(strokes: [pressureRamp]),
            ]),
            card(
                .tiltSweep,
                prediction: true,
                passes: [drawPass(
                    capabilities: ["pressure", "altitude", "azimuth"],
                    strokes: [tiltSweep]
                )]
            ),
            card(
                .curve,
                background: .opaque,
                paint: "#C43A52FF",
                passes: [drawPass(strokes: [makeStroke(
                    index: 0,
                    points: [
                        ScreenPoint(x: 48, y: 160),
                        ScreenPoint(x: 72, y: 112),
                        ScreenPoint(x: 112, y: 80),
                        ScreenPoint(x: 160, y: 88),
                        ScreenPoint(x: 208, y: 136),
                    ],
                    pressures: Array(repeating: 0.55, count: 5),
                    interval: 0.014
                )])]
            ),
            card(
                .sharpCorner,
                background: .opaque,
                paint: "#C43A52FF",
                passes: [drawPass(strokes: [makeStroke(
                    index: 0,
                    points: [
                        ScreenPoint(x: 48, y: 192),
                        ScreenPoint(x: 128, y: 192),
                        ScreenPoint(x: 128, y: 64),
                        ScreenPoint(x: 208, y: 64),
                    ],
                    pressures: Array(repeating: 0.55, count: 4),
                    interval: 0.014
                )])]
            ),
            card(
                .crossHatch,
                background: .opaque,
                paint: "#245EC7FF",
                passes: [drawPass(strokes: crossHatchStrokes)]
            ),
            card(
                .repeatedBuildup,
                background: .opaque,
                paint: "#245EC7FF",
                passes: [drawPass(strokes: buildupStrokes)]
            ),
            card(
                .periodicSeamCrossing,
                document: periodic,
                prediction: true,
                passes: [drawPass(strokes: [makeStroke(
                    index: 0,
                    points: [
                        ScreenPoint(x: 4, y: 128),
                        ScreenPoint(x: 128, y: 128),
                        ScreenPoint(x: 252, y: 128),
                    ],
                    pressures: [0.55, 0.55, 0.55],
                    interval: 0.014,
                    predicted: true
                )])]
            ),
            card(
                .radialRotation,
                document: radialRotation,
                prediction: true,
                passes: [drawPass(strokes: [makeStroke(
                    index: 0,
                    points: [
                        ScreenPoint(x: 128, y: 24),
                        ScreenPoint(x: 196, y: 92),
                        ScreenPoint(x: 128, y: 232),
                    ],
                    pressures: [0.55, 0.55, 0.55],
                    interval: 0.014,
                    predicted: true
                )])]
            ),
            card(
                .radialReflection,
                document: radialReflection,
                prediction: true,
                passes: [drawPass(strokes: [makeStroke(
                    index: 0,
                    points: [
                        ScreenPoint(x: 128, y: 24),
                        ScreenPoint(x: 196, y: 92),
                        ScreenPoint(x: 128, y: 232),
                    ],
                    pressures: [0.55, 0.55, 0.55],
                    interval: 0.014,
                    predicted: true
                )])]
            ),
            card(
                .eraserRetrace,
                background: .opaque,
                passes: [
                    drawPass(strokes: [retraceStroke]),
                    eraserPass,
                ]
            ),
            card(.mouseFallback, passes: [
                drawPass(
                    source: .mouse,
                    capabilities: [],
                    strokes: [makeStroke(
                        index: 0,
                        points: expressiveLine,
                        pressures: Array(repeating: 1, count: 5),
                        interval: 0.012
                    )]
                ),
            ]),
            card(
                .tabletInput,
                prediction: true,
                passes: [drawPass(
                    source: .tablet,
                    capabilities: [
                        "pressure", "altitude", "azimuth", "roll",
                    ],
                    strokes: [tabletStroke]
                )]
            ),
        ]
    }

    private static func makeStroke(
        index: Int,
        points: [ScreenPoint],
        pressures: [Float],
        interval: TimeInterval,
        altitudes: [Float]? = nil,
        azimuths: [Float]? = nil,
        rolls: [Float]? = nil,
        predicted: Bool = false
    ) -> BrushLabProfessionalManualStroke {
        precondition(points.count >= 2 && points.count == pressures.count)
        precondition(altitudes == nil || altitudes?.count == points.count)
        precondition(azimuths == nil || azimuths?.count == points.count)
        precondition(rolls == nil || rolls?.count == points.count)
        return BrushLabProfessionalManualStroke(
            strokeIndex: index,
            samples: points.indices.map { sampleIndex in
                BrushLabProfessionalManualSample(
                    sampleIndex: sampleIndex,
                    x: points[sampleIndex].x,
                    y: points[sampleIndex].y,
                    pressure: pressures[sampleIndex],
                    timeOffset: Double(sampleIndex) * interval,
                    phase: sampleIndex == 0
                        ? .began
                        : sampleIndex == points.count - 1 ? .ended : .moved,
                    kind:
                        predicted && sampleIndex == max(1, points.count - 2)
                        ? .predicted
                        : .actual,
                    altitude: altitudes?[sampleIndex],
                    azimuth: azimuths?[sampleIndex],
                    roll: rolls?[sampleIndex]
                )
            }
        )
    }
}

struct BrushLabManualAssessment: Codable, Equatable, Sendable {
    let cardID: String
    let responsiveness: String?
    let edgeQuality: String?
    let taperTermination: String?
    let textureCohesion: String?
    let pressureResponse: String?
    let tiltDirectionResponse: String?
    let buildup: String?
    let symmetryBehavior: String?
    let eraserMatch: String?
    let notes: String?

    init(
        cardID: String,
        responsiveness: String? = nil,
        edgeQuality: String? = nil,
        taperTermination: String? = nil,
        textureCohesion: String? = nil,
        pressureResponse: String? = nil,
        tiltDirectionResponse: String? = nil,
        buildup: String? = nil,
        symmetryBehavior: String? = nil,
        eraserMatch: String? = nil,
        notes: String? = nil
    ) {
        self.cardID = cardID
        self.responsiveness = responsiveness
        self.edgeQuality = edgeQuality
        self.taperTermination = taperTermination
        self.textureCohesion = textureCohesion
        self.pressureResponse = pressureResponse
        self.tiltDirectionResponse = tiltDirectionResponse
        self.buildup = buildup
        self.symmetryBehavior = symmetryBehavior
        self.eraserMatch = eraserMatch
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case cardID
        case responsiveness
        case edgeQuality
        case taperTermination
        case textureCohesion
        case pressureResponse
        case tiltDirectionResponse
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
        try container.encodeIfPresent(
            taperTermination,
            forKey: .taperTermination
        )
        try container.encode(textureCohesion, forKey: .textureCohesion)
        try container.encodeIfPresent(
            pressureResponse,
            forKey: .pressureResponse
        )
        try container.encodeIfPresent(
            tiltDirectionResponse,
            forKey: .tiltDirectionResponse
        )
        try container.encode(buildup, forKey: .buildup)
        try container.encode(
            symmetryBehavior,
            forKey: .symmetryBehavior
        )
        try container.encode(eraserMatch, forKey: .eraserMatch)
        try container.encode(notes, forKey: .notes)
    }
}

struct BrushLabProfessionalManualAssessment:
    Codable, Equatable, Sendable
{
    let cardID: String
    let responsiveness: String?
    let edgeQuality: String?
    let taperTermination: String?
    let textureCohesion: String?
    let pressureResponse: String?
    let tiltDirectionResponse: String?
    let buildup: String?
    let symmetryBehavior: String?
    let eraserMatch: String?
    let notes: String?

    init(
        cardID: String,
        responsiveness: String? = nil,
        edgeQuality: String? = nil,
        taperTermination: String? = nil,
        textureCohesion: String? = nil,
        pressureResponse: String? = nil,
        tiltDirectionResponse: String? = nil,
        buildup: String? = nil,
        symmetryBehavior: String? = nil,
        eraserMatch: String? = nil,
        notes: String? = nil
    ) {
        self.cardID = cardID
        self.responsiveness = responsiveness
        self.edgeQuality = edgeQuality
        self.taperTermination = taperTermination
        self.textureCohesion = textureCohesion
        self.pressureResponse = pressureResponse
        self.tiltDirectionResponse = tiltDirectionResponse
        self.buildup = buildup
        self.symmetryBehavior = symmetryBehavior
        self.eraserMatch = eraserMatch
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case cardID
        case responsiveness
        case edgeQuality
        case taperTermination
        case textureCohesion
        case pressureResponse
        case tiltDirectionResponse
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
        try container.encode(taperTermination, forKey: .taperTermination)
        try container.encode(textureCohesion, forKey: .textureCohesion)
        try container.encode(pressureResponse, forKey: .pressureResponse)
        try container.encode(
            tiltDirectionResponse,
            forKey: .tiltDirectionResponse
        )
        try container.encode(buildup, forKey: .buildup)
        try container.encode(
            symmetryBehavior,
            forKey: .symmetryBehavior
        )
        try container.encode(eraserMatch, forKey: .eraserMatch)
        try container.encode(notes, forKey: .notes)
    }
}

struct BrushLabManualCatalog: Codable, Equatable, Sendable {
    static let schemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let cards: [BrushLabManualCard]
    let assessments: [BrushLabManualAssessment]

    init(
        cards: [BrushLabManualCard],
        assessments: [BrushLabManualAssessment]
    ) {
        schemaVersion = Self.schemaVersion
        self.cards = cards
        self.assessments = assessments
    }

    static func pending(
        cards: [BrushLabManualCard] = BrushLabManualCard.fixedMatrix
    ) -> BrushLabManualCatalog {
        BrushLabManualCatalog(
            cards: cards,
            assessments: cards.map {
                BrushLabManualAssessment(cardID: $0.cardID)
            }
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return try encoder.encode(self)
    }
}

/// Stage 5 professional evidence export. Its separate schema keeps the Stage
/// 4 diagnostic catalog byte-stable and prevents old evidence being presented
/// as professional review material.
struct BrushLabProfessionalManualCatalog: Codable, Equatable, Sendable {
    static let schemaVersion: UInt16 = 3

    let schemaVersion: UInt16
    let cards: [BrushLabProfessionalManualCard]
    let assessments: [BrushLabProfessionalManualAssessment]

    init(
        cards: [BrushLabProfessionalManualCard],
        assessments: [BrushLabProfessionalManualAssessment]
    ) {
        schemaVersion = Self.schemaVersion
        self.cards = cards
        self.assessments = assessments
    }

    static func pending(
        cards: [BrushLabProfessionalManualCard] =
            BrushLabProfessionalManualCard.fixedMatrix
    ) -> BrushLabProfessionalManualCatalog {
        BrushLabProfessionalManualCatalog(
            cards: cards,
            assessments: cards.map {
                BrushLabProfessionalManualAssessment(cardID: $0.cardID)
            }
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return try encoder.encode(self)
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
    case invalidProfessionalReviewCard
    case identityMismatch(expected: String, actual: String)
    case unsupportedCustomResourceFixture(String)
}
#endif
