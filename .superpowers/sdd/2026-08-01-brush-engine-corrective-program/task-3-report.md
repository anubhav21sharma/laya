# Task 3 — Make Performance Evidence Measure The Production Path

## Result

Implemented the Task 3 runtime telemetry contract, fail-closed software gate,
attributable buffered JSONL records, compact HUD mapping, and harness trace
profile routing. No performance pass is synthesized from isolated benchmark
arrays: a requested harness trace must contain a production-origin runtime
snapshot of the requested duration or the launcher fails.

## Requirement mapping

1. **Attributable telemetry.**
   `StrokeRuntimeTelemetry` records session, segment, and stroke UUIDs; actual,
   coalesced, predicted, and estimated-update input counts; new logical and
   projected dab counts; authoritative and predicted replay counts; current and
   high-water queue depths; prepare, event-to-submit, GPU, and presentation
   timestamps; frame/prepare/submit/GPU percentiles; display and
   event-to-submit miss fractions; cache hits/misses; memory high-water; and a
   bounded authoritative queue series.
2. **Deterministic aggregation.**
   `StrokeRuntimeTimestampSource` is injectable. The focused aggregation test
   uses a locked deterministic sequence source and hand-derived timestamp,
   percentile, counter, queue, cache, memory, and miss expectations.
3. **Segment isolation and buffered JSONL.**
   Runtime begin/end markers carry session, segment, stroke, timestamp, and
   trace profile. Existing production logger session calls are persisted as
   explicit `segmentBegan`/`segmentEnded` JSONL records with a stable segment
   ID. Records are encoded into memory and no file is created or written on the
   sample path; `flush()` performs the batched file write at session teardown.
4. **Production trace profiles.**
   Added named 10-second and accelerated logical 10-minute profiles with exact
   10,000,000,000 ns and 600,000,000,000 ns duration contracts. Harness
   `--performance-trace 10-second` and
   `--performance-trace accelerated-10-minute` requests require a matching
   persisted production snapshot and reject missing, mismatched, synthetic, or
   too-short evidence rather than silently relabeling an isolated benchmark.
5. **Software gate.**
   `BenchmarkStrokeRuntimeGate` rejects non-production origin, insufficient
   duration, any authoritative replay for append-only brushes, a nondecreasing
   authoritative backlog with net growth across at least three observations,
   and event-to-submit misses above 1%. Tests independently exercise each
   failure mode and the exact 1% inclusive boundary.
6. **Benchmark persistence.**
   `BenchmarkRecord` round-trips an optional full runtime snapshot and exposes
   a fail-closed runtime validation entry point while preserving all legacy
   schemas.
7. **Production deposition accounting.**
   Existing deposition telemetry now counts submitted frames and exposes a
   measured missed-frame fraction; reset and saturation behavior remain intact.
8. **HUD and monitor.**
   Monitor snapshots can carry the complete runtime contract and map its live
   queue/timing values into existing app diagnostics. The HUD shows current /
   target FPS, frame p95, prepare p95, submit p95, GPU p95, actual/predicted
   queue depth, and logging state.
9. **Expected prior defects.**
   The five Task 2 renderer failures remain reproducible with exactly seven
   known issues; Task 3 did not modify their implementation or expectations.

## Files changed

- `Sources/MetalRenderer/StrokeRuntime/StrokeRuntimeTelemetry.swift`
- `Sources/MetalRenderer/Deposition/DepositionTelemetry.swift`
- `Sources/MetalRenderer/BenchmarkRecord.swift`
- `App/PatternSpike/Debug/DebugPerformanceMonitor.swift`
- `App/PatternSpike/Debug/DebugPerformanceHUD.swift`
- `App/PatternSpike/Harness/HarnessLaunch.swift`
- `Tests/MetalRendererTests/StrokeRuntimeTelemetryTests.swift`
- `Tests/MetalRendererTests/BenchmarkRecordTests.swift`
- `Tests/MetalRendererTests/DepositionTelemetryTests.swift`
- `App/Tests/DebugPerformanceMonitorTests.swift`

Preserved without modification: `.vscode/` and
`brushes/procreate/1_FREE_Charcoal_Set.key`.

## Red/green evidence

