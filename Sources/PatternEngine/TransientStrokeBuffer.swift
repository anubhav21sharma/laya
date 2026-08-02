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

/// Fixed renderer-owned storage for transient dabs. The backing array is
/// allocated once; slices are lightweight ranges and never own collections.
public final class TransientStrokeDabArena: @unchecked Sendable {
    public enum ReservationError: Error, Equatable, Sendable {
        case transactionAlreadyActive
        case capacityExceeded(Int)
        case inactiveTransaction
    }

    public static let retainedCapacity =
        TransientStrokeBufferContract.wholeStrokeDabCapacity
    private static let actualCapacity = retainedCapacity * 2
    private static let predictionBankCapacity = retainedCapacity
    private static let predictionCapacity = predictionBankCapacity * 2

    private var storage: [TransientStrokeDab?]
    private var slotGeneration: [UInt64]
    private var slotTransaction: [UInt64]
    private var retainedMarker: [UInt64]
    private var actualSearchCursor = 0
    private var predictionSearchCursor = 0
    private var nextTransaction: UInt64 = 1
    private var nextGeneration: UInt64 = 1
    private var nextRetainedMarker: UInt64 = 1
    private var activeTransaction: UInt64?

    public struct DiagnosticSnapshot: Equatable, Sendable {
        public struct OccupiedSlot: Equatable, Sendable {
            public let index: Int
            public let dab: TransientStrokeDab
            public let generation: UInt64
            public let retainedMarker: UInt64
        }

        public let occupiedSlotCount: Int
        public let actualSearchCursor: Int
        public let predictionSearchCursor: Int
        public let committedGenerationChecksum: UInt64
        public let occupiedSlots: [OccupiedSlot]
    }

    public var diagnosticSnapshot: DiagnosticSnapshot {
        var occupiedSlotCount = 0
        var committedGenerationChecksum: UInt64 = 0
        var occupiedSlots: [DiagnosticSnapshot.OccupiedSlot] = []
        occupiedSlots.reserveCapacity(Self.retainedCapacity * 2)
        for slot in storage.indices where slotGeneration[slot] != 0 {
            occupiedSlotCount += 1
            committedGenerationChecksum &+= slotGeneration[slot]
            occupiedSlots.append(
                DiagnosticSnapshot.OccupiedSlot(
                    index: slot,
                    dab: storage[slot]!,
                    generation: slotGeneration[slot],
                    retainedMarker: retainedMarker[slot]
                )
            )
        }
        return DiagnosticSnapshot(
            occupiedSlotCount: occupiedSlotCount,
            actualSearchCursor: actualSearchCursor,
            predictionSearchCursor: predictionSearchCursor,
            committedGenerationChecksum: committedGenerationChecksum,
            occupiedSlots: occupiedSlots
        )
    }

    public init() {
        let capacity = Self.actualCapacity
            + 2 * Self.predictionBankCapacity
        storage = [TransientStrokeDab?](repeating: nil, count: capacity)
        slotGeneration = [UInt64](repeating: 0, count: capacity)
        slotTransaction = [UInt64](repeating: 0, count: capacity)
        retainedMarker = [UInt64](repeating: 0, count: capacity)
    }

    public func reset() {
        storage.indices.forEach {
            storage[$0] = nil
            slotGeneration[$0] = 0
            slotTransaction[$0] = 0
            retainedMarker[$0] = 0
        }
        actualSearchCursor = 0
        predictionSearchCursor = 0
        activeTransaction = nil
    }

    public func beginTransaction(
        replacingPrediction: Bool
    ) throws -> ReservationTransaction {
        guard activeTransaction == nil else {
            throw ReservationError.transactionAlreadyActive
        }
        let identifier = nextTransaction
        nextTransaction &+= 1
        precondition(nextTransaction != 0)
        activeTransaction = identifier
        return ReservationTransaction(
            arena: self,
            identifier: identifier,
            allowsPrediction: replacingPrediction,
            actualCursorBefore: actualSearchCursor,
            predictionCursorBefore: predictionSearchCursor
        )
    }

    /// Value token for one arena reservation transaction. The arena owns all
    /// transaction state, so creating a token does not allocate. Callers must
    /// use `defer { token.rollback() }`; rollback is a no-op after commit.
    public struct ReservationTransaction: @unchecked Sendable {
        private let arena: TransientStrokeDabArena
        fileprivate let identifier: UInt64
        fileprivate let allowsPrediction: Bool
        private let actualCursorBefore: Int
        private let predictionCursorBefore: Int

        fileprivate init(
            arena: TransientStrokeDabArena,
            identifier: UInt64,
            allowsPrediction: Bool,
            actualCursorBefore: Int,
            predictionCursorBefore: Int
        ) {
            self.arena = arena
            self.identifier = identifier
            self.allowsPrediction = allowsPrediction
            self.actualCursorBefore = actualCursorBefore
            self.predictionCursorBefore = predictionCursorBefore
        }

        package func storeActual(
            _ dabs: [TransientStrokeDab],
            range: Range<Int>
        ) throws -> TransientStrokeDabSlice {
            return try arena.storeActual(
                transaction: identifier,
                dabs,
                range: range
            )
        }

        public func storeActual(
            count: Int,
            elementAt: (Int) -> TransientStrokeDab
        ) throws -> TransientStrokeDabSlice {
            try arena.storeActual(
                transaction: identifier,
                count: count,
                elementAt: elementAt
            )
        }

        package func storePredicted(
            _ dabs: [TransientStrokeDab],
            range: Range<Int>
        ) throws -> TransientStrokeDabSlice {
            guard allowsPrediction else {
                throw ReservationError.inactiveTransaction
            }
            return try arena.storePredicted(
                transaction: identifier,
                dabs,
                range: range
            )
        }

        public func storePredicted(
            count: Int,
            elementAt: (Int) -> TransientStrokeDab
        ) throws -> TransientStrokeDabSlice {
            guard allowsPrediction else {
                throw ReservationError.inactiveTransaction
            }
            return try arena.storePredicted(
                transaction: identifier,
                count: count,
                elementAt: elementAt
            )
        }

        public func commit(
            retainingActual actualChunks: [TransientStrokeChunk],
            retainingPredicted predictedChunks: [TransientStrokeChunk]
        ) throws {
            try arena.commit(
                identifier,
                retainingActual: actualChunks,
                retainingPredicted: predictedChunks
            )
        }

        public func commit<
            ActualChunks: Collection,
            PredictedChunks: Collection
        >(
            retainingActual actualChunks: ActualChunks,
            retainingPredicted predictedChunks: PredictedChunks
        ) throws
        where
            ActualChunks.Element == TransientStrokeChunk,
            PredictedChunks.Element == TransientStrokeChunk
        {
            try commit(
                retainingActual: Array(actualChunks),
                retainingPredicted: Array(predictedChunks)
            )
        }

