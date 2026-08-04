# Stage D Color And Sparse Paint Surfaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish one typed linear-light color contract, replace every
full-canvas paint-bearing working texture with bounded 256 × 256 `rgba16Float`
tiles, add deterministic tile-backed history and project persistence, and
compose at most eight ordered layers without weakening the accepted Stage B/C
stroke lifecycle.

**Architecture:** Encoded sRGB exists only at UI/archive and display/export
boundaries. Paint enters the renderer as typed linear-premultiplied values and
remains linear through deposition, live/prediction accumulation, canonical
storage, erase, history, and layer composition. A sparse tile store owns
private Metal tiles and a deterministic byte-budgeted residency policy; the
off-main stroke encoder publishes immutable dirty-tile leases rather than two
full-canvas textures. `EditorCore.LayerStack` owns layer order and active-layer
rules, `PatternFile` owns schema-v4 wire data, `MetalRenderer` owns tile bytes
and GPU composition, and `GridRenderer` remains the lifecycle facade.

**Tech Stack:** Swift 6.0 with complete concurrency checking, Swift Testing,
Metal/MetalKit, CoreGraphics/ImageIO, SafeArchive/PatternFile, XcodeGen 2.46+,
macOS 14+, and iPadOS 18+.

**Authority:** This plan is the just-in-time refinement required by the
Universal Stage Delivery Protocol in
`docs/superpowers/plans/2026-08-01-brush-engine-corrective-program.md`. It
supersedes only that document's Stage D task decomposition. The corrective
program's Goal, Global Constraints, locked decisions, Stage D exit, later-stage
interfaces, and explicit non-goals remain binding.

**Baseline:** Stage C is accepted at `ca5dff5`. The final focused Stage C gate
passed 37 tests, the prescribed medium gate passed 400 tests, and the broad
suite completed 1,716 tests with exactly the 27 frozen Stage B issue records.
No Stage D production behavior exists at the baseline.

## Global Constraints

- Execute directly on `main`; do not create a worktree.
- Preserve unrelated user files, including `.vscode/` and
  `brushes/procreate/1_FREE_Charcoal_Set.key`. Stage only task-owned files.
- Write the failing test or measurable assertion before every behavior change.
- Run focused tests after each red/green step and the broad suite at Task 8.
- `PatternEngine` remains platform- and renderer-independent.
- `EditorCore` owns layer ordering and history commands; it never imports Metal.
- `PatternFile` owns wire formats and defensive validation; it never imports
  MetalRenderer.
- `MetalRenderer` owns GPU textures, residency, deposition, composition, and
  raster revision storage.
- Canonical pixels remain the source of truth. Preview and prediction tiles are
  transient and can never be committed as authoritative input.
- One completed stroke produces exactly one history command for the layer that
  was active at pointer-down. Cancel or failure produces none and cannot mutate
  canonical tiles.
- Actual/coalesced samples alone determine committed output. Prediction can be
  shed without changing canonical hashes.
- No ordinary stroke replays its retained body. The Stage C generator and
  scheduler contracts, ordinals, stack gates, and zero-warmed-allocation input
  probes remain green.
- Input callbacks perform bounded copy/enqueue only. Tile allocation, snapshot
  creation, image conversion, Metal encoding, and GPU waits stay off that path.
- Tile allocation failure is typed and transactional. No partial tile set,
  layer mutation, history command, revision publication, or visible output may
  survive a failed operation.
- UI/archive colors are encoded sRGB. Paint storage and blend math are
  premultiplied linear sRGB. Alpha is linear and is never gamma encoded.
- Every paint-bearing canonical, authoritative-live, prediction, scratch, and
  layer tile is 256 × 256 `.rgba16Float` private storage. Edge tiles retain the
  same physical size and use clipped logical bounds.
- Display uses `.bgra8Unorm_srgb` when supported; otherwise the display shader
  performs exactly one explicit linear-to-sRGB encode. PNG export always emits
  encoded-sRGB BGRA8 exactly once.
