# Brush Engine Corrective Architecture Report

Date: 2026-08-01

Status: Proposed corrective authority

Scope: Laya brush input, logical dab generation, live rendering, built-in dry
brushes, performance validation, perceptual validation, and editor cursor
semantics

Krita reference checkout: `/Users/anubhav/git/krita` at
`be34a47a66f1bf2637a13a33d94250a9864d96a2`

## 1. Executive Decision

The current professional brush implementation is not acceptable for product
use. The reported failures are reproducible and share a small number of
systemic causes:

1. ordinary live input rebuilds a retained replay tail instead of depositing
   only newly emitted authoritative dabs;
2. end taper is applied retroactively after pointer-up, visibly retracting the
   stroke endpoint;
3. the cursor represents nominal diameter rather than the evaluated brush
   footprint;
4. the four professional presets were built from deterministic validation
   fixtures and numeric capability combinations rather than calibrated,
   artist-reviewed brush assets;
5. the direction-following chisel tip has no corner-angle interpolation or
   continuous-join treatment;
6. the Stage 5 evidence gate proves determinism and internal invariants but
   does not fail visibly useless output, poor responsiveness, or unset manual
   quality assessments.

This is not a collection of isolated preset-tuning defects. Tuning flow,
opacity, or grain strength on top of the current live-stroke path would leave
the dominant performance and interaction failures intact.

The correction should be a focused rewrite of the live stroke coordinator,
prediction/replay policy, frame scheduler boundary, cursor semantics, and four
built-in professional brushes. The brush definition model, deterministic
dynamics, logical dab abstraction, compiler/resource cache, symmetry model,
canonical raster ownership, history transaction boundary, and useful Metal
deposition primitives can remain.

Stage 5 must be treated as rejected for product acceptance until this report's
functional, performance, visual, and manual gates pass. The terms
`realtime120` and `professional` must not be used as acceptance claims merely
because a definition contains those enum values.

## 2. Authority And Relationship To Existing Documents

This report refines and corrects implementation choices made under:

- [World-Class Brush Engine Design](../specs/2026-07-26-world-class-brush-engine-design.md);
- [Brush Deposition Backend Design](../specs/2026-07-28-brush-deposition-backend-design.md);
- [Stage 5 Professional Dry-Media Design](../specs/2026-07-30-professional-dry-media-stage5-design.md);
- [Stage 5 Professional Dry-Media Plan](../plans/2026-07-30-professional-dry-media-stage5.md);
- [Professional Dry And Non-Interacting Media Milestone](../milestones/12-professional-dry-media.md).

The world-class engine and deposition specifications already contain the
correct high-level invariants: completed stroke length must not increase
per-frame work, actual samples alone determine canonical pixels, prediction is
transient, CPU work is bounded per frame, resource preparation stays off the
input path, and manual review decides perceptual quality.

The failure occurred in the Stage 5 implementation and acceptance policy, not
in those load-bearing product invariants. This report therefore preserves the
following decisions:

- canonical raster pixels remain the document source of truth;
- symmetry and tiling remain projection metadata and do not rewrite committed
  pixels;
- interpolation, spacing, dynamics, and random generation happen once per
  logical stroke before symmetry projection;
- preview and commit use the same coverage and accumulation equations;
- actual input alone determines the committed result;
- a stroke remains cancelable until completion and creates one history command;
- compilation, texture decoding, mip preparation, pipeline creation, and file
  I/O remain cold-path operations;
- dry/ink/glaze/marker/erase remain on a deposition backend, while future
  smudge and Wet Mix use a specialized interaction backend;
- the engine remains stamp-first where stamps are the correct primitive.

The following Stage 5 choices are superseded:

| Previous choice | Corrective decision |
| --- | --- |
| Every professional brush uses `.replayTail` | Authoritative deposition is append-only. Replay is reserved for prediction and explicitly bounded correction windows. |
| Long retroactive end tapers on ordinary brushes | Default taper is causal. Any retroactive correction is short, bounded, visually stationary at the pointer, and opt-in. |
| Procedural validation textures are professional assets | Validation fixtures remain test-only. Product brushes use intentionally authored and reviewed assets. |
| A nominal circle is a sufficient cursor | The cursor is derived from the evaluated tip footprint and current input state. |
| A nonzero missed-frame count is diagnostic only | Interactive missed frames, latency, backlog growth, and frame pacing have hard acceptance thresholds. |
| A one-pixel result satisfies visible output | Visibility, width, density, tonal range, and footprint contracts have meaningful quantitative floors. |
| Unset manual cards permit a “software complete” product brush | Engineering integration may be complete, but a brush is not product-accepted or exposed as professional until required manual cards pass. |
| Direction can directly rotate a thin chisel stamp | Direction-following tips require angular interpolation, filtering, and explicit corner semantics. |

## 3. Investigation Method

The findings in this report come from four independent evidence sources:

1. a fresh review of the Laya source path from normalized input through
   `GridRenderer`, transient stroke storage, dynamics, resource generation,
   cursor display, and Stage 5 validation;
2. direct use of the running macOS application on a 2048×2048 plain canvas
   with the debug HUD and JSONL performance logging enabled;
3. inspection of the generated Stage 5 positive artifacts, long-stroke raw
   measurements, manual-card catalog, and artifact-only validator;
4. a local source review of Krita's pixel brush, asynchronous dab queue, dab
   cache, freehand update scheduling, brush cursor, fan-corner behavior,
   color-smudge engine, hairy/bristle engine, and stroke benchmarks.

The live measurements below were captured on the available paravirtual Metal
environment. They do not establish physical-device performance, but they do
reproduce the same failure shape reported on a separate physical MacBook. The
user-observed 2 FPS floor on physical hardware must be retained as a release
blocking report until a controlled physical trace disproves it.

## 4. Reproduced Failures

### 4.1 Technical Ink long-stroke responsiveness

A single long Technical Ink stroke at 20 px on a 2048×2048 plain canvas
reported approximately:

- 445.55 ms CPU preparation;
- 1,398.57 ms input-event-to-submit latency;
- 20.16 ms GPU duration;
- 6,796 peak queued/projected work items;
- roughly 23–30 FPS around the captured result;
- approximately 50% or more missed display frames.

The retained Stage 5 software trace independently records 124 missed
event-to-submit frame budgets out of 128 samples for Technical Ink. The other
professional brushes record 117–126 misses out of 128.

The performance-status file nevertheless sets `correctnessPassed` to true.
Its validator verifies that the missed-frame dictionary matches the raw
artifacts but imposes no acceptable maximum. The 0.45 ms CPU preparation p95
reported by the isolated benchmark therefore does not represent the complete
interactive path that the user experiences.

