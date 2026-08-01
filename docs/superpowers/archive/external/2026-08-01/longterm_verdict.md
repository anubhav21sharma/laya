# Is laya on track to a world-class brush engine? — Long-term verdict

**Question:** if we make the fixes in `KRITA_VS_LAYA_BRUSH_ENGINE_REPORT.md`, does the *current architecture* reach world-class, butter-smooth, fun-to-use — or should we do something fundamentally different like krita?

**Stated bar (your answer):** the full natural-media suite — krita-class breadth: wet/smudge/bristle engines, a full layer stack, blend modes, many media. Patterns are one feature among many. This is the ambitious end, and the verdict below is judged against *that* bar, not the narrower pattern-niche bar.

## Verdict in one paragraph

**Keep the architecture. Do not rewrite as krita.** The fixes are necessary but the core model — a GPU-instanced, canonical-raster, value-typed, deterministic deposition engine — is *the right foundation for Apple hardware* and is, if anything, closer to what a modern engine should be than krita's 15-year-old CPU-paint-device design. Laya's problems are **wrong policies on a right foundation** (retroactive taper, replay-tail, main-actor coupling, gamma color), not a wrong foundation. **However**, hitting the *full-suite* bar requires two architectural extensions the current design does not have and cannot fake: **(1) real destination-sampling** for wet/smudge, and **(2) a compositing/layer model with blend modes**. Both are additive seams, not rewrites — but they must be *designed in now* so today's shortcuts don't calcify into walls. The honest risk is not the engine; it's **scope and calibration discipline** (the pattern that produced an invisible Charcoal will reproduce at suite scale unless the acceptance gate is fixed first).

## Why NOT rewrite like krita

Krita's architecture is excellent *for what krita is* — a cross-platform, CPU-first, 8-to-32-bit, color-managed, general raster+animation suite that must run on a 2009 Linux laptop with no dependable GPU. Its central mechanisms exist to make **CPU pixel pushing** fast:
*   `KisDabCache` + Copy-jobs + `PooledMemoryAllocator` — because rasterizing a dab on the CPU is expensive, so you memoize the *pixels*.
*   `KisQImagePyramid` — because CPU rescaling is expensive, so you precompute mip levels in RAM.
*   `KisUpdaterContext` thread pool with `UNIQUELY_CONCURRENT` — because you must parallelize CPU compositing across cores.
*   Tiled paint devices + `KisTileManager` — because a full-canvas CPU buffer at 16-bit is huge and must be paged.

**Laya is GPU-instanced.** On Apple silicon with Metal, the equivalent work is *free or near-free on the GPU*: dab rasterization is a fragment-shader fill, scaling is hardware trilinear sampling, and thousands of dabs composite in one `drawPrimitives` instanced call. **Porting krita's CPU-era optimizations to laya would be building elaborate machinery to solve problems the GPU already solved.** The corrective report reached the same conclusion independently (§6.6, §12.3: "do not create a separate bitmap for every transformed stamp when the GPU can sample one source texture through an affine frame"). A krita-style rewrite would be *slower to build and no better* — possibly worse, because you'd be fighting the platform.

The parts of krita worth stealing are **algorithms and policies, not classes**: incremental append-only deposition, causal spacing/taper, the sensor/curve dynamics model, fan-corner interpolation, linear premultiplied color, the paintop registry. All of those are portable into laya's existing model as *policy changes and additive seams*. None require its architecture.

## Why the current foundation is genuinely good

These are strengths krita would envy, and they are the hard parts to get right:

1.  **Deterministic, value-typed core.** `BrushDefinition`/`BrushProgram` are immutable value types; dynamics are pure functions with seeded RNG. This makes the engine *testable, replayable, and reasoning-friendly* — laya already has offscreen trace replay, negative controls, and content-hashed provenance. Krita cannot easily reproduce a stroke bit-for-bit; laya can. For long-term maintainability and AI-assisted work, this is a major asset.
2.  **Canonical raster as single source of truth + one-command-per-stroke history.** Clean, correct undo/commit semantics. This is exactly the invariant a suite needs.
3.  **GPU-instanced deposition** — the right primitive for Apple hardware and for the *symmetry moat* (one logical dab -> N transforms in one instanced draw). Krita's tiling is CPU work per copy; laya's is nearly free.
4.  **The engine already contains the correct fast path** (`.appendOnly`) and the correct backend split (deposition vs a reserved `canvasInteraction` backend, and `usesDestinationSampling` is already plumbed). The good decisions were *made*; they're just not *wired up*.

The corrective report's own "Retain" list (§6.1) and the shared conclusion here agree: normalized input, deterministic dynamics, logical dabs, symmetry projection, canonical raster, history, compiled pipelines, resource budgets — all sound. That is most of an engine.

## What the fixes get you — and what they DON'T

**The report fixes get you to "butter-smooth + fun for dry/ink/marker."** RC1 (off-main), RC2 (append-only), RC-Taper (causal), RC5 (speed axis), RC3 (linear color + analytic masks), fan-corners — after these, ordinary drawing is responsive, edges are crisp, color is correct, and the pattern moat shines. That is a *shippable, excellent* v1 for the dry-media + pattern use case.

**They do NOT, by themselves, get you the full natural-media suite.** Two capabilities are structurally absent today and are not on the current fix list as first-class architecture:

### Gap A — Wet / smudge / paint-mixing needs real destination sampling and bounded stateful tiles

