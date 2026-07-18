# Design — Seamless Pattern Creator (Apple-Native Pivot)

**Date:** 2026-06-12 **Status:** Approved design, pending implementation plan **Supersedes:** The Flutter-based `ARCHITECTURE.md` and `IMPLEMENTATION_PLAN.md` (retained in git history only).

## 0. Why This Document Exists

The project began as a cross-platform Flutter app (iPad, macOS, Android, Windows, phones). We are pivoting to **Apple-only (iPad + macOS)** and **discarding all existing Dart code** to rebuild natively in **Swift + Metal**.

The original Flutter choice was justified by one principle — "one codebase, all platforms" (P3). Once the target is Apple-only *and* the existing code is being discarded regardless, that justification disappears. What remains is a latency-critical drawing app whose #1 principle is "brushes must feel immediate" (P1). Native Swift + Metal gives the best possible control over that hot path, in the ecosystem the quality bar (Procreate) actually lives in.

**The engine *design* carries over; only the *tech binding* changes.** Coordinate systems, tiling math, the layer model, undo model, file format, and export families are platform-agnostic and survive intact. The Flutter/Dart binding is replaced by Swift/Metal.

---

## 1. Scope & Platform

A native Apple app for illustrators to create seamless repeating patterns. The user draws with high-quality brushes; every stroke replicates live across the canvas according to the chosen tiling. **Latency is the product** — target input-to-pixel under ~20ms, 120Hz ProMotion on iPad.

* **Targets:** iPadOS (primary — where illustrators work) + macOS. iPhone/phone layout is parked, not a v1 target.
* **Stack:** Swift + Metal. SwiftUI app shell on both platforms. The canvas is an `MTKView` subclass bridged via `UIViewRepresentable` (iPad) / `NSViewRepresentable` (macOS). Raw input handled inside the hosted view, per platform.
* **No Flutter, no Dart.** No cross-platform fallback renderer — one Metal tiling path.
* **Clean break:** delete `lib/`, `test/`, `android/`, `windows/`, `assets/`, `pubspec.*`, and the Flutter `ios/` / `macos/` scaffolds. Old Flutter docs remain in git history; a brief pointer notes where they went.

### v1 Hard Limits (carried over)

| Limit | Value |
| :--- | :--- |
| Maximum brush size | 200 px |
| Maximum editable tile dimension | 4096 x 4096 |
| Recommended tablet/desktop tile size | 2048 – 4096 |
| Maximum visible layers | 8 |
| Maximum first-party brush presets | 16 |

### v1 Tilings

Grid, half-drop, brick, mirror-x, mirror-xy. (Diamond/hex/rotational and the remaining wallpaper groups are post-v1.)

---

## 2. Module Architecture

Three layers, with platform-specific code quarantined to the thinnest possible host layer.

```text
App Shell (SwiftUI)            — shared, #if os() branches |
  toolbar · layer panel · tiling panel · brush picker ·    |
  color picker · export UI · project browser               |
-----------------------------------------------------------|
Canvas Host                — thin, forks per platform      |
  PatternCanvasView : MTKView                              |
  ├── UIViewRepresentable  (iPad: UITouch/Pencil input)    |
  └── NSViewRepresentable  (macOS: NSEvent/tablet input)   |
  InputAdapter → normalized StrokeSample stream            |
-----------------------------------------------------------|
PatternEngine (pure Swift, no UIKit/AppKit/SwiftUI/Metal)  |
  ├── Brush      (dab gen, Catmull-Rom, pressure curves)   |
  ├── Tiling     (TilingStrategy + 5 strategies, math)     |
  ├── Raster     (RasterSurface abstraction, snapshots)    |
  ├── Layers     (unified pattern+floating stack, compositor)|
  ├── Transient  (confirm/cancel sessions + local undo)    |
  ├── Undo       (single document command stack)           |
  └── File       (.patternproj read/write, export)         |
-----------------------------------------------------------|
MetalRenderer (the CanvasBackend analog, behind Renderer)  |
  instanced dab draw · tiling fragment shaders (MSL) ·     |
  offscreen raster commits (MTLTexture) · compositor pass  |
```

### Dependency Rules

