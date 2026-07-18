# Pattern Product Rebuild Design

**Date:** 2026-07-18
**Status:** Approved
**Targets:** macOS first, iPadOS continuously buildable

## 1. Purpose

Rebuild the intended seamless-pattern editor from documentation after loss of
the source code. This is not a byte-for-byte restoration of the last spike.
Recovered behavior and constants are evidence, but known defects, temporary
limits, and superseded architecture do not become requirements.

The product is a native Apple drawing application for illustrators. Users draw
into a canonical raster tile while seeing the selected repeat update live
across the canvas. Drawing feel and seam correctness are the first release
gates. Layers, editing, persistence, and export build on that verified core.

The primary product promise is:

> A stroke feels immediate, previews truthfully, commits without a visual
> change, and repeats correctly for the tiling active while it is drawn.

## 2. Decision Precedence

When recovered documents conflict, use this order:

1. Explicit user decisions made during this rebuild.
2. This approved design.
3. `16-reference-sheet.md` for exact as-built constants that this design does
   not intentionally replace.
4. Later correction notes, especially eraser compositing, half-drop clipping,
   persistent live-tile performance, and edit-transaction lifecycle.
5. Earlier feature designs as historical reasoning.

Intentional improvements over the lost implementation:

- General cell-fragment projection replaces round-dab and immediate-neighbor
  tiling shortcuts.
- Raster undo stores changed regions instead of fixed-depth full-tile copies.
- The edit transaction reducer arrives before complex tools and layers.
- Selection/transform is built against real layer ownership, not a temporary
  flat canvas.
- `EditorCore` has no SwiftUI, AppKit, or UIKit types.
- Cold-path persistence lives in a separate `PatternFile` module.
- Frame scheduling is selected through measurement instead of preserving a
  historical display-link choice.

## 3. V1 Scope

### 3.1 Included

- Native Swift 6, Metal, and SwiftUI.
- Minimum macOS 14 and iPadOS 17.
- macOS production target.
- iPadOS target compiled throughout development.
- Rectangular canonical tiles from 64 x 64 through 4096 x 4096.
- Grid, half-drop, brick, mirror-x, mirror-y, mirror-xy, and rotational
  tiling choices.
- Reversible, pixel-preserving tiling changes.
- Pattern and floating layers in one ordered stack.
- Maximum eight visible/resident layers; additional hidden layers require the
  later lazy-raster residency path and are not part of initial V1 storage.
- Draw, erase, rectangular selection, move, scale, and rotate tools.
- Brush diameter from 2 px through
  `min(2000 px, 8 x min(tileWidth, tileHeight))`; engine radius is half the
  user-facing diameter.
- 12-16 calibrated built-in brushes.
- Brush Library, Brush Studio, and engine-rendered brush previews.
- Pressure, tilt-ready input, speed/direction dynamics, response curves,
  stabilization, taper, and deterministic randomness.
- Region-based undo/redo under a combined 100-step and 200 MB resident cap.
- Versioned `.patternproj` files.
- Autosave recovery.
- Source tile, baked repeat, and scene/preview exports.
- PNG, TIFF, and JPEG export in sRGB.
- Mac keyboard shortcuts and menu commands.
- Adaptive iPad controls with touch-sized targets.

### 3.2 Deferred

- Retained or vector stroke storage.
- Cloud accounts, sync, collaboration, or a brush marketplace.
- iPhone, Android, Windows, Linux, and web targets.
- Per-layer tiling.
- Wallpaper groups beyond the listed choices.
- Lasso, feather, warp, perspective, and cross-fold selection.
- Masks, adjustment layers, clipping layers, and groups.
- Full fluid simulation.
- CMYK and general ICC workflows.
- User brush-package import/export.

### 3.3 Conditional

V1 starts with a single-texture `RasterSurface` implementation. The protocol
must permit chunked storage without changing tools, layers, history, or file
semantics. Chunking moves into V1 only if the eight-layer 2048 baseline or
4096 stress tests fail memory or frame-time gates.

## 4. Product Invariants

These requirements are load-bearing:

1. Canonical pixels are the retained document source of truth.
2. Tiling is document metadata controlling fold and sampling.
3. Changing tiling never rewrites canonical pixels.
4. Changing back to a previous tiling restores the exact previous rendering.
5. World-space interpolation occurs before canonical projection.
6. CPU and GPU tiling maps agree for points, transforms, and boundaries.
7. Right and bottom coordinate boundaries are half-open.
8. Drawing in any visible repeated cell edits the same canonical content as
   drawing in the central cell.
9. Active strokes remain discardable until pointer-up.
10. Pointer-up creates one document command; pointer-cancel creates none.
11. Live preview and commit use identical compositing math.
12. Stroke length does not increase per-frame live-stroke cost.
13. Cold-path work never runs in the input-to-pixel path.
14. Random brush output is reproducible from a stored transient stroke seed.
15. Failed operations leave the last committed document unchanged.

### 4.1 Seam Guarantee

Artwork drawn while tiling `T` is active must be correct for `T` across all
supported brush sizes, rotations, shapes, grains, materials, and editable
preview cells.

Reinterpreting existing canonical pixels under another tiling is allowed and
reversible, but no seam repair or seamlessness promise applies to the new
tiling. This is expected canonical-tile behavior, not an error.

Rotational tiling is tested for its rotational centers and fold consistency.
It is not incorrectly tested as edge-continuous where the mathematical group
does not require edge continuity.

## 5. Module Architecture

```text
PatternApp (SwiftUI + platform hosts)
  |-- EditorCore
  |-- PatternEngine
  |-- MetalRenderer
  `-- PatternFile

EditorCore ------> PatternEngine
MetalRenderer ---> PatternEngine + CShaderTypes
PatternFile -----> PatternEngine
CShaderTypes ----> no target dependencies
PatternEngine ---> Foundation + simd only
```

Circular dependencies are forbidden.

### 5.1 PatternEngine

Pure Swift domain library. No Metal, SwiftUI, UIKit, or AppKit.

Responsibilities:

- Typed coordinate systems and viewport-independent geometry.
- Tiling strategies and full cell transforms.
- Cell-fragment projection.
- Stroke samples, interpolation, stabilization inputs, and spacing.
- Brush recipes, dynamics evaluation, and generated dab attributes.
- Transient stroke generation and deterministic seeds.
- Document metadata and layer value types.
- `RasterSurface` and raster revision interfaces without Metal types.
- Pure affine math and selection geometry.

Brush generation knows no layer or GPU implementation. Tiling knows no brush
preset or editor UI. Projection combines a geometric footprint with a tiling
strategy through explicit interfaces.

### 5.2 EditorCore

Platform-free editor intent and lifecycle library. It may use `Observation`,
but exposes no SwiftUI `KeyPress`, AppKit `NSEvent`, or UIKit `UITouch`.

Responsibilities:

- Observable editor configuration.
- Semantic commands and platform-independent key mapping.
- Tool intent.
- Brush library metadata and custom in-session recipe edits.
- Total edit-transaction reducer.
- Linear document command history.
- History byte/step pruning policy.
- UI enable-state derived from editor/document state.

Platform code translates native events into `EditorCommand` values.

### 5.3 CShaderTypes

C target containing shared CPU/MSL layouts and append-only wire constants.

Requirements:

- Swift and MSL structs match byte-for-byte.
- Runtime preconditions guard critical layout equality.
- CPU-only tests guard stride, alignment, and field offsets.
- Tiling selector raw values are append-only and never renumbered.
- Canonical, live, selection, and drawable color textures use
  `.bgra8Unorm` premultiplied storage.
- Shape and grain coverage textures use `.r8Unorm`.

The lost 64-byte dab layout is a reference, not a frozen requirement. The new
placement representation may grow to carry full isometry and clipping. Correct
pixels take priority; measured instance bandwidth decides final packing.

### 5.4 MetalRenderer

Metal implementation of raster and display behavior.

Responsibilities:

- Pipeline and sampler creation.
- Canonical and floating raster textures.
- Persistent live-stroke and provisional textures.
- Instanced brush stamping.
- Tiling sampling.
- Layer compositing.
- Region capture/restore for history.
- Selection lift, provisional affine rendering, and confirm.
- Texture/buffer pools and in-flight synchronization.
- Offscreen rendering and PNG capture for the harness.
- GPU timing instrumentation.

MetalRenderer does not own editor intent or file policy.

### 5.5 PatternFile

Cold-path persistence and export module.

Responsibilities:

- Versioned Codable schema.
- Atomic archive save/open.
- Raster encoding/decoding through Apple image frameworks.
- Thumbnail generation.
- PNG, TIFF, and JPEG export.
- Autosave and recovery package assembly.

It returns immutable decoded results. PatternApp performs the final document
swap on the main actor.

### 5.6 PatternApp

Thin SwiftUI and platform-host layer.

Responsibilities:

- App lifecycle, windows, commands, panels, and project browser.
- `MTKView` integration.
- macOS and iPad input adapters.
- Viewport gestures.
- Translation between platform events and engine/editor values.
- Dispatch of reducer effects to renderer/document operations.
- Presentation of typed errors.

No drawing math or shader policy belongs here.

## 6. Target Directory Structure

```text
Package.swift
App/
  PatternSpike/
    PatternSpikeApp.swift
    ContentView.swift
    Canvas/
    Input/
    Panels/
    Commands/
    Assets.xcassets/
  PatternSpike.xcodeproj/
