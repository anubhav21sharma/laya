# Slice 1: Measured Grid Drawing Kernel

**Status:** Pending Performance Acceptance
**Gate:** `./scripts/verify-slice1.sh`
**Current implementation:** `65f8d24`

## Result

- Pure viewport, interpolation, grid projection, raster, ABI, lifecycle, and
  harness contracts pass.
- The macOS app and generic iPadOS Simulator target build.
- The real app metallib passes all six positive grid scene families.
- Each negative control fails on its intended pixel or structural assertion.
- Preview and commit stay within one 8-bit channel value.
- Cancel preserves canonical bytes and revision identity.
- Long-stroke counters record zero restamped instances.
- Manual pointer direction and cursor alignment were corrected and accepted.

Slice 1 is not accepted yet. A stable performance run and the remaining
manual acceptance record are unavailable, so this milestone does not establish
the fixed Slice 1 baseline required by the approved rebuild specification.

## Latest Available Measurement

The latest retained run is diagnostic evidence, not an accepted baseline:

- Artifacts:
  `.build/slice1-artifacts/positive/*/*.benchmark.json`
- Commit: `bc0818027a4d82e8778920fcb162e41fea67840d`
- Configuration: `Debug`
- GPU: `Apple Paravirtual device`
- OS: `Version 26.5.2 (Build 25F84)`
- Brush-processing p95: `0.6940364837646484 ms`
- Grid-pass p95: `3.0200000037439167 ms` (budget: `< 2 ms`)
- 500-dab GPU maximum: `12.080583328497596 ms` (budget: `< 3 ms`)
- Long-stroke missed-frame fraction: `0 / 242`
- Peak resident bytes: `25,968,640`
- Commit-pending maximum: `7.079958915710449 ms`
- Minimum recorded display-frame budget: `16.666666666666668 ms`

The functional, artifact, structural, and negative-control stages passed.
The gate stopped at the performance check because the grid and 500-dab GPU
budgets failed on the variable paravirtual GPU. Thresholds were not weakened.

## Decisions

- Keep timed `MTKView`; no evidence identifies frame scheduling as the cause of
  the paravirtual GPU variance.
- Keep fixed pending and instance-buffer capacities unchanged.
- Do not label Slice 1 accepted from a failed timing run.
- Planning Slice 2 may proceed, but Slice 2 implementation remains gated by
  accepted Slice 1 evidence under the rebuild delivery sequence.

## Manual Gate

Confirmed:

- The first dab is aligned with the cursor.
- Stroke direction matches pointer direction.
- Resize/display-scale input mapping is guarded by automated tests.

Still requires one recorded full sweep before acceptance:

- live grid continuity at edges and corners;
- preview/commit stability;
- Escape and focus-loss cancellation;
- idle-only Space-drag pan;
- cursor-anchored wheel/pinch zoom and clamp behavior;
- long-stroke responsiveness;
- resize rendering;
- commit-pending rejection without a perceptible stall.

## Acceptance Work Remaining

1. Run `./scripts/verify-slice1.sh` in a stable measured environment without
   weakening its budgets.
2. Record an accepted benchmark identity and exact baseline values.
3. Record the complete manual Mac checklist.
4. Change this status to `Accepted`, replace diagnostic measurements with the
   accepted run, run hygiene checks, commit, and push.

## Retrospective

- Flipped AppKit view coordinates must map directly from view bounds into
  `MTKView.drawableSize`; `convertToBacking(_:)` introduces the wrong backing
  origin and Y orientation for this path.
- Drawable mapping must handle bounds origins, independent X/Y scales,
  zero-size transitions, and display-scale changes during gestures.
- Slice 2 should keep an independent CPU correctness oracle while bringing up
  every production tiling family through Metal end to end.