* **SwiftUI shell** → `PatternEngine` (through an observable view-model layer). Never touches Metal directly.
* **Canvas Host** → `PatternEngine` + `MetalRenderer`. Owns the run loop and input.
* **PatternEngine** → pure Swift + `simd` + Foundation only. No platform UI types, no Metal types. Fully unit-testable headless, no GPU required. This is the bulk of the code.
* **MetalRenderer** → Metal + `PatternEngine` data types. It is the swappable backend behind a `Renderer` protocol (the analog of the Flutter `CanvasBackend`). The abstraction is kept because it earns its place even within native: it isolates GPU code and keeps the engine testable without a device.
* Circular dependencies between engine modules are forbidden. Brush knows nothing of tiling or layers; tiling knows nothing of brushes.

### Package Layout (SwiftPM + Xcode)

* `PatternEngine` — platform-agnostic SwiftPM library target (+ test target).
* `MetalRenderer` — Metal-dependent library target; depends on `PatternEngine`.
* App target — SwiftUI + canvas hosts; depends on both. Xcode project with iPad + macOS destinations.

The win: engine and renderer are **shared libraries**; only the canvas host and a few `#if os()` shell branches are platform-specific.

---

## 3. Rendering Pipeline, Input & Concurrency

### Frame Loop

`MTKView` driven by `CADisplayLink` (iPad, up to 120Hz) / `CVDisplayLink` (macOS). Each frame:

1.  **Input** — drain all coalesced/predicted touches (iPad) or `NSEvent`s (macOS) accumulated since the last frame.
2.  **Tool processing** — active tool consumes samples → Catmull-Rom interpolation → dab generation in the active edit space (canonical-tile for pattern, bitmap-local for floating).
3.  **Live overlay** — uncommitted dabs rendered via **instanced Metal draw** (the `drawAtlas` analog: one instance buffer of per-dab transforms + colors, one draw call) into an offscreen overlay texture. Committed pixels untouched.
4.  **Source prep** — reuse committed canonical-tile texture (pattern) / trimmed bitmap texture (floating). No history replay.
5.  **Tiling / direct draw** — pattern layers: full-viewport quad with the active tiling MSL fragment shader sampling the canonical texture. Floating: draw the bitmap once in world space. No fallback path.
6.  **Compositing** — bottom-to-top, opacity + blend mode per layer; the active layer's live overlay composited in place.
7.  **UI overlay** — selection, guides, cursor drawn on top, never through the tiling shader.
8.  **Present** — submit command buffer, present drawable.

### Dirty Tracking

Cache **committed source content**, not whole-viewport composites. A pattern layer reuses its committed canonical-tile texture until its pixels change; a floating layer reuses its trimmed bitmap until pixels/origin change. No `below-active`/`above-active` composite caches in v1. Only the active layer's source raster and overlay normally change during a stroke.

### Input Model

A platform `InputAdapter` normalizes everything into one `StrokeSample` stream: `{ position, pressure, tiltAltitude, tiltAzimuth, timestamp, kind }`.

* **iPad:** `UITouch` with `coalescedTouches` + `predictedTouches`; `force` / `altitudeAngle` / `azimuthAngle`; `UITouch.estimatedProperties` for late pressure updates. Pencil = draw; finger = navigate (pan/zoom); finger ignored mid-stroke. Optional stylus-only mode.
* **macOS:** `NSEvent` mouse/trackpad + `NSEvent` tablet pressure/tilt (Wacom). Wheel/trackpad zoom centered on cursor; space/middle-drag pan; mouse pressure defaults to 0.5.

If pressure is unavailable (mouse, or stylus without pressure), default to 0.5 so the brush still works. Tilt/azimuth are optional in early presets; the architecture supports them but initial presets may be pressure-only.

### Stroke Lifecycle

Draft-only while drawing → exactly one committed command on pointer-up → pointer-cancel discards the draft and leaves committed state unchanged. **One stroke = one undo unit.** Long strokes may internally compact draft data, but compaction must stay fully discardable and never become committed state. Navigation touches are ignored until the active stroke ends.

### Concurrency

* **Hot path is synchronous on the main thread / `@MainActor`** — no actor hops between input and GPU. This is the rule the whole pivot exists to honor.
* **Cold path on background tasks/queues:** `.patternproj` ZIP assembly, PNG/TIFF encoding (ImageIO), metadata transforms, autosave. The UI must stay interactive during save/export.
* **GPU resource writes** (texture uploads for commits) use a managed buffer/texture pool with triple-buffered CPU↔GPU synchronization so a commit never stalls a frame.

