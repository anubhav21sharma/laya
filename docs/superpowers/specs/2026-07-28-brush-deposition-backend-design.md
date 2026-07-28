# Brush Deposition Backend Design

**Date:** 2026-07-28

**Status:** Approved interactively; written-spec review pending

**Primary target:** iPadOS 18+

**Secondary target:** macOS 14+ development and Wacom use

**Scope:** World-class brush-engine rollout Stage 4 only

## 1. Purpose

Stage 4 replaces Laya's compatibility-only stamp renderer with a native,
specialized deposition backend for ink, dry media, glaze, marker, airbrush,
and erase.

The new brushes are designed from scratch. Existing brush pixels are not a
quality target, the old renderer is not retained as a parity oracle, and old
images and traces remain non-gating historical evidence only. Manual Brush Lab
evaluation decides whether the new brushes look and feel good. Automated gates
continue to enforce determinism, seam correctness, lifecycle safety, bounded
work, failure containment, and measured performance.

This stage preserves the engine foundation already delivered:

- normalized Pencil, mouse, and tablet input;
- deterministic interpolation, dynamics, and logical-dab generation;
- full affine stamp and grain frames;
- compiled symmetry and half-open projection;
- native `.layabrush` packages;
- asynchronous brush compilation and resource residency;
- actual versus replaceable predicted stroke state;
- canonical raster history and transactional commit.

Stage 4 changes deposition, not the retained document model.

## 2. Decision Precedence And Intentional Deviations

When documents disagree, the following precedence applies:

1. Explicit user decisions recorded for this Stage 4 design.
2. This design.
3. `2026-07-26-world-class-brush-engine-design.md`.
4. Earlier approved product, symmetry, and stroke documents.
5. Existing implementation details that are not intentionally replaced.

This design intentionally changes the program-level Stage 4 outline in the
world-class brush-engine design:

- old/new rendered-pixel parity is not an acceptance gate;
- the legacy renderer is removed completely instead of retained as a frozen
  test oracle;
- existing brush visuals are not preserved;
- bounded wash is removed now because its current behavior is not a useful
  compatibility target;
- proper wet paint and smudge return only through the Stage 6
  canvas-interaction backend;
- manual evaluation, followed by explicit baseline approval, decides visual
  quality for the new brushes.

These decisions do not weaken raster, transaction, symmetry, prediction,
failure-safety, or performance invariants.

## 3. Goals

1. Render every supported dry brush from an immutable `CompiledBrush`.
2. Build fresh native ink, dry-media, glaze, marker, airbrush, and eraser
   anchors.
3. Render built-in and converted custom shape/grain resources through the same
   path.
4. Specialize shader work by accumulation, edge treatment, and texture
   features before a stroke begins.
5. Keep file I/O, decode, upload, pipeline creation, allocation growth, and
   synchronous GPU waits outside the input-to-pixel path.
6. Preserve evaluated tip, grain, scatter, direction, and reflection frames
   through periodic and finite-radial projection.
7. Apply stroke opacity once and keep preview, commit, and erase equations
   consistent.
8. Carry excess authoritative work across frames without changing the dab
   sequence.
9. Make all non-aesthetic behavior testable without interactive UI.
10. Produce fixed Brush Lab test cards and evidence for manual feel and visual
    acceptance.

## 4. Non-Goals

- Preserving old brush pixels.
- Keeping a runtime or test-only legacy renderer.
- Implementing bounded wash, smudge, pickup, or Wet Mix.
- Final professional preset calibration; that is Stage 5.
- A polished public Brush Studio.
- GPU-side path generation, dynamics, randomness, or symmetry evaluation.
- Sparse textures, Apple tile shaders, or virtual-texture residency.
- Changing canonical raster storage, history commands, tiling metadata, or
  finite-radial document semantics.
- Claiming hardware acceptance from virtualized or paravirtual Metal.

## 5. Load-Bearing Invariants

1. Canonical raster pixels remain the retained document source of truth.
2. Tiling and finite-radial symmetry remain document metadata.
3. Changing projection metadata never rewrites committed pixels.
4. World-space interpolation, dynamics, and random decisions happen once,
   before projection.
5. Every symmetry copy transforms the same evaluated logical dab, including
   tip direction, grain frames, scatter, and reflection handedness.
6. Symmetry never reruns spacing, dynamics, or random generation.
7. Actual samples alone determine committed pixels.
8. Predicted samples are replaceable and never advance authoritative state.
9. A stroke is discardable until its authoritative commit completes.
10. Pointer-up creates exactly one raster history command.
11. Pointer-cancel creates no history command.
12. Preview and commit use the same coverage and composition equations.
13. Erase uses the same coverage and dynamics as paint, deposits no color, and
    applies destination-out at composition.
