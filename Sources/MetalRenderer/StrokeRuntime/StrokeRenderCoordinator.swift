import Foundation
import PatternEngine

public enum StrokeRenderCoordinatorError: Error, Equatable, Sendable {
    case invalidLifecycle
    case invalidAuthoritativeSample
    case settledReplayCheckpointMismatch
    case ordinalDiscontinuity(expected: UInt64, actual: UInt64)
    case transactionAlreadyPrepared
    case preparedEmissionOriginMismatch
    case preparedEmissionAlreadyConsumed
    case preparedEmissionTokenMismatch
    case authoritativeFrameAlreadyPrepared
    case authoritativeQueueNotEmpty
    case transactionAlreadyReserved
    case transactionTokenOverflow
    case stalePreparedEmission(expectedRevision: UInt64, actualRevision: UInt64)
}

/// Candidate authoritative state. Preparation registers one coordinator-bound
/// transaction; only a successful commit makes the candidate authoritative.
public struct PreparedStrokeCoordinatorEmission: Sendable {
    public var work: [AuthoritativeStrokeWork] { emission.work }
    public let predictionProvenanceBoundary:
        PredictionProvenanceBoundary

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

/// Mutable single-owner authoritative core. This deliberately non-Sendable
/// final reference is confined to its owning executor (`GridRenderer` uses the
/// main actor) until Task 7 moves it behind an off-main actor and bounded queue.
/// Aliases share transaction consumption; authoritative work cannot fork by
/// copying a value. Completed dabs leave memory when their frame retires.
public final class StrokeRenderCoordinator {
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
    public var predictionProvenanceBoundary:
        PredictionProvenanceBoundary
    {
        PredictionProvenanceBoundary(
            coordinatorRevision: revision,
            nextAuthoritativeOrdinal: generator.emittedDabCount
        )
    }

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
    private var settledTransferWorkScratch: [AuthoritativeStrokeWork] = []

    private enum TransactionState: Equatable, Sendable {
        case idle
        case prepared(token: UInt64, baseRevision: UInt64)
        case reserved(
            token: UInt64,
            baseRevision: UInt64,
            retireAfterAcceptance: Bool
        )
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
        settledTransferWorkScratch.reserveCapacity(authoritativeCapacity)
    }