### 4.2 Retroactive endpoint retreat

Technical Ink specifies an end taper of 1.5 nominal diameters, a minimum size
of 0.08, and a minimum flow of 0.25. At a 40 px brush size, the final 60 px of
the retained stroke are recomputed after total stroke length becomes known.
The end of the visible line can therefore shrink almost to nothing behind the
released cursor.

This exactly explains the reported 20–30 px apparent endpoint retreat. The
renderer is not merely adding a tapered cap. It is revising already previewed
coverage behind the pointer.

### 4.3 Graphite footprint and appearance

At a nominal 20 px size, Graphite rendered as a faint hairline rather than a
pencil mark. The same stroke reported approximately 179.33 ms CPU preparation,
747.63 ms event-to-submit latency, and a high-water mark of 2,880 work items.

The cursor is circular and nominal. The brush definition then applies:

- a narrow generated ellipse;
- an aspect ratio of 0.34;
- pressure-dependent size down to 0.25;
- two full-strength multiplied grain layers;
- low base flow and pressure-dependent opacity.

The painted support is therefore much narrower and fainter than the cursor,
especially for mouse fallback or modest pressure. No contract checks that the
visible width agrees with the promised cursor footprint.

### 4.4 Natural Charcoal visibility

Natural Charcoal produced no perceptible live mark in the direct app pass. It
still consumed approximately 33.17 ms CPU preparation and 441.24 ms
event-to-submit latency.

The canonical positive artifact contains exactly one nontransparent pixel.
This passed the existing `nonemptyVisibleOutput` condition because one pixel
is technically nonempty.

Coverage is attenuated repeatedly by:

1. an irregular charcoal tip;
2. a multiplied soft-round shape;
3. a full-strength charcoal grain;
4. a full-strength paper grain;
5. full-strength dry-breakup edge treatment;
6. base flow 0.24;
7. pressure-dependent flow and opacity.

These operations are individually valid engine features. Their uncalibrated
composition makes the preset functionally invisible.

### 4.5 Chisel Marker turns

The Chisel Marker uses a 0.22-aspect tip, 3.5% spacing, and direct
direction-to-rotation mapping. Each small change in segment direction rotates
the next elongated stamp. At a turn, adjacent stamps fan outward with no
shortest-angle interpolation, angular rate limit, join construction, or
continuous chisel ribbon. That produces the reported icicle-like spikes.

The Brush Lab curve card does not provide sufficient protection. It contains
only five points and renders a small polygonal curve. The card remains
unassessed, as does the sharp-corner card.

### 4.6 Artificial texture and feel

The professional tip and grain resources are generated from deterministic
integer/hash functions in `BrushTextureFactory`. That source explicitly calls
the collection a validation pack. Determinism is useful for engine tests, but
the resulting noise does not contain the coherent fibers, pores, clumps,
directional wear, material variation, or scale hierarchy expected from real
graphite and charcoal.

The artificial feel is therefore not just a sampling or performance problem.
The source material and preset construction never went through an actual
artist-calibration loop.

## 5. Root-Cause Analysis

### 5.1 The live path performs work proportional to retained stroke history

For ordinary actual input, `GridRenderer.ingestGeneratedSample` appends the
chunk to `TransientStrokeBuffer` and calls `rebuildReplayLayer`. That method:

1. clears replay scratch collections while retaining capacity;
2. walks all retained actual and predicted chunks;
3. reapplies known-total-distance taper when finishing;
4. reprojects retained dabs;
5. rebuilds dirty rectangles for every projected record;
6. canonicalizes the full replay dirty-region set;
7. replaces the replay surface contents.

The bounds of 256 samples, 2,048 logical dabs, and 4,096 projected instances
prevent unbounded memory, but they do not make the operation fast. Repeating a
4,096-instance rebuild for each new input event is still excessive, and
symmetry can amplify deposition work further.

The existing invariant says completed stroke length must not increase
per-frame work. Retaining only a bounded tail technically prevents infinite
growth, but it does not satisfy the product intent when the fixed bound itself
is far beyond the interactive budget.

### 5.2 Prediction and semantic correction were coupled to authoritative paint

Prediction legitimately needs replaceable pixels. Retroactive taper also
needs revision under the current definition. Those two needs led to one
general replay mechanism, which was then used for every professional brush on
every event.

The correct separation is:

- authoritative actual dabs are deposited once;
- prediction lives on a distinct replaceable overlay;
- rare semantic correction uses a separate, very small correction window;
- brushes that require large-scale stroke revision are not executed as an
  ordinary raster deposition brush.

### 5.3 Nominal size, logical footprint, and visible support were conflated

The editor stores nominal diameter. The renderer evaluates aspect, pressure,
tip alpha, grain, threshold, tilt, and rotation. The cursor ignores those
evaluated properties and always draws a circle from nominal diameter and zoom.

The application therefore has no single truthful answer to “how wide will the
next mark be?” The solution is not to force every brush to fill a circle. The
solution is to define cursor semantics and compute an effective footprint from
the compiled brush and current input.

### 5.4 Capability coverage replaced perceptual brush design

The Stage 5 definitions exercise dual shapes, dual grains, dry breakup,
rotation, pressure, tilt, scatter, taper, marker overlap, and replay. This is
valuable as an engine matrix but is not evidence that the combinations make a
good tool.

A world-class preset begins from intended mark behavior, then uses the minimum
engine features required to achieve it. The current presets began from engine
features and combined them into brush definitions.

### 5.5 The acceptance gate measured internal truth instead of user truth

The gate is strong at hashes, schema exactness, deterministic replay,
projection equivalence, negative controls, provenance, and bounded resource
accounting. It is weak at:

- sustained interactive frame pacing;
- meaningful visible coverage;
- cursor-to-mark agreement;
- endpoint agreement;
- turn and join quality;
- texture character;
- pressure usefulness;
- actual user approval.

The missing manual assessments were correctly represented as pending, but the
milestone language still allowed “software complete” to be interpreted as the
brushes being effectively finished. That terminology must be corrected.

## 6. What To Retain, Replace, And Remove

### 6.1 Retain

- normalized input and capability representation;
- deterministic path interpolation and random channels;
- immutable `BrushDefinition` and compiled brush identity;
- logical dabs before symmetry projection;
- projection transforms that correctly rotate and mirror the entire dab frame;
- canonical raster and one-command-per-stroke history semantics;
- compiled Metal pipelines and typed resource budgets;
- offscreen rendering, deterministic trace replay, negative controls, and
  artifact provenance;
