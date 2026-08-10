import Foundation
import PatternEngine

enum DocumentPaintStableCanonicalSnapshotError: Error, Equatable, Sendable {
    case invalidLimit
    case closed
    case activeChildSelectionLimitExceeded(maximum: Int)
    case selectedReferenceLimitExceeded(required: Int, maximum: Int)
}

struct DocumentPaintStableCanonicalSnapshotLimits: Equatable, Sendable {
    static let hardMaximumActiveChildSelections = 64
    static let hardMaximumSelectedReferenceCountPerChild = 512

    let maximumActiveChildSelections: Int
    let maximumSelectedReferenceCountPerChild: Int

    init(
        maximumActiveChildSelections: Int,
        maximumSelectedReferenceCountPerChild: Int = 512
    ) throws {
        guard maximumActiveChildSelections > 0,
              maximumActiveChildSelections
                <= Self.hardMaximumActiveChildSelections,
              maximumSelectedReferenceCountPerChild > 0,
              maximumSelectedReferenceCountPerChild
                <= Self.hardMaximumSelectedReferenceCountPerChild
        else {
            throw DocumentPaintStableCanonicalSnapshotError.invalidLimit
        }
        self.maximumActiveChildSelections = maximumActiveChildSelections
        self.maximumSelectedReferenceCountPerChild =
            maximumSelectedReferenceCountPerChild
    }

    static let documentProduction = try! Self(
        maximumActiveChildSelections: 8,
        maximumSelectedReferenceCountPerChild: 512
    )
}

/// One immutable canonical epoch retained independently of later document
/// publication. The root owns the full exact reference set once; viewport
/// children borrow narrowed authority without creating additional store tokens.
final class DocumentPaintStableCanonicalSnapshot: @unchecked Sendable {
    private final class ChildReservation: @unchecked Sendable {
        private weak var owner: DocumentPaintStableCanonicalSnapshot?
        private let lock = NSLock()
        private var isOpen = true

        init(owner: DocumentPaintStableCanonicalSnapshot) {
            self.owner = owner
        }

        func close() {
            lock.lock()
            guard isOpen else {
                lock.unlock()
                return
            }
            isOpen = false
            let owner = owner
            self.owner = nil
            lock.unlock()
            owner?.childSelectionTerminated()
        }

        deinit { close() }
    }

    let documentGeneration: UInt64
    let geometry: DocumentPaintGeometry
    let layerID: UUID
    let revision: RasterRevision
    let addressing: SparseTileAddressing
    let addressingRevision: UInt64
    let referenceCount: Int

    private let source: SparseTileSourceRequest
    private let capture: TiledRasterExactReferenceCapture
    private let limits: DocumentPaintStableCanonicalSnapshotLimits
    private let maximumReferenceCountFromStoreBudget: Int
    private let lock = NSLock()
    private var closed = false
    private var activeChildSelections = 0

    #if DEBUG
    var testingChildAdmissionCompleted: (@Sendable () -> Void)?
    #endif

    init(
        documentGeneration: UInt64,
        geometry: DocumentPaintGeometry,
        layerID: UUID,
        revision: RasterRevision,
        addressing: SparseTileAddressing,
        addressingRevision: UInt64,
        source: SparseTileSourceRequest,
        capture: TiledRasterExactReferenceCapture,
        maximumReferenceCountFromStoreBudget: Int,
        limits: DocumentPaintStableCanonicalSnapshotLimits
    ) {
        self.documentGeneration = documentGeneration
        self.geometry = geometry
        self.layerID = layerID
        self.revision = revision
        self.addressing = addressing
        self.addressingRevision = addressingRevision
        referenceCount = source.references.count
        self.source = source
        self.capture = capture
        self.maximumReferenceCountFromStoreBudget =
            maximumReferenceCountFromStoreBudget
        self.limits = limits
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    var activeChildSelectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeChildSelections
    }

    func captureVisibleSources(
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputToSourceTransform: SparseTileOutputToSourceTransform = .identity,
        planLimits: SparseTilePlanLimits = .documentProduction
    ) throws -> DocumentPaintCanonicalVisibleSourceCapture {
        try captureVisibleSources(
            outputRegion: outputRegion,
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: .affine(outputToSourceTransform),
            planLimits: planLimits
        )
    }

