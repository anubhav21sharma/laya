# Task 2 Report: Exact Canonical Identity and Dirty-Tile Publication

## Status

Implemented and verified from base `4706bc5a0ba67a11f4fef33ad7931757404db288`.

## Files

- `Sources/MetalRenderer/Raster/DocumentPaintSurfaceTransaction.swift`
- `Sources/MetalRenderer/Raster/DocumentPaintSurfaceStore.swift`
- `Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift`
- `Sources/MetalRenderer/Transactions/StrokeCommitter.swift`
- `Sources/MetalRenderer/GridRenderer.swift`
- `Tests/MetalRendererTests/DocumentPaintSurfaceTransactionTests.swift`
- `Tests/MetalRendererTests/DocumentPaintRenderContextTests.swift`
- `Tests/MetalRendererTests/RendererResizeTests.swift`

`StrokeCommitter.swift` is the necessary constructor ripple for the expanded
no-op application result. `GridRenderer.swift` only forwards context-owned
identity to resize tests; it derives and owns no revision counter.

## RED evidence

1. Initial contract RED:

   `swift test --filter 'DocumentPaintSurfaceTransactionTests|DocumentPaintRenderContextTests|RendererResizeTests'`

   Failed at compile time because `DocumentPaintRenderContext` had no
   `canonicalStateIdentity()`, and `DocumentPaintSurfaceApplicationResult` had
   neither `dirtyCoordinates` nor `canonicalIdentity`. This was the intended
   absent behavior. One test macro needed a nested `try` correction before
   production behavior work.

2. Review-regression RED:

   `swift test --filter 'transactionBoundarySortsAndDeduplicatesDirtyCoordinates|emptyClearDoesNotAdvanceCanonicalIdentity'`

   Ran 2 tests; both failed. Dirty input `[one, zero, one]` threw
   `unsortedCoordinate` instead of normalizing, and empty clear at
   `compositeRevision == UInt64.max` threw `canonicalIdentityOverflow` instead
   of remaining a no-op.

3. Publication coherence RED:

   `swift test --filter 'canonicalIdentityNeverMixesPublishedGeometryWithOldRevisions'`

   Failed at compile time because the deterministic post-publication test hook
   did not exist. The hook was introduced only under `DEBUG` to suspend the
   worker immediately after registry publication and prove the observable
   identity cannot mix new geometry with old revisions.

## Implementation decisions

- `CanvasCanonicalStateIdentity` is owned by `DocumentPaintRenderContext` and
  contains a stable document-lifetime generation, canonical geometry, and
  checked geometry/layer-stack/composite revisions.
- Transaction requests normalize dirty and explicit-removal coordinates with a
  sorted unique boundary before validation/allocation. Existing geometry bounds
  checks still reject every coordinate outside captured geometry.
- The worker forwards the exact normalized `DocumentPaintSurfaceCommitResult`
  dirties into the application result.
- A lock-protected context-created revision reservation preflights every
  required checked increment immediately before irreversible worker
  publication. No-op mutations never prepare the reservation, so max-counter
  no-ops remain valid and unchanged.
- Immediately after registry publication, the worker marks the reservation with
  the published geometry. While its MainActor continuation is suspended,
  `canonicalStateIdentity()` returns that coherent published tuple; after the
  continuation, the tuple becomes the context's durable state.
- Tile content advances composite only. Layer stack mutation advances layer and
  composite. Geometry replacement/resize/layer-history geometry restore
  advances all three. Raster history restore advances composite and also
  geometry/layer when its target geometry changes.
- Native archive import and no-op stroke construction were updated consistently
  without adding Task 3 snapshots or Tasks 4-6 caches.

## GREEN evidence

1. Review regressions:

   `swift test --filter 'transactionBoundarySortsAndDeduplicatesDirtyCoordinates|emptyClearDoesNotAdvanceCanonicalIdentity|canonicalIdentityNeverMixesPublishedGeometryWithOldRevisions'`

   Result: 3 tests passed, 0 failures.

2. Final focused verification:

   `swift test --filter 'DocumentPaintSurfaceTransactionTests|DocumentPaintRenderContextTests|RendererResizeTests'`

   Result: 129 tests passed, 0 failures, 3.370 seconds.

3. Broad package attempt:

   `swift test`

   This was not useful GREEN evidence. Highly parallel unrelated GPU/lifecycle
   suites entered severe host resource contention (roughly 500-second test
   durations) and reported unrelated deadline/workspace failures including
   `StrokeFrameSchedulerTests`, `ContentViewLifecycleTests`,
   `SparseTileSamplingPlanTests`, and a resize suspension timing assertion. The
   run did not complete normally. No Task 2 focused test failed in the clean
   selected verification.

## Self-review and mutation check

- Removing dirty forwarding fails the far-apart exact-coordinate test.
- Removing sorting/deduplication fails the transaction-boundary normalization
  test.
- Advancing the wrong counter class fails the opacity, tile, and resize/history
  assertions.
- Reusing a superseded geometry identity fails both context and renderer
  resize/history tests.
- Preflighting a no-op or dropping checked overflow fails the max-counter
  atomicity tests.
- Publishing geometry before its identity becomes observable fails the
  deterministic await-gap coherence test.
- Independent review initially found three Important issues (no-op overflow,
  publication coherence, dirty normalization). All received RED regressions and
  fixes. Re-review reported no remaining Critical or Important findings.

## Diff check

- `git diff --check`: clean.
- Scope reviewed against the Task 2 brief.
- Preserved unrelated untracked `.vscode/` and
  `brushes/procreate/1_FREE_Charcoal_Set.key`.
- The repair plan was not edited.

## Commit

Commit SHA: recorded after commit below.

## Concerns

The unbounded full-package run is currently unsuitable as a signal on this host
because unrelated GPU/resource-heavy suites contend in parallel. The exact
Task 2 suites and all new regressions are clean.