- The persistent paint residency budget is
  `min(256 MiB, max(64 MiB, recommendedMaxWorkingSetSize / 8))` for a nonzero
  recommendation, otherwise 128 MiB on macOS and 64 MiB on iOS.
- At most eight layers exist. Only the active unlocked layer accepts paint,
  erase, or clear. Normal, multiply, and screen are the only Stage D blend
  modes.
- Existing schema-v1/v2/v3 project files decode without data loss. New saves
  use schema v4. Unknown required formats fail closed.
- Checked-in raster updates require independent semantic/reference evidence;
  current-code output alone is not authority.
- Physical iPad/Pencil/Wacom/120 Hz evidence remains pending and cannot be
  fabricated. It does not block Stage D software acceptance.

## Lifecycle And Ownership Inventory

The following transitions are exhaustive and must have tests before production
wiring changes:

1. **Initialize/import:** create an empty one-layer tiled document, or decode
   v1/v2/v3 encoded BGRA8 once into v4 linear tiles. No empty tile allocates a
   texture.
2. **Begin:** capture the active unlocked layer ID, compiled brush, color, and
   surface generation. Begin with empty authoritative/prediction tile sets.
3. **Append actual/coalesced:** the Stage C scheduler emits new projected
   records; projected support determines a bounded touched-tile set; allocation
   and encoding happen off main; submitted ordinals remain one-shot.
4. **Replace prediction:** clear/rebuild only prior prediction tiles and publish
   a generation-matched immutable lease. Prediction never enters history.
5. **Prepare/submit/display:** pin only tiles needed by the frame, submit
   prepared work, return the lease after the main actor composites it, and
   encode linear tiles to display exactly once.
6. **Finish/commit:** stop prediction, drain actual work, snapshot before-state
   for dirty canonical tiles, compose authoritative live tiles into the
   pointer-down layer, capture after-state, publish exactly one layer-bound
   history command, then retire transient tiles.
7. **Cancel/failure:** discard transient/provisional tiles and revisions,
   preserve every canonical layer byte, return leases, and leave the renderer
   reusable for an immediate next stroke.
8. **Clear:** clear only the active unlocked layer, capture only its nonempty
   tiles, and emit one layer-bound history command. Empty clear is a no-op.
9. **Undo/redo:** restore the command's original layer ID even after reorder or
   active-layer change. Missing/deleted target layers fail atomically.
10. **Layer mutation:** add/delete/reorder/visibility/opacity/lock/active changes
    cannot race an active stroke; transaction policy rejects them while drawing.
11. **Resize/mode switch/import:** allocate/convert the complete replacement
    document before swapping it in. Failure keeps the prior document and
    history intact.
12. **Export/save:** snapshot a stable revision, stream nonempty tile payloads,
    and perform one linear-to-encoded conversion only for PNG/interchange.

---

### Task 0: Freeze Stage D Contracts And Counterexamples

**Files:**

- Create: `Tests/MetalRendererTests/StageDBaselineContractTests.swift`
- Create: `Tests/PatternFileTests/StageDProjectBaselineTests.swift`
- Create: `docs/superpowers/reports/2026-08-04-stage-d-preflight.md`
- Modify: `.superpowers/sdd/2026-08-01-brush-engine-corrective-program/progress.md`

**Interfaces:**

- Consumes: Stage C accepted production lifecycle and
  `Tests/Baselines/stage-b-known-issues.txt`.
- Produces: frozen encoded-BGRA8 import fixtures, existing project v1/v2/v3
  archive hashes, representative dry-scene semantic/canonical hashes, and an
  executable inventory of every full-canvas paint allocation that Task 5 must
  remove.

- [ ] Add a source-structure test that identifies all baseline paint-bearing
  `.bgra8Unorm` allocations in `CanonicalRaster`, `PersistentLiveTile`,
  `ReplayLiveTile`, and `StrokeMetalSurfaceResources`; the test must fail only
  after those allocations are replaced and will be inverted at Task 5.
- [ ] Add fixtures for empty, translucent, low-flow repeated buildup, erase,
  periodic seam, and radial pages. Record encoded input bytes and independent
  expected linear reference values; do not bless current blended pixels as
  color truth.
