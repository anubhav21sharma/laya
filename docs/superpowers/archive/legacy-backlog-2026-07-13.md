# Archived Backlog — 2026-07-13

> **Historical evidence only.** This backlog describes the lost pre-rebuild
> implementation and its former delivery order. It is not an active roadmap
> for the rebuild. Current scope and sequence come from
> `specs/2026-07-18-pattern-product-rebuild-design.md` and its slice-specific
> specs and plans.

## Original backlog

Open work that has no design-spec home: bugs to fix, verification gaps, deferred fast-follows, and intrinsic limitations we accepted on purpose. Distilled from working notes 2026-07-13. Each item says whether it is a fix, a gap, or an accepted limitation, and where it was last confirmed in code.

Design rationale lives in the phase docs (`00-15`); this file is the running punch-list.

## Next feature

* **[Layers (roadmap step 6) — NOW NEXT. Deferred past the professional-brush-engine pass (15). A pure consumer of the seams already installed (per-dab attributes, snapshot undo, provisional channel, commit transaction); it multiplies canvas state but invents no new engine mechanism. The edit-transaction machinery was hardened across four review rounds (14-edit-transaction-module-design.md) specifically so layers land on a settled lifecycle. See 07-drawing-tools-roadmap.md.]**

## Brush-engine fixes

* **[fix]** Opacity/flow is not a per-tool setting; mouse input has no pressure. `PatternCanvasView.mousePressure` is a hardcoded `0.5` (`PatternCanvasView.swift:490`) feeding every mouse dab's radius/flow. Per-preset `opacity/flow` exist (`BrushPreset`, `EditorModel.setBrushOpacity`), but on a mouse the eraser (and brush) still ride the 0.5 pressure constant, so the eraser erases at partial strength — it doesn't fully clear ink. The eraser's coverage is its destination-out alpha (`dst *= 1-src.a`), so an eraser strength/opacity control maps straight onto that alpha. Design a shared per-tool opacity/strength control; don't special-case the eraser. (Pen pressure on iPad is real; this is the mouse/desktop path.)
* **[accepted limitation]** Moving-grain seamless wrap. The moving grain mode (stroke-local grain) does not wrap seam-safe; only the `texturized` (`canvas-fixed`) grain is proven seamless. Documented in `12-raster-brush-design.md` / `13-png-brush-quality-design.md`. Revisit if a preset needs moving grain across tile seams.
* **[accepted limitation]** Pressure lerp is by curve parameter, not arc length. `StrokeInterpolator` lerps per-dab pressure along the curve parameter, not arc length — slightly uneven taper on sharply-spaced samples. Fast-follow, not a correctness bug.

## Brush assets

* **[fix]** `tip.png` is committed but unreferenced. `Assets.xcassets/tip.imageset` exists and `BrushPreset.shapeAsset` is plumbed end-to-end (`SpikeRenderer.setBrushTextures` -> `resolver` -> `.r8Unorm`), but no built-in preset sets `shapeAsset`, so the shape-PNG path is never exercised by a preset or the harness. Either wire a preset to `tip` (and add a harness scene) or drop the asset.
* **[gap]** PNG-asset harness does not prove asset identity. `brush-png-asset` (`RenderHarness.swift:832`) binds the grain PNG by name and asserts grain renders + tiles, but it passes identically to the procedural fallback — no assert that the asset pixels (vs generated pixels) reached the GPU, and the `warnMissing` logs aren't captured. Add an asset-identity / adjacent-variation assert so a broken resolver can't pass green.

## Selection / transform

* **[fix - PARKED by user call 2026-07-03]** Live interactive transform UI never engages. The renderer seams (extract / cut / affine / composite / provisional channel) are **done and harness-proven** — the harness drives `beginTransform`/`setSelectionAffine`/`confirmTransform` directly and passes. But through the real macOS/iOS input path the transform never reaches active state: the √/X toolbar buttons (gated on `isTransforming`) never appear, so `beginTransform` is not engaging via `PatternCanvasView.setTool(.transform)`. Three fix rounds each corrected genuine defects (1x1 unfolded-rect lift, missing affordance, focus loss, scale/rotate hit-testing) but the entry is still inert. Suspect the `apply()`-ordering / `selectionRect`-nil-at-`setTool` / `@observable` same-value-suppression class that has repeatedly bitten this path. Resume with instrumentation (log whether `beginTransform` runs and whether `selectionRect` is non-nil at `setTool`), not another blind patch. DOES NOT block layers. Renderer-seam design in `11-selection-transform-design.md`; the parked-state root-cause analysis is captured above.
* **[deferred by design]** Selection is central-tile, rectangular only. Warp / lasso / feather / cross-fold selection, and a SwiftUI outline that tracks the transformed pixels (the outline currently anchors at the drag origin), are all deferred. See `11-selection-transform-design.md`.

## Intrinsic / accepted limitations (tiling)

Recorded in `04-multi-tiling-design.md`; listed here for one-place visibility:

* Cross-tiling reuse breaks committed content (open design question A-vs-B; needs a retained stroke model to fix, deferred indefinitely).
* Half-drop horizontal-line phantom dot (a single canonical tile can't represent a lattice-inconsistent horizontal stroke under a column phase).
* Mirror / p2 seamless only to ~1xtile though the radius cap allows 4xtile (multi-image enumeration deferred).

## Already fixed (do NOT re-chase)

Items from the 2026-07-06 review that were remediated and merged (`4a39787`); left here so they aren't re-filed from stale notes:

* `pressureCurve` now feeds radius — `BrushDynamics.radius(forPressure:curve:)` (`BrushDynamics.swift:26`).
* `StrokeSession` persists `lastEmittedWorld` across input batches — scatter / `.followDirection` no longer break on the first dab of a batch (`StrokeSession.swift:39`).
* The stale duplicate `PatternSpike/PatternSpike.xcodeproj` (missing the EditorCore dep) was removed; the real project is `App/PatternSpike.xcodeproj`.
* The edit-transaction lifecycle whack-a-mole (guarded config-key / select-mode / select-drag teardown paths) — root-caused into the `EditorTransaction` reducer module (`14`).
