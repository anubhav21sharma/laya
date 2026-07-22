# Professional Stroke Core Implementation Plan

**Goal:** Deliver Slice 4: deterministic BrushInput V2, attributed
interpolation, recipe-driven dynamics, shape/grain rendering, taper and
bounded replay, dry/ink/glaze/bounded-wash materials, and four selectable
anchor recipes without changing the raster document or transaction model.

**Governing spec:**
`docs/superpowers/specs/2026-07-22-professional-stroke-core-design.md`

**Master precedence:**
`docs/superpowers/specs/2026-07-18-pattern-product-rebuild-design.md`

**Architecture:** PatternEngine normalizes and generates deterministic
world-space dabs. EditorCore owns active recipe intent and captures immutable
stroke configuration. MetalRenderer resolves assets, projects/stamps generated
footprints, manages settled-live/replay epochs and material working textures,
and commits the combined live result through the existing raster revision
seam. The app remains a thin native-input and UI adapter.

**Tech stack:** Swift 6, Swift Testing, Observation, SwiftUI, AppKit/UIKit,
Metal, MetalKit, shared C/MSL ABI, XcodeGen, Bash, and JSON harness scenes.

## Global Constraints

- Work directly on `main`; the user explicitly selected the main checkout.
- Preserve unrelated worktree content, including untracked `.vscode/` files.
- Minimum macOS 14 and iPadOS 17; both application targets remain buildable.
- PatternEngine imports Foundation and simd only.
- EditorCore exposes no Metal, SwiftUI, AppKit, UIKit, or native event types.
- MetalRenderer owns no editor intent or history policy.
- Canonical and live color textures remain `.bgra8Unorm` premultiplied
  storage; shape and grain textures are `.r8Unorm` with mipmaps.
- Canonical pixels remain the retained artifact; never persist samples/dabs.
- World interpolation and dynamics precede tiling projection.
- Current tiling raw values, buffer indexes, and texture indexes are never
  renumbered; additions are append-only.
- Keep current `LiveStroke` as renderer upload state. Name engine replay state
  `TransientStrokeBuffer`.
- Preserve one pointer-up/one raster history command and cancel/no-command.
- Preserve destination-out erasing and separate eraser strength.
- Never block the main actor waiting for a command buffer.
- Every transient buffer, replay mode, wash pass, and dirty-region collection
  has a hard cap and tested degradation path.
- Every new harness family first proves its negative control fails, then proves
  the positive scene passes.
- Slice 5 owns preview rendering, Brush Library, Brush Studio, editable
  multi-point curves, and the final 12-16 preset pack. Do not pull them into
  this plan.
- Run focused tests after each red/green step, both target builds after every
  integration task, and the full gate before completion.
- Obtain a fresh diff review and verification before each commit. Commit task
  groups only after their focused checks are green.

## Baseline Commands

Run before Task 1 and record the results in the Slice 4 milestone draft:

```bash
git status --short --branch
swift test
./scripts/bootstrap.sh
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedDataPad \
  build CODE_SIGNING_ALLOWED=NO
```

Do not run `scripts/verify-slice3.sh` against a dirty implementation checkout;
its source-provenance check intentionally requires committed source. The Slice
4 gate will inherit and extend that behavior.

## Planned File Map

Exact grouping may move when a type is demonstrably better colocated, but
module ownership and semantics are fixed by the governing spec.

### PatternEngine

- Modify `Sources/PatternEngine/StrokeSample.swift`
  - V2 provenance, capabilities, orientation, validated construction.
- Create `Sources/PatternEngine/BrushInput.swift`
  - screen-to-world derivation, finite velocity policy, attributed samples.
- Create `Sources/PatternEngine/StrokeStabilizer.swift`
  - deterministic bounded stabilizer.
- Modify or replace
  `Sources/PatternEngine/CentripetalCatmullRomStrokeInterpolator.swift`
  - attributed path segments and legacy wrapper during migration.
- Create `Sources/PatternEngine/BrushRecipe.swift`
  - recipe IDs, mappings, assets, taper, replay, material descriptions.
- Create `Sources/PatternEngine/BrushRandom.swift`
  - SplitMix64 and fixed named random channels.
- Create `Sources/PatternEngine/BrushDynamicsEngine.swift`
  - contexts and `DabAttributes` evaluation.
