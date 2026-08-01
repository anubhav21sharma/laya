import Foundation
import PatternEngine

public enum StrokeRenderCoordinatorError: Error, Equatable, Sendable {
    case invalidLifecycle
    case invalidAuthoritativeSample
    case ordinalDiscontinuity(expected: UInt64, actual: UInt64)
    case transactionAlreadyPrepared
    case preparedEmissionOriginMismatch
    case preparedEmissionAlreadyConsumed
    case preparedEmissionTokenMismatch
    case authoritativeFrameAlreadyPrepared
    case transactionAlreadyReserved
    case transactionTokenOverflow
    case stalePreparedEmission(expectedRevision: UInt64, actualRevision: UInt64)
}

/// Candidate authoritative state. Preparation registers one coordinator-bound
/// transaction; only a successful commit makes the candidate authoritative.
public struct PreparedStrokeCoordinatorEmission: Sendable {
    public var work: [AuthoritativeStrokeWork] { emission.work }

    let emission: StrokeCoordinatorEmission
    fileprivate let coordinatorIdentity: UUID
    fileprivate let token: UInt64
    fileprivate let baseRevision: UInt64
    fileprivate let generator: BrushStrokeGenerator
    fileprivate let inputDeriver: BrushInputDeriver
    fileprivate let commitMetadata: StrokeCommitMetadata
    fileprivate let maximumReturnedDabCount: Int
    fileprivate let hasBegun: Bool
    fileprivate let hasFinished: Bool
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
    private var revision: UInt64 = 0
    private let coordinatorIdentity = UUID()
    private var transactionState = TransactionState.idle
    private var nextTransactionToken: UInt64 = 1

    private enum TransactionState: Equatable, Sendable {
        case idle
        case prepared(token: UInt64, baseRevision: UInt64)
        case reserved(token: UInt64, baseRevision: UInt64)
    }

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