- separation between deposition and future interaction materials;
- Brush Lab as an internal engineering surface;
- debug HUD and persistent performance logging.

### 6.2 Replace

- normal-stroke `replayTail` with incremental authoritative deposition;
- `GridRenderer` ownership of input, replay, scheduling, and deposition with a
  dedicated stroke coordinator and frame scheduler;
- nominal circular cursor with effective footprint outlines;
- the four current professional definitions and their generated assets;
- direct direction-to-chisel-rotation with filtered angular interpolation;
- performance-status success semantics that tolerate nearly every frame
  missing its budget;
- “nonempty output” with brush-specific visibility and coverage contracts.

### 6.3 Remove from product paths

- procedural validation textures as product brush assets;
- large retroactive taper windows for ordinary drawing;
- any synchronous wait for GPU completion on the input or main-actor path;
- any full retained-tail projection or dirty-region rebuild for a new actual
  input sample;
- product exposure of an unreviewed brush under a professional label.

## 7. Target Runtime Architecture

```text
Platform events
    |
    v
InputAdapter -- actual/coalesced/predicted provenance
    |
    v
StrokeInputQueue (bounded, lock-free or actor-isolated off main actor)
    |
    v
Path + Stabilization + Spacing + Dynamics
    |
    v
LogicalDabBatch (only newly emitted dabs)
    |
    +--------------------------+
    |                          |
    v                          v
Actual queue               Prediction queue
append-only                replaceable, short-lived
    |                          |
    v                          v
Compiled projection + instanced Metal encoding
    |                          |
    v                          v
Authoritative live layer   Prediction overlay
    |                          |
    +------------+-------------+
                 |
                 v
             Display composite
                 |
        pointer-up / successful drain
                 |
                 v
       Canonical commit + one history command
```

### 7.1 `StrokeRenderCoordinator`

Introduce a coordinator outside `GridRenderer` that owns one active stroke:

- immutable compiled brush and editor intent captured at pointer-down;
- authoritative generator state;
- prediction generator snapshot or deterministic prediction replacement state;
- actual and predicted work queues;
- live authoritative and prediction surfaces;
- frame-budget accounting and telemetry;
- cancellation and commit state.

It exposes operations equivalent to:

```swift
begin(configuration:initialSamples:)
append(actualSamples:predictedSamples:)
prepareFrame(budget:)
submitPreparedFrame()
finish(finalActualSamples:)
cancel()
```

No operation accepts or returns the complete historical dab list for ordinary
deposition.

### 7.2 Incremental authoritative deposition

Each authoritative logical dab is assigned a monotonically increasing ordinal
and deposited at most once into the authoritative live surface. The engine
maintains the last emitted path distance and spacing accumulator, so the next
input batch emits only the new arc-length suffix.

Projection should use transform tables or Metal instancing wherever possible:

- one logical dab record;
- N symmetry transforms supplied separately;
- shader or bounded pre-encoding expands to projected fragments;
- only intersecting canonical fragments are rasterized;
- dirty tiles are derived from new projected bounds only.

Per-event CPU cost becomes proportional to newly emitted logical dabs, not
retained stroke length.

### 7.3 Prediction overlay

Prediction remains replaceable but isolated:

- actual samples invalidate overlapping predicted ordinals;
- the prediction overlay is cleared only in its previous dirty regions;
- the prediction tail has a small time/distance cap, not a 2,048-dab generic
  replay allowance;
- prediction work may be shortened or disabled under overload without changing
  authoritative output;
- committed pixels never come from predicted samples.

The overlay should normally contain tens of dabs, not thousands. Its exact cap
is selected from measured input rate, spacing, brush size, symmetry factor,
and frame budget.

### 7.4 Explicit correction window

Some future brushes may need small retroactive corrections for stabilization,
curve finalization, or specialized taper. That is a distinct feature:

- it is opt-in per compiled brush;
- its maximum sample, distance, dab, and pixel-area cost is declared;
- it owns a separate correction surface or suffix transaction;
- it never rewrites the completed body of the stroke;
- its maximum visible endpoint displacement is tested;
- it cannot qualify for a performance tier if the declared correction window
  misses that tier's budget.

The four initial professional brushes should not require a correction window
for ordinary drawing.

### 7.5 Frame scheduler

The scheduler runs outside the main actor and follows the active display rate.
It must:

- accept coalesced batches without blocking event delivery;
- prepare logical and projected records before acquiring a drawable;
- use preallocated ring buffers and private GPU resources;
- acquire the drawable late;
- encode new authoritative work, prediction replacement, and display composite
  as separate measured phases;
- maintain at most a tightly bounded authoritative backlog;
- report overload instead of silently removing authoritative dabs or changing
  dynamics;
- drain authoritative work before commit without replaying completed paint;
- expose p50/p95/p99 for input preparation, event-to-submit, GPU completion,
  frame time, queue depth, and input-to-visible presentation where measurable.

If a built-in brush cannot maintain the declared tier with its exact semantics,
the brush or implementation fails acceptance. A growing backlog is not an
acceptable mechanism for preserving theoretical quality while destroying
interactive feel.

### 7.6 Dab and resource caching

Krita demonstrates that a stamp engine benefits from caching equivalent tip
masks and from precision-aware reuse. Laya can implement a Metal-native form:

- compile immutable shape and grain pyramids before activation;
- store active resources in private Metal textures;
- pin the active compiled brush;
- use a byte-budgeted LRU for inactive brushes;
- cache or atlas reusable mask variants by quantized size, aspect, rotation,
  hardness, subpixel phase, and relevant material inputs;
- bypass mask regeneration when the shader can transform the same source
  texture directly;
- select mip levels from projected footprint;
- batch consecutive dabs sharing pipeline and resource bindings;
- measure hit rate, miss cost, residency, and eviction.

Unlike Krita's CPU paint device, Laya should not create a separate bitmap for
every transformed stamp when the GPU can sample one source texture through an
affine frame. The transferable principle is reuse and incremental work, not a
literal port of Krita's classes.

### 7.7 Commit and cancel

- The authoritative live layer remains transient until pointer-up.
- Pointer-up first stops prediction, accepts final actual/coalesced input, and
  drains only outstanding new authoritative work.
- The final live surface is merged once into canonical storage.
- The history system records one region command.
- Cancel discards both live surfaces without touching canonical pixels.
- A failed allocation, encode, or command buffer leaves the previous committed
  document intact and reports a typed error.