14. Stroke opacity is applied exactly once at the live-surface composition
    boundary.
15. Completed stroke length does not increase per-frame live work.
16. Failed compilation, reservation, encoding, submission, or GPU completion
    preserves the last committed document revision.
17. No random or rendered behavior depends on wall-clock time, UUIDs,
    collection iteration order, or process hash randomization.

## 6. Architecture

### 6.1 Shared Front Half

`PatternEngine` remains platform-free and unchanged in ownership:

```text
normalized input
  -> stabilization and interpolation
  -> deterministic dynamics
  -> LogicalDabBatch
  -> document projection
```

`LogicalDab` remains the authoritative evaluated stamp. It already carries the
full brush-to-world frame, grain frames, color, opacity, flow, hardness,
material inputs, deterministic random values, and conservative bounds.

Stage 4 does not introduce a second path generator or family-specific spacing
logic.

### 6.2 Compiled Activation

Brush selection has two phases:

1. `BrushCompiler` validates the native definition, resolves and uploads
   resources, produces its `BrushPipelineKey`, and requests pipeline
   preparation.
2. The selection becomes active only when its resources and specialized
   deposition pipeline are both ready.

The previously active brush remains usable while replacement compilation is
pending or failed. No stroke waits for compilation.

`StrokeRenderStyle` remains portable and contains no Metal object.
MetalRenderer instead exposes an atomic compiled-brush activation operation.
The renderer stores the active `CompiledBrush` and its prepared pipeline
binding. At pointer-down it verifies that the style's definition identity and
semantic hash match the active compiled brush, then captures the whole
immutable compiled object in the active stroke.

The captured object keeps its textures alive even if the cache later evicts
other ownership references. Mid-stroke editor changes affect only the next
stroke. A style/compiled-brush mismatch fails before any transient mutation.

### 6.3 Deposition Components

Stage 4 adds focused MetalRenderer units:

#### `DepositionPipelineLibrary`

- owns `BrushPipelineKey -> MTLRenderPipelineState` caching;
- compiles function-constant variants before activation;
- includes render-target format and required ABI version in the effective
  key;
- never creates a pipeline during input processing or frame encoding;
- returns typed preparation and lookup failures.

#### `DepositionMaterialBinding`

- derives immutable stroke-wide uniforms from `CompiledBrush.uniformTemplate`;
- resolves stable texture slots from `CompiledBrush.textures`;
- contains no compatibility-recipe logic;
- records accumulation, edge, resource, and performance diagnostics.

#### `DepositionStampInstance`

- is the versioned CPU/Metal ABI for one projected stamp fragment;
- carries the projected affine tip frame;
- carries primary and secondary grain coordinate frames when enabled;
- carries clip planes and reflection flags;
- carries per-dab premultiplied color inputs, opacity, flow, hardness, and
  material contribution;
- carries stable logical/isometry ordinals for diagnostics;
- has exact size, alignment, offset, and round-trip tests in Swift and Metal.

#### `DepositionEncoder`

- preflights a complete frame batch;
- atomically reserves all required ring-buffer leases;
- packs instances without heap growth;
- binds one pipeline and one immutable resource set for the batch;
- encodes only the supplied projected instances;
- publishes no partial upload state when preflight or encoding fails;
- reports encoded instances, buffer usage, texture levels, and timing.

#### `FrameScheduler`

- separates authoritative and predicted queues;
- consumes work using the active device/profile frame budget;
- gives authoritative work priority;
- carries excess authoritative work without removing or altering dabs;
- may shorten or omit predicted work under pressure;
- drains authoritative work before pointer-up commit;
- exposes backlog depth, oldest-work age, missed frames, and budget overruns.

### 6.4 `GridRenderer` Boundary

During Stage 4, `GridRenderer` remains the facade that owns:

- stroke lifecycle;
- projection configuration;
- actual/predicted replay ownership;
- live surfaces;
- canonical commit;
- raster revisions and history;
- command completion and rollback.

It delegates all brush-specific resource binding, pipeline selection, instance
packing, and stamp encoding to the deposition components. It does not retain a
generic legacy deposition route.

This is an intentional incremental decomposition. Stage 4 does not rewrite the
document renderer or duplicate projection and history logic.

## 7. Coverage Model

The deposition shader evaluates coverage in this order:

1. Transform canonical sample position into the projected tip frame.
2. Evaluate the primary shape.
3. Evaluate the optional secondary shape using its declared combination mode.
4. Apply hardness, threshold, and antialiasing.
5. Evaluate primary and optional secondary grain in their transformed frames.
6. Apply grain strengths and declared coordinate policies.
7. Apply the selected edge treatment.
8. Multiply by evaluated per-dab opacity, material contribution, and the
   accumulation mode's flow rule.

The coverage implementation supports:

- one or two shape layers;
- zero, one, or two grain layers;
- analytic and asset-backed sources;
- aspect, rotation, offset, scatter, and full affine deformation;
- stroke-, moving-, and texture-oriented grain frames already represented by
  the logical dab;
- reflected directional features;
- derivative-based mip selection;
- device working textures prepared by the compiler.

Required asset failure prevents activation. Optional fallback is permitted
only when the native definition explicitly declares it and the compiler report
records it. The shader never guesses a missing resource.

## 8. Accumulation And Edge Semantics

Let:

- `shape` be antialiased shape coverage in `[0, 1]`;
- `grain` be combined grain coverage in `[0, 1]`;
- `opacity` be evaluated per-dab opacity;
- `flow` be evaluated per-dab flow;
- `strength` be the material strength;
- `base = clamp(shape * grain * opacity * strength, 0, 1)`;
- `flowCoverage = clamp(base * flow, 0, 1)`.

The CPU reference and Metal implementation use the same declared semantics:

### `.opaque`

Uses `base`, without flow attenuation, and source-over alpha union. It is for
solid stamps that should reach their evaluated coverage immediately.

### `.flow`

Uses `flowCoverage` and source-over alpha union:

```text
nextAlpha = currentAlpha + (1 - currentAlpha) * flowCoverage
```

Repeated dabs build continuously. Ink, dry media, and airbrush use this mode
with different coverage and edge definitions.

### `.uniformGlaze`

Uses the maximum stroke-local coverage rather than repeated alpha union:

```text
nextAlpha = max(currentAlpha, flowCoverage)
```

Repeated overlap inside one stroke does not darken the body. Stroke opacity is
still applied once when the live layer is composed.

### `.intenseGlaze`

Uses source-over alpha union with this fixed optical-density response:

```text
intenseCoverage = 1 - (1 - flowCoverage) * (1 - flowCoverage)
nextAlpha = currentAlpha + (1 - currentAlpha) * intenseCoverage
```

It builds more strongly than `.flow` without introducing a hidden setting or
schema field, and remains bounded by `accumulationLimit`.

### `.destinationOut`

Accumulates erase coverage with the selected brush's ordinary coverage and
flow rules. Composition applies:

```text
destinationAlpha *= 1 - eraseCoverage * strokeOpacity
destinationPremultipliedRGB *= 1 - eraseCoverage * strokeOpacity
```

Brush color is neither read nor deposited.

### Edge treatments

- `.none`: no additional coverage modulation.
- `.dryBreakup`: deterministic grain/edge breakup using the compiled grain
  sample and edge distance; no wall-clock or per-pixel random source.
- `.markerOverlap`: preserves a uniform translucent body while allowing
  declared overlap/edge density to remain visible within the accumulation
  limit.
- `.wetConcentration`: rejected by Stage 4 compilation.

Every non-`.none` `BrushInteractionMode` is rejected by Stage 4 activation.

## 9. Native Brush Families

Families are built-in `BrushDefinition` presets, not another renderer enum.

| Family | Native composition |
| --- | --- |
| Ink | `.flow + .none`, hard or textured tip |
| Dry media | `.flow + .dryBreakup`, textured shape/grain |
| Glaze | `.uniformGlaze` or `.intenseGlaze`, optional grain |
| Marker | glaze or flow accumulation plus `.markerOverlap` |
| Airbrush | `.flow + .none`, soft analytic or textured tip, low flow |
| Eraser | `.destinationOut` with any supported dry coverage |

The first Stage 4 catalog contains one diagnostic anchor for each family.
Stage 5 may add or retune professional variants without changing deposition
architecture.

Converted native packages use the same combinations. A converter report does
not make unsupported wet or interaction behavior activatable.

## 10. Symmetry And Projection

Projection transforms the evaluated frames, not the brush definition:

- tip axes and direction rotate with rotational copies;
- reflected copies preserve the mathematically reflected handedness;
- primary and secondary grain frames receive the same document isometry;
- scatter and offset have already been evaluated once;
- logical spacing and random outputs remain shared across copies;
- periodic fragments retain seam-continuous texture coordinates;
- finite-radial transform enumeration order cannot affect output.

The new instance ABI must not reduce a grain frame to the legacy scalar scale,
rotation, and offset payload. Full transformed frames reach the shader.

