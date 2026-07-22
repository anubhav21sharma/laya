#if os(macOS)
import AppKit
import PatternEngine

/// Converts AppKit pointer events into the platform-neutral BrushInput V2
/// contract. Native event details stop at this boundary.
@MainActor
struct BrushInputAdapter {
    struct NativeSample: Equatable {
        let position: ScreenPoint
        let pressure: Float
        let timestamp: TimeInterval
        let tilt: SIMD2<Float>?
        let rotationDegrees: Float?
        let phase: StrokePhase
        let kind: StrokeSampleKind
        let isTablet: Bool

        init(
            position: ScreenPoint,
            pressure: Float,
            timestamp: TimeInterval,
            tilt: SIMD2<Float>? = nil,
            rotationDegrees: Float? = nil,
            phase: StrokePhase,
            kind: StrokeSampleKind = .actual,
            isTablet: Bool
        ) {
            self.position = position
            self.pressure = pressure
            self.timestamp = timestamp
            self.tilt = tilt
            self.rotationDegrees = rotationDegrees
            self.phase = phase
            self.kind = kind
            self.isTablet = isTablet
        }
    }

    func orderedSamples(
        for event: NSEvent,
        phase: StrokePhase,
        position: ScreenPoint
    ) -> [StrokeSample] {
        orderedSamples([
            nativeSample(for: event, phase: phase, position: position),
        ])
    }

    /// Produces a stable chronological batch. Equal timestamps retain native
    /// delivery order, which is significant for lifecycle samples.
    func orderedSamples(
        _ nativeSamples: [NativeSample]
    ) -> [StrokeSample] {
        nativeSamples.enumerated()
            .compactMap { offset, native -> (Int, StrokeSample)? in
                guard let sample = normalizedSample(native) else { return nil }
                return (offset, sample)
            }
            .sorted { lhs, rhs in
                if lhs.1.timestamp == rhs.1.timestamp {
                    return lhs.0 < rhs.0
                }
                return lhs.1.timestamp < rhs.1.timestamp
            }
            .map(\.1)
    }

    private func nativeSample(
        for event: NSEvent,
        phase: StrokePhase,
        position: ScreenPoint
    ) -> NativeSample {
        let isTablet = event.type == .tabletPoint
            || event.subtype == .tabletPoint
        guard isTablet else {
            return NativeSample(
                position: position,
                pressure: 0.5,
                timestamp: event.timestamp,
                phase: phase,
                isTablet: false
            )
        }

        return NativeSample(
            position: position,
            pressure: event.pressure,
            timestamp: event.timestamp,
            tilt: SIMD2(Float(event.tilt.x), Float(event.tilt.y)),
            rotationDegrees: event.rotation,
            phase: phase,
            isTablet: true
        )
    }

    private func normalizedSample(
        _ native: NativeSample
    ) -> StrokeSample? {
        guard native.isTablet else {
            return StrokeSample.validated(
                position: native.position,
                pressure: 0.5,
                timestamp: native.timestamp,
                phase: native.phase,
                source: .mouse,
                kind: native.kind
            )
        }

        let orientation = tabletOrientation(
            tilt: native.tilt,
            rotationDegrees: native.rotationDegrees
        )
        return StrokeSample.validated(
            position: native.position,
            pressure: native.pressure,
            timestamp: native.timestamp,
            phase: native.phase,
            source: .tablet,
            kind: native.kind,
            capabilities: orientation.capabilities.union(.pressure),
            altitude: orientation.altitude,
            azimuth: orientation.azimuth,
            roll: orientation.roll
        )
    }

    private func tabletOrientation(
        tilt: SIMD2<Float>?,
        rotationDegrees: Float?
    ) -> (
        altitude: Float?,
        azimuth: Float?,
        roll: Float?,
        capabilities: StrokeInputCapabilities
    ) {
        var capabilities: StrokeInputCapabilities = []
        var altitude: Float?
        var azimuth: Float?
        var roll: Float?

        if let tilt, tilt.x.isFinite, tilt.y.isFinite {
            let magnitude = min(1, hypot(tilt.x, tilt.y))
            altitude = acos(magnitude)
            azimuth = atan2(tilt.y, tilt.x)
            capabilities.formUnion([.altitude, .azimuth])
        }

        if let rotationDegrees, rotationDegrees.isFinite {
            roll = rotationDegrees * .pi / 180
            capabilities.insert(.roll)
        }

        return (altitude, azimuth, roll, capabilities)
    }
}
#endif
