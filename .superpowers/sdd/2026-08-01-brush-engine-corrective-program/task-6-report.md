# Task 6 report — Isolate Replaceable Prediction

Status: DONE

## Outcome

- Added `PredictionOverlay`, which owns the replaceable replay surface,
  matching provenance boundary, bounded admission metadata, and the exact
  dirty regions from the last submitted overlay.
- Prediction replacement clears only the prior submitted footprint. The new
  footprint becomes clearable only after its frame is accepted and made
  visible.
- Routed every true-prediction producer, including Native Ink, generic replay,
  and predicted estimated-update replay, through the same limits: 64
  normalized samples, 512 logical dabs, and the active frame profile's
  predicted-instance budget.
- Prediction overload truncates only prediction and increments bounded
  diagnostics. Nonpredicted correction records retain their existing atomic
  replay capacity behavior.
- Added coordinator revision/ordinal provenance. Authoritative input rejects a
  mismatched prediction invalidation before coordinator, transient-buffer,
  arena, or scheduler mutation.
- Frame scheduling retains correction records while capping or discarding true
  prediction. Commit preparation can promote correction but never promotes a
  true predicted record to canonical truth.
- Pointer-up discards prediction before the final actual drain. Prediction is
  also discarded defensively during commit preparation.
- The prediction replacement hot path retains reusable dirty-region storage;
  the production allocation probe remains at zero allocations after warmup.

## Verification and TDD evidence

Initial RED failed because the prediction overlay and scheduler admission APIs
did not exist. Subsequent route-level RED cases exposed and fixed four gaps:

- A 65-sample generic replay-tail prediction retained all 65 samples and did
  not record overload.
- A long predicted move reached the legacy 4,096 projected-instance failure
  instead of stopping at 512 logical dabs.
- Predicted estimated-update replay reached the same legacy 4,096-instance
  failure and lost prediction provenance.
- The first no-allocation integration attempt allocated 2,176 times because it
  materialized `PixelRegionSet` values in the interactive path. In-place,
  preallocated footprint planning restored zero production allocations.

The final required gate was run exactly as specified:

```text
swift test --filter 'PredictionOverlayTests|DepositionMetamorphicTests|DepositionRendererTests'
```

Result: 74 tests in 3 suites passed. Coverage includes exact 64-sample and
512-dab boundaries, frame-instance admission, ordinary and estimated
prediction routes, provenance mismatch atomicity, correction retention,
nonpromotion, pointer-up discard, tile-local clear planning, production
allocation assertions, and Native Metal canonical byte identity across
prediction-off and arbitrary replacement cadences.

Adjacent ownership and scheduling gate:

```text
swift test --filter 'FrameSchedulerTests|StrokeRenderCoordinatorTests'
```

Result: 21 tests in 2 suites passed.

Build and hygiene gates:

```text
swift build -c release
git diff --check
```

Result: both exited 0.

## Review

The first independent review found coordinator-only cap enforcement, unwired
provenance APIs, cadence tests that did not submit replacement frames, dirty
footprints that included scheduler-dropped records, and one unbounded
predicted estimated-update route. The implementation and tests were corrected
for each finding.

The final independent re-review reported no Critical, Important, or Minor
findings and judged the task ready to commit. A separate targeted inspection
of estimated prediction found no remaining actionable issue after the early
provenance guard was added.

## Files

- Created `Sources/MetalRenderer/StrokeRuntime/PredictionOverlay.swift`
- Modified `Sources/MetalRenderer/StrokeRuntime/StrokeRenderCoordinator.swift`
- Modified `Sources/MetalRenderer/Deposition/FrameScheduler.swift`
- Modified `Sources/MetalRenderer/GridRenderer.swift`
- Created `Tests/MetalRendererTests/PredictionOverlayTests.swift`
- Modified `Tests/MetalRendererTests/DepositionMetamorphicTests.swift`

## Concerns

None blocking. The unrelated untracked `.vscode/` directory and brush asset
remain outside this task and its commit.