## 8. Taper And Stroke-Termination Semantics

### 8.1 Default rule

The default brush does not infer a long end taper after release. Size, flow,
and opacity are evaluated causally from available input such as pressure,
speed, tilt, and authored dynamics.

### 8.2 Permitted termination effects

An ordinary ink brush may use:

- a final cap consistent with the current tip;
- a short low-pass pressure release based on actual pressure samples;
- a tiny bounded endpoint easing window whose maximum displacement is below a
  declared pixel tolerance;
- optional stylized taper modes selected by the user or preset author.

The previewed endpoint must remain at the release location within tolerance.
The engine must not make a completed mark appear to jump backward.

### 8.3 Required endpoint tests

For every built-in brush and size tier:

- record the final actual sample position;
- compute the final visible support along the stroke tangent;
- assert the support reaches the expected cap range;
- compare pre-release and post-release rasters;
- assert changed pixels are confined to the declared correction window;
- assert the centroid or visible endpoint does not retreat beyond tolerance;
- repeat with mouse, pressure ramp-down, fast release, prediction enabled, and
  prediction disabled.

## 9. Cursor Semantics

### 9.1 Effective footprint

The compiled brush provides an outline or conservative alpha-support boundary
for the evaluated tip. The cursor pipeline applies:

- current nominal diameter;
- pressure or no-pressure neutral value;
- tilt and azimuth where available;
- aspect ratio and deformation;
- brush/tip rotation;
- mirror state when relevant;
- viewport zoom and drawable scale.

The default cursor is the actual transformed tip outline. A circular cursor is
valid for circular tips or as an explicitly selected nominal-size guide, not as
the universal representation.

### 9.2 Cursor fallback and stability

- Before pressure contact, use a declared hover/default pressure value.
- Smooth noisy hover pressure separately from paint dynamics.
- For highly textured tips, show the stable alpha-support contour rather than
  every pore.
- For scatter brushes, show the core tip plus an optional scatter envelope.
- For broad tilted media, update the outline with tilt and azimuth.
- Cursor computation must not allocate or read GPU texture bytes per event;
  compiled outline data is cached.

### 9.3 Cursor correctness tests

Render a single controlled dab using the same compiled definition and input
state as the cursor. Compare the painted alpha bounds against the cursor's
declared effective bounds. Brush-specific tolerances may exclude deliberately
sparse pores, but the cursor may not promise a 40 px contact while the main
painted support is a 3 px hairline.

## 10. Professional Brush Rebuild

The four current professional presets should be removed from product
acceptance and rebuilt one at a time after the incremental engine is working.
Each brush is admitted independently; failure of one does not lower another
brush's threshold.

### 10.1 Asset policy

Product assets may be:

- scanned and cleaned physical marks owned or licensed for Laya;
- intentionally painted grayscale shape and grain resources;
- procedurally generated assets only when the procedure is itself an authored
  visual design and passes the same manual review;
- packaged at sufficient resolution with deterministic checked-in source
  provenance and reproducible derived mipmaps.

Test fixtures remain small, deterministic, and synthetic, but cannot be used
to claim product quality.

The author-supplied
`brushes/procreate/1_FREE_Charcoal_Set.brushset` is an approved real reference
corpus, not a synthetic unit fixture. `C Charcoal`
(`CC70504F-0D16-4D26-88A6-BF47BDA8ADE8`) is the primary Natural Charcoal
fidelity target and `C Charcoal Soft`
(`21AF8C6B-3FB1-4BF8-8F89-F5768271DA35`) is a secondary characterization
target. Both use an active `Sub01` and refer to absent Source Library resources:
`Haggard-Oval.png`, `Brush-Preset-Bonobo.png`, and
`Brush-Artery-Charcoal-Corse.jpg`. Laya must parse the active component
explicitly, preserve independent component behavior in a native composite dry
brush, and supply project-owned replacements recorded as approximations. The
two supplied high-resolution paper photographs are approved source material
for owned grain creation. The `.brushset` and photographs stay on the offline
tooling/test path and are never interpreted by the renderer.

Every asset records:

- source and license/provenance;
- intended physical/material role;
- native dimensions and color interpretation;
- alpha/support bounds;
- mip-generation policy;
- maximum useful projected size;
- expected grain anchoring and scale range;
- visual reference sheet.

### 10.2 Technical Ink

Design target:

- crisp, opaque, continuous technical line;
- predictable width at neutral input;
- useful pressure range without vanishing at low pressure;
- no automatic long end taper;
- smooth curves and caps;
- no grain unless a specific ink preset calls for it;
- cursor width agrees with the principal painted support.

Implementation guidance:

- begin with a circular or subtly elliptical authored nib;
- use causal pressure-to-size and pressure-to-flow curves;
- keep spacing high enough for performance but low enough to prevent scallops;
- prefer stable tangent filtering over rotating on each raw segment;
- calibrate mouse fallback separately from Pencil/Wacom pressure;
- add stylized tapered-ink as a separate preset after the neutral technical
  brush passes.

### 10.3 Graphite Pencil

Design target:

- recognizable graphite tooth at normal viewing scale;
- coherent paper interaction rather than white-noise dropout;
- light-to-dark pressure range with repeated buildup;
- useful side shading under tilt;
- effective width consistent with the cursor;
- no disappearing line at neutral mouse input.

Implementation guidance:

- use one authored graphite contact shape with irregular but coherent edges;
- use one canonical paper grain as the primary substrate interaction;
- introduce any brush-local graphite variation at modest strength rather than
  multiplying two full-strength masks;
- map pressure primarily to pigment deposition and secondarily to size;
- map tilt to broader contact and altered grain/opacity, with a calibrated
  transition between tip and side;
- retain enough minimum coverage that one pass is visible while allowing
  buildup to create darker values;
- assess texture at 100%, fit-to-canvas, and common export sizes.

### 10.4 Natural Charcoal

Design target:

- immediately visible broad porous contact;
- larger clumps and voids than graphite;
- strong repeated buildup and expressive pressure/tilt variation;
- coherent material breakup without erasing most coverage;
- rough but intentional edges;
- useful mouse fallback.

Implementation guidance:

- start with the approved `C Charcoal` parent plus active `Sub01`, using
  Laya-owned replacements for the absent oval tip, fine paper grain, and coarse
  charcoal grain; do not collapse the independent components into the current
  procedural ellipse/noise fixture;
- decode and report the source settings through the bounded offline converter;
  do not copy Procreate keys or parsing into product runtime modules;
