import Foundation
import PatternEngine

public enum HarnessPixelChannel: String, Codable, Equatable, Sendable {
    case screen
    case liveScreen
    case committedScreen
    case canonical
    case oracleCoverage
    case oracleCanonicalCoordinates
    case oracleBrushLocalCoordinates
}

public enum HarnessDiagnosticMode: String, Codable, Equatable, Sendable {
    case hardRound
    case asymmetricCoverage
    case canonicalCoordinates
    case brushLocalCoordinates
}

public enum TilingHarnessProgram: String, Codable, Equatable, Sendable {
    case gridInterior
    case gridBoundary
    case previewCommit
    case cancelPreservesCanonical
    case fiveHundredDabs
    case longStroke
    case generalizedGrid
    case halfDropInterior
    case halfDropEdge
    case halfDropCorner
    case brickTranspose
    case mirrorX
    case mirrorY
    case mirrorXY
    case rotationalGenerator
    case rotationalFixedPoint
    case rotationalOrientation
    case largeFootprint
    case asymmetricFootprint
    case canonicalCoordinateContinuity
    case brushLocalCoordinateContinuity
    case rectangularTile
    case noncentralVisibleCell
    case metadataTilingSwitch
    case projectedLiveCommit
    case projectedLongStroke

    var requiredTiling: TilingKind? {
        switch self {
        case .gridInterior, .gridBoundary, .previewCommit,
             .cancelPreservesCanonical, .fiveHundredDabs, .longStroke:
            nil
        case .generalizedGrid, .largeFootprint, .rectangularTile,
             .metadataTilingSwitch:
            .grid
        case .halfDropInterior, .halfDropEdge, .halfDropCorner,
             .canonicalCoordinateContinuity, .projectedLiveCommit,
             .projectedLongStroke:
            .halfDrop
        case .brickTranspose:
            .brick
        case .mirrorX:
            .mirrorX
        case .mirrorY:
            .mirrorY
        case .mirrorXY, .brushLocalCoordinateContinuity:
            .mirrorXY
        case .rotationalGenerator, .rotationalFixedPoint,
             .rotationalOrientation, .asymmetricFootprint:
            .rotational
        case .noncentralVisibleCell:
            nil
        }
    }

    var requiresInteractiveHardRound: Bool {
        switch self {
        case .noncentralVisibleCell, .metadataTilingSwitch,
             .projectedLiveCommit, .projectedLongStroke:
            true
        default:
            false
        }
    }
}

public typealias GridHarnessProgram = TilingHarnessProgram

public enum HarnessStructuralMetric: String, Codable, Equatable, Sendable {
    case emittedDabCount
    case encodedInstanceCount
    case restampedInstanceCount
    case canonicalRevisionDelta
    case previewCommitMaximumDelta
    case canonicalByteDelta
    case missedFrameCount
    case oracleHoleCount
    case oraclePhantomCount
    case oracleMaximumDelta
    case restoredDisplayMaximumDelta
    case transformMismatchCount
    case duplicateFixedPointWriteCount
    case coordinateContinuityMismatchCount
    case visibleCellCanonicalByteDelta
    case previewCommitViolationCount
}

public enum HarnessRelation: String, Codable, Equatable, Sendable {
    case equal
    case lessThanOrEqual
}

public struct HarnessStructuralCheck: Codable, Equatable, Sendable {
    public let metric: HarnessStructuralMetric
    public let relation: HarnessRelation
    public let value: Int
}

public struct HarnessPixelCheck: Codable, Equatable, Sendable {
    public let channel: HarnessPixelChannel
    public let x: Int
    public let y: Int
    public let expectedBGRA: [UInt8]
    public let tolerance: UInt8

    private enum CodingKeys: String, CodingKey {
        case channel
        case x
        case y
        case expectedBGRA
        case tolerance
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        channel = try values.decodeIfPresent(
            HarnessPixelChannel.self,
            forKey: .channel
        ) ?? .screen
        x = try values.decode(Int.self, forKey: .x)
        y = try values.decode(Int.self, forKey: .y)
        expectedBGRA = try values.decode(
            [UInt8].self,
            forKey: .expectedBGRA
        )
        tolerance = try values.decode(UInt8.self, forKey: .tolerance)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if channel != .screen {
            try values.encode(channel, forKey: .channel)
        }
        try values.encode(x, forKey: .x)
        try values.encode(y, forKey: .y)
        try values.encode(expectedBGRA, forKey: .expectedBGRA)
        try values.encode(tolerance, forKey: .tolerance)
    }
}

