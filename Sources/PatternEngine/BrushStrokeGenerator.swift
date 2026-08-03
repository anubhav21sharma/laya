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
    private var directionTracker: BrushDirectionTracker
    private var cornerEmitter: BrushCornerEmitter?
    private var path: CentripetalCatmullRomPathInterpolator
    private var random: BrushRandom
    private var isActive: Bool
    private var hasAttributedPath: Bool
    private var heldDirectionalBegin: InterpolatedStrokeSample?
    private var nextCornerSequence: UInt64
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
        stabilizer = Self.makeStabilizer(program: program)
        directionTracker = BrushDirectionTracker()
        cornerEmitter = Self.makeCornerEmitter(program: program)
        path = CentripetalCatmullRomPathInterpolator(
            maximumSegmentLength: min(0.5, spacing * 0.2),
            minimumSubdivisionEstimate: spacing
        )
        random = BrushRandom(seed: effectiveSeed)
        isActive = false
        hasAttributedPath = false
        heldDirectionalBegin = nil
        nextCornerSequence = 0
        strokeStartTimestamp = nil
        processedPathDistance = 0
        distanceUntilNext = spacing
        lastDirection = 0
        lastEmittedSourcePosition = nil
    }

    public static func == (
        lhs: borrowing BrushStrokeGenerator,
        rhs: borrowing BrushStrokeGenerator
    ) -> Bool {
        configurationEqual(lhs, rhs)
            && stabilizationStateEqual(lhs, rhs)
            && directionStateEqual(lhs, rhs)
            && pathStateEqual(lhs, rhs)
            && emissionStateEqual(lhs, rhs)
    }

    @inline(never)
    private static func configurationEqual(
        _ lhs: borrowing BrushStrokeGenerator,
        _ rhs: borrowing BrushStrokeGenerator
    ) -> Bool {
        lhs.program == rhs.program
            && lhs.nominalDiameter == rhs.nominalDiameter
            && lhs.color == rhs.color
            && lhs.seed == rhs.seed
    }

    @inline(never)
    private static func stabilizationStateEqual(
        _ lhs: borrowing BrushStrokeGenerator,
        _ rhs: borrowing BrushStrokeGenerator
    ) -> Bool {
        lhs.stabilizer == rhs.stabilizer
    }

    @inline(never)
    private static func directionStateEqual(
        _ lhs: borrowing BrushStrokeGenerator,
        _ rhs: borrowing BrushStrokeGenerator
    ) -> Bool {
        lhs.directionTracker == rhs.directionTracker
            && lhs.cornerEmitter == rhs.cornerEmitter
            && lhs.heldDirectionalBegin == rhs.heldDirectionalBegin
            && lhs.nextCornerSequence == rhs.nextCornerSequence
            && lhs.lastDirection == rhs.lastDirection
    }

    @inline(never)
    private static func pathStateEqual(
        _ lhs: borrowing BrushStrokeGenerator,
        _ rhs: borrowing BrushStrokeGenerator
    ) -> Bool {
        lhs.path == rhs.path
            && lhs.hasAttributedPath == rhs.hasAttributedPath
            && lhs.processedPathDistance == rhs.processedPathDistance
            && lhs.lastEmittedSourcePosition
                == rhs.lastEmittedSourcePosition
    }

    @inline(never)
    private static func emissionStateEqual(
        _ lhs: borrowing BrushStrokeGenerator,
        _ rhs: borrowing BrushStrokeGenerator
    ) -> Bool {
        lhs.currentSpacing == rhs.currentSpacing
            && lhs.emittedDabCount == rhs.emittedDabCount
            && lhs.random == rhs.random
            && lhs.isActive == rhs.isActive
            && lhs.strokeStartTimestamp == rhs.strokeStartTimestamp
            && lhs.distanceUntilNext == rhs.distanceUntilNext
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
        emit: (DabAttributes) -> Void
    ) {
        do {
            try appendTransaction(sample, emit: emit)
        } catch {
            preconditionFailure(
                "Unbounded stroke generation exceeded a typed bound: \(error)"
            )
        }
    }

    public mutating func append(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) throws {
        try appendTransaction(sample, emit: emit)
    }

    private mutating func appendTransaction(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) throws {
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
        emit: (DabAttributes) -> Void
    ) {
        do {
            try finishTransaction(sample, emit: emit)
        } catch {
            preconditionFailure(
                "Unbounded stroke generation exceeded a typed bound: \(error)"
            )
        }
    }

    public mutating func finish(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) throws {
        try finishTransaction(sample, emit: emit)
    }

    private mutating func finishTransaction(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) throws {
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
        let emission = try collectCandidateEmission(
            sample,
            operation: operation
        )
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
        let emission = try collectCandidateEmission(
            sample,
            operation: operation
        )
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
    ) throws -> (
        candidate: BrushStrokeGenerator,
        startingOrdinal: UInt64,
        dabs: [LogicalDab]
    ) {
        let startingOrdinal: UInt64 = operation == .begin
            ? 0
            : emittedDabCount
        var candidate = self
        var dabs: [LogicalDab] = []
        let collect: (DabAttributes) throws -> Void = { dabs.append($0) }
        switch operation {
        case .begin:
            candidate.begin(sample) { dabs.append($0) }
        case .append:
            try candidate.append(sample, emit: collect)
        case .finish:
            try candidate.finish(sample, emit: collect)
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
        guard program.stageC != nil else {
            let stabilized = stabilizer.process(sample)
            let attributed = InterpolatedStrokeSample(stabilized)
            _ = path.begin(at: attributed)
            hasAttributedPath = true
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
            return
        }
        guard let stabilized = processStageCStabilizer(sample) else {
            return
        }
        let attributed = InterpolatedStrokeSample(stabilized)
        try beginStageCAttributedPath(attributed, emit: emit)
        if sample.phase == .ended {
            try resolveHeldDirectionalBegin(
                direction: stageCStationaryDirection,
                isPredicted: sample.kind == .predicted,
                emit: emit
            )
        }
    }

    private mutating func appendActive(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) throws {
        let isPredicted = sample.kind == .predicted
        guard program.stageC != nil else {
            let stabilized = stabilizer.process(sample)
            let attributed = InterpolatedStrokeSample(stabilized)
            var updatedPath = path
            try updatedPath.append(attributed) { segment in
                try consumeLegacy(
                    segment,
                    isPredicted: isPredicted,
                    emit: emit
                )
            }
            path = updatedPath
            return
        }
        guard let stabilized = processStageCStabilizer(sample) else {
            return
        }
        let attributed = InterpolatedStrokeSample(stabilized)
        guard hasAttributedPath else {
            try beginStageCAttributedPath(attributed, emit: emit)
            return
        }
        var updatedPath = path
        try updatedPath.append(attributed) { segment in
            try consumeStageC(
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
        guard program.stageC != nil else {
            let stabilized = stabilizer.process(sample)
            let attributed = InterpolatedStrokeSample(stabilized)
            var updatedPath = path
            try updatedPath.append(
                attributed,
                maximumSubdivisionCount: maximumPathSubdivisionCount
            ) { segment in
                try consumeLegacy(
                    segment,
                    isPredicted: isPredicted,
                    emit: emit
                )
            }
            path = updatedPath
            return
        }
        guard let stabilized = processStageCStabilizer(sample) else {
            return
        }
        let attributed = InterpolatedStrokeSample(stabilized)
        guard hasAttributedPath else {
            try beginStageCAttributedPath(attributed, emit: emit)
            return
        }
        var updatedPath = path
        try updatedPath.append(
            attributed,
            maximumSubdivisionCount: maximumPathSubdivisionCount
        ) { segment in
            try consumeStageC(
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
        guard program.stageC != nil else {
            let stabilized = stabilizer.process(sample)
            let attributed = InterpolatedStrokeSample(stabilized)
            var updatedPath = path
            let outcome = try updatedPath.appendBoundedPrefix(
                attributed,
                maximumSubdivisionCount: maximumPathSubdivisionCount
            ) { segment in
                try consumeLegacy(
                    segment,
                    isPredicted: true,
                    emit: emit
                )
            }
            guard outcome == .completed else { return .truncated }
            path = updatedPath
            return .completed
        }
        guard let stabilized = processStageCStabilizer(sample) else {
            return .completed
        }
        let attributed = InterpolatedStrokeSample(stabilized)
        guard hasAttributedPath else {
            try beginStageCAttributedPath(attributed, emit: emit)
            return .completed
        }
        var updatedPath = path
        let outcome = try updatedPath.appendBoundedPrefix(
            attributed,
            maximumSubdivisionCount: maximumPathSubdivisionCount
        ) { segment in
            try consumeStageC(
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
    ) throws {
        let isPredicted = sample.kind == .predicted
        guard program.stageC != nil else {
            let terminalSample = program.termination
                .usesLegacySchemaV1EndpointFiltering
                ? stabilizer.process(sample)
                : sample
            let attributed = InterpolatedStrokeSample(terminalSample)
            var updatedPath = path
            let endpoint = try updatedPath.finish(at: attributed) { segment in
                try consumeLegacy(
                    segment,
                    isPredicted: isPredicted,
                    emit: emit
                )
            }
            path = updatedPath
            try emitTerminalDabIfNeeded(
                endpoint,
                isPredicted: isPredicted,
                emit: emit
            )
            return
        }
        guard let terminalSample = processStageCStabilizer(sample) else {
            return
        }
        let attributed = InterpolatedStrokeSample(terminalSample)
        guard hasAttributedPath else {
            try beginStageCAttributedPath(attributed, emit: emit)
            try resolveHeldDirectionalBegin(
                direction: stageCStationaryDirection,
                isPredicted: isPredicted,
                emit: emit
            )
            return
        }
        if case .weightedWindow = program.stageC?.stabilization {
            try emitWeightedEndpointCorrection(
                attributed,
                isPredicted: isPredicted,
                emit: emit
            )
            return
        }
        var updatedPath = path
        let endpoint = try updatedPath.finish(at: attributed) { segment in
            try consumeStageC(
                segment,
                isPredicted: isPredicted,
                emit: emit
            )
        }
        path = updatedPath
        try resolveHeldDirectionalBegin(
            direction: stageCStationaryDirection,
            isPredicted: isPredicted,
            emit: emit
        )
        try emitTerminalDabIfNeeded(
            endpoint,
            isPredicted: isPredicted,
            emit: emit
        )
    }

    private mutating func finishActive(
        _ sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int,
        emit: (DabAttributes) throws -> Void
    ) throws {
        let isPredicted = sample.kind == .predicted
        guard program.stageC != nil else {
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
                try consumeLegacy(
                    segment,
                    isPredicted: isPredicted,
                    emit: emit
                )
            }
            path = updatedPath
            try emitTerminalDabIfNeeded(
                endpoint,
                isPredicted: isPredicted,
                emit: emit
            )
            return
        }
        guard let terminalSample = processStageCStabilizer(sample) else {
            return
        }
        let attributed = InterpolatedStrokeSample(terminalSample)
        guard hasAttributedPath else {
            try beginStageCAttributedPath(attributed, emit: emit)
            try resolveHeldDirectionalBegin(
                direction: stageCStationaryDirection,
                isPredicted: isPredicted,
                emit: emit
            )
            return
        }
        if case .weightedWindow = program.stageC?.stabilization {
            try emitWeightedEndpointCorrection(
                attributed,
                isPredicted: isPredicted,
                emit: emit
            )
            return
        }
        var updatedPath = path
        let endpoint = try updatedPath.finish(
            at: attributed,
            maximumSubdivisionCount: maximumPathSubdivisionCount
        ) { segment in
            try consumeStageC(
                segment,
                isPredicted: isPredicted,
                emit: emit
            )
        }
        path = updatedPath

        try resolveHeldDirectionalBegin(
            direction: stageCStationaryDirection,
            isPredicted: isPredicted,
            emit: emit
        )
        try emitTerminalDabIfNeeded(
            endpoint,
            isPredicted: isPredicted,
            emit: emit
        )
    }

    private mutating func finishActivePredictionPrefix(
        _ sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int,
        emit: (DabAttributes) throws -> Void
    ) throws -> StrokePathInterpolationOutcome {
        guard program.stageC != nil else {
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
                try consumeLegacy(
                    segment,
                    isPredicted: true,
                    emit: emit
                )
            }
            guard outcome == .completed else { return .truncated }
            path = updatedPath
            try emitTerminalDabIfNeeded(
                attributed,
                isPredicted: true,
                emit: emit
            )
            return .completed
        }
        guard let terminalSample = processStageCStabilizer(sample) else {
            return .completed
        }
        let attributed = InterpolatedStrokeSample(terminalSample)
        guard hasAttributedPath else {
            try beginStageCAttributedPath(attributed, emit: emit)
            try resolveHeldDirectionalBegin(
                direction: stageCStationaryDirection,
                isPredicted: true,
                emit: emit
            )
            return .completed
        }
        if case .weightedWindow = program.stageC?.stabilization {
            try emitWeightedEndpointCorrection(
                attributed,
                isPredicted: true,
                emit: emit
            )
            return .completed
        }
        var updatedPath = path
        let outcome = try updatedPath.finishBoundedPrefix(
            at: attributed,
            maximumSubdivisionCount: maximumPathSubdivisionCount
        ) { segment in
            try consumeStageC(
                segment,
                isPredicted: true,
                emit: emit
            )
        }
        guard outcome == .completed else { return .truncated }
        path = updatedPath

        try resolveHeldDirectionalBegin(
            direction: stageCStationaryDirection,
            isPredicted: true,
            emit: emit
        )
        try emitTerminalDabIfNeeded(
            attributed,
            isPredicted: true,
            emit: emit
        )
        return .completed
    }

    private mutating func consumeLegacy(
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

    private mutating func consumeStageC(
        _ segment: AttributedStrokePathSegment,
        isPredicted: Bool,
        emit: (DabAttributes) throws -> Void
    ) throws {
        guard segment.length > 0 else { return }
        let update = try directionTracker.update(to: segment.end.position)
        let direction = update.direction ?? lastDirection
        if update.direction != nil {
            try resolveHeldDirectionalBegin(
                direction: direction,
                isPredicted: isPredicted,
                emit: emit
            )
        }
        if let signedTurn = update.signedTurn,
           let cornerEmitter
        {
            try emitCornerFan(
                emitter: cornerEmitter,
                segment: segment,
                endingDirection: direction,
                signedTurn: signedTurn,
                isPredicted: isPredicted,
                emit: emit
            )
        }
        try consumeDistanceSegment(
            segment,
            direction: direction,
            isPredicted: isPredicted,
            emit: emit
        )
        lastDirection = direction
    }

    @inline(never)
    private mutating func emitCornerFan(
        emitter: BrushCornerEmitter,
        segment: AttributedStrokePathSegment,
        endingDirection: Float,
        signedTurn: Float,
        isPredicted: Bool,
        emit: (DabAttributes) throws -> Void
    ) throws {
        let startDirection = endingDirection - signedTurn
        let relativeTime = max(
            0,
            segment.start.timestamp - (strokeStartTimestamp ?? 0)
        )
        let sourceDistance = Double(processedPathDistance)
        let vertex = StrokeEmissionCandidate(
            sample: segment.start,
            relativeStrokeTime: relativeTime,
            sourceDistance: sourceDistance,
            direction: startDirection,
            provenance: isPredicted ? .prediction : .authoritative,
            timeKey: Self.canonicalKey(relativeTime, scale: 1_000_000_000),
            distanceKey: Self.canonicalKey(
                sourceDistance,
                scale: 1_000_000
            ),
            kind: .distance,
            cornerSequence: 0
        )
        var candidates = StrokeEmissionCandidateBuffer()
        try emitter.emit(
            from: startDirection,
            signedTurn: signedTurn,
            vertex: vertex,
            into: &candidates,
            nextCornerSequence: &nextCornerSequence
        )
        for index in 0..<candidates.count {
            let candidate = candidates[index]
            let dab = nextDab(
                sample: candidate.sample,
                traveledDistance: Float(candidate.sourceDistance),
                direction: candidate.direction,
                totalDistance: nil,
                isPredicted: isPredicted
            )
            try emit(dab)
        }
    }

    private mutating func consumeDistanceSegment(
        _ segment: AttributedStrokePathSegment,
        direction: Float,
        isPredicted: Bool,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        let length = segment.length
        guard length > 0 else { return }
        let delta = segment.end.position.simd - segment.start.position.simd
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
                distanceUntilNext = currentSpacing
            }
            remainingLength = length - distanceFromStart
        }

        distanceUntilNext -= remainingLength
        processedPathDistance += length
    }

    private mutating func beginStageCAttributedPath(
        _ attributed: InterpolatedStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        _ = path.begin(at: attributed)
        hasAttributedPath = true
        do {
            try directionTracker.begin(at: attributed.position)
        } catch {
            preconditionFailure(
                "Validated world input must have a finite position: \(error)"
            )
        }
        if program.stageC?.usesTravelDirection == true {
            heldDirectionalBegin = attributed
            return
        }
        let dab = nextDab(
            sample: attributed,
            traveledDistance: 0,
            direction: 0,
            totalDistance: nil,
            isPredicted: attributed.kind == .predicted
        )
        try emit(dab)
        lastEmittedSourcePosition = attributed.position
        currentSpacing = dab.spacing
        distanceUntilNext = dab.spacing
    }

    private mutating func resolveHeldDirectionalBegin(
        direction: Float,
        isPredicted: Bool,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        guard let held = heldDirectionalBegin else { return }
        let dab = nextDab(
            sample: held,
            traveledDistance: 0,
            direction: direction,
            totalDistance: nil,
            isPredicted: isPredicted
        )
        try emit(dab)
        heldDirectionalBegin = nil
        lastEmittedSourcePosition = held.position
        currentSpacing = dab.spacing
        distanceUntilNext = dab.spacing
        lastDirection = direction
    }

    private mutating func emitWeightedEndpointCorrection(
        _ endpoint: InterpolatedStrokeSample,
        isPredicted: Bool,
        emit: (DabAttributes) throws -> Void
    ) throws {
        let update = try directionTracker.update(to: endpoint.position)
        let direction = update.direction ?? lastDirection
        try resolveHeldDirectionalBegin(
            direction: update.direction == nil
                ? stageCStationaryDirection
                : direction,
            isPredicted: isPredicted,
            emit: emit
        )
        lastDirection = update.direction ?? lastDirection
        try emitTerminalDabIfNeeded(
            endpoint,
            isPredicted: isPredicted,
            emit: emit
        )
    }

    private mutating func emitTerminalDabIfNeeded(
        _ endpoint: InterpolatedStrokeSample,
        isPredicted: Bool,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        guard lastEmittedSourcePosition != endpoint.position else { return }
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
        program.stageC?.direction.stationaryDirection ?? 0
    }

    private static func canonicalKey(
        _ value: Double,
        scale: Double
    ) -> Int64 {
        let scaled = (value * scale).rounded(.toNearestOrEven)
        precondition(
            scaled.isFinite
                && scaled >= Double(Int64.min)
                && scaled <= Double(Int64.max),
            "Stage C corner key must fit the canonical domain"
        )
        return Int64(scaled)
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
        stabilizer = Self.makeStabilizer(program: program)
        directionTracker = BrushDirectionTracker()
        cornerEmitter = Self.makeCornerEmitter(program: program)
        path = CentripetalCatmullRomPathInterpolator(
            maximumSegmentLength: min(0.5, spacing * 0.2),
            minimumSubdivisionEstimate: spacing
        )
        random = BrushRandom(seed: seed)
        isActive = false
        hasAttributedPath = false
        heldDirectionalBegin = nil
        nextCornerSequence = 0
        strokeStartTimestamp = nil
        processedPathDistance = 0
        distanceUntilNext = spacing
        lastDirection = 0
        lastEmittedSourcePosition = nil
    }

    private static func makeStabilizer(
        program: BrushProgram
    ) -> StrokeStabilizer {
        guard let stageC = program.stageC else {
            return StrokeStabilizer(
                strength: program.definition.stabilization
            )
        }
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

    private static func makeCornerEmitter(
        program: BrushProgram
    ) -> BrushCornerEmitter? {
        guard let stageC = program.stageC,
              stageC.usesTravelDirection
        else {
            return nil
        }
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
