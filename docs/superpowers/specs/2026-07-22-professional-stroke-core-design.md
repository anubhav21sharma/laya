# Professional Stroke Core Design

**Date:** 2026-07-22
**Status:** Approved
**Slice:** 4

## 1. Purpose

Slice 4 replaces the fixed hard-round stroke generator with a professional,
deterministic stroke core while preserving the raster document, generalized
tiling projection, transaction lifecycle, region history, and commit seam
already proven in Slices 1-3.

The slice adds:

- BrushInput V2 with normalized pressure, stylus orientation, provenance, and
  derived world-space velocity;
- pressure-carrying Catmull-Rom interpolation and recipe-controlled spacing;
- one pure `BrushDynamicsEngine` for per-dab attributes;
- versioned brush recipes and deterministic seeded randomness;
- fixed-cost stabilization, start taper, end taper, and bounded replay;
- shape and grain assets with deterministic fallbacks and mipmaps;
- dry, ink, glaze, and bounded-wash material families;
- four internal anchor recipes needed to verify the engine;
- GPU and pure verification for spacing, opacity, materials, replay, and every
  supported tiling.

The product bar for this slice is not the number of exposed controls. It is
that the same input trace always generates the same expressive stroke, active
pixels match committed pixels, long strokes remain bounded, and every shipped
brush mode remains correct across tile seams.

## 2. Governing Decisions And Reconciliation

`2026-07-18-pattern-product-rebuild-design.md` governs this slice. Current
source and passing tests are the as-built baseline. Recovered brush documents
are historical input only where they agree with that approved rebuild.

Slice 3 and earlier manual/performance evidence may remain pending. The user
explicitly authorized later slices to proceed without treating unavailable or
unstable performance measurements as implementation blockers. Existing
functional and regression gates remain mandatory; no pending gate is silently
marked accepted.

The following recovered decisions remain valid:

- committed documents remain emit-and-forget raster pixels;
- transient samples and dabs live only for the active stroke;
- pressure is interpolated per emitted dab rather than quantized per event;
- flow is per-dab accumulation while stroke opacity is applied once to the
  premultiplied live layer;
- one shape and one grain are bound per stroke;
- material uniforms remain per stroke unless a value truly varies per dab;
- shape, grain, dynamics, replay, and material behavior are independently
  testable;
- full fluid simulation, smudge/pickup, retained strokes, layers, selection,
  persistence, and cloud brush distribution are outside this slice.

The following recovered assumptions are superseded or corrected:

| Recovered assumption | Slice 4 ruling |
| --- | --- |
| A prior dual-texture brush engine, preset library, editor, and provisional channel already exist. | The rebuild currently has one hard-round brush, no brush assets or recipes, and one persistent live tile. Slice 4 builds from that real baseline. |
| Build Brush Library and Brush Studio before the engine. | Library, Studio, preview rendering, editable response curves, and the final preset pack belong to Slice 5. |
| `StrokeSample` contains only position and pressure. | It already contains position, pressure, timestamp, lifecycle phase, and source. V2 extends it additively. |
| Renderer `LiveStroke` is the transient brush model. | It is currently an append-only projected-instance upload queue. The engine replay model is named `TransientStrokeBuffer`; the renderer type keeps its scheduling role. |
| Moving grain may ship with a known seam limitation. | The governing seam guarantee does not permit that exception. Any enabled grain mode must pass fragment-continuity and tiling scenes before an anchor uses it. |
| The final 12-16 preset library is part of the professional-engine pass. | Slice 4 ships four verification anchors. Product calibration and the final library remain Slice 5. |
| iPad Pencil feel can close the slice immediately. | iPad remains continuously buildable. Hardware-only Pencil, prediction, latency, and 120 Hz gates stay pending until hardware is available. |

## 3. Goals And Non-Goals

### 3.1 Goals

1. Preserve exact legacy hard-round placement before enabling new recipes.
2. Make input normalization and brush generation pure and deterministic.
3. Carry pressure and other interpolable properties to every emitted dab.
4. Let recipes control size, spacing, flow, opacity, rotation, scatter,
   hardness, grain, stabilization, taper, and material parameters.
5. Keep per-event CPU work and per-frame GPU work bounded independently of
   completed stroke length.
6. Preserve preview/commit equality for draw and erase.
7. Preserve generalized tiling for rotated, scattered, non-round, and grained
   stamps.
8. Make replay correct in the presence of in-flight GPU submissions without
   blocking the main actor.
