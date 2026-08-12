import Foundation
import simd

public enum BrushStrokeGeneratorFootprintError: Error, Equatable, Sendable {
    case nominalDiameterOutsideCompiledLimits(
        actual: Float,
        minimum: Float,
        maximum: Float
    )
    case unsafeCompiledFootprintEnvelope
    case worldPositionOutsideFootprintEnvelope
}

public enum BrushStrokeGeneratorEmissionError: Error, Equatable, Sendable {
    case logicalOrdinalOverflow
}

/// A conservative, compile-once proof that every accepted schema-v2 sample can
/// build its post-dynamics affine support using finite Float arithmetic. The
/// fourfold input margin covers the bounded interpolator's control-point
/// envelope; the wider arithmetic margin protects all placement and shape math.
private struct BrushStrokeFootprintEnvelope: Equatable, Sendable {
    static let interpolationSafetyDivisor = 4.0
    static let arithmeticSafetyDivisor = 1_024.0

    let rejection: BrushStrokeGeneratorFootprintError?
    let maximumInputMagnitude: Float

    static func compile(
        program: BrushProgram,
        component: BrushComponentProgram,
        nominalDiameter: Float
    ) -> BrushStrokeFootprintEnvelope {
        let limits = program.definition.limits
        guard nominalDiameter >= limits.minimumDiameter,
              nominalDiameter <= limits.maximumDiameter
        else {
            return BrushStrokeFootprintEnvelope(
                rejection: .nominalDiameterOutsideCompiledLimits(
                    actual: nominalDiameter,
                    minimum: limits.minimumDiameter,
                    maximum: limits.maximumDiameter
                ),
                maximumInputMagnitude: 0
            )
        }

        let definition = component.definition
        let nominal = Double(nominalDiameter)
        let maximumRadius = nominal * 4
        let aspect = Double(definition.coverage.aspectRatio)
        var maximumShapeReach = 0.0
        for shape in definition.coverage.shapes {
            let offsetReach = maximumRadius * (
                abs(Double(shape.offset.x))
                    + aspect * abs(Double(shape.offset.y))
            )
            let axisReach = maximumRadius
                * Double(shape.scale)
                * (1 + aspect)
            maximumShapeReach = max(
                maximumShapeReach,
                offsetReach + axisReach
            )
        }
        let placement = definition.placement
        let maximumDynamicOffset = nominal * 8
        let maximumScatter = nominal
            * Double(placement.baseScatterFraction)
            * 8
            * Double(definition.dynamics.randomization.scatter)
        let maximumJitter = nominal
            * Double(placement.baseJitterFraction)
        let maximumBaseOffset = max(
            abs(Double(placement.baseOffset.x)),
            abs(Double(placement.baseOffset.y))
        )
        let maximumReach = maximumShapeReach
            + maximumDynamicOffset
            + maximumScatter
            + maximumJitter
            + maximumBaseOffset
        let arithmeticLimit = Double(Float.greatestFiniteMagnitude)
            / arithmeticSafetyDivisor
        guard maximumReach.isFinite,
              maximumReach >= 0,
              maximumReach < arithmeticLimit
        else {
            return BrushStrokeFootprintEnvelope(
                rejection: .unsafeCompiledFootprintEnvelope,
                maximumInputMagnitude: 0
            )
        }
        return BrushStrokeFootprintEnvelope(
            rejection: nil,
            maximumInputMagnitude: Float(
                (arithmeticLimit - maximumReach)
                    / interpolationSafetyDivisor
            )
        )
    }

    func validate(_ sample: WorldStrokeSample) throws {
        if let rejection { throw rejection }
        guard abs(sample.position.x) <= maximumInputMagnitude,
              abs(sample.position.y) <= maximumInputMagnitude
        else {
            throw BrushStrokeGeneratorFootprintError
                .worldPositionOutsideFootprintEnvelope
        }
    }
}

extension BrushComponentStrokeGenerator {
    public struct EmissionPage: Equatable, Sendable {
        public let emittedCount: Int
        public let hasMore: Bool
    }

    public enum EmissionSinkDecision: Equatable, Sendable {
        case accept
        case pause
    }

    /// A copyable, exact continuation for one current input sample.
    /// This is the sole production-facing generation API.
    public struct EmissionCursor: Equatable, Sendable {
        private enum Operation: Equatable, Sendable {
            case begin, append, finish
        }

        /// Each worker installs its successor and returns to `emitNextPage`.
        /// Only `advanceOne` may dispatch a worker; workers must never invoke
        /// one another or their large debug frames become simultaneously live.
        private enum Phase: Equatable, Sendable {
            case prepare
            case initialPath
            case beginSource
            case pendingSegment
            case finishSource
            case finishTimedAdvance
            case finishTimedTermination
            case path
            case afterPath
            case source
            case segmentPrepareSpatial
            case segmentPrepareTimed
            case segmentDecide
            case segmentSettleDuplicate
            case segmentCommit
            case segmentLifecycle
            case complete
        }

        private enum SourcePurpose: Equatable, Sendable {
            case complete
            case resetAndComplete
            case segment
            case finish
        }

        enum CandidateAdvance: Equatable, Sendable {
            case noDab
            case prepared
            case blocked
        }

        private struct PendingMergeDecision: Equatable, Sendable {
            let continuation: StrokeEmissionMerger
            let consumesDistance: Bool
            let consumesTimed: Bool
            let selectsDistance: Bool
            let acceptsCandidate: Bool

            init(
                step: StrokeEmissionMergeStep,
                distance: StrokeEmissionCandidate?,
                timed: StrokeEmissionCandidate?
            ) {
                guard let candidate = step.candidate else {
                    preconditionFailure(
                        "A pending emission decision must contain a candidate"
                    )
                }
                self.init(
                    continuation: step.continuation,
                    consumesDistance: step.consumesDistance,
                    consumesTimed: step.consumesTimed,
                    selectsDistance: distance == candidate || timed == nil,
                    acceptsCandidate: true
                )
            }

            init(
                continuation: StrokeEmissionMerger,
                consumesDistance: Bool,
                consumesTimed: Bool,
                selectsDistance: Bool,
                acceptsCandidate: Bool
            ) {
                self.continuation = continuation
                self.consumesDistance = consumesDistance
                self.consumesTimed = consumesTimed
                self.selectsDistance = selectsDistance
                self.acceptsCandidate = acceptsCandidate
            }
        }

        private struct SourceCursor: Equatable, Sendable {
            private enum CandidatePhase: Equatable, Sendable {
                case decide
                case commit
            }

            var distanceHead: StrokeEmissionCandidate?
            var timedHead: StrokeEmissionCandidate?
            var timedCursor: TimedStrokeEmissionCursor?
            var merger: StrokeEmissionMerger
            let isPredicted: Bool
            private var candidatePhase = CandidatePhase.decide
            private var pendingTimedCandidate: StrokeEmissionCandidate?
            private var pendingMergeDecision: PendingMergeDecision?

