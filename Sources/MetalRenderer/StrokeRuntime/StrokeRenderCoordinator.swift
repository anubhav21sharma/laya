import PatternEngine

public enum StrokeRenderCoordinatorError: Error, Equatable, Sendable {
    case invalidLifecycle
    case invalidAuthoritativeSample
    case ordinalDiscontinuity(expected: UInt64, actual: UInt64)
}

/// Synchronous authoritative core introduced before Task 7 moves its ownership
/// behind an off-main actor and bounded input queue. It retains generator and
/// compact counters only; completed dabs leave memory when their frame retires.
public struct StrokeRenderCoordinator: Sendable {
    public var snapshot: StrokeRenderSnapshot {
        StrokeRenderSnapshot(
            authoritativeQueueDepth: authoritativeQueue.count,
            authoritativeQueueHighWater: authoritativeQueue.highWater,
            authoritativeSubmittedDabCount:
                authoritativeQueue.submittedCount,
            maximumReturnedDabCount: maximumReturnedDabCount,
            retainedCompletedDabCount: 0,
            commitMetadata: commitMetadata
        )
    }

    var generatorSnapshot: BrushStrokeGenerator { generator }
    var inputDeriverSnapshot: BrushInputDeriver { inputDeriver }

    private var generator: BrushStrokeGenerator
    private var inputDeriver = BrushInputDeriver()
    private let viewport: ViewportTransform
    private var authoritativeQueue: AuthoritativeStrokeQueue
    private var commitMetadata = StrokeCommitMetadata()
    private var maximumReturnedDabCount = 0
    private var hasBegun = false
    private var hasFinished = false

    public init(
        program: BrushProgram,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64,
        viewport: ViewportTransform,
        authoritativeCapacity: Int
    ) throws {
        generator = BrushStrokeGenerator(
            program: program,
            nominalDiameter: nominalDiameter,
            color: color,
            seed: seed
        )
        self.viewport = viewport
        authoritativeQueue = try AuthoritativeStrokeQueue(
            capacity: authoritativeCapacity
        )
    }

    public mutating func begin(
        actualSamples: [StrokeSample]
    ) throws -> StrokeCoordinatorEmission {
        guard !hasBegun, !hasFinished, !actualSamples.isEmpty,
              actualSamples[0].phase == .began
        else {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        for sample in actualSamples.dropFirst()
        where sample.phase != .moved {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        let emission = try generate(
            actualSamples,
            firstOperation: .begin
        )
        hasBegun = true
        return emission
    }

    public mutating func append(
        actualSamples: [StrokeSample]
    ) throws -> StrokeCoordinatorEmission {
        guard hasBegun, !hasFinished else {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        guard !actualSamples.isEmpty else {
            return StrokeCoordinatorEmission(work: [], generatedSamples: [])
        }
        guard actualSamples.allSatisfy({ $0.phase == .moved }) else {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        return try generate(actualSamples, firstOperation: .append)
    }

    public mutating func finish(
        actualSamples: [StrokeSample]
    ) throws -> StrokeCoordinatorEmission {
        guard hasBegun, !hasFinished, !actualSamples.isEmpty,
              actualSamples.last?.phase == .ended
        else {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        for sample in actualSamples.dropLast()
        where sample.phase != .moved {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        let emission = try generate(
            actualSamples,
            firstOperation: actualSamples.count == 1 ? .finish : .append
        )
        hasFinished = true
        return emission
    }

    public mutating func prepareAuthoritativeFrame(
        maximumDabs: Int
    ) throws -> PreparedAuthoritativeStrokeFrame? {
        try authoritativeQueue.prepare(maximumCount: maximumDabs)
    }

    public mutating func markAuthoritativeFrameSubmitted(
        _ frame: PreparedAuthoritativeStrokeFrame
    ) throws {
        try authoritativeQueue.retire(frame)
        commitMetadata.submittedDabCount =
            authoritativeQueue.submittedCount
    }

    public mutating func abandonAuthoritativeFrame(
        _ frame: PreparedAuthoritativeStrokeFrame
    ) {
        authoritativeQueue.abandon(frame)
    }

    public mutating func cancel() {
        generator.cancel()
        inputDeriver.reset()
        authoritativeQueue.reset()
        commitMetadata = StrokeCommitMetadata()
        maximumReturnedDabCount = 0
        hasBegun = false
        hasFinished = false
    }

    private enum Operation {
        case begin
        case append
        case finish
    }

    private mutating func generate(
        _ samples: [StrokeSample],
        firstOperation: Operation
    ) throws -> StrokeCoordinatorEmission {
        guard samples.allSatisfy({ sample in
            (sample.kind == .actual || sample.kind == .coalesced)
                && sample.estimationUpdateIndex == nil
                && sample.estimatedProperties.isEmpty
                && sample.estimatedPropertiesExpectingUpdates.isEmpty
        }) else {
            throw StrokeRenderCoordinatorError.invalidAuthoritativeSample
        }

        var candidateGenerator = generator
        var candidateDeriver = inputDeriver
        var generatedSamples: [StrokeCoordinatorGeneratedSample] = []
        generatedSamples.reserveCapacity(samples.count)
        var work: [AuthoritativeStrokeWork] = []

        for (offset, sample) in samples.enumerated() {
            let inputBefore = candidateDeriver
            let worldSample = candidateDeriver.derive(
                sample,
                viewport: viewport
            )
            let generatorBefore = candidateGenerator
            var dabs: [LogicalDab] = []
            let operation: Operation
            if offset == 0 {
                operation = firstOperation
            } else if sample.phase == .ended {
                operation = .finish
            } else {
                operation = .append
            }
            switch operation {
            case .begin:
                candidateGenerator.begin(worldSample) { dabs.append($0) }
            case .append:
                candidateGenerator.append(worldSample) { dabs.append($0) }
            case .finish:
                candidateGenerator.finish(worldSample) { dabs.append($0) }
            }
            for dab in dabs {
                let expected = authoritativeQueue.nextExpectedOrdinal
                    + UInt64(work.count)
                guard dab.ordinal == expected else {
                    throw StrokeRenderCoordinatorError.ordinalDiscontinuity(
                        expected: expected,
                        actual: dab.ordinal
                    )
                }
                work.append(AuthoritativeStrokeWork(dab: dab))
            }
            generatedSamples.append(
                StrokeCoordinatorGeneratedSample(
                    sample: worldSample,
                    dabs: dabs,
                    generatorBefore: generatorBefore,
                    generatorAfter: candidateGenerator,
                    inputDeriverBefore: inputBefore
                )
            )
        }

        try authoritativeQueue.preflightAppend(work)
        try authoritativeQueue.append(work)
        generator = candidateGenerator
        inputDeriver = candidateDeriver
        commitMetadata.inputSampleCount += UInt64(samples.count)
        commitMetadata.emittedDabCount += UInt64(work.count)
        commitMetadata.lastEmittedOrdinal =
            work.last?.ordinal ?? commitMetadata.lastEmittedOrdinal
        maximumReturnedDabCount = max(maximumReturnedDabCount, work.count)
        return StrokeCoordinatorEmission(
            work: work,
            generatedSamples: generatedSamples
        )
    }
}
