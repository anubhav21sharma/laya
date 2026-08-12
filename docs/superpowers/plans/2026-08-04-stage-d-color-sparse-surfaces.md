# Stage D Color And Sparse Paint Surfaces Implementation Plan

**Execution status (2026-08-13):** Tasks 0 through 7 and the locally executable
portions of Task 8 are complete. Debug/Release/simulator builds, sustained
probes, direct production-app evidence, the hosted non-XCTest route, focused
regressions, and the exact `XCUIApplication` route gate are green. The user
approved macOS UI Automation; authorization persists and no sudo is needed.
Signed diagnostic runs now
exercise all 29 controls/shortcuts/persistence routes with one test passed and
zero failures, including a wrapper-style `build-for-testing` plus
`test-without-building` run. The gate exposed defects in transient-display
completion, imported layer-stack adoption, sandbox artifact paths, keyboard
focus, evidence routing, capture quiescence, and durable history accounting;
focused regressions cover the repairs, and the final review reported no
Critical, Important, or Minor findings. Exact pushed routes passed `1810dce` in
145.050 seconds and `e8756ee` in 158.444 seconds without another authorization
prompt. Two fresh clean-commit aggregate runs,
the strict native-wall threshold, and physical-device evidence remain pending.
An earlier clean-root aggregate attempt exposed and corrected a hardcoded
default SwiftPM build path in the CLI subprocess tests; isolated-scratch
subprocess verification is green. The next exact-commit attempt passed 656
focused tests, the complete 2,206-test/120-suite broad boundary, every product
build, both runtime probes, and both allocation probes. It stopped at final
package emission because the consumer required cache hits where the mutating
production compositor deliberately records one-shot misses, required exact
zero-work allocation equality where the producer allows a maximum, required
zero sampling totals where the producer enforces per-event caps, and split
spaced metric arrays incorrectly. Those contracts and their regression tests
are corrected, and the same full evidence now validates all 12 package rows.
The clean aggregate count remains zero until two complete runs of the resulting
pushed commit finish.

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

## Current-Only And Boundary-Validation Amendment

The project owner's 2026-08-10 direction removes all Laya-native pre-release
compatibility obligations. The binding design and removal sequence are
[`2026-08-10-native-current-only-validation-design.md`](../specs/2026-08-10-native-current-only-validation-design.md)
and
[`2026-08-10-native-current-only-cleanup.md`](2026-08-10-native-current-only-cleanup.md).
They supersede conflicting migration, alias, old-execution, compatibility-test,
and duplicated-validation requirements in this plan.

Stage D therefore accepts only native project schema 4, deletes schema-v1/v2/v3
migration at the Task 7 persistence boundary, deletes legacy renderer/harness
routes at the Task 6 authority cutover, and keeps external imports as separately
validated product features. Validation remains strong at untrusted bytes,
checked arithmetic/memory/Metal limits, transactional publication, and
GPU/resource ownership. Validated internal values are trusted rather than
rechecked in every layer.

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
- Native project schema 4 is the sole accepted project format. Schemas 1, 2, 3,
  and unknown future versions fail typed before payload allocation. No native
  migration adapter or compatibility alias is retained.
- In schema v4, a tiled surface's `pixelSize` is physical paint-storage
  geometry, not viewport/document size: plain and periodic use the compiled
  canonical raster size, radial uses `RadialSectorLayout.atlasPixelSize`.
- Checked-in raster updates require independent semantic/reference evidence;
  current-code output alone is not authority.
- Physical iPad/Pencil/Wacom/120 Hz evidence remains pending and cannot be
  fabricated. It does not block Stage D software acceptance.

## Lifecycle And Ownership Inventory

The following transitions are exhaustive and must have tests before production
wiring changes:

1. **Initialize/import:** create an empty one-layer tiled document, decode a
   current schema-4 native project, or explicitly import a supported external
   interchange format into a fully validated candidate. No empty tile allocates
   a texture and no native pre-release schema is migrated.
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
- Produces: frozen external encoded-BGRA8 import fixtures, a current schema-4
  archive baseline, typed old-version rejection fixtures, representative
  dry-scene semantic/canonical hashes, and an
  executable inventory of every full-canvas paint allocation that Task 6 must
  remove.

- [x] Add a source/runtime structure gate that inventories every baseline
  full-canvas paint allocation and encoded-BGRA deposition route, regardless
  of the concrete type or pixel format. Keep an exact BGRA8 allowlist for
  drawable, export/interchange, capture, and diagnostics. Task 5 proves its
  opt-in tiled seam without changing this production inventory; Task 6 removes
  the legacy routes and inverts the gate.
- [x] Add fixtures for empty, translucent, low-flow repeated buildup, erase,
  periodic seam, and radial pages. Record encoded input bytes and independent
  expected linear reference values; do not bless current blended pixels as
  color truth.
- [x] Freeze deterministic schema-4 decode/re-encode behavior and add early
  rejection fixtures for schemas 1, 2, 3, and an unknown future version. Delete
  migration fixtures once the current-only decoder lands.
- [x] Enumerate the twelve lifecycle transitions above in one table-driven test
  so every later task adds its new assertions to a named row rather than
  creating a second lifecycle owner.
- [x] Run `swift test --filter 'StageDBaselineContractTests|StageDProjectBaselineTests|StageCAcceptance'`.
- [x] Commit as `test(raster): freeze stage D contracts`.

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

- [x] Write pure RED vectors for black/white, both transfer breakpoints,
  transparent nonzero RGB, alpha 0/0.5/1, 50% source-over, destination-out,
  1/8/64 low-flow buildup, and encoded round trip. Require alpha to remain
  unchanged and RGB round-trip error at most `1 / 255`.
- [x] Write a Metal differential RED that renders typed half-float values and
  requires absolute linear-channel error at most `2e-3` for conversion,
  source-over, buildup, and erase.
- [x] Implement transfer and premultiplication once in `DocumentColor.swift`;
  shader helpers must use the same constants but not call UI/CoreGraphics APIs.
- [x] Audit `EditorTopBar`'s SwiftUI/AppKit/UIKit `Color` conversion and add an
  app test proving arbitrary source color spaces become bounded encoded sRGB,
  alpha is preserved, and the UI boundary performs no gamma decode or
  premultiplication. Add the new test file to the explicit Package source list.
- [x] Add a tested packing conversion API that Task 6 can call, but leave the
  active `DepositionStampInstance` path byte-identical in this task. Converting
  instance color before the paint/display surface switch would create an
  invalid mixed encoded/linear production state. A route-contract test pins
  UI encoded input -> exactly one Task 1 conversion -> linear-premultiplied
  shader payload; Task 6 activates that route atomically.
- [x] Add negative tests that fail on double premultiplication, gamma-encoded
  alpha, encoded-space source-over, and double display encode.
- [x] Run `swift test --filter 'DocumentColorTests|DocumentColorPipelineTests|DepositionStampInstanceTests|DepositionShaderSourceTests'`.
- [x] Commit as `feat(color): define linear paint contract`.

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