            init(
                distanceHead: StrokeEmissionCandidate?,
                timedHead: StrokeEmissionCandidate?,
                timedCursor: TimedStrokeEmissionCursor?,
                merger: StrokeEmissionMerger,
                isPredicted: Bool
            ) {
                self.distanceHead = distanceHead
                self.timedHead = timedHead
                self.timedCursor = timedCursor
                self.merger = merger
                self.isPredicted = isPredicted
                candidatePhase = .decide
                pendingTimedCandidate = nil
                pendingMergeDecision = nil
            }

            var isComplete: Bool {
                distanceHead == nil
                    && timedHead == nil
                    && timedCursor?.isComplete != false
            }

            @inline(never)
            mutating func advanceSourceCandidate(
                allowEmission: Bool
            ) throws -> CandidateAdvance {
                if candidatePhase == .commit {
                    guard pendingMergeDecision != nil else {
                        preconditionFailure(
                            "Committed source decision must contain a dab"
                        )
                    }
                    return allowEmission ? .prepared : .blocked
                }

                if timedHead == nil,
                   pendingTimedCandidate == nil,
                   let timedStep = try timedCursor?.nextCandidate()
                {
                    pendingTimedCandidate = timedStep.candidate
                    timedCursor = timedStep.continuation
                }
                let timedCandidate = timedHead ?? pendingTimedCandidate
                guard let step = try merger.next(
                    distance: distanceHead,
                    timed: timedCandidate
                ) else { return .noDab }

                if step.candidate != nil {
                    guard allowEmission else { return .blocked }
                    pendingMergeDecision = PendingMergeDecision(
                        step: step,
                        distance: distanceHead,
                        timed: timedCandidate
                    )
                    candidatePhase = .commit
                    return .prepared
                }

                commit(
                    continuation: step.continuation,
                    consumesDistance: step.consumesDistance,
                    consumesTimed: step.consumesTimed
                )
                return .noDab
            }

            var preparedCandidate: StrokeEmissionCandidate? {
                guard candidatePhase == .commit,
                      let decision = pendingMergeDecision
                else { return nil }
                return decision.selectsDistance
                    ? distanceHead
                    : (timedHead ?? pendingTimedCandidate)
            }

            mutating func commitPreparedCandidate() {
                guard candidatePhase == .commit,
                      let decision = pendingMergeDecision
                else {
                    preconditionFailure(
                        "Missing prepared source emission decision"
                    )
                }
                commit(
                    continuation: decision.continuation,
                    consumesDistance: decision.consumesDistance,
                    consumesTimed: decision.consumesTimed
                )
            }

            private mutating func commit(
                continuation: StrokeEmissionMerger,
                consumesDistance: Bool,
                consumesTimed: Bool
            ) {
                merger = continuation
                if consumesDistance { distanceHead = nil }
                if consumesTimed {
                    if timedHead != nil {
                        timedHead = nil
                    } else {
                        pendingTimedCandidate = nil
                    }
                }
                pendingMergeDecision = nil
                candidatePhase = .decide
            }
        }

        private struct SegmentCursor: Equatable, Sendable {
            let segment: AttributedStrokePathSegment
            let direction: Float
            let isPredicted: Bool
            let baseDistance: Float
            let length: Float
            let delta: SIMD2<Float>
            var cornerCursor: BrushCornerEmissionCursor?
            var timedCursor: TimedStrokeEmissionCursor?
            var merger: StrokeEmissionMerger
            var traversed: Float

            var pendingSpatialCandidate: StrokeEmissionCandidate?
            var pendingSpatialIsCorner: Bool
            var pendingTimedCandidate: StrokeEmissionCandidate?
            var pendingMergeDecision: PendingMergeDecision?

            var hasSource: Bool {
                cornerCursor?.isComplete == false
                    || timedCursor?.isComplete == false
            }

            @inline(never)
            fileprivate mutating func prepareSpatialCandidate(
                generator: borrowing BrushComponentStrokeGenerator
            ) throws {
                let distanceStep = generator.distanceUntilNext
                let distanceCandidate: StrokeEmissionCandidate?
                if generator.stageCUsesDistanceEmission,
                   distanceStep.isFinite,
                   distanceStep >= 0,
                   traversed + distanceStep <= length
                {
                    let candidateOffset = traversed + distanceStep
                    let fraction = length == 0
                        ? 0
                        : min(1, candidateOffset / length)
                    let exactPosition = WorldPoint(
                        segment.start.position.simd + delta * fraction
                    )
                    let sample = segment.sample(
                        at: fraction,
                        exactPosition: exactPosition
                    )
                    distanceCandidate = try generator.stageCCandidate(
                        sample: sample,
                        sourceDistance: Double(
                            baseDistance + candidateOffset
                        ),
                        direction: direction,
                        kind: .distance,
                        isPredicted: isPredicted
                    )
                } else {
                    distanceCandidate = nil
                }

                let cornerCandidate = cornerCursor?.nextCandidate()?.candidate
                if let cornerCandidate, let distanceCandidate {
                    if StrokeEmissionMerger.precedes(
                        cornerCandidate,
                        distanceCandidate
                    ) {
                        pendingSpatialCandidate = cornerCandidate
                        pendingSpatialIsCorner = true
                    } else {
                        pendingSpatialCandidate = distanceCandidate
                        pendingSpatialIsCorner = false
                    }
                } else if let cornerCandidate {
                    pendingSpatialCandidate = cornerCandidate
                    pendingSpatialIsCorner = true
                } else {
                    pendingSpatialCandidate = distanceCandidate
                    pendingSpatialIsCorner = false
                }
            }

            @inline(never)
            fileprivate mutating func decidePreparedCandidates(
                allowEmission: Bool
            ) throws -> CandidateAdvance {
                guard let mergeStep = try merger.next(
                    distance: pendingSpatialCandidate,
                    timed: pendingTimedCandidate
                ) else {
                    return .noDab
                }

                if mergeStep.candidate != nil, !allowEmission {
                    return .blocked
                }
                if mergeStep.candidate != nil {
                    pendingMergeDecision = PendingMergeDecision(
                        step: mergeStep,
                        distance: pendingSpatialCandidate,
                        timed: pendingTimedCandidate
                    )
                    return .prepared
                }
                pendingMergeDecision = PendingMergeDecision(
                    continuation: mergeStep.continuation,
                    consumesDistance: mergeStep.consumesDistance,
                    consumesTimed: mergeStep.consumesTimed,
                    selectsDistance: mergeStep.consumesDistance,
                    acceptsCandidate: false
                )
                return .noDab
            }

