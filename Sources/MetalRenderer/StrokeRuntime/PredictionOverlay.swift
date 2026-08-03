import Metal
import PatternEngine

public struct PredictionProvenanceBoundary: Equatable, Sendable {
    public let coordinatorRevision: UInt64
    public let nextAuthoritativeOrdinal: UInt64

    public init(
        coordinatorRevision: UInt64,
        nextAuthoritativeOrdinal: UInt64
    ) {
        self.coordinatorRevision = coordinatorRevision
        self.nextAuthoritativeOrdinal = nextAuthoritativeOrdinal
    }
}

public struct PredictionOverloadReasons:
    OptionSet, Equatable, Sendable
{
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let normalizedSamples = Self(rawValue: 1 << 0)
    public static let logicalDabs = Self(rawValue: 1 << 1)
    public static let projectedInstances = Self(rawValue: 1 << 2)
}

public struct PredictionOverlayAdmission: Equatable, Sendable {
    public let normalizedSampleCount: Int
    public let logicalDabCount: Int
    public let projectedInstanceCount: Int
    public let overload: PredictionOverloadReasons

    public var overloaded: Bool { !overload.isEmpty }
}

public struct PredictionOverlaySnapshot: Equatable, Sendable {
    public let provenance: PredictionProvenanceBoundary?
    public let normalizedSampleCount: Int
    public let logicalDabCount: Int
    public let projectedInstanceCount: Int
    public let overloadCount: UInt64
    public let lastOverload: PredictionOverloadReasons
    public let previousDirtyRegions: PixelRegionSet
}

/// Owns the replaceable prediction surface and the regions occupied by the
/// last submitted overlay. A new replacement clears only that submitted
/// footprint; its new footprint becomes authoritative for clearing only when
/// the replacement is submitted.
@MainActor
public final class PredictionOverlay {
    nonisolated public static let maximumNormalizedSampleCount = 64
    nonisolated public static let maximumLogicalDabCount = 512
    nonisolated public static let maximumRetainedDirtyRegionCount =
        TransientStrokeBufferContract.visibleEpochProjectedInstanceCapacity

    public let pixelSize: PixelSize
    public let surface: ReplayLiveTile
    private(set) var snapshotMaterializationCountForTesting: UInt64 = 0

    public var snapshot: PredictionOverlaySnapshot {
        snapshotMaterializationCountForTesting = Self.saturatingIncrement(
            snapshotMaterializationCountForTesting
        )
        let usePlanned = hasPlannedReplacement
        let admission = usePlanned ? plannedAdmission : visibleAdmission
        return PredictionOverlaySnapshot(
            provenance: usePlanned ? plannedProvenance : visibleProvenance,
            normalizedSampleCount: admission.normalizedSampleCount,
            logicalDabCount: admission.logicalDabCount,
            projectedInstanceCount: admission.projectedInstanceCount,
            overloadCount: overloadCount,
            lastOverload: lastOverload,
            previousDirtyRegions: PixelRegionSet(
                visibleDirtyRegions,
                clippedTo: pixelSize
            )
        )
    }

    func canInvalidatePrediction(
        from boundary: PredictionProvenanceBoundary
    ) -> Bool {
        currentProvenance == nil || currentProvenance == boundary
    }

    func hasPrediction(
        from boundary: PredictionProvenanceBoundary
    ) -> Bool {
        currentProvenance == boundary
    }

    private var visibleDirtyRegions: [PixelRect] = []
    private var plannedDirtyRegions: [PixelRect] = []
    private var visibleProvenance: PredictionProvenanceBoundary?
    private var plannedProvenance: PredictionProvenanceBoundary?
    private var visibleAdmission = PredictionOverlay.emptyAdmission
    private var plannedAdmission = PredictionOverlay.emptyAdmission
    private var plannedEpoch: UInt64 = 0
    private var hasPlannedReplacement = false
    private var overloadCount: UInt64 = 0
    private var lastOverload: PredictionOverloadReasons = []

    public init(
        device: any MTLDevice,
        pixelSize: PixelSize
    ) throws {
        self.pixelSize = pixelSize
        surface = try ReplayLiveTile(device: device, pixelSize: pixelSize)
        visibleDirtyRegions.reserveCapacity(
            Self.maximumRetainedDirtyRegionCount
        )
        plannedDirtyRegions.reserveCapacity(
            Self.maximumRetainedDirtyRegionCount
        )
    }

    nonisolated public static func admit(
        normalizedSampleCount: Int,
        logicalDabCount: Int,
        projectedInstanceCount: Int,
        predictedInstanceBudget: Int
    ) -> PredictionOverlayAdmission {
        precondition(normalizedSampleCount >= 0)
        precondition(logicalDabCount >= 0)
        precondition(projectedInstanceCount >= 0)
        precondition(predictedInstanceBudget > 0)
        var overload: PredictionOverloadReasons = []
        if normalizedSampleCount > maximumNormalizedSampleCount {
            overload.insert(.normalizedSamples)
        }
        if logicalDabCount > maximumLogicalDabCount {
            overload.insert(.logicalDabs)
        }
        if projectedInstanceCount > predictedInstanceBudget {
            overload.insert(.projectedInstances)
        }
        return PredictionOverlayAdmission(
            normalizedSampleCount: min(
                normalizedSampleCount,
                maximumNormalizedSampleCount
            ),
            logicalDabCount: min(
                logicalDabCount,
                maximumLogicalDabCount
            ),
            projectedInstanceCount: min(
                projectedInstanceCount,
                predictedInstanceBudget
            ),
            overload: overload
        )
    }

