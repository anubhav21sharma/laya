import Foundation

/// Hard engine limits for one active stroke's replayable state.
public enum TransientStrokeBufferContract {
    public static let replayTailSampleCapacity = 256
    public static let replayTailDabCapacity = 2_048
    public static let wholeStrokeSampleCapacity = 4_096
    public static let wholeStrokeDabCapacity = 4_096
    public static let visibleEpochProjectedInstanceCapacity = 4_096
}

/// One generated dab plus its post-tiling cost in the visible replay epoch.
public struct TransientStrokeDab: Equatable, Sendable {
    public let attributes: LogicalDab
    public let projectedInstanceCount: Int

    public init(
        attributes: LogicalDab,
        projectedInstanceCount: Int
    ) {
        precondition(
            projectedInstanceCount >= 0,
            "Projected instance count must be nonnegative"
        )
        self.attributes = attributes
        self.projectedInstanceCount = projectedInstanceCount
    }
}

/// Replay state produced while consuming one ordered input sample.
///
/// Chunks are the indivisible promotion unit. Keeping sample, dabs, and the
/// generator state after that sample together gives replay a deterministic
/// boundary without retaining renderer or platform objects.
public struct TransientStrokeChunk: Equatable, Sendable {
    public let sample: WorldStrokeSample
    public let dabs: [TransientStrokeDab]
    public let generatorSnapshotBeforeSample: BrushStrokeGenerator?
    public let generatorSnapshotAfterSample: BrushStrokeGenerator?
    public let inputDeriverSnapshotBeforeSample: BrushInputDeriver?

    public init(
        sample: WorldStrokeSample,
        dabs: [TransientStrokeDab],
        generatorSnapshotBeforeSample: BrushStrokeGenerator? = nil,
        generatorSnapshotAfterSample: BrushStrokeGenerator? = nil,
        inputDeriverSnapshotBeforeSample: BrushInputDeriver? = nil
    ) {
        self.sample = sample
        self.dabs = dabs
        self.generatorSnapshotBeforeSample = generatorSnapshotBeforeSample
        self.generatorSnapshotAfterSample = generatorSnapshotAfterSample
        self.inputDeriverSnapshotBeforeSample =
            inputDeriverSnapshotBeforeSample
    }

    public var projectedInstanceCount: Int {
        dabs.reduce(into: 0) { result, dab in
            result = Self.saturatingAdd(
                result,
                dab.projectedInstanceCount
            )
        }
    }

    private static func saturatingAdd(_ left: Int, _ right: Int) -> Int {
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int.max : sum
    }
}

public enum TransientStrokeDegradationReason:
    UInt8, Equatable, Sendable
{
    case wholeStrokeCapacity
    case projectedInstanceCapacity
}

public enum TransientStrokeBufferError: Error, Equatable, Sendable {
    case nonPredictedSample
    case nonEstimatedUpdate
    case unknownEstimatedUpdateIndex(Int)
    case duplicateEstimatedUpdateIndex(Int)
    case estimatedUpdateAlreadyResolved(Int)
    case invalidEstimatedUpdateProperties(Int)
    case staleEstimatedUpdatePlan
    case invalidEstimatedReplacement
    case unresolvedSuffixExceedsCapacity(
        sampleCount: Int,
        dabCount: Int,
        projectedInstanceCount: Int
    )
    case predictedSuffixExceedsCapacity(
        sampleCount: Int,
        dabCount: Int,
        projectedInstanceCount: Int
    )
}

public enum EstimatedStrokeUpdateTarget: Equatable, Sendable {
    case authoritative
    case predicted
}

public struct EstimatedStrokeUpdatePlan: Equatable, Sendable {
    public let target: EstimatedStrokeUpdateTarget
    /// True buffer mutation version. The name is retained from the plan's
    /// public API; it is intentionally independent of renderer replay epochs.
    public let sourceReplayEpoch: UInt64
    public let replacedChunkIndex: Int
    public let mergedSample: WorldStrokeSample
    public let generatorBeforeReplacement: BrushStrokeGenerator?
    public let inputDeriverBeforeReplacement: BrushInputDeriver?
    public let samplesToReplay: [WorldStrokeSample]

