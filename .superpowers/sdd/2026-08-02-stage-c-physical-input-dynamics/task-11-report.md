# Task 11 Report — Unified Distance/Time Candidate Merge

## Pre-integration ownership inventory

The state introduced by Task 11 is owned by `BrushStrokeGenerator`; every
generator checkpoint therefore copies it by value. The explicit inventory is:

- configuration: compiled `BrushStageCProgramMetadata.emission` selects
  distance/time/union; schema v1 has no Stage-C metadata and remains isolated;
- authoritative recorded-time state: `TimedStrokeEmitter`;
- authoritative accepted-key state: `StrokeEmissionMerger(.authoritative)`;
- prediction accepted-key state: `StrokeEmissionMerger(.prediction)`, used only
  by speculative generator copies and never installed into the authoritative
  generator;
- held begin: the existing `heldDirectionalBegin` remains the only direction
  owner; the timed source does not publish an early identity;
- continuation/page state: `TimedStrokeEmissionCursor` and
  `StrokeEmissionMergeStep` are copyable transaction candidates; source cursor,
  merger continuation, ordinal and random state install only after sink success;
- finish: authoritative time catch-up precedes one exact finish candidate;
  prediction never requests a finish candidate;
- cancel/reset/rapid reuse: `resetRuntimeState` recreates timed and merge state
  from the compiled definition together with path/direction/random state;
- equality: `BrushStrokeGenerator.emissionStateEqual` must name the timed and
  both merger fields explicitly; the manual field inventory is updated so an
  omitted owner fails a mutation-style test;
- buffer/coordinator checkpoints: `TransientStrokeChunk` already stores the
  complete generator snapshot after each sample; settled replay and prediction
  copies compare/reinstall the whole generator. No second cursor owner is added
  to buffer, coordinator, or scheduler in C11. C12 owns bounded downstream drain.

## TDD evidence

### RED 1–3 — pure merge

`swift test --filter StrokeEmissionMergerTests` failed to compile because
`StrokeEmissionMerger` and its typed provenance error did not exist.

The first green API is a pure allocation-free transactional head merge:
`next(distance:timed:)` returns the accepted unnumbered candidate (or nil for an
exact duplicate), exact source-consumption flags, and a copyable continuation.
Callers install the continuation and advance sources only after sink acceptance.
Six tests pin distance/time/union tuple order, exact versus adjacent keys, a
transitive three-candidate chain across partitions, full earliest-kind
attributes, stationary/corner ordering, and provenance isolation.

### RED 4 — generator acceptance

The first stationary time-mode integration test emitted only the begin dab
instead of the literal five-dab trace at 250 ms cadence. This proves the
compiled v2 emission mode was not consumed by production generation.

### RED 5 — bounded generator continuation

The first generator paging tests failed to compile because the generator had
no `emissionCursor` API. A timed cursor alone was insufficient: draining it
inside one generator call merely moved the unbounded loop and did not satisfy
the 512-identity contract. The production-facing value continuation now owns
the generator proposal, path traversal, held begin, pending segment, distance,
time and corner source state, both merge streams, and lifecycle phase.

The tests then pinned:

- 511, 512 and 513 accepted identities, including exact completion after 512;
- a million-second time gap doing one 512-identity page;
- an exact 513-dab distance path split 512 + 1;
- throwing-sink retry at ordinal 4, including a copied continuation;
- a complete begin/append/turn/corners/finish trace equal to the compatibility
  trace and ending in the same generator state;
- explicit cursor stored-field inventory and the logical-ordinal overflow
  preflight used by production acceptance.

### Stack RED and corrective design

The first correct cursor implementation copied the full 5+ KiB continuation
for every candidate. It passed functional and allocation tests but the pinned
ARM64 debug gate measured a 132,800-byte advance chain, so it was rejected.
The final design uses no full-cursor proposal:

- `emitNextPage` has one unified enabled/settling loop;
- the cursor itself remains the last accepted checkpoint;
- source and segment candidates mutate only after the sink accepts;
- `emitAcceptedCandidate` proposes only the eight-word random cursor and dab,
  then installs random/ordinal/spacing after sink success;
- segment work is a resumable `prepareSpatial -> prepareTimed -> decide ->
  commit` state machine, so candidate construction, merge decision, and sink
  commit do not share one stack frame;
- after a full page, disabled emission may settle duplicates and lifecycle-only
  transitions but returns `blocked` before the next accepted identity.