### Core runtime RED

Command:

```bash
swift test --filter 'StrokeRuntimeTelemetryTests|BenchmarkRecordTests'
```

Exit status: `1` as expected. Compilation failed because
`StrokeRuntimeTelemetry`, its timestamp source/frame/snapshot/profile types,
the benchmark gate, and `BenchmarkRecord.strokeRuntime` did not exist. No
unrelated production failure was present.

### Core runtime GREEN

The same command exited `0`. Thirty-one tests passed, including deterministic
aggregation, trace-profile duration, four independent software-gate failures,
and benchmark round-trip.

### App boundary RED

Command:

```bash
swift test --filter 'DebugPerformanceMonitorTests'
```

Exit status: `1` as expected. Compilation failed because the monitor runtime
snapshot method/field, attributed segment kinds/IDs, deterministic logger
session initializer, and buffered record API did not exist.

After adding those APIs, the same command exited `0`: eight tests passed.

### Buffered production marker RED then GREEN

Command:

```bash
swift test --filter debugPerformanceLoggerWritesReviewableJSONLines
```

Before the automatic production marker mapping, exit status was `1`: the
recorded kinds were `sessionStarted/sessionEnded` and segment ID was nil.
After mapping production session boundaries to explicit segment markers and a
stable ID, the test passed in the required focused run.

### Deposition frame denominator RED then GREEN

Command:

```bash
swift test --filter 'DepositionTelemetryTests.timingWindows'
```

Exit status: `1` as expected because `submittedFrameCount` and
`missedFrameFraction` did not exist. After implementation, the extended
focused suite passed the exact five-frame / one-miss fraction of `0.2`.

### Required focused verification

Command:

```bash
swift test --filter 'StrokeRuntimeTelemetryTests|DebugPerformanceMonitorTests|BenchmarkRecordTests'
```

Exit status: `0`; 39 tests passed with zero issues in 0.009 seconds.

### Extended telemetry regression

Command:

```bash
swift test --filter 'StrokeRuntimeTelemetryTests|DebugPerformanceMonitorTests|BenchmarkRecordTests|DepositionTelemetryTests'
```

Exit status: `0`; 44 tests passed in one suite with zero issues.

### macOS app build

Command:

```bash
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac \
  -configuration Debug -derivedDataPath .build/task3-derived \
  CODE_SIGNING_ALLOWED=NO build
```

Exit status: `0`; `** BUILD SUCCEEDED **`. This compiles the app logger,
HUD, monitor, new MetalRenderer source, and HarnessLaunch trace routing.

### Expected-red corrective fixtures

Command:

```bash
swift test --filter 'BrushCorrectiveFunctionalTests|ProfessionalStrokeTraceTests'
```

Exit status: `1` as expected. Twelve tests ran. Seven infrastructure/oracle
tests passed; the five intentional Task 2 defect tests produced the same seven
issues: retained replay 280, endpoint retreat 24 px, Graphite widths 10/10 px,
Charcoal visibility 0 and alpha p50 0, and Chisel protrusion 13.5 px.

### Repository checks

`git diff --check` exits `0`. Only the Task 3 source/test/report paths are
staged; the two named unrelated paths remain untracked and untouched.

## Self-review

- Every aggregate expected value is hand-derived; tests do not reuse telemetry
  helpers to construct expected percentiles or counters.
- The gate treats 1% as passing and rejects only values strictly above it.
- Production labels alone cannot pass: the gate additionally requires the
  profile's full logical duration.
- Queue-growth detection requires at least three observations, no decreases,
  and net growth, avoiding false positives for stable or draining queues.
- Duration windows and queue history are bounded; cumulative counters saturate.
- Timestamp order, queue nonnegativity, frame budget, active segment, and stroke
  attribution fail explicitly.
- Existing BenchmarkRecord schemas remain backward-compatible because runtime
  evidence is optional.
- JSONL file I/O occurs only in the explicit batched flush, not on sample
  recording.
- The app build proves Swift 6 strict-concurrency compatibility.
- Task 2 expected failures were rerun unchanged.

## Concerns

