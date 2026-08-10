import PatternEngine

enum PredictionTileReplacementError: Error, Equatable, Sendable {
    case capacityExceeded(required: Int, maximum: Int)
    case replacementAlreadyPlanned
}

/// Allocation-stable tile-footprint transaction used by the Task 5 backend.
/// Visible state changes only at commit; rollback leaves it byte-for-byte intact.
struct PredictionTileReplacementState: Sendable {
    let maximumTileCount: Int
    private(set) var visibleCoordinates: [PaintTileCoordinate] = []
    private(set) var plannedCoordinates: [PaintTileCoordinate] = []
    private(set) var priorCoordinatesToClear: [PaintTileCoordinate] = []
    private var hasPlannedReplacement = false

    init(maximumTileCount: Int) {
        precondition(maximumTileCount > 0)
        self.maximumTileCount = maximumTileCount
        visibleCoordinates.reserveCapacity(maximumTileCount)
        plannedCoordinates.reserveCapacity(maximumTileCount)
        priorCoordinatesToClear.reserveCapacity(maximumTileCount)
    }

    mutating func beginReplacement(
        _ sortedUniqueCoordinates: [PaintTileCoordinate]
    ) throws {
        guard !hasPlannedReplacement else {
            throw PredictionTileReplacementError.replacementAlreadyPlanned
        }
        guard sortedUniqueCoordinates.count <= maximumTileCount else {
            throw PredictionTileReplacementError.capacityExceeded(
                required: sortedUniqueCoordinates.count,
                maximum: maximumTileCount
            )
        }
        for index in sortedUniqueCoordinates.indices.dropFirst() {
            precondition(
                sortedUniqueCoordinates[index - 1]
                    < sortedUniqueCoordinates[index],
                "Prediction coordinates must be sorted and unique."
            )
        }
        plannedCoordinates.removeAll(keepingCapacity: true)
        priorCoordinatesToClear.removeAll(keepingCapacity: true)
        plannedCoordinates.append(contentsOf: sortedUniqueCoordinates)
        priorCoordinatesToClear.append(contentsOf: visibleCoordinates)
        hasPlannedReplacement = true
    }

    mutating func commitReplacement() {
        precondition(hasPlannedReplacement)
        swap(&visibleCoordinates, &plannedCoordinates)
        plannedCoordinates.removeAll(keepingCapacity: true)
        priorCoordinatesToClear.removeAll(keepingCapacity: true)
        hasPlannedReplacement = false
    }

    mutating func rollbackReplacement() {
        plannedCoordinates.removeAll(keepingCapacity: true)
        priorCoordinatesToClear.removeAll(keepingCapacity: true)
        hasPlannedReplacement = false
    }

    mutating func reset() {
        visibleCoordinates.removeAll(keepingCapacity: true)
        rollbackReplacement()
    }
}

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

public struct PredictionAdmission: Equatable, Sendable {
    public let normalizedSampleCount: Int
    public let logicalDabCount: Int
    public let projectedInstanceCount: Int
    public let overload: PredictionOverloadReasons

    public var overloaded: Bool { !overload.isEmpty }
}

public enum PredictionAdmissionLimits {
    public static let maximumNormalizedSampleCount = 64
    public static let maximumLogicalDabCount = 512
    public static let maximumRetainedDirtyRegionCount =
        TransientStrokeBufferContract.visibleEpochProjectedInstanceCapacity
}
