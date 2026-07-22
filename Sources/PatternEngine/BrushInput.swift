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
    public let velocity: Float
    public let phase: StrokePhase
    public let source: StrokeSource
    public let kind: StrokeSampleKind
    public let capabilities: StrokeInputCapabilities

    init(
        sample: StrokeSample,
        position: WorldPoint,
        velocity: Float
    ) {
        self.position = position
        pressure = sample.pressure
        timestamp = sample.timestamp
        altitude = sample.altitude
        azimuth = sample.azimuth
        roll = sample.roll
        self.velocity = velocity
        phase = sample.phase
        source = sample.source
        kind = sample.kind
        capabilities = sample.capabilities
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

    public init() {
        previousPosition = nil
        previousTimestamp = nil
        lastVelocity = 0
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
                velocity: 0
            )
        }

        if sample.phase == .began {
            if sample.kind != .predicted {
                reset()
                previousPosition = position
                previousTimestamp = sample.timestamp
            }
            return WorldStrokeSample(
                sample: sample,
                position: position,
                velocity: 0
            )
        }

        let velocity = derivedVelocity(
            to: position,
            timestamp: sample.timestamp
        )
        let result = WorldStrokeSample(
            sample: sample,
            position: position,
            velocity: velocity
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
        }
        return result
    }

    public mutating func reset() {
        previousPosition = nil
        previousTimestamp = nil
        lastVelocity = 0
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
}
