# Live Drawing Experience — Design Spec

**Date:** 2026-06-19 **Status:** Implemented + human-confirmed on macOS.

## Purpose & Context

The tiling engine, viewport math, and a working commit path already existed: a stroke could be drawn and, on pointer-up, would appear tiled across the canvas. But the *in-progress* stroke did not repeat live — the user only saw the pattern after releasing — and committed strokes left thin **white seams** wherever a stroke crossed a tile edge. This spec covers making the live stroke appear under the pen and tile live across the whole canvas, wrapping correctly at tile boundaries, which also eliminates the seam bug.

Scope at the time: a **single pattern layer with grid tiling**. Explicitly deferred: layers/compositor, undo, erase, the other four tilings, predicted touches, and off-main-thread commit.

The load-bearing idea is a separation of concerns between two coordinate regimes and two pixel buffers: interpolate the stroke in continuous **world space**, then fold each emitted dab into **canonical tile space** with boundary-wrap copies; and keep the in-progress draft in a **separate transparent texture** from the committed canonical pixels until pointer-up.

## Decisions

### D1 — Interpolate in world space, fold to canonical *after*

The stroke smoother (`StrokeInterpolator`, centripetal Catmull-Rom) runs on **world-space** points. The screen sample is converted to world **once** on ingest, and the smoothed curve is walked in world space; only after a point is emitted is it folded into canonical tile space.

