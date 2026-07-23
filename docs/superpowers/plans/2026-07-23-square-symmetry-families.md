# Square Symmetry Families Implementation Plan

**Goal:** Ship the first new compiled-symmetry family: seamless `p4` Square
Rotation and `p4m` Square Kaleidoscope, including reversible square repeat
geometry, fixed-point-safe projection, production Metal display and guides,
minimum repeat export, UI controls, and independent evidence.

**Governing spec:**
`docs/superpowers/specs/2026-07-23-compiled-periodic-radial-symmetry-design.md`

**Depends on:**
`docs/superpowers/plans/2026-07-23-compiled-symmetry-foundation.md`

## Phase Boundary

This plan implements delivery-sequence Phase 2 from the governing spec:

- `p4` Square Rotation;
- `p4m` Square Kaleidoscope;
- four-fold stabilizers and square mirror-triangle ownership;
- square repeat export and UI presets.

It does not implement triangular/hexagonal presets, Kaleidoscope 30 degrees,
finite/radial documents, per-layer symmetry, or persistence migration. Those
remain Phases 3 through 5.

## Pinned Design Decisions

1. Preset wire values append as `squareRotation = 7` and
   `squareKaleidoscope = 8`. Values `0...6` remain byte-compatible.
2. Square presets use the existing `.rectangular` kernel family because their
   translation supercell is square. No square family ABI value is added.
3. A periodic document owns `PeriodicSymmetryConfiguration` separately from
   canonical `PixelSize`. It contains the preset, world repeat size, and
   orientation. Raster resize remains crop/expand with no scaling and does not
   silently change repeat geometry.
4. Compatibility construction remains source-compatible. Legacy presets get
   a zero-angle repeat matching the canonical raster. Square presets get a
   zero-angle square whose side is the smaller canonical dimension, so a
   rectangular raster still has one deterministic metric-backed default.
5. Square compilation requires equal finite repeat extents, but the retained
   canonical raster may be rectangular. `RasterMetric2D` maps the square world
   supercell into that raster without turning scaling into a group operation.
6. Square lattice orientation is normalized deterministically on the cold
   compile path. Input, projection, and rendering consume the compiled basis
   and inverse; they never calculate it per dab.
7. The retained periodic raster remains one complete rectangular repeat.
   The four or eight generated copies are committed pixels, so changing a
   periodic preset remains a metadata-only reinterpretation.
8. Orientation uses radians normalized to `[-pi, pi)`, with equivalent full
   turns canonicalized to positive zero. The oriented square basis is
   `u = s(cos(a), sin(a))`, `v = s(-sin(a), cos(a))`.
9. `p4` rotates counter-clockwise about the supercell centre and compiles
   identity, `90`, `180`, then `270` degrees. In normalized cell coordinates,
   the transforms are `(x,y)`, `(1-y,x)`, `(1-x,1-y)`, `(y,1-x)`.
10. `p4m` appends the seed reflection `(x,1-y)` and its `90`, `180`, and `270`
   degree rotations. Its ownership description contains eight `45-45-90`
   triangles covering the square exactly once.
11. Fixed-point deduplication compares the complete evaluated stamp contract.
    Identity-only, half-turn, arbitrary-rotation, reflection-only, and
    rotation-plus-reflection invariance remain distinct. A relative operation
    may collapse only when its determinant and angle belong to the declared
    contract.
12. `TilingImage` carries an exact convex cell domain in addition to its AABB.
    Projection clips to the cell domain; the existing four-plane Metal
    instance ABI remains sufficient. Fundamental ownership triangles are a
    separate descriptor payload: their directed edge/vertex owner breaks ties
    between coincident group images and prevents duplicate guide/export
    boundaries. They do not replace the full-cell stamp clip.
13. The production CPU code projects geometry only. Metal remains the sole
    production raster renderer. The oracle continues to implement `p4` and
    `p4m` directly without consuming production descriptors.
14. Archived Slice 4 evidence stays pinned to the explicit legacy seven.
    Square presets receive a separate positive/single-cause-negative matrix.
