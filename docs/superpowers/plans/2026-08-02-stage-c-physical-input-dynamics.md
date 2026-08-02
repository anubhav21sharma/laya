# Stage C Physical Input And Dynamics Implementation Plan

> **Execution:** Implement this plan directly on `main` with
> `superpowers:subagent-driven-development`. Every behavior change starts with
> a failing test, every task receives a fresh review, and work continues through
> C13 unless an external decision is genuinely impossible to deduce.

**Goal:** Make input velocity, sensor dynamics, stabilization, travel direction,
corner handling, timed emission, and directional footprint spacing coherent,
deterministic, bounded, and production-path safe while preserving every
schema-v1 brush exactly.

**Scope boundary:** This stage owns portable logical-stroke semantics only. It
does not implement Stage D color, Stage E texture residency/raster backends,
Stage F preset calibration, or Stage G product admission. Existing built-in and
converted brushes remain schema v1 during Stage C. New behavior is exercised by
named schema-v2 fixtures; Stage F opts the professional presets into it.

**Authority:** This plan refines Stage C of
`2026-08-01-brush-engine-corrective-program.md`. The approved world-class brush
engine design takes precedence over the older professional-stroke design where
they conflict. This document is the executable source of truth for Stage C.

**Baseline:** Before Stage C, the focused input/dynamics/generator suite passes
109 tests. The broad suite has 27 exact known baseline issue records documented
by the Stage B acceptance report. Stage C may not add a new failure or rewrite
an old visual baseline to make a changed result pass.

---

## 1. Delivery Protocol Learned From Stage B

Stage B failed operationally because one task mixed architecture migration,
state-machine changes, platform wiring, performance, and acceptance across 46
files. Stage C uses these rules, and later stages must adopt the same protocol:

1. A task owns one primary semantic contract or one integration seam, not both.
2. Pure state machines and reference oracles land before production wiring.
3. Definition schema, package decode, compiler, and semantic identity change in
   one atomic schema-owner task; no other task performs a partial wire migration.
4. Each state transition is enumerated before implementation: begin, append,
   prediction, estimated replacement, finish, cancel, failure, copy, reset, and
   rapid reuse where applicable.
5. Each task follows red -> green -> focused regression -> independent review.
   The reviewer checks the actual diff and tests, not the plan alone.
6. Integration seams add metamorphic tests immediately: trace partitioning,
   prediction on/off, zoom, display cadence, and estimated-suffix replay.
7. Performance-sensitive tasks include allocation and bounded-work assertions
   in the task that creates the hot path. Performance is not deferred to C13.
8. C13 repeats broad correctness, production-path, allocation, sustained-load,
   and independent-review gates. Stage C is not delivered before C13 is green.
9. After C13, Stage D receives a just-in-time preflight using this protocol.
   Stages E through G receive the same preflight before their implementation.
10. Commit only owned files. Preserve `.vscode/` and the untracked Procreate
    corpus key file.

Tasks are sequential even where the dependency graph permits conceptual
parallelism because `BrushDefinition`, `BrushProgram`, `BrushStrokeGenerator`,
and scheduler checkpoint state are shared ownership hotspots.

---

## 2. Locked Architecture And Semantics

### 2.1 Front-half order

The production and pure-generator paths use this exact order:

```text
validated actual/coalesced sample
  -> screen-to-world conversion
  -> raw-world velocity-window update
  -> position stabilization; other sensor provenance is retained
  -> attributed path interpolation
  -> travel-direction tracking and bounded corner candidates
  -> distance/time candidate generation and deterministic merge
  -> dynamics evaluation for one accepted candidate
  -> evaluated pre-projection footprint support
  -> distance carry for the following candidate
  -> ordinal and random assignment exactly once
  -> LogicalDabBatch
  -> symmetry/tiling/document projection
```

Velocity describes raw world-space input before stabilization. Symmetry,
tiling, zoom, display cadence, prediction, and batching never rerun or alter
logical dynamics, spacing, timing, ordinals, or random values.

Prediction runs this entire sequence from a value copy of authoritative state.
Estimated-property replacement restores the checkpoint preceding the changed
sample and regenerates the complete retained suffix. Cancel discards every
pending state. Failure leaves the next stroke reusable.

### 2.2 Version and compatibility ownership

The three version domains remain independent:

- `BrushDefinition` wire schema becomes v2 while v1 remains readable.
- `BrushPackageManifest` remains v2 because its wire format does not change.
- `BrushContentHash` dispatches independently by definition schema: v1 keeps
  semantic-hash schema 2 and its existing digest; v2 uses semantic-hash schema
  3 and the Stage C canonical stream.

Package decode first reads a tiny version envelope, then a version-specific DTO.
The v1 DTO adapts into an explicitly tagged runtime compatibility definition.
Ordinary read never rewrites the source archive. The checked-in
`stage2-v1.layabrush` fixture must read, compile, render, and hash under its
pinned legacy hash contract. Read performs no write; explicit encode may produce
new archive bytes only under a separately asserted round-trip contract.

The existing public initializer remains explicitly v1 even after
`currentSchemaVersion` becomes 2. A distinct v2 initializer requires every new
Stage C field; it has no defaults that could silently promote an old definition.
Within v1, preserve the existing unforgeable compatibility marker: decoded
legacy packages and `LegacyBrushRecipeAdapter` remain marker-bearing, while
direct catalog definitions remain unmarked. Termination compilation and hashing
must keep those two existing v1 paths distinct exactly as they are today.

