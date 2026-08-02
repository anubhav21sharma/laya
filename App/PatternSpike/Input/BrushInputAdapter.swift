import Foundation
import PatternEngine

enum BrushInputBatchPolicy {
    struct PredictionBatch<Element> {
        let submittedCount: Int
        let admitted: ArraySlice<Element>
    }

    static func predictionBatch<Element>(
        _ elements: [Element],
        maximumCount: Int
    ) -> PredictionBatch<Element> {
        precondition(maximumCount >= 0)
        return PredictionBatch(
            submittedCount: elements.count,
            admitted: elements.prefix(maximumCount)
        )
    }

    static func stableOrder<Elements: Collection>(
        _ elements: Elements,
        timestamp: (Elements.Element) -> TimeInterval
    ) -> [Elements.Element] {
        elements.enumerated()
            .sorted { lhs, rhs in
                let leftTimestamp = timestamp(lhs.element)
                let rightTimestamp = timestamp(rhs.element)
                if leftTimestamp == rightTimestamp {
                    return lhs.offset < rhs.offset
                }
                return leftTimestamp < rightTimestamp
            }
            .map(\.element)
    }

    static func phase(
        at index: Int,
        count: Int,
        terminalPhase: StrokePhase
    ) -> StrokePhase {
        if terminalPhase == .began {
            return index == 0 ? .began : .moved
        }
        return index == count - 1 ? terminalPhase : .moved
    }

    static func discoversRoll(
        previouslyDiscovered: Bool,
        rollIsEstimated: Bool,
        rollExpectsUpdate: Bool,
        nativeRoll: Float
    ) -> Bool {
        previouslyDiscovered
            || rollIsEstimated
            || rollExpectsUpdate
            || (nativeRoll.isFinite && nativeRoll != 0)
    }

    static func primaryInput<Element>(
        _ elements: [Element],
        isPencil: (Element) -> Bool
    ) -> Element? {
        let pencils = elements.filter(isPencil)
        if pencils.count == 1 {
            return pencils[0]
        }
        guard pencils.isEmpty, elements.count == 1 else {
            return nil
        }
        return elements[0]
    }
}

struct PendingEstimatedInputRegistry<Value> {
    private struct Entry {
        let value: Value
        let isPredicted: Bool
        let inputGeneration: UInt64?
    }

    private var entries: [Int: Entry] = [:]

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var indices: [Int] { entries.keys.sorted() }

    func contains(_ index: Int) -> Bool {
        entries[index] != nil
    }

    func value(for index: Int) -> Value? {
        entries[index]?.value
    }

    func inputGeneration(for index: Int) -> UInt64? {
        entries[index]?.inputGeneration
    }

    func containsIdentical(
        _ value: Value,
        for index: Int
    ) -> Bool where Value: AnyObject {
        entries[index]?.value === value
    }

    mutating func record(
        _ value: Value,
        index: Int?,
        expecting: StrokeEstimatedProperties,
        isPredicted: Bool,
        inputGeneration: UInt64? = nil
    ) {
        guard let index else { return }
        if expecting.isEmpty {
            entries.removeValue(forKey: index)
        } else {
            entries[index] = Entry(
                value: value,
                isPredicted: isPredicted,
                inputGeneration: inputGeneration
            )
        }
    }

    mutating func discardPredicted() {
        entries = entries.filter { !$0.value.isPredicted }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}

struct TabletEventSignature: Equatable {
    let timestamp: TimeInterval
    let position: ScreenPoint
    let pressure: Float
    let deviceIdentifier: Int?
    let phase: StrokePhase
}

struct TabletEventDeduplicator {
    private var lastDelivered: TabletEventSignature?

    mutating func shouldDeliver(_ signature: TabletEventSignature) -> Bool {
        guard signature != lastDelivered else { return false }
        lastDelivered = signature
        return true
    }

    mutating func reset() {
        lastDelivered = nil
    }
}

#if os(macOS)
import AppKit

/// Converts AppKit pointer events into the platform-neutral BrushInput V2
/// contract. Native event details stop at this boundary.
@MainActor
struct BrushInputAdapter {
    enum TabletCapability {
        static let tiltX: UInt = 0x0080
        static let tiltY: UInt = 0x0100
        static let pressure: UInt = 0x0400
        static let tangentialPressure: UInt = 0x0800
        static let rotation: UInt = 0x2000
    }

    struct NativeSample: Equatable {
        let position: ScreenPoint
        let pressure: Float
        let timestamp: TimeInterval
        let tilt: SIMD2<Float>?
        let rotationDegrees: Float?
        let tangentialPressure: Float?
        let deviceIdentifier: Int?
        let capabilityMask: UInt?
        let phase: StrokePhase
        let kind: StrokeSampleKind
        let isTablet: Bool

