# Laya vs Krita — Brush Engine Architecture Report

**Task:** compare laya's brush engine architecture against krita's; find what krita does better, and find laya's architectural bugs, bad decisions, and code smells, with recommendations.

**Method.** Seven brush-engine dimensions were read side-by-side against the actual source of both projects (krita = C++/Qt reference at `/krita`, laya = Swift/Metal under audit at `/laya`). Every laya defect was then re-opened at its cited `file:line` by a separate adversarial reviewer whose job was to *refute* it. Refuted/not-found claims were dropped; severities were corrected against what the source actually shows. **The severities below are the post-verification ones**, which are frequently lower than first impressions — laya is a GPU-instanced deposition renderer, and several "krita does X on the CPU" complaints do not transfer.

**One-line verdict.** Laya is not badly *written* — it is well-tested and internally consistent. It feels *clunky, slow, and inorganic* because of **five structural decisions**, not scattered bugs. Fixing the top three would move it most of the way to krita's feel.

---

## Cross-check against `2026-08-01-brush-engine-corrective-report.md` (empirical review)

A separate corrective report exists that reached its conclusions by **running the macOS app and measuring live traces** (445 ms CPU prep, ~1.4 s event-to-submit latency, ~2 FPS on physical hardware, 124/128 missed frame budgets). My report is **static source analysis**; that report is **empirical**. I re-verified its two load-bearing claims against the current source myself (not on face value). **Both are true, and both correct errors in my original report:**

1.  **Ordinary live input re-projects the whole retained tail per event — CONFIRMED, my report was WRONG.** The 4 professional brushes all use `replayMode: .replayTail` (`ProfessionalBrushDefinitions.swift:149,302,466,576`). For any non-`.appendOnly` brush, every actual sample hits `rebuildReplayLayer()` (`GridRenderer.swift:2728-2733`), which walks `buffer.actualChunks + predictedChunks` and re-appends every retained dab's projected records (`:3081-3135`), up to the 2,048-dab / 4,096-instance replay cap) **on every input event**. My workflow's RC2 verifier only exercised the `.appendOnly` `FrameScheduler` path and wrongly generalized "drain-once, append-only" to the whole engine. **The professional brushes route through the replay path, which is O(retained tail) per event — the dominant cause of the measured latency**. This is worse than anything in my original ledger.
2.  **End taper is retroactive -> visible endpoint retreat — CONFIRMED, my report MISSED it.** Technical Ink sets `taper.end = .diameterMultiples(1.5), minimumSize 0.08, minimumFlow 0.25` (`ProfessionalBrushDefinitions.swift:143-148`). End-taper envelope depends on `totalDistance - dab.sourceDistance` (`BrushDynamicsEngine.swift:582-586`), which is unknowable until pointer-up. At finish, `knownStrokeTotalDistance` is set (`GridRenderer.swift:2722`) and `rebuildReplayLayer()` re-evaluates the tail via `applyingKnownTotalDistance` (`:3116-3126`), shrinking already-previewed end dabs toward `minimumSize`. **The last ~1.5 diameters of the drawn line retract behind the released cursor.** My 7 dimensions never traced the finish/render-style path, so I did not catch this.

**What the corrective report does NOT overturn.** Its focus (live-stroke coordinator, replay policy, taper, cursor truth, preset asset quality, acceptance gate) is largely orthogonal to my findings. My **RC1 (main-actor pipeline)**, **RC3 (gamma-space + baked masks)**, **RC4 (no wet media, no registry, dropped `secondaryColorMix`)**, **RC5 (dead speed axis)** all still stand and are mostly *absent* from that report. The two reports are complementary, not competing — together they cover live-path cost + taper + cursor + acceptance (theirs) and threading + color + masks + dynamics + extensibility (mine).

**Where I hold a nuance against it.** (a) Its perf numbers are single-environment (paravirtual Metal / one physical Mac) — correctly flagged by the report itself as blocking-until-disproven, not a proven hardware tier. (b) On dab caching it and I **agree**: do GPU affine sampling of shared tip textures first, add quantized mask caching only for expensive generated masks — do not literally port Krita's CPU dab-bitmap cache (laya is GPU-instanced). (c) Its `.appendOnly` target is not a rewrite from zero: the engine **already has** an `.appendOnly` replay mode and fast path (`GridRenderer.swift:2682-2719`); the work is making taper causal so professional brushes can adopt it, plus moving the coordinator off `@MainActor`.