V1 uses its existing instantaneous velocity, exponential stabilization, single
mapping evaluator, nominal-diameter spacing, termination, seven-word random
cursor, and compiled outputs bit-for-bit. New state may exist beside it but may
not influence its dabs. Production catalogs and `SyntheticV1BrushMapper` keep
emitting v1 until Stage F.

### 2.3 Velocity reference algorithm

`StrokeVelocityFilter` is a fixed-capacity value type with a 40 ms window and
64 segment slots. The minimum accepted delta is at least
`0.040 / 64 = 0.000625` seconds, so a valid window cannot overflow the ring.
Each accepted positive-time segment records start/end time and its
safety-clamped scalar speed:

```text
dt = end.time - start.time
if dt <= 0: return lastFiniteVelocity without mutating state
if dt < minimumDeltaTime: retain start as the next segment origin and return last
speed = min(maximumWorldVelocity, distance(start.position, end.position) / dt)
windowStart = end.time - 0.040
weightedDistance = sum(speed[i] * overlapDuration(segment[i], windowStart...end.time))
coveredDuration = sum(overlapDuration(...))
filtered = coveredDuration > 0 ? weightedDistance / coveredDuration : last
```

Segments crossing the left boundary are fractionally included; a segment that
ends exactly at the boundary contributes zero. The clamp is applied per segment
before averaging. Reset/begin produces zero. Positive sub-minimum deltas do not
advance the retained origin, so their displacement/time is coalesced into the
next accepted segment. Nonpositive deltas do not mutate anything. All arithmetic
is finite checked.

Schema-v2 `BrushSensorNormalizationDefinition` contains:

- `fullScaleWorldVelocity` in world units/second;
- `minimumVelocityDeltaTime` in seconds;
- `fullScaleStrokeAge` in seconds; and
- `fullScaleStrokeDistanceInDiameters` in nominal-diameter multiples.

Every value is finite and positive. Speed full scale is at most the 100,000
safety ceiling; minimum delta is `0.000625...0.01`; age is `1e-3...86_400`;
distance is `1e-3...1_000_000`. Normalized values clamp to `0...1`. The v1 adapter keeps
the existing 100,000 speed, 1-second age, and 10-diameter distance references.

### 2.4 Ordered sensor programs

Each schema-v2 output has a base value and zero through four ordered terms:

```swift
struct BrushResponseTermDefinition {
    let input: BrushDynamicsInput
    let response: BrushResponseDefinition
    let inputInverted: Bool
    let missingInputValue: Float
    let responseScale: Float
    let responseOffset: Float
    let responseLowerClamp: Float
    let responseUpperClamp: Float
    let jitter: Float
    let operation: BrushResponseOperation
}
```

For a term, optional missing input uses `missingInputValue`; present zero stays
zero. The normalized input is optionally inverted, evaluated through a compiled
256-entry LUT, transformed as `offset + scale * response`, receives symmetric
term-local jitter, and clamps to the term's explicit response range. The result
then applies `replace`, `multiply`, `add`, `minimum`, or `maximum` to the running
accumulator in serialized order. Only the named term clamp and final output
contract clamp/wrap occur—there is no hidden clamp between operations.

The output contracts are:

| Output | Final domain | Allowed operations |
| --- | --- | --- |
| size, spacing, grain | `1/1024...8` | all |
| flow, hardness | `0...8` | all |
| opacity, secondary color mix | `0...definition.limits.maximumOpacity` / `0...1` | all |
| scatter | `0...8` | all |
| offset X/Y | `-8...8` world-diameter multipliers | replace, add, min, max |
| rotation | wrapped to `[-pi, pi)` only after the full program | replace, add, multiply |
| hue | wrapped in turns only after the full program | replace, add, multiply |
| saturation, brightness | `-1...1` | all |

Direction, azimuth, and roll are cyclic normalized inputs. A term consuming a
cyclic input must use a periodic curve whose first and last y values match, or
a built-in linear-angle response explicitly marked for a cyclic rotation/hue
output. Invalid cyclic/output/operation pairs fail compilation.

Outputs compile and evaluate in fixed `BrushDynamicOutput.allCases` order.
Term random uses a counter keyed by `(strokeSeed, logicalOrdinal, outputID,
termIndex)` with four reserved term slots. It never consumes the v1 seven-word
cursor. Reordering terms intentionally changes that output; adding a term never
shifts another output or later dab.

### 2.5 Stabilization and direction

Schema-v2 stabilization modes are:

- `.none`: identity.
- `.weightedWindow(distance:)`: causal position-weighted window in world units.
  Resample incoming segments at the fixed arc interval `distance / 64`, retain
  the 65 bracketing points covering the newest authored distance, and keep the
  exact head separately. Integrate position along that clipped polyline with
  triangular arc weight `w(s) = 1 + s / distance` from oldest (`s = 0`) to head
  (`s = distance`); do not average event samples. On finish, append only one
  causal endpoint correction whose visible support reaches the actual endpoint
  within one world pixel; never replay the body.
