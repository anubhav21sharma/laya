# Undo / Redo — Design Spec (drawing-tools step 3)

**Status:** approved 2026-07-02. **Roadmap:** `docs/superpowers/07-drawing-tools-roadmap.md` step 3.

## Goal
Undo/redo for canvas edits — draw, erase, and clear — with ⌘Z / ⌘⇧Z and toolbar arrow buttons. Snapshot-based at the `commitOverlay` seam. This installs the `commit-boundary-as-geometry-agnostic-transaction` seam that selection/transform (step 4) reuses to become undoable for free, and that the raster brush (step 5) inherits.

## Decisions locked in brainstorming
*   **Snapshot-based**, NOT a retained dab list (roadmap ruling): undo operates on the canonical TEXTURE (pixels), so draw, erase (destination-out, no clean dab list), and clear are handled uniformly, and it's immune to the brush's coming dab-schema churn. Emit-and-forget preserved.
*   **Full-tile snapshots**, NOT dirty-rect deltas. This deliberately SUPERSEDES the roadmap's "dirty-rect deltas" line — chosen for correctness-first simplicity. Cost: ~4 MB per snapshot at 1024² × 20 = 80 MB worst case, acceptable for a desktop/iPad app. Optimize to dirty-rects later only if memory bites.
*   **Ring depth 20** (drop oldest beyond that).
*   **Clear IS undoable** — `clearCanvas` snapshots before wiping, so an accidental clear is recoverable.
*   **Tile-size change and tiling switch are NOT undoable and FLUSH the undo history** — snapshots are tied to a fixed tile dimension + fold; a snapshot from a different size/fold can't be safely blitted back. Undo/redo apply within one tile configuration.
*   **Granularity = per-completed-stroke / per-clear** (and, later, per-confirmed-transform). No mid-stroke undo.
*   **Controls:** ⌘Z undo, ⌘⇧Z redo, routed through `EditorKeymap`; plus undo/redo arrow buttons in the toolbar (enabled per `canUndo` / `canRedo`).
*   **Commit stays synchronous at mouse-up** (deferring it a frame risks a flicker: the live tile is reset immediately after commit; if canonical lagged a frame the stroke would blink out). So the snapshot is taken synchronously in the renderer at commit time — NOT via a deferred model command.

## Architecture
Every canvas mutation funnels through one chokepoint in the renderer: `CanonicalRaster.commit` (draw/erase dabs) and `CanonicalRaster.clear` (clear). Undo wraps that seam:

*   **Before** a commit or clear mutates `canonical.texture`, capture a **full-tile snapshot** and push it onto the undo stack (clearing redo).
*   **Undo:** blit the top undo snapshot back into `canonical.texture`; move it to redo.
*   **Redo:** blit the top redo snapshot back; move it to undo.

Geometry-agnostic (pixels, not dabs). Selection-composites (step 4) plug in with zero special-casing.

## Ownership split (the clean division)
The undo state is two separable things, owned where each belongs:

1.  **Pixel snapshots (GPU textures)** — a renderer detail. Owned by a new `UndoHistory` type in `MetalRenderer`. The snapshot is taken **synchronously** at the commit/clear seam (correct timing, no flicker).
2.  **Enable-state (canUndo / canRedo)** — needed by the SwiftUI toolbar. Surfaced to SwiftUI via a view→ContentView callback (`onHistoryChanged`), the SAME idiom the codebase already uses for `onZoomChange` and `onStrokePoint`. NOT a bespoke back-channel — it's how view/renderer-local state already reaches SwiftUI here.

Commands (undo, redo, clear) flow the other direction as edge-triggered `CommandToken`s on `EditorModel` (exactly like the existing `clearToken`), through the one-way `apply` bridge. So: commands flow model→view via tokens; enable-state flows view→ContentView via a callback. No two-way model binding; the view never writes model state.

## Components (files touched)