            @inline(never)
            mutating func commitPreparedCandidate(
                generator: inout BrushComponentStrokeGenerator
            ) {
                guard let decision = pendingMergeDecision else {
                    preconditionFailure(
                        "Missing prepared segment emission decision"
                    )
                }
                commitPreparedCandidates(
                    generator: &generator,
                    continuation: decision.continuation,
                    consumesDistance: decision.consumesDistance,
                    consumesTimed: decision.consumesTimed,
                    selectsDistance: decision.selectsDistance
                )
            }

            var preparedCandidate: StrokeEmissionCandidate? {
                guard let decision = pendingMergeDecision,
                      decision.acceptsCandidate
                else { return nil }
                return decision.selectsDistance
                    ? pendingSpatialCandidate
                    : pendingTimedCandidate
            }

            private mutating func commitPreparedCandidates(
                generator: inout BrushComponentStrokeGenerator,
                continuation: StrokeEmissionMerger,
                consumesDistance: Bool,
                consumesTimed: Bool,
                selectsDistance: Bool
            ) {
                guard let selected = selectsDistance
                    ? pendingSpatialCandidate
                    : pendingTimedCandidate
                else {
                    preconditionFailure(
                        "Emission merger consumed a source without a candidate"
                    )
                }
                let selectedOffset = min(
                    length,
                    max(0, Float(selected.sourceDistance) - baseDistance)
                )
                var proposedTraversed = traversed
                var proposedDistanceUntilNext = generator.distanceUntilNext
                if selectedOffset > proposedTraversed {
                    proposedDistanceUntilNext = max(
                        0,
                        proposedDistanceUntilNext
                            - (selectedOffset - proposedTraversed)
                    )
                    proposedTraversed = selectedOffset
                }

                if let accepted = preparedCandidate {
                    switch accepted.kind {
                    case .corner, .time:
                        generator.distanceUntilNext = min(
                            proposedDistanceUntilNext,
                            generator.currentSpacing
                        )
                    case .begin, .distance:
                        break
                    case .finish:
                        generator.distanceUntilNext =
                            proposedDistanceUntilNext
                    }
                } else if consumesDistance
                            && !pendingSpatialIsCorner
                {
                    generator.distanceUntilNext = generator.currentSpacing
                } else {
                    generator.distanceUntilNext = proposedDistanceUntilNext
                }

                traversed = proposedTraversed
                merger = continuation
                if consumesDistance,
                   pendingSpatialIsCorner
                {
                    cornerCursor = cornerCursor?.nextCandidate()?.continuation
                }
                if consumesTimed { pendingTimedCandidate = nil }
                pendingSpatialCandidate = nil
                pendingSpatialIsCorner = false
                pendingMergeDecision = nil
            }

            @inline(never)
            mutating func finishSegment(
                generator: inout BrushComponentStrokeGenerator
            ) {
                if generator.stageCUsesDistanceEmission,
                   traversed < length
                {
                    generator.distanceUntilNext = max(
                        0,
                        generator.distanceUntilNext - (length - traversed)
                    )
                }
                generator.processedPathDistance += length
                generator.lastDirection = direction
                if isPredicted {
                    generator.predictionEmissionMerger = merger
                } else {
                    generator.authoritativeEmissionMerger = merger
                }
            }
        }

        var generator: BrushComponentStrokeGenerator
        private let sample: WorldStrokeSample
        private let operation: Operation
        private let maximumPathSubdivisionCount: Int
        private var phase: Phase
        private var attributed: InterpolatedStrokeSample?
        private var pathCursor: AttributedStrokePathAdvanceCursor?
        private var pendingPathContinuation:
            AttributedStrokePathAdvanceCursor?
        private var pendingSegment: AttributedStrokePathSegment?
        private var pendingDirection: Float
        private var pendingSignedTurn: Float?
        private var segmentCursor: SegmentCursor?
        private var sourceCursor: SourceCursor?
        private var sourcePurpose: SourcePurpose

        fileprivate init(
            generator: BrushComponentStrokeGenerator,
            sample: WorldStrokeSample,
            maximumPathSubdivisionCount: Int
        ) {
            self.generator = generator
            self.sample = sample
            operation = switch sample.phase {
            case .began: .begin
            case .moved: .append
            case .ended: .finish
            case .cancelled:
                preconditionFailure("Cancelled input has no emission cursor")
            }
            self.maximumPathSubdivisionCount = maximumPathSubdivisionCount
            phase = .prepare
            attributed = nil
            pathCursor = nil
            pendingPathContinuation = nil
            pendingSegment = nil
            pendingDirection = 0
            pendingSignedTurn = nil
            segmentCursor = nil
            sourceCursor = nil
            sourcePurpose = .complete
        }

        public var isComplete: Bool { phase == .complete }

        /// The exact generator continuation becomes available only after the
        /// input cursor has no authoritative or prediction suffix remaining.
        public var completedGenerator: BrushComponentStrokeGenerator? {
            isComplete ? generator : nil
        }

        @discardableResult
        public mutating func emitNextPage(
            _ emit: (DabAttributes) throws -> Void
        ) throws -> EmissionPage {
            try emitNextPageDeciding { dab in
                try emit(dab)
                return .accept
            }
        }

        /// Offers candidates to a sink that may pause before accepting the
        /// current candidate. A pause preserves the exact candidate,
        /// generator random stream and logical ordinal for the next resume.
        @discardableResult
        public mutating func emitNextPageDeciding(
            _ emit: (DabAttributes) throws -> EmissionSinkDecision
        ) throws -> EmissionPage {
            var emittedCount = 0
            while !isComplete {
                let allowEmission = emittedCount
                    < LogicalDabBatch.maximumDabCount
                switch try advanceOne(
                    allowEmission: allowEmission
                ) {
                case .prepared:
                    guard allowEmission else {
                        preconditionFailure(
                            "Disabled cursor advance prepared a dab"
                        )
                    }
                    guard let candidate = preparedCandidate else {
                        preconditionFailure(
                            "Prepared cursor advance must expose a candidate"
                        )
                    }
                    let wasAccepted = try generator.offerCandidate(
                        candidate,
                        emit: emit
                    )
                    guard wasAccepted else {
                        return EmissionPage(
                            emittedCount: emittedCount,
                            hasMore: true
                        )
                    }
                    commitPreparedCandidate()
                    emittedCount += 1
                case .noDab:
                    break
                case .blocked:
                    return EmissionPage(
                        emittedCount: emittedCount,
                        hasMore: true
                    )
                }
            }
            return EmissionPage(
                emittedCount: emittedCount,
                hasMore: false
            )
        }

