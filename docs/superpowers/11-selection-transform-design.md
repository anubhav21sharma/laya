# Selection + Transform — design spec (drawing-tools step 4)

**Status:** DESIGN (approved 2026-07-02). Brainstormed from the drawing-tools roadmap (`docs/superpowers/07-drawing-tools-roadmap.md`) + the live-tile/ephemeral-layer note (`docs/superpowers/notes/2026-06-22-live-tile-perf-promotion-undo.md`). Implementation plan follows.

## Purpose

Step 4 of the drawing-tools roadmap. Its **real job is to install the reusable seams the raster brush (step 5) inherits**, with a rectangular selection tool as the cheapest client that exercises them:

1.  **Affine textured-quad through a vertex matrix** — one textured quad whose 4 corners are multiplied by a `float3x3` in a vertex shader. This IS the raster brush’s textured-stamp primitive (build once, brush inherits). The fast round-dab path is left untouched.
2.  **A real `canonical-world` API** — promote the implicit `canonicalPoint` + `cellSize` scattered through placement code into a named method on the tiling strategy.
3.  **A shared provisional render channel** — a third texture the tiling shader composites over `canonical+live`. The selection draft is its first client; the brush’s predicted-touches/lookahead is the second (per the live-tile note, generalized).
4.  **Region extract + transformed composite** — `CanonicalRaster` gains "blit a sub-rect out to a texture" and "composite a transformed texture back in at the commit seam".

**Non-goals for v1 (deferred):** warp/perspective/distort, lasso/freeform selection, feathering, selections that cross a tiling fold boundary, cut/copy toggle (v1 is always cut), multi-region selection, sub-stroke undo granularity.

## Scope (settled decisions)

*   **Rectangular selection in `CANONICAL` space**, clamped to the central tile `[0, tileSize]^2`. The spike renders the central tile only (Shaders.metal `dab_vertex` TODO: "apply tiling cell transform here"), so working in canonical space sidesteps the fold-boundary problem entirely. Cross-fold selection is a documented deferred limitation (analogous to the mirror/p2 radius cap).
*   **Transforms: move + scale + rotate**. Composed as a single affine about the selection center.
*   **Lift model = CUT on enter, composite on confirm**. Entering transform snapshots canonical (undo), extracts the region into a `selection` texture, then CLEARS the source rect in canonical (it goes blank). Confirm composites the transformed selection at its new place. Moving genuinely relocates pixels; it is not a duplicate.
*   **Two tool modes: `.select` (define the rect) then `.manipulate`**. Added to `EditorModel.Tool` (currently `.draw`/`.erase`).
*   **Interactive handles + a scriptable matrix seam**. Handles (drag inside = move, corner = scale, outside-corner = rotate) compute-and-set an affine; the affine is set through a plain renderer setter fed from `EditorModel`/the view. The render harness scripts the SAME affine directly, so the transform MATH + extract/composite are fully headless-proven; the interactive handles are the manual-only check.

## Architecture

### New / changed units