        init(
            position: ScreenPoint,
            pressure: Float,
            timestamp: TimeInterval,
            tilt: SIMD2<Float>? = nil,
            rotationDegrees: Float? = nil,
            tangentialPressure: Float? = nil,
            deviceIdentifier: Int? = nil,
            capabilityMask: UInt? = nil,
            phase: StrokePhase,
            kind: StrokeSampleKind = .actual,
            isTablet: Bool
        ) {
            self.position = position
            self.pressure = pressure
            self.timestamp = timestamp
            self.tilt = tilt
            self.rotationDegrees = rotationDegrees
            self.tangentialPressure = tangentialPressure
            self.deviceIdentifier = deviceIdentifier
            self.capabilityMask = capabilityMask
            self.phase = phase
            self.kind = kind
            self.isTablet = isTablet
        }
    }

    private var tabletCapabilitiesByDeviceIdentifier: [UInt64: UInt] = [:]

    mutating func updateTabletProximity(
        deviceIdentifier: Int,
        capabilityMask: UInt,
        isEntering: Bool
    ) {
        guard deviceIdentifier >= 0 else { return }
        let identifier = UInt64(deviceIdentifier)
        if isEntering {
            tabletCapabilitiesByDeviceIdentifier[identifier] = capabilityMask
        } else {
            tabletCapabilitiesByDeviceIdentifier.removeValue(
                forKey: identifier
            )
        }
    }

    mutating func updateTabletProximity(with event: NSEvent) {
        guard event.type == .tabletProximity, event.capabilityMask >= 0 else {
            return
        }
        updateTabletProximity(
            deviceIdentifier: event.deviceID,
            capabilityMask: UInt(event.capabilityMask),
            isEntering: event.isEnteringProximity
        )
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
        BrushInputBatchPolicy.stableOrder(
            nativeSamples.compactMap(normalizedSample),
            timestamp: \.timestamp
        )
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
            tangentialPressure: event.tangentialPressure,
            deviceIdentifier: event.deviceID,
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

        let deviceIdentifier = native.deviceIdentifier.flatMap {
            $0 >= 0 ? UInt64($0) : nil
        }
        let mask = native.capabilityMask
            ?? deviceIdentifier.flatMap {
                tabletCapabilitiesByDeviceIdentifier[$0]
            }
            ?? 0
        var capabilities: StrokeInputCapabilities = []

        let pressure: Float
        if mask & TabletCapability.pressure != 0,
           native.pressure.isFinite
        {
            pressure = native.pressure
            capabilities.insert(.pressure)
        } else {
            pressure = 0.5
        }

        var altitude: Float?
        var azimuth: Float?
        if mask & TabletCapability.tiltX != 0,
           mask & TabletCapability.tiltY != 0,
           let tilt = native.tilt,
           tilt.x.isFinite,
           tilt.y.isFinite
        {
            let magnitude = min(1, hypot(tilt.x, tilt.y))
            altitude = acos(magnitude)
            azimuth = atan2(tilt.y, tilt.x)
            capabilities.formUnion([.altitude, .azimuth])
        }

        var roll: Float?
        if mask & TabletCapability.rotation != 0,
           let rotationDegrees = native.rotationDegrees,
           rotationDegrees.isFinite
        {
            roll = rotationDegrees * .pi / 180
            capabilities.insert(.roll)
        }

        var tangentialPressure: Float?
        if mask & TabletCapability.tangentialPressure != 0,
           let nativeTangentialPressure = native.tangentialPressure,
           nativeTangentialPressure.isFinite
        {
            tangentialPressure = nativeTangentialPressure
            capabilities.insert(.tangentialPressure)
        }

        return StrokeSample.validated(
            position: native.position,
            pressure: pressure,
            timestamp: native.timestamp,
            phase: native.phase,
            source: .tablet,
            kind: native.kind,
            capabilities: capabilities,
            altitude: altitude,
            azimuth: azimuth,
            roll: roll,
            tangentialPressure: tangentialPressure,
            deviceIdentifier: deviceIdentifier
        )
    }
}
#elseif os(iOS)
import UIKit

/// Converts UIKit touch batches into normalized, stably ordered Pencil input.
@MainActor
struct BrushInputAdapter {
    private var activeTouchHasRollCapability = false

    mutating func beginTouch() {
        activeTouchHasRollCapability = false
    }

    mutating func endTouch() {
        activeTouchHasRollCapability = false
    }