        public func rollback() {
            arena.rollback(
                identifier,
                actualCursorBefore: actualCursorBefore,
                predictionCursorBefore: predictionCursorBefore
            )
        }
    }

    private func storeActual(
        transaction: UInt64,
        _ dabs: [TransientStrokeDab],
        range: Range<Int>
    ) throws -> TransientStrokeDabSlice {
        guard activeTransaction == transaction else {
            throw ReservationError.inactiveTransaction
        }
        let count = range.count
        guard (0 ... Self.retainedCapacity).contains(count) else {
            throw ReservationError.capacityExceeded(
                Self.retainedCapacity
            )
        }
        let start = try freeActualStart(count: count)
        let generation = reserveGeneration()
        var offset = 0
        while offset < count {
            let slot = (start + offset) % Self.actualCapacity
            storage[slot] = dabs[range.lowerBound + offset]
            slotGeneration[slot] = generation
            slotTransaction[slot] = transaction
            offset += 1
        }
        actualSearchCursor = (start + count) % Self.actualCapacity
        return TransientStrokeDabSlice(
            arena: self,
            regionStart: 0,
            regionCapacity: Self.actualCapacity,
            start: start,
            count: count,
            generation: generation
        )
    }

    private func storeActual(
        transaction: UInt64,
        count: Int,
        elementAt: (Int) -> TransientStrokeDab
    ) throws -> TransientStrokeDabSlice {
        guard activeTransaction == transaction else {
            throw ReservationError.inactiveTransaction
        }
        guard (0 ... Self.retainedCapacity).contains(count) else {
            throw ReservationError.capacityExceeded(
                Self.retainedCapacity
            )
        }
        let start = try freeActualStart(count: count)
        let generation = reserveGeneration()
        var offset = 0
        while offset < count {
            let slot = (start + offset) % Self.actualCapacity
            storage[slot] = elementAt(offset)
            slotGeneration[slot] = generation
            slotTransaction[slot] = transaction
            offset += 1
        }
        actualSearchCursor = (start + count) % Self.actualCapacity
        return TransientStrokeDabSlice(
            arena: self,
            regionStart: 0,
            regionCapacity: Self.actualCapacity,
            start: start,
            count: count,
            generation: generation
        )
    }

    private func storePredicted(
        transaction: UInt64,
        _ dabs: [TransientStrokeDab],
        range: Range<Int>
    ) throws -> TransientStrokeDabSlice {
        guard activeTransaction == transaction else {
            throw ReservationError.inactiveTransaction
        }
        let count = range.count
        guard (0 ... Self.retainedCapacity).contains(count)
        else {
            throw ReservationError.capacityExceeded(
                Self.retainedCapacity
            )
        }
        let regionStart = Self.actualCapacity
        let start = try freePredictionStart(count: count)
        let generation = reserveGeneration()
        var offset = 0
        while offset < count {
            let slot = regionStart
                + (start + offset) % Self.predictionCapacity
            storage[slot] = dabs[range.lowerBound + offset]
            slotGeneration[slot] = generation
            slotTransaction[slot] = transaction
            offset += 1
        }
        predictionSearchCursor =
            (start + count) % Self.predictionCapacity
        return TransientStrokeDabSlice(
            arena: self,
            regionStart: regionStart,
            regionCapacity: Self.predictionCapacity,
            start: start,
            count: count,
            generation: generation
        )
    }

    private func storePredicted(
        transaction: UInt64,
        count: Int,
        elementAt: (Int) -> TransientStrokeDab
    ) throws -> TransientStrokeDabSlice {
        guard activeTransaction == transaction else {
            throw ReservationError.inactiveTransaction
        }
        guard (0 ... Self.retainedCapacity).contains(count) else {
            throw ReservationError.capacityExceeded(
                Self.retainedCapacity
            )
        }
        let regionStart = Self.actualCapacity
        let start = try freePredictionStart(count: count)
        let generation = reserveGeneration()
        var offset = 0
        while offset < count {
            let slot = regionStart
                + (start + offset) % Self.predictionCapacity
            storage[slot] = elementAt(offset)
            slotGeneration[slot] = generation
            slotTransaction[slot] = transaction
            offset += 1
        }
        predictionSearchCursor =
            (start + count) % Self.predictionCapacity
        return TransientStrokeDabSlice(
            arena: self,
            regionStart: regionStart,
            regionCapacity: Self.predictionCapacity,
            start: start,
            count: count,
            generation: generation
        )
    }

    private func freeActualStart(count: Int) throws -> Int {
        guard count > 0 else { return actualSearchCursor }
        for distance in 0 ..< Self.actualCapacity {
            let candidate =
                (actualSearchCursor + distance) % Self.actualCapacity
            var isFree = true
            for offset in 0 ..< count
            where slotGeneration[
                (candidate + offset) % Self.actualCapacity
            ] != 0
            {
                isFree = false
                break
            }
            if isFree { return candidate }
        }
        throw ReservationError.capacityExceeded(Self.actualCapacity)
    }

    private func freePredictionStart(count: Int) throws -> Int {
        guard count > 0 else { return predictionSearchCursor }
        let regionStart = Self.actualCapacity
        for distance in 0 ..< Self.predictionCapacity {
            let candidate =
                (predictionSearchCursor + distance)
                    % Self.predictionCapacity
            var isFree = true
            for offset in 0 ..< count
            where slotGeneration[
                regionStart
                    + (candidate + offset) % Self.predictionCapacity
            ] != 0
            {
                isFree = false
                break
            }
            if isFree { return candidate }
        }
        throw ReservationError.capacityExceeded(
            Self.predictionCapacity
        )
    }

    private func reserveGeneration() -> UInt64 {
        let generation = nextGeneration
        nextGeneration &+= 1
        precondition(nextGeneration != 0)
        return generation
    }

    private func commit(
        _ transaction: UInt64,
        retainingActual actualChunks: [TransientStrokeChunk],
        retainingPredicted predictedChunks: [TransientStrokeChunk]
    ) throws {
        guard activeTransaction == transaction else {
            throw ReservationError.inactiveTransaction
        }
        let marker = nextRetainedMarker
        nextRetainedMarker &+= 1
        precondition(nextRetainedMarker != 0)
        var chunkIndex = actualChunks.startIndex
        while chunkIndex < actualChunks.endIndex {
            actualChunks[chunkIndex].dabs.markRetained(
                in: self,
                marker: marker
            )
            chunkIndex += 1
        }
        chunkIndex = predictedChunks.startIndex
        while chunkIndex < predictedChunks.endIndex {
            predictedChunks[chunkIndex].dabs.markRetained(
                in: self,
                marker: marker
            )
            chunkIndex += 1
        }
        var slot = storage.startIndex
        while slot < storage.endIndex {
            if slotGeneration[slot] != 0,
               retainedMarker[slot] != marker
            {
                storage[slot] = nil
                slotGeneration[slot] = 0
            }
            slotTransaction[slot] = 0
            slot += 1
        }
        activeTransaction = nil
    }

