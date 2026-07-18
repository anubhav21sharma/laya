# Eraser — Design Spec (drawing-tools step 2)

**Status:** approved 2026-07-01. Roadmap: `docs/superpowers/07-drawing-tools-roadmap.md` step 2.

## Goal

An eraser tool that removes ink from the canvas — the primary dab and all its tiled replicas — with **live preview** during the stroke (ink disappears under the cursor as you drag, not only on mouse-up). Switchable via a toolbar button (active-styled) and the `e` key.

This tool installs two roadmap seams later tools reuse:

1. `activeTool` — the first tool-mode concept in `EditorModel` (draw default).
2. Per-dab `blendMode`, batched by mode at `commitOverlay()` — NOT a one-off destination-out pipeline. Per-dab/batched blend generalizes to multiply/screen and the textured brush; a destination-out-only pipeline would not.

## Architecture

Color rode the dab pipeline as a per-dab attribute (step 1). Blend mode rides the same chain as a second per-dab attribute — constant per stroke (captured at session init), like color.

`EditorModel.activeTool` -> `CanvasRepresentable.apply` -> `PatternCanvasView.configuredBlendMode` -> `makeSession(color:blendMode:)` -> `StrokeSession` (captures it) -> stamps `blendMode` on every `DabSpec` -> `Dab(canonicalOf:)` copies it -> GPU `DabInstance`. Same one-way flow as `inkColor`; the interpolator/dynamics stay blend-agnostic.

## Tool mode

*   `EditorModel`: `enum Tool: Sendable { case draw, erase }`; `public private(set) var activeTool: Tool = .draw`; actions `setTool(_:)` and `toggleEraser()` (flips draw<->erase). Registered in `ContentView.body`'s observation tuple so the one-way push fires.
*   `EditorKeymap`: `case "e": m.toggleEraser(); return true.`
*   Toolbar: an eraser SF Symbol button (`eraser`), active-background styled exactly like the grid toggle, calling `model.toggleEraser()` (or `setTool`). A pencil/draw affordance is implicit (eraser off = draw).

## Per-dab blend attribute — reuse `_pad0`, NO stride change

`DabInstance` is a 48-byte struct with two spare pad floats (`_pad0` @24, `_pad1` @28) left over after `color` landed at @32. Reuse `_pad0` as `blendMode` — stride stays 48, `LayoutTests` still guards it (asserts 48, unchanged). `_pad1` remains padding.

*   `blendMode` semantics: `0` = normal (source-over ink), `1` = erase.
*   Chain: add `blendMode: Float` to `DabSpec` (default 0); `StrokeSession.init(color:blendMode:)` captures it (default 0) and stamps it on every emitted `DabSpec` (both call sites, like color); `Dab` gets `blendMode` where `_pad0` was; `Dab(canonicalOf:)` copies `spec.blendMode`; C `DabInstance._pad0` -> `blendMode`.

## Live preview — erase = a `(0,0,0,coverage)` premultiplied dab (zero shader branching)

CORRECTION (2026-07-02, 80e1547): The "zero shader branching" claim below is WRONG — it was found incorrect during implementation. The composite `draft + committed*(1-draft.a)` fades committed RGB toward transparent, but the `(0,0,0,cov)` draft term also drives the result's **alpha toward 1**. Composited over opaque paper, an alpha-1 black pixel is **opaque black**, not erased — so the live preview showed opaque black under the cursor while dragging (only the committed destination-out result on mouse-up was correct). The fix added a **subtractive branch** in `tiling_fragment`: when the `liveStrokeErases` uniform bit (`0x20000`, packed in `tilingKind`) is set, `color = committed * (1.0 - draft.a)` (matching the committed destination-out `dst *= 1-src.a` exactly, on both RGB and alpha). `SpikeRenderer.liveStrokeErases` is set at stroke start (erase only) and reset at every stroke end. The original reasoning below is retained for context but is superseded by this note.

The tiling shader composites the live tile over committed, premultiplied:

`color = draft + committed * (1.0 - draft.a);`

An erase dab is a premultiplied `(0,0,0, coverage)` dab stamped source-over into the live tile. `dab_fragment` returns `float4(color.rgb, color.a * falloff)`; for an erase dab `color = (0,0,0,1)`, so it emits `(0, 0, 0, falloff)` — RGB 0, alpha = the pressure/round-falloff coverage. At an erased pixel the existing composite becomes:

`(0,0,0,cov) + committed*(1-cov)`

i.e. committed ink fades toward transparent as `cov -> 1`, and because the draft's RGB is 0, **no ink is added**. Erasing falls out of the composite already in the shader — **no new branch, no second texture, no shader edit for preview**.

CORRECTION (2026-07-02, 80e1547): This conclusion is incorrect (see the note at the top of this section). The RGB analysis holds, but the composite's **alpha** rises to 1 at an erased pixel; over opaque paper that renders **opaque black**, not erased. A subtractive shader branch (`committed * (1-draft.a)`, gated by the `liveStrokeErases` bit `0x20000`) was required for live preview.

`dab_fragment` produces `(0,0,0,falloff)` automatically when the dab's `color` is `(0,0,0,1)`. So the ENGINE gives an erase dab `color = (0,0,0,1)` (opaque black, straight alpha) in addition to `blendMode = 1`. The shader stays untouched; `blendMode` is consumed only at COMMIT (below). During the live stroke, an erase dab is literally "a black dab" in the live tile, which the premultiplied composite reads as erasure of committed. `LiveTile.stampNew` (source-over into transparent) needs no change.