- `.delayed(distance:)`: use the same fixed arc resampling and emit the point
  exactly the authored world distance behind the exact head by interpolation
  between its bracketing arc samples. Before sufficient distance, hold output.
  Finish does not hide the lag by flushing to the pointer; compiled metadata exposes
  `declaredEndpointLag`. A tap uses the stationary fallback below.
- `.legacyExponential(strength:)`: internal adapter-only mode preserving v1.

The resampling phase is defined by cumulative stroke distance from begin, not
by event boundaries. One long segment and the same collinear segment split into
arbitrary batches therefore produce identical retained samples. A segment
crossing multiple intervals emits only the newest 65 required samples; no
unbounded loop or queue is permitted. Consecutive stationary positions update
the exact head attributes without consuming a slot.

All modes modify position only and retain the current sample's attributes and
provenance. State is fixed-capacity, copyable, equatable, resettable, and has no
timer or wall-clock dependency. Weighted and delayed distances must be finite,
`1/1024...4096` world units. Authors select `.none`, rather than a zero-distance
weighted/delayed value, for identity behavior; schema validation rejects zero.

The stabilizer API can emit zero or one sample for a regular input and zero or
one final sample on finish; it therefore returns an explicit bounded output
rather than preserving the old unconditional one-sample return type. The v1
compatibility wrapper retains the old API result exactly.

`BrushDirectionTracker` consumes stabilized nonzero path segments, stores an
unwrapped angle, and applies shortest signed delta in `[-pi, pi)`. At exactly
pi, the sign follows the last nonzero turn; with no prior turn it is positive.
Stationary samples retain the last direction. First nonzero travel initializes
without interpolation from zero.

`BrushCornerEmitter` inserts orientation fan candidates when the signed turn
exceeds the compiled `maximumAngularStep` (`1 degree...pi`). It emits at the
corner position, excludes duplicate endpoints, uses monotonically interpolated
angles, and caps one corner at 32 candidates. A larger required fan is a typed
capacity failure; candidates consume ordinals/randomness only after candidate
merge. Reversal follows the tracker's deterministic pi rule.

The compiler records `usesTravelDirection`. A non-directional brush emits its
begin dab immediately. A directional brush holds the begin candidate until its
first nonzero tangent; a tap or stationary timed hold resolves it with the
authored `stationaryDirection` and still emits a visible dab. Holding consumes
no ordinal/randomness.

### 2.6 Portable support and distance spacing

Schema v2 owns a Metal-independent `BrushTipSupportDefinition`:

- `.analyticEllipse`: exact unit ellipse support;
- `.analyticRectangle`: exact unit rectangle/chisel support; or
- `.normalizedBounds(minX:maxX:minY:maxY:)`: validated, nonempty conservative
  alpha bounds within `[-1, 1]` on each axis for packaged/textured tips,
  computed off the stroke hot path.

V1 adapts to conservative full normalized bounds and keeps its old nominal-
diameter spacing path. Stage E may validate source alpha, build mips/cursor
contours, and cache resources, but it may not change this logical support per
device.

For an evaluated current dab and unit world tangent `t`, support is computed
from its complete pre-projection affine frame. A centered ellipse contributes
the projection interval `centerProjection +/-
sqrt(dot(t,xAxis)^2 + dot(t,yAxis)^2)`. A centered rectangle contributes
`centerProjection +/- (abs(dot(t,xAxis)) + abs(dot(t,yAxis)))`. Normalized
bounds transform all four corners and use their minimum and maximum tangent
projections. Multiple shape layers take the union interval across every layer.
Support width is always `maximumProjection - minimumProjection`; it is never
`2 * maximumAbsoluteProjection`, because bounds and shape layers may be offset
or asymmetric.

The following distance carry is:

```text
authored = supportWidth * placement.baseSpacingFraction * dynamicSpacing
safetyFloor = 1 world pixel
safetyCeiling = max(safetyFloor,
                    supportWidth * placement.maximumSpacingFraction)
carry = clamp(authored, safetyFloor...safetyCeiling)
```

The current dab drives the next carry. Rotation, aspect, pressure-driven size,
shape-layer transforms, and current tangent participate. Symmetry, tiling, and
viewport projection do not. Abrupt footprint/tangent changes may shorten the
remaining carry to the newly evaluated ceiling but never increase already
traveled distance or renumber an accepted candidate.

### 2.7 Recorded-time emission

Stage C uses sample-driven authoritative time. Only actual/coalesced sample
timestamps and the final ended-sample timestamp advance committed timed
emission. Display callbacks and wall clock are never inputs. Live stationary
buildup before another authoritative sample is intentionally not guaranteed;
adding recorded clock-advance events is a future versioned input feature.

```swift
enum BrushEmissionMode { case distance, time, distanceAndTime }
struct BrushEmissionDefinition {
    let mode: BrushEmissionMode
    let timeInterval: TimeInterval?
}
```

Distance and union modes use the existing placement spacing plus the compiled
spacing dynamics; there is no second authored distance-spacing source of truth.
Time and union modes require an interval; distance mode requires it to be nil.
Time interval is finite in `1/240...10` seconds. Time cadence is static in
schema v2; dynamics modulates only distance spacing.

For each attributed segment, distance and time sources produce candidates with
relative stroke time and source distance. Attributes interpolate by segment
time/path fraction. Every coordinate receives a transitive canonical key using
round-to-nearest-even integer quantization: relative seconds to nanoseconds and
world distance to millionths of a world unit. Values that cannot convert to
the signed 64-bit key domain fail validation before emission.