- [ ] Freeze schema-v1/v2/v3 project decode and deterministic re-encode behavior
  with archives that exercise single raster, radial pages, layer metadata, and
  transparent pixels.
- [ ] Enumerate the twelve lifecycle transitions above in one table-driven test
  so every later task adds its new assertions to a named row rather than
  creating a second lifecycle owner.
- [ ] Run `swift test --filter 'StageDBaselineContractTests|StageDProjectBaselineTests|StageCAcceptance'`.
- [ ] Commit as `test(raster): freeze stage D contracts`.

### Task 1: Add Typed Linear-Light Color Semantics

**Files:**

- Create: `Sources/PatternEngine/Color/DocumentColor.swift`
- Create: `Sources/MetalRenderer/Color/DocumentColorPipeline.swift`
- Modify: `App/PatternSpike/Panels/EditorTopBar.swift`
- Modify: `Package.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Create: `Tests/PatternEngineTests/DocumentColorTests.swift`
- Create: `Tests/MetalRendererTests/DocumentColorPipelineTests.swift`
- Modify: `Tests/MetalRendererTests/DepositionShaderSourceTests.swift`
- Create: `App/Tests/EditorTopBarColorBoundaryTests.swift`

**Interfaces:**

- Produces `EncodedSRGBColor`, `LinearUnpremultipliedColor`, and
  `LinearPremultipliedColor`, each finite and component-bounded.
- Produces pure conversions
  `EncodedSRGBColor.linearPremultiplied()` and
  `LinearPremultipliedColor.encodedSRGB()` using the IEC 61966-2-1 boundaries
  `0.04045` and `0.0031308`.
- Produces `DocumentColorPipeline.workingPixelFormat == .rgba16Float` and
  `displayPixelFormat == .bgra8Unorm_srgb` plus test-only CPU/GPU reference
  operations for source-over, destination-out, normal, multiply, and screen.
- Keeps `EditorTopBar` as the sole live SwiftUI/AppKit/UIKit color boundary and
  makes its result explicitly `EncodedSRGBColor`/encoded `InkColor`; it never
  premultiplies or linearizes UI values.
- Does not change active production paint textures or display in this task.

- [ ] Write pure RED vectors for black/white, both transfer breakpoints,
  transparent nonzero RGB, alpha 0/0.5/1, 50% source-over, destination-out,
  1/8/64 low-flow buildup, and encoded round trip. Require alpha to remain
  unchanged and RGB round-trip error at most `1 / 255`.
- [ ] Write a Metal differential RED that renders typed half-float values and
  requires absolute linear-channel error at most `2e-3` for conversion,
  source-over, buildup, and erase.
- [ ] Implement transfer and premultiplication once in `DocumentColor.swift`;
  shader helpers must use the same constants but not call UI/CoreGraphics APIs.
- [ ] Audit `EditorTopBar`'s SwiftUI/AppKit/UIKit `Color` conversion and add an
  app test proving arbitrary source color spaces become bounded encoded sRGB,
  alpha is preserved, and the UI boundary performs no gamma decode or
  premultiplication. Add the new test file to the explicit Package source list.
- [ ] Add a tested packing conversion API that Task 6 can call, but leave the
  active `DepositionStampInstance` path byte-identical in this task. Converting
  instance color before the paint/display surface switch would create an
  invalid mixed encoded/linear production state. A route-contract test pins
  UI encoded input -> exactly one Task 1 conversion -> linear-premultiplied
  shader payload; Task 6 activates that route atomically.
- [ ] Add negative tests that fail on double premultiplication, gamma-encoded
  alpha, encoded-space source-over, and double display encode.
- [ ] Run `swift test --filter 'DocumentColorTests|DocumentColorPipelineTests|DepositionStampInstanceTests|DepositionShaderSourceTests'`.
- [ ] Commit as `feat(color): define linear paint contract`.

### Task 2: Build The Sparse Tile And Residency Core

**Files:**

- Create: `Sources/MetalRenderer/Raster/PaintTileDescriptor.swift`
- Create: `Sources/MetalRenderer/Raster/PaintTileStore.swift`
- Create: `Sources/MetalRenderer/Raster/PaintTileResidency.swift`
- Create: `Sources/MetalRenderer/Raster/TiledRasterSurface.swift`
- Create: `Tests/MetalRendererTests/PaintTileDescriptorTests.swift`
- Create: `Tests/MetalRendererTests/PaintTileResidencyTests.swift`
- Create: `Tests/MetalRendererTests/TiledRasterSurfaceTests.swift`

**Interfaces:**

- Produces `PaintTileCoordinate: Hashable, Comparable, Sendable`,
  `PaintTileDescriptor.side == 256`, `pixelFormat == .rgba16Float`, and
  `residentByteCount == 524_288`.
- Produces deterministic `PaintTileStore` lookup/transaction APIs that reserve
  all missing tiles before mutation and return immutable `PaintTileLease`
  values pinned to a surface generation.
- Produces `PaintTileResidency` with pin reasons `.active`, `.dirty`,
  `.historyBefore`, `.visible`, and `.inFlight`; deterministic LRU ordering is
  `(lastUseEpoch, layerID, y, x, tileID)`.
- Produces `TiledRasterSurface` with logical `pixelSize`, monotonically
  advancing revision, empty-without-texture representation, dirty tile
  enumeration, backing snapshots, and memory-pressure eviction.
- Does not route production rendering through this store yet.

- [ ] Write RED tests proving one dab on a 4096 × 4096 surface allocates only
  intersecting tiles, an empty surface allocates zero, and clipped edge tiles
  retain 256 × 256 physical storage.
- [ ] Add exact tile-coordinate/bounds tests for negative/out-of-range inputs,
  a dab crossing two tiles, and a dab/eraser crossing four corners including
  its one-pixel antialias halo.
- [ ] Add deterministic LRU, every pin reason, nested lease, stale generation,
  budget exhaustion, memory pressure, backing-snapshot, and rollback tests.
- [ ] Implement the required budget formula with overflow-checked arithmetic;
  tests cover zero/nonzero device recommendations and macOS/iOS fallbacks.
- [ ] Add allocation-failure injection at every multi-tile reserve index and
  assert identical store identity, tile set, bytes, LRU order, and revisions.
- [ ] Add an accelerated residency trace with flat resident bytes, bounded tile
  count, and no per-frame growth after warmup.
- [ ] Run `swift test --filter 'PaintTileDescriptorTests|PaintTileResidencyTests|TiledRasterSurfaceTests'`.
- [ ] Commit as `feat(raster): add bounded sparse tile store`.

### Task 3: Add Layer Ownership And Project Schema V4

**Files:**

- Create: `Sources/EditorCore/Layers/LayerStack.swift`
- Modify: `Sources/EditorCore/History/DocumentHistory.swift`
- Modify: `App/PatternSpike/EditorSessionController.swift`
- Modify: `App/Tests/EditorSessionControllerTests.swift`
- Modify: `Sources/PatternFile/PatternProjectMetadata.swift`
- Modify: `Sources/PatternFile/PatternProjectMetadataCodec.swift`
- Modify: `Sources/PatternFile/PatternProjectArchive.swift`
- Create: `Sources/PatternFile/PatternPaintTileCodec.swift`
- Create: `Tests/EditorCoreTests/LayerStackTests.swift`
- Modify: `Tests/EditorCoreTests/DocumentHistoryTests.swift`
- Modify: `Tests/PatternFileTests/PatternProjectMetadataCodecTests.swift`
- Create: `Tests/PatternFileTests/PatternPaintTileCodecTests.swift`
- Modify: `Tests/PatternFileTests/PatternProjectArchiveTests.swift`

**Interfaces:**

- Produces `LayerStack` with maximum eight stable UUID layers, one active ID,
  deterministic order, visibility, opacity, lock, rename, add/delete/reorder,
  and active fallback. It is platform-independent and stores no pixels.
- Extends `RasterHistoryCommand` and `TileResizeHistoryCommand` with the target
  `layerID`; undo/redo always addresses that ID. Adds layer-stack metadata
  commands and a layer-deletion command that retains the removed layer's tile
  revision so delete is undoable without losing pixels.
- Updates the controller—the sole history/lifecycle owner—to capture the
  pointer-down layer ID in renderer receipts, construct every layer-bound
  command, and pass the target ID back for undo/redo before finishing history
  navigation.
- Sets `PatternProjectFormat.currentSchemaVersion = 4`, retains decode support
  for versions 1, 2, and 3, and writes v4 only.
- Produces a v4 tiled surface manifest whose nonempty records contain stable
  tile ID, integer coordinate, clipped logical bounds, `rgba16Float`, little
  endian byte order, byte count, SHA-256 semantic hash, and raster revision.
- `PatternPaintTileCodec` validates finite half-float linear-premultiplied
  channels, `0 <= rgb <= alpha <= 1`, exact byte counts, unique IDs and
  coordinates, bounds, hashes, total decoded bytes, and maximum eight layers.

- [ ] Write LayerStack RED tests for all operations, maximum count, duplicate
  IDs, invalid opacity/name/order, active deletion fallback, and locked active
  mutation rejection.
- [ ] Write history RED tests proving reorder and active-layer changes do not
  retarget undo/redo. Prove delete/undo restores descriptor, order, active
  fallback, and exact tile revision; a genuinely missing target or retained
  deletion revision fails before mutation.
- [ ] Add controller RED tests for command creation, draw/erase/clear/resize
  completion, undo, redo, reorder, deleted-target atomic failure, and history
  cursor preservation when renderer restore fails.
- [ ] Write v4 wire RED tests for deterministic round trip and each malformed
  tile field. Include archive-wide decoded-byte limits and path-collision tests.
- [ ] Add v1 single-raster, v2/v3 layer, and v3 radial-page migration fixtures.
  Preserve every declared layer up to the eight-layer bound; never flatten or
  drop a valid old layer. Reject larger legacy stacks with a typed error.
- [ ] Keep PNG as encoded-sRGB import/export only. The v4 native tile payload is
  lossless little-endian RGBA16F and is not disguised as PNG.
- [ ] Run `swift test --filter 'LayerStackTests|DocumentHistoryTests|PatternProjectMetadataCodecTests|PatternPaintTileCodecTests|PatternProjectArchiveTests'`.
- [ ] Commit as `feat(document): add layered tile schema`.

### Task 4: Make Raster Revisions Tile-Transactional

**Files:**

- Create: `Sources/MetalRenderer/Raster/TiledRasterRevisionStore.swift`
- Modify: `Sources/MetalRenderer/Raster/RasterRevisionStore.swift`
- Modify: `Sources/PatternEngine/RasterRevisionReference.swift`
- Modify: `Sources/MetalRenderer/Raster/RendererRasterOperation.swift`
- Modify: `App/PatternSpike/EditorSessionController.swift`
- Modify: `App/Tests/EditorSessionControllerTests.swift`
- Create: `Tests/MetalRendererTests/TiledRasterRevisionStoreTests.swift`
- Modify: `Tests/MetalRendererTests/RasterRevisionStoreTests.swift`

**Interfaces:**

- Produces a tile-backed revision pair for one layer and an exact sorted tile
  coordinate set. Each before/after payload stores only clipped dirty tile
  bytes; empty-before is represented explicitly without a fake texture.
- Capture and restore operations are two-phase and generation-scoped. Publish
  occurs only after all tile blits complete. Release during in-flight work is
  deferred, and failure/cancel discards the entire provisional pair.
- Keeps the old full-surface store only as a private compatibility helper until
  Task 5 switches every production route; Task 6 then deletes it.

- [ ] Write RED tests for 1/2/4-tile capture/restore, empty-before, erase-to-
  empty, stale token, wrong layer/generation/format/coordinate, duplicate
  finalize, release while in flight, and byte-budget overflow.
- [ ] Add failure injection before each buffer allocation, each tile capture,
  command encoding, and completion. Assert no published partial pair and exact
  reusable store state.
- [ ] Prove one stroke spanning many dirty rectangles but the same tile captures
  that tile once, and that retained bytes equal aligned RGBA16F tile slices.
- [ ] Add reorder regression using the layer-bound history command from Task 3.
- [ ] Run `swift test --filter 'TiledRasterRevisionStoreTests|RasterRevisionStoreTests|DocumentHistoryTests'`.
- [ ] Commit as `refactor(history): snapshot sparse paint tiles`.

### Task 5: Prepare Off-Main Tiled Stroke Surfaces

**Files:**

- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokePrivateSurfaceEncoder.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/PredictionOverlay.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeFrameScheduler.swift`
- Create: `Sources/MetalRenderer/StrokeRuntime/StrokeTileSurfaceResources.swift`
- Create: `Tests/MetalRendererTests/StrokeTileSurfaceEncoderTests.swift`
- Modify: `Tests/MetalRendererTests/PredictionOverlayTests.swift`
- Modify: `Tests/MetalRendererTests/StrokeFrameSchedulerTests.swift`
- Modify: `Sources/BrushInputAllocationProbeHarness/main.swift`