Today every dab is one flat premultiplied color; `secondaryColorMix` is computed then dropped. RC4 proposes the *first step* (sample canonical color in the fragment, lerp by mix). But a **credible wet/smudge/bristle suite** needs more than a lerp:
*   the interaction backend must **read destination paint** and carry **ordered, bounded per-tile state** (pickup reservoir, dilution, dry-down) across dabs — this is inherently stateful and order-dependent, unlike the current stateless instanced deposition;
*   it interacts badly with pure GPU instancing (instanced draws have no defined intra-draw ordering), so smudge dabs likely need **sequential encoding or tile-serialized passes**, a different scheduling shape than deposition.

This is exactly why krita has a **separate `KisColorSmudgeOp` and `hairy` engine rather than bolting wetness onto the pixel brush.** Laya's reserved `canvasInteraction` backend is the right intent — but it is currently a rejected stub. **Reaching the suite bar means actually building that second backend, and its scheduling model is not free-riding on the deposition path.**

### Gap B — Layers + blend modes need a compositing model the renderer doesn't have

The **file format** has `PatternProjectLayer` (up to 8 layers per the design doc), but the **renderer** composites a single canonical raster with exactly two blend states (premultiplied source-over + `.max`) plus a destination-out eraser. A suite needs:
*   an N-layer stack the renderer composites every frame (or caches);
*   the `KoCompositeOp` family (multiply/screen/overlay/dodge/burn/...);
*   per-layer opacity/mode/clipping.

None of that exists in the render path. It's additive — but it's real work, and it wants **linear-space compositing (RC3) done first** or every blend mode will be subtly wrong.

### Latent scaling concern — single full-canvas textures, not tiled

Canonical raster is a single `MTLTexture` (`front` + `scratch`), capped at 4096². For v1 that's fine (GPU eats a 4096² composite trivially). But a *suite* with 8 layers x blend modes x larger canvases means 8+ full-canvas textures re-composited per frame. At 4096² x 8 layers x `rgba16float` that's ~1 GB of texture just for layers, re-read every vsync by the current "re-composite everything each frame" display path (RC3 perf finding). **This is the one place laya may eventually need krita-like tiling** — dirty-tile compositing so only changed regions recomposite. Not a v1 blocker; a v2/v3 design constraint to keep in mind. Design the layer compositor with a dirty-rect/tile interface from day one so it can be made tiled later without a rewrite.

## The real long-term risk isn't the engine — it's discipline

The most alarming thing in the evidence is not any single bug. It's the **pattern**: four "professional" presets were built from capability-combinations and validation-fixture textures, one renders as *a single pixel* yet passed the gate (`nonemptyVisibleOutput`), and the acceptance status still read `correctnessPassed = true` with 124/128 frames missing budget. **A gate that measures internal invariants but not user-visible truth will let a full media suite ship broken at 10x the surface area.** Before scaling breadth, the acceptance model must fail invisible output, cursor/mark mismatch, endpoint retreat, and latency/backlog — and "engine-integrated" must stop being spoken as "product-complete." This is cheap to fix and is the highest-leverage process change for the long game.

Likewise: **assets and calibration are not an engine problem and no architecture fixes them.** World-class *feel* comes from artist-calibrated tips/grains and per-brush tuning, reviewed by eye. Budget for that loop; it's the difference between "technically correct" and "fun to use."

## Recommendation (long-term plan)

**Evolve, don't rewrite. Sequence it so each phase is shippable and no phase paints you into a corner.**

**Phase 1 — Make the current model live up to itself (the report's fixes).** Causal taper -> `.appendOnly` for pro brushes -> off-main `StrokeRenderCoordinator` -> speedRef -> linear color -> analytic masks -> fan-corners. Fix the acceptance gate *first* so the rest is measured honestly. **Outcome: butter-smooth dry/ink/marker + the pattern moat. This is a real, shippable world-class v1 for its niche.**

**Phase 2 — Build the two suite-enabling seams as first-class architecture (design now, even if built later).**
*   **Interaction backend** (wet/smudge/bristle): destination-read + bounded per-tile stateful passes, sequential/tile-serialized scheduling. Treat it as a *sibling* of deposition (as krita does), sharing input/dynamics/symmetry/commit but NOT the stateless instanced draw. Wire up the already-reserved `canvasInteraction` path for real.
*   **Layer compositor + blend modes:** N-layer stack, `KoCompositeOp`-equivalent family, in linear space, behind a **dirty-rect/tile interface** so it can go tiled later.

**Phase 3 — Scale + harden.** Dirty-tile compositing when layer count/canvas size demands it; LOD only if profiling on real devices shows big brushes stutter (GPU fill has hidden it so far); the registry/factory seam so new engines are additive; artist-calibration loop for every shipped preset.

What **"doing something entirely different like krita" would cost you:** throwing away a determinism/replay/provenance system that is *better* than krita's, rebuilding CPU machinery to solve GPU-solved problems, and losing the instanced-symmetry moat — for no feel benefit. The only krita idea worth adopting wholesale is its **multi-backend boundary** (deposition ≠ smudge ≠ bristle), and laya *already chose that boundary* on paper. Finish wiring it.

**Bottom line:** on track — conditionally. The foundation is world-class-capable and correctly Apple-native. It becomes world-class if you (a) ship the report's fixes, (b) fix the acceptance gate before scaling, and (c) build the interaction backend and layer/blend compositor as real, designed-in seams rather than shortcuts. Rerouting to a krita-style architecture would be a strategic mistake.
