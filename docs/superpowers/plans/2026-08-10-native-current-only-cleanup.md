# Native Current-Only Cleanup Implementation Plan

**Execution status (2026-08-12):** Task 4 is complete and verified as part of
corrective Task 18. Tasks 1 through 3 and Task 5 remain open where their full
current-only or validation-consolidation boundaries are not yet satisfied;
this document does not infer completion from adjacent corrective work.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all Laya-native pre-release compatibility paths and consolidate validation at genuine trust, resource, publication, and ownership boundaries without weakening correctness.

**Architecture:** Each owning vertical slice first migrates every current producer to one trusted representation, then physically deletes the obsolete adapter and its compatibility-only tests. Untrusted external formats remain defensive import boundaries. Internal layers consume immutable validated values and unforgeable ownership capabilities instead of repeating guards.

**Tech Stack:** Swift 6, Swift Testing, Metal/MetalKit, PatternEngine, BrushFormat, PatternFile, SafeArchive, MetalRenderer, macOS 14+, iPadOS 18+.

## Global Constraints

- Execute directly on `main`; the user explicitly authorized this repository workflow.
- Preserve `.vscode/` and `brushes/procreate/1_FREE_Charcoal_Set.key`.
- Do not commit partial Task 6 renderer activation; its production switch remains one atomic commit.
- Native formats accept exactly their current schema/version. Old and future native versions fail typed before payload allocation or execution.
- Procreate and other approved external formats remain supported import features and convert directly into current native trusted types.
- Keep validation at untrusted bytes, checked arithmetic/memory/Metal limits, transactional publication, and GPU/resource ownership.
- Remove repeated internal validation only after construction or access control makes the invalid state impossible.
- Keep functional correctness, visual quality, performance, cancellation safety, data integrity, and leak-free ownership non-negotiable.
- Use focused red/green tests per implementation step, vertical-slice functional/performance gates, and comprehensive adversarial testing at stage acceptance.
- Retire brittle source-text gates after the code is physically removed or structurally inaccessible.

---

### Task 1: Make Stage D Renderer Cutover Current-Only