## 11. Frame Scheduling And Bounded Work

`FrameScheduler` follows the drawable's supported refresh rate and a
`BrushDeviceProfile`; it does not assume 60 Hz.

Each profile supplies:

- CPU preparation budget;
- maximum authoritative instances per frame;
- maximum predicted instances per frame;
- maximum pending authoritative instances;
- maximum pending predicted instances;
- in-flight upload-buffer count.

Reference values are measured and checked in with device evidence. They are
not inferred from model names or virtualized timing.

Scheduling rules:

1. Actual input advances the authoritative generator immediately.
2. Generated authoritative batches enter an ordered queue.
3. Predicted work enters a separate replaceable queue.
4. Each frame consumes authoritative work up to the active budget.
5. Remaining budget may encode prediction.
6. Prediction replacement clears and rebuilds only predicted work.
7. Settled uploads leave CPU queues and remain represented by live textures.
8. Pointer-up marks commit requested and returns without blocking the main
   actor. Later scheduled frames drain the authoritative queue; completion
   handlers begin the single commit only after all authoritative uploads
   succeed.
9. Queue-capacity exhaustion fails and discards the stroke explicitly.

The scheduler never changes spacing, skips authoritative dabs, removes
dynamics, reruns randomness, or reduces symmetry count.

## 12. Stroke Lifecycle

### Begin

- validate idle state and captured editor transaction;
- require a fully prepared deposition `CompiledBrush`;
- capture compiled brush, seed, color, size, tool, and projection;
- reserve or validate fixed-capacity stroke state;
- generate and queue the initial authoritative batch;
- create no canonical or history mutation.

### Append

- normalize and derive actual/coalesced/estimated input;
- update authoritative generator transactionally;
- queue ordered logical batches and projected instances;
- replace prediction from the last authoritative checkpoint;
- encode scheduled work into settled/replay live surfaces.

### Finish

- finish authoritative generation;
- discard predicted work;
- drain authoritative queued and in-flight work;
- prepare before/after raster revisions;
- composite live coverage into canonical scratch using the same equation as
  preview;
- publish one canonical revision and one history command only after GPU
  completion succeeds.

### Cancel Or Failure

- discard queued work and captured brush ownership;
- invalidate pending completion tokens;
- clear transient settled/replay surfaces;
- discard uncommitted raster revisions;
- leave canonical pixels and history unchanged.

## 13. Failure Containment

The following are explicit, testable failure stages:

- unsupported definition or interaction;
- missing required compiled resource;
- pipeline preparation or lookup failure;
- active-resource residency failure;
- projected-instance limit or queue overflow;
- upload-buffer reservation failure;
- render encoder or command buffer unavailability;
- command buffer completion failure;
- revision allocation or commit failure.

Preflight failures occur before live-state mutation. Mid-stroke and GPU
completion failures terminate the transient stroke and preserve the last
committed revision.

Telemetry includes definition hash, backend, pipeline key, ABI version,
resident bytes, instance counts, device profile, and failure stage. It does
not include third-party texture contents.

## 14. Legacy And Bounded-Wash Removal

Stage 4 removes production dependencies on:

- `BrushMaterialState` compatibility-recipe initialization;
- `GridPipelineLibrary.stamp` as a generic brush path;
- legacy material-family wire branches;
- `BoundedWashSurface` and bounded-wash encode/resolve state;
- bounded-wash catalog and UI entries;
- rendered old/new parity harnesses or frozen legacy renderer code.

`BrushRecipe` and `LegacyBrushRecipeAdapter` remain only where required to
decode or characterize historical schema fixtures. The production renderer
does not read `compatibilityRecipe`.

Because documents retain raster pixels rather than editable strokes, removing
bounded wash does not alter saved artwork. A stale selected bounded-wash
identifier resolves to the default ink anchor with an explicit diagnostic.

Native packages containing wet concentration or interaction settings remain
loadable and inspectable. Activation returns a typed unsupported-capability
failure until Stage 6.

Obsolete bounded-wash scenes and baselines are moved to historical evidence
rather than rewritten to pass. Active foundation and Stage 3 gates retain
every non-obsolete raster, transaction, symmetry, parser, package, resource,
and failure invariant. Stage 3's wet activation check changes only from
"compatibility bounded wash" to the explicit Stage 4 unsupported-capability
result.

## 15. Automated Verification

### 15.1 Pure Reference Tests

Pure tests cover:

