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
    case invalidSettledTransferWorkLimit(Int)
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

struct PreparedSettledStageCTransfer: Sendable {
    let sampleCount: Int
    let dabCount: Int
    let lastOrdinal: UInt64?

    fileprivate let coordinatorIdentity: UUID
    fileprivate let token: UInt64
    fileprivate let baseRevision: UInt64
    fileprivate let startingOrdinal: UInt64
    fileprivate let generator: BrushStrokeGenerator
    fileprivate let inputDeriver: BrushInputDeriver
    fileprivate let commitMetadata: StrokeCommitMetadata
    fileprivate let maximumReturnedDabCount: Int
    fileprivate let hasBegun: Bool
    fileprivate let hasFinished: Bool
}

enum SettledStageCTransferStep: Sendable {
    case pending(consumedWorkUnits: Int)
    case prepared(
        PreparedSettledStageCTransfer,
        consumedWorkUnits: Int
    )
}

private enum SettledStageCTransferPhase: Sendable {
    case chunkHeader
    case dab
    case chunkFooter
}

struct SettledStageCTransferCursor: Sendable {
    fileprivate let coordinatorIdentity: UUID
    fileprivate let baseRevision: UInt64
    fileprivate let expectedChunkCount: Int
    fileprivate let startingOrdinal: UInt64
    fileprivate let trustedFinalGenerator: BrushStrokeGenerator
    fileprivate var chunkIndex: Int
    fileprivate var dabIndex: Int
    fileprivate var phase: SettledStageCTransferPhase
    fileprivate var expectedOrdinal: UInt64
    fileprivate var sampleCount: Int
    fileprivate var dabCount: Int
    fileprivate var lastOrdinal: UInt64?
    fileprivate var generator: BrushStrokeGenerator
    fileprivate var inputDeriver: BrushInputDeriver
    fileprivate var lifecycle: SettledReplayLifecycleCandidate
    fileprivate var currentSample: WorldStrokeSample?
    fileprivate var currentDabCount: Int
    fileprivate var currentGeneratorCheckpoint: BrushStrokeGenerator?
}

private struct SettledReplayLifecycleCandidate: Sendable {
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

    public convenience init(
        program: BrushProgram,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64,
        viewport: ViewportTransform,
        authoritativeCapacity: Int
    ) throws {
        try self.init(
            program: program,
            nominalDiameter: nominalDiameter,
            color: color,
            seed: seed,
            componentRandomNamespaceMode: .isolated,
            viewport: viewport,
            authoritativeCapacity: authoritativeCapacity
        )
    }