Candidates sort by `(provenance, timeKey, distanceKey, kind, cornerSequence)`.
Authoritative actual/coalesced candidates and prediction candidates are
generated in separate streams and never merge. Estimated updates first replace
the retained trace, so they do not form a third live provenance rank. Kind order
is `begin < distance < time < corner < finish`. Equal-key
distance/time/begin/finish candidates merge transitively by exact key equality;
the earliest kind supplies all interpolated attributes. There is no vague
"most authoritative" field-by-field combination. A corner fan uses its vertex's
canonical time/distance keys, and distinct orientations never merge;
`cornerSequence` preserves their monotonic order even when coordinates are
identical. Ordinals and random values are assigned only after merge. The begin
dab satisfies a coincident time/distance candidate.
Nonincreasing timestamps add no time candidate and do not mutate the next tick.
Stationary ticks retain direction or use `stationaryDirection`.

Finish catches up ticks through the ended timestamp, then emits the exact
endpoint once when the mode/termination contract requires it. Prediction never
synthesizes a finish endpoint. Cancel drops pending ticks/candidates.

One generation advance returns at most `LogicalDabBatch.maximumDabCount` (512)
accepted dabs and retains a resumable pure cursor for the remainder. The
coordinator drains cursors through existing bounded scheduler admission before
accepting completion. Queue exhaustion produces the existing typed capacity
failure; no candidate is dropped, widened, or silently deferred across commit.

### 2.8 Semantic identity

The v2/hash-schema-3 semantic digest is canonical and order-sensitive for normalization,
ordered terms, stabilization, direction/corner settings, emission, and tip
support. Every field that can alter dab count, ordinal, position, affine,
material input, or timestamp enters the digest. Preview and provenance remain
non-semantic. Dictionary insertion/hash order never affects identity. Pinned
fixtures lock v1/hash-schema-2 and v2/hash-schema-3 field order and digests.

---

## 3. Sequential Implementation Tasks

### Task 0 (C0) — Freeze The Reproducible Stage B Baseline

**Files:**

- Create `scripts/verify-swift-testing-baseline.sh`.
- Create `Tests/Baselines/stage-b-known-issues.txt`.
- Create `Tests/Baselines/README.md` documenting the normalization contract.

**Red:** Feed the verifier a missing, added, removed, and line-number-shifted
issue fixture. Only source line/column movement may normalize away; message,
test, file, and issue-count changes must fail.

**Green:** Run the pre-Stage-C full `swift test`, require its expected nonzero
status, extract Swift Testing issue records, normalize only source line/column,
sort them, and freeze the exact 27 records. The verifier then compares any new
full-suite log byte-for-byte with that checked-in artifact and exits zero only
for the same issue set. This must land before C1 so the baseline cannot be
recreated from Stage C output.

**Verify:**

```bash
set +e
swift test 2>&1 | tee /tmp/stage-c-preimplementation-swift-test.log
status=${PIPESTATUS[0]}
set -e
test "$status" -ne 0
scripts/verify-swift-testing-baseline.sh \
  /tmp/stage-c-preimplementation-swift-test.log \
  Tests/Baselines/stage-b-known-issues.txt
```

**Commit:** `test(brush): freeze stage B issue baseline`

### Task 1 (C1) — Deterministic Velocity Filter

**Files:**

- Create `Sources/PatternEngine/StrokeVelocityFilter.swift`.
- Create `Tests/PatternEngineTests/StrokeVelocityFilterTests.swift`.

**Red:** Add numeric vectors for uniform motion, exact 40 ms boundary,
fractional clipping, jittered intervals, positive sub-minimum coalescing,
zero/negative timestamps, stationary samples, safety-clamped spike recovery,
copy, reset, and capacity invariants. Include more than 64 raw samples inside
40 ms and prove sub-minimum coalescing yields the same duration-weighted result
as the equivalent accepted segmentation. Assert no heap growth after warm-up
over a million updates.

**Green:** Implement the fixed 64-slot value-state filter and expose only the
minimal update/reset/snapshot API. No `BrushInputDeriver` wiring yet.

**Verify:**

```bash
swift test --filter StrokeVelocityFilterTests
```

**Commit:** `feat(input): add deterministic velocity filter`

### Task 2 (C2) — Direction Tracker And Corner Oracle

**Files:**

- Create `Sources/PatternEngine/BrushDirectionTracker.swift`.
- Create `Sources/PatternEngine/BrushCornerEmitter.swift`.
- Create `Sources/PatternEngine/StrokeEmissionCandidate.swift`.
- Create `Tests/PatternEngineTests/BrushDirectionTrackerTests.swift`.
- Create `Tests/PatternEngineTests/BrushCornerEmitterTests.swift`.

**Red:** Cover first nonzero direction, 359° -> 1°, stationary retention, exact
pi with/without prior turn, reversal, maximum angular step, duplicate endpoints,
32-candidate bound, and copy/reset.

**Green:** Implement the shared unnumbered candidate representation plus pure
fixed-state tracker/emitter. A corner candidate receives the exact canonical
time/distance key of its vertex and a monotonic `cornerSequence`. These types do
not know about brush definitions, dabs, renderers, or random cursors.

**Verify:**

