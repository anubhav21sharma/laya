import Foundation

public enum StrokePhase: UInt8, Equatable, Sendable {
    case began
    case moved
    case ended
    case cancelled
}

public enum StrokeSource: UInt8, Equatable, Sendable {
    case mouse
    case tablet
    case pencil
}

public struct StrokeSample: Equatable, Sendable {
    public let position: ScreenPoint
    public let pressure: Float
    public let timestamp: TimeInterval
    public let phase: StrokePhase
    public let source: StrokeSource

    public init(
        position: ScreenPoint,
        pressure: Float,
        timestamp: TimeInterval,
        phase: StrokePhase,
        source: StrokeSource
    ) {
        self.position = position
        self.pressure = pressure
        self.timestamp = timestamp
        self.phase = phase
        self.source = source
    }

    public static func mouse(
        position: ScreenPoint,
        timestamp: TimeInterval,
        phase: StrokePhase
    ) -> StrokeSample {
        StrokeSample(
            position: position,
            pressure: 0.5,
            timestamp: timestamp,
            phase: phase,
            source: .mouse
        )
    }
}