- Create `Sources/PatternEngine/BrushStrokeGenerator.swift`
  - path walking, dynamic spacing, actual/predicted generator snapshots.
- Create `Sources/PatternEngine/TransientStrokeBuffer.swift`
  - append/tail/whole modes, caps, prefix promotion, replay decisions.
- Modify `Sources/PatternEngine/StrokeRenderStyle.swift`
  - immutable recipe/configuration/seed capture while retaining draw/erase.
- Modify `Sources/PatternEngine/StampFootprint.swift`
  - generated non-round local bounds/coverage symmetry as needed.
- Modify `Sources/PatternEngine/TilingProjection.swift`
  - conservative transformed and material-halo dirty bounds.

### EditorCore

- Create `Sources/EditorCore/Brushes/AnchorBrushCatalog.swift`
  - the four immutable anchor recipes and dedicated eraser recipe.
- Modify `Sources/EditorCore/Model/EditorModel.swift`
  - active anchor identity and confirmation method.
- Modify `Sources/EditorCore/Transactions/EditorTransaction.swift`
  - recipe intent/effect and captured stroke configuration.
- Modify `Sources/EditorCore/Commands/EditorCommand.swift` and
  `Sources/EditorCore/Commands/EditorKeymap.swift` only if a semantic recipe
  command is needed; do not assign digit keys already used by tilings.

### CShaderTypes And MetalRenderer

- Modify `Sources/CShaderTypes/include/ShaderTypes.h`
  - 128-byte projected instance, material uniform, appended bindings/selectors.
- Modify `Sources/MetalRenderer/ShaderABI.swift`
  - exact size/alignment/offset and selector checks.
- Modify `Sources/MetalRenderer/ProjectedStampInstance.swift`
  - transformed footprint and packed brush attributes.
- Create `Sources/MetalRenderer/Brush/BrushTextureResolver.swift`
  - cached asset resolution, procedural fallbacks, one-shot diagnostics.
- Create `Sources/MetalRenderer/Brush/BrushTextureFactory.swift`
  - deterministic `.r8Unorm` procedural assets and mip generation.
- Create `Sources/MetalRenderer/Brush/BrushMaterialState.swift`
  - validated GPU bindings/uniform conversion.
- Create `Sources/MetalRenderer/Brush/ReplayLiveTile.swift`
  - replay-only accumulation texture, region/full clear, visibility.
- Create `Sources/MetalRenderer/Brush/BoundedWashSurface.swift`
  - fixed working textures, dirty halo, capped local passes.
- Modify `Sources/MetalRenderer/GridPipelineLibrary.swift`
  - ink, dry, glaze, wash deposition/resolve pipelines.
- Modify `Sources/MetalRenderer/Shaders.metal`
  - shape/grain sampling, material functions, shared opacity composite.
- Modify `Sources/MetalRenderer/LiveStroke.swift`
  - settled/replay upload targets, render epoch, and globally safe identity
    bookkeeping without changing its role into an engine sample buffer.
- Modify `Sources/MetalRenderer/GridRenderCompletionMailbox.swift`
  - epoch-bearing upload outcomes and stale-epoch handling.
- Modify `Sources/MetalRenderer/GridRenderer.swift`
  - generator integration, asset/material binding, settled-prefix promotion,
    replay clear/restamp, wash, commit readiness, and expanded dirty regions.
- Modify `Sources/MetalRenderer/BenchmarkRecord.swift`
  - Slice 4 bounded-state and material timing fields.

### App

- Create `App/PatternSpike/Input/BrushInputAdapter.swift`
  - native event extraction and ordered batch construction.
- Modify `App/PatternSpike/Canvas/InteractiveMetalView.swift`
  - use the macOS V2 adapter; no brush policy.
- Modify `App/PatternSpike/Canvas/MetalCanvas.swift`
  - forward active nominal diameter unchanged; retain build-safe iPad host.
- Modify `App/PatternSpike/EditorSessionController.swift`
  - ordered sample batches, captured recipe/seed, renderer execution.
- Modify `App/PatternSpike/Panels/EditorTopBar.swift`
  - compact four-anchor text menu.
- Modify `App/PatternSpike/ContentView.swift` only if required to thread the
  active anchor state; preserve controller identity.
