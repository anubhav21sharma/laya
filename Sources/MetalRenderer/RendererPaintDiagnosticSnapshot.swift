import Foundation

/// Package-only ownership evidence consumed by tests and diagnostics without
/// exposing the renderer's internal transaction/cache snapshot graph.
package struct RendererPaintDiagnosticSnapshot: Equatable, Sendable {
    package let storeIdentity: PaintTileStoreIdentity
    package let activeLayerID: UUID
    package let documentGeneration: UInt64
    package let layerIDs: [UUID]
    package let activeSnapshotTokenCount: Int
    package let aggregateSnapshotReferenceCount: Int
    package let activeTileLeaseCount: Int
    package let snapshotMetadataByteCount: Int
    package let snapshotPayloadLiabilityByteCount: Int
    package let revisionResidentBytes: Int
    package let activeStrokeSurfaceCount: Int
    package let activeCommandOperationCount: Int
}
