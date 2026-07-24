# Compiled Symmetry Phase 4: Radial / Mandala Domain

- **Status:** Implementation Complete — Acceptance Pending Environment-Only Gates
- **Date:** 2026-07-24
- **Branch:** `main`
- **Governing specification:**
  `docs/superpowers/specs/2026-07-23-compiled-periodic-radial-symmetry-design.md`
- **Implementation plan:**
  `docs/superpowers/plans/2026-07-24-radial-mandala-domain.md`

## Status Ruling

Phase 4 adds the approved finite document domain beside Seamless Pattern:

- Plain Canvas, with no repeat outside the finite document;
- Mirror (`D1`);
- arbitrary Rotation (`C_n`) for integer rays `2...32`;
- arbitrary Mandala/Kaleidoscope (`D_n`) for integer rays `2...32`;
- quick ray presets `4`, `6`, `8`, `12`, and `16`;
- one linked Cartesian canonical sector stored in deterministic sparse pages;
- pre-edit centre/reference/group/ray setup and permanent first-edit locking;
- finite crop/transparent-fill resize and full-canvas flattened export;
- an independent radial oracle and real-Metal evidence matrix.

The complete Swift suite, macOS and generic iPad simulator builds, both static
analysis passes, finite/radial failure matrix, independent oracle, and
real-Metal deterministic matrix pass. Physical Apple-GPU performance and
interactive UI automation remain environment-only acceptance work, matching
the earlier compiled-symmetry milestones.

## Stable Contracts

| Stable selector | Preset | Group | Displayed sectors |
| ---: | --- | --- | ---: |
| `14` | Plain Canvas | identity | 1 |
| `15` | Mirror | `D1` | 2 |
| `16` | Rotation | `C_n` | `n` |
| `17` | Mandala | `D_n` | `2n` |

Selectors `0...13` are unchanged. Finite configuration is domain-typed as
Plain or radial, so periodic lattice parameters cannot be combined with
finite radial geometry. Mirror is fixed at one ray; Rotation and Mandala
reject, rather than clamp, values outside `2...32`.

The centre must lie inside the half-open finite canvas. Reference angles are
finite and normalized to `[-π, π)`. The first successful raster operation
permanently locks the finite domain and radial geometry. Begin, projection,
allocation, encoding, and GPU command failures leave both pixels and lock
state unchanged.

## Cartesian Sector And Page Storage

The implementation does not use polar pixels or store one raster per ray.
World points fold isometrically into one Cartesian sector:

- `C_n` uses sector angle `2π/n`;
- `D_n` uses sector angle `π/n` and alternates reflection;
- brush scale and brush-local material coordinates are preserved.

`RadialSectorLayout` partitions the radius-bounded sector into `256 x 256`
logical pages. Only pages intersecting the sector receive deterministic
packed-atlas slots. An immutable signed-page table maps logical coordinates
to those slots for display, export, resize, and material sampling.

Canonical, settled-live, and replay-live surfaces share the same layout.
Projected footprints are split by canvas, sector, and page clips while
retaining the existing four-plane stamp ABI. Compiler limits reject atlas
dimensions, resident bytes, images, or projected-instance costs before any
renderer state changes.

Bounded wash is topology-aware:

- periodic documents wrap over the canonical repeat;
- Plain Canvas clips at finite document edges;
- radial documents expand halos through logical pages and sample through the
  page table instead of bleeding between physically adjacent atlas slots.

Real-Metal regressions cover both a wash crossing a packed radial page
boundary and a Plain Canvas edge that must not wrap.

## Rendering, History, Resize, And Export

- Dedicated radial Metal entry points perform finite fold, page-table lookup,
  bilinear canonical/live/replay composition, and radial guide overlays.
- Draw, erase, bounded wash, live preview, commit, clear, undo, and redo all
  operate on the linked canonical sector.
- Raster history records logical document size separately from physical atlas
  size. Full-atlas revisions remain geometry-agnostic and restore exact bytes.
