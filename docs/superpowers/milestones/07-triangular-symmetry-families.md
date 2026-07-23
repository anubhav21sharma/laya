# Compiled Symmetry Phase 3: Triangular Families

- **Status:** Implementation Complete — Acceptance Pending Environment-Only Gates
- **Date:** 2026-07-24
- **Branch:** `main`
- **Governing specification:**
  `docs/superpowers/specs/2026-07-23-compiled-periodic-radial-symmetry-design.md`
- **Implementation plan:**
  `docs/superpowers/plans/2026-07-23-triangular-symmetry-families.md`

## Status Ruling

Phase 3 implements the approved seamless-pattern triangular families without
changing the periodic document model or storing expanded output pixels:

- Hexagons, a triangular-lattice translation preset;
- Rotation 3 (`p3`);
- Rotation 6 (`p6`);
- Kaleidoscope 60 degrees (`p3m1` / `*333`);
- Kaleidoscope 30 degrees (`p6m` / `*632`);
- a rectangular index-two supercell and metric-correct repeat export;
- triangular grid, mirror, and 2/3/6-fold guide programs;
- a production-independent triangular coverage oracle.

The implementation, complete Swift suite, both product builds, both static
analysis passes, independent oracle, real-Metal Phase 3 matrix, and archived
legacy/square byte-parity gates pass. Physical Apple-GPU performance and UI
automation remain environment-only acceptance work, matching the prior
compiled-symmetry milestone policy.

## Stable Contracts

| Stable selector | Preset | Point group | Generic images |
| ---: | --- | --- | ---: |
| `9` | Hexagons | translation | 2 |
| `10` | Rotation 3 | `C3` | 6 |
| `11` | Rotation 6 | `C6` | 12 |
| `12` | Kaleidoscope 60 degrees | `D3` | 12 |
| `13` | Kaleidoscope 30 degrees | `D6` | 24 |

Selectors `0...8` are unchanged. Triangular presets compile as the dedicated
`.triangular` family and dispatch through `TriangularSymmetryKernel`; no
fallback to Grid or the rectangular projection kernel exists.

The world primitive vectors are:

```text
u = rotate(angle) * (spacing, 0)
v = rotate(angle) * (spacing / 2, sqrt(3) * spacing / 2)
```

Retained pixels represent the rectangular index-two supercell with horizontal
vector `u`, vertical vector `2v-u`, and the two primitive cosets `0` and `v`.
The raster metric may be anisotropic, but group operations remain world-space
isometries. Spacing and orientation remain continuous metadata independent of
canonical raster dimensions.

## Correctness And Failure Handling

- Group operations store exact rational turns as `step/order`; deduplication
  never infers group equality from approximate angles.
- The compiler emits deterministic image tables, two cosets, 24 ownership
  triangles, stabilizers, guide selectors, and bounded projection cost.
- The triangular kernel enumerates transformed supercell preimages, clips each
  exact parallelogram, folds into half-open storage, and preserves stable
  row/column/image ordering.
- Complete-stamp invariance controls coincident-image collapse. The
  4096-pixel regression proves an exact fixed point deduplicates while a
  `0.0015`-pixel near-fixed point retains every distinct image.
- The independent oracle implements direct triangular coordinates,
  `C3`/`C6`/`D3`/`D6` operations, cosets, folding, coverage, and material
  coordinates without consuming production descriptor images or ownership.
- Inspector spacing/orientation drafts preserve untouched continuous fields
  bit-exactly. Switching between square and triangular lattice presets
  preserves the lattice draft; selecting a triangular preset from a
  rectangular legacy canvas installs a valid uniform default.
- Draw, erase, live/commit, clear, history, grid visibility, numeric focus,
  and canonical crop/transparent-fill resize remain available for all five
  presets.
- Triangular display uses a separate Metal entry point. The archived
  rectangular/square shader path remains byte-identical.
- Repeat export produces `density x round(sqrt(3) * density)` BGRA8 pixels,
  uses wrapped bilinear sampling, and rejects an invalid derived dimension
  before allocating or mutating renderer state.

## Complete Regression Gate

```bash
swift test \
  --scratch-path .build/phase3-final-scratch \
  --no-parallel
```

Result: exit `0`; `568 tests in 12 suites` passed with zero issues in
`286.035 seconds`.

Focused post-review gates also passed:

```bash
swift test --filter SymmetryDescriptorCompilerTests
swift test --filter TriangularSymmetryKernelTests
swift test --filter PeriodicRepeatExportTests
swift test --filter triangularPreset
```

These cover exact group closure and ownership, the fixed/near-fixed
regression, all five metric exports, guide visibility, and rectangular-canvas
preset selection.