    init(
        target: EstimatedStrokeUpdateTarget,
        sourceReplayEpoch: UInt64,
        replacedChunkIndex: Int,
        mergedSample: WorldStrokeSample,
        generatorBeforeReplacement: BrushStrokeGenerator?,
        inputDeriverBeforeReplacement: BrushInputDeriver?,
        samplesToReplay: [WorldStrokeSample]
    ) {
        self.target = target
        self.sourceReplayEpoch = sourceReplayEpoch
        self.replacedChunkIndex = replacedChunkIndex
        self.mergedSample = mergedSample
        self.generatorBeforeReplacement = generatorBeforeReplacement
        self.inputDeriverBeforeReplacement = inputDeriverBeforeReplacement
        self.samplesToReplay = samplesToReplay
    }
}

/// Renderer-facing result of one deterministic buffer mutation.
public struct TransientStrokeBufferUpdate: Equatable, Sendable {
    public let settledPrefix: [TransientStrokeChunk]
    public let requiresReplayReplacement: Bool
    public let replayWindowShortened: Bool
    public let degradedToReplayTail: Bool
    public let clearedPredictedSuffix: Bool
    public let replayEpoch: UInt64
    public let rejection: TransientStrokeBufferError?

    public init(
        settledPrefix: [TransientStrokeChunk],
        requiresReplayReplacement: Bool,
        replayWindowShortened: Bool,
        degradedToReplayTail: Bool,
        clearedPredictedSuffix: Bool,
        replayEpoch: UInt64,
        rejection: TransientStrokeBufferError? = nil
    ) {
        self.settledPrefix = settledPrefix
        self.requiresReplayReplacement = requiresReplayReplacement
        self.replayWindowShortened = replayWindowShortened
        self.degradedToReplayTail = degradedToReplayTail
        self.clearedPredictedSuffix = clearedPredictedSuffix
        self.replayEpoch = replayEpoch
        self.rejection = rejection
    }

    public static let noChange = TransientStrokeBufferUpdate(
        settledPrefix: [],
        requiresReplayReplacement: false,
        replayWindowShortened: false,
        degradedToReplayTail: false,
        clearedPredictedSuffix: false,
        replayEpoch: 0
    )

    public var settledDabCount: Int {
        settledPrefix.reduce(0) { $0 + $1.dabs.count }
    }

    public var settledProjectedInstanceCount: Int {
        settledPrefix.reduce(into: 0) { result, chunk in
            let (sum, overflow) = result.addingReportingOverflow(
                chunk.projectedInstanceCount
            )
            result = overflow ? Int.max : sum
        }
    }
}

/// Bounded, platform-free replay state for one active stroke.
///
/// Actual state is append-only. Prediction replaces only the predicted suffix.
/// Prefix promotion always removes oldest complete chunks, preserving a stable
/// generator snapshot at the new replay boundary.
public struct TransientStrokeBuffer: Equatable, Sendable {
    public let replayContract: BrushReplayContract
    public let requestedMode: BrushReplayMode
    public private(set) var mode: BrushReplayMode
    public private(set) var actualChunks: [TransientStrokeChunk]
    public private(set) var predictedChunks: [TransientStrokeChunk]
    public private(set) var replayEpoch: UInt64
    public private(set) var mutationVersion: UInt64
    public private(set) var degradationReason:
        TransientStrokeDegradationReason?
    public private(set) var degradationCount: Int
    public private(set) var settledPrefixPromotionCount: Int
    public private(set) var replayWindowShorteningCount: Int
    public private(set) var replayStartGeneratorSnapshot:
        BrushStrokeGenerator?
    public private(set) var authoritativeGeneratorSnapshot:
        BrushStrokeGenerator?
    public private(set) var predictedGeneratorSnapshot:
        BrushStrokeGenerator?
    private var actualDabCountStorage: Int
    private var predictedDabCountStorage: Int
    private var actualProjectedInstanceCountStorage: Int
    private var predictedProjectedInstanceCountStorage: Int

    public init(replayContract: BrushReplayContract) {
        self.replayContract = replayContract
        requestedMode = replayContract.mode
        mode = replayContract.mode
        actualChunks = []
        predictedChunks = []
        replayEpoch = 0
        mutationVersion = 0
        degradationReason = nil
        degradationCount = 0
        settledPrefixPromotionCount = 0
        replayWindowShorteningCount = 0
        replayStartGeneratorSnapshot = nil
        authoritativeGeneratorSnapshot = nil
        predictedGeneratorSnapshot = nil
        actualDabCountStorage = 0
        predictedDabCountStorage = 0
        actualProjectedInstanceCountStorage = 0
        predictedProjectedInstanceCountStorage = 0
    }