15. Phase 2 repeat export is a bounded Metal render into a square target whose
    pixel side is the requested finite density rounded to an integer in
    `64...4096`. It uses the compiled metric and half-open sampler, has no CPU
    fallback, fails before mutation/allocation overflow, and verifies a `3 x
    3` repetition. Full format/UI/persistence export matrices remain Phase 5.
16. Work directly on `main`. Preserve the untracked `.vscode/` directory and
    stage only Phase 2 files.

## Baseline

Before edits:

```bash
git status --short --branch
swift test --no-parallel
```

Expected baseline on 2026-07-23: `504` tests in `10` suites pass. Capture the
legacy real-Metal PNG manifest before the first rendering change and prove it
is byte-identical after Phase 2.

## Task 1: Stable Selectors And Periodic Configuration

**Production files:**

- `Sources/PatternEngine/TilingKind.swift`
- `Sources/PatternEngine/CompiledSymmetry.swift`
- `Sources/PatternEngine/SymmetryDescriptorCompiler.swift`
- `Sources/PatternEngine/TilingStrategy.swift`

**Test files:**

- `Tests/PatternEngineTests/SymmetryDescriptorCompilerTests.swift`
- `Tests/PatternEngineTests/TilingStrategyTests.swift`

Steps:

- [ ] Split tests that intentionally pin the legacy seven from tests covering
  every current preset.
- [ ] Append stable preset values `7` and `8`.
- [ ] In the same atomic selector change, update every exhaustive production
  and test switch to either handle square behavior or use an explicit
  legacy-seven collection. No unknown or new preset may silently act as Grid.
- [ ] Add validated `PeriodicSymmetryConfiguration` with preset, repeat size,
  and orientation.
- [ ] Add a compiler entry accepting configuration plus canonical raster size;
  retain the old preset/tile-size compatibility entry.
- [ ] Add typed errors for invalid angle, non-square repeat geometry,
  singular basis, and bounded-cost rejection.
- [ ] Compile the pinned four/eight image tables, square raster metric, guide
  metadata, stabilizers, and ownership triangles.
- [ ] Prove group closure, inverse, determinant, lattice preservation, image
  order, triangle coverage, and exact fixed-point metadata.

Focused verification:

```bash
swift test --filter SymmetryDescriptorCompilerTests
```

`TilingStrategyTests` becomes a focused gate after Task 2; Task 1 still builds
the entire package so all exhaustive selector sites must compile.

## Task 2: General Lattice Projection And Stamp Equivalence

**Production files:**

- `Sources/PatternEngine/RectangularSymmetryKernel.swift`
- `Sources/PatternEngine/TilingStrategy.swift`
- `Sources/PatternEngine/TilingProjection.swift`
- `Sources/PatternEngine/StampFootprint.swift`
- `Sources/MetalRenderer/Brush/BrushMaterialState.swift`

**Test files:**

- `Tests/PatternEngineTests/RectangularSymmetryKernelParityTests.swift`
- `Tests/PatternEngineTests/TilingProjectionTests.swift`
- `Tests/MetalRendererTests/BrushMaterialStateTests.swift`

Steps:

- [ ] Enumerate cells through the compiled lattice inverse for positive,
  negative, rotated, and large coordinates.
- [ ] Compute each cell's exact parallelogram clip and deterministic
  row/column/ordinal order.
- [ ] Preserve every legacy fold, transform, clip, and error fixture exactly.
- [ ] Extend full-stamp invariance with distinct half-turn, arbitrary rotation,
  reflection-only, and rotation-plus-reflection contracts; deduplicate only
  relative operations licensed by the declared contract.
- [ ] Use fundamental-triangle directed ownership only to break exact
  coincident-image and guide-boundary ties. Continue clipping stamp support to
  the exact cell parallelogram.
- [ ] Pin generic, centre, mirror-axis, edge, and vertex cardinalities for
  oriented and invariant stamps.
- [ ] Prove repeat queries are bit-identical and no candidate is silently
  dropped.

Focused verification:

```bash
swift test --filter RectangularSymmetryKernelParityTests
swift test --filter TilingProjectionTests
swift test --filter BrushMaterialStateTests
```