- use the source QuickLook thumbnail as an independent characteristic reference
  for coverage, width, texture spectrum, and edge character, not as an exact
  pixel golden;
- add a secondary envelope only if it improves the mark in isolation;
- avoid multiplying multiple sparse masks at full strength;
- calibrate base coverage before enabling dry breakup, scatter, or a second
  grain;
- impose quantitative floors for changed-pixel count, mean alpha, width, and
  tonal range;
- use scatter to create material character only after a continuous base mark
  is proven;
- maintain a separate charcoal block/side preset later instead of forcing one
  definition to cover every charcoal behavior.

### 10.5 Chisel Marker

Design target:

- stable broad and narrow axes;
- smooth direction-following turns;
- controlled translucent overlap;
- no spikes, holes, or radial stamp fans at corners;
- cursor shows the current rotated chisel outline.

Implementation options, in priority order:

1. retain stamps but filter tangent angle, interpolate the shortest angular
   difference, and emit intermediate fan dabs at an angle-derived step;
2. construct a continuous swept chisel ribbon with explicit joins and caps for
   the marker family;
3. provide fixed-angle and direction-following modes as separate presets.

The initial correction should use option 1 because it fits the stamp-first
engine and mirrors a proven concept in Krita's Fan Corners behavior. If contour
tests and manual use still show turn artifacts, move the Chisel family to the
swept-ribbon backend rather than piling more scatter or spacing heuristics onto
the stamp chain.

## 11. Specialized Engine Boundary

Krita supports multiple paint engines rather than requiring one generalized
path to emulate every medium. Laya's existing narrow-hybrid decision remains
sound:

- deposition backend: ink, pencil, charcoal, marker, airbrush, glaze, erase;
- interaction backend: smudge, pickup, Wet Mix, carried paint;
- optional continuous geometry backend: bristle/ribbon tools if stamp
  deposition cannot produce acceptable joins or physical continuity.

All backends share normalized input, path stabilization, dynamics, logical
brush identity, symmetry projection semantics, resource management, live
surface ownership, commit, and telemetry. Backend selection is made once per
compiled brush/stroke, never dynamically per pixel.

Do not implement Wet Mix as increasingly complex alpha modulation in the dry
stamp shader. Stateful media must read destination paint and preserve ordered,
bounded carried state on dirty tiles.

## 12. Krita Findings And Laya Adaptation

### 12.1 Incremental dab production

Krita's pixel brush `paintAt` evaluates the next tip shape, opacity, flow, and
spacing and queues that dab. It does not rebuild every previous dab. Laya
should apply the same incremental invariant while using Metal instancing and
canonical projection rather than Krita's CPU paint devices.

Relevant Krita files:

- `plugins/paintops/defaultpaintops/brush/kis_brushop.cpp`;
- `plugins/paintops/defaultpaintops/brush/KisDabRenderingExecutor.cpp`;
- `plugins/paintops/defaultpaintops/brush/KisDabRenderingQueue.cpp`.

### 12.2 Concurrent preparation and ordered consumption

Krita schedules dab-rendering jobs concurrently, preserves sequence numbers,
and consumes only the completed prefix in order. Its update path estimates
work per dab and limits each update batch to avoid visible hiccups.

Laya should use:

- off-main-actor logical preparation;
- stable ordinal ordering;
- asynchronous Metal command submission;
- bounded per-frame record rings;
- separate authoritative and prediction queues;
- no main-thread command-buffer wait.

### 12.3 Precision-aware cache reuse

Krita compares color, angle, size, subpixel position, softness, lightness,
ratio, brush index, and mirror properties at selectable precision. A matching
dab can reuse or postprocess a cached result.

Laya should prefer affine sampling of shared GPU tip resources first, then add
quantized mask caching only for expensive generated masks. Cache precision is
a compiled quality/performance policy and must not vary nondeterministically.

Relevant Krita file:

- `plugins/paintops/libpaintop/kis_dab_cache_base.cpp`.

### 12.4 Corner-angle interpolation

Krita's Fan Corners path computes the shortest angular difference between
successive direction-following tips and emits intermediate orientations. This
directly addresses Laya's Chisel failure.

Relevant Krita files:

- `libs/image/brushengine/kis_paintop_utils.h`;
- `plugins/paintops/libpaintop/KisRotationOption.cpp`.

### 12.5 Truthful cursor outline

Krita obtains the brush outline and transforms it using current brush
dynamics. Laya should similarly cache compiled tip support and evaluate its
current affine transform.

Relevant Krita file:

- `plugins/paintops/libpaintop/kis_brush_based_paintop_settings.cpp`.

### 12.6 Specialized media and functional benchmarks

Krita has distinct pixel, color-smudge, hairy/bristle, MyPaint, spray,
hatching, sketch, curve, and marker implementations. Its stroke benchmarks
exercise lines, circles, random lines, rectangles, and Bézier strokes with
real presets and can save rendered outputs.

Relevant Krita paths:

- `plugins/paintops/colorsmudge/`;
- `plugins/paintops/hairy/`;
- `plugins/paintops/mypaint/`;
- `benchmarks/kis_stroke_benchmark.cpp`.

### 12.7 Licensing boundary

The inspected Krita implementation is predominantly GPL-2.0-or-later/GPL.
Laya may study behavior and independently implement general architecture and
algorithms, but must not copy Krita code unless Laya deliberately adopts a
compatible licensing model. The corrective implementation should be written
clean-room from this report and Laya's requirements. Laya also needs an
explicit project license before distribution.

## 13. Performance Engineering Contract

### 13.1 Complexity invariants

For one new input batch:

- path and dynamics cost is proportional to new normalized samples;
- dab emission cost is proportional to newly traversed arc length divided by
  spacing;
- CPU projection cost does not depend on completed stroke length;
- dirty-region generation considers only new actual records and previous/new
  prediction bounds;
- authoritative deposition never clears or re-encodes completed live paint;
- memory used by active scheduling is bounded independently of stroke length;
- canonical history storage may grow by dirty region at commit, not per live
  frame.

### 13.2 Initial software thresholds

These are release gates for built-in dry brushes, subject to stricter measured
hardware profiles:

- CPU brush preparation p95 below 2 ms for the standard dry workload;
- no allocation, decode, file I/O, pipeline creation, or synchronous GPU wait
  after brush warmup on the input path;
- event-to-submit p95 below 4 ms for a claimed 120 Hz tier and below 8 ms for a
  claimed 60 Hz tier in the controlled software trace;
- missed event-to-submit budget fraction at or below 1% over a sustained trace;
- no monotonic authoritative backlog growth;
- authoritative backlog drains within one display interval after input stops
  for standard workloads;