    public var activeReplayLimits: BrushReplayLimits {
        capacitiesForCurrentMode()
    }

    public var actualSamples: [WorldStrokeSample] {
        actualChunks.map(\.sample)
    }

    public var predictedSamples: [WorldStrokeSample] {
        predictedChunks.map(\.sample)
    }

    public var actualDabs: [TransientStrokeDab] {
        actualChunks.flatMap(\.dabs)
    }

    public var predictedDabs: [TransientStrokeDab] {
        predictedChunks.flatMap(\.dabs)
    }

    public var replayChunks: [TransientStrokeChunk] {
        actualChunks + predictedChunks
    }

    public var actualSampleCount: Int { actualChunks.count }
    public var predictedSampleCount: Int { predictedChunks.count }
    public var retainedSampleCount: Int {
        actualSampleCount + predictedSampleCount
    }

    public var actualDabCount: Int {
        actualDabCountStorage
    }

    public var predictedDabCount: Int {
        predictedDabCountStorage
    }

    public var retainedDabCount: Int {
        actualDabCount + predictedDabCount
    }

    public var visibleProjectedInstanceCount: Int {
        Self.saturatingAdd(
            actualProjectedInstanceCountStorage,
            predictedProjectedInstanceCountStorage
        )
    }

    /// Appends one authoritative sample. Any prediction is discarded first.
    /// Append-only chunks are returned immediately for settled-live rendering.
    @discardableResult
    public mutating func appendActual(
        _ chunk: TransientStrokeChunk
    ) -> TransientStrokeBufferUpdate {
        precondition(
            chunk.sample.kind != .predicted,
            "Authoritative append cannot contain a predicted sample"
        )
        let retainsAppendOnlySuffix = mode == .appendOnly
            && (
                !actualChunks.isEmpty
                    || !chunk.sample
                        .estimatedPropertiesExpectingUpdates.isEmpty
            )
        if retainsAppendOnlySuffix,
           let rejection = unresolvedAppendOnlyOverflow(adding: chunk)
        {
            return TransientStrokeBufferUpdate(
                settledPrefix: [],
                requiresReplayReplacement: false,
                replayWindowShortened: false,
                degradedToReplayTail: false,
                clearedPredictedSuffix: false,
                replayEpoch: replayEpoch,
                rejection: rejection
            )
        }
        advanceMutationVersion()

        let clearedPrediction = !predictedChunks.isEmpty
        if clearedPrediction {
            predictedChunks.removeAll(keepingCapacity: true)
            predictedGeneratorSnapshot = nil
            predictedDabCountStorage = 0
            predictedProjectedInstanceCountStorage = 0
        }
        if let snapshot = chunk.generatorSnapshotAfterSample {
            authoritativeGeneratorSnapshot = snapshot
        }

        if mode == .appendOnly {
            if !actualChunks.isEmpty
                || !chunk.sample.estimatedPropertiesExpectingUpdates.isEmpty
            {
                actualChunks.append(chunk)
                recalculateActualCounters()
                let settled = promoteResolvedAppendOnlyPrefix()
                advanceReplayEpoch()
                return TransientStrokeBufferUpdate(
                    settledPrefix: settled,
                    requiresReplayReplacement: true,
                    replayWindowShortened: false,
                    degradedToReplayTail: false,
                    clearedPredictedSuffix: clearedPrediction,
                    replayEpoch: replayEpoch
                )
            }
            if clearedPrediction {
                advanceReplayEpoch()
            }
            return TransientStrokeBufferUpdate(
                settledPrefix: [chunk],
                requiresReplayReplacement: clearedPrediction,
                replayWindowShortened: false,
                degradedToReplayTail: false,
                clearedPredictedSuffix: clearedPrediction,
                replayEpoch: replayEpoch
            )
        }

        actualChunks.append(chunk)
        actualDabCountStorage = Self.saturatingAdd(
            actualDabCountStorage,
            chunk.dabs.count
        )
        actualProjectedInstanceCountStorage = Self.saturatingAdd(
            actualProjectedInstanceCountStorage,
            chunk.projectedInstanceCount
        )
        var didDegrade = false
        if mode == .boundedWholeStroke,
           let reason = wholeStrokeOverflowReason()
        {
            mode = .replayTail
            degradationReason = reason
            degradationCount += 1
            didDegrade = true
        }

        let capacities = capacitiesForCurrentMode()
        let projectedOverflow = visibleProjectedInstanceCount
            > capacities.maximumProjectedInstances
        let settled = promoteUntilWithinLimits(
            sampleCapacity: capacities.maximumSamples,
            dabCapacity: capacities.maximumDabs,
            projectedInstanceCapacity: capacities.maximumProjectedInstances
        )
        let shortened = projectedOverflow && !settled.isEmpty
        recordPromotion(settled, shortened: shortened)

        let requiresReplacement = clearedPrediction
            || !settled.isEmpty
            || didDegrade
        if requiresReplacement {
            advanceReplayEpoch()
        }
        return TransientStrokeBufferUpdate(
            settledPrefix: settled,
            requiresReplayReplacement: requiresReplacement,
            replayWindowShortened: shortened,
            degradedToReplayTail: didDegrade,
            clearedPredictedSuffix: clearedPrediction,
            replayEpoch: replayEpoch
        )
    }