**Interfaces:**

- Replaces the two full-canvas textures in `StrokeMetalSurfaceResources` with
  sparse authoritative and prediction tile sets from Task 2.
- `StrokePreparedSurfaceLease` carries immutable sorted dirty-tile bindings,
  generation/token/layer, clear flags, and actual/predicted counts. The main
  actor can read leased textures; the scheduler cannot mutate them until return.
- Projected record bounds are partitioned by tile before encoding. Per-tile
  scissor/coordinate uniforms preserve canonical positions and symmetry.
- This task prepares the new path behind a test-only installation seam; Task 6 is
  the single production switch.

- [ ] Write RED tests for authoritative append, shorter/longer prediction
  replacement, seam/corner partition, radial pages, tile allocation failure,
  command failure, late completion, stale lease return, cancel, and immediate
  reuse.
- [ ] Prove an untouched 4096 canvas has zero stroke tiles and a long diagonal
  owns only its intersecting tiles; no full-canvas texture may appear.
- [ ] Prove actual ordinals deposit once, prediction on/off produces identical
  committed candidate tile bytes, and prediction clears only its prior tiles.
- [ ] Extend the release allocation probe to the warmed tile-partition and lease
  paths; application-level input/prepare bookkeeping remains zero-allocation.
- [ ] Run `swift test --filter 'StrokeTileSurfaceEncoderTests|PredictionOverlayTests|StrokeFrameSchedulerTests|StageCAcceptanceLifecycleTests'` and
  `scripts/run-brush-input-allocation-probe.sh all`.