Sources/
  PatternEngine/
    Geometry/
    Tiling/
    Brush/
    Document/
    Selection/
  EditorCore/
    Model/
    Commands/
    Transactions/
    History/
    Brushes/
  CShaderTypes/
    include/ShaderTypes.h
    CShaderTypes.c
  MetalRenderer/
    Raster/
    Brush/
    Tiling/
    Compositor/
    Selection/
    Capture/
    Shaders.metal
  PatternFile/
    Schema/
    Archive/
    Export/
    Autosave/
Tests/
  PatternEngineTests/
  EditorCoreTests/
  MetalRendererTests/
  PatternFileTests/
docs/
  superpowers/
scripts/
```

Files remain focused by responsibility. A folder does not justify a large
manager type; public interfaces must explain what each unit consumes, produces,
and depends on.

## 7. Rendering And Input Pipeline

### 7.1 Hot Path

```text
platform event
  -> InputAdapter normalizes StrokeSample
  -> BrushInput derives velocity and validates fields
  -> Stabilizer updates filtered sample
  -> StrokeInterpolator walks continuous world space
  -> BrushDynamicsEngine evaluates each emitted point
  -> TilingStrategy enumerates intersected cell fragments
  -> CellFragment maps and clips the stamp into canonical space
  -> GPU instances append to active LiveStroke
  -> LiveTile stamps only new or replay-tail instances
  -> compositor samples canonical + live + provisional layers
  -> drawable is acquired late
  -> command buffer presents