*   **`Sources/MetalRenderer/UndoHistory.swift`** — CREATE. Owns two stacks of `MTLTexture` snapshots (bounded to 20 undo) + blit logic.
    *   `init(device:)`
    *   `func snapshot(_ src: MTLTexture, queue:)` — copy `src` into a pooled texture, push to undo, clear redo. (Drops oldest beyond 20.)
    *   `func undo(into dst: MTLTexture, queue:) -> Bool` — blit top undo snapshot into `dst`, move it to redo; false if empty.
    *   `func redo(into dst: MTLTexture, queue:) -> Bool` — symmetric.
    *   `func reset()` — flush both stacks (tile-size / tiling change).
    *   `var canUndo: Bool / var canRedo: Bool`
    *   Snapshot textures are sized to the current tile; `reset()` flushes on tile-size change so dimensions always match.

*   **`Sources/MetalRenderer/SpikeRenderer.swift`** — MODIFY.
    *   Own an `UndoHistory`.
    *   `commitOverlay()` and `clearCanvas()`: call `undoHistory.snapshot(canonical.texture, ...)` BEFORE mutating.
    *   New `func undo() -> (canUndo: Bool, canRedo: Bool) / func redo() -> ...` — call `undoHistory.undo/redo(into: canonical.texture)`, return the resulting enable-state. New `func resetHistory()` for tile-size changes.
    *   Expose `canUndo/canRedo` (read-through to `undoHistory`) so the view can report post-commit state.

*   **`App/PatternSpike/PatternCanvasView.swift`** — MODIFY.
    *   `var onHistoryChanged: ((_ canUndo: Bool, _ canRedo: Bool) -> Void)?`
    *   `func undo() / func redo()` — guard `session == nil` (ignore mid-stroke); call `spike.undo()/redo()`; fire `onHistoryChanged`.
    *   `mouseUp/touchesEnded` (after `commitOverlay`), `clearCanvas`: fire `onHistoryChanged(spike.canUndo, spike.canRedo)`.
    *   `setTiling/setTileSize`: after the renderer resets history, fire `onHistoryChanged` (both false).

*   **`App/PatternSpike/CanvasRepresentable.swift`** — MODIFY.
    *   Thread `onHistoryChanged` into the view (both makeView branches).
    *   Coordinator: `applyUndoIfChanged/applyRedoIfChanged` (mirroring `applyClearIfChanged`) comparing `model.undoToken/redoToken`; on change call `v.undo()/v.redo()`.
    *   `apply(...)`: call those alongside `applyClearIfChanged`.

*   **`App/PatternSpike/ContentView.swift`** — MODIFY.
    *   `@State private var canUndo = false`, `@State private var canRedo = false`.
    *   Pass `onHistoryChanged: { canUndo = $0; canRedo = $1 }` to `CanvasRepresentable`.
    *   Register `model.undoToken`, `model.redoToken` in the body observation tuple.
    *   Toolbar: undo/redo arrow buttons (`arrow.uturn.backward` / `arrow.uturn.forward`), calling `model.undo()/model.redo()`, `.disabled(!canUndo)` / `.disabled(!canRedo)`, near the clear button. Use the shared `iconW/iconH` sizing.

*   **`Sources/EditorCore/EditorModel.swift`** — MODIFY.
    *   `public private(set) var undoToken = CommandToken(), redoToken = CommandToken()`.
    *   `public func undo() { undoToken.bump() }`, `public func redo() { redoToken.bump() }`.