- [ ] Commit as `refactor(render): prepare sparse stroke surfaces`.

### Task 6: Atomically Switch Production Paint To Linear Sparse Tiles

**Files:**

- Modify: `Sources/MetalRenderer/CanonicalRaster.swift`
- Modify: `Sources/MetalRenderer/PersistentLiveTile.swift`
- Modify: `Sources/MetalRenderer/Brush/ReplayLiveTile.swift`
- Modify: `Sources/MetalRenderer/GridPipelineLibrary.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionPipelineLibrary.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionEncoder.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionStampInstance.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/GridRenderer+Harness.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Modify: `Sources/MetalRenderer/CommittedDocumentSnapshot.swift`
- Modify: `Sources/MetalRenderer/FlattenedSceneExporter.swift`
- Modify: `Sources/MetalRenderer/FiniteCanvasExporter.swift`
- Modify: `Sources/MetalRenderer/PeriodicRepeatExporter.swift`
- Modify: `Sources/MetalRenderer/PeriodicBakedRepeatExporter.swift`
- Modify: `App/PatternSpike/Canvas/MetalCanvas.swift`
- Modify: `App/PatternSpike/Panels/EditorTopBar.swift`
- Modify: `App/PatternSpike/Persistence/PatternProjectBridge.swift`
- Modify: `Tests/MetalRendererTests/DepositionRendererTests.swift`
- Modify: `Tests/MetalRendererTests/StageDBaselineContractTests.swift`
- Modify: `App/Tests/PatternProjectBridgeTests.swift`

**Interfaces:**

- `CanonicalRaster`, authoritative live, prediction, and scratch become
  `TiledRasterSurface` owners. No production paint-bearing `.bgra8Unorm`
  full-canvas texture remains.
- All deposition/erase/commit math targets `.rgba16Float`; encoded `InkColor`
  enters through Task 1's conversion API exactly once when instances are packed in
  this atomic switch. Display and PNG/interchange export perform the sole
  linear-to-encoded conversion.
- GridRenderer installs Task 5 leases, commits only dirty tiles through Task 4, and
  preserves the twelve lifecycle transitions. The legacy full-canvas paint
  path and test switch are deleted in this commit.

- [ ] Invert Task 0's structure test: fail on any production full-canvas paint
  allocation or encoded-BGRA8 deposition target. Permit BGRA8 only in drawable,
  capture/export/interchange, and diagnostics boundaries.
- [ ] Add CPU old-path versus tiled geometric differentials for opaque legacy
  scenes before deletion; compare coverage/support, not encoded-space low-flow
  color that Task 1 intentionally corrects.
- [ ] Add independent linear reference tests for translucent buildup, erase,
  transparent edges, preview/commit, display, and PNG. Require GPU error at
  most `2e-3` in linear half-float and encoded export error at most one channel
  value.
- [ ] Exercise begin/append/predict/estimate/finish/cancel/failure/next stroke,
  resize, clear, undo/redo, brush switch, plain/periodic/radial, and maximum
  symmetry through production entry points.
- [ ] Require one-dab 4096 allocation proportional to touched tiles, exact
  transaction rollback on each injected failure, bounded residency, and no
  growing per-event work in the accelerated 10-minute trace.
- [ ] Regenerate no golden from current output. Any changed approved fixture
  must cite its independent color vector and semantic reason in the task report.
- [ ] Run `swift test --filter 'DocumentColorPipelineTests|TiledRasterSurfaceTests|TiledRasterRevisionStoreTests|StrokeTileSurfaceEncoderTests|DepositionRendererTests|StageCAcceptance'`, the allocation probe, and Debug/Release macOS builds.
- [ ] Commit as `refactor(raster): activate linear sparse paint`.

### Task 7: Add The Linear Tile-Based Layer Compositor

**Files:**

- Create: `Sources/MetalRenderer/Compositing/LayerCompositor.swift`
- Create: `Sources/MetalRenderer/Compositing/LayerBlendPipeline.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `App/PatternSpike/EditorSessionController.swift`
- Modify: `App/PatternSpike/Persistence/PatternProjectBridge.swift`
- Modify: `Sources/PatternFile/PatternRasterExportCodec.swift`
- Create: `Tests/MetalRendererTests/LayerCompositorTests.swift`
- Modify: `App/Tests/EditorSessionControllerTests.swift`
- Modify: `Tests/PatternFileTests/PatternRasterExportCodecTests.swift`
- Modify: `Tests/EditorCoreTests/LayerStackTests.swift`

