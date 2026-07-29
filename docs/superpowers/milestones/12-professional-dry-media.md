# Professional Dry And Non-Interacting Media

**Status:** Final Clean Evidence Run Pending

## Scope

Stage 5 adds four calibrated professional brush families while preserving the
frozen Stage 4 diagnostic anchors:

- `builtin.professional-technical-ink` (`Technical Ink`);
- `builtin.professional-graphite-pencil` (`Graphite Pencil`);
- `builtin.professional-natural-charcoal` (`Natural Charcoal`);
- `builtin.professional-chisel-marker` (`Chisel Marker`).

The editor catalog and migrations now select these definitions. The Stage 5
gate does not retune Stage 4, introduce wet interaction, or claim perceptual
quality from software evidence.

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

## Automated Evidence

Each positive scene produces exactly:

- `live.png`, `committed.png`, and `canonical.png`;
- `characterization.json`;
- `benchmark.json`;
- `evidence.json`.

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
- no compiler, decode, upload, pipeline creation, file I/O, or synchronous
  wait on the production input path;
- resource residency bounded by each compiled definition and device budget.

The final clean run records the measured maximum professional CPU p95 and
Stage 4 500-dab GPU diagnostic in:

```text
.build/professional-brush-artifacts/performance-status.json
```

Exact per-scene CPU samples, GPU samples, resource bytes, renderer identity,
and OS/GPU provenance remain in the four positive benchmark files. Values
from a simulator, virtual, or paravirtual GPU are diagnostic and cannot
establish 60 Hz or `realtime120` acceptance.

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

## Completion Checklist

- [x] Add four exact professional definitions, assets, catalog entries, and
      editor migrations.
- [x] Add the stable 40-record logical characterization matrix.
- [x] Add four positive and four paired fail-closed Metal scenes.
- [x] Add exact artifact schemas and artifact-only validation.
- [x] Preserve the frozen Stage 4 scene/evidence truth.
- [ ] Run the Stage 5 gate from the final clean committed source and record
      its exact terminal result.
- [ ] Complete all 68 human perceptual assessments.
- [ ] Supply and validate all eight physical-hardware profiles.
