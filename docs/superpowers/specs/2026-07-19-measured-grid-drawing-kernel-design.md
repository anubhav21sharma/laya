# Slice 1: Measured Grid Drawing Kernel

**Date:** 2026-07-19
**Status:** Approved
**Targets:** macOS interaction; iPadOS continuously buildable

## 1. Purpose

Slice 1 replaces the blank Slice 0 renderer with the first real drawing loop.
It proves that normalized input can become a truthful, responsive repeated
grid image without compromising cancelability or making frame cost grow with
stroke length.

The exit promise is:

> A hard-round mouse stroke appears immediately in every grid repeat, remains
> discardable until pointer-up, commits without a visual change, and costs only
> the new dabs emitted for the current frame.

This design is subordinate to the approved product rebuild design. Recovered
feature documents provide useful evidence, but their clear-and-rebuild live
tile is superseded by the later persistent-live performance correction.

## 2. Scope

### 2.1 Included

- Normalized macOS mouse input.
- A viewport with pan and cursor-anchored zoom.
- World-space fixed-spacing centripetal Catmull-Rom interpolation.
- One opaque black hard-round brush.
- One 256 x 256 canonical raster.
- Grid repetition only.
- Exact translated wrap placements for hard-round dabs crossing grid edges.
- A persistent live-stroke texture that stamps only new dabs.
- Nonblocking pointer-up commit through a scratch canonical texture.
- Pointer cancel, Escape, focus-loss cancellation, and failure cancellation.
- Onscreen drawing through the real app metallib.
- Offscreen pixel, lifecycle, and performance scenes through the same metallib.
- CPU tests, benchmark JSON, negative controls, dual-platform builds, and a
  manual Mac interaction gate.

### 2.2 Deferred

- Half-drop, brick, mirror, rotational, and generalized cell-fragment
  projection.
- Rectangular or user-configurable tiles.
- Brush configuration UI, color, opacity, eraser, pressure response, tilt,
  textures, grain, scatter, taper, and materials.
- Pencil, coalesced, predicted, or late-estimated iPad input.
- Undo/redo and document commands.
- Layers, selection, transform, persistence, export, and product toolbars.
- Custom frame schedulers. Slice 1 measures MetalKit timed redraw first.

### 2.3 Explicit Rebuild Decisions

These choices are deliberate additions or overrides where recovered documents
do not supply one controlling answer:

- Space-primary-drag is the Slice 1 pan gesture. The recovered middle-drag
  alternative is not included.
- Zoom clamps to `0.25...8.0` and remains cursor anchored.
- The initial tile is centered in the drawable.
- The accepted Slice 0 Precision Light neutral paper replaces the recovered
  pure-white drawable clear.
- Focus loss cancels an active stroke.
- Canonical commit uses a scratch replacement so failed commits do not replace
  the last completed raster.
- Hard-round coverage uses a one-pixel analytic antialias transition.
- Commit-pending input is rejected rather than queued in Slice 1; acceptance
  requires the pending interval to remain imperceptible.

## 3. Governing Invariants

1. Canonical pixels are the retained source of truth.
2. Input is interpolated in continuous world space before grid projection.
3. Canonical coordinates use half-open right and bottom boundaries.
4. The active stroke never mutates canonical pixels.
5. Pointer-up produces one canonical replacement; cancel produces none.
6. Live display and commit use identical premultiplied source-over math.
7. Per-frame live-stroke work depends on newly emitted dabs, not total stroke
   length.
8. Missing drawables and transient renderer failures do not change the last
   committed canonical front texture.
9. The interactive input-to-encoding path performs no waits, file I/O, image
   encoding, shader compilation, or unbounded allocation.
10. `swift test` remains a CPU-contract gate and never claims shader
    validation.

## 4. User Interaction

### 4.1 Drawing

- Primary-button down begins a stroke and emits an initial dab.
- Primary-button drag adds normalized samples.
- Primary-button up emits the final endpoint and requests commit.
- Mouse pressure uses the recovered neutral default `0.5`. Slice 1 records it
  in normalized samples but does not map pressure into brush attributes yet.
- The initial brush is opaque black, diameter `20` world pixels, radius `10`.
- Dab spacing is the recovered simple-kernel rule
  `max(1, min(8, radius * 0.25))`, initially `2.5` world pixels.
- A click without movement produces one round dab.

### 4.2 Viewport

- World coordinates use pixels and increase rightward and downward.
- Default zoom is `1.0`; allowed zoom is `0.25...8.0`.
- The 256 x 256 central tile is centered in the initial drawable.
- Space-primary-drag begins a pan only from idle. Pressing Space after a stroke
  begins does not convert it; navigation input is ignored until stroke end.