9. Provide enough minimal anchor-selection UI and harness coverage to compare
   four materially distinct anchor brushes.

### 3.2 Non-Goals

- Brush Library, Brush Studio, generated preview thumbnails, custom recipe
  editing, import/export, or user asset import.
- The final 12-16 calibrated preset pack.
- General editable response-curve UI. Slice 4 may use bounded power responses;
  editable multi-point curves arrive in Slice 5.
- Layers or per-layer brush routing.
- Selection, transform, persistence, export, or autosave.
- Retained/vector strokes or re-folding old strokes after a tiling change.
- Full fluid dynamics, pigment pickup, smudge, or unbounded wet simulation.
- iPad hardware acceptance without an actual device.

## 4. Product Invariants

1. Canonical raster pixels remain the retained document source of truth.
2. A successful pointer-up creates exactly one raster history command.
3. Pointer-cancel clears every transient brush surface and creates no command.
4. A recipe, color, diameter, eraser strength, material, and random seed are
   captured at pointer-down and remain stroke-constant.
5. World-space interpolation and dynamics evaluation occur before tiling
   projection.
6. Identical normalized actual samples, recipe, diameter, color, and seed
   produce byte-identical generated dab attributes on the same supported
   numeric architecture.
7. Random generation never uses `SystemRandomNumberGenerator`, Swift
   `Hasher`, wall-clock time, UUID hashing, or collection iteration order.
8. Predicted samples never mutate the actual sample interpolator, spacing
   carry, deterministic random cursor, history, or canonical pixels.
9. Pressure, spacing, taper, scatter, and rotation change generated dabs, not
   the document storage model.
10. Preview and commit use one shared compositing equation and stroke-opacity
    value.
11. Pointer-up changes no visible color, opacity, coverage, or grain by more
    than one 8-bit value.
12. Eraser output is destination-out and never inherits draw material color or
    a synthetic mouse-pressure value as strength.
13. Shape and grain coordinates remain continuous across all projected
    fragments of one dab.
14. Every material enabled by an anchor passes the seam oracle for all seven
    tilings before it is considered shipped.
15. Main-actor input handling performs no `await`, file I/O, image decode,
    shader compilation, blocking wait, or unbounded allocation.
16. Replay storage and wash working state have explicit hard caps and a
    deterministic degradation policy.
17. Failed generation, projection, allocation, or GPU work preserves the last
    committed canonical revision.
18. Existing Slice 0-3 scenes and pure tests remain green.
19. Replay never exposes a cleared or partially rebuilt tail texture.

## 5. Current Baseline

The implementation starts from these concrete facts:

- `StrokeSample` carries screen position, `Float` pressure,
  `TimeInterval` timestamp, began/moved/ended/cancelled phase, and
  mouse/tablet/Pencil source.
- macOS currently emits one mouse sample per native event at neutral pressure
  `0.5`; iPad displays an `MTKView` but has no drawing adapter.
- `CentripetalCatmullRomStrokeInterpolator` stores positions only and uses
  fixed spacing `max(1, min(8, radius * 0.25))`.
- `GridRenderer` converts screen to world, runs interpolation, projects a
  circular footprint, and appends 112-byte projected instances.
- `PatternProjectedStampInstance` already carries a full canonical affine,
  radius, color, and four clip planes.
- rotation and scatter can be represented by the existing affine and do not
  need separate GPU fields.
- the hard-round shader stamps straight color into a premultiplied
  `.bgra8Unorm` persistent live tile.
- the display and commit passes share draw/erase composite math, but there is
  no separate stroke-opacity ceiling.
- renderer `LiveStroke` retains only pending projected instances, monotonic
  high-water marks, and bounded dirty-region metadata.
- `EditorTransaction` already captures style at pointer-down, cancels on tool
  or configuration interruption, and waits for asynchronous commit success
  before history finalization.

Slice 4 extends these seams. It does not replace the transaction reducer,
history owner, projection oracle, or canonical commit model.

## 6. Architecture And Ownership

### 6.1 PatternEngine

PatternEngine owns all platform-free brush values and generation:

- normalized and world-space stroke sample values;
- input validation and derived velocity;
- deterministic stabilizer;
- attributed Catmull-Rom path interpolation;
- dynamic spacing and dab emission;
- `BrushRecipe`, mappings, taper, and material descriptions;
- `BrushDynamicsEngine`;
- deterministic random stream and stroke seed;
- `TransientStrokeBuffer` and replay decisions;
- generated `DabAttributes` and transformed `StampFootprint` values.