The new harness flags intentionally fail closed until a harness runner supplies
a qualifying `strokeRuntime` snapshot; this task does not manufacture a pass
from the existing isolated timing arrays. A real controlled trace must populate
the snapshot through `StrokeRuntimeTelemetry` before either profile can be
reported as passed. Physical-device qualification remains out of scope and
pending.

## Round 1 corrective review

The review findings are fixed in the production path. `GridRenderer` now owns
the production recorder and records real input, preparation, submission, Metal
GPU start/finish, and drawable presentation events. Harness trace requests run
that path for the required wall duration, attach the resulting snapshot to the
benchmark JSON atomically, and then apply the software gate. The accelerated
profile spends ten seconds of wall time and derives ten logical minutes with a
60x mapping.

The gate now requires a production-recorder attestation, matching trace
profile, complete frame/queue event counts, distinct segment/stroke
attribution, renderer input and dab attribution, internally consistent event
timestamps, and wall/logical durations derived from the first input and final
presentation. Direct aggregates, relabelled encoded snapshots, partial queue
evidence, monotonic growth hidden outside bounded diagnostic history, invalid
GPU ordering, and cross-frame regressions all fail closed.

The debug logger now sends lightweight records to a bounded actor-owned queue.
JSON encoding and file I/O occur in that actor in batches or on periodic/
explicit flush. Its session, segment, and stroke IDs come only from the
renderer recorder, and every stroke rotates the segment/stroke IDs while the
session remains stable.

### Corrective RED evidence

```bash
swift test --filter StrokeRuntimeTelemetryTests
```

Exit status: `1` before implementation. The new tests did not compile because
`StrokeRuntimeProductionController`, recorder origin/attestation, derived wall
duration, strict regression errors, and full-segment backlog evidence were
absent. During implementation, the relabel test specifically failed with the
unattested-trace result until encoded profile/attestation consistency was
enforced.

```bash
swift test --filter DebugPerformanceMonitorTests
```

Exit status: `1` before implementation. The logger still performed synchronous
encoding/I/O and had no bounded capacity, drop diagnostics, or renderer-owned
identifier contract.

### Corrective focused GREEN

```bash
swift test --filter 'StrokeRuntimeTelemetryTests|DebugPerformanceMonitorTests|BenchmarkRecordTests'
```

Exit status: `0`; 48 tests passed with zero issues. This includes production
controller event completion/attestation, encoded and direct relabel rejection,
accelerated wall/logical mapping, full-segment backlog detection with a
truncated diagnostic window, insufficient evidence, timestamp order/
regressions, per-stroke ID rotation, renderer-owned logger IDs, and bounded
background logging.

### Real renderer trace evidence

```bash
.build/task3-round1-derived/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike \
  --harness-scene App/PatternSpike/Harness/Scenes/blank-canvas.json \
  --output-directory "$out" --git-commit test --configuration Debug \
  --performance-trace 10-second
```

Exit status: `0`; `HARNESS PASS`. The persisted benchmark records profile
`productionTenSeconds`, origin `productionRenderer`, 374 frames, 374 complete
frame attestations, 374 queue observations, wall/logical duration
`10026280333` ns, and distinct non-null session/segment/stroke IDs.

The same command with `--performance-trace accelerated-10-minute` exited `0`
with `HARNESS PASS`. The persisted trace records profile
`productionAcceleratedTenMinutes`, wall duration `10031550250` ns, derived
logical duration `601893015000` ns, and 365 production frames.

### Corrective macOS build

```bash
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac \
  -configuration Debug -derivedDataPath .build/task3-round1-derived \
  CODE_SIGNING_ALLOWED=NO build
```

Exit status: `0`; `** BUILD SUCCEEDED **` from the final sources.

### Expected-red isolation check

```bash
swift test --filter 'BrushCorrectiveFunctionalTests|ProfessionalStrokeTraceTests'
```

Exit status: `1` as expected. Twelve tests ran; the same five Task 2 defect
tests produced the same seven issues (retained replay 280, endpoint retreat 24
px, Graphite widths 10/10 px, Charcoal visibility/alpha zero, Chisel protrusion
13.5 px). Task 3 did not alter those expected-red fixtures.

`git diff --check` exits `0`. `.vscode/` and
`brushes/procreate/1_FREE_Charcoal_Set.key` remain untracked and untouched.

