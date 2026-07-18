# Reference Sheet — exact constants for byte-identical reproduction

The design docs (00-15) carry the why at prose altitude. This sheet pins the load-bearing exact constants they deliberately left out — GPU struct layouts, blend states, preset numbers, the keymap, config ranges, the module graph, and the harness scene catalog. With this sheet plus the design docs, a rebuild reproduces observable behavior, not just an equivalent architecture.

Everything here is transcribed from the current source (2026-07-13). If a design doc and this sheet disagree, this sheet is the as-built truth (the design docs are pre-/around-implementation intent). Source of record is always the code itself: `Sources/CShaderTypes/include/ShaderTypes.h`, `Sources/EditorCore/`, `Sources/MetalRenderer/SpikeRenderer.swift`, `App/PatternSpike/RenderHarness.swift`, `Package.swift`.

## Module graph (Package.swift, swift-tools 6.0, iOS 17 / macOS 14)

SPM libraries (pure, swift test-able):
* **PatternEngine** — no deps. Tiling folds, strokes, geometry, dab specs, affine. No GPU.
* **CShaderTypes** — C target holding `ShaderTypes.h` (shared Swift↔MSL struct layouts).
* **MetalRenderer** — deps `PatternEngine`, `CShaderTypes`; resources: `[.process("Shaders.metal")]`. GPU renderer.
* **EditorCore** — no deps. Headless config/input/intent layer: `EditorModel`, `EditorConfig`, `SteppedRange`, `TilingChoice`, `EditorKeymap`, `BrushPreset`, `EditorTransaction`, `SelectionRect`, `Stabilizer`, `Comparable+Clamped`. Imports only `Observation`/`simd`/`SwiftUI`.

Test targets: `PatternEngineTests`, `EditorCoreTests`, `MetalRendererTests` (CPU-only MemoryLayout guard — must NOT instantiate `SpikeRenderer`, which would trap at `makeDefaultLibrary` since SwiftPM does not compile `Shaders.metal`).

The Xcode app target `App/PatternSpike.xcodeproj` (scheme `PatternSpike`, targets macOS + iOS) depends on all three libraries AND compiles `Shaders.metal` into the app's metallib — the renderer + harness only run through this project, never through `swift test`. (Design doc 05 calls this SPM module `PatternApp`; it shipped as `EditorCore`.)

## GPU struct layouts (ShaderTypes.h — MUST match Swift byte-for-byte)

Pixel format everywhere: `.bgra8Unorm` (tiles, canonical, live, selection, drawable). Brush shape/grain textures: `.r8Unorm`. All canonical/live/selection textures clear to `MTLClearColor(0,0,0,0)` (transparent premultiplied); the drawable clears to white paper.

### SpikeUniforms (both passes)

| field | type | note |
| :--- | :--- | :--- |
| `viewportOffset` | `simd_float2` | pan offset, world coords |
| `zoom` | `float` | 1.0 == 100% |
| `tilingKind` | `uint32_t` | packed selector (see wire contract below); occupies the former `_pad0` |
| `tileSize` | `simd_float2` | canonical tile size, world px |
| `resolution` | `simd_float2` | drawable size, px |
| `dabFlags` | `uint32_t` | dab-pass grain flags: bit0 = grain enabled, bit1 = moving (stroke-local) grain |
| `strokeOpacity` | `float` | per-stroke ceiling applied ONCE to the live layer (tiling preview + compositeLive commit); 1 = full |
| `grainScale` | `float` | canvas-px per grain tile (Procreate "Scale"); texturized grain repeats every `grainScale` px. Default 256 |

### DabInstance (overlay pass) — 64-byte stride

| field | type | offset | note |
| :--- | :--- | :--- | :--- |
| `center` | `simd_float2` | @0 | canonical-space center |
| `radius` | `float` | @8 | canonical-space radius |
| `alpha` | `float` | @12 | per-dab coverage = flow x pressure |
| `clipThreshold` | `float` | @16 | unit-quad clip threshold |
| `clipMode` | `float` | @20 | 0=none, 1=keep local.x ≥ thr, 2=x ≤, 3=y ≥, 4=y ≤ |
| `blendMode` | `float` | @24 | 0=normal, 1=erase (former `_pad0`; consumed at COMMIT by destination-out batching, shader ignores it) |
| `rotation` | `float` | @28 | stamp angle, radians (former `_pad1`) |
| `color` | `simd_float4` | @32 | straight RGBA ink (forces 16-byte alignment → sits at @32) |
| `hardness` | `float` | @48 | falloff sharpness 0..1 |
| `_pad2` | `float` | @52 | 56..63 tail padding to stride 64 |

