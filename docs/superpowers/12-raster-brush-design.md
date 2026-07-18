Raster Brush System — Design Spec (drawing-tools step 5)

Date: 2026-07-03 Status: Approved (brainstorming) — next: implementation plan (writing-plans).
Context

PatternSpike’s tiling engine and drawing tools (color, eraser, undo/redo, selection+transform renderer seams) are done. Step 5 is the raster brush system — the roadmap’s explicitly named "make-or-break" feature. Its purpose is twofold: ship a real, Procreate-class textured brush, and prove a low-latency emit -> stamp -> commit loop on the seams steps 1–4 installed (per-dab attributes, per-dab blend, snapshot undo, the vertex-matrix/textured-quad primitive, the provisional channel, canonicalToWorld, premultiplied-alpha pipeline). Emit-and-forget stays — the canonical texture is the retained artifact; the brush churns dab attributes, not the storage model.

The current dab is a procedural SDF disk (dab_fragment: 1 - smoothstep(length(local))), Dab/DabInstance is a 48-byte stride with one free slot (_pad1 @28) and color @32, pressure is quantized per interpolated segment (the interpolator walks positions only), and the live tile stamps only new dabs per frame (append-only, composited over canonical each frame).

Scope: the full brush system in one spec (user decision), designed as bounded components so it can be built incrementally on the existing spine.
Goal

A dual-texture (shape × grain) raster brush with per-dab pressure dynamics, flow/opacity separation with a true stroke-opacity ceiling, input stabilization, and a small built-in preset library — matching how Procreate/Photoshop actually work — riding the existing emit→stamp→commit spine with the tiling fold, wrap-placement, and snapshot-undo seams unchanged.
Architecture — the emit→stamp→commit spine (unchanged shape, extended stages)
Swift

StrokeSample(pos, pressure)                   // EditorCore, pure fn, BEFORE interpolation
-> [NEW]   Stabilizer.smooth(strength)       // now carries pressure per emitted point
-> [CHANGED] StrokeInterpolator              // pressure; + scatter/rotation dynamics
-> [CHANGED] StrokeSession.emit              // + rotation, hardness, flow
-> [CHANGED] EmittedDab / DabSpec            // stride 48 -> 64 (see "GPU layout")
-> [CHANGED] Dab / DabInstance (GPU)         // shader samples shape × grain (see "Shader")
-> [CHANGED] LiveTile.stampNew               // stroke-opacity ceiling
-> [CHANGED] tiling composite: canonical ⊕ live×OPACITY  // SAME formula (WYSIWYG); undo unchanged
-> [CHANGED] commitOverlay: bake live×opacity -> canonical

Nothing about the tiling fold, worldToCanonical, wrap-placement, DabClip, or the commitOverlay() undo seam changes. The tiling fold still stamps the shape in canonical space, so shapes wrap across tile seams exactly as today's disk does.
Module boundaries (each independently testable)

    EditorCore (pure, swift test): BrushPreset value type; EditorModel.activeBrush (source of truth, one-way flow like tiling/activeTool); Stabilizer (pure point-stream fn); pressure→size and pressure→flow response curves. No Metal.

    PatternEngine (pure): pressure-carrying StrokeInterpolator; StrokeSession.emit dynamics (per-dab pressure, scatter, rotation); DabSpec growth. No Metal.

    MetalRenderer: dual-texture dab_fragment; procedural built-in shape/grain generators; rotation in dab_vertex; live-tile-at-opacity composite; 64-byte Dab/DabInstance + LayoutTests.

    App: brush preset picker + size/flow/opacity controls in the toolbar; one harness scene per capability.

GPU data layout — Dab / DabInstance grows to 64 bytes