    /// Atomically replaces the predicted suffix. Actual chunks and their
    /// generator snapshot are never changed by prediction.
    @discardableResult
    public mutating func replacePredicted(
        with chunks: [TransientStrokeChunk]
    ) throws -> TransientStrokeBufferUpdate {
        guard chunks.allSatisfy({ $0.sample.kind == .predicted }) else {
            throw TransientStrokeBufferError.nonPredictedSample
        }
        guard chunks != predictedChunks else {
            return noChangeUpdate()
        }

        let predictedDabCount = chunks.reduce(into: 0) { result, chunk in
            result = Self.saturatingAdd(result, chunk.dabs.count)
        }
        let predictedProjectedCount = Self.projectedInstanceCount(chunks)
        let capacities = capacitiesForCurrentMode()
        guard
            chunks.count <= capacities.maximumSamples,
            predictedDabCount <= capacities.maximumDabs,
            predictedProjectedCount <= capacities.maximumProjectedInstances
        else {
            throw TransientStrokeBufferError
                .predictedSuffixExceedsCapacity(
                    sampleCount: chunks.count,
                    dabCount: predictedDabCount,
                    projectedInstanceCount: predictedProjectedCount
                )
        }

        var updated = self
        let clearedPrediction = !updated.predictedChunks.isEmpty
        updated.predictedChunks = chunks
        updated.predictedDabCountStorage = predictedDabCount
        updated.predictedProjectedInstanceCountStorage =
            predictedProjectedCount
        updated.predictedGeneratorSnapshot = chunks.last?
            .generatorSnapshotAfterSample
        var didDegrade = false
        if updated.mode == .boundedWholeStroke,
           let reason = updated.combinedWholeStrokeOverflowReason()
        {
            updated.mode = .replayTail
            updated.degradationReason = reason
            updated.degradationCount += 1
            didDegrade = true
        }
        let updatedCapacities = updated.capacitiesForCurrentMode()
        let settled = updated.promoteUntilWithinLimits(
            sampleCapacity: updatedCapacities.maximumSamples,
            dabCapacity: updatedCapacities.maximumDabs,
            projectedInstanceCapacity:
                updatedCapacities.maximumProjectedInstances
        )
        guard
            updated.retainedSampleCount <= updatedCapacities.maximumSamples,
            updated.retainedDabCount <= updatedCapacities.maximumDabs,
            updated.visibleProjectedInstanceCount
                <= updatedCapacities.maximumProjectedInstances
        else {
            throw TransientStrokeBufferError
                .predictedSuffixExceedsCapacity(
                    sampleCount: chunks.count,
                    dabCount: predictedDabCount,
                    projectedInstanceCount: predictedProjectedCount
                )
        }

        let shortened = !settled.isEmpty
        updated.recordPromotion(settled, shortened: shortened)
        updated.advanceReplayEpoch()
        updated.advanceMutationVersion()
        self = updated
        return TransientStrokeBufferUpdate(
            settledPrefix: settled,
            requiresReplayReplacement: true,
            replayWindowShortened: shortened,
            degradedToReplayTail: didDegrade,
            clearedPredictedSuffix: clearedPrediction,
            replayEpoch: replayEpoch
        )
    }

