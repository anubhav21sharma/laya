# World-Class Brush Engine: Foundation

- **Status:** Stage 1–2 Correctness Complete — Physical-Device Performance
  And Input Acceptance Pending
- **Date:** 2026-07-28
- **Branch:** `main`
- **Evidence commit:** `4a1b7158a095d67e78ce70466f9577722268b483`
- **Governing specification:**
  `docs/superpowers/specs/2026-07-26-world-class-brush-engine-design.md`
- **Implementation plan:**
  `docs/superpowers/plans/2026-07-27-world-class-brush-engine-foundation.md`

## Status Ruling

Stages 1 and 2 of the world-class brush-engine design are correctness
complete. The implementation now has:

- immutable native brush definitions and deterministic compiled programs;
- exact compatibility adapters for all five current anchor brushes;
- normalized Pencil, tablet, mouse, coalesced, predicted, and estimated-update
  input;
- bounded logical-dab batches and replay ownership;
- versioned, defensively decoded `.layabrush` packages;
- bounded CPU texture preparation, mip generation, private Metal upload, and
  pinned-LRU residency;
- atomic latest-request-wins brush compilation and activation;
- program capture before pointer-down, with no compile, decode, or upload work
  during a stroke;
- deterministic logical and renderer characterization baselines;
- a fail-closed, commit-bound foundation evidence gate.

The gate passed every correctness requirement. Its final exit was `2`, not
`0`, because the host GPU is `Apple Paravirtual device`. This is the one
recognized performance-pending condition. It is not a performance pass and
does not block later correctness work.

This milestone does not complete Stage 3 conversion or Brush Lab work, Stage 4
deposition backends, Stage 5 professional dry-media calibration, Stage 6
canvas-interaction wet media, or Stage 7 product calibration.

## Evidence Command And Result

The gate ran from clean, committed build inputs:

```bash
./scripts/verify-brush-foundation.sh
```

Terminal result:

```text
BRUSH FOUNDATION PERFORMANCE PENDING: unstable real-Metal timing environment 'Apple Paravirtual device'.
BRUSH FOUNDATION CORRECTNESS PASS; PERFORMANCE PENDING artifacts=/Users/anubhav/git/laya/.build/brush-foundation-artifacts commit=4a1b7158a095d67e78ce70466f9577722268b483
```

The command exited `2`, with correctness accepted and stable physical-device
performance still pending. Any correctness, provenance, baseline, negative
control, or unrecognized performance condition would instead exit `1`.

The generated evidence is under:

```text
/Users/anubhav/git/laya/.build/brush-foundation-artifacts
```

It contains 134 files, eight complete positive scene directories, eight
negative-control directories, exact copies of all 16 committed scene inputs,
compiler/cache evidence, adapter parity evidence, benchmark and image
artifacts, logs, and source/toolchain/host provenance.

The nested Slice 4 gate retains its detailed test, build, analysis, and first
scene-run logs separately under:

```text
/Users/anubhav/git/laya/.build/slice4-artifacts/gate-logs
```

The foundation root's `logs/slice4-gate.*.log` files record only the nested
gate's terminal status. The counts and timings below cite the detailed Slice 4
logs at the separate path, while the final fresh-scratch result cites
`brush-foundation-artifacts/logs/foundation-tests.stdout.log`.

## Commands Exercised By The Gate

The committed script ran the following acceptance families:

```bash
./scripts/verify-slice4.sh
swift test \
  --scratch-path .build/brush-foundation-swiftpm \
  --no-parallel
./scripts/bootstrap.sh
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath .build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath .build/DerivedData \
  analyze CODE_SIGNING_ALLOWED=NO
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedDataPad \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedDataPad \
  analyze CODE_SIGNING_ALLOWED=NO
```

It also ran all eight Slice 4 scenes and all eight matching negative controls
directly into the foundation artifact root, generated fresh logical and
renderer characterization files, recorded adapter and compiler evidence, and
ran:

```bash
BrushFoundationEvidenceGate \
  Tests/EditorCoreTests/Fixtures/brush-logical-v1.json \
  App/PatternSpike/Harness/Baselines/brush-foundation-v1.json \
  .build/brush-foundation-artifacts \
  4a1b7158a095d67e78ce70466f9577722268b483
```

The terminal boundary rechecked the commit, tracked tree, index, and untracked
build-input scopes. The pre-existing untracked `.vscode/` directory remained
untouched and is not a build input.

## Automated Test Results

The committed gate's generated logs record:

- pure `PatternEngineTests`: `285 tests in 8 suites`, passed in
  `129.252 seconds`;
- Slice 4 serialized full suite: `901 tests in 34 suites`, passed in
  `334.007 seconds`;
- final fresh-scratch serialized full suite: `901 tests in 34 suites`, passed
  in `337.648 seconds`;
- focused foundation validator suite: `12 tests in 1 suite`, passed, including
  the real Metal compiler-probe-to-production-validator round trip.

The Mac and generic iPad Simulator Debug builds both ended with
`** BUILD SUCCEEDED **`. Both matching static-analysis commands ended with
`** ANALYZE SUCCEEDED **`.

## Toolchain And Host Provenance

- Swift driver `1.148.6`
- Apple Swift `6.3.3`
  (`swiftlang-6.3.3.1.3 clang-2100.1.1.101`)
- Xcode `26.6` (`17F113`)
- XcodeGen `2.46.0`
- macOS `26.5.2` (`25F84`)
- architecture `arm64`
- model `VirtualMac2,1`
- GPU `Apple Paravirtual device`
- configuration `Debug`

`system_profiler SPDisplaysDataType` returned no display records on this
virtual host. The renderer benchmark records independently and consistently
identify the GPU as `Apple Paravirtual device`.

## Logical Baseline Digest Matrix

The checked logical baseline has SHA-256
`e456ec2d80d2060927adc34ddfab42b5a3125141c98d806fa06a4aaa169f5173`.
Fresh program-path generation byte-matched it.

| Recipe | Trace | Samples | Dabs | Logical digest |
| --- | --- | ---: | ---: | --- |
| `builtin.bounded-wash` | `curved` | 3 | 7 | `66c49941d22fe30c` |
| `builtin.bounded-wash` | `prediction-correction` | 6 | 13 | `134649a89211035f` |
| `builtin.bounded-wash` | `pressure-ramp` | 4 | 12 | `e98c21d468c3830a` |
| `builtin.dry-pencil` | `curved` | 3 | 9 | `924ad7405ec84146` |
| `builtin.dry-pencil` | `prediction-correction` | 6 | 23 | `77a44af8893d9636` |
| `builtin.dry-pencil` | `pressure-ramp` | 4 | 21 | `e98a4e0e0410caf3` |
| `builtin.glaze-marker` | `curved` | 3 | 6 | `105a0542aba6bb67` |
| `builtin.glaze-marker` | `prediction-correction` | 6 | 12 | `d22df3576f7815e6` |
| `builtin.glaze-marker` | `pressure-ramp` | 4 | 11 | `a97db29494e8eebe` |
| `builtin.hard-round-eraser` | `curved` | 3 | 8 | `c1ebfd9bee725f8f` |
| `builtin.hard-round-eraser` | `prediction-correction` | 6 | 12 | `1a65651a67b490d5` |
| `builtin.hard-round-eraser` | `pressure-ramp` | 4 | 11 | `dd7875f339161f5d` |
| `builtin.technical-ink` | `curved` | 3 | 11 | `b1f3e4f85138b9dc` |
| `builtin.technical-ink` | `prediction-correction` | 6 | 24 | `377f25efa505c5be` |
| `builtin.technical-ink` | `pressure-ramp` | 4 | 22 | `7912d37a88e8fc97` |

The separate 15-entry adapter artifact proves that every row has the same dab
count and digest through the captured program and compatibility-recipe paths.
Its SHA-256 is
`e2404f0b477ab3917abf25f80db3ed666371c79f97203b897d7b1b15515e2d62`.