    package init(
        program: BrushProgram,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64,
        componentRandomNamespaceMode: BrushComponentRandomNamespaceMode,
        viewport: ViewportTransform,
        authoritativeCapacity: Int
    ) throws {
        generator = BrushStrokeGenerator(
            program: program,
            nominalDiameter: nominalDiameter,
            color: color,
            seed: seed,
            componentRandomNamespaceMode: componentRandomNamespaceMode
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

    func beginSettledStageCTransfer(
        expectedChunkCount: Int,
        trustedStartingGenerator: BrushStrokeGenerator,
        trustedFinalGenerator: BrushStrokeGenerator
    ) throws -> SettledStageCTransferCursor {
        try requireIdleTransaction()
        guard expectedChunkCount > 0,
              trustedStartingGenerator == generator,
              trustedFinalGenerator.program == generator.program
        else {
            throw StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        }
        return SettledStageCTransferCursor(
            coordinatorIdentity: coordinatorIdentity,
            baseRevision: revision,
            expectedChunkCount: expectedChunkCount,
            startingOrdinal: authoritativeQueue.nextExpectedOrdinal,
            trustedFinalGenerator: trustedFinalGenerator,
            chunkIndex: 0,
            dabIndex: 0,
            phase: .chunkHeader,
            expectedOrdinal: authoritativeQueue.nextExpectedOrdinal,
            sampleCount: 0,
            dabCount: 0,
            lastOrdinal: nil,
            generator: generator,
            inputDeriver: inputDeriver,
            lifecycle: SettledReplayLifecycleCandidate(
                hasBegun: hasBegun,
                hasFinished: hasFinished,
                expectedOrdinal: authoritativeQueue.nextExpectedOrdinal
            ),
            currentSample: nil,
            currentDabCount: 0,
            currentGeneratorCheckpoint: nil
        )
    }

    func resumeSettledStageCTransfer(
        _ cursor: inout SettledStageCTransferCursor,
        chunks: borrowing [TransientStrokeChunk],
        maximumWorkUnits: Int
    ) throws -> SettledStageCTransferStep {
        guard maximumWorkUnits > 0 else {
            throw StrokeRenderCoordinatorError
                .invalidSettledTransferWorkLimit(maximumWorkUnits)
        }
        guard cursor.coordinatorIdentity == coordinatorIdentity else {
            throw StrokeRenderCoordinatorError
                .preparedEmissionOriginMismatch
        }
        guard cursor.baseRevision == revision else {
            throw StrokeRenderCoordinatorError.stalePreparedEmission(
                expectedRevision: revision,
                actualRevision: cursor.baseRevision
            )
        }
        try requireIdleTransaction()
        guard chunks.count == cursor.expectedChunkCount,
              cursor.chunkIndex < chunks.endIndex
        else {
            throw StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        }

        var consumedWorkUnits = 0
        while consumedWorkUnits < maximumWorkUnits {
            let chunk = chunks[cursor.chunkIndex]
            switch cursor.phase {
            case .chunkHeader:
                try validateSettledReplayLifecycle(
                    chunk,
                    index: cursor.chunkIndex,
                    finalIndex: chunks.index(before: chunks.endIndex),
                    candidate: &cursor.lifecycle
                )
                try Self.validateSettledReplayInputTransition(
                    chunk,
                    inputDeriver: &cursor.inputDeriver
                )
                let (nextSampleCount, sampleOverflow) = cursor.sampleCount
                    .addingReportingOverflow(1)
                guard !sampleOverflow else {
                    throw AuthoritativeStrokeQueueError.ordinalOverflow
                }
                cursor.sampleCount = nextSampleCount
                cursor.currentSample = chunk.sample
                cursor.currentDabCount = chunk.dabs.count
                cursor.currentGeneratorCheckpoint =
                    chunk.generatorSnapshotAfterSample
                cursor.phase = chunk.dabs.isEmpty ? .chunkFooter : .dab
                consumedWorkUnits += 1

            case .dab:
                guard cursor.currentSample == .some(chunk.sample),
                      chunk.dabs.count == cursor.currentDabCount,
                      cursor.dabIndex < chunk.dabs.count
                else {
                    throw StrokeRenderCoordinatorError
                        .settledReplayCheckpointMismatch
                }
                let dab = chunk.dabs[cursor.dabIndex].attributes
                guard !dab.isPredicted else {
                    throw StrokeRenderCoordinatorError
                        .invalidAuthoritativeSample
                }
                guard dab.ordinal == cursor.expectedOrdinal else {
                    throw StrokeRenderCoordinatorError.ordinalDiscontinuity(
                        expected: cursor.expectedOrdinal,
                        actual: dab.ordinal
                    )
                }
                let (nextOrdinal, ordinalOverflow) = cursor.expectedOrdinal
                    .addingReportingOverflow(1)
                let (nextDabCount, countOverflow) = cursor.dabCount
                    .addingReportingOverflow(1)
                guard !ordinalOverflow, !countOverflow else {
                    throw AuthoritativeStrokeQueueError.ordinalOverflow
                }
                cursor.expectedOrdinal = nextOrdinal
                cursor.lifecycle.expectedOrdinal = nextOrdinal
                cursor.dabCount = nextDabCount
                cursor.lastOrdinal = dab.ordinal
                cursor.dabIndex += 1
                if cursor.dabIndex == chunk.dabs.count {
                    cursor.phase = .chunkFooter
                }
                consumedWorkUnits += 1

            case .chunkFooter:
                guard cursor.currentSample == .some(chunk.sample),
                      chunk.dabs.count == cursor.currentDabCount,
                      chunk.generatorSnapshotAfterSample
                        == cursor.currentGeneratorCheckpoint,
                      let checkpoint = chunk.generatorSnapshotAfterSample,
                      checkpoint.program == cursor.generator.program
                else {
                    throw StrokeRenderCoordinatorError
                        .settledReplayCheckpointMismatch
                }
                let expectedCheckpointCount = chunk.sample.phase == .ended
                    ? 0
                    : cursor.expectedOrdinal
                guard checkpoint.emittedDabCount == expectedCheckpointCount
                else {
                    throw StrokeRenderCoordinatorError
                        .settledReplayCheckpointMismatch
                }
                cursor.generator = checkpoint
                cursor.chunkIndex += 1
                cursor.dabIndex = 0
                cursor.phase = .chunkHeader
                cursor.currentSample = nil
                cursor.currentDabCount = 0
                cursor.currentGeneratorCheckpoint = nil
                consumedWorkUnits += 1

                if cursor.chunkIndex == cursor.expectedChunkCount {
                    guard cursor.generator == cursor.trustedFinalGenerator
                    else {
                        throw StrokeRenderCoordinatorError
                            .settledReplayCheckpointMismatch
                    }
                    let prepared = try registerPreparedSettledStageCTransfer(
                        cursor
                    )
                    return .prepared(
                        prepared,
                        consumedWorkUnits: consumedWorkUnits
                    )
                }
            }
        }
        return .pending(consumedWorkUnits: consumedWorkUnits)
    }

    func prepareSettledReplayTransfer(
        _ chunks: borrowing [TransientStrokeChunk],
        trustedStartingGenerator: BrushStrokeGenerator,
        trustedFinalGenerator: BrushStrokeGenerator
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
        try installSettledStageCCheckpoints(
            chunks,
            startingExpectedOrdinal: replayStartingOrdinal,
            trustedStartingGenerator: trustedStartingGenerator,
            trustedFinalGenerator: trustedFinalGenerator,
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

    /// Stage C generation is already complete on the scheduler actor. Promote
    /// only its trusted checkpoints after validating their complete
    /// ordinal/program/final chain.
    @inline(never)
    private func installSettledStageCCheckpoints(
        _ chunks: borrowing [TransientStrokeChunk],
        startingExpectedOrdinal: UInt64,
        trustedStartingGenerator: BrushStrokeGenerator,
        trustedFinalGenerator: BrushStrokeGenerator,
        generator: inout BrushStrokeGenerator
    ) throws {
        guard trustedStartingGenerator == generator,
              trustedFinalGenerator.program == generator.program
        else {
            throw StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        }
        var expectedOrdinal = startingExpectedOrdinal
        var finalCheckpoint: BrushStrokeGenerator?
        for index in chunks.indices {
            let chunk = chunks[index]
            let (ordinalAfterChunk, overflow) = expectedOrdinal
                .addingReportingOverflow(UInt64(chunk.dabs.count))
            guard !overflow,
                  let checkpoint = chunk.generatorSnapshotAfterSample,
                  checkpoint.program == generator.program
            else {
                throw StrokeRenderCoordinatorError
                    .settledReplayCheckpointMismatch
            }
            let expectedCheckpointCount = chunk.sample.phase == .ended
                ? 0
                : ordinalAfterChunk
            guard checkpoint.emittedDabCount == expectedCheckpointCount else {
                throw StrokeRenderCoordinatorError
                    .settledReplayCheckpointMismatch
            }
            finalCheckpoint = checkpoint
            expectedOrdinal = ordinalAfterChunk
        }
        guard finalCheckpoint == trustedFinalGenerator else {
            throw StrokeRenderCoordinatorError
                .settledReplayCheckpointMismatch
        }
        generator = trustedFinalGenerator
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

    func reserveForDownstreamAcceptance(
        _ prepared: PreparedSettledStageCTransfer,
        retireAfterAcceptance: Bool = true
    ) throws {
        try validatePreparedTransaction(
            prepared,
            expectedReservation: false
        )
        guard retireAfterAcceptance else {
            throw StrokeRenderCoordinatorError.invalidLifecycle
        }
        guard !authoritativeQueue.hasPreparedFrame else {
            throw StrokeRenderCoordinatorError
                .authoritativeFrameAlreadyPrepared
        }
        guard authoritativeQueue.isEmpty else {
            throw StrokeRenderCoordinatorError.authoritativeQueueNotEmpty
        }
        try authoritativeQueue.preflightRetiredTransfer(
            startingOrdinal: prepared.startingOrdinal,
            count: prepared.dabCount
        )
        transactionState = .reserved(
            token: prepared.token,
            baseRevision: prepared.baseRevision,
            retireAfterAcceptance: true
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

    func finalizeAndRetireAfterDownstreamAcceptance(
        _ prepared: PreparedSettledStageCTransfer
    ) {
        preconditionReservedTransaction(
            prepared,
            retireAfterAcceptance: true
        )
        authoritativeQueue.recordPrevalidatedRetiredTransfer(
            startingOrdinal: prepared.startingOrdinal,
            count: prepared.dabCount
        )
        installAndConsume(prepared)
    }

    public func abandon(
        _ prepared: PreparedStrokeCoordinatorEmission
    ) throws {
        try validatePreparedTransaction(prepared, expectedReservation: nil)
        transactionState = .idle
    }

    func abandon(
        _ prepared: PreparedSettledStageCTransfer
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
            let collect: (DabAttributes) throws -> Void = {
                dabs.append($0)
            }
            let operation: Operation
            if offset == 0 {
                operation = firstOperation
            } else if sample.phase == .ended {
                operation = .finish
            } else {
                operation = .append
            }
            let expectedPhase: StrokePhase = switch operation {
            case .begin: .began
            case .append: .moved
            case .finish: .ended
            }
            guard worldSample.phase == expectedPhase else {
                throw StrokeRenderCoordinatorError.invalidLifecycle
            }
            var cursor = try candidateGenerator.emissionCursor(
                for: worldSample,
                maximumPathSubdivisionCount: .max
            )
            repeat {
                _ = try cursor.emitNextPage(collect)
            } while !cursor.isComplete
            guard let completed = cursor.completedGenerator else {
                throw StrokeRenderCoordinatorError.invalidLifecycle
            }
            candidateGenerator = completed
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

    private func registerPreparedSettledStageCTransfer(
        _ cursor: borrowing SettledStageCTransferCursor
    ) throws -> PreparedSettledStageCTransfer {
        precondition(
            transactionState == .idle,
            "A stroke coordinator may issue only one transaction at a time"
        )
        let token = nextTransactionToken
        let (successor, tokenOverflow) = token.addingReportingOverflow(1)
        guard !tokenOverflow else {
            throw StrokeRenderCoordinatorError.transactionTokenOverflow
        }
        let (inputSampleCount, sampleOverflow) = commitMetadata
            .inputSampleCount
            .addingReportingOverflow(UInt64(cursor.sampleCount))
        let (emittedDabCount, dabOverflow) = commitMetadata
            .emittedDabCount
            .addingReportingOverflow(UInt64(cursor.dabCount))
        guard !sampleOverflow, !dabOverflow else {
            throw AuthoritativeStrokeQueueError.ordinalOverflow
        }
        var candidateMetadata = commitMetadata
        candidateMetadata.inputSampleCount = inputSampleCount
        candidateMetadata.emittedDabCount = emittedDabCount
        candidateMetadata.lastEmittedOrdinal =
            cursor.lastOrdinal ?? commitMetadata.lastEmittedOrdinal
        nextTransactionToken = successor
        transactionState = .prepared(token: token, baseRevision: revision)
        return PreparedSettledStageCTransfer(
            sampleCount: cursor.sampleCount,
            dabCount: cursor.dabCount,
            lastOrdinal: cursor.lastOrdinal,
            coordinatorIdentity: coordinatorIdentity,
            token: token,
            baseRevision: revision,
            startingOrdinal: cursor.startingOrdinal,
            generator: cursor.generator,
            inputDeriver: cursor.inputDeriver,
            commitMetadata: candidateMetadata,
            maximumReturnedDabCount: max(
                maximumReturnedDabCount,
                cursor.dabCount
            ),
            hasBegun: cursor.lifecycle.hasBegun,
            hasFinished: cursor.lifecycle.hasFinished
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

    private func validatePreparedTransaction(
        _ prepared: PreparedSettledStageCTransfer,
        expectedReservation: Bool?
    ) throws {
        guard prepared.coordinatorIdentity == coordinatorIdentity else {
            throw StrokeRenderCoordinatorError
                .preparedEmissionOriginMismatch
        }
        guard prepared.baseRevision == revision else {
            throw StrokeRenderCoordinatorError.stalePreparedEmission(
                expectedRevision: revision,
                actualRevision: prepared.baseRevision
            )
        }
        switch transactionState {
        case .idle:
            throw StrokeRenderCoordinatorError
                .preparedEmissionAlreadyConsumed
        case let .prepared(token, baseRevision):
            guard expectedReservation != true,
                  token == prepared.token,
                  baseRevision == prepared.baseRevision
            else {
                throw StrokeRenderCoordinatorError
                    .preparedEmissionTokenMismatch
            }
        case let .reserved(token, baseRevision, _):
            guard expectedReservation != false,
                  token == prepared.token,
                  baseRevision == prepared.baseRevision
            else {
                throw StrokeRenderCoordinatorError
                    .preparedEmissionTokenMismatch
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

    private func preconditionReservedTransaction(
        _ prepared: PreparedSettledStageCTransfer,
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

    private func installAndConsume(
        _ prepared: PreparedSettledStageCTransfer
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
