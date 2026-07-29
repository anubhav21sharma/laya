import PatternEngine

public struct InputPathStorageDiagnosticSnapshot:
    Equatable, Sendable
{
    public let isArmed: Bool
    public let allocationEventCountAfterWarmup: UInt64
    public let auditedEventCount: UInt64
    public let generatedDabCapacityHighWater: Int
    public let tilingImageCapacityHighWater: Int
    public let tilingCandidateCapacityHighWater: Int
    public let clippedPolygonCapacityHighWater: Int
    public let projectionFragmentCapacityHighWater: Int
    public let schedulerRecordCapacityHighWater: Int
    public let replayRecordCapacityHighWater: Int
}

struct InputPathStorageAudit {
    private(set) var isArmed = false
    private(set) var allocationEventCountAfterWarmup: UInt64 = 0
    private(set) var auditedEventCount: UInt64 = 0
    private(set) var generatedDabCapacityHighWater = 0
    private(set) var tilingImageCapacityHighWater = 0
    private(set) var tilingCandidateCapacityHighWater = 0
    private(set) var clippedPolygonCapacityHighWater = 0
    private(set) var projectionFragmentCapacityHighWater = 0
    private(set) var schedulerRecordCapacityHighWater = 0
    private(set) var replayRecordCapacityHighWater = 0

    var snapshot: InputPathStorageDiagnosticSnapshot {
        InputPathStorageDiagnosticSnapshot(
            isArmed: isArmed,
            allocationEventCountAfterWarmup:
                allocationEventCountAfterWarmup,
            auditedEventCount: auditedEventCount,
            generatedDabCapacityHighWater:
                generatedDabCapacityHighWater,
            tilingImageCapacityHighWater:
                tilingImageCapacityHighWater,
            tilingCandidateCapacityHighWater:
                tilingCandidateCapacityHighWater,
            clippedPolygonCapacityHighWater:
                clippedPolygonCapacityHighWater,
            projectionFragmentCapacityHighWater:
                projectionFragmentCapacityHighWater,
            schedulerRecordCapacityHighWater:
                schedulerRecordCapacityHighWater,
            replayRecordCapacityHighWater:
                replayRecordCapacityHighWater
        )
    }

    mutating func reset() {
        self = InputPathStorageAudit()
    }

    mutating func armAfterWarmup() {
        isArmed = true
        allocationEventCountAfterWarmup = 0
        auditedEventCount = 0
    }

    mutating func recordCollectionStorageAllocation(capacity: Int) {
        precondition(capacity >= 0)
        guard isArmed else { return }
        allocationEventCountAfterWarmup = Self.saturatingIncrement(
            allocationEventCountAfterWarmup
        )
    }

    mutating func recordGeneratedDabs(_ count: Int) {
        precondition(count >= 0)
        if isArmed {
            auditedEventCount = Self.saturatingIncrement(
                auditedEventCount
            )
        }
        generatedDabCapacityHighWater = record(
            count,
            highWater: generatedDabCapacityHighWater
        )
    }

    mutating func recordTiling(
        _ diagnostics: TilingProjectionStorageDiagnostics
    ) {
        tilingImageCapacityHighWater = record(
            diagnostics.imageCapacity,
            highWater: tilingImageCapacityHighWater
        )
        tilingCandidateCapacityHighWater = record(
            diagnostics.candidateCapacity,
            highWater: tilingCandidateCapacityHighWater
        )
        clippedPolygonCapacityHighWater = record(
            diagnostics.maximumClippedPolygonCapacity,
            highWater: clippedPolygonCapacityHighWater
        )
        projectionFragmentCapacityHighWater = record(
            diagnostics.fragmentCapacity,
            highWater: projectionFragmentCapacityHighWater
        )
    }

    mutating func recordRecordStorage(
        schedulerCapacity: Int,
        replayCapacity: Int
    ) {
        precondition(schedulerCapacity >= 0)
        precondition(replayCapacity >= 0)
        schedulerRecordCapacityHighWater = record(
            schedulerCapacity,
            highWater: schedulerRecordCapacityHighWater
        )
        replayRecordCapacityHighWater = record(
            replayCapacity,
            highWater: replayRecordCapacityHighWater
        )
    }

    private mutating func record(
        _ requiredCapacity: Int,
        highWater: Int
    ) -> Int {
        max(requiredCapacity, highWater)
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }
}
