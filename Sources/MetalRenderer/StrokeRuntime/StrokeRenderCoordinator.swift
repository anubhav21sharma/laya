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

private struct SettledReplayLifecycleCandidate {
    var hasBegun: Bool
    var hasFinished: Bool
    var expectedOrdinal: UInt64
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
        _ chunks: borrowing [TransientStrokeChunk]
    ) throws -> PreparedStrokeCoordinatorEmission {
        try requireIdleTransaction()
        guard !chunks.isEmpty else {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }

        settledTransferWorkScratch.removeAll(keepingCapacity: true)
        var candidateGenerator = generator
        var candidateInputDeriver = inputDeriver
        let replayStartingOrdinal = authoritativeQueue.nextExpectedOrdinal
        var candidateLifecycle = SettledReplayLifecycleCandidate(
            hasBegun: hasBegun,
            hasFinished: hasFinished,
            expectedOrdinal: replayStartingOrdinal
        )
        try validateSettledReplayStructure(
            chunks,
            candidate: &candidateLifecycle
        )
        try advanceSettledReplayInputChunks(
            chunks,
            inputDeriver: &candidateInputDeriver
        )
        try advanceSettledReplayGeneratorChunks(
            chunks,
            startingExpectedOrdinal: replayStartingOrdinal,
            generator: &candidateGenerator
        )

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
            inputDeriver: candidateInputDeriver,
            commitMetadata: candidateMetadata,
            maximumReturnedDabCount: max(
                maximumReturnedDabCount,
                settledTransferWorkScratch.count
            ),
            hasBegun: candidateLifecycle.hasBegun,
            hasFinished: candidateLifecycle.hasFinished
        )
    }

    @inline(never)
    private func validateSettledReplayStructure(
        _ chunks: borrowing [TransientStrokeChunk],
        candidate: inout SettledReplayLifecycleCandidate
    ) throws {
        for index in chunks.indices {
            try validateSettledReplayLifecycle(
                chunks[index],
                index: index,
                finalIndex: chunks.index(before: chunks.endIndex),
                candidate: &candidate
            )
            try appendSettledReplayWork(
                chunks[index],
                expectedOrdinal: &candidate.expectedOrdinal
            )
        }
    }

    @inline(never)
    private func advanceSettledReplayInputChunks(
        _ chunks: borrowing [TransientStrokeChunk],
        inputDeriver: inout BrushInputDeriver
    ) throws {
        for index in chunks.indices {
            try Self.validateSettledReplayInputTransition(
                chunks[index],
                inputDeriver: &inputDeriver
            )
        }
    }

    @inline(never)
    private func advanceSettledReplayGeneratorChunks(
        _ chunks: borrowing [TransientStrokeChunk],
        startingExpectedOrdinal: UInt64,
        generator: inout BrushStrokeGenerator
    ) throws {
        var expectedOrdinal = startingExpectedOrdinal
        for index in chunks.indices {
            let (ordinalAfterChunk, overflow) = expectedOrdinal
                .addingReportingOverflow(UInt64(chunks[index].dabs.count))
            guard !overflow else {
                throw AuthoritativeStrokeQueueError.ordinalOverflow
            }
            try Self.advanceSettledReplayGeneratorChunk(
                chunks[index],
                expectedOrdinal: ordinalAfterChunk,
                generator: &generator
            )
            expectedOrdinal = ordinalAfterChunk
        }
    }

    @inline(never)
    private static func advanceSettledReplayGeneratorChunk(
        _ chunk: borrowing TransientStrokeChunk,
        expectedOrdinal: UInt64,
        generator: inout BrushStrokeGenerator
    ) throws {
        try validateSettledReplayGeneratorBefore(
            chunk,
            generator: &generator
        )
        try advanceSettledReplayGeneratorChunkAfterBeforeCheck(
            chunk,
            expectedOrdinal: expectedOrdinal,
            generator: &generator
        )
    }

    @inline(never)
    private static func advanceSettledReplayGeneratorChunkAfterBeforeCheck(
        _ chunk: borrowing TransientStrokeChunk,
        expectedOrdinal: UInt64,
        generator: inout BrushStrokeGenerator
    ) throws {
        try replaySettledGeneratorTransition(
            chunk,
            expectedOrdinal: expectedOrdinal,
            generator: &generator
        )
    }

    @inline(never)
    private func validateSettledReplayLifecycle(
        _ chunk: borrowing TransientStrokeChunk,
        index: Int,
        finalIndex: Int,
        candidate: inout SettledReplayLifecycleCandidate
    ) throws {
        switch chunk.sample.phase {
        case .began:
            guard index == 0, !candidate.hasBegun,
                  !candidate.hasFinished
            else {
                throw StrokeRenderCoordinatorError.invalidLifecycle
            }
            candidate.hasBegun = true
        case .moved:
            guard candidate.hasBegun, !candidate.hasFinished else {
                throw StrokeRenderCoordinatorError.invalidLifecycle
            }
        case .ended:
            guard candidate.hasBegun, !candidate.hasFinished,
                  index == finalIndex
            else {
                throw StrokeRenderCoordinatorError.invalidLifecycle
            }
            candidate.hasFinished = true
        case .cancelled:
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        guard chunk.sample.kind == .actual
                || chunk.sample.kind == .coalesced
        else {
            throw StrokeRenderCoordinatorError.invalidAuthoritativeSample
        }
        guard chunk.generatorSnapshotAfterSample != nil else {
            throw StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        }
    }

    @inline(never)
    private func appendSettledReplayWork(
        _ chunk: borrowing TransientStrokeChunk,
        expectedOrdinal: inout UInt64
    ) throws {
        for transientDab in chunk.dabs {
            let dab = transientDab.attributes
            guard !dab.isPredicted else {
                throw StrokeRenderCoordinatorError.invalidAuthoritativeSample
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
    }

    @inline(never)
    private static func replaySettledGeneratorTransition(
        _ chunk: borrowing TransientStrokeChunk,
        expectedOrdinal: UInt64,
        generator: inout BrushStrokeGenerator
    ) throws {
        let replayedDabCount: Int
        switch chunk.sample.phase {
        case .began:
            replayedDabCount = try Self.replaySettledBegin(
                chunk,
                generator: &generator
            )
        case .moved:
            replayedDabCount = try Self.replaySettledAppend(
                chunk,
                generator: &generator
            )
        case .ended:
            replayedDabCount = try Self.replaySettledFinish(
                chunk,
                generator: &generator
            )
        case .cancelled:
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        try Self.validateSettledReplayStateAfter(
            chunk,
            expectedOrdinal: expectedOrdinal,
            replayedDabCount: replayedDabCount,
            generator: &generator
        )
    }

    @inline(never)
    private static func validateSettledReplayGeneratorBefore(
        _ chunk: borrowing TransientStrokeChunk,
        generator: inout BrushStrokeGenerator
    ) throws {
        guard let checkpoint = chunk.generatorSnapshotBeforeSample,
              checkpoint == generator
        else {
            throw StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        }
    }

    @inline(never)
    private static func validateSettledReplayInputTransition(
        _ chunk: borrowing TransientStrokeChunk,
        inputDeriver: inout BrushInputDeriver
    ) throws {
        guard chunk.inputDeriverSnapshotBeforeSample == .some(inputDeriver) else {
            throw StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        }
        let rederivedSample = inputDeriver.rederive(chunk.sample)
        guard rederivedSample == chunk.sample else {
            throw StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        }
    }

    @inline(never)
    private static func replaySettledBegin(
        _ chunk: borrowing TransientStrokeChunk,
        generator: inout BrushStrokeGenerator
    ) throws -> Int {
        var replayedDabCount = 0
        try generator.begin(chunk.sample) { dab in
            try validateSettledReplayDab(
                dab,
                at: &replayedDabCount,
                in: chunk
            )
        }
        return replayedDabCount
    }

    @inline(never)
    private static func replaySettledAppend(
        _ chunk: borrowing TransientStrokeChunk,
        generator: inout BrushStrokeGenerator
    ) throws -> Int {
        var replayedDabCount = 0
        try generator.append(chunk.sample) { dab in
            try validateSettledReplayDab(
                dab,
                at: &replayedDabCount,
                in: chunk
            )
        }
        return replayedDabCount
    }

    @inline(never)
    private static func replaySettledFinish(
        _ chunk: borrowing TransientStrokeChunk,
        generator: inout BrushStrokeGenerator
    ) throws -> Int {
        var replayedDabCount = 0
        try generator.finish(chunk.sample) { dab in
            try validateSettledReplayDab(
                dab,
                at: &replayedDabCount,
                in: chunk
            )
        }
        return replayedDabCount
    }

    @inline(never)
    private static func validateSettledReplayStateAfter(
        _ chunk: borrowing TransientStrokeChunk,
        expectedOrdinal: UInt64,
        replayedDabCount: Int,
        generator: inout BrushStrokeGenerator
    ) throws {
        guard let checkpoint = chunk.generatorSnapshotAfterSample else {
            throw StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        }
        guard replayedDabCount == chunk.dabs.count,
              checkpoint == generator
        else {
            throw StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        }
        let expectedGeneratorDabCount = chunk.sample.phase == .ended
            ? 0
            : expectedOrdinal
        guard generator.emittedDabCount == expectedGeneratorDabCount else {
            throw StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        }
    }

    private static func validateSettledReplayDab(
        _ dab: borrowing LogicalDab,
        at index: inout Int,
        in chunk: borrowing TransientStrokeChunk
    ) throws {
        guard index < chunk.dabs.count,
              chunk.dabs[index].attributes == dab
        else {
            throw StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        }
        index += 1
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