The sections below are **updated** to fold these two confirmed findings in and correct my prior errors.

---

## The architectural difference in one picture

| | Krita | Laya |
| :--- | :--- | :--- |
| Where dabs are built | Worker thread pool (`KisUpdaterContext`), off the GUI thread | `@MainActor GridRenderer` — same thread as input + compositing |
| Dab pixels | CPU-rasterized, **memoized** (`KisDabCache`), pooled buffers | GPU-instanced (good), **no dab memo** |
| Per-event work | Deposit **only new dabs** (append-once) | `.replayTail` brushes **re-project the whole retained tail every event** (up to 2,048 dabs) |
| End taper | Causal (never revises drawn dabs) | **Retroactive** — endpoint retreats after release |
| Generation vs compositing | **Decoupled** across threads, self-throttling | Coupled, serial per-frame drain |
| Big-brush responsiveness | **LOD** low-res buddy stroke | None (GPU fill hides most of this) |
| Mask | **Analytic**, evaluated at true dab size | **Baked 64/128/256px, upscaled** (only `hardRound` analytic) |
| Color | `KoColorSpace` abstraction, **linear** premultiplied mixing | Bare `InkColor` RGBA, **8-bit gamma sRGB** blend |
| Dynamics | Multi-sensor stacks per parameter, combine modes | **One input per channel** |
| Extensibility | **Registry + plugin** late binding | Hardcoded `static let` + stringly-typed switch |
| Media types | mask / image-stamp / colorful / smudge / wet | Deposition only — **smudge/wet declared but rejected at compile** |

---

## Root causes (ranked by leverage)

### RC1 — Whole live-stroke pipeline is single-threaded on `@MainActor` [highest leverage]

`GridRenderer` is `@MainActor public final class GridRenderer: NSObject, MTKViewDelegate` (`GridRenderer.swift:120`) — simultaneously renderer, view delegate, and stroke ingestion target. Grep confirms **zero `DispatchQueue`/`Task.detached`/worker in the interactive path**. Brush interpolation, 14-channel per-dab dynamics, CPU projection into instance records, per-record validation, buffer memcpy, and command-buffer encoding all run on the same thread that must ingest the next pointer event. **Frame time is coupled to brush complexity — the literal mechanism of "clunky/slow" under fast or large strokes.**

Nuance the verification added: laya does *not* CPU-rasterize pixels (the GPU does), so this is lighter than krita's equivalent CPU work — but the CPU-side geometry cost still competes with input handling.

Krita: GUI thread only builds `KisStrokeJobData` and enqueues; dabs render on a `QThreadPool` in `KisUpdaterContext`, tagged `UNIQUELY_CONCURRENT` so many render in parallel; `KisDabRenderingExecutor` decouples generation from compositing with self-throttling.

**Fix:** introduce a `KisUpdaterContext`-equivalent async seam. Move dab generation, dynamics, projection, validation, and buffer fill onto a worker actor / serial queue; keep only event intake and `present()` on the main thread. **Every other perf finding is downstream of this.**

### RC2 — Professional brushes re-project the whole retained tail every input event [co-highest leverage; corrected]

*(This replaces my original "no dab memoization" RC2, which was built on a wrong premise — see the cross-check section. The real, verified problem is far bigger.)*

All 4 professional brushes use `replayMode: .replayTail` (`ProfessionalBrushDefinitions.swift:149,302,466,576`), not `.appendOnly`. For any non-`.appendOnly` brush, **every ordinary actual input sample** calls `rebuildReplayLayer()` (`GridRenderer.swift:2728-2733`), which walks all retained `actualChunks + predictedChunks` and re-appends every dab's projected records into the replay surface (`:3081-3135`) — up to the replay cap of **256 samples / 2,048 dabs / 4,096 projected instances** (`BrushRecipe.swift:319`). So per-event CPU cost is **O(retained stroke tail)**, re-run on every event, and symmetry multiplies it. This is the direct source of the empirically-measured 445 ms CPU prep and ~1.4 s latency on a long stroke.

