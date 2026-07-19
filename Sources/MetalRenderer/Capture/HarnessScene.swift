import Foundation

public struct HarnessPixelCheck: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let expectedBGRA: [UInt8]
    public let tolerance: UInt8
}

public struct HarnessScene: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let name: String
    public let width: Int
    public let height: Int
    public let checks: [HarnessPixelCheck]

    public static func decode(_ data: Data) throws -> HarnessScene {
        let scene = try JSONDecoder().decode(HarnessScene.self, from: data)
        try scene.validate()
        return scene
    }

    private func validate() throws {
        guard schemaVersion == 1 else {
            throw HarnessSceneError.unsupportedSchema(schemaVersion)
        }
        guard !name.isEmpty else {
            throw HarnessSceneError.emptyName
        }
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw HarnessSceneError.invalidDimensions(width: width, height: height)
        }
        guard !checks.isEmpty else {
            throw HarnessSceneError.missingPixelChecks
        }

        for check in checks {
            guard (0..<width).contains(check.x), (0..<height).contains(check.y) else {
                throw HarnessSceneError.invalidCheckCoordinate(x: check.x, y: check.y)
            }
            guard check.expectedBGRA.count == 4 else {
                throw HarnessSceneError.invalidExpectedPixelCount(
                    check.expectedBGRA.count
                )
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
        }
    }
}