- Modify `App/project.yml` and `Package.swift` source lists only as required by
  new app test files.

### Tests, Harness, Scripts, And Docs

- Add focused pure tests under `Tests/PatternEngineTests/` for every new engine
  component.
- Add EditorCore tests for catalog, model, and reducer ordering.
- Add renderer tests for ABI, texture identity/fallback, material uniforms,
  epochs, replay ordering, wash bounds, and instance accounting.
- Add app tests for adapters, batch/controller ordering, anchor picker/model,
  cursor stability, and regression controls.
- Modify `Sources/MetalRenderer/Capture/HarnessScene.swift`
  - schema 5 recipe/seed/attributed trace and Slice 4 metrics.
- Create `Sources/MetalRenderer/Capture/SliceFourHarnessRunner.swift`.
- Add Slice 4 app harness orchestration beside the Slice 3 runner.
- Add positive and negative-control scene JSON files under
  `App/PatternSpike/Harness/Scenes/`.
- Create `Sources/SliceFourEvidenceGate/main.swift` and package executable.
- Create `scripts/verify-slice4.sh`.
- Create
  `docs/superpowers/milestones/04-professional-stroke-core.md`.

---

## Task 1: Freeze Baseline And Add Deterministic Trace Fixtures

**Purpose:** Make legacy pixel/placement behavior and reusable attributed input
traces explicit before changing the stroke path.

**Files:**

- Modify `Tests/PatternEngineTests/CentripetalCatmullRomStrokeInterpolatorTests.swift`
- Create `Tests/PatternEngineTests/BrushTraceFixtures.swift`
- Modify `Tests/MetalRendererTests/ProjectedStampInstanceTests.swift`
- Modify `Tests/MetalRendererTests/HarnessSceneTests.swift`
- Start `docs/superpowers/milestones/04-professional-stroke-core.md`

- [x] Record current full test count, Mac/iPad build results, current 112-byte
  stride, representative placement arrays, and current scene schema versions.
- [x] Add pinned straight, curved, click, repeated-timestamp, pressure-ramp,
  seam-crossing, reflected, and long-stroke trace fixtures.
- [x] Add a legacy hard-round footprint/instance fixture with exact positions,
  radius, affine, clips, color, and dirty region.
- [x] Add a test proving the current fixture is independent of native event
  types and reusable from pure, renderer, and harness tests.
- [x] Run:

```bash
swift test --filter 'CentripetalCatmullRomStrokeInterpolator|BrushTraceFixtures|ProjectedStampInstance|HarnessScene'
```

**Exit:** current behavior is pinned before any production type changes.

## Task 2: BrushInput V2 And World-Space Derivation

**Purpose:** Extend current samples additively and centralize validation,
capabilities, world conversion, and velocity without changing rendered output.

**Files:**

- Modify `Sources/PatternEngine/StrokeSample.swift`
- Create `Sources/PatternEngine/BrushInput.swift`
- Create `Tests/PatternEngineTests/BrushInputTests.swift`
- Modify current sample constructors/tests across package and app tests

- [x] Write failing tests for finite rejection, pressure/angle normalization,
  absent sensor capabilities, provenance, mouse compatibility, repeated
  timestamps, world-space velocity, zoom independence, and cancel reset.
- [x] Add V2 fields with defaults that preserve existing construction sites.
- [x] Add `WorldStrokeSample` and a stateful pure derivation value. Keep
  viewport conversion explicit; do not import renderer types into the engine.
- [x] Preserve the single-sample API as a wrapper during migration.
- [x] Prove current renderer tests still receive the same world positions.
- [x] Run:

```bash
swift test --filter 'BrushInput|StrokeSample|ViewportTransform|EditorTransaction'
```

**Exit:** all active samples are valid V2 values; hard-round pixels are
unchanged.

## Task 3: Stabilizer And Pressure-Carrying Path Interpolation

**Purpose:** Separate attributed curve construction from dab spacing while
preserving the current geometric output through a compatibility wrapper.

**Files:**

- Create `Sources/PatternEngine/StrokeStabilizer.swift`
- Modify `Sources/PatternEngine/CentripetalCatmullRomStrokeInterpolator.swift`
- Create `Tests/PatternEngineTests/StrokeStabilizerTests.swift`
- Create `Tests/PatternEngineTests/AttributedStrokeInterpolatorTests.swift`
- Retain/update current interpolator tests