It imports no AppKit, UIKit, SwiftUI, Metal, or MetalKit.

### 6.2 EditorCore

EditorCore owns:

- active anchor recipe identity;
- semantic recipe-selection intent;
- recipe-selection enable state;
- stroke configuration captured into transaction effects.

It does not interpret native pressure events, load Metal textures, generate
dabs, or own transient replay.

### 6.3 MetalRenderer

MetalRenderer owns:

- shape and grain texture creation/resolution and deterministic fallbacks;
- mipmap creation;
- material pipelines and shared C/MSL layouts;
- projected instance upload and dirty regions;
- persistent settled-live, replay-tail, and bounded wash working textures;
- replay clear/restamp epochs;
- live display and canonical commit;
- GPU timing and offscreen evidence.

It does not own recipe selection, input policy, history order, or random seed
creation.

### 6.4 Pattern App

The app layer owns:

- native event extraction and batching;
- screen/drawable coordinate conversion at the platform boundary;
- the existing session controller and reducer execution;
- a minimal anchor-recipe picker;
- the existing nominal-diameter cursor.

Platform adapters may inspect native events but contain no interpolation,
dynamics, tiling, material, or commit policy.

## 7. BrushInput V2

### 7.1 Sample Model

The existing lifecycle `StrokePhase` remains began/moved/ended/cancelled.
Sample provenance is a separate value so prediction never masquerades as a
lifecycle state.

Conceptual public values:

```swift
public enum StrokeSampleKind: UInt8, Sendable {
    case actual
    case coalesced
    case predicted
    case estimatedUpdate
}

public struct StrokeSample: Equatable, Sendable {
    public let position: ScreenPoint
    public let pressure: Float
    public let timestamp: TimeInterval
    public let altitude: Float?
    public let azimuth: Float?
    public let roll: Float?
    public let phase: StrokePhase
    public let source: StrokeSource
    public let kind: StrokeSampleKind
    public let capabilities: StrokeInputCapabilities
}

public struct WorldStrokeSample: Equatable, Sendable {
    public let position: WorldPoint
    public let pressure: Float
    public let timestamp: TimeInterval
    public let altitude: Float?
    public let azimuth: Float?
    public let roll: Float?
    public let velocity: Float
    public let phase: StrokePhase
    public let source: StrokeSource
    public let kind: StrokeSampleKind
    public let capabilities: StrokeInputCapabilities
}
```

`Float` remains the numeric representation because the geometry and GPU path
are already `Float`; timestamp remains `TimeInterval`. The `Double` fields in
the governing architecture sketch are conceptual, not a wire requirement.

### 7.2 Normalization Rules

- Position and timestamp must be finite. Invalid samples are rejected before
  entering the transaction reducer.
- Measured pressure is clamped to `0...1`; capability records whether it is a
  real sensor value.
- Altitude is clamped to `0...pi/2` when present.
- Azimuth and roll normalize to `-pi...pi` when present.
- Nonfinite optional sensor values become `nil` and record one development
  diagnostic; they never poison the stroke.
- Timestamps may repeat. Velocity retains the last finite value when
  `deltaTime <= 0` and starts at zero.
- Velocity is derived after screen-to-world conversion so zoom does not change
  brush behavior. It is measured in canonical pixels per second and bounded
  by a named engine contract.
- A source without measured pressure retains the raw neutral sample for
  compatibility, but dynamics uses the recipe's no-pressure neutral. Anchor
  recipes use `1.0`, so the visible nominal brush diameter matches mouse
  output. Eraser strength remains its own captured setting.

### 7.3 Batches And Prediction

The controller accepts ordered sample batches. Actual/coalesced samples are
chronological and advance the authoritative stroke generator. Predicted
samples are evaluated from a copied generator state and rendered only through
a replayable preview epoch. The next actual batch discards the predicted
suffix before advancing.

macOS adopts V2 actual mouse and available tablet fields in this slice. iPad
adapter types and build-safe extraction may be added, but no Pencil behavior
is declared accepted without hardware. A single-sample wrapper remains for
existing tests and callers during migration.

## 8. Interpolation, Stabilization, And Spacing

### 8.1 Attributed Path

The current portable centripetal Catmull-Rom arithmetic remains the geometric
baseline. The implementation separates two responsibilities:

1. `CentripetalCatmullRomPathInterpolator` converts stabilized world samples
   into deterministic short attributed path segments.
2. `BrushStrokeGenerator` walks those segments, owns distance carry, asks
   `BrushDynamicsEngine` for the next dab, and uses that dab's spacing for the
   following emission.

