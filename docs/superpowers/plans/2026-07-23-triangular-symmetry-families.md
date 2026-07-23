# Triangular Symmetry Families Implementation Plan

**Goal:** Ship Compiled Symmetry Phase 3: seamless triangular-lattice
translation, rotation, and kaleidoscope presets, including the periodic
Kaleidoscope 30-degree proving case and metric-correct rectangular repeat
export.

**Governing specification:**
`docs/superpowers/specs/2026-07-23-compiled-periodic-radial-symmetry-design.md`

**Depends on:**
`docs/superpowers/milestones/06-square-symmetry-families.md`

## Phase Boundary

This plan implements:

- Hexagons: triangular-lattice translation with a hexagonal guide;
- Rotation 3 (`p3`);
- Rotation 6 (`p6`);
- Kaleidoscope 60 degrees (`p3m1` / `*333`);
- Kaleidoscope 30 degrees (`p6m` / `*632`);
- rectangular index-two supercell storage, display, and export;
- independent triangular oracle and real-Metal evidence.

It does not implement finite/radial documents, per-layer symmetry,
persistence migration, or the Phase 5 export-format matrix.

## Pinned Design Decisions

1. Stable preset identifiers append as:
   `hexagons = 9`, `rotation3 = 10`, `rotation6 = 11`,
   `kaleidoscope60 = 12`, and `kaleidoscope30 = 13`.
   Values `0...8` remain unchanged.
2. Triangular presets compile as `.triangular`. Production dispatches through
   a dedicated `TriangularSymmetryKernel`; unsupported families never fall
   back to the rectangular kernel or Grid.
3. `PeriodicSymmetryConfiguration.repeatSize.width` is triangular world
   spacing `s`. Width and height must contain the same positive finite value,
   matching the existing square-family one-spacing UI contract.
4. Orientation is normalized through the same `[-pi, pi)` cold-path rule as
   square families. The primitive basis is:

   ```text
   u = rotate(a) * (s, 0)
   v = rotate(a) * (s / 2, sqrt(3) * s / 2)
   ```

5. Canonical storage is the rectangular index-two supercell:

   ```text
   horizontal = u
   vertical = 2 * v - u
   ```

   It has world aspect `1:sqrt(3)` and contains the two primitive-lattice
   cosets `0` and `v`.
6. The raster metric maps this exact continuous supercell into the retained
   rectangular canonical raster. It may be anisotropic representation
   metadata; no brush or group operation scales in world space.
7. A compiled triangular image is one point-group operation paired with one
   of the two primitive cosets. Generic rectangular-supercell image counts
   are therefore:

   | Preset | Point group | Images |
   | --- | ---: | ---: |
   | Hexagons | 1 | 2 |
   | Rotation 3 | 3 | 6 |
   | Rotation 6 | 6 | 12 |
   | Kaleidoscope 60 degrees | 6 | 12 |
   | Kaleidoscope 30 degrees | 12 | 24 |

8. `CompiledGroupOperation` represents an exact rational turn
   (`step / order`) plus reflection. The quarter-turn initializer remains for
   source compatibility. Deduplication compares rational relative operations;
   it never compares approximate angles.
9. The triangular kernel transforms the conservative footprint through each
   compiled operation, enumerates intersected rectangular supercells, clips
   against each exact four-plane preimage, and maps the surviving fragment
   into half-open canonical storage. It does not discover group closure,
   allocate image tables, or run modulo branches per sample.
10. The rectangular supercell is partitioned into 24 deterministic
    `30-60-90` ownership triangles generated from the `p6m` fundamental
    triangle. Lower-order presets group those triangles under their smaller
    compiled image tables. Directed-edge ties use image ordinal order.
11. Stabilizers are pinned in normalized supercell coordinates:
    two six-fold, four additional three-fold, and six two-fold centres for
    `p6`/`p6m`; `p3`/`p3m1` expose the six corresponding three-fold centres.
    Dihedral presets mark mirror-intersection centres as dihedral.
12. The complete-stamp invariance contract remains authoritative. A
    homogeneous round dab may collapse at a fixed point; directional or
    textured material frames retain mathematically distinct orientations.
