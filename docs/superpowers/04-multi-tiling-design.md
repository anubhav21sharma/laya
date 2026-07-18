# Multi-Tiling & Configurable Sizes — Design Spec

**Date:** 2026-06-20 **Status:** Shipped (on main). **Provenance:** design derived and adversarially re-derived by independent verifiers (workflows `wf_aef40322-9c1` + `wf_cfa77211-3f5`).

## Purpose & Context

The tiling engine started with one wallpaper group (grid `p1`) and a hardcoded 256px tile. This work ships **five wallpaper-group tilings** and makes both **tile size and brush size end-user-configurable** at runtime, while fixing the boundary-wrap math so it stays seamless for brushes larger than a single tile. The five tilings: **grid** (`p1`), **mirror** (X / Y / both, one strategy with an axis enum), **half-drop**, **brick**, and **rotational** (`p2`).

The shape of the code is dominated by one structural constraint: every tiling is a **parity pair of two hand-mirrored folds** that must agree exactly across the Swift/MSL boundary. Everything else (the round-dab simplification, the wire contract, the large-brush bounds) exists to keep those two folds honest and cheap.

## Architecture — the two folds

Each tiling is a `TilingStrategy` that owns **both halves** of a parity pair:

* **Storage fold** (Swift, CPU): `worldToCanonical` + `wrapPlacements`. Produces the dab placements written into the canonical tile texture.
* **Sampling fold** (MSL, GPU): a single `tiling_fragment` that `switch`es on a `uint tilingKind` uniform and reads the repeated tile back for display.

The two folds are hand-mirrored — each `case` in `foldCanonical` (MSL) re-implements the same math as its strategy's `worldToCanonical` (Swift). They are kept honest by a **per-group CPU parity test** that re-implements the MSL fold in Swift and asserts it matches `worldToCanonical` at sampled points (exact in `Double`; sub-pixel epsilon for `Float` reconstructions). No shared metal-callable fold library was built — that is deferred until parity drift actually recurs.

Data flow for configurable tile size: `app config` -> `SpikeRenderer` -> `GridStrategy/CanonicalRaster/LiveTile` -> `tileSize uniform`

```text
StrokeSample (world)
-> TilingStrategy.worldToCanonical    // fold world center into canonical tile
-> TilingStrategy.wrapPlacements      // expand into boundary-wrap copies
-> StrokeSession.emit                 // transform-agnostic; applies radius cap
-> LiveTile / CanonicalRaster         // stamp round dabs into the tile texture
-> tiling_fragment (foldCanonical)    // GPU samples the repeated tile for display
```

## Key decisions

### Round-dab simplification (load-bearing)

For an isometry `R(x) = Mx + b` with `M` orthogonal, `R(disk(c, r)) = disk(R(c), r)`. Because a v1 dab is a **round, radially-symmetric disk** (fragment falloff is `length(local)`, and `radius`/`alpha` are isometry-invariant), transforming *only the center* is pixel-exact. Consequences:

* `WrappedPlacement` **stays a `Point`** — no GPU 2x2 matrix is needed. But its *meaning changes* from "additive delta" to "**absolute transformed canonical center**" (`center + offset == R(center)` by construction). For grid/half-drop/brick the transform is a pure translation, so absolute-center math equals the old additive math; only mirror/`p2` exploit the new freedom.
* `StrokeSession.emit` becomes **transform-agnostic**: it never branches on tiling kind. Each strategy bakes its own isometry (`R(c) - c`) into the placement offset, so `emit` just does `canonicalPosition = c + wp.offset` for every group.
* The **dab vertex/fragment shaders are unchanged** by this work.

**Rejected alternative:** carrying a full 2x2 (or angle + flip-sign) on `WrappedPlacement`/`DabInstance` from day one. Rejected as premature — round dabs make it unnecessary and it complicates the GPU path for no v1 benefit.

### Affine migration trigger (documented, deferred)

The day a **non-round / textured / directional brush** lands, the round-dab shortcut breaks and the full isometry must be carried:

* Add a 2x2 (or angle + flip-sign) to `Dab`/`DabInstance`. **Note:** a single scalar sign is insufficient — mirror needs mixed signs `diag(-1, +1)`.
* `dab_vertex` computes `world = R(c) + M * (corner * radius)`; `dab_fragment` samples `M⁻¹·local`; strategies emit the full isometry.
* Pressure-varying radius does **not** trigger this (per-dab radius is already stored).

### p2 is NOT edge-continuous (adversarially verified)

**Do not** write an edge-continuity assertion for `p2`. Adjacent 180°-rotated cells meet only at a **point**, not along a continuous seam. `p2` consistency comes from its **2-fold rotation centers** instead. Tests assert the rotated-center placement and the fold values, never seam continuity. (This corrected a first-pass error where a naive mirror-style continuity check was assumed.)

### User decisions (2026-06-20)