- Wheel and magnification gestures zoom around the cursor. The world point
  under the cursor before the zoom remains under it after the zoom.
- Grid boundaries are supported as a subtle development overlay but default
  off, matching the recovered config. Harness scenes may enable them
  explicitly. The canvas uses the existing Precision Light neutral paper
  color.
- Pointer coordinates are converted from backing coordinates exactly once at
  the platform boundary.

### 4.3 Cancellation

Escape, platform pointer cancellation, loss of window/key focus, or a renderer
failure cancels the active stroke. Cancellation removes transient state and
leaves the committed canonical front texture unchanged.

## 5. Module Architecture

```text
PatternSpike app
  InteractiveMetalView / input adapter
      |
      v
PatternEngine
  ViewportTransform
  normalized StrokeSample
  CentripetalCatmullRomStrokeInterpolator
  GridProjection
  RasterSurface protocol
      |
      v
MetalRenderer
  GridRenderer
  renderer-local ViewportState
  CanonicalRaster
  LiveStroke
  PersistentLiveTile
  triple-buffered DabInstanceBufferPool
  app metallib
```

### 5.1 PatternEngine

PatternEngine owns platform-free math and behavior:

- Typed point, size, and rectangle values or focused wrappers around simd
  values.
- Pure `ViewportTransform` math, including `screenToWorld`, `worldToScreen`,
  panning, zoom clamp, and cursor-anchor preservation. Mutable viewport state
  remains renderer-local.
- Normalized `StrokeSample` values containing position, pressure, timestamp,
  phase, and source without AppKit/UIKit types.
- A centripetal Catmull-Rom, arc-length fixed-spacing interpolator with carry
  across input segments.
- Grid folding with mathematically positive modulo into `[0, width)` and
  `[0, height)`.
- Translation-only hard-round wrap placement enumeration for every lattice
  copy whose circular bounds intersect the canonical tile.
- A minimal Metal-free `RasterSurface` contract exposing pixel dimensions and
  opaque revision identity; MetalRenderer supplies the concrete texture-backed
  surface.

The interpolator uses the recovered no-lookahead closure rule: each segment
duplicates the current point as its trailing control. It emits the initial
point once, preserves spacing carry between move events, and emits the final
endpoint on pointer-up when needed. Every emitted position is therefore final
immediately and safe for the persistent live texture. True lookahead,
stabilization, prediction, and professional dynamics remain later work.

### 5.2 MetalRenderer

`GridRenderer` replaces `BlankRenderer` as the interactive renderer. It owns:

- A private `.bgra8Unorm` transparent canonical front texture.
- A private `.bgra8Unorm` transparent canonical commit scratch texture.
- A private `.bgra8Unorm` transparent persistent live texture.
- A renderer-local mutable `ViewportState` containing a pure
  `ViewportTransform`.
- An append-only `LiveStroke` with monotonic dab identity and a baked
  high-water mark.
- A fixed, preallocated triple-buffered `DabInstance` pool.
- Hard-round stamp, grid-display, and canonical-composite pipelines.
- Interactive frame, stroke, commit, error, and benchmark state.

The document still has one logical `RasterSurface`. Scratch and in-flight
textures are renderer-private synchronization resources, not additional
document rasters or layers.

`BlankCanvasContract` remains available for the Slice 0 harness and regression
gate. Slice 1 adds focused grid contracts rather than silently redefining the
blank contract.

### 5.3 PatternSpike App

The app layer owns only platform translation and lifecycle:

- An `InteractiveMetalView` receives AppKit mouse, key, wheel, magnification,
  focus, and resize events.
- It normalizes them into engine inputs and semantic viewport commands.
- It never contains interpolation, grid-fold, wrap, brush, or shader policy.
- The iPadOS adapter remains compile-safe but makes no Pencil or device
  behavior claim in this slice.
- SwiftUI continues to show the explicit unsupported/error state when Metal
  initialization fails.

## 6. Coordinate And Geometry Contracts

### 6.1 Viewport

Renderer-local `ViewportState` stores drawable size, world center, and
positive zoom. It delegates conversions to the pure PatternEngine
`ViewportTransform`.

```text
screen = (world - worldCenter) * zoom + screenCenter
world  = (screen - screenCenter) / zoom + worldCenter
```

Panning by a screen delta moves `worldCenter` by `-delta / zoom`, making the
art follow the pointer. Cursor-anchored zoom computes the anchor world point
before changing zoom, clamps the requested zoom, then adjusts `worldCenter` so
the same world point maps back to the anchor screen point.

### 6.2 Grid Fold

For positive tile dimensions:

```text
canonicalX = worldX - floor(worldX / tileWidth) * tileWidth
canonicalY = worldY - floor(worldY / tileHeight) * tileHeight
```