This separation avoids a circular design where an interpolator must know a
recipe before dynamics has evaluated spacing.

For a legacy-equivalent recipe with constant pressure:

- the same begin point is emitted;
- straight-line points and the exact final endpoint remain identical;
- the recovered spacing formula remains identical;
- spacing carry crosses native event boundaries exactly as before.

Pressure, timestamp, velocity, altitude, azimuth, and roll travel with each
path point. Pressure, timestamp, and velocity interpolate by the same local arc
fraction used for position. Angles use shortest-arc interpolation when both
endpoints contain a value. A missing optional sensor value remains missing
until a real sample provides it; the engine does not manufacture tilt or roll.

### 8.2 Dynamic Spacing

Recipes express base spacing as a fraction of nominal diameter. Dynamics
returns a finite world-pixel spacing for each emitted dab. Engine policy clamps
it to:

```text
1 px ... min(8 px, current diameter * recipe maximum spacing fraction)
```

The legacy-equivalent recipe resolves to the current
`max(1, min(8, radius * 0.25))` result. A zero, negative, NaN, or infinite
mapping result is a programmer error in a built-in recipe and a validation
failure for future user recipes.

Spacing randomness changes the distance selected after a dab; it never moves
the current dab backward, emits two identities at one distance by accident,
or resets carry at an input-event boundary.

### 8.3 Stabilization

Slice 4 provides one deterministic bounded stabilizer with strength `0..<1`:

- zero is bit-for-bit identity;
- it operates before interpolation;
- it carries every sample attribute without reordering lifecycle events;
- it introduces no timer, async task, or unbounded lookahead;
- predicted samples use copied stabilizer state;
- cancel drops all carry.

Multiple named stabilization modes and editable controls remain Slice 5.

## 9. Recipes, Dynamics, And Determinism

### 9.1 Brush Recipe

`BrushRecipe` is an immutable, validated, `Equatable`, `Sendable` PatternEngine
value. It contains:

- stable recipe identity and schema version;
- shape and grain descriptors;
- grain coordinate mode and base transform;
- material family and bounded material parameters;
- base spacing, flow, stroke opacity, hardness, scatter, and rotation policy;
- size, flow, spacing, rotation, scatter, hardness, and grain mappings;
- no-pressure neutral values;
- stabilization and taper configuration;
- replay mode and declared caps.

Recipe validation rejects nonfinite values, unsupported asset combinations,
out-of-range opacity/flow, an unbounded replay request, and a material whose
working-set declaration exceeds engine policy.

Slice 4 mappings support disabled, linear, and bounded power responses. The
type remains extensible, but editable multi-point response curves are not
enabled until Slice 5 supplies their product model and UI.

### 9.2 Brush Dynamics Engine

The only pure evaluator is:

```swift
public struct BrushDynamicsEngine: Sendable {
    public func evaluate(
        sample: InterpolatedStrokeSample,
        context: BrushStrokeContext,
        recipe: BrushRecipe,
        random: BrushRandomValues
    ) -> DabAttributes
}
```

Inputs available to mappings are:

- pressure or recipe-defined no-pressure neutral;
- world-space speed;
- tilt magnitude and azimuth when available;
- travel direction;
- roll when available;
- stroke age and traveled distance;
- deterministic random channels.

`DabAttributes` contains:

- world position and affine axes;
- radius/diameter and spacing;
- flow contribution and stroke-opacity contribution;
- rotation and scatter already applied to the footprint transform;
- hardness;
- grain offset and scale;
- color adjustment;
- bounded material contribution;
- source distance, ordinal, and whether the dab is predicted.

Projection consumes the resulting footprint and has no knowledge of recipe or
input source. The renderer consumes projected instances and material
bindings; it does not re-evaluate dynamics.

### 9.3 Deterministic Random Stream

Each actual stroke captures an explicit nonzero `UInt64` seed. Harness scenes
provide it directly. The app derives it from a main-actor monotonic stroke
sequence mixed with document-session entropy captured outside the hot path.

The engine uses a specified SplitMix64 stream. One emitted dab consumes one
fixed-width random block with named channels for spacing, scatter X/Y,
rotation, grain X/Y, and material variation. Disabled mappings still reserve
their channel, so turning one mapping off does not shift unrelated random
sequences. Predicted evaluation copies the random cursor and cannot advance
the actual cursor.