- [ ] Write failing tests for zero-strength bit identity, deterministic carry,
  attribute order, cancel, and copied predicted state.
- [ ] Write failing attributed interpolation tests for pressure ramp,
  timestamp, shortest-arc angles, missing values, straight/curve parity,
  spacing carry, and exact final endpoint.
- [ ] Extract the existing portable Catmull-Rom arithmetic into an attributed
  path component without rewriting its SIMD formula.
- [ ] Keep a legacy position-only wrapper until Task 5 replaces every caller.
- [ ] Run:

```bash
swift test --filter 'StrokeStabilizer|AttributedStrokeInterpolator|CentripetalCatmullRomStrokeInterpolator'
```

**Exit:** attributed paths pass and the old placement fixtures remain exact.

## Task 4: Recipes, SplitMix64, And BrushDynamicsEngine

**Purpose:** Establish immutable recipe validation and one deterministic pure
evaluator before integrating it with rendering.

**Files:**

- Create `Sources/PatternEngine/BrushRecipe.swift`
- Create `Sources/PatternEngine/BrushRandom.swift`
- Create `Sources/PatternEngine/BrushDynamicsEngine.swift`
- Create `Tests/PatternEngineTests/BrushRecipeTests.swift`
- Create `Tests/PatternEngineTests/BrushRandomTests.swift`
- Create `Tests/PatternEngineTests/BrushDynamicsEngineTests.swift`

- [ ] Write validation failures for nonfinite/out-of-range mappings,
  unsupported assets, unbounded replay, and excessive wash parameters.
- [ ] Pin SplitMix64 output words and upper-24-bit float conversion for at
  least three seeds.
- [ ] Prove each dab consumes fixed named channels even when mappings are off;
  predicted evaluation must leave actual cursor unchanged.
- [ ] Test pressure/no-pressure neutral, speed, direction, tilt, roll,
  age/distance, size, spacing, flow, opacity, rotation, scatter, hardness,
  grain, color adjustment, and material contribution.
- [ ] Add a legacy-equivalent recipe and prove it evaluates the current radius,
  spacing, color, and hard-round transform.
- [ ] Run:

```bash
swift test --filter 'BrushRecipe|BrushRandom|BrushDynamicsEngine'
```

**Exit:** dynamics are deterministic, validated, renderer-free, and capable of
representing current behavior.

## Task 5: BrushStrokeGenerator And Append-Only Renderer Integration

**Purpose:** Make the new generator the only input-to-footprint path while
holding GPU output to legacy hard-round parity.

**Files:**

- Create `Sources/PatternEngine/BrushStrokeGenerator.swift`
- Create `Tests/PatternEngineTests/BrushStrokeGeneratorTests.swift`
- Modify `Sources/PatternEngine/StrokeRenderStyle.swift`
- Modify `Sources/MetalRenderer/GridRenderer.swift`
- Modify `App/PatternSpike/EditorSessionController.swift`
- Modify renderer transaction and app controller tests

- [ ] Write generator tests for dynamic spacing carry, no coincident emission,
  exact end point, pressure-per-dab, event partition invariance, click, cancel,
  and deterministic transformed footprints.
- [ ] Extend captured stroke configuration with validated recipe and seed.
- [ ] Convert V2 screen samples to world samples, stabilize, interpolate,
  evaluate dynamics, then project the generated footprint.
- [ ] Keep rendering on the existing hard-round shader and append-only queue.
- [ ] Delete the direct position-only renderer path after parity is proven; do
  not keep parallel legacy policy.
- [ ] Compare legacy fixture arrays and hard-round harness artifacts.
- [ ] Run:

```bash
swift test --filter 'BrushStrokeGenerator|RendererTransaction|EditorSessionController|CentripetalCatmullRomStrokeInterpolator'
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedDataPad build CODE_SIGNING_ALLOWED=NO
```

**Exit:** one new pure generator drives rendering with no known legacy pixel,
transaction, or history change.

## Task 6: Grow The ABI And Add Asset Resolution