*   **`Sources/EditorCore/EditorKeymap.swift`** — MODIFY. Add a modifier-aware, unit-testable overload: `EditorKeymap.handle(key: String, command: Bool, shift: Bool, m: EditorModel) -> Bool` that maps `key=="z"`, `command`, `shift` -> `m.redo()`; `key=="z"`, `command` -> `m.undo()`; returns false otherwise (so it does NOT consume plain `z`). The existing char-router `handle(_:_:)` stays for the non-modifier keys.
    *   In `ContentView.onKeyPress`, call the modifier overload FIRST (`EditorKeymap.handle(key: press.key.character.map(String.init) ?? press.characters, command: press.modifiers.contains(.command), shift: press.modifiers.contains(.shift), model)`); if it returns false, fall through to the existing `EditorKeymap.handle(press.characters, model)`.
    *   Risk to verify during implementation: confirm ⌘Z actually reaches SwiftUI `.onKeyPress` (this app has no menu bar wired to Edit>Undo yet, so it should — SwiftUI receives the key event). If macOS swallows ⌘Z before `.onKeyPress`, the fallback is to also accept the corresponding menu command or a non-modifier key; note the outcome in the plan/commit. Do NOT ship a silently-dead ⌘Z.

*   **Tests:**
    *   `Tests/EditorCoreTests/EditorCoreTests.swift` — `undo()/redo()` bump their tokens; the modifier-aware keymap overload routes ⌘Z→undo, ⌘⇧Z→redo.
    *   Harness (`App/PatternSpike/RenderHarness.swift` + `ScriptedScene`) — an undo-redo scene proving the GPU snapshot/restore (below).

## Data flow
**Commit (draw/erase)**, synchronous in view: `mouseUp` -> `session.end()` -> `addOverlayDabs` -> `spike.commitOverlay()` [snapshots canonical, then composites] -> `onHistoryChanged(canUndo=true, canRedo=false)` -> `ContentView` `@State`.

**Clear**: `model.clear()` bumps `clearToken` -> `apply` -> `view.clearCanvas()` [snapshots, then wipes] -> `onHistoryChanged`.

**Undo (⌘Z or toolbar)**: `model.undo()` bumps `undoToken` -> `body` reads it -> `apply` -> `applyUndoIfChanged` -> `view.undo()` (guarded `session == nil`) -> `spike.undo()` blits snapshot back synchronously -> `onHistoryChanged(canUndo, canRedo)`. Redo symmetric.

**Toolbar arrows**: read `@State canUndo/canRedo` for `.disabled(...)`.

**Tile-size / tiling change**: `setTileSize/setTiling` -> `undoHistory.reset()` -> `onHistoryChanged(false, false)`.

## Error handling / edge cases
*   Undo/redo on empty stack -> `UndoHistory` returns false, no-op (button disabled anyway).
*   Ring full (>20 undo) -> drop the oldest snapshot.
*   Mid-stroke keypress -> `view.undo()/redo()` no-op while `session != nil`.
*   New commit/clear clears redo (linear history).
*   Tile-size change: snapshots of the old dimension can't blit into the resized texture -> `reset()` guarantees every stored snapshot matches the current tile size.
*   Snapshot textures reuse a pool sized to the current tile to limit allocation churn; the pool is flushed on `reset()`.

## Testing strategy
*   **Headless GPU (core proof)** — an undo-redo harness scene / a renderer-level test: commit stroke A -> commit stroke B -> `undo()` -> pixel-assert canonical == post-A (blit-back correct); `redo()` -> canonical == post-B; `undo()` past empty -> no-op; `clear` -> `undo()` restores. Uses `RenderCapture.readBGRA` to compare regions of the canonical texture across steps.
*   **EditorCore (swift test)** — `undo()/redo()` bump `undoToken`/`redoToken`; the modifier-aware keymap overload maps ⌘Z→undo, ⌘⇧Z→redo, and does NOT consume plain `z`.
*   **Manual** — the ⌘Z/⌘⇧Z + toolbar-arrow interaction and enable/disable states (SwiftUI, not harness-drivable). Draw a few strokes, undo/redo, erase, undo; clear, undo (canvas returns).

## Non-goals (YAGNI)
*   Dirty-rect delta snapshots (full-tile now; optimize later only if needed).
*   Undo across tile-size / tiling changes.
*   Mid-stroke / sub-stroke undo granularity.
*   Persisting undo history across app launches.
*   A visible history/timeline UI (just undo/redo).