```

The main actor owns event ordering and command encoding. No `await`, file I/O,
image codec, archive operation, shader compilation, or unbounded allocation is
allowed after input enters this path.

### 7.2 Frame Scheduling

Start with MetalKit's timed redraw and device-appropriate preferred frame rate.
Record frame timing from the first visible slice. Adopt `CAMetalDisplayLink` or
another custom schedule only if profiling proves MetalKit timing is the
bottleneck or variable-refresh control materially improves latency.

The implementation follows Apple's rule to acquire the drawable as late as
possible, immediately before the onscreen pass.

References:

- <https://developer.apple.com/documentation/metalkit/mtkview/>
- <https://developer.apple.com/documentation/quartzcore/cametaldisplaylink>

### 7.3 Input

Normalized samples contain:

```swift
struct StrokeSample {
    var position: Point
    var pressure: Double
    var timestamp: Double
    var altitude: Double?
    var azimuth: Double?
    var roll: Double?
    var velocity: Double
    var phase: SamplePhase
    var source: InputSource
}
```

Mouse pressure defaults to a configurable neutral value for brush drawing.
Eraser strength is a tool setting and never accidentally inherits the mouse
pressure default.

iPad later consumes precise, coalesced, predicted, and late-estimated Pencil
properties. Predicted samples use copied transient state and never poison the
real interpolator's carry or spacing.

References:

- <https://developer.apple.com/documentation/uikit/getting-high-fidelity-input-with-coalesced-touches>
- <https://developer.apple.com/documentation/uikit/uievent/predictedtouches%28for%3A%29>

## 8. Generalized Tiling Projection

The lost renderer folded dab centers and added special-case wrap copies. That
was exact only for round stamps and bounded neighbor cases. Textured,
directional, reflected, rotated, and large stamps require the full mapping.

### 8.1 Cell Fragment

For each emitted world-space stamp:

1. Compute conservative world bounds for the fully transformed stamp.
2. Enumerate every tiling cell intersecting those bounds.
3. Intersect the stamp bounds with each cell.
4. Obtain the cell's complete world-to-canonical isometry.
5. Map that clipped fragment into canonical space.
6. Preserve brush-local coordinates so shape and grain remain continuous
   across fragments.
7. Emit a canonical placement with transform and clip data.

Conceptual value:

```swift
struct CellFragment {
    var canonicalTransform: Affine2D
    var canonicalClip: ConvexClip
    var brushLocalTransform: Affine2D
    var cell: CellIndex
}
```

Exact GPU packing is an implementation-plan decision tested against bandwidth
and alignment. It must represent reflection, mixed-axis signs, rotation, and
translation without lossy flags.

### 8.2 Correctness Oracle

A slow CPU reference rasterizer is the source of truth for tests:

- Rasterize a world-space brush footprint.
- Fold every covered sample through the selected tiling.
- Compare expected canonical coverage with projected placements.
- Assert both zero holes and zero phantom pixels.

Property tests cover:

- Negative and large coordinates.
- Exact right/bottom boundaries.
- Every cell parity.
- Corners and multiple crossed cells.
- Rectangular tile sizes.
- Minimum and maximum supported brush sizes.
- Rotated and reflected non-round shapes.
- Texturized and moving grain coordinates.
- All visible-cell editing paths.

GPU scenes compare real Metal output with the same oracle.

### 8.3 Tiling Switch

Tiling is an undoable metadata command. It changes only sampling and editor
metadata. Canonical raster bytes and raster history remain valid and unchanged.
No repair runs and no warning blocks the switch.

## 9. Brush Architecture

### 9.1 Brush Dynamics

`BrushDynamicsEngine` is the only pure evaluator from sample/context/recipe to
stamp attributes:

```swift
evaluate(
    sample: StrokeSample,
    context: BrushStrokeContext,
    recipe: BrushRecipe
) -> DabAttributes
```

Supported mapping sources:

- Pressure.
- Speed.
- Tilt and direction.
- Roll where available.
- Stroke age and distance.
- Deterministic random value.

Supported outputs:

- Radius and spacing.
- Flow and stroke opacity contribution.
- Rotation and scatter.
- Hardness.
- Grain offset and scale.
- Color adjustment.
- Material parameters.

Existing simple brush behavior is represented through recipes, not a parallel
legacy evaluator.

### 9.2 LiveStroke

Committed documents remain emit-and-forget. `LiveStroke` retains data only for
the active stroke.

Modes:

- Append-only for simple brushes.
- Replay bounded tail for prediction correction and taper.
- Replay whole stroke only for explicitly bounded wet materials.

Every mode has sample/dab caps. Cancel clears all transient surfaces. Commit
produces pixels and releases transient history.

### 9.3 Brush Rendering

Brush rendering uses one shape and one grain binding per stroke plus
per-stroke material uniforms.

Material families:

- Dry.
- Ink.
- Glaze.
- Bounded wash.

Full fluid simulation and smudge/pickup remain deferred.

Shape and grain assets use mipmaps. Texturized grain uses canvas/canonical
coordinates. Moving grain preserves brush-local coordinates across projected
cell fragments. A mode does not ship in a preset until seam tests pass.

### 9.4 Preview/Commit Parity

Dabs accumulate into a live texture at flow. Stroke opacity scales the
premultiplied live layer once during preview and once through the identical
commit composite. Eraser preview and commit use the same destination-out
equation.

Pointer-up must not change visible opacity, color, edge coverage, or grain.

## 10. Document And Layers

```text
PatternDocument
  identity
  title
  timestamps
  tileSize
  tiling
  ordered layers
  activeLayerID
  project palette
  saved viewport