**Purpose:** Carry hardness/grain attributes and bind deterministic mipmapped
shape/grain textures without yet changing the visible legacy anchor.

**Files:**

- Modify `Sources/CShaderTypes/include/ShaderTypes.h`
- Modify `Sources/MetalRenderer/ShaderABI.swift`
- Modify `Sources/MetalRenderer/ProjectedStampInstance.swift`
- Create `Sources/MetalRenderer/Brush/BrushTextureFactory.swift`
- Create `Sources/MetalRenderer/Brush/BrushTextureResolver.swift`
- Modify `Sources/MetalRenderer/GridRenderer.swift`
- Modify ABI, instance, buffer-pool, benchmark, and asset tests

- [ ] First change tests to expect 128-byte stride and exact offsets, proving
  they fail against the 112-byte production layout.
- [ ] Append `brushAttributes`, material uniforms, and new wire bindings without
  renumbering existing constants.
- [ ] Update projected-instance construction and all byte accounting,
  including old Slice 2/3 evidence validators that multiply fragment count by
  instance stride.
- [ ] Generate deterministic hard/soft/non-round coverage and opaque/paper/noise
  grain textures as `.r8Unorm` with complete mip chains.
- [ ] Add resolver caching, asset identity, missing-asset fallback, and one-shot
  diagnostics. Prove a named asset scene cannot pass by silently using the
  procedural fallback.
- [ ] Bind fallback hard-round/opaque-grain while retaining old visible pixels.
- [ ] Run:

```bash
swift test --filter 'ShaderABI|ProjectedStampInstance|DabInstanceBufferPool|BrushTexture|BenchmarkRecord|SliceThreeEvidenceValidator'
```

**Exit:** the guarded ABI is 128 bytes, assets are ready before strokes, and
legacy rendering remains pixel-equivalent.

## Task 7: Ink And Dry Material Rendering

**Purpose:** Replace the procedural-only fragment with shape x grain coverage
and prove transformed asset continuity before adding opacity or replay.

**Files:**

- Create `Sources/MetalRenderer/Brush/BrushMaterialState.swift`
- Modify `Sources/MetalRenderer/GridPipelineLibrary.swift`
- Modify `Sources/MetalRenderer/Shaders.metal`
- Modify `Sources/MetalRenderer/GridRenderer.swift`
- Modify `Sources/PatternEngine/StampFootprint.swift`
- Modify `Sources/PatternEngine/TilingProjection.swift`
- Add material, shader-source, projection-oracle, and renderer tests

- [ ] Add CPU reference coverage for hard, soft, tapered/chisel, canonical
  grain, and brush-local grain.
- [ ] Add failing shader/renderer tests for shape coverage, hardness, grain
  identity, full affine rotation/reflection, and conservative dirty bounds.
- [ ] Implement ink and dry pipeline states using shared clip and coordinate
  functions.
- [ ] Bake rotation, anisotropy, pressure size, and scatter into the existing
  affine. Do not duplicate those fields in the instance.
- [ ] Use `.oriented` coverage symmetry for directional shapes and preserve
  `.halfTurnInvariant` only for shapes whose pixels actually have that
  symmetry. For anisotropic stamps, derive antialias expansion from the
  minimum affine scale and dirty bounds from expanded transformed bounds.
- [ ] Prove zero holes/phantoms and coordinate continuity across every tiling
  with both canonical and brush-local modes before enabling them in anchors.
- [ ] Run focused pure and renderer tests, then Mac/iPad builds.

**Exit:** ink and dry produce distinct pixels, remain seam-correct, and preserve
live/commit equality at opacity 1.

## Task 8: Glaze Flow And Stroke-Opacity Parity

**Purpose:** Introduce true flow accumulation and one-time premultiplied stroke
opacity without a pointer-up jump.

**Files:**

- Modify `Sources/CShaderTypes/include/ShaderTypes.h`
- Modify `Sources/MetalRenderer/ShaderABI.swift`
- Modify `Sources/MetalRenderer/Shaders.metal`
- Modify `Sources/MetalRenderer/GridRenderer.swift`
- Modify material/renderer/harness tests

- [ ] Write tests showing per-dab flow builds inside live while visible output
  cannot exceed the configured stroke-opacity ceiling.
