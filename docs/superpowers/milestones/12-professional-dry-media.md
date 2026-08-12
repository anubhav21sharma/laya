# Professional Dry And Non-Interacting Media

**Status:**

- `engineIntegrated`: `true`
- `softwarePerformancePassed`: `true`
- `manualQualityPassed`: `false`
- `physicalProfilePassed`: `false`
- `productAccepted`: `false`

> **Status notice (2026-08-12):** The corrective engine rebuild and three-pass
> software performance round are complete. The four professional definitions
> remain laboratory-only because human quality review and qualifying physical
> hardware profiles are pending.

## Scope

The prior Stage 5 implementation added four proposed professional brush
families while preserving the frozen Stage 4 diagnostic anchors:

- `builtin.professional-technical-ink` (`Technical Ink`);
- `builtin.professional-graphite-pencil` (`Graphite Pencil`);
- `builtin.professional-natural-charcoal` (`Natural Charcoal`);
- `builtin.professional-chisel-marker` (`Chisel Marker`).

The editor catalog does not select these definitions. Persisted professional
IDs resolve only to their Brush Lab entries, with a manual/physical-pending
message; they do not silently select a substitute product brush. The corrective
program does not retune Stage 4 or claim perceptual quality from software
evidence.

All four candidate definitions declare `realtime60`. None declares
`realtime120`; that intent remains unavailable until the 120 Hz physical
profile passes.

## Commit Binding

The final clean run writes its authoritative commit, source-tree SHA-256,
toolchain, operating-system, hardware, GPU, Stage 4 prerequisite result, and
Stage 4 artifact-manifest SHA-256 to:

```text
.build/professional-brush-artifacts/provenance.json
```

The complete digest set is:

```text
.build/professional-brush-artifacts/artifact-sha256.txt
```

This document does not embed a future commit identity. The generated
provenance and manifest are the non-self-referential source of truth.

## Evidence Commands

The final command is:

```bash
./scripts/verify-brush-stage5.sh
```

It runs the complete Stage 4 gate first, then exercises these boundaries from
a clean committed source tree:

```bash
swift test --disable-sandbox --no-parallel
swift test --disable-sandbox --no-parallel \
  --filter \
  'ProfessionalBrushCatalogTests|ProfessionalBrushCharacterizationTests|ProfessionalBrushDynamicsTests|ProfessionalBrushHarnessRunnerTests|ProfessionalBrushEvidenceValidatorTests|EditorBrushCatalogTests|BrushLabSessionTests'
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac \
  -configuration Debug -destination platform=macOS \
  -derivedDataPath .build/ProfessionalBrushDerivedDataMac \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac \
  -configuration Debug -destination platform=macOS \
  -derivedDataPath .build/ProfessionalBrushDerivedDataMac \
  analyze CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ProfessionalBrushDerivedDataPad \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ProfessionalBrushDerivedDataPad \
  analyze CODE_SIGNING_ALLOWED=NO
```

It also runs the four positive Metal scenes and four fail-closed negative
controls in isolated app processes, exports the stable 40-record logical
characterization baseline, exports the fixed 68-card manual catalog, builds
the artifact-only validator, and verifies the final source tree and artifact
manifest.

The focused harness and validator development command is:

```bash
swift test --disable-sandbox --no-parallel \
  --filter 'ProfessionalBrush(HarnessRunner|EvidenceValidator)Tests'
```

Its first implementation-complete run passed 11 tests in two suites. The
final clean gate reruns this coverage inside the complete serialized suite.

## Historical Clean Gate Result

A clean committed run on 2026-07-30 recorded exit `2` and the exact terminal
classification:

```text
BRUSH STAGE 5 MANUAL/PHYSICAL PENDING
```

This was the historical all-software-green classification; it is not current
correctness or product-acceptance evidence. The run recorded:

- the Stage 4 prerequisite remained software-correct and ended only in its
  designed physical-performance-pending state on the paravirtual host;
- the complete suite passed 1,297 tests in 70 suites;
- the focused professional coverage passed 97 tests in three suites;
- the macOS and iPad Simulator targets both built and analyzed;
- all four positive professional scenes and four paired fail-closed negative
  controls passed artifact-only validation;
- software correctness and the CPU preparation budget passed, while
  paravirtual GPU measurements remained diagnostic and could not establish a
  physical-device performance claim.

The exact commit, source-tree digest, toolchain, hardware classification,
Stage 4 artifact binding, renderer executable digest, measured timings, and
per-brush missed-frame diagnostics remain in the generated provenance and
performance-status files. They intentionally are not copied into this
checked-in document, which avoids a circular commit identity and makes each
clean rerun the authoritative source.

## Automated Evidence

Each positive scene produces exactly:

- `live.png`, `committed.png`, and `canonical.png`;
- prediction-on/off, grid-origin/translated, eraser-before/after, and four
  radial rendered/reference observation PNGs;
- `characterization.json`;
- `benchmark.json`;
- `evidence.json`;
- `professional-performance.json`;
- `professional-five-hundred-dabs.raw.json`;
- `professional-long-stroke.raw.json`;
- `professional-long-stroke-trace.json`.