The post-isolation cached full run executed 569 tests. All 568 behavioral and
integration tests passed; the only issue was a stale source-string assertion
that still expected triangular dispatch inside the legacy shader function.
After updating that assertion to require the dedicated triangular fragment,
the complete seven-test shader-source suite passed. No production file
changed after that correction.

## Product Builds And Analysis

`./scripts/bootstrap.sh` regenerated `App/PatternSpike.xcodeproj` with
XcodeGen `2.46.0`.

The macOS and generic iPad simulator `Debug` builds both exited `0`:

```bash
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/phase3-final-mac \
  build CODE_SIGNING_ALLOWED=NO

xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/phase3-final-pad \
  build CODE_SIGNING_ALLOWED=NO
```

The equivalent `analyze` commands against the same derived-data paths both
ended with `** ANALYZE SUCCEEDED **`.

## Dedicated Phase 3 Metal Evidence

The production macOS app ran these positive/single-cause-negative pairs:

| Positive scene | Preset/case | Negative metric |
| --- | --- | --- |
| `triangular-hexagons-noncentral` | Hexagons | visible-cell byte delta |
| `triangular-rotation3-noncentral` | Rotation 3 | visible-cell byte delta |
| `triangular-rotation6-noncentral` | Rotation 6 | visible-cell byte delta |
| `triangular-kaleidoscope60-noncentral` | Kaleidoscope 60 | visible-cell byte delta |
| `triangular-kaleidoscope30-noncentral` | Kaleidoscope 30 | visible-cell byte delta |
| `triangular-kaleidoscope30-fixed-point` | 2/3/6-fold evidence | duplicate fixed-point writes |
| `triangular-kaleidoscope30-large-footprint` | distant supercells | oracle holes |
| `triangular-kaleidoscope30-mirror` | oriented reflection | oracle holes |
| `triangular-kaleidoscope30-eraser` | live/commit eraser | preview/commit violation |

Every positive exited zero with `HARNESS PASS`. Every negative exited exactly
one with one typed `HARNESS FAIL`. All oracle-bearing positives report zero
holes, zero phantoms, zero maximum delta, and zero transform mismatches.

The nine positives generated 50 PNGs under
`.build/phase3-harness-isolated-a`. A second run under
`.build/phase3-harness-isolated-b` generated the same 50 hashes;
`diff -u` returned zero with no output.

## Archived Byte Parity

All 22 Phase 1 legacy positive scenes were replayed through the final Phase 3
binary. Their 123 deterministic PNGs exactly match
`.build/symmetry-phase1-legacy-baseline.sha256`.

All four Phase 2 square positive scenes were also replayed. Their 22 PNGs
exactly match
`.build/phase2-square-evidence-final6-content.sha256`, including the display
screens. The isolated triangular display pipeline prevents new guide code
from perturbing the approved square shader output.

## Measured Paravirtual Performance

The representative second deterministic run used the Apple Paravirtual
device in Debug. These are correctness diagnostics, not physical-device
shipping acceptance:

| Scene | Max fragments | Instance bytes | CPU max | Dab GPU max | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Hexagons generic | 2 | 512 | 0.117 ms | 0.978 ms | 25.36 MB |
| Rotation 3 generic | 7 | 1,792 | 0.182 ms | 0.903 ms | 25.41 MB |
| Rotation 6 generic | 14 | 3,584 | 0.160 ms | 2.825 ms | 25.58 MB |
| Kaleidoscope 60 generic | 16 | 4,096 | 0.128 ms | 1.180 ms | 25.46 MB |
| Kaleidoscope 30 generic | 28 | 7,168 | 0.113 ms | 1.140 ms | 25.53 MB |
| Kaleidoscope 30 fixed point | 6 | 768 | 0.164 ms | 1.014 ms | 29.34 MB |
| Kaleidoscope 30 large footprint | 598 | 76,544 | 0.282 ms | 4.608 ms | 30.65 MB |
| Kaleidoscope 30 mirror | 52 | 6,656 | 0.056 ms | 1.657 ms | 24.89 MB |
| Kaleidoscope 30 eraser | 18 | 2,304 | 0.157 ms | 1.051 ms | 25.10 MB |

The five-preset 64-pixel export gate completed in `0.902 seconds` combined.
Each result is `64x111`, or 28,416 returned BGRA8 bytes. The largest accepted
triangular payload is `2365x4096`; target plus returned BGRA8 storage is
bounded to 77,496,320 bytes, excluding the existing canonical texture and
driver overhead.

## Remaining Acceptance Debt

- Run the existing macOS UI suite on a host where XCTest automation mode can
  be enabled, including preset selection, lattice text fields, drawing,
  erasing, clear, undo/redo, and guide visibility.
- Capture physical Apple-GPU p50/p95, sustained FPS, and peak-resident export
  measurements for all five presets.

No known correctness bug or specification deviation remains open.