- [ ] Prove source-over of replay-tail over settled-live is chronological and
  the combined premultiplied layer is scaled exactly once.
- [ ] Write preview/commit comparisons for translucent colored draw and erase
  at overlaps and antialiased edges.
- [ ] Bind one stroke-opacity value to both display and commit and scale
  premultiplied RGB/alpha together exactly once.
- [ ] Keep eraser strength independent of draw opacity and synthetic pressure.
- [ ] Inject a deliberately per-dab-applied opacity negative control and prove
  the parity test catches the darkening.
- [ ] Run focused renderer tests and the current colored/eraser harness scenes.

**Exit:** glaze accumulation is distinct; pointer-up delta is at most one
8-bit value for draw and erase.

## Task 9: TransientStrokeBuffer, Taper, And Replay Epochs

**Purpose:** Support predicted correction and retroactive end taper without
stale pixels, identity reuse, main-actor waits, or unbounded state.

**Files:**

- Create `Sources/PatternEngine/TransientStrokeBuffer.swift`
- Add `Tests/PatternEngineTests/TransientStrokeBufferTests.swift`
- Extend `BrushStrokeGenerator` and tests for snapshots/taper
- Create `Sources/MetalRenderer/Brush/ReplayLiveTile.swift`
- Modify `Sources/MetalRenderer/LiveStroke.swift`
- Modify `Sources/MetalRenderer/GridRenderCompletionMailbox.swift`
- Modify `Sources/MetalRenderer/GridRenderer.swift`
- Modify buffer/completion/renderer transaction tests

- [ ] Test append-only, 256-sample/2,048-dab tail caps, 4,096-sample/4,096-dab
  whole caps, the 4,096 projected-instance visible-epoch cap, deterministic
  prefix promotion, replay-window shortening, and cancel reset.
- [ ] Test start taper, end taper, click, short stroke, tail longer than stroke,
  and predicted endpoint replacement.
- [ ] Add render epochs and nonreused active-stroke instance identities. Every
  completion carries epoch; stale epochs reclaim leases but cannot advance the
  latest high-water mark.
- [ ] Keep settled coverage in `PersistentLiveTile` and retained/predicted
  coverage in `ReplayLiveTile`. Promote dabs leaving the replay window into
  settled-live before dropping their engine state.
- [ ] Add regional replay-tail clear/restamp with full replay-texture fallback
  when bounds are unsafe. Never clear the settled-live prefix during replay.
- [ ] Project the complete replacement first and preflight its upload lease plus
  any promotion lease. If unavailable, leave the prior replay texture visible
  and retry; never clear or display a partial replacement epoch.
- [ ] Composite replay-tail over settled-live in chronological order, then
  apply stroke opacity once. Use the identical combined-live function for
  display and commit.
- [ ] Prove delayed and deliberately reordered mailbox drainage cannot expose
  an old epoch or commit before the newest high-water mark.
- [ ] Inject clear, upload, and replay failure; canonical bytes and history must
  remain unchanged and controls return idle.
- [ ] Run focused tests plus Mac/iPad builds under Thread Sanitizer where the
  current non-crash suite supports it.

**Exit:** end taper and prediction replay correctly, storage stays capped, and
no stale GPU completion corrupts the current stroke.

## Task 10: Bounded Wash

**Purpose:** Add the fourth governed material using fixed working textures and
local bounded passes, not a fluid simulation.

**Files:**

- Create `Sources/MetalRenderer/Brush/BoundedWashSurface.swift`
- Modify `Sources/MetalRenderer/GridPipelineLibrary.swift`
- Modify `Sources/MetalRenderer/Shaders.metal`
- Modify `Sources/MetalRenderer/GridRenderer.swift`
- Modify `Sources/MetalRenderer/MetalRendererError.swift`
- Add wash surface, bounds, failure, renderer, and benchmark tests

- [ ] Test allocation format/size, a maximum two passes, maximum 32-pixel halo,
  clipped/wrapped dirty regions, and resource reuse.
- [ ] Test whole-stroke replay until cap and deterministic prefix promotion
  into settled-live before replay-tail mode after cap.
- [ ] Implement deposit, fixed local soften/bleed, and resolve into the same
  premultiplied live tile.
- [ ] Include the material halo in dirty history capture. A cap overflow uses
  the existing conservative full-tile region.
