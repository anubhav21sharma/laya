import Foundation
import CShaderTypes
import PatternEngine

package enum StrokePreparationAllocationProbeStage: UInt8, Sendable {
    case authoritativeCPU
    case predictionCPU
    case estimatedCPU
    case batchPackaging
    case privateSurfaceEncoding
}

package struct StrokePreparationAllocationProbe: Sendable {
    package let identity: UInt64
    private let armHandler: @Sendable () -> Void
    private let disarmHandler: @Sendable () -> UInt64
    private let recordHandler:
        @Sendable (StrokePreparationAllocationProbeStage, UInt64) -> Void

    package init(
        identity: UInt64,
        arm: @escaping @Sendable () -> Void,
        disarm: @escaping @Sendable () -> UInt64,
        record: @escaping @Sendable (
            StrokePreparationAllocationProbeStage,
            UInt64
        ) -> Void
    ) {
        self.identity = identity
        armHandler = arm
        disarmHandler = disarm
        recordHandler = record
    }

    func arm() {
        armHandler()
    }

    func disarmAndRecord(_ stage: StrokePreparationAllocationProbeStage) {
        recordHandler(stage, disarmHandler())
    }
}

struct StrokePreparationConfiguration: Equatable, Sendable {
    let program: BrushProgram
    let nominalDiameter: Float
    let color: InkColor
    let seed: UInt64
    let viewport: ViewportTransform
    let tilingStrategy: TilingStrategy
    let metalResourceDescriptor: StrokeMetalResourceDescriptor?
    let allocationProbe: StrokePreparationAllocationProbe?

    init(
        program: BrushProgram,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64,
        viewport: ViewportTransform,
        tilingStrategy: TilingStrategy,
        metalResourceDescriptor: StrokeMetalResourceDescriptor? = nil,
        allocationProbe: StrokePreparationAllocationProbe? = nil
    ) {
        self.program = program
        self.nominalDiameter = nominalDiameter
        self.color = color
        self.seed = seed
        self.viewport = viewport
        self.tilingStrategy = tilingStrategy
        self.metalResourceDescriptor = metalResourceDescriptor
        self.allocationProbe = allocationProbe
    }

    static func == (
        lhs: StrokePreparationConfiguration,
        rhs: StrokePreparationConfiguration
    ) -> Bool {
        lhs.program == rhs.program
            && lhs.nominalDiameter == rhs.nominalDiameter
            && lhs.color == rhs.color
            && lhs.seed == rhs.seed
            && lhs.viewport == rhs.viewport
            && lhs.tilingStrategy == rhs.tilingStrategy
            && lhs.metalResourceDescriptor?.brushRenderIdentity
                == rhs.metalResourceDescriptor?.brushRenderIdentity
            && lhs.allocationProbe?.identity
                == rhs.allocationProbe?.identity
    }
}

struct StrokePreparationExecutorProbe: Equatable, Sendable {
    let generatorRanOnMainThread: Bool
    let projectionRanOnMainThread: Bool
}

struct StrokePreparedProjectedRecord: Equatable, Sendable {
    let depositionRecord: ProjectedDepositionRecord
    let dirtyRect: PixelRect
    let radialPage: RadialPageCoordinate?
}

struct StrokePreparedDepositionBatch: Sendable {
    let generation: UInt64
    let sequence: UInt64
    let frameToken: UInt64?
    let logicalDabs: [LogicalDab]
    let dirtyRegions: [PixelRect]
    let authoritativeInstanceCount: Int
    let predictedInstanceCount: Int
    let predictionProvenanceBoundary: PredictionProvenanceBoundary
    let coordinatorSnapshot: StrokeRenderSnapshot
    let executorProbe: StrokePreparationExecutorProbe
    let isFinishing: Bool
    let predictionAdmission: PredictionOverlayAdmission?
    let surfaceLease: StrokePreparedSurfaceLease?
    let surfaceSnapshot: StrokePrivateSurfaceEncoderSnapshot?
    let preparationCPUNanoseconds: UInt64
}

struct StrokeScheduledFrame: Equatable, Sendable {
    let authoritative: [ProjectedDepositionRecord]
    let predicted: [ProjectedDepositionRecord]
    let authoritativeRemaining: Int
    let predictedRemaining: Int
    let targetFrameDurationNanoseconds: UInt64
    fileprivate let token: UInt64
}

struct StrokeFrameSchedulerSnapshot: Equatable, Sendable {
    let activeGeneration: UInt64?
    let cancelledGeneration: UInt64?
    let authoritativePending: Int
    let predictedPending: Int
    let authoritativeHighWater: Int
    let predictedHighWater: Int
    let authoritativeStorageCapacity: Int
    let predictedStorageCapacity: Int
    let maximumPreparationWorkUnitsPerFrame: Int
    let commitRequested: Bool
    let frameOutstanding: Bool
    let retainedActualSampleCount: Int
    let retainedPredictedSampleCount: Int
    let transientMutationVersion: UInt64
    let generatedLogicalDabHighWater: Int
    let generatedProjectionHighWater: Int
    let generatedLogicalDabStorageCapacity: Int
    let generatedProjectionStorageCapacity: Int
    let projectionImageHighWater: Int
    let projectionCellHighWater: Int
    let projectionFragmentHighWater: Int
    let projectionImageStorageCapacity: Int
    let projectionCellStorageCapacity: Int
    let projectionFragmentStorageCapacity: Int
    let projectionStorageAllocationCount: UInt64
}

#if DEBUG
struct StrokeTransientPreparationSnapshot: Equatable, Sendable {
    let actualSamples: [WorldStrokeSample]
    let predictedSamples: [WorldStrokeSample]
    let actualDabs: [TransientStrokeDab]
    let predictedDabs: [TransientStrokeDab]
}

struct StrokeEstimatedUpdateDiagnosticSnapshot: Equatable, Sendable {
    let target: EstimatedStrokeUpdateTarget
    let mergedSample: WorldStrokeSample
    let rederivedSampleCount: Int
    let mutationVersion: UInt64
}
#endif

enum StrokeFrameSchedulerError: Error, Equatable, Sendable {
    case invalidLifecycle
    case invalidProjectedIsometry(imageOrdinal: UInt8)
    case staleGeneration(expected: UInt64?, actual: UInt64)
    case authoritativeCapacityExceeded(
        generation: UInt64,
        current: Int,
        incoming: Int,
        maximum: Int
    )
    case replayCapacityExceeded(actual: Int, maximum: Int)
    case strokeSampleCapacityExceeded(actual: Int, maximum: Int)
    case generatedDabCapacityExceeded(actual: Int, maximum: Int)
    case projectedInstanceCapacityExceeded(actual: Int, maximum: Int)
    case invalidPreparedFrame
    case frameTokenOverflow
    case missingGeneratorCheckpoint
}

private struct StrokePredictionGenerationLimitReached: Error {
    let reason: PredictionOverloadReasons
}