This preserves exact retry semantics while remaining allocation-free. The
fail-closed gate now measures construction, every cursor branch, accepted-dab
evaluation, and both advance/resume roots. The final debug composites are
34,928 bytes for construction and 52,704 bytes for advance/resume, each below
57,344 bytes. Optimized `emissionCursor` and `emitNextPage` roots are 7,744 and
8,544 bytes respectively, below 16 KiB.

## Contract implementation

- `StrokeEmissionMerger` compares only the exact tuple `(provenance, timeKey,
  distanceKey, kind, cornerSequence)`. There is no epsilon comparison.
- Raw kind order is begin, distance, time, corner, finish. Exact-key
  begin/distance/time/finish heads collapse transitively; the earliest kind's
  complete candidate is retained.
- Corner candidates retain distinct sequence/orientation identities and remain
  ordered with the other source heads.
- Authoritative and prediction mergers are separate stored generator fields;
  crossed provenance throws before mutation.
- Distance/time source continuations and merger continuation advance only after
  a duplicate is deterministically rejected or an accepted dab reaches the
  sink. Ordinal and all random channels advance only in the latter case.
- Finish drains authoritative time catch-up and then the exact endpoint once.
  Prediction advances its own copied timed/merge state and never synthesizes a
  finish identity.
- Timed, corner and Catmull-Rom traversal cursors are arithmetic/copyable. One
  page exposes at most `LogicalDabBatch.maximumDabCount` identities; huge gaps
  do O(512) candidate work per page.
- Schema v1 never constructs an emission cursor and stays on the characterized
  distance-only implementation. Schema v2 selects distance, time, or union
  from compiled `BrushEmissionDefinition`; only distance carry consumes the
  evaluated footprint spacing.

## Production boundary and duplication audit

Normal schema-v2 callback and batch entry points (`begin`, `append`, `finish`)
now call `emissionCursor` and synchronously drain its pages. This makes the
cursor implementation the semantic source of truth for the standard API, and
the full paged-vs-compatibility lifecycle test pins mutation parity.

That adapter is intentionally still unbounded across pages. The renderer still
uses the callback surface in C11, so this task does **not** claim bounded
end-to-end renderer draining. C12 must retain the cursor between frame budgets,
call one or more bounded pages, and install `completedGenerator` only when the
cursor completes. C11 does not add a second cursor owner to the scheduler,
coordinator, or transient buffer.

One deliberate residual implementation exists for prediction-prefix APIs.
`appendPredictionPrefix` and `finishPredictionPrefix` must publish the true
interpolator prefix and return `.truncated` without committing the incomplete
input; they therefore retain the older segment-oriented Stage-C traversal.
They share the canonical candidate builder, exact merger, timed cursor,
transactional accepted-dab function, dynamics evaluator, and random rules with
the bounded cursor. Existing prediction copy, truncation, partition, and retry
tests pin that seam. Standard authoritative schema-v2 generation does not call
this residual path. C12 should keep the distinction explicit; a later cleanup
may unify it only if the partial-prefix contract can be represented without a
second state owner.

`BrushStrokeGenerator.swift` grew substantially because the continuation is a
complete lifecycle state machine. Splitting the extension into a separate file
would improve navigation but would not change ownership or runtime behavior;
doing that during C11 would add mechanical diff risk while C12 still needs to
stabilize the scheduler-facing API. The recommended cleanup point is after C12.

## Verification evidence

- prescribed focused gate:
  `swift test --filter 'TimedStrokeEmitterTests|StrokeEmissionMergerTests|BrushStrokeGeneratorTests|LogicalDabBatchTests'`
  passed 95 tests in 2 suites;
- cursor layout gate: `BrushStrokeGenerator.EmissionCursor <= 6,144` bytes;
- release allocation probe: exact-tie union, direction/corners, 512+1 resume,
  huge time gap, standard Stage-C generator, and production route all require
  zero post-warm-up allocations; final results were Stage-C generator 0,
  Stage-C emission 0, and production 0;
- ARM64 stack gate: debug cursor composites <=57,344 and optimized public roots
  <=16 KiB under pinned Xcode 26.6 / Swift 6.3.3 / LLVM 21.0.0;
- symbol selection is fail-closed: the fully qualified generator cursor page
  resolves once, while the deliberately broad timed/generator cursor fragment
  is rejected as ambiguous;
- `git diff --check` is required immediately before commit; no broad suite is
  part of the C11 contract.
