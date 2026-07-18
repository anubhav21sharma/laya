# Colored brush + picker — design (2026-07-01)

## Context
PatternSpike draws only **black** ink today: `dab_fragment` returns a hardcoded `float4(0,0,0,a)`. This is step 1 of the drawing-tools roadmap (`docs/superpowers/07-drawing-tools-roadmap.md`). Its purpose is dual: ship a usable ink-color feature, and — more importantly — install the **per-dab attribute seam** (a dab carries render attributes beyond geometry) that every later tool reuses: the eraser's blend mode, the raster brush's hardness/brush-id. Color is the cheapest, lowest-risk client to prove that seam on.

Scope is deliberately tight: **ink color only**. Paper/background color (the drawable clear color) is a separate subsystem and is out of scope. Per-dab interpolated pressure (smooth radius/alpha/color taper along a segment) is a known pre-existing limitation, explicitly **deferred** (see Non-goals).

## Decisions (from brainstorming)
*   **Ink color only** — paper stays white.
*   **Native SwiftUI `ColorPicker`** in the toolbar (works macOS + iPad; no custom palette).
*   **Dab carries RGBA**; final alpha = `picked-alpha * pressure-alpha` (multiply).
*   `EditorModel.inkColor` + `setInkColor(_, :)`, bound to the picker. **No keyboard shortcut**.
*   **Approach A** (full per-dab RGBA on the instance), over a per-commit uniform (B — can't do the per-dab seam) or a parallel color buffer (C — over-engineered). The dab carries color as its own attribute, exactly like the clip fields already do.
*   **Color is constant per stroke/segment** (applied at `emit` time like radius/alpha), NOT interpolated. The `StrokeInterpolator` stays position-only.

## Architecture / data flow
Color rides the existing path as a per-dab attribute (nothing in the pipeline shape changes):

```
EditorModel.inkColor (SIMD4<Float> RGBA)
-> renderer passes it into StrokeSession.emit(..., color:)
-> emit stamps color onto every DabSpec in the batch (constant per segment)
-> Dabicalonical0f: spec) copies color
-> DabInstance.color (GPU)
-> dab_vertex forwards color to dab_fragment
-> dab_fragment returns float4(color.rgb, color.a * pressureAlpha)
```

## Components changed
*   `Sources/EditorCore/EditorModel.swift` — add `public private(set) var inkColor: SIMD4<Float> = SIMD4(0,0,0,1)` (opaque black default = today's look) + `public func setInkColor(_ c: SIMD4<Float>) { inkColor = c }`. Read `inkColor` in `ContentView.body` (with the other config) so `@Observable` registers the dependency and the view re-pushes on change.
*   `Sources/PatternEngine/DabSpec.swift` — add `var color: SIMD4<Float>` with default `SIMD4(0,0,0,1)` in the initializer (so every existing call site + test compiles unchanged).
*   `Sources/PatternEngine/StrokeSession.swift` — `emit(_ worldPoints:pressure:color:)` gains a `color: SIMD4<Float>` parameter; every `DabSpec` it constructs (primary, wrap copies, parity completions) is stamped with that color. `begin/addSample/end/ingest` thread the color through, sourced from the session's ink color. The session captures ink color at `init` (a stored `let color`), not per-sample: color can't change mid-stroke (the user is drawing), so a per-stroke constant is correct and simplest. A new stroke picks up the current `model.inkColor`.
*   `Sources/CShaderTypes/include/ShaderTypes.h` — extend `DabInstance` with `simd_float4 color;`. New layout (16-byte aligned): `center@0(8) radius@8(4) alpha@12(4) clipThreshold@16(4) clipMode@20(4)`
*   `Sources/CShaderTypes/include/ShaderTypes.h` — extend `DabInstance` with `simd_float4 color;`. New layout (16-byte aligned): `center@0(8) radius@8(4) alpha@12(4) clipThreshold@16(4) clipMode@20(4)` `color@32(16)` + pad to keep alignment. `Stride 32 -> 48`. (color must be 16-byte aligned, so it lands at @32; @24–@31 stay pad. Final struct = 48 bytes.)
*   `Sources/MetalRenderer/DabInstance.swift` (Swift Dab) — mirror: add `color: SIMD4<Float>`, keep byte-for-byte layout parity with the C struct; `Dab(canonical0f: spec)` copies `spec.color`.
*   `Sources/MetalRenderer/Shaders.metal` — `DabOut` gains `float4 color`; `dab_vertex` sets `out.color = d.color`; `dab_fragment` returns `float4(in.color.rgb, in.color.a * a)` (was `float4(0,0,0,a)`). No pipeline/blend-state change — straight-alpha commit blend already composites colored dabs correctly. Clip discard logic untouched.
*   `App/PatternSpike/ContentView.swift` — add a `ColorPicker("Ink", selection: <binding>, supportsOpacity: true)` to the toolbar. A computed `Binding<Color>` bridges `model.inkColor` (`SIMD4<Float>`) ↔ SwiftUI `Color`: `get = Color(from SIMD4)`, `set = model.setInkColor(SIMD4 from Color)`. Add the `Color ↔ SIMD4<Float>` conversions (plain sRGB component values; no color-space management, consistent with the untinted `bgra8Unorm` pipeline today).
*   `Renderer/session wiring` (`SpikeRenderer` / `PatternCanvasView`) — where the app builds a `StrokeSession` (and where the harness does), pass the current ink color so `emit` stamps it. The app reads `model.inkColor`; the harness supplies a scene color.

## What does NOT change
`StrokeInterpolator` (position-only), `BrushDynamics` (pressure→radius/alpha only; color is not a dynamics property), the blend pipelines, the tiling fold, the clip logic, viewport, layers (none). The brush **cursor ring** stays grey (a size indicator, not a color swatch).

## Testing / verification
*   **swift test (headless)**: extend `Tests/MetalRendererTests/LayoutTests.swift` to assert `MemoryLayout<Dab>.stride == MemoryLayout<DabInstance>.stride == 48`. Add a `PatternEngine` test that `emit(..., color:)` stamps the given color onto every `DabSpec` in a batch (primary + wraps + completions).
*   **Render harness (GPU, headless)**: add a `colored-brush` scene — draw a stroke with a non-black ink color (e.g. red, alpha 0.8), pixel-assert the dab center's `RGB` = the picked color (not black) and `alpha` = `pickedAlpha * pressureAlpha`. Fold into `--all`. This is the definitive end-to-end proof of the GPU color path.
*   **Regression**: existing harness scenes (phantom asserts, tiling-switch) still pass — the `dab_fragment` change is additive and must not disturb the clip/alpha behavior. macOS + iOS builds green.
*   **Manual (minimal, unavoidable)**: the `ColorPicker` UI itself is SwiftUI input (not harness- or `swift test`-drivable) — one manual check that picking a color changes the stroke color live.

## Non-goals / deferred
*   **Paper/background color** — separate subsystem (drawable clear color); trivial follow-up.
*   **Per-dab interpolated pressure** — the pre-existing per-segment quantization of radius/alpha (documented in the roadmap). Colored brush inherits it (color is constant per segment like radius/alpha) and does NOT fix it. Deferred to its own brush-era step: interpolator emits `(position, pressure)`, `emit` computes radius/alpha/color per dab from arc-length-lerped pressure.
*   **Preset palette / keyboard color cycling** — not now (native picker only).
*   **Color-varies-along-stroke** (gradient/velocity brushes) — future; would compute per-dab in `emit`, never inside the interpolator.