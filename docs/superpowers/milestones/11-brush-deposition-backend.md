# Brush Deposition Backend

**Status:** Stage 4 Acceptance Pending Physical Hardware And Manual Review

## Scope

This milestone records the commit-bound Stage 4 deposition evidence bundle.
Stage 4 replaces the generic compatibility stamp path and bounded wash with
the native compiled deposition backend for ink, dry media, glaze, marker,
airbrush, and erase.

## Commit Binding

- Stage 4 evidence gate:
  `cdbf0af7c2eed46a51b7604791a8784897c571db`
  (`test(brush): add Stage 4 evidence gate`).
- Gate-discovered native harness prerequisite:
  `87a5f4de34586d8f46f903ece8dccc8084920f46`
  (`fix(harness): restore native workload evidence`).
- Evidence record and final source tree: the commit containing this milestone.
  Its exact full identity is written by the final clean run to
  `.build/brush-deposition-artifacts/provenance.json` and repeated in every
  renderer-backed benchmark. The provenance file is authoritative because a
  Git commit cannot embed its own eventual object identity.

The harness prerequisite does not restore `ProjectedStampInstance` or any
legacy deposition route. It exposes native encoded-count identity ranges to
the historical performance harness and keeps long-stroke commit preparation
on the production two-phase native lifecycle.

## Automated Evidence

The final evidence command is:

```bash
./scripts/verify-brush-stage4.sh
```

On the current paravirtual Mac it completes every software check and exits
`2` with:

```text
BRUSH STAGE 4 PERFORMANCE PENDING artifacts=<absolute-artifact-root> commit=<provenance.commit> gpu=Apple Paravirtual device
```

Exit `2` is the designed hardware-only pending result. Exit `1` remains a
correctness, build, analysis, schema, digest, invariant, negative-control, or
stable-device performance failure.

### Tests And Contracts

- `swift test --no-parallel`: 1,145 tests in 68 suites passed.
- Focused Brush Lab headless contract: four tests in one suite passed.
- Positive native deposition scenes: 16 of 16 passed in isolated processes.
- Paired negative controls: 16 of 16 failed closed with exactly exit `1`,
  empty standard output, and one `HARNESS FAIL` standard-error line.
- The artifact-only validator accepted commit/source-tree provenance, exact
  scene pairing, schemas, native identities, pipeline/resource/texture
  evidence, PNG dimensions and hashes, CPU/GPU and preview/commit deltas,
  metamorphic invariants, hot-path counters, negative controls, the Brush Lab
  catalog, performance evidence, and the artifact manifest.

### Build And Analysis

Bootstrap completed before the four Xcode boundaries:

```bash
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac \
  -configuration Debug -destination platform=macOS \
  -derivedDataPath .build/BrushDepositionDerivedDataMac \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac \
  -configuration Debug -destination platform=macOS \
  -derivedDataPath .build/BrushDepositionDerivedDataMac \
  analyze CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/BrushDepositionDerivedDataPad \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/BrushDepositionDerivedDataPad \
  analyze CODE_SIGNING_ALLOWED=NO
```

Both builds and both analyses succeeded.

### Artifact Bundle

The authoritative bundle is:

```text
.build/brush-deposition-artifacts/
```

It contains commit/toolchain/OS/kernel/hardware/GPU provenance, matching
initial and terminal committed source trees, the exact scene matrix,
performance status, 16 positive directories, 16 negative-control directories,
the headless Brush Lab catalog, raw performance evidence, build/test logs, and
`artifact-sha256.txt`. The manifest binds every other artifact file; the final
clean run verifies every recorded digest before reporting pending or pass.

The Brush Lab catalog contains 312 sorted unique cards and 312 explicitly
unset assessments. Its committed SHA-256 is
`2e943ffdaf3da1ef3dc4dacbac916229c2815c86c1d04a256567a7a64a938331`.

### Software Performance Policy

- CPU preparation p95 budget: less than `2 ms`.
- Exact one-frame 500-dab GPU budget: less than `3 ms` only on stable,
  supported physical Metal hardware.
- Completed-stroke length independence: required and validated from the raw
  401-frame projected-long-stroke series.
- Input hot path: no decode, upload, pipeline creation, allocation, file I/O,
  or synchronous wait; compiler/resource counters remain zero.

The final run records the measured CPU and GPU values even when physical
acceptance is pending. Measurements from `Apple Paravirtual device` are
diagnostic and do not establish a 120 Hz or 60 Hz product claim.

## Physical Hardware Acceptance

The final software gate records `correctnessPassed = true`, while these eight
profiles remain explicitly pending unless a committed gate run receives
separate physical evidence:

- reference M-series ProMotion iPad at 120 Hz;
- A14-class floor at 60 Hz;
- Pencil;
- Wacom;
- memory-warning recovery;
- suspend/resume recovery;
- sustained thermal drawing;
- true input-to-photon instrumentation.

Virtual and paravirtual Metal measurements are diagnostic only and never
claim `realtime120` or 60 Hz physical acceptance.

## Manual Brush Lab Acceptance

The deterministic manual matrix contains 52 cards for each native anchor:

- `builtin.native-airbrush`;
- `builtin.native-dry-media`;
- `builtin.native-eraser`;
- `builtin.native-glaze`;
- `builtin.native-ink`;
- `builtin.native-marker`.

Every appearance, edge quality, buildup, texture cohesion, eraser match,
symmetry behavior, responsiveness, and notes assessment remains explicitly
unset. User appearance and input-quality review is therefore pending. No
visual baseline was created or promoted.

## Product Boundary

Old Slice 4 pixel parity and bounded-wash behavior are intentionally not
acceptance targets. Stage 5 may tune dry-media behavior only after this engine
boundary is accepted. Stage 6 introduces wet interaction, pickup, smudge, and
Wet Mix from scratch.

Stage 4 is not complete until every software check passes on the final commit
and the user assesses the manual cards. The designed hardware-only pending
state may remain explicit until the eight physical profiles are supplied.