    public mutating func prepareBegin(
        actualSamples: [StrokeSample]
    ) throws -> PreparedStrokeCoordinatorEmission {
        try requireIdleTransaction()
        guard !hasBegun, !hasFinished, !actualSamples.isEmpty,
              actualSamples[0].phase == .began
        else {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        for sample in actualSamples.dropFirst()
        where sample.phase != .moved {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        return try prepare(
            actualSamples,
            firstOperation: .begin,
            hasBegun: true,
            hasFinished: false
        )
    }

    public mutating func prepareAppend(
        actualSamples: [StrokeSample]
    ) throws -> PreparedStrokeCoordinatorEmission {
        try requireIdleTransaction()
        guard hasBegun, !hasFinished else {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        guard !actualSamples.isEmpty else {
            return try registerPreparedTransaction(
                emission: StrokeCoordinatorEmission(
                    work: [],
                    generatedSamples: []
                ),
                generator: generator,
                inputDeriver: inputDeriver,
                commitMetadata: commitMetadata,
                maximumReturnedDabCount: maximumReturnedDabCount,
                hasBegun: hasBegun,
                hasFinished: hasFinished
            )
        }
        guard actualSamples.allSatisfy({ $0.phase == .moved }) else {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        return try prepare(
            actualSamples,
            firstOperation: .append,
            hasBegun: true,
            hasFinished: false
        )
    }

    public mutating func prepareFinish(
        actualSamples: [StrokeSample]
    ) throws -> PreparedStrokeCoordinatorEmission {
        try requireIdleTransaction()
        guard hasBegun, !hasFinished, !actualSamples.isEmpty,
              actualSamples.last?.phase == .ended
        else {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        for sample in actualSamples.dropLast()
        where sample.phase != .moved {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        return try prepare(
            actualSamples,
            firstOperation: actualSamples.count == 1 ? .finish : .append,
            hasBegun: true,
            hasFinished: true
        )
    }

    public mutating func commit(
        _ prepared: PreparedStrokeCoordinatorEmission
    ) throws {
        try reserveForDownstreamAcceptance(prepared)
        finalizeAfterDownstreamAcceptance(prepared)
    }

    /// Performs every check that can reject a coordinator candidate. Once this
    /// succeeds, the renderer may transfer the work and then call the
    /// nonthrowing finalizer.
    mutating func reserveForDownstreamAcceptance(
        _ prepared: PreparedStrokeCoordinatorEmission
    ) throws {
        try validatePreparedTransaction(prepared, expectedReservation: false)
        guard !authoritativeQueue.hasPreparedFrame else {
            throw StrokeRenderCoordinatorError.authoritativeFrameAlreadyPrepared
        }
        try authoritativeQueue.preflightAppend(prepared.work)
        transactionState = .reserved(
            token: prepared.token,
            baseRevision: prepared.baseRevision
        )
    }

    /// Finalizes a prevalidated candidate after downstream ownership has been
    /// accepted. No fallible work is permitted beyond this boundary.
    mutating func finalizeAfterDownstreamAcceptance(
        _ prepared: PreparedStrokeCoordinatorEmission
    ) {
        precondition(
            prepared.coordinatorIdentity == coordinatorIdentity,
            "Cannot finalize a foreign stroke coordinator transaction"
        )
        precondition(
            transactionState == .reserved(
                token: prepared.token,
                baseRevision: prepared.baseRevision
            ) && prepared.baseRevision == revision,
            "Stroke coordinator transaction was not reserved"
        )
        authoritativeQueue.appendPrevalidated(prepared.work)
        generator = prepared.generator
        inputDeriver = prepared.inputDeriver
        var currentMetadata = prepared.commitMetadata
        currentMetadata.submittedDabCount = authoritativeQueue.submittedCount
        commitMetadata = currentMetadata
        maximumReturnedDabCount = prepared.maximumReturnedDabCount
        hasBegun = prepared.hasBegun
        hasFinished = prepared.hasFinished
        transactionState = .idle
        revision &+= 1
    }

    public mutating func abandon(
        _ prepared: PreparedStrokeCoordinatorEmission
    ) throws {
        try validatePreparedTransaction(prepared, expectedReservation: nil)
        transactionState = .idle
    }

    public mutating func prepareAuthoritativeFrame(
        maximumDabs: Int
    ) throws -> PreparedAuthoritativeStrokeFrame? {
        if case .reserved = transactionState {
            throw StrokeRenderCoordinatorError.transactionAlreadyReserved
        }
        return try authoritativeQueue.prepare(maximumCount: maximumDabs)
    }

    public mutating func markAuthoritativeFrameSubmitted(
        _ frame: PreparedAuthoritativeStrokeFrame
    ) throws {
        if case .reserved = transactionState {
            throw StrokeRenderCoordinatorError.transactionAlreadyReserved
        }
        try authoritativeQueue.retire(frame)
        commitMetadata.submittedDabCount =
            authoritativeQueue.submittedCount
        invalidatePreparedTransaction()
        revision &+= 1
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
        transactionState = .idle
        revision &+= 1
    }

    private enum Operation {
        case begin
        case append
        case finish
    }

    private mutating func prepare(
        _ samples: [StrokeSample],
        firstOperation: Operation,
        hasBegun candidateHasBegun: Bool,
        hasFinished candidateHasFinished: Bool
    ) throws -> PreparedStrokeCoordinatorEmission {
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
        var candidateMetadata = commitMetadata
        candidateMetadata.inputSampleCount += UInt64(samples.count)
        candidateMetadata.emittedDabCount += UInt64(work.count)
        candidateMetadata.lastEmittedOrdinal =
            work.last?.ordinal ?? candidateMetadata.lastEmittedOrdinal
        return try registerPreparedTransaction(
            emission: StrokeCoordinatorEmission(
                work: work,
                generatedSamples: generatedSamples
            ),
            generator: candidateGenerator,
            inputDeriver: candidateDeriver,
            commitMetadata: candidateMetadata,
            maximumReturnedDabCount: max(
                maximumReturnedDabCount,
                work.count
            ),
            hasBegun: candidateHasBegun,
            hasFinished: candidateHasFinished
        )
    }

    private func requireIdleTransaction() throws {
        guard case .idle = transactionState else {
            throw StrokeRenderCoordinatorError.transactionAlreadyPrepared
        }
    }

    private mutating func registerPreparedTransaction(
        emission: StrokeCoordinatorEmission,
        generator: BrushStrokeGenerator,
        inputDeriver: BrushInputDeriver,
        commitMetadata: StrokeCommitMetadata,
        maximumReturnedDabCount: Int,
        hasBegun: Bool,
        hasFinished: Bool
    ) throws -> PreparedStrokeCoordinatorEmission {
        precondition(
            transactionState == .idle,
            "A stroke coordinator may issue only one transaction at a time"
        )
        let token = nextTransactionToken
        let (successor, overflow) = token.addingReportingOverflow(1)
        guard !overflow else {
            throw StrokeRenderCoordinatorError.transactionTokenOverflow
        }
        nextTransactionToken = successor
        transactionState = .prepared(token: token, baseRevision: revision)
        return PreparedStrokeCoordinatorEmission(
            emission: emission,
            coordinatorIdentity: coordinatorIdentity,
            token: token,
            baseRevision: revision,
            generator: generator,
            inputDeriver: inputDeriver,
            commitMetadata: commitMetadata,
            maximumReturnedDabCount: maximumReturnedDabCount,
            hasBegun: hasBegun,
            hasFinished: hasFinished
        )
    }

    private func validatePreparedTransaction(
        _ prepared: PreparedStrokeCoordinatorEmission,
        expectedReservation: Bool?
    ) throws {
        guard prepared.coordinatorIdentity == coordinatorIdentity else {
            throw StrokeRenderCoordinatorError.preparedEmissionOriginMismatch
        }
        guard prepared.baseRevision == revision else {
            throw StrokeRenderCoordinatorError.stalePreparedEmission(
                expectedRevision: revision,
                actualRevision: prepared.baseRevision
            )
        }
        switch transactionState {
        case .idle:
            throw StrokeRenderCoordinatorError.preparedEmissionAlreadyConsumed
        case let .prepared(token, baseRevision):
            guard expectedReservation != true else {
                throw StrokeRenderCoordinatorError.preparedEmissionTokenMismatch
            }
            guard token == prepared.token,
                  baseRevision == prepared.baseRevision
            else {
                throw StrokeRenderCoordinatorError.preparedEmissionTokenMismatch
            }
        case let .reserved(token, baseRevision):
            guard expectedReservation != false else {
                throw StrokeRenderCoordinatorError.preparedEmissionTokenMismatch
            }
            guard token == prepared.token,
                  baseRevision == prepared.baseRevision
            else {
                throw StrokeRenderCoordinatorError.preparedEmissionTokenMismatch
            }
        }
    }

    private mutating func invalidatePreparedTransaction() {
        if case .prepared = transactionState {
            transactionState = .idle
        }
    }
}
