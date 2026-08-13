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

Commit SHA: `0222c88293de7d2ffd1ccdea08ae30c4cdddc7cc`

## Concerns

The unbounded full-package run is currently unsuitable as a signal on this host
because unrelated GPU/resource-heavy suites contend in parallel. The exact
Task 2 suites and all new regressions are clean.

---

# Task 2 fix round 1

## Files changed

- `Sources/MetalRenderer/Raster/DocumentPaintSurfaceTransaction.swift`
- `Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift`
- `Sources/MetalRenderer/Raster/DocumentPaintSurfaceStore.swift`
- `Sources/MetalRenderer/GridRenderer.swift`
- `App/PatternSpike/EditorSessionController.swift`
- `Tests/MetalRendererTests/DocumentPaintSurfaceTransactionTests.swift`
- `Tests/MetalRendererTests/DocumentPaintRenderContextTests.swift`
- `Tests/MetalRendererTests/RendererResizeTests.swift`

## RED evidence

1. Shrinking-import dirty bounds:

   `swift test --filter 'shrinkingImportPublishesOnlyDirtiesInsideResultGeometry'`

   The regression failed because the result published coordinates `(0, 0)` and
   `(1, 0)` after shrinking to a one-tile-wide geometry; constructing a
   descriptor for `(1, 0)` threw
   `coordinateOutsideSurface(PaintTileCoordinate(x: 1, y: 0))`.

2. Identical stack and already-active endpoint no-ops:

   The new context regressions initially failed to compile because
   `DocumentPaintLayerApplicationResult` and
   `DocumentPaintSurfaceRestoreResult` could not express `didPublish == false`,
   and the layer revision was non-optional. This established that the result
   contract could not accurately represent non-publication before production
   edits.

3. Review integration regressions:

   `swift test --filter 'identicalRendererLayerStackApplicationIsSuccessfulNoOp|releasedActiveRasterEndpointIsNotAcceptedAsNoOp'`

   Both tests failed as intended: the renderer wrapper threw
   `LayerStackError.invalidRestoration` for a successful identical-stack no-op,
   and restoring a released-but-tracked active raster endpoint returned success
   instead of reporting the unavailable revision.

## Implementation decisions

- Geometry-changing transaction dirties are sorted and deduplicated, then
  filtered against the resulting storage geometry. Old-geometry removals that
  are outside the result are represented by the canonical geometry identity
  change rather than published as invalid new-geometry coordinates.
- Identical layer-stack application compares state before reserving revisions or
  preparing a history transaction and returns `didPublish == false`, unchanged
  generation/geometry/stack, no history revision, and unchanged canonical
  identity. This path remains valid at `UInt64.max`.
- Layer endpoint restoration compares the registry's complete physical endpoint
  state before reservation. Repeating the already-active endpoint returns a
  non-publishing result.
- Raster endpoint identity is tracked by the context only. Repeating the active
  endpoint returns an empty non-publishing restore result; mutations that
  supersede it and releases containing its revision ID invalidate the marker.
- `GridRenderer.applyLayerStack` now exposes the optional revision so a no-op is
  successful. Editor history call sites already reject identical candidate
  stacks; they defensively require a revision before recording history.

## GREEN evidence

1. Required finding regressions:

   `swift test --filter 'shrinkingImportPublishesOnlyDirtiesInsideResultGeometry|identicalLayerStackIsNoOpWithoutHistoryOrIdentityAdvance|identicalLayerStackAtMaxRevisionsDoesNotOverflow|restoringAlreadyActiveLayerAndRasterEndpointsIsNoOp'`

   Result: 4 tests passed, 0 failures, 0.092 seconds.

2. Final exact regressions, including review edge cases:

   `swift test --filter 'shrinkingImportPublishesOnlyDirtiesInsideResultGeometry|identicalLayerStackIsNoOpWithoutHistoryOrIdentityAdvance|identicalLayerStackAtMaxRevisionsDoesNotOverflow|restoringAlreadyActiveLayerAndRasterEndpointsIsNoOp|identicalRendererLayerStackApplicationIsSuccessfulNoOp|releasedActiveRasterEndpointIsNotAcceptedAsNoOp'`

   Result: 6 tests passed, 0 failures, 0.097 seconds.

3. Final focused verification:

   `swift test --filter 'DocumentPaintSurfaceTransactionTests|DocumentPaintRenderContextTests|RendererResizeTests'`

   Result: 135 tests passed, 0 failures, 3.339 seconds. The original selected
   suite contained 129 tests; the four requested regressions and two review
   regressions account for the new total.

   Per the fix-round instruction, the unbounded parallel full suite was not
   rerun.

## Self-review and mutation check

- Removing result-geometry dirty filtering reproduces the out-of-bounds shrink
  failure while preserving the in-bounds changed coordinate.
- Moving equality checks after reservation reproduces identity overflow at max
  counters and creates unwanted history/generation publication.
- Removing full registry endpoint equality makes repeated layer restoration
  publish again; removing raster endpoint tracking does the same for raster
  restoration.
- Keeping the active raster marker after revision release makes an unavailable
  reference appear valid; the review regression detects this.
- Converting the renderer no-op to an error is detected at the public wrapper.
- Independent review found these two integration issues after the initial fix;
  both received focused RED regressions and are now GREEN.

## Diff check and concerns

- `git diff --check`: clean.
- Scope reviewed against fix round 1; no snapshots or presentation caches were
  added, and the repair plan was not edited.
- Preserved unrelated untracked `.vscode/` and
  `brushes/procreate/1_FREE_Charcoal_Set.key`.
- No implementation concerns. The broad-suite host contention concern from the
  original Task 2 report remains unchanged.

## Commit

Fix-round commit SHA is recorded in the final handoff.
