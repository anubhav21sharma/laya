# Brush Deposition Backend

**Status:** Stage 4 Acceptance Pending Physical Hardware And Manual Review

## Scope

This milestone records the commit-bound Stage 4 deposition evidence bundle.
Stage 4 replaces the generic compatibility stamp path and bounded wash with
the native compiled deposition backend for ink, dry media, glaze, marker,
airbrush, and erase.

## Commit Binding

- The authoritative commit and source-tree identity are written by each final
  clean run to `.build/brush-deposition-artifacts/provenance.json` and repeated
  in every renderer-backed benchmark.
- The authoritative bundle digest set is written to
  `.build/brush-deposition-artifacts/artifact-sha256.txt`.
- This milestone intentionally does not copy the final commit, source-tree
  digest, artifact-manifest digest, or measured timings. A commit cannot embed
  its own eventual object identity, and copied run values become stale after
  any reviewed correction. The generated evidence files are the single
  source of truth.

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

- `swift test --no-parallel`: the complete serialized suite passed; exact
  test and suite counts are recorded in the final run log.
- Focused post-warmup input-path allocation contract: one test passed
  after 128 warmup events and 512 audited events.
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
the headless Brush Lab catalog, a `physical-profiles` root for separately
supplied structured raw evidence, raw software performance evidence,
build/test logs, and `artifact-sha256.txt`. The manifest binds every other
artifact file; the final clean run verifies every recorded digest before
reporting pending or pass.

The Brush Lab catalog contains 312 sorted unique cards and 312 explicitly
unset assessments. Its generated digest is bound through the final run's
provenance and artifact manifest rather than copied into this milestone.

The clean reviewed run's exact commit, source-tree SHA-256, and complete
artifact digest set live only in `provenance.json` and
`artifact-sha256.txt`, following the non-self-referential convention above.

### Software Performance Policy

- CPU preparation p95 budget: less than `2 ms`.
- Exact one-frame 500-dab GPU budget: less than `3 ms` only on stable,
  supported physical Metal hardware.
- Completed-stroke length independence: required and validated from the raw
  401-frame projected-long-stroke series.
- Input hot path: no decode, upload, pipeline creation, file I/O, or
  synchronous wait; compiler/resource counters remain zero. Renderer-owned
  reusable scratch covers dab generation, tiling projection, scheduler frame
  drains, and replay record stores. Runtime allocation-event instrumentation
  observed no post-warmup scratch acquisition across 512 audited events.

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

Raw caller-supplied `passed`, `pending`, or `failed` strings are rejected.
Each supplied profile must contain the exact structured evidence schema,
commit/source-tree and toolchain provenance, profile-specific platform,
hardware model, GPU class, measured refresh provenance, input-device identity
and telemetry source, threshold declarations, and a structured raw trace.
The validator recomputes the raw trace digest and metric aggregates, enforces
minimum sample/event counts and trace duration with ordered timestamps, and
requires reported samples to match the raw samples before a physical profile
can pass.

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

## Reviewed Completion Checklist

- [x] Software-complete on committed source: the clean Stage 4 gate passed all
      correctness, test, build, analysis, scene, binary, source, schema,
      provenance, digest, allocation-event, and negative-control checks,
      then returned the designed exit `2` on the paravirtual GPU.
- [x] Close all seven post-review software findings with failing-first
      regressions, including the six restored native regression cases.
- [x] Preserve native-only production boundaries without restoring
      `ProjectedStampInstance` or bounded-wash runtime behavior.
- [ ] Supply and validate all eight physical-hardware evidence profiles.
- [ ] Complete the 312-card human Brush Lab appearance and input-quality
      assessment.