- [ ] Prove per-frame processed pixels depend on new/replayed dirty area and
  fixed halo, not settled stroke length.
- [ ] Inject allocation and command failures and prove canonical/history
  preservation.
- [ ] Run focused tests and a long-wash diagnostic benchmark.

**Exit:** wash is visibly distinct, deterministic, seam-correct, bounded, and
uses the common preview/commit equation.

## Task 11: Anchor Catalog, Reducer Intent, And Minimal Picker

**Purpose:** Make the four engine anchors selectable without implementing Slice
5's brush product.

**Files:**

- Create `Sources/EditorCore/Brushes/AnchorBrushCatalog.swift`
- Modify `Sources/EditorCore/Model/EditorModel.swift`
- Modify `Sources/EditorCore/Transactions/EditorTransaction.swift`
- Modify `App/PatternSpike/EditorSessionController.swift`
- Create/modify `App/PatternSpike/Input/BrushInputAdapter.swift`
- Modify `App/PatternSpike/Canvas/InteractiveMetalView.swift`
- Modify `App/PatternSpike/Panels/EditorTopBar.swift`
- Add catalog/model/reducer/adapter/controller/UI tests

- [ ] Pin stable recipe IDs and validate Technical Ink, Dry Pencil, Glaze
  Marker, Bounded Wash, and dedicated Hard Round Eraser.
- [ ] Add reducer tests: idle selection updates; collecting selection emits
  cancel then update; commit-pending selection is busy; failed stroke returns
  idle without changing recipe.
- [ ] Capture recipe value and seed at pointer-down so selection changes cannot
  mutate an active stroke.
- [ ] Implement macOS V2 actual/tablet extraction and ordered batches. Keep
  native types in the app adapter.
- [ ] Add only a compact labeled picker. Do not add preview thumbnails,
  categories, settings, custom state, curves, or import.
- [ ] Verify brush diameter cursor remains the nominal maximum for all anchors.
- [ ] Verify every control and shortcut still works after repeated recipe/tool
  changes, and the dedicated eraser always erases.
- [ ] Build and launch Mac; build and simulator-launch iPad current layout.

**Exit:** all anchors are usable from the UI, transaction ordering is total,
and no Slice 5 surface has leaked in.

## Task 12: Harness Schema 5 And Slice 4 Evidence

**Purpose:** Turn every load-bearing engine/material claim into repeatable
offscreen evidence and one provenance-aware gate.

**Files:**

- Modify `Sources/MetalRenderer/Capture/HarnessScene.swift`
- Create `Sources/MetalRenderer/Capture/SliceFourHarnessRunner.swift`
- Modify app harness routing/history files
- Modify `Sources/MetalRenderer/BenchmarkRecord.swift`
- Create scene JSON pairs under `App/PatternSpike/Harness/Scenes/`
- Create `Sources/SliceFourEvidenceGate/main.swift`
- Modify `Package.swift`
- Create `scripts/verify-slice4.sh`
- Complete `docs/superpowers/milestones/04-professional-stroke-core.md`

- [ ] Add schema 5 fields for recipe ID, explicit `UInt64` seed, attributed
  sample trace, expected material, replay mode, and Slice 4 checks. Continue
  decoding schema 3/4 scenes unchanged.
- [ ] Add benchmark fields for material, seed, retained samples/dabs, replay
  count, promoted settled prefixes, replay degradation, asset bytes, material
  GPU time, processed wash pixels, and wash working bytes.
- [ ] Add positive/negative-control pairs for:
  - legacy hard-round parity;
  - pressure size/flow;
  - deterministic scatter same/different seed;
  - shape/hardness and asset identity;
  - canonical and brush-local grain continuity;
  - dry, ink, glaze opacity, and bounded wash;
  - end taper and predicted replacement;
  - stale replay epoch completion;
  - every anchor/material across all tilings and noncentral cells;
  - draw/erase after every anchor;
  - live/commit for every material;
  - cancel/failure canonical preservation;
  - one history command per completed stroke;
  - long-stroke and replay/wash bounds.
- [ ] Make the gate run Slice 0-3 regression scenes, all Slice 4 negative
  controls, all Slice 4 positives, pure tests, Mac/iPad build and analyze, and
  provenance checks.