13. Display samples the committed rectangular supercell through the compiled
    inverse basis. Guides are descriptor-selected:
    hexagonal Voronoi edges, triangular rotation centres, three mirror
    directions for Kaleidoscope 60 degrees, and six mirror directions plus
    2/3/6-fold centres for Kaleidoscope 30 degrees.
14. Repeat export remains Metal-only. `density` continues to mean horizontal
    pixels per spacing, preserving the square API. A triangular export is
    `density x round(sqrt(3) * density)` square pixels. A derived dimension
    outside `64...4096` is rejected explicitly rather than clamped.
15. The independent oracle implements triangular axial coordinates, direct
    `C3`/`C6`/`D3`/`D6` operations, the two cosets, half-open rectangular
    folding, coverage, and material coordinates without consuming production
    images, ownership, display programs, projected fragments, or Metal data.
16. The archived Slice 4 matrix remains pinned to selectors `0...6`. Phase 2
    square evidence remains byte-identical. Phase 3 receives a separate
    positive/single-cause-negative matrix covering every new preset, with
    Kaleidoscope 30-degree fixed centres, mirrors, large footprints, and
    rectangular export as mandatory acceptance cases.
17. Work directly on `main`. Preserve the user-owned untracked `.vscode/`
    directory and stage only Phase 3 files.

## Task 1: Stable Selectors And Exact Operation Metadata

**Production:**

- `Sources/PatternEngine/TilingKind.swift`
- `Sources/PatternEngine/CompiledSymmetry.swift`
- `Sources/PatternEngine/SymmetryDescriptorCompiler.swift`

**Tests:**

- `Tests/PatternEngineTests/SymmetryDescriptorCompilerTests.swift`
- `Tests/PatternEngineTests/TilingStrategyTests.swift`

Steps:

- [ ] Append stable values `9...13` and update every exhaustive switch.
- [ ] Preserve explicit legacy-seven and square-only collections.
- [ ] Generalize operation metadata to exact rational turns.
- [ ] Compile the triangular basis, rectangular supercell metric, two cosets,
  group tables, ownership triangles, stabilizers, guides, and bounded cost.
- [ ] Prove closure modulo the supercell, inverses, determinants, lattice
  preservation, stable ordering, ownership coverage, and cardinalities.
- [ ] Reject non-finite, unequal-spacing, singular, over-image, and
  over-projection configurations before producing a descriptor.

Focused gate:

```bash
swift test --filter SymmetryDescriptorCompilerTests
swift test --filter TilingStrategyTests
```

## Task 2: Dedicated Triangular Projection Kernel

**Production:**

- `Sources/PatternEngine/TriangularSymmetryKernel.swift`
- `Sources/PatternEngine/TilingStrategy.swift`
- `Sources/PatternEngine/TilingProjection.swift`

**Tests:**

- `Tests/PatternEngineTests/TriangularSymmetryKernelTests.swift`
- `Tests/PatternEngineTests/TilingProjectionTests.swift`

Steps:

- [ ] Enumerate transformed supercell preimages at positive, negative, large,
  rotated, boundary, and multi-cell coordinates.
- [ ] Preserve exact brush-local coordinates and deterministic
  row/column/image ordering.
- [ ] Pin generic `2/6/12/12/24` cardinalities.
- [ ] Pin 2/3/6-fold and mirror-axis cardinalities for every complete-stamp
  invariance contract.
- [ ] Prove near-fixed subpixel points remain distinct and exact fixed points
  do not multiply opacity or eraser strength.
- [ ] Reject the complete dab on projected-instance overflow; never drop
  individual fragments.

Focused gate:

```bash
swift test --filter TriangularSymmetryKernelTests
swift test --filter TilingProjectionTests
```

## Task 3: Independent Triangular Oracle

**Production:**

- `Sources/PatternEngine/Verification/TilingCoverageOracle.swift`

**Tests:**

- `Tests/PatternEngineTests/TilingCoverageOracleTests.swift`

Steps:

- [ ] Implement direct axial lattice and point-group formulas.
- [ ] Cover asymmetric/reflected footprints, material coordinates, negative
  and large cells, all mirror edges, every stabilizer, and large footprints.
