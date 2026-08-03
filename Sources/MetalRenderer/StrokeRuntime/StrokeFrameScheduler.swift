import Foundation
import CShaderTypes
import PatternEngine

package enum StrokePreparationAllocationProbeStage: UInt8, Sendable {
    case authoritativeCPU
    case predictionCPU
    case estimatedCPU
    case batchPackaging
    case surfaceRecordPacking
    case surfaceMetalSubmission
    case strokeLifecycleCPU
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

    @discardableResult
    func disarmAndRecord(
        _ stage: StrokePreparationAllocationProbeStage
    ) -> UInt64 {
        let count = disarmHandler()
        recordHandler(stage, count)
        return count
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

enum StrokeStageCFailureInjectionSeam: UInt8, CaseIterable, Sendable {
    case beforeRetainedProjection
    case afterRetainedProjection
    case beforeCandidatePage
    case afterCandidatePage
    case beforeTransientCheckpointUpdate
    case afterTransientCheckpointUpdate
    case afterCandidateAccepted
    case beforePreparedPreflight
    case afterPreparedPreflight
    case beforeCoordinatorReserve
    case afterCoordinatorReserve
    case beforeCoordinatorFinalize
    case afterCoordinatorFinalize
    case beforeQueueInstall
    case afterQueueInstall
    case beforeArenaRetentionCommit
    case afterArenaRetentionCommit
    case beforeArenaPublish
    case afterArenaPublish
    case beforeSurfaceEncoding
    case afterSurfaceEncoding
    case beforeAcknowledgementResume
    case afterAcknowledgementResume
    case beforeFinishGate
    case afterFinishGate
}

struct StrokeStageCFailureInjectionContext: Equatable, Sendable {
    let generation: UInt64
    let drainPhase: UInt8?
    let sampleIndex: Int
    let consumedWorkUnits: Int
}

struct StrokeStageCInjectedFailure: Error, Equatable, Sendable {
    let seam: StrokeStageCFailureInjectionSeam
}

struct StrokeStageCFailureInjection: Sendable {
    private let handler: @Sendable (
        StrokeStageCFailureInjectionSeam,
        StrokeStageCFailureInjectionContext
    ) throws -> Void

    init(
        handler: @escaping @Sendable (
            StrokeStageCFailureInjectionSeam,
            StrokeStageCFailureInjectionContext
        ) throws -> Void
    ) {
        self.handler = handler
    }

    init(failingAt seam: StrokeStageCFailureInjectionSeam) {
        self.init { observed, _ in
            if observed == seam {
                throw StrokeStageCInjectedFailure(seam: observed)
            }
        }
    }

    func callAsFunction(
        _ seam: StrokeStageCFailureInjectionSeam,
        context: StrokeStageCFailureInjectionContext
    ) throws {
        try handler(seam, context)
    }
}

struct StrokePreparedProjectedRecord: Equatable, Sendable {
    let depositionRecord: ProjectedDepositionRecord
    let dirtyRect: PixelRect
    let radialPage: RadialPageCoordinate?
}

struct StrokePreparedLogicalDabView: RandomAccessCollection, Sendable {
    typealias Index = Int

    let startIndex = 0
    let endIndex: Int
    private let page: StrokePreparedOutputPage?
    private let token: UInt64?

    static let empty = StrokePreparedLogicalDabView(
        page: nil,
        token: nil,
        count: 0
    )

    fileprivate init(
        page: StrokePreparedOutputPage?,
        token: UInt64?,
        count: Int
    ) {
        self.page = page
        self.token = token
        endIndex = count
    }

    subscript(position: Int) -> LogicalDab {
        precondition(indices.contains(position))
        return page!.logicalDab(at: position, token: token!)
    }
}

struct StrokePreparedDirtyRegionView: RandomAccessCollection, Sendable {
    typealias Index = Int

    let startIndex = 0
    let endIndex: Int
    private let page: StrokePreparedOutputPage?
    private let token: UInt64?

    static let empty = StrokePreparedDirtyRegionView(
        page: nil,
        token: nil,
        count: 0
    )

    fileprivate init(
        page: StrokePreparedOutputPage?,
        token: UInt64?,
        count: Int
    ) {
        self.page = page
        self.token = token
        endIndex = count
    }

    subscript(position: Int) -> PixelRect {
        precondition(indices.contains(position))
        return page!.dirtyRegion(at: position, token: token!)
    }
}

/// One output page is borrowed by Main at a time. The scheduler swaps its
/// pre-reserved scratch buffers into this reference-owned page, so a retained
/// batch can never create Array COW on the next actor resume. ACK is the sole
/// operation that returns and clears the page. Views are lease-scoped: every
/// element must be consumed before ACK. A stale view deliberately traps rather
/// than reading storage that may have been reused by a later batch.
private final class StrokePreparedOutputPage: @unchecked Sendable {
    private var logicalDabs: [LogicalDab] = []
    private var dirtyRegions: [PixelRect] = []
    private var borrowedToken: UInt64?

    init(logicalDabCapacity: Int, dirtyRegionCapacity: Int) {
        logicalDabs.reserveCapacity(logicalDabCapacity)
        dirtyRegions.reserveCapacity(dirtyRegionCapacity)
    }

    func lend(
        token: UInt64,
        logicalDabScratch: inout [LogicalDab],
        dirtyRegionScratch: inout [PixelRect]
    ) -> (StrokePreparedLogicalDabView, StrokePreparedDirtyRegionView) {
        precondition(borrowedToken == nil)
        precondition(logicalDabs.isEmpty)
        precondition(dirtyRegions.isEmpty)
        swap(&logicalDabs, &logicalDabScratch)
        swap(&dirtyRegions, &dirtyRegionScratch)
        borrowedToken = token
        return (
            StrokePreparedLogicalDabView(
                page: self,
                token: token,
                count: logicalDabs.count
            ),
            StrokePreparedDirtyRegionView(
                page: self,
                token: token,
                count: dirtyRegions.count
            )
        )
    }

    func reclaim(token: UInt64) {
        precondition(borrowedToken == token)
        logicalDabs.removeAll(keepingCapacity: true)
        dirtyRegions.removeAll(keepingCapacity: true)
        borrowedToken = nil
    }

    func cancelBorrow() {
        logicalDabs.removeAll(keepingCapacity: true)
        dirtyRegions.removeAll(keepingCapacity: true)
        borrowedToken = nil
    }

    var isBorrowed: Bool { borrowedToken != nil }

    func logicalDab(at index: Int, token: UInt64) -> LogicalDab {
        precondition(borrowedToken == token)
        return logicalDabs[index]
    }

    func dirtyRegion(at index: Int, token: UInt64) -> PixelRect {
        precondition(borrowedToken == token)
        return dirtyRegions[index]
    }
}

struct StrokePreparedDepositionBatch: Sendable {
    let generation: UInt64
    let sequence: UInt64
    let frameToken: UInt64?
    let logicalDabs: StrokePreparedLogicalDabView
    let dirtyRegions: StrokePreparedDirtyRegionView
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

    var isSyntheticZeroWorkContinuation: Bool {
        surfaceLease == nil
            && frameToken != nil
            && authoritativeInstanceCount == 0
            && predictedInstanceCount == 0
    }
}

struct StrokeScheduledFrame: Equatable, Sendable {
    let authoritative: [ProjectedDepositionRecord]
    let predicted: [ProjectedDepositionRecord]
    let authoritativeRemaining: Int
    let predictedRemaining: Int
    let targetFrameDurationNanoseconds: UInt64
    let token: UInt64
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
    let authoritativeCandidateContinuationPending: Bool
    let authoritativeCandidatePageCount: UInt64
    let authoritativeCandidateResumeCount: UInt64
    let authoritativeCandidateLogicalHighWater: Int
    let authoritativeCandidateProjectionHighWater: Int
    let synchronousCompatibilityReplayInvocationCount: UInt64
    let retainedActualSampleCount: Int
    let retainedPredictedSampleCount: Int
    let transientMutationVersion: UInt64
    let generatedLogicalDabHighWater: Int
    let generatedProjectionHighWater: Int
    let generatedLogicalDabStorageCapacity: Int
    let generatedProjectionStorageCapacity: Int
    let transientChunkStorageCapacity: Int
    let settledChunkStorageCapacity: Int
    let perMutationSettledStorageCapacity: Int
    let projectionImageHighWater: Int
    let projectionCellHighWater: Int
    let projectionFragmentHighWater: Int
    let projectionImageStorageCapacity: Int
    let projectionCellStorageCapacity: Int
    let projectionFragmentStorageCapacity: Int
    let projectionStorageAllocationCount: UInt64
}

package struct StrokeStageCContinuationMetrics: Equatable, Sendable {
    package let pageCount: UInt64
    package let resumeCount: UInt64
    package let logicalPageHighWater: Int
    package let emittedAuthoritativeDabCount: UInt64
    package let phaseHits: StrokeStageCContinuationPhaseHits
    package let settledTransferWorkUnitCount: UInt64
    package let firstAllocationIncident:
        StrokeStageCAuthoritativeAllocationIncident?
    package let lastAllocationIncident:
        StrokeStageCAuthoritativeAllocationIncident?
}

package struct StrokeStageCContinuationPhaseHits:
    OptionSet,
    Equatable,
    Sendable
{
    package let rawValue: UInt8

    package init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    package static let retainedProjection = Self(rawValue: 1 << 0)
    package static let candidateEmission = Self(rawValue: 1 << 1)
    package static let candidateStorage = Self(rawValue: 1 << 2)
    package static let settledTransfer = Self(rawValue: 1 << 3)
    package static let arenaRetention = Self(rawValue: 1 << 4)
    package static let finalInstall = Self(rawValue: 1 << 5)

    package static let candidateLifecycle: Self = [
        .candidateEmission,
        .candidateStorage,
        .settledTransfer,
        .arenaRetention,
        .finalInstall,
    ]
    package static let fullLifecycle: Self = [
        .retainedProjection,
        .candidateEmission,
        .candidateStorage,
        .settledTransfer,
        .arenaRetention,
        .finalInstall,
    ]
}

package struct StrokeStageCAuthoritativeAllocationIncident:
    Equatable,
    Sendable
{
    package let eventOrdinal: UInt64
    package let allocationCount: UInt64
    package let phase: UInt8?
    package let sampleIndex: Int?
    package let pageIndex: Int?
    package let workUnits: Int?
}

#if DEBUG
struct StrokeTransientPreparationSnapshot: Equatable, Sendable {
    let actualSamples: [WorldStrokeSample]
    let predictedSamples: [WorldStrokeSample]
    let actualDabs: [TransientStrokeDab]
    let predictedDabs: [TransientStrokeDab]
}

struct StrokeStageCCleanupSnapshot: Equatable, Sendable {
    let arenaOccupiedSlotCount: Int
    let arenaHasActiveTransaction: Bool
    let arenaHasActiveOperation: Bool
    let projectedCarryCount: Int
    let coordinatorIsPresent: Bool
    let coordinatorAuthoritativeQueueDepth: Int
    let schedulerAuthoritativeQueueDepth: Int
    let schedulerPredictionQueueDepth: Int
    let hasCandidateContinuation: Bool
    let hasOutstandingFrame: Bool
    let hasOutstandingSurfaceLease: Bool
    let hasOutstandingZeroWorkContinuation: Bool
    let hasBorrowedPreparedOutputPage: Bool
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

private enum StrokeAuthoritativeCandidateDrainPhase: UInt8, Sendable {
    case retainedProjection
    case candidateEmission
    case candidateStorage
    case settledTransfer
    case arenaRetention
    case finalInstall
}

/// Actor-confined reference ownership is intentional. A page publication may
/// suspend while this continuation is also installed in actor state. Keeping
/// one reference prevents the resumed mutation from copying the buffer's
/// pre-reserved arrays merely because the prior async frame has not yet been
/// destroyed under scheduler contention.
private final class StrokeAuthoritativeCandidateDrain: @unchecked Sendable {
    let generation: UInt64
    let samples: [StrokeSample]
    let isFinishing: Bool
    let arenaTransaction: TransientStrokeDabArena.ReservationTransaction
    var sampleIndex: Int
    var generator: BrushStrokeGenerator
    var inputDeriver: BrushInputDeriver
    var buffer: TransientStrokeBuffer
    var cursor: BrushStrokeGenerator.EmissionCursor?
    var currentSample: WorldStrokeSample?
    var inputDeriverBeforeCurrentSample: BrushInputDeriver?
    var currentTransientStart: Int
    var currentPageIndex: Int
    var hasPublishedCandidatePage: Bool
    var stagingSurfaceLayer: StrokePrivateSurfaceLayer
    var phase: StrokeAuthoritativeCandidateDrainPhase
    var retainedChunkIndex: Int
    var retainedDabIndex: Int
    var currentResumeWorkUnits: Int
    var replacementClearIssued: Bool
    var actualStoreCursor: TransientStrokeDabArena.ActualStoreCursor?
    var arenaCommitCursor: TransientStrokeDabArena.CommitCursor?
    var preparedArenaCommit: TransientStrokeDabArena.PreparedCommit?
    var settledTransferCursor: SettledStageCTransferCursor?
    var preparedSettledTransfer: PreparedSettledStageCTransfer?

    init(
        generation: UInt64,
        samples: [StrokeSample],
        isFinishing: Bool,
        arenaTransaction: TransientStrokeDabArena.ReservationTransaction,
        sampleIndex: Int,
        generator: BrushStrokeGenerator,
        inputDeriver: BrushInputDeriver,
        buffer: TransientStrokeBuffer,
        cursor: BrushStrokeGenerator.EmissionCursor?,
        currentSample: WorldStrokeSample?,
        inputDeriverBeforeCurrentSample: BrushInputDeriver?,
        currentTransientStart: Int,
        currentPageIndex: Int,
        hasPublishedCandidatePage: Bool,
        stagingSurfaceLayer: StrokePrivateSurfaceLayer,
        phase: StrokeAuthoritativeCandidateDrainPhase,
        retainedChunkIndex: Int,
        retainedDabIndex: Int,
        currentResumeWorkUnits: Int,
        replacementClearIssued: Bool,
        actualStoreCursor: TransientStrokeDabArena.ActualStoreCursor?,
        arenaCommitCursor: TransientStrokeDabArena.CommitCursor?,
        preparedArenaCommit: TransientStrokeDabArena.PreparedCommit?,
        settledTransferCursor: SettledStageCTransferCursor?,
        preparedSettledTransfer: PreparedSettledStageCTransfer?
    ) {
        self.generation = generation
        self.samples = samples
        self.isFinishing = isFinishing
        self.arenaTransaction = arenaTransaction
        self.sampleIndex = sampleIndex
        self.generator = generator
        self.inputDeriver = inputDeriver
        self.buffer = buffer
        self.cursor = cursor
        self.currentSample = currentSample
        self.inputDeriverBeforeCurrentSample =
            inputDeriverBeforeCurrentSample
        self.currentTransientStart = currentTransientStart
        self.currentPageIndex = currentPageIndex
        self.hasPublishedCandidatePage = hasPublishedCandidatePage
        self.stagingSurfaceLayer = stagingSurfaceLayer
        self.phase = phase
        self.retainedChunkIndex = retainedChunkIndex
        self.retainedDabIndex = retainedDabIndex
        self.currentResumeWorkUnits = currentResumeWorkUnits
        self.replacementClearIssued = replacementClearIssued
        self.actualStoreCursor = actualStoreCursor
        self.arenaCommitCursor = arenaCommitCursor
        self.preparedArenaCommit = preparedArenaCommit
        self.settledTransferCursor = settledTransferCursor
        self.preparedSettledTransfer = preparedSettledTransfer
    }
}

/// Actor-isolated frame admission and submission state. The contained
/// deposition scheduler is never shared across executors; callers exchange
/// immutable records and frame values only.
actor StrokeFrameScheduler {
    package var stageCContinuationMetrics:
        StrokeStageCContinuationMetrics
    {
        StrokeStageCContinuationMetrics(
            pageCount: authoritativeCandidatePageCount,
            resumeCount: authoritativeCandidateResumeCount,
            logicalPageHighWater: authoritativeCandidateLogicalHighWater,
            emittedAuthoritativeDabCount:
                authoritativeGenerator?.emittedDabCount ?? 0,
            phaseHits: authoritativeCandidatePhaseHits,
            settledTransferWorkUnitCount:
                authoritativeCandidateSettledTransferWorkUnitCount,
            firstAllocationIncident:
                firstAuthoritativeAllocationIncident,
            lastAllocationIncident: lastAuthoritativeAllocationIncident
        )
    }

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
            frameOutstanding: outstandingFrame != nil
                || outstandingSurfaceLease != nil
                || outstandingZeroWorkContinuationToken != nil,
            authoritativeCandidateContinuationPending:
                authoritativeCandidateDrain != nil,
            authoritativeCandidatePageCount:
                authoritativeCandidatePageCount,
            authoritativeCandidateResumeCount:
                authoritativeCandidateResumeCount,
            authoritativeCandidateLogicalHighWater:
                authoritativeCandidateLogicalHighWater,
            authoritativeCandidateProjectionHighWater:
                authoritativeCandidateProjectionHighWater,
            synchronousCompatibilityReplayInvocationCount:
                preparationCoordinator?
                    .synchronousCompatibilityReplayInvocationCount ?? 0,
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
            transientChunkStorageCapacity: transientChunkScratch.capacity,
            settledChunkStorageCapacity: settledChunkScratch.capacity,
            perMutationSettledStorageCapacity:
                perMutationSettledScratch.capacity,
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

    var stageCCleanupSnapshotForTesting: StrokeStageCCleanupSnapshot {
        let arena = transientDabArena.diagnosticSnapshot
        let frame = scheduler.diagnosticSnapshot
        return StrokeStageCCleanupSnapshot(
            arenaOccupiedSlotCount: arena.occupiedSlotCount,
            arenaHasActiveTransaction: arena.hasActiveTransaction,
            arenaHasActiveOperation: arena.hasActiveOperation,
            projectedCarryCount: projectedCarry.count,
            coordinatorIsPresent: preparationCoordinator != nil,
            coordinatorAuthoritativeQueueDepth:
                preparationCoordinator?.snapshot.authoritativeQueueDepth ?? 0,
            schedulerAuthoritativeQueueDepth: frame.authoritativePending,
            schedulerPredictionQueueDepth: frame.predictedPending,
            hasCandidateContinuation: authoritativeCandidateDrain != nil,
            hasOutstandingFrame: outstandingFrame != nil,
            hasOutstandingSurfaceLease: outstandingSurfaceLease != nil,
            hasOutstandingZeroWorkContinuation:
                outstandingZeroWorkContinuationToken != nil,
            hasBorrowedPreparedOutputPage: preparedOutputPage.isBorrowed
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
    private let preparationClock: @Sendable () -> UInt64
    private let stageCFailureInjection: StrokeStageCFailureInjection?
    private var scheduler: FrameScheduler
    private var activeGeneration: UInt64?
    private var cancelledGeneration: UInt64?
    private var commitRequested = false
    private var outstandingFrame: StrokeScheduledFrame?
    private var outstandingZeroWorkContinuationToken: UInt64?
    private var outstandingPreparedOutputPageToken: UInt64?
    private var nextFrameToken: UInt64 = 1
    private var authoritativeScratch: [ProjectedDepositionRecord] = []
    private var predictedScratch: [ProjectedDepositionRecord] = []
    private var maximumPreparationWorkUnitsPerFrame = 0
    private var authoritativeAllocationProbeIsArmed = false
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
    private let preparedOutputPage: StrokePreparedOutputPage
    private var privateSurfaceEncoder: StrokePrivateSurfaceEncoder?
    private let reusablePrivateSurfaceEncoder = StrokePrivateSurfaceEncoder()
    private var preparationAllocationProbe:
        StrokePreparationAllocationProbe?
    private var outstandingSurfaceLease: StrokePreparedSurfaceLease?
    private var pendingCommitBarrierGeneration: UInt64?
    private var preparationMutationRevision: UInt64 = 0
    private var preparationHasBegun = false
    private var preparationHasFinished = false
    private var authoritativeCandidateDrain:
        StrokeAuthoritativeCandidateDrain?
    private var candidatePageForcedSurfaceLayer:
        StrokePrivateSurfaceLayer?
    private var authoritativeCandidatePageCount: UInt64 = 0
    private var authoritativeCandidateResumeCount: UInt64 = 0
    private var authoritativeCandidateLogicalHighWater = 0
    private var authoritativeCandidateProjectionHighWater = 0
    private var authoritativeCandidatePhaseHits:
        StrokeStageCContinuationPhaseHits = []
    private var authoritativeCandidateSettledTransferWorkUnitCount: UInt64 = 0
    private var authoritativeAllocationEventCount: UInt64 = 0
    private var firstAuthoritativeAllocationIncident:
        StrokeStageCAuthoritativeAllocationIncident?
    private var lastAuthoritativeAllocationIncident:
        StrokeStageCAuthoritativeAllocationIncident?
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
        targetFramesPerSecond: Int,
        preparationClock: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        stageCFailureInjection: StrokeStageCFailureInjection? = nil
    ) {
        precondition(targetFramesPerSecond > 0)
        self.budget = budget
        preparedOutputPage = StrokePreparedOutputPage(
            logicalDabCapacity:
                TransientStrokeBufferContract.wholeStrokeDabCapacity,
            dirtyRegionCapacity: max(
                budget.maximumAuthoritativeInstances,
                budget.maximumPredictedInstances
            )
        )
        self.preparationClock = preparationClock
        self.stageCFailureInjection = stageCFailureInjection
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
        } catch let error as StrokeStageCInjectedFailure {
            cancelPreparedStroke(generation: message.generation)
            return .failed(
                generation: message.generation,
                failure: .injectedStageC(error.seam)
            )
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
        frameToken: UInt64,
        resumeAuthoritativeContinuation: Bool = true
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
                if let frame = outstandingFrame,
                   frame.token == frameToken
                {
                    consumedCount = frame.authoritative.count
                        + frame.predicted.count
                    try markSubmitted(frame, generation: generation)
                } else if outstandingZeroWorkContinuationToken == frameToken {
                    consumedCount = 0
                    outstandingZeroWorkContinuationToken = nil
                } else {
                    throw StrokeFrameSchedulerError.invalidPreparedFrame
                }
            }
            // The caller has consumed both page views before sending ACK. The
            // page must be reclaimed before any continuation can refill the
            // scheduler scratch buffers and publish another result.
            if let pageToken = outstandingPreparedOutputPageToken {
                guard pageToken == frameToken else {
                    throw StrokeFrameSchedulerError.invalidPreparedFrame
                }
                preparedOutputPage.reclaim(token: frameToken)
                outstandingPreparedOutputPageToken = nil
            }
            projectedCarry.removeFirst(consumedCount)
            if let next = try await makePreparedOutputBatch(
                generation: generation,
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
            candidatePageForcedSurfaceLayer = nil
            if resumeAuthoritativeContinuation,
               authoritativeCandidateDrain != nil
            {
                try injectStageCFailure(
                    .beforeAcknowledgementResume,
                    generation: generation
                )
                let resumed = try await resumeAuthoritativeCandidateDrain(
                    generatorRanOnMainThread: false,
                    preparationCPUStartedAt: preparationClock()
                )
                try injectStageCFailure(
                    .afterAcknowledgementResume,
                    generation: generation
                )
                return .prepared(resumed)
            }
            if pendingCommitBarrierGeneration == generation {
                pendingCommitBarrierGeneration = nil
                return .commitBarrierReached(generation: generation)
            }
            return nil
        } catch let error as StrokeStageCInjectedFailure {
            cancelPreparedStroke(generation: generation)
            return .failed(
                generation: generation,
                failure: .injectedStageC(error.seam)
            )
        } catch let error as StrokeRenderCoordinatorError {
            cancelPreparedStroke(generation: generation)
            return .failed(
                generation: generation,
                failure: .coordinator(error)
            )
        } catch let error as BrushCornerEmitterError {
            cancelPreparedStroke(generation: generation)
            return .failed(
                generation: generation,
                failure: .cornerEmission(error)
            )
        } catch let error as AuthoritativeStrokeQueueError {
            cancelPreparedStroke(generation: generation)
            return .failed(
                generation: generation,
                failure: .authoritativeQueue(error)
            )
        } catch let error as StrokeFrameSchedulerError {
            cancelPreparedStroke(generation: generation)
            return .failed(
                generation: generation,
                failure: .scheduler(error)
            )
        } catch let error as DepositionStampPackingError {
            cancelPreparedStroke(generation: generation)
            return .failed(
                generation: generation,
                failure: .stampPacking(error)
            )
        } catch let error as StrokePrivateSurfaceEncodingError {
            cancelPreparedStroke(generation: generation)
            return .failed(
                generation: generation,
                failure: .privateSurfaceEncoding(error)
            )
        } catch let error as TransientStrokeBufferError {
            cancelPreparedStroke(generation: generation)
            return .failed(
                generation: generation,
                failure: .transientBuffer(error)
            )
        } catch let error as TransientStrokeDabArena.ReservationError {
            cancelPreparedStroke(generation: generation)
            if case let .capacityExceeded(maximum) = error {
                return .failed(
                    generation: generation,
                    failure: .dabArenaCapacityExceeded(
                        actual: maximum + 1,
                        maximum: maximum
                    )
                )
            }
            return .failed(
                generation: generation,
                failure: .unexpected(String(describing: error))
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
        guard activeGeneration == nil,
              outstandingPreparedOutputPageToken == nil,
              !preparedOutputPage.isBorrowed
        else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        scheduler.reset()
        activeGeneration = generation
        cancelledGeneration = nil
        commitRequested = false
        outstandingFrame = nil
        outstandingZeroWorkContinuationToken = nil
        outstandingPreparedOutputPageToken = nil
        outstandingSurfaceLease = nil
        pendingCommitBarrierGeneration = nil
        maximumPreparationWorkUnitsPerFrame = 0
        preparationMutationRevision = 0
        preparationHasBegun = false
        preparationHasFinished = false
        authoritativeCandidateDrain = nil
        candidatePageForcedSurfaceLayer = nil
        authoritativeCandidatePageCount = 0
        authoritativeCandidateResumeCount = 0
        authoritativeCandidateLogicalHighWater = 0
        authoritativeCandidateProjectionHighWater = 0
        authoritativeCandidatePhaseHits = []
        authoritativeCandidateSettledTransferWorkUnitCount = 0
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
        let preparationCPUStartedAt = preparationClock()
        preparationAllocationProbe = configuration.allocationProbe
        let lifecycleProbe = preparationAllocationProbe
        lifecycleProbe?.arm()
        var lifecycleProbeIsArmed = lifecycleProbe != nil
        do {
            try begin(generation: generation)
        } catch {
            if lifecycleProbeIsArmed {
                lifecycleProbe?.disarmAndRecord(.strokeLifecycleCPU)
                lifecycleProbeIsArmed = false
            }
            preparationAllocationProbe = nil
            throw error
        }
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
            let initialGenerator = BrushStrokeGenerator(
                program: configuration.program,
                nominalDiameter: configuration.nominalDiameter,
                color: configuration.color,
                seed: configuration.seed
            )
            authoritativeGenerator = initialGenerator
            authoritativeInputDeriver = BrushInputDeriver()
            transientStrokeBuffer = TransientStrokeBuffer(
                replayContract: configuration.program.replayContract,
                initialGeneratorSnapshot: initialGenerator
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
            if lifecycleProbeIsArmed {
                lifecycleProbe?.disarmAndRecord(.strokeLifecycleCPU)
                lifecycleProbeIsArmed = false
            }
            let generatorRanOnMainThread = executionIsOnMainThread()
            return try await prepareActualMutation(
                generation: generation,
                samples: actualSamples,
                generatorRanOnMainThread: generatorRanOnMainThread,
                isFinishing: false,
                preparationCPUStartedAt: preparationCPUStartedAt
            )
        } catch {
            if lifecycleProbeIsArmed {
                lifecycleProbe?.disarmAndRecord(.strokeLifecycleCPU)
                lifecycleProbeIsArmed = false
            }
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
        let preparationCPUStartedAt = preparationClock()
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
              authoritativeCandidateDrain == nil,
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
            perSampleLogicalDabScratch.removeAll(keepingCapacity: true)
            let transientStart = transientDabScratch.count
            let projectedStart = generatedProjectionScratch.count
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
            } catch is BrushCornerEmitterError {
                rollbackPreparedPredictionSampleScratch(
                    transientStart: transientStart,
                    projectedStart: projectedStart
                )
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
            : try prepareSettledTransfer(
                settledChunkScratch,
                coordinator: coordinator
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
            preparationClock()
                - preparationCPUStartedAt
        return try await makePreparedOutputBatch(
            generation: generation,
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
        let preparationCPUStartedAt = preparationClock()
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
                var candidateGenerator = replayGenerator
                perSampleLogicalDabScratch.removeAll(keepingCapacity: true)
                let transientStart = transientDabScratch.count
                let projectedStart = generatedProjectionScratch.count
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
                        } catch is BrushCornerEmitterError {
                            rollbackPreparedPredictionSampleScratch(
                                transientStart: transientStart,
                                projectedStart: projectedStart
                            )
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
            : try prepareSettledTransfer(
                settledChunkScratch,
                coordinator: coordinator
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
            preparationClock()
                - preparationCPUStartedAt
        return .prepared(
            try await makePreparedOutputBatch(
                generation: generation,
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
        guard !commitRequested,
              authoritativeCandidateDrain == nil
        else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        if preparationCoordinator != nil {
            guard preparationHasFinished,
                  outstandingFrame == nil,
                  outstandingSurfaceLease == nil,
                  outstandingZeroWorkContinuationToken == nil,
                  outstandingPreparedOutputPageToken == nil,
                  !preparedOutputPage.isBorrowed,
                  projectedCarry.count == 0,
                  scheduler.authoritativeIsDrained,
                  scheduler.predictedCount == 0,
                  candidatePageForcedSurfaceLayer == nil
            else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
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
                : try prepareSettledTransfer(
                    settledChunkScratch,
                    coordinator: coordinator
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
        guard outstandingFrame == nil,
              outstandingSurfaceLease == nil,
              outstandingZeroWorkContinuationToken == nil,
              outstandingPreparedOutputPageToken == nil,
              !preparedOutputPage.isBorrowed
        else {
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
        let token = try takeFrameToken()
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

    private func takeFrameToken() throws -> UInt64 {
        let token = nextFrameToken
        let (successor, overflow) = token.addingReportingOverflow(1)
        guard !overflow else {
            throw StrokeFrameSchedulerError.frameTokenOverflow
        }
        nextFrameToken = successor
        return token
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
            && (preparationCoordinator == nil || preparationHasFinished)
            && authoritativeCandidateDrain == nil
            && scheduler.authoritativeIsDrained
            && scheduler.predictedCount == 0
            && outstandingFrame == nil
            && outstandingSurfaceLease == nil
            && outstandingZeroWorkContinuationToken == nil
            && outstandingPreparedOutputPageToken == nil
            && !preparedOutputPage.isBorrowed
            && projectedCarry.count == 0
            && candidatePageForcedSurfaceLayer == nil
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
            ?? preparationClock()
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

        if candidateGenerator.program.stageC != nil {
            return try await beginAuthoritativeCandidateDrain(
                generation: generation,
                samples: samples,
                generator: candidateGenerator,
                inputDeriver: candidateDeriver,
                buffer: consume candidateBuffer,
                generatorRanOnMainThread: generatorRanOnMainThread,
                isFinishing: isFinishing,
                preparationCPUStartedAt: preparationCPUStartedAt
            )
        }

        let allocationProbe = preparationAllocationProbe
        allocationProbe?.arm()
        var allocationProbeIsArmed = allocationProbe != nil
        defer {
            if allocationProbeIsArmed {
                allocationProbe?.disarmAndRecord(.authoritativeCPU)
            }
        }

        transientStrokeBuffer = nil

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
            : try prepareSettledTransfer(
                settledChunkScratch,
                coordinator: coordinator
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
            preparationClock()
                - preparationCPUStartedAt
        return try await makePreparedOutputBatch(
            generation: generation,
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

    private func beginAuthoritativeCandidateDrain(
        generation: UInt64,
        samples: [StrokeSample],
        generator: BrushStrokeGenerator,
        inputDeriver: BrushInputDeriver,
        buffer: consuming TransientStrokeBuffer,
        generatorRanOnMainThread: Bool,
        isFinishing: Bool,
        preparationCPUStartedAt: UInt64
    ) async throws -> StrokePreparedDepositionBatch {
        transientStrokeBuffer = nil
        transientDabScratch.removeAll(keepingCapacity: true)
        transientChunkScratch.removeAll(keepingCapacity: true)
        settledChunkScratch.removeAll(keepingCapacity: true)
        generatedLogicalDabScratch.removeAll(keepingCapacity: true)
        generatedProjectionScratch.removeAll(keepingCapacity: true)
        let transaction = try transientDabArena.beginTransaction(
            replacingPrediction: false
        )
        authoritativeCandidateDrain = StrokeAuthoritativeCandidateDrain(
            generation: generation,
            samples: samples,
            isFinishing: isFinishing,
            arenaTransaction: transaction,
            sampleIndex: 0,
            generator: generator,
            inputDeriver: inputDeriver,
            buffer: buffer,
            cursor: nil,
            currentSample: nil,
            inputDeriverBeforeCurrentSample: nil,
            currentTransientStart: 0,
            currentPageIndex: 0,
            hasPublishedCandidatePage: false,
            stagingSurfaceLayer:
                buffer.replayContract.mode == .appendOnly
                    && !buffer.actualChunks.contains {
                        !$0.sample
                            .estimatedPropertiesExpectingUpdates.isEmpty
                    }
                    ? .authoritative
                    : .prediction,
            phase: buffer.actualChunks.isEmpty
                ? .candidateEmission
                : .retainedProjection,
            retainedChunkIndex: 0,
            retainedDabIndex: 0,
            currentResumeWorkUnits: 0,
            replacementClearIssued: false,
            actualStoreCursor: nil,
            arenaCommitCursor: nil,
            preparedArenaCommit: nil,
            settledTransferCursor: nil,
            preparedSettledTransfer: nil
        )
        do {
            return try await resumeAuthoritativeCandidateDrain(
                generatorRanOnMainThread: generatorRanOnMainThread,
                preparationCPUStartedAt: preparationCPUStartedAt
            )
        } catch {
            transaction.rollback()
            authoritativeCandidateDrain = nil
            throw error
        }
    }

    private func resumeAuthoritativeCandidateDrain(
        generatorRanOnMainThread: Bool,
        preparationCPUStartedAt: UInt64
    ) async throws -> StrokePreparedDepositionBatch {
        guard let drain = authoritativeCandidateDrain,
              let coordinator = preparationCoordinator,
              let viewport = preparationViewport,
              let strategy = preparationTilingStrategy
        else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        armAuthoritativeAllocationProbe()
        defer { disarmAuthoritativeAllocationProbe(drain: drain) }
        // Take unique ownership before mutating the buffer. Keeping the actor
        // property's copy alive would force Array COW on every continuation
        // resume. Every path reinstalls the drain before its only suspension
        // point; terminal publish has no active transaction left to expose.
        authoritativeCandidateDrain = nil
        defer {
            // A synchronous failure can escape before a continuation is
            // reinstalled. The outer process/ack catch will reset the stroke,
            // but it cannot see this uniquely-owned local transaction; close
            // it here so failure injection never leaves arena ownership live.
            if authoritativeCandidateDrain == nil {
                drain.arenaTransaction.rollback()
            }
        }
        recordCandidatePhase(drain.phase)
        authoritativeCandidateResumeCount &+= 1
        generatedLogicalDabScratch.removeAll(keepingCapacity: true)
        generatedProjectionScratch.removeAll(keepingCapacity: true)
        perSampleLogicalDabScratch.removeAll(keepingCapacity: true)
        drain.currentResumeWorkUnits = 0

        if drain.phase == .retainedProjection {
            try injectStageCFailure(
                .beforeRetainedProjection,
                generation: drain.generation,
                drain: drain
            )
            let pageProjectedCapacity = min(
                budget.maximumAuthoritativeInstances,
                budget.maximumPendingAuthoritativeInstances
            )
            let maximumWorkUnits = LogicalDabBatch.maximumDabCount
            var pageIsFull = false
            retainedProjection: while drain.retainedChunkIndex
                < drain.buffer.actualChunks.count
            {
                let chunk = drain.buffer.actualChunks[
                    drain.retainedChunkIndex
                ]
                while drain.retainedDabIndex < chunk.dabs.count {
                    if drain.currentResumeWorkUnits >= maximumWorkUnits
                        || (
                            drain.currentResumeWorkUnits > 0
                                && preparationClock()
                                    - preparationCPUStartedAt
                                    >= budget.cpuPreparationNanoseconds
                        )
                    {
                        pageIsFull = true
                        break retainedProjection
                    }
                    let dab = chunk.dabs[drain.retainedDabIndex]
                    guard try appendProjectedRecordsToPage(
                        for: dab.attributes,
                        strategy: strategy,
                        to: &generatedProjectionScratch,
                        maximumRecordCount: pageProjectedCapacity
                    ) else {
                        pageIsFull = true
                        break retainedProjection
                    }
                    drain.retainedDabIndex += 1
                    drain.currentResumeWorkUnits += 1
                }
                if drain.retainedDabIndex == chunk.dabs.count {
                    drain.retainedChunkIndex += 1
                    drain.retainedDabIndex = 0
                }
            }
            let retainedProjectionComplete = drain.retainedChunkIndex
                == drain.buffer.actualChunks.count
            try injectStageCFailure(
                .afterRetainedProjection,
                generation: drain.generation,
                drain: drain
            )
            if retainedProjectionComplete {
                setCandidatePhase(.candidateEmission, on: drain)
            }
            if pageIsFull
                || !generatedProjectionScratch.isEmpty
                || (!retainedProjectionComplete
                    && drain.currentResumeWorkUnits > 0)
            {
                try installStagedCandidateProjectionPage(drain)
                drain.hasPublishedCandidatePage = true
                authoritativeCandidateDrain = drain
                return try await makeCandidateDrainBatch(
                    drain: drain,
                    coordinator: coordinator,
                    generatorRanOnMainThread: generatorRanOnMainThread,
                    isFinishing: false,
                    preparationCPUStartedAt: preparationCPUStartedAt
                )
            }
        }

        if drain.phase == .candidateStorage {
            let storageCompleted = try resumeCandidateActualStorage(
                drain,
                preparationCPUStartedAt: preparationCPUStartedAt
            )
            if !storageCompleted
                || drain.currentResumeWorkUnits
                    >= LogicalDabBatch.maximumDabCount
            {
                try installCheckpointedAuthoritativeCandidatePage(drain)
                drain.hasPublishedCandidatePage = true
                authoritativeCandidateDrain = drain
                return try await makeCandidateDrainBatch(
                    drain: drain,
                    coordinator: coordinator,
                    generatorRanOnMainThread: generatorRanOnMainThread,
                    isFinishing: false,
                    preparationCPUStartedAt: preparationCPUStartedAt
                )
            }
        }
        if drain.phase == .settledTransfer {
            return try await continueAfterCandidateEmission(
                drain,
                coordinator: coordinator,
                generatorRanOnMainThread: generatorRanOnMainThread,
                preparationCPUStartedAt: preparationCPUStartedAt
            )
        }

        while drain.sampleIndex < drain.samples.count {
            if drain.cursor == nil {
                let inputBefore = drain.inputDeriver
                let worldSample = drain.inputDeriver.derive(
                    drain.samples[drain.sampleIndex],
                    viewport: viewport
                )
                let remainingDabCapacity = max(
                    0,
                    TransientStrokeBufferContract.wholeStrokeDabCapacity
                        - transientDabScratch.count
                )
                drain.cursor = try drain.generator.emissionCursor(
                    for: worldSample,
                    maximumPathSubdivisionCount:
                        Self.maximumPathSubdivisionCount(
                            forRemainingDabCapacity: remainingDabCapacity
                        )
                )
                drain.currentSample = worldSample
                let retainsReplaceableActual =
                    drain.buffer.replayContract.mode != .appendOnly
                        || drain.buffer.actualChunks.contains {
                            !$0.sample
                                .estimatedPropertiesExpectingUpdates.isEmpty
                        }
                drain.stagingSurfaceLayer =
                    !worldSample.estimatedPropertiesExpectingUpdates.isEmpty
                        || retainsReplaceableActual
                        ? .prediction
                        : .authoritative
                drain.inputDeriverBeforeCurrentSample = inputBefore
                drain.currentTransientStart = transientDabScratch.count
                drain.currentPageIndex = 0
            }

            guard var cursor = drain.cursor else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
            let pageProjectedCapacity =
                min(
                    budget.maximumAuthoritativeInstances,
                    budget.maximumPendingAuthoritativeInstances
                )
            if pageProjectedCapacity <= 0 {
                try installPartialAuthoritativeCandidatePage(drain)
                drain.hasPublishedCandidatePage = true
                authoritativeCandidateDrain = drain
                return try await makeCandidateDrainBatch(
                    drain: drain,
                    coordinator: coordinator,
                    generatorRanOnMainThread: generatorRanOnMainThread,
                    isFinishing: false,
                    preparationCPUStartedAt: preparationCPUStartedAt
                )
            }
            let page: BrushStrokeGenerator.EmissionPage?
            var yieldedAcceptedPrefix = false
            var pausedBeforeCandidate = false
            try injectStageCFailure(
                .beforeCandidatePage,
                generation: drain.generation,
                drain: drain
            )
            page = try cursor.emitNextPageDeciding { dab in
                if !self.generatedLogicalDabScratch.isEmpty,
                   self.preparationClock()
                    - preparationCPUStartedAt
                        >= self.budget.cpuPreparationNanoseconds
                {
                    pausedBeforeCandidate = true
                    return .pause
                }
                guard try self.appendPreparedActualDabToPage(
                    dab,
                    strategy: strategy,
                    maximumDabCount:
                        TransientStrokeBufferContract
                            .wholeStrokeDabCapacity,
                    maximumProjectedCount: pageProjectedCapacity
                ) else {
                    if self.generatedLogicalDabScratch.isEmpty {
                        throw StrokeFrameSchedulerError
                            .projectedInstanceCapacityExceeded(
                                actual: pageProjectedCapacity + 1,
                                maximum: pageProjectedCapacity
                            )
                    }
                        pausedBeforeCandidate = true
                        return .pause
                }
                drain.currentResumeWorkUnits += 1
                return .accept
            }
            yieldedAcceptedPrefix = yieldedAcceptedPrefix
                || pausedBeforeCandidate
            try injectStageCFailure(
                .afterCandidatePage,
                generation: drain.generation,
                drain: drain
            )
            if yieldedAcceptedPrefix {
                // The cursor calls its sink before it commits identity/random
                // state. `cursor` therefore owns the accepted prefix and the
                // rejected candidate remains the exact next candidate.
                drain.cursor = cursor
                drain.currentPageIndex += 1
                try installPartialAuthoritativeCandidatePage(drain)
                drain.hasPublishedCandidatePage = true
                authoritativeCandidateDrain = drain
                return try await makeCandidateDrainBatch(
                    drain: drain,
                    coordinator: coordinator,
                    generatorRanOnMainThread: generatorRanOnMainThread,
                    isFinishing: false,
                    preparationCPUStartedAt: preparationCPUStartedAt
                )
            }
            guard let page else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
            drain.cursor = cursor

            if page.hasMore {
                drain.currentPageIndex += 1
                try installPartialAuthoritativeCandidatePage(drain)
                drain.hasPublishedCandidatePage = true
                authoritativeCandidateDrain = drain
                return try await makeCandidateDrainBatch(
                    drain: drain,
                    coordinator: coordinator,
                    generatorRanOnMainThread: generatorRanOnMainThread,
                    isFinishing: false,
                    preparationCPUStartedAt: preparationCPUStartedAt
                )
            }

            guard let completedGenerator = cursor.completedGenerator,
                  let worldSample = drain.currentSample,
                  let inputBefore =
                    drain.inputDeriverBeforeCurrentSample
            else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
            _ = worldSample
            _ = inputBefore
            _ = completedGenerator
            setCandidatePhase(.candidateStorage, on: drain)
            let storageCompleted = try resumeCandidateActualStorage(
                drain,
                preparationCPUStartedAt: preparationCPUStartedAt
            )
            if !storageCompleted {
                try installPartialAuthoritativeCandidatePage(drain)
                drain.hasPublishedCandidatePage = true
                authoritativeCandidateDrain = drain
                return try await makeCandidateDrainBatch(
                    drain: drain,
                    coordinator: coordinator,
                    generatorRanOnMainThread: generatorRanOnMainThread,
                    isFinishing: false,
                    preparationCPUStartedAt: preparationCPUStartedAt
                )
            }

            let preparationDeadlineReached =
                drain.currentResumeWorkUnits > 0
                && preparationClock() - preparationCPUStartedAt
                    >= budget.cpuPreparationNanoseconds
            if drain.sampleIndex < drain.samples.count,
               (!generatedLogicalDabScratch.isEmpty
                   || preparationDeadlineReached)
            {
                try installCheckpointedAuthoritativeCandidatePage(drain)
                drain.hasPublishedCandidatePage = true
                authoritativeCandidateDrain = drain
                return try await makeCandidateDrainBatch(
                    drain: drain,
                    coordinator: coordinator,
                    generatorRanOnMainThread: generatorRanOnMainThread,
                    isFinishing: false,
                    preparationCPUStartedAt: preparationCPUStartedAt
                )
            }
        }

        setCandidatePhase(.settledTransfer, on: drain)
        if !generatedLogicalDabScratch.isEmpty
            || !generatedProjectionScratch.isEmpty
        {
            try installCheckpointedAuthoritativeCandidatePage(drain)
            drain.hasPublishedCandidatePage = true
            authoritativeCandidateDrain = drain
            return try await makeCandidateDrainBatch(
                drain: drain,
                coordinator: coordinator,
                generatorRanOnMainThread: generatorRanOnMainThread,
                isFinishing: false,
                preparationCPUStartedAt: preparationCPUStartedAt
            )
        }
        return try await continueAfterCandidateEmission(
            drain,
            coordinator: coordinator,
            generatorRanOnMainThread: generatorRanOnMainThread,
            preparationCPUStartedAt: preparationCPUStartedAt
        )
    }

    private func continueAfterCandidateEmission(
        _ drain: StrokeAuthoritativeCandidateDrain,
        coordinator: StrokeRenderCoordinator,
        generatorRanOnMainThread: Bool,
        preparationCPUStartedAt: UInt64
    ) async throws -> StrokePreparedDepositionBatch {
        if !settledChunkScratch.isEmpty,
           drain.preparedSettledTransfer == nil
        {
            if drain.settledTransferCursor == nil {
                guard let trustedFinalGenerator = settledChunkScratch.last?
                    .generatorSnapshotAfterSample
                else {
                    throw StrokeFrameSchedulerError
                        .missingGeneratorCheckpoint
                }
                drain.settledTransferCursor = try coordinator
                    .beginSettledStageCTransfer(
                        expectedChunkCount: settledChunkScratch.count,
                        trustedStartingGenerator:
                            coordinator.generatorSnapshot,
                        trustedFinalGenerator: trustedFinalGenerator
                    )
            }
            guard var transferCursor = drain.settledTransferCursor else {
                throw StrokeFrameSchedulerError.invalidLifecycle
            }
            let remainingWork = LogicalDabBatch.maximumDabCount
                - drain.currentResumeWorkUnits
            if remainingWork > 0 {
                var remainingTransferWork = remainingWork
                while remainingTransferWork > 0 {
                    let step = try coordinator.resumeSettledStageCTransfer(
                        &transferCursor,
                        chunks: settledChunkScratch,
                        maximumWorkUnits: 1
                    )
                    switch step {
                    case let .pending(consumedWorkUnits):
                        drain.currentResumeWorkUnits += consumedWorkUnits
                        authoritativeCandidateSettledTransferWorkUnitCount &+=
                            UInt64(consumedWorkUnits)
                        remainingTransferWork -= consumedWorkUnits
                        drain.settledTransferCursor = transferCursor
                    case let .prepared(prepared, consumedWorkUnits):
                        drain.currentResumeWorkUnits += consumedWorkUnits
                        authoritativeCandidateSettledTransferWorkUnitCount &+=
                            UInt64(consumedWorkUnits)
                        remainingTransferWork -= consumedWorkUnits
                        drain.settledTransferCursor = nil
                        drain.preparedSettledTransfer = prepared
                    }
                    if drain.preparedSettledTransfer != nil
                        || (drain.currentResumeWorkUnits > 0
                            && preparationClock()
                                - preparationCPUStartedAt
                                >= budget.cpuPreparationNanoseconds)
                    {
                        break
                    }
                }
            }
            if drain.preparedSettledTransfer == nil {
                try installCheckpointedAuthoritativeCandidatePage(drain)
                drain.hasPublishedCandidatePage = true
                authoritativeCandidateDrain = drain
                return try await makeCandidateDrainBatch(
                    drain: drain,
                    coordinator: coordinator,
                    generatorRanOnMainThread: generatorRanOnMainThread,
                    isFinishing: false,
                    preparationCPUStartedAt: preparationCPUStartedAt
                )
            }
        }
        setCandidatePhase(.arenaRetention, on: drain)
        if drain.arenaCommitCursor == nil {
            try injectStageCFailure(
                .beforeArenaRetentionCommit,
                generation: drain.generation,
                drain: drain
            )
            drain.arenaCommitCursor = try drain.arenaTransaction.beginCommit(
                expectedActualChunkCount: drain.buffer.actualChunks.count,
                expectedPredictedChunkCount:
                    drain.buffer.predictedChunks.count
            )
        }
        guard var arenaCommitCursor = drain.arenaCommitCursor else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        let remainingWork = LogicalDabBatch.maximumDabCount
            - drain.currentResumeWorkUnits
        if remainingWork > 0 {
            let step = try drain.arenaTransaction.resumeCommit(
                &arenaCommitCursor,
                retainingActual: drain.buffer.actualChunks,
                retainingPredicted: drain.buffer.predictedChunks,
                maximumWorkUnits: remainingWork,
                shouldYield: {
                    self.preparationClock()
                        - preparationCPUStartedAt
                        >= self.budget.cpuPreparationNanoseconds
                }
            )
            switch step {
            case let .pending(consumedWorkUnits):
                drain.currentResumeWorkUnits += consumedWorkUnits
                drain.arenaCommitCursor = arenaCommitCursor
            case let .prepared(prepared, consumedWorkUnits):
                drain.currentResumeWorkUnits += consumedWorkUnits
                drain.arenaCommitCursor = nil
                drain.preparedArenaCommit = prepared
                setCandidatePhase(.finalInstall, on: drain)
                try injectStageCFailure(
                    .afterArenaRetentionCommit,
                    generation: drain.generation,
                    drain: drain
                )
            }
        }
        if drain.phase != .finalInstall {
            try installCheckpointedAuthoritativeCandidatePage(drain)
            drain.hasPublishedCandidatePage = true
            authoritativeCandidateDrain = drain
            return try await makeCandidateDrainBatch(
                drain: drain,
                coordinator: coordinator,
                generatorRanOnMainThread: generatorRanOnMainThread,
                isFinishing: false,
                preparationCPUStartedAt: preparationCPUStartedAt
            )
        }
        return try await finalizeAuthoritativeCandidateDrain(
            drain,
            coordinator: coordinator,
            generatorRanOnMainThread: generatorRanOnMainThread,
            preparationCPUStartedAt: preparationCPUStartedAt
        )
    }

    private func resumeCandidateActualStorage(
        _ drain: StrokeAuthoritativeCandidateDrain,
        preparationCPUStartedAt: UInt64
    ) throws -> Bool {
        guard let completedGenerator = drain.cursor?.completedGenerator,
              let worldSample = drain.currentSample,
              let inputBefore = drain.inputDeriverBeforeCurrentSample
        else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        let transientStart = drain.currentTransientStart
        let transientCount = transientDabScratch.count - transientStart
        if drain.actualStoreCursor == nil {
            drain.actualStoreCursor = try drain.arenaTransaction
                .beginActualStore(count: transientCount)
        }
        guard var storeCursor = drain.actualStoreCursor else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        let remainingWork = LogicalDabBatch.maximumDabCount
            - drain.currentResumeWorkUnits
        guard remainingWork > 0 else {
            drain.actualStoreCursor = storeCursor
            return false
        }
        let step = try drain.arenaTransaction.resumeActualStore(
            &storeCursor,
            maximumWorkUnits: remainingWork,
            shouldYield: {
                self.preparationClock()
                    - preparationCPUStartedAt
                    >= self.budget.cpuPreparationNanoseconds
            }
        ) { offset in
            transientDabScratch[transientStart + offset]
        }
        switch step {
        case let .pending(consumedWorkUnits):
            drain.currentResumeWorkUnits += consumedWorkUnits
            drain.actualStoreCursor = storeCursor
            return false
        case let .stored(slice, consumedWorkUnits):
            drain.currentResumeWorkUnits += consumedWorkUnits
            let chunk = TransientStrokeChunk(
                sample: worldSample,
                dabs: slice,
                generatorSnapshotAfterSample: completedGenerator,
                inputDeriverSnapshotBeforeSample: inputBefore
            )
            perMutationSettledScratch.removeAll(keepingCapacity: true)
            try injectStageCFailure(
                .beforeTransientCheckpointUpdate,
                generation: drain.generation,
                drain: drain
            )
            let mutation = drain.buffer.appendActual(
                chunk,
                settledInto: &perMutationSettledScratch
            )
            if let rejection = mutation.rejection {
                throw capacityError(
                    for: rejection,
                    limits: drain.buffer.activeReplayLimits
                )
            }
            settledChunkScratch.append(
                contentsOf: perMutationSettledScratch
            )
            try injectStageCFailure(
                .afterTransientCheckpointUpdate,
                generation: drain.generation,
                drain: drain
            )
            drain.generator = completedGenerator
            drain.cursor = nil
            drain.currentSample = nil
            drain.inputDeriverBeforeCurrentSample = nil
            drain.actualStoreCursor = nil
            drain.sampleIndex += 1
            setCandidatePhase(.candidateEmission, on: drain)
            try injectStageCFailure(
                .afterCandidateAccepted,
                generation: drain.generation,
                drain: drain
            )
            return true
        }
    }

    private func makeCandidateDrainBatch(
        drain: StrokeAuthoritativeCandidateDrain,
        coordinator: StrokeRenderCoordinator,
        generatorRanOnMainThread: Bool,
        isFinishing: Bool,
        preparationCPUStartedAt: UInt64
    ) async throws -> StrokePreparedDepositionBatch {
        authoritativeCandidatePageCount &+= 1
        authoritativeCandidateLogicalHighWater = max(
            authoritativeCandidateLogicalHighWater,
            generatedLogicalDabScratch.count
        )
        let projectedWork = max(
            generatedProjectionScratch.count,
            max(
                authoritativeProjectedScratch.count,
                replayProjectedScratch.count
            )
        )
        authoritativeCandidateProjectionHighWater = max(
            authoritativeCandidateProjectionHighWater,
            projectedWork
        )
        maximumPreparationWorkUnitsPerFrame = max(
            maximumPreparationWorkUnitsPerFrame,
            drain.currentResumeWorkUnits
        )
        // Batch packaging has its own allocation stage. Close the CPU stage
        // before that probe is armed so continuation pages remain separately
        // measurable instead of nesting/resetting the same counter.
        disarmAuthoritativeAllocationProbe(drain: drain)
        let batch = try await makePreparedOutputBatch(
            generation: drain.generation,
            predictionProvenanceBoundary:
                currentPredictionProvenanceBoundary,
            coordinatorSnapshot: coordinator.snapshot,
            executorProbe: StrokePreparationExecutorProbe(
                generatorRanOnMainThread: generatorRanOnMainThread,
                projectionRanOnMainThread: executionIsOnMainThread()
            ),
            isFinishing: isFinishing,
            emitEmpty: true,
            predictionAdmission: nil,
            forcedSurfaceLayer: drain.stagingSurfaceLayer,
            preparationCPUNanoseconds:
                preparationClock()
                    - preparationCPUStartedAt
        )!
        // A terminal candidate page can contain logical dabs that project to
        // no visible records. Without a surface or continuation lease there
        // will be no acknowledgement callback to retire the page-scoped
        // layer override, so retire it synchronously once the cursor and all
        // projected work are fully drained.
        if authoritativeCandidateDrain == nil,
           batch.frameToken == nil,
           projectedCarry.count == 0,
           scheduler.authoritativeIsDrained,
           scheduler.predictedCount == 0
        {
            candidatePageForcedSurfaceLayer = nil
        }
        return batch
    }

    private func setCandidatePhase(
        _ phase: StrokeAuthoritativeCandidateDrainPhase,
        on drain: StrokeAuthoritativeCandidateDrain
    ) {
        drain.phase = phase
        recordCandidatePhase(phase)
    }

    private func recordCandidatePhase(
        _ phase: StrokeAuthoritativeCandidateDrainPhase
    ) {
        let hit: StrokeStageCContinuationPhaseHits = switch phase {
        case .retainedProjection: .retainedProjection
        case .candidateEmission: .candidateEmission
        case .candidateStorage: .candidateStorage
        case .settledTransfer: .settledTransfer
        case .arenaRetention: .arenaRetention
        case .finalInstall: .finalInstall
        }
        authoritativeCandidatePhaseHits.insert(hit)
    }

    private func armAuthoritativeAllocationProbe() {
        guard let preparationAllocationProbe else { return }
        precondition(!authoritativeAllocationProbeIsArmed)
        preparationAllocationProbe.arm()
        authoritativeAllocationProbeIsArmed = true
    }

    private func disarmAuthoritativeAllocationProbe(
        drain: StrokeAuthoritativeCandidateDrain? = nil
    ) {
        guard authoritativeAllocationProbeIsArmed else { return }
        let allocationCount = preparationAllocationProbe?
            .disarmAndRecord(.authoritativeCPU) ?? 0
        authoritativeAllocationProbeIsArmed = false
        authoritativeAllocationEventCount &+= 1
        guard allocationCount > 0 else { return }
        let incident = StrokeStageCAuthoritativeAllocationIncident(
            eventOrdinal: authoritativeAllocationEventCount,
            allocationCount: allocationCount,
            phase: drain?.phase.rawValue,
            sampleIndex: drain?.sampleIndex,
            pageIndex: drain?.currentPageIndex,
            workUnits: drain?.currentResumeWorkUnits
        )
        if firstAuthoritativeAllocationIncident == nil {
            firstAuthoritativeAllocationIncident = incident
        }
        lastAuthoritativeAllocationIncident = incident
    }

    private func installPartialAuthoritativeCandidatePage(
        _ drain: StrokeAuthoritativeCandidateDrain
    ) throws {
        authoritativeProjectedScratch.removeAll(keepingCapacity: true)
        replayProjectedScratch.removeAll(keepingCapacity: true)
        authoritativeProjectedScratch.append(
            contentsOf: generatedProjectionScratch
        )
        try preflightPreparedMutation(
            generation: drain.generation,
            authoritative: authoritativeProjectedScratch,
            replay: replayProjectedScratch,
            candidateDrain: drain
        )
        try injectStageCFailure(
            .beforeQueueInstall,
            generation: drain.generation,
            drain: drain
        )
        installPreparedQueues(
            authoritative: authoritativeProjectedScratch,
            replay: replayProjectedScratch
        )
        try injectStageCFailure(
            .afterQueueInstall,
            generation: drain.generation,
            drain: drain
        )
        candidatePageForcedSurfaceLayer = drain.stagingSurfaceLayer
        if !drain.replacementClearIssued,
           drain.stagingSurfaceLayer == .prediction {
            privateSurfaceEncoder?.beginPredictionReplacement()
            drain.replacementClearIssued = true
        }
    }

    private func installCheckpointedAuthoritativeCandidatePage(
        _ drain: StrokeAuthoritativeCandidateDrain
    ) throws {
        authoritativeProjectedScratch.removeAll(keepingCapacity: true)
        replayProjectedScratch.removeAll(keepingCapacity: true)
        authoritativeProjectedScratch.append(
            contentsOf: generatedProjectionScratch
        )
        try preflightPreparedMutation(
            generation: drain.generation,
            authoritative: authoritativeProjectedScratch,
            replay: replayProjectedScratch,
            candidateDrain: drain
        )
        try injectStageCFailure(
            .beforeQueueInstall,
            generation: drain.generation,
            drain: drain
        )
        installPreparedQueues(
            authoritative: authoritativeProjectedScratch,
            replay: replayProjectedScratch
        )
        try injectStageCFailure(
            .afterQueueInstall,
            generation: drain.generation,
            drain: drain
        )
        candidatePageForcedSurfaceLayer = drain.stagingSurfaceLayer
        if !drain.replacementClearIssued,
           drain.stagingSurfaceLayer == .prediction {
            privateSurfaceEncoder?.beginPredictionReplacement()
            drain.replacementClearIssued = true
        }
    }

    private func installStagedCandidateProjectionPage(
        _ drain: StrokeAuthoritativeCandidateDrain
    ) throws {
        try installPartialAuthoritativeCandidatePage(drain)
    }

    private func finalizeAuthoritativeCandidateDrain(
        _ drain: StrokeAuthoritativeCandidateDrain,
        coordinator: StrokeRenderCoordinator,
        generatorRanOnMainThread: Bool,
        preparationCPUStartedAt: UInt64
    ) async throws -> StrokePreparedDepositionBatch {
        guard let preparedArenaCommit = drain.preparedArenaCommit else {
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        guard generatedLogicalDabScratch.isEmpty,
              generatedProjectionScratch.isEmpty
        else {
            // Candidate emission must publish every logical/projection page
            // before entering the terminal O(1) install phase.
            throw StrokeFrameSchedulerError.invalidLifecycle
        }
        authoritativeProjectedScratch.removeAll(keepingCapacity: true)
        replayProjectedScratch.removeAll(keepingCapacity: true)
        candidatePageForcedSurfaceLayer = drain.stagingSurfaceLayer
        try preflightPreparedMutation(
            generation: drain.generation,
            authoritative: authoritativeProjectedScratch,
            replay: replayProjectedScratch,
            candidateDrain: drain
        )
        let transfer = drain.preparedSettledTransfer
        if let transfer {
            try injectStageCFailure(
                .beforeCoordinatorReserve,
                generation: drain.generation,
                drain: drain
            )
            try coordinator.reserveForDownstreamAcceptance(
                transfer,
                retireAfterAcceptance: true
            )
            try injectStageCFailure(
                .afterCoordinatorReserve,
                generation: drain.generation,
                drain: drain
            )
        }
        try injectStageCFailure(
            .beforeQueueInstall,
            generation: drain.generation,
            drain: drain
        )
        installPreparedQueues(
            authoritative: authoritativeProjectedScratch,
            replay: replayProjectedScratch
        )
        try injectStageCFailure(
            .afterQueueInstall,
            generation: drain.generation,
            drain: drain
        )
        if let transfer {
            try injectStageCFailure(
                .beforeCoordinatorFinalize,
                generation: drain.generation,
                drain: drain
            )
            coordinator.finalizeAndRetireAfterDownstreamAcceptance(transfer)
            try injectStageCFailure(
                .afterCoordinatorFinalize,
                generation: drain.generation,
                drain: drain
            )
        }
        try injectStageCFailure(
            .beforeArenaPublish,
            generation: drain.generation,
            drain: drain
        )
        drain.arenaTransaction.publish(preparedArenaCommit)
        try injectStageCFailure(
            .afterArenaPublish,
            generation: drain.generation,
            drain: drain
        )
        authoritativeGenerator = drain.generator
        authoritativeInputDeriver = drain.inputDeriver
        transientStrokeBuffer = drain.buffer
        preparationHasBegun = true
        if drain.isFinishing {
            try injectStageCFailure(
                .beforeFinishGate,
                generation: drain.generation,
                drain: drain
            )
        }
        preparationHasFinished = drain.isFinishing
        if drain.isFinishing {
            try injectStageCFailure(
                .afterFinishGate,
                generation: drain.generation,
                drain: drain
            )
        }
        preparationMutationRevision &+= 1
        authoritativeCandidateDrain = nil
        if !drain.hasPublishedCandidatePage,
           (!replayProjectedScratch.isEmpty
            || authoritativeProjectedScratch.isEmpty)
        {
            privateSurfaceEncoder?.beginPredictionReplacement()
        }
        return try await makeCandidateDrainBatch(
            drain: drain,
            coordinator: coordinator,
            generatorRanOnMainThread: generatorRanOnMainThread,
            isFinishing: drain.isFinishing,
            preparationCPUStartedAt: preparationCPUStartedAt
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

    private func prepareSettledTransfer(
        _ chunks: [TransientStrokeChunk],
        coordinator: StrokeRenderCoordinator
    ) throws -> PreparedStrokeCoordinatorEmission {
        try coordinator.prepareSettledReplayTransfer(
            chunks,
            trustedStartingGenerator: coordinator.generatorSnapshot,
            trustedFinalGenerator:
                chunks.last?.generatorSnapshotAfterSample
        )
    }

    private func preflightPreparedMutation(
        generation: UInt64,
        authoritative: [StrokePreparedProjectedRecord],
        replay: [StrokePreparedProjectedRecord],
        candidateDrain: StrokeAuthoritativeCandidateDrain? = nil
    ) throws {
        if let candidateDrain {
            try injectStageCFailure(
                .beforePreparedPreflight,
                generation: generation,
                drain: candidateDrain
            )
        }
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
        if let candidateDrain {
            try injectStageCFailure(
                .afterPreparedPreflight,
                generation: generation,
                drain: candidateDrain
            )
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
            guard emitEmpty else {
                precondition(generatedLogicalDabScratch.isEmpty)
                return nil
            }
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
        let effectiveForcedSurfaceLayer = forcedSurfaceLayer
            ?? candidatePageForcedSurfaceLayer
        if let effectiveForcedSurfaceLayer {
            surfaceLayer = effectiveForcedSurfaceLayer
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
            if authoritativeCandidateDrain != nil
                || candidatePageForcedSurfaceLayer != nil
            {
                try injectStageCFailure(
                    .beforeSurfaceEncoding,
                    generation: generation
                )
            }
            surfaceLease = try await privateSurfaceEncoder.encode(
                generation: generation,
                records: preparedOutputScratch,
                layer: surfaceLayer,
                allocationProbe: preparationAllocationProbe
            )
            if authoritativeCandidateDrain != nil
                || candidatePageForcedSurfaceLayer != nil
            {
                try injectStageCFailure(
                    .afterSurfaceEncoding,
                    generation: generation
                )
            }
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
        // A token is also required when projection produced no frame (for
        // example, a fully clipped logical-dab page). It is the lifetime lease
        // for the output page even when there is no GPU surface to submit.
        let zeroWorkContinuationToken: UInt64?
        if surfaceLease == nil,
           frame == nil,
           (authoritativeCandidateDrain != nil
               || !generatedLogicalDabScratch.isEmpty
               || !preparedDirtyOutputScratch.isEmpty)
        {
            precondition(outstandingZeroWorkContinuationToken == nil)
            zeroWorkContinuationToken = try takeFrameToken()
            outstandingZeroWorkContinuationToken = zeroWorkContinuationToken
        } else {
            zeroWorkContinuationToken = nil
        }
        // Complete every throwable operation before lending the page. Failure
        // before this point is recovered by normal stroke cancellation without
        // ever stranding swapped scratch buffers in a published batch.
        let sequence = try takePreparationSequence()
        let frameToken = surfaceLease?.token
            ?? frame?.token
            ?? zeroWorkContinuationToken
        let logicalDabView: StrokePreparedLogicalDabView
        let dirtyRegionView: StrokePreparedDirtyRegionView
        if let frameToken {
            (logicalDabView, dirtyRegionView) = preparedOutputPage.lend(
                token: frameToken,
                logicalDabScratch: &generatedLogicalDabScratch,
                dirtyRegionScratch: &preparedDirtyOutputScratch
            )
            outstandingPreparedOutputPageToken = frameToken
        } else {
            precondition(generatedLogicalDabScratch.isEmpty)
            precondition(preparedDirtyOutputScratch.isEmpty)
            logicalDabView = .empty
            dirtyRegionView = .empty
        }
        let batch = StrokePreparedDepositionBatch(
            generation: generation,
            sequence: sequence,
            frameToken: frameToken,
            logicalDabs: logicalDabView,
            dirtyRegions: dirtyRegionView,
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
        guard try appendProjectedRecordsToPage(
            for: dab,
            strategy: strategy,
            to: &records,
            maximumRecordCount: maximumRecordCount
        ) else {
            let (actual, overflow) = records.count.addingReportingOverflow(
                projectionScratch.fragments.count
            )
            throw StrokeFrameSchedulerError
                .projectedInstanceCapacityExceeded(
                    actual: overflow ? .max : actual,
                    maximum: maximumRecordCount
                )
        }
    }

    /// Returns `false` when the dab fits an empty page but not the remaining
    /// slots in this page. An indivisible dab that exceeds the full page stays
    /// a typed failure. No destination or logical state is mutated on pause.
    private func appendProjectedRecordsToPage(
        for dab: LogicalDab,
        strategy: TilingStrategy,
        to records: inout [StrokePreparedProjectedRecord],
        maximumRecordCount: Int
    ) throws -> Bool {
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
        do {
            try TilingProjection.project(
                footprint,
                using: strategy,
                into: projectionScratch,
                maximumFragmentCount: maximumRecordCount
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
        if overflow || projectedCount > maximumRecordCount {
            return false
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
        return true
    }

    private func appendPreparedActualDab(
        _ dab: LogicalDab,
        strategy: TilingStrategy,
        maximumDabCount: Int,
        maximumProjectedCount: Int
    ) throws {
        guard try appendPreparedActualDabToPage(
            dab,
            strategy: strategy,
            maximumDabCount: maximumDabCount,
            maximumProjectedCount: maximumProjectedCount
        ) else {
            let (actual, overflow) = generatedProjectionScratch.count
                .addingReportingOverflow(projectionScratch.fragments.count)
            throw StrokeFrameSchedulerError
                .projectedInstanceCapacityExceeded(
                    actual: overflow ? .max : actual,
                    maximum: maximumProjectedCount
                )
        }
    }

    private func appendPreparedActualDabToPage(
        _ dab: LogicalDab,
        strategy: TilingStrategy,
        maximumDabCount: Int,
        maximumProjectedCount: Int
    ) throws -> Bool {
        guard transientDabScratch.count < maximumDabCount else {
            throw StrokeFrameSchedulerError.generatedDabCapacityExceeded(
                actual: maximumDabCount + 1,
                maximum: maximumDabCount
            )
        }
        let projectedStart = generatedProjectionScratch.count
        guard try appendProjectedRecordsToPage(
            for: dab,
            strategy: strategy,
            to: &generatedProjectionScratch,
            maximumRecordCount: maximumProjectedCount
        ) else { return false }
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
        return true
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

    private func rollbackPreparedPredictionSampleScratch(
        transientStart: Int,
        projectedStart: Int
    ) {
        perSampleLogicalDabScratch.removeAll(keepingCapacity: true)
        transientDabScratch.removeSubrange(transientStart...)
        generatedProjectionScratch.removeSubrange(projectedStart...)
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

    private func injectStageCFailure(
        _ seam: StrokeStageCFailureInjectionSeam,
        generation: UInt64,
        drain: StrokeAuthoritativeCandidateDrain? = nil
    ) throws {
        guard let stageCFailureInjection else { return }
        let effectiveDrain = drain ?? authoritativeCandidateDrain
        try stageCFailureInjection(
            seam,
            context: StrokeStageCFailureInjectionContext(
                generation: generation,
                drainPhase: effectiveDrain?.phase.rawValue,
                sampleIndex: effectiveDrain?.sampleIndex ?? 0,
                consumedWorkUnits:
                    effectiveDrain?.currentResumeWorkUnits ?? 0
            )
        )
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
        precondition(!authoritativeAllocationProbeIsArmed)
        let lifecycleProbe = preparationAllocationProbe
        lifecycleProbe?.arm()
        defer {
            lifecycleProbe?.disarmAndRecord(.strokeLifecycleCPU)
            preparationAllocationProbe = nil
        }
        authoritativeCandidateDrain?.arenaTransaction.rollback()
        authoritativeCandidateDrain = nil
        candidatePageForcedSurfaceLayer = nil
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
        outstandingZeroWorkContinuationToken = nil
        outstandingPreparedOutputPageToken = nil
        preparedOutputPage.cancelBorrow()
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
        outstandingZeroWorkContinuationToken = nil
        outstandingPreparedOutputPageToken = nil
        candidatePageForcedSurfaceLayer = nil
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
