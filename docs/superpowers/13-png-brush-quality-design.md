# PNG Brush System + Procreate-style Grain + Editor — Design Spec

**Date:** 2026-07-04 **Status:** Approved (brainstorming) — next: implementation plan (writing-plans). Follows: the raster-brush system (12-raster-brush-design.md), DONE on main tip `fd2c932`.

---

### Context
The raster-brush system shipped and works, but the built-in brushes feel flat/unprofessional. Root cause: the textures are minimal procedural placeholders – two analytic round shapes and grain made from summed sinusoids (which band into a visible interference grid, not paper/graphite tooth) – and the grain is stretched to cover one full tile (`canonicalUV = center / tileSize` in the Task-4 shader), so on a large canvas it blurs. Two of the four presets use grain/scatter/rotation; the dynamics are tuned mild.

User direction (this session): the end goal is PNG-based brushes, so build the real PNG-asset pipeline now; seed it with 1-2 generated PNGs so it looks good today and drop in more art later. Grain must stay crisp at the canvas sizes actually used – 1024² and up to 4K. Reference tool; Procreate, which does NOT stretch grain to the canvas – grain has a fixed Scale (density) and repeats like a paint roller, staying consistent regardless of canvas size (Procreate Handbook – Brush Studio Settings).

---

### Goal
Move brushes onto a real PNG-asset pipeline (with graceful procedural fallback), replace the weak grain/shape generators with high-quality ones, adopt Procreate's fixed-density repeating-grain model so grain stays crisp at any canvas size, retune the 4 built-in presets to feel professional using the already-wired dynamics, and add a per-parameter brush editor. NO new engine capability (no dual-brush, no per-dab size/opacity jitter) – this is texture content + one grain-sampling change + tuning + UI.

---

### Non-goals (deferred)
*   User-authored brush art in this change (the pipeline accepts it; only 1-2 seed PNGs are generated now).
*   Saving custom brushes to disk / a brush library format.
*   Dual-brush, per-dab size/opacity jitter, or any new `DabInstance`/shader capability.
*   The moving grain mode's seamless wrap across the tile seam (already a documented limitation).

---

### Architecture
Two coordinated changes riding the EXISTING shape x grain x alpha dab shader (Task 4). The dab pipeline, tiling fold, wrap-placement, snapshot-undo, and WYSIWYG-commit seams are UNCHANGED.

#### (A) PNG-asset pipeline with procedural fallback
*   `BrushPreset` gains optional `shapeAsset: String?` and `grainAsset: String?` (asset NAMES).
*   A new `BrushTextureResolver` (MetalRenderer) resolves a name -> `MTLTexture`:
    1.  name present + image found in `Assets.xcassets` -> load grayscale PNG -> `.r8Unorm` (via `CGImage` -> single-channel bytes -> `MTLTexture.replace`; works on iOS + macOS, no `MTLTextureLoader` dependency needed for r8 grayscale).
    2.  name present but NOT found -> procedural fallback (the existing generator) + a one-time `os_log`/print warning naming the missing asset.
    3.  name nil -> procedural fallback (the current enum path).
*   `SpikeRenderer`, `setBrushTextures` is extended to accept optional asset names alongside the enum (the enum remains the fallback generator selector). The resolver is the single load point; the two texture slots (`shapeTex`, `grainTex`) and the shader binding are unchanged.
*   Seeded now (generated -> committed PNGs in `App/PatternSpike/Assets.xcassets`): `grain-paper` (1024²) and one textured tip (512²). As built: only `grain-paper` is actually referenced (by Chalk); tip is committed but unreferenced (no preset sets `shapeAsset` – see `BACKLOG.md`). Any preset referencing a missing asset name falls back to procedural rounds – nothing looks broken.