- frame-time p95 remains within the target display interval on the qualifying
  physical profile;
- no single normal input event may create thousands of retained replay records;
- 10-second and 10-minute sustained traces remain stable in latency, queue
  depth, memory, and cache residency;
- declared maximum brush size and symmetry configurations have separate
  measured tiers and do not inherit the plain-canvas result.

Exact physical thresholds and baselines remain measured artifacts. A virtual
or paravirtual result cannot establish the hardware tier, but catastrophic
software misses on any environment still fail software acceptance.

### 13.3 Workload matrix

Every built-in brush runs:

- taps and rapid short strokes;
- slow and fast straight strokes;
- long curves and circles;
- repeated tight turns and 90-degree corners;
- direction reversal;
- low, neutral, and high pressure;
- tilt and azimuth sweeps where supported;
- 1 px, nominal, 40 px, large, and maximum supported sizes;
- mouse fallback;
- prediction on and off;
- plain, periodic, and radial projection;
- maximum supported symmetry multiplication;
- draw and footprint-matched erase;
- cold activation, warm activation, cache churn, and memory pressure;
- sustained drawing and thermal profiling on physical devices.

## 14. Functional And Perceptual Test Strategy

### 14.1 Pure engine tests

Continue testing deterministic input normalization, spacing, dynamics,
randomness, symmetry frames, cancellation, history, and compilation. Add:

- no historical dabs returned by incremental append;
- every actual ordinal deposited exactly once;
- prediction replacement never changes committed output;
- correction-window bounds and endpoint displacement;
- shortest-angle rotation interpolation;
- cursor footprint derivation from compiled tip support;
- cache quantization and deterministic cache decisions;
- scheduler backlog and overload state transitions.

### 14.2 Headless functional raster tests

Use versioned real drawing traces, not only two-point synthetic lines. Produce
rendered outputs and independent measurements for:

- alpha-support width percentiles;
- changed-pixel count and bounding box;
- mean, median, and percentile alpha within the intended footprint;
- endpoint distance from final input;
- pre-release/post-release pixel displacement;
- contour roughness and isolated protrusions at turns;
- gaps and scalloping along centerlines;
- tonal buildup after repeated passes;
- grain autocorrelation or scale-band energy as regression diagnostics;
- cursor outline versus controlled single-dab support;
- eraser footprint versus draw footprint.

These metrics reject gross failures. They do not replace human judgment of
texture and feel.

### 14.3 Independent oracles

Expected values must not be generated solely by the implementation under
test. Use a combination of:

- simple independent CPU coverage references;
- authored bounds and tonal targets;
- checked-in approved raster references;
- invariants across batching, prediction, zoom, symmetry order, and backend;
- manual comparison with reference applications and physical media.

### 14.4 Real app functional automation

Add macOS UI-driven traces that:

- launch the production app and production renderer;
- select each brush and exact size;
- send a multi-point drag at controlled cadence;
- exercise a curved Chisel turn rather than a straight synthetic drag;
- capture the HUD/log session and final canvas;
- fail on low FPS, excessive latency/backlog, missing visible output, cursor
  mismatch, endpoint retreat, or unusable controls;
- archive the trace, screenshot, rendered raster, and JSONL segment.

UI automation is not a substitute for Pencil or Wacom pressure hardware, but
it catches main-thread, frame-scheduler, editor-binding, and actual production
path regressions that offscreen unit tests miss.

### 14.5 Manual review

Each candidate brush must pass the Brush Lab matrix for:

- edge and join quality;
- taper and termination;
- texture cohesion at multiple zoom levels;
- pressure response;
- tilt and direction response;
- buildup and tonal range;
- seam and symmetry behavior;
- erase match;
- responsiveness and subjective smoothness;
- prolonged drawing comfort.

The reviewer records an explicit pass/fail value and notes. An unset card is
pending. Any required failed or pending card prevents product acceptance.

Manual review is deliberately clustered after every corrective implementation
stage and the complete automated performance round. It does not block starting
the next brush. A manual failure reopens the affected implementation and its
automated cluster; manual status is never inferred from automated metrics.

### 14.6 Clustered execution cadence

Focused red/green tests still accompany each behavior change. Heavier checks
run at four checkpoints so engineering remains fast without repeating the
previous false-positive completion:

1. after incremental scheduling: endpoint, prediction, complexity, backlog,
   and event-to-submit tests;
2. after dynamics/resources/backends: sizing, cursor, typed input, resource,
   color, memory, and UI-control tests;
3. after all four dry brushes: exhaustive visibility, footprint, texture,
   buildup, join, seam, symmetry, erase, negative-control, and nominal/large
   performance tests;
4. after integration: production-app, sustained-load, cache-churn,
   memory-pressure, build, and regression tests.

After the fourth checkpoint, run the entire performance matrix three times and
repair every software failure before requesting the one final manual round.

## 15. Evidence Gate Redesign

### 15.1 Status vocabulary

Use distinct states:

- `engineIntegrated`: code and automated correctness checks pass;
- `softwarePerformancePassed`: controlled software interaction thresholds pass;
- `manualQualityPassed`: required human review passes;
- `physicalProfilePassed`: qualifying device profile passes;
- `productAccepted`: all required states pass.

Do not summarize `engineIntegrated` as “professional brush complete.”

### 15.2 Hard failures

The gate fails when:

- any required output is below brush-specific visibility thresholds;
- cursor and mark footprint disagree beyond tolerance;
- endpoint retreat exceeds tolerance;
- turn-contour protrusions exceed the Chisel threshold;
- event-to-submit or frame-time thresholds fail;
- missed-frame fraction exceeds its limit;
- authoritative backlog grows or fails to drain;
- an input-path allocation, compilation, resource load, or GPU wait occurs;
- required manual cards are failed;
- a supplied hardware profile fails;
- any provenance, determinism, seam, symmetry, erase, or history invariant
  fails.

### 15.3 Pending states

- Missing iPad evidence remains pending while no device is available.
- Missing Wacom evidence remains pending while no tablet is available.
- Missing manual review is pending during development, but the brush stays out
  of the product professional catalog.
- Pending physical evidence cannot become a `realtime120` claim.

### 15.4 Artifact requirements

For each brush/workload pair, archive:

- exact brush definition and compiled semantic hash;
- input trace and input capabilities;
- logical dab summary;
- final canonical raster and display capture;
- cursor footprint trace where relevant;
- performance samples and derived percentiles;
- queue/backlog high-water and time series;
- CPU/GPU/resource/cache measurements;
- automated functional measurements;
- manual assessment identity and result;
- hardware, OS, toolchain, renderer, and source provenance.