        mutating func advanceOne(
            allowEmission: Bool
        ) throws -> CandidateAdvance {
            switch phase {
            case .prepare:
                try prepare()
                return .noDab
            case .initialPath:
                guard let attributed else {
                    preconditionFailure("Missing initial attributed sample")
                }
                try prepareInitialPath(attributed)
                return .noDab
            case .beginSource:
                try prepareBeginSource()
                return .noDab
            case .pendingSegment:
                try preparePendingSegment()
                return .noDab
            case .finishSource:
                try prepareFinishSource()
                return .noDab
            case .finishTimedAdvance:
                try prepareFinishTimedAdvance()
                return .noDab
            case .finishTimedTermination:
                try prepareFinishTimedTermination()
                return .noDab
            case .path:
                try advancePath()
                return .noDab
            case .afterPath:
                try afterPath()
                return .noDab
            case .source:
                return try advanceSource(
                    allowEmission: allowEmission
                )
            case .segmentPrepareSpatial:
                try prepareSegmentSpatial()
                return .noDab
            case .segmentPrepareTimed:
                try prepareSegmentTimed()
                return .noDab
            case .segmentDecide:
                return try decideSegment(
                    allowEmission: allowEmission
                )
            case .segmentSettleDuplicate:
                settleSegmentDuplicate()
                return .noDab
            case .segmentCommit:
                guard segmentCursor?.pendingMergeDecision != nil else {
                    preconditionFailure(
                        "Committed segment decision must contain a dab"
                    )
                }
                return allowEmission ? .prepared : .blocked
            case .segmentLifecycle:
                advanceSegmentLifecycle()
                return .noDab
            case .complete:
                return .noDab
            }
        }

        var preparedCandidate: StrokeEmissionCandidate? {
            switch phase {
            case .source:
                sourceCursor?.preparedCandidate
            case .segmentCommit:
                segmentCursor?.preparedCandidate
            case .prepare, .initialPath, .beginSource, .pendingSegment,
                    .finishSource, .finishTimedAdvance,
                    .finishTimedTermination, .path, .afterPath,
                    .segmentPrepareSpatial,
                    .segmentPrepareTimed, .segmentDecide,
                    .segmentSettleDuplicate, .segmentLifecycle, .complete:
                nil
            }
        }

        mutating func commitPreparedCandidate() {
            switch phase {
            case .source:
                guard var cursor = sourceCursor else {
                    preconditionFailure(
                        "Missing prepared source cursor"
                    )
                }
                cursor.commitPreparedCandidate()
                sourceCursor = cursor
            case .segmentCommit:
                guard var cursor = segmentCursor else {
                    preconditionFailure(
                        "Missing prepared segment cursor"
                    )
                }
                cursor.commitPreparedCandidate(generator: &generator)
                segmentCursor = cursor
                phase = .segmentLifecycle
            case .prepare, .initialPath, .beginSource, .pendingSegment,
                    .finishSource, .finishTimedAdvance,
                    .finishTimedTermination, .path, .afterPath,
                    .segmentPrepareSpatial,
                    .segmentPrepareTimed, .segmentDecide,
                    .segmentSettleDuplicate, .segmentLifecycle, .complete:
                preconditionFailure(
                    "Prepared candidate cannot exist outside an emission source"
                )
            }
        }

        private mutating func prepare() throws {
            try generator.footprintEnvelope.validate(sample)
            if operation == .begin || !generator.isActive {
                generator.resetRuntimeState()
                generator.isActive = true
                generator.strokeStartTimestamp = sample.timestamp
                guard let stabilized = generator.processStageCStabilizer(sample)
                else {
                    complete(reset: operation == .finish)
                    return
                }
                attributed = InterpolatedStrokeSample(stabilized)
                phase = .initialPath
                return
            }

            guard let terminal = generator.processStageCStabilizer(sample)
            else {
                complete(reset: operation == .finish)
                return
            }
            try generator.validateCornerCanonicalDomain(for: terminal)
            let attributed = InterpolatedStrokeSample(terminal)
            self.attributed = attributed
            guard generator.hasAttributedPath else {
                phase = .initialPath
                return
            }

            if operation == .finish,
               case .weightedWindow = generator.component.stageC.stabilization
            {
                let update = try generator.directionTracker.update(
                    to: attributed.position
                )
                let direction = update.direction ?? generator.lastDirection
                generator.lastDirection = update.direction
                    ?? generator.lastDirection
                if generator.heldDirectionalBegin != nil {
                    pendingDirection = update.direction == nil
                        ? generator.stageCStationaryDirection
                        : direction
                    sourcePurpose = .finish
                    phase = .beginSource
                } else {
                    phase = .finishSource
                }
                return
            }

            pathCursor = try generator.path.advanceCursor(
                to: attributed,
                maximumSubdivisionCount: maximumPathSubdivisionCount
            )
            if pathCursor == nil {
                phase = .afterPath
            } else {
                phase = .path
            }
        }

        private mutating func prepareInitialPath(
            _ attributed: InterpolatedStrokeSample
        ) throws {
            self.attributed = attributed
            _ = generator.path.begin(at: attributed)
            generator.hasAttributedPath = true
            try generator.initializeTimedEmission(at: attributed)
            do {
                try generator.directionTracker.begin(at: attributed.position)
            } catch {
                preconditionFailure(
                    "Validated world input must have a finite position: \(error)"
                )
            }
            let resets = operation == .finish
            if generator.component.stageC.usesTravelDirection {
                generator.heldDirectionalBegin = attributed
                if resets {
                    pendingDirection = generator.stageCStationaryDirection
                    sourcePurpose = .resetAndComplete
                    phase = .beginSource
                } else {
                    phase = .complete
                }
            } else {
                pendingDirection = 0
                sourcePurpose = resets ? .resetAndComplete : .complete
                phase = .beginSource
            }
        }

        private mutating func advancePath() throws {
            guard let pathCursor else {
                phase = .afterPath
                return
            }
            guard let step = pathCursor.nextSegment() else {
                generator.path = pathCursor.completedPath
                self.pathCursor = nil
                phase = .afterPath
                return
            }
            if step.segment.length <= 0 {
                self.pathCursor = step.continuation
                return
            }
            let update = try generator.directionTracker.update(
                to: step.segment.end.position
            )
            let direction = update.direction ?? generator.lastDirection
            pendingPathContinuation = step.continuation
            pendingSegment = step.segment
            pendingDirection = direction
            pendingSignedTurn = update.signedTurn
            if update.direction != nil,
               generator.heldDirectionalBegin != nil
            {
                sourcePurpose = .segment
                phase = .beginSource
            } else {
                phase = .pendingSegment
            }
        }

