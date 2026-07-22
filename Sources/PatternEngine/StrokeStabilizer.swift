/// Deterministic, fixed-cost exponential stabilization for one stroke stream.
///
/// The value retains one filtered position. Callers evaluate predicted input
/// from a copied value so the authoritative carry remains untouched.
public struct StrokeStabilizer: Equatable, Sendable {
    public let strength: Float

    private var filteredPosition: WorldPoint?

    public init(strength: Float) {
        precondition(
            strength.isFinite && strength >= 0 && strength < 1,
            "Stabilization strength must be finite and in 0..<1"
        )
        self.strength = strength
        filteredPosition = nil
    }

    public mutating func process(
        _ sample: WorldStrokeSample
    ) -> WorldStrokeSample {
        if sample.phase == .cancelled {
            reset()
            return sample
        }

        if sample.phase == .began {
            reset()
            filteredPosition = sample.position
            return sample
        }

        // Preserve the compatibility path bit-for-bit, including signed zero.
        guard strength > 0 else {
            if sample.phase == .ended {
                reset()
            } else {
                filteredPosition = sample.position
            }
            return sample
        }

        guard let previous = filteredPosition else {
            if sample.phase != .ended {
                filteredPosition = sample.position
            }
            return sample
        }

        let response = 1 - strength
        let position = WorldPoint(
            x: previous.x + (sample.position.x - previous.x) * response,
            y: previous.y + (sample.position.y - previous.y) * response
        )
        let output = sample.replacingPosition(position)

        if sample.phase == .ended {
            reset()
        } else {
            filteredPosition = position
        }
        return output
    }

    public mutating func reset() {
        filteredPosition = nil
    }
}

private extension WorldStrokeSample {
    func replacingPosition(_ position: WorldPoint) -> WorldStrokeSample {
        let copiedSample = StrokeSample(
            position: ScreenPoint(x: position.x, y: position.y),
            pressure: pressure,
            timestamp: timestamp,
            phase: phase,
            source: source,
            kind: kind,
            capabilities: capabilities,
            altitude: altitude,
            azimuth: azimuth,
            roll: roll
        )
        return WorldStrokeSample(
            sample: copiedSample,
            position: position,
            velocity: velocity
        )
    }
}