Rationale: a stroke that crosses a tile seam must stay a single continuous curve. If folding happened *before* interpolation, the input point sequence would jump discontinuously (e.g. from canonical x≈255 to x≈1) mid-curve, and the smoother would either kink or spuriously interpolate across the whole tile. Interpolating in the unbounded world regime keeps the curve geometrically faithful; the fold is a per-point projection that cannot corrupt curve shape. (This is concern #3, "seam-crossing strokes.")

Rejected: fold-then-interpolate — breaks smoothing across seams, as above.

### D2 — Each emitted dab carries *both* a world and a canonical position

An emitted dab is expanded into an `EmittedDab` holding `placements: [DabSpec]`, where each `DabSpec` carries a `worldPosition` (unbounded, where the dab actually is under the pen) and a `canonicalPosition` (the same dab folded into the tile). `placements[0]` is the primary dab; any further entries are opposite-edge wrap copies (see D3). Radius/alpha are shared across placements.

Rationale: the two positions serve two different consumers — world for "draw it literally under the cursor," canonical for "stamp it into the tile so it repeats." Carrying both avoids re-deriving one from the other downstream and keeps the engine the single source of geometry. (In the final tiled-preview design the renderer only needs the canonical placements — see D5 — but the dual-position `DabSpec` is the clean engine contract.)

### D3 — Fold expands into boundary-wrap placements

When a dab's canonical footprint (`center ± radius`) crosses a tile edge, the fold emits an additional placement shifted by ±1 tile-size onto the opposite edge. A dab in a corner produces up to three extra copies (primary + 3). This uses the tiling strategy's existing `wrapPlacements(forCanonicalBounds:)`, which was already implemented and unit-tested but **not wired into any write path**.

### D4 — The white-seam bug: root cause and fix

**Root cause:** `wrapPlacements` existed and passed its tests, but the commit path never called it. A dab straddling a tile edge was stamped into the canonical texture exactly once and clipped at the boundary. Nothing wrote the clipped remainder onto the opposite edge, so the stored tile had a **transparent sliver** along that edge. When the tile repeats, adjacent copies do not cover for each other there, and the transparent sliver reveals the white paper underneath — a thin white line at every tile seam.

**Fix:** wire `wrapPlacements` into the fold (D3) so the session emits opposite-edge copies, and stamp *all* placements at commit. The stored tile is then seamless: what leaves one edge re-enters the other.

**Why we trust this is the cause, not a screen-space artifact:** the seams appeared **only after drawing** (a blank tiled canvas had none) and their thickness **scaled with the tile** rather than staying a fixed number of screen pixels. Both point at a stored-texel defect (missing pixels in the canonical texture), not a sampler/filtering artifact at tile joins. Human visual confirmation on macOS: after wiring wrap into commit, strokes continue seamlessly onto the opposite edge and the white lines are gone.

### D5 — Two-texture compositing: draft stays separate until commit

The in-progress stroke renders into a **separate transparent "live-tile" texture**, the same 256x256 canonical tile space as the committed tile, with the same wrap-placement stamping. Every frame the live tile is **cleared and rebuilt** from the current set of live dabs (it is never persisted). The tiling fragment shader samples **both** the committed canonical tile and the live tile at the same wrapped UV and composites **live over committed** in one pass. That single composited color is what repeats across the viewport.

Rationale:
* Because the live tile is stamped in canonical space with the same wrap logic as commit, the in-progress stroke **tiles and wraps identically to how it will look once committed** — the preview is truthful (concerns #1 under-pen and #2 live tiling both fall out of this one mechanism).
* Keeping the draft in its own buffer means pointer-up **commit** (bake live dabs into canonical) and pointer-cancel (discard) are trivially clean — committed pixels are never touched mid-stroke, so cancel needs no undo and commit is a single append.

Rejected: stamping live dabs directly onto the drawable in a separate screen-space pass (an interim scaffold during the build). That draws the stroke under the pen but does **not** tile it — the live stroke would appear in only one cell. Replaced by the live-tile composite.

Note on blend interaction: the tiling pipeline already composites its output over the white paper clear color. So the shader returns one `live-over-committed` color and the pipeline then puts that over paper — a three-way stack (live over committed over paper). An unpainted texel stays transparent and shows paper; a painted texel shows ink. This interaction (especially opacity where a live stroke overlaps already-committed paint) is the thing the visual check had to confirm.

## Data Flow / Architecture

```text
StrokeSample (screen pos, pressure)
  → StrokeSession.ingest: screenToWorld ONCE
  → StrokeInterpolator (walks WORLD space)                    [D1]
  → StrokeSession.emit: per emitted world point,
      fold worldToCanonical, then expand via
      wrapPlacements → EmittedDab{ placements: [DabSpec] }    [D2, D3]
  → SpikeRenderer.addOverlayDabs: flatten placements into
      liveCanonicalDabs (canonical-space GPU dabs)
  — each frame —
  → LiveTile.rebuild: clear to transparent, stamp
      liveCanonicalDabs into the 256² live texture            [D5]
  → tiling_fragment: sample canonical + live at wrapped uv,
      return live over committed; pipeline composites
      that over paper                                         [D5]
  — pointer-up —
  → commitOverlay: canonical.commit(liveCanonicalDabs)        [D4]
      (wrap copies included → seamless tile), clear live
  — pointer-cancel —
  → cancelOverlay: clear live, canonical untouched
```

Module responsibilities:

* **`StrokeSession`** (PatternEngine, pure) — owns a fresh per-stroke interpolator; interpolates in world; folds + wrap-expands each emitted point.
* **`DabSpec` / `EmittedDab`** (PatternEngine) — the geometry contract: world + canonical position per dab, placements list per emitted point.
* **`LiveTile`** (MetalRenderer) — the transparent draft texture; rebuilt every frame from the live dabs using the same dab pipeline and identity (offset 0, zoom 1) uniforms as the canonical commit, so live and committed stamping are pixel-identical. Rebuilt inline into the frame's command buffer (not a separate blocking submit like commit).
* **`SpikeRenderer`** — owns the live tile; accumulates `liveCanonicalDabs`; rebuilds the live tile before the tiling pass; binds both textures (canonical @0, live @1, shared sampler); `commit`/`cancel` clear the overlay.
* **`Shaders.metal` `tiling_fragment`** — samples both tiles at the modular-wrapped UV (which must match `GridStrategy.worldToCanonical`) and composites live over committed.

## Known Limitations

* Grid tiling only. The fold and the shader's modular wrap are the grid mapping; the other tilings are out of scope here.
* Single pattern layer. No compositor, no layer stack.
* No undo, no erase. Commit is append-only into canonical; cancel discards the draft.
* Live tile rebuilt fully each frame from all accumulated live dabs — fine for a single stroke at spike scale; not optimized for very long strokes.
* Off-main-thread commit and predicted touches deferred.

## Verification

Engine-level TDD covered the geometry; a dab near the right edge (canonical x≈250, radius 20) must also emit an opposite-edge placement (x<0); an interior dab must emit exactly one placement; a corner dab must emit four (primary + three); world position must survive the fold (a screen point in cell 2 keeps its true world x while folding to canonical). A dedicated seam-regression test asserts edge/corner strokes produce opposite-edge placements, pinning the D4 fix at the data level.

The payoff is not headless-testable and was **human-confirmed on macOS (2026-06-19)**: while still dragging, the stroke appears under the cursor, repeats live across every tile, wraps live onto the opposite edge when crossing a seam, shows no white seams, and on release the committed result matches the live preview exactly (live tile and canonical share the same stamping path).