    @discardableResult
    public mutating func discardPredicted()
        -> TransientStrokeBufferUpdate
    {
        guard !predictedChunks.isEmpty else { return noChangeUpdate() }
        predictedChunks.removeAll(keepingCapacity: true)
        predictedGeneratorSnapshot = nil
        predictedDabCountStorage = 0
        predictedProjectedInstanceCountStorage = 0
        advanceReplayEpoch()
        advanceMutationVersion()
        return TransientStrokeBufferUpdate(
            settledPrefix: [],
            requiresReplayReplacement: true,
            replayWindowShortened: false,
            degradedToReplayTail: false,
            clearedPredictedSuffix: true,
            replayEpoch: replayEpoch
        )
    }

    /// Deterministically promotes oldest actual chunks until the visible
    /// replay epoch fits the requested post-projection budget.
    @discardableResult
    public mutating func shortenReplayWindow(
        maximumProjectedInstanceCount: Int
    ) -> TransientStrokeBufferUpdate {
        precondition(
            maximumProjectedInstanceCount >= 0
                && maximumProjectedInstanceCount
                    <= capacitiesForCurrentMode()
                        .maximumProjectedInstances,
            "Replay window must fit the validated recipe cap"
        )
        guard
            mode != .appendOnly,
            visibleProjectedInstanceCount
                > maximumProjectedInstanceCount
        else {
            return noChangeUpdate()
        }

        var didDegrade = false
        if mode == .boundedWholeStroke {
            mode = .replayTail
            degradationReason = .projectedInstanceCapacity
            degradationCount += 1
            didDegrade = true
        }
        let capacities = capacitiesForCurrentMode()
        let settled = promoteUntilWithinLimits(
            sampleCapacity: capacities.maximumSamples,
            dabCapacity: capacities.maximumDabs,
            projectedInstanceCapacity: maximumProjectedInstanceCount
        )
        guard !settled.isEmpty else { return noChangeUpdate() }

        recordPromotion(settled, shortened: true)
        advanceReplayEpoch()
        advanceMutationVersion()
        return TransientStrokeBufferUpdate(
            settledPrefix: settled,
            requiresReplayReplacement: true,
            replayWindowShortened: true,
            degradedToReplayTail: didDegrade,
            clearedPredictedSuffix: false,
            replayEpoch: replayEpoch
        )
    }

    /// Clears all transient state and restores the recipe-requested mode.
    public mutating func cancel() {
        advanceMutationVersion()
        mode = requestedMode
        actualChunks.removeAll(keepingCapacity: true)
        predictedChunks.removeAll(keepingCapacity: true)
        replayEpoch = 0
        degradationReason = nil
        degradationCount = 0
        settledPrefixPromotionCount = 0
        replayWindowShorteningCount = 0
        replayStartGeneratorSnapshot = nil
        authoritativeGeneratorSnapshot = nil
        predictedGeneratorSnapshot = nil
        actualDabCountStorage = 0
        predictedDabCountStorage = 0
        actualProjectedInstanceCountStorage = 0
        predictedProjectedInstanceCountStorage = 0
    }

    public mutating func reset() {
        cancel()
    }