The scene evidence binds the professional definition ID and semantic hash,
resolved resource identities and mip counts, resident bytes, deposition
pipeline and ABI, compiler/cache counters, logical/projected work counts,
image and characterization hashes, preview/commit delta, scheduler telemetry,
and the required prediction, tiling, radial, eraser, bounded-work, resource,
and input-hot-path invariants.

Each paired negative control flips only
`professionalDefinitionIdentityExact`, exits exactly `1`, writes no standard
output, and writes one exact `HARNESS FAIL` line to standard error.

The artifact-only validator accepts only exact sorted roots and schemas,
recomputes source and artifact hashes, rejects raw caller-supplied status
strings, validates the independently generated Stage 4 prerequisite bundle,
and returns:

- `0` only when software, manual, and all physical profiles pass;
- `2` when software passes but manual or physical evidence is pending;
- `1` for any software, schema, provenance, artifact, or supplied-evidence
  failure.

## Software Measurements

The software policy is:

- professional CPU preparation p95 below `2 ms`;
- established 500-dab GPU workload below `3 ms` only on qualifying stable
  physical Metal hardware;
- completed-stroke-length-independent live work;
- every exact long-stroke live frame records the transient replay buffer's
  runtime retained-dab and visible projected-instance counts, bounded by
  `2048` and `4096` respectively, with nonzero retained state required;
- all 128 raw long-stroke timings remain authoritative while schema 4 reports
  16 contiguous eight-frame medians and deterministic Theil-Sen slopes from
  all 120 pairs at exact block-center frame indices; the validator recomputes
  every derived value, accepts multiple bounded timing-contaminated blocks
  without hiding sustained `+0.004 ms/frame` growth, and always enforces CPU
  quartile stability plus the `0.001 ms/frame` CPU slope limit; exact raw GPU
  samples, block medians, and slopes remain digest-bound diagnostics on
  nonphysical devices, while qualifying physical hardware additionally
  enforces GPU quartile stability and the unchanged `0.001 ms/frame` slope
  limit;
- the same schema preserves all 128 chronological event-to-submit samples,
  records the exact `16,666,667 ns` software frame budget, and requires a
  strictly-positive sample at every frame plus a validator-derived exact
  missed-frame count; nonzero software counts remain diagnostic and are
  published per brush in performance-status schema 3; the primary one-frame
  correctness capture's counter remains diagnostic because it intentionally
  batches the deterministic trace rather than modeling per-input submission;
- no compiler, decode, upload, pipeline creation, file I/O, or synchronous
  wait on the production input path;
- resource residency bounded by each compiled definition and device budget.

The final clean run records the measured maximum professional CPU p95, Stage 5
500-dab GPU diagnostic, and per-brush software event-to-submit miss counts in:

```text
.build/professional-brush-artifacts/performance-status.json
```

Exact per-scene CPU samples, GPU samples, resource bytes, renderer identity,
and OS/GPU provenance remain in the four positive benchmark files. Values
from a simulator, virtual, or paravirtual GPU are diagnostic and cannot
establish a product performance claim. Their exact raw GPU timing,
block-median, and Theil-Sen values remain validator-recomputed and published
as historical evidence only.

## Manual And Physical Acceptance

Software generates 68 sorted professional Brush Lab cards with every
appearance and input-quality assessment unset. It never self-approves edge
quality, taper, texture cohesion, pressure/tilt response, buildup,
seam/symmetry behavior, eraser match, responsiveness, or notes.

These physical profiles remain pending until separately supplied structured
raw evidence passes validation:

- reference M-series ProMotion iPad at 120 Hz;
- A14-class iPad at the 60 Hz floor;
- Apple Pencil;
- Wacom;
- sustained thermal drawing;
- memory-warning recovery;
- suspend/resume recovery;
- true input-to-photon capture.

Missing manual or physical evidence is a designed pending state. Malformed or
failing supplied evidence is an error, and caller-authored pass strings are
not accepted.

The current three-pass comparison is persisted at:

```text
.build/brush-corrective-acceptance/full-matrix/summary.json
.build/brush-corrective-acceptance/full-matrix/artifact-sha256.txt
```

It contains 24 isolated Release traces: two duration profiles for each of four
brushes over three runs. Canonical and logical hashes are stable; the runtime
gate enforces bounded queues, zero actual replay, zero dropped/overflowed
input, equal early/late projected work, and the one-percent event-to-submit
miss ceiling. Four paired negative controls fail closed. The production UI
route was also exercised directly; XCTest UI automation remains an OS-host
infrastructure exception because automation mode could not be enabled.

## Historical Checklist And Current Corrective Boundary

- [x] Historical: add four exact professional definitions, assets, catalog
      entries, and editor migrations.
- [x] Add the stable 40-record logical characterization matrix.
- [x] Add four positive and four paired fail-closed Metal scenes.
- [x] Add exact artifact schemas and artifact-only validation.
- [x] Preserve the frozen Stage 4 scene/evidence truth.
- [x] Historical: run the Stage 5 gate from the final clean committed source
      and record its exact terminal result.
- [x] Correctively rebuild and complete automated software qualification for
      the four professional definitions while keeping them out of the picker.
- [ ] Complete all 68 human perceptual assessments.
- [ ] Supply and validate all eight physical-hardware profiles.