**Files:**
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokePrivateSurfaceEncoder.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeInputQueue.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift`
- Modify: `Sources/MetalRenderer/Compositing/SparseTileSamplingPlan.swift`
- Modify: `Sources/MetalRenderer/Raster/TiledRasterRevisionStore.swift`
- Modify: `Sources/MetalRenderer/Raster/PaintTileStore.swift`
- Modify: renderer harness scene/routing/benchmark files to accept schema 6 only.
- Delete: `Sources/MetalRenderer/CanonicalRaster.swift`
- Delete: `Sources/MetalRenderer/PersistentLiveTile.swift`
- Delete: `Sources/MetalRenderer/Brush/ReplayLiveTile.swift`
- Delete: `Sources/MetalRenderer/Raster/RasterRevisionStore.swift`
- Modify/Delete focused renderer compatibility tests and temporary source gates.

**Interfaces:**
- Consumes: accepted shared sparse document store, stable snapshot renderer, stroke transaction backend, and Task 6 cutover plan.
- Produces: one non-optional sparse `DocumentPaintRenderContext` as GridRenderer paint authority; no legacy backend selector or magic compatibility layer.

- [ ] Add failing behavioral tests proving GridRenderer has one generic initial layer ID, one shared store/context, and no alternate paint backend can be selected.
- [ ] Run the focused tests and confirm they fail because the legacy owner/selector remains reachable.
- [ ] Migrate every stroke, clear, resize, restore, import, history, display, capture, and export caller to the shared sparse context.
- [ ] Delete the full-canvas owners, legacy preparation resources, scheduler backing, compatibility replay counters, synchronous fallback, deprecated sparse factories, provisional `beginInstall`, generation-selecting namespace/capability factories, source-compatible payload-debt names, and magic compatibility-layer branches.
- [ ] Collapse renderer/harness decode to exact schema 6; remove schemas 1–5,
  old runners/scenes, conditional benchmark validation, and successful old-
  schema tests. Reject the version envelope before decoding the remaining body.
- [ ] Replace temporary source scanners with compile/access-control proof plus functional allocation, pixel, cancellation, terminal ownership, and immediate-reuse tests.
- [ ] Run the complete Task 6 vertical-slice matrix, Release builds, allocation/performance probes, and one scoped independent review.
- [ ] Commit only as part of the atomic Task 6 activation commit.

### Task 2: Make Native Project Persistence Schema-4-Only

**Files:**
- Modify: `Sources/PatternFile/PatternProjectMetadata.swift`
- Modify: `Sources/PatternFile/PatternProjectMetadataCodec.swift`
- Modify: `Sources/PatternFile/PatternProjectPackageCodec.swift`
- Modify: `Sources/MetalRenderer/CommittedDocumentSnapshot.swift`
- Modify: `App/PatternSpike/Persistence/PatternProjectBridge.swift`
- Modify: current-format PatternFile/App tests.
- Modify: `Sources/EditorCore/Layers/LayerStack.swift`
- Modify: current tiling/symmetry API call sites.
- Delete: native schema-v1/v2/v3 migration fixtures and compatibility-only tests.

**Interfaces:**
- Consumes: untrusted SafeArchive entries and current schema-4 project wire data.
- Produces: one validated current-project value and a transactional sparse document candidate; versions other than 4 throw `PatternProjectLoadError.unsupportedSchema(version)` before payload allocation.

- [ ] Add failing tests that schemas 1, 2, 3, and an unknown future version are rejected before layer/tile payload reads or Metal allocation.
- [ ] Add current schema-4 round-trip, malformed boundary, streaming budget, hash, geometry, and transactional publication tests.
- [ ] Remove `legacySchemaVersion`, prior-schema constants, `sourceSchemaVersion`, `wasMigrated`, legacy wire DTOs, lock/preset inference, native PNG migration, and compatibility-layer IDs.
- [ ] Remove the hard-coded compatibility layer UUID/default stack, deprecated
  tiling/symmetry aliases and convenience initializers, and restore guards that
  exist only for pre-release identities. Preserve loaded schema-4 layer UUIDs.
- [ ] Make current decode construct one validated immutable project value; remove repeated schema/metadata validation from downstream archive, bridge, and renderer layers.
- [ ] Keep SafeArchive path/count/size/checksum enforcement, checked tile budgets, Metal allocation limits, and atomic registry swap validation.
- [ ] Run the Task 7 persistence vertical slice, save/load/save byte/semantic checks for schema 4, fault/cancellation/resource cleanup, and scoped independent review.

### Task 3: Make Native Brush Definition And Packages Current-Only

**Scheduling:** Execute as corrective Task 14A after Stage D acceptance and
before Stage E Task 15. The exact four-slice brief is
`.superpowers/sdd/2026-08-01-brush-engine-corrective-program/task-14a-current-native-brush-cutover-brief.md`.

**Files:**
- Modify: `Sources/PatternEngine/BrushModel/BrushDefinition.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushProgram.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushProgramCompiler.swift`
- Modify: `Sources/PatternEngine/BrushDynamicsEngine.swift`
- Modify: `Sources/PatternEngine/BrushStrokeGenerator.swift`
- Modify: `Sources/PatternEngine/BrushTerminationEvaluator.swift`
- Modify: `Sources/PatternEngine/StrokeStabilizer.swift`
- Modify: `Sources/BrushFormat/BrushPackageManifest.swift`
- Modify: `Sources/BrushFormat/BrushPackage.swift`
- Modify: `Sources/BrushFormat/BrushContentHash.swift`
- Modify: built-in/professional definition producers, converter output, harnesses, and test factories.
- Modify: current editor brush catalogs and IDs.
- Delete: `Sources/PatternEngine/BrushModel/LegacyBrushRecipeAdapter.swift`
- Delete: native v1 fixtures and compatibility-only tests.

**Interfaces:**
- Consumes: current native schema-2 definitions/packages and validated foreign brush IR.
- Produces: current trusted `BrushDefinition`/compiled program only; old/future native versions fail with version-bearing diagnostics. External importers emit current definitions directly.

- [ ] Add failing tests that native definition/package schema 1 and unknown future versions fail before resource upload or compilation.
- [ ] Add explicit current-schema constructors and migrate all built-ins, professional candidates, Synthetic external mapper output, harnesses, allocation probes, and test factories.
- [ ] Remove manifest-v1 default/range support, v1 definition DTOs, omitted-field encoding, legacy hash writers/tags, `LegacyBrushRecipeAdapter`, and native `BrushRecipe` compatibility serialization once no current producer depends on them.
- [ ] Delete schema-v1 compiler, response, dynamics, taper, generator, stabilizer, coordinator, scheduler, and bounded-whole-stroke execution branches. Preserve current typed bounded correction, prediction, and estimated-input replacement.
- [ ] Remove retired catalog IDs/source aliases/deprecated initializers; retain current IDs and rename current semantics that are misleadingly called compatibility.
- [ ] Keep external Procreate/Synthetic parsers, fuzzing, provenance, source-setting keys, required-semantic diagnostics, and resource-capability checks. They must not call a native legacy adapter.
- [ ] Remove repeated package/definition/schema validation after trusted construction. Keep untrusted package bytes/resources/limits and compiler capability checks at their owners.
- [ ] Specifically remove repeated `BrushPackageValidator.validate` calls from
  archive encoding and content hashing after immutable package construction,
  and remove compiler/package schema rechecks after the trusted current
  definition type owns that invariant.
- [ ] Run current brush semantic/raster/performance gates, converter import tests, full Stage C lifecycle, and one scoped independent review before Stage E begins.

### Task 4: Hard-Cut Composite Native Brush Schema At Corrective Task 18

**Files:**
- Modify: Task 18 files in `docs/superpowers/plans/2026-08-01-brush-engine-corrective-program.md`.
- Modify: `Sources/BrushFormat/BrushPackage.swift`
- Modify: `Sources/BrushFormat/BrushPackageManifest.swift`
- Modify: current brush definition/package/hash tests.

**Interfaces:**
- Scheduling: execute this cleanup task as the amendment to corrective Task 18,
  only after corrective Tasks 15 through 17 establish mask-resource, truthful-
  cursor, and static-backend foundations. Its numbering here is organizational,
  not permission to run immediately after cleanup Task 3.
- Consumes: current-only definition-schema-2/package-manifest-schema-2 brush
  system from Task 3 plus the accepted Tasks 15–17 foundations.
- Produces: definition schema 3 as the sole accepted native definition version.
  Package-manifest schema 2 remains its sole accepted container version unless
  the manifest wire layout itself changes; `BrushPackage` requires its payload
  definition to be schema 3.

- [x] Write failing tests proving schema 3 represents one/two current components and schemas 1/2 are rejected without migration.
- [x] Move every in-tree native producer to schema 3 in the same slice.
- [x] Remove schema-2 decode/compile/hash branches instead of adding an adapter.
- [x] Keep manifest decoding at exact schema 2, continue rejecting manifest
  schema 1/future versions, and update package validation to require definition
  schema 3 without inventing a redundant package-manifest version.
- [x] Preserve foreign-import provenance while emitting schema-3 native values directly.
- [x] Run composite semantics, raster, resource, cancellation, performance, and package gates plus scoped independent review.

### Task 5: Consolidate Validation And Acceptance Gates

**Files:**
- Modify/Delete: `Tests/MetalRendererTests/StageDProductionSparseCutoverGateTests.swift`
- Modify/Delete: `Tests/MetalRendererTests/StageD2TransientDisplayGateTests.swift`
- Modify: transaction, deposition, sparse sampling, project, brush, and stage-acceptance tests.
- Modify: just-in-time plans for Stages E, F, and G.

**Interfaces:**
- Consumes: current-only native formats and sole-owner renderer/persistence/brush architectures.
- Produces: boundary-focused validation tests, meaningful vertical-slice functional/performance suites, and comprehensive stage acceptance without duplicated source-text policing.

- [ ] Inventory each validation/check/hook in files touched by the next stage and name the trust or ownership boundary it protects.
- [ ] Remove checks duplicated by a validated immutable type, private constructor, unforgeable capability, or single transaction owner; retain corruption, limit, publication, GPU, cancellation, and leak checks.
- [ ] Delete source-text gates once compilation/access control makes the old path impossible. Keep one temporary inventory only during a destructive cutover.
- [ ] Consolidate repeated invariant tests into one boundary proof plus consumer behavior and end-to-end functional/performance evidence.
- [ ] Remove fault hooks for impossible internal states; retain deterministic failures at realistic allocation, publication, GPU terminal, cancellation, and ownership seams.
- [ ] At each stage acceptance, run comprehensive adversarial, sustained performance, visual/canonical, cancellation, integrity, and leak-free ownership tests and require a fresh broad review.

## Completion Boundary

This cleanup is complete only when no production or test target supports an
obsolete Laya-native format, identifier alias, compatibility adapter, or old
renderer execution path; external imports still work; internal consumers use
trusted current types; and every remaining guard maps to a genuine trust,
resource, publication, or ownership risk.