## 16. Observability

The compact HUD should continue displaying:

- current/target FPS;
- frame p95;
- missed-frame percentage;
- CPU preparation and GPU duration;
- event-to-submit and GPU completion;
- actual/predicted queue depth and high-water;
- active brush, size, symmetry mode, and tier;
- logging state.

The JSONL log must additionally make a controlled test segment identifiable:

- session ID;
- stroke ID and ordinal;
- brush semantic hash;
- begin/end markers;
- actual and predicted input counts;
- new logical and projected dab counts per event;
- replay/correction counts, which should normally be zero for actual paint;
- per-phase timings;
- queue depth time series;
- command buffer submission and completion timestamps;
- dropped/coalesced input diagnostics;
- frame presentation timestamps when available.

Logs must be cheap enough not to create the performance failure being measured.
Sampling and buffered writes happen off the input path.

## 17. Implementation Sequence

### Phase 0: Correct project status

1. Mark the current four professional presets as experimental or remove them
   from the product-facing catalog.
2. Change the Stage 5 milestone from “software complete” to corrective work
   required.
3. Preserve current artifacts as failure characterization, not golden visual
   references.
4. Add this report to the governing-document precedence chain.

Exit: no project document or UI implies the current brushes are accepted.

### Phase 1: Freeze reproducible failures

1. Add the exact direct traces for Technical Ink, Graphite, Charcoal, and
   Chisel turns.
2. Capture current rasters, cursor bounds, latency, frame pacing, and backlog.
3. Add failing tests for endpoint retreat, invisible Charcoal, Graphite width,
   Chisel protrusions, and replay work.
4. Add the physical MacBook report as an unresolved hardware failure record.

Exit: the current implementation fails for the same user-visible reasons
reported here.

### Phase 2: Build incremental stroke scheduling

1. Introduce `StrokeRenderCoordinator` and actual/predicted work queues.
2. Route one compatibility brush through append-only actual deposition.
3. Add isolated prediction overlay replacement.
4. Derive dirty regions only from new records and replaced prediction bounds.
5. Remove ordinary actual-input calls to `rebuildReplayLayer`.
6. Move CPU preparation and command submission off the main actor.
7. Add bounded frame scheduling, telemetry, and overload failure semantics.
8. Prove preview/commit/cancel/history/symmetry invariants.

Exit: a long compatibility stroke has flat per-event work, no retained-body
replay, no growing backlog, and passes the 60 Hz software contract.

### Phase 3: Resource reuse and cursor truth

1. Complete private texture/mipmap activation for built-in product assets.
2. Add resource batching and measured mask/source reuse.
3. Add compiled tip support/outline metadata.
4. Render the evaluated footprint cursor.
5. Add cursor-versus-dab functional tests.

Exit: controlled single dabs agree with displayed cursor semantics and resource
work remains off the input path.

### Phase 4: Rebuild Technical Ink

1. Author the neutral ink nib and reference sheet.
2. Remove generic retroactive end taper.
3. Calibrate mouse, Pencil, and Wacom-neutral mappings separately where data is
   available.
4. Pass line, curve, endpoint, width, cursor, erase, symmetry, and performance
   gates.
5. Export the complete manual candidate card with status pending.

Exit: Technical Ink is an automated-gate-passing candidate, not yet admitted.

### Phase 5: Rebuild Graphite

1. Author contact and paper resources.
2. Establish a visible neutral mark before adding secondary variation.
3. Calibrate pressure buildup and tilt shading.
4. Pass footprint, tonal, texture, and performance gates; export pending manual
   cards.

Exit: Graphite is an automated-gate-passing candidate, not yet admitted.

### Phase 6: Rebuild Charcoal

1. Parse and convert the approved `C Charcoal` parent plus active `Sub01`
   through the typed bounded offline mapper.
2. Characterize `C Charcoal Soft` as a secondary target so tuning does not
   overfit one preset.
3. Admit Laya-owned tip and fine/coarse grain replacements, each reported as an
   approximation for an absent Procreate built-in.
4. Preserve independent component size, spacing, dynamics, resources, and
   deterministic randomness in the native composite dry-brush model.
5. Establish visibility and tonal floors before breakup/scatter.
6. Calibrate pressure, tilt, buildup, and edges.
7. Pass component-contribution, visibility, footprint, texture, and performance
   gates; export pending manual cards.

Exit: Charcoal is an automated-gate-passing candidate, not yet admitted.

### Phase 7: Rebuild Chisel Marker

1. Author a stable chisel tip.
2. Implement shortest-angle fan-corner interpolation and tangent filtering.
3. Add a swept-ribbon fallback experiment if stamp joins remain unacceptable.
4. Calibrate overlap and transparency.
5. Pass curve, corner, contour, cursor, buildup, and performance gates; export
   pending manual cards.

Exit: Chisel is an automated-gate-passing candidate, not yet admitted.

### Phase 8: Cross-family automated integration

1. Run the complete software matrix on macOS and iPad Simulator.
2. Run production-app automation and sustained software load.
3. Export the complete manual candidate cards without asking for review.

Exit: all implementation stages are green and manual remains pending.

### Phase 9: Full performance and final manual acceptance

1. Run the complete software performance matrix three times.
2. Repair every functional, visual-metric, latency, backlog, memory, cache, or
   production-control failure and repeat affected clusters.
3. Complete every required manual card in one final user review round.
4. Repair every manual failure and rerun relevant automated/performance gates.
5. Run controlled physical Mac/Wacom/iPad profiles when hardware is available;
   keep unavailable profiles pending.
6. Promote only passing brushes and evidence-backed tiers.

Exit: software performance and manual quality may be accepted for passing
brushes. Physical-profile and final product acceptance remain pending until
qualifying hardware evidence exists.

## 18. Suggested Code Ownership Changes

### PatternEngine

- retain normalized input, stabilization, spacing, dynamics, deterministic
  random values, and logical dabs;
- expose incremental generator state without historical replay arrays;
- add shortest-angle direction filtering/fan-corner helpers;
- define optional bounded correction-window policy;
- define effective tip-support metadata independent of Metal.

### EditorCore

- distinguish experimental, integrated, manually approved, and product
  accepted brush catalog entries;
- expose cursor intent and hover/default input policy;
- preserve brush capture at pointer-down;
- migrate IDs only after each replacement brush passes acceptance.

### MetalRenderer