    mutating func orderedSamples(
        coalescedTouches: [UITouch],
        actualTouch: UITouch,
        predictedTouches: ArraySlice<UITouch>,
        terminalPhase: StrokePhase,
        in view: UIView
    ) -> [StrokeSample] {
        var ordinary = coalescedTouches
        if !ordinary.contains(where: { $0 === actualTouch }) {
            ordinary.append(actualTouch)
        }
        let orderedOrdinary = BrushInputBatchPolicy.stableOrder(
            ordinary,
            timestamp: \.timestamp
        )
        var samples: [StrokeSample] = []
        samples.reserveCapacity(
            orderedOrdinary.count + predictedTouches.count
        )
        for (index, touch) in orderedOrdinary.enumerated() {
            let phase = BrushInputBatchPolicy.phase(
                at: index,
                count: orderedOrdinary.count,
                terminalPhase: terminalPhase
            )
            let kind: StrokeSampleKind =
                index == orderedOrdinary.count - 1 ? .actual : .coalesced
            if let sample = normalizedSample(
                touch,
                phase: phase,
                kind: kind,
                in: view
            ) {
                samples.append(sample)
            }
        }
        for touch in BrushInputBatchPolicy.stableOrder(
            predictedTouches,
            timestamp: \.timestamp
        ) {
            if let sample = normalizedSample(
                touch,
                phase: .moved,
                kind: .predicted,
                in: view
            ) {
                samples.append(sample)
            }
        }
        return samples
    }

    mutating func estimatedUpdate(
        for touch: UITouch,
        in view: UIView
    ) -> StrokeSample? {
        normalizedSample(
            touch,
            phase: .moved,
            kind: .estimatedUpdate,
            in: view
        )
    }

    func isAwaitingEstimatedUpdates(_ touch: UITouch) -> Bool {
        !estimatedProperties(
            touch.estimatedPropertiesExpectingUpdates
        ).isEmpty
    }

    func estimationState(
        for touch: UITouch
    ) -> (
        index: Int?,
        expecting: StrokeEstimatedProperties
    ) {
        (
            touch.estimationUpdateIndex?.intValue,
            estimatedProperties(
                touch.estimatedPropertiesExpectingUpdates
            )
        )
    }

    private mutating func normalizedSample(
        _ touch: UITouch,
        phase: StrokePhase,
        kind: StrokeSampleKind,
        in view: UIView
    ) -> StrokeSample? {
        let point = touch.location(in: view)
        let isPencil = touch.type == .pencil
        var capabilities: StrokeInputCapabilities = []
        let pressure: Float
        if isPencil,
           touch.maximumPossibleForce.isFinite,
           touch.maximumPossibleForce > 0,
           touch.force.isFinite
        {
            pressure = Float(touch.force / touch.maximumPossibleForce)
            capabilities.insert(.pressure)
        } else {
            pressure = 0.5
        }

        var altitude: Float?
        var azimuth: Float?
        if isPencil {
            let nativeAltitude = Float(touch.altitudeAngle)
            let nativeAzimuth = Float(touch.azimuthAngle(in: view))
            if nativeAltitude.isFinite {
                altitude = nativeAltitude
                capabilities.insert(.altitude)
            }
            if nativeAzimuth.isFinite {
                azimuth = nativeAzimuth
                capabilities.insert(.azimuth)
            }
        }

        let estimated = estimatedProperties(touch.estimatedProperties)
        let expecting = estimatedProperties(
            touch.estimatedPropertiesExpectingUpdates
        )
        let nativeRoll = Float(touch.rollAngle)
        if isPencil {
            activeTouchHasRollCapability = BrushInputBatchPolicy
                .discoversRoll(
                    previouslyDiscovered: activeTouchHasRollCapability,
                    rollIsEstimated: estimated.contains(.roll),
                    rollExpectsUpdate: expecting.contains(.roll),
                    nativeRoll: nativeRoll
                )
        }
        let roll: Float?
        if activeTouchHasRollCapability, nativeRoll.isFinite {
            roll = nativeRoll
            capabilities.insert(.roll)
        } else {
            roll = nil
        }

        let estimationUpdateIndex = touch.estimationUpdateIndex?.intValue
        return StrokeSample.validated(
            position: ScreenPoint(x: Float(point.x), y: Float(point.y)),
            pressure: pressure,
            timestamp: touch.timestamp,
            phase: phase,
            source: isPencil ? .pencil : .mouse,
            kind: kind,
            capabilities: capabilities,
            altitude: altitude,
            azimuth: azimuth,
            roll: roll,
            estimationUpdateIndex: estimationUpdateIndex,
            estimatedProperties: estimated,
            estimatedPropertiesExpectingUpdates: expecting
        )
    }

    private func estimatedProperties(
        _ properties: UITouch.Properties
    ) -> StrokeEstimatedProperties {
        var result: StrokeEstimatedProperties = []
        if properties.contains(.force) {
            result.insert(.pressure)
        }
        if properties.contains(.azimuth) {
            result.insert(.azimuth)
        }
        if properties.contains(.altitude) {
            result.insert(.altitude)
        }
        if properties.contains(.location) {
            result.insert(.location)
        }
        if properties.contains(.roll) {
            result.insert(.roll)
        }
        return result
    }
}
#endif