public struct HarnessScene: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let name: String
    public let width: Int
    public let height: Int
    public let checks: [HarnessPixelCheck]
    public let program: TilingHarnessProgram?
    public let structuralChecks: [HarnessStructuralCheck]
    public let tileWidth: Int?
    public let tileHeight: Int?
    public let tiling: TilingKind?
    public let diagnosticMode: HarnessDiagnosticMode?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case name
        case width
        case height
        case checks
        case program
        case structuralChecks
        case tileWidth
        case tileHeight
        case tiling
        case diagnosticMode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        name = try values.decode(String.self, forKey: .name)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        checks = try values.decodeIfPresent(
            [HarnessPixelCheck].self,
            forKey: .checks
        ) ?? []
        program = try values.decodeIfPresent(
            TilingHarnessProgram.self,
            forKey: .program
        )
        structuralChecks = try values.decodeIfPresent(
            [HarnessStructuralCheck].self,
            forKey: .structuralChecks
        ) ?? []
        if schemaVersion == 3 {
            tileWidth = try Self.decodeRequiredSchemaThreeValue(
                Int.self,
                key: .tileWidth,
                field: "tileWidth",
                from: values
            )
            tileHeight = try Self.decodeRequiredSchemaThreeValue(
                Int.self,
                key: .tileHeight,
                field: "tileHeight",
                from: values
            )
            tiling = try Self.decodeRequiredSchemaThreeValue(
                TilingKind.self,
                key: .tiling,
                field: "tiling",
                from: values
            )
            diagnosticMode = try Self.decodeRequiredSchemaThreeValue(
                HarnessDiagnosticMode.self,
                key: .diagnosticMode,
                field: "diagnosticMode",
                from: values
            )
        } else {
            tileWidth = nil
            tileHeight = nil
            tiling = nil
            diagnosticMode = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(name, forKey: .name)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
        try values.encode(checks, forKey: .checks)
        try values.encodeIfPresent(program, forKey: .program)
        if !structuralChecks.isEmpty {
            try values.encode(structuralChecks, forKey: .structuralChecks)
        }
        if schemaVersion == 3 {
            try values.encode(tileWidth, forKey: .tileWidth)
            try values.encode(tileHeight, forKey: .tileHeight)
            try values.encode(tiling, forKey: .tiling)
            try values.encode(diagnosticMode, forKey: .diagnosticMode)
        }
    }

    public static func decode(_ data: Data) throws -> HarnessScene {
        let scene = try JSONDecoder().decode(HarnessScene.self, from: data)
        try scene.validate()
        return scene
    }

    private func validate() throws {
        switch schemaVersion {
        case 1:
            guard program == nil else {
                throw HarnessSceneError.programForbiddenForSchemaOne
            }
        case 2:
            guard program != nil else {
                throw HarnessSceneError.missingProgram
            }
        case 3:
            guard let program else {
                throw HarnessSceneError.missingProgram
            }
            guard let tileWidth, let tileHeight else {
                preconditionFailure(
                    "Schema 3 required tile fields must be decoded before validation"
                )
            }
            guard (64...4_096).contains(tileWidth),
                  (64...4_096).contains(tileHeight)
            else {
                throw HarnessSceneError.invalidTileDimensions(
                    width: tileWidth,
                    height: tileHeight
                )
            }
            guard let tiling, let diagnosticMode else {
                preconditionFailure(
                    "Schema 3 required tiling fields must be decoded before validation"
                )
            }
            if let requiredTiling = program.requiredTiling,
               requiredTiling != tiling
            {
                throw HarnessSceneError.programTilingMismatch(
                    program: program,
                    tiling: tiling
                )
            }
            if program.requiresInteractiveHardRound,
               diagnosticMode != .hardRound
            {
                throw HarnessSceneError.interactiveDiagnosticRequiresHardRound(
                    program: program,
                    diagnosticMode: diagnosticMode
                )
            }
        default:
            throw HarnessSceneError.unsupportedSchema(schemaVersion)
        }
        guard !name.isEmpty else {
            throw HarnessSceneError.emptyName
        }
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw HarnessSceneError.invalidDimensions(width: width, height: height)
        }
        if schemaVersion == 1, checks.isEmpty {
            throw HarnessSceneError.missingPixelChecks
        }
        if schemaVersion >= 2, checks.isEmpty, structuralChecks.isEmpty {
            throw HarnessSceneError.missingAssertions
        }

        for check in checks {
            let usesTileDimensions: Bool
            switch check.channel {
            case .canonical, .oracleCoverage,
                 .oracleCanonicalCoordinates,
                 .oracleBrushLocalCoordinates:
                usesTileDimensions = true
            case .screen, .liveScreen, .committedScreen:
                usesTileDimensions = false
            }
            let artifactWidth = usesTileDimensions
                ? (tileWidth ?? Int(GridCanvasContract.tileSize))
                : width
            let artifactHeight = usesTileDimensions
                ? (tileHeight ?? Int(GridCanvasContract.tileSize))
                : height
            guard
                (0..<artifactWidth).contains(check.x),
                (0..<artifactHeight).contains(check.y)
            else {
                throw HarnessSceneError.invalidCheckCoordinate(x: check.x, y: check.y)
            }
            guard check.expectedBGRA.count == 4 else {
                throw HarnessSceneError.invalidExpectedPixelCount(
                    check.expectedBGRA.count
                )
            }
        }
        for check in structuralChecks {
            guard check.value >= 0 else {
                throw HarnessSceneError.invalidStructuralValue(check.value)
            }
        }
    }

    private static func decodeRequiredSchemaThreeValue<Value: Decodable>(
        _ type: Value.Type,
        key: CodingKeys,
        field: String,
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> Value {
        guard values.contains(key),
              try !values.decodeNil(forKey: key)
        else {
            throw HarnessSceneError.missingSchemaThreeField(field)
        }
        return try values.decode(Value.self, forKey: key)
    }
}