`clipMode`/`clipThreshold` gate which fragments survive (half-drop/brick parity slivers); the round falloff over local ∈ [-1,1]² is unchanged. Swift mirror: `MetalRenderer/DabInstance.swift`; `SpikeRenderer.init` asserts strides match.

### SelectionUniforms (selection/transform textured-quad pass)

| field | type | note |
| :--- | :--- | :--- |
| `affineCol0` | `simd_float3` | affine column 0 (column-major, matches Swift `Affine.matrix`) |
| `affineCol1` | `simd_float3` | affine column 1 |
| `affineCol2` | `simd_float3` | affine column 2 (translation x/y) |
| `rectOrigin` | `simd_float2` | selection rect origin, FOLDED tile-space px [0,tileSize] (NOT raw canonical) |
| `rectSize` | `simd_float2` | selection rect size, tile-space px |
| `tileResolution` | `simd_float2` | provisional/canonical texture size, px |

## tilingKind wire contract + shader flag bits

Low byte of `tilingKind` = the strategy kind: grid 0, halfDrop 1, brick 2, mirror 3, rotational 4 (append-only, never renumber). Mirror axis flags in bits 8-9: x = 0x100, y = 0x200. Additional `tiling_fragment` selector bits: grid-lines 0x10000, erase (live-stroke-erases) 0x20000, provisional-channel 0x40000.

Note the two-enum split: the app-level `EditorCore.TilingChoice` has 7 cases (grid, halfDrop, brick, mirrorX, mirrorY, mirrorBoth, rotational) — that's what the 1-7 keys and the toolbar pick — and it maps down to the 5-strategy `tilingKind` + the mirror axis bits (mirrorX/Y both collapse onto strategy 3 with the axis flags). `EditorModel.Tool` = (draw, erase, select, transform).

## Blend states (7 pipelines, SpikeRenderer.swift ~L182-284)

All enabled pipelines use `rgbBlendOperation = .add`, `alphaBlendOperation = .add`. Factors as (srcRGB, dstRGB, srcA, dstA):

| pipeline | srcRGB | dstRGB | srcA | dstA | purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `tilingPipeline` | .one | .oneMinusSourceAlpha | .one | .oneMinusSourceAlpha | composite premultiplied tile over white paper (.one not .sourceAlpha - else colored-edge grey fringe) |
| `commitDabPipeline` | .sourceAlpha | .oneMinusSourceAlpha | .one | .oneMinusSourceAlpha | stamp straight-alpha dabs into a texture; srcA=.one builds alpha correctly |
| `eraseDabPipeline` | .zero | .oneMinusSourceAlpha | .zero | .oneMinusSourceAlpha | destination-out (dst *= 1-src.a) |
| `copyPipeline` | — | — | — | — | blending disabled; .bgra8Unorm straight copy |
| `compositeLiveNormalPipeline` | .one | .oneMinusSourceAlpha | .one | .oneMinusSourceAlpha | bake the live tile into canonical at commit (premultiplied over) |
| `compositeLiveErasePipeline` | .zero | .oneMinusSourceAlpha | .zero | .oneMinusSourceAlpha | destination-out variant for an erasing live stroke |
| `selectionPipeline` | .one | .oneMinusSourceAlpha | .one | .oneMinusSourceAlpha | textured affine quad into provisional / canonical |

## Built-in BrushPresets (exact — EditorCore/BrushPreset.swift)

`BrushPreset.builtins = [softAirbrush, hardInk, chalk, pencil]`. Enums: Shape{softRound, hardRound, tapered, chisel}, Grain{paper, canvas,noise}, GrainMode{texturized,moving}, RotationMode{fixed,followDirection,random}. Defaults on init: `grainMode=.texturized`, `grainScale=256`, `shapeAsset=nil`, `grainAsset=nil`. `Streamline` = stabilizer strength 0..<1 (Stabilizer clamps to 0.99; 1.0 would freeze).