**Interfaces:**

- `LayerCompositor` consumes an immutable ordered visible-layer snapshot and
  dirty tile coordinate; it streams at most eight source tiles directly to the
  drawable/export target using linear premultiplied normal/multiply/screen.
  A `.visible` pin lasts for the in-flight tile composition batch, not the
  lifetime of the whole viewport, so an eight-layer viewport cannot pin the
  entire canvas above budget.
- GridRenderer captures the active layer ID at pointer-down. Paint/erase/clear
  reject a locked layer. Visibility/opacity/order changes invalidate only the
  affected display tiles and never rewrite layer pixels.
- Project capture/save/load uses schema v4 native tiles; v1/v2/v3 imports
  convert encoded BGRA8 once and produce a single transactionally installed
  v4 layer stack.

- [ ] Write independent CPU equations and GPU differential RED tests for all
  three blend modes, opacity 0/0.5/1, transparent edges, hidden layers, reordered
  layers, empty tiles, and eight-layer order. Require `2e-3` linear error.
- [ ] Add pure/app lifecycle tests for add/delete/reorder/visibility/opacity/
  lock/active changes and rejection during active drawing.
- [ ] Prove undo/redo restores the pointer-down layer after reorder/active
  changes and one stroke still creates exactly one command.
- [ ] Run a fully populated 2048 × 2048 eight-layer streaming composition and
  assert persistent plus in-flight paint bytes never exceed the configured
  budget; no whole-viewport composite cache is allowed.