        private mutating func preparePendingSegment() throws {
            guard let segment = pendingSegment else {
                preconditionFailure("Missing resumable path segment")
            }
            var cornerCursor: BrushCornerEmissionCursor?
            if let signedTurn = pendingSignedTurn,
               let cornerEmitter = generator.cornerEmitter
            {
                let startDirection = pendingDirection - signedTurn
                let vertex = try generator.stageCCandidate(
                    sample: segment.start,
                    sourceDistance: Double(generator.processedPathDistance),
                    direction: startDirection,
                    kind: .distance,
                    isPredicted: sample.kind == .predicted
                )
                cornerCursor = try cornerEmitter.cursor(
                    from: startDirection,
                    signedTurn: signedTurn,
                    vertex: vertex,
                    nextCornerSequence: &generator.nextCornerSequence
                )
            }
            let timedCursor = try generator.stageCTimedCursor(
                to: segment.end,
                sourceDistance: Double(
                    generator.processedPathDistance + segment.length
                ),
                direction: pendingDirection,
                isPredicted: sample.kind == .predicted
            )
            segmentCursor = SegmentCursor(
                segment: segment,
                direction: pendingDirection,
                isPredicted: sample.kind == .predicted,
                baseDistance: generator.processedPathDistance,
                length: segment.length,
                delta: segment.end.position.simd - segment.start.position.simd,
                cornerCursor: cornerCursor,
                timedCursor: timedCursor,
                merger: sample.kind == .predicted
                    ? generator.predictionEmissionMerger
                    : generator.authoritativeEmissionMerger,
                traversed: 0,
                pendingSpatialCandidate: nil,
                pendingSpatialIsCorner: false,
                pendingTimedCandidate: nil,
                pendingMergeDecision: nil
            )
            pendingSegment = nil
            pendingSignedTurn = nil
            phase = .segmentPrepareSpatial
        }

        @inline(never)
        private mutating func prepareSegmentSpatial() throws {
            guard var cursor = segmentCursor else {
                preconditionFailure("Missing resumable emission segment")
            }
            try cursor.prepareSpatialCandidate(generator: generator)
            segmentCursor = cursor
            phase = .segmentPrepareTimed
        }

        @inline(never)
        private mutating func prepareSegmentTimed() throws {
            guard var cursor = segmentCursor else {
                preconditionFailure("Missing resumable emission segment")
            }
            if let candidate = try cursor.timedCursor?.consumeNextCandidate() {
                cursor.pendingTimedCandidate = candidate
            }
            segmentCursor = cursor
            phase = .segmentDecide
        }

        @inline(never)
        private mutating func decideSegment(
            allowEmission: Bool
        ) throws -> CandidateAdvance {
            guard var cursor = segmentCursor else {
                preconditionFailure("Missing resumable emission segment")
            }
            let result = try cursor.decidePreparedCandidates(
                allowEmission: allowEmission
            )
            guard result != .blocked else { return .blocked }
            segmentCursor = cursor
            if result == .prepared {
                phase = .segmentCommit
            } else if cursor.pendingMergeDecision != nil {
                phase = .segmentSettleDuplicate
            } else {
                phase = .segmentLifecycle
            }
            return result
        }

        @inline(never)
        private mutating func settleSegmentDuplicate() {
            guard var cursor = segmentCursor else {
                preconditionFailure(
                    "Missing segment cursor for duplicate settlement"
                )
            }
            guard cursor.pendingMergeDecision != nil else {
                preconditionFailure(
                    "Duplicate settlement must contain a decision"
                )
            }
            cursor.commitPreparedCandidate(generator: &generator)
            segmentCursor = cursor
            phase = .segmentLifecycle
        }

        @inline(never)
        private mutating func advanceSegmentLifecycle() {
            guard var cursor = segmentCursor else {
                preconditionFailure("Missing resumable emission segment")
            }
            if cursor.hasSource
                || (generator.stageCUsesDistanceEmission
                    && generator.distanceUntilNext <= cursor.length
                        - cursor.traversed)
            {
                segmentCursor = cursor
                phase = .segmentPrepareSpatial
                return
            }
            cursor.finishSegment(generator: &generator)
            segmentCursor = nil
            pathCursor = pendingPathContinuation
            pendingPathContinuation = nil
            phase = .path
        }

        private mutating func afterPath() throws {
            guard let attributed else {
                preconditionFailure("Missing attributed input")
            }
            if operation == .finish {
                generator.path.cancel()
                if generator.heldDirectionalBegin != nil {
                    pendingDirection = generator.stageCStationaryDirection
                    sourcePurpose = .finish
                    phase = .beginSource
                } else {
                    phase = .finishSource
                }
                return
            }
            let timed = try generator.stageCTimedCursor(
                to: attributed,
                sourceDistance: Double(generator.processedPathDistance),
                direction: generator.lastDirection,
                isPredicted: sample.kind == .predicted
            )
            prepareSource(
                distance: nil,
                timedHead: nil,
                timedCursor: timed,
                purpose: .complete
            )
        }

        private mutating func prepareBeginSource() throws {
            let beginSample: InterpolatedStrokeSample
            if let held = generator.heldDirectionalBegin {
                beginSample = held
                generator.heldDirectionalBegin = nil
                generator.lastDirection = pendingDirection
            } else if let attributed {
                beginSample = attributed
            } else {
                preconditionFailure("Missing attributed begin sample")
            }
            let candidate = try generator.stageCCandidate(
                sample: beginSample,
                sourceDistance: 0,
                direction: pendingDirection,
                kind: .begin,
                isPredicted: sample.kind == .predicted
            )
            switch generator.stageCEmissionMode {
            case .distance:
                prepareSource(
                    distance: candidate,
                    timedHead: nil,
                    timedCursor: nil,
                    purpose: sourcePurpose
                )
            case .time:
                prepareSource(
                    distance: nil,
                    timedHead: candidate,
                    timedCursor: nil,
                    purpose: sourcePurpose
                )
            case .distanceAndTime:
                prepareSource(
                    distance: candidate,
                    timedHead: candidate,
                    timedCursor: nil,
                    purpose: sourcePurpose
                )
            }
        }

        private mutating func prepareFinishSource() throws {
            guard let attributed else {
                preconditionFailure("Missing finish input")
            }
            let isPredicted = sample.kind == .predicted
            if isPredicted {
                prepareSource(
                    distance: nil,
                    timedHead: nil,
                    timedCursor: nil,
                    purpose: .resetAndComplete
                )
                phase = .finishTimedAdvance
                return
            }
            let finish = try generator.stageCCandidate(
                sample: attributed,
                sourceDistance: Double(generator.processedPathDistance),
                direction: generator.lastDirection,
                kind: .finish,
                isPredicted: false
            )
            let distance = generator.stageCUsesDistanceEmission
                    && generator.lastEmittedSourcePosition
                        != attributed.position
                ? finish
                : nil
            prepareSource(
                distance: distance,
                timedHead: nil,
                timedCursor: nil,
                purpose: .resetAndComplete
            )
            phase = .finishTimedTermination
        }

        @inline(never)
        private mutating func prepareFinishTimedAdvance() throws {
            guard let attributed else {
                preconditionFailure("Missing predicted finish input")
            }
            guard var cursor = sourceCursor else {
                preconditionFailure("Missing predicted finish source")
            }
            cursor.timedCursor = try generator.stageCTimedCursor(
                to: attributed,
                sourceDistance: Double(generator.processedPathDistance),
                direction: generator.lastDirection,
                isPredicted: true
            )
            sourceCursor = cursor
            phase = .source
        }

