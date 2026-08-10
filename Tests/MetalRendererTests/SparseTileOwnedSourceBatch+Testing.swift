import Foundation
@testable import MetalRenderer

extension SparseTileRoleContentKey {
    init(
        role: SparseTileSampleRole,
        contentRevision: UInt64,
        bindingChunkRevision: UInt64
    ) {
        self.init(
            role: role,
            surfaceIdentity: UUID(
                uuidString: "00000000-0000-0000-0000-000000000000"
            )!,
            contentRevision: contentRevision,
            bindingChunkRevision: bindingChunkRevision
        )
    }
}

/// Existing behavioral tests describe plan construction rather than source
/// ownership. Keep their concise call sites while ensuring every invocation,
/// including cache hits, crosses the production one-shot batch boundary.
extension SparseTileSamplingPlanCache {
    func acquire(
        key: SparseTileSamplingPlanKey,
        sources: [SparseTileSourceRequest],
        outputRegion: SparseTileOutputRegion,
        limits: SparseTilePlanLimits,
        updating previous: SparseTileSamplingPlanContent? = nil
    ) throws -> SparseTileSamplingPlanLease {
        try acquire(
            key: key,
            sourceBatch: SparseTileOwnedSourceBatch.capturingSelection(
                sources: sources,
                key: key,
                outputRegion: outputRegion
            ),
            outputRegion: outputRegion,
            limits: limits,
            updating: previous
        )
    }
}