| field | Soft Airbrush | Hard Ink | Chalk | Pencil |
| :--- | :--- | :--- | :--- | :--- |
| `shape` | softRound | tapered | softRound | hardRound |
| `grain` | nil | nil | .paper | .noise |
| `grainMode` | texturized | texturized | texturized | texturized |
| `size` | 20 | 12 | 24 | 6 |
| `spacing` | 0.15 | 0.08 | 0.2 | 0.1 |
| `hardness` | 0.0 | 0.9 | 0.5 | 0.7 |
| `flow` | 0.4 | 1.0 | 0.8 | 0.7 |
| `opacity` | 1.0 | 1.0 | 0.9 | 0.85 |
| `pressureSize` | true | true | true | true |
| `pressureFlow` | true | false | true | true |
| `pressureCurve` | 1.0 | 1.0 | 1.5 | 2.0 |
| `scatter` | 0 | 0 | 0.1 | 0.05 |
| `rotationMode` | fixed | fixed | random | followDirection |
| `streamline` | 0.3 | 0.3 | 0.2 | 0.15 |
| `grainScale` | 256 (default) | 256 (default) | 256 | 128 |
| `grainAsset` | nil | nil | "grain-paper" | nil |
| `shapeAsset` | nil | nil | nil | nil |

Seed PNGs in `App/PatternSpike/Assets.xcassets`: `grain-paper` (1024², used by Chalk) and `tip` (512², committed but unreferenced — no preset sets `shapeAsset`; see `BACKLOG.md`).

## Keymap (EditorCore/EditorKeymap.swift)

Plain `handle(characters, model)` — routes on the typed character string, returns consumed?:

| key(s) | action |
| :--- | :--- |
| `0` | `clear()` |
| `+/=` | `brushLarger()` |
| `-` | `brushSmaller()` |
| `>` | `tileLarger()` |
| `<` | `tileSmaller()` |
| `g` | `toggleGrid()` |
| `b` | `setTool(.draw)` |
| `e` | `setTool(.erase)` |
| `s` | `setTool(.select)` |
| `t` | `setTool(.transform)` |
| `\r` (Return) | `confirmTransform()` |
| `\u{1B}` (Escape) | `cancelTransform()` |
| `1-7` | `selectTiling(index1:)` |
| `any other` | `not consumed (falls through)` |

Modifier-aware `handle(key:command:shift:model)`: `⌘Z` = `undo()`, `⌘⇧Z` = `redo()`; returns false for anything else (incl. plain `⌘`). The `.onKeyPress` glue lives in the view; a future `.commands` menu calls the same `EditorModel` methods.

## Config ranges (EditorCore/EditorConfig.swift)

`SteppedRange(initial, range, nudge); stepped(v,up) = nudge(v,up).clamped(to: range)`. The ±32, x÷1.25, and both ranges appear nowhere else.

| field | initial | range | nudge (pre-clamp) |
| :--- | :--- | :--- | :--- |
| `tile` | 256 | 64...1024 | additive (v ± 32).rounded() |
| `brush` | 20 | 2...2000 | geometric (v x 1.25 or v ÷ 1.25).rounded() |

## Render-harness scene catalog (22 scenes — App/PatternSpike/RenderHarness.swift)

Launch: `PatternSpike --render-harness <dir> [--scene X | --all]`; replays a scripted stroke through the real Metal pipeline offscreen, writes `<scene>-canonical.png` + `<scene>-screen.png`, runs pixel asserts, prints `HARNESS OK|FAIL`, exits 0/1. No display/permission needed. Exact probe coordinates + tolerances live in the scene bodies (that is the right altitude for them — they encode empirical pixel measurements); this catalog enumerates the coverage surface so a rebuild knows what must exist.

Tiling/edge-dab: `interior-control`, `halfdrop-phantom`, `brick-phantom`.
Tools: `colored-brush`, `eraser`, `eraser-live`, `undo-redo`.
Selection/transform: `select-transform`, `select-transform-rotate`, `select-transform-rotate-folded`.
Raster brush: `brush-textured-stamp`, `brush-grain-texturized`, `brush-pressure-taper`, `brush-flow-opacity`, `brush-wysiwyg-commit`.
PNG-brush quality: `brush-grain-scale`, `brush-tapered-tip`, `brush-png-asset`, `brush-grain-seam-safe`, `brush-grain-copy-consistency`, `brush-grain-chalk-preset-seam`, `brush-grain-nondividing-imperceptible`.

## Known doc↔code discrepancies fixed in this pass

* 05: proposed module `PatternApp` → shipped as `EditorCore` (annotated in 05).
* 13: Chalk/Pencil `grainScale` ~200 / ~120 → 256/128; Pencil grain is procedural `.noise`, not a PNG (annotated in 13).