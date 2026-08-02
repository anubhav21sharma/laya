import Foundation
import simd

enum BrushStrokeBatchOperation {
    case begin
    case append
    case finish
}

/// Deterministic input-to-dab generator for one captured stroke configuration.
public struct BrushStrokeGenerator: Equatable, Sendable {
    public let program: BrushProgram
    public let nominalDiameter: Float
    public let color: InkColor
    public let seed: UInt64

    public private(set) var currentSpacing: Float
    public private(set) var emittedDabCount: UInt64

    private var stabilizer: StrokeStabilizer
    private var path: CentripetalCatmullRomPathInterpolator
    private var random: BrushRandom
    private var isActive: Bool
    private var strokeStartTimestamp: TimeInterval?
    private var processedPathDistance: Float
    private var distanceUntilNext: Float
    private var lastDirection: Float
    private var lastEmittedSourcePosition: WorldPoint?

    public init(
        program: BrushProgram,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64
    ) {
        precondition(
            nominalDiameter.isFinite && nominalDiameter > 0,
            "Nominal brush diameter must be finite and positive"
        )
        let effectiveSeed: UInt64
        switch program.definition.seedPolicy {
        case .perStroke:
            effectiveSeed = seed
        case let .fixed(value):
            effectiveSeed = value
        }
        precondition(effectiveSeed != 0, "Brush stroke seed must be nonzero")
        let spacing = Self.initialSpacing(
            program: program,
            nominalDiameter: nominalDiameter
        )
        self.program = program
        self.nominalDiameter = nominalDiameter
        self.color = color
        self.seed = effectiveSeed
        currentSpacing = spacing
        emittedDabCount = 0
        stabilizer = StrokeStabilizer(strength: program.definition.stabilization)
        path = CentripetalCatmullRomPathInterpolator(
            maximumSegmentLength: min(0.5, spacing * 0.2),
            minimumSubdivisionEstimate: spacing
        )
        random = BrushRandom(seed: effectiveSeed)
        isActive = false
        strokeStartTimestamp = nil
        processedPathDistance = 0
        distanceUntilNext = spacing
        lastDirection = 0
        lastEmittedSourcePosition = nil
    }

    public mutating func begin(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        precondition(sample.phase == .began)
        var updated = self
        try updated.start(sample, emit: emit)
        self = updated
    }

    public mutating func append(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        precondition(sample.phase == .moved)
        var updated = self
        if updated.isActive {
            try updated.appendActive(sample, emit: emit)
        } else {
            try updated.start(sample, emit: emit)
        }
        self = updated
    }

    /// Bounded renderer entry point. Rejects pathological interpolation work
    /// before sampling a segment, while preserving the transactional generator
    /// state used by the throwing emission path.
    public mutating func append(
        _ sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int,
        emit: (DabAttributes) throws -> Void
    ) throws {
        precondition(maximumPathSubdivisionCount > 0)
        precondition(sample.phase == .moved)
        var updated = self
        if updated.isActive {
            try updated.appendActive(
                sample,
                maximumPathSubdivisionCount:
                    maximumPathSubdivisionCount,
                emit: emit
            )
        } else {
            try updated.start(sample, emit: emit)
        }
        self = updated
    }

    /// Prediction-only bounded entry point. It emits the true path prefix that
    /// fits the interpolation budget, but commits generator state only when
    /// the complete input sample was processed.
    @discardableResult
    public mutating func appendPredictionPrefix(
        _ sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int,
        emit: (DabAttributes) throws -> Void
    ) throws -> StrokePathInterpolationOutcome {
        precondition(maximumPathSubdivisionCount > 0)
        precondition(sample.phase == .moved)
        precondition(sample.kind == .predicted)
        var updated = self
        let outcome: StrokePathInterpolationOutcome
        if updated.isActive {
            outcome = try updated.appendActivePredictionPrefix(
                sample,
                maximumPathSubdivisionCount:
                    maximumPathSubdivisionCount,
                emit: emit
            )
        } else {
            try updated.start(sample, emit: emit)
            outcome = .completed
        }
        if outcome == .completed {
            self = updated
        }
        return outcome
    }

    public mutating func finish(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        precondition(sample.phase == .ended)
        var updated = self
        if !updated.isActive {
            try updated.start(sample, emit: emit)
        } else {
            try updated.finishActive(sample, emit: emit)
        }
        updated.resetRuntimeState()
        self = updated
    }

    /// Bounded renderer entry point matching `append`'s interpolation-work
    /// contract for a terminal sample.
    public mutating func finish(
        _ sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int,
        emit: (DabAttributes) throws -> Void
    ) throws {
        precondition(maximumPathSubdivisionCount > 0)
        precondition(sample.phase == .ended)
        var updated = self
        if !updated.isActive {
            try updated.start(sample, emit: emit)
        } else {
            try updated.finishActive(
                sample,
                maximumPathSubdivisionCount:
                    maximumPathSubdivisionCount,
                emit: emit
            )
        }
        updated.resetRuntimeState()
        self = updated
    }