```

Layer kinds:

- `pattern`: canonical raster exactly matching document tile size.
- `floating`: trimmed raster plus world-space origin, bypassing tiling.

Common layer fields:

- Stable UUID.
- Name.
- Opacity.
- Blend mode.
- Visibility.
- Lock state.

Translation of floating content changes metadata. Scale and rotation bake on
confirm. Painting expands floating bounds while preserving existing world
positions. Erasing never expands. Transparent margins trim only after a
completed edit.

V1 blend modes begin with normal, multiply, and screen. Additional documented
blend modes are added only after compositor tests and budgets pass.

Only committed source textures are cached. Whole-viewport composites are not
cached in V1. During a stroke, normally only the active layer's live source and
final compositor pass change.

## 11. Edit Transactions And Undo

### 11.1 Transaction Reducer

One total reducer owns edit lifecycle:

```text
idle
drawing(tool)
selectingDraft
selectionReady
transforming
```

Events include pointer lifecycle, tool intent, selection changes, commands, and
canvas configuration changes. Effects are ordered values. Every state/event
pair has defined behavior and pure tests.

Renderer transform flags mirror reducer state; they do not create a second
lifecycle owner.

### 11.2 History

EditorCore owns command order and pruning. MetalRenderer owns raster revision
storage.

Raster commands reference opaque before/after revision IDs:

- Pattern edits capture changed canonical union regions.
- Floating edits capture changed bitmap/origin state.
- Layer and tiling commands store metadata.
- Tile-size changes capture all affected raster revisions.

History limits:

- Maximum 100 commands.
- Maximum 200 MB resident combined before/after raster payload.
- Oldest commands prune first.
- New mutation clears redo.
- History is not persisted.

Tiling commands do not flush raster history because canonical pixels do not
change. Tile-size resize is undoable and commits only after every replacement
texture and history payload allocates successfully. Whole-document operations
that exceed the resident cap may use compressed disk-backed revisions in the
app's temporary recovery area. These revisions count toward the 100-command
limit, prune with their command, and are deleted when history or the document
closes. If the temporary revision cannot be secured, resize fails before
mutation.

## 12. Selection And Transform

Selection is implemented after layers and always targets the active unlocked
layer.

V1 behavior:

- Rectangular selection.
- Central canonical tile creation for pattern content.
- Move, scale, and rotate.
- Cut on transform entry.
- Provisional transformed preview.
- Composite on confirm.
- Exact restoration on cancel.
- One confirmed transform equals one undo command.

Selection geometry stores both raw and folded origins. This structurally
preserves the fold delta needed for correct affine pivots.

The live UI path is an integration gate. Renderer-only scripted success is not
accepted as feature completion.

## 13. Persistence And Export

`.patternproj` remains a versioned archive:

```text
project.patternproj
  manifest.json
  tiling.json
  layers/<layer-id>.json
  rasters/<layer-id>.png
  palettes/project_palette.json
  thumbnail.png
