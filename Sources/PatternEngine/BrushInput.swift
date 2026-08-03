import Foundation

public enum BrushInputContract {
    /// Upper bound for canonical world-space speed, in pixels per second.
    public static let maximumWorldVelocity: Float = 100_000
}

public struct WorldStrokeSample: Equatable, Sendable {
    public let position: WorldPoint
    public let pressure: Float
    public let timestamp: TimeInterval
    public let altitude: Float?
    public let azimuth: Float?
    public let roll: Float?
    public let tangentialPressure: Float?
    public let deviceIdentifier: UInt64?
    public let estimationUpdateIndex: Int?
    public let estimatedProperties: StrokeEstimatedProperties
    public let estimatedPropertiesExpectingUpdates: StrokeEstimatedProperties
    public let velocity: Float
    public let artisticVelocity: Float
    public let phase: StrokePhase
    public let source: StrokeSource
    public let kind: StrokeSampleKind
    public let capabilities: StrokeInputCapabilities

    init(
        sample: StrokeSample,
        position: WorldPoint,
        velocity: Float,
        artisticVelocity: Float
    ) {
        self.position = position
        pressure = sample.pressure
        timestamp = sample.timestamp
        altitude = sample.altitude
        azimuth = sample.azimuth
        roll = sample.roll
        tangentialPressure = sample.tangentialPressure
        deviceIdentifier = sample.deviceIdentifier
        estimationUpdateIndex = sample.estimationUpdateIndex
        estimatedProperties = sample.estimatedProperties
        estimatedPropertiesExpectingUpdates =
            sample.estimatedPropertiesExpectingUpdates
        self.velocity = velocity
        self.artisticVelocity = artisticVelocity
        phase = sample.phase
        source = sample.source
        kind = sample.kind
        capabilities = sample.capabilities
    }

    init(
        position: WorldPoint,
        pressure: Float,
        timestamp: TimeInterval,
        altitude: Float?,
        azimuth: Float?,
        roll: Float?,
        tangentialPressure: Float?,
        deviceIdentifier: UInt64?,
        estimationUpdateIndex: Int?,
        estimatedProperties: StrokeEstimatedProperties,
        estimatedPropertiesExpectingUpdates: StrokeEstimatedProperties,
        velocity: Float,
        artisticVelocity: Float,
        phase: StrokePhase,
        source: StrokeSource,
        kind: StrokeSampleKind,
        capabilities: StrokeInputCapabilities
    ) {
        self.position = position
        self.pressure = pressure
        self.timestamp = timestamp
        self.altitude = altitude
        self.azimuth = azimuth
        self.roll = roll
        self.tangentialPressure = tangentialPressure
        self.deviceIdentifier = deviceIdentifier
        self.estimationUpdateIndex = estimationUpdateIndex
        self.estimatedProperties = estimatedProperties
        self.estimatedPropertiesExpectingUpdates =
            estimatedPropertiesExpectingUpdates
        self.velocity = velocity
        self.artisticVelocity = artisticVelocity
        self.phase = phase
        self.source = source
        self.kind = kind
        self.capabilities = capabilities
    }

    func replacing(
        position: WorldPoint? = nil,
        pressure: Float? = nil,
        altitude: Float?? = nil,
        azimuth: Float?? = nil,
        roll: Float?? = nil,
        estimatedProperties: StrokeEstimatedProperties? = nil,
        estimatedPropertiesExpectingUpdates: StrokeEstimatedProperties? = nil,
        velocity: Float? = nil,
        artisticVelocity: Float? = nil
    ) -> WorldStrokeSample {
        WorldStrokeSample(
            position: position ?? self.position,
            pressure: pressure ?? self.pressure,
            timestamp: timestamp,
            altitude: altitude ?? self.altitude,
            azimuth: azimuth ?? self.azimuth,
            roll: roll ?? self.roll,
            tangentialPressure: tangentialPressure,
            deviceIdentifier: deviceIdentifier,
            estimationUpdateIndex: estimationUpdateIndex,
            estimatedProperties:
                estimatedProperties ?? self.estimatedProperties,
            estimatedPropertiesExpectingUpdates:
                estimatedPropertiesExpectingUpdates
                    ?? self.estimatedPropertiesExpectingUpdates,
            velocity: velocity ?? self.velocity,
            artisticVelocity: artisticVelocity ?? self.artisticVelocity,
            phase: phase,
            source: source,
            kind: kind,
            capabilities: capabilities
        )
    }
}

/// Pure stateful screen-to-world input derivation for one stroke stream.
///
/// One instance tracks one authoritative stroke at a time. Predicted samples
/// are evaluated against, but never advance, that authoritative state.
public struct BrushInputDeriver: Equatable, Sendable {
    private var previousPosition: WorldPoint?
    private var previousTimestamp: TimeInterval?
    private var lastVelocity: Float
    private var artisticVelocityFilter: StrokeVelocityFilter

    public init() {
        previousPosition = nil
        previousTimestamp = nil
        lastVelocity = 0
        artisticVelocityFilter = StrokeVelocityFilter()
    }

