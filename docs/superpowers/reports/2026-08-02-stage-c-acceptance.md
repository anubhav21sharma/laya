# Stage C Physical Input And Dynamics Acceptance

Status: **accepted**

Scope: Stage C Tasks C0 through C13. Stage D has not started.

Stage C base revision: `d108f75`

Last pre-acceptance implementation revision: `9fcca20384e3bdf4137b19ee1279c62cd8ec7baf`

Execution date: 2026-08-04 (Asia/Kolkata)

## Outcome

Stage C adds the schema-v2 physical-input and dynamics foundation while
preserving schema-v1 behavior as an explicit compatibility path. It includes
world-space velocity, stable direction and bounded corner fans, causal
stabilization, timed emission, evaluated tip-support spacing, ordered sensor
programs, a unified distance/time/corner candidate stream, and bounded
off-main continuation through the production renderer.

The acceptance tree also fixes one candidate-merger liveness bug found during
C13: a coincident time/distance candidate could be consumed without advancing
its cursor. The regression now proves the paged union settles exact duplicates
without hanging or changing ordinals.

No Stage D preset migration or wet-material work is included.

## Compatibility and semantic identity

`StageCSemanticAcceptanceTests` pins a pre-Stage-C schema-v1 `.layabrush`
archive and verifies all of the following without rewriting the source bytes:

- archive SHA-256 `12ab63f9c5588ccd7b625ebb41633221d7bc494e7f5fd21dd90f840efffbf98e`;
- definition SHA-256 `1619878df5c45fa61745813c71d7dcb11feaecd8abed0b82033ed8d7220852ad`;
- legacy content hash `5b9ff4f916d0a20dc1df61ad2b53056fe20b9950ea1e90792b96b5f64e1d0912`;
- exact decoded definition and compiled program;
- 21 exact logical dabs;
- logical digest `40c4f8b7acfe363ac984f7a40df9bb7792ce24d497f26d69ec97944fcb1b2f86`;
- full-dab digest `312dc6011bd6005e6213084869c084f95c16a405b65424d5bd09c530f4cf63ad`;
  and
- reference-raster digest `7a98c6d088ad90de4cf29263de6919732a61ffb4861f12b27c893e1e124a77aa`.

The same suite enumerates every stored schema-v2 semantic field and exercises
65 single-semantic mutations. Response tags, response payloads, term fields,
normalization, stabilization, direction, emission, support geometry, and
collection contents all change the digest. Dictionary insertion order and
randomized process hash order do not.

The professional dry-media characterization fixture was regenerated once
during C13. Investigation and commit-boundary isolation proved the change came
from approved C10 behavior: schema-v2 spacing now uses the evaluated current
tip footprint rather than nominal diameter. The regenerated fixture is stable
over repeated runs and has SHA-256
`2e903cc6be4d39bb563edc83a45e2ff29ff525b0d00b5b20ba6989904b299a08`.
The frozen schema-v1 package and logical/raster digests above were not changed.

## Determinism and partition matrix

The Stage C acceptance suites prove:

- all 32 contiguous partitions of the six-sample schema-v1 distance trace are
  identical;
- all 32 contiguous partitions of the schema-v2
  distance/time/corner trace are identical;
- every bounded output-page partition preserves exact dabs, ordinals, random
  channels, checkpoints, and final generator state;
- prediction disabled, endpoint-only prediction, and prediction after every
  sample produce identical authoritative output;
- production authoritative batch partitions commit byte-identical pixels;
- 60 Hz, 120 Hz, and uncapped display schedules do not alter authoritative
  output;
- viewport zoom does not alter world velocity, dynamics, spacing, or output;
- estimated location and sensor suffix replacement equals a fresh final
  actual trace;
- schema-v1 endpoint behavior remains exact;
- schema-v2 weighted endpoints, declared delayed lag, clicks, and stationary
  directional fallback remain visible and bounded;
- direction wrap, half-turn tie, exact reversal, maximum angular delta, and
  bounded corner fans preserve deterministic ordering;
- distance/time ties, huge time gaps, page resume, overflow, finish, cancel,
  and immediate reuse are transactional; and
- analytic and textured support follows size, aspect, rotation, tangent, and
  corner geometry while symmetry changes projected instances only.

The final Stage C-focused command was:

```text
swift test --filter 'StageC|stageC'
```

Result: **37 tests in 6 suites passed in 1.320 seconds**.

The prescribed medium command was:

```text
swift test --filter 'BrushInputTests|StrokeVelocityFilterTests|BrushDirectionTrackerTests|BrushCornerEmitterTests|StrokeStabilizerTests|TimedStrokeEmitterTests|BrushTipSupportTests|BrushFootprintSpacingTests|BrushSensorProgramTests|BrushDefinitionTests|BrushProgramCompilerTests|BrushDynamicsEngineTests|BrushStrokeGeneratorTests|LogicalDabBatchTests|TransientStrokeBufferTests|BrushPackageCodecTests|BrushPackageIOTests|StrokeFrameSchedulerTests|StrokeRenderCoordinatorTests'
```

Result: **400 tests in 10 suites passed in 4.693 seconds**.

## Production lifecycle and route audit

The serialized production acceptance suite runs the same schema-v2 program
through plain, seamless, and radial renderers. It covers begin, append,
prediction, estimated update, finish, commit, cancel, injected failure, rapid
next stroke, resize, clear, undo, redo, and brush switching. Each transition
asserts clean ownership, idle/reusable state, canonical pixel behavior, and
history behavior.