- add `StrokeRenderCoordinator`;
- add actual and predicted frame queues;
- add incremental `DepositionEncoder` entry points;
- isolate prediction overlay clearing;
- move frame scheduling out of `GridRenderer`;
- add compiled tip outline/support and resource reuse telemetry;
- retain canonical projection, accumulation, and commit invariants;
- delete ordinary actual-stroke replay once parity and failure tests pass.

### Pattern App

- keep platform input extraction and batching only;
- render the evaluated cursor outline;
- add controllable production-path UI trace replay;
- keep HUD/logging compact and off the hot path;
- keep Brush Lab internal and require explicit assessments.

### Evidence tooling

- preserve strict schema/provenance validation;
- add functional raster metrics and real interaction budgets;
- separate engineering integration, manual quality, physical performance, and
  product acceptance statuses;
- fail visibly meaningless output and high missed-frame fractions.

## 19. Risks And Mitigations

### Risk: incremental deposition changes preview/commit pixels

Mitigation: render the same logical dab batches through old and new coverage
equations, compare canonical output, and permit differences only where the old
retroactive semantics are intentionally removed and independently approved.

### Risk: prediction seams become visible

Mitigation: use the identical shader/material path on separate surfaces,
replace only prediction dirty regions, and cross-fade only if measurement and
manual review prove it necessary. Never blend predicted pixels into commit.

### Risk: symmetry multiplication overwhelms a frame

Mitigation: instance logical dabs through transform tables, cull projected
fragments, batch by pipeline/resource, and classify heavy symmetry workloads
separately. Do not rerun dynamics per copy.

### Risk: mask caching consumes excessive memory

Mitigation: prefer source-texture affine sampling, keep caches byte-budgeted,
pin only active resources, record hit rate, and evict inactive variants.

### Risk: quantitative visual metrics reward the wrong look

Mitigation: metrics reject gross failures only. Checked-in approved references
and explicit human assessment remain mandatory.

### Risk: borrowing too closely from Krita

Mitigation: use this report as a clean-room requirements document, implement in
Swift/Metal from Laya abstractions, and do not copy GPL source.

### Risk: another broad stage hides brush-specific failures

Mitigation: admit each brush independently. A passing Technical Ink does not
mask a failing Charcoal, and no aggregate boolean can override a failed
brush/workload card.

## 20. Definition Of Done

The corrective work is complete only when all of the following are true:

- actual deposition is incremental and never replays the completed stroke body;
- prediction is isolated and replaceable;
- per-event work does not grow with stroke length;
- Technical Ink no longer retreats behind the released pointer;
- every brush cursor truthfully represents its effective footprint;
- Graphite visibly resembles calibrated graphite and supports useful buildup;
- Charcoal produces an immediately visible, expressive charcoal mark;
- Chisel curves and corners have no spike/fan artifacts;
- all four brushes feel responsive in the production app, not only in an
  offscreen harness;
- software interaction traces meet latency, missed-frame, backlog, and memory
  thresholds;
- physical profiles pass when the required hardware is available;
- all required manual quality cards explicitly pass;
- debug HUD and persisted logs agree with the gate artifacts;
- existing canonical raster, symmetry, erase, history, determinism, failure,
  and resource invariants remain intact;
- no Krita GPL implementation code has been copied;
- project documentation and editor status accurately reflect acceptance.

Until then, the correct project status is: brush foundation under corrective
development, professional dry brushes not yet accepted.

## 21. Evidence Index

### Current Laya implementation

- `Sources/MetalRenderer/GridRenderer.swift:2571` appends generated samples
  into the transient stroke system.
- `Sources/MetalRenderer/GridRenderer.swift:3024` rebuilds retained replay
  records and dirty regions.
- `Sources/PatternEngine/BrushDynamicsEngine.swift:543` applies retroactive
  taper after total distance becomes known.
- `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift:54` defines
  Technical Ink.
- `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift:142` selects
  its 1.5-diameter end taper and replay-tail policy.
- `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift:195` defines
  Graphite's coverage and dual grains.
- `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift:348` defines
  Charcoal's multiplied shapes and grains.
- `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift:498` defines
  Chisel's elongated tip and direct direction mapping.
- `Sources/MetalRenderer/Brush/BrushTextureFactory.swift:56` identifies the
  procedural resources as a validation pack.
- `App/PatternSpike/Canvas/InteractiveMetalView.swift:354` derives a nominal
  circular cursor without evaluated tip semantics.
- `Sources/ProfessionalBrushEvidenceValidation/PerformanceStatusValidator.swift:63`
  checks that missed-frame counts match but does not bound them.
- `scripts/verify-brush-stage5.sh:295` writes the software status and copies
  raw missed-frame counts into it.

### Generated Laya evidence reviewed

- `.build/professional-brush-artifacts/performance-status.json`;
- `.build/professional-brush-artifacts/positive/professional-technical-ink/professional-long-stroke.raw.json`;
- `.build/professional-brush-artifacts/positive/professional-graphite-pencil/professional-long-stroke.raw.json`;
- `.build/professional-brush-artifacts/positive/professional-natural-charcoal/evidence.json`;
- `.build/professional-brush-artifacts/positive/professional-chisel-marker/professional-long-stroke.raw.json`;
- `.build/professional-brush-artifacts/manual-cards/catalog.json`;
- `~/Library/Logs/Pattern/brush-performance-1785569379-9fdf2a6d-6fb0-4e4a-8a9e-9bf980325711.jsonl`.

Generated files are diagnostic products of the reviewed source tree and are
not checked-in source truth. A future gate rerun must bind equivalent evidence
to its exact source commit and renderer executable.

### Krita implementation reviewed

- `plugins/paintops/defaultpaintops/brush/kis_brushop.cpp`;
- `plugins/paintops/defaultpaintops/brush/KisDabRenderingExecutor.cpp`;
- `plugins/paintops/defaultpaintops/brush/KisDabRenderingQueue.cpp`;
- `plugins/paintops/libpaintop/kis_dab_cache_base.cpp`;
- `plugins/paintops/libpaintop/KisRotationOption.cpp`;
- `plugins/paintops/libpaintop/kis_brush_based_paintop_settings.cpp`;
- `libs/image/brushengine/kis_paintop_utils.h`;
- `libs/ui/tool/strokes/freehand_stroke.cpp`;
- `plugins/paintops/colorsmudge/`;
- `plugins/paintops/hairy/`;
- `plugins/paintops/mypaint/`;
- `benchmarks/kis_stroke_benchmark.cpp`;
- `COPYING` and per-file SPDX license identifiers.
