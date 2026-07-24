# Radial / Mandala Domain Implementation Plan

**Goal:** Ship Compiled Symmetry Phase 4: finite Plain Canvas and linked
Cartesian radial documents with cyclic `C_n`, dihedral `D_n`, immutable
post-edit geometry, page-bounded sector storage, finite display, and
full-canvas export.

**Governing specification:**
`docs/superpowers/specs/2026-07-23-compiled-periodic-radial-symmetry-design.md`

**Depends on:**
`docs/superpowers/milestones/07-triangular-symmetry-families.md`

## Phase Boundary

This plan implements:

- a finite document domain beside the existing periodic domain;
- Plain Canvas, Mirror, Rotation `C_n`, and Mandala/Kaleidoscope `D_n`;
- arbitrary integer rotational ray counts through the measured shipped
  maximum, initially capped at the target value `32`;
- quick ray presets `4`, `6`, `8`, `12`, and `16`;
- one linked Cartesian canonical sector;
- pre-edit centre/reference/group/ray setup and atomic first-edit locking;
- page-packed sector residency, finite display, finite flattened export;
- an independent radial oracle and real-Metal evidence.

It does not implement per-layer symmetry, mixed domains in one document,
post-lock radial geometry changes, retained strokes, polar storage, or the
Phase 5 persistence migration and format matrix.

## Pinned Design Decisions

1. Stable preset identifiers append as:
   `plainCanvas = 14`, `radialMirror = 15`,
   `radialRotation = 16`, and `radialMandala = 17`.
   Values `0...13` remain unchanged.
2. Public configuration is domain-typed. A document is either
   `.periodic(PeriodicSymmetryConfiguration)` or
   `.finite(FiniteSymmetryConfiguration)`. Finite configuration is Plain or
   radial; no invalid periodic/radial parameter mixture is representable.
3. `RadialSymmetryConfiguration.rayCount` is the rotational repeat count:
   Rotation `C_n` displays `n` sectors of angle `2π/n`; Mandala `D_n`
   displays `2n` alternating reflected sectors of angle `π/n`; Mirror is
   fixed `D_1`; Plain has no ray parameter.
4. Rotation and Mandala accept integer `n` in `2...shippedMaximumRayCount`.
   The initial capability ceiling is `32`; no input is silently clamped.
   Quick presets are UI conveniences that produce ordinary validated values.
5. Centre is a finite document-world point inside the half-open finite
   canvas. Reference angle is finite and normalized to `[-π, π)`.
6. The canonical sector is Cartesian. Folded world points retain unit scale
   and are translated into logical sector coordinates; no polar texture,
   angular resampling, or symmetry scaling is permitted.
7. `RadialSectorLayout` divides the logical sector bounding box into
   `256 x 256` pages. Only pages intersecting the radius-bounded canonical
   sector mask are assigned deterministic atlas slots. A compact integer page
   table maps signed logical page coordinates to packed atlas slots.
8. Production keeps one Metal atlas per canonical/live/replay surface, but
   the atlas contains only resident sector pages. Projected footprints are
   split at page boundaries into deterministic triangles or quadrilaterals,
   preserving the existing four-plane stamp ABI.
9. The compiler rejects non-finite geometry, an out-of-canvas centre,
   unsupported rays, atlas dimension overflow, resident-byte overflow,
   image overflow, or projected-instance overflow before installing a
   descriptor.
10. Plain Canvas uses identity finite geometry and the existing bounded
    rectangular raster layout. It never repeats outside the canvas.
11. Radial group images are compiled cold-path isometries around the locked
    centre. The radial kernel enumerates only those static images and resident
    pages intersecting a footprint; it never discovers group closure during
    input.
12. Display folds finite world coordinates into the logical canonical sector,
    resolves the page table, samples the packed atlas, and returns paper
    outside the finite canvas. Grid mode overlays the centre, every sector
    axis, and a distinct canonical-sector edge.
13. The first successful raster commit atomically installs both the new
    canonical bytes and `geometryLocked = true`. Begin, projection,
    allocation, encoding, or command failure leaves bytes and lock unchanged.
14. Once locked, group, ray count, centre, and reference angle are read-only.
    Undoing the first edit, redoing it, erasing all content, or Clear never
    unlocks geometry. A new geometry requires a new document.
15. Finite resize remains crop/expand without scaling. The centre and
    reference angle remain in document-world coordinates. The resize rebuilds
    the sector layout and copies a canonical orbit iff at least one generated
    image remains inside the new canvas. Resize never unlocks geometry.
16. Full finite export uses the same Metal fold/page-table sampler as display,
    at the document pixel dimensions. It supports transparency, makes no
    repeat claim, and cannot mutate pixels, history, viewport, or lock state.
17. The independent oracle implements direct polar-angle reduction and
    `C_n`/`D_n` operations from primitive configuration values. It does not
    consume production compiled images, ownership fragments, page transforms,
    projected instances, display programs, or Metal buffers.
18. Work directly on `main`. Preserve the user-owned untracked `.vscode/`
    directory and stage only Phase 4 files.

## Task 1: Domain Types, Descriptor, And Sector Layout

**Production:**

- `Sources/PatternEngine/TilingKind.swift`
- `Sources/PatternEngine/CompiledSymmetry.swift`
- `Sources/PatternEngine/SymmetryDescriptorCompiler.swift`
- `Sources/PatternEngine/RadialSectorLayout.swift`

**Tests:**

- `Tests/PatternEngineTests/SymmetryDescriptorCompilerTests.swift`
- `Tests/PatternEngineTests/RadialSectorLayoutTests.swift`

Steps:

- [x] Append preset wires `14...17` without changing prior values.
- [x] Add typed document, finite, and radial configurations.
- [x] Compile exact `C_n`/`D_n` images, sector ownership, stabilizers,
  display parameters, raster metric, and finite export capability.
- [x] Compute a deterministic sparse-page layout and packed atlas.
- [x] Prove generic orbit cardinality, determinants, inverse operations,
  sector coverage, stable page ordering, and resident-cost accounting.
- [x] Prove every invalid or over-budget configuration fails explicitly.

## Task 2: Dedicated Radial Projection Kernel

**Production:**

- `Sources/PatternEngine/RadialSymmetryKernel.swift`
- `Sources/PatternEngine/TilingStrategy.swift`
- `Sources/PatternEngine/TilingProjection.swift`

**Tests:**

- `Tests/PatternEngineTests/RadialSymmetryKernelTests.swift`
- `Tests/PatternEngineTests/TilingProjectionTests.swift`

Steps:

- [x] Implement finite clipping and direct display fold.
- [x] Split sector/page intersections into four-plane fragments.
- [x] Cover ray counts `2`, `3`, `4`, `5`, `7`, quick presets, and `32`.
- [x] Cover centre, axes, off-centre geometry, negative viewport bounds, and
  a footprint crossing the centre and many sectors.
- [x] Preserve brush-local material coordinates through reflection.
- [x] Reject complete work on instance overflow; never drop fragments.

## Task 3: Independent Radial Oracle

**Production:**

- `Sources/PatternEngine/Verification/RadialCoverageOracle.swift`

**Tests:**

- `Tests/PatternEngineTests/RadialCoverageOracleTests.swift`

Steps:

- [x] Implement direct finite identity, mirror, cyclic, and dihedral folds.
- [x] Compare production coverage, folds, canonical coordinates, orientation,
  and fixed-point cardinality across the required ray matrix.
- [x] Add a source guard that forbids production descriptor/page/image types.

## Task 4: Renderer, Page Table, Display, And Export

**Production:**

- `Sources/CShaderTypes/include/ShaderTypes.h`
- `Sources/MetalRenderer/ShaderABI.swift`
- `Sources/MetalRenderer/GridPipelineLibrary.swift`
- `Sources/MetalRenderer/GridRenderer.swift`
- `Sources/MetalRenderer/Shaders.metal`
- `Sources/MetalRenderer/FiniteCanvasExporter.swift`

**Tests:**

- `Tests/MetalRendererTests/ShaderABILayoutTests.swift`
- `Tests/MetalRendererTests/RadialShaderTests.swift`
- `Tests/MetalRendererTests/FiniteCanvasExportTests.swift`
- `Tests/MetalRendererTests/RendererRasterOperationTests.swift`

Steps:

- [x] Append radial preset/guide wires and a dedicated radial uniform ABI.
- [x] Allocate canonical/live/replay packed atlases plus immutable page table.
- [x] Render draw, erase, live, commit, clear, undo, and redo through the
  radial projector.
- [x] Sample finite radial display without periodic wrap or fallback.
- [x] Export a flattened finite canvas with the production Metal sampler.
- [x] Prove failures preserve canonical bytes, geometry lock, and state.

## Task 5: Lock Transaction, Model, And UI

**Production:**

- `Sources/EditorCore/**`
- `App/PatternSpike/EditorSessionController.swift`
- `App/PatternSpike/ContentView.swift`
- `App/PatternSpike/Panels/TilingInspector.swift`

**Tests:**

- `Tests/EditorCoreTests/**`
- `App/Tests/EditorSessionControllerTests.swift`
- `App/Tests/ContentViewLifecycleTests.swift`

Steps:

- [x] Add Seamless Pattern versus Radial/Mandala domain creation state.
- [x] Expose Plain, Mirror, Rotation, Mandala, arbitrary rays, quick presets,
  centre, reference angle, grid, and visible lock state.
- [x] Lock only on successful first raster commit.
- [x] Keep locked controls visible and disabled, not silently ignored.
- [x] Preserve numeric-field shortcut isolation and existing controls.
- [x] Prove failed first edit, undo/redo, Clear, eraser, and grid behavior.

## Task 6: Harness And Real-Metal Evidence

**Production:**

- `Sources/MetalRenderer/Capture/**`
- `App/PatternSpike/Harness/Scenes/*.json`

**Tests:**

- `Tests/MetalRendererTests/HarnessSceneTests.swift`

Steps:

- [x] Add positive/single-cause-negative finite/radial scenes.
- [x] Require oracle metrics for generic, axis, centre, reflected, off-centre,
  large-footprint, erase, lock, and export cases.
- [x] Run the required ray matrix including the measured shipped maximum.
- [x] Re-run legacy, square, and triangular evidence and prove byte parity.

## Task 7: Completion Gate

- [x] Run all Swift tests from a clean scratch path.
- [x] Regenerate the Xcode project.
- [x] Build and analyze macOS and generic iPad simulator targets.
- [x] Run the dedicated real-Metal matrix twice and compare hashes.
- [x] Record paravirtual CPU projection, GPU commit, projected-instance
  traffic, resident page bytes, and export time by radial case and ray count.
- [ ] Capture physical Apple-GPU display timing and peak memory
  (environment-only acceptance; not a Phase 4 correctness blocker).
- [x] Run a fresh independent diff review and fix every correctness finding.
- [x] Create
  `docs/superpowers/milestones/08-radial-mandala-domain.md`.
- [x] Update the milestone index only after every non-environment gate passes.
- [x] Commit and push `main`, leaving `.vscode/` untouched.

Any lock atomicity failure, linked-sector divergence, oracle mismatch,
dropped page/fragment, finite-canvas repeat, silent fallback, prior-family
drift, or untyped partial mutation blocks Phase 4 completion.