        @inline(never)
        private mutating func prepareFinishTimedTermination() throws {
            guard let attributed else {
                preconditionFailure("Missing authoritative finish input")
            }
            guard var cursor = sourceCursor else {
                preconditionFailure("Missing authoritative finish source")
            }
            if generator.stageCUsesTimedEmission,
               var emitter = generator.timedEmitter
            {
                cursor.timedCursor = try emitter.finish(at: TimedStrokePoint(
                    sample: attributed,
                    sourceDistance: Double(generator.processedPathDistance),
                    direction: generator.lastDirection
                ))
                generator.timedEmitter = emitter
            }
            sourceCursor = cursor
            phase = .source
        }

        private mutating func prepareSource(
            distance: StrokeEmissionCandidate?,
            timedHead: StrokeEmissionCandidate?,
            timedCursor: TimedStrokeEmissionCursor?,
            purpose: SourcePurpose
        ) {
            let isPredicted = sample.kind == .predicted
            sourceCursor = SourceCursor(
                distanceHead: distance,
                timedHead: timedHead,
                timedCursor: timedCursor,
                merger: isPredicted
                    ? generator.predictionEmissionMerger
                    : generator.authoritativeEmissionMerger,
                isPredicted: isPredicted
            )
            sourcePurpose = purpose
            phase = .source
        }

        private mutating func advanceSource(
            allowEmission: Bool
        ) throws -> CandidateAdvance {
            guard var cursor = sourceCursor else {
                preconditionFailure("Missing resumable source cursor")
            }
            let result = try cursor.advanceSourceCandidate(
                allowEmission: allowEmission
            )
            if result == .blocked {
                return .blocked
            }
            if result == .prepared {
                sourceCursor = cursor
                return .prepared
            }
            guard cursor.isComplete else {
                sourceCursor = cursor
                return .noDab
            }
            if cursor.isPredicted {
                generator.predictionEmissionMerger = cursor.merger
            } else {
                generator.authoritativeEmissionMerger = cursor.merger
            }
            sourceCursor = nil
            switch sourcePurpose {
            case .complete:
                phase = .complete
            case .resetAndComplete:
                complete(reset: true)
            case .segment:
                phase = .pendingSegment
            case .finish:
                phase = .finishSource
            }
            return .noDab
        }

        private mutating func complete(reset: Bool) {
            if reset { generator.resetRuntimeState() }
            phase = .complete
        }
    }

    /// Creates an emission cursor without mutating this generator. Consumers
    /// install `completedGenerator` only after `hasMore` becomes false.
    public func emissionCursor(
        for sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int
    ) throws -> EmissionCursor {
        precondition(maximumPathSubdivisionCount > 0)
        precondition(sample.phase != .cancelled)
        return EmissionCursor(
            generator: self,
            sample: sample,
            maximumPathSubdivisionCount: maximumPathSubdivisionCount
        )
    }

}

/// Deterministic input-to-dab generator for one captured stroke configuration.
struct BrushComponentStrokeGenerator: Equatable, Sendable {
    public let program: BrushProgram
    let component: BrushComponentProgram
    public let nominalDiameter: Float
    public let color: InkColor
    public let seed: UInt64

    public private(set) var currentSpacing: Float
    public private(set) var emittedDabCount: UInt64

    private var stabilizer: StrokeStabilizer
    private var directionTracker: BrushDirectionTracker
    private var cornerEmitter: BrushCornerEmitter?
    private var path: CentripetalCatmullRomPathInterpolator
    private var random: BrushRandom
    private var isActive: Bool
    private var hasAttributedPath: Bool
    private var heldDirectionalBegin: InterpolatedStrokeSample?
    private var nextCornerSequence: UInt64
    private var timedEmitter: TimedStrokeEmitter?
    private var authoritativeEmissionMerger: StrokeEmissionMerger
    private var predictionEmissionMerger: StrokeEmissionMerger
    private var strokeStartTimestamp: TimeInterval?
    private var processedPathDistance: Float
    private var distanceUntilNext: Float
    private var lastDirection: Float
    private var lastEmittedSourcePosition: WorldPoint?
    private let footprintEnvelope: BrushStrokeFootprintEnvelope

    init(
        program: BrushProgram,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64
    ) {
        self.init(
            program: program,
            component: program.primaryComponent,
            nominalDiameter: nominalDiameter,
            color: color,
            seed: seed
        )
    }

    init(
        program rootProgram: BrushProgram,
        component: BrushComponentProgram,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64,
        randomNamespaceOrdinal: UInt8? = nil
    ) {
        precondition(
            nominalDiameter.isFinite && nominalDiameter > 0,
            "Nominal brush diameter must be finite and positive"
        )
        let effectiveSeed: UInt64
        switch rootProgram.definition.seedPolicy {
        case .perStroke:
            effectiveSeed = seed
        case let .fixed(value):
            effectiveSeed = value
        }
        precondition(effectiveSeed != 0, "Brush stroke seed must be nonzero")
        let componentSeed = BrushComponentRandomNamespace.seed(
            strokeSeed: effectiveSeed,
            componentOrdinal:
                randomNamespaceOrdinal ?? component.definition.ordinal
        )
        let spacing = Self.initialSpacing(
            component: component,
            nominalDiameter: nominalDiameter
        )
        program = rootProgram
        self.component = component
        self.nominalDiameter = nominalDiameter
        self.color = color
        self.seed = componentSeed
        currentSpacing = spacing
        emittedDabCount = 0
        stabilizer = Self.makeStabilizer(component: component)
        directionTracker = BrushDirectionTracker()
        cornerEmitter = Self.makeCornerEmitter(component: component)
        path = Self.makePath(component: component, spacing: spacing)
        random = BrushRandom(seed: componentSeed)
        isActive = false
        hasAttributedPath = false
        heldDirectionalBegin = nil
        nextCornerSequence = 0
        timedEmitter = Self.makeTimedEmitter(component: component)
        authoritativeEmissionMerger = StrokeEmissionMerger(
            provenance: .authoritative
        )
        predictionEmissionMerger = StrokeEmissionMerger(
            provenance: .prediction
        )
        strokeStartTimestamp = nil
        processedPathDistance = 0
        distanceUntilNext = spacing
        lastDirection = 0
        lastEmittedSourcePosition = nil
        footprintEnvelope = BrushStrokeFootprintEnvelope.compile(
            program: rootProgram,
            component: component,
            nominalDiameter: nominalDiameter
        )
    }

    public static func == (
        lhs: borrowing BrushComponentStrokeGenerator,
        rhs: borrowing BrushComponentStrokeGenerator
    ) -> Bool {
        configurationEqual(lhs, rhs)
            && stabilizationStateEqual(lhs, rhs)
            && directionStateEqual(lhs, rhs)
            && pathStateEqual(lhs, rhs)
            && emissionStateEqual(lhs, rhs)
    }