### Final corrective review closure

A second read-only review found four additional production-readiness gaps in
the first corrective pass. The final implementation closes them as follows:

- SHA-256 attestation binds the complete encoded aggregate (with the
  attestation removed), so changing replay/miss counters, either profile,
  duration, attribution, timestamps, queues, or any other gated field rejects
  as `invalidAttestation`.
- The logger uses one bounded `AsyncStream` mailbox and one persistent consumer
  task. The MainActor callback no longer allocates one task per sample; JSON
  encoding and file I/O remain isolated in the sink actor.
- Input timestamps are consumed at `beginFrame`, preventing concurrent frames
  from reusing an older input and inflating event-to-submit misses.
- `GridRenderer` tracks every in-flight runtime frame and deterministically
  discards the complete set before ending a segment. The production controller
  also provides an all-pending discard seam covered by tests.
- Runtime presentation telemetry uses the drawable's presented callback on all
  supported platforms; command-buffer completion is no longer represented as
  presentation on non-macOS platforms.

Final focused verification:

```bash
swift test --filter 'StrokeRuntimeTelemetryTests|DebugPerformanceMonitorTests|BenchmarkRecordTests'
```

Exit status: `0`; 51 tests passed with zero issues. The three added regression
tests prove aggregate failure fields cannot be erased in encoded evidence,
each in-flight frame consumes its own input, and multiple pending frames can be
discarded before a segment ends.

Final persisted production runs from the rebuilt application both exited `0`
with `HARNESS PASS`:

- `10-second`: profile `productionTenSeconds`, origin
  `productionRenderer`, 372 frames/complete events/queue observations, wall
  and logical duration `10031485084` ns, digest
  `16bf8e6b580bf52239f561dff209e0809088d75ef14044339a12cb04f1abd1bf`.
- `accelerated-10-minute`: profile
  `productionAcceleratedTenMinutes`, origin `productionRenderer`, 369
  frames/complete events/queue observations, wall duration `10035090208` ns,
  derived logical duration `602105412480` ns, digest
  `9dbf4af2c387cb08aca777f861733989bd7b00561f3f9663790a1c2dc292e08c`.

The final macOS Debug build exited `0` with `** BUILD SUCCEEDED **`. The
expected-red Task 2 isolation check was rerun after the renderer changes:
12 tests ran and the same five intentional tests produced the same seven
issues and measurements.

Finding-by-finding self-review confirms every original Critical/Important item:
real GridRenderer event wiring and benchmark persistence; recorder origin,
aggregate integrity, attribution, timestamp and derived-duration consistency;
bounded off-hot-path logger work; explicit accelerated wall/logical semantics;
full-segment backlog and minimum evidence; complete same/cross-frame timestamp
ordering; and recorder-owned rotating session/segment/stroke identifiers. The
deferred Minor `Array.removeFirst()`/shared-primitive cleanup remains the only
known review item and is intentionally outside this corrective scope.

## Round 1 fix rescue — live authority and complete trace evidence

This section supersedes the digest and final-closure claims immediately above.
A self-contained SHA-256 checksum can be recomputed after changing a persisted
report, so it cannot prove recorder origin. The rescue removes that checksum
from the authority boundary instead of strengthening an invalid premise.

The production gate now accepts only a non-`Codable`
`StrokeRuntimeRecordedEvidence` capability. Its initializer and the
clock-injectable production controller are internal to `MetalRenderer`; the
renderer issues a capture only after a segment ends. `BenchmarkRecord` persists
the capture's immutable `Codable` report for review, but decoding that report
does not recreate gate authority. Harness validation therefore runs against
the live capture before writing benchmark JSON.

The persisted report now includes bounded raw frame records and an overflow
counter in addition to its summary. The gate requires all begun frames to have
complete raw records, with zero discarded frames, trace overflow, and
unconsumed input events. Input timestamps are consumed at frame begin; frames
without an attributed input remain useful for GPU/queue drainage but do not
enter event-to-submit percentiles or their miss denominator. A test with one
missed attributed frame and 99 unattributed drain frames remains a 100% miss.

