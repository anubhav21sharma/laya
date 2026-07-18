EditorTransaction — edit-lifecycle state machine (design)

Date: 2026-07-07 Status: design (brainstorm complete, pending spec review → implementation plan) Branch context: fix/review-findings-2026-07-06 (17 findings fixed across 3 review rounds)
Problem

"Which edit is currently active" — idle / drawing / erasing / selecting / transforming — is represented implicitly across scattered state with no single owner enforcing legal transitions:

    View (PatternCanvasView): session, stabilizer, selectionRect, dragStartCanonical, dragStartPoints, activeRegion, grabRef, rotateCenter, rotateStartAngle.

    Renderer (SpikeRenderer): isTransforming, transformRestore, selectionLayer.

    Model (EditorModel): activeTool, and the edge-trigger CommandTokens (clear/undo/redo/ confirm/cancel transform).

    UndoHistory: snapshot ring.

Because no component owns the lifecycle, each transition (config change mid-transform, ⌘Z mid-transform, a .select-mode rect surviving a tile-size change, switching tool away from transform) is hand-guarded in an ad-hoc method. Three review rounds each found a different illegal-transition edge the previous round's hand-guard missed:

    Round 1 (F1): keyboard ⌘/⌘Z mid-transform corrupted state — clearCanvas/undo/redo didn't resolve the transform.

    Round 2 (R2-1): the config-key path (1–7, >, <) bypassed the round-1 guard.

    Round 3 (R3-1): a .select-mode rect (not yet lifted) survived a config change → stale lift; and the overlay-clear was a synchronous SwiftUI @State write (unreliable mid-updateNSView).

