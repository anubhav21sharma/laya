# Interactive Brush Presentation Repair Design

**Status:** Approved direction from the project owner on 2026-08-13.

## Goal

Make the native Swift/Metal brush engine visibly responsive, correct, and
bounded through the shipping `InteractiveMetalView` path. Ordinary painting
must continue independently of drawable presentation, update only affected
canonical/display resources, preserve every supported tiling transform, and
produce measurable input-to-present evidence.

## Confirmed Failure Model

The current sparse producer is not spending seconds generating a stroke. The
shipping path stalls because one prepared result retains the worker's only
credit until a transient display submission is acknowledged, while the paused
`MTKView` receives no continuation draw request. The same display boundary
also:

- builds a full-drawable, three-texture RGBA16F layer composite and exceeds its
  fixed 96 MiB scratch budget at ordinary maximized window sizes;
- cancels and replaces an asynchronous display preparation before the prior
  request retires, allowing a second request to enter an exclusive compositor;
- assembles addressing from renderer state that can differ from the paint
  context's published geometry revision; and
- reduces every non-radial periodic strategy to independent rectangular
  modulo sampling, discarding half-drop, brick, reflection, oblique-lattice,
  and phase semantics.

The repair therefore targets the presentation boundary. It does not replace
the stroke generator, dynamics engine, compiled symmetry model, sparse layer
store, history model, project format, or Metal deposition backend.

## Considered Approaches

### 1. Tactical symptom repair

Call the existing continuation-frame helper, increase the scratch limit,
serialize cancellation, and add preset switches to the sampling shader. This
is the smallest change, but presentation would still own producer credit and
ordinary painting cost would remain proportional to full viewport area and
layer count. A larger window or slower drawable could reproduce the same
failure class. Rejected as the final architecture.

### 2. Decoupled native presentation caches

Retain the native brush producer and sparse document authority, but add
persistent canonical composite and transient presentation caches. A prepared
stroke page returns worker credit when its dirty tiles have been incorporated
into the transient cache, never when a drawable presents. The display pass
samples stable and transient caches through the complete compiled tiling fold.
This is the selected approach.

### 3. Third-party engine replacement

Embedding Krita would introduce C++/Qt/KDE, GPL distribution constraints, a
second document/tile/scheduler model, and conversions into Metal presentation.
It would still require a correct Laya display boundary. A later independent
engine such as libmypaint may be evaluated as an additional backend, but it is
not a remedy for the confirmed presentation failures. Rejected for this work.

## Non-Negotiable Invariants

1. Drawable availability, display preparation, and presentation completion
   never grant brush-input or deposition-worker credit.
2. Authoritative input is never dropped, duplicated, reordered, or replaced by
   prediction. Prediction cannot change the settled canonical document hash.
3. Every GPU-owned prepared stroke resource settles exactly once through
   cache adoption, cancellation, or failure.
4. Ordinary interactive drawing performs work proportional to dirty canonical
   tiles and affected presentation regions, not full document area.
5. Ordinary interactive drawing allocates no three-texture full-drawable
   scratch set.
6. One immutable presentation snapshot supplies geometry, tiling, layer,
   transient, viewport, and drawable revisions to a frame.
7. A newer presentation revision may supersede an older frame, but cannot
   supersede or discard document mutation.
8. CPU and GPU display folds agree for every compiled periodic and finite
   symmetry family.
9. Idle means all input, cache updates, submissions, leases, callbacks, and
   revisions are settled; it is not inferred from an empty UI event queue.

## Architecture

### Persistent canonical composite cache

A `CanvasCompositeTileCache` owns RGBA16F composite tiles in canonical document
space. Its keys contain the canonical tile coordinate, document generation,
layer-stack revision, and composite revision. A committed layer mutation
publishes exact dirty tile coordinates. The cache recomposites only those
coordinates in layer order and retains unaffected tiles.

The cache has an explicit resident-byte budget, deterministic eviction of
reconstructible tiles, exact high-water accounting, and no dependency on a
drawable. Full invalidation is reserved for changes that genuinely affect all
canonical pixels, such as a layer-wide blend/opacity change or document
replacement.