    public func planEstimatedUpdate(
        _ update: WorldStrokeSample
    ) throws -> EstimatedStrokeUpdatePlan {
        guard update.kind == .estimatedUpdate,
              let updateIndex = update.estimationUpdateIndex
        else {
            throw TransientStrokeBufferError.nonEstimatedUpdate
        }
        let actualMatches = actualChunks.indices.filter {
            actualChunks[$0].sample.estimationUpdateIndex == updateIndex
        }
        let predictedMatches = predictedChunks.indices.filter {
            predictedChunks[$0].sample.estimationUpdateIndex == updateIndex
        }
        let totalMatches = actualMatches.count + predictedMatches.count
        guard totalMatches > 0 else {
            throw TransientStrokeBufferError
                .unknownEstimatedUpdateIndex(updateIndex)
        }
        guard totalMatches == 1 else {
            throw TransientStrokeBufferError
                .duplicateEstimatedUpdateIndex(updateIndex)
        }

        let target: EstimatedStrokeUpdateTarget
        let index: Int
        let chunks: [TransientStrokeChunk]
        if let actual = actualMatches.first {
            target = .authoritative
            index = actual
            chunks = actualChunks
        } else {
            target = .predicted
            index = predictedMatches[0]
            chunks = predictedChunks
        }
        let originalChunk = chunks[index]
        let original = originalChunk.sample
        guard !original.estimatedPropertiesExpectingUpdates.isEmpty else {
            throw TransientStrokeBufferError
                .estimatedUpdateAlreadyResolved(updateIndex)
        }
        guard update.estimatedProperties.isSubset(
            of: original.estimatedProperties
        ), update.estimatedPropertiesExpectingUpdates.isSubset(
            of: original.estimatedPropertiesExpectingUpdates
        ) else {
            throw TransientStrokeBufferError
                .invalidEstimatedUpdateProperties(updateIndex)
        }

        let expecting = original.estimatedPropertiesExpectingUpdates
        var merged = original.replacing(
            position: expecting.contains(.location)
                ? update.position
                : original.position,
            pressure: expecting.contains(.pressure)
                ? update.pressure
                : original.pressure,
            altitude: expecting.contains(.altitude)
                ? .some(update.altitude)
                : nil,
            azimuth: expecting.contains(.azimuth)
                ? .some(update.azimuth)
                : nil,
            roll: expecting.contains(.roll)
                ? .some(update.roll)
                : nil,
            estimatedProperties: update.estimatedProperties,
            estimatedPropertiesExpectingUpdates:
                update.estimatedPropertiesExpectingUpdates
        )
        var replay = Array(chunks.dropFirst(index + 1).map(\.sample))
        let deriverCheckpoint =
            originalChunk.inputDeriverSnapshotBeforeSample
        if var deriver = deriverCheckpoint {
            merged = deriver.rederive(merged)
            replay = replay.map { deriver.rederive($0) }
        }
        let generatorBefore =
            originalChunk.generatorSnapshotBeforeSample
                ?? (index == 0
                    ? (target == .authoritative
                        ? replayStartGeneratorSnapshot
                        : authoritativeGeneratorSnapshot)
                    : chunks[index - 1].generatorSnapshotAfterSample)
        return EstimatedStrokeUpdatePlan(
            target: target,
            sourceReplayEpoch: mutationVersion,
            replacedChunkIndex: index,
            mergedSample: merged,
            generatorBeforeReplacement: generatorBefore,
            inputDeriverBeforeReplacement: deriverCheckpoint,
            samplesToReplay: replay
        )
    }

    @discardableResult
    public mutating func replaceEstimatedSuffix(
        using plan: EstimatedStrokeUpdatePlan,
        with rebuiltChunks: [TransientStrokeChunk]
    ) throws -> TransientStrokeBufferUpdate {
        guard plan.sourceReplayEpoch == mutationVersion else {
            throw TransientStrokeBufferError.staleEstimatedUpdatePlan
        }
        guard rebuiltChunks.count == plan.samplesToReplay.count + 1,
              rebuiltChunks.first?.sample == plan.mergedSample,
              Array(rebuiltChunks.dropFirst().map(\.sample))
                == plan.samplesToReplay
        else {
            throw TransientStrokeBufferError.invalidEstimatedReplacement
        }

        var updated = self
        let clearedPrediction: Bool
        switch plan.target {
        case .authoritative:
            guard plan.replacedChunkIndex < updated.actualChunks.count,
                  updated.actualChunks[plan.replacedChunkIndex]
                    .sample.estimationUpdateIndex
                    == plan.mergedSample.estimationUpdateIndex,
                  rebuiltChunks.allSatisfy({
                      $0.sample.kind != .predicted
                  })
            else {
                throw TransientStrokeBufferError.invalidEstimatedReplacement
            }
            updated.actualChunks.replaceSubrange(
                plan.replacedChunkIndex...,
                with: rebuiltChunks
            )
            clearedPrediction = !updated.predictedChunks.isEmpty
            updated.predictedChunks.removeAll(keepingCapacity: true)
            updated.predictedGeneratorSnapshot = nil
        case .predicted:
            guard plan.replacedChunkIndex < updated.predictedChunks.count,
                  updated.predictedChunks[plan.replacedChunkIndex]
                    .sample.estimationUpdateIndex
                    == plan.mergedSample.estimationUpdateIndex,
                  rebuiltChunks.allSatisfy({
                      $0.sample.kind == .predicted
                  })
            else {
                throw TransientStrokeBufferError.invalidEstimatedReplacement
            }
            updated.predictedChunks.replaceSubrange(
                plan.replacedChunkIndex...,
                with: rebuiltChunks
            )
            clearedPrediction = false
        }

        let rebuiltAuthoritativeGeneratorSnapshot =
            updated.actualChunks.last?.generatorSnapshotAfterSample
                ?? updated.authoritativeGeneratorSnapshot
        let rebuiltPredictedGeneratorSnapshot =
            updated.predictedChunks.last?.generatorSnapshotAfterSample
        updated.recalculateAllCounters()
        var settled: [TransientStrokeChunk] = []
        if updated.mode == .appendOnly {
            settled = updated.promoteResolvedAppendOnlyPrefix()
        }
        let limits = updated.capacitiesForCurrentMode()
        guard updated.retainedSampleCount <= limits.maximumSamples,
              updated.retainedDabCount <= limits.maximumDabs,
              updated.visibleProjectedInstanceCount
                <= limits.maximumProjectedInstances
        else {
            throw TransientStrokeBufferError.predictedSuffixExceedsCapacity(
                sampleCount: updated.retainedSampleCount,
                dabCount: updated.retainedDabCount,
                projectedInstanceCount:
                    updated.visibleProjectedInstanceCount
            )
        }

        updated.authoritativeGeneratorSnapshot =
            rebuiltAuthoritativeGeneratorSnapshot
        updated.predictedGeneratorSnapshot =
            rebuiltPredictedGeneratorSnapshot
        updated.advanceReplayEpoch()
        updated.advanceMutationVersion()
        self = updated
        return TransientStrokeBufferUpdate(
            settledPrefix: settled,
            requiresReplayReplacement: true,
            replayWindowShortened: false,
            degradedToReplayTail: false,
            clearedPredictedSuffix: clearedPrediction,
            replayEpoch: replayEpoch
        )
    }