## Task 3: Independent Square Oracle

**Production file:**

- `Sources/PatternEngine/Verification/TilingCoverageOracle.swift`

**Test file:**

- `Tests/PatternEngineTests/TilingCoverageOracleTests.swift`

Steps:

- [ ] Implement direct square lattice fold and direct `C4`/`D4` orbit math
  without importing compiled images, ownership, or projected instances.
- [ ] Cover asymmetric and reflected shapes, moving grain coordinates, all
  square axes, four-fold centres, negative cells, large coordinates, and
  multi-cell footprints.
- [ ] Compare production fragments with the independent oracle for holes,
  phantom copies, canonical coordinates, and brush-local coordinates.
- [ ] Retain an explicit source guard proving the oracle does not consume
  production descriptors.

Focused verification:

```bash
swift test --filter TilingCoverageOracleTests
```

## Task 4: Periodic Metadata Transactions

**Production files:**

- `Sources/EditorCore/Model/EditorModel.swift`
- `Sources/EditorCore/History/DocumentHistory.swift`
- `Sources/EditorCore/Transactions/EditorTransaction.swift`
- `App/PatternSpike/EditorSessionController.swift`
- `Sources/MetalRenderer/GridRenderer.swift`

**Test files:**

- `Tests/EditorCoreTests/EditorModelTests.swift`
- `Tests/EditorCoreTests/DocumentHistoryTests.swift`
- `Tests/EditorCoreTests/EditorTransactionTests.swift`
- `App/Tests/EditorSessionControllerTests.swift`
- affected renderer transaction and resize tests

Steps:

- [ ] Store the complete periodic configuration in the model and metadata
  history while retaining `tiling` as a computed compatibility view.
- [ ] Compile and validate a proposed configuration before renderer, model, or
  history state changes.
- [ ] Install successful changes only while idle as one zero-raster-cost undo
  step; failure leaves the prior descriptor active and adds no history.
- [ ] Keep canonical pixel resize independent of repeat geometry.
- [ ] Prove changing presets/configuration and returning restores rendering
  while preserving canonical bytes exactly.

Focused verification:

```bash
swift test --filter EditorModelTests
swift test --filter DocumentHistoryTests
swift test --filter EditorTransactionTests
swift test --filter EditorSessionControllerTests
```

## Task 5: Metal Display, Guides, And ABI

**Production files:**

- `Sources/CShaderTypes/include/ShaderTypes.h`
- `Sources/MetalRenderer/ShaderABI.swift`
- `Sources/MetalRenderer/GridRenderer.swift`
- `Sources/MetalRenderer/Shaders.metal`

**Test files:**

- `Tests/MetalRendererTests/ShaderABILayoutTests.swift`
- `Tests/MetalRendererTests/TranslationTilingShaderTests.swift`
- `Tests/MetalRendererTests/ReflectedRotationalShaderTests.swift`

Steps:

- [ ] Append square preset wires and compiled lattice/display parameters
  without renumbering any existing field or selector.
- [ ] Map square world coordinates through the compiled inverse basis and
  raster metric before canonical sampling.
- [ ] Render square cells and rotation centres for `p4`; add mirror diagonals
  and the `45-45-90` fundamental triangle for `p4m`.
- [ ] Keep unknown presets visibly invalid rather than falling back to Grid.
- [ ] Prove CPU/MSL positive folding agrees at negative epsilon seams.

Focused verification:

```bash
swift test --filter ShaderABILayoutTests
swift test --filter TranslationTilingShaderTests
swift test --filter ReflectedRotationalShaderTests
```

## Task 6: Square Inspector And Minimum Repeat Export

**Production files:**

- `App/PatternSpike/Panels/TilingInspector.swift`
- `App/PatternSpike/ContentView.swift`
- `Sources/MetalRenderer/PeriodicRepeatExporter.swift`
- `Sources/MetalRenderer/GridRenderer.swift`
- `Sources/MetalRenderer/Shaders.metal`

**Test files:**

- `App/Tests/ContentViewLifecycleTests.swift`
- `App/UITests/PatternSpikeMacUITests.swift`
- `Tests/MetalRendererTests/PeriodicRepeatExportTests.swift`