    func captureVisibleSources(
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping,
        planLimits: SparseTilePlanLimits = .documentProduction
    ) throws -> DocumentPaintCanonicalVisibleSourceCapture {
        let key = SparseTileSamplingPlanKey(
            documentGeneration: documentGeneration,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: layerID,
                roles: [source.contentKey]
            )],
            addressingRevision: addressingRevision,
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: outputMapping
        )
        let selection = try SparseTileOwnedSourceBatch.selecting(
            sources: [source],
            key: key,
            outputRegion: outputRegion
        )
        let selectedReferenceCount = try selection.selectedReferenceCount()
        let maximumSelectedReferences = try preflightMaximumSelectedReferences(
            planLimits
        )
        guard selectedReferenceCount <= maximumSelectedReferences
        else {
            throw DocumentPaintStableCanonicalSnapshotError
                .selectedReferenceLimitExceeded(
                    required: selectedReferenceCount,
                    maximum: maximumSelectedReferences
                )
        }

        let reservation = try admitChildSelection()
        #if DEBUG
        testingChildAdmissionCompleted?()
        #endif
        do {
            let batch = try SparseTileOwnedSourceBatch.borrowing(
                selection,
                from: capture,
                onTerminal: { reservation.close() }
            )
            return DocumentPaintCanonicalVisibleSourceCapture(
                key: key,
                outputRegion: outputRegion,
                sourceBatch: batch
            )
        } catch TiledRasterSurfaceError.exactReferenceCaptureClosed {
            reservation.close()
            throw DocumentPaintStableCanonicalSnapshotError.closed
        } catch {
            reservation.close()
            throw error
        }
    }

    /// One bounded child-plan transaction. The same limits preflight selection
    /// before borrowing and govern cache construction, so failure at any later
    /// stage terminalizes the child batch and returns its admission slot.
    func acquireVisiblePlan(
        cache: SparseTileSamplingPlanCache,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputToSourceTransform: SparseTileOutputToSourceTransform = .identity,
        limits: SparseTilePlanLimits = .documentProduction
    ) throws -> SparseTileSamplingPlanLease {
        try acquireVisiblePlan(
            cache: cache,
            outputRegion: outputRegion,
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: .affine(outputToSourceTransform),
            limits: limits
        )
    }

    func acquireVisiblePlan(
        cache: SparseTileSamplingPlanCache,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping,
        limits: SparseTilePlanLimits = .documentProduction
    ) throws -> SparseTileSamplingPlanLease {
        let child = try captureVisibleSources(
            outputRegion: outputRegion,
            outputGeometryRevision: outputGeometryRevision,
            outputMapping: outputMapping,
            planLimits: limits
        )
        return try cache.acquire(
            key: child.key,
            sourceBatch: child.sourceBatch,
            outputRegion: child.outputRegion,
            limits: limits
        )
    }

    private func preflightMaximumSelectedReferences(
        _ planLimits: SparseTilePlanLimits
    ) throws -> Int {
        guard planLimits.allValues.allSatisfy({ $0 > 0 }) else {
            throw SparseTileSamplingPlanError.invalidLimit
        }
        let (chunkCapacity, chunkOverflow) = planLimits.maximumBindingChunks
            .multipliedReportingOverflow(by: 64)
        let (batchCapacity, batchOverflow) = planLimits.maximumTexturesPerBatch
            .multipliedReportingOverflow(by: planLimits.maximumBatchCount)
        return min(
            limits.maximumSelectedReferenceCountPerChild,
            maximumReferenceCountFromStoreBudget,
            512,
            planLimits.maximumBindingSlots,
            planLimits.maximumBindingBytes / 64,
            chunkOverflow ? Int.max : chunkCapacity,
            batchOverflow ? Int.max : batchCapacity
        )
    }

    #if DEBUG
    func testingMaximumSelectedReferences(
        planLimits: SparseTilePlanLimits
    ) throws -> Int {
        try preflightMaximumSelectedReferences(planLimits)
    }
    #endif

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        capture.close()
    }

    private func admitChildSelection() throws -> ChildReservation {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else {
            throw DocumentPaintStableCanonicalSnapshotError.closed
        }
        guard activeChildSelections < limits.maximumActiveChildSelections else {
            throw DocumentPaintStableCanonicalSnapshotError
                .activeChildSelectionLimitExceeded(
                    maximum: limits.maximumActiveChildSelections
                )
        }
        activeChildSelections += 1
        return ChildReservation(owner: self)
    }

    private func childSelectionTerminated() {
        lock.lock()
        precondition(activeChildSelections > 0)
        activeChildSelections -= 1
        lock.unlock()
    }

    deinit { close() }
}