### Latency Budget (Apple-native)

| Stage | Budget |
| :--- | :--- |
| Pencil sampling (240Hz) | ~4ms |
| OS → app | ~2ms |
| Interpolation + dab generation | ~2ms |
| Instanced dab draw | ~1ms |
| Tiling shader | ~1ms |
| Compositing | ~2ms |
| Display wait (120Hz) | ~4ms |
| **Total** | **~16ms** |

Target is <20ms input-to-pixel. The +2–4ms Flutter scheduling jitter from the prior design is gone because we own the frame loop.

---

## 4. Engine Domain (carried over, restated in Swift)

These are platform-agnostic and survive the pivot intact. Swift value types + enums fit them better than Dart did.

### Coordinate Systems (5)

screen → viewport → world → canonical-tile (pattern) / floating-bitmap-local (floating). World origin `(0,0)` = top-left of the central tile. **Half-open boundary intervals:** a point on the right/bottom edge belongs to the next cell, not the current one.

### Tiling

`TilingStrategy` protocol:

* `worldToCanonical(_:) -> CanonicalHit`
* `cellTransform(_:) -> simd_float4x4`
* `cellsForWorldRect(_:bleed:) -> [CellIndex]`
* `wrapPlacementsForCanonicalBounds(_:) -> [WrappedPlacement]`

Five v1 strategies: grid, half-drop, brick, mirror-x, mirror-xy.

**Critical invariant:** the Swift mapping math and the MSL shader math must be identical, or the stroke "jumps" relative to the tiled output. Covered by a parity test (Section 6). Changing tiling is **metadata-only** and must never rewrite stored pixels — the resulting repeat may look odd, and that is acceptable. Mirror/rotation is preview/export behavior *outside* the tile boundary; storage writes stay translational. Floating layers bypass tiling entirely. Tiling is document-level in v1 (no per-layer overrides).

### Layers

One unified ordered stack. `LayerKind { pattern, floating }`, modeled as a Swift enum with associated content:

* `PatternContent(raster: RasterSurface)` — raster always equals document tile size.
* `FloatingContent(raster: RasterSurface, origin: SIMD2<Double>)` — trimmed bitmap + world-space top-left of local pixel (0,0).

A `Layer` has: `id` (UUID), `kind`, `name`, `opacity`, `blendMode`, `isVisible`, `isLocked`, `content`. Floating semantics: translation is metadata; scale/rotate bake into pixels on confirm; paint auto-expands bounds (origin shifts so existing pixels stay fixed in world space); erase never expands; transparent margins auto-trim only after a completed edit, never mid-gesture. Max 8 visible layers.

### Seam / Wrap Rules

When a pattern dab crosses a canonical boundary, duplicate it translationally into the canonical raster:

```swift
For a dab at (x, y) radius r in tile (W, H):
always draw (x, y)
if x - r < 0:  also (x + W, y)
if x + r > W:  also (x - W, y)
if y - r < 0:  also (x, y + H)
if y + r > H:  also (x, y - H)
corners: up to 3 extra copies
```

Same rule whether the stroke started in the central tile or any preview cell. Floating layers never wrap. Selection creation is constrained to the central tile (clipped back on release); once a selection exists, transforms may cross edges and preview through the active tiling. Only the central copy is interactive.

### Undo / Redo

Single document-level command stack (matches Procreate/Photoshop — Cmd+Z undoes the last action regardless of active layer; commands reference the layer they affect).

* `PatternRegionCommand` — canonical union-rect before/after snapshot.
* `FloatingBitmapCommand` — full trimmed bitmap + origin before/after (bounds/origin can change via expand/trim, so the full bitmap is snapshotted).
* Layer stack ops (add/delete/reorder/visibility/blend/convert/merge-same-kind) are also commands on the same stack.
* 100-step / 200MB cap, pruned oldest-first. Redo cleared on new action. **Not persisted across launches.**
* Transient sessions keep local history: confirm → exactly one document command; cancel → none; local history discarded either way.

### Raster Storage

`RasterSurface` protocol hides the concrete storage model. v1 implementation is single-bitmap, `MTLTexture`-backed (`Pattern`: full-tile RGBA exactly tile-sized; `Floating`: trimmed RGBA + origin). Commits use whole-image replacement. The abstraction exists so future chunking can drop in without changing tool, layer, undo, or file semantics.

