# Half-drop / brick edge-dab clipping (FIXED + VISUALLY CONFIRMED — symmetric clip, 2026-06-28)

**Status (2026-06-28):** FIXED, VISUALLY CONFIRMED, merged to main. Symmetric half-plane clip. User confirmed 2026-06-28 the phantom "4th dot" is GONE in a fresh build with the fix (the prior screenshot was from a build predating it). 109 engine tests pass; macOS + iOS Xcode builds green; `FoldParityRegressionTests` / `TilingFoldParityTests` byte-for-byte untouched (no fold change).

The mental model the user gave (the decisive framing): a dab on the right edge with 80% inside the tile and 20% past the seam should store the 80% where drawn PLUS just the 20% sliver folded to the lower-left (the odd column's -h/2 phase) — "that's it", no extra disks. The fix exactly this: verified in canonical space the stored tile is PIXEL-IDENTICAL to the literal per-pixel fold of the world disk (0 phantoms, 0 holes) for on-seam, 80/20-edge, interior, and near-edge cases.

**NB (test-harness lesson):** while chasing this, an earlier screen-space verification harness used a SIGN-FLIPPED half-drop orbit (odd columns at +h/2 instead of -h/2) and falsely reported phantoms. The TRUE orbit, read straight from `worldToCanonical`: for a source point, even columns repeat at (±2i·w, j·h); odd columns at (±(2i+1)·w, j·h - h/2). Validate storage by comparing IN CANONICAL SPACE against the literal fold (truth = {fold(p) : p in world disk}), never via a hand-derived orbit — the fold is the only source of truth and a hand orbit is easy to get wrong.

This supersedes BOTH earlier attempts. The arc:

1. `f005ebe` (2026-06-23) stored a FULL completion disk at the other parity -> killed the half-circle holes but OVER-CORRECTED into a phantom "4th dot" (the completion disk's cross-seam half is -75% phantom).
2. 2026-06-25 diagnosis (workflow `wf_8e6d933d-785`) correctly concluded the cheap "drop a lobe" fix is geometrically impossible and that a CLIP is required — but framed it as clipping ONLY the completion disk.
3. 2026-06-27 (this fix): the clip must be SYMMETRIC. A design workflow (`wf_5ba71413-1b5`) specified a unit-quad clip on the completion. During implementation, an independent numeric check found the PRIMARY disk has the exact same phantom (its cross-seam lobe folds to the other parity row — verified: `fold(300,144)=(12,0)`, NOT y=144). A second workflow (`wf_bb826fce-d83`) re-derived and confirmed: BOTH the primary and the completion must be clipped to complementary half-planes on the crossed seam. With both clipped, a strict integer oracle gives 0 holes AND 0 phantoms on every case (half-drop + brick).

## The fix (decided + verified)

A round dab carries an optional `DabClip { axisIsX, threshold, keepGreater }` in unit-quad space (local ∈ [-1,1]², the dab corner coord). The clip keeps one side of `local.x = threshold` (half-drop) or `local.y = threshold` (brick). Unit-quad space is the key choice: the clip is copy-invariant under the ±tile lattice wrap copies (every copy regenerates the same local from its translated center), so the same `DabClip` rides every copy with NO per-placement math.

On a phased-seam straddle (gated `straddle && r < tile/2`), with `K = floor((wx-r)/w)+1`, `seam = K·w`, `threshold = (seam - wx)/r`, `centerCol = floor(wx/w)`:

*   **Completion** keeps the OTHER column's half: `keepGreater = (centerCol < K)`. (NOT the naive `wx <= seam` — that keeps the phantom on-seam with an odd center column. `centerCol < K` is correct for every sub-case, verified numerically.)
*   **Primary** keeps the CENTER's half = exact complement: same `axisIsX` + `threshold`, negated `keepGreater`.
*   Brick `.row` is the exact transpose (x↔y, w↔h; `axisIsX = false`).

`r >= tile/2` (large brush): BOTH clips are `nil` (full disks). A single completion is already geometrically insufficient when the footprint spans >1 seam (pre-existing limitation); clipping would regress, so we keep the pre-existing full-disk behavior — a strict no-regression. The phantom reappears only for large brushes, by design (documented limitation, tracked follow-up).

Corner straddle needs only the SINGLE phased-axis half-plane; the orthogonal tile edge is handled by the ordinary lattice wrap (verified 0/0).

## Implementation (files)

*   **Engine:** `DabSpec.clip: DabClip?`; `TilingStrategy.primaryClip(worldCenter:radius:)` (default nil) -> `parityCompletions(...)` -> `[ParityCompletion]` (replaces `parityCompletionCenters`, carries a per-disk clip); `HalfDropStrategy.seamClip`/`primaryClip`/`parityCompletions` share one seam derivation; `StrokeSession.emit` attaches the primary clip to every primary placement and `pc.clip` to every completion placement.
*   **GPU:** `DabInstance` (ShaderTypes.h) gains `clipThreshold` + `clipMode` (0=none,1=x≤,2=x≥,3=y≤,4=y≥) + 2 pads -> 32-byte stride; Swift `Dab` mirrors it; `Dab(canonical0f:)` maps `DabClip` -> mode; `dab_fragment` does an inclusive-predicate `discard_fragment()` outside the clip (no-clip fast path for mode 0; round falloff unchanged); `SpikeRenderer.init` asserts the strides match.
*   **Tests:** `EdgeDabParityTests` rewritten as a two-directional 0-holes-AND-0-phantoms property oracle (CPU mirror of `dab_fragment`), replacing the phantom-blind holes-only test that enshrined the bug. Plus structural tests (complement invariant, sign rule incl. on-seam-odd, large-brush clip==nil, gating, brick transpose, grid no-clip).

## OPEN: human visual check before merge

Data-level + build are green, but the GPU `discard_fragment` end-to-end could not be pixel-verified in the agent session (no Screen Recording / Accessibility permission; screencapture denied). Manual check: `scripts/start.sh edge-dab-clip`, press 2 (half-drop), draw a single dab on a vertical tile edge -> expect ONE dab per tile, no stray 4th dot. Then merge to main (ff-only from the main checkout) and update the project-status note.

(Below: the original 2026-06-23 diagnosis + the 2026-06-25 CORRECTION, kept for the reasoning. NB: the 2026-06-25 framing of "clip the COMPLETION disk" was INCOMPLETE — the PRIMARY needs the complementary clip too, as above.)

Original status (superseded): FIXED on main (commit `f005ebe`, 2026-06-23). Diagnosed + verified by workflow `wzvt2o82b`; implemented via the encapsulated `TilingStrategy.parityCompletionCenters` seam (default [], overridden only by `HalfDropStrategy`) plus a `positiveMod` helper, wired into `StrokeSession.emit`. 7 data-level.regression tests in `EdgeDabParityTests.swift`; 99 tests pass, macOS + iOS build green; `FoldParityRegressionTests` unchanged. The notes below are the original diagnosis, kept for the reasoning.

## Symptom (user repro)

Draw a single dab centered ON a vertical tile edge (e.g. world x = w) under half-drop. Expected: a full circle in the stored tile, which then replicates per tiling. Actual: a-half-circle (the dab is clipped to one side), and that half-circle is what tiles.

User's framing (the correct mental model): "When I'm making a dab on the edge, what I expect is a full dab. After that, however that dab is replicated as per tiling is a different problem." The bug is in storage, before replication — we store half a disk.

## Root cause

Half-drop stores one canonical tile but samples it with a per-column phase:

*   EVEN world-x columns sample canonical row (y mod h).
*   ODD world-x columns sample canonical row ((y - h/2) mod h).

A dab whose footprint straddles a column boundary x = k·w has half its footprint in an even column and half in an odd column. Those two halves therefore read canonical rows that are h/2 apart. But `StrokeSession.emit` folds only the dab's center (one parity) and stamps a single disk at that one row. The other parity's row holds no ink there -> that half is absent on screen -> half-circle.

Worked example (tile w=h=288, dab world (288,144), r=38):

*   Center folds: `cellX = floor(288/288) = 1 (ODD)` -> canonical center (0,0) (odd-parity row 0).
*   ODD columns (world x ∈ [288,326]) sample row 0 -> see the disk √.
*   EVEN columns (world x ∈ [250,288]) sample row 144 -> no disk there x -> right half missing.

Grid does NOT have this bug: grid has no parity phase (all columns sample `y mod h`), so the existing `tw` lattice wrap copy completes the disk across the seam in the same row.

## Verified fix (belongs in StrokeSession.emit, storage-only)

**Principle (invariant):** the stored tile T must contain a COMPLETE disk for every column parity the dab's world footprint touches. A dab confined to one parity needs one disk (current behavior — correct). A dab straddling a column boundary touches both parities, so T must also hold the disk at the other parity's row = center shifted by ±h/2 in Y (half-drop) / ±w/2 in X (brick).

Where: in `Sources/PatternEngine/StrokeSession.swift`, the `worldPoints.map` closure (–lines 69-87), per world point, AFTER computing hit / canonical center c / radius:

1.  Keep the existing primary expansion: `bounds = c ± radius; placements = tiling.wrapPlacements(forCanonicalBounds: bounds)` -> `DabSpec` (unchanged), `isPrimary=true` for the (0,0) placement.
2.  Detect axis-specific straddle from the WORLD point + radius + tile period (info only emit has — see "Why emit, not wrapPlacements" below):
    *   half-drop (axis .column): `strX = floor((world.x - r)/w) != floor((world.x + r)/w)`
    *   brick (axis .row): `strY = floor((world.y - r)/h) != floor((world.y + r)/h)`
3.  If straddling, compute the OTHER-parity completion center, reduced into the tile BEFORE wrapping (the mod is LOAD-BEARING — see holes below):
    *   half-drop: `c2 = Point(c.x, (c.y + h/2).mod(h))`
    *   brick: `c2 = Point((c.x + w/2).mod(w), c.y)` Then call `tiling.wrapPlacements` a SECOND time around c2 (`bounds = c2 ± r`), map to `DabSpec` with `isPrimary=false`, and union with the primary set.
4.  All copies keep the same radius/alpha.

This is purely additive to STORAGE placements. It does NOT touch `worldToCanonical` or the MSL `foldCanonical`, so sampling / fold parity is untouched (`FoldParityRegressionTests` stay green).

## Worked fix output (288,144,r38, tile 288)

*   Odd-parity center (0,0) lattice-wrapped -> {(0,0), (288,0), (0,288), (288,288)}.
*   Even-parity completion center (0,144) lattice-wrapped -> {(0,144), (288,144)}.
*   6 disks total. Sweeping all 18125 footprint pixels through the real fold: MISSING = 0 (was ~8986 ≈ half before fix).

## Why emit, not wrapPlacements

`wrapPlacements` receives only `CanonicalRect` bounds in [0,w)x[0,h). The fold already collapsed world x into [0,w) and discarded which cell/parity the center came from (canonical (0,0) is identical whether it came from world x=0 even-col or x=288 odd-col). So `wrapPlacements` cannot recover the straddle; adding a ±h/2 copy there unconditionally would double every dab and recreate/worsen the horizontal-line phantom. Clean split: `emit` owns the world→parity decision (only it holds world + tile size + strategy axis) and calls the parity-agnostic `wrapPlacements` twice. (Equivalent acceptable refactor: add a strategy method that takes the WORLD center+radius and returns the full parity-aware center, pushing the `.column-vs-.row` axis decision into `HalfDropStrategy`.)

## Why it does NOT worsen the horizontal-line phantom

The completion copy fires only when the footprint genuinely straddles a boundary. An interior dab — even centered in an odd column — spans a single parity, so all its columns read the same row; it gets exactly one disk and NO ±h/2 copy. The gate is load-bearing in both directions. The fix adds ink only for the ≤2r-wide band of dabs sitting on a seam — exactly the set currently rendering as half-circles.

## Verification holes the implementer MUST honor (not defects, design notes)

1.  **mod-then-lattice:** the completion center must be reduced mod h (mod w for brick) BEFORE lattice-wrapping. `c2y = (ly + h/2) mod h`, NOT raw `ly + h/2`. With `ly=0` the naive `+h/2 = 144` is harmless, but `ly=288 -> 344`, out of [0,288), would be CLIPPED by `CanonicalRaster` (no modulo) before its `+w` wrap fires -> bug persists for lower-half folds. Verified: dab (576,200) needs completion at `y=56` (`= (200+144) mod 288`).
2.  **Gate on footprint-crosses-boundary, NOT center-in-odd-cell:** adjacent cells k and k+1 are always opposite parity, so `floor((wx-r)/w) != floor((wx+r)/w)` must fire at EVERY `k·w` (verified at x=288 cell0|cell1 AND x=576 cell1|cell2). Gating on "center in odd cell" would miss even-cell-side straddlers.

## Regression tests to add (data-level, no GPU)

1.  **Half-drop edge straddle is whole:** tile 288, dab (288,144) r38 -> stamped centers == {(0,0), (0,288), (288,0), (288,288), (0,144), (288,144)}; every footprint pixel folds inside ≥1 stamped disk (0 missing). Pre-fix: only the 4 odd-parity disks, ~half missing.
2.  **Half-drop interior dab gets NO parity copy:** dab (144,144) r38 (single cell 0) -> straddleX=false -> exactly the primary set, no disk at 144±144. Also (432,144) r38 (single cell 1, odd) -> no +h/2 copy; its 2 disks are the legit y-edge wrap, not parity.
3.  **Half-drop horizontal line not worsened:** dabs at y=144, x∈{100,150,200,250,288,300,350, 432,500,576} -> straddleX true ONLY for {250,288,300,576} (within 38 of a mult of 288).
4.  **Completion-center mod is load-bearing:** dab (576,200) r38 -> completion center MUST be 56, giving {(0,200), (288,200), (0,56), (288,56)}; assert it's in [0,h).
5.  **Straddle fires at every k·w regardless of parity:** predicate true at x=288 AND x=576.
6.  **Brick transpose:** tile 288, dab (144,288) r38, axis .row -> centers == {(0,0), (0,288), (288,0), (288,288), (144,0), (144,288)}; 0 missing. Interior brick dab (144,144) -> straddleY=false -> no +w/2 copy.
7.  **Grid unchanged:** GridStrategy dab (288,144) r38 -> NO parity completion; placement set is exactly the existing {(0,144), (288,144)} (matches WrapCommitTests).
8.  **Fold parity untouched:** `FoldParityRegressionTests` still pass byte-for-byte (we edit neither `worldToCanonical` nor `Shaders.metal` `foldCanonical`).

## Also fix while here

*   The misleading comment in `HalfDropStrategy.wrapPlacements` (~lines 48-51) claiming the per-column phase is "a SAMPLING concern, not a storage one" and the canonical tile is "seamless under ±tile translation" — proven incorrect by this workflow. The storage DOES need parity-aware completion for straddling dabs.

## Known unrelated typo (do not touch as part of this)

*   `FoldParityRegressionTests` case-2 MSL comment has a transcription typo `lx -= floor(lx/tile.x)*lx` but the executed Swift `msfFold` uses `*t.x` correctly. Cosmetic.