    /// Prediction-only terminal counterpart to `appendPredictionPrefix`.
    /// Truncation neither commits state nor synthesizes the terminal dab.
    @discardableResult
    public mutating func finishPredictionPrefix(
        _ sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int,
        emit: (DabAttributes) throws -> Void
    ) throws -> StrokePathInterpolationOutcome {
        precondition(maximumPathSubdivisionCount > 0)
        precondition(sample.phase == .ended)
        precondition(sample.kind == .predicted)
        var updated = self
        let outcome: StrokePathInterpolationOutcome
        if !updated.isActive {
            try updated.start(sample, emit: emit)
            outcome = .completed
        } else {
            outcome = try updated.finishActivePredictionPrefix(
                sample,
                maximumPathSubdivisionCount:
                    maximumPathSubdivisionCount,
                emit: emit
            )
        }
        guard outcome == .completed else { return .truncated }
        updated.resetRuntimeState()
        self = updated
        return .completed
    }

    public mutating func cancel() {
        resetRuntimeState()
    }

    public mutating func beginBatches(
        _ sample: WorldStrokeSample
    ) -> [LogicalDabBatch] {
        invariantBatches(sample, operation: .begin)
    }

    public mutating func appendBatches(
        _ sample: WorldStrokeSample
    ) -> [LogicalDabBatch] {
        invariantBatches(sample, operation: .append)
    }

    public mutating func finishBatches(
        _ sample: WorldStrokeSample
    ) -> [LogicalDabBatch] {
        invariantBatches(sample, operation: .finish)
    }

    public mutating func beginBatch(
        _ sample: WorldStrokeSample
    ) throws -> LogicalDabBatch {
        try validatedBatch(sample, operation: .begin)
    }

    public mutating func appendBatch(
        _ sample: WorldStrokeSample
    ) throws -> LogicalDabBatch {
        try validatedBatch(sample, operation: .append)
    }

    public mutating func finishBatch(
        _ sample: WorldStrokeSample
    ) throws -> LogicalDabBatch {
        try validatedBatch(sample, operation: .finish)
    }

    mutating func validatedBatch(
        _ sample: WorldStrokeSample,
        operation: BrushStrokeBatchOperation,
        validator: (
            _ seed: UInt64,
            _ startingOrdinal: UInt64,
            _ isPredicted: Bool,
            _ dabs: [LogicalDab]
        ) throws -> LogicalDabBatch
    ) throws -> LogicalDabBatch {
        let emission = collectCandidateEmission(sample, operation: operation)
        let batch = try validator(
            seed,
            emission.startingOrdinal,
            sample.kind == .predicted,
            emission.dabs
        )
        self = emission.candidate
        return batch
    }

    mutating func validatedBatch(
        _ sample: WorldStrokeSample,
        operation: BrushStrokeBatchOperation
    ) throws -> LogicalDabBatch {
        try validatedBatch(
            sample,
            operation: operation
        ) { seed, startingOrdinal, isPredicted, dabs in
            try LogicalDabBatch(
                seed: seed,
                startingOrdinal: startingOrdinal,
                isPredicted: isPredicted,
                dabs: dabs
            )
        }
    }

    mutating func validatedBatches(
        _ sample: WorldStrokeSample,
        operation: BrushStrokeBatchOperation,
        validator: (
            _ seed: UInt64,
            _ startingOrdinal: UInt64,
            _ isPredicted: Bool,
            _ dabs: [LogicalDab]
        ) throws -> LogicalDabBatch
    ) throws -> [LogicalDabBatch] {
        let emission = collectCandidateEmission(sample, operation: operation)
        let starts: [Int]
        if emission.dabs.isEmpty {
            starts = [0]
        } else {
            starts = Array(
                stride(
                    from: 0,
                    to: emission.dabs.count,
                    by: LogicalDabBatch.maximumDabCount
                )
            )
        }
        var batches: [LogicalDabBatch] = []
        batches.reserveCapacity(starts.count)
        for start in starts {
            let end = min(
                start + LogicalDabBatch.maximumDabCount,
                emission.dabs.count
            )
            let batch = try validator(
                seed,
                emission.startingOrdinal + UInt64(start),
                sample.kind == .predicted,
                Array(emission.dabs[start..<end])
            )
            batches.append(batch)
        }
        self = emission.candidate
        return batches
    }

