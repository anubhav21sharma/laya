# Compiled Symmetry Phase 2: Square Families

- **Status:** Implementation Complete — Acceptance Pending Environment-Only Gates
- **Date:** 2026-07-23
- **Branch:** `main`
- **Governing specification:**
  `docs/superpowers/specs/2026-07-23-compiled-periodic-radial-symmetry-design.md`
- **Implementation plan:**
  `docs/superpowers/plans/2026-07-23-square-symmetry-families.md`

## Status Ruling

Phase 2 implements the seamless-pattern square families without changing the
document domain or replacing retained canonical pixels:

- Square Rotation (`p4`, stable selector `7`);
- Square Kaleidoscope (`p4m`, stable selector `8`);
- reversible square world spacing and orientation;
- four/eight compiled images, stabilizers, and deterministic ownership;
- fixed-point-safe complete-stamp deduplication;
- production Metal display, guides, live/commit, eraser, and repeat export;
- inspector controls and atomic metadata history.

The implementation, clean-scratch Swift suite, both app builds, both static
analysis passes, independent oracle, dedicated square Metal evidence, and all
legacy parity gates pass. Final UI automation is environment-blocked because
the current macOS host cannot enable XCTest automation mode. Physical-device
performance remains deferred; measured timings below come from the Apple
Paravirtual Metal device and are correctness evidence, not shipping
performance acceptance.

## Stable Contracts

| Stable selector | Preset | Generic images | Ownership |
| ---: | --- | ---: | --- |
| `7` | Square Rotation (`p4`) | 4 | four rotation sectors |
| `8` | Square Kaleidoscope (`p4m`) | 8 | eight `45-45-90` mirror triangles |

The original selectors `0...6` are unchanged. Square presets continue to use
the existing rectangular kernel-family wire because their exported supercell
is square. Periodic world repeat geometry is stored separately from canonical
pixel dimensions. Raster resize remains top-left crop/transparent expansion
with no scaling and does not modify repeat geometry.

Square repeat dimensions are positive finite continuous world values rather
than integer pixel counts. The compiler rejects a repeat when the worst-case
rotated maximum-size brush could exceed the `4096` projected-instance
capacity; this is a cost bound, not an integer geometry bound. Only canonical
raster dimensions and requested export density retain the integer
`64...4096` bounds. Orientation is normalized once by the compiler and the
compiled lattice basis/inverse is reused by projection and Metal.

## Correctness And Failure Handling

- The compiler proves group closure, inverses, determinant sign, lattice
  preservation, stable image order, ownership coverage, stabilizers, and a
  rotation-safe `2√2r` worst-case projection bound.
- Projection enumerates through the compiled lattice inverse and clips against
  exact four-plane cell polygons.
- Coverage-equivalent images collapse only when the complete evaluated stamp
  declares the corresponding rotation/reflection invariance.
- Square fixed-point centre keys tolerate at most two ULPs per component;
  clipped domains and operation equivalence remain exact, and a `4096`-pixel
  near-stabilizer regression proves distinct subpixel orbits remain distinct.
- The independent square oracle implements direct lattice and `C4`/`D4`
  formulas without consuming production descriptors.
- Configuration changes validate before renderer/model/history mutation.
  Cancellation failure also drains queued token-bearing work so the editor
  cannot remain permanently busy.
- Inspector drafts round-trip continuous values and preserve an untouched
  spacing or orientation field bit-exactly when the other field is applied.
- Export rejects unsupported presets, invalid density, allocation failure,
  command-buffer failure, and encoder failure without changing canonical
  bytes, descriptor, history-facing renderer state, or viewport.
- The square fixed-point harness explicitly declares complete round-stamp
  invariance. A regression test prevents the earlier half-turn-only harness
  contract from producing coincident p4 writes.
- Generic square Metal scenes must also pass the independent oracle. Their
  probe is deliberately separated from every stabilizer so valid overlapping
  anti-aliased orbit copies do not masquerade as binary-oracle phantoms.

## Complete Regression Gate

```bash
swift test \
  --scratch-path .build/phase2-final-scratch2 \
  --no-parallel
```

Result: exit `0`; `548 tests in 11 suites` passed with zero failures in
`236.792 seconds`.

Notable matrices within that run:

- the compiled production/independent-oracle matrix passed all `540` cases in
  `103.932 seconds`;
- the archived Slice 4 real-Metal matrix passed in `104.996 seconds`;
- the periodic export suite passed all six tests, including both square
  presets, independent translated `3x3` sampling, and injected
  allocation/encoding failures.

After adding square cases to the existing live/commit eraser test:

```bash
swift test --no-parallel \
  --filter liveAndCommittedFixedStrengthEraserMatchAndClearCenter
```

Result: the Grid, Square Rotation, and Square Kaleidoscope cases passed.

## Product Builds And Analysis

`./scripts/bootstrap.sh` regenerated `App/PatternSpike.xcodeproj` with
XcodeGen `2.46.0`.

The following all exited `0`:

```bash
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
  -derivedDataPath .build/Phase2FinalPadReview \
  build CODE_SIGNING_ALLOWED=NO
```

The equivalent `analyze` commands used
`.build/Phase2FinalMacAnalyzeReview` and `.build/Phase2FinalPadReview`;
both ended with `** ANALYZE SUCCEEDED **`.

The macOS UI-test bundle builds and signs successfully through the
`PatternSpikeMac` scheme. The host then fails before launching any test:

```text
Failed to initialize for UI testing:
Timed out while enabling automation mode.
```

Result bundle:
`.build/DerivedDataUITestsSigned/Logs/Test/Test-PatternSpikeMac-2026.07.23_19-30-51-+0530.xcresult`.
No product assertion ran or failed. UI execution remains an explicit
environment-only acceptance gate.

## Dedicated Square Metal Evidence

The production macOS app ran these positive/single-cause-negative pairs:

| Positive scene | Preset | Negative metric |
| --- | --- | --- |
| `square-rotation-noncentral` | `p4` | `visibleCellCanonicalByteDelta` |
| `square-kaleidoscope-noncentral` | `p4m` | `visibleCellCanonicalByteDelta` |
| `square-rotation-fixed-point` | `p4` | `duplicateFixedPointWriteCount` |
| `square-kaleidoscope-fixed-point` | `p4m` | `duplicateFixedPointWriteCount` |

Every positive exited zero with `HARNESS PASS`. Every negative exited nonzero
with a typed `HARNESS FAIL`. All positive and negative runs report zero oracle
holes, zero phantoms, zero maximum delta, and zero transform mismatches. The
fixed-point positives additionally report one projected fragment and zero
duplicate writes.

The four positives generated `22` PNGs. Their normalized manifest is
`.build/phase2-square-evidence-final6-content.sha256`. A second clean run
generated `.build/phase2-square-evidence-repeat7-content.sha256`; `diff -u`
returned `0` with no output.

## Legacy Byte Parity

All 22 archived legacy positive/negative scene pairs passed through the same
post-Phase-2 production binary. The new manifest contains exactly 123 PNGs:

```bash
diff -u \
  .build/symmetry-phase1-legacy-baseline.sha256 \
  .build/symmetry-phase2-legacy-final2.sha256
```

Result: exit `0` with no output. All 123 PNG payloads are byte-identical to
the pre-Phase-1 baseline.

## Measured Paravirtual Performance

These numbers aggregate the noncentral and fixed-point square harness runs.
Percentiles use linear interpolation. They are Debug/paravirtual measurements.

| Preset | CPU encode/projection p50 / p95 | Dab GPU p50 / p95 | Display GPU p50 / p95 |
| --- | --- | --- | --- |
| `p4` | `0.129 / 0.330 ms` | `2.437 / 3.016 ms` | `2.014 / 2.773 ms` |
| `p4m` | `0.051 / 0.228 ms` | `0.987 / 0.992 ms` | `0.800 / 0.981 ms` |

Live instance traffic is one instance at a completely invariant fixed point,
four for generic `p4`, and eight for generic `p4m`. The observed process peak
resident sizes were `29,982,720` bytes for `p4` and `29,933,568` bytes for
`p4m`.

The focused two-preset export tests completed the direct 64-pixel renders in
`0.032 seconds` combined and the oriented rectangular-source 137-pixel
reference comparisons in `0.106 seconds` combined. The complete export suite,
including the independent translated `3x3` check, completed in `0.422`
seconds. These are suite timings,
not physical-device per-preset latency claims.

Export payload memory is deterministically bounded. At maximum density
`4096`, the BGRA8 target is `67,108,864` bytes and the tightly packed returned
buffer is another `67,108,864` bytes, for `134,217,728` bytes of peak bounded
payload while both are live, excluding the existing canonical texture and
driver/pipeline overhead.

## Remaining Acceptance Debt

- Run the existing macOS UI suite on a host where XCTest automation mode is
  enabled, including numeric-field focus, preset selection, drawing, erasing,
  clear, undo/redo, and guide visibility.
- Capture physical Apple-GPU p50/p95 and peak-resident export measurements for
  both presets before declaring performance acceptance.

No known correctness bug or legacy deviation remains open.