This gives half-open canonical coordinates for positive and negative world
positions. Storage projection and display sampling use the same formula.

### 6.3 Hard-Round Wrap Placement

Slice 1 may exploit radial symmetry only for its hard-round brush. It folds the
world-space center into canonical space, then emits translated lattice copies
whose circular bounds intersect the canonical tile. This makes grid-edge and
corner strokes exact without introducing the full transforms and convex clips
reserved for Slice 2.

No interface in this slice claims that center folding is sufficient for
textured, directional, reflected, or rotated stamps.

## 7. Stroke And Frame Data Flow

```text
AppKit event
  -> normalized screen sample
  -> ViewportTransform.screenToWorld once
  -> CentripetalCatmullRomStrokeInterpolator
  -> fixed-spaced world dab centers
  -> GridProjection fold + wrap placements
  -> append monotonically identified dabs to LiveStroke
  -> next Metal frame encodes pending suffix only
  -> PersistentLiveTile load-action .load stamp
  -> advance baked high-water mark after successful encoding
  -> compact safely baked CPU prefixes within fixed buffer capacities
  -> grid display samples live over canonical
```

The live texture is never cleared and rebuilt during an active stroke. Final
dabs are immutable when emitted, so no promotion or provisional texture is
needed in Slice 1. `LiveStroke` assigns absolute monotonic dab indices and
advances a baked high-water mark; it never deduplicates by position. Baked
prefix storage may compact after its instance-buffer lifetime ends, but
absolute identity never resets before stroke completion.

Physical CPU payload is bounded to the current pending buffer capacity plus at
most three in-flight buffer capacities. Capacity is fixed during renderer
initialization; excess emitted instances are encoded in ordered chunks instead
of growing hot-path storage.

The renderer maintains structural counters:

- New dabs emitted for the current input event.
- New instances encoded for the current frame.
- Total dabs encoded for the stroke.
- Frames rendered during the stroke.

These counters prove that a late frame does not restamp early-stroke dabs.

## 8. Commit And Cancel

### 8.1 Commit

Pointer-up performs no synchronous GPU wait.

1. Encode any pending live dabs.
2. Render `live over canonicalFront` into `canonicalScratch` using the same
   premultiplied source-over function used by display.
3. Submit the command buffer and keep displaying the old canonical plus live
   texture while it is pending.
4. On successful completion, swap front and scratch, mark live logically
   invisible, and complete the stroke.
5. Clear the physically dirty live texture before its next use.

Because display remains `live over old front` until the completed scratch is
swapped in, pointer-up causes no blank or double-composite frame.

### 8.2 Commit-Pending Lifecycle

Slice 1 serializes stroke lifecycles. A new stroke is not admitted while the
prior scratch commit is awaiting GPU completion. Pointer events received in
that short state do not mutate renderer or canonical state. The manual gate
measures this interval; acceptance requires it to remain below one display
frame and produce no perceptible stall. Later transaction work may add input
queuing only if measurement proves it necessary.

### 8.3 Cancel

Cancel marks live invisible, drops interpolation and pending dabs, and clears
the live texture before reuse. Canonical front and scratch identity remain
unchanged.

## 9. GPU Pipeline

### 9.1 Shared ABI

Append new grid frame and dab layouts to `CShaderTypes`; do not repurpose or
renumber existing wire constants. Pure tests and renderer startup
preconditions guard size, stride, alignment, and offsets before pipeline
creation.

### 9.2 Hard-Round Stamp

Each dab instance supplies canonical center and radius. The vertex function
expands an instanced quad. The fragment function emits straight black RGB with
coverage alpha and a one-pixel analytic antialias transition at the circle
edge. Matching the recovered stamp contract, live stamping uses
`sourceRGB = .sourceAlpha`, `destinationRGB = .oneMinusSourceAlpha`,
`sourceAlpha = .one`, and `destinationAlpha = .oneMinusSourceAlpha`, producing
premultiplied `.bgra8Unorm` storage.

### 9.3 Grid Display

A full-screen pass maps screen pixels through the viewport into world space,
folds by the grid formula, samples canonical and live at the same coordinate,
and returns their premultiplied live-over-canonical result. The drawable clears
to neutral paper; the display pipeline blends the tile over that clear using
`.one` and `.oneMinusSourceAlpha`. Paper is not baked into canonical, live, or
tiling-shader output. When live is logically hidden, the same pipeline uses
transparent live contribution. Optional grid-line coverage is derived from
distance to tile boundaries in screen space so line weight remains visually
stable across zoom.

### 9.4 Commit Composite

The commit pass samples canonical front and live, uses the same source-over
function as grid display, and writes the result into scratch. It never writes
the current front in place.

## 10. Scheduling And Allocation