```bash
swift test --filter 'BrushDirectionTrackerTests|BrushCornerEmitterTests'
```

**Commit:** `feat(input): track direction and corner turns`

### Task 3 (C3) — Stabilizer Modes As Bounded State Machines

**Files:**

- Modify `Sources/PatternEngine/StrokeStabilizer.swift`.
- Modify `Tests/PatternEngineTests/StrokeStabilizerTests.swift`.

**Red:** Preserve existing v1 exponential vectors, then add none identity,
weighted reference vectors/boundary clipping/endpoint tolerance, delayed
interpolation/authored lag, zero-distance rejection, lower/upper distance
bounds, tap, cancel, prediction copy, reset, capacity, and attribute-provenance
cases.

**Green:** Evolve the existing stabilizer; do not create a duplicate. Keep the
legacy initializer and exact legacy implementation isolated.

**Verify:**

```bash
swift test --filter StrokeStabilizerTests
```

**Commit:** `feat(input): add bounded stabilizer modes`

### Task 4 (C4) — Timed Candidate State Machine

**Files:**

- Create `Sources/PatternEngine/TimedStrokeEmitter.swift`.
- Create `Tests/PatternEngineTests/TimedStrokeEmitterTests.swift`.

**Red:** Cover relative time origin, stationary ticks, moving interpolation,
exact interval boundary, begin deduplication, zero/negative timestamps, finish
catch-up, prediction without finish, cancel/reset, 512-result resumption, huge
gaps, tick-index overflow preflight, canonical key rounding/overflow, and
arbitrary input-batch partitions.

**Green:** Implement a pure sample-driven tick cursor using C2's shared
unnumbered candidate representation. It never reads a clock, allocates after
warm-up, or knows about the renderer.

**Verify:**

```bash
swift test --filter TimedStrokeEmitterTests
```

**Commit:** `feat(input): add recorded-time candidates`

### Task 5 (C5) — Portable Tip Support And Spacing Oracle

**Files:**

- Create `Sources/PatternEngine/BrushTipSupport.swift`.
- Create `Sources/PatternEngine/BrushFootprintSpacing.swift`.
- Create `Tests/PatternEngineTests/BrushTipSupportTests.swift`.
- Create `Tests/PatternEngineTests/BrushFootprintSpacingTests.swift`.

**Red:** Add independent ellipse, rectangle, centered and asymmetric/translated
normalized-bounds, offset multi-shape union, transformed aspect/rotation/size,
0°/45°/90° tangent, abrupt turn, reversal, safety-floor/ceiling, and nonfinite
validation vectors. Add a small CPU raster oracle that checks gaps and runaway
density without using production support math.

**Green:** Implement portable support functions and next-carry calculation.
Keep this package independent of Metal/CoreGraphics.

**Verify:**

```bash
swift test --filter 'BrushTipSupportTests|BrushFootprintSpacingTests'
```

**Commit:** `feat(brush): model directional tip support`

### Task 6 (C6) — Atomic Definition V2 And Semantic Identity

**Files:**

- Create `Sources/PatternEngine/BrushModel/BrushSensorProgram.swift`.
- Modify `Sources/PatternEngine/BrushModel/BrushDefinition.swift`.
- Modify `Sources/PatternEngine/BrushModel/BrushProgram.swift`.
- Modify `Sources/PatternEngine/BrushModel/BrushProgramCompiler.swift`.
- Modify `Sources/PatternEngine/BrushModel/LegacyBrushRecipeAdapter.swift`.
- Inspect/pin `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`.
- Inspect/pin `Sources/EditorCore/Brushes/StageFourAnchorDefinitions.swift`.
- Inspect/pin `Sources/BrushConverter/SyntheticV1BrushMapper.swift`.
- Modify `Sources/BrushFormat/BrushPackageCodec.swift`.
- Modify `Sources/BrushFormat/BrushPackage.swift`.
- Modify `Sources/BrushFormat/BrushContentHash.swift`.
- Modify `Tests/PatternEngineTests/BrushDefinitionTests.swift`.
- Modify `Tests/PatternEngineTests/BrushProgramCompilerTests.swift`.
- Modify `Tests/BrushFormatTests/BrushPackageCodecTests.swift`.
- Modify `Tests/BrushFormatTests/BrushPackageIOTests.swift`.
- Create `Tests/BrushFormatTests/BrushContentHashTests.swift`.
- Modify `Tests/EditorCoreTests/ProfessionalBrushCatalogTests.swift`.
- Modify `Tests/EditorCoreTests/AnchorBrushCatalogTests.swift`.
- Modify `Tests/BrushConverterTests/SyntheticV1BrushMapperTests.swift`.
- Add versioned fixtures under `Tests/BrushFormatTests/Fixtures/` only where
  generated from explicit hand-authored definitions.

**Red:** First pin v1 fixture bytes, definition fields, compiled program, dab
trace, no-read-rewrite behavior, and legacy semantic hash. Add v2 round trips,
unsupported-version errors, every validation boundary, manifest-version
independence, all-field hash sensitivity, ordered-term hash sensitivity, and
dictionary-order invariance.

Also assert every existing professional/anchor catalog entry and every synthetic
converter output is schema v1 before and after the migration, with its pinned
logical-dab/raster characterization unchanged.