Random `Float` values are formed from the upper 24 bits and scaled into
`[0, 1)`. Tests pin seed-to-word and seed-to-dab fixtures. Changing the
algorithm or channel order requires a recipe schema migration, not a silent
refactor.

## 10. Taper And Transient Replay

### 10.1 Taper

Recipes may define start and end taper lengths in world pixels or nominal
diameter multiples, minimum size, and minimum flow.

- start taper evaluates forward from stroke distance zero;
- end taper is resolved at pointer-up from distance to the actual endpoint;
- taper affects size and/or flow according to recipe flags;
- click strokes remain one finite visible dab unless the recipe explicitly
  defines zero click coverage;
- predicted endpoints may preview taper but never become authoritative.

End taper can change already displayed tail dabs, so it uses replay rather than
painting corrective dabs over old pixels.

### 10.2 Transient Stroke Buffer

`TransientStrokeBuffer` is a PatternEngine value distinct from renderer
`LiveStroke`. It retains:

- authoritative normalized/stabilized samples required by the selected replay
  mode;
- generated dab attributes for the replayable suffix;
- actual and predicted boundaries;
- deterministic generator snapshots;
- accumulated world/canonical dirty bounds;
- replay epoch and degradation state.

Modes are:

- `appendOnly`: no previously settled dab changes;
- `replayTail`: retain at most 256 samples, 2,048 generated dabs, and 4,096
  projected instances in its visible epoch;
- `boundedWholeStroke`: wet materials may retain at most 4,096 samples, 4,096
  generated dabs, and 4,096 projected instances in its visible epoch.

These are engine caps, not initial allocation sizes. Buffers reserve measured
working capacity and grow only at safe event boundaries up to the cap. When a
whole-stroke cap is reached, the oldest prefix is deterministically promoted
from the replay-tail texture into the settled-live texture and the mode
degrades to replay-tail. The stroke continues; it does not allocate without
limit or discard committed pixels. A development diagnostic and harness
metric record the degradation.

Previously settled coverage and replayable coverage never share one mutable
accumulation target. `PersistentLiveTile` remains the chronological settled
prefix. A new replay-tail texture contains the retained actual tail plus any
predicted suffix. Display and commit source-over replay-tail onto settled-live,
then apply stroke opacity once to that combined premultiplied result. Because
source-over is associative and chronological order is preserved, promoting
the oldest replay dabs into settled-live does not change visible output.

### 10.3 Renderer Replay Epochs

Replay cannot reuse the current renderer high-water identity blindly because
older command buffers may still complete. Every replay upload and completion
carries a stroke render epoch plus a monotonically increasing
projected-instance identity. Replaying performs, in command-queue order:

1. increment epoch;
2. project the complete replacement tail and preflight enough upload leases
   for both promotion and replacement; if they are unavailable, keep the prior
   replay texture visible and retry on a later frame;
3. promote any tail prefix that has left the replay window into settled-live;
4. clear the affected replay/wash region or the whole replay-tail texture when
   required, never the settled-live prefix;
5. enqueue the complete regenerated replay epoch in the same command buffer;
6. ignore obsolete completion bookkeeping from older epochs while still
   reclaiming its buffer leases;
7. display only the complete latest replay epoch over the settled prefix;
8. permit commit only when both settled and latest-replay uploads have reached
   their emitted high-water marks and no token-bearing frame remains pending.

The 4,096 projected-instance visible-epoch cap matches one current instance
buffer lease, so a replacement tail is never intentionally split across
visible frames. Promotion may use another preflighted lease. The cap is checked
after tiling projection because one generated dab may produce many fragments.
If projection exceeds it, the engine promotes the oldest safe prefix and
shortens the effective replay/taper window deterministically. The first
retained taper dab starts at full envelope strength, preventing a discontinuity
at the promotion boundary. A metric records every shortened replay window.

The main actor never waits for the GPU. Failure of a replay epoch terminates
the active transaction through the existing typed renderer failure path and
preserves canonical pixels.

## 11. Shape And Grain Assets

### 11.1 Asset Contract

Shape and grain coverage textures use `.r8Unorm` with mipmaps.

- shape is sampled in stable brush-local `[-1, 1]` coordinates;
- grain is sampled either in canonical/canvas coordinates or stable
  brush-local coordinates as declared by the recipe;
- one shape and one grain are resolved and bound per stroke;
- procedural hard round and opaque grain are mandatory deterministic
  fallbacks;
- missing optional assets produce one diagnostic per asset identity, not one
  per dab or frame;
- asset decode and mip generation happen before a stroke begins;
- unresolved assets never trigger synchronous file work in the hot path.