    private mutating func invariantBatches(
        _ sample: WorldStrokeSample,
        operation: BrushStrokeBatchOperation
    ) -> [LogicalDabBatch] {
        do {
            return try validatedBatches(
                sample,
                operation: operation
            ) { seed, startingOrdinal, isPredicted, dabs in
                try LogicalDabBatch(
                    seed: seed,
                    startingOrdinal: startingOrdinal,
                    isPredicted: isPredicted,
                    dabs: dabs
                )
            }
        } catch {
            preconditionFailure(
                "Generated logical-dab chunks violated an invariant: \(error)"
            )
        }
    }

    private func collectCandidateEmission(
        _ sample: WorldStrokeSample,
        operation: BrushStrokeBatchOperation
    ) -> (
        candidate: BrushStrokeGenerator,
        startingOrdinal: UInt64,
        dabs: [LogicalDab]
    ) {
        let startingOrdinal: UInt64 = operation == .begin
            ? 0
            : emittedDabCount
        var candidate = self
        var dabs: [LogicalDab] = []
        switch operation {
        case .begin:
            candidate.begin(sample) { dabs.append($0) }
        case .append:
            candidate.append(sample) { dabs.append($0) }
        case .finish:
            candidate.finish(sample) { dabs.append($0) }
        }
        return (candidate, startingOrdinal, dabs)
    }

    private mutating func start(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        resetRuntimeState()
        isActive = true
        strokeStartTimestamp = sample.timestamp
        let stabilized = stabilizer.process(sample)
        let attributed = InterpolatedStrokeSample(stabilized)
        _ = path.begin(at: attributed)
        let dab = nextDab(
            sample: attributed,
            traveledDistance: 0,
            direction: 0,
            totalDistance: sample.phase == .ended
                && program.termination.isLegacySchemaV1EndTaper
                ? 0
                : nil,
            isPredicted: sample.kind == .predicted
        )
        try emit(dab)
        lastEmittedSourcePosition = attributed.position
        currentSpacing = dab.spacing
        distanceUntilNext = dab.spacing
    }

    private mutating func appendActive(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        let isPredicted = sample.kind == .predicted
        let stabilized = stabilizer.process(sample)
        let attributed = InterpolatedStrokeSample(stabilized)
        var updatedPath = path
        try updatedPath.append(attributed) { segment in
            try consume(
                segment,
                isPredicted: isPredicted,
                emit: emit
            )
        }
        path = updatedPath
    }

    private mutating func appendActive(
        _ sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int,
        emit: (DabAttributes) throws -> Void
    ) throws {
        let isPredicted = sample.kind == .predicted
        let stabilized = stabilizer.process(sample)
        let attributed = InterpolatedStrokeSample(stabilized)
        var updatedPath = path
        try updatedPath.append(
            attributed,
            maximumSubdivisionCount: maximumPathSubdivisionCount
        ) { segment in
            try consume(
                segment,
                isPredicted: isPredicted,
                emit: emit
            )
        }
        path = updatedPath
    }

    private mutating func appendActivePredictionPrefix(
        _ sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int,
        emit: (DabAttributes) throws -> Void
    ) throws -> StrokePathInterpolationOutcome {
        let stabilized = stabilizer.process(sample)
        let attributed = InterpolatedStrokeSample(stabilized)
        var updatedPath = path
        let outcome = try updatedPath.appendBoundedPrefix(
            attributed,
            maximumSubdivisionCount: maximumPathSubdivisionCount
        ) { segment in
            try consume(
                segment,
                isPredicted: true,
                emit: emit
            )
        }
        guard outcome == .completed else { return .truncated }
        path = updatedPath
        return .completed
    }

    private mutating func finishActive(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        let isPredicted = sample.kind == .predicted
        let terminalSample = program.termination
            .usesLegacySchemaV1EndpointFiltering
            ? stabilizer.process(sample)
            : sample
        let attributed = InterpolatedStrokeSample(terminalSample)
        var updatedPath = path
        let endpoint = try updatedPath.finish(at: attributed) { segment in
            try consume(
                segment,
                isPredicted: isPredicted,
                emit: emit
            )
        }
        path = updatedPath

        if lastEmittedSourcePosition != endpoint.position {
            let dab = nextDab(
                sample: endpoint,
                traveledDistance: processedPathDistance,
                direction: lastDirection,
                totalDistance: nil,
                isPredicted: isPredicted
            )
            try emit(dab)
            lastEmittedSourcePosition = endpoint.position
            currentSpacing = dab.spacing
            distanceUntilNext = dab.spacing
        }
    }