### Transient stroke presentation cache

An `InteractiveStrokePresentationCache` owns the latest displayable transient
stroke tiles independently of the worker's reusable deposition page. For each
`StrokePreparedDepositionBatch` it:

1. validates the stroke generation and monotonic cache revision;
2. encodes an offscreen copy/composite of only the batch's dirty tiles;
3. publishes the new transient revision when that command completes; and
4. acknowledges the prepared page immediately after cache ownership is safe.

This acknowledgement returns worker credit without waiting for an
`MTLDrawable`. The cache preserves the last completed revision while the next
revision is being prepared. A bounded two-slot update pipeline may overlap CPU
preparation with one GPU cache update, but it cannot grow without limit.

At stroke commit, stable composite dirties are applied before the matching
transient revision is retired. That prevents a blank or double-painted frame.
Cancellation retires the transient generation without mutating committed
tiles.

### Direct display pass

Ordinary `draw(in:)` no longer invokes the full-output `LayerCompositor`.
Instead, one display submission samples the persistent canonical composite and
optional transient cache into the drawable. Draw and erase transient modes are
combined in the display shader using the existing composite semantics.

The existing bounded layer compositor remains available for stable capture and
export, where chunking and explicit completion are appropriate. Raising the
96 MiB display scratch budget is not part of the repair.

### Compiled display fold

`SparseTileSamplingOutputMapping` gains a representation of the complete
compiled display fold rather than a preset identifier. It carries the lattice
transform, domain/period, parity or phase rules, reflections, and finite/radial
layout required to map output pixels into canonical storage.

The GPU mapping is produced from `TilingStrategy.compiledSymmetry`, not a
second hand-written preset table. CPU oracle probes and Metal output must agree
at central cells, noncentral cells, phased boundaries, reflected cells, seams,
and corners. Export paths that render a displayed/flattened scene consume the
same mapping contract.

### Immutable presentation snapshots

A `CanvasPresentationSnapshot` contains:

- document generation and canonical geometry revision;
- layer-stack and canonical composite revisions;
- transient generation/revision and composite mode, when present;
- compiled display-fold payload;
- viewport transform;
- drawable pixel size and backing-scale revision; and
- grid/boundary display options.

The snapshot is constructed only after its constituent revisions are mutually
compatible. Resizing, zooming, tiling changes, document replacement, and layer
changes publish a new snapshot. An in-flight older frame may finish and be
discarded, but no replacement enters an exclusive mutable preparation object
until the older request has retired.

### Interactive frame pump

An explicit `InteractiveFramePump` owns on-demand redraw state. It requests a
frame while any of these are true:

- an active stroke has unpublished or unpresented cache progress;
- a newer stable/transient presentation revision exists;
- viewport animation or resize requires a new frame; or
- debug presentation telemetry requires a sample.

Input admission, cache publication, drawable-size changes, and command-buffer
completion signal the pump. Every exit from `draw(in:)` returns the pump to a
defined state. It stops when the newest compatible revision has presented and
the renderer is otherwise idle, so the repair does not create a permanent
busy render loop.

### Production-path telemetry

Every authoritative/coalesced input sample receives a monotonic trace identity.
The shipping path records monotonic timestamps for event receipt, worker
dequeue, dab preparation, transient-cache submission/completion, drawable
submission, and drawable presentation. It also records queue depths, dirty
tiles/regions, cache hits and resident bytes, revision identities, frame
deadlines, errors, and resource ownership counts.

Debug/acceptance runs write JSONL incrementally and emit a one-second progress
line. Performance evidence uses actual drawable presentation time; offscreen
command completion is labeled separately and cannot satisfy interactive
acceptance.

## Failure Handling

- A cache-update command failure fails the active renderer operation, releases
  its prepared-page ownership exactly once, and preserves the last complete
  display revision when safe.
- A stale snapshot or revision is discarded as expected superseded work. It is
  not shown as an end-user Metal error.
- Invalid or incompatible geometry fails before encoding and includes the two
  conflicting revision identities in diagnostics.