- [ ] Compare production fragments for holes, phantoms, canonical
  coordinates, and brush-local coordinates.
- [ ] Extend the source guard so production descriptor/image identifiers
  remain absent from the triangular oracle implementation.

Focused gate:

```bash
swift test --filter TilingCoverageOracleTests
```

## Task 4: Model, History, Inspector, And Shortcuts

**Production:**

- `Sources/EditorCore/**`
- `App/PatternSpike/EditorSessionController.swift`
- `App/PatternSpike/Panels/TilingInspector.swift`

**Tests:**

- `Tests/EditorCoreTests/**`
- `App/Tests/EditorSessionControllerTests.swift`
- `App/Tests/ContentViewLifecycleTests.swift`

Steps:

- [ ] Treat square and triangular presets as one-spacing/orientation
  configurations while retaining their exact preset identity.
- [ ] Keep configuration installation atomic and metadata-only.
- [ ] Preserve untouched spacing/orientation fields bit-exactly.
- [ ] Keep numeric fields isolated from editor shortcuts.
- [ ] Prove undo/redo, clear, tool changes, grid visibility, and resize remain
  available after selecting every new preset.

## Task 5: Metal Display, Guides, And Export

**Production:**

- `Sources/CShaderTypes/include/ShaderTypes.h`
- `Sources/MetalRenderer/ShaderABI.swift`
- `Sources/MetalRenderer/GridRenderer.swift`
- `Sources/MetalRenderer/Shaders.metal`
- `Sources/MetalRenderer/PeriodicRepeatExporter.swift`

**Tests:**

- `Tests/MetalRendererTests/ShaderABILayoutTests.swift`
- `Tests/MetalRendererTests/TranslationTilingShaderTests.swift`
- `Tests/MetalRendererTests/ReflectedRotationalShaderTests.swift`
- `Tests/MetalRendererTests/PeriodicRepeatExportTests.swift`
- `Tests/MetalRendererTests/RendererRasterOperationTests.swift`

Steps:

- [ ] Append preset and guide wires without moving existing ABI values.
- [ ] Display through the triangular family and compiled inverse basis.
- [ ] Draw hexagonal, triangular, mirror, and stabilizer guides.
- [ ] Extend draw/erase/live/commit/clear paths to all five presets.
- [ ] Export the metric-resolved rectangular supercell with wrapped bilinear
  sampling and derived-dimension validation.
- [ ] Compare export to an independent translated `3 x 3` sampler and prove
  failures leave canonical bytes, configuration, history-facing state, and
  viewport unchanged.

## Task 6: Harness And Real-Metal Evidence

**Production:**

- `Sources/MetalRenderer/Capture/**`
- `App/PatternSpike/Harness/Scenes/*.json`

**Tests:**

- `Tests/MetalRendererTests/HarnessSceneTests.swift`

Steps:

- [ ] Add schema-compatible Phase 3 programs and typed metrics.
- [ ] Add positive/single-cause-negative pairs for all five presets.
- [ ] Require independent oracle metrics for every generic triangular scene.
- [ ] Add Kaleidoscope 30-degree 2/3/6-fold, mirror, large-footprint, eraser,
  and export evidence.
- [ ] Generate deterministic Phase 3 PNG and metric manifests.
- [ ] Re-run all Phase 1/2 scenes and prove legacy and square output hashes
  remain byte-identical.

## Task 7: Completion Gate

- [ ] Run all Swift tests from a clean scratch path.
- [ ] Regenerate the Xcode project.
- [ ] Build and analyze macOS and generic iPad simulator targets.
- [ ] Run the dedicated real-Metal Phase 3 matrix twice and compare hashes.
- [ ] Record CPU projection, GPU dab/display, instance traffic, resident
  memory, export time, and export peak memory per new preset.
- [ ] Run a fresh independent diff review and fix every correctness finding.
- [ ] Create
  `docs/superpowers/milestones/07-triangular-symmetry-families.md`.
- [ ] Update the milestone index only after every non-environment gate passes.
- [ ] Commit and push `main`, leaving `.vscode/` untouched.

Any correctness failure, oracle mismatch, dropped fragment, silent fallback,
legacy/square byte drift, or untyped partial mutation blocks Phase 3
completion.