**Green:** Add version-envelope dispatch, v1/v2 DTOs, new definitions, runtime
source discrimination, compiler metadata, and hash schema evolution atomically.
`BrushDefinition.legacySchemaVersion` is 1; the existing initializer defaults
to that constant. `BrushDefinition.currentSchemaVersion` becomes 2 and only the
new fully explicit v2 initializer selects it. Catalog/converter call sites stay
v1 unless source changes are needed to make that selection explicit.

Hash selection is exact: definition v1 invokes `CanonicalBrushWriterV1` with
hash schema 2; definition v2 invokes `CanonicalBrushWriterV2` with hash schema
3; every other definition version throws the typed unsupported-schema error.
Neither manifest version nor caller preference selects a writer. Never default
absent v2 semantics while decoding v1.

**Verify:**

```bash
swift test --filter 'BrushDefinitionTests|BrushProgramCompilerTests|BrushPackageCodecTests|BrushPackageIOTests|BrushContentHashTests'
swift test --filter 'SyntheticV1BrushMapperTests|professionalCatalog|anchorCatalog'
```

**Commit:** `feat(brush): add versioned stage C schema`

### Task 7 (C7) — Ordered Sensor Compiler And Evaluator

**Files:**

- Modify `Sources/PatternEngine/BrushModel/BrushSensorProgram.swift`.
- Modify `Sources/PatternEngine/BrushModel/BrushProgram.swift`.
- Modify `Sources/PatternEngine/BrushModel/BrushProgramCompiler.swift`.
- Modify `Sources/PatternEngine/BrushDynamicsEngine.swift`.
- Modify `Sources/PatternEngine/BrushRandom.swift`.
- Create `Tests/PatternEngineTests/BrushSensorProgramTests.swift`.
- Modify `Tests/PatternEngineTests/BrushDynamicsEngineTests.swift`.
- Modify `Tests/PatternEngineTests/BrushRandomTests.swift`.

**Red:** Use an independent scalar evaluator to cover every sensor/output,
pressure×tilt, pressure+speed, direction→rotation, operation order, present zero
versus absent neutral, inversion/affine/clamp/jitter, four-term limit, invalid
operation pairs, periodic curve seam, fixed output iteration, term-local random,
and exact v1 response parity.

**Green:** Compile all curves/validation off the input path and evaluate a fixed
tuple/enum-ordered program with no dictionary iteration or allocation. Retain
the v1 evaluator as an isolated compatibility path.

**Verify:**

```bash
swift test --filter 'BrushSensorProgramTests|BrushDynamicsEngineTests|BrushRandomTests|BrushProgramCompilerTests'
```

**Commit:** `feat(brush): evaluate ordered sensor programs`

### Task 8 (C8) — Velocity And Normalization Production Integration

**Files:**

- Modify `Sources/PatternEngine/BrushInput.swift`.
- Modify `Sources/PatternEngine/CentripetalCatmullRomStrokeInterpolator.swift`.
- Modify `Sources/PatternEngine/BrushStrokeGenerator.swift`.
- Modify `Sources/PatternEngine/BrushDynamicsEngine.swift`.
- Modify `Sources/MetalRenderer/StrokeRuntime/StrokeFrameScheduler.swift`.
- Modify `Sources/MetalRenderer/StrokeRuntime/StrokeRenderCoordinator.swift`.
- Modify `Sources/PatternEngine/TransientStrokeBuffer.swift` if its explicit
  checkpoint shape requires the filter state.
- Modify `Tests/PatternEngineTests/BrushInputTests.swift`.
- Modify `Tests/PatternEngineTests/AttributedStrokeInterpolatorTests.swift`.
- Modify `Tests/PatternEngineTests/BrushStrokeGeneratorTests.swift`.
- Modify `Tests/MetalRendererTests/StrokeFrameSchedulerTests.swift`.
- Modify `Tests/MetalRendererTests/StrokeRenderCoordinatorTests.swift`.

**Red:** Add v2 40 ms vectors through the generator plus zoom, event
partitioning, prediction on/off, estimated location replacement, suffix replay,
cancel, failure reuse, and rapid-next-stroke tests. Assert v1 still sees its
instantaneous velocity and emits the pinned trace. Pin both velocity fields at
world sample, attributed interpolation, generator, prediction checkpoint, and
estimated replay boundaries.

**Green:** Preserve the existing `velocity` field as the v1 instantaneous value
and add an explicitly named `artisticVelocity` field. World derivation computes
both; attributed interpolation linearly interpolates both with the same path
fraction; the compiled program selects one before dynamics. Include both fields
and filter state in every scheduler/coordinator checkpoint and replay equality
check.

**Performance:** After warm-up, one million derivations must show flat retained
allocation and O(1) work per accepted sample.

**Verify:**

```bash
swift test --filter 'BrushInputTests|StrokeVelocityFilterTests|AttributedStrokeInterpolatorTests|BrushStrokeGeneratorTests|StrokeFrameSchedulerTests|StrokeRenderCoordinatorTests'
```

**Commit:** `feat(input): integrate artistic velocity`

### Task 9 (C9) — Stabilized Path And Direction Production Integration

**Files:**