* **Tile-size change -> resample.** Existing canonical content is *scaled* to fill the new tile dimensions (a GPU blit/draw old->new texture) so composition is preserved. Rejected alternative: keep pixels 1:1 and expose more blank tile — noted but not implemented.
* `p2` rotation center = tile center (`w/2, h/2`).
* Mirror = one strategy with an axis enum (`.x` / `.y` / `.both`), not three strategies.
* Include brick this round (row-phase half-drop; the transpose of half-drop's column phase).

### Half-drop / brick storage is plain grid-translation

Half-drop (odd columns shift down by `h/2`) and brick (odd rows shift right by `w/2`) are the **same mechanism with axes swapped** — one `HalfDropStrategy` with an axis enum covers both. The half-step is a **sampling concern** applied when reading world->canonical; the stored canonical tile is an ordinary seamless `[0,w)×[0,h)` raster whose own edges wrap by `±tile`. So `wrapPlacements` is the identical lattice enumeration as grid. Both are pure translations, needing no reflection machinery.

### tilingKind wire contract

`tilingKind` lives on the `TilingStrategy` protocol as the single source of truth mapping strategy -> GPU uniform. Raw values are a **pinned wire contract** with the shader `switch` — append new kinds at the end, never renumber:

| kind | raw value |
| :--- | :--- |
| grid | 0 |
| halfDrop | 1 |
| brick | 2 |
| mirror | 3 |
| rotational | 4 |

A separate `gpuKindBits: UInt32` packs the selector actually sent to the shader: **low byte = `tilingKind.rawValue`**, bits 8–9 = mirror axis flags (x = `0x100`, y = `0x200`). The protocol default is just the raw kind; only `MirrorStrategy` overrides it to set the axis flags. On the GPU side this reused the existing `_pad0` uniform slot renamed to `uint32_t tilingKind` — a layout-neutral change (both are 4 bytes aligning `tileSize`).

### Large-brush wrap enumeration

The original wrap emitted at most one copy per axis (`{0, ±w}`), which **under-emits and leaves white seams** when `radius > w/2`. The fix (grid/half-drop/brick) emits a placement for **every** integer lattice offset (`i·w, j·h`) whose shifted footprint overlaps the canonical tile. The tight, over-emission-free integer bounds per axis:

```text
i_min = floor(-maxX / w) + 1
i_max = ceil((w - minX) / w) - 1
```

This is identical to the old `{0, ±w}` behavior for small dabs but covers many tiles for large ones. The tight (open-interval) form deliberately avoids the naive floor-form's spurious zero-overlap copy at exact tile-multiple boundaries. The identity offset (`0,0`) is always in range (a folded center always overlaps its own tile), preserving the "placements are never empty" contract.

Cost is bounded by a radius cap: `cappedRadius = min(R, tileMin * 4)`, so `R/tileSize ≤ 4` (≤ 81 copies/dab), preventing an O(R²) blowup. `tileMin` is the smaller tile dimension so the bound holds on both axes.

### Known limitations (intentional)

* **Mirror / `p2` large-brush seam.** Mirror and `p2` storage emit only the immediate **±1 reflected/rotated neighbour**, so they are seamless only for `radius ≤ one tile`. Since the radius cap allows up to 4·tile, a brush wider than one tile under mirror/`p2` may seam at the **second symmetry line**. Grid/half-drop/brick handle arbitrarily large brushes. Full multi-image mirror/`p2` enumeration is the natural follow-up; bounded and acceptable for v1 given the cap.
* **Square tile texture.** The canonical texture is allocated square at `tileSize.x`. Non-square tiles paint correctly (canonical coords carry both dims) but the texture is square; keep tiles square in the UI for v1 (trivial follow-up otherwise).
* **Resample stretches content.** Changing tile size scales existing art to fill the new tile rather than revealing blank space (the chosen resample semantics).

### Open design question — cross-tiling reuse breaks committed content

Switching the tiling *after* drawing re-samples the existing committed canonical tile under the new fold — but the stored content carries edge-wrap + parity completions tuned to the *drawing* tiling's phase. A stroke drawn under half-drop (column phase) then viewed as brick (row phase) shows **broken seams** (each tiling on its own is fine). This is not a renderer bug: a single canonical tile's wrap geometry is fold-specific, and commit discards the originating world-space strokes (emit-and-forget), so there is nothing to re-fold from. Verified with the harness `--tiling-switch` scene (half-drop view seamless, brick view broken).

Two futures, decide later: **(A)** keep re-sample-as-is (current; fast, old strokes can look broken under a new tiling), or **(B)** re-fold on switch (seamless, but requires retaining the original world-space strokes — a retained/vector stroke model, which the roadmap defers indefinitely as a brush-era decision once the dab schema is stable). Tile-size change already resamples; tiling change does not re-fold.

### Verification

* **Engine unit tests (headless, `swift test`):** per-group storage folds (grid, half-drop, brick, mirror x/y/both, rotational), the large-brush enumeration (multi-tile span, exact-boundary non-over-emission, identity-always-present, corner placement-count product), the radius cap, and the Swift<->MSL fold-parity tests. `p2` tests assert rotated-center placement and fold values but **never** edge continuity.
* **GPU / on-device (human):** per-tiling visual check that each repeat matches its group, that mid-session tile-size changes resample seamlessly, that a large grid brush shows no seams, and that the live preview matches the committed result (a mismatch means the MSL `foldCanonical` case and the strategy's `worldToCanonical` have drifted).