    @inline(never)
    private static func configurationEqual(
        _ lhs: borrowing BrushComponentStrokeGenerator,
        _ rhs: borrowing BrushComponentStrokeGenerator
    ) -> Bool {
        lhs.program == rhs.program
            && lhs.component == rhs.component
            && lhs.nominalDiameter == rhs.nominalDiameter
            && lhs.color == rhs.color
            && lhs.seed == rhs.seed
            && lhs.footprintEnvelope == rhs.footprintEnvelope
    }

    @inline(never)
    private static func stabilizationStateEqual(
        _ lhs: borrowing BrushComponentStrokeGenerator,
        _ rhs: borrowing BrushComponentStrokeGenerator
    ) -> Bool {
        lhs.stabilizer == rhs.stabilizer
    }

    @inline(never)
    private static func directionStateEqual(
        _ lhs: borrowing BrushComponentStrokeGenerator,
        _ rhs: borrowing BrushComponentStrokeGenerator
    ) -> Bool {
        lhs.directionTracker == rhs.directionTracker
            && lhs.cornerEmitter == rhs.cornerEmitter
            && lhs.heldDirectionalBegin == rhs.heldDirectionalBegin
            && lhs.nextCornerSequence == rhs.nextCornerSequence
            && lhs.lastDirection == rhs.lastDirection
    }

    @inline(never)
    private static func pathStateEqual(
        _ lhs: borrowing BrushComponentStrokeGenerator,
        _ rhs: borrowing BrushComponentStrokeGenerator
    ) -> Bool {
        lhs.path == rhs.path
            && lhs.hasAttributedPath == rhs.hasAttributedPath
            && lhs.processedPathDistance == rhs.processedPathDistance
            && lhs.lastEmittedSourcePosition
                == rhs.lastEmittedSourcePosition
    }

    @inline(never)
    private static func emissionStateEqual(
        _ lhs: borrowing BrushComponentStrokeGenerator,
        _ rhs: borrowing BrushComponentStrokeGenerator
    ) -> Bool {
        lhs.currentSpacing == rhs.currentSpacing
            && lhs.emittedDabCount == rhs.emittedDabCount
            && lhs.random == rhs.random
            && lhs.isActive == rhs.isActive
            && lhs.timedEmitter == rhs.timedEmitter
            && lhs.authoritativeEmissionMerger
                == rhs.authoritativeEmissionMerger
            && lhs.predictionEmissionMerger == rhs.predictionEmissionMerger
            && lhs.strokeStartTimestamp == rhs.strokeStartTimestamp
            && lhs.distanceUntilNext == rhs.distanceUntilNext
    }

    public mutating func cancel() {
        resetRuntimeState()
    }

    private mutating func stageCTimedCursor(
        to sample: InterpolatedStrokeSample,
        sourceDistance: Double,
        direction: Float,
        isPredicted: Bool
    ) throws -> TimedStrokeEmissionCursor? {
        guard stageCUsesTimedEmission, var emitter = timedEmitter else {
            return nil
        }
        let sample = stageCSample(sample, isPredicted: isPredicted)
        let point = TimedStrokePoint(
            sample: sample,
            sourceDistance: sourceDistance,
            direction: direction
        )
        let cursor = isPredicted
            ? try emitter.prediction(to: point)
            : try emitter.advance(to: point)
        timedEmitter = emitter
        return cursor
    }

    private mutating func initializeTimedEmission(
        at attributed: InterpolatedStrokeSample
    ) throws {
        guard var emitter = timedEmitter,
              attributed.kind == .actual || attributed.kind == .coalesced
        else { return }
        _ = try emitter.begin(at: TimedStrokePoint(
            sample: attributed,
            sourceDistance: 0,
            direction: stageCStationaryDirection
        ))
        timedEmitter = emitter
    }

    mutating func offerCandidate(
        _ candidate: StrokeEmissionCandidate,
        emit: (DabAttributes) throws -> EmissionSinkDecision
    ) throws -> Bool {
        try Self.preflightLogicalIdentity(
            emittedDabCount: emittedDabCount
        )
        var proposedRandom = random
        let dab = evaluatedDab(
            sample: candidate.sample,
            traveledDistance: Float(candidate.sourceDistance),
            direction: candidate.direction,
            totalDistance: nil,
            isPredicted: candidate.provenance == .prediction,
            ordinal: emittedDabCount,
            randomValues: proposedRandom.nextValues()
        )
        guard try emit(dab) == .accept else { return false }
        random = proposedRandom
        emittedDabCount &+= 1
        installAcceptedCandidate(candidate, dab: dab)
        return true
    }

    static func preflightLogicalIdentity(
        emittedDabCount: UInt64
    ) throws {
        guard emittedDabCount != .max else {
            throw BrushStrokeGeneratorEmissionError.logicalOrdinalOverflow
        }
    }

    private mutating func installAcceptedCandidate(
        _ candidate: StrokeEmissionCandidate,
        dab: DabAttributes
    ) {
        currentSpacing = dab.spacing
        switch candidate.kind {
        case .corner, .time:
            distanceUntilNext = min(distanceUntilNext, dab.spacing)
        case .begin, .distance:
            distanceUntilNext = dab.spacing
        case .finish:
            break
        }
        if candidate.kind != .corner {
            lastEmittedSourcePosition = candidate.position
        }
    }

    private func stageCCandidate(
        sample: InterpolatedStrokeSample,
        sourceDistance: Double,
        direction: Float,
        kind: StrokeEmissionCandidateKind,
        isPredicted: Bool,
        cornerSequence: UInt64 = 0
    ) throws -> StrokeEmissionCandidate {
        let sample = stageCSample(sample, isPredicted: isPredicted)
        let relativeTime = max(
            0,
            sample.timestamp - (strokeStartTimestamp ?? sample.timestamp)
        )
        return StrokeEmissionCandidate(
            sample: sample,
            relativeStrokeTime: relativeTime,
            sourceDistance: sourceDistance,
            direction: direction,
            provenance: isPredicted ? .prediction : .authoritative,
            timeKey: try Self.canonicalKey(
                relativeTime,
                scale: 1_000_000_000
            ),
            distanceKey: try Self.canonicalKey(
                sourceDistance,
                scale: 1_000_000
            ),
            kind: kind,
            cornerSequence: cornerSequence
        )
    }

    private func stageCSample(
        _ sample: InterpolatedStrokeSample,
        isPredicted: Bool
    ) -> InterpolatedStrokeSample {
        guard isPredicted, sample.kind != .predicted else { return sample }
        return InterpolatedStrokeSample(
            position: sample.position,
            pressure: sample.pressure,
            timestamp: sample.timestamp,
            altitude: sample.altitude,
            azimuth: sample.azimuth,
            roll: sample.roll,
            velocity: sample.velocity,
            artisticVelocity: sample.artisticVelocity,
            phase: sample.phase,
            source: sample.source,
            kind: .predicted,
            capabilities: sample.capabilities,
            tangentialPressure: sample.tangentialPressure,
            deviceIdentifier: sample.deviceIdentifier,
            estimationUpdateIndex: sample.estimationUpdateIndex,
            estimatedProperties: sample.estimatedProperties,
            estimatedPropertiesExpectingUpdates:
                sample.estimatedPropertiesExpectingUpdates
        )
    }