Steps:

- [ ] Label both presets and expose spacing/orientation controls only for
  square presets.
- [ ] Keep canvas pixel width/height explicitly separate from symmetry repeat
  controls.
- [ ] Ensure focused numeric entry is never interpreted as an editor shortcut.
- [ ] Show validation failures without installing partial state.
- [ ] Resolve a metric-correct, half-open square repeat through a bounded Metal
  render target at requested density; reject allocation/encoding failure with
  no CPU fallback.
- [ ] Validate translated seams and a byte-tiled `3 x 3` repetition.
- [ ] Prove export leaves canonical bytes, descriptor, history, and viewport
  unchanged.

Focused verification:

```bash
swift test --filter PeriodicRepeatExportTests
swift test --filter ContentViewLifecycleTests
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMacUITests \
  -destination 'platform=macOS' \
  test
```

## Task 7: Dedicated Real-Metal Square Evidence

**Production and fixture files:**

- `Sources/MetalRenderer/Capture/HarnessScene.swift`
- `Sources/MetalRenderer/Capture/HarnessRunner+Grid.swift`
- new Phase 2 square scene JSON files
- `Sources/MetalRenderer/Capture/SliceFourHarnessRunner.swift`

**Test files:**

- `Tests/MetalRendererTests/HarnessSceneTests.swift`
- new square evidence tests
- affected Slice 4 evidence tests

Steps:

- [ ] Pin Slice 4's archived brush/tiling matrix to the explicit legacy seven.
- [ ] Append an optional, versioned periodic-configuration object to the scene
  schema (repeat size and orientation); legacy scenes decode unchanged and
  invalid/singular/over-budget values fail before renderer allocation.
- [ ] Add positive and single-cause negative scenes for `p4` and `p4m`.
- [ ] Cover generic orbits, fixed centre, mirror axis, asymmetric orientation,
  draw, erase, live/commit equality, grid guides, and repeat seams.
- [ ] Require zero holes, zero phantom copies, no silent fallback, no discarded
  fragment, and at most one 8-bit channel value of live/commit delta.
- [ ] Save deterministic square artifact hashes separately from the legacy
  manifest.

## Task 8: Product Integration And Completion

- [ ] Run all Swift tests from a clean scratch path.
- [ ] Regenerate the Xcode project and build macOS and iPad simulator targets.
- [ ] Run static analysis for both targets.
- [ ] Run the dedicated real-Metal square matrix.
- [ ] Record projection, stamp, and display p50/p95, live instance traffic,
  resident raster bytes, export duration, and peak export allocation for each
  square preset. Treat unavailable physical-device timing as explicit
  non-blocking acceptance debt, not as fabricated evidence.
- [ ] Prove all legacy PNG hashes remain byte-identical.
- [ ] Perform a fresh subagent diff review; fix every correctness finding and
  rerun affected verification.
- [ ] Create
  `docs/superpowers/milestones/06-square-symmetry-families.md` with commands,
  measured results, deferred physical-device evidence, and remaining risks.
- [ ] Update the milestone index and mark Phase 2 complete only when all exit
  criteria below pass.
- [ ] Commit a small conventional series, then push `main`.

## Exit Criteria

- Both new preset IDs compile through the one descriptor architecture.
- `p4` produces four generic oriented images and correct four-fold stabilizers.
- `p4m` produces eight generic oriented images and eight owned mirror
  triangles.
- Complete-stamp invariance prevents opacity/eraser multiplication at fixed
  points without removing intentional orientations.
- CPU oracle and production projection report no holes or phantom copies.
- Production Metal agrees with the oracle and live equals commit.
- Square guides and numeric controls work without disabling drawing, clear,
  undo/redo, eraser, or preset changes.
- Repeat export tiles seamlessly and does not mutate the document.
- Canonical resize remains crop/expand and does not alter repeat geometry.
- The original seven selectors, fixtures, shader output, and 123 legacy PNG
  hashes remain byte-identical.
- Full tests, macOS/iPad builds, analysis, dedicated square evidence, and fresh
  review pass.