Point-patches do not converge — each fixes one edge and the next review finds another. The root cause (reviewer's architecture note #1) is the absence of an edit-transaction owner.
Solution

A pure reducer in EditorCore (Swift, no GPU / SwiftUI / CoreGraphics), owned by a sibling @MainActor controller in the app/view layer (NOT inside EditorModel — see §4). It owns the lifecycle and returns the side effects each transition requires; the view/renderer are dumb executors. Effects are a declarative, ordered value, so every transition's effects are unit-asserted.
1. State — draft vs ready split

The selection lifecycle has THREE distinct phases, not two. Conflating "being dragged" with "settled" (an earlier draft's selecting(rect)) is a bad interface: enterTransform could fire on a half-built or zero-area rect. Split them:
Swift

public enum State: Equatable {
    case idle
    case drawing(StrokeTool) // draw OR erase — a stroke in flight (tool carries which)
    case selectingDraft(rect: SelectionRect?) // pointer down/dragging; rect nil until first drag delta
    case selectionReady(SelectionRect) // drag ended, a valid non-empty selection settled
    case transforming(SelectionRect) // pixels lifted; affine draft active
}

public enum StrokeTool: Equatable { case draw, erase }

Only selectionReady → transforming is legal; enterTransform from selectingDraft (or a nil/ empty rect) never lifts. Because a tool intent supersedes current live input, transform intent from drawing cancels the stroke, and transform intent from selectingDraft abandons the draft (clearing the overlay if a visible rect exists). drawing(StrokeTool) collapses the old separate drawing/erasing — erase is a stroke variant, not a distinct lifecycle; the tool value flows into commitStroke/cancelStroke so the executor still sets liveStrokeErases correctly.
2. SelectionRect — explicit raw/folded value object

TileRect alone is underspecified. The current code has a load-bearing raw-vs-folded split: pixelRect(from:) folds the origin into [0, tileSize) and clamps the span, while the renderer ALSO needs the raw (unfolded) origin to conjugate the affine pivot into folded space (round-1 finding #3's fold-delta fix). Encode that split structurally instead of two loose params:
Swift

public struct SelectionRect: Equatable {
    public var rawOrigin: SIMD2<Double> // unfolded canonical/world origin (affine-pivot space)
    public var folded: PixelBox // origin folded into [0,tileSize), span clamped to the tile
    // Invariants (enforced at construction): folded is non-empty (w,h >= 1); folded.origin ∈ [0,tileSize);
    // v1 does NOT lift across a seam - a straddling drag is truncated at the tile edge (documented).
}

(PixelBox = EditorCore-native int rect; the renderer's PixelRect maps from it. rawOrigin - foldedOrigin is the fold delta the renderer conjugates by.) A zero-area drag yields selectingDraft(rect: nil), never a SelectionRect, so downstream code never sees an empty selection.
3. Events & Effects
Swift

public enum Event: Equatable {
    case strokeBegan(StrokeTool) // pointer-down in draw/erase
    case strokeEnded // pointer-up -> commit
    case pointerCancelled // iOS touch-cancel -> drop
    case selectionChanged(SelectionRect) // select drag produced a valid rect
    case selectionCleared // select drag collapsed to empty / abandoned
    case selectionEnded // pointer-up in select -> settle (draft -> ready)
    case toolIntent(Tool) // user picked a tool (draw/erase/select/transform)
    case command(Command) // .undo / .redo / .clear (see §4 — NOT snapshot mechanics)
    case canvasConfigChanged // tiling OR tile-size changed (both invalidate folds)
}

public enum Command: Equatable { case undo, redo, clear }

public enum Effect: Equatable {
    case cancelStroke(StrokeTool) // drop session + stabilizer + live overlay
    case commitStroke(StrokeTool) // spike.commitOverlay (renderer snapshots at ITS seam)
    case beginTransform(SelectionRect) // spike.beginTransform(folded, rawOrigin:)
    case confirmTransform // spike.confirmTransform (restore lifted pixels)
    case cancelTransform // spike.cancelTransform (restore lifted pixels)
    case clearSelectionOverlay // onSelectionRect(nil) - async by executor
    case performCommand(Command) // spike.undo/redo/clearCanvas - renderer owns snapshot
}

    Note (impl): there is deliberately NO showSelection effect. The view surfaces the selection outline itself during the select drag (overlay-point space — gesture mechanics, not lifecycle), so the machine only ever CLEARS the overlay. Transform entry emits beginTransform alone; the outline the view already drew persists into the transform.

No snapshotUndo effect. Undo lives at the renderer's commit seam (per the undo-redo design); the machine must NOT know snapshot mechanics. commitStroke/confirmTransform/performCommand(.clear) already trigger the renderer's own snapshotting. The machine only decides lifecycle, never how undo is stored.
3a. Effect ORDER is part of the contract

Effects are an ordered array; tests assert the exact sequence, not a set. Order matters — a transform interrupted by undo must run cancelTransform → clearSelectionOverlay → performCommand(.undo), never undo-before-cancel (which would snapshot/restore the wrong canvas). Worked examples (each a prior-round bug, now a passing ordered-array assertion):

    apply(.canvasConfigChanged) in .transforming(r) → .idle, [cancelTransform, clearSelectionOverlay] ← R2-1

    apply(.canvasConfigChanged) in .selectionReady(r) → .idle, [clearSelectionOverlay] ← R3-1a (settled rect invalidated by re-fold)

    apply(.canvasConfigChanged) in .drawing(t) → .idle, [cancelStroke(t)] ← F4

    apply(.command(.undo)) in .transforming(r) → .idle, [cancelTransform, clearSelectionOverlay, performCommand(.undo)] ← F1 (ORDER load-bearing)

    apply(.toolIntent(.transform)) in .selectingDraft(nil) → .idle, [] ← #1 no lift on empty rect

    apply(.toolIntent(.transform)) in .selectingDraft(r) → .idle, [clearSelectionOverlay] ← abandon draft

    apply(.toolIntent(.transform)) in .drawing(t) → .idle, [cancelStroke(t)] ← abandon live stroke

    apply(.toolIntent(.transform)) in .selectionReady(r) → .transforming(r), [beginTransform(r)] (the view-drawn outline persists; no showSelection effect)

4. Ownership & data flow

    A sibling EditorTransactionController (@MainActor, app/view layer) owns one EditorTransaction value and exposes apply(_ event:) -> [Effect]. NOT inside EditorModel: EditorModel.activeTool is user intent/config (persisted, one-way to the view); transaction state is live session state (ephemeral, input-driven). Mixing them deepens the model with per-frame lifecycle. Keep the model shallow; the controller is the transaction owner. The pure EditorTransaction reducer lives in EditorCore (testable); the controller is the thin @MainActor holder + effect dispatcher.

    PatternCanvasView sends events on input/config/command and executes the returned effects by calling spike.* / onSelectionRect (overlay clears async-dispatched — R3-1b). It stops hand-guarding.

    Renderer keeps isTransforming/transformRestore/selectionLayer as the GPU realization of the machine's state — an Adapter executing effects, not an independent source of truth. isTransforming becomes a derived mirror, no longer consulted for guards.

4a. Coordinator ordering — the bug must not just MOVE

CanvasRepresentable.apply() runs on EVERY SwiftUI update and calls the setters in a FIXED order (tiling → tileSize → clear → undo → redo → setTool → confirm(cancel), each individually guarded so only changed inputs act. If the controller consumes these as separate apply(event) calls, the event order becomes this hardcoded apply() order, not the user's action order — the ordering bug would move from the view's hand-guards into the coordinator. Two obligations make this safe, both part of the contract:

    Coordinator emits a DEFINED event order from apply() — documented + the same every pass, so the sequence is deterministic (not incidental to setter order). Config-change events precede command events precede tool events (matching "resolve the live edit, then apply the command"). Each (state, event) pair has a defined, sane transition (no "illegal, silently ignored" holes). A test enumerates the full State × Event matrix so no pair is unhandled. Totality means even an unexpected coordinator order can't corrupt state — the worst case is a harmless no-op, never a stale lift.

    The reducer is TOTAL — every (state, event) pair has a defined, sane transition (no "illegal, silently ignored" holes). A test enumerates the full State × Event matrix so no pair is unhandled. Totality means even an unexpected coordinator order can't corrupt state — the worst case is a harmless no-op, never a stale lift.

The machine cannot enforce coordinator order (it sees one event at a time); safety comes from (1) a deterministic emitter AND (2) a total reducer, together.
Scope

    Owns: lifecycle states, the SelectionRect (raw + folded), transitions, ordered effects.

    Leaves in the view: transform-drag gesture math (grabRef / rotateCenter / region / affine).

    Out of scope this pass: the parked live selection/transform interactive-input bug (a separate defect — the input path not engaging; this design HARDENS lifecycle legality but does NOT prove live-transform ENTRY works — kept honest); the shape-PNG asset path; any renderer/undo rework. The machine wraps emit-and-forget + snapshot-undo; it does not replace them [reviewer agreed these still fit — no broader subsystem rewrite].

Architecture verdict: one deep module (EditorTransaction) whose interface owns lifecycle legality + effect ordering; renderer stays an Adapter executing effects; undo history + GPU state stay where they are. Depth + leverage + locality without a wider rewrite.
Migration (low-risk, decided)

    Build the pure reducer + exhaustive unit tests FIRST (EditorCoreTests). Encode every prior-round bug scenario as an ordered-effect assertion, PLUS a total State × Event matrix test (every pair handled — §4a). Correctness proven headlessly before any view churn.

    Add EditorTransactionController (@MainActor, app layer) wrapping the reducer.

    Wire PatternCanvasView + CanvasRepresentable.apply() to emit events in the DEFINED order (§4a) + execute effects, preserving current behavior. The scattered guards (endTransactionsBeforeCommand, discardViewSelectionForConfigChange, the setTool guards, undo/redo/clearCanvas guards) collapse into event dispatch.

    Do NOT attempt the parked live-UI fix in the same pass.

Decided semantics (carried from prior rounds)

    command(.undo/.redo/.clear) during a transform → implicitly cancelTransform first (restore lifted pixels) + clearSelectionOverlay, THEN performCommand — ordered, explicit transition.

    canvasConfigChanged during any active edit → cancel the stroke and/or transform and clear the selection overlay; a settled selectionReady rect is invalidated too (R3-1a).

    toolIntent(.transform) only lifts from selectionReady; from a live stroke or draft it resolves the live input first and does not lift a half-built rect (#1).

    Overlay effects (clearSelectionOverlay) are always async-dispatched by the executor (SwiftUI @State-write-during-updateNSView hazard — R3-1b).

Testing

    Pure EditorTransactionTests in EditorCoreTests (swift-testing) — the exact layer where 3 rounds of transition bugs went unverified.

        Ordered-effect assertions for every prior-round bug scenario (§3a) — exact effect arrays, not sets.

        Total State × Event matrix test — every pair produces a defined (state, effects); no unhandled hole (§4a totality guarantee).

    Renderer effects continue to be proven by the existing offscreen render harness (no new GPU proof needed — the machine only decides effects; the effects themselves are already harness-covered).

    macOS + iOS build; full swift test green.

Success criteria

    Every prior-round bug scenario is a passing ordered-effect unit test.

    The State × Event matrix is total (no unhandled pair).

    The ad-hoc transaction guards in PatternCanvasView are gone, replaced by event dispatch; the transaction owner is the controller, not EditorModel.

    A new transaction edge is added by extending the reducer + a test — not by hand-guarding a call site.