- [ ] Add deterministic v4 save/load/save archive equality and v1/v2/v3 visual
  import parity within one encoded channel value.
- [ ] Run `swift test --filter 'LayerStackTests|LayerCompositorTests|EditorSessionControllerTests|PatternRasterExportCodecTests|PatternProjectBridgeTests'`.
- [ ] Commit as `feat(layers): compose bounded linear tiles`.

### Task 8: Stage D Acceptance Checkpoint

**Files:**

- Create: `Tests/MetalRendererTests/StageDAcceptanceTests.swift`
- Create: `Sources/StageDAcceptanceProbe/main.swift`
- Modify: `Package.swift`
- Create: `scripts/run-stage-d-acceptance.sh`
- Create: `docs/superpowers/reports/2026-08-04-stage-d-acceptance.md`
- Modify: `.superpowers/sdd/2026-08-01-brush-engine-corrective-program/progress.md`

**Acceptance matrix:**

- encoded/linear transfer vectors and CPU/GPU blend differentials;
- empty, one-tile, seam, four-corner, large, clear, erase, and rollback surfaces;
- begin, append, prediction, estimate, finish, cancel, every injected failure,
  rapid next stroke, resize, clear, undo/redo, brush/layer switch;
- plain, every periodic family, radial rotation/reflection, and maximum symmetry;
- schema-v1/v2/v3 imports and deterministic schema-v4 save/load;
- one through eight layers, all blend modes, order/visibility/opacity/lock;
- cold/warm, cache churn, memory pressure, 10-second, and accelerated 10-minute
  traces with allocation/residency/queue/frame telemetry.