public enum HarnessSceneError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case emptyName
    case invalidDimensions(width: Int, height: Int)
    case missingPixelChecks
    case invalidCheckCoordinate(x: Int, y: Int)
    case invalidExpectedPixelCount(Int)
    case missingProgram
    case programForbiddenForSchemaOne
    case missingAssertions
    case invalidStructuralValue(Int)
    case missingSchemaThreeField(String)
    case invalidTileDimensions(width: Int, height: Int)
    case programTilingMismatch(
        program: TilingHarnessProgram,
        tiling: TilingKind
    )
    case interactiveDiagnosticRequiresHardRound(
        program: TilingHarnessProgram,
        diagnosticMode: HarnessDiagnosticMode
    )

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported harness scene schema \(version)."
        case .emptyName:
            "Harness scene name is empty."
        case let .invalidDimensions(width, height):
            "Harness dimensions \(width)x\(height) are outside 1...4096."
        case .missingPixelChecks:
            "Harness scene has no pixel checks."
        case let .invalidCheckCoordinate(x, y):
            "Harness check coordinate (\(x), \(y)) is outside the scene."
        case let .invalidExpectedPixelCount(count):
            "Expected BGRA pixel has \(count) components instead of 4."
        case .missingProgram:
            "Schema 2 harness scene requires a grid program."
        case .programForbiddenForSchemaOne:
            "Schema 1 harness scene cannot contain a grid program."
        case .missingAssertions:
            "Schema 2 harness scene has no pixel or structural assertions."
        case let .invalidStructuralValue(value):
            "Harness structural assertion value \(value) is negative."
        case let .missingSchemaThreeField(field):
            "Schema 3 harness scene requires '\(field)'."
        case let .invalidTileDimensions(width, height):
            "Harness tile dimensions \(width)x\(height) are outside 64...4096."
        case let .programTilingMismatch(program, tiling):
            "Harness program \(program.rawValue) requires a different tiling than \(tiling)."
        case let .interactiveDiagnosticRequiresHardRound(program, mode):
            "Interactive harness program \(program.rawValue) cannot use diagnostic mode \(mode.rawValue)."
        }
    }
}