## Renderer Baseline Digest Matrix

The checked renderer baseline has SHA-256
`1f2dd91d3b2de7147fa7043980d7cc1fc22412e33e19d4eb8e04a1ff691da5c8`.
Freshly merged evidence byte-matched it.

| Scene | Recipe | Samples | Dabs | Logical digest | Canonical BGRA8 digest |
| --- | --- | ---: | ---: | --- | --- |
| `slice4-dry-grain-tilings` | `anchor.dry-grain` | 3 | 118 | `2d04e8a667837c63` | `e9bd40bdce7c5f99` |
| `slice4-glaze-live-commit` | `anchor.glaze-soft` | 3 | 51 | `9f528c2c11294e87` | `62ecdf6d7b01c435` |
| `slice4-legacy-ink-parity` | `anchor.legacy-ink` | 3 | 23 | `5f650731c49e9b53` | `06f12904c36af1bc` |
| `slice4-long-stroke-bounds` | `anchor.dry-long` | 302 | 392 | `ea24c8caebd87672` | `d02e4ebcb7b34110` |
| `slice4-prediction-taper-replay` | `anchor.ink-prediction-taper-replay` | 4 | 79 | `5546147b1c54ccfc` | `7ac02c193a1cdcbd` |
| `slice4-pressure-scatter` | `anchor.ink-pressure-scatter` | 4 | 94 | `494cd23958f8fc56` | `45fc0cf054ba8721` |
| `slice4-stale-epoch-cancel` | `anchor.ink-stale-replay` | 3 | 31 | `6a8484319def2ff0` | `afe5248bf1f0630c` |
| `slice4-wash-bounds` | `anchor.wash-bounded` | 260 | 13,503 | `aef1e827f74bc3b4` | `c4b9216295a2dad7` |

The gate also validated the resolved shape/grain identities, all required
schema-6 benchmark fields, benchmark-to-characterization agreement, exact
commit and GPU provenance, image digests, positive artifact sets, and exact
negative-control failures.

## Compiler And Cache Evidence

The real Metal compiler probe produced a 5,461-byte private texture residency
for `evidence.cache-probe`:

| Boundary | Package decodes | Image decodes | Uploads | Cache hits | Activations |
| --- | ---: | ---: | ---: | ---: | ---: |
| Before compile | 0 | 0 | 0 | 0 | 0 |
| First activation | 1 | 0 | 1 | 0 | 1 |
| Same-resource reactivation | 2 | 0 | 1 | 1 | 2 |
| After 1,000 logical dabs | 2 | 0 | 1 | 1 | 2 |

The built-in probe generates its deterministic CPU pyramid without invoking
the packaged-image decoder, so an image-decode count of zero is expected. The
single private Metal upload is reused on the second activation, and all
compiler counters remain unchanged while 1,000 logical dabs are generated.

## Remaining Hardware Gates

The virtual-host evidence cannot accept any of these product claims:

- Apple Pencil feel, pressure response, tilt, azimuth, roll, prediction, or
  estimated-update behavior on a physical iPad;
- Wacom pressure, tilt, rotation, tangential pressure, or device identity on a
  physical macOS tablet setup;
- true input-to-photon latency;
- sustained 120 Hz ProMotion behavior or the oldest-supported-device 60 Hz
  floor;
- stable physical-Apple-GPU frame timing;
- thermal behavior under sustained drawing;
- shipping-app peak memory behavior and memory-warning recovery.

Those measurements remain explicit Stage 5/7 hardware acceptance work. This
milestone also does not claim final wet-brush behavior: bounded wash remains a
compatibility anchor until the Stage 6 canvas-interaction backend exists.

## Next Stage

The next planned work is Stage 3: the shared foreign-brush converter library,
CLI, `ForeignBrushIR`, compatibility reports, defensive corpus, and internal
Brush Lab shell. It must consume the native definitions and compiler delivered
here rather than adding foreign-format parsing to the app input path.