    public mutating func derive(
        _ sample: StrokeSample,
        viewport: ViewportTransform
    ) -> WorldStrokeSample {
        let position = viewport.screenToWorld(sample.position)
        precondition(
            position.x.isFinite && position.y.isFinite,
            "Viewport conversion must produce a finite world position"
        )

        if sample.phase == .cancelled {
            if sample.kind != .predicted {
                reset()
            }
            return WorldStrokeSample(
                sample: sample,
                position: position,
                velocity: 0,
                artisticVelocity: 0
            )
        }

        if sample.kind == .estimatedUpdate {
            return WorldStrokeSample(
                sample: sample,
                position: position,
                velocity: derivedVelocity(
                    to: position,
                    timestamp: sample.timestamp
                ),
                artisticVelocity: evaluatedArtisticVelocity(
                    to: position,
                    timestamp: sample.timestamp
                ).velocity
            )
        }

        if sample.phase == .began {
            if sample.kind != .predicted {
                reset()
                previousPosition = position
                previousTimestamp = sample.timestamp
                _ = artisticVelocityFilter.begin(
                    at: position,
                    time: sample.timestamp
                )
            }
            return WorldStrokeSample(
                sample: sample,
                position: position,
                velocity: 0,
                artisticVelocity: 0
            )
        }

        let velocity = derivedVelocity(
            to: position,
            timestamp: sample.timestamp
        )
        let artistic = evaluatedArtisticVelocity(
            to: position,
            timestamp: sample.timestamp
        )
        let result = WorldStrokeSample(
            sample: sample,
            position: position,
            velocity: velocity,
            artisticVelocity: artistic.velocity
        )

        guard sample.kind != .predicted else {
            return result
        }

        if sample.phase == .ended {
            reset()
        } else {
            previousPosition = position
            previousTimestamp = sample.timestamp
            lastVelocity = velocity
            artisticVelocityFilter = artistic.filter
        }
        return result
    }

    /// Advances a copied derivation cursor through a predicted suffix without
    /// touching the authoritative cursor owned by the active stroke.
    public mutating func deriveAdvancingPrediction(
        _ sample: StrokeSample,
        viewport: ViewportTransform
    ) -> WorldStrokeSample {
        precondition(sample.kind == .predicted)
        let result = derive(sample, viewport: viewport)
        if sample.phase == .ended || sample.phase == .cancelled {
            reset()
        } else {
            previousPosition = result.position
            previousTimestamp = result.timestamp
            lastVelocity = result.velocity
            _ = artisticVelocityFilter.update(
                to: result.position,
                time: result.timestamp
            )
        }
        return result
    }

    /// Recomputes velocity for a retained world-space sample during estimated
    /// property replay. This advances an exact copied checkpoint and does not
    /// require the original viewport.
    public mutating func rederive(
        _ sample: WorldStrokeSample
    ) -> WorldStrokeSample {
        if sample.phase == .cancelled {
            if sample.kind != .predicted {
                reset()
            }
            return sample.replacing(velocity: 0, artisticVelocity: 0)
        }
        if sample.phase == .began {
            reset()
            previousPosition = sample.position
            previousTimestamp = sample.timestamp
            _ = artisticVelocityFilter.begin(
                at: sample.position,
                time: sample.timestamp
            )
            return sample.replacing(velocity: 0, artisticVelocity: 0)
        }

        let velocity = derivedVelocity(
            to: sample.position,
            timestamp: sample.timestamp
        )
        let artistic = evaluatedArtisticVelocity(
            to: sample.position,
            timestamp: sample.timestamp
        )
        let result = sample.replacing(
            velocity: velocity,
            artisticVelocity: artistic.velocity
        )
        if sample.phase == .ended {
            reset()
        } else {
            previousPosition = sample.position
            previousTimestamp = sample.timestamp
            lastVelocity = velocity
            artisticVelocityFilter = artistic.filter
        }
        return result
    }

    public mutating func reset() {
        previousPosition = nil
        previousTimestamp = nil
        lastVelocity = 0
        artisticVelocityFilter.reset()
    }

    private func derivedVelocity(
        to position: WorldPoint,
        timestamp: TimeInterval
    ) -> Float {
        guard
            let previousPosition,
            let previousTimestamp
        else {
            return 0
        }

        let deltaTime = timestamp - previousTimestamp
        guard deltaTime > 0, deltaTime.isFinite else {
            return lastVelocity
        }

        let deltaX = Double(position.x) - Double(previousPosition.x)
        let deltaY = Double(position.y) - Double(previousPosition.y)
        let velocity = hypot(deltaX, deltaY) / deltaTime
        guard velocity.isFinite else {
            return BrushInputContract.maximumWorldVelocity
        }
        return min(
            BrushInputContract.maximumWorldVelocity,
            Float(velocity)
        )
    }

    private func evaluatedArtisticVelocity(
        to position: WorldPoint,
        timestamp: TimeInterval
    ) -> (velocity: Float, filter: StrokeVelocityFilter) {
        var candidate = artisticVelocityFilter
        let velocity = candidate.update(to: position, time: timestamp)
        return (velocity, candidate)
    }
}