The engine **already contains** the correct fast path: `.appendOnly` mode (`GridRenderer.swift:2682-2719`) appends only the newly emitted records and never rebuilds the tail. Professional brushes don't use it only because they rely on `.replayTail` for (a) prediction replacement and (b) retroactive end taper (RC-Taper below). Krita's invariant: authoritative dabs deposit exactly once; only prediction is replaceable.

**Fix:** make authoritative deposition append-only for ordinary paint (adopt `.appendOnly`); confine replay to a small, time/distance-bounded prediction overlay (tens of dabs, not 2,048); remove the general retained-tail rebuild from the actual-input path. This is co-#1 with RC1 — RC1 is "wrong thread," RC2 is "wrong amount of work"; both must be fixed to hit responsive feel. *(The secondary dab-memoization idea from my first draft still applies but is minor and GPU-dependent — see the ledger; do it only after RC1+RC2.)*

### RC-Taper — End taper is retroactive, so the stroke endpoint visibly retreats after release [new; confirmed]

End-taper strength depends on `totalDistance - dab.sourceDistance` (`BrushDynamicsEngine.swift:582-586`), unknowable until pointer-up. At finish, `knownStrokeTotalDistance` is set (`GridRenderer.swift:2722`) and the tail is re-evaluated through `applyingKnownTotalDistance` (`:3116-3126`), shrinking already-drawn end dabs toward `minimumSize 0.08`/`minimumFlow 0.25` over the last **1.5 diameters** (`ProfessionalBrushDefinitions.swift:143-148`). The drawn line therefore **retracts behind the released cursor** — a jarring, un-tactile artifact and a first-order "feels wrong" cause. It also forces the `.replayTail` policy that drives RC2.

Krita: taper is causal (evaluated from available pressure/speed as dabs are emitted); the completed body of a stroke is never revised.

**Fix:** make taper causal by default — evaluate end easing only from actual samples as they arrive; if any retroactive easing is kept, bound it to a tiny declared window whose maximum visible endpoint displacement is tested. Removing retroactive taper is also what lets professional brushes move to `.appendOnly` (RC2).

### RC3 — Fixed-resolution baked masks + flat color, all composited in 8-bit gamma sRGB

Three compounding facts:

*   **Masks baked once at 64/128/256px and bilinearly upscaled** to any diameter (`BrushTextureFactory.swift:60,74,176`). Only `hardRound` is analytic (`Shaders.metal:414`). A 300px soft brush is an upsample of a 64² mask → blurry/mushy.
*   **All blending in gamma space, 8-bit.** Every target is `.bgra8Unorm` (not `_srgb`, not `rgba16Float`) — `CanonicalRaster.swift:19` and every other target. `patternSourceOver` (`Shaders.metal:840`) runs `src + dst*(1-src.a)` on gamma-encoded bytes. No `toLinear`/`toSRGB` anywhere in the paint path. → soft edges get dark halos, gradients bow toward black, low-flow glazes band/posterize.
*   **Display re-composites 3 textures 4x per fragment** for bilinear (`Shaders.metal:906`), then bilerps gamma-composited samples (reintroduces fringing).

This is the biggest single contributor to "inorganic."

Krita: analytic `KisCircleMaskGenerator::valueAt` at the true dab size; `KisQImagePyramid` nearest-level + fractional residual transform; all math through `KoColorSpace` with **premultiplied linear** alpha-weighted averaging (divide by `totalAlpha`).

**Fix:** composite in linear space — store canonical/live as `rgba16Float` (or at minimum `.bgra8Unorm_srgb` so hardware linearizes on read/write) and convert `InkColor` to linear before packing `premultipliedColor`. Then give soft-round and chisel/ellipse **analytic SDF evaluators** so they are resolution-independent like `hardRound` already is.

### RC4 — Closed, non-extensible engine model; whole media classes structurally impossible

No `KisPaintOpRegistry`/`KisPaintOpFactory` equivalent. Built-ins are `static let`s resolved by a **stringly-typed switch** (`EditorBrushCatalog.swift:26`, matching `"builtin.native-ink"` literals). Most damning:

*   `canvasInteraction` (smudge/pickup/wetMix) is fully modeled and validated **but rejected at compile time** — `BrushCompiler.swift:390` throws `unsupportedBackend`; `:767` throws `unsupportedInteraction`. Destination-sampling media literally cannot paint.
*   `secondaryColorMix` is computed per dab then **silently dropped** at the CPU→GPU boundary — `reserved0`/`reserved1` zeroed (`DepositionStampInstance.swift:150`); the fragment only ever returns `premultipliedColor * coverage` (`Shaders.metal:537`). Dead data-flow.

So there is **no wet/paint mixing at all**; each dab is one flat color that cannot pick up underlying paint.

Krita: registry + `KoPluginLoader` late binding; polymorphic `KisColorSource` (gradient/pattern/random); `KisColorSmudgeOp` samples the destination.

**Fix (do first):** implement **one** destination-sampling deposition path — sample canonical color in `patternDepositionFragment`, lerp by `secondaryColorMix`/wetness. The reserved instance fields and the `usesDestinationSampling` flag are **already plumbed**. This single change unblocks smudge + wet-mix and delivers the wet-media feel. Then add a registry/factory seam so new engines are additive, not central-switch edits.

### RC5 — Naive velocity + single-mode smoothing → dead, noisy, laggy dynamics

*   **Speed axis is inert.** Speed is normalized against `speedReference = maximumWorldVelocity = 100,000 px/s` (`BrushDynamicsEngine.swift:696,26`), and `nextDab` never overrides the default (`BrushStrokeGenerator.swift:409`). Real strokes (500–2000 px/s) map to **0.005–0.02** — the bottom sliver of every speed-driven curve. The test suite itself uses `speedReference: 100`, proving 100k was meant as a safety clamp, not the dynamics reference. **This is the single cheapest high-impact fix in the report.**
*   **Velocity has zero smoothing** — raw single-sample `hypot(dp)/dt` on untrusted timestamps (`BrushInput.swift:263`). Jitters between coalesced/predicted samples.
*   **Direction has no locked-angle fallback** — raw `atan2` (`BrushStrokeGenerator.swift:360`), `lastDirection` seeded to `0` (east), so oriented brushes east-snap at stroke start.
*   **Stabilizer is a single fixed EMA** (`StrokeStabilizer.swift:50`) — no weighted-Gaussian, no delayed-deque, no tail preservation, position-only.

Krita: `KisSpeedSmoother` (timestamp-agnostic, distance-accumulating, 512-deep filtered rolling mean); `directionBetweenPoints` with locked-angle fallback; WEIGHTED (distance Gaussian + tail aggressiveness) and delayed-deque STABILIZER modes.

**Fix:** set `speedReference` to a realistic full-scale (~few hundred px/s) and feed it a `KisSpeedSmoother`-style smoothed velocity. Near-trivial edit that revives an entire dynamics axis. Then add a weighted-Gaussian smoother and lock the direction angle on sub-threshold deltas.

---

## What the dimension analyses missed (concepts absent from laya entirely)

1.  **No non-source-over blend modes, no layers, no real undo model.** Laya has exactly two blend states (premultiplied source-over + `.max` glaze) plus a destination-out eraser. Krita's entire `KoCompositeOp` family (multiply/screen/overlay/dodge/burn) and the layer stack are absent as concepts. First-class capability gap surfaced nowhere in the per-dimension pass.
2.  **No mask border padding for rotated/translated dabs.** Krita adds a 1px CLAMP border per pyramid level + a fake-scale nudge to defeat nearest-neighbor on pure translation. Laya's shape sampler uses `address::clamp_to_zero` with no border → rotated/translated tips hard-clip at the edge on every rotated dab.
3.  **No "rotation follows stroke direction" (rake) mode** and no subpixel-accurate mask sizing (masks are integer-baked then scaled).
4.  **Symmetry/tiling lives only in the projection layer, not the stroke generator** — so symmetry multiplies instance counts instead of being amortized in dab generation.
5.  **No clock input to the stroke generator** — airbrush/time-based emission (`getNextPointPositionTimed`, `qMin(distance, time)`) is architecturally missing, not merely unimplemented. A paused or very slow pen deposits nothing.

---

## Verified defect ledger (post-adversarial-review severities)