#### (B) Procreate-style fixed-density repeating grain
*   Change grain sampling from stretch-to-tile to fixed-density repeat. In `dab_fragment` the texturized-grain UV becomes `canonicalPosition / grainScale` sampled with a `.repeat` sampler (a new dedicated grain sampler; the shape keeps its `.clampToEdge` brush sampler). `grainScale` is a new per-brush field on `BrushPreset`, and a new per-stroke uniform `float grainScale` appended to `SpikeUniforms` – analogous to the existing per-stroke `strokeOpacity` and `dabFlags` (grain mode), set once via a new `SpikeRenderer.setGrainScale(_:)`. It is NOT a per-dab `DabInstance` slot (grain scale is constant per stroke, like opacity). `BrushParams` does not need it (it's not an emit dynamic – the shader consumes it directly).
*   The grain sampler is a NEW dedicated `.repeat` sampler stored on `SpikeRenderer`, bound at `[[sampler(1)]]` on the dab passes; the shape keeps the existing `.clampToEdge` `brushSampler` at `[[sampler(0)]]`. (Today both shape and grain share `BrushSampler`; grain must move to `.repeat` so `canonicalPosition / grainScale` wraps.)
*   Result: grain density is CONSTANT in canvas space, so a 1024² paper grain repeating every ~256 canvas-px stays crisp at 256, 1024, or 4K+ tiles – matching Procreate. The moving grain mode is unaffected (still stroke-local; still not seam-tiling – documented limitation).
*   Seamless-wrap invariant: the grain texture must tile seamlessly (its period wraps) AND `grainScale` should divide evenly into the tile size for the texturized grain to stay seam-free across the pattern wrap. Generated grain is authored tileable; the harness `brush-grain-texturized` seam assert guards that the repeat-UV change did not break the wrap seam.

---

### Resolution standard
*   **Shapes:** 512². Tips are drawn at brush-radius px (a few hundred px at most, even for big brushes), independent of canvas size – 512² is ample.
*   **Grain:** 1024², tileable.
*   **User-supplied PNGs:** grayscale, square, power-of-two (256-1024). The resolver tolerates other sizes (loads them, logs a warning); non-tileable grain will visibly seam (documented). Shape PNGs must have -zero coverage at the border (the `.clampToEdge` sampler would otherwise show a hard square edge).

---

### Better generators + retuned presets

#### Generators (BrushTextures, also used to bake the seed PNGs)
*   **Grain** — multi-octave value noise replacing summed sinusoids: a hashed integer lattice, bilinearly interpolated, 3-4 octaves, wrapping on the texture period (integer lattice -> exactly tileable, so `.repeat` has no seam). Variants: `paper` (soft low-frequency tooth), `canvas` (coarser weave), `noise` (fine speckle for pencil).
*   **Shapes** — beyond round: keep `softRound`/`hardRound`; add `tapered` (soft with a denser core, ink-like) and `chisel` (flattened/elliptical for calligraphic edges). SDF + falloff; border-safe for `.clampToEdge`.

#### Retuned built-in presets (all via existing BrushParams knobs + new grainScale)

| Preset | Shape | Grain | Key dynamics |
| :--- | :--- | :--- | :--- |
| **Soft Airbrush** | softRound | none | low flow (~0.4), soft pressure->flow, mild streamline. Gentle buildable spray. |
| **Hard Ink** | tapered | none | high flow, strong pressure->size taper, pressureFlow off, tight spacing. Crisp inking line that tapers with pressure. |
| **Chalk** | softRound | paper (seed PNG `grain-paper`), grainScale 256 | random rotation + slight scatter (0.1), pressureCurve 1.5, opacity 0.9. Dry chalk tooth varying dab-to-dab. |
| **Pencil** | hardRound | noise (procedural, no PNG), grainScale 128 (fine) | follow-direction rotation, small size (6), steep pressureCurve (2.0), slight scatter (0.05). Grainy graphite. |

*   As built (exact): the retune landed on tile-dividing `grainScale` values – Chalk 256, Pencil 128 (the ~200/~120 here were the pre-implementation intent; a round-3 review changed them to divide the default 256 tile for seam-safety). Chalk uses the `grain-paper` seed PNG; Pencil uses procedural `.noise`, not a PNG (only `grain-paper` is asset-backed – the committed tip PNG is unreferenced, see `BACKLOG.md`). Every built-in's full parameter set is pinned in `16-reference-sheet.md`.
*   Chalk/Pencil showcase the fixed-density grain; Ink showcases shape + taper; Airbrush is the clean control.

---

### Per-parameter brush editor UI
A panel (disclosure/popover from a toolbar "Brush settings" button, shown for the draw tool, beside the existing preset row + flow/opacity sliders) exposing every `BrushPreset` field. Editing writes through clamping `EditorModel` actions (one-way flow, same as `setBrushFlow`), so nothing goes out of range; the renderer/session pick up changes on the next `apply()`.

**Fields (grouped):**
*   **Tip:** shape (picker: soft/hard/tapered/chisel), size, spacing, hardness.
*   **Grain:** grain (picker: none/paper/canvas/noise), grainMode (texturized/moving), grainScale, scatter.
*   **Dynamics:** flow, opacity, pressureSize (toggle), pressureFlow (toggle), pressureCurve, rotationMode (fixed/followDirection/random), streamline.

**Editing model:** edits mutate `activeBrush` in place. When `activeBrush` no longer equals any built-in, the preset row shows "Custom". Selecting a built-in resets `activeBrush` to it (discarding edits). No persistence (session-lived); saving custom brushes is deferred (the data model supports it later).

**New EditorModel setters** (each clamps + mutates only `activeBrush`): `setBrushShape`, `setBrushGrain`, `setBrushGrainMode`, `setBrushGrainScale`, `setBrushHardness`, `setBrushSpacing`, `setBrushScatter`, `setBrushPressureCurve`, `setBrushPressureSize`, `setBrushPressureFlow`, `setBrushRotationMode`, `setBrushStreamline` (plus existing size/flow/opacity).

---

### Verification

#### Unit (swift test, pure – no GPU)
*   **Value-noise grain tileability** – opposite-edge rows/columns of the generator output match within tolerance (the load-bearing property enabling `.repeat` with no seam).
*   **New EditorModel setters** – each clamps to range and mutates only `activeBrush` (guard tests, mirroring the Task-6 size/clamp tests).
*   **"Custom" detection** – `activeBrush != any builtin` after an edit; `== builtin` after selecting one.
*   **BrushTextureResolver decision logic** – name-nil -> procedural, name-missing -> procedural (the resolver's decision is pure/testable; the actual PNG decode needs a device and is covered by the harness).

#### GPU harness (render-to-PNG; extends the 14 existing scenes)
*   **Regression:** the 14 existing scenes stay OK. They set no asset names and default `grainScale`, so the texturized path must still tile seamlessly under the new `.repeat` sampler – the existing `brush-grain-texturized` seam assert guards this. If the repeat-UV change breaks the wrap seam, that scene fails (a real bug, not to be loosened).
*   **brush-grain-scale (new)** – a grained stroke on a large tile (e.g. 1024): assert grain shows fine variation (adjacent canonical points differ -> crisp, not blurred) + seam continuity across the wrap. Proves fixed-density crispness at large canvas.
*   **brush-tapered-tip (new)** – the tapered/chisel shape renders with its distinct silhouette (denser core / flattened edge vs. the round). Proves the resolver's REAL PNG path (the seed PNG is committed fixed bytes -> reproducible), not just the fallback.
*   **brush-png-asset (new)** – bind `grain-paper` by ASSET NAME; assert it loads and shows grain variation (ink present + adjacent points differ).

#### Live-only (user-verified)
Actual feel: does Chalk read as chalk, does Ink taper nicely, does grain stay crisp when the canvas is enlarged/zoomed, does the editor panel feel good. The harness proves pixels; feel is the user's.

---

### Build gate
macOS + iOS `xcodebuild` succeed; full `swift test` green; `--render-harness --all` all-OK – the same three-layer gate used for the brush system.

### Known limitations (intentional, documented)
*   Moving grain does not tile seamlessly across the wrap seam (stroke-local frame) – unchanged.
*   Non-tileable user grain PNGs will seam – the resolver loads them but can't make them tileable.
*   `grainScale` not dividing the tile size can introduce a wrap-seam discontinuity for texturized grain – presets use seam-safe values; the editor allows arbitrary values (user's choice).
*   Custom (edited) brushes are session-lived; no disk persistence in this change.

### Build order (for the implementation plan)
1.  `BrushTextureResolver` + grayscale-PNG -> `.r8Unorm` load + procedural fallback (+ asset-name on `setBrushTextures`); no behavior change yet (no preset sets an asset name).
2.  New generators: multi-octave value-noise grain (tileable, unit-tested) + tapered/chisel shapes.
3.  Fixed-density repeating grain: `grainScale` on `BrushPreset` + a per-stroke `SpikeUniforms.grainScale` (via `setGrainScale`) + a new dedicated `.repeat` grain sampler at `[[sampler(1)]]` + the `dab_fragment` grain-UV change (`canonicalPosition / grainScale`); regression-guard the wrap seam.
4.  Bake + commit the seed PNGs (`grain-paper` 1024², `tip` 512²) into `Assets.xcassets`.
5.  Retune the 4 presets (asset names where seeded, `grainScale`, dynamics).
6.  `EditorModel` setters + "Custom" detection (unit-tested).
7.  Editor UI panel (toolbar, draw-tool-gated).
8.  Harness scenes (`brush-grain-scale`, `brush-tapered-tip`, `brush-png-asset`) + unit tests; full gate.

Each step is independently unit- or harness-verifiable; the pipeline + grain model (1-4) land before the tuning/UI (5-7).