```

Rules:

- `manifest.json` is authoritative for identity, timestamps, tile size, and
  saved viewport.
- Layer kind is explicit.
- Tiling is stored once at document level.
- Pattern rasters match tile dimensions.
- Floating rasters store origin.
- Thumbnail is advisory.
- Active drafts and undo history are not serialized.
- Save writes a temporary archive and atomically replaces the destination.
- Autosave serializes committed state only.

Export families:

- Source canonical tile.
- Baked repeat unit for active tiling.
- Flattened repeated scene/preview.

Export never mutates document state.

## 14. UI And Interaction Design

Selected visual direction: **Precision Light**.

### 14.1 Shell

- Canvas-first workspace.
- Stable Photoshop-like tool rail on the left.
- Layers and tiling inspector on the right.
- Compact top bar for document identity, brush selection, color, undo/redo,
  and inspector visibility.
- Tile size, brush internals, and secondary commands stay out of the top bar.
- Status bar presents zoom, brush size, color space, and optional development
  performance metrics.

### 14.2 Responsive Behavior

Mac:

- Compact 30-32 point icon controls.
- Right inspector docked at wide window sizes.
- Keyboard and menu commands mirror visible actions.

iPad:

- Minimum 44 point touch targets.
- Left tool positions remain stable.
- Right inspector docks on wide layouts and becomes a slide-over panel in
  compact width or Split View.
- Starting a stroke dismisses temporary panels without changing active tool.

### 14.3 Visual System

- Light neutral chrome.
- Near-white content panels.
- Fine neutral borders.
- Restrained green active/selection state.
- Coral reserved for current color/artwork examples, not general chrome.
- System typography with clear compact hierarchy.
- SF Symbols for product controls.
- No text-wrapped tool labels.
- No floating decorative cards or nested-card page sections.
- Brush previews show actual engine output.
- Tooltips label unfamiliar Mac icons.

Mockup session:

`.superpowers/brainstorm/2130447-1784370236/content/visual-style.html`

## 15. Error Handling

Programmer invariants use assertions or preconditions:

- CPU/GPU struct mismatch.
- Invalid shader wire selector.
- Impossible dimensions.
- Illegal reducer effects.

User/data failures use typed errors:

- Corrupt or unsupported archive.
- Raster decode failure.
- Insufficient memory.
- Texture or pipeline allocation failure.
- Save or export failure.

Policies:

- Failed mutation preserves last committed state.
- Failed save preserves prior file.
- Missing optional brush asset uses deterministic fallback and records one
  diagnostic.
- Metal unavailable presents an explicit unsupported-device state.
- No alternate rendering backend silently changes output.
- Background work returns immutable results for main-actor adoption.
- Corrupt canonical pixels are not guessed or repaired silently.

## 16. Verification

Every milestone passes five gates.

### 16.1 Pure Tests

- Geometry and coordinate conversions.
- Tiling transforms and projection oracle.
- Interpolation and brush dynamics.
- Deterministic random output.
- Transaction state/effect matrix.
- History pruning.
- File schema round trips.

### 16.2 GPU Harness

The real app metallib renders offscreen canonical and screen PNGs. Scenes assert
pixels and exit nonzero on failure. `swift test` does not claim to validate
Metal shaders.

Scene families:

- Interior and boundary controls.
- Every tiling and editable preview cell.
- Large, rotated, reflected, textured stamps.
- Live/commit equality.
- Color and eraser.
- Undo/redo.
- Layer compositing.
- Selection/transform.
- Brush materials and preview parity.
- Export parity.

Each new harness family receives one temporary negative-control run proving its
assertions fail when target behavior is broken. The broken code is reverted;
the result is recorded in milestone notes.

### 16.3 Integration

- Pointer cancel.
- Tool/config interruption.
- Metadata-only tiling switches.
- Layer routing.
- Save/open.
- Autosave recovery.
- Background export while drawing.

### 16.4 Manual Mac Gate

- Drawing feel.
- Cursor alignment.
- Pan/zoom.
- Keyboard focus.
- Transform gestures.
- Inspector ergonomics.
- Visual seam scan.

### 16.5 Performance

Fixed scenes record hardware, OS, build, CPU spans, GPU spans, frames, and
memory in JSON.

Budgets:

- Brush processing p95 under 2 ms/frame.
- Dab rendering under 3 ms for 500 new dabs.
- Tiling pass under 2 ms.
- Eight-layer composite under 2 ms at 2048 baseline.
- Sustained drawing and pan/zoom at 60 fps minimum.
- Missed frames below 1 percent in fixed stress trace.
- Baseline memory under 512 MB for eight visible 2048 layers.
- No frame-time growth with stroke length.
- Preview/commit channels equal within one 8-bit value.
- Milestone fails on unexplained p95 regression above 15 percent.

Mac records event-to-submit and GPU-completion latency as a proxy. It does not
claim Pencil input-to-pixel compliance.

When iPad hardware arrives, add:

- High-speed-camera input-to-pixel measurement below 20 ms target.
- 120 Hz sustained drawing on ProMotion hardware.
- Coalesced and predicted sample correction.
- Palm rejection.
- Pressure and tilt calibration.
- iPad memory gate.

## 17. Delivery Sequence

Each slice ends in working software plus tests, harness images, benchmark JSON,
and a short decision/retrospective note. No slice starts until the prior gate is
accepted.

### Slice 0: Foundation And Harness

Restore packages, Xcode app, shared shader types, test targets, offscreen Metal
harness, scripted scene format, and benchmark recording.

Exit: blank Metal canvas renders onscreen and offscreen; macOS build and pure
tests pass.

### Slice 1: Measured Grid Drawing Kernel

Add normalized mouse input, viewport, pan/zoom, world interpolation, one
hard-round brush, canonical raster, persistent live stroke, commit, and cancel.

Exit: immediate grid drawing; preview equals commit; long strokes have stable
frame time.

### Slice 2: Generalized Seam-Correct Tiling

Add cell-fragment projection, all listed tilings, full transforms and clips,
editable preview cells, rectangular tiles, CPU oracle, and GPU scenes.

Exit: supported geometry passes zero-hole/zero-phantom tests; tiling switches
preserve canonical bytes.

### Slice 3: Transactions, Region Undo, Color, Eraser

Add total lifecycle reducer, raster revision store, metadata commands, bounded
history, color, destination-out eraser, shortcuts, and minimal controls.

Exit: ordered transaction tests pass; live/commit eraser parity passes; undo
restores exact regions.

### Slice 4: Professional Stroke Core

Add BrushInput V2, pressure-carrying interpolation, BrushDynamicsEngine,
recipes, deterministic scatter, shape/grain assets, taper, transient replay,
and dry/ink/glaze/bounded-wash materials.

Exit: anchor brushes feel distinct; spacing, opacity, and seam gates pass.

### Slice 5: Brush Product

Add engine preview renderer, Brush Library, Brush Studio, response curves,
grouped controls, asset pack, and 12-16 calibrated presets.

Exit: Precision Light brush workflow is accepted; every preset has preview and
family coverage.

### Slice 6: Layers

Add pattern/floating stack, compositor, active-layer routing, visibility,
opacity, initial blend modes, layer commands, dirty tracking, and right
inspector.

Exit: eight-layer baseline passes correctness and performance gates.

### Slice 7: Selection And Transform

Add rectangular selection, lift/cut, provisional affine preview, move, scale,
rotate, confirm/cancel, and floating placement against real layer ownership.

Exit: real Mac interaction works; transform creates exactly one undo command.

### Slice 8: Persistence And Export

Add schema, archive, save/open, autosave recovery, thumbnail, source/baked/scene
exports, and project browser.

Exit: round trips and exports are pixel-correct; drawing stays responsive
during background work.

### Slice 9: Hardening

Add memory-pressure handling, texture-pool tuning, 4096 stress, accessibility,
menus, high-DPI/window behavior, crash recovery, and packaging.

Exit: Mac release candidate passes full matrix. iPad device gates run when
hardware is available.

## 18. Completion Criteria

The rebuild is ready for V1 release when:

- Every included workflow exists in usable UI.
- All pure, GPU, and integration tests pass.
- No known seam defect exists for supported active-tiling behavior.
- Mac feel and performance gates pass.
- Project round trips and exports are pixel-correct.
- Known limitations match this document and are not hidden regressions.
- iPad-specific claims are withheld until device verification passes.

## 19. Recovered Source Documents

- `00-apple-native-pivot-design.md`
- `03-live-drawing-design.md`
- `04-multi-tiling-design.md`
- `05-input-architecture-design.md`
- `06-offscreen-render-harness.md`
- `07-drawing-tools-roamap.md`
- `08-colored-brush-design.md`
- `09-eraser-design.md`
- `10-undo-redo-design.md`
- `11-selection-transform-design.md`
- `12-raster-brush-design.md`
- `13-png-brush-quality-design.md`
- `14-edit-transaction-module-design.md`
- `15-professional-brush-design.md`
- `16-reference-sheet.md`
- `backlog.md`
- `notes/live-tile-perf-promotion-undo.md`
- `notes/halfdrop-edge-dab-clipping.md`