    private var stageCEmissionMode: BrushEmissionMode {
        component.stageC.emission.mode
    }

    private var stageCUsesDistanceEmission: Bool {
        stageCEmissionMode != .time
    }

    private var stageCUsesTimedEmission: Bool {
        stageCEmissionMode != .distance
    }

    private mutating func processStageCStabilizer(
        _ sample: WorldStrokeSample
    ) -> WorldStrokeSample? {
        do {
            return try stabilizer.processV2(sample)
        } catch {
            preconditionFailure(
                "Compiled Stage C stabilizer must remain compatible: \(error)"
            )
        }
    }

    private var stageCStationaryDirection: Float {
        component.stageC.direction.stationaryDirection
    }

    private func validateCornerCanonicalDomain(
        for sample: WorldStrokeSample
    ) throws {
        guard cornerEmitter != nil else { return }
        let relativeTime = max(
            0,
            sample.timestamp - (strokeStartTimestamp ?? sample.timestamp)
        )
        _ = try Self.canonicalKey(relativeTime, scale: 1_000_000_000)
        _ = try Self.canonicalKey(
            Double(processedPathDistance),
            scale: 1_000_000
        )
    }

    static func canonicalKey(
        _ value: Double,
        scale: Double
    ) throws -> Int64 {
        let scaled = value * scale
        guard scaled.isFinite,
              let key = Int64(exactly: scaled.rounded(.toNearestOrEven))
        else {
            throw BrushCornerEmitterError.canonicalKeyOverflow
        }
        return key
    }

    private mutating func nextDab(
        sample: InterpolatedStrokeSample,
        traveledDistance: Float,
        direction: Float,
        totalDistance: Float?,
        isPredicted: Bool
    ) -> DabAttributes {
        let dab = evaluatedDab(
            sample: sample,
            traveledDistance: traveledDistance,
            direction: direction,
            totalDistance: totalDistance,
            isPredicted: isPredicted,
            ordinal: emittedDabCount,
            randomValues: random.nextValues()
        )
        emittedDabCount &+= 1
        return dab
    }

    private func evaluatedDab(
        sample: InterpolatedStrokeSample,
        traveledDistance: Float,
        direction: Float,
        totalDistance: Float?,
        isPredicted: Bool,
        ordinal: UInt64,
        randomValues: BrushRandomValues
    ) -> DabAttributes {
        let start = strokeStartTimestamp ?? sample.timestamp
        let age = max(0, Float(sample.timestamp - start))
        let context = BrushStrokeContext(
            nominalDiameter: nominalDiameter,
            color: color,
            direction: direction,
            strokeAge: age,
            traveledDistance: traveledDistance,
            totalDistance: totalDistance,
            ordinal: ordinal,
            isPredicted: isPredicted
        )
        return BrushDynamicsEngine().evaluate(
            sample: sample,
            context: context,
            program: program,
            component: component,
            random: randomValues,
            strokeSeed: seed
        )
    }

    private mutating func resetRuntimeState() {
        let spacing = Self.initialSpacing(
            component: component,
            nominalDiameter: nominalDiameter
        )
        currentSpacing = spacing
        emittedDabCount = 0
        stabilizer.reset()
        directionTracker = BrushDirectionTracker()
        cornerEmitter = Self.makeCornerEmitter(component: component)
        path = Self.makePath(component: component, spacing: spacing)
        random = BrushRandom(seed: seed)
        isActive = false
        hasAttributedPath = false
        heldDirectionalBegin = nil
        nextCornerSequence = 0
        timedEmitter = Self.makeTimedEmitter(component: component)
        authoritativeEmissionMerger = StrokeEmissionMerger(
            provenance: .authoritative
        )
        predictionEmissionMerger = StrokeEmissionMerger(
            provenance: .prediction
        )
        strokeStartTimestamp = nil
        processedPathDistance = 0
        distanceUntilNext = spacing
        lastDirection = 0
        lastEmittedSourcePosition = nil
    }

    private static func makeStabilizer(
        component: BrushComponentProgram
    ) -> StrokeStabilizer {
        let stageC = component.stageC
        let mode: StrokeStabilizerMode = switch stageC.stabilization {
        case .none: .none
        case let .weightedWindow(distance):
            .weightedWindow(distance: distance)
        case let .delayed(distance): .delayed(distance: distance)
        }
        do {
            return try StrokeStabilizer(mode: mode)
        } catch {
            preconditionFailure(
                "Compiled Stage C stabilization must be valid: \(error)"
            )
        }
    }

    private static func makeTimedEmitter(
        component: BrushComponentProgram
    ) -> TimedStrokeEmitter? {
        let stageC = component.stageC
        switch stageC.emission.mode {
        case .distance:
            return nil
        case .time, .distanceAndTime:
            guard let timeInterval = stageC.emission.timeInterval else {
                preconditionFailure(
                    "Compiled time emission must retain an interval"
                )
            }
            do {
                return try TimedStrokeEmitter(
                    timeInterval: timeInterval
                )
            } catch {
                preconditionFailure(
                    "Compiled Stage C time interval must remain valid: \(error)"
                )
            }
        }
    }

    private static func makeCornerEmitter(
        component: BrushComponentProgram
    ) -> BrushCornerEmitter? {
        let stageC = component.stageC
        guard stageC.usesTravelDirection else { return nil }
        do {
            return try BrushCornerEmitter(
                maximumAngularStep: stageC.direction.maximumAngularStep
            )
        } catch {
            preconditionFailure(
                "Compiled Stage C direction must be valid: \(error)"
            )
        }
    }

    private static func makePath(
        component: BrushComponentProgram,
        spacing: Float
    ) -> CentripetalCatmullRomPathInterpolator {
        let isRigidDirectionalMarker = component.stageC.usesTravelDirection
            && component.definition.material.edgeTreatment == .markerOverlap
        return CentripetalCatmullRomPathInterpolator(
            maximumSegmentLength: min(0.5, spacing * 0.2),
            minimumSubdivisionEstimate: spacing,
            clampsToSegmentBounds: isRigidDirectionalMarker
        )
    }

    private static func initialSpacing(
        component: BrushComponentProgram,
        nominalDiameter: Float
    ) -> Float {
        let placement = component.definition.placement
        let upperBound = max(
            1,
            min(8, nominalDiameter * placement.maximumSpacingFraction)
        )
        return min(
            upperBound,
            max(1, nominalDiameter * placement.baseSpacingFraction)
        )
    }
}
