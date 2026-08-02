import Foundation

/// Separates committed/coalesced input from speculative prediction streams.
public enum StrokeEmissionProvenance: UInt8, Equatable, Sendable {
    case authoritative
    case prediction
}

/// Stable precedence used when unnumbered candidates are merged later.
public enum StrokeEmissionCandidateKind: UInt8, Equatable, Sendable {
    case begin
    case distance
    case time
    case corner
    case finish
}

/// A fully attributed logical emission request before ordinal/random assignment.
public struct StrokeEmissionCandidate: Equatable, Sendable {
    public let sample: InterpolatedStrokeSample
    public let relativeStrokeTime: TimeInterval
    public let sourceDistance: Double
    public let direction: Float
    public let provenance: StrokeEmissionProvenance
    public let timeKey: Int64
    public let distanceKey: Int64
    public let kind: StrokeEmissionCandidateKind
    public let cornerSequence: UInt64

    public init(
        sample: InterpolatedStrokeSample,
        relativeStrokeTime: TimeInterval,
        sourceDistance: Double,
        direction: Float,
        provenance: StrokeEmissionProvenance,
        timeKey: Int64,
        distanceKey: Int64,
        kind: StrokeEmissionCandidateKind,
        cornerSequence: UInt64
    ) {
        self.sample = sample
        self.relativeStrokeTime = relativeStrokeTime
        self.sourceDistance = sourceDistance
        self.direction = direction
        self.provenance = provenance
        self.timeKey = timeKey
        self.distanceKey = distanceKey
        self.kind = kind
        self.cornerSequence = cornerSequence
    }

    public var position: WorldPoint {
        sample.position
    }

    func cornerCandidate(
        direction: Float,
        sequence: UInt64
    ) -> StrokeEmissionCandidate {
        StrokeEmissionCandidate(
            sample: sample,
            relativeStrokeTime: relativeStrokeTime,
            sourceDistance: sourceDistance,
            direction: direction,
            provenance: provenance,
            timeKey: timeKey,
            distanceKey: distanceKey,
            kind: .corner,
            cornerSequence: sequence
        )
    }
}

/// Inline storage for the bounded orientation fan from one corner.
public struct StrokeEmissionCandidateBuffer: Equatable, Sendable {
    public static let maximumCount = 32

    public private(set) var count = 0

    private var slot0: StrokeEmissionCandidate?
    private var slot1: StrokeEmissionCandidate?
    private var slot2: StrokeEmissionCandidate?
    private var slot3: StrokeEmissionCandidate?
    private var slot4: StrokeEmissionCandidate?
    private var slot5: StrokeEmissionCandidate?
    private var slot6: StrokeEmissionCandidate?
    private var slot7: StrokeEmissionCandidate?
    private var slot8: StrokeEmissionCandidate?
    private var slot9: StrokeEmissionCandidate?
    private var slot10: StrokeEmissionCandidate?
    private var slot11: StrokeEmissionCandidate?
    private var slot12: StrokeEmissionCandidate?
    private var slot13: StrokeEmissionCandidate?
    private var slot14: StrokeEmissionCandidate?
    private var slot15: StrokeEmissionCandidate?
    private var slot16: StrokeEmissionCandidate?
    private var slot17: StrokeEmissionCandidate?
    private var slot18: StrokeEmissionCandidate?
    private var slot19: StrokeEmissionCandidate?
    private var slot20: StrokeEmissionCandidate?
    private var slot21: StrokeEmissionCandidate?
    private var slot22: StrokeEmissionCandidate?
    private var slot23: StrokeEmissionCandidate?
    private var slot24: StrokeEmissionCandidate?
    private var slot25: StrokeEmissionCandidate?
    private var slot26: StrokeEmissionCandidate?
    private var slot27: StrokeEmissionCandidate?
    private var slot28: StrokeEmissionCandidate?
    private var slot29: StrokeEmissionCandidate?
    private var slot30: StrokeEmissionCandidate?
    private var slot31: StrokeEmissionCandidate?

    public init() {}

    public var isEmpty: Bool {
        count == 0
    }

    public subscript(index: Int) -> StrokeEmissionCandidate {
        precondition(index >= 0 && index < count, "Candidate index out of range")
        return candidate(at: index)!
    }

    public mutating func reset() {
        count = 0
    }

    public static func == (
        lhs: StrokeEmissionCandidateBuffer,
        rhs: StrokeEmissionCandidateBuffer
    ) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        for index in 0..<lhs.count where lhs[index] != rhs[index] {
            return false
        }
        return true
    }

    mutating func append(_ candidate: StrokeEmissionCandidate) {
        precondition(count < Self.maximumCount, "Candidate buffer is full")
        set(candidate, at: count)
        count += 1
    }

    private func candidate(at index: Int) -> StrokeEmissionCandidate? {
        switch index {
        case 0: slot0
        case 1: slot1
        case 2: slot2
        case 3: slot3
        case 4: slot4
        case 5: slot5
        case 6: slot6
        case 7: slot7
        case 8: slot8
        case 9: slot9
        case 10: slot10
        case 11: slot11
        case 12: slot12
        case 13: slot13
        case 14: slot14
        case 15: slot15
        case 16: slot16
        case 17: slot17
        case 18: slot18
        case 19: slot19
        case 20: slot20
        case 21: slot21
        case 22: slot22
        case 23: slot23
        case 24: slot24
        case 25: slot25
        case 26: slot26
        case 27: slot27
        case 28: slot28
        case 29: slot29
        case 30: slot30
        case 31: slot31
        default: preconditionFailure("Candidate index must be in 0..<32")
        }
    }

    private mutating func set(
        _ candidate: StrokeEmissionCandidate,
        at index: Int
    ) {
        switch index {
        case 0: slot0 = candidate
        case 1: slot1 = candidate
        case 2: slot2 = candidate
        case 3: slot3 = candidate
        case 4: slot4 = candidate
        case 5: slot5 = candidate
        case 6: slot6 = candidate
        case 7: slot7 = candidate
        case 8: slot8 = candidate
        case 9: slot9 = candidate
        case 10: slot10 = candidate
        case 11: slot11 = candidate
        case 12: slot12 = candidate
        case 13: slot13 = candidate
        case 14: slot14 = candidate
        case 15: slot15 = candidate
        case 16: slot16 = candidate
        case 17: slot17 = candidate
        case 18: slot18 = candidate
        case 19: slot19 = candidate
        case 20: slot20 = candidate
        case 21: slot21 = candidate
        case 22: slot22 = candidate
        case 23: slot23 = candidate
        case 24: slot24 = candidate
        case 25: slot25 = candidate
        case 26: slot26 = candidate
        case 27: slot27 = candidate
        case 28: slot28 = candidate
        case 29: slot29 = candidate
        case 30: slot30 = candidate
        case 31: slot31 = candidate
        default: preconditionFailure("Candidate index must be in 0..<32")
        }
    }
}