    private func rollback(
        _ transaction: UInt64,
        actualCursorBefore: Int,
        predictionCursorBefore: Int
    ) {
        guard activeTransaction == transaction else { return }
        for slot in storage.indices
        where slotTransaction[slot] == transaction
        {
            storage[slot] = nil
            slotGeneration[slot] = 0
            slotTransaction[slot] = 0
        }
        actualSearchCursor = actualCursorBefore
        predictionSearchCursor = predictionCursorBefore
        activeTransaction = nil
    }

    fileprivate func markRetained(
        regionStart: Int,
        regionCapacity: Int,
        start: Int,
        count: Int,
        generation: UInt64,
        marker: UInt64
    ) {
        var offset = 0
        while offset < count {
            let slot = regionStart
                + (start + offset) % regionCapacity
            precondition(slotGeneration[slot] == generation)
            retainedMarker[slot] = marker
            offset += 1
        }
    }

    fileprivate func dab(
        regionStart: Int,
        regionCapacity: Int,
        start: Int,
        offset: Int,
        generation: UInt64
    ) -> TransientStrokeDab {
        let slot = regionStart + (start + offset) % regionCapacity
        precondition(
            slotGeneration[slot] == generation,
            "Transient dab slice no longer owns its arena storage"
        )
        return storage[slot]!
    }
}

public struct TransientStrokeDabSlice:
    RandomAccessCollection, Equatable, Sendable
{
    public typealias Index = Int
    public typealias Element = TransientStrokeDab

    private enum Storage: Equatable, Sendable {
        case owned([TransientStrokeDab])
        case arena(
            TransientStrokeDabArena,
            regionStart: Int,
            regionCapacity: Int,
            start: Int,
            count: Int,
            generation: UInt64
        )

        static func == (lhs: Storage, rhs: Storage) -> Bool {
            switch (lhs, rhs) {
            case let (.owned(left), .owned(right)):
                left == right
            default:
                false
            }
        }
    }

    private let storage: Storage
    public let count: Int
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    public init(_ dabs: [TransientStrokeDab]) {
        storage = .owned(dabs)
        count = dabs.count
    }

    fileprivate init(
        arena: TransientStrokeDabArena,
        regionStart: Int,
        regionCapacity: Int,
        start: Int,
        count: Int,
        generation: UInt64
    ) {
        storage = .arena(
            arena,
            regionStart: regionStart,
            regionCapacity: regionCapacity,
            start: start,
            count: count,
            generation: generation
        )
        self.count = count
    }

    public subscript(position: Int) -> TransientStrokeDab {
        precondition(indices.contains(position))
        return switch storage {
        case let .owned(dabs):
            dabs[position]
        case let .arena(
            arena,
            regionStart,
            regionCapacity,
            start,
            _,
            generation
        ):
            arena.dab(
                regionStart: regionStart,
                regionCapacity: regionCapacity,
                start: start,
                offset: position,
                generation: generation
            )
        }
    }

    fileprivate func markRetained(
        in arena: TransientStrokeDabArena,
        marker: UInt64
    ) {
        guard case let .arena(
            owner,
            regionStart,
            regionCapacity,
            start,
            count,
            generation
        ) = storage else {
            return
        }
        precondition(owner === arena)
        arena.markRetained(
            regionStart: regionStart,
            regionCapacity: regionCapacity,
            start: start,
            count: count,
            generation: generation,
            marker: marker
        )
    }

    public static func == (
        lhs: TransientStrokeDabSlice,
        rhs: TransientStrokeDabSlice
    ) -> Bool {
        lhs.count == rhs.count
            && lhs.indices.allSatisfy { lhs[$0] == rhs[$0] }
    }
}

public func == (
    lhs: TransientStrokeDabSlice,
    rhs: [TransientStrokeDab]
) -> Bool {
    lhs.count == rhs.count
        && lhs.indices.allSatisfy { lhs[$0] == rhs[$0] }
}

public func == (
    lhs: [TransientStrokeDab],
    rhs: TransientStrokeDabSlice
) -> Bool {
    rhs == lhs
}