Kind: 🐛 bug • ⚠️ bad-decision • 👃 code-smell • ✂️ missing-capability • 🐢 perf. Dropped after verification: the "fresh `BrushDynamicsEngine()` per dab" claim (it is a zero-size stateless struct → n/a).

### Stroke pipeline & dab spacing

| Sev | Kind | Finding | Ref |
| :--- | :--- | :--- | :--- |
| med | ✂️ | Isotropic-only spacing; no anisotropic/elliptical spacing though tips can be elliptical+rotated → gaps/clumping on chisel/calligraphy | `BrushDynamicsEngine.swift:354` |
| low | ✂️ | No time/airbrush emission — stationary/slow cursor deposits nothing | `BrushStrokeGenerator.swift:351` |
| low | ✂️ | No fan-corner dab insertion (largely mitigated: spline resamples direction ≥5x dab density) | `BrushStrokeGenerator.swift:360` |
| low | ⚠️ | Dabs placed by linear interp along fine chords, not analytic arc length (residual is sub-pixel; overstated originally) | `BrushStrokeGenerator.swift:364` |
| low | 🐢 | `maximumSegmentLength=min(0.5, spacing*0.2)` over-subdivides; constant tangent terms recomputed in loop | `BrushStrokeGenerator.swift:60` |

### Input handling / dynamics

| Sev | Kind | Finding | Ref |
| :--- | :--- | :--- | :--- |
| **high** | 🐢 | **Speed normalized against 100,000 px/s → speed axis functionally dead** | `BrushDynamicsEngine.swift:696` |
| med | ⚠️ | Per-sample velocity: no smoothing, trusts raw timestamps | `BrushInput.swift:263` |
| med | ✂️ | One input per output channel; no multi-sensor combination | `BrushProgram.swift:6` |
| med | ⚠️ | Single fixed EMA stabilizer; no weighted/delayed modes, no tail preservation | `StrokeStabilizer.swift:50` |
| low | 🐛 | Direction `atan2` with no zero-length/locked-angle fallback (east-snap at start) | `BrushStrokeGenerator.swift:360` |

### Dab caching & rendering

| Sev | Kind | Finding | Ref |
| :--- | :--- | :--- | :--- |
| med | ⚠️ | Entire dab pipeline pinned to `@MainActor` (RC1) | `DepositionEncoder.swift:109`, `DabInstanceBufferPool.swift:14` |
| med | 🐢 | `validate()` allocates 2 throwaway `[(String, SIMD4)]` arrays **per dab** (not 14 as first claimed; string labels are static) | `DepositionEncoder.swift:453` |
| low | ✂️ | No dab-level cache; dead `hasSameFrozenFields`/`==`. *Correction: "drain-once" only holds for `.appendOnly` brushes; the professional `.replayTail` brushes DO re-pack the tail per event — see RC2, the real cost lives there* | `DepositionEncoder.swift:181` |
| low | 🐢 | O(n²) dirty-rect merge — but hard-capped at 256 then O(1); real cost negligible | `LiveStroke.swift:125` |

### Threading / frame scheduling

| Sev | Kind | Finding | Ref |
| :--- | :--- | :--- | :--- |
| **high** | 🐢 | **`.replayTail` brushes re-project the entire retained tail (≤2,048 dabs) on every input event (RC2)** — all 4 professional presets. Measured: 445 ms CPU prep, ~1.4 s latency. `.appendOnly` fast path exists but is unused. | `GridRenderer.swift:2728-2733, :3081-3135; ProfessionalBrushDefinitions.swift:149` |
| **high** | 🐛 | **Retroactive end taper → endpoint retreats after pointer-up (RC-Taper)** — tail re-evaluated with now-known `totalDistance` | `GridRenderer.swift:2722, 3116; BrushDynamicsEngine.swift:582` |
| **high** | ⚠️ | **Entire live-stroke pipeline on the main actor (RC1)** | `GridRenderer.swift:119` |
| med | 🐢 | `draw(in:)` free-runs every vsync regardless of change (`isPaused=false`, `enableSetNeedsDisplay=false`) | `MetalCanvas.swift:20` |
| low | 🐢 | Synchronous `commit()+waitUntilCompleted()` looped 64x — **but only on the harness/export path, not live input** (impact refuted) | `GridRenderer.swift:2249` |
| low | ✂️ | Fixed per-frame instance budget, no concurrency (budget is 4096/frame; documented lossless flow control) | `FrameScheduler.swift:138` |
| low | ✂️ | No LOD/low-res proxy (impact largely refuted — GPU fills the pixels) | `GridRenderer.swift` |
| low | ⚠️ | Per-sample value-copy of whole generator for rollback (load-bearing for prediction replay, not removable) | `GridRenderer.swift:1210` |