    public func prepareBegin(
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

    public func prepareAppend(
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

    public func prepareFinish(
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

    func prepareSettledReplayTransfer(
        _ chunks: [TransientStrokeChunk]
    ) throws -> PreparedStrokeCoordinatorEmission {
        try requireIdleTransaction()
        guard !chunks.isEmpty else {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }

        var candidateGenerator = generator
        var candidateDeriver = inputDeriver
        settledTransferWorkScratch.removeAll(keepingCapacity: true)
        var candidateHasBegun = hasBegun
        var candidateHasFinished = hasFinished
        var expectedOrdinal = authoritativeQueue.nextExpectedOrdinal

        for (index, chunk) in chunks.enumerated() {
            switch chunk.sample.phase {
            case .began:
                guard index == 0, !candidateHasBegun,
                      !candidateHasFinished
                else {
                    throw StrokeRenderCoordinatorError.invalidLifecycle
                }
                candidateHasBegun = true
            case .moved:
                guard candidateHasBegun, !candidateHasFinished else {
                    throw StrokeRenderCoordinatorError.invalidLifecycle
                }
            case .ended:
                guard candidateHasBegun, !candidateHasFinished,
                      index == chunks.index(before: chunks.endIndex)
                else {
                    throw StrokeRenderCoordinatorError.invalidLifecycle
                }
                candidateHasFinished = true
            case .cancelled:
                throw StrokeRenderCoordinatorError.invalidLifecycle
            }
            guard
                chunk.sample.kind == .actual
                    || chunk.sample.kind == .coalesced
            else {
                throw StrokeRenderCoordinatorError.invalidAuthoritativeSample
            }
            guard
                let generatorBefore =
                    chunk.generatorSnapshotBeforeSample,
                let generatorAfter =
                    chunk.generatorSnapshotAfterSample,
                let inputDeriverBefore =
                    chunk.inputDeriverSnapshotBeforeSample
            else {
                throw StrokeRenderCoordinatorError.invalidAuthoritativeSample
            }
            guard generatorBefore == candidateGenerator,
                  inputDeriverBefore == candidateDeriver
            else {
                throw StrokeRenderCoordinatorError
                    .settledReplayCheckpointMismatch
            }
            for transientDab in chunk.dabs {
                let dab = transientDab.attributes
                guard !dab.isPredicted else {
                    throw StrokeRenderCoordinatorError
                        .invalidAuthoritativeSample
                }
                guard dab.ordinal == expectedOrdinal else {
                    throw StrokeRenderCoordinatorError.ordinalDiscontinuity(
                        expected: expectedOrdinal,
                        actual: dab.ordinal
                    )
                }
                let (nextOrdinal, overflow) = expectedOrdinal
                    .addingReportingOverflow(1)
                guard !overflow else {
                    throw AuthoritativeStrokeQueueError.ordinalOverflow
                }
                settledTransferWorkScratch.append(
                    AuthoritativeStrokeWork(dab: dab)
                )
                expectedOrdinal = nextOrdinal
            }
            var replayedGenerator = candidateGenerator
            var replayedDabIndex = 0
            switch chunk.sample.phase {
            case .began:
                try replayedGenerator.begin(chunk.sample) { dab in
                    guard replayedDabIndex < chunk.dabs.count,
                          chunk.dabs[replayedDabIndex].attributes == dab
                    else {
                        throw StrokeRenderCoordinatorError
                            .settledReplayCheckpointMismatch
                    }
                    replayedDabIndex += 1
                }
            case .moved:
                try replayedGenerator.append(chunk.sample) { dab in
                    guard replayedDabIndex < chunk.dabs.count,
                          chunk.dabs[replayedDabIndex].attributes == dab
                    else {
                        throw StrokeRenderCoordinatorError
                            .settledReplayCheckpointMismatch
                    }
                    replayedDabIndex += 1
                }
            case .ended:
                try replayedGenerator.finish(chunk.sample) { dab in
                    guard replayedDabIndex < chunk.dabs.count,
                          chunk.dabs[replayedDabIndex].attributes == dab
                    else {
                        throw StrokeRenderCoordinatorError
                            .settledReplayCheckpointMismatch
                    }
                    replayedDabIndex += 1
                }
            case .cancelled:
                throw StrokeRenderCoordinatorError.invalidLifecycle
            }
            guard replayedDabIndex == chunk.dabs.count,
                  replayedGenerator == generatorAfter
            else {
                throw StrokeRenderCoordinatorError
                    .settledReplayCheckpointMismatch
            }
            let expectedGeneratorDabCount = chunk.sample.phase == .ended
                ? 0
                : expectedOrdinal
            guard generatorAfter.emittedDabCount
                    == expectedGeneratorDabCount
            else {
                throw StrokeRenderCoordinatorError
                    .settledReplayCheckpointMismatch
            }
            candidateGenerator = replayedGenerator
            let rederivedSample = candidateDeriver.rederive(chunk.sample)
            guard rederivedSample == chunk.sample else {
                throw StrokeRenderCoordinatorError
                    .settledReplayCheckpointMismatch
            }
        }

        try authoritativeQueue.preflightAppend(settledTransferWorkScratch)
        var candidateMetadata = commitMetadata
        candidateMetadata.inputSampleCount += UInt64(chunks.count)
        candidateMetadata.emittedDabCount += UInt64(
            settledTransferWorkScratch.count
        )
        candidateMetadata.lastEmittedOrdinal =
            settledTransferWorkScratch.last?.ordinal
                ?? candidateMetadata.lastEmittedOrdinal
        return try registerPreparedTransaction(
            emission: StrokeCoordinatorEmission(
                work: settledTransferWorkScratch,
                generatedSamples: []
            ),
            generator: candidateGenerator,
            inputDeriver: candidateDeriver,
            commitMetadata: candidateMetadata,
            maximumReturnedDabCount: max(
                maximumReturnedDabCount,
                settledTransferWorkScratch.count
            ),
            hasBegun: candidateHasBegun,
            hasFinished: candidateHasFinished
        )
    }

    public func commit(
        _ prepared: PreparedStrokeCoordinatorEmission
    ) throws {
        try reserveForDownstreamAcceptance(prepared)
        finalizeAfterDownstreamAcceptance(prepared)
    }

    /// Performs every check that can reject a coordinator candidate. Once this
    /// succeeds, the renderer may transfer the work and then call the
    /// nonthrowing finalizer.
    func reserveForDownstreamAcceptance(
        _ prepared: PreparedStrokeCoordinatorEmission,
        retireAfterAcceptance: Bool = false
    ) throws {
        try validatePreparedTransaction(prepared, expectedReservation: false)
        guard !authoritativeQueue.hasPreparedFrame else {
            throw StrokeRenderCoordinatorError.authoritativeFrameAlreadyPrepared
        }
        if retireAfterAcceptance, !authoritativeQueue.isEmpty {
            throw StrokeRenderCoordinatorError.authoritativeQueueNotEmpty
        }
        try authoritativeQueue.preflightAppend(prepared.work)
        transactionState = .reserved(
            token: prepared.token,
            baseRevision: prepared.baseRevision,
            retireAfterAcceptance: retireAfterAcceptance
        )
    }

    /// Finalizes a prevalidated candidate after downstream ownership has been
    /// accepted. No fallible work is permitted beyond this boundary.
    func finalizeAfterDownstreamAcceptance(
        _ prepared: PreparedStrokeCoordinatorEmission
    ) {
        preconditionReservedTransaction(
            prepared,
            retireAfterAcceptance: false
        )
        authoritativeQueue.appendPrevalidated(prepared.work)
        installAndConsume(prepared)
    }

    /// Installs and immediately retires work already accepted downstream.
    /// Reservation proved the queue empty and preflighted all work, so this
    /// boundary cannot allocate a frame token or throw after acceptance.
    func finalizeAndRetireAfterDownstreamAcceptance(
        _ prepared: PreparedStrokeCoordinatorEmission
    ) {
        preconditionReservedTransaction(
            prepared,
            retireAfterAcceptance: true
        )
        authoritativeQueue.recordPrevalidatedTransfer(prepared.work)
        installAndConsume(prepared)
    }

    public func abandon(
        _ prepared: PreparedStrokeCoordinatorEmission
    ) throws {
        try validatePreparedTransaction(prepared, expectedReservation: nil)
        transactionState = .idle
    }

    public func prepareAuthoritativeFrame(
        maximumDabs: Int
    ) throws -> PreparedAuthoritativeStrokeFrame? {
        if case .reserved = transactionState {
            throw StrokeRenderCoordinatorError.transactionAlreadyReserved
        }
        return try authoritativeQueue.prepare(maximumCount: maximumDabs)
    }

    public func markAuthoritativeFrameSubmitted(
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

    public func abandonAuthoritativeFrame(
        _ frame: PreparedAuthoritativeStrokeFrame
    ) {
        authoritativeQueue.abandon(frame)
    }

    public func cancel() {
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

    #if DEBUG
    var nextTransactionTokenForTesting: UInt64 {
        nextTransactionToken
    }

    @discardableResult
    func replaceNextFrameTokenForTesting(
        _ token: UInt64
    ) -> UInt64 {
        authoritativeQueue.replaceNextFrameTokenForTesting(token)
    }
    #endif

    private enum Operation {
        case begin
        case append
        case finish
    }

    private func prepare(
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

    private func registerPreparedTransaction(
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
            predictionProvenanceBoundary:
                predictionProvenanceBoundary,
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
        case let .reserved(token, baseRevision, _):
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

    private func preconditionReservedTransaction(
        _ prepared: PreparedStrokeCoordinatorEmission,
        retireAfterAcceptance: Bool
    ) {
        precondition(
            prepared.coordinatorIdentity == coordinatorIdentity,
            "Cannot finalize a foreign stroke coordinator transaction"
        )
        precondition(
            transactionState == .reserved(
                token: prepared.token,
                baseRevision: prepared.baseRevision,
                retireAfterAcceptance: retireAfterAcceptance
            ) && prepared.baseRevision == revision,
            "Stroke coordinator transaction was not reserved"
        )
    }

    private func installAndConsume(
        _ prepared: PreparedStrokeCoordinatorEmission
    ) {
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

    private func invalidatePreparedTransaction() {
        if case .prepared = transactionState {
            transactionState = .idle
        }
    }
}