- [ ] Treat paravirtual timing as an explicit pending result while still
  failing correctness, bounds, missing metrics, or malformed evidence.
- [ ] Run the gate only from committed source and archive exact stdout/stderr,
  artifact paths, hardware identity, OS, configuration, and commit.

**Exit:** one command proves all automatable Slice 4 claims and clearly
separates functional pass from hardware-only pending evidence.

## Task 13: Full Regression, Sanitizers, Review, And Acceptance Handoff

**Purpose:** Close integration gaps before declaring Slice 4 complete.

- [ ] Run formatting/lint checks already configured by the repository.
- [ ] Run `swift test` and record exact count.
- [ ] Build and analyze both application targets.
- [ ] Run current ASan and TSan non-crash suites; document unsupported tests
  rather than silently omitting them.
- [ ] From committed source, run `scripts/verify-slice4.sh` and retain all
  artifacts.
- [ ] Run macOS UI automation covering anchor selection, draw/erase, diameter,
  cursor, grid, tiling, clear, undo/redo, keyboard focus, and debug HUD.
- [ ] Perform fresh code review against both governing specs, specifically
  checking hot-path allocation, epoch ordering, premultiplied math, ABI byte
  accounting, caps, asset fallback diagnostics, transaction ordering, and
  Slice 5 scope leakage.
- [ ] Perform manual Mac gate: four anchors distinct, cursor aligned,
  pan/zoom, no opacity jump, no stale replay flash, long-stroke feel, wash
  responsiveness, and all-tiling visual seam scan.
- [ ] Mark unavailable stable timing, tablet, or iPad hardware checks pending
  with exact reason. Do not call them pass.
- [ ] Update milestone status and master status/index references.

Final verification commands:

```bash
git diff --check
swift test
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build analyze CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedDataPad build analyze CODE_SIGNING_ALLOWED=NO
./scripts/verify-slice4.sh
git status --short --branch
```

**Exit:** all automatable correctness, bounds, build, analyzer, sanitizer, UI,
and evidence checks pass; manual/hardware-only residue is explicitly listed.

## Commit Sequence

Use compact conventional commits after each green reviewed group:

1. `test(brush): pin stroke trace baseline`
2. `feat(brush): add normalized input v2`
3. `feat(brush): carry attributes through interpolation`
4. `feat(brush): add deterministic recipe dynamics`
5. `refactor(brush): route strokes through generator`
6. `feat(renderer): add brush assets and guarded abi`
7. `feat(renderer): render ink and dry materials`
8. `feat(renderer): add glaze opacity parity`
9. `feat(brush): add taper and bounded replay`
10. `feat(renderer): add bounded wash material`
11. `feat(editor): expose anchor brush selector`
12. `test(brush): add slice 4 evidence gate`
13. `docs(brush): record slice 4 acceptance`

Do not force a commit if a task naturally shares an unreviewable intermediate
with the next task; keep the working state buildable and explain any combined
commit in the milestone.

## Slice 4 Exit Checklist

- [ ] V2 input and world velocity are the only active brush-input path.
- [ ] Attributed interpolation preserves legacy geometry and smooth pressure.
- [ ] One deterministic dynamics engine evaluates every dab.
- [ ] Recipe/random output is pinned and prediction cannot advance actual
  state.
- [ ] Shape/grain assets use guarded identity, fallback, mip, and seam paths.
- [ ] Projected-instance ABI and byte accounting agree at 128 bytes.
- [ ] Dry, ink, glaze, and bounded wash are distinct and bounded.
- [ ] Stroke opacity and eraser preview equal commit within one 8-bit value.
- [ ] Taper/replay handle stale GPU completions without waiting.
- [ ] Four anchors and a dedicated eraser are selectable and correct.
- [ ] Every enabled mode passes all seven tilings and noncentral-cell gates.
- [ ] One stroke remains one history command; cancel/failure create none.
- [ ] Slice 0-3 regressions remain green.
- [ ] Mac and iPad targets build/analyze; sanitizer results are recorded.
- [ ] Performance and memory metrics are present and bounded.
- [ ] Hardware-only pending checks are named precisely.
- [ ] No Brush Library, Studio, previews, final preset pack, layers,
  selection, persistence, or export work entered Slice 4.
