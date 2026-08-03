public enum StrokeEmissionMergerError: Error, Equatable, Sendable {
    case provenanceMismatch(
        expected: StrokeEmissionProvenance,
        actual: StrokeEmissionProvenance
    )
}

/// One transactional decision from two individually ordered candidate streams.
/// The caller advances its source cursors and installs `continuation` only
/// after accepting `candidate`; a rejected exact duplicate has no candidate and
/// can be committed without consuming identity or random state.
public struct StrokeEmissionMergeStep: Equatable, Sendable {
    public let candidate: StrokeEmissionCandidate?
    public let consumesDistance: Bool
    public let consumesTimed: Bool
    public let continuation: StrokeEmissionMerger
}

/// Allocation-free exact-key merge state for one provenance stream.
public struct StrokeEmissionMerger: Equatable, Sendable {
    public let provenance: StrokeEmissionProvenance

    private var hasAcceptedMergeKey: Bool
    private var acceptedTimeKey: Int64
    private var acceptedDistanceKey: Int64

    public init(provenance: StrokeEmissionProvenance) {
        self.provenance = provenance
        hasAcceptedMergeKey = false
        acceptedTimeKey = 0
        acceptedDistanceKey = 0
    }

    /// Chooses the next candidate by the locked tuple
    /// `(provenance, timeKey, distanceKey, kind, cornerSequence)`.
    /// Both inputs must already be ordered within their respective streams.
    public func next(
        distance: StrokeEmissionCandidate?,
        timed: StrokeEmissionCandidate?
    ) throws -> StrokeEmissionMergeStep? {
        try validate(distance)
        try validate(timed)
        guard distance != nil || timed != nil else { return nil }

        let selected: StrokeEmissionCandidate
        let consumesDistance: Bool
        let consumesTimed: Bool
        if let distance, let timed {
            if Self.mergeEquivalent(distance, timed) {
                selected = Self.precedes(timed, distance) ? timed : distance
                consumesDistance = true
                consumesTimed = true
            } else if Self.precedes(distance, timed) {
                selected = distance
                consumesDistance = true
                consumesTimed = false
            } else {
                selected = timed
                consumesDistance = false
                consumesTimed = true
            }
        } else if let distance {
            selected = distance
            consumesDistance = true
            consumesTimed = false
        } else if let timed {
            selected = timed
            consumesDistance = false
            consumesTimed = true
        } else {
            return nil
        }

        var continuation = self
        let isDuplicate = continuation.isAcceptedDuplicate(selected)
        if !isDuplicate {
            continuation.recordAccepted(selected)
        }
        return StrokeEmissionMergeStep(
            candidate: isDuplicate ? nil : selected,
            consumesDistance: consumesDistance,
            consumesTimed: consumesTimed,
            continuation: continuation
        )
    }

    private func validate(_ candidate: StrokeEmissionCandidate?) throws {
        guard let candidate, candidate.provenance != provenance else { return }
        throw StrokeEmissionMergerError.provenanceMismatch(
            expected: provenance,
            actual: candidate.provenance
        )
    }

    private func isAcceptedDuplicate(
        _ candidate: StrokeEmissionCandidate
    ) -> Bool {
        Self.isMergeable(candidate.kind)
            && hasAcceptedMergeKey
            && candidate.timeKey == acceptedTimeKey
            && candidate.distanceKey == acceptedDistanceKey
    }

    private mutating func recordAccepted(
        _ candidate: StrokeEmissionCandidate
    ) {
        guard Self.isMergeable(candidate.kind) else { return }
        hasAcceptedMergeKey = true
        acceptedTimeKey = candidate.timeKey
        acceptedDistanceKey = candidate.distanceKey
    }

    private static func mergeEquivalent(
        _ lhs: StrokeEmissionCandidate,
        _ rhs: StrokeEmissionCandidate
    ) -> Bool {
        lhs.provenance == rhs.provenance
            && lhs.timeKey == rhs.timeKey
            && lhs.distanceKey == rhs.distanceKey
            && isMergeable(lhs.kind)
            && isMergeable(rhs.kind)
    }

    private static func isMergeable(
        _ kind: StrokeEmissionCandidateKind
    ) -> Bool {
        kind != .corner
    }

    static func precedes(
        _ lhs: StrokeEmissionCandidate,
        _ rhs: StrokeEmissionCandidate
    ) -> Bool {
        if lhs.provenance.rawValue != rhs.provenance.rawValue {
            return lhs.provenance.rawValue < rhs.provenance.rawValue
        }
        if lhs.timeKey != rhs.timeKey { return lhs.timeKey < rhs.timeKey }
        if lhs.distanceKey != rhs.distanceKey {
            return lhs.distanceKey < rhs.distanceKey
        }
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.cornerSequence < rhs.cornerSequence
    }
}