- Start with `MTKView` timed redraw at a device-appropriate preferred rate.
- Acquire the drawable immediately before the onscreen pass.
- The main actor preserves event and encoding order.
- Preallocate a triple-buffered ring of instance buffers outside the input hot
  path.
- Split more than one buffer capacity of new instances into bounded chunks
  without retaining the full stroke on CPU.
- Retain append-only `LiveStroke` identity while active. Compact safely baked
  CPU payloads within the fixed buffer-capacity bounds; the persistent live
  texture remains the transient pixel artifact.
- No custom display link, predicted input, or speculative replay is added until
  measurement proves it necessary.

## 11. Failure Handling

Typed renderer failures distinguish:

- Metal/device/library/pipeline unavailability.
- Canonical, live, scratch, or instance-buffer allocation failure.
- Invalid drawable or texture dimensions.
- Invalid stroke or commit-pending lifecycle.
- Command buffer creation, encoding, or GPU execution failure.

Encoder creation failure leaves counters and pending instances retryable.
Submitted live-pass failure cancels transient state and dirties only the
throwaway live texture. Commit failure never swaps scratch into front.
Missing drawables skip presentation without consuming semantic input.

The app retains the last committed display when possible and presents a short
unsupported/error message. There is no fallback renderer.

## 12. Verification

### 12.1 Pure Tests

- Viewport screen/world round trips across zoom and pan.
- Cursor-anchored zoom invariance and zoom clamping.
- Screen-delta pan conversion.
- Interpolation initial/final dabs, fixed spacing, segment carry, click dots,
  and negative-world motion.
- Grid modulo at zero, exact boundaries, negative coordinates, and large
  coordinates.
- Interior, edge, and corner wrap placements.
- Stroke begin/move/end/cancel lifecycle.
- Commit-pending lifecycle and non-mutation behavior.
- Shared CPU/MSL layout parity.

### 12.2 Real-Metallib Harness

The existing macOS app executable remains the GPU harness. Slice 1 adds fixed
scene families for:

1. Interior grid stroke.
2. Grid-boundary and corner stroke.
3. Live screen versus committed screen equality within one 8-bit value.
4. Cancel preserving exact canonical bytes.
5. A frame containing 500 new dabs.
6. A long trace whose late frames encode only their new instances.

Pixel scenes emit live, committed, and canonical PNGs as relevant. Performance
scenes emit benchmark JSON containing hardware, OS, build, CPU spans, GPU
spans, frame count, new-instance counts, total-stroke counts, and peak resident
memory.

Each new harness family receives a deliberate negative-control run. Pixel
controls expect a wrong pixel or image phase. Structural controls deliberately
expect an incorrect instance count. The failure is recorded before the
positive scene passes.

### 12.3 Performance Gates

- Brush processing p95 below 2 ms per frame.
- GPU dab rendering below 3 ms for 500 new dabs.
- Grid display pass below 2 ms.
- Sustained drawing and pan/zoom at 60 fps minimum.
- Missed frames below 1 percent in the fixed stress trace.
- No frame-time growth attributable to accumulated stroke length.
- Live and committed channels equal within one 8-bit value.
- Slice 1 establishes the fixed-scene p95 baseline. Later milestones fail on
  unexplained regression above 15 percent against that accepted baseline.

The structural new-instance counter is the primary proof of constant
per-frame work. Timing is still recorded and gated, but noisy host timing
cannot excuse re-stamping accumulated dabs.

### 12.4 Build And Manual Gate

The automated Slice 1 gate runs:

- `swift test`.
- macOS app build.
- Generic iPadOS Simulator build.
- All real-metallib positive and negative scenes.
- PNG, benchmark, schema, and repository-hygiene assertions.

The manual Mac gate confirms:

- The first dab appears under the cursor.
- A stroke repeats live across the visible grid.
- Grid-edge and corner strokes have no visible gap.
- Pointer-up causes no visual change.
- Escape and focus loss discard the active stroke.
- Space-drag pan and cursor-centered wheel/pinch zoom remain aligned.
- Long strokes stay responsive.
- Window resize preserves rendering and input alignment.

## 13. Slice 1 Exit

Slice 1 is accepted only when:

- Immediate grid drawing works through the real app.
- Preview and commit match within one 8-bit value.
- Cancel leaves canonical bytes unchanged.
- Structural counters prove only new dabs stamp each frame.
- Fixed performance budgets pass or a measured environment limitation is
  explicitly resolved before acceptance.
- CPU tests, macOS build, iPadOS build, GPU harness, artifacts, and hygiene all
  pass.
- The user accepts the Mac drawing, pan/zoom, cancel, resize, and feel gate.
- A milestone note records results, benchmark identity, negative-control
  evidence, decisions, and retrospective.
- No Slice 2 generalized tiling or later product behavior leaks into scope.