- Finite resize is top-left crop or transparent expansion with no scaling.
  Radial resize rebuilds the layout and copies a canonical orbit only when an
  image remains inside the resized canvas; cropped content cannot resurrect.
- Resize and resize-restore allocate and explicitly clear replacement replay
  surfaces before atomic installation.
- Finite export renders exactly the document pixel dimensions through the
  production fold/page-table sampler. Transparency is supported and export
  cannot mutate pixels, history, viewport, configuration, or lock state.

## Model And Product UI

The editor exposes Seamless Pattern, Radial/Mandala, and Plain Canvas
creation states. The finite inspector provides:

- Plain, Mirror, Rotation, and Mandala modes;
- arbitrary ray entry plus the five quick presets;
- centre X/Y and reference-angle entry;
- grid/guide visibility and an explicit lock explanation.

Geometry controls remain visible but disabled after lock. Numeric fields use
non-editor focus targets, so digit input is not consumed by tiling shortcuts.
Controller/model tests prove successful lock, failed-first-edit rollback,
undo/redo, Clear, eraser, grid, resize, and domain switching behavior.

## Complete Regression Gate

```bash
swift test \
  --scratch-path .build/phase4-final-scratch \
  --no-parallel
```

Result: exit `0`; `612 tests in 18 suites` passed with zero issues in
`261.233 seconds`.

The first clean run found one stale test-only expectation that still ended the
append-only selector list at `13`. Production behavior and every Phase 4 test
had passed. Updating that assertion to `0...17` made the focused contract and
the complete rerun pass.

## Product Builds And Analysis

`./scripts/bootstrap.sh` regenerated `App/PatternSpike.xcodeproj`.

The macOS and generic iPad simulator `Debug` builds both exited `0`:

```bash
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO

xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

The equivalent `analyze` commands also ended with
`** ANALYZE SUCCEEDED **`.

## Dedicated Phase 4 Metal Evidence

Eight positive/single-cause-negative scene pairs cover:

| Positive scene | Case | Negative expectation |
| --- | --- | --- |
| `radial-generic` | generic off-centre `C5` | one mismatch |
| `radial-axis` | `D8` mirror axis | one mismatch |
| `radial-center` | `D7` fixed centre | one mismatch |
| `radial-reflected` | oriented `D1` reflection | one mismatch |
| `radial-large-footprint` | maximum `D32` footprint | one mismatch |
| `radial-erase` | linked erase | one mismatch |
| `radial-lock` | post-commit geometry lock | one mismatch |
| `radial-export` | viewport/guide-independent export | one mismatch |

Every positive reports zero oracle-fold mismatches, zero missing Metal orbit
points, zero erase residue, zero lock violations, and zero export mutations.
Every paired negative expects exactly one mismatch and fails closed against
the unchanged positive measurement.

The dedicated real-Metal ray matrix covers
`2, 3, 4, 5, 6, 7, 8, 12, 16, 32`. Two complete runs produced identical
export hashes, fragment counts, and resident page bytes for every ray count.

## Measured Paravirtual Diagnostics

The radial harness records per-scene CPU projection time, commit CPU and GPU
time, projected fragment count, per-surface resident atlas bytes, finite
export time, and deterministic export hash. These values are correctness and
cost diagnostics on the Apple Paravirtual device, not physical-device
shipping acceptance.

The maximum accepted centred `4096 x 4096`, 32-ray configurations compile
inside the declared dimension, resident-byte, and projection budgets.
An extreme off-centre `C32` case whose projected cost is `4160` is rejected
against the `4096` instance limit before installation.

## Remaining Acceptance Debt

- Run the macOS UI suite on a host with XCTest automation enabled, including
  mode selection, arbitrary/preset ray entry, centre/reference fields,
  drawing, erasing, Clear, undo/redo, guides, lock-state visibility, resize,
  and export.
- Capture physical Apple-GPU p50/p95 for projection, dab, display, commit,
  and export plus sustained FPS, transfer traffic, and peak resident memory
  across representative canvas/ray/brush sizes.

No known correctness bug or specification deviation remains open.