Production route guards prove that no app input path constructs or invokes the
legacy synchronous deposition renderer. The legacy surface remains confined to
named harness-only entry points. Candidate continuation is owned by the
off-main scheduler and drains under configured CPU, queue, projection, arena,
and output-page budgets. Finish cannot cross an undrained authoritative
continuation, while prediction remains disposable.

Failure injection covers candidate admission, page resume, replay transfer,
projection, private-surface reservation/encoding, acknowledgement, finish,
commit, cancellation, and stale/overtaking messages. Each failure either sheds
prediction or terminates the affected authoritative generation atomically; a
fresh generation remains usable.

## Performance and allocation checkpoint

The final optimized probe ran all allocation scopes plus production:

```text
scripts/run-brush-input-allocation-probe.sh all
```

The velocity filter, input derivation, direction/corner tracker, v2
stabilizer, Stage C generator, Stage C emitter, timed emitter, tip-support
spacing, and sensor program each reported zero post-warm-up allocations.
Production reported:

```text
application=0
workspace=0
main=0
authoritative=0
estimated=0
prediction=0
packaging=0
surface_pack=0
```

Periodic and radial-32 continuation traces crossed replay-tail boundaries and
remained flat over eight complete lifecycles. Driver/Metal allocations are
reported separately from application allocations.

The isolated ten-logical-minute production trace processed 36,000 samples:

```text
first_decile_ns_per_event=26762
last_decile_ns_per_event=27419
missed=0
input_high_water<=60 / 12288
result_high_water=1 / 1
workspace_installations=stable
surface_lease_high_water=1
hot_allocations=1/0
```

The last decile was about 2.5% slower than the first and remained inside the
declared flat-work bound. No logical frame was missed.

The same trace also passed inside the fully contended broad suite. Its wall
time expanded to 45.334 seconds, but preparation CPU remained flat
(45,866 ns/event first decile versus 36,354 ns/event last decile), storage and
queues remained bounded, and missed logical frames remained zero.

The trace harness now uses a 30-second monotonic *inactivity* watchdog that is
renewed only by causal protocol progress. A fixed five-second total wall
deadline previously produced a false failure while the broad suite contended
for Metal. Wall time is diagnostic; deterministic CPU work, queue bounds,
allocation stability, exact completion, and missed-frame accounting remain the
performance gates.

The final structural mutation gate and debug/release ARM64 stack budget gate
also pass. The generator composite measures 49,152 bytes against its 57,344
byte debug limit; optimized public roots remain at or below 16,384 bytes. The
stack checker selects the exact Swift function symbol so compiler-emitted
closure and partial-apply thunks cannot create an ambiguous measurement.

## Broad regression checkpoint

The final broad run completed **1,716 tests in 86 suites** in 176.864 seconds
and recorded exactly **27 issues**. Its process status is intentionally nonzero
because Swift Testing treats the frozen Stage B issues as failures.

`scripts/verify-swift-testing-baseline.sh` normalized source locations and
byte-compared the complete observed records against
`Tests/Baselines/stage-b-known-issues.txt`. It exited `0` with:

```text
Swift Testing baseline verified: 27 complete issue records.
```

No issue was added, removed, rewritten, or silently accepted.

## Environment and physical-evidence boundary

The final gates ran on:

```text
Model: Apple Virtual Machine 1 (VirtualMac2,1)
Chip: Apple M4 Pro (Virtual), 8 cores
Memory: 8 GB
macOS: 26.5.2 (25F84)
Xcode: 26.6 (17F113)
Swift: Apple Swift 6.3.3
Target: arm64-apple-macosx26.0
```

No iPad, Apple Pencil, Wacom tablet, or physical ProMotion display was
available. Therefore this checkpoint does not claim physical pressure, tilt,
azimuth, roll, predicted-touch, coalesced-touch, hover, drawable-presentation,
or sustained 120 Hz acceptance. Those remain explicit hardware/manual gates;
their absence does not weaken the deterministic software and Metal evidence
recorded here.

## Evidence logs

- `/tmp/stage-c-final-focused.log`
  (`fe9a3a99de2431f7c01e713a2b64ab5d7e871a47527fdae2de14eb2c465dd5e4`)
- `/tmp/stage-c-final-medium.log`
  (`43c9dc58b5fcd2377bfa965f7898863013811354b32af696d5b7908e0fb1fcda`)
- `/tmp/stage-c-final-allocation-probe.log`
  (`5dac5f1c31e5f2bb71c9376067a3fe7050753bfacbf7250d2a36bb052ed49de4`)
- `/tmp/stage-c-final-swift-test.log`
  (`b6f7a4df3c1fdc1dec8f1b20b3191403a704ec277793638363664fbb625d8e27`)

These logs are local execution evidence and are intentionally not committed.
The frozen Stage B issue-record file has SHA-256
`debb71d46973f9b48f8834e271d0be858be95e9241e75973842df1ef9957bd16`.

## Independent review

A fresh independent review inspected the complete C13 delta after all fixes.
It independently validated the duplicate-candidate correction, causal
inactivity watchdog, thread-safe allocation instrumentation, evidence
hashes/counts, and exact stack-symbol selector. It found no unresolved Critical
or Important correctness, concurrency, determinism, compatibility,
performance, or acceptance-evidence issue.

## Exit decision

Stage C is accepted. C13 is complete, and execution stops at the approved
Stage D boundary.