**`Sources/MetalRenderer/SelectionLayer.swift` (NEW)** — mirrors `LiveTile`’s shape (pure GPU bookkeeping). Owns:
*   `provisional`: `MTLTexture` — tile-sized, `bgra8Unorm`, the shared provisional channel. Cleared and repainted every gesture; sampled by the tiling pass; empty (and zero-cost) when no transform is active.
*   `selection`: `MTLTexture?` — the lifted region’s pixels (allocated at the selection rect's pixel size on enter, `freed` on `confirm`/`cancel`).
*   API: `lift(from canonical:, rect:, queue:)` -> `Void` (blit sub-rect into `selection`); `renderProvisional(affine:, rect:, viewport-free canonical mapping, queue:)` (clear `provisional`, draw the transformed selection quad into it); `clear()` (drop `provisional` contents + `selection`). Exact method names finalized in the plan; shape mirrors `LiveTile.stampNew`/`reset`.

**`Sources/MetalRenderer/Shaders.metal` (MODIFY)**
*   `selection_vertex` / `selection_fragment` (NEW pair): vertex takes a `float3x3 selectionAffine` + the selection rect (canonical origin/size) via a uniforms struct; emits A - corner mapped through the viewport to clip space exactly as `dab_vertex` maps (canonical→world→screen→clip); passes a 0..1 UV. Fragment samples the `selection` texture bilinearly, returns premultiplied RGBA (matching the premultiplied-alpha pipeline note). No change to `dab_vertex`/`dab_fragment` (round path preserved).
*   `Tiling_fragment` (MODIFY): add `texture2d provisional [[texture(2)]]`; composite `provisional` over `live` over `canonical` gated by a new "hasProvisional" uniform bit (a free bit alongside the existing gridlines `0x10000` and erase `0x20000` flags - exact value chosen in the plan) so it's a no-op when absent. Blend uses source-over with premultiplied inputs (`out = prov + base * (1-prov.a)`), consistent with the existing live-over-canonical branch.

**`Sources/MetalRenderer/CanonicalRaster.swift` (MODIFY)** — two methods:
*   `extractRegion(_ rect: PixelRect, queue:)` -> `MTLTexture` — blit the canonical sub-rect into a new texture sized to the rect (for `SelectionLayer.selection`).
*   `clearRegion(_ rect: PixelRect, queue:)` — clear the source rect to transparent (the "cut").
*   `compositeTextured(_ tex: MTLTexture, affine: float3x3, queue:)` — render the same transformed textured quad into `texture` (`loadAction .load`, source-over) at confirm. This is the undoable commit-seam mutation; undo already snapshots before it via the enter-transform snapshot. (Extract/clear/composite may share a small `PixelRect` helper; names finalized in the plan.)

**`Sources/MetalRenderer/SpikeRenderer.swift` (MODIFY)** — owns a `SelectionLayer`; new API:
*   `beginTransform(canonicalRect:)` — stash the pre-transform canonical into a dedicated `transformRestore` texture (a full-tile blit, held only while a transform is active — NOT pushed to the `UndoHistory` ring yet; the undo entry is created at confirm), lift the region into `selection`, clear the source rect, reset affine to identity, mark provisional active. Keeping the cancel-restore separate from the undo ring means cancel never has to manipulate ring internals.
*   `setSelectionAffine(_ a: float3x3)` — update the affine; re-render provisional. THE SCRIPTABLE SEAM.
*   `confirmTransform()` — push the stashed `transformRestore` (the pre-transform full-tile state) onto the `UndoHistory` undo ring so undo returns to pre-transform, then `compositeTextured` the selection into canonical, release the stash, clear provisional + selection, mark inactive. Nothing is pushed to the undo ring (cancel fully restored, so it is not itself undoable — see the rulings).
*   `cancelTransform()` — blit the `transformRestore` stash back into canonical, release the stash, clear provisional + selection + inactive. (Nothing is pushed to the undo ring.)
*   `resetSelection()` — used on tool-switch-away / tile-size / tiling change (implicit cancel; also resets history like the existing tile/tiling reset).
*   The draw loop stamps the provisional layer (if active) and passes it as `texture(2)` with the `hasProvisional` bit set.

**`Sources/PatternEngine/tiling strategy` (MODIFY)** — add `func canonicalToWorld(_ p: Point, cell: SIMD2<Int>)` -> `Point` to the `TilingStrategy` protocol + all 5 implementations (grid, half-drop, brick, mirror, rotational). It is the inverse of `worldToCanonical`. For v1 the selection is in the central cell `(0,0)` so it reduces to identity, but the API is installed and round-trip tested. (The affine math itself lives in a small `Sources/PatternEngine/Affine.swift` value type — `float3x3` builders for translate/scale/rotate-about-center — so it’s headless-unit-testable.)

**`Sources/EditorCore/EditorModel.swift` (MODIFY)** — Tool gains `.select`, `.transform`; `confirmTransform`/`cancelTransform` edge-triggered `CommandToken`s (the `clearToken`/`undoToken` idiom).

**`Sources/EditorCore/EditorKeymap.swift` (MODIFY)** — `s` -> `.select`, `t` -> `.transform`; Return -> `confirmTransform`, Escape -> `cancelTransform` (via the plain char/again-modifier-aware router as appropriate).

**`App/PatternSpike/PatternCanvasView.swift` (MODIFY)** — phase state (view-local, like `session`): `selectionRect: CGRect?` (canonical), transform-active flag, handle hit-testing. `.select` drag builds the rect (clamped); entering `.transform` calls `spike.beginTransform`; `.transform` gestures recompute the affine and call `spike.setSelectionAffine`; `confirm`/`cancel` drive the renderer. Fires the existing `onHistoryChanged` after confirm. Both macOS (mouse) and iOS (touch) paths.

**`App/PatternSpike/CanvasRepresentable.swift` (MODIFY)** — thread the `confirm`/`cancel` tokens through `applyConfirmTransformIfChanged`/`applyCancelTransformIfChanged` in BOTH iOS + macOS coordinators (the `applyClearIfChanged` idiom).

**`App/PatternSpike/ContentView.swift` (MODIFY)** — `.select`/`.transform` toolbar icons; `confirm` ✓ / `cancel` ✕ controls (enabled only while a transform is active); observation tuple + keymap routing.

**`Sources/PatternEngine/ScriptedScene.swift` + `App/PatternSpike/RenderHarness.swift` (MODIFY)** — scene support: a `selectionRect` + `selectionAffine` (+ a confirm flag) so a scene can script ‘paint → select rect → set affine → confirm → assert’. Plus a `select-transform` scene.

## Data flow (cut-on-enter, composite-on-confirm)

1.  `.select` phase: drag → `selectionRect` (canonical `CGRect`, clamped to `[0, tileSize]^2`).
2.  Enter `.transform` (tool switch with a rect present): `spike.beginTransform(canonicalRect:)` → stash pre-transform canonical into `transformRestore` → `extractRegion` into `selection` → `clearRegion` on canonical (source blank) → affine = identity → provisional active.
3.  Each gesture / scripted set: recompute affine (handles) or set directly (harness) → `spike.setSelectionAffine` → clear `provisional`, render the selection quad through the affine into `provisional`. Canonical untouched. Tiling pass shows `provisional` over `live` over `canonical` live.
4.  Confirm: push `transformRestore` onto the undo ring → `compositeTextured(selection, affine)` into canonical → release stash, clear `provisional` + `selection` → inactive → `reportHistory()`. The pushed pre-transform state makes the entire cut+move ONE undo entry.
5.  Cancel / tool-switch-away / tile-size / tiling change: blit `transformRestore` back into canonical → release stash, clear `provisional` + `selection` → inactive. (Nothing pushed to the undo ring.)

## The affine

`float3x3` on homogeneous canonical coordinates, composed about the selection center: `A = T(center) · T(translate) · R(θ) · S(sx,sy) · T(-center)`, identity on enter. Built by `Affine` value-type helpers (`PatternEngine`), unit-tested headlessly. `selection_vertex` applies it to the rect's canonical corners; the fragment samples the lifted texture with a bilinear sampler (reuse the one `resize` already builds) so rotate/scale are smooth.

## Explicit rulings

*   Switching tools away mid-transform = implicit cancel (canonical restored). Only ✓ bakes; a half-lifted selection can never be stranded.
*   Selection rect is clamped to the central tile `[0, tileSize]^2` (a drag beyond clamps, not rejects). Cross-fold selection deferred.
*   A confirmed transform is exactly one undo step (the enter-transform snapshot); cancel is not undoable (it already restored). Consistent with per-completed-stroke undo granularity.

## Testing / verification posture

**Headless (the load-bearing correctness):**
*   **Affine unit tests** (`swift test`, `PatternEngine`): translate/scale/rotate-about-center produce the expected matrices; compose correctly.
*   **canonicalToWorld round-trip test** (`swift test`): `worldToCanonical(canonicalToWorld(p, cell)) == p` for all 5 tilings, incl. non-central cells.
*   **EditorCore tests**: `.select`/`.transform` tool routing (s/t keys), confirm/cancel token bumps, Return/Escape routing.
*   **Render-harness select-transform scene** (GPU proof): paint a mark at canonical A; select a rect around it; set a translate affine moving it to B; confirm; assert canonical B inked AND canonical A blank (proves cut + move). A negative control (skip confirm, or identity affine) must change the asserts' outcome so the proof isn't vacuous. These exercise only view-local code that computes-and-sets the affine the harness proves.

**Manual-only (flagged, not automatable):** the interactive handle gestures (drag inside/corner/outside), the toolbar ✓/✕ + s/t/Return/Esc reaching SwiftUI `.onKeyPress`, and the live draft-preview smoothness.

## What the raster brush (step 5) inherits from this

*   The **textured-quad-through-a-vertex-matrix** primitive = the brush's textured stamp.
*   The **Affine** value type + the vertex matrix path.
*   The **provisional channel** (its predicted-touches/lookahead client).
*   `canonicalToWorld` for placing stamps/handles.
*   The **commit-seam composite** already wrapped by snapshot undo (step 3).

## Key conventions (from the codebase)

*   `swift build`/`swift test` do NOT compile the metallib (trap in `SpikeRenderer.init` under SwiftPM); the Xcode app target compiles `Shaders.metal`. Engine/EditorCore/Affine tests run under `swift test`; GPU/end-to-end via the app + render harness (`--render-harness <dir> [--scene X | --all]`, read PNG paths from the `HARNESS OK` line). See the `verifier-metal` skill.
*   `EditorModel` is `@Observable @MainActor`; config `public private(set)`; edge commands via `CommandToken`. Config flows ONE WAY (`model` → `CanvasRepresentable.apply` → view setters); view surfaces state via callbacks (`onHistoryChanged`). BOTH `CanvasRepresentable` branches (iOS + macOS) get every change.
*   Premultiplied-alpha pipeline: tiles store premultiplied color; composite passes must blend, not overwrite (see the premultiplied-alpha note; the provisional composite follows the live-layer branch).
*   Commit messages: conventional prefix, NO GENAI tag, NO Co-Authored-By trailer.
*   Snapshot undo (step 3) already wraps the commit seam; the transform confirm reuses it → undoable free.