The brush adds three per-dab floats: rotation (oriented/scattered stamps), hardness (falloff sharpness), flow (per-dab paint rate; the existing alpha field is re-semantic'd to flow×pressure coverage). Shape and grain are bound per stroke (one each, Procreate-style), so neither needs a per-dab slot. _pad1 @28 absorbs rotation; hardness pushes the stride to the next 16-byte-aligned size, 64.
C++

typedef struct {           // offset (bytes)
  simd_float2 center;     // @0   canonical center
  float radius;           // @8   canonical radius (per-dab, pressure-driven)
  float alpha;            // @12  per-dab coverage == FLOW × pressure (re-semantic'd; field kept)
  float clipThreshold;    // @16  existing half-drop/brick sliver clip
  float clipMode;         // @20  existing
  float blendMode;        // @24  0=normal, 1=erase (existing; consumed at commit)
  float rotation;         // @28  NEW - was _pad1; stamp angle (radians)
  simd_float4 color;      // @32  straight RGBA ink (existing)
  float hardness;         // @48  NEW - falloff sharpness 0..1
  float _pad2;            // @52  NEW pad
  // @56..63 tail padding to 64-byte stride (color forces 16-byte alignment)
} DabInstance;            // stride 64

    The Swift Dab mirror grows in lockstep; the Dab ↔ DabInstance stride precondition in SpikerRenderer.init and LayoutTests guard the 64-byte drift (update the assert 48→64).

    Stroke opacity is NOT per-dab — it is the live-layer composite ceiling (see below), so it needs no slot.

    Alternative considered (packing rotation+hardness into _pad1 as float16 to stay at 48) rejected: saves bytes we don’t need to save (single-digit KB/frame at the 8px spacing cap), costs readability, and leaves no room for the next attribute.

Dual-texture shader & compositing (the make-or-break core)
Built-in textures (procedural, generated once at renderer init — no asset files)

    Shapes (silhouette, sampled in the dab’s local [-1,1]²): soft round (smoothstep falloff, hardness-parameterized) and hard round. The soft round at hardness→0 reproduces the current procedural disk exactly (regression safety net).

    Grains (texture multiplied under the stroke, grayscale, seamless/tileable): a couple of paper/ noise patterns.

Stored as the two per-stroke binding points (one shape texture, one grain texture bound per stroke). Real PNG shapes/grains (import) layer on later as "load into the same two binding points" - no schema change. (A texture-array with a per-dab index was rejected: real brushes get variety from scatter/rotation/pressure on ONE shape, not from mixing tip images mid-stroke — matching Procreate, whose .brush file embeds exactly one shape + one grain.)
dab_fragment (the core primitive — replaces the SDF disk)
C++

float shapeA = shape.sample(s, localUV).r;   // localUV from the (rotated) unit quad
shapeA = hardnessRemap(shapeA, in.hardness); // hardness sharpens the shape's own ramp
float grainA = grain.sample(gs, grainUV).r;   // grainUV per grain mode (below)
float a = shapeA * grainA * in.alpha;        // in.alpha == per-dab flow × pressure
return float4(in.color.rgb, in.color.a * a);

    Rotation applied in dab_vertex: rotate the unit-quad corners by d.rotation before the canonical placement (reusing the vertex-matrix idea proven by the selection pipeline).

    Grain mode is a per-stroke uniform bit (like LiveStrokeErases / grid bits):

        Texturized — sample grain by canonical position (grain fixed to the tile -> tiles seamlessly with the pattern).

        Moving — sample grain in the per-dab local frame (streaky/smeared). Documented limitation: moving grain does NOT tile seamlessly across the wrap seam (local frame vs. canonical fold) — same class as the existing per-strategy radius cap.

Flow vs. opacity — WYSIWYG stroke-opacity ceiling

Dabs accumulate into the live tile at full flow (source-over, as today) -> self-overlap builds up = flow. The tiling pass composites canonical ⊕ (liveTile × strokeOpacity) — the live layer is scaled by opacity once, so overlaps within the stroke cannot exceed opacity (the ceiling). commitOverlay bakes liveTile × opacity into canonical using the identical formula.

WYSIWYG-commit invariant (load-bearing, per user requirement "opacity must not change on mouseup"): the live-preview composite and the commit composite MUST be the same formula, same opacity, same blend, single accumulation buffer. Consequences the design commits to:

    The live tile is ONE accumulation buffer composited ONCE at opacity — never bake dabs individually at flow×opacity into canonical (that would multiply overlaps and darken past opacity, and differ live vs. baked).

    Live tile and canonical are both bgra8Unorm premultiplied -> live × opacity rounds identically at preview and commit (exact, no 1/255 drift). Scaling a premultiplied layer by a scalar is premultiplied-safe (rgb and a scale together) -> no grey-fringe regression.

    Erase previews and commits with the identical destination-out formula (erase "strength" applied the same in both), so the same no-jump-on-mouseup invariant holds for erasing. Undo is unchanged (snapshot at the commit seam); opacity is just a scalar on the live→canonical blend.

Pressure dynamics — per-dab, not per-segment

Fix the roadmap’s named limitation: the interpolator emits (position, pressure) per point via arc-length lerp of the incoming sample pressures, so StrokeSession.emit computes radius and flow per dab — smooth taper, no segment stepping.

    pressureSize (on/off) -> radius = lerp(minRadius, size, pressure^curve).

    pressureFlow (on/off) -> flow = lerp(minFlow, flow, pressure^curve).

    opacity is the per-stroke ceiling (separate from flow), applied at composite (above).

    pressureCurve is the response exponent (a single tunable).

Input stabilization

A lightweight, tunable Stabilizer (pull-toward-pointer or 1€ filter) runs in EditorCore BEFORE the interpolator, strength 0..1 (0 = raw). Pure function on the point stream -> unit-testable. The interpolator remains the geometry (Catmull-Rom) layer.
Config model, presets, UI
Swift

BrushPreset (EditorCore value type, Equatable/Sendable)
BrushPreset {
  shape: BuiltinShape            // .softRound | .hardRound
  grain: BuiltinGrain?           // nil = no grain
  grainMode: GrainMode           // .texturized | .moving
  size: Double                   // base radius
  spacing: Double                // fraction of radius; the on-screen dab step reuses the EXISTING
                                 // cap logic (currently max(1,min(8,radius*0.25)) in the view) but
                                 // the fraction now comes from the preset, not a view constant -
                                 // move that computation to read activeBrush.spacing.
  hardness: Double               // 0..1
  flow: Double                   // 0..1 per-dab paint rate
  opacity: Double                // 0..1 stroke ceiling
  pressureSize: Bool
  pressureFlow: Bool
  pressureCurve: Double          // response exponent
  scatter: Double                // positional jitter
  rotationMode: RotationMode     // .fixed | .followDirection | .random
  streamline: Double             // stabilizer strength 0..1
}

    EditorModel.activeBrush: BrushPreset — private(set), mutated only by semantic actions (one-way flow, like tiling/activeTool). Built-in presets (static): Soft Airbrush, Hard Ink, Chalk (grain), Pencil (grain).

    UI (v1, minimal): the toolbar's .draw tool gains a preset picker (radio row, like the tiling icons) + live size / flow / opacity controls. The existing inkColor picker stays as brush color; existing brush-size keys/steppers rebind to activeBrush.size.

    Full per-parameter editing (hardness, scatter, curves) and PNG import are fast-follows; the BrushPreset type already holds those fields, so the editor panel is additive with no refactor.

Verification

    Unit (swift test, no GPU): Stabilizer (strength 0=identity, 1=heavy lag, monotonic); pressure→size/flow curves; interpolator emits (position, pressure) with arc-length-lerped pressure; BrushPreset defaults + built-ins; LayoutTests updated to 64-byte stride (and Dab==DabInstance).

    Harness (GPU, render-to-PNG; add scenes):

        brush-textured-stamp — hard-round vs soft-round: assert crisp vs feathered edge.

        brush-grain-texturized — grain shows through a flat stroke AND tiles seamlessly across the wrap seam (assert grain pattern present + seam continuity).

        brush-grain-moving — streaky grain renders; NOT asserted seamless (documents the limitation).

        brush-pressure-taper — ramped-pressure stroke: assert radius/flow vary dab-to-dab (no stepping).

        brush-flow-opacity — overlapping dabs at opacity<1: assert overlap alpha ≤ the opacity ceiling.

        brush-wysiwyg-commit — capture the tiled-screen preview (live tile composited at opacity<1), then commit, then capture canonical; assert the two match at the stroke pixels (within the harness's 8-bit tolerance). This makes "no opacity jump on mouseup" a regression test.

    Live-only (user-verified; not headless-testable): actual pen feel/latency (roadmap already flags latency as on-device-only), stabilizer feel, preset switching in the toolbar.

Known limitations (intentional, documented)

    Moving grain does not tile seamlessly across the wrap seam (stroke-local frame vs. canonical fold) — same class as the existing per-strategy radius cap. Texturized grain tiles seamlessly.

    Cross-tiling reuse of a grained/textured stroke inherits the existing "canonical tile is fold-specific" limitation (switching tiling after drawing can break seams).

    v1 has no PNG import and no per-parameter brush editor — both fast-follows; the data model already supports them.

Build order (for the implementation plan)

    Grow Dab/DabInstance to 64 bytes; update LayoutTests + the stride precondition.

    Pressure-carrying StrokeInterpolator (emits (position, pressure)); StrokeSession.emit per-dab radius/flow from arc-length-lerped pressure; scatter/rotation dynamics; DabSpec growth.

    Procedural built-in shape (soft/hard round) + grain generators in MetalRenderer.

    Dual-texture dab_fragment (shape × grain, hardness remap, grain-mode uniform) + rotation in dab_vertex.

    Live-tile-at-opacity composite + the WYSIWYG-commit invariant (preview ≡ commit); erase parity.

    BrushPreset + EditorModel.activeBrush + built-in presets (one-way flow).

    Stabilizer (EditorCore pure fn) before the interpolator.

    Toolbar preset picker + size/flow/opacity controls.

    Harness scenes (the six above) + unit tests.

Each step is independently unit- or harness-verifiable; the core stamp loop (1–5) proves the make-or-break bet before the config/UI layer (6–8) lands.