### Cross-Kind Operations

Cross-kind merge is disallowed in v1. `floating -> pattern` conversion is explicit, one-way, and undoable (captures only the central-tile footprint, clipping anything outside). `pattern -> floating` whole-layer conversion is not supported in v1.

---

## 5. File Format, Export & Cold Path

Carried over; platform-agnostic. Swift uses `Codable` for JSON and `ImageIO` /Core Graphics for codecs. For the ZIP archive, default to Apple's built-in `Compression` framework (no third-party dependency); `ZIPFoundation` is the fallback only if assembling the archive container by hand proves more friction than it's worth — a call to make during Phase 2, not now.

### .patternproj (ZIP archive)

```text
project.patternproj (ZIP)
├── manifest.json       # schemaVersion, documentId, title, appVersion,
                        # created/modified, tile {width,height}, viewport {scale,offsetX,offsetY}
├── tiling.json         # { "type": "...", "parameters": {} }
├── rasters/<layer-id>.png
├── layers/<layer-id>.json  # id, kind, name, order, opacity, blendMode,
                            # isVisible, isLocked, rasterFile, (origin {x,y} for floating)
├── palettes/project_palette.json
└── thumbnail.png       # advisory 512x512 gallery preview
```

### Persistence Rules

* `schemaVersion` present from day one; backwards compatibility expected within a major version. `Codable` structs are the schema models; encode/decode on a background task.
* One raster per layer. `manifest.json` is authoritative for identity, timestamps, tile dimensions, and saved viewport.
* Pattern rasters match tile dimensions exactly; floating rasters are trimmed bitmaps positioned by `origin`.
* `layer.kind` explicit and required. `tiling.json.type` authoritative; `parameters` holds mode-specific knobs or `{}`. Offset tilings (halfDrop, brick) derive offset from type + tile dimensions; no second offset field persisted.
* Tile dimensions stored only in `manifest.json` (not duplicated in `tiling.json`). Tiling stored once at document level — no per-layer overrides in v1.
* `viewport` is UI restoration only; never changes document meaning or export math. `thumbnail.png` is advisory and may be regenerated.
* Active transient drafts are never serialized. Undo history is never serialized in v1.

### Export Families

| Mode | Exports | Use case |
| :--- | :--- | :--- |
| Source tile | Exact canonical raster | Re-editing, archival, reapplying a different tiling |
| Baked repeat unit | One image that repeats externally per active tiling (may exceed source size for mirror modes) | Default for sharing/downstream |
| Scene / repeated preview | Flattened swatch or visible scene | Presentation/review |

* Formats: PNG, TIFF, JPEG. sRGB only in v1; CMYK/ICC deferred.
* Only visible layers. Pattern exports include visible pattern layers by default; the UI offers "Include visible floating layers", which clips floating content to export bounds and warns the result may not repeat cleanly. Scene export includes all visible layers.
* Export never mutates document state, layer kinds, or stored rasters.

### Blend Modes → Metal blend state

Normal, Multiply, Screen (P0); Overlay, Soft Light (P1); Color Dodge, Color Burn (P2). Mapped to Metal blend states / compositing passes.

### Autosave

Debounced ~60s on a background task; committed state only (ignores active drafts); crash-recovery offer on next launch; deleted on clean exit after a successful manual save. Never blocks drawing.

### Concurrency Rule (restated)

Everything in this section is cold path — background queues/tasks, never the drawing thread.

---

## 6. Testing, Quality Gates & Phasing

### Testing (XCTest)

* **Unit (no GPU):** tiling `worldToCanonical` round-trips for all 5 modes; pattern boundary-wrap logic; viewport math (screen→world→canonical); raster snapshot/restore; floating auto-expand/trim; brush spacing/interpolation; `Codable` manifest round-trips. The entire `PatternEngine` is testable headless — the payoff of keeping it free of Metal/UI types.
* **Golden / snapshot (GPU):** boundary continuity per tiling mode; repeated-preview correctness; mixed pattern+floating compositing; export consistency (source tile vs baked repeat); floating-inclusion bounds clipping. Render to offscreen `MTLTexture`, compare against reference PNGs. **The Swift↔MSL tiling-math parity test lives here:** render via shader, compare to CPU `worldToCanonical`.
* **Integration:** save/open round-trips; long-stroke draft behavior; pointer-cancel discard; pan/zoom during a transient session; floating→pattern conversion.
* **Manual on-device (required, not automatable):** Pencil latency feel, palm rejection, pressure response, transform UX across boundaries — on iPad Pro + a Mac.

