import Foundation

public enum SliceThreeHarnessRunError: Error, Equatable, LocalizedError {
    case structuralMismatch(
        sceneName: String,
        metric: HarnessStructuralMetric,
        expectedRelation: HarnessRelation,
        expectedValue: Int,
        actualValue: Int
    )
    case invariant(sceneName: String, message: String)
    case missingCompletion(sceneName: String, token: RendererOperationToken)
    case unexpectedCompletion(sceneName: String, token: RendererOperationToken)
    case missingArtifact(sceneName: String, channel: HarnessPixelChannel)
    case pixelMismatch(
        sceneName: String,
        channel: HarnessPixelChannel,
        x: Int,
        y: Int,
        expected: [UInt8],
        actual: [UInt8],
        tolerance: UInt8
    )

    public var errorDescription: String? {
        switch self {
        case let .structuralMismatch(
            sceneName,
            metric,
            relation,
            expected,
            actual
        ):
            "Slice 3 scene '\(sceneName)' metric \(metric.rawValue): expected \(relation.rawValue) \(expected), actual \(actual)."
        case let .invariant(sceneName, message):
            "Slice 3 scene '\(sceneName)' invariant failed: \(message)."
        case let .missingCompletion(sceneName, token):
            "Slice 3 scene '\(sceneName)' did not receive completion token \(token.rawValue)."
        case let .unexpectedCompletion(sceneName, token):
            "Slice 3 scene '\(sceneName)' received the wrong completion for token \(token.rawValue)."
        case let .missingArtifact(sceneName, channel):
            "Slice 3 scene '\(sceneName)' is missing artifact channel \(channel.rawValue)."
        case let .pixelMismatch(
            sceneName,
            channel,
            x,
            y,
            expected,
            actual,
            tolerance
        ):
            "Slice 3 scene '\(sceneName)' channel \(channel.rawValue) pixel mismatch at (\(x), \(y)): expected \(expected), actual \(actual), tolerance \(tolerance)."
        }
    }
}
