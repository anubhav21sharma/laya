import Foundation

public enum HarnessPixelChannel: String, Codable, Equatable, Sendable {
    case screen
    case liveScreen
    case committedScreen
    case canonical
}

public enum GridHarnessProgram: String, Codable, Equatable, Sendable {
    case gridInterior
    case gridBoundary
    case previewCommit
    case cancelPreservesCanonical
    case fiveHundredDabs
    case longStroke
}

public enum HarnessStructuralMetric: String, Codable, Equatable, Sendable {
    case emittedDabCount
    case encodedInstanceCount
    case restampedInstanceCount
    case canonicalRevisionDelta
    case previewCommitMaximumDelta
    case canonicalByteDelta
    case missedFrameCount
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
    public let program: GridHarnessProgram?
    public let structuralChecks: [HarnessStructuralCheck]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case name
        case width
        case height
        case checks
        case program
        case structuralChecks
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
            GridHarnessProgram.self,
            forKey: .program
        )
        structuralChecks = try values.decodeIfPresent(
            [HarnessStructuralCheck].self,
            forKey: .structuralChecks
        ) ?? []
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
        if schemaVersion == 2, checks.isEmpty, structuralChecks.isEmpty {
            throw HarnessSceneError.missingAssertions
        }

        for check in checks {
            let artifactWidth = check.channel == .canonical
                ? Int(GridCanvasContract.tileSize)
                : width
            let artifactHeight = check.channel == .canonical
                ? Int(GridCanvasContract.tileSize)
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
        }
    }
}