/// Actor-isolated frame admission and submission state. The contained
/// deposition scheduler is never shared across executors; callers exchange
/// immutable records and frame values only.
actor StrokeFrameScheduler {
    var snapshot: StrokeFrameSchedulerSnapshot {
        let frame = scheduler.diagnosticSnapshot
        return StrokeFrameSchedulerSnapshot(
            activeGeneration: activeGeneration,
            cancelledGeneration: cancelledGeneration,
            authoritativePending: frame.authoritativePending,
            predictedPending: frame.predictedPending,
            authoritativeHighWater: frame.authoritativeHighWater,
            predictedHighWater: frame.predictedHighWater,
            authoritativeStorageCapacity:
                frame.authoritativeStorageCapacity,
            predictedStorageCapacity: frame.predictedStorageCapacity,
            maximumPreparationWorkUnitsPerFrame:
                maximumPreparationWorkUnitsPerFrame,
            commitRequested: commitRequested,
            frameOutstanding: outstandingFrame != nil,
            retainedActualSampleCount:
                transientStrokeBuffer?.actualSampleCount ?? 0,
            retainedPredictedSampleCount:
                transientStrokeBuffer?.predictedSampleCount ?? 0,
            transientMutationVersion:
                transientStrokeBuffer?.mutationVersion ?? 0,
            generatedLogicalDabHighWater:
                generatedLogicalDabHighWater,
            generatedProjectionHighWater:
                generatedProjectionHighWater,
            generatedLogicalDabStorageCapacity:
                generatedLogicalDabScratch.capacity,
            generatedProjectionStorageCapacity:
                generatedProjectionScratch.capacity,
            projectionImageHighWater: projectionImageHighWater,
            projectionCellHighWater: projectionCellHighWater,
            projectionFragmentHighWater: projectionFragmentHighWater,
            projectionImageStorageCapacity:
                projectionScratch.storageDiagnostics.imageCapacity,
            projectionCellStorageCapacity:
                projectionScratch.cellStorageCapacity,
            projectionFragmentStorageCapacity:
                projectionScratch.storageDiagnostics.fragmentCapacity,
            projectionStorageAllocationCount:
                projectionScratch.storageAllocationCount
        )
    }

    #if DEBUG
    var transientPreparationSnapshotForTesting:
        StrokeTransientPreparationSnapshot
    {
        StrokeTransientPreparationSnapshot(
            actualSamples: transientStrokeBuffer?.actualSamples ?? [],
            predictedSamples:
                transientStrokeBuffer?.predictedSamples ?? [],
            actualDabs: transientStrokeBuffer?.actualDabs ?? [],
            predictedDabs: transientStrokeBuffer?.predictedDabs ?? []
        )
    }


    var lastEstimatedUpdateSnapshotForTesting:
        StrokeEstimatedUpdateDiagnosticSnapshot?
    {
        lastEstimatedUpdateSnapshot
    }
    #endif

    private let budget: DepositionFrameBudget
    private let targetFrameDurationNanoseconds: UInt64
    private var scheduler: FrameScheduler
    private var activeGeneration: UInt64?
    private var cancelledGeneration: UInt64?
    private var commitRequested = false
    private var outstandingFrame: StrokeScheduledFrame?
    private var nextFrameToken: UInt64 = 1
    private var authoritativeScratch: [ProjectedDepositionRecord] = []
    private var predictedScratch: [ProjectedDepositionRecord] = []
    private var maximumPreparationWorkUnitsPerFrame = 0
    private var preparationCoordinator: StrokeRenderCoordinator?
    private var authoritativeGenerator: BrushStrokeGenerator?
    private var authoritativeInputDeriver: BrushInputDeriver?
    private var transientStrokeBuffer: TransientStrokeBuffer?
    private let transientDabArena = TransientStrokeDabArena()
    private var preparationTilingStrategy: TilingStrategy?
    private var preparationViewport: ViewportTransform?
    private let projectionScratch: TilingProjectionScratch
    private var nextPreparationSequence: UInt64 = 1
    private var projectedCarry: StrokePreparedProjectedQueue
    private var preparedOutputScratch: [StrokePreparedProjectedRecord] = []
    private var preparedDirtyOutputScratch: [PixelRect] = []
    private var privateSurfaceEncoder: StrokePrivateSurfaceEncoder?
    private let reusablePrivateSurfaceEncoder = StrokePrivateSurfaceEncoder()
    private var preparationAllocationProbe:
        StrokePreparationAllocationProbe?
    private var outstandingSurfaceLease: StrokePreparedSurfaceLease?
    private var pendingCommitBarrierGeneration: UInt64?
    private var preparationMutationRevision: UInt64 = 0
    private var preparationHasBegun = false
    private var preparationHasFinished = false
    #if DEBUG
    private var lastEstimatedUpdateSnapshot:
        StrokeEstimatedUpdateDiagnosticSnapshot?
    #endif
    private var transientDabScratch: [TransientStrokeDab] = []
    private var transientChunkScratch: [TransientStrokeChunk] = []
    private var settledChunkScratch: [TransientStrokeChunk] = []
    private var generatedLogicalDabScratch: [LogicalDab] = []
    private var perSampleLogicalDabScratch: [LogicalDab] = []
    private var authoritativeProjectedScratch:
        [StrokePreparedProjectedRecord] = []
    private var replayProjectedScratch: [StrokePreparedProjectedRecord] = []
    private var authoritativeDepositionScratch:
        [ProjectedDepositionRecord] = []
    private var replayDepositionScratch: [ProjectedDepositionRecord] = []
    private var estimatedReplacementSampleScratch: [WorldStrokeSample] = []
    private var perMutationSettledScratch: [TransientStrokeChunk] = []
    private var estimatedRetainedActualScratch: [TransientStrokeChunk] = []
    private var estimatedRetainedPredictionScratch:
        [TransientStrokeChunk] = []
    private var generatedProjectionScratch:
        [StrokePreparedProjectedRecord] = []
    private var singleActualSampleScratch: [StrokeSample] = []
    private var singlePredictionSampleScratch: [StrokeSample] = []
    private var predictionBatchSampleScratch: [StrokeSample] = []
    private var pendingPredictionBatchGeneration: UInt64?
    private var pendingPredictionBatchCount = 0
    private var pendingPredictionBatchSubmittedCount = 0
    private var generatedLogicalDabHighWater = 0
    private var generatedProjectionHighWater = 0
    private var projectionImageHighWater = 0
    private var projectionCellHighWater = 0
    private var projectionFragmentHighWater = 0

    init(
        budget: DepositionFrameBudget,
        targetFramesPerSecond: Int
    ) {
        precondition(targetFramesPerSecond > 0)
        self.budget = budget
        targetFrameDurationNanoseconds = UInt64(
            1_000_000_000 / targetFramesPerSecond
        )
        scheduler = FrameScheduler(budget: budget)
        projectionScratch = TilingProjectionScratch(
            maximumFragmentCount:
                budget.maximumPendingAuthoritativeInstances
        )
        projectedCarry = StrokePreparedProjectedQueue(
            capacity: budget.maximumPendingAuthoritativeInstances
                + budget.maximumPendingPredictedInstances
        )
        authoritativeScratch.reserveCapacity(
            budget.maximumAuthoritativeInstances
        )
        predictedScratch.reserveCapacity(
            budget.maximumPredictedInstances
        )
        preparedOutputScratch.reserveCapacity(
            max(
                budget.maximumAuthoritativeInstances,
                budget.maximumPredictedInstances
            )
        )
        preparedDirtyOutputScratch.reserveCapacity(
            max(
                budget.maximumAuthoritativeInstances,
                budget.maximumPredictedInstances
            )
        )
        transientDabScratch.reserveCapacity(
            TransientStrokeBufferContract.wholeStrokeDabCapacity
        )
        transientChunkScratch.reserveCapacity(
            TransientStrokeBufferContract.wholeStrokeSampleCapacity
        )
        settledChunkScratch.reserveCapacity(
            TransientStrokeBufferContract.wholeStrokeSampleCapacity
        )
        generatedLogicalDabScratch.reserveCapacity(
            TransientStrokeBufferContract.wholeStrokeDabCapacity
        )
        perSampleLogicalDabScratch.reserveCapacity(
            TransientStrokeBufferContract.wholeStrokeDabCapacity
        )
        authoritativeProjectedScratch.reserveCapacity(
            budget.maximumPendingAuthoritativeInstances
        )
        replayProjectedScratch.reserveCapacity(
            budget.maximumPendingPredictedInstances
        )
        authoritativeDepositionScratch.reserveCapacity(
            budget.maximumPendingAuthoritativeInstances
        )
        replayDepositionScratch.reserveCapacity(
            budget.maximumPendingPredictedInstances
        )
        estimatedReplacementSampleScratch.reserveCapacity(
            TransientStrokeBufferContract.wholeStrokeSampleCapacity
        )
        perMutationSettledScratch.reserveCapacity(
            TransientStrokeBufferContract.wholeStrokeSampleCapacity
        )
        estimatedRetainedActualScratch.reserveCapacity(
            TransientStrokeBufferContract.wholeStrokeSampleCapacity
        )
        estimatedRetainedPredictionScratch.reserveCapacity(
            TransientStrokeBufferContract.wholeStrokeSampleCapacity
        )
        generatedProjectionScratch.reserveCapacity(
            budget.maximumPendingAuthoritativeInstances
        )
        singleActualSampleScratch.reserveCapacity(1)
        singlePredictionSampleScratch.reserveCapacity(1)
        predictionBatchSampleScratch.reserveCapacity(
            PredictionOverlay.maximumNormalizedSampleCount
        )
    }

    func process(
        _ message: StrokeInputMessage
    ) async -> StrokePreparationResult? {
        do {
            switch message {
            case let .begin(generation, configuration, samples):
                resetPredictionBatchAssembly()
                return .prepared(
                    try await beginPreparedStroke(
                        generation: generation,
                        configuration: configuration,
                        actualSamples: samples
                    )
                )
            case let .appendAuthoritative(generation, samples):
                return .prepared(
                    try await appendPreparedStroke(
                        generation: generation,
                        actualSamples: samples
                    )
                )
            case let .appendAuthoritativeSample(generation, sample):
                return .prepared(
                    try await appendPreparedStrokeSample(
                        generation: generation,
                        sample: sample
                    )
                )
            case let .finish(generation, samples):
                return .prepared(
                    try await finishPreparedStroke(
                        generation: generation,
                        actualSamples: samples
                    )
                )
            case let .replacePrediction(
                generation,
                samples,
                acceptedCount
            ):
                resetPredictionBatchAssembly()
                return .prepared(
                    try await replacePreparedPrediction(
                        generation: generation,
                        samples: samples,
                        acceptedCount: acceptedCount
                    )
                )
            case let .replacePredictionBatchSample(
                generation,
                sample,
                index,
                count,
                submittedCount
            ):
                guard count > 0,
                      count
                        <= PredictionOverlay.maximumNormalizedSampleCount,
                      submittedCount >= count,
                      index >= 0,
                      index < count
                else {
                    throw StrokeFrameSchedulerError.invalidLifecycle
                }
                if index == 0 {
                    resetPredictionBatchAssembly()
                    pendingPredictionBatchGeneration = generation
                    pendingPredictionBatchCount = count
                    pendingPredictionBatchSubmittedCount = submittedCount
                }
                guard pendingPredictionBatchGeneration == generation,
                      pendingPredictionBatchCount == count,
                      pendingPredictionBatchSubmittedCount
                        == submittedCount,
                      predictionBatchSampleScratch.count == index
                else {
                    throw StrokeFrameSchedulerError.invalidLifecycle
                }
                predictionBatchSampleScratch.append(sample)
                guard predictionBatchSampleScratch.count == count else {
                    return nil
                }
                defer { resetPredictionBatchAssembly() }
                return .prepared(
                    try await replacePreparedPrediction(
                        generation: generation,
                        samples: predictionBatchSampleScratch,
                        acceptedCount: count,
                        submittedSampleCount: submittedCount
                    )
                )
            case let .replacePredictionSample(generation, sample):
                resetPredictionBatchAssembly()
                singlePredictionSampleScratch.removeAll(
                    keepingCapacity: true
                )
                singlePredictionSampleScratch.append(sample)
                return .prepared(
                    try await replacePreparedPrediction(
                        generation: generation,
                        samples: singlePredictionSampleScratch,
                        acceptedCount: 1
                    )
                )
            case let .applyEstimatedUpdate(generation, sample):
                return try await applyPreparedEstimatedUpdate(
                    generation: generation,
                    sample: sample
                )
            case let .commit(generation):
                try requestCommit(generation: generation)
                if privateSurfaceEncoder != nil {
                    pendingCommitBarrierGeneration = generation
                    return .prepared(
                        try await makePreparedOutputBatch(
                            generation: generation,
                            logicalDabs: [],
                            predictionProvenanceBoundary:
                                currentPredictionProvenanceBoundary,
                            coordinatorSnapshot:
                                preparationCoordinator?.snapshot,
                            executorProbe: StrokePreparationExecutorProbe(
                                generatorRanOnMainThread: false,
                                projectionRanOnMainThread: false
                            ),
                            isFinishing: false,
                            emitEmpty: true,
                            predictionAdmission: PredictionOverlayAdmission(
                                normalizedSampleCount: 0,
                                logicalDabCount: 0,
                                projectedInstanceCount: 0,
                                overload: []
                            )
                        )!
                    )
                }
                return .commitBarrierReached(generation: generation)
            case let .cancel(generation, reason):
                resetPredictionBatchAssembly()
                cancel(generation: generation)
                return .cancelled(
                    generation: generation,
                    reason: reason
                )
            }
        } catch let error as StrokeRenderCoordinatorError {
            cancelPreparedStroke(generation: message.generation)
            return .failed(
                generation: message.generation,
                failure: .coordinator(error)
            )
        } catch let error as BrushCornerEmitterError {
            cancelPreparedStroke(generation: message.generation)
            return .failed(
                generation: message.generation,
                failure: .cornerEmission(error)
            )
        } catch let error as AuthoritativeStrokeQueueError {
            cancelPreparedStroke(generation: message.generation)
            return .failed(
                generation: message.generation,
                failure: .authoritativeQueue(error)
            )
        } catch let error as StrokeFrameSchedulerError {
            cancelPreparedStroke(generation: message.generation)
            return .failed(
                generation: message.generation,
                failure: .scheduler(error)
            )
        } catch let error as DepositionStampPackingError {
            cancelPreparedStroke(generation: message.generation)
            return .failed(
                generation: message.generation,
                failure: .stampPacking(error)
            )
        } catch let error as StrokePrivateSurfaceEncodingError {
            cancelPreparedStroke(generation: message.generation)
            return .failed(
                generation: message.generation,
                failure: .privateSurfaceEncoding(error)
            )
        } catch let error as TransientStrokeBufferError {
            cancelPreparedStroke(generation: message.generation)
            return .failed(
                generation: message.generation,
                failure: .transientBuffer(error)
            )
        } catch let error as TransientStrokeDabArena.ReservationError {
            cancelPreparedStroke(generation: message.generation)
            if case let .capacityExceeded(maximum) = error {
                return .failed(
                    generation: message.generation,
                    failure: .dabArenaCapacityExceeded(
                        actual: maximum + 1,
                        maximum: maximum
                    )
                )
            }
            return .failed(
                generation: message.generation,
                failure: .unexpected(String(describing: error))
            )
        } catch {
            cancelPreparedStroke(generation: message.generation)
            return .failed(
                generation: message.generation,
                failure: .unexpected(String(describing: error))
            )
        }
    }

    private func resetPredictionBatchAssembly() {
        predictionBatchSampleScratch.removeAll(keepingCapacity: true)
        pendingPredictionBatchGeneration = nil
        pendingPredictionBatchCount = 0
        pendingPredictionBatchSubmittedCount = 0
    }

    func acknowledgePreparedFrame(
        generation: UInt64,
        frameToken: UInt64
    ) async -> StrokePreparationResult? {
        do {
            try requireActive(generation)
            let consumedCount: Int
            if let lease = outstandingSurfaceLease {
                guard lease.token == frameToken,
                      lease.generation == generation
                else {
                    throw StrokeFrameSchedulerError.invalidPreparedFrame
                }
                privateSurfaceEncoder?.acknowledge(lease)
                outstandingSurfaceLease = nil
                if let frame = outstandingFrame {
                    consumedCount = frame.authoritative.count
                        + frame.predicted.count
                    try markSubmitted(frame, generation: generation)
                } else {
                    consumedCount = 0
                }
            } else {
                guard let frame = outstandingFrame,
                      frame.token == frameToken
                else {
                    throw StrokeFrameSchedulerError.invalidPreparedFrame
                }
                consumedCount = frame.authoritative.count
                    + frame.predicted.count
                try markSubmitted(frame, generation: generation)
            }
            projectedCarry.removeFirst(consumedCount)
            if let next = try await makePreparedOutputBatch(
                generation: generation,
                logicalDabs: [],
                predictionProvenanceBoundary:
                    currentPredictionProvenanceBoundary,
                coordinatorSnapshot: preparationCoordinator?.snapshot,
                executorProbe: StrokePreparationExecutorProbe(
                    generatorRanOnMainThread: false,
                    projectionRanOnMainThread: false
                ),
                isFinishing: false,
                emitEmpty: false,
                predictionAdmission: nil
            ) {
                return .prepared(next)
            }
            if pendingCommitBarrierGeneration == generation {
                pendingCommitBarrierGeneration = nil
                return .commitBarrierReached(generation: generation)
            }
            return nil
        } catch let error as StrokeFrameSchedulerError {
            cancelPreparedStroke(generation: generation)
            return .failed(
                generation: generation,
                failure: .scheduler(error)
            )
        } catch let error as StrokePrivateSurfaceEncodingError {
            cancelPreparedStroke(generation: generation)
            return .failed(
                generation: generation,
                failure: .privateSurfaceEncoding(error)
            )
        } catch {
            cancelPreparedStroke(generation: generation)
            return .failed(
                generation: generation,
                failure: .unexpected(String(describing: error))
            )
        }
    }

    func begin(generation: UInt64) throws {
        guard activeGeneration == nil else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        scheduler.reset()
        activeGeneration = generation
        cancelledGeneration = nil
        commitRequested = false
        outstandingFrame = nil
        outstandingSurfaceLease = nil
        pendingCommitBarrierGeneration = nil
        maximumPreparationWorkUnitsPerFrame = 0
        preparationMutationRevision = 0
        preparationHasBegun = false
        preparationHasFinished = false
        #if DEBUG
        lastEstimatedUpdateSnapshot = nil
        #endif
        projectedCarry.reset()
    }

    /// Installs the actor-owned generator/deriver/projection state and prepares
    /// the first immutable deposition batch. The caller may be MainActor, but
    /// every operation after the copied message crosses this actor boundary.
    func beginPreparedStroke(
        generation: UInt64,
        configuration: StrokePreparationConfiguration,
        actualSamples: [StrokeSample]
    ) async throws -> StrokePreparedDepositionBatch {
        let preparationCPUStartedAt = DispatchTime.now().uptimeNanoseconds
        try begin(generation: generation)
        do {
            let coordinator = try StrokeRenderCoordinator(
                program: configuration.program,
                nominalDiameter: configuration.nominalDiameter,
                color: configuration.color,
                seed: configuration.seed,
                viewport: configuration.viewport,
                authoritativeCapacity:
                    budget.maximumPendingAuthoritativeInstances
            )
            preparationCoordinator = coordinator
            authoritativeGenerator = BrushStrokeGenerator(
                program: configuration.program,
                nominalDiameter: configuration.nominalDiameter,
                color: configuration.color,
                seed: configuration.seed
            )
            authoritativeInputDeriver = BrushInputDeriver()
            transientStrokeBuffer = TransientStrokeBuffer(
                replayContract: configuration.program.replayContract
            )
            transientDabArena.reset()
            preparationTilingStrategy = configuration.tilingStrategy
            preparationViewport = configuration.viewport
            if let descriptor = configuration.metalResourceDescriptor {
                reusablePrivateSurfaceEncoder.configure(descriptor)
                privateSurfaceEncoder = reusablePrivateSurfaceEncoder
            } else {
                privateSurfaceEncoder = nil
            }
            preparationAllocationProbe = configuration.allocationProbe
            let generatorRanOnMainThread = executionIsOnMainThread()
            return try await prepareActualMutation(
                generation: generation,
                samples: actualSamples,
                generatorRanOnMainThread: generatorRanOnMainThread,
                isFinishing: false,
                preparationCPUStartedAt: preparationCPUStartedAt
            )
        } catch {
            cancelPreparedStroke(generation: generation)
            throw error
        }
    }

    func appendPreparedStroke(
        generation: UInt64,
        actualSamples: [StrokeSample]
    ) async throws -> StrokePreparedDepositionBatch {
        try requireActive(generation)
        guard preparationCoordinator != nil else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        do {
            let generatorRanOnMainThread = executionIsOnMainThread()
            return try await prepareActualMutation(
                generation: generation,
                samples: actualSamples,
                generatorRanOnMainThread: generatorRanOnMainThread,
                isFinishing: false
            )
        } catch {
            cancelPreparedStroke(generation: generation)
            throw error
        }
    }

    private func appendPreparedStrokeSample(
        generation: UInt64,
        sample: StrokeSample
    ) async throws -> StrokePreparedDepositionBatch {
        try requireActive(generation)
        guard preparationCoordinator != nil else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        do {
            let generatorRanOnMainThread = executionIsOnMainThread()
            singleActualSampleScratch.removeAll(keepingCapacity: true)
            singleActualSampleScratch.append(sample)
            return try await prepareActualMutation(
                generation: generation,
                samples: singleActualSampleScratch,
                generatorRanOnMainThread: generatorRanOnMainThread,
                isFinishing: false
            )
        } catch {
            cancelPreparedStroke(generation: generation)
            throw error
        }
    }

    func finishPreparedStroke(
        generation: UInt64,
        actualSamples: [StrokeSample]
    ) async throws -> StrokePreparedDepositionBatch {
        try requireActive(generation)
        guard preparationCoordinator != nil else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        do {
            let generatorRanOnMainThread = executionIsOnMainThread()
            return try await prepareActualMutation(
                generation: generation,
                samples: actualSamples,
                generatorRanOnMainThread: generatorRanOnMainThread,
                isFinishing: true
            )
        } catch {
            cancelPreparedStroke(generation: generation)
            throw error
        }
    }

    func replacePreparedPrediction(
        generation: UInt64,
        samples: [StrokeSample],
        acceptedCount: Int? = nil,
        submittedSampleCount: Int? = nil
    ) async throws -> StrokePreparedDepositionBatch {
        let preparationCPUStartedAt = DispatchTime.now().uptimeNanoseconds
        let allocationProbe = preparationAllocationProbe
        allocationProbe?.arm()
        var allocationProbeIsArmed = allocationProbe != nil
        defer {
            if allocationProbeIsArmed {
                allocationProbe?.disarmAndRecord(.predictionCPU)
            }
        }
        try requireActive(generation)
        let mailboxAcceptedSampleCount = min(
            samples.count,
            acceptedCount ?? samples.count
        )
        let submittedSampleCount = submittedSampleCount ?? samples.count
        guard !commitRequested,
              submittedSampleCount >= mailboxAcceptedSampleCount,
              let coordinator = preparationCoordinator,
              let authoritativeGenerator,
              let currentAuthoritativeInputDeriver =
                authoritativeInputDeriver,
              var candidateBuffer = transientStrokeBuffer,
              let strategy = preparationTilingStrategy,
              let viewport = preparationViewport,
              samples.prefix(mailboxAcceptedSampleCount).allSatisfy({
                  $0.kind == .predicted && $0.phase == .moved
              })
        else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        transientStrokeBuffer = nil

        let replayLimits = candidateBuffer.activeReplayLimits
        let retainedActualProjectedCount =
            candidateBuffer.actualChunks.reduce(0) {
                $0 + $1.projectedInstanceCount
            }
        let maximumPredictionSamples = min(
            PredictionOverlay.maximumNormalizedSampleCount,
            max(
                0,
                replayLimits.maximumSamples
                    - candidateBuffer.actualSampleCount
            )
        )
        let maximumPredictionDabs = min(
            PredictionOverlay.maximumLogicalDabCount,
            max(
                0,
                replayLimits.maximumDabs
                    - candidateBuffer.actualDabCount
            )
        )
        let maximumPredictionProjectedInstances = min(
            budget.maximumPredictedInstances,
            min(
                max(
                    0,
                    replayLimits.maximumProjectedInstances
                        - retainedActualProjectedCount
                ),
                max(
                    0,
                    scheduler.predictedCapacity
                        - retainedActualProjectedCount
                )
            )
        )
        let boundedSampleCount = min(
            mailboxAcceptedSampleCount,
            maximumPredictionSamples
        )
        var overload: PredictionOverloadReasons = []
        if submittedSampleCount > boundedSampleCount {
            overload.insert(.normalizedSamples)
        }
        let admittedSamples = samples.prefix(boundedSampleCount)
        var generator = authoritativeGenerator
        var deriver = currentAuthoritativeInputDeriver
        generatedLogicalDabScratch.removeAll(keepingCapacity: true)
        transientDabScratch.removeAll(keepingCapacity: true)
        transientChunkScratch.removeAll(keepingCapacity: true)
        settledChunkScratch.removeAll(keepingCapacity: true)
        generatedProjectionScratch.removeAll(keepingCapacity: true)
        var acceptedSampleCount = 0
        var predictionIsFull = false
        let generatorRanOnMainThread = executionIsOnMainThread()
        var projectionRanOnMainThread = false
        let arenaTransaction = try transientDabArena.beginTransaction(
            replacingPrediction: true
        )
        defer { arenaTransaction.rollback() }

        for sample in admittedSamples {
            guard !predictionIsFull else { break }
            var candidateDeriver = deriver
            var candidateGenerator = generator
            let inputBefore = candidateDeriver
            let worldSample = candidateDeriver.deriveAdvancingPrediction(
                sample,
                viewport: viewport
            )
            let generatorBefore = candidateGenerator
            perSampleLogicalDabScratch.removeAll(keepingCapacity: true)
            let transientStart = transientDabScratch.count
            do {
                let remainingDabCapacity = max(
                    0,
                    maximumPredictionDabs
                        - generatedLogicalDabScratch.count
                )
                let interpolationOutcome = try candidateGenerator
                    .appendPredictionPrefix(
                        worldSample,
                        maximumPathSubdivisionCount:
                            Self.maximumPathSubdivisionCount(
                                forRemainingDabCapacity:
                                    remainingDabCapacity
                            )
                    ) { dab in
                        guard perSampleLogicalDabScratch.count
                            < remainingDabCapacity
                        else {
                            throw StrokePredictionGenerationLimitReached(
                                reason: .logicalDabs
                            )
                        }
                        projectionRanOnMainThread = projectionRanOnMainThread
                            || executionIsOnMainThread()
                        let dabProjectedStart =
                            generatedProjectionScratch.count
                        do {
                            try appendProjectedRecords(
                                for: dab,
                                strategy: strategy,
                                to: &generatedProjectionScratch,
                                maximumRecordCount:
                                    maximumPredictionProjectedInstances
                            )
                        } catch let error as StrokeFrameSchedulerError {
                            guard case .projectedInstanceCapacityExceeded =
                                error else { throw error }
                            throw StrokePredictionGenerationLimitReached(
                                reason: .projectedInstances
                            )
                        }
                        perSampleLogicalDabScratch.append(dab)
                        transientDabScratch.append(
                            TransientStrokeDab(
                                attributes: dab,
                                projectedInstanceCount:
                                    generatedProjectionScratch.count
                                        - dabProjectedStart
                            )
                        )
                    }
                if interpolationOutcome == .truncated {
                    overload.insert(.logicalDabs)
                    predictionIsFull = true
                }
            } catch let limit as StrokePredictionGenerationLimitReached {
                overload.insert(limit.reason)
                predictionIsFull = true
            } catch is StrokePathInterpolationError {
                overload.insert(.logicalDabs)
                predictionIsFull = true
            }
            let transientCount = transientDabScratch.count - transientStart
            let slice = try arenaTransaction.storePredicted(
                count: transientCount
            ) { offset in
                transientDabScratch[transientStart + offset]
            }
            transientChunkScratch.append(
                TransientStrokeChunk(
                    sample: worldSample,
                    dabs: slice,
                    generatorSnapshotBeforeSample: generatorBefore,
                    generatorSnapshotAfterSample: candidateGenerator,
                    inputDeriverSnapshotBeforeSample: inputBefore
                )
            )
            generatedLogicalDabScratch.append(
                contentsOf: perSampleLogicalDabScratch
            )
            generator = candidateGenerator
            deriver = candidateDeriver
            acceptedSampleCount += 1
            if predictionIsFull { break }
        }
        if acceptedSampleCount < admittedSamples.count,
           !overload.contains(.logicalDabs),
           !overload.contains(.projectedInstances)
        {
            overload.insert(.normalizedSamples)
        }

        _ = try candidateBuffer.replacePredicted(
            with: transientChunkScratch,
            settledInto: &settledChunkScratch
        )
        authoritativeProjectedScratch.removeAll(keepingCapacity: true)
        replayProjectedScratch.removeAll(keepingCapacity: true)
        try appendProjectedChunks(
            settledChunkScratch,
            to: &authoritativeProjectedScratch,
            maximumRecordCount:
                budget.maximumPendingAuthoritativeInstances
        )
        try appendProjectedChunks(
            candidateBuffer.actualChunks,
            to: &replayProjectedScratch,
            maximumRecordCount:
                budget.maximumPendingPredictedInstances
        )
        try appendProjectedChunks(
            candidateBuffer.predictedChunks,
            to: &replayProjectedScratch,
            maximumRecordCount:
                budget.maximumPendingPredictedInstances
        )
        try preflightPreparedMutation(
            generation: generation,
            authoritative: authoritativeProjectedScratch,
            replay: replayProjectedScratch
        )
        let transfer = settledChunkScratch.isEmpty
            ? nil
            : try coordinator.prepareSettledReplayTransfer(
                settledChunkScratch
            )
        if let transfer {
            try coordinator.reserveForDownstreamAcceptance(
                transfer,
                retireAfterAcceptance: true
            )
        }
        installPreparedQueues(
            authoritative: authoritativeProjectedScratch,
            replay: replayProjectedScratch
        )
        if let transfer {
            coordinator.finalizeAndRetireAfterDownstreamAcceptance(transfer)
        }
        transientStrokeBuffer = candidateBuffer
        try arenaTransaction.commit(
            retainingActual: candidateBuffer.actualChunks,
            retainingPredicted: candidateBuffer.predictedChunks
        )
        privateSurfaceEncoder?.beginPredictionReplacement()
        let acceptedProjectedCount = replayDepositionScratch.reduce(
            into: 0
        ) { count, record in
            if record.isPredicted { count += 1 }
        }
        if acceptedProjectedCount
            < generatedProjectionScratch.count
        {
            overload.insert(.projectedInstances)
        }
        allocationProbe?.disarmAndRecord(.predictionCPU)
        allocationProbeIsArmed = false
        let preparationCPUNanoseconds =
            DispatchTime.now().uptimeNanoseconds
                - preparationCPUStartedAt
        return try await makePreparedOutputBatch(
            generation: generation,
            logicalDabs: generatedLogicalDabScratch,
            predictionProvenanceBoundary:
                currentPredictionProvenanceBoundary,
            coordinatorSnapshot: coordinator.snapshot,
            executorProbe: StrokePreparationExecutorProbe(
                generatorRanOnMainThread: generatorRanOnMainThread,
                projectionRanOnMainThread: projectionRanOnMainThread
            ),
            isFinishing: false,
            emitEmpty: true,
            predictionAdmission: PredictionOverlayAdmission(
                normalizedSampleCount: acceptedSampleCount,
                logicalDabCount: generatedLogicalDabScratch.count,
                projectedInstanceCount:
                    acceptedProjectedCount,
                overload: overload
            ),
            preparationCPUNanoseconds: preparationCPUNanoseconds
        )!
    }

    private func applyPreparedEstimatedUpdate(
        generation: UInt64,
        sample: StrokeSample
    ) async throws -> StrokePreparationResult {
        let preparationCPUStartedAt = DispatchTime.now().uptimeNanoseconds
        let allocationProbe = preparationAllocationProbe
        allocationProbe?.arm()
        var allocationProbeIsArmed = allocationProbe != nil
        defer {
            if allocationProbeIsArmed {
                allocationProbe?.disarmAndRecord(.estimatedCPU)
            }
        }
        try requireActive(generation)
        guard !commitRequested,
              sample.kind == .estimatedUpdate,
              let viewport = preparationViewport,
              let strategy = preparationTilingStrategy,
              let coordinator = preparationCoordinator,
              let currentAuthoritativeInputDeriver =
                authoritativeInputDeriver,
              var candidateBuffer = transientStrokeBuffer
        else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        var updateDeriver = currentAuthoritativeInputDeriver
        let update = updateDeriver.derive(sample, viewport: viewport)
        let plan: BorrowedEstimatedStrokeUpdatePlan
        do {
            plan = try candidateBuffer.planEstimatedUpdate(
                update,
                replacementSamplesInto:
                    &estimatedReplacementSampleScratch
            )
        } catch let error as TransientStrokeBufferError {
            switch error {
            case .unknownEstimatedUpdateIndex,
                 .estimatedUpdateAlreadyResolved:
                return .estimatedUpdateWasIgnored(
                    generation: generation,
                    error: error
                )
            default:
                return .estimatedUpdateWasRejected(
                    generation: generation,
                    error: error,
                    capacityFailure: capacityFailure(
                        for: error,
                        limits: candidateBuffer.activeReplayLimits
                    )
                )
            }
        }
        guard var replayGenerator = plan.generatorBeforeReplacement
        else {
            throw StrokeFrameSchedulerError.missingGeneratorCheckpoint
        }
        var replayDeriver = plan.inputDeriverBeforeReplacement
            ?? BrushInputDeriver()
        let isPredictedReplay = plan.target == .predicted
        let retainedPredictedPrefix = isPredictedReplay
            ? candidateBuffer.predictedChunks[..<plan.replacedChunkIndex]
            : candidateBuffer.predictedChunks[..<0]
        let retainedPredictionDabCount = retainedPredictedPrefix.reduce(0) {
            $0 + $1.dabs.count
        }
        let retainedPredictionProjectedCount =
            retainedPredictedPrefix.reduce(0) {
                $0 + $1.projectedInstanceCount
            }
        let retainedActualProjectedCount =
            candidateBuffer.actualChunks.reduce(0) {
                $0 + $1.projectedInstanceCount
            }
        let replayLimits = candidateBuffer.activeReplayLimits
        let maximumReplacementDabCount = max(
            0,
            min(
                PredictionOverlay.maximumLogicalDabCount
                    - retainedPredictionDabCount,
                replayLimits.maximumDabs
                    - candidateBuffer.actualDabCount
                    - retainedPredictionDabCount
            )
        )
        let maximumReplacementProjectedCount = max(
            0,
            min(
                min(
                    budget.maximumPredictedInstances
                        - retainedPredictionProjectedCount,
                    replayLimits.maximumProjectedInstances
                        - retainedActualProjectedCount
                        - retainedPredictionProjectedCount
                ),
                scheduler.predictedCapacity
                    - retainedActualProjectedCount
                    - retainedPredictionProjectedCount
            )
        )
        let maximumAuthoritativeReplacementDabCount =
            TransientStrokeBufferContract.wholeStrokeDabCapacity
        let maximumAuthoritativeReplacementProjectedCount =
            budget.maximumPendingAuthoritativeInstances

        transientDabScratch.removeAll(keepingCapacity: true)
        transientChunkScratch.removeAll(keepingCapacity: true)
        settledChunkScratch.removeAll(keepingCapacity: true)
        generatedLogicalDabScratch.removeAll(keepingCapacity: true)
        generatedProjectionScratch.removeAll(keepingCapacity: true)
        let arenaTransaction: TransientStrokeDabArena.ReservationTransaction
        do {
            arenaTransaction = try transientDabArena.beginTransaction(
                replacingPrediction: isPredictedReplay
            )
        } catch {
            return .estimatedUpdateWasRejected(
                generation: generation,
                error: .invalidEstimatedReplacement,
                capacityFailure: nil
            )
        }
        defer { arenaTransaction.rollback() }
        var generatedPredictionDabCount = 0
        var generatedPredictionProjectedCount = 0
        var predictionWasTruncated = false
        var predictionOverload: PredictionOverloadReasons = []
        var projectionRanOnMainThread = false
        var rederivedSampleCount = 0
        let replacementPreview: BorrowedEstimatedStrokeUpdatePreview

        do {
            for sampleIndex in estimatedReplacementSampleScratch.indices {
                let plannedSample =
                    estimatedReplacementSampleScratch[sampleIndex]
                let inputBefore = replayDeriver
                let replayedSample = replayDeriver.rederive(plannedSample)
                estimatedReplacementSampleScratch[sampleIndex] =
                    replayedSample
                rederivedSampleCount += 1
                let generatorBefore = replayGenerator
                var candidateGenerator = replayGenerator
                perSampleLogicalDabScratch.removeAll(keepingCapacity: true)
                let transientStart = transientDabScratch.count
                if isPredictedReplay, !predictionWasTruncated {
                    let priorGeneratedPredictionDabCount =
                        generatedPredictionDabCount
                    let projectionExecutionRanOnMainThread =
                        executionIsOnMainThread()
                    let remainingDabCapacity = max(
                        0,
                        maximumReplacementDabCount
                            - priorGeneratedPredictionDabCount
                    )
                    if remainingDabCapacity == 0 {
                        predictionWasTruncated = true
                        predictionOverload.insert(.logicalDabs)
                    } else if maximumReplacementProjectedCount == 0 {
                        predictionWasTruncated = true
                        predictionOverload.insert(.projectedInstances)
                    } else {
                        do {
                            let maximumPathSubdivisionCount =
                                Self.maximumPathSubdivisionCount(
                                    forRemainingDabCapacity:
                                        remainingDabCapacity
                                )
                            let interpolationOutcome:
                                StrokePathInterpolationOutcome
                            switch replayedSample.phase {
                            case .began:
                                try candidateGenerator.begin(replayedSample) {
                                    dab in
                                    try self.appendPreparedEstimatedPredictionDab(
                                        dab,
                                        strategy: strategy,
                                        remainingDabCapacity:
                                            remainingDabCapacity,
                                        maximumProjectedCount:
                                            maximumReplacementProjectedCount
                                    )
                                }
                                interpolationOutcome = .completed
                            case .moved:
                                interpolationOutcome = try candidateGenerator
                                    .appendPredictionPrefix(
                                        replayedSample,
                                        maximumPathSubdivisionCount:
                                            maximumPathSubdivisionCount
                                    ) { dab in
                                        try self.appendPreparedEstimatedPredictionDab(
                                            dab,
                                            strategy: strategy,
                                            remainingDabCapacity:
                                                remainingDabCapacity,
                                            maximumProjectedCount:
                                                maximumReplacementProjectedCount
                                        )
                                    }
                            case .ended:
                                interpolationOutcome = try candidateGenerator
                                    .finishPredictionPrefix(
                                        replayedSample,
                                        maximumPathSubdivisionCount:
                                            maximumPathSubdivisionCount
                                    ) { dab in
                                        try self.appendPreparedEstimatedPredictionDab(
                                            dab,
                                            strategy: strategy,
                                            remainingDabCapacity:
                                                remainingDabCapacity,
                                            maximumProjectedCount:
                                                maximumReplacementProjectedCount
                                        )
                                    }
                            case .cancelled:
                                throw StrokeFrameSchedulerError
                                    .invalidLifecycle
                            }
                            if interpolationOutcome == .truncated {
                                predictionWasTruncated = true
                                predictionOverload.insert(.logicalDabs)
                            }
                        } catch let limit
                            as StrokePredictionGenerationLimitReached
                        {
                            predictionWasTruncated = true
                            predictionOverload.insert(limit.reason)
                        } catch is StrokePathInterpolationError {
                            predictionWasTruncated = true
                            predictionOverload.insert(.logicalDabs)
                        }
                    }
                    if !perSampleLogicalDabScratch.isEmpty {
                        projectionRanOnMainThread =
                            projectionRanOnMainThread
                                || projectionExecutionRanOnMainThread
                    }
                    replayGenerator = candidateGenerator
                } else if !isPredictedReplay {
                    let projectionExecutionRanOnMainThread =
                        executionIsOnMainThread()
                    let remainingDabCapacity = max(
                        0,
                        maximumAuthoritativeReplacementDabCount
                            - generatedLogicalDabScratch.count
                    )
                    do {
                        let maximumPathSubdivisionCount =
                            Self.maximumPathSubdivisionCount(
                                forRemainingDabCapacity:
                                    remainingDabCapacity
                            )
                        switch replayedSample.phase {
                        case .began:
                            try candidateGenerator.begin(replayedSample) {
                                dab in
                                try self.appendPreparedEstimatedActualDab(
                                    dab,
                                    strategy: strategy,
                                    remainingDabCapacity:
                                        remainingDabCapacity,
                                    maximumDabCount:
                                        maximumAuthoritativeReplacementDabCount,
                                    maximumProjectedCount:
                                        maximumAuthoritativeReplacementProjectedCount
                                )
                            }
                        case .moved:
                            try candidateGenerator.append(
                                replayedSample,
                                maximumPathSubdivisionCount:
                                    maximumPathSubdivisionCount
                            ) { dab in
                                try self.appendPreparedEstimatedActualDab(
                                    dab,
                                    strategy: strategy,
                                    remainingDabCapacity:
                                        remainingDabCapacity,
                                    maximumDabCount:
                                        maximumAuthoritativeReplacementDabCount,
                                    maximumProjectedCount:
                                        maximumAuthoritativeReplacementProjectedCount
                                )
                            }
                        case .ended:
                            try candidateGenerator.finish(
                                replayedSample,
                                maximumPathSubdivisionCount:
                                    maximumPathSubdivisionCount
                            ) { dab in
                                try self.appendPreparedEstimatedActualDab(
                                    dab,
                                    strategy: strategy,
                                    remainingDabCapacity:
                                        remainingDabCapacity,
                                    maximumDabCount:
                                        maximumAuthoritativeReplacementDabCount,
                                    maximumProjectedCount:
                                        maximumAuthoritativeReplacementProjectedCount
                                )
                            }
                        case .cancelled:
                            throw StrokeFrameSchedulerError.invalidLifecycle
                        }
                    } catch is StrokePathInterpolationError {
                        throw StrokeFrameSchedulerError
                            .generatedDabCapacityExceeded(
                                actual:
                                    maximumAuthoritativeReplacementDabCount
                                        + 1,
                                maximum:
                                    maximumAuthoritativeReplacementDabCount
                            )
                    }
                    if !perSampleLogicalDabScratch.isEmpty {
                        projectionRanOnMainThread =
                            projectionRanOnMainThread
                                || projectionExecutionRanOnMainThread
                    }
                    replayGenerator = candidateGenerator
                }
                let transientCount = transientDabScratch.count
                    - transientStart
                let slice = isPredictedReplay
                    ? try arenaTransaction.storePredicted(
                        count: transientCount
                    ) { offset in
                        transientDabScratch[transientStart + offset]
                    }
                    : try arenaTransaction.storeActual(
                        count: transientCount
                    ) { offset in
                        transientDabScratch[transientStart + offset]
                    }
                transientChunkScratch.append(
                    TransientStrokeChunk(
                        sample: replayedSample,
                        dabs: slice,
                        generatorSnapshotBeforeSample: generatorBefore,
                        generatorSnapshotAfterSample: replayGenerator,
                        inputDeriverSnapshotBeforeSample: inputBefore
                    )
                )
                generatedLogicalDabScratch.append(
                    contentsOf: perSampleLogicalDabScratch
                )
                if isPredictedReplay {
                    generatedPredictionDabCount +=
                        perSampleLogicalDabScratch.count
                    generatedPredictionProjectedCount +=
                        transientChunkScratch.last?
                            .projectedInstanceCount ?? 0
                }
            }

            replacementPreview = try candidateBuffer.previewEstimatedSuffix(
                using: plan,
                expectedSamples: estimatedReplacementSampleScratch,
                with: transientChunkScratch,
                settledInto: &settledChunkScratch,
                retainedActualInto: &estimatedRetainedActualScratch,
                retainedPredictedInto:
                    &estimatedRetainedPredictionScratch
            )
            authoritativeProjectedScratch.removeAll(keepingCapacity: true)
            replayProjectedScratch.removeAll(keepingCapacity: true)
            try appendProjectedChunks(
                settledChunkScratch,
                to: &authoritativeProjectedScratch,
                maximumRecordCount:
                    budget.maximumPendingAuthoritativeInstances
            )
            try appendProjectedChunks(
                estimatedRetainedActualScratch.dropFirst(
                    settledChunkScratch.count
                ),
                to: &replayProjectedScratch,
                maximumRecordCount:
                    budget.maximumPendingPredictedInstances
            )
            try appendProjectedChunks(
                estimatedRetainedPredictionScratch,
                to: &replayProjectedScratch,
                maximumRecordCount:
                    budget.maximumPendingPredictedInstances
            )
            try preflightPreparedMutation(
                generation: generation,
                authoritative: authoritativeProjectedScratch,
                replay: replayProjectedScratch
            )
        } catch let error as TransientStrokeBufferError {
            return .estimatedUpdateWasRejected(
                generation: generation,
                error: error,
                capacityFailure: capacityFailure(
                    for: error,
                    limits: replayLimits
                )
            )
        } catch let error as StrokeFrameSchedulerError {
            switch error {
            case let .authoritativeCapacityExceeded(
                _,
                current,
                incoming,
                maximum
            ):
                return .estimatedUpdateWasRejected(
                    generation: generation,
                    error: .unresolvedSuffixExceedsCapacity(
                        sampleCount: candidateBuffer.actualSampleCount,
                        dabCount: candidateBuffer.actualDabCount,
                        projectedInstanceCount: incoming
                    ),
                    capacityFailure: .projectedInstances(
                        actual: Self.saturatingAdd(current, incoming),
                        maximum: maximum
                    )
                )
            case let .replayCapacityExceeded(actual, maximum):
                return .estimatedUpdateWasRejected(
                    generation: generation,
                    error: .predictedSuffixExceedsCapacity(
                        sampleCount: candidateBuffer.retainedSampleCount,
                        dabCount: candidateBuffer.retainedDabCount,
                        projectedInstanceCount: actual
                    ),
                    capacityFailure: .projectedInstances(
                        actual: actual,
                        maximum: maximum
                    )
                )
            case let .strokeSampleCapacityExceeded(actual, maximum):
                return .estimatedUpdateWasRejected(
                    generation: generation,
                    error: .unresolvedSuffixExceedsCapacity(
                        sampleCount: actual,
                        dabCount: candidateBuffer.actualDabCount,
                        projectedInstanceCount:
                            candidateBuffer.visibleProjectedInstanceCount
                    ),
                    capacityFailure: .strokeSamples(
                        actual: actual,
                        maximum: maximum
                    )
                )
            case let .generatedDabCapacityExceeded(actual, maximum):
                return .estimatedUpdateWasRejected(
                    generation: generation,
                    error: .unresolvedSuffixExceedsCapacity(
                        sampleCount: candidateBuffer.actualSampleCount,
                        dabCount: actual,
                        projectedInstanceCount:
                            candidateBuffer.visibleProjectedInstanceCount
                    ),
                    capacityFailure: .generatedDabs(
                        actual: actual,
                        maximum: maximum
                    )
                )
            case let .projectedInstanceCapacityExceeded(actual, maximum):
                return .estimatedUpdateWasRejected(
                    generation: generation,
                    error: .unresolvedSuffixExceedsCapacity(
                        sampleCount: candidateBuffer.actualSampleCount,
                        dabCount: candidateBuffer.actualDabCount,
                        projectedInstanceCount: actual
                    ),
                    capacityFailure: .projectedInstances(
                        actual: actual,
                        maximum: maximum
                    )
                )
            default:
                throw error
            }
        } catch let error as TransientStrokeDabArena.ReservationError {
            let maximum: Int
            if case let .capacityExceeded(capacity) = error {
                maximum = capacity
            } else {
                throw error
            }
            return .estimatedUpdateWasRejected(
                generation: generation,
                error: .predictedSuffixExceedsCapacity(
                    sampleCount: candidateBuffer.retainedSampleCount,
                    dabCount: candidateBuffer.retainedDabCount,
                    projectedInstanceCount:
                        candidateBuffer.visibleProjectedInstanceCount
                ),
                capacityFailure: .generatedDabs(
                    actual: maximum + 1,
                    maximum: maximum
                )
            )
        }

        let transfer = settledChunkScratch.isEmpty
            ? nil
            : try coordinator.prepareSettledReplayTransfer(
                settledChunkScratch
            )
        if let transfer {
            try coordinator.reserveForDownstreamAcceptance(
                transfer,
                retireAfterAcceptance: true
            )
        }
        try arenaTransaction.commit(
            retainingActual: estimatedRetainedActualScratch,
            retainingPredicted: estimatedRetainedPredictionScratch
        )
        transientStrokeBuffer = nil
        _ = candidateBuffer.replaceEstimatedSuffixPrevalidated(
            using: plan,
            with: transientChunkScratch,
            preview: replacementPreview,
            settledInto: &settledChunkScratch
        )
        installPreparedQueues(
            authoritative: authoritativeProjectedScratch,
            replay: replayProjectedScratch
        )
        if let transfer {
            coordinator.finalizeAndRetireAfterDownstreamAcceptance(transfer)
        }
        transientStrokeBuffer = candidateBuffer
        if plan.target == .authoritative {
            authoritativeGenerator = replayGenerator
            authoritativeInputDeriver = replayDeriver
            preparationMutationRevision &+= 1
        }
        #if DEBUG
        lastEstimatedUpdateSnapshot = StrokeEstimatedUpdateDiagnosticSnapshot(
            target: plan.target,
            mergedSample:
                estimatedReplacementSampleScratch.first
                    ?? plan.mergedSample,
            rederivedSampleCount: rederivedSampleCount,
            mutationVersion: candidateBuffer.mutationVersion
        )
        #endif
        let needsPredictionReplacement =
            !replayProjectedScratch.isEmpty
                || authoritativeProjectedScratch.isEmpty
        if needsPredictionReplacement {
            privateSurfaceEncoder?.beginPredictionReplacement()
        }
        allocationProbe?.disarmAndRecord(.estimatedCPU)
        allocationProbeIsArmed = false
        let preparationCPUNanoseconds =
            DispatchTime.now().uptimeNanoseconds
                - preparationCPUStartedAt
        return .prepared(
            try await makePreparedOutputBatch(
                generation: generation,
                logicalDabs: generatedLogicalDabScratch,
                predictionProvenanceBoundary:
                    currentPredictionProvenanceBoundary,
                coordinatorSnapshot: coordinator.snapshot,
                executorProbe: StrokePreparationExecutorProbe(
                    generatorRanOnMainThread: false,
                    projectionRanOnMainThread:
                        projectionRanOnMainThread
                ),
                isFinishing: preparationHasFinished,
                emitEmpty: true,
                predictionAdmission: isPredictedReplay
                    ? PredictionOverlayAdmission(
                        normalizedSampleCount:
                            candidateBuffer.predictedSampleCount,
                        logicalDabCount:
                            candidateBuffer.predictedDabCount,
                        projectedInstanceCount:
                            retainedPredictionProjectedCount
                                + generatedPredictionProjectedCount,
                        overload: predictionOverload
                    )
                    : nil,
                forcedSurfaceLayer:
                    authoritativeProjectedScratch.isEmpty
                        && replayProjectedScratch.isEmpty
                        ? .prediction
                        : nil,
                preparationCPUNanoseconds: preparationCPUNanoseconds
            )!
        )
    }

    func enqueueAuthoritative(
        _ records: [ProjectedDepositionRecord],
        generation: UInt64
    ) throws {
        try requireActive(generation)
        guard !commitRequested else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        do {
            try scheduler.enqueueAuthoritative(records)
        } catch let error as FrameSchedulerError {
            guard case let .authoritativeCapacityExceeded(
                current,
                incoming,
                maximum
            ) = error else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
            cancelCurrentGeneration(generation)
            throw StrokeFrameSchedulerError.authoritativeCapacityExceeded(
                generation: generation,
                current: current,
                incoming: incoming,
                maximum: maximum
            )
        }
    }

    func replacePrediction(
        _ records: [ProjectedDepositionRecord],
        generation: UInt64
    ) throws -> PredictionReplacementResult {
        try requireActive(generation)
        guard !commitRequested else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        return try scheduler.replacePrediction(records)
    }

    func requestCommit(generation: UInt64) throws {
        try requireActive(generation)
        guard !commitRequested else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        if let coordinator = preparationCoordinator,
           let buffer = transientStrokeBuffer
        {
            settledChunkScratch.removeAll(keepingCapacity: true)
            settledChunkScratch.append(contentsOf: buffer.actualChunks)
            authoritativeProjectedScratch.removeAll(keepingCapacity: true)
            replayProjectedScratch.removeAll(keepingCapacity: true)
            try appendProjectedChunks(
                settledChunkScratch,
                to: &authoritativeProjectedScratch,
                maximumRecordCount:
                    budget.maximumPendingAuthoritativeInstances
            )
            try preflightPreparedMutation(
                generation: generation,
                authoritative: authoritativeProjectedScratch,
                replay: replayProjectedScratch
            )
            let transfer = settledChunkScratch.isEmpty
                ? nil
                : try coordinator.prepareSettledReplayTransfer(
                    settledChunkScratch
                )
            if let transfer {
                try coordinator.reserveForDownstreamAcceptance(
                    transfer,
                    retireAfterAcceptance: true
                )
            }
            installPreparedQueues(
                authoritative: authoritativeProjectedScratch,
                replay: replayProjectedScratch
            )
            if let transfer {
                coordinator.finalizeAndRetireAfterDownstreamAcceptance(
                    transfer
                )
            }
            transientStrokeBuffer?.cancel()
            transientDabArena.reset()
            if authoritativeProjectedScratch.isEmpty {
                privateSurfaceEncoder?.beginPredictionReplacement()
            }
        } else {
            _ = try scheduler.prepareReplayForCommit()
        }
        commitRequested = true
    }

    func prepareFrame(
        generation: UInt64
    ) throws -> StrokeScheduledFrame? {
        try requireActive(generation)
        guard outstandingFrame == nil else {
            throw StrokeFrameSchedulerError.invalidPreparedFrame
        }
        let includePrediction = scheduler.authoritativeIsDrained
        let scheduled = scheduler.preparedFrame(
            budget: budget,
            includePrediction: includePrediction,
            authoritativeScratch: &authoritativeScratch,
            predictedScratch: &predictedScratch
        )
        guard !scheduled.authoritative.isEmpty
            || !scheduled.predicted.isEmpty
        else {
            return nil
        }
        let token = nextFrameToken
        let (successor, overflow) = token.addingReportingOverflow(1)
        guard !overflow else {
            throw StrokeFrameSchedulerError.frameTokenOverflow
        }
        nextFrameToken = successor
        let frame = StrokeScheduledFrame(
            authoritative: scheduled.authoritative,
            predicted: scheduled.predicted,
            authoritativeRemaining: scheduled.authoritativeRemaining,
            predictedRemaining: scheduled.predictedRemaining,
            targetFrameDurationNanoseconds:
                targetFrameDurationNanoseconds,
            token: token
        )
        maximumPreparationWorkUnitsPerFrame = max(
            maximumPreparationWorkUnitsPerFrame,
            frame.authoritative.count + frame.predicted.count
        )
        outstandingFrame = frame
        return frame
    }

    func markSubmitted(
        _ frame: StrokeScheduledFrame,
        generation: UInt64
    ) throws {
        try requireActive(generation)
        guard outstandingFrame == frame else {
            throw StrokeFrameSchedulerError.invalidPreparedFrame
        }
        scheduler.consume(
            ScheduledDepositionFrame(
                authoritative: frame.authoritative,
                predicted: frame.predicted,
                authoritativeRemaining: frame.authoritativeRemaining,
                predictedRemaining: frame.predictedRemaining
            )
        )
        outstandingFrame = nil
    }

    func abandon(
        _ frame: StrokeScheduledFrame,
        generation: UInt64
    ) throws {
        try requireActive(generation)
        guard outstandingFrame == frame else {
            throw StrokeFrameSchedulerError.invalidPreparedFrame
        }
        outstandingFrame = nil
    }

    func isCommitReady(generation: UInt64) -> Bool {
        guard activeGeneration == generation else { return false }
        return commitRequested
            && scheduler.authoritativeIsDrained
            && scheduler.predictedCount == 0
            && outstandingFrame == nil
    }

    func cancel(generation: UInt64) {
        guard activeGeneration == generation else { return }
        cancelPreparedStroke(generation: generation)
    }

    /// Generates one authoritative input message against actor-owned tentative
    /// state. Only chunks whose estimated properties are fully resolved cross
    /// the coordinator/authoritative-surface boundary; the unresolved suffix
    /// remains replaceable on the private replay surface.
    private func prepareActualMutation(
        generation: UInt64,
        samples: [StrokeSample],
        generatorRanOnMainThread: Bool,
        isFinishing: Bool,
        preparationCPUStartedAt: UInt64? = nil
    ) async throws -> StrokePreparedDepositionBatch {
        let preparationCPUStartedAt = preparationCPUStartedAt
            ?? DispatchTime.now().uptimeNanoseconds
        let allocationProbe = preparationAllocationProbe
        allocationProbe?.arm()
        var allocationProbeIsArmed = allocationProbe != nil
        defer {
            if allocationProbeIsArmed {
                allocationProbe?.disarmAndRecord(.authoritativeCPU)
            }
        }
        try requireActive(generation)
        guard !commitRequested,
              let coordinator = preparationCoordinator,
              var candidateGenerator = authoritativeGenerator,
              var candidateDeriver = authoritativeInputDeriver,
              var candidateBuffer = transientStrokeBuffer,
              let viewport = preparationViewport,
              let strategy = preparationTilingStrategy,
              !samples.isEmpty,
              samples.allSatisfy({
                  $0.kind == .actual || $0.kind == .coalesced
              })
        else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        transientStrokeBuffer = nil
        if !preparationHasBegun {
            guard samples.first?.phase == .began,
                  samples.dropFirst().allSatisfy({
                      $0.phase == .moved
                  })
            else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
        } else if isFinishing {
            guard !preparationHasFinished,
                  samples.last?.phase == .ended,
                  samples.dropLast().allSatisfy({ $0.phase == .moved })
            else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
        } else {
            guard !preparationHasFinished,
                  samples.allSatisfy({ $0.phase == .moved })
            else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
        }

        transientDabScratch.removeAll(keepingCapacity: true)
        transientChunkScratch.removeAll(keepingCapacity: true)
        settledChunkScratch.removeAll(keepingCapacity: true)
        generatedLogicalDabScratch.removeAll(keepingCapacity: true)
        generatedProjectionScratch.removeAll(keepingCapacity: true)
        let arenaTransaction = try transientDabArena.beginTransaction(
            replacingPrediction: false
        )
        defer { arenaTransaction.rollback() }
        var projectionRanOnMainThread = false
        let maximumGeneratedDabCount =
            TransientStrokeBufferContract.wholeStrokeDabCapacity
        let maximumGeneratedProjectionCount =
            budget.maximumPendingAuthoritativeInstances

        for sample in samples {
            let inputBefore = candidateDeriver
            let worldSample = candidateDeriver.derive(
                sample,
                viewport: viewport
            )
            let generatorBefore = candidateGenerator
            perSampleLogicalDabScratch.removeAll(keepingCapacity: true)
            let transientStart = transientDabScratch.count
            let projectionExecutionRanOnMainThread =
                executionIsOnMainThread()
            do {
                let maximumPathSubdivisionCount =
                    Self.maximumPathSubdivisionCount(
                        forRemainingDabCapacity: max(
                            0,
                            maximumGeneratedDabCount
                                - generatedLogicalDabScratch.count
                        )
                    )
                switch sample.phase {
                case .began:
                    try candidateGenerator.begin(worldSample) { dab in
                        try self.appendPreparedActualDab(
                            dab,
                            strategy: strategy,
                            maximumDabCount: maximumGeneratedDabCount,
                            maximumProjectedCount:
                                maximumGeneratedProjectionCount
                        )
                    }
                case .moved:
                    try candidateGenerator.append(
                        worldSample,
                        maximumPathSubdivisionCount:
                            maximumPathSubdivisionCount
                    ) { dab in
                        try self.appendPreparedActualDab(
                            dab,
                            strategy: strategy,
                            maximumDabCount: maximumGeneratedDabCount,
                            maximumProjectedCount:
                                maximumGeneratedProjectionCount
                        )
                    }
                case .ended:
                    try candidateGenerator.finish(
                        worldSample,
                        maximumPathSubdivisionCount:
                            maximumPathSubdivisionCount
                    ) { dab in
                        try self.appendPreparedActualDab(
                            dab,
                            strategy: strategy,
                            maximumDabCount: maximumGeneratedDabCount,
                            maximumProjectedCount:
                                maximumGeneratedProjectionCount
                        )
                    }
                case .cancelled:
                    throw StrokeFrameSchedulerError.invalidLifecycle
                }
            } catch is StrokePathInterpolationError {
                throw StrokeFrameSchedulerError
                    .generatedDabCapacityExceeded(
                        actual: maximumGeneratedDabCount + 1,
                        maximum: maximumGeneratedDabCount
                    )
            }
            if !perSampleLogicalDabScratch.isEmpty {
                projectionRanOnMainThread = projectionRanOnMainThread
                    || projectionExecutionRanOnMainThread
            }
            let transientCount = transientDabScratch.count - transientStart
            let slice = try arenaTransaction.storeActual(
                count: transientCount
            ) { offset in
                transientDabScratch[transientStart + offset]
            }
            let chunk = TransientStrokeChunk(
                sample: worldSample,
                dabs: slice,
                generatorSnapshotBeforeSample: generatorBefore,
                generatorSnapshotAfterSample: candidateGenerator,
                inputDeriverSnapshotBeforeSample: inputBefore
            )
            transientChunkScratch.append(chunk)
            perMutationSettledScratch.removeAll(keepingCapacity: true)
            let mutation = candidateBuffer.appendActual(
                chunk,
                settledInto: &perMutationSettledScratch
            )
            if let rejection = mutation.rejection {
                throw capacityError(
                    for: rejection,
                    limits: candidateBuffer.activeReplayLimits
                )
            }
            settledChunkScratch.append(
                contentsOf: perMutationSettledScratch
            )
        }

        authoritativeProjectedScratch.removeAll(keepingCapacity: true)
        replayProjectedScratch.removeAll(keepingCapacity: true)
        try appendProjectedChunks(
            settledChunkScratch,
            to: &authoritativeProjectedScratch,
            maximumRecordCount:
                budget.maximumPendingAuthoritativeInstances
        )
        try appendProjectedChunks(
            candidateBuffer.actualChunks,
            to: &replayProjectedScratch,
            maximumRecordCount:
                budget.maximumPendingPredictedInstances
        )
        try appendProjectedChunks(
            candidateBuffer.predictedChunks,
            to: &replayProjectedScratch,
            maximumRecordCount:
                budget.maximumPendingPredictedInstances
        )
        try preflightPreparedMutation(
            generation: generation,
            authoritative: authoritativeProjectedScratch,
            replay: replayProjectedScratch
        )

        let coordinatorTransfer = settledChunkScratch.isEmpty
            ? nil
            : try coordinator.prepareSettledReplayTransfer(
                settledChunkScratch
            )
        if let coordinatorTransfer {
            try coordinator.reserveForDownstreamAcceptance(
                coordinatorTransfer,
                retireAfterAcceptance: true
            )
        }
        installPreparedQueues(
            authoritative: authoritativeProjectedScratch,
            replay: replayProjectedScratch
        )
        if let coordinatorTransfer {
            coordinator.finalizeAndRetireAfterDownstreamAcceptance(
                coordinatorTransfer
            )
        }
        authoritativeGenerator = candidateGenerator
        authoritativeInputDeriver = candidateDeriver
        transientStrokeBuffer = candidateBuffer
        preparationHasBegun = true
        preparationHasFinished = isFinishing
        preparationMutationRevision &+= 1
        try arenaTransaction.commit(
            retainingActual: candidateBuffer.actualChunks,
            retainingPredicted: candidateBuffer.predictedChunks
        )

        let needsPredictionReplacement =
            !replayProjectedScratch.isEmpty
                || authoritativeProjectedScratch.isEmpty
        if needsPredictionReplacement {
            privateSurfaceEncoder?.beginPredictionReplacement()
        }
        allocationProbe?.disarmAndRecord(.authoritativeCPU)
        allocationProbeIsArmed = false
        let preparationCPUNanoseconds =
            DispatchTime.now().uptimeNanoseconds
                - preparationCPUStartedAt
        return try await makePreparedOutputBatch(
            generation: generation,
            logicalDabs: generatedLogicalDabScratch,
            predictionProvenanceBoundary:
                currentPredictionProvenanceBoundary,
            coordinatorSnapshot: coordinator.snapshot,
            executorProbe: StrokePreparationExecutorProbe(
                generatorRanOnMainThread: generatorRanOnMainThread,
                projectionRanOnMainThread: projectionRanOnMainThread
            ),
            isFinishing: isFinishing,
            emitEmpty: true,
            predictionAdmission: nil,
            forcedSurfaceLayer:
                authoritativeProjectedScratch.isEmpty
                    && replayProjectedScratch.isEmpty
                    ? .prediction
                    : nil,
            preparationCPUNanoseconds: preparationCPUNanoseconds
        )!
    }

    private var currentPredictionProvenanceBoundary:
        PredictionProvenanceBoundary
    {
        PredictionProvenanceBoundary(
            coordinatorRevision: preparationMutationRevision,
            nextAuthoritativeOrdinal:
                authoritativeGenerator?.emittedDabCount ?? 0
        )
    }

    private func appendProjectedChunks<Chunks: Collection>(
        _ chunks: Chunks,
        to destination: inout [StrokePreparedProjectedRecord],
        maximumRecordCount: Int
    ) throws where Chunks.Element == TransientStrokeChunk {
        guard let strategy = preparationTilingStrategy else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        for chunk in chunks {
            for dab in chunk.dabs {
                try appendProjectedRecords(
                    for: dab.attributes,
                    strategy: strategy,
                    to: &destination,
                    maximumRecordCount: maximumRecordCount
                )
            }
        }
    }

    private func preflightPreparedMutation(
        generation: UInt64,
        authoritative: [StrokePreparedProjectedRecord],
        replay: [StrokePreparedProjectedRecord]
    ) throws {
        guard outstandingFrame == nil,
              projectedCarry.count == 0,
              scheduler.authoritativeCount == 0,
              scheduler.predictedCount == 0
        else {
            throw StrokeFrameSchedulerError.invalidPreparedFrame
        }
        authoritativeDepositionScratch.removeAll(keepingCapacity: true)
        for record in authoritative {
            authoritativeDepositionScratch.append(
                record.depositionRecord
            )
        }
        replayDepositionScratch.removeAll(keepingCapacity: true)
        for record in replay {
            replayDepositionScratch.append(record.depositionRecord)
        }
        do {
            try scheduler.preflightAuthoritative(
                authoritativeDepositionScratch
            )
            _ = try scheduler.preflightPrediction(
                replayDepositionScratch
            )
        } catch let error as FrameSchedulerError {
            switch error {
            case let .authoritativeCapacityExceeded(
                current,
                incoming,
                maximum
            ):
                throw StrokeFrameSchedulerError
                    .authoritativeCapacityExceeded(
                        generation: generation,
                        current: current,
                        incoming: incoming,
                        maximum: maximum
                    )
            case let .predictedCapacityExceeded(actual, maximum):
                throw StrokeFrameSchedulerError.replayCapacityExceeded(
                    actual: actual,
                    maximum: maximum
                )
            }
        }
    }

    private func installPreparedQueues(
        authoritative: [StrokePreparedProjectedRecord],
        replay: [StrokePreparedProjectedRecord]
    ) {
        scheduler.enqueueAuthoritativePrevalidated(
            authoritativeDepositionScratch
        )
        let predictionResult = try! scheduler.preflightPrediction(
            replayDepositionScratch
        )
        scheduler.replacePredictionPrevalidated(
            replayDepositionScratch,
            result: predictionResult
        )
        projectedCarry.reset()
        projectedCarry.append(authoritative)
        var retainedPredictedCount = 0
        for record in replay {
            if record.depositionRecord.isPredicted {
                guard retainedPredictedCount
                    < predictionResult.acceptedPredictedInstanceCount
                else { continue }
                retainedPredictedCount += 1
            }
            projectedCarry.append(record)
        }
    }

    private func makePreparedOutputBatch(
        generation: UInt64,
        logicalDabs: [LogicalDab],
        predictionProvenanceBoundary: PredictionProvenanceBoundary?,
        coordinatorSnapshot: StrokeRenderSnapshot?,
        executorProbe: StrokePreparationExecutorProbe,
        isFinishing: Bool,
        emitEmpty: Bool,
        predictionAdmission: PredictionOverlayAdmission?,
        forcedSurfaceLayer: StrokePrivateSurfaceLayer? = nil,
        preparationCPUNanoseconds: UInt64 = 0
    ) async throws -> StrokePreparedDepositionBatch? {
        let frame = try prepareFrame(generation: generation)
        if let frame {
            let count = frame.authoritative.count + frame.predicted.count
            projectedCarry.copyPrefix(
                maximumCount: count,
                into: &preparedOutputScratch
            )
        } else {
            preparedOutputScratch.removeAll(keepingCapacity: true)
            guard emitEmpty else { return nil }
        }
        let fallbackBoundary = PredictionProvenanceBoundary(
            coordinatorRevision: 0,
            nextAuthoritativeOrdinal: 0
        )
        let fallbackSnapshot = StrokeRenderSnapshot(
            authoritativeQueueDepth: 0,
            authoritativeQueueHighWater: 0,
            authoritativeSubmittedDabCount: 0,
            maximumReturnedDabCount: 0,
            retainedCompletedDabCount: 0,
            commitMetadata: StrokeCommitMetadata()
        )
        let surfaceLayer: StrokePrivateSurfaceLayer
        if let forcedSurfaceLayer {
            surfaceLayer = forcedSurfaceLayer
        } else if let frame, !frame.authoritative.isEmpty {
            surfaceLayer = .authoritative
        } else if let frame, !frame.predicted.isEmpty {
            surfaceLayer = .prediction
        } else {
            surfaceLayer = predictionAdmission == nil
                ? .authoritative
                : .prediction
        }
        let surfaceLease: StrokePreparedSurfaceLease?
        if let privateSurfaceEncoder {
            surfaceLease = try await privateSurfaceEncoder.encode(
                generation: generation,
                records: preparedOutputScratch,
                layer: surfaceLayer,
                allocationProbe: preparationAllocationProbe
            )
        } else {
            surfaceLease = nil
        }
        if let surfaceLease {
            precondition(outstandingSurfaceLease == nil)
            outstandingSurfaceLease = surfaceLease
        }
        let allocationProbe = preparationAllocationProbe
        allocationProbe?.arm()
        var packagingProbeIsArmed = allocationProbe != nil
        defer {
            if packagingProbeIsArmed {
                allocationProbe?.disarmAndRecord(.batchPackaging)
            }
        }
        preparedDirtyOutputScratch.removeAll(keepingCapacity: true)
        precondition(
            preparedDirtyOutputScratch.capacity
                >= preparedOutputScratch.count
        )
        for record in preparedOutputScratch {
            preparedDirtyOutputScratch.append(record.dirtyRect)
        }
        let batch = StrokePreparedDepositionBatch(
            generation: generation,
            sequence: try takePreparationSequence(),
            frameToken: surfaceLease?.token ?? frame?.token,
            logicalDabs: logicalDabs,
            dirtyRegions: preparedDirtyOutputScratch,
            authoritativeInstanceCount:
                frame?.authoritative.count ?? 0,
            predictedInstanceCount: frame?.predicted.count ?? 0,
            predictionProvenanceBoundary:
                predictionProvenanceBoundary ?? fallbackBoundary,
            coordinatorSnapshot: coordinatorSnapshot ?? fallbackSnapshot,
            executorProbe: executorProbe,
            isFinishing: isFinishing,
            predictionAdmission: predictionAdmission,
            surfaceLease: surfaceLease,
            surfaceSnapshot: privateSurfaceEncoder?.snapshot,
            preparationCPUNanoseconds: preparationCPUNanoseconds
        )
        allocationProbe?.disarmAndRecord(.batchPackaging)
        packagingProbeIsArmed = false
        return batch
    }

    private func appendProjectedRecords(
        for dab: LogicalDab,
        strategy: TilingStrategy,
        to records: inout [StrokePreparedProjectedRecord],
        maximumRecordCount: Int
    ) throws {
        let footprint = StampFootprint(
            brushToWorld: dab.brushToWorld,
            localBounds: AxisAlignedRect(
                minimum: SIMD2(-1, -1),
                maximum: SIMD2(1, 1)
            ),
            coverageSymmetry: .oriented
        )
        defer {
            projectionImageHighWater = max(
                projectionImageHighWater,
                projectionScratch.imageCount
            )
            projectionCellHighWater = max(
                projectionCellHighWater,
                projectionScratch.cellCount
            )
            projectionFragmentHighWater = max(
                projectionFragmentHighWater,
                projectionScratch.fragments.count
            )
        }
        guard records.count < maximumRecordCount else {
            throw StrokeFrameSchedulerError
                .projectedInstanceCapacityExceeded(
                    actual: maximumRecordCount + 1,
                    maximum: maximumRecordCount
                )
        }
        let remaining = maximumRecordCount - records.count
        do {
            try TilingProjection.project(
                footprint,
                using: strategy,
                into: projectionScratch,
                maximumFragmentCount: remaining
            )
        } catch is TilingProjectionError {
            throw StrokeFrameSchedulerError
                .projectedInstanceCapacityExceeded(
                    actual: maximumRecordCount + 1,
                    maximum: maximumRecordCount
                )
        }
        let (projectedCount, overflow) = records.count
            .addingReportingOverflow(
                projectionScratch.fragments.count
            )
        guard !overflow, projectedCount <= maximumRecordCount else {
            throw StrokeFrameSchedulerError
                .projectedInstanceCapacityExceeded(
                    actual: overflow ? .max : projectedCount,
                    maximum: maximumRecordCount
                )
        }
        for fragment in projectionScratch.fragments {
            var isometryOrdinal: UInt8?
            for image in strategy.compiledSymmetry.images {
                if image.ordinal == fragment.imageOrdinal,
                   image.operation == fragment.operation
                {
                    isometryOrdinal = image.ordinal
                    break
                }
            }
            guard let isometryOrdinal else {
                throw StrokeFrameSchedulerError.invalidProjectedIsometry(
                    imageOrdinal: fragment.imageOrdinal
                )
            }
            let radialPage: RadialPageCoordinate? =
                strategy.compiledSymmetry.domain.finite?.radial.layout == nil
                    ? nil
                    : RadialPageCoordinate(
                        x: fragment.cell.column,
                        y: fragment.cell.row
                    )
            records.append(
                StrokePreparedProjectedRecord(
                    depositionRecord: ProjectedDepositionRecord(
                        identity: dab.ordinal,
                        instance: try PatternDepositionStampInstance(
                            fragment: fragment,
                            dab: dab,
                            logicalOrdinal: dab.ordinal,
                            isometryOrdinal: isometryOrdinal
                        ),
                        radialPage: radialPage
                    ),
                    dirtyRect: TilingProjection.dirtyPixelRect(
                        for: fragment,
                        radius: dab.radius
                    ),
                    radialPage: radialPage
                )
            )
        }
        generatedProjectionHighWater = max(
            generatedProjectionHighWater,
            records.count
        )
    }

    private func appendPreparedActualDab(
        _ dab: LogicalDab,
        strategy: TilingStrategy,
        maximumDabCount: Int,
        maximumProjectedCount: Int
    ) throws {
        guard generatedLogicalDabScratch.count < maximumDabCount else {
            throw StrokeFrameSchedulerError.generatedDabCapacityExceeded(
                actual: maximumDabCount + 1,
                maximum: maximumDabCount
            )
        }
        let projectedStart = generatedProjectionScratch.count
        try appendProjectedRecords(
            for: dab,
            strategy: strategy,
            to: &generatedProjectionScratch,
            maximumRecordCount: maximumProjectedCount
        )
        perSampleLogicalDabScratch.append(dab)
        transientDabScratch.append(
            TransientStrokeDab(
                attributes: dab,
                projectedInstanceCount:
                    generatedProjectionScratch.count - projectedStart
            )
        )
        generatedLogicalDabScratch.append(dab)
        recordGenerationScratchHighWater()
    }

    private func appendPreparedEstimatedActualDab(
        _ dab: LogicalDab,
        strategy: TilingStrategy,
        remainingDabCapacity: Int,
        maximumDabCount: Int,
        maximumProjectedCount: Int
    ) throws {
        guard perSampleLogicalDabScratch.count < remainingDabCapacity else {
            throw StrokeFrameSchedulerError.generatedDabCapacityExceeded(
                actual: maximumDabCount + 1,
                maximum: maximumDabCount
            )
        }
        let projectedStart = generatedProjectionScratch.count
        try appendProjectedRecords(
            for: dab,
            strategy: strategy,
            to: &generatedProjectionScratch,
            maximumRecordCount: maximumProjectedCount
        )
        perSampleLogicalDabScratch.append(dab)
        transientDabScratch.append(
            TransientStrokeDab(
                attributes: dab,
                projectedInstanceCount:
                    generatedProjectionScratch.count - projectedStart
            )
        )
    }

    private func appendPreparedEstimatedPredictionDab(
        _ dab: LogicalDab,
        strategy: TilingStrategy,
        remainingDabCapacity: Int,
        maximumProjectedCount: Int
    ) throws {
        guard perSampleLogicalDabScratch.count < remainingDabCapacity else {
            throw StrokePredictionGenerationLimitReached(
                reason: .logicalDabs
            )
        }
        let projectedStart = generatedProjectionScratch.count
        do {
            try appendProjectedRecords(
                for: dab,
                strategy: strategy,
                to: &generatedProjectionScratch,
                maximumRecordCount: maximumProjectedCount
            )
        } catch let error as StrokeFrameSchedulerError {
            guard case .projectedInstanceCapacityExceeded = error else {
                throw error
            }
            throw StrokePredictionGenerationLimitReached(
                reason: .projectedInstances
            )
        }
        perSampleLogicalDabScratch.append(dab)
        transientDabScratch.append(
            TransientStrokeDab(
                attributes: dab,
                projectedInstanceCount:
                    generatedProjectionScratch.count - projectedStart
            )
        )
    }

    private func recordGenerationScratchHighWater() {
        generatedLogicalDabHighWater = max(
            generatedLogicalDabHighWater,
            generatedLogicalDabScratch.count
        )
        generatedProjectionHighWater = max(
            generatedProjectionHighWater,
            generatedProjectionScratch.count
        )
    }

    private func capacityError(
        for error: TransientStrokeBufferError,
        limits: BrushReplayLimits
    ) -> StrokeFrameSchedulerError {
        guard case let .unresolvedSuffixExceedsCapacity(
            sampleCount,
            dabCount,
            projectedInstanceCount
        ) = error else {
            return .invalidLifecycle
        }
        if sampleCount > limits.maximumSamples {
            return .strokeSampleCapacityExceeded(
                actual: sampleCount,
                maximum: limits.maximumSamples
            )
        }
        if dabCount > limits.maximumDabs {
            return .generatedDabCapacityExceeded(
                actual: dabCount,
                maximum: limits.maximumDabs
            )
        }
        return .projectedInstanceCapacityExceeded(
            actual: projectedInstanceCount,
            maximum: limits.maximumProjectedInstances
        )
    }

    private func capacityFailure(
        for error: TransientStrokeBufferError,
        limits: BrushReplayLimits
    ) -> StrokePreparationCapacityFailure? {
        let counts: (
            samples: Int,
            dabs: Int,
            projectedInstances: Int
        )
        switch error {
        case let .unresolvedSuffixExceedsCapacity(
            sampleCount,
            dabCount,
            projectedInstanceCount
        ), let .predictedSuffixExceedsCapacity(
            sampleCount,
            dabCount,
            projectedInstanceCount
        ):
            counts = (sampleCount, dabCount, projectedInstanceCount)
        default:
            return nil
        }
        if counts.samples > limits.maximumSamples {
            return .strokeSamples(
                actual: counts.samples,
                maximum: limits.maximumSamples
            )
        }
        if counts.dabs > limits.maximumDabs {
            return .generatedDabs(
                actual: counts.dabs,
                maximum: limits.maximumDabs
            )
        }
        if counts.projectedInstances > limits.maximumProjectedInstances {
            return .projectedInstances(
                actual: counts.projectedInstances,
                maximum: limits.maximumProjectedInstances
            )
        }
        return nil
    }

    private func takePreparationSequence() throws -> UInt64 {
        let sequence = nextPreparationSequence
        let (successor, overflow) = sequence.addingReportingOverflow(1)
        guard !overflow else {
            throw StrokeFrameSchedulerError.frameTokenOverflow
        }
        nextPreparationSequence = successor
        return sequence
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    /// The interpolator uses at most sixteen linearized path segments per dab
    /// at the supported spacing range. One extra dab of headroom preserves
    /// spacing carry while keeping adversarial path work explicitly bounded.
    private static func maximumPathSubdivisionCount(
        forRemainingDabCapacity remainingDabCapacity: Int
    ) -> Int {
        let remainingWithHeadroom = saturatingAdd(
            max(0, remainingDabCapacity),
            1
        )
        let (count, overflow) = remainingWithHeadroom
            .multipliedReportingOverflow(by: 16)
        return max(1, overflow ? .max : count)
    }

    private func cancelPreparedStroke(generation: UInt64) {
        preparationCoordinator?.cancel()
        preparationCoordinator = nil
        authoritativeGenerator = nil
        authoritativeInputDeriver = nil
        transientStrokeBuffer?.cancel()
        transientStrokeBuffer = nil
        transientDabArena.reset()
        preparationTilingStrategy = nil
        preparationViewport = nil
        privateSurfaceEncoder?.resetAfterCancellation()
        privateSurfaceEncoder = nil
        outstandingSurfaceLease = nil
        pendingCommitBarrierGeneration = nil
        projectedCarry.reset()
        preparationHasBegun = false
        preparationHasFinished = false
        #if DEBUG
        lastEstimatedUpdateSnapshot = nil
        #endif
        cancelCurrentGeneration(generation)
    }

    private func requireActive(_ generation: UInt64) throws {
        guard activeGeneration == generation else {
            throw StrokeFrameSchedulerError.staleGeneration(
                expected: activeGeneration,
                actual: generation
            )
        }
    }

    private func cancelCurrentGeneration(_ generation: UInt64) {
        scheduler.reset()
        outstandingFrame = nil
        outstandingSurfaceLease = nil
        pendingCommitBarrierGeneration = nil
        commitRequested = false
        activeGeneration = nil
        cancelledGeneration = generation
    }
}

private func executionIsOnMainThread() -> Bool {
    Thread.isMainThread
}

private struct StrokePreparedProjectedQueue {
    let capacity: Int
    private var storage: ContiguousArray<StrokePreparedProjectedRecord?>
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = ContiguousArray(repeating: nil, count: capacity)
    }

    mutating func append(_ records: [StrokePreparedProjectedRecord]) {
        precondition(records.count <= capacity - count)
        for record in records {
            storage[(head + count) % capacity] = record
            count += 1
        }
    }

    mutating func append(_ record: StrokePreparedProjectedRecord) {
        precondition(count < capacity)
        storage[(head + count) % capacity] = record
        count += 1
    }

    func copyPrefix(
        maximumCount: Int,
        into destination: inout [StrokePreparedProjectedRecord]
    ) {
        let copiedCount = min(maximumCount, count)
        destination.removeAll(keepingCapacity: true)
        precondition(destination.capacity >= copiedCount)
        for offset in 0..<copiedCount {
            destination.append(storage[(head + offset) % capacity]!)
        }
    }

    mutating func removeFirst(_ removedCount: Int) {
        precondition((0...count).contains(removedCount))
        for offset in 0..<removedCount {
            storage[(head + offset) % capacity] = nil
        }
        head = (head + removedCount) % capacity
        count -= removedCount
        if count == 0 { head = 0 }
    }

    mutating func reset() {
        removeFirst(count)
    }
}