    private func capacitiesForCurrentMode() -> BrushReplayLimits {
        switch mode {
        case .appendOnly:
            return BrushRecipePolicy.replayTailLimits
        case .replayTail:
            let declared = replayContract.limits
                ?? BrushRecipePolicy.replayTailLimits
            return Self.minimumLimits(
                declared,
                BrushRecipePolicy.replayTailLimits
            )
        case .boundedWholeStroke:
            return replayContract.limits
                ?? BrushRecipePolicy.wholeStrokeLimits
        }
    }

    private func unresolvedAppendOnlyOverflow(
        adding chunk: TransientStrokeChunk
    ) -> TransientStrokeBufferError? {
        let limits = capacitiesForCurrentMode()
        let sampleCount = Self.saturatingAdd(actualSampleCount, 1)
        let dabCount = Self.saturatingAdd(
            actualDabCountStorage,
            chunk.dabs.count
        )
        let projectedInstanceCount = Self.saturatingAdd(
            actualProjectedInstanceCountStorage,
            chunk.projectedInstanceCount
        )
        guard sampleCount > limits.maximumSamples
                || dabCount > limits.maximumDabs
                || projectedInstanceCount
                    > limits.maximumProjectedInstances
        else {
            return nil
        }
        return .unresolvedSuffixExceedsCapacity(
            sampleCount: sampleCount,
            dabCount: dabCount,
            projectedInstanceCount: projectedInstanceCount
        )
    }

    private func wholeStrokeOverflowReason()
        -> TransientStrokeDegradationReason?
    {
        let limits = replayContract.limits
            ?? BrushRecipePolicy.wholeStrokeLimits
        if actualSampleCount > limits.maximumSamples
            || actualDabCount > limits.maximumDabs
        {
            return .wholeStrokeCapacity
        }
        if visibleProjectedInstanceCount > limits.maximumProjectedInstances {
            return .projectedInstanceCapacity
        }
        return nil
    }

    private func combinedWholeStrokeOverflowReason()
        -> TransientStrokeDegradationReason?
    {
        let limits = replayContract.limits
            ?? BrushRecipePolicy.wholeStrokeLimits
        if retainedSampleCount > limits.maximumSamples
            || retainedDabCount > limits.maximumDabs
        {
            return .wholeStrokeCapacity
        }
        if visibleProjectedInstanceCount > limits.maximumProjectedInstances {
            return .projectedInstanceCapacity
        }
        return nil
    }