### Brush model / masks / presets

| Sev | Kind | Finding | Ref |
| :--- | :--- | :--- | :--- |
| med | ⚠️ | Tips baked at fixed 64/128/256px, upscaled to any size (RC3) — *not* `hardRound`, which is analytic | `BrushTextureFactory.swift:60` |
| med | ✂️ | `canvasInteraction` (smudge/pickup/wetMix) declared+validated but rejected at compile (RC4) | `BrushCompiler.swift:390` |
| low | ⚠️ | Hardness = crude linear coverage remap, fixed ±1/255 AA (baked softness ramp mitigates) | `Shaders.metal:272` |
| low | ⚠️ | Built-in catalog+tip pixels hardcoded in Swift (but a full data-driven package/import path exists for user brushes) | `BrushTextureFactory.swift:176` |
| low | 👃 | `hardRound` analytic while all others are textures — divergent branches to keep in sync | `Shaders.metal:414` |
| low | 🐢 | Mip/tip baking is scalar single-threaded (cached, off-thread, once per resource — impact overstated) | `BrushTextureFactory.swift:331` |
| low | 👃 | 4-layer Recipe→Definition→Program→Compiled chain + lossy reverse adapter (adapter is test/offline-only, not live path) | `LegacyBrushRecipeAdapter.swift:19` |

### Color / compositing

| Sev | Kind | Finding | Ref |
| :--- | :--- | :--- | :--- |
| med | ⚠️ | All blending in gamma-encoded 8-bit sRGB, not linear (RC3) | `CanonicalRaster.swift:19, Shaders.metal:840` |
| med | 🐢 | Per-pixel re-composite of 3 textures, composite math run 4x for bilinear (RC3) | `Shaders.metal:906` |
| med | ✂️ | `secondaryColorMix` computed per dab then dropped before GPU (RC4) | `DepositionStampInstance.swift:87` |
| low | ⚠️ | No color-space abstraction; `InkColor` is bare 4xFloat RGBA clamped 0..1 (blocks HDR/wide-gamut) | `InkColor.swift:3` |
| low | 🐢 | Per-dab RGB→HSV→RGB in gamma space (fidelity issue more than perf) | `BrushDynamicsEngine.swift:991` |

### Architecture / coupling

| Sev | Kind | Finding | Ref |
| :--- | :--- | :--- | :--- |
| **high** | ⚠️ | **~45% of the `MetalRenderer` shipping library (14,295 / 31,859 LOC) is test/evidence scaffolding** compiled into product code (`Capture/`, `DepositionHarnessRunner.swift` = 4,748 lines). No `#if DEBUG` guards. *Build-time & product-surface problem — verification confirmed the hot path itself is clean.* | `Sources/MetalRenderer/Capture/` |
| med | 👃 | `GridRenderer` God object: 5,575 lines, ~68 stored props (not 548 — that figure was a bad grep), 34 public methods, 15 nested types | `GridRenderer.swift:120` |
| med | ✂️ | No registry/factory/plugin seam; stringly-typed brush resolution (RC4) | `EditorBrushCatalog.swift:26` |
| low | ⚠️ | Recipe/Definition duality + lossy adapter (offline/test-only, guarded by `DepositionLegacyRemovalTests`) | `LegacyBrushRecipeAdapter.swift:19` |
| low | 👃 | `DepositionReference` — full CPU re-impl of the coverage shader in the shipping lib (legitimate parity oracle; belongs in test target) | `DepositionReference.swift:31` |
| low | 🐢 | Per-dab per-channel random hashing computed eagerly even when jitter unused (`SplitMix64`, sub-ns — trivial) | `BrushDynamicsEngine.swift:868` |

### Live-stroke path & product acceptance (from the empirical corrective report; verified here against source)

