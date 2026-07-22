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

public enum StrokeSampleKind: UInt8, Equatable, Sendable {
    case actual
    case coalesced
    case predicted
    case estimatedUpdate
}

public struct StrokeInputCapabilities:
    OptionSet, Equatable, Hashable, Sendable
{
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let pressure = StrokeInputCapabilities(rawValue: 1 << 0)
    public static let altitude = StrokeInputCapabilities(rawValue: 1 << 1)
    public static let azimuth = StrokeInputCapabilities(rawValue: 1 << 2)
    public static let roll = StrokeInputCapabilities(rawValue: 1 << 3)
}

public struct StrokeSample: Equatable, Sendable {
    public let position: ScreenPoint
    public let pressure: Float
    public let timestamp: TimeInterval
    public let altitude: Float?
    public let azimuth: Float?
    public let roll: Float?
    public let phase: StrokePhase
    public let source: StrokeSource
    public let kind: StrokeSampleKind
    public let capabilities: StrokeInputCapabilities

    /// Constructs a sample from values already trusted by the caller.
    ///
    /// Platform input boundaries should use `validated` so malformed native
    /// values can be dropped instead of triggering this initializer's
    /// precondition.
    public init(
        position: ScreenPoint,
        pressure: Float,
        timestamp: TimeInterval,
        phase: StrokePhase,
        source: StrokeSource,
        kind: StrokeSampleKind = .actual,
        capabilities: StrokeInputCapabilities = [],
        altitude: Float? = nil,
        azimuth: Float? = nil,
        roll: Float? = nil
    ) {
        guard let sample = Self.validated(
            position: position,
            pressure: pressure,
            timestamp: timestamp,
            phase: phase,
            source: source,
            kind: kind,
            capabilities: capabilities,
            altitude: altitude,
            azimuth: azimuth,
            roll: roll
        ) else {
            preconditionFailure(
                "StrokeSample position, pressure, and timestamp must be finite"
            )
        }
        self = sample
    }

    /// Validates required values and normalizes sensor values at the platform
    /// boundary. Nonfinite optional sensor fields are discarded.
    public static func validated(
        position: ScreenPoint,
        pressure: Float,
        timestamp: TimeInterval,
        phase: StrokePhase,
        source: StrokeSource,
        kind: StrokeSampleKind = .actual,
        capabilities: StrokeInputCapabilities = [],
        altitude: Float? = nil,
        azimuth: Float? = nil,
        roll: Float? = nil
    ) -> StrokeSample? {
        validationResult(
            position: position,
            pressure: pressure,
            timestamp: timestamp,
            phase: phase,
            source: source,
            kind: kind,
            capabilities: capabilities,
            altitude: altitude,
            azimuth: azimuth,
            roll: roll
        )?.sample
    }

    /// Returns the normalized sample plus at most one nonfatal development
    /// diagnostic for discarded optional sensor values.
    public static func validationResult(
        position: ScreenPoint,
        pressure: Float,
        timestamp: TimeInterval,
        phase: StrokePhase,
        source: StrokeSource,
        kind: StrokeSampleKind = .actual,
        capabilities: StrokeInputCapabilities = [],
        altitude: Float? = nil,
        azimuth: Float? = nil,
        roll: Float? = nil
    ) -> StrokeSampleValidationResult? {
        guard
            position.x.isFinite,
            position.y.isFinite,
            pressure.isFinite,
            timestamp.isFinite
        else {
            return nil
        }

        let sample = StrokeSample(
            validatedPosition: position,
            pressure: min(1, max(0, pressure)),
            timestamp: timestamp,
            phase: phase,
            source: source,
            kind: kind,
            capabilities: capabilities,
            altitude: normalizedAltitude(altitude),
            azimuth: normalizedSignedAngle(azimuth),
            roll: normalizedSignedAngle(roll)
        )
        let discardedOptionalSensor = isNonfinite(altitude)
            || isNonfinite(azimuth)
            || isNonfinite(roll)
        return StrokeSampleValidationResult(
            sample: sample,
            developmentDiagnostic: discardedOptionalSensor
                ? .discardedNonfiniteOptionalSensor
                : nil
        )
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

    public static func validatedMouse(
        position: ScreenPoint,
        timestamp: TimeInterval,
        phase: StrokePhase
    ) -> StrokeSample? {
        validated(
            position: position,
            pressure: 0.5,
            timestamp: timestamp,
            phase: phase,
            source: .mouse
        )
    }

    private init(
        validatedPosition position: ScreenPoint,
        pressure: Float,
        timestamp: TimeInterval,
        phase: StrokePhase,
        source: StrokeSource,
        kind: StrokeSampleKind,
        capabilities: StrokeInputCapabilities,
        altitude: Float?,
        azimuth: Float?,
        roll: Float?
    ) {
        self.position = position
        self.pressure = pressure
        self.timestamp = timestamp
        self.altitude = altitude
        self.azimuth = azimuth
        self.roll = roll
        self.phase = phase
        self.source = source
        self.kind = kind
        self.capabilities = capabilities
    }

    private static func normalizedAltitude(_ value: Float?) -> Float? {
        guard let value, value.isFinite else {
            return nil
        }
        return min(.pi / 2, max(0, value))
    }

    private static func isNonfinite(_ value: Float?) -> Bool {
        guard let value else { return false }
        return !value.isFinite
    }

    private static func normalizedSignedAngle(_ value: Float?) -> Float? {
        guard let value, value.isFinite else {
            return nil
        }
        let fullTurn = 2 * Float.pi
        var normalized = value.truncatingRemainder(dividingBy: fullTurn)
        if normalized > .pi {
            normalized -= fullTurn
        } else if normalized < -.pi {
            normalized += fullTurn
        }
        return normalized
    }
}

public enum StrokeSampleDevelopmentDiagnostic:
    UInt8, Equatable, Sendable
{
    case discardedNonfiniteOptionalSensor
}

public struct StrokeSampleValidationResult: Equatable, Sendable {
    public let sample: StrokeSample
    public let developmentDiagnostic: StrokeSampleDevelopmentDiagnostic?
}