    private mutating func promoteUntilWithinLimits(
        sampleCapacity: Int,
        dabCapacity: Int,
        projectedInstanceCapacity: Int
    ) -> [TransientStrokeChunk] {
        var retainedSamples = retainedSampleCount
        var retainedDabs = retainedDabCount
        var retainedProjectedInstances = visibleProjectedInstanceCount
        var prefixCount = 0

        while
            prefixCount < actualChunks.count,
            retainedSamples > sampleCapacity
                || retainedDabs > dabCapacity
                || retainedProjectedInstances
                    > projectedInstanceCapacity
        {
            let chunk = actualChunks[prefixCount]
            if !chunk.sample.estimatedPropertiesExpectingUpdates.isEmpty {
                break
            }
            retainedSamples -= 1
            retainedDabs -= chunk.dabs.count
            retainedProjectedInstances -= chunk.projectedInstanceCount
            prefixCount += 1
        }
        guard prefixCount > 0 else { return [] }

        let settled = Array(actualChunks.prefix(prefixCount))
        actualChunks.removeFirst(prefixCount)
        for chunk in settled {
            actualDabCountStorage -= chunk.dabs.count
            actualProjectedInstanceCountStorage -=
                chunk.projectedInstanceCount
            if let snapshot = chunk.generatorSnapshotAfterSample {
                replayStartGeneratorSnapshot = snapshot
            }
        }
        return settled
    }

    private mutating func recordPromotion(
        _ settled: [TransientStrokeChunk],
        shortened: Bool
    ) {
        guard !settled.isEmpty else { return }
        settledPrefixPromotionCount += 1
        if shortened {
            replayWindowShorteningCount += 1
        }
    }

    private mutating func advanceReplayEpoch() {
        let (next, overflow) = replayEpoch.addingReportingOverflow(1)
        precondition(!overflow, "Replay epoch exhausted")
        replayEpoch = next
    }

    private mutating func advanceMutationVersion() {
        let (next, overflow) = mutationVersion.addingReportingOverflow(1)
        precondition(!overflow, "Transient mutation version exhausted")
        mutationVersion = next
    }

    private mutating func promoteResolvedAppendOnlyPrefix()
        -> [TransientStrokeChunk]
    {
        let firstUnresolved = actualChunks.firstIndex {
            !$0.sample.estimatedPropertiesExpectingUpdates.isEmpty
        } ?? actualChunks.endIndex
        guard firstUnresolved > actualChunks.startIndex else { return [] }
        let settled = Array(actualChunks[..<firstUnresolved])
        actualChunks.removeFirst(firstUnresolved)
        for chunk in settled {
            if let snapshot = chunk.generatorSnapshotAfterSample {
                replayStartGeneratorSnapshot = snapshot
            }
        }
        recalculateActualCounters()
        return settled
    }

    private mutating func recalculateActualCounters() {
        actualDabCountStorage = actualChunks.reduce(0) {
            Self.saturatingAdd($0, $1.dabs.count)
        }
        actualProjectedInstanceCountStorage =
            Self.projectedInstanceCount(actualChunks)
    }

    private mutating func recalculateAllCounters() {
        recalculateActualCounters()
        predictedDabCountStorage = predictedChunks.reduce(0) {
            Self.saturatingAdd($0, $1.dabs.count)
        }
        predictedProjectedInstanceCountStorage =
            Self.projectedInstanceCount(predictedChunks)
    }

    private func noChangeUpdate() -> TransientStrokeBufferUpdate {
        TransientStrokeBufferUpdate(
            settledPrefix: [],
            requiresReplayReplacement: false,
            replayWindowShortened: false,
            degradedToReplayTail: false,
            clearedPredictedSuffix: false,
            replayEpoch: replayEpoch
        )
    }

    private static func projectedInstanceCount(
        _ chunks: [TransientStrokeChunk]
    ) -> Int {
        chunks.reduce(into: 0) { result, chunk in
            result = saturatingAdd(result, chunk.projectedInstanceCount)
        }
    }

    private static func saturatingAdd(_ left: Int, _ right: Int) -> Int {
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int.max : sum
    }

    private static func minimumLimits(
        _ first: BrushReplayLimits,
        _ second: BrushReplayLimits
    ) -> BrushReplayLimits {
        BrushReplayLimits(
            maximumSamples: min(
                first.maximumSamples,
                second.maximumSamples
            ),
            maximumDabs: min(first.maximumDabs, second.maximumDabs),
            maximumProjectedInstances: min(
                first.maximumProjectedInstances,
                second.maximumProjectedInstances
            )
        )
    }
}