| Sev | Kind | Finding | Ref |
| :--- | :--- | :--- | :--- |
| **high** | 🐢 | **Retained-tail re-projection per event (RC2)** — see Threading table | `GridRenderer.swift:2728` |
| **high** | 🐛 | **Retroactive endpoint retreat (RC-Taper)** — see Threading table | `GridRenderer.swift:2722` |
| med | 🐛 | **Cursor is a nominal circle**, ignores the evaluated tip (aspect 0.34 ellipse, grain, pressure) — cursor promises 40 px, mark is a 3 px hairline. *(Outside my original 7 dimensions, evidence is concrete.)* | `InteractiveMetalView.swift:354` |
| med | ⚠️ | **Acceptance gate measures internal truth, not user truth** — a 1-pixel Charcoal passes `nonemptyVisibleOutput`; 124/128 missed frame budgets still sets `correctnessPassed=true`. No visibility/latency/backlog floors. | `PerformanceStatusValidator.swift:63` |
| med | ⚠️ | **Professional presets built from validation fixtures + capability combinations, not artist-calibrated assets** — multiplied full-strength masks make Charcoal invisible, Graphite a hairline | `ProfessionalBrushDefinitions.swift`, `BrushTextureFactory.swift:56` |
| med | 🐛 | **Chisel: direct direction→rotation, no fan-corner interpolation** → icicle spikes at turns (upgraded from my "low" after app evidence) | `ProfessionalBrushDefinitions.swift:498` |

---

## Recommended sequence (revised after the empirical cross-check)

The two confirmed live-path defects (RC2 replay cost, RC-Taper) are now the top priority — they are what the user physically feels as "slow" and "the line jumps back." They also unblock each other: killing retroactive taper lets professional brushes move to the existing `.appendOnly` fast path.

1.  **Make end taper causal** (RC-Taper) — stop endpoint retreat; removes the reason professional brushes need `.replayTail`.
2.  **Move professional brushes to `.appendOnly`** (RC2) — the fast path already exists (`GridRenderer.swift:2682`); confine replay to a small bounded prediction overlay. Kills the O(tail) per-event cost. **Biggest measured-latency win.**
3.  **Fix `speedReference`** (RC5) — ~1 line, revives the whole speed axis. Trivial, do alongside.
4.  **Move the stroke coordinator off `@MainActor`** (RC1) — the structural lift; decouples frame time from brush cost. Pairs naturally with steps 1-2 (extract a `StrokeRenderCoordinator`).
5.  **Truthful cursor + real acceptance floors** — derive cursor from the compiled tip footprint; add visibility/latency/missed-frame/endpoint gates so invisible or laggy brushes fail CI (they currently pass).
6.  **Composite in linear space** (RC3 color) — `rgba16Float`/`_srgb` + linearize `InkColor`. Kills dark halos/banding.
7.  **Analytic SDF for soft-round + chisel** (RC3 mask); **fan-corner interpolation** for chisel turns.
8.  **Rebuild the 4 professional presets** from calibrated assets, one at a time, each admitted independently.
9.  **Then:** destination-sampling path (RC4 wet media), multi-sensor dynamics, weighted stabilizer, blend modes/layers, registry seam, evict `Capture/` from the shipping library.

**Governance note (from the corrective report, endorsed):** the current professional presets should not be labelled "professional"/"realtime120"/"software complete" until they pass visibility, latency, endpoint, cursor, and manual-review gates. Adopt distinct acceptance states (`engineIntegrated ≠ productAccepted`).

**License note:** krita is GPL-2.0-or-later. Study its behavior/algorithms, implement clean-room in Swift/Metal from this report — do not copy krita source. Laya also needs an explicit project license before distribution.

*Provenance: the ledger + RC1/RC3/RC4/RC5 come from a 61-agent static-analysis workflow with per-finding adversarial verification (`.claude/brush-compare-workflow.js`). RC2 and RC-Taper were confirmed by direct source reading after cross-checking `docs/superpowers/reports/2026-08-01-brush-engine-corrective-report.md`, which reached them empirically by running the app. Where the two reports overlap they now agree; where they diverged, the corrective report was right on the live-stroke path and this report was right on threading/color/masks/dynamics/extensibility.*