    @discardableResult
    public func planReplacement(
        epoch: UInt64,
        provenance: PredictionProvenanceBoundary?,
        admission: PredictionOverlayAdmission,
        dirtyRegions: [PixelRect]
    ) -> ReplayClearPlan? {
        guard planReplacementInPlace(
            epoch: epoch,
            provenance: provenance,
            admission: admission,
            dirtyRegions: dirtyRegions
        ) else { return nil }
        return surface.lastClearPlan!
    }

    /// Renderer hot-path variant. Both the submitted footprint and the next
    /// footprint are retained in preallocated storage.
    @discardableResult
    func planReplacementInPlace<DirtyRegions: Collection>(
        epoch: UInt64,
        provenance: PredictionProvenanceBoundary?,
        admission: PredictionOverlayAdmission,
        dirtyRegions: DirtyRegions
    ) -> Bool where DirtyRegions.Element == PixelRect {
        guard epoch > surface.visibleEpoch,
              !hasPlannedReplacement || epoch > plannedEpoch else {
            return false
        }
        precondition(
            admission.normalizedSampleCount
                <= Self.maximumNormalizedSampleCount
        )
        precondition(
            admission.logicalDabCount <= Self.maximumLogicalDabCount
        )
        guard surface.planReplacementInPlace(
            epoch: epoch,
            canonicalRegions: visibleDirtyRegions
        ) else { return false }
        plannedDirtyRegions.removeAll(keepingCapacity: true)
        precondition(
            dirtyRegions.count <= Self.maximumRetainedDirtyRegionCount,
            "Prediction dirty footprint exceeds the admitted replay bound."
        )
        precondition(
            plannedDirtyRegions.capacity >= dirtyRegions.count,
            "Prediction dirty storage must be reserved before input."
        )
        plannedDirtyRegions.append(contentsOf: dirtyRegions)
        PixelRegionSet.canonicalizeInPlace(
            &plannedDirtyRegions,
            clippedTo: pixelSize
        )
        plannedProvenance = provenance
        plannedAdmission = admission
        plannedEpoch = epoch
        hasPlannedReplacement = true
        lastOverload = admission.overload
        if admission.overloaded {
            overloadCount = Self.saturatingIncrement(overloadCount)
        }
        return true
    }

    @discardableResult
    public func invalidatePrediction(
        from boundary: PredictionProvenanceBoundary,
        epoch: UInt64
    ) -> Bool {
        guard currentProvenance == boundary else { return false }
        return planReplacementInPlace(
            epoch: epoch,
            provenance: nil,
            admission: Self.emptyAdmission,
            dirtyRegions: []
        )
    }

    public func discard(epoch: UInt64) {
        planReplacementInPlace(
            epoch: epoch,
            provenance: nil,
            admission: Self.emptyAdmission,
            dirtyRegions: []
        )
    }

    public func markVisible(epoch: UInt64) {
        guard surface.markVisible(epoch: epoch) else { return }
        guard hasPlannedReplacement, epoch == plannedEpoch else { return }
        installPlannedReplacement()
    }

    public func markCleared(epoch: UInt64) {
        guard surface.markCleared(epoch: epoch) else { return }
        visibleDirtyRegions.removeAll(keepingCapacity: true)
        visibleProvenance = nil
        visibleAdmission = Self.emptyAdmission
        if hasPlannedReplacement,
           epoch == plannedEpoch,
           plannedDirtyRegions.isEmpty
        {
            installPlannedReplacement()
        }
    }

    public func reset() {
        surface.reset()
        visibleDirtyRegions.removeAll(keepingCapacity: true)
        plannedDirtyRegions.removeAll(keepingCapacity: true)
        visibleProvenance = nil
        plannedProvenance = nil
        visibleAdmission = Self.emptyAdmission
        plannedAdmission = Self.emptyAdmission
        plannedEpoch = 0
        hasPlannedReplacement = false
        overloadCount = 0
        lastOverload = []
    }

    private func installPlannedReplacement() {
        visibleDirtyRegions.removeAll(keepingCapacity: true)
        precondition(
            visibleDirtyRegions.capacity >= plannedDirtyRegions.count,
            "Prediction dirty storage must remain bounded."
        )
        visibleDirtyRegions.append(contentsOf: plannedDirtyRegions)
        visibleProvenance = plannedProvenance
        visibleAdmission = plannedAdmission
        hasPlannedReplacement = false
    }

    /// Hot-path validation reads only provenance. Building the public snapshot
    /// also canonicalizes a value copy of the dirty footprint, which belongs
    /// to diagnostics and must not run for every authoritative input event.
    var currentProvenance: PredictionProvenanceBoundary? {
        hasPlannedReplacement ? plannedProvenance : visibleProvenance
    }

    private static let emptyAdmission = PredictionOverlayAdmission(
        normalizedSampleCount: 0,
        logicalDabCount: 0,
        projectedInstanceCount: 0,
        overload: []
    )

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }
}