    private mutating func finishActive(
        _ sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int,
        emit: (DabAttributes) throws -> Void
    ) throws {
        let isPredicted = sample.kind == .predicted
        let terminalSample = program.termination
            .usesLegacySchemaV1EndpointFiltering
            ? stabilizer.process(sample)
            : sample
        let attributed = InterpolatedStrokeSample(terminalSample)
        var updatedPath = path
        let endpoint = try updatedPath.finish(
            at: attributed,
            maximumSubdivisionCount: maximumPathSubdivisionCount
        ) { segment in
            try consume(
                segment,
                isPredicted: isPredicted,
                emit: emit
            )
        }
        path = updatedPath

        if lastEmittedSourcePosition != endpoint.position {
            let dab = nextDab(
                sample: endpoint,
                traveledDistance: processedPathDistance,
                direction: lastDirection,
                totalDistance: nil,
                isPredicted: isPredicted
            )
            try emit(dab)
            lastEmittedSourcePosition = endpoint.position
            currentSpacing = dab.spacing
            distanceUntilNext = dab.spacing
        }
    }

    private mutating func finishActivePredictionPrefix(
        _ sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int,
        emit: (DabAttributes) throws -> Void
    ) throws -> StrokePathInterpolationOutcome {
        let terminalSample = program.termination
            .usesLegacySchemaV1EndpointFiltering
            ? stabilizer.process(sample)
            : sample
        let attributed = InterpolatedStrokeSample(terminalSample)
        var updatedPath = path
        let outcome = try updatedPath.finishBoundedPrefix(
            at: attributed,
            maximumSubdivisionCount: maximumPathSubdivisionCount
        ) { segment in
            try consume(
                segment,
                isPredicted: true,
                emit: emit
            )
        }
        guard outcome == .completed else { return .truncated }
        path = updatedPath

        if lastEmittedSourcePosition != attributed.position {
            let dab = nextDab(
                sample: attributed,
                traveledDistance: processedPathDistance,
                direction: lastDirection,
                totalDistance: nil,
                isPredicted: true
            )
            try emit(dab)
            lastEmittedSourcePosition = attributed.position
            currentSpacing = dab.spacing
            distanceUntilNext = dab.spacing
        }
        return .completed
    }

    private mutating func consume(
        _ segment: AttributedStrokePathSegment,
        isPredicted: Bool,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        let length = segment.length
        guard length > 0 else { return }

        let delta = segment.end.position.simd - segment.start.position.simd
        let direction = atan2(delta.y, delta.x)
        var distanceFromStart: Float = 0
        var remainingLength = length

        while remainingLength >= distanceUntilNext {
            distanceFromStart += distanceUntilNext
            let fraction = min(1, distanceFromStart / length)
            let exactPosition = WorldPoint(
                segment.start.position.simd + delta * fraction
            )
            let sample = segment.sample(
                at: fraction,
                exactPosition: exactPosition
            )
            let sourceDistance = processedPathDistance + distanceFromStart
            if lastEmittedSourcePosition != sample.position {
                let dab = nextDab(
                    sample: sample,
                    traveledDistance: sourceDistance,
                    direction: direction,
                    totalDistance: nil,
                    isPredicted: isPredicted
                )
                try emit(dab)
                lastEmittedSourcePosition = sample.position
                currentSpacing = dab.spacing
                distanceUntilNext = dab.spacing
            } else {
                // A rounded path position is not a dab: it must not consume
                // the ordinal or deterministic random channels.
                distanceUntilNext = currentSpacing
            }
            remainingLength = length - distanceFromStart
        }

        distanceUntilNext -= remainingLength
        processedPathDistance += length
        lastDirection = direction
    }

    private mutating func nextDab(
        sample: InterpolatedStrokeSample,
        traveledDistance: Float,
        direction: Float,
        totalDistance: Float?,
        isPredicted: Bool
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
            ordinal: emittedDabCount,
            isPredicted: isPredicted
        )
        let dab = BrushDynamicsEngine().evaluate(
            sample: sample,
            context: context,
            program: program,
            random: random.nextValues(),
            strokeSeed: seed
        )
        emittedDabCount &+= 1
        return dab
    }

    private mutating func resetRuntimeState() {
        let spacing = Self.initialSpacing(
            program: program,
            nominalDiameter: nominalDiameter
        )
        currentSpacing = spacing
        emittedDabCount = 0
        stabilizer = StrokeStabilizer(strength: program.definition.stabilization)
        path = CentripetalCatmullRomPathInterpolator(
            maximumSegmentLength: min(0.5, spacing * 0.2),
            minimumSubdivisionEstimate: spacing
        )
        random = BrushRandom(seed: seed)
        isActive = false
        strokeStartTimestamp = nil
        processedPathDistance = 0
        distanceUntilNext = spacing
        lastDirection = 0
        lastEmittedSourcePosition = nil
    }

    private static func initialSpacing(
        program: BrushProgram,
        nominalDiameter: Float
    ) -> Float {
        let placement = program.definition.placement
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