/// Replay state produced while consuming one ordered input sample.
///
/// Chunks are the indivisible promotion unit. Keeping sample, dabs, and the
/// generator state after that sample together gives replay a deterministic
/// boundary without retaining renderer or platform objects.
public struct TransientStrokeChunk: Equatable, Sendable {
    public let sample: WorldStrokeSample
    public let dabs: TransientStrokeDabSlice
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
        self.dabs = TransientStrokeDabSlice(dabs)
        self.generatorSnapshotBeforeSample = generatorSnapshotBeforeSample
        self.generatorSnapshotAfterSample = generatorSnapshotAfterSample
        self.inputDeriverSnapshotBeforeSample =
            inputDeriverSnapshotBeforeSample
    }

    public init(
        sample: WorldStrokeSample,
        dabs: TransientStrokeDabSlice,
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

/// Metadata for an estimated-input replay whose sample storage belongs to the
/// caller. `planEstimatedUpdate(_:replacementSamplesInto:)` writes the merged
/// sample and replay suffix into that storage.
public struct BorrowedEstimatedStrokeUpdatePlan: Equatable, Sendable {
    public let target: EstimatedStrokeUpdateTarget
    public let sourceReplayEpoch: UInt64
    public let replacedChunkIndex: Int
    public let mergedSample: WorldStrokeSample
    public let generatorBeforeReplacement: BrushStrokeGenerator?
    public let inputDeriverBeforeReplacement: BrushInputDeriver?
    public let replacementSampleCount: Int

    init(
        target: EstimatedStrokeUpdateTarget,
        sourceReplayEpoch: UInt64,
        replacedChunkIndex: Int,
        mergedSample: WorldStrokeSample,
        generatorBeforeReplacement: BrushStrokeGenerator?,
        inputDeriverBeforeReplacement: BrushInputDeriver?,
        replacementSampleCount: Int
    ) {
        self.target = target
        self.sourceReplayEpoch = sourceReplayEpoch
        self.replacedChunkIndex = replacedChunkIndex
        self.mergedSample = mergedSample
        self.generatorBeforeReplacement = generatorBeforeReplacement
        self.inputDeriverBeforeReplacement =
            inputDeriverBeforeReplacement
        self.replacementSampleCount = replacementSampleCount
    }
}

package struct BorrowedEstimatedStrokeUpdatePreview: Sendable {
    package let retainedSampleCount: Int
    package let retainedDabCount: Int
    package let retainedProjectedInstanceCount: Int
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

public struct TransientStrokeBufferMutation: Equatable, Sendable {
    public let requiresReplayReplacement: Bool
    public let replayWindowShortened: Bool
    public let degradedToReplayTail: Bool
    public let clearedPredictedSuffix: Bool
    public let replayEpoch: UInt64
    public let rejection: TransientStrokeBufferError?

    public init(
        requiresReplayReplacement: Bool,
        replayWindowShortened: Bool,
        degradedToReplayTail: Bool,
        clearedPredictedSuffix: Bool,
        replayEpoch: UInt64,
        rejection: TransientStrokeBufferError? = nil
    ) {
        self.requiresReplayReplacement = requiresReplayReplacement
        self.replayWindowShortened = replayWindowShortened
        self.degradedToReplayTail = degradedToReplayTail
        self.clearedPredictedSuffix = clearedPredictedSuffix
        self.replayEpoch = replayEpoch
        self.rejection = rejection
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
        actualChunks.reserveCapacity(
            replayContract.mode == .appendOnly
                ? BrushRecipePolicy.replayTailLimits.maximumSamples
                : TransientStrokeBufferContract.wholeStrokeSampleCapacity
        )
        predictedChunks.reserveCapacity(
            TransientStrokeBufferContract.wholeStrokeSampleCapacity
        )
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
        var settled: [TransientStrokeChunk] = []
        let mutation = appendActual(
            chunk,
            settledInto: &settled
        )
        return TransientStrokeBufferUpdate(
            settledPrefix: settled,
            requiresReplayReplacement:
                mutation.requiresReplayReplacement,
            replayWindowShortened: mutation.replayWindowShortened,
            degradedToReplayTail: mutation.degradedToReplayTail,
            clearedPredictedSuffix:
                mutation.clearedPredictedSuffix,
            replayEpoch: mutation.replayEpoch,
            rejection: mutation.rejection
        )
    }

    @discardableResult
    public mutating func appendActual(
        _ chunk: TransientStrokeChunk,
        settledInto settled: inout [TransientStrokeChunk]
    ) -> TransientStrokeBufferMutation {
        settled.removeAll(keepingCapacity: true)
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
            return TransientStrokeBufferMutation(
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
                promoteResolvedAppendOnlyPrefix(into: &settled)
                advanceReplayEpoch()
                return TransientStrokeBufferMutation(
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
            settled.append(chunk)
            return TransientStrokeBufferMutation(
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
        promoteUntilWithinLimits(
            sampleCapacity: capacities.maximumSamples,
            dabCapacity: capacities.maximumDabs,
            projectedInstanceCapacity: capacities.maximumProjectedInstances,
            settledInto: &settled
        )
        let shortened = projectedOverflow && !settled.isEmpty
        recordPromotion(settled, shortened: shortened)

        let requiresReplacement = clearedPrediction
            || !settled.isEmpty
            || didDegrade
        if requiresReplacement {
            advanceReplayEpoch()
        }
        return TransientStrokeBufferMutation(
            requiresReplayReplacement: requiresReplacement,
            replayWindowShortened: shortened,
            degradedToReplayTail: didDegrade,
            clearedPredictedSuffix: clearedPrediction,
            replayEpoch: replayEpoch
        )
    }

    /// Renderer hot-path append. The caller preflights the exact settled
    /// prefix and proposed replay footprint before any buffer mutation.
    @discardableResult
    public mutating func appendActual(
        _ chunk: TransientStrokeChunk,
        settledInto settled: inout [TransientStrokeChunk],
        preflightSettled: (
            [TransientStrokeChunk],
            Int
        ) throws -> Void
    ) throws -> TransientStrokeBufferMutation {
        settled.removeAll(keepingCapacity: true)
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
           unresolvedAppendOnlyOverflow(adding: chunk) != nil
        {
            return appendActual(chunk, settledInto: &settled)
        }
        let replayProjectedInstanceCount = previewActualAppend(
            chunk,
            settledInto: &settled
        )
        try preflightSettled(
            settled,
            replayProjectedInstanceCount
        )
        return appendActual(chunk, settledInto: &settled)
    }

    package mutating func previewActualAppend(
        _ chunk: TransientStrokeChunk,
        settledInto settled: inout [TransientStrokeChunk]
    ) -> Int {
        if mode == .appendOnly {
            var reachedUnresolved = false
            var replayProjectedInstanceCount = 0
            func preview(_ candidate: TransientStrokeChunk) {
                if !reachedUnresolved,
                   !candidate.sample
                    .estimatedPropertiesExpectingUpdates.isEmpty
                {
                    reachedUnresolved = true
                }
                if reachedUnresolved {
                    replayProjectedInstanceCount = Self.saturatingAdd(
                        replayProjectedInstanceCount,
                        candidate.projectedInstanceCount
                    )
                } else {
                    settled.append(candidate)
                }
            }
            for candidate in actualChunks {
                preview(candidate)
            }
            preview(chunk)
            return replayProjectedInstanceCount
        }

        var retainedSamples = Self.saturatingAdd(
            actualSampleCount,
            1
        )
        var retainedDabs = Self.saturatingAdd(
            actualDabCountStorage,
            chunk.dabs.count
        )
        var retainedProjected = Self.saturatingAdd(
            actualProjectedInstanceCountStorage,
            chunk.projectedInstanceCount
        )
        let wholeLimits = replayContract.limits
            ?? BrushRecipePolicy.wholeStrokeLimits
        let degradesToReplayTail = mode == .boundedWholeStroke
            && (
                retainedSamples > wholeLimits.maximumSamples
                    || retainedDabs > wholeLimits.maximumDabs
                    || retainedProjected
                        > wholeLimits.maximumProjectedInstances
            )
        let limits = degradesToReplayTail
            ? Self.minimumLimits(
                replayContract.limits
                    ?? BrushRecipePolicy.replayTailLimits,
                BrushRecipePolicy.replayTailLimits
            )
            : capacitiesForCurrentMode()
        var promotionBlocked = false
        func preview(_ candidate: TransientStrokeChunk) {
            guard !promotionBlocked,
                  retainedSamples > limits.maximumSamples
                    || retainedDabs > limits.maximumDabs
                    || retainedProjected
                        > limits.maximumProjectedInstances
            else {
                return
            }
            guard candidate.sample
                .estimatedPropertiesExpectingUpdates.isEmpty
            else {
                promotionBlocked = true
                return
            }
            settled.append(candidate)
            retainedSamples -= 1
            retainedDabs -= candidate.dabs.count
            retainedProjected -= candidate.projectedInstanceCount
        }
        for candidate in actualChunks {
            preview(candidate)
        }
        preview(chunk)
        return retainedProjected
    }

    /// Measures the exact authoritative suffix that a previously previewed
    /// append would retain for replacement. The supplied settled count must
    /// come from `previewActualAppend(_:settledInto:)` for the same chunk.
    package func terminationCorrection(
        appending chunk: TransientStrokeChunk,
        settledPrefixCount: Int
    ) -> BrushTerminationCorrection {
        precondition(
            settledPrefixCount >= 0
                && settledPrefixCount <= actualChunks.count + 1,
            "Termination correction must use a matching append preview"
        )
        let settledActualCount = min(
            settledPrefixCount,
            actualChunks.count
        )
        let retainsAppendedChunk = settledPrefixCount <= actualChunks.count
        let sampleCount = actualChunks.count - settledActualCount
            + (retainsAppendedChunk ? 1 : 0)
        var dabCount = 0
        var firstDistance: Float?
        var lastDistance: Float?
        var firstOrdinal: UInt64?
        var lastOrdinal: UInt64?

        func measure(_ candidate: TransientStrokeChunk) {
            for dab in candidate.dabs {
                let attributes = dab.attributes
                if firstDistance == nil {
                    firstDistance = attributes.sourceDistance
                    firstOrdinal = attributes.ordinal
                }
                lastDistance = attributes.sourceDistance
                lastOrdinal = attributes.ordinal
                let (next, overflow) = dabCount.addingReportingOverflow(1)
                dabCount = overflow ? Int.max : next
            }
        }
        for candidate in actualChunks.dropFirst(settledActualCount) {
            measure(candidate)
        }
        if retainsAppendedChunk {
            measure(chunk)
        }

        let ordinalRange: Range<UInt64>
        if let firstOrdinal, let lastOrdinal {
            let (upperBound, overflow) =
                lastOrdinal.addingReportingOverflow(1)
            ordinalRange = overflow
                ? lastOrdinal..<lastOrdinal
                : firstOrdinal..<upperBound
        } else {
            ordinalRange = 0..<0
        }
        return BrushTerminationCorrection(
            sampleCount: sampleCount,
            worldLength: (lastDistance ?? 0) - (firstDistance ?? 0),
            dabCount: dabCount,
            ordinalRange: ordinalRange
        )
    }

    /// Atomically replaces the predicted suffix. Actual chunks and their
    /// generator snapshot are never changed by prediction.
    @discardableResult
    public mutating func replacePredicted<Chunks: Collection>(
        with chunks: Chunks
    ) throws -> TransientStrokeBufferUpdate
    where Chunks.Element == TransientStrokeChunk {
        var settled: [TransientStrokeChunk] = []
        let materialized = Array(chunks)
        let mutation = try replacePredicted(
            with: materialized,
            settledInto: &settled
        )
        return TransientStrokeBufferUpdate(
            settledPrefix: settled,
            requiresReplayReplacement:
                mutation.requiresReplayReplacement,
            replayWindowShortened: mutation.replayWindowShortened,
            degradedToReplayTail: mutation.degradedToReplayTail,
            clearedPredictedSuffix: mutation.clearedPredictedSuffix,
            replayEpoch: mutation.replayEpoch,
            rejection: mutation.rejection
        )
    }

    /// Renderer hot-path variant. The caller owns and pre-reserves the
    /// settlement storage, so replacement does not create a result array.
    @discardableResult
    public mutating func replacePredicted(
        with chunks: [TransientStrokeChunk],
        settledInto settled: inout [TransientStrokeChunk]
    ) throws -> TransientStrokeBufferMutation {
        settled.removeAll(keepingCapacity: true)
        var chunkIndex = chunks.startIndex
        while chunkIndex < chunks.endIndex {
            guard chunks[chunkIndex].sample.kind == .predicted else {
                throw TransientStrokeBufferError.nonPredictedSample
            }
            chunkIndex += 1
        }
        var isUnchanged = chunks.count == predictedChunks.count
        chunkIndex = chunks.startIndex
        while isUnchanged, chunkIndex < chunks.endIndex {
            isUnchanged =
                chunks[chunkIndex] == predictedChunks[chunkIndex]
            chunkIndex += 1
        }
        if isUnchanged {
            return noChangeMutation()
        }
        _ = try previewPredictedReplacement(
            with: chunks,
            settledInto: &settled
        )
        settled.removeAll(keepingCapacity: true)

        var predictedProjectedCount = 0
        var lastGeneratorSnapshot: BrushStrokeGenerator?
        var predictedDabCount = 0
        chunkIndex = chunks.startIndex
        while chunkIndex < chunks.endIndex {
            let chunk = chunks[chunkIndex]
            predictedDabCount = Self.saturatingAdd(
                predictedDabCount,
                chunk.dabs.count
            )
            predictedProjectedCount = Self.saturatingAdd(
                predictedProjectedCount,
                chunk.projectedInstanceCount
            )
            lastGeneratorSnapshot =
                chunk.generatorSnapshotAfterSample
            chunkIndex += 1
        }
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

        let clearedPrediction = !predictedChunks.isEmpty
        predictedChunks.removeAll(keepingCapacity: true)
        chunkIndex = chunks.startIndex
        while chunkIndex < chunks.endIndex {
            predictedChunks.append(chunks[chunkIndex])
            chunkIndex += 1
        }
        predictedDabCountStorage = predictedDabCount
        predictedProjectedInstanceCountStorage =
            predictedProjectedCount
        predictedGeneratorSnapshot = lastGeneratorSnapshot
        var didDegrade = false
        if mode == .boundedWholeStroke,
           let reason = combinedWholeStrokeOverflowReason()
        {
            mode = .replayTail
            degradationReason = reason
            degradationCount += 1
            didDegrade = true
        }
        let updatedCapacities = capacitiesForCurrentMode()
        promoteUntilWithinLimits(
            sampleCapacity: updatedCapacities.maximumSamples,
            dabCapacity: updatedCapacities.maximumDabs,
            projectedInstanceCapacity:
                updatedCapacities.maximumProjectedInstances,
            settledInto: &settled
        )
        guard
            retainedSampleCount <= updatedCapacities.maximumSamples,
            retainedDabCount <= updatedCapacities.maximumDabs,
            visibleProjectedInstanceCount
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
        recordPromotion(settled, shortened: shortened)
        advanceReplayEpoch()
        advanceMutationVersion()
        return TransientStrokeBufferMutation(
            requiresReplayReplacement: true,
            replayWindowShortened: shortened,
            degradedToReplayTail: didDegrade,
            clearedPredictedSuffix: clearedPrediction,
            replayEpoch: replayEpoch
        )
    }

    public mutating func replacePredicted<Chunks: Collection>(
        with chunks: Chunks,
        settledInto settled: inout [TransientStrokeChunk],
        preflightSettled:
            (([TransientStrokeChunk], Int) throws -> Void)? = nil
    ) throws -> TransientStrokeBufferMutation
    where Chunks.Element == TransientStrokeChunk {
        let materialized = Array(chunks)
        settled.removeAll(keepingCapacity: true)
        let replayProjectedInstanceCount =
            try previewPredictedReplacement(
                with: materialized,
                settledInto: &settled
            )
        try preflightSettled?(
            settled,
            replayProjectedInstanceCount
        )
        return try replacePredicted(
            with: materialized,
            settledInto: &settled
        )
    }

    package mutating func previewPredictedReplacement(
        with chunks: [TransientStrokeChunk],
        settledInto settled: inout [TransientStrokeChunk]
    ) throws -> Int {
        var predictedDabCount = 0
        var predictedProjectedCount = 0
        var chunkIndex = chunks.startIndex
        while chunkIndex < chunks.endIndex {
            let chunk = chunks[chunkIndex]
            predictedDabCount = Self.saturatingAdd(
                predictedDabCount,
                chunk.dabs.count
            )
            predictedProjectedCount = Self.saturatingAdd(
                predictedProjectedCount,
                chunk.projectedInstanceCount
            )
            chunkIndex += 1
        }
        let currentLimits = capacitiesForCurrentMode()
        guard
            chunks.count <= currentLimits.maximumSamples,
            predictedDabCount <= currentLimits.maximumDabs,
            predictedProjectedCount
                <= currentLimits.maximumProjectedInstances
        else {
            throw TransientStrokeBufferError
                .predictedSuffixExceedsCapacity(
                    sampleCount: chunks.count,
                    dabCount: predictedDabCount,
                    projectedInstanceCount: predictedProjectedCount
                )
        }
        let combinedSamples = Self.saturatingAdd(
            actualSampleCount,
            chunks.count
        )
        let combinedDabs = Self.saturatingAdd(
            actualDabCount,
            predictedDabCount
        )
        let combinedProjected = Self.saturatingAdd(
            actualProjectedInstanceCountStorage,
            predictedProjectedCount
        )
        let wholeLimits = replayContract.limits
            ?? BrushRecipePolicy.wholeStrokeLimits
        let degradesToReplayTail = mode == .boundedWholeStroke
            && (
                combinedSamples > wholeLimits.maximumSamples
                    || combinedDabs > wholeLimits.maximumDabs
                    || combinedProjected
                        > wholeLimits.maximumProjectedInstances
            )
        let limits = degradesToReplayTail
            ? Self.minimumLimits(
                replayContract.limits
                    ?? BrushRecipePolicy.replayTailLimits,
                BrushRecipePolicy.replayTailLimits
            )
            : currentLimits
        var retainedSamples = combinedSamples
        var retainedDabs = combinedDabs
        var retainedProjected = combinedProjected
        chunkIndex = actualChunks.startIndex
        while chunkIndex < actualChunks.endIndex {
            let chunk = actualChunks[chunkIndex]
            guard retainedSamples > limits.maximumSamples
                    || retainedDabs > limits.maximumDabs
                    || retainedProjected
                        > limits.maximumProjectedInstances
            else {
                break
            }
            guard chunk.sample.estimatedPropertiesExpectingUpdates.isEmpty
            else {
                break
            }
            settled.append(chunk)
            retainedSamples -= 1
            retainedDabs -= chunk.dabs.count
            retainedProjected -= chunk.projectedInstanceCount
            chunkIndex += 1
        }
        guard
            retainedSamples <= limits.maximumSamples,
            retainedDabs <= limits.maximumDabs,
            retainedProjected <= limits.maximumProjectedInstances
        else {
            throw TransientStrokeBufferError
                .predictedSuffixExceedsCapacity(
                    sampleCount: chunks.count,
                    dabCount: predictedDabCount,
                    projectedInstanceCount: predictedProjectedCount
                )
        }
        return retainedProjected
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

    /// Renderer hot-path planner. The caller supplies reusable storage for the
    /// merged sample followed by every sample that must be replayed.
    public func planEstimatedUpdate(
        _ update: WorldStrokeSample,
        replacementSamplesInto replacementSamples:
            inout [WorldStrokeSample]
    ) throws -> BorrowedEstimatedStrokeUpdatePlan {
        replacementSamples.removeAll(keepingCapacity: true)
        guard update.kind == .estimatedUpdate,
              let updateIndex = update.estimationUpdateIndex
        else {
            throw TransientStrokeBufferError.nonEstimatedUpdate
        }

        var matchedTarget: EstimatedStrokeUpdateTarget?
        var matchedIndex = 0
        var matchCount = 0
        for index in actualChunks.indices
        where actualChunks[index].sample.estimationUpdateIndex
            == updateIndex
        {
            matchedTarget = .authoritative
            matchedIndex = index
            matchCount += 1
        }
        for index in predictedChunks.indices
        where predictedChunks[index].sample.estimationUpdateIndex
            == updateIndex
        {
            matchedTarget = .predicted
            matchedIndex = index
            matchCount += 1
        }
        guard matchCount > 0 else {
            throw TransientStrokeBufferError
                .unknownEstimatedUpdateIndex(updateIndex)
        }
        guard matchCount == 1, let target = matchedTarget else {
            throw TransientStrokeBufferError
                .duplicateEstimatedUpdateIndex(updateIndex)
        }

        let originalChunk = target == .authoritative
            ? actualChunks[matchedIndex]
            : predictedChunks[matchedIndex]
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
        let deriverCheckpoint =
            originalChunk.inputDeriverSnapshotBeforeSample
        if var deriver = deriverCheckpoint {
            merged = deriver.rederive(merged)
            replacementSamples.append(merged)
            let sourceCount = target == .authoritative
                ? actualChunks.count
                : predictedChunks.count
            for index in (matchedIndex + 1) ..< sourceCount {
                let sample = target == .authoritative
                    ? actualChunks[index].sample
                    : predictedChunks[index].sample
                replacementSamples.append(deriver.rederive(sample))
            }
        } else {
            replacementSamples.append(merged)
            let sourceCount = target == .authoritative
                ? actualChunks.count
                : predictedChunks.count
            for index in (matchedIndex + 1) ..< sourceCount {
                replacementSamples.append(
                    target == .authoritative
                        ? actualChunks[index].sample
                        : predictedChunks[index].sample
                )
            }
        }
        let generatorBefore =
            originalChunk.generatorSnapshotBeforeSample
                ?? (matchedIndex == 0
                    ? (target == .authoritative
                        ? replayStartGeneratorSnapshot
                        : authoritativeGeneratorSnapshot)
                    : (target == .authoritative
                        ? actualChunks[matchedIndex - 1]
                            .generatorSnapshotAfterSample
                        : predictedChunks[matchedIndex - 1]
                            .generatorSnapshotAfterSample))
        return BorrowedEstimatedStrokeUpdatePlan(
            target: target,
            sourceReplayEpoch: mutationVersion,
            replacedChunkIndex: matchedIndex,
            mergedSample: merged,
            generatorBeforeReplacement: generatorBefore,
            inputDeriverBeforeReplacement: deriverCheckpoint,
            replacementSampleCount: replacementSamples.count
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

    /// Renderer hot-path estimated replacement. Both expected samples and
    /// settled chunks use caller-owned, pre-reserved storage.
    package func previewEstimatedSuffix(
        using plan: BorrowedEstimatedStrokeUpdatePlan,
        expectedSamples: [WorldStrokeSample],
        with rebuiltChunks: [TransientStrokeChunk],
        settledInto settled: inout [TransientStrokeChunk]
    ) throws -> BorrowedEstimatedStrokeUpdatePreview {
        settled.removeAll(keepingCapacity: true)
        guard plan.sourceReplayEpoch == mutationVersion else {
            throw TransientStrokeBufferError.staleEstimatedUpdatePlan
        }
        guard
            expectedSamples.count == plan.replacementSampleCount,
            rebuiltChunks.count == expectedSamples.count,
            expectedSamples.first == plan.mergedSample
        else {
            throw TransientStrokeBufferError.invalidEstimatedReplacement
        }
        var replacementIndex = expectedSamples.startIndex
        while replacementIndex < expectedSamples.endIndex {
            guard rebuiltChunks[replacementIndex].sample
                    == expectedSamples[replacementIndex]
            else {
                throw TransientStrokeBufferError.invalidEstimatedReplacement
            }
            replacementIndex += 1
        }
        switch plan.target {
        case .authoritative:
            guard
                plan.replacedChunkIndex < actualChunks.count,
                actualChunks[plan.replacedChunkIndex]
                    .sample.estimationUpdateIndex
                    == plan.mergedSample.estimationUpdateIndex,
                rebuiltChunks.allSatisfy({
                    $0.sample.kind != .predicted
                })
            else {
                throw TransientStrokeBufferError.invalidEstimatedReplacement
            }
        case .predicted:
            guard
                plan.replacedChunkIndex < predictedChunks.count,
                predictedChunks[plan.replacedChunkIndex]
                    .sample.estimationUpdateIndex
                    == plan.mergedSample.estimationUpdateIndex,
                rebuiltChunks.allSatisfy({
                    $0.sample.kind == .predicted
                })
            else {
                throw TransientStrokeBufferError.invalidEstimatedReplacement
            }
        }

        var retainedSamplesAfterReplacement = 0
        var retainedDabsAfterReplacement = 0
        var retainedProjectedAfterReplacement = 0
        var retainsActualChunk = mode != .appendOnly
        switch plan.target {
        case .authoritative:
            for chunk in actualChunks[..<plan.replacedChunkIndex] {
                Self.accumulateRetainedActual(
                    chunk,
                    retainsActualChunk: &retainsActualChunk,
                    sampleCount: &retainedSamplesAfterReplacement,
                    dabCount: &retainedDabsAfterReplacement,
                    projectedCount: &retainedProjectedAfterReplacement
                )
            }
            for chunk in rebuiltChunks {
                Self.accumulateRetainedActual(
                    chunk,
                    retainsActualChunk: &retainsActualChunk,
                    sampleCount: &retainedSamplesAfterReplacement,
                    dabCount: &retainedDabsAfterReplacement,
                    projectedCount: &retainedProjectedAfterReplacement
                )
            }
        case .predicted:
            for chunk in actualChunks {
                Self.accumulateRetainedActual(
                    chunk,
                    retainsActualChunk: &retainsActualChunk,
                    sampleCount: &retainedSamplesAfterReplacement,
                    dabCount: &retainedDabsAfterReplacement,
                    projectedCount: &retainedProjectedAfterReplacement
                )
            }
            for chunk in predictedChunks[..<plan.replacedChunkIndex] {
                Self.accumulateRetained(
                    chunk,
                    sampleCount: &retainedSamplesAfterReplacement,
                    dabCount: &retainedDabsAfterReplacement,
                    projectedCount: &retainedProjectedAfterReplacement
                )
            }
            for chunk in rebuiltChunks {
                Self.accumulateRetained(
                    chunk,
                    sampleCount: &retainedSamplesAfterReplacement,
                    dabCount: &retainedDabsAfterReplacement,
                    projectedCount: &retainedProjectedAfterReplacement
                )
            }
        }
        let limits = capacitiesForCurrentMode()
        guard
            retainedSamplesAfterReplacement <= limits.maximumSamples,
            retainedDabsAfterReplacement <= limits.maximumDabs,
            retainedProjectedAfterReplacement
                <= limits.maximumProjectedInstances
        else {
            throw TransientStrokeBufferError
                .predictedSuffixExceedsCapacity(
                    sampleCount: retainedSamplesAfterReplacement,
                    dabCount: retainedDabsAfterReplacement,
                    projectedInstanceCount:
                        retainedProjectedAfterReplacement
                )
        }

        if mode == .appendOnly {
            var reachedUnresolved = false
            switch plan.target {
            case .authoritative:
                for chunk in actualChunks[..<plan.replacedChunkIndex] {
                    Self.collectResolvedAppendOnly(
                        chunk,
                        reachedUnresolved: &reachedUnresolved,
                        into: &settled
                    )
                }
                for chunk in rebuiltChunks {
                    Self.collectResolvedAppendOnly(
                        chunk,
                        reachedUnresolved: &reachedUnresolved,
                        into: &settled
                    )
                }
            case .predicted:
                for chunk in actualChunks {
                    Self.collectResolvedAppendOnly(
                        chunk,
                        reachedUnresolved: &reachedUnresolved,
                        into: &settled
                    )
                }
            }
        }
        return BorrowedEstimatedStrokeUpdatePreview(
            retainedSampleCount: retainedSamplesAfterReplacement,
            retainedDabCount: retainedDabsAfterReplacement,
            retainedProjectedInstanceCount:
                retainedProjectedAfterReplacement
        )
    }

    /// Produces the exact post-replacement retained chunk sets in caller-owned
    /// storage. The actor can project and preflight these immutable values
    /// before committing the already-validated mutation in place.
    package func previewEstimatedSuffix(
        using plan: BorrowedEstimatedStrokeUpdatePlan,
        expectedSamples: [WorldStrokeSample],
        with rebuiltChunks: [TransientStrokeChunk],
        settledInto settled: inout [TransientStrokeChunk],
        retainedActualInto retainedActual: inout [TransientStrokeChunk],
        retainedPredictedInto retainedPredicted:
            inout [TransientStrokeChunk]
    ) throws -> BorrowedEstimatedStrokeUpdatePreview {
        let preview = try previewEstimatedSuffix(
            using: plan,
            expectedSamples: expectedSamples,
            with: rebuiltChunks,
            settledInto: &settled
        )
        retainedActual.removeAll(keepingCapacity: true)
        retainedPredicted.removeAll(keepingCapacity: true)
        switch plan.target {
        case .authoritative:
            retainedActual.append(
                contentsOf: actualChunks[..<plan.replacedChunkIndex]
            )
            retainedActual.append(contentsOf: rebuiltChunks)
        case .predicted:
            retainedActual.append(contentsOf: actualChunks)
            retainedPredicted.append(
                contentsOf: predictedChunks[..<plan.replacedChunkIndex]
            )
            retainedPredicted.append(contentsOf: rebuiltChunks)
        }
        return preview
    }

    @discardableResult
    public mutating func replaceEstimatedSuffix(
        using plan: BorrowedEstimatedStrokeUpdatePlan,
        expectedSamples: [WorldStrokeSample],
        with rebuiltChunks: [TransientStrokeChunk],
        settledInto settled: inout [TransientStrokeChunk]
    ) throws -> TransientStrokeBufferMutation {
        let preview = try previewEstimatedSuffix(
            using: plan,
            expectedSamples: expectedSamples,
            with: rebuiltChunks,
            settledInto: &settled
        )
        return replaceEstimatedSuffixPrevalidated(
            using: plan,
            with: rebuiltChunks,
            preview: preview,
            settledInto: &settled
        )
    }

    /// Nonthrowing commit paired with a successful immutable preview of the
    /// same mutation version and rebuilt chunks.
    package mutating func replaceEstimatedSuffixPrevalidated(
        using plan: BorrowedEstimatedStrokeUpdatePlan,
        with rebuiltChunks: [TransientStrokeChunk],
        preview: BorrowedEstimatedStrokeUpdatePreview,
        settledInto settled: inout [TransientStrokeChunk]
    ) -> TransientStrokeBufferMutation {
        precondition(plan.sourceReplayEpoch == mutationVersion)
        settled.removeAll(keepingCapacity: true)

        let clearedPrediction: Bool
        switch plan.target {
        case .authoritative:
            precondition(plan.replacedChunkIndex < actualChunks.count)
            actualChunks.removeSubrange(plan.replacedChunkIndex...)
            actualChunks.append(contentsOf: rebuiltChunks)
            clearedPrediction = !predictedChunks.isEmpty
            if clearedPrediction {
                predictedChunks.removeAll(keepingCapacity: true)
            }
            predictedGeneratorSnapshot = nil
        case .predicted:
            precondition(plan.replacedChunkIndex < predictedChunks.count)
            predictedChunks.removeSubrange(plan.replacedChunkIndex...)
            predictedChunks.append(contentsOf: rebuiltChunks)
            clearedPrediction = false
        }

        let rebuiltAuthoritativeGeneratorSnapshot =
            actualChunks.last?.generatorSnapshotAfterSample
                ?? authoritativeGeneratorSnapshot
        let rebuiltPredictedGeneratorSnapshot =
            predictedChunks.last?.generatorSnapshotAfterSample
        recalculateAllCounters()
        if mode == .appendOnly {
            promoteResolvedAppendOnlyPrefix(into: &settled)
        }
        precondition(
            retainedSampleCount == preview.retainedSampleCount
                && retainedDabCount == preview.retainedDabCount
                && visibleProjectedInstanceCount
                    == preview.retainedProjectedInstanceCount,
            "Estimated replacement preflight diverged from mutation."
        )

        authoritativeGeneratorSnapshot =
            rebuiltAuthoritativeGeneratorSnapshot
        predictedGeneratorSnapshot =
            rebuiltPredictedGeneratorSnapshot
        advanceReplayEpoch()
        advanceMutationVersion()
        return TransientStrokeBufferMutation(
            requiresReplayReplacement: true,
            replayWindowShortened: false,
            degradedToReplayTail: false,
            clearedPredictedSuffix: clearedPrediction,
            replayEpoch: replayEpoch
        )
    }

    private static func accumulateRetainedActual(
        _ chunk: TransientStrokeChunk,
        retainsActualChunk: inout Bool,
        sampleCount: inout Int,
        dabCount: inout Int,
        projectedCount: inout Int
    ) {
        if !retainsActualChunk,
           !chunk.sample.estimatedPropertiesExpectingUpdates.isEmpty
        {
            retainsActualChunk = true
        }
        guard retainsActualChunk else { return }
        accumulateRetained(
            chunk,
            sampleCount: &sampleCount,
            dabCount: &dabCount,
            projectedCount: &projectedCount
        )
    }

    private static func accumulateRetained(
        _ chunk: TransientStrokeChunk,
        sampleCount: inout Int,
        dabCount: inout Int,
        projectedCount: inout Int
    ) {
        sampleCount = saturatingAdd(sampleCount, 1)
        dabCount = saturatingAdd(dabCount, chunk.dabs.count)
        projectedCount = saturatingAdd(
            projectedCount,
            chunk.projectedInstanceCount
        )
    }

    private static func collectResolvedAppendOnly(
        _ chunk: TransientStrokeChunk,
        reachedUnresolved: inout Bool,
        into settled: inout [TransientStrokeChunk]
    ) {
        guard !reachedUnresolved else { return }
        if chunk.sample.estimatedPropertiesExpectingUpdates.isEmpty {
            settled.append(chunk)
        } else {
            reachedUnresolved = true
        }
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
        var settled: [TransientStrokeChunk] = []
        promoteUntilWithinLimits(
            sampleCapacity: sampleCapacity,
            dabCapacity: dabCapacity,
            projectedInstanceCapacity: projectedInstanceCapacity,
            settledInto: &settled
        )
        return settled
    }

    private mutating func promoteUntilWithinLimits(
        sampleCapacity: Int,
        dabCapacity: Int,
        projectedInstanceCapacity: Int,
        settledInto settled: inout [TransientStrokeChunk]
    ) {
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
        guard prefixCount > 0 else { return }

        settled.append(contentsOf: actualChunks.prefix(prefixCount))
        actualChunks.removeFirst(prefixCount)
        for chunk in settled {
            actualDabCountStorage -= chunk.dabs.count
            actualProjectedInstanceCountStorage -=
                chunk.projectedInstanceCount
            if let snapshot = chunk.generatorSnapshotAfterSample {
                replayStartGeneratorSnapshot = snapshot
            }
        }
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
        var settled: [TransientStrokeChunk] = []
        promoteResolvedAppendOnlyPrefix(into: &settled)
        return settled
    }

    private mutating func promoteResolvedAppendOnlyPrefix(
        into settled: inout [TransientStrokeChunk]
    ) {
        let firstUnresolved = actualChunks.firstIndex {
            !$0.sample.estimatedPropertiesExpectingUpdates.isEmpty
        } ?? actualChunks.endIndex
        guard firstUnresolved > actualChunks.startIndex else { return }
        settled.append(contentsOf: actualChunks[..<firstUnresolved])
        actualChunks.removeFirst(firstUnresolved)
        for chunk in settled {
            if let snapshot = chunk.generatorSnapshotAfterSample {
                replayStartGeneratorSnapshot = snapshot
            }
        }
        recalculateActualCounters()
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

    private func noChangeMutation() -> TransientStrokeBufferMutation {
        TransientStrokeBufferMutation(
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