- [x] Write RED tests proving one dab on a 4096 × 4096 surface allocates only
  intersecting tiles, an empty surface allocates zero, and clipped edge tiles
  retain 256 × 256 physical storage.
- [x] Add exact tile-coordinate/bounds tests for negative/out-of-range inputs,
  a dab crossing two tiles, and a dab/eraser crossing four corners including
  its one-pixel antialias halo.
- [x] Add deterministic LRU, every pin reason, nested lease, stale generation,
  budget exhaustion, memory pressure, backing-snapshot, and rollback tests.
- [x] Implement the required budget formula with overflow-checked arithmetic;
  tests cover zero/nonzero device recommendations and macOS/iOS fallbacks.
- [x] Add allocation-failure injection at every multi-tile reserve index and
  assert identical store identity, tile set, bytes, LRU order, and revisions.
- [x] Add an accelerated residency trace with flat resident bytes, bounded tile
  count, and no per-frame growth after warmup.
- [x] Run `swift test --filter 'PaintTileDescriptorTests|PaintTileResidencyTests|TiledRasterSurfaceTests'`.
- [x] Commit as `feat(raster): add bounded sparse tile store`.

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
- Sets `PatternProjectFormat.currentSchemaVersion = 4`, writes and accepts only
  schema 4, and rejects every other native version before payload allocation.
- Produces a v4 tiled surface manifest whose nonempty records contain stable
  tile ID, integer coordinate, clipped logical bounds, `rgba16Float`, little
  endian byte order, byte count, SHA-256 semantic hash, and raster revision.
  `PatternPaintTileSurface.rasterRevision` is required even when its tile list
  is empty; `PatternProjectPaintTileSurface` carries the same value and every
  nonempty record must repeat that exact revision.
- Defines persisted tile UUIDs as archive identities, distinct from process-
  local `PaintTileID`. Task 7 must install a checked bijection during native
  import and return the same UUIDs during save/history restore; no UUID-to-
  `UInt64` truncation or regeneration is allowed.
- `PatternPaintTileCodec` validates finite half-float linear-premultiplied
  channels, `0 <= rgb <= alpha <= 1`, exact byte counts, unique IDs and
  coordinates, bounds, hashes, uniform surface revision, total decoded bytes,
  and maximum eight layers. It accepts physical dimensions through
  `RadialSectorLayout.maximumAtlasDimension == 16_384`, while project metadata
  separately requires the surface size to equal the compiled document's exact
  plain/periodic/radial storage geometry.

- [x] Write LayerStack RED tests for all operations, maximum count, duplicate
  IDs, invalid opacity/name/order, active deletion fallback, and locked active
  mutation rejection.
- [x] Write history RED tests proving reorder and active-layer changes do not
  retarget undo/redo. Prove delete/undo restores descriptor, order, active
  fallback, and exact tile revision; a genuinely missing target or retained
  deletion revision fails before mutation.
- [x] Add controller RED tests for command creation, draw/erase/clear/resize
  completion, undo, redo, reorder, deleted-target atomic failure, and history
  cursor preservation when renderer restore fails.
- [x] Write v4 wire RED tests for deterministic round trip and each malformed
  tile field. Include empty-surface revision, mixed tile revisions, physical-
  size/compiled-geometry mismatch, archive-wide decoded-byte limits, and path-
  collision tests.
- [x] Before Task 6 starts, correct the existing 4,096-only manifest bound and
  run save/decode/save fixtures at the maximum accepted plain/periodic size and
  a compiled radial layout whose atlas dimension exceeds 4,096 and is at most
  16,384. Require identical physical size, surface revision, tile UUIDs,
  payload bytes, and semantic hashes; malformed oversized or noncompiled
  dimensions fail before payload materialization.
- [x] Add typed early-rejection fixtures for native schemas 1, 2, 3, and an
  unknown future schema; delete successful migration fixtures and migration
  metadata. Current schema-4 archives still enforce the eight-layer bound.
- [x] Keep PNG as encoded-sRGB import/export only. The v4 native tile payload is
  lossless little-endian RGBA16F and is not disguised as PNG.
- [x] Run `swift test --filter 'LayerStackTests|DocumentHistoryTests|PatternProjectMetadataCodecTests|PatternPaintTileCodecTests|PatternProjectArchiveTests'`.
- [x] Commit as `feat(document): add layered tile schema`.

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
- Produces an opaque `TiledRasterRevisionInstallLease` from
  `beginInstall(for:)`. `encodeInstall(_:layerID:generation:targets:on:)`
  returns the existing operation token, `finalize(_:as:)` makes a successful
  lease consumable only after GPU completion, and
  `consumeInstall(_:layerID:generation:)` releases its retained-payload pin
  after the atomic destination swap. Failed finalization invalidates the lease.
  History release, pruning, memory pressure, a second install, and forged or
  wrong-layer leases cannot invalidate retained buffers during installation.
- Leaves the existing full-surface authority untouched only until the atomic
  Task 6 replacement is ready. It is not a supported compatibility mode; Task 6
  deletes it and its tests immediately after the new authority is proven.

- [x] Write RED tests for 1/2/4-tile capture/restore, empty-before, erase-to-
  empty, stale token, wrong layer/generation/format/coordinate, duplicate
  finalize, release while in flight, and byte-budget overflow.
- [x] Add failure injection before each buffer allocation, each tile capture,
  command encoding, and completion. Assert no published partial pair and exact
  reusable store state.
- [x] Add install-lease RED tests for release/prune while install is in flight,
  wrong token/layer/generation, duplicate finish, failed destination upload,
  and immediate retry. Retained bytes remain pinned through GPU completion and
  return to the exact pre-install accounting on every outcome.
- [x] Prove one stroke spanning many dirty rectangles but the same tile captures
  that tile once, and that retained bytes equal aligned RGBA16F tile slices.
- [x] Add reorder regression using the layer-bound history command from Task 3.
- [x] Run `swift test --filter 'TiledRasterRevisionStoreTests|RasterRevisionStoreTests|DocumentHistoryTests'`.
- [x] Commit as `refactor(history): snapshot sparse paint tiles`.

### Task 5: Prepare Off-Main Tiled Stroke Surfaces

**Files:**

- Modify: `Sources/MetalRenderer/Raster/PaintTileStore.swift`
- Modify: `Sources/MetalRenderer/Raster/TiledRasterSurface.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionPipelineLibrary.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokePrivateSurfaceEncoder.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/PredictionOverlay.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeFrameScheduler.swift`
- Create: `Sources/MetalRenderer/StrokeRuntime/StrokeTileSurfaceResources.swift`
- Modify: `Tests/MetalRendererTests/StageDBaselineContractTests.swift`
- Create: `Tests/MetalRendererTests/StrokeTileSurfaceEncoderTests.swift`
- Modify: `Tests/MetalRendererTests/PredictionOverlayTests.swift`
- Modify: `Tests/MetalRendererTests/StrokeFrameSchedulerTests.swift`
- Modify: `Sources/BrushInputAllocationProbeHarness/main.swift`