- [ ] Add negative controls that independently break transfer direction,
  premultiplication, alpha handling, tile coordinate/halo, LRU/pinning, rollback,
  layer order, blend mode, display encode, export encode, and old full-canvas
  route detection. Prove every control fails its intended gate.
- [ ] Require Stage C semantic and scheduler suites unchanged, zero actual
  replay, zero warmed input-path application allocations, bounded queues,
  bounded tile bytes, flat first/last-decile CPU work, stable allocations, and
  failure reuse.
- [ ] Run the focused Stage D suite, all adjacent history/project/export suites,
  `scripts/run-stage-d-acceptance.sh`, Debug/Release macOS builds, and Debug
  iPadOS simulator build. Record physical checks as pending.
- [ ] Run the broad suite. It must contain no new issue outside the exact frozen
  27 Stage B records; if Stage D legitimately resolves a frozen record, require
  an independent reference and treat removal as an explicit acceptance change,
  never silently regenerate the baseline.
- [ ] Run a fresh independent review over the complete Stage D range. Resolve
  every Critical/Important finding and rerun affected gates.
- [ ] Record environment, exact commands, counts, hashes, CPU/GPU/frame/memory
  metrics, unresolved hardware evidence, and the Stage E boundary in the
  acceptance report.
- [ ] Commit as `test(raster): accept stage D surfaces`.

## Completion Boundary

Stage D is complete only when Task 8 is green and independently reviewed. At that
point low-flow buildup and blend equations match independent linear-light
references, every production paint surface is sparse RGBA16F, history and
schema-v4 persistence are tile-transactional, eight-layer composition respects
the residency budget, and the accepted Stage B/C lifecycle remains intact.
Manual brush quality and physical-device claims remain pending; Stage E may
start only after the Stage D acceptance report says `accepted`.