Slice 4 includes a small engine-validation pack only: hard/soft/tapered or
chisel tip coverage as required by anchors, plus paper/noise grain. Final art
asset selection and the full preset pack belong to Slice 5.

### 11.2 Coordinate Continuity

Rotation and scatter are baked into `StampFootprint.brushToWorld` before
projection. `CellFragment.canonicalFromBrush` therefore carries the full
transformed shape, including reflection and rotation.

Every shape declares its real coverage symmetry. Round and genuinely
half-turn-invariant shapes may use `.halfTurnInvariant`; chisel, tapered, or
otherwise directional shapes use `.oriented` so rotational projection never
deduplicates distinct coverage.

Canonical grain derives from canonical pixel position and repeats with the
stored tile. Brush-local grain derives from the uncut brush-local coordinate
already preserved across fragments. No anchor may enable a coordinate mode
until the CPU oracle and GPU scenes prove zero holes, zero phantom coverage,
and coordinate continuity for all tilings, including reflected and rotational
images.

## 12. GPU Data And Material Rendering

### 12.1 Shared ABI

The current 112-byte `PatternProjectedStampInstance` is not frozen. Slice 4
adds one aligned per-dab attribute vector:

```c
PatternFloat4 brushAttributes;
// x = hardness
// y = grain scale
// z = grain offset x
// w = grain offset y
```

Rotation, anisotropy, pressure size, and scatter remain encoded by the existing
canonical affine. Flow and color adjustment remain encoded by the existing
straight RGBA field. Material family and bounded material controls are
stroke-constant uniforms, not duplicated into every projected fragment.

For a circular footprint, the existing `radius` field retains its exact legacy
meaning. For an anisotropic footprint, the affine carries the real dimensions
and `radius` carries the minimum finite local-to-canonical scale used only for
conservative one-pixel vertex expansion and antialiasing. Dirty bounds use the
expanded transformed local bounds, not a circular-radius shortcut.

The expected projected-instance stride becomes 128 bytes. Exact size,
alignment, and offsets are guarded in C, Swift, MSL-facing tests, buffer byte
accounting, and harness metrics. If implementation measurement proves a
different packing necessary, this spec must be amended before changing the
semantic contract.

New texture and buffer indexes append to existing wire constants; no current
selector is renumbered.

### 12.2 Stroke Material Uniforms

One shared `PatternBrushMaterialUniforms` block contains at least:

- append-only material-family selector;
- grain coordinate selector;
- stroke opacity;
- material strength/wetness;
- bounded bleed radius and pass count;
- wash/glaze accumulation limits;
- padding required for exact CPU/MSL layout.

The same opacity and composite controls are bound to live display and commit.
Display and commit also bind the settled-live and replay-tail textures in the
same chronological order. Draw and erase keep separate semantic composite
modes.

### 12.3 Material Families

**Ink**

- shape coverage, hardness, flow, and optional grain;
- source-over accumulation into the live tile;
- suitable for crisp or soft opaque strokes;
- append-only unless taper or prediction requires tail replay.

**Dry**

- shape coverage multiplied by mipmapped grain/tooth;
- deterministic pressure/flow response;
- no hidden temporal simulation;
- canonical or brush-local grain only after seam proof.

**Glaze**

- translucent per-dab flow accumulates inside one live layer;
- stroke opacity scales premultiplied live RGB and alpha exactly once at
  display and commit;
- overlap may build at flow but cannot exceed the configured stroke-opacity
  ceiling when composited;
- pointer-up does not darken the stroke.

**Bounded wash**

- deposits coverage/pigment into fixed-format transient working textures;
- applies a fixed, recipe-declared number of local bleed/soften passes over
  the newly dirty region plus a bounded halo;
- uses no fluid solver, velocity field, pickup, background task, or
  stroke-length-sized pass;
- bleed radius and pass count are hard-clamped by engine policy;
- may use bounded-whole-stroke replay until its cap, then deterministically
  promotes a prefix into settled-live and continues in replay-tail mode;
- resolves into the same premultiplied live tile and uses the same final
  preview/commit composite.

The initial implementation uses a maximum two local wash passes and a maximum
32-pixel bleed halo. These constants are measured and may only be reduced, or
raised by a reviewed spec amendment with performance evidence.

### 12.4 Preview/Commit Composite

Let `combinedLive` be:

```text
combinedLive = sourceOver(replayTail, settledLive)
```

For draw:

```text
visible = sourceOver(
    scalePremultiplied(combinedLive, strokeOpacity),
    canonical
)
```

For erase:

```text
visible = canonical * (1 - combinedLive.alpha * eraserStrength)
```

The commit pass writes these exact equations into canonical scratch. Live RGB
and alpha are scaled together. Material pipelines may change how live coverage
is generated; they may not substitute a different pointer-up equation.

## 13. Anchor Recipes And Minimal UI

Slice 4 supplies four immutable anchors as engine fixtures:

1. **Technical Ink**: crisp ink, no grain, pressure size when available,
   stable close spacing, no scatter.
2. **Dry Pencil**: dry material, paper/noise grain, pressure size and flow,
   direction-aware orientation, small deterministic scatter.
3. **Glaze Marker**: directional or chisel shape, translucent flow, visible
   overlap buildup under a fixed stroke-opacity ceiling.
4. **Bounded Wash**: soft shape, paper grain, bounded bleed, whole-stroke mode
   with deterministic cap degradation.

These are acceptance fixtures, not the final product preset pack. Calibration
targets are qualitative separation plus pinned test fingerprints; Slice 5 may
rename or replace them while preserving recipe-schema compatibility.

The current top bar gains one compact menu or picker for these four anchors.
It has text labels only, no generated previews, categories, editing controls,
curve editor, asset browser, or custom state. Recipe change during an active
stroke follows existing configuration policy: cancel the active stroke, then
update the selection.

The cursor remains a circle representing nominal maximum diameter at current
zoom. Pressure and non-round tips may render inside it; scatter and material
bleed are not represented by the ring in Slice 4.

The eraser uses a dedicated hard-round erase recipe with shared nominal
diameter and captured eraser strength. Selecting a draw anchor never causes
the eraser to paint, inherit draw color, or run a wet material.

## 14. Transaction, History, And Failure Semantics

`EditorTransaction` remains the only editor lifecycle owner. The captured
stroke configuration grows to include recipe and seed. A recipe-selection
intent is handled like color or diameter:

```text
idle -> update recipe
collecting -> cancel stroke, then update recipe
commit pending -> busy/no-op under existing policy
```

One pointer-up still creates one before/after raster history command regardless
of material or replay count. Replay never creates history and never captures
canonical revisions. Dirty history regions are the union of every projected
or wash-affected canonical region, including the maximum bleed halo. If the
bounded dirty-rectangle contract overflows, history conservatively captures
the full tile as it does today.

Cancellation or failure clears settled-live, replay-tail, wash, predicted,
sample, dab, asset-binding, and material state. It does not alter canonical
front, append history, or leave the editor busy.

## 15. Verification

### 15.1 Pure Tests

- V2 finite validation, clamping, angle normalization, capabilities, and
  neutral mouse behavior.
- World-space velocity for repeated, increasing, and invalid timestamps.
- Zero-strength stabilization identity and deterministic bounded carry.
- Legacy interpolator point parity.
- Per-dab pressure interpolation and exact endpoint behavior.
- Dynamic spacing carry across event boundaries and no spacing collapse.
- Recipe validation and stable anchor identities.
- Every mapping source and bounded power response.
- SplitMix64 pinned words, fixed channel consumption, and predicted-state
  isolation.
- Identical trace/recipe/seed produces identical dabs.
- Start/end taper and click behavior.
- Replay-tail replacement and whole-stroke cap degradation.
- Projected rotated/non-round/grained footprints against the tiling oracle.

### 15.2 GPU Harness

The harness schema gains explicit recipe ID, stroke seed, attributed samples,
material channel captures, replay counters, and asset identity diagnostics.

Required scene families, each with a proven negative control:

- hard-round legacy parity;
- pressure size/flow taper;
- deterministic scatter repeatability and different-seed separation;
- hard/soft/non-round shape coverage;
- canonical and brush-local grain continuity;
- dry material tooth;
- ink coverage;
- glaze flow/opacity ceiling;
- bounded-wash bleed radius and pass cap;
- end-taper replay correction;
- predicted suffix replacement without duplicate settled dabs;
- live/commit equality for every material;
- draw/erase parity after selecting every anchor;
- all four anchors across all seven tilings and noncentral visible cells;
- replay epoch ordering with delayed/out-of-order completion drainage;
- one pointer-up/one history command for every material;
- cancel and injected GPU/allocation failure preserve canonical bytes.

Every asset scene proves asset identity, not merely that a fallback also
renders. Seam scenes assert zero holes, zero phantom pixels, and coordinate
continuity where applicable.