**Single-mode-per-stroke invariant**: within one stroke the tool is fixed (all draw or all erase), and each stroke commits before the next begins, so draw and erase dabs never share a live tile. No draw/erase alpha fighting within the live tile.

## Commit — batch by mode

`CanonicalRaster.commit(dabs:queue:)` currently draws ALL dabs with one source-over `dabPipeline`. Change to partition dabs by `blendMode` and, per partition, set the matching pipeline before `drawPrimitives`:

*   `normal` (`0`) -> the existing source-over dab pipeline (unchanged path).
*   `erase` (`1`) -> a NEW **destination-out** pipeline: `sourceRGBBlendFactor = .zero`, `sourceAlphaBlendFactor = .zero`, `destinationRGBBlendFactor = .oneMinusSourceAlpha`, `destinationAlphaBlendFactor = .oneMinusSourceAlpha`. Result: `dst *= (1 - src.a)` — subtracts the dab's coverage from canonical RGB *and* alpha, removing premultiplied ink cleanly.

`CanonicalRaster` builds this second pipeline once at init (mirrors how `SpikeRenderer` builds its pipelines). Since a stroke is single-mode, cross-mode ordering within one commit is moot, but the partition preserves per-mode order.

## Components (files touched)

*   `Sources/PatternEngine/DabSpec.swift` — add `blendMode: Float` (default 0).
*   `Sources/PatternEngine/StrokeSession.swift` — `init(color:blendMode:)`; stamp `blendMode` on both `DabSpec` call sites.
*   `Sources/CShaderTypes/include/ShaderTypes.h` — rename `_pad0` -> `blendMode` (stride stays 48).
*   `Sources/MetalRenderer/DabInstance.swift` — `Dab.blendMode` (replaces `pad0`); copy `spec.blendMode` in `canonicalOf`.
*   `Sources/MetalRenderer/CanonicalRaster.swift` — build the destination-out pipeline; partition + per-mode draw in `commit`.
*   `Sources/EditorCore/EditorModel.swift` — `Tool` enum, `activeTool`, `setTool`/`toggleEraser`.
*   `Sources/EditorCore/EditorKeymap.swift` — `e` -> toggle.
*   `App/PatternSpike/PatternCanvasView.swift` — `configuredBlendMode` + `setActiveTool`; `makeSession` passes color+blendMode (erase -> color `(0,0,0,1)`, blendMode 1).
*   `App/PatternSpike/ContentView.swift` — eraser toolbar button; register `model.activeTool` in the observation tuple.
*   `App/PatternSpike/RenderHarness.swift` + `Sources/PatternEngine/ScriptedScene.swift` — `eraser` scene: allow a second (erase) stroke; assert canonical alpha->0 in the erased region, ink intact just outside.
*   Tests: `Tests/PatternEngineTests/*` (`blendMode` stamped on every placement), `Tests/EditorCoreTests/*` (tool default + toggle), `LayoutTests` (still 48).

## Data flow (erase stroke)

1. User presses `e` (or toolbar) -> `activeTool = .erase`.
2. Pointer down/drag -> `PatternCanvasView.makeSession` builds `StrokeSession(color: (0,0,0,1), blendMode: 1)`.
3. Emitted dabs (`blendMode = 1`, `color = (0,0,0,1)`) -> `LiveTile` (source-over) -> tiling shader composite reads them as `(0,0,0,cov)` -> committed ink fades under the cursor **live**.
4. Pointer up -> `commitOverlay` -> `CanonicalRaster.commit` partitions: the erase dabs draw through the **destination-out** pipeline -> canonical alpha subtracted permanently.

## Error handling / edge cases

*   Erasing where nothing is drawn: destination-out on `dst.a=0` is a no-op (`0 * (1-src.a) = 0`). Safe.
*   Tiled replicas + parity completions: erase dabs carry the same wrap/clip machinery as draw dabs (they're ordinary `DabSpec` s), so erasing tiles seamlessly, including on half-drop/brick seams.
*   Large erase brush: same radius cap as draw (dynamics-driven); no special-casing.
*   Cursor ring: unchanged — the ring tracks the pen for erase exactly as for draw (recent fix). (Optional future nicety: distinct ring style for erase — out of scope.)

## Testing strategy

*   **Engine (swift test):** `blendMode` defaults to 0; `StrokeSession(blendMode:1)` stamps 1 on every placement (incl. seam multi-placements) — mirror the color test.
*   **Layout (swift test):** `LayoutTests` unchanged — stride 48, `Dab == DabInstance`.
*   **EditorCore (swift test):** `activeTool` defaults `.draw`; `toggleEraser` flips; `e` routes through `EditorKeymap`.
*   **Harness (headless GPU, the make-or-break check):** `eraser` scene — draw-commit a filled dab, then erase-commit a dab over its center; pixel-assert canonical **alpha = 0** at the erased center and **ink present** just outside the erase radius. Read the PNG to confirm a clean hole (not a grey smear).
*   **Manual (one un-automatable bit):** live preview — the SwiftUI stroke can't be driven headlessly; confirm in-app that erasing removes ink *while dragging*, across tiled replicas.

## Non-goals (YAGNI)

*   Separate eraser-opacity control (uses the brush's pressure->alpha falloff -> soft edges for free).
*   Per-layer erase (layers are step 6).
*   A distinct erase cursor style.
*   Erase in the *overlay* (uncommitted) affecting *other* uncommitted strokes — impossible by the single-mode-per-stroke invariant.