- Modify `Sources/PatternEngine/BrushStrokeGenerator.swift`.
- Modify `Sources/PatternEngine/TransientStrokeBuffer.swift` as required.
- Modify `Sources/MetalRenderer/StrokeRuntime/StrokeFrameScheduler.swift`.
- Modify `Sources/MetalRenderer/StrokeRuntime/StrokeRenderCoordinator.swift`.
- Modify `Tests/PatternEngineTests/BrushStrokeGeneratorTests.swift`.
- Modify `Tests/PatternEngineTests/TransientStrokeBufferTests.swift`.
- Modify `Tests/MetalRendererTests/StrokeFrameSchedulerTests.swift`.
- Modify `Tests/MetalRendererTests/StrokeRenderCoordinatorTests.swift`.

**Red:** Add pipeline-order assertions, directional/non-directional begin, tap,
stationary fallback, weighted endpoint, delayed lag, tight turn, reversal,
bounded fan ordinals/randomness, prediction copy, estimated-suffix replacement,
cancel, failure reuse, batching, and no-body-replay tests.

**Green:** Wire C2/C3 state into the authoritative generator and all production
copies/checkpoints. Corner candidates enter the unified unnumbered candidate
stream. Do not modify Technical Ink or another production preset.

**Verify:**

```bash
swift test --filter 'StrokeStabilizerTests|BrushDirectionTrackerTests|BrushCornerEmitterTests|BrushStrokeGeneratorTests|TransientStrokeBufferTests|StrokeFrameSchedulerTests|StrokeRenderCoordinatorTests'
```

**Commit:** `feat(input): integrate stable path direction`

### Task 10 (C10) — Footprint-Aware Distance Integration

**Files:**

- Modify `Sources/PatternEngine/BrushDynamicsEngine.swift`.
- Modify `Sources/PatternEngine/BrushStrokeGenerator.swift`.
- Modify `Sources/PatternEngine/BrushModel/LogicalDabBatch.swift` only if a
  named telemetry/projection consumer needs support evidence.
- Modify `Tests/PatternEngineTests/BrushDynamicsEngineTests.swift`.
- Modify `Tests/PatternEngineTests/BrushStrokeGeneratorTests.swift`.
- Modify `Tests/PatternEngineTests/LogicalDabBatchTests.swift` if needed.
- Modify symmetry/tiling oracle tests that already exercise logical dab counts.

**Red:** Prove the evaluated current footprint drives the following carry for
ellipse/chisel/textured bounds across size, pressure, aspect, rotation, tangent,
turn, and reversal. Prove symmetry count changes projected instances only, not
logical dabs. Pin v1 nominal-spacing trace.

**Green:** Integrate C5 after dynamics and before next-distance carry. Do not
store metadata downstream unless a test names its consumer.

**Verify:**

```bash
swift test --filter 'BrushFootprintSpacingTests|BrushStrokeGeneratorTests|LogicalDabBatchTests|TilingCoverageOracleTests|RadialSymmetryKernelTests'
```

**Commit:** `feat(brush): space from evaluated footprint`

### Task 11 (C11) — Unified Distance/Time Candidate Merge

**Files:**

- Create `Sources/PatternEngine/StrokeEmissionMerger.swift`.
- Modify `Sources/PatternEngine/TimedStrokeEmitter.swift`.
- Modify `Sources/PatternEngine/BrushStrokeGenerator.swift`.
- Create `Tests/PatternEngineTests/StrokeEmissionMergerTests.swift`.
- Modify `Tests/PatternEngineTests/TimedStrokeEmitterTests.swift`.
- Modify `Tests/PatternEngineTests/BrushStrokeGeneratorTests.swift`.

**Red:** Cover distance-only, time-only, union, exact and adjacent quantization-
boundary ties, a three-candidate chain that would be non-transitive under
epsilon comparison, interpolation, stationary movement, corner coexistence and
sequence preservation, begin/end, batch partitions, separate prediction
provenance, ordinal/random assignment after merge, resumption at 512, huge
gaps, cancel, overflow, and v1 distance-only parity.

**Green:** Merge unnumbered candidates in the locked order and assign identity
only after acceptance. Generator returns a resumable result without dropping
or widening candidates.

**Verify:**

```bash
swift test --filter 'TimedStrokeEmitterTests|StrokeEmissionMergerTests|BrushStrokeGeneratorTests|LogicalDabBatchTests'
```

**Commit:** `feat(brush): merge distance and timed emission`

### Task 12 (C12) — Bounded Scheduler Drain And Failure Recovery

**Files:**

- Modify `Sources/MetalRenderer/StrokeRuntime/StrokeFrameScheduler.swift`.
- Modify `Sources/MetalRenderer/StrokeRuntime/StrokeRenderCoordinator.swift`.
- Modify `Sources/PatternEngine/TransientStrokeBuffer.swift` if resumable cursor
  checkpoints require it.
- Modify `Tests/MetalRendererTests/StrokeFrameSchedulerTests.swift`.
- Modify `Tests/MetalRendererTests/StrokeRenderCoordinatorTests.swift`.
- Modify `Tests/PatternEngineTests/TransientStrokeBufferTests.swift`.

**Red:** Exercise 60/120/uncapped schedules, 512 boundaries, huge stationary
gaps, queue pressure, drain-before-finish, prediction shedding, authoritative
capacity failure, cancel during resume, resize/clear/undo/redo/brush switch, and
rapid next stroke. Inject failures at each resume/admission seam and prove the
renderer remains reusable.