Drawable presentation and synchronous offscreen command completion are now
explicit terminal semantics. Only drawable-presented frames populate frame
interval and missed-presentation metrics. The headless harness reports
`offscreenCommandCompleted` and makes no presentation-cadence claim. Same-frame
timestamp ordering and every adjacent cross-frame timestamp regression remain
fail-closed.

Frame completion now returns a lightweight Boolean and updates preallocated
windows/counters. Percentile sorting and summary publication happen only every
15 completed frames or at a segment boundary; raw records are copied only when
the segment is sealed. The queue suffix uses a ring instead of
`Array.removeFirst()`. JSON encoding and file I/O remain in the logger sink
actor.

The logger uses a marker-aware bounded mailbox. Samples are shed first under
pressure, preserving segment boundaries. Flush rotates immediately to one
bounded successor mailbox whose consumer waits for its predecessor, so a quick
HUD disable/re-enable cannot lose the next session or reorder generations.
Overlapping flushes serialize, and logger teardown finishes/cancels its stream
and tasks.

### Rescue verification

```bash
swift test --filter 'StrokeRuntimeTelemetryTests|DebugPerformanceMonitorTests|BenchmarkRecordTests'
```

Exit status: `0`; 62 tests passed with zero issues. New coverage includes a
real `GridRenderer` Metal call-site trace, live-capability versus decoded-report
authority, recomputable-checksum removal, raw-record round-trip, trace overflow,
discarded and unconsumed lifecycle evidence, unattributed miss dilution, every
within-frame inversion, cross-frame regressions, marker preservation under
sample pressure, and records accepted during an in-flight flush.

```bash
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac \
  -configuration Debug -derivedDataPath .build/task3-rescue-derived \
  CODE_SIGNING_ALLOWED=NO build
```

Exit status: `0`; `** BUILD SUCCEEDED **`.

Both rebuilt-binary production traces exited `0` with `HARNESS PASS`:

- `10-second`: profile `productionTenSeconds`, 396 begun/complete/raw frames,
  394 input-attributed frames, zero discarded/overflow/unconsumed events,
  explicit `offscreenCommandCompleted` semantics, and wall/logical duration
  `10026573500` ns.
- `accelerated-10-minute`: profile
  `productionAcceleratedTenMinutes`, 391 begun/complete/raw frames, 389
  input-attributed frames, zero discarded/overflow/unconsumed events, explicit
  `offscreenCommandCompleted` semantics, wall duration `10032645459` ns, and
  derived logical duration `601958727540` ns.

```bash
swift test --filter 'BrushCorrectiveFunctionalTests|ProfessionalStrokeTraceTests'
```

Exit status: `1` as expected. Twelve tests ran and reproduced the unchanged
five Task 2 defects as seven issues: retained replay 280, endpoint retreat 24
px, Graphite widths 10/10 px, Charcoal visibility/alpha 0, and Chisel turn
protrusion 13.5 px.

Both staged and unstaged `git diff --check` invocations exit `0`.
`.vscode/` and `brushes/procreate/1_FREE_Charcoal_Set.key` remain untracked and
untouched. Persisted reports are independently reviewable but intentionally do
not claim cryptographic origin after import; cross-process authenticity would
require an externally anchored signing key. Physical-device qualification
remains pending and outside Task 3.

## Final rescue review closure

The final independent review found and closed two remaining renderer edge
cases. Replay-epoch attribution now resets from each new transient stroke
buffer after the production controller successfully begins the stroke, so a
later stroke cannot inherit the previous stroke's replay high-water mark. A
two-stroke regression proves that each stroke independently reports its first
replay delta. The zero-valued drawable `presentedTime` fallback is now sampled
inside the presentation callback, so it cannot predate GPU completion merely
because it was captured before command-buffer commit.

Verification against the final source state:

```bash
swift test --filter 'StrokeRuntimeTelemetryTests|DebugPerformanceMonitorTests|BenchmarkRecordTests'
```

Exit status: `0`; 63 tests passed with zero issues, including the new
per-stroke replay-epoch regression.

```bash
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac \
  -configuration Debug -derivedDataPath .build/task3-rescue-derived \
  CODE_SIGNING_ALLOWED=NO build
```

Exit status: `0`; `** BUILD SUCCEEDED **`.