- all coverage-layer combinations and validation limits;
- analytic and texture coordinate transforms;
- hardness, threshold, antialiasing, and grain modulation;
- every Stage 4 accumulation equation;
- dry and marker edge treatments;
- destination-out color independence;
- stable pipeline keys and function constants;
- frame scheduling, prioritization, drain, and bounded overflow;
- failure-state transitions.

The CPU reference is defined for the new deposition equations only. It is not
an old-renderer oracle.

### 15.2 ABI And Differential Tests

- Swift and C/Metal layouts match size, alignment, and every field offset.
- Packed instances round-trip through a diagnostic kernel.
- CPU reference coverage agrees with offscreen Metal within a declared
  channel tolerance.
- A negative-control shader or forged ABI field proves the differential gate
  fails.

### 15.3 Metamorphic Tests

For identical authoritative input:

- prediction on versus off produces identical committed pixels;
- different `LogicalDabBatch` partitions produce identical pixels;
- symmetry-transform enumeration order produces identical pixels;
- tiling-period input translation preserves folded canonical pixels;
- display zoom does not alter canonical output;
- brush color does not affect erase output;
- reflection correctly changes directional handedness;
- canceled and failed strokes produce no canonical or history mutation.

### 15.4 Offscreen Metal Matrix

The Stage 4 harness records positive and negative-control scenes for:

- every native family;
- built-in and custom asymmetric shape/grain resources;
- no/one/two shapes and no/one/two grains;
- minimum, default, and maximum supported stamp sizes;
- mip transitions;
- low spacing, high scatter, and fast direction changes;
- every periodic symmetry family;
- finite-radial rotation and reflection;
- draw and erase;
- prediction replacement;
- preview/commit equality;
- cache eviction and active-resource pinning;
- pipeline, buffer, encoder, allocation, and command completion failure.

Historical images are never used as Stage 4 pass criteria.

## 16. Performance Contract

Stroke-time static and runtime audits require zero:

- package or image decode;
- texture preparation or upload;
- pipeline compilation;
- unbounded buffer growth;
- file I/O;
- synchronous GPU wait;
- collection-order-dependent pipeline or resource lookup.

Software smoke budgets retain:

- standard dry CPU preparation p95 below 2 ms;
- established exact 500-dab GPU workload below 3 ms on stable supported Metal
  hardware;
- bounded live work independent of completed stroke length.

The harness records p50, p95, p99, maximum backlog, event-to-submit,
CPU preparation, GPU completion, missed-frame fraction, buffer high-water, and
resource high-water.

Hardware acceptance separately verifies:

- `realtime120` on a reference M-series ProMotion iPad;
- at least 60 Hz on the A14-class floor;
- Pencil and Wacom input behavior;
- memory warning recovery;
- suspend/resume;
- sustained drawing and thermal behavior;
- true input-to-photon latency where instrumented.

Paravirtual Metal may prove correctness and produce measurements, but cannot
close stable-device performance gates.

## 17. Brush Lab Manual Acceptance

Brush Lab exposes a fixed card for each anchor brush:

- tap, slow line, fast line, curve, zig-zag, and direction reversal;
- minimum, default, and maximum size;
- low, medium, and high pressure;
- tilt/azimuth/roll inputs when the device provides them;
- plain, periodic, reflected, and finite-radial projection;
- opaque background, transparent background, and colored paint;
- custom asymmetric shape and grain;
- prediction enabled and disabled;
- live CPU/GPU, backlog, residency, and cache diagnostics.

Manual review judges:

- responsiveness and continuity;
- pressure and tilt feel;
- edge quality;
- texture cohesion;
- overlap and buildup character;
- directional behavior under symmetry;
- eraser footprint match;
- visible hitching or frame backlog.

New rendered baselines become gating only after explicit user approval.
Baseline approval freezes regression output; it does not claim that future
Stage 5 tuning is complete.

## 18. Stage 4 Completion Boundary

Stage 4 is complete only when:

1. all six native anchors render through `DepositionEncoder`;
2. built-in and converted custom textures reach the shader through compiled
   resources;
3. pipeline variants are prepared before activation and cached by stable key;
4. full affine tip and grain frames survive every projection;
5. actual/predicted scheduling remains deterministic and bounded;
6. draw, erase, preview, commit, cancel, and failure invariants pass;
7. old generic deposition and bounded-wash production code are removed;
8. automated pure, ABI, metamorphic, offscreen, failure, build, analysis, and
   evidence gates pass;
9. hardware-only gates are either passed on recorded devices or remain
   explicitly pending;
10. Brush Lab manual cards and reproducible evidence bundles are ready for
    user assessment.

Stage 5 begins only after this engine boundary is accepted. Stage 6 later
introduces canvas interaction and wet media from scratch.