**Interfaces:**

- Adds a temporary old-versus-tiled test backend to
  `StrokeMetalResourceDescriptor`. Normal application construction continues to
  install the existing full-canvas BGRA8 backend; only tests and the allocation
  harness may select the tiled backend in this task. Task 6 remains the single
  production switch and deletes the old backend, selector, and compatibility-
  only tests.
- `StrokeTileSurfaceResources` owns sparse RGBA16F authoritative and prediction
  `TiledRasterSurface`s from Task 2, an immutable per-stroke layer/generation
  namespace, and preallocated partition/upload workspace. Its production
  initializer must borrow an injected document-owned `PaintTileStore` and
  namespace allocator; it cannot create or budget a store. A standalone-store
  convenience initializer is internal test-only. It receives a separately
  prepared RGBA16F deposition pipeline; the compiled brush's current BGRA8
  pipeline must never be bound to a tile.
- Extend `PaintTileStore`/`TiledRasterSurface` with a checked, already-sorted
  reserve/return path whose warmed bookkeeping does not allocate. The existing
  convenience API may continue to canonicalize arbitrary caller arrays.
- The encoder stores row-major bindings in fixed-capacity, append-only immutable
  chunks that are reused across frames. `StrokePreparedSurfaceLease` carries
  generation/token/layer, actual/predicted counts, the dirty/invalidation delta,
  and references to newly appended or replaced chunks; it never recopies the
  stroke's entire visible binding history. Task 6 may request viewport/export-
  batch leases from those chunks. Main may read referenced textures until exact
  acknowledgement; the scheduler may neither mutate nor evict them meanwhile.
- Projected support is clipped, partitioned, and deduplicated before encoding.
  A separately checked tile-record-reference budget accounts for one projected
  record intersecting multiple tiles; overflow fails typed before any store or
  GPU mutation. Do not size this workspace from projected-record count alone.
- Per-tile encoding preserves global canonical, clip, and grain coordinates by
  retaining the full-storage frame uniforms, translating the Metal viewport by
  the physical tile origin, and scissoring to the tile's valid extent. Radial
  records map `RadialPageCoordinate` through `RadialSectorLayout` to the
  resident atlas slot before selecting the physical tile; missing pages fail
  typed and atomically.
- Prediction replacement owns allocation-stable visible, planned, and
  prior-to-clear tile-coordinate lists. The planned footprint publishes only
  after GPU success; shorter, longer, overlapping, and empty replacements clear
  only the preceding prediction footprint and failure preserves the old one.
- Stroke namespaces and borrowed-store entries retire only after the final GPU
  completion plus exact ACK, cancel, or failure disposition has returned every
  published lease. Late ACK, cancel while Main owns a lease, and failure after
  chunk publication defer retirement; immediate next-stroke reuse gets a new
  namespace and cannot alias the retiring generation.
- Task 5 proves sparse geometry, lifecycle, and storage. Encoded-sRGB-to-linear
  conversion and application consumption of tiled leases remain Task 6 work.
- Correct Task 0's source-structure contract to inventory the legacy production
  allocations separately from the tiled test seam. The tiled seam must contain
  no full-canvas paint allocation, while the legacy inventory remains frozen
  until Task 6 removes and inverts it.

- [x] First write pure partition RED tests for empty, one-tile, seam, corner,
  deduplication, row-major ordering, long diagonal, clipped support, radial
  logical-page-to-atlas mapping, missing radial page, and checked tile-reference
  overflow. These tests must not require a Metal device.
- [x] Then write resource/encoder RED tests proving an untouched 4096 canvas
  owns zero tiles, one dab allocates only intersecting tiles, no full-canvas
  texture exists in the tiled backend, and an RGBA16F pipeline binding is used.
- [x] Add authoritative append and multi-frame tests proving each actual ordinal
  deposits once per required tile, prior immutable chunks remain reusable,
  per-frame binding-copy work is bounded by the changed chunks rather than total
  stroke tiles, and exact ACK returns every frame pin.
- [x] Add shorter, longer, overlapping, multi-page, and empty prediction
  replacement tests. Prediction enabled/disabled must produce identical
  authoritative candidate tile bytes, and replacement may clear only its prior
  prediction tiles.
- [x] Inject failure before tile allocation, partition/reference publication,
  command encoding, completion, and lease publication. Cover late completion,
  stale/wrong generation-token-layer ACK, cancel with Main ownership, deferred
  namespace/store retirement, and immediate next-stroke reuse; no partial
  footprint may publish and no borrowed-store entry may outlive final retirement.
- [x] At minimum and maximum radial ray counts, preflight projected-image count,
  tile-record references, page slots, binding chunks, upload bytes, and checked
  arithmetic before reserve. Maximum symmetry must either fit the declared
  capacities or fail typed without any store/GPU mutation.
- [x] Install the tiled backend only through a scheduler test seam and exercise
  begin, authoritative append, prediction, estimated replacement, finish,
  cancel, failure, radial pages, and immediate reuse. Run the unchanged Stage C
  lifecycle against the legacy production backend to prove no early switch.
- [x] Extend the release allocation probe with explicit warmed
  `surfaceTilePartition` and `surfaceTileLease` stages. Prewarm maximum bounded
  storage before arming; application input, partition, lease bookkeeping, ACK,
  cancel, and reuse remain zero-allocation. Report Metal driver allocation
  separately instead of hiding it in application counts.
- [x] Run `swift test --filter 'StageDBaselineContractTests|StrokeTileSurfaceEncoderTests|PredictionOverlayTests|StrokeFrameSchedulerTests|StageCAcceptanceLifecycleTests'` and
  `scripts/run-brush-input-allocation-probe.sh all`.
- [x] Commit as `refactor(render): prepare sparse stroke surfaces`.

### Task 6: Atomically Switch Production Paint To Linear Sparse Tiles

**Files:**