**Green:** Drain resumable candidates under existing preparation and queue
budgets. Completion cannot commit until authoritative candidates are drained.
Overload uses typed failure and cancels cleanly; prediction remains disposable.

**Performance:** Queue high-water remains bounded; per-frame preparation is
bounded by configured budget; no main-actor generation; allocations stabilize
after warm-up.

**Verify:**

```bash
swift test --filter 'StrokeFrameSchedulerTests|StrokeRenderCoordinatorTests|TransientStrokeBufferTests|InteractiveFrameTimestampTests'
```

**Commit:** `perf(render): bound stage C candidate drain`

### Task 13 (C13) — Stage C Acceptance Checkpoint

**Files:**

- Create `docs/superpowers/reports/2026-08-02-stage-c-acceptance.md`.
- Add/modify test harness files only when a missing acceptance observation
  cannot be expressed by existing harnesses.

**Acceptance matrix:**

- [ ] V1 package reads without rewrite and matches pinned definition, compiled
      program, logical dabs, legacy hash, and rendered output.
- [ ] Every v2 semantic field changes the current semantic digest; collection
      insertion/hash order does not.
- [ ] Every partition of the canonical traces emits identical dabs, ordinals,
      random values, and committed pixels.
- [ ] Prediction on/off and prediction batching do not change authoritative
      dabs or committed pixels.
- [ ] 60/120/uncapped display schedules produce identical authoritative output.
- [ ] Zoom does not change world velocity, dynamics, spacing, or output.
- [ ] Estimated location/sensor suffix replacement equals a final actual trace
      generated from scratch.
- [ ] V1 exact endpoint, v2 weighted endpoint tolerance, delayed declared lag,
      click visibility, and stationary directional fallback pass.
- [ ] Direction wrap, pi tie, reversal, maximum angular delta, bounded fans,
      and broad-tip corner raster metrics pass.
- [ ] Time/distance tie, huge gap, resume, overflow, finish, and cancel pass.
- [ ] Analytic/textured support across size/aspect/rotation/tangent/corners and
      symmetry invariance pass.
- [ ] Begin, append, prediction, estimate, finish, cancel, failure, rapid next
      stroke, resize, clear, undo/redo, brush switch, and plain/seamless/radial
      production routes pass.
- [ ] No production input route uses the legacy synchronous renderer.
- [ ] Focused allocation traces show no post-warm-up growth for new filters,
      trackers, stabilizers, support math, or candidate merger.
- [ ] The 10-minute production trace has bounded queues, flat first-vs-last
      decile CPU work, stable allocations, and acceptable frame scheduling.
- [ ] The broad `swift test` returns the expected nonzero status and the C0
      verifier byte-compares exactly the accepted 27 Stage B issue records with
      no added, removed, or changed issue.
- [ ] A fresh independent review finds no unresolved Critical or Important
      correctness, concurrency, determinism, compatibility, or performance issue.

Record commands, commit, environment, counts, hashes, trace paths, skipped
physical evidence, and exact known baseline failures in the report. Do not
claim iPad/Wacom/120 Hz physical acceptance without hardware.

**Commit:** `test(brush): accept stage C dynamics`

---

## 4. Verification Cadence

Fast gate after every task: the task's pure and focused tests.

Medium gate after C6, C9, and C12:

```bash
swift test --filter 'BrushInputTests|StrokeVelocityFilterTests|BrushDirectionTrackerTests|BrushCornerEmitterTests|StrokeStabilizerTests|TimedStrokeEmitterTests|BrushTipSupportTests|BrushFootprintSpacingTests|BrushSensorProgramTests|BrushDefinitionTests|BrushProgramCompilerTests|BrushDynamicsEngineTests|BrushStrokeGeneratorTests|LogicalDabBatchTests|TransientStrokeBufferTests|BrushPackageCodecTests|BrushPackageIOTests|StrokeFrameSchedulerTests|StrokeRenderCoordinatorTests'
```

Stage gate after C13 (the first command is expected to return nonzero because
Swift Testing treats the frozen known issues as failures; the verifier must
return zero):

```bash
set +e
swift test 2>&1 | tee /tmp/stage-c-final-swift-test.log
status=${PIPESTATUS[0]}
set -e
test "$status" -ne 0
scripts/verify-swift-testing-baseline.sh \
  /tmp/stage-c-final-swift-test.log \
  Tests/Baselines/stage-b-known-issues.txt
```

Run the real Metal harness when a device is available on the current Mac; a
device absence may be recorded only as a hardware skip. The simulator and
macOS app provide platform input/resize/lifecycle coverage while physical iPad
evidence remains pending.

---

## 5. Dependency Graph And Stop Boundary

```text
C0 baseline -----------> all tasks and C13
C1 velocity -----------\
C2 direction/corners --+--> C6 schema --> C7 sensor runtime --> C8 velocity integration
C3 stabilization ------+---------------------------------------> C9 path integration
C4 timed candidates ---+------------------------------------------\
C5 support/spacing ----+--> C10 footprint integration -------------+--> C11 merge
                                                                  --> C12 scheduler
                                                                  --> C13 acceptance
```

C13 is the only Stage C completion boundary. Do not begin Stage D in this
execution. If an implementation discovery invalidates a locked rule, update
this plan with evidence and continue when the correction is deducible; stop for
the user only when the product choice is both material and not inferable from
the approved specs or repository behavior.
