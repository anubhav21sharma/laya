# Design note: live-tile performance, dab promotion, predicted touches, undo

**Status:** PARTIALLY IMPLEMENTED. The persistent live layer (incremental, append-only — the perf fix) is DONE (`LiveTile` now persistent + `stampNew` / `bakedCount` high-water mark + `reset`; `SpikeRenderer` stamps the delta each frame, resets on commit/cancel/setTileSize). The ephemeral layer + promotion remain DESIGN ONLY. Captured 2026-06-22 from a design exploration + an adversarially-verified workflow (run `wf_5860079c-17e`). UPDATE 2026-06-29: the ephemeral layer is now scheduled — generalized to a shared provisional channel and built with the selection/transform tool (draft transform), not gated on predicted touches. Undo decision also revised below (snapshot, not dab list). See `docs/superpowers/07-drawing-tools-roadmap.md`.

---

## DEFERRED DECISIONS (revisit when relevant)

1. **Ephemeral provisional layer** — add a SECOND live texture (third sampled in `tiling_fragment`) for provisional content, cleared+repainted every input event, composited `ephemeral` over `live` over `canonical`. Today nothing is provisional, so it is intentionally NOT built; the promotion rule in this note is its spec. The persistent-live layer fix is forward-compatible: adding the ephemeral layer is additive (one texture + one composite line + change the eligibility predicate from "always" to "position pinned").

   **GENERALIZED (2026-06-29):** the ephemeral layer is a shared PROVISIONAL RENDER CHANNEL, not a prediction-only feature. It has (at least) two clients: (a) predicted touches / lookahead interpolation, as originally framed; and (b) the **draft transform** of the selection tool — while the user drags rotate/scale/warp handles, the selected region is re-rendered into the ephemeral layer every gesture event (nothing touches canonical), and only **confirm** bakes the result into canonical via the commit seam (so it's undoable); **cancel** just clears the ephemeral layer. So the ephemeral layer should be built as a general channel (whoever its first real client is — likely the selection tool, see the roadmap), not stubbed as prediction-specific.

2. **Additional interpolation algorithms** — DECISION DEFERRED: whether to support smoothing models beyond the current per-segment centripetal Catmull-Rom (trailing-point tangent, zero-latency, final-on-emission). Candidates to evaluate: true lookahead centripetal CR (smoother joints, adds one-sample latency); One-Euro / exponential input smoothing (jitter denoise, low latency); pulled-string / "rope" smoothing (Procreate StreamLine, Apple PencilKit) actually do before committing. NOTE: The persistent-live- layer perf fix is Bézier fit. Also open: expose a user-facing "smoothing" parameter? Needs a researched comparison of what pro tools (Procreate StreamLine, Apple PencilKit) actually do before committing. NOTE: The persistent-live- layer perf fix is independent of the interpolation choice — it works the same regardless of which algorithm produces the dabs — so this decision does not block or interact with the fix.

## The bug that motivated this

Drawing with a medium/large brush (≈50px+) feels sluggish; small brushes are fine.

**Confirmed cause (measured, engine-level geometry model):** `LiveTile.rebuild` CLEARS the live tile and RE-STAMPS every dab accumulated so far in the stroke EVERY frame, alpha-blended, at up to 120fps. Per-frame fragment fill = Σ(clipped dab areas). Because a large dab covers much of the 256² tile, per-frame overdraw scales badly and compounds with stroke length:

| brush radius | per-frame full-tile overdraws |
| :--- | :--- |
| 10px (fine) | ~1.5x |
| 20px | ~3x |
| 50px (sluggish) | ~3x early -> ~12x by end of stroke |
| 200px | ~32x |
| 400px | ~68x |

Instance count stays low (~100-300; larger brushes use larger spacing -> fewer dabs), so the cost is per-instance FILL, not instance count. It worsens through the stroke because rebuild redraws the whole accumulated overlay each frame.

---

## The fix: incremental persistent live layer (+ ephemeral layer for provisional data)

Stop clear-and-restamp. Treat the live stroke like `CanonicalRaster.commit` already treats the committed tile: persistent texture, `loadAction = .load`, append only the NEW dabs since last frame. Per-frame cost drops to "dabs added this frame" — independent of stroke length and brush size. This is the real fix (not FPS throttling, which doesn't help while actively dragging).

**Two surfaces:**
* **Persistent live-stroke layer** — final dabs, append-only, baked once, never cleared mid-stroke. Holds the whole confirmed in-progress stroke. This is where the perf win comes from.
* **Ephemeral layer** — only the CURRENT provisional tail (predicted touches and/or an unpinned lookahead segment). Cleared + recomputed every input event. EMPTY today (no prediction, no lookahead) so it costs nothing. Its size is bounded by the prediction/lookahead HORIZON, not by a frame count — "N frames old" is the wrong model; it holds "whatever is not yet final."

Data flows ephemeral -> persistent by PROMOTION (one-directional) as dabs become final.

## Promotion: when is a dab eligible for the persistent layer?

**General rule:** a dab is promotable the instant its POSITION can no longer change — every input its position depends on has arrived.

**Today (no prediction, no lookahead):** promotion is trivial — nothing to promote.
`StrokeInterpolator.add` closes each segment P[k-1]->P[k] with the duplicated trailing point (`sampleSegment(pBefore, pPrev, pCur, pCur)`), NOT a future sample. So every emitted dab is FINAL on emission; `StrokeSession.emit` only ever appends immutable `DabSpecs`; `liveCanonicalDabs` is append-only (verified: only `.append` + bulk `.removeAll`). The shippable perf fix needs ZERO promotion machinery: persistent layer = "append every emitted dab"; ephemeral = empty; eligibility predicate = constant `true`.

**With predicted touches (future):** predictions are NEVER promoted
Trigger = "REAL input (actual + `coalescedTouches`) arrived covering that region." Predicted dabs are discarded wholesale every `touchesMoved` and regenerated. "Promotion" = discard-ephemeral + append the newly-arrived REAL dabs. (We already consume `coalescedTouches`; we do NOT use `predictedTouches` yet.)

**CRITICAL hazard (verifier-raised):** protect the interpolator walk state. The interpolator threads forward-only mutable state — `carry` (arc-length remainder) and `lastEmitted` — with no rewind. The speculative/predicted walk MUST run on a COPY of the interpolator (`var preview = session`), or the next REAL dab lands at `spacing - poisoned-carry` (wrong spacing at the seam). This works today ONLY because `StrokeInterpolator` is a Swift struct (value copy deep-copies `carry`/`lastEmitted`/`control`). Load-bearing, currently-unstated dependency: if it ever becomes a class, prediction silently corrupts real spacing. Guard with a comment + a test when prediction lands.

**With lookahead centripetal Catmull-Rom (future):** trigger = "outgoing-tangent control arrived"
If upgraded to a true outgoing tangent (smoother joints than the duplicated stand-in), the LAST segment is provisional until its tangent control exists. Predicate: `promotable(S(k)) == (control.count > k+1) || ended`. Dependency window is exactly `(P0, P1, P2, P3)` (Barry-Goldman in `evalCR`), verified — "two control points ahead of the segment start" is geometrically complete; no points further out matter.

**Verifier correction:** segments are NOT independently freezable. Re-walking `S(k)` with its true tangent changes its arc length -> changes `carry` into `S(k+1)` -> changes `S(k+1)`'s dab positions AND count. So promotion is keyed on the **flat emitted-dab index**, NOT the segment index.

**Identity / dedup: monotonic baked-count high-water mark**
Do NOT dedup by position equality — `Dab` is `Equatable` on center/radius/alpha only, and `finish()` legitimately yields coincident points, so position-equality would drop real dabs. Use a per-stroke monotonic `bakedCount` indexing the append-only `liveCanonicalDabs`: each event, bake the suffix `[bakedCount...]`, then `bakedCount = liveCanonicalDabs.count`. Exactly-once + idempotent on empty frames by construction.

## Per-event promotion step (works for all three cases)

```swift
onInputEvent(event):
  ephemeral.clear()                        # drop last frame's predictions (no-op today)
  realDabs = liveSession.feed(actual + coalesced)   # advances the REAL carry/lastEmitted
  overlay.append(realDabs)                          # (control.count > k+1 || ended) under lookahead
                                                    # exactly-once via high-water mark
  overlay.bake(from: bakedCount); bakedCount = overlay.count
  var preview = liveSession.copy()                  # COPY - value semantics; must NOT touch real state
  ephemeral.draw(preview.feed(event.predicted))     # speculative; never appended, never baked
```


## Cancel / clear (under the layered design)

Trivially correct, and the layered design makes the invariant explicit: **nothing reaches canonical until commit (pointer-up)**. Mid-stroke dabs live only in the live-stroke texture.

* **Cancel mid-stroke (`cancelOverlay` / `touchesCancelled`):** clear the live-stroke texture.
    * ephemeral, reset `bakedCount`, drop the session. Canonical untouched. The "can't unbake" fear does not apply because we never bake into the permanent surface mid-stroke.
* **Clear canvas (∅):** clear canonical + live-stroke + ephemeral, drop session.

## Undo

No undo exists yet; commit is destructive (`CanonicalRaster.commit`, `loadAction = .load`, blend). **The commit step is the seam where undo plugs in.** Two strategies were sketched here:

* (a) Snapshot-based: on pointer-up, snapshot canonical BEFORE compositing the live-stroke layer in; undo = restore snapshot.
* (b) Layer/command: retain each committed stroke's dab list / live texture; undo = drop last + recompose — the path toward non-destructive editing.

**DECIDED (2026-06-29): undo is SNAPSHOT-based (strategy a), NOT a retained dab list.** This supersedes the earlier "keep the DAB LIST as source of truth" lean below. Rationale (see the tools roadmap, `docs/superpowers/07-drawing-tools-roadmap.md`): undo must wrap the commit seam as a **geometry-agnostic transaction** because the eraser (destination-out) and the selection transform-composite produce canvas changes with no clean originating dab list — a snapshot model treats all these uniformly, a dab-list model special-cases them. And the upcoming raster brush will churn the dab schema (textured stamps, hardness, brush-id), so a retained dab list now gets re-versioned or made lossy; snapshots are schema-proof (just pixels). Emit-and-forget is preserved; the canonical TEXTURE is the retained artifact.

Implementation: a **bounded ring of canonical snapshots** at the commit seam (clear redo on new commit; undo blits the snapshot back, moves it to redo). Store **dirty-rect deltas** (the changed region of the canonical tile — small for one stroke) rather than full-tile copies, so it stays cheap at large tile sizes (tile is user-configurable up to 1024² ≈ 4MB/full-copy; a delta is a fraction). Headless-verifiable: commit A -> snapshot -> commit B -> undo -> pixel-assert canonical == post-A.

The earlier dab-list "source of truth" idea is the right model ONLY for **re-fold-on-tiling-change** (replay strokes under a new fold), which is explicitly deferred (speculative, not on the roadmap). If that feature ever lands it's a brush-era decision, once the dab schema is stable. Mid-stroke (sub-stroke) undo granularity is intentionally not supported; undo is per-completed-stroke (and per-confirmed transform, per-erase).

## Sequencing recommendation

Ship the **persistent-layer half now** (fixes the sluggishness today) with the ephemeral layer stubbed empty and `bakedCount` append-only — no promotion logic, because today every dab is final on emission. Add the ephemeral layer + promotion ONLY when predicted touches (or lookahead CR) land; at that point this note is the spec.