### 15.3 Integration And UI Automation

- Anchor selection updates model and next stroke.
- Recipe selection during drawing cancels before update.
- Diameter cursor continues to track nominal size for every anchor.
- Brush size, grid, tiling, clear, undo/redo, tool, color, and shortcuts remain
  responsive after anchor changes and strokes.
- Eraser always erases after every draw anchor and draw resumes afterward.
- Focus loss and Escape clear transient replay state.
- A failed brush operation returns the reducer and controls to idle.
- macOS anchor picker is keyboard/focus safe.
- iPad target builds and launches its current layout without claiming Pencil
  acceptance.

### 15.4 Manual Mac Gate

- four anchors feel visibly and behaviorally distinct;
- nominal cursor alignment remains correct while panning and zooming;
- pressure-capable tablet input, if available, changes size/flow smoothly;
- no event-boundary spacing steps or opacity jump on pointer-up;
- end taper corrects without a visible stale tail or flash;
- long ink/dry strokes remain immediate;
- wash is bounded and does not freeze interaction;
- visual seam scan passes every tiling.

### 15.5 Performance And Bounds

Record existing benchmark fields plus recipe, material, seed, replay mode,
sample/dab retention peaks, replay count, settled-prefix count, asset bytes,
material pass time, and wash working bytes.

Existing governing budgets remain:

- brush processing p95 under 2 ms/frame;
- dab rendering under 3 ms for 500 new dabs;
- sustained 60 fps minimum;
- missed frames below 1 percent in the fixed stress trace;
- no unexplained p95 regression above 15 percent;
- no per-frame cost growth with settled stroke length;
- preview/commit difference within one 8-bit value.

Unstable virtualized or paravirtualized timings are diagnostic rather than a
functional implementation blocker. They do not count as acceptance evidence.
Stable Mac measurements and manual feel remain pending until the environment
can provide them. Pencil latency and 120 Hz gates remain pending until iPad
hardware is available.

## 16. Delivery Increments

### 4A. Deterministic Input And Legacy Parity

Add V2 samples, world derivation, stabilizer seam, attributed interpolation,
legacy-equivalent recipe, and pinned deterministic traces without changing
rendered pixels.

Exit: all prior scenes are byte/pixel equivalent and new pure parity tests
pass.

### 4B. Recipes, Dynamics, And Dynamic Placement

Add validated recipes, SplitMix64 channels, dynamic size/spacing/flow,
rotation/scatter, and generated footprint transforms while retaining the hard
round material.

Exit: deterministic dynamics and all-tiling transformed-footprint gates pass.

### 4C. Shape, Grain, And Ink/Dry

Grow/guard the ABI, resolve mipmapped coverage assets, add shared material
uniforms, and ship ink and dry rendering.

Exit: asset identity, grain continuity, live/commit, and seam gates pass.

### 4D. Glaze And Stroke Opacity

Add flow accumulation and one-time premultiplied stroke-opacity composite for
preview and commit.

Exit: opacity ceiling and no-jump gates pass for draw and erase.

### 4E. Taper And Replay

Add transient buffer modes, predicted isolation, end taper, renderer epochs,
regional clear/restamp, and stale-completion protection.

Exit: replay ordering, taper, cancellation, failure, and long-stroke bounds
pass.

### 4F. Bounded Wash And Anchor Acceptance

Add bounded wash working textures/passes, the four anchor fixtures, minimal
picker, full harness family, UI automation, evidence script, and milestone
record.

Exit: anchors feel distinct; spacing, opacity, material, seam, history, bounds,
build, and regression gates pass or are explicitly recorded as hardware-only
pending.

## 17. Completion Criteria

Slice 4 is functionally complete when:

- BrushInput V2 and pure deterministic generation are the only active stroke
  path;
- legacy hard-round behavior is represented by a recipe, not parallel code;
- pressure and dynamic spacing are evaluated per dab;
- deterministic scatter and replay are pinned by tests;
- shape/grain, dry, ink, glaze, and bounded wash render through guarded shared
  ABI and bindings;
- preview equals commit for draw and erase;
- four anchors are selectable and materially distinct;
- every enabled anchor/material/grain mode passes all-tiling seam gates;
- replay and wet storage remain within declared caps;
- one stroke remains one history command;
- all prior tests and harness scenes remain green;
- macOS and iPadOS targets build and analyze;
- unavailable hardware gates are documented as pending rather than guessed.

Slice 4 completion does not imply Slice 5 Brush Product completion.