### Quality Gates (architectural pass/fail bar)

* Drawing near every tile edge wraps correctly for the active tiling.
* Drawing in any repeated preview cell edits the same canonical tile as the central tile.
* Floating layers remain untiled and preserve stack order among pattern layers.
* Save/open preserves tiling metadata, layer kind, order, visibility, and floating origin; reopened documents render identically.
* Source-tile export matches canonical data exactly; baked-repeat export matches active tiling.
* Changing tiling preserves stored pixels exactly even when the new repeat looks different.
* No full-history replay on the hot path; no cold-path work leaking into drawing; pan/zoom stays responsive when populated.
* Canceling a transient session leaves the document unchanged; confirming creates exactly one undoable command. Autosave/manual save ignore active drafts.

### Performance Budgets (carried over)

Input-to-pixel <20ms on iPad Pro; ≥60fps sustained drawing (120fps target on ProMotion); ≥60fps pan/zoom with 8 visible layers; dab render <3ms/frame (≤500 dabs); tiling shader <2ms/frame; compositing <2ms/frame for 8 layers; memory <512MB (iPad); save <2s, open <1s for an 8-layer 2048² project; cold start to drawing-ready <2s. Validated under the baseline scenario (2048² tile, 8 visible mixed layers, 200px brush, repeated preview, pressure-varying stylus stroke). Performance claims require real-device measurement.

### Phasing

* **Phase 0 — Metal spike (de-risks the ramp).** One textured dab under the Pencil at 120Hz; instanced draw; grid tiling shader; pan/zoom; boundary write; **measured on-device latency**. No layers/undo/UI/save. *Gate: if the Metal loop comes together here, the rest is conventional Swift.*
* **Phase 1 — Engine core.** `RasterSurface` + single-bitmap impl; unified layer stack; compositor; live overlay + stroke-end commit; undo; transient sessions; 5 tilings; 12–16 brush presets; pressure/tilt dynamics.
* **Phase 2 — Product shell.** SwiftUI panels (brush picker/editor, layers, tiling, color, export); place/paste; selection/transform UI; save/load; export; autosave; macOS keyboard shortcuts + menu bar.
* **Phase 3 — Hardening.** macOS desktop polish (Wacom, window management, high-DPI); performance profiling to budget on real iPad + Mac.

---

## 7. Decisions Carried Over vs. Changed

**Carried over (still valid):** finite canonical tile with full-bitmap raster storage; stamp-based brush via instanced GPU draw; GPU fragment shaders for tiling; single document undo stack; live overlay + stroke-end draft-only commit; raw low-level input (not high-level gestures); centripetal Catmull-Rom smoothing; local-first files on disk; two layer kinds in one unified stack; raster-first floating layers (bitmap + origin); document-level tiling only; transient sessions with confirm/cancel; renderer behind an abstraction; pattern export distinguishes source tile from baked repeat; cross-kind merge disallowed, `floating -> pattern` explicit one-way.

**Changed by the pivot:**

* Flutter/Dart → Swift/Metal. The single biggest change.
* 6 platforms → 2 (iPad + macOS). iPhone parked; Android + Windows dropped, their folders/config deleted.
* Cell-based fallback renderer dropped. It existed for Android Vulkan / Windows OpenGL driver divergence; on Metal-only that risk is gone. One tiling path.
* GLSL → MSL shaders.
* `drawAtlas` → instanced Metal draw; `PictureRecorder`/`ui.Image` commits → offscreen `MTLTexture` commits; `FragmentProgram` → Metal pipeline state.
* Latency budget tightened (~16ms vs ~18ms) — owning the frame loop removes framework scheduling jitter.
* Riverpod → SwiftUI observable view-models; `archive`/`image` packages → `ZIPFoundation`/`ImageIO`.

---

## 8. Out of Scope (v1)

Chunked raster storage; Rust/native-FFI beyond Metal; cloud/accounts/sync; per-layer tiling overrides; adjustment/mask/clipping/group layers; tilings beyond the 5 named; CMYK/ICC export; iPhone/phone layout; Android; Windows; Linux; web.