- Create: `Sources/MetalRenderer/Raster/DocumentPaintSurfaceStore.swift`
- Create: `Sources/MetalRenderer/Compositing/SparseTileSamplingPlan.swift`
- Create: `Sources/MetalRenderer/Compositing/SparseTileSamplingPipeline.swift`
- Delete: `Sources/MetalRenderer/Raster/RasterRevisionStore.swift`
- Delete: `Sources/MetalRenderer/PersistentLiveTile.swift`
- Delete: `Sources/MetalRenderer/Brush/ReplayLiveTile.swift`
- Modify: `Sources/MetalRenderer/CanonicalRaster.swift`
- Modify: `Sources/PatternEngine/RadialSectorLayout.swift`
- Modify: `Sources/CShaderTypes/include/ShaderTypes.h`
- Modify: `Sources/MetalRenderer/ShaderABI.swift`
- Modify: `Sources/MetalRenderer/GridPipelineLibrary.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionPipelineLibrary.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionEncoder.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionStampInstance.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/GridRenderer+Harness.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Modify: `Sources/MetalRenderer/Color/DocumentColorPipeline.swift`
- Modify: `Sources/MetalRenderer/Capture/PNGWriter.swift`
- Modify: `Sources/MetalRenderer/CommittedDocumentSnapshot.swift`
- Modify: `Sources/MetalRenderer/FlattenedSceneExporter.swift`
- Modify: `Sources/MetalRenderer/FiniteCanvasExporter.swift`
- Modify: `Sources/MetalRenderer/PeriodicRepeatExporter.swift`
- Modify: `Sources/MetalRenderer/PeriodicBakedRepeatExporter.swift`
- Modify: `App/PatternSpike/Canvas/MetalCanvas.swift`
- Modify: `App/PatternSpike/Panels/EditorTopBar.swift`
- Modify: `App/PatternSpike/Persistence/PatternProjectBridge.swift`
- Modify: `Sources/BrushInputAllocationProbeHarness/main.swift`
- Create: `Tests/MetalRendererTests/DocumentPaintSurfaceStoreTests.swift`
- Create: `Tests/MetalRendererTests/SparseTileSamplingPlanTests.swift`
- Create: `Tests/MetalRendererTests/SparseTileSamplingPipelineTests.swift`
- Modify: `Tests/MetalRendererTests/DepositionRendererTests.swift`
- Modify: `Tests/MetalRendererTests/DocumentColorPipelineTests.swift`
- Modify: `Tests/MetalRendererTests/CommittedDocumentSnapshotTests.swift`
- Modify: `Tests/MetalRendererTests/RendererResizeTests.swift`
- Modify: `Tests/MetalRendererTests/StageDBaselineContractTests.swift`
- Modify: `Tests/PatternEngineTests/RadialSectorLayoutTests.swift`
- Modify: `Tests/PatternEngineTests/SymmetryDescriptorCompilerTests.swift`
- Modify: `App/Tests/PatternProjectBridgeTests.swift`

**Interfaces:**

- `DocumentPaintSurfaceStore` is the document-owned residency owner. It holds
  exactly one `PaintTileStore`, a checked layer-ID-to-`TiledRasterSurface`
  registry, document geometry, and surface generation. It accepts any valid
  layer ID and contains no compatibility-layer special cases; Task 6 initially
  registers exactly one layer and Task 7 exercises the same API with up to
  eight. Canonical, authoritative, prediction, provisional, scratch, and later
  every layer draw from this one budget; no production convenience initializer
  may create a second store.
- Task 5 production stroke resources receive this exact shared store and a fresh
  document namespace from the registry. Canonical, transient, and history-
  install identities cannot collide because surface role and generation are
  part of the namespace; final ACK/cancel/failure retirement is the only path
  that releases transient namespace ownership.
- Document geometry distinguishes visible `documentPixelSize` from physical
  storage size. Plain storage uses the finite canvas, periodic storage uses the
  canonical repeat cell, and radial storage uses the checked compiled sector
  atlas dimensions/page map rather than the viewport size. Resize/mode import
  validates both dimensions and total possible tile/page-table bytes before it
  allocates a candidate registry.
- `SparseTileSamplingPlan` is an immutable generation/revision-scoped value with
  sorted CPU page-table entries, bounded texture binding batches, tile-origin
  and clipped-bounds uniforms, and visible leases. The builder runs page-in,
  residency reservation, page-table construction, and argument-buffer filling
  off main. Main only binds a completed plan and returns it after the final GPU
  completion that sampled it.
- The primary display/export sampler uses Tier-2 argument buffers where the
  device supports them. Its bounded fallback partitions bindings into ordered
  output-region batches and includes the one-tile input halo needed by every
  output region, so all four bilinear neighbors are bound in the same pass and
  each output pixel is written exactly once. It must not issue one fullscreen
  pass per tile. Plans are cached by document generation, canonical/transient
  content revision, viewport/export batch geometry, and binding-chunk revision.
  Lease tokens express lifetime only and never invalidate content. Dirty tile
  and chunk deltas update page-table ranges incrementally; unchanged chunks and
  page-table ranges remain byte-identical and are not rebuilt per input event.
- Every bilinear sample resolves all four integer neighbors independently.
  Missing pages/tiles are transparent; edge tiles honor clipped bounds;
  periodic coordinates wrap before lookup; radial logical coordinates resolve
  through the immutable sector page table to physical atlas tiles. CPU and GPU
  samplers use identical floor/neighbor semantics across tile, periodic, and
  radial seams.
- `DocumentColorPipeline` adds explicit encoded-premultiplied BGRA8 interchange
  APIs. Import unpremultiplies RGB in encoded space, decodes straight sRGB, then
  premultiplies in linear space. Transparent PNG export unpremultiplies linear
  RGB, encodes straight sRGB, premultiplies in encoded space, then packs BGRA8.
  Alpha zero has deterministic zero RGB. Automatic sRGB attachment conversion
  is allowed only for an opaque drawable, never as transparent PNG authority.
- The Task 1 stamp packer is the sole paint-ingress conversion. Deposition,
  buildup, erase, preview, canonical commit, clear, resize, restore, and native
  tile bytes stay linear-premultiplied `.rgba16Float`; display/interchange is
  encoded once at the boundary.
- GridRenderer consumes Task 5 immutable authoritative/prediction leases and
  commits their exact sorted coordinates through Task 4. A Task 4 install lease
  pins revision payload buffers until every candidate destination upload
  completes; only then does one atomic registry swap, one canonical surface
  revision advance, and `consumeInstall` publish. Failed finalization discards
  the entire candidate and preserves pixels, history, generation, and visible
  plans.
- After successful deposition, erase, clear, restore, resize, or import, every
  candidate tile whose valid logical texels are all transparent is removed from
  the surface and backing store before publication. Empty clear is a no-op and
  erase-to-empty releases residency after the last lease completes.
- Radial capacity uses RGBA16F's exact 8 bytes per physical pixel, checked as
  resident-page count × 256 × 256 × 8 plus separately checked page-table and
  binding bytes. `maximumAtlasDimension` remains 16,384, but the resident-byte
  budget may reject a geometrically valid atlas. Compilation and Task 5
  preflight minimum and maximum ray counts—including the maximum projected
  image count—before allocating or publishing tile/reference workspace.
- The old full-surface canonical allocations plus live/replay/revision types,
  legacy scheduler selector, and production-capable synchronous harness route
  are deleted in the same commit. BGRA8 remains only at the exact Task 0
  allowlisted boundaries.

- [x] Satisfy the Task 4 dependency before production edits: add RED
  install-lease tests and make retained revision payloads impossible to
  release/prune during destination
  upload, and rerun `TiledRasterRevisionStoreTests`. Task 6 may not compensate
  for a weaker revision-store contract with caller timing assumptions.
- [x] Satisfy the Task 3 wire dependency before production edits: land physical-
  geometry validation, 16,384-bounded radial manifests, manifest-level surface
  revisions, and maximum-layout deterministic round trips. Task 6 must not add
  a second interpretation of v4 `pixelSize`.
- [x] Write pure RED tests for the shared registry and physical geometry:
  arbitrary stable layer IDs, one common byte budget, no hidden independent
  stores, plain/periodic/radial storage dimensions, maximum radial layout,
  candidate swap, stale generation, 8-byte radial resident accounting, minimum/
  maximum-ray workspace preflight, and overflow before allocation.
- [x] Write CPU sparse-sampler RED tests for missing/clear tiles, clipped edges,
  four-neighbor bilinear interpolation, all four tile-corner combinations,
  negative and maximum periodic wrap, radial page/atlas resolution, immutable
  plan identity, deterministic batching, Tier-2/fallback equivalence, and
  cache invalidation only on a dependency change.
- [x] Add offscreen Metal differentials for the same sampling cases. Assert
  absolute linear-channel error at most `2e-3`, transparent missing entries,
  no seam discontinuity above that tolerance, and identical Tier-2/fallback
  output. Add behavioral pass-count and allocation evidence rejecting per-tile
  fullscreen passes; do not use a brittle source-text scanner.
- [x] Add encoded-premultiplied import/export vectors for alpha 0, 0.5, and 1,
  non-gray translucent edges, low channel values, row padding, and round trip.
  Require at most one encoded channel of PNG error and tests that fail for
  straight-alpha packing, encoded-space blend, double encode, or encoding alpha.
- [x] Add opaque old-path versus tiled geometry/support differentials as a
  temporary cutover oracle, then delete both the old renderer and those
  compatibility-only differentials in this task. Activate RGBA16F pipeline
  validation, the typed
  stamp packer, shared document store, sparse sampling plans, Task 5 leases,
  Task 4 install leases, and transactional clear/restore/resize/import as one
  production change.
- [x] Exercise the generic one-layer route through all twelve lifecycle rows in
  plain, every periodic family, radial rotation/mirror/mandala, maximum symmetry,
  resize crop/empty-fill, clear, undo/redo, and brush switch. Inject failure at
  reserve, page-in, plan build, command creation/encoding/completion, install,
  prune, candidate swap, resize, and import; every failure must allow an
  immediate successful next stroke.
- [x] Invert Task 0: delete the legacy types/symbols, renderer-harness schemas
  1 through 5, deprecated factories, compatibility constructors,
  `compatibilityLayerID`, every full-canvas paint-bearing allocation in any
  format, and encoded-BGRA deposition. Accept only the current harness schema
  6. Replace transitional source-text scanners with structural access control,
  current-schema decode rejection, and behavioral allocation/route evidence;
  retain the exact BGRA8 boundary inventory plus runtime one-dab 4096
  touched-tile count/resident bytes. Update Task 0/report wording from Task 5
  to Task 6.
- [x] Consolidate validation at the Task 6 boundary. Construct trusted
  geometry, sampling, transaction, and ownership values only after checked
  arithmetic, Metal-limit, registry-generation, and resource-ownership
  validation. Downstream render/cache layers consume those types without
  repeating the same range and identity checks. Remove redundant test hooks,
  duplicate invariant tests, and source-shape gates once construction and
  terminal ownership make the invalid state unrepresentable.
- [x] Stream stable tiled revisions directly into display/export/interchange
  destinations without assembling a full RGBA16F source. Prove erase-to-empty
  pruning, bounded page-table/argument-buffer bytes, shared-budget pressure,
  viewport/batch-bounded pins, incremental page-table/chunk invalidation, and no
  total-stroke-sized per-event copy or plan rebuild in the accelerated 10-minute
  trace.
- [x] Run `swift test --filter 'PatternPaintTileCodecTests|StageDProjectBaselineTests|RadialSectorLayoutTests|SymmetryDescriptorCompilerTests|DocumentColorPipelineTests|DocumentPaintSurfaceStoreTests|SparseTileSamplingPlanTests|SparseTileSamplingPipelineTests|TiledRasterSurfaceTests|TiledRasterRevisionStoreTests|StrokeTileSurfaceEncoderTests|DepositionRendererTests|CommittedDocumentSnapshotTests|RendererResizeTests|StageCAcceptance'`,
  `scripts/run-brush-input-allocation-probe.sh all`, and Debug/Release macOS
  builds. No current-output golden may be regenerated; every approved fixture
  change cites an independent vector and semantic reason.
- [x] Commit as `refactor(raster): activate linear sparse paint`.

### Task 7: Add The Linear Tile-Based Layer Compositor

**Files:**

- Create: `Sources/MetalRenderer/Compositing/LayerCompositor.swift`
- Create: `Sources/MetalRenderer/Compositing/LayerBlendPipeline.swift`
- Create: `Sources/MetalRenderer/Raster/LayerSurfaceTransaction.swift`
- Create: `Sources/MetalRenderer/Raster/PersistedPaintTileIdentityMap.swift`
- Modify: `Sources/MetalRenderer/Compositing/SparseTileSamplingPlan.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintSurfaceStore.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/CommittedDocumentSnapshot.swift`
- Modify: `Sources/MetalRenderer/FlattenedSceneExporter.swift`
- Modify: `Sources/MetalRenderer/FiniteCanvasExporter.swift`
- Modify: `Sources/MetalRenderer/PeriodicRepeatExporter.swift`
- Modify: `Sources/MetalRenderer/PeriodicBakedRepeatExporter.swift`
- Modify: `App/PatternSpike/EditorSessionController.swift`
- Create: `App/PatternSpike/Panels/LayerPanel.swift`
- Modify: `App/PatternSpike/ContentView.swift`
- Modify: `App/PatternSpike/Panels/EditorTopBar.swift`
- Modify: `App/PatternSpike/Persistence/PatternProjectBridge.swift`
- Modify: `Sources/SafeArchive/SafeArchive.swift`
- Modify: `Sources/SafeArchive/SafeArchiveCodec.swift`
- Modify: `Sources/SafeArchive/SafeArchiveIO.swift`
- Modify: `Sources/PatternFile/PatternProjectArchive.swift`
- Modify: `Sources/PatternFile/PatternProjectPackageCodec.swift`
- Modify: `Sources/PatternFile/PatternPaintTileCodec.swift`
- Modify: `Sources/PatternFile/PatternRasterExportCodec.swift`
- Create: `Tests/MetalRendererTests/LayerCompositorTests.swift`
- Create: `Tests/MetalRendererTests/LayerSurfaceTransactionTests.swift`
- Create: `Tests/MetalRendererTests/PersistedPaintTileIdentityMapTests.swift`
- Modify: `App/Tests/EditorSessionControllerTests.swift`
- Modify: `App/Tests/PatternProjectBridgeTests.swift`
- Modify: `Tests/PatternFileTests/PatternProjectArchiveTests.swift`
- Modify: `Tests/PatternFileTests/PatternProjectPackageCodecTests.swift`
- Modify: `Tests/PatternFileTests/PatternPaintTileCodecTests.swift`
- Modify: `Tests/PatternFileTests/PatternRasterExportCodecTests.swift`
- Modify: `Tests/EditorCoreTests/LayerStackTests.swift`
- Modify: `Tests/SafeArchiveTests/SafeArchiveCodecTests.swift`
- Modify: `Tests/SafeArchiveTests/SafeArchiveIOTests.swift`

**Interfaces:**

Task 7 is implemented in eight bounded subphases rather than as
one integration commit: freeze Task 6 contracts; CPU reference plus immutable
composite plans; GPU compositor/shared display-export kernel; atomic layer
transactions plus production layer controls; persisted tile-ID bijection;
bounded SafeArchive provider/consumer primitives; v4 streaming persistence and
current-schema enforcement; then exporter integration and eight-layer
budget/failure traces. Each subphase receives focused RED/GREEN tests. One
end-to-end functional/performance checkpoint follows the meaningful vertical
slice, and the comprehensive adversarial/review gate remains at Task 8 rather
than being repeated after minor edits.

- Task 7 extends—not replaces—Task 6's generic registry and immutable sampling
  plan. `PreparedLayerCompositePlan` contains an immutable bottom-to-top visible
  layer snapshot and one sparse sampling plan per contributing layer. It pins
  only the bounded batch being encoded and releases all plans after GPU
  completion; it never creates a whole-viewport or full-layer composite cache.
- `LayerCompositor` applies opacity and linear-premultiplied normal, multiply,
  or screen in deterministic stack order. Display and every exporter call this
  same composition kernel/reference contract. Hidden/empty layers contribute
  transparent; visibility/order/opacity changes invalidate bindings/output,
  never rewrite layer tile bytes.
- `LayerSurfaceTransaction` prepares raster and metadata candidates together.
  Add creates an empty registered surface with zero textures; delete retains a
  stable tile revision before removing the surface; undo restores exact layer
  descriptor, order, tile IDs, payload revisions, and active fallback; redo
  removes them again. Resize/mode switch prepares all layer surfaces, radial
  page maps, and metadata before one registry/stack/history swap. Any storage,
  upload, metadata, or completion failure leaves both old raster and old stack
  installed with the history cursor unchanged.
- GridRenderer captures the active unlocked layer and registry generation at
  pointer-down. The stroke remains bound to that layer through completion;
  paint/erase/clear and all layer mutations reject locked, missing, stale, or
  active-drawing targets with typed errors.
- `PersistedPaintTileIdentityMap`, owned by `DocumentPaintSurfaceStore`, is the
  checked bijection between persisted tile UUIDs and process-local
  `PaintTileIdentity` values. New tiles receive one UUID
  when first published; eviction/page-in preserves it; native import binds the
  manifest UUID to the newly reserved runtime identity; history delete/restore
  snapshots and reinstalls the mapping transactionally. Duplicate UUID,
  coordinate disagreement, stale mapping, or regenerated identity fails before
  registry swap.
- Native v4 save snapshots one stable document generation and streams sorted
  nonempty RGBA16F tile entries directly to `PatternProjectArchive`; it never
  flattens to PNG or assembles a full canvas. The surface manifest always emits
  physical storage `pixelSize` and manifest-level raster revision, including an
  empty surface; every tile record repeats that revision. Save/load/save
  preserves layer IDs, persisted tile UUIDs, coordinates, clipped bounds,
  surface revision, byte order, payload bytes, and semantic hashes. Runtime
  `PaintTileID` and history-store namespaces are freshly allocated and are not
  serialized.
- Canonicalize ZIP entry order, timestamps, compression settings, and metadata
  under executable tests, then require unconditional save/load/save semantic
  and byte equality. Do not infer byte stability from semantic hashing.
- SafeArchive gains bounded `SafeArchiveEntryProvider` and
  `SafeArchiveEntryConsumer` chunk APIs. Project save provides manifest and tile
  entries lazily while holding one document snapshot lease from manifest freeze
  through archive fsync/atomic replacement; project load preflights the central
  directory and consumes one bounded entry/chunk at a time into validation and
  candidate upload. Neither direction constructs `[String: Data]` for all tile
  payloads, and every early error closes the provider/consumer and snapshot
  lease exactly once.
- Native v4 load validates the complete manifest, paths, counts, checked
  per-entry/aggregate sizes, exact compiled physical storage geometry, manifest/
  tile revision uniformity, persisted-ID bijection, hashes, and layer limits
  once before constructing a trusted current-project value or allocating a
  candidate shared store. It then bounded-reads/uploads one tile at a time,
  sets the candidate surface's persisted revision even when it is empty, and
  swaps only after every tile succeeds. Native schema 1, 2, 3, and unknown
  future schemas fail clearly before payload allocation; no migration adapter,
  alias, compatibility decoder, or migration fixture is retained. Downstream
  transaction and upload layers consume the trusted current-project value and
  do not repeat archive/manifest validation.
- PNG/interchange remains flattened encoded-premultiplied BGRA8. Transparent
  export first composites layers in linear premultiplied space and then uses
  Task 6's boundary packer exactly once; native project tiles never pass through
  PNG or a transfer conversion.

- [x] Write CPU/GPU RED differentials for normal/multiply/screen, opacity
  0/0.5/1, hidden and empty layers, translucent colored edges, reordered
  layers, one through eight layers, and missing sparse inputs. Require `2e-3`
  linear error, deterministic order, and identical Tier-2/fallback results.
- [x] Write transaction RED tests for add/delete/undo/redo/reorder/visibility/
  opacity/lock/active, deletion of active and nonactive layers, exact revision
  restoration, resize crop/empty-fill across all layers, radial layout changes,
  failure at every prepare/upload/swap seam, and rejection while drawing.
- [x] Route production paint to the pointer-down layer and prove brush/layer
  switching, clear, and undo/redo never retarget a command after reorder or
  active-layer change. One completed stroke still publishes exactly one
  history command; cancel/failure publishes none.
- [x] Implement streamed v4 capture/save/load and RED malformed-archive tests
  for duplicate IDs/coordinates/paths, reordered manifest entries, byte/hash/
  bounds/revision mismatch, excessive layers/entries/bytes, radial map mismatch,
  truncated payload, upload failure, and stale snapshot. Assert save/load/save
  semantic and byte equality with stable persisted tile UUIDs and surface
  revision, including empty surfaces and a maximum accepted radial atlas.
- [x] Add SafeArchive provider/consumer RED tests for bounded chunk size,
  declared-size mismatch, checksum failure, duplicate/unsafe path, aggregate
  overflow, provider/consumer throw at every chunk, atomic destination replace,
  snapshot mutation while saving, and exact lease closure. Peak payload memory
  must be measured and bounded by one tile plus fixed archive buffers, not
  inferred from chunked APIs or allowed to scale with archive size.
- [x] Add compact schema 1/2/3/future rejection fixtures proving typed failure
  before payload allocation or registry mutation, then delete native migration
  code and successful-migration fixtures. Keep external PNG and external brush
  import coverage separate from the native project codec.
- [x] Route display, finite, periodic repeat/baked repeat, flattened PNG, and
  native project capture through the correct shared snapshot. Compare each
  flattened export against an independent CPU layer/color reference and prove
  native bytes remain lossless linear RGBA16F.
- [x] Run fully populated and sparse 2048 × 2048 eight-layer display/export
  traces without requiring all roughly 512 MiB of raw RGBA16F layer content to
  be resident simultaneously. Persistent plus page-in plus in-flight
  composition bytes must remain
  within the checked shared/transient budgets; leases, queues, page tables, and
  binding batches return to their warm baseline after completion or failure.
- [x] Enumerate prepare, allocation, upload, metadata, registry swap, GPU
  completion, persistence provider/consumer, checksum, and atomic file-replace
  failure seams. Every injected failure proves unchanged pixels, metadata,
  history cursor, and generation; zero leaked leases/tokens; and immediate
  successful reuse.
- [x] Run `swift test --filter 'LayerStackTests|LayerCompositorTests|LayerSurfaceTransactionTests|PersistedPaintTileIdentityMapTests|EditorSessionControllerTests|SafeArchiveCodecTests|SafeArchiveIOTests|PatternPaintTileCodecTests|PatternProjectArchiveTests|PatternProjectPackageCodecTests|PatternRasterExportCodecTests|PatternProjectBridgeTests'`.
- [x] Commit as `feat(layers): compose bounded linear tiles`.

### Task 8: Stage D Acceptance Checkpoint

**Files:**

- Create: `Tests/MetalRendererTests/StageDAcceptanceTests.swift`
- Create: `Sources/StageDAcceptanceProbe/main.swift`
- Modify: `Package.swift`
- Create: `scripts/run-stage-d-acceptance.sh`
- Create: `App/PatternSpike/Harness/StageDAppRouteEvidence.swift`
- Create: `App/UITests/StageDAppRouteUITests.swift`
- Modify: `App/PatternSpike/Debug/DebugPerformanceHUD.swift`
- Modify: `App/PatternSpike/Debug/DebugPerformanceMonitor.swift`
- Modify: `App/PatternSpike/ContentView.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintSurfaceStore.swift`
- Modify: `Sources/MetalRenderer/Raster/PaintTileStore.swift`
- Modify: `Sources/MetalRenderer/Compositing/SparseTileSamplingPlan.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeRuntimeTelemetry.swift`
- Modify: `App/UITests/PatternSpikeMacUITests.swift`
- Modify: `App/Tests/ContentViewLifecycleTests.swift`
- Modify: `App/Tests/EditorSessionControllerTests.swift`
- Modify: `App/Tests/PatternProjectBridgeTests.swift`
- Modify: `Tests/MetalRendererTests/StageDBaselineContractTests.swift`
- Create: `docs/superpowers/reports/2026-08-04-stage-d-acceptance.md`
- Modify: `.superpowers/sdd/2026-08-01-brush-engine-corrective-program/progress.md`

**Exact acceptance harness matrix:**

| Harness group | Required production scenarios | Required evidence |
| --- | --- | --- |
| Color | alpha 0/0.5/1, translucent colored edge, 1/8/64 buildup, erase, normal/multiply/screen, opaque display, transparent PNG | independent CPU vectors, GPU differential `<= 2e-3`, encoded export error `<= 1/255`, negative controls |
| Sparse sampling | empty, one tile, two-tile seam, four-corner bilinear, clipped edge, 4096 one dab, erase-to-empty, cache churn, pressure | exact coordinates/bytes, CPU/GPU page-table parity, Tier-2/fallback parity, zero full-paint allocations |
| Stroke lifecycle | initialize/import, begin, append actual/coalesced, prediction, estimate replacement, prepare/submit/display, finish, cancel, every injected failure, rapid next stroke, clear, undo/redo, brush/layer switch | canonical hashes, one-shot ordinals, command count, token/lease return, cursor/generation, renderer reuse |
| Modes | plain; periodic grid, half-drop, brick, mirror-X, mirror-Y, mirror-XY, rotational, square-rotation, square-kaleidoscope, hexagons, rotation-3, rotation-6, kaleidoscope-60, kaleidoscope-30; radial rotation/mirror/mandala at minimum and maximum rays; resize crop/empty-fill | seam probes, logical-to-physical maps, stable hashes with prediction on/off, bounded radial storage |
| Layers | one/eight layers, sparse/full, all blend modes, order, visibility, opacity, lock, active fallback, add/delete/undo/redo/resize | CPU/GPU blend parity, exact target layer/revision identity, transactional rollback, shared budget |
| Persistence/export | schema-4 empty/periodic/radial/eight-layer, schema-1/2/3/future rejection, save/load/save, finite/repeat/baked/PNG | bounded streaming reads, pre-allocation typed rejection, stable IDs/revisions/hashes/bytes, independent flattened reference, one transfer conversion |
| Sustained runtime | cold/warm, 10-second wall trace, 36,000-sample no-sleep accelerated trace, allocation/residency pressure, injected failure/reuse | JSONL plus summary: input provenance, replay, queues, prepare/submit/GPU/present p95/p99, allocations, page tables/bindings/leases, resident/high-water bytes |
| App/UI routes | color selection, draw/erase/clear, size/brush/layer changes, mode/resize, undo/redo, save/open/export, tilde HUD, digit/letter/command shortcuts while canvas vs numeric fields own focus | Xcode-hosted `PatternSpikeMacUITests` `.xcresult` plus app-written route manifest prove real control/key delivery, focus ownership, production sparse route, disabled/rejected states, and matching state/pixels |

- [x] Implement `StageDAcceptanceProbe` as the manifest aggregator for package
  harness results, the Xcode-hosted macOS UI `.xcresult`, and the app-written
  production-route evidence manifest. Every row has a stable scenario ID,
  deterministic seed/input trace, expected semantic hash or independent numeric
  oracle, producer kind, and typed result. The shell script rejects missing/
  duplicate rows, an absent/failed required Xcode test identifier, skipped
  software evidence, nonfinite metrics, or any nonproduction backend.
- [x] Add mutation/negative controls at genuine boundaries that independently
  invert transfer
  direction, straight/premultiplied handling, alpha, bilinear neighbor/tile
  origin, periodic/radial lookup, LRU/pinning, install atomicity, empty pruning,
  layer order/blend, display/export encode, and archive identity. Require each
  control to fail exactly its named gate while the unmodified fixture passes.
  Prove obsolete native paths are absent through current-version rejection and
  production behavior rather than brittle source-text inventories.
- [x] Strengthen lifecycle/app coverage so every one of the twelve inventory
  rows runs through production GridRenderer plus EditorSessionController. Cover
  app commands for color, draw, erase, clear, brush/size/layer/mode/resize,
  undo/redo, save/open/export, text-field focus/keyboard shortcuts, failed
  operation recovery, and immediate next action. Assert visible state,
  canonical bytes, history cursor, layer stack, generation, and pending tokens.
- [x] Add production layer controls before claiming any layer UI route. Configure
  deterministic temporary open/save/export URLs at launch so automation never
  depends on a native file-dialog interaction, while still proving the real app
  command, persistence bridge, atomic replacement, and evidence route executed.
- [x] Run actual `XCUIApplication` controls in `StageDAppRouteUITests`: click
  draw/erase/clear, brush/size/layer/mode/resize, undo/redo, save/open/export;
  send tilde, digits, letters, Command-Z, and Command-Shift-Z first to canvas and
  then to focused numeric fields. Assert accessibility value/selection/enabled
  state, field text, unchanged tiling while a field owns digits, shortcut action
  after canvas refocus, HUD presence, and app-written canonical/layer/history/
  sparse-route evidence after each command. SwiftUI hosting/controller tests
  alone cannot satisfy this row.
- [x] Require zero production legacy synchronous-render calls, zero append-only
  actual replay, zero post-warm input/partition/lease application allocations,
  no dropped actual input, no GPU wait on input/main, all queues and lease/token
  counts at zero after quiescence, resident plus transient bytes within their
  configured budgets, and no per-event page-table rebuild or full-canvas source.
- [x] Audit validation and test infrastructure at acceptance: keep untrusted-
  input, checked-arithmetic/memory/Metal-limit, transactional-publication, and
  GPU/resource-ownership guards. Remove duplicate downstream validation,
  compatibility-only tests, source-text gates, and implausible-state hooks
  whose states are already excluded by trusted construction and access control.
- [x] Run two complementary sustained gates: the current production GPU/app
  harness, which advances ten logical minutes in roughly ten wall-clock
  seconds, and the existing no-sleep allocation/scheduler probe, which actually
  processes 36,000 accelerated samples. Neither is described as 36,000 physical
  presented frames. Both use existing Stage B
  thresholds: event-to-submit miss fraction `<= 1%`, early/late 400-frame
  `BenchmarkLongStrokeMetrics` limits, bounded queue high-water, stable warmed
  capacities/allocation counts, the production probe's last-decile-per-event
  bound `<= max(firstDecile * 2, firstDecile + 100_000 ns)`, and the separate
  scheduler trace bound `<= max(firstDecile * 4, firstDecile + 100 ms)`.
  Both flat-work gates must pass; neither substitutes for the other. Record CPU
  preparation, event-to-submit, GPU, presentation p95/p99,
  missed-frame fraction, page-in/cache counts, and resident/in-flight high-water;
  do not claim physical 120 Hz performance from this evidence.
- [ ] Run the focused color/surface/history/layer/persistence/export suite and
  every adjacent Stage B/C lifecycle, scheduler, semantic, allocation, and
  telemetry suite, then run `scripts/run-stage-d-acceptance.sh` twice from a
  clean build directory. Both runs must produce identical semantic hashes and
  no unexplained metric or resident-resource growth.
- [x] Run the Xcode-hosted app-route gate:

  ```bash
  STAGE_D_ACCEPTANCE_COMMIT="$(git rev-parse HEAD)" \
  xcodebuild test -project App/PatternSpike.xcodeproj \
    -scheme PatternSpikeMac -destination 'platform=macOS' \
    -only-testing:PatternSpikeMacUITests/StageDAppRouteUITests/testProductionControlsShortcutsAndPersistenceWriteEvidence \
    -resultBundlePath .build/StageDAppRoutes.xcresult
  ```

  Convert its test summary plus the app route manifest into the aggregator
  input and require every named UI scenario above to pass. Never treat a
  successful app build as UI route evidence. On 2026-08-12 the user approved
  the macOS UI Automation prompt and repeated exact tests executed the complete
  29-route sequence in 145–199 seconds with one test passed and zero failures;
  the definitive pre-commit final-source run passed in 156.435 seconds and the
  exact pushed implementation commits `1810dce` and `e8756ee` passed in
  145.050 and 158.444 seconds respectively.
  The controls, shortcuts, and persistence rows all passed with zero pending
  ownership; save wrote a nonempty schema-4 project and export wrote a valid
  PNG. Four post-fix manifests have identical projected semantic
  hashes and compared resource metrics despite variable raw macOS gesture
  sampling. The latest standalone result is bound to `e8756ee`; the two fresh
  clean-commit acceptance-script runs remain the final aggregate boundary.
- [x] Build `PatternSpikeMac` Debug and Release for `platform=macOS`, and build
  `PatternSpikePad` Debug and Release for `generic/platform=iOS Simulator`, all
  with `CODE_SIGNING_ALLOWED=NO`. Launch the macOS harness route and require a
  completed production JSONL segment; simulator build is compile evidence only.
- [x] Rerun the broad suite against the current reviewed inventory: exactly
  2,206 tests in 120 suites and zero issues. Independent review approved the
  explicit removal of the five resolved graphite/charcoal/chisel records; the
  tracked Stage D baseline is intentionally empty and must never be regenerated
  from current output. Validate the log with
  `scripts/verify-swift-testing-baseline.sh`; any issue or inventory change is
  an unreviewed regression. The final rerun passed 2,206/120 in 1,840.787
  seconds with zero issues, and the empty baseline verifier passed.
- [x] Run a fresh independent review over `ca5dff5..HEAD` against this plan and
  the parent corrective program. Resolve every Critical/Important finding,
  rerun the complete affected matrix plus broad/build gates, and require the
  final reviewer to report no unresolved Critical/Important issue.
- [x] Record commit range, OS/Xcode/Swift/GPU, exact commands and test counts,
  every scenario/result/hash, CPU/GPU/frame/queue/allocation/residency metrics,
  negative-control proof, broad baseline diff, review disposition, and physical
  iPad/Pencil/Wacom/120 Hz/thermal/memory evidence as pending in the acceptance
  report. The report alone may set Stage D to `accepted` and open Stage E.
- [x] Commit and push the Stage D capture/XCTest hardening after the
  Xcode-hosted app-route gate passes (`1810dce`).
- [x] Align final package validation with the runtime/allocation producers:
  accept deliberate one-shot cache misses as production activity, enforce the
  shared sampling per-event caps with overflow-safe total bounds, accept
  zero-work allocation below its declared maximum, and parse bracketed metric
  arrays fail-closed. The affected 81-test matrix and 12-row package emission
  pass on the captured exact-commit evidence.
- [ ] Run the corrected aggregate twice from independent fresh roots on the
  same pushed commit and compare the resulting manifests.
- [ ] Commit final Stage D acceptance only after the two clean aggregate runs
  and qualifying hardware/profile evidence pass, using
  `test(raster): accept stage D surfaces`.

## Completion Boundary

Stage D is complete only when Task 8 is green and independently reviewed. At that
point low-flow buildup and blend equations match independent linear-light
references, every production paint surface is sparse RGBA16F, history and
schema-v4 persistence are tile-transactional, eight-layer composition respects
the residency budget, and the accepted Stage B/C lifecycle remains intact.
Manual brush quality and physical-device claims remain pending; Stage E may
start only after the Stage D acceptance report says `accepted`.