- Resource-budget exhaustion fails closed with requested/current/high-water
  byte counts. The renderer never silently falls back to a full-canvas path.
- Drawable unavailability delays presentation only. It cannot stop input,
  canonical mutation, cache updates, cancellation, or commit settlement.
- Resizing and rapid invalidation use monotonic latest-wins publication plus
  explicit retirement; cancellation alone is not treated as retirement.

## Delivery Slices

### Slice 1: Regressions and observability

Add red tests for frame starvation, drawable-independent worker progress,
maximized-drawable memory, in-flight invalidation, geometry transition, and
periodic display pixels. Add shipping-path trace timestamps and live progress
output before changing production behavior.

### Slice 2: Correct scheduling and revision ownership

Introduce the frame pump and immutable presentation snapshot. Make ordinary
invalidation retire or supersede work without concurrent compositor entry.
This slice must remove the user-visible `already processing another request`
and inconsistent-addressing failures, but cannot yet claim final performance.

### Slice 3: Decoupled persistent presentation

Add transient and canonical caches, move prepared-page acknowledgement to
transient-cache completion, and remove `LayerCompositor` from ordinary
interactive display. This slice closes starvation and full-drawable scratch
dependence.

### Slice 4: Complete compiled tiling display

Encode the compiled display-fold payload for Metal, use it in interactive and
flattened display output, and prove all symmetry families against CPU/pixel
oracles.

### Slice 5: Shipping-path acceptance

Run focused red/green tests, full renderer/app suites, Release shipping-route
latency runs, real ten-minute endurance, Metal validation, memory/resource
settlement, and physical manual review on the required hardware matrix.

## Acceptance Contract

All measurements come from the exact Release executable and commit being
accepted.

- Input-to-command-submit: p95 at most 8 ms and p99 at most 12 ms on 120 Hz;
  p95 at most 12 ms and p99 at most 16.7 ms on 60 Hz.
- Input-to-drawable-present: p95 within two refresh intervals, p99 within three,
  and no authoritative sample above 100 ms.
- Backlog returns to zero within two refresh intervals after pointer-up, never
  shows a sustained positive slope, and contains no dropped/reordered input.
- Missed display deadlines are at most 1% after warm-up, with no run longer
  than two consecutive misses.
- Brush preparation p95 remains below 2 ms for the representative dry-media
  matrix.
- A true ten-minute mixed session at 2048-square and 4096-square sizes has no
  renderer/Metal error, hang, ownership leak, or trace overflow.
- During the final five endurance minutes, RSS slope is at most 1 MiB/min;
  post-settle RSS is within 10% or 64 MiB of warm baseline, whichever is larger.
- Every supported tiling passes canonical and actual-drawable pixel oracles at
  1x/2x backing scale and 0.25x/1x/8x zoom with no hole, phantom, or seam.
- Maximized supported drawables, including the reported failing pixel area,
  complete without full-drawable scratch allocation or an error banner.
- All active operations, tile leases, cache updates, submissions, callbacks,
  and transient generations return to zero at idle.

## Regression Honesty

Every new regression must fail against the pre-repair implementation for the
expected behavioral reason. After it passes, temporarily disabling the
relevant production condition must make it fail again. Source-text assertions,
synthetic button-state checks, explicit offscreen flushes, and logically scaled
durations cannot substitute for shipping-path behavior.

## Hardware Qualification

Performance qualification requires a lowest-supported 60 Hz Apple-silicon Mac
and a current 120 Hz Apple-silicon Mac with mouse input, plus supported tablet
hardware. If iPadOS remains a shipping target, it additionally requires an
A14-class 60 Hz iPad and an M-series 120 Hz iPad with Apple Pencil. Correctness
and ownership runs repeat with Metal validation enabled; timing runs use it
disabled.

## Non-Goals

- Porting Krita or changing Laya's licensing model.
- Adding wet mixing, smudge, bristle, or other new brush families.
- Retuning imported brush feel before the shipping path meets latency and
  correctness gates.
- Preserving deprecated native renderer or harness compatibility paths.
- Claiming professional brush quality